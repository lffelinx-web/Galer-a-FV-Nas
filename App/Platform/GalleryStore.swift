import Foundation
import SwiftUI
import Photos
import UIKit

enum NASState: Equatable {
    /// `slow`: connected, but the last check did not answer in time (a busy NAS).
    case notConfigured, checking, connected, slow, offline

    var label: String {
        switch self {
        case .notConfigured: return "NAS sin configurar"
        case .checking: return "Conectando…"
        case .connected: return "NAS conectado"
        case .slow: return "Conexión lenta"
        case .offline: return "NAS sin conexión"
        }
    }

    var shortLabel: String {
        switch self {
        case .notConfigured: return "Sin configurar"
        case .checking: return "Conectando…"
        case .connected: return "Conectado"
        case .slow: return "Conexión lenta"
        case .offline: return "Sin conexión"
        }
    }

    var color: Color {
        switch self {
        case .connected: return Palette.online
        case .checking, .slow: return Palette.warning
        case .offline: return .red
        case .notConfigured: return .gray
        }
    }
}

/// The NAS account for code that should not observe the whole store, such as tiles.
enum ActiveAccount {
    static var current: NASAccount?
}

/// Space on the NAS share, when the NAS reports it over WebDAV.
struct NASSpace: Equatable {
    var used: Int64?
    var available: Int64?
    var total: Int64? { used.flatMap { used in available.map { used + $0 } } }
}

struct ViewerContext: Identifiable {
    let id = UUID()
    let items: [GalleryItem]
    let start: String
    /// The tapped tile on screen and what it showed, for the zoom in and out.
    var sourceFrame: CGRect?
    var sourceImage: UIImage?
    /// The source image is the whole photo with its real shape, not the tile's crop.
    var sourceIsWhole = false
}

/// «Ver en el día»: show this date in the mosaic.
struct DayRequest: Equatable {
    let id = UUID()
    let date: Date
    /// Only in the NAS tab (the photo is not in Fototeca).
    let nas: Bool
}

