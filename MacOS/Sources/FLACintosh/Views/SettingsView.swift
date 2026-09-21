import SwiftUI

/// ⌘, — in tabs: how the music sounds, the services it is shared with, and
/// what it keeps on disk.
struct SettingsView: View {
    @Bindable var discord: DiscordPresence
    @Bindable var effects: AudioEffects
    @Bindable var scrobbler: Scrobbler
    let offline: OfflineStore

    var body: some View {
        #if os(macOS)
        TabView {
            PlaybackSettings(effects: effects)
                .tabItem { Label("Playback", systemImage: "play.circle") }
            ServicesSettings(discord: discord, scrobbler: scrobbler)
                .tabItem { Label("Services", systemImage: "antenna.radiowaves.left.and.right") }
            StorageSettings(offline: offline)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 500)
        #else
        // A list of pages, not tabs: this already sits in a tab bar of its own.
        NavigationStack {
            List {
                NavigationLink {
                    PlaybackSettings(effects: effects).navigationTitle("Playback")
                } label: {
                    Label("Playback", systemImage: "play.circle")
                }
                NavigationLink {
                    ServicesSettings(discord: discord, scrobbler: scrobbler).navigationTitle("Services")
                } label: {
                    Label("Services", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    StorageSettings(offline: offline).navigationTitle("Storage")
                } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
                NavigationLink {
                    AppearanceSettings().navigationTitle("Appearance")
                } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }
            }
            .navigationTitle("Settings")
        }
        #endif
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        // Off by default, and it renders an empty cache as "Zero KB".
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Appearance

/// Which accent the app wears, and on what ground.
private struct AppearanceSettings: View {
    @AppStorage(Theme.storageKey) private var themeKey = Theme.ruby.rawValue

    var body: some View {
        Form {
            Section {
                ForEach(Theme.allCases) { theme in
                    Button {
                        themeKey = theme.rawValue
                    } label: {
                        HStack(spacing: 14) {
                            // The two forms of its accent, overlapped: what
                            // the buttons and the highlights will be made of.
                            ZStack {
                                Circle().fill(theme.light).frame(width: 26, height: 26).offset(x: -8)
                                Circle().fill(theme.strong).frame(width: 26, height: 26).offset(x: 8)
                            }
                            .frame(width: 50, height: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.title).font(.system(size: 14, weight: .semibold))
                                Text(theme.summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if themeKey == theme.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.red)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Only the colours change. The app is rebuilt in the new ones as soon as you choose.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

// MARK: - Playback

private struct PlaybackSettings: View {
    @Bindable var effects: AudioEffects
    @AppStorage("showMenuBarPlayer") private var showMenuBarPlayer = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openEqualizer) private var openEqualizer

    var body: some View {
        Form {
            Section {
                Toggle("Gapless playback", isOn: $effects.gapless)
                Picker("ReplayGain", selection: $effects.replayGain) {
                    ForEach(AudioEffects.ReplayGainMode.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Preamp") {
                    HStack {
                        Slider(value: $effects.replayGainPreamp, in: -6 ... 6, step: 0.5)
                            .frame(width: 160)
                        Text(String(format: "%+.1f dB", effects.replayGainPreamp))
                            .monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                    }
                }
                .disabled(effects.replayGain == .off)
                LabeledContent("Equalizer") {
                    HStack {
                        Text(effects.equalizerOn ? (effects.presetName ?? "Manual") : "Off")
                            .foregroundStyle(.secondary)
                        Button("Open Equalizer…") {
                            if let openEqualizer { openEqualizer() } else { openWindow(id: "equalizer") }
                        }
                    }
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("""
                Gapless joins songs without a pause, for live albums and mixes. It \
                applies to files on this Mac and downloaded songs; Crossfade, when on, \
                takes its place. ReplayGain evens out loudness using the tags in your \
                files — Album keeps the differences between songs of the same record.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            #if os(macOS)
            Section {
                Toggle("Show the player in the menu bar", isOn: $showMenuBarPlayer)
            } header: {
                Text("Menu Bar")
            }
            #endif
        }
        .formStyle(.grouped)
        #if os(macOS)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

// MARK: - Services

private struct ServicesSettings: View {
    @Bindable var discord: DiscordPresence
    @Bindable var scrobbler: Scrobbler

    var body: some View {
        Form {
            Section {
                Toggle("Scrobble to Last.fm", isOn: $scrobbler.lastFMOn)
                TextField("API Key", text: $scrobbler.lastFMKey)
                    .disabled(!scrobbler.lastFMOn)
                SecureField("Shared Secret", text: $scrobbler.lastFMSecret)
                    .disabled(!scrobbler.lastFMOn)
                LabeledContent("Account") {
                    HStack(spacing: 8) {
                        StatusDot(connected: scrobbler.lastFMStatus.isConnected, enabled: scrobbler.lastFMOn)
                        Text(scrobbler.lastFMStatus.text)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if scrobbler.lastFMStatus.isConnected {
                            Button("Disconnect") { scrobbler.disconnectLastFM() }
                        } else if scrobbler.lastFMAuthorising {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Connect…") { Task { await scrobbler.connectLastFM() } }
                                .disabled(!scrobbler.lastFMOn || scrobbler.lastFMKey.isEmpty || scrobbler.lastFMSecret.isEmpty)
                        }
                    }
                }
            } header: {
                Text("Last.fm")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create an API account on Last.fm, paste its API key and shared secret, then Connect: Last.fm opens in your browser to approve FLACintosh.")
                    Link("Create a Last.fm API account", destination: URL(string: "https://www.last.fm/api/account/create")!)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Submit listens to ListenBrainz", isOn: $scrobbler.listenBrainzOn)
                SecureField("User Token", text: $scrobbler.listenBrainzToken)
                    .disabled(!scrobbler.listenBrainzOn)
                LabeledContent("Account") {
                    HStack(spacing: 8) {
                        StatusDot(connected: scrobbler.listenBrainzStatus.isConnected, enabled: scrobbler.listenBrainzOn)
                        Text(scrobbler.listenBrainzStatus.text)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if scrobbler.pendingCount > 0 {
                    LabeledContent("Waiting to send") {
                        HStack {
                            Text("\(scrobbler.pendingCount)")
                                .monospacedDigit()
                            Button("Retry Now") { scrobbler.flush() }
                        }
                    }
                }
            } header: {
                Text("ListenBrainz")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A song is scrobbled once you have heard half of it or four minutes — the same rule as the Recap. Scrobbles that cannot be sent are kept and retried.")
                    Link("Find your ListenBrainz token", destination: URL(string: "https://listenbrainz.org/settings/")!)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            #if os(macOS)
            Section {
                Toggle("Show what you're listening to", isOn: $discord.enabled)
                TextField("Application ID", text: $discord.applicationID, prompt: Text("e.g. 1234567890123456789"))
                    .disabled(!discord.enabled)
                Toggle("Show album art", isOn: $discord.showArtwork)
                    .disabled(!discord.enabled)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        StatusDot(connected: discordConnected, enabled: discord.enabled)
                        Text(discord.status.text)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } header: {
                Text("Discord")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("""
                    Create an application in the Discord Developer Portal — its name is \
                    what Discord shows, so call it FLACintosh — and paste its Application \
                    ID here. The Discord desktop app has to be running. Album art is \
                    looked up on Apple Music by artist and album, because Discord can \
                    only show a picture with a public address.
                    """)
                    Link("Open the Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(height: 620)
        #endif
    }

    private var discordConnected: Bool {
        if case .connected = discord.status { return true }
        return false
    }
}

private struct StatusDot: View {
    let connected: Bool
    let enabled: Bool

    var body: some View {
        Circle()
            .fill(connected ? Color.green : (enabled ? Color.orange : Color.secondary))
            .frame(width: 7, height: 7)
    }
}

// MARK: - Storage

private struct StorageSettings: View {
    let offline: OfflineStore

    @State private var limited = RemoteCache.limit > 0
    @State private var gigabytes = Double(RemoteCache.limit) / 1_073_741_824
    @State private var usage: Int64 = 0
    @State private var confirmingRemoveAll = false

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.minimum = 0.1
        formatter.maximum = 2000
        return formatter
    }()

    var body: some View {
        Form {
            Section {
                LabeledContent("Downloaded") {
                    Text("\(offline.albumCount) \(offline.albumCount == 1 ? "album" : "albums") · \(SettingsView.size(offline.size))")
                        .monospacedDigit()
                }
                if let error = offline.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.red)
                }
                Button("Remove All Downloads…", role: .destructive) { confirmingRemoveAll = true }
                    .disabled(offline.albumCount == 0 && offline.progress.isEmpty)
            } header: {
                Text("Offline Downloads")
            } footer: {
                Text("Download a server album from its page, with the ••• button. Downloaded albums play without the server and are listed under Downloaded in the sidebar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Limit the cache", isOn: $limited)
                    .onChange(of: limited) { _, on in
                        RemoteCache.limit = on ? bytes : 0
                        if on { RemoteCache.enforceLimit() }
                        refresh()
                    }

                // `LabeledContent` rather than an `HStack`: in a Form the
                // stack hands the whole width to the controls and the label
                // wraps to one letter per line.
                LabeledContent("Maximum") {
                    HStack(spacing: 6) {
                        TextField("", value: $gigabytes, formatter: Self.formatter)
                            .labelsHidden()
                            .frame(width: 62)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(apply)
                        Text("GB")
                            .foregroundStyle(.secondary)
                        Stepper("") {
                            gigabytes += 1
                            apply()
                        } onDecrement: {
                            gigabytes = max(0.1, gigabytes - 1)
                            apply()
                        }
                        .labelsHidden()
                    }
                }
                .disabled(!limited)

                LabeledContent("In use") {
                    HStack(spacing: 8) {
                        Text(SettingsView.size(usage))
                            .monospacedDigit()
                        if limited, bytes > 0 {
                            ProgressView(value: min(1, Double(usage) / Double(bytes)))
                                .frame(width: 90)
                                .tint(Double(usage) / Double(bytes) > 0.9 ? Palette.red : Palette.pink)
                        }
                    }
                }

                Button("Empty Cache Now") {
                    RemoteCache.empty()
                    refresh()
                }
                .disabled(usage == 0)
            } header: {
                Text("Server Track Cache")
            } footer: {
                // Worth saying why the cache exists at all, or a 2 GB folder
                // of audio looks like a bug.
                Text("""
                Tracks from Navidrome and Jellyfin stream. What is kept is the \
                part of each file with its tags, lyrics and cover — usually a \
                megabyte or two — plus whole tracks in formats that cannot \
                stream. The least recently played are dropped first. Downloads \
                are separate and never removed on their own.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .fixedSize(horizontal: false, vertical: true)
        #endif
        .onAppear(perform: refresh)
        .confirmationDialog("Remove all downloaded music?", isPresented: $confirmingRemoveAll) {
            Button("Remove All Downloads", role: .destructive) { offline.removeAll() }
        } message: {
            Text("The albums stay on your servers and can be downloaded again.")
        }
    }

    private var bytes: Int64 {
        Int64(max(0.1, gigabytes) * 1_073_741_824)
    }

    private func apply() {
        guard limited else { return }
        RemoteCache.limit = bytes
        RemoteCache.enforceLimit()
        refresh()
    }

    private func refresh() {
        usage = RemoteCache.size()
    }
}
