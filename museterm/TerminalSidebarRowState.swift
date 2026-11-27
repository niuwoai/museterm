import Combine
import Foundation

/// The row observes only the values it displays. Output, command history, and
/// runtime metadata continue to publish on TerminalSession for their consumers.
final class TerminalSidebarRowState: ObservableObject {
    struct Labels: Equatable {
        let title: String
        let subtitle: String?
    }

    struct Value: Equatable {
        var labels: Labels
        var shellName: String?
        var agent: TerminalAgentBadge.Presentation?
        var isRunning: Bool
        var hasUnreadAttention: Bool
        var hasActiveTunnel: Bool
        var isAIControlled: Bool
    }

    let id: UUID
    let environment: TerminalEnvironmentKind
    @Published private(set) var value: Value

    init(id: UUID, environment: TerminalEnvironmentKind, value: Value) {
        self.id = id
        self.environment = environment
        self.value = value
    }

    func update<Field: Equatable>(_ keyPath: WritableKeyPath<Value, Field>, to newValue: Field) {
        guard value[keyPath: keyPath] != newValue else { return }
        value[keyPath: keyPath] = newValue
    }
}
