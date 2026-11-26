import Foundation
import MachO
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
        let applicationImageAddresses: Set<UInt64> = pid == ProcessInfo.processInfo.processIdentifier
            ? loadedApplicationImageAddresses() : []
        return PerformanceStackRedactor.redact(text, executableURL: executableURL,
                                               applicationImageAddresses: applicationImageAddresses)
    }

    private static func loadedApplicationImageAddresses() -> Set<UInt64> {
        var addresses: Set<UInt64> = []
        if let header = _dyld_get_image_header(0) {
            addresses.insert(UInt64(UInt(bitPattern: header)))
        }
        #if DEBUG
        if let executableURL = Bundle.main.executableURL {
            let debugImage = executableURL.appendingPathExtension("debug.dylib").resolvingSymlinksInPath()
            for index in 0..<_dyld_image_count() {
                guard let name = _dyld_get_image_name(index), let path = String(validatingCString: name),
                      path.hasSuffix("/" + debugImage.lastPathComponent),
                      URL(fileURLWithPath: path).resolvingSymlinksInPath().path == debugImage.path,
                      let header = _dyld_get_image_header(index) else { continue }
                addresses.insert(UInt64(UInt(bitPattern: header)))
                break
            }
        }
        #endif
        return addresses
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
    // A 1 MiB stack fits under the receiver's 8 MiB JSON cap even at six bytes per escaped byte.
    private static let maxReportBytes = 1024 * 1024
    private static let truncationNotice = "\n[Call graph truncated to fit report size limit]\n"
    private static let imagePattern = #/^\s*(0x[0-9a-fA-F]+)\s+-\s+(0x[0-9a-fA-F]+)\s+\+?([^ ]+)\s+.*?<([0-9a-fA-F-]{36})>\s+(.+)$/#
    private static let threadPattern = #/^(\s*[+!|:\- ]*\d+\s+Thread_\d+)/#
    // Debug frames can include a source location after the instruction address. Never retain it.
    private static let framePattern = #/^([\t +!|:\-]*\d+\s+)(.+?)\s+\(in [^)]+\).*?\[(0x[0-9a-fA-F]+)\](?:[ \t]+.*)?$/#
    private static let imageNamePattern = #/^[A-Za-z0-9._+-]+$/#
    private static let footprintPattern = #/^Physical footprint(?: \(peak\))?:\s+\d+(?:\.\d+)?[KMGTP]?(?:B)?$/#

    static func redact(_ text: String, executableURL: URL?, applicationImageAddresses: Set<UInt64> = []) -> String? {
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
            // macOS may replace a temporary directory component with `*`. For self-samples,
            // trust the start address observed by dyld rather than guessing at a redacted path.
            guard applicationImageAddresses.contains(start) || path == executablePath || path == debugImagePath
                    || path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/lib/") else { return nil }
            // Keep identifiers and addresses for symbolication, but omit image paths and versions.
            return Image(name: String(match.3), start: start, end: end,
                         line: "       \(match.1) - \(match.2)  \(match.3) <\(match.4)>")
        }
        let orderedImages = trustedImages.sorted { $0.start < $1.start }
        var threads: [SampleThread] = []
        for line in lines[(callGraph + 1)..<images] {
            if line.hasPrefix("Total number in stack") || line.hasPrefix("Sort by top of stack") { break }
            if let thread = line.prefixMatch(of: threadPattern) {
                // Queue and thread labels can be set by callers and can contain local data.
                threads.append(SampleThread(header: String(thread.1) + "\n"))
                continue
            }
            guard !threads.isEmpty, let frame = line.wholeMatch(of: framePattern),
                  let address = UInt64(frame.3.dropFirst(2), radix: 16) else { continue }
            // Samples may label a frame Foundation while listing the image as com.apple.Foundation.
            let image = image(at: address, in: orderedImages)
            let symbol = frame.2
            let filtered: String
            if let image, !symbol.contains("/"), !symbol.contains("\\") {
                filtered = "\(frame.1)\(symbol)  (in \(image.name))  [\(frame.3)]\n"
            } else {
                filtered = "\(frame.1)???  [\(frame.3)]\n"
            }
            threads[threads.count - 1].append(filtered)
        }
        guard threads.contains(where: { !$0.frames.isEmpty }) else { return nil }
        let footprint = lines[..<callGraph].filter { $0.wholeMatch(of: footprintPattern) != nil }.joined(separator: "\n")
        let prefix = "\(footprint)\n\nCall graph:\n"
        let imageList = trustedImages.map(\.line).joined(separator: "\n")
        let suffix = "\nBinary Images:\n\(imageList)\n"
        guard let graph = renderGraph(threads, budget: maxReportBytes - prefix.utf8.count - suffix.utf8.count) else {
            return nil
        }
        return prefix + graph + suffix
    }

    private static func renderGraph(_ threads: [SampleThread], budget: Int) -> String? {
        let totalBytes = threads.reduce(0) { $0 + $1.minimumBytes + $1.extraBytes }
        let truncated = totalBytes > budget
        var frameCounts = threads.map { $0.frames.count }
        if truncated {
            // Reserve every header and first frame before sharing the remaining space. Small threads
            // go first so their unused shares can be reused by larger threads.
            var remaining = budget - truncationNotice.utf8.count - threads.reduce(0) { $0 + $1.minimumBytes }
            guard remaining >= 0 else { return nil }
            let indices = threads.indices.sorted { threads[$0].extraBytes < threads[$1].extraBytes }
            for (position, index) in indices.enumerated() {
                let frames = threads[index].frames
                var allowance = remaining / (indices.count - position)
                var included = min(1, frames.count)
                for frame in frames.dropFirst() {
                    guard frame.bytes <= allowance else { break }
                    included += 1
                    allowance -= frame.bytes
                    remaining -= frame.bytes
                }
                frameCounts[index] = included
            }
        }
        var graph = ""
        graph.reserveCapacity(min(totalBytes, budget))
        for (thread, count) in zip(threads, frameCounts) {
            graph += thread.header
            for frame in thread.frames.prefix(count) { graph += frame.text }
        }
        if truncated { graph += truncationNotice }
        return graph
    }

    private struct SampleThread {
        let header: String
        var frames: [(text: String, bytes: Int)] = []
        var extraBytes = 0

        var minimumBytes: Int { header.utf8.count + (frames.first?.bytes ?? 0) }

        mutating func append(_ text: String) {
            let bytes = text.utf8.count
            if !frames.isEmpty { extraBytes += bytes }
            frames.append((text, bytes))
        }
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
