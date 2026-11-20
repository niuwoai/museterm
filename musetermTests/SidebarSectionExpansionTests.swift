import AppKit
import SwiftUI
import XCTest
@testable import museterm

@MainActor
final class SidebarSectionExpansionTests: XCTestCase {
    func testFirstRenderRestoresSavedOppositeDefaultsWithNilPreferencesArgument() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = TerminalPreferences(defaults: defaults)
        for kind in SidebarSectionKind.allCases {
            writer.setSidebarSection(kind, expanded: !SidebarSectionKind.defaultExpanded(kind))
        }
        let restored = TerminalPreferences(defaults: defaults)

        for kind in SidebarSectionKind.allCases {
            let hosted = host(SectionFixture(
                kind: kind, initiallyExpanded: SidebarSectionKind.defaultExpanded(kind)
            ).environmentObject(restored))
            defer { hosted.close() }

            assertSection(kind, expanded: !SidebarSectionKind.defaultExpanded(kind), in: hosted)
        }
    }

    func testTwoLiveHostsFollowSharedExpansionChanges() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = TerminalPreferences(defaults: defaults)
        let first = host(SectionFixture(kind: .shortcuts, initiallyExpanded: false)
            .environmentObject(preferences))
        let second = host(SectionFixture(kind: .shortcuts, initiallyExpanded: false)
            .environmentObject(preferences))
        defer {
            first.close()
            second.close()
        }
        assertSection(.shortcuts, expanded: false, in: first)
        assertSection(.shortcuts, expanded: false, in: second)
        let collapsedHeight = first.view.fittingSize.height

        preferences.setSidebarSection(.shortcuts, expanded: true)

        assertSection(.shortcuts, expanded: true, in: first)
        assertSection(.shortcuts, expanded: true, in: second)
        XCTAssertGreaterThan(first.view.fittingSize.height - collapsedHeight, Metrics.contentHeight)
        XCTAssertEqual(first.view.fittingSize.height, second.view.fittingSize.height, accuracy: 0.5)

        preferences.setSidebarSection(.shortcuts, expanded: false)

        assertSection(.shortcuts, expanded: false, in: first)
        assertSection(.shortcuts, expanded: false, in: second)
        XCTAssertEqual(first.view.fittingSize.height, collapsedHeight, accuracy: 0.5)
        XCTAssertEqual(second.view.fittingSize.height, collapsedHeight, accuracy: 0.5)
    }

    func testUntypedSectionUsesInitialExpansionWithoutEnvironmentObject() {
        for initiallyExpanded in [false, true] {
            let hosted = host(SectionFixture(kind: nil, initiallyExpanded: initiallyExpanded))
            defer { hosted.close() }

            assertSection(nil, expanded: initiallyExpanded, in: hosted)
        }
    }

    func testHiddenReorderedAndRecreatedSectionsRetainExpansionChoices() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = TerminalPreferences(defaults: defaults)
        preferences.setSidebarSection(.quickPaths, expanded: false)
        preferences.setSidebarSection(.shortcuts, expanded: true)
        let hosted = host(SidebarListFixture(preferences: preferences)
            .environmentObject(preferences))
        defer { hosted.close() }
        assertContent(.quickPaths, visible: false, in: hosted)
        assertContent(.shortcuts, visible: true, in: hosted)
        let originalHeight = hosted.view.fittingSize.height

        preferences.setSidebarSection(.shortcuts, visible: false)

        assertContent(.shortcuts, visible: false, in: hosted)
        XCTAssertLessThan(hosted.view.fittingSize.height, originalHeight - Metrics.contentHeight)
        preferences.setSidebarSection(.shortcuts, visible: true)
        assertContent(.shortcuts, visible: true, in: hosted)
        assertContent(.quickPaths, visible: false, in: hosted)
        XCTAssertEqual(hosted.view.fittingSize.height, originalHeight, accuracy: 0.5)

        preferences.sidebarSectionOrder = Array(preferences.sidebarSectionOrder.reversed())

        assertContent(.quickPaths, visible: false, in: hosted)
        assertContent(.shortcuts, visible: true, in: hosted)
        XCTAssertEqual(hosted.view.fittingSize.height, originalHeight, accuracy: 0.5)

        let restored = TerminalPreferences(defaults: defaults)
        let recreated = host(SidebarListFixture(preferences: restored)
            .environmentObject(restored))
        defer { recreated.close() }

        assertContent(.quickPaths, visible: false, in: recreated)
        assertContent(.shortcuts, visible: true, in: recreated)
        XCTAssertEqual(recreated.view.fittingSize.height, originalHeight, accuracy: 0.5)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SidebarSectionExpansionTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func host<Content: View>(_ content: Content) -> HostedSection {
        let view = NSHostingView(rootView: AnyView(content
            .frame(width: Metrics.hostWidth)
            .fixedSize(horizontal: false, vertical: true)
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: Metrics.hostWidth, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        return HostedSection(view: view, window: window)
    }

    private func assertSection(
        _ kind: SidebarSectionKind?, expanded: Bool, in hosted: HostedSection,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertContent(kind, visible: expanded, in: hosted, file: file, line: line)
        let height = hosted.view.fittingSize.height
        if expanded {
            XCTAssertGreaterThan(height, Metrics.contentHeight, file: file, line: line)
        } else {
            XCTAssertLessThan(height, Metrics.contentHeight, file: file, line: line)
        }
    }

    private func assertContent(
        _ kind: SidebarSectionKind?, visible: Bool, in hosted: HostedSection,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let identifier = Metrics.contentIdentifier(kind)
        RunLoop.main.run(until: Date().addingTimeInterval(Metrics.updateInterval))
        let deadline = Date().addingTimeInterval(Metrics.updateTimeout)
        repeat {
            _ = hosted.view.fittingSize
            hosted.view.layoutSubtreeIfNeeded()
            if contains(identifier, in: hosted.view) == visible,
               hosted.view.fittingSize.height > 0 {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(Metrics.updateInterval))
        } while Date() < deadline

        XCTAssertGreaterThan(hosted.view.fittingSize.height, 0, file: file, line: line)
        XCTAssertEqual(
            contains(identifier, in: hosted.view), visible,
            "Rendered content for \(kind?.rawValue ?? "untyped") must match its expansion choice",
            file: file, line: line
        )
    }

    private func contains(_ identifier: NSUserInterfaceItemIdentifier, in view: NSView) -> Bool {
        view.identifier == identifier || view.subviews.contains { contains(identifier, in: $0) }
    }

    private enum Metrics {
        static let contentHeight: CGFloat = 80
        static let hostWidth: CGFloat = 280
        static let updateTimeout: TimeInterval = 1
        static let updateInterval: TimeInterval = 0.01

        static func contentIdentifier(_ kind: SidebarSectionKind?) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("SidebarSectionExpansionTests.content.\(kind?.rawValue ?? "untyped")")
        }
    }

    @MainActor
    private struct HostedSection {
        let view: NSHostingView<AnyView>
        let window: NSWindow

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    private struct SectionFixture: View {
        let kind: SidebarSectionKind?
        let initiallyExpanded: Bool

        var body: some View {
            SidebarSection(
                title: "Section", systemImage: "folder", skin: .midnight,
                initiallyExpanded: initiallyExpanded, kind: kind, preferences: nil
            ) {
                ContentMarker(identifier: Metrics.contentIdentifier(kind))
                    .frame(height: Metrics.contentHeight)
            }
        }
    }

    @MainActor
    private struct SidebarListFixture: View {
        @ObservedObject var preferences: TerminalPreferences

        var body: some View {
            VStack(spacing: 0) {
                ForEach(preferences.visibleSidebarSections) { kind in
                    SectionFixture(kind: kind, initiallyExpanded: SidebarSectionKind.defaultExpanded(kind))
                }
            }
        }
    }

    @MainActor
    private struct ContentMarker: NSViewRepresentable {
        let identifier: NSUserInterfaceItemIdentifier

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = identifier
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
