import CarPlay
import MusicEngine
import SubsonicKit
import UIKit

/// The car's screen. It runs in the same process as the phone UI and drives the same model and
/// player, so playback started here shows on the phone and the lock screen, and the other way
/// round. The Now Playing screen is the system's own template.
///
/// Lists are short on purpose: CarPlay is for a glance and a tap. Downloads come first among
/// the library entries because a car often has no signal.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var model: AppModel { AppModel.shared }

    /// CarPlay's guidelines ask for short lists; the system also caps them.
    private static let maxItems = 100

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(CPListTemplate(title: Self.title, sections: []), animated: false) { _, _ in }
        Task {
            // CarPlay can start the app without the phone UI ever appearing.
            if !model.hasLoaded { await model.load() }
            showRoot()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    private static let title = "subsonic"

    // MARK: - Root

    private func showRoot() {
        guard model.activeClient != nil else {
            let item = CPListItem(text: String(localized: "Add a server on your iPhone"), detailText: nil)
            item.isEnabled = false
            interfaceController?.setRootTemplate(
                CPListTemplate(title: Self.title, sections: [CPListSection(items: [item])]), animated: true
            ) { _, _ in }
            return
        }
        let entries: [(String, String, () async -> Void)] = [
            (String(localized: "Recently Played"), "clock", { [weak self] in await self?.pushAlbums(.recent, title: String(localized: "Recently Played")) }),
            (String(localized: "Recently Added"), "sparkles", { [weak self] in await self?.pushAlbums(.newest, title: String(localized: "Recently Added")) }),
            (String(localized: "Downloads"), "arrow.down.circle", { [weak self] in self?.pushDownloads() }),
            (String(localized: "Playlists"), "music.note.list", { [weak self] in await self?.pushPlaylists() }),
            (String(localized: "Artists"), "music.mic", { [weak self] in await self?.pushArtists() }),
            (String(localized: "Favorites"), "star", { [weak self] in await self?.pushFavorites() }),
        ]
        let items = entries.map { text, symbol, action -> CPListItem in
            let item = CPListItem(text: text, detailText: nil, image: UIImage(systemName: symbol))
            item.accessoryType = .disclosureIndicator
            item.handler = { _, completion in
                Task {
                    await action()
                    completion()
                }
            }
            return item
        }
        let root = CPListTemplate(title: model.activeServer?.displayName ?? Self.title, sections: [CPListSection(items: items)])
        interfaceController?.setRootTemplate(root, animated: true) { _, _ in }
    }

    // MARK: - Lists

    private func pushAlbums(_ type: AlbumListType, title: String) async {
        guard let client = model.activeClient else { return }
        let albums = (try? await client.albumList(type, size: Self.maxItems)) ?? []
        push(title: title, items: albums.map { album in
            listItem(album.name, detail: album.artist, artwork: album.coverArt ?? album.id) { [weak self] in
                await self?.playAlbum(album)
            }
        }, emptyText: String(localized: "Nothing here yet"))
    }

    private func pushPlaylists() async {
        guard let client = model.activeClient else { return }
        let playlists = (try? await client.playlists()) ?? []
        push(title: String(localized: "Playlists"), items: playlists.prefix(Self.maxItems).map { playlist in
            listItem(playlist.name, detail: songCountText(playlist.songCount), artwork: playlist.coverArt) { [weak self] in
                guard let songs = try? await client.playlist(id: playlist.id).songs else { return }
                self?.play(songs, containerId: "playlist:\(playlist.id)")
            }
        }, emptyText: String(localized: "No playlists"))
    }

    private func pushArtists() async {
        guard let client = model.activeClient else { return }
        let artists = (try? await client.artists()) ?? []
        push(title: String(localized: "Artists"), items: artists.prefix(Self.maxItems).map { artist in
            let item = CPListItem(text: artist.name, detailText: nil)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.pushArtist(artist)
                    completion()
                }
            }
            return item
        }, emptyText: String(localized: "No artists"))
    }

    private func pushArtist(_ artist: Artist) async {
        guard let client = model.activeClient else { return }
        let albums = (try? await client.artist(id: artist.id).albums) ?? []
        push(title: artist.name, items: albums.map { album in
            listItem(album.name, detail: album.year.map(String.init), artwork: album.coverArt ?? album.id) { [weak self] in
                await self?.playAlbum(album)
            }
        }, emptyText: String(localized: "No albums"))
    }

    private func pushFavorites() async {
        guard let client = model.activeClient, let starred = try? await client.starred() else { return }
        let songs = starred.songs
        var items: [CPListItem] = []
        if !songs.isEmpty {
            items.append(listItem(String(localized: "Favorite Songs"), detail: songCountText(songs.count), artwork: nil, symbol: "star.fill") { [weak self] in
                self?.play(songs, containerId: "favorites")
            })
        }
        items += starred.albums.map { album in
            listItem(album.name, detail: album.artist, artwork: album.coverArt ?? album.id) { [weak self] in
                await self?.playAlbum(album)
            }
        }
        push(title: String(localized: "Favorites"), items: items, emptyText: String(localized: "No favorites"))
    }

    /// From the download index alone, so it works with no signal.
    private func pushDownloads() {
        let downloads = model.downloads
        let collections = downloads.collections.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        var items = collections.map { collection in
            let item = CPListItem(text: collection.name, detailText: collection.artist)
            item.handler = { [weak self] _, completion in
                let songs = downloads.songs(in: collection)
                self?.model.play(downloaded: songs, containerId: collection.id)
                self?.showNowPlaying()
                completion()
            }
            loadArtwork(for: item, artworkId: collection.coverArt.map { TrackID.make(serverId: collection.serverId, itemId: $0) })
            return item
        }
        let loose = downloads.looseTracks
        if !loose.isEmpty {
            let item = CPListItem(text: String(localized: "Downloaded Songs"), detailText: songCountText(loose.count), image: UIImage(systemName: "music.note"))
            item.handler = { [weak self] _, completion in
                self?.model.play(downloaded: loose)
                self?.showNowPlaying()
                completion()
            }
            items.insert(item, at: 0)
        }
        push(title: String(localized: "Downloads"), items: items, emptyText: String(localized: "Nothing downloaded"))
    }

    // MARK: - Helpers

    private func playAlbum(_ album: Album) async {
        guard let client = model.activeClient, let songs = try? await client.album(id: album.id).songs else { return }
        play(songs, containerId: "album:\(album.id)")
    }

    private func play(_ songs: [Song], containerId: String) {
        model.play(songs, containerId: containerId)
        showNowPlaying()
    }

    /// A tapped row should visibly start something, not leave the driver on the list.
    private func showNowPlaying() {
        guard interfaceController?.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, _ in }
    }

    private func push(title: String, items: [CPListItem], emptyText: String) {
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        template.emptyViewTitleVariants = [emptyText]
        interfaceController?.pushTemplate(template, animated: true) { _, _ in }
    }

    /// The row appears at once; its cover fills in when loaded.
    private func listItem(
        _ text: String, detail: String?, artwork coverId: String?, symbol: String? = nil,
        action: @escaping () async -> Void
    ) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail, image: symbol.flatMap { UIImage(systemName: $0) })
        item.handler = { _, completion in
            Task {
                await action()
                completion()
            }
        }
        loadArtwork(for: item, artworkId: model.artworkId(coverId))
        return item
    }

    private func loadArtwork(for item: CPListItem, artworkId: String?) {
        guard let artworkId else { return }
        let covers = model.covers
        Task {
            if let image = await covers.image(artworkId: artworkId, size: 120) { item.setImage(image) }
        }
    }
}
