import Foundation
import SwiftUI

enum NASState: Equatable {
    case notConfigured, checking, connected, offline

    var label: String {
        switch self {
        case .notConfigured: return "NAS sin configurar"
        case .checking: return "Conectando…"
        case .connected: return "NAS conectado"
        case .offline: return "NAS sin conexión"
        }
    }
}

/// The NAS account for code that should not observe the whole store, such as tiles.
enum ActiveAccount {
    static var current: NASAccount?
}

struct ViewerContext: Identifiable {
    let id = UUID()
    let items: [GalleryItem]
    let start: String
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
    @Published var error: String?
    @Published var showPhone = UserDefaults.standard.object(forKey: "showPhone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPhone, forKey: "showPhone"); merge() }
    }
    @Published var showNAS = UserDefaults.standard.object(forKey: "showNAS") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNAS, forKey: "showNAS"); merge() }
    }

    /// Every known item by id, whatever the Fototeca filters, for albums.
    private(set) var itemIndex: [String: GalleryItem] = [:]
    private var scanTask: Task<Void, Never>?
    private var mergeTask: Task<Void, Never>?
    private var phoneReload: Task<Void, Never>?
    private var learnedAspects: [String: Double] = [:]
    private var captured: [String: CaptureInfo] = [:]
    private var datesTask: Task<Void, Never>?
    private var lastStatusUpdate = Date.distantPast

    private var indexName: String { "nas-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private var aspectsName: String { "aspects-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private var capturedName: String { "captured-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private let albumsName = "albums.json"

    init() {
        account = AccountKeychain.load()
        ActiveAccount.current = account
        photoAccess = PhoneLibrary.access
        albums = Files.load(albumsName, as: [AppAlbum].self) ?? []
        if account != nil { nasState = .checking }
        // Photos posts many changes in a row (iCloud, edits); wait for them to settle.
        PhoneLibrary.shared.onChange = { [weak self] in self?.schedulePhoneReload() }
    }

    var nasLabel: String { account?.label ?? "NAS" }

    var statusText: String {
        switch nasState {
        case .connected, .checking, .offline: return nasState.label + " • " + nasLabel
        case .notConfigured: return nasState.label
        }
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
        if nasItems.isEmpty && nasState == .connected { scan() } else if nasState == .connected { readCaptureDates() }
    }

    /// Pull to refresh: the iPhone library and the NAS connection. A full NAS search is
    /// started from the NAS tab, since it can take minutes.
    func refresh() async {
        await reloadPhone()
        await checkConnection()
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
    }

    // MARK: NAS

    func connect(root: String, user: String, password: String, route: String, tailscale: String, mode: NASConnectionMode, name: String) async -> Bool {
        guard !connecting else { return false }
        connecting = true; defer { connecting = false }
        do {
            let candidate = NASAccount(root: try URLPolicy.root(root), username: user.trimmingCharacters(in: .whitespaces), password: password,
                                       routeIP: route.trimmingCharacters(in: .whitespaces), tailscaleHost: tailscale.trimmingCharacters(in: .whitespacesAndNewlines),
                                       connectionMode: mode, displayName: name.trimmingCharacters(in: .whitespacesAndNewlines))
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
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        do { try AccountKeychain.clear() } catch { self.error = error.localizedDescription; return }
        scanTask?.cancel(); scanning = false; scanStatus = nil
        datesTask?.cancel(); datesTask = nil; datesStatus = nil; captured = [:]
        account = nil; nasItems = []; lastScan = nil; lastRoute = nil; nasState = .notConfigured
        merge()
    }

    func checkConnection() async {
        guard let account else { nasState = .notConfigured; return }
        if nasState != .connected { nasState = .checking }
        do {
            let response = try await NASTransport(account).request(account.root, method: "PROPFIND", headers: ["Depth": "0"])
            guard self.account?.scope == account.scope else { return }
            lastRoute = response.route
            nasState = response.status == 207 ? .connected : .offline
        } catch {
            guard self.account?.scope == account.scope else { return }
            nasState = .offline
        }
    }

    func scan() {
        guard let account, !scanning else { return }
        datesTask?.cancel(); datesTask = nil; datesStatus = nil
        scanning = true; scanStatus = "Buscando fotos en el NAS…"
        let aspects = learnedAspects
        let known = captured
        let name = indexName
        scanTask = Task {
            defer { scanning = false }
            do {
                let scanned = try await NASScanner(account: account, learnedAspects: aspects).scan { folder, count in
                    Task { @MainActor [weak self] in self?.showProgress(folder: folder, count: count) }
                }
                let found = await Task.detached(priority: .userInitiated) { Self.applying(known, to: scanned) }.value
                guard self.account?.scope == account.scope else { return }
                let scannedAt = Date()
                nasItems = found; lastScan = scannedAt; nasState = .connected; scanStatus = nil
                Task.detached(priority: .utility) { try? Files.save(NASIndex(items: scanned, scanned: scannedAt), name: name) }
                merge()
                scanning = false
                readCaptureDates()
            } catch {
                scanStatus = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                // Only a network failure means the NAS is offline; a bad listing is reported as an error.
                if self.account?.scope == account.scope, !(error is GalleryError) { nasState = .offline }
                self.error = error.localizedDescription
            }
        }
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
        nasItems = index.items
        lastScan = index.scanned
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
    /// NAS by that date. Already read files are remembered, so it only runs once per file.
    func readCaptureDates() {
        guard let account, datesTask == nil, !scanning else { return }
        let known = captured
        let pending = nasItems.filter { known[$0.id] == nil }
        guard !pending.isEmpty else { return }
        let total = pending.count
        datesStatus = "Ordenando por fecha de captura…"
        datesTask = Task {
            let transport = NASTransport(account)
            var batch: [String: CaptureInfo] = [:]
            var done = 0, failures = 0
            var lastApply = Date()
            var start = 0
            while start < total, !Task.isCancelled {
                let chunk = Array(pending[start..<min(start + 4, total)])
                start += chunk.count
                let results = await withTaskGroup(of: (String, CaptureInfo?).self) { group -> [(String, CaptureInfo?)] in
                    for item in chunk { group.addTask { (item.id, await CaptureReader.read(item, transport: transport)) } }
                    var out: [(String, CaptureInfo?)] = []
                    for await result in group { out.append(result) }
                    return out
                }
                for (id, info) in results {
                    if let info { batch[id] = info; failures = 0 } else { failures += 1 }
                }
                done += chunk.count
                // The NAS stopped answering: try again on the next launch.
                if failures >= 12 { break }
                if done % 200 == 0 || done == total {
                    datesStatus = "Ordenando por fecha de captura · \(done.formatted()) de \(total.formatted())"
                }
                // Reorder now and then, not on every file, so the wall does not keep moving.
                if Date().timeIntervalSince(lastApply) > 180 {
                    await applyCaptured(batch); batch = [:]; lastApply = Date()
                }
            }
            guard !Task.isCancelled else { return }
            await applyCaptured(batch)
            datesStatus = nil
            datesTask = nil
        }
    }

    private func applyCaptured(_ new: [String: CaptureInfo]) async {
        guard !new.isEmpty, account != nil else { return }
        captured.merge(new) { _, latest in latest }
        let (all, items, name) = (captured, nasItems, capturedName)
        let sorted = await Task.detached(priority: .userInitiated) { () -> [GalleryItem] in
            try? Files.save(all, name: name)
            return Self.applying(all, to: items)
        }.value
        nasItems = sorted
        merge()
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
        let (usePhone, useNAS) = (showPhone, showNAS)
        mergeTask?.cancel()
        mergeTask = Task {
            let (merged, index) = await Task.detached(priority: .userInitiated) { () -> ([GalleryItem], [String: GalleryItem]) in
                let a = usePhone ? phone : [], b = useNAS ? nas : []
                let merged: [GalleryItem]
                if a.isEmpty { merged = b } else if b.isEmpty { merged = a } else {
                    merged = (a + b).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
                }
                var index: [String: GalleryItem] = [:]
                index.reserveCapacity(phone.count + nas.count)
                for item in phone { index[item.id] = item }
                for item in nas { index[item.id] = item }
                return (merged, index)
            }.value
            guard !Task.isCancelled else { return }
            items = merged
            itemIndex = index
            revision += 1
        }
    }

    /// Opens the viewer on the photos around the tapped one, so it opens instantly even in
    /// a library of tens of thousands.
    func open(_ item: GalleryItem, in list: [GalleryItem]) {
        let position = list.firstIndex { $0.id == item.id } ?? 0
        let window = list.isEmpty ? [item] : Array(list[max(0, position - 400)..<min(list.count, position + 400)])
        viewer = ViewerContext(items: window, start: item.id)
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
