import Foundation

/// 侧栏里可以排序、可以隐藏的分区。项目与待处理不在其中：它们始终固定在分区列表上方。
enum SidebarSectionKind: String, CaseIterable, Identifiable, Codable {
    case quickPaths
    case learnedCommands
    case shortcuts
    case fileTransfer
    case profiles
    case sshHosts

    var id: String { rawValue }

    /// 新安装的顺序，也是这个功能上线前侧栏一直用的顺序。
    static let defaultOrder: [SidebarSectionKind] = [
        .quickPaths,
        .learnedCommands,
        .shortcuts,
        .fileTransfer,
        .profiles,
        .sshHosts
    ]

    /// 没有保存过展开状态时的默认值，与这个功能上线前侧栏打开时的样子一致。
    static func defaultExpanded(_ kind: SidebarSectionKind) -> Bool {
        switch kind {
        case .quickPaths, .learnedCommands: return true
        case .shortcuts, .fileTransfer, .profiles, .sshHosts: return false
        }
    }

    var titleKey: String {
        switch self {
        case .quickPaths: return "quick_path.section"
        case .learnedCommands: return "learned_command.section"
        case .shortcuts: return "shortcut.section"
        case .fileTransfer: return "file_transfer.section"
        case .profiles: return "profile.section"
        case .sshHosts: return "ssh.section"
        }
    }

    var systemImage: String {
        switch self {
        case .quickPaths: return "folder"
        case .learnedCommands: return "bolt.fill"
        case .shortcuts: return "record.circle"
        case .fileTransfer: return "arrow.up.arrow.down.square"
        case .profiles: return "person.crop.rectangle.stack"
        case .sshHosts: return "network"
        }
    }

    /// 把存下的顺序补齐：丢掉认不出的值、去掉重复，再把缺的分区按默认顺序追到末尾。
    /// 这样旧版本写下的列表和以后新增的分区都能读出一份完整顺序。
    static func normalizedOrder(_ stored: [String]) -> [SidebarSectionKind] {
        var seen = Set<SidebarSectionKind>()
        var order: [SidebarSectionKind] = []
        for rawValue in stored {
            guard let kind = SidebarSectionKind(rawValue: rawValue), seen.insert(kind).inserted else {
                continue
            }
            order.append(kind)
        }
        for kind in defaultOrder where seen.insert(kind).inserted {
            order.append(kind)
        }
        return order
    }
}
