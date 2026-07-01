import Combine
import Darwin
import Foundation

struct LocalListeningPort: Identifiable, Equatable, Sendable {
    var pid: Int32
    var command: String
    var protocolName: String
    var endpoint: String
    var port: Int
    var serviceName: String?
    var workingDirectory: String?

    nonisolated var id: String {
        "\(pid)-\(protocolName)-\(endpoint)"
    }

    nonisolated var localURL: URL? {
        URL(string: "http://127.0.0.1:\(port)")
    }

    nonisolated func matchesSearch(_ query: String) -> Bool {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }
        guard !tokens.isEmpty else { return true }

        let haystack = searchableParts
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return tokens.allSatisfy { token in
            haystack.localizedCaseInsensitiveContains(token)
        }
    }

    private nonisolated var searchableParts: [String] {
        var parts = [
            "\(pid)",
            command,
            protocolName,
            endpoint,
            "\(port)"
        ]
        if let serviceName {
            parts.append(serviceName)
        }
        if let workingDirectory {
            parts.append(workingDirectory)
            parts.append(URL(fileURLWithPath: workingDirectory).lastPathComponent)
        }
        return parts
    }
}

private enum LocalServiceScannerError: Error, Sendable {
    case lsofUnavailable
}

@MainActor
final class LocalServiceScanner: ObservableObject {
    @Published private(set) var ports: [LocalListeningPort] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage = ""
    @Published private(set) var updatedAt: Date?

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = ""

        Task {
            do {
                ports = try await Self.scanListeningPorts()
                updatedAt = Date()
            } catch {
                if let scannerError = error as? LocalServiceScannerError {
                    errorMessage = scannerError.localizedMessage
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            isScanning = false
        }
    }

    private static func scanListeningPorts() async throws -> [LocalListeningPort] {
        try await Task.detached {
            try runLsof()
        }.value
    }

    private nonisolated static func runLsof() throws -> [LocalListeningPort] {
        let executable = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalServiceScannerError.lsofUnavailable
        }

        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = executable
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcPn"]
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0, data.isEmpty {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                throw NSError(
                    domain: "MuseTerm.LocalServiceScanner",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
            return []
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        let ports = parseLsofFields(text)
        let workingDirectories = processWorkingDirectories(for: Set(ports.map(\.pid)))
        return ports.map { port in
            var enriched = port
            enriched.serviceName = serviceName(for: port.port, protocolName: port.protocolName)
            enriched.workingDirectory = workingDirectories[port.pid]
            return enriched
        }
    }

    nonisolated static func parseLsofFields(_ text: String) -> [LocalListeningPort] {
        var currentPID: Int32?
        var currentCommand = ""
        var currentProtocol = "TCP"
        var seen = Set<String>()
        var ports: [LocalListeningPort] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                currentPID = Int32(value)
                currentCommand = ""
                currentProtocol = "TCP"
            case "c":
                currentCommand = decodeLsofEscapedText(value)
            case "P":
                currentProtocol = value
            case "n":
                guard let currentPID,
                      let port = extractPort(from: value) else {
                    continue
                }
                let record = LocalListeningPort(
                    pid: currentPID,
                    command: currentCommand,
                    protocolName: currentProtocol.isEmpty ? "TCP" : currentProtocol,
                    endpoint: value,
                    port: port,
                    serviceName: nil,
                    workingDirectory: nil
                )
                guard seen.insert(record.id).inserted else { continue }
                ports.append(record)
            default:
                continue
            }
        }

        return ports.sorted { left, right in
            if left.port != right.port {
                return left.port < right.port
            }
            if left.command != right.command {
                return left.command.localizedCaseInsensitiveCompare(right.command) == .orderedAscending
            }
            return left.pid < right.pid
        }
    }

    private nonisolated static func extractPort(from endpoint: String) -> Int? {
        guard let separator = endpoint.lastIndex(of: ":") else { return nil }
        let suffix = endpoint[endpoint.index(after: separator)...]
        let digits = suffix.prefix { $0.isNumber }
        guard let port = Int(digits), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    private nonisolated static func processWorkingDirectories(for pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let executable = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return [:] }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [
            "-nP",
            "-a",
            "-d", "cwd",
            "-F", "pn",
            "-p", pids.sorted().map(String.init).joined(separator: ",")
        ]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }

