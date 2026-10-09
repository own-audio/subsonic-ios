# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- App skeleton: XcodeGen project (`project.yml`), iPhone and iPad, iOS 18+, background audio,
  plain-http servers allowed (home servers rarely have TLS on the LAN).
- `SubsonicKit`: Subsonic/OpenSubsonic client with token+salt auth (the password never goes
  over the wire), browsing (artists, albums, album lists by type, songs), `search3`,
  playlists (read, create, update, delete), stream and cover-art URLs, and a three-state
  connection check (ok / rejected / unreachable).
- `SubsonicKit`: Keychain store for any number of servers, readable while the phone is locked
  so playback can keep making requests.
- `PlayerEngine`: AVAudioEngine-based player with gapless playback, crossfade, progressive
  streaming through its own Core Audio decoder, a 6-band EQ, spectrum data for a visualizer,
  sleep timer, shuffle and repeat, per-album resume points, lock screen and Control Center
  controls, and pausing on calls and unplugged headphones.
- `PlayerEngine`: `onPlaybackStarted` / `onPlaybackStopped(reason)` hooks for scrobbling.
- Servers: add a server (checked against it before anything is saved, with distinct messages
  for a wrong password and an unreachable server), several servers, pick the one to browse,
  check, rename and remove. The first run opens straight into adding one.
- Library: recently added and recently played shelves; artists (with Navidrome's artist
  images) and artist pages; albums in any server list order (title, artist, newest, recently
  played, most played, random, favorites) loaded a page at a time; album pages with discs;
  playlists; search across artists, albums and songs. Pull to refresh everywhere.
- Cover art cached in memory and on disk, keyed by cover id and size, since Subsonic URLs
  change with every request.
- Player: mini player above the tab bar with played and buffered progress; full player with
  blurred-cover background, format badge (e.g. "FLAC · 44.1 kHz"), track position in the
  album, scrubber, swipe the cover to skip, shuffle, repeat, crossfade, sleep timer, queue
  (played, now playing, up next) and AirPlay.
- Settings: servers, crossfade, version, source code and license links.
- Scrobbling: "now playing" when a track starts, and a counted play once half of it (or four
  minutes) has actually been heard; tracks under 30 s never count. Plays that can't be
  reported are kept and sent later with the time listening began. Can be turned off in
  Settings. The rule lives in `SubsonicKit.ScrobbleTracker`, with 12 tests.
- Favorites: star songs (long-press menu, player), albums and artists (toolbar); a Favorites
  screen with starred songs, albums and artists; a star marker on starred songs.
