import Foundation
import SwiftUI
import Photos
import UIKit

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

    var shortLabel: String {
        switch self {
        case .notConfigured: return "Sin configurar"
        case .checking: return "Conectando…"
        case .connected: return "Conectado"
        case .offline: return "Sin conexión"
        }
    }

    var color: Color {
        switch self {
        case .connected: return Palette.online
        case .checking: return Palette.warning
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
    private var lastStatusUpdate = Date.distantPast

    private var indexName: String { "nas-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private var aspectsName: String { "aspects-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private var capturedName: String { "captured-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private let albumsName = "albums.json"
    private let favoritesName = "favorites.json"
    private let hiddenName = "hidden.json"

    init() {
        account = AccountKeychain.load()
        ActiveAccount.current = account
        photoAccess = PhoneLibrary.access
        albums = Files.load(albumsName, as: [AppAlbum].self) ?? []
        favorites = Files.load(favoritesName, as: Set<String>.self) ?? []
        hidden = Files.load(hiddenName, as: Set<String>.self) ?? []
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
        if nasItems.isEmpty && nasState == .connected { scan() } else if nasState == .connected { readCaptureDates() }
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
        if nasState == .connected { readCaptureDates() }
    }

    /// Going to the background: keep what was read so far.
    func suspend() async {
        await saveLearned()
        saveCaptured()
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
        datesTask?.cancel(); datesTask = nil; datesStatus = nil; captured = [:]; datesRead = 0
        account = nil; nasItems = []; lastScan = nil; lastRoute = nil; nasState = .notConfigured; nasSpace = nil; lastAdded = []
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
            if nasState == .connected, let space = try? await NASTransport(account).space(account.root), self.account?.scope == account.scope {
                nasSpace = space
            }
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
                // What is new since the previous search, when there was one.
                let previous = Set(nasItems.map(\.id))
                let added: [String] = previous.isEmpty ? [] : found.filter { !previous.contains($0.id) }.map(\.id)
                lastAdded = added
                nasItems = found; lastScan = scannedAt; nasState = .connected; scanStatus = nil
                let addedIDs = lastAdded
                Task.detached(priority: .utility) { try? Files.save(NASIndex(items: scanned, scanned: scannedAt, added: addedIDs), name: name) }
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
        datesRead = captured.count
        nasItems = index.items
        lastScan = index.scanned
        lastAdded = index.added ?? []
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
        datesTask = Task {
            let background = BackgroundWork(name: "Fechas de captura")
            defer { background.end() }
            let transport = NASTransport(account)
            var failures = 0, sinceSave = 0, sinceReorder = 0
            var read = self.datesRead
            var lastReorder = Date()
            var start = 0
            while start < pending.count, !Task.isCancelled {
                let chunk = Array(pending[start..<min(start + 4, pending.count)])
                start += chunk.count
                let results = await withTaskGroup(of: (String, CaptureInfo?).self) { group -> [(String, CaptureInfo?)] in
                    for item in chunk { group.addTask { (item.id, await CaptureReader.read(item, transport: transport)) } }
                    var out: [(String, CaptureInfo?)] = []
                    for await result in group { out.append(result) }
                    return out
                }
                guard !Task.isCancelled, self.account?.scope == account.scope else { return }
                for (id, info) in results {
                    if let info { captured[id] = info; failures = 0; sinceSave += 1; sinceReorder += 1; read += 1 } else { failures += 1 }
                }
                // The NAS stopped answering: stop here and resume when the app comes back.
                if failures >= 12 { break }
                if sinceSave >= 300 { saveCaptured(); sinceSave = 0 }
                // Published every hundred files, not on each one, to keep the screen calm.
                if read / 100 != (read - chunk.count) / 100 { datesRead = read; datesStatus = datesText(read, total) }
                // Reorder now and then, not on every file, so the wall does not keep moving.
                if sinceReorder > 0, Date().timeIntervalSince(lastReorder) > 180 {
                    await reorderByCapture(); sinceReorder = 0; lastReorder = Date()
                }
            }
            guard !Task.isCancelled else { return }
            saveCaptured()
            datesRead = read
            if sinceReorder > 0 { await reorderByCapture() }
            datesStatus = nil
            datesTask = nil
        }
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

    /// NAS files that were read but carry no capture date.
    var undatedItems: [GalleryItem] {
        captured.compactMap { $0.value.date == nil ? itemIndex[$0.key] : nil }.sorted { $0.date > $1.date }
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
        let checked = Set(captured.compactMap { $0.value.date == nil ? nil : $0.key })
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
            duplicateIDs = duplicates
            duplicatesHidden = duplicates.count
            nasShown = nasVisible
            items = merged
            itemIndex = index
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
    func open(_ item: GalleryItem, in list: [GalleryItem]) {
        let position = list.firstIndex { $0.id == item.id } ?? 0
        let window = list.isEmpty ? [item] : Array(list[max(0, position - 400)..<min(list.count, position + 400)])
        viewer = ViewerContext(items: window, start: item.id)
    }

    // MARK: Favorites and hidden

    func isFavorite(_ item: GalleryItem) -> Bool { favorites.contains(item.id) || (item.favorite && !favorites.contains("-" + item.id)) }

    /// Favorites live in the app; an iPhone favorite can be unmarked here without touching the library.
    func toggleFavorite(_ item: GalleryItem) {
        if isFavorite(item) {
            favorites.remove(item.id)
            if item.favorite { favorites.insert("-" + item.id) }
        } else {
            favorites.remove("-" + item.id)
            if !item.favorite { favorites.insert(item.id) }
        }
        save(favorites, as: favoritesName)
    }

    var favoriteItems: [GalleryItem] {
        itemIndex.values.filter { isFavorite($0) && !hidden.contains($0.id) }.sorted { $0.date > $1.date }
    }

    func isHidden(_ item: GalleryItem) -> Bool { hidden.contains(item.id) }

    func setHidden(_ item: GalleryItem, _ value: Bool) {
        if value { hidden.insert(item.id) } else { hidden.remove(item.id) }
        save(hidden, as: hiddenName)
        merge()
    }

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
