import SwiftUI
import AVKit
import MapKit

/// Full-screen viewer: swipe sideways between photos, pinch or double tap to zoom, swipe
/// down to close and up for the information. Below, the neighbours in a strip and the
/// actions: Compartir, Favorito, Información and Más.
struct ViewerView: View {
    let context: ViewerContext
    @EnvironmentObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    @State private var current: String?
    @State private var chrome = true
    @State private var zoomed = false
    @State private var dragY: CGFloat = 0
    @State private var albumItem: GalleryItem?
    @State private var infoItem: GalleryItem?
    @State private var shareFile: ShareFile?
    @State private var working: String?
    @State private var toast: String?
    /// 0: the photo sits on its tile; 1: it fills the screen. Animated when opening and closing.
    @State private var progress: CGFloat
    @State private var settled: Bool
    private let positions: [String: Int]

    private var hasSource: Bool { context.sourceFrame != nil && context.sourceImage != nil }

    init(context: ViewerContext) {
        self.context = context
        _current = State(initialValue: context.start)
        let zooms = context.sourceFrame != nil && context.sourceImage != nil
        _progress = State(initialValue: zooms ? 0 : 1)
        _settled = State(initialValue: !zooms)
        var positions: [String: Int] = [:]
        positions.reserveCapacity(context.items.count)
        for (index, item) in context.items.enumerated() { positions[item.id] = index }
        self.positions = positions
    }

    private var currentItem: GalleryItem? { current.flatMap { positions[$0] }.map { context.items[$0] } }

