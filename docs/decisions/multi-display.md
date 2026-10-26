# Multi-display Macs: no per-display switching (decided 2026-10-25)

## What happens

A Mac with several displays (tested: a MacBook Pro plus three external monitors) arrives over
macOS Screen Sharing as **one stitched framebuffer** covering every display in its arranged
layout. DuoRemote shows it as one large desktop: the pointer moves across all displays and you
pinch-zoom to whichever area you want. That works and is what the app does.

## Why there's no "jump to display N"

- The VNC protocol has a standard way for a server to list its displays: the
  `ExtendedDesktopSize` pseudo-encoding's screen list (RoyalVNCKit exposes it as
  `VNCFramebuffer.screens`).
- **macOS Screen Sharing reports a single screen covering the whole framebuffer to non-Apple
  clients.** Confirmed on the 4-display Mac: the switcher's tab never appeared, because only
  one screen was reported.
- Apple's own Screen Sharing app picks displays using Apple's private, undocumented RFB
  extensions. Building on those would be fragile and isn't planned.
- Asking the Mac directly (e.g. `system_profiler SPDisplaysDataType` over SSH) would need
  Remote Login on the Mac and an SSH client in the app. That breaks the "nothing to set up on
  the Mac" design.

## Options considered and declined

1. A built display switcher: an edge tab plus a glass panel with a colour-bordered, numbered
   live map and All / 1–N buttons. Mockups are in `docs/mockups/displays/`. It was built
   (commits `e525a3e`, `13eab99`), worked against simulated layouts of 1–8 displays, and was
   **removed** (reverted) because macOS never supplies the layout.
2. Detecting displays from the picture: black gaps between displays plus seams between
   touching ones. Started, then stopped. It's a heuristic that can't be dependable for an
   arbitrary set of monitors.
3. A per-Mac manual layout (the user describes the arrangement once). Declined: too fiddly for
   the benefit.

## If this is revisited

- If a future macOS reports real screens via `ExtendedDesktopSize`, revert the revert: the
  switcher code is in history and lights up automatically when `screens.count > 1`.
- Check what a Mac reports by logging `framebuffer.screens` when the framebuffer is created.
