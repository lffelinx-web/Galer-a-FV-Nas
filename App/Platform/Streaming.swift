import Foundation
import Network

/// A NAS video for the players: its address and, when known, its size.
struct StreamFile: Hashable {
    var url: URL
    var bytes: Int64?
}

enum MediaType {
    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "3gp": return "video/3gpp"
        case "wmv": return "video/x-ms-wmv"
        case "mpg", "mpeg": return "video/mpeg"
        default: return "application/octet-stream"
        }
    }
}

/// A parsed `Range: bytes=…` header, resolved against the file length (both ends inclusive).
struct ByteRange: Equatable {
    var start: Int64
    var end: Int64
    var count: Int64 { end - start + 1 }

    /// `nil` means the range can't be satisfied (416); a missing or malformed header means the whole file.
    static func parse(_ header: String?, total: Int64) -> ByteRange? {
        guard total > 0 else { return nil }
        let whole = ByteRange(start: 0, end: total - 1)
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes=") else { return whole }
        // Players ask for one range at a time; only the first of a list is honoured.
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return whole }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            return ByteRange(start: max(0, total - suffix), end: total - 1)
        }
        guard let start = Int64(parts[0]), start >= 0 else { return whole }
        guard start < total else { return nil }
        let end = parts[1].isEmpty ? total - 1 : min(Int64(parts[1]) ?? total - 1, total - 1)
        return end >= start ? ByteRange(start: start, end: end) : nil
    }
}

/// A loopback HTTP server that hands NAS videos to AVPlayer and VLC.
///
/// Neither player can use `NASTransport` (LAN/Tailscale IP with the HTTPS hostname
/// as SNI), so they read `http://127.0.0.1:<port>/v/<token>.<ext>` and this server
/// answers each byte range by fetching it from the NAS in blocks.
final class StreamServer: @unchecked Sendable {
    static let shared = StreamServer()

    /// Blocks requested ahead of the one being written to the player.
    static let prefetch = 3

    private let queue = DispatchQueue(label: "lfaz.galeria.stream")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var items: [String: (file: StreamFile, account: NASAccount)] = [:]

    func url(for file: StreamFile, account: NASAccount) async throws -> URL {
        let port = try await start()
        let token = UUID().uuidString
        lock.withLock { items[token] = (file, account) }
        let ext = file.url.pathExtension.lowercased()
        return URL(string: "http://127.0.0.1:\(port)/v/\(token)" + (ext.isEmpty ? "" : ".\(ext)"))!
    }

    private func start() async throws -> UInt16 {
        if let current = lock.withLock({ self.listener != nil && self.port != 0 ? self.port : nil }) { return current }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume(returning: listener?.port?.rawValue ?? 0) }
                case .failed(let error):
                    self?.reset()
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                case .cancelled:
                    self?.reset()
                    if !resumed { resumed = true; continuation.resume(throwing: GalleryError.message("No se pudo iniciar el reproductor.")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener; self.port = port }
        return port
    }

    /// iOS may close the socket in the background; the next request starts a new listener.
    private func reset() { lock.withLock { listener = nil; port = 0 } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { await self.handle(connection); connection.cancel() }
    }

    private func handle(_ connection: NWConnection) async {
        guard let head = try? await receiveHead(connection),
              let lines = String(data: head, encoding: .isoLatin1)?.components(separatedBy: "\r\n"),
              let first = lines.first?.split(separator: " "), first.count >= 2 else { return }
        let method = String(first[0]), path = String(first[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let token = ((path.split(separator: "/").last.map(String.init) ?? "") as NSString).deletingPathExtension
        guard ["GET", "HEAD"].contains(method), let item = lock.withLock({ items[token] }) else {
            try? await send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
        }
        do {
            let cache = BlockCache.shared, file = item.file, account = item.account
            let total = try await cache.length(file, account: account)
            let mime = MediaType.mime(file.url.pathExtension)
            guard let range = ByteRange.parse(headers["range"], total: total) else {
                try await send(connection, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
            }
            let partial = headers["range"] != nil
            var response = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            response += "Content-Type: \(mime)\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.count)\r\nConnection: close\r\n"
            if partial { response += "Content-Range: bytes \(range.start)-\(range.end)/\(total)\r\n" }
            try await send(connection, Data((response + "\r\n").utf8))
            guard method == "GET" else { return }

            // Whole aligned blocks come from BlockCache (disk or NAS); keep the next ones
            // in flight so each NAS round trip overlaps with writing to the player.
            let size = Int64(BlockCache.blockSize)
            let first = range.start / size, last = range.end / size
            var next = first
            var pending: [(index: Int64, task: Task<Data, Error>)] = []
            func schedule() {
                while pending.count < Self.prefetch && next <= last {
                    let index = next
                    pending.append((index, Task { try await cache.block(index, of: file, account: account) }))
                    next += 1
                }
            }
            defer { pending.forEach { $0.task.cancel() } }
            schedule()
            while !pending.isEmpty {
                let (index, task) = pending.removeFirst()
                let data = try await task.value
                guard !data.isEmpty else { return }
                schedule()
                let blockStart = index * size
                let from = Int(max(range.start, blockStart) - blockStart)
                let to = Int(min(range.end + 1, blockStart + Int64(data.count)) - blockStart)
                guard from < to else { return }
                try await send(connection, data.subdata(in: from..<to))
            }
        } catch {
            // The player closed the connection (seek or stop) or the NAS failed; the player retries with a new range.
        }
    }

    private func receiveHead(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard buffer.count < 16_384 else { throw GalleryError.message("Solicitud demasiado grande.") }
            let (data, complete): (Data, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data ?? Data(), complete)) }
                }
            }
            buffer.append(data)
            if complete && buffer.range(of: Data("\r\n\r\n".utf8)) == nil { throw GalleryError.message("Solicitud incompleta.") }
        }
        return buffer
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}


