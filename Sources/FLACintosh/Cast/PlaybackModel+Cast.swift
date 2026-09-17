import Foundation

/// Playing on a Cast device instead of this Mac.
///
/// While a device is connected the local decks stay silent and every
/// transport call goes to the receiver; the queue, lyrics and Now Playing
/// carry on here as before, following the receiver's clock.
extension PlaybackModel {
    func startCasting(to device: CastController.Device) {
        wireCast()
        guard cast.activeDevice?.id != device.id else { return }
        let resumeAt = cast.isActive ? cast.estimatedTime : (pendingLocalResume ?? displayTime)
        let resume = isPlaying
        if !cast.isActive { localVolume = volume }

        Task {
            do {
                try await cast.connect(to: device)
            } catch {
                lastError = "Could not connect to \(device.name): \(error.localizedDescription)"
                return
            }
            lastError = nil
            if let level = cast.volume {
                adoptingCastVolume = true
                volume = level
                adoptingCastVolume = false
            }
            guard let url = currentURL, track != nil || isBuffering else { return }
            generation += 1
            castOpen(url, generation: generation, startAt: resumeAt, autoplay: resume)
        }
    }

    /// Back to this Mac, from where the device had got to.
    func stopCasting() {
        guard cast.isActive else { return }
        let at = cast.estimatedTime
        let resume = isPlaying
        cast.disconnect()
        endCastSession()
        if resume {
            resumeLocally(at: at, playing: true)
        } else {
            holdForLocalResume(at: at)
        }
    }

    // MARK: - Internals

    func wireCast() {
        cast.startDiscovery()
        guard cast.onFinished == nil else { return }

        cast.onFinished = { [weak self] in
            guard let self else { return }
            if repeatMode == .one, let queueIndex = self.queueIndex {
                jump(to: queueIndex)
            } else {
                advance(by: 1)
            }
        }
        cast.onMediaError = { [weak self] message in
            guard let self, let url = currentURL else { return }
            if !castViaMac, !castRetried {
                // It took the URL and then could not decode what came down
                // it. Once more, converted here.
                castRetried = true
                let at = cast.estimatedTime
                generation += 1
                castOpen(url, generation: generation, startAt: at, autoplay: true, viaMac: true)
            } else {
                isBuffering = false
                isPlaying = false
                lastError = message
            }
        }
        cast.onSessionEnded = { [weak self] message in
            guard let self else { return }
            let at = displayTime
            endCastSession()
            holdForLocalResume(at: at)
            lastError = message
        }
    }

    func castOpen(
        _ url: URL,
        generation: Int,
        startAt: TimeInterval = 0,
        autoplay: Bool = true,
        viaMac: Bool = false
    ) {
        silenceLocalPlayback()
        lastError = nil
        lyricsSearch = .idle
        if !viaMac { castRetried = false }
        castViaMac = viaMac

        let listed = currentTrack?.url == url ? currentTrack : nil
        track = TrackInfo(
            title: listed?.title ?? url.deletingPathExtension().lastPathComponent,
            artist: listed?.artist ?? "",
            album: listed?.album ?? "",
            duration: listed?.duration
        )
        artwork = nil
        (lyrics, lyricsSource) = Self.loadLyrics(for: url, embedded: nil)
        displayTime = startAt
        isBuffering = true
        if isPlaying != autoplay { isPlaying = autoplay }
        startTicker()

        if url.isFileURL {
            Task {
                let loaded = await Self.read(url, lyricsFor: url)
                guard generation == self.generation else { return }
                var info = loaded.track
                if info?.duration == nil { info?.duration = listed?.duration }
                if let info { self.track = info }
                self.artwork = loaded.artwork
                if loaded.lyrics != nil {
                    self.lyrics = loaded.lyrics
                    self.lyricsSource = loaded.lyricsSource
                }
            }
        } else {
            loadRemoteDetails(for: url, listed: listed, generation: generation)
        }

        Task {
            do {
                guard let host = cast.localAddress else { throw CastController.Failure.disconnected }
                let media = try await CastMedia.prepare(localCopy?(url) ?? url, listed: listed, host: host, viaMac: viaMac)
                guard generation == self.generation, cast.isActive else { return }
                castViaMac = media.viaMac
                do {
                    try await cast.load(media, startAt: startAt, autoplay: autoplay)
                } catch CastController.Failure.refused where !media.viaMac {
                    // Refused outright: the same track, converted and served
                    // from here, is the one thing left to try.
                    guard generation == self.generation, cast.isActive else { return }
                    castRetried = true
                    castViaMac = true
                    let fallback = try await CastMedia.prepare(localCopy?(url) ?? url, listed: listed, host: host, viaMac: true)
                    guard generation == self.generation, cast.isActive else { return }
                    try await cast.load(fallback, startAt: startAt, autoplay: autoplay)
                }
                guard generation == self.generation else { return }
                isBuffering = false
            } catch {
                guard generation == self.generation else { return }
                isBuffering = false
                isPlaying = false
                lastError = error.localizedDescription
            }
        }
    }

    func tickCast() {
        guard !isBuffering else { return }
        var time = cast.estimatedTime
        if let duration = track?.duration, duration > 0 { time = min(time, duration) }
        if abs(time - displayTime) > 0.01 { displayTime = time }
        if cast.isPlaying != isPlaying { isPlaying = cast.isPlaying }
        // The device's own buttons or remote changed the volume.
        if let level = cast.volume, abs(level - volume) > 0.01 {
            adoptingCastVolume = true
            volume = level
            adoptingCastVolume = false
        }
    }

    private func endCastSession() {
        isBuffering = false
        isPlaying = false
        if let localVolume {
            self.localVolume = nil
            adoptingCastVolume = true
            volume = localVolume
            adoptingCastVolume = false
        }
    }

    /// Paused, at `time`, with nothing loaded yet: play picks up from here.
    private func holdForLocalResume(at time: TimeInterval) {
        guard currentURL != nil else { return }
        pendingLocalResume = time
        displayTime = time
        isPlaying = false
    }

    func resumeLocally(at time: TimeInterval, playing: Bool) {
        pendingLocalResume = nil
        guard let url = currentURL else { return }
        let keep = generation
        open(url)
        guard generation != keep else { return }
        if time > 1 { seek(to: time) }
        if !playing { togglePlayPause() }
    }
}
