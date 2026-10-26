# Vendored RoyalVNCKit

Upstream: github.com/royalapplications/royalvnc, tag `1.1.0` (commit `92d4427c73817d8f849bb289ff190aa4b40c44ea`).
The repo is archived, and SwiftPM can't pin it by version (it has a branch dependency and unsafeFlags), so it lives here.
Only `Sources/{RoyalVNCKit,RoyalVNCKitC,Z,d3des}` and `LICENSE` were copied. Every source patch is marked `LOCAL PATCH`.

1. `Package.swift`: iOS only, static library. Dropped swift-jpeg/swift-png (needed only on Linux, Windows and Android),
   the demo executables, `-enable-library-evolution`, `type: .dynamic` and vendored zlib (used only on Windows).
   CryptoSwift is pinned by revision (`a59b4d91`, the 1.1.0 Package.resolved SHA).
2. `Extensions/Queue.swift`: the struct had no lock, so it was racing between input callers and the send Task.
   It is now a class guarded by `NSLock`.
3. `Framebuffer/VNCFramebuffer.swift`: `ioSurface` is now `public`, so the client can make a zero-copy Metal texture.
4. Clipboard: `VNCConnectionClipboardDelegate` (new file) + `VNCConnection.clipboardDelegate` receive ServerCutText,
   and `sendClipboardText(_:)` sends ClientCutText. The app keeps `isClipboardRedirectionEnabled` off, so the
   library's own pasteboard polling (which triggers iOS paste prompts) never runs.
5. `SDK/Connection/VNCConnection+API.swift` `mouseWheel`: upstream sends only the wheel-button press for each
   step, never the release, so the server saw one long press and dropped most steps. Each step now sends press + release.
6. ARD credentials (`ARDAuthenticationImpl.swift`, new `SDK/VNCCredentialLimit.swift`): the username and password were
   capped at 63 *characters* but copied into 64-byte fields, so multi-byte text (accents, emoji) wrote past the buffer,
   and a short multi-byte string could index past its end. Now capped at 63 UTF-8 bytes on a character boundary;
   `VNCCredentialLimit` is public so the app can reject over-long credentials up front.
7. Security type (`VNCConnection+Handshake.swift`, `VNCConnection.isUnauthenticatedAccessAllowed`): "None" was chosen
   first even when ARD was offered, so a server could skip sign-in. ARD is now preferred, "None" is used only when
   the app allows it (off by default), and Tight (not implemented, so also no sign-in) is never chosen.

