// ConfigIdentity — the configuration fingerprint = the snapshot key. v0.3.0: sorted set of active
// display UUIDs, hashed to a stable, filename-safe id. Arrangement is a later refinement (Q9).
import Foundation
import AppKit        // CGDisplayCreateUUIDFromDisplayID is a ColorSync symbol, surfaced via the AppKit umbrella
import CoreGraphics
import CryptoKit

public enum ConfigIdentity {
    /// UUID strings of the currently-active displays, sorted (order-independent key).
    public static func activeDisplayUUIDs() -> [String] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).compactMap { uuid($0) }.sorted()
    }

    public static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }

    /// Stable, filename-safe key for the current display configuration (16 hex chars of SHA-256).
    public static func fingerprint() -> String { fingerprint(of: activeDisplayUUIDs()) }

    /// Pure fingerprint of a display-UUID set — sorted here so it's order-independent for any caller.
    public static func fingerprint(of uuids: [String]) -> String {
        let digest = SHA256.hash(data: Data(uuids.sorted().joined(separator: "+").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
