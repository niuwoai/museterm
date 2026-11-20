import AppKit
import Combine
import SwiftUI

enum AICommandActivation: String, CaseIterable, Identifiable {
    case doubleControl
    case doubleShift
    case disabled

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .doubleControl: return "settings.ai_command.activation.double_control"
        case .doubleShift: return "settings.ai_command.activation.double_shift"
        case .disabled: return "settings.ai_command.activation.disabled"
        }
    }

    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .doubleControl: return .control
        case .doubleShift: return .shift
        case .disabled: return nil
        }
    }
}

struct DoubleModifierTapDetector {
    static let maximumInterval: TimeInterval = 0.42

    private var activeModifier: NSEvent.ModifierFlags?
    private var lastReleaseTimestamp: TimeInterval?
    private var triggeredCurrentPress = false

    mutating func handleFlagsChanged(
        flags: NSEvent.ModifierFlags,
        timestamp: TimeInterval,
        activation: AICommandActivation
    ) -> Bool {
        guard let desiredModifier = activation.modifierFlag else {
            reset()
            return false
        }

        let supportedFlags = flags.intersection([.control, .shift, .option, .command])
        let isDesiredModifierDown = supportedFlags == desiredModifier

        if isDesiredModifierDown, activeModifier == nil {
            activeModifier = desiredModifier
            if let lastReleaseTimestamp,
               timestamp - lastReleaseTimestamp <= Self.maximumInterval {
                triggeredCurrentPress = true
                self.lastReleaseTimestamp = nil
                return true
            }
            return false
        }

        if activeModifier == desiredModifier, !flags.contains(desiredModifier) {
            activeModifier = nil
            if triggeredCurrentPress {
                triggeredCurrentPress = false
                lastReleaseTimestamp = nil
            } else {
                lastReleaseTimestamp = timestamp
            }
            return false
        }

        if !supportedFlags.isEmpty, supportedFlags != desiredModifier {
            reset()
        }
        return false
    }

    mutating func registerKeyDown() {
        reset()
    }

    mutating func reset() {
        activeModifier = nil
        lastReleaseTimestamp = nil
        triggeredCurrentPress = false
    }
}

enum AICommandAssistantPhase: Equatable {
    case hidden
    case composing
    case generating
    case review
    /// The command was accepted by the runtime input queue and its write to the
    /// PTY has not been acknowledged yet.
    case filling
    case failed
}

enum AICommandAssistantNotice: Equatable {
    case ended
    case filled(isProduction: Bool)
}

struct AICommandContext: Equatable {
    let tabID: TerminalSession.ID
    let targetKind: TerminalExecutionTargetKind
    let targetName: String
    let workingDirectory: String?
    let user: String?
    let host: String?
    let shell: String?
    let environment: TerminalEnvironmentKind

    init(tab: TerminalSession) {
        let executionContext = tab.executionContext
        tabID = tab.id
        targetKind = executionContext.targetKind
        targetName = executionContext.displayTarget
        workingDirectory = executionContext.normalizedDirectory
        user = executionContext.normalizedUser
        host = executionContext.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        shell = executionContext.normalizedShell
        environment = tab.environment
    }

    var displaySummary: String {
        var parts = [
            targetKind == .ssh
                ? L10n.string("execution_context.ssh")
                : L10n.string("execution_context.local")
        ]
        if let user, let host, !user.isEmpty, !host.isEmpty {
            parts.append("\(user)@\(host)")
        } else {
            parts.append(targetName)
        }
        if let workingDirectory { parts.append(workingDirectory) }
        if let shell { parts.append(shell) }
        if environment != .local { parts.append(environment.shortName) }
        return parts.joined(separator: " · ")
    }

    var promptDescription: String {
        [
            "target_kind=\(targetKind.rawValue)",
            "target_name=\(targetName)",
            "user=\(user ?? "unknown")",
            "host=\(host ?? "unknown")",
            "working_directory=\(workingDirectory ?? "unknown")",
            "shell=\(shell ?? "unknown")",
            "environment=\(environment.rawValue)"
        ].joined(separator: "\n")
    }
}

struct AICommandSuggestion: Identifiable, Equatable {
    let id: UUID
    let command: String
    let explanation: String
    let riskProfile: TerminalCommandRiskProfile

