import MapKit
import SwiftUI

/// Every photo with a location on a map, grouped into pins with a photo and how many there
/// are; closer in, the groups split. A pin opens its photos.
struct PhotoMapView: View {
    @EnvironmentObject var store: GalleryStore
    @State private var points: [GeoPlace.Point]?
    @State private var clusters: [GeoPlace.Cluster] = []
    @State private var position = MapCameraPosition.automatic
    @State private var region: MKCoordinateRegion?
    @State private var chosen: GeoPlace.Cluster?
    @State private var grouping: Task<Void, Never>?

    var body: some View {
        Map(position: $position) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude), anchor: .center) {
                    Button { chosen = cluster } label: {
                        MapPin(item: cluster.ids.first.flatMap { store.itemIndex[$0] }, count: cluster.ids.count)
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
            regroup()
        }
        .overlay(alignment: .bottom) {
            if let points {
                Text(footer(points.count))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14).frame(height: 34)
                    .liquidCapsule()
                    .padding(.bottom, 100)
            }
        }
        .overlay {
            if points == nil { ProgressView() }
            else if points?.isEmpty == true {
                EmptyState(symbol: "map", title: "Sin ubicaciones todavía",
                           message: "Las fotos del iPhone con ubicación aparecen aquí; las del NAS se van leyendo en segundo plano.")
                    .padding(24).card().padding(24)
            }
        }
        .navigationTitle("Mapa")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $chosen) { PlacePhotosView(cluster: $0) }
        .task(id: store.revision) { await load() }
    }

    private func footer(_ count: Int) -> String {
        var text = countText(count, "foto con ubicación", "fotos con ubicación")
        if store.datesStatus?.hasPrefix("Leyendo ubicaciones") == true { text += " · leyendo el NAS…" }
        return text
    }

    private func load() async {
        let items = store.allVisible
        let found = await Task.detached(priority: .userInitiated) { () -> [GeoPlace.Point] in
            items.compactMap { item in
                guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
                return GeoPlace.Point(id: item.id, latitude: latitude, longitude: longitude, date: item.date)
            }
        }.value
        let first = points == nil
        points = found
        if first, let area = GeoPlace.mainArea(found) {
            let start = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: area.centerLatitude, longitude: area.centerLongitude),
                                           span: MKCoordinateSpan(latitudeDelta: min(area.spanLatitude, 150), longitudeDelta: min(area.spanLongitude, 300)))
            position = .region(start)
            region = start
        }
        regroup()
        PlaceNames.shared.fill(items)
    }

    /// Off the main thread, and only the latest request counts.
    private func regroup() {
        guard let points, let region else { return }
        grouping?.cancel()
        grouping = Task {
            let result = await Task.detached(priority: .userInitiated) {
                GeoPlace.clusters(points, centerLatitude: region.center.latitude, centerLongitude: region.center.longitude,
                                  spanLatitude: region.span.latitudeDelta, spanLongitude: region.span.longitudeDelta)
            }.value
            guard !Task.isCancelled else { return }
            clusters = Array(result.prefix(80))
        }
    }
}

/// A rounded photo with a white border and, for a group, how many it holds.
private struct MapPin: View {
    let item: GalleryItem?
    let count: Int

    var body: some View {
        Group {
            if let item { Thumbnail(item: item, pixelSize: 52, badges: false) } else { Rectangle().fill(Palette.tile) }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text(count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white).monospacedDigit()
                    .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 20)
                    .background(Palette.accent, in: Capsule())
                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                    .offset(x: 10, y: -8)
            }
        }
        .accessibilityLabel(countText(count, "foto", "fotos"))
    }
}

/// The photos of one pin, newest first, under the name of the place.
private struct PlacePhotosView: View {
    @EnvironmentObject var store: GalleryStore
    let cluster: GeoPlace.Cluster
    @State private var title: String?

    var body: some View {
        let items = cluster.ids.compactMap { store.itemIndex[$0] }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(mediaSummary(items)).font(.footnote).foregroundStyle(Palette.secondary)
                SquareGrid(items: items, columns: 4)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(AppBackground())
        .navigationTitle(title ?? countText(items.count, "foto", "fotos"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let first = items.first, let known = PlaceNames.shared.name(first) { title = known.components(separatedBy: ", ").first; return }
            title = await PhotoInfo.placeName(CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude))?
                .components(separatedBy: ", ").first
        }
    }
}
