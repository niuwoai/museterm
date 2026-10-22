import SwiftUI

struct TerminalAgentBadge: View {
    let status: TerminalAgentSnapshot
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if !compact { Text(status.label).lineLimit(1) }
        }
        .font(.caption2)
        .foregroundStyle(color)
        .help(status.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.detail)
        .accessibilityIdentifier("agent-state-\(status.instanceID)")
    }

    private var symbol: String {
        switch status.activity {
        case .unknown: return "questionmark.circle"
        case .working: return "gearshape.2"
        case .idle: return "pause.circle"
        case .blocked: return "hand.raised.fill"
        case .exited: return "stop.circle"
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
