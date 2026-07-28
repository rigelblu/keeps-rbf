// #keeps-5 — the two checks that decide whether restore is allowed to touch a window at all.
//
// WHAT THIS FILE COVERS, and what it deliberately does not. The defect is that `cgWindowId` dies with the
// login session while snapshots persist, so the real subject is a REBOOT — and no unit test can reboot the
// machine running it. What is pinned here is therefore the pure half: the truth table both checks reduce to,
// with boot time and app identity injected. The impure half (does `kern.boottime` read correctly, does a
// login-item launch keep the AX grant) is verified by S6-S9 in `test-suite/review.md`, by hand, on hardware.
//
// That split is the whole reason `SessionFreshness.decide` takes a `Date?` instead of reading the sysctl
// itself — the SettlePolicy discipline, applied to trust.
import Foundation
import Testing

@testable import Core

@Suite struct SessionTrustTests {

  // MARK: - The session gate (whole-run)

  private let boot = Date(timeIntervalSince1970: 1_000_000)

  @Test func snapshotFromThisSessionIsCurrent() {
    let after = boot.addingTimeInterval(60)
    #expect(SessionFreshness.decide(capturedAt: after, bootTime: boot) == .current)
  }

  @Test func snapshotFromBeforeBootIsPriorSession() {
    let before = boot.addingTimeInterval(-1)  // one second is enough; the axis is the boundary, not the gap
    #expect(SessionFreshness.decide(capturedAt: before, bootTime: boot) == .priorSession)
  }

  @Test func capturedExactlyAtBootIsCurrent() {
    // The boundary is inclusive on purpose: a snapshot stamped at the same instant the session began belongs
    // to that session. Exclusive would refuse a legitimate capture for a rounding artifact.
    #expect(SessionFreshness.decide(capturedAt: boot, bootTime: boot) == .current)
  }

  @Test func unreadableBootTimeRefuses() {
    // FAIL CLOSED. The costs are not symmetric: wrongly refusing costs a Save the user re-clicks; wrongly
    // proceeding moves a real window to a stranger's frame. A nil must never read as "probably fine".
    let recent = boot.addingTimeInterval(9_999)
    #expect(SessionFreshness.decide(capturedAt: recent, bootTime: nil) == .unknownBoot)
    #expect(SessionFreshness.decide(capturedAt: recent, bootTime: nil) != .current)
  }

  @Test func ageAloneNeverDecidesIt() {
    // The property that makes boot time the right axis and a staleness clock the wrong one: a MUCH older
    // snapshot from this session is trustworthy, and a MUCH fresher one from the previous session is not.
    let ancientButThisSession = boot.addingTimeInterval(1)
    let freshButLastSession = boot.addingTimeInterval(-1)
    #expect(SessionFreshness.decide(capturedAt: ancientButThisSession, bootTime: boot) == .current)
    #expect(SessionFreshness.decide(capturedAt: freshButLastSession, bootTime: boot) == .priorSession)
  }

  @Test func isCurrentIsTheOneGateBothActingPathsAsk() {
    // The 2nd-pass finding: the gate first lived inside `Restore.restore`, with a comment claiming every
    // caller was "covered by construction". False — `Carry.carry` reaches the same windows through
    // `Restore.classify`, so `--carry-once` and the menu's carry phase bypassed it entirely. The per-window
    // identity guard would still have stopped an impostor, but the run would have reported N mismatches and
    // never the one real cause, which is the whole point of the whole-run/per-window split.
    //
    // `isCurrent` is now the single function both call. This pins its agreement with `decide` so the two can
    // never diverge — the same "one definition, two callers" discipline as `AppIdentity.encode`.
    let snapCurrent = Snapshot(
      schema: captureSchema, capturedAt: Date(timeIntervalSince1970: 2_000_000),
      configFingerprint: "fp", displays: [], windows: [])
    let stale = Snapshot(
      schema: captureSchema, capturedAt: Date(timeIntervalSince1970: 1),
      configFingerprint: "fp", displays: [], windows: [])
    // Boot time is real here, so `snapCurrent` (dated 1970+2e6) is genuinely prior-session on any live Mac —
    // which is the assertion that matters: a snapshot older than this boot is refused, whatever its date.
    #expect(SessionFreshness.isCurrent(stale) == false)
    #expect(SessionFreshness.isCurrent(snapCurrent) == false)
    // And a snapshot stamped now is accepted — the positive leg, so the gate isn't just "always false".
    let fresh = Snapshot(
      schema: captureSchema, capturedAt: Date(), configFingerprint: "fp", displays: [], windows: [])
    #expect(SessionFreshness.isCurrent(fresh) == true)
  }

