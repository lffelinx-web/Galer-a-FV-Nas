import Foundation

import Network

import Security

struct NASResponse {

    var route: String? = nil
    let status: Int

    let headers: [String: String]

    let data: Data

    var totalLength: Int64? {

        if let range = headers["content-range"], let tail = range.split(separator: "/").last, let total = Int64(tail) { return total }

        return headers["content-length"].flatMap(Int64.init)

    }

}

/// Connects to an optional LAN/Tailscale IP while preserving the HTTPS hostname,

/// SNI and the system trust chain. Each bounded range uses its own connection.

final class NASTransport: @unchecked Sendable {

    let account: NASAccount

    init(_ account: NASAccount) { self.account = account }

    /// `bodyFile` sends a file from disk as the body, a piece at a time (the backup). Statuses
    /// in `accept` come back as a response instead of an error, without their body.
    func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data = Data(), bodyFile: URL? = nil,
                 accept: Set<Int> = [], limit: Int = 2_000_000, allowPrefix: Bool = false) async throws -> NASResponse {

        try await NASRouteFallback.perform(account: account) { route in
            var response = try await requestOnRoute(url, route: route, method: method, headers: headers, body: body, bodyFile: bodyFile, accept: accept,
                                                    limit: limit, allowPrefix: allowPrefix)
            response.route = route
            NotificationCenter.default.post(name: .nasRequestSucceeded, object: nil, userInfo: ["scope": account.scope])
            return response
        }
    }

    /// Tries a connection kept open from an earlier request first; a stale one (closed by
    /// the NAS while idle) is replaced by a new connection once.
    private func requestOnRoute(_ url: URL, route: String, method: String, headers: [String: String], body: Data, bodyFile: URL?, accept: Set<Int>,
                                limit: Int, allowPrefix: Bool) async throws -> NASResponse {
        let dsm = URLPolicy.allowedDSM(url, account: account)
        // Writing is only allowed inside the backup folder, and a move only to a name there
        // that does not exist yet (`Overwrite: F`).
        let backupWrite = ["PUT", "MKCOL", "MOVE"].contains(method) && URLPolicy.allowedBackup(url, root: account.root)
            && (method != "MOVE" || (headers["Overwrite"] == "F" && headers["Destination"].flatMap { URL(string: $0) }.map { URLPolicy.allowedBackup($0, root: account.root) } == true))
        guard (URLPolicy.allowed(url, root: account.root) && ["GET", "PROPFIND"].contains(method)) || (dsm && ["GET", "POST"].contains(method)) || backupWrite,
              NASAccount.validRoute(route), !account.username.contains(":"),
              let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else {
            throw GalleryError.message("La solicitud está fuera de la carpeta autorizada.")
        }
        let key = "\(route)|\(host)|\(port.rawValue)"
        if let pooled = NASConnectionPool.shared.take(key) {
            do {
                return try await exchange(url, pooled: pooled, key: key, host: host, port: port, route: route, method: method, headers: headers, body: body,
                                          bodyFile: bodyFile, accept: accept, limit: limit, allowPrefix: allowPrefix, dsm: dsm)
            } catch let error as URLError where error.code == .networkConnectionLost {
                // The NAS closed it while it waited; continue with a fresh one.
            } catch let error as NWError {
                _ = error
            }
        }
        return try await exchange(url, pooled: nil, key: key, host: host, port: port, route: route, method: method, headers: headers, body: body,
                                  bodyFile: bodyFile, accept: accept, limit: limit, allowPrefix: allowPrefix, dsm: dsm)
    }

    private func connect(host: String, port: NWEndpoint.Port, route: String) async throws -> PooledConnection {
        let tls = NWProtocolTLS.Options()
        host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, host as CFString)
            guard SecTrustSetPolicies(value, policy) == errSecSuccess else { complete(false); return }
            complete(SecTrustEvaluateWithError(value, nil))
        }, DispatchQueue.global(qos: .userInitiated))
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(route.isEmpty ? host : route), port: port, using: parameters)
        let queue = DispatchQueue(label: "lfaz.galeria.https.\(UUID().uuidString)")
        let connectTimeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 6, execute: connectTimeout)
        defer { connectTimeout.cancel() }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: connection.stateUpdateHandler = nil; continuation.resume()
                    case .failed(let error): connection.stateUpdateHandler = nil; continuation.resume(throwing: error)
                    case .cancelled: connection.stateUpdateHandler = nil; continuation.resume(throwing: URLError(.timedOut))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }, onCancel: { connection.cancel() })
        return PooledConnection(connection: connection, reader: SocketReader(connection), queue: queue)
    }

    private func exchange(_ url: URL, pooled: PooledConnection?, key: String, host: String, port: NWEndpoint.Port, route: String, method: String,
                          headers: [String: String], body: Data, bodyFile: URL?, accept: Set<Int>, limit: Int, allowPrefix: Bool, dsm: Bool) async throws -> NASResponse {
        let link: PooledConnection
        if let pooled { link = pooled } else { link = try await connect(host: host, port: port, route: route) }
        let connection = link.connection, reader = link.reader
        // A long upload keeps the connection alive as long as pieces keep going out.
        let timeout = Watchdog(queue: link.queue) { connection.cancel() }
        timeout.arm(35)
        // Kept open for the next request only when the whole response was read.
        var reusable = false
        defer {
            timeout.cancel()
            if reusable { NASConnectionPool.shared.put(key, link) } else { connection.cancel() }
        }

        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            // Only DSM API calls carry a query; WebDAV URLs never do.
            let path = components.percentEncodedPath + (dsm ? components.percentEncodedQuery.map { "?" + $0 } ?? "" : "")
            let hostValue = (host.contains(":") ? "[\(host)]" : host) + (url.port.map { ":\($0)" } ?? "")
            let credential = Data("\(account.username):\(account.password)".utf8).base64EncodedString()
            var fileSize: Int64?
            if let bodyFile {
                guard let size = (try? FileManager.default.attributesOfItem(atPath: bodyFile.path))?[.size] as? NSNumber else {
                    throw GalleryError.message("No se encontró el archivo para subir.")
                }
                fileSize = size.int64Value
            }
            var lines = ["\(method) \(path.isEmpty ? "/" : path) HTTP/1.1", "Host: \(hostValue)", "Authorization: Basic \(credential)",
                         "Connection: keep-alive", "Accept-Encoding: identity", "Content-Length: \(fileSize ?? Int64(body.count))"]
            for (key, value) in headers {
                guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else { throw GalleryError.message("Cabecera no válida.") }
                lines.append("\(key): \(value)")
            }
            var wire = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8); wire.append(body)
            func send(_ data: Data) async throws {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                }
            }
            try await send(wire)
            if let bodyFile, let fileSize {
                let file = try FileHandle(forReadingFrom: bodyFile)
                defer { try? file.close() }
                var sent: Int64 = 0
                while sent < fileSize {
                    try Task.checkCancellation()
                    guard let piece = try file.read(upToCount: 262_144), !piece.isEmpty else { throw GalleryError.message("El archivo cambió mientras se subía.") }
                    try await send(piece)
                    sent += Int64(piece.count)
                    timeout.arm(35)
                }
                // The NAS may take a moment to store a large file before answering.
                timeout.arm(90)
            }
            let head = try await reader.until(Data("\r\n\r\n".utf8), max: 65536)
            if let text = String(data: head, encoding: .isoLatin1), let first = text.components(separatedBy: "\r\n").first,
               let status = Int(first.split(separator: " ").dropFirst().first ?? ""), !(200...299).contains(status), accept.contains(status) {
                // Expected answers such as «already exists»: the body is not read, so this
                // connection is not reused.
                return NASResponse(status: status, headers: [:], data: Data())
            }
            guard let text = String(data: head, encoding: .isoLatin1), let first = text.components(separatedBy: "\r\n").first,
                  let status = Int(first.split(separator: " ").dropFirst().first ?? ""), (200...299).contains(status) else {
                let statusLine = String(data: head.prefix(100), encoding: .isoLatin1) ?? ""
                if statusLine.contains("401") { throw GalleryError.message("Usuario o contraseña incorrectos.") }
                if statusLine.contains("403") {
                    throw GalleryError.message(["PUT", "MKCOL", "MOVE"].contains(method) ? "La cuenta no tiene permiso de escritura en la carpeta del NAS." : "La cuenta no tiene permiso de lectura.")
                }
                if statusLine.contains("507") { throw GalleryError.message("El NAS no tiene espacio libre.") }
                throw GalleryError.message("El NAS rechazó la solicitud. Revisa la carpeta y el acceso WebDAV; no se siguen redirecciones.")
            }
            var fields: [String: String] = [:]
            for line in text.components(separatedBy: "\r\n").dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    fields[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if let encoding = fields["content-encoding"], encoding != "identity" { throw GalleryError.message("El NAS envió una codificación no compatible.") }
            var result = Data()
            var complete = false
            func append(_ part: Data) throws -> Bool {
                if result.count + part.count > limit {
                    guard allowPrefix else { throw GalleryError.message("La respuesta excede el tamaño permitido.") }
                    result.append(part.prefix(limit - result.count)); return false
                }
                result.append(part); return !allowPrefix || result.count < limit
            }
            if status == 204 || status == 304 {
                // These answers never carry a body.
                complete = true
            } else if fields["transfer-encoding"]?.lowercased() == "chunked" {
                outer: while true {
                    let line = try await reader.until(Data("\r\n".utf8), max: 4096)
                    guard let text = String(data: line, encoding: .ascii), let number = text.split(separator: ";").first,
                          let size = Int(number, radix: 16), size >= 0 else { throw GalleryError.message("Respuesta HTTP incompleta.") }
                    if size == 0 {
                        // Trailers end with an empty line; then the connection can be reused.
                        while !(try await reader.until(Data("\r\n".utf8), max: 4096)).isEmpty {}
                        complete = true
                        break
                    }
                    var remaining = size
                    while remaining > 0 {
                        let part = try await reader.exactly(min(65536, remaining)); remaining -= part.count
                        if try !append(part) { break outer }
                    }
                    guard try await reader.exactly(2) == Data("\r\n".utf8) else { throw GalleryError.message("Respuesta HTTP no válida.") }
                }
            } else if let text = fields["content-length"], let size = Int64(text), size >= 0 {
                if size > Int64(limit) && !allowPrefix { throw GalleryError.message("La respuesta excede el tamaño permitido.") }
                var remaining = size
                while remaining > 0 {
                    let part = try await reader.exactly(Int(min(65536, remaining))); remaining -= Int64(part.count)
                    if try !append(part) { break }
                }
                complete = remaining == 0
            } else {
                while let part = try await reader.some() { if try !append(part) { break } }
            }
            try Task.checkCancellation()
            reusable = complete && reader.isEmpty && fields["connection"]?.lowercased() != "close"
            return NASResponse(status: status, headers: fields, data: result)
        }, onCancel: { connection.cancel() })
    }

    func list(_ folder: URL) async throws -> [DAVEntry] {

        let xml = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>".utf8)

        let response = try await request(folder, method: "PROPFIND", headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"], body: xml, limit: DAVParser.maxResponse)

        guard response.status == 207 else { throw GalleryError.message("La dirección no corresponde a WebDAV.") }

        return try DAVParser.parse(response.data, folder: folder)

    }

    func range(_ url: URL, start: Int64, count: Int, prefix: Bool = false) async throws -> NASResponse {

        let response = try await request(url, headers: ["Range": "bytes=\(start)-\(start + Int64(count) - 1)"], limit: count, allowPrefix: prefix)

        if response.status == 206 {

            guard response.headers["content-range"]?.hasPrefix("bytes \(start)-") == true else { throw GalleryError.message("El NAS devolvió un rango de archivo incorrecto.") }

        } else if start != 0 { throw GalleryError.message("El NAS no permite descargar por partes.") }

        return response

    }

}

