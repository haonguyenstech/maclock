# MacLock

A macOS menu-bar app that mimics the native lock screen and unlocks with **Touch ID** —
useful on Macs where an MDM profile blocks fingerprint unlock at the system login window
(the `LocalAuthentication` API still works inside a normal app).

Lock instantly from the menu bar or a global shortcut, then unlock with your fingerprint
or your login password.

## Features
- **Native-style lock screen** — blurred wallpaper, big clock, avatar, password field.
- **Touch ID unlock** — always armed; one touch wakes and unlocks.
- **Manual password** — type your real login password (verified via PAM/`dscl`) as a fallback.
- **Keyboard + gesture blocking** — a `CGEventTap` swallows every keystroke, scroll, multi-touch
  swipe (Mission Control / Spaces), and disables hot corners while locked (needs Accessibility).
- **Quick-Lock shortcut** — global hotkey (default `⌃⌥L`), remappable in Settings.
- **Screen dim / blackout** — after a configurable idle time MacLock blacks out the display and
  drops the backlight to save power, while holding a power assertion so the *native* lock screen
  never layers on top (you unlock once, with Touch ID).
- **Menu bar / Dock toggle** and **Launch at Login**.

## Install / update
One-liner (installs the latest release, strips quarantine, launches):
```bash
curl -fsSL https://raw.githubusercontent.com/haonguyenstech/maclock/master/install.sh | bash
```
Run it again any time to update. Or download `MacLock.zip` from
[Releases](https://github.com/haonguyenstech/maclock/releases), unzip, and run `Install.command`.

After first launch, grant **System Settings → Privacy & Security → Accessibility** so MacLock
can block the keyboard, then right-click the menu-bar icon → **Settings…** to configure.

## Security note
MacLock is a **convenience lock**, not a replacement for the system login window. It runs in your
user session and can only *cover and block* — it cannot freeze the session at the kernel level the
way `loginwindow` does. A restart (unless Launch at Login is on), SSH, or Screen Sharing can bypass
it. For real protection, enable **FileVault** and keep using the native lock for sensitive data.

## Build from source
```
./build.sh      # compile universal binary → /Applications/MacLock.app (ad-hoc signed)
./release.sh    # package + publish a new GitHub release (maintainer)
```
Requires macOS 14+ and the Xcode command-line tools.
