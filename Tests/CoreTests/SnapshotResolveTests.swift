// #keeps-15: a layout is a set of spots on displays, not numbers on a plane. `Snapshot.resolved(against:)` turns
// saved frames into today's coordinates by each display's origin delta. These are the pure cases the brief
// enumerates (a)–(i), plus the real 2026-08-29 fixture: the store file as it was before that morning's Save,
// with the saved origins the trace header recorded (`keeps-debug.log:3762`, 2026-08-28 09:15) and the live
// bounds read after Tom dragged the displays in Arrange Displays.
import Foundation
import Testing

@testable import Core

@Suite struct SnapshotResolveTests {
  // MARK: - Synthetic fleet

  private let mb = "MB-UUID"
  private let lg = "LG-UUID"

  private func window(_ id: UInt32, on display: String?, x: Int, y: Int, w: Int = 800, h: Int = 600)
    -> CapturedWindow
  {
    CapturedWindow(
      bundleId: "com.example.app", pid: 7, title: nil, cgWindowId: id,
      displayUUID: display, desktopOrdinal: 1, spaceUUID: "SPACE",
      frame: WindowFrame(x: x, y: y, w: w, h: h), spaceIds: [9], sticky: display == nil, onScreen: true)
  }

  private func snapshot(displays: [DisplaySummary], windows: [CapturedWindow]) -> Snapshot {
    Snapshot(
      schema: captureSchema, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      configFingerprint: "deadbeefcafef00d", displays: displays, windows: windows)
  }

  private func summary(_ uuid: String, _ b: DisplayBounds?) -> DisplaySummary {
    DisplaySummary(uuid: uuid, desktopCount: 3, activeDesktopOrdinal: 1, bounds: b)
  }

  private let mbSaved = DisplayBounds(x: 0, y: 0, w: 1512, h: 982)
  private let lgSaved = DisplayBounds(x: -1920, y: 0, w: 1920, h: 1080)

  @Test func aOnlyTheMovedDisplaysWindowsShift() {
    let snap = snapshot(
      displays: [summary(mb, mbSaved), summary(lg, lgSaved)],
      windows: [window(1, on: mb, x: 100, y: 100), window(2, on: lg, x: -1800, y: 50)])
    let live = [
      LiveDisplay(uuid: mb, bounds: mbSaved),
      LiveDisplay(uuid: lg, bounds: DisplayBounds(x: -1920 + 333, y: -167, w: 1920, h: 1080)),
    ]
    let (r, notes) = snap.resolved(against: live)
    #expect(notes == [.unchanged(uuid: mb), .shifted(uuid: lg, dx: 333, dy: -167)])
    #expect(r.windows[0].frame == WindowFrame(x: 100, y: 100, w: 800, h: 600), "the built-in didn't move")
    #expect(r.windows[1].frame == WindowFrame(x: -1800 + 333, y: 50 - 167, w: 800, h: 600))
    #expect(r.displays == snap.displays, "the resolved snapshot keeps the SAVED bounds — it is never saved")
  }

  @Test func bNoSavedBoundsAnywhereIsAbsoluteWithOneNote() {
    let snap = snapshot(
      displays: [summary(mb, nil), summary(lg, nil)],
      windows: [window(1, on: mb, x: 100, y: 100), window(2, on: lg, x: -1800, y: 50)])
    let live = [LiveDisplay(uuid: lg, bounds: DisplayBounds(x: -1000, y: 0, w: 1920, h: 1080))]
    let (r, notes) = snap.resolved(against: live)
    #expect(notes == [.noSavedBounds])
    #expect(r.windows == snap.windows, "a pre-#keeps-15 file behaves exactly as before")
  }

