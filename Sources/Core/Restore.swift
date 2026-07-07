import AppKit
import ApplicationServices
import CGSPrivate
import CoreGraphics
// Restore — the inverse of Capture: read back a config's Snapshot and put each window where it was
// (display + position + size) via PUBLIC AX (silent, SIP-on). The per-window decision (`decide`) is a pure
// truth table separated from the I/O sweep (`restore`, #keeps-3 slice B) so every place/skip is unit-testable
// and every skip is counted with a reason — never a silent miss (the #keeps-2 Scenario-A discipline).
//
// The silent/active-desktop boundary falls out of AX for free: AX (kAXWindows) only reaches the ACTIVE
// desktop, so a captured window with no AX match is either on a BACKGROUND desktop (→ #keeps-12's visible
// ⌥⌘N carry) or GONE — and CGWindowList(.optionAll) + cgsSpacesForWindow tell those apart. Raw .optionAll
// membership is NOT the discriminator: it includes 0-space minimized/junk windows (#keeps-2,
// agents-core-memories), so a since-minimized window must be classified `minimized`, never mislabeled
// `deferredBackground` (the M1 fix from the adversarial review).
import Foundation

public enum Restore {

  // MARK: - Pure classification (no I/O — fully unit-testable)

  /// Why a captured window is not placed. Counted per restore (Result.skips); the #keeps-3 analogue of Capture.DropReason.
  public enum SkipReason: String, Codable, CaseIterable {
    case sticky  // flagged all-desktops AND not reachable — can't frame-restore (reachable ones ARE placed)
    case gone  // no live window matches — closed since capture
    case minimized  // matched but minimized / 0-space — can't place; un-minimize is out of scope
    case deferredBackground  // matched, on a BACKGROUND desktop — silent AX can't reach it → #keeps-12
    case alreadyCorrect  // live frame already matches the captured frame (±tolerance) — no-op
  }

  enum Action: Equatable {
    case place(WindowFrame)  // set the window to this captured frame (display + position + size)
    case skip(SkipReason)
    var label: String {
      switch self {
      case .place: return "place"
      case .skip(let r): return r.rawValue
      }
    }
  }

  /// The live state of a captured window's match, lifted out of AX/CGWindowList so `decide` is pure.
  /// A nil match means "no live window in .optionAll at all" ⇒ gone.
  struct Match: Equatable {
    var reachable: Bool  // present in the AX active-desktop enumeration (placeable now)
    var minimized: Bool  // AX kAXMinimized — a minimized window can still appear in AX
    var liveSpaceCount: Int  // cgsSpacesForWindow count: 0 ⇒ minimized/junk, 1 ⇒ one desktop, >1 ⇒ all-desktops
    var liveFrame: WindowFrame?  // current frame from CGWindowList bounds (same source as capture)
  }

  /// The restore filter, as one pure function. Order matters: cheapest/most-decisive rejects first.
  /// ±tolerance on `alreadyCorrect` defeats 1px rounding thrash (Q6).
  static func decide(_ cap: CapturedWindow, match: Match?, tolerance: Int = 2) -> Action {
    guard let m = match else { return .skip(.gone) }  // no live window in .optionAll at all
    if m.minimized || m.liveSpaceCount == 0 { return .skip(.minimized) }  // 0-space = minimized/junk, NOT background (M1)
    guard m.reachable else { return .skip(cap.sticky ? .sticky : .deferredBackground) }  // can't reach: #keeps-12, or all-spaces we can't touch
    // Reachable on an active desktop → frame-restore (display + position + size). The `sticky` flag gates only
    // desktop-CARRY (#keeps-12), never frame-restore — and it's unreliable anyway (cgsSpacesForWindow over-reports
    // Safari/others as all-spaces, #keeps-6), so it must not block placing a window we CAN reach. (dogfeel 2026-06-13)
    if let lf = m.liveFrame, cap.frame.matches(lf, tolerance: tolerance) {
      return .skip(.alreadyCorrect)
    }
    return .place(cap.frame)
  }

  // MARK: - Shared classification seam (#keeps-12)
  // The carry can't consume a cached `Result` — it exposes only a deferred *count* (`Outcome` drops
  // spaceUUID/frame), and a deliberate carry fired later than any auto-restore must act on *current* live
  // state. So both `Restore.restore` and `Carry` gather live window state ONCE and run the same per-window
  // `decide` over it; the carry then keeps the `.deferredBackground` `CapturedWindow`s (which carry the
  // spaceUUID + frame it needs). Shared logic, computed fresh — the adversarial-review Blocker-1 fix.

  /// Live window state gathered once for a classification pass: the CGS connection, the AX active-desktop
  /// reachable set, and the CGWindowList(.optionAll) existence/frames. `nil` ⇒ SkyLight read failed (cid == 0).
  struct LiveState {
    let cid: CGSConnectionID
    let reachable: [CGWindowID: Reachable]
    let existence: Existence
  }

