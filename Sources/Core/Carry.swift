import AppKit
import ApplicationServices
import CGSPrivate
import ColorSync  // CGDisplayCreateUUIDFromDisplayID — map a CGS display identifier to a CGDirectDisplayID
import CoreGraphics
// Carry — #keeps-4's VISIBLE half: carry every background-desktop window silent restore can't reach (#keeps-3's
// `.deferredBackground` set) back to its captured desktop + frame. Same shape as Capture/Restore: a pure
// `plan` truth-table (every carry/skip named + counted — no silent miss, Scenario A) split from an I/O sweep
// that navigates desktops, grabs each window by a synthetic title-bar drag, carries it across the space switch
// (proven D2/D3), AX-places its frame (#keeps-3's size→pos→size), and VERIFIES it landed.
//
// It re-classifies FRESH at trigger time (Blocker-1): a deliberate carry fires whenever clicked and must act on
// CURRENT live state, and `Restore.Result` threw away the spaceUUID/frame anyway — so it re-runs Restore.decide
// over the snapshot via the shared seam and keeps the deferred windows (which carry the spaceUUID + frame).
//
// Two move types compose a carry, and neither alone is enough: a desktop switch (held drag) moves a window
// between desktops on the SAME display; an AX frame-set moves it between displays (different global coords) but
// NOT between desktops. So same-display targets are carried then placed; a cross-display target can't be
// desktop-carried — it falls through to the AX place (right display+spot+size, #keeps-3-grade) and the verify
// reports honestly whether the desktop matched. Never claims the wrong desktop.
import Foundation
import os

public enum Carry {

  private static let log = Logger(subsystem: "com.rigelblu.keeps", category: "Carry")

  // MARK: - Pure plan (no I/O — Scenario A truth table)

  /// A deferred window paired with its CURRENT live desktop. The current desktop is live (read at trigger time
  /// from cgsSpacesForWindow); the target comes from the captured `spaceUUID`. The plan needs both: it grabs at
  /// the current desktop and `alreadyOnDesktop` compares the two. `nil` current ⇒ no resolvable live desktop.
  public struct DeferredWindow: Equatable {
    public let captured: CapturedWindow
    public let currentGlobalDesktop: Int?
    public init(captured: CapturedWindow, currentGlobalDesktop: Int?) {
      self.captured = captured
      self.currentGlobalDesktop = currentGlobalDesktop
    }
  }

  /// Why a deferred window is not carried — every one counted + surfaced (the Capture/Restore "no silent miss"
  /// discipline). `carryFailed` is the only I/O-only outcome (navigated + grabbed but didn't land); the rest are
  /// pure plan verdicts.
  public enum CarrySkip: String, Codable, CaseIterable, Sendable {
    case alreadyOnDesktop  // current desktop == target — no-op (idempotence)
    case targetGone  // captured spaceUUID no longer in the live topology — its desktop was deleted
    case unreachableShortcut  // can't navigate to it — needed Switch-to-Desktop/Move-a-space is unbound
    case gone  // no resolvable current desktop — closed/vanished since classify
    case carryFailed  // I/O: navigated + grabbed but the window didn't land on its target desktop
  }

  public enum CarryAction: Equatable {
    case carry(CapturedWindow, fromGlobal: Int, toGlobal: Int)
    case skip(CarrySkip, CapturedWindow)
  }

  /// The carry filter, as one pure function over the fresh deferred set + the live topology + the user's
  /// bindings. Order matters: target resolves → current resolves → not already there → both legs navigable.
  public static func plan(
    deferred: [DeferredWindow], spaceIndex: DesktopIndex, shortcuts: Shortcuts
  ) -> [CarryAction] {
    deferred.map { dw in
      let cap = dw.captured
      guard let uuid = cap.spaceUUID, let to = spaceIndex.globalOrdinal(ofSpaceUUID: uuid) else {
        return .skip(.targetGone, cap)  // captured desktop no longer exists
      }
      guard let from = dw.currentGlobalDesktop else { return .skip(.gone, cap) }  // no live desktop
      if from == to { return .skip(.alreadyOnDesktop, cap) }  // already home (idempotent)
      guard navigable(to, shortcuts), navigable(from, shortcuts) else {
        return .skip(.unreachableShortcut, cap)  // can't reach to grab it, or can't reach its target
      }
      return .carry(cap, fromGlobal: from, toGlobal: to)
    }
  }

