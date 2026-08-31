import SwiftUI
import SyncedLyrics

/// The reason this project exists: lyrics that light up one syllable at a
/// time, from a local file.
///
/// The effect is not "colour the current word". Each syllable fills across
/// its own duration, so the light travels *through* a long word, and the
/// lines around the current one recede rather than disappear. That
/// continuous fill is what the eye reads as following the voice.
struct LyricsView: View {
    let lyrics: TimedLyrics
    let time: TimeInterval
    let onSeek: (TimeInterval) -> Void

    private var activeIndex: Int? { lyrics.lineIndex(at: time) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    // Breathing room so the first and last lines can still
                    // settle in the middle of the view.
                    Color.clear.frame(height: 120)
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        LyricLineView(
                            line: line,
                            time: time,
                            distance: activeIndex.map { index - $0 }
                        )
                        .id(line.id)
                        .contentShape(Rectangle())
                        .onTapGesture { onSeek(line.start) }
                    }
                    Color.clear.frame(height: 260)
                }
                .padding(.horizontal, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                    proxy.scrollTo(lyrics.lines[index].id, anchor: .center)
                }
            }
        }
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    let time: TimeInterval
    /// Lines from the active one: 0 is current, negative is past.
    let distance: Int?

    private var isActive: Bool { distance == 0 }

    /// Sung lines dim but stay legible; lines still to come fade further the
    /// further off they are, and blur slightly — that depth is most of what
    /// makes the current line read as current.
    private var dimming: Double {
        guard let distance else { return 0.35 }
        if distance == 0 { return 1 }
        if distance < 0 { return 0.28 }
        return max(0.16, 0.55 - Double(distance) * 0.09)
    }

    private var blur: Double {
        guard let distance, distance != 0 else { return 0 }
        return min(2.2, Double(abs(distance)) * 0.7)
    }

    var body: some View {
        SyllableFlow(lineSpacing: 2) {
            ForEach(Array(line.syllables.enumerated()), id: \.offset) { _, syllable in
                SyllableText(
                    syllable: syllable,
                    progress: isActive ? syllable.progress(at: time) : (isSung ? 1 : 0),
                    emphasise: isActive
                )
            }
        }
        .font(.system(size: 30, weight: .bold, design: .rounded))
        .opacity(dimming)
        .blur(radius: blur)
        .scaleEffect(isActive ? 1 : 0.94, anchor: .leading)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isActive)
    }

    private var isSung: Bool { (distance ?? 0) < 0 }
}

private struct SyllableText: View {
    let syllable: Syllable
    let progress: Double
    let emphasise: Bool

    /// The soft edge of the sweep. A hard cut looks like a progress bar; a
    /// short gradient looks like light moving across the letters.
    private static let feather = 0.12

    var body: some View {
        Text(syllable.text)
            .foregroundStyle(.tertiary)
            .overlay(alignment: .leading) {
                Text(syllable.text)
                    .foregroundStyle(.primary)
                    .mask(alignment: .leading) {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: max(0, progress - Self.feather)),
                                .init(color: .clear, location: min(1, progress + Self.feather)),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
            }
            // A syllable lifts as it is sung and settles back. Small on
            // purpose: at this size anything more reads as a bounce.
            .scaleEffect(emphasise && progress > 0 && progress < 1 ? 1.045 : 1)
            .offset(y: emphasise && progress > 0 && progress < 1 ? -1.5 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: progress > 0)
    }
}
