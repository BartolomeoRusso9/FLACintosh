import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// A colour taken off a cover, kept as plain numbers so it can cross an
/// actor boundary. `Color` cannot: the extraction runs on a background
/// thread and the result is handed to the main one.
struct RGB: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// The same hue, made fit to sit behind white text.
    ///
    /// Covers are mastered to be looked at, not to be read over: a pale
    /// sleeve would wash the lyrics out and a black one would say nothing.
    /// Pinning brightness and floor-ing saturation keeps the album's colour
    /// recognisable while the ground stays dark enough to read on.
    var stageTint: HSB {
        let hsb = HSB(self)
        // Washed-out sleeves get lifted towards a usable saturation, but a
        // cover that is already vivid keeps exactly what it had: pinning
        // everything to one value made two different browns come out as the
        // same brown. A true grey stays grey — the hue it reports is
        // rounding error, and borrowing it would tint the window a colour
        // that is nowhere on the cover.
        let saturation = hsb.saturation < 0.06
            ? 0
            : min(0.92, hsb.saturation + max(0, 0.42 - hsb.saturation) * 0.55)

        return HSB(
            hue: saturation == 0 ? 0 : hsb.hue,
            saturation: saturation,
            // Dark enough to read white over, whatever the sleeve does.
            brightness: min(saturation == 0 ? 0.3 : 0.52, max(0.16, hsb.brightness))
        )
    }

    var asStageTint: Color {
        let hsb = stageTint
        return Color(
            hue: hsb.hue,
            saturation: hsb.saturation,
            brightness: hsb.brightness
        )
    }
}

/// A cover and the colours it is made of.
struct Artwork: Sendable, Equatable {
    /// Identity for the view that decodes `data`, so it can tell "a new
    /// cover" from "the same cover" without comparing megabytes of it.
    var id = UUID()
    /// The original bytes, turned into an image on the main thread.
    var data: Data
    /// Most prominent first, at most four.
    var palette: [RGB]
}

// MARK: - Extraction

extension Artwork {
    /// Decodes the cover small and counts what colours it is mostly made of.
    ///
    /// Deliberately crude — a 48-pixel thumbnail into 512 buckets. A proper
    /// k-means would be slower and no more convincing at this size, and the
    /// answer only has to be "what colour is this record", not a palette a
    /// designer would sign off.
    static func make(from data: Data) -> Artwork? {
        guard let thumbnail = thumbnail(from: data, side: 48) else { return nil }
        return Artwork(data: data, palette: palette(of: thumbnail))
    }

    private static func thumbnail(from data: Data, side: Int) -> [RGB]? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: side,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
            )
        else { return nil }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return stride(from: 0, to: pixels.count, by: 4).compactMap { index in
            guard pixels[index + 3] > 128 else { return nil }
            return RGB(
                red: Double(pixels[index]) / 255,
                green: Double(pixels[index + 1]) / 255,
                blue: Double(pixels[index + 2]) / 255
            )
        }
    }

    private static func palette(of pixels: [RGB]) -> [RGB] {
        struct Bucket {
            var red = 0.0, green = 0.0, blue = 0.0
            var count = 0
            /// Colourful pixels are what a cover is remembered by, so they
            /// count for more than the grey that surrounds them.
            var weight = 0.0
        }

        var buckets: [Int: Bucket] = [:]
        for pixel in pixels {
            let hsb = HSB(pixel)
            // Near-black and near-white say nothing about an album.
            guard hsb.brightness > 0.12, hsb.brightness < 0.97 else { continue }
            let key = Int(pixel.red * 7) << 6 | Int(pixel.green * 7) << 3 | Int(pixel.blue * 7)
            var bucket = buckets[key] ?? Bucket()
            let weight = 0.25 + hsb.saturation
            bucket.red += pixel.red * weight
            bucket.green += pixel.green * weight
            bucket.blue += pixel.blue * weight
            bucket.count += 1
            bucket.weight += weight
            buckets[key] = bucket
        }

        let ranked = buckets.values
            .filter { $0.count > 2 }
            .sorted { $0.weight > $1.weight }
            .map {
                RGB(
                    red: $0.red / $0.weight,
                    green: $0.green / $0.weight,
                    blue: $0.blue / $0.weight
                )
            }

        // Four blobs that all look alike is one blob. Keep only colours far
        // enough apart to read as separate light sources.
        var chosen: [RGB] = []
        for candidate in ranked where chosen.count < 4 {
            let isDistinct = chosen.allSatisfy { existing in
                let dr = existing.red - candidate.red
                let dg = existing.green - candidate.green
                let db = existing.blue - candidate.blue
                return (dr * dr + dg * dg + db * db).squareRoot() > 0.22
            }
            if isDistinct { chosen.append(candidate) }
        }
        return chosen
    }
}

// MARK: - Thumbnails

extension Artwork {
    /// A small JPEG of a cover, for the grid.
    ///
    /// Sleeves are commonly 3000 pixels square. Two hundred of those decoded
    /// into a scrolling grid is a gigabyte of memory for pictures drawn at
    /// 180 points, so the library keeps this instead and never touches the
    /// original until something asks for it full size.
    static func thumbnailData(from data: Data, maxPixel: Int = 320) -> Data? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
            )
        else { return nil }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                "public.jpeg" as CFString,
                1,
                nil
            )
        else { return nil }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// MARK: - Colour space

/// Just enough HSB to judge a colour. `NSColor` would do this too, but it is
/// main-thread-shy and this runs off the main thread by design.
struct HSB {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    init(_ rgb: RGB) {
        let maximum = max(rgb.red, rgb.green, rgb.blue)
        let minimum = min(rgb.red, rgb.green, rgb.blue)
        let delta = maximum - minimum

        brightness = maximum
        saturation = maximum == 0 ? 0 : delta / maximum

        if delta == 0 {
            hue = 0
        } else if maximum == rgb.red {
            hue = ((rgb.green - rgb.blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == rgb.green {
            hue = (rgb.blue - rgb.red) / delta + 2
        } else {
            hue = (rgb.red - rgb.green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
    }
}
