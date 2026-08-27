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

    @Test func dragPathEndsExactlyOneDragToTheRight() {
        let p = CGPoint(x: -5104, y: -387)
        let path = Carry.dragPath(from: p)
        #expect(path.count == 3)
        #expect(path.last == CGPoint(x: p.x + Carry.gripDrag, y: p.y))
        #expect(path.allSatisfy { $0.y == p.y })
        #expect(path.map(\.x) == path.map(\.x).sorted())
    }

    @Test func dragPathWithZeroStepsIsEmpty() {
        #expect(Carry.dragPath(from: .zero, steps: 0).isEmpty)
    }

    /// The new reason is a first-class `CarrySkip`: counted, traced, rendered like every other.
    @Test func gripNotTakenIsAFirstClassReason() {
        #expect(Carry.CarrySkip.allCases.contains(.gripNotTaken))
        #expect(Carry.CarrySkip.gripNotTaken.rawValue == "gripNotTaken")
    }
}
