import UIKit

/// Asks iOS for a little more time when the app goes to the background in the middle of
/// long work, such as reading capture dates, so the current files finish and are saved.
@MainActor
final class BackgroundWork {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
