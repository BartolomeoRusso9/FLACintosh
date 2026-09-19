import AppKit
import MediaPlayer
import Observation

/// What is playing, as macOS shows it outside the app: the Now Playing
/// module in Control Center and the menu bar, the lock screen, a paired
/// iPhone's or Apple Watch's remote — and the play/pause, next and previous
/// keys on the keyboard, which reach an app only through the same system.
///
/// Nothing here plays anything. It mirrors `PlaybackModel` into
/// `MPNowPlayingInfoCenter` and turns remote commands back into calls on it,
/// so the window and the system can never disagree about which is in charge.
///
/// The elapsed time is not pushed every tick. The system extrapolates it from
/// the last value and the playback rate, which is how Apple's own players do
/// it; it is only re-sent when that guess would be wrong — a pause, a seek,
/// a new track.
@MainActor
final class SystemNowPlaying {
    private weak var model: PlaybackModel?
    private var clock: Task<Void, Never>?

    /// What was last sent, to know whether the system's own extrapolation
    /// has drifted from the real position — a seek in the window, say.
    private var sentElapsed: TimeInterval = 0
    private var sentAt = Date.distantPast
    private var sentRate: Double = 0
    private var sentArtworkID: UUID?
    private var sentTrackKey: String?

    func attach(to model: PlaybackModel) {
        guard self.model == nil else { return }
        self.model = model
        registerCommands()
        observe()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.correctDrift()
            }
        }
    }

    // MARK: - Commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let model = self?.model, model.track != nil else { return .noActionableNowPlayingItem }
            if !model.isPlaying { model.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let model = self?.model, model.track != nil else { return .noActionableNowPlayingItem }
            if model.isPlaying { model.togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let model = self?.model, model.track != nil else { return .noActionableNowPlayingItem }
            model.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let model = self?.model, model.track != nil else { return .noActionableNowPlayingItem }
            model.advance(by: 1)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let model = self?.model, model.track != nil else { return .noActionableNowPlayingItem }
            model.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let model = self?.model,
                  let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            model.seek(to: event.positionTime)
            self?.publish()
            return .success
        }
    }

    // MARK: - Mirroring the model

    /// Re-publishes whenever something the system shows changes. Observation
    /// fires once per registration, so each change registers again.
    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.track
            _ = model.artwork
            _ = model.isPlaying
            _ = model.currentTrack
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publish()
                self?.observe()
            }
        }
        publish()
    }

    private func publish() {
        guard let model else { return }
        let center = MPNowPlayingInfoCenter.default()

        guard let track = model.track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            sentTrackKey = nil
            sentArtworkID = nil
            return
        }

        var info = center.nowPlayingInfo ?? [:]
        let key = "\(track.title)|\(track.artist)|\(track.album)"
        if key != sentTrackKey {
            // A new track: nothing of the old one may linger, cover included.
            info = [:]
            sentTrackKey = key
            sentArtworkID = nil
        }

        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        info[MPMediaItemPropertyAlbumTitle] = track.album
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        if let duration = track.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let position = model.queueIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = position
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = model.queue.count
        }

        if let artwork = model.artwork, artwork.id != sentArtworkID,
           let image = NSImage(data: artwork.data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            sentArtworkID = artwork.id
        } else if model.artwork == nil {
            info[MPMediaItemPropertyArtwork] = nil
        }

        let elapsed = model.currentTime
        let rate: Double = model.isPlaying ? 1 : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1

        center.nowPlayingInfo = info
        center.playbackState = model.isPlaying ? .playing : .paused

        sentElapsed = elapsed
        sentAt = .now
        sentRate = rate
    }

    /// Where the system thinks playback is, against where it really is.
    /// More than a second and a half apart — a seek, a stall while a stream
    /// buffered — and the real position is sent again.
    private func correctDrift() {
        guard let model, model.track != nil else { return }
        let expected = sentElapsed + Date.now.timeIntervalSince(sentAt) * sentRate
        if abs(model.currentTime - expected) > 1.5 {
            publish()
        }
    }
}
