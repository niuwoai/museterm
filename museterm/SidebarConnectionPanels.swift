import AppKit
import SwiftUI

struct TerminalShortcutSection: View {
    @ObservedObject var workspace: TerminalWorkspace
    let skin: TerminalVisualSkin
    @State private var renameDraft: TerminalShortcutRenameDraft?
    @State private var isEditingJSON = false

    var body: some View {
        SidebarSection(title: L10n.string("shortcut.section"), systemImage: "record.circle", skin: skin) {
            HStack(spacing: 6) {
                Button {
                    if workspace.isRecording {
                        workspace.stopRecording()
                    } else {
                        workspace.startRecordingSelectedTab()
                    }
                } label: {
                    Label(
                        workspace.isRecording ? L10n.string("shortcut.stop_recording") : L10n.string("shortcut.start_recording"),
                        systemImage: workspace.isRecording ? "stop.fill" : "record.circle"
                    )
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 26)
                    .foregroundStyle(workspace.isRecording ? Color.white : Color.red)
                    .background(workspace.isRecording ? Color.red : Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(workspace.isRecording ? L10n.string("shortcut.stop_recording") : L10n.string("shortcut.start_recording"))

                Button {
                    isEditingJSON = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help(L10n.string("shortcut.edit_json"))

                Spacer()
            }

            if workspace.shortcuts.isEmpty {
                Text(L10n.string("shortcut.empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(workspace.shortcuts) { shortcut in
                    shortcutMenu(shortcut)
                }
            }
        }
        .sheet(item: $renameDraft) { draft in
            TerminalShortcutRenameSheet(
                title: draft.title,
                onCancel: { renameDraft = nil },
                onSave: { title in
                    workspace.renameShortcut(id: draft.shortcutID, title: title)
                    renameDraft = nil
                }
            )
        }
        .sheet(isPresented: $isEditingJSON) {
            TerminalShortcutJSONEditorSheet(
                initialText: workspace.editableShortcutsText(),
                onCancel: { isEditingJSON = false },
                onSave: { text in
                    try workspace.saveEditableShortcutsText(text)
                    isEditingJSON = false
                }
            )
        }
    }

    private func shortcutMenu(_ shortcut: TerminalShortcut) -> some View {
        Menu {
            Button {
                workspace.playShortcut(shortcut)
            } label: {
                Label(L10n.string("shortcut.play"), systemImage: "play.fill")
            }
            .disabled(workspace.isRecording)

            Button {
                renameDraft = TerminalShortcutRenameDraft(shortcut: shortcut)
            } label: {
                Label(L10n.string("shortcut.rename"), systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                workspace.deleteShortcut(id: shortcut.id)
            } label: {
                Label(L10n.string("shortcut.delete"), systemImage: "trash")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(shortcut.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                if shortcut.hasProtectedInput {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(skin.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(L10n.format("shortcut.tooltip", shortcut.eventCount, max(1, shortcut.durationMilliseconds / 1000)))
    }
}

struct SSHProfilesSection: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var store: SSHConnectionStore
    let skin: TerminalVisualSkin
    @State private var editingProfile: SSHConnectionProfile?
    @State private var diagnosticProfile: SSHConnectionProfile?
    @State private var configPreviewProfile: SSHConnectionProfile?
    @State private var importMessage = ""
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var collapsedProfileGroups: Set<String> = []

    var body: some View {
        SidebarSection(title: L10n.string("ssh.section"), systemImage: "network", skin: skin) {
            HStack(spacing: 6) {
                Button {
                    editingProfile = SSHConnectionProfile()
                } label: {
                    Label(L10n.string("ssh.add"), systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(skin.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Button {
                    importDefaultOpenSSHConfig()
                } label: {
                    Label(L10n.string("ssh.import"), systemImage: "tray.and.arrow.down")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(skin.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help(L10n.string("ssh.import.help"))

                Spacer()
            }

            if !importMessage.isEmpty {
                Text(importMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.profiles.isEmpty {
                Text(L10n.string("ssh.empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if filteredProfiles.isEmpty {
                searchControls
                Text(L10n.string("ssh.search.empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                searchControls
                ForEach(groupedProfiles) { group in
                    if groupedProfiles.count > 1 {
                        profileGroupHeader(group)
                    }
                    if !isProfileGroupCollapsed(group) {
                        ForEach(group.profiles) { profile in
                            sshProfileRow(profile)
                        }
                    }
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            SSHProfileEditorSheet(
                profile: profile,
                onCancel: { editingProfile = nil },
                onSave: { edited in
                    store.upsert(edited)
                    editingProfile = nil
                }
            )
        }
        .sheet(item: $diagnosticProfile) { profile in
            SSHRouteDiagnosticPlanSheet(
                profile: profile,
                workspace: workspace,
                skin: skin,
                onClose: { diagnosticProfile = nil }
            )
        }
        .sheet(item: $configPreviewProfile) { profile in
            SSHConfigPreviewSheet(
                profile: profile,
                skin: skin,
                onClose: { configPreviewProfile = nil }
            )
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(L10n.string("ssh.search.placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption2)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("action.clear"))
                }
                if groupedProfiles.count > 1 {
                    Button {
                        expandAllProfileGroups()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("ssh.groups.expand_all"))

                    Button {
                        collapseAllProfileGroups()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("ssh.groups.collapse_all"))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(skin.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help(L10n.string("ssh.search.help"))

            if !availableTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        tagFilterButton(title: L10n.string("ssh.tags.all"), tag: nil)
                        ForEach(availableTags, id: \.self) { tag in
                            tagFilterButton(title: "#\(tag)", tag: tag)
                        }
                    }
                }
            }
        }
    }

    private func tagFilterButton(title: String, tag: String?) -> some View {
        let isSelected = selectedTag == tag
        return Button {
            selectedTag = tag
        } label: {
            Text(title)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .background(isSelected ? Color.accentColor : skin.controlFill)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var filteredProfiles: [SSHConnectionProfile] {
        store.profiles.filter { $0.matchesSearch(searchText, selectedTag: selectedTag) }
    }

    private var availableTags: [String] {
        var seen: Set<String> = []
        var tags: [String] = []
        for tag in store.profiles.flatMap({ $0.normalized.tags }) {
            let key = tag.lowercased()
            guard seen.insert(key).inserted else { continue }
            tags.append(tag)
        }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var groupedProfiles: [SSHProfileListGroup] {
        let favoriteProfiles = sortedProfiles(filteredProfiles.filter { $0.normalized.isFavorite })
        let regularProfiles = filteredProfiles.filter { !$0.normalized.isFavorite }
        let groups = Dictionary(grouping: regularProfiles) { profile in
            profile.normalized.groupDisplayName
        }

        var result: [SSHProfileListGroup] = []
        if !favoriteProfiles.isEmpty {
            result.append(
                SSHProfileListGroup(
                    id: "__favorites",
                    name: L10n.string("ssh.group.favorites"),
                    profiles: favoriteProfiles
                )
            )
        }

        result += groups
            .map { SSHProfileListGroup(name: $0.key, profiles: $0.value) }
            .sorted { lhs, rhs in
                if lhs.name == L10n.string("ssh.group.ungrouped") { return false }
                if rhs.name == L10n.string("ssh.group.ungrouped") { return true }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        return result
    }

    private func sortedProfiles(_ profiles: [SSHConnectionProfile]) -> [SSHConnectionProfile] {
        profiles.sorted { lhs, rhs in
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let targetOrder = lhs.target.localizedCaseInsensitiveCompare(rhs.target)
            if targetOrder != .orderedSame { return targetOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func profileGroupHeader(_ group: SSHProfileListGroup) -> some View {
        let isCollapsed = isProfileGroupCollapsed(group)
        return Button {
            toggleProfileGroup(group)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 10)
                    .foregroundStyle(.secondary)
                Text(group.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(group.profiles.count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(skin.controlFill)
                    .clipShape(Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 3)
        .help(L10n.format(isCollapsed ? "ssh.group.expand.help" : "ssh.group.collapse.help", group.name))
    }

    private func isProfileGroupCollapsed(_ group: SSHProfileListGroup) -> Bool {
        collapsedProfileGroups.contains(group.id)
    }

    private func toggleProfileGroup(_ group: SSHProfileListGroup) {
        if collapsedProfileGroups.contains(group.id) {
            collapsedProfileGroups.remove(group.id)
        } else {
            collapsedProfileGroups.insert(group.id)
        }
    }

    private func expandAllProfileGroups() {
        collapsedProfileGroups.removeAll()
    }

    private func collapseAllProfileGroups() {
        collapsedProfileGroups = Set(groupedProfiles.map(\.id))
    }

    private func sshProfileRow(_ profile: SSHConnectionProfile) -> some View {
        let health = profile.healthSummary
        let portForwardSummary = profile.portForwardSummaryText
        let portForwardAccessEntries = profile.portForwardAccessEntries
        return HStack(spacing: 7) {
            Button {
                workspace.openSSH(profile: profile)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: profile.jumpHosts.isEmpty ? "network" : "point.3.connected.trianglepath.dotted")
                        .frame(width: 20)
                    if profile.normalized.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.yellow)
                            .help(L10n.string("ssh.favorite.status"))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.displayName)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        Text(profile.target)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !profile.normalized.tags.isEmpty {
                            Text(profile.normalized.tags.map { "#\($0)" }.joined(separator: " "))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    SSHProfileHealthBadges(summary: health)
                    SSHProfilePortForwardBadge(
                        count: profile.usablePortForwards.count,
                        summary: portForwardSummary
                    )
                    EnvironmentBadge(environment: profile.environment)
                }
                // 整块名字区域都可点击直接连接，而非仅文字本身。
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("ssh.connect"))

            Menu {
                Button {
                    store.toggleFavorite(profile)
                } label: {
                    Label(
                        profile.normalized.isFavorite
                            ? L10n.string("ssh.favorite.remove")
                            : L10n.string("ssh.favorite.add"),
                        systemImage: profile.normalized.isFavorite ? "star.slash" : "star"
                    )
                }
                .help(
                    profile.normalized.isFavorite
                        ? L10n.string("ssh.favorite.remove.help")
                        : L10n.string("ssh.favorite.add.help")
                )
                Button {
                    editingProfile = profile
                } label: {
                    Label(L10n.string("ssh.edit"), systemImage: "pencil")
                }
                Button {
                    copyOpenSSHConfigSnippet(for: profile)
                } label: {
                    Label(L10n.string("ssh.copy_config"), systemImage: "doc.on.doc")
                }
                .help(L10n.string("ssh.copy_config.help"))
                Button {
                    configPreviewProfile = profile
                } label: {
                    Label(L10n.string("ssh.config_preview.open"), systemImage: "doc.plaintext")
                }
                .help(L10n.string("ssh.config_preview.open.help"))
                Button {
                    copyPortForwardSummary(for: profile)
                } label: {
                    Label(L10n.string("ssh.copy_port_forwards"), systemImage: "arrow.left.arrow.right")
                }
                .disabled(profile.usablePortForwards.isEmpty)
                .help(L10n.string("ssh.copy_port_forwards.help"))
                Menu {
                    ForEach(portForwardAccessEntries) { entry in
                        if entry.canOpenInBrowser {
                            Button {
                                openPortForwardAccess(entry)
                            } label: {
                                Label(
                                    L10n.format("ssh.open_port_forward_entry", entry.urlString),
                                    systemImage: "safari"
                                )
                            }
                        } else {
                            Button {
                                copyPortForwardAccess(entry)
                            } label: {
                                Label(
                                    L10n.format("ssh.copy_port_forward_entry", entry.urlString),
                                    systemImage: "doc.on.doc"
                                )
                            }
                        }
                    }
                } label: {
                    Label(L10n.string("ssh.open_port_forward_entries"), systemImage: "link")
                }
                .disabled(portForwardAccessEntries.isEmpty)
                .help(L10n.string("ssh.open_port_forward_entries.help"))
                Button {
                    diagnosticProfile = profile
                } label: {
                    Label(L10n.string("ssh.diagnostic_plan.open"), systemImage: "checklist")
                }
                .help(L10n.string("ssh.diagnostic_plan.open.help"))
                Divider()
                Button(role: .destructive) {
                    store.delete(profile)
                } label: {
                    Label(L10n.string("ssh.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(rowHelp(for: profile, health: health))
    }

    private func rowHelp(for profile: SSHConnectionProfile, health: SSHProfileHealthSummary) -> String {
        let base = profile.jumpHosts.isEmpty ? profile.target : L10n.format("ssh.tooltip_route", profile.routeSummary)
        let capabilities = profile.connectionCapabilityText
        let portForwards = profile.portForwardClipboardText
        return [
            base,
            capabilities.isEmpty ? nil : capabilities,
            health.hasAttentionItems ? health.tooltip : nil,
            portForwards.isEmpty ? nil : portForwards
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func importDefaultOpenSSHConfig() {
        do {
            let count = try store.importDefaultOpenSSHConfig()
            importMessage = count == 0
                ? L10n.string("ssh.import.none")
                : L10n.format("ssh.import.success", count)
        } catch {
            importMessage = L10n.format("ssh.import.failed", error.localizedDescription)
        }
    }

    private func copyOpenSSHConfigSnippet(for profile: SSHConnectionProfile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SSHConfigMaterializer.exportSnippet(for: profile), forType: .string)
        importMessage = L10n.format("ssh.copy_config.copied", profile.displayName)
    }

    private func copyPortForwardSummary(for profile: SSHConnectionProfile) {
        let summary = profile.portForwardClipboardText
        guard !summary.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        importMessage = L10n.format("ssh.copy_port_forwards.copied", profile.displayName)
    }

    private func openPortForwardAccess(_ entry: SSHPortForwardAccessEntry) {
        guard let url = URL(string: entry.urlString) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func copyPortForwardAccess(_ entry: SSHPortForwardAccessEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.urlString, forType: .string)
        importMessage = L10n.format("ssh.copy_port_forward_entry.copied", entry.urlString)
    }
}

private struct SSHProfileListGroup: Identifiable {
    let id: String
    let name: String
    let profiles: [SSHConnectionProfile]

    init(id: String? = nil, name: String, profiles: [SSHConnectionProfile]) {
        self.id = id ?? "group:\(name)"
        self.name = name
        self.profiles = profiles.sorted { lhs, rhs in
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let targetOrder = lhs.target.localizedCaseInsensitiveCompare(rhs.target)
            if targetOrder != .orderedSame { return targetOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

private struct SSHProfileHealthBadges: View {
    let summary: SSHProfileHealthSummary

    var body: some View {
        HStack(spacing: 4) {
            if summary.preflightIssueCount > 0 {
                badge(
                    count: summary.preflightIssueCount,
                    systemImage: "checklist.unchecked",
                    color: .blue,
                    help: summary.tooltip
                )
            }
            if summary.securityWarningCount > 0 {
                badge(
                    count: summary.securityWarningCount,
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange,
                    help: summary.tooltip
                )
            }
        }
    }

    private func badge(count: Int, systemImage: String, color: Color, help: String) -> some View {
        Label {
            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help(help)
    }
}

private struct SSHProfilePortForwardBadge: View {
    let count: Int
    let summary: String

    var body: some View {
        if count > 0 {
            Label {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            } icon: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(Color.teal)
            .background(Color.teal.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help(summary)
        }
    }
}

struct FileTransferSection: View {
    @ObservedObject var workspace: TerminalWorkspace
    let skin: TerminalVisualSkin

    var body: some View {
        SidebarSection(title: L10n.string("file_transfer.section"), systemImage: "arrow.up.arrow.down.square", skin: skin) {
            if let selectedTab = workspace.selectedTab {
                FileTransferControls(workspace: workspace, tab: selectedTab, skin: skin)
            } else {
                Text(L10n.string("file_transfer.no_tab"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FileTransferControls: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var tab: TerminalSession
    let skin: TerminalVisualSkin

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    openUploadPanel()
                } label: {
                    Label(L10n.string("file_transfer.upload"), systemImage: "tray.and.arrow.up.fill")
                        .font(.caption.weight(.medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(skin.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(isTransferActive)
                .help(L10n.string("file_transfer.upload.help"))

                Button {
                    openDownloadPrompt()
                } label: {
                    Label(L10n.string("file_transfer.download"), systemImage: "tray.and.arrow.down.fill")
                        .font(.caption.weight(.medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(skin.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(isTransferActive)
                .help(L10n.string("file_transfer.download.help"))
            }

            if let status = tab.fileTransferStatus {
                Text(status.localizedSummary)
                    .font(.caption2)
                    .foregroundStyle(status.phase == .failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = tab.fileTransferStatus, status.isActive {
                if let percent = status.progress?.percent {
                    ProgressView(value: percent)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                if let progressText = progressText(for: status) {
                    Text(progressText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var isTransferActive: Bool {
        tab.fileTransferStatus?.isActive == true
    }

    private func openUploadPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("file_transfer.upload.panel_title")
        panel.prompt = L10n.string("file_transfer.upload")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        workspace.startZModemUpload(fileURLs: panel.urls)
    }

    private func openDownloadPrompt() {
        let savePanel = NSSavePanel()
        savePanel.title = L10n.string("file_transfer.download.save_title")
        savePanel.prompt = L10n.string("file_transfer.download")
        savePanel.nameFieldStringValue = L10n.string("file_transfer.download.default_filename")
        guard savePanel.runModal() == .OK, let destinationFile = savePanel.url else { return }

        let alert = NSAlert()
        alert.messageText = L10n.string("file_transfer.download.prompt_title")
        alert.informativeText = L10n.string("file_transfer.download.prompt_message")
        alert.addButton(withTitle: L10n.string("action.save"))
        alert.addButton(withTitle: L10n.string("action.cancel"))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = L10n.string("file_transfer.download.placeholder")
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let remotePath = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remotePath.isEmpty else { return }
        workspace.startZModemDownload(remotePath: remotePath, destinationFile: destinationFile)
    }

    private func progressText(for status: TerminalFileTransferStatus) -> String? {
        if let fileName = status.progress?.fileName, let percent = status.progress?.percent {
            return L10n.format("file_transfer.progress.with_percent", fileName, Int((percent * 100).rounded()))
        }
        if let fileName = status.progress?.fileName {
            return fileName
        }
        return status.progress?.detail
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    let systemImage: String
    let skin: TerminalVisualSkin
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EnvironmentBadge: View {
    let environment: TerminalEnvironmentKind

    var body: some View {
        Text(environment.shortName)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help(environment.name)
    }

    private var background: Color {
        switch environment {
        case .local:
            return Color.secondary.opacity(0.14)
        case .development:
            return Color.blue.opacity(0.16)
        case .staging:
            return Color.orange.opacity(0.20)
        case .production:
            return Color.red.opacity(0.22)
        }
    }

    private var foreground: Color {
        switch environment {
        case .local:
            return .secondary
        case .development:
            return .blue
        case .staging:
            return .orange
        case .production:
            return .red
        }
    }
}

private struct TerminalShortcutRenameDraft: Identifiable {
    let id = UUID()
    let shortcutID: UUID
    let title: String

    init(shortcut: TerminalShortcut) {
        shortcutID = shortcut.id
        title = shortcut.title
    }
}

private struct TerminalShortcutRenameSheet: View {
    @State private var title: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    init(title: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        _title = State(initialValue: title)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("shortcut.rename_title"))
                .font(.headline)
            TextField(L10n.string("shortcut.name"), text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button(L10n.string("action.cancel"), action: onCancel)
                Button(L10n.string("action.save")) {
                    onSave(title)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}

private struct TerminalShortcutJSONEditorSheet: View {
    @State private var text: String
    @State private var errorMessage = ""
    let onCancel: () -> Void
    let onSave: (String) throws -> Void

    init(initialText: String, onCancel: @escaping () -> Void, onSave: @escaping (String) throws -> Void) {
        _text = State(initialValue: initialText)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("shortcut.edit_json"))
                .font(.headline)
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 620, height: 360)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(TerminalShortcutStore.fileURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(L10n.string("action.cancel"), action: onCancel)
                Button(L10n.string("action.save")) {
                    do {
                        try onSave(text)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

private struct SSHProfileEditorSheet: View {
    @State private var id: UUID
    @State private var name: String
    @State private var groupName: String
    @State private var tagsText: String
    @State private var host: String
    @State private var user: String
    @State private var portText: String
    @State private var identityText: String
    @State private var jumpText: String
    @State private var portForwardText: String
    @State private var optionText: String
    @State private var startupText: String
    @State private var keepAliveEnabled: Bool
    @State private var keepAliveIntervalText: String
    @State private var keepAliveCountText: String
    @State private var connectionReuseEnabled: Bool
    @State private var connectionReusePersistText: String
    @State private var automaticReconnectEnabled: Bool
    @State private var automaticReconnectAttemptsText: String
    @State private var automaticReconnectDelayText: String
    @State private var remoteShellIntegrationEnabled: Bool
    @State private var environment: TerminalEnvironmentKind
    @State private var safetyPolicy: SSHSafetyConfirmationPolicy
    let onCancel: () -> Void
    let onSave: (SSHConnectionProfile) -> Void

    init(profile: SSHConnectionProfile, onCancel: @escaping () -> Void, onSave: @escaping (SSHConnectionProfile) -> Void) {
        let clean = profile.normalized
        _id = State(initialValue: clean.id)
        _name = State(initialValue: clean.name)
        _groupName = State(initialValue: clean.groupName)
        _tagsText = State(initialValue: clean.tags.joined(separator: ", "))
        _host = State(initialValue: clean.host)
        _user = State(initialValue: clean.user)
        _portText = State(initialValue: "\(clean.port)")
        _identityText = State(initialValue: clean.identityFiles.joined(separator: "\n"))
        _jumpText = State(initialValue: Self.jumpText(from: clean.jumpHosts))
        _portForwardText = State(initialValue: Self.portForwardText(from: clean.portForwards))
        _optionText = State(initialValue: clean.extraOptions.joined(separator: "\n"))
        _startupText = State(initialValue: clean.startupCommands.joined(separator: "\n"))
        _keepAliveEnabled = State(initialValue: clean.keepAliveEnabled)
        _keepAliveIntervalText = State(initialValue: "\(clean.keepAliveIntervalSeconds)")
        _keepAliveCountText = State(initialValue: "\(clean.keepAliveCountMax)")
        _connectionReuseEnabled = State(initialValue: clean.connectionReuseEnabled)
        _connectionReusePersistText = State(initialValue: "\(clean.connectionReusePersistMinutes)")
        _automaticReconnectEnabled = State(initialValue: clean.automaticReconnectEnabled)
        _automaticReconnectAttemptsText = State(initialValue: "\(clean.automaticReconnectAttempts)")
        _automaticReconnectDelayText = State(initialValue: "\(clean.automaticReconnectDelaySeconds)")
        _remoteShellIntegrationEnabled = State(initialValue: clean.remoteShellIntegrationEnabled)
        _environment = State(initialValue: clean.environment)
        _safetyPolicy = State(initialValue: clean.safetyPolicy)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("ssh.editor.title"))
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                textRow("ssh.name", text: $name)
                textRow("ssh.group", text: $groupName)
                textRow("ssh.tags", text: $tagsText)
                textRow("ssh.host", text: $host)
                textRow("ssh.user", text: $user)
                textRow("ssh.port", text: $portText)
                environmentRow
                safetyPolicyRow
                keepAliveRow
                connectionReuseRow
                automaticReconnectRow
                remoteShellIntegrationRow
            }

            labeledEditor("ssh.identities", help: "ssh.identities.help", text: $identityText, height: 58)
            labeledEditor("ssh.jumps", help: "ssh.jumps.help", text: $jumpText, height: 86)
            routeSummaryView
            labeledEditor("ssh.port_forwards", help: "ssh.port_forwards.help", text: $portForwardText, height: 86)
            portForwardPreviewView
            preflightIssuesView
            labeledEditor("ssh.options", help: "ssh.options.help", text: $optionText, height: 62)
            securityWarningsView
            labeledEditor("ssh.startup", help: "ssh.startup.help", text: $startupText, height: 62)

            HStack {
                Spacer()
                Button(L10n.string("action.cancel"), action: onCancel)
                Button(L10n.string("action.save")) {
                    onSave(profile)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private var profile: SSHConnectionProfile {
        SSHConnectionProfile(
            id: id,
            name: name,
            host: host,
            user: user,
            port: Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22,
            identityFiles: identityText.lines,
            jumpHosts: Self.parseJumpHosts(jumpText),
            portForwards: Self.parsePortForwards(portForwardText),
            extraOptions: optionText.lines,
            startupCommands: startupText.lines,
            keepAliveEnabled: keepAliveEnabled,
            keepAliveIntervalSeconds: Int(keepAliveIntervalText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 30,
            keepAliveCountMax: Int(keepAliveCountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 6,
            connectionReuseEnabled: connectionReuseEnabled,
            connectionReusePersistMinutes: Int(connectionReusePersistText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 10,
            automaticReconnectEnabled: automaticReconnectEnabled,
            automaticReconnectAttempts: Int(automaticReconnectAttemptsText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 3,
            automaticReconnectDelaySeconds: Int(automaticReconnectDelayText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 3,
            remoteShellIntegrationEnabled: remoteShellIntegrationEnabled,
            environment: environment,
            safetyPolicy: safetyPolicy,
            groupName: groupName,
            tags: Self.parseTags(tagsText)
        )
    }

    private var keepAliveRow: some View {
        GridRow {
            Text(L10n.string("ssh.keep_alive"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L10n.string("ssh.keep_alive.enabled"), isOn: $keepAliveEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                HStack(spacing: 8) {
                    Text(L10n.string("ssh.keep_alive.interval"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("30", text: $keepAliveIntervalText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .disabled(!keepAliveEnabled)
                    Text(L10n.string("ssh.keep_alive.count"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("6", text: $keepAliveCountText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .disabled(!keepAliveEnabled)
                }

                Text(L10n.string("ssh.keep_alive.help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionReuseRow: some View {
        GridRow {
            Text(L10n.string("ssh.connection_reuse"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L10n.string("ssh.connection_reuse.enabled"), isOn: $connectionReuseEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                HStack(spacing: 8) {
                    Text(L10n.string("ssh.connection_reuse.persist"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("10", text: $connectionReusePersistText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .disabled(!connectionReuseEnabled)
                }

                Text(L10n.string("ssh.connection_reuse.help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var automaticReconnectRow: some View {
        GridRow {
            Text(L10n.string("ssh.reconnect"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L10n.string("ssh.reconnect.enabled"), isOn: $automaticReconnectEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                HStack(spacing: 8) {
                    Text(L10n.string("ssh.reconnect.attempts"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("3", text: $automaticReconnectAttemptsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .disabled(!automaticReconnectEnabled)
                    Text(L10n.string("ssh.reconnect.delay"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("3", text: $automaticReconnectDelayText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .disabled(!automaticReconnectEnabled)
                }

                Text(L10n.string("ssh.reconnect.help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var remoteShellIntegrationRow: some View {
        GridRow {
            Text(L10n.string("ssh.remote_shell_integration"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Toggle(L10n.string("ssh.remote_shell_integration.help"), isOn: $remoteShellIntegrationEnabled)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
    }

    private var environmentRow: some View {
        GridRow {
            Text(L10n.string("ssh.environment"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Picker(L10n.string("ssh.environment"), selection: $environment) {
                ForEach(TerminalEnvironmentKind.allCases.filter { $0 != .local }) { environment in
                    Text(environment.name).tag(environment)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: environment) { newEnvironment in
                if newEnvironment == .production, safetyPolicy == .inherit {
                    safetyPolicy = .forceConfirm
                }
            }
        }
    }

    private var safetyPolicyRow: some View {
        GridRow {
            Text(L10n.string("ssh.safety_policy"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Picker(L10n.string("ssh.safety_policy"), selection: $safetyPolicy) {
                    ForEach(SSHSafetyConfirmationPolicy.allCases) { policy in
                        Text(policy.name).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                Text(safetyPolicy.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var routeSummaryView: some View {
        let summary = profile.routeSummary
        if !summary.isEmpty {
            Label(summary, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(L10n.string("ssh.route.help"))
        }
    }

    @ViewBuilder
    private var securityWarningsView: some View {
        let warnings = profile.securityWarningKinds
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(warnings, id: \.rawValue) { warning in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(warning.title)
                                .font(.caption2.weight(.semibold))
                            Text(warning.summary)
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(Color.orange)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    @ViewBuilder
    private var preflightIssuesView: some View {
        let issues = profile.preflightIssues
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(issues) { issue in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.kind.title)
                                .font(.caption2.weight(.semibold))
                            Text(issue.kind.summary(detail: issue.detail))
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "checklist.unchecked")
                    }
                    .foregroundStyle(Color.blue)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.blue.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    @ViewBuilder
    private var portForwardPreviewView: some View {
        let forwards = profile.usablePortForwards
        let hasInput = !portForwardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !forwards.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label(L10n.format("ssh.port_forward.preview.title", forwards.count), systemImage: "tablecells")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    GridRow {
                        previewHeader("ssh.port_forward.preview.kind")
                        previewHeader("ssh.port_forward.preview.listen")
                        previewHeader("ssh.port_forward.preview.target")
                        previewHeader("ssh.port_forward.preview.access")
                    }
                    ForEach(forwards) { forward in
                        let clean = forward.normalized
                        GridRow {
                            Text(clean.kind.displayName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(portForwardColor(for: clean.kind))
                            Text(clean.listenEndpoint)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                            Text(clean.previewTargetText)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                            Text(clean.previewAccessText)
                                .font(.caption2.monospaced())
                                .foregroundStyle(clean.localAccessURLString == nil ? .secondary : .primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.teal.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else if hasInput {
            Label(L10n.string("ssh.port_forward.preview.empty"), systemImage: "exclamationmark.circle")
                .font(.caption2)
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func previewHeader(_ key: String) -> some View {
        Text(L10n.string(key))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func portForwardColor(for kind: SSHPortForwardKind) -> Color {
        switch kind {
        case .local:
            return .teal
        case .remote:
            return .purple
        case .dynamic:
            return .blue
        }
    }

    private func textRow(_ key: String, text: Binding<String>) -> some View {
        GridRow {
            Text(L10n.string(key))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            TextField(L10n.string(key), text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledEditor(_ titleKey: String, help helpKey: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(titleKey))
                .font(.caption.weight(.semibold))
            Text(L10n.string(helpKey))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
    }

    private static func jumpText(from jumps: [SSHJumpHost]) -> String {
        jumps.map { jump in
            let identity = jump.identityFiles.joined(separator: ",")
            let namePart = jump.name.isEmpty ? "" : "\(jump.name)|"
            return "\(namePart)\(jump.user)@\(jump.host):\(jump.port)|\(identity)"
        }
        .joined(separator: "\n")
    }

    private static func portForwardText(from forwards: [SSHPortForward]) -> String {
        forwards.map(\.editorLineText)
        .joined(separator: "\n")
    }

    private static func parseJumpHosts(_ text: String) -> [SSHJumpHost] {
        text.lines.compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let name: String
            let targetPart: String
            let identityPart: String
            if parts.count >= 3 {
                name = parts[0]
                targetPart = parts[1]
                identityPart = parts.dropFirst(2).joined(separator: "|")
            } else {
                name = ""
                targetPart = parts.first ?? ""
                identityPart = parts.dropFirst().first ?? ""
            }
            let parsed = parseTarget(targetPart)
            guard !parsed.host.isEmpty else { return nil }
            return SSHJumpHost(
                name: name,
                host: parsed.host,
                user: parsed.user,
                port: parsed.port,
                identityFiles: identityPart.split(separator: ",").map(String.init)
            )
        }
    }

    private static func parsePortForwards(_ text: String) -> [SSHPortForward] {
        text.lines.compactMap(SSHPortForward.parseEditorLine)
    }

    private static func parseTags(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",， \n\t"))
            .cleanedTagList()
    }

    private static func parseTarget(_ value: String) -> (user: String, host: String, port: Int) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let userAndRest = trimmed.split(separator: "@", maxSplits: 1).map(String.init)
        let user = userAndRest.count == 2 ? userAndRest[0] : ""
        let rest = userAndRest.count == 2 ? userAndRest[1] : userAndRest.first ?? ""
        let hostAndPort = rest.split(separator: ":", maxSplits: 1).map(String.init)
        let host = hostAndPort.first ?? ""
        let port = hostAndPort.count == 2 ? Int(hostAndPort[1]) ?? 22 : 22
        return (user, host, port)
    }
}

private extension String {
    var lines: [String] {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