  /// A desktop is navigable if we can step to it (Move-a-space bound, reaches any desktop on its display) OR jump
  /// straight to it (a bound ⌥⌘N for that number). Independent of which display — a cross-display target is still
  /// "navigable" (we can switch the view to it); whether the held window FOLLOWS is the sweep's concern + verify.
  private static func navigable(_ global: Int, _ shortcuts: Shortcuts) -> Bool {
    shortcuts.canStep || shortcuts.switchTo(global) != nil
  }

  // MARK: - I/O sweep result

  public struct Outcome: Sendable {
    public let bundleId: String
    public let title: String?
    public let cgWindowId: UInt32
    public let fromGlobal: Int?
    public let toGlobal: Int?
    public let outcome: String  // "would-carry" | "carried" | "aborted" | a CarrySkip rawValue
    init(cap: CapturedWindow, fromGlobal: Int?, toGlobal: Int?, outcome: String) {
      bundleId = cap.bundleId
      title = cap.title
      cgWindowId = cap.cgWindowId
      self.fromGlobal = fromGlobal
      self.toGlobal = toGlobal
      self.outcome = outcome
    }
  }

  public struct Progress: Sendable {
    public let done: Int  // k of N (the carry currently being attempted)
    public let total: Int  // N planned carries
    public let toDesktop: Int  // the target desktop being carried to
    public let bundleId: String
  }

  public struct CarryResult: Sendable {
    public let plannedCarries: Int  // # windows the plan decided to carry (executed in apply; listed in dry-run)
    public let carried: Int  // # that landed on their target desktop (0 in dry-run)
    public let skips: [CarrySkip: Int]
    public let aborted: Bool
    public let abortedAfter: Int  // # carried before a real-input abort
    public let outcomes: [Outcome]
    public let dryRun: Bool
    public let readFailed: Bool  // cid == 0 — nothing read or done (M4)
    public let navigationDead: Bool  // no Switch-to-Desktop AND no Move-a-space bound — can't navigate at all
    public var skipped: Int { skips.values.reduce(0, +) }
  }

  // MARK: - I/O sweep

