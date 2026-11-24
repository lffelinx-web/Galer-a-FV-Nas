import SwiftUI

enum LibraryRowKind {
    case header(TimelineSection)
    case mosaic(MosaicBlock, [GalleryItem])
    case squares([GalleryItem])
    case year(TimelineSection)
}

struct LibraryRow: Identifiable {
    let id: String
    let date: Date
    let kind: LibraryRowKind
}

enum LibraryRows {
    static let spacing: CGFloat = 4
    static let columns = 4

    static func build(_ sections: [TimelineSection], scale: TimeScale, width: CGFloat) -> [LibraryRow] {
        guard width > 0 else { return [] }
        var rows: [LibraryRow] = []
        for section in sections {
            switch scale {
            case .days:
                rows.append(LibraryRow(id: section.id, date: section.date, kind: .header(section)))
                let blocks = Mosaic.layout(aspects: section.items.map(\.aspect), width: width, spacing: spacing)
                for (number, block) in blocks.enumerated() {
                    rows.append(LibraryRow(id: section.id + "#\(number)", date: section.date, kind: .mosaic(block, block.tiles.map { section.items[$0.index] })))
                }
            case .months:
                rows.append(LibraryRow(id: section.id, date: section.date, kind: .header(section)))
                var start = 0
                while start < section.items.count {
                    let end = min(start + columns, section.items.count)
                    rows.append(LibraryRow(id: section.id + "#\(start)", date: section.date, kind: .squares(Array(section.items[start..<end]))))
                    start = end
                }
            case .years:
                rows.append(LibraryRow(id: section.id, date: section.date, kind: .year(section)))
            }
        }
        return rows
    }
}

/// Remembers which sections are on screen without redrawing the view, so switching
/// between Días, Meses and Años keeps your place.
final class FocusTracker {
    var visible: [String: Date] = [:]
    var requested: Date?
    var focus: Date? { requested ?? visible.values.max() }
}

private struct OffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// How far the content is scrolled from the top. iOS 18 and later report it directly;
/// earlier versions read the position of a marker at the top of the content.
private struct ScrollDistance: ViewModifier {
    var action: (CGFloat) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, distance in
                action(distance)
            }
        } else {
            content.onPreferenceChange(OffsetKey.self) { action(-$0) }
        }
    }
}

private struct WallKey: Equatable {
    let revision: Int
    let scale: TimeScale
    let width: CGFloat
}

/// The photo wall shared by Fototeca and NAS: a mosaic by day, a grid by month or a card
/// per year. The layout of tens of thousands of photos is built off the main thread.
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

    @State private var sections: [TimelineSection] = []
    @State private var rows: [LibraryRow] = []
    @State private var width: CGFloat = 0
    @State private var tracker = FocusTracker()
    @State private var pendingJump: Date?
    @State private var building = true
    @State private var layoutID = 0

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                            .background(GeometryReader { marker in
                                Color.clear.preference(key: OffsetKey.self, value: marker.frame(in: .named("wall")).minY)
                            })
                        header()
                        if items.isEmpty { empty() }
                        else if rows.isEmpty && building { ProgressView().padding(.top, 80) }
                        else { wall }
                    }
                }
                .coordinateSpace(name: "wall")
                .scrollIndicators(.hidden)
                .contentMargins(.bottom, 110, for: .scrollContent)
                .modifier(ScrollDistance(action: onScroll))
                .refreshable { await refresh() }
                .onChange(of: topRequest) {
                    tracker.requested = nil
                    withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo("top", anchor: .top) }
                }
                .onChange(of: scale) {
                    // Keep the place: jump to the same dates once the new layout is ready.
                    pendingJump = tracker.focus
                    tracker.requested = nil
                    tracker.visible = [:]
                }
                .task(id: WallKey(revision: revision, scale: scale, width: geo.size.width - LibraryRows.spacing * 2)) {
                    await build(width: geo.size.width - LibraryRows.spacing * 2, proxy: proxy)
                }
            }
        }
    }

    private func build(width: CGFloat, proxy: ScrollViewProxy) async {
        guard width > 0 else { return }
        building = true
        let (items, scale) = (self.items, self.scale)
        let result = await Task.detached(priority: .userInitiated) { () -> ([TimelineSection], [LibraryRow]) in
            let sections = Timeline.sections(items, scale: scale)
            return (sections, LibraryRows.build(sections, scale: scale, width: width))
        }.value
        guard !Task.isCancelled else { return }
        sections = result.0
        rows = result.1
        self.width = width
        layoutID += 1
        building = false
        if let target = pendingJump {
            pendingJump = nil
            if let section = Timeline.section(containing: target, in: sections, scale: scale) {
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.scrollTo(section.id, anchor: .top)
            }
        }
    }

    private var wall: some View {
        WallRows(rows: rows, layoutID: layoutID, width: width, scale: scale, tracker: tracker,
                 jump: { date, next in
                     tracker.requested = date
                     scale = next
                 },
                 open: { [items] item in store.open(item, in: items) })
            .equatable()
    }
}

