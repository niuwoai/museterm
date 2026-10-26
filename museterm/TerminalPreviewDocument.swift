import Foundation
import Darwin
import ImageIO
import Markdown
import UniformTypeIdentifiers

nonisolated struct TerminalPreviewContent: Sendable {
    var markdown: String?
    var html: String?
    var imageData: Data?
    var remoteImages: [URL] = []
}

nonisolated enum TerminalPreviewError: Error { case unsupported, tooLarge, invalidImage, invalidText }

/// Read bounded regular files only. ImageIO produces a bounded first-frame thumbnail before AppKit sees it.
nonisolated enum TerminalPreviewLoader {
    static let markdownLimit = 2 * 1024 * 1024
    static let imageLimit = 20 * 1024 * 1024
    static let thumbnailPixels = 4096
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    static func supports(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased()) ||
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        let descriptor = Darwin.open(url.resolvingSymlinksInPath().path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw TerminalPreviewError.unsupported }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw TerminalPreviewError.unsupported }
        guard info.st_size <= limit else { throw TerminalPreviewError.tooLarge }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw TerminalPreviewError.tooLarge }
        return data
    }

    static func thumbnail(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw TerminalPreviewError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw TerminalPreviewError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TerminalPreviewError.invalidImage }
        return output as Data
    }

    static func load(_ url: URL, remoteCache: [URL: Data] = [:]) throws -> TerminalPreviewContent {
        if markdownExtensions.contains(url.pathExtension.lowercased()) {
            let data = try read(url, limit: markdownLimit)
            guard let text = String(data: data, encoding: .utf8) else { throw TerminalPreviewError.invalidText }
            return try render(text, base: url.deletingLastPathComponent(), remoteCache: remoteCache)
        }
        guard supports(url) else { throw TerminalPreviewError.unsupported }
        return TerminalPreviewContent(imageData: try thumbnail(read(url, limit: imageLimit)))
    }

    static func render(_ text: String, base: URL? = nil, remoteCache: [URL: Data] = [:]) throws -> TerminalPreviewContent {
        guard text.utf8.count <= markdownLimit else { throw TerminalPreviewError.tooLarge }
        var renderer = TerminalMarkdownRenderer(base: base, remoteCache: remoteCache)
        let body = renderer.render(Document(parsing: text))
        return TerminalPreviewContent(markdown: text, html: renderer.page(body), remoteImages: renderer.remoteImages)
    }
}

/// Build HTML from an allowlisted AST; raw HTML is escaped, never executed. All images become bounded data URLs.
nonisolated struct TerminalMarkdownRenderer {
    let base: URL?
    var remoteCache: [URL: Data] = [:]
    var remoteImages: [URL] = []
    private var embeddedBytes = 0
    private var embeddedCount = 0
    private static let embeddedLimit = 20 * 1024 * 1024
    private static let imageCountLimit = 32

    init(base: URL?, remoteCache: [URL: Data] = [:]) { self.base = base; self.remoteCache = remoteCache }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    mutating func render(_ node: any Markup, depth: Int = 0) -> String {
        guard depth < 128 else { return "" }
        if let text = node as? Markdown.Text { return Self.escape(text.string) }
        if let code = node as? InlineCode { return "<code>\(Self.escape(code.code))</code>" }
        if let code = node as? CodeBlock { return "<pre><code>\(Self.escape(code.code))</code></pre>" }
        if let html = node as? HTMLBlock { return "<pre>\(Self.escape(html.rawHTML))</pre>" }
        if let html = node as? InlineHTML { return Self.escape(html.rawHTML) }
        if let image = node as? Markdown.Image { return renderImage(image) }
        var children = ""
        for child in node.children { children += render(child, depth: depth + 1) }
        switch node {
        case let heading as Heading: return "<h\(heading.level)>\(children)</h\(heading.level)>"
        case is Paragraph: return "<p>\(children)</p>"
        case is Strong: return "<strong>\(children)</strong>"
        case is Emphasis: return "<em>\(children)</em>"
        case is Strikethrough: return "<del>\(children)</del>"
        case is BlockQuote: return "<blockquote>\(children)</blockquote>"
        case is UnorderedList: return "<ul>\(children)</ul>"
        case let list as OrderedList: return "<ol start=\"\(list.startIndex)\">\(children)</ol>"
        case let item as ListItem:
            let check = item.checkbox.map { $0 == .checked ? "☑ " : "☐ " } ?? ""
            return "<li>\(check)\(children)</li>"
        case is Table: return "<div class=\"table\"><table>\(children)</table></div>"
        case is Table.Head: return "<thead><tr>\(children)</tr></thead>"
        case is Table.Body: return "<tbody>\(children)</tbody>"
        case is Table.Row: return "<tr>\(children)</tr>"
        case is Table.Cell: return "<td>\(children)</td>"
        case is ThematicBreak: return "<hr>"
        case is LineBreak: return "<br>"
        case is SoftBreak: return "\n"
        case let link as Markdown.Link:
            guard let raw = link.destination, let url = URL(string: raw),
                  ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return children }
            return "<a href=\"\(Self.escape(url.absoluteString))\">\(children)</a>"
        default: return children
        }
    }

    private mutating func renderImage(_ image: Markdown.Image) -> String {
        let alt = Self.escape(image.plainText)
        guard embeddedCount < Self.imageCountLimit else { return "<span>\(alt)</span>" }
        embeddedCount += 1
        guard let path = image.source, let url = URL(string: path) else { return "<span>\(alt)</span>" }
        var data: Data?
        if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            if !remoteImages.contains(url), remoteImages.count < Self.imageCountLimit { remoteImages.append(url) }
            data = remoteCache[url]
        } else if url.scheme == nil, !path.hasPrefix("/"), let base {
            let root = base.resolvingSymlinksInPath().standardizedFileURL
            let local = root.appendingPathComponent(path.removingPercentEncoding ?? path).resolvingSymlinksInPath().standardizedFileURL
            if local.path.hasPrefix(root.path + "/"), TerminalPreviewLoader.supports(local), embeddedBytes < Self.embeddedLimit {
                data = try? TerminalPreviewLoader.read(local, limit: min(TerminalPreviewLoader.imageLimit, Self.embeddedLimit - embeddedBytes))
            }
        }
        guard let data, let thumbnail = try? TerminalPreviewLoader.thumbnail(data),
              embeddedBytes + thumbnail.count <= Self.embeddedLimit else { return "<span class=\"image-placeholder\">▧ \(alt)</span>" }
        embeddedBytes += thumbnail.count
        return "<img alt=\"\(alt)\" src=\"data:image/png;base64,\(thumbnail.base64EncodedString())\">"
    }

    func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>:root{color-scheme:light dark}body{font:14px -apple-system,sans-serif;line-height:1.65;margin:24px;overflow-wrap:anywhere}h1,h2,h3{line-height:1.3}h1{font-size:26px}h2{font-size:21px}a{color:#6e9bea}code{font:12px ui-monospace,monospace}pre{padding:14px;background:rgba(128,128,128,.13);border-radius:8px;overflow:auto}blockquote{border-left:3px solid #8492aa;margin-left:0;padding-left:14px;opacity:.85}.table{overflow:auto}table{border-collapse:collapse;width:100%}td{border:1px solid #8888;padding:7px 10px}thead{font-weight:600}img{max-width:100%;height:auto;border-radius:6px}.image-placeholder{opacity:.6}hr{border:0;border-top:1px solid #8885}</style>
        </head><body>\(body)</body></html>
        """
    }
}
