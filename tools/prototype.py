#!/usr/bin/env python3
"""Phase 0 oracle for the AgentSpend menu bar app.

Parses Claude Code session logs, dedupes, and applies the energy + pricing
models. Validates the coefficients against real data before any Swift is
written, and doubles as the golden-file fixture the Swift ingestor is tested
against — its totals are the reference the app must reproduce exactly.

    python3 tools/prototype.py                    # summary to stdout
    python3 tools/prototype.py --json golden.json # golden file for Swift tests
    python3 tools/prototype.py --limit 40         # quick pass over N files

Two things this exists to prove out:
  1. Dedup on message.id is correct. ~50% of usage rows are duplicates.
  2. Cache reads are ~95% of token volume, so cacheReadFactor dominates the
     total. --sweep shows how much.
"""

import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict

# Model IDs appear in both alias (claude-haiku-4-5) and dated
# (claude-haiku-4-5-20251001) form. Normalize to the alias before any lookup —
# otherwise dated rows silently match nothing and are counted as zero energy.
DATE_SUFFIX = re.compile(r"-\d{8}$")


def normalize_model(model):
    return DATE_SUFFIX.sub("", model) if model else model

RESOURCES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "mac", "AgentSpend", "Resources",
)
DEFAULT_ROOT = os.path.expanduser("~/.claude/projects")

# Rows with this model are local bookkeeping, not inference.
SYNTHETIC = "<synthetic>"


def load_resources():
    with open(os.path.join(RESOURCES, "energy-model.json")) as f:
        energy = json.load(f)
    with open(os.path.join(RESOURCES, "pricing.json")) as f:
        pricing = json.load(f)

    tiers = {m["id"]: m["tier"] for m in energy["models"]}
    prices = {m["id"]: m for m in pricing["models"]}
    prices.update({m["id"]: m for m in pricing["unknownModels"]["entries"]})
    return energy, pricing, tiers, prices


def parse(root, limit=None):
    """Walk session logs and return deduped usage rows.

    Returns (rows, stats). Dedup is on message.id, which is present on 100% of
    usage rows; requestId is missing on synthetic rows, so it can't be primary.
    """
    # Recursive: session logs sit at <project>/<session>.jsonl, but subagent
    # transcripts are nested at <project>/<session>/subagents/agent-*.jsonl and
    # account for ~29% of the corpus. A one-level glob silently drops them.
    files = sorted(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True))
    if limit:
        files = files[:limit]

    # message.id -> row. NOT a first-wins set: a streaming assistant message is
    # logged repeatedly as it generates, each time with a partial
    # output_tokens. Every other field is identical across those repeats
    # (verified: 0 ids conflict on input/cacheRead/cacheWrite), so the correct
    # row is the one with the highest output_tokens — the completed message.
    # First-wins undercounts total output tokens by ~12.6%, and output is the
    # priciest (5x) and most energy-intensive (4x) token class.
    best = {}
    stats = {"files": len(files), "subagentFiles": 0, "bytesRead": 0,
             "rawUsageRows": 0, "duplicates": 0, "supersededPartials": 0,
             "synthetic": 0, "unparseable": 0}

    for path in files:
        is_subagent = f"{os.sep}subagents{os.sep}" in path
        if is_subagent:
            stats["subagentFiles"] += 1
        try:
            stats["bytesRead"] += os.path.getsize(path)
            fh = open(path, errors="ignore")
        except OSError:
            continue
        with fh:
            for line in fh:
                # Cheap prefilter: only ~40% of lines carry usage. Avoids
                # paying full JSON decode on the majority.
                if '"usage":{' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    stats["unparseable"] += 1
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict):
                    continue
                usage = msg.get("usage")
                if not isinstance(usage, dict):
                    continue

                stats["rawUsageRows"] += 1

                key = msg.get("id") or d.get("requestId")
                if key is None:
                    continue
                prior = best.get(key)
                if prior is not None:
                    stats["duplicates"] += 1
                    if (usage.get("output_tokens") or 0) <= prior["output"]:
                        continue
                    # Streaming repeat with a more complete output count.
                    stats["supersededPartials"] += 1

                model = msg.get("model")
                if model == SYNTHETIC:
                    stats["synthetic"] += 1
                    continue
                model = normalize_model(model)

                cc = usage.get("cache_creation") or {}
                best[key] = {
                    "id": key,
                    "ts": d.get("timestamp"),
                    "model": model,
                    "input": usage.get("input_tokens") or 0,
                    "output": usage.get("output_tokens") or 0,
                    "cacheWrite": usage.get("cache_creation_input_tokens") or 0,
                    "cacheWrite5m": cc.get("ephemeral_5m_input_tokens") or 0,
                    "cacheWrite1h": cc.get("ephemeral_1h_input_tokens") or 0,
                    "cacheRead": usage.get("cache_read_input_tokens") or 0,
                    "cwd": d.get("cwd"),
                    "branch": d.get("gitBranch"),
                    "session": d.get("sessionId"),
                    "sidechain": bool(d.get("isSidechain")),
                    "subagent": is_subagent,
                }
    return list(best.values()), stats


