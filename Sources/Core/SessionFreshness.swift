// SessionFreshness — does this snapshot's window ids still mean anything?
//
// The defect (#keeps-5): `cgWindowId` is a WindowServer handle that dies with the login session and gets
// RECYCLED from low numbers on the next boot. Snapshots persist indefinitely and `capturedAt` — written since
// keeps-capture/v1 — had never been read by anything. So after a reboot, restore matched a saved layout against
// ids that now belong to whatever happened to start first, and the review register's example is the honest one:
// "a Terminal window gets shoved to Slack's old frame".
//
// Why boot time and not an age clock: a snapshot from THIS boot is good no matter how old, and one from a
// previous boot is worthless no matter how fresh. Wall-clock age gets both directions wrong.
//
// This is the SettlePolicy discipline applied to trust — the decision is pure and unit-testable, the I/O
// (`bootTime()`) sits at the edge. A restore cannot be tested by rebooting the machine that runs the tests.
import Foundation

public enum SessionFreshness {

  public enum Verdict: Equatable {
    case current  // captured during this login session — ids are live, proceed
    case priorSession  // captured before this boot — every id is churned, refuse the whole run
    case unknownBoot  // couldn't read boot time — refuse, because guessing here mutates real windows
  }

  /// Pure: is `capturedAt` from the session that began at `bootTime`?
  ///
  /// Fails CLOSED. `bootTime == nil` returns `.unknownBoot`, not a pass-through: the cost of wrongly refusing
  /// is a restore the user re-triggers with a Save; the cost of wrongly proceeding is a window mutated to a
  /// stranger's frame. Those are not symmetric, so the tie doesn't go to convenience.
  public static func decide(capturedAt: Date, bootTime: Date?) -> Verdict {
    guard let bootTime else { return .unknownBoot }
    return capturedAt >= bootTime ? .current : .priorSession
  }

  /// The gate every acting caller asks. `false` ⇒ refuse the whole run.
  ///
  /// This exists because the first build put the gate inside `Restore.restore` and claimed in a comment that
  /// "every caller is covered by construction" — which was false. `Carry.carry` reaches the same windows
  /// through `Restore.classify`, not `restore`, so `--carry-once` and the menu's carry phase bypassed it
  /// entirely. Same defect shape as the review's Required-1: a confident claim about why something is safe,
  /// written after tracing one path of two. One function, called by both, is the only version that stays true.
  public static func isCurrent(_ snapshot: Snapshot) -> Bool {
    decide(capturedAt: snapshot.capturedAt, bootTime: bootTime()) == .current
  }

  /// When this machine booted, via `kern.boottime`.
  ///
  /// Caveat worth knowing (brief's Known Unknowns, from the #keeps-5 review): the kernel recomputes this on
  /// CLOCK STEPS, not only at boot — a backward step (bad NTP, dead PRAM battery, a VM resuming) shifts it
  /// earlier and could let a prior-session snapshot through. The per-window identity guard is the backstop for
  /// every such case except same-app id reuse. A persisted boot-session UUID has no such failure mode and is
  /// the noted upgrade if this ever bites.
  public static func bootTime() -> Date? {
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
  }
}
