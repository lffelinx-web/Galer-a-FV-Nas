import SwiftUI
import UIKit

private struct WallKey: Equatable {
    let revision: Int
    let width: CGFloat
}

/// A request to show a day, from Ir a fecha.
struct DateJump: Equatable {
    let id = UUID()
    let date: Date
}

/// Scroll position shared with the header, so only the header redraws while scrolling.
final class WallScroll: ObservableObject {
    @Published var distance: CGFloat = 0
}

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The photo wall shared by Fototeca and NAS: a mosaic by day, a collage per month or per
/// year. All three are measured in advance off the main thread, so changing the scale is
/// immediate, and drawn by a collection view that reuses its cells.
struct PhotoWall<Header: View, Empty: View>: View {
    @EnvironmentObject var store: GalleryStore
    var items: [GalleryItem]
    var revision: Int
    @Binding var scale: TimeScale
    var topRequest: Int
    var jump: DateJump?
    /// Distance from the top, and whether the finger moved it.
    var onScroll: (CGFloat, Bool) -> Void
    var refresh: () async -> Void
    @ViewBuilder var header: () -> Header
    @ViewBuilder var empty: () -> Empty

    @State private var layouts: [TimeScale: WallLayout] = [:]
    @State private var shown = WallLayout()
    @State private var layoutID = 0
    @State private var animateChange = false
    @State private var headerHeight: CGFloat = 0
    @State private var focus: Date?
    @State private var waitingFor: TimeScale?
    // Held without observing: only the header follows the scroll.
    @State private var scroll = WallScroll()
    @State private var tracker = WallTracker()
    @State private var control = WallControl()

    var body: some View {
        GeometryReader { geo in
            if items.isEmpty {
                ScrollView {
                    VStack(spacing: 0) { header(); empty() }
                }
                .scrollIndicators(.hidden)
                .refreshable { await refresh() }
            } else {
                ZStack(alignment: .top) {
                    CollectionWall(layout: shown, layoutID: layoutID, animated: animateChange, topInset: headerHeight, topRequest: topRequest,
                                   tracker: tracker, control: control,
                                   onScroll: { distance, user in
                                       scroll.distance = distance
                                       onScroll(distance, user)
                                   },
                                   onSelect: select,
                                   refresh: refresh)
                        .ignoresSafeArea()
                    WallHeader(scroll: scroll) { header() }
                        .background(GeometryReader { proxy in Color.clear.preference(key: HeaderHeightKey.self, value: proxy.size.height) })
                    DateScrubber(scroll: scroll, control: control, label: { distance in
                        shown.date(at: distance + 20).map { Timeline.format($0, "LLLL y") }
                    })
                    .padding(.top, headerHeight)
                    if shown.elements.isEmpty {
                        ProgressView().padding(.top, headerHeight + 80)
                    }
                }
                .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
                .task(id: WallKey(revision: revision, width: geo.size.width)) {
                    await buildAll(width: geo.size.width)
                }
                .onChange(of: scale) { _, next in show(next, animated: true) }
                .onChange(of: jump) { _, request in
                    guard let request else { return }
                    focus = request.date
                    if scale == .days { show(.days, animated: true) } else { scale = .days }
                }
            }
        }
    }

    /// Builds the scale on screen first, then the other two, so switching never waits.
    private func buildAll(width: CGFloat) async {
        guard width > 0 else { return }
        let items = self.items
        let first = scale
        let current = await Task.detached(priority: .userInitiated) { WallLayout.build(items, scale: first, width: width) }.value
        guard !Task.isCancelled else { return }
        layouts = [first: current]
        if scale == first { display(current, animated: false) }
        for other in TimeScale.allCases where other != first {
            let layout = await Task.detached(priority: .utility) { WallLayout.build(items, scale: other, width: width) }.value
            guard !Task.isCancelled else { return }
            layouts[other] = layout
            if waitingFor == other, scale == other { waitingFor = nil; show(other, animated: true) }
        }
    }

