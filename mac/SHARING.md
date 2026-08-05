# AgentSpend — for the person who sent you this

A tiny menu bar app that shows what your Claude Code usage is costing — in
dollars and in estimated electricity. It runs entirely on your Mac, reads only
your local Claude Code logs, and never sends anything anywhere.

## Install (about 30 seconds)

1. **Unzip** `AgentSpend.zip` (double-click it).
2. Drag **AgentSpend.app** into your **Applications** folder.
3. **First launch is blocked by macOS** — this app isn't signed by an Apple
   Developer account, so Gatekeeper stops it the first time. Pick whichever
   works on your macOS:

   - **Double-click it, get the "cannot be opened" warning, then:**
     System Settings → **Privacy & Security** → scroll down → **"Open Anyway"**
     next to AgentSpend. Confirm once. (This is the normal path on recent macOS.)
   - **Or Terminal (most reliable):**
     ```
     xattr -dr com.apple.quarantine /Applications/AgentSpend.app
     ```
     then double-click.

   You only do this once. After that it opens normally.

It appears as a **⚡ menu bar item** showing today's energy — no Dock icon, no
window. Click it for History / Activity / Insights. Quit from the bottom of the
popover.

## It only shows something if you use Claude Code

The app reads `~/.claude/projects` — the logs Claude Code writes locally. If you
don't use Claude Code, or have no history there, it'll be empty. Nothing to
configure; it picks up your usage automatically and updates live.

## Two honest caveats

- **The dollars are exact; the energy is an estimate.** No AI vendor publishes
  per-token energy, so the Wh figures are modelled from public measurements and
  carry a wide band. The app is upfront about this — see its **Method** tab. Use
  the energy side for *relative* comparisons (this model vs that one), not as a
  precise meter.
- **It's not notarized by Apple.** That's the reason for the Gatekeeper step
  above. The bundle contains only the app and two small reference data files —
  no tracking, no network calls. If you'd rather build it yourself, the source
  is available (ask whoever sent this).

## Uninstall

Drag `AgentSpend.app` to the Trash. It keeps a small local database at
`~/Library/Application Support/AgentSpend/` — delete that folder too if you want
it fully gone.
