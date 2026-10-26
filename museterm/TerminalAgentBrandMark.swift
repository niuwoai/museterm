import AppKit
import SwiftUI

nonisolated enum TerminalAgentBrand: String, CaseIterable {
    case codex, claude, willdeep

    init?(identifier: String) {
        switch identifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "codex", "codex cli": self = .codex
        case "claude", "claude code", "claude-code": self = .claude
        case "willdeep", "willdeep-cli", "willdeep cli": self = .willdeep
        default: return nil
        }
    }

    var assetName: String {
        switch self {
        case .codex: "AgentBrandCodex"
        case .claude: "AgentBrandClaude"
        case .willdeep: "AboutAppWillDeepIcon"
        }
    }

    @MainActor var name: String { L10n.string("agent.kind.\(rawValue)") }
}

nonisolated enum TerminalAgentSurface {
    case cli, desktop
    @MainActor var label: String { L10n.string(self == .cli ? "agent.surface.cli" : "agent.surface.desktop") }
}

/// Product marks stay recognizable; the terminal carrier identifies a CLI.
/// Desktop presentation uses the same product mark without that carrier.
struct TerminalAgentBrandMark: View {
    let identifier: String
    var surface: TerminalAgentSurface = .cli
    var size: CGFloat = 16

    private var brand: TerminalAgentBrand? { .init(identifier: identifier) }
    private var image: NSImage? { brand.flatMap { NSImage(named: $0.assetName) } }
    var hasLogo: Bool { image != nil }

    var body: some View {
        if let image {
            if surface == .cli {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 5, weight: .bold))
                        .foregroundStyle(.secondary)
                    logo(image)
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12), lineWidth: 0.75) }
                .fixedSize()
            } else {
                logo(image)
            }
        } else {
            Text(brand?.name ?? identifier)
                .font(.caption2.weight(.medium)).lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func logo(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .renderingMode(brand == .codex ? .template : .original)
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.primary)
    }
}
