// #keeps-5.4 — resolving a pre-reboot snapshot's dead window ids to live windows by app + position.
//
// Grounded in the real dogfood snapshot that forced this slice: 37 windows, **zero titles** (Screen Recording
// isn't granted, so `kCGWindowName` is empty), and several apps with many windows each — Bear 7, Safari 6,
// Warp 3. That shape is why matching is positional and why "which Bear window went where" is explicitly not
// a promise the design makes.
import CoreGraphics
import Foundation
import Testing

@testable import Core

@Suite struct ColdStartMatchTests {

  private func cap(
    _ bundleId: String, id: UInt32, x: Int, y: Int, sticky: Bool = false
  ) -> CapturedWindow {
    CapturedWindow(
      bundleId: bundleId, pid: 1, title: nil, cgWindowId: id, displayUUID: "D", desktopOrdinal: 1,
      spaceUUID: "S", frame: WindowFrame(x: x, y: y, w: 100, h: 100), spaceIds: [1],
      sticky: sticky, onScreen: true)
  }

  private func live(_ identity: String, id: UInt32, x: Int, y: Int) -> ColdStartMatch.LiveWindow {
    ColdStartMatch.LiveWindow(
      id: id, identity: identity, frame: WindowFrame(x: x, y: y, w: 100, h: 100))
  }

  @Test func matchesTheSoleWindowOfAnApp() {
    let m = ColdStartMatch.assign(
      captured: [cap("com.a", id: 900, x: 10, y: 10)],
      live: [live("com.a", id: 12, x: 500, y: 500)])
    // Position is a PAIRING key, not a filter: the live window is nowhere near the captured frame, and that
    // is exactly the normal case after a reboot (apps reopen at their own defaults). Restoring means MOVING
    // it back — so refusing a distant match would refuse the whole point of the feature.
    #expect(m == [900: 12])
  }

  @Test func neverMatchesAcrossApps() {
    // The safety property `5.1` exists for: a Terminal window must never be resolved to Slack's live window.
    let m = ColdStartMatch.assign(
      captured: [cap("com.terminal", id: 900, x: 0, y: 0)],
      live: [live("com.slack", id: 12, x: 0, y: 0)])
    #expect(m.isEmpty)
  }

  @Test func pairsManyWindowsOfOneAppInReadingOrder() {
    // The Bear/Safari case. With no titles there is nothing to distinguish windows by, so the guarantee is
    // set-level: every captured slot gets a live window of the right app, and relative arrangement is
    // preserved — topmost live → topmost captured — rather than shuffled.
    let caps = [
      cap("com.bear", id: 901, x: 0, y: 300),  // lower
      cap("com.bear", id: 902, x: 0, y: 100),  // upper
      cap("com.bear", id: 903, x: 0, y: 200),  // middle
    ]
    let lives = [
      live("com.bear", id: 21, x: 50, y: 250),  // middle
      live("com.bear", id: 22, x: 50, y: 50),  // upper
      live("com.bear", id: 23, x: 50, y: 450),  // lower
    ]
    let m = ColdStartMatch.assign(captured: caps, live: lives)
    #expect(m[902] == 22)  // upper ↔ upper
    #expect(m[903] == 21)  // middle ↔ middle
    #expect(m[901] == 23)  // lower ↔ lower
    #expect(Set(m.values).count == 3)  // a bijection — no live window claimed twice
  }

