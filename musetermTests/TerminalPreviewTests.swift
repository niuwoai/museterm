import AppKit
import SwiftTerm
import XCTest
@testable import museterm

@MainActor
final class TerminalPreviewTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/xcAAwMCAO6V2yEAAAAASUVORK5CYII=")!

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-preview-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testGFMHeadingsTablesCodeAndTaskLists() throws {
        let result = try TerminalPreviewLoader.render("# Report\n\n| A | B |\n|---|---|\n| x | y |\n\n- [x] Done\n\n```sh\nprintf '<ok>'\n```\n")
        let html = try XCTUnwrap(result.html)
        XCTAssertTrue(html.contains("<h1>Report</h1>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<td>x</td>"))
        XCTAssertTrue(html.contains("☑"))
        XCTAssertTrue(html.contains("&lt;ok&gt;"))
        XCTAssertEqual(result.markdown?.hasPrefix("# Report"), true)
    }

    func testRawHTMLAndUnsafeLinksCannotBecomeActiveContent() throws {
        let html = try XCTUnwrap(TerminalPreviewLoader.render("<script>alert(1)</script>\n\n[bad](javascript:alert) [file](file:///etc/passwd)\n\n![x](https://example.invalid/x.png)").html)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertFalse(html.contains("href=\"file:"))
        XCTAssertFalse(html.contains("src=\"https:"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testRelativeImagesStayInsideRealDocumentDirectoryAndRemoteNeedsCache() throws {
        let root = try root(), folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("outside.png"))
        try png.write(to: folder.appendingPathComponent("inside.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.png"), withDestinationURL: root.appendingPathComponent("outside.png"))
        let safe = try TerminalPreviewLoader.render("![ok](inside.png)", base: folder)
        XCTAssertTrue(safe.html?.contains("data:image/png;base64,") == true)
        for path in ["../outside.png", "escape.png", root.appendingPathComponent("outside.png").path] {
            XCTAssertFalse(try XCTUnwrap(TerminalPreviewLoader.render("![bad](\(path))", base: folder).html).contains("src=\"data:"))
        }
        let url = URL(string: "https://example.invalid/p.png")!
        let blocked = try TerminalPreviewLoader.render("![remote](\(url))")
        XCTAssertEqual(blocked.remoteImages, [url])
        XCTAssertFalse(blocked.html?.contains("src=\"data:") == true)
        let allowed = try TerminalPreviewLoader.render("![remote](\(url))", remoteCache: [url: png])
        XCTAssertTrue(allowed.html?.contains("src=\"data:") == true)
    }

    func testFilesAreBoundedAndInvalidFormatsFail() throws {
        let root = try root(), image = root.appendingPathComponent("image.png"), markdown = root.appendingPathComponent("report.md")
        try png.write(to: image)
        XCTAssertNotNil(try TerminalPreviewLoader.load(image).imageData)
        try Data("invalid".utf8).write(to: image)
        XCTAssertThrowsError(try TerminalPreviewLoader.load(image))
        try Data(repeating: 65, count: TerminalPreviewLoader.markdownLimit + 1).write(to: markdown)
        XCTAssertThrowsError(try TerminalPreviewLoader.load(markdown))
        XCTAssertThrowsError(try TerminalPreviewLoader.read(root, limit: 1))
        XCTAssertFalse(TerminalPreviewLoader.supports(root.appendingPathComponent("run.sh")))
    }

    func testInlineImagesReachNativeViewAcrossHistoricalReplayAndResize() async {
        let encoded = png.base64EncodedString()
        let protocols = [
            "\u{1b}]1337;File=inline=1;width=2;height=1:\(encoded)\u{7}",
            "\u{1b}_Gf=100,a=T,i=7,q=2;\(encoded)\u{1b}\\",
            "\u{1b}Pq#0;2;100;0;0~$\u{1b}\\"
        ]
        for sequence in protocols {
            let view = FocusableLocalProcessTerminalView(
                frame: .init(x: 0, y: 0, width: 800, height: 600),
                font: nil,
                options: TerminalGraphicsPolicy.terminalOptions(cacheMegabytes: 128)
            )
            let data = Data(sequence.utf8)
            await withCheckedContinuation { continuation in
                view.receiveExternal(data, historicalBytes: data.count) { continuation.resume() }
            }
            // v1.99.2 keeps iTerm2 and sixel images on buffer lines, and Kitty images in
            // its graphics store. Neither shows up in the text the view returns.
            XCTAssertTrue(view.hasRetainedInlineGraphics(), String(sequence.prefix(24)))
            view.resize(cols: 60, rows: 20)
            XCTAssertTrue(view.hasRetainedInlineGraphics(), String(sequence.prefix(24)))
            view.feed(text: "\r\n__AFTER_IMAGE__")
            XCTAssertTrue(String(decoding: view.getBufferAsData(), as: UTF8.self).contains("__AFTER_IMAGE__"))
        }
    }

    func testDocumentRefreshesAfterAtomicReplacementAndReportsDeletion() async throws {
        let root = try root(), file = root.appendingPathComponent("report.md")
        try "# Original".write(to: file, atomically: true, encoding: .utf8)
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let document = TerminalPreviewDocument(source: try XCTUnwrap(workspace.selectedTab), url: file)
        for _ in 0..<100 {
            if document.content?.markdown == "# Original" { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(document.content?.markdown, "# Original")
        try "# Replaced content".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<120 {
            if document.content?.markdown == "# Replaced content" { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(document.content?.markdown, "# Replaced content")
        try FileManager.default.removeItem(at: file)
        for _ in 0..<100 {
            if document.error != nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(document.error)
        XCTAssertNil(document.content)
    }

    func testGeneratedCLIMCPPairingBackgroundScopeAndTimeout() async throws {
        let root = try root(), domain = "MuseTermPreviewTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let preferences = TerminalPreferences(defaults: defaults)
        workspace.preferences = preferences
        let source = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab(startDirectory: root.path)
        let selected = workspace.selectedID
        let toolRoot = root.appendingPathComponent("Library/Application Support/MuseTerm/Tools")
        let bridge = TerminalToolBridge(rootDirectory: toolRoot)
        bridge.attach(workspace: workspace)
        defer { bridge.stop(); TerminalPreviewCenter.shared.close(source.id) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: toolRoot.appendingPathComponent("runtime.json").path) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        MuseTermKeychain._useTestStorage(true)
        defer { MuseTermKeychain._useTestStorage(false) }
        XCTAssertNoThrow(try MuseTermKeychain.save("preview-fixture-only", account: "museterm-cli", serviceName: TerminalToolAccess.keychainServiceName))
        preferences.toolBridgeWritesEnabled = true
        let definitions = try XCTUnwrap(MuseTermCLIInstaller.script.components(separatedBy: "\ncommand = ARGV.shift").first)
        let report = root.appendingPathComponent("cli-report.md")
        try "# CLI file preview".write(to: report, atomically: true, encoding: .utf8)
        let body = """
        def access_token; "wrong-fixture"; end
        denied = begin
          preview_tool({"tab" => "\(source.id)", "markdown" => "# Denied"}); false
        rescue; true; end
        def access_token; "preview-fixture-only"; end
        def print_json(value); $preview_cli_result = value; end
        command_preview(["--tab", "\(source.id)", "\(report.path)"])
        raise "CLI dispatch failed" unless $preview_cli_result["ok"]
        require "stringio"
        Object.send(:remove_const, :STDIN)
        STDIN = StringIO.new("# 中文标准输入")
        command_preview(["--tab", "\(source.id)", "--stdin"])
        raise "UTF-8 stdin failed" unless $preview_cli_result["ok"]
        result = call_tool("preview", {"tab" => "\(source.id)", "markdown" => "# Background preview"})
        puts JSON.generate({"denied" => denied, "response" => JSON.parse(result["content"][0]["text"])})
        """
        let script = root.appendingPathComponent("fixture.rb")
        try (definitions + "\n" + body).write(to: script, atomically: true, encoding: .utf8)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby"); process.arguments = [script.path]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<400 {
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(process.isRunning)
        guard !process.isRunning else { return }
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        XCTAssertEqual(result["denied"] as? Bool, true)
        XCTAssertEqual((result["response"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual(workspace.selectedID, selected)
        XCTAssertNotNil(TerminalPreviewCenter.shared.documents[source.id])
        XCTAssertNil(TerminalPreviewCenter.shared.documents[try XCTUnwrap(selected)])
        // A queued request from an old UI process must not open a file after reconnect.
        var request = try JSONDecoder().decode(TerminalToolRequest.self, from: Data("{\"id\":\"test\",\"action\":\"preview\",\"tab\":\"\(source.id)\"}".utf8))
        request.previewRequest = TerminalPreviewRequest(uiEpoch: UUID(), deadlineMonotonic: TerminalProjectToolService.requestMonotonicTime() + 2, markdown: "# Stale")
        XCTAssertFalse(TerminalPreviewToolService.perform(request, workspace: workspace, snapshotSequence: 1).ok)
        request.previewRequest?.uiEpoch = workspace.sessionRegistry.events.appEpoch
        request.previewRequest?.deadlineMonotonic = TerminalProjectToolService.requestMonotonicTime() - 1
        XCTAssertFalse(TerminalPreviewToolService.perform(request, workspace: workspace, snapshotSequence: 1).ok)
    }

    func testSuppliedImageOpensBesideTheSourceTerminal() throws {
        let domain = "MuseTermPreviewTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let preferences = TerminalPreferences(defaults: defaults)
        workspace.preferences = preferences
        let source = try XCTUnwrap(workspace.selectedTab)
        defer { TerminalPreviewCenter.shared.close(source.id) }

        var request = try JSONDecoder().decode(TerminalToolRequest.self, from: Data("{\"id\":\"image\",\"action\":\"preview\",\"tab\":\"\(source.id)\"}".utf8))
        request.previewRequest = TerminalPreviewRequest(
            uiEpoch: workspace.sessionRegistry.events.appEpoch,
            deadlineMonotonic: TerminalProjectToolService.requestMonotonicTime() + 2,
            image: png.base64EncodedString(), title: "generated.png")

        let response = TerminalPreviewToolService.perform(request, workspace: workspace, snapshotSequence: 1)
        XCTAssertTrue(response.ok)
        let document = try XCTUnwrap(TerminalPreviewCenter.shared.documents[source.id])
        XCTAssertEqual(document.title, "generated.png")
        for _ in 0..<100 {
            if document.content?.imageData != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(document.content?.imageData)

        request.previewRequest?.image = Data("not an image".utf8).base64EncodedString()
        XCTAssertFalse(TerminalPreviewToolService.perform(request, workspace: workspace, snapshotSequence: 2).ok)
        request.previewRequest?.image = png.base64EncodedString()
        request.previewRequest?.path = "/tmp/also.png"
        XCTAssertFalse(TerminalPreviewToolService.perform(request, workspace: workspace, snapshotSequence: 3).ok)
    }
}
