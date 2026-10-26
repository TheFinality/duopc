# DuoPC

Control your **Windows PC** from your iPhone, built for the **iPhone Duo**. Fold it halfway and it becomes a tiny laptop: the PC's screen on the top half, a trackpad, Ctrl / ⊞ / Alt / Shift and the keyboard on the bottom half. Open it flat and the PC gets the whole screen.

It connects **directly** to your PC, at home or away, over an encrypted connection. No Tailscale, no relay, no account.

```
 iPhone (DuoPC)                       your router                 Windows PC
 ──────────────                       ───────────                 ──────────────────────────────────
  TLS 1.3, pinned to the PC's   ──▶   port forward  ──▶  :5960   DuoPC Gateway ──▶ 127.0.0.1:5900
  certificate + pairing token          (TCP 5960)                  (paired phones only)   TightVNC
```

- **TightVNC** draws the screen and takes your input. It's set to accept connections only from the PC itself, so nothing on the network or internet can reach it directly.
- **DuoPC Gateway** (in `windows/DuoPCGateway`, C#/.NET 8) is the only way in. It speaks TLS 1.3 with its own certificate, lets in only phones that scanned its pairing QR code, and passes their connection on to TightVNC.
- **The app** trusts exactly one certificate per PC, the one it paired with, so a fake server can't stand in for your PC, even on hostile Wi-Fi.

DuoPC is a fork of [DuoRemote](https://github.com/yezzer/DuoRemote) by Iestyn Lloyd-Wilkins, which does the same for a Mac.

## Video streaming

Paired PCs stream the screen as **video** by default: your NVIDIA card encodes it (HEVC) and the iPhone decodes it in hardware, so scrolling and moving windows run at up to 60 fps instead of VNC's catch-up. It goes through the same encrypted, paired connection on port 5960 (no extra ports), and pinch-zoom still gives you full 4K detail.

- **Needs** an NVIDIA graphics card with driver **570 or newer** (update it with the NVIDIA App or from nvidia.com). `Setup-DuoPC.ps1` installs the streamer and FFmpeg; `-Check` tests the encoder.
- **Keeps the delay down:** the phone acknowledges every frame, and if the network backs up the PC skips frames instead of queueing them; the encoder's rolling refresh repairs the picture within half a second. ••• → Connection log shows fps, Mbps, skipped frames and round trip every few seconds.
- **Picture quality** sets the bitrate: Fast 8 Mbps (mobile data), Balanced 20 Mbps, Sharp 45 Mbps (home Wi-Fi). Changing it restarts the video for a moment.
- **Switch to VNC** any time: ••• → Video streaming, or per PC in Edit PC. Windows doesn't let normal screen capture see the lock screen or admin (UAC) prompts; when one is up, the app offers **Use VNC for now**.
- Not yet in video mode: the PC's clipboard coming to the iPhone, the pointer's shape (you see an arrow), and Ctrl+Alt+Del (Windows ignores it unless it comes through VNC).

## Set up your PC (once)

You need Windows 10 or 11, the [.NET 8 SDK](https://dotnet.microsoft.com/download) (to build the gateway), and this repository on the PC.

1. Open PowerShell **as administrator** (Start → type *PowerShell* → *Run as administrator*), then:

   ```powershell
   cd D:\duocomputer\windows
   powershell -ExecutionPolicy Bypass -File .\Setup-DuoPC.ps1
   ```

   It:
   - downloads TightVNC **2.8.85** from tightvnc.com, checks it's signed by GlavSoft, and installs only the server, as a Windows service (so the lock screen, sign-in screen and UAC prompts work too),
   - gives TightVNC a random password and locks it to `127.0.0.1`,
   - builds DuoPC Gateway, installs it to `C:\Program Files\DuoPC`, and runs it as a service on port **5960** that restarts itself if it stops,
   - opens port 5960 in Windows Firewall for the gateway program only, and turns off any older TightVNC rules,
   - checks that the gateway can sign in to TightVNC and answers with TLS 1.3,
   - asks for your home's internet address (see below) and shows the **pairing QR code**.

2. **Scan the QR code** in the app: tap **+** → **Scan pairing code** → **Save**. The code carries the address, port, certificate fingerprint, the phone's pairing token and the VNC password, so there's nothing to type.

   If the camera can't read it, copy the `duopc://…` line the script prints to your phone (for example in a note to yourself, deleted afterwards) and tap **Paste** in the same place.

3. **Forward the port on your router**, for use away from home. In the router's settings (often <http://192.168.1.1> or <http://192.168.0.1>), add:

   | Protocol | Outside port | To (this PC) | Port |
   |---|---|---|---|
   | TCP | 5960 | your PC's local IP (the script shows it, e.g. `10.0.0.93`) | 5960 |

   Also give the PC a fixed local IP there (a *DHCP reservation*), so the forward keeps pointing at it.

### Your home's internet address

Away from home, the phone connects to your home's public address. Your ISP can change that, so a **dynamic DNS name** is best:
- many routers have DDNS built in (look for *DDNS* or *Dynamic DNS*), or
- use a free service like [Duck DNS](https://www.duckdns.org) with its small Windows updater.

Pass it to the script with `-PublicHost myhome.duckdns.org`, or type it when asked. If you press Enter, the script looks up your current public IP (from api.ipify.org) and uses that. You can change the address later in the app (Edit PC → Hostname); the pairing doesn't depend on it.

**At home:** if your router supports *NAT loopback* (most do), the same address works at home. If it doesn't, edit the PC in the app and use the PC's local IP while you're at home.

**If it never works from outside:** some ISPs (and most mobile hotspots) use *CGNAT*, which means no port forward can reach you. If the WAN IP in your router's status page differs from what <https://api.ipify.org> shows, that's you. Ask your ISP for a public IP, or use IPv6, or fall back to Tailscale (below).

### Script options

| Command | What it does |
|---|---|
| `.\Setup-DuoPC.ps1 -Check` | Changes nothing. Checks TightVNC (running, locked to this PC, answering), the gateway (running, TLS 1.3, its certificate), the firewall, and paired phones. |
| `.\Setup-DuoPC.ps1 -Pair` | Pairs another phone, or pairs again. Shows a new QR code. |
| `.\Setup-DuoPC.ps1 -Update` | After pulling a new DuoPC version: rebuilds and reinstalls the gateway and video streamer, adds FFmpeg, and checks the NVIDIA driver. Keeps your pairings, port and passwords. |
| `.\Setup-DuoPC.ps1 -PublicHost NAME` | Uses this address in the QR code instead of asking. |
| `.\Setup-DuoPC.ps1 -ExternalPort 443` | If your router forwards a different outside port to 5960. |
| `.\Setup-DuoPC.ps1 -Uninstall` | Removes the gateway (service, files, certificate, pairings), its firewall rule, and TightVNC. |

The gateway has its own commands too (`C:\Program Files\DuoPC\DuoPCGateway.exe`, as administrator):

| Command | What it does |
|---|---|
| `DuoPCGateway devices` | Lists paired phones. |
| `DuoPCGateway revoke "Phone 2026-10-26 09:12"` | Unpairs a phone; it can no longer connect. `revoke --all` unpairs every phone. |
| `DuoPCGateway pair --png qr.png` | Also saves the QR code as an image (delete it after scanning). |
| `DuoPCGateway fingerprint` | Prints the certificate's SHA-256; the app shows its first 16 digits in Edit PC. |

Its log is `C:\ProgramData\DuoPC\gateway.log`: who connected, and rejected attempts.

## Install the app from Windows (free, no Mac)

GitHub builds the app for you on a cloud Mac. You sign and install it from Windows with a free Apple ID, using a sideloading tool.

1. **Download `DuoPC.ipa`.** On GitHub, open **Actions** → the latest green **Build and test** run → **Artifacts** → **DuoPC-ipa** (a zip with `DuoPC.ipa` inside; artifacts are kept 30 days, and every push makes a new one). Or, with the GitHub CLI:
   ```bash
   gh run download --repo TheFinality/duopc --name DuoPC-ipa --dir D:/duocomputer/dist
   ```
2. **Install [Sideloadly](https://sideloadly.io)** on the PC and follow its setup notes. It may need Apple's iTunes and iCloud for Windows; get the versions it says, since some Microsoft Store versions don't work. (AltServer/AltStore works too and can re-sign over Wi-Fi.)
3. **Get the iPhone ready.** Plug it into the PC with a cable and tap **Trust** on the phone. Turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
4. **Sideload.** Drag `DuoPC.ipa` into Sideloadly, enter your Apple ID, and press **Start**. Use a spare Apple ID if you'd rather not give a third-party tool your main one: any free Apple ID works.
5. **Trust it on the phone:** **Settings → General → VPN & Device Management** → your Apple ID → **Trust**. Then open DuoPC and scan your PC's pairing code.

What a free Apple ID means:
- **The app stops opening after 7 days.** Sideload it again before then (Sideloadly can refresh it automatically while the PC is on). Re-signing with the same Apple ID keeps your paired PCs; a different Apple ID or bundle ID starts fresh, so pair again.
- At most 3 sideloaded apps at a time, and 10 new app IDs a week.
- **If the app opens but crashes when you open a PC or the demo**, and the crash log (Settings → Privacy & Security → Analytics & Improvements → Analytics Data → `DuoRemote-…`) says `CODESIGNING` / `Invalid Page`, the copy on the phone was damaged during install. Delete the app and sideload it again.
- The bundle ID is `io.github.thefinality.duopc` (in `Config/DuoRemote.xcconfig`). If Sideloadly says it's unavailable, change it there and push, or let Sideloadly change it under its advanced options.

## Build the app with Xcode

If you have a Mac (or rent one), you can build and run it directly instead. That needs **Xcode 27**. A free Apple account is enough to run it on your own phone, with the same 7-day limit.

1. Clone this repo on the Mac and open `DuoRemote.xcodeproj`. (The project and target keep the DuoRemote name; the app shows up as **DuoPC**.)
2. Select the **DuoRemote** target → **Signing & Capabilities**, choose your **Team**, and if Xcode says the **Bundle Identifier** is taken, change it to your own (e.g. `com.yourname.duopc`). Or put both in `Config/Local.xcconfig` (git ignores it):
   ```
   DEVELOPMENT_TEAM = YOURTEAMID
   APP_BUNDLE_ID = com.yourname.duopc
   ```
3. Plug in the iPhone, choose it as the run destination, and press **Run** (⌘R). The first time, trust the developer on the phone: **Settings → General → VPN & Device Management**.

The GitHub Actions workflow (`.github/workflows/build.yml`) builds the app and runs its tests on GitHub's Xcode 27 image, builds the unsigned `DuoPC.ipa` for sideloading, and builds and tests the gateway end to end on Windows.

## What's different from DuoRemote

- **Direct, encrypted connections** through DuoPC Gateway, paired by QR code (above). DuoRemote relies on Tailscale.
- **PC keys.** Sticky `ctrl` `⊞` `alt` `⇧` (tap to latch, double-tap to lock). On a hardware keyboard, ⌘ is the Windows key and ⌥ is Alt, as in Boot Camp.
- **Autocorrect and suggestions on the keyboard.** Corrections are sent to the PC as Backspaces plus the corrected word; dragging on the space bar moves the PC's cursor. It starts fresh whenever you click or use a key from the bar. Turn it off in Settings (e.g. for passwords).
- **Windows shortcuts** in the ••• menu: Ctrl+Alt+Del, Task Manager, Start menu, Task view, Show desktop, File Explorer.
- **Clipboard PC → iPhone.** Copy on the PC (Ctrl+C) and it's on your iPhone for 10 minutes. *Paste to PC* types your iPhone clipboard into the PC. *Copy text from screen* (Live Text) is still there for text you can't select.
- **Scroll speed retuned for Windows**, which scrolls 3 lines per wheel step.

Everything else is DuoRemote: laptop pose, trackpad and direct touch, momentum scrolling, pinch zoom, the text box with dictation, auto-reconnect, Keychain storage.

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

**What's exposed to the internet:** one TCP port, answered only by DuoPC Gateway.

- **Encryption.** Everything between the phone and the gateway (screen, keystrokes, clipboard, the VNC password) is inside TLS 1.3. The gateway accepts nothing older.
- **The phone knows it's your PC.** The gateway makes a self-signed P-256 certificate on first run. The pairing code carries its SHA-256, and the app accepts that certificate and no other, on any network. If it ever changes (you reinstalled, or something else is answering), the app refuses and sends nothing; pair again.
- **The PC knows it's your phone.** Each pairing gives the phone a random 256-bit token, kept in the iPhone's Keychain (this device only, never synced). The gateway keeps only its SHA-256, compares in constant time, and closes the connection before any VNC traffic unless the token matches. An address that sends 5 wrong tokens within 15 minutes is blocked for an hour. Unpair a lost phone with `DuoPCGateway revoke`.
- **TightVNC can't be reached from the network.** It accepts connections only from 127.0.0.1 (TightVNC's *loopback only* setting plus its access list), and its port isn't opened in the firewall. Its random 8-character password is a second lock behind the gateway, not the main one.
- **On the PC,** the certificate's private key, the token hashes and the VNC password (DPAPI-encrypted) are in `C:\ProgramData\DuoPC`, readable only by SYSTEM and Administrators. The gateway runs as a service, as SYSTEM.
- **The pairing code is a secret.** It holds the token and the VNC password. It's shown on screen only; don't screenshot or share it. If it leaks, run `revoke` and pair again.
- **Keep the gateway updated.** It's built on .NET 8, whose support ends on 10 November 2026. Before then, install the .NET 10 SDK, change `net8.0-windows` to `net10.0-windows` in `windows/DuoPCGateway/DuoPCGateway.csproj`, and run the setup script again to rebuild it. The rebuild keeps the certificate and pairings. Run Windows Update too: TLS is Windows' own (Schannel).
- **No accounts, analytics or servers.** The app talks only to the PCs you add. It reads the iPhone clipboard only when you tap Paste (iOS asks first), and text from the PC's clipboard stays on this iPhone and expires after 10 minutes.

### Without the gateway (Tailscale)

The app still supports PCs added by hand, with no pairing: plain VNC (for example TightVNC with its port open to Tailscale only). That isn't encrypted by VNC itself, so the app sends a saved password to such a PC only when it's reached through Tailscale, and asks first anywhere else.

## Notes

- **Several monitors** show up as one wide desktop. Pinch to zoom to the one you want.
- **Wallpaper:** TightVNC hides the desktop wallpaper while you're connected, to send less data. Change that in the TightVNC tray icon → Configuration → Server.
- **Lock screen and UAC:** use ••• → Windows shortcuts → Ctrl+Alt+Del at the lock screen.

## Credits

- [DuoRemote](https://github.com/yezzer/DuoRemote) by Iestyn Lloyd-Wilkins (MIT).
- [RoyalVNCKit](https://github.com/royalapplications/royalvnc) 1.1.0 (MIT), vendored in `Vendor/RoyalVNCKit` with the patches in `Vendor/RoyalVNCKit/PATCHES.md`, and [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift). Full licences: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- DuoPC Gateway uses [QRCoder](https://github.com/codebude/QRCoder) (MIT) and Microsoft's .NET libraries (MIT), fetched by NuGet when it's built.
- [TightVNC](https://www.tightvnc.com) (GPL) is downloaded by the setup script from its official site. It isn't included in this repository or the app.

This is an independent project, not affiliated with, sponsored or endorsed by Apple Inc., Microsoft Corporation, GlavSoft LLC or Tailscale Inc. Provided as-is, with no warranty. Use at your own risk, and only with computers you own or are authorised to access.