    /// Switches to a scale, opening at the dates on screen or at the one tapped.
    private func show(_ next: TimeScale, animated: Bool) {
        guard var layout = layouts[next] else { waitingFor = next; return }
        let target = focus ?? (tracker.distance > 30 ? tracker.topDate : nil)
        focus = nil
        layout.initialY = target.flatMap { layout.top(for: $0) } ?? (tracker.distance > 30 ? nil : 0)
        display(layout, animated: animated)
    }

    private func display(_ layout: WallLayout, animated: Bool) {
        animateChange = animated
        shown = layout
        layoutID += 1
    }

    private func select(_ element: WallElement, from frame: CGRect?, image: UIImage?) {
        switch element.kind {
        case .tile(let item, _):
            store.open(item, in: items, from: frame, image: image)
        case .header:
            break
        case .card(let section):
            // A year opens its months; a month opens its days.
            focus = section.date
            scale = shown.scale == .years ? .months : .days
        }
    }
}

/// The header scrolls with the photos: it is drawn over the collection view and moved by
/// the scroll distance.
private struct WallHeader<Content: View>: View {
    @ObservedObject var scroll: WallScroll
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .offset(y: -scroll.distance)
            .opacity(scroll.distance > 200 ? 0 : 1)
    }
}

/// Lets SwiftUI move the collection view directly, for the date scrubber.
final class WallControl {
    weak var collectionView: UICollectionView?

    var maxDistance: CGFloat {
        guard let view = collectionView else { return 0 }
        return max(0, view.contentSize.height + view.adjustedContentInset.top + view.adjustedContentInset.bottom - view.bounds.height)
    }

    func scroll(toFraction fraction: CGFloat) {
        guard let view = collectionView else { return }
        let distance = maxDistance * min(max(fraction, 0), 1)
        view.setContentOffset(CGPoint(x: 0, y: distance - view.adjustedContentInset.top), animated: false)
    }
}

/// The handle on the right edge: drag it to travel through the years, with the month on screen.
struct DateScrubber: View {
    @ObservedObject var scroll: WallScroll
    let control: WallControl
    var label: (CGFloat) -> String?
    @State private var visible = false
    @State private var dragging = false
    @State private var text: String?
    @State private var hide: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let track = max(geo.size.height - 150, 1)
            let maxDistance = control.maxDistance
            let fraction = maxDistance > 0 ? min(max(scroll.distance / maxDistance, 0), 1) : 0
            ZStack(alignment: .topTrailing) {
                if visible || dragging {
                    HStack(spacing: 8) {
                        if dragging, let text {
                            Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                                .padding(.horizontal, 14).frame(height: 36)
                                .liquidCapsule()
                                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.accent)
                            .frame(width: 34, height: 48)
                            .liquidCapsule(interactive: true)
                            .contentShape(Capsule())
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .named("scrubber"))
                                    .onChanged { value in
                                        if !dragging { withAnimation(.easeOut(duration: 0.15)) { dragging = true } }
                                        let next = min(max((value.location.y - 24) / track, 0), 1)
                                        control.scroll(toFraction: next)
                                        let newText = label(next * maxDistance)
                                        if newText != text { text = newText }
                                    }
                                    .onEnded { _ in
                                        withAnimation(.easeOut(duration: 0.2)) { dragging = false }
                                        scheduleHide()
                                    }
                            )
                            .accessibilityLabel("Barra de fechas")
                            .accessibilityValue(text ?? "")
                    }
                    .sensoryFeedback(.selection, trigger: text)
                    .offset(y: fraction * track)
                    .padding(.trailing, 4)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .coordinateSpace(name: "scrubber")
        }
        // Long walls only, and only while moving through them.
        .onChange(of: scroll.distance) { _, distance in
            guard !dragging, control.maxDistance > 3_000 else { return }
            if distance > 200 { if !visible { withAnimation(.easeOut(duration: 0.2)) { visible = true } }; scheduleHide() }
            else if visible { withAnimation { visible = false } }
        }
    }

    private func scheduleHide() {
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, !dragging else { return }
            withAnimation(.easeOut(duration: 0.3)) { visible = false }
        }
    }
}

