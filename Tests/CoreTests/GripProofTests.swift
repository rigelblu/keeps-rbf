import CoreGraphics
import Testing
@testable import Core

// #keeps-26 — the proof that a grab took, and the drag that produces it. Pure: the I/O (posting the drag,
// polling the bounds) lives in `grabTitlebar`; this is the decision it makes from what it read.
@Suite struct GripProofTests {
    private func rect(x: CGFloat, y: CGFloat = 100) -> CGRect { CGRect(x: x, y: y, width: 800, height: 600) }

    @Test func fullDragTakes() {
        #expect(Carry.gripTook(before: rect(x: 0), after: rect(x: 8)))
    }

    @Test func halfTheDragTakes() {
        #expect(Carry.gripTook(before: rect(x: 0), after: rect(x: 4)))
    }

    @Test func justUnderHalfDoesNot() {
        #expect(!Carry.gripTook(before: rect(x: 0), after: rect(x: 3)))
    }

    /// An app that anchors the move on the FIRST drag event travels 2/3 of a 3-step drag (~5.3px of 8).
    /// That grab took; the bar must say so.
    @Test func firstEventAnchoredMoveTakes() {
        #expect(Carry.gripTook(before: rect(x: 0), after: rect(x: 5.3)))
    }

    @Test func movingLeftDoesNot() {
        #expect(!Carry.gripTook(before: rect(x: 0), after: rect(x: -8)))
    }

    @Test func movingOnlyInYDoesNot() {
        #expect(!Carry.gripTook(before: rect(x: 0, y: 100), after: rect(x: 0, y: 108)))
    }

    @Test func noMoveDoesNot() {
        #expect(!Carry.gripTook(before: rect(x: 0), after: rect(x: 0)))
    }

    /// The bar derives from the drag — a disconnected `drag` parameter would pass this with the 8px default.
    @Test func theBarIsDerivedFromTheDrag() {
        #expect(!Carry.gripTook(before: rect(x: 0), after: rect(x: 7), drag: 16))
        #expect(Carry.gripTook(before: rect(x: 0), after: rect(x: 8), drag: 16))
    }

    // MARK: #keeps-38.1 — the step drag

    @Test func stepPathStepsTwoPixelsToTheLimit() {
        let p = CGPoint(x: -5104, y: -387)
        let path = Carry.stepPath(from: p, limit: Carry.gripLimit)
        #expect(path.count == 20)
        #expect(path.first == CGPoint(x: p.x + 2, y: p.y))
        #expect(path.last == CGPoint(x: p.x + 40, y: p.y))
        #expect(path.allSatisfy { $0.y == p.y })
        #expect(zip(path, path.dropFirst()).allSatisfy { $1.x - $0.x == 2 })
    }

    @Test func stepPathBelowOneStepIsEmpty() {
        #expect(Carry.stepPath(from: .zero, limit: 1).isEmpty)
        #expect(Carry.stepPath(from: .zero, step: 0, limit: 40).isEmpty)
    }

    /// The 2026-10-30 measurement: no move at 8px, a move at 10px that catches up to the cursor.
    @Test func aWindowThatCatchesUpAtTenPixelsFollowsThere() {
        #expect(!Carry.gripTook(before: rect(x: 0), after: rect(x: 0), drag: 8))
        #expect(Carry.gripTook(before: rect(x: 0), after: rect(x: 10), drag: 10))
    }

    /// An app that anchors the move on the first drag event lags one 2px step behind the cursor.
    @Test func aWindowLaggingOneStepFollowsWithinThreeSteps() {
        #expect(!Carry.gripTook(before: rect(x: 0), after: rect(x: 0), drag: 2))
        #expect(!Carry.gripTook(before: rect(x: 0), after: rect(x: 2), drag: 4))   // 2 < max(2, 3)
        #expect(Carry.gripTook(before: rect(x: 0), after: rect(x: 4), drag: 6))
    }

    /// The 3px floor: half of a 2px step is 1px, and a 1px nudge is not a follow.
    @Test func aOnePixelNudgeIsNeverAFollow() {
        #expect(!Carry.gripTook(before: rect(x: 0), after: rect(x: 1), drag: 2))
        #expect(!Carry.gripTook(before: rect(x: 0), after: rect(x: 2), drag: 2))
        #expect(Carry.gripTook(before: rect(x: 0), after: rect(x: 3), drag: 2))
    }

    @Test func aButtonRowPointDragsFortyAFallbackPointEight() {
        #expect(Carry.dragLimit(for: .closeButtonTop) == 40)
        #expect(Carry.dragLimit(for: .trafficLightGap) == 40)
        #expect(Carry.dragLimit(for: .trafficLightRow) == 40)
        #expect(Carry.dragLimit(for: .knownGoodFallback) == 8)
    }

    // MARK: #keeps-38.3 — the points a window is pressed at

    private let ghosttyButtons = Carry.ChromeButtonFrames(
        close: CGRect(x: 389, y: 294, width: 16, height: 16),
        minimize: CGRect(x: 409, y: 294, width: 16, height: 16),
        zoom: CGRect(x: 429, y: 294, width: 16, height: 16))
    private let ghostty = CGRect(x: 381, y: 286, width: 888, height: 584)

    @Test func theRowKeepsThreePointsInOrderAndDropsTheHighGap() {
        let all = Carry.gripProfile(windowBounds: ghostty, buttons: ghosttyButtons).candidates
        let row = Carry.rowCandidates(all)
        #expect(row.map(\.source) == [.closeButtonTop, .trafficLightGap, .trafficLightRow])
        #expect(row[0].point == CGPoint(x: 397, y: 291))   // 5px below the top: never moved Ghostty
        #expect(row[1].point == CGPoint(x: 407, y: 302))   // the gap at the row's middle: moved it at 8px
        #expect(!row.contains { $0.source == .knownGoodFallback })
    }

