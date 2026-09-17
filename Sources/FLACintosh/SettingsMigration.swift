import Foundation

/// Brings settings over from the unbundled builds, once.
///
/// `swift run` starts a bare executable, and a bare executable keeps its
/// preferences under its own name. The packaged app keeps them under its
/// bundle identifier instead — so without this, the first launch of the app
/// would come up with no servers, the default folder and every view choice
/// forgotten.
///
/// The executable has had more than one name: it was `Flacintosh` before it
/// became `FLACintosh`. Each earlier name is a domain settings may still be
/// sitting in, and a development build under the new name reads them too —
/// otherwise renaming the target would quietly forget the servers.
///
/// Passwords are not part of it: they are in the keychain, keyed by server,
/// and the app finds them there on its own.
enum SettingsMigration {
    /// The names settings may have been saved under, newest first.
    private static let developmentDomains = ["FLACintosh", "Flacintosh"]
    private static let doneKey = "importedDevelopmentSettings"

    /// Everything the app stores. Listed rather than copied wholesale: a
    /// domain also carries AppKit's own window and panel state, which is
    /// no business of the new app's.
    private static let keys = [
        "musicServers", "hiddenSources", "libraryRoot",
        "autoPlay", "crossfade", "remoteCacheLimitBytes",
        "spotiflacAddress",
    ]
    private static let prefixes = ["view."]

    static func importDevelopmentSettings() -> Bool {
        // Unbundled, the standard domain is the executable's own name.
        let current = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return false }
        defaults.set(true, forKey: doneKey)

        var imported = false
        for domain in developmentDomains where domain != current {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old
            where keys.contains(key) || prefixes.contains(where: key.hasPrefix) {
                // Whatever the app has already set wins — and so does a newer
                // name, which comes first in the list.
                guard defaults.object(forKey: key) == nil else { continue }
                defaults.set(value, forKey: key)
                imported = true
            }
        }
        return imported
    }
}
