import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case library, nas, albums, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .library: return "Fototeca"; case .nas: return "NAS"; case .albums: return "Espacio"; case .settings: return "Configuración" }
    }
    var symbol: String {
        switch self { case .library: return "photo"; case .nas: return "server.rack"; case .albums: return "square.grid.2x2"; case .settings: return "gearshape" }
    }
    var selectedSymbol: String {
        switch self { case .library: return "photo.fill"; case .nas: return "server.rack"; case .albums: return "square.grid.2x2.fill"; case .settings: return "gearshape.fill" }
    }
}

/// The four screens under one floating glass bar. On Fototeca, once you scroll into the
/// photos, the bar melts into three pieces: Inicio on the left, Días · Meses · Años in the
/// middle and Configuración on the right. Back at the top it becomes the full bar again.
struct MainView: View {
    @EnvironmentObject var store: GalleryStore
    @State private var tab = AppTab.library
    @State private var libraryScale = TimeScale.days
    @State private var nasScale = TimeScale.days
    @State private var compact = false
    @State private var libraryTop = 0
    @State private var nasTop = 0
    @State private var libraryJump: DateJump?
    @State private var nasJump: DateJump?
    @State private var choosingDate = false
    @State private var opened: Set<AppTab> = [.library]
    @Namespace private var glass
    @Namespace private var lens

    /// Both bars share this height, so changing from one to the other is a smooth morph.
    static let barHeight: CGFloat = 62

