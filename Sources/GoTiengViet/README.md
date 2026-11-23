# Gõ Tiếng Việt

A lean Vietnamese input app for macOS that lives only in the menu bar. It uses
the typing engine of [OpenKey](https://github.com/tuyenvm/OpenKey) by Tuyen Mai,
unchanged, with a much smaller app around it.

- **Menu bar only.** A `V` (Vietnamese) or `E` (English) icon. It is a template
  image, so it follows light and dark mode. No Dock icon, no main window.
- **Small menu.** Vietnamese on/off, Settings…, Quit.
- **One small Settings window**, built with standard AppKit controls:
  switch key, switch sound, spell check, remember the input for each app,
  open at login.
- **Switch sound.** The switch key plays the macOS "Tink" sound when
  Vietnamese turns on and "Pop" when English turns on, at a soft volume.
  The menu and the per-app memory change the input without a sound.
- **Fixed choices.** Telex, Unicode, and OpenKey's browser autocomplete fixes.
- **No helper apps, no update check, no network access, no storyboard.**
  The whole app is about 400 KB.

## Differences from OpenKey 2.0.5

The keyboard hook (`KeyHook.mm`) is OpenKey's `OpenKey.mm` with the UI links
removed. The engine code and the way characters are sent are unchanged. The
changes are about latency and robustness:

- **The language switch does not block typing.** OpenKey's event tap runs on
  the main thread, and macOS holds every later key until the callback returns.
  OpenKey 2.0.5 did the full UI refresh in that callback on each switch,
  including a `SMLoginItemSetEnabled` call (about 23 ms on an Apple Silicon
  Mac). Here the switch only flips the engine state; saving and UI updates run
  after the callback returns.
- **The front app is cached** from `NSWorkspace` notifications instead of being
  queried on every key.
- **No nested run loop.** OpenKey 2.0.5 started the tap with `CFRunLoopRun()`
  inside a main-queue block, which blocked the main dispatch queue (upstream
  fixed this in a582ac4).
- **The tap is turned on again** when macOS disables it (timeout or secure input).
- **Login item through `SMAppService`** (macOS 13+) instead of a helper app.
- **Accessibility:** the app shows the macOS prompt and starts by itself as soon
  as the permission is on, without a restart.

## Requirements

- macOS 13 or later, Apple Silicon (`arm64`).
- Accessibility permission (System Settings › Privacy & Security › Accessibility).

## Build

Only the Command Line Tools are needed (`xcode-select --install`); Xcode is not.

```sh
./build_gotiengviet.sh
open build/GoTiengViet.app
```

The script compiles `Sources/GoTiengViet` and the OpenKey engine
(`Sources/OpenKey/engine`) with clang and builds the app bundle in `build/`.
It signs the app with a code-signing identity named **"OpenKey Local Signing"**
if your keychain has one, and ad hoc otherwise. With a stable identity, the
Accessibility permission stays valid after a rebuild; with an ad hoc signature,
you must grant it again after each build.

`ICON=/path/to/AppIcon.icns ./build_gotiengviet.sh` sets the app icon. Without
it, the script uses OpenKey's icon from a reference OpenKey bundle if present.

## Using a downloaded build

Release builds are not notarized. On the first open, macOS blocks the app:
open System Settings › Privacy & Security and click **Open Anyway**. Then grant
the Accessibility permission when asked.

Do not run Gõ Tiếng Việt and another Vietnamese input app (OpenKey, EVKey,
…) at the same time: each key would be converted twice.

## Settings storage

Preferences are in the `com.sonvu.gotiengviet` defaults domain. On the first
launch, the app copies the switch key, spell check, smart switch and per-app
languages from OpenKey (`com.tuyenmai.openkey`) if they exist.

## License

GPL-3.0, the same as OpenKey (see `LICENSE` at the repository root).
The OpenKey engine and the keyboard hook code are © Tuyen Mai and the OpenKey
contributors.
