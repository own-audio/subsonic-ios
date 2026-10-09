import AVFoundation
import OSLog
import Foundation
import Observation

/// The music player. Not built on `AVQueuePlayer`: that swaps items reactively on end-of-file,
/// which is exactly the audible gap this engine exists to not have — true gapless needs sample-accurate scheduling ahead of
/// time, which only `AVAudioEngine` + `AVAudioPlayerNode.scheduleFile` gives on this platform.
///
/// Two player nodes (`playerA`/`playerB`), both feeding one mixer, both feeding one shared
/// `AVAudioUnitEQ`:
/// - **Gapless** (default): only the active node is used. The next track is scheduled onto it
///   with `at: nil` — "immediately following whatever's already scheduled" — *before* the
///   current one finishes, so the transition is sample-accurate with zero silence. If the next
///   file isn't downloaded/cached in time (slow network), this degrades to a reactive swap on
///   the other node instead of a hard failure — not silently claimed gapless when it wasn't.
/// - **Crossfade**: the *other* node starts the next track early, at volume 0, while the active
///   node ramps down — true overlap, which chaining on one node cannot do (`AVAudioPlayerNode`
///   only has one volume for its whole output). Mutually exclusive with gapless by construction,
///   matching `PlaybackSettingsStore.crossfadeEnabled`.
///
/// Unlike `AVPlayerItem`/`AVURLAsset`, `AVAudioFile` only reads local files — `TrackFileCache` resolves one (a real download, already-downloaded
/// or into a temp cache) before any file here is ever scheduled.
@Observable
@MainActor
public final class PlaybackEngine {
    public private(set) var currentTrack: Track?
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var errorMessage: String?
    public private(set) var isShuffled = false
    /// Sticky across track/album changes within a session, same as `isShuffled` -- deliberately
    /// not persisted to `UserDefaults` (unlike `PlaybackSettingsStore.crossfadeEnabled`,
    /// a device-audio preference): repeat is a per-listening-session choice, not a standing
    /// preference, and resets to `.off` on a fresh launch.
    public private(set) var repeatMode: RepeatMode = .off
    public private(set) var isLoading = false

    /// Fully client-side countdown; wired in `init` so expiry pauses playback here rather than
    /// making every owner of a `PlaybackEngine` remember to do that wiring itself — same
    /// shape `PlaybackEngine`'s own `sleepTimer` already uses.
    public let sleepTimer = SleepTimer()

    public var volume: Float = 1.0 {
        didSet { applyVolume() }
    }

    public var isMuted: Bool = false {
        didSet { applyVolume() }
    }

    public var hasNextTrack: Bool { queue?.nextTrack != nil }
    public var hasPreviousTrack: Bool { queue?.previousTrack != nil }

    /// Every track after the current one, in play order — the queue sheet's list. Empty once
    /// the queue is exhausted or nothing is loaded.
    public var upcomingTracks: [Track] { queue?.upcoming ?? [] }

    /// What has already been played on the way to the current track, in play order — the other
    /// half of a queue anyone can actually look through, rather than only the road ahead.
    public var playedTracks: [Track] { queue?.played ?? [] }

    /// "Track 4 of 12" — where the current track sits in the album, playlist or artist being
    /// played. `nil` for a single track started on its own, which has no list to count against.
    ///
    /// Counted in the *list's* order, not play order: shuffled, the two disagree, and a number
    /// that cannot be found among the rows on screen is worse than no number at all.
    public var trackIndexDisplay: (current: Int, total: Int)? {
        guard let display = queue?.listPositionDisplay, display.total > 1 else { return nil }
        return display
    }

    /// How far through the whole container playback is, summing the durations of the tracks
    /// already played plus the position in this one — the album's answer to
    /// `PlaybackEngine.bookProgressFraction`, and derived the same way.
    ///
    /// `nil` unless every track so far has a known length: a partial sum would draw a bar that
    /// understates the position, which is worse than drawing none.
    public var containerProgressFraction: Double? {
        guard let total = containerDurationSecs, total > 0, let queue else { return nil }
        let before = queue.played.reduce(0.0) { $0 + Double($1.durationSecs ?? 0) }
        return min(max((before + currentTime) / Double(total), 0), 1)
    }

    /// The container's whole length, or `nil` when any track in it has no duration.
    public var containerDurationSecs: Int? {
        guard let queue, queue.tracks.count > 1 else { return nil }
        var total = 0
        for track in queue.tracks {
            guard let seconds = track.durationSecs else { return nil }
            total += seconds
        }
        return total
    }

    /// The active source's own encoded format — `nil` before it's known (right after a load
    /// starts) or once nothing is playing. Drives the player's "FLAC · 44.1 kHz · 16-bit" badge.
    ///
    /// Above 48kHz, the reported `sampleRate` is the session's actual negotiated rate
    /// (`NowPlayingController.sessionSampleRate`, iOS only), not the file's own nominal one —
    /// `updateFormatSnapshot(_:)` already asked the session for it via `preferSampleRate`, and
    /// this is what makes the badge honest when a route (Bluetooth, typically) couldn't honor
    /// that request: it shows what's actually reaching the speaker, not what the file claims.
    public var currentFormat: AudioStreamDecoder.FormatInfo? {
        guard let snapshot = currentFormatSnapshot else { return nil }
        guard snapshot.sampleRate > 48000, let actual = nowPlayingController.sessionSampleRate else {
            return snapshot
        }
        return AudioStreamDecoder.FormatInfo(
            sampleRate: actual, channelCount: snapshot.channelCount,
            bitsPerChannel: snapshot.bitsPerChannel, formatID: snapshot.formatID, bitrate: snapshot.bitrate
        )
    }

    /// How far into the current track has actually been decoded and scheduled, ahead of
    /// `currentTime` — the streaming counterpart to a local file's instantly-available full
    /// length. 0 for an ordinary local-file track (nothing to show separately: the whole file is
    /// already on disk) and once a stream has fully arrived, since nothing is buffered ahead of
    /// what will play that isn't already covered by `duration` itself.
    public var bufferedTime: Double {
        guard streamingTask != nil, !streamingFinishedReceiving,
              let track = currentTrack, let boundary = boundaries.first(where: { $0.trackId == track.id })
        else { return 0 }
        return boundary.trackPositionOffsetSecs + Double(boundary.endFrame - boundary.startFrame) / boundary.sampleRate
    }

    // MARK: - Audio graph

    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()
    private let eqNode: AVAudioUnitEQ
    private let spectrumAnalyzer = SpectrumAnalyzer()
    private var isSpectrumTapInstalled = false
    /// 32 log-spaced magnitude bands, 0...1, post-EQ (tapped on `mainMixerNode`, downstream of
    /// `eqNode` — a visualizer should react to what's actually audible, curve
    /// included, not the pre-EQ signal). All zero whenever the tap isn't installed
    /// (`setSpectrumEnabled(false)`, or before it's ever been turned on) rather than stale data
    /// from whatever last played.
    public private(set) var spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    /// Which node is carrying the track actually audible right now — the other is either idle
    /// (gapless mode) or fading out during a crossfade.
    private var activeIsA = true
    private var activeNode: AVAudioPlayerNode { activeIsA ? playerA : playerB }
    private var idleNode: AVAudioPlayerNode { activeIsA ? playerB : playerA }

