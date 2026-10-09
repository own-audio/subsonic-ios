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
- Tests: 29 stubbed client tests, 7 live-server tests (skipped unless `SUBSONIC_HOST`,
  `SUBSONIC_USER` and `SUBSONIC_PASSWORD` are set), 81 engine tests including a real
  `AVAudioEngine` playing fixture audio.

### Known issues

- Seeking inside a track that is still streaming waits for the full download.
- Streamed FLAC drops the last ~28 ms of a track.
