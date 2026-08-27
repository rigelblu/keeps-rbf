// #keeps-30 — one resolver for both sessions. A dead id whose app RELAUNCHED is re-matched by app + geometry
// in this boot session, the way every id is after a reboot; a dead id whose app still runs under the captured
// pid is a window the user closed and stays `gone`. Pure: the only I/O left inside `resolveIds` (the Space
// read) is injected, so these tests count it as well as check it.
import CoreGraphics
import Foundation
import Testing

@testable import Core

@Suite struct IdResolutionTests {

  private func cap(_ bundleId: String, pid: Int32, id: UInt32, x: Int, y: Int, w: Int = 100, h: Int = 100)
    -> CapturedWindow
  {
    CapturedWindow(
      bundleId: bundleId, pid: pid, title: nil, cgWindowId: id, displayUUID: "D", desktopOrdinal: 1,
      spaceUUID: "S", frame: WindowFrame(x: x, y: y, w: w, h: h), spaceIds: [1], sticky: false,
      onScreen: true)
  }

  private struct Live {  // one live window, as CGWindowList would report it
    let id: CGWindowID, pid: pid_t, identity: String, frame: WindowFrame
  }
  private func live(_ identity: String, pid: pid_t, id: UInt32, x: Int, y: Int, w: Int = 100, h: Int = 100)
    -> Live
  {
    Live(id: id, pid: pid, identity: identity, frame: WindowFrame(x: x, y: y, w: w, h: h))
  }

  /// `running` is pid → identity for every regular app; `windows` every normal-layer window.
  private func state(running: [pid_t: String], windows: [Live]) -> Restore.LiveState {
    var ids = Set<CGWindowID>()
    var frames: [CGWindowID: WindowFrame] = [:]
    var owners: [CGWindowID: String] = [:]
    var ownerPids: [CGWindowID: pid_t] = [:]
    for w in windows {
      ids.insert(w.id)
      frames[w.id] = w.frame
      owners[w.id] = w.identity
      ownerPids[w.id] = w.pid
    }
    return Restore.LiveState(
      cid: 0, reachable: [:],
      existence: Restore.Existence(
        ids: ids, frames: frames, owners: owners, normalLayer: ids, identities: running,
        ownerPids: ownerPids),
      desktopIndex: DesktopIndex(displays: []), topology: Restore.Topology(displays: []))
  }

  private func snap(_ caps: [CapturedWindow]) -> Snapshot {
    Snapshot(
      schema: "test", capturedAt: Date(), configFingerprint: "0123456789abcdef", displays: [],
      windows: caps)
  }

  private func resolve(_ caps: [CapturedWindow], _ live: Restore.LiveState, trustIds: Bool = true)
    -> Restore.IdResolution
  {
    Restore.resolveIds(snap(caps), live: live, trustIds: trustIds, spaces: { _ in [1] })
  }

  // MARK: - the decision

  @Test func aRelaunchedAppsDeadIdIsReMatchedByGeometry() {  // (a) the 2026-08-27 12:14 repro
    // Overcast ran as pid 500 with window 384; quit; relaunched as pid 900 with window 11540 at the same frame.
    let captured = cap("fm.overcast", pid: 500, id: 384, x: 80, y: 257, w: 1024, h: 678)
    let state = state(
      running: [900: "fm.overcast"], windows: [live("fm.overcast", pid: 900, id: 11540, x: 80, y: 257, w: 1024, h: 678)])
    let r = resolve([captured], state)
    #expect(r.map == [384: 11540])
    #expect(r.live == 0 && r.dead == 1 && r.relaunched == 1 && r.exact == 1)
  }

  @Test func aClosedWindowOfARunningAppStaysGone() {  // (b) same pid alive ⇒ the WINDOW closed
    // Bear (pid 500) still runs; note 333 was closed; a newer note 700 sits exactly where 333 was.
    let captured = cap("net.shinyfrog.bear", pid: 500, id: 333, x: 0, y: 0)
    let state = state(
      running: [500: "net.shinyfrog.bear"], windows: [live("net.shinyfrog.bear", pid: 500, id: 700, x: 0, y: 0)])
    var reads = 0
    let r = Restore.resolveIds(snap([captured]), live: state, trustIds: true, spaces: { _ in reads += 1; return [1] })
    #expect(r.map.isEmpty)  // absent ⇒ `decide` classifies gone
    #expect(r.dead == 1 && r.relaunched == 0)
    #expect(reads == 0)  // `assign` was never consulted
  }

