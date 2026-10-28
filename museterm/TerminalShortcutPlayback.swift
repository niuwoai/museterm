import Foundation
import LocalAuthentication

// 录制捷径的回放门禁。界面点击和命令面板是本人操作；
// MCP、CLI 与 AppleScript 是自动化。两者都要尊重「播放前验证本人」；
// 只有自动化会额外被「允许 AI 回放」拦下。

nonisolated enum TerminalShortcutAutomationDenial: Equatable, Sendable {
    case notPlayable
    case protectedInput
    case automationDisabled
}

nonisolated enum TerminalShortcutPlaybackOrigin: Equatable, Sendable {
    case user
    case automation
}

nonisolated enum TerminalShortcutPlaybackDecision: Equatable, Sendable {
    case play
    case authenticate
    case deny(TerminalShortcutAutomationDenial)
}

nonisolated enum TerminalShortcutPlaybackError: Error, Equatable, Sendable, LocalizedError {
    case notPlayable
    case protectedInput
    case automationDisabled
    case authenticationCancelled
    case authenticationFailed
    case authenticationUnavailable
    case authenticationBusy
    case authenticationTimedOut

    init(_ denial: TerminalShortcutAutomationDenial) {
        switch denial {
        case .notPlayable: self = .notPlayable
        case .protectedInput: self = .protectedInput
        case .automationDisabled: self = .automationDisabled
        }
    }

    var scriptErrorCode: Int {
        switch self {
        case .protectedInput, .notPlayable:
            return MuseTermScriptErrorCode.shortcutProtected
        case .automationDisabled:
            return MuseTermScriptErrorCode.shortcutAutomationDisabled
        case .authenticationCancelled, .authenticationFailed, .authenticationUnavailable,
             .authenticationBusy, .authenticationTimedOut:
            return MuseTermScriptErrorCode.shortcutAuthenticationFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return L10n.string("shortcut.auth.error.not_playable")
        case .protectedInput:
            return L10n.string("applescript.error.shortcut_protected")
        case .automationDisabled:
            return L10n.string("applescript.error.shortcut_automation_disabled")
        case .authenticationCancelled:
            return L10n.string("shortcut.auth.error.cancelled")
        case .authenticationFailed:
            return L10n.string("shortcut.auth.error.failed")
        case .authenticationUnavailable:
            return L10n.string("shortcut.auth.error.unavailable")
        case .authenticationBusy:
            return L10n.string("shortcut.auth.error.busy")
        case .authenticationTimedOut:
            return L10n.string("shortcut.auth.error.timed_out")
        }
    }
}

nonisolated protocol TerminalUserAuthenticating: AnyObject {
    func authenticate(
        localizedReason: String,
        invalidateAfter: TimeInterval?,
        completion: @escaping @Sendable (Result<Void, TerminalShortcutPlaybackError>) -> Void
    )
}

nonisolated enum TerminalShortcutPlayback {
    static var authenticator: TerminalUserAuthenticating = TerminalTouchIDAuthenticator()

    static func decision(
        for shortcut: TerminalShortcut,
        origin: TerminalShortcutPlaybackOrigin
    ) -> TerminalShortcutPlaybackDecision {
        switch origin {
        case .automation:
            if let denial = MuseTermScriptingPolicy.automationDenial(shortcut) {
                return .deny(denial)
            }
        case .user:
            guard shortcut.isPlayable else { return .deny(.notPlayable) }
        }
        return shortcut.requiresUserAuthentication ? .authenticate : .play
    }

    static func begin(
        shortcut: TerminalShortcut,
        origin: TerminalShortcutPlaybackOrigin,
        invalidateAfter: TimeInterval?,
        completion: @escaping (Result<Void, TerminalShortcutPlaybackError>) -> Void
    ) {
        switch decision(for: shortcut, origin: origin) {
        case .play:
            completion(.success(()))
        case .deny(let denial):
            completion(.failure(TerminalShortcutPlaybackError(denial)))
        case .authenticate:
            let reason = L10n.format("shortcut.auth.reason", shortcut.title)
            authenticator.authenticate(localizedReason: reason, invalidateAfter: invalidateAfter) { result in
                completion(result)
            }
        }
    }
}