    /// Sample-accurate boundaries for whatever is chained on the *active* node right now, in
    /// scheduling order — gapless mode's `currentTime` is derived from these plus the node's own
    /// `playerTime`, since `scheduleFile(at: nil)` chaining means the node's own elapsed time
    /// spans every file scheduled on it, not just the one actually audible.
    private struct ScheduledBoundary {
        let trackId: String
        let startFrame: AVAudioFramePosition
        /// `var`, not `let`: a file-based boundary is complete the moment it's created (the
        /// file's own length is already known), but a *streaming* boundary starts at whatever
        /// the first buffer covers and grows as each further buffer is scheduled — `endFrame` is
        /// extended in place rather than appending one boundary per buffer, so `tick()`'s lookup
        /// stays a single, unchanged code path for both cases.
        var endFrame: AVAudioFramePosition
        let sampleRate: Double
        /// The track position (seconds) that this boundary's `startFrame` (node-relative, not
        /// file-relative) corresponds to — 0 except right after a seek, where the node's own
        /// elapsed time restarts at 0 but the *track's* position does not. Without this, playing
        /// after a seek would display "time since the seek" instead of the real position.
        let trackPositionOffsetSecs: Double
    }
    private var boundaries: [ScheduledBoundary] = []

    /// Bumped by every fresh `loadAndPlay` (a manual skip/seek/reactive reload), *before*
    /// `activeNode.stop()` — see that call's own doc comment for why this exists: `stop()`
    /// immediately fires the completion handler of every pending scheduled file it cancels,
    /// including an already-chained gapless prefetch, regardless of `completionCallbackType`.
    /// Each completion closure captures the generation active when it was scheduled and checks
    /// it still matches before treating itself as a real "this track finished playing" signal —
    /// a stale generation means this callback fired only because some *newer* load's `stop()`
    /// cancelled it, not because playback actually completed.
    private var schedulingGeneration: UInt64 = 0

    private var queue: PlayQueue?
    private var isCrossfading = false
    private var tickTask: Task<Void, Never>?
    private var crossfadeTask: Task<Void, Never>?
    private var prefetchNextTask: Task<Void, Never>?
    /// Reset to 0 by `beginPlaybackAfterLoad` (a track that actually starts playing) — counts a
    /// failure to open/stream a track, not a failure to play it once started. Caps
    /// `handleLoadFailure`'s auto-skip so an outage (server down, no network) can't
    /// silently fast-skip an entire queue burning data/battery; it stops and leaves the error
    /// message up once the cap is hit, same as reporting one failure would.
    private var consecutiveLoadFailures = 0
    private static let maxConsecutiveLoadFailures = 3

    // MARK: - Streaming

    /// The network fetch for whatever track is currently *streaming* (not yet a local file).
    /// Cancelling this is what stops an abandoned stream's network activity on a skip/seek —
    /// `Task` cancellation propagates into `StreamingTrackSource.stream`'s `for try await` loop
    /// over `URLSession.bytes`, so there is nothing else to tear down by hand.
    private var streamingTask: Task<Void, Never>?
    /// How many frames of the currently-streaming track have been handed to `scheduleBuffer` so
    /// far — the running offset the *next* buffer's `ScheduledBoundary` starts at. Reset to 0 at
    /// the start of every new streaming load; meaningless once the track has fully arrived and
    /// subsequent plays take the ordinary file-based path.
    private var streamingFrameCursor: AVAudioFramePosition = 0
    /// How many scheduled buffers from the current stream have not yet finished *playing* —
    /// distinct from "not yet received": the network can (and normally does) finish well before
    /// playback catches up. Only once this reaches 0 *and* `streamingFinishedReceiving` is true
    /// does the last buffer's own completion mean "this track is over," the streaming analogue
    /// of a file's `scheduleFile` completion.
    private var streamingBuffersPending = 0
    private var streamingFinishedReceiving = false
    /// The active source's own encoded format — a streamed track's decoder-reported format
    /// (`StreamingTrackSource.currentFormatInfo()`, via `onFormatKnown`) or a local file's
    /// `AVAudioFile.fileFormat`. Reset to `nil` at the top of every `loadAndPlay`, since it
    /// otherwise briefly reports the outgoing track's format for whatever load path takes a
    /// moment to discover the new one.
    private var currentFormatSnapshot: AudioStreamDecoder.FormatInfo?

    private let fileCache: TrackFileCache
    private let nowPlayingController: NowPlayingController
    private let settingsStore: PlaybackSettingsStore
    private let resumeStore: ResumeStore?
    /// Which album/playlist/artist/genre the current queue came from, if the caller said. Only
    /// used to key `resumeStore` — the engine itself has no concept of a container beyond this.
    public private(set) var currentContainerId: String?
    /// Called before this engine starts audio of its own, so an app with another audio source
    /// can pause it and never play two streams at once.
    public var onWillStartPlaying: (() -> Void)?

    /// Fires when audio for a track starts or resumes, at that position. With
    /// `onPlaybackStopped` this is what scrobbling is built on.
    public var onPlaybackStarted: ((_ track: Track, _ positionSecs: Double) -> Void)?
    /// Fires when audio for a track stops, and why.
    public var onPlaybackStopped: ((_ track: Track, _ positionSecs: Double, _ reason: PlaybackStopReason) -> Void)?
    /// Cover art for the lock screen. Optional; without it Now Playing shows no image.
    public var artworkProvider: (@Sendable (Track) async -> Data?)?

    private var currentArtwork: NowPlayingImage?
    private var artworkTask: Task<Void, Never>?

    public init(
        fileCache: TrackFileCache,
        nowPlayingController: NowPlayingController,
        settingsStore: PlaybackSettingsStore,
        equalizerStore: EqualizerStore,
        resumeStore: ResumeStore? = nil
    ) {
        self.resumeStore = resumeStore
        self.fileCache = fileCache
        self.nowPlayingController = nowPlayingController
        self.settingsStore = settingsStore
        eqNode = AVAudioUnitEQ(numberOfBands: EqBand.count)
        configureEqBands()
        buildGraph()
        wireEqualizer(equalizerStore)
        sleepTimer.onExpire = { [weak self] in self?.pause() }
        observeEngineConfigurationChanges()
        #if os(iOS) || os(tvOS)
        observeAudioSessionNotifications()
        #endif
    }

