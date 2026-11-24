import SwiftUI
import LocalAuthentication

/// The automatic collections of Espacio. They mix the iPhone and the NAS.
enum SmartCollection: String, Hashable, CaseIterable, Identifiable {
    case favorites, videos, livePhotos, screenshots, raw, selfies
    case duplicates, recent, undated
    var id: String { rawValue }

    static let types: [SmartCollection] = [.favorites, .videos, .livePhotos, .screenshots, .raw, .selfies]
    static let utilities: [SmartCollection] = [.duplicates, .recent, .undated]

    var title: String {
        switch self {
        case .favorites: return "Favoritos"
        case .videos: return "Videos"
        case .livePhotos: return "Live Photos"
        case .screenshots: return "Capturas de pantalla"
        case .raw: return "RAW"
        case .selfies: return "Selfies"
        case .duplicates: return "Duplicados"
        case .recent: return "Agregadas recientemente"
        case .undated: return "Sin fecha de captura"
        }
    }

    var symbol: String {
        switch self {
        case .favorites: return "heart.fill"
        case .videos: return "video.fill"
        case .livePhotos: return "livephoto"
        case .screenshots: return "camera.viewfinder"
        case .raw: return "camera.aperture"
        case .selfies: return "person.crop.square"
        case .duplicates: return "square.on.square"
        case .recent: return "clock.arrow.circlepath"
        case .undated: return "calendar.badge.exclamationmark"
        }
    }

    var note: String? {
        switch self {
        case .duplicates: return "Fotos del NAS que también están en este iPhone. En Fototeca se muestran una sola vez."
        case .recent: return "Lo nuevo de la última búsqueda en el NAS y lo último agregado al iPhone."
        case .undated: return "Archivos del NAS sin fecha de captura dentro del archivo; se ordenan por su nombre, carpeta o fecha de modificación."
        default: return nil
        }
    }
}

struct YearCount: Hashable {
    let year: Int
    let count: Int
}

/// Numbers for the summary, counted off the main thread.
struct SpaceStats {
    var photos = 0
    var videos = 0
    var phone = 0
    var nas = 0
    var years: [YearCount] = []
    var counts: [SmartCollection: Int] = [:]

    static func count(phone: [GalleryItem], nas: [GalleryItem], hidden: Set<String>, isFavorite: (GalleryItem) -> Bool) -> SpaceStats {
        var stats = SpaceStats()
        var years: [Int: Int] = [:]
        let calendar = Calendar.current
        for item in phone + nas where !hidden.contains(item.id) {
            if item.isVideo { stats.videos += 1 } else { stats.photos += 1 }
            if item.isNAS { stats.nas += 1 } else { stats.phone += 1 }
            years[calendar.component(.year, from: item.date), default: 0] += 1
            if isFavorite(item) { stats.counts[.favorites, default: 0] += 1 }
            if item.isVideo { stats.counts[.videos, default: 0] += 1 }
            if item.kind == .livePhoto { stats.counts[.livePhotos, default: 0] += 1 }
            if item.isScreenshot { stats.counts[.screenshots, default: 0] += 1 }
            if item.isRAW { stats.counts[.raw, default: 0] += 1 }
        }
        stats.years = years.filter { $0.key > 1970 }.sorted { $0.key < $1.key }.map { YearCount(year: $0.key, count: $0.value) }
        return stats
    }
}

