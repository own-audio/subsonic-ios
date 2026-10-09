import SubsonicKit
import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Playlist]> = .loading
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        LoadStateView(state: state, retry: load) { playlists in
            if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists", systemImage: "music.note.list",
                    description: Text("Make one with +, or add songs to a new one from any song's menu.")
                )
            } else {
                List(playlists) { playlist in
                    NavigationLink(value: Route.playlist(playlist)) {
                        HStack(spacing: Theme.Spacing.md) {
                            CoverArtView(artworkId: model.artworkId(playlist.coverArt), pointSize: 56)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).lineLimit(1)
                                Text(subtitle(playlist))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    isNaming = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Playlist")
                .accessibilityIdentifier("playlists.new")
            }
        }
        .alert("New Playlist", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create() }
        }
        .refreshable { await load() }
        .task(id: model.isOffline) { await load() }
    }

    private func subtitle(_ playlist: Playlist) -> String {
        let songs = songCountText(playlist.songCount)
        guard let owner = playlist.owner, owner != model.activeServer?.credentials.username else { return songs }
        return String(localized: "\(songs) · by \(owner)")
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            state = .loaded(try await client.playlists())
        } catch {
            let downloaded = model.offlinePlaylists
            state = downloaded.isEmpty ? .failed(error.userMessage) : .loaded(downloaded)
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = model.activeClient else { return }
        model.perform {
            try await client.createPlaylist(name: name)
            await load()
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var playlist: Playlist
    @State private var state: LoadState<[Song]> = .loading
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isConfirmingDelete = false

    init(playlist: Playlist) {
        _playlist = State(initialValue: playlist)
    }

    /// Edit actions only on the listener's own playlists. A server that leaves out `owner` gets
    /// them too; it refuses what it doesn't allow, and that error is shown.
    private var isOwn: Bool {
        playlist.owner == nil || playlist.owner == model.activeServer?.credentials.username
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            LoadStateView(state: state, retry: load) { songs in
                // Rows are keyed by position: a playlist can hold the same song twice.
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    Button {
                        Haptics.impact(.light)
                        model.play(songs, startSongId: song.id, containerId: "playlist:\(playlist.id)")
                    } label: {
                        SongRow(song: song, showsCover: true)
                    }
                    .buttonStyle(.plain)
                    .songActions(song, removeFromPlaylist: isOwn ? { remove(at: index) } : nil)
                }
                .onDelete(perform: isOwn ? { offsets in offsets.forEach(remove(at:)) } : nil)
                if !songs.isEmpty {
                    Text(songsSummary(songs))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CollectionDownloadButton(
                    collectionId: model.activeServerId.map { DownloadManager.collectionId(kind: .playlist, serverId: $0, itemId: playlist.id) },
                    isEnabled: songs?.isEmpty == false
                ) {
                    if let songs { model.download(playlist: playlist, songs: songs) }
                }
            }
            if isOwn {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newName = playlist.name
                            isRenaming = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Edit Playlist")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename() }
        }
        .confirmationDialog("Delete \"\(playlist.name)\"?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { delete() }
        } message: {
            Text("This deletes it on the server, for every app that uses it.")
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            CoverArtView(artworkId: model.artworkId(playlist.coverArt), pointSize: 200)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
            Text(playlist.name).font(.title2.bold()).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let comment = playlist.comment, !comment.isEmpty {
                Text(comment).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            PlayShuffleButtons(isEnabled: songs?.isEmpty == false) {
                if let songs { model.play(songs, containerId: "playlist:\(playlist.id)") }
            } shuffle: {
                if let songs { model.play(songs, shuffled: true, containerId: "playlist:\(playlist.id)") }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var songs: [Song]? {
        if case .loaded(let songs) = state { songs } else { nil }
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            let loaded = try await client.playlist(id: playlist.id)
            playlist = loaded.playlist
            model.learn(songs: loaded.songs)
            state = .loaded(loaded.songs)
        } catch {
            if let downloaded = model.offlineSongs(playlistId: playlist.id), !downloaded.isEmpty {
                state = .loaded(downloaded)
            } else {
                state = .failed(error.userMessage)
            }
        }
    }

    /// Removes by position, then reloads: positions shift, and the server is the authority.
    private func remove(at index: Int) {
        guard let client = model.activeClient, var songs else { return }
        guard songs.indices.contains(index) else { return }
        songs.remove(at: index)
        state = .loaded(songs)
        model.perform {
            defer { Task { await load() } }
            try await client.updatePlaylist(id: playlist.id, songIndicesToRemove: [index])
        }
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = model.activeClient else { return }
        model.perform {
            try await client.updatePlaylist(id: playlist.id, name: name)
            await load()
        }
    }

    private func delete() {
        guard let client = model.activeClient else { return }
        model.perform {
            try await client.deletePlaylist(id: playlist.id)
            dismiss()
        }
    }
}
