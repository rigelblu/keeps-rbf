// ColdStartMatch — how keeps finds your windows again after a reboot, when the ids it saved are dead.
//
// #keeps-5.4. `5.1` established that a snapshot from a previous login session cannot be matched by
// `cgWindowId` — the ids are recycled and matching on them moves the wrong windows. Its first answer was to
// refuse the whole run. Dogfood killed that answer on the day it shipped (2026-07-28): the first post-reboot
// Restore did nothing, and the remedy keeps offered — "Save again" — would have OVERWRITTEN the very layout
// the user was trying to restore, permanently, because `Store.save` keeps no history. The feature turned
// "can't restore right now" into "gone forever".
//
// The fix is to notice what actually died. Only `cgWindowId` is session-scoped. `bundleId`, `frame`,
// `displayUUID` and `spaceUUID` all survive a reboot intact — so the layout IS restorable, by matching on
// APP + POSITION instead of on id.
//
// WHY POSITION AND NOT TITLE. Titles would be the strongest signal and are not available: `kCGWindowName` is
// empty without Screen Recording, and on the real dogfood snapshot **all 37 windows had empty titles**. So
// title matching was never written — it would have been dead code dressed as rigour.
//
// WHY AN ARBITRARY-LOOKING BIJECTION IS ACTUALLY RIGHT. With no titles, seven Bear windows are
// indistinguishable from each other. That reads like a problem and isn't: the user's goal is "my layout looks
// the way I left it", and filling the seven captured slots with the seven live Bear windows achieves that
// exactly, whichever note lands where. The SET is restored even when the assignment isn't provably
// per-window. Reading-order pairing then makes the choice deterministic and least-surprising — the top-left
// live window takes the top-left captured slot, so relative arrangement is preserved rather than shuffled.
//
// SAFETY. Grouping by `bundleId` is what keeps this honest: a captured window is only ever matched to a live
// window of the SAME app, so the cross-app harm `5.1` exists to prevent ("a Terminal window gets shoved to
// Slack's old frame") remains impossible here. The residual — Bear window A landing where Bear window B was
// — is a different and much milder class, and is the price of restoring anything at all.
import CoreGraphics
import Foundation

public enum ColdStartMatch {

  /// The live side of the match, reduced to what the decision needs. Plain data so the whole thing is pure.
  public struct LiveWindow: Equatable {
    public let id: CGWindowID
    public let identity: String  // AppIdentity-encoded owner — the grouping key
    public let frame: WindowFrame?
    public init(id: CGWindowID, identity: String, frame: WindowFrame?) {
      self.id = id
      self.identity = identity
      self.frame = frame
    }
  }

  /// Reading order: top-to-bottom, then left-to-right, with a final id tiebreak so the sort is TOTAL.
  ///
  /// The id tiebreak is not decoration. `sorted(by:)` is not stable in Swift (the same lesson `#keeps-20`
  /// banked for condition ordering), so two windows at identical coordinates would otherwise pair
  /// differently between runs — and a restore that shuffles windows differently each time it runs is its own
  /// defect. Windows with no readable frame sort last: they carry no position signal, so they take whatever
  /// slots are left rather than displacing a window that does.
  static func readingOrder(_ frame: WindowFrame?, _ id: CGWindowID) -> (Int, Int, Int, UInt32) {
    guard let f = frame else { return (1, 0, 0, id) }  // 1 ⇒ after every positioned window
    return (0, f.y, f.x, id)
  }

  private static func before(_ a: (Int, Int, Int, UInt32), _ b: (Int, Int, Int, UInt32)) -> Bool {
    if a.0 != b.0 { return a.0 < b.0 }
    if a.1 != b.1 { return a.1 < b.1 }
    if a.2 != b.2 { return a.2 < b.2 }
    return a.3 < b.3
  }

  /// Is this live window one CAPTURE would have stored? The candidate gate, lifted out of the I/O so the
  /// rule is testable without a live WindowServer — the `SettlePolicy` / `Restore.decide` discipline.
  ///
  /// Mirrors `Capture.decide`'s chain deliberately rather than approximating it. The first build gated on
  /// ownership alone, and on the live fleet **122 of 154 normal-layer windows were junk** — 1×1 utility
  /// windows, 1800×39 chrome. Real windows were matched to those, classified `minimized`, and starved of
  /// their slots: 26 of 29 came back that way. The candidate set IS the correctness of this feature.
  public static func isCandidate(normalLayer: Bool, frame: WindowFrame?, hasSpace: Bool) -> Bool {
    guard normalLayer else { return false }  // menus, panels, status items, shadows
    guard let f = frame, f.w > 0, f.h > 0 else { return false }  // degenerate — capture drops these too
    return hasSpace  // no Space ⇒ minimized/junk; matching one starves a window that can actually be placed
  }

  /// Map each captured window's (dead) `cgWindowId` to the live `cgWindowId` that should stand in for it.
  ///
  /// Pure. Windows with no match are simply absent from the result — the caller then classifies them exactly
  /// as it always has (`gone`), so no new "unmatched" concept leaks into the restore truth table.
  public static func assign(captured: [CapturedWindow], live: [LiveWindow]) -> [CGWindowID: CGWindowID] {
    // Sticky (all-desktops) windows are excluded for the same reason `decide` skips them: they cannot be
    // frame-restored at all, so claiming a live window for one would starve a window that CAN be placed.
    let byApp = Dictionary(grouping: captured.filter { !$0.sticky }, by: \.bundleId)
    let liveByApp = Dictionary(grouping: live, by: \.identity)

    var map: [CGWindowID: CGWindowID] = [:]
    for (bundleId, caps) in byApp {
      guard let lives = liveByApp[bundleId], !lives.isEmpty else { continue }  // app not running ⇒ all gone

      let capsSorted = caps.sorted {
        before(readingOrder($0.frame, $0.cgWindowId), readingOrder($1.frame, $1.cgWindowId))
      }
      let livesSorted = lives.sorted {
        before(readingOrder($0.frame, $0.id), readingOrder($1.frame, $1.id))
      }

      // Pair positionally, one-to-one. `zip` truncates to the shorter side by construction, which is exactly
      // the wanted behaviour at BOTH mismatches: fewer live than captured ⇒ the extra captured windows fall
      // through to `gone`; more live than captured ⇒ the extras are left alone rather than being moved
      // somewhere the user never asked for.
      for (cap, liveWindow) in zip(capsSorted, livesSorted) {
        map[cap.cgWindowId] = liveWindow.id
      }
    }
    return map
  }
}
