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

/// Fototeca: the photo wall of the iPhone and the NAS together.
struct LibraryView: View {
    @EnvironmentObject var store: GalleryStore
    @Binding var scale: TimeScale
    @Binding var compact: Bool
    var topRequest: Int
    var openSettings: () -> Void

    @State private var sections: [TimelineSection] = []
    @State private var rows: [LibraryRow] = []
    @State private var tracker = FocusTracker()
    @State private var width: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: OffsetKey.self, value: g.frame(in: .named("library")).minY)
                            })
                        header
                        if store.items.isEmpty { empty } else { wall }
                    }
                }
                .coordinateSpace(name: "library")
                .scrollIndicators(.hidden)
                .contentMargins(.bottom, 110, for: .scrollContent)
                .refreshable { await store.refresh() }
                .onPreferenceChange(OffsetKey.self) { y in
                    let next = compact ? y < -30 : y < -90
                    if next != compact { compact = next }
                }
                .onChange(of: topRequest) {
                    tracker.requested = nil
                    withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo("top", anchor: .top) }
                }
                .onChange(of: scale) { old, new in
                    let target = compact || tracker.requested != nil ? tracker.focus : nil
                    tracker.requested = nil
                    tracker.visible = [:]
                    rebuild(width: geo.size.width)
                    guard let target, let section = Timeline.section(containing: target, in: sections, scale: new) else { return }
                    DispatchQueue.main.async { proxy.scrollTo(section.id, anchor: .top) }
                }
                .onChange(of: store.revision) { rebuild(width: geo.size.width) }
                .onChange(of: geo.size.width) { _, value in rebuild(width: value) }
                .onAppear { rebuild(width: geo.size.width) }
            }
        }
    }

    private func rebuild(width: CGFloat) {
        let inner = width - LibraryRows.spacing * 2
        sections = Timeline.sections(store.items, scale: scale)
        rows = LibraryRows.build(sections, scale: scale, width: inner)
        self.width = inner
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Brand()
                Spacer(minLength: 8)
                StatusPill()
            }
            if let status = store.scanStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                .padding(.horizontal, 12).frame(height: 30)
                .liquidCapsule()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var wall: some View {
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
                tracker.requested = section.date
                scale = .days
            }
        case .mosaic(let block, let items):
            ZStack(alignment: .topLeading) {
                ForEach(0..<min(items.count, block.tiles.count), id: \.self) { index in
                    tileButton(items[index], size: block.tiles[index].frame.size, corner: 8)
                        .offset(x: block.tiles[index].frame.minX, y: block.tiles[index].frame.minY)
                }
            }
            .frame(width: width, height: block.height, alignment: .topLeading)
        case .squares(let items):
            let side = ((width - LibraryRows.spacing * CGFloat(LibraryRows.columns - 1)) / CGFloat(LibraryRows.columns)).rounded(.down)
            HStack(spacing: LibraryRows.spacing) {
                ForEach(items) { item in tileButton(item, size: CGSize(width: side, height: side), corner: 6) }
                Spacer(minLength: 0)
            }
            .frame(width: width)
        case .year(let section):
            YearCard(section: section) {
                tracker.requested = section.date
                scale = .months
            }
            .padding(.horizontal, 4).padding(.bottom, 10)
        }
    }

    private func tileButton(_ item: GalleryItem, size: CGSize, corner: CGFloat) -> some View {
        Button { store.open(item, in: store.items) } label: {
            Thumbnail(item: item, pixelSize: max(size.width, size.height))
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }

    @ViewBuilder private var empty: some View {
        if store.scanning || (store.items.isEmpty && store.photoAccess.canRead && store.phoneItems.isEmpty && store.account != nil && store.nasItems.isEmpty && store.nasState == .checking) {
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
            EmptyState(symbol: "photo", title: "Sin fotos", message: "No se encontraron fotos ni videos. Desliza hacia abajo para buscar de nuevo.")
                .padding(.top, 60)
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
