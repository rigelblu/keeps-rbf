import AppKit
import CGSPrivate
import CoreGraphics
// Capture — enumerate ALL windows across ALL desktops via CGWindowList(.optionAll) [NOT AX, which is
// blind to background desktops — #keeps-6], attribute each to display UUID + per-display desktop ordinal,
// produce a Snapshot. Read-only; moves nothing. No per-app AX sweep ⇒ Stay's "Save all" freeze is gone.
//
// The per-window decision (`decide`) is pure and separated from the I/O sweep (`capture`) so every
// keep/drop is unit-testable and every drop is *counted with a reason* (Scenario A), never silent.
import Foundation

public enum Capture {

  // MARK: - Pure classification (no I/O — fully unit-testable)

  /// Why a window-server window is not captured. Counted per snapshot; surfaced for Scenario A.
  public enum DropReason: String, Codable, CaseIterable {
    case notRegularApp  // owner isn't a regular (Dock-shown) app
    case notNormalLayer  // layer != 0 — menus, panels, status items, shadows
    case noBounds  // no CGWindowBounds — can't place it
    case noSpace  // on zero spaces — WindowServer junk (helper strips, placeholders) or minimized
    case degenerateFrame  // zero/negative size — not a real, restorable window
    case noWindowID  // kCGWindowNumber absent (wid == 0) — unidentifiable, can't be restored
  }

  struct SpaceLoc: Equatable {
    let displayUUID: String
    let ordinal: Int
    let spaceUUID: String?
  }

  /// Everything `decide` needs, already lifted out of the CGWindowList dict — so tests construct it directly.
  struct Candidate {
    var bundleId: String?  // nil ⇒ not a regular app
    var pid: Int32
    var layer: Int
    var wid: CGWindowID
    var frame: WindowFrame?
    var title: String?
    var onScreen: Bool
    var spaces: [Int]
  }

  enum Decision: Equatable {
    case keep(CapturedWindow)
    case drop(DropReason)
  }

  /// The capture filter, as one pure function. Order matters: cheapest/most-fundamental rejects first.
  static func decide(_ c: Candidate, spaceIndex: [Int: SpaceLoc]) -> Decision {
    guard let bundleId = c.bundleId else { return .drop(.notRegularApp) }
    guard c.layer == 0 else { return .drop(.notNormalLayer) }
    guard c.wid != 0 else { return .drop(.noWindowID) }  // honest reason — not a false .noSpace from the cost-optimized skip
    guard let frame = c.frame else { return .drop(.noBounds) }
    guard !c.spaces.isEmpty else { return .drop(.noSpace) }
    guard frame.w > 0, frame.h > 0 else { return .drop(.degenerateFrame) }
    let loc = c.spaces.count == 1 ? spaceIndex[c.spaces[0]] : nil  // count != 1 ⇒ all-desktops sticky
    return .keep(
      CapturedWindow(
        bundleId: bundleId, pid: c.pid, title: c.title, cgWindowId: c.wid,
        displayUUID: loc?.displayUUID, desktopOrdinal: loc?.ordinal,
        spaceUUID: loc.flatMap { $0.spaceUUID }, frame: frame,
        spaceIds: c.spaces, sticky: c.spaces.count != 1, onScreen: c.onScreen))
  }

  // MARK: - I/O sweep

  public struct Result {
    public let snapshot: Snapshot
    public let drops: [DropReason: Int]  // counts by reason — Scenario A: every drop accounted for
    // An ENUMERATION failed rather than honestly returning nothing — do NOT persist (M4). Three ways in:
    // cid == 0 (SkyLight didn't load), unresolved space symbols, or a NULL window list. All three make a busy
    // desktop read as empty, and the sweep then drops every window "correctly", producing a valid-looking
    // empty snapshot. The last two were silent until the #keeps-2 review (2026-07-27) widened this flag.
    public let readFailed: Bool
  }

