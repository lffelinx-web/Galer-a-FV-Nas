import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// Gets the original file of a photo or video, for sharing, copying or saving: from the
/// iPhone library (asking iCloud when needed) or downloaded from the NAS.
enum ItemExport {
    static var folder: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Compartir", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A local copy of the original, with its own name.
    @MainActor
    static func file(for item: GalleryItem, account: NASAccount?, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        switch item.source {
        case .nas(let url):
            guard let account else { throw GalleryError.message("Conecta el NAS para usar este archivo.") }
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, let bytes = item.bytes, Int64(size) == bytes { return destination }
            try await NASTransport(account).download(url, to: destination, progress: progress)
            return destination
        case .phone(let id):
            guard let asset = PhoneLibrary.shared.asset(id) else { throw GalleryError.message("La foto ya no está en el iPhone.") }
            let resources = PHAssetResource.assetResources(for: asset)
            let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
            guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first ?? resources.first else {
                throw GalleryError.message("No se encontró el archivo original.")
            }
            let destination = folder.appendingPathComponent(resource.originalFilename)
            try? FileManager.default.removeItem(at: destination)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            options.progressHandler = { progress($0) }
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)
            return destination
        }
    }

    /// Adds a NAS photo or video to the iPhone library. The only place the app writes there,
    /// and only when you ask for it.
    static func saveToPhone(_ file: URL, isVideo: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.lastPathComponent
            request.addResource(with: isVideo ? .video : .photo, fileURL: file, options: options)
        }
    }

    /// Puts a photo on the clipboard.
    static func copy(_ file: URL) throws {
        guard let image = UIImage(contentsOfFile: file.path) else { throw GalleryError.message("No se pudo copiar esta foto.") }
        UIPasteboard.general.image = image
    }

    static func clear() { try? FileManager.default.removeItem(at: folder) }
}
