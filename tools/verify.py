#!/usr/bin/env python3
"""Verification suite for the Phase 0 oracle.

Independent code path from prototype.py — deliberately re-derives everything
rather than importing the aggregation logic, so a bug in one doesn't hide in
the other. Checks the assumptions dedup rests on:

  1. Dedup integrity  — does any message.id carry two DIFFERENT usage payloads?
                        If so, dedup is discarding real requests.
  2. Duplicate shape  — are duplicates within one file, or across files?
  3. Idempotence      — parsing twice yields identical totals.
  4. Spot-check cost  — recompute one session by hand against published rates.
"""

import glob
import json
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from prototype import (DEFAULT_ROOT, SYNTHETIC, cost_usd, load_resources,  # noqa: E402
                       normalize_model, parse)

FAIL = []


def check(label, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f"  {detail}" if detail else ""))
    if not ok:
        FAIL.append(label)


def main():
    energy, pricing, tiers, prices = load_resources()
    mult = pricing["cacheMultipliers"]

    # Raw scan, independent of prototype.parse
    payloads = defaultdict(set)      # message.id -> set of usage fingerprints
    stable = defaultdict(set)        # message.id -> non-output fields only
    files_for_id = defaultdict(set)  # message.id -> set of files
    max_out = defaultdict(int)       # message.id -> max output_tokens seen
    first_out = {}                   # message.id -> first output_tokens seen
    raw = 0
    for path in sorted(glob.glob(os.path.join(DEFAULT_ROOT, "**", "*.jsonl"),
                                 recursive=True)):
        with open(path, errors="ignore") as fh:
            for line in fh:
                if '"usage":{' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                m = d.get("message")
                if not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
                    continue
                if m.get("model") == SYNTHETIC:
                    continue
                raw += 1
                mid = m.get("id") or d.get("requestId")
                u = m["usage"]
                fp = (u.get("input_tokens"), u.get("output_tokens"),
                      u.get("cache_creation_input_tokens"),
                      u.get("cache_read_input_tokens"), m.get("model"))
                payloads[mid].add(fp)
                stable[mid].add((u.get("input_tokens"),
                                 u.get("cache_creation_input_tokens"),
                                 u.get("cache_read_input_tokens"), m.get("model")))
                o = u.get("output_tokens") or 0
                max_out[mid] = max(max_out[mid], o)
                first_out.setdefault(mid, o)
                files_for_id[mid].add(path)

    print("1. Dedup integrity")
    # A streaming message is logged repeatedly with a growing output_tokens, so
    # payloads DO conflict by design. What must never conflict is everything
    # else -- that is what makes "keep the row with max output_tokens" sound.
    unstable = {k: v for k, v in stable.items() if len(v) > 1}
    check("non-output fields never conflict for a given message.id",
          not unstable, f"{len(unstable)} conflicts of {len(payloads):,} ids")
    for k, v in list(unstable.items())[:3]:
        print(f"       {k}: {v}")

    streaming = sum(1 for k, v in payloads.items() if len(v) > 1)
    under = sum(max_out.values()) - sum(first_out.values())
    check("max-output dedup recovers the streaming undercount", under > 0,
          f"{streaming:,} streamed ids; first-wins would lose {under:,} output "
          f"tokens ({100.0 * under / max(sum(max_out.values()), 1):.1f}%)")

    print("\n2. Duplicate shape")
    cross = sum(1 for v in files_for_id.values() if len(v) > 1)
    dupes = raw - len(payloads)
    check("duplicates exist and are accounted for", dupes > 0,
          f"{dupes:,} dupes over {raw:,} raw rows ({100.0 * dupes / raw:.1f}%)")
    print(f"       ids appearing in >1 file: {cross:,} "
          f"({100.0 * cross / max(len(payloads), 1):.1f}%) "
          f"-- cross-file dupes mean parent sessions re-log subagent turns")

    print("\n3. Idempotence")
    a, sa = parse(DEFAULT_ROOT)
    b, sb = parse(DEFAULT_ROOT)
    check("two parses agree on row count", len(a) == len(b), f"{len(a):,} vs {len(b):,}")
    ta = sum(r["input"] + r["output"] + r["cacheRead"] + r["cacheWrite"] for r in a)
    tb = sum(r["input"] + r["output"] + r["cacheRead"] + r["cacheWrite"] for r in b)
    check("two parses agree on total tokens", ta == tb, f"{ta:,}")
    check("parse output matches independent raw scan", len(a) == len(payloads),
          f"parse={len(a):,} rawscan={len(payloads):,}")
    pa = sum(r["output"] for r in a)
    check("parse keeps the completed (max) output count per message",
          pa == sum(max_out.values()),
          f"parse={pa:,} rawscan_max={sum(max_out.values()):,}")

    print("\n4. Every model resolves to coefficients")
    seen_models = {r["model"] for r in a}
    unpriced = {m for m in seen_models if m not in prices}
    unenergied = {m for m in seen_models if m not in tiers}
    check("all observed models have pricing", not unpriced, str(sorted(unpriced)))
    check("all observed models have energy coefficients", not unenergied,
          str(sorted(unenergied)))

    print("\n5. Cost spot-check (hand-computed vs cost_usd)")
    row = max(a, key=lambda r: r["output"])
    p = prices[row["model"]]
    w5, w1h = row["cacheWrite5m"], row["cacheWrite1h"]
    write = (w5 * mult["write5m"] + w1h * mult["write1h"]) if (w5 + w1h) else \
        row["cacheWrite"] * mult["write5m"]
    hand = (row["input"] * p["input"] + write * p["input"]
            + row["cacheRead"] * p["input"] * mult["read"]
            + row["output"] * p["output"]) / 1_000_000.0
    got = cost_usd(row, prices, mult)
    check("hand-computed cost matches cost_usd", abs(hand - got) < 1e-12,
          f"{row['model']}: ${got:.6f}")

    print("\n6. Model ID normalization")
    check("dated IDs normalize to alias",
          normalize_model("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
    check("alias IDs are unchanged",
          normalize_model("claude-opus-4-8") == "claude-opus-4-8")
    check("no dated IDs survive into parsed rows",
          not any(m and m[-9] == "-" and m[-8:].isdigit() for m in seen_models),
          str(sorted(seen_models)))

    print("\n" + ("ALL CHECKS PASSED" if not FAIL else f"FAILED: {FAIL}"))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