  public static func capture() -> Result {
    let cid = cgsMainConnection()
    guard cid != 0, cgsSpaceLookupAvailable else {  // DO-NOT-PERSIST result (M4): a 0-window
      // snapshot must never overwrite a good one (e.g. a first-encounter capture under a failed read).
      let empty = Snapshot(
        schema: captureSchema, capturedAt: Date(),
        configFingerprint: ConfigIdentity.fingerprint(), displays: [], windows: [])
      return Result(snapshot: empty, drops: [:], readFailed: true)
    }
    let spaceIndex = buildSpaceIndex(cid)
    let regularPIDs = regularAppPIDs()

    var windows: [CapturedWindow] = []
    var drops: [DropReason: Int] = [:]
    // NULL here is a read failure, not an empty desktop — hoisted so the verdict below can tell them apart.
    let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    for info in windowList ?? [] {
      let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? -1
      let bundleId = regularPIDs[pid]
      let layer = info[kCGWindowLayer as String] as? Int ?? -1
      let wid = info[kCGWindowNumber as String] as? CGWindowID ?? 0
      // Only the private space lookup is worth doing for real candidates (skips ~285 junk lookups).
      let isCandidate = bundleId != nil && layer == 0 && wid != 0
      let cand = Candidate(
        bundleId: bundleId, pid: pid, layer: layer, wid: wid,
        frame: frame(from: info), title: info[kCGWindowName as String] as? String,
        onScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
        spaces: isCandidate ? cgsSpacesForWindow(cid, wid) : [])
      switch decide(cand, spaceIndex: spaceIndex) {
      case .keep(let w): windows.append(w)
      case .drop(let r): drops[r, default: 0] += 1
      }
    }
    let snapshot = Snapshot(
      schema: captureSchema, capturedAt: Date(),
      configFingerprint: ConfigIdentity.fingerprint(),
      displays: displaySummaries(cid), windows: windows)
    return Result(snapshot: snapshot, drops: drops, readFailed: windowList == nil)
  }

  /// Convenience for callers that only want the layout (the menu Save path).
  public static func snapshot() -> Snapshot { capture().snapshot }

  // MARK: - I/O helpers

  private static func frame(from info: [String: Any]) -> WindowFrame? {
    guard let dict = info[kCGWindowBounds as String],
      let r = CGRect(dictionaryRepresentation: dict as! CFDictionary)
    else { return nil }
    return WindowFrame(x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height))
  }

  // ManagedSpaceID -> (display uuid, 1-based ordinal). The ordinal is the ⌥⌘N target #keeps-3 will use.
  private static func buildSpaceIndex(_ cid: CGSConnectionID) -> [Int: SpaceLoc] {
    var map: [Int: SpaceLoc] = [:]
    for d in cgsManagedDisplaySpaces(cid) {
      let displayUUID = d["Display Identifier"] as? String ?? "?"
      for (i, s) in ((d["Spaces"] as? [[String: Any]]) ?? []).enumerated() {
        if let id = s["ManagedSpaceID"] as? Int {
          map[id] = SpaceLoc(
            displayUUID: displayUUID, ordinal: i + 1,
            spaceUUID: s["uuid"] as? String)  // nil (not "") when a space has no uuid — an honest restore anchor
        }
      }
    }
    return map
  }

  private static func displaySummaries(_ cid: CGSConnectionID) -> [DisplaySummary] {
    cgsManagedDisplaySpaces(cid).map { d in
      let spaces = (d["Spaces"] as? [[String: Any]]) ?? []
      let activeID = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? -1
      let activeOrdinal =
        (spaces.firstIndex { ($0["ManagedSpaceID"] as? Int) == activeID }).map { $0 + 1 } ?? -1
      return DisplaySummary(
        uuid: d["Display Identifier"] as? String ?? "?",
        desktopCount: spaces.count, activeDesktopOrdinal: activeOrdinal)
    }
  }

  /// #keeps-5: the `bundleIdentifier ?? "pid:<pid>"` rule moved to `AppIdentity` so restore's identity guard
  /// compares against the SAME encoding this writes, by calling the same function rather than re-deriving it.
  /// Two copies of one rule is how a guard starts rejecting a window for being itself.
  private static func regularAppPIDs() -> [pid_t: String] {
    var map: [pid_t: String] = [:]
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      map[app.processIdentifier] = AppIdentity.encode(
        bundleId: app.bundleIdentifier, pid: app.processIdentifier)
    }
    return map
  }
}
