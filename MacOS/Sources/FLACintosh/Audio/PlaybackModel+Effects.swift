import Foundation
import SFBAudioEngine

/// The equalizer and ReplayGain on both players, gapless playback, and
/// downloaded copies of server tracks.
extension PlaybackModel {
    func attachEffects(_ effects: AudioEffects) {
        guard self.effects == nil else { return }
        self.effects = effects
        deckEffects = [deckA, deckB].map { deck in
            let fx = DeckEffects(player: deck)
            fx.onNowPlayingChanged = { [weak self, weak deck] url in
                guard let self, let deck else { return }
                self.nowPlayingChanged(on: deck, url: url)
            }
            return fx
        }
        effects.onChange = { [weak self] in
            self?.applyEffects()
            self?.refreshGapless()
        }
        applyEffects()
    }

    /// The equalizer curve and the overall gain — ReplayGain for the track
    /// playing, less the equalizer's headroom — on every player.
    func applyEffects() {
        guard let effects else { return }
        let replayGain = currentReplayGain?.gain(for: effects.replayGain, preamp: effects.replayGainPreamp) ?? 0
        let gain = replayGain + effects.equalizerHeadroom
        for deck in deckEffects {
            deck.apply(enabled: effects.equalizerOn, gains: effects.gains, gain: gain)
        }
        streamEffects?.apply(enabled: effects.equalizerOn, gains: effects.gains, gain: gain)
    }

    /// What the local engine can play for a queued track: the file itself,
    /// or a server track's downloaded copy.
    func playableFile(for url: URL) -> URL? {
        url.isFileURL ? url : localCopy?(url)
    }

    // MARK: - Gapless

    /// Queues the next track on the live deck, so it starts on the very
    /// sample the current one ends — no gap on a live album or a DJ mix.
    ///
    /// Only between files the local engine plays (local tracks and
    /// downloaded ones); a stream has to buffer and cannot be joined
    /// seamlessly. Crossfade, when on, takes over the transition instead.
    func prepareGapless() {
        pendingGapless = nil
        guard let effects, effects.gapless, !crossfade, fade == nil,
              !cast.isActive, !isStreaming, repeatMode != .one,
              player.playbackState != .stopped,
              let next = followingIndex, next != queueIndex, queue.indices.contains(next),
              let file = playableFile(for: queue[next].url)
        else { return }
        do {
            try player.enqueue(file)
            pendingGapless = (next, file, queue[next].url)
        } catch {
            pendingGapless = nil
        }
    }

    /// The queue or the rules changed: what was lined up may no longer be
    /// what comes next.
    func refreshGapless() {
        guard !isStreaming, !cast.isActive else { return }
        if pendingGapless != nil { player.clearQueue() }
        prepareGapless()
    }

    /// The live deck moved on to the file queued behind the last one.
    private func nowPlayingChanged(on deck: AudioPlayer, url: URL?) {
        guard deck === player, let pending = pendingGapless, let url,
              url.standardizedFileURL == pending.file.standardizedFileURL
        else { return }
        pendingGapless = nil

        queueIndex = pending.index
        currentURL = pending.origin
        pendingLocalResume = nil
        generation += 1
        let generation = generation
        canvas = Self.canvas(beside: pending.origin)
        displayTime = 0
        wasPlaying = true
        lyricsSearch = .idle
        lastError = nil
        currentReplayGain = nil
        applyEffects()

        let file = pending.file
        let origin = pending.origin
        Task {
            let loaded = await Self.read(file, lyricsFor: origin)
            guard generation == self.generation else { return }
            self.track = loaded.track
            self.artwork = loaded.artwork
            self.lyrics = loaded.lyrics
            self.lyricsSource = loaded.lyricsSource
            self.currentReplayGain = loaded.replayGain
            self.applyEffects()
        }
        prepareGapless()
    }
}
