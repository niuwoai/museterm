import Darwin
import XCTest
@testable import museterm

@MainActor
final class SSHConnectionProfileTests: XCTestCase {
    func testSSHProfileDecodesLegacyJSONWithoutFavoriteFlag() throws {
        let data = try XCTUnwrap("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy",
          "host": "legacy.example.com",
          "user": "deploy",
          "port": 22
        }
        """.data(using: .utf8))

        let profile = try JSONDecoder().decode(SSHConnectionProfile.self, from: data)

        XCTAssertFalse(profile.isFavorite)
        XCTAssertFalse(profile.normalized.isFavorite)
        XCTAssertNil(profile.lastConnectedAt)
        XCTAssertEqual(profile.connectionOpenCount, 0)
    }

    func testSSHProfileSearchMatchesFavoriteState() {
        let profile = SSHConnectionProfile(
            name: "Production",
            host: "prod.example.com",
            isFavorite: true
        )

        XCTAssertTrue(profile.matchesSearch("favorite"))
        XCTAssertTrue(profile.matchesSearch("star"))
    }

    func testSSHProfileSearchMatchesRecentState() {
        let profile = SSHConnectionProfile(
            name: "Production",
            host: "prod.example.com",
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            connectionOpenCount: 2
        )

        XCTAssertTrue(profile.matchesSearch("recent"))
    }

    func testSSHProfileBuildsRecentConnectionSummary() throws {
        let profile = SSHConnectionProfile(
            name: "Production",
            host: "prod.example.com",
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            connectionOpenCount: 3
        )

        let summary = try XCTUnwrap(profile.recentConnectionSummary)

        XCTAssertTrue(summary.contains("3"))
    }

    func testSSHConnectionStorePersistsFavoriteToggle() throws {
        let suiteName = "museterm.favorite.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHConnectionStore(defaults: defaults)
        let profile = SSHConnectionProfile(name: "Production", host: "prod.example.com")

        store.upsert(profile)
        let storedProfile = try XCTUnwrap(store.profiles.first)
        store.toggleFavorite(storedProfile)

        XCTAssertTrue(store.profiles.first?.isFavorite == true)
        let reloadedStore = SSHConnectionStore(defaults: defaults)
        XCTAssertTrue(reloadedStore.profiles.first?.isFavorite == true)
    }

    func testSSHConnectionStoreRecordsRecentConnection() throws {
        let suiteName = "museterm.recent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHConnectionStore(defaults: defaults)
        let profile = SSHConnectionProfile(name: "Production", host: "prod.example.com")
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        store.upsert(profile)
        let storedProfile = try XCTUnwrap(store.profiles.first)
        let firstOpen = store.recordConnection(storedProfile, at: firstDate)
        let secondOpen = store.recordConnection(firstOpen, at: secondDate)

        XCTAssertEqual(secondOpen.lastConnectedAt, secondDate)
        XCTAssertEqual(secondOpen.connectionOpenCount, 2)
        let reloadedStore = SSHConnectionStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.profiles.first?.lastConnectedAt, secondDate)
        XCTAssertEqual(reloadedStore.profiles.first?.connectionOpenCount, 2)
    }

    func testSSHConnectionStoreClearsRecentConnection() throws {
        let suiteName = "museterm.recent-clear.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHConnectionStore(defaults: defaults)
        let profile = SSHConnectionProfile(
            name: "Production",
            host: "prod.example.com",
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            connectionOpenCount: 2
        )

        store.upsert(profile)
        let storedProfile = try XCTUnwrap(store.profiles.first)
        store.clearRecentConnection(storedProfile)

        XCTAssertNil(store.profiles.first?.lastConnectedAt)
        XCTAssertEqual(store.profiles.first?.connectionOpenCount, 0)
        let reloadedStore = SSHConnectionStore(defaults: defaults)
        XCTAssertNil(reloadedStore.profiles.first?.lastConnectedAt)
        XCTAssertEqual(reloadedStore.profiles.first?.connectionOpenCount, 0)
    }

    func testSSHConfigAddsDefaultKeepAliveOptions() {
        let profile = SSHConnectionProfile(host: "example.com", user: "deploy")
        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("  ServerAliveInterval 30"))
        XCTAssertTrue(config.contains("  ServerAliveCountMax 6"))
    }

    func testSSHConfigAddsKeepAliveOptionsToJumpHosts() {
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            host: "target.internal",
            user: "deploy",
            jumpHosts: [
                SSHJumpHost(name: "bastion", host: "bastion.internal", user: "ops", port: 22),
                SSHJumpHost(name: "relay", host: "relay.internal", user: "ops", port: 2222)
            ],
            keepAliveEnabled: true,
            keepAliveIntervalSeconds: 20,
            keepAliveCountMax: 4
        )

        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("""
Host museterm-22222222-2222-2222-2222-222222222222-jump-1
  HostName bastion.internal
  Port 22
  User ops
  ServerAliveInterval 20
  ServerAliveCountMax 4
"""))
        XCTAssertTrue(config.contains("""
Host museterm-22222222-2222-2222-2222-222222222222-jump-2
  HostName relay.internal
  Port 2222
  User ops
  ProxyJump museterm-22222222-2222-2222-2222-222222222222-jump-1
  ServerAliveInterval 20
  ServerAliveCountMax 4
"""))
    }

    func testSSHConfigUsesManualKeepAliveOptionsForJumpHosts() {
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            host: "target.internal",
            user: "deploy",
            jumpHosts: [
                SSHJumpHost(name: "bastion", host: "bastion.internal", user: "ops", port: 22)
            ],
            extraOptions: [
                "ServerAliveInterval 12"
            ],
            keepAliveEnabled: true,
            keepAliveIntervalSeconds: 30,
            keepAliveCountMax: 5
        )

        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("""
Host museterm-33333333-3333-3333-3333-333333333333-jump-1
  HostName bastion.internal
  Port 22
  User ops
  ServerAliveInterval 12
  ServerAliveCountMax 5
"""))
    }

    func testSSHConfigDoesNotDuplicateManualKeepAliveOptions() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            extraOptions: [
                "ServerAliveInterval 15",
                "ServerAliveCountMax 2"
            ],
            keepAliveEnabled: true,
            keepAliveIntervalSeconds: 30,
            keepAliveCountMax: 6
        )
        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertFalse(config.contains("  ServerAliveInterval 30"))
        XCTAssertFalse(config.contains("  ServerAliveCountMax 6"))
        XCTAssertTrue(config.contains("  ServerAliveInterval 15"))
        XCTAssertTrue(config.contains("  ServerAliveCountMax 2"))
    }

    func testSSHConfigAddsConnectionReuseOptionsByDefault() {
        let profile = SSHConnectionProfile(host: "example.com", user: "deploy")
        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("  ControlMaster auto"))
        XCTAssertTrue(config.contains("  ControlPersist 10m"))
        XCTAssertTrue(config.contains("  ControlPath \"~/.ssh/museterm-cm-%C\""))
    }

    func testSSHConfigDoesNotDuplicateManualConnectionReuseOptions() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            extraOptions: [
                "ControlMaster no",
                "ControlPersist=30m",
                "ControlPath ~/.ssh/custom-%C"
            ],
            connectionReuseEnabled: true,
            connectionReusePersistMinutes: 10
        )
        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertFalse(config.contains("  ControlMaster auto"))
        XCTAssertFalse(config.contains("  ControlPersist 10m"))
        XCTAssertFalse(config.contains("  ControlPath \"~/.ssh/museterm-cm-%C\""))
        XCTAssertTrue(config.contains("  ControlMaster no"))
        XCTAssertTrue(config.contains("  ControlPersist=30m"))
        XCTAssertTrue(config.contains("  ControlPath ~/.ssh/custom-%C"))
    }

    func testSSHConfigRendersPortForwards() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            portForwards: [
                SSHPortForward(
                    kind: .local,
                    bindHost: "",
                    bindPort: 8080,
                    destinationHost: "127.0.0.1",
                    destinationPort: 80
                ),
                SSHPortForward(
                    kind: .remote,
                    bindHost: "0.0.0.0",
                    bindPort: 9000,
                    destinationHost: "127.0.0.1",
                    destinationPort: 9000
                ),
                SSHPortForward(kind: .dynamic, bindHost: "127.0.0.1", bindPort: 1080)
            ]
        )
        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("  ExitOnForwardFailure yes"))
        XCTAssertTrue(config.contains("  LocalForward 8080 127.0.0.1:80"))
        XCTAssertTrue(config.contains("  RemoteForward 0.0.0.0:9000 127.0.0.1:9000"))
        XCTAssertTrue(config.contains("  DynamicForward 127.0.0.1:1080"))
    }

    func testSSHConfigRendersIPv6PortForwardEndpointsWithBrackets() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            portForwards: [
                SSHPortForward(
                    kind: .local,
                    bindHost: "::1",
                    bindPort: 8443,
                    destinationHost: "2001:db8::20",
                    destinationPort: 443
                ),
                SSHPortForward(
                    kind: .remote,
                    bindHost: "",
                    bindPort: 9443,
                    destinationHost: "2001:db8::30",
                    destinationPort: 9443
                ),
                SSHPortForward(kind: .dynamic, bindHost: "::", bindPort: 1080)
            ]
        )
        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("  LocalForward [::1]:8443 [2001:db8::20]:443"))
        XCTAssertTrue(config.contains("  RemoteForward 9443 [2001:db8::30]:9443"))
        XCTAssertTrue(config.contains("  DynamicForward [::]:1080"))
    }

    func testSSHConfigPreviewDescribesGeneratedConfig() {
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Production",
            host: "prod.internal",
            user: "deploy",
            jumpHosts: [
                SSHJumpHost(name: "Bastion", host: "bastion.internal", user: "jump", port: 2200)
            ]
        )

        let preview = SSHConfigMaterializer.preview(for: profile)

        XCTAssertEqual(preview.targetAlias, "museterm-11111111-1111-1111-1111-111111111111-target")
        XCTAssertEqual(preview.hostBlockCount, 2)
        XCTAssertEqual(preview.lineCount, preview.config.split(whereSeparator: \.isNewline).count)
        XCTAssertEqual(preview.commands.count, 4)
        XCTAssertTrue(preview.configURL.path.hasSuffix("11111111-1111-1111-1111-111111111111.conf"))
        XCTAssertTrue(preview.config.contains("Host museterm-11111111-1111-1111-1111-111111111111-jump-1"))
        XCTAssertTrue(preview.config.contains("HostName prod.internal"))
        XCTAssertTrue(preview.config.contains("ProxyJump museterm-11111111-1111-1111-1111-111111111111-jump-1"))
        XCTAssertTrue(preview.config.contains("ControlPath"))
        XCTAssertTrue(preview.config.contains("/tmp/mtssh-\(getuid())/cm-%C"))
        XCTAssertFalse(preview.config.contains("Application Support/MuseTerm/SSH/cm-%C"))
        XCTAssertTrue(preview.commands.contains { $0.command.contains("dscacheutil -q host -a name 'bastion.internal'") })
        XCTAssertTrue(preview.commands.contains { $0.command.contains("nc -vz -w 5 'bastion.internal' 2200") })
        XCTAssertTrue(preview.commands.contains { $0.command.contains("ssh -G -F") && $0.command.contains(preview.targetAlias) })
        XCTAssertTrue(preview.commands.contains { $0.command.contains("ssh -vvv -F") && $0.command.contains(preview.targetAlias) })

        XCTAssertEqual(preview.commands[0].diagnosticStep.kind, .dnsLookup)
        XCTAssertEqual(preview.commands[0].diagnosticStep.routeStepKind, .jump(index: 1))
        XCTAssertEqual(preview.commands[0].diagnosticStep.host, "bastion.internal")
        XCTAssertEqual(preview.commands[0].diagnosticStep.alias, "museterm-11111111-1111-1111-1111-111111111111-jump-1")
        XCTAssertEqual(preview.commands[2].diagnosticStep.kind, .generatedConfig)
        XCTAssertEqual(preview.commands[2].diagnosticStep.alias, preview.targetAlias)

        let configResult = preview.commands[2].diagnosticStep.interpretResult(
            exitCode: nil,
            output: "hostname prod.internal\nuser deploy\nport 22\n"
        )
        XCTAssertEqual(configResult.status, .passed)
    }

    func testRuntimeSSHConfigUsesShortControlPathForUnixSocketLimit() {
        let profile = SSHConnectionProfile(host: "example.com", user: "deploy")

        let preview = SSHConfigMaterializer.preview(for: profile)
        let expectedControlPath = "/tmp/mtssh-\(getuid())/cm-%C"

        XCTAssertTrue(preview.config.contains("  ControlPath \"\(expectedControlPath)\""))
        XCTAssertLessThan(expectedControlPath.count + 40, 104)
        XCTAssertFalse(preview.config.contains("Library/Application Support/MuseTerm/SSH/cm-%C"))
    }

    func testRuntimeSSHConfigIgnoresLegacyGeneratedControlPathExtraOption() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let staleControlPath = appSupport
            .appendingPathComponent("MuseTerm", isDirectory: true)
            .appendingPathComponent("SSH", isDirectory: true)
            .appendingPathComponent("cm-%C")
            .path
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            extraOptions: [
                "ControlPath = \"\(staleControlPath)\"",
                "Compression yes"
            ],
            connectionReuseEnabled: true
        )

        let preview = SSHConfigMaterializer.preview(for: profile)
        let expectedControlPath = "/tmp/mtssh-\(getuid())/cm-%C"

        XCTAssertTrue(preview.config.contains("  ControlPath \"\(expectedControlPath)\""))
        XCTAssertFalse(preview.config.contains(staleControlPath))
        XCTAssertTrue(preview.config.contains("  Compression yes"))
    }

    func testSSHRouteDiagnosticAdvisorRecommendsNextStepFromPreviewResults() {
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Production",
            host: "prod.internal",
            user: "deploy",
            jumpHosts: [
                SSHJumpHost(name: "Bastion", host: "bastion.internal", user: "jump", port: 2200)
            ]
        )
        let preview = SSHConfigMaterializer.preview(for: profile)
        let steps = preview.commands.map(\.diagnosticStep)

        let tcpFailed = SSHRouteDiagnosticAdvisor.recommendation(
            planSteps: steps,
            results: [
                0: SSHRouteDiagnosticStepResult(status: .passed, summary: "ok", evidence: nil),
                1: SSHRouteDiagnosticStepResult(status: .failed, summary: "refused", evidence: "Connection refused")
            ]
        )
        XCTAssertEqual(tcpFailed?.kind, .tcpFailure)
        XCTAssertEqual(tcpFailed?.status, .failed)
        XCTAssertEqual(tcpFailed?.relatedStepIndex, 2)
        guard let tcpFailed else {
            XCTFail("Expected TCP failure recommendation")
            return
        }
        let tcpDetail = SSHRouteDiagnosticRecommendationDetail(
            recommendation: tcpFailed,
            planSteps: steps,
            results: [
                0: SSHRouteDiagnosticStepResult(status: .passed, summary: "ok", evidence: nil),
                1: SSHRouteDiagnosticStepResult(status: .failed, summary: "refused", evidence: "Connection refused")
            ]
        )
        XCTAssertEqual(tcpDetail.oneBasedStepIndex, 2)
        XCTAssertEqual(tcpDetail.zeroBasedStepIndex, 1)
        XCTAssertEqual(tcpDetail.stepTitle, steps[1].title)
        XCTAssertTrue(tcpDetail.command?.contains("nc -vz -w 5") == true)
        XCTAssertTrue(tcpDetail.command?.contains("'bastion.internal' 2200") == true)
        XCTAssertEqual(tcpDetail.evidence, "Connection refused")

        let continueChecks = SSHRouteDiagnosticAdvisor.recommendation(
            planSteps: steps,
            results: [
                0: SSHRouteDiagnosticStepResult(status: .passed, summary: "ok", evidence: nil)
            ]
        )
        XCTAssertEqual(continueChecks?.kind, .continueChecks)
        XCTAssertEqual(continueChecks?.status, .passed)
        XCTAssertEqual(continueChecks?.relatedStepIndex, 2)
        XCTAssertTrue(continueChecks?.summary.contains(steps[1].title) == true)

        let allPassed = SSHRouteDiagnosticAdvisor.recommendation(
            planSteps: steps,
            results: Dictionary(uniqueKeysWithValues: steps.indices.map {
                ($0, SSHRouteDiagnosticStepResult(status: .passed, summary: "ok", evidence: nil))
            })
        )
        XCTAssertEqual(allPassed?.kind, .allPassed)
        XCTAssertEqual(allPassed?.status, .passed)
    }

    func testSSHProfileBuildsReadablePortForwardSummaries() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            portForwards: [
                SSHPortForward(
                    kind: .local,
                    bindHost: "",
                    bindPort: 8080,
                    destinationHost: "127.0.0.1",
                    destinationPort: 80
                ),
                SSHPortForward(
                    kind: .remote,
                    bindHost: "0.0.0.0",
                    bindPort: 9000,
                    destinationHost: "127.0.0.1",
                    destinationPort: 9000
                ),
                SSHPortForward(kind: .dynamic, bindHost: "127.0.0.1", bindPort: 1080),
                SSHPortForward(kind: .dynamic, bindHost: "::", bindPort: 1081),
                SSHPortForward(kind: .dynamic, bindHost: "2001:db8::1", bindPort: 1082)
            ]
        )

        XCTAssertEqual(profile.usablePortForwards.count, 5)
        XCTAssertTrue(profile.portForwardSummaryText.contains("localhost:8080"))
        XCTAssertTrue(profile.portForwardSummaryText.contains("0.0.0.0:9000"))
        XCTAssertTrue(profile.portForwardSummaryText.contains("127.0.0.1:1080"))
        XCTAssertTrue(profile.portForwardSummaryText.contains("[::]:1081"))
        XCTAssertTrue(profile.portForwardSummaryText.contains("[2001:db8::1]:1082"))
        XCTAssertTrue(profile.portForwardAccessText.contains("http://localhost:8080"))
        XCTAssertTrue(profile.portForwardAccessText.contains("socks5://127.0.0.1:1080"))
        XCTAssertTrue(profile.portForwardAccessText.contains("socks5://localhost:1081"))
        XCTAssertTrue(profile.portForwardAccessText.contains("socks5://[2001:db8::1]:1082"))
        XCTAssertFalse(profile.portForwardAccessText.contains("0.0.0.0:9000"))
        XCTAssertTrue(profile.portForwardClipboardText.contains(L10n.string("ssh.port_forward.access")))
    }

    func testSSHProfileFormatsIPv6PortForwardSummaryEndpoints() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            portForwards: [
                SSHPortForward(
                    kind: .local,
                    bindHost: "::1",
                    bindPort: 8443,
                    destinationHost: "2001:db8::20",
                    destinationPort: 443
                )
            ]
        )

        XCTAssertTrue(profile.portForwardSummaryText.contains("[::1]:8443"))
        XCTAssertTrue(profile.portForwardSummaryText.contains("[2001:db8::20]:443"))
        XCTAssertTrue(profile.portForwardAccessText.contains("https://[::1]:8443"))
    }

    func testSSHPortForwardEditorLineRoundTripsIPv6Endpoints() {
        let forward = SSHPortForward(
            kind: .local,
            bindHost: "::1",
            bindPort: 8443,
            destinationHost: "2001:db8::20",
            destinationPort: 443
        )

        XCTAssertEqual(forward.editorLineText, "local|[::1]:8443|[2001:db8::20]:443")

        let parsed = SSHPortForward.parseEditorLine(forward.editorLineText)?.normalized
        XCTAssertEqual(parsed?.kind, .local)
        XCTAssertEqual(parsed?.bindHost, "::1")
        XCTAssertEqual(parsed?.bindPort, 8443)
        XCTAssertEqual(parsed?.destinationHost, "2001:db8::20")
        XCTAssertEqual(parsed?.destinationPort, 443)
    }

    func testSSHPortForwardPreviewTextDescribesTargetAndAccess() {
        let local = SSHPortForward(
            kind: .local,
            bindHost: "",
            bindPort: 8443,
            destinationHost: "2001:db8::20",
            destinationPort: 443
        ).normalized
        let remote = SSHPortForward(
            kind: .remote,
            bindHost: "",
            bindPort: 9000,
            destinationHost: "127.0.0.1",
            destinationPort: 9000
        ).normalized
        let dynamic = SSHPortForward(kind: .dynamic, bindHost: "::", bindPort: 1080).normalized

        XCTAssertEqual(local.previewTargetText, "[2001:db8::20]:443")
        XCTAssertEqual(local.previewAccessText, "https://localhost:8443")
        XCTAssertEqual(remote.previewTargetText, "127.0.0.1:9000")
        XCTAssertEqual(remote.previewAccessText, L10n.string("ssh.port_forward.preview.no_local_entry"))
        XCTAssertEqual(dynamic.previewTargetText, L10n.string("ssh.port_forward.preview.socks"))
        XCTAssertEqual(dynamic.previewAccessText, "socks5://localhost:1080")
    }

    func testSSHProfileDeduplicatesRepeatedPortForwardAccessEntries() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            portForwards: [
                SSHPortForward(
                    kind: .local,
                    bindHost: "",
                    bindPort: 8080,
                    destinationHost: "127.0.0.1",
                    destinationPort: 80
                ),
                SSHPortForward(
                    kind: .local,
                    bindHost: "0.0.0.0",
                    bindPort: 8080,
                    destinationHost: "app.internal",
                    destinationPort: 80
                ),
                SSHPortForward(kind: .dynamic, bindHost: "*", bindPort: 1080),
                SSHPortForward(kind: .dynamic, bindHost: "::", bindPort: 1080)
            ]
        )

        XCTAssertEqual(profile.usablePortForwards.count, 4)
        XCTAssertEqual(profile.portForwardSummaryText.occurrences(of: "localhost:8080"), 1)
        XCTAssertEqual(profile.portForwardSummaryText.occurrences(of: "0.0.0.0:8080"), 1)
        XCTAssertEqual(profile.portForwardSummaryText.occurrences(of: "*:1080"), 1)
        XCTAssertEqual(profile.portForwardSummaryText.occurrences(of: "[::]:1080"), 1)
        XCTAssertEqual(profile.portForwardAccessText.occurrences(of: "http://localhost:8080"), 1)
        XCTAssertEqual(profile.portForwardAccessText.occurrences(of: "socks5://localhost:1080"), 1)
        XCTAssertEqual(
            profile.portForwardAccessEntries,
            [
                SSHPortForwardAccessEntry(kind: .local, urlString: "http://localhost:8080"),
                SSHPortForwardAccessEntry(kind: .dynamic, urlString: "socks5://localhost:1080")
            ]
        )
        XCTAssertTrue(profile.portForwardAccessEntries[0].canOpenInBrowser)
        XCTAssertFalse(profile.portForwardAccessEntries[1].canOpenInBrowser)
    }

    func testSSHProfileBuildsConnectionCapabilitySummary() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            portForwards: [
                SSHPortForward(kind: .local, bindHost: "", bindPort: 8080, destinationHost: "127.0.0.1", destinationPort: 80)
            ]
        )

        let summary = profile.connectionCapabilityText

        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.summary")))
        XCTAssertTrue(summary.contains("ServerAliveInterval 30"))
        XCTAssertTrue(summary.contains("ServerAliveCountMax 6"))
        XCTAssertTrue(summary.contains("ControlMaster auto"))
        XCTAssertTrue(summary.contains("ControlPersist 10"))
        XCTAssertTrue(summary.contains(L10n.format("ssh.capability.reconnect.enabled", 3, 3)))
        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.forward_failure.enabled")))
    }

    func testSSHProfileCapabilitySummaryRespectsManualAdvancedOptions() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            portForwards: [
                SSHPortForward(kind: .dynamic, bindHost: "127.0.0.1", bindPort: 1080)
            ],
            extraOptions: [
                "ServerAliveInterval 15",
                "ControlMaster no",
                "ExitOnForwardFailure no"
            ]
        )

        let summary = profile.connectionCapabilityText

        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.keep_alive.manual")))
        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.reuse.manual")))
        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.forward_failure.manual")))
        XCTAssertFalse(summary.contains("ServerAliveInterval 30"))
        XCTAssertFalse(summary.contains("ControlMaster auto"))
    }

    func testSSHProfileCapabilitySummaryShowsManualOptionsEvenWhenFeatureTogglesAreOff() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            extraOptions: [
                "ServerAliveInterval 15",
                "ControlPersist=30m"
            ],
            keepAliveEnabled: false,
            connectionReuseEnabled: false
        )

        let summary = profile.connectionCapabilityText

        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.keep_alive.manual")))
        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.reuse.manual")))
        XCTAssertFalse(summary.contains(L10n.string("ssh.capability.keep_alive.disabled")))
        XCTAssertFalse(summary.contains(L10n.string("ssh.capability.reuse.disabled")))
    }

    func testSSHProfileCapabilitySummaryShowsDisabledBehaviors() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            user: "deploy",
            keepAliveEnabled: false,
            connectionReuseEnabled: false,
            automaticReconnectEnabled: false
        )

        let summary = profile.connectionCapabilityText

        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.keep_alive.disabled")))
        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.reuse.disabled")))
        XCTAssertTrue(summary.contains(L10n.string("ssh.capability.reconnect.disabled")))
        XCTAssertFalse(summary.contains(L10n.string("ssh.capability.forward_failure.enabled")))
    }

    func testSSHProfileSearchMatchesGroupTagsAndJumpHosts() {
        let profile = SSHConnectionProfile(
            name: "Production API",
            host: "prod.internal",
            user: "deploy",
            jumpHosts: [SSHJumpHost(name: "Bastion", host: "bastion.internal", user: "ops")],
            environment: .production,
            groupName: "Core Services",
            tags: ["Prod", "api", "prod", "#urgent"]
        ).normalized

        XCTAssertEqual(profile.tags, ["api", "Prod", "urgent"])
        XCTAssertEqual(profile.groupDisplayName, "Core Services")
        XCTAssertTrue(profile.matchesSearch("core api"))
        XCTAssertTrue(profile.matchesSearch("bastion prod", selectedTag: "urgent"))
        XCTAssertTrue(profile.matchesSearch("", selectedTag: "API"))
        XCTAssertFalse(profile.matchesSearch("billing"))
        XCTAssertFalse(profile.matchesSearch("prod", selectedTag: "database"))
    }

    func testSSHProfileDecodesLegacyJSONWithoutGroupsOrTags() throws {
        let data = """
        {
          "name": "legacy",
          "host": "legacy.example.com",
          "user": "deploy"
        }
        """.data(using: .utf8)!

        let profile = try JSONDecoder().decode(SSHConnectionProfile.self, from: data).normalized

        XCTAssertEqual(profile.name, "legacy")
        XCTAssertEqual(profile.host, "legacy.example.com")
        XCTAssertEqual(profile.groupName, "")
        XCTAssertEqual(profile.tags, [])
    }

    func testSSHConnectionIssueClassifierMatchesCommonFailures() {
        XCTAssertEqual(
            SSHConnectionIssueClassifier.classify("Permission denied (publickey,password)."),
            .permissionDenied
        )
        XCTAssertEqual(
            SSHConnectionIssueClassifier.classify("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"),
            .hostKeyVerificationFailed
        )
        XCTAssertEqual(
            SSHConnectionIssueClassifier.classify("ssh: connect to host example.com port 22: Operation timed out"),
            .connectionTimedOut
        )
        XCTAssertEqual(
            SSHConnectionIssueClassifier.classify("ssh: connect to host example.com port 22: Connection refused"),
            .connectionRefused
        )
        XCTAssertEqual(
            SSHConnectionIssueClassifier.classify("Received disconnect from 10.0.0.1: Too many authentication failures"),
            .tooManyAuthenticationFailures
        )
        XCTAssertEqual(
            SSHConnectionIssueClassifier.classify("channel_setup_fwd_listener_tcpip: cannot listen to port: 8080"),
            .portForwardFailure
        )
    }

    func testSSHRouteDiagnosticAnalyzerIdentifiesJumpHostFailure() throws {
        let profile = SSHConnectionProfile(
            name: "Production API",
            host: "prod.internal",
            user: "deploy",
            jumpHosts: [
                SSHJumpHost(name: "Bastion", host: "bastion.internal", user: "ops"),
                SSHJumpHost(name: "Inner", host: "inner.internal", user: "ops", port: 2222)
            ]
        )
        let diagnosticText = "ssh: connect to host inner.internal port 2222: Connection refused"

        let context = try XCTUnwrap(SSHRouteDiagnosticAnalyzer.context(for: profile, diagnosticText: diagnosticText))

        XCTAssertEqual(context.kind, .jump(index: 2))
        XCTAssertEqual(context.host, "inner.internal")
        XCTAssertEqual(context.port, 2222)
        XCTAssertEqual(context.evidence, diagnosticText)
        XCTAssertTrue(context.message.contains("inner.internal:2222"))
    }

    func testSSHRouteDiagnosticAnalyzerIdentifiesTargetFailureWithoutJumps() throws {
        let profile = SSHConnectionProfile(name: "Production API", host: "prod.internal", user: "deploy")
        let diagnosticText = "ssh: Could not resolve hostname prod.internal: nodename nor servname provided"

        let context = try XCTUnwrap(SSHRouteDiagnosticAnalyzer.context(for: profile, diagnosticText: diagnosticText))

        XCTAssertEqual(context.kind, .target)
        XCTAssertEqual(context.host, "prod.internal")
        XCTAssertEqual(context.evidence, diagnosticText)
    }

    @MainActor
    func testSSHProfileNormalizesAutomaticReconnectSettings() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            automaticReconnectAttempts: 99,
            automaticReconnectDelaySeconds: 0
        ).normalized

        XCTAssertTrue(profile.automaticReconnectEnabled)
        XCTAssertEqual(profile.automaticReconnectAttempts, 20)
        XCTAssertEqual(profile.automaticReconnectDelaySeconds, 1)
    }

    @MainActor
    func testSSHReconnectPolicyRetriesTransientFailuresWithBackoff() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            automaticReconnectAttempts: 3,
            automaticReconnectDelaySeconds: 4
        )

        XCTAssertEqual(
            SSHReconnectPolicy.decision(
                profile: profile,
                issue: .connectionTimedOut,
                exitCode: 255,
                completedAttempts: 0
            ),
            .reconnect(delaySeconds: 4)
        )
        XCTAssertEqual(
            SSHReconnectPolicy.decision(
                profile: profile,
                issue: .connectionRefused,
                exitCode: 255,
                completedAttempts: 2
            ),
            .reconnect(delaySeconds: 12)
        )
        XCTAssertEqual(
            SSHReconnectPolicy.decision(
                profile: profile,
                issue: .connectionRefused,
                exitCode: 255,
                completedAttempts: 3
            ),
            .exhausted
        )
    }

    @MainActor
    func testSSHDisconnectReasonClassifierDistinguishesRemoteCloseAndNetworkInterruption() {
        XCTAssertEqual(
            SSHDisconnectReasonClassifier.classify(
                issue: nil,
                exitCode: 255,
                diagnosticText: "Connection to prod.internal closed by remote host."
            ),
            .remoteClosedConnection
        )
        XCTAssertEqual(
            SSHDisconnectReasonClassifier.classify(
                issue: nil,
                exitCode: 255,
                diagnosticText: "client_loop: send disconnect: Broken pipe"
            ),
            .networkInterrupted
        )
        XCTAssertEqual(
            SSHDisconnectReasonClassifier.classify(
                issue: .permissionDenied,
                exitCode: 255,
                diagnosticText: "Permission denied (publickey)."
            ),
            .authenticationOrSecurityStopped
        )
        XCTAssertEqual(
            SSHDisconnectReasonClassifier.classify(
                issue: nil,
                exitCode: 0,
                diagnosticText: "logout"
            ),
            .cleanExit
        )
    }

    @MainActor
    func testSSHReconnectPolicySuppressesRemoteClosedConnectionButRetriesNetworkInterruption() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            automaticReconnectAttempts: 3,
            automaticReconnectDelaySeconds: 4
        )

        XCTAssertEqual(
            SSHReconnectPolicy.decision(
                profile: profile,
                issue: nil,
                exitCode: 255,
                completedAttempts: 0,
                disconnectReason: .remoteClosedConnection
            ),
            .suppress
        )
        XCTAssertEqual(
            SSHReconnectPolicy.decision(
                profile: profile,
                issue: nil,
                exitCode: 255,
                completedAttempts: 0,
                disconnectReason: .networkInterrupted
            ),
            .reconnect(delaySeconds: 4)
        )
    }

    @MainActor
    func testSSHReconnectPolicySuppressesCleanAndSecuritySensitiveExits() {
        let profile = SSHConnectionProfile(host: "example.com")

        XCTAssertEqual(
            SSHReconnectPolicy.decision(
                profile: profile,
                issue: nil,
                exitCode: 0,
                completedAttempts: 0
            ),
            .suppress
        )
        XCTAssertEqual(
            SSHReconnectPolicy.decision(
                profile: profile,
                issue: .permissionDenied,
                exitCode: 255,
                completedAttempts: 0
            ),
            .suppress
        )
        XCTAssertEqual(
            SSHReconnectPolicy.decision(
                profile: profile,
                issue: .hostKeyVerificationFailed,
                exitCode: 255,
                completedAttempts: 0
            ),
            .suppress
        )
    }

    @MainActor
    func testManualSSHReconnectIsAvailableOnlyAfterSSHExit() {
        let sshSession = TerminalSession(
            sequence: 1,
            launchConfiguration: .ssh(SSHConnectionProfile(host: "example.com"))
        )
        XCTAssertFalse(sshSession.canManuallyReconnectSSH)

        sshSession.state = .exited(255)
        XCTAssertTrue(sshSession.canManuallyReconnectSSH)

        sshSession.state = .running
        XCTAssertFalse(sshSession.canManuallyReconnectSSH)

        let localSession = TerminalSession(sequence: 2)
        localSession.state = .exited(0)
        XCTAssertFalse(localSession.canManuallyReconnectSSH)
    }

    @MainActor
    func testSSHProfileBuildsRouteSummaryThroughJumpHosts() {
        let profile = SSHConnectionProfile(
            name: "prod-app",
            host: "10.0.2.15",
            user: "deploy",
            jumpHosts: [
                SSHJumpHost(name: "edge", host: "edge.example.com", user: "ops"),
                SSHJumpHost(host: "bastion.internal", user: "deploy")
            ]
        )

        XCTAssertEqual(
            profile.routeSummary,
            "\(L10n.string("ssh.route.local")) -> edge -> deploy@bastion.internal -> deploy@10.0.2.15"
        )
    }

    func testSSHRouteDiagnosticAnalyzerLocatesJumpHostFailure() {
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Prod",
            host: "prod.internal",
            user: "deploy",
            port: 2200,
            jumpHosts: [
                SSHJumpHost(
                    name: "bastion",
                    host: "jump1.example.com",
                    user: "ops",
                    port: 2222
                )
            ]
        )

        let context = SSHRouteDiagnosticAnalyzer.context(
            for: profile,
            diagnosticText: "ssh: connect to host jump1.example.com port 2222: Operation timed out"
        )

        XCTAssertEqual(context?.kind, .jump(index: 1))
        XCTAssertEqual(context?.displayName, "bastion")
        XCTAssertEqual(context?.host, "jump1.example.com")
        XCTAssertEqual(context?.port, 2222)
        XCTAssertTrue(context?.message.contains("jump1.example.com") ?? false)
        XCTAssertTrue(context?.message.contains("Operation timed out") ?? false)
    }

    func testSSHRouteDiagnosticAnalyzerLocatesTargetAliasFailure() {
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Prod",
            host: "prod.internal",
            user: "deploy",
            port: 2200,
            jumpHosts: [
                SSHJumpHost(name: "bastion", host: "jump1.example.com", user: "ops")
            ]
        )

        let context = SSHRouteDiagnosticAnalyzer.context(
            for: profile,
            diagnosticText: """
            channel 0: open failed: connect failed: Connection refused
            ssh: connect to host museterm-11111111-1111-1111-1111-111111111111-target port 2200: Connection refused
            """
        )

        XCTAssertEqual(context?.kind, .target)
        XCTAssertEqual(context?.displayName, "Prod")
        XCTAssertEqual(context?.host, "prod.internal")
        XCTAssertEqual(context?.port, 2200)
        XCTAssertTrue(context?.message.contains("prod.internal") ?? false)
        XCTAssertTrue(context?.message.contains("Connection refused") ?? false)
    }

    func testSSHRouteDiagnosticAnalyzerFallsBackToUnknownWhenJumpRouteOutputOmitsHost() {
        let profile = SSHConnectionProfile(
            name: "Prod",
            host: "prod.internal",
            user: "deploy",
            jumpHosts: [
                SSHJumpHost(name: "bastion", host: "jump1.example.com", user: "ops")
            ]
        )

        let context = SSHRouteDiagnosticAnalyzer.context(
            for: profile,
            diagnosticText: "Permission denied (publickey)."
        )

        XCTAssertEqual(context?.kind, .unknown)
        XCTAssertNil(context?.host)
        XCTAssertNil(context?.port)
        XCTAssertEqual(context?.evidence, "Permission denied (publickey).")
        XCTAssertEqual(context?.routeSummary, profile.routeSummary)
    }

    func testSSHRouteProbeGuideUsesFirstHopAndGeneratedConfig() throws {
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Prod",
            host: "prod.internal",
            user: "deploy",
            port: 2200,
            identityFiles: ["~/.ssh/prod"],
            jumpHosts: [
                SSHJumpHost(
                    name: "bastion",
                    host: "jump1.example.com",
                    user: "ops",
                    port: 2222,
                    identityFiles: ["~/.ssh/jump1"]
                )
            ]
        )

        let plan = try XCTUnwrap(SSHRouteProbeGuideBuilder.plan(for: profile, issue: .connectionTimedOut))
        let guide = plan.failureGuide
        let message = guide.message

        XCTAssertEqual(plan.routeSummary, profile.routeSummary)
        XCTAssertEqual(plan.steps.map(\.kind), [.dnsLookup, .tcpPort, .generatedConfig, .verboseRoute, .verboseRoute])
        XCTAssertEqual(plan.steps[0].routeStepKind, .jump(index: 1))
        XCTAssertEqual(plan.steps[0].host, "jump1.example.com")
        XCTAssertEqual(plan.steps[1].port, 2222)
        XCTAssertEqual(plan.steps[3].alias, "museterm-11111111-1111-1111-1111-111111111111-jump-1")
        XCTAssertEqual(plan.steps[4].routeStepKind, .target)
        XCTAssertEqual(guide.commands.count, 5)
        XCTAssertTrue(message.contains("dscacheutil -q host -a name 'jump1.example.com'"))
        XCTAssertTrue(message.contains("nc -vz -w 5 'jump1.example.com' 2222"))
        XCTAssertTrue(message.contains("ssh -G -F "))
        XCTAssertTrue(message.contains("11111111-1111-1111-1111-111111111111.conf"))
        XCTAssertTrue(message.contains("'museterm-11111111-1111-1111-1111-111111111111-target'"))
        XCTAssertTrue(message.contains("'museterm-11111111-1111-1111-1111-111111111111-jump-1'"))
        XCTAssertTrue(message.contains(" true"))
    }

    func testSSHRouteProbeGuideChecksTargetDirectlyWhenThereAreNoJumps() throws {
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            host: "direct.example.com",
            port: 2200
        )

        let plan = try XCTUnwrap(SSHRouteProbeGuideBuilder.plan(for: profile, issue: .connectionRefused))
        let guide = plan.failureGuide

        XCTAssertEqual(plan.steps.map(\.kind), [.dnsLookup, .tcpPort, .generatedConfig, .verboseRoute])
        XCTAssertEqual(plan.steps[0].routeStepKind, .target)
        XCTAssertTrue(guide.message.contains("dscacheutil -q host -a name 'direct.example.com'"))
        XCTAssertTrue(guide.message.contains("nc -vz -w 5 'direct.example.com' 2200"))
        XCTAssertTrue(guide.message.contains("'museterm-22222222-2222-2222-2222-222222222222-target'"))
    }

    func testSSHRouteProbeGuideDoesNotSuggestVerboseReconnectForHostKeyFailure() throws {
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            host: "prod.internal",
            user: "deploy"
        )

        let plan = try XCTUnwrap(SSHRouteProbeGuideBuilder.plan(for: profile, issue: .hostKeyVerificationFailed))
        let guide = plan.failureGuide

        XCTAssertEqual(plan.steps.map(\.kind), [.dnsLookup, .tcpPort, .generatedConfig])
        XCTAssertEqual(guide.commands.count, 3)
        XCTAssertTrue(guide.message.contains("ssh -G -F "))
        XCTAssertFalse(guide.message.contains("ssh -vvv -F "))
    }

    func testSSHRouteDiagnosticStepResultInterpretsDNSOutput() {
        let step = SSHRouteDiagnosticPlanStep(
            kind: .dnsLookup,
            title: "Resolve host",
            command: "dscacheutil -q host -a name example.com",
            routeStepKind: .target,
            host: "example.com",
            port: nil,
            alias: nil,
            includeInFailureGuide: true
        )

        let passed = step.interpretResult(
            exitCode: nil,
            output: "name: example.com\nip_address: 93.184.216.34"
        )
        let failed = step.interpretResult(
            exitCode: 1,
            output: "** server can't find missing.internal: NXDOMAIN"
        )

        XCTAssertEqual(passed.status, .passed)
        XCTAssertEqual(passed.evidence, "name: example.com")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.evidence?.contains("NXDOMAIN") ?? false)
    }

    func testSSHRouteDiagnosticStepResultInterpretsTCPOutput() {
        let step = SSHRouteDiagnosticPlanStep(
            kind: .tcpPort,
            title: "Check TCP",
            command: "nc -vz -w 5 example.com 22",
            routeStepKind: .target,
            host: "example.com",
            port: 22,
            alias: nil,
            includeInFailureGuide: true
        )

        let open = step.interpretResult(exitCode: 0, output: "Connection to example.com port 22 [tcp/ssh] succeeded!")
        let refused = step.interpretResult(exitCode: 1, output: "nc: connectx to example.com port 22: Connection refused")
        let timedOut = step.interpretResult(exitCode: 1, output: "nc: connectx to example.com port 22: Operation timed out")

        XCTAssertEqual(open.status, .passed)
        XCTAssertEqual(refused.status, .failed)
        XCTAssertTrue(refused.evidence?.lowercased().contains("connection refused") ?? false)
        XCTAssertEqual(timedOut.status, .failed)
        XCTAssertTrue(timedOut.evidence?.lowercased().contains("timed out") ?? false)
    }

    func testSSHRouteDiagnosticStepResultInterpretsConfigOutput() {
        let step = SSHRouteDiagnosticPlanStep(
            kind: .generatedConfig,
            title: "Config",
            command: "ssh -G -F /tmp/profile.conf alias",
            routeStepKind: .target,
            host: "example.com",
            port: 22,
            alias: "alias",
            includeInFailureGuide: true
        )

        let passed = step.interpretResult(exitCode: nil, output: "hostname example.com\nuser deploy\nport 22")
        let failed = step.interpretResult(exitCode: 255, output: "Bad configuration option: proxyjumpx")

        XCTAssertEqual(passed.status, .passed)
        XCTAssertEqual(passed.evidence, "hostname example.com")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.evidence?.lowercased().contains("bad configuration option") ?? false)
    }

    func testSSHRouteDiagnosticStepResultInterpretsVerboseSSHOutput() {
        let step = SSHRouteDiagnosticPlanStep(
            kind: .verboseRoute,
            title: "Verbose",
            command: "ssh -vvv -F /tmp/profile.conf alias true",
            routeStepKind: .target,
            host: "example.com",
            port: 22,
            alias: "alias",
            includeInFailureGuide: true
        )

        let passed = step.interpretResult(exitCode: 0, output: "debug1: Authenticated to example.com.\ndebug1: Exit status 0")
        let denied = step.interpretResult(exitCode: 255, output: "Permission denied (publickey).")
        let unknown = step.interpretResult(exitCode: nil, output: "")

        XCTAssertEqual(passed.status, .passed)
        XCTAssertTrue(passed.evidence?.contains("Exit status 0") ?? false)
        XCTAssertEqual(denied.status, .failed)
        XCTAssertTrue(denied.summary.contains(SSHConnectionIssueKind.permissionDenied.title))
        XCTAssertEqual(unknown.status, .unknown)
    }

    func testSSHRouteDiagnosticResultSummaryCountsScopedResults() {
        let results: [Int: SSHRouteDiagnosticStepResult] = [
            0: SSHRouteDiagnosticStepResult(status: .passed, summary: "ok", evidence: nil),
            1: SSHRouteDiagnosticStepResult(status: .failed, summary: "bad", evidence: "Connection refused"),
            2: SSHRouteDiagnosticStepResult(status: .needsAttention, summary: "maybe", evidence: nil),
            9: SSHRouteDiagnosticStepResult(status: .unknown, summary: "stale", evidence: nil)
        ]

        let summary = SSHRouteDiagnosticResultSummary(totalSteps: 4, results: results)

        XCTAssertTrue(summary.hasResults)
        XCTAssertEqual(summary.parsedSteps, 3)
        XCTAssertEqual(summary.remainingSteps, 1)
        XCTAssertEqual(summary.passed, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(summary.unknown, 0)
        XCTAssertEqual(summary.leadingStatus, .failed)
    }

    func testSSHRouteDiagnosticReportBuildsRunbookReadyMarkdown() {
        let steps = [
            SSHRouteDiagnosticPlanStep(
                kind: .dnsLookup,
                title: "Resolve target",
                command: "dscacheutil -q host -a name example.com",
                routeStepKind: .target,
                host: "example.com",
                port: nil,
                alias: nil,
                includeInFailureGuide: true
            ),
            SSHRouteDiagnosticPlanStep(
                kind: .tcpPort,
                title: "Check TCP",
                command: "nc -vz -w 5 example.com 22",
                routeStepKind: .target,
                host: "example.com",
                port: 22,
                alias: nil,
                includeInFailureGuide: true
            )
        ]
        let results: [Int: SSHRouteDiagnosticStepResult] = [
            0: SSHRouteDiagnosticStepResult(status: .passed, summary: "DNS resolved.", evidence: "name: example.com"),
            1: SSHRouteDiagnosticStepResult(status: .failed, summary: "TCP refused.", evidence: "Connection refused"),
            9: SSHRouteDiagnosticStepResult(status: .unknown, summary: "stale", evidence: "old")
        ]

        let report = SSHRouteDiagnosticReport(
            profileName: "Production API",
            routeSummary: "Mac -> example.com:22",
            planSteps: steps,
            results: results,
            generatedAtText: "2026-07-02T09:00:00Z",
            redactsSensitiveData: false
        )
        let markdown = report.markdown

        XCTAssertTrue(report.hasResults)
        XCTAssertEqual(report.resultSummary.parsedSteps, 2)
        XCTAssertTrue(markdown.hasPrefix("# "))
        XCTAssertTrue(markdown.contains("Production API"))
        XCTAssertTrue(markdown.contains("Mac -> example.com:22"))
        XCTAssertTrue(markdown.contains("2026-07-02T09:00:00Z"))
        XCTAssertTrue(markdown.contains("### 1. Resolve target"))
        XCTAssertTrue(markdown.contains("### 2. Check TCP"))
        XCTAssertTrue(markdown.contains("DNS resolved."))
        XCTAssertTrue(markdown.contains("Connection refused"))
        XCTAssertTrue(markdown.contains("## \(L10n.string("ssh.diagnostic_report.recommendation"))"))
        XCTAssertTrue(markdown.contains(L10n.string("ssh.diagnostic_recommendation.tcpFailure.title")))
        XCTAssertTrue(markdown.contains("- **\(L10n.string("ssh.diagnostic_report.recommendation.step")):** 2. Check TCP"))
        let recommendationSection = markdown.section(
            from: "## \(L10n.string("ssh.diagnostic_report.recommendation"))",
            to: "## \(L10n.string("ssh.diagnostic_report.checks"))"
        )
        XCTAssertTrue(recommendationSection.contains("- **\(L10n.string("ssh.diagnostic_report.recommendation.command")):**"))
        XCTAssertTrue(recommendationSection.contains("```shell\nnc -vz -w 5 example.com 22\n```"))
        XCTAssertTrue(recommendationSection.contains("- **\(L10n.string("ssh.diagnostic_report.recommendation.evidence")):** Connection refused"))
        XCTAssertTrue(markdown.contains(L10n.string("ssh.diagnostic_recommendation.tcpFailure.action")))
        XCTAssertTrue(markdown.contains("```shell\nnc -vz -w 5 example.com 22\n```"))
        XCTAssertTrue(markdown.contains(L10n.string("ssh.diagnostic_report.sensitive_content_not_detected")))
        XCTAssertFalse(markdown.contains("stale"))
    }

    func testSSHRouteDiagnosticReportKeepsRecommendationStepIndexWhenEarlierResultsAreMissing() {
        let steps = [
            SSHRouteDiagnosticPlanStep(
                kind: .dnsLookup,
                title: "Resolve target",
                command: "dscacheutil -q host -a name example.com",
                routeStepKind: .target,
                host: "example.com",
                port: nil,
                alias: nil,
                includeInFailureGuide: true
            ),
            SSHRouteDiagnosticPlanStep(
                kind: .tcpPort,
                title: "Check TCP",
                command: "nc -vz -w 5 example.com 22",
                routeStepKind: .target,
                host: "example.com",
                port: 22,
                alias: nil,
                includeInFailureGuide: true
            )
        ]

        let report = SSHRouteDiagnosticReport(
            profileName: "Production API",
            routeSummary: "Mac -> example.com:22",
            planSteps: steps,
            results: [
                1: SSHRouteDiagnosticStepResult(status: .failed, summary: "TCP refused.", evidence: "Connection refused")
            ],
            generatedAtText: "2026-07-02T09:00:00Z"
        )
        let markdown = report.markdown

        XCTAssertFalse(markdown.contains("### 1. Resolve target"))
        XCTAssertTrue(markdown.contains("### 2. Check TCP"))
        XCTAssertTrue(markdown.contains("- **\(L10n.string("ssh.diagnostic_report.recommendation.step")):** 2. Check TCP"))
    }

    func testSSHRouteDiagnosticReportAnchorsContinueRecommendationToNextUncheckedStep() {
        let steps = [
            SSHRouteDiagnosticPlanStep(
                kind: .dnsLookup,
                title: "Resolve target",
                command: "dscacheutil -q host -a name example.com",
                routeStepKind: .target,
                host: "example.com",
                port: nil,
                alias: nil,
                includeInFailureGuide: true
            ),
            SSHRouteDiagnosticPlanStep(
                kind: .tcpPort,
                title: "Check TCP",
                command: "nc -vz -w 5 example.com 22",
                routeStepKind: .target,
                host: "example.com",
                port: 22,
                alias: nil,
                includeInFailureGuide: true
            )
        ]

        let report = SSHRouteDiagnosticReport(
            profileName: "Production API",
            routeSummary: "Mac -> example.com:22",
            planSteps: steps,
            results: [
                0: SSHRouteDiagnosticStepResult(status: .passed, summary: "DNS resolved.", evidence: "name: example.com")
            ],
            generatedAtText: "2026-07-02T09:00:00Z"
        )
        let markdown = report.markdown
        let recommendationSection = markdown.section(
            from: "## \(L10n.string("ssh.diagnostic_report.recommendation"))",
            to: "## \(L10n.string("ssh.diagnostic_report.checks"))"
        )

        XCTAssertTrue(recommendationSection.contains(L10n.string("ssh.diagnostic_recommendation.continueChecks.title")))
        XCTAssertTrue(recommendationSection.contains("- **\(L10n.string("ssh.diagnostic_report.recommendation.step")):** 2. Check TCP"))
        XCTAssertTrue(recommendationSection.contains("```shell\nnc -vz -w 5 example.com 22\n```"))
    }

    func testSSHRouteDiagnosticReportRedactsSensitiveEvidenceAndCommandsByDefault() {
        let steps = [
            SSHRouteDiagnosticPlanStep(
                kind: .verboseRoute,
                title: "Verbose SSH",
                command: "ssh -vvv example.com --token ghp_abcdefghijklmnopqrstuvwxyz123456",
                routeStepKind: .target,
                host: "example.com",
                port: 22,
                alias: "example",
                includeInFailureGuide: true
            )
        ]
        let results: [Int: SSHRouteDiagnosticStepResult] = [
            0: SSHRouteDiagnosticStepResult(
                status: .failed,
                summary: "Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz123456",
                evidence: "password=super-secret-value"
            )
        ]

        let redacted = SSHRouteDiagnosticReport(
            profileName: "Production API",
            routeSummary: "Mac -> example.com:22",
            planSteps: steps,
            results: results,
            generatedAtText: "2026-07-02T09:00:00Z"
        ).markdown
        let unredacted = SSHRouteDiagnosticReport(
            profileName: "Production API",
            routeSummary: "Mac -> example.com:22",
            planSteps: steps,
            results: results,
            generatedAtText: "2026-07-02T09:00:00Z",
            redactsSensitiveData: false
        ).markdown

        XCTAssertTrue(redacted.contains("[REDACTED]"))
        XCTAssertTrue(redacted.contains(L10n.string("ssh.diagnostic_report.sensitive_content_redacted")))
        XCTAssertFalse(redacted.contains("ghp_abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(redacted.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(redacted.contains("super-secret-value"))
        XCTAssertTrue(unredacted.contains(L10n.string("ssh.diagnostic_report.sensitive_content_detected_unredacted")))
        XCTAssertTrue(unredacted.contains("ghp_abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertTrue(unredacted.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertTrue(unredacted.contains("super-secret-value"))
    }

    @MainActor
    func testSSHProfileSecurityAnalyzerFlagsRiskyOptions() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            extraOptions: [
                "ForwardAgent yes",
                "StrictHostKeyChecking=no",
                "UserKnownHostsFile /dev/null"
            ]
        )

        XCTAssertEqual(
            profile.securityWarningKinds,
            [.agentForwarding, .hostKeyCheckingDisabled, .knownHostsDisabled]
        )
    }

    @MainActor
    func testSSHProfileSecurityAnalyzerNormalizesQuotedRiskyOptions() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            extraOptions: [
                "ForwardAgent \"yes\" # jump host agent",
                "StrictHostKeyChecking 'off' # lab host",
                "UserKnownHostsFile \"/dev/null\" ~/.ssh/known_hosts"
            ]
        )

        XCTAssertEqual(
            profile.securityWarningKinds,
            [.agentForwarding, .hostKeyCheckingDisabled, .knownHostsDisabled]
        )
    }

    func testSSHProfileHealthSummaryCombinesPreflightAndSecurityWarnings() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            portForwards: [
                SSHPortForward(
                    kind: .local,
                    bindHost: "127.0.0.1",
                    bindPort: 8080,
                    destinationHost: "127.0.0.1",
                    destinationPort: 80
                ),
                SSHPortForward(
                    kind: .dynamic,
                    bindHost: "127.0.0.1",
                    bindPort: 8080
                )
            ],
            extraOptions: ["ForwardAgent yes"]
        )

        let health = profile.healthSummary

        XCTAssertTrue(health.hasAttentionItems)
        XCTAssertEqual(health.preflightIssueCount, 1)
        XCTAssertEqual(health.securityWarningCount, 1)
        XCTAssertTrue(health.tooltip.contains("127.0.0.1:8080"))
        XCTAssertTrue(health.tooltip.contains(SSHProfileSecurityWarningKind.agentForwarding.summary))
    }

    @MainActor
    func testSSHProfilePreflightFlagsDuplicatePortForwardListeners() {
        let profile = SSHConnectionProfile(
            host: "example.com",
            portForwards: [
                SSHPortForward(
                    kind: .local,
                    bindHost: "127.0.0.1",
                    bindPort: 8080,
                    destinationHost: "127.0.0.1",
                    destinationPort: 80
                ),
                SSHPortForward(
                    kind: .dynamic,
                    bindHost: "127.0.0.1",
                    bindPort: 8080
                )
            ]
        )

        XCTAssertEqual(
            profile.preflightIssues,
            [
                SSHProfilePreflightIssue(
                    kind: .duplicatePortForwardListener,
                    detail: "local 127.0.0.1:8080"
                )
            ]
        )
    }

    @MainActor
    func testSSHProfilePreflightFlagsUnavailableIdentityFiles() {
        let missingTargetKey = "/tmp/museterm-missing-target-key-\(UUID().uuidString)"
        let missingJumpKey = "/tmp/museterm-missing-jump-key-\(UUID().uuidString)"
        let profile = SSHConnectionProfile(
            host: "example.com",
            identityFiles: [missingTargetKey],
            jumpHosts: [
                SSHJumpHost(
                    name: "edge",
                    host: "edge.example.com",
                    user: "ops",
                    identityFiles: [missingJumpKey]
                )
            ]
        )

        XCTAssertEqual(
            profile.preflightIssues,
            [
                SSHProfilePreflightIssue(
                    kind: .identityFileUnavailable,
                    detail: missingTargetKey
                ),
                SSHProfilePreflightIssue(
                    kind: .jumpIdentityFileUnavailable,
                    detail: "edge: \(missingJumpKey)"
                )
            ]
        )
    }

    @MainActor
    func testSSHProfilePreflightFlagsOpenIdentityFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-key-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetKey = directory.appendingPathComponent("target-key")
        let jumpKey = directory.appendingPathComponent("jump key")
        try Data("target".utf8).write(to: targetKey)
        try Data("jump".utf8).write(to: jumpKey)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: targetKey.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: jumpKey.path)

        let profile = SSHConnectionProfile(
            host: "example.com",
            identityFiles: [targetKey.path],
            jumpHosts: [
                SSHJumpHost(name: "edge", host: "edge.example.com", identityFiles: [jumpKey.path])
            ]
        )

        let issues = profile.preflightIssues
        XCTAssertTrue(
            issues.contains {
                $0.kind == .identityFilePermissionsTooOpen
                    && $0.detail.contains(targetKey.path)
                    && $0.detail.contains("chmod 600")
            }
        )
        XCTAssertTrue(
            issues.contains {
                $0.kind == .jumpIdentityFilePermissionsTooOpen
                    && $0.detail.contains("edge:")
                    && $0.detail.contains("chmod 600")
                    && $0.detail.contains("'")
            }
        )
    }

    @MainActor
    func testSSHProfilePreflightAllowsRestrictedIdentityFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-key-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetKey = directory.appendingPathComponent("target-key")
        try Data("target".utf8).write(to: targetKey)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetKey.path)

        let profile = SSHConnectionProfile(host: "example.com", identityFiles: [targetKey.path])

        XCTAssertFalse(profile.preflightIssues.contains { $0.kind == .identityFilePermissionsTooOpen })
    }

    @MainActor
    func testSSHHostKeyRepairGuideBuildsKnownHostsCommandForCustomPort() {
        let profile = SSHConnectionProfile(host: "example.com", port: 2222)
        let guide = SSHConnectionIssueRepairGuide.hostKeyGuide(
            for: profile,
            diagnosticText: "Offending ECDSA key in /Users/rocky/.ssh/known_hosts:42"
        )

        XCTAssertEqual(guide?.knownHostsTarget, "[example.com]:2222")
        XCTAssertEqual(guide?.removalCommand, "ssh-keygen -f '/Users/rocky/.ssh/known_hosts' -R '[example.com]:2222'")
        XCTAssertEqual(guide?.offendingLocation, "/Users/rocky/.ssh/known_hosts:42")
        XCTAssertTrue(guide?.message.contains("ssh-keygen -f '/Users/rocky/.ssh/known_hosts' -R '[example.com]:2222'") ?? false)
    }

    @MainActor
    func testSSHHostKeyRepairGuideUsesPlainHostForDefaultPort() {
        let profile = SSHConnectionProfile(host: "example.com", port: 22)
        let guide = SSHConnectionIssueRepairGuide.hostKeyGuide(
            for: profile,
            diagnosticText: "Host key verification failed."
        )

        XCTAssertEqual(guide?.knownHostsTarget, "example.com")
        XCTAssertEqual(guide?.removalCommand, "ssh-keygen -R 'example.com'")
        XCTAssertNil(guide?.offendingLocation)
    }

    @MainActor
    func testSSHHostKeyRepairGuideQuotesKnownHostsFilePath() {
        let profile = SSHConnectionProfile(host: "example.com", port: 22)
        let guide = SSHConnectionIssueRepairGuide.hostKeyGuide(
            for: profile,
            diagnosticText: "Offending ED25519 key in /Users/rocky/Library/Application Support/ssh/known hosts:7"
        )

        XCTAssertEqual(guide?.knownHostsTarget, "example.com")
        XCTAssertEqual(
            guide?.removalCommand,
            "ssh-keygen -f '/Users/rocky/Library/Application Support/ssh/known hosts' -R 'example.com'"
        )
        XCTAssertEqual(guide?.offendingLocation, "/Users/rocky/Library/Application Support/ssh/known hosts:7")
    }

    @MainActor
    func testSSHHostKeyRepairGuideFormatsIPv6KnownHostsTargets() {
        let defaultPort = SSHConnectionIssueRepairGuide.hostKeyGuide(
            for: SSHConnectionProfile(host: "2001:db8::10", port: 22),
            diagnosticText: "Host key verification failed."
        )
        let customPort = SSHConnectionIssueRepairGuide.hostKeyGuide(
            for: SSHConnectionProfile(host: "2001:db8::10", port: 2222),
            diagnosticText: "Host key verification failed."
        )
        let bracketedCustomPort = SSHConnectionIssueRepairGuide.hostKeyGuide(
            for: SSHConnectionProfile(host: "[2001:db8::10]", port: 2222),
            diagnosticText: "Host key verification failed."
        )

        XCTAssertEqual(defaultPort?.knownHostsTarget, "2001:db8::10")
        XCTAssertEqual(defaultPort?.removalCommand, "ssh-keygen -R '2001:db8::10'")
        XCTAssertEqual(customPort?.knownHostsTarget, "[2001:db8::10]:2222")
        XCTAssertEqual(customPort?.removalCommand, "ssh-keygen -R '[2001:db8::10]:2222'")
        XCTAssertEqual(bracketedCustomPort?.knownHostsTarget, "[2001:db8::10]:2222")
        XCTAssertEqual(bracketedCustomPort?.removalCommand, "ssh-keygen -R '[2001:db8::10]:2222'")
    }

    func testSSHConfigRendersPerHopIdentityAndProxyJump() {
        let firstJump = SSHJumpHost(
            name: "bastion",
            host: "jump1.example.com",
            user: "ops",
            port: 2222,
            identityFiles: ["~/.ssh/jump1"]
        )
        let secondJump = SSHJumpHost(
            host: "jump2.example.com",
            user: "root",
            port: 22,
            identityFiles: ["~/.ssh/jump2"]
        )
        let profile = SSHConnectionProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Prod",
            host: "prod.internal",
            user: "deploy",
            port: 2200,
            identityFiles: ["~/.ssh/prod"],
            jumpHosts: [firstJump, secondJump],
            extraOptions: ["ServerAliveInterval 30"]
        )

        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("Host museterm-11111111-1111-1111-1111-111111111111-jump-1"))
        XCTAssertTrue(config.contains("IdentityFile "))
        XCTAssertTrue(config.contains("ProxyJump museterm-11111111-1111-1111-1111-111111111111-jump-1"))
        XCTAssertTrue(config.contains("ProxyJump museterm-11111111-1111-1111-1111-111111111111-jump-2"))
        XCTAssertTrue(config.contains("HostName prod.internal"))
        XCTAssertTrue(config.contains("ServerAliveInterval 30"))
    }

    func testSSHConfigExportSnippetUsesPortableControlPath() {
        let profile = SSHConnectionProfile(
            host: "prod.internal",
            user: "deploy",
            connectionReuseEnabled: true,
            connectionReusePersistMinutes: 15
        )

        let snippet = SSHConfigMaterializer.exportSnippet(for: profile)

        XCTAssertTrue(snippet.contains("# Generated by MuseTerm."))
        XCTAssertTrue(snippet.contains("HostName prod.internal"))
        XCTAssertTrue(snippet.contains("User deploy"))
        XCTAssertTrue(snippet.contains("ControlPersist 15m"))
        XCTAssertTrue(snippet.contains("ControlPath \"~/.ssh/museterm-cm-%C\""))
        XCTAssertFalse(snippet.contains("Library/Application Support/MuseTerm/SSH"))
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }

    func section(from startMarker: String, to endMarker: String) -> String {
        guard
            let start = range(of: startMarker),
            let end = range(of: endMarker, range: start.upperBound..<endIndex)
        else {
            return ""
        }
        return String(self[start.lowerBound..<end.lowerBound])
    }
}
