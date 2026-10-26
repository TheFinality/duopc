# Security

Please report security problems privately, using GitHub's **Report a vulnerability** button on the repository's **Security** tab, rather than in a public issue.

Include what you found, how to reproduce it, and what an attacker could do with it. This is a spare-time project, so there's no bounty and response times vary, but reports are taken seriously.

The app's security model (what macOS Screen Sharing does and doesn't protect, and why the app relies on Tailscale) is described under **Security** in the [README](README.md).

## Known limitations

The vendored RoyalVNCKit (upstream is archived) still trusts some server data more than it should. A malicious or
impersonated VNC server could crash the app or make it run out of memory, by sending malformed frame data (ZRLE
palette indices, Hextile rectangle sizes) or very large lengths (clipboard text, desktop name, compressed frames).
These can't read your data or run code, and the Tailscale check makes reaching an impersonated server hard. Fixes
are welcome; see `Vendor/RoyalVNCKit/PATCHES.md` for how local changes are recorded.
