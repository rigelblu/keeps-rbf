// Scenario B made executable — the spaceUUID → GLOBAL ⌥⌘N ordinal map, with the cross-display case pinned.
// The per-display index equals the ⌥⌘N number only on the FIRST display; on later displays they diverge by the
// preceding displays' desktop counts. That divergence is the bug the #keeps-6 seed shipped (it read the per-display
// index as the global number), so display-1-and-beyond is the load-bearing assertion here. Pure — no CGS call.
import Testing

@testable import Core

@Suite struct DesktopIndexTests {
  // The probe's live topology: 12 / 5 / 4 desktops across 3 displays = 21 (uuid "d{disp}s{idx}", managedID disp*100+idx).
  private func index() -> DesktopIndex {
    func display(_ d: Int, _ count: Int) -> DesktopIndex.Display {
      DesktopIndex.Display(
        identifier: "DISP-\(d)",
        spaces: (0..<count).map {
          DesktopIndex.Space(uuid: "d\(d)s\($0)", managedID: d * 100 + $0)
        },
        currentIndex: 0)
    }
    return DesktopIndex(displays: [display(0, 12), display(1, 5), display(2, 4)])
  }

  @Test func firstDisplayOrdinalEqualsPerDisplayIndex() {  // the only display where global == per-display
    #expect(index().globalOrdinal(ofSpaceUUID: "d0s0") == 1)
    #expect(index().globalOrdinal(ofSpaceUUID: "d0s11") == 12)
  }

  @Test func laterDisplayOrdinalAddsPrecedingDesktops() {  // the seed's bug: display 1's 5th desktop is GLOBAL 17, not 5
    #expect(index().globalOrdinal(ofSpaceUUID: "d1s4") == 17)  // 12 + (4+1)
    #expect(index().globalOrdinal(ofSpaceUUID: "d2s0") == 18)  // 12 + 5 + (0+1)
    #expect(index().globalOrdinal(ofSpaceUUID: "d2s3") == 21)  // last desktop
  }

  @Test func managedIDResolvesToSameGlobalAsUUID() {  // a window's CURRENT desktop (cgsSpacesForWindow gives ints)
    #expect(index().globalOrdinal(ofManagedID: 104) == 17)  // display 1, managedID 1*100+4
    #expect(index().globalOrdinal(ofManagedID: 0) == 1)  // display 0, managedID 0
  }

  @Test func absentSpaceIsNil() {  // captured desktop deleted since capture → the carry skips `targetGone`
    #expect(index().globalOrdinal(ofSpaceUUID: "ghost") == nil)
    #expect(index().globalOrdinal(ofManagedID: 999) == nil)
  }

  @Test func locateMapsGlobalBackToDisplayAndIndex() {  // the navigation target: which display, which desktop
    let a = index().locate(global: 17)
    #expect(a?.displayIndex == 1 && a?.perDisplayIndex == 4)
    let b = index().locate(global: 18)
    #expect(b?.displayIndex == 2 && b?.perDisplayIndex == 0)
    let c = index().locate(global: 1)
    #expect(c?.displayIndex == 0 && c?.perDisplayIndex == 0)
  }

  @Test func locateOutOfRangeIsNil() {
    #expect(index().locate(global: 22) == nil)  // only 21 desktops
    #expect(index().locate(global: 0) == nil)
  }

  @Test func totalDesktopsSumsAllDisplays() {
    #expect(index().totalDesktops == 21)
  }

  @Test func uuidOfManagedIDSpeaksTheCapturedIdentity() {  // #keeps-17 verify-after-place: landed int → stable uuid
    #expect(index().uuid(ofManagedID: 104) == "d1s4")
    #expect(index().uuid(ofManagedID: 999) == nil)
  }

  @Test func uuidOfManagedIDTreatsEmptyAsUnknown() {  // CGS can leave a space's uuid "" — unknown, never ""
    let idx = DesktopIndex(displays: [
      DesktopIndex.Display(
        identifier: "D", spaces: [DesktopIndex.Space(uuid: "", managedID: 7)], currentIndex: nil)
    ])
    #expect(idx.uuid(ofManagedID: 7) == nil)
  }
}
