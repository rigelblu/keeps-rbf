// CarryAffordance — the #keeps-13 one-tap offer gate. The carry is never silent-automatic (it hijacks the cursor
// + active Space), so phase 1 (#keeps-3 silent restore) runs automatically and this only decides whether to OFFER
// phase 2 and for how many windows. A fresh restore replaces any prior offer; nothing stranded clears it.
import Testing

@testable import Core

@Suite struct CarryAffordanceTests {
  private let docked = "80bc74744ed01909"
  private let undocked = "8a09103d5a98d868"

  @Test func strandedWindowsRaiseAnOffer() {  // windows remain on other Spaces → offer the one-tap carry
    #expect(
      CarryAffordance.afterRestore(fingerprint: docked, deferred: 3)
        == PendingCarry(fingerprint: docked, count: 3))
  }

  @Test func nothingStrandedClearsTheOffer() {  // phase 1 reached everything on the current Space → no offer
    #expect(CarryAffordance.afterRestore(fingerprint: docked, deferred: 0) == nil)
  }

  @Test func oneStrandedWindowStillOffers() {  // the boundary: a single off-Space window is worth offering
    #expect(
      CarryAffordance.afterRestore(fingerprint: docked, deferred: 1)
        == PendingCarry(fingerprint: docked, count: 1))
  }

  @Test func theOfferBelongsToItsConfig() {  // fingerprint rides along so the host can reject a stale-config tap
    let a = CarryAffordance.afterRestore(fingerprint: docked, deferred: 2)
    let b = CarryAffordance.afterRestore(fingerprint: undocked, deferred: 2)
    #expect(a?.fingerprint == docked)
    #expect(b?.fingerprint == undocked)
    #expect(a != b)  // same count, different config → distinct offers (newest restore wins; offers never stack)
  }
}