  /// Carry the snapshot's deferred-background windows home. `apply == false` is a DRY RUN — it re-classifies,
  /// plans, and lists per-window targets but moves nothing (the safe default; note this validates the PLAN, not
  /// the mechanism — whether a held window follows is only provable live). `onProgress` streams `Carrying k/N`.
  public static func carry(
    _ snapshot: Snapshot, apply: Bool,
    onProgress: (Progress) -> Void = { _ in }
  ) async -> CarryResult {
    guard let live = Restore.gatherLiveState() else {  // SkyLight load failed → act on nothing (M4)
      return CarryResult(
        plannedCarries: 0, carried: 0, skips: [:], aborted: false, abortedAfter: 0,
        outcomes: [], dryRun: !apply, readFailed: true, navigationDead: false)
    }
    let cid = live.cid
    let index = DesktopIndex.live(cid)
    let shortcuts = Shortcuts.live()
    guard shortcuts.canNavigate else {  // both nav mechanisms dead → honest stop, never a silent do-nothing
      return CarryResult(
        plannedCarries: 0, carried: 0, skips: [:], aborted: false, abortedAfter: 0,
        outcomes: [], dryRun: !apply, readFailed: false, navigationDead: true)
    }

    // Fresh deferred set (Blocker-1): keep Restore.decide's `.deferredBackground` windows, each paired with its
    // CURRENT live desktop (the int ManagedSpaceID cgsSpacesForWindow returns → global ordinal).
    let deferred: [DeferredWindow] = Restore.classify(snapshot, against: live).compactMap {
      (cap, action) in
      guard action == .skip(.deferredBackground) else { return nil }
      let currentMid = cgsSpacesForWindow(cid, cap.cgWindowId).first
      return DeferredWindow(
        captured: cap,
        currentGlobalDesktop: currentMid.flatMap { index.globalOrdinal(ofManagedID: $0) })
    }
    let actions = plan(deferred: deferred, spaceIndex: index, shortcuts: shortcuts)
    let total = actions.reduce(0) { if case .carry = $1 { return $0 + 1 } else { return $0 } }

    var carried = 0
    var done = 0
    var abortedAfter = 0
    var aborted = false
    var skips: [CarrySkip: Int] = [:]
    var outcomes: [Outcome] = []
    for (dw, action) in zip(deferred, actions) {  // 1:1 — plan maps each deferred window to one action
      switch action {
      case .skip(let reason, let cap):
        skips[reason, default: 0] += 1
        // Surface the desktops even for skips: current (from) is known, target (to) resolves from the
        // captured spaceUUID — so a verbose line reads `desktop 5→5 (alreadyOnDesktop)`, not `?→?`.
        let to = cap.spaceUUID.flatMap { index.globalOrdinal(ofSpaceUUID: $0) }
        outcomes.append(
          Outcome(
            cap: cap, fromGlobal: dw.currentGlobalDesktop, toGlobal: to, outcome: reason.rawValue))
      case .carry(let cap, let from, let to):
        done += 1
        onProgress(Progress(done: done, total: total, toDesktop: to, bundleId: cap.bundleId))
        guard apply, !aborted else {  // dry run lists the plan; after an abort the rest are left untouched
          outcomes.append(
            Outcome(
              cap: cap, fromGlobal: from, toGlobal: to,
              outcome: apply ? "skipped (aborted)" : "would-carry"))
          continue
        }
        switch await executeCarry(
          cap, fromGlobal: from, toGlobal: to, index: index, shortcuts: shortcuts, cid: cid)
        {
        case .carried:
          carried += 1
          outcomes.append(Outcome(cap: cap, fromGlobal: from, toGlobal: to, outcome: "carried"))
        case .failed:
          skips[.carryFailed, default: 0] += 1
          outcomes.append(
            Outcome(
              cap: cap, fromGlobal: from, toGlobal: to, outcome: CarrySkip.carryFailed.rawValue))
        case .aborted:
          aborted = true
          abortedAfter = carried
          outcomes.append(Outcome(cap: cap, fromGlobal: from, toGlobal: to, outcome: "aborted"))
        }
      }
    }
    return CarryResult(
      plannedCarries: total, carried: carried, skips: skips, aborted: aborted,
      abortedAfter: abortedAfter, outcomes: outcomes, dryRun: !apply,
      readFailed: false, navigationDead: false)
  }

  // MARK: - One window's carry (navigate → grab → carry → place → verify)

  private enum CarryOutcome { case carried, failed, aborted }
  private static let driftThreshold: CGFloat = 12  // px a parked cursor may wander before we call it real input