extension NASTransport {
    /// Used and free space of the share (RFC 4331 quota properties), when the NAS reports them.
    func space(_ folder: URL) async throws -> NASSpace? {
        let xml = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>".utf8)
        let response = try await request(folder, method: "PROPFIND", headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"], body: xml, limit: 200_000)
        guard response.status == 207, let text = String(data: response.data, encoding: .utf8) else { return nil }
        return Self.parseSpace(text)
    }

    static func parseSpace(_ xml: String) -> NASSpace? {
        func value(_ name: String) -> Int64? {
            guard let range = xml.range(of: "\(name)[^>]*>\\s*(\\d+)\\s*<", options: .regularExpression) else { return nil }
            return Int64(xml[range].filter(\.isNumber))
        }
        let space = NASSpace(used: value("quota-used-bytes"), available: value("quota-available-bytes"))
        return space.used == nil && space.available == nil ? nil : space
    }

    /// Copies a file to disk in bounded ranges, so a long video never has to fit in memory.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let chunk = 8 * 1_048_576
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw GalleryError.message("No se pudo crear el archivo temporal.") }
        let handle = try FileHandle(forWritingTo: partial)
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? FileManager.default.removeItem(at: partial) }
        }
        var offset: Int64 = 0
        var total: Int64?
        repeat {
            try Task.checkCancellation()
            let response = try await range(url, start: offset, count: chunk, prefix: true)
            if total == nil { total = response.totalLength }
            if response.status == 200, let size = total, Int64(response.data.count) < size {
                throw GalleryError.message("El NAS no permite descargar este archivo por partes.")
            }
            guard !response.data.isEmpty else { break }
            try handle.write(contentsOf: response.data)
            offset += Int64(response.data.count)
            if let size = total, size > 0 { progress(min(1, Double(offset) / Double(size))) }
            if response.status == 200 { break }
        } while offset < (total ?? 0)
        try handle.close()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        finished = true
    }
}

