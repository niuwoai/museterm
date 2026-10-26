import AppKit
import SwiftUI
import XCTest
@testable import museterm

@MainActor
final class TerminalAgentBadgeTests: XCTestCase {
    func testKnownBrandsHaveBundledImagesAndUnknownBrandFallsBack() {
        for brand in TerminalAgentBrand.allCases {
            XCTAssertNotNil(NSImage(named: brand.assetName), brand.rawValue)
            XCTAssertTrue(TerminalAgentBrandMark(identifier: brand.rawValue).hasLogo)
        }
        XCTAssertEqual(TerminalAgentBrand(identifier: "Claude Code"), .claude)
        XCTAssertEqual(TerminalAgentBrand(identifier: "willdeep-cli"), .willdeep)
        XCTAssertFalse(TerminalAgentBrandMark(identifier: "Other Agent").hasLogo)
    }

    func testCLICarrierIsDistinctAndBadgeFitsSidebar() throws {
        let cli = try render(TerminalAgentBrandMark(identifier: "codex"))
        let desktop = try render(TerminalAgentBrandMark(identifier: "codex", surface: .desktop))
        XCTAssertGreaterThan(cli.size.width, desktop.size.width)
        for kind in [TerminalAgentKind.codex, .claude, .willdeep] {
            let badge = try render(TerminalAgentBadge(status: snapshot(kind, .exited)))
            XCTAssertLessThanOrEqual(badge.size.width, 40)
            XCTAssertGreaterThan(badge.size.height, 15)
        }
        let fallback = try render(TerminalAgentBrandMark(identifier: "Other Agent"))
        XCTAssertGreaterThan(fallback.size.width, 30)
    }

    func testRenderLightAndDarkBadgeGallery() throws {
        for scheme in [ColorScheme.light, .dark] {
            let gallery = VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("CLI").frame(width: 70, alignment: .leading)
                    Text("Working").frame(width: 60)
                    Text("Waiting").frame(width: 60)
                    Text("Exited").frame(width: 60)
                }.font(.caption).foregroundStyle(.secondary)
                ForEach([TerminalAgentKind.codex, .claude, .willdeep], id: \.rawValue) { kind in
                    HStack {
                        Text(kind.rawValue).frame(width: 70, alignment: .leading)
                        ForEach([TerminalAgentActivity.working, .blocked, .exited], id: \.rawValue) { state in
                            TerminalAgentBadge(status: self.snapshot(kind, state)).frame(width: 60)
                        }
                    }
                }
                Divider()
                HStack(spacing: 20) {
                    Text("Desktop").font(.caption).foregroundStyle(.secondary)
                    ForEach(TerminalAgentBrand.allCases, id: \.rawValue) { brand in
                        TerminalAgentBrandMark(identifier: brand.rawValue, surface: .desktop)
                    }
                }
                TerminalAgentBrandMark(identifier: "Other Agent")
            }
            .padding(24)
            .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
            let image = try render(gallery)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let name = "qterm-rc33-agent-badges-\(scheme == .dark ? "dark" : "light")"
            try data.write(to: URL(fileURLWithPath: "/private/tmp/\(name).png"))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func render<Content: View>(_ content: Content) throws -> NSImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage)
    }

    private func snapshot(_ kind: TerminalAgentKind, _ activity: TerminalAgentActivity) -> TerminalAgentSnapshot {
        TerminalAgentSnapshot(instanceID: UUID(), runID: UUID(), kind: kind, activity: activity,
            blockReason: activity == .blocked ? .question : nil, source: .integration,
            confidence: .high, reason: .reported, updatedAt: Date(), reportSequence: 1, ruleVersion: 1)
    }
}
