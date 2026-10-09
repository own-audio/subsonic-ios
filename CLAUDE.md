# CLAUDE.md — subsonic-ios

Open-source (MPL-2.0) native iOS player for Subsonic/OpenSubsonic servers, published by
own.audio. The repo is **private until the first release, then public** — write everything
as if strangers will read it.

- Work phase by phase from `IMPLEMENTATION_PLAN.md`; tick phases there.
- **No own.audio internals in this repo**: no references to the closed repos, their plan
  documents, internal hosts, team IDs or credentials. Comments explain why, for an outside
  reader.
- own.audio may appear as one optional server, never as a funnel.

## Build

```bash
xcodegen generate                      # after changing project.yml; the .xcodeproj is not committed
cd Packages/SubsonicKit && swift test  # package tests (Swift Testing)
xcodebuild -project OwnAudioSubsonic.xcodeproj -scheme OwnAudioSubsonic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Live server tests: `SUBSONIC_HOST=… SUBSONIC_USER=… SUBSONIC_PASSWORD=… swift test --filter LiveServer`.
Never commit the credentials.

Editor shows "no such module" on code that builds? Run
`xcode-build-server config -project OwnAudioSubsonic.xcodeproj -scheme OwnAudioSubsonic`
(`buildServer.json` is gitignored).

## Layout

- `App/OwnAudioSubsonic/` — the app target.
- `Packages/SubsonicKit/` — protocol client and Keychain server store; Foundation only.
- `Packages/PlayerEngine/` — playback engine; knows tracks by opaque id, nothing about servers.
