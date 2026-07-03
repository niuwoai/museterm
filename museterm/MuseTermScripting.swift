import AppKit
import Foundation

// MARK: - 桥接注册表

// Cocoa Scripting 层没法直接拿到 SwiftUI 场景里的对象，
// ContentView.onAppear 时把 workspace / preferences / sshStore 挂到这里（与 Tool Bridge 同点位）。
@MainActor
enum MuseTermScriptingRegistry {
    private(set) static weak var workspace: TerminalWorkspace?
    private(set) static weak var preferences: TerminalPreferences?
    private(set) static weak var sshStore: SSHConnectionStore?

    static func attach(
        workspace: TerminalWorkspace,
        preferences: TerminalPreferences,
        sshStore: SSHConnectionStore
    ) {
        self.workspace = workspace
        self.preferences = preferences
        self.sshStore = sshStore
    }

    static var isScriptedInputAllowed: Bool {
        preferences?.appleScriptInputEnabled ?? true
    }
}

// MARK: - 错误码

enum MuseTermScriptErrorCode {
    static let noWorkspace = -31000
    static let tabNotFound = -31001
    static let inputDisabled = -31002
    static let unknownKey = -31003
    static let processUnavailable = -31004
    static let profileNotFound = -31005
    static let shortcutNotFound = -31006
    static let shortcutProtected = -31007
    static let executionTimeout = -31008
    static let emptyInput = -31009
    static let closeCancelled = -31010
}

// MARK: - 纯逻辑（可单测）

enum MuseTermScriptingPolicy {
    // 含受保护输入（echo-off 密码段）的快捷方式禁止通过脚本接口回放。
    nonisolated static func canPlay(_ shortcut: TerminalShortcut) -> Bool {
        shortcut.isPlayable && !shortcut.hasProtectedInput
    }

    nonisolated static func clampedExecuteTimeout(_ requested: Int?) -> TimeInterval {
        TimeInterval(min(max(requested ?? 120, 1), 3600))
    }
}

enum MuseTermScriptRecords {
    nonisolated static func fourCC(_ code: String) -> FourCharCode {
        var result: FourCharCode = 0
        for byte in code.utf8 {
            result = (result << 8) | FourCharCode(byte)
        }
        return result
    }

    // execute 命令的返回记录：键为 sdef execution result 各属性的 cocoa key，
    // Cocoa Scripting 按 record-type 声明自动转换为 AppleScript 记录。
    nonisolated static func executionResult(
        exitCode: Int32?,
        output: String,
        durationMilliseconds: Int?
    ) -> [String: Any] {
        // NUL 来自终端空单元；头尾空白对脚本消费者只是噪音。
        let cleanedOutput = output
            .replacingOccurrences(of: "\0", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "succeeded": exitCode == 0,
            "exitCode": Int(exitCode ?? -1),
            "commandOutput": cleanedOutput,
            "durationSeconds": durationMilliseconds.map { Double($0) / 1000 } ?? -1.0,
        ]
    }
}

// MARK: - NSApplication 的脚本属性

extension NSApplication {
    @objc var scriptTabs: [MuseTermScriptTab] {
        guard let workspace = MuseTermScriptingRegistry.workspace else { return [] }
        MuseTermScriptTab.prune(existingIDs: Set(workspace.tabs.map(\.id)))
        return workspace.tabs.map { MuseTermScriptTab.wrapper(for: $0) }
    }

    @objc var scriptSelectedTab: Any? {
        get {
            guard let selected = MuseTermScriptingRegistry.workspace?.selectedTab else { return nil }
            return MuseTermScriptTab.wrapper(for: selected)
        }
        set {
            // set 命令传来的可能是已求值的包装器，也可能是未求值的对象说明符。
            let resolved: MuseTermScriptTab?
            switch newValue {
            case let tab as MuseTermScriptTab:
                resolved = tab
            case let specifier as NSScriptObjectSpecifier:
                resolved = specifier.objectsByEvaluatingSpecifier as? MuseTermScriptTab
            default:
                resolved = nil
            }
            guard let workspace = MuseTermScriptingRegistry.workspace,
                  let sessionID = resolved?.sessionID,
                  workspace.tabs.contains(where: { $0.id == sessionID }) else { return }
            workspace.selectedID = sessionID
        }
    }

