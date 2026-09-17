import Foundation

/// Whether the library already has a record or a song found elsewhere — a
/// catalogue search, say, where nothing shares an identifier with the files.
///
/// Same title and artist once both are reduced to their letters and digits,
/// with the edition notes a catalogue adds — "(Remastered 2011)",
/// "[Deluxe]", "- Single" — dropped. Deliberately forgiving: a wrong "In
/// Library" costs a click to download anyway, a missed one a duplicate.
@MainActor
enum LibraryMatch {
    static func hasAlbum(title: String, artist: String, in library: LibraryStore) -> Bool {
        let title = key(title)
        let artist = key(artist)
        guard !title.isEmpty else { return false }
        return library.albums.contains {
            key($0.title) == title && sameArtist(key($0.artist), artist)
        }
    }

    static func hasSong(title: String, artist: String, in library: LibraryStore) -> Bool {
        let title = key(title)
        let artist = key(artist)
        guard !title.isEmpty else { return false }
        return library.songs.contains {
            key($0.title) == title && sameArtist(key($0.artist), artist)
        }
    }

    /// Catalogues list every credited artist, libraries often only the
    /// first: "Artist A, Artist B" matches a library that says "Artist A".
    private static func sameArtist(_ library: String, _ catalogue: String) -> Bool {
        guard !library.isEmpty, !catalogue.isEmpty else { return true }
        return library == catalogue || catalogue.hasPrefix(library) || library.hasPrefix(catalogue)
    }

    static func key(_ text: String) -> String {
        var cleaned = text
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = cleaned.range(of: open),
                  let end = cleaned.range(of: close, range: start.upperBound ..< cleaned.endIndex) {
                cleaned.removeSubrange(start.lowerBound ..< end.upperBound)
            }
        }
        if let dash = cleaned.range(of: " - ") {
            cleaned = String(cleaned[..<dash.lowerBound])
        }
        return cleaned
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
