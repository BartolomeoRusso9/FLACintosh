import Foundation
import Observation

#if !os(macOS)
/// Nothing to bridge to: SpotiFLAC's own command line lives on a computer, and
/// an iPhone cannot run it. Downloads go through the server, as they do from
/// the Mac. The type exists so the screens that hold one need no `#if` of
/// their own.
@MainActor
@Observable
final class SpotiFLACBridge {}
#else

/// Optional glue to SpotiFLAC, the downloader this player was built to sit
/// next to.
///
/// Optional in the strict sense: nothing here is required for the app to
/// work, nothing is bundled, and if the tool is not installed the app says
/// how to install it and otherwise carries on. When it *is* installed, its
/// terminal UI is one click away and its downloads land in the
/// library folder — which is also where its `--save-lrc` sidecars go, so a
/// track downloaded through it arrives with word-by-word lyrics already
/// beside it.
///
/// Only the release on PyPI is usable. SpotiFLAC talks to services that
/// change under it, and an old install fails in ways that look like this
/// app's fault — so an outdated copy, or one whose version cannot be checked
/// against PyPI, is refused until it is updated.
@MainActor
@Observable
final class SpotiFLACBridge {
    enum Availability: Equatable {
        case checking
        case missing
        /// Installed and the same as PyPI's latest release, or newer.
        case available(version: String, path: String)
        /// Installed, but PyPI has a newer release.
        case outdated(installed: String, latest: String, path: String, update: String)
        /// Installed, but PyPI could not be asked — so it cannot be shown to
        /// be current either.
        case unverified(installed: String, path: String, update: String, reason: String)
    }

    private(set) var availability: Availability = .checking
    private(set) var lastLaunchError: String?

    /// Read from the detached lookup too, so not tied to the main actor.
    nonisolated static let packageName = "SpotiFLAC"
    static let installCommand = "pip install --upgrade SpotiFLAC"

    private static let pypiURL = URL(string: "https://pypi.org/pypi/SpotiFLAC/json")!

    @ObservationIgnored private var check: Task<Void, Never>?

    func detect() {
        check?.cancel()
        check = Task { await refresh() }
    }

    /// Hands the terminal UI to Terminal, in the library folder.
    ///
    /// `--tui`, not `--interactive`: the older flag is a deprecated alias
    /// that now opens the same thing and prints a warning first. The TUI is
    /// a full-screen terminal program — it belongs in a terminal, not
    /// re-implemented badly inside a window.
    /// Starting it in the library folder means what it downloads is already
    /// where ⌘R will find it.
    ///
    /// The version is checked again first, not taken from when the screen
    /// was opened: a release can land on PyPI while the window sits there.
    func openTUI(in folder: URL) {
        check?.cancel()
        check = Task {
            await refresh()
            guard case .available(_, let path) = availability else { return }
            runInTerminal("cd \(shellQuoted(folder.path)) && \(shellQuoted(path)) --tui")
        }
    }

    /// Runs the update in Terminal, with the Python SpotiFLAC is installed
    /// under — not whichever `pip` happens to be first on the PATH, which
    /// can update a different copy and leave this one exactly as old.
    func openUpdate() {
        switch availability {
        case .outdated(_, _, _, let update), .unverified(_, _, let update, _):
            runInTerminal(update)
        default:
            break
        }
    }

    private func refresh() async {
        availability = .checking
        lastLaunchError = nil

        async let installedLookup = Self.locate()
        async let latestLookup = Self.latestRelease()
        let (installed, latest) = await (installedLookup, latestLookup)
        guard !Task.isCancelled else { return }

        guard let installed else {
            availability = .missing
            return
        }

        switch latest {
        case .failure(let error):
            availability = .unverified(
                installed: installed.version,
                path: installed.path,
                update: installed.update,
                reason: error.localizedDescription
            )
        case .success(let latest):
            if Self.isAtLeast(installed.version, latest) {
                availability = .available(version: installed.version, path: installed.path)
            } else {
                availability = .outdated(
                    installed: installed.version,
                    latest: latest,
                    path: installed.path,
                    update: installed.update
                )
            }
        }
    }

    private func runInTerminal(_ command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            lastLaunchError = error.localizedDescription
        }
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - PyPI

    private struct Release: Decodable {
        struct Info: Decodable { let version: String }
        let info: Info
    }

    private enum CheckError: LocalizedError {
        case unreadable
        var errorDescription: String? { "PyPI sent something that is not a release" }
    }

    private static func latestRelease() async -> Result<String, Error> {
        var request = URLRequest(url: pypiURL)
        request.timeoutInterval = 10
        // PyPI's JSON is cached at its CDN; asking for a fresh copy means a
        // release published a minute ago counts.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CheckError.unreadable }
            return .success(try JSONDecoder().decode(Release.self, from: data).info.version)
        } catch {
            return .failure(error)
        }
    }

    /// Whether `installed` is `latest` or newer, compared number by number:
    /// as strings "4.10.0" sorts before "4.9.0".
    nonisolated static func isAtLeast(_ installed: String, _ latest: String) -> Bool {
        let a = numbers(installed)
        let b = numbers(latest)
        for index in 0 ..< max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    /// "4.1.7" → [4, 1, 7]; a suffix such as "rc1" is ignored.
    nonisolated private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    // MARK: - Finding it

    private static func locate() async -> (path: String, version: String, update: String)? {
        await Task.detached(priority: .userInitiated) {
            // A login shell, not this process's PATH: an app started from
            // Finder inherits almost nothing, and SpotiFLAC lives wherever
            // the user's Python does — Homebrew, pyenv, a virtualenv.
            guard let path = run("/bin/zsh", ["-lc", "command -v spotiflac"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else { return nil }

            // The CLI has no `--version` (it prints usage and exits 2), so
            // the installed distribution is asked instead — by the Python
            // the script actually runs under, named on its first line. A
            // bare `python3` can be another interpreter entirely, with
            // another copy of SpotiFLAC or none.
            let python = interpreter(of: path)
            let version = python.flatMap {
                run($0[0], Array($0.dropFirst()) + [
                    "-c", #"import importlib.metadata as m; print(m.version("SpotiFLAC"))"#,
                ])
            }?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? run("/bin/zsh", [
                    "-lc", #"python3 -c 'import importlib.metadata as m; print(m.version("SpotiFLAC"))'"#,
                ])?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""

            let pythonCommand = python?.map(quoted).joined(separator: " ") ?? "python3"
            return (
                path,
                version.isEmpty ? "0" : version,
                "\(pythonCommand) -m pip install --upgrade \(packageName)"
            )
        }.value
    }

    /// The interpreter from a script's `#!` line, as an executable and its
    /// arguments — `/usr/bin/env python3` included.
    nonisolated private static func interpreter(of script: String) -> [String]? {
        guard
            let handle = FileHandle(forReadingAtPath: script),
            let head = try? handle.read(upToCount: 512),
            let text = String(data: head, encoding: .utf8),
            text.hasPrefix("#!"),
            let line = text.dropFirst(2).split(separator: "\n").first
        else { return nil }
        let parts = line.split(separator: " ").map(String.init)
        return parts.isEmpty ? nil : parts
    }

    nonisolated private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
