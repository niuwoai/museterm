import Foundation

enum TerminalLinkImageDownloadError: Error, Equatable {
    case badStatus(Int)
    case notAnImage(String?)
    case tooLarge
    case transport(String)
}

/// 下载网络图片到临时目录，好让系统图片查看器（"预览"不认网络地址）打开。
/// 有大小上限和超时，响应必须是 image/*，避免 ⌘+点击一个伪装成 .png 的大文件把磁盘写满。
final class TerminalLinkImageDownloader: NSObject, URLSessionDataDelegate {
    static let maxBytes: Int64 = 20 * 1024 * 1024
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 60
    /// 临时预览文件保留时长，过期的在下次下载时清理
    static let previewRetention: TimeInterval = 24 * 60 * 60
    static let previewDirectoryName = "MuseTermLinkPreviews"
    private static let fallbackFileName = "image"

    private let url: URL
    private let completion: (Result<URL, TerminalLinkImageDownloadError>) -> Void
    private var session: URLSession?
    private var receivedData = Data()
    private var mimeType: String?
    private var failure: TerminalLinkImageDownloadError?

    /// completion 在主线程回调；成功时给出本地文件 URL
    static func download(
        _ url: URL,
        completion: @escaping (Result<URL, TerminalLinkImageDownloadError>) -> Void
    ) {
        let downloader = TerminalLinkImageDownloader(url: url, completion: completion)
        downloader.start()
    }

    private init(url: URL, completion: @escaping (Result<URL, TerminalLinkImageDownloadError>) -> Void) {
        self.url = url
        self.completion = completion
    }

    private func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        // session 强引用 delegate，任务结束后 invalidate 释放这个环
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: url).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = .badStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }
        mimeType = response.mimeType?.lowercased()
        guard mimeType?.hasPrefix("image/") == true else {
            failure = .notAnImage(mimeType)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Self.maxBytes {
            failure = .tooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        if Int64(receivedData.count) > Self.maxBytes {
            failure = .tooLarge
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        self.session = nil
        let result: Result<URL, TerminalLinkImageDownloadError>
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(.transport(error.localizedDescription))
        } else {
            do {
                result = .success(try saveToPreviewFile())
            } catch {
                result = .failure(.transport(error.localizedDescription))
            }
        }
        let completion = self.completion
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func saveToPreviewFile() throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(Self.previewDirectoryName, isDirectory: true)
        Self.removeExpiredPreviews(in: root, fileManager: fileManager)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(Self.previewFileName(for: url, mimeType: mimeType))
        try receivedData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// 用 URL 里的文件名；没有扩展名时按 MIME 补一个，否则系统不知道用什么 App 打开
    static func previewFileName(for url: URL, mimeType: String?) -> String {
        let name = url.lastPathComponent
        let base = name.isEmpty || name == "/" ? fallbackFileName : name
        if !(base as NSString).pathExtension.isEmpty {
            return base
        }
        guard let subtype = mimeType?.split(separator: "/").last.map(String.init), !subtype.isEmpty else {
            return base
        }
        let ext = subtype == "jpeg" ? "jpg" : subtype.replacingOccurrences(of: "+xml", with: "")
        return "\(base).\(ext)"
    }

    private static func removeExpiredPreviews(in root: URL, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-previewRetention)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
