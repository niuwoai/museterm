import Foundation
import SwiftTerm

/// Serializes preflight, user confirmation, actual write ACK and local recording.
/// Device replies bypass this queue so a modal confirmation cannot deadlock a TUI.
@MainActor
final class TerminalRuntimeInputQueue {
    private struct Pending {
        let id = UUID()
        let bytes: [UInt8]
        let validationBytes: [UInt8]
        let source: TerminalRuntimeInputSource
        let owner: String?
        let generation: UUID
        let controlEpoch: UUID
        let completion: ((Result<Void, Error>) -> Void)?
    }
    private let handle: TerminalRuntimeSessionHandle
    private let approve: ([UInt8], Bool, TerminalRuntimeInputSource, String?) -> Bool
    private let committed: ([UInt8], TerminalRuntimeInputSource, TerminalRuntimeResponse) -> Void
    private let failed: (Error) -> Void
    private var pending: [Pending] = []
    private var pendingBytes = 0
    private var active = false
    private var stopped = false
    private static let maximumRequests = 256

    static func rejectedEnqueueIssue(connected: Bool, byteCount: Int) -> TerminalRuntimePresentationIssue {
        guard connected else { return .disconnected }
        return byteCount > TerminalRuntimeLimits.maximumOutputBytes ? .inputTooLarge : .inputRejected
    }

    init(handle: TerminalRuntimeSessionHandle,
         approve: @escaping ([UInt8], Bool, TerminalRuntimeInputSource, String?) -> Bool,
         committed: @escaping ([UInt8], TerminalRuntimeInputSource, TerminalRuntimeResponse) -> Void,
         failed: @escaping (Error) -> Void) {
        self.handle = handle; self.approve = approve; self.committed = committed; self.failed = failed
    }

    @discardableResult
    func enqueue(_ bytes: [UInt8], source: TerminalRuntimeInputSource, owner: String?, validationBytes: [UInt8]? = nil,
                 completion: ((Result<Void, Error>) -> Void)? = nil) -> Bool {
        guard !stopped, handle.connected, let info = handle.info, info.running,
              !bytes.isEmpty, bytes.count <= TerminalRuntimeLimits.maximumOutputBytes,
              pendingBytes + bytes.count <= TerminalRuntimeLimits.maximumFrameBytes,
              pending.count < Self.maximumRequests, source != .protocolReply else { return false }
        let validation = validationBytes ?? bytes
        guard !validation.isEmpty, validation.count <= bytes.count else { return false }
        guard validation == bytes || (source == .human && bytes ==
            EscapeSequences.bracketedPasteStart + validation + EscapeSequences.bracketedPasteEnd) else { return false }
        pending.append(.init(bytes: bytes, validationBytes: validation, source: source, owner: owner, generation: info.generation,
            controlEpoch: info.controlEpoch, completion: completion))
        pendingBytes += bytes.count
        drain()
        return true
    }

    func cancel() {
        stopped = true
        let abandoned = pending
        pending.removeAll(); pendingBytes = 0; active = false
        for item in abandoned { item.completion?(.failure(TerminalRuntimeConnectionError.cancelled)) }
    }

    private func drain() {
        guard !stopped, !active, let item = pending.first else { return }
        active = true
        handle.prepareInput { [weak self] result in
            guard let self, !self.stopped, self.pending.first?.id == item.id else { return }
            switch result {
            case .failure(let error): self.finish(item, result: .failure(error))
            case .success(let preparation): self.send(item, preparation: preparation)
            }
        }
    }

    private func send(_ item: Pending, preparation: TerminalRuntimeInputPreparation) {
        guard preparation.session.generation == item.generation, preparation.session.controlEpoch == item.controlEpoch,
              approve(item.validationBytes, preparation.echoEnabled, item.source, item.owner) else {
            finish(item, result: .failure(TerminalAIControlError.inputRejected)); return
        }
        // A modal approval can run a nested event loop and cancel/replace us.
        guard !stopped, pending.first?.id == item.id else { return }
        let accepted = handle.sendPrepared(Data(item.bytes), preparation: preparation, source: item.source, owner: item.owner) { [weak self] result in
            guard let self, !self.stopped, self.pending.first?.id == item.id else { return }
            if case .success(let response) = result { self.committed(item.validationBytes, item.source, response) }
            self.finish(item, result: result.map { _ in () })
        }
        if !accepted { finish(item, result: .failure(TerminalAIControlError.inputRejected)) }
    }

    private func finish(_ item: Pending, result: Result<Void, Error>) {
        guard pending.first?.id == item.id else { return }
        pending.removeFirst(); pendingBytes -= item.bytes.count; active = false
        if case .failure(let error) = result { failed(error) }
        item.completion?(result)
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }
}