        guard process.terminationStatus == 0 else { return [:] }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return parseWorkingDirectoryFields(text)
    }

    nonisolated static func parseWorkingDirectoryFields(_ text: String) -> [Int32: String] {
        var currentPID: Int32?
        var result: [Int32: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                currentPID = Int32(value)
            case "n":
                guard let currentPID, !value.isEmpty else { continue }
                result[currentPID] = decodeLsofEscapedText(value)
            default:
                continue
            }
        }

        return result
    }

    nonisolated static func decodeLsofEscapedText(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "\\",
               let nextIndex = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               nextIndex < text.endIndex {
                let marker = text[nextIndex]
                if marker == "x" || marker == "X",
                   let firstHexIndex = text.index(nextIndex, offsetBy: 1, limitedBy: text.endIndex),
                   let secondHexIndex = text.index(firstHexIndex, offsetBy: 1, limitedBy: text.endIndex),
                   secondHexIndex < text.endIndex,
                   let high = hexValue(text[firstHexIndex]),
                   let low = hexValue(text[secondHexIndex]) {
                    bytes.append((high << 4) | low)
                    index = text.index(after: secondHexIndex)
                    continue
                }

                if let firstOctal = octalValue(marker) {
                    var value = firstOctal
                    var consumedEnd = nextIndex
                    var consumedCount = 1
                    while consumedCount < 3,
                          let candidateIndex = text.index(consumedEnd, offsetBy: 1, limitedBy: text.endIndex),
                          candidateIndex < text.endIndex,
                          let digit = octalValue(text[candidateIndex]) {
                        value = (value << 3) | digit
                        consumedEnd = candidateIndex
                        consumedCount += 1
                    }
                    bytes.append(value)
                    index = text.index(after: consumedEnd)
                    continue
                }
            }

            bytes.append(contentsOf: String(text[index]).utf8)
            index = text.index(after: index)
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private nonisolated static func hexValue(_ character: Character) -> UInt8? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return nil
        }
        switch scalar.value {
        case 48...57:
            return UInt8(scalar.value - 48)
        case 65...70:
            return UInt8(scalar.value - 55)
        case 97...102:
            return UInt8(scalar.value - 87)
        default:
            return nil
        }
    }

    private nonisolated static func octalValue(_ character: Character) -> UInt8? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return nil
        }
        guard (48...55).contains(scalar.value) else { return nil }
        return UInt8(scalar.value - 48)
    }

    nonisolated static func serviceName(for port: Int, protocolName: String = "TCP") -> String? {
        commonPortNames[port] ?? systemServiceName(for: port, protocolName: protocolName)
    }

    private nonisolated static func systemServiceName(for port: Int, protocolName: String) -> String? {
        guard let portValue = UInt16(exactly: port) else { return nil }
        let networkOrderPort = Int32(portValue.bigEndian)
        guard let service = getservbyport(networkOrderPort, protocolName.lowercased()) else {
            return nil
        }
        return String(cString: service.pointee.s_name)
    }

    private nonisolated static let commonPortNames: [Int: String] = [
        20: "ftp-data",
        21: "ftp",
        22: "ssh",
        25: "smtp",
        53: "dns",
        80: "http",
        110: "pop3",
        143: "imap",
        443: "https",
        465: "smtps",
        587: "smtp-submission",
        993: "imaps",
        995: "pop3s",
        3000: "node-dev",
        3306: "mysql",
        5000: "dev-server",
        5432: "postgres",
        5672: "amqp",
        5900: "vnc",
        6379: "redis",
        8000: "http-alt",
        8080: "http-alt",
        8443: "https-alt",
        9000: "app-server",
        9200: "elasticsearch",
        11211: "memcached",
        27017: "mongodb",
        24678: "vite-hmr",
        5173: "vite",
        5174: "vite"
    ]
}

private extension LocalServiceScannerError {
    var localizedMessage: String {
        switch self {
        case .lsofUnavailable:
            return L10n.string("task_panel.error_lsof_unavailable")
        }
    }
}
