import UIKit
import ImageIO
import AVFoundation

/// Limits how many NAS downloads run at once.
actor Gate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ count: Int) { available = count }
    func enter() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func leave() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Thumbnails and full images of NAS files. A thumbnail is made once, kept on disk as a
/// small JPEG and in memory. Synology's own thumbnails (`@eaDir/<file>/SYNOPHOTO_THUMB_XL.jpg`)
/// are tried first, so most photos never need the full file; if the NAS does not serve
/// them, the original is downloaded once to make the thumbnail.
actor NASImageLoader {
    static let shared = NASImageLoader()
    static let thumbnailPixels: CGFloat = 720

    private struct Running {
        let token: UUID
        let task: Task<UIImage?, Never>
        var users: Int
    }

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 160 * 1_048_576; return cache
    }()
    private let full: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 200 * 1_048_576; return cache
    }()
    private var running: [String: Running] = [:]
    private let gate = Gate(3)
    /// Per account: how Synology thumbnails went, so a NAS that hides `@eaDir` stops being asked.
    private var synologyHits: [String: (ok: Int, failed: Int)] = [:]
    /// Width/height learned while making thumbnails, read back by the store.
    private(set) var aspects: [String: Double] = [:]

    static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Miniaturas", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated func cached(_ url: URL) -> UIImage? { memory.object(forKey: url.absoluteString as NSString) }

    func takeAspects() -> [String: Double] {
        defer { aspects = [:] }
        return aspects
    }

    func thumbnail(_ item: GalleryItem, account: NASAccount) async -> UIImage? {
        guard let url = item.nasURL else { return nil }
        let key = url.absoluteString
        if let image = memory.object(forKey: key as NSString) { return image }
        let entry: Running
        if var existing = running[key] {
            existing.users += 1; running[key] = existing; entry = existing
        } else {
            let token = UUID()
            let task = Task<UIImage?, Never> { [gate] in
                let image = await Self.produceThumbnail(item, url: url, account: account, gate: gate, loader: self)
                await self.finished(key, token: token, image: image, id: item.id)
                return image
            }
            entry = Running(token: token, task: task, users: 1)
            running[key] = entry
        }
        return await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { await self.abandon(key, token: entry.token) }
        }
    }

    private func finished(_ key: String, token: UUID, image: UIImage?, id: String) {
        if running[key]?.token == token { running[key] = nil }
        guard let image else { return }
        memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        if image.size.height > 0 { aspects[id] = Double(image.size.width / image.size.height) }
    }

    /// A tile scrolled away: when nobody else waits for this thumbnail, stop downloading it.
    private func abandon(_ key: String, token: UUID) {
        guard var entry = running[key], entry.token == token else { return }
        entry.users -= 1
        if entry.users <= 0 { entry.task.cancel(); running[key] = nil } else { running[key] = entry }
    }

    fileprivate func synologyAllowed(_ scope: String) -> Bool {
        guard let stats = synologyHits[scope] else { return true }
        return stats.ok > 0 || stats.failed < 6
    }

    fileprivate func synologyResult(_ scope: String, ok: Bool) {
        var stats = synologyHits[scope] ?? (0, 0)
        if ok { stats.ok += 1 } else { stats.failed += 1 }
        synologyHits[scope] = stats
    }

    private static func diskFile(_ url: URL) -> URL { folder.appendingPathComponent(Files.key(url.absoluteString) + ".jpg") }

    static func synologyThumbnailURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("@eaDir", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent, isDirectory: true)
            .appendingPathComponent("SYNOPHOTO_THUMB_XL.jpg")
    }

    private static func produceThumbnail(_ item: GalleryItem, url: URL, account: NASAccount, gate: Gate, loader: NASImageLoader) async -> UIImage? {
        let file = diskFile(url)
        if FileManager.default.fileExists(atPath: file.path) { return decode(file, maxPixels: thumbnailPixels) }
        await gate.enter()
        defer { Task { await gate.leave() } }
        guard !Task.isCancelled else { return nil }
        let transport = NASTransport(account)
        var data: Data?
        if await loader.synologyAllowed(account.scope) {
            data = try? await transport.request(synologyThumbnailURL(url), limit: 4_000_000).data
            if Task.isCancelled { return nil }
            let usable = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.map { CGImageSourceGetCount($0) > 0 } ?? false
            await loader.synologyResult(account.scope, ok: usable)
            if !usable { data = nil }
        }
        if data == nil, item.kind == .video, MediaFormat.playable.contains(item.fileExtension) {
            let local = videoFile(url)
            if FileManager.default.fileExists(atPath: local.path) { return await videoFrame(local) }
            return nil
        }
        if data == nil, item.kind != .video {
            data = try? await transport.request(url, limit: 150_000_000).data
        }
        guard !Task.isCancelled, let data, let image = decode(data, maxPixels: thumbnailPixels) else { return nil }
        if let jpeg = image.jpegData(compressionQuality: 0.82) { try? jpeg.write(to: file, options: .atomic) }
        return image
    }

    /// The full photo, decoded no larger than `maxPixels` on its long side.
    func image(_ item: GalleryItem, account: NASAccount, maxPixels: CGFloat) async throws -> UIImage {
        guard let url = item.nasURL else { throw GalleryError.message("La foto no está en el NAS.") }
        let key = url.absoluteString as NSString
        if let image = full.object(forKey: key) { return image }
        await gate.enter()
        let data: Data
        do { data = try await NASTransport(account).request(url, limit: 200_000_000).data; await gate.leave() }
        catch { await gate.leave(); throw error }
        guard let image = Self.decode(data, maxPixels: maxPixels) else { throw GalleryError.message("iOS no puede abrir este formato de imagen.") }
        full.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    static func decode(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source, maxPixels: maxPixels)
    }

    static func decode(_ file: URL, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return decode(source, maxPixels: maxPixels)
    }

    private static func decode(_ source: CGImageSource, maxPixels: CGFloat) -> UIImage? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    // MARK: Videos

    static let videoFolder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("VideosNAS", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func videoFile(_ url: URL) -> URL {
        videoFolder.appendingPathComponent(Files.key(url.absoluteString)).appendingPathExtension(url.pathExtension.lowercased())
    }

    static func videoFrame(_ file: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailPixels, height: thumbnailPixels)
        guard let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: frame.image)
    }

    // MARK: Cache

    static func cacheSize() -> Int64 {
        [folder, videoFolder].reduce(0) { total, url in
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return total + files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
    }

    func clear() {
        memory.removeAllObjects(); full.removeAllObjects()
        for url in [Self.folder, Self.videoFolder] {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
