# Vendored SwiftTerm

- upstream: https://github.com/migueldeicaza/SwiftTerm
- version: 1.99.2
- tag: v1.99.2 (2026-10-29)
- commit: a183c15b52858530a17de57dcc72b93eeebc9857

Vendored because the app must intercept keyboard input before it reaches the
PTY, and v1.99.2 made the only hook for that (`TerminalInputSender.replaceDelivery`)
internal. Two members are widened from internal to `public`:

- `TerminalInputSender.replaceDelivery` in
  `Sources/SwiftTerm/Apple/AppleTerminalView.swift`, so
  `FocusableLocalProcessTerminalView` can route keystrokes, paste and
  `send(txt:)` through the app input guards (approval, ZMODEM, SSH and runtime
  routing, input recording, replay suppression).
- `Terminal.mouseEventBytes(buttonFlags:x:y:pixelX:pixelY:)` in
  `Sources/SwiftTerm/Terminal.swift`, so the view can encode a mouse report
  while it holds the terminal lock and deliver it afterwards. Delivering inside
  the callback re-enters the lock, which v1.99.2 made non-recursive. The app
  also snapshots the active mouse encoding, refuses X10 coordinates beyond its
  representable range, and supplies actual cell-center pixels for SGR-pixel clicks.
- `TerminalView.pixelCenterForCell(column:row:)` in
  `Sources/SwiftTerm/Mac/MacTerminalView.swift`, so host-generated clicks can
  translate zero-based grid cells into the current view's pixel coordinates.
- `TerminalView.hasRetainedInlineGraphics()` in
  `Sources/SwiftTerm/Apple/AppleTerminalView.swift`, so the app can tell whether
  an iTerm2, sixel or Kitty image is still held. Text snapshots omit images, and
  the terminal itself is internal.
- `TerminalView.scrollWheel(with:)` in
  `Sources/SwiftTerm/Mac/MacTerminalView.swift` encodes wheel reports under the
  terminal lock and delivers them after releasing it. The method is not `open`,
  so the app cannot intercept it, and delivering inside the lock re-enters it.
- `LocalProcessTerminalView.processInput` in
  `Sources/SwiftTerm/Mac/MacLocalTerminalView.swift`. Mouse reports are delivered
  through the delegate, and only `LocalProcessTerminalView.send(source:data:)`
  writes them to the child process. The app installs its own delegate, so it
  forwards reports here after its input checks.

Dropped from the upstream tree (not needed to build the library): Tests,
TerminalApp, Tools, Web, Docs, Benchmarks, .github and Documentation.docc.
`swifterm-terminfo` stays: the build plugin reads it to generate the terminfo
table.
