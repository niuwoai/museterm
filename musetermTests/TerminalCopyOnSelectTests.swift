import XCTest
@testable import museterm

final class TerminalCopyOnSelectTests: XCTestCase {
    func testCopiesSelectionChangedByMouseGesture() {
        XCTAssertEqual(
            TerminalCopyOnSelectPolicy.textToCopy(
                isEnabled: true,
                selectionChangedDuringGesture: true,
                selection: "  git status\n"
            ),
            "  git status\n",
            "复制内容应与 Cmd+C 一致，不裁剪首尾空白"
        )
    }

    func testDoesNotCopyWhenDisabled() {
        XCTAssertNil(
            TerminalCopyOnSelectPolicy.textToCopy(
                isEnabled: false,
                selectionChangedDuringGesture: true,
                selection: "git status"
            )
        )
    }

    func testDoesNotRecopyStaleSelectionWhenGestureLeftItUntouched() {
        // 鼠标上报模式下点击会被转发给 tmux/vim，选区不变，不应覆盖剪贴板
        XCTAssertNil(
            TerminalCopyOnSelectPolicy.textToCopy(
                isEnabled: true,
                selectionChangedDuringGesture: false,
                selection: "old selection"
            )
        )
    }

    func testDoesNotCopyClearedOrBlankSelection() {
        for selection in [nil, "", "   ", "\n\t "] as [String?] {
            XCTAssertNil(
                TerminalCopyOnSelectPolicy.textToCopy(
                    isEnabled: true,
                    selectionChangedDuringGesture: true,
                    selection: selection
                ),
                "selection: \(String(describing: selection))"
            )
        }
    }

    func testPreferenceDefaultsToEnabledAndPersistsOptOut() throws {
        let suiteName = "museterm.copy-on-select.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        XCTAssertTrue(preferences.copyOnSelect)

        preferences.copyOnSelect = false

        XCTAssertFalse(TerminalPreferences(defaults: defaults).copyOnSelect)
    }
}
