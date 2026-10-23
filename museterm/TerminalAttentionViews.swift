import AppKit
import SwiftUI

struct TerminalAttentionEntry: View {
    @ObservedObject var store: TerminalAttentionStore
    let workspace: TerminalWorkspace
    let compact: Bool
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label(L10n.format("attention.entry", store.activeItems.count), systemImage: "tray.full")
                .labelStyle(AttentionEntryStyle(compact: compact))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-attention-entry")
        .accessibilityLabel(L10n.format("attention.entry", store.activeItems.count))
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("attention.title")).font(.headline)
                if store.activeItems.isEmpty { Text(L10n.string("attention.empty")).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.activeItems) { item in
                            Button {
                                workspace.focusAttention(tabID: item.tabID, itemID: item.id, version: item.version)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.string("attention.kind.\(item.kind.rawValue)"))
                                        .font(.subheadline.weight(item.readAt == nil ? .bold : .regular))
                                    Text(workspace.sessionRegistry.sessions[item.tabID]?.tabTitle ?? L10n.string("attention.closed"))
                                        .font(.caption).lineLimit(1)
                                    Text(item.createdAt, style: .relative).font(.caption2)
                                    if let count = item.terminal?.occurrences, count > 1 {
                                        Text(L10n.format("attention.occurrences", count)).font(.caption2)
                                    }
                                    if item.isStale { Text(L10n.string("attention.stale")).font(.caption2) }
                                    if item.readAt != nil && item.kind.requiresAnswer { Text(L10n.string("attention.read_pending")).font(.caption2) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("attention-item-\(item.id)")
                        }
                    }
                }
                .frame(height: min(380, CGFloat(max(1, store.activeItems.count)) * 132))
            }.padding(16).frame(width: 320)
        }
    }
}

private struct AttentionEntryStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack { configuration.icon; if !compact { configuration.title } }
    }
}

extension TerminalWorkspace {
    @discardableResult
    func focusAttention(tabID: UUID, itemID: UUID? = nil, version: Int? = nil) -> Bool {
        guard let session = sessionRegistry.sessions[tabID] else { return false }
        if let itemID, let version {
            // A notification for an older version must not acknowledge a newer question.
            try? sessionRegistry.attention.markRead(id: itemID, version: version)
        } else { sessionRegistry.attention.markViewed(tabID: tabID) }
        if !DetachedTerminalPanelManager.shared.focus(tabID) {
            suppressAttentionAutoRead = itemID != nil
            defer { suppressAttentionAutoRead = false }
            selectedID = tabID
            session.controller.container.window?.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }
}