/// 优先走 Touch ID。这台 Mac 没有可用指纹、指纹被锁定，或用户点了「使用密码」时，
/// 改为系统登录密码。取消、失败或超时都不算通过。
nonisolated final class TerminalTouchIDAuthenticator: TerminalUserAuthenticating {
    private let gate = NSLock()
    private var inFlight = false

    func authenticate(
        localizedReason: String,
        invalidateAfter: TimeInterval?,
        completion: @escaping @Sendable (Result<Void, TerminalShortcutPlaybackError>) -> Void
    ) {
        gate.lock()
        if inFlight {
            gate.unlock()
            DispatchQueue.main.async { completion(.failure(.authenticationBusy)) }
            return
        }
        inFlight = true
        gate.unlock()

        let attempt = ShortcutAuthAttempt()
        if let invalidateAfter, invalidateAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + invalidateAfter) {
                attempt.markTimedOutAndInvalidate()
            }
        }
        evaluate(
            preferBiometrics: true,
            reason: localizedReason,
            attempt: attempt,
            completion: completion
        )
    }

    private func evaluate(
        preferBiometrics: Bool,
        reason: String,
        attempt: ShortcutAuthAttempt,
        completion: @escaping @Sendable (Result<Void, TerminalShortcutPlaybackError>) -> Void
    ) {
        let context = LAContext()
        var policyError: NSError?
        let policy: LAPolicy
        if preferBiometrics,
           context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) {
            policy = .deviceOwnerAuthenticationWithBiometrics
            context.localizedFallbackTitle = L10n.string("shortcut.auth.use_password")
        } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) {
            policy = .deviceOwnerAuthentication
        } else {
            deliver(.failure(.authenticationUnavailable), attempt: attempt, completion: completion)
            return
        }
        attempt.adopt(context)
        context.evaluatePolicy(policy, localizedReason: reason) { success, error in
            if attempt.consumeTimedOut() {
                self.deliver(.failure(.authenticationTimedOut), attempt: attempt, completion: completion)
                return
            }
            if success {
                self.deliver(.success(()), attempt: attempt, completion: completion)
                return
            }
            let code = (error as NSError?)?.code
            let canFallBack = preferBiometrics && Self.shouldOfferPassword(code)
            if canFallBack {
                self.evaluate(preferBiometrics: false, reason: reason, attempt: attempt, completion: completion)
                return
            }
            if code == LAError.userCancel.rawValue
                || code == LAError.appCancel.rawValue
                || code == LAError.systemCancel.rawValue {
                self.deliver(.failure(.authenticationCancelled), attempt: attempt, completion: completion)
                return
            }
            self.deliver(.failure(.authenticationFailed), attempt: attempt, completion: completion)
        }
    }

    private static func shouldOfferPassword(_ code: Int?) -> Bool {
        code == LAError.userFallback.rawValue
            || code == LAError.biometryLockout.rawValue
            || code == LAError.biometryNotAvailable.rawValue
            || code == LAError.biometryNotEnrolled.rawValue
    }

    private func deliver(
        _ result: Result<Void, TerminalShortcutPlaybackError>,
        attempt: ShortcutAuthAttempt,
        completion: @escaping @Sendable (Result<Void, TerminalShortcutPlaybackError>) -> Void
    ) {
        guard attempt.finishOnce() else { return }
        gate.lock()
        inFlight = false
        gate.unlock()
        DispatchQueue.main.async { completion(result) }
    }
}

/// 给主线程上的工具桥等一个已经派回主线程的回放结果。
/// 先应答再等，避免指纹弹窗挡住主线程时结果永远写不回来。
final class TerminalShortcutAutomationReply: @unchecked Sendable {
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var result: Result<TerminalToolResponse, TerminalShortcutPlaybackError>?
    private var delivered = false

    func finish(_ result: Result<TerminalToolResponse, TerminalShortcutPlaybackError>) {
        lock.lock()
        if delivered {
            lock.unlock()
            return
        }
        delivered = true
        self.result = result
        lock.unlock()
        arrived.signal()
    }

    func await(seconds: TimeInterval) -> Result<TerminalToolResponse, TerminalShortcutPlaybackError> {
        let wait = max(1, seconds)
        guard arrived.wait(timeout: .now() + wait) == .success else {
            return .failure(.authenticationTimedOut)
        }
        lock.lock()
        let result = self.result ?? .failure(.authenticationTimedOut)
        lock.unlock()
        return result
    }
}

private final class ShortcutAuthAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var context: LAContext?
    private var timedOut = false
    private var finished = false

    func adopt(_ context: LAContext) {
        lock.lock()
        self.context = context
        let alreadyTimedOut = timedOut
        lock.unlock()
        if alreadyTimedOut {
            context.invalidate()
        }
    }

    func markTimedOutAndInvalidate() {
        lock.lock()
        timedOut = true
        let context = self.context
        lock.unlock()
        context?.invalidate()
    }

    func consumeTimedOut() -> Bool {
        lock.lock()
        let value = timedOut
        lock.unlock()
        return value
    }

    func finishOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}