/// What the collection view knows about the scroll, read without redrawing SwiftUI.
final class WallTracker {
    var distance: CGFloat = 0
    var topDate: Date?
}

// MARK: Collection view

/// Holds the collection view, so a change of scale can cross-fade over a snapshot.
final class WallContainerView: UIView {
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: WallCollectionLayout())

    override init(frame: CGRect) {
        super.init(frame: frame)
        collectionView.frame = bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(collectionView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

struct CollectionWall: UIViewRepresentable {
    var layout: WallLayout
    var layoutID: Int
    var animated: Bool
    var topInset: CGFloat
    var topRequest: Int
    var tracker: WallTracker
    var control: WallControl
    var onScroll: (CGFloat, Bool) -> Void
    var onSelect: (WallElement, CGRect?, UIImage?) -> Void
    var refresh: () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WallContainerView {
        let container = WallContainerView()
        let view = container.collectionView
        view.backgroundColor = .clear
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.contentInsetAdjustmentBehavior = .always
        view.contentInset.bottom = 104
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        let refresher = UIRefreshControl()
        refresher.addTarget(context.coordinator, action: #selector(Coordinator.refreshPulled(_:)), for: .valueChanged)
        view.refreshControl = refresher
        context.coordinator.lastTopRequest = topRequest
        control.collectionView = view
        return container
    }

    func updateUIView(_ container: WallContainerView, context: Context) {
        let coordinator = context.coordinator
        let view = container.collectionView
        coordinator.parent = self
        if view.contentInset.top != topInset {
            let atTop = view.contentOffset.y <= -view.adjustedContentInset.top + 1
            view.contentInset.top = topInset
            if atTop { view.contentOffset.y = -view.adjustedContentInset.top }
        }
        if coordinator.layoutID != layoutID, let collectionLayout = view.collectionViewLayout as? WallCollectionLayout {
            coordinator.layoutID = layoutID
            // A new scale fades in over a picture of the old one, with a slight zoom.
            var snapshot: UIView?
            if animated, !collectionLayout.wall.elements.isEmpty, let picture = view.snapshotView(afterScreenUpdates: false) {
                picture.frame = view.frame
                container.addSubview(picture)
                snapshot = picture
            }
            collectionLayout.wall = layout
            coordinator.moving = true
            view.reloadData()
            collectionLayout.invalidateLayout()
            view.layoutIfNeeded()
            if let y = layout.initialY {
                let maxOffset = max(layout.height + view.adjustedContentInset.bottom - view.bounds.height, -view.adjustedContentInset.top)
                view.setContentOffset(CGPoint(x: 0, y: min(y - view.adjustedContentInset.top, maxOffset)), animated: false)
            }
            coordinator.moving = false
            if let snapshot {
                view.alpha = 0
                view.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
                UIView.animate(withDuration: 0.34, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    snapshot.alpha = 0
                    snapshot.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
                    view.alpha = 1
                    view.transform = .identity
                } completion: { _ in snapshot.removeFromSuperview() }
            }
        }
        if coordinator.lastTopRequest != topRequest {
            coordinator.lastTopRequest = topRequest
            view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: true)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: CollectionWall
        var layoutID = -1
        var lastTopRequest = 0
        /// True while the wall itself moves the content, so it is not taken for a gesture.
        var moving = false

        init(_ parent: CollectionWall) { self.parent = parent }

        private func wall(_ collectionView: UICollectionView) -> WallLayout {
            (collectionView.collectionViewLayout as? WallCollectionLayout)?.wall ?? WallLayout()
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            wall(collectionView).elements.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
            let wall = wall(collectionView)
            guard indexPath.item < wall.elements.count else { return cell }
            let element = wall.elements[indexPath.item]
            switch element.kind {
            case .tile(let item, let corner):
                let side = max(element.frame.width, element.frame.height)
                cell.contentConfiguration = UIHostingConfiguration {
                    Thumbnail(item: item, pixelSize: side)
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                }
                .margins(.all, 0)
            case .header(let section):
                let scale = wall.scale
                cell.contentConfiguration = UIHostingConfiguration { SectionHeader(section: section, scale: scale) }.margins(.all, 0)
            case .card(let section):
                let scale = wall.scale
                cell.contentConfiguration = UIHostingConfiguration { PeriodCard(section: section, scale: scale) }.margins(.all, 0)
            }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
            guard let element = element(collectionView, indexPath) else { return false }
            if case .header = element.kind { return false }
            return true
        }

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            self.collectionView(collectionView, shouldHighlightItemAt: indexPath)
        }

        func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
            guard let cell = collectionView.cellForItem(at: indexPath) else { return }
            UIView.animate(withDuration: 0.15) { cell.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
        }

        func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
            guard let cell = collectionView.cellForItem(at: indexPath) else { return }
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [.allowUserInteraction]) { cell.transform = .identity }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            guard let element = element(collectionView, indexPath) else { return }
            // Where the tile is and what it shows, for the zoom into the viewer.
            var frame: CGRect?, image: UIImage?
            if let cell = collectionView.cellForItem(at: indexPath) {
                let bounds = cell.bounds
                frame = cell.convert(bounds, to: nil)
                image = UIGraphicsImageRenderer(bounds: bounds).image { _ in cell.drawHierarchy(in: bounds, afterScreenUpdates: false) }
            }
            parent.onSelect(element, frame, image)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Clamped, so the bounce at the bottom does not count as scrolling up.
            let maxDistance = max(0, scrollView.contentSize.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
            let distance = min(scrollView.contentOffset.y + scrollView.adjustedContentInset.top, maxDistance)
            parent.tracker.distance = distance
            if let collectionView = scrollView as? UICollectionView { parent.tracker.topDate = wall(collectionView).date(at: distance + 20) }
            let user = !moving && (scrollView.isDragging || scrollView.isDecelerating)
            parent.onScroll(distance, user)
        }

        @objc func refreshPulled(_ control: UIRefreshControl) {
            Task { @MainActor in
                await parent.refresh()
                control.endRefreshing()
            }
        }

        private func element(_ collectionView: UICollectionView, _ indexPath: IndexPath) -> WallElement? {
            let elements = wall(collectionView).elements
            return indexPath.item < elements.count ? elements[indexPath.item] : nil
        }
    }
}

/// Places every cell at the frame measured in advance.
final class WallCollectionLayout: UICollectionViewLayout {
    var wall = WallLayout()

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: wall.height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        wall.indices(in: rect).map(attributes)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < wall.elements.count ? attributes(indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    private func attributes(_ index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = wall.elements[index].frame
        return attributes
    }
}

// MARK: Fototeca

/// Fototeca: the photos of the iPhone and the NAS together.
struct LibraryView: View {
    @EnvironmentObject var store: GalleryStore
    @Binding var scale: TimeScale
    @Binding var compact: Bool
    var topRequest: Int
    var jump: DateJump?
    var openSettings: () -> Void
    var openNAS: () -> Void
    @State private var direction = BarDirection()
    @State private var showInfo = false

    var body: some View {
        PhotoWall(items: store.items, revision: store.revision, scale: $scale, topRequest: topRequest, jump: jump,
                  onScroll: { direction.apply($0, user: $1, to: $compact) }, refresh: { await store.refresh() }) {
            header
        } empty: {
            empty
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Brand()
                Spacer(minLength: 8)
                // A tap gesture that wins over the photos behind, so the first touch always opens it.
                StatusPill(short: true)
                    .contentShape(Capsule())
                    .highPriorityGesture(TapGesture().onEnded { showInfo = true })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { showInfo = true }
                    .accessibilityHint("Muestra el estado del NAS")
                    .popover(isPresented: $showInfo) {
                        NASInfoCard(openNAS: { showInfo = false; openNAS() },
                                    openSettings: { showInfo = false; openSettings() })
                            .presentationCompactAdaptation(.popover)
                    }
            }
            ScanBanner()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var empty: some View {
        if !store.loaded || store.scanning {
            VStack(spacing: 14) {
                ProgressView()
                Text(store.scanStatus ?? "Cargando fotos…").font(.subheadline).foregroundStyle(Palette.secondary)
            }
            .padding(.top, 120)
        } else if store.photoAccess == .notDetermined {
            EmptyState(symbol: "photo.on.rectangle.angled", title: "Tus fotos en un solo lugar",
                       message: "Permite el acceso a las fotos de este iPhone para verlas junto con las de tu NAS.",
                       action: ("Permitir acceso", { Task { await store.requestPhotoAccess() } }))
                .padding(.top, 60)
        } else if store.account == nil {
            EmptyState(symbol: "server.rack", title: "Conecta tu NAS",
                       message: store.photoAccess.canRead ? "No hay fotos en este iPhone todavía. Agrega la carpeta de fotos de tu NAS en Configuración."
                                                          : "Sin acceso a las fotos del iPhone. Agrega la carpeta de fotos de tu NAS en Configuración o permite el acceso en Ajustes.",
                       action: ("Configurar NAS", openSettings))
                .padding(.top, 60)
        } else {
            EmptyState(symbol: "photo", title: "Sin fotos", message: "No se encontraron fotos ni videos. Busca de nuevo desde la pestaña NAS.")
                .padding(.top, 60)
        }
    }
}

/// The card behind the NAS pill: state, route, space and the useful actions.
struct NASInfoCard: View {
    @EnvironmentObject var store: GalleryStore
    var openNAS: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                NASBadge(size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.account == nil ? "Sin NAS" : store.nasLabel).font(.headline).foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        Circle().fill(store.nasState.color).frame(width: 8, height: 8)
                        Text(store.nasState.shortLabel).font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                }
            }
            if store.account != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let route = store.routeLabel { info("Conexión", route) }
                    if let space = store.spaceText { info("Espacio", space) }
                    if let date = store.lastScan { info("Última búsqueda", date.formatted(.relative(presentation: .named))) }
                    if let status = store.datesStatus { info("Fechas", status.replacingOccurrences(of: "Ordenando por fecha · ", with: "")) }
                    if store.duplicatesHidden > 0 { info("Duplicados", "\(store.duplicatesHidden.formatted()) ocultos en Fototeca") }
                }
                VStack(spacing: 8) {
                    action(store.scanning ? "Buscando…" : "Buscar fotos nuevas", "arrow.triangle.2.circlepath", primary: true) { store.scan() }
                        .disabled(store.scanning)
                    HStack(spacing: 8) {
                        // Resume the capture dates when they stopped; otherwise, the NAS settings.
                        if store.datesPaused {
                            action("Reanudar fechas", "calendar.badge.clock", primary: false) { store.readCaptureDates() }
                        } else {
                            action("Configuración", "gearshape", primary: false, run: openSettings)
                        }
                        action("Ir al NAS", "server.rack", primary: false, run: openNAS)
                    }
                }
            } else {
                Text("Conecta tu Synology en Configuración para ver sus fotos aquí.").font(.subheadline).foregroundStyle(Palette.secondary)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline).foregroundStyle(Palette.secondary)
            Spacer(minLength: 10)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
        }
    }

    private func action(_ title: String, _ symbol: String, primary: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(primary ? Color.white : Palette.accent)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background {
                    if primary { Capsule().fill(Palette.selection) } else { Capsule().fill(Palette.accent.opacity(0.1)) }
                }
        }
        .buttonStyle(PressStyle())
    }
}

