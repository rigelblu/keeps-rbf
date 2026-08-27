// #keeps-5.4 — resolving a pre-reboot snapshot's dead window ids to live windows by app + geometry.
//
// Grounded in two real dogfood snapshots. The first (2026-07-28): 37 windows, **zero titles** (Screen Recording
// isn't granted, so `kCGWindowName` is empty), several apps with many windows each — Bear 7, Safari 6, Warp 3.
// That shape is why matching is geometric and why "which Bear window went where" is explicitly not a promise.
// The second (2026-08-26, #keeps-31): the same fleet after a real reboot, where the reading-order pairing
// matched real windows to status strips — the fixture at the bottom of this file is that snapshot, verbatim.
import CoreGraphics
import Foundation
import Testing

@testable import Core

@Suite struct ColdStartMatchTests {

  private func cap(
    _ bundleId: String, id: UInt32, x: Int, y: Int, w: Int = 100, h: Int = 100, sticky: Bool = false
  ) -> CapturedWindow {
    CapturedWindow(
      bundleId: bundleId, pid: 1, title: nil, cgWindowId: id, displayUUID: "D", desktopOrdinal: 1,
      spaceUUID: "S", frame: WindowFrame(x: x, y: y, w: w, h: h), spaceIds: [1],
      sticky: sticky, onScreen: true)
  }

  private func live(_ identity: String, id: UInt32, x: Int, y: Int, w: Int = 100, h: Int = 100)
    -> ColdStartMatch.LiveWindow
  {
    ColdStartMatch.LiveWindow(id: id, identity: identity, frame: WindowFrame(x: x, y: y, w: w, h: h))
  }

  private func assign(_ caps: [CapturedWindow], _ lives: [ColdStartMatch.LiveWindow])
    -> [CGWindowID: CGWindowID]
  {
    ColdStartMatch.assign(captured: caps, live: lives).map
  }

  // MARK: - The three tiers (#keeps-31)

  @Test func matchesTheSoleWindowOfAnApp() {
    // The live window is nowhere near the captured frame — the normal case after a reboot, when an app
    // reopens at its own default position — but it is the SAME SIZE, and that is a geometry signal (tier 3).
    // Restoring means moving it back; the signal is what makes the move safe to propose.
    let a = ColdStartMatch.assign(
      captured: [cap("com.a", id: 900, x: 10, y: 10)],
      live: [live("com.a", id: 12, x: 500, y: 500)])
    #expect(a.map == [900: 12])
    #expect((a.exact, a.position, a.size) == (0, 0, 1))
  }

  @Test func exactFrameClaimsBeforeAnyOtherTier() {
    // The Chrome `856` case, reduced. A strip record sits ABOVE a real record in reading order; one live
    // window sits exactly at the real record's frame. Reading order handed the live window to the strip and
    // told a window already home to become a 5120×46 strip. Tier 1 runs first across the whole app.
    let real = cap("com.chrome", id: 4235, x: -2560, y: -1817, w: 2560, h: 1425)
    let strip = cap("com.chrome", id: 4238, x: -5120, y: -1894, w: 5120, h: 46)
    let home = live("com.chrome", id: 856, x: -2560, y: -1817, w: 2560, h: 1425)
    let a = ColdStartMatch.assign(captured: [strip, real], live: [home])
    #expect(a.map == [4235: 856])
    #expect(a.exact == 1)
  }

  @Test func samePositionDifferentSizePairs() {
    // Safari's link-preview strip: saved 155 wide, live 292 wide (its width tracks the hovered link), same
    // origin. It pairs with ITS OWN record — and so can never be handed a real window's frame.
    let a = ColdStartMatch.assign(
      captured: [cap("com.safari", id: 47219, x: 9, y: 1140, w: 155, h: 20)],
      live: [live("com.safari", id: 234, x: 9, y: 1140, w: 292, h: 20)])
    #expect(a.map == [47219: 234])
    #expect(a.position == 1)
  }