  @Test func aColdStartSendsEveryIdToAssign() {  // (c) `trustIds == false` is today's cold path, unchanged
    // The captured id 42 is LIVE — but after a reboot it belongs to a stranger; it must not be trusted.
    let captured = cap("com.a", pid: 1, id: 42, x: 0, y: 0)
    let state = state(
      running: [77: "com.a", 78: "com.b"],
      windows: [live("com.b", pid: 78, id: 42, x: 0, y: 0), live("com.a", pid: 77, id: 43, x: 500, y: 500)])
    let r = resolve([captured], state, trustIds: false)
    #expect(r.map == [42: 43])  // same app, same size, moved — tier 3; never the stranger holding id 42
    #expect(r.size == 1)
  }

  @Test func aSiblingsLiveWindowIsNeverACandidateForADeadRecord() {  // (d) claimed once, by construction
    // Two Bear records: 10 is live (pid 500 still runs it); 11 was owned by pid 501, now dead, and Bear also
    // runs as pid 600 (a second process of the same bundle — rare, but nothing forbids it), so 11 reads as
    // relaunched. The only live window at 11's frame is 10's.
    let a = cap("net.shinyfrog.bear", pid: 500, id: 10, x: 0, y: 0)
    let b = cap("net.shinyfrog.bear", pid: 501, id: 11, x: 0, y: 0)
    let state = state(
      running: [500: "net.shinyfrog.bear", 600: "net.shinyfrog.bear"],
      windows: [live("net.shinyfrog.bear", pid: 500, id: 10, x: 0, y: 0)])
    let r = resolve([a, b], state)
    #expect(r.map == [10: 10])  // 11 is relaunched but its only candidate is already 10's
    #expect(r.relaunched == 1)
  }

  @Test func twoDeadRecordsOneCandidateExactlyOnePairs() {  // (e) — and it is #keeps-31's rule, unchanged
    // Both records are the candidate's size, neither its position, so both reach tier 3. `assign` walks the
    // captured side in READING ORDER and gives each record its nearest unclaimed candidate; nearest-first
    // breaks ties among candidates for one record, not among records for one candidate. So the top-left
    // record (id 1) claims the only window, even though id 2 sits nearer to it. This test first expected
    // `[2: 50]` and failed — the expectation was wrong, the matcher was right; recorded so nobody "fixes" it.
    let a = cap("com.a", pid: 1, id: 1, x: 0, y: 0)
    let b = cap("com.a", pid: 1, id: 2, x: 1000, y: 1000)
    let state = state(running: [9: "com.a"], windows: [live("com.a", pid: 9, id: 50, x: 990, y: 990)])
    let r = resolve([a, b], state)
    #expect(r.map == [1: 50])  // one claim, never two
    #expect(r.map.values.count == Set(r.map.values).count)
  }

  @Test func aResolvedIdCarriesTheCandidatesFrameAndTheLiveOwnersPid() {  // (f) never a stranger's frame
    let captured = cap("com.a", pid: 1, id: 1, x: 0, y: 0)
    let state = state(
      running: [9: "com.a", 10: "com.b"],
      windows: [live("com.b", pid: 10, id: 5, x: 0, y: 0), live("com.a", pid: 9, id: 6, x: 0, y: 0)])
    let r = resolve([captured], state)
    #expect(r.map == [1: 6])
    let resolved = r.map[1]!  // through the result, not the fixture: the window the resolver chose…
    #expect(state.existence.owners[resolved] == captured.bundleId)  // …is the captured app's
    #expect(state.existence.frames[resolved] == captured.frame)  // …at the frame the tier matched on
    #expect(state.existence.identities[state.existence.ownerPids[resolved]!] == captured.bundleId)
  }

  @Test func aPidRecycledOntoAnotherAppStillReadsAsRelaunched() {  // (h) grill Q1, the non-nil form
    let captured = cap("com.a", pid: 500, id: 1, x: 0, y: 0)
    let state = state(
      running: [500: "com.other", 900: "com.a"], windows: [live("com.a", pid: 900, id: 6, x: 0, y: 0)])
    #expect(resolve([captured], state).map == [1: 6])
  }

