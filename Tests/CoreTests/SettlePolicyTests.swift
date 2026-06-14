// The auto-restore trigger's truth table (#keeps-3). Both skip cases came from dogfeel (2026-06-14): a display
// sleep empties the config (skipNoDisplays), and sleep/wake re-enters the same config (skipNoChange) — neither
// must fire a restore that reverts a deliberate rearrangement.
import Testing

@testable import Core

@Suite struct SettlePolicyTests {
  private let docked = "80bc74744ed01909"
  private let undocked = "8a09103d5a98d868"
  private let empty = "e3b0c44298fc1c14"  // SHA-256("") — what a display sleep produces

  @Test func noActiveDisplaysAlwaysSkips() {  // gate A wins regardless of known/lastSettled
    #expect(
      SettlePolicy.decide(fingerprint: empty, degenerate: true, lastSettled: docked, known: true)
        == .skipNoDisplays)
    #expect(
      SettlePolicy.decide(fingerprint: empty, degenerate: true, lastSettled: nil, known: false)
        == .skipNoDisplays)
  }

  @Test func sameConfigSkipsTheSpuriousRestore() {  // the sleep/wake Flavor-B case: 80bc → [empty] → 80bc
    #expect(
      SettlePolicy.decide(fingerprint: docked, degenerate: false, lastSettled: docked, known: true)
        == .skipNoChange)
  }

  @Test func knownChangedConfigRestores() {  // real re-dock: came back from a DIFFERENT config
    #expect(
      SettlePolicy.decide(
        fingerprint: docked, degenerate: false, lastSettled: undocked, known: true) == .restore)
  }

  @Test func unknownChangedConfigCaptures() {  // entered a never-seen config → learn it
    #expect(
      SettlePolicy.decide(
        fingerprint: undocked, degenerate: false, lastSettled: docked, known: false) == .capture)
  }

  @Test func firstSettleAfterLaunchActs() {  // lastSettled == nil is NOT a no-change
    #expect(
      SettlePolicy.decide(fingerprint: docked, degenerate: false, lastSettled: nil, known: true)
        == .restore)
    #expect(
      SettlePolicy.decide(fingerprint: docked, degenerate: false, lastSettled: nil, known: false)
        == .capture)
  }
}
