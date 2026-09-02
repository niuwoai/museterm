import SwiftTerm
import XCTest
@testable import museterm

final class TerminalGraphicsPolicyTests: XCTestCase {
    func testDefaultGraphicsPolicyAdvertisesSixelAndCapsKittyCache() {
        let terminal = Terminal(
            delegate: GraphicsTerminalDelegate(),
            options: TerminalOptions(cols: 80, rows: 24)
        )

        TerminalGraphicsPolicy.apply(
            to: terminal,
            cacheMegabytes: TerminalGraphicsPolicy.defaultCacheMegabytes
        )

        XCTAssertTrue(terminal.options.enableSixelReported)
        XCTAssertEqual(
            terminal.options.kittyImageCacheLimitBytes,
            128 * 1_024 * 1_024
        )
    }

    func testGraphicsCacheClampsToSupportedRange() {
        XCTAssertEqual(TerminalGraphicsPolicy.clampedCacheMegabytes(1), 32)
        XCTAssertEqual(TerminalGraphicsPolicy.clampedCacheMegabytes(192), 192)
        XCTAssertEqual(TerminalGraphicsPolicy.clampedCacheMegabytes(2_048), 512)
    }

    func testGraphicsEnvironmentAdvertisesAppAndProtocols() {
        let environment = TerminalGraphicsPolicy.environmentVariables(appVersion: "1.2.3-rc1")

        XCTAssertEqual(environment["TERM_PROGRAM"], "MuseTerm")
        XCTAssertEqual(environment["TERM_PROGRAM_VERSION"], "1.2.3-rc1")
        XCTAssertEqual(environment["LC_TERMINAL"], "MuseTerm")
        XCTAssertEqual(environment["LC_TERMINAL_VERSION"], "1.2.3-rc1")
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(environment["MUSETERM_GRAPHICS_PROTOCOLS"], "kitty,iterm2,sixel")
    }

    func testImageCachePreferencePersistsAndClamps() throws {
        let suiteName = "museterm.graphics.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.imageCacheMegabytes, 128)

        preferences.imageCacheMegabytes = 256
        XCTAssertEqual(TerminalPreferences(defaults: defaults).imageCacheMegabytes, 256)

        preferences.imageCacheMegabytes = 4_096
        XCTAssertEqual(preferences.imageCacheMegabytes, 512)
        XCTAssertEqual(TerminalPreferences(defaults: defaults).imageCacheMegabytes, 512)
    }

    func testITerm2InlineImageSequenceDeliversEncodedImage() throws {
        let delegate = GraphicsTerminalDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24)
        )
        let png = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let sequence = "\u{1b}]1337;File=inline=1;width=2;height=1:"
            + png.base64EncodedString()
            + "\u{7}"

        terminal.feed(text: sequence)

        XCTAssertEqual(delegate.encodedImages.count, 1)
        XCTAssertEqual(delegate.encodedImages.first?.data, png)
        XCTAssertEqual(delegate.encodedImages.first?.preserveAspectRatio, true)
    }

    func testKittyInlinePNGSequenceDeliversEncodedImage() throws {
        let delegate = GraphicsTerminalDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24)
        )
        TerminalGraphicsPolicy.apply(to: terminal, cacheMegabytes: 128)
        let png = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let sequence = "\u{1b}_Gf=100,a=T,i=7,q=2;"
            + png.base64EncodedString()
            + "\u{1b}\\"

        terminal.feed(text: sequence)

        XCTAssertEqual(delegate.encodedImages.count, 1)
        XCTAssertEqual(delegate.encodedImages.first?.data, png)
    }

    func testSixelSequenceDeliversRGBABitmap() {
        let delegate = GraphicsTerminalDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24)
        )
        TerminalGraphicsPolicy.apply(to: terminal, cacheMegabytes: 128)

        terminal.feed(text: "\u{1b}Pq#0;2;100;0;0~$\u{1b}\\")

        XCTAssertEqual(delegate.bitmaps.count, 1)
        XCTAssertEqual(delegate.bitmaps.first?.width, 1)
        XCTAssertEqual(delegate.bitmaps.first?.height, 6)
        XCTAssertEqual(delegate.bitmaps.first?.bytes.count, 24)
    }

    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/xcAAwMCAO6V2yEAAAAASUVORK5CYII="
}

private final class GraphicsTerminalDelegate: TerminalDelegate {
    struct EncodedImage {
        let data: Data
        let preserveAspectRatio: Bool
    }

    struct Bitmap {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    private(set) var encodedImages: [EncodedImage] = []
    private(set) var bitmaps: [Bitmap] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    func createImageFromBitmap(
        source: Terminal,
        bytes: inout [UInt8],
        width: Int,
        height: Int
    ) {
        bitmaps.append(Bitmap(bytes: bytes, width: width, height: height))
    }

    func createImage(
        source: Terminal,
        data: Data,
        width: ImageSizeRequest,
        height: ImageSizeRequest,
        preserveAspectRatio: Bool
    ) {
        encodedImages.append(
            EncodedImage(data: data, preserveAspectRatio: preserveAspectRatio)
        )
    }
}
