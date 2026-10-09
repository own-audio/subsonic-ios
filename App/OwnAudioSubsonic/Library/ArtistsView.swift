import SubsonicKit
import SwiftUI

struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Artist]> = .loading
    @State private var filter = ""

    var body: some View {
        LoadStateView(state: state, retry: load) { artists in
            let shown = filter.isEmpty ? artists : artists.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            if artists.isEmpty {
                ContentUnavailableView("No Artists", systemImage: "music.mic")
            } else {
                List(shown) { artist in
                    NavigationLink(value: Route.artist(artist)) {
                        HStack(spacing: Theme.Spacing.md) {
                            ArtistImage(artist: artist, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.name).lineLimit(1)
                                Text("\(artist.albumCount) albums")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $filter, prompt: "Filter Artists")
            }
        }
        .navigationTitle("Artists")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            state = .loaded(try await client.artists())
        } catch {
            state = .failed(error.userMessage)
        }
    }
}

/// An artist's picture where the server offers one (Navidrome does), a circle with an icon
/// otherwise.
struct ArtistImage: View {
    @Environment(\.displayScale) private var displayScale
    let artist: Artist
    let size: CGFloat

    var body: some View {
        Group {
            if let raw = Artist.displaySizedImageURL(artist.artistImageUrl, size: Int(size * displayScale)),
               let url = URL(string: raw) {
                // These URLs are signed per artist and stable, so `AsyncImage`'s URL cache works.
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color(.secondarySystemFill))
            Image(systemName: "music.mic").foregroundStyle(.tertiary)
        }
    }
}
