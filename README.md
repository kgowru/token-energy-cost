<div align="center">

<img src="mac/assets/icon-1024.png" alt="AgentSpend" width="128" height="128" />

# AgentSpend

**A macOS menu bar app that turns your Claude Code token spend into two honest numbers — actual dollars and estimated watt-hours — updated live as you work.**

So "switch to a cheaper model" becomes a quantified decision instead of a hunch.

[Download](https://github.com/kgowru/token-energy-cost/releases/latest) · [Why I built it](content/blog/why-i-built-agentspend.md) · [The energy method](#the-honest-caveat)

</div>

<!-- A UI screenshot belongs here. None is committed yet because every capture
     to date contains real project names and dollar figures — add a sanitized
     one before or just after going public. -->

---

## What it is

AgentSpend reads Claude Code's own local logs at `~/.claude/projects` and shows
what your usage costs — in money and in modelled electricity. It runs entirely
on your Mac: **no API keys, no account, no network calls.** It picks up your
usage automatically and updates while you work.

Native Swift, zero external dependencies (SQLite comes from the system). A ~1 MB
universal binary that sits at 0% CPU when idle — a tool that burned power to
report power would undercut its own premise.

## Install

1. Download **`AgentSpend.dmg`** from the [latest release](https://github.com/kgowru/token-energy-cost/releases/latest).
2. Open it, drag **AgentSpend** into **Applications**, and launch it.

That's it. The app is signed with an Apple Developer ID and notarized by Apple,
so it opens without any Gatekeeper warning.

It appears as a **⚡ menu bar item** showing today's energy — no Dock icon, no
window. Click it for the panes below; quit from the bottom of the popover.

## What it shows

| Pane | |
|---|---|
| **Home** | Cost and energy over 1/14/30/90 days, today against your own daily average, then the one or two things worth acting on — scoped to *today*, so it speaks to the work still running |
| **Sessions** | Recent sessions — project, branch, model, cost, and context size; hourly breakdown |
| **Savings** | The same recommender over your whole history: ranked, quantified changes to how you work, each with its evidence and its caveat |
| **Method** | Per-model baseline, every coefficient with its band and source, and the one slider that matters. Reached from the footer link |

## The honest caveat

**The dollars are exact; the energy is an estimate.** No frontier AI vendor
publishes per-token energy — Anthropic publishes nothing at all — so every
Claude energy figure in circulation, including this one, is third-party
modelling that carries a wide band.

AgentSpend is built to say so. The model is anchored to three converging,
production-grade public measurements (Google's median Gemini prompt at 0.24 Wh,
Microsoft's peer-reviewed 0.31 Wh median, Epoch AI's ~0.3 Wh for GPT-4o), then
scaled by tier. The **Method** pane shows every coefficient, its band, and its
source, and lets you drag the single assumption that moves the total most. Use
the energy side for *relative* comparisons (this model vs. that one), not as a
precise meter. The full reasoning is in the [blog post](content/blog/why-i-built-agentspend.md).

## Build from source

Requires a recent macOS and the Swift toolchain (no Xcode project needed).

```bash
cd mac
./build-app.sh              # build build/AgentSpend.app (ad-hoc signed, runs locally)
open build/AgentSpend.app
```

Verification harnesses:

```bash
./.build/release/AgentSpend --selftest   # 61 assertions
./.build/release/AgentSpend --verify     # aggregates, diffable against the Python oracle
./.build/release/AgentSpend --render <dir>   # render each pane to PNG
./.build/release/AgentSpend --window     # the panes in an ordinary window
```

`tools/prototype.py` is an independent Python implementation of the same parse
and model — the reference the Swift ingestor is checked against. On a frozen
snapshot the two agree exactly, to the token and the cent.

## Repository layout

This is a monorepo:

- **`mac/`** — the Swift menu bar app (see [`mac/README.md`](mac/README.md) for
  architecture, and [`mac/RELEASING.md`](mac/RELEASING.md) for how releases are cut).
- **`src/`, `content/`, `public/`** — the Next.js landing site and blog.
- **`tools/`** — the Python reference implementation and verification scripts.

## Privacy

AgentSpend makes **zero network calls**. It reads only your local Claude Code
logs and writes a small local database at
`~/Library/Application Support/AgentSpend/`. Nothing leaves your machine.

## Not affiliated with Anthropic

AgentSpend reads logs that Claude Code writes locally, but it is an independent
project and is not affiliated with, endorsed by, or sponsored by Anthropic.

## License

[MIT](LICENSE) © 2026 Kapil Gowru
