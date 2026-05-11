# Changelog

All notable changes to **quicktab-iterm2** are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-05-11

Initial public release.

### Added

- **Hotkey-triggered popup picker** — user-configurable iTerm2 key binding
  invokes `quicktab_show()` to summon a Spotlight-style tab switcher
  anchored to the focused iTerm2 window.
- **Fuzzy search across all tabs and windows** — subsequence match with
  scored ranking (consecutive-character bonus, word-boundary bonus,
  shorter-haystack preference).
- **Pre-select currently-active tab** — when the popup opens, the focused
  tab is already highlighted so a one-keypress confirmation re-finds it.
- **Last-activity indicator** at the right edge of each row, formatted as
  relative time (`5m`, `3h`, `2d`, `1w`). Hidden when less than 30 seconds.
  Driven by tty `atime` (last user-interaction signal) rather than `mtime`
  (which is noisy from shell prompt redraws and background processes).
- **Close tab from the picker** via `⌘⌫` (highlighted row) or click the X
  icon that appears on hover. Picker stays open after close so users can
  clean up a streak of stale tabs in one session.
- **Toggle close** — pressing the bound hotkey while the picker is open
  closes it (no commit).
- **Auto-dismiss** on `Esc` or click outside the popup; `⏎` opens the
  selected tab.
- **Native macOS look** — SwiftUI implementation with glass material,
  SF Symbols, rounded corners, system accent for selection, monospaced
  ⌘N shortcut hints. Adapts to system light/dark mode.
- **Streaming JSON event protocol** between the autolaunch RPC parent and
  the picker subprocess — supports both intermediate `close` events
  (picker remains open) and the final `select` event before exit.
- **Silent logging by default** with `QUICKTAB_DEBUG=1` opt-in for verbose
  diagnostics.
- **Idempotent installer** (`install.sh`) — checks prerequisites (iTerm2,
  Swift toolchain, iTerm2 Python API enabled), copies sources to
  `~/.local/bin/` and the iTerm2 AutoLaunch directory, builds the picker
  binary via `swiftc -O`, starts the autolaunch script without requiring
  iTerm2 to be restarted.

### Architecture notes

- macOS `setActivationPolicy(.regular)` alone is not sufficient for a
  CLI-spawned Swift binary to become the frontmost app. Required osascript
  `tell System Events to set frontmost of process` to physically promote
  the process — same trick proven on the predecessor Tkinter implementation.
- `applicationShouldTerminateAfterLastWindowClosed = false` and a vetoing
  `windowShouldClose` delegate prevent silent termination from external
  close events (system `⌘W`, accessibility actions, window-server quirks).
- `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` handles
  `Esc / arrows / Return / ⌘⌫` at the controller level — runs before the
  responder chain, so the SwiftUI TextField doesn't intercept arrow keys
  for cursor movement (which beeps on empty input).

[Unreleased]: https://github.com/OWNER/quicktab-iterm2/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/OWNER/quicktab-iterm2/releases/tag/v0.1.0
