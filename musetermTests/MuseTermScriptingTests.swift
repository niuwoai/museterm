import Foundation
import XCTest
@testable import museterm

final class MuseTermScriptingTests: XCTestCase {
    // MARK: - sdef 词典

    private func loadSdefDocument() throws -> XMLDocument {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "museterm", withExtension: "sdef"),
            "museterm.sdef 应随 App 打包"
        )
        return try XMLDocument(contentsOf: url)
    }

    func testSdefIsBundledAndWellFormed() throws {
        let document = try loadSdefDocument()
        XCTAssertEqual(document.rootElement()?.name, "dictionary")
        XCTAssertEqual(document.rootElement()?.attribute(forName: "title")?.stringValue, "QTerm Terminology")
        XCTAssertEqual(
            try document.nodes(forXPath: "//suite[@code='MTrm']/@name").first?.stringValue,
            "QTerm Suite"
        )
    }

    func testSdefDeclaresExpectedCommandsAndClasses() throws {
        let document = try loadSdefDocument()

        let commandNames = try document.nodes(forXPath: "//command/@name")
            .compactMap(\.stringValue)
        for expected in ["create tab", "close tab", "open ssh profile", "write text", "send key", "execute", "play shortcut", "select"] {
            XCTAssertTrue(commandNames.contains(expected), "sdef 缺少命令 \(expected)")
        }

        let classNames = try document.nodes(forXPath: "//class/@name")
            .compactMap(\.stringValue)
        for expected in ["tab", "command record"] {
            XCTAssertTrue(classNames.contains(expected), "sdef 缺少类 \(expected)")
        }

        // 标准套件（get/set/count/close 等）经 XInclude 引入；application 用 class-extension 挂接。
        let includeHrefs = try document.nodes(forXPath: "//*[local-name()='include']/@href")
            .compactMap(\.stringValue)
        XCTAssertTrue(
            includeHrefs.contains { $0.contains("CocoaStandard.sdef") },
            "sdef 应引入 CocoaStandard 标准套件"
        )
        let classExtensions = try document.nodes(forXPath: "//class-extension/@extends")
            .compactMap(\.stringValue)
        XCTAssertTrue(classExtensions.contains("application"))
        // tab 需响应标准 close 命令。
        let respondsTo = try document.nodes(forXPath: "//class[@name='tab']/responds-to/@command")
            .compactMap(\.stringValue)
        XCTAssertTrue(respondsTo.contains("close"))
        XCTAssertTrue(respondsTo.contains("select"))

        // cocoa class 名必须与 @objc 导出名一致，否则运行时解析不到实现。
        let cocoaClasses = try document.nodes(forXPath: "//class/cocoa/@class")
            .compactMap(\.stringValue)
        XCTAssertTrue(cocoaClasses.contains("MuseTermScriptTab"))
        XCTAssertTrue(cocoaClasses.contains("MuseTermScriptCommandRecord"))
        XCTAssertNotNil(NSClassFromString("MuseTermScriptTab"))
        XCTAssertNotNil(NSClassFromString("MuseTermScriptCommandRecord"))

        let commandClasses = try document.nodes(forXPath: "//command/cocoa/@class")
            .compactMap(\.stringValue)
        for name in commandClasses {
            XCTAssertNotNil(NSClassFromString(name), "sdef 引用的命令类 \(name) 不存在")
        }
    }

    func testCloseTabCommandDeclaresExplicitSkipConfirmationParameter() throws {
        let document = try loadSdefDocument()
        let command = try XCTUnwrap(
            document.nodes(forXPath: "//command[@name='close tab']").first as? XMLElement
        )
        XCTAssertEqual(command.attribute(forName: "code")?.stringValue, "MTrmCltb")

        let parameters = try command.nodes(forXPath: "parameter")
        let skipParameter = try XCTUnwrap(parameters.first as? XMLElement)
        XCTAssertEqual(skipParameter.attribute(forName: "name")?.stringValue, "skipping confirmation")
        XCTAssertEqual(skipParameter.attribute(forName: "type")?.stringValue, "boolean")
        XCTAssertEqual(
            try skipParameter.nodes(forXPath: "cocoa/@key").first?.stringValue,
            "skipConfirmation"
        )
    }

    func testSdefSameNamedTermsShareCodes() throws {
        // AppleScript 术语表按名字全局编译：同名 property 在不同类/记录里必须用同一个 code，
        // 否则编译器可能选错 code，导致对象属性读取失败（历史教训：exit code 曾撞车）。
        let document = try loadSdefDocument()
        let properties = try document.nodes(forXPath: "//property")
        var codeByName: [String: String] = [:]
        for node in properties {
            guard let element = node as? XMLElement,
                  let name = element.attribute(forName: "name")?.stringValue,
                  let code = element.attribute(forName: "code")?.stringValue else { continue }
            if let existing = codeByName[name] {
                XCTAssertEqual(existing, code, "属性 \(name) 在 sdef 中使用了不同的 code：\(existing) vs \(code)")
            } else {
                codeByName[name] = code
            }
        }
    }

    func testInfoPlistEnablesAppleScript() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["NSAppleScriptEnabled"] as? Bool, true)
        XCTAssertEqual(info["OSAScriptingDefinition"] as? String, "museterm.sdef")
    }

    // MARK: - 偏好

    func testAppleScriptInputEnabledDefaultsToTrueAndPersists() throws {
        let suiteName = "museterm.tests.applescript.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        XCTAssertTrue(preferences.appleScriptInputEnabled, "默认应允许 AppleScript 写入")

        preferences.appleScriptInputEnabled = false
        let reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.appleScriptInputEnabled, "关闭状态应持久化")
    }

    // MARK: - 安全策略

    @MainActor
    func testScriptedInputGateReflectsPreference() throws {
        let suiteName = "museterm.tests.applescript.gate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        let workspace = TerminalWorkspace()
        let sshStore = SSHConnectionStore(defaults: defaults)
        MuseTermScriptingRegistry.attach(workspace: workspace, preferences: preferences, sshStore: sshStore)

        XCTAssertTrue(MuseTermScriptingRegistry.isScriptedInputAllowed)
        preferences.appleScriptInputEnabled = false
        XCTAssertFalse(MuseTermScriptingRegistry.isScriptedInputAllowed, "关闭开关后写入 gate 应立即拒绝")
        preferences.appleScriptInputEnabled = true
        XCTAssertTrue(MuseTermScriptingRegistry.isScriptedInputAllowed)
    }

    func testProtectedShortcutIsNotPlayableFromScripts() {
        let protectedShortcut = TerminalShortcut(
            id: UUID(),
            title: "with password",
            createdAt: Date(),
            updatedAt: Date(),
            durationMilliseconds: 100,
            events: [
                TerminalShortcutEvent(
                    delayMilliseconds: 0,
                    bytes: [],
                    requiresEchoOff: true,
                    transientProtectedBytes: [0x61]
                )
            ],
            hasProtectedInput: true
        )
        XCTAssertFalse(MuseTermScriptingPolicy.canPlay(protectedShortcut))

        let plainShortcut = TerminalShortcut(
            id: UUID(),
            title: "plain",
            createdAt: Date(),
            updatedAt: Date(),
            durationMilliseconds: 100,
            events: [
                TerminalShortcutEvent(delayMilliseconds: 0, bytes: [0x6C, 0x73, 0x0D])
            ],
            hasProtectedInput: false
        )
        XCTAssertTrue(MuseTermScriptingPolicy.canPlay(plainShortcut))

        let emptyShortcut = TerminalShortcut(
            id: UUID(),
            title: "empty",
            createdAt: Date(),
            updatedAt: Date(),
            durationMilliseconds: 0,
            events: [],
            hasProtectedInput: false
        )
        XCTAssertFalse(MuseTermScriptingPolicy.canPlay(emptyShortcut), "空快捷方式不可回放")
    }

    func testShortcutAutomationHonorsPerRecordingAccess() {
        let lockedOut = shortcut(allowsAutomationPlayback: false)
        XCTAssertEqual(MuseTermScriptingPolicy.automationDenial(lockedOut), .automationDisabled)
        XCTAssertFalse(MuseTermScriptingPolicy.canPlay(lockedOut))

        let touchID = shortcut(requiresUserAuthentication: true)
        XCTAssertNil(MuseTermScriptingPolicy.automationDenial(touchID), "需要本人验证的录制仍可回放，只是要先通过 Touch ID")
        XCTAssertTrue(MuseTermScriptingPolicy.canPlay(touchID))
        XCTAssertEqual(TerminalShortcutPlayback.decision(for: touchID, origin: .automation), .authenticate)
        XCTAssertEqual(TerminalShortcutPlayback.decision(for: touchID, origin: .user), .authenticate)

        let open = shortcut()
        XCTAssertEqual(TerminalShortcutPlayback.decision(for: open, origin: .user), .play)
        XCTAssertEqual(TerminalShortcutPlayback.decision(for: open, origin: .automation), .play)

        XCTAssertEqual(
            TerminalShortcutPlayback.decision(for: lockedOut, origin: .automation),
            .deny(.automationDisabled)
        )
        XCTAssertEqual(TerminalShortcutPlayback.decision(for: lockedOut, origin: .user), .play)
    }

    func testLegacyShortcutJSONKeepsDirectReplay() throws {
        let id = UUID()
        let json = """
        [{
          "id": "\(id.uuidString)",
          "title": "old",
          "createdAt": "1970-01-01T00:00:01Z",
          "updatedAt": "1970-01-01T00:00:02Z",
          "durationMilliseconds": 10,
          "events": [{"id": "\(UUID().uuidString)", "delayMilliseconds": 0, "text": "ls\\r", "requiresEchoOff": false}],
          "hasProtectedInput": false
        }]
        """
        let decoded = try TerminalShortcutStore.decodeEditableText(json)
        let shortcut = try XCTUnwrap(decoded.first)
        XCTAssertFalse(shortcut.requiresUserAuthentication)
        XCTAssertTrue(shortcut.allowsAutomationPlayback)
        XCTAssertEqual(TerminalShortcutPlayback.decision(for: shortcut, origin: .automation), .play)
    }

    func testPlaybackBeginsOnlyAfterAuthenticationSucceeds() {
        let authenticator = ScriptedShortcutAuthenticator()
        let previous = TerminalShortcutPlayback.authenticator
        TerminalShortcutPlayback.authenticator = authenticator
        defer { TerminalShortcutPlayback.authenticator = previous }

        var results: [Result<Void, TerminalShortcutPlaybackError>] = []
        TerminalShortcutPlayback.begin(
            shortcut: shortcut(requiresUserAuthentication: true),
            origin: .automation,
            invalidateAfter: nil
        ) { results.append($0) }
        XCTAssertTrue(results.isEmpty, "指纹还没通过时不能开始回放")

        authenticator.succeed()
        XCTAssertEqual(results.count, 1)
        guard case .success = results.first else {
            return XCTFail("验证通过后应该允许回放")
        }

        TerminalShortcutPlayback.begin(
            shortcut: shortcut(allowsAutomationPlayback: false),
            origin: .automation,
            invalidateAfter: nil
        ) { results.append($0) }
        XCTAssertEqual(results.count, 2)
        if case .failure(let error) = results[1] {
            XCTAssertEqual(error, .automationDisabled)
            XCTAssertEqual(error.scriptErrorCode, MuseTermScriptErrorCode.shortcutAutomationDisabled)
        } else {
            XCTFail("关闭 AI 回放的录制应该直接拒绝")
        }
    }

    private func shortcut(
        requiresUserAuthentication: Bool = false,
        allowsAutomationPlayback: Bool = true,
        events: [TerminalShortcutEvent] = [TerminalShortcutEvent(delayMilliseconds: 0, bytes: [0x0D])]
    ) -> TerminalShortcut {
        TerminalShortcut(
            id: UUID(),
            title: "deploy",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            durationMilliseconds: 10,
            events: events,
            hasProtectedInput: false,
            requiresUserAuthentication: requiresUserAuthentication,
            allowsAutomationPlayback: allowsAutomationPlayback
        )
    }
}

