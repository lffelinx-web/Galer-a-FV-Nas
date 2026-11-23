import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: GalleryStore
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var name = ""
    @State private var route = ""
    @State private var tailscale = ""
    @State private var connectionMode = NASConnectionMode.automatic
    @State private var cacheSize = "—"
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://tu-nas.synology.me:5006/photo/", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Usuario", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    SecureField("Contraseña", text: $password).textContentType(.password)
                    TextField("Nombre del NAS (por ejemplo DS120j)", text: $name).autocorrectionDisabled()
                } header: { Text("Conexión al NAS") } footer: {
                    Text("Escribe la dirección WebDAV de la carpeta compartida de tus fotos, con la ruta incluida. La cuenta se guarda en el llavero de este iPhone.")
                }
                Section {
                    TextField("IP local (opcional)", text: $route).keyboardType(.numbersAndPunctuation)
                    TextField("IP Tailscale o nombre MagicDNS", text: $tailscale).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Ruta", selection: $connectionMode) { ForEach(NASConnectionMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                } header: { Text("Red local y Tailscale") } footer: {
                    Text("Mantén arriba el dominio HTTPS del certificado. Automática prueba la red local y después Tailscale; activa Tailscale en el iPhone fuera de casa.")
                }
                Section {
                    Button {
                        Task {
                            saved = await store.connect(root: address, user: user, password: password, route: route, tailscale: tailscale, mode: connectionMode, name: name)
                        }
                    } label: {
                        HStack {
                            Text(store.connecting ? "Conectando…" : "Conectar y guardar")
                            Spacer()
                            if store.connecting { ProgressView() } else if saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.online) }
                        }
                    }
                    .disabled(store.connecting || address.isEmpty || user.isEmpty || password.isEmpty)
                }

                Section {
                    Toggle("Fotos del iPhone", isOn: $store.showPhone)
                    Toggle("Fotos del NAS", isOn: $store.showNAS)
                } header: { Text("Mostrar en la Fototeca") }

                Section {
                    LabeledContent("Permiso", value: store.photoAccess.label)
                    if store.photoAccess == .notDetermined {
                        Button("Permitir acceso a las fotos") { Task { await store.requestPhotoAccess() } }
                    } else if store.photoAccess != .full {
                        Button("Abrir Ajustes del iPhone") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    LabeledContent("Fotos y videos", value: store.phoneItems.isEmpty ? "—" : mediaSummary(store.phoneItems))
                } header: { Text("Fotos del iPhone") } footer: {
                    Text("LF’AZ Galería solo lee tu fototeca; no cambia ni borra nada.")
                }

                if store.account != nil {
                    Section {
                        Button {
                            store.scan()
                        } label: {
                            HStack { Text(store.scanning ? "Buscando…" : "Buscar fotos nuevas en el NAS"); Spacer(); if store.scanning { ProgressView() } }
                        }
                        .disabled(store.scanning)
                        if let status = store.scanStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                        LabeledContent("Contenido", value: store.nasItems.isEmpty ? "—" : mediaSummary(store.nasItems))
                    } header: { Text("Biblioteca del NAS") }
                }

                Section {
                    LabeledContent("Miniaturas y videos", value: cacheSize)
                    Button("Vaciar caché") {
                        Task { await NASImageLoader.shared.clear(); refreshCacheSize() }
                    }
                } header: { Text("Almacenamiento") } footer: {
                    Text("Las miniaturas del NAS se guardan en este iPhone para que la galería cargue al instante.")
                }

                if store.account != nil {
                    Section { Button("Cerrar sesión del NAS", role: .destructive) { store.disconnect(); fill() } }
                }

                Section {
                    LabeledContent("Versión", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .contentMargins(.bottom, 100, for: .scrollContent)
            .navigationTitle("Configuración")
            .onAppear { fill(); refreshCacheSize() }
        }
    }

    private func fill() {
        guard let account = store.account else { address = ""; user = ""; password = ""; name = ""; route = ""; tailscale = ""; return }
        address = account.root.absoluteString; user = account.username; password = account.password; name = account.displayName ?? ""
        route = account.routeIP; tailscale = account.tailscaleHost ?? ""; connectionMode = account.connectionMode ?? .automatic
    }

    private func refreshCacheSize() {
        Task.detached(priority: .utility) {
            let size = NASImageLoader.cacheSize()
            await MainActor.run { cacheSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        }
    }
}
