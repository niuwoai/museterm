import XCTest
@testable import museterm

@MainActor
final class SSHConnectionProfileTests: XCTestCase {
    func testSSHConfigAddsDefaultKeepAliveOptions() {
        let profile = SSHConnectionProfile(host: "example.com", user: "deploy")
        let config = SSHConfigMaterializer.renderConfig(profile: profile)

        XCTAssertTrue(config.contains("  ServerAliveInterval 30"))
        XCTAssertTrue(config.contains("  ServerAliveCountMax 6"))
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
    func testSSHHostKeyRepairGuideBuildsKnownHostsCommandForCustomPort() {
        let profile = SSHConnectionProfile(host: "example.com", port: 2222)
        let guide = SSHConnectionIssueRepairGuide.hostKeyGuide(
            for: profile,
            diagnosticText: "Offending ECDSA key in /Users/rocky/.ssh/known_hosts:42"
        )

        XCTAssertEqual(guide?.knownHostsTarget, "[example.com]:2222")
        XCTAssertEqual(guide?.removalCommand, "ssh-keygen -R '[example.com]:2222'")
        XCTAssertEqual(guide?.offendingLocation, "/Users/rocky/.ssh/known_hosts:42")
        XCTAssertTrue(guide?.message.contains("ssh-keygen -R '[example.com]:2222'") ?? false)
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