    @objc var scriptInputAllowed: Bool {
        MuseTermScriptingRegistry.isScriptedInputAllowed
    }

    @objc(valueInScriptTabsWithUniqueID:)
    func valueInScriptTabs(withUniqueID uniqueID: String) -> MuseTermScriptTab? {
        guard let workspace = MuseTermScriptingRegistry.workspace,
              let session = workspace.tabs.first(where: { $0.id.uuidString == uniqueID }) else {
            return nil
        }
        return MuseTermScriptTab.wrapper(for: session)
    }
}

// MARK: - tab 包装器

// TerminalSession 不是 NSObject，Cocoa Scripting 需要 NSObject + objectSpecifier，
// 这里做一层弱引用包装；按会话 ID 缓存，保证同一标签多次解析拿到同一对象。
@objc(MuseTermScriptTab)
final class MuseTermScriptTab: NSObject {
    let sessionID: UUID
    private(set) weak var session: TerminalSession?

    private static var cache: [UUID: MuseTermScriptTab] = [:]

    private init(session: TerminalSession) {
        sessionID = session.id
        self.session = session
        super.init()
    }

    static func wrapper(for session: TerminalSession) -> MuseTermScriptTab {
        if let existing = cache[session.id], existing.session != nil {
            return existing
        }
        let wrapper = MuseTermScriptTab(session: session)
        cache[session.id] = wrapper
        return wrapper
    }

    static func prune(existingIDs: Set<UUID>) {
        cache = cache.filter { existingIDs.contains($0.key) }
    }

    // 注册表里 'capp' 可能有多份描述（Standard Suite 原始版 + class-extension 合并版），
    // 打包 specifier 必须用带 scriptTabs 关系的那一份，否则回复阶段抛异常、脚本收到 -1708。
    static let applicationClassDescription: NSScriptClassDescription? = {
        let registry = NSScriptSuiteRegistry.shared()
        for suiteName in registry.suiteNames {
            let descriptions = registry.classDescriptions(inSuite: suiteName) ?? [:]
            for description in descriptions.values
            where description.appleEventCode == MuseTermScriptRecords.fourCC("capp")
                && description.hasOrderedToManyRelationship(forKey: "scriptTabs") {
                return description
            }
        }
        return nil
    }()

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let appDescription = Self.applicationClassDescription else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: appDescription,
            containerSpecifier: nil,
            key: "scriptTabs",
            uniqueID: sessionID.uuidString
        )
    }

    // MARK: 脚本属性（cocoa key 与 sdef 对应）

    @objc var uniqueID: String { sessionID.uuidString }

    @objc var orderedIndex: Int {
        guard let workspace = MuseTermScriptingRegistry.workspace,
              let index = workspace.tabs.firstIndex(where: { $0.id == sessionID }) else {
            return 0
        }
        return index + 1
    }

    @objc var title: String { session?.tabTitle ?? "" }

    @objc var currentDirectory: String? { session?.currentDirectory }

    @objc var shellName: String? { session?.shellName }

    @objc var busy: Bool { session?.hasRunningProcess ?? false }

    @objc var stateText: String { session?.toolStateText ?? "unknown" }

    @objc var selected: Bool {
        get { MuseTermScriptingRegistry.workspace?.selectedTab?.id == sessionID }
        set {
            guard newValue, let workspace = MuseTermScriptingRegistry.workspace,
                  workspace.tabs.contains(where: { $0.id == sessionID }) else { return }
            workspace.selectedID = sessionID
        }
    }

    // 终端 buffer 空单元会以 NUL 出现在文本里，对脚本消费者是陷阱（grep 会按二进制处理），统一替换为空格。
    @objc var screenContents: String {
        (session?.controller.visibleScreenText() ?? "")
            .replacingOccurrences(of: "\0", with: " ")
    }

    @objc var historyContents: String {
        guard let session else { return "" }
        return String(session.controller.latestHistoryText().suffix(240_000))
            .replacingOccurrences(of: "\0", with: " ")
    }

    @objc var columns: Int { session?.controller.terminalColumns ?? 0 }

    @objc var rows: Int { session?.controller.terminalRows ?? 0 }

    @objc var scriptCommandRecords: [MuseTermScriptCommandRecord] {
        guard let session else { return [] }
        return session.commandBlocks.suffix(50).enumerated().map { offset, block in
            MuseTermScriptCommandRecord(block: block, tab: self, index: offset)
        }
    }

    @objc(valueInScriptCommandRecordsWithUniqueID:)
    func valueInScriptCommandRecords(withUniqueID uniqueID: String) -> MuseTermScriptCommandRecord? {
        scriptCommandRecords.first { $0.uniqueID == uniqueID }
    }

    // MARK: 接收者命令

    @objc(handleCloseScriptCommand:)
    func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        guard let workspace = MuseTermScriptingRegistry.workspace, let session else {
            command.scriptErrorNumber = MuseTermScriptErrorCode.tabNotFound
            command.scriptErrorString = L10n.format("tools.error.tab_not_found", sessionID.uuidString)
            return nil
        }
        // close 可能被「关闭前确认」对话框取消，取消时向脚本报告错误而不是静默成功。
        if !workspace.close(session) {
            command.scriptErrorNumber = MuseTermScriptErrorCode.closeCancelled
            command.scriptErrorString = L10n.string("applescript.error.close_cancelled")
        }
        return nil
    }

    @objc(handleSelectScriptCommand:)
    func handleSelectScriptCommand(_ command: NSScriptCommand) -> Any? {
        selected = true
        return nil
    }
}

