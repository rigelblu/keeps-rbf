// The restore filter as a truth table — every place and every skip reason, with no I/O.
// This is Scenario A made executable. The M1 confound (a since-minimized 0-space window must be
// `minimized`, never `deferredBackground`) is pinned as a red-on-regression test, and idempotence
// (±2px alreadyCorrect) is locked so restore can't thrash on rounding.
import Testing

@testable import Core

@Suite struct RestorePlanTests {
  private func cap(
    sticky: Bool = false, frame: WindowFrame = WindowFrame(x: 100, y: 100, w: 800, h: 600)
  ) -> CapturedWindow {
    CapturedWindow(
      bundleId: "com.example.app", pid: 42, title: "t", cgWindowId: 1,
      displayUUID: "DISP-A", desktopOrdinal: 2, spaceUUID: "S", frame: frame,
      spaceIds: [9], sticky: sticky, onScreen: true)
  }
  private func match(
    reachable: Bool = true, minimized: Bool = false, spaceCount: Int = 1,
    liveFrame: WindowFrame? = WindowFrame(x: 100, y: 100, w: 800, h: 600)
  ) -> Restore.Match {
    Restore.Match(
      reachable: reachable, minimized: minimized, liveSpaceCount: spaceCount, liveFrame: liveFrame)
  }

  @Test func placesReachableWindowOffSpot() {
    let m = match(liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600))  // current ≠ captured → move
    #expect(Restore.decide(cap(), match: m) == .place(cap().frame))
  }

  @Test func skipsAlreadyCorrectWithinTolerance() {
    let m = match(liveFrame: WindowFrame(x: 101, y: 99, w: 800, h: 601))  // within ±2px on every edge
    #expect(Restore.decide(cap(), match: m) == .skip(.alreadyCorrect))
  }

  @Test func movesWhenOutsideTolerance() {
    let m = match(liveFrame: WindowFrame(x: 105, y: 100, w: 800, h: 600))  // 5px off → move
    #expect(Restore.decide(cap(), match: m) == .place(cap().frame))
  }

  @Test func skipsGoneWhenNoMatch() {
    #expect(Restore.decide(cap(), match: nil) == .skip(.gone))
  }

  @Test func skipsMinimizedByAXFlag() {  // minimized windows can still appear in AX (kAXWindows)
    #expect(
      Restore.decide(cap(), match: match(reachable: true, minimized: true)) == .skip(.minimized))
  }

  @Test func zeroSpaceIsMinimizedNotDeferred() {  // M1: 0-space = minimized/junk, NOT a background desktop
    #expect(
      Restore.decide(cap(), match: match(reachable: false, spaceCount: 0)) == .skip(.minimized))
  }

  @Test func defersBackgroundDesktopWindow() {  // matched, 1 space, not active → #keeps-4's input
    #expect(
      Restore.decide(cap(), match: match(reachable: false, spaceCount: 1))
        == .skip(.deferredBackground))
  }

  @Test func placesReachableStickyWindow() {  // Safari over-report fix: sticky must NOT block frame-restore
    let m = match(reachable: true, liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600))
    #expect(Restore.decide(cap(sticky: true), match: m) == .place(cap().frame))
  }

  @Test func skipsStickyOnlyWhenUnreachable() {  // all-spaces over-report AND not on an active desktop
    #expect(
      Restore.decide(cap(sticky: true), match: match(reachable: false, spaceCount: 5))
        == .skip(.sticky))
  }
}
