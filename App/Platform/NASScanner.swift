import Foundation

/// What a folder held at the last search, to skip it next time if it did not change.
struct CachedFolder: Codable, Equatable {
    /// The folder's modification date as its parent listed it.
    var modified: Date?
    /// A folder without subfolders: its date changes whenever a file is added or removed.
    var leaf: Bool
    /// Ids of the photos and videos directly inside.
    var items: [String]
}

/// Walks every folder under the WebDAV root, several listings at a time, and turns each
/// photo or video into a `GalleryItem`. A folder without subfolders whose date did not
/// change since the last search is taken from the previous result instead of asking the
/// NAS again, which makes a repeat search much faster. Synology system folders
/// (`@eaDir`, `#recycle`) and hidden files are skipped.
struct NASScanner {
    static let maxDepth = 12
    static let maxFolders = 20_000
    static let maxFiles = 300_000
    static let parallel = 6

    struct Result {
        var items: [GalleryItem]
        var folders: [String: CachedFolder]
        var reused: Int
    }

    let account: NASAccount
    var learnedAspects: [String: Double] = [:]
    var previousFolders: [String: CachedFolder] = [:]
    var previousItems: [String: GalleryItem] = [:]

    func scan(progress: @escaping @Sendable (String, Int) -> Void) async throws -> Result {
        let transport = NASTransport(account)
        let rootEntries = try await transport.list(account.root)
        var result = Result(items: [], folders: [:], reused: 0)
        var pending: [(url: URL, folders: [String], modified: Date?)] = []
        var visited = 1, failed = 0
        collect(rootEntries, folders: [], into: &result, pending: &pending)
        while !pending.isEmpty {
            try Task.checkCancellation()
            let batch = Array(pending.suffix(Self.parallel))
            pending.removeLast(batch.count)
            visited += batch.count
            guard visited <= Self.maxFolders else { throw GalleryError.message("El NAS tiene más de \(Self.maxFolders.formatted()) carpetas; elige una carpeta más específica en Configuración.") }
            let listed = await withTaskGroup(of: (Int, [DAVEntry]?).self) { group -> [(Int, [DAVEntry]?)] in
                for (position, folder) in batch.enumerated() {
                    group.addTask { (position, try? await transport.list(folder.url)) }
                }
                var out: [(Int, [DAVEntry]?)] = []
                for await entry in group { out.append(entry) }
                return out
            }
            try Task.checkCancellation()
            for (position, entries) in listed {
                let folder = batch[position]
                guard let entries else { failed += 1; continue }
                let before = result.items.count
                let hasSubfolders = collect(entries, folders: folder.folders, into: &result, pending: &pending)
                result.folders[folder.url.absoluteString] = CachedFolder(modified: folder.modified, leaf: !hasSubfolders,
                                                                        items: result.items[before...].map(\.id))
                guard result.items.count <= Self.maxFiles else { throw GalleryError.message("El NAS tiene más de \(Self.maxFiles.formatted()) archivos; elige una carpeta más específica en Configuración.") }
            }
            progress(batch.last?.folders.joined(separator: "/") ?? "", result.items.count)
        }
        if failed > 0 && result.items.isEmpty { throw GalleryError.message("No se pudieron leer las carpetas del NAS.") }
        result.items = Self.removeLivePhotoVideos(result.items).sorted { $0.date > $1.date }
        return result
    }

    /// Adds the files of one listing and queues its subfolders. Returns whether it had subfolders.
    @discardableResult
    private func collect(_ entries: [DAVEntry], folders: [String], into result: inout Result, pending: inout [(url: URL, folders: [String], modified: Date?)]) -> Bool {
        var hasSubfolders = false
        for entry in entries where !Self.hidden(entry.name) {
            if entry.directory {
                hasSubfolders = true
                guard folders.count < Self.maxDepth else { continue }
                let key = entry.url.absoluteString
                // Unchanged folder without subfolders: reuse what it held last time.
                if let cached = previousFolders[key], cached.leaf, let modified = entry.modified, cached.modified == modified {
                    // Ids missing from the previous result are Live Photo movies that were hidden.
                    result.items.append(contentsOf: cached.items.compactMap { previousItems[$0] })
                    result.folders[key] = cached
                    result.reused += 1
                    continue
                }
                pending.append((entry.url, folders + [entry.name], entry.modified))
            } else if let kind = entry.kind {
                let id = "n:" + entry.url.absoluteString
                let date = DateGuess.date(fileName: entry.name, folders: folders) ?? entry.modified ?? Date(timeIntervalSince1970: 0)
                result.items.append(GalleryItem(id: id, source: .nas(entry.url), date: date, kind: kind, aspect: learnedAspects[id] ?? 1,
                                                duration: nil, name: entry.name, bytes: entry.bytes, folder: folders.joined(separator: "/")))
            }
        }
        return hasSubfolders
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
