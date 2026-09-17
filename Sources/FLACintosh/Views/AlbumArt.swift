import AppKit
import SwiftUI

/// Decoded sleeves, kept so scrolling the grid does not decode the same
/// JPEG twice. The library hands out bytes; this hands out pictures.
@MainActor
final class CoverCache {
    static let shared = CoverCache()

    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    /// Roughly a screenful of grid, several times over. Past that the oldest
    /// go: a library can be thousands of records and every one of them
    /// decoded at once is memory spent on tiles nobody is looking at.
    private let limit = 400

    /// Already decoded, if it is: no wait for a tile scrolled back into view.
    func cached(id: String) -> NSImage? { images[id] }

    /// Decodes a cover off the main thread, at no more pixels than it will be
    /// drawn with.
    ///
    /// `NSImage(data:)` on its own decodes nothing: the JPEG is inflated the
    /// first time the image is drawn, on the main thread, at full size — a
    /// 3000-pixel sleeve for a 420-point square, and a hitch in every grid
    /// that scrolls a new row in. ImageIO makes a thumbnail of the right size
    /// here instead, decoded before it is handed over.
    func load(id: String, data: Data?, maxPixel: Int) async -> NSImage? {
        if let cached = images[id] { return cached }
        guard let data else { return nil }

        let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let decoded else { return nil }

        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        images[id] = image
        order.append(id)
        if order.count > limit {
            let evicted = order.removeFirst()
            images[evicted] = nil
        }
        return image
    }
}

/// A square sleeve, or a placeholder shaped like one.
struct AlbumArt: View {
    let id: String
    let data: Data?
    var corner: CGFloat = 8
    /// What a missing sleeve is filled with.
    ///
    /// The shelves sit on the window's own background, where `.quaternary`
    /// reads as a tile. The Now Playing stage brings its own grey, and on it
    /// a translucent grey placeholder disappears entirely — so that caller
    /// passes something darker.
    var placeholder: AnyShapeStyle = AnyShapeStyle(.quaternary)

    @State private var image: NSImage?
    @State private var side: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(placeholder)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Sized against the square it sits in: a fixed 20pt note
                    // is right in a 26pt thumbnail and a speck in a 320pt
                    // sleeve.
                    GeometryReader { geometry in
                        let side = min(geometry.size.width, geometry.size.height)
                        Image(systemName: "music.note")
                            .font(.system(size: max(11, side * 0.42), weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .background {
                // Measured so the decode matches the size on screen: a
                // thumbnail in a list and the sleeve in Now Playing are the
                // same cover at very different sizes.
                GeometryReader { geometry in
                    Color.clear.preference(key: CoverSideKey.self, value: max(geometry.size.width, geometry.size.height))
                }
            }
            .onPreferenceChange(CoverSideKey.self) { side = $0 }
            .task(id: "\(id)|\(bucket)") {
                // Not before it has been measured: decoding for a size of
                // zero and again a moment later is two decodes for one cover.
                guard side > 0 else { return }
                if let cached = CoverCache.shared.cached(id: cacheKey) {
                    image = cached
                    return
                }
                image = await CoverCache.shared.load(id: cacheKey, data: data, maxPixel: bucket)
            }
    }

    /// Pixels to decode for the size drawn, at the screen's scale, rounded
    /// up to a few steps so resizing a window does not decode again for
    /// every point it changes.
    private var bucket: Int {
        let pixels = side * (NSScreen.main?.backingScaleFactor ?? 2)
        return [128, 256, 512, 1024, 2048].first { CGFloat($0) >= pixels } ?? 2048
    }

    private var cacheKey: String { "\(id)@\(bucket)" }
}

private struct CoverSideKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
