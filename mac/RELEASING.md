# Releasing AgentSpend publicly

The one hard requirement is **notarization** — without it, everyone who
downloads the app hits Gatekeeper and most bounce. Notarization needs an
**Apple Developer Program** membership: **$99/year**. That's the only cost.
Everything else (notarization itself, hosting, Homebrew) is free.

## The recommended path

Your audience is Claude Code users — i.e. developers. That points to:

1. **Open-source it on GitHub.** Fits the app's whole ethos (the logic is meant
   to be readable and checkable), lets developers build it themselves, and is
   the cheapest way to reach this audience. Needs a `LICENSE` (MIT or Apache-2.0
   are the usual picks).
2. **Ship a notarized `.dmg` on GitHub Releases** for people who just want to
   download and run. `notarize.sh` (in this folder) produces it.
3. **Optionally add a Homebrew cask** so `brew install --cask agentspend`
   works. Homebrew requires the artifact be signed + notarized (step 2 covers
   it) and hosted at a stable URL (GitHub Releases covers it).

## What each step actually involves

### 1. Apple Developer + notarization (the gate)

- Join at developer.apple.com → **$99/year**.
- Create a **Developer ID Application** certificate (Xcode → Settings →
  Accounts, or the developer portal), installed in your login keychain.
- Store notarization credentials once:
  ```
  xcrun notarytool store-credentials "AgentSpend" \
    --apple-id "you@example.com" --team-id "YOURTEAMID" \
    --password "app-specific-password"    # make one at appleid.apple.com
  ```
- Then every release is one command:
  ```
  DEVID="Developer ID Application: Your Name (TEAMID)" ./notarize.sh
  ```
  It builds the universal app, signs it with the hardened runtime, packages a
  `.dmg`, submits to Apple's notary service, and staples the ticket so it
  verifies offline. Output: `build/AgentSpend.dmg`, ready to upload.

### 2. GitHub Releases

- Create a public repo. **What's safe to publish:** the repo is already clean —
  `build/`, the SQLite store, `.context/`, and any screenshots are gitignored,
  so none of *your* usage data (project names, dollar amounts) would be
  committed. Double-check with `git status` before the first push.
- Tag a version, attach `AgentSpend.dmg` to the release.

### 3. Homebrew cask (optional, developer-friendly)

- A cask is a small Ruby file pointing at the release URL + SHA256. You can host
  your own tap (`brew tap you/agentspend`) immediately, or PR the main
  `homebrew-cask` repo (has an acceptance bar: notarized, some notability).

## Not recommended: the Mac App Store

The App Store requires **sandboxing**, and a sandboxed app **cannot read
`~/.claude/projects`** — the exact thing this app depends on — without the user
manually granting folder access via a security-scoped bookmark on every launch,
plus App Review overhead and a different certificate. The direct-download +
Homebrew route avoids all of that. Skip the App Store unless you specifically
want its discovery.

## Things a public release will get asked about — and where you stand

- **"Are the energy numbers real?"** They're *estimates*, and the app is already
  built to say so — the Method tab shows every coefficient, its band, and its
  sources, and the app leads with exact **cost** and *relative* comparisons. Own
  this in the README; it's a strength, not a liability. Lead with "estimated."
- **"Does it phone home?"** No — zero network calls, everything is local. Say
  this loudly; it's a real selling point.
- **Affiliation.** It reads Claude Code's logs but isn't affiliated with
  Anthropic. Don't use Claude/Anthropic logos; add a one-line "not affiliated"
  note.

## The real maintenance cost

Anthropic ships new models and changes prices. Today a brand-new model shows a
loud "no coefficients — counted as zero" banner until you update
`pricing.json` / `energy-model.json` and cut a new release. Two ways to soften
this before a public launch (ask me to build either):

- **Graceful fallback:** guess a new model's tier from its name (`*opus*` →
  frontier-large, etc.) and label the estimate "assumed," instead of zero.
- **Remote coefficients:** fetch the two JSON files from a URL at launch so you
  can update pricing without shipping an app update. (This adds the app's first
  network call — weigh it against the "100% local" promise.)

## Nice-to-have later

- **Auto-update** via [Sparkle](https://sparkle-project.org) (appcast + EdDSA
  signing). Standard for Mac apps outside the App Store; adds one dependency.
- **A landing page** (even just the README with screenshots) and an app icon —
  right now the menu bar uses an SF Symbol and there's no `.icns`.
