#if DEBUG
import Foundation

enum TerminalPreviewUITestFixture {
    static func applyIfRequested(workspace: TerminalWorkspace) {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing-preview"),
              let path = ProcessInfo.processInfo.environment["QTERM_AGENT_TEST_TOOL_ROOT"],
              path.hasPrefix("/private/tmp/qterm-preview-ui-"), let source = workspace.selectedTab else { return }
        do {
            let root = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let markdown = root.appendingPathComponent("preview-report.md")
            try "# Preview acceptance\n\n| Item | Result |\n|---|---|\n| Terminal | Preserved |\n\n```sh\nprintf preview_ok\n```\n".write(to: markdown, atomically: true, encoding: .utf8)
            let image = root.appendingPathComponent("preview-image.png")
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/xcAAwMCAO6V2yEAAAAASUVORK5CYII=")!
            try png.write(to: image)
            TerminalPreviewCenter.shared.open(source: source, url: markdown)
        } catch { NSLog("QTerm preview UI fixture failed: %@", error.localizedDescription) }
    }
}
#endif
