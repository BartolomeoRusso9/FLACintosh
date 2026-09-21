import SFBAudioEngine
import SwiftUI

/// Editing what a file says about itself.
///
/// Writes straight into the file's tags — the library has no database to
/// update, so once the tag is written a rescan is the whole refresh.
/// Local files only: a track on a server is somebody else's to edit.
struct MetadataEditor: View {
    let track: LibraryTrack
    let onSaved: () -> Void
    let onClose: () -> Void

    @State private var fields = Fields()
    @State private var loaded = false
    @State private var saving = false
    @State private var problem: String?

    struct Fields: Equatable {
        var title = ""
        var artist = ""
        var albumArtist = ""
        var album = ""
        var genre = ""
        var year = ""
        var trackNumber = ""
        var discNumber = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Get Info")
                .font(.system(size: 18, weight: .bold))
            Text(track.url.lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Form {
                TextField("Title", text: $fields.title)
                TextField("Artist", text: $fields.artist)
                TextField("Album Artist", text: $fields.albumArtist)
                TextField("Album", text: $fields.album)
                TextField("Genre", text: $fields.genre)
                HStack {
                    TextField("Year", text: $fields.year)
                    TextField("Track", text: $fields.trackNumber)
                    TextField("Disc", text: $fields.discNumber)
                }
            }
            .formStyle(.grouped)
            .disabled(!loaded || saving)

            if let problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", action: onClose)
                Spacer()
                Button(saving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.red)
                    .disabled(!loaded || saving)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 430)
        #endif
        .task { load() }
    }

    /// Read from the file rather than from the library row: the row holds
    /// what the scanner cared about, and this edits everything.
    private func load() {
        guard track.url.isFileURL else {
            problem = "This track is on a server — its tags are not yours to edit"
            return
        }
        guard let file = try? AudioFile(readingPropertiesAndMetadataFrom: track.url) else {
            problem = "Could not read this file's tags"
            return
        }
        let metadata = file.metadata
        fields = Fields(
            title: metadata.title ?? "",
            artist: metadata.artist ?? "",
            albumArtist: metadata.albumArtist ?? "",
            album: metadata.albumTitle ?? "",
            genre: metadata.genre ?? "",
            year: metadata.releaseDate ?? "",
            trackNumber: metadata.trackNumber.map(String.init) ?? "",
            discNumber: metadata.discNumber.map(String.init) ?? ""
        )
        loaded = true
    }

    private func save() {
        saving = true
        problem = nil
        let url = track.url
        let fields = fields

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
                    let metadata = file.metadata
                    // Empty means "remove the tag", which is what an emptied
                    // field is asking for.
                    metadata.title = fields.title.nilIfEmpty
                    metadata.artist = fields.artist.nilIfEmpty
                    metadata.albumArtist = fields.albumArtist.nilIfEmpty
                    metadata.albumTitle = fields.album.nilIfEmpty
                    metadata.genre = fields.genre.nilIfEmpty
                    metadata.releaseDate = fields.year.nilIfEmpty
                    metadata.trackNumber = Int(fields.trackNumber)
                    metadata.discNumber = Int(fields.discNumber)
                    try file.writeMetadata()
                }.value
                saving = false
                onSaved()
                onClose()
            } catch {
                saving = false
                problem = error.localizedDescription
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
