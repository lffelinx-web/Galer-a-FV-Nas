import Foundation
import ImageIO

/// What the file itself says about a NAS photo or video: when it was taken and its shape.
struct CaptureInfo: Codable, Equatable {
    var date: Date?
    var aspect: Double?
    var duration: Double?
    var latitude: Double?
    var longitude: Double?
    /// The file was also checked for a location (older reads only looked for the date).
    var geo: Bool?
}

/// Reads the capture date from the first bytes of each file, so the NAS can be ordered by
/// when photos were taken instead of when they were copied. Photos keep it in EXIF near
/// the start; videos keep it in the `mvhd` box, at the start or at the end of the file.
enum CaptureReader {
    static let headBytes = 65_536
    static let moreBytes = 2_097_152

    /// Nil when the NAS could not be reached, so the file is tried again later.
    static func read(_ item: GalleryItem, transport: NASTransport) async -> CaptureInfo? {
        guard var info = await readFile(item, transport: transport) else { return nil }
        info.geo = true
        if let lat = info.latitude, let lon = info.longitude, !GeoPlace.valid(lat, lon) { info.latitude = nil; info.longitude = nil }
        return info
    }

    private static func readFile(_ item: GalleryItem, transport: NASTransport) async -> CaptureInfo? {
        guard let url = item.nasURL else { return nil }
        do {
            let head = try await transport.range(url, start: 0, count: headBytes, prefix: true).data
            if item.kind == .video {
                if let info = movie(head) { return info }
                // Usually the date is in the `moov` box after the video data: jump to it.
                let bytes = [UInt8](head)
                var next = MediaBoxes.nextTopLevelOffset(bytes)
                var hops = 0
                while let offset = next, hops < 3, offset + 8 < UInt64(item.bytes ?? Int64.max) {
                    hops += 1
                    let chunk = [UInt8](try await transport.range(url, start: Int64(offset), count: headBytes, prefix: true).data)
                    if MediaBoxes.topType(chunk) == "moov", let info = movie(Data(chunk)) { return info }
                    next = MediaBoxes.nextTopLevelOffset(chunk, base: offset)
                }
                if let size = item.bytes, size > Int64(headBytes) {
                    let start = max(Int64(0), size - Int64(moreBytes))
                    let tail = try await transport.range(url, start: start, count: Int(size - start), prefix: true).data
                    if let info = movie(tail) { return info }
                }
                return CaptureInfo()
            }
            if let info = image(head), info.date != nil { return info }
            // HEIC: the start says where the EXIF block is; read only that.
            let bytes = [UInt8](head)
            if let place = MediaBoxes.heifExifLocation(bytes), place.length > 8, place.length < 262_144 {
                let exif = [UInt8](try await transport.range(url, start: Int64(place.offset), count: Int(place.length), prefix: true).data)
                if let found = MediaBoxes.exifDate(heifItem: exif) {
                    var info = CaptureInfo(date: found.date.flatMap { exifDate($0, offset: found.offset) }, latitude: found.latitude, longitude: found.longitude)
                    if let size = MediaBoxes.heifSize(bytes) { info.aspect = Double(size.width) / Double(size.height) }
                    if info.date != nil { return info }
                }
            }
            // HEIC and RAW files can keep their metadata further in.
            if head.count >= headBytes, (item.bytes ?? Int64(moreBytes)) > Int64(headBytes) {
                let more = try await transport.range(url, start: 0, count: moreBytes, prefix: true).data
                if let info = image(more) { return info }
            }
            return image(head) ?? CaptureInfo()
        } catch {
            if error is CancellationError { return nil }
            // A file the NAS refuses still counts as read; a network failure does not.
            return (error as? GalleryError) != nil ? CaptureInfo() : nil
        }
    }

    // MARK: Photos

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
    private static let formatterLock = NSLock()

