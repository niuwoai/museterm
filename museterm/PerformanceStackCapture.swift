import Foundation
import os

nonisolated enum PerformanceStackCapture {
    static let durationSeconds = 2
    private static let symbolicationTimeout: TimeInterval = 120
    private static let maxRawBytes = 8 * 1024 * 1024
    private static let logger = Logger(subsystem: "im.some.museterm", category: "performance")

    static func capture(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        executableURL: URL? = Bundle.main.executableURL
    ) async throws -> String? {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = try openUnlinkedFile(in: directory)
        defer { file.closeFile() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(pid), String(durationSeconds), "-mayDie", "-file", "/dev/stdout"]
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = file
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let deadline = ProcessInfo.processInfo.systemUptime + Double(durationSeconds) + symbolicationTimeout
        while process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.timeout }
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw CaptureError.sampleFailed(process.terminationStatus) }
        try file.seek(toOffset: 0)
        guard let data = try file.read(upToCount: maxRawBytes + 1), data.count <= maxRawBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return PerformanceStackRedactor.redact(text, executableURL: executableURL)
    }

    private static func openUnlinkedFile(in directory: URL) throws -> FileHandle {
        let output = directory.appendingPathComponent("report.txt")
        do {
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CaptureError.cannotCreateOutput
            }
            let file = try FileHandle(forUpdating: output)
            // The child inherits an open descriptor. No named file ever contains a raw report.
            try FileManager.default.removeItem(at: directory)
            return file
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { logger.error("Could not remove empty sample directory") }
            throw error
        }
    }

    enum CaptureError: Error {
        case cannotCreateOutput
        case timeout
        case sampleFailed(Int32)
    }
}

nonisolated enum PerformanceStackRedactor {
    // Bound encoded JSON even in the worst case of escaping every byte.
    private static let maxReportBytes = 512 * 1024
    private static let imagePattern = #/^\s*(0x[0-9a-fA-F]+)\s+-\s+(0x[0-9a-fA-F]+)\s+\+?([^ ]+)\s+.*?<([0-9a-fA-F-]{36})>\s+(.+)$/#
    private static let threadPattern = #/^(\s*[+!|:\- ]*\d+\s+Thread_\d+)/#
    private static let framePattern = #/^([\t +!|:\-]*\d+\s+)(.+?)\s+\(in ([^)]+)\).*\[(0x[0-9a-fA-F]+)\]\s*$/#
    private static let imageNamePattern = #/^[A-Za-z0-9._+-]+$/#
    private static let footprintPattern = #/^Physical footprint(?: \(peak\))?:\s+\d+(?:\.\d+)?[KMGTP]?(?:B)?$/#

    static func redact(_ text: String, executableURL: URL?) -> String? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let callGraph = lines.firstIndex(of: "Call graph:"),
              let images = lines.firstIndex(of: "Binary Images:"), callGraph < images else { return nil }
        let executablePath = executableURL?.resolvingSymlinksInPath().path
        #if DEBUG
        let debugImagePath = executablePath.map { $0 + ".debug.dylib" }
        #else
        let debugImagePath: String? = nil
        #endif
        let trustedImages = lines[(images + 1)...].compactMap { line -> Image? in
            guard let match = line.wholeMatch(of: imagePattern), match.3.wholeMatch(of: imageNamePattern) != nil,
                  let start = UInt64(match.1.dropFirst(2), radix: 16),
                  let end = UInt64(match.2.dropFirst(2), radix: 16), start <= end else { return nil }
            let path = String(match.5)
            guard path == executablePath || path == debugImagePath
                    || path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/lib/") else { return nil }
            // Keep identifiers and addresses for symbolication, but omit image paths and versions.
            return Image(name: String(match.3), start: start, end: end,
                         line: "       \(match.1) - \(match.2)  \(match.3) <\(match.4)>")
        }
        let orderedImages = trustedImages.sorted { $0.start < $1.start }
        var graph = ""
        var sawFrame = false
        for line in lines[(callGraph + 1)..<images] {
            if line.isEmpty { break }
            let filtered: String
            if let thread = line.prefixMatch(of: threadPattern) {
                // Queue and thread labels can be set by callers and can contain local data.
                filtered = String(thread.1)
            } else if let frame = line.wholeMatch(of: framePattern),
                      let address = UInt64(frame.4.dropFirst(2), radix: 16) {
                sawFrame = true
                // Samples may label a frame Foundation while listing the image as com.apple.Foundation.
                let image = image(at: address, in: orderedImages)
                let symbol = frame.2
                if let image, !symbol.contains("/"), !symbol.contains("\\") {
                    filtered = "\(frame.1)\(symbol)  (in \(image.name))  [\(frame.4)]"
                } else {
                    filtered = "\(frame.1)???  [\(frame.4)]"
                }
            } else {
                continue
            }
            guard graph.utf8.count + filtered.utf8.count + 1 <= maxReportBytes else { break }
            graph += filtered + "\n"
        }
        guard sawFrame, !graph.isEmpty else { return nil }
        let footprint = lines[..<callGraph].filter { $0.wholeMatch(of: footprintPattern) != nil }.joined(separator: "\n")
        let imageList = trustedImages.map(\.line).joined(separator: "\n")
        let text = "\(footprint)\n\nCall graph:\n\(graph)\nBinary Images:\n\(imageList)\n"
        guard text.utf8.count <= maxReportBytes * 2 else { return nil }
        return text
    }

    private static func image(at address: UInt64, in images: [Image]) -> Image? {
        var lower = 0
        var upper = images.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if images[middle].start <= address { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0, address <= images[lower - 1].end else { return nil }
        return images[lower - 1]
    }

    private struct Image {
        let name: String
        let start: UInt64
        let end: UInt64
        let line: String
    }
}