    /// Not iOS-gated, unlike `observeAudioSessionNotifications()` below: `AVAudioEngine`'s own
    /// configuration-change notification exists on both platforms — switching output to a USB
    /// DAC or an AirPlay device fires it.
    /// Both can renegotiate the hardware's sample rate mid-playback, which silently stops
    /// `AVAudioEngine`'s render graph without this — every node here was connected with
    /// `format: nil` (`buildGraph()`), so they renegotiate against the new hardware format on
    /// their own; the only thing actually required is restarting the engine if the change
    /// stopped it. Not rescheduling `boundaries`/the already-queued buffers on top of that: a
    /// config change mid-track is rare enough that the existing schedule surviving a restart
    /// intact is the reasonable default, reasoned from Apple's own documented behavior for this
    /// notification -- not verified against real AirPlay hardware, since none was available to
    /// confirm it directly.
    private func observeEngineConfigurationChanges() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleEngineConfigurationChange()
            }
        }
    }

    private func handleEngineConfigurationChange() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    #if os(iOS) || os(tvOS)
    /// Calls, Siri and unplugged headphones. iOS only: macOS has no audio session.
    private func observeAudioSessionNotifications() {
        // `Notification`/`userInfo` (`[AnyHashable: Any]?`) aren't `Sendable`, and
        // `NotificationCenter`'s observer closure is `@Sendable` — extracting the two plain
        // `UInt`s this needs *inside* that closure and handing only those (genuinely `Sendable`)
        // values into `MainActor.assumeIsolated` is what keeps Swift 6 strict concurrency happy;
        // reading the whole `Notification` inside the isolated block, or hopping through a
        // fresh `Task { @MainActor in }` capturing it, both trip the same "sending non-Sendable
        // value" error on a real iOS build (macOS never compiles this block at all, so neither
        // mistake showed up there).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        }
    }

    /// A phone call, Siri, or another app taking the audio session pauses playback. `.ended`
    /// with `.shouldResume` set resumes it automatically — an interruption that clears itself
    /// (a Siri query that turned out not to need audio, a call declined instantly) shouldn't
    /// leave the listener needing to manually hit play again, matching every other music player
    /// on the platform.
    private func handleInterruption(typeValue: UInt, optionsValue: UInt?) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            pauseAudioOnly()
        case .ended:
            guard let optionsValue else { return }
            if AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                resumeAudioOnly()
            }
        @unknown default:
            break
        }
    }

    /// Headphones (wired or Bluetooth) being pulled must not continue out loud on the speaker
    /// unannounced — `.oldDeviceUnavailable` is the one route-change reason that means exactly
    /// that, as opposed to e.g. a new AirPlay route connecting, which should keep playing.
    private func handleRouteChange(reasonValue: UInt) {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue), reason == .oldDeviceUnavailable else { return }
        pauseAudioOnly()
    }
    #endif

    // MARK: - Graph setup

    private func buildGraph() {
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(mixer)
        engine.attach(eqNode)

        engine.connect(playerA, to: mixer, format: nil)
        engine.connect(playerB, to: mixer, format: nil)
        engine.connect(mixer, to: eqNode, format: nil)
        engine.connect(eqNode, to: engine.mainMixerNode, format: nil)
    }

    /// One `AVAudioUnitEQ` band per `EqBand` frequency, `.parametric` (a peaking filter) with
    /// a moderate Q, using `AVAudioUnitEQ`'s native bands.
    private func configureEqBands() {
        for (index, frequency) in EqBand.standardFrequenciesHz.enumerated() {
            let band = eqNode.bands[index]
            band.filterType = .parametric
            band.frequency = Float(frequency)
            band.bandwidth = Float(1.0 / EqBand.qFactor)
            band.gain = 0
            band.bypass = false
        }
    }

    /// Registers this engine as `EqualizerStore`'s second sink (see that type's own doc comment)
    /// and primes the EQ node with whatever the store already has loaded.
    private func wireEqualizer(_ store: EqualizerStore) {
        store.onSettingsChanged = { [weak self] enabled, preampDb, bandGainsDb in
            self?.applyEqualizerSettings(enabled: enabled, preampDb: preampDb, bandGainsDb: bandGainsDb)
        }
        let current = store.currentSettings()
        applyEqualizerSettings(enabled: current.enabled, preampDb: current.preampDb, bandGainsDb: current.bandGainsDb)
    }

    private func applyEqualizerSettings(enabled: Bool, preampDb: Double, bandGainsDb: [Double]) {
        eqNode.bypass = !enabled
        eqNode.globalGain = Float(preampDb)
        for (index, gainDb) in bandGainsDb.enumerated() where eqNode.bands.indices.contains(index) {
            eqNode.bands[index].gain = Float(gainDb)
        }
    }

    // MARK: - Transport

    public func play(
        tracks: [Track], startTrackId: String? = nil,
        startPositionSecs: Double = 0, containerId: String? = nil
    ) async {
        guard !tracks.isEmpty else { return }
        // Starting something unrelated, not skipping this: `replaced` keeps the two apart.
        if isPlaying { closeSpan(atPositionSecs: currentTime, reason: .replaced) }

        onWillStartPlaying?()
        stopEngineAndClearSchedule()

        var newQueue = PlayQueue(tracks: tracks, startTrackId: startTrackId)
        if isShuffled && startTrackId == nil {
            // Shuffle of a whole container: start anywhere, not always at track 1.
            newQueue.shuffleFromStart()
        } else {
            newQueue.setShuffled(isShuffled)
        }
        queue = newQueue
        currentContainerId = containerId
        errorMessage = nil

        guard let track = newQueue.currentTrack else { return }
        // A resume position only applies to the track it was saved against — starting a
        // container at a *different* track than the one remembered must begin that track at 0,
        // not at the previous track's offset.
        let seekTo = (startTrackId != nil && startTrackId == track.id) ? startPositionSecs : 0
        await loadAndPlay(track: track, seekTo: seekTo)
    }

    public func togglePlayPause() {
        isPlaying ? pauseAudioOnly() : resumeAudioOnly()
    }

    /// Pauses without discarding the queue/schedule — `resumeAudioOnly()`/`togglePlayPause()`
    /// pick up exactly where this left off.
    public func pause() {
        pauseAudioOnly()
    }

    private func pauseAudioOnly() {
        guard isPlaying else { return }
        playerA.pause()
        playerB.pause()
        isPlaying = false
        stopTicking()
        saveProgressNow()
        pushNowPlayingInfo()
        closeSpan(atPositionSecs: currentTime, reason: .stopped)
    }

    private func resumeAudioOnly() {
        guard currentTrack != nil, !isPlaying else { return }
        wireRemoteCommands()
        onWillStartPlaying?()
        if !engine.isRunning { try? engine.start() }
        activeNode.play()
        if isCrossfading { idleNode.play() }
        isPlaying = true
        startTicking()
        pushNowPlayingInfo()
        openSpan(atPositionSecs: currentTime)
    }

    public func stop() {
        stopEngineAndClearSchedule()
        saveProgressNow()
        closeSpan(atPositionSecs: currentTime, reason: .stopped)
        nowPlayingController.clear()

        currentTrack = nil
        duration = 0
        currentTime = 0
        queue = nil
        artworkTask?.cancel()
        currentArtwork = nil
    }

    private func stopEngineAndClearSchedule() {
        // Bumped *before* the `stop()` calls, for exactly the reason `loadAndPlay` documents at
        // its own `stop()`: stopping a node immediately fires the completion handler of every
        // file still pending on it, and those handlers only stand down if the generation they
        // captured is stale.
        //
        // `loadAndPlay` had this guard; this shared teardown did not — and it runs *first* in
        // `play(tracks:)`, before `loadAndPlay` gets a chance to bump. So every pending segment
        // of the outgoing track (the playing one, plus the gapless prefetch already chained
        // behind it) came back as a genuine "track finished", each `Task { @MainActor }`-hopped
        // to land *after* the new queue was installed, and each advancing it one more step.
        // Tapping the first track of an album started playback several tracks in.
        schedulingGeneration += 1

        playerA.stop()
        playerB.stop()
        isPlaying = false
        isCrossfading = false
        activeIsA = true
        boundaries = []
        stopTicking()
        crossfadeTask?.cancel()
        prefetchNextTask?.cancel()
        streamingTask?.cancel()
    }

    /// Deliberately ignores `repeatMode` -- a manual skip always moves one literal position
    /// forward, or does nothing at the true end of the queue. Repeat only governs what happens
    /// when a track finishes *on its own* (`handleActiveNodeConsumedSegment`, and the prefetch/
    /// crossfade lookaheads that prepare for it); letting `.one` hijack a deliberate Next would
    /// trap a listener on the current track until they changed the mode first.
    public func next() {
        guard var queue, let nextTrack = queue.nextTrack else { return }
        cancelInFlightCrossfade()
        closeSpan(atPositionSecs: currentTime, reason: .skipped)
        queue.advance()
        self.queue = queue
        Task { await loadAndPlay(track: nextTrack) }
    }

    public func previous() {
        // Restart-the-current-track-if-more-than-a-few-seconds-in is the universal music-player
        // convention (same reasoning a CD player's "previous" button has always used) — a
        // listener hitting previous three seconds into a song wants the *previous* song, not to
        // restart this one, but ten seconds in they usually want this one restarted.
        if currentTime > 3 {
            Task { await seek(to: 0) }
            return
        }
        guard var queue, let previousTrack = queue.previousTrack else { return }
        cancelInFlightCrossfade()
        closeSpan(atPositionSecs: currentTime, reason: .skipped)
        queue.goToPrevious()
        self.queue = queue
        Task { await loadAndPlay(track: previousTrack) }
    }

    /// A manual skip that lands mid-crossfade must not race the fade task's own completion —
    /// both would otherwise try to set `currentTrack`/`queue`/`boundaries` around the same time.
    /// `loadAndPlay`'s own `activeNode.stop()` already handles stopping whichever node the fade
    /// had going; this only needs to stop the *other* one and drop the in-flight fade itself.
    private func cancelInFlightCrossfade() {
        guard isCrossfading else { return }
        crossfadeTask?.cancel()
        isCrossfading = false
        idleNode.stop()
    }

    public func setShuffled(_ shuffled: Bool) {
        isShuffled = shuffled
        queue?.setShuffled(shuffled)
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
    }

    /// Installs or removes the real-time tap driving `spectrum` — never left running
    /// unconditionally, since a tap callback firing ~40 times a second for as long as anything
    /// is playing is real, avoidable CPU/battery cost — turn it on only while a visualizer is
    /// on screen.
    public func setSpectrumEnabled(_ enabled: Bool) {
        guard enabled != isSpectrumTapInstalled else { return }
        isSpectrumTapInstalled = enabled
        if enabled {
            // `analyzer` is captured as a plain local here, resolved once while this method
            // itself is still running on the main actor — the tap callback below then closes
            // over that local `Sendable` reference, not `self.spectrumAnalyzer`.
            //
            // `boxedSelf` (`Unmanaged`, not `[weak self]`) avoids putting a MainActor-typed
            // reference in the closure's captures at all. Unretained is safe here specifically
            // because this engine is a long-lived, effectively-singleton instance for the app's
            // lifetime — never deallocated mid-callback.
            //
            // The explicit `@Sendable (...) -> Void` type annotation on `tapBlock` below is
            // load-bearing, not decorative: a closure *literal* written inline inside a
            // `@MainActor` method — this one — defaults to inheriting that method's own
            // main-actor isolation from its lexical context, regardless of what it captures or
            // doesn't. That inherited isolation is invisible at the call site (no compile
            // error — `installTap`'s parameter type is plain/non-isolated, so the mismatch
            // isn't caught statically) but real at runtime: every invocation from CoreAudio's
            // audio-render thread trapped at entry, before a single line of the closure's own
            // body ran (`swift_task_checkIsolatedSwift` / SIGTRAP), reproduced live against
            // several different closure bodies and confirmed via this app's own crash logs.
            // Giving the closure an explicit `@Sendable` type forces it to be considered
            // non-isolated from the moment it's created, breaking that inheritance regardless
            // of where it's lexically written.
            let analyzer = spectrumAnalyzer
            let boxedSelf = Unmanaged.passUnretained(self)
            let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
                guard let bands = analyzer.magnitudes(from: buffer) else { return }
                // Plain GCD, not `Task { @MainActor in }` — the latter, even called from a
                // closure that's genuinely non-isolated, also crashed here (same trap, same
                // symbol): CoreAudio's tap delivers on its own `RealtimeMessenger` dispatch
                // queue, which apparently doesn't satisfy whatever Swift's Task executor-
                // checking machinery expects when hopping from there. `DispatchQueue.main`
                // unconditionally *is* the main actor's executor, so `assumeIsolated` inside an
                // `.async` onto it is a real guarantee, not a hope.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        boxedSelf.takeUnretainedValue().spectrum = bands
                    }
                }
            }
            // `format: nil` — the tap then uses the bus's own native output format internally,
            // without this call separately querying `mainMixerNode.outputFormat(forBus:)` first.
            // That explicit query is gone on purpose: a user-reported crash (later confirmed via
            // its own crash log — `AURemoteIO::Cleanup` / an RPC timeout inside
            // `-[AVAudioNode outputFormatForBus:]`, right as a track finished) traces through
            // this exact call. Bisection had already shown a *related* CoreAudio teardown crash
            // reproduces even on code from before any of this tap's own work, so this doesn't
            // claim to be a full fix for that underlying engine-teardown race — only that this
            // call was one avoidable way of poking at the same fragile surface, needlessly:
            // `installTap` never required querying the format up front.
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tapBlock)
        } else {
            engine.mainMixerNode.removeTap(onBus: 0)
            spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        }
    }

    /// Jumps directly to a track already in the queue — the queue sheet's tap-to-jump. Does
    /// nothing if `trackId` isn't in the current queue (a stale tap after the queue changed
    /// underneath the sheet).
    public func jump(toTrackId trackId: String) {
        guard var queue, queue.jumpTo(trackId: trackId) != nil, let track = queue.currentTrack else { return }
        cancelInFlightCrossfade()
        closeSpan(atPositionSecs: currentTime, reason: .skipped)
        self.queue = queue
        Task { await loadAndPlay(track: track) }
    }

    public func seek(to seconds: Double) async {
        guard let track = currentTrack else { return }
        let clamped = min(max(seconds, 0), duration)
        let wasPlaying = isPlaying
        cancelInFlightCrossfade()
        // Scrubbing within a track says nothing about liking or skipping it.
        closeSpan(atPositionSecs: currentTime)
        await loadAndPlay(track: track, seekTo: clamped)
        if !wasPlaying { pauseAudioOnly() }
    }

    private func applyVolume() {
        let effective = isMuted ? 0 : volume
        playerA.volume = effective
        playerB.volume = effective
    }

    // MARK: - File loading

    private func loadAndPlay(track: Track, seekTo: Double = 0) async {
        currentTrack = track
        duration = Double(track.durationSecs ?? 0)
        currentTime = seekTo
        isLoading = true
        currentFormatSnapshot = nil
        loadArtwork(track: track)
        streamingTask?.cancel()
        streamingTask = nil

        // A track with no local copy yet streams instead of waiting on a full download.
        // Seeking always uses the file path below: `StreamingTrackSource` can't seek yet, so
        // scrubbing before a track has fully arrived waits for the full download.
        if seekTo == 0, await fileCache.existingLocalURL(trackId: track.id) == nil {
            await loadAndPlayStreaming(track: track)
            return
        }

        defer { isLoading = false }

        do {
            let url = try await fileCache.localURL(trackId: track.id)
            let file = try AVAudioFile(forReading: url)
            updateFormatSnapshot(Self.formatInfo(from: file.fileFormat))
            adoptDurationFromFile(file)

            if !engine.isRunning { try engine.start() }

            // A fresh load (not a seek) always restarts the active node's own schedule —
            // `scheduleFile`'s `at: nil` only chains cleanly onto a schedule this engine itself
            // built; a stale one from a previous track must not linger underneath a new load.
            //
            // Bumped *before* `stop()`: stopping a node immediately fires the completion handler
            // of every pending file it cancels (including an already-chained gapless prefetch),
            // regardless of `completionCallbackType` — without this generation check, that stale
            // "completion" would call `handleActiveNodeConsumedSegment()` as if the track had
            // really finished, advancing the queue an extra, spurious step on every manual skip.
            schedulingGeneration += 1
            let generation = schedulingGeneration
            activeNode.stop()
            boundaries = []

            var startFrame = seekTo > 0 ? AVAudioFramePosition(seekTo * file.processingFormat.sampleRate) : 0
            // A saved position at or past the end of the file — the server's recorded duration
            // runs a little longer than the decoded audio, or the track was last played to the
            // end — used to go negative here and trap converting to the unsigned frame count.
            // Starting over is what a listener expects from a track they already finished.
            if startFrame >= file.length { startFrame = 0 }
            let startSecs = startFrame > 0 ? seekTo : 0
            currentTime = startSecs
            if startFrame > 0 {
                let remaining = AVAudioFrameCount(file.length - startFrame)
                activeNode.scheduleSegment(
                    file, startingFrame: startFrame, frameCount: remaining, at: nil,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.schedulingGeneration == generation else { return }
                        self.handleActiveNodeConsumedSegment()
                    }
                }
            } else {
                activeNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.schedulingGeneration == generation else { return }
                        self.handleActiveNodeConsumedSegment()
                    }
                }
            }
            boundaries.append(ScheduledBoundary(
                trackId: track.id, startFrame: 0, endFrame: file.length - startFrame,
                sampleRate: file.processingFormat.sampleRate, trackPositionOffsetSecs: startSecs
            ))

            beginPlaybackAfterLoad(seekTo: startSecs)
        } catch {
            handleLoadFailure(loc("Could not load this track."))
        }
    }

    /// The "start audible playback" sequence every load path (file, streamed, and the ALAC
    /// fallback-to-file) ends with once *something* has been scheduled on `activeNode` — pulled
    /// out once it needed to run from three places rather than one.
    private func beginPlaybackAfterLoad(seekTo: Double) {
        wireRemoteCommands()
        onWillStartPlaying?()
        activeNode.play()
        isPlaying = true
        isLoading = false
        errorMessage = nil
        consecutiveLoadFailures = 0
        startTicking()
        pushNowPlayingInfo()
        openSpan(atPositionSecs: seekTo)
    }

    /// One track could not be opened or streamed — reported live: this used to just set
    /// `errorMessage` and stop, leaving playback stuck on the failed track (the transport still
    /// showing "Pause," since nothing here touched `isPlaying`) until the listener noticed and
    /// intervened by hand. Real players treat one bad track as something to skip past, not a
    /// reason to stop the queue — this does the same, capped by `consecutiveLoadFailures` so a
    /// genuine outage stops and reports itself instead of fast-skipping silently through
    /// everything left in the queue.
    private func handleLoadFailure(_ message: String) {
        errorMessage = message
        isLoading = false
        consecutiveLoadFailures += 1
        guard consecutiveLoadFailures <= Self.maxConsecutiveLoadFailures, queue?.nextTrack != nil else { return }
        next()
    }

    // MARK: - Streaming playback

    /// The streaming counterpart to the file-based path above — schedules `AVAudioPCMBuffer`s
    /// onto the active node as `TrackFileCache.stream` decodes them, instead of waiting for
    /// `AVAudioFile` to open a complete local file. Falls back to the ordinary file path for the
    /// one case that cannot stream at all
    /// (`StreamingTrackSource.FallbackToLocalPlaybackRequired` — M4A/ALAC with a trailing `moov`
    /// atom).
    ///
    /// Gapless chaining to the *next* track does not start until this one has fully arrived —
    /// `finishStreamingReceiving` is what calls `schedulePrefetchAndChainNext`/
    /// `prefetchNextTrackForCrossfade`, the same two functions the file path already used, so
    /// chaining onto a streamed boundary needs no special-casing there: it only ever reads
    /// `boundaries.last`, which this path keeps correctly extended as buffers arrive. A track
    /// that reaches its own end before its stream has finished arriving degrades to the same
    /// reactive-load gap `handleActiveNodeConsumedSegment()` already falls back to when a
    /// gapless prefetch loses the race — not a new failure mode, the existing one reached from a
    /// new direction.
    private func loadAndPlayStreaming(track: Track) async {
        schedulingGeneration += 1
        let generation = schedulingGeneration
        activeNode.stop()
        boundaries = []
        streamingFrameCursor = 0
        streamingBuffersPending = 0
        streamingFinishedReceiving = false

        if !engine.isRunning { try? engine.start() }

        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.fileCache.stream(trackId: track.id, onBuffer: { [weak self] decoded in
                    guard let self else { return }
                    await MainActor.run {
                        guard self.schedulingGeneration == generation else { return }
                        self.scheduleStreamedBuffer(decoded, trackId: track.id, generation: generation)
                    }
                }, onFormatKnown: { [weak self] format in
                    guard let self else { return }
                    await MainActor.run {
                        guard self.schedulingGeneration == generation else { return }
                        self.updateFormatSnapshot(format)
                    }
                })
                guard self.schedulingGeneration == generation else { return }
                self.finishStreamingReceiving(generation: generation)
            } catch let fallback as StreamingTrackSource.FallbackToLocalPlaybackRequired {
                guard self.schedulingGeneration == generation else { return }
                self.switchToLocalFile(fallback.localURL, track: track, generation: generation)
            } catch is CancellationError {
                // A newer load or a stop cancelled this task — every state mutation this task's
                // own work could still make is already behind the same generation check, so
                // there is nothing left to undo here.
            } catch {
                guard self.schedulingGeneration == generation else { return }
                // The cause goes to the log, not only to the sofa. Swallowing it meant a track
                // that would not play left no trace at all, and finding out why took pulling
                // the bytes out of the server by hand.
                Logger.playback.error("streaming \(track.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self.handleLoadFailure(loc("Could not play this track."))
            }
        }
    }

    /// Schedules one decoded buffer and extends the current track's `ScheduledBoundary` to cover
    /// it — the first call also starts audible playback, exactly like the file path's own single
    /// `scheduleFile`/`scheduleSegment` call did, just spread over however many buffers a track
    /// takes to arrive instead of one.
    private func scheduleStreamedBuffer(_ decoded: AudioStreamDecoder.DecodedBuffer, trackId: String, generation: UInt64) {
        let buffer = decoded.buffer
        let frameLength = AVAudioFramePosition(buffer.frameLength)
        guard frameLength > 0 else { return }
        let startFrame = streamingFrameCursor
        streamingFrameCursor += frameLength
        streamingBuffersPending += 1

        activeNode.scheduleBuffer(buffer, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.schedulingGeneration == generation else { return }
                self.handleStreamedBufferConsumed(generation: generation)
            }
        }

        if boundaries.isEmpty {
            boundaries = [ScheduledBoundary(
                trackId: trackId, startFrame: startFrame, endFrame: streamingFrameCursor,
                sampleRate: buffer.format.sampleRate, trackPositionOffsetSecs: 0
            )]
            beginPlaybackAfterLoad(seekTo: 0)
        } else {
            boundaries[0].endFrame = streamingFrameCursor
        }
    }

    /// A streamed buffer finished *playing* (as opposed to finished arriving, which
    /// `finishStreamingReceiving` tracks separately) — only once both are true does the track
    /// actually end, the streaming analogue of a file's single `scheduleFile` completion.
    private func handleStreamedBufferConsumed(generation: UInt64) {
        streamingBuffersPending -= 1
        guard streamingFinishedReceiving, streamingBuffersPending <= 0 else { return }
        handleActiveNodeConsumedSegment()
    }

    /// The network side of the current track is done — every byte has arrived and been decoded
    /// and scheduled, though not necessarily *played* yet. This is the streaming equivalent of
    /// the moment the file path's `loadAndPlay` finishes its single scheduling call, so it is
    /// what starts next-track prefetching, exactly as the file path already did at that point.
    private func finishStreamingReceiving(generation: UInt64) {
        streamingFinishedReceiving = true
        adoptDurationFromStream()
        if streamingBuffersPending <= 0 {
            // Every scheduled buffer already finished playing before the network finished
            // delivering the rest — a short track well ahead of a slow tail, or a fast
            // connection outrunning real-time playback for a short enough clip. There is no
            // further buffer-completion callback coming to notice the track is over, so this
            // checks directly instead of waiting for one that will never arrive.
            handleActiveNodeConsumedSegment()
            return
        }
        if settingsStore.crossfadeEnabled {
            prefetchNextTrackForCrossfade()
        } else {
            schedulePrefetchAndChainNext()
        }
    }

    /// The length the server failed to record, taken from the audio itself.
    ///
    /// A track whose `duration_secs` never got extracted on upload left the scrub bar showing a
    /// full-width nothing and "-0:00" however long the song was, and made a playlist's total
    /// length unknowable — two thirds of a real library here. The file on disk has always known
    /// the answer. Only ever fills a gap: a duration the server does send is left alone, since
    /// it is what every other screen and the server's own progress maths already agree on.
    private func adoptDurationFromFile(_ file: AVAudioFile) {
        guard duration <= 0 else { return }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length > 0 else { return }
        duration = Double(file.length) / rate
    }

    /// The same gap again, for a track that arrived by being chained onto the one before it:
    /// its boundary was measured off the prefetched file and carries the frame count.
    private func adoptDurationFromBoundary(_ boundary: ScheduledBoundary) {
        guard duration <= 0, boundary.sampleRate > 0 else { return }
        let frames = boundary.endFrame - boundary.startFrame
        guard frames > 0 else { return }
        duration = Double(frames) / boundary.sampleRate
    }

    /// The same gap, filled for a track played straight off the network: once the last buffer
    /// has been decoded, the frames counted so far *are* the whole track.
    private func adoptDurationFromStream() {
        guard duration <= 0, streamingFrameCursor > 0,
              let rate = currentFormatSnapshot?.sampleRate, rate > 0
        else { return }
        duration = Double(streamingFrameCursor) / rate
    }

    /// The ALAC/M4A trailing-`moov` case: `StreamingTrackSource` could not parse the format
    /// progressively at all, and instead fully downloaded the track through the ordinary
    /// `TrackFileCache` cache (see `StreamingTrackSource.FallbackToLocalPlaybackRequired`'s
    /// own doc comment). By the time this runs, the file is already complete on disk — this is
    /// the same one-`scheduleFile`-call shape `loadAndPlay`'s own file branch uses, just entered
    /// from a different starting point.
    private func switchToLocalFile(_ url: URL, track: Track, generation: UInt64) {
        guard let file = try? AVAudioFile(forReading: url) else {
            handleLoadFailure(loc("Could not load this track."))
            return
        }
        updateFormatSnapshot(Self.formatInfo(from: file.fileFormat))

        schedulingGeneration += 1
        let newGeneration = schedulingGeneration
        activeNode.stop()
        boundaries = []

        activeNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.schedulingGeneration == newGeneration else { return }
                self.handleActiveNodeConsumedSegment()
            }
        }
        boundaries.append(ScheduledBoundary(
            trackId: track.id, startFrame: 0, endFrame: file.length,
            sampleRate: file.processingFormat.sampleRate, trackPositionOffsetSecs: 0
        ))

        beginPlaybackAfterLoad(seekTo: 0)

        if settingsStore.crossfadeEnabled {
            prefetchNextTrackForCrossfade()
        } else {
            schedulePrefetchAndChainNext()
        }
    }

    /// Crossfade mode's analogue to `schedulePrefetchAndChainNext()` below — that one chains the
    /// next file directly onto the active node's own schedule, which only gapless mode can do (a
    /// crossfade needs the *other*, currently-idle node, started at a precise moment inside
    /// `beginCrossfade()`, not chained ahead of time). This only warms `fileCache`'s download,
    /// called as early as `loadAndPlay` itself instead of waiting until `beginCrossfade()` fires
    /// with just `fadeDurationSecs` (1-12s, default 4s) of real time left on the outgoing track —
    /// by the time `beginCrossfade()` calls `fileCache.localURL`, it's a cache hit (or already
    /// well into the same in-flight download it can just join) instead of racing a fresh
    /// download/decode against the fade window.
    private func prefetchNextTrackForCrossfade() {
        prefetchNextTask?.cancel()
        guard let next = queue?.trackAfterCurrent(repeatMode: repeatMode) else { return }
        prefetchNextTask = Task { await fileCache.prefetch(trackId: next.id) }
    }

    /// Gapless mode only — resolves and schedules the *next* track onto the active node's
    /// existing schedule ahead of time, so `scheduleFile(at: nil)` lands it sample-accurately
    /// right after the current one with no gap. Best-effort: if the network is slow enough that
    /// this hasn't finished by the time the current track ends, `handleActiveNodeConsumedSegment`
    /// falls back to a reactive load instead — a real (if rare) gap, not a crash or silent stall.
    private func schedulePrefetchAndChainNext() {
        prefetchNextTask?.cancel()
        guard let next = queue?.trackAfterCurrent(repeatMode: repeatMode) else { return }
        prefetchNextTask = Task { [weak self] in
            guard let self else { return }
            guard let url = try? await fileCache.localURL(trackId: next.id) else { return }
            guard let file = try? AVAudioFile(forReading: url) else { return }
            guard !Task.isCancelled, let lastBoundary = boundaries.last, lastBoundary.trackId == currentTrack?.id else { return }

            let generation = schedulingGeneration
            activeNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.schedulingGeneration == generation else { return }
                    self.handleActiveNodeConsumedSegment()
                }
            }
            boundaries.append(ScheduledBoundary(
                trackId: next.id, startFrame: lastBoundary.endFrame,
                endFrame: lastBoundary.endFrame + file.length, sampleRate: file.processingFormat.sampleRate,
                trackPositionOffsetSecs: 0
            ))
        }
    }

    /// Fires once a scheduled segment has *actually finished playing* — for the second-to-last
    /// boundary that means "the next chained file is now the one actually audible," which is
    /// exactly when book-keeping (queue position, progress, Now Playing, prefetching the
    /// *following* track) needs to catch up; for the true last boundary it means the whole
    /// gapless chain — or a lone track with no prefetch ready in time — has finished.
    ///
    /// Every scheduling call in this file uses `completionCallbackType: .dataPlayedBack`, not
    /// `.dataConsumed` — `.dataConsumed` fires once a file's data is fully *read into the
    /// buffer*, which for a compressed file on a fast machine can happen well before that data
    /// has actually finished being *heard*.
    ///
    /// That alone wasn't the whole bug, though — the real one (found via live verification,
    /// reproduced 3/3 times): `AVAudioPlayerNode.stop()` immediately fires the completion
    /// handler of every pending file it cancels, *regardless* of `completionCallbackType`. Since
    /// gapless mode always has the next track pre-chained onto the same node
    /// (`schedulePrefetchAndChainNext`), every manual skip/seek — which starts with
    /// `activeNode.stop()` in `loadAndPlay` — fired two "completions" at once: one for the track
    /// being abandoned, one for the already-chained prefetch. Each called this method, each
    /// advanced the queue and reactively loaded another track, which chained another prefetch,
    /// which the *next* `stop()` cancelled the same way — a self-sustaining cascade with no
    /// relationship to real playback timing (confirmed live: over 200 tracks advanced in ~3
    /// seconds from two single clicks). `schedulingGeneration` fixes this: every completion
    /// closure captures the generation active when it was scheduled and this method's callers
    /// check it's still current before treating the callback as real — a stale generation means
    /// it fired only because a *newer* load's `stop()` cancelled it.
    private func handleActiveNodeConsumedSegment() {
        guard var queue, let finishedTrack = currentTrack else { return }
        let finishedDuration = Double(finishedTrack.durationSecs ?? Int(currentTime))
        closeSpan(atPositionSecs: finishedDuration, reason: .completed)

        guard let next = queue.advance(repeatMode: repeatMode) else {
            isPlaying = false
            currentTrack = nil
            stopTicking()
            nowPlayingController.clear()
            self.queue = queue
            // Played to the end: the next Play on this container should start it over, not
            // resume onto the last second of the final track.
            if let containerId = currentContainerId { resumeStore?.clearResume(containerId: containerId) }
            return
        }
        self.queue = queue
        saveResumePoint(track: next, positionSecs: 0)

        // Already chained (the common, truly-gapless case): the boundary list already has an
        // entry starting where the finished track ended, so just adopt it as current and keep
        // ticking — no reload, no new `scheduleFile` call, nothing for the audio thread to do.
        if boundaries.count > 1, boundaries[1].trackId == next.id {
            boundaries.removeFirst()
            currentTrack = next
            duration = Double(next.durationSecs ?? 0)
            // The boundary was built from the prefetched file, so it knows the length even when
            // the server does not. Without this the scrub bar went back to "-0:00" at the first
            // track change — the gap `adoptDurationFromFile` could not reach, because a chained
            // or crossfaded track never goes through `loadAndPlay` at all.
            adoptDurationFromBoundary(boundaries[0])
            loadArtwork(track: next)
            pushNowPlayingInfo()
            // The other paths start a track through `beginPlaybackAfterLoad` or the crossfade,
            // which report it; a chained track never passes through either.
            openSpan(atPositionSecs: 0)
            if !settingsStore.crossfadeEnabled {
                schedulePrefetchAndChainNext()
            }
            return
        }

        // The prefetch didn't win the race — reactively load, same as `PlaybackEngine`'s own
        // file-end handling. A real (rare) gap, not a silent claim of gaplessness.
        Task { await loadAndPlay(track: next) }
    }

    // MARK: - Crossfade

    /// Called from the tick loop once within `fadeDurationSecs` of the current track ending, in
    /// crossfade mode only. Starts the next track on the idle node at volume 0 and ramps both
    /// nodes' volumes over the configured duration — real overlap, unlike gapless chaining on
    /// one node, which is exactly why crossfade needs the second node at all.
    private func beginCrossfade() {
        guard !isCrossfading, let queue, let next = queue.trackAfterCurrent(repeatMode: repeatMode) else { return }
        isCrossfading = true
        let outgoingNode = activeNode
        let incomingNode = idleNode
        let fadeSecs = settingsStore.fadeDurationSecs

        crossfadeTask = Task { [weak self] in
            guard let self else { return }
            guard let url = try? await fileCache.localURL(trackId: next.id),
                  let file = try? AVAudioFile(forReading: url)
            else {
                // Without resetting this, a failed fetch/open left `isCrossfading` stuck `true`
                // forever — silently disabling every future crossfade *and* `tick()`'s own
                // position updates for the rest of the session (its guard at the top of this
                // function skips both while `isCrossfading` is set).
                self.isCrossfading = false
                return
            }
            guard !Task.isCancelled else { return }

            incomingNode.stop()
            incomingNode.volume = 0
            // Bumped here, before the fade even starts, for the same reason `loadAndPlay` bumps
            // before its own `stop()`: `outgoingNode.stop()` below (once the fade completes) fires
            // the completion handler still registered for whatever track that node was carrying —
            // which, without this, would still match the *current* generation (nothing else
            // changed it) and fire `handleActiveNodeConsumedSegment()` a second time, right on top
            // of the bookkeeping this task already does by hand a few lines further down. Live
            // symptom before this fix: the queue silently skipped an extra track immediately after
            // every crossfade, with the freshly-started incoming track spuriously logged as
            // "completed" from position 0 — which read as "the next song isn't loaded yet."
            schedulingGeneration += 1
            let generation = schedulingGeneration
            incomingNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.schedulingGeneration == generation else { return }
                    self.handleActiveNodeConsumedSegment()
                }
            }
            incomingNode.play()

            let steps = 20
            let stepNanos = UInt64((fadeSecs / Double(steps)) * 1_000_000_000)
            let targetVolume = self.isMuted ? 0 : self.volume
            for step in 1...steps {
                guard !Task.isCancelled else { break }
                let fraction = Float(step) / Float(steps)
                outgoingNode.volume = targetVolume * (1 - fraction)
                incomingNode.volume = targetVolume * fraction
                try? await Task.sleep(nanoseconds: stepNanos)
            }
            guard !Task.isCancelled else { return }

            outgoingNode.stop()
            outgoingNode.volume = targetVolume
            activeIsA.toggle()
            isCrossfading = false
            boundaries = [ScheduledBoundary(
                trackId: next.id, startFrame: 0, endFrame: file.length,
                sampleRate: file.processingFormat.sampleRate, trackPositionOffsetSecs: 0
            )]

            var queue = self.queue
            queue?.advance()
            self.queue = queue
            currentTrack = next
            duration = Double(next.durationSecs ?? 0)
            adoptDurationFromFile(file)
            loadArtwork(track: next)
            pushNowPlayingInfo()
            openSpan(atPositionSecs: 0)
        }
    }

    // MARK: - Ticking / progress

    private func startTicking() {
        stopTicking()
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() async {
        // During a crossfade, position tracking is skipped for this tick — two nodes are both
        // live at once, and `boundaries` is mid-transition; the fade task itself sets the
        // authoritative `currentTrack`/`duration` once it completes.
        guard isPlaying, !isCrossfading else { return }
        guard let nodeElapsedFrames = elapsedFrames(of: activeNode) else { return }
        guard let boundary = boundaries.first(where: {
            nodeElapsedFrames >= $0.startFrame && nodeElapsedFrames < $0.endFrame
        }) ?? boundaries.first else { return }

        currentTime = boundary.trackPositionOffsetSecs
            + Double(nodeElapsedFrames - boundary.startFrame) / boundary.sampleRate

        // Grounded in the real file's own remaining frames (`boundary.endFrame`, set from
        // `AVAudioFile.length` when the track was scheduled), not `duration - currentTime`
        // (server-reported `durationSecs`) — confirmed live via temporary structured logging
        // that the two can disagree by a few hundred milliseconds even for an ordinary track
        // (MP3 VBR headers/encoder delay are the usual cause). That gap meant the crossfade
        // could start with *less* real audio left than `fadeDurationSecs` itself needs, so the
        // outgoing track went silent before the fade-out finished ramping — audible as "no real
        // fade," exactly the live report this fixes.
        let remainingRealSecs = Double(boundary.endFrame - nodeElapsedFrames) / boundary.sampleRate
        if settingsStore.crossfadeEnabled, !isCrossfading, hasNextTrack,
           remainingRealSecs <= settingsStore.fadeDurationSecs {
            beginCrossfade()
        }
    }

    /// A local file's on-disk (encoded) format, read the same way `AVAudioFile.fileFormat`
    /// exposes it — distinct from `.processingFormat`, which is the decoded PCM shape the engine
    /// actually schedules and tells nothing about the source codec/bit depth the format badge
    /// needs. Bitrate isn't derivable from `AVAudioFile` without reading the container's own
    /// metadata, so it's left `nil` here — the badge only needs it as a nice-to-have, not the
    /// codec name/sample rate/bit depth that make it legible at all.
    private static func formatInfo(from format: AVAudioFormat) -> AudioStreamDecoder.FormatInfo {
        let asbd = format.streamDescription.pointee
        return AudioStreamDecoder.FormatInfo(
            sampleRate: asbd.mSampleRate, channelCount: asbd.mChannelsPerFrame,
            bitsPerChannel: asbd.mBitsPerChannel > 0 ? asbd.mBitsPerChannel : nil,
            formatID: asbd.mFormatID, bitrate: nil
        )
    }

    /// Every write to `currentFormatSnapshot` for a newly-known format (as opposed to the
    /// `nil` reset at the top of `loadAndPlay`) goes through here, so hi-res session negotiation
    /// happens exactly once per track, right as its real format becomes known, rather than at
    /// every one of the three call sites separately.
    private func updateFormatSnapshot(_ info: AudioStreamDecoder.FormatInfo) {
        currentFormatSnapshot = info
        nowPlayingController.preferSampleRate(info.sampleRate)
    }

    private func elapsedFrames(of node: AVAudioPlayerNode) -> AVAudioFramePosition? {
        guard let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return playerTime.sampleTime
    }

    /// For the app's background/terminate hook: audio may keep playing in the background, so
    /// this is not the same as pausing.
    public func saveProgressForTeardown() {
        saveProgressNow()
    }

    private func saveProgressNow() {
        guard let track = currentTrack else { return }
        saveResumePoint(track: track, positionSecs: currentTime)
    }

    /// Records this container's resume point (on pause, stop and track change) as a
    /// whole-container fact: which track, and where in it.
    private func saveResumePoint(track: Track, positionSecs: Double) {
        guard let containerId = currentContainerId else { return }
        resumeStore?.saveResume(containerId: containerId, trackId: track.id, positionSecs: positionSecs)
    }

    // MARK: - Playback events

    private func openSpan(atPositionSecs positionSecs: Double) {
        guard let track = currentTrack else { return }
        onPlaybackStarted?(track, positionSecs)
    }

    private func closeSpan(atPositionSecs positionSecs: Double, reason: PlaybackStopReason = .seeked) {
        guard let track = currentTrack else { return }
        onPlaybackStopped?(track, positionSecs, reason)
    }

    // MARK: - Now Playing

    private func wireRemoteCommands() {
        nowPlayingController.onPlay = { [weak self] in self?.resumeAudioOnly() }
        nowPlayingController.onPause = { [weak self] in self?.pauseAudioOnly() }
        nowPlayingController.onSeek = { [weak self] time in Task { await self?.seek(to: time) } }
        nowPlayingController.onNextTrack = { [weak self] in self?.next() }
        nowPlayingController.onPreviousTrack = { [weak self] in self?.previous() }
    }

    private func pushNowPlayingInfo() {
        nowPlayingController.update(
            title: currentTrack?.title ?? "",
            artist: currentTrack?.artist,
            album: currentTrack?.album,
            duration: duration,
            elapsedTime: currentTime,
            rate: isPlaying ? 1 : 0,
            artwork: currentArtwork,
            hasNextTrack: hasNextTrack,
            hasPreviousTrack: hasPreviousTrack
        )
    }

    private func loadArtwork(track: Track) {
        artworkTask?.cancel()
        currentArtwork = nil
        guard let artworkProvider else { return }
        artworkTask = Task { [weak self] in
            guard let data = await artworkProvider(track),
                  let image = NowPlayingImage(data: data),
                  !Task.isCancelled
            else { return }
            self?.currentArtwork = image
            self?.pushNowPlayingInfo()
        }
    }
}

/// Why audio for a track stopped.
public enum PlaybackStopReason: Sendable {
    /// Played to its end.
    case completed
    /// The listener moved to another track in the queue.
    case skipped
    /// Paused or stopped.
    case stopped
    /// Something else was started in its place.
    case replaced
    /// The position jumped within the same track.
    case seeked
}
