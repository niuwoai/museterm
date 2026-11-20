import Foundation

enum TerminalAttentionToolService {
    static let actions: Set<String> = ["list_attention", "acknowledge_attention"]

    static func perform(_ request: TerminalToolRequest, registry: TerminalSessionRegistry,
                        snapshotSequence: Int, paired: () -> Bool) -> TerminalToolResponse {
        do {
            if request.action == "acknowledge_attention" {
                guard paired(), let id = request.attentionID, let version = request.attentionVersion else {
                    throw TerminalAttentionMutationError.notFound
                }
                try registry.attention.markRead(id: id, version: version)
            }
            var response = TerminalToolResponse(id: request.id, ok: true, snapshotSequence: snapshotSequence,
                action: request.action, message: nil, error: nil)
            response.attentionItems = registry.attention.activeItems.filter {
                request.tab == nil || $0.tabID.uuidString.lowercased() == request.tab?.lowercased()
            }
            return response
        } catch {
            return TerminalToolResponse(id: request.id, ok: false, snapshotSequence: snapshotSequence,
                action: request.action, message: nil,
                error: (error as? TerminalAttentionMutationError)?.rawValue ?? "invalid_request")
        }
    }
}
