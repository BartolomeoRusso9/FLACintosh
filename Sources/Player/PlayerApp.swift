import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PlayerApp: App {
    @State private var model = PlaybackModel()

    init() {
        // Launched by `swift run` there is no bundle, so AppKit starts the
        // process as an accessory: no Dock icon, no window focus. Saying so
        // explicitly is what makes it behave like an app during development.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    // `swift run Player /path/to/track.flac` — during
                    // development the alternative is clicking through an open
                    // panel on every rebuild.
                    if let path = CommandLine.arguments.dropFirst().first {
                        model.open(URL(fileURLWithPath: path))
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openFile() }
                    .keyboardShortcut("o")
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url)
        }
    }
}

struct ContentView: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        // One clock for the whole window. Everything time-dependent reads
        // from here, so the lyrics, the scrubber and the play button can
        // never disagree about what moment it is.
        TimelineView(.animation(paused: !model.isPlaying)) { _ in
            let now = model.currentTime

            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)

                if let lyrics = model.lyrics {
                    LyricsView(lyrics: lyrics, time: now) { model.seek(to: $0) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder
                }

                Divider().opacity(0.5)
                TransportBar(model: model, now: now)
            }
            // The window's own ground. Left to the system so light, dark and
            // reduced-transparency all come out right without a palette of
            // hard-coded greys.
            .background(.background)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.open(url) }
            }
            return true
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.track?.title ?? "No track")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(
                    [model.track?.artist, model.track?.album]
                        .compactMap { $0?.isEmpty == false ? $0 : nil }
                        .joined(separator: " — ")
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let summary = model.track?.formatSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                    .help("Read from the decoder, not guessed from the file extension")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 14)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.track == nil ? "Drop an audio file, or press ⌘O" : "No lyrics for this track")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TransportBar: View {
    @Bindable var model: PlaybackModel
    let now: TimeInterval

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .disabled(model.track == nil)

            Text(Self.clock(now))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            if let duration = model.track?.duration, duration > 0 {
                Slider(
                    value: Binding(
                        get: { min(now, duration) },
                        set: { model.seek(to: $0) }
                    ),
                    in: 0...duration
                )
                Text(Self.clock(duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
            }

            if let source = model.lyricsSource {
                Text(source)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("Where these lyrics came from")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
