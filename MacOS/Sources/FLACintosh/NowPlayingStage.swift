import QuartzCore
import SwiftUI

/// The ground the lyrics sit on: the album's own colours, drifting.
///
/// Core Animation, not SwiftUI animation. The first version animated each
/// blob's `.position` and `.scaleEffect` with `repeatForever` — and position
/// is layout: SwiftUI interpolated it on the main thread at the display's
/// refresh rate, forever, recompositing four window-sized gradients a frame.
/// With the app merely open that was a steady load on the whole Mac.
///
/// Here each blob is a radial `CAGradientLayer` with its drift handed to the
/// render server as a `CABasicAnimation`: once added, the app does no work
/// per frame at all. The colours change with the record, cross-faded by a
/// short implicit animation on the layer.
struct NowPlayingStage: View {
    var palette: [RGB]

    var body: some View {
        if palette.isEmpty {
            // Nothing to borrow. A flat grey, not an invented pink: the
            // drift is the album's colours moving, and with no album there
            // is nothing for it to be about.
            Palette.emptyStage.ignoresSafeArea()
        } else {
            ZStack {
                StageLayers(colours: palette.map { PlatformColor($0.asStageTint) })

                // Enough darkness at the top and bottom for the header and
                // the transport bar to read over any cover.
                LinearGradient(
                    colors: [
                        Palette.stage.opacity(0.75),
                        Palette.stage.opacity(0.1),
                        Palette.stage.opacity(0.1),
                        Palette.stage.opacity(0.8),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()
        }
    }
}

#if os(macOS)
private struct StageLayers: NSViewRepresentable {
    let colours: [PlatformColor]

    func makeNSView(context: Context) -> StageView {
        let view = StageView()
        view.setColours(colours)
        return view
    }

    func updateNSView(_ view: StageView, context: Context) {
        view.setColours(colours)
    }
}
#else
private struct StageLayers: UIViewRepresentable {
    let colours: [PlatformColor]

    func makeUIView(context: Context) -> StageView {
        let view = StageView()
        view.setColours(colours)
        return view
    }

    func updateUIView(_ view: StageView, context: Context) {
        view.setColours(colours)
    }
}
#endif

final class StageView: PlatformView {
    /// Where each blob sits, and where it drifts to, in unit coordinates
    /// (origin top left, as the design was drawn).
    private static let anchors: [(from: CGPoint, to: CGPoint)] = [
        (CGPoint(x: 0.18, y: 0.16), CGPoint(x: 0.34, y: 0.34)),
        (CGPoint(x: 0.86, y: 0.24), CGPoint(x: 0.68, y: 0.08)),
        (CGPoint(x: 0.24, y: 0.86), CGPoint(x: 0.12, y: 0.64)),
        (CGPoint(x: 0.78, y: 0.82), CGPoint(x: 0.92, y: 0.96)),
    ]

    private var blobs: [CAGradientLayer] = []
    private var colours: [PlatformColor] = []
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backingLayer.backgroundColor = PlatformColor(Palette.stage).cgColor
        backingLayer.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    #if os(macOS)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        sizeMayHaveChanged()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        sizeMayHaveChanged()
    }
    #endif

    func setColours(_ new: [PlatformColor]) {
        guard new != colours else { return }
        colours = new
        rebuildIfNeeded(force: blobs.count != new.count)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        for (blob, colour) in zip(blobs, new) {
            blob.colors = [colour.withAlphaComponent(0.85).cgColor, colour.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
    }

    private func sizeMayHaveChanged() {
        // Rebuilding restarts the drift, so only when the size really
        // changed — not on every layout pass SwiftUI happens to run.
        if abs(bounds.width - laidOutSize.width) > 1 || abs(bounds.height - laidOutSize.height) > 1 {
            rebuildIfNeeded(force: true)
        }
    }

    private func rebuildIfNeeded(force: Bool) {
        guard force, bounds.width > 0, bounds.height > 0 else { return }
        let root = backingLayer
        laidOutSize = bounds.size
        blobs.forEach { $0.removeFromSuperlayer() }
        blobs = []

        let reach = max(bounds.width, bounds.height)
        let side = reach * 0.95

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, colour) in colours.enumerated() {
            let anchor = Self.anchors[index % Self.anchors.count]
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.colors = [colour.withAlphaComponent(0.85).cgColor, colour.withAlphaComponent(0).cgColor]
            // A radial gradient runs from the centre to the layer's edge;
            // the circle ends at 0.42 of the reach, as the design had it.
            let end = (reach * 0.42) / side
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 0.5 + end, y: 0.5 + end)
            blob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            blob.position = point(anchor.from)
            blob.transform = CATransform3DMakeScale(0.92, 0.92, 1)
            root.addSublayer(blob)
            blobs.append(blob)

            let duration = 18 + Double(index) * 3.5

            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = animationValue(point(anchor.from))
            move.toValue = animationValue(point(anchor.to))

            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.92
            grow.toValue = 1.12

            let drift = CAAnimationGroup()
            drift.animations = [move, grow]
            drift.duration = duration
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drift.isRemovedOnCompletion = false
            // A drift over eighteen seconds does not need sixty frames a
            // second. Left to the display's rate, the render server redrew
            // four window-sized gradients sixty times a second for motion of
            // a pixel or two per frame — a steady cost, and heat.
            drift.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
            blob.add(drift, forKey: "drift")
        }
        CATransaction.commit()
    }

    private func point(_ unit: CGPoint) -> CGPoint {
        CGPoint(x: unit.x * bounds.width, y: unit.y * bounds.height)
    }
}
