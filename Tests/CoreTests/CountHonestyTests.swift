// #keeps-23 — the number keeps shows has to be true, in both directions.
//
// WHAT THIS FILE COVERS, and what it deliberately does not. Two defects, both found in one live dogfood run
// (2026-07-28: one click, 8 windows attempted, 1 actually moved, "2 of 8" reported):
//
//   (a) the carry reported a window "brought back" without ever reading its frame back
//   (b) restore INFERRED a reachable window's Space from its display instead of asking the window
//
// Only (b)'s decision is pinned here as a pure truth table, because only (b) has a pure decision to pin —
// `DesktopIndex.ownSpaceUUID`, extracted for exactly this reason (the SessionFreshness/SettlePolicy
// discipline: the bug lived on the I/O side of the seam, where no test could reach it).
//
// (a) has NO pure decision worth a test of its own. Its rule is `WindowFrame.matches(tolerance: 2)` — already
// pinned below as the acceptance bar, so the INTENT is recorded — wrapped in `Carry.FrameHeld.verify`, which
// is private, async, and does CGWindowList I/O against a live window server. Whether a real window actually
// holds a real frame is still not assertable here, and is verified by the human scenario in the ship-plan
// entry instead: verdict count == the number of windows whose frame actually changed, measured by --print
// before/after. Saying so plainly beats a test named for a guarantee it does not provide (#keeps-21's lesson).
//
// ONE HALF OF THAT GAP CLOSED, and not by a test (#keeps-23 2nd engineering pass). This header used to say
// "what cannot be asserted here is that every place path actually calls it". That is now enforced by the
// compiler rather than asserted by anyone: `CarryOutcome.carried` carries a `FrameHeld`, whose initializer is
// private to itself, so a place path cannot report success without a read-back — it does not compile. Proven
// by a deliberate probe, not assumed (see `FrameHeld`'s doc). The residual gap is narrower and worth naming
// exactly: the compiler guarantees the read HAPPENS, not that the window keeps the frame afterwards.
//
// THE COLD REVIEW PROVED THAT GAP IS NOT THEORETICAL (2026-07-28). Its finding 1 was a real defect in the
// verify loop (then `frameSettled`, now `FrameHeld.verify`): reads landed at t≈0/150/300/450ms and the loop
// then slept a final 150ms and exited
// WITHOUT re-reading, so a 600ms budget observed 450ms. An app settling at ~500ms would have had an honest
// success reported `frameNotHeld` — this slice's own defect class, sign flipped. **No test here would have
// caught it**, and none added since does: it is loop-timing over live CGWindowList I/O, and catching it needs
// an injectable clock and an injectable frame read — a seam this file does not have. It was caught by reading
// the code against its two neighbours (`poll`, `pollWindowGlobal`), both of which do the post-loop read the
// first draft omitted. Recorded here so the next reader knows the suite's real boundary, and does not mistake
// 153 green for coverage of the mechanism.
import Foundation
import Testing

@testable import Core

@Suite struct CountHonestyTests {

  // MARK: - (b) a window's Space is read, never inferred

  /// Two desktops on one display. `currentIndex: 1` means the SECOND is the active one — so a window on the
  /// first is on a background Space while still being AX-reachable. That is the cmux case, exactly.
  private let index = DesktopIndex(displays: [
    DesktopIndex.Display(
      identifier: "DISPLAY-A",
      spaces: [
        DesktopIndex.Space(uuid: "SPACE-BACKGROUND", managedID: 3),
        DesktopIndex.Space(uuid: "SPACE-ACTIVE", managedID: 17),
      ],
      currentIndex: 1)
  ])

  /// THE REGRESSION. Before the fix this resolved to the display's active Space, so restore called a window
  /// sitting exactly where it belonged `deferredWrongSpace` while the carry called it `alreadyOnDesktop 1→1`
  /// in the same run. Two classifiers, one window, opposite verdicts.
  @Test func aBackgroundSpaceWindowResolvesItsOwnSpaceNotTheDisplaysActiveOne() {
    #expect(index.ownSpaceUUID(ofSpaces: [3]) == "SPACE-BACKGROUND")
    #expect(index.ownSpaceUUID(ofSpaces: [3]) != "SPACE-ACTIVE")
  }

  @Test func aWindowOnTheActiveSpaceStillResolvesCorrectly() {
    #expect(index.ownSpaceUUID(ofSpaces: [17]) == "SPACE-ACTIVE")
  }

  /// The #keeps-15 `spaces.first` finding, held as a property rather than an example: CGS over-reports some
  /// apps, and `first` on a multi-Space read is an arbitrary member. Proving a home from it means the verdict
  /// flips with the ordering — so ANY ordering must refuse, not just the inconvenient one.
  @Test func multipleSpacesProveNothingWhicheverWayTheyAreOrdered() {
    #expect(index.ownSpaceUUID(ofSpaces: [3, 17]) == nil)
    #expect(index.ownSpaceUUID(ofSpaces: [17, 3]) == nil)
  }