/// Espacio: a summary of the whole library, the app's albums, automatic collections and
/// the hidden album.
struct SpaceView: View {
    @EnvironmentObject var store: GalleryStore
    @State private var naming = false
    @State private var newName = ""
    @State private var stats = SpaceStats()
    @State private var showHidden = false
    @State private var lockMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Espacio").font(.system(size: 34, weight: .bold)).foregroundStyle(Palette.ink).padding(.top, 8)
                    summary
                    albumsSection
                    list("Tipos", SmartCollection.types)
                    list("Utilidades", SmartCollection.utilities)
                    privateSection
                }
                .padding(.horizontal, 16)
            }
            .contentMargins(.bottom, 110, for: .scrollContent)
            .background(AppBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { AlbumDetailView(id: $0) }
            .navigationDestination(for: SmartCollection.self) { CollectionView(collection: $0) }
            .navigationDestination(isPresented: $showHidden) { HiddenView() }
            .alert("Nuevo álbum", isPresented: $naming) {
                TextField("Nombre", text: $newName)
                Button("Cancelar", role: .cancel) {}
                Button("Crear") { store.createAlbum(newName) }
            }
            .alert("No se pudo abrir", isPresented: Binding(get: { lockMessage != nil }, set: { if !$0 { lockMessage = nil } })) {
                Button("Aceptar", role: .cancel) {}
            } message: { Text(lockMessage ?? "") }
            .task(id: "\(store.revision)-\(store.favorites.count)-\(store.hidden.count)") { await count() }
        }
    }

    private func count() async {
        let (phone, nas, hidden, favorites) = (store.phoneItems, store.nasItems, store.hidden, store.favorites)
        var result = await Task.detached(priority: .utility) {
            SpaceStats.count(phone: phone, nas: nas, hidden: hidden) { item in
                favorites.contains(item.id) || (item.favorite && !favorites.contains("-" + item.id))
            }
        }.value
        result.counts[.duplicates] = store.duplicateIDs.count
        result.counts[.recent] = store.lastAdded.count
        result.counts[.undated] = store.undatedItems.count
        stats = result
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                number(stats.photos, "fotos")
                number(stats.videos, "videos")
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                Label(stats.phone.formatted(), systemImage: "iphone")
                Label(stats.nas.formatted(), systemImage: "server.rack")
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary)

            if let space = store.nasSpace, let used = space.used, let total = space.total, total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(used), total: Double(total)).tint(Palette.accent)
                    Text("\(store.nasLabel): \(store.spaceText ?? "")").font(.footnote).foregroundStyle(Palette.secondary)
                }
            }

            if !stats.years.isEmpty { yearsChart }

            if store.account != nil {
                VStack(alignment: .leading, spacing: 6) {
                    let total = max(store.nasItems.count, 1)
                    HStack {
                        Text("Fechas de captura").font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(store.datesRead >= store.nasItems.count ? "Listas" : "\(store.datesRead.formatted()) de \(store.nasItems.count.formatted())")
                            .font(.footnote).foregroundStyle(Palette.secondary)
                    }
                    if store.datesRead < store.nasItems.count {
                        ProgressView(value: Double(store.datesRead), total: Double(total)).tint(Palette.accent)
                    }
                    if store.duplicatesHidden > 0 {
                        Text("\(store.duplicatesHidden.formatted()) fotos del NAS ya están en este iPhone y se muestran una vez.")
                            .font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
        .card()
    }

    private func number(_ value: Int, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted()).font(.system(size: 30, weight: .bold)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(unit).font(.subheadline).foregroundStyle(Palette.secondary)
        }
    }

    /// Photos per year, as small bars.
    private var yearsChart: some View {
        let highest = max(stats.years.map(\.count).max() ?? 1, 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(stats.years, id: \.year) { entry in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Palette.selection)
                            .frame(width: 22, height: max(4, 70 * CGFloat(entry.count) / CGFloat(highest)))
                        Text("’" + String(String(entry.year).suffix(2))).font(.caption2).foregroundStyle(Palette.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.year): \(entry.count.formatted()) fotos")
                }
            }
            .frame(height: 92, alignment: .bottom)
        }
        .defaultScrollAnchor(.trailing)
    }

    // MARK: Albums

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mis álbumes").font(.title3.bold()).foregroundStyle(Palette.ink)
                Spacer()
                Button { newName = ""; naming = true } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accent)
                        .frame(width: 38, height: 38).contentShape(Circle())
                        .liquidCircle()
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Nuevo álbum")
            }
            if store.albums.isEmpty {
                Text("Junta fotos del iPhone y del NAS. Para agregar una, ábrela y toca el botón de álbum.")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(store.albums) { album in
                            let items = store.items(in: album)
                            NavigationLink(value: album.id) {
                                CoverCard(title: album.name, subtitle: countText(items.count, "elemento", "elementos"), cover: items.first, symbol: "rectangle.stack")
                                    .frame(width: 140)
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
            }
        }
    }

    // MARK: Lists

    private func list(_ title: String, _ collections: [SmartCollection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).foregroundStyle(Palette.ink)
            VStack(spacing: 0) {
                ForEach(Array(collections.enumerated()), id: \.element) { index, collection in
                    NavigationLink(value: collection) {
                        row(collection.title, symbol: collection.symbol, count: stats.counts[collection])
                    }
                    .buttonStyle(.plain)
                    if index < collections.count - 1 { Divider().padding(.leading, 52) }
                }
            }
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white, lineWidth: 1))
        }
    }

    private func row(_ title: String, symbol: String, count: Int?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 26)
            Text(title).foregroundStyle(Palette.ink)
            Spacer()
            if let count { Text(count.formatted()).foregroundStyle(Palette.secondary).monospacedDigit() }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary.opacity(0.6))
        }
        .padding(.horizontal, 14).frame(height: 50)
        .contentShape(Rectangle())
    }

    private var privateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privado").font(.title3.bold()).foregroundStyle(Palette.ink)
            Button { Task { await unlock() } } label: {
                row("Oculto", symbol: "eye.slash.fill", count: nil)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "faceid").foregroundStyle(Palette.secondary).padding(.trailing, 40)
                    }
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white, lineWidth: 1))
            Text("Las fotos ocultas no aparecen en Fototeca ni en NAS. Para ocultar una, ábrela y toca el ojo.")
                .font(.footnote).foregroundStyle(Palette.secondary)
        }
    }

    /// Face ID (or the passcode) opens the hidden album.
    private func unlock() async {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            lockMessage = "Activa un código o Face ID en este iPhone para proteger las fotos ocultas."
            return
        }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Abre tus fotos ocultas") { showHidden = true }
        } catch {
            if (error as? LAError)?.code != .userCancel { lockMessage = error.localizedDescription }
        }
    }
}

