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

/// Photos from this day in an earlier year.
struct Memory: Identifiable {
    let year: Int
    let yearsAgo: Int
    let items: [GalleryItem]
    var id: Int { year }
    var title: String { yearsAgo == 1 ? "Hace 1 año" : "Hace \(yearsAgo) años" }
}

/// What Espacio shows, counted off the main thread.
struct SpaceStats {
    var photos = 0
    var videos = 0
    var phone = 0
    var nas = 0
    var years: [YearCount] = []
    var counts: [SmartCollection: Int] = [:]
    /// The newest item of each collection, for its cover.
    var covers: [SmartCollection: GalleryItem] = [:]
    var memories: [Memory] = []

    static func count(phone: [GalleryItem], nas: [GalleryItem], hidden: Set<String>, today: Date = Date(),
                      isFavorite: (GalleryItem) -> Bool) -> SpaceStats {
        var stats = SpaceStats()
        var years: [Int: Int] = [:]
        let calendar = Calendar.current
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        let todayOfYear = calendar.ordinality(of: .day, in: .year, for: today) ?? 0
        var sameDay: [Int: [GalleryItem]] = [:]
        var sameWeek: [Int: [GalleryItem]] = [:]

        func cover(_ collection: SmartCollection, _ item: GalleryItem) {
            stats.counts[collection, default: 0] += 1
            if let current = stats.covers[collection], current.date >= item.date { return }
            if item.isVideo && collection != .videos, stats.covers[collection] != nil { return }
            stats.covers[collection] = item
        }

        for item in phone + nas where !hidden.contains(item.id) {
            if item.isVideo { stats.videos += 1 } else { stats.photos += 1 }
            if item.isNAS { stats.nas += 1 } else { stats.phone += 1 }
            let parts = calendar.dateComponents([.year, .month, .day], from: item.date)
            let year = parts.year ?? 0
            years[year, default: 0] += 1
            if isFavorite(item) { cover(.favorites, item) }
            if item.isVideo { cover(.videos, item) }
            if item.kind == .livePhoto { cover(.livePhotos, item) }
            if item.isScreenshot { cover(.screenshots, item) }
            if item.isRAW { cover(.raw, item) }
            // Memories: the same day in earlier years, or the same week when no day matches.
            guard let currentYear = now.year, year > 1970, year < currentYear, !item.isScreenshot else { continue }
            if parts.month == now.month && parts.day == now.day { sameDay[year, default: []].append(item); continue }
            if let dayOfYear = calendar.ordinality(of: .day, in: .year, for: item.date), abs(dayOfYear - todayOfYear) <= 3 {
                sameWeek[year, default: []].append(item)
            }
        }
        stats.years = years.filter { $0.key > 1970 }.sorted { $0.key < $1.key }.map { YearCount(year: $0.key, count: $0.value) }
        let chosen = sameDay.isEmpty ? sameWeek : sameDay
        stats.memories = chosen.map { year, items in
            Memory(year: year, yearsAgo: (now.year ?? year) - year, items: items.sorted { $0.date > $1.date })
        }
        .sorted { $0.year > $1.year }
        return stats
    }
}

