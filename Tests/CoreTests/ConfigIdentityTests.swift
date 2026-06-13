// The config fingerprint must be deterministic, order-independent (it's a set), and distinct per set —
// because it's the filename #keeps-3 will look up. A collision or instability silently mixes two setups.
import Testing

@testable import Core

@Suite struct ConfigIdentityTests {
  @Test func deterministicAndOrderIndependent() {
    let a = ConfigIdentity.fingerprint(of: ["UUID-B", "UUID-A", "UUID-C"])
    let b = ConfigIdentity.fingerprint(of: ["UUID-A", "UUID-C", "UUID-B"])
    #expect(a == b)  // order-independent (it's a set)
    #expect(a == ConfigIdentity.fingerprint(of: ["UUID-B", "UUID-A", "UUID-C"]))  // deterministic
    #expect(a.count == 16)  // stable, filename-safe length
  }

  @Test func distinctSetsProduceDistinctKeys() {
    let macbookOnly = ConfigIdentity.fingerprint(of: ["INTERNAL"])
    let oneExternal = ConfigIdentity.fingerprint(of: ["INTERNAL", "EXT-1"])
    let twoExternal = ConfigIdentity.fingerprint(of: ["INTERNAL", "EXT-1", "EXT-2"])
    #expect(Set([macbookOnly, oneExternal, twoExternal]).count == 3)  // no collisions across Tom's 3 setups
  }
}
