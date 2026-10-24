import SwiftUI

struct TerminalRuntimeIssueView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let issue = session.runtimeConnectionIssue {
            VStack {
                HStack(spacing: 10) {
                    Text(L10n.string("runtime.issue.\(issue.rawValue)"))
                    Spacer()
                    if [.outputGap, .inputRejected, .inputTooLarge].contains(issue) {
                        Button(L10n.string("runtime.dismiss")) { session.runtimeConnectionIssue = nil }
                    } else if issue == .disconnected {
                        Button(L10n.string("runtime.reconnect")) { session.controller.reconnectRuntime() }
                    } else { ProgressView().controlSize(.small) }
                }
                .font(.caption).padding(10).background(.regularMaterial)
                Spacer()
            }
        }
    }
}