/// Espacio: your personal library. What matters first (memories, favorites, albums), then
/// collections and tools, and the numbers at the end.
struct SpaceView: View {
    @EnvironmentObject var store: GalleryStore
    @State private var naming = false
    @State private var newName = ""
    @State private var stats = SpaceStats()
    @State private var favorites: [GalleryItem] = []
    @State private var showHidden = false
    @State private var lockMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Espacio").font(.system(size: 34, weight: .bold)).foregroundStyle(Palette.ink)
                        Text("Tu biblioteca personal").font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                    .padding(.top, 8)
                    if !stats.memories.isEmpty { memories }
                    if !favorites.isEmpty { favoritesSection }
                    albumsSection
                    collections
                    utilities
                    section("Resumen") { summary }
                }
                .padding(.horizontal, 16)
            }
            .contentMargins(.bottom, 110, for: .scrollContent)
            .scrollIndicators(.hidden)
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
        let (phone, nas, hidden, favoriteIDs) = (store.phoneItems, store.nasItems, store.hidden, store.favorites)
        var result = await Task.detached(priority: .utility) {
            SpaceStats.count(phone: phone, nas: nas, hidden: hidden) { item in
                favoriteIDs.contains(item.id) || (item.favorite && !favoriteIDs.contains("-" + item.id))
            }
        }.value
        result.counts[.duplicates] = store.duplicateIDs.count
        result.counts[.recent] = store.lastAdded.count
        result.counts[.undated] = store.undatedItems.count
        result.covers[.recent] = store.lastAdded.lazy.compactMap { store.itemIndex[$0] }.first
        if let selfie = await PhoneLibrary.shared.ids(in: .smartAlbumSelfPortraits, limit: 1).first { result.covers[.selfies] = store.itemIndex[selfie] }
        stats = result
        favorites = Array(store.favoriteItems.prefix(24))
    }

    private func section<Content: View, Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
                                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold()).foregroundStyle(Palette.ink)
                Spacer()
                trailing()
            }
            content()
        }
    }

    /// A row that scrolls sideways edge to edge.
    private func carousel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12, content: content).padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    // MARK: Memories

    private var memories: some View {
        section("Recuerdos") {
            carousel {
                ForEach(stats.memories) { memory in
                    Button { if let first = memory.items.first { store.open(first, in: memory.items) } } label: {
                        MemoryCard(memory: memory)
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }

    // MARK: Favorites

    private var favoritesSection: some View {
        section("Favoritos") {
            NavigationLink(value: SmartCollection.favorites) {
                Text("Ver todos").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
            }
        } content: {
            carousel {
                ForEach(favorites) { item in
                    Button { store.open(item, in: favorites) } label: {
                        Thumbnail(item: item, pixelSize: 130)
                            .frame(width: 130, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }

    // MARK: Albums

    private var albumsSection: some View {
        section("Mis álbumes") {
            carousel {
                Button { newName = ""; naming = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Palette.accent.opacity(0.08))
                            .overlay { Image(systemName: "plus").font(.system(size: 28, weight: .semibold)).foregroundStyle(Palette.accent) }
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.accent.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                            .frame(width: 150, height: 150)
                        Text("Nuevo álbum").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text(" ").font(.caption)
                    }
                }
                .buttonStyle(PressStyle())
                ForEach(store.albums) { album in
                    let items = store.items(in: album)
                    NavigationLink(value: album.id) {
                        CoverCard(title: album.name, subtitle: countText(items.count, "elemento", "elementos"), cover: items.first, symbol: "rectangle.stack")
                            .frame(width: 150)
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }

    // MARK: Collections

    private var collections: some View {
        section("Colecciones") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach([SmartCollection.videos, .livePhotos, .selfies, .screenshots, .raw, .recent]) { collection in
                    NavigationLink(value: collection) {
                        CollectionTile(collection: collection, cover: stats.covers[collection], count: stats.counts[collection])
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }

    // MARK: Utilities

    private var utilities: some View {
        section("Utilidades") {
            HStack(spacing: 10) {
                NavigationLink(value: SmartCollection.duplicates) { chip("Duplicados", "square.on.square", stats.counts[.duplicates]) }
                NavigationLink(value: SmartCollection.undated) { chip("Sin fecha", "calendar.badge.exclamationmark", stats.counts[.undated]) }
                Button { Task { await unlock() } } label: { chip("Oculto", "lock.fill", nil) }
            }
            .buttonStyle(PressStyle())
        }
    }

    private func chip(_ title: String, _ symbol: String, _ count: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.8)
                Text(count.map { $0.formatted() } ?? "Face ID").font(.caption).foregroundStyle(Palette.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white, lineWidth: 1))
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

/// «Hace 3 años»: a large photo of that day with the title over it.
struct MemoryCard: View {
    let memory: Memory
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let cover = memory.items.first(where: { !$0.isVideo }) ?? memory.items.first {
                Thumbnail(item: cover, pixelSize: 280).frame(width: 260, height: 180)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.title).font(.title3.bold())
                Text(String(memory.year) + " · " + mediaSummary(memory.items)).font(.caption.weight(.medium)).opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .frame(width: 260, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(memory.title), \(memory.year)")
    }
}

/// A collection with its newest photo behind the title and the count.
struct CollectionTile: View {
    let collection: SmartCollection
    let cover: GalleryItem?
    let count: Int?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let cover {
                GeometryReader { geo in Thumbnail(item: cover, pixelSize: geo.size.width).frame(width: geo.size.width, height: geo.size.height) }
            } else {
                Palette.selection.opacity(0.85)
            }
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: collection.symbol).font(.system(size: 15, weight: .semibold))
                Text(collection.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                if let count { Text(count.formatted()).font(.caption).opacity(0.9) }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(height: 124)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(collection.title)\(count.map { ", \($0)" } ?? "")")
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