/// Which bar to show, from the direction of the scroll: scrolling down into the photos
/// shows Días · Meses · Años; scrolling up brings back the main bar, wherever you are.
final class BarDirection {
    private var last: CGFloat = 0
    private var anchor: CGFloat = 0
    private var goingDown = true

    /// True for the scale bar, false for the main bar, nil to leave it as it is.
    func update(_ distance: CGFloat, user: Bool = true) -> Bool? {
        defer { last = distance }
        let delta = distance - last
        // A jump (a new scale, Ir a fecha or Inicio) is not a gesture.
        if !user || abs(delta) > 400 { anchor = distance; return nil }
        if distance < 40 { anchor = distance; return false }
        if delta != 0, (delta > 0) != goingDown { goingDown = delta > 0; anchor = last }
        if goingDown && distance - anchor > 24 { return true }
        if !goingDown && anchor - distance > 24 { return false }
        return nil
    }

    func apply(_ distance: CGFloat, user: Bool, to compact: Binding<Bool>) {
        guard let next = update(distance, user: user), next != compact.wrappedValue else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { compact.wrappedValue = next }
    }
}

/// «Buscando fotos en el NAS…» or «Ordenando por fecha…» while it works.
struct ScanBanner: View {
    @EnvironmentObject var store: GalleryStore
    var body: some View {
        if let status = store.scanStatus ?? store.datesStatus {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .liquidCapsule()
        }
    }
}