  /// Read the live window state `decide` classifies against. One AX sweep + one CGWindowList read; `nil` on a
  /// failed SkyLight load (cid == 0) so callers can surface `readFailed` instead of acting on nothing (M4).
  static func gatherLiveState() -> LiveState? {
    let cid = cgsMainConnection()
    guard cid != 0 else { return nil }
    return LiveState(cid: cid, reachable: reachableWindows(), existence: enumerateExistence())
  }

  /// Classify every captured window against live state — each paired with its `Action`. The seam #keeps-12's
  /// carry re-runs at trigger time, then filters for `.skip(.deferredBackground)` to get its carry set.
  static func classify(_ snapshot: Snapshot, against live: LiveState, tolerance: Int = 2) -> [(
    CapturedWindow, Action
  )] {
    snapshot.windows.map { cap in
      let match = matchFor(cap, cid: live.cid, reachable: live.reachable, existence: live.existence)
      return (cap, decide(cap, match: match, tolerance: tolerance))
    }
  }

  // MARK: - I/O sweep

  public struct Result {
    public let planned: Int  // windows the plan decided to place (display + position + size)
    public let applied: Int  // windows actually moved (0 in dry-run; ≤ planned)
    public let failures: Int  // place attempts where the AX position-set failed (apply mode)
    public let skips: [SkipReason: Int]  // every non-place outcome, by reason — no silent miss (Scenario A)
    public let outcomes: [Outcome]  // per-window decision — every captured window, inspectable
    public let dryRun: Bool
    public let readFailed: Bool  // cid == 0 — SkyLight read failed; nothing read or done (M4)
    public var deferredBackground: Int { skips[.deferredBackground] ?? 0 }  // the #keeps-12 handoff size
  }

  /// One captured window's restore decision — for the verbose log + future menu detail. `action` is "place"
  /// or a SkipReason rawValue, so every window's fate is named (the Scenario-A "no silent miss" made visible).
  public struct Outcome {
    public let bundleId: String
    public let title: String?
    public let cgWindowId: UInt32
    public let action: String
  }

  /// Read back `snapshot` and place each captured window where it was, via public AX (silent). `apply == false`
  /// is a DRY RUN — it plans and counts but moves nothing (the safe default). Only windows reachable on an
  /// active desktop are placed; background-desktop matches are counted `deferredBackground` for #keeps-12.
  public static func restore(_ snapshot: Snapshot, apply: Bool, tolerance: Int = 2) -> Result {
    guard let live = gatherLiveState() else {  // SkyLight load failed → act on nothing (M4)
      return Result(
        planned: 0, applied: 0, failures: 0, skips: [:], outcomes: [], dryRun: !apply,
        readFailed: true)
    }
    var planned = 0
    var applied = 0
    var failures = 0
    var skips: [SkipReason: Int] = [:]
    var outcomes: [Outcome] = []
    let dbg = DebugTrace.enabled ? DebugTrace.activeDisplays() : []  // debug-only: name each frame's display
    if DebugTrace.enabled {
      DebugTrace.log(
        "=== restore fp=\(snapshot.configFingerprint) apply=\(apply)\(DebugTrace.focusNote) — displays: "
          + DebugTrace.displaysHeader(dbg))
    }
    for (cap, action) in classify(snapshot, against: live, tolerance: tolerance) {
      let before = DebugTrace.enabled ? live.existence.frames[cap.cgWindowId] : nil
      switch action {
      case .place(let frame):
        planned += 1
        if apply, let el = live.reachable[cap.cgWindowId]?.element {  // dry run, or lost the element, ⇒ count only
          let ok = setFrame(el, frame)
          if ok { applied += 1 } else { failures += 1 }
          if DebugTrace.enabled && DebugTrace.traces(bundleId: cap.bundleId, title: cap.title) {
            DebugTrace.log(
              DebugTrace.windowLine(
                bundleId: cap.bundleId, title: cap.title, wid: cap.cgWindowId,
                decision: ok ? "placed" : "place-FAILED(axSet)", desired: frame, before: before,
                after: axFrame(el), displays: dbg))
          }
        } else if DebugTrace.enabled && DebugTrace.traces(bundleId: cap.bundleId, title: cap.title) {
          DebugTrace.log(
            DebugTrace.windowLine(
              bundleId: cap.bundleId, title: cap.title, wid: cap.cgWindowId,
              decision: "place(dry-run/no-element)", desired: frame, before: before, after: nil,
              displays: dbg))
        }
      case .skip(let reason):
        skips[reason, default: 0] += 1
        if DebugTrace.enabled && DebugTrace.traces(bundleId: cap.bundleId, title: cap.title) {
          DebugTrace.log(
            DebugTrace.windowLine(
              bundleId: cap.bundleId, title: cap.title, wid: cap.cgWindowId,
              decision: "skip:\(reason.rawValue)", desired: cap.frame, before: before, after: nil,
              displays: dbg))
        }
      }
      outcomes.append(
        Outcome(
          bundleId: cap.bundleId, title: cap.title, cgWindowId: cap.cgWindowId, action: action.label
        ))
    }
    return Result(
      planned: planned, applied: applied, failures: failures, skips: skips,
      outcomes: outcomes, dryRun: !apply, readFailed: false)
  }

