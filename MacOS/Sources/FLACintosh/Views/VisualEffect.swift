import SwiftUI

#if os(macOS)
import AppKit

/// An `NSVisualEffectView`, because SwiftUI's materials only ever blend with
/// what is *inside* the window.
///
/// Apple Music's sidebar shows the desktop through it, and that takes
/// `.behindWindow` blending — a depth `.regularMaterial` cannot reach, since
/// it composites against the window's own backing. AppKit punches the
/// window background out behind this view by itself, so the window stays an
/// ordinary opaque one and only this region turns to glass.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        // Not `.active`: a sidebar that keeps glowing while the app is in the
        // background is the one detail that gives a fake material away.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
#else
/// iOS has no window to show through, so the sidebar's glass is SwiftUI's own
/// material: it blends with what is behind it inside the app, which is all
/// there is to blend with.
struct VisualEffect: View {
    var body: some View {
        Rectangle().fill(.regularMaterial)
    }
}
#endif
