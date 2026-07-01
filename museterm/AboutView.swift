import Combine
import Foundation
import SwiftUI

struct AboutView: View {
    @ObservedObject var preferences: TerminalPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    AboutPenguinAnimationView()
                        .frame(width: 128, height: 128)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("MuseTerm")
                                .font(.title2.weight(.semibold))
                            Text(AppVersion.displayValue)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Text(L10n.string("settings.about.summary"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Link(destination: URL(string: "https://83d.me")!) {
                            Label(L10n.string("settings.about.author_homepage"), systemImage: "link")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.link)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("settings.about.other_apps"))
                        .font(.headline)
                    Text(L10n.string("settings.about.other_apps.summary"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                        ForEach(AboutRecommendedApp.allCases) { app in
                            AboutRecommendedAppCard(app: app, skin: preferences.skin)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 700, height: 500)
        .background(preferences.skin.panelFill)
        .tint(preferences.skin.accent)
        .preferredColorScheme(preferences.skin.preferredColorScheme)
    }
}

private struct AboutPenguinAnimationView: View {
    @State private var frameIndex = 0
    private let timer = Timer.publish(every: 0.065, on: .main, in: .common).autoconnect()
    private let frameCount = 16

    var body: some View {
        Image(frameName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .onReceive(timer) { _ in
                frameIndex = (frameIndex + 1) % frameCount
            }
    }

    private var frameName: String {
        String(format: "PenguinWalkAbout%02d", frameIndex)
    }
}

private enum AboutRecommendedApp: String, CaseIterable, Identifiable {
    case willDeep
    case timeBill
    case museUploader
    case museSnip
    case markReader
    case museType
    case museMail
    case museMate

    var id: String { rawValue }

    var nameKey: String {
        "settings.about.app.\(rawValue).name"
    }

    var summaryKey: String {
        "settings.about.app.\(rawValue).summary"
    }

    var iconAssetName: String {
        switch self {
        case .willDeep: return "AboutAppWillDeepIcon"
        case .timeBill: return "AboutAppTimeBillIcon"
        case .museUploader: return "AboutAppMuseUploaderIcon"
        case .museSnip: return "AboutAppMuseSnipIcon"
        case .markReader: return "AboutAppMarkReaderIcon"
        case .museType: return "AboutAppMuseTypeIcon"
        case .museMail: return "AboutAppMuseMailIcon"
        case .museMate: return "AboutAppMuseMateIcon"
        }
    }

    var productURL: URL {
        URL(string: "https://83d.me/products/\(productSlug)")!
    }

    private var productSlug: String {
        switch self {
        case .willDeep: return "veilwriter"
        case .timeBill: return "timebill"
        case .museUploader: return "qingtu"
        case .museSnip: return "jiantu"
        case .markReader: return "markreader"
        case .museType: return "typecho"
        case .museMail: return "musemail"
        case .museMate: return "musemate"
        }
    }
}

private struct AboutRecommendedAppCard: View {
    let app: AboutRecommendedApp
    let skin: TerminalVisualSkin

    var body: some View {
        Link(destination: app.productURL) {
            HStack(spacing: 10) {
                Image(app.iconAssetName)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string(app.nameKey))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(L10n.string(app.summaryKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skin.accent)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(skin.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(skin.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
