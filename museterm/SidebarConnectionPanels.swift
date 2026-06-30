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

                Spacer()
            }

            if store.profiles.isEmpty {
                Text(L10n.string("ssh.empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.profiles) { profile in
                    sshProfileRow(profile)
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
    }

    private func sshProfileRow(_ profile: SSHConnectionProfile) -> some View {
        HStack(spacing: 7) {
            Button {
                workspace.openSSH(profile: profile)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: profile.jumpHosts.isEmpty ? "network" : "point.3.connected.trianglepath.dotted")
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.displayName)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        Text(profile.target)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                }
                // 整块名字区域都可点击直接连接，而非仅文字本身。
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("ssh.connect"))

            Menu {
                Button {
                    editingProfile = profile
                } label: {
                    Label(L10n.string("ssh.edit"), systemImage: "pencil")
                }
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
        .help(profile.jumpHosts.isEmpty ? profile.target : L10n.format("ssh.tooltip_with_jumps", profile.target, profile.jumpHosts.count))
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
    @State private var host: String
    @State private var user: String
    @State private var portText: String
    @State private var identityText: String
    @State private var jumpText: String
    @State private var optionText: String
    @State private var startupText: String
    let onCancel: () -> Void
    let onSave: (SSHConnectionProfile) -> Void

    init(profile: SSHConnectionProfile, onCancel: @escaping () -> Void, onSave: @escaping (SSHConnectionProfile) -> Void) {
        let clean = profile.normalized
        _id = State(initialValue: clean.id)
        _name = State(initialValue: clean.name)
        _host = State(initialValue: clean.host)
        _user = State(initialValue: clean.user)
        _portText = State(initialValue: "\(clean.port)")
        _identityText = State(initialValue: clean.identityFiles.joined(separator: "\n"))
        _jumpText = State(initialValue: Self.jumpText(from: clean.jumpHosts))
        _optionText = State(initialValue: clean.extraOptions.joined(separator: "\n"))
        _startupText = State(initialValue: clean.startupCommands.joined(separator: "\n"))
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("ssh.editor.title"))
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                textRow("ssh.name", text: $name)
                textRow("ssh.host", text: $host)
                textRow("ssh.user", text: $user)
                textRow("ssh.port", text: $portText)
            }

            labeledEditor("ssh.identities", help: "ssh.identities.help", text: $identityText, height: 58)
            labeledEditor("ssh.jumps", help: "ssh.jumps.help", text: $jumpText, height: 86)
            labeledEditor("ssh.options", help: "ssh.options.help", text: $optionText, height: 62)
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
            extraOptions: optionText.lines,
            startupCommands: startupText.lines
        )
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
