import SwiftUI

/// NAS: every photo and video on the NAS in one wall, newest first, under a compact
/// header. The details and actions live in the «…» menu.
struct NASView: View {
    @EnvironmentObject var store: GalleryStore
    @Binding var scale: TimeScale
    @Binding var compact: Bool
    var topRequest: Int
    var jump: DateJump?
    var openSettings: () -> Void
    @State private var direction = BarDirection()

    var body: some View {
        PhotoWall(items: store.nasShown, revision: store.revision, scale: $scale, topRequest: topRequest, jump: jump,
                  onScroll: { direction.apply($0, user: $1, to: $compact) }, refresh: { await store.checkConnection() }) {
            header
        } empty: {
            empty
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("NAS").font(.system(size: 34, weight: .bold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if store.account != nil { menu }
            }
            HStack(spacing: 10) {
                StatusPill()
                // Free space and what is new, more useful than totals (those are in Espacio).
                if !store.nasDetail.isEmpty {
                    Text(store.nasDetail).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            ScanBanner()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var menu: some View {
        Menu {
            Section {
                if let account = store.account { Text("Carpeta: \(account.root.path)") }
                if let route = store.routeLabel { Text("Conexión: \(route)") }
                if let date = store.lastScan { Text("Última búsqueda: \(date.formatted(.relative(presentation: .named)))") }
            }
            Button { store.scan() } label: { Label(store.scanning ? "Buscando…" : "Buscar fotos nuevas", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(store.scanning)
            Button { Task { await store.checkConnection() } } label: { Label("Probar conexión", systemImage: "antenna.radiowaves.left.and.right") }
            Button(action: openSettings) { Label("Configuración del NAS", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .liquidCircle()
        }
        .accessibilityLabel("Opciones del NAS")
    }

    @ViewBuilder private var empty: some View {
        if store.account == nil {
            EmptyState(symbol: "server.rack", title: "Conecta tu NAS", message: "Agrega la carpeta de fotos de tu Synology en Configuración.",
                       action: ("Configurar NAS", openSettings))
                .padding(.top, 60)
        } else if store.scanning || !store.loaded {
            VStack(spacing: 14) {
                ProgressView()
                Text(store.scanStatus ?? "Cargando…").font(.subheadline).foregroundStyle(Palette.secondary)
            }
            .padding(.top, 120)
        } else {
            EmptyState(symbol: "photo", title: "Sin fotos todavía", message: "Busca las fotos y videos de tu NAS.",
                       action: ("Buscar fotos", { store.scan() }))
                .padding(.top, 60)
        }
    }
}

/// A square cover with a title under it, for albums.
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
    var remove: ((GalleryItem) -> Void)?

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
                .contextMenu {
                    if let remove {
                        Button(role: .destructive) { remove(item) } label: { Label("Quitar del álbum", systemImage: "minus.circle") }
                    }
                }
            }
        }
    }
}
