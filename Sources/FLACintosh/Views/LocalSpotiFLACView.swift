import AppKit
import SwiftUI

/// SpotiFLAC installed on this Mac: its terminal UI in Terminal if it
/// is there and current, and how to get it — or update it — if not.
///
/// The second way to download, below the server search: for a SpotiFLAC
/// that is not running as a server, or for its full terminal UI.
struct LocalSpotiFLACView: View {
    @Bindable var spotiflac: SpotiFLACBridge
    let library: LibraryStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.red)

            Text("SpotiFLAC on this Mac")
                .font(.system(size: 17, weight: .semibold))

            switch spotiflac.availability {
            case .checking:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the installed version against PyPI…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

            case .available(let version, let path):
                installed(version: version, path: path)

            case .outdated(let installed, let latest, let path, let update):
                outdated(installed: installed, latest: latest, path: path, update: update)

            case .unverified(let installed, let path, let update, let reason):
                unverified(installed: installed, path: path, update: update, reason: reason)

            case .missing:
                missing
            }

            if let error = spotiflac.lastLaunchError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        // Every visit, not once: an update run in Terminal, or a release on
        // PyPI, changes the answer while the app stays open.
        .task { spotiflac.detect() }
        // Coming back from Terminal after updating is the usual way this
        // screen's answer goes stale, so returning to the app re-checks.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            spotiflac.detect()
        }
    }

    private func installed(version: String, path: String) -> some View {
        VStack(spacing: 14) {
            Label("Version \(version) — the latest on PyPI", systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                spotiflac.openTUI(in: library.root)
            } label: {
                Label("Open TUI", systemImage: "terminal")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.red)
            .controlSize(.large)

            // The TUI is a full-screen terminal program; re-implementing
            // it badly inside a window would help nobody.
            Text("Opens in Terminal, in \(library.root.lastPathComponent). Press ⌘R here when it finishes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            pathLabel(path)
        }
    }

    /// Refused, with the one thing that fixes it.
    private func outdated(installed: String, latest: String, path: String, update: String) -> some View {
        VStack(spacing: 14) {
            Label("Update required", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.red)

            Text("Version \(installed) is installed; PyPI has \(latest). SpotiFLAC can only be used here once it is up to date.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            commandBox(update)
            updateButtons
            pathLabel(path)
        }
    }

    private func unverified(installed: String, path: String, update: String, reason: String) -> some View {
        VStack(spacing: 14) {
            Label("Could not check for updates", systemImage: "wifi.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.red)

            Text("Version \(installed) is installed, but PyPI could not be reached (\(reason)). SpotiFLAC can only be used once it is confirmed to be the latest release.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            commandBox(update)
            updateButtons
            pathLabel(path)
        }
    }

    private var updateButtons: some View {
        HStack(spacing: 10) {
            Button {
                spotiflac.openUpdate()
            } label: {
                Label("Update in Terminal", systemImage: "arrow.triangle.2.circlepath")
                    .frame(width: 170)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.red)
            .controlSize(.large)

            Button("Check Again") { spotiflac.detect() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    private var missing: some View {
        VStack(spacing: 14) {
            Text("Not installed — everything else in this app works without it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            commandBox(SpotiFLACBridge.installCommand)

            Text("It downloads lossless audio and writes the word-by-word `.lrc` files this player was built to read.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Check Again") { spotiflac.detect() }
                .buttonStyle(.bordered)
        }
    }

    private func commandBox(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pathLabel(_ path: String) -> some View {
        Text(path)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
    }
}
