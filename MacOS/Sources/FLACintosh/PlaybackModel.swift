import AVFoundation
import Foundation
import Observation
import SFBAudioEngine
import SyncedLyrics

/// What the bar under the artwork shows.
///
/// Sample rate and bit depth are read straight off the decoder rather than
/// guessed from the extension: a `.m4a` is ALAC or AAC depending on what is
/// inside it, and the whole point of a player like this is to say which.
struct TrackInfo: Sendable {
    var title: String
    var artist: String
    var album: String
    var sampleRate: Double?
    var bitDepth: Int?
    var channelCount: UInt32?
    var duration: TimeInterval?

    /// "24 bit · 96 kHz · Stereo", with the parts it actually knows.
    var formatSummary: String {
        var parts: [String] = []
        if let bitDepth { parts.append("\(bitDepth) bit") }
        if let sampleRate {
            let kHz = sampleRate / 1000
            parts.append(
                kHz == kHz.rounded()
                    ? String(format: "%.0f kHz", kHz)
                    : String(format: "%.1f kHz", kHz)
            )
        }
        switch channelCount {
        case 1: parts.append("Mono")
        case 2: parts.append("Stereo")
        case let count?: parts.append("\(count) ch")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class PlaybackModel {
    var track: TrackInfo?
    var artwork: Artwork?
    var lyrics: TimedLyrics? {
        didSet { updateLyricLine() }
    }
    var lyricsSource: String?
    var lastError: String?

    /// What the "find lyrics" button is doing.
    var lyricsSearch: LyricsSearchState = .idle

    enum LyricsSearchState: Equatable {
        case idle
        case searching
        case failed(String)
    }

    /// The clock the *interface* runs on: the elapsed readout, the scrubber.
    /// Deliberately coarse — see `tickInterval`.
    ///
    /// It changes thirty times a second, so anything that reads it redraws
    /// thirty times a second. Only small views should: a whole screen that
    /// reads it rebuilds everything in it on every tick, and that work lands
    /// on the same main thread the lyric sweep is animating on.
    var displayTime: TimeInterval = 0 {
        didSet { updateLyricLine() }
    }

    /// A Spotify Canvas for the track: the short looping clip SpotiFLAC saves
    /// beside the audio with `--save-canvas`, same name, video extension.
    /// Local files only — a server does not hand over the files next to a
    /// track, only the track.
    var canvas: URL?

    /// What SpotiFLAC writes (`core/canvas.py`), minus `.webm`, which
    /// AVFoundation cannot play.
    nonisolated private static let canvasExtensions = ["mp4", "m4v", "mov"]

    nonisolated static func canvas(beside audio: URL) -> URL? {
        guard audio.isFileURL else { return nil }
        let stem = audio.deletingPathExtension()
        return canvasExtensions
            .map { stem.appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The lyric line being sung, published only when it changes — a few
    /// times a minute rather than on every tick. What the lyrics view follows,
    /// instead of working it out from `displayTime` and redrawing with it.
    private(set) var lyricLineIndex: Int?

    private func updateLyricLine() {
        let line = lyrics?.lineIndex(at: displayTime)
        // Observation notifies on every assignment, equal or not.
        if line != lyricLineIndex { lyricLineIndex = line }
    }
    var isPlaying = false

    // MARK: Queue

    /// What is lined up, in the order it was handed over. Shuffle reorders a
    /// *copy* of the indices rather than the queue itself, so turning it off
    /// puts the record back the way the artist sequenced it.
    private(set) var queue: [LibraryTrack] = []
    var queueIndex: Int?
    var isShuffling = false {
        didSet {
            guard oldValue != isShuffling else { return }
            rebuildOrder()
            // Turned on mid-record, the song playing goes to the front of
            // the new order. Left wherever the shuffle put it, everything
            // shuffled in ahead of it would never play, and a queue of forty
            // could end after three.
            if isShuffling, let queueIndex, let position = order.firstIndex(of: queueIndex) {
                order.swapAt(0, position)
            }
            refreshGapless()
        }
    }
    var repeatMode: RepeatMode = .off {
        didSet { if oldValue != repeatMode { refreshGapless() } }
    }

    /// Keep going when the queue runs out, instead of stopping.
    ///
    /// Apple Music picks what it thinks you would like next; with a folder of
    /// files there is nothing to base that on, so this takes the rest of the
    /// library in a random order. Same promise — the music does not stop —
    /// without pretending to a taste it does not have.
    var autoPlay = UserDefaults.standard.bool(forKey: "autoPlay") {
        didSet { UserDefaults.standard.set(autoPlay, forKey: "autoPlay") }
    }

    /// Where that continuation comes from. Set by the library, which is the
    /// only thing that knows what else there is to play.
    @ObservationIgnored var moreToPlay: (() -> [LibraryTrack])?

    /// Start the next record before this one has finished, and cross the two
    /// volumes over.
    var crossfade = UserDefaults.standard.bool(forKey: "crossfade") {
        didSet {
            UserDefaults.standard.set(crossfade, forKey: "crossfade")
            refreshGapless()
        }
    }

    /// Apple Music's own default. Long enough to be a blend rather than a
    /// cut, short enough not to eat the end of a song.
    static let crossfadeDuration: TimeInterval = 6

    /// A fade in progress: when it began, and the deck being faded out.
    struct Fade {
        var startedAt: Date
        var outgoing: AudioPlayer
    }

    @ObservationIgnored var fade: Fade?

    enum RepeatMode: CaseIterable {
        case off, all, one

        var symbol: String { self == .one ? "repeat.1" : "repeat" }
        var next: RepeatMode {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }
    }

    /// Positions into `queue`, in playing order.
    @ObservationIgnored var order: [Int] = []
    @ObservationIgnored var wasPlaying = false

    /// What was asked for — a local file, or a stream on a server. Lyrics
    /// are keyed on this, so they survive the cache being emptied.
    @ObservationIgnored var currentURL: URL?

    /// A remote track is not audible yet: the stream is filling, or — for a
    /// format AVFoundation cannot decode — the whole file is being fetched.
    var isBuffering = false

    var currentTrack: LibraryTrack? {
        guard let queueIndex, queue.indices.contains(queueIndex) else { return nil }
        return queue[queueIndex]
    }

    // Two engines, not one. A crossfade is two records audible at the same
    // time, and one `AudioPlayer` plays one file: the second deck is the
    // only way to overlap them. Off a fade the idle one sits silent and
    // costs nothing.
    @ObservationIgnored let deckA = AudioPlayer()
    @ObservationIgnored let deckB = AudioPlayer()
    @ObservationIgnored var liveIsA = true

    /// Server tracks, streamed. SFBAudioEngine only opens local files, and
    /// fetching a whole FLAC before the first note is a wait of seconds on a
    /// LAN and far longer off it. AVPlayer reads over HTTP with byte ranges,
    /// so a track starts almost at once and seeking does not need the rest.
    @ObservationIgnored let stream = AVPlayer()
    @ObservationIgnored var isStreaming = false

    /// The deck the interface is about: the one whose track is showing, whose
    /// clock the scrubber follows. During a fade it is already the *incoming*
    /// record — the outgoing one is only a sound finishing behind it.
    var player: AudioPlayer { liveIsA ? deckA : deckB }

    // MARK: Cast

    @ObservationIgnored let cast = CastController()

    // MARK: Effects, gapless, offline

    @ObservationIgnored var effects: AudioEffects?
    @ObservationIgnored var deckEffects: [DeckEffects] = []
    @ObservationIgnored var streamEffects: StreamEffects?
    /// The playing file's ReplayGain tags, once read.
    @ObservationIgnored var currentReplayGain: ReplayGainInfo?
    /// The file queued behind the current one on the live deck.
    @ObservationIgnored var pendingGapless: (index: Int, file: URL, origin: URL)?
    /// A downloaded copy of a server track, when there is one.
    @ObservationIgnored var localCopy: ((URL) -> URL?)?
    /// Where to start when play is pressed after casting ended — nothing is
    /// loaded on this Mac until then.
    @ObservationIgnored var pendingLocalResume: TimeInterval?
    /// The slider's level on this Mac, put back when casting ends: while
    /// casting the slider is the device's volume.
    @ObservationIgnored var localVolume: Double?
    @ObservationIgnored var adoptingCastVolume = false
    @ObservationIgnored var castViaMac = false
    @ObservationIgnored var castRetried = false

    /// Stops both local players without touching the queue or the display.
    func silenceLocalPlayback() {
        cancelFade()
        deckA.stop()
        deckB.stop()
        stopStream()
    }

    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Bumped by every `open`, so a slow tag parse cannot land on the track
    /// that replaced it.
    @ObservationIgnored var generation = 0

    /// The interface clock ticks; it is not read every frame.
    ///
    /// Publishing the time at the display's own rate is what froze this app:
    /// every observer of it — header, transport, and *every* lyric line —
    /// rebuilt 120 times a second, and the main thread had nothing left for
    /// input. Only one thing on screen genuinely needs per-frame precision
    /// (the syllable sweep on the line being sung), and it reads
    /// `currentTime` directly inside its own `TimelineView` instead.
    private static let tickInterval = Duration.milliseconds(33)
    private static let idleTickInterval = Duration.milliseconds(250)

    /// Live, unobserved, straight off the decoder — for the syllable sweep.
    ///
    /// Reading this does *not* register an observation dependency, which is
    /// the point: a `TimelineView` already asks for it once per frame, and a
    /// change notification on top of that would invalidate the whole window.
    var currentTime: TimeInterval {
        if cast.isActive { return cast.estimatedTime }
        if isStreaming {
            let time = stream.currentTime().seconds
            return time.isFinite ? time : displayTime
        }
        return player.currentTime ?? displayTime
    }

    // MARK: - Queue control

    func play(_ tracks: [LibraryTrack], startingAt index: Int) {
        cancelFade()
        queue = tracks
        rebuildOrder()
        // Whatever was asked for plays first, even with shuffle on — the
        // alternative is clicking a song and hearing a different one.
        if let position = order.firstIndex(of: index) {
            order.swapAt(0, position)
        }
        start(at: index)
    }

    func advance(by offset: Int) {
        cancelFade()
        guard let queueIndex, let position = order.firstIndex(of: queueIndex) else { return }
        let next = position + offset
        if order.indices.contains(next) {
            start(at: order[next])
        } else if repeatMode == .all, let wrapped = offset > 0 ? order.first : order.last {
            start(at: wrapped)
        } else if offset > 0, autoPlay, let more = moreToPlay?(), !more.isEmpty {
            // Forwards only: running off the *front* of the queue is someone
            // pressing previous on the first track, and answering that with a
            // random record would be startling.
            play(more, startingAt: 0)
        } else {
            // Off the end of the queue: stop where the music stopped rather
            // than silently restarting the record.
            _ = player.pause()
            stream.pause()
            if cast.isActive { cast.pause() }
            isPlaying = false
        }
    }

    private func start(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queueIndex = index
        open(queue[index].url)
    }

    /// Positions in `queue` still ahead, in playing order — shuffled when
    /// shuffle is on, which is the order the list has to show.
    var upNextIndices: [Int] {
        guard let queueIndex, let position = order.firstIndex(of: queueIndex) else { return [] }
        return order[(position + 1)...].filter { queue.indices.contains($0) }
    }

    /// What is still ahead, in playing order — the part of the queue the
    /// list shows and "Clear" throws away.
    var upNext: [LibraryTrack] {
        upNextIndices.map { queue[$0] }
    }

    /// Plays a track that is already queued, keeping the order as it is.
    /// Handing the queue to `play` again would reshuffle it.
    func jump(to index: Int) {
        cancelFade()
        start(at: index)
    }

    /// Drops everything after the current track.
    ///
    /// The record on now keeps playing: "clear" is about the list of what
    /// comes next, not about the needle.
    func clearQueue() {
        guard let queueIndex, queue.indices.contains(queueIndex) else {
            queue = []
            order = []
            self.queueIndex = nil
            return
        }
        queue = [queue[queueIndex]]
        self.queueIndex = 0
        rebuildOrder()
        refreshGapless()
    }

    // MARK: - Crossfade

    /// The record after this one, if the queue has one to give.
    var followingIndex: Int? {
        guard let queueIndex, let position = order.firstIndex(of: queueIndex) else { return nil }
        if order.indices.contains(position + 1) { return order[position + 1] }
        if repeatMode == .all { return order.first }
        return nil
    }

    /// Starts the next record on the idle deck and hands the interface to it.
    ///
    /// The swap happens up front, not at the end of the ramp: from the moment
    /// the new song is audible it is the one you are listening to, so it
    /// should be the one whose title, sleeve and lyrics are on screen. What
    /// is left on the old deck is a sound finishing, not a track playing.
    private func beginCrossfade() {
        guard let next = followingIndex, queue.indices.contains(next) else { return }
        // Local files only: a server track has to be fetched before it can
        // play, and a fade cannot wait on a download.
        guard playableFile(for: queue[next].url) != nil else { return }

        fade = Fade(startedAt: .now, outgoing: player)
        liveIsA.toggle()
        start(at: next)
    }

    /// One step of the ramp, driven by the interface clock that is already
    /// running — 33ms while playing, so about thirty steps a second.
    private func stepFade() {
        guard let fade else { return }
        let progress = min(max(Date.now.timeIntervalSince(fade.startedAt) / Self.crossfadeDuration, 0), 1)
        try? fade.outgoing.setDeckVolume(Float(volume * (1 - progress)))
        try? player.setDeckVolume(Float(volume * progress))
        guard progress >= 1 else { return }
        fade.outgoing.stop()
        self.fade = nil
        try? player.setDeckVolume(Float(volume))
    }

    /// Ends a fade early, leaving the incoming record at full volume.
    func cancelFade() {
        guard let fade else { return }
        fade.outgoing.stop()
        self.fade = nil
        try? player.setDeckVolume(Float(volume))
    }

    private func rebuildOrder() {
        order = Array(queue.indices)
        if isShuffling { order.shuffle() }
    }

    /// Plays one file with no queue behind it — a drop, or ⌘O.
    func openStandalone(_ url: URL) {
        cancelFade()
        queue = []
        order = []
        queueIndex = nil
        open(url)
    }

    func open(_ url: URL) {
        currentURL = url
        generation += 1
        let generation = generation
        canvas = Self.canvas(beside: url)
        pendingLocalResume = nil

        if cast.isActive {
            castOpen(url, generation: generation)
            return
        }

        // Downloaded for offline listening: the file, not the stream — it
        // plays without the server, gaplessly, through the equalizer graph.
        if !url.isFileURL, let local = localCopy?(url) {
            stopStream()
            play(local, describing: url)
            return
        }

        guard url.isFileURL else {
            startStream(url, generation: generation)
            return
        }

        stopStream()
        play(url, describing: url)
    }

    // MARK: - Streaming

    /// Plays a server track over HTTP, without fetching it first.
    ///
    /// The bar is filled in straight away from what the library already
    /// knows — title, artist, album, length — because there are no tags to
    /// read until the bytes arrive, and an empty bar over a song that is
    /// already playing looks broken.
    private func startStream(_ url: URL, generation: Int) {
        cancelFade()
        player.stop()
        isStreaming = true
        lastError = nil
        lyricsSearch = .idle

        let listed = currentTrack?.url == url ? currentTrack : nil
        track = TrackInfo(
            title: listed?.title ?? url.lastPathComponent,
            artist: listed?.artist ?? "",
            album: listed?.album ?? "",
            duration: listed?.duration
        )
        artwork = nil
        (lyrics, lyricsSource) = Self.loadLyrics(for: url, embedded: nil)

        displayTime = 0
        isBuffering = true
        let item = AVPlayerItem(url: url)
        let tap = StreamEffects()
        streamEffects = tap
        currentReplayGain = nil
        applyEffects()
        tap.attach(to: item)
        stream.replaceCurrentItem(with: item)
        stream.volume = Float(volume)
        stream.play()
        isPlaying = true
        wasPlaying = false
        startTicker()

        loadRemoteDetails(for: url, listed: listed, generation: generation)
    }

    /// What a server track's file says about itself, fetched alongside
    /// playback: the sleeve, the format, embedded lyrics.
    func loadRemoteDetails(for url: URL, listed: LibraryTrack?, generation: Int) {
        // The server's copy of the sleeve first, because it is small and
        // quick; the file's own, from its header, replaces it if it has one.
        if let cover = listed?.artworkURL?.requestingImageSize(1000) {
            Task {
                guard let fetched = try? await URLSession.shared.data(from: cover),
                      (fetched.1 as? HTTPURLResponse)?.statusCode == 200
                else { return }
                let data = fetched.0
                let art = await Task.detached(priority: .userInitiated) { Artwork.make(from: data) }.value
                guard generation == self.generation, self.artwork == nil else { return }
                self.artwork = art
            }
        }

        // Then what the file itself says: format, embedded lyrics, full-size
        // cover. Read off the start of the file only, while the stream plays.
        Task {
            guard let header = try? await RemoteCache.header(for: url) else { return }
            let loaded = await Self.read(header, lyricsFor: url)
            // Not kept if it cannot be read: a cached header is never fetched
            // again, so a bad one would hide this track's tags for good.
            guard loaded.error == nil else {
                try? FileManager.default.removeItem(at: header)
                return
            }
            guard generation == self.generation, self.isStreaming || self.cast.isActive, let tags = loaded.track else { return }

            // The library's names stay: a tag-less file would otherwise be
            // titled after its cache fingerprint.
            var info = self.track ?? tags
            info.sampleRate = tags.sampleRate.flatMap { $0 > 0 ? $0 : nil }
            info.bitDepth = tags.bitDepth.flatMap { $0 > 0 ? $0 : nil }
            info.channelCount = tags.channelCount.flatMap { $0 > 0 ? $0 : nil }
            if info.duration == nil, let duration = tags.duration, duration > 0 {
                info.duration = duration
            }
            self.track = info
            if let art = loaded.artwork { self.artwork = art }
            self.currentReplayGain = loaded.replayGain
            self.applyEffects()
            if let lyrics = loaded.lyrics {
                self.lyrics = lyrics
                self.lyricsSource = loaded.lyricsSource
            }
        }
    }

    func stopStream() {
        guard isStreaming else { return }
        isStreaming = false
        isBuffering = false
        stream.pause()
        stream.replaceCurrentItem(with: nil)
    }

    /// The old way, kept for what AVFoundation will not decode — Opus,
    /// Vorbis, and whatever else a server might send untranscoded: fetch the
    /// file whole, then hand it to SFBAudioEngine like any local track.
    private func download(_ url: URL) {
        let generation = generation
        isBuffering = true
        Task {
            do {
                let local = try await RemoteCache.file(for: url)
                guard generation == self.generation else { return }
                self.isBuffering = false
                self.play(local, describing: url)
            } catch {
                guard generation == self.generation else { return }
                self.isBuffering = false
                self.lastError = error.localizedDescription
            }
        }
    }

    private func tickStream() {
        guard let item = stream.currentItem, let url = currentURL else { return }

        if item.status == .failed {
            stopStream()
            download(url)
            return
        }

        let time = item.currentTime().seconds
        if time.isFinite, time != displayTime { displayTime = time }
        if track?.duration == nil, item.duration.isNumeric {
            track?.duration = item.duration.seconds
        }
        let buffering = stream.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if buffering != isBuffering { isBuffering = buffering }
        // `rate`, not `timeControlStatus`: it is non-zero while the stream is
        // still filling, and a pause button that flickers to play every time
        // the network hiccups is wrong about what the player intends.
        if isPlaying != (stream.rate != 0) { isPlaying = stream.rate != 0 }

        // AVPlayer pauses itself at the end of an item. Polled here for the
        // same reason the local decks are: this clock is already running.
        let duration = item.duration.isNumeric ? item.duration.seconds : (track?.duration ?? 0)
        if wasPlaying, stream.rate == 0, duration > 0, time >= duration - 0.3 {
            wasPlaying = false
            if repeatMode == .one, let queueIndex {
                start(at: queueIndex)
            } else {
                advance(by: 1)
            }
            return
        }
        if isPlaying { wasPlaying = true }
    }

    /// `file` is what the engine plays; `origin` is what the track *is* —
    /// the same thing for a local library, a stream URL for a server.
    func play(_ file: URL, describing origin: URL) {
        // Audio first: it is the part with a perceptible delay, and it needs
        // nothing from the tag reader.
        do {
            try player.play(file)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            track = nil
            artwork = nil
            lyrics = nil
            lyricsSource = nil
            return
        }

        // The engine is rebuilt for each file, so the volume goes back on —
        // silent if this file is the incoming half of a crossfade, since the
        // ramp is about to raise it.
        try? player.setDeckVolume(Float(fade == nil ? volume : 0))
        currentReplayGain = nil
        applyEffects()
        displayTime = 0
        isPlaying = player.playbackState == .playing
        wasPlaying = isPlaying
        startTicker()

        // Metadata is a full parse of the file's tags — artwork included —
        // so it happens off the main thread. Blocking here is a stutter on
        // small files and a visible hang on a FLAC with a big cover.
        track = nil
        artwork = nil
        lyrics = nil
        lyricsSource = nil
        lyricsSearch = .idle
        // Here as well as in `open`: a crossfade starts the next file
        // without going through it.
        canvas = Self.canvas(beside: origin)
        generation += 1
        let generation = generation
        Task {
            let loaded = await Self.read(file, lyricsFor: origin)
            // A later `open` may have won the race while we were parsing.
            guard generation == self.generation else { return }
            self.track = loaded.track
            self.artwork = loaded.artwork
            self.lyrics = loaded.lyrics
            self.lyricsSource = loaded.lyricsSource
            self.currentReplayGain = loaded.replayGain
            self.applyEffects()
            if let message = loaded.error, self.lastError == nil {
                self.lastError = message
            }
        }
        prepareGapless()
    }

    /// Identity for the cover cache: the artwork's own id, so the mini
    /// player does not re-decode the same sleeve on every tick.
    var artworkID: String { artwork?.id.uuidString ?? "none" }

    /// Held here rather than read back from the engine: the engine reports
    /// NaN whenever it is not running, and a slider bound to NaN is a crash
    /// waiting for the first paused track.
    var volume: Double = 1 {
        didSet {
            // Not while a fade is running: it is mid-ramp on both decks, and
            // slamming the live one to full would cut the crossing short.
            // The next step picks the new level up on its own.
            if cast.isActive {
                if !adoptingCastVolume { cast.setVolume(volume) }
                return
            }
            stream.volume = Float(volume)
            guard fade == nil else { return }
            try? player.setDeckVolume(Float(volume))
        }
    }

    func togglePlayPause() {
        if cast.isActive {
            if cast.playerState == "IDLE", !isBuffering, let url = currentURL {
                // The track ended on the device, or never started: play it
                // again rather than send a PLAY with nothing loaded.
                generation += 1
                castOpen(url, generation: generation)
            } else if cast.isPlaying {
                cast.pause()
                isPlaying = false
            } else {
                cast.play()
                isPlaying = true
            }
            return
        }
        if let time = pendingLocalResume {
            resumeLocally(at: time, playing: true)
            return
        }
        if isStreaming {
            if stream.rate == 0 { stream.play() } else { stream.pause() }
            isPlaying = stream.rate != 0
            return
        }
        // Pressing pause mid-fade ends the fade: the outgoing record stops
        // and the incoming one holds where it is. Trying to pause both and
        // resume the ramp later would mean the fade needed its own clock,
        // and "pause" already means silence either way.
        cancelFade()
        try? player.togglePlayPause()
        isPlaying = player.playbackState == .playing
        startTicker()
    }

    /// Back to the start of the track first, the way every player does it —
    /// the previous song is only one press away once you are near the top.
    func previous() {
        if displayTime > 3 {
            seek(to: 0)
        } else {
            advance(by: -1)
        }
    }

    func seek(to time: TimeInterval) {
        if cast.isActive {
            cast.seek(to: time)
            displayTime = time
            return
        }
        if pendingLocalResume != nil {
            pendingLocalResume = time
            displayTime = time
            return
        }
        cancelFade()
        if isStreaming {
            stream.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        } else {
            _ = player.seek(time: time)
        }
        // Move the interface immediately rather than at the next tick: a
        // scrubber that lags its own thumb feels broken.
        displayTime = time
    }

    // MARK: - The interface clock

    func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = self?.isPlaying == true ? Self.tickInterval : Self.idleTickInterval
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        if cast.isActive {
            tickCast()
            return
        }
        if isStreaming {
            tickStream()
            return
        }
        // Only assigned when different: Observation notifies on every set,
        // equal or not, and this runs four times a second even while paused
        // — each redundant write re-evaluated every view that reads it.
        let playing = player.playbackState == .playing
        if playing != isPlaying { isPlaying = playing }
        // `currentTime` goes nil when the last decoder is done. Holding the
        // final value keeps the lyrics on the closing line instead of
        // snapping back to the top of the song.
        if let time = player.currentTime, time != displayTime {
            displayTime = time
        }

        if fade != nil {
            stepFade()
        } else if crossfade, isPlaying,
                  let duration = track?.duration, duration > Self.crossfadeDuration,
                  duration - displayTime <= Self.crossfadeDuration {
            beginCrossfade()
        }

        // End of track, noticed by polling rather than by the player's
        // delegate: the delegate arrives on an unspecified queue, and this
        // clock is already running. The cost is up to a quarter-second of
        // silence between songs, which is the idle tick interval.
        if wasPlaying, !isPlaying, player.playbackState == .stopped {
            wasPlaying = false
            if repeatMode == .one, let queueIndex {
                start(at: queueIndex)
            } else {
                advance(by: 1)
            }
        }
        if isPlaying { wasPlaying = true }
    }

    // MARK: - Loading

    struct Loaded: Sendable {
        var track: TrackInfo?
        var artwork: Artwork?
        var lyrics: TimedLyrics?
        var lyricsSource: String?
        var error: String?
        var replayGain: ReplayGainInfo?
    }

    nonisolated static func read(_ url: URL, lyricsFor origin: URL) async -> Loaded {
        await Task.detached(priority: .userInitiated) {
            do {
                let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
                let properties = file.properties
                let metadata = file.metadata

                let track = TrackInfo(
                    title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
                    artist: metadata.artist ?? "",
                    album: metadata.albumTitle ?? "",
                    sampleRate: properties.sampleRate,
                    bitDepth: properties.bitDepth,
                    channelCount: properties.channelCount,
                    duration: properties.duration
                )

                let (parsed, source) = loadLyrics(for: origin, embedded: metadata.lyrics)
                return Loaded(
                    track: track,
                    artwork: cover(in: metadata),
                    lyrics: parsed,
                    lyricsSource: source,
                    replayGain: ReplayGainInfo(metadata)
                )
            } catch {
                // Playback already started, so this is not fatal: the file
                // plays, we just cannot name it.
                let (parsed, source) = loadLyrics(for: origin, embedded: nil)
                return Loaded(
                    track: TrackInfo(
                        title: url.deletingPathExtension().lastPathComponent,
                        artist: "",
                        album: ""
                    ),
                    lyrics: parsed,
                    lyricsSource: source,
                    error: error.localizedDescription
                )
            }
        }.value
    }

    // MARK: - Finding lyrics

    /// Go and look for lyrics this file does not have.
    ///
    /// What comes back is written as an `.lrc` sidecar next to the audio,
    /// which is where the app looks first anyway — so the result survives a
    /// restart, can be corrected by hand, and is picked up by anything else
    /// that reads sidecars. A read-only folder falls back to a cache.
    func findLyrics() {
        guard let track, let url = currentURL, lyricsSearch != .searching else { return }
        lyricsSearch = .searching

        let query = LyricsQuery(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration ?? 0
        )
        let generation = generation

        Task {
            let result = await LyricsSidecar.fetch(
                title: query.title,
                artist: query.artist,
                album: query.album,
                duration: query.duration,
                for: url
            )
            guard generation == self.generation else { return }

            switch result {
            case .success(let source):
                // Re-read rather than keep what was fetched: the sidecar is
                // now the file's lyrics, and this is the same path a restart
                // would take.
                let (parsed, found) = Self.loadLyrics(for: url, embedded: nil)
                self.lyrics = parsed
                self.lyricsSource = found ?? source
                self.lyricsSearch = .idle
            case .failure(let failure):
                self.lyricsSearch = .failed(failure.message)
            }
        }
    }

    // MARK: - Lyrics

    /// The sidecar wins over the tag.
    ///
    /// Both usually exist and hold the same text — SpotiFLAC's `--save-lrc`
    /// writes the file out of the tag it just embedded — but the file is the
    /// one a person can fix by hand, so it takes precedence.
    nonisolated static func loadLyrics(
        for url: URL,
        embedded: String?
    ) -> (TimedLyrics?, String?) {
        // Only for a real file: `String(contentsOf:)` on an http URL would
        // go and ask the server for a `.lrc` that does not exist.
        if url.isFileURL {
            let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
            if let text = try? String(contentsOf: sidecar, encoding: .utf8) {
                let parsed = EnhancedLRC.parse(text)
                if !parsed.isEmpty { return (parsed, sidecar.lastPathComponent) }
            }
        }
        if let embedded {
            let parsed = EnhancedLRC.parse(embedded)
            if !parsed.isEmpty { return (parsed, "embedded tag") }
        }
        // Last: lyrics this app went and found for a file it could not write
        // next to. The file's own tag still outranks them.
        if let cached = LyricsSidecar.cacheURL(for: url),
           let text = try? String(contentsOf: cached, encoding: .utf8) {
            let parsed = EnhancedLRC.parse(text)
            if !parsed.isEmpty { return (parsed, "fetched (cached)") }
        }
        return (nil, nil)
    }
}

// MARK: - Cover art

extension PlaybackModel {
    /// The front cover if the file names one, otherwise whatever picture it
    /// carries. Tags are inconsistent about the type — plenty of files store
    /// a perfectly good sleeve as "other".
    nonisolated fileprivate static func cover(in metadata: AudioMetadata) -> Artwork? {
        let pictures = metadata.attachedPictures
        let chosen = pictures.first { $0.type == .frontCover } ?? pictures.first
        guard let data = chosen?.imageData else { return nil }
        return Artwork.make(from: data)
    }
}
