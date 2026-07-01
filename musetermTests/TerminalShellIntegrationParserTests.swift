import XCTest
@testable import museterm

final class TerminalShellIntegrationParserTests: XCTestCase {
    func testAcceptsMarkerPrefixSplitAcrossChunks() {
        let parser = TerminalShellIntegrationParser()

        XCTAssertEqual(parser.accept(Array("noise\u{1B}]777;Muse".utf8)[...]), [])
        XCTAssertEqual(parser.accept(Array("Term;end=0\u{7}".utf8)[...]), [.commandFinished(0)])
    }

    func testSkipsMalformedMarkerAndContinuesWithNextValidMarker() {
        let parser = TerminalShellIntegrationParser()
        let text = "\u{1B}]777;MuseTerm;start=not-hex\u{7}noise\u{1B}]777;MuseTerm;end=2\u{7}"

        XCTAssertEqual(parser.accept(Array(text.utf8)[...]), [.commandFinished(2)])
    }

    func testAcceptsStringTerminatorMarker() {
        let parser = TerminalShellIntegrationParser()
        let marker = "\u{1B}]777;MuseTerm;start=6563686f206f6b\u{1B}\\"

        XCTAssertEqual(parser.accept(Array(marker.utf8)[...]), [.commandStarted("echo ok")])
    }

    func testAcceptsStringTerminatorSplitAcrossChunks() {
        let parser = TerminalShellIntegrationParser()

        XCTAssertEqual(parser.accept(Array("\u{1B}]777;MuseTerm;end=9\u{1B}".utf8)[...]), [])
        XCTAssertEqual(parser.accept(Array("\\".utf8)[...]), [.commandFinished(9)])
    }

    func testParsesMixedBelAndStringTerminatorMarkersInOrder() {
        let parser = TerminalShellIntegrationParser()
        let text = "\u{1B}]777;MuseTerm;end=1\u{7}\u{1B}]777;MuseTerm;end=2\u{1B}\\"

        XCTAssertEqual(parser.accept(Array(text.utf8)[...]), [.commandFinished(1), .commandFinished(2)])
    }

    func testAcceptsShellDetectedMarker() {
        let parser = TerminalShellIntegrationParser()
        let marker = "\u{1B}]777;MuseTerm;shell=/usr/local/bin/fish\u{7}"

        XCTAssertEqual(parser.accept(Array(marker.utf8)[...]), [.shellDetected("/usr/local/bin/fish")])
    }

    func testIgnoresPlainTerminalOutputWithoutMarkers() {
        let parser = TerminalShellIntegrationParser()

        XCTAssertEqual(parser.accept(Array("build output\nerror: nope\n".utf8)[...]), [])
    }
}
