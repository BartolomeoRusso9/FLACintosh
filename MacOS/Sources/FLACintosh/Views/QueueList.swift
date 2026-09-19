import SwiftUI

/// What is playing now, and what comes after it.
///
/// In playing order, not the order the queue was handed over: with shuffle
/// on, the two have nothing in common, and a list that does not match what
/// is about to play is worse than none. Sized by whatever holds it: it fills
/// the right-hand column of Now Playing, where it shares the space with the
/// lyrics and only one of the two is up at a time.
struct QueueList: View {
    let model: PlaybackModel

    var body: some View {
        if model.queue.isEmpty {
            Text("Nothing queued")
                .font(.system(size: 12))
                .foregroundStyle(Palette.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let current = model.currentTrack {
                        row(current, isCurrent: true)
                    }
                    ForEach(model.upNextIndices, id: \.self) { index in
                        row(model.queue[index], isCurrent: false)
                            .onTapGesture { model.jump(to: index) }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func row(_ track: LibraryTrack, isCurrent: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                .font(.system(size: 9))
                .foregroundStyle(isCurrent ? Palette.pink : Palette.white.opacity(0.55))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(Palette.white.opacity(isCurrent ? 1 : 0.85))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
