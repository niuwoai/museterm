import Foundation

struct SessionTunnelPreset: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var targetHost: String
    var targetPort: Int
    var localPort: Int
    var lastUsedAt: Date
    var useCount: Int

    var configuration: SessionTunnelConfiguration {
        SessionTunnelConfiguration(
            name: name,
            targetHost: targetHost,
            targetPort: targetPort,
            localPort: localPort
        )
    }
}

enum SessionTunnelPresetStore {
    static let defaultsKey = "sessionTunnel.presets"
    static let maximumPresetCount = 12

    static func load(defaults: UserDefaults = .standard) -> [SessionTunnelPreset] {
        guard let data = defaults.data(forKey: defaultsKey),
              let presets = try? decoder.decode([SessionTunnelPreset].self, from: data) else {
            return []
        }
        return sorted(presets)
    }

    @discardableResult
    static func record(
        _ configuration: SessionTunnelConfiguration,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> [SessionTunnelPreset] {
        guard let validated = try? configuration.validated() else { return load(defaults: defaults) }
        var presets = load(defaults: defaults)
        if let index = presets.firstIndex(where: { $0.configuration == validated }) {
            presets[index].lastUsedAt = now
            presets[index].useCount += 1
        } else {
            presets.append(
                SessionTunnelPreset(
                    id: UUID(),
                    name: validated.name,
                    targetHost: validated.targetHost,
                    targetPort: validated.targetPort,
                    localPort: validated.localPort,
                    lastUsedAt: now,
                    useCount: 1
                )
            )
        }
        presets = Array(sorted(presets).prefix(maximumPresetCount))
        if let data = try? encoder.encode(presets) {
            defaults.set(data, forKey: defaultsKey)
        }
        return presets
    }

    private static func sorted(_ presets: [SessionTunnelPreset]) -> [SessionTunnelPreset] {
        presets.sorted {
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }
            return $0.useCount > $1.useCount
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
