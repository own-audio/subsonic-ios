import SubsonicKit
import SwiftUI

/// What is on the phone. Works with no network: everything here comes from the download index.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingRemoveAll = false

    private var downloads: DownloadManager { model.downloads }

    private var albums: [DownloadManager.Collection] {
        downloads.collections.values.filter { $0.kind == .album }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private var playlists: [DownloadManager.Collection] {
        downloads.collections.values.filter { $0.kind == .playlist }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if downloads.tracks.isEmpty && downloads.pendingCount == 0 && downloads.failedCount == 0 {
                ContentUnavailableView(
                    "Nothing Downloaded", systemImage: "arrow.down.circle",
                    description: Text("Download an album or a playlist with the arrow on its page, or a song from its menu. It then plays without a network.")
                )
                .listRowSeparator(.hidden)
            } else {
                Section {
                    LabeledContent("On this phone", value: ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                    if downloads.pendingCount > 0 {
                        LabeledContent("Downloading", value: "\(downloads.pendingCount)")
                    }
                    if downloads.failedCount > 0 {
                        Button("Retry \(downloads.failedCount) Failed") { downloads.retryFailed() }
                    }
                }

                if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums) { collection in
                            NavigationLink {
                                DownloadedCollectionView(collectionId: collection.id)
                            } label: {
                                collectionRow(collection)
                            }
                            .accessibilityIdentifier("downloads.album.\(collection.name)")
                        }
                        .onDelete { offsets in offsets.map { albums[$0].id }.forEach(downloads.remove(collectionId:)) }
                    }
                }
                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { collection in
                            NavigationLink {
                                DownloadedCollectionView(collectionId: collection.id)
                            } label: {
                                collectionRow(collection)
                            }
                        }
                        .onDelete { offsets in offsets.map { playlists[$0].id }.forEach(downloads.remove(collectionId:)) }
                    }
                }
                let loose = downloads.looseTracks
                if !loose.isEmpty {
                    Section("Songs") {
                        ForEach(loose, id: \.trackId) { item in
                            Button {
                                model.play(downloaded: loose, startTrackId: item.trackId)
                            } label: {
                                DownloadedSongRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in offsets.map { loose[$0].trackId }.forEach(downloads.remove(trackId:)) }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !downloads.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Remove All", role: .destructive) { isConfirmingRemoveAll = true }
                }
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $isConfirmingRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("They stay on the server and can be downloaded again.")
        }
    }

    private func collectionRow(_ collection: DownloadManager.Collection) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            CoverArtView(artworkId: collection.coverArt.map { TrackID.make(serverId: collection.serverId, itemId: $0) }, pointSize: 56)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).lineLimit(1)
                if let progress = downloads.progress(of: collection.id) {
                    Text(progress.done == progress.total
                        ? songCountText(progress.total)
                        : String(localized: "\(progress.done) of \(progress.total) downloaded"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A downloaded album or playlist, playable offline.
struct DownloadedCollectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let collectionId: String

    var body: some View {
        if let collection = model.downloads.collections[collectionId] {
            let songs = model.downloads.songs(in: collection)
            List {
                Section {
                    VStack(spacing: Theme.Spacing.md) {
                        CoverArtView(artworkId: collection.coverArt.map { TrackID.make(serverId: collection.serverId, itemId: $0) }, pointSize: 200)
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
                        Text(collection.name).font(.title2.bold()).multilineTextAlignment(.center)
                        if let artist = collection.artist {
                            Text(artist).foregroundStyle(.secondary)
                        }
                        PlayShuffleButtons(isEnabled: !songs.isEmpty) {
                            model.play(downloaded: songs, containerId: collectionId)
                        } shuffle: {
                            model.play(downloaded: songs, shuffled: true, containerId: collectionId)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                ForEach(songs, id: \.trackId) { item in
                    Button {
                        Haptics.impact(.light)
                        model.play(downloaded: songs, startTrackId: item.trackId, containerId: collectionId)
                    } label: {
                        DownloadedSongRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle(collection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        model.downloads.remove(collectionId: collectionId)
                        dismiss()
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                }
            }
        } else {
            ContentUnavailableView("Removed", systemImage: "arrow.down.circle")
        }
    }
}

struct DownloadedSongRow: View {
    @Environment(AppModel.self) private var model
    let item: DownloadManager.DownloadedTrack

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(item.song.track.map(String.init) ?? "")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title)
                    .foregroundStyle(model.engine.currentTrack?.id == item.trackId ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(item.song.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The toolbar control for downloading an album or playlist: an arrow, then progress, then a
/// filled check with a menu to remove it.
struct CollectionDownloadButton: View {
    @Environment(AppModel.self) private var model
    let collectionId: String?
    let isEnabled: Bool
    let start: () -> Void

    var body: some View {
        let progress = collectionId.flatMap { model.downloads.progress(of: $0) }
        if let progress, let collectionId {
            if progress.done == progress.total {
                Menu {
                    Button(role: .destructive) {
                        model.downloads.remove(collectionId: collectionId)
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                }
                .accessibilityLabel("Downloaded")
                .accessibilityIdentifier("download.done")
            } else {
                ZStack {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .progressViewStyle(.circular)
                    Text("\(progress.done)").font(.system(size: 9).monospacedDigit())
                }
                .frame(width: 26, height: 26)
                .accessibilityLabel("Downloading \(progress.done) of \(progress.total)")
                .accessibilityIdentifier("download.progress")
            }
        } else {
            Button {
                Haptics.impact(.light)
                start()
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .disabled(!isEnabled)
            .accessibilityLabel("Download")
            .accessibilityIdentifier("download.start")
        }
    }
}
