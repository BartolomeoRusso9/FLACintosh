import SwiftUI

/// Where a record or a track lives: this Mac's folder, or which server.
///
/// Every source is in the library at once, so the same album can sit on the
/// shelf twice — once ripped locally, once on Jellyfin. The label is what
/// tells the two apart. With a single source there is nothing to tell apart,
/// and it stays out of the way.
struct SourceBadge: View {
    let source: LibrarySource
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if library.showsSourceBadges {
            Label(library.name(of: source), systemImage: library.symbol(of: source))
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(tint)
                .background(tint.opacity(0.14), in: Capsule())
                .fixedSize()
                .help(help)
        }
    }

    /// Two colours, not one per source: the question is almost always
    /// "local or server?", and a legend of colours would need learning.
    private var tint: Color {
        source == .folder ? .blue : .orange
    }

    private var help: String {
        switch source {
        case .folder: "On this Mac, in \(library.root.path)"
        case .server: "On the server \(library.name(of: source))"
        }
    }
}
