import SwiftUI

/// The app's own albums. They can mix photos from the iPhone and the NAS and live only in
/// the app: the iPhone library and the NAS are never changed.
struct AlbumsView: View {
    @EnvironmentObject var store: GalleryStore
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Álbumes").font(.system(size: 34, weight: .bold)).foregroundStyle(Palette.ink)
                        Spacer()
                        Button { newName = ""; naming = true } label: {
                            Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.accent)
                                .frame(width: 44, height: 44).contentShape(Circle())
                                .liquidCircle()
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityLabel("Nuevo álbum")
                    }
                    .padding(.top, 8)
                    if store.albums.isEmpty {
                        EmptyState(symbol: "rectangle.stack.badge.plus", title: "Crea tu primer álbum",
                                   message: "Junta fotos del iPhone y del NAS en un mismo álbum. Para agregar una foto, ábrela y toca el botón de álbum arriba a la derecha.",
                                   action: ("Nuevo álbum", { newName = ""; naming = true }))
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                            ForEach(store.albums) { album in
                                let items = store.items(in: album)
                                NavigationLink(value: album.id) {
                                    CoverCard(title: album.name, subtitle: countText(items.count, "elemento", "elementos"),
                                              cover: items.first, symbol: "rectangle.stack")
                                }
                                .buttonStyle(PressStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .contentMargins(.bottom, 110, for: .scrollContent)
            .background(AppBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { AlbumDetailView(id: $0) }
            .alert("Nuevo álbum", isPresented: $naming) {
                TextField("Nombre", text: $newName)
                Button("Cancelar", role: .cancel) {}
                Button("Crear") { store.createAlbum(newName) }
            }
        }
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
