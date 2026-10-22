import Foundation

struct TerminalNotificationRoute {
    let tabID: UUID
    let itemID: UUID?
    let version: Int?

    init?(tab: String?, item: String?, version: Int?) {
        guard let tab, let tabID = UUID(uuidString: tab) else { return nil }
        self.tabID = tabID
        if let item {
            guard let id = UUID(uuidString: item), let version, version > 0 else { return nil }
            itemID = id
            self.version = version
        } else {
            guard version == nil else { return nil }
            itemID = nil
            self.version = nil
        }
    }
}
