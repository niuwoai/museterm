import Combine
import Foundation

struct PersistentCommandStatsSnapshot: Codable, Equatable {
    var dateKey: String
    var commandCount: Int
    var failureCount: Int
    var longestDurationMilliseconds: Int?
    var countedCommandIDs: Set<String>

    static func empty(dateKey: String = Self.currentDateKey()) -> PersistentCommandStatsSnapshot {
        PersistentCommandStatsSnapshot(
            dateKey: dateKey,
            commandCount: 0,
            failureCount: 0,
            longestDurationMilliseconds: nil,
            countedCommandIDs: []
        )
    }

    static func currentDateKey(date: Date = Date()) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@MainActor
final class PersistentCommandStatsStore: ObservableObject {
    @Published private(set) var today: PersistentCommandStatsSnapshot = .empty()

    init() {
        today = loadToday()
    }

    func record(blocks: [TerminalCommandBlock]) {
        // 内存快照仍是当天时直接复用，定时刷新不再每次读盘解码；跨天时才回读磁盘。
        let currentKey = PersistentCommandStatsSnapshot.currentDateKey()
        var snapshot = today.dateKey == currentKey ? today : loadToday()
        var didChange = false

        for block in blocks where block.endedAt != nil {
            let id = block.id.uuidString
            guard snapshot.countedCommandIDs.insert(id).inserted else { continue }
            snapshot.commandCount += 1
            if let exitCode = block.exitCode, exitCode != 0 {
                snapshot.failureCount += 1
            }
            if let duration = block.durationMilliseconds {
                snapshot.longestDurationMilliseconds = max(snapshot.longestDurationMilliseconds ?? 0, duration)
            }
            didChange = true
        }

        if didChange {
            save(snapshot)
        }
        if today != snapshot {
            today = snapshot
        }
    }

    private func loadToday() -> PersistentCommandStatsSnapshot {
        let currentKey = PersistentCommandStatsSnapshot.currentDateKey()
        guard let url = try? Self.statsURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PersistentCommandStatsSnapshot.self, from: data),
              snapshot.dateKey == currentKey else {
            return .empty(dateKey: currentKey)
        }
        return snapshot
    }

    private func save(_ snapshot: PersistentCommandStatsSnapshot) {
        do {
            let url = try Self.statsURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Local statistics are best-effort; terminal work should never be blocked by persistence.
        }
    }

    private static func statsURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("Stats", isDirectory: true)
            .appendingPathComponent("daily-command-stats.json")
    }
}
