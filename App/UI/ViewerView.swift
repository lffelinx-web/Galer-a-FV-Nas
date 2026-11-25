import SwiftUI
import UIKit
import MapKit

/// Full-screen viewer. Sideways moves between photos; a vertical swipe never does: down
/// closes and up lifts the photo to show its information below, as in Photos. At the
/// bottom, the neighbours in a strip and the actions in three glass pieces.
struct ViewerView: View {
    let context: ViewerContext
    @EnvironmentObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    @State private var current: String?
    @State private var chrome = true
    @State private var zoomed = false
    @State private var dragY: CGFloat = 0
    /// 0: photo only; 1: the photo lifted and the information below it.
    @State private var info: CGFloat = 0
    @State private var infoOpen = false
    @State private var albumItem: GalleryItem?
    @State private var shareFile: ShareFile?
    @State private var working: String?
    @State private var toast: String?
    @State private var places: [String: String] = [:]
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
        GeometryReader { geo in
            let panel = geo.size.height * 0.52
            ZStack(alignment: .top) {
                Color.black.opacity((1 - min(dragY / 500, 0.7)) * progress).ignoresSafeArea()
                ViewerPager(items: context.items, current: $current, chrome: chrome && settled && info == 0, locked: zoomed || info > 0, zoomed: zoomed,
                            store: store, poster: poster(for:),
                            toggleChrome: { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } },
                            zoomChanged: { zoomed = $0 },
                            vertical: vertical)
                    .ignoresSafeArea()
                    // Lifted and a little smaller while the information is open.
                    .scaleEffect(1 - 0.38 * info - min(dragY / 2500, 0.15), anchor: .top)
                    .offset(y: dragY + info * geo.safeAreaInsets.top * 0.5)
                    .opacity(settled ? 1 : 0)
                    .simultaneousGesture(TapGesture().onEnded { if infoOpen { setInfo(false) } }, including: infoOpen ? .all : .none)
                if !settled { zoomLayer }
                if info > 0, let item = currentItem {
                    InfoPanel(item: item)
                        .frame(height: panel)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .offset(y: (1 - info) * panel)
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.identity)
                }
            }
        }
        .overlay(alignment: .top) {
            if chrome && settled { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if chrome && settled && info == 0 { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
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
        .sheet(item: $shareFile) { ActivitySheet(items: [$0.url]).ignoresSafeArea() }
        .onChange(of: current) { zoomed = false }
        .task(id: current) {
            guard let item = currentItem, places[item.id] == nil, let place = await PhotoInfo.quickPlace(item) else { return }
            places[item.id] = place
        }
    }

    /// The picture the page shows at once: the uncropped one from the tap for the first
    /// photo, otherwise the NAS thumbnail already in memory.
    private func poster(for item: GalleryItem) -> UIImage? {
        if item.id == context.start, context.sourceIsWhole, let image = context.sourceImage { return image }
        return item.nasURL.flatMap { NASImageLoader.shared.cached($0) }
    }

    // MARK: Vertical swipes

    /// Down closes (or hides the information); up shows the information.
    private func vertical(_ drag: VerticalDrag) {
        switch drag {
        case .changed(let dy):
            if infoOpen {
                info = max(0, min(1, 1 - dy / 320))
            } else if dy > 0 {
                dragY = dy
            } else {
                info = max(0, min(1, -dy / 320))
            }
        case .ended(let dy, let velocity):
            if infoOpen {
                setInfo(!(dy > 90 || velocity > 600))
            } else if dy > 0 {
                if dy > 130 || (velocity > 800 && dy > 40) { close() }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 } }
            } else {
                setInfo(-dy > 80 || velocity < -600)
            }
        }
    }

    private func setInfo(_ open: Bool) {
        infoOpen = open
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { info = open ? 1 : 0 }
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
        guard hasSource, current == context.start, !zoomed, info == 0 else { dismiss(); return }
        settled = false
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { progress = 0; dragY = 0 } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
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
                    // The place when the photo has one, and the time; the folder is in the information.
                    Text([places[item.id], Timeline.format(item.date, "HH:mm")].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 16).frame(height: 46)
                .liquidCapsule()
            }
            Spacer(minLength: 0)
            if store.nasState == .slow, currentItem?.isNAS == true {
                Label("Cargando del NAS…", systemImage: "tortoise.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.warning)
                    .frame(width: 46, height: 46)
                    .liquidCircle()
                    .accessibilityLabel("El NAS responde lento")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Videos show their time bar here instead.
            if currentItem?.isVideo != true { Filmstrip(items: context.items, current: $current) }
            if let item = currentItem { actions(item) }
        }
        .padding(.bottom, 4)
    }

    /// Compartir on the left, Favorito and Información together in the middle, Más on the
    /// right: three glass pieces, like the scale bar of Fototeca.
    private func actions(_ item: GalleryItem) -> some View {
        let favorite = store.isFavorite(item)
        let hidden = store.isHidden(item)
        let size = ViewerMetrics.barHeight
        return GlassGroup(spacing: 14) {
            HStack(spacing: 0) {
                Button { Task { await share(item) } } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                        .offset(y: -1)
                        .frame(width: size, height: size).contentShape(Circle())
                        .liquidCircle()
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Compartir")
                Spacer(minLength: 10)
                HStack(spacing: 4) {
                    Button { store.toggleFavorite(item) } label: {
                        Image(systemName: favorite ? "heart.fill" : "heart")
                            .foregroundStyle(favorite ? Color.red : Palette.ink)
                            .symbolEffect(.bounce, value: favorite)
                            .frame(width: 64, height: size - 8)
                            .background { if favorite { Capsule().fill(Color.red.opacity(0.12)) } }
                            .contentShape(Capsule())
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: favorite)
                    .accessibilityLabel(favorite ? "Quitar de favoritos" : "Agregar a favoritos")
                    Button { setInfo(true) } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Palette.ink)
                            .frame(width: 64, height: size - 8)
                            .contentShape(Capsule())
                    }
                    .accessibilityLabel("Información")
                }
                .font(.system(size: 18, weight: .semibold))
                .buttonStyle(PressStyle())
                .padding(4)
                .liquidCapsule()
                Spacer(minLength: 10)
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
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink)
                        .frame(width: size, height: size).contentShape(Circle())
                        .liquidCircle()
                }
                .accessibilityLabel("Más")
            }
        }
        .padding(.horizontal, 22)
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

