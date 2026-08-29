// The captured layout — the source of truth #keeps-3 restore reads back. Codable, schema-versioned.
import Foundation

public let captureSchema = "keeps-capture/v1"

public struct WindowFrame: Codable, Equatable {
  public var x: Int, y: Int, w: Int, h: Int
}

public struct CapturedWindow: Codable, Equatable {
  public var bundleId: String
  public var pid: Int32
  public var title: String?  // best-effort: kCGWindowName is empty without Screen Recording
  public var cgWindowId: UInt32
  public var displayUUID: String?  // nil when unattributable
  public var desktopOrdinal: Int?  // 1-based per-display; nil when sticky/unattributable
  public var spaceUUID: String?  // the desktop's STABLE identity — persists across reboot while the int
  // spaceIds churn (#keeps-1). #keeps-3 restore anchors on this to find the
  // desktop and compute its live global ⌥⌘N target.
  public var frame: WindowFrame
  public var spaceIds: [Int]
  public var sticky: Bool  // not on exactly one space (all-spaces / minimized / none) → don't desktop-restore
  public var onScreen: Bool
}

/// A display's `CGDisplayBounds` in global points — where the display sat when the layout was saved (#keeps-15).
/// `Int` like `WindowFrame`: `CGDisplayBounds` is integral on every Retina point grid, so the narrowing is lossless.
public struct DisplayBounds: Codable, Equatable {
  public var x: Int, y: Int, w: Int, h: Int
  public init(x: Int, y: Int, w: Int, h: Int) {
    self.x = x; self.y = y; self.w = w; self.h = h
  }
}

public struct DisplaySummary: Codable, Equatable {
  public var uuid: String
  public var desktopCount: Int
  public var activeDesktopOrdinal: Int
  /// #keeps-15: optional so every `keeps-capture/v1` file saved before it decodes to `nil` and resolves as
  /// absolute — today's behaviour, named on the trace. `nil` on a new save means the uuid→bounds join missed.
  public var bounds: DisplayBounds? = nil
}

public struct Snapshot: Codable {
  public var schema: String
  public var capturedAt: Date
  public var configFingerprint: String
  public var displays: [DisplaySummary]
  public var windows: [CapturedWindow]
}

// MARK: - #keeps-15: resolve saved frames against the live display origins

/// A live display as the resolve needs it: uuid + bounds. `Restore.Topology` projects into this at the call
/// site so this file never points at the restore engine (it imports `Foundation` only).
public struct LiveDisplay: Equatable {
  public let uuid: String
  public let bounds: DisplayBounds
  public init(uuid: String, bounds: DisplayBounds) {
    self.uuid = uuid; self.bounds = bounds
  }
}

/// What `Snapshot.resolved(against:)` did per display, in the snapshot's `displays` order — the trace formats it.
public enum ResolveNote: Equatable {
  /// No saved display carries bounds (a pre-#keeps-15 file): the whole snapshot is absolute. The only note.
  case noSavedBounds
  case unchanged(uuid: String)
  case shifted(uuid: String, dx: Int, dy: Int)
  case absolute(uuid: String, reason: AbsoluteReason)

  public enum AbsoluteReason: Equatable {
    case noSavedBounds  // this display was saved with `bounds: nil` while siblings carry bounds
    case resized(saved: DisplayBounds, live: DisplayBounds)  // same uuid, different point size — `keeps-15.2`
    case absent  // no live display with this uuid (cannot happen under the same fingerprint; total anyway)
  }
}

extension Snapshot {
  /// Translate every saved frame into today's coordinates: for each saved display with bounds and a live
  /// counterpart of the same size, its windows move by (live origin − saved origin). Every uncertain case
  /// leaves that display's windows exactly as saved — the direction that reproduces pre-#keeps-15 behaviour.
  /// Pure. The returned snapshot is for classification only and must never be saved: its `displays` still
  /// carry the *saved* bounds, so a second load would shift its frames twice.
  public func resolved(against live: [LiveDisplay]) -> (snapshot: Snapshot, notes: [ResolveNote]) {
    guard displays.contains(where: { $0.bounds != nil }) else { return (self, [.noSavedBounds]) }
    var deltas: [String: (dx: Int, dy: Int)] = [:]
    var notes: [ResolveNote] = []
    for d in displays {
      guard let saved = d.bounds else {
        notes.append(.absolute(uuid: d.uuid, reason: .noSavedBounds))
        continue
      }
      guard let l = live.first(where: { $0.uuid == d.uuid }) else {
        notes.append(.absolute(uuid: d.uuid, reason: .absent))
        continue
      }
      guard saved.w == l.bounds.w, saved.h == l.bounds.h else {  // exact, never ±tolerance: a display doesn't drift
        notes.append(.absolute(uuid: d.uuid, reason: .resized(saved: saved, live: l.bounds)))
        continue
      }
      let dx = l.bounds.x - saved.x, dy = l.bounds.y - saved.y
      if dx == 0, dy == 0 {
        notes.append(.unchanged(uuid: d.uuid))
      } else {
        deltas[d.uuid] = (dx, dy)
        notes.append(.shifted(uuid: d.uuid, dx: dx, dy: dy))
      }
    }
    var out = self
    out.windows = windows.map { w in
      // Shift by the window's RECORDED display, never the display under its centre (grill Q2).
      guard let u = w.displayUUID, let d = deltas[u] else { return w }
      var moved = w
      moved.frame.x += d.dx
      moved.frame.y += d.dy
      return moved
    }
    return (out, notes)
  }
}