- Ratings: rate songs and albums 1–5 or clear the rating.
- Playlists: create one (from Playlists, or from any song's "Add to Playlist…"), add songs or a
  whole album, remove songs (swipe or menu), rename and delete. Edit actions appear only on
  the listener's own playlists.
- `SubsonicKit`: `star`, `unstar`, `setRating`, `starred` (`getStarred2`), `scrobble`,
  `openSubsonicExtensions`; songs, albums and artists now carry `starred`, `userRating` and
  `playCount`.
- Failed actions (star, rate, playlist edits) show one alert and undo what the screen had
  already changed.
- Downloads: download an album or playlist (arrow on its page) or a single song (its menu).
  Two at a time, resumed after a restart, failures retried on request. Files are kept in
  Application Support, out of iCloud backup, and a downloaded song plays from the phone even
  when the server is reachable. Covers are fetched at every size the screens use, so a
  downloaded album looks the same offline. A song shared by two downloaded albums or
  playlists is stored once and kept until neither needs it. Removing a server removes its
  downloads.
- Downloads screen (Library and Settings): albums, playlists and single songs on the phone,
  with storage used, progress, retry, swipe to remove and Remove All. It works with no
  network and plays each song from the server it came from.
- Adding a server explains that own.audio takes the account email and the Subsonic key from
  the web app's settings, not the account password.
- Offline, a cover falls back to any size of it already cached rather than a placeholder.
- `scripts/test-servers.sh`: the live client tests and both UI tests against every server
  listed in the gitignored `test-servers.local.env` (a Navidrome and an own.audio server,
  whose Subsonic key it fetches fresh, as a demo server issues a new one daily).
- UI test: download an album, restart with every server unreachable, play it from Downloads.
  `-simulateOffline` (debug builds only) points every server at an address nothing answers.
- Lyrics (player tool): synced lyrics follow the music with the current line centred, and a
  tap on a line jumps there; plain lyrics scroll; a server with several versions (languages,
  synced and plain) offers a choice. Uses the OpenSubsonic `songLyrics` extension where the
  server has it, classic `getLyrics` otherwise.
- Volume leveling (ReplayGain), on by default per song, or per album, or off (Settings). Each
  of the engine's two player nodes has its own gain stage, so quiet songs can be raised as
  well as loud ones lowered, never so far that the peak clips; the gain switches exactly at a
  gapless track change and follows each side of a crossfade. The player shows the gain
  applied next to the format.
- Equalizer screen (player tool and Settings): on/off, preamp, six bands, presets, reset.
- `SubsonicKit`: `lyrics(for:useSongLyricsExtension:)`, `Lyrics.lineIndex(at:)`,
  `Song.replayGain`. `PlayerEngine`: `Track.replayGain`, `ReplayGainMode`,
  `PlaybackEngine.appliedGainDb`.
- UI test: ReplayGain shown, synced lyrics loaded and following, equalizer preset applied
  (runs where an album with lyrics and ReplayGain tags exists; `NAVIDROME_LYRICS_ALBUM` in
  `test-servers.local.env`).
- CarPlay: Recently Played, Recently Added, Downloads (from the download index, so it works
  with no signal), Playlists, Artists and Favorites, with covers; a tap plays and opens the
  system Now Playing screen. Same player as the phone. Built and compiled; not yet seen on a
  CarPlay screen (see Known issues).
- The app model is one shared instance and loads once, whether the phone UI or CarPlay starts
  the app.
- iPad: a sidebar (iOS's adaptable tab style), the four-column album grid and the player's
  centred column; both UI tests pass on an iPad Air simulator.
- Czech localization of the whole app, including the engine's strings, with Czech plurals
  ("1 skladba, 2 skladby, 5 skladeb") and the terms of the shared own.audio glossary. String
  catalogs: `Localizable.xcstrings`, `InfoPlist.xcstrings`.
- UI test: the main screens in Czech, with screenshots.
- Large text: Play and Shuffle stack at accessibility sizes, album and playlist titles wrap,
  and the full player caps its text at the first accessibility size so its controls still
  fit. UI test: the main screens at the largest size.
- README for the public repository.
- App icon: the own.audio construction in orange, light with a dark-mode variant (source in
  `Design/`). Home-screen name "own subsonic", like own music, own book and own podcast; the
  store name is "own.audio for Subsonic".
- App Store listing in English and Czech (`AppStore/`), and `scripts/app-store-screenshots.sh`,
  which takes the screenshots on the required iPhone 6.9" and iPad 13" sizes in both languages
  from a server whose music may be shown, with a clean status bar.
- Debug builds: `-debugServerHost`, `-debugServerUser`, `-debugServerPassword` (and optional
  `-debugServerName`) launch arguments add a server at launch, to hand someone a simulator
  that is already connected.
- Privacy manifest: no tracking, no data collected; UserDefaults and file attributes declared
  with their reasons.
- A queue can mix servers: track ids carry the server they come from.
- `PlayerEngine`: `Track.artworkId`, an opaque cover key for the lock screen and mini player.
- UI smoke test: add a server, open an album, play, check the position moves, skip, pause
  (runs against a real server, see `UITests/PlaybackSmokeTests.swift`).
- Tests: 29 stubbed client tests, 7 live-server tests (skipped unless `SUBSONIC_HOST`,
  `SUBSONIC_USER` and `SUBSONIC_PASSWORD` are set), 81 engine tests including a real
  `AVAudioEngine` playing fixture audio.

### Fixed

- UI tests ran in the simulator's language, which broke them once the app had a Czech
  translation; they now launch in English (the Czech test excepted).

- "1 songs" and "1 albums" now read "1 song" and "1 album".

- `PlayerEngine`: a track chained gaplessly onto the previous one (the normal case within an
  album) never reported `onPlaybackStarted`, so it could not be scrobbled as now playing.

### Known issues

- CarPlay hasn't been checked on a screen yet: it needs the simulator's CarPlay window, opened
  by hand. On a real car it also needs Apple's CarPlay audio entitlement, which needs a paid
  developer account; the entitlement isn't in the project yet.

- Seeking inside a track that is still streaming waits for the full download.
- Streamed FLAC drops the last ~28 ms of a track.
