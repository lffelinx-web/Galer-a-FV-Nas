import SwiftUI

@main
struct LFAZGaleriaApp: App {
    @StateObject private var store = GalleryStore.shared
    @Environment(\.scenePhase) private var scenePhase
    /// «system», «light» or «dark», from Configuración.
    @AppStorage("appearance") private var appearance = "system"

    init() {
        BackgroundJobs.register()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
                .tint(Palette.accent)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .task { await store.start() }
                .alert("No se pudo completar", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                    Button("Aceptar", role: .cancel) { store.error = nil }
                } message: { Text(store.error ?? "") }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: Task { await store.suspend() }
            case .active: Task { await store.resume() }
            default: break
            }
        }
    }
}
