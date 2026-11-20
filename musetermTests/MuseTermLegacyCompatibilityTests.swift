import Foundation
import Testing
@testable import museterm

struct MuseTermLegacyCompatibilityTests {
    @Test func freshInstallUsesNewDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(MuseTermLegacyCompatibility.directory("Runtime", base: base) ==
            base.appendingPathComponent("MuseTerm/Runtime", isDirectory: true))
    }

    @Test func legacyRuntimeIsKeptInPlace() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = base.appendingPathComponent("QTerm/Runtime", isDirectory: true)
        try manager.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        #expect(MuseTermLegacyCompatibility.directory("Runtime", base: base) == legacy)
        #expect(manager.fileExists(atPath: legacy.path))
    }

    @Test func existingNewDirectoryWinsWithoutMerging() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let current = base.appendingPathComponent("MuseTerm/Tools", isDirectory: true)
        try manager.createDirectory(at: current, withIntermediateDirectories: true)
        try manager.createDirectory(at: base.appendingPathComponent("QTerm/Tools"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        #expect(MuseTermLegacyCompatibility.directory("Tools", base: base) == current)
    }
}
