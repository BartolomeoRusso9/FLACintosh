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
    /// The library's titles, each with the artists it is listed under.
    ///
    /// Asked once per result row, and every row is redrawn whenever anything
    /// on the page changes: comparing against the whole library each time —
    /// reducing every title in it to letters and digits, again and again —
    /// made a search freeze a phone with a library of any size. Reduced once
    /// per change to the library instead, and looked up by title.
    private struct Index {
        var revision: Int
        var songs: [String: [String]] = [:]
        var albums: [String: [String]] = [:]
    }

    private static var indexes: [ObjectIdentifier: Index] = [:]

    private static func index(for library: LibraryStore) -> Index {
        let id = ObjectIdentifier(library)
        if let cached = indexes[id], cached.revision == library.revision { return cached }

        var index = Index(revision: library.revision)
        for track in library.tracks {
            index.songs[key(track.title), default: []].append(key(track.artist))
        }
        for album in library.albums {
            index.albums[key(album.title), default: []].append(key(album.artist))
        }
        indexes[id] = index
        return index
    }

    static func hasAlbum(title: String, artist: String, in library: LibraryStore) -> Bool {
        let title = key(title)
        let artist = key(artist)
        guard !title.isEmpty else { return false }
        return index(for: library).albums[title]?.contains { sameArtist($0, artist) } ?? false
    }

    static func hasSong(title: String, artist: String, in library: LibraryStore) -> Bool {
        let title = key(title)
        let artist = key(artist)
        guard !title.isEmpty else { return false }
        return index(for: library).songs[title]?.contains { sameArtist($0, artist) } ?? false
    }

    /// Catalogues list every credited artist, libraries often only the
    /// first: "Artist A, Artist B" matches a library that says "Artist A".
    private static func sameArtist(_ library: String, _ catalogue: String) -> Bool {
        guard !library.isEmpty, !catalogue.isEmpty else { return true }
        return library == catalogue || catalogue.hasPrefix(library) || library.hasPrefix(catalogue)
    }

    static func key(_ text: String) -> String {
        var cleaned = text
        // The searches below are Foundation string searches, slow enough to
        // matter when run over a library: most titles have no brackets and
        // no " - ", which a scan of the bytes finds out first.
        let bytes = cleaned.utf8
        if bytes.contains(where: { $0 == UInt8(ascii: "(") || $0 == UInt8(ascii: "[") }) {
            for (open, close) in [("(", ")"), ("[", "]")] {
                while let start = cleaned.range(of: open),
                      let end = cleaned.range(of: close, range: start.upperBound ..< cleaned.endIndex) {
                    cleaned.removeSubrange(start.lowerBound ..< end.upperBound)
                }
            }
        }
        if cleaned.utf8.contains(UInt8(ascii: "-")), let dash = cleaned.range(of: " - ") {
            cleaned = String(cleaned[..<dash.lowerBound])
        }

        // Plain ASCII, which is nearly every title: lower-cased letters and
        // digits, straight from the bytes. Anything else — accents, other
        // alphabets — takes the full Unicode route below.
        var reduced: [UInt8] = []
        reduced.reserveCapacity(cleaned.utf8.count)
        var isASCII = true
        for byte in cleaned.utf8 {
            switch byte {
            case 0x30 ... 0x39, 0x61 ... 0x7A: reduced.append(byte)
            case 0x41 ... 0x5A: reduced.append(byte | 0x20)
            case 0x80...: isASCII = false
            default: break
            }
            if !isASCII { break }
        }
        if isASCII { return String(decoding: reduced, as: UTF8.self) }

        return cleaned
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
