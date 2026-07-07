// Carry — #keeps-12's verified VISIBLE half: carry every background-desktop window silent restore can't reach
// (#keeps-3's `.deferredBackground` set) back to its captured desktop + frame. Same shape as Capture/Restore: a pure
// `plan` truth-table (every carry/skip named + counted — no silent miss, Scenario A) split from an I/O sweep
// that navigates desktops, holds each window by a synthetic title-bar mouse-down, carries it across the space switch
// (proven D2/D3), VERIFIES it landed, then AX-places its frame (#keeps-3's size→pos→size).
//
// It re-classifies FRESH at trigger time (Blocker-1): a deliberate carry fires whenever clicked and must act on
// CURRENT live state, and `Restore.Result` threw away the spaceUUID/frame anyway — so it re-runs Restore.decide
// over the snapshot via the shared seam and keeps the deferred windows (which carry the spaceUUID + frame).
//
// Two move types compose a carry, and neither alone is enough: a desktop switch (held drag) moves a window
// between desktops on the SAME display; an AX frame-set moves it between displays (different global coords) but
// NOT between desktops. So same-display targets are carried then placed. Cross-display targets cannot be
// desktop-carried by this primitive; membership verification runs before AX placement, so a wrong-desktop window
// is reported honestly instead of being framed into a misleading position.
import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import ColorSync            // CGDisplayCreateUUIDFromDisplayID — map a CGS display identifier to a CGDirectDisplayID
import CGSPrivate
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
            self.captured = captured; self.currentGlobalDesktop = currentGlobalDesktop
        }
    }

    /// Why a deferred window is not carried — every one counted + surfaced (the Capture/Restore "no silent miss"
    /// discipline). #keeps-12 keeps the I/O failures specific so a failed app/window can be quarantined without
    /// blocking unrelated eligible windows.
    public enum CarrySkip: String, Codable, CaseIterable, Error, Sendable {
        case alreadyOnDesktop      // current desktop == target — no-op (idempotence)
        case targetGone            // captured spaceUUID no longer in the live topology — its desktop was deleted
        case unreachableShortcut   // can't navigate to it — needed Switch-to-Desktop/Move-a-space is unbound
        case gone                  // no resolvable current desktop — closed/vanished since classify
        case stickyAllDesktops     // all-desktops/pinned windows have no single Space to carry
        case noCandidateGrip       // no usable grip profile could be produced
        case offDisplayGrip        // grip candidates exist, but all land on a different physical display
        case spaceSwitchFailed     // the decoded shortcut did not switch the target display's Space
        case membershipMismatch    // Space switched and mouse released, but membership did not land on target
        case axPlaceFailed         // membership landed, but the final public-AX frame placement failed
        case userInterrupt         // physical mouse movement interrupted the run
    }

    public enum CarryAction: Equatable {
        case carry(CapturedWindow, fromGlobal: Int, toGlobal: Int)
        case skip(CarrySkip, CapturedWindow)
    }

    public enum GripCandidateSource: String, Codable, CaseIterable, Sendable {
        case closeButtonTop
        case trafficLightGap
        case trafficLightRow
        case knownGoodFallback
    }

    public struct GripCandidate: Equatable, Sendable {
        public let source: GripCandidateSource
        public let point: CGPoint
        public init(source: GripCandidateSource, point: CGPoint) {
            self.source = source
            self.point = point
        }
    }

    public struct ChromeButtonFrames: Equatable, Sendable {
        public let close: CGRect?
        public let minimize: CGRect?
        public let zoom: CGRect?
        public init(close: CGRect?, minimize: CGRect?, zoom: CGRect?) {
            self.close = close
            self.minimize = minimize
            self.zoom = zoom
        }
    }

    public struct GripProfile: Equatable, Sendable {
        public let candidates: [GripCandidate]
        public init(candidates: [GripCandidate]) { self.candidates = candidates }
    }

    /// Pure #keeps-12 grip-profile generation. AX button frames are global, so generated points are global too.
    /// Candidate order is deliberate: close-button-top first, other derived traffic-light geometry next,
    /// prototype fallbacks last.
    public static func gripProfile(windowBounds: CGRect, buttons: ChromeButtonFrames) -> GripProfile {
        func point(_ source: GripCandidateSource, _ x: CGFloat, _ y: CGFloat) -> GripCandidate? {
            let p = CGPoint(x: x, y: y)
            return windowBounds.contains(p) ? GripCandidate(source: source, point: p) : nil
        }

        var candidates: [GripCandidate] = []
        if let close = buttons.close {
            if let c = point(.closeButtonTop, close.midX, close.minY - 3) { candidates.append(c) }
        }
        if let close = buttons.close, let minimize = buttons.minimize {
            let gapX = (close.maxX + minimize.minX) / 2
            let rowTop = min(close.minY, minimize.minY)
            let rowMidY = (close.midY + minimize.midY) / 2
            if let c = point(.trafficLightGap, gapX, rowTop - 3) { candidates.append(c) }
            if let c = point(.trafficLightGap, gapX, rowMidY) { candidates.append(c) }
        }
        if let minimize = buttons.minimize, let zoom = buttons.zoom {
            let gapX = (minimize.maxX + zoom.minX) / 2
            let rowMidY = (minimize.midY + zoom.midY) / 2
            if let c = point(.trafficLightRow, gapX, rowMidY) { candidates.append(c) }
        }

        let fallbackOffsets: [(CGFloat, CGFloat)] = [
            (72, 20),
            (72, 14),
            (windowBounds.width - 180, 20),
            (windowBounds.width / 2, 12),
        ]
        for (xOffset, yOffset) in fallbackOffsets {
            let x = windowBounds.minX + min(max(xOffset, 24), max(24, windowBounds.width - 24))
            if let c = point(.knownGoodFallback, x, windowBounds.minY + yOffset) { candidates.append(c) }
        }

        var seen = Set<String>()
        let unique = candidates.filter { c in
            let key = "\(Int(c.point.x)):\(Int(c.point.y)):\(c.source.rawValue)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        return GripProfile(candidates: unique)
    }

    /// Keep only candidates on the same physical display as the target window. A spanning window can contain a
    /// point on another monitor; clicking there sends the Space-switch to the wrong display.
    public static func candidatesOnTargetDisplay(_ candidates: [GripCandidate], windowBounds: CGRect,
                                                 displayBounds: [CGRect]) -> [GripCandidate] {
        guard let target = displayBounds.first(where: { $0.contains(CGPoint(x: windowBounds.midX, y: windowBounds.midY)) }) else {
            return []
        }
        return candidates.filter { target.contains($0.point) }
    }

    /// The carry filter, as one pure function over the fresh deferred set + the live topology + the user's
    /// bindings. Order matters: target resolves → current resolves → not already there → both legs navigable.
    public static func plan(deferred: [DeferredWindow], spaceIndex: DesktopIndex, shortcuts: Shortcuts) -> [CarryAction] {
        deferred.map { dw in
            let cap = dw.captured
            if cap.sticky || cap.spaceIds.count != 1 { return .skip(.stickyAllDesktops, cap) }
            guard let uuid = cap.spaceUUID, let to = spaceIndex.globalOrdinal(ofSpaceUUID: uuid) else {
                return .skip(.targetGone, cap)        // captured desktop no longer exists
            }
            guard let from = dw.currentGlobalDesktop else { return .skip(.gone, cap) }   // no live desktop
            if from == to { return .skip(.alreadyOnDesktop, cap) }                       // already home (idempotent)
            guard navigable(to, shortcuts), navigable(from, shortcuts) else {
                return .skip(.unreachableShortcut, cap)   // can't reach to grab it, or can't reach its target
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
        public let outcome: String     // "would-carry" | "carried" | "aborted" | a CarrySkip rawValue
        init(cap: CapturedWindow, fromGlobal: Int?, toGlobal: Int?, outcome: String) {
            bundleId = cap.bundleId; title = cap.title; cgWindowId = cap.cgWindowId
            self.fromGlobal = fromGlobal; self.toGlobal = toGlobal; self.outcome = outcome
        }
    }

    public struct Progress: Sendable {
        public let done: Int           // k of N (the carry currently being attempted)
        public let total: Int          // N planned carries
        public let toDesktop: Int      // the target desktop being carried to
        public let bundleId: String
    }

    public struct CarryResult: Sendable {
        public let plannedCarries: Int   // # windows the plan decided to carry (executed in apply; listed in dry-run)
        public let carried: Int          // # that landed on their target desktop (0 in dry-run)
        public let skips: [CarrySkip: Int]
        public let aborted: Bool
        public let abortedAfter: Int     // # carried before a real-input abort
        public let outcomes: [Outcome]
        public let dryRun: Bool
        public let readFailed: Bool      // cid == 0 — nothing read or done (M4)
        public let navigationDead: Bool  // no Switch-to-Desktop AND no Move-a-space bound — can't navigate at all
        public var skipped: Int { skips.values.reduce(0, +) }
    }

    // MARK: - I/O sweep

    /// Carry the snapshot's deferred-background windows home. `apply == false` is a DRY RUN — it re-classifies,
    /// plans, and lists per-window targets but moves nothing (the safe default; note this validates the PLAN, not
    /// the mechanism — whether a held window follows is only provable live). `onProgress` streams `Carrying k/N`.
    public static func carry(_ snapshot: Snapshot, apply: Bool,
                             onProgress: (Progress) -> Void = { _ in }) async -> CarryResult {
        guard let live = Restore.gatherLiveState() else {   // SkyLight load failed → act on nothing (M4)
            return CarryResult(plannedCarries: 0, carried: 0, skips: [:], aborted: false, abortedAfter: 0,
                               outcomes: [], dryRun: !apply, readFailed: true, navigationDead: false)
        }
        let cid = live.cid
        let index = DesktopIndex.live(cid)
        let shortcuts = Shortcuts.live()
        guard shortcuts.canNavigate else {   // both nav mechanisms dead → honest stop, never a silent do-nothing
            return CarryResult(plannedCarries: 0, carried: 0, skips: [:], aborted: false, abortedAfter: 0,
                               outcomes: [], dryRun: !apply, readFailed: false, navigationDead: true)
        }

        // Fresh deferred set (Blocker-1): keep Restore.decide's `.deferredBackground` windows, each paired with its
        // CURRENT live desktop (the int ManagedSpaceID cgsSpacesForWindow returns → global ordinal).
        let deferred: [DeferredWindow] = Restore.classify(snapshot, against: live).compactMap { (cap, action) in
            guard action == .skip(.deferredBackground) else { return nil }
            let currentMid = cgsSpacesForWindow(cid, cap.cgWindowId).first
            return DeferredWindow(captured: cap, currentGlobalDesktop: currentMid.flatMap { index.globalOrdinal(ofManagedID: $0) })
        }
        let actions = plan(deferred: deferred, spaceIndex: index, shortcuts: shortcuts)
        let total = actions.reduce(0) { if case .carry = $1 { return $0 + 1 } else { return $0 } }
        if DebugTrace.enabled {   // #keeps-15: carry header — the carry's view of the live arrangement (focus-noted)
            DebugTrace.log("=== carry fp=\(snapshot.configFingerprint) apply=\(apply)\(DebugTrace.focusNote) — displays: "
                + DebugTrace.displaysHeader(DebugTrace.activeDisplays()))
        }

        var carried = 0, done = 0, abortedAfter = 0, aborted = false
        var skips: [CarrySkip: Int] = [:]
        var outcomes: [Outcome] = []
        for (dw, action) in zip(deferred, actions) {   // 1:1 — plan maps each deferred window to one action
            switch action {
            case .skip(let reason, let cap):
                skips[reason, default: 0] += 1
                // Surface the desktops even for skips: current (from) is known, target (to) resolves from the
                // captured spaceUUID — so a verbose line reads `desktop 5→5 (alreadyOnDesktop)`, not `?→?`.
                let to = cap.spaceUUID.flatMap { index.globalOrdinal(ofSpaceUUID: $0) }
                outcomes.append(Outcome(cap: cap, fromGlobal: dw.currentGlobalDesktop, toGlobal: to, outcome: reason.rawValue))
            case .carry(let cap, let from, let to):
                done += 1
                onProgress(Progress(done: done, total: total, toDesktop: to, bundleId: cap.bundleId))
                guard apply, !aborted else {   // dry run lists the plan; after an abort the rest are left untouched
                    outcomes.append(Outcome(cap: cap, fromGlobal: from, toGlobal: to,
                                            outcome: apply ? "skipped (aborted)" : "would-carry"))
                    continue
                }
                switch await executeCarry(cap, fromGlobal: from, toGlobal: to, index: index, shortcuts: shortcuts, cid: cid) {
                case .carried:
                    carried += 1; outcomes.append(Outcome(cap: cap, fromGlobal: from, toGlobal: to, outcome: "carried"))
                case .failed(let reason):
                    skips[reason, default: 0] += 1
                    outcomes.append(Outcome(cap: cap, fromGlobal: from, toGlobal: to, outcome: reason.rawValue))
                case .aborted(let reason):
                    skips[reason, default: 0] += 1
                    aborted = true; abortedAfter = carried
                    outcomes.append(Outcome(cap: cap, fromGlobal: from, toGlobal: to, outcome: reason.rawValue))
                }
            }
        }
        if DebugTrace.enabled {   // #keeps-15: record EVERY carry outcome (incl. fail-closed) — the trace was blind to non-placements
            for o in outcomes where DebugTrace.traces(bundleId: o.bundleId, title: o.title) {
                DebugTrace.log("[carry:\(o.outcome)] \(o.bundleId) wid=\(o.cgWindowId) \"\(o.title ?? "")\""
                    + " — desktop \(o.fromGlobal.map(String.init) ?? "?")→\(o.toGlobal.map(String.init) ?? "?")")
            }
        }
        return CarryResult(plannedCarries: total, carried: carried, skips: skips, aborted: aborted,
                           abortedAfter: abortedAfter, outcomes: outcomes, dryRun: !apply,
                           readFailed: false, navigationDead: false)
    }

    // MARK: - One window's carry (navigate → grab → carry → verify → place)

    private enum CarryOutcome { case carried, failed(CarrySkip), aborted(CarrySkip) }
    private static let driftThreshold: CGFloat = 12   // px a parked cursor may wander before we call it real input

    private static func executeCarry(_ cap: CapturedWindow, fromGlobal: Int, toGlobal: Int,
                                     index: DesktopIndex, shortcuts: Shortcuts, cid: CGSConnectionID) async -> CarryOutcome {
        let to = index.locate(global: toGlobal), from = index.locate(global: fromGlobal)
        let sameDisplay = (to?.displayIndex == from?.displayIndex)
        log.info("carry wid=\(cap.cgWindowId) \(cap.bundleId, privacy: .public) from=\(fromGlobal)(disp \(from?.displayIndex ?? -1)) to=\(toGlobal)(disp \(to?.displayIndex ?? -1)) sameDisplay=\(sameDisplay)")

        // 1) grab-leg — navigate the VIEW to the window's current desktop so it's on screen + grabbable.
        guard await navigateView(toGlobal: fromGlobal, index: index, shortcuts: shortcuts, cid: cid) else {
            log.info("carry wid=\(cap.cgWindowId) FAILED grab-leg nav: couldn't reach from=\(fromGlobal)")
            return .failed(.unreachableShortcut)
        }
        // 2) bring the exact target forward, confirm its frame after navigation, then grab it. Raising first avoids
        // sending the synthetic mouse-down into an overlapping window on crowded desktops.
        _ = raiseWindow(cap)
        try? await Task.sleep(for: .milliseconds(350))
        guard let bounds = onScreenBounds(cap.cgWindowId) else {
            let nowIdx = from.flatMap { liveIndex($0.displayIndex, cid) } ?? -1   // did nav land where we asked?
            log.info("carry wid=\(cap.cgWindowId) FAILED grab-leg: not on screen after nav to \(fromGlobal); disp \(from?.displayIndex ?? -1) now at perIdx \(nowIdx) (wanted \(from?.perDisplayIndex ?? -1))")
            return .failed(.gone)
        }
        log.info("carry wid=\(cap.cgWindowId) on screen at (\(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))×\(Int(bounds.height)))")
        try? await Task.sleep(for: .milliseconds(700))   // settle the freshly-navigated desktop before grabbing

        let initialParked: CGPoint
        switch await grabTitlebar(cap, bounds: bounds) {
        case .success(let point):
            initialParked = point
        case .failure(let reason):
            log.info("carry wid=\(cap.cgWindowId) grip failed: \(reason.rawValue, privacy: .public)")
            return .failed(reason)
        }
        var parked = initialParked
        var released = false
        func release() { if !released { endWindowGrab(at: parked); released = true } }
        defer { release() }   // FLOOR GUARANTEE: the synthetic drag is released on EVERY exit path

        // 3) place-leg — carry the HELD window to its target desktop, but only when target + current share a
        // display (a desktop switch can't move a window between displays). Cross-display falls through to the AX
        // place below. A real mouse-move drifts the parked cursor mid-carry ⇒ abort + release.
        if let to, let from, to.displayIndex == from.displayIndex, to.perDisplayIndex != from.perDisplayIndex {
            log.info("carry wid=\(cap.cgWindowId) held titlebar — place-leg stepping \(from.perDisplayIndex)→\(to.perDisplayIndex) on disp \(from.displayIndex)")
            switch await carryHeld(displayIndex: from.displayIndex, toIndex: to.perDisplayIndex,
                                   fromIndex: from.perDisplayIndex, toGlobal: toGlobal,
                                   shortcuts: shortcuts, cid: cid, parked: &parked) {
            case .carried:
                break
            case .failed(let reason):
                log.info("carry wid=\(cap.cgWindowId) FAILED place-leg: \(reason.rawValue, privacy: .public)")
                return .failed(reason)
            case .aborted(let reason):
                log.info("carry wid=\(cap.cgWindowId) ABORTED (cursor drift)")
                return .aborted(reason)   // defer releases the drag at the parked point
            }
        } else {
            log.info("carry wid=\(cap.cgWindowId) place-leg skipped (cross-display or same desktop) — verifying membership before AX place")
        }
        // 4) commit the drag (drop), then let membership settle.
        release()
        try? await Task.sleep(for: .milliseconds(500))
        // 5) verify it landed before frame placement. If membership did not land, fail closed rather than moving a
        // window's frame on the wrong Space.
        let landedOn = await pollWindowGlobal(cap.cgWindowId, targetGlobal: toGlobal, index: index, cid: cid)
        guard landedOn == toGlobal else {
            log.info("carry wid=\(cap.cgWindowId) landedOn=\(landedOn ?? -1) target=\(toGlobal) → membershipMismatch")
            return .failed(.membershipMismatch)
        }
        // 6) place display + position + size via public AX — the window is on the target desktop now (#keeps-3 path).
        let placed = placeFrame(cap)
        if DebugTrace.enabled && DebugTrace.traces(bundleId: cap.bundleId, title: cap.title) {
            let displays = DebugTrace.activeDisplays()
            let after = onScreenBounds(cap.cgWindowId).map {
                WindowFrame(x: Int($0.minX), y: Int($0.minY), w: Int($0.width), h: Int($0.height))
            }
            DebugTrace.log(DebugTrace.windowLine(
                bundleId: cap.bundleId, title: cap.title, wid: cap.cgWindowId,
                decision: "carry→place \(placed ? "ok" : "FAILED(axSet)") (desktop \(toGlobal), landed=\(landedOn ?? -1))",
                desired: cap.frame, before: nil, after: after, displays: displays))
        }
        guard placed else {
            log.info("carry wid=\(cap.cgWindowId) landedOn=\(landedOn ?? -1) target=\(toGlobal) axPlaced=false → axPlaceFailed")
            return .failed(.axPlaceFailed)
        }
        log.info("carry wid=\(cap.cgWindowId) landedOn=\(landedOn ?? -1) target=\(toGlobal) axPlaced=true → CARRIED")
        return .carried
    }

    /// Carry a HELD window across desktops on its current display: one global ⌥⌘N jump if the target is directly
    /// bound (proven single-jump, #keeps-6), else step desktop-by-desktop (proven multi-step, D2). The window is
    /// held without any drag/nudge; membership verification after release proves whether the hold carried.
    /// Cursor drift still aborts; `.aborted` ⇒ the caller drops + halts.
    private static func carryHeld(displayIndex: Int, toIndex: Int, fromIndex: Int, toGlobal: Int,
                                  shortcuts: Shortcuts, cid: CGSConnectionID,
                                  parked: inout CGPoint) async -> CarryOutcome {
        if let jump = shortcuts.switchTo(toGlobal) {
            postKeyChord(jump.keyCode, flags: jump.flags)
            let switched = await poll(displayIdx: displayIndex, until: { $0 == toIndex }, cid: cid, timeout: 2.5)
            if !switched { return .failed(.spaceSwitchFailed) }
            try? await Task.sleep(for: .milliseconds(300))
            if drifted(from: parked) { return .aborted(.userInterrupt) }
            try? await Task.sleep(for: .milliseconds(300))
            return .carried
        }
        let right = toIndex > fromIndex
        guard let step = right ? shortcuts.moveRight : shortcuts.moveLeft, step.isEnabled else { return .failed(.unreachableShortcut) }
        var cur = fromIndex
        for _ in 0..<abs(toIndex - fromIndex) {
            postKeyChord(step.keyCode, flags: step.flags)
            let next = await pollChange(displayIndex, from: cur, cid: cid, timeout: 2.5)
            if next == cur { return .failed(.spaceSwitchFailed) }
            cur = next
            if drifted(from: parked) { return .aborted(.userInterrupt) }
            try? await Task.sleep(for: .milliseconds(450))
        }
        return cur == toIndex ? .carried : .failed(.spaceSwitchFailed)
    }

    // MARK: - Navigation (unheld view moves — the grab-leg)

    /// Navigate the VIEW to a global desktop: one ⌥⌘N jump when it's directly bound, else move the cursor to its
    /// display and step from the display's current desktop to the target index, polling until each switch lands.
    private static func navigateView(toGlobal target: Int, index: DesktopIndex,
                                     shortcuts: Shortcuts, cid: CGSConnectionID) async -> Bool {
        guard let (dispIdx, toIdx) = index.locate(global: target) else { return false }
        if let jump = shortcuts.switchTo(target) {   // direct global jump — no stepping
            postKeyChord(jump.keyCode, flags: jump.flags)
            return await poll(displayIdx: dispIdx, until: { $0 == toIdx }, cid: cid)
        }
        guard let did = displayID(forIdentifier: index.displays[dispIdx].identifier) else { return false }
        moveCursor(to: CGPoint(x: CGDisplayBounds(did).midX, y: CGDisplayBounds(did).midY))
        try? await Task.sleep(for: .milliseconds(300))
        var cur = liveIndex(dispIdx, cid) ?? -1
        var guardSteps = 0
        while cur != toIdx && guardSteps < 40 {
            guard let step = toIdx > cur ? shortcuts.moveRight : shortcuts.moveLeft, step.isEnabled else { return false }
            let before = cur
            postKeyChord(step.keyCode, flags: step.flags)
            cur = await pollChange(dispIdx, from: before, cid: cid)
            if cur == before { return false }   // stall — the synthetic step didn't register
            guardSteps += 1
        }
        return cur == toIdx
    }

    /// Poll the live active index of a display until `predicate` holds or it times out (the ~1.1s space-switch
    /// animation — reading sooner misreads, the poll-until-landed lesson).
    private static func poll(displayIdx: Int, until predicate: (Int?) -> Bool, cid: CGSConnectionID,
                             timeout: Double = 2.0) async -> Bool {
        var waited = 0.0
        while waited < timeout {
            if predicate(liveIndex(displayIdx, cid)) { return true }
            try? await Task.sleep(for: .milliseconds(150)); waited += 0.15
        }
        return predicate(liveIndex(displayIdx, cid))
    }

    /// Step variant: poll until the active index CHANGES from `before` (bounded); returns the new index, or
    /// `before` on a stall.
    private static func pollChange(_ displayIdx: Int, from before: Int, cid: CGSConnectionID,
                                   timeout: Double = 2.0) async -> Int {
        var waited = 0.0
        while waited < timeout {
            try? await Task.sleep(for: .milliseconds(150)); waited += 0.15
            if let now = liveIndex(displayIdx, cid), now != before { return now }
        }
        return before
    }

    private static func liveIndex(_ displayIdx: Int, _ cid: CGSConnectionID) -> Int? {
        let displays = DesktopIndex.live(cid).displays
        return displayIdx < displays.count ? displays[displayIdx].currentIndex : nil
    }

    /// Poll a carried window's Space membership. A single immediate read can catch WindowServer mid-transition.
    private static func pollWindowGlobal(_ wid: CGWindowID, targetGlobal: Int,
                                         index: DesktopIndex, cid: CGSConnectionID,
                                         timeout: Double = 3.0) async -> Int? {
        var waited = 0.0
        var last: Int?
        while waited < timeout {
            last = cgsSpacesForWindow(cid, wid).first.flatMap { index.globalOrdinal(ofManagedID: $0) }
            if last == targetGlobal { return last }
            try? await Task.sleep(for: .milliseconds(150)); waited += 0.15
        }
        return cgsSpacesForWindow(cid, wid).first.flatMap { index.globalOrdinal(ofManagedID: $0) } ?? last
    }

    // MARK: - I/O helpers

    private static func drifted(from parked: CGPoint) -> Bool {
        guard let cur = cursorLocation() else { return false }
        return hypot(cur.x - parked.x, cur.y - parked.y) > driftThreshold
    }

    /// Hold the window using a derived grip profile. The Raycast-style close-button-top point is tried first;
    /// prototype offsets are fallback candidates when earlier geometry is unavailable or off-display. There is no
    /// pre-drag proof; the post-release membership check is the proof that the hold carried the target window.
    /// Returns the parked hold point if a candidate was pressed (the caller must release it).
    private static func grabTitlebar(_ cap: CapturedWindow, bounds: CGRect) async -> Result<CGPoint, CarrySkip> {
        let buttons = axElement(for: cap).map { axButtonFrames(for: $0) }
            ?? ChromeButtonFrames(close: nil, minimize: nil, zoom: nil)
        let profile = gripProfile(windowBounds: bounds, buttons: buttons)
        guard !profile.candidates.isEmpty else { return .failure(.noCandidateGrip) }

        let candidates = candidatesOnTargetDisplay(profile.candidates, windowBounds: bounds,
                                                   displayBounds: currentDisplayBounds())
        guard !candidates.isEmpty else {
            log.info("grab wid=\(cap.cgWindowId) all \(profile.candidates.count) candidates are off target display")
            return .failure(.offDisplayGrip)
        }

        let candidate = candidates[0]
        let p = candidate.point
        moveCursor(to: p)
        try? await Task.sleep(for: .milliseconds(120))
        let parked = beginWindowGrab(at: p)
        try? await Task.sleep(for: .milliseconds(150))
        log.info("grab wid=\(cap.cgWindowId) source=\(candidate.source.rawValue, privacy: .public) point=(\(Int(p.x)),\(Int(p.y))) held")
        return .success(parked)
    }

    private static func axButtonFrames(for window: AXUIElement) -> ChromeButtonFrames {
        ChromeButtonFrames(close: axChildFrame(window, "AXCloseButton"),
                           minimize: axChildFrame(window, "AXMinimizeButton"),
                           zoom: axChildFrame(window, "AXZoomButton"))
    }

    private static func axChildFrame(_ window: AXUIElement, _ attribute: String) -> CGRect? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
              let child = value.map({ $0 as! AXUIElement }) else { return nil }
        return axFrame(child)
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var posVal: AnyObject?
        var sizeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let posVal, let sizeVal,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        let pos = posVal as! AXValue
        let size = sizeVal as! AXValue
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func currentDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Bring the target to the front before synthetic clicking. After navigation, AX can see windows on the active
    /// desktop; using the captured cgWindowId avoids raising a sibling from the same app.
    @discardableResult
    private static func raiseWindow(_ cap: CapturedWindow) -> Bool {
        guard let el = axElement(for: cap) else {
            log.info("raise wid=\(cap.cgWindowId) failed: no AX element for pid=\(cap.pid) bundle=\(cap.bundleId, privacy: .public)")
            return false
        }
        let activated = NSRunningApplication(processIdentifier: pid_t(cap.pid))?.activate() ?? false
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        log.info("raise wid=\(cap.cgWindowId) activated=\(activated) frontmostPid=\(frontmost) targetPid=\(cap.pid)")
        return true
    }

    /// The window's current on-screen frame, by cgWindowId (the grab-leg verify: is its frame valid after nav?).
    private static func onScreenBounds(_ wid: CGWindowID) -> CGRect? {
        for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [] {
            guard (w[kCGWindowNumber as String] as? CGWindowID) == wid,
                  let bd = w[kCGWindowBounds as String],
                  let r = CGRect(dictionaryRepresentation: bd as! CFDictionary) else { continue }
            return r
        }
        return nil
    }

    /// Place the carried window's display + position + size via public AX, reusing Restore's exact size→pos→size.
    /// Match by cgWindowId among the live app's windows (now on the active desktop). pid may have churned, so
    /// resolve the running app by bundleId, not the captured pid.
    @discardableResult
    private static func placeFrame(_ cap: CapturedWindow) -> Bool {
        guard let el = axElement(for: cap) else { return false }
        return Restore.setFrame(el, cap.frame)
    }

    private static func axElement(for cap: CapturedWindow) -> AXUIElement? {
        var apps: [NSRunningApplication] = []
        if let app = NSRunningApplication(processIdentifier: pid_t(cap.pid)) {
            apps.append(app)
        }
        apps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: cap.bundleId)
            .filter { $0.processIdentifier != pid_t(cap.pid) })
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 1.0)   // the #keeps-3/#keeps-6 freeze guard
            var winsVal: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsVal) == .success,
                  let windows = winsVal as? [AXUIElement] else { continue }
            for w in windows where axWindowID(w) == cap.cgWindowId { return w }
        }
        return nil
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
