import XCTest
@testable import museterm

final class TerminalRuntimeCapacityTests: XCTestCase {
    func testResponseBudgetIsIndependentFromUnchangedRequestBudget() {
        XCTAssertEqual(TerminalRuntimeLimits.maximumFrameBytes, 131_072)
        XCTAssertGreaterThan(TerminalRuntimeLimits.maximumResponseBytes, TerminalRuntimeLimits.maximumFrameBytes)
        XCTAssertGreaterThan(TerminalRuntimeLimits.maximumClientQueueBytes, TerminalRuntimeLimits.maximumResponseBytes)
    }

    func testOversizedReplyReturnsSmallErrorWithSameIdentity() throws {
        var response = TerminalRuntimeResponse(serviceEpoch: UUID(), id: UUID(), action: .read)
        response.data = Data(repeating: 65, count: TerminalRuntimeLimits.maximumResponseBytes)
        let frame = try response.encodedTransportFrame(using: JSONEncoder())
        XCTAssertEqual(frame.last, 10)
        XCTAssertLessThan(frame.count, TerminalRuntimeLimits.maximumFrameBytes)
        let rejected = try JSONDecoder().decode(TerminalRuntimeResponse.self, from: frame.dropLast())
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.error, "response_too_large")
        XCTAssertEqual(rejected.id, response.id)
        XCTAssertEqual(rejected.serviceEpoch, response.serviceEpoch)
        XCTAssertEqual(rejected.action, response.action)
        XCTAssertNil(rejected.data)
    }
}
