import AppKit
import OSLog
import Photos

let appLog = Logger(subsystem: "jp.cloford.photo-slideshow", category: "Playback")

struct Album: Sendable {
    let id: String
    let title: String
    let context: String
    let imageCount: Int

    static func labels(for albums: [Album]) -> [String] {
        let titleCounts = Dictionary(grouping: albums, by: \.title).mapValues(\.count)
        let contextual = albums.map { album in
            titleCounts[album.title] == 1 ? album.title : "\(album.title) — \(album.context)"
        }
        let contextCounts = Dictionary(grouping: contextual, by: { $0 }).mapValues(\.count)
        let counted = zip(albums, contextual).map { album, label in
            contextCounts[label] == 1 ? label : "\(label)（\(album.imageCount)枚）"
        }
        let labelCounts = Dictionary(grouping: counted, by: { $0 }).mapValues(\.count)
        var occurrences: [String: Int] = [:]
        return counted.map { label in
            guard labelCounts[label, default: 0] > 1 else { return label }
            occurrences[label, default: 0] += 1
            return "\(label) #\(occurrences[label, default: 0])"
        }
    }
}

struct Photo: Sendable {
    let id: String
    let date: Date?
    let modified: Date?
    let width: Int?
    let height: Int?

    init(id: String, date: Date?, modified: Date? = nil, width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.date = date
        self.modified = modified
        self.width = width
        self.height = height
    }

    static func ordered(_ photos: [Photo]) -> [Photo] {
        photos.sorted { a, b in
            if let first = a.date, let second = b.date, first != second { return first < second }
            if (a.date == nil) != (b.date == nil) { return a.date != nil }
            return a.id < b.id
        }
    }
}

// PhotoKit hands off a fully loaded image. Only AppKit on the main actor draws it.
struct LoadedImage: @unchecked Sendable {
    let image: NSImage
}

enum ImageResult: Sendable {
    case image(LoadedImage)
    case unavailable(cloud: Bool)
}

@MainActor
protocol PhotoSource: Sendable {
    var sourceKind: String { get }
    var sourceID: String { get }
    func resources(for photo: Photo) async -> [PhotoResource]
    func requestThumbnail(for photo: Photo, size: CGSize,
                          completion: @escaping @MainActor (ImageResult) -> Void) -> () -> Void
    func albums() async -> [Album]
    func photos(in album: String) async -> [Photo]?
    func requestImage(
        for photo: Photo, size: CGSize, completion: @escaping @MainActor (ImageResult) -> Void
    ) -> () -> Void
}

struct PhotoResource: Codable, Sendable {
    let filename: String?
    let format: String?
    let kind: String?
}

extension PhotoSource {
    var sourceKind: String { "photos" }
    var sourceID: String { "system-photo-library" }
    func resources(for photo: Photo) async -> [PhotoResource] { [] }
    func requestThumbnail(for photo: Photo, size: CGSize,
                          completion: @escaping @MainActor (ImageResult) -> Void) -> () -> Void {
        requestImage(for: photo, size: size, completion: completion)
    }
}

@MainActor
protocol SlideshowLibrary: PhotoSource {
    var authorization: PHAuthorizationStatus { get }
    func requestAuthorization() async -> PHAuthorizationStatus
}

@MainActor
final class PhotoLibrary: SlideshowLibrary {
    private let queue = DispatchQueue(label: "jp.cloford.photo-slideshow.photos", qos: .userInitiated)
    private var assets: [String: PHAsset] = [:]
    private let manager = PHImageManager.default()

