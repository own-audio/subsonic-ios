import SwiftUI

/// A square cover from `CoverArtLoader`, with a placeholder while it loads or when there is none.
struct CoverArtView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale

    /// A composite id (`TrackID`), or nil for "no cover".
    let artworkId: String?
    /// The size it is drawn at, in points; the request is made at the matching pixel size.
    let pointSize: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: max(pointSize * 0.3, 12)))
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .task(id: artworkId) {
            image = nil
            guard let artworkId else { return }
            let pixels = Self.bucket(Int(pointSize * displayScale))
            let loaded = await model.covers.image(artworkId: artworkId, size: pixels)
            withAnimation(.easeIn(duration: 0.15)) { image = loaded }
        }
        .accessibilityHidden(true)
    }

    /// A few fixed sizes, so a cover shown at slightly different sizes is fetched once.
    private static func bucket(_ pixels: Int) -> Int {
        [120, 300, 600, 1000].first { $0 >= pixels } ?? 1000
    }
}
