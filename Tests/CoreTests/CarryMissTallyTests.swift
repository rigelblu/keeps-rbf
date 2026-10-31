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

  // MARK: Scenario 2 — a leg's tag comes from what its first half learned (#keeps-36.2's split)

  @Test func onScreenCheckComesFromTheReach() {
    #expect(Carry.onScreenCheck(.notReached(.unreachableShortcut)) == nil)
    #expect(Carry.onScreenCheck(.missed(raised: false)) == .missedNoElement)
    #expect(Carry.onScreenCheck(.missed(raised: true)) == .missedWithElement)
    #expect(Carry.onScreenCheck(.found(CGRect(x: 0, y: 0, width: 400, height: 80))) == .found)
  }

  @Test func summaryLineNamesTheLeftOut() {
    let r = Carry.CarryResult(
      plannedCarries: 4, carried: 3, skips: [:], aborted: false, abortedAfter: 0,
      outcomes: [outcome(.missedNoElement), outcome(.found)], dryRun: false, readFailed: false,
      navigationDead: false)
    #expect(
      r.summaryTraceLine
        == "[carry:summary] carried 3 of 4 planned — 1 left out of the verdict (not on screen, raise=noAXElement)")
    let none = Carry.CarryResult(
      plannedCarries: 2, carried: 2, skips: [:], aborted: false, abortedAfter: 0,
      outcomes: [outcome(.found)], dryRun: false, readFailed: false, navigationDead: false)
    #expect(none.summaryTraceLine == "[carry:summary] carried 2 of 2 planned — 0 left out")
  }

  // MARK: Scenario 3 — the tally stops on a repeat, not on one miss

  private func tally(_ legs: [Carry.OnScreenCheck?], _ wid: UInt32 = 5649) -> CarryMissTally {
    var t = CarryMissTally()
    for leg in legs { t.record([outcome(leg, wid)]) }
    return t
  }

  @Test func twoMissesInARowStopTheOffer() {
    #expect(tally([.missedNoElement, .missedNoElement]).notOffered == [5649])
    #expect(tally([.missedNoElement]).notOffered == [])
    #expect(CarryMissTally.stopAfter == 2)
  }

  @Test func foundBetweenMissesResets() {
    #expect(tally([.missedNoElement, .found, .missedNoElement]).notOffered == [])
  }

  @Test func missWithElementBetweenMissesResets() {
    #expect(tally([.missedNoElement, .missedWithElement, .missedNoElement]).notOffered == [])
  }

  @Test func untaggedLegChangesNothing() {
    #expect(tally([.missedNoElement, nil, .missedNoElement]).notOffered == [5649])
  }

  @Test func oneMissEachForTwoWindowsStopsNeither() {
    var t = CarryMissTally()
    t.record([outcome(.missedNoElement, 5649), outcome(.missedNoElement, 170)])
    #expect(t.notOffered == [])
    #expect(t.tracked == [5649, 170])
  }

  // MARK: Scenario 4 — seen real resets it, at any count

  @Test func seenRealIsTrackedAndReachableOrOnScreen() {
    #expect(CarryMissTally.seenReal(tracked: [5649, 170], reachable: [5649], onScreen: []) == [5649])
    #expect(CarryMissTally.seenReal(tracked: [5649, 170], reachable: [], onScreen: [170]) == [170])
    #expect(CarryMissTally.seenReal(tracked: [5649], reachable: [1, 2], onScreen: [3]) == [])
  }

  @Test func clearReturnsOnlyTheOnesComingBack() {
    var t = tally([.missedNoElement, .missedNoElement])
    t.record([outcome(.missedNoElement, 170)])
    #expect(t.clear([5649, 170]) == [5649])
    #expect(t.tracked == [])
  }

  // MARK: One carry's misses, absorbed in one step — seen-real clears first, then this run's legs record

  @Test func absorbClearsBeforeItRecords() {  // seen real at gather time, then missed by the same run
    var t = tally([.missedNoElement])
    let r = t.absorb(seenReal: [5649], outcomes: [outcome(.missedNoElement)])
    #expect(r.back == [])
    #expect(t.tracked == [5649])  // at 1 miss, not cleared…
    #expect(t.notOffered == [])  // …and not at 2
    t.record([outcome(.missedNoElement)])
    #expect(t.notOffered == [5649])  // the next miss is the second
  }

  @Test func aRestoreThatFindsItBetweenMissesKeepsItOffered() {  // miss → a Restore finds it → miss
    var t = CarryMissTally()
    _ = t.absorb(seenReal: [], outcomes: [outcome(.missedNoElement)])
    _ = t.clear([5649])  // the restore path: `Restore.Result.seenReal`
    _ = t.absorb(seenReal: [], outcomes: [outcome(.missedNoElement)])
    #expect(t.notOffered == [])
    #expect(t.tracked == [5649])
  }

  @Test func absorbNamesTheWindowsThisRunStopped() {
    var t = tally([.missedNoElement])  // 5649 at 1
    t.record([outcome(.missedNoElement, 170), outcome(.missedNoElement, 170)])  // 170 already stopped
    t.record([outcome(.missedNoElement, 186), outcome(.missedNoElement, 186)])  // 186 stopped, seen real now
    let r = t.absorb(
      seenReal: [186],
      outcomes: [outcome(.missedNoElement), outcome(.missedNoElement, 170), outcome(.missedNoElement, 99)])
    #expect(r.newlyStopped == [5649])
    #expect(r.back == [186])
    #expect(t.notOffered == [5649, 170])
  }
}
