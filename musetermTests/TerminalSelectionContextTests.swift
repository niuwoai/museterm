import XCTest
@testable import museterm

final class TerminalSelectionContextTests: XCTestCase {
    func testBuildsURLContext() throws {
        let context = try XCTUnwrap(TerminalSelectionContext(selection: "example.com:8080/path"))

        XCTAssertEqual(context.normalizedURL?.absoluteString, "http://example.com:8080/path")
        XCTAssertEqual(context.port, 8080)
        XCTAssertEqual(context.escapedPathArgument, "'example.com:8080/path'")
        XCTAssertFalse(context.isLikelyPath)
        XCTAssertEqual(context.markdownCodeBlock, "```text\nexample.com:8080/path\n```")
        XCTAssertTrue(context.aiPrompt.contains("example.com:8080/path"))
    }

    func testBuildsPortPIDAndGitContexts() throws {
        XCTAssertEqual(TerminalSelectionContext(selection: ":3000")?.port, 3000)
        let hostPort = try XCTUnwrap(TerminalSelectionContext(selection: "localhost:3000"))
        XCTAssertEqual(hostPort.normalizedURL?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(hostPort.port, 3000)

        let pid = try XCTUnwrap(TerminalSelectionContext(selection: "12345"))
        XCTAssertNil(pid.port)
        XCTAssertEqual(pid.pid, 12_345)
        XCTAssertEqual(
            TerminalSelectionContext(selection: "abc1234def5678")?.gitHash,
            "abc1234def5678"
        )
        XCTAssertNil(TerminalSelectionContext(selection: "70000")?.port)
        XCTAssertNil(TerminalSelectionContext(selection: ":70000")?.port)
        XCTAssertNil(TerminalSelectionContext(selection: "localhost:70000")?.normalizedURL)
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

    func testBase64DecodedTextAvoidsPlainTextFalsePositives() throws {
        XCTAssertEqual(
            TerminalSelectionContext(selection: "SGVsbG8gd29ybGQ=")?.base64DecodedText,
            "Hello world"
        )
        XCTAssertEqual(
            TerminalSelectionContext(selection: "SGVsbG8g\nd29ybGQ=")?.base64DecodedText,
            "Hello world"
        )
        XCTAssertNil(TerminalSelectionContext(selection: "hello")?.base64DecodedText)
        XCTAssertNil(TerminalSelectionContext(selection: "abcd")?.base64DecodedText)
        XCTAssertNil(TerminalSelectionContext(selection: "YWJjZA")?.base64DecodedText)
        XCTAssertNil(TerminalSelectionContext(selection: "YWJjZA==$")?.base64DecodedText)
        XCTAssertNil(TerminalSelectionContext(selection: "YQ==")?.base64DecodedText)
    }

    func testBuildsInteractiveRemoveCommand() throws {
        let context = try XCTUnwrap(TerminalSelectionContext(selection: "my file.txt"))

        XCTAssertEqual(context.interactiveRemoveCommand, "rm -i -- 'my file.txt'")
    }

    func testPathDetectionAvoidsPlainTextAndVersions() throws {
        XCTAssertEqual(TerminalSelectionContext(selection: "permission denied")?.isLikelyPath, false)
        XCTAssertEqual(TerminalSelectionContext(selection: "1.2.3")?.isLikelyPath, false)
        XCTAssertEqual(TerminalSelectionContext(selection: "release notes")?.isLikelyPath, false)
    }

    func testPathDetectionKeepsFileLikeSelections() throws {
        XCTAssertEqual(TerminalSelectionContext(selection: "my file.txt")?.isLikelyPath, true)
        XCTAssertEqual(TerminalSelectionContext(selection: ".env")?.isLikelyPath, true)
        XCTAssertEqual(TerminalSelectionContext(selection: "./Scripts/build.sh")?.isLikelyPath, true)
    }
}
