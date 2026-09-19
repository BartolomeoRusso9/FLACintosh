import SwiftUI

/// Lays syllables out like text: left to right, wrapping at the edge.
///
/// An `HStack` cannot do this — it never wraps — and a single `Text` can wrap
/// but cannot animate its pieces independently. A line of lyrics needs both,
/// which is what this exists for.
struct SyllableFlow: Layout {
    var lineSpacing: CGFloat = 4

    /// Measuring text is the expensive part, and a line's syllables never
    /// change size while it is on screen — only their fill does. Without
    /// this the active line re-measured every syllable twice per frame.
    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    /// Called on every frame of the sweep, because the active line's views
    /// are rebuilt for each one. Their text is the same, so their sizes are
    /// too: measured again only when the pieces themselves change. Measuring
    /// thirty-point text for every syllable sixty times a second was a
    /// steady load on the Mac for nothing.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        guard cache.sizes.count != subviews.count else { return }
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    /// A piece's size within `maxWidth`.
    ///
    /// Normally the cached single-line size. A piece wider than the whole
    /// row — a line with no word timing, or one enormous word — is given the
    /// row's width instead and wraps inside itself: measured on one line it
    /// forced the flow wider than its column and pushed the rest of Now
    /// Playing out of the window.
    private func size(
        of index: Int,
        within maxWidth: CGFloat,
        subviews: Subviews,
        cache: Cache
    ) -> CGSize {
        let size = cache.sizes[index]
        guard size.width > maxWidth, maxWidth.isFinite else { return size }
        return subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0

        for index in subviews.indices {
            let size = size(of: index, within: maxWidth, subviews: subviews, cache: cache)
            if rowWidth > 0, rowWidth + size.width > maxWidth {
                widest = max(widest, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width
            rowHeight = max(rowHeight, size.height)
        }

        widest = max(widest, rowWidth)
        totalHeight += rowHeight
        return CGSize(
            width: proposal.width ?? widest,
            height: totalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = size(of: index, within: bounds.width, subviews: subviews, cache: cache)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
