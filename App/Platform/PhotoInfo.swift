import Foundation
import ImageIO
import Photos
import CoreLocation
import AVFoundation

/// What the info panel shows about one photo or video.
struct PhotoInfo: Equatable {
    var fileName: String?
    var bytes: Int64?
    var width: Int?
    var height: Int?
    var format: String?
    var camera: String?
    var lens: String?
    /// «ƒ/1.8 · 1/120 s · ISO 100 · 26 mm».
    var exposure: String?
    var location: CLLocationCoordinate2D?
    /// Videos: «HEVC · 30 fps».
    var video: String?

    static func == (lhs: PhotoInfo, rhs: PhotoInfo) -> Bool {
        lhs.fileName == rhs.fileName && lhs.bytes == rhs.bytes && lhs.width == rhs.width && lhs.camera == rhs.camera
            && lhs.location?.latitude == rhs.location?.latitude && lhs.location?.longitude == rhs.location?.longitude
    }

    var resolution: String? {
        guard let width, let height else { return nil }
        let megapixels = Double(width * height) / 1_000_000
        return "\(width) × \(height)" + (megapixels >= 1 ? String(format: " · %.0f MP", megapixels) : "")
    }

    /// Reads the metadata: PhotoKit and the image data for iPhone items, the first bytes of
    /// the file for NAS items.
    @MainActor
    static func load(_ item: GalleryItem, account: NASAccount?) async -> PhotoInfo {
        var info = PhotoInfo()
        switch item.source {
        case .phone(let id):
            guard let asset = PhoneLibrary.shared.asset(id) else { return info }
            info.width = asset.pixelWidth
            info.height = asset.pixelHeight
            info.location = asset.location?.coordinate
            if let resource = PHAssetResource.assetResources(for: asset).first {
                info.fileName = resource.originalFilename
                info.format = (resource.originalFilename as NSString).pathExtension.uppercased()
            }
            if asset.mediaType == .image, let data = await imageData(asset) {
                info.bytes = Int64(data.count)
                info.apply(properties(data))
                if info.location == nil { info.location = asset.location?.coordinate }
            } else if asset.mediaType == .video, let movie = await videoAsset(asset) {
                await info.applyVideo(movie)
            }
        case .nas(let url):
            info.fileName = item.name
            info.bytes = item.bytes
            info.format = url.pathExtension.uppercased()
            guard let account else { return info }
            if item.kind == .video {
                if MediaFormat.playable.contains(item.fileExtension),
                   let stream = try? await StreamServer.shared.url(for: StreamFile(url: url, bytes: item.bytes), account: account) {
                    await info.applyVideo(AVURLAsset(url: stream))
                }
                return info
            }
            let transport = NASTransport(account)
            if let head = try? await transport.range(url, start: 0, count: 524_288, prefix: true).data {
                info.apply(properties(head))
            }
            // Some files (WebP, PNG from apps) keep their size only in the image itself: read
            // the whole file when it is small.
            if info.width == nil, (item.bytes ?? .max) <= 20_000_000,
               let whole = try? await transport.request(url, limit: 20_000_000).data {
                info.apply(properties(whole))
            }
        }
        return info
    }

    private static func imageData(_ asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .original
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private static func videoAsset(_ asset: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { movie, _, _ in continuation.resume(returning: movie) }
        }
    }

    /// Size, frame rate and codec of the video track.
    mutating func applyVideo(_ asset: AVAsset) async {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions) else { return }
        let (size, transform, rate, formats) = loaded
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        width = Int(abs(shown.width).rounded())
        height = Int(abs(shown.height).rounded())
        var parts: [String] = []
        if let format = formats.first { parts.append(Self.codecName(CMFormatDescriptionGetMediaSubType(format))) }
        if rate > 0 { parts.append("\(Int(rate.rounded())) fps") }
        if !parts.isEmpty { video = parts.joined(separator: " · ") }
    }

    static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProResRAW: return "ProRes"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
            return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces).uppercased() ?? "Video"
        }
    }

    /// «Guadalajara, México» for the viewer's title, quickly: iPhone photos carry their
    /// place; NAS photos only once their information was opened.
    @MainActor
    static func quickPlace(_ item: GalleryItem) async -> String? {
        if let known = PlaceCache.byItem[item.id] { return known }
        guard case .phone(let id) = item.source, let coordinate = PhoneLibrary.shared.asset(id)?.location?.coordinate else { return nil }
        let name = await placeName(coordinate)
        PlaceCache.byItem[item.id] = name
        return name
    }

    mutating func apply(_ properties: [CFString: Any]) {
        if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            (self.width, self.height) = (5...8).contains(orientation) ? (height, width) : (width, height)
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) {
            // «Apple iPhone 15 Pro» reads better as «iPhone 15 Pro».
            camera = make.map { model.lowercased().hasPrefix($0.lowercased()) ? model : "\($0) \(model)" } ?? model
            if camera?.hasPrefix("Apple ") == true { camera = String(camera!.dropFirst(6)) }
        }
        lens = (exif?[kCGImagePropertyExifLensModel] as? String).map(PhotoInfo.shortLens)
        var parts: [String] = []
        if let number = exif?[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "ƒ/%.1f", number)) }
        if let time = exif?[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            parts.append(time >= 1 ? String(format: "%.0f s", time) : "1/\(Int((1 / time).rounded())) s")
        }
        if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
        if let focal = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int ?? (exif?[kCGImagePropertyExifFocalLength] as? Double).map({ Int($0.rounded()) }) {
            parts.append("\(focal) mm")
        }
        if !parts.isEmpty { exposure = parts.joined(separator: " · ") }
        if location == nil, var latitude = gps?[kCGImagePropertyGPSLatitude] as? Double, var longitude = gps?[kCGImagePropertyGPSLongitude] as? Double {
            if (gps?[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
            if (gps?[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
            if latitude != 0 || longitude != 0 { location = CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        }
    }

    /// «iPhone 15 Pro back triple camera 6.86mm f/1.78» → «Cámara trasera · 6.86 mm ƒ/1.78».
    static func shortLens(_ text: String) -> String {
        guard text.lowercased().contains("camera") else { return text }
        let side = text.lowercased().contains("front") ? "Cámara frontal" : "Cámara trasera"
        let detail = text.components(separatedBy: " ").filter { $0.hasSuffix("mm") || $0.hasPrefix("f/") }
            .map { $0.hasPrefix("f/") ? "ƒ/" + String($0.dropFirst(2)) : $0.replacingOccurrences(of: "mm", with: " mm") }
        return ([side] + detail).joined(separator: " · ")
    }

    /// «Puebla, México». Nearby photos share one lookup, since Apple limits how many are allowed.
    @MainActor
    static func placeName(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let key = String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
        if let known = PlaceCache.byArea[key] { return known }
        let name = await lookUpPlace(coordinate)
        if let name { PlaceCache.byArea[key] = name }
        return name
    }

    private static func lookUpPlace(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                                                       preferredLocale: Locale(identifier: "es_MX"))
        guard let place = placemarks?.first else { return nil }
        return [place.subLocality ?? place.locality, place.locality == place.subLocality ? nil : place.locality, place.country]
            .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
    }
}

/// Places already looked up, by photo and by area.
@MainActor
enum PlaceCache {
    static var byItem: [String: String] = [:]
    static var byArea: [String: String] = [:]
}
