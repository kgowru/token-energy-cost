# AgentSpend

A macOS menu bar app that turns your Claude Code token spend into estimated
electricity and actual dollars, so "switch to a cheaper model" becomes a
quantified decision instead of a hunch.

Reads `~/.claude/projects` directly. No API keys, no network, fully offline.

```
./build-app.sh          # build build/AgentSpend.app
open build/AgentSpend.app
```

Native Swift, zero external dependencies (SQLite comes from the system). ~1 MB
bundle, 0% CPU at idle. A tool that burns power to report power would undercut
its own premise.

## What it shows

| Pane | |
|---|---|
| **Home** | Day-by-day cost and energy over 1/14/30/90 days and today against your own daily average, then the one or two things worth acting on, scoped to *today*, so it speaks to the work still running |
| **Sessions** | Recent sessions: project, branch, model, cost, and context size; hourly breakdown |
| **Savings** | The same recommender over your whole history: ranked, quantified changes to how you work, each with its evidence and its caveat |
| **Method** | Per-model baseline, every coefficient with its band and source, and the one slider that matters. Reached from the link in the footer, not the tab bar. It's read once, not lived in |

## The honest caveat

**No frontier vendor publishes per-token energy. Anthropic publishes nothing at
all.** Every Claude energy figure in circulation, including this one, is
third-party modeling. Measured energy for the same model on the same GPU varies
~100× between naive and optimized serving.

So the app leads with **cost** (exact arithmetic on published rates) and
**relative** model comparisons (robust, because the shared serving-efficiency
unknowns largely cancel), and presents absolute Wh as a banded estimate with its
sources shown.

Coefficients are anchored to the three independent measurements that converge on
~0.3 Wh for a median frontier query: Google's Gemini disclosure (0.24 Wh),
Microsoft's peer-reviewed *Joule* study (0.31 Wh), and Epoch AI's GPT-4o model
(0.30 Wh). Those are then scaled by tier. See the Method pane for the full list.

**The dominant uncertainty is `cacheReadFactor`.** Cache reads are ~95% of local
Claude Code token volume, so whether a cache hit costs 10% or 1% of a fresh
input token swings the total ~4.7×. There is no published energy measurement of
a prompt-cache hit. The 10% price discount is a billing decision, not a
measured ratio. It's a slider in the Method pane rather than a buried constant.

## Ingestion, and why it's fussy

Four things that are easy to get wrong, each verified against the real corpus:

1. **Dedup on `message.id`, keeping max `output_tokens`.** ~52% of usage rows
   are repeats: a streaming message is logged many times with a *partial* output
   count. First-wins keeps the partial and undercounts total output by **12.6%**.
   Output is the priciest (5×) and most energy-intensive (4×) token class. Every
   non-output field is identical across repeats (0 conflicts of 21,782 ids),
   which is what makes max-output provably safe. `requestId` can't be the key:
   it's missing on `<synthetic>` rows.
2. **Walk recursively.** Sessions live at `<project>/<session>.jsonl`, but
   subagent transcripts nest at `<project>/<session>/subagents/agent-*.jsonl`. A
   one-level glob finds 143 of 623 files: **77% missing**.
3. **Normalize dated model IDs.** IDs appear as both `claude-haiku-4-5` and
   `claude-haiku-4-5-20251001`. Unnormalized, dated rows match no coefficient
   and are silently counted as zero. An unmatched model is now a loud banner.
4. **Buffer partial trailing lines.** Logs are appended to live, so a read can
   land mid-line.

Steady state reads only appended bytes, and the FSEvents watcher passes the
changed paths through so a refresh touches only those files rather than
re-stat'ing all ~600 logs.

## A layout trap worth knowing about

`MenuBarExtra` proposes its own height during layout, and a `ScrollView` under
`maxHeight` can resolve that proposal to zero. The popover then renders its
chrome and nothing else. This shipped once. The fix is a fully concrete `.frame(width:
420, height: 540)` on the root, which no proposal can collapse.

Worth knowing because **none of the offscreen checks caught it**: `ImageRenderer`
proposes a concrete size, and `NSHostingController.fittingSize` asks for the
ideal size, so both reported a healthy 535pt for the broken layout. Only the
live popover shows it. `LayoutProbe` writes the real laid-out size to
`~/Library/Application Support/AgentSpend/layout-probe.txt` on first open, so
it can be checked without a screenshot.

`ImageRenderer` also can't rasterize `ScrollView` children or interactive
controls, which is why `--render` snapshots each pane standalone as well as
hosted. The standalone shots verify content, the hosted ones verify layout.

## Performance, and the token question

**The analytics cost zero tokens.** Every figure (day-by-day history, per-session
summaries, the ranked recommendations) is local arithmetic over the SQLite
store in Swift. Nothing here calls an LLM. The app reads Claude Code's logs; it
never talks to the API. So "burning tokens to create the analytics" can't
happen by construction.

What *can* cost is CPU, and the Insights pane originally did. It took ~2.7s to
open on a ~23k-record corpus. Two bugs, both found with `--bench`:

- `Recommender.build` accumulated rows into a dictionary of tuples and appended
  to an array pulled out by value, forcing a full copy-on-write of the array
  every iteration: **O(n²)**, ~2,600ms of the 2,700. Fixed by grouping with
  in-place appends (`dict[k, default: []].append`): **9ms**.
- `EnergyModel.tier(for:)` rebuilt a lookup dictionary on every call, and it's
  called once per record in every pass, or ~100k rebuilds per render. The
  `Estimator` now builds the tier and entry lookups once at init.

Full Insights compute: **2,681ms → 61ms** (42×). On top of that, the derived
products are **memoized against a data-version counter**, so a pane that's open
while you work recomputes only when new usage rows actually land. An incidental
redraw (the refresh spinner toggling, the "updated" timestamp) is a **0ms** memo
hit. `--bench` prints the cold and memo numbers.

**Refresh cadence:** the FSEvents watcher coalesces file changes over 2s and
re-ingests only the changed files (not a full rescan), with a 60s timer as a
backstop. A refresh bumps the data-version only when it actually merges new
rows, so the memo survives no-op refreshes.

## Verifying

```
./.build/release/AgentSpend --selftest        # 61 assertions
./.build/release/AgentSpend --verify [root]   # aggregates, diffable vs the oracle
./.build/release/AgentSpend --render <dir>    # render each pane to PNG
./.build/release/AgentSpend --window [--tab method]   # views in a normal window
./.build/release/AgentSpend --bench           # time the derived analytics (cold + memo)
```

`tools/prototype.py` is an independent Python implementation of the same parse
and model, and is the reference the Swift ingestor is checked against. On a
frozen snapshot the two agree exactly, to the token and the cent:

```
python3 tools/prototype.py --root /tmp/snap
./.build/release/AgentSpend --verify /tmp/snap
```

`tools/verify.py` asserts the dedup and idempotence properties against the live
corpus from a separate code path.

Tests are plain assertions in `--selftest` rather than XCTest because the
installed Xcode predates this macOS and its XCTest can't load; requiring an
Xcode reinstall to run the tests would be a bad trade.

## Not done

Codex ingestion, notifications for unusually hot sessions, and live grid carbon
via Electricity Maps.

Release builds are Developer ID signed and notarized (see `RELEASING.md`);
`build-app.sh` still ad-hoc signs for fast local iteration.
