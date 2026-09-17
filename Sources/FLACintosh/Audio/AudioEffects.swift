import Accelerate
import AVFoundation
import Foundation
import MediaToolbox
import Observation
import SFBAudioEngine
import os

/// What happens to the sound between the file and the speakers: gapless
/// playback, ReplayGain and the equalizer.
///
/// The settings live here; the two players apply them. Local files play
/// through SFBAudioEngine, where the equalizer is an `AVAudioUnitEQ` in its
/// processing graph. Server streams play through AVPlayer, which has no graph
/// to insert into — there the same curve is computed as biquad filters in an
/// audio processing tap.
@MainActor
@Observable
final class AudioEffects {
    enum ReplayGainMode: String, CaseIterable, Identifiable {
        case off, track, album

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Off"
            case .track: "Track"
            case .album: "Album"
            }
        }
    }

    /// The ten bands, in hertz — the classic graphic equalizer octaves.
    nonisolated static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    nonisolated static let bandLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let gainRange: ClosedRange<Double> = -12 ... 12

    static let presets: [(name: String, gains: [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Booster", [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]),
        ("Bass Reducer", [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
        ("Treble Booster", [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
        ("Treble Reducer", [0, 0, 0, 0, 0, -1, -2.5, -4, -5, -6]),
        ("Vocal Booster", [-2, -3, -3, 1, 4, 4, 3.5, 1.5, 0, -2]),
        ("Loudness", [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        ("Acoustic", [5, 5, 4, 1, 2, 2, 3.5, 4, 3.5, 2]),
        ("Classical", [5, 4, 3.5, 3, -1.5, -1.5, 0, 2, 3.5, 4]),
        ("Dance", [3.5, 6.5, 5, 0, 2, 3.5, 5, 4, 3.5, 0]),
        ("Electronic", [4, 3.5, 1, 0, -2, 2, 1, 1, 4, 5]),
        ("Hip-Hop", [5, 4, 1, 3, -1, -1, 1, -0.5, 2, 3]),
        ("Jazz", [4, 3, 1, 2, -1.5, -1.5, 0, 1.5, 3, 3.5]),
        ("Pop", [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        ("R&B", [2.5, 7, 5.5, 1.5, -2, -1.5, 2, 2.5, 3, 3.5]),
        ("Rock", [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        ("Late Night", [4, 3, 2, 0, -1, -1, 0, 1, 2, 3]),
        ("Small Speakers", [5.5, 4, 3.5, 2.5, 1.5, 0, -1.5, -2.5, -3.5, -4]),
        ("Spoken Word", [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 5, 4, 2.5, 0]),
    ]

    var gapless = UserDefaults.standard.object(forKey: "gapless") as? Bool ?? true {
        didSet { save("gapless", gapless) }
    }

    var replayGain = ReplayGainMode(rawValue: UserDefaults.standard.string(forKey: "replayGain") ?? "") ?? .off {
        didSet { save("replayGain", replayGain.rawValue) }
    }

    /// Added to every ReplayGain adjustment. ReplayGain aims at 89 dB SPL,
    /// quieter than most modern masters; some people like it a little louder.
    var replayGainPreamp = UserDefaults.standard.double(forKey: "replayGainPreamp") {
        didSet { save("replayGainPreamp", replayGainPreamp) }
    }

    var equalizerOn = UserDefaults.standard.bool(forKey: "equalizerOn") {
        didSet { save("equalizerOn", equalizerOn) }
    }

    var gains: [Double] = (UserDefaults.standard.array(forKey: "equalizerGains") as? [Double]).flatMap { $0.count == 10 ? $0 : nil }
        ?? Array(repeating: 0, count: 10) {
        didSet { save("equalizerGains", gains) }
    }

    /// The preset last chosen, or nil once the bands match none of them.
    var presetName: String? = UserDefaults.standard.string(forKey: "equalizerPreset") ?? "Flat" {
        didSet { save("equalizerPreset", presetName ?? "") }
    }

    /// Called after any change, for the players to pick it up.
    @ObservationIgnored var onChange: (() -> Void)?

    func apply(preset name: String) {
        guard let preset = Self.presets.first(where: { $0.name == name }) else { return }
        gains = preset.gains
        presetName = name
    }

    func setGain(_ value: Double, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = value
        let match = Self.presets.first { $0.gains == gains }?.name
        if match != presetName { presetName = match }
    }

    /// Headroom for the curve: boosting a band by 6 dB on a track mastered
    /// to full scale clips unless the whole signal comes down by as much.
    var equalizerHeadroom: Double {
        equalizerOn ? -max(0, gains.max() ?? 0) : 0
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }
}

// MARK: - ReplayGain

/// ReplayGain as tagged in a file.
struct ReplayGainInfo: Sendable, Equatable {
    var trackGain: Double?
    var trackPeak: Double?
    var albumGain: Double?
    var albumPeak: Double?

    init?(_ metadata: AudioMetadata) {
        trackGain = metadata.replayGainTrackGain
        trackPeak = metadata.replayGainTrackPeak
        albumGain = metadata.replayGainAlbumGain
        albumPeak = metadata.replayGainAlbumPeak
        if trackGain == nil, albumGain == nil { return nil }
    }

    /// The adjustment in decibels for a mode, held back so the loudest
    /// sample in the file does not go past full scale.
    func gain(for mode: AudioEffects.ReplayGainMode, preamp: Double) -> Double {
        let chosen: (gain: Double?, peak: Double?) = switch mode {
        case .off: (nil, nil)
        case .track: (trackGain ?? albumGain, trackPeak ?? albumPeak)
        case .album: (albumGain ?? trackGain, albumPeak ?? trackPeak)
        }
        guard let gain = chosen.gain else { return 0 }
        var total = gain + preamp
        if let peak = chosen.peak, peak > 0 {
            total = min(total, -20 * log10(peak))
        }
        return total
    }
}

// MARK: - The local player

/// The equalizer in one SFBAudioEngine player's graph, and the player's
/// delegate — which is how gapless playback learns that the next file began.
final class DeckEffects: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    private let eq = AVAudioUnitEQ(numberOfBands: AudioEffects.frequencies.count)
    /// The file that started rendering, reported on the main actor.
    var onNowPlayingChanged: (@MainActor (URL?) -> Void)?

    init(player: AudioPlayer) {
        super.init()
        for (band, frequency) in zip(eq.bands, AudioEffects.frequencies) {
            band.filterType = .parametric
            band.frequency = Float(frequency)
            band.bandwidth = 1
            band.gain = 0
            band.bypass = true
        }
        player.delegate = self
        let eq = eq
        player.modifyProcessingGraph { engine in
            let source = player.sourceNode
            let format = source.outputFormat(forBus: 0)
            engine.attach(eq)
            engine.disconnectNodeOutput(source)
            engine.connect(source, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
        }
    }

    /// - parameter gain: overall gain in decibels — ReplayGain and headroom.
    func apply(enabled: Bool, gains: [Double], gain: Double) {
        for (band, value) in zip(eq.bands, gains) {
            band.gain = Float(value)
            band.bypass = !enabled || value == 0
        }
        eq.globalGain = Float(min(max(gain, -96), 24))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        engine.disconnectNodeOutput(eq)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        return eq
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: PCMDecoding?) {
        let url = nowPlaying?.inputSource.url
        guard let callback = onNowPlayingChanged else { return }
        Task { @MainActor in callback(url) }
    }
}

// MARK: - The stream player

/// The same equalizer and gain for AVPlayer, as an audio processing tap.
///
/// AVPlayer hands the tap its decoded audio; each channel goes through ten
/// peaking biquads (the RBJ cookbook's, one octave wide, like the
/// `AVAudioUnitEQ` bands) and a gain. New settings are built on the main
/// thread and swapped in under a lock the audio thread only ever *tries*: if
/// it is busy, that one buffer goes through untouched rather than waiting.
final class StreamEffects: @unchecked Sendable {
    private struct Filters {
        var setups: [vDSP_biquad_Setup] = []
        var delays: [[Float]] = []
        var linearGain: Float = 1
        var active = false
    }

    private let lock = OSAllocatedUnfairLock()
    private var filters = Filters()
    private var retired: [vDSP_biquad_Setup] = []
    private var sampleRate: Double = 44100
    private var channels = 2
    private var settings: (enabled: Bool, gains: [Double], gain: Double) = (false, Array(repeating: 0, count: 10), 0)

    deinit {
        filters.setups.forEach { vDSP_biquad_DestroySetup($0) }
        retired.forEach { vDSP_biquad_DestroySetup($0) }
    }

    func apply(enabled: Bool, gains: [Double], gain: Double) {
        lock.withLockUnchecked {
            settings = (enabled, gains, gain)
            rebuildLocked()
        }
    }

    /// Adds the tap to an item. The asset's audio track is needed for it,
    /// which for a stream means waiting for the first bytes.
    func attach(to item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: Unmanaged.passRetained(self).toOpaque(),
                init: { _, clientInfo, storage in storage.pointee = clientInfo },
                finalize: { tap in
                    Unmanaged<StreamEffects>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
                },
                prepare: { tap, _, format in
                    let effects = Unmanaged<StreamEffects>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    effects.prepare(format.pointee)
                },
                unprepare: nil,
                process: { tap, frames, _, buffers, framesOut, flagsOut in
                    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
                    guard status == noErr else { return }
                    let effects = Unmanaged<StreamEffects>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    effects.process(buffers, frames: Int(framesOut.pointee))
                }
            )
            var tap: MTAudioProcessingTap?
            guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
                  let tap
            else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    private func prepare(_ format: AudioStreamBasicDescription) {
        lock.withLockUnchecked {
            sampleRate = format.mSampleRate
            channels = Int(format.mChannelsPerFrame)
            rebuildLocked()
        }
    }

    private func rebuildLocked() {
        retired.append(contentsOf: filters.setups)
        var next = Filters()
        let (enabled, gains, gain) = settings
        next.linearGain = Float(pow(10, min(max(gain, -96), 24) / 20))
        next.active = enabled || abs(gain) > 0.01

        if enabled, gains.contains(where: { $0 != 0 }) {
            var coefficients: [Double] = []
            for (frequency, dB) in zip(AudioEffects.frequencies, gains) {
                coefficients += Self.peaking(frequency: frequency, gain: dB, sampleRate: sampleRate)
            }
            let sections = vDSP_Length(gains.count)
            for _ in 0 ..< max(channels, 1) {
                if let setup = vDSP_biquad_CreateSetup(coefficients, sections) {
                    next.setups.append(setup)
                    next.delays.append(Array(repeating: 0, count: 2 * gains.count + 2))
                }
            }
        }
        filters = next
        // The audio thread only reads under the lock, so anything replaced
        // before this rebuild is no longer in use.
        retired.forEach { vDSP_biquad_DestroySetup($0) }
        retired.removeAll()
    }

    private func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }
        _ = lock.withLockIfAvailableUnchecked {
            guard filters.active else { return }
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            for (index, buffer) in list.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                if filters.setups.indices.contains(index) {
                    let setup = filters.setups[index]
                    filters.delays[index].withUnsafeMutableBufferPointer { delay in
                        vDSP_biquad(setup, delay.baseAddress!, data, 1, data, 1, vDSP_Length(count))
                    }
                }
                if filters.linearGain != 1 {
                    var gain = filters.linearGain
                    vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(count))
                }
            }
        }
    }

    /// One peaking band, normalised, in vDSP's order: b0, b1, b2, a1, a2.
    nonisolated static func peaking(frequency: Double, gain: Double, sampleRate: Double) -> [Double] {
        guard gain != 0, frequency < sampleRate / 2 else { return [1, 0, 0, 0, 0] }
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let bandwidth = 1.0
        let alpha = sin(w0) * sinh(log(2) / 2 * bandwidth * w0 / sin(w0))
        let a0 = 1 + alpha / a
        return [
            (1 + alpha * a) / a0,
            (-2 * cos(w0)) / a0,
            (1 - alpha * a) / a0,
            (-2 * cos(w0)) / a0,
            (1 - alpha / a) / a0,
        ]
    }
}
