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
// Two move types compose a carry: a desktop switch (held titlebar through the user's real Space-switch
// binding) moves a window between desktops on the SAME display; an AX frame-set moves it between displays AND
// re-homes it onto the landing display's ACTIVE Space (#keeps-17.2 — the 2026-06-16 lever). So same-display
// targets are held-carried then placed; cross-display targets are AX-placed INTO a pre-navigated target view —
// the placement IS the Space move, no hold involved. A third path, `.placeOnly` (#keeps-22), fixes a drifted
// frame on the window's own Space. Membership verification gates ALL THREE before anything is reported carried
// — including `.placeOnly`, whose "the Space never changes" premise holds only while the place stays on one
// display; a landing that lies is restituted (best-effort) instead of left mis-framed.
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
        /// #keeps-22: the carry has to see the frame, not just the Space. Without it, `plan` skipped every
        /// window already on its target desktop — including ones whose size/position had drifted, which
        /// restore had counted as carry work. `nil` ⇒ unknown ⇒ treated as already-home (fail-safe).
        public let liveFrame: WindowFrame?
        public init(captured: CapturedWindow, currentGlobalDesktop: Int?, liveFrame: WindowFrame? = nil) {
            self.captured = captured
            self.currentGlobalDesktop = currentGlobalDesktop
            self.liveFrame = liveFrame
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
        // #keeps-23: the AX set was ACCEPTED and membership verified, but the window does not hold the
        // captured frame afterwards. Distinct from `axPlaceFailed`, which is the set itself being refused —
        // this is the set succeeding and the window ending up somewhere else anyway, which is the shape that
        // used to be reported as success (Safari's status bar, 2026-07-28 dogfood: `340x20` asked, `151x20` held).
        case frameNotHeld
        case userInterrupt         // physical mouse movement interrupted the run
    }

    public enum CarryAction: Equatable {
        case carry(CapturedWindow, fromGlobal: Int, toGlobal: Int)
        /// #keeps-22: already on its captured Space, but the frame drifted. No Space move — navigate the view
        /// so AX can reach it, then place. Restore can't do this itself: a background-Space window is
        /// unreachable, which is exactly why it lands in the deferred set.
        case placeOnly(CapturedWindow, onGlobal: Int)
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

    /// The skip reasons the carry owns (#keeps-17.3): windows silent restore deferred TO the carry — on a
    /// background Space, blocked by the cross-display Space guard, or visible on a wrong Space (#keeps-13
    /// dogfood). `unprovableSpace` and `offScreenTarget` stay count-only: the carry can't resolve a target
    /// for them either.
    static func isCarryDeferred(_ action: Restore.Action) -> Bool {
        action == .skip(.deferredBackground) || action == .skip(.deferredCrossDisplay)
            || action == .skip(.deferredWrongSpace)
    }

    /// The carry filter, as one pure function over the fresh deferred set + the live topology + the user's
    /// bindings. Order matters: target resolves → current resolves → not already there → both legs navigable.
    /// `tolerance` must track `Restore.decide`'s default — the two classifiers deciding "already home"
    /// differently is precisely the `#keeps-22` defect, so they compare frames the same way or not at all.
    /// It now literally IS that default (`Restore.frameTolerance`) rather than a matching magic number kept
    /// in step by this comment: the cold review pointed out that a warning about drift, guarded only by
    /// convention, is not a guard.
    public static func plan(deferred: [DeferredWindow], spaceIndex: DesktopIndex, shortcuts: Shortcuts,
                            tolerance: Int = Restore.frameTolerance) -> [CarryAction] {
        deferred.map { dw in
            let cap = dw.captured
            if cap.sticky || cap.spaceIds.count != 1 { return .skip(.stickyAllDesktops, cap) }
            guard let uuid = cap.spaceUUID, let to = spaceIndex.globalOrdinal(ofSpaceUUID: uuid) else {
                return .skip(.targetGone, cap)        // captured desktop no longer exists
            }
            guard let from = dw.currentGlobalDesktop else { return .skip(.gone, cap) }   // no live desktop
            if from == to {
                // #keeps-22: same desktop is NOT "already home" — correctness is frame AND Space, the same
                // pair `Restore.decide` uses. Skipping on the Space alone both overstated the offer (restore
                // counted these) and left the frame with no repair path at all: restore can't reach a
                // background window, and the carry walked past it. Unknown live frame ⇒ can't prove drift ⇒ skip.
                guard let lf = dw.liveFrame, !cap.frame.matches(lf, tolerance: tolerance) else {
                    return .skip(.alreadyOnDesktop, cap)
                }
                guard navigable(to, shortcuts) else { return .skip(.unreachableShortcut, cap) }
                return .placeOnly(cap, onGlobal: to)
            }
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
        // #keeps-5: snapshot predates this boot ⇒ every cgWindowId in it is churned. Refused whole, before any
        // window is touched — the carry reaches windows via Restore.classify, NOT Restore.restore, so it needs
        // its own gate rather than inheriting one. Same shape as readFailed/navigationDead: an honest stop.
        public var staleSession: Bool = false
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
        // #keeps-5.4: same story as restore — a prior-session snapshot means the ids need resolving by
        // app+geometry, not that the run is refused. Refusal survives only when nothing resolves at all.
        var remap: [CGWindowID: CGWindowID]? = nil  // nil ⇒ same session, ids are trustworthy
        if !SessionFreshness.isCurrent(snapshot) {
            remap = Restore.coldStartRemap(snapshot, live: live)
            DebugTrace.log("=== carry COLD START — resolved \(remap?.count ?? 0)/\(snapshot.windows.count) windows by app+geometry")
            guard !(remap ?? [:]).isEmpty else {
                return CarryResult(plannedCarries: 0, carried: 0, skips: [:], aborted: false, abortedAfter: 0,
                                   outcomes: [], dryRun: !apply, readFailed: false, navigationDead: false,
                                   staleSession: true)
            }
        }
        let cid = live.cid
        let index = DesktopIndex.live(cid)
        let shortcuts = Shortcuts.live()
        guard shortcuts.canNavigate else {   // both nav mechanisms dead → honest stop, never a silent do-nothing
            return CarryResult(plannedCarries: 0, carried: 0, skips: [:], aborted: false, abortedAfter: 0,
                               outcomes: [], dryRun: !apply, readFailed: false, navigationDead: true)
        }

        // Fresh deferred set (Blocker-1): keep the carry-owned deferrals — background-Space windows AND the
        // #keeps-17 guard's cross-display ones — each paired with its CURRENT live desktop (the int
        // ManagedSpaceID cgsSpacesForWindow returns → global ordinal).
        let deferred: [DeferredWindow] = Restore.classify(snapshot, against: live, remap: remap).compactMap { (cap, action) in
            guard isCarryDeferred(action) else { return nil }
            // #keeps-5.4: substitute the resolved live id INTO the captured record, once, here. The execute
            // path reads `cap.cgWindowId` at ~20 sites (raise, grab, bounds, membership poll, restitution);
            // rewriting the id at construction makes every one of them address the window that actually
            // exists, with no per-site edits to get wrong. Everything else on the record — bundleId, frame,
            // spaceUUID — stays exactly as captured, because those are the TARGET, not the lookup key.
            // Resolve or SKIP — never fall back to the dead id. Same rule, same reason as `matchFor`: a
            // recycled id would hand this carry a stranger's window to grab and drag across Spaces.
            var cap = cap
            if let remap {
                guard let resolved = remap[cap.cgWindowId] else { return nil }
                cap.cgWindowId = resolved
            }
            let currentMid = cgsSpacesForWindow(cid, cap.cgWindowId).first
            return DeferredWindow(captured: cap,
                                  currentGlobalDesktop: currentMid.flatMap { index.globalOrdinal(ofManagedID: $0) },
                                  liveFrame: live.existence.frames[cap.cgWindowId])  // #keeps-22
        }
        let actions = plan(deferred: deferred, spaceIndex: index, shortcuts: shortcuts)
        let total = actions.reduce(0) {   // #keeps-22: a place is work too — it counts toward progress
            switch $1 { case .carry, .placeOnly: return $0 + 1; case .skip: return $0 }
        }
        if DebugTrace.enabled {   // #keeps-15: carry header — the carry's view of the live arrangement (focus-noted)
            DebugTrace.log("=== carry fp=\(snapshot.configFingerprint) apply=\(apply)\(DebugTrace.focusNote) — displays: "
                + DebugTrace.displaysHeader(DebugTrace.activeDisplays()))
        }

        var carried = 0, done = 0, abortedAfter = 0, aborted = false
        var skips: [CarrySkip: Int] = [:]
        var outcomes: [Outcome] = []
        expectedCursor = apply ? cursorLocation() : nil   // #keeps-17 Q3: the unheld-leg interrupt baseline
        for (dw, action) in zip(deferred, actions) {   // 1:1 — plan maps each deferred window to one action
            switch action {
            case .skip(let reason, let cap):
                skips[reason, default: 0] += 1
                // Surface the desktops even for skips: current (from) is known, target (to) resolves from the
                // captured spaceUUID — so a verbose line reads `desktop 5→5 (alreadyOnDesktop)`, not `?→?`.
                let to = cap.spaceUUID.flatMap { index.globalOrdinal(ofSpaceUUID: $0) }
                outcomes.append(Outcome(cap: cap, fromGlobal: dw.currentGlobalDesktop, toGlobal: to, outcome: reason.rawValue))
            case .placeOnly(let cap, let on):
                // #keeps-22: same shape as a carry (progress, dry-run, interrupt boundary) minus the Space
                // move. Counts as carried — from the user's side the window did come home; only the drift
                // being size-not-Space is an implementation detail.
                done += 1
                onProgress(Progress(done: done, total: total, toDesktop: on, bundleId: cap.bundleId))
                guard apply, !aborted else {
                    outcomes.append(Outcome(cap: cap, fromGlobal: on, toGlobal: on,
                                            outcome: apply ? "skipped (aborted)" : "would-place"))
                    continue
                }
                if userMoved() {
                    aborted = true; abortedAfter = carried
                    skips[.userInterrupt, default: 0] += 1
                    outcomes.append(Outcome(cap: cap, fromGlobal: on, toGlobal: on,
                                            outcome: CarrySkip.userInterrupt.rawValue))
                    continue
                }
                switch await executePlaceOnly(cap, onGlobal: on, index: index, shortcuts: shortcuts, cid: cid) {
                case .carried:
                    carried += 1
                    outcomes.append(Outcome(cap: cap, fromGlobal: on, toGlobal: on, outcome: "placed"))
                case .failed(let reason), .aborted(let reason):
                    skips[reason, default: 0] += 1
                    outcomes.append(Outcome(cap: cap, fromGlobal: on, toGlobal: on, outcome: reason.rawValue))
                }
            case .carry(let cap, let from, let to):
                done += 1
                onProgress(Progress(done: done, total: total, toDesktop: to, bundleId: cap.bundleId))
                guard apply, !aborted else {   // dry run lists the plan; after an abort the rest are left untouched
                    outcomes.append(Outcome(cap: cap, fromGlobal: from, toGlobal: to,
                                            outcome: apply ? "skipped (aborted)" : "would-carry"))
                    continue
                }
                if userMoved() {   // #keeps-17 Q3: between-windows boundary sample — real input halts the run
                    aborted = true; abortedAfter = carried
                    skips[.userInterrupt, default: 0] += 1
                    outcomes.append(Outcome(cap: cap, fromGlobal: from, toGlobal: to,
                                            outcome: CarrySkip.userInterrupt.rawValue))
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

    /// `.carried` carries its evidence (#keeps-23, 2nd pass) — see `FrameHeld`. The payload is not read by
    /// the sweep, which only counts; it is here so the case cannot be written without a read-back.
    private enum CarryOutcome { case carried(FrameHeld), failed(CarrySkip), aborted(CarrySkip) }

    /// The hold-leg's result, deliberately NOT `CarryOutcome`. This step proves the VIEW reached the target
    /// desktop with the window held — it says nothing about the frame, and it is consumed mid-function by
    /// `executeCarry` rather than returned to the sweep. Until the fold both shared `.carried`, one case
    /// meaning "the Space switch worked" in one function and "the window is verified home" in three others.
    private enum StepOutcome { case switched, failed(CarrySkip), aborted(CarrySkip) }
    private static let driftThreshold: CGFloat = 12   // px a parked cursor may wander before we call it real input

    /// #keeps-22: the window is already on its captured Space; only its frame drifted. Restore can't repair
    /// that — a background-Space window is unreachable by AX, which is why it was deferred here in the first
    /// place. So: navigate the VIEW to that desktop (making it reachable), raise, place. Deliberately NOT a
    /// carry — no grab, no Space switch, and no membership verification, because the Space never changes.
    private static func executePlaceOnly(_ cap: CapturedWindow, onGlobal: Int, index: DesktopIndex,
                                         shortcuts: Shortcuts, cid: CGSConnectionID) async -> CarryOutcome {
        log.info("place wid=\(cap.cgWindowId) \(cap.bundleId, privacy: .public) on=\(onGlobal) (frame drift, no Space move)")
        guard await navigateView(toGlobal: onGlobal, index: index, shortcuts: shortcuts, cid: cid) else {
            log.info("place wid=\(cap.cgWindowId) FAILED nav: couldn't reach \(onGlobal)")
            return .failed(.unreachableShortcut)
        }
        _ = raiseWindow(cap)
        try? await Task.sleep(for: .milliseconds(350))
        guard let preBounds = onScreenBounds(cap.cgWindowId) else {
            log.info("place wid=\(cap.cgWindowId) FAILED: not on screen after nav to \(onGlobal)")
            return .failed(.gone)
        }
        guard placeFrame(cap) else {
            log.info("place wid=\(cap.cgWindowId) axPlaced=false → axPlaceFailed")
            return .failed(.axPlaceFailed)
        }
        // "The Space never changes" holds only SAME-DISPLAY. An AX frame-set that lands the window on a
        // DIFFERENT display re-homes it onto that display's active Space — the exact lever
        // `carryAcrossDisplays` uses on purpose. `Restore.decide` refuses precisely this place and defers it
        // here, so without a check this path would perform the move decide refused, then report it "brought
        // back": a silent wrong-Space landing, the #keeps-17 invariant inverted, and the header claim above
        // ("membership verification gates BOTH paths") made false by a third, unguarded path.
        // Enforced, not predicted — same settle + poll + best-effort restitution as the cross-display carry.
        try? await Task.sleep(for: .milliseconds(500))  // membership settles after any re-home
        let landedOn = await pollWindowGlobal(cap.cgWindowId, targetGlobal: onGlobal, index: index, cid: cid)
        guard landedOn == onGlobal else {
            let note = restituteFrame(cap, to: preBounds) ? "restituted" : "restitutionFailed"
            let landedNote = landedOn.map(String.init) ?? "?"
            log.info(
                "place wid=\(cap.cgWindowId) MOVED SPACE \(onGlobal)→\(landedNote); \(note) → membershipMismatch")
            return .failed(.membershipMismatch)
        }
        // #keeps-23: membership is verified, but this path exists SOLELY to fix a drifted frame (#keeps-22) —
        // so the frame is the whole deliverable, and reporting success without reading it back is reporting
        // success about the one thing never checked. Restitution is deliberately NOT attempted here: unlike
        // the wrong-Space case above, the window is on its OWN Space — the Space was never the problem.
        // Undoing to `preBounds` would trade a possibly-partial success for a certain one, and on the two
        // carry paths it would discard a good Space move to fix a size.
        //
        // What this does NOT claim is which HALF of the frame failed. `posOK` means AX ACCEPTED the position
        // write, and "accepted ≠ held" is this slice's whole premise — so it cannot prove the window reached
        // the captured position and merely clamped its size. `placeHeld.seen` is the only thing that could
        // say; the log line prints it, and nothing acts on it. See #keeps-29.
        return await verifyPlacement(
            cap, "place wid=\(cap.cgWindowId) on=\(onGlobal) axPlaced=true membershipVerified", verb: "PLACED")
    }

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

        // #keeps-17.2: a desktop switch moves a window on ONE display; a cross-display target takes the
        // AX-place re-home path instead — branch BEFORE grabbing so the grip machinery stays out of it.
        guard let to, let from, to.displayIndex == from.displayIndex else {
            return await carryAcrossDisplays(cap, toGlobal: toGlobal, index: index, shortcuts: shortcuts,
                                             cid: cid, preBounds: bounds)
        }

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

        // 3) place-leg — carry the HELD window to its target desktop (same display; the plan never emits
        // from == to). A real mouse-move drifts the parked cursor mid-carry ⇒ abort + release.
        if to.perDisplayIndex != from.perDisplayIndex {
            log.info("carry wid=\(cap.cgWindowId) held titlebar — place-leg stepping \(from.perDisplayIndex)→\(to.perDisplayIndex) on disp \(from.displayIndex)")
            switch await carryHeld(displayIndex: from.displayIndex, toIndex: to.perDisplayIndex,
                                   fromIndex: from.perDisplayIndex, toGlobal: toGlobal,
                                   shortcuts: shortcuts, cid: cid, parked: &parked) {
            case .switched:
                break
            case .failed(let reason):
                log.info("carry wid=\(cap.cgWindowId) FAILED place-leg: \(reason.rawValue, privacy: .public)")
                return .failed(reason)
            case .aborted(let reason):
                log.info("carry wid=\(cap.cgWindowId) ABORTED (cursor drift)")
                return .aborted(reason)   // defer releases the drag at the parked point
            }
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
        // #keeps-23: same-display carry — the Space move landed and the AX set was accepted, but neither
        // proves the window holds the captured frame. Verify it before this counts as carried.
        return await verifyPlacement(
            cap, "carry wid=\(cap.cgWindowId) landedOn=\(landedOn ?? -1) target=\(toGlobal) axPlaced=true",
            verb: "CARRIED")
    }

    /// #keeps-17.2 — the cross-display carry: point the TARGET display's view at the captured Space
    /// (`navigateView`, unheld), then AX-place the window — the placement IS the Space move, because macOS
    /// re-homes a cross-display AX move onto the landing display's ACTIVE Space (the 2026-06-16 lever, banked).
    /// Membership is verified before anything is reported carried; a landing that lies is restituted to the
    /// pre-carry frame (best-effort, Q4) so a failed carry leaves no visible damage. The user's brake is the
    /// Q3 boundary sample: real cursor movement since our last synthetic park aborts before the AX-place.
    private static func carryAcrossDisplays(_ cap: CapturedWindow, toGlobal: Int, index: DesktopIndex,
                                            shortcuts: Shortcuts, cid: CGSConnectionID,
                                            preBounds: CGRect) async -> CarryOutcome {
        // place-leg (unheld) — switch the target display's view to the captured Space.
        guard await navigateView(toGlobal: toGlobal, index: index, shortcuts: shortcuts, cid: cid) else {
            log.info("carry wid=\(cap.cgWindowId) FAILED cross-display place-leg: couldn't reach to=\(toGlobal)")
            return .failed(.spaceSwitchFailed)
        }
        try? await Task.sleep(for: .milliseconds(300))   // let the switch settle before the move
        if userMoved() {   // Q3: the boundary brake before the irreversible action
            log.info("carry wid=\(cap.cgWindowId) ABORTED (real input before cross-display place)")
            return .aborted(.userInterrupt)
        }
        // the move — AX-place at the captured frame; WindowServer re-homes onto the target display's active
        // Space, which navigateView just made the captured one.
        guard placeFrame(cap) else {
            log.info("carry wid=\(cap.cgWindowId) cross-display axPlaced=false → axPlaceFailed")
            return .failed(.axPlaceFailed)
        }
        try? await Task.sleep(for: .milliseconds(500))   // membership settles after the re-home
        let landedOn = await pollWindowGlobal(cap.cgWindowId, targetGlobal: toGlobal, index: index, cid: cid)
        let carried = landedOn == toGlobal
        var restitutionNote = ""
        if !carried {
            // restitute best-effort (Q4): put the frame back where the window was; the outcome stays specific.
            let restituted = restituteFrame(cap, to: preBounds)
            restitutionNote = restituted ? "; restituted" : "; restitutionFailed"
        }
        if DebugTrace.enabled && DebugTrace.traces(bundleId: cap.bundleId, title: cap.title) {
            let displays = DebugTrace.activeDisplays()
            let after = onScreenBounds(cap.cgWindowId).map {
                WindowFrame(x: Int($0.minX), y: Int($0.minY), w: Int($0.width), h: Int($0.height))
            }
            DebugTrace.log(DebugTrace.windowLine(
                bundleId: cap.bundleId, title: cap.title, wid: cap.cgWindowId,
                decision: "carry→crossDisplay \(carried ? "ok" : "FAILED(membership\(restitutionNote))") (desktop \(toGlobal), landed=\(landedOn ?? -1))",
                desired: cap.frame,
                before: WindowFrame(x: Int(preBounds.minX), y: Int(preBounds.minY),
                                    w: Int(preBounds.width), h: Int(preBounds.height)),
                after: after, displays: displays))
        }
        guard carried else {
            log.info("carry wid=\(cap.cgWindowId) cross-display landedOn=\(landedOn ?? -1) target=\(toGlobal) → membershipMismatch\(restitutionNote, privacy: .public)")
            return .failed(.membershipMismatch)
        }
        // #keeps-23, third place path. The header claims membership verification gates every path; the frame
        // now does too. This one is covered deliberately rather than "because it looked similar" — the
        // repeated lesson on this codebase (#keeps-5, twice) is that a claim traced down one path of several
        // reads as proven and isn't. Restitution is skipped as in `executePlaceOnly`, with one caveat that
        // path doesn't carry: membership was polled BEFORE this frame read, so on `frameNotHeld` here the
        // Space is LAST-KNOWN, not known — a drift big enough to return the window to the origin display
        // would have re-homed it. The count stays honest either way (not counted carried); it's the Space
        // claim that's stale. Re-polling membership on this branch belongs to #keeps-26, which owns the
        // cross-display path.
        return await verifyPlacement(
            cap, "carry wid=\(cap.cgWindowId) cross-display landedOn=\(toGlobal)", verb: "CARRIED")
    }

    /// Best-effort frame restitution after a failed cross-display landing — the same public-AX write, aimed back.
    private static func restituteFrame(_ cap: CapturedWindow, to bounds: CGRect) -> Bool {
        guard let el = axElement(for: cap) else { return false }
        return Restore.setFrame(el, WindowFrame(x: Int(bounds.minX), y: Int(bounds.minY),
                                                w: Int(bounds.width), h: Int(bounds.height)))
    }

    /// Carry a HELD window across desktops on its current display: one global ⌥⌘N jump if the target is directly
    /// bound (proven single-jump, #keeps-6), else step desktop-by-desktop (proven multi-step, D2). The window is
    /// held without any drag/nudge; membership verification after release proves whether the hold carried.
    /// Cursor drift still aborts; `.aborted` ⇒ the caller drops + halts.
    private static func carryHeld(displayIndex: Int, toIndex: Int, fromIndex: Int, toGlobal: Int,
                                  shortcuts: Shortcuts, cid: CGSConnectionID,
                                  parked: inout CGPoint) async -> StepOutcome {
        if let jump = shortcuts.switchTo(toGlobal) {
            postKeyChord(jump.keyCode, flags: jump.flags)
            let switched = await poll(displayIdx: displayIndex, until: { $0 == toIndex }, cid: cid, timeout: 2.5)
            if !switched { return .failed(.spaceSwitchFailed) }
            try? await Task.sleep(for: .milliseconds(300))
            if drifted(from: parked) { return .aborted(.userInterrupt) }
            try? await Task.sleep(for: .milliseconds(300))
            return .switched
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
        return cur == toIndex ? .switched : .failed(.spaceSwitchFailed)
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
        parkCursor(to: CGPoint(x: CGDisplayBounds(did).midX, y: CGDisplayBounds(did).midY))
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

    // #keeps-17 Q3: the interrupt contract on UNHELD legs. The held path measures drift against its parked
    // hold point; the cross-display path holds nothing, so the brake is boundary sampling — remember where
    // OUR last synthetic move left the cursor (or where the run found it) and treat further movement as the
    // user's. Sampled between windows and before each irreversible AX-place, never mid-keystroke.
    private static var expectedCursor: CGPoint?

    /// Synthetic cursor move that keeps the interrupt reference honest — every carry-path `moveCursor` goes
    /// through here so `userMoved()` only ever fires on REAL input.
    private static func parkCursor(to p: CGPoint) {
        moveCursor(to: p)
        expectedCursor = p
    }

    /// Has the cursor moved beyond the drift threshold since we last placed (or observed) it?
    private static func userMoved() -> Bool {
        guard let expected = expectedCursor, let cur = cursorLocation() else { return false }
        return hypot(cur.x - expected.x, cur.y - expected.y) > driftThreshold
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
        parkCursor(to: p)
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
        // #keeps-5.4: activate the app that OWNS THE ELEMENT we are about to raise, never `cap.pid`. A
        // captured pid is session-scoped like the window id — after a reboot it belongs to some unrelated
        // process, so activating it would steal focus to an arbitrary app mid-carry and make `targetPid=` a
        // lie in the log. Asking the element removes the possibility of the two disagreeing at all.
        var livePid: pid_t = 0
        let activated =
            AXUIElementGetPid(el, &livePid) == .success
            ? (NSRunningApplication(processIdentifier: livePid)?.activate() ?? false)
            : false
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        log.info("raise wid=\(cap.cgWindowId) activated=\(activated) frontmostPid=\(frontmost) targetPid=\(livePid)")
        return true
    }

    /// #keeps-23 — did the window actually TAKE the frame we set? Every place path **in this file** used to
    /// report success on the strength of the AX set returning `.success` plus Space membership landing;
    /// neither says anything about where the window ended up. Safari's link-preview strip proved the gap live
    /// (2026-07-28): asked for `340x20`, logged `axPlaced=true membershipVerified → PLACED`, held `151x20`.
    ///
    /// SCOPE, stated because the first draft of this comment did not (cold review, finding 2): "every place
    /// path" means the carry's three. `Restore.restore`'s own apply path counts `applied += 1` on
    /// `setFrame`'s `posOK` alone and has NO read-back, so a reachable window whose app clamps its size is
    /// still counted restored there, every run. That gap is real, is NOT closed by this change, and is
    /// tracked as `#keeps-28` — it needs its own slice because `Restore.restore` runs synchronously on the
    /// main thread (`main.swift:462`), so a per-window polled read-back would freeze the menu bar for
    /// seconds across a full layout. An unenumerated path left unnamed is this repo's most-repeated mistake;
    /// naming it here is the minimum, not the fix.
    ///
    /// The bar is `WindowFrame.matches(tolerance:)` — position AND size, the same predicate `Restore.decide`
    /// uses for `alreadyCorrect`. That is deliberate and it overrules `Restore.setFrame`'s "size is
    /// best-effort" doc: if `decide` calls a window within ±2 already home, a place landing outside ±2 has
    /// not brought it home, and one standard has to mean one thing. Position-only was not an option — the
    /// Safari case drifted in width at an identical position, so it would have passed.
    ///
    /// POLLED, not read once, for the same reason `#keeps-17`'s membership check had to be (Tom hit that live,
    /// 2026-07-06): an AX set lands asynchronously, and an immediate read races it and fails a place that
    /// actually worked. Reads back through `onScreenBounds` — CGWindowList bounds, the same coordinate source
    /// capture used, which `WindowFrame.matches` requires of both sides or the compare is meaningless.
    /// Returns the last frame seen so the caller can log what it got, not merely that it disagreed.
    /// WHAT THIS PROVES, exactly: the window matched its captured frame on two consecutive reads one poll
    /// interval apart. Not that it will KEEP it — "held" is a claim about the future and no finite
    /// observation can establish it, because the owning app may re-lay-out later for reasons we cannot see.
    ///
    /// TWO CONSECUTIVE, not first-match-wins (second-model review, 2026-07-29). The previous version returned
    /// the instant a read matched, which made it structurally OPTIMISTIC: it stopped looking the moment it
    /// saw what it wanted. An app that accepts the frame and then clamps it a moment later — the `#keeps-6`
    /// move-on-resize class this whole slice exists to catch — matched at t≈0 and was counted carried while
    /// holding a size it never accepted. The fix deliberately introduces NO new constant: it reuses the 150ms
    /// tick already here, so there is one budget to reason about rather than two magic numbers.
    ///
    /// It rounds toward FALSE NEGATIVE on purpose. The two error directions are not symmetric — reporting
    /// "brought back" for a window that isn't destroys the only thing this feature sells, while under-counting
    /// a window that did come home is merely modest. When the observation is ambiguous, be modest.
    ///
    /// A provisional match always earns its confirming read even past the budget (bounded: one extra
    /// interval), so a window that settles at the very end is not failed on a technicality — that would
    /// re-introduce the sign-flipped defect the first cold review caught here.
    ///
    /// THE PROOF IS THE TYPE (#keeps-23, 2nd engineering pass). Three call sites each hand-maintained their
    /// own place-then-verify pair, and correctness rested on all three remembering. `init` here is `private`,
    /// so — Swift scoping `private` to the enclosing *declaration*, which is this struct and not `Carry` —
    /// nothing outside can build a `FrameHeld`; `verify` is the only thing that does, and it polls the real
    /// window to do it. Since `CarryOutcome.carried` now carries one, **a place path cannot report success
    /// without a read-back: it does not compile.** That is the whole point of the fold. Sharing a helper
    /// would have made the three paths consistent and left a fourth free to skip it — which is exactly what
    /// this codebase keeps doing (#keeps-5 twice, #keeps-23 once), each time caught by a reviewer rather than
    /// by the code. Vigilance was the control; construction is the control now.
    ///
    /// WHAT THE SEAL DOES NOT COVER, stated because an unstated scope is how the last three got through:
    /// it makes success-without-a-read-back unrepresentable, not success-with-the-wrong-window's-read-back.
    /// A path holding a `FrameHeld` obtained for a different window could still pass it along. Nothing does
    /// — so KEEP `verifyPlacement` the proof's only consumer, obtaining and spending it in one expression.
    /// (Stated as the contract to hold, not as a fact about today's arrangement: a comment claiming "X is the
    /// only path that…" goes stale the moment someone adds a second, and four of six findings in the
    /// 2026-07-29 second-model review were exactly that shape.) Closing this too would mean carrying the
    /// `cgWindowId` in the proof and checking it, which buys nothing while the contract holds. The claim is
    /// bounded on purpose: "cannot skip the read", not "cannot be fooled".
    ///
    /// Verified, not assumed (2026-07-29): a deliberate probe adding `return .carried(FrameHeld(seen:…))` to
    /// `executePlaceOnly` — a fourth path faking success — failed to compile with
    /// "'Carry.FrameHeld' initializer is inaccessible due to 'private' protection level", then was removed.
    private struct FrameHeld {
        /// The frame actually observed on the confirming read — a real one, never "nothing on screen": a
        /// window that vanished cannot match, so it cannot reach this initializer.
        let seen: WindowFrame
        /// Elapsed ms of the FIRST of the two matching reads. It exists to be logged: a success that prints
        /// no observation cannot be checked by anyone, which is how the optimism above survived a review and
        /// a human verify. If real matches cluster at 0ms this gap is wide open; if they cluster at
        /// 300-600ms it was mostly theoretical. Run 1 (2026-07-29) read 0ms on all seven successes.
        let matchedAtMillis: Int

        private init(seen: WindowFrame, matchedAtMillis: Int) {
            self.seen = seen
            self.matchedAtMillis = matchedAtMillis
        }

        /// The sole way to obtain a `FrameHeld` — poll until two consecutive reads match, or give up.
        /// Returns the last frame observed either way, so a caller can log what it actually got on a miss
        /// without paying a second read.
        static func verify(
            _ cap: CapturedWindow, tolerance: Int = Restore.frameTolerance, timeout: Double = 1.2
        ) async -> (held: FrameHeld?, lastSeen: WindowFrame?) {
            func read() -> WindowFrame? {
                Carry.onScreenBounds(cap.cgWindowId).map {
                    WindowFrame(x: Int($0.minX), y: Int($0.minY), w: Int($0.width), h: Int($0.height))
                }
            }
            var seen: WindowFrame?
            var firstMatchAt: Double?
            var waited = 0.0
            while true {
                seen = read()
                if let now = seen, cap.frame.matches(now, tolerance: tolerance) {
                    if let first = firstMatchAt {   // confirmed — two in a row, one interval apart
                        return (FrameHeld(seen: now, matchedAtMillis: Int(first * 1000)), now)
                    }
                    firstMatchAt = waited  // provisional — confirm it on the next tick
                } else {
                    firstMatchAt = nil  // drifted (or vanished): any streak is broken
                }
                if waited >= timeout, firstMatchAt == nil { break }
                try? await Task.sleep(for: .milliseconds(150))
                waited += 0.15
            }
            return (nil, seen)
        }
    }

    /// The ONE tail every place path ends on. `prefix` is the path's own context (which window, which
    /// desktop, what it already verified); the verdict half is written here so all three report identically
    /// and a fourth path gets the same line for free. Success is only constructible here — see `FrameHeld`.
    private static func verifyPlacement(_ cap: CapturedWindow, _ prefix: String,
                                        verb: String) async -> CarryOutcome {
        let (held, lastSeen) = await FrameHeld.verify(cap)
        guard let held else {
            log.info(
                "\(prefix, privacy: .public) but frame drifted back: \(Carry.frameNote(cap, lastSeen), privacy: .public) → frameNotHeld")
            return .failed(.frameNotHeld)
        }
        log.info(
            "\(prefix, privacy: .public) frameVerified \(Carry.heldNote(held), privacy: .public) → \(verb, privacy: .public)")
        return .carried(held)
    }

    /// What a verified place actually observed, for the success log line — see `FrameHeld`'s note on why a
    /// success that prints nothing is unfalsifiable. Mirrors `frameNote`, which does the same for failures.
    /// It takes the proof rather than optionals, so the old "nothing on screen"/"?ms" fallbacks are gone:
    /// they were representable but unreachable, and a success line can no longer claim it saw nothing.
    private static func heldNote(_ held: FrameHeld) -> String {
        "holds \(held.seen.w)×\(held.seen.h) at (\(held.seen.x),\(held.seen.y)), matchedAt \(held.matchedAtMillis)ms"
    }

    /// One-line "wanted X, saw Y" for the frame-verify log lines — so a `frameNotHeld` says what happened.
    private static func frameNote(_ cap: CapturedWindow, _ seen: WindowFrame?) -> String {
        let want = "\(cap.frame.w)×\(cap.frame.h) at (\(cap.frame.x),\(cap.frame.y))"
        let got = seen.map { "\($0.w)×\($0.h) at (\($0.x),\($0.y))" } ?? "nothing on screen"
        return "wanted \(want), holds \(got)"
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