/// Video bytes in aligned 1 MB blocks: from a finished download, from the temporary cache,
/// or from the NAS (and then kept in the cache). Rewinding replays from disk.
actor BlockCache {
    static let shared = BlockCache()
    static let blockSize = 1_048_576

    private var limit: Int64 = 1_024 * 1_048_576
    private var lengths: [String: Int64] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var writesSinceTrim = 0

    nonisolated static func key(_ file: StreamFile) -> String { Files.key(file.url.absoluteString) }

    nonisolated static var cacheFolder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A video already saved whole on the phone by an earlier version.
    nonisolated static func downloaded(_ file: StreamFile) -> URL? {
        let url = NASImageLoader.videoFile(file.url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func configure(megabytes: Int) { limit = Int64(max(256, megabytes)) * 1_048_576; trim() }

    func length(_ file: StreamFile, account: NASAccount?) async throws -> Int64 {
        if let local = Self.downloaded(file), let size = try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize { return Int64(size) }
        let key = Self.key(file)
        if let known = lengths[key] { return known }
        guard let account else { throw GalleryError.message("Conecta el NAS para ver este video.") }
        let response = try await NASTransport(account).range(file.url, start: 0, count: 1, prefix: true)
        guard let total = response.totalLength ?? file.bytes, total > 0 else { throw GalleryError.message("No se pudo conocer el tamaño del video.") }
        lengths[key] = total
        return total
    }

    /// One aligned block; concurrent requests for the same block share a single NAS fetch.
    func block(_ index: Int64, of file: StreamFile, account: NASAccount?) async throws -> Data {
        let start = index * Int64(Self.blockSize)
        if let local = Self.downloaded(file) {
            let handle = try FileHandle(forReadingFrom: local); defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            return try handle.read(upToCount: Self.blockSize) ?? Data()
        }
        let key = Self.key(file)
        let path = Self.cacheFolder.appendingPathComponent("\(key)-\(index).blk")
        if let data = try? Data(contentsOf: path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
            return data
        }
        let taskKey = "\(key)-\(index)"
        if let running = inFlight[taskKey] { return try await running.value }
        let total = try await length(file, account: account)
        guard start < total else { return Data() }
        guard let account else { throw GalleryError.message("Esta parte del video no está guardada. Conecta el NAS.") }
        let count = Int(min(Int64(Self.blockSize), total - start))
        let task = Task { try await NASTransport(account).range(file.url, start: start, count: count).data }
        inFlight[taskKey] = task
        defer { inFlight[taskKey] = nil }
        let data = try await task.value
        guard data.count == count else { throw GalleryError.message("El bloque del video llegó incompleto.") }
        try? data.write(to: path, options: .atomic)
        writesSinceTrim += 1
        if writesSinceTrim >= 32 { writesSinceTrim = 0; trim() }
        return data
    }

    /// Whether every block of the file is already on the phone.
    func isComplete(_ file: StreamFile, account: NASAccount?) async -> Bool {
        if Self.downloaded(file) != nil { return true }
        guard let total = try? await length(file, account: account) else { return false }
        let key = Self.key(file), blocks = (total + Int64(Self.blockSize) - 1) / Int64(Self.blockSize)
        return (0..<blocks).allSatisfy { FileManager.default.fileExists(atPath: Self.cacheFolder.appendingPathComponent("\(key)-\($0).blk").path) }
    }

    /// Size of the temporary cache, in bytes.
    func cacheSize() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.cacheFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: Self.cacheFolder)
        _ = Self.cacheFolder
    }

    /// Oldest blocks go first once the cache passes its limit.
    private func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: Self.cacheFolder, includingPropertiesForKeys: keys) else { return }
        var entries = urls.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > limit {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { total -= entry.1 }
        }
    }
}
