# Implementation plan

A native, open-source iPhone and iPad player for Subsonic and OpenSubsonic servers
(Navidrome, Gonic, Airsonic, LMS, own.audio's server, …). Swift 6, SwiftUI, iOS 18+.

Code lifted from the closed own.audio apps (the Subsonic client, the playback engine) is
copied in and relicensed under MPL-2.0. It is not shared with them and will drift; that was
the trade-off chosen for simpler maintenance.

## Phases

- [x] **P0: Skeleton.** XcodeGen project, app launches on the simulator.
- [x] **P1: SubsonicKit.** Client (token+salt auth, browse, search, playlists, stream and
  cover URLs), Keychain server store, 29 stubbed tests, 7 live-server tests (env-gated).
  All 7 live tests pass against Navidrome 0.64.2 (local Docker, 2026-10-09).
- [x] **P2: PlayerEngine.** AVAudioEngine engine: gapless, crossfade, progressive streaming
  with its own Core Audio decoder, file cache (driven by a track-id → URL resolver), EQ and
  spectrum, sleep timer, resume points, Now Playing and remote commands. `onPlaybackStarted` /
  `onPlaybackStopped(reason)` are the hooks P6's scrobbling uses. 81 tests, including a real
  `AVAudioEngine` playing fixture audio. Builds for iOS; not yet heard on a device.
  Known gaps carried over: no seeking inside a track that is still streaming (it waits for the
  full download); FLAC streaming drops the last ~28 ms of a track.
- [x] **P3: Servers.** Add, check, rename and remove servers; several at once; clear error
  states (wrong password vs unreachable).
- [x] **P4: Library.** Artists, albums (newest, recent, frequent, random, starred), album and
  artist detail, playlists, search; cached cover art.
- [x] **P5: Player UI.** Mini player, full player, queue, AirPlay. Verified end to end in the
  simulator against Navidrome by `UITests/PlaybackSmokeTests.swift`. Not yet: going from the
  player to the artist or album, an iPad layout (P10).
- [x] **P6: Server features.** Scrobble (now playing + submission, offline queue), star/unstar,
  ratings, playlist editing, `getOpenSubsonicExtensions` in the client (used from P9).
  Live-tested against a real Navidrome 0.64.2 library (519 artists); the live tests restore what
  they change and never submit a counted play.
- [x] **P7: Offline.** Downloads per song, album and playlist; a Downloads screen that works
  with no network; offline playback verified by a UI test that restarts with every server
  unreachable, on both Navidrome and own.audio. Not yet: background downloads (URLSession
  background sessions) and a cellular-data switch.
- [ ] **P8: CarPlay.** Needs the CarPlay audio entitlement, which needs a paid Apple
  Developer account.
- [x] **P9: Extras.** Lyrics (OpenSubsonic `getLyricsBySongId`, classic `getLyrics`
  fallback), ReplayGain (track/album/off, peak-protected, per node), EQ screen. The two real
  test servers carry neither lyrics nor ReplayGain tags, so these were verified against a
  local Navidrome with a generated album (`.lrc` file, `LYRICS` tag, ReplayGain tags); the real
  servers verify that "no lyrics" is handled.
- [ ] **P10: Release.** iPad layout, accessibility, localization, App Store listing,
  public repo, launch posts.

## Open questions

- App Store name and icon ("own.audio subsonic" is the working name; check Subsonic's
  naming before submitting).
- Distribution needs an Apple Developer account in good standing.
