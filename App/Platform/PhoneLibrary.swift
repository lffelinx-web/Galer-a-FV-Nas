import Photos
import AVFoundation
import UIKit

enum PhotoAccess: Equatable {
    case notDetermined, denied, limited, full

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .limited: self = .limited
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }

    var canRead: Bool { self == .full || self == .limited }
    var label: String {
        switch self {
        case .notDetermined: return "Sin permiso todavía"
        case .denied: return "Acceso denegado"
        case .limited: return "Acceso limitado"
        case .full: return "Acceso completo"
        }
    }
}

struct PhoneAlbum: Identifiable {
    let id: String
    let title: String
    let count: Int
    let cover: GalleryItem?
}

/// Reads the iPhone photo library with PhotoKit. Nothing is ever written to it.
@MainActor
final class PhoneLibrary: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhoneLibrary()

    let manager = PHCachingImageManager()
    private var assets: [String: PHAsset] = [:]
    private var observing = false
    var onChange: (() -> Void)?

    static var access: PhotoAccess { PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    static func requestAccess() async -> PhotoAccess {
        PhotoAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    /// Every photo and video, newest first.
    func load() async -> [GalleryItem] {
        let (items, assets) = await Task.detached(priority: .userInitiated) { Self.fetchAll() }.value
        self.assets = assets
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        return items
    }

    nonisolated static func fetchAll() -> ([GalleryItem], [String: PHAsset]) {
        let result = PHAsset.fetchAssets(with: sortedOptions())
        var items: [GalleryItem] = []
        var assets: [String: PHAsset] = [:]
        items.reserveCapacity(result.count)
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            items.append(GalleryItem(asset: asset))
            assets[asset.localIdentifier] = asset
        }
        return (items, assets)
    }

    nonisolated static func sortedOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        return options
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.onChange?() }
    }

    func asset(_ id: String) -> PHAsset? {
        if let asset = assets[id] { return asset }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        if let asset { assets[id] = asset }
        return asset
    }

    /// Delivers a quick low-quality image first and then the sharp one; asks iCloud when needed.
    func images(_ id: String, pixels: CGSize, fill: Bool) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            guard let asset = asset(id) else { continuation.finish(); return }
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let manager = self.manager
            let request = manager.requestImage(for: asset, targetSize: pixels, contentMode: fill ? .aspectFill : .aspectFit, options: options) { image, info in
                if let image { continuation.yield(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded || info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) == true { continuation.finish() }
            }
            continuation.onTermination = { _ in manager.cancelImageRequest(request) }
        }
    }

    func livePhoto(_ id: String, pixels: CGSize) -> AsyncStream<PHLivePhoto> {
        AsyncStream { continuation in
            guard let asset = asset(id) else { continuation.finish(); return }
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            let manager = self.manager
            let request = manager.requestLivePhoto(for: asset, targetSize: pixels, contentMode: .aspectFit, options: options) { photo, info in
                if let photo { continuation.yield(photo) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded || info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) == true { continuation.finish() }
            }
            continuation.onTermination = { _ in manager.cancelImageRequest(request) }
        }
    }

    func playerItem(_ id: String) async -> AVPlayerItem? {
        guard let asset = asset(id) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in continuation.resume(returning: item) }
        }
    }

    // MARK: Albums

    func albums() async -> [PhoneAlbum] {
        await Task.detached(priority: .userInitiated) { Self.fetchAlbums() }.value
    }

    nonisolated static func fetchAlbums() -> [PhoneAlbum] {
        var collections: [PHAssetCollection] = []
        let smart: [PHAssetCollectionSubtype] = [.smartAlbumFavorites, .smartAlbumRecentlyAdded, .smartAlbumVideos, .smartAlbumSelfPortraits,
                                                 .smartAlbumLivePhotos, .smartAlbumPanoramas, .smartAlbumScreenshots, .smartAlbumBursts]
        for subtype in smart {
            if let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject { collections.append(collection) }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in collections.append(collection) }
        return collections.compactMap { collection in
            let result = PHAsset.fetchAssets(in: collection, options: sortedOptions())
            guard result.count > 0 else { return nil }
            return PhoneAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Álbum", count: result.count,
                              cover: result.firstObject.map { GalleryItem(asset: $0) })
        }
    }

    func items(inAlbum id: String) async -> [GalleryItem] {
        let (items, found) = await Task.detached(priority: .userInitiated) { () -> ([GalleryItem], [PHAsset]) in
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { return ([], []) }
            let result = PHAsset.fetchAssets(in: collection, options: Self.sortedOptions())
            var items: [GalleryItem] = [], assets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in items.append(GalleryItem(asset: asset)); assets.append(asset) }
            return (items, assets)
        }.value
        for asset in found where assets[asset.localIdentifier] == nil { assets[asset.localIdentifier] = asset }
        return items
    }
}

extension GalleryItem {
    init(asset: PHAsset) {
        let kind: MediaKind
        if asset.mediaType == .video { kind = .video }
        else if asset.mediaSubtypes.contains(.photoLive) { kind = .livePhoto }
        else { kind = .photo }
        self.init(id: "p:" + asset.localIdentifier, source: .phone(asset.localIdentifier),
                  date: asset.creationDate ?? asset.modificationDate ?? Date(timeIntervalSince1970: 0), kind: kind,
                  aspect: asset.pixelHeight > 0 ? Double(asset.pixelWidth) / Double(asset.pixelHeight) : 1,
                  duration: asset.mediaType == .video ? asset.duration : nil, name: "", bytes: nil, folder: nil, favorite: asset.isFavorite)
    }
}
