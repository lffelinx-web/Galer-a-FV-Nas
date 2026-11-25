import BackgroundTasks
import Foundation

/// Work iOS lets the app do while it is closed, usually at night with the iPhone charging:
/// reading capture dates (and, later, the backup to the NAS).
enum BackgroundJobs {
    static let identifier = "com.lfaz.galeria.trabajo"

    /// Must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in
                let work = Task { await GalleryStore.shared.backgroundWork() }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
                schedule()
            }
        }
    }

    /// Asks for the next window: with a network and, to spare the battery, while charging.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
