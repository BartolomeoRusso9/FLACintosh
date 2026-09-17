import Observation
import SwiftUI

/// The little bit of navigation state that outlives a single view.
///
/// "Am I showing Now Playing" is a property of the window, not of the
/// library screen inside it: the transport bar sits in a `safeAreaInset`
/// below the split view and has to be able to raise it.
@MainActor
@Observable
final class AppRoute {
    static let mainWindow = "library"

    var showingNowPlaying = false
}
