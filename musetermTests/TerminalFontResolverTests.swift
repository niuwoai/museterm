import AppKit
import CoreText
import XCTest
@testable import museterm

final class TerminalFontResolverTests: XCTestCase {
    func testSanitizeTrimsDropsEmptiesAndDeduplicatesCaseInsensitively() {
        let sanitized = TerminalFontResolver.sanitizedFallbackFamilies([
            "  PingFang SC  ",
            "",
            "   ",
            "pingfang sc",
            "Menlo"
        ])

        XCTAssertEqual(sanitized, ["PingFang SC", "Menlo"])
    }

    func testSanitizePreservesOrderAndCapsAtMaximum() {
        let families = (0..<(TerminalFontResolver.maximumFallbackFamilies + 4)).map { "Family \($0)" }

        let sanitized = TerminalFontResolver.sanitizedFallbackFamilies(families)

        XCTAssertEqual(sanitized.count, TerminalFontResolver.maximumFallbackFamilies)
        XCTAssertEqual(sanitized.first, "Family 0")
        XCTAssertEqual(sanitized, Array(families.prefix(TerminalFontResolver.maximumFallbackFamilies)))
    }

    func testCascadeListKeepsEveryInstalledFallbackInOrder() throws {
        let font = TerminalFontResolver.font(
            primaryFamily: "Menlo",
            fallbackFamilies: ["Apple Symbols", "PingFang SC"],
            size: 14
        )

        let cascade = try XCTUnwrap(
            font.fontDescriptor.fontAttributes[.cascadeList] as? [NSFontDescriptor]
        )
        XCTAssertEqual(cascade.count, 2)
    }

    func testMissingFallbackIsSkippedInsteadOfBreakingTheChain() throws {
        let font = TerminalFontResolver.font(
            primaryFamily: "Menlo",
            fallbackFamilies: ["No Such Font \(UUID().uuidString)", "PingFang SC"],
            size: 14
        )

        let cascade = try XCTUnwrap(
            font.fontDescriptor.fontAttributes[.cascadeList] as? [NSFontDescriptor]
        )
        XCTAssertEqual(cascade.count, 1)
        XCTAssertEqual(resolvedFontName(for: "中", in: font), "PingFangSC-Regular")
    }

    /// 回归本次修复的核心场景：主字体画不出的字符要沿列表逐个向后找，
    /// 而不是只认第一个回退字体。
    func testSecondFallbackStillResolvesWhenFirstLacksTheGlyph() {
        let font = TerminalFontResolver.font(
            primaryFamily: "Menlo",
            fallbackFamilies: ["Apple Symbols", "PingFang SC"],
            size: 14
        )

        XCTAssertEqual(resolvedFontName(for: "中", in: font), "PingFangSC-Regular")
    }

    func testEmptyFallbackListLeavesPrimaryFontUntouched() {
        let font = TerminalFontResolver.font(
            primaryFamily: "Menlo",
            fallbackFamilies: [],
            size: 14
        )

        XCTAssertNil(font.fontDescriptor.fontAttributes[.cascadeList])
        XCTAssertEqual(font.fontName, "Menlo-Regular")
    }

    func testPreferencesMigrateLegacySingleFallbackKey() throws {
        let suiteName = "museterm.font.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("icons-in-terminal", forKey: "terminal.fallbackFontFamily")

        let preferences = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.fallbackFontFamilies, ["icons-in-terminal"])
    }

    func testPreferencesPersistOrderedListAndMirrorLegacyKey() throws {
        let suiteName = "museterm.font.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        preferences.fallbackFontFamilies = ["PingFang SC", "icons-in-terminal"]

        XCTAssertEqual(
            TerminalPreferences(defaults: defaults).fallbackFontFamilies,
            ["PingFang SC", "icons-in-terminal"]
        )
        // 降级安装到旧版本时仍要读到一个合理的单字体值
        XCTAssertEqual(defaults.string(forKey: "terminal.fallbackFontFamily"), "PingFang SC")
    }

    func testPreferencesSanitizeOnAssignmentAndKeepDeliberateEmptyList() throws {
        let suiteName = "museterm.font.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        preferences.fallbackFontFamilies = ["  Menlo  ", "menlo", ""]
        XCTAssertEqual(preferences.fallbackFontFamilies, ["Menlo"])

        preferences.fallbackFontFamilies = []
        XCTAssertEqual(TerminalPreferences(defaults: defaults).fallbackFontFamilies, [])
    }

    func testDefaultFallbackAppliesWhenNothingStored() throws {
        let suiteName = "museterm.font.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            TerminalPreferences(defaults: defaults).fallbackFontFamilies,
            TerminalPreferences.defaultFallbackFontFamilies
        )
    }

    private func resolvedFontName(for character: String, in font: NSFont) -> String {
        let resolved = CTFontCreateForString(
            font as CTFont,
            character as CFString,
            CFRangeMake(0, character.utf16.count)
        )
        return CTFontCopyPostScriptName(resolved) as String
    }
}
