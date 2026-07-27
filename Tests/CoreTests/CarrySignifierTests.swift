// CarrySignifier — the #keeps-19 words-and-glyphs. The verdict variants must PARTITION CarryResult's reachable
// states (aborted first, then carried vs planned): the adversarial brief review caught that partial non-aborted
// runs are common (.failed outcomes don't set aborted) and must never wear the "success" copy.
import Testing

@testable import Core

@Suite struct CarrySignifierTests {

  // MARK: In-flight title

  @Test func titleAnimatesFramesWithProgress() {
    #expect(CarrySignifier.title(frame: 0, progress: (done: 2, total: 5), reduceMotion: false) == "◐ 2/5")
    #expect(CarrySignifier.title(frame: 1, progress: (done: 2, total: 5), reduceMotion: false) == "◓ 2/5")
    #expect(CarrySignifier.title(frame: 4, progress: (done: 2, total: 5), reduceMotion: false) == "◐ 2/5")  // wraps
  }

  @Test func titleBeforeFirstProgressIsGlyphOnly() {
    #expect(CarrySignifier.title(frame: 2, progress: nil, reduceMotion: false) == "◑")
  }

  @Test func reduceMotionIsStaticSameInformation() {  // same info, no cycle (a11y)
    #expect(CarrySignifier.title(frame: 0, progress: (done: 1, total: 3), reduceMotion: true) == "⟳ 1/3")
    #expect(CarrySignifier.title(frame: 3, progress: (done: 1, total: 3), reduceMotion: true) == "⟳ 1/3")
  }

  // MARK: Offer copy — fact body, count-aware action (the two #keeps-18 banner findings)

  @Test func offerBodyStatesTheFactNoQuestionMark() {
    // #keeps-22: names the problem, not the location. "on other Spaces" was true of every counted window
    // and misleading about most of them — `deferredBackground` only means "a Space you aren't looking at".
    #expect(CarrySignifier.offerBody(count: 1) == "1 window isn't where you left it")
    #expect(CarrySignifier.offerBody(count: 4) == "4 windows aren't where you left them")
  }

  @Test func offerActionTitleIsCountAware() {
    #expect(CarrySignifier.offerActionTitle(count: 1) == "Bring it back")
    #expect(CarrySignifier.offerActionTitle(count: 4) == "Bring them back")
  }

  // MARK: Verdict copy — the five-state partition

  @Test func cleanRunSaysBroughtBack() {
    #expect(
      CarrySignifier.verdictBody(carried: 3, planned: 3, aborted: false)
        == "3 windows brought back")
    #expect(  // #keeps-22: not "to its Space" (a run may fix only size), and not "where you left them" —
      // that rhymed with the offer body, and on an aborted run both banners are on screen together
      CarrySignifier.verdictBody(carried: 1, planned: 1, aborted: false)
        == "1 window brought back")
  }

  @Test func partialNonAbortedNeverWearsSuccessCopy() {  // the review's major: .failed outcomes don't set aborted
    #expect(
      CarrySignifier.verdictBody(carried: 2, planned: 5, aborted: false)
        == "2 of 5 windows brought back")
  }

  @Test func stoppedIsHonestAboutThePartial() {
    #expect(
      CarrySignifier.verdictBody(carried: 2, planned: 5, aborted: true)
        == "Stopped — 2 of 5 windows brought back")
    // #keeps-21: this case used to assert "0 of 1 windows" — the expectation itself was the bug, so a
    // green suite endorsed copy that violated the file's own "counts agree at N=1" rule. Caught only by
    // a human reading a real banner (2026-07-27). Both N=1 aborts are pinned now.
    #expect(
      CarrySignifier.verdictBody(carried: 0, planned: 1, aborted: true)
        == "Stopped — 0 of 1 window brought back")
    #expect(
      CarrySignifier.verdictBody(carried: 1, planned: 1, aborted: true)
        == "Stopped — 1 of 1 window brought back")
  }

  @Test func noneCarriedIsAFailureNotASkipCount() {  // "skipped" would conflate already-home with failure
    #expect(
      CarrySignifier.verdictBody(carried: 0, planned: 3, aborted: false)
        == "Couldn't bring windows back — none of 3 moved")
    #expect(
      CarrySignifier.verdictBody(carried: 0, planned: 1, aborted: false)
        == "Couldn't bring the window back")
  }

  @Test func nothingToDoStillGetsAVerdict() {  // the user consented and waited — a verdict is owed
    #expect(
      CarrySignifier.verdictBody(carried: 0, planned: 0, aborted: false)
        == "Everything was already in place")
  }
}