    var authorization: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func assetOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    func albums() async -> [Album] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.fetchAlbums())
            }
        }
    }

    nonisolated private static func fetchAlbums() -> [Album] {
        var collections: [String: Album] = [:]
        func add(_ album: PHAssetCollection, context: String) {
            let id = album.localIdentifier
            guard collections[id] == nil else { return }
            // estimatedAssetCount can include videos. An exact count is only needed for duplicate labels.
            collections[id] = Album(id: id, title: album.localizedTitle ?? "名称未設定",
                                    context: context, imageCount: 0)
        }
        func visit(_ results: PHFetchResult<PHCollection>, path: [String]) {
            results.enumerateObjects { collection, _, _ in
                if let folder = collection as? PHCollectionList {
                    visit(PHCollection.fetchCollections(in: folder, options: nil),
                          path: path + [folder.localizedTitle ?? "名称未設定のフォルダ"])
                } else if let album = collection as? PHAssetCollection {
                    let root = album.assetCollectionSubtype == .albumCloudShared ? "共有アルバム" : "アルバム"
                    add(album, context: path.isEmpty ? root : path.joined(separator: " › "))
                }
            }
        }
        visit(PHCollectionList.fetchTopLevelUserCollections(with: nil), path: [])
        for type: PHAssetCollectionType in [.album, .smartAlbum] {
            PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
                .enumerateObjects { album, _, _ in
                    let context = type == .smartAlbum ? "スマートアルバム" :
                        (album.assetCollectionSubtype == .albumCloudShared ? "共有アルバム" : "アルバム")
                    add(album, context: context)
                }
        }
        let titles = Dictionary(grouping: collections.values, by: \.title)
        return collections.values.map { item in
            guard titles[item.title, default: []].count > 1,
                  let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [item.id], options: nil)
                    .firstObject else { return item }
            let count = PHAsset.fetchAssets(in: album, options: assetOptions()).count
            return Album(id: item.id, title: item.title, context: item.context, imageCount: count)
        }.sorted { first, second in
            let titleOrder = first.title.localizedStandardCompare(second.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            if first.context != second.context { return first.context < second.context }
            return first.id < second.id
        }
    }

    func photos(in album: String) async -> [Photo]? {
        let result: [PHAsset]? = await withCheckedContinuation { continuation in
            queue.async {
                guard let collection = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [album], options: nil).firstObject else {
                    continuation.resume(returning: nil)
                    return
                }
                var assets: [PHAsset] = []
                PHAsset.fetchAssets(in: collection, options: Self.assetOptions()).enumerateObjects { asset, _, _ in
                    assets.append(asset)
                }
                continuation.resume(returning: assets)
            }
        }
        guard let result, !Task.isCancelled else { return nil }
        assets = Dictionary(result.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        return Photo.ordered(result.map { asset in
            Photo(id: asset.localIdentifier, date: asset.creationDate, modified: asset.modificationDate,
                  width: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
                  height: asset.pixelHeight > 0 ? asset.pixelHeight : nil)
        })
    }

    func resources(for photo: Photo) async -> [PhotoResource] {
        guard let asset = assets[photo.id] else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: PHAssetResource.assetResources(for: asset).map {
                    let name: String?
                    if #available(macOS 27, *) { name = $0.filename }
                    else { name = $0.originalFilename }
                    let format: String
                    if #available(macOS 26, *) { format = $0.contentType.identifier }
                    else { format = $0.uniformTypeIdentifier }
                    return PhotoResource(filename: name == "" ? nil : name,
                                         format: format.isEmpty ? nil : format,
                                         kind: Self.resourceKind($0.type))
                })
            }
        }
    }

    nonisolated private static func resourceKind(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: return "originalPhoto"
        case .fullSizePhoto: return "fullSizePhoto"
        case .alternatePhoto: return "alternatePhoto"
        case .adjustmentBasePhoto: return "adjustmentBasePhoto"
        case .adjustmentData: return "adjustmentData"
        case .pairedVideo: return "pairedVideo"
        default: return "photoKit:\(type.rawValue)"
        }
    }

    func requestThumbnail(for photo: Photo, size: CGSize,
                          completion: @escaping @MainActor (ImageResult) -> Void) -> () -> Void {
        requestImage(for: photo, size: size, network: false, completion: completion)
    }

    func requestImage(for photo: Photo, size: CGSize,
                      completion: @escaping @MainActor (ImageResult) -> Void) -> () -> Void {
        requestImage(for: photo, size: size, network: true, completion: completion)
    }

    private func requestImage(for photo: Photo, size: CGSize, network: Bool,
                              completion: @escaping @MainActor (ImageResult) -> Void) -> () -> Void {
        guard let asset = assets[photo.id] else {
            let task = Task { @MainActor in
                if !Task.isCancelled { completion(.unavailable(cloud: false)) }
            }
            return { task.cancel() }
        }
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = network
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.version = .current
        let id = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) {
            image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? NSError
            let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if degraded && !cancelled && error == nil { return }
            let result: ImageResult
            if !cancelled, error == nil, let image, image.isValid, image.size.width > 0, image.size.height > 0 {
                result = .image(LoadedImage(image: image))
            } else {
                result = .unavailable(cloud: inCloud || error?.domain == NSURLErrorDomain)
            }
            Task { @MainActor in completion(result) }
        }
        return { [manager] in manager.cancelImageRequest(id) }
    }
}