  @Test func cResizedDisplayFallsBackToAbsolute() {
    let snap = snapshot(
      displays: [summary(mb, mbSaved), summary(lg, DisplayBounds(x: -3360, y: -1890, w: 3360, h: 1890))],
      windows: [window(1, on: mb, x: 100, y: 100), window(2, on: lg, x: -3000, y: -1800)])
    let liveLG = DisplayBounds(x: -5120 + 333, y: -2880, w: 5120, h: 2880)  // moved AND rescaled
    let (r, notes) = snap.resolved(against: [LiveDisplay(uuid: mb, bounds: mbSaved), LiveDisplay(uuid: lg, bounds: liveLG)])
    #expect(notes == [
      .unchanged(uuid: mb),
      .absolute(uuid: lg, reason: .resized(saved: DisplayBounds(x: -3360, y: -1890, w: 3360, h: 1890), live: liveLG)),
    ])
    #expect(r.windows[1].frame == snap.windows[1].frame, "a resized display's windows are left as saved (keeps-15.2)")
  }

  @Test func cSizeMustMatchExactlyNotWithinTolerance() {
    // Grill Q1: a display never drifts by a pixel; a one-point difference is a rescale, not noise.
    let snap = snapshot(displays: [summary(lg, lgSaved)], windows: [window(2, on: lg, x: -1800, y: 50)])
    let liveLG = DisplayBounds(x: -1920 + 333, y: 0, w: 1921, h: 1080)
    let (r, notes) = snap.resolved(against: [LiveDisplay(uuid: lg, bounds: liveLG)])
    #expect(notes == [.absolute(uuid: lg, reason: .resized(saved: lgSaved, live: liveLG))])
    #expect(r.windows[0].frame == snap.windows[0].frame)
  }

  @Test func dAbsentLiveDisplayFallsBackToAbsolute() {
    let snap = snapshot(
      displays: [summary(mb, mbSaved), summary(lg, lgSaved)],
      windows: [window(2, on: lg, x: -1800, y: 50)])
    let (r, notes) = snap.resolved(against: [LiveDisplay(uuid: mb, bounds: mbSaved)])
    #expect(notes == [.unchanged(uuid: mb), .absolute(uuid: lg, reason: .absent)])
    #expect(r.windows == snap.windows)
  }

  @Test func eTwoDisplaysMovedByDifferentDeltas() {
    let snap = snapshot(
      displays: [summary(mb, mbSaved), summary(lg, lgSaved)],
      windows: [window(1, on: mb, x: 100, y: 100), window(2, on: lg, x: -1800, y: 50)])
    let live = [
      LiveDisplay(uuid: mb, bounds: DisplayBounds(x: 10, y: 20, w: 1512, h: 982)),
      LiveDisplay(uuid: lg, bounds: DisplayBounds(x: -1920 - 40, y: 5, w: 1920, h: 1080)),
    ]
    let (r, notes) = snap.resolved(against: live)
    #expect(notes == [.shifted(uuid: mb, dx: 10, dy: 20), .shifted(uuid: lg, dx: -40, dy: 5)])
    #expect(r.windows[0].frame == WindowFrame(x: 110, y: 120, w: 800, h: 600))
    #expect(r.windows[1].frame == WindowFrame(x: -1840, y: 55, w: 800, h: 600))
  }

  @Test func fWindowWithNoDisplayIsNeverShifted() {
    let snap = snapshot(
      displays: [summary(lg, lgSaved)],
      windows: [window(3, on: nil, x: -1800, y: 50)])  // sticky / unattributable
    let (r, notes) = snap.resolved(against: [LiveDisplay(uuid: lg, bounds: DisplayBounds(x: -1000, y: 0, w: 1920, h: 1080))])
    #expect(notes == [.shifted(uuid: lg, dx: 920, dy: 0)])
    #expect(r.windows[0].frame == snap.windows[0].frame, "no recorded display ⇒ nothing to shift by")
  }

  // MARK: - The real 2026-08-29 fleet

  private static let mbUUID = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
  private static let fiveKUUID = "943BF734-59F5-4793-A42C-45E6900CE778"
  private static let fourKUUID = "47D9AC15-E011-4DD8-B953-F43E9D2D66AE"
  // Saved origins — `~/Library/Logs/keeps-debug.log:3762`, 2026-08-28 09:15:38, one minute before the save.
  private static let mbSaved29 = DisplayBounds(x: 0, y: 0, w: 1800, h: 1169)
  private static let fiveKSaved29 = DisplayBounds(x: -3320, y: -2880, w: 5120, h: 2880)
  private static let fourKSaved29 = DisplayBounds(x: 1800, y: -1817, w: 3840, h: 2160)
  // Live `CGDisplayBounds` after Tom's drag in Arrange Displays, 2026-08-29 10:0x.
  private static let live29 = [
    LiveDisplay(uuid: mbUUID, bounds: DisplayBounds(x: 0, y: 0, w: 1800, h: 1169)),
    LiveDisplay(uuid: fourKUUID, bounds: DisplayBounds(x: 2133, y: -1984, w: 3840, h: 2160)),
    LiveDisplay(uuid: fiveKUUID, bounds: DisplayBounds(x: -2987, y: -2880, w: 5120, h: 2880)),
  ]

  private func fixture() throws -> Snapshot {
    let url = try #require(
      Bundle.module.url(forResource: "80bc74744ed01909-2026-08-28", withExtension: "json", subdirectory: "Fixtures"))
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try dec.decode(Snapshot.self, from: Data(contentsOf: url))
  }

  /// The fixture with saved bounds injected for the given displays (the file itself predates `bounds`).
  private func fixture(withBounds bounds: [String: DisplayBounds]) throws -> Snapshot {
    var snap = try fixture()
    snap.displays = snap.displays.map { d in
      var d = d
      d.bounds = bounds[d.uuid]
      return d
    }
    return snap
  }

  private func frame(of wid: UInt32, in snap: Snapshot) -> WindowFrame? {
    snap.windows.first { $0.cgWindowId == wid }?.frame
  }

  @Test func gRealFixtureResolvesChromeAndCmux() throws {
    let file = try fixture()
    #expect(file.displays.allSatisfy { $0.bounds == nil }, "the file predates #keeps-15")
    #expect(file.displays.map(\.uuid) == [Self.mbUUID, Self.fiveKUUID, Self.fourKUUID], "the stored order the notes follow")
    #expect(frame(of: 25741, in: file) == WindowFrame(x: -760, y: -2850, w: 2560, h: 1425), "Chrome beta, saved")
    #expect(frame(of: 30690, in: file) == WindowFrame(x: 1800, y: -1787, w: 3840, h: 2130), "cmux, saved")

    let snap = try fixture(withBounds: [
      Self.mbUUID: Self.mbSaved29, Self.fiveKUUID: Self.fiveKSaved29, Self.fourKUUID: Self.fourKSaved29,
    ])
    let (r, notes) = snap.resolved(against: Self.live29)
    #expect(notes == [
      .unchanged(uuid: Self.mbUUID),
      .shifted(uuid: Self.fiveKUUID, dx: 333, dy: 0),
      .shifted(uuid: Self.fourKUUID, dx: 333, dy: -167),
    ])
    #expect(frame(of: 25741, in: r) == WindowFrame(x: -427, y: -2850, w: 2560, h: 1425), "Chrome: 333px right")
    #expect(frame(of: 30690, in: r) == WindowFrame(x: 2133, y: -1954, w: 3840, h: 2130), "cmux: == its live frame ⇒ alreadyCorrect")
    #expect(frame(of: 30796, in: r) == WindowFrame(x: 0, y: 39, w: 1200, h: 1130), "Safari on the built-in: untouched")
  }

  @Test func hTwoSameSizeWindowsUnderAShiftStillPairWithThemselves() throws {
    // Zed `26459` and `29568`: both 5120×1425 on the 5K, stacked 1425px apart. The resolve moves both by +333.
    let snap = try fixture(withBounds: [
      Self.mbUUID: Self.mbSaved29, Self.fiveKUUID: Self.fiveKSaved29, Self.fourKUUID: Self.fourKSaved29,
    ])
    let (r, _) = snap.resolved(against: Self.live29)
    let zed = r.windows.filter { $0.bundleId == "dev.zed.Zed-RBF" }
    #expect(zed.map(\.cgWindowId).sorted() == [26459, 29568])
    let a = try #require(zed.first { $0.cgWindowId == 26459 })
    let b = try #require(zed.first { $0.cgWindowId == 29568 })
    #expect(a.frame == WindowFrame(x: -2987, y: -2850, w: 5120, h: 1425))
    #expect(b.frame == WindowFrame(x: -2987, y: -1425, w: 5120, h: 1425))

    // Live windows that FOLLOWED the display sit at the resolved frames → tier `exact`, each to itself.
    let followed = [
      ColdStartMatch.LiveWindow(id: 9001, identity: a.bundleId, frame: a.frame),
      ColdStartMatch.LiveWindow(id: 9002, identity: b.bundleId, frame: b.frame),
    ]
    let f = ColdStartMatch.assign(captured: zed, live: followed)
    #expect(f.exact == 2)
    #expect(f.map[26459] == 9001 && f.map[29568] == 9002)

    // Live windows that STAYED at the old absolute frames (Chrome's behaviour this morning) → tier `size`,
    // nearest centre: 333² against 333² + 1425², so A→A, B→B. The margin this pins: shift < half the spacing.
    let stayed = [
      ColdStartMatch.LiveWindow(id: 9001, identity: a.bundleId, frame: WindowFrame(x: -3320, y: -2850, w: 5120, h: 1425)),
      ColdStartMatch.LiveWindow(id: 9002, identity: b.bundleId, frame: WindowFrame(x: -3320, y: -1425, w: 5120, h: 1425)),
    ]
    let s = ColdStartMatch.assign(captured: zed, live: stayed)
    #expect(s.exact == 0 && s.position == 0 && s.size == 2)
    #expect(s.map[26459] == 9001 && s.map[29568] == 9002)
  }

  @Test func iOneDisplaySavedWithoutBoundsResolvesAbsoluteWhileSiblingsShift() throws {
    // Grill Q3: capture couldn't read the 5K's bounds; the file still saves. Only the 4K's windows shift.
    let snap = try fixture(withBounds: [Self.mbUUID: Self.mbSaved29, Self.fourKUUID: Self.fourKSaved29])
    let (r, notes) = snap.resolved(against: Self.live29)
    #expect(notes == [
      .unchanged(uuid: Self.mbUUID),
      .absolute(uuid: Self.fiveKUUID, reason: .noSavedBounds),
      .shifted(uuid: Self.fourKUUID, dx: 333, dy: -167),
    ])
    #expect(frame(of: 25741, in: r) == WindowFrame(x: -760, y: -2850, w: 2560, h: 1425), "Chrome: as saved")
    #expect(frame(of: 30690, in: r) == WindowFrame(x: 2133, y: -1954, w: 3840, h: 2130), "cmux: shifted")
  }
}
