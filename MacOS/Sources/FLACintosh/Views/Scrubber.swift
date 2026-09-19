import SwiftUI

/// The playhead, as a line rather than a slider.
///
/// A stock `Slider` cannot be this thin, and it insists on a thumb. This one
/// follows the finger while dragging and only tells the player once, on
/// release: seeking on every intermediate value makes the decoder thrash and
/// the line fight the playhead.
struct Scrubber: View {
    let elapsed: TimeInterval
    let duration: TimeInterval
    var height: CGFloat = 4
    var tint: AnyShapeStyle = AnyShapeStyle(Palette.brand)
    var track: Color = Color.primary.opacity(0.14)
    let onSeek: (TimeInterval) -> Void

    @State private var dragging: Double?

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max((dragging ?? elapsed) / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: max(0, width * fraction))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        dragging = min(max(value.location.x / width, 0), 1) * duration
                    }
                    .onEnded { _ in
                        if let dragging { onSeek(dragging) }
                        dragging = nil
                    }
            )
        }
        .frame(height: max(height, 12))
    }
}
