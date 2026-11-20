import XCTest
@testable import museterm

final class RunbookSensitiveRedactorTests: XCTestCase {
    func testRedactsCommonProviderAndRepositoryTokens() {
        let githubFineGrainedLikeToken = "github" + "_pat_" + "1234567890abcdefghijklmnopqrstuvwxyz"
        let googleLikeKey = "AI" + "za" + "1234567890abcdefghijklmnopqrstuvwxy"
        let npmLikeToken = "npm" + "_" + "1234567890abcdefghijklmnopqrstuvwxyz"
        let stripeLikeKey = "sk" + "_live_" + "1234567890abcdefghijklmnop"
        let githubClassicLikeToken = "gh" + "p_" + "1234567890abcdefghijklmnop"
        let text = [
            githubFineGrainedLikeToken,
            googleLikeKey,
            npmLikeToken,
            stripeLikeKey,
            "Authorization: Bearer \(githubClassicLikeToken)"
        ].joined(separator: "\n")

        let redacted = RunbookSensitiveRedactor.redact(text)

        XCTAssertFalse(redacted.contains(githubFineGrainedLikeToken))
        XCTAssertFalse(redacted.contains(googleLikeKey))
        XCTAssertFalse(redacted.contains(npmLikeToken))
        XCTAssertFalse(redacted.contains(stripeLikeKey))
        XCTAssertFalse(redacted.contains(githubClassicLikeToken))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func testRedactsCommandLineSecretArgumentsAndBasicAuthURLPassword() {
        let text = """
        curl --token secret-token-123 https://api.example.com
        deploy --password='prod-password'
        git clone https://user:secretpass@example.com/repo.git
        """

        let redacted = RunbookSensitiveRedactor.redact(text)

        XCTAssertFalse(redacted.contains("secret-token-123"))
        XCTAssertFalse(redacted.contains("prod-password"))
        XCTAssertFalse(redacted.contains("secretpass"))
        XCTAssertTrue(redacted.contains("--token [REDACTED]"))
        XCTAssertTrue(redacted.contains("--password=[REDACTED]"))
        XCTAssertTrue(redacted.contains("https://user:[REDACTED]@example.com/repo.git"))
    }

    func testRedactsPEMPrivateKeyBlocksAcrossLines() {
        let text = """
        before
        -----BEGIN PRIVATE KEY-----
        abcdef
        ghijkl
        -----END PRIVATE KEY-----
        after
        """

        let redacted = RunbookSensitiveRedactor.redact(text)

        XCTAssertTrue(redacted.contains("before"))
        XCTAssertTrue(redacted.contains("after"))
        XCTAssertFalse(redacted.contains("BEGIN PRIVATE KEY"))
        XCTAssertFalse(redacted.contains("abcdef"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
        XCTAssertTrue(RunbookSensitiveRedactor.containsSensitiveData(text))
    }

    func testDoesNotFlagOrdinaryOutput() {
        let text = "git status --short\nM Sources/App.swift\nBuild completed in 120ms"

        XCTAssertEqual(RunbookSensitiveRedactor.redact(text), text)
        XCTAssertFalse(RunbookSensitiveRedactor.containsSensitiveData(text))
    }
}
