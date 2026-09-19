import Foundation
import Security

/// Whether macOS is about to ask for the Mac's password before handing over
/// a saved server password.
///
/// The login keychain gives an item to the apps on its access list, and it
/// lists apps by their code signature — for an app signed ad hoc, the cdhash,
/// which changes with every build. A copy the keychain has not seen gets a
/// system prompt. There is no way to ask the keychain beforehand whether it
/// will prompt: both "fail instead of asking" options still show the dialog
/// for these items. So the app keeps its own note instead — the cdhash of
/// the copy that last read or saved a password — and a different one means
/// macOS will ask.
enum KeychainSignature {
    private static let defaultsKey = "keychainReaderSignature"

    /// This copy's cdhash, as the keychain's access list records it.
    static let current: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }()

    /// True when this copy is not the one that last used the passwords.
    static var mayAsk: Bool {
        guard let current else { return true }
        return UserDefaults.standard.string(forKey: defaultsKey) != current
    }

    /// This copy has just been handed a password, or saved one — either way
    /// it is on the item's list now.
    static func remember() {
        guard let current else { return }
        UserDefaults.standard.set(current, forKey: defaultsKey)
    }
}
