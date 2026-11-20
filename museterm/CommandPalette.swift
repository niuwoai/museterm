import AppKit
import SwiftUI

struct CommandPalettePresentationState: Equatable {
    var isPresented = false

    mutating func present() {
        isPresented = true
    }

    mutating func dismiss() {
        isPresented = false
    }
}

enum CommandPaletteKeyboardAction: Equatable {
    case selectPrevious
    case selectNext
    case execute
    case dismiss

    static func resolve(event: NSEvent) -> Self? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return nil }

        switch event.keyCode {
        case 126: return .selectPrevious
        case 125: return .selectNext
        case 36, 76: return .execute
        case 53: return .dismiss
        default: return nil
        }
    }
}

enum CommandPaletteScrollPlan: Equatable {
    /// 保持列表不动，只有高亮在视口内挪动。
    case none
    /// 把该行索引对齐到视口顶部（.top 锚点），实现「撞边才整块滚动」。
    case scrollTopTo(index: Int)
}

/// 纯索引滚动策略：列表尽量保持静止，仅当高亮移出「顶部/底部各保留 margin 行」的可视带时，
/// 才滚动列表，使高亮距离撞上的那条边保留 margin 行上下文。行高固定，故全程用索引算术推导，
/// 不依赖任何逐行坐标测量——避免测量反馈环导致的抖动。
enum CommandPaletteScrollPolicy {
    static func plan(
        topIndex: Int,
        selectedIndex: Int,
        visibleCount: Int,
        itemCount: Int,
        margin: Int
    ) -> CommandPaletteScrollPlan {
        guard itemCount > 0, visibleCount > 0 else { return .none }
        // 列表不长于视口：全部可见，永不滚动。
        guard itemCount > visibleCount else { return .none }

        let maxTop = itemCount - visibleCount
        // 视口窄到容不下上下各 margin 行时收敛 margin，避免可视带塌成负值。
        let effectiveMargin = min(margin, max(0, (visibleCount - 1) / 2))
        let lowerBound = topIndex + effectiveMargin
        let upperBound = topIndex + visibleCount - 1 - effectiveMargin

        if selectedIndex < lowerBound {
            let newTop = max(0, selectedIndex - effectiveMargin)
            return newTop == topIndex ? .none : .scrollTopTo(index: newTop)
        }
        if selectedIndex > upperBound {
            let newTop = min(maxTop, selectedIndex - (visibleCount - 1) + effectiveMargin)
            return newTop == topIndex ? .none : .scrollTopTo(index: newTop)
        }
        return .none
    }
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var sshStore: SSHConnectionStore
    @ObservedObject var preferences: TerminalPreferences

    @State private var query = ""
    @State private var selectedIndex = 0
    // 视口顶部当前所在的行索引；只在真正滚动时更新，作为索引滚动的锚。
    @State private var topIndex = 0
    // 仅键盘上下移动才驱动滚动；hover 改选不滚动，避免鼠标下的行被挪走引发抖动/抖选。
    @State private var lastMoveWasKeyboard = false
    @FocusState private var searchIsFocused: Bool

