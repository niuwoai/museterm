import Foundation

enum SessionTunnelHelperPlatform: String, CaseIterable, Equatable {
    case linuxAMD64 = "linux-amd64"
    case linuxARM64 = "linux-arm64"
    case darwinAMD64 = "darwin-amd64"
    case darwinARM64 = "darwin-arm64"

    var resourceName: String {
        "museterm-tunnel-\(rawValue)"
    }

    static func detect(operatingSystem: String, architecture: String) -> Self? {
        let normalizedOS = operatingSystem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedArchitecture = architecture
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch (normalizedOS, normalizedArchitecture) {
        case ("linux", "x86_64"), ("linux", "amd64"):
            return .linuxAMD64
        case ("linux", "aarch64"), ("linux", "arm64"):
            return .linuxARM64
        case ("darwin", "x86_64"), ("darwin", "amd64"):
            return .darwinAMD64
        case ("darwin", "arm64"), ("darwin", "aarch64"):
            return .darwinARM64
        default:
            return nil
        }
    }

    static func detect(probeData: String) -> Self? {
        let components = probeData.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }
        return detect(
            operatingSystem: String(components[0]),
            architecture: String(components[1])
        )
    }
}

enum SessionTunnelBundledHelper {
    static let resourceSubdirectory = "SessionTunnelHelpers"

    struct Artifact: Equatable {
        let data: Data
        let isGzipCompressed: Bool
    }

