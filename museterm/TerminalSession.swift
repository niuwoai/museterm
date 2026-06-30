import Combine
import Foundation

final class TerminalSession: ObservableObject, Identifiable {
    enum State {
        case running
        case exited(Int32?)
    }

    let id = UUID()
    let sequence: Int
    let createdAt = Date()

    @Published var title: String
    @Published var currentDirectory: String?
    @Published var state: State = .running

    lazy var controller = TerminalHostController(session: self)

    init(sequence: Int) {
        self.sequence = sequence
        title = L10n.format("tab.default_title", sequence)
    }

    func prepareController() {
        _ = controller
    }

    func startProcessIfNeeded() {
        controller.ensureProcessStarted()
    }

    var displayTitle: String {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.format("tab.default_title", sequence)
        }
        return title
    }

    var tabTitle: String {
        if let remoteIdentity {
            return remoteIdentity
        }

        let directory = directoryLabel
        if directory != "~" {
            return directory
        }

        return L10n.format("tab.default_title", sequence)
    }

    var tabSubtitle: String? {
        if remoteIdentity != nil {
            return directoryLabel
        }

        let fallback = L10n.format("tab.default_title", sequence)
        if tabTitle != fallback {
            return nil
        }

        return directoryLabel
    }

    var directoryLabel: String {
        guard let currentDirectory, !currentDirectory.isEmpty else {
            return "~"
        }

        if let url = URL(string: currentDirectory), url.isFileURL {
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }

        let url = URL(fileURLWithPath: currentDirectory)
        return url.lastPathComponent.isEmpty ? currentDirectory : url.lastPathComponent
    }

    private var remoteIdentity: String? {
        guard let identity = Self.identity(in: title) else { return nil }
        return Self.isLocalIdentity(identity) ? nil : identity
    }

    private static func identity(in title: String) -> String? {
        let pattern = #"(?:^|[\s:/])([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = regex.firstMatch(in: title, range: range), match.numberOfRanges >= 3 else {
            return nil
        }

        guard
            let userRange = Range(match.range(at: 1), in: title),
            let hostRange = Range(match.range(at: 2), in: title)
        else {
            return nil
        }

        return "\(title[userRange])@\(title[hostRange])"
    }

    private static func isLocalIdentity(_ identity: String) -> Bool {
        let parts = identity.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }

        let user = parts[0]
        let host = normalizedHost(parts[1])
        guard user == NSUserName() else { return false }

        let localHosts = [
            Host.current().localizedName,
            Host.current().name,
            ProcessInfo.processInfo.hostName
        ]
        .compactMap { $0 }
        .map(normalizedHost)

        return localHosts.contains { localHost in
            host == localHost || host.hasPrefix(localHost) || localHost.hasPrefix(host)
        }
    }

    nonisolated private static func normalizedHost(_ host: String) -> String {
        host
            .lowercased()
            .replacingOccurrences(of: ".local", with: "")
            .split(separator: ".")
            .first
            .map(String.init) ?? host.lowercased()
    }
}

final class TerminalWorkspace: ObservableObject {
    @Published private(set) var tabs: [TerminalSession] = []
    @Published var selectedID: TerminalSession.ID?

    private let automaticallyStartProcesses: Bool
    private var nextSequence = 1
    private var preparedTab: TerminalSession?
    private var isPreparingNextTab = false
    private var lastShortcutNewTabUptime: TimeInterval = -.infinity
    private var lastShortcutNewTabEventTimestamp: TimeInterval?

    init(automaticallyStartProcesses: Bool = true) {
        self.automaticallyStartProcesses = automaticallyStartProcesses
        newTab()
    }

    deinit {
        preparedTab?.controller.terminate()
    }

    var selectedTab: TerminalSession? {
        guard let selectedID else { return tabs.first }
        return tabs.first { $0.id == selectedID } ?? tabs.first
    }

    func newTab() {
        let tab = takePreparedTab()
        tabs.append(tab)
        selectedID = tab.id
        if automaticallyStartProcesses {
            DispatchQueue.main.async {
                tab.startProcessIfNeeded()
            }
        }
        schedulePrepareNextTab()
    }

    func newTabFromShortcut(eventTimestamp: TimeInterval? = nil) {
        if let eventTimestamp {
            guard eventTimestamp != lastShortcutNewTabEventTimestamp else { return }
            lastShortcutNewTabEventTimestamp = eventTimestamp
            newTab()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastShortcutNewTabUptime > 0.2 else { return }
        lastShortcutNewTabUptime = now
        newTab()
    }

    func select(_ tab: TerminalSession) {
        selectedID = tab.id
    }

    func selectNextTab() {
        selectRelativeTab(offset: 1)
    }

    func selectPreviousTab() {
        selectRelativeTab(offset: -1)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }

    func close(_ tab: TerminalSession) {
        tab.controller.terminate()
        guard tabs.count > 1 else {
            newTab()
            tabs.removeAll { $0.id == tab.id }
            selectedID = tabs.first?.id
            return
        }

        let index = tabs.firstIndex { $0.id == tab.id }
        tabs.removeAll { $0.id == tab.id }

        if selectedID == tab.id {
            let fallbackIndex = min(index ?? 0, tabs.count - 1)
            selectedID = tabs[fallbackIndex].id
        }
    }

    private func selectRelativeTab(offset: Int) {
        guard tabs.count > 1 else { return }

        let currentIndex = selectedTab.flatMap { selected in
            tabs.firstIndex { $0.id == selected.id }
        } ?? 0

        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        selectedID = tabs[nextIndex].id
    }

    private func takePreparedTab() -> TerminalSession {
        if let preparedTab {
            self.preparedTab = nil
            return preparedTab
        }

        return makeTab()
    }

    private func makeTab() -> TerminalSession {
        let tab = TerminalSession(sequence: nextSequence)
        nextSequence += 1
        return tab
    }

    private func schedulePrepareNextTab() {
        guard automaticallyStartProcesses else { return }
        guard preparedTab == nil, !isPreparingNextTab else { return }
        isPreparingNextTab = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.prepareNextTab()
        }
    }

    private func prepareNextTab() {
        defer { isPreparingNextTab = false }
        guard preparedTab == nil else { return }

        let tab = makeTab()
        tab.prepareController()
        tab.startProcessIfNeeded()
        preparedTab = tab
    }
}
