import SwiftUI

/// The Apple Music brand palette.
///
/// Three colours, and only three: pink, red, white. Everything else on
/// screen is either the artwork's own colour or a shade of white over it,
/// which is the whole trick of the Now Playing screen — the album supplies
/// the hue, the brand supplies the accent, and nothing else is invented.
enum Palette {
    /// `#FF4E6B`
    static let pink = Color(red: 255 / 255, green: 78 / 255, blue: 107 / 255)
    /// `#FF0436`
    static let red = Color(red: 255 / 255, green: 4 / 255, blue: 54 / 255)
    /// `#FFFFFF`
    static let white = Color.white

    /// Pink into red, the direction the logo runs.
    static let brand = LinearGradient(
        colors: [pink, red],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// The stage with nothing to tint it: no cover, so no colours to borrow.
    /// Apple Music's own grey — the drift only means something when the
    /// colours belong to the record, and inventing a pink for a track that
    /// has no artwork is inventing a mood it does not have.
    static let emptyStage = Color(red: 0.42, green: 0.42, blue: 0.44)

    /// The stage is dark whatever the system appearance is.
    ///
    /// Not a preference: white lyrics over an album's own colours only works
    /// on a dark ground, and a Now Playing screen that flipped to a light
    /// one in the morning would have to abandon either the artwork tint or
    /// the white text. Apple Music makes the same call.
    static let stage = Color(red: 0.055, green: 0.055, blue: 0.063)

    // MARK: - Lyrics

    /// Text the sweep has not reached yet. White, not grey: over a tinted
    /// ground a grey reads as a different colour in every song.
    static let lyricPending = Color.white.opacity(0.3)
    /// Hairlines and the scrubber's unfilled track.
    static let hairline = Color.white.opacity(0.1)
}
