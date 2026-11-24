import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case library, nas, albums, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .library: return "Fototeca"; case .nas: return "NAS"; case .albums: return "Álbumes"; case .settings: return "Configuración" }
    }
    var symbol: String {
        switch self { case .library: return "photo"; case .nas: return "server.rack"; case .albums: return "rectangle.stack"; case .settings: return "gearshape" }
    }
    var selectedSymbol: String {
        switch self { case .library: return "photo.fill"; case .nas: return "server.rack"; case .albums: return "rectangle.stack.fill"; case .settings: return "gearshape.fill" }
    }
}

/// The four screens under one floating glass bar. On Fototeca, once you scroll into the
/// photos, the bar melts into three pieces: Inicio on the left, Días · Meses · Años in the
/// middle and Configuración on the right. Back at the top it becomes the full bar again.
struct MainView: View {
    @EnvironmentObject var store: GalleryStore
    @State private var tab = AppTab.library
    @State private var scale = TimeScale.days
    @State private var compact = false
    @State private var topRequest = 0
    @State private var opened: Set<AppTab> = [.library]
    @Namespace private var glass
    @Namespace private var lens

    private var showCompact: Bool { tab == .library && compact }

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
                    .opacity(tab == .library && compact ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                bar
                    .padding(.horizontal, 14)
                    .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 0 : 12)
                    // A little closer to the edge than the safe area, without touching it.
                    .offset(y: geo.safeAreaInsets.bottom > 0 ? 8 : 0)
            }
        }
        .fullScreenCover(item: $store.viewer) { ViewerView(context: $0).environmentObject(store) }
    }

    @ViewBuilder private func screen(_ item: AppTab) -> some View {
        switch item {
        case .library: LibraryView(scale: $scale, compact: $compact, topRequest: topRequest, openSettings: { select(.settings) })
        case .nas: NASView(openSettings: { select(.settings) })
        case .albums: AlbumsView()
        case .settings: SettingsView()
        }
    }

    private var bar: some View {
        GlassGroup(spacing: 16) {
            HStack(spacing: 10) {
                if showCompact {
                    GlassCircleButton(systemImage: "house.fill", label: "Inicio", id: "home", namespace: glass, size: 56) { goHome() }
                    Spacer(minLength: 0)
                    ScaleSwitcher(scale: $scale, namespace: lens)
                        .glassPiece(Capsule(), id: "bar", in: glass)
                    Spacer(minLength: 0)
                    GlassCircleButton(systemImage: "gearshape.fill", label: "Configuración", id: "gear", namespace: glass, size: 56) { select(.settings) }
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
        if item == tab {
            if item == .library { topRequest += 1 }
            return
        }
        opened.insert(item)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { tab = item }
    }

    private func goHome() {
        if tab != .library { withAnimation { tab = .library } }
        topRequest += 1
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
                    VStack(spacing: 4) {
                        Image(systemName: selected ? item.selectedSymbol : item.symbol)
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 20, weight: .semibold))
                            .frame(height: 24)
                        Text(item.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selected ? Color.white : Palette.ink)
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .selectionLens(selected, in: namespace)
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .frame(height: 70)
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
                        .padding(.horizontal, 13).frame(height: 46)
                        .selectionLens(selected, in: namespace)
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .frame(height: 56)
        .fixedSize(horizontal: true, vertical: false)
        .sensoryFeedback(.selection, trigger: scale)
    }
}
