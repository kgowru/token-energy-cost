# AgentSpend — for the person who sent you this

A tiny menu bar app that shows what your Claude Code usage is costing — in
dollars and in estimated electricity. It runs entirely on your Mac, reads only
your local Claude Code logs, and never sends anything anywhere.

## Install (about 30 seconds)

1. **Open** `AgentSpend.dmg` (double-click it).
2. Drag **AgentSpend** into your **Applications** folder.
3. Launch it.

That's all. The app is signed with an Apple Developer ID and notarized by Apple,
so it opens with no Gatekeeper warning and no Terminal steps.

It appears as a **⚡ menu bar item** showing today's energy — no Dock icon, no
window. Click it for Home / Sessions / Savings, with Method in the footer. Quit
from the bottom of the popover.

## It only shows something if you use Claude Code

The app reads `~/.claude/projects` — the logs Claude Code writes locally. If you
don't use Claude Code, or have no history there, it'll be empty. Nothing to
configure; it picks up your usage automatically and updates live.

## Two honest caveats

- **The dollars are exact; the energy is an estimate.** No AI vendor publishes
  per-token energy, so the Wh figures are modelled from public measurements and
  carry a wide band. The app is upfront about this — see its **Method** pane. Use
  the energy side for *relative* comparisons (this model vs that one), not as a
  precise meter.
- **It's independent, not an Anthropic product.** It reads Claude Code's local
  logs but isn't affiliated with Anthropic. It makes no network calls — the
  bundle is just the app and two small reference data files. If you'd rather
  build it yourself, the source is public (ask whoever sent this for the link).

## Uninstall

Drag `AgentSpend.app` to the Trash. It keeps a small local database at
`~/Library/Application Support/AgentSpend/` — delete that folder too if you want
it fully gone.
