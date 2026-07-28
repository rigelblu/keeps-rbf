import Foundation
// The store is the source of truth #keeps-3 reads back, so a save→load round-trip must be lossless,
// and a write must be atomic (a crash mid-write never leaves a half-file — Scenario D).
import Testing

@testable import Core

@Suite struct StoreTests {
  private func sampleSnapshot() -> Snapshot {
    Snapshot(
      schema: captureSchema,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),  // whole second ⇒ ISO8601-stable
      configFingerprint: "deadbeefcafef00d",
      displays: [DisplaySummary(uuid: "DISP-A", desktopCount: 9, activeDesktopOrdinal: 2)],
      windows: [
        CapturedWindow(
          bundleId: "com.example.app", pid: 7, title: "Notes", cgWindowId: 4242,
          displayUUID: "DISP-A", desktopOrdinal: 3, spaceUUID: "SPACE-A",
          frame: WindowFrame(x: 10, y: 20, w: 800, h: 600),
          spaceIds: [9], sticky: false, onScreen: true)
      ])
  }

  @Test func roundTripIsLossless() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "keeps-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir)
    let snap = sampleSnapshot()

    let url = try store.save(snap)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let loaded = try store.load(fingerprint: snap.configFingerprint)
    #expect(loaded.schema == snap.schema)
    #expect(loaded.configFingerprint == snap.configFingerprint)
    #expect(loaded.capturedAt == snap.capturedAt)
    #expect(loaded.displays == snap.displays)
    #expect(loaded.windows == snap.windows)
  }

  @Test func eachFingerprintGetsItsOwnFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "keeps-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir)
    #expect(store.url(for: "aaaa").lastPathComponent == "aaaa.json")
    #expect(store.url(for: "aaaa") != store.url(for: "bbbb"))
  }

  @Test func loadRejectsInvalidFingerprint() {  // path-traversal / wrong-shape guard — throws before any file I/O
    let store = Store(directory: FileManager.default.temporaryDirectory)
    #expect(throws: StoreError.self) { try store.load(fingerprint: "../../etc/passwd") }
    #expect(throws: StoreError.self) { try store.load(fingerprint: "deadbeef") }  // too short
    #expect(throws: StoreError.self) { try store.load(fingerprint: "DEADBEEFCAFEF00D") }  // uppercase ≠ ours
  }

  @Test func loadRejectsSchemaMismatch() throws {  // refuse a future/foreign schema rather than mis-decode
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "keeps-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir)
    let fp = "00000000000000aa"  // valid shape
    let badJSON =
      #"{"schema":"keeps-capture/v999","capturedAt":"2026-01-01T00:00:00Z","configFingerprint":"00000000000000aa","displays":[],"windows":[]}"#
    try badJSON.data(using: .utf8)!.write(to: store.url(for: fp))
    #expect(throws: StoreError.self) { try store.load(fingerprint: fp) }
  }

  @Test func existsReflectsSavedSnapshot() throws {  // the restore/capture arbitration hinge
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "keeps-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir)
    let snap = sampleSnapshot()
    #expect(store.exists(fingerprint: snap.configFingerprint) == false)  // nothing saved yet
    _ = try store.save(snap)
    #expect(store.exists(fingerprint: snap.configFingerprint) == true)
    #expect(store.exists(fingerprint: "ffffffffffffffff") == false)  // a different, valid-shape fp
    #expect(store.exists(fingerprint: "../bad") == false)  // invalid shape ⇒ absent, no I/O
  }

  @Test func saveKeepsOnePreviousCopy() throws {
    // Review C2: Save was a plain atomic overwrite with NO history, so one click could permanently destroy
    // the layout the user was trying to restore — and for a while keeps recommended exactly that click after
    // a reboot. A misplaced window is recoverable by dragging; a destroyed snapshot is not.
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("keeps-store-history-\(UUID().uuidString)")
    let store = Store(directory: dir)
    let fp = String(repeating: "a", count: 16)

    let first = Snapshot(
      schema: captureSchema, capturedAt: Date(timeIntervalSince1970: 1_000),
      configFingerprint: fp, displays: [], windows: [])
    _ = try store.save(first)
    let previous = dir.appendingPathComponent("\(fp).previous.json")
    #expect(!FileManager.default.fileExists(atPath: previous.path), "nothing to back up on a first save")

    let second = Snapshot(
      schema: captureSchema, capturedAt: Date(timeIntervalSince1970: 2_000),
      configFingerprint: fp, displays: [], windows: [])
    _ = try store.save(second)

    #expect(FileManager.default.fileExists(atPath: previous.path), "the overwritten snapshot is kept")
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let kept = try dec.decode(Snapshot.self, from: Data(contentsOf: previous))
    #expect(kept.capturedAt == first.capturedAt, "the copy is the OLD one, not the new one")
    #expect(try store.load(fingerprint: fp).capturedAt == second.capturedAt, "the live one is current")

    // The backup must be invisible to normal lookups — `.previous.json` is not a fingerprint, so no config
    // can ever resolve to it and no restore can act on it by accident.
    #expect(!store.exists(fingerprint: "\(fp).previous"))
    try? FileManager.default.removeItem(at: dir)
  }
}
