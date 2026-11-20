import Foundation

enum TerminalAgentToolService {
    static let actions: Set<String> = ["bind_agent", "bind_native_agent", "report_agent_state", "get_agent_state", "read_session_events"]

    static func perform(_ request: TerminalToolRequest, registry: TerminalSessionRegistry,
                        snapshotSequence: Int, paired: () -> Bool) -> TerminalToolResponse {
        var response = TerminalToolResponse(id: request.id, ok: true, snapshotSequence: snapshotSequence,
                                           action: request.action, message: nil, error: nil)
        do {
            if request.action == "read_session_events" {
                let cursor = request.eventCursor ?? registry.events.cursor
                response.eventBatch = try registry.events.read(after: cursor, limit: request.eventLimit ?? 100)
                return response
            }
            guard let selector = request.tab, let id = UUID(uuidString: selector),
                  let session = registry.sessions[id] else { throw TerminalAgentReportError.unavailable }
            // Runtime mutation must go through the asynchronous bridge and the
            // service's monitor. Never mint a second UI-only reporting grant.
            if session.runtimeRequiresExisting || session.runtimeInfo != nil {
                throw TerminalAgentReportError.unavailable
            }
            switch request.action {
            case "bind_native_agent":
                guard registry.agentMonitoringEnabled, request.agentKind == .willdeep,
                      session.nativeAgentContext.authorizes(request.nativeAgentToken) else {
                    throw TerminalAgentReportError.invalidCapability
                }
                response.agentGrant = try session.bindAgent(kind: .willdeep)
            case "bind_agent":
                guard registry.agentMonitoringEnabled else { throw TerminalAgentReportError.unavailable }
                // Status binding is separate from terminal input permission and the input lease.
                guard paired(), let kind = request.agentKind else {
                    throw TerminalAgentReportError.invalidCapability
                }
                response.agentGrant = try session.bindAgent(kind: kind)
            case "report_agent_state":
                guard registry.agentMonitoringEnabled else { throw TerminalAgentReportError.unavailable }
                guard let report = request.agentReport else { throw TerminalAgentReportError.invalidState }
                try session.reportAgent(report)
            default: break
            }
            session.expireAgentStatus(now: Date())
            response.agent = session.agentStatus
            return response
        } catch {
            // Never interpolate a report, request, token, or untrusted terminal text into errors.
            let code: String
            if let failure = error as? TerminalAgentReportError { code = failure.rawValue }
            else if let failure = error as? TerminalEventReadError {
                switch failure {
                case .appRestarted: code = "app_restarted"
                case .cursorExpired: code = "cursor_expired"
                case .futureCursor: code = "future_cursor"
                }
            } else { code = "invalid_request" }
            return TerminalToolResponse(id: request.id, ok: false, snapshotSequence: snapshotSequence,
                action: request.action, message: nil, error: code)
        }
    }
}
