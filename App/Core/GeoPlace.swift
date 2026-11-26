import Foundation

/// Places without MapKit: reading a position from a video, grouping photos into pins for
/// the map and the areas used to name places for the search.
enum GeoPlace {
    static func valid(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 && !(latitude == 0 && longitude == 0)
    }

    private static let iso6709Expression = try! NSRegularExpression(pattern: "([+-]\\d{1,2}\\.\\d{2,})([+-]\\d{1,3}\\.\\d{2,})")

    /// iPhone videos keep where they were taken as text, such as `+20.6597-103.3496+1550.000/`.
    static func iso6709(in bytes: [UInt8]) -> (latitude: Double, longitude: Double)? {
        guard let text = String(bytes: bytes, encoding: .isoLatin1) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in iso6709Expression.matches(in: text, range: range) {
            guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
                  let latitude = Double(text[a]), let longitude = Double(text[b]), valid(latitude, longitude) else { continue }
            return (latitude, longitude)
        }
        return nil
    }

    /// Areas of about 11 km, each named once («Guadalajara, Jalisco, México»).
    static func areaKey(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.1f,%.1f", (latitude * 10).rounded() / 10, (longitude * 10).rounded() / 10)
    }

    static func areaCenter(_ key: String) -> (latitude: Double, longitude: Double)? {
        let parts = key.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    struct Point: Sendable {
        let id: String
        let latitude: Double
        let longitude: Double
        let date: Date
    }

    struct Cluster: Identifiable, Hashable, Sendable {
        let id: String
        let latitude: Double
        let longitude: Double
        /// Newest first.
        let ids: [String]
        static func == (a: Cluster, b: Cluster) -> Bool { a.id == b.id && a.ids.count == b.ids.count }
        func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(ids.count) }
    }

    /// The points inside the visible area (and a margin around it) grouped on a grid of
    /// about 7 × 5 cells, so the map never draws more than a few dozen pins.
    static func clusters(_ points: [Point], centerLatitude: Double, centerLongitude: Double, spanLatitude: Double, spanLongitude: Double) -> [Cluster] {
        let spanLat = max(spanLatitude, 0.0005), spanLon = max(spanLongitude, 0.0005)
        let cellLat = spanLat / 7, cellLon = spanLon / 5
        let minLat = centerLatitude - spanLat, maxLat = centerLatitude + spanLat
        let minLon = centerLongitude - spanLon, maxLon = centerLongitude + spanLon
        struct Cell: Hashable { let x: Int; let y: Int }
        var buckets: [Cell: (lat: Double, lon: Double, points: [Point])] = [:]
        for point in points where point.latitude >= minLat && point.latitude <= maxLat && point.longitude >= minLon && point.longitude <= maxLon {
            let cell = Cell(x: Int((point.longitude / cellLon).rounded(.down)), y: Int((point.latitude / cellLat).rounded(.down)))
            var bucket = buckets[cell] ?? (0, 0, [])
            bucket.lat += point.latitude; bucket.lon += point.longitude; bucket.points.append(point)
            buckets[cell] = bucket
        }
        return buckets.map { cell, bucket in
            let sorted = bucket.points.sorted { $0.date > $1.date }
            return Cluster(id: "\(cell.x):\(cell.y):\(sorted[0].id)", latitude: bucket.lat / Double(sorted.count), longitude: bucket.lon / Double(sorted.count),
                           ids: sorted.map(\.id))
        }
        .sorted { $0.ids.count > $1.ids.count }
    }

    /// The area that holds most of the photos, leaving out a few far away ones, to open the
    /// map where your photos are.
    static func mainArea(_ points: [Point]) -> (centerLatitude: Double, centerLongitude: Double, spanLatitude: Double, spanLongitude: Double)? {
        guard !points.isEmpty else { return nil }
        let lats = points.map(\.latitude).sorted(), lons = points.map(\.longitude).sorted()
        let low = Int(Double(points.count) * 0.05), high = max(low, Int(Double(points.count) * 0.95) - 1)
        let (a, b, c, d) = (lats[low], lats[high], lons[low], lons[high])
        return ((a + b) / 2, (c + d) / 2, max((b - a) * 1.3, 0.05), max((d - c) * 1.3, 0.05))
    }
}
