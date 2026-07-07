// The restore filter as a truth table — every place and every skip reason, with no I/O.
// This is Scenario A made executable. The M1 confound (a since-minimized 0-space window must be
// `minimized`, never `deferredBackground`) is pinned as a red-on-regression test, and idempotence
// (±2px alreadyCorrect) is locked so restore can't thrash on rounding.
import CoreGraphics
import Testing

@testable import Core

@Suite struct RestorePlanTests {
  private func cap(
    sticky: Bool = false, spaceUUID: String? = "S",
    frame: WindowFrame = WindowFrame(x: 100, y: 100, w: 800, h: 600)
  ) -> CapturedWindow {
    CapturedWindow(
      bundleId: "com.example.app", pid: 42, title: "t", cgWindowId: 1,
      displayUUID: "DISP-A", desktopOrdinal: 2, spaceUUID: spaceUUID, frame: frame,
      spaceIds: [9], sticky: sticky, onScreen: true)
  }
  // Guard facts default to a same-display landing (#keeps-17): current == landing ⇒ the Space guard is
  // moot, preserving the pre-guard truth table. Cross-display cases set the three facts explicitly.
  private func match(
    reachable: Bool = true, minimized: Bool = false, spaceCount: Int = 1,
    liveFrame: WindowFrame? = WindowFrame(x: 100, y: 100, w: 800, h: 600),
    currentDisplay: String? = "DISP-A", landingDisplay: String? = "DISP-A",
    landingActiveSpace: String? = nil
  ) -> Restore.Match {
    Restore.Match(
      reachable: reachable, minimized: minimized, liveSpaceCount: spaceCount, liveFrame: liveFrame,
      currentDisplay: currentDisplay, landingDisplay: landingDisplay,
      landingActiveSpace: landingActiveSpace)
  }

  @Test func placesReachableWindowOffSpot() {
    let m = match(liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600))  // current ≠ captured → move
    #expect(Restore.decide(cap(), match: m) == .place(cap().frame, verifySpace: false))
  }

  @Test func skipsAlreadyCorrectWithinTolerance() {
    let m = match(liveFrame: WindowFrame(x: 101, y: 99, w: 800, h: 601))  // within ±2px on every edge
    #expect(Restore.decide(cap(), match: m) == .skip(.alreadyCorrect))
  }

  @Test func movesWhenOutsideTolerance() {
    let m = match(liveFrame: WindowFrame(x: 105, y: 100, w: 800, h: 600))  // 5px off → move
    #expect(Restore.decide(cap(), match: m) == .place(cap().frame, verifySpace: false))
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

  @Test func defersBackgroundDesktopWindow() {  // matched, 1 space, not active → #keeps-12's input
    #expect(
      Restore.decide(cap(), match: match(reachable: false, spaceCount: 1))
        == .skip(.deferredBackground))
  }

  @Test func placesReachableStickyWindow() {  // Safari over-report fix: sticky must NOT block frame-restore
    let m = match(reachable: true, liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600))
    #expect(Restore.decide(cap(sticky: true), match: m) == .place(cap().frame, verifySpace: false))
  }

  @Test func skipsStickyOnlyWhenUnreachable() {  // all-spaces over-report AND not on an active desktop
    #expect(
      Restore.decide(cap(sticky: true), match: match(reachable: false, spaceCount: 5))
        == .skip(.sticky))
  }

  // #keeps-17: the Space-safety guard — a silent place must never change the window's Space. Same-display
  // is always safe; cross-display needs proof (landing display's active Space == the captured Space) and
  // the sweep verifies after the set. offScreenTarget/unprovableSpace are count-only; deferredCrossDisplay
  // is the carry's input.
  @Test func placesCrossDisplayWhenTargetSpaceActive() {
    let m = match(
      liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
      currentDisplay: "DISP-A", landingDisplay: "DISP-B", landingActiveSpace: "S")
    #expect(Restore.decide(cap(), match: m) == .place(cap().frame, verifySpace: true))
  }

  @Test func defersCrossDisplayWhenTargetSpaceInactive() {
    let m = match(
      liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
      currentDisplay: "DISP-A", landingDisplay: "DISP-B", landingActiveSpace: "OTHER")
    #expect(Restore.decide(cap(), match: m) == .skip(.deferredCrossDisplay))
  }

  @Test func defersCrossDisplayWhenActiveSpaceUnknown() {  // nil active ⇒ can't prove ⇒ fail closed
    let m = match(
      liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
      currentDisplay: "DISP-A", landingDisplay: "DISP-B", landingActiveSpace: nil)
    #expect(Restore.decide(cap(), match: m) == .skip(.deferredCrossDisplay))
  }

  @Test func unprovableWhenCrossDisplayWithoutCapturedSpace() {  // the carry has no target either — count-only
    let m = match(
      liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
      currentDisplay: "DISP-A", landingDisplay: "DISP-B", landingActiveSpace: "S")
    #expect(Restore.decide(cap(spaceUUID: nil), match: m) == .skip(.unprovableSpace))
  }

  @Test func skipsOffScreenTargetForAnyWindow() {  // no live display owns the desired coords — sticky included
    let m = match(liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600), landingDisplay: nil)
    #expect(Restore.decide(cap(), match: m) == .skip(.offScreenTarget))
    #expect(Restore.decide(cap(sticky: true), match: m) == .skip(.offScreenTarget))
  }

  @Test func stickyCrossDisplayPlacesUnverified() {  // all-desktops membership can't be damaged
    let m = match(
      liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
      currentDisplay: "DISP-A", landingDisplay: "DISP-B", landingActiveSpace: "OTHER")
    #expect(Restore.decide(cap(sticky: true), match: m) == .place(cap().frame, verifySpace: false))
  }

  @Test func unknownCurrentDisplayRequiresProof() {  // can't show same-display ⇒ treat as crossing (fail closed)
    let proven = match(
      liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
      currentDisplay: nil, landingDisplay: "DISP-B", landingActiveSpace: "S")
    #expect(Restore.decide(cap(), match: proven) == .place(cap().frame, verifySpace: true))
    let unproven = match(
      liveFrame: WindowFrame(x: 0, y: 0, w: 800, h: 600),
      currentDisplay: nil, landingDisplay: "DISP-B", landingActiveSpace: "OTHER")
    #expect(Restore.decide(cap(), match: unproven) == .skip(.deferredCrossDisplay))
  }

  @Test func alreadyCorrectBeatsTheGuard() {  // an already-home window needs no guard — order pinned
    let m = match(landingDisplay: nil)  // even an off-screen-looking target: the window IS at its captured frame
    #expect(Restore.decide(cap(), match: m) == .skip(.alreadyCorrect))
  }

  @Test func displayContainingUsesCenterRule() {  // the guard's landing resolution == the trace's displayOf rule
    let topo = Restore.Topology(displays: [
      .init(uuid: "A", bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), activeSpaceUUID: "SA"),
      .init(uuid: "B", bounds: CGRect(x: 1000, y: 0, width: 1000, height: 1000), activeSpaceUUID: nil),
    ])
    #expect(topo.displayContaining(WindowFrame(x: 900, y: 100, w: 400, h: 100))?.uuid == "B")  // center x=1100
    #expect(topo.displayContaining(WindowFrame(x: 100, y: 100, w: 400, h: 100))?.uuid == "A")
    #expect(topo.displayContaining(WindowFrame(x: 5000, y: 5000, w: 100, h: 100)) == nil)  // off-screen
  }
}
