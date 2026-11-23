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

struct ViewerContext: Identifiable {
    let id = UUID()
    let items: [GalleryItem]
    let start: String
}

/// The app state: the iPhone library, the NAS index and the merged timeline.
@MainActor
final class GalleryStore: ObservableObject {
    @Published private(set) var account: NASAccount?
    @Published private(set) var phoneItems: [GalleryItem] = []
    @Published private(set) var nasItems: [GalleryItem] = []
    /// Both sources merged, newest first.
    @Published private(set) var items: [GalleryItem] = []
    /// Changes whenever `items` changes, so views can redo their layout cheaply.
    @Published private(set) var revision = 0
    @Published private(set) var photoAccess = PhotoAccess.notDetermined
    @Published private(set) var nasState = NASState.notConfigured
    @Published private(set) var lastRoute: String?
    @Published private(set) var scanning = false
    @Published private(set) var scanStatus: String?
    @Published private(set) var lastScan: Date?
    @Published private(set) var connecting = false
    @Published var viewer: ViewerContext?
    @Published var error: String?
    @Published var showPhone = UserDefaults.standard.object(forKey: "showPhone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPhone, forKey: "showPhone"); merge() }
    }
    @Published var showNAS = UserDefaults.standard.object(forKey: "showNAS") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNAS, forKey: "showNAS"); merge() }
    }

    private var scanTask: Task<Void, Never>?
    private var learnedAspects: [String: Double] = [:]

    private var indexName: String { "nas-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private var aspectsName: String { "aspects-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }

    init() {
        account = AccountKeychain.load()
        photoAccess = PhoneLibrary.access
        if account != nil { loadIndex(); nasState = .checking }
        PhoneLibrary.shared.onChange = { [weak self] in Task { await self?.reloadPhone() } }
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
        await reloadPhone()
        guard account != nil else { return }
        await checkConnection()
        if nasItems.isEmpty && nasState == .connected { scan() }
    }

    func refresh() async {
        await reloadPhone()
        if account != nil { scan(); await scanTask?.value }
    }

    // MARK: iPhone

    func requestPhotoAccess() async {
        photoAccess = await PhoneLibrary.requestAccess()
        await reloadPhone()
    }

    func reloadPhone() async {
        photoAccess = PhoneLibrary.access
        guard photoAccess.canRead else { phoneItems = []; merge(); return }
        phoneItems = await PhoneLibrary.shared.load()
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
            if changed { scanTask?.cancel(); scanning = false }
            account = candidate
            lastRoute = response.route
            nasState = .connected
            if changed { loadIndex(); scan() }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        do { try AccountKeychain.clear() } catch { self.error = error.localizedDescription; return }
        scanTask?.cancel(); scanning = false; scanStatus = nil
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
        scanning = true; scanStatus = "Buscando fotos en el NAS…"
        let aspects = learnedAspects
        scanTask = Task {
            defer { scanning = false }
            do {
                let found = try await NASScanner(account: account, learnedAspects: aspects).scan { folder, count in
                    Task { @MainActor [weak self] in
                        self?.scanStatus = "\(count.formatted()) archivos · \(folder.isEmpty ? "carpeta principal" : folder)"
                    }
                }
                guard self.account?.scope == account.scope else { return }
                nasItems = found; lastScan = Date(); nasState = .connected; scanStatus = nil
                try? Files.save(NASIndex(items: found, scanned: lastScan), name: indexName)
                merge()
            } catch {
                scanStatus = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                if self.account?.scope == account.scope { nasState = .offline }
                self.error = error.localizedDescription
            }
        }
    }

    private func loadIndex() {
        learnedAspects = Files.load(aspectsName, as: [String: Double].self) ?? [:]
        let index = Files.load(indexName, as: NASIndex.self) ?? NASIndex()
        nasItems = index.items.map { item in
            var item = item
            if let aspect = learnedAspects[item.id] { item.aspect = aspect }
            return item
        }
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
        try? Files.save(learnedAspects, name: aspectsName)
    }

    // MARK: Timeline

    private func merge() {
        let phone = showPhone ? phoneItems : []
        let nas = showNAS ? nasItems : []
        if phone.isEmpty { items = nas } else if nas.isEmpty { items = phone } else {
            items = (phone + nas).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        }
        revision += 1
    }

    func open(_ item: GalleryItem, in list: [GalleryItem]) {
        viewer = ViewerContext(items: list, start: item.id)
    }

}
