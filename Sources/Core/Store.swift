// Store — one JSON snapshot per configuration fingerprint, atomic write (Foundation .atomic = temp+rename),
// under Application Support. The on-disk source of truth #stay-3 will read back.
import Foundation

public struct Store {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("com.rigelblu.stay/configs", isDirectory: true)
        }
    }

    public func url(for fingerprint: String) -> URL {
        directory.appendingPathComponent("\(fingerprint).json")
    }

    @discardableResult
    public func save(_ snapshot: Snapshot) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let dest = url(for: snapshot.configFingerprint)
        try encoder.encode(snapshot).write(to: dest, options: .atomic)   // temp file + rename under the hood
        return dest
    }

    public func load(fingerprint: String) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Snapshot.self, from: Data(contentsOf: url(for: fingerprint)))
    }
}
