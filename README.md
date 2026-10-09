# subsonic

A native iPhone and iPad player for Subsonic and OpenSubsonic servers: Navidrome, Gonic,
Airsonic, LMS, Ampache, own.audio and others. Swift and SwiftUI, no web views.

- Gapless playback and crossfade, on AVAudioEngine
- Streams while it downloads, with its own Core Audio decoder
- Downloads for offline listening
- Synced lyrics, volume leveling (ReplayGain), equalizer
- Favorites, ratings, playlists, scrobbling
- Several servers at once, CarPlay, iPad
- English and Czech

Made by [own.audio](https://www.own.audio). Free, no account, no tracking.

## Build

Developed with Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen); runs on iOS 18
and later.

```bash
brew install xcodegen
xcodegen generate
open OwnAudioSubsonic.xcodeproj
```

The two Swift packages test on their own:

```bash
cd Packages/SubsonicKit && swift test
cd Packages/PlayerEngine && swift test
```

Tests against a real server, and the UI tests, are described in [CLAUDE.md](CLAUDE.md).

## Layout

- `Packages/SubsonicKit` — the Subsonic client, server store, scrobble rules
- `Packages/PlayerEngine` — the player; knows nothing about servers
- `App/` — the app
- `UITests/` — end-to-end tests against a real server

## License

[MPL-2.0](LICENSE). Changes are listed in [CHANGELOG.md](CHANGELOG.md).
