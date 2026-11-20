import XCTest
@testable import museterm

@MainActor
final class TerminalReminderTests: XCTestCase {
    func testBellParserIgnoresControlPayloadAcrossEverySplit() {
        let bytes = Array("\u{1b}]0;title\u{7}\u{1b}]777;MuseTerm;end=1\u{7}\u{1b}Ppayload\u{7}\u{1b}\\\u{1b}_payload\u{7}\u{1b}\\\u{7}".utf8)
        for split in 0...bytes.count {
            let parser = TerminalBellParser()
            XCTAssertEqual(parser.accept(bytes[..<split]) + parser.accept(bytes[split...]), 1)
        }
    }

    func testBellParserHandlesMultipleBellsAndCancelledOSC() {
        let parser = TerminalBellParser()
        XCTAssertEqual(parser.accept(Array("\u{7}\u{7}\u{1b}]unfinished\u{18}\u{7}".utf8)[...]), 3)
        XCTAssertEqual(parser.accept(Array("\u{1b}[1\u{7};2m\u{7}".utf8)[...]), 2)
    }

    func testReminderPolicyRequiresExplicitSuccessOrFailure() {
        let policy = TerminalReminderPolicy(longCommandSeconds: 1, failureMinimumSeconds: 5)
        for state in [TerminalCommandLifecycleState.running, .interrupted, .superseded, .completedUnknownStatus] {
            XCTAssertFalse(policy.allowsCommand(state: state, duration: 100, isLowInformation: false, hasErrorSignal: true))
        }
        XCTAssertTrue(policy.allowsCommand(state: .succeeded, duration: 1, isLowInformation: true, hasErrorSignal: false))
        XCTAssertFalse(policy.allowsCommand(state: .failed, duration: 100, isLowInformation: true, hasErrorSignal: true))
        XCTAssertTrue(policy.allowsCommand(state: .failed, duration: 0, isLowInformation: false, hasErrorSignal: true))
        XCTAssertFalse(policy.allowsCommand(state: .failed, duration: 4, isLowInformation: false, hasErrorSignal: false))
    }

    func testInvalidReminderThresholdsAreRejected() {
        XCTAssertFalse(TerminalReminderPolicy(longCommandSeconds: .infinity).isValid)
        XCTAssertFalse(TerminalReminderPolicy(failureMinimumSeconds: -1).isValid)
        XCTAssertTrue(TerminalReminderPolicy(longCommandSeconds: 0, failureMinimumSeconds: 0).isValid)
        XCTAssertTrue(TerminalReminderPolicy.isLowInformationCommand("builtin command false"))
        XCTAssertFalse(TerminalReminderPolicy.isLowInformationCommand("make test"))
    }

    func testNativeAgentBellsUseSemanticStateAndKeepUnknownFallback() throws {
        let policy = TerminalReminderPolicy()
        var monitor = TerminalAgentMonitor()
        let grant = try monitor.bind(kind: .willdeep, now: Date())
        XCTAssertTrue(policy.allowsBell(agent: monitor.snapshot, hasSemanticItem: false))
        try monitor.report(.init(instanceID: grant.instanceID, runID: grant.runID, token: grant.token,
            sequence: 1, activity: .working), now: Date())
        XCTAssertFalse(policy.allowsBell(agent: monitor.snapshot, hasSemanticItem: false))
        monitor.expire(now: Date().addingTimeInterval(200))
        XCTAssertTrue(policy.allowsBell(agent: monitor.snapshot, hasSemanticItem: false))
        XCTAssertFalse(policy.allowsBell(agent: monitor.snapshot, hasSemanticItem: true))
        XCTAssertTrue(policy.allowsBell(agent: nil, hasSemanticItem: false))
    }

    func testRuntimeTerminalItemsUseBackendAcknowledgementAndIgnoreLatePackets() throws {
        let serviceEvents = TerminalSessionEventStore(), service = TerminalAttentionStore(events: serviceEvents)
        let uiEvents = TerminalSessionEventStore(), ui = TerminalAttentionStore(events: uiEvents)
        let tab = UUID(), generation = UUID()
        let context = TerminalAttentionTerminalContext(kind: .bell, eventID: generation, commandID: nil, exitCode: nil, failed: false)
        let first = try XCTUnwrap(service.recordTerminal(context, tabID: tab))
        ui.markRuntimeAuthorityExternal(tabID: tab)
        ui.adoptAgentItems([first], tabID: tab, cursor: serviceEvents.cursor)
        var acknowledged = false
        ui.externalAcknowledgement[tab] = { id, version in
            acknowledged = id == first.id && version == first.version
            return true
        }
        try ui.markRead(id: first.id, version: first.version)
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(ui.hasUnread(tabID: tab), "UI cannot invent acknowledgement before service confirmation")
        try service.markRead(id: first.id, version: first.version)
        ui.adoptAgentItems(service.activeItems, tabID: tab, cursor: serviceEvents.cursor)
        ui.adoptAgentItems([first], tabID: tab, cursor: .init(appEpoch: serviceEvents.appEpoch, sequence: first.createdSequence))
        XCTAssertTrue(ui.activeItems.isEmpty)
        XCTAssertFalse(ui.hasUnread(tabID: tab))
        let next = try XCTUnwrap(service.recordTerminal(context, tabID: tab))
        XCTAssertNotEqual(first.id, next.id, "A new bell after acknowledgement is a new unread reminder")
    }

    func testBellBatchCoalescesOccurrencesAndCommandDedupSurvivesRead() throws {
        let events = TerminalSessionEventStore(), store = TerminalAttentionStore(events: events), tab = UUID()
        var bell = TerminalAttentionTerminalContext(kind: .bell, eventID: UUID(), commandID: nil, exitCode: nil, failed: false)
        bell.occurrences = 3
        let first = try XCTUnwrap(store.recordTerminal(bell, tabID: tab))
        _ = store.recordTerminal(bell, tabID: tab)
        XCTAssertEqual(store.activeItems.count, 1)
        XCTAssertEqual(store.activeItems.first?.terminal?.occurrences, 6)
        let id = UUID()
        let command = TerminalAttentionTerminalContext(kind: .commandFinished, eventID: id, commandID: id, exitCode: 1, failed: true)
        let item = try XCTUnwrap(store.recordTerminal(command, tabID: tab))
        try store.markRead(id: item.id, version: item.version)
        XCTAssertNil(store.recordTerminal(command, tabID: tab))
        XCTAssertEqual(store.activeItems.first?.id, first.id)
    }
}
