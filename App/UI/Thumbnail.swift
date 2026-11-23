import SwiftUI

/// A photo or video tile from either source. Fills its frame and crops.
struct Thumbnail: View {
    @EnvironmentObject var store: GalleryStore
    @Environment(\.displayScale) private var displayScale
    let item: GalleryItem
    /// The longer side of the tile, in points.
    var pixelSize: CGFloat
    @State private var image: UIImage?
    @State private var shown: String?

    var body: some View {
        Rectangle()
            .fill(Palette.tile)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else if item.isVideo && item.isNAS {
                    Image(systemName: "video.fill").font(.title3).foregroundStyle(Palette.secondary.opacity(0.6))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                        if let duration = item.duration { Text(durationText(duration)).font(.system(size: 11, weight: .semibold)).monospacedDigit() }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
                }
            }
            .clipped()
            .task(id: item.id) { await load() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isImage)
    }

    private var accessibilityText: String {
        let kind = item.isVideo ? "Video" : "Foto"
        let source = item.isNAS ? "del NAS" : "del iPhone"
        return "\(kind) \(source), \(Timeline.format(item.date, "d 'de' MMMM 'de' y"))"
    }

    private func load() async {
        if shown != item.id { image = nil; shown = item.id }
        let pixels = min(pixelSize * displayScale, 1400)
        switch item.source {
        case .phone(let id):
            for await next in PhoneLibrary.shared.images(id, pixels: CGSize(width: pixels, height: pixels), fill: true) {
                image = next
            }
        case .nas(let url):
            if let cached = NASImageLoader.shared.cached(url) { image = cached; return }
            guard let account = store.account else { return }
            let loaded = await NASImageLoader.shared.thumbnail(item, account: account)
            guard !Task.isCancelled, let loaded else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