/// «Hoy · 12 fotos» over a day.
struct SectionHeader: View {
    var section: TimelineSection
    var scale: TimeScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Text(mediaSummary(section.items)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A month in Meses or a year in Años: its title and a summary over a collage of one large
/// photo and four small ones picked across the period.
struct PeriodCard: View {
    var section: TimelineSection
    var scale: TimeScale

    private var picks: [GalleryItem] { PeriodCard.highlights(section.items, count: 5) }

    private var summary: String {
        let days = Set(section.items.map { Calendar.current.ordinality(of: .day, in: .era, for: $0.date) ?? 0 }).count
        let unit = scale == .years ? countText(Set(section.items.map { Calendar.current.component(.month, from: $0.date) }).count, "mes", "meses")
                                   : countText(days, "día", "días")
        return mediaSummary(section.items) + " · " + unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.system(size: scale == .years ? 30 : 22, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondary)
            }
            Text(summary).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1).padding(.top, -6)
            collage
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white, lineWidth: 1))
        .shadow(color: Palette.accent.opacity(0.07), radius: 10, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.title), \(summary)")
        .accessibilityAddTraits(.isButton)
    }

    private var collage: some View {
        GeometryReader { geo in
            let gap: CGFloat = 4
            let picks = self.picks
            let bigWidth = picks.count > 1 ? (geo.size.width * 0.58).rounded() : geo.size.width
            let smallWidth = ((geo.size.width - bigWidth - gap * 2) / 2).rounded(.down)
            let smallHeight = ((geo.size.height - gap) / 2).rounded(.down)
            HStack(spacing: gap) {
                if let first = picks.first { tile(first, CGSize(width: bigWidth, height: geo.size.height)) }
                if picks.count > 1 {
                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            ForEach(Array(picks.dropFirst().prefix(2))) { tile($0, CGSize(width: smallWidth, height: smallHeight)) }
                        }
                        HStack(spacing: gap) {
                            ForEach(Array(picks.dropFirst(3).prefix(2))) { tile($0, CGSize(width: smallWidth, height: smallHeight)) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func tile(_ item: GalleryItem, _ size: CGSize) -> some View {
        Thumbnail(item: item, pixelSize: max(size.width, size.height))
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Favorites first, then photos spread evenly across the period.
    static func highlights(_ items: [GalleryItem], count: Int) -> [GalleryItem] {
        let photos = items.filter { !$0.isVideo }
        let pool = photos.isEmpty ? items : photos
        guard pool.count > count else { return pool }
        var picks = Array(pool.filter(\.favorite).prefix(1))
        let step = Double(pool.count) / Double(count)
        var index = 0
        while picks.count < count && index < count * 2 {
            let candidate = pool[min(pool.count - 1, Int(Double(index) * step + step / 2))]
            if !picks.contains(where: { $0.id == candidate.id }) { picks.append(candidate) }
            index += 1
        }
        return picks
    }
}