    init(
        id: UUID = UUID(),
        command: String,
        explanation: String,
        riskProfile: TerminalCommandRiskProfile? = nil
    ) {
        self.id = id
        self.command = command
        self.explanation = explanation
        self.riskProfile = riskProfile ?? TerminalCommandRiskAnalyzer.profile(for: command)
    }
}

enum AICommandResponseParser {
    private struct Payload: Decodable {
        struct Candidate: Decodable {
            let command: String
            let explanation: String?
        }

        let candidates: [Candidate]
    }

    static func parse(_ response: String) throws -> [AICommandSuggestion] {
        let json = extractedJSONObject(from: response)
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw AICommandAssistantError.invalidSuggestions
        }

        var seenCommands: Set<String> = []
        let suggestions = payload.candidates.compactMap { candidate -> AICommandSuggestion? in
            let command = candidate.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty,
                  !command.contains("\n"),
                  !command.contains("\r"),
                  seenCommands.insert(command).inserted else {
                return nil
            }
            let explanation = candidate.explanation?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AICommandSuggestion(
                command: command,
                explanation: explanation.isEmpty
                    ? L10n.string("ai_command.explanation_fallback")
                    : String(explanation.prefix(600))
            )
        }

        guard !suggestions.isEmpty else {
            throw AICommandAssistantError.invalidSuggestions
        }
        return Array(suggestions.prefix(2))
    }

    private static func extractedJSONObject(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return trimmed
        }
        return String(trimmed[start...end])
    }
}

enum AICommandAssistantError: LocalizedError {
    case missingContext
    case invalidSuggestions
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .missingContext:
            return L10n.string("ai_command.error.missing_context")
        case .invalidSuggestions:
            return L10n.string("ai_command.error.invalid_suggestions")
        case .targetChanged:
            return L10n.string("ai_command.error.target_changed")
        }
    }
}

@MainActor
final class AICommandAssistantModel: ObservableObject {
    @Published private(set) var phase: AICommandAssistantPhase = .hidden
    @Published var query = ""
    @Published private(set) var context: AICommandContext?
    @Published private(set) var candidates: [AICommandSuggestion] = []
    @Published var selectedCandidateID: AICommandSuggestion.ID?
    @Published private(set) var errorMessage = ""
    @Published private(set) var notice: AICommandAssistantNotice?
    /// 这一轮用哪个 Provider 和模型。切换 Provider 会换掉模型列表。
    @Published var modelChoice = AICommandModelChoice(provider: .magpie, model: "")
    @Published private(set) var discoveredModels: [String] = []
    @Published private(set) var isLoadingModels = false

    private weak var targetTab: TerminalSession?
    private var modelDiscoveryTask: Task<Void, Never>?
    private var modelByProvider: [AIProviderKind: String] = [:]
    private var generationTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    var isActive: Bool { phase != .hidden }

    var selectedCandidate: AICommandSuggestion? {
        candidates.first { $0.id == selectedCandidateID } ?? candidates.first
    }

    func present(for tab: TerminalSession, preferences: TerminalPreferences = TerminalPreferences()) {
        generationTask?.cancel()
        targetTab = tab
        context = AICommandContext(tab: tab)
        query = ""
        candidates = []
        selectedCandidateID = nil
        errorMessage = ""
        clearNotice()
        modelByProvider = [:]
        modelChoice = AICommandModelChoice.preferred(preferences: preferences)
        phase = .composing
        loadModels(preferences: preferences)
    }

    /// 换 Provider：保留本轮各服务已选模型，设置中的服务仍使用其保存的模型。
    func selectProvider(_ provider: AIProviderKind, preferences: TerminalPreferences) {
        guard provider != modelChoice.provider else { return }
        modelByProvider[modelChoice.provider] = modelChoice.model
        var choice = modelChoice.switching(to: provider)
        if let previousModel = modelByProvider[provider] {
            choice.model = previousModel
        } else if provider == preferences.aiProvider {
            choice = AICommandModelChoice.preferred(preferences: preferences)
        }
        modelChoice = choice
        loadModels(preferences: preferences)
    }

    func selectModel(_ model: String) {
        modelChoice.model = model
    }