/// Cancels a connection when it goes quiet for too long; each `arm` starts the wait again.
final class Watchdog: @unchecked Sendable {
    private let queue: DispatchQueue
    private let action: () -> Void
    private var item: DispatchWorkItem?

    init(queue: DispatchQueue, action: @escaping () -> Void) { self.queue = queue; self.action = action }

    func arm(_ seconds: Double) {
        queue.async { [self] in
            item?.cancel()
            let next = DispatchWorkItem(block: action)
            item = next
            queue.asyncAfter(deadline: .now() + seconds, execute: next)
        }
    }

    func cancel() { queue.async { [self] in item?.cancel(); item = nil } }

    deinit { item?.cancel() }
}

/// An open HTTPS connection to the NAS with what is left in its buffer.
struct PooledConnection {
    let connection: NWConnection
    let reader: SocketReader
    let queue: DispatchQueue
}

/// Connections kept open between requests: opening one costs the NAS a TLS handshake,
/// the heaviest part of a request for a small NAS. Idle ones are closed after 15 s.
final class NASConnectionPool: @unchecked Sendable {
    static let shared = NASConnectionPool()
    private let lock = NSLock()
    private var idle: [String: [(link: PooledConnection, since: Date)]] = [:]

    func take(_ key: String) -> PooledConnection? {
        lock.lock(); defer { lock.unlock() }
        var list = idle[key] ?? []
        defer { idle[key] = list }
        while let entry = list.popLast() {
            if Date().timeIntervalSince(entry.since) < 15, entry.link.connection.state == .ready { return entry.link }
            entry.link.connection.cancel()
        }
        return nil
    }