  private static func executeCarry(
    _ cap: CapturedWindow, fromGlobal: Int, toGlobal: Int,
    index: DesktopIndex, shortcuts: Shortcuts, cid: CGSConnectionID
  ) async -> CarryOutcome {
    let to = index.locate(global: toGlobal)
    let from = index.locate(global: fromGlobal)
    let sameDisplay = (to?.displayIndex == from?.displayIndex)
    log.info(
      "carry wid=\(cap.cgWindowId) \(cap.bundleId, privacy: .public) from=\(fromGlobal)(disp \(from?.displayIndex ?? -1)) to=\(toGlobal)(disp \(to?.displayIndex ?? -1)) sameDisplay=\(sameDisplay)"
    )

    // 1) grab-leg — navigate the VIEW to the window's current desktop so it's on screen + grabbable.
    guard await navigateView(toGlobal: fromGlobal, index: index, shortcuts: shortcuts, cid: cid)
    else {
      log.info("carry wid=\(cap.cgWindowId) FAILED grab-leg nav: couldn't reach from=\(fromGlobal)")
      return .failed
    }
    // 2) confirm the (off-screen-this-session) window's frame is valid after the nav (D3 grab-leg) + grab it.
    guard let bounds = onScreenBounds(cap.cgWindowId) else {
      let nowIdx = from.flatMap { liveIndex($0.displayIndex, cid) } ?? -1  // did nav land where we asked?
      log.info(
        "carry wid=\(cap.cgWindowId) FAILED grab-leg: not on screen after nav to \(fromGlobal); disp \(from?.displayIndex ?? -1) now at perIdx \(nowIdx) (wanted \(from?.perDisplayIndex ?? -1))"
      )
      return .failed
    }
    log.info(
      "carry wid=\(cap.cgWindowId) on screen at (\(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))×\(Int(bounds.height)))"
    )
    try? await Task.sleep(for: .milliseconds(700))  // settle the freshly-navigated desktop before grabbing

    // 2b) grab the titlebar — trying a few points until the window actually FOLLOWS the grab-drag. The dead
    // center the spike used is Safari's address bar / Chrome's tab strip (not draggable) → the window wasn't
    // held and got stranded by the desktop switch. No draggable point (Chrome) ⇒ nil: AX-place it where it is
    // (reachable now) + honest carryFailed, never a pointless desktop switch that strands it.
    guard var parked = await grabTitlebar(cap.cgWindowId, bounds: bounds) else {
      log.info(
        "carry wid=\(cap.cgWindowId) no draggable titlebar point found — AX-place only, carryFailed"
      )
      _ = placeFrame(cap)
      return .failed
    }
    var released = false
    func release() {
      if !released {
        endWindowGrab(at: parked)
        released = true
      }
    }
    defer { release() }  // FLOOR GUARANTEE: the synthetic drag is released on EVERY exit path

    // 3) place-leg — carry the HELD window to its target desktop, but only when target + current share a
    // display (a desktop switch can't move a window between displays). Cross-display falls through to the AX
    // place below. A real mouse-move drifts the parked cursor mid-carry ⇒ abort + release.
    if let to, let from, to.displayIndex == from.displayIndex,
      to.perDisplayIndex != from.perDisplayIndex
    {
      log.info(
        "carry wid=\(cap.cgWindowId) grabbed (window followed) — place-leg stepping \(from.perDisplayIndex)→\(to.perDisplayIndex) on disp \(from.displayIndex)"
      )
      if await carryHeld(
        toIndex: to.perDisplayIndex, fromIndex: from.perDisplayIndex,
        toGlobal: toGlobal, shortcuts: shortcuts, parked: &parked) == .aborted
      {
        log.info("carry wid=\(cap.cgWindowId) ABORTED (cursor drift)")
        return .aborted  // defer releases the drag at the parked point
      }
    } else {
      log.info(
        "carry wid=\(cap.cgWindowId) place-leg skipped (cross-display or same desktop) — AX place only"
      )
    }
    // 4) commit the drag (drop) before placing, then let it settle.
    release()
    try? await Task.sleep(for: .milliseconds(500))
    // 5) place display + position + size via public AX — the window is on the active desktop now (#keeps-3 path).
    let placed = placeFrame(cap)
    // 6) verify it landed: the window's live desktop now maps to its target global ordinal?
    let landedOn = cgsSpacesForWindow(cid, cap.cgWindowId).first.flatMap {
      index.globalOrdinal(ofManagedID: $0)
    }
    let outcome: CarryOutcome = landedOn == toGlobal ? .carried : .failed
    log.info(
      "carry wid=\(cap.cgWindowId) landedOn=\(landedOn ?? -1) target=\(toGlobal) axPlaced=\(placed) → \(outcome == .carried ? "CARRIED" : "carryFailed", privacy: .public)"
    )
    return outcome
  }

