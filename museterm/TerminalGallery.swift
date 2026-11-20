import AppKit
import Combine
import Foundation

/// One thumbnail in the column beside a terminal, plus the full image behind it.
struct TerminalGalleryItem: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case ready
        case rejected(String)
    }

    let id: String
    var name: String
    var mutable: Bool
    var state: State
    var image: NSImage?

    var canDelete: Bool {
        if case .rejected = state { return true }
        return mutable && state == .ready
    }

    var rejectionReason: String? {
        if case .rejected(let reason) = state { return reason }
        return nil
    }
}

/// What one terminal tab is showing in its image column.
///
/// The column exists only while the program inside the tab has said hello and still has images.
/// A tab that never speaks the protocol keeps the whole width for the character terminal.
@MainActor
final class TerminalGalleryState: ObservableObject {
    @Published private(set) var joined = false
    @Published private(set) var items: [TerminalGalleryItem] = []
    @Published private(set) var pasteFailure: TerminalGalleryPasteFailure?
    private(set) var connectionEpoch = UUID()
    private var transfers: [String: TerminalGalleryTransfer] = [:]

    var isVisible: Bool { joined && !items.isEmpty }

    func reset() {
        connectionEpoch = UUID()
        joined = false
        items = []
        transfers = [:]
        pasteFailure = nil
    }

    func notePasteFailure(_ failure: TerminalGalleryPasteFailure) {
        pasteFailure = failure
    }

    func clearPasteFailure() {
        pasteFailure = nil
    }

    /// Applies one frame the program wrote. Unknown or malformed frames change nothing.
    func receive(_ payload: [UInt8]) {
        guard let frame = TerminalGalleryProtocol.parse(payload) else { return }
        switch frame.operation {
        case .hello:
            connectionEpoch = UUID()
            joined = true
            pasteFailure = nil
        case .bye:
            reset()
        case .list:
            guard let listed = TerminalGalleryProtocol.listedImages(in: frame) else { return }
            apply(listed)
        case .ack:
            guard let nonce = frame.fields.first.map(String.init) else { return }
            settle(nonce, acceptedAs: frame.fields.dropFirst().first.map(String.init))
        case .reject:
            guard let nonce = frame.fields.first.map(String.init) else { return }
            markRejected(nonce, reason: frame.fields.dropFirst().first.map(String.init) ?? "")
        case .remove:
            guard let id = frame.fields.first.map(String.init) else { return }
            items.removeAll { $0.id == id }
        case .blob:
            receiveBlob(frame)
        case .drop, .delete:
            break
        }
    }

    /// Shows a paste immediately, before the program has acknowledged it.
    @discardableResult
    func stagePaste(nonce: String, image: NSImage) -> Bool {
        guard joined, items.count < TerminalGalleryProtocol.maximumImages,
              !items.contains(where: { $0.id == nonce }) else { return false }
        items.append(TerminalGalleryItem(id: nonce, name: "", mutable: false,
                                          state: .pending, image: image))
        return true
    }

    func discardPendingPaste(nonce: String) {
        items.removeAll { $0.id == nonce && $0.state == .pending }
    }

    func item(_ id: String) -> TerminalGalleryItem? {
        items.first { $0.id == id }
    }

    private func apply(_ listed: [TerminalGalleryProtocol.ListedImage]) {
        let pending = items.filter {
            if case .pending = $0.state { return true }
            if case .rejected = $0.state { return true }
            return false
        }
        var merged: [TerminalGalleryItem] = listed.map { entry in
            let existing = items.first { $0.id == entry.id }
            return TerminalGalleryItem(id: entry.id, name: entry.name, mutable: entry.mutable,
                                        state: .ready, image: existing?.image)
        }
        for item in pending where !merged.contains(where: { $0.id == item.id }) {
            merged.append(item)
        }
        items = merged
    }

    private func settle(_ nonce: String, acceptedAs id: String?) {
        guard let index = items.firstIndex(where: { $0.id == nonce }),
              case .pending = items[index].state else { return }
        let image = items[index].image
        items.remove(at: index)
        if let id, let target = items.firstIndex(where: { $0.id == id }) {
            items[target].image = items[target].image ?? image
        }
    }

    private func markRejected(_ nonce: String, reason: String) {
        guard let index = items.firstIndex(where: { $0.id == nonce }) else { return }
        items[index].state = .rejected(reason)
        items[index].mutable = false
    }

    private func receiveBlob(_ frame: TerminalGalleryProtocol.Frame) {
        guard frame.fields.count >= 4,
              let id = frame.fields.first.map(String.init),
              TerminalGalleryProtocol.isIdentifier(id),
              let index = Int(frame.fields.dropFirst(1).first ?? ""),
              let total = Int(frame.fields.dropFirst(2).first ?? ""),
              (1...999).contains(total),
              let piece = frame.fields.dropFirst(3).first.map(String.init) else { return }
        var transfer = transfers[id] ?? TerminalGalleryTransfer(nonce: id, total: total)
        guard transfer.total == total, transfer.add(index: index, piece: piece) else {
            transfers[id] = nil
            return
        }
        guard transfer.isComplete, let data = transfer.data(),
              data.count <= TerminalGalleryProtocol.maximumImageBytes,
              let image = NSImage(data: data) else {
            transfers[id] = transfer
            return
        }
        transfers[id] = nil
        if let target = items.firstIndex(where: { $0.id == id }) {
            items[target].image = image
        }
    }
}

/// Reads the pictures on the pasteboard. Text is deliberately not read here: the terminal's own
/// paste path still owns it.
enum TerminalGalleryPasteboard {
    static let maximumSourceBytes = 20 * 1_024 * 1_024

    static func hasImageCandidate() -> Bool {
        NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
    }

    static func readPNGImage() -> Result<(png: Data, image: NSImage), TerminalGalleryPasteFailure> {
        let pasteboard = NSPasteboard.general
        guard let type = pasteboard.availableType(from: [.png, .tiff]) else {
            return .failure(.unsupportedFormat)
        }
        guard let source = pasteboard.data(forType: type) else {
            return .failure(.unsupportedFormat)
        }
        guard source.count <= maximumSourceBytes else { return .failure(.pasteboardTooLarge) }
        guard let image = NSImage(data: source) else { return .failure(.unsupportedFormat) }
        let png = type == .png ? source : pngData(from: image)
        guard let png else { return .failure(.unsupportedFormat) }
        guard png.count <= TerminalGalleryProtocol.maximumImageBytes else { return .failure(.imageTooLarge) }
        return .success((png, image))
    }

    static func pngImage() -> (png: Data, image: NSImage)? {
        switch readPNGImage() {
        case .success(let value): return value
        case .failure: return nil
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}
