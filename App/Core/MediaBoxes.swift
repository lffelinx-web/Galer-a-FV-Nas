import Foundation

/// Just enough of the ISO media file format (HEIC photos, MOV and MP4 videos) and of TIFF
/// (EXIF) to find a capture date with a few small reads instead of downloading megabytes.
enum MediaBoxes {
    struct Box {
        let type: String
        let start: Int
        let headerSize: Int
        /// Total size as declared; it can reach beyond the bytes at hand.
        let size: UInt64
        var payload: Int { start + headerSize }
        var end: Int { size > UInt64(Int.max / 2) ? Int.max / 2 : start + Int(size) }
    }

    static func uint(_ bytes: [UInt8], _ at: Int, _ count: Int, little: Bool = false) -> UInt64? {
        guard at >= 0, count > 0, at + count <= bytes.count else { return nil }
        let slice = bytes[at..<(at + count)]
        return (little ? Array(slice.reversed()) : Array(slice)).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// The boxes one after another between `start` and `end`.
    static func boxes(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil) -> [Box] {
        let limit = min(end ?? bytes.count, bytes.count)
        var result: [Box] = []
        var at = start
        while at + 8 <= limit, result.count < 512 {
            guard var size = uint(bytes, at, 4) else { break }
            let type = String(bytes: bytes[(at + 4)..<(at + 8)], encoding: .isoLatin1) ?? ""
            var header = 8
            if size == 1 {
                guard let large = uint(bytes, at + 8, 8) else { break }
                size = large
                header = 16
            } else if size == 0 {
                size = UInt64(limit - at)
            }
            guard size >= UInt64(header) else { break }
            let box = Box(type: type, start: at, headerSize: header, size: size)
            result.append(box)
            if box.end >= limit { break }
            at = box.end
        }
        return result
    }

    // MARK: Videos

    /// Where the next top-level box begins after the ones that start inside `head`: after a
    /// large `mdat`, that is usually the `moov` box with the date.
    static func nextTopLevelOffset(_ head: [UInt8], base: UInt64 = 0) -> UInt64? {
        guard let last = boxes(head).last else { return nil }
        return base + UInt64(last.start) + last.size
    }

    static func topType(_ bytes: [UInt8]) -> String? { boxes(bytes).first?.type }

    // MARK: HEIC

    /// Where the EXIF block of a HEIC photo is in the file, from the `meta` box at its start.
    static func heifExifLocation(_ head: [UInt8]) -> (offset: UInt64, length: UInt64)? {
        guard let meta = boxes(head).first(where: { $0.type == "meta" }) else { return nil }
        let children = boxes(head, from: meta.payload + 4, to: meta.end)
        guard let iinf = children.first(where: { $0.type == "iinf" }), let iloc = children.first(where: { $0.type == "iloc" }),
              let exifID = exifItemID(head, iinf) else { return nil }
        return location(of: exifID, head, iloc, idat: children.first(where: { $0.type == "idat" }))
    }

    private static func exifItemID(_ bytes: [UInt8], _ iinf: Box) -> UInt64? {
        guard let version = bytes[safe: iinf.payload] else { return nil }
        let entries = iinf.payload + 4 + (version == 0 ? 2 : 4)
        for infe in boxes(bytes, from: entries, to: iinf.end) where infe.type == "infe" {
            let v = bytes[safe: infe.payload] ?? 0
            guard v >= 2 else { continue }
            let idSize = v == 2 ? 2 : 4
            guard let id = uint(bytes, infe.payload + 4, idSize) else { continue }
            let typeAt = infe.payload + 4 + idSize + 2
            guard typeAt + 4 <= bytes.count else { continue }
            if String(bytes: bytes[typeAt..<(typeAt + 4)], encoding: .isoLatin1) == "Exif" { return id }
        }
        return nil
    }

    private static func location(of item: UInt64, _ bytes: [UInt8], _ iloc: Box, idat: Box?) -> (offset: UInt64, length: UInt64)? {
        var at = iloc.payload
        guard let version = bytes[safe: at], let sizes = bytes[safe: at + 4], let more = bytes[safe: at + 5] else { return nil }
        at += 6
        let offsetSize = Int(sizes >> 4), lengthSize = Int(sizes & 0x0F), baseSize = Int(more >> 4)
        let indexSize = (version == 1 || version == 2) ? Int(more & 0x0F) : 0
        let countSize = version < 2 ? 2 : 4
        guard let count = uint(bytes, at, countSize) else { return nil }
        at += countSize
        for _ in 0..<min(count, 4096) {
            guard let id = uint(bytes, at, countSize) else { return nil }
            at += countSize
            var method: UInt64 = 0
            if version == 1 || version == 2 { method = (uint(bytes, at, 2) ?? 0) & 0x0F; at += 2 }
            at += 2 // data reference index
            let base = baseSize > 0 ? (uint(bytes, at, baseSize) ?? 0) : 0
            at += baseSize
            guard let extents = uint(bytes, at, 2) else { return nil }
            at += 2
            var first: (UInt64, UInt64)?
            for _ in 0..<min(extents, 64) {
                at += indexSize
                let offset = offsetSize > 0 ? (uint(bytes, at, offsetSize) ?? 0) : 0
                at += offsetSize
                let length = lengthSize > 0 ? (uint(bytes, at, lengthSize) ?? 0) : 0
                at += lengthSize
                if first == nil { first = (offset, length) }
            }
            guard id == item, let (offset, length) = first, length > 0 else { continue }
            if method == 1, let idat { return (UInt64(idat.payload) + base + offset, length) }
            return method == 0 ? (base + offset, length) : nil
        }
        return nil
    }

    /// Width and height of the main image (the largest `ispe`), turned by `irot`.
    static func heifSize(_ head: [UInt8]) -> (width: Int, height: Int)? {
        guard let meta = boxes(head).first(where: { $0.type == "meta" }),
              let iprp = boxes(head, from: meta.payload + 4, to: meta.end).first(where: { $0.type == "iprp" }),
              let ipco = boxes(head, from: iprp.payload, to: iprp.end).first(where: { $0.type == "ipco" }) else { return nil }
        var best: (Int, Int)?
        var rotated = false
        for property in boxes(head, from: ipco.payload, to: ipco.end) {
            if property.type == "ispe", let w = uint(head, property.payload + 4, 4), let h = uint(head, property.payload + 8, 4) {
                if best == nil || Int(w * h) > best!.0 * best!.1 { best = (Int(w), Int(h)) }
            } else if property.type == "irot", let angle = head[safe: property.payload] {
                rotated = (angle & 0x03) % 2 == 1
            }
        }
        guard let (w, h) = best, w > 0, h > 0 else { return nil }
        return rotated ? (h, w) : (w, h)
    }

    // MARK: EXIF

    /// DateTimeOriginal and its offset from an EXIF block (a HEIC Exif item starts with a
    /// 4-byte offset to the TIFF header).
    static func exifDate(heifItem bytes: [UInt8]) -> (date: String, offset: String?)? {
        guard let skip = uint(bytes, 0, 4), Int(skip) + 4 < bytes.count else { return nil }
        return exifDate(tiff: Array(bytes[(4 + Int(skip))...]))
    }

    static func exifDate(tiff bytes: [UInt8]) -> (date: String, offset: String?)? {
        guard bytes.count >= 8 else { return nil }
        let little: Bool
        if bytes[0] == 0x49 && bytes[1] == 0x49 { little = true } else if bytes[0] == 0x4D && bytes[1] == 0x4D { little = false } else { return nil }
        func u16(_ at: Int) -> Int? { uint(bytes, at, 2, little: little).map(Int.init) }
        func u32(_ at: Int) -> Int? { uint(bytes, at, 4, little: little).map(Int.init) }
        func entries(_ ifd: Int) -> [Int: (type: Int, count: Int, value: Int)] {
            guard let count = u16(ifd), count < 512 else { return [:] }
            var result: [Int: (type: Int, count: Int, value: Int)] = [:]
            for index in 0..<count {
                let at = ifd + 2 + index * 12
                guard let tag = u16(at), let type = u16(at + 2), let n = u32(at + 4), let value = u32(at + 8) else { break }
                result[tag] = (type, n, value)
            }
            return result
        }
        func text(_ entry: (type: Int, count: Int, value: Int)?) -> String? {
            guard let entry, entry.type == 2, entry.count > 0 else { return nil }
            let start = entry.count <= 4 ? -1 : entry.value
            guard start >= 0, start + entry.count <= bytes.count else { return nil }
            let raw = bytes[start..<(start + entry.count)].prefix { $0 != 0 }
            return String(bytes: raw, encoding: .ascii)
        }
        guard let ifd0 = u32(4) else { return nil }
        let main = entries(ifd0)
        var date: String?, offset: String?
        if let pointer = main[0x8769]?.value {
            let exif = entries(pointer)
            date = text(exif[0x9003]) ?? text(exif[0x9004])
            offset = text(exif[0x9011])
        }
        guard let found = date ?? text(main[0x0132]) else { return nil }
        return (found, offset)
    }
}

extension Array where Element == UInt8 {
    subscript(safe index: Int) -> UInt8? { indices.contains(index) ? self[index] : nil }
}
