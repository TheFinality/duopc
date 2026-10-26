# Contributing

Thanks for taking a look. This started as a personal app, so support is best-effort, but issues and pull requests are welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Bugs: include your iPhone model (and Duo pose, if relevant), iOS version, macOS version, and steps to reproduce. **Connection log** (••• → Connection log) helps; check it doesn't contain anything private before you paste it.
- Security problems: please don't open a public issue. See [SECURITY.md](SECURITY.md).

## Building and testing

See **Building** in the [README](README.md). Run the tests with ⌘U before opening a pull request.

## Code style

- Swift 6, with the main actor as the default isolation. Use `@Observable`, not `ObservableObject`.
- Never base layout on the device model, idiom, orientation or `UIScreen.main`. Read the space a view is given (this is what makes the iPhone Duo work).
- Keep comments short and about *why*, not *what*.
- Add tests (Swift Testing, in `DuoRemoteTests/`) for pure logic: viewport maths, gestures, key mapping and so on.
- No third-party SDKs, analytics or accounts. Passwords go in the Keychain only.
- RoyalVNCKit is vendored in `Vendor/RoyalVNCKit`. If you change it, record the change in `Vendor/RoyalVNCKit/PATCHES.md`.

## Pull requests

Keep them focused: one change per pull request, with a short description of what and why, and screenshots for UI changes.

By submitting a pull request, you agree that your contribution is licensed under this project's [MIT License](LICENSE) and that you have the right to submit it.
