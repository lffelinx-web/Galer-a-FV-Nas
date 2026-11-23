import SwiftUI

enum AlbumRoute: Hashable {
    case phone(id: String, title: String)
}

struct AlbumsView: View {
    @EnvironmentObject var store: GalleryStore
    @State private var phoneAlbums: [PhoneAlbum] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Álbumes").font(.largeTitle.bold()).foregroundStyle(Palette.ink).padding(.top, 8)
                    if store.photoAccess.canRead {
                        sectionTitle("En este iPhone", symbol: "iphone")
                        if phoneAlbums.isEmpty && !loaded {
                            ProgressView().frame(maxWidth: .infinity).padding(30)
                        } else if phoneAlbums.isEmpty {
                            Text("No hay álbumes.").font(.subheadline).foregroundStyle(Palette.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                                ForEach(phoneAlbums) { album in
                                    NavigationLink(value: AlbumRoute.phone(id: album.id, title: album.title)) {
                                        CoverCard(title: album.title, subtitle: countText(album.count, "elemento", "elementos"), cover: album.cover, symbol: "photo.on.rectangle")
                                    }
                                    .buttonStyle(PressStyle())
                                }
                            }
                        }
                    }
                    if store.account != nil {
                        let folders = FolderTree.children(of: "", in: store.nasItems).folders
                        sectionTitle("En el NAS · \(store.nasLabel)", symbol: "server.rack")
                        if folders.isEmpty {
                            Text(store.scanning ? "Buscando carpetas…" : "Las carpetas del NAS aparecerán aquí.").font(.subheadline).foregroundStyle(Palette.secondary)
                        } else {
                            FolderGrid(folders: folders)
                        }
                    }
                    if !store.photoAccess.canRead && store.account == nil {
                        EmptyState(symbol: "rectangle.stack", title: "Sin álbumes", message: "Permite el acceso a tus fotos o conecta tu NAS para ver tus álbumes.")
                    }
                }
                .padding(.horizontal, 16)
            }
            .contentMargins(.bottom, 110, for: .scrollContent)
            .background(AppBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AlbumRoute.self) { route in
                switch route {
                case .phone(let id, let title): PhoneAlbumView(id: id, title: title)
                }
            }
            .navigationDestination(for: FolderRoute.self) { FolderView(path: $0.path) }
            .task(id: store.photoAccess) { await loadAlbums() }
            .onChange(of: store.revision) { Task { await loadAlbums() } }
        }
    }

    private func loadAlbums() async {
        guard store.photoAccess.canRead else { phoneAlbums = []; loaded = true; return }
        phoneAlbums = await PhoneLibrary.shared.albums()
        loaded = true
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.title3.bold()).foregroundStyle(Palette.ink).padding(.top, 4)
    }
}

struct PhoneAlbumView: View {
    let id: String
    let title: String
    @State private var items: [GalleryItem] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loaded {
                    Text(mediaSummary(items)).font(.footnote).foregroundStyle(Palette.secondary)
                    SquareGrid(items: items)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(AppBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .task {
            items = await PhoneLibrary.shared.items(inAlbum: id)
            loaded = true
        }
    }
}
