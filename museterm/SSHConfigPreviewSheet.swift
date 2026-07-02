import AppKit
import SwiftUI

struct SSHConfigPreviewSheet: View {
    let profile: SSHConnectionProfile
    let skin: TerminalVisualSkin
    let onClose: () -> Void
    @State private var message = ""

    private var preview: SSHConfigPreview {
        SSHConfigMaterializer.preview(for: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summary
            configBody
            footer
        }
        .padding(18)
        .frame(width: 720, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(skin.accent)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("ssh.config_preview.title"))
                    .font(.headline)
                Text(profile.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(L10n.string("ssh.config_preview.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            EnvironmentBadge(environment: profile.environment)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            previewChip(
                title: L10n.string("ssh.config_preview.target_alias"),
                value: preview.targetAlias,
                systemImage: "scope"
            )
            previewChip(
                title: L10n.string("ssh.config_preview.host_blocks"),
                value: "\(preview.hostBlockCount)",
                systemImage: "list.bullet.rectangle"
            )
            previewChip(
                title: L10n.string("ssh.config_preview.lines"),
                value: "\(preview.lineCount)",
                systemImage: "number"
            )
        }
    }

    private func previewChip(title: String, value: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(skin.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var configBody: some View {
        ScrollView {
            Text(preview.config)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.black.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var footer: some View {
        HStack {
            if !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(preview.config, forType: .string)
                message = L10n.string("ssh.config_preview.copied")
            } label: {
                Label(L10n.string("ssh.config_preview.copy"), systemImage: "doc.on.doc")
            }
            Button(L10n.string("action.close"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.bordered)
    }
}
