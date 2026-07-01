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

    func testIgnoresPlainTerminalOutputWithoutMarkers() {
        let parser = TerminalShellIntegrationParser()

        XCTAssertEqual(parser.accept(Array("build output\nerror: nope\n".utf8)[...]), [])
    }
}
