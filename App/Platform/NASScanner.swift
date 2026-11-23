import Foundation

/// Walks every folder under the WebDAV root, four listings at a time, and turns each
/// photo or video into a `GalleryItem`. Synology system folders (`@eaDir`, `#recycle`)
/// and hidden files are skipped.
struct NASScanner {
    static let maxDepth = 12
    static let maxFolders = 20_000
    static let maxFiles = 300_000
    static let parallel = 4

    let account: NASAccount
    var learnedAspects: [String: Double] = [:]

    func scan(progress: @escaping @Sendable (String, Int) -> Void) async throws -> [GalleryItem] {
        let transport = NASTransport(account)
        let rootEntries = try await transport.list(account.root)
        var items: [GalleryItem] = []
        var pending: [(URL, [String])] = []
        var visited = 1, failed = 0
        collect(rootEntries, folders: [], into: &items, pending: &pending)
        while !pending.isEmpty {
            try Task.checkCancellation()
            let batch = Array(pending.suffix(Self.parallel))
            pending.removeLast(batch.count)
            visited += batch.count
            guard visited <= Self.maxFolders else { throw GalleryError.message("El NAS tiene más de \(Self.maxFolders.formatted()) carpetas; elige una carpeta más específica en Configuración.") }
            let results = await withTaskGroup(of: ([String], [DAVEntry]?).self) { group -> [([String], [DAVEntry]?)] in
                for (url, folders) in batch {
                    group.addTask { (folders, try? await transport.list(url)) }
                }
                var out: [([String], [DAVEntry]?)] = []
                for await result in group { out.append(result) }
                return out
            }
            try Task.checkCancellation()
            for (folders, entries) in results {
                guard let entries else { failed += 1; continue }
                collect(entries, folders: folders, into: &items, pending: &pending)
                guard items.count <= Self.maxFiles else { throw GalleryError.message("El NAS tiene más de \(Self.maxFiles.formatted()) archivos; elige una carpeta más específica en Configuración.") }
            }
            progress(batch.last?.1.joined(separator: "/") ?? "", items.count)
        }
        if failed > 0 && items.isEmpty { throw GalleryError.message("No se pudieron leer las carpetas del NAS.") }
        return Self.removeLivePhotoVideos(items).sorted { $0.date > $1.date }
    }

    private func collect(_ entries: [DAVEntry], folders: [String], into items: inout [GalleryItem], pending: inout [(URL, [String])]) {
        for entry in entries where !Self.hidden(entry.name) {
            if entry.directory {
                if folders.count < Self.maxDepth { pending.append((entry.url, folders + [entry.name])) }
            } else if let kind = entry.kind {
                let id = "n:" + entry.url.absoluteString
                let date = DateGuess.date(fileName: entry.name, folders: folders) ?? entry.modified ?? Date(timeIntervalSince1970: 0)
                items.append(GalleryItem(id: id, source: .nas(entry.url), date: date, kind: kind, aspect: learnedAspects[id] ?? 1,
                                         duration: nil, name: entry.name, bytes: entry.bytes, folder: folders.joined(separator: "/")))
            }
        }
    }

    static func hidden(_ name: String) -> Bool {
        guard let first = name.first else { return true }
        return [".", "@", "#", "~", "$"].contains(first) || name == "Thumbs.db"
    }

    /// An iPhone Live Photo copied to the NAS is `IMG_1234.HEIC` plus `IMG_1234.MOV`; the
    /// movie part is hidden so the photo is not shown twice.
    static func removeLivePhotoVideos(_ items: [GalleryItem]) -> [GalleryItem] {
        func stem(_ item: GalleryItem) -> String {
            (item.folder ?? "") + "/" + (item.name as NSString).deletingPathExtension.lowercased()
        }
        let photos = Set(items.filter { $0.kind == .photo }.map(stem))
        return items.filter { item in
            !(item.kind == .video && item.fileExtension == "mov" && photos.contains(stem(item)))
        }
    }
}
