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

8. DuoPC Gateway (`SDK/VNCGateway.swift`, new; `Network/NetworkConnection.swift`, `Network/NWConnection+NetworkConnection.swift`,
   `SDK/Connection/VNCConnection.swift`, `SDK/Error/ConnectionError.swift`): `VNCConnection.gateway` makes the connection
   TLS 1.3 with a verify block that accepts only the certificate whose SHA-256 is pinned (no CA, name or expiry check), then
   sends `"DPC1"` + the 32-byte pairing token and waits for 0x00 (accepted) or 0x01 (→ `ConnectionError.gatewayRejected`)
   before the VNC handshake. A pin mismatch is reported as `ConnectionError.gatewayCertificateMismatch`. Plain connections
   (`gateway == nil`) are unchanged.
9. Latency (`Network/NWConnection+NetworkConnection.swift`, `SDK/Connection/VNCConnection.swift`, `+API.swift`, `+Receive.swift`,
   `+Send.swift`): TCP `noDelay`; the next incremental FramebufferUpdateRequest is sent when an update starts arriving
   instead of after it's decoded (plus a fresh one after the first or a resizing update); the send loop idles 4 ms instead
   of 10 ms; Tight JPEG quality and compression level are public (`jpegQualityLevel`, `compressionLevel`, defaults 6 and 5,
   as before) and `updateQuality(jpegQuality:compressionLevel:)` re-sends SetEncodings while connected.
10. Whole-frame updates (`SDK/VNCConnectionFrameDelegate.swift`, new; `SDK/Connection/VNCConnection.swift`, `+Receive.swift`):
   `VNCConnection.frameDelegate` gets `connectionDidFinishFramebufferUpdate(_:)` once every rectangle of a FramebufferUpdate is
   decoded and reported, before the next one is read, so the client can present complete frames instead of drawing the
   framebuffer while it's being written.
