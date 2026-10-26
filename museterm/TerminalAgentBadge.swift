import SwiftUI

struct TerminalAgentBadge: View {
    let status: TerminalAgentSnapshot
    var compact = false

    var body: some View {
        TerminalAgentBrandMark(identifier: status.kind.rawValue, size: compact ? 13 : 15)
            .saturation(status.activity == .exited ? 0 : 1)
            .opacity(status.activity == .exited ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: status.activity == .exited ? 4 : 5, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 8, height: 8)
                    .background(.background, in: Circle())
                    .offset(x: 3, y: -2)
                    .accessibilityHidden(true)
        }
        .padding(.trailing, 3)
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail)
        .accessibilityIdentifier("agent-state-\(status.instanceID)")
    }

    private var detail: String {
        L10n.format("agent.identity.detail", TerminalAgentSurface.cli.label, status.detail)
    }

    private var symbol: String {
        switch status.activity {
        case .unknown: return "questionmark"
        case .working: return "circle.fill"
        case .idle: return "circle"
        case .blocked: return "exclamationmark"
        case .exited: return "stop.fill"
        }
    }

    private var color: Color {
        switch status.activity {
        case .working: return .blue
        case .blocked: return .orange
        default: return .secondary
        }
    }
}
