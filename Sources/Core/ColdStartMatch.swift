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
// APP + GEOMETRY instead of on id (#keeps-31 — the geometry rule is below).
//
// WHY GEOMETRY AND NOT TITLE. Titles would be the strongest signal and are not available: `kCGWindowName` is
// empty without Screen Recording, and on the real dogfood snapshot **all 37 windows had empty titles**. So
// title matching was never written — it would have been dead code dressed as rigour.
//
// WHY A PAIRING NEEDS A SHARED GEOMETRY SIGNAL, AND WHY ORDER ALONE NEVER PAIRS (#keeps-31). The first shape
// of this file sorted both sides in reading order and `zip`ped them, arguing that seven title-less Bear windows
// are indistinguishable so any bijection restores the SET. That holds when the windows are the same kind. On
// 2026-08-26 the set mixed real windows with app chrome — Safari's link-preview strip, Chrome's tab-hover
// strips — because capture keeps any layer-0 window with a Space and the candidate gate below mirrors capture
// on purpose. Reading order then paired across the strip/real boundary: a real 2560×1425 Chrome window sitting
// EXACTLY at its saved frame was paired with a 5120×46 strip record and told to move off-screen, and the only
// real Chrome record was declared gone because the strips' records had consumed both live windows first.
//
// The rule now: three tiers, each within `Restore.frameTolerance`, each claiming across the whole app before
// the next runs — exact frame → same position (size differs) → same size (position differs). A captured window
// with no live window in any tier is absent from the map and classifies `gone`. A size-class ratio was measured
// and rejected first: across 8 stored snapshots real↔real ratios reach 4.8× and real↔strip go down to 1.6×, so
// no threshold separates them (the same overlap that killed #keeps-25's capture-side filter). The Bear bijection
// argument survives, bounded: same-size windows still fill their slots, nearest-first, deterministically.
//
// It rounds toward "never a wrong move": an app that relaunches at a new size AND a new position is `gone`
// until the next Save, and that count is watched (per-tier trace line) rather than assumed rare.
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
  /// Since #keeps-31 this orders only the CAPTURED side — the sequence in which records get to claim within a
  /// tier — and is no longer a pairing rule; live windows are picked by geometry, nearest first. The id
  /// tiebreak is not decoration: `sorted(by:)` is not stable in Swift (the same lesson `#keeps-20` banked for
  /// condition ordering), so two records at identical coordinates would otherwise claim in a different order
  /// between runs — and a restore that shuffles windows differently each time it runs is its own defect.
  /// A captured frame is never optional (`CapturedWindow.frame`); frameless LIVE windows are dropped before
  /// pairing (`assign`), so this needs no "sort last" branch any more.
  static func readingOrder(_ f: WindowFrame, _ id: CGWindowID) -> (Int, Int, UInt32) {
    (f.y, f.x, id)
  }

  private static func before(_ a: (Int, Int, UInt32), _ b: (Int, Int, UInt32)) -> Bool {
    if a.0 != b.0 { return a.0 < b.0 }
    if a.1 != b.1 { return a.1 < b.1 }
    return a.2 < b.2
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

  /// The result of a cold-start pairing: the id map every consumer reads, plus how each pairing was earned so
  /// a run's guesses are readable from the trace. `Restore.resolveIds` is the only caller — for both sessions
  /// since #keeps-30 — it logs the counts and hands `map` on; nothing below `Restore.classify(remap:)` sees
  /// this type (#keeps-31).
  public struct Assignment: Equatable {
    public let map: [CGWindowID: CGWindowID]
    public let exact: Int  // tier 1 — live frame within tolerance on every edge
    public let position: Int  // tier 2 — same origin, size differs (a content-driven strip; a window resized in place)
    public let size: Int  // tier 3 — same size, moved (an app relaunched elsewhere)
    public var count: Int { map.count }
  }

  /// Map each captured window's (dead) `cgWindowId` to the live `cgWindowId` that should stand in for it.
  ///
  /// Pure. Windows with no match are simply absent from the result — the caller then classifies them exactly
  /// as it always has (`gone`), so no new "unmatched" concept leaks into the restore truth table.
  ///
  /// Three passes per app, in tier order, each over every still-unpaired captured window (reading order, for
  /// determinism) before the next tier starts. The order is load-bearing, not cosmetic: a per-window cascade
  /// would let a same-size sibling claim, by tier 3, a live window that a later captured record matches
  /// exactly — stealing a window that is already home, the very defect this rule exists to end.
  public static func assign(
    captured: [CapturedWindow], live: [LiveWindow], tolerance: Int = Restore.frameTolerance
  ) -> Assignment {
    // Sticky (all-desktops) windows are excluded for the same reason `decide` skips them: they cannot be
    // frame-restored at all, so claiming a live window for one would starve a window that CAN be placed.
    let byApp = Dictionary(grouping: captured.filter { !$0.sticky }, by: \.bundleId)
    let liveByApp = Dictionary(grouping: live, by: \.identity)

    var map: [CGWindowID: CGWindowID] = [:]
    var exact = 0, position = 0, size = 0
    for (bundleId, caps) in byApp {
      guard let lives = liveByApp[bundleId], !lives.isEmpty else { continue }  // app not running ⇒ all gone

      let capsSorted = caps.sorted {
        before(readingOrder($0.frame, $0.cgWindowId), readingOrder($1.frame, $1.cgWindowId))
      }
      // A live window with no readable frame carries no geometry signal, so it can never pair — it used to
      // sort last and take a leftover slot, which handed a window that can't even be placed to a record.
      var unclaimed = lives.compactMap { w in w.frame.map { (id: w.id, frame: $0) } }

      func pass(_ tier: inout Int, _ pairs: (WindowFrame, WindowFrame) -> Bool) {
        for cap in capsSorted where map[cap.cgWindowId] == nil {
          // Nearest centre first, then id: a total order, so identical inputs pair identically every run
          // (`sorted(by:)` is not stable — the #keeps-20 lesson).
          let pick = unclaimed.filter { pairs(cap.frame, $0.frame) }.min { a, b in
            let da = cap.frame.centreDistanceSquared(to: a.frame)
            let db = cap.frame.centreDistanceSquared(to: b.frame)
            return da != db ? da < db : a.id < b.id
          }
          guard let pick else { continue }
          map[cap.cgWindowId] = pick.id
          unclaimed.removeAll { $0.id == pick.id }
          tier += 1
        }
      }
      pass(&exact) { $0.matches($1, tolerance: tolerance) }
      pass(&position) { $0.samePosition($1, tolerance: tolerance) }
      pass(&size) { $0.sameSize($1, tolerance: tolerance) }
    }
    return Assignment(map: map, exact: exact, position: position, size: size)
  }
}
