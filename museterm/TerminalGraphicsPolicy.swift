import SwiftTerm

enum TerminalGraphicsPolicy {
    static let supportedProtocols = ["kitty", "iterm2", "sixel"]
    static let minimumCacheMegabytes = 32
    static let defaultCacheMegabytes = 128
    static let maximumCacheMegabytes = 512
    static let cacheStepMegabytes = 32

    static func clampedCacheMegabytes(_ value: Int) -> Int {
        min(max(value, minimumCacheMegabytes), maximumCacheMegabytes)
    }

    static func cacheBytes(megabytes: Int) -> Int {
        clampedCacheMegabytes(megabytes) * 1_024 * 1_024
    }

    static func apply(to terminal: Terminal, cacheMegabytes: Int) {
        terminal.options.enableSixelReported = true
        terminal.options.kittyImageCacheLimitBytes = cacheBytes(megabytes: cacheMegabytes)
    }

    /// Options for a view whose terminal is created once and then hidden. SwiftTerm 1.99 keeps
    /// the terminal internal, so the graphics cache has to be chosen up front. The default
    /// reports sixel already, and the Kitty limit is per screen rather than shared.
    static func terminalOptions(cacheMegabytes: Int) -> TerminalOptions {
        var options = TerminalOptions.default
        options.enableSixelReported = true
        options.kittyGraphics.storageLimitBytesPerScreen = UInt32(
            clamping: cacheBytes(megabytes: cacheMegabytes)
        )
        return options
    }

    static func environmentVariables(appVersion: String) -> [String: String] {
        [
            "COLORTERM": "truecolor",
            "LC_TERMINAL": "MuseTerm",
            "LC_TERMINAL_VERSION": appVersion,
            "MUSETERM_GRAPHICS_PROTOCOLS": supportedProtocols.joined(separator: ","),
            "TERM_PROGRAM": "MuseTerm",
            "TERM_PROGRAM_VERSION": appVersion
        ]
    }
}
