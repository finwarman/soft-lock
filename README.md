# SoftLock

A native macOS menu bar app that covers every display without locking the session.

Cmd+Shift+L toggles the covers. The menu also offers Cmd+L. Connected displays are covered when the display layout changes.

Terminal jobs keep running. GUI automation sees the covers. This is a soft lock, not an authentication boundary. Force Quit can bypass it.

While covered, the Mac stays awake for one hour by default, then sleeps. A small dim counter shows the minutes remaining on each display. Press 1–9 to restart the timer for that many hours, or 0 for indefinite awake time. Unlocking cancels the timer and restores normal sleep behavior. The menu saves a different default for future locks.

Keeping awake prevents idle display and system sleep. It does not override closing the lid, manual sleep, or a depleted battery.

Press P while covered to require a PIN for this lock. First use asks you to enter and confirm a 4-digit PIN. Later uses reuse it. The unlock shortcut then shows a PIN prompt; Return submits and Escape cancels. P also requires the PIN before disabling protection. Number keys enter the PIN while a prompt is open; otherwise they control the awake timer.

The PIN resets to optional after unlocking. Its salted hash is saved only in `~/Library/Application Support/SoftLock/pin.json`, outside the repository, with owner-only file permissions. No PIN is bundled in the app. PIN protection remains a soft lock and does not prevent Force Quit.

## Touch ID

Click Touch ID on a cover, or press Return or Space, then use your fingerprint in the macOS prompt. Successful authentication uncovers every screen, including PIN-protected covers. Cancelling or failing leaves the covers in place. The shortcut and PIN still work. Touch ID must already be configured in macOS.

## Hot corner

Enable Bottom-right hot corner in the menu. Hold the pointer in a display’s bottom-right corner briefly to cover every screen. Entering the corner never unlocks them.

SoftLock temporarily disables the Dock’s bottom-right action to avoid triggering the macOS lock screen too. It restores the previous action when disabled or when SoftLock exits. A helper waits for process exit without polling and restores the action after a crash or Force Quit. The Dock restarts when this setting changes. Other hot corners are untouched.

## Build

Requires macOS 13 or newer and the Xcode command line tools. The build includes Intel and Apple silicon binaries.

```sh
zsh build.sh
open "$HOME/Applications/SoftLock.app"
```

The build installs an ad-hoc signed app in `~/Applications`. No network access or third-party dependencies. The countdown updates once per minute while covered.

## Smoke test

This briefly covers all screens, checks the display count, then uncovers them and exits.

```sh
"$HOME/Applications/SoftLock.app/Contents/MacOS/SoftLock" --smoke-test
```

The smoke test also checks failed, stale, and successful authentication callbacks. It does not authenticate a real fingerprint.

To check hot-corner recovery, quit SoftLock first:

```sh
swiftc -parse-as-library HotCorner.swift tests/CornerProbe.swift -o build/corner-probe
python3 tests/hot-corner-smoke.py
```

This temporarily takes over the bottom-right corner and verifies restoration after normal exit and forced termination.
