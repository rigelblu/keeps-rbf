// CarryMissTally — #keeps-36.2: how many times in a row the carry reached a window's desktop and found it neither on
// screen nor in AX (`Carry.OnScreenCheck.missedNoElement`). Two in a row with nothing between that showed the window
// is real, and keeps stops offering it. One miss isn't proof: real windows have missed once and come home on the
// next try (Claude 25469, Codex 2159); the strips that repeat were never moved.
//
// Pure value type. The menu-bar app holds the one instance, in memory only — a relaunch starts every window fresh,
// and nothing here is ever saved. Keyed by the LIVE window id the carry acted on, never the saved record's id: after
// a cold start the same record can pair with a different live window, and that window starts at zero.
import CoreGraphics

public struct CarryMissTally: Equatable, Sendable {
  /// Misses in a row at which keeps stops offering the window.
  public static let stopAfter = 2

  private var misses: [CGWindowID: Int] = [:]

  public init() {}

  /// One carry run's legs: a quiet miss adds one; `found` or `missedWithElement` resets the window — it's real.
  /// A leg that never reached the on-screen check (`nil`) is no evidence either way.
  public mutating func record(_ outcomes: [Carry.Outcome]) {
    for o in outcomes {
      switch o.onScreenCheck {
      case .missedNoElement: misses[o.cgWindowId, default: 0] += 1
      case .found, .missedWithElement: misses[o.cgWindowId] = nil
      case nil: break
      }
    }
  }

  /// Ids with one or more misses — the ones a Restore or carry should look for on screen or in AX.
  public var tracked: Set<CGWindowID> { Set(misses.keys) }

  /// Ids keeps no longer offers.
  public var notOffered: Set<CGWindowID> { Set(misses.filter { $0.value >= Self.stopAfter }.keys) }

  /// Forget these ids — something showed they're real. Returns the ones that were not offered, so the host can say
  /// each is offered again.
  public mutating func clear(_ ids: Set<CGWindowID>) -> Set<CGWindowID> {
    let back = ids.intersection(notOffered)
    for id in ids { misses[id] = nil }
    return back
  }

  /// One carry run, in one step and in this order: forget what the run saw real (at its gather), then record its
  /// legs — so a window seen real and then missed by the same run ends at one miss, not cleared. Returns the
  /// windows coming back into the offer and the ones this run stopped offering.
  public mutating func absorb(seenReal: Set<CGWindowID>, outcomes: [Carry.Outcome])
    -> (back: Set<CGWindowID>, newlyStopped: Set<CGWindowID>)
  {
    let before = notOffered
    let back = clear(seenReal)
    record(outcomes)
    return (back, notOffered.subtracting(before))
  }

  /// The one rule `Restore` and `Carry` both apply: a tracked window read on screen (`kCGWindowIsOnscreen`) or
  /// found in AX (`live.reachable`) is real, at any count.
  public static func seenReal(
    tracked: Set<CGWindowID>, reachable: Set<CGWindowID>, onScreen: Set<CGWindowID>
  ) -> Set<CGWindowID> {
    tracked.intersection(reachable.union(onScreen))
  }
}
