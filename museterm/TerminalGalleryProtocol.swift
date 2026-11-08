import Foundation

/// The private OSC 7771 conversation that drives the narrow image column beside a terminal.
///
/// A program announces itself with `hello` and then describes its attachments with `list`.
/// The terminal answers a paste with `drop` and a click on the delete icon with `delete`, both
/// written as ordinary input, never as an emulator reply. Frames carrying pixels are split so
/// each one stays inside a single runtime input write.
enum TerminalGalleryProtocol {
    static let oscCode = 7771
    static let version = 1
    static let maximumImages = 12
    /// Decoded pixels. The peer stores the image inside a JSON document capped near 10 MiB, so
    /// the decoded ceiling leaves room for the base64 expansion and the rest of that document.
    static let maximumImageBytes = 8 * 1_024 * 1_024
    /// One outgoing frame, including its OSC wrapper. Runtime input accepts 65,536 bytes, and
    /// 131,072 bytes may be waiting in total, so two frames of this size always fit together.
    static let maximumFrameBytes = 60_000
    /// A frame that arrives without its terminator after this long is discarded, so a cut-off
    /// paste cannot sit in the buffer forever.
    static let incompleteFrameLifetime: TimeInterval = 5

    enum Operation: String {
        case hello
        case bye
        case list
        case ack
        case reject
        case remove
        case blob
        case drop
        case delete
    }

    struct Frame: Equatable {
        let operation: Operation
        let fields: ArraySlice<Substring>
    }

    /// One attachment as the peer describes it. Pixel data travels separately, in `blob` frames.
    struct ListedImage: Equatable {
        let id: String
        let name: String
        let mutable: Bool
    }

    struct Outgoing {
        let frames: [[UInt8]]
        /// The text the input path records and checks. It carries no image bytes.
        let validationText: String
    }

    static func parse(_ payload: [UInt8]) -> Frame? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3,
              fields[0] == "v=\(version)",
              let operation = Operation(rawValue: String(fields[1])) else { return nil }
        return Frame(operation: operation, fields: fields.dropFirst(2))
    }

    static func listedImages(in frame: Frame) -> [ListedImage]? {
        guard frame.operation == .list, let json = frame.fields.first,
              let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        guard rows.count <= maximumImages else { return nil }
        var images: [ListedImage] = []
        var seen: Set<String> = []
        for row in rows {
            guard let id = row["id"] as? String, isIdentifier(id), seen.insert(id).inserted,
                  let name = row["name"] as? String, !name.isEmpty, name.count <= 255,
                  name.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }),
                  let mutable = row["mutable"] as? Bool else { return nil }
            images.append(ListedImage(id: id, name: name, mutable: mutable))
        }
        return images
    }

    /// `true` when the value can be placed in a frame without splitting a field.
    static func isIdentifier(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return (1...64).contains(scalars.count)
            && scalars.allSatisfy { scalar in
                (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "z")
                    || (scalar >= "A" && scalar <= "Z") || scalar == "-"
            }
    }

    static func drop(nonce: String, png: Data) -> Outgoing? {
        guard isIdentifier(nonce), !png.isEmpty, png.count <= maximumImageBytes else { return nil }
        return frames(operation: .drop, lead: nonce, payload: png)
    }

    static func delete(id: String) -> Outgoing? {
        guard isIdentifier(id) else { return nil }
        return frames(operation: .delete, lead: id, payload: Data())
    }

    private static func frames(operation: Operation, lead: String, payload: Data) -> Outgoing? {
        let prefix = Data("\u{1b}]\(oscCode);v=\(version);\(operation.rawValue);\(lead);".utf8)
        // BEL, not ST. A base64 payload can contain the byte 0x5c, so an ESC ST terminator can
        // be forged by the payload itself and cut the frame short.
        let suffix = Data([0x07])
        let budget = maximumFrameBytes - prefix.count - suffix.count
        guard budget > 32 else { return nil }
        let encoded = payload.base64EncodedString()
        let pieceBudget = budget - 24
        guard pieceBudget > 0 else { return nil }
        let pieceCount = max(1, (encoded.utf8.count + pieceBudget - 1) / pieceBudget)
        guard pieceCount < 1000 else { return nil }
        var frames: [[UInt8]] = []
        var cursor = encoded.startIndex
        for index in 0..<pieceCount {
            let end = encoded.index(cursor, offsetBy: pieceBudget, limitedBy: encoded.endIndex) ?? encoded.endIndex
            let piece = encoded[cursor..<end]
            cursor = end
            var frame = Data()
            frame.append(prefix)
            frame.append(Data("\(index);\(pieceCount);\(piece)".utf8))
            frame.append(suffix)
            guard frame.count <= maximumFrameBytes else { return nil }
            frames.append(Array(frame))
        }
        guard cursor == encoded.endIndex else { return nil }
        return Outgoing(frames: frames, validationText: "\u{1b}]\(oscCode);\(operation.rawValue);\(lead)")
    }
}

