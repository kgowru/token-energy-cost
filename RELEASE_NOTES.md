## AgentSpend v0.1.0

First public release. A macOS menu bar app that turns your Claude Code token
spend into two numbers — actual dollars and estimated watt-hours — read live
from your local logs, entirely offline.

### Install

Download **`AgentSpend.dmg`** below, open it, and drag AgentSpend to
Applications. The app is signed with an Apple Developer ID and notarized by
Apple, so it opens with no Gatekeeper warning. Universal binary (Apple Silicon
+ Intel), ~3 MB.

Reads `~/.claude/projects`; it's empty until you've used Claude Code.

### What's in it

- **Home** — today's cost and energy, day-by-day history over 1/14/30/90 days,
  and the one or two things worth acting on *today*.
- **Sessions** — recent sessions with project, branch, model, cost, and context
  size, plus an hourly breakdown.
- **Savings** — the same analysis over your whole history: ranked, quantified
  changes to how you work, each with its evidence and its caveat.
- **Method** — every energy coefficient with its band and source, and the one
  assumption that moves the total most, as a slider you can drag.

### The honest caveat

The dollars are exact; the energy is a modelled estimate anchored to public,
production-grade measurements and carrying a wide band. Use it for relative
comparisons, not as a precise meter. The Method pane shows all the workings.

Makes zero network calls. Independent project, not affiliated with Anthropic.