  // MARK: - I/O helpers

  struct Reachable {
    let element: AXUIElement
    let minimized: Bool
  }  // internal: held by LiveState (#keeps-12 seam)
  struct Existence {
    let ids: Set<CGWindowID>
    let frames: [CGWindowID: WindowFrame]
  }

  /// Live windows reachable via public AX — i.e. on each display's ACTIVE desktop (+ minimized). Keyed by
  /// cgWindowId via the private bridge. Every app handle gets a 1s messaging timeout (the #keeps-6 freeze guard).
  private static func reachableWindows() -> [CGWindowID: Reachable] {
    var map: [CGWindowID: Reachable] = [:]
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(axApp, 1.0)
      var winsVal: AnyObject?
      guard
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsVal) == .success,
        let windows = winsVal as? [AXUIElement]
      else { continue }
      for w in windows {
        guard let wid = axWindowID(w) else { continue }
        map[wid] = Reachable(element: w, minimized: axFlag(w, kAXMinimizedAttribute))
      }
    }
    return map
  }

  /// Every window CGWindowList(.optionAll) sees (all desktops): membership (for gone-detection) + frames
  /// (for the already-correct compare, read from the SAME source capture used — CGWindowList bounds).
  private static func enumerateExistence() -> Existence {
    var ids = Set<CGWindowID>()
    var frames: [CGWindowID: WindowFrame] = [:]
    for info in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]])
      ?? []
    {
      guard let wid = info[kCGWindowNumber as String] as? CGWindowID, wid != 0 else { continue }
      ids.insert(wid)
      if let f = frame(from: info) { frames[wid] = f }
    }
    return Existence(ids: ids, frames: frames)
  }

  /// Lift one captured window's live state into a pure `Match` (nil ⇒ gone). The space lookup is lazy — done
  /// only for matched-but-not-reachable windows, where it discriminates a background desktop (1 space) from
  /// minimized/junk (0 spaces, the M1 fix) — never for the hundreds the reachable set already covers.
  private static func matchFor(
    _ cap: CapturedWindow, cid: CGSConnectionID,
    reachable: [CGWindowID: Reachable], existence: Existence
  ) -> Match? {
    if let r = reachable[cap.cgWindowId] {
      return Match(
        reachable: true, minimized: r.minimized,
        liveSpaceCount: 1,  // don't-care when reachable; decide() gates on `reachable`
        liveFrame: existence.frames[cap.cgWindowId])
    }
    guard existence.ids.contains(cap.cgWindowId) else { return nil }  // not in .optionAll at all ⇒ gone
    return Match(
      reachable: false, minimized: false,  // not-in-AX minimized is caught by the 0-space check
      liveSpaceCount: cgsSpacesForWindow(cid, cap.cgWindowId).count,
      liveFrame: existence.frames[cap.cgWindowId])
  }

  /// AX size→pos→size — defeats apps that move-on-resize and constraints that drop a lone trailing size-set
  /// (the #keeps-6 Endel finding). "Different display" needs no special step: it's the captured global coords.
  /// Returns whether the position landed (the load-bearing display+position; size is best-effort).
  /// Internal (not private) so #keeps-12's carry reuses the exact same placement after it lands a window.
  @discardableResult
  static func setFrame(_ el: AXUIElement, _ f: WindowFrame) -> Bool {
    var size = CGSize(width: f.w, height: f.h)
    var pos = CGPoint(x: f.x, y: f.y)
    guard let sizeV = AXValueCreate(.cgSize, &size), let posV = AXValueCreate(.cgPoint, &pos) else {
      return false
    }
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sizeV)
    let posOK = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posV) == .success
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sizeV)
    return posOK
  }

  /// Read a window's current AX frame (position + size) — debug-only, for the after-placement trace. Top-left
  /// global coords, the same space as the captured frame, so a window that landed reads ≈ its desired frame.
  static func axFrame(_ el: AXUIElement) -> WindowFrame? {
    var posV: AnyObject?
    var sizeV: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
      AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success,
      let posV, let sizeV
    else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(posV as! AXValue, .cgPoint, &p)
    AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
    return WindowFrame(x: Int(p.x), y: Int(p.y), w: Int(s.width), h: Int(s.height))
  }

  private static func frame(from info: [String: Any]) -> WindowFrame? {
    guard let dict = info[kCGWindowBounds as String],
      let r = CGRect(dictionaryRepresentation: dict as! CFDictionary)
    else { return nil }
    return WindowFrame(x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height))
  }

  private static func axFlag(_ el: AXUIElement, _ attr: String) -> Bool {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success
      && (v as? Bool == true)
  }
}

extension WindowFrame {
  /// True when two frames agree within ±tolerance px on every edge — the idempotence test (#keeps-3 Q6).
  /// Both sides must come from the SAME coordinate source (CGWindowList bounds) or the compare is meaningless.
  func matches(_ other: WindowFrame, tolerance: Int) -> Bool {
    abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance && abs(w - other.w) <= tolerance
      && abs(h - other.h) <= tolerance
  }
}
