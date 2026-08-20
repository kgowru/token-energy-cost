<div align="center">

<img src="mac/assets/icon-1024.png" alt="AgentSpend" width="128" height="128" />

# AgentSpend

**A macOS menu bar app that shows what your Claude Code usage costs and an estimate of the electricity behind it. Updated live as you work.**

So "switch to a cheaper model" becomes a decision you can put a number on, instead of a hunch.

[Download](https://github.com/kgowru/token-energy-cost/releases/latest) · [Why I built it](content/blog/why-i-built-agentspend.md) · [The energy method](#how-much-to-trust-these-numbers)

</div>

<!-- A UI screenshot belongs here. None is committed yet because every capture
     to date contains real project names and dollar figures. Add a sanitized
     one before or just after going public. -->

---

## What it is

AgentSpend reads Claude Code's own local logs at `~/.claude/projects` and shows
what your usage costs, in money and in estimated electricity. It runs entirely
on your Mac: **no API keys, no account, no network calls.** It picks up your
usage automatically and updates while you work.

Native Swift, zero external dependencies (SQLite comes from the system). A ~1 MB
universal binary that sits at 0% CPU when idle. A tool that burns power to
report power would be a bad joke.

## Install

1. Download **`AgentSpend.dmg`** from the [latest release](https://github.com/kgowru/token-energy-cost/releases/latest).
2. Open it, drag **AgentSpend** into **Applications**, and launch it.

That's it. The app is signed with an Apple Developer ID and notarized by Apple,
so it opens without any Gatekeeper warning.

It appears as a **⚡ menu bar item** showing today's cost. There's no Dock icon
and no window. Click it for the panes below; the ⚡/$ button at the bottom of the
popover swaps the menu bar between cost and energy. Quit from there too.

## What it shows

| Pane | |
|---|---|
| **Home** | Cost and energy over 1/14/30/90 days, today against your own daily average, then the one or two things worth acting on, limited to today so it speaks to the work still running |
| **Sessions** | Recent sessions: project, branch, model, cost, and context size, plus an hourly breakdown |
| **Savings** | The same analysis over your whole history: ranked, quantified changes to how you work, each with its evidence and its caveat |
| **Method** | Per-model baseline, every coefficient with its range and source, and the one slider that matters. Reached from the footer link |

## How much to trust these numbers

**The dollars are exact. The energy is an estimate.**

No AI company publishes how much power a token takes. So every energy figure
you'll see anywhere, including this one, is an estimate.

This estimate is built on the three best public measurements available (Google's
median Gemini prompt at 0.24 Wh, Microsoft's peer-reviewed 0.31 Wh, Epoch AI's
~0.3 Wh for GPT-4o), which land close enough to each other to be worth trusting.
Use the energy side to compare one model against another, not as a meter reading.

The **Method** pane shows every number the estimate uses, its range, and where it
came from, and lets you drag the single assumption that moves the total most. The
full reasoning is in the [blog post](content/blog/why-i-built-agentspend.md).

## Build from source

Requires a recent macOS and the Swift toolchain (no Xcode project needed).

```bash
cd mac
./build-app.sh              # build build/AgentSpend.app (ad-hoc signed, runs locally)
open build/AgentSpend.app
```

Checks you can run:

```bash
./.build/release/AgentSpend --selftest   # 61 assertions
./.build/release/AgentSpend --verify     # aggregates, diffable against the Python oracle
./.build/release/AgentSpend --render <dir>   # render each pane to PNG
./.build/release/AgentSpend --window     # the panes in an ordinary window
```

`tools/prototype.py` is an independent Python implementation of the same parse
and model. It's the reference the Swift ingestor is checked against. On a frozen
snapshot the two agree exactly, to the token and the cent.

## Repository layout

This is a monorepo:

- **`mac/`**: the Swift menu bar app (see [`mac/README.md`](mac/README.md) for
  architecture, and [`mac/RELEASING.md`](mac/RELEASING.md) for how releases are cut).
- **`src/`, `content/`, `public/`**: the Next.js landing site and blog.
- **`tools/`**: the Python reference implementation and verification scripts.

## Privacy

AgentSpend makes **zero network calls**. It reads only your local Claude Code
logs and writes a small local database at
`~/Library/Application Support/AgentSpend/`. Nothing leaves your machine.

## Not affiliated with Anthropic

AgentSpend reads logs that Claude Code writes locally, but it is an independent
project and is not affiliated with, endorsed by, or sponsored by Anthropic.

## License

[MIT](LICENSE) © 2026 Kapil Gowru