    private func loadModels(preferences: TerminalPreferences) {
        modelDiscoveryTask?.cancel()
        let provider = modelChoice.provider
        discoveredModels = []
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-ai-command-composer") {
            isLoadingModels = false
            return
        }
        #endif
        let baseURL = provider.defaultBaseURL
        guard !baseURL.isEmpty else {
            isLoadingModels = false
            return
        }
        let savedKey = preferences.loadAIAPIKey(for: provider)
        let apiKey = savedKey.isEmpty && provider == .magpie
            ? AIProviderKind.magpieLocalGatewayAPIKey
            : savedKey
        guard provider.isLocalProvider || !apiKey.isEmpty else {
            isLoadingModels = false
            return
        }
        isLoadingModels = true
        modelDiscoveryTask = Task { [weak self] in
            let models = (try? await AIModelDiscovery(provider: provider, baseURL: baseURL, apiKey: apiKey).fetch()) ?? []
            guard !Task.isCancelled, let self, self.modelChoice.provider == provider else { return }
            self.discoveredModels = models
            self.isLoadingModels = false
            // 默认模型不在发现到的列表里时，改选列表里的第一个，免得指向一个不存在的模型。
            if !models.isEmpty, !models.contains(self.modelChoice.model) {
                self.modelChoice.model = models[0]
            }
        }
    }

    func generate(preferences: TerminalPreferences) {
        let request = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, let context else { return }

        generationTask?.cancel()
        candidates = []
        selectedCandidateID = nil
        errorMessage = ""
        phase = .generating

        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try await AIExplainClient.Configuration.resolving(
                    preferences: preferences,
                    choice: modelChoice
                )
                let response = try await AIExplainClient(configuration: configuration).stream(
                    systemPrompt: L10n.string("ai_command.system_prompt"),
                    userPrompt: Self.userPrompt(request: request, context: context)
                ) { _ in }
                try Task.checkCancellation()
                let parsed = try AICommandResponseParser.parse(response)
                guard self.phase == .generating, self.context == context else { return }
                self.candidates = parsed
                self.selectedCandidateID = parsed.first?.id
                self.phase = .review
            } catch is CancellationError {
                return
            } catch {
                guard self.phase == .generating else { return }
                self.errorMessage = error.localizedDescription
                self.phase = .failed
            }
        }
    }

    func select(_ candidate: AICommandSuggestion) {
        selectedCandidateID = candidate.id
    }

    #if DEBUG
    /// Seeds one reviewed suggestion so tests can drive the fill path without a
    /// model round trip.
    func stageReviewedCandidateForTesting(_ candidate: AICommandSuggestion) {
        guard phase == .composing else { return }
        candidates = [candidate]
        selectedCandidateID = candidate.id
        phase = .review
    }
    #endif

    func askAgain() {
        generationTask?.cancel()
        candidates = []
        selectedCandidateID = nil
        errorMessage = ""
        phase = .composing
    }

    func copySelectedCommand() {
        guard let command = selectedCandidate?.command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func fillSelectedCommand(in workspace: TerminalWorkspace) {
        guard let command = selectedCandidate?.command,
              let context,
              workspace.selectedTab?.id == context.tabID,
              targetTab?.id == context.tabID else {
            errorMessage = AICommandAssistantError.targetChanged.localizedDescription
            phase = .failed
            return
        }

        do {
            let production = context.environment == .production
            if targetTab?.controller.runtimeHandle != nil {
                // The ACK arrives on the main queue, so it can run before this
                // method returns. Install the observer before the enqueue, and
                // never wait for it here: waiting on the main thread deadlocks.
                phase = .filling
                targetTab?.controller.observePendingRuntimeToolInput { [weak self] result in
                    guard let self, self.phase == .filling else { return }
                    switch result {
                    case .success: self.finish(with: .filled(isProduction: production))
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                        self.phase = .failed
                    }
                }
            }
            _ = try workspace.sendToolInput(to: "selected", bytes: Array(command.utf8))
            if phase != .filling {
                finish(with: .filled(isProduction: production))
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    func dismiss(showNotice: Bool = true) {
        finish(with: showNotice ? .ended : nil)
    }

    func cancelIfTargetChanged(selectedID: TerminalSession.ID?) {
        guard isActive, selectedID != context?.tabID else { return }
        finish(with: nil)
    }

    private func finish(with newNotice: AICommandAssistantNotice?) {
        generationTask?.cancel()
        generationTask = nil
        modelDiscoveryTask?.cancel()
        modelDiscoveryTask = nil
        isLoadingModels = false
        targetTab = nil
        context = nil
        candidates = []
        selectedCandidateID = nil
        errorMessage = ""
        query = ""
        phase = .hidden
        showNotice(newNotice)
    }

    private func showNotice(_ newNotice: AICommandAssistantNotice?) {
        noticeTask?.cancel()
        notice = newNotice
        guard newNotice != nil else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    private static func userPrompt(request: String, context: AICommandContext) -> String {
        L10n.format(
            "ai_command.user_prompt",
            context.promptDescription,
            request
        )
    }
}

struct AICommandAssistantLayer: View {
    @ObservedObject var model: AICommandAssistantModel
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if model.phase == .composing {
                // 输入条放在底部，菜单向上展开。
                VStack {
                    Spacer()
                    AICommandComposerBar(model: model, preferences: preferences)
                        .frame(maxWidth: 620)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if [.generating, .review, .filling, .failed].contains(model.phase) {
                AICommandFloatingPanel(
                    model: model,
                    workspace: workspace,
                    preferences: preferences
                )
                .frame(width: 470)
                .padding(.top, 24)
                .padding(.trailing, 22)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if let notice = model.notice {
                VStack {
                    Spacer()
                    AICommandNoticeView(notice: notice, skin: preferences.skin)
                        .padding(.bottom, 22)
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: 0.16), value: model.phase)
        .animation(.easeOut(duration: 0.16), value: model.notice)
        .zIndex(50)
    }
}

enum AICommandComposerLayout {
    static let minimumInputLines = 2
    static let maximumInputLines = 5
    static let minimumInputHeight: CGFloat = 44
    static let minimumBarHeight: CGFloat = 46
    static let contextRowSpacing: CGFloat = 4
    static let bottomRowSpacing: CGFloat = 10
}

/// 输入条里的 Provider 与模型选择。模型列表跟所选 Provider 走，切换 Provider 就换成它自己的列表。
struct AICommandModelChoice: Equatable {
    var provider: AIProviderKind
    var model: String

    /// 跟随设置里的选择；设置没选模型时用该 Provider 的默认模型。
    static func preferred(preferences: TerminalPreferences) -> AICommandModelChoice {
        let saved = preferences.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return AICommandModelChoice(
            provider: preferences.aiProvider,
            model: saved.isEmpty ? preferences.aiProvider.defaultModel : saved
        )
    }

    /// 切换 Provider：新 Provider 的默认模型顶上，列表之外的旧模型不带过去。
    func switching(to provider: AIProviderKind) -> AICommandModelChoice {
        AICommandModelChoice(provider: provider, model: provider.defaultModel)
    }

    /// 当前 Provider 下能选的模型：发现到的列表优先，再补上默认模型和当前选中的。
    func models(discovered: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for candidate in discovered + [provider.defaultModel, model] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

nonisolated enum AICommandComposerKeyAction: Equatable {
    case submit
    case insertNewline
    case passthrough
}

nonisolated enum AICommandComposerKeyResolver {
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    static func action(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> AICommandComposerKeyAction {
        guard returnKeyCodes.contains(keyCode) else { return .passthrough }

        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if modifiers == .shift { return .insertNewline }
        if modifiers.isEmpty { return .submit }
        return .passthrough
    }
}

private struct AICommandComposerKeyMonitor: NSViewRepresentable {
    let isFocused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isFocused: isFocused, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installMonitor()
        DispatchQueue.main.async { context.coordinator.window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isFocused = isFocused
        context.coordinator.onSubmit = onSubmit
        DispatchQueue.main.async { context.coordinator.window = nsView.window }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        var isFocused: Bool
        var onSubmit: () -> Void
        private var monitor: Any?

        init(isFocused: Bool, onSubmit: @escaping () -> Void) {
            self.isFocused = isFocused
            self.onSubmit = onSubmit
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      isFocused,
                      event.window === window else {
                    return event
                }

                switch AICommandComposerKeyResolver.action(
                    keyCode: event.keyCode,
                    modifierFlags: event.modifierFlags
                ) {
                case .submit:
                    onSubmit()
                    return nil
                case .insertNewline:
                    guard let editor = event.window?.firstResponder as? NSTextView else {
                        return event
                    }
                    editor.insertText("\n", replacementRange: editor.selectedRange())
                    return nil
                case .passthrough:
                    return event
                }
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private struct AICommandComposerBar: View {
    @ObservedObject var model: AICommandAssistantModel
    @ObservedObject var preferences: TerminalPreferences
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(preferences.skin.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: AICommandComposerLayout.contextRowSpacing) {
                TextField(
                    L10n.string("ai_command.input.placeholder"),
                    text: $model.query,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    // 输入区至少两行，避免和下面的选择框挤成一条。
                    .lineLimit(
                        AICommandComposerLayout.minimumInputLines...AICommandComposerLayout.maximumInputLines
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: AICommandComposerLayout.minimumInputHeight,
                        alignment: .topLeading
                    )
                    .focused($focused)
                    .accessibilityIdentifier("aiCommandQuery")
                    .background {
                        AICommandComposerKeyMonitor(isFocused: focused) {
                            model.generate(preferences: preferences)
                        }
                    }
                    .help(L10n.string("ai_command.input.keyboard_help"))
                modelPickers
                HStack(spacing: AICommandComposerLayout.bottomRowSpacing) {
                    if let context = model.context {
                        Text(context.displaySummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(context.displaySummary)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Button {
                        model.generate(preferences: preferences)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(L10n.string("ai_command.generate"))
                    Button {
                        model.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("ai_command.close_help"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: AICommandComposerLayout.minimumBarHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(preferences.skin.accent.opacity(0.32), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 6)
        .onAppear { focused = true }
        .onExitCommand { model.dismiss() }
    }

    /// Provider 和模型两个选择框，模型列表跟着所选 Provider 变化。
    private var modelPickers: some View {
        HStack(spacing: 10) {
            labeledMenu(
                title: L10n.string("ai_command.provider"),
                value: model.modelChoice.provider.name,
                maxWidth: 170,
                enabled: true,
                menu: providerMenu
            )
            labeledMenu(
                title: L10n.string("ai_command.model"),
                value: model.modelChoice.model,
                maxWidth: 250,
                enabled: !model.modelChoice.models(discovered: model.discoveredModels).isEmpty,
                menu: modelMenu
            )
            Spacer(minLength: 0)
        }
    }

    private func providerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for provider in AIProviderKind.allCases {
            let item = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
            item.state = provider == model.modelChoice.provider ? .on : .off
            installAICommandMenuPick(item) { [model, preferences] in
                model.selectProvider(provider, preferences: preferences)
            }
            menu.addItem(item)
        }
        return menu
    }

    private func modelMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for name in model.modelChoice.models(discovered: model.discoveredModels) {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.state = name == model.modelChoice.model ? .on : .off
            installAICommandMenuPick(item) { [model] in
                model.selectModel(name)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// 标题在左、胶囊限宽。行本身不锁死宽度，长名字能占到上限再截断。
    private func labeledMenu(title: String, value: String, maxWidth: CGFloat, enabled: Bool, menu: @escaping () -> NSMenu) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
            capsule(value: value, width: maxWidth)
                .overlay {
                    AICommandMenuButton(enabled: enabled, title: title, value: value, menu: menu)
                }
        }
        .fixedSize(horizontal: true, vertical: false)
        .opacity(enabled ? 1 : 0.55)
        .help(title)
    }

    private func capsule(value: String, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(value.isEmpty ? L10n.string("ai_command.model.none") : value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(width: width, alignment: .leading)
        .background(preferences.skin.controlFill, in: Capsule())
        .overlay(Capsule().strokeBorder(preferences.skin.hairline, lineWidth: 1))
    }
}

/// 透明的点击层，盖在 SwiftUI 画的胶囊上。菜单挂在窗口层弹出，
/// 不走 SwiftUI 的 Picker，否则菜单会被输入条所在的图层裁掉。
private struct AICommandMenuButton: NSViewRepresentable {
    let enabled: Bool
    let title: String
    let value: String
    let menu: () -> NSMenu

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: AICommandMenuButtonView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func makeNSView(context: Context) -> AICommandMenuButtonView {
        let view = AICommandMenuButtonView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.popUpButton)
        return view
    }

    func updateNSView(_ view: AICommandMenuButtonView, context: Context) {
        view.isEnabled = enabled
        view.menuProvider = menu
        view.setAccessibilityLabel(title)
        view.setAccessibilityValue(value)
    }
}

/// NSMenuItem 的 target 是弱引用；用 representedObject 保留动作对象，
/// 再显式设置 target，让系统菜单点击能找到接收者。
final class AICommandMenuPick: NSObject {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    @objc func invoke(_ sender: Any?) {
        body()
    }
}

func installAICommandMenuPick(_ item: NSMenuItem, _ body: @escaping () -> Void) {
    let pick = AICommandMenuPick(body)
    item.representedObject = pick
    item.target = pick
    item.action = #selector(AICommandMenuPick.invoke(_:))
    item.isEnabled = true
}

private final class AICommandMenuButtonView: NSView {
    var isEnabled = true
    var menuProvider: (() -> NSMenu)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let menu = menuProvider?(), menu.numberOfItems > 0 else { return }
        // 锚定最后一项并放在输入条上沿，菜单向上展开，避免贴着窗口底边时被屏幕裁掉。
        menu.popUp(
            positioning: menu.item(at: menu.numberOfItems - 1),
            at: NSPoint(x: 0, y: bounds.height + 4),
            in: self
        )
    }
}

private struct AICommandFloatingPanel: View {
    @ObservedObject var model: AICommandAssistantModel
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var preferences: TerminalPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                contextSummary
                switch model.phase {
                case .generating:
                    generatingContent
                case .review:
                    reviewContent
                case .filling:
                    fillingContent
                case .failed:
                    failedContent
                case .hidden, .composing:
                    EmptyView()
                }
            }
            .padding(14)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(L10n.string("ai_command.close_ends_session"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(preferences.skin.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 10)
        .onExitCommand { model.dismiss() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(preferences.skin.accent)
            Text(L10n.string("ai_command.title"))
                .font(.headline)
            Spacer()
            Button {
                model.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(L10n.string("ai_command.close_help"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var contextSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let context = model.context {
                Text(context.displaySummary)
                    .font(.caption.monospaced())
                    .lineLimit(2)
            }
            Label(L10n.string("ai_command.never_auto_executes"), systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(preferences.skin.accent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(preferences.skin.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var generatingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("ai_command.generating"))
                    .font(.subheadline.weight(.semibold))
            }
            generationStep("ai_command.generating.context")
            generationStep("ai_command.generating.risk")
            generationStep("ai_command.generating.candidates")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func generationStep(_ key: String) -> some View {
        Label(L10n.string(key), systemImage: "circle.dotted")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var fillingContent: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.string("ai_command.filling"))
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("ai_command.suggestions"))
                .font(.caption.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(model.candidates) { candidate in
                    Button {
                        model.select(candidate)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: model.selectedCandidate?.id == candidate.id
                                ? "largecircle.fill.circle"
                                : "circle")
                                .foregroundStyle(preferences.skin.accent)
                            Text(candidate.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            AICommandRiskBadge(profile: candidate.riskProfile)
                        }
                        .padding(10)
                        .background(
                            model.selectedCandidate?.id == candidate.id
                                ? preferences.skin.accent.opacity(0.10)
                                : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                    if candidate.id != model.candidates.last?.id { Divider() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(preferences.skin.hairline, lineWidth: 1)
            )

            if let candidate = model.selectedCandidate {
                Text(L10n.string("ai_command.explanation"))
                    .font(.caption.weight(.semibold))
                Text(candidate.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(L10n.string("ai_command.ask_again")) {
                    model.askAgain()
                }
                Button(L10n.string("ai_command.copy")) {
                    model.copySelectedCommand()
                }
                Spacer()
                Button(L10n.string("ai_command.fill_terminal")) {
                    model.fillSelectedCommand(in: workspace)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.string("ai_command.failed"), systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(model.errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .textSelection(.enabled)
            HStack {
                Button(L10n.string("ai_command.ask_again")) {
                    model.askAgain()
                }
                Spacer()
                Button(L10n.string("ai_command.retry")) {
                    model.generate(preferences: preferences)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }
}

private struct AICommandRiskBadge: View {
    let profile: TerminalCommandRiskProfile

    var body: some View {
        Text(L10n.string("ai_command.risk.\(profile.level.rawValue)"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .fixedSize()
    }

    private var color: Color {
        switch profile.level {
        case .readOnly: return .green
        case .mutating: return .orange
        case .dangerous: return .red
        case .unknown: return .yellow
        }
    }
}

private struct AICommandNoticeView: View {
    let notice: AICommandAssistantNotice
    let skin: TerminalVisualSkin

    var body: some View {
        Label(message, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(skin.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
    }

    private var message: String {
        switch notice {
        case .ended:
            return L10n.string("ai_command.notice.ended")
        case .filled(let isProduction):
            return L10n.string(isProduction
                ? "ai_command.notice.filled_production"
                : "ai_command.notice.filled")
        }
    }

    private var icon: String {
        switch notice {
        case .ended: return "checkmark.circle.fill"
        case .filled(let isProduction):
            return isProduction ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        }
    }
}
