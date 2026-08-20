# Releasing AgentSpend publicly

The signing + notarization gate is **already set up**: the project has a
**Developer ID Application** certificate (Kapil Gowru, team `B47QPRK3YN`) and a
stored `notarytool` credential profile named `AgentSpend`. Cutting a release is
now a single command; the sections below are the standing process, not a to-do
list. (The only recurring cost is the **Apple Developer Program**, $99/year;
notarization, GitHub hosting, and Homebrew are all free.)

## The path

The audience is Claude Code users, i.e. developers. That points to:

1. **Open-source on GitHub.** Done: the repo is public and MIT-licensed. Fits
   the app's whole ethos (the logic is meant to be readable and checkable) and
   lets developers build it themselves.
2. **Ship a notarized `.dmg` on GitHub Releases** for people who just want to
   download and run. `notarize.sh` (in this folder) produces it.
3. **Optionally add a Homebrew cask** so `brew install --cask agentspend`
   works. Homebrew requires the artifact be signed + notarized (step 2 covers
   it) and hosted at a stable URL (GitHub Releases covers it).

## What each step actually involves

### 1. Build the notarized DMG

The certificate and the `AgentSpend` credential profile are already in the login
keychain, so a release is one command:

```
DEVID="Developer ID Application: Kapil Gowru (B47QPRK3YN)" ./notarize.sh
```

It builds the universal app, signs it with the hardened runtime, packages a
`.dmg`, submits to Apple's notary service, and staples the ticket so it verifies
offline. Output: `build/AgentSpend.dmg`, ready to upload.

Confirm it before uploading:

```
spctl -a -vvv -t exec build/AgentSpend.app   # expect: accepted, source=Notarized Developer ID
xcrun stapler validate build/AgentSpend.dmg   # expect: The validate action worked!
```

**Re-doing the one-time setup** (new machine, expired cert): create a Developer
ID Application certificate (Xcode → Settings → Accounts, or the developer
portal) in the login keychain, then store the notary credential once:

```
xcrun notarytool store-credentials "AgentSpend" \
  --apple-id "k.gowru@gmail.com" --team-id "B47QPRK3YN" \
  --password "app-specific-password"    # make one at appleid.apple.com
```

### 2. GitHub Releases

- The repo is `github.com/kgowru/token-energy-cost` (public). **What's safe to
  publish:** it's clean. `build/`, the SQLite store, `.context/`, and any
  screenshots are gitignored, so none of *your* usage data (project names,
  dollar amounts) is committed. Re-check with `git status` before any push that
  might add a screenshot.
- Tag a version and attach the notarized DMG. From the **repo root** (the DMG
  lives under `mac/`, the notes at root):
  ```
  git tag v0.1.0 && git push origin v0.1.0
  gh release create v0.1.0 mac/build/AgentSpend.dmg \
    --title "AgentSpend v0.1.0" --notes-file RELEASE_NOTES.md
  ```

### 3. Homebrew cask (optional, developer-friendly)

- A cask is a small Ruby file pointing at the release URL + SHA256. You can host
  your own tap (`brew tap you/agentspend`) immediately, or PR the main
  `homebrew-cask` repo (has an acceptance bar: notarized, some notability).

## Not recommended: the Mac App Store

The App Store requires **sandboxing**, and a sandboxed app **cannot read
`~/.claude/projects`** (the exact thing this app depends on) without the user
manually granting folder access via a security-scoped bookmark on every launch,
plus App Review overhead and a different certificate. The direct-download +
Homebrew route avoids all of that. Skip the App Store unless you specifically
want its discovery.

## Things a public release will get asked about, and where you stand

- **"Are the energy numbers real?"** They're *estimates*, and the app is already
  built to say so. The Method tab shows every coefficient, its band, and its
  sources, and the app leads with exact **cost** and *relative* comparisons. Own
  this in the README; it's a strength, not a liability. Lead with "estimated."
- **"Does it phone home?"** No. Zero network calls, everything is local. Say
  this loudly; it's a real selling point.
- **Affiliation.** It reads Claude Code's logs but isn't affiliated with
  Anthropic. Don't use Claude/Anthropic logos; add a one-line "not affiliated"
  note.

## The real maintenance cost

Anthropic ships new models and changes prices. Today a brand-new model shows a
loud "no coefficients, counted as zero" banner until you update
`pricing.json` / `energy-model.json` and cut a new release. Two ways to soften
this before a public launch (ask me to build either):

- **Graceful fallback:** guess a new model's tier from its name (`*opus*` →
  frontier-large, etc.) and label the estimate "assumed," instead of zero.
- **Remote coefficients:** fetch the two JSON files from a URL at launch so you
  can update pricing without shipping an app update. (This adds the app's first
  network call. Weigh it against the "100% local" promise.)

## Nice-to-have later

- **Auto-update** via [Sparkle](https://sparkle-project.org) (appcast + EdDSA
  signing). Standard for Mac apps outside the App Store; adds one dependency.
- **A landing page** (even just the README with screenshots) and an app icon.
  Right now the menu bar uses an SF Symbol and there's no `.icns`.
