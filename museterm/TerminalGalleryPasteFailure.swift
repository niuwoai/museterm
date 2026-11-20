import Foundation

/// Why a clipboard image could not enter the gallery column for this tab.
enum TerminalGalleryPasteFailure: Equatable, Error {
    case notJoined
    case unsupportedFormat
    case pasteboardTooLarge
    case imageTooLarge
    case thumbnailLimit
    case protocolEncodeFailed
}

extension TerminalGalleryPasteFailure {
    var localizationKey: String {
        switch self {
        case .notJoined: return "gallery.failure.not_joined"
        case .unsupportedFormat: return "gallery.failure.unsupported_format"
        case .pasteboardTooLarge: return "gallery.failure.pasteboard_too_large"
        case .imageTooLarge: return "gallery.failure.image_too_large"
        case .thumbnailLimit: return "gallery.failure.thumbnail_limit"
        case .protocolEncodeFailed: return "gallery.failure.encode_failed"
        }
    }

    var userMessage: String { L10n.string(localizationKey) }
}

/// Maps a program-side reject token to user-visible text.
enum TerminalGalleryRejectionText {
    static func message(for reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.string("gallery.rejected.generic") }
        let key = "gallery.reject.\(trimmed)"
        let localized = L10n.string(key)
        if localized != key { return localized }
        return L10n.format("gallery.rejected.reason", trimmed)
    }
}
