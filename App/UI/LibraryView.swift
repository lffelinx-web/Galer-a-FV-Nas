import SwiftUI
import UIKit

private struct WallKey: Equatable {
    let revision: Int
    let scale: TimeScale
    let width: CGFloat
}

/// Scroll position shared with the header, so only the header redraws while scrolling.
final class WallScroll: ObservableObject {
    @Published var distance: CGFloat = 0
}

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The photo wall shared by Fototeca and NAS: a mosaic by day, a grid by month or a card
/// per year. The layout is measured off the main thread and drawn by a collection view
/// that reuses its cells, so it stays smooth with tens of thousands of photos.
struct PhotoWall<Header: View, Empty: View>: View {
    @EnvironmentObject var store: GalleryStore
    var items: [GalleryItem]
    var revision: Int
    @Binding var scale: TimeScale
    var topRequest: Int
    var onScroll: (CGFloat) -> Void
    var refresh: () async -> Void
    @ViewBuilder var header: () -> Header
    @ViewBuilder var empty: () -> Empty

    @State private var layout = WallLayout()
    @State private var layoutID = 0
    @State private var building = true
    @State private var headerHeight: CGFloat = 0
    @State private var focus: Date?
    // Held without observing: only the header follows the scroll.
    @State private var scroll = WallScroll()
    @State private var tracker = WallTracker()

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
                    CollectionWall(layout: layout, layoutID: layoutID, topInset: headerHeight, topRequest: topRequest,
                                   tracker: tracker,
                                   onScroll: { distance in
                                       scroll.distance = distance
                                       onScroll(distance)
                                   },
                                   onSelect: select,
                                   refresh: refresh)
                        .ignoresSafeArea()
                    WallHeader(scroll: scroll) { header() }
                        .background(GeometryReader { proxy in Color.clear.preference(key: HeaderHeightKey.self, value: proxy.size.height) })
                    if building && layout.elements.isEmpty {
                        ProgressView().padding(.top, headerHeight + 80)
                    }
                }
                .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
                .task(id: WallKey(revision: revision, scale: scale, width: geo.size.width)) {
                    await build(width: geo.size.width)
                }
            }
        }
    }

    private func build(width: CGFloat) async {
        guard width > 0 else { return }
        building = true
        // Keep the place: a new scale opens at the dates on screen, or at the one tapped.
        let scaleChanged = scale != layout.scale && !layout.elements.isEmpty
        let focus = self.focus ?? (scaleChanged && tracker.distance > 30 ? tracker.topDate : nil)
        let (items, scale) = (self.items, self.scale)
        let result = await Task.detached(priority: .userInitiated) {
            WallLayout.build(items, scale: scale, width: width, focus: focus)
        }.value
        guard !Task.isCancelled else { return }
        self.focus = nil
        layout = result
        layoutID += 1
        building = false
    }

    private func select(_ element: WallElement) {
        switch element.kind {
        case .tile(let item, _):
            store.open(item, in: items)
        case .header:
            break
        case .card(let section):
            // A year opens its months; a month opens its days.
            focus = section.date
            let next: TimeScale = layout.scale == .years ? .months : .days
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { scale = next }
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

/// What the collection view knows about the scroll, read without redrawing SwiftUI.
final class WallTracker {
    var distance: CGFloat = 0
    var topDate: Date?
}

// MARK: Collection view

struct CollectionWall: UIViewRepresentable {
    var layout: WallLayout
    var layoutID: Int
    var topInset: CGFloat
    var topRequest: Int
    var tracker: WallTracker
    var onScroll: (CGFloat) -> Void
    var onSelect: (WallElement) -> Void
    var refresh: () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let view = UICollectionView(frame: .zero, collectionViewLayout: WallCollectionLayout())
        view.backgroundColor = .clear
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.contentInsetAdjustmentBehavior = .always
        view.contentInset.bottom = 104
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        let control = UIRefreshControl()
        control.addTarget(context.coordinator, action: #selector(Coordinator.refreshPulled(_:)), for: .valueChanged)
        view.refreshControl = control
        context.coordinator.lastTopRequest = topRequest
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if view.contentInset.top != topInset {
            let atTop = view.contentOffset.y <= -view.adjustedContentInset.top + 1
            view.contentInset.top = topInset
            if atTop { view.contentOffset.y = -view.adjustedContentInset.top }
        }
        if coordinator.layoutID != layoutID, let collectionLayout = view.collectionViewLayout as? WallCollectionLayout {
            coordinator.layoutID = layoutID
            collectionLayout.wall = layout
            view.reloadData()
            collectionLayout.invalidateLayout()
            view.layoutIfNeeded()
            if let y = layout.initialY {
                let maxOffset = max(layout.height + view.adjustedContentInset.bottom - view.bounds.height, -view.adjustedContentInset.top)
                view.setContentOffset(CGPoint(x: 0, y: min(y - view.adjustedContentInset.top, maxOffset)), animated: false)
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

        init(_ parent: CollectionWall) { self.parent = parent }

        private var wall: WallLayout { parent.layout }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            (collectionView.collectionViewLayout as? WallCollectionLayout)?.wall.elements.count ?? 0
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
            guard let elements = (collectionView.collectionViewLayout as? WallCollectionLayout)?.wall.elements, indexPath.item < elements.count else { return cell }
            let element = elements[indexPath.item]
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
            parent.onSelect(element)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Clamped, so the bounce at the bottom does not count as scrolling up.
            let maxDistance = max(0, scrollView.contentSize.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
            let distance = min(scrollView.contentOffset.y + scrollView.adjustedContentInset.top, maxDistance)
            parent.tracker.distance = distance
            parent.tracker.topDate = wall.date(at: distance + 20)
            parent.onScroll(distance)
        }

        @objc func refreshPulled(_ control: UIRefreshControl) {
            Task { @MainActor in
                await parent.refresh()
                control.endRefreshing()
            }
        }

        private func element(_ collectionView: UICollectionView, _ indexPath: IndexPath) -> WallElement? {
            guard let elements = (collectionView.collectionViewLayout as? WallCollectionLayout)?.wall.elements, indexPath.item < elements.count else { return nil }
            return elements[indexPath.item]
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
    var openSettings: () -> Void
    @State private var direction = BarDirection()

    var body: some View {
        PhotoWall(items: store.items, revision: store.revision, scale: $scale, topRequest: topRequest,
                  onScroll: { direction.apply($0, to: $compact) }, refresh: { await store.refresh() }) {
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
                StatusPill()
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

/// Which bar to show, from the direction of the scroll: scrolling down into the photos
/// shows Días · Meses · Años; scrolling up brings back the main bar, wherever you are.
final class BarDirection {
    private var last: CGFloat = 0
    private var anchor: CGFloat = 0
    private var goingDown = true

    /// True for the scale bar, false for the main bar, nil to leave it as it is.
    func update(_ distance: CGFloat) -> Bool? {
        defer { last = distance }
        let delta = distance - last
        // A jump (a new scale or a tap on Inicio) is not a gesture.
        if abs(delta) > 400 { anchor = distance; return nil }
        if distance < 40 { anchor = distance; return false }
        if delta != 0, (delta > 0) != goingDown { goingDown = delta > 0; anchor = last }
        if goingDown && distance - anchor > 24 { return true }
        if !goingDown && anchor - distance > 24 { return false }
        return nil
    }

    func apply(_ distance: CGFloat, to compact: Binding<Bool>) {
        guard let next = update(distance), next != compact.wrappedValue else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { compact.wrappedValue = next }
    }
}

/// «Buscando fotos en el NAS…» or «Ordenando por fecha de captura…» while it works.
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

/// «Hoy · 12 fotos» over a day, or «Mayo 2024 ›» over a month.
struct SectionHeader: View {
    var section: TimelineSection
    var scale: TimeScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(scale == .months ? .title3.weight(.bold) : .headline)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Text(mediaSummary(section.items)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if scale == .months { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary) }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(scale == .months ? .isButton : .isHeader)
    }
}

/// One month in Meses or one year in Años: a large photo with its title over it.
struct PeriodCard: View {
    var section: TimelineSection
    var scale: TimeScale

    private var cover: GalleryItem? {
        section.items.first { $0.favorite && !$0.isVideo } ?? section.items.first { !$0.isVideo } ?? section.items.first
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if let cover { Thumbnail(item: cover, pixelSize: geo.size.width).frame(width: geo.size.width, height: geo.size.height) }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.system(size: scale == .years ? 40 : 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(mediaSummary(section.items)).font(.subheadline.weight(.medium)).opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.title), \(mediaSummary(section.items))")
        .accessibilityAddTraits(.isButton)
    }
}