/// The app state: the iPhone library, the NAS index, the merged timeline and the app's
/// own albums. Sorting and indexing tens of thousands of items happens off the main
/// thread, so the interface never freezes.
@MainActor
final class GalleryStore: ObservableObject {
    @Published private(set) var account: NASAccount? {
        didSet { ActiveAccount.current = account }
    }
    @Published private(set) var phoneItems: [GalleryItem] = []
    @Published private(set) var nasItems: [GalleryItem] = [] {
        didSet { nasRevision += 1 }
    }
    /// Both sources merged, newest first.
    @Published private(set) var items: [GalleryItem] = []
    /// Changes whenever `items` changes, so views can redo their layout cheaply.
    @Published private(set) var revision = 0
    @Published private(set) var nasRevision = 0
    @Published private(set) var loaded = false
    @Published private(set) var photoAccess = PhotoAccess.notDetermined
    @Published private(set) var nasState = NASState.notConfigured
    @Published private(set) var lastRoute: String?
    @Published private(set) var scanning = false
    @Published private(set) var scanStatus: String?
    /// Progress while the capture dates of NAS files are read.
    @Published private(set) var datesStatus: String?
    @Published private(set) var lastScan: Date?
    @Published private(set) var connecting = false
    @Published private(set) var albums: [AppAlbum] = []
    @Published var viewer: ViewerContext?
    @Published var dayRequest: DayRequest?
    @Published var error: String?
    @Published var showPhone = UserDefaults.standard.object(forKey: "showPhone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPhone, forKey: "showPhone"); merge() }
    }
    @Published var showNAS = UserDefaults.standard.object(forKey: "showNAS") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNAS, forKey: "showNAS"); merge() }
    }
    /// Hides NAS copies of photos that are also on the iPhone, such as an iPhone backup.
    @Published var hideDuplicates = UserDefaults.standard.object(forKey: "hideDuplicates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideDuplicates, forKey: "hideDuplicates"); merge() }
    }
    @Published private(set) var duplicatesHidden = 0
    /// NAS copies of iPhone photos hidden from Fototeca.
    @Published private(set) var duplicateIDs: [String] = []
    /// NAS items shown in the NAS tab: everything except what is hidden.
    @Published private(set) var nasShown: [GalleryItem] = []
    @Published private(set) var nasSpace: NASSpace?
    /// Files that appeared in the latest NAS search.
    @Published private(set) var lastAdded: [String] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var hidden: Set<String> = []
    /// Capture dates read so far, for the summary.
    @Published private(set) var datesRead = 0

    /// Every known item by id, whatever the Fototeca filters, for albums.
    private(set) var itemIndex: [String: GalleryItem] = [:]
    private var scanTask: Task<Void, Never>?
    private var mergeTask: Task<Void, Never>?
    private var phoneReload: Task<Void, Never>?
    private var learnedAspects: [String: Double] = [:]
    private var captured: [String: CaptureInfo] = [:]
    private var datesTask: Task<Void, Never>?
    private var datesToken: UUID?
    /// Dates were read that the wall does not reflect yet.
    private var capturedDirty = false
    private var lastStatusUpdate = Date.distantPast
    private var lastSpaceCheck = Date.distantPast
    private var folderCache: [String: CachedFolder] = [:]
    private var failedChecks = 0
    private var needsFullScan = false

    private var indexName: String { "nas-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private var aspectsName: String { "aspects-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private var capturedName: String { "captured-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private let albumsName = "albums.json"
    private let favoritesName = "favorites.json"
    private let hiddenName = "hidden.json"

    static let shared = GalleryStore()

    init() {
        account = AccountKeychain.load()
        ActiveAccount.current = account
        photoAccess = PhoneLibrary.access
        albums = Files.load(albumsName, as: [AppAlbum].self) ?? []
        // Older versions kept «-id» marks to unmark iPhone favorites; no longer needed.
        favorites = (Files.load(favoritesName, as: Set<String>.self) ?? []).filter { !$0.hasPrefix("-") }
        hidden = Files.load(hiddenName, as: Set<String>.self) ?? []
        if account != nil { nasState = .checking }
        // Photos posts many changes in a row (iCloud, edits); wait for them to settle.
        PhoneLibrary.shared.onChange = { [weak self] in self?.schedulePhoneReload() }
    }

    var nasLabel: String { account?.label ?? "NAS" }

    var statusText: String {
        switch nasState {
        case .connected, .checking, .slow, .offline: return nasState.label + " • " + nasLabel
        case .notConfigured: return nasState.label
        }
    }

    /// «1.2 TB libres de 4 TB», when the NAS reports its space.
    var spaceText: String? {
        guard let available = nasSpace?.available else { return nil }
        let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file) + " libres"
        guard let total = nasSpace?.total, total > 0 else { return free }
        return free + " de " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// The NAS line under its title: free space, then what is new or when it was last searched.
    var nasDetail: String {
        var parts: [String] = []
        if let available = nasSpace?.available { parts.append(ByteCountFormatter.string(fromByteCount: available, countStyle: .file) + " libres") }
        if !lastAdded.isEmpty { parts.append(countText(lastAdded.count, "nueva", "nuevas")) }
        else if let lastScan { parts.append("revisado " + lastScan.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    var routeLabel: String? {
        guard let account, let route = lastRoute else { return nil }
        if route == account.routeIP { return route.isEmpty ? "Dominio (internet)" : "Red local · \(route)" }
        return "Tailscale · \(route)"
    }

    // MARK: Startup

    func start() async {
        if account != nil { await loadIndex() }
        await reloadPhone()
        loaded = true
        guard account != nil else { return }
        await checkConnection()
        if nasState == .connected { PhoneBackup.shared.start() }
        if nasItems.isEmpty && nasState == .connected { scan() } else if nasState == .connected { searchIfStale() }
    }

    /// A quick search for new photos when the last one is more than six hours old; it only
    /// lists the folders that changed. Otherwise the capture dates continue.
    private func searchIfStale() {
        if !needsFullScan, let lastScan, Date().timeIntervalSince(lastScan) < 6 * 3600 { readCaptureDates() } else { scan(quiet: true) }
    }

    /// Pull to refresh: the iPhone library and the NAS connection. A full NAS search is
    /// started from the NAS tab, since it can take minutes.
    func refresh() async {
        await reloadPhone()
        await checkConnection()
    }

    /// Back from the background: check the NAS and pick up the capture dates where they stopped.
    func resume() async {
        guard loaded else { return }
        await checkConnection()
        if nasState == .connected { PhoneBackup.shared.start(); searchIfStale() }
    }

    /// Going to the background: keep what was read so far, put the NAS in date order, and
    /// ask iOS for time later to keep reading.
    func suspend() async {
        await saveLearned()
        saveCaptured()
        BackgroundJobs.schedule()
        await applyReadDates()
    }

    // MARK: iPhone

    func requestPhotoAccess() async {
        photoAccess = await PhoneLibrary.requestAccess()
        await reloadPhone()
    }

    private func schedulePhoneReload() {
        phoneReload?.cancel()
        phoneReload = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await reloadPhone()
        }
    }

    func reloadPhone() async {
        photoAccess = PhoneLibrary.access
        guard photoAccess.canRead else {
            if !phoneItems.isEmpty { phoneItems = []; merge() }
            return
        }
        let fresh = await PhoneLibrary.shared.load()
        guard fresh != phoneItems else { return }
        phoneItems = fresh
        merge()
        // A new photo on the iPhone: copy it to the NAS if the backup is on.
        if loaded { PhoneBackup.shared.start() }
    }

    // MARK: NAS

    func connect(root: String, user: String, password: String, route: String, tailscale: String, mode: NASConnectionMode, name: String, dsmPort: Int?) async -> Bool {
        guard !connecting else { return false }
        connecting = true; defer { connecting = false }
        do {
            let candidate = NASAccount(root: try URLPolicy.root(root), username: user.trimmingCharacters(in: .whitespaces), password: password,
                                       routeIP: route.trimmingCharacters(in: .whitespaces), tailscaleHost: tailscale.trimmingCharacters(in: .whitespacesAndNewlines),
                                       connectionMode: mode, displayName: name.trimmingCharacters(in: .whitespacesAndNewlines), dsmPort: dsmPort)
            guard !candidate.username.isEmpty, !password.isEmpty, NASAccount.validRoute(candidate.routeIP),
                  NASAccount.validRoute(candidate.tailscaleHost ?? ""), !candidate.routes.isEmpty else {
                throw GalleryError.message("Revisa usuario, contraseña e IP de conexión.")
            }
            let response = try await NASTransport(candidate).request(candidate.root, method: "PROPFIND", headers: ["Depth": "0"])
            guard response.status == 207 else { throw GalleryError.message("La dirección no corresponde a una carpeta WebDAV.") }
            try AccountKeychain.save(candidate)
            let changed = account?.scope != candidate.scope
            if changed { scanTask?.cancel(); scanning = false; datesTask?.cancel(); datesTask = nil; datesStatus = nil }
            account = candidate
            lastRoute = response.route
            nasState = .connected
            if changed { await loadIndex(); scan() }
            await refreshSpace(candidate, force: true)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        do { try AccountKeychain.clear() } catch { self.error = error.localizedDescription; return }
        scanTask?.cancel(); scanning = false; scanStatus = nil
        datesTask?.cancel(); datesTask = nil; datesStatus = nil; captured = [:]; datesRead = 0
        account = nil; nasItems = []; lastScan = nil; lastRoute = nil; nasState = .notConfigured; nasSpace = nil; lastAdded = []
        merge()
    }

    /// One failed check while connected only means «Conexión lenta»: a busy NAS answers late.
    /// Two in a row mean it is really out of reach.
    func checkConnection() async {
        guard let account else { nasState = .notConfigured; return }
        if nasState == .notConfigured || nasState == .offline { nasState = .checking }
        do {
            let response = try await NASTransport(account).request(account.root, method: "PROPFIND", headers: ["Depth": "0"])
            guard self.account?.scope == account.scope else { return }
            lastRoute = response.route
            failedChecks = 0
            nasState = response.status == 207 ? .connected : .offline
            if nasState == .connected { await refreshSpace(account) }
        } catch {
            guard self.account?.scope == account.scope else { return }
            if error is GalleryError { nasState = .offline; return }
            failedChecks += 1
            let wasReachable = nasState == .connected || nasState == .slow
            nasState = wasReachable && failedChecks < 2 ? .slow : .offline
        }
    }

    /// Searches the NAS. `quiet` is the automatic search: no alert if it fails.
    func scan(quiet: Bool = false) {
        guard let account, !scanning else { return }
        datesTask?.cancel(); datesTask = nil; datesStatus = nil
        scanning = true; scanStatus = "Buscando fotos nuevas en el NAS…"
        let aspects = learnedAspects
        let known = captured
        let name = indexName
        let previousFolders = folderCache
        let previousItems = Dictionary(nasItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        scanTask = Task {
            defer { scanning = false }
            do {
                let result = try await NASScanner(account: account, learnedAspects: aspects, previousFolders: previousFolders, previousItems: previousItems).scan { folder, count in
                    Task { @MainActor [weak self] in self?.showProgress(folder: folder, count: count) }
                }
                let scanned = result.items
                let folders = result.folders
                let found = await Task.detached(priority: .userInitiated) { Self.applying(known, to: scanned) }.value
                guard self.account?.scope == account.scope else { return }
                let scannedAt = Date()
                // What is new since the previous search, when there was one.
                let previous = Set(nasItems.map(\.id))
                let added: [String] = previous.isEmpty ? [] : found.filter { !previous.contains($0.id) }.map(\.id)
                lastAdded = added
                nasItems = found; lastScan = scannedAt; nasState = .connected; scanStatus = nil
                let addedIDs = lastAdded
                folderCache = folders
                needsFullScan = false
                Task.detached(priority: .utility) { try? Files.save(NASIndex(items: scanned, scanned: scannedAt, added: addedIDs, folders: folders, version: 2), name: name) }
                merge()
                scanning = false
                readCaptureDates()
            } catch {
                scanStatus = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                // Only a network failure means the NAS is offline; a bad listing is reported as an error.
                if self.account?.scope == account.scope, !(error is GalleryError) { nasState = nasState == .connected ? .slow : .offline }
                if !quiet { self.error = error.localizedDescription }
            }
        }
    }

    /// Free space of the share: from WebDAV when the NAS reports it there, otherwise from the
    /// DSM API. Asked at most every half hour, since DSM records each sign-in.
    private func refreshSpace(_ account: NASAccount, force: Bool = false) async {
        guard force || nasSpace == nil || Date().timeIntervalSince(lastSpaceCheck) > 1800 else { return }
        lastSpaceCheck = Date()
        let transport = NASTransport(account)
        var space = try? await transport.space(account.root)
        if space?.available == nil { space = try? await DSMSpace.read(account, transport: transport) }
        guard self.account?.scope == account.scope, let space else { return }
        nasSpace = space
    }

    /// At most a few updates a second, so a long search does not redraw the screen constantly.
    private func showProgress(folder: String, count: Int) {
        guard scanning, Date().timeIntervalSince(lastStatusUpdate) > 0.5 else { return }
        lastStatusUpdate = Date()
        scanStatus = "\(count.formatted()) archivos · \(folder.isEmpty ? "carpeta principal" : folder)"
    }

    private func loadIndex() async {
        let (aspectsFile, indexFile, capturedFile) = (aspectsName, indexName, capturedName)
        let (aspects, captured, index) = await Task.detached(priority: .userInitiated) { () -> ([String: Double], [String: CaptureInfo], NASIndex) in
            let aspects = Files.load(aspectsFile, as: [String: Double].self) ?? [:]
            let captured = Files.load(capturedFile, as: [String: CaptureInfo].self) ?? [:]
            var index = Files.load(indexFile, as: NASIndex.self) ?? NASIndex()
            if !aspects.isEmpty {
                for position in index.items.indices {
                    if let aspect = aspects[index.items[position].id] { index.items[position].aspect = aspect }
                }
            }
            index.items = Self.applying(captured, to: index.items)
            return (aspects, captured, index)
        }.value
        learnedAspects = aspects
        self.captured = captured
        datesRead = captured.count
        nasItems = index.items
        lastScan = index.scanned
        lastAdded = index.added ?? []
        folderCache = index.folders ?? [:]
        // Made before dates came from the NAS files: every folder is listed again once.
        needsFullScan = !index.items.isEmpty && (index.version ?? 0) < 2
        if needsFullScan { folderCache = [:] }
        merge()
    }

    /// Keeps the shapes learned from thumbnails; they are used from the next launch on, so
    /// the wall does not jump while you look at it.
    func saveLearned() async {
        guard account != nil else { return }
        let new = await NASImageLoader.shared.takeAspects()
        guard !new.isEmpty else { return }
        learnedAspects.merge(new) { _, latest in latest }
        let (all, name) = (learnedAspects, aspectsName)
        Task.detached(priority: .utility) { try? Files.save(all, name: name) }
    }

    // MARK: Capture dates

    /// Reads, in the background, when each NAS photo was really taken and reorders the
    /// NAS by that date. Progress is saved as it goes and resumes after the app is closed,
    /// so each file is read only once.
    func readCaptureDates() {
        guard let account, datesTask == nil, !scanning else { return }
        let known = captured
        let pending = nasItems.filter { known[$0.id] == nil }
        let total = nasItems.count
        datesRead = total - pending.count
        guard !pending.isEmpty else { datesStatus = nil; return }
        datesStatus = datesText(datesRead, total)
        let token = UUID()
        datesToken = token
        datesTask = Task {
            let background = BackgroundWork(name: "Fechas de captura")
            defer { background.end() }
            let transport = NASTransport(account)
            var failures = 0, sinceSave = 0
            var read = self.datesRead
            var start = 0
            // Stopped (by a search, or iOS ending the background time): keep what was read.
            defer {
                if datesToken == token {
                    saveCaptured()
                    datesRead = read
                    datesStatus = nil
                    datesTask = nil
                }
            }
            while start < pending.count, !Task.isCancelled {
                // Waits only while a photo is open, so the NAS answers what you look at first.
                while !Task.isCancelled && viewer != nil {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                let chunk = Array(pending[start..<min(start + 3, pending.count)])
                start += chunk.count
                let results = await withTaskGroup(of: (String, CaptureInfo?).self) { group -> [(String, CaptureInfo?)] in
                    for item in chunk { group.addTask { (item.id, await CaptureReader.read(item, transport: transport)) } }
                    var out: [(String, CaptureInfo?)] = []
                    for await result in group { out.append(result) }
                    return out
                }
                guard !Task.isCancelled, self.account?.scope == account.scope else { return }
                for (id, info) in results {
                    if let info { captured[id] = info; failures = 0; sinceSave += 1; read += 1; capturedDirty = true } else { failures += 1 }
                }
                // The NAS stopped answering: stop here and resume when the app comes back.
                if failures >= 12 { break }
                if sinceSave >= 300 { saveCaptured(); sinceSave = 0 }
                // Published every hundred files, not on each one, to keep the screen calm.
                if read / 100 != (read - chunk.count) / 100 { datesRead = read; datesStatus = datesText(read, total) }
            }
            // The wall is reordered when you leave the app, not while you use it.
        }
    }

    /// Reorders the NAS by the dates read since the last time, if any.
    func applyReadDates() async {
        guard capturedDirty else { return }
        capturedDirty = false
        await reorderByCapture()
    }

    /// Time iOS gives in the background (at night, while charging): read capture dates
    /// until it runs out.
    func backgroundWork() async {
        if !loaded {
            if account != nil { await loadIndex() }
            loaded = true
        }
        guard account != nil else { return }
        await checkConnection()
        guard nasState == .connected || nasState == .slow else { return }
        // The backup first: new photos are safe on the NAS before anything else.
        await PhoneBackup.shared.runNow()
        guard !Task.isCancelled else { return }
        readCaptureDates()
        let running = datesTask
        await withTaskCancellationHandler {
            await running?.value
        } onCancel: {
            running?.cancel()
        }
        await applyReadDates()
    }

    private func datesText(_ done: Int, _ total: Int) -> String {
        "Ordenando por fecha · \(done.formatted()) de \(total.formatted())"
    }

    private func saveCaptured() {
        guard account != nil, !captured.isEmpty else { return }
        let (all, name) = (captured, capturedName)
        Task.detached(priority: .utility) { try? Files.save(all, name: name) }
    }

    private func reorderByCapture() async {
        let (all, items) = (captured, nasItems)
        let sorted = await Task.detached(priority: .userInitiated) { Self.applying(all, to: items) }.value
        nasItems = sorted
        merge()
    }

    /// The capture dates stopped before the end (the NAS stopped answering); they can be resumed.
    var datesPaused: Bool { account != nil && datesTask == nil && !scanning && datesRead < nasItems.count && !nasItems.isEmpty }

    /// Where the date of an item comes from, so you know how much to trust it.
    func dateSource(_ item: GalleryItem) -> String {
        guard item.isNAS else { return "Fecha de la fototeca del iPhone" }
        if captured[item.id]?.date != nil { return item.isVideo ? "Fecha guardada en el video" : "Fecha de captura del archivo (EXIF)" }
        let calendar = Calendar.current
        let latest = calendar.component(.year, from: Date()) + 1
        if DateGuess.fromName(item.name, calendar: calendar, latestYear: latest) != nil { return "Fecha tomada del nombre del archivo" }
        if item.exactDate == true { return "Fecha del archivo en el NAS" }
        let folders = (item.folder ?? "").split(separator: "/").map(String.init)
        if DateGuess.fromFolders(folders, calendar: calendar, latestYear: latest) != nil { return "Fecha aproximada por la carpeta" }
        return "Fecha de modificación en el NAS"
    }

    /// NAS files whose date is only a guess: nothing inside the file, no date in the name,
    /// and a NAS date that does not match the folder.
    var undatedItems: [GalleryItem] {
        let calendar = Calendar.current
        let latest = calendar.component(.year, from: Date()) + 1
        return captured.compactMap { entry -> GalleryItem? in
            guard entry.value.date == nil, let item = itemIndex[entry.key], item.exactDate != true,
                  DateGuess.fromName(item.name, calendar: calendar, latestYear: latest) == nil else { return nil }
            return item
        }.sorted { $0.date > $1.date }
    }

    nonisolated static func applying(_ captured: [String: CaptureInfo], to items: [GalleryItem]) -> [GalleryItem] {
        guard !captured.isEmpty else { return items }
        var result = items
        for index in result.indices {
            guard let info = captured[result[index].id] else { continue }
            if let date = info.date { result[index].date = date }
            if let aspect = info.aspect, aspect.isFinite, aspect > 0 { result[index].aspect = aspect }
            if let duration = info.duration { result[index].duration = duration }
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    // MARK: Timeline

    private func merge() {
        let phone = phoneItems, nas = nasItems
        let (usePhone, useNAS, dedupe, secret) = (showPhone, showNAS, hideDuplicates, hidden)
        // Exact dates: read from the file, or the NAS date confirmed by the folder.
        let checked = Set(captured.compactMap { $0.value.date == nil ? nil : $0.key }).union(nas.lazy.filter { $0.exactDate == true }.map(\.id))
        mergeTask?.cancel()
        mergeTask = Task {
            let (merged, index, duplicates, nasVisible) = await Task.detached(priority: .userInitiated) { () -> ([GalleryItem], [String: GalleryItem], [String], [GalleryItem]) in
                let nasVisible = secret.isEmpty ? nas : nas.filter { !secret.contains($0.id) }
                let a = usePhone ? (secret.isEmpty ? phone : phone.filter { !secret.contains($0.id) }) : []
                var b = useNAS ? nasVisible : []
                var duplicates: [String] = []
                if dedupe && !a.isEmpty && !b.isEmpty {
                    let unique = Self.removingDuplicates(b, of: a, checked: checked)
                    let kept = Set(unique.map(\.id))
                    duplicates = b.lazy.filter { !kept.contains($0.id) }.map(\.id)
                    b = unique
                }
                let merged: [GalleryItem]
                if a.isEmpty { merged = b } else if b.isEmpty { merged = a } else {
                    merged = (a + b).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
                }
                var index: [String: GalleryItem] = [:]
                index.reserveCapacity(phone.count + nas.count)
                for item in phone { index[item.id] = item }
                for item in nas { index[item.id] = item }
                return (merged, index, duplicates, nasVisible)
            }.value
            guard !Task.isCancelled else { return }
            itemIndex = index
            // Nothing visible changed: no new layouts, no redraw.
            if merged == items && nasVisible == nasShown && duplicates == duplicateIDs { return }
            duplicateIDs = duplicates
            duplicatesHidden = duplicates.count
            nasShown = nasVisible
            items = merged
            revision += 1
        }
    }

    /// NAS files whose capture second, kind and shape match a photo on the iPhone. Only
    /// files whose date was read from the file itself (`checked`) are compared, since a
    /// date guessed from a name or folder is not precise enough.
    nonisolated static func removingDuplicates(_ nas: [GalleryItem], of phone: [GalleryItem], checked: Set<String>) -> [GalleryItem] {
        func key(_ item: GalleryItem, second: Int) -> String { (item.kind == .video ? "v" : "p") + String(second) }
        var shapes: [String: [Double]] = [:]
        for item in phone {
            shapes[key(item, second: Int(item.date.timeIntervalSince1970.rounded(.down))), default: []].append(item.aspect)
        }
        return nas.filter { item in
            guard checked.contains(item.id) else { return true }
            let second = Int(item.date.timeIntervalSince1970.rounded(.down))
            for offset in -1...1 {
                guard let candidates = shapes[key(item, second: second + offset)] else { continue }
                // Same second and same shape (within 3 %), or a shape that is not known yet.
                if item.aspect == 1 || candidates.contains(where: { abs($0 - item.aspect) / max($0, item.aspect) < 0.03 || $0 == 1 }) { return false }
            }
            return true
        }
    }

    /// Opens the viewer on the photos around the tapped one, so it opens instantly even in
    /// a library of tens of thousands.
    func open(_ item: GalleryItem, in list: [GalleryItem], from frame: CGRect? = nil, image: UIImage? = nil) {
        let position = list.firstIndex { $0.id == item.id } ?? 0
        let window = list.isEmpty ? [item] : Array(list[max(0, position - 400)..<min(list.count, position + 400)])
        // The whole photo with its real shape, so the zoom ends exactly where the viewer begins.
        let whole: UIImage? = frame == nil ? nil : {
            switch item.source {
            case .nas(let url): return NASImageLoader.shared.cached(url)
            case .phone(let id): return PhoneLibrary.shared.quickImage(id, pixels: 900)
            }
        }()
        let context = ViewerContext(items: window, start: item.id, sourceFrame: frame, sourceImage: whole ?? image, sourceIsWhole: whole != nil)
        // With a source tile the viewer draws its own zoom, so the system slide is turned off.
        var transaction = Transaction()
        transaction.disablesAnimations = frame != nil && image != nil
        withTransaction(transaction) { viewer = context }
    }

    // MARK: Favorites and hidden

    /// Favorites belong to the app only: the iPhone's favorites play no part.
    func isFavorite(_ item: GalleryItem) -> Bool { favorites.contains(item.id) }

    func toggleFavorite(_ item: GalleryItem) {
        toggleFavoriteSilently(item)
        save(favorites, as: favoritesName)
    }

    var favoriteItems: [GalleryItem] {
        itemIndex.values.filter { isFavorite($0) && !hidden.contains($0.id) }.sorted { $0.date > $1.date }
    }

    func isHidden(_ item: GalleryItem) -> Bool { hidden.contains(item.id) }

    func setHidden(_ item: GalleryItem, _ value: Bool) { setHidden([item], value) }

    func setHidden(_ items: [GalleryItem], _ value: Bool) {
        for item in items { if value { hidden.insert(item.id) } else { hidden.remove(item.id) } }
        save(hidden, as: hiddenName)
        merge()
    }

    /// Several at once: all become favorites, or (when all already are) none.
    func setFavorite(_ items: [GalleryItem], _ value: Bool) {
        for item in items where isFavorite(item) != value { toggleFavoriteSilently(item) }
        save(favorites, as: favoritesName)
    }

    private func toggleFavoriteSilently(_ item: GalleryItem) {
        if favorites.contains(item.id) { favorites.remove(item.id) } else { favorites.insert(item.id) }
    }

    // MARK: Selection

    /// Photos chosen in the mosaic; nil when not choosing.
    @Published var selection: Set<String>?

    func toggleSelection(_ id: String) {
        guard var current = selection else { return }
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        selection = current
    }

    var selectedItems: [GalleryItem] { (selection ?? []).compactMap { itemIndex[$0] }.sorted { $0.date > $1.date } }

    var hiddenItems: [GalleryItem] { hidden.compactMap { itemIndex[$0] }.sorted { $0.date > $1.date } }

    /// Every item, iPhone and NAS, without the hidden ones.
    var allVisible: [GalleryItem] { itemIndex.values.filter { !hidden.contains($0.id) } }

    private func save<T: Encodable>(_ value: T, as name: String) {
        do { try Files.save(value, name: name) } catch { self.error = "No se pudo guardar el cambio." }
    }

    // MARK: Collections

    /// The items of an automatic collection in Espacio, newest first.
    func items(for collection: SmartCollection) async -> [GalleryItem] {
        let newest: (GalleryItem, GalleryItem) -> Bool = { $0.date > $1.date }
        switch collection {
        case .favorites: return favoriteItems
        case .duplicates: return duplicateIDs.compactMap { itemIndex[$0] }.sorted(by: newest)
        case .undated: return undatedItems
        case .selfies:
            return await PhoneLibrary.shared.ids(in: .smartAlbumSelfPortraits).compactMap { itemIndex[$0] }.filter { !hidden.contains($0.id) }
        case .recent:
            let phone = await PhoneLibrary.shared.ids(in: .smartAlbumRecentlyAdded, limit: 300)
            return (lastAdded + phone).compactMap { itemIndex[$0] }.filter { !hidden.contains($0.id) }.sorted(by: newest)
        case .videos, .livePhotos, .screenshots, .raw:
            let all = allVisible
            return await Task.detached(priority: .userInitiated) { () -> [GalleryItem] in
                let matching: [GalleryItem]
                switch collection {
                case .videos: matching = all.filter(\.isVideo)
                case .livePhotos: matching = all.filter { $0.kind == .livePhoto }
                case .screenshots: matching = all.filter(\.isScreenshot)
                default: matching = all.filter(\.isRAW)
                }
                return matching.sorted { $0.date > $1.date }
            }.value
        }
    }

    // MARK: Albums

    @discardableResult
    func createAlbum(_ name: String, with itemIDs: [String] = []) -> AppAlbum? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let album = AppAlbum(id: UUID(), name: name, created: Date(), items: itemIDs)
        albums.insert(album, at: 0)
        saveAlbums()
        return album
    }

    func renameAlbum(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index].name = name
        saveAlbums()
    }

    func deleteAlbum(_ id: UUID) {
        albums.removeAll { $0.id == id }
        saveAlbums()
    }

    func album(_ id: UUID, contains itemID: String) -> Bool {
        albums.first { $0.id == id }?.items.contains(itemID) ?? false
    }

    func toggle(_ itemID: String, in id: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        if let position = albums[index].items.firstIndex(of: itemID) { albums[index].items.remove(at: position) }
        else { albums[index].items.insert(itemID, at: 0) }
        saveAlbums()
    }

    /// Puts several photos in an album, or takes them out.
    func set(_ itemIDs: [String], in id: UUID, _ inside: Bool) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        if inside {
            albums[index].items.insert(contentsOf: itemIDs.filter { !albums[index].items.contains($0) }, at: 0)
        } else {
            let removed = Set(itemIDs)
            albums[index].items.removeAll { removed.contains($0) }
        }
        saveAlbums()
    }

    func remove(_ itemID: String, from id: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index].items.removeAll { $0 == itemID }
        saveAlbums()
    }

    /// The album's photos that still exist, newest first.
    func items(in album: AppAlbum) -> [GalleryItem] {
        album.items.compactMap { itemIndex[$0] }.sorted { $0.date > $1.date }
    }

    private func saveAlbums() {
        do { try Files.save(albums, name: albumsName) } catch { self.error = "No se pudo guardar el álbum." }
    }
}
