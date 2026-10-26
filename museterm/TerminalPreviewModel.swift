import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TerminalPreviewRequest: Codable {
    var uiEpoch: UUID? = nil
    var deadlineMonotonic: Double? = nil
    var path: String? = nil
    var markdown: String? = nil
    var close: Bool? = nil
}

@MainActor
final class TerminalPreviewDocument: ObservableObject, Identifiable {
    let id = UUID()
    let sourceID: UUID
    let sourceTitle: String
    let url: URL?
    private let selectedText: String?
    @Published private(set) var content: TerminalPreviewContent?
    @Published private(set) var error: String?
    @Published private(set) var remoteError: String?
    @Published private(set) var loading = false
    @Published var raw = false
    @Published var zoom: CGFloat = 1
    @Published var fit = true
    @Published var detached = false
    private var remoteCache: [URL: Data] = [:]
    private var timer: Timer?
    private var generation = UUID()
    private var lastStamp: String?
    private var loadingRemote = false

    var title: String { url?.lastPathComponent ?? L10n.string("preview.selection") }

    init(source: TerminalSession, url: URL? = nil, text: String? = nil) {
        sourceID = source.id; sourceTitle = source.title; self.url = url; selectedText = text
        reload()
        if url != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshIfChanged() }
            }
        }
    }

    deinit { timer?.invalidate() }

    private func stamp() -> String? {
        guard let url, let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]) else { return nil }
        return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0):\(String(describing: values.fileResourceIdentifier))"
    }

    private func refreshIfChanged() {
        let value = stamp()
        guard value != lastStamp, !loading else { return }
        remoteCache = [:]
        reload()
    }

    func reload() {
        let token = UUID(); generation = token; loading = true; error = nil; lastStamp = stamp()
        let url = url, text = selectedText, cache = remoteCache
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> TerminalPreviewContent in
                    if let url { return try TerminalPreviewLoader.load(url, remoteCache: cache) }
                    return try TerminalPreviewLoader.render(text ?? "", remoteCache: cache)
                }
            }.value
            guard let self, self.generation == token else { return }
            self.loading = false
            switch result {
            case .success(let content): self.content = content
            case .failure: self.content = nil; self.error = L10n.string("preview.load_error")
            }
        }
    }

    func loadRemoteImages() {
        guard !loadingRemote, let urls = content?.remoteImages, !urls.isEmpty else { return }
        loadingRemote = true
        remoteError = nil
        downloadNext(urls[...], documentGeneration: generation)
    }

    private func downloadNext(_ urls: ArraySlice<URL>, documentGeneration: UUID) {
        guard generation == documentGeneration, let url = urls.first else {
            loadingRemote = false
            if generation == documentGeneration { reload() }
            return
        }
        TerminalLinkImageDownloader.download(url) { [weak self] result in
            guard let self, self.generation == documentGeneration else { self?.loadingRemote = false; return }
            if case .success(let local) = result,
               let data = try? TerminalPreviewLoader.read(local, limit: TerminalPreviewLoader.imageLimit),
               self.remoteCache.values.reduce(0, { $0 + $1.count }) + data.count <= TerminalPreviewLoader.imageLimit {
                self.remoteCache[url] = data
            } else { self.remoteError = L10n.string("preview.remote_error") }
            self.downloadNext(urls.dropFirst(), documentGeneration: documentGeneration)
        }
    }

    func copyContent() {
        NSPasteboard.general.clearContents()
        if let text = content?.markdown { NSPasteboard.general.setString(text, forType: .string) }
        else if let data = content?.imageData, let image = NSImage(data: data) { NSPasteboard.general.writeObjects([image]) }
    }
}

@MainActor
final class TerminalPreviewCenter: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = TerminalPreviewCenter()
    @Published private(set) var documents: [UUID: TerminalPreviewDocument] = [:]
    private var windows: [UUID: NSWindow] = [:]

    func open(source: TerminalSession, url: URL? = nil, text: String? = nil) {
        close(source.id)
        documents[source.id] = TerminalPreviewDocument(source: source, url: url, text: text)
    }

    func chooseFile(source: TerminalSession) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .init(filenameExtension: "md") ?? .plainText, .plainText]
        panel.prompt = L10n.string("preview.open")
        panel.begin { [weak self, weak source] response in
            guard response == .OK, let source, let url = panel.url else { return }
            self?.open(source: source, url: url)
        }
    }

    func close(_ sourceID: UUID) {
        windows.removeValue(forKey: sourceID)?.close()
        documents.removeValue(forKey: sourceID)
    }

    func detach(_ document: TerminalPreviewDocument) {
        if let window = windows[document.sourceID] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = document.title
        window.delegate = self
        window.contentView = NSHostingView(rootView: TerminalPreviewPanel(document: document, isDetachedWindow: true))
        window.center(); windows[document.sourceID] = window; document.detached = true
        objectWillChange.send()
        // Detach is an explicit human action. Agent requests only open the non-focusing sidebar.
        window.makeKeyAndOrderFront(nil)
    }

    func dock(_ document: TerminalPreviewDocument) {
        windows.removeValue(forKey: document.sourceID)?.close()
        document.detached = false
        objectWillChange.send()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: id)
        documents[id]?.detached = false
        objectWillChange.send()
    }
}