// MARK: - command record 包装器

@objc(MuseTermScriptCommandRecord)
final class MuseTermScriptCommandRecord: NSObject {
    private let block: TerminalCommandBlock
    private weak var tab: MuseTermScriptTab?
    private let index: Int

    init(block: TerminalCommandBlock, tab: MuseTermScriptTab, index: Int) {
        self.block = block
        self.tab = tab
        self.index = index
        super.init()
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let tab,
              let tabDescription = tab.classDescription as? NSScriptClassDescription else {
            return nil
        }
        return NSIndexSpecifier(
            containerClassDescription: tabDescription,
            containerSpecifier: tab.objectSpecifier,
            key: "scriptCommandRecords",
            index: index
        )
    }

    @objc var uniqueID: String { block.id.uuidString }
    @objc var commandText: String { block.command }
    @objc var exitCodeNumber: Int { block.exitCode.map(Int.init) ?? -1 }
    @objc var running: Bool { block.endedAt == nil }
    @objc var outputTail: String { block.outputTail }
    @objc var durationSeconds: Double { block.durationMilliseconds.map { Double($0) / 1000 } ?? -1 }
    @objc var workingDirectory: String? { block.workingDirectory }
    @objc var startedAt: Date { block.startedAt }
    @objc var endedAt: Date? { block.endedAt }
}

// MARK: - 命令基础设施

extension NSScriptCommand {
    func museFail(_ code: Int, _ message: String) -> Any? {
        scriptErrorNumber = code
        scriptErrorString = message
        return nil
    }

    // to/in 参数缺省时回落到选中标签。
    func museResolveTargetTab(argumentKey: String) -> (MuseTermScriptTab, TerminalSession)? {
        let explicit = evaluatedArguments?[argumentKey] as? MuseTermScriptTab
        if let explicit {
            guard let session = explicit.session else { return nil }
            return (explicit, session)
        }
        guard let selected = MuseTermScriptingRegistry.workspace?.selectedTab else { return nil }
        return (MuseTermScriptTab.wrapper(for: selected), selected)
    }

    func museSendInput(bytes: [UInt8], to session: TerminalSession) -> Any? {
        guard let workspace = MuseTermScriptingRegistry.workspace else {
            return museFail(MuseTermScriptErrorCode.noWorkspace, L10n.string("tools.error.no_workspace"))
        }
        session.startProcessIfNeeded()
        // 刚 create tab 的进程要等视图渲染后才真正启动（pending-start），
        // 这里短暂驱动主 RunLoop 让布局与启动推进，避免 create tab 后立刻写入必然失败。
        let deadline = Date().addingTimeInterval(3)
        while !session.controller.isProcessRunning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        do {
            try session.controller.sendToolInput(bytes: bytes)
        } catch {
            return museFail(MuseTermScriptErrorCode.processUnavailable, error.localizedDescription)
        }
        workspace.selectedID = session.id
        return nil
    }
}

