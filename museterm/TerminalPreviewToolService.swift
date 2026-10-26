import Foundation

@MainActor
enum TerminalPreviewToolService {
    static func perform(_ request: TerminalToolRequest, workspace: TerminalWorkspace, snapshotSequence: Int) -> TerminalToolResponse {
        do {
            // UI operations must name the source explicitly; never guess the user's foreground tab.
            guard let selector = request.tab, let id = UUID(uuidString: selector),
                  let source = workspace.tabs.first(where: { $0.id == id }),
                  let preview = request.previewRequest else { throw TerminalPreviewError.unsupported }
            let now = TerminalProjectToolService.requestMonotonicTime()
            guard preview.uiEpoch == workspace.sessionRegistry.events.appEpoch,
                  let deadline = preview.deadlineMonotonic, deadline.isFinite,
                  deadline > now, deadline - now <= 60 else { throw TerminalPreviewError.unsupported }
            if preview.close == true {
                guard preview.path == nil, preview.markdown == nil else { throw TerminalPreviewError.unsupported }
                TerminalPreviewCenter.shared.close(source.id)
            }
            else if let text = preview.markdown, preview.path == nil {
                guard text.utf8.count <= TerminalPreviewLoader.markdownLimit else { throw TerminalPreviewError.tooLarge }
                TerminalPreviewCenter.shared.open(source: source, text: text)
            } else if let path = preview.path, preview.markdown == nil {
                // SSH paths are not local paths. An Agent on the remote host can send Markdown text instead.
                guard source.executionContext.targetKind != .ssh, path.hasPrefix("/"), !path.utf8.contains(0)
                else { throw TerminalPreviewError.unsupported }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard TerminalPreviewLoader.supports(url) else { throw TerminalPreviewError.unsupported }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                let limit = TerminalPreviewLoader.markdownExtensions.contains(url.pathExtension.lowercased())
                    ? TerminalPreviewLoader.markdownLimit : TerminalPreviewLoader.imageLimit
                guard values.isRegularFile == true, let size = values.fileSize, size <= limit else { throw TerminalPreviewError.tooLarge }
                TerminalPreviewCenter.shared.open(source: source, url: url)
            } else { throw TerminalPreviewError.unsupported }
            return TerminalToolResponse(id: request.id, ok: true, snapshotSequence: snapshotSequence,
                action: request.action, tabID: source.id.uuidString, message: L10n.string("preview.accepted"), error: nil)
        } catch {
            return TerminalToolResponse(id: request.id, ok: false, snapshotSequence: snapshotSequence,
                action: request.action, message: nil, error: L10n.string("preview.request_error"))
        }
    }
}
