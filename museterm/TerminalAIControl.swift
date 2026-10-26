import AppKit
import Foundation
import SwiftUI

enum TerminalAIControlError: LocalizedError {
    case owned, retake, busy, inputRejected

    var errorDescription: String? {
        switch self {
        case .owned: return L10n.string("ai_control.error.owned")
        case .retake: return L10n.string("ai_control.error.retake")
        case .busy: return L10n.string("ai_control.error.busy")
        case .inputRejected: return L10n.string("ai_control.error.input_rejected")
        }
    }
}

struct TerminalAILease: Equatable {
    static let duration: TimeInterval = 120
    let owner: String
    var expiresAt: Date
}

/// One private, local JSONL file per takeover. Never stores password-mode input.
final class TerminalAIArchive {
    static var directory: URL {
        TerminalToolPaths.rootDirectory.deletingLastPathComponent()
            .appendingPathComponent("AI Archives", isDirectory: true)
    }

    private let handle: FileHandle
    private var pending: [UInt8] = []
    private var suppressed = false
    private var omittingPrivateKey = false
    private static let maximumPendingBytes = 65_536

    init(tabID: UUID, directory: URL = TerminalAIArchive.directory) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("\(tabID)-\(UUID()).jsonl")
        guard manager.createFile(atPath: file.path, contents: nil,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: file)
        try event("takeover")
    }

    deinit { try? handle.close() }

    func event(_ kind: String, text: String? = nil) throws {
        var record = ["timestamp": ISO8601DateFormatter().string(from: Date()), "event": kind]
        if let text {
            // Omit the whole sensitive line: a token's quoted value can contain
            // spaces that a pattern-based partial replacement cannot safely bound.
            record["input"] = RunbookSensitiveRedactor.containsSensitiveData(text) ? "[REDACTED]" : text
        }
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func record(_ bytes: [UInt8], echoEnabled: Bool) throws {
        guard echoEnabled else {
            pending.removeAll()
            suppressed = !bytes.contains { $0 == 0x0A || $0 == 0x0D }
            try event("hidden_input_omitted")
            return
        }
        for byte in bytes {
            if byte == 0x0A || byte == 0x0D || byte == 0x03 {
                try flush()
            } else if pending.count < Self.maximumPendingBytes && !suppressed {
                pending.append(byte)
            } else {
                pending.removeAll()
                suppressed = true
            }
        }
    }

    func flush() throws {
        let text = String(decoding: pending, as: UTF8.self)
        if text.contains("-----BEGIN ") && text.contains("PRIVATE KEY-----") {
            omittingPrivateKey = true
        }
        if omittingPrivateKey {
            try event("private_key_input_omitted")
            if text.contains("-----END ") && text.contains("PRIVATE KEY-----") {
                omittingPrivateKey = false
            }
        } else if !pending.isEmpty {
            try event("input", text: text)
        }
        if suppressed { try event("input_omitted") }
        pending.removeAll()
        suppressed = false
    }
}

struct TerminalAIControlMask: View {
    @ObservedObject var tab: TerminalSession
    let skin: TerminalVisualSkin
    private let backdropOpacity = 0.04
    private let cardOpacity = 0.55

    var body: some View {
        if tab.aiLease != nil {
            ZStack {
                skin.accent.opacity(backdropOpacity)
                    .contentShape(Rectangle())
                    .onTapGesture { }
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.title)
                    Text(L10n.string("ai_control.locked")).font(.headline)
                    Text(L10n.string("ai_control.description"))
                        .font(.caption).multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    Button {
                        tab.releaseAIControl(reason: "human_unlock")
                    } label: {
                        Label(L10n.string("ai_control.unlock"), systemImage: "lock.open.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(Color(nsColor: skin.terminalBackground).opacity(cardOpacity),
                            in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(skin.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