/// One automatic collection, as a grid.
struct CollectionView: View {
    @EnvironmentObject var store: GalleryStore
    let collection: SmartCollection
    @State private var items: [GalleryItem]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let note = collection.note { Text(note).font(.footnote).foregroundStyle(Palette.secondary) }
                if let items {
                    if items.isEmpty {
                        EmptyState(symbol: collection.symbol, title: "Nada por aquí", message: "No hay elementos en \(collection.title.lowercased()).")
                    } else {
                        Text(mediaSummary(items)).font(.footnote).foregroundStyle(Palette.secondary)
                        SquareGrid(items: items)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(AppBackground())
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.large)
        .task(id: "\(store.revision)-\(store.favorites.count)") { items = await store.items(for: collection) }
    }
}

/// The hidden album, after Face ID.
struct HiddenView: View {
    @EnvironmentObject var store: GalleryStore

    var body: some View {
        let items = store.hiddenItems
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    EmptyState(symbol: "eye.slash", title: "Sin fotos ocultas", message: "Abre una foto y toca el ojo para ocultarla de Fototeca y NAS.")
                } else {
                    Text(mediaSummary(items)).font(.footnote).foregroundStyle(Palette.secondary)
                    SquareGrid(items: items)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(AppBackground())
        .navigationTitle("Oculto")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var album: AppAlbum? { store.albums.first { $0.id == id } }

    var body: some View {
        let items = album.map { store.items(in: $0) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    EmptyState(symbol: "photo.badge.plus", title: "Álbum vacío",
                               message: "Abre una foto en Fototeca o NAS y toca el botón de álbum para agregarla aquí.")
                } else {
                    Text(mediaSummary(items)).font(.footnote).foregroundStyle(Palette.secondary)
                    SquareGrid(items: items, remove: { store.remove($0.id, from: id) })
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(AppBackground())
        .navigationTitle(album?.name ?? "Álbum")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newName = album?.name ?? ""; renaming = true } label: { Label("Cambiar nombre", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Eliminar álbum", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .alert("Cambiar nombre", isPresented: $renaming) {
            TextField("Nombre", text: $newName)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") { store.renameAlbum(id, to: newName) }
        }
        .confirmationDialog("¿Eliminar este álbum?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Eliminar álbum", role: .destructive) { store.deleteAlbum(id); dismiss() }
        } message: {
            Text("Las fotos no se borran del iPhone ni del NAS.")
        }
    }
}

/// Opened from the viewer: add or remove the photo from albums, or make a new one.
struct AddToAlbumSheet: View {
    @EnvironmentObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    let itemID: String
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Nuevo álbum", text: $newName)
                        Button("Crear") {
                            store.createAlbum(newName, with: [itemID])
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !store.albums.isEmpty {
                    Section("Mis álbumes") {
                        ForEach(store.albums) { album in
                            Button { store.toggle(itemID, in: album.id) } label: {
                                HStack {
                                    Text(album.name).foregroundStyle(Palette.ink)
                                    Spacer()
                                    if album.items.contains(itemID) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                                    else { Image(systemName: "circle").foregroundStyle(Palette.secondary.opacity(0.5)) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Agregar a álbum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
