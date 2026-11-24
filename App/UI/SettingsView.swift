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
    @State private var editingPassword = false
    @State private var testing = false

    /// Whether the form differs from the saved account.
    private var changed: Bool {
        guard let account = store.account else { return true }
        return address != account.root.absoluteString || user != account.username || password != account.password
            || name != (account.displayName ?? "") || route != account.routeIP || tailscale != (account.tailscaleHost ?? "")
            || connectionMode != (account.connectionMode ?? .automatic)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { status }

                Section {
                    LabeledField(title: "Dirección") {
                        TextField("https://tu-nas.synology.me:5006/photo/", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                    LabeledField(title: "Usuario") {
                        TextField("Usuario", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    }
                    LabeledField(title: "Contraseña") {
                        if store.account != nil && !editingPassword {
                            HStack {
                                Text("••••••••").foregroundStyle(Palette.ink)
                                Spacer()
                                Button("Cambiar") { password = ""; editingPassword = true }.buttonStyle(.borderless)
                            }
                        } else {
                            SecureField("Contraseña", text: $password).textContentType(.password)
                        }
                    }
                    LabeledField(title: "Nombre") {
                        TextField("Por ejemplo DS120j", text: $name).autocorrectionDisabled()
                    }
                } header: { Text("Conexión al NAS") } footer: {
                    Text("Escribe la dirección WebDAV de la carpeta compartida de tus fotos, con la ruta incluida. La cuenta se guarda en el llavero de este iPhone.")
                }
                Section {
                    LabeledField(title: "IP local") {
                        TextField("Opcional", text: $route).keyboardType(.numbersAndPunctuation)
                    }
                    LabeledField(title: "Tailscale") {
                        TextField("IP o nombre MagicDNS", text: $tailscale).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("Ruta", selection: $connectionMode) { ForEach(NASConnectionMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                } header: { Text("Red local y Tailscale") } footer: {
                    Text("Mantén arriba el dominio HTTPS del certificado. Automática prueba la red local y después Tailscale; activa Tailscale en el iPhone fuera de casa.")
                }
                Section {
                    Button {
                        Task {
                            saved = await store.connect(root: address, user: user, password: password, route: route, tailscale: tailscale, mode: connectionMode, name: name)
                            if saved { editingPassword = false }
                        }
                    } label: {
                        HStack {
                            Text(store.connecting ? "Conectando…" : store.account == nil ? "Conectar y guardar" : "Guardar cambios")
                            Spacer()
                            if store.connecting { ProgressView() } else if saved && !changed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.online) }
                        }
                    }
                    .disabled(store.connecting || !changed || address.isEmpty || user.isEmpty || password.isEmpty)
                }

                Section {
                    Toggle("Fotos del iPhone", isOn: $store.showPhone)
                    Toggle("Fotos del NAS", isOn: $store.showNAS)
                    Toggle("Ocultar duplicados", isOn: $store.hideDuplicates)
                } header: { Text("Mostrar en la Fototeca") } footer: {
                    Text(store.hideDuplicates && store.duplicatesHidden > 0
                         ? "\(store.duplicatesHidden.formatted()) fotos del NAS ya están en este iPhone (por ejemplo, un respaldo) y se muestran una sola vez. En la pestaña NAS siguen apareciendo todas."
                         : "Las fotos del NAS que también están en este iPhone se muestran una sola vez. Se detectan por la fecha de captura, que se lee en segundo plano.")
                }

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

    /// «● Conectado a DS120j · Red local 192.168.1.70», always at the top.
    private var status: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Palette.selection, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(statusTitle).font(.headline).foregroundStyle(Palette.ink)
                }
                Text(statusDetail).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if store.account != nil {
                Button {
                    testing = true
                    Task { await store.checkConnection(); testing = false }
                } label: {
                    if testing || store.nasState == .checking { ProgressView() } else { Text("Probar").font(.subheadline.weight(.semibold)) }
                }
                .buttonStyle(.borderless)
                .disabled(testing)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch store.nasState {
        case .connected: return Palette.online
        case .checking: return Palette.warning
        case .offline: return .red
        case .notConfigured: return .gray
        }
    }

    private var statusTitle: String {
        switch store.nasState {
        case .connected: return "Conectado a \(store.nasLabel)"
        case .checking: return "Conectando a \(store.nasLabel)…"
        case .offline: return "Sin conexión con \(store.nasLabel)"
        case .notConfigured: return "Sin NAS configurado"
        }
    }

    private var statusDetail: String {
        switch store.nasState {
        case .connected:
            let route = store.routeLabel ?? store.account?.root.host ?? ""
            return store.nasItems.isEmpty ? route : route + " · " + mediaSummary(store.nasItems)
        case .checking: return store.account?.root.host ?? ""
        case .offline: return "Revisa que estés en tu red o que Tailscale esté activo, y toca Probar."
        case .notConfigured: return "Escribe abajo la dirección de la carpeta de fotos de tu Synology."
        }
    }

    private func fill() {
        editingPassword = false
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

/// A form row with a fixed label on the left, so every field says what it is even when filled.
struct LabeledField<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Palette.secondary).frame(width: 92, alignment: .leading)
            content()
        }
    }
}