    var body: some View {
        ZStack {
            Color.black.opacity((1 - min(dragY / 500, 0.7)) * progress).ignoresSafeArea()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(context.items) { item in
                        ViewerPage(item: item, active: item.id == current, chrome: chrome && settled, poster: poster(for: item),
                                   toggleChrome: { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } },
                                   zoomChanged: { zoomed = $0 })
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .scrollDisabled(zoomed)
            .ignoresSafeArea()
            .offset(y: dragY)
            .scaleEffect(1 - min(dragY / 2500, 0.15))
            .simultaneousGesture(verticalGesture, including: zoomed ? .none : .all)
            .opacity(settled ? 1 : 0)
            if !settled { zoomLayer }
        }
        .overlay(alignment: .top) {
            if chrome && settled { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if chrome && settled { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay {
            if let working {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(working).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                }
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 18).frame(height: 42)
                    .liquidCapsule()
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .presentationBackground(.clear)
        .onAppear {
            guard !settled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { progress = 1 } completion: { settled = true }
        }
        .statusBarHidden(!chrome)
        .sheet(item: $albumItem) { AddToAlbumSheet(itemID: $0.id).environmentObject(store) }
        .sheet(item: $infoItem) { InfoSheet(item: $0).environmentObject(store) }
        .sheet(item: $shareFile) { ActivitySheet(items: [$0.url]).ignoresSafeArea() }
        .onChange(of: current) { zoomed = false }
    }

    /// The picture the page shows at once: the uncropped one from the tap for the first
    /// photo, otherwise the NAS thumbnail already in memory.
    private func poster(for item: GalleryItem) -> UIImage? {
        if item.id == context.start, context.sourceIsWhole, let image = context.sourceImage { return image }
        return item.nasURL.flatMap { NASImageLoader.shared.cached($0) }
    }

    // MARK: Zoom in and out

    /// The tapped photo moving between its tile and the full screen. The picture keeps its
    /// real shape; the frame around it opens from the tile's crop to the whole photo.
    private var zoomLayer: some View {
        GeometryReader { geo in
            if let image = context.sourceImage, let source = context.sourceFrame {
                let target = fitted(aspect: aspect(of: image), in: CGRect(origin: .zero, size: geo.size))
                let frame = CGRect(x: source.minX + (target.minX - source.minX) * progress,
                                   y: source.minY + (target.minY - source.minY) * progress + dragY,
                                   width: source.width + (target.width - source.width) * progress,
                                   height: source.height + (target.height - source.height) * progress)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8 * (1 - progress), style: .continuous))
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func aspect(of image: UIImage) -> CGFloat {
        if context.sourceIsWhole, image.size.height > 0 { return image.size.width / image.size.height }
        if let item = context.items.first(where: { $0.id == context.start }), item.aspect > 0 { return CGFloat(item.aspect) }
        return image.size.height > 0 ? image.size.width / image.size.height : 1
    }

    private func fitted(aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspect > 0, bounds.height > 0 else { return bounds }
        if aspect > bounds.width / bounds.height {
            let height = bounds.width / aspect
            return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        }
        let width = bounds.height * aspect
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
    }

    /// Back to the tile when the photo shown is the one that was tapped; otherwise a plain close.
    private func close() {
        guard hasSource, current == context.start, !zoomed else { dismiss(); return }
        settled = false
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { progress = 0; dragY = 0 } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }

    /// Down closes, up opens the information.
    private var verticalGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) * 1.4 else { return }
                dragY = value.translation.height
            }
            .onEnded { value in
                let vertical = abs(value.translation.height) > abs(value.translation.width) * 1.4
                if vertical && value.translation.height < -60 { infoItem = currentItem; return }
                if dragY > 130 || value.predictedEndTranslation.height > 400 && dragY > 40 { close() }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 } }
            }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                    .frame(width: 46, height: 46).contentShape(Circle())
                    .liquidCircle()
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Cerrar")
            if let item = currentItem {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Timeline.format(item.date, "d 'de' MMMM 'de' y")).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(detail(item)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 16).frame(height: 46)
                .liquidCapsule()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Filmstrip(items: context.items, current: $current)
            if let item = currentItem { actions(item) }
        }
        .padding(.bottom, 6)
    }

    /// Compartir · Favorito · Información · Más.
    private func actions(_ item: GalleryItem) -> some View {
        let favorite = store.isFavorite(item)
        let hidden = store.isHidden(item)
        return HStack(spacing: 0) {
            barButton("square.and.arrow.up", "Compartir") { Task { await share(item) } }
            barButton(favorite ? "heart.fill" : "heart", favorite ? "Quitar de favoritos" : "Favorito", tint: favorite ? .red : nil) {
                store.toggleFavorite(item)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: favorite)
            barButton("info.circle", "Información") { infoItem = item }
            Menu {
                Button { albumItem = item } label: { Label("Agregar a álbum", systemImage: "rectangle.stack.badge.plus") }
                if item.isNAS {
                    Button { Task { await saveToPhone(item) } } label: { Label("Guardar en el iPhone", systemImage: "square.and.arrow.down") }
                }
                if !item.isVideo {
                    Button { Task { await copy(item) } } label: { Label("Copiar", systemImage: "doc.on.doc") }
                }
                Button { showDay(item) } label: { Label("Ver en el día", systemImage: "calendar") }
                Divider()
                Button { store.setHidden(item, !hidden) } label: {
                    Label(hidden ? "Mostrar en Fototeca" : "Ocultar", systemImage: hidden ? "eye" : "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(maxWidth: .infinity).frame(height: 54).contentShape(Rectangle())
            }
            .accessibilityLabel("Más")
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 10)
        .liquidCapsule()
        .padding(.horizontal, 22)
    }

    private func barButton(_ symbol: String, _ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(tint ?? Palette.ink)
                .frame(maxWidth: .infinity).frame(height: 54).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }

    private func detail(_ item: GalleryItem) -> String {
        let time = Timeline.format(item.date, "HH:mm")
        if item.isNAS {
            let place = item.folder.map { $0.isEmpty ? store.nasLabel : $0 } ?? store.nasLabel
            return "\(time) · NAS · \(place)"
        }
        return "\(time) · iPhone"
    }

    // MARK: Actions

    private func share(_ item: GalleryItem) async {
        guard let file = await prepare(item, message: item.isNAS ? "Descargando del NAS…" : "Preparando…") else { return }
        shareFile = ShareFile(url: file)
    }

    private func saveToPhone(_ item: GalleryItem) async {
        guard let file = await prepare(item, message: "Descargando del NAS…") else { return }
        do {
            try await ItemExport.saveToPhone(file, isVideo: item.isVideo)
            show("Guardada en el iPhone")
        } catch {
            store.error = "No se pudo guardar en el iPhone. Revisa el permiso de Fotos en Ajustes."
        }
    }

    private func copy(_ item: GalleryItem) async {
        guard let file = await prepare(item, message: "Preparando…") else { return }
        do { try ItemExport.copy(file); show("Copiada") } catch { store.error = error.localizedDescription }
    }

    private func showDay(_ item: GalleryItem) {
        store.dayRequest = DayRequest(date: item.date, nas: item.isNAS && !store.items.contains { $0.id == item.id })
        dismiss()
    }

    private func prepare(_ item: GalleryItem, message: String) async -> URL? {
        working = message
        defer { working = nil }
        do { return try await ItemExport.file(for: item, account: store.account) }
        catch { store.error = error.localizedDescription; return nil }
    }

    private func show(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
        }
    }
}