  /// Zero Spaces is minimized/WindowServer junk (the #keeps-2 core memory), never a provable home.
  @Test func zeroSpacesProvesNothing() {
    #expect(index.ownSpaceUUID(ofSpaces: []) == nil)
  }

  /// A managed id the live topology doesn't know can't be translated — nil, never a fabricated uuid.
  @Test func anUnknownManagedIdProvesNothing() {
    #expect(index.ownSpaceUUID(ofSpaces: [999]) == nil)
  }

  /// Nil must mean "cannot prove", and the caller must fail safe to frame-only rather than re-deriving from
  /// the display — re-deriving would reinstate the bug inside its own fix. This pins the consuming half:
  /// `decide` treats an unknown current Space as frame-only, so an unprovable Space never invents a verdict.
  @Test func anUnprovableSpaceFallsBackToFrameOnlyNotToTheDisplayGuess() {
    let cap = Self.window(frame: WindowFrame(x: 0, y: 39, w: 800, h: 600), space: "SPACE-BACKGROUND")
    let m = Restore.Match(
      reachable: true, minimized: false, liveSpaceCount: 1,
      liveFrame: WindowFrame(x: 0, y: 39, w: 800, h: 600),
      currentDisplay: "DISPLAY-A", landingDisplay: "DISPLAY-A",
      landingActiveSpace: "SPACE-ACTIVE",
      currentSpace: nil)  // unprovable
    #expect(Restore.decide(cap, match: m) == .skip(.alreadyCorrect))
  }

  /// And when the Space IS provable and wrong, the window is carry work — the behavior the inference used to
  /// produce by accident for background windows, now produced on evidence.
  @Test func aProvablyWrongSpaceIsStillCarryWork() {
    let cap = Self.window(frame: WindowFrame(x: 0, y: 39, w: 800, h: 600), space: "SPACE-ACTIVE")
    let m = Restore.Match(
      reachable: true, minimized: false, liveSpaceCount: 1,
      liveFrame: WindowFrame(x: 0, y: 39, w: 800, h: 600),
      currentDisplay: "DISPLAY-A", landingDisplay: "DISPLAY-A",
      landingActiveSpace: "SPACE-ACTIVE",
      currentSpace: "SPACE-BACKGROUND")
    #expect(Restore.decide(cap, match: m) == .skip(.deferredWrongSpace))
  }

  // MARK: - (a) the acceptance bar a place is held to

  /// What `WindowFrame.matches` means at the shared bar: ±`frameTolerance` in BOTH dimensions is jitter,
  /// anything beyond it is drift.
  ///
  /// RENAMED 2026-07-29 (second-model review, found independently by two models). This was
  /// `theAcceptanceBarIsTheSameOneIdempotenceUses` — a name claiming an equality between two subsystems,
  /// over a body that called `matches` with a hand-typed `2` and touched NEITHER of them. It proved `abs()`
  /// works. The sameness it was named for is now actually asserted by `bothClassifiersAgreeAtAnyTolerance`
  /// below; this one keeps only the claim it can carry, and reads the bar from the constant so it moves
  /// when the constant does.
  @Test func toleranceIsPositionAndSizeAlike() {
    let t = Restore.frameTolerance
    let want = WindowFrame(x: 9, y: 1140, w: 340, h: 20)
    #expect(want.matches(WindowFrame(x: 9, y: 1140, w: 340, h: 20), tolerance: t))
    #expect(want.matches(WindowFrame(x: 9 + t, y: 1140 + t, w: 340 + t, h: 20 + t), tolerance: t))
    #expect(!want.matches(WindowFrame(x: 9, y: 1140, w: 340 + t + 1, h: 20), tolerance: t))
    #expect(!want.matches(WindowFrame(x: 9 + t + 1, y: 1140, w: 340, h: 20), tolerance: t))
  }

