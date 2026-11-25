import Foundation

struct PlaybackPreferences: Codable, Equatable, Sendable {
    enum Edge: String, Codable, Sendable { case top, bottom }
    enum ClockStyle: String, Codable, Sendable { case analog, digital }
    enum ClockSide: String, Codable, Sendable { case left, right }

    static let presets = [3, 5, 10, 15, 30, 60]
    var seconds = 5
    var fromBeginning = false
    var barHideSeconds = 3
    var noticeSide: ClockSide = .right
    var clockPlacement = OverlayPlacement()
    var heartPlacement = OverlayPlacement()
    var barPlacement = OverlayPlacement()

    func placement(_ item: OverlayItem) -> OverlayPlacement {
        switch item {
        case .clock: clockPlacement
        case .heart: heartPlacement
        case .bar: barPlacement
        }
    }

    mutating func setPlacement(_ value: OverlayPlacement, for item: OverlayItem) {
        switch item {
        case .clock: clockPlacement = value
        case .heart: heartPlacement = value
        case .bar: barPlacement = value
        }
    }

    mutating func resetPosition(_ item: OverlayItem) {
        var value = placement(item)
        value.position = nil
        setPlacement(value, for: item)
        switch item {
        case .clock: clockSide = .right
        case .heart: noticeSide = .right
        case .bar: barEdge = .bottom
        }
    }

    var reserveBarSpace = false
    var barEdge: Edge = .bottom
    var clockVisible = false
    var clockStyle: ClockStyle = .digital
    var clockSide: ClockSide = .right

    init(seconds: Int = 5, fromBeginning: Bool = false) {
        self.seconds = seconds
        self.fromBeginning = fromBeginning
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try values.decodeIfPresent(Int.self, forKey: .seconds) ?? 5
        fromBeginning = try values.decodeIfPresent(Bool.self, forKey: .fromBeginning) ?? false
        barHideSeconds = try values.decodeIfPresent(Int.self, forKey: .barHideSeconds) ?? 3
        noticeSide = try values.decodeIfPresent(ClockSide.self, forKey: .noticeSide) ?? .right
        clockPlacement = try values.decodeIfPresent(OverlayPlacement.self, forKey: .clockPlacement) ?? OverlayPlacement()
        heartPlacement = try values.decodeIfPresent(OverlayPlacement.self, forKey: .heartPlacement) ?? OverlayPlacement()
        barPlacement = try values.decodeIfPresent(OverlayPlacement.self, forKey: .barPlacement) ?? OverlayPlacement()
        reserveBarSpace = try values.decodeIfPresent(Bool.self, forKey: .reserveBarSpace) ?? false
        barEdge = try values.decodeIfPresent(Edge.self, forKey: .barEdge) ?? .bottom
        clockVisible = try values.decodeIfPresent(Bool.self, forKey: .clockVisible) ?? false
        clockStyle = try values.decodeIfPresent(ClockStyle.self, forKey: .clockStyle) ?? .digital
        clockSide = try values.decodeIfPresent(ClockSide.self, forKey: .clockSide) ?? .right
    }
}

struct SourceKey: Codable, Hashable, Sendable {
    static let photos = SourceKey(kind: "photos", id: "system-photo-library")
    let kind: String
    let id: String

    @MainActor
    init(_ source: any PhotoSource) { self.init(kind: source.sourceKind, id: source.sourceID) }

    init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }
}

struct Favorite: Codable, Sendable {
    let source: SourceKey
    let albumID: String
    let albumTitle: String?
    let photoID: String
    let added: Date
    let position: Int
    let captured: Date?
    let modified: Date?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let resources: [PhotoResource]
}

struct ScopedPositions: Codable, Sendable {
    var sources: [SourceKey: SourcePositions] = [:]

    struct SourcePositions: Codable, Sendable {
        var currentAlbum: String
        var photos: [String: String] = [:]
    }

    func record(for source: SourceKey, album: String? = nil) -> PlaybackRecord? {
        guard let positions = sources[source] else { return nil }
        let id = album ?? positions.currentAlbum
        return PlaybackRecord(albumID: id, photoID: positions.photos[id])
    }

    mutating func update(_ record: PlaybackRecord, source: SourceKey) {
        var positions = sources[source] ?? SourcePositions(currentAlbum: record.albumID)
        positions.currentAlbum = record.albumID
        positions.photos[record.albumID] = record.photoID
        sources[source] = positions
    }
}

struct UserData: Sendable {
    let legacy: PlaybackSettings
    private let queue = DispatchQueue(label: "jp.cloford.photo-slideshow.user-data", qos: .utility)

    private func file(_ name: String) -> URL {
        legacy.url.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL, default fallback: T) throws -> T {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            error.code == NSFileReadNoSuchFileError { return fallback }
        return try JSONDecoder().decode(type, from: data)
    }

    private func persist<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Codable & Sendable>(_ name: String, fallback: T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try decode(T.self, at: file(name), default: fallback) })
            }
        }
    }

    func positions() async throws -> ScopedPositions {
        var value = try await read("positions.json", fallback: ScopedPositions())
        if value.sources[.photos] == nil, let record = await legacy.read() {
            value.update(record, source: .photos)
        }
        return value
    }

    func preferences() async throws -> PlaybackPreferences {
        let value = try await read("preferences.json", fallback: PlaybackPreferences())
        guard (1...300).contains(value.seconds) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    func favorites() async throws -> [Favorite] { try await read("favorites.json", fallback: []) }

    func save(_ positions: ScopedPositions, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            let success: Bool
            do {
                let url = file("positions.json")
                _ = try decode(ScopedPositions.self, at: url, default: ScopedPositions())
                try persist(positions, at: url)
                success = true
            } catch {
                appLog.error("Unable to save playback positions.")
                success = false
            }
            Task { @MainActor in completion(success) }
        }
    }

    func savePreferences(_ value: PlaybackPreferences) async -> Bool {
        await save(value, name: "preferences.json")
    }

    func saveFavorites(_ value: [Favorite]) async -> Bool {
        await save(value, name: "favorites.json")
    }

    private func save<T: Codable & Sendable>(_ value: T, name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let url = file(name)
                    _ = try decode(T.self, at: url, default: value)
                    try persist(value, at: url)
                    continuation.resume(returning: true)
                } catch {
                    appLog.error("Unable to save user data.")
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
