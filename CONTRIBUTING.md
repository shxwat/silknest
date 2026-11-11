# Contributing to SilkNest

Thanks for helping. SilkNest is a native macOS app: Swift, AppKit and SceneKit, no dependencies.

## Requirements

- A Mac with Apple silicon, macOS 14 Sonoma or later
- Xcode or the Command Line Tools (Swift 6 toolchain; the code builds in Swift 5 language mode)

## Build and run

```sh
./scripts/build-app.sh          # builds .build/SilkNest.app
open .build/SilkNest.app
```

Only one SilkNest runs at a time: quit an installed copy first (menu bar spider → Quit SilkNest).

### Signing

You don't need any certificate. `scripts/sign.sh` signs with the maintainer's "SilkNest Signing"
certificate only when it is in the keychain; otherwise it falls back to an **ad-hoc signature**, which is
all a local build needs:

```
bundle: app.silknest.dev
signed: ad-hoc (app.silknest.dev)
```

Builds without the certificate are **development builds** ("SilkNest Dev", bundle identifier
`app.silknest.dev`). They never touch an installed SilkNest:
- their own data folder (`~/Library/Application Support/SilkNest Dev`) and preferences,
- automatic updates are off,
- they can run next to the released app (you'll see two spiders; quit one).

macOS treats SilkNest Dev as its own app, so 1-click paste asks for Accessibility for it separately.
(`SILKNEST_DEV=1 ./scripts/build-app.sh` forces a development build even with the certificate.)

## Tests

```sh
./scripts/test-motion.sh        # spider motion checks + clipboard, storage, search, secrets, signing-free
./scripts/test-signing.sh       # signing transition checks (throwaway certificates in a temporary keychain)
./scripts/test-upgrade.sh       # history and notes written by the real 1.2.2 code open in this version (temp folder)
```

They run with the Command Line Tools; XCTest is not required. Please add a check for anything you fix or
add (see `Tests/WEBBERTests`). Tests never use your real clipboard, history or keychain.

Performance (development only; quits and relaunches SilkNest and briefly opens the Nest on screen):

```sh
zsh scripts/perf.sh
```

## Developer modes

Release builds ignore all of these (see `DevFlags` in `AppDelegate.swift`). They exist only in builds
compiled with `-DDEBUG` (`swift build -Xswiftc -DDEBUG`):

| Flag | What it does |
|---|---|
| `--study` | Spider Study window: motion replay and diagnostics |
| `--automation` | Verification channel (named commands over a distributed notification); uses a temporary data folder, never the real one, and never reports clipboard or screen content |
| `--web-check`, `--web-debug` | Physical web replay and diagnostics |
| `--render-preview`, `--species-preview`, `--sprite-sheet`, `--app-icon` | Render images into `artifacts/` and quit |

## Code style

- Follow the surrounding code: compact Swift, `final class` by default, no third-party dependencies.
- Comments explain *why* (and what the user sees), not what the next line does.
- User-facing text: short, plain English, no jargon.
- Privacy is a feature: nothing may leave the Mac except the update check; nothing sensitive may be
  logged, printed or written unencrypted. New stored data uses `HistoryStore`/`NoteStore` encryption,
  owner-only permissions and stays out of backups.
- One logical change per commit, with a message that says what changed for the user.

## Pull requests

Describe what changed and how you tested it (which checks, what you tried in the app). Screenshots or
a short screen recording help for anything visual — make sure they show no real clipboard content.

By contributing you agree that your contribution is licensed under the GPL-3.0 (see `LICENSE`).