// MARK: Pager

enum VerticalDrag {
    case changed(CGFloat)
    /// Distance and speed (points per second; positive is down).
    case ended(CGFloat, CGFloat)
}

/// The pages, in a native paging collection view. A vertical swipe is recognised on the
/// first movement: when it is more vertical than horizontal the pages do not move sideways
/// at all, so swiping up for the information never turns the page.
struct ViewerPager: UIViewRepresentable {
    let items: [GalleryItem]
    @Binding var current: String?
    var chrome: Bool
    /// No sideways paging (zoomed in, or the information is open).
    var locked: Bool
    /// Zoomed in: dragging moves the photo, so vertical swipes are off too.
    var zoomed: Bool
    var store: GalleryStore
    var poster: (GalleryItem) -> UIImage?
    var toggleChrome: () -> Void
    var zoomChanged: (Bool) -> Void
    var vertical: (VerticalDrag) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PagerContainer {
        let container = PagerContainer()
        let view = container.collectionView
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        // Sideways paging waits only until the vertical swipe declines, on the first movement.
        view.panGestureRecognizer.require(toFail: pan)
        context.coordinator.verticalPan = pan
        container.onLayout = { [weak coordinator = context.coordinator] in coordinator?.scrollToCurrent(animated: false) }
        return container
    }

    func updateUIView(_ container: PagerContainer, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        let view = container.collectionView
        view.isScrollEnabled = !locked
        coordinator.verticalPan?.isEnabled = !zoomed
        if current != coordinator.shownID { coordinator.scrollToCurrent(animated: true) }
        if previous.chrome != chrome || previous.current != current {
            view.reconfigureItems(at: view.indexPathsForVisibleItems)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
        var parent: ViewerPager
        weak var verticalPan: UIPanGestureRecognizer?
        var shownID: String?
        private lazy var positions: [String: Int] = Dictionary(parent.items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })

        init(_ parent: ViewerPager) {
            self.parent = parent
            self.shownID = parent.current
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { parent.items.count }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath)
            let parent = self.parent
            let item = parent.items[indexPath.item]
            let currentIndex = parent.current.flatMap { positions[$0] } ?? 0
            cell.backgroundConfiguration = .clear()
            // The page gets the exact screen size, so it is laid out once and never shifts.
            let size = collectionView.bounds.size
            cell.contentConfiguration = UIHostingConfiguration {
                ViewerPage(item: item, active: item.id == parent.current, chrome: parent.chrome, upcoming: indexPath.item == currentIndex + 1,
                           poster: parent.poster(item), toggleChrome: parent.toggleChrome, zoomChanged: parent.zoomChanged)
                    .frame(width: size.width, height: size.height)
                    .environmentObject(parent.store)
            }
            .margins(.all, 0)
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            collectionView.bounds.size
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle(scrollView) }

        private func settle(_ scrollView: UIScrollView) {
            guard scrollView.bounds.width > 0 else { return }
            let index = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
            guard parent.items.indices.contains(index) else { return }
            let id = parent.items[index].id
            shownID = id
            if parent.current != id { parent.current = id }
        }

        func scrollToCurrent(animated: Bool) {
            guard let view = verticalPan?.view as? UICollectionView, view.bounds.width > 0,
                  let id = parent.current, let index = positions[id] else { return }
            shownID = id
            view.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: animated)
        }

        // MARK: Vertical swipe

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x) * 1.1
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view).y
            switch gesture.state {
            case .began, .changed: parent.vertical(.changed(translation))
            case .ended, .cancelled, .failed: parent.vertical(.ended(translation, gesture.velocity(in: gesture.view).y))
            default: break
            }
        }
    }
}

