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
