import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: GalleryStore
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var name = ""
    @State private var route = ""
    @State private var tailscale = ""
    @State private var dsmPort = ""
    @AppStorage("appearance") private var appearance = "system"
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
            || connectionMode != (account.connectionMode ?? .automatic) || dsmPort != (account.dsmPort.map(String.init) ?? "")
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
                    LabeledField(title: "Puerto DSM") {
                        TextField("5001", text: $dsmPort).keyboardType(.numberPad)
                    }
                    Picker("Ruta", selection: $connectionMode) { ForEach(NASConnectionMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                } header: { Text("Red local y Tailscale") } footer: {
                    Text("Mantén arriba el dominio HTTPS del certificado. Automática prueba la red local y después Tailscale; activa Tailscale en el iPhone fuera de casa. El puerto DSM (5001 si lo dejas vacío) se usa solo para leer el espacio libre.")
                }
                Section {
                    Button {
                        Task {
                            saved = await store.connect(root: address, user: user, password: password, route: route, tailscale: tailscale, mode: connectionMode, name: name,
                                                        dsmPort: Int(dsmPort.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil })
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
                    Picker("Apariencia", selection: $appearance) {
                        Text("Como el iPhone").tag("system")
                        Text("Claro").tag("light")
                        Text("Oscuro").tag("dark")
                    }
                } header: { Text("Pantalla") }

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
                    Text("LF’AZ Galería solo lee tu fototeca: no cambia ni borra nada. Solo agrega una foto cuando tú eliges «Guardar en el iPhone» en una del NAS.")
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

    /// The connection at a glance, always at the top: state, NAS and route, last search.
    private var status: some View {
        HStack(alignment: .center, spacing: 14) {
            NASBadge(size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(store.nasState.color).frame(width: 8, height: 8)
                    Text(store.nasState.shortLabel).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                }
                Text(statusDetail).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if let extra = statusExtra {
                    Text(extra).font(.caption).foregroundStyle(Palette.secondary.opacity(0.85)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.account != nil {
                Button {
                    testing = true
                    Task { await store.checkConnection(); testing = false }
                } label: {
                    Group {
                        if testing || store.nasState == .checking { ProgressView().controlSize(.small) }
                        else { Text("Probar").font(.footnote.weight(.semibold)) }
                    }
                    .foregroundStyle(Palette.accent)
                    .frame(minWidth: 64).frame(height: 30)
                    .background(Palette.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.borderless)
                .disabled(testing)
            }
        }
        .padding(.vertical, 6)
    }

    /// «DS120j · Red local 192.168.1.70».
    private var statusDetail: String {
        guard let account = store.account else { return "Escribe abajo la carpeta de fotos de tu Synology." }
        switch store.nasState {
        case .offline: return "\(store.nasLabel) · revisa tu red o Tailscale"
        default: return store.nasLabel + " · " + (store.routeLabel ?? account.root.host ?? "")
        }
    }

    private var statusExtra: String? {
        guard store.account != nil else { return nil }
        var parts: [String] = []
        if let space = store.spaceText { parts.append(space) }
        if let date = store.lastScan { parts.append("Revisado " + date.formatted(.relative(presentation: .named))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func fill() {
        editingPassword = false
        guard let account = store.account else { address = ""; user = ""; password = ""; name = ""; route = ""; tailscale = ""; dsmPort = ""; return }
        address = account.root.absoluteString; user = account.username; password = account.password; name = account.displayName ?? ""
        route = account.routeIP; tailscale = account.tailscaleHost ?? ""; connectionMode = account.connectionMode ?? .automatic
        dsmPort = account.dsmPort.map(String.init) ?? ""
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
