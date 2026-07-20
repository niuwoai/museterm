import AppKit
import XCTest
@testable import museterm

final class TerminalVisualSkinTests: XCTestCase {
    func testEverySkinPreviewUsesReadableTerminalForegroundAndBackground() throws {
        for skin in TerminalVisualSkin.allCases {
            let contrast = try contrastRatio(
                foreground: skin.terminalForeground,
                background: skin.terminalBackground
            )

            XCTAssertGreaterThanOrEqual(
                contrast,
                4.5,
                "\(skin.rawValue) preview contrast was only \(contrast):1"
            )
        }
    }

    private func contrastRatio(foreground: NSColor, background: NSColor) throws -> CGFloat {
        let foregroundLuminance = try relativeLuminance(foreground)
        let backgroundLuminance = try relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) throws -> CGFloat {
        let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return 0.2126 * linearized(rgb.redComponent)
            + 0.7152 * linearized(rgb.greenComponent)
            + 0.0722 * linearized(rgb.blueComponent)
    }

    private func linearized(_ component: CGFloat) -> CGFloat {
        if component <= 0.04045 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}
