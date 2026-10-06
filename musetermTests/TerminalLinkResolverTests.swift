import XCTest
@testable import museterm

final class TerminalLinkResolverTests: XCTestCase {
    private let home = "/Users/tester"
    private let localContext = TerminalLinkContext(currentDirectory: "/Users/tester/project", isRemoteSession: false)

    /// 虚拟文件系统：路径 -> 文件信息，不碰真实磁盘
    private func fileSystem(_ entries: [String: TerminalLinkFileInfo]) -> (String) -> TerminalLinkFileInfo? {
        { entries[$0] }
    }

    private let file = TerminalLinkFileInfo(isDirectory: false, isExecutable: false)
    private let directory = TerminalLinkFileInfo(isDirectory: true, isExecutable: false)
    private let executable = TerminalLinkFileInfo(isDirectory: false, isExecutable: true)

    private func resolve(
        _ link: String,
        context: TerminalLinkContext? = nil,
        files: [String: TerminalLinkFileInfo] = [:]
    ) -> Result<TerminalLinkTarget, TerminalLinkResolutionFailure> {
        TerminalLinkResolver.resolve(
            link,
            context: context ?? localContext,
            homeDirectory: home,
            fileInfo: fileSystem(files)
        )
    }

    // MARK: - Web

    func testWebPageOpensInBrowser() {
        let url = URL(string: "https://example.com/docs?q=1")!
        XCTAssertEqual(resolve("https://example.com/docs?q=1"), .success(.webPage(url)))
    }

    func testImageURLsAreDetectedByExtensionCaseInsensitively() {
        for link in [
            "https://example.com/a.png",
            "http://cdn.example.com/x/photo.JPG",
            "https://example.com/pic.webp?size=large",
            "https://example.com/shot.heic",
        ] {
            XCTAssertEqual(resolve(link), .success(.webImage(URL(string: link)!)), link)
        }
    }

    func testSVGAndNonImageURLsStayInBrowser() {
        for link in ["https://example.com/logo.svg", "https://example.com/png", "https://example.com/a.png.html"] {
            XCTAssertEqual(resolve(link), .success(.webPage(URL(string: link)!)), link)
        }
    }

    func testWebURLsWorkEvenInRemoteSessions() {
        let remote = TerminalLinkContext(currentDirectory: "/srv/app", isRemoteSession: true)
        let link = "https://example.com/a.png"
        XCTAssertEqual(resolve(link, context: remote), .success(.webImage(URL(string: link)!)))
    }

    func testOtherSchemesKeepSystemBehavior() {
        let link = "mailto:dev@example.com"
        XCTAssertEqual(resolve(link), .success(.otherScheme(URL(string: link)!)))
    }

    // MARK: - Local paths

    func testRelativeMarkdownPathResolvesAgainstCurrentDirectory() {
        let path = "/Users/tester/project/docs/README.md"
        XCTAssertEqual(
            resolve("docs/README.md", files: [path: file]),
            .success(.localItem(URL(fileURLWithPath: path)))
        )
        XCTAssertEqual(
            resolve("./docs/README.md", files: [path: file]),
            .success(.localItem(URL(fileURLWithPath: path)))
        )
    }

    func testParentAndHomeAndAbsolutePaths() {
        let notes = "/Users/tester/notes.md"
        XCTAssertEqual(resolve("../notes.md", files: [notes: file]), .success(.localItem(URL(fileURLWithPath: notes))))
        XCTAssertEqual(resolve("~/notes.md", files: [notes: file]), .success(.localItem(URL(fileURLWithPath: notes))))
        XCTAssertEqual(resolve(notes, files: [notes: file]), .success(.localItem(URL(fileURLWithPath: notes))))
    }

    func testFileSchemeURL() {
        let path = "/tmp/report.md"
        XCTAssertEqual(resolve("file:///tmp/report.md", files: [path: file]), .success(.localItem(URL(fileURLWithPath: path))))
    }

    func testCurrentDirectoryReportedAsFileURL() {
        let context = TerminalLinkContext(currentDirectory: "file:///Users/tester/project", isRemoteSession: false)
        let path = "/Users/tester/project/CHANGELOG.md"
        XCTAssertEqual(
            resolve("CHANGELOG.md", context: context, files: [path: file]),
            .success(.localItem(URL(fileURLWithPath: path)))
        )
    }

    func testLineAndColumnSuffixIsStrippedWhenNeeded() {
        let path = "/Users/tester/project/README.md"
        for link in ["README.md:12", "README.md:12:5", "README.md:12:"] {
            XCTAssertEqual(resolve(link, files: [path: file]), .success(.localItem(URL(fileURLWithPath: path))), link)
        }
    }

    func testDirectoryOpensInFinder() {
        let path = "/Users/tester/project/docs"
        XCTAssertEqual(
            resolve("docs/", files: [path: directory]),
            .success(.localItem(URL(fileURLWithPath: path, isDirectory: true)))
        )
    }