  @Test func sameSizePairsBySizeNotByOrder() {
    // Tier 3 by design, not by fixture luck: three windows of DISTINCT sizes, reopened in a shuffled vertical
    // order. Reading order would pair top↔top; the size signal pairs each with its own.
    let caps = [
      cap("com.bear", id: 901, x: 0, y: 300, w: 300, h: 300),
      cap("com.bear", id: 902, x: 0, y: 100, w: 500, h: 500),
      cap("com.bear", id: 903, x: 0, y: 200, w: 700, h: 700),
    ]
    let lives = [
      live("com.bear", id: 21, x: 50, y: 50, w: 700, h: 700),  // top, but 903's size
      live("com.bear", id: 22, x: 50, y: 250, w: 300, h: 300),  // middle, 901's size
      live("com.bear", id: 23, x: 50, y: 450, w: 500, h: 500),  // bottom, 902's size
    ]
    #expect(assign(caps, lives) == [901: 22, 902: 23, 903: 21])
  }

  @Test func sameSizeCandidatesResolveByNearestPosition() {
    // The Bear case: seven indistinguishable, same-size windows reopened at cascaded positions. Each takes
    // the NEAREST saved slot, so relative arrangement is preserved rather than shuffled.
    let caps = [
      cap("com.bear", id: 901, x: 0, y: 300),
      cap("com.bear", id: 902, x: 0, y: 100),
      cap("com.bear", id: 903, x: 0, y: 200),
    ]
    let lives = [
      live("com.bear", id: 21, x: 50, y: 250),
      live("com.bear", id: 22, x: 50, y: 50),
      live("com.bear", id: 23, x: 50, y: 450),
    ]
    let m = assign(caps, lives)
    #expect(m == [902: 22, 903: 21, 901: 23])
    #expect(Set(m.values).count == 3)  // a bijection — no live window claimed twice
  }

  @Test func noSharedGeometryIsGoneNotGuessed() {
    // The Chrome `793` case: a real live window against three strip records that share neither its origin
    // nor its size. Under reading order it was told to become an 1826×89 strip. Now: no signal, no pairing —
    // the records classify `gone` and the window is left alone.
    let strips = [
      cap("com.chrome", id: 4238, x: -5120, y: -1894, w: 5120, h: 46),
      cap("com.chrome", id: 4237, x: -2221, y: -1832, w: 1826, h: 89),
      cap("com.chrome", id: 26365, x: -804, y: -1785, w: 403, h: 84),
    ]
    let real = live("com.chrome", id: 793, x: -2560, y: -392, w: 2560, h: 1425)
    #expect(assign(strips, [real]).isEmpty)
  }

  @Test func threePassOrderClaimsAcrossTheAppBeforeTheNextTier() {
    // The discriminating variant from the brief's review: two same-size Zed records, one live window sitting
    // exactly at the LOWER record's frame. Three-pass: tier 1 sweeps both records and 43133 claims it. A
    // per-window cascade would let 43131 (first in reading order) claim it by tier 3 — a same-size sibling
    // stealing a window that is exactly home, the defect class this rule exists to end.
    let caps = [
      cap("dev.zed", id: 43131, x: -5120, y: -1817, w: 5120, h: 1425),
      cap("dev.zed", id: 43133, x: -5120, y: -392, w: 5120, h: 1425),
    ]
    let a = ColdStartMatch.assign(
      captured: caps, live: [live("dev.zed", id: 293, x: -5120, y: -392, w: 5120, h: 1425)])
    #expect(a.map == [43133: 293])
    #expect((a.exact, a.size) == (1, 0))
  }

