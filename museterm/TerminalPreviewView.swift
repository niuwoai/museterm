import AppKit
import SwiftUI
import WebKit

struct TerminalPreviewSidebar: View {
    @ObservedObject private var center = TerminalPreviewCenter.shared
    let sourceID: UUID?
    @State private var width: CGFloat = 410
    @State private var dragWidth: CGFloat?

    var body: some View {
        if let sourceID, let document = center.documents[sourceID], !document.detached {
            HStack(spacing: 0) {
                Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 5)
                    .contentShape(Rectangle())
                    .help(L10n.string("preview.resize"))
                    .gesture(DragGesture().onChanged { value in
                        if dragWidth == nil { dragWidth = width }
                        width = min(720, max(280, (dragWidth ?? width) - value.translation.width))
                    }.onEnded { _ in dragWidth = nil })
                TerminalPreviewPanel(document: document).frame(width: width)
            }
            .accessibilityIdentifier("terminal-preview-sidebar")
        }
    }
}

struct TerminalPreviewPanel: View {
    @ObservedObject var document: TerminalPreviewDocument
    var isDetachedWindow = false
    private let center = TerminalPreviewCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: document.content?.markdown != nil ? "doc.richtext" : "photo")
                Text(document.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                action("preview.copy", "doc.on.doc", document.copyContent)
                action(isDetachedWindow ? "preview.dock" : "preview.detach", isDetachedWindow ? "sidebar.right" : "arrow.up.forward.square") {
                    isDetachedWindow ? center.dock(document) : center.detach(document)
                }
                action("preview.close", "xmark") { center.close(document.sourceID) }
            }.padding(12)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.sourceTitle).font(.caption).foregroundStyle(.secondary)
                Text(document.url?.path ?? L10n.string("preview.selection"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            HStack {
                action("preview.refresh", "arrow.clockwise", document.reload)
                if document.content?.markdown != nil {
                    Toggle(L10n.string("preview.raw"), isOn: $document.raw).toggleStyle(.button)
                    if document.content?.remoteImages.isEmpty == false {
                        Button(L10n.string("preview.load_remote"), action: document.loadRemoteImages).font(.caption)
                    }
                } else if document.content?.imageData != nil {
                    action("preview.zoom_out", "minus.magnifyingglass") { document.fit = false; document.zoom = max(0.1, document.zoom / 1.25) }
                    Button(L10n.string("preview.fit")) { document.fit = true; document.zoom = 1 }
                    action("preview.zoom_in", "plus.magnifyingglass") { document.fit = false; document.zoom = min(8, document.zoom * 1.25) }
                }
                Spacer(minLength: 0)
                if document.loading { ProgressView().controlSize(.small) }
            }.buttonStyle(.borderless).padding(10)
            if let error = document.error ?? document.remoteError { Text(error).font(.caption).foregroundStyle(.secondary).padding(10) }
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("terminal-preview-panel")
    }

    @ViewBuilder private var preview: some View {
        if let content = document.content {
            if let markdown = content.markdown, document.raw {
                ScrollView([.horizontal, .vertical]) {
                    Text(markdown).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                }.accessibilityIdentifier("terminal-preview-raw")
            } else if let html = content.html {
                TerminalMarkdownWebView(html: html).accessibilityIdentifier("terminal-preview-markdown")
            } else if let data = content.imageData, let image = NSImage(data: data) {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        let fitScale = min(1, min(geometry.size.width / image.size.width, geometry.size.height / image.size.height))
                        let scale = document.fit ? fitScale : document.zoom
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                }.accessibilityIdentifier("terminal-preview-image")
            }
        } else { Spacer() }
    }

    private func action(_ key: String, _ icon: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: icon) }.buttonStyle(.borderless)
            .help(L10n.string(key)).accessibilityLabel(L10n.string(key))
    }
}

/// No JS, no network resources, no filesystem base URL, and no in-view navigation.
struct TerminalMarkdownWebView: NSViewRepresentable {
    let html: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else { decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel) }
        }
    }
}
