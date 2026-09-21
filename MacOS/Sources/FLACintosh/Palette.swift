import SwiftUI

/// The look of the app: which accent it wears, and on what ground.
///
/// Ruby is the app's own and the default: a red accent, on the system's
/// light or dark. Emerald is a choice in Settings — a green accent on a dark
/// ground that stays dark. Nothing but colours differs between them.
enum Theme: String, CaseIterable, Identifiable {
    case ruby
    case emerald

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ruby: "Ruby"
        case .emerald: "Emerald"
        }
    }

    var summary: String {
        switch self {
        case .ruby: "A red accent. Follows the system's light or dark appearance."
        case .emerald: "A green accent on a dark ground, whatever the system is set to."
        }
    }

    /// The accent's light form: Ruby `#FF4E6B`, Emerald `#1ED760`.
    var light: Color {
        switch self {
        case .ruby: Color(red: 255 / 255, green: 78 / 255, blue: 107 / 255)
        case .emerald: Color(red: 30 / 255, green: 215 / 255, blue: 96 / 255)
        }
    }

    /// The accent's strong form: Ruby `#FF0436`; Emerald `#18A64A`, a green
    /// deep enough that the white on a button still reads.
    var strong: Color {
        switch self {
        case .ruby: Color(red: 255 / 255, green: 4 / 255, blue: 54 / 255)
        case .emerald: Color(red: 24 / 255, green: 166 / 255, blue: 74 / 255)
        }
    }

    /// The preference's key, for `@AppStorage`.
    static let storageKey = "theme"

    /// Read where it is needed rather than passed down: the palette is
    /// reached from a hundred places that have no reason to know about it.
    static var current: Theme {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Theme.init(rawValue:)) ?? .ruby
    }
}

/// The brand palette: Ruby, unless the theme says otherwise.
///
/// Three colours, and only three: pink, red, white. Everything else on
/// screen is either the artwork's own colour or a shade of white over it,
/// which is the whole trick of the Now Playing screen — the album supplies
/// the hue, the brand supplies the accent, and nothing else is invented.
///
/// `pink` and `red` are the accent's light and strong forms whichever theme
/// is on; the names are the ones they started with.
enum Palette {
    static var pink: Color { Theme.current.light }

    static var red: Color { Theme.current.strong }

    /// `#FFFFFF`
    static let white = Color.white

    /// The ground of the library screens under Emerald, `#121212`. Under Ruby
    /// it is not used: the system's own background stands.
    static let canvas = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)

    /// Light accent into strong, the direction the logo runs.
    static var brand: LinearGradient {
        LinearGradient(
            colors: [pink, red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

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