    func put(_ key: String, _ link: PooledConnection) {
        lock.lock(); defer { lock.unlock() }
        var list = (idle[key] ?? []).filter { entry in
            let fresh = Date().timeIntervalSince(entry.since) < 15
            if !fresh { entry.link.connection.cancel() }
            return fresh
        }
        if list.count >= 6 { link.connection.cancel() } else { list.append((link, Date())) }
        idle[key] = list
    }
}

final class SocketReader {

    let connection: NWConnection

    var buffer = Data()

    var ended = false

    init(_ connection: NWConnection) { self.connection = connection }

    func receive() async throws {

        try Task.checkCancellation()

        // The NAS closed the connection; a request on a reused connection is then retried.
        if ended { throw URLError(.networkConnectionLost) }

        let pair: (Data, Bool) = try await withCheckedThrowingContinuation { continuation in

            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in

                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data ?? Data(), complete)) }

            }

        }

        buffer.append(pair.0); ended = pair.1

    }

    func until(_ delimiter: Data, max: Int) async throws -> Data {

        while true {

            if let range = buffer.range(of: delimiter) {

                guard range.lowerBound <= max else { throw GalleryError.message("Cabecera HTTP demasiado grande.") }

                let result = Data(buffer[..<range.lowerBound]); buffer = Data(buffer[range.upperBound...]); return result

            }

            if buffer.count > max { throw GalleryError.message("Cabecera HTTP demasiado grande.") }

            try await receive()

        }

    }

    func exactly(_ count: Int) async throws -> Data {

        while buffer.count < count { try await receive() }

        let result = Data(buffer.prefix(count)); buffer = Data(buffer.dropFirst(count)); return result

    }

    var isEmpty: Bool { buffer.isEmpty }

    func some() async throws -> Data? {

        if buffer.isEmpty && !ended { try await receive() }

        if buffer.isEmpty { return nil }

        let result = buffer; buffer = Data(); return result

    }

}

extension Notification.Name {
    static let nasRequestSucceeded = Notification.Name("lfaz.galeria.nas.request.succeeded")
}
