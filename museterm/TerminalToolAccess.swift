import Foundation
import Security

enum TerminalToolAccess {
    static let builtInClientID = "museterm-cli"
    static let keychainServiceName = "im.some.museterm.tool-access"
    static let auditFileName = "access-audit.jsonl"

    static var auditFile: URL {
        TerminalToolPaths.rootDirectory.appendingPathComponent(auditFileName)
    }

    static func isPaired(clientID: String = builtInClientID) -> Bool {
        !storedToken(clientID: clientID).isEmpty
    }

    @discardableResult
    static func pair(clientID: String = builtInClientID) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw MuseTermKeychainError(status: randomStatus)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let saved = try MuseTermKeychain.save(token, account: clientID, serviceName: keychainServiceName)
        if clientID == builtInClientID {
            MuseTermKeychain.delete(account: MuseTermLegacyCompatibility.legacyClientID, serviceName: keychainServiceName)
        }
        return saved
    }

    static func revoke(clientID: String = builtInClientID) {
        MuseTermKeychain.delete(account: clientID, serviceName: keychainServiceName)
        if clientID == builtInClientID {
            MuseTermKeychain.delete(account: MuseTermLegacyCompatibility.legacyClientID, serviceName: keychainServiceName)
        }
    }

    static func authorizes(clientID: String?, token: String?) -> Bool {
        guard
            let clientID = normalizedClientID(clientID),
            let token,
            !token.isEmpty,
            token.utf8.count <= 256
        else { return false }

        let expected = storedToken(clientID: clientID)
        guard !expected.isEmpty else { return false }
        return constantTimeEqual(expected, token)
    }

    private static func storedToken(clientID: String) -> String {
        let token = MuseTermKeychain.load(account: clientID, serviceName: keychainServiceName)
        guard token.isEmpty, clientID == builtInClientID else { return token }
        return MuseTermKeychain.load(account: MuseTermLegacyCompatibility.legacyClientID, serviceName: keychainServiceName)
    }

    static func recordAuthorization(clientID: String?, action: String, allowed: Bool) {
        let record = AuditRecord(
            timestamp: Date(),
            clientID: normalizedClientID(clientID) ?? "unpaired",
            action: action,
            result: allowed ? "authorized" : "denied"
        )
        guard let data = try? JSONEncoder.auditEncoder.encode(record) else { return }

        do {
            try TerminalToolPaths.ensureDirectories()
            if !FileManager.default.fileExists(atPath: auditFile.path) {
                FileManager.default.createFile(atPath: auditFile.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: auditFile)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
            try handle.close()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: auditFile.path
            )
        } catch {
            NSLog("MuseTerm tool access audit failed: \(error.localizedDescription)")
        }
    }

    private static func normalizedClientID(_ clientID: String?) -> String? {
        let value = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.count <= 80 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }

    private struct AuditRecord: Codable {
        let timestamp: Date
        let clientID: String
        let action: String
        let result: String
    }
}

private extension JSONEncoder {
    static var auditEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
