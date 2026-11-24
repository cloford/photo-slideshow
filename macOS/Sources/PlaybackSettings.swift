import Foundation
import OSLog

struct PlaybackRecord: Codable, Sendable {
    let version: Int
    let albumID: String
    var photoID: String?

    init(albumID: String, photoID: String?) {
        version = 1
        self.albumID = albumID
        self.photoID = photoID
    }
}

struct PlaybackSettings: Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "jp.cloford.photo-slideshow.settings", qos: .utility)

    init(bundleID: String) {
        #if SLIDESHOW_QA
        if let testDirectory = ProcessInfo.processInfo.environment["PHOTO_SLIDESHOW_QA_DIR"] {
            url = URL(fileURLWithPath: testDirectory, isDirectory: true).appendingPathComponent("playback.json")
            return
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = support.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("playback.json")
    }

    func read() async -> PlaybackRecord? {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let data = try Data(contentsOf: url)
                    let record = try JSONDecoder().decode(PlaybackRecord.self, from: data)
                    guard record.version == 1, !record.albumID.isEmpty, record.photoID != "" else {
                        appLog.error("Settings format is invalid.")
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: record)
                } catch {
                    let error = error as NSError
                    if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
                        appLog.error("Settings read failed (\(error.domain, privacy: .public) \(error.code)).")
                    }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func write(_ record: PlaybackRecord, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            let saved: Bool
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(record).write(to: url, options: .atomic)
                saved = true
            } catch {
                let error = error as NSError
                appLog.error("Settings write failed (\(error.domain, privacy: .public) \(error.code)).")
                saved = false
            }
            Task { @MainActor in completion(saved) }
        }
    }
}
