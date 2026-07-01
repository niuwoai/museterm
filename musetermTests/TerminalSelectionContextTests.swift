import XCTest
@testable import museterm

final class TerminalSelectionContextTests: XCTestCase {
    func testBuildsURLContext() throws {
        let context = try XCTUnwrap(TerminalSelectionContext(selection: "example.com:8080/path"))

        XCTAssertEqual(context.normalizedURL?.absoluteString, "http://example.com:8080/path")
        XCTAssertEqual(context.port, nil)
        XCTAssertEqual(context.escapedPathArgument, "'example.com:8080/path'")
        XCTAssertFalse(context.isLikelyPath)
        XCTAssertEqual(context.markdownCodeBlock, "```text\nexample.com:8080/path\n```")
        XCTAssertTrue(context.aiPrompt.contains("example.com:8080/path"))
    }

    func testBuildsPortPIDAndGitContexts() throws {
        XCTAssertEqual(TerminalSelectionContext(selection: ":3000")?.port, 3000)
        XCTAssertEqual(TerminalSelectionContext(selection: "12345")?.pid, 12_345)
        XCTAssertEqual(
            TerminalSelectionContext(selection: "abc1234def5678")?.gitHash,
            "abc1234def5678"
        )
        XCTAssertNil(TerminalSelectionContext(selection: "70000")?.port)
    }

    func testBuildsPrettyJSONAndTransformContext() throws {
        let context = try XCTUnwrap(TerminalSelectionContext(selection: #"{"b":2,"a":1}"#))

        XCTAssertEqual(context.prettyJSON, "{\n  \"a\" : 1,\n  \"b\" : 2\n}")
        XCTAssertEqual(context.markdownCodeBlock, "```json\n{\"b\":2,\"a\":1}\n```")
        XCTAssertEqual(context.base64EncodedText, "eyJiIjoyLCJhIjoxfQ==")
        XCTAssertEqual(
            TerminalSelectionContext(selection: "eyJiIjoyLCJhIjoxfQ==")?.base64DecodedText,
            #"{"b":2,"a":1}"#
        )
        XCTAssertEqual(
            TerminalSelectionContext(selection: "hello%20world")?.urlDecodedText,
            "hello world"
        )
    }

    func testBuildsInteractiveRemoveCommand() throws {
        let context = try XCTUnwrap(TerminalSelectionContext(selection: "my file.txt"))

        XCTAssertEqual(context.interactiveRemoveCommand, "rm -i -- 'my file.txt'")
    }
}