extension View {
    @ViewBuilder func liquidCircle() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(.regularMaterial, in: Circle()).overlay(Circle().stroke(Palette.stroke, lineWidth: 0.75))
        }
    }
}

// MARK: Filmstrip

/// The photos around the current one, small, to move quickly between them.
struct Filmstrip: View {
    let items: [GalleryItem]
    @Binding var current: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 3) {
                    ForEach(items) { item in
                        let selected = item.id == current
                        Button { withAnimation(.easeInOut(duration: 0.2)) { current = item.id } } label: {
                            Thumbnail(item: item, pixelSize: 60)
                                .frame(width: selected ? 44 : 30, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white, lineWidth: selected ? 2 : 0))
                                .padding(.horizontal, selected ? 4 : 0)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 200)
            }
            .frame(height: 50)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, value in withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(value, anchor: .center) } }
        }
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: Share

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet: WhatsApp, AirDrop, Mensajes…
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: Information

/// Ⓘ: when and where the photo was taken, with what, the file and its albums.
struct InfoSheet: View {
    @EnvironmentObject var store: GalleryStore
    let item: GalleryItem
    @State private var info: PhotoInfo?
    @State private var place: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Timeline.format(item.date, "EEEE d 'de' MMMM 'de' y")).font(.headline)
                        Text(Timeline.format(item.date, "HH:mm") + (item.duration.map { " · " + durationText($0) } ?? ""))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if let info {
                    if info.camera != nil || info.lens != nil || info.exposure != nil {
                        Section("Cámara") {
                            if let camera = info.camera { Label(camera, systemImage: "camera") }
                            if let lens = info.lens { Label(lens, systemImage: "camera.aperture") }
                            if let exposure = info.exposure { Label(exposure, systemImage: "dial.medium") }
                        }
                    }
                    Section("Archivo") {
                        if let name = info.fileName { LabeledContent("Nombre", value: name) }
                        if let format = info.format, !format.isEmpty { LabeledContent("Formato", value: format) }
                        if let resolution = info.resolution { LabeledContent("Resolución", value: resolution) }
                        if let bytes = info.bytes { LabeledContent("Tamaño", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                    }
                    if let location = info.location {
                        Section("Ubicación") {
                            Map(initialPosition: .region(MKCoordinateRegion(center: location, latitudinalMeters: 1500, longitudinalMeters: 1500))) {
                                Marker(place ?? "", coordinate: location)
                            }
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                            if let place { Label(place, systemImage: "mappin.and.ellipse") }
                        }
                    }
                } else {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                }
                Section("Dónde está") {
                    if item.isNAS {
                        Label(store.nasLabel + " · " + ((item.folder?.isEmpty ?? true) ? "carpeta principal" : item.folder!), systemImage: "server.rack")
                    } else {
                        Label("Este iPhone", systemImage: "iphone")
                    }
                    let albums = store.albums.filter { $0.items.contains(item.id) }
                    if !albums.isEmpty { Label(albums.map(\.name).joined(separator: ", "), systemImage: "rectangle.stack") }
                    if store.isFavorite(item) { Label("Favoritos", systemImage: "heart.fill") }
                }
            }
            .navigationTitle("Información")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task {
            let loaded = await PhotoInfo.load(item, account: store.account)
            info = loaded
            if let location = loaded.location { place = await PhotoInfo.placeName(location) }
        }
    }
}
