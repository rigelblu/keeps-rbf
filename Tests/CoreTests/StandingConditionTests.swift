// StandingCondition — the #keeps-20 pure layer.
//
// WHAT THIS FILE COVERS, stated honestly because the first draft did not: the glyph composition and the
// honesty properties of the copy. WHAT IT DOES NOT COVER: persistence — the actual defect. Persistence is
// writer discipline in `main.swift` (the mark living inside `baseGlyph()` so no reset can drop it), there is
// no host test target, and no assertion in this file would fail if that discipline were broken. It is
// verified by scenario S2 in `test-suite/review.md` and by nothing here.
//
// That distinction matters in this repo: #keeps-21 shipped a defect precisely because a test asserted the
// wrong string under a confident comment, so 95 green tests endorsed it. A header claiming coverage it
// doesn't have is the same failure in a new place.
//
// The copy tests below assert PROPERTIES (does the label promise only what keeps can deliver) rather than
// exact strings wherever possible, so a copy edit doesn't fail the suite while a dishonest label would.
import Foundation
import Testing

@testable import Core

@Suite struct StandingConditionTests {

  // MARK: Copy honesty — the property, not the wording

  @Test func onlyAStateKeepsCanFixEarnsACommandLabel() {
    // The property the design rests on: a label routes to Settings exactly when keeps CANNOT do the thing
    // itself. A verb-first label is a promise, and only .notificationsNotAsked can keep it —
    // requestAuthorization returns false forever once denied.
    for c in StandingCondition.allCases {
      #expect(
        c.label.contains("open Settings") == !c.keepsCanFixItself,
        "\(c): a label may promise action iff keeps can deliver it — label \"\(c.label)\"")
    }
  }

  @Test func fixableInAppMeansTheRemedyNeverLeavesTheApp() {
    // Was `exactlyOneStateCanBeFixedInApp`, asserting the set equals [.notificationsNotAsked]. That was an
    // ENUMERATION SNAPSHOT, not a property: it was true only because one state happened to be in-app, so
    // #keeps-5's `.fixInApp` (a stale snapshot — keeps runs Save itself, no OS involved) broke it correctly.
    //
    // Rewritten as the property it was always standing in for, per this feature's own review lesson (#keeps-20
    // finding #5): a test named for a guarantee should assert the guarantee. The list would have needed
    // editing on every future state; the property will not.
    for c in StandingCondition.allCases {
      switch c.remedy {
      case .promptInApp, .fixInApp:
        #expect(c.keepsCanFixItself, "\(c): remedy stays in-app, so keeps must claim it can fix it")
      case .openSettings:
        #expect(!c.keepsCanFixItself, "\(c): only Settings can clear it — keeps must not claim otherwise")
      }
    }
  }

  @Test func theTwoInAppRemediesAreNotInterchangeable() {
    // #keeps-5 added a third remedy rather than widening `.promptInApp`, because the two differ in a way the
    // user feels: an OS authorization dialog can REFUSE, and running Save cannot. Collapsing them would put a
    // label on the stale-snapshot line that promises something an OS prompt might not deliver.
    #expect(StandingCondition.notificationsNotAsked.remedy == .promptInApp)
    #expect(StandingCondition.savedLayoutUnmatchable.remedy == .fixInApp)
    #expect(StandingCondition.notificationsNotAsked.remedy != StandingCondition.savedLayoutUnmatchable.remedy)
  }

  @Test func severityRanksByHowMuchIsBrokenRightNow() {
    // Severity is user-facing: the top line is the one read first, so the order encodes urgency, not
    // category. Reading down: keeps can't move a window at all → can't reach you → won't act on a memory it
    // can't trust (this session) → won't come back by itself (next session). The last is deliberately
    // LOWEST: keeps is working fine right now, it just may not be here after a reboot.
    //
    // Written as the explicit expected order. The first draft asserted "everything outranks the stale line",
    // which was only true while that line happened to be last — `loginItemBlocked` broke it immediately.
    // Pinning the order says what we mean; pinning a superlative says what was accidentally true.
    let expected: [StandingCondition] = [
      .accessibilityOff,  // 0 — keeps does nothing at all
      .notificationsNotAsked, .notificationsDenied, .notificationBannersOff,  // 1 — can't reach you
      .savedLayoutUnmatchable,  // 2 — declines to act, this session
      .loginItemBlocked,  // 3 — may not be running next session
    ]
    #expect(
      Set(expected) == Set(StandingCondition.allCases),
      "a new condition was added without placing it in the expected order")
    for (a, b) in zip(expected, expected.dropFirst()) {
      #expect(a.severity <= b.severity, "\(a) must not sort below \(b)")
    }
    // And sorting must be a total order — equal severities break on declaration order, because `sorted(by:)`
    // is not stable in Swift and menu lines that shuffle between reads would be their own defect.
    #expect(StandingCondition.sorted(expected.reversed()) == expected)
  }

  @Test func deniedNeverRoutesToAnInAppPrompt() {
    // requestAuthorization cannot clear a denial; a prompt remedy here would be a dead button.
    #expect(!StandingCondition.notificationsDenied.keepsCanFixItself)
    #expect(!StandingCondition.notificationBannersOff.keepsCanFixItself)
    #expect(!StandingCondition.accessibilityOff.keepsCanFixItself)
  }

  @Test func everyStateHasItsOwnLabelAndTraceName() {
    // Distinct fixes need distinct lines — a copy/paste that collapsed two states into one wording would
    // send the user to fix the wrong thing.
    let labels = Set(StandingCondition.allCases.map(\.label))
    let traces = Set(StandingCondition.allCases.map(\.traceName))
    #expect(labels.count == StandingCondition.allCases.count)
    #expect(traces.count == StandingCondition.allCases.count)
  }

  @Test func bannersOffIsItsOwnStateNotFoldedIntoDenied() {
    // Authorized-with-alerts-off is user-identical to denied (no banner ever appears) but has a different
    // cause and therefore a different fix. Folding them would send the user to the wrong toggle.
    #expect(StandingCondition.notificationBannersOff.label != StandingCondition.notificationsDenied.label)
    #expect(StandingCondition.notificationBannersOff.remedy == StandingCondition.notificationsDenied.remedy)
  }

  // MARK: Settings anchors — pinned, because nothing at runtime can catch a bad one

  @Test func settingsAnchorsArePinnedExactly() {
    // Deliberately exact-string, unlike the copy above. `URL(string:)` accepts
    // "x-apple.systempreferences:com.apple.TOTAL-GARBAGE" and NSWorkspace.open returns true for any
    // REGISTERED SCHEME regardless of whether the pane id resolves — so a wrong anchor is invisible at
    // runtime AND to any well-formedness check. Pinning makes a change deliberate; only the human scenario
    // in test-suite/review.md can prove an anchor still lands.
    #expect(
      StandingCondition.notificationsDenied.remedy
        == .openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension"))
    #expect(
      StandingCondition.accessibilityOff.remedy
        == .openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
  }

  // MARK: Ordering — a total order, not merely a sort

  @Test func accessibilitySortsAboveNotifications() {
    // Without AX keeps does nothing at all; notifications only decide whether it can reach you.
    #expect(
      StandingCondition.sorted([.notificationsDenied, .accessibilityOff])
        == [.accessibilityOff, .notificationsDenied])
  }

  @Test func equalSeverityStillOrdersDeterministically() {
    // Array.sorted(by:) is NOT stable in Swift, so equal severities would come out unspecified without the
    // declaration-order tiebreak. Menu lines that shuffle between reads would be their own defect.
    let a = StandingCondition.sorted([.notificationBannersOff, .notificationsNotAsked])
    let b = StandingCondition.sorted([.notificationsNotAsked, .notificationBannersOff])
    #expect(a == b, "equal-severity ordering must not depend on input order")
  }

  @Test func sortingHandlesTheEmptyAndSingleCases() {
    #expect(StandingCondition.sorted([]) == [])
    #expect(StandingCondition.sorted([.notificationsNotAsked]) == [.notificationsNotAsked])
  }

  // MARK: The resting glyph — all four compositions

  @Test func cleanRestingGlyphIsByteIdenticalToTheOldBaseGlyph() {
    // The no-condition cases must render exactly as before, or every existing expectation about the menu
    // bar silently shifts under a change that claims to add something.
    #expect(StandingCondition.glyph(conditions: [], offerCount: nil) == "▢")
    #expect(StandingCondition.glyph(conditions: [], offerCount: 3) == "▢ 3")
  }

  @Test func conditionMarkLeadsAndSurvivesAPendingCount() {
    // The mark leads because the count describes work keeps INTENDS to do while the mark says it cannot.
    #expect(StandingCondition.glyph(conditions: [.accessibilityOff], offerCount: nil) == "!▢")
    #expect(StandingCondition.glyph(conditions: [.accessibilityOff], offerCount: 3) == "!▢ 3")
  }

  @Test func manyConditionsStillRenderOneMark() {
    // The glyph says "something is standing in the way", not how many — the menu lines carry the specifics.
    #expect(
      StandingCondition.glyph(conditions: [.accessibilityOff, .notificationsDenied], offerCount: 2) == "!▢ 2")
  }

  @Test func theGlyphNeverBorrowsTheTransientWarningMark() {
    // "⚠" means *this run had a problem* and it decays after 1.2s. A standing condition wearing it would be
    // indistinguishable from a transient — which is the confusion this whole feature exists to remove.
    // Checked on the GLYPH, where the risk actually lives; the first draft checked labels, which never
    // contained it.
    for c in StandingCondition.allCases {
      #expect(!StandingCondition.glyph(conditions: [c], offerCount: nil).contains("⚠"))
      #expect(!StandingCondition.glyph(conditions: [c], offerCount: 4).contains("⚠"))
    }
  }

  @Test func aZeroOfferCountIsNotTheSameAsNoOffer() {
    // nil means "no offer stands"; 0 would be a real (if odd) count and must still render as a badge, so a
    // future caller passing 0 can't silently look like the clean state.
    #expect(StandingCondition.glyph(conditions: [], offerCount: 0) == "▢ 0")
  }
}