private final class ScriptedShortcutAuthenticator: TerminalUserAuthenticating {
    private var completions: [(Result<Void, TerminalShortcutPlaybackError>) -> Void] = []

    func authenticate(
        localizedReason: String,
        invalidateAfter: TimeInterval?,
        completion: @escaping @Sendable (Result<Void, TerminalShortcutPlaybackError>) -> Void
    ) {
        completions.append(completion)
    }

    func succeed() {
        let pending = completions
        completions = []
        pending.forEach { $0(.success(())) }
    }
}

extension MuseTermScriptingTests {
    func testExecuteTimeoutClamping() {
        XCTAssertEqual(MuseTermScriptingPolicy.clampedExecuteTimeout(nil), 120)
        XCTAssertEqual(MuseTermScriptingPolicy.clampedExecuteTimeout(0), 1)
        XCTAssertEqual(MuseTermScriptingPolicy.clampedExecuteTimeout(-5), 1)
        XCTAssertEqual(MuseTermScriptingPolicy.clampedExecuteTimeout(60), 60)
        XCTAssertEqual(MuseTermScriptingPolicy.clampedExecuteTimeout(999_999), 3600)
    }

    // MARK: - 执行结果记录

    func testExecutionResultFields() throws {
        let record = MuseTermScriptRecords.executionResult(
            exitCode: 0,
            output: "hello",
            durationMilliseconds: 1500
        )
        XCTAssertEqual(record["succeeded"] as? Bool, true)
        XCTAssertEqual(record["exitCode"] as? Int, 0)
        XCTAssertEqual(record["commandOutput"] as? String, "hello")
        XCTAssertEqual(try XCTUnwrap(record["durationSeconds"] as? Double), 1.5, accuracy: 0.0001)
    }

    func testExecutionResultUnknownExit() {
        let record = MuseTermScriptRecords.executionResult(
            exitCode: nil,
            output: "",
            durationMilliseconds: nil
        )
        XCTAssertEqual(record["succeeded"] as? Bool, false)
        XCTAssertEqual(record["exitCode"] as? Int, -1)
        XCTAssertEqual(record["durationSeconds"] as? Double, -1)
    }

    func testExecutionResultKeysMatchSdefCocoaKeys() throws {
        // 字典键必须与 sdef execution result 各属性的 cocoa key 一致，否则记录字段静默丢失。
        let document = try loadSdefDocument()
        let cocoaKeys = Set(
            try document.nodes(forXPath: "//record-type[@name='execution result']/property/cocoa/@key")
                .compactMap(\.stringValue)
        )
        let record = MuseTermScriptRecords.executionResult(exitCode: 0, output: "", durationMilliseconds: 0)
        XCTAssertEqual(Set(record.keys), cocoaKeys)
    }

    func testFourCC() {
        XCTAssertEqual(MuseTermScriptRecords.fourCC("XSok"), 0x58536F6B)
    }
}
