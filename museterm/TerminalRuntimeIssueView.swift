import SwiftUI

struct TerminalRuntimeIssueView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let issue = session.runtimeConnectionIssue ?? (session.runtimeSessionWasReopened ? .sessionReopened : nil) {
            HStack(spacing: 10) {
                Text(L10n.string("runtime.issue.\(issue.rawValue)"))
                Spacer()
                if [.outputGap, .inputRejected, .inputTooLarge, .sessionReopened].contains(issue) {
                    Button(L10n.string("runtime.dismiss")) {
                        if issue == .sessionReopened { session.runtimeSessionWasReopened = false }
                        else { session.runtimeConnectionIssue = nil }
                    }
                } else if issue == .sessionEnded {
                    Button(L10n.string("runtime.new_local_terminal")) { session.onNewLocalTerminal?() }
                        .disabled(session.onNewLocalTerminal == nil)
                } else if issue == .disconnected {
                    Button(L10n.string("runtime.reconnect")) { session.controller.reconnectRuntime() }
                } else { ProgressView().controlSize(.small) }
            }
            .font(.caption).padding(10).background(.regularMaterial)
        }
    }
}
