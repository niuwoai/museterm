import SwiftUI

/// The narrow column of thumbnails at the right edge of one terminal tab.
///
/// It takes no width unless the program in that tab has announced images, so a tab that never
/// speaks the protocol stays a full character terminal.
struct TerminalGalleryColumn: View {
    @ObservedObject var gallery: TerminalGalleryState
    let onOpen: (TerminalGalleryItem) -> Void
    let onDelete: (TerminalGalleryItem) -> Void

    private static let width: CGFloat = 120
    private static let thumbnail: CGFloat = 92

    var body: some View {
        if gallery.isVisible {
            VStack(spacing: 0) {
            if let failure = gallery.pasteFailure {
                Text(failure.userMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                Divider()
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(gallery.items) { item in
                        thumbnail(item)
                    }
                }
                .padding(8)
            }
            .frame(width: Self.width)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .leading) { Divider() }
            .accessibilityIdentifier("terminal-gallery-column")
            }
        } else if let failure = gallery.pasteFailure {
            VStack {
                Text(failure.userMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
            .frame(width: Self.width)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .leading) { Divider() }
        }
    }

    private func thumbnail(_ item: TerminalGalleryItem) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Button {
                    onOpen(item)
                } label: {
                    image(item)
                        .frame(width: Self.thumbnail, height: Self.thumbnail)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L10n.string("gallery.open"))
                .accessibilityLabel(item.name.isEmpty ? L10n.string("gallery.open") : item.name)
                if item.canDelete {
                    Button {
                        onDelete(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                    .help(L10n.string("gallery.delete"))
                    .accessibilityLabel(L10n.string("gallery.delete"))
                }
            }
            if let reason = item.rejectionReason {
                Text(TerminalGalleryRejectionText.message(for: reason))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func image(_ item: TerminalGalleryItem) -> some View {
        if let image = item.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(item.state == .pending ? 0.45 : 1)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}
