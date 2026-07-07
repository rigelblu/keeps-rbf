// CarryAffordance — the #keeps-13 one-tap offer gate. #keeps-3 silently restores the windows reachable on the
// current Space (phase 1, automatic); when captured windows remain stranded on OTHER Spaces, this decides
// whether to OFFER the visible carry (phase 2) and for how many windows. Pure decision lifted out of the
// menu-bar host so offer/replace/clear is unit-testable — the SettlePolicy discipline, applied to the affordance.
//
// Model (B), decided 2026-06-17: the carry is NEVER silent-automatic (it hijacks the cursor + active Space, so
// auto-running it on every dock/undock would surprise a user mid-task), so the host only ever OFFERS it. A fresh
// restore — auto on reconfig, or the manual menu — REPLACES any prior offer rather than stacking (newest restore
// wins, which this enforces by construction: one optional in, one optional out), and `deferred == 0` clears it.
import Foundation

/// A pending one-tap carry offer: the off-Space windows a settled config left behind. `count` is a HINT for the
/// badge/notification only; the carry re-classifies live window state at tap time (the Restore.classify seam),
/// so the set it actually carries is recomputed fresh — never this cached number.
public struct PendingCarry: Equatable, Sendable {
  public let fingerprint: String  // the config this offer belongs to — lets the host reject a stale-config tap
  public let count: Int  // # deferred-background windows offered (always ≥ 1 whenever a PendingCarry exists)
  public init(fingerprint: String, count: Int) {
    self.fingerprint = fingerprint
    self.count = count
  }
}

public enum CarryAffordance {
  /// The pending carry offer after a restore settled for `fingerprint`, leaving `deferred` windows on other
  /// Spaces. `nil` ⇒ no offer (nothing stranded, or phase 1 reached everything). A non-nil result REPLACES any
  /// prior offer — the host assigns it to its single pending slot, so a newer restore always supersedes an older.
  public static func afterRestore(fingerprint: String, deferred: Int) -> PendingCarry? {
    deferred > 0 ? PendingCarry(fingerprint: fingerprint, count: deferred) : nil
  }
}