/// Holds the pager and keeps each page as big as the screen when the size changes.
final class PagerContainer: UIView {
    let collectionView: UICollectionView
    var onLayout: (() -> Void)?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collectionView.backgroundColor = .clear
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "page")
        // Hidden until it sits on the tapped photo at its final size.
        collectionView.alpha = 0
        addSubview(collectionView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = bounds
        guard bounds.size != lastSize, bounds.width > 0 else { return }
        lastSize = bounds.size
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        onLayout?()
        collectionView.layoutIfNeeded()
        collectionView.alpha = 1
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
                            Thumbnail(item: item, pixelSize: 50, badges: false)
                                .frame(width: selected ? 34 : 24, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .opacity(selected ? 1 : 0.85)
                                .padding(.horizontal, selected ? 5 : 0)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 200)
            }
            .frame(height: 40)
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

/// Below the lifted photo: what it is, when it was taken (and how sure that date is),
/// with what, the file, the place, where it is kept and its albums. Files without camera
/// data still show everything that can be read from them.
struct InfoPanel: View {
    @EnvironmentObject var store: GalleryStore
    let item: GalleryItem
    @State private var info: PhotoInfo?
    @State private var place: String?
    @State private var showFolder = false

    private var kind: (String, String) {
        if item.isScreenshot { return ("Captura de pantalla", "camera.viewfinder") }
        if item.kind == .livePhoto { return ("Live Photo", "livephoto") }
        if item.isVideo { return ("Video", "video") }
        if item.isRAW { return ("Foto RAW", "camera.aperture") }
        return ("Foto", "photo")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(Palette.secondary.opacity(0.35)).frame(width: 38, height: 5).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Timeline.format(item.date, "EEEE d 'de' MMMM 'de' y")).font(.title3.bold()).foregroundStyle(Palette.ink)
                    Text(Timeline.format(item.date, "HH:mm") + (item.duration.map { " · " + durationText($0) } ?? ""))
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                }
                group {
                    row(kind.0, kind.1)
                    row(store.dateSource(item), "calendar.badge.clock", secondary: true)
                }
                if let info {
                    if info.camera != nil || info.lens != nil || info.exposure != nil {
                        group {
                            if let camera = info.camera { row(camera, "camera") }
                            if let lens = info.lens { row(lens, "camera.aperture") }
                            if let exposure = info.exposure { row(exposure, "dial.medium") }
                        }
                    }
                    group {
                        if let name = info.fileName { row(name, "doc") }
                        if let resolution = info.resolution { row(resolution, "aspectratio") }
                        let details = [info.format.flatMap { $0.isEmpty ? nil : $0 },
                                       info.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }
                        if !details.isEmpty { row(details.joined(separator: " · "), "internaldrive") }
                        if let video = info.video { row(video, "film") }
                    }
                    if let location = info.location {
                        VStack(alignment: .leading, spacing: 8) {
                            Map(initialPosition: .region(MKCoordinateRegion(center: location, latitudinalMeters: 1500, longitudinalMeters: 1500))) {
                                Marker(place ?? "", coordinate: location)
                            }
                            .frame(height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            if let place { row(place, "mappin.and.ellipse") }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                group {
                    if item.isNAS {
                        row(store.nasLabel + " · " + ((item.folder?.isEmpty ?? true) ? "carpeta principal" : item.folder!), "server.rack")
                        Button { showFolder = true } label: {
                            Label("Ver carpeta", systemImage: "folder")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                        }
                        if store.duplicateIDs.contains(item.id) { row("También está en este iPhone", "iphone", secondary: true) }
                    } else {
                        row("Este iPhone", "iphone")
                    }
                    let albums = store.albums.filter { $0.items.contains(item.id) }
                    if !albums.isEmpty { row(albums.map(\.name).joined(separator: ", "), "rectangle.stack") }
                    if store.isFavorite(item) { row("Favoritos", "heart.fill") }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
        .sheet(isPresented: $showFolder) { FolderSheet(folder: item.folder ?? "").environmentObject(store) }
        .task(id: item.id) {
            info = nil
            place = nil
            let loaded = await PhotoInfo.load(item, account: store.account)
            info = loaded
            if let location = loaded.location {
                place = await PhotoInfo.placeName(location)
                if let place { PlaceCache.byItem[item.id] = place }
            }
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ text: String, _ symbol: String, secondary: Bool = false) -> some View {
        Label {
            Text(text).foregroundStyle(secondary ? Palette.secondary : Palette.ink).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.accent)
        }
        .font(secondary ? .footnote : .subheadline)
    }
}

/// «Ver carpeta»: everything in the same NAS folder.
struct FolderSheet: View {
    @EnvironmentObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    let folder: String

    var body: some View {
        let items = store.nasShown.filter { ($0.folder ?? "") == folder }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(mediaSummary(items)).font(.footnote).foregroundStyle(Palette.secondary)
                    SquareGrid(items: items)
                }
                .padding(.horizontal, 16)
            }
            .background(AppBackground())
            .navigationTitle(folder.split(separator: "/").last.map(String.init) ?? "Carpeta principal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
    }
}