  @Test func isDeterministicWhenPositionsTie() {
    // `sorted(by:)` is not stable in Swift (the lesson #keeps-20 banked for condition ordering). Two windows
    // at identical coordinates must still pair the same way every run — a restore that shuffles differently
    // each time it runs is its own defect.
    let caps = [cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 0)]
    let lives = [live("com.a", id: 31, x: 9, y: 9), live("com.a", id: 32, x: 9, y: 9)]
    let first = ColdStartMatch.assign(captured: caps, live: lives)
    for _ in 0..<20 {
      #expect(ColdStartMatch.assign(captured: caps.reversed(), live: lives.reversed()) == first)
    }
  }

  @Test func extraCapturedWindowsAreLeftUnmatched() {
    // Three saved, two open ⇒ two resolve and the third falls through to the existing `gone` path. No new
    // "unmatched" concept enters the restore truth table.
    let caps = [
      cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 100),
      cap("com.a", id: 903, x: 0, y: 200),
    ]
    let m = ColdStartMatch.assign(
      captured: caps, live: [live("com.a", id: 31, x: 0, y: 0), live("com.a", id: 32, x: 0, y: 100)])
    #expect(m.count == 2)
    #expect(m[903] == nil)  // the lowest captured window is the one left over
  }

  @Test func extraLiveWindowsAreLeftAlone() {
    // Two saved, five open ⇒ three live windows are NOT touched. Moving a window the user never asked about
    // would be keeps inventing layout, which is worse than leaving it be.
    let m = ColdStartMatch.assign(
      captured: [cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 100)],
      live: (0..<5).map { live("com.a", id: UInt32(40 + $0), x: 0, y: $0 * 100) })
    #expect(m.count == 2)
    #expect(Set(m.values).count == 2)
  }

  @Test func stickyWindowsNeverClaimALiveWindow() {
    // All-desktops windows can't be frame-restored at all (`decide` skips them), so letting one claim a live
    // window would starve a window that CAN be placed.
    let m = ColdStartMatch.assign(
      captured: [cap("com.a", id: 901, x: 0, y: 0, sticky: true), cap("com.a", id: 902, x: 0, y: 100)],
      live: [live("com.a", id: 31, x: 0, y: 0)])
    #expect(m == [902: 31])
  }

  @Test func windowsWithNoLiveFrameSortLastRatherThanDisplacing() {
    // A frameless live window carries no position signal. It must take a leftover slot, not the top one —
    // otherwise one unreadable frame would scramble the pairing for every window that IS readable.
    let caps = [cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 100)]
    let lives = [
      ColdStartMatch.LiveWindow(id: 31, identity: "com.a", frame: nil),
      live("com.a", id: 32, x: 0, y: 50),
    ]
    let m = ColdStartMatch.assign(captured: caps, live: lives)
    #expect(m[901] == 32)  // the positioned live window takes the top captured slot
    #expect(m[902] == 31)  // the frameless one takes what's left
  }

  // MARK: - The candidate gate — what counts as a real window

  @Test func candidateGateMirrorsCaptureAndRejectsJunk() {
    // The bug this pins, found by running the real binary rather than reading the code: gating on ownership
    // alone let 1×1 utility windows and 1800×39 chrome into the candidate pool. Real windows matched to those
    // and classified `minimized` — 26 of 29 on the live fleet. 122 of 154 normal-layer windows were junk.
    let good = WindowFrame(x: 0, y: 39, w: 1800, h: 1130)
    #expect(ColdStartMatch.isCandidate(normalLayer: true, frame: good, hasSpace: true))

    // Each rejection reason, one at a time, so a regression names itself.
    #expect(!ColdStartMatch.isCandidate(normalLayer: false, frame: good, hasSpace: true))  // menu/panel/shadow
    #expect(!ColdStartMatch.isCandidate(normalLayer: true, frame: nil, hasSpace: true))  // no bounds
    // 1×1 is deliberately ACCEPTED here, stated positively rather than hidden in a double negative: capture
    // accepts it too (`w > 0, h > 0`), and mirroring capture is the whole rule. In practice such windows are
    // rejected a step later by `hasSpace` — which is what actually cleared Chrome's 1×1 off the live fleet.
    // If that ever stops holding, this line is the one that should be revisited, not quietly tightened.
    #expect(
      ColdStartMatch.isCandidate(
        normalLayer: true, frame: WindowFrame(x: 0, y: 0, w: 1, h: 1), hasSpace: true))
    #expect(
      !ColdStartMatch.isCandidate(
        normalLayer: true, frame: WindowFrame(x: 0, y: 0, w: 1, h: 1), hasSpace: false))
    #expect(
      !ColdStartMatch.isCandidate(
        normalLayer: true, frame: WindowFrame(x: 0, y: 0, w: 0, h: 100), hasSpace: true))  // zero width
    #expect(
      !ColdStartMatch.isCandidate(
        normalLayer: true, frame: WindowFrame(x: 0, y: 0, w: 100, h: 0), hasSpace: true))  // zero height
    #expect(!ColdStartMatch.isCandidate(normalLayer: true, frame: good, hasSpace: false))  // minimized/junk
  }

  // MARK: - The integration seam (the layer the pure tests could not reach)

  @Test func aColdStartMissIsGoneAndNeverAFallbackToTheDeadId() {
    // C1 from the independent review, pinned. The first build resolved ids as `remap[id] ?? id`. In a cold
    // start that hands an UNRESOLVED window its dead id — and ids recycle from low numbers after a reboot, so
    // that id routinely belongs to a live stranger. Two proven consequences: the window classified against
    // someone else's window, and one live window could be claimed TWICE (once through the map, once through a
    // colliding fallback), producing two verdicts for one window and acting on both.
    //
    // The distinction is now a type: `remap == nil` means same session, non-nil means cold start where a miss
    // is `gone`. This asserts the rule at `decide`'s boundary, which is where the pure matcher tests stop.
    let unresolved = cap("com.a", id: 165, x: 0, y: 0)  // 165 is deliberately a plausible live id
    // Cold start, empty map ⇒ nothing resolves ⇒ gone, regardless of what lives at id 165.
    #expect(Restore.decide(unresolved, match: nil) == .skip(.gone))
  }

  @Test func stickyCapturedWindowsCannotBeResolvedInAColdStart() {
    // Sticky windows are excluded from `assign`, so in a cold start they can never resolve — which under the
    // old fallback meant they were classified via their DEAD id, and `decide` places sticky windows on the
    // reachable path. Excluded-from-matching must therefore mean gone, not "matched by accident".
    let m = ColdStartMatch.assign(
      captured: [cap("com.a", id: 165, x: 0, y: 0, sticky: true)],
      live: [live("com.a", id: 165, x: 0, y: 0)])
    #expect(m.isEmpty, "a sticky captured window must claim no live window")
  }

  @Test func oneLiveWindowIsNeverPromisedToTwoCapturedWindows() {
    // The bijection, asserted as the property that matters rather than as a count. Two captured windows of
    // one app against one live window: exactly one may resolve, and the other must be absent from the map so
    // it classifies gone.
    let m = ColdStartMatch.assign(
      captured: [cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 100)],
      live: [live("com.a", id: 165, x: 0, y: 0)])
    #expect(m.count == 1)
    #expect(Set(m.values) == [165])
  }

  @Test func emptyInputsResolveToNothing() {
    #expect(ColdStartMatch.assign(captured: [], live: []).isEmpty)
    #expect(ColdStartMatch.assign(captured: [cap("com.a", id: 1, x: 0, y: 0)], live: []).isEmpty)
    #expect(ColdStartMatch.assign(captured: [], live: [live("com.a", id: 1, x: 0, y: 0)]).isEmpty)
  }
}
