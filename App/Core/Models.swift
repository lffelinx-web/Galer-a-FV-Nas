import Foundation

struct NASAccount: Codable, Equatable {
    var root: URL
    var username: String
    var password: String
    var routeIP: String
    var tailscaleHost: String?
    var connectionMode: NASConnectionMode?
    /// The name shown in the status pill, such as `DS120j`. Defaults to the first label of the domain.
    var displayName: String?
    /// HTTPS port of DSM, to read the free space. 5001 when not set.
    var dsmPort: Int?
    var dsmPortValue: Int { dsmPort ?? 5001 }
    var scope: String { root.absoluteString + "|" + username }
    var label: String {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return root.host?.split(separator: ".").first.map(String.init) ?? "NAS"
    }
}

enum MediaKind: String, Codable {
    case photo, video, livePhoto
}

enum MediaFormat {
    static let raw: Set<String> = ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "raw", "rwl", "3fr", "erf", "mrw", "x3f", "iiq", "mos", "kdc", "dcr"]
    static let images: Set<String> = Set(["jpg", "jpeg", "jpe", "jfif", "heic", "heif", "hif", "png", "gif", "webp", "tif", "tiff", "bmp", "avif", "jxl", "psd", "ico"]).union(raw)
    static let videos: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2", "avi", "mkv", "webm", "mts", "m2ts", "ts", "wmv", "mpg", "mpeg", "flv", "hevc"]
    /// Videos AVPlayer can open directly.
    static let playable: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2"]

    static func kind(ofExtension ext: String) -> MediaKind? {
        let ext = ext.lowercased()
        if images.contains(ext) { return .photo }
        if videos.contains(ext) { return .video }
        return nil
    }
}

enum MediaSource: Hashable, Codable {
    /// A `PHAsset` local identifier.
    case phone(String)
    case nas(URL)
}

struct GalleryItem: Identifiable, Hashable, Codable {
    var id: String
    var source: MediaSource
    var date: Date
    var kind: MediaKind
    /// Width divided by height; 1 until it is known.
    var aspect: Double
    var duration: Double?
    var name: String
    var bytes: Int64?
    /// For NAS files, the folder relative to the shared root, such as `2023/Vacaciones`.
    var folder: String?
    var favorite = false
    /// Set for iPhone screenshots; NAS files are recognized by name.
    var screenshot: Bool?
    /// A NAS file whose date on the NAS matches its folder: the moment it was taken.
    var exactDate: Bool?

    var isVideo: Bool { kind == .video }
    var isNAS: Bool { if case .nas = source { return true } else { return false } }
    var nasURL: URL? { if case .nas(let url) = source { return url } else { return nil } }
    var phoneID: String? { if case .phone(let id) = source { return id } else { return nil } }
    var fileExtension: String { nasURL?.pathExtension.lowercased() ?? "" }
    var isRAW: Bool { MediaFormat.raw.contains(fileExtension) }
    var isScreenshot: Bool {
        if let screenshot { return screenshot }
        let lower = name.lowercased()
        return lower.contains("screenshot") || lower.contains("screen shot") || lower.contains("captura de pantalla")
    }
}

struct NASIndex: Codable {
    var items: [GalleryItem] = []
    var scanned: Date?
    /// Ids that were new in that search.
    var added: [String]?
    /// Each folder as it was, so the next search can skip the unchanged ones.
    var folders: [String: CachedFolder]?
    /// 2: dates from the NAS file when the folder agrees. Older indexes are searched again in full.
    var version: Int?
}

enum GalleryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func countText(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count.formatted()) \(count == 1 ? singular : plural)"
}

func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
}

func mediaSummary(_ items: [GalleryItem]) -> String {
    let videos = items.filter(\.isVideo).count
    let photos = items.count - videos
    var parts: [String] = []
    if photos > 0 || videos == 0 { parts.append(countText(photos, "foto", "fotos")) }
    if videos > 0 { parts.append(countText(videos, "video", "videos")) }
    return parts.joined(separator: " · ")
}

/// An album made in the app. It can mix photos from the iPhone and the NAS; it lives only
/// in the app, so the iPhone library and the NAS are never changed.
struct AppAlbum: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var created: Date
    /// Item ids, most recently added first.
    var items: [String]
}
