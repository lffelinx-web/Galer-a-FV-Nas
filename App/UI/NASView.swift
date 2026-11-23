import SwiftUI

struct FolderEntry: Identifiable {
    let path: String
    let name: String
    let count: Int
    let cover: GalleryItem?
    var id: String { path }
}

/// The folder tree of the NAS index, built without asking the NAS again.
enum FolderTree {
    static func children(of path: String, in items: [GalleryItem]) -> (folders: [FolderEntry], files: [GalleryItem]) {
        var files: [GalleryItem] = []
        var counts: [String: Int] = [:]
        var covers: [String: GalleryItem] = [:]
        let prefix = path.isEmpty ? "" : path + "/"
        for item in items {
            let folder = item.folder ?? ""
            if folder == path { files.append(item); continue }
            guard folder.hasPrefix(prefix), folder.count > prefix.count else { continue }
            let name = String(folder.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first ?? "")
            guard !name.isEmpty else { continue }
            counts[name, default: 0] += 1
            if covers[name] == nil || (covers[name]!.isVideo && !item.isVideo) { covers[name] = item }
        }
        let folders = counts.map { FolderEntry(path: prefix + $0.key, name: $0.key, count: $0.value, cover: covers[$0.key]) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (folders, files)
    }
}

struct FolderRoute: Hashable { let path: String }

struct NASView: View {
    @EnvironmentObject var store: GalleryStore
    var openSettings: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("NAS").font(.largeTitle.bold()).foregroundStyle(Palette.ink).padding(.top, 8)
                    statusCard
                    if store.account != nil {
                        let tree = FolderTree.children(of: "", in: store.nasItems)
                        if !tree.folders.isEmpty {
                            Text("Carpetas").font(.title3.bold()).foregroundStyle(Palette.ink).padding(.top, 4)
                            FolderGrid(folders: tree.folders)
                        }
                        if !tree.files.isEmpty {
                            Text("En la carpeta principal").font(.title3.bold()).foregroundStyle(Palette.ink).padding(.top, 4)
                            SquareGrid(items: tree.files)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .contentMargins(.bottom, 110, for: .scrollContent)
            .background(AppBackground())
            .refreshable { await store.checkConnection() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FolderRoute.self) { FolderView(path: $0.path) }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Palette.selection, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.account == nil ? "Sin NAS" : store.nasLabel).font(.title3.bold()).foregroundStyle(Palette.ink)
                    Text(store.account?.root.host ?? "Agrega tu Synology en Configuración").font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            StatusPill()
            if let account = store.account {
                VStack(spacing: 10) {
                    row("Carpeta", account.root.path)
                    if let route = store.routeLabel { row("Conexión", route) }
                    row("Contenido", store.nasItems.isEmpty ? "Sin buscar todavía" : mediaSummary(store.nasItems))
                    if let date = store.lastScan { row("Última búsqueda", date.formatted(.relative(presentation: .named))) }
                }
                if let status = store.scanStatus {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1) }
                }
                HStack(spacing: 10) {
                    actionButton(store.scanning ? "Buscando…" : "Buscar fotos nuevas", symbol: "arrow.triangle.2.circlepath", primary: true) { store.scan() }
                        .disabled(store.scanning)
                    actionButton("Probar", symbol: "antenna.radiowaves.left.and.right", primary: false) { Task { await store.checkConnection() } }
                }
            } else {
                actionButton("Configurar NAS", symbol: "gearshape", primary: true, action: openSettings)
            }
        }
        .card()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline).foregroundStyle(Palette.secondary)
            Spacer(minLength: 12)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing).lineLimit(2)
        }
    }

    private func actionButton(_ title: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primary ? Color.white : Palette.accent)
                .frame(maxWidth: primary ? .infinity : nil).padding(.horizontal, 16).frame(height: 44)
                .background {
                    if primary { Capsule().fill(Palette.selection) } else { Capsule().fill(Palette.accent.opacity(0.1)) }
                }
        }
        .buttonStyle(PressStyle())
    }
}

struct FolderView: View {
    @EnvironmentObject var store: GalleryStore
    let path: String

    var body: some View {
        let tree = FolderTree.children(of: path, in: store.nasItems)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !tree.folders.isEmpty { FolderGrid(folders: tree.folders) }
                if !tree.files.isEmpty {
                    Text(mediaSummary(tree.files)).font(.footnote).foregroundStyle(Palette.secondary)
                    SquareGrid(items: tree.files)
                }
                if tree.folders.isEmpty && tree.files.isEmpty {
                    EmptyState(symbol: "folder", title: "Carpeta vacía", message: "No hay fotos ni videos aquí.")
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(AppBackground())
        .navigationTitle(path.split(separator: "/").last.map(String.init) ?? "NAS")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct FolderGrid: View {
    var folders: [FolderEntry]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
            ForEach(folders) { folder in
                NavigationLink(value: FolderRoute(path: folder.path)) {
                    CoverCard(title: folder.name, subtitle: countText(folder.count, "elemento", "elementos"), cover: folder.cover, symbol: "folder.fill")
                }
                .buttonStyle(PressStyle())
            }
        }
    }
}

/// A square cover with a title under it, for albums and folders.
struct CoverCard: View {
    var title: String
    var subtitle: String
    var cover: GalleryItem?
    var symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let cover {
                        GeometryReader { geo in Thumbnail(item: cover, pixelSize: geo.size.width).frame(width: geo.size.width, height: geo.size.height) }
                    } else {
                        ZStack { Palette.tile; Image(systemName: symbol).font(.largeTitle).foregroundStyle(Palette.accent.opacity(0.5)) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(Palette.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// A grid of square tiles that opens the viewer on tap.
struct SquareGrid: View {
    @EnvironmentObject var store: GalleryStore
    var items: [GalleryItem]
    var columns = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(items) { item in
                Button { store.open(item, in: items) } label: {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { GeometryReader { geo in Thumbnail(item: item, pixelSize: geo.size.width).frame(width: geo.size.width, height: geo.size.height) } }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(PressStyle())
            }
        }
    }
}