  // MARK: - Identity encoding

  @Test func identityFallsBackToPidWhenBundleIdIsAbsent() {
    // Capture has always stored `bundleIdentifier ?? "pid:<pid>"`. A guard comparing a raw nil-able bundle id
    // would make every window of a bundle-less regular app permanently mismatch ITSELF — caught in review
    // before it was written. Both sides call this one function so they cannot drift.
    #expect(AppIdentity.encode(bundleId: nil, pid: 4711) == "pid:4711")
    #expect(AppIdentity.encode(bundleId: "com.example.app", pid: 4711) == "com.example.app")
  }

  // MARK: - The identity guard (per-window)

  private func cap(bundleId: String = "com.example.app") -> CapturedWindow {
    CapturedWindow(
      bundleId: bundleId, pid: 42, title: "t", cgWindowId: 1,
      displayUUID: "DISP-A", desktopOrdinal: 2, spaceUUID: "S",
      frame: WindowFrame(x: 100, y: 100, w: 800, h: 600),
      spaceIds: [9], sticky: false, onScreen: true)
  }

  @Test func impostorIsSkippedNotPlaced() {
    // Guard site 1: a reachable hit gets placed via AX. This is the review register's example made
    // executable — "a Terminal window gets shoved to Slack's old frame".
    #expect(Restore.decide(cap(), match: Restore.Match.impostor) == .skip(.identityMismatch))
  }

  @Test func impostorNeverBecomesCarryWork() {
    // Guard site 2, and the one the brief's first draft argued was harmless. An unguarded id collision here
    // classified `deferredBackground`, which hands the window to the CARRY — where the grab is geometric and
    // the post-move membership check PASSES, because the impostor really did land on the target Space. The
    // wrong window moves and the run reports success. `identityMismatch` must therefore be outside the
    // carry-deferred set, or the offer would count a window a tap can never fix.
    let action = Restore.decide(cap(), match: Restore.Match.impostor)
    #expect(action == .skip(.identityMismatch))
    #expect(action != .skip(.deferredBackground))
    // Assert the PRODUCTION predicate, not a hand-copied set. The first draft of this test built its own
    // `carryOwned` set and checked that — which would have stayed green if someone added `identityMismatch`
    // to `Carry.isCarryDeferred`, i.e. green while the exact guarantee this test is named for was broken
    // (2nd-pass review finding 3).
    #expect(!Carry.isCarryDeferred(action))
    // …and out of the offer count too: `carryDeferred` is what the "bring back N windows" badge reads, so an
    // impostor leaking in there would promise a tap that can never fix anything.
    let result = Restore.Result(
      planned: 0, applied: 0, failures: 0, skips: [.identityMismatch: 3], outcomes: [],
      dryRun: true, readFailed: false)
    #expect(result.carryDeferred == 0)
  }

  @Test func identityOutranksEveryOtherVerdict() {
    // Ordering is the point, not an implementation detail. An impostor that is ALSO minimized, 0-space, and
    // frame-identical must still report identityMismatch — any other reason would describe the stranger's
    // window as though it were ours, and `alreadyCorrect` in particular would silently bless it.
    var m = Restore.Match.impostor
    m.minimized = true
    m.liveSpaceCount = 0
    m.liveFrame = cap().frame
    #expect(Restore.decide(cap(), match: m) == .skip(.identityMismatch))
  }

  @Test func matchingIdentityIsUntouchedByTheGuard() {
    // The guard adds a rejection; it must re-classify nothing. A normal same-identity window still places.
    let m = Restore.Match(
      reachable: true, minimized: false, liveSpaceCount: 1,
      liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
      currentDisplay: "DISP-A", landingDisplay: "DISP-A")
    #expect(Restore.decide(cap(), match: m) == .place(cap().frame, verifySpace: false))
  }

  @Test func goneStillOutranksIdentity() {
    // nil match means no live window holds the id at all — there is no impostor to speak of, and calling
    // that an identity mismatch would misreport an ordinary closed window.
    #expect(Restore.decide(cap(), match: nil) == .skip(.gone))
  }
}
