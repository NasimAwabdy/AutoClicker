# AutoClicker for macOS

A native Swift/SwiftUI clone of [OP Auto Clicker](https://www.opautoclicker.com/) with added
**anti-bot-detection randomization**.

## Features (parity with OP Auto Clicker)

- **Click interval** — hours / mins / secs / milliseconds
- **Mouse button** — left, right, or middle click
- **Click type** — single, double, or triple clicking
- **Click repeat** — repeat N times, or repeat until stopped (infinite)
- **Cursor position** — click at your dynamic cursor location, or a prespecified fixed
  location (use *Pick location*: a 3-second countdown, then it captures wherever your mouse is)
- **Changeable global hotkey** — default **F6** to start/stop; works in the background
  even when the app isn't focused. Click *Hotkey setting* and press any key
  (with optional ⌘⌥⌃⇧ modifiers); Esc cancels.
- **Settings saved** — every option (including the last fixed location and hotkey)
  persists across sessions

## Anti-detection additions

- **Vary click interval** — adds a random ± offset (in ms) to every click delay:
  - *Uniform* — evenly distributed within the range
  - *Human-like* — right-skewed (log-normal) distribution: clicks cluster near
    the base interval with an occasional slow tail but no impossibly fast
    outliers, and the base rhythm itself drifts slowly over the session
    (mean-reverting random walk), so delays are autocorrelated like real
    human clicking rather than statistically independent
- **Jitter click position** — randomly offsets each click by ± N pixels so clicks
  don't land on the exact same coordinate every time
- **Randomized hold time** — holds the button for a random, right-skewed
  duration between mousedown and mouseup (real clicks last ~50–150 ms and
  cluster toward the short end; a ~0 ms press duration on every click is an
  easy bot giveaway). Hold time is absorbed into the click interval, so the
  configured click rate is unaffected
- **Random pauses** — occasionally stops clicking for a random duration, at
  randomized intervals (measured in clicks, seconds, or minutes), like a human
  taking a break

## Install

One command installs the latest [release](https://github.com/NasimAwabdy/AutoClicker/releases)
to `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/NasimAwabdy/AutoClicker/main/install.sh | bash
```

**Updates are offered in-app:** on launch, AutoClicker checks GitHub Releases
and shows a banner with an *Update Now* button when a newer version exists.
You can also update manually by re-running the install command above.

Releases are ad-hoc signed rather than Apple-notarized, so the script removes
macOS's quarantine flag after download — feel free to read
[`install.sh`](install.sh) before running it. After every install or update,
macOS asks you to re-grant Accessibility permission (the code signature changes
with each build).

## Build from source

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh    # builds and installs /Applications/AutoClicker.app
```

## Releasing (maintainers)

Push a version tag and GitHub Actions builds the app, stamps the version into
Info.plist, and publishes a GitHub Release with `AutoClicker.zip` attached:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

## First launch

macOS requires **Accessibility** permission to post synthetic mouse clicks.
On first launch you'll be prompted — enable AutoClicker under
**System Settings → Privacy & Security → Accessibility**, then relaunch the app.
(The global hotkey works without any permission.)

## Project layout

```
AutoClicker/
├── build.sh                     # builds build/AutoClicker.app
├── Info.plist
└── Sources/
    ├── AutoClickerApp.swift     # app entry, accessibility prompt
    ├── ContentView.swift        # UI + persisted settings
    ├── ClickEngine.swift        # click loop, CGEvent posting, randomization
    └── HotKeyManager.swift      # global hotkey (Carbon), hotkey recording
```