  @Test func aRelaunchAtANewSizeAndPositionStaysGone() {  // (i) the #keeps-31 residual, unchanged
    let captured = cap("com.a", pid: 500, id: 1, x: 0, y: 0, w: 100, h: 100)
    let state = state(running: [900: "com.a"], windows: [live("com.a", pid: 900, id: 6, x: 300, y: 300, w: 200, h: 150)])
    let r = resolve([captured], state)
    #expect(r.map.isEmpty && r.relaunched == 1)
  }

  @Test func aBundleLessAppCanNeverReadAsRelaunched() {  // its identity IS its pid; fails toward gone
    let captured = cap("pid:500", pid: 500, id: 1, x: 0, y: 0)
    let state = state(running: [900: "pid:900"], windows: [live("pid:900", pid: 900, id: 6, x: 0, y: 0)])
    #expect(resolve([captured], state).map.isEmpty)
  }

  @Test func liveIdsMapToThemselvesAndAreNeverReassigned() {  // same-session truth table unchanged
    // The captured window (id 1) has MOVED to (900,900); a sibling (id 2) now sits exactly at its saved frame.
    // A regression that fed live ids into `assign` would pair 1→2 by tier `exact`. The rule is: live ⇒ self.
    let a = cap("com.a", pid: 1, id: 1, x: 0, y: 0)
    let state = state(
      running: [1: "com.a"],
      windows: [live("com.a", pid: 1, id: 1, x: 900, y: 900), live("com.a", pid: 1, id: 2, x: 0, y: 0)])
    let r = resolve([a], state)
    #expect(r.map == [1: 1] && r.live == 1 && r.dead == 0)
  }

  // MARK: - the read cost (A6) — the identity filter runs BEFORE the Space read

  private func fleet() -> (running: [pid_t: String], windows: [Live]) {
    var running: [pid_t: String] = [:]
    var windows: [Live] = []
    for app in 0..<5 {
      let pid = pid_t(100 + app)
      running[pid] = "com.app\(app)"
      for w in 0..<8 {
        windows.append(live("com.app\(app)", pid: pid, id: UInt32(app * 10 + w + 1), x: w * 50, y: app * 50))
      }
    }
    return (running, windows)
  }

  @Test func spaceReadsOnlyRelaunchedApps() {
    var (running, windows) = fleet()
    // com.app2 relaunched: it now runs as pid 202 with 3 windows; the captured record names the dead pid 102.
    running[102] = nil
    running[202] = "com.app2"
    windows.removeAll { $0.identity == "com.app2" }
    windows += [
      live("com.app2", pid: 202, id: 901, x: 0, y: 0), live("com.app2", pid: 202, id: 902, x: 50, y: 0),
      live("com.app2", pid: 202, id: 903, x: 100, y: 0),
    ]
    let captured = cap("com.app2", pid: 102, id: 21, x: 0, y: 0)
    var reads = 0
    let r = Restore.resolveIds(
      snap([captured]), live: state(running: running, windows: windows), trustIds: true,
      spaces: { _ in reads += 1; return [1] })
    #expect(reads == 3)  // com.app2's three windows, not the fleet's 35
    #expect(r.map == [21: 901])
  }

  @Test func noRelaunchedAppsMeansNoSpaceReads() {
    let (running, windows) = fleet()
    let captured = cap("com.app1", pid: 101, id: 11, x: 0, y: 50)  // live
    var reads = 0
    _ = Restore.resolveIds(
      snap([captured]), live: state(running: running, windows: windows), trustIds: true,
      spaces: { _ in reads += 1; return [1] })
    #expect(reads == 0)
  }

  @Test func aColdStartReadsEveryAttributableNormalLayerWindow() {
    let (running, windows) = fleet()
    let captured = cap("com.app1", pid: 101, id: 11, x: 0, y: 50)
    var reads = 0
    _ = Restore.resolveIds(
      snap([captured]), live: state(running: running, windows: windows), trustIds: false,
      spaces: { _ in reads += 1; return [1] })
    #expect(reads == 40)  // today's cold behaviour, unchanged
  }
}