    static func image(_ data: Data) -> CaptureInfo? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var info = CaptureInfo()
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let text = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String
        if let text {
            let offset = (exif?[kCGImagePropertyExifOffsetTimeOriginal] ?? exif?[kCGImagePropertyExifOffsetTime]) as? String
            info.date = exifDate(text, offset: offset)
        }
        if let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            info.aspect = (5...8).contains(orientation) ? height / width : width / height
        }
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        if var latitude = gps?[kCGImagePropertyGPSLatitude] as? Double, var longitude = gps?[kCGImagePropertyGPSLongitude] as? Double {
            if (gps?[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
            if (gps?[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
            info.latitude = latitude; info.longitude = longitude
        }
        return info.date == nil && info.aspect == nil ? nil : info
    }

    /// `2023:05:14 10:15:30` with an optional `-06:00` offset; local time without it.
    static func exifDate(_ text: String, offset: String?, timeZone: TimeZone = .current) -> Date? {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        exifFormatter.timeZone = offset.flatMap(timeZoneFromOffset) ?? timeZone
        guard let date = exifFormatter.date(from: String(text.prefix(19))), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    static func timeZoneFromOffset(_ text: String) -> TimeZone? {
        let parts = text.trimmingCharacters(in: .whitespaces).dropFirst().split(separator: ":")
        guard let sign = text.trimmingCharacters(in: .whitespaces).first, sign == "+" || sign == "-",
              parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    // MARK: Videos

    /// Reads `mvhd` (creation time and duration) and the video track's `tkhd` (size and rotation).
    static func movie(_ data: Data) -> CaptureInfo? {
        let bytes = [UInt8](data)
        guard let mvhd = find("mvhd", in: bytes) else { return nil }
        var info = CaptureInfo()
        let version = bytes[safe: mvhd]
        let created: UInt64?, timescale: UInt64?, length: UInt64?
        if version == 1 {
            created = uint(bytes, mvhd + 4, 8); timescale = uint(bytes, mvhd + 20, 4); length = uint(bytes, mvhd + 24, 8)
        } else {
            created = uint(bytes, mvhd + 4, 4); timescale = uint(bytes, mvhd + 12, 4); length = uint(bytes, mvhd + 16, 4)
        }
        // Seconds since 1 January 1904, UTC.
        if let created, created > 2_082_844_800 {
            let date = Date(timeIntervalSince1970: TimeInterval(created) - 2_082_844_800)
            if date.timeIntervalSince1970 > 631_152_000 { info.date = date } // after 1990
        }
        if let timescale, let length, timescale > 0, length > 0 { info.duration = Double(length) / Double(timescale) }
        if let place = GeoPlace.iso6709(in: bytes) { info.latitude = place.latitude; info.longitude = place.longitude }
        var search = 0
        while let tkhd = find("tkhd", in: bytes, from: search) {
            search = tkhd
            let v1 = bytes[safe: tkhd] == 1
            let matrix = tkhd + (v1 ? 52 : 40)
            let sizeAt = tkhd + (v1 ? 88 : 76)
            if let width = uint(bytes, sizeAt, 4), let height = uint(bytes, sizeAt + 4, 4), width > 0, height > 0 {
                let a = uint(bytes, matrix, 4) ?? 0x10000
                let rotated = a == 0
                let w = Double(width) / 65536, h = Double(height) / 65536
                info.aspect = rotated ? h / w : w / h
                break
            }
        }
        return info
    }

    /// The position right after the 4-letter box type.
    private static func find(_ type: String, in bytes: [UInt8], from start: Int = 0) -> Int? {
        let pattern = Array(type.utf8)
        guard bytes.count >= pattern.count, start <= bytes.count - pattern.count else { return nil }
        var index = start
        while index <= bytes.count - pattern.count {
            if bytes[index] == pattern[0] && bytes[index + 1] == pattern[1] && bytes[index + 2] == pattern[2] && bytes[index + 3] == pattern[3] {
                return index + 4
            }
            index += 1
        }
        return nil
    }

    private static func uint(_ bytes: [UInt8], _ start: Int, _ count: Int) -> UInt64? {
        guard start >= 0, start + count <= bytes.count else { return nil }
        return bytes[start..<(start + count)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}