def energy_wh(row, energy, tiers, bound="v", read_factor=None):
    """Watt-hours for one request at the given band edge (lo | v | hi)."""
    tier = tiers.get(row["model"])
    if tier is None:
        return None
    t = energy["tiers"][tier]
    d = energy["defaults"]

    e_in = t["whPer1kInput"][bound]
    e_out = t["whPer1kOutput"][bound]
    rf = d["cacheReadFactor"][bound] if read_factor is None else read_factor
    wf = d["cacheWriteFactor"][bound]

    return (row["input"] * e_in
            + row["cacheWrite"] * e_in * wf
            + row["cacheRead"] * e_in * rf
            + row["output"] * e_out) / 1000.0


def cost_usd(row, prices, mult):
    p = prices.get(row["model"])
    if p is None:
        return None
    # Split the write by TTL when the breakdown is present; the 1h premium is
    # 2x vs 1.25x, which is a real difference in Claude Code's usage pattern.
    w5, w1h = row["cacheWrite5m"], row["cacheWrite1h"]
    if w5 + w1h == 0:
        write = row["cacheWrite"] * mult["write5m"]
    else:
        write = w5 * mult["write5m"] + w1h * mult["write1h"]
    return (row["input"] * p["input"]
            + write * p["input"]
            + row["cacheRead"] * p["input"] * mult["read"]
            + row["output"] * p["output"]) / 1_000_000.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--limit", type=int)
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--counterfactual", action="store_true",
                    help="replay the same tokens under alternative models")
    ap.add_argument("--sweep", action="store_true",
                    help="show total energy across the cacheReadFactor band")
    args = ap.parse_args()

    energy, pricing, tiers, prices = load_resources()
    mult = pricing["cacheMultipliers"]

    rows, stats = parse(args.root, args.limit)
    if not rows:
        sys.exit(f"No usage rows found under {args.root}")

    by_model = defaultdict(lambda: defaultdict(float))
    by_project = defaultdict(lambda: defaultdict(float))
    by_day = defaultdict(lambda: defaultdict(float))
    unknown_models = set()

    for r in rows:
        wh = energy_wh(r, energy, tiers)
        usd = cost_usd(r, prices, mult)
        if wh is None or usd is None:
            unknown_models.add(r["model"])
            wh, usd = wh or 0.0, usd or 0.0

        day = (r["ts"] or "")[:10]
        project = os.path.basename(r["cwd"] or "unknown")
        for bucket, k in ((by_model, r["model"]), (by_project, project), (by_day, day)):
            b = bucket[k]
            b["requests"] += 1
            b["input"] += r["input"]
            b["cacheWrite"] += r["cacheWrite"]
            b["cacheRead"] += r["cacheRead"]
            b["output"] += r["output"]
            b["wh"] += wh
            b["usd"] += usd

    tok = {k: sum(b[k] for b in by_model.values())
           for k in ("input", "cacheWrite", "cacheRead", "output")}
    total_tokens = sum(tok.values())
    total_wh = sum(b["wh"] for b in by_model.values())
    total_usd = sum(b["usd"] for b in by_model.values())

    sub_wh = sum(energy_wh(r, energy, tiers) or 0 for r in rows if r["subagent"])
    sub_rows = sum(1 for r in rows if r["subagent"])

    dup_pct = 100.0 * stats["duplicates"] / max(stats["rawUsageRows"], 1)
    print(f"files={stats['files']} (subagent {stats['subagentFiles']})  "
          f"{stats['bytesRead'] / 1e9:.2f} GB  rawUsageRows={stats['rawUsageRows']}  "
          f"unique={len(rows)}  duplicates={stats['duplicates']} ({dup_pct:.1f}%)  "
          f"synthetic={stats['synthetic']}")
    if unknown_models:
        # Silently zeroing an unrecognized model is the exact failure mode that
        # makes a tool like this quietly wrong. Make it loud.
        print(f"\n!! NO COEFFICIENTS — counted as ZERO energy and ZERO cost: "
              f"{', '.join(sorted(unknown_models))}")

    print("\ntoken mix")
    for k in ("cacheRead", "cacheWrite", "output", "input"):
        print(f"  {k:<11} {tok[k]:>16,}  {100.0 * tok[k] / total_tokens:>5.2f}%")

    print(f"\n{'model':<20} {'requests':>9} {'Wh (est)':>12} {'$':>10}  share")
    for m, b in sorted(by_model.items(), key=lambda kv: -kv[1]["wh"]):
        print(f"  {m:<18} {int(b['requests']):>9,} {b['wh']:>12,.1f} "
              f"{b['usd']:>10,.2f}  {100.0 * b['wh'] / total_wh:>5.1f}%")

    lo = sum(energy_wh(r, energy, tiers, "lo") or 0 for r in rows)
    hi = sum(energy_wh(r, energy, tiers, "hi") or 0 for r in rows)
    print(f"\nTOTAL  {total_wh / 1000:,.1f} kWh  (band {lo / 1000:,.1f}-{hi / 1000:,.1f})"
          f"   ${total_usd:,.2f}")
    print(f"  of which subagents: {sub_rows:,} requests, {sub_wh / 1000:,.1f} kWh "
          f"({100.0 * sub_wh / total_wh:.1f}%)")
    # The band evaluates every coefficient at its extreme simultaneously, so it
    # is a worst-case envelope, not a confidence interval. Treat it as such.

    # The whole point of the sweep: cache reads are ~95% of volume, so this one
    # coefficient moves the total more than any model-choice decision.
    if args.sweep:
        print("\ncacheReadFactor sensitivity (all else held at v)")
        for rf in (0.01, 0.05, 0.10, 0.20, 0.30):
            t = sum(energy_wh(r, energy, tiers, "v", read_factor=rf) or 0 for r in rows)
            print(f"  {rf:>5.2f}  {t / 1000:>10,.1f} kWh   {t / total_wh:>5.2f}x")

    # Counterfactual: replay the SAME token counts under a different model.
    # Upper bound on savings -- a smaller model may need more turns to reach the
    # same result, and this holds turn count fixed. Never present as free.
    if args.counterfactual:
        print(f"\nCounterfactual: same tokens, different model "
              f"(upper bound -- assumes equal turn count)")
        print(f"  {'swap to':<20} {'kWh':>10} {'vs now':>9} {'$':>11} {'saved':>11}")
        for target in ("claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"):
            wh = usd = 0.0
            for r in rows:
                alt = dict(r, model=target)
                wh += energy_wh(alt, energy, tiers) or 0
                usd += cost_usd(alt, prices, mult) or 0
            print(f"  {target:<20} {wh / 1000:>10,.1f} {wh / total_wh:>8.2f}x "
                  f"{usd:>11,.2f} {total_usd - usd:>11,.2f}")

    # Cache reads are billed at 0.1x and skip prefill; cache WRITES re-pay full
    # prefill at a 1.25-2x price premium. A low ratio means cache churn.
    cr = tok["cacheRead"]
    denom = cr + tok["cacheWrite"] + tok["input"]
    print(f"\nCache efficiency: {100.0 * cr / denom:.1f}% of prompt tokens served "
          f"from cache ({tok['cacheWrite'] / 1e6:,.0f}M written, "
          f"{cr / 1e6:,.0f}M read)")

    print("\nTop projects by estimated energy")
    for p, b in sorted(by_project.items(), key=lambda kv: -kv[1]["wh"])[:8]:
        print(f"  {p:<40} {b['wh'] / 1000:>8,.1f} kWh  ${b['usd']:>9,.2f}")

    if args.json_out:
        payload = {
            "generated": "prototype.py",
            "root": args.root,
            "limit": args.limit,
            "stats": stats,
            "uniqueRequests": len(rows),
            "tokens": tok,
            "totals": {"wh": total_wh, "whLo": lo, "whHi": hi, "usd": total_usd},
            "byModel": {k: dict(v) for k, v in by_model.items()},
            "byProject": {k: dict(v) for k, v in by_project.items()},
            "byDay": {k: dict(v) for k, v in by_day.items()},
            "unknownModels": sorted(unknown_models),
        }
        with open(args.json_out, "w") as f:
            json.dump(payload, f, indent=1, sort_keys=True)
        print(f"\nwrote {args.json_out}")


if __name__ == "__main__":
    main()
