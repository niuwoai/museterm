import AppKit
import Foundation

enum AppIconChoice: String, CaseIterable, Identifiable {
    case defaultTerminal
    case cat
    case fox
    case panda
    case owl
    case dog

    var id: String { rawValue }

    var assetName: String {
        switch self {
        case .defaultTerminal: return "AppIconDefaultPreview"
        case .cat: return "AppIconCat"
        case .fox: return "AppIconFox"
        case .panda: return "AppIconPanda"
        case .owl: return "AppIconOwl"
        case .dog: return "AppIconDog"
        }
    }

    var name: String {
        L10n.string("app_icon.\(rawValue).name")
    }

    var summary: String {
        L10n.string("app_icon.\(rawValue).summary")
    }

    var nsImage: NSImage? {
        NSImage(named: assetName)
    }
}

enum AppIconManager {
    static func apply(_ choice: AppIconChoice) {
        guard let image = choice.nsImage?.copy() as? NSImage else { return }
        NSApplication.shared.applicationIconImage = image
    }
}
