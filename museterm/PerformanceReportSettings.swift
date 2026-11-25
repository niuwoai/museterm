import SwiftUI

struct PerformanceReportSettings: View {
    @ObservedObject var preferences: TerminalPreferences
    @ObservedObject private var watchdog = PerformanceWatchdog.shared
    @State private var confirmingDeletion = false
    @State private var deletionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L10n.string("settings.performance_reports"), isOn: $preferences.performanceReportsEnabled)
                .disabled(watchdog.isDeleting)
            Text(L10n.string("settings.performance_reports.help"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.string("settings.performance_reports.delete")) {
                    deletionMessage = nil
                    confirmingDeletion = true
                }
                .disabled(!watchdog.hasInstallID || watchdog.isDeleting)
                if watchdog.isDeleting {
                    ProgressView().controlSize(.small)
                } else if let deletionMessage {
                    Text(L10n.string(deletionMessage)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: preferences.performanceReportsEnabled) { enabled in
            if enabled { deletionMessage = nil }
        }
        .alert(L10n.string("settings.performance_reports.delete"), isPresented: $confirmingDeletion) {
            Button(L10n.string("settings.performance_reports.delete"), role: .destructive, action: deleteReports)
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("settings.performance_reports.delete.help"))
        }
    }

    private func deleteReports() {
        Task {
            do {
                try await watchdog.deleteReports()
                deletionMessage = "settings.performance_reports.delete.success"
            } catch {
                deletionMessage = "settings.performance_reports.delete.failure"
            }
        }
    }
}
