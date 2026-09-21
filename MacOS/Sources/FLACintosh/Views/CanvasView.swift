import AVFoundation
import SwiftUI

/// A Spotify Canvas: a few seconds of silent video, looping where the sleeve
/// would be.
///
/// Muted on purpose — the clip's own soundtrack, when it has one, is the
/// song, already playing. It follows the music: paused with it, so a stopped
/// record does not keep moving, and started again from where it was.
#if os(macOS)
struct CanvasView: NSViewRepresentable {
    let url: URL
    let isPlaying: Bool

    func makeNSView(context: Context) -> CanvasLayerView {
        let view = CanvasLayerView()
        view.load(url)
        view.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ view: CanvasLayerView, context: Context) {
        view.load(url)
        view.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ view: CanvasLayerView, coordinator: ()) {
        view.stop()
    }
}
#else
struct CanvasView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool

    func makeUIView(context: Context) -> CanvasLayerView {
        let view = CanvasLayerView()
        view.load(url)
        view.setPlaying(isPlaying)
        return view
    }

    func updateUIView(_ view: CanvasLayerView, context: Context) {
        view.load(url)
        view.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ view: CanvasLayerView, coordinator: ()) {
        view.stop()
    }
}
#endif

/// The layer-backed view the clip draws into: an `AVPlayerLayer` filling
/// its bounds, cropped rather than letterboxed — a canvas is tall, the
/// sleeve is square, and black bars would look like a broken video.
final class CanvasLayerView: PlatformView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loaded: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        backingLayer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    #if os(macOS)
    override func layout() {
        super.layout()
        fitPlayerLayer()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        fitPlayerLayer()
    }
    #endif

    private func fitPlayerLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func load(_ url: URL) {
        guard url != loaded else { return }
        stop()
        loaded = url

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        // Never the reason a Mac stays awake, and never a claim on the
        // system's Now Playing — that belongs to the song.
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        playerLayer.player = queue
    }

    func setPlaying(_ playing: Bool) {
        guard let player else { return }
        if playing {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer.player = nil
        loaded = nil
    }
}
