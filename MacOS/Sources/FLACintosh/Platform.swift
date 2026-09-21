import ImageIO
import SFBAudioEngine
import SwiftUI

// The one place that knows which UI framework this build sits on. The rest of
// the app says `PlatformImage` and `PlatformColor` and does not care whether
// it is AppKit or UIKit underneath.

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformView = NSView

extension NSView {
    /// The view's Core Animation layer. AppKit makes it on request and hands
    /// it back optional; UIKit always has one.
    var backingLayer: CALayer {
        wantsLayer = true
        return layer!
    }
}
#else
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformView = UIView

extension UIView {
    var backingLayer: CALayer { layer }
}
#endif

extension Notification.Name {
    /// The last thing an app hears before it is gone — the moment to write
    /// out whatever is only in memory.
    static var appWillTerminate: Notification.Name {
        #if canImport(AppKit)
        NSApplication.willTerminateNotification
        #else
        UIApplication.willTerminateNotification
        #endif
    }

    /// The app came back to the front.
    static var appDidBecomeActive: Notification.Name {
        #if canImport(AppKit)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }
}

/// Puts the keyboard away, from wherever it was asked for.
///
/// A search field keeps the keyboard up for as long as it has the cursor, and
/// a screen laid over it — Now Playing — does not take the cursor away: the
/// keys stayed on screen over the player.
@MainActor
func dismissKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

/// Opens a web page in the user's browser.
@MainActor
func openInBrowser(_ url: URL) {
    #if canImport(AppKit)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}

/// Puts text on the general pasteboard.
@MainActor
func copyToPasteboard(_ text: String) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

extension AudioPlayer {
    /// The level of this player alone, as opposed to the device's volume.
    ///
    /// On the Mac the engine's output unit has a volume of its own, and that
    /// is what `setVolume` sets. iOS has none — the hardware buttons own the
    /// device volume — so the player's own mixer stands in for it. Either way
    /// two decks can be set independently, which the crossfade relies on.
    func setDeckVolume(_ volume: Float) throws {
        #if os(macOS)
        try setVolume(volume)
        #else
        modifyProcessingGraph { $0.mainMixerNode.outputVolume = volume }
        #endif
    }
}

private struct OpenEqualizerKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// How to show the equalizer where it is not a window of its own.
    ///
    /// `nil` on the Mac, where the Equalizer is a window and `openWindow`
    /// reaches it. The iOS app sets it to raise a sheet, since a phone has no
    /// second window to open.
    var openEqualizer: (() -> Void)? {
        get { self[OpenEqualizerKey.self] }
        set { self[OpenEqualizerKey.self] = newValue }
    }
}

extension Font {
    /// A size drawn for the Mac, made larger where the screen is held at arm's
    /// length. The lists were set in 11 to 13 points — right at a desk, and
    /// about three quarters of what a phone's own lists use.
    static func list(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        #if os(iOS)
        .system(size: (size * 1.3).rounded(), weight: weight, design: design)
        #else
        .system(size: size, weight: weight, design: design)
        #endif
    }
}

/// Room around a row of a list: enough for a finger on a phone, the tighter
/// figure of a pointer on the Mac.
enum RowMetrics {
    static var vertical: CGFloat {
        #if os(iOS)
        11
        #else
        7
        #endif
    }
}

/// What this device calls itself in a sentence: text written for the Mac says
/// "this Mac", and on a phone that is simply wrong.
enum ThisDevice {
    /// "this Mac", "this iPhone", "this iPad".
    static var lowercase: String {
        #if os(macOS)
        "this Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        #endif
    }

    /// "This Mac", for a heading.
    static var capitalized: String {
        lowercase.prefix(1).uppercased() + lowercase.dropFirst()
    }
}

/// A point boxed for a `CABasicAnimation` value: Core Animation wants an
/// `NSValue`, and the two frameworks spell the initialiser differently.
func animationValue(_ point: CGPoint) -> NSValue {
    #if canImport(AppKit)
    NSValue(point: point)
    #else
    NSValue(cgPoint: point)
    #endif
}

extension PlatformImage {
    /// A decoded bitmap, sized in points as it has pixels: the cover cache
    /// decodes at the resolution it will be drawn at, so one to one is right.
    static func make(cgImage: CGImage) -> PlatformImage {
        #if canImport(AppKit)
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        UIImage(cgImage: cgImage)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformColor {
    /// White at some opacity, the colour of text laid over artwork.
    static func whiteAlpha(_ alpha: CGFloat) -> PlatformColor {
        PlatformColor.white.withAlphaComponent(alpha)
    }

    /// The system's primary and secondary text colours: the two greys every
    /// control text is drawn in.
    ///
    /// Not named `primaryLabel` and `secondaryLabel`: UIKit already has
    /// colours by those names, and an extension member of the same name
    /// shadows them — `.secondaryLabel` inside it then calls itself.
    static var primaryText: PlatformColor {
        #if canImport(AppKit)
        .labelColor
        #else
        .label
        #endif
    }

    static var secondaryText: PlatformColor {
        #if canImport(AppKit)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }
}
