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
- A queue can mix servers: track ids carry the server they come from.
- `PlayerEngine`: `Track.artworkId`, an opaque cover key for the lock screen and mini player.
- UI smoke test: add a server, open an album, play, check the position moves, skip, pause
  (runs against a real server, see `UITests/PlaybackSmokeTests.swift`).
- Tests: 29 stubbed client tests, 7 live-server tests (skipped unless `SUBSONIC_HOST`,
  `SUBSONIC_USER` and `SUBSONIC_PASSWORD` are set), 81 engine tests including a real
  `AVAudioEngine` playing fixture audio.

### Known issues

- Seeking inside a track that is still streaming waits for the full download.
- Streamed FLAC drops the last ~28 ms of a track.