// MARK: - create tab

@objc(MuseTermCreateTabScriptCommand)
final class MuseTermCreateTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let workspace = MuseTermScriptingRegistry.workspace else {
            return museFail(MuseTermScriptErrorCode.noWorkspace, L10n.string("tools.error.no_workspace"))
        }
        let rawDirectory = (evaluatedArguments?["directory"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = (rawDirectory?.isEmpty == false)
            ? NSString(string: rawDirectory!).expandingTildeInPath
            : nil
        workspace.newTab(startDirectory: directory)
        guard let tab = workspace.selectedTab else {
            return museFail(MuseTermScriptErrorCode.noWorkspace, L10n.string("tools.error.no_workspace"))
        }
        // 返回包装器对象本身，引擎会调用它的 objectSpecifier 打包成 tab 引用。
        return MuseTermScriptTab.wrapper(for: tab)
    }
}

// MARK: - open ssh profile

@objc(MuseTermOpenSSHProfileScriptCommand)
final class MuseTermOpenSSHProfileScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let workspace = MuseTermScriptingRegistry.workspace else {
            return museFail(MuseTermScriptErrorCode.noWorkspace, L10n.string("tools.error.no_workspace"))
        }
        let name = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return museFail(MuseTermScriptErrorCode.emptyInput, L10n.string("applescript.error.empty_input"))
        }
        let profiles = MuseTermScriptingRegistry.sshStore?.profiles ?? []
        let profile = profiles.first { $0.displayName == name }
            ?? profiles.first { $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame }
        guard let profile else {
            return museFail(
                MuseTermScriptErrorCode.profileNotFound,
                L10n.format("applescript.error.profile_not_found", name)
            )
        }
        workspace.openSSH(profile: profile)
        guard let tab = workspace.selectedTab else {
            return museFail(MuseTermScriptErrorCode.noWorkspace, L10n.string("tools.error.no_workspace"))
        }
        return MuseTermScriptTab.wrapper(for: tab)
    }
}

// MARK: - write text

@objc(MuseTermWriteTextScriptCommand)
final class MuseTermWriteTextScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard MuseTermScriptingRegistry.isScriptedInputAllowed else {
            return museFail(MuseTermScriptErrorCode.inputDisabled, L10n.string("applescript.error.input_disabled"))
        }
        guard let (_, session) = museResolveTargetTab(argumentKey: "targetTab") else {
            return museFail(
                MuseTermScriptErrorCode.tabNotFound,
                L10n.format("tools.error.tab_not_found", "selected")
            )
        }
        let text = directParameter as? String ?? ""
        let newline = evaluatedArguments?["newline"] as? Bool ?? true
        var bytes = Array(text.utf8)
        if newline {
            bytes.append(0x0D)
        }
        guard !bytes.isEmpty else {
            return museFail(MuseTermScriptErrorCode.emptyInput, L10n.string("applescript.error.empty_input"))
        }
        return museSendInput(bytes: bytes, to: session)
    }
}

// MARK: - send key

@objc(MuseTermSendKeyScriptCommand)
final class MuseTermSendKeyScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard MuseTermScriptingRegistry.isScriptedInputAllowed else {
            return museFail(MuseTermScriptErrorCode.inputDisabled, L10n.string("applescript.error.input_disabled"))
        }
        guard let (_, session) = museResolveTargetTab(argumentKey: "targetTab") else {
            return museFail(
                MuseTermScriptErrorCode.tabNotFound,
                L10n.format("tools.error.tab_not_found", "selected")
            )
        }
        let keyName = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let bytes = TerminalToolInput.bytes(forKey: keyName) else {
            return museFail(
                MuseTermScriptErrorCode.unknownKey,
                L10n.format("applescript.error.unknown_key", keyName)
            )
        }
        return museSendInput(bytes: bytes, to: session)
    }
}

// MARK: - play shortcut

