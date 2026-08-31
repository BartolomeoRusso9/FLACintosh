import SwiftUI

/// Lays syllables out like text: left to right, wrapping at the edge.
///
/// An `HStack` cannot do this — it never wraps — and a single `Text` can wrap
/// but cannot animate its pieces independently. A line of lyrics needs both,
/// which is what this exists for.
struct SyllableFlow: Layout {
    var lineSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
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
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
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
