import Foundation
import Network
import Photos

/// Copies the photos and videos taken after the backup was turned on to the NAS, in their
/// original format, into `Respaldo iPhone/año/mes`. It only reads the iPhone library and
/// only adds files on the NAS: nothing is deleted or replaced on either side.
@MainActor
final class PhoneBackup: ObservableObject {
    static let shared = PhoneBackup()

    /// A photo in the backup list: the one uploading, or one copied or failed lately.
    struct Entry: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var bytes: Int64?
        var date: Date
        /// Why it could not be copied; nil when it was.
        var failure: String?
    }

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "backupEnabled")
    @Published private(set) var paused = UserDefaults.standard.bool(forKey: "backupPaused")
    @Published var useCellular = UserDefaults.standard.bool(forKey: "backupCellular") {
        didSet {
            UserDefaults.standard.set(useCellular, forKey: "backupCellular")
            if useCellular { start() }
        }
    }
    @Published private(set) var running = false
    /// «Subiendo 3 de 12».
    @Published private(set) var progress: String?
    /// The photo going up now and how much of it has been sent (0…1).
    @Published private(set) var current: Entry?
    @Published private(set) var currentFraction = 0.0
    /// The next ones in line (only the first few, for the list).
    @Published private(set) var queue: [String] = []
    @Published private(set) var recent: [Entry] = Files.load("backup-recent.json", as: [Entry].self) ?? []
    @Published private(set) var pending = 0
    @Published private(set) var copied = UserDefaults.standard.integer(forKey: "backupCopied")
    @Published private(set) var lastCopy = UserDefaults.standard.object(forKey: "backupLast") as? Date
    /// Why it stopped, when it did not finish.
    @Published private(set) var problem: String?
    @Published private(set) var since = UserDefaults.standard.object(forKey: "backupSince") as? Date

    private var baseline: Set<String> = Files.load("backup-baseline.json", as: Set<String>.self) ?? []
    private var done: Set<String> = Files.load("backup-done.json", as: Set<String>.self) ?? []
    private var task: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private var expensive = false
    private var online = true

    private init() {
        monitor.pathUpdateHandler = { path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAllowed = self.networkAllowed
                self.expensive = path.isExpensive
                self.online = path.status == .satisfied
                if !wasAllowed && self.networkAllowed { self.start() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "lfaz.galeria.respaldo.red"))
    }

    private var networkAllowed: Bool { online && (useCellular || !expensive) }

    /// The line shown in Espacio and Configuración.
    var summary: String {
        if !enabled { return "Apagado" }
        if paused { return pending > 0 ? "En pausa · " + countText(pending, "pendiente", "pendientes") : "En pausa" }
        if running { return progress ?? "Revisando fotos nuevas…" }
        if let problem { return problem }
        if pending > 0 { return countText(pending, "pendiente", "pendientes") + (networkAllowed ? "" : " · esperando Wi‑Fi") }
        if let lastCopy { return "Al día · " + lastCopy.formatted(.relative(presentation: .named)) }
        return "Al día"
    }

    /// Turning it on remembers everything already in the library, so only what comes after
    /// is copied (the earlier photos are already on the NAS).
    func setEnabled(_ on: Bool) async {
        if on && since == nil {
            let all = await Task.detached(priority: .userInitiated) { Self.assetIDs(excluding: []) }.value
            baseline = Set(all)
            let saved = baseline
            Task.detached(priority: .utility) { try? Files.save(saved, name: "backup-baseline.json") }
            let now = Date()
            since = now
            UserDefaults.standard.set(now, forKey: "backupSince")
        }
        enabled = on
        UserDefaults.standard.set(on, forKey: "backupEnabled")
        if on { start() } else { task?.cancel() }
    }

    func setPaused(_ value: Bool) {
        paused = value
        UserDefaults.standard.set(value, forKey: "backupPaused")
        if value { task?.cancel() } else { start() }
    }

    /// Starts copying what is pending, if it is on, the NAS is set up and the network allows it.
    func start() {
        guard enabled, !paused, task == nil, let account = ActiveAccount.current, PhoneLibrary.access == .full else { return }
        guard networkAllowed else { Task { await countPending() }; return }
        task = Task { await run(account) }
    }

    /// For the time iOS gives at night: copy until done or until the time runs out.
    func runNow() async {
        start()
        let running = task
        await withTaskCancellationHandler { await running?.value } onCancel: { running?.cancel() }
    }

    var hasPending: Bool { enabled && !paused && pending > 0 }

    private func countPending() async {
        let skip = baseline.union(done)
        let ids = await Task.detached(priority: .utility) { Self.assetIDs(excluding: skip) }.value
        pending = ids.count
        queue = Array(ids.prefix(40))
    }

    private func remember(_ entry: Entry) {
        recent.insert(entry, at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
        let saved = recent
        Task.detached(priority: .utility) { try? Files.save(saved, name: "backup-recent.json") }
    }

    private func run(_ account: NASAccount) async {
        running = true
        problem = nil
        let work = BackgroundWork(name: "Respaldo en el NAS")
        defer { work.end(); running = false; progress = nil; current = nil; currentFraction = 0; task = nil }
        let skip = baseline.union(done)
        let ids = await Task.detached(priority: .utility) { Self.assetIDs(excluding: skip) }.value
        pending = ids.count
        queue = Array(ids.prefix(40))
        guard !ids.isEmpty else { return }
        let uploader = BackupUploader(account: account)
        var unreadable = 0
        for (position, id) in ids.enumerated() {
            guard !Task.isCancelled, enabled, !paused else { return }
            guard networkAllowed else { return }
            queue = Array(ids.dropFirst(position + 1).prefix(40))
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                pending -= 1; continue
            }
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Foto"
            current = Entry(id: id, name: name, bytes: nil, date: Date())
            currentFraction = 0
            progress = "Subiendo \(position + 1) de \(ids.count)"
            do {
                let result = try await uploader.copy(asset) { sent, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.current?.id == id, total > 0 else { return }
                        let fraction = min(1, Double(sent) / Double(total))
                        if self.current?.bytes != total { self.current?.bytes = total }
                        if fraction - self.currentFraction >= 0.02 || fraction == 1 { self.currentFraction = fraction }
                    }
                }
                // On the NAS tab right away, on the day it was taken.
                GalleryStore.shared.addBackedUp(result.files, folder: result.folder, date: asset.creationDate ?? Date(),
                                                aspect: asset.pixelHeight > 0 ? Double(asset.pixelWidth) / Double(asset.pixelHeight) : 1,
                                                duration: asset.mediaType == .video ? asset.duration : nil)
                done.insert(id)
                let saved = done
                Task.detached(priority: .utility) { try? Files.save(saved, name: "backup-done.json") }
                pending -= 1
                copied += 1
                lastCopy = Date()
                UserDefaults.standard.set(copied, forKey: "backupCopied")
                UserDefaults.standard.set(lastCopy, forKey: "backupLast")
                remember(Entry(id: id, name: name, bytes: result.bytes, date: Date()))
                unreadable = 0
            } catch is CancellationError {
                return
            } catch BackupError.unreadable {
                // Usually a photo still in iCloud that could not be downloaded: tried again next time.
                unreadable += 1
                remember(Entry(id: id, name: name, bytes: nil, date: Date(), failure: "No se pudo leer de iCloud; se intentará más tarde"))
                if unreadable >= 5 { problem = "No se pudieron leer algunas fotos de iCloud; se intentará más tarde."; return }
            } catch let error as GalleryError {
                problem = error.localizedDescription
                remember(Entry(id: id, name: name, bytes: nil, date: Date(), failure: error.localizedDescription))
                return
            } catch {
                if Task.isCancelled { return }
                problem = "En pausa: se reanudará cuando el NAS responda."
                return
            }
        }
    }

    /// Photos and videos of the library, oldest first, minus the given ones.
    nonisolated static func assetIDs(excluding skip: Set<String>) -> [String] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var ids: [String] = []
        result.enumerateObjects { asset, _, _ in
            if !skip.contains(asset.localIdentifier) { ids.append(asset.localIdentifier) }
        }
        return ids
    }
}

