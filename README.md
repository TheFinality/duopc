# DuoPC

Control your **Windows PC** from your iPhone, built for the **iPhone Duo**. Fold it halfway and it becomes a tiny laptop: the PC's screen on the top half, a trackpad, Ctrl / ⊞ / Alt / Shift and the keyboard on the bottom half. Open it flat and the PC gets the whole screen.

DuoPC is a fork of [DuoRemote](https://github.com/yezzer/DuoRemote) by Iestyn Lloyd-Wilkins, which does the same thing for a Mac. DuoRemote uses the Screen Sharing built into macOS. Windows (especially Windows 11 Home) has no built-in VNC server, so DuoPC comes with a one-time setup script that installs the free **TightVNC** server on your PC and locks it down to your Tailscale devices.

```
 iPhone Duo (DuoPC app)  ──── Tailscale (encrypted) ────▶  Windows PC (TightVNC server, port 5900)
```

## What's different from DuoRemote

- **PC keys.** The sticky modifiers are `ctrl` `⊞` `alt` `⇧` (tap to latch, double-tap to lock). On a hardware keyboard, ⌘ is the Windows key and ⌥ is Alt, the same as Boot Camp.
- **Windows shortcuts** in the ••• menu: Ctrl+Alt+Del, Task Manager, Start menu, Task view, Show desktop, File Explorer.
- **VNC password sign-in.** TightVNC uses a VNC password, so there's no username. The username field is there only for UltraVNC's Windows-account sign-in (MS-Logon II).
- **The clipboard works PC → iPhone.** Copy on the PC (Ctrl+C) and the text is on your iPhone for 10 minutes. *Copy text from screen* (Live Text) is still there for text you can't select. *Paste to PC* types your iPhone clipboard into the PC.
- **Scroll speed retuned for Windows.** Windows scrolls 3 lines per wheel step (macOS scrolls much less), so each step takes more finger travel.
- A Windows-style demo screen, PC icons and PC wording.

Everything else is DuoRemote: laptop pose, trackpad and direct touch, momentum scrolling, pinch zoom, the text box with dictation, auto-reconnect, Keychain passwords, the sky-coloured deck.

## Set up your PC (once)

1. **Install Tailscale** on the PC from <https://tailscale.com/download> and sign in. In the [admin console](https://login.tailscale.com/admin/dns), turn on **MagicDNS**.
2. **Run the setup script.** Open PowerShell **as administrator** (Start → type *PowerShell* → *Run as administrator*), then:

   ```powershell
   cd D:\duocomputer\windows
   powershell -ExecutionPolicy Bypass -File .\Setup-DuoPC.ps1
   ```

   It asks for a VNC password (1–8 characters; press Enter to have one made up). Then it:
   - downloads TightVNC **2.8.85** from tightvnc.com and checks that it's signed by GlavSoft,
   - installs only the server, as a Windows service, so it also works at the lock screen, the sign-in screen and UAC prompts,
   - sets the password, turns off TightVNC's web (Java) viewer, and allows only Tailscale addresses (`100.64.0.0/10`) in TightVNC's own access list,
   - adds a Windows Firewall rule for port 5900 that allows only Tailscale addresses, and turns off any older "TightVNC" rule that allowed everyone,
   - prints the hostname to type into the app.

   Options:

   | Command | What it does |
   |---|---|
   | `.\Setup-DuoPC.ps1 -Check` | Changes nothing. Checks TightVNC, the firewall rule and Tailscale, and whether the server answers like a VNC server should. |
   | `.\Setup-DuoPC.ps1 -AllowLan` | Also lets in devices on your home network without Tailscale. VNC isn't encrypted, so do this only on a network you trust. |
   | `.\Setup-DuoPC.ps1 -Port 5901` | Uses another port. |
   | `.\Setup-DuoPC.ps1 -Uninstall` | Removes the firewall rule and uninstalls TightVNC. |

   To change the password later, run the script again, or use the TightVNC tray icon → *Configuration* → *Server* → *Primary password*.

   > **Why not TightVNC 4?** TightVNC 4.0 (released 2026-10-25) moves passwords to its own sign-in method (SRP), which other VNC apps can't use. The script installs 2.8.85, the last 2.x release. If you'd rather use another server, **UltraVNC** and **TigerVNC** work too: set a VNC password and allow only Tailscale addresses.

3. **Install Tailscale on the iPhone** and sign in with the same account.

## Build the app

Building needs a **Mac with Xcode 27**. You can't build iOS apps on Windows. A free Apple account is enough to run it on your own phone. If you don't have a Mac, a cloud Mac or a CI service with macOS runners (such as GitHub Actions or Xcode Cloud) can build it, but you'll still need to sign it with your Apple account.

1. Copy this folder to the Mac (or push it to a git repo and clone it there), then open `DuoRemote.xcodeproj` in Xcode. The project and target are still called *DuoRemote*; the app shows up on your phone as **DuoPC**.
2. Select the **DuoRemote** target → **Signing & Capabilities**. Choose your **Team** and change the **Bundle Identifier** to something of your own (e.g. `com.yourname.duopc`).
   Or create `Config/Local.xcconfig` (git ignores it) with:
   ```
   DEVELOPMENT_TEAM = YOURTEAMID
   APP_BUNDLE_ID = com.yourname.duopc
   ```
3. Plug in the iPhone, choose it as the run destination, and press **Run** (⌘R).
4. The first time, trust the developer on the phone: **Settings → General → VPN & Device Management**.

No Mac? Push this folder to a GitHub repository and the included workflow (`.github/workflows/build.yml`) builds the app and runs the tests on a GitHub macOS runner. That checks the code compiles; installing it on your phone still needs Xcode and your Apple account.

To try it without a device, pick any iOS 27.1+ simulator; the app's built-in demo needs no PC. Run the tests with ⌘U, or:

```
xcodebuild test -project DuoRemote.xcodeproj -scheme DuoRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Connect

In DuoPC, tap **+** and enter:

- **Hostname:** the PC's Tailscale name (the setup script prints it, e.g. `my-pc`) or its `100.x.y.z` address
- **Port:** 5900
- **VNC password:** the one you chose. Leave the username empty.

Then fold the phone halfway for laptop pose.

## Gestures

| Gesture | Does |
|---|---|
| Drag | moves the pointer |
| Tap | left click |
| Two-finger tap | right click |
| Two-finger drag | scroll (with momentum) |
| Hold, then drag | drag (a magnifier shows while you drag) |
| Pinch | zoom |
| Three-finger drag | pan when zoomed in |

## Security

- **VNC doesn't encrypt your screen or keystrokes.** Tailscale encrypts the whole connection end to end, which is why the setup script lets in only Tailscale addresses, both in TightVNC and in Windows Firewall.
- The VNC password itself isn't sent in the clear (it's a challenge–response), but it's at most 8 characters and the exchange can be cracked offline if someone records it. Use Tailscale.
- The app can't verify the identity of the PC it connects to. A saved password is sent automatically only when the PC's name resolves to Tailscale addresses routed through the Tailscale tunnel. Anywhere else, the app warns and asks first. *Allow outside Tailscale* in Edit PC turns that off for one PC.
- Passwords are stored only in the iPhone's Keychain. No accounts, no analytics, no servers: the app talks only to the PCs you add.
- During setup, the password is passed to the TightVNC installer on its command line, so for those few seconds other administrators on the PC could see it. TightVNC stores it obfuscated in the registry (`HKLM\SOFTWARE\TightVNC\Server`), the same as every VNC server.
- The app reads the iPhone clipboard only when you tap Paste (iOS asks first). Text from the PC's clipboard stays on this iPhone (no Handoff) and expires after 10 minutes.

## Notes

- **Several monitors** show up as one wide desktop (that's how TightVNC sends them). Pinch to zoom to the one you want.
- **Wallpaper:** TightVNC hides the desktop wallpaper while you're connected, to send less data. Change that in the TightVNC tray icon → Configuration → Server.
- **Lock screen and UAC:** because TightVNC runs as a service, you can sign in and answer UAC prompts remotely. Use ••• → Windows shortcuts → Ctrl+Alt+Del at the lock screen.

## Credits

- [DuoRemote](https://github.com/yezzer/DuoRemote) by Iestyn Lloyd-Wilkins (MIT). This app is DuoRemote with Windows changes.
- [RoyalVNCKit](https://github.com/royalapplications/royalvnc) 1.1.0 (MIT), vendored in `Vendor/RoyalVNCKit` with the patches listed in `Vendor/RoyalVNCKit/PATCHES.md`, and [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift). Full licences are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- [TightVNC](https://www.tightvnc.com) (GPL) is downloaded by the setup script from its official site. It isn't included in this repository or the app.

This is an independent project, not affiliated with, sponsored or endorsed by Apple Inc., Microsoft Corporation, GlavSoft LLC or Tailscale Inc. Provided as-is, with no warranty. Use at your own risk, and only with computers you own or are authorised to access.