  /// Carry a HELD window across desktops on its current display: one global ⌥⌘N jump if the target is directly
  /// bound (proven single-jump, #keeps-6), else step desktop-by-desktop (proven multi-step, D2). Nudges the drag
  /// + checks cursor drift each step; `.aborted` ⇒ the caller drops + halts.
  private static func carryHeld(
    toIndex: Int, fromIndex: Int, toGlobal: Int,
    shortcuts: Shortcuts, parked: inout CGPoint
  ) async -> CarryOutcome {
    if let jump = shortcuts.switchTo(toGlobal) {
      postKeyChord(jump.keyCode, flags: jump.flags)
      try? await Task.sleep(for: .milliseconds(900))  // the held window follows the jump
      if drifted(from: parked) { return .aborted }
      parked.x += 3
      dragHeldWindow(to: parked)
      try? await Task.sleep(for: .milliseconds(300))
      return .carried
    }
    let right = toIndex > fromIndex
    guard let step = right ? shortcuts.moveRight : shortcuts.moveLeft, step.isEnabled else {
      return .failed
    }
    for _ in 0..<abs(toIndex - fromIndex) {
      postKeyChord(step.keyCode, flags: step.flags)
      try? await Task.sleep(for: .milliseconds(750))  // let the switch animate, carrying the held window
      if drifted(from: parked) { return .aborted }
      parked.x += 3
      dragHeldWindow(to: parked)  // nudge so the OS keeps the window held across the switch
      try? await Task.sleep(for: .milliseconds(450))
    }
    return .carried
  }

  // MARK: - Navigation (unheld view moves — the grab-leg)

  /// Navigate the VIEW to a global desktop: one ⌥⌘N jump when it's directly bound, else move the cursor to its
  /// display and step from the display's current desktop to the target index, polling until each switch lands.
  private static func navigateView(
    toGlobal target: Int, index: DesktopIndex,
    shortcuts: Shortcuts, cid: CGSConnectionID
  ) async -> Bool {
    guard let (dispIdx, toIdx) = index.locate(global: target) else { return false }
    if let jump = shortcuts.switchTo(target) {  // direct global jump — no stepping
      postKeyChord(jump.keyCode, flags: jump.flags)
      return await poll(displayIdx: dispIdx, until: { $0 == toIdx }, cid: cid)
    }
    guard let did = displayID(forIdentifier: index.displays[dispIdx].identifier) else {
      return false
    }
    moveCursor(to: CGPoint(x: CGDisplayBounds(did).midX, y: CGDisplayBounds(did).midY))
    try? await Task.sleep(for: .milliseconds(300))
    var cur = liveIndex(dispIdx, cid) ?? -1
    var guardSteps = 0
    while cur != toIdx && guardSteps < 40 {
      guard let step = toIdx > cur ? shortcuts.moveRight : shortcuts.moveLeft, step.isEnabled else {
        return false
      }
      let before = cur
      postKeyChord(step.keyCode, flags: step.flags)
      cur = await pollChange(dispIdx, from: before, cid: cid)
      if cur == before { return false }  // stall — the synthetic step didn't register
      guardSteps += 1
    }
    return cur == toIdx
  }

  /// Poll the live active index of a display until `predicate` holds or it times out (the ~1.1s space-switch
  /// animation — reading sooner misreads, the poll-until-landed lesson).
  private static func poll(
    displayIdx: Int, until predicate: (Int?) -> Bool, cid: CGSConnectionID,
    timeout: Double = 2.0
  ) async -> Bool {
    var waited = 0.0
    while waited < timeout {
      if predicate(liveIndex(displayIdx, cid)) { return true }
      try? await Task.sleep(for: .milliseconds(150))
      waited += 0.15
    }
    return predicate(liveIndex(displayIdx, cid))
  }

  /// Step variant: poll until the active index CHANGES from `before` (bounded); returns the new index, or
  /// `before` on a stall.
  private static func pollChange(
    _ displayIdx: Int, from before: Int, cid: CGSConnectionID,
    timeout: Double = 2.0
  ) async -> Int {
    var waited = 0.0
    while waited < timeout {
      try? await Task.sleep(for: .milliseconds(150))
      waited += 0.15
      if let now = liveIndex(displayIdx, cid), now != before { return now }
    }
    return before
  }

