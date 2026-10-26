# Notes for coding agents

Read this before changing code. It's for AI coding agents (Claude Code, Codex, Cursor and others); people should read
[CONTRIBUTING.md](CONTRIBUTING.md), which says the same things at more length.

## What this is

DuoRemote: an iOS/iPadOS VNC client for macOS Screen Sharing, built for iPhone Duo (laptop pose, the fold) as well as
iPhone and iPad. Swift 6, SwiftUI with UIKit where needed, Metal for the remote screen. No third-party SDKs.

## Build and test

```
xcodebuild build -project DuoRemote.xcodeproj -scheme DuoRemote -destination 'generic/platform=iOS Simulator'
xcodebuild test  -project DuoRemote.xcodeproj -scheme DuoRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Both must pass before you open a pull request. Swap in any installed iOS 27.1+ simulator. Signing isn't needed for
the simulator. Never commit a team ID, a bundle ID or `Config/Local.xcconfig`.

## Map

| Folder | What's there |
|---|---|
| `DuoRemote/Session/` | The connection (`VNCSession`), key mapping, sticky modifiers, the Tailscale/credential policy |
| `DuoRemote/Remote/` | The remote screen: Metal renderer, viewport maths, touch interpreter, mouse/trackpad input |
| `DuoRemote/Hosts/` | Saved Macs, Keychain, reachability, the session coordinator |
| `DuoRemote/Keys/` | Key bar, keyboard capture, hardware key mapping |
| `DuoRemote/Shell/` | Screens and layout, including iPhone Duo laptop pose |
| `DuoRemote/Theme/` | The sky palette and deck effects |
| `DuoRemoteTests/` | Swift Testing tests for the pure logic |
| `Vendor/RoyalVNCKit/` | Vendored, patched RoyalVNCKit 1.1.0 |

## Rules

- **Layout:** never branch on the device model, idiom, orientation or `UIScreen.main`. Lay out from the space a view
  is given and the fold (`reservedRegions(kind: .division)`); that's what makes iPhone Duo and iPad multitasking work.
- **Concurrency:** Swift 6 with the main actor as the default isolation. RoyalVNCKit calls its delegate on background
  threads; hop to the main actor as `ConnectionBridge` does. Use `@Observable`, not `ObservableObject`.
- **Tests:** add or update Swift Testing tests for pure logic (viewport maths, gestures, key mapping, policies).
- **Comments:** short, and only to say *why*. No change logs or history in comments.
- **Vendored code:** if you change `Vendor/RoyalVNCKit`, mark the change with a `LOCAL PATCH` comment and add it to
  `Vendor/RoyalVNCKit/PATCHES.md`. Keep `THIRD_PARTY_NOTICES.md` and the in-app Acknowledgements in step with any
  dependency change.

## Security invariants (don't weaken these)

- A saved password goes out automatically only over Tailscale (`CredentialPolicy`, `Tailnet.route`), and the app
  connects to the address it checked. Every connect, retry and reconnect goes through that check.
- Passwords live only in the Keychain (`WhenUnlockedThisDeviceOnly`). Never log passwords, typed text, clipboard
  contents or screen contents; log counts at most.
- Clipboard writes are local-only and expire. Paste to Mac never presses Return and confirms long or multi-line text.
- The privacy cover hides the app in the app switcher. Debug-only code stays behind `#if DEBUG`.
- No analytics, accounts, servers or third-party SDKs.

If a change touches any of these, say so plainly in the pull request.

## Pull requests

One focused change per pull request, with what and why, and screenshots for UI changes. By submitting one, the
contribution is licensed under the project's MIT licence (see CONTRIBUTING.md).
