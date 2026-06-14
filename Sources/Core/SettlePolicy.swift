// SettlePolicy — what the menu host does when a display-config change has SETTLED (#keeps-3 auto path).
// Pure decision, lifted out of the host's I/O so the "don't fight me on a non-change" guards are unit-testable
// (the Restore.decide discipline, applied to the trigger). Both gates were surfaced by dogfeel (2026-06-14):
//   • a display SLEEP collapses CGGetActiveDisplayList to empty ⇒ fingerprint = SHA-256 of nothing (degenerate)
//   • sleep/wake re-fires the reconfig with the SAME fingerprint we were already in (no real change)
// Manual Save/Restore bypass this entirely — the user can always force an action.
import Foundation

public enum SettleAction: Equatable {
  case restore  // known config, genuinely entered (came back from a different one) → put windows back
  case capture  // unknown config, genuinely entered → learn it
  case skipNoChange  // settled on the SAME config we were already in (sleep/wake) → don't revert hand-moves
  case skipNoDisplays  // no active displays (all asleep) → nothing real to capture or restore
}

public enum SettlePolicy {
  /// Decide what a settled config-change should do.
  /// - `degenerate`: no active displays (the empty-set fingerprint a display sleep produces).
  /// - `lastSettled`: the last real config we acted on (`nil` until the first settle after launch).
  /// - `known`: a snapshot already exists for `fingerprint`.
  public static func decide(
    fingerprint: String, degenerate: Bool, lastSettled: String?, known: Bool
  ) -> SettleAction {
    if degenerate { return .skipNoDisplays }  // gate A: displays asleep ⇒ meaningless config
    if fingerprint == lastSettled { return .skipNoChange }  // gate B: no net change ⇒ don't fight a hand-move
    return known ? .restore : .capture
  }
}
