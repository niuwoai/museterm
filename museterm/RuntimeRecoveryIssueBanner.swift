import SwiftUI

struct RuntimeRecoveryIssueBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("runtime.workspace.recovery_issue.title"))
                .font(.caption.weight(.semibold))
            Text(L10n.string("runtime.workspace.recovery_issue.detail"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 8)
                Button(L10n.string("runtime.dismiss"), action: onDismiss)
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
