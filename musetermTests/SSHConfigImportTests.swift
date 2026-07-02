import XCTest
@testable import museterm

final class SSHConfigImportTests: XCTestCase {
    func testOpenSSHConfigImporterParsesCommonHostBlock() throws {
        let config = """
        Host prod-app
          HostName prod.internal
          User deploy
          Port 2222
          IdentityFile "~/.ssh/prod key"
          ProxyJump ops@bastion.example.com:2200,edge.example.com
          LocalForward 127.0.0.1:8080 10.0.0.5:80
          RemoteForward 9000 127.0.0.1:9000
          DynamicForward 1080
          ServerAliveInterval 45
          ServerAliveCountMax 4
          ControlMaster auto
          ControlPersist 20m
          StrictHostKeyChecking no
        """

        let profile = try XCTUnwrap(OpenSSHConfigImporter.profiles(from: config).first)

        XCTAssertEqual(profile.name, "prod-app")
        XCTAssertEqual(profile.host, "prod.internal")
        XCTAssertEqual(profile.user, "deploy")
        XCTAssertEqual(profile.port, 2222)
        XCTAssertEqual(profile.identityFiles, ["~/.ssh/prod key"])
        XCTAssertEqual(profile.jumpHosts.map(\.host), ["bastion.example.com", "edge.example.com"])
        XCTAssertEqual(profile.jumpHosts.first?.user, "ops")
        XCTAssertEqual(profile.jumpHosts.first?.port, 2200)
        XCTAssertEqual(profile.portForwards.map(\.kind), [.local, .remote, .dynamic])
        XCTAssertEqual(profile.portForwards[0].bindHost, "127.0.0.1")
        XCTAssertEqual(profile.portForwards[0].bindPort, 8080)
        XCTAssertEqual(profile.portForwards[0].destinationHost, "10.0.0.5")
        XCTAssertEqual(profile.portForwards[0].destinationPort, 80)
        XCTAssertEqual(profile.keepAliveIntervalSeconds, 45)
        XCTAssertEqual(profile.keepAliveCountMax, 4)
        XCTAssertTrue(profile.connectionReuseEnabled)
        XCTAssertEqual(profile.connectionReusePersistMinutes, 20)
        XCTAssertEqual(profile.extraOptions, ["StrictHostKeyChecking no"])
    }

    func testOpenSSHConfigImporterSupportsEqualsSeparatedOptions() throws {
        let config = """
        Host prod-equals
          HostName = prod.example.com
          User=deploy
          Port = 2200
          IdentityFile = "~/.ssh/prod key"
        """

        let profile = try XCTUnwrap(OpenSSHConfigImporter.profiles(from: config).first)

        XCTAssertEqual(profile.host, "prod.example.com")
        XCTAssertEqual(profile.user, "deploy")
        XCTAssertEqual(profile.port, 2200)
        XCTAssertEqual(profile.identityFiles, ["~/.ssh/prod key"])
    }

    func testOpenSSHConfigImporterNormalizesBracketedIPv6PortForwards() throws {
        let config = """
        Host ipv6-tunnel
          HostName tunnel.example.com
          LocalForward [::1]:8443 [2001:db8::20]:443
          RemoteForward 9443 [2001:db8::30]:9443
          DynamicForward [::]:1080
        """

        let profile = try XCTUnwrap(OpenSSHConfigImporter.profiles(from: config).first)

        XCTAssertEqual(profile.portForwards.count, 3)
        XCTAssertEqual(profile.portForwards[0].kind, .local)
        XCTAssertEqual(profile.portForwards[0].bindHost, "::1")
        XCTAssertEqual(profile.portForwards[0].bindPort, 8443)
        XCTAssertEqual(profile.portForwards[0].destinationHost, "2001:db8::20")
        XCTAssertEqual(profile.portForwards[0].destinationPort, 443)
        XCTAssertEqual(profile.portForwards[1].kind, .remote)
        XCTAssertEqual(profile.portForwards[1].bindHost, "")
        XCTAssertEqual(profile.portForwards[1].bindPort, 9443)
        XCTAssertEqual(profile.portForwards[1].destinationHost, "2001:db8::30")
        XCTAssertEqual(profile.portForwards[1].destinationPort, 9443)
        XCTAssertEqual(profile.portForwards[2].kind, .dynamic)
        XCTAssertEqual(profile.portForwards[2].bindHost, "::")
        XCTAssertEqual(profile.portForwards[2].bindPort, 1080)
        XCTAssertTrue(profile.portForwardSummaryText.contains("[::1]:8443"))
        XCTAssertTrue(profile.portForwardSummaryText.contains("[2001:db8::20]:443"))
        XCTAssertTrue(profile.portForwardSummaryText.contains("[2001:db8::30]:9443"))
        XCTAssertTrue(profile.portForwardSummaryText.contains("[::]:1080"))
        XCTAssertEqual(
            profile.portForwardAccessEntries,
            [
                SSHPortForwardAccessEntry(kind: .local, urlString: "https://[::1]:8443"),
                SSHPortForwardAccessEntry(kind: .dynamic, urlString: "socks5://localhost:1080")
            ]
        )
    }

