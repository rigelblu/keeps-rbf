import CoreGraphics
import Testing
@testable import Core

@Suite struct GripProfileTests {
    private func buttons(window: CGRect, left: CGFloat, top: CGFloat) -> Carry.ChromeButtonFrames {
        Carry.ChromeButtonFrames(
            close: CGRect(x: window.minX + left, y: window.minY + top, width: 14, height: 14),
            minimize: CGRect(x: window.minX + left + 23, y: window.minY + top, width: 14, height: 14),
            zoom: CGRect(x: window.minX + left + 46, y: window.minY + top, width: 14, height: 14)
        )
    }

    @Test func derivesCloseButtonTopBeforeGapsAndFallbacks() {
        let window = CGRect(x: 100, y: 100, width: 900, height: 600)
        let profile = Carry.gripProfile(windowBounds: window, buttons: buttons(window: window, left: 18, top: 18))

        #expect(profile.candidates.first?.source == .closeButtonTop)
        #expect(abs((profile.candidates.first?.point.x ?? 0) - 125.0) < 0.1)
        #expect(abs((profile.candidates.first?.point.y ?? 0) - 115.0) < 0.1)
        #expect(profile.candidates.contains { $0.source == .trafficLightGap })
        #expect(profile.candidates.contains { $0.source == .knownGoodFallback })
    }

    @Test func appSpecificTrafficLightOffsetsStillProduceDerivedCandidates() {
        let window = CGRect(x: 40, y: 80, width: 700, height: 500)
        let offsets: [(CGFloat, CGFloat)] = [
            (18, 18),   // Safari
            (8, 8),     // Zed
            (11, 11),   // Figma
            (11, 10),   // Warp
        ]

        for offset in offsets {
            let profile = Carry.gripProfile(windowBounds: window, buttons: buttons(window: window, left: offset.0, top: offset.1))
            #expect(profile.candidates.first?.source == .closeButtonTop)
            #expect(window.contains(profile.candidates.first!.point))
        }
    }

    @Test func filtersGripCandidatesToTargetPhysicalDisplay() {
        let window = CGRect(x: 80, y: 20, width: 80, height: 100)   // center is on the right display
        let candidates = [
            Carry.GripCandidate(source: .knownGoodFallback, point: CGPoint(x: 90, y: 40)),
            Carry.GripCandidate(source: .trafficLightGap, point: CGPoint(x: 130, y: 40)),
        ]
        let displays = [
            CGRect(x: 0, y: 0, width: 100, height: 200),
            CGRect(x: 100, y: 0, width: 200, height: 200),
        ]

        let filtered = Carry.candidatesOnTargetDisplay(candidates, windowBounds: window, displayBounds: displays)
        #expect(filtered == [candidates[1]])
    }
}
