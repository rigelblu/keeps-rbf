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
// pinned below as the acceptance bar, so the INTENT is recorded — wrapped in `Carry.frameSettled`, which is
// private, async, and does CGWindowList I/O against a live window server. What cannot be asserted here is
// that every place path actually calls it. That is host behavior with no host test target, exactly like
// #keeps-20's persistence gap, and it is verified by the human scenario in the ship-plan entry instead:
// verdict count == the number of windows whose frame actually changed, measured by --print before/after.
// Saying so plainly beats a test named for a guarantee it does not provide (the #keeps-21 lesson).
//
// THE COLD REVIEW PROVED THAT GAP IS NOT THEORETICAL (2026-07-28). Its finding 1 was a real defect in
// `frameSettled`'s loop: reads landed at t≈0/150/300/450ms and the loop then slept a final 150ms and exited
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

  /// The carry's frame verification uses `WindowFrame.matches(tolerance: 2)` — the SAME predicate
  /// `Restore.decide` uses for `alreadyCorrect`. Pinned here as a decision, not an implementation detail:
  /// "this window is home" has to mean one thing whether it got there by placement or was already there.
  /// It also overrules `Restore.setFrame`'s "size is best-effort" doc, deliberately — see the next test.
  @Test func theAcceptanceBarIsTheSameOneIdempotenceUses() {
    let want = WindowFrame(x: 9, y: 1140, w: 340, h: 20)
    #expect(want.matches(WindowFrame(x: 9, y: 1140, w: 340, h: 20), tolerance: 2))
    #expect(want.matches(WindowFrame(x: 10, y: 1141, w: 341, h: 21), tolerance: 2))  // ±2 jitter is not drift
    #expect(!want.matches(WindowFrame(x: 9, y: 1140, w: 355, h: 20), tolerance: 2))
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