    func testOpenSSHConfigImporterNormalizesBracketedIPv6ProxyJumpHosts() throws {
        let config = """
        Host ipv6-prod
          HostName prod.example.com
          ProxyJump ops@[2001:db8::10]:2200,[2001:db8::11]
        """

        let profile = try XCTUnwrap(OpenSSHConfigImporter.profiles(from: config).first)

        XCTAssertEqual(profile.jumpHosts.count, 2)
        XCTAssertEqual(profile.jumpHosts[0].user, "ops")
        XCTAssertEqual(profile.jumpHosts[0].host, "2001:db8::10")
        XCTAssertEqual(profile.jumpHosts[0].port, 2200)
        XCTAssertEqual(profile.jumpHosts[1].user, "")
        XCTAssertEqual(profile.jumpHosts[1].host, "2001:db8::11")
        XCTAssertEqual(profile.jumpHosts[1].port, 22)
        XCTAssertFalse(profile.routeSummary.contains("[2001:db8::10]"))
        XCTAssertEqual(profile.jumpHosts.map(\.displayName), ["ops@2001:db8::10", "2001:db8::11"])
        let preview = SSHConfigMaterializer.preview(for: profile)
        XCTAssertTrue(preview.config.contains("HostName 2001:db8::10"))
        XCTAssertTrue(preview.config.contains("ProxyJump museterm-"))
    }

    func testOpenSSHConfigImporterKeepsBareIPv6ProxyJumpHostIntact() throws {
        let config = """
        Host ipv6-dev
          HostName dev.example.com
          ProxyJump 2001:db8::11
        """

        let profile = try XCTUnwrap(OpenSSHConfigImporter.profiles(from: config).first)

        XCTAssertEqual(profile.jumpHosts.count, 1)
        XCTAssertEqual(profile.jumpHosts[0].host, "2001:db8::11")
        XCTAssertEqual(profile.jumpHosts[0].port, 22)
    }

    func testOpenSSHConfigImporterExpandsMultipleExplicitAliasesInHostBlock() throws {
        let config = """
        Host prod prod-short
          HostName prod.example.com
          User deploy
          Port 2222
          IdentityFile ~/.ssh/prod
        """

        let profiles = OpenSSHConfigImporter.profiles(from: config)

        XCTAssertEqual(profiles.map(\.name), ["prod", "prod-short"])
        XCTAssertEqual(profiles.map(\.host), ["prod.example.com", "prod.example.com"])
        XCTAssertEqual(profiles.map(\.user), ["deploy", "deploy"])
        XCTAssertEqual(profiles.map(\.port), [2222, 2222])
        XCTAssertEqual(profiles.map(\.identityFiles), [["~/.ssh/prod"], ["~/.ssh/prod"]])
    }

    func testOpenSSHConfigImporterDeduplicatesAliasesAndSkipsPatterns() throws {
        let config = """
        Host dev dev *.internal !blocked dev
          User deploy

        Host raw raw-alt
          User ops
        """

        let profiles = OpenSSHConfigImporter.profiles(from: config)

        XCTAssertEqual(profiles.map(\.name), ["dev", "raw", "raw-alt"])
        XCTAssertEqual(profiles.map(\.host), ["dev", "raw", "raw-alt"])
        XCTAssertEqual(profiles.map(\.user), ["deploy", "ops", "ops"])
    }

    func testOpenSSHConfigImporterSkipsMalformedBracketedProxyJumpHost() throws {
        let config = """
        Host ipv6-bad
          HostName bad.example.com
          ProxyJump [2001:db8::11
        """

        let profile = try XCTUnwrap(OpenSSHConfigImporter.profiles(from: config).first)

        XCTAssertTrue(profile.jumpHosts.isEmpty)
    }

    @MainActor
    func testSSHConnectionStoreImportsExplicitHostsAndReplacesByName() throws {
        let suiteName = "museterm.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SSHConnectionStore(defaults: defaults)
        let config = """
        Host *
          User ignored

        Host prod
          HostName old.example.com

        Host prod
          HostName new.example.com
          User deploy
        """

        XCTAssertEqual(store.importProfiles(OpenSSHConfigImporter.profiles(from: config)), 2)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "prod")
        XCTAssertEqual(store.profiles.first?.host, "new.example.com")
        XCTAssertEqual(store.profiles.first?.user, "deploy")
    }
}
