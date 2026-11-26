import CoreLocation
import Foundation

/// The names of the places where photos were taken («Guadalajara, Jalisco, México»), one
/// per area of about 11 km, kept on the iPhone so each one is asked to Apple only once.
@MainActor
final class PlaceNames {
    static let shared = PlaceNames()

    private(set) var names: [String: String] = Files.load("places.json", as: [String: String].self) ?? [:]
    private var task: Task<Void, Never>?
    private var unnamed: Set<String> = []

    func name(_ item: GalleryItem) -> String? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        return names[GeoPlace.areaKey(latitude, longitude)]
    }

    /// Names the areas that have no name yet, the ones with most photos first, slowly:
    /// Apple limits how many places can be asked in a row.
    func fill(_ items: [GalleryItem]) {
        guard task == nil else { return }
        let known = names
        task = Task {
            let wanted = await Task.detached(priority: .utility) { () -> [String] in
                var counts: [String: Int] = [:]
                for item in items {
                    guard let latitude = item.latitude, let longitude = item.longitude else { continue }
                    let key = GeoPlace.areaKey(latitude, longitude)
                    if known[key] == nil { counts[key, default: 0] += 1 }
                }
                return counts.sorted { $0.value > $1.value }.map(\.key)
            }.value
            var sinceSave = 0
            defer { task = nil; save() }
            for key in wanted where !unnamed.contains(key) {
                guard !Task.isCancelled, let center = GeoPlace.areaCenter(key) else { return }
                if let name = await Self.lookUp(center) {
                    names[key] = name
                    sinceSave += 1
                    if sinceSave >= 10 { save(); sinceSave = 0 }
                } else {
                    // The sea, or Apple asking to slow down: try it another day.
                    unnamed.insert(key)
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_300_000_000)
            }
        }
    }

    func stop() { task?.cancel() }

    private func save() {
        let all = names
        Task.detached(priority: .utility) { try? Files.save(all, name: "places.json") }
    }

    private static func lookUp(_ center: (latitude: Double, longitude: Double)) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: center.latitude, longitude: center.longitude),
                                                                       preferredLocale: Locale(identifier: "es_MX"))
        guard let place = placemarks?.first else { return nil }
        let parts = [place.locality, place.subAdministrativeArea, place.administrativeArea, place.country].compactMap { $0 }
        let unique = parts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }
}