    static func data(
        for platform: SessionTunnelHelperPlatform,
        bundle: Bundle = .main
    ) -> Data? {
        let candidates = [
            bundle.url(
                forResource: platform.resourceName,
                withExtension: nil,
                subdirectory: resourceSubdirectory
            ),
            bundle.url(forResource: platform.resourceName, withExtension: nil),
            bundle.resourceURL?
                .appendingPathComponent(resourceSubdirectory, isDirectory: true)
                .appendingPathComponent(platform.resourceName, isDirectory: false)
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    static func compressedData(
        for platform: SessionTunnelHelperPlatform,
        bundle: Bundle = .main
    ) -> Data? {
        let candidates = [
            bundle.url(
                forResource: platform.resourceName,
                withExtension: "gz",
                subdirectory: resourceSubdirectory
            ),
            bundle.url(forResource: platform.resourceName, withExtension: "gz"),
            bundle.resourceURL?
                .appendingPathComponent(resourceSubdirectory, isDirectory: true)
                .appendingPathComponent("\(platform.resourceName).gz", isDirectory: false),
            bundle.resourceURL?
                .appendingPathComponent("\(platform.resourceName).gz", isDirectory: false)
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    static func artifact(
        for platform: SessionTunnelHelperPlatform,
        bundle: Bundle = .main
    ) -> Artifact? {
        if let data = compressedData(for: platform, bundle: bundle) {
            return Artifact(data: data, isGzipCompressed: true)
        }
        if let data = data(for: platform, bundle: bundle) {
            return Artifact(data: data, isGzipCompressed: false)
        }
        return nil
    }

    static func platformProbeCommand(token: String) -> String {
        let script = [
            "_mst_os=$(uname -s 2>/dev/null || printf unknown)",
            "_mst_arch=$(uname -m 2>/dev/null || printf unknown)",
            "printf '\\n{\"v\":1,\"token\":\"%s\",\"type\":\"platform\",\"data\":\"%s|%s\"}\\n' \(SessionTunnelRemoteHelper.shellQuoted(token)) \"$_mst_os\" \"$_mst_arch\""
        ].joined(separator: ";")
        return "/bin/sh -c \(SessionTunnelRemoteHelper.shellQuoted(script))\n"
    }

    static func platformProbeInputBytes(token: String) -> [UInt8] {
        terminalInputBytes(platformProbeCommand(token: token))
    }

    static func loaderCommand(
        configuration: SessionTunnelConfiguration,
        token: String,
        payloadByteCount: Int,
        isGzipCompressed: Bool
    ) -> String {
        let temporaryTemplate = "${TMPDIR:-/tmp}/.museterm-tunnel-\(token).XXXXXX"
        let payloadTemporaryTemplate = "${TMPDIR:-/tmp}/.museterm-tunnel-\(token).payload.XXXXXX"
        let encodedTemporaryTemplate = "${TMPDIR:-/tmp}/.museterm-tunnel-\(token).b64.XXXXXX"
        let readyFrame = "{\"v\":1,\"token\":\"\(token)\",\"type\":\"loader_ready\"}"
        let restoredFrameFormat = "{\"v\":1,\"token\":\"\(token)\",\"type\":\"shell_ready\",\"data\":\"%s\"}"
        var script = [
            "umask 077",
            "_mst_old=$(stty -g) || exit 71",
            "_mst_tmp=$(mktemp \"\(temporaryTemplate)\") || exit 72",
            "_mst_payload=$(mktemp \"\(payloadTemporaryTemplate)\") || exit 72",
            "_mst_b64=$(mktemp \"\(encodedTemporaryTemplate)\") || exit 72",
            "_mst_restore(){ stty \"$_mst_old\" >/dev/null 2>&1; rm -f \"$_mst_tmp\" \"$_mst_payload\" \"$_mst_b64\"; }",
            "trap '_mst_restore' EXIT HUP INT TERM",
            "stty raw -echo || exit 73",
            "printf '\\n%s\\n' \(SessionTunnelRemoteHelper.shellQuoted(readyFrame))",
            "(head -c \(payloadByteCount) > \"$_mst_b64\" 2>/dev/null || dd bs=1 count=\(payloadByteCount) of=\"$_mst_b64\" 2>/dev/null) || exit 74",
            "(base64 -d \"$_mst_b64\" > \"$_mst_payload\" 2>/dev/null || base64 -D -i \"$_mst_b64\" -o \"$_mst_payload\" 2>/dev/null || openssl base64 -d -A -in \"$_mst_b64\" -out \"$_mst_payload\" 2>/dev/null) || exit 74"
        ]
        if isGzipCompressed {
            script.append("(gzip -dc \"$_mst_payload\" > \"$_mst_tmp\" 2>/dev/null || gunzip -c \"$_mst_payload\" > \"$_mst_tmp\" 2>/dev/null) || exit 74")
        } else {
            script.append("mv \"$_mst_payload\" \"$_mst_tmp\" || exit 74")
        }
        script.append(contentsOf: [
            "chmod 700 \"$_mst_tmp\" || exit 75",
            "\"$_mst_tmp\" \(SessionTunnelRemoteHelper.shellQuoted(configuration.targetHost)) \(SessionTunnelRemoteHelper.shellQuoted(String(configuration.targetPort))) \(SessionTunnelRemoteHelper.shellQuoted(token))",
            "_mst_code=$?",
            "_mst_restore",
            "trap - EXIT HUP INT TERM",
            "printf '\\n\(restoredFrameFormat)\\n' \"$_mst_code\"",
            "exit \"$_mst_code\""
        ])
        let shellScript = script.joined(separator: ";")
        return "/bin/sh -c \(SessionTunnelRemoteHelper.shellQuoted(shellScript))\n"
    }

    static func loaderInputBytes(
        configuration: SessionTunnelConfiguration,
        token: String,
        payloadByteCount: Int,
        isGzipCompressed: Bool = false
    ) -> [UInt8] {
        terminalInputBytes(
            loaderCommand(
                configuration: configuration,
                token: token,
                payloadByteCount: payloadByteCount,
                isGzipCompressed: isGzipCompressed
            )
        )
    }

    static func helperPayload(_ payload: Data) -> [UInt8] {
        Array(payload.base64EncodedString().utf8)
    }

    static func terminalInputBytes(_ command: String) -> [UInt8] {
        var bytes = Array(command.utf8)
        if bytes.last == 0x0A {
            bytes[bytes.count - 1] = 0x0D
        }
        return bytes
    }
}