  /// The invariant `Restore.frameTolerance` exists to protect, held as a property rather than an example:
  /// "this window is home" means ONE thing — whether restore is deciding idempotence or the carry is
  /// deciding there is nothing to do. Two classifiers disagreeing about one window IS the #keeps-22 defect.
  ///
  /// This is the test the tolerance seams were kept for (2026-07-29). The second-model review's first
  /// finding was that `classify`/`restore` still defaulted to a literal `2` while `Carry` used the constant.
  /// The obvious fix was to delete those parameters as dead surface; they were re-pointed at the constant
  /// INSTEAD, specifically so this property could be stated — pass the same `t` to both classifiers and they
  /// must agree. A knob carrying its own literal is a fork; the same knob defaulting to the constant is a seam.
  ///
  /// HONEST BOUNDARY, so 153 green is not mistaken for more than it covers: this pins the two PURE
  /// classifiers to each other. It does NOT reach `Restore.classify`/`Restore.restore`'s defaults — the
  /// layer where the drift actually was — because those need a `LiveState` and nothing in this suite can
  /// build one. That gap is closed by wiring, and nothing here would catch it re-opening.
  /// SWEPT, not sampled — and that is the difference between the name being true and being the next
  /// `theAcceptanceBarIsTheSameOneIdempotenceUses`. The first draft hand-picked four tolerances, which is
  /// four example tests wearing the word "ANY". Both classifiers are pure and trivial, so the cost argument
  /// for sampling does not exist: 9×41 pairs on two axes run in microseconds. `@Test(arguments:)` names the
  /// failing pair, which a `for` loop would not.
  ///
  /// `tolerance: 0` is swept deliberately and is NOT an endorsement of 0 as a setting. The property is
  /// AGREEMENT, not correctness — the two classifiers must reach the same verdict at every tolerance,
  /// including silly ones. Position and size drift sweep independently, so a classifier checking one axis
  /// and not the other is caught; that matters because the motivating defect was a size-only drift at an
  /// IDENTICAL position (Safari's strip, 340×20 → 151×20 at (9,1140)).
  @Test(arguments: 0...8, 0...40)
  func bothClassifiersAgreeAtAnyTolerance(tolerance: Int, drift: Int) {
    let home = WindowFrame(x: 0, y: 39, w: 800, h: 600)

    /// Restore's verdict on a reachable window sitting on its own captured Space: is it already home?
    func restoreSaysHome(dx: Int, dw: Int) -> Bool {
      let cap = Self.window(frame: home, space: "SPACE-BACKGROUND")
      let live = WindowFrame(x: home.x + dx, y: home.y, w: home.w + dw, h: home.h)
      let m = Restore.Match(
        reachable: true, minimized: false, liveSpaceCount: 1, liveFrame: live,
        currentDisplay: "DISPLAY-A", landingDisplay: "DISPLAY-A",
        landingActiveSpace: "SPACE-ACTIVE", currentSpace: "SPACE-BACKGROUND")
      return Restore.decide(cap, match: m, tolerance: tolerance) == .skip(.alreadyCorrect)
    }

    /// The carry's verdict on the SAME window, already on its target desktop: nothing to do?
    func carrySaysHome(dx: Int, dw: Int) -> Bool {
      let cap = Self.window(frame: home, space: "SPACE-BACKGROUND")
      let live = WindowFrame(x: home.x + dx, y: home.y, w: home.w + dw, h: home.h)
      let deferredWindow = Carry.DeferredWindow(
        captured: cap, currentGlobalDesktop: 1, liveFrame: live)
      let binding = Shortcuts.Binding(keyCode: 0, flags: [], isEnabled: true)
      let shortcuts = Shortcuts(
        switchToDesktop: Dictionary(uniqueKeysWithValues: (1...10).map { ($0, binding) }),
        moveLeft: binding, moveRight: binding)
      return Carry.plan(
        deferred: [deferredWindow], spaceIndex: index, shortcuts: shortcuts, tolerance: tolerance)[0]
        == .skip(.alreadyOnDesktop, cap)
    }

    #expect(restoreSaysHome(dx: drift, dw: 0) == carrySaysHome(dx: drift, dw: 0))  // position drift
    #expect(restoreSaysHome(dx: 0, dw: drift) == carrySaysHome(dx: 0, dw: drift))  // size drift
  }

  /// THE CASE THAT MOTIVATED (a), with the real numbers. Safari's link-preview strip was asked for 340×20,
  /// logged `axPlaced=true membershipVerified → PLACED`, and held 151×20 at an IDENTICAL position.
  /// Position-only verification — which `setFrame`'s "size is best-effort" doc would have implied — passes
  /// this. Size must count, or the defect this slice exists to fix walks straight through the fix.
  @Test func aSizeOnlyDriftAtAnIdenticalPositionIsNotHome() {
    let want = WindowFrame(x: 9, y: 1140, w: 340, h: 20)
    let held = WindowFrame(x: 9, y: 1140, w: 151, h: 20)
    #expect(want.x == held.x && want.y == held.y)  // position agrees exactly
    #expect(!want.matches(held, tolerance: 2))  // and it is still not home
  }

  /// `frameNotHeld` must be its own outcome, not folded into `axPlaceFailed`. They are different facts: one
  /// is the AX set being refused, the other is the set succeeding and the window ending up elsewhere anyway.
  /// Collapsing them would hide the whole defect class behind a reason that reads like a platform failure.
  @Test func frameNotHeldIsDistinctFromAPlaceThatWasRefused() {
    #expect(Carry.CarrySkip.frameNotHeld != Carry.CarrySkip.axPlaceFailed)
    #expect(Carry.CarrySkip.frameNotHeld.rawValue == "frameNotHeld")
    #expect(Carry.CarrySkip.allCases.contains(.frameNotHeld))
  }

  // MARK: - Fixture

  private static func window(frame: WindowFrame, space: String?) -> CapturedWindow {
    CapturedWindow(
      bundleId: "com.example.app", pid: 1, title: nil, cgWindowId: 42,
      displayUUID: "DISPLAY-A", desktopOrdinal: 1, spaceUUID: space, frame: frame,
      spaceIds: [3], sticky: false, onScreen: true)
  }
}
