# SoftLock

A native macOS menu bar app that covers every display without locking the session.

Cmd+Shift+L toggles the covers. The menu also offers Cmd+L. Connected displays are covered when the display layout changes.

Terminal jobs keep running. GUI automation sees the covers. This is a soft lock, not an authentication boundary. Force Quit can bypass it.

## Build

Requires macOS and the Xcode command line tools.

```sh
zsh build.sh
open "$HOME/Applications/SoftLock.app"
```

The build installs an ad-hoc signed app in `~/Applications`. No background polling, network access, or third-party dependencies.

## Smoke test

This briefly covers all screens, checks the display count, then uncovers them and exits.

```sh
"$HOME/Applications/SoftLock.app/Contents/MacOS/SoftLock" --smoke-test
```
