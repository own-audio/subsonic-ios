import SubsonicKit
import SwiftUI

extension View {
    /// Star, rate and add to a playlist, on a long press of any song. `removeFromPlaylist` adds a remove action, for a playlist the listener owns.
    func songActions(_ song: Song, removeFromPlaylist: (() -> Void)? = nil) -> some View {
        modifier(SongActions(song: song, removeFromPlaylist: removeFromPlaylist))
    }
}

private struct SongActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let song: Song
    let removeFromPlaylist: (() -> Void)?
    @State private var isAddingToPlaylist = false

    func body(content: Content) -> some View {
        let id = model.compositeId(song.id)
        content
            .contextMenu {
                if let id {
                    let starred = model.isStarred(id)
                    Button {
                        model.perform { try await model.toggleStar(id, kind: .song) }
                    } label: {
                        Label(starred ? "Unfavorite" : "Favorite", systemImage: starred ? "star.slash" : "star")
                    }
                    RatingMenu(rating: model.ratings[id]) { rating in
                        model.perform { try await model.setRating(id, rating: rating) }
                    }
                }
                Button {
                    isAddingToPlaylist = true
                } label: {
                    Label("Add to Playlist…", systemImage: "text.badge.plus")
                }
                if let id {
                    if model.downloads.isDownloaded(id) {
                        Button(role: .destructive) {
                            model.downloads.remove(trackId: id)
                        } label: {
                            Label("Remove Download", systemImage: "trash")
                        }
                    } else {
                        Button {
                            model.download(songs: [song])
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                }
                if let removeFromPlaylist {
                    Button(role: .destructive, action: removeFromPlaylist) {
                        Label("Remove from Playlist", systemImage: "minus.circle")
                    }
                }
            }
            .sheet(isPresented: $isAddingToPlaylist) {
                AddToPlaylistSheet(songIds: [song.id])
            }
    }
}

/// One to five stars, or none.
struct RatingMenu: View {
    let rating: Int?
    let set: (Int) -> Void

    var body: some View {
        Menu {
            ForEach((1...5).reversed(), id: \.self) { value in
                Button {
                    set(value)
                } label: {
                    if rating == value {
                        Label(String(repeating: "★", count: value), systemImage: "checkmark")
                    } else {
                        Text(String(repeating: "★", count: value))
                    }
                }
            }
            if rating != nil {
                Button("Clear Rating", role: .destructive) { set(0) }
            }
        } label: {
            Label(rating.map { String(localized: "Rating: \(String(repeating: "★", count: $0))") } ?? String(localized: "Rate"), systemImage: "star.leadinghalf.filled")
        }
    }
}

/// Pick one of the listener's own playlists, or make a new one, for the given songs.
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let songIds: [String]
    @State private var state: LoadState<[Playlist]> = .loading
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            LoadStateView(state: state, retry: load) { playlists in
                List {
                    Button {
                        newName = ""
                        isNaming = true
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                    }
                    ForEach(playlists) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            HStack {
                                Text(playlist.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(playlist.songCount)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Playlist", isPresented: $isNaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    /// Only the listener's own playlists can be added to.
    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            let username = model.activeServer?.credentials.username
            let all = try await client.playlists()
            // A server that doesn't send `owner` per the spec gets every playlist offered; it
            // will refuse a write it doesn't allow, and that error is shown.
            state = .loaded(all.filter { $0.owner == nil || $0.owner == username })
        } catch {
            state = .failed(error.userMessage)
        }
    }

    private func add(to playlist: Playlist) {
        guard let client = model.activeClient else { return }
        Haptics.impact(.light)
        model.perform { try await client.updatePlaylist(id: playlist.id, songIdsToAdd: songIds) }
        dismiss()
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = model.activeClient else { return }
        Haptics.impact(.light)
        model.perform { try await client.createPlaylist(name: name, songIds: songIds) }
        dismiss()
    }
}
