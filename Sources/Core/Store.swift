// Store — one JSON snapshot per configuration fingerprint, atomic write (Foundation .atomic = temp+rename),
// under Application Support. The on-disk source of truth #keeps-3 will read back.
import Foundation

public struct Store {
  public let directory: URL

  public init(directory: URL? = nil) {
    if let directory {
      self.directory = directory
    } else {
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      self.directory = appSupport.appendingPathComponent(
        "com.rigelblu.keeps/configs", isDirectory: true)
    }
  }

  public func url(for fingerprint: String) -> URL {
    directory.appendingPathComponent("\(fingerprint).json")
  }

  /// Is there a snapshot for this config? The arbitration hinge (#keeps-3): a KNOWN config restores, an
  /// UNKNOWN one captures. Invalid fingerprints are "absent" and never touch the filesystem.
  public func exists(fingerprint: String) -> Bool {
    Store.isValidFingerprint(fingerprint)
      && FileManager.default.fileExists(atPath: url(for: fingerprint).path)
  }

  @discardableResult
  public func save(_ snapshot: Snapshot) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let dest = url(for: snapshot.configFingerprint)
    try encoder.encode(snapshot).write(to: dest, options: .atomic)  // temp file + rename under the hood
    return dest
  }

  public func load(fingerprint: String) throws -> Snapshot {
    // Fingerprint is an internal SHA-256 hex id, never user input — but validate its shape anyway so a
    // crafted value can't escape the configs dir (path traversal), and refuse an unknown schema rather
    // than mis-decode a future/foreign file (#keeps-2 review entry-conditions, now that restore consumes it).
    guard Store.isValidFingerprint(fingerprint) else {
      throw StoreError.invalidFingerprint(fingerprint)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snap = try decoder.decode(Snapshot.self, from: Data(contentsOf: url(for: fingerprint)))
    guard snap.schema == captureSchema else {
      throw StoreError.schemaMismatch(found: snap.schema, expected: captureSchema)
    }
    return snap
  }

  /// A fingerprint is exactly 16 lowercase-hex chars (8 bytes of SHA-256) — anything else can't be one of
  /// ours and must never become a file path.
  static func isValidFingerprint(_ fp: String) -> Bool {
    fp.count == 16 && fp.allSatisfy { "0123456789abcdef".contains($0) }
  }
}

public enum StoreError: Error, Equatable {
  case invalidFingerprint(String)
  case schemaMismatch(found: String, expected: String)
}
