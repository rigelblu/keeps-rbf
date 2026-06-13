// The captured layout — the source of truth #stay-3 restore reads back. Codable, schema-versioned.
import Foundation

public let captureSchema = "stay-capture/v1"

public struct WindowFrame: Codable, Equatable {
    public var x: Int, y: Int, w: Int, h: Int
}

public struct CapturedWindow: Codable, Equatable {
    public var bundleId: String
    public var pid: Int32
    public var title: String?          // best-effort: kCGWindowName is empty without Screen Recording
    public var cgWindowId: UInt32
    public var displayUUID: String?    // nil when unattributable
    public var desktopOrdinal: Int?    // 1-based per-display; nil when sticky/unattributable
    public var spaceUUID: String?      // the desktop's STABLE identity — persists across reboot while the int
                                       // spaceIds churn (#stay-1). #stay-3 restore anchors on this to find the
                                       // desktop and compute its live global ⌥⌘N target.
    public var frame: WindowFrame
    public var spaceIds: [Int]
    public var sticky: Bool            // not on exactly one space (all-spaces / minimized / none) → don't desktop-restore
    public var onScreen: Bool
}

public struct DisplaySummary: Codable, Equatable {
    public var uuid: String
    public var desktopCount: Int
    public var activeDesktopOrdinal: Int
}

public struct Snapshot: Codable {
    public var schema: String
    public var capturedAt: Date
    public var configFingerprint: String
    public var displays: [DisplaySummary]
    public var windows: [CapturedWindow]
}