    /// Buttons touching the window's top edge: the high gap point falls outside the window and never exists,
    /// and so does close-button top — the one gap point left is the row's middle, and it stays.
    @Test func aWindowWithButtonsAtItsTopEdgeKeepsItsOnlyGap() {
        let top = CGRect(x: 0, y: 0, width: 800, height: 600)
        let buttons = Carry.ChromeButtonFrames(close: CGRect(x: 8, y: 1, width: 16, height: 16),
                                               minimize: CGRect(x: 28, y: 1, width: 16, height: 16),
                                               zoom: CGRect(x: 48, y: 1, width: 16, height: 16))
        let row = Carry.rowCandidates(Carry.gripProfile(windowBounds: top, buttons: buttons).candidates)
        #expect(row.map(\.source) == [.trafficLightGap, .trafficLightRow])
        #expect(row[0].point.y == 9)
    }

    @Test func aWindowWithAButtonRowIsPressedOnlyInTheRow() {
        let all = Carry.gripProfile(windowBounds: ghostty, buttons: ghosttyButtons).candidates
        #expect(Carry.gripTries(all) == Carry.rowCandidates(all))
    }

    /// No AX buttons → only fallback points → the first one, once, as before #keeps-38.
    @Test func aWindowWithNoButtonRowIsPressedOnceAtItsFirstPoint() {
        let none = Carry.ChromeButtonFrames(close: nil, minimize: nil, zoom: nil)
        let all = Carry.gripProfile(windowBounds: ghostty, buttons: none).candidates
        #expect(Carry.gripTries(all) == [all[0]])
        #expect(Carry.gripTries(all)[0].source == .knownGoodFallback)
        #expect(Carry.gripTries([]).isEmpty)
    }

    // MARK: #keeps-38.2 — the [grab] line, one shape per verdict

    private func attempt(_ verdict: Carry.GripTry.Verdict, source: Carry.GripCandidateSource = .closeButtonTop,
                         point: CGPoint = CGPoint(x: 16, y: 44), index: Int = 0, of: Int = 3,
                         limit: CGFloat = 40, dragged: CGFloat = 10, moved: CGVector? = CGVector(dx: 10, dy: 0),
                         ms: Int? = 556) -> Carry.GripTry {
        Carry.GripTry(bundleId: "dev.zed.Zed-RBF", cgWindowId: 265, title: "", source: source, point: point,
                      windowOrigin: CGPoint(x: 0, y: 39), index: index, of: of, limit: limit, dragged: dragged,
                      verdict: verdict, moved: moved, ms: ms)
    }

    @Test func aFollowedPressRendersWhereItFollowed() {
        #expect(attempt(.followed(at: 10)).traceLine
            == #"[grab] dev.zed.Zed-RBF wid=265 "" — try 1/3 closeButtonTop at (16,44), window+(16,5) — followed at 10px, moved (10,0), 556ms"#)
    }

    @Test func aPressThatNeverTookRendersItsLimit() {
        #expect(attempt(.notFollowed, dragged: 40, moved: CGVector(dx: 0, dy: 0), ms: 1880).traceLine
            .hasSuffix("— not followed by 40px, moved (0,0), 1880ms"))
        #expect(attempt(.notFollowed, source: .knownGoodFallback, of: 1, limit: 8, dragged: 8,
                        moved: CGVector(dx: 0, dy: 0), ms: 1240).traceLine
            .hasSuffix("try 1/1 knownGoodFallback at (16,44), window+(16,5) — not followed by 8px, moved (0,0), 1240ms"))
    }

    @Test func aVanishedWindowRendersAQuestionMark() {
        #expect(attempt(.vanished, dragged: 6, moved: nil, ms: 420).traceLine
            .hasSuffix("— window gone at 6px, moved ?, 420ms"))
    }

    @Test func aHandStopDuringThePressRendersHowFarItGot() {
        #expect(attempt(.stoppedByHand, dragged: 4, moved: CGVector(dx: 0, dy: 0), ms: 410).traceLine
            .hasSuffix("— stopped by hand at 4px, moved (0,0), 410ms"))
    }

    /// os_log runs with the trace off, so its line never carries the window title.
    @Test func theOsLogLineLeavesOutTheTitle() {
        let titled = Carry.GripTry(bundleId: "com.apple.Safari", cgWindowId: 7, title: "Bank — Statement", source: .closeButtonTop,
                                   point: CGPoint(x: 16, y: 44), windowOrigin: CGPoint(x: 0, y: 39), index: 0, of: 3,
                                   limit: 40, dragged: 10, verdict: .followed(at: 10), moved: CGVector(dx: 10, dy: 0), ms: 556)
        #expect(!titled.osLogLine.contains("Bank"))
        #expect(titled.osLogLine == "grab com.apple.Safari wid=7 — try 1/3 closeButtonTop at (16,44), window+(16,5) — followed at 10px, moved (10,0), 556ms")
        #expect(titled.traceLine.contains("\"Bank — Statement\""))
    }

    @Test func aHandStopBeforeThePressSaysNoMouseDownWasPosted() {
        #expect(attempt(.stoppedBeforePress, index: 1, ms: nil).traceLine
            .hasSuffix("— try 2/3 closeButtonTop at (16,44), window+(16,5) — stopped by hand before the press — no mouse-down"))
    }

    /// The new reason is a first-class `CarrySkip`: counted, traced, rendered like every other.
    @Test func gripNotTakenIsAFirstClassReason() {
        #expect(Carry.CarrySkip.allCases.contains(.gripNotTaken))
        #expect(Carry.CarrySkip.gripNotTaken.rawValue == "gripNotTaken")
    }
}