/// Reassembles the base64 pieces of one paste.
struct TerminalGalleryTransfer: Equatable {
    let nonce: String
    let total: Int
    private var pieces: [Int: String] = [:]

    init(nonce: String, total: Int) {
        self.nonce = nonce
        self.total = total
    }

    var isComplete: Bool { pieces.count == total }

    mutating func add(index: Int, piece: String) -> Bool {
        guard (0..<total).contains(index), pieces[index] == nil,
              piece.utf8.allSatisfy({ $0 != 0x3b && $0 >= 0x20 }) else { return false }
        pieces[index] = piece
        return true
    }

    func data() -> Data? {
        guard isComplete else { return nil }
        return Data(base64Encoded: (0..<total).compactMap { pieces[$0] }.joined(),
                    options: .ignoreUnknownCharacters)
    }
}

/// Pulls whole OSC 7771 frames out of a byte stream and hands back everything else untouched.
struct TerminalGalleryFramer {
    private static let start = Array("\u{1b}]7771;".utf8)
    private static let stringTerminator = Array("\u{1b}\\".utf8)
    private var pending: [UInt8] = []
    private var pendingSince: TimeInterval?

    mutating func push(_ bytes: ArraySlice<UInt8>, now: TimeInterval) -> (plain: [UInt8], frames: [[UInt8]]) {
        if let pendingSince, now - pendingSince > TerminalGalleryProtocol.incompleteFrameLifetime {
            pending.removeAll()
            self.pendingSince = nil
        }
        pending.append(contentsOf: bytes)
        var plain: [UInt8] = []
        var frames: [[UInt8]] = []
        while !pending.isEmpty {
            guard let start = indexOfStart() else {
                let keep = retainedSuffixCount()
                if keep < pending.count {
                    plain.append(contentsOf: pending.prefix(pending.count - keep))
                    pending.removeFirst(pending.count - keep)
                }
                // A short prefix of the marker is not a frame, so the incomplete-frame timeout
                // must not discard it. The next read either completes the marker or releases it.
                pendingSince = nil
                break
            }
            if start > 0 {
                plain.append(contentsOf: pending.prefix(start))
                pending.removeFirst(start)
            }
            guard let end = indexOfTerminator() else {
                pendingSince = pendingSince ?? now
                break
            }
            let frame = Array(pending.prefix(end))
            pending.removeFirst(end)
            pendingSince = nil
            if frame.count <= TerminalGalleryProtocol.maximumFrameBytes * 2 {
                frames.append(frame)
            }
        }
        return (plain, frames)
    }

    /// How many trailing bytes are the start of `ESC ]7771;` and must wait for the next read.
    /// Any other tail, including a different escape, belongs on screen now.
    private func retainedSuffixCount() -> Int {
        let limit = min(pending.count, Self.start.count - 1)
        guard limit > 0 else { return 0 }
        for length in stride(from: limit, through: 1, by: -1) {
            if pending.suffix(length).elementsEqual(Self.start.prefix(length)) {
                return length
            }
        }
        return 0
    }

    private func indexOfStart() -> Int? {
        guard pending.count >= Self.start.count else { return nil }
        for index in 0...(pending.count - Self.start.count) {
            if pending[index..<(index + Self.start.count)].elementsEqual(Self.start) { return index }
        }
        return nil
    }

    private func indexOfTerminator() -> Int? {
        let candidates = [
            (Self.stringTerminator, Self.stringTerminator.count),
            ([0x07], 1)
        ]
        var found: Int?
        for (marker, length) in candidates {
            guard pending.count >= length else { continue }
            for index in 0...(pending.count - length) where pending[index..<(index + length)].elementsEqual(marker) {
                found = min(found ?? index + length, index + length)
                break
            }
        }
        return found
    }
}