  @Test func aLiveWindowWithNoFrameNeverPairs() {
    // Rewritten for #keeps-31 (it used to assert the opposite: "sorts last, takes a leftover slot"). A
    // frameless live window carries no geometry signal, and a window whose frame can't be read can't be
    // placed anyway — pairing it would hand a record to a window nothing can act on.
    let caps = [cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 100)]
    let lives = [
      ColdStartMatch.LiveWindow(id: 31, identity: "com.a", frame: nil),
      live("com.a", id: 32, x: 0, y: 50),
    ]
    let m = assign(caps, lives)
    #expect(m == [901: 32])  // same size ⇒ 901 (first in reading order) claims it; 902 finds nothing left
    #expect(m[902] == nil)  // 31 is never claimed
  }

  @Test func isDeterministicWhenPositionsTie() {
    // `sorted(by:)` is not stable in Swift (the lesson #keeps-20 banked for condition ordering). Two windows
    // at identical coordinates must still pair the same way every run — a restore that shuffles differently
    // each time it runs is its own defect.
    let caps = [cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 0)]
    let lives = [live("com.a", id: 31, x: 1, y: 1), live("com.a", id: 32, x: 1, y: 1)]
    let first = assign(caps, lives)
    #expect(first.count == 2)  // not vacuous — both pair (tier 1, within tolerance)
    for _ in 0..<20 {
      #expect(assign(caps.reversed(), lives.reversed()) == first)
    }
  }

  @Test func toleranceIsTheOnlyKnob() {
    // The brief's tolerance sweep: the fixture below has no near-miss pairs, so the map must be identical at
    // every tolerance — a rule that changed its answer with the knob would be pairing on something else.
    let (caps, lives) = fixture20260826()
    let base = ColdStartMatch.assign(captured: caps, live: lives, tolerance: 0)
    for tol in [0, 2, 5, 50] {
      #expect(ColdStartMatch.assign(captured: caps, live: lives, tolerance: tol) == base)
    }
  }

  @Test func theToleranceParameterIsWired() {
    // Cold review M4: with the parameter ignored (predicates hardcoded to `Restore.frameTolerance`), every
    // test still passed — the sweep above only proved the fixture has no near-miss pairs. This pins the seam
    // with a 3px-off pair: below tolerance it is a size match (tier 3), above it an exact one (tier 1). The
    // shape is real — Chrome popup `26365↔1185` paired 3px off on the 2026-08-26 fleet.
    let caps = [cap("com.a", id: 1, x: 0, y: 0)]
    let lives = [live("com.a", id: 11, x: 3, y: 3)]
    let tight = ColdStartMatch.assign(captured: caps, live: lives, tolerance: 2)
    let loose = ColdStartMatch.assign(captured: caps, live: lives, tolerance: 5)
    #expect((tight.exact, tight.position, tight.size) == (0, 0, 1))
    #expect((loose.exact, loose.position, loose.size) == (1, 0, 0))
    #expect(tight.map == loose.map)  // same pairing, earned by a different tier
  }

  @Test func samePositionClaimsBeforeSameSize() {
    // Cold review M3: swapping tier 2 and tier 3 passed every test. The order is a Decision — a window
    // resized in place is nearer home than one of the same size across the screen — so pin it: one record,
    // one live window at its origin (bigger), one of its size far away.
    let caps = [cap("com.a", id: 1, x: 0, y: 0)]
    let lives = [live("com.a", id: 11, x: 0, y: 0, w: 500, h: 500), live("com.a", id: 12, x: 900, y: 900)]
    let a = ColdStartMatch.assign(captured: caps, live: lives)
    #expect(a.map == [1: 11])
    #expect((a.position, a.size) == (1, 0))
  }

  // MARK: - Properties kept from 5.4

  @Test func neverMatchesAcrossApps() {
    // The safety property `5.1` exists for: a Terminal window must never be resolved to Slack's live window.
    let m = assign(
      [cap("com.terminal", id: 900, x: 0, y: 0)], [live("com.slack", id: 12, x: 0, y: 0)])
    #expect(m.isEmpty)
  }

  @Test func extraCapturedWindowsAreLeftUnmatched() {
    // Three saved, two open ⇒ two resolve and the third falls through to the existing `gone` path. No new
    // "unmatched" concept enters the restore truth table.
    let caps = [
      cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 100),
      cap("com.a", id: 903, x: 0, y: 200),
    ]
    let m = assign(caps, [live("com.a", id: 31, x: 0, y: 0), live("com.a", id: 32, x: 0, y: 100)])
    #expect(m == [901: 31, 902: 32])
    #expect(m[903] == nil)
  }

  @Test func extraLiveWindowsAreLeftAlone() {
    // Two saved, five open ⇒ three live windows are NOT touched. Moving a window the user never asked about
    // would be keeps inventing layout, which is worse than leaving it be.
    let m = assign(
      [cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 100)],
      (0..<5).map { live("com.a", id: UInt32(40 + $0), x: 0, y: $0 * 100) })
    #expect(m == [901: 40, 902: 41])
  }

  @Test func stickyWindowsNeverClaimALiveWindow() {
    // All-desktops windows can't be frame-restored at all (`decide` skips them), so letting one claim a live
    // window would starve a window that CAN be placed.
    let m = assign(
      [cap("com.a", id: 901, x: 0, y: 0, sticky: true), cap("com.a", id: 902, x: 0, y: 100)],
      [live("com.a", id: 31, x: 0, y: 0)])
    #expect(m == [902: 31])
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
    let m = assign(
      [cap("com.a", id: 165, x: 0, y: 0, sticky: true)], [live("com.a", id: 165, x: 0, y: 0)])
    #expect(m.isEmpty, "a sticky captured window must claim no live window")
  }

  @Test func oneLiveWindowIsNeverPromisedToTwoCapturedWindows() {
    // The bijection, asserted as the property that matters rather than as a count. Two captured windows of
    // one app against one live window: exactly one may resolve, and the other must be absent from the map so
    // it classifies gone.
    let m = assign(
      [cap("com.a", id: 901, x: 0, y: 0), cap("com.a", id: 902, x: 0, y: 100)],
      [live("com.a", id: 165, x: 0, y: 0)])
    #expect(m == [901: 165])
  }

  @Test func emptyInputsResolveToNothing() {
    #expect(assign([], []).isEmpty)
    #expect(assign([cap("com.a", id: 1, x: 0, y: 0)], []).isEmpty)
    #expect(assign([], [live("com.a", id: 1, x: 0, y: 0)]).isEmpty)
  }

  // MARK: - The 2026-08-26 fixture — the real post-reboot fleet, verbatim

  /// Saved side: `ebd2d02df1990d1c.json` (saved 19:10). Live side: the `before` frames of the 20:13 dry-run.
  /// Only the apps whose pairing went wrong (or was masked) are included; the rest were exact and boring.
  private func fixture20260826() -> ([CapturedWindow], [ColdStartMatch.LiveWindow]) {
    let chrome = "com.google.Chrome.beta", safari = "com.apple.Safari"
    let gemini = "com.google.GeminiMacOS", zed = "dev.zed.Zed-RBF", codex = "com.openai.codex"
    let caps = [
      cap(chrome, id: 4238, x: -5120, y: -1894, w: 5120, h: 46),  // strip, above any display
      cap(chrome, id: 4237, x: -2221, y: -1832, w: 1826, h: 89),  // strip
      cap(chrome, id: 4235, x: -2560, y: -1817, w: 2560, h: 1425),  // the real window
      cap(chrome, id: 26365, x: -804, y: -1785, w: 403, h: 84),  // popup
      cap(safari, id: 47220, x: 0, y: 39, w: 1200, h: 1130),  // real
      cap(safari, id: 47745, x: 276, y: 91, w: 648, h: 368),  // real, closed since
      cap(safari, id: 29043, x: 401, y: 589, w: 291, h: 111),  // popover
      cap(safari, id: 47219, x: 9, y: 1140, w: 155, h: 20),  // link-preview strip
      cap(gemini, id: 10730, x: 125, y: 273, w: 1024, h: 678),
      cap(zed, id: 43133, x: -5120, y: -392, w: 5120, h: 1425),
      cap(zed, id: 43131, x: -5120, y: -1817, w: 5120, h: 1425),
      cap(codex, id: 47912, x: 0, y: 39, w: 1800, h: 1130),
    ]
    let lives = [
      live(chrome, id: 793, x: -2560, y: -392, w: 2560, h: 1425),
      live(chrome, id: 856, x: -2560, y: -1817, w: 2560, h: 1425),
      live(safari, id: 236, x: 0, y: 39, w: 1200, h: 1130),
      live(safari, id: 234, x: 9, y: 1140, w: 292, h: 20),
      live(gemini, id: 347, x: 548, y: 192, w: 704, h: 520),
      live(gemini, id: 348, x: 125, y: 273, w: 1024, h: 678),
      live(zed, id: 293, x: -5120, y: -1817, w: 5120, h: 1425),
      live(codex, id: 778, x: 0, y: 39, w: 1800, h: 1130),
    ]
    return (caps, lives)
  }

  @Test func theRealFleetOf20260826PairsOnlyOnSharedGeometry() {
    // Under reading order this fleet produced: 4238→856 (a home window told to become an off-screen strip),
    // 4237→793 (a real window told to become a strip), 47745→234 (a strip told to become a window), 10730→347
    // (the wrong Gemini, while 348 sat exactly home), and 4235 — the only real Chrome record — `gone`.
    let (caps, lives) = fixture20260826()
    let a = ColdStartMatch.assign(captured: caps, live: lives)
    #expect(
      a.map == [
        4235: 856, 47220: 236, 47219: 234, 10730: 348, 43131: 293, 47912: 778,
      ])
    #expect((a.exact, a.position, a.size) == (5, 1, 0))
    // Left alone, by construction: the second real Chrome window and the second Gemini window.
    #expect(!a.map.values.contains(793))
    #expect(!a.map.values.contains(347))
  }
}
