import SwiftUI

/// Espacio, above Recuerdos: the backup in one quiet line, with a thin bar while a photo
/// goes up. «Detalles» shows each photo.
struct BackupCard: View {
    @EnvironmentObject var store: GalleryStore
    @ObservedObject var backup: PhoneBackup
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(backup.problem != nil && !backup.running ? Palette.warning : Palette.accent)
                    .symbolEffect(.pulse, isActive: backup.running)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Respaldo").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(backup.summary).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                Button("Detalles") { details = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Palette.accent.opacity(0.12), in: Capsule())
                    .buttonStyle(.borderless)
            }
            if backup.running {
                ProgressView(value: backup.currentFraction).tint(Palette.accent).scaleEffect(x: 1, y: 0.6, anchor: .center)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Palette.cardStroke, lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: backup.running)
        .sheet(isPresented: $details) { BackupDetailsView(backup: backup).environmentObject(store) }
    }

    private var icon: String {
        if backup.paused { return "pause.circle" }
        if backup.running { return "arrow.up.circle" }
        if backup.problem != nil { return "exclamationmark.circle" }
        return backup.pending > 0 ? "clock.arrow.circlepath" : "checkmark.circle"
    }
}

/// Each photo of the backup: the one going up with its progress, the next in line and the
/// latest copies.
struct BackupDetailsView: View {
    @EnvironmentObject var store: GalleryStore
    @ObservedObject var backup: PhoneBackup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Estado", value: backup.summary)
                    Button(backup.paused ? "Reanudar" : "Pausar") { backup.setPaused(!backup.paused) }
                    Toggle("Usar datos móviles", isOn: $backup.useCellular)
                } footer: {
                    Text("Se copian a «Respaldo iPhone/año/mes» en el NAS, en su formato original. Nunca se borra ni se reemplaza nada.")
                }

                if let current = backup.current {
                    Section("Subiendo ahora") {
                        row(current.id, title: current.name, detail: current.bytes.map { size($0) } ?? "Preparando…") {
                            ProgressView(value: backup.currentFraction).frame(width: 70)
                        }
                    }
                }

                if !backup.queue.isEmpty {
                    Section(backup.pending > backup.queue.count ? "En cola · \(backup.pending.formatted())" : "En cola") {
                        ForEach(backup.queue, id: \.self) { id in
                            row(id, title: store.itemIndex["p:" + id].map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "Foto",
                                detail: store.itemIndex["p:" + id]?.isVideo == true ? "Video" : "Foto") {
                                Image(systemName: "clock").foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                }

                if !backup.recent.isEmpty {
                    Section("Copiadas recientemente") {
                        ForEach(backup.recent) { entry in
                            row(entry.id, title: entry.name,
                                detail: entry.failure ?? ([entry.bytes.map { size($0) }, entry.date.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))) {
                                Image(systemName: entry.failure == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(entry.failure == nil ? Palette.online : Palette.warning)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Respaldo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func row<Trailing: View>(_ assetID: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Group {
                if let item = store.itemIndex["p:" + assetID] {
                    Thumbnail(item: item, pixelSize: 44, badges: false)
                } else {
                    Rectangle().fill(Palette.tile)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Palette.ink).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}