    private let panelWidth: CGFloat = 620
    private let rowHeight: CGFloat = 54
    private let rowSpacing: CGFloat = 2
    private let listPadding: CGFloat = 12
    private let maxListHeight: CGFloat = 430
    // 撞到顶/底时保留的上下文行数。
    private let visibleMargin = 3

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                searchField
                Divider()
                results
                footer
            }
            .frame(width: panelWidth)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
            .padding(.top, 58)
        }
        .onAppear {
            selectedIndex = 0
            topIndex = 0
            DispatchQueue.main.async { searchIsFocused = true }
        }
        .onChange(of: query) { _ in
            selectedIndex = 0
            topIndex = 0
        }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: close)
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteKeyboardAction)) { note in
            guard let action = note.object as? CommandPaletteKeyboardAction else { return }
            handleKeyboardAction(action)
        }
    }

    private var searchField: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n.string("command_palette.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .focused($searchIsFocused)
                .onSubmit { executeSelectedItem() }
            if let shortcut = TerminalKeyBinding(
                storageValue: preferences.appShortcut(for: .commandPalette)
            )?.displayName {
                Text(shortcut)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    @ViewBuilder
    private var results: some View {
        let items = filteredItems
        if items.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "command")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text(L10n.string("command_palette.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 170)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: rowSpacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selectedIndex)
                                .id(item.id)
                                .onTapGesture { execute(item) }
                                .onHover { hovering in
                                    if hovering {
                                        lastMoveWasKeyboard = false
                                        selectedIndex = index
                                    }
                                }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: min(maxListHeight, CGFloat(items.count) * rowHeight + listPadding))
                .onChange(of: selectedIndex) { value in
                    guard lastMoveWasKeyboard else { return }
                    guard items.indices.contains(value) else { return }
                    let plan = CommandPaletteScrollPolicy.plan(
                        topIndex: topIndex,
                        selectedIndex: value,
                        visibleCount: visibleRowCount(itemCount: items.count),
                        itemCount: items.count,
                        margin: visibleMargin
                    )
                    guard case let .scrollTopTo(newTop) = plan,
                          items.indices.contains(newTop) else { return }
                    topIndex = newTop
                    // 撞边整块滚动：无动画，避免键盘连按时动画相互打断反而抖动。
                    proxy.scrollTo(items[newTop].id, anchor: .top)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label(L10n.string("command_palette.hint.navigate"), systemImage: "arrow.up.arrow.down")
            Label(L10n.string("command_palette.hint.execute"), systemImage: "return")
            Spacer()
            Text(L10n.string("command_palette.hint.context"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.primary.opacity(0.035))
    }

    private func row(_ item: CommandPaletteItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Color.white : preferences.skin.accent)
                .frame(width: 28, height: 28)
                .background(selected ? Color.white.opacity(0.16) : preferences.skin.accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(item.kindTitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(selected ? Color.white.opacity(0.72) : Color.secondary)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .background(selected ? preferences.skin.accent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var filteredItems: [CommandPaletteItem] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return allItems }
        return allItems.compactMap { item in
            guard let score = Self.matchScore(query: cleaned, text: item.searchableText) else { return nil }
            var copy = item
            copy.searchScore = score
            return copy
        }
        .sorted {
            if $0.searchScore != $1.searchScore { return $0.searchScore > $1.searchScore }
            return $0.priority > $1.priority
        }
    }

    private var allItems: [CommandPaletteItem] {
        var items = appItems
        items += workspace.discoverableLearnedCommands.map { record in
            CommandPaletteItem(
                id: "learned:\(record.id)",
                title: record.command,
                subtitle: record.displaySubtitle,
                kindTitle: L10n.string("command_palette.kind.learned"),
                systemImage: record.category.systemImage,
                priority: record.isPinned ? 1_000 : 700 + record.observationCount,
                action: .learned(record.id)
            )
        }
        items += workspace.shortcuts.map { shortcut in
            CommandPaletteItem(
                id: "shortcut:\(shortcut.id.uuidString)",
                title: shortcut.title,
                subtitle: shortcut.executionContext?.displaySummary ?? L10n.string("command_palette.current_tab"),
                kindTitle: L10n.string("command_palette.kind.shortcut"),
                systemImage: "play.rectangle",
                priority: 500,
                action: .shortcut(shortcut.id)
            )
        }
        items += workspace.quickPathRecords.prefix(20).map { record in
            CommandPaletteItem(
                id: "path:\(record.path)",
                title: URL(fileURLWithPath: record.path).lastPathComponent,
                subtitle: record.path,
                kindTitle: L10n.string("command_palette.kind.path"),
                systemImage: "folder",
                priority: 350 + record.visitCount,
                action: .quickPath(record.path)
            )
        }
        items += sshStore.profiles.map { profile in
            CommandPaletteItem(
                id: "ssh:\(profile.id.uuidString)",
                title: profile.displayName,
                subtitle: profile.normalized.target,
                kindTitle: L10n.string("command_palette.kind.ssh"),
                systemImage: "network",
                priority: profile.isFavorite ? 480 : 300,
                action: .ssh(profile.id)
            )
        }
        items += workspace.tabs.map { tab in
            CommandPaletteItem(
                id: "tab:\(tab.id.uuidString)",
                title: tab.tabTitle,
                subtitle: tab.executionContext.displaySummary,
                kindTitle: L10n.string("command_palette.kind.tab"),
                systemImage: "rectangle.stack",
                priority: 250,
                action: .tab(tab.id)
            )
        }
        return items.sorted { $0.priority > $1.priority }
    }

    private var appItems: [CommandPaletteItem] {
        [
            CommandPaletteItem(
                id: "app:new-tab",
                title: L10n.string("action.new_tab"),
                subtitle: L10n.string("command_palette.new_tab.subtitle"),
                kindTitle: L10n.string("command_palette.kind.action"),
                systemImage: "plus.rectangle.on.rectangle",
                priority: 900,
                action: .newTab
            ),
            CommandPaletteItem(
                id: "app:command-inspector",
                title: L10n.string("action.search_commands"),
                subtitle: L10n.string("command_palette.command_inspector.subtitle"),
                kindTitle: L10n.string("command_palette.kind.action"),
                systemImage: "magnifyingglass",
                priority: 600,
                action: .commandInspector
            ),
            CommandPaletteItem(
                id: "app:tasks",
                title: L10n.string("action.show_tasks_ports"),
                subtitle: L10n.string("command_palette.tasks.subtitle"),
                kindTitle: L10n.string("command_palette.kind.action"),
                systemImage: "server.rack",
                priority: 590,
                action: .tasks
            ),
            CommandPaletteItem(
                id: "app:settings",
                title: L10n.string("action.settings"),
                subtitle: L10n.string("command_palette.settings.subtitle"),
                kindTitle: L10n.string("command_palette.kind.action"),
                systemImage: "gearshape",
                priority: 400,
                action: .settings
            )
        ]
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filteredItems.isEmpty else { return }
        lastMoveWasKeyboard = true
        switch direction {
        case .down: selectedIndex = min(selectedIndex + 1, filteredItems.count - 1)
        case .up: selectedIndex = max(selectedIndex - 1, 0)
        default: break
        }
    }

    /// 视口能完整容纳多少行（行高固定，纯几何推导，不测量）。列表不超过视口高度时返回全部行数，
    /// 使短列表判定为「全可见、不滚动」。
    private func visibleRowCount(itemCount: Int) -> Int {
        let contentHeight = CGFloat(itemCount) * rowHeight
            + CGFloat(max(0, itemCount - 1)) * rowSpacing
            + listPadding
        if contentHeight <= maxListHeight { return max(1, itemCount) }
        return max(1, Int((maxListHeight - listPadding + rowSpacing) / (rowHeight + rowSpacing)))
    }

    private func handleKeyboardAction(_ action: CommandPaletteKeyboardAction) {
        switch action {
        case .selectPrevious:
            moveSelection(.up)
        case .selectNext:
            moveSelection(.down)
        case .execute:
            executeSelectedItem()
        case .dismiss:
            close()
        }
    }

    private func executeSelectedItem() {
        let items = filteredItems
        guard items.indices.contains(selectedIndex) else { return }
        execute(items[selectedIndex])
    }

    private func execute(_ item: CommandPaletteItem) {
        do {
            switch item.action {
            case .newTab:
                workspace.newTab()
            case .commandInspector:
                NotificationCenter.default.post(name: .toggleCommandInspector, object: nil)
            case .tasks:
                NotificationCenter.default.post(name: .toggleTaskPortPanel, object: nil)
            case .settings:
                SettingsWindowOpener.open(preferences: preferences)
            case .tab(let id):
                if let tab = workspace.tabs.first(where: { $0.id == id }) { workspace.select(tab) }
            case .quickPath(let path):
                workspace.openQuickPath(path)
            case .ssh(let id):
                if let profile = sshStore.profiles.first(where: { $0.id == id }) {
                    workspace.openSSH(profile: sshStore.recordConnection(profile))
                }
            case .shortcut(let id):
                if let shortcut = workspace.shortcuts.first(where: { $0.id == id }) {
                    close()
                    workspace.playUserShortcut(shortcut, sshProfiles: sshStore.profiles) { result in
                        if case .failure(let error) = result {
                            showError(error)
                        }
                    }
                    return
                }
            case .learned(let id):
                guard let record = workspace.learnedCommands.first(where: { $0.id == id }) else { return }
                guard confirmIfNeeded(record) else { return }
                try workspace.executeLearnedCommand(record, sshProfiles: sshStore.profiles)
            }
            close()
        } catch {
            showError(error)
        }
    }

    private func confirmIfNeeded(_ record: LearnedCommandRecord) -> Bool {
        let risk = TerminalCommandRiskAnalyzer.profile(for: record.command)
        guard risk.level != .readOnly else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.string("learned_command.confirm.title")
        alert.informativeText = L10n.format(
            "learned_command.confirm.message",
            record.command,
            record.context.displaySummary
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("learned_command.confirm.action"))
        alert.addButton(withTitle: L10n.string("action.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string("learned_command.error.title")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("action.ok"))
        alert.runModal()
    }

    private func close() {
        isPresented = false
    }

    private static func matchScore(query: String, text: String) -> Int? {
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let text = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if text.hasPrefix(query) { return 1_000 - text.count }
        if let range = text.range(of: query) { return 800 - text.distance(from: text.startIndex, to: range.lowerBound) }

        var searchIndex = text.startIndex
        var score = 0
        for character in query {
            guard let found = text[searchIndex...].firstIndex(of: character) else { return nil }
            score += found == searchIndex ? 8 : 2
            searchIndex = text.index(after: found)
        }
        return score
    }
}

extension Notification.Name {
    static let commandPaletteKeyboardAction = Notification.Name("MuseTermCommandPaletteKeyboardAction")
}

private struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let kindTitle: String
    let systemImage: String
    let priority: Int
    let action: Action
    var searchScore = 0

    var searchableText: String {
        [title, subtitle, kindTitle].joined(separator: " ")
    }

    enum Action {
        case newTab
        case commandInspector
        case tasks
        case settings
        case tab(TerminalSession.ID)
        case quickPath(String)
        case ssh(UUID)
        case shortcut(UUID)
        case learned(String)
    }
}

struct LearnedCommandSidebarSection: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var sshStore: SSHConnectionStore
    let skin: TerminalVisualSkin
    @State private var errorMessage = ""

    private var commands: [LearnedCommandRecord] {
        Array(workspace.discoverableLearnedCommands.prefix(6))
    }

    var body: some View {
        SidebarSection(
            title: L10n.string("learned_command.section"),
            systemImage: "bolt.fill",
            skin: skin,
            initiallyExpanded: true,
            kind: .learnedCommands,
            preferences: workspace.preferences
        ) {
            if commands.isEmpty {
                Text(L10n.string("learned_command.empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(commands) { record in
                    Button {
                        run(record)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: record.isPinned ? "pin.fill" : record.category.systemImage)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(skin.accent)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.command)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(record.context.displaySummary)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 2)
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(skin.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contextMenu {
                        Button {
                            workspace.setLearnedCommandPinned(!record.isPinned, id: record.id)
                        } label: {
                            Label(
                                record.isPinned
                                    ? L10n.string("learned_command.unpin")
                                    : L10n.string("learned_command.pin"),
                                systemImage: record.isPinned ? "pin.slash" : "pin"
                            )
                        }
                        Button {
                            workspace.dismissLearnedCommand(id: record.id)
                        } label: {
                            Label(L10n.string("learned_command.dismiss"), systemImage: "eye.slash")
                        }
                        Divider()
                        Button(role: .destructive) {
                            workspace.removeLearnedCommand(id: record.id)
                        } label: {
                            Label(L10n.string("learned_command.delete"), systemImage: "trash")
                        }
                        Button(role: .destructive) {
                            workspace.blacklistLearnedCommand(id: record.id)
                        } label: {
                            Label(L10n.string("learned_command.blacklist"), systemImage: "nosign")
                        }
                    }
                }
            }
        }
        .alert(
            L10n.string("learned_command.error.title"),
            isPresented: Binding(
                get: { !errorMessage.isEmpty },
                set: { if !$0 { errorMessage = "" } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { errorMessage = "" }
        } message: {
            Text(errorMessage)
        }
    }

    private func run(_ record: LearnedCommandRecord) {
        guard confirmIfNeeded(record) else { return }
        do {
            try workspace.executeLearnedCommand(record, sshProfiles: sshStore.profiles)
        } catch {
            NSSound.beep()
            errorMessage = error.localizedDescription
        }
    }

    private func confirmIfNeeded(_ record: LearnedCommandRecord) -> Bool {
        guard TerminalCommandRiskAnalyzer.profile(for: record.command).level != .readOnly else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.string("learned_command.confirm.title")
        alert.informativeText = L10n.format(
            "learned_command.confirm.message",
            record.command,
            record.context.displaySummary
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("learned_command.confirm.action"))
        alert.addButton(withTitle: L10n.string("action.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
