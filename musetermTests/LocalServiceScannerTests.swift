import XCTest
@testable import museterm

final class LocalServiceScannerTests: XCTestCase {
    func testListeningPortSearchMatchesProcessDirectoryAndServiceName() {
        let port = LocalListeningPort(
            pid: 4242,
            command: "node",
            protocolName: "TCP",
            endpoint: "127.0.0.1:5173",
            port: 5173,
            serviceName: "vite",
            workingDirectory: "/Users/tester/Sites/museterm"
        )

        XCTAssertTrue(port.matchesSearch("node"))
        XCTAssertTrue(port.matchesSearch("museterm"))
        XCTAssertTrue(port.matchesSearch("vite"))
        XCTAssertTrue(port.matchesSearch("5173"))
        XCTAssertTrue(port.matchesSearch("127.0.0.1"))
        XCTAssertTrue(port.matchesSearch("node museterm"))
        XCTAssertFalse(port.matchesSearch("postgres"))
    }

    func testLocalServiceScannerParsesWorkingDirectoryFields() {
        let text = "p42\nn/Users/tester/Sites/museterm\np99\nn/private/tmp/demo\n"

        XCTAssertEqual(
            LocalServiceScanner.parseWorkingDirectoryFields(text),
            [
                42: "/Users/tester/Sites/museterm",
                99: "/private/tmp/demo"
            ]
        )
    }

    func testLocalServiceScannerResolvesCommonPortNames() {
        XCTAssertEqual(LocalServiceScanner.serviceName(for: 5173), "vite")
        XCTAssertEqual(LocalServiceScanner.serviceName(for: 5432), "postgres")
    }

    func testLocalServiceScannerDecodesEscapedUTF8ProcessNames() {
        let text = """
        p88
        c\\xe4\\xbc\\x81\\xe4\\xb8\\x9a\\xe5\\xbe\\xae\\xe4\\xbf\\xa1
        PTCP
        n127.0.0.1:50010
        """

        let ports = LocalServiceScanner.parseLsofFields(text)

        XCTAssertEqual(ports.first?.command, "企业微信")
        XCTAssertEqual(LocalServiceScanner.decodeLsofEscapedText("\\344\\274\\201"), "企")
        XCTAssertTrue(ports.first?.matchesSearch("企业") == true)
    }

    func testLocalServiceScannerParsesLsofFieldsUniquelyAndSortsByPort() {
        let text = """
        p42
        cnode
        PTCP
        n*:5173
        n*:5173
        p7
        cpostgres
        PTCP
        n127.0.0.1:5432
        """

        let ports = LocalServiceScanner.parseLsofFields(text)

        XCTAssertEqual(ports.map(\.port), [5173, 5432])
        XCTAssertEqual(ports.map(\.command), ["node", "postgres"])
        XCTAssertEqual(ports.map(\.pid), [42, 7])
        XCTAssertTrue(ports.allSatisfy { $0.serviceName == nil })
        XCTAssertTrue(ports.allSatisfy { $0.workingDirectory == nil })
    }
}