    /// Fototeca and NAS both split their bar while scrolling down through the photos.
    private var showCompact: Bool { (tab == .library || tab == .nas) && compact }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AppBackground()
                ForEach(AppTab.allCases) { item in
                    if opened.contains(item) {
                        screen(item)
                            .opacity(item == tab ? 1 : 0)
                            .allowsHitTesting(item == tab)
                            .accessibilityHidden(item != tab)
                    }
                }
            }
            .overlay(alignment: .top) {
                // Keeps the clock readable while photos scroll under the status bar.
                LinearGradient(colors: [Palette.background.opacity(0.95), Palette.background.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.safeAreaInsets.top + 14)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .opacity(showCompact ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                Group {
                    if store.selection != nil {
                        SelectionBar().transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        bar
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 0 : 12)
                // A little closer to the edge than the safe area, without touching it.
                .offset(y: geo.safeAreaInsets.bottom > 0 ? 8 : 0)
            }
            .overlay(alignment: .top) {
                if let selection = store.selection {
                    HStack {
                        Text(selection.isEmpty ? "Elige fotos" : countText(selection.count, "seleccionada", "seleccionadas"))
                            .font(.headline).foregroundStyle(Palette.ink)
                            .padding(.horizontal, 16).frame(height: 44)
                            .liquidCapsule()
                        Spacer()
                        Button("Cancelar") { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.selection = nil } }
                            .font(.headline).foregroundStyle(Palette.accent)
                            .padding(.horizontal, 16).frame(height: 44)
                            .liquidCapsule()
                            .buttonStyle(PressStyle())
                    }
                    .padding(.horizontal, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.selection == nil)
        }
        .fullScreenCover(item: $store.viewer) { ViewerView(context: $0).environmentObject(store) }
        .onChange(of: store.dayRequest) { _, request in
            // «Ver en el día» from the viewer: that date in the mosaic, in Fototeca or NAS.
            guard let request else { return }
            let target: AppTab = request.nas ? .nas : .library
            if tab != target { opened.insert(target); tab = target }
            compact = false
            if request.nas { nasJump = DateJump(date: request.date) } else { libraryJump = DateJump(date: request.date) }
        }
        .sheet(isPresented: $choosingDate) {
            DateJumpSheet(items: tab == .nas ? store.nasShown : store.items) { date in
                if tab == .nas { nasJump = DateJump(date: date) } else { libraryJump = DateJump(date: date) }
            }
        }
    }

    @ViewBuilder private func screen(_ item: AppTab) -> some View {
        switch item {
        case .library: LibraryView(scale: $libraryScale, compact: $compact, topRequest: libraryTop, jump: libraryJump,
                                   openSettings: { select(.settings) }, openNAS: { select(.nas) })
        case .nas: NASView(scale: $nasScale, compact: $compact, topRequest: nasTop, jump: nasJump, openSettings: { select(.settings) })
        case .albums: SpaceView(visible: tab == .albums)
        case .settings: SettingsView()
        }
    }

    private var bar: some View {
        GlassGroup(spacing: 16) {
            HStack(spacing: 0) {
                if showCompact {
                    GlassCircleButton(systemImage: "house.fill", label: "Inicio", id: "home", namespace: glass, size: Self.barHeight) { goHome() }
                    Spacer(minLength: 6)
                    ScaleSwitcher(scale: tab == .nas ? $nasScale : $libraryScale, namespace: lens)
                        .glassPiece(Capsule(), id: "bar", in: glass)
                    Spacer(minLength: 6)
                    GlassCircleButton(systemImage: "calendar", label: "Ir a fecha", id: "gear", namespace: glass, size: Self.barHeight) { choosingDate = true }
                } else {
                    FullTabBar(tab: tab, namespace: lens, select: select)
                        .glassPiece(Capsule(), id: "bar", in: glass)
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: showCompact)
        .sensoryFeedback(.selection, trigger: showCompact)
    }

    private func select(_ item: AppTab) {
        store.selection = nil
        if item == tab {
            scrollToTop()
            return
        }
        opened.insert(item)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = item; compact = false }
    }

    /// Inicio: back to the top of the photos you are looking at, where the main bar returns.
    private func goHome() {
        scrollToTop()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { compact = false }
    }

    private func scrollToTop() {
        switch tab {
        case .library: libraryTop += 1
        case .nas: nasTop += 1
        default: break
        }
    }
}

/// Fototeca · NAS · Álbumes · Configuración.
struct FullTabBar: View {
    var tab: AppTab
    var namespace: Namespace.ID
    var select: (AppTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { item in
                let selected = item == tab
                Button { select(item) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: selected ? item.selectedSymbol : item.symbol)
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(height: 22)
                        Text(item.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selected ? Color.white : Palette.ink)
                    .frame(maxWidth: .infinity).frame(height: MainView.barHeight - 10)
                    .selectionLens(selected, in: namespace)
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .frame(height: MainView.barHeight)
    }
}

/// Días · Meses · Años, joined in one capsule.
struct ScaleSwitcher: View {
    @Binding var scale: TimeScale
    var namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimeScale.allCases) { item in
                let selected = item == scale
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { scale = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 15, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? Color.white : Palette.ink)
                        .padding(.horizontal, 11).frame(height: MainView.barHeight - 10)
                        .selectionLens(selected, in: namespace)
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .frame(height: MainView.barHeight)
        .fixedSize(horizontal: true, vertical: false)
        .sensoryFeedback(.selection, trigger: scale)
    }
}


/// While choosing several photos: share them, add them to an album, mark them as favorites
/// or hide them, all at once.
struct SelectionBar: View {
    @EnvironmentObject var store: GalleryStore
    @State private var albumIDs: [String]?
    @State private var shareFiles: [URL]?
    @State private var working: String?

    var body: some View {
        let items = store.selectedItems
        let allFavorite = !items.isEmpty && items.allSatisfy(store.isFavorite)
        HStack(spacing: 0) {
            button("square.and.arrow.up", "Compartir") { Task { await share(items) } }
            button("rectangle.stack.badge.plus", "Álbum") { albumIDs = items.map(\.id) }
            button(allFavorite ? "heart.fill" : "heart", allFavorite ? "Quitar" : "Favorito") {
                store.setFavorite(items, !allFavorite)
            }
            button("eye.slash", "Ocultar") {
                store.setHidden(items, true)
                store.selection = nil
            }
        }
        .disabled(items.isEmpty || working != nil)
        .opacity(items.isEmpty ? 0.5 : 1)
        .padding(.horizontal, 6)
        .frame(height: MainView.barHeight)
        .liquidCapsule()
        .overlay {
            if let working {
                HStack(spacing: 8) { ProgressView(); Text(working).font(.footnote.weight(.semibold)) }
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: -MainView.barHeight)
            }
        }
        .sheet(item: Binding(get: { albumIDs.map(IDList.init) }, set: { albumIDs = $0?.ids })) {
            AddToAlbumSheet(itemIDs: $0.ids).environmentObject(store)
        }
        .sheet(item: Binding(get: { shareFiles.map(FileList.init) }, set: { shareFiles = $0?.urls })) {
            ActivitySheet(items: $0.urls).ignoresSafeArea()
        }
    }

    private func button(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity).frame(height: MainView.barHeight - 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    /// The originals, one by one (NAS ones are downloaded), then the share sheet with all.
    private func share(_ items: [GalleryItem]) async {
        var files: [URL] = []
        for (index, item) in items.enumerated() {
            working = "Preparando \(index + 1) de \(items.count)…"
            if let file = try? await ItemExport.file(for: item, account: store.account) { files.append(file) }
        }
        working = nil
        if files.isEmpty { store.error = "No se pudieron preparar las fotos." } else { shareFiles = files }
    }
}

private struct IDList: Identifiable {
    let ids: [String]
    var id: String { ids.joined(separator: ",") }
}

private struct FileList: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.path).joined(separator: ",") }
}
