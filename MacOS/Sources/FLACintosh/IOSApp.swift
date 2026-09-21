#if os(iOS)
import AVFoundation
import SwiftUI

/// The iPhone and iPad entry point. It builds the same models the Mac app
/// does and hands them to the same `RootView`; what differs is only what a
/// phone has no use for — no menu bar, no menu commands, no second window.
@main
struct FLACintoshIOSApp: App {
    @State private var model = PlaybackModel()
    @State private var library = LibraryStore()
    @State private var spotiflac = SpotiFLACBridge()
    @State private var spotiflacServer = SpotiFLACServer()
    @State private var route = AppRoute()
    /// The lock screen, Control Center and the headphone buttons.
    @State private var nowPlaying = SystemNowPlaying()
    @State private var history = ListeningHistory()
    @State private var playlists = PlaylistStore()
    @State private var offline = OfflineStore()
    @State private var effects = AudioEffects()
    @State private var scrobbler = Scrobbler()
    /// Only so the shared Settings screen has one to bind to: it is never
    /// attached to the player on iOS, and the Discord section is not shown.
    @State private var discord = DiscordPresence()
    @State private var showingEqualizer = false

    init() {
        // Playback, not ambient: the music keeps going with the screen locked
        // and the silent switch on, which is what a music player is for. The
        // `audio` background mode in Info.plist is the other half of this.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                model: model,
                library: library,
                spotiflac: spotiflac,
                spotiflacServer: spotiflacServer,
                route: route,
                history: history,
                settings: AnyView(SettingsView(discord: discord, effects: effects, scrobbler: scrobbler, offline: offline))
            )
                .environment(playlists)
                .environment(offline)
                // The Mac opens the equalizer as a window; a phone raises it
                // over whatever is on screen.
                .environment(\.openEqualizer, { showingEqualizer = true })
                .sheet(isPresented: $showingEqualizer) {
                    NavigationStack {
                        ScrollView {
                            EqualizerView(effects: effects)
                        }
                        .navigationTitle("Equalizer")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingEqualizer = false }
                            }
                        }
                    }
                    .presentationDetents([.large])
                }
                .onAppear {
                    library.rescanIfNeeded()
                    model.moreToPlay = { library.songs.shuffled() }
                    spotiflacServer.onDownloadFinished = { library.refreshAfterDownload() }
                    nowPlaying.attach(to: model)
                    history.attach(to: model)
                    model.attachEffects(effects)
                    scrobbler.attach(to: model, history: history)
                    model.localCopy = { [offline] url in offline.localFile(for: url) }
                }
        }
    }
}
#endif
