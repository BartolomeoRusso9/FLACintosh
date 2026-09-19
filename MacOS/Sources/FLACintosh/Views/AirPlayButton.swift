import AVKit
import SwiftUI

/// The system's own output picker: AirPlay speakers and TVs, headphones,
/// the Mac's speakers.
///
/// macOS's `AVRoutePickerView`, not a menu drawn here, for the same reason
/// Apple Music uses it — the list of devices, their grouping and the
/// connection itself belong to the system, and a picker built by hand would
/// only ever be a worse copy of it.
///
/// It chooses the system's audio output, which is where both of the app's
/// players send their sound.
struct AirPlayButton: NSViewRepresentable {
    var tint: NSColor = .labelColor
    var activeTint: NSColor = NSColor(Palette.red)

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        apply(to: picker)
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        apply(to: picker)
    }

    private func apply(to picker: AVRoutePickerView) {
        picker.setRoutePickerButtonColor(tint, for: .normal)
        picker.setRoutePickerButtonColor(tint.withAlphaComponent(0.7), for: .normalHighlighted)
        // Lit while the sound is going somewhere other than this Mac.
        picker.setRoutePickerButtonColor(activeTint, for: .active)
        picker.setRoutePickerButtonColor(activeTint.withAlphaComponent(0.7), for: .activeHighlighted)
    }
}
