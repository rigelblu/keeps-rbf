import CGSPrivate
// DesktopIndex — the live desktop topology turned into the lookups #keeps-12's carry navigates by. Two identities
// flow through the carry and they are NOT the same number:
//   • the captured `spaceUUID` (a stable uuid, the restore anchor) names the TARGET desktop,
//   • `cgsSpacesForWindow` returns int `ManagedSpaceID`s naming a window's CURRENT desktop.
// Both must resolve to the same coordinate to compare: the 1-based GLOBAL ⌥⌘N ordinal = Σ(preceding displays'
// desktop counts) + the space's per-display index. That global numbering is #keeps-12's keystone and the fix to the
// seed's bug — the per-display index == the ⌥⌘N number only on the FIRST display; on later displays they diverge
// by the offset (display 1's 5th desktop is global 17, not 5). The probe proved ⌥⌘N is global, so this ordinal
// IS the navigation target. Pure (built from a parsed read) so Scenario B unit-tests the cross-display case.
import Foundation

public struct DesktopIndex: Equatable {

  /// One desktop, carrying BOTH identities so a captured uuid and a live ManagedSpaceID resolve to one ordinal.
  public struct Space: Equatable {
    public let uuid: String  // stable identity — matches CapturedWindow.spaceUUID (the target anchor)
    public let managedID: Int  // the int cgsSpacesForWindow returns (a window's live current desktop)
    public init(uuid: String, managedID: Int) {
      self.uuid = uuid
      self.managedID = managedID
    }
  }

  /// One display's ordered desktops + which one is showing (for navigation: step from current → target index).
  public struct Display: Equatable {
    public let identifier: String  // CGS "Display Identifier" (== display UUID) — where to park the cursor
    public let spaces: [Space]  // ordered as macOS numbers them (the ⌃→ stepping order)
    public let currentIndex: Int?  // 0-based index of this display's active desktop (nil ⇒ unknown)
    public init(identifier: String, spaces: [Space], currentIndex: Int?) {
      self.identifier = identifier
      self.spaces = spaces
      self.currentIndex = currentIndex
    }
  }

  public let displays: [Display]
  public init(displays: [Display]) { self.displays = displays }

  public var totalDesktops: Int { displays.reduce(0) { $0 + $1.spaces.count } }

  /// The 1-based GLOBAL ⌥⌘N ordinal of the desktop whose stable uuid is `uuid` — the captured target's live
  /// number. `nil` ⇒ that desktop is no longer in the topology (deleted since capture ⇒ the carry skips `targetGone`).
  public func globalOrdinal(ofSpaceUUID uuid: String) -> Int? { ordinal { $0.uuid == uuid } }

  /// The 1-based GLOBAL ⌥⌘N ordinal of the desktop with this live `ManagedSpaceID` — a window's CURRENT
  /// desktop (from cgsSpacesForWindow). `nil` ⇒ not in the topology (the window has no resolvable desktop).
  public func globalOrdinal(ofManagedID managedID: Int) -> Int? {
    ordinal { $0.managedID == managedID }
  }

  /// The stable uuid of the desktop with this live `ManagedSpaceID` — the #keeps-17 verify-after-place lens:
  /// a landed window's cgsSpacesForWindow id, translated into the identity the captured spaceUUID speaks.
  /// `nil` ⇒ unknown desktop (or one whose uuid CGS left empty — unknown, never "").
  public func uuid(ofManagedID managedID: Int) -> String? {
    for d in displays {
      if let s = d.spaces.first(where: { $0.managedID == managedID }) {
        return s.uuid.isEmpty ? nil : s.uuid
      }
    }
    return nil
  }

  /// #keeps-23 — the Space a window is ACTUALLY on, from its raw `cgsSpacesForWindow` membership.
  ///
  /// Pure on purpose, and separated from the CGS read for the reason `SessionFreshness` and `SettlePolicy`
  /// were: the bug this exists to kill lived on the I/O side of the seam, where no test could reach it.
  /// `Restore.matchFor` used to INFER a reachable window's Space as "the active Space of the display under
  /// its frame" — sound only if AX never reaches across Spaces, which a single live window disproved
  /// (cmux, 2026-07-28: reachable on desktop 1 with desktop 13 active).
  ///
  /// Exactly one Space or nothing. `spaces.first` on a multi-Space read is an arbitrary member — CGS
  /// over-reports some apps — so it can "prove" a home the window is nowhere near, and the opposite ordering
  /// proves the reverse (the #keeps-15 `spaces.first` finding). Nil means "cannot prove", which every caller
  /// must treat as fail-safe rather than falling back to a guess.
  public func ownSpaceUUID(ofSpaces spaces: [Int]) -> String? {
    guard spaces.count == 1, let mid = spaces.first else { return nil }
    return uuid(ofManagedID: mid)
  }

  /// Map a 1-based GLOBAL ordinal back to (display index, 0-based per-display index) — the navigation target:
  /// which display to step, and to which of its desktops. `nil` ⇒ out of range.
  public func locate(global: Int) -> (displayIndex: Int, perDisplayIndex: Int)? {
    var offset = 0
    for (i, d) in displays.enumerated() {
      if global > offset && global <= offset + d.spaces.count { return (i, global - offset - 1) }
      offset += d.spaces.count
    }
    return nil
  }

  private func ordinal(_ match: (Space) -> Bool) -> Int? {
    var offset = 0
    for d in displays {
      if let idx = d.spaces.firstIndex(where: match) { return offset + idx + 1 }
      offset += d.spaces.count
    }
    return nil
  }
}

extension DesktopIndex {
  /// Read the live topology from CGS — the SAME managed-display-spaces read capture uses for desktop
  /// attribution. Each "Spaces" entry carries both `uuid` and `ManagedSpaceID`; "Current Space" identifies the
  /// active desktop (by uuid when present, else by ManagedSpaceID). The one I/O point; everything above is pure.
  static func live(_ cid: CGSConnectionID) -> DesktopIndex {
    DesktopIndex(
      displays: cgsManagedDisplaySpaces(cid).map { d in
        let raw = (d["Spaces"] as? [[String: Any]]) ?? []
        let spaces: [Space] = raw.compactMap { s in
          guard let mid = s["ManagedSpaceID"] as? Int else { return nil }
          return Space(uuid: s["uuid"] as? String ?? "", managedID: mid)
        }
        let current = d["Current Space"] as? [String: Any]
        let currentIndex: Int? = {
          if let u = current?["uuid"] as? String, !u.isEmpty,
            let i = spaces.firstIndex(where: { $0.uuid == u })
          {
            return i
          }
          if let m = current?["ManagedSpaceID"] as? Int {
            return spaces.firstIndex { $0.managedID == m }
          }
          return nil
        }()
        return Display(
          identifier: d["Display Identifier"] as? String ?? "?", spaces: spaces,
          currentIndex: currentIndex)
      })
  }
}
