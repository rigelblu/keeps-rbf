// The capture filter as a truth table — every keep and every drop reason, with no I/O.
// This is Scenario A made executable: the #stay-6 regression (silently losing real windows) becomes
// a red test, and each drop reason is pinned so the 0-space junk filter can't quietly start eating real windows.
import Testing
import CoreGraphics
@testable import Core

@Suite struct CaptureDecisionTests {
    let index: [Int: Capture.SpaceLoc] = [9: .init(displayUUID: "DISP-A", ordinal: 3, spaceUUID: "SPACE-9")]

    private func candidate(
        bundleId: String? = "com.example.app", layer: Int = 0, wid: CGWindowID = 1,
        frame: WindowFrame? = WindowFrame(x: 100, y: 100, w: 800, h: 600), spaces: [Int] = [9]
    ) -> Capture.Candidate {
        Capture.Candidate(bundleId: bundleId, pid: 42, layer: layer, wid: wid,
                          frame: frame, title: "t", onScreen: true, spaces: spaces)
    }

    @Test func keepsRealPlacedWindowWithAttribution() throws {
        guard case .keep(let w) = Capture.decide(candidate(), spaceIndex: index) else {
            Issue.record("expected a real single-space window to be kept"); return
        }
        #expect(w.displayUUID == "DISP-A")
        #expect(w.desktopOrdinal == 3)
        #expect(w.spaceUUID == "SPACE-9")
        #expect(w.sticky == false)
    }

    @Test func allDesktopsWindowIsKeptButFlaggedSticky() throws {
        guard case .keep(let w) = Capture.decide(candidate(spaces: [9, 10, 11]), spaceIndex: index) else {
            Issue.record("expected an all-desktops window to be kept (flagged)"); return
        }
        #expect(w.sticky == true)
        #expect(w.desktopOrdinal == nil)   // no single ordinal to restore to
        #expect(w.displayUUID == nil)
        #expect(w.spaceUUID == nil)
    }

    @Test func dropsNonRegularApp() {
        #expect(Capture.decide(candidate(bundleId: nil), spaceIndex: index) == .drop(.notRegularApp))
    }

    @Test func dropsNonNormalLayer() {
        #expect(Capture.decide(candidate(layer: 25), spaceIndex: index) == .drop(.notNormalLayer))
    }

    @Test func dropsZeroWindowId() {   // wid == 0 ⇒ honest .noWindowID, never a false .noSpace (H1)
        #expect(Capture.decide(candidate(wid: 0), spaceIndex: index) == .drop(.noWindowID))
    }

    @Test func dropsMissingBounds() {
        #expect(Capture.decide(candidate(frame: nil), spaceIndex: index) == .drop(.noBounds))
    }

    @Test func dropsZeroSpaceJunk() {   // the 3840×30 strips / placeholders / minimized
        #expect(Capture.decide(candidate(spaces: []), spaceIndex: index) == .drop(.noSpace))
    }

    @Test func dropsDegenerateFrame() {
        #expect(Capture.decide(candidate(frame: WindowFrame(x: 0, y: 0, w: 0, h: 0)), spaceIndex: index)
                == .drop(.degenerateFrame))
    }

    @Test func unknownSpaceKeepsWindowUnattributed() throws {   // on one space, but not in our index
        guard case .keep(let w) = Capture.decide(candidate(spaces: [999]), spaceIndex: index) else {
            Issue.record("a single-space window should still be kept even if the space isn't indexed"); return
        }
        #expect(w.desktopOrdinal == nil)
        #expect(w.sticky == false)        // it IS on exactly one space; we just couldn't map it
    }
}
