import SwiftUI

struct TerminalShortcutJSONEditorSheet: View {
    @State private var text: String
    @State private var errorMessage = ""
    @State private var selectedPasswordID: String?
    @State private var passwordText = ""
    @State private var appendReturnToPassword = true
    @State private var passwordMessage = ""

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
                .frame(width: 720, height: 320)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            HStack(alignment: .top, spacing: 12) {
                editorHelp
                    .frame(width: 354, alignment: .topLeading)
                passwordEditor
                    .frame(width: 354, alignment: .topLeading)
            }

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
        .onAppear(perform: syncSelectedPassword)
        .onChange(of: text) { _ in syncSelectedPassword() }
        .onChange(of: selectedPasswordID) { _ in refreshPasswordMessage() }
    }

    private var editorHelp: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L10n.string("shortcut.edit_help.title"), systemImage: "questionmark.circle")
                .font(.caption.weight(.semibold))
            helpLine("shortcut.edit_help.text_input")
            helpLine("shortcut.edit_help.password_input")
            helpLine("shortcut.edit_help.wait")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func helpLine(_ key: String) -> some View {
        Text(L10n.string(key))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var passwordEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string("shortcut.password.section"), systemImage: "key")
                .font(.caption.weight(.semibold))

            if decodedProtectedInputs == nil {
                Text(L10n.string("shortcut.password.invalid_json"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if protectedInputs.isEmpty {
                Text(L10n.string("shortcut.password.empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(L10n.string("shortcut.password.choose"), selection: $selectedPasswordID) {
                    ForEach(protectedInputs) { input in
                        Text(passwordLabel(for: input))
                            .tag(Optional(input.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                SecureField(L10n.string("shortcut.password.value"), text: $passwordText)
                    .textFieldStyle(.roundedBorder)

                Toggle(L10n.string("shortcut.password.append_return"), isOn: $appendReturnToPassword)
                    .toggleStyle(.checkbox)
                    .font(.caption2)

                if !passwordMessage.isEmpty {
                    Text(passwordMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(L10n.string("shortcut.password.clear")) {
                        clearSelectedPassword()
                    }
                    .disabled(selectedProtectedInput == nil)

                    Spacer()

                    Button(L10n.string("shortcut.password.save")) {
                        saveSelectedPassword()
                    }
                    .disabled(selectedProtectedInput == nil)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var decodedProtectedInputs: [TerminalShortcutProtectedInput]? {
        try? TerminalShortcutStore.protectedInputs(fromEditableText: text)
    }

    private var protectedInputs: [TerminalShortcutProtectedInput] {
        decodedProtectedInputs ?? []
    }

    private var selectedProtectedInput: TerminalShortcutProtectedInput? {
        if let selectedPasswordID,
           let selected = protectedInputs.first(where: { $0.id == selectedPasswordID }) {
            return selected
        }
        return protectedInputs.first
    }

    private func passwordLabel(for input: TerminalShortcutProtectedInput) -> String {
        let name = input.usesDefaultAccount
            ? L10n.format("shortcut.password.default_name", input.eventIndex + 1)
            : input.account
        return L10n.format("shortcut.password.item", input.shortcutTitle, name)
    }

    private func syncSelectedPassword() {
        guard let first = protectedInputs.first else {
            selectedPasswordID = nil
            passwordText = ""
            passwordMessage = ""
            return
        }
        if let selectedPasswordID,
           protectedInputs.contains(where: { $0.id == selectedPasswordID }) {
            return
        }
        selectedPasswordID = first.id
        passwordText = ""
        refreshPasswordMessage()
    }

    private func refreshPasswordMessage() {
        guard let input = selectedProtectedInput else {
            passwordMessage = ""
            return
        }
        passwordMessage = TerminalShortcutStore.protectedInputHasValue(account: input.account)
            ? L10n.string("shortcut.password.stored")
            : L10n.string("shortcut.password.not_stored")
    }

    private func saveSelectedPassword() {
        guard let input = selectedProtectedInput else { return }
        guard !passwordText.isEmpty else {
            passwordMessage = L10n.string("shortcut.password.empty_value")
            return
        }
        if TerminalShortcutStore.saveProtectedInput(passwordText, account: input.account, appendingReturn: appendReturnToPassword) {
            passwordText = ""
            passwordMessage = L10n.format("shortcut.password.saved", passwordLabel(for: input))
        }
    }

    private func clearSelectedPassword() {
        guard let input = selectedProtectedInput else { return }
        TerminalShortcutStore.deleteProtectedInput(account: input.account)
        passwordText = ""
        passwordMessage = L10n.format("shortcut.password.cleared", passwordLabel(for: input))
    }
}
