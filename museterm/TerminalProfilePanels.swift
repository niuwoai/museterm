import SwiftUI

/// 侧栏「终端 Profile」区：列出、开 tab、设默认、增删改。
struct TerminalProfilesSection: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var store: TerminalProfileStore
    let skin: TerminalVisualSkin
    @State private var editingProfile: TerminalProfile?

    var body: some View {
        SidebarSection(
            title: L10n.string("profile.section"),
            systemImage: "person.crop.rectangle.stack",
            skin: skin,
            initiallyExpanded: false,
            kind: .profiles,
            preferences: workspace.preferences
        ) {
            HStack(spacing: 6) {
                Button {
                    editingProfile = TerminalProfile()
                } label: {
                    Label(L10n.string("profile.add"), systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(skin.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Spacer()
            }

            ForEach(store.profiles) { profile in
                profileRow(profile)
            }
        }
        .sheet(item: $editingProfile) { profile in
            TerminalProfileEditorSheet(
                profile: profile,
                onCancel: { editingProfile = nil },
                onSave: { edited in
                    store.upsert(edited)
                    editingProfile = nil
                }
            )
        }
    }

    private func profileRow(_ profile: TerminalProfile) -> some View {
        HStack(spacing: 7) {
            Button {
                workspace.newTab(profile: profile)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: profile.isDefault ? "star.fill" : "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(profile.isDefault ? .yellow : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.displayName)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        Text(profileSubtitle(profile))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("profile.open"))

            Menu {
                Button {
                    workspace.newTab(profile: profile)
                } label: {
                    Label(L10n.string("profile.open"), systemImage: "plus.rectangle.on.rectangle")
                }
                Button {
                    store.setDefault(profile)
                } label: {
                    Label(L10n.string("profile.set_default"), systemImage: "star")
                }
                .disabled(profile.isDefault)
                Button {
                    editingProfile = profile
                } label: {
                    Label(L10n.string("profile.edit"), systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    store.delete(profile)
                } label: {
                    Label(L10n.string("profile.delete"), systemImage: "trash")
                }
                .disabled(profile.isDefault)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(skin.controlFill.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func profileSubtitle(_ profile: TerminalProfile) -> String {
        let shell = L10n.string(profile.shell.titleKey)
        let prompt = L10n.string(profile.promptStyle.titleKey)
        return "\(shell) · \(prompt)"
    }
}

/// 轻量可折叠分区容器（与 SSH 区风格一致，但本文件自持，避免依赖 file-private 组件）。
/// 新建/编辑 Profile 的表单。
struct TerminalProfileEditorSheet: View {
    @State private var id: UUID
    @State private var name: String
    @State private var shell: ProfileShellKind
    @State private var customShellPath: String
    @State private var promptStyle: PromptStyle
    @State private var customPrompt: String
    @State private var environmentText: String
    @State private var startupText: String
    @State private var workingDirectory: String
    @State private var makeDefault: Bool
    private let wasDefault: Bool
    let onCancel: () -> Void
    let onSave: (TerminalProfile) -> Void

    init(profile: TerminalProfile, onCancel: @escaping () -> Void, onSave: @escaping (TerminalProfile) -> Void) {
        let clean = profile.normalized
        _id = State(initialValue: clean.id)
        _name = State(initialValue: clean.name)
        _shell = State(initialValue: clean.shell)
        _customShellPath = State(initialValue: clean.customShellPath)
        _promptStyle = State(initialValue: clean.promptStyle)
        _customPrompt = State(initialValue: clean.customPrompt)
        _environmentText = State(initialValue: Self.environmentText(from: clean.environment))
        _startupText = State(initialValue: clean.startupCommands.joined(separator: "\n"))
        _workingDirectory = State(initialValue: clean.workingDirectory)
        _makeDefault = State(initialValue: clean.isDefault)
        wasDefault = clean.isDefault
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("profile.editor.title"))
                .font(.headline)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    labeledField("profile.name") {
                        TextField(L10n.string("profile.name.placeholder"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    labeledField("profile.shell") {
                        Picker("", selection: $shell) {
                            ForEach(ProfileShellKind.allCases) { kind in
                                Text(L10n.string(kind.titleKey)).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    if shell == .custom {
                        labeledField("profile.shell.custom_path", help: "profile.shell.custom_path.help") {
                            TextField("/opt/homebrew/bin/nu", text: $customShellPath)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    labeledField("profile.prompt", help: "profile.prompt.help") {
                        Picker("", selection: $promptStyle) {
                            ForEach(PromptStyle.allCases) { style in
                                Text(L10n.string(style.titleKey)).tag(style)
                            }
                        }
                        .labelsHidden()
                    }

                    if promptStyle == .custom {
                        labeledEditor("profile.prompt.custom", help: "profile.prompt.custom.help", text: $customPrompt, height: 54)
                    }

                    labeledField("profile.working_directory", help: "profile.working_directory.help") {
                        TextField("~/Projects", text: $workingDirectory)
                            .textFieldStyle(.roundedBorder)
                    }

                    labeledEditor("profile.environment", help: "profile.environment.help", text: $environmentText, height: 76)
                    labeledEditor("profile.startup", help: "profile.startup.help", text: $startupText, height: 62)

                    Toggle(L10n.string("profile.make_default"), isOn: $makeDefault)
                        .disabled(wasDefault)
                        .help(L10n.string("profile.make_default.help"))
                }
                .padding(.vertical, 12)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.string("action.cancel"), action: onCancel)
                Button(L10n.string("action.save")) {
                    onSave(builtProfile)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 12)
        }
        .padding(18)
        .frame(width: 520, height: 560)
    }

    private var builtProfile: TerminalProfile {
        TerminalProfile(
            id: id,
            name: name,
            shell: shell,
            customShellPath: customShellPath,
            promptStyle: promptStyle,
            customPrompt: customPrompt,
            environment: Self.environment(from: environmentText),
            startupCommands: startupText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0) },
            workingDirectory: workingDirectory,
            // 编辑本就是默认项时保持默认；否则由勾选决定是否设为默认。
            isDefault: wasDefault || makeDefault,
            isFavorite: false
        ).normalized
    }

    @ViewBuilder
    private func labeledField<Content: View>(
        _ titleKey: String,
        help helpKey: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(titleKey))
                .font(.caption.weight(.medium))
            content()
            if let helpKey {
                Text(L10n.string(helpKey))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labeledEditor(
        _ titleKey: String,
        help helpKey: String,
        text: Binding<String>,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(titleKey))
                .font(.caption.weight(.medium))
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            Text(L10n.string(helpKey))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func environmentText(from environment: [String: String]) -> String {
        environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    private static func environment(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}