/// The rows themselves. They only redraw when the layout changes, not on every status
/// change of the store, which matters with tens of thousands of photos.
private struct WallRows: View, Equatable {
    let rows: [LibraryRow]
    let layoutID: Int
    let width: CGFloat
    let scale: TimeScale
    let tracker: FocusTracker
    let jump: (Date, TimeScale) -> Void
    let open: (GalleryItem) -> Void

    static func == (lhs: WallRows, rhs: WallRows) -> Bool {
        lhs.layoutID == rhs.layoutID && lhs.width == rhs.width && lhs.scale == rhs.scale
    }

    var body: some View {
        LazyVStack(spacing: LibraryRows.spacing) {
            ForEach(rows) { row in
                rowView(row)
                    .id(row.id)
                    .onAppear { tracker.visible[row.id] = row.date }
                    .onDisappear { tracker.visible[row.id] = nil }
            }
        }
        .padding(.horizontal, LibraryRows.spacing)
    }

    @ViewBuilder private func rowView(_ row: LibraryRow) -> some View {
        switch row.kind {
        case .header(let section):
            SectionHeader(section: section, scale: scale) {
                guard scale == .months else { return }
                jump(section.date, .days)
            }
        case .mosaic(let block, let tiles):
            ZStack(alignment: .topLeading) {
                ForEach(0..<min(tiles.count, block.tiles.count), id: \.self) { index in
                    tileButton(tiles[index], size: block.tiles[index].frame.size, corner: 8)
                        .offset(x: block.tiles[index].frame.minX, y: block.tiles[index].frame.minY)
                }
            }
            .frame(width: width, height: block.height, alignment: .topLeading)
        case .squares(let tiles):
            let side = ((width - LibraryRows.spacing * CGFloat(LibraryRows.columns - 1)) / CGFloat(LibraryRows.columns)).rounded(.down)
            HStack(spacing: LibraryRows.spacing) {
                ForEach(tiles) { item in tileButton(item, size: CGSize(width: side, height: side), corner: 6) }
                Spacer(minLength: 0)
            }
            .frame(width: width)
        case .year(let section):
            YearCard(section: section) { jump(section.date, .months) }
                .padding(.horizontal, 4).padding(.bottom, 10)
        }
    }

    private func tileButton(_ item: GalleryItem, size: CGSize, corner: CGFloat) -> some View {
        Button { open(item) } label: {
            Thumbnail(item: item, pixelSize: max(size.width, size.height))
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// Fototeca: the photos of the iPhone and the NAS together.
struct LibraryView: View {
    @EnvironmentObject var store: GalleryStore
    @Binding var scale: TimeScale
    @Binding var compact: Bool
    var topRequest: Int
    var openSettings: () -> Void

    var body: some View {
        PhotoWall(items: store.items, revision: store.revision, scale: $scale, topRequest: topRequest,
                  onScroll: updateCompact, refresh: { await store.refresh() }) {
            header
        } empty: {
            empty
        }
    }

    /// The bar splits once the photos reach the top, and joins again near the top.
    private func updateCompact(_ distance: CGFloat) {
        let next = compact ? distance > 30 : distance > 90
        guard next != compact else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { compact = next }
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

/// «Buscando fotos en el NAS…» while a search runs.
struct ScanBanner: View {
    @EnvironmentObject var store: GalleryStore
    var body: some View {
        if let status = store.scanStatus {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .liquidCapsule()
        }
    }
}

struct SectionHeader: View {
    var section: TimelineSection
    var scale: TimeScale
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title)
                    .font(scale == .months ? .title3.weight(.bold) : .headline)
                    .foregroundStyle(Palette.ink)
                Text(mediaSummary(section.items)).font(.caption).foregroundStyle(Palette.secondary)
                Spacer(minLength: 0)
                if scale == .months { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 14).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(scale != .months)
    }
}

/// One year in Años: a large photo with the year over it.
struct YearCard: View {
    var section: TimelineSection
    var action: () -> Void

    private var cover: GalleryItem? {
        section.items.first { $0.favorite && !$0.isVideo } ?? section.items.first { !$0.isVideo } ?? section.items.first
    }

    var body: some View {
        Button(action: action) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    if let cover { Thumbnail(item: cover, pixelSize: geo.size.width).frame(width: geo.size.width, height: geo.size.height) }
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title).font(.system(size: 40, weight: .bold))
                        Text(mediaSummary(section.items)).font(.subheadline.weight(.medium)).opacity(0.9)
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: Palette.accent.opacity(0.12), radius: 14, y: 6)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(section.title), \(mediaSummary(section.items))")
    }
}
