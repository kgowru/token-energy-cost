## AgentSpend v0.1.1

The menu bar now leads with **cost** instead of energy.

### What changed

- The menu bar item shows today's dollar figure by default. The ⚡/$ button at
  the bottom of the popover still swaps it back to watt-hours whenever you want.

This only affects fresh installs. If you've ever used that toggle, AgentSpend
keeps showing whichever metric you picked.

### Install

Download **`AgentSpend.dmg`** below, open it, and drag AgentSpend to
Applications. The app is signed with an Apple Developer ID and notarized by
Apple, so it opens with no Gatekeeper warning. Universal binary (Apple Silicon
+ Intel), ~3 MB.

Reads `~/.claude/projects`; it's empty until you've used Claude Code.

Upgrading from v0.1.0: just replace the copy in Applications. Your history lives
in the Claude Code logs rather than in the app, so there's nothing to migrate.

### How much to trust these numbers

Unchanged from v0.1.0. The dollars are exact. The energy is an estimate, built on
the best public measurements available. Use it to compare one model against
another, not as a meter reading. The Method pane shows all the workings.

Makes zero network calls. Independent project, not affiliated with Anthropic.