/// A file the backup left on the NAS, as the NAS lists it.
struct BackedUpFile {
    let url: URL
    let name: String
    let bytes: Int64?
}

enum BackupError: Error {
    case unreadable
    /// The name was taken on the NAS between the check and the copy: tried again later.
    case taken
}

/// Copies the original files of one photo or video: the photo, its Live Photo video, the
/// RAW of a RAW+JPEG and the unedited video, never the edited versions.
final class BackupUploader: @unchecked Sendable {
    private let account: NASAccount
    private let transport: NASTransport
    private var ready: Set<String> = []

    init(account: NASAccount) {
        self.account = account
        transport = NASTransport(account)
    }

    /// The files now on the NAS for this photo (also the ones copied before), their
    /// folder relative to the photo folder and the bytes sent.
    func copy(_ asset: PHAsset, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (files: [BackedUpFile], folder: String, bytes: Int64) {
        let originals: [PHAssetResourceType] = [.photo, .video, .pairedVideo, .alternatePhoto, .audio]
        let resources = PHAssetResource.assetResources(for: asset).filter { originals.contains($0.type) }
        guard !resources.isEmpty else { return ([], "", 0) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("respaldo-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let names = BackupPlan.distinctNames(resources.enumerated().map { BackupPlan.safeName($1.originalFilename, fallback: "archivo-\($0 + 1)") })
        var files: [(name: String, size: Int64, url: URL)] = []
        for (index, resource) in resources.enumerated() {
            try Task.checkCancellation()
            let file = temp.appendingPathComponent("\(index)")
            try await Self.export(resource, to: file)
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw BackupError.unreadable }
            files.append((names[index], size, file))
        }

        let parts = BackupPlan.folders(for: asset.creationDate ?? Date())
        let folder = try await folder(parts)
        let existing = try await listing(folder)
        let plan = BackupPlan.choose(files.map { (name: $0.name, size: $0.size) }, existing: existing.mapValues(\.bytes))
        let total = plan.upload.reduce(Int64(0)) { $0 + files[$1].size }
        var before: Int64 = 0
        for index in plan.upload {
            try Task.checkCancellation()
            let base = before
            try await upload(files[index].url, as: BackupPlan.suffixed(files[index].name, plan.number), in: folder) { sent in progress(base + sent, total) }
            before += files[index].size
        }
        // Checked on the NAS: every file there, complete.
        let after = plan.upload.isEmpty ? existing : try await listing(folder)
        for index in plan.upload where after[BackupPlan.suffixed(files[index].name, plan.number).lowercased()]?.bytes != files[index].size {
            throw GalleryError.message("Una copia en el NAS no quedó completa; se detuvo el respaldo.")
        }
        let placed = files.compactMap { file in after[BackupPlan.suffixed(file.name, plan.number).lowercased()] }
        return (placed, parts.joined(separator: "/"), total)
    }

    /// Creates `Respaldo iPhone`, the year and the month when missing.
    private func folder(_ parts: [String]) async throws -> URL {
        var url = account.root
        for part in parts {
            url = url.appendingPathComponent(part, isDirectory: true)
            let key = url.absoluteString
            guard !ready.contains(key) else { continue }
            // 405: it already exists.
            _ = try await transport.request(url, method: "MKCOL", accept: [405])
            ready.insert(key)
        }
        return url
    }

    /// The files on the NAS by name in lower case, as the NAS lists them (the same addresses
    /// a search finds later).
    private func listing(_ folder: URL) async throws -> [String: BackedUpFile] {
        var result: [String: BackedUpFile] = [:]
        for entry in try await transport.list(folder) where !entry.directory {
            let name = entry.url.lastPathComponent
            result[name.lowercased()] = BackedUpFile(url: entry.url, name: entry.name, bytes: entry.bytes)
        }
        return result
    }

    private func upload(_ file: URL, as name: String, in folder: URL, sent: @escaping @Sendable (Int64) -> Void) async throws {
        let temporary = folder.appendingPathComponent(BackupPlan.temporaryName(name))
        let final = folder.appendingPathComponent(name)
        _ = try await transport.request(temporary, method: "PUT", headers: ["Content-Type": "application/octet-stream"], bodyFile: file, sent: sent)
        // `Overwrite: F`: if the name exists, the NAS refuses (412) instead of replacing it.
        let moved = try await transport.request(temporary, method: "MOVE", headers: ["Destination": final.absoluteString, "Overwrite": "F"], accept: [412])
        if moved.status == 412 { throw BackupError.taken }
    }

    private static func export(_ resource: PHAssetResource, to file: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                if error != nil { continuation.resume(throwing: BackupError.unreadable) } else { continuation.resume() }
            }
        }
    }
}