    func testExecutablesAndAppBundlesAreOnlyRevealed() {
        let script = "/Users/tester/project/deploy.sh"
        let binary = "/Users/tester/project/bin/server"
        let app = "/Applications/Some.app"
        XCTAssertEqual(resolve("deploy.sh", files: [script: file]), .success(.revealInFinder(URL(fileURLWithPath: script))))
        XCTAssertEqual(resolve("bin/server", files: [binary: executable]), .success(.revealInFinder(URL(fileURLWithPath: binary))))
        XCTAssertEqual(
            resolve(app, files: [app: directory]),
            .success(.revealInFinder(URL(fileURLWithPath: app, isDirectory: true)))
        )
    }

    func testExecutableBitOnDocumentStillOpens() {
        let path = "/Users/tester/project/notes.md"
        XCTAssertEqual(resolve("notes.md", files: [path: executable]), .success(.localItem(URL(fileURLWithPath: path))))
    }

    func testRemoteSessionPathsAreNotOpenedLocally() {
        let remote = TerminalLinkContext(currentDirectory: "/srv/app", isRemoteSession: true)
        // 本机恰好有同名文件也不能开
        XCTAssertEqual(
            resolve("/etc/hosts", context: remote, files: ["/etc/hosts": file]),
            .failure(.remotePath("/etc/hosts"))
        )
    }

    func testMissingFilesReportNotFound() {
        XCTAssertEqual(resolve("docs/missing.md"), .failure(.notFound("docs/missing.md")))
    }

    func testRelativePathWithoutWorkingDirectoryIsNotFound() {
        let context = TerminalLinkContext(currentDirectory: nil, isRemoteSession: false)
        XCTAssertEqual(resolve("README.md", context: context), .failure(.notFound("README.md")))
    }

    func testVariablePathsAreNotExpanded() {
        XCTAssertEqual(
            resolve("$HOME/notes.md", files: ["/Users/tester/notes.md": file]),
            .failure(.notFound("$HOME/notes.md"))
        )
    }

    func testBlankLinkIsInvalid() {
        XCTAssertEqual(resolve("   "), .failure(.invalid("   ")))
    }

    // MARK: - Image download helpers & preference

    func testPreviewFileNameKeepsOrAddsExtension() {
        XCTAssertEqual(
            TerminalLinkImageDownloader.previewFileName(for: URL(string: "https://e.com/a/b.png")!, mimeType: "image/png"),
            "b.png"
        )
        XCTAssertEqual(
            TerminalLinkImageDownloader.previewFileName(for: URL(string: "https://e.com/avatar")!, mimeType: "image/jpeg"),
            "avatar.jpg"
        )
        XCTAssertEqual(
            TerminalLinkImageDownloader.previewFileName(for: URL(string: "https://e.com/")!, mimeType: "image/webp"),
            "image.webp"
        )
    }

    func testOpenWebImagesInViewerDefaultsOnAndPersists() {
        let suiteName = "TerminalLinkResolverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)
        XCTAssertTrue(preferences.openWebImagesInViewer)

        preferences.openWebImagesInViewer = false
        XCTAssertFalse(TerminalPreferences(defaults: defaults).openWebImagesInViewer)
    }
}

final class TerminalLinkWordExtractorTests: XCTestCase {
    private func cells(_ text: String) -> [Character] { Array(text) }

    func testExtractsBareFileNameFromLsOutput() {
        let line = cells("AGENTS.md  CHANGELOG.md  README.md")
        let column = 13 // 落在 CHANGELOG.md 中间
        XCTAssertEqual(TerminalLinkWordExtractor.candidate(in: line, at: column), "CHANGELOG.md")
    }

    func testKeepsLineNumberButDropsTrailingPunctuation() {
        XCTAssertEqual(TerminalLinkWordExtractor.candidate(in: cells("see CHANGELOG.md:3: Added"), at: 6), "CHANGELOG.md:3")
        XCTAssertEqual(TerminalLinkWordExtractor.candidate(in: cells("open notes.md."), at: 7), "notes.md")
    }

    func testKeepsLeadingDotsOfRelativeAndHiddenPaths() {
        XCTAssertEqual(TerminalLinkWordExtractor.candidate(in: cells("x ../a.md y"), at: 4), "../a.md")
        XCTAssertEqual(TerminalLinkWordExtractor.candidate(in: cells(".env"), at: 1), ".env")
    }

    func testClickOnSpaceOrOutOfRangeReturnsNil() {
        let line = cells("a.md  b.md")
        XCTAssertNil(TerminalLinkWordExtractor.candidate(in: line, at: 5))
        XCTAssertNil(TerminalLinkWordExtractor.candidate(in: line, at: 99))
    }

    func testStopsAtWideCharacterPlaceholders() {
        // 宽字符后面的占位格是 NUL
        let line: [Character] = ["文", "\u{0}", "件", "\u{0}", " ", "a", ".", "m", "d"]
        XCTAssertEqual(TerminalLinkWordExtractor.candidate(in: line, at: 6), "a.md")
        XCTAssertNil(TerminalLinkWordExtractor.candidate(in: line, at: 1))
    }
}