  private static func liveIndex(_ displayIdx: Int, _ cid: CGSConnectionID) -> Int? {
    let displays = DesktopIndex.live(cid).displays
    return displayIdx < displays.count ? displays[displayIdx].currentIndex : nil
  }

  // MARK: - I/O helpers

  private static func drifted(from parked: CGPoint) -> Bool {
    guard let cur = cursorLocation() else { return false }
    return hypot(cur.x - parked.x, cur.y - parked.y) > driftThreshold
  }

  /// Grab the window's titlebar, trying a couple of points until one actually starts a window-drag — confirmed by
  /// the window FOLLOWING the small grab-drag (~8px). Dead-center works for plain titlebars (Bear, Raycast,
  /// Fantastical — the validated cases) but is Safari's address bar; off-center-left clears the traffic lights +
  /// that centered content. Two points only, center first, so plain apps poke once and browser chrome isn't
  /// raked across (no stray tab/button hits beyond the one fallback). Some apps (Chrome — tabs span the whole
  /// top) have no draggable point → nil (the caller AX-places + counts `carryFailed`, never strands the window).
  /// Returns the parked drag point if a grab took (the caller must release it).
  private static func grabTitlebar(_ wid: CGWindowID, bounds: CGRect) async -> CGPoint? {
    let y = bounds.minY + 8
    let points = [
      CGPoint(x: bounds.midX, y: y),  // plain titlebars — the validated path (one poke)
      CGPoint(x: bounds.minX + 80, y: y),
    ]  // off-center-left, past traffic lights (Safari toolbar gap)
    for p in points {
      moveCursor(to: p)
      try? await Task.sleep(for: .milliseconds(120))
      let parked = beginWindowGrab(at: p)
      try? await Task.sleep(for: .milliseconds(150))
      if let now = onScreenBounds(wid), hypot(now.minX - bounds.minX, now.minY - bounds.minY) > 3 {
        return parked  // the window moved with the grab-drag ⇒ it's really held
      }
      endWindowGrab(at: parked)  // didn't take — release and try the next point
      try? await Task.sleep(for: .milliseconds(120))
    }
    return nil
  }

  /// The window's current on-screen frame, by cgWindowId (the grab-leg verify: is its frame valid after nav?).
  private static func onScreenBounds(_ wid: CGWindowID) -> CGRect? {
    for w
      in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]])
      ?? []
    {
      guard (w[kCGWindowNumber as String] as? CGWindowID) == wid,
        let bd = w[kCGWindowBounds as String],
        let r = CGRect(dictionaryRepresentation: bd as! CFDictionary)
      else { continue }
      return r
    }
    return nil
  }

  /// Place the carried window's display + position + size via public AX, reusing Restore's exact size→pos→size.
  /// Match by cgWindowId among the live app's windows (now on the active desktop). pid may have churned, so
  /// resolve the running app by bundleId, not the captured pid.
  @discardableResult
  private static func placeFrame(_ cap: CapturedWindow) -> Bool {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: cap.bundleId) {
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(axApp, 1.0)  // the #keeps-3/#keeps-6 freeze guard
      var winsVal: AnyObject?
      guard
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsVal) == .success,
        let windows = winsVal as? [AXUIElement]
      else { continue }
      for w in windows where axWindowID(w) == cap.cgWindowId {
        return Restore.setFrame(w, cap.frame)
      }
    }
    return false
  }

  /// Map a CGS "Display Identifier" (== display UUID) to a live CGDirectDisplayID, to park the cursor on that
  /// display before stepping (⌃→ acts on the cursor's display).
  private static func displayID(forIdentifier identifier: String) -> CGDirectDisplayID? {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.first { d in
      guard let u = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue() else { return false }
      return (CFUUIDCreateString(nil, u) as String?) == identifier
    }
  }
}