@objc(MuseTermPlayShortcutScriptCommand)
final class MuseTermPlayShortcutScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard MuseTermScriptingRegistry.isScriptedInputAllowed else {
            return museFail(MuseTermScriptErrorCode.inputDisabled, L10n.string("applescript.error.input_disabled"))
        }
        guard let workspace = MuseTermScriptingRegistry.workspace else {
            return museFail(MuseTermScriptErrorCode.noWorkspace, L10n.string("tools.error.no_workspace"))
        }
        guard let (_, session) = museResolveTargetTab(argumentKey: "targetTab") else {
            return museFail(
                MuseTermScriptErrorCode.tabNotFound,
                L10n.format("tools.error.tab_not_found", "selected")
            )
        }
        let title = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shortcut = workspace.shortcuts.first { $0.title == title }
            ?? workspace.shortcuts.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
        guard let shortcut else {
            return museFail(
                MuseTermScriptErrorCode.shortcutNotFound,
                L10n.format("applescript.error.shortcut_not_found", title)
            )
        }
        guard MuseTermScriptingPolicy.canPlay(shortcut) else {
            return museFail(
                MuseTermScriptErrorCode.shortcutProtected,
                L10n.string("applescript.error.shortcut_protected")
            )
        }
        session.startProcessIfNeeded()
        workspace.selectedID = session.id
        session.playShortcut(shortcut)
        return nil
    }
}

// MARK: - execute（同步执行，挂起 Apple 事件直至命令块结束）

@objc(MuseTermExecuteScriptCommand)
final class MuseTermExecuteScriptCommand: NSScriptCommand {
    private var pollTimer: Timer?
    private var deadline = Date.distantFuture
    private var baselineBlockIDs: Set<UUID> = []
    private var targetSessionID: UUID?
    private var completedBlockID: UUID?

    override func performDefaultImplementation() -> Any? {
        guard MuseTermScriptingRegistry.isScriptedInputAllowed else {
            return museFail(MuseTermScriptErrorCode.inputDisabled, L10n.string("applescript.error.input_disabled"))
        }
        guard let (_, session) = museResolveTargetTab(argumentKey: "targetTab") else {
            return museFail(
                MuseTermScriptErrorCode.tabNotFound,
                L10n.format("tools.error.tab_not_found", "selected")
            )
        }
        let commandText = (directParameter as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !commandText.isEmpty else {
            return museFail(MuseTermScriptErrorCode.emptyInput, L10n.string("applescript.error.empty_input"))
        }

        // 基线在发送前采集：新出现且已结束的命令块即为本次执行的结果。
        baselineBlockIDs = Set(session.commandBlocks.map(\.id))
        targetSessionID = session.id

        if let failure = museSendInput(bytes: Array(commandText.utf8) + [0x0D], to: session) {
            return failure
        }

        let timeout = MuseTermScriptingPolicy.clampedExecuteTimeout(evaluatedArguments?["timeout"] as? Int)
        deadline = Date().addingTimeInterval(timeout)

        suspendExecution()
        // Timer 挂在主 RunLoop 上，回调必然在主线程，assumeIsolated 只是向编译器说明这一点。
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return nil
    }

    private func poll() {
        guard let workspace = MuseTermScriptingRegistry.workspace,
              let session = workspace.tabs.first(where: { $0.id == targetSessionID }) else {
            finish(errorCode: MuseTermScriptErrorCode.tabNotFound,
                   message: L10n.format("tools.error.tab_not_found", targetSessionID?.uuidString ?? "?"))
            return
        }

        if let block = session.commandBlocks.first(where: {
            !baselineBlockIDs.contains($0.id) && $0.endedAt != nil
        }) {
            // 输出快照有 250ms 节流，命令刚结束时 outputTail 往往还没刷新；
            // 首次发现完成先记下，再等一个轮询周期取最终数据。
            guard completedBlockID == block.id else {
                completedBlockID = block.id
                return
            }
            finish(result: MuseTermScriptRecords.executionResult(
                exitCode: block.exitCode,
                output: block.outputTail,
                durationMilliseconds: block.durationMilliseconds
            ))
            return
        }

        if Date() > deadline {
            finish(errorCode: MuseTermScriptErrorCode.executionTimeout,
                   message: L10n.string("applescript.error.timeout"))
        }
    }

    private func finish(result: [String: Any]) {
        stopPolling()
        resumeExecution(withResult: result)
    }

    private func finish(errorCode: Int, message: String) {
        stopPolling()
        scriptErrorNumber = errorCode
        scriptErrorString = message
        resumeExecution(withResult: nil)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
