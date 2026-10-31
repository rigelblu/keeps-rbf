// #keeps-36 — a window keeps reached but couldn't find. A leg's on-screen tag (`Carry.OnScreenCheck`) is the one
// record of what the leg learned; the verdict's quiet-miss count and the trace's `raise=…` evidence both read it,
// so the two can't disagree.
import CoreGraphics
import Testing

@testable import Core

@Suite struct CarryMissTallyTests {
  private func cap(_ wid: UInt32 = 5649) -> CapturedWindow {
    CapturedWindow(
      bundleId: "com.google.Chrome.beta", pid: 1, title: nil, cgWindowId: wid,
      displayUUID: "DISP-0", desktopOrdinal: 1, spaceUUID: "s1",
      frame: WindowFrame(x: 0, y: 0, w: 400, h: 80), spaceIds: [1], sticky: false, onScreen: false)
  }
  private func outcome(_ check: Carry.OnScreenCheck?, _ wid: UInt32 = 5649) -> Carry.Outcome {
    Carry.Outcome(cap: cap(wid), fromGlobal: 6, toGlobal: 1, outcome: "notOnScreen", onScreenCheck: check)
  }

  // MARK: Scenario 2 — only `missedNoElement` is a quiet miss, and the evidence is derived from the tag

  @Test func onlyMissedNoElementIsAQuietMiss() {
    let r = Carry.CarryResult(
      plannedCarries: 5, carried: 1, skips: [:], aborted: false, abortedAfter: 0,
      outcomes: [
        outcome(.missedNoElement), outcome(.missedNoElement), outcome(.missedWithElement), outcome(.found),
        outcome(nil),
      ], dryRun: false, readFailed: false, navigationDead: false)
    #expect(r.quietMisses == 2)
    #expect(r.verdictPlanned == 3)
  }

  @Test func raiseEvidenceIsDerivedFromTheTag() {
    #expect(
      outcome(.missedWithElement).traceLine
        == "[carry:notOnScreen] com.google.Chrome.beta wid=5649 \"\" — desktop 6→1 — raise=ok")
    #expect(
      outcome(.missedNoElement).traceLine
        == "[carry:notOnScreen] com.google.Chrome.beta wid=5649 \"\" — desktop 6→1 — raise=noAXElement")
    #expect(outcome(.found).evidence == nil)
    #expect(outcome(nil).evidence == nil)
  }
}
