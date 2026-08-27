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
    // #keeps-17: the Space-safety guard. `deferred*` = the carry owns it now; the other two are count-only.
    case deferredCrossDisplay  // placing would cross displays onto a Space that isn't the window's captured one
    case offScreenTarget  // the desired frame resolves to no live display — placing lands unpredictably (#keeps-15 owns the repair)
    case unprovableSpace  // cross-display but no captured spaceUUID — can't prove Space safety, and the carry has no target
    case deferredWrongSpace  // reachable but sitting on the wrong Space — silent AX can't move it there; same-display carry work (#keeps-13 dogfood)
    // #keeps-5: a live window holds this id, but it belongs to a different app than the one captured. NOT
    // carry work — the carry can't fix an identity problem either, so this must never reach the offer count.
    case identityMismatch
  }

  enum Action: Equatable {
    // set the window to this captured frame (display + position + size). `verifySpace` is the #keeps-17
    // enforcement order: a cross-display place re-homes the window, so the sweep must read membership after
    // the AX-set and restitute if it didn't land on the window's own Space (sticky/same-display never verify).
    case place(WindowFrame, verifySpace: Bool)
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
    // #keeps-17 guard facts, resolved against LIVE geometry (matchFor computes them; tests set them directly).
    var currentDisplay: String? = nil  // live display under the window's current frame center (nil ⇒ unknown)
    var landingDisplay: String? = nil  // live display under the DESIRED frame center — where an AX-set would actually land; nil ⇒ off-screen
    var landingActiveSpace: String? = nil  // the landing display's active Space uuid (nil ⇒ unknown — treated as unprovable)
    var currentSpace: String? = nil  // the window's own current Space uuid (#keeps-15 slice 2 — background idempotence); nil ⇒ unknown
    // #keeps-5: does the live window's owning app still match the captured one? Defaults true so every
    // existing test fixture keeps meaning what it meant — this guard adds a rejection, it re-classifies nothing.
    var identityOK: Bool = true

    /// A live window exists under this id, but it belongs to someone else. Every other field is deliberately
    /// inert — `decide` rejects on `identityOK` before reading any of them.
    static let impostor = Match(
      reachable: false, minimized: false, liveSpaceCount: 0, liveFrame: nil, identityOK: false)
  }

  /// The px slack at which two frames are "the same window position" — the ONE definition.
  ///
  /// THE RULE, which is the part to preserve: every `tolerance` parameter in this codebase defaults to THIS
  /// constant. One carrying its own literal is a fork, and a fork lets two classifiers disagree about the
  /// same window — which IS the #keeps-22 defect, as `Carry.plan`'s own comment warns.
  ///
  /// Stated as a rule rather than a census, because a census rots. Worth knowing that the constant was
  /// introduced by the first cold review (2026-07-28) and was ITSELF forked: it missed `classify` and
  /// `restore` — the two on the production call path, where the literals then WON because every call site
  /// omits the argument. So it reached only `Carry`, and raising it would have moved the carry's bar while
  /// restore stayed at 2: the drift it exists to prevent, wearing its cure. Two second-model reviewers found
  /// that independently, 2026-07-29.
  ///
  /// The parameters deliberately SURVIVE rather than being deleted as dead surface. A knob carrying its own
  /// literal is a fork; the same knob defaulting to this constant is a seam — and the seam is what makes the
  /// invariant testable (`CountHonestyTests.bothClassifiersAgreeAtAnyTolerance`). That test is the guard;
  /// this constant only makes the defaults honest.
  public static let frameTolerance = 2

  /// The restore filter, as one pure function. Order matters: cheapest/most-decisive rejects first.
  /// ±tolerance on `alreadyCorrect` defeats 1px rounding thrash (Q6).
  static func decide(_ cap: CapturedWindow, match: Match?, tolerance: Int = Restore.frameTolerance)
    -> Action
  {
    guard let m = match else { return .skip(.gone) }  // no live window in .optionAll at all
    // #keeps-5: identity outranks every other verdict. A window we can't prove is the one we captured must not
    // be placed, deferred, or counted as carry work — deferring it is what fed an impostor to the carry, where
    // the grab is geometric and the membership check would have called the move a success.
    guard m.identityOK else { return .skip(.identityMismatch) }
    if m.minimized || m.liveSpaceCount == 0 { return .skip(.minimized) }  // 0-space = minimized/junk, NOT background (M1)
    guard m.reachable else {
      // #keeps-15 slice 2 (shipped early, v0.6.0): a background window that is already fully home — frame at
      // its captured spot AND on its captured Space (macOS preserves membership across reconfigs) — is
      // alreadyCorrect, not carry work. Without this every settled background window inflates the deferred
      // count and the MVP offer lies ("Bring back 49" when the true number is 1 — Tom's 2026-07-06 dogfood).
      // nil currentSpace ⇒ can't prove home ⇒ defer as before (fail-safe).
      // `liveSpaceCount == 1` is load-bearing, not belt-and-braces: `currentSpace` is derived from
      // `spaces.first`, and cgsSpacesForWindow over-reports some apps (Safari) with several Spaces in an
      // order we don't control. On a >1 read, `first` is an arbitrary member — so a window sitting AWAY from
      // home whose list happens to lead with home would be proven "already correct" and silently dropped from
      // the offer, and the opposite ordering would defer the identical state. That flicker is the same
      // count-dishonesty this slice exists to remove. One Space is the only reading that actually proves home.
      if !cap.sticky, m.liveSpaceCount == 1, let lf = m.liveFrame,
        cap.frame.matches(lf, tolerance: tolerance),
        let home = cap.spaceUUID, m.currentSpace == home
      {
        return .skip(.alreadyCorrect)
      }
      return .skip(cap.sticky ? .sticky : .deferredBackground)  // can't reach: #keeps-12, or all-spaces we can't touch
    }
    // Reachable on an active desktop. Correctness is frame AND Space (#keeps-13 dogfood, 2026-07-07: a window
    // hand-moved to another Space keeps its frame — frame-only idempotence called it "correct" and the offer
    // never saw it). Space facts fail safe: unknown home/current ⇒ frame-only, the pre-#keeps-17 behavior.
    // Sticky windows have no single home Space — frame-only for them too (the #keeps-6 over-report lesson:
    // sticky must never block frame work, dogfeel 2026-06-13).
    let spaceOK =
      cap.sticky || cap.spaceUUID == nil || m.currentSpace == nil
      || m.currentSpace == cap.spaceUUID
    if let lf = m.liveFrame, cap.frame.matches(lf, tolerance: tolerance) {
      return spaceOK ? .skip(.alreadyCorrect) : .skip(.deferredWrongSpace)
    }
    if !spaceOK {
      // Frame AND Space wrong — the carry fixes both (it AX-places after the verified landing).
      return .skip(.deferredWrongSpace)
    }
    // #keeps-17: a silent place must never change the window's Space. Placing at coords no live display owns
    // lands wherever macOS clamps it — refuse (the repair is #keeps-15's display-relative model, not ours).
    guard let landing = m.landingDisplay else { return .skip(.offScreenTarget) }
    // Crossing displays re-homes the window onto the landing display's ACTIVE Space (the 2026-06-16 lever) —
    // allowed only when that active Space IS the window's own captured Space, and verified after the set.
    // Sticky (all-desktops) membership can't be damaged, so sticky windows place unguarded, unverified.
    if !cap.sticky, m.currentDisplay == nil || m.currentDisplay != landing {
      guard let home = cap.spaceUUID else { return .skip(.unprovableSpace) }
      guard m.landingActiveSpace == home else { return .skip(.deferredCrossDisplay) }
      return .place(cap.frame, verifySpace: true)
    }
    return .place(cap.frame, verifySpace: false)
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
    let desktopIndex: DesktopIndex  // #keeps-17: managedID→uuid for verify-after-place
    let topology: Topology  // #keeps-17: the guard's landing-display + active-Space facts
  }

  /// The live display topology the #keeps-17 guard classifies against: each display's bounds (which display
  /// a frame would actually land on — the same center rule the trace's `displayOf` uses) and its active Space
  /// uuid (the Space a cross-display AX move re-homes onto). Pure once built; one I/O read per sweep.
  struct Topology: Equatable {
    struct Display: Equatable {
      let uuid: String
      let bounds: CGRect
      let activeSpaceUUID: String?  // nil ⇒ unknown — decide treats a cross-display landing there as unprovable
    }
    let displays: [Display]

    /// The display whose bounds contain the frame's center; nil ⇒ no live display owns it (an off-screen target).
    func displayContaining(_ f: WindowFrame) -> Display? {
      let c = CGPoint(x: Double(f.x) + Double(f.w) / 2, y: Double(f.y) + Double(f.h) / 2)
      return displays.first { $0.bounds.contains(c) }
    }

    /// Read the live topology: CG display bounds joined to the CGS per-display active Space by display UUID
    /// (CGS "Display Identifier" == the CFUUID string ConfigIdentity derives — the same join `Carry`'s
    /// `displayID(forIdentifier:)` relies on).
    static func live(index: DesktopIndex) -> Topology {
      var count: UInt32 = 0
      CGGetActiveDisplayList(0, nil, &count)
      var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
      CGGetActiveDisplayList(count, &ids, &count)
      let displays: [Display] = ids.prefix(Int(count)).compactMap { id in
        guard let uuid = ConfigIdentity.uuid(id) else { return nil }
        let active = index.displays.first { $0.identifier == uuid }
          .flatMap { d in d.currentIndex.map { d.spaces.indices.contains($0) ? d.spaces[$0].uuid : "" } }
        return Display(
          uuid: uuid, bounds: CGDisplayBounds(id),
          activeSpaceUUID: (active?.isEmpty == false) ? active : nil)
      }
      return Topology(displays: displays)
    }
  }

  /// Read the live window state `decide` classifies against. One AX sweep + one CGWindowList read + one
  /// topology read; `nil` on a failed SkyLight load (cid == 0) so callers can surface `readFailed` instead
  /// of acting on nothing (M4).
  static func gatherLiveState() -> LiveState? {
    let cid = cgsMainConnection()
    guard cid != 0 else { return nil }
    let index = DesktopIndex.live(cid)
    return LiveState(
      cid: cid, reachable: reachableWindows(), existence: enumerateExistence(),
      desktopIndex: index, topology: Topology.live(index: index))
  }

  /// Classify every captured window against live state — each paired with its `Action`. The seam #keeps-12's
  /// carry re-runs at trigger time, then filters for `.skip(.deferredBackground)` to get its carry set.
  /// `remap` is #keeps-5.4's cold-start substitution: captured `cgWindowId` → the live id standing in for it.
  /// Empty in the normal same-session case, so this is the identity function and nothing about the existing
  /// truth table changes. One substitution point is deliberately the WHOLE integration — every rule below
  /// (reachability, Space guards, idempotence, the identity guard) then applies unmodified to a cold start.
  /// `remap` is `nil` for a same-session run (ids are trustworthy, use them directly) and NON-NIL for a cold
  /// start, where a captured id is dead and the map is the ONLY way to resolve it. That distinction is a
  /// type, not a convention, because the first version used an empty dictionary and fell back to
  /// `remap[id] ?? id` — which in a cold start hands an unresolved window its DEAD id, and ids recycle from
  /// low numbers after a reboot, so that id routinely belongs to a live stranger. It also let one live window
  /// be claimed twice: once legitimately through the map, once through a colliding fallback. Both wrong-window
  /// mutations, on the exact path this feature exists to make safe. A miss must be `gone`, and now cannot be
  /// anything else.
  static func classify(
    _ snapshot: Snapshot, against live: LiveState, tolerance: Int = Restore.frameTolerance,
    remap: [CGWindowID: CGWindowID]? = nil
  ) -> [(CapturedWindow, Action)] {
    snapshot.windows.map { cap in
      (cap, decide(cap, match: matchFor(cap, live: live, remap: remap), tolerance: tolerance))
    }
  }

  /// The live ids for a cold start, lifted out of `LiveState` so `ColdStartMatch` stays pure.
  static func coldStartRemap(_ snapshot: Snapshot, live: LiveState) -> [CGWindowID: CGWindowID] {
    // The candidate set must be exactly "windows CAPTURE would have stored" — mirroring `Capture.decide`'s
    // filter chain, not approximating it. The first build filtered on nothing but ownership and matched real
    // windows to 1×1 utility windows and 1800×39 chrome, which then classified `minimized` and starved the
    // real windows of their slots: 26 of 29 came back that way on the live fleet.
    //
    // Same four guards as `Capture.decide`, in the same order: attributable owner → normal layer →
    // non-degenerate frame → occupies at least one Space. The Space read is the only costly one and runs on
    // the cold-start path only, over candidates rather than over every window in the system.
    let liveWindows = live.existence.normalLayer.compactMap { id -> ColdStartMatch.LiveWindow? in
      guard let identity = live.existence.owners[id] else { return nil }  // unattributable ⇒ never a match
      let frame = live.existence.frames[id]
      guard
        ColdStartMatch.isCandidate(
          normalLayer: true,  // this set is already layer-filtered; passed explicitly so the gate is one rule
          frame: frame,
          hasSpace: !cgsSpacesForWindow(live.cid, id).isEmpty)
      else { return nil }
      return ColdStartMatch.LiveWindow(id: id, identity: identity, frame: frame)
    }
    let assignment = ColdStartMatch.assign(captured: snapshot.windows, live: liveWindows)
    // #keeps-31: say how each pairing was earned, so a run's guesses can be read without the code. `size` is
    // the only true guess (same size, moved); a climbing `gone` for running apps is the number to watch.
    DebugTrace.log(
      "=== cold-start candidates: \(liveWindows.count) live windows survive capture's filter "
        + "(of \(live.existence.normalLayer.count) normal-layer, \(live.existence.ids.count) total); "
        + "resolved \(assignment.count)/\(snapshot.windows.count) by tier: exact \(assignment.exact), "
        + "position \(assignment.position), size \(assignment.size)")
    return assignment.map
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
    // #keeps-5: the snapshot predates this boot (or boot time was unreadable), so every cgWindowId in it is
    // churned. The WHOLE run is refused before any window is touched — after a reboot every id is dead, so
    // skipping them one at a time would report 38 individual mismatches and never state the one real cause.
    // The host raises a standing condition off this; a silent refusal would be the very defect #keeps-20 fixed.
    public var staleSession: Bool = false
    // #keeps-5.4: this run resolved its windows by app+geometry rather than by id, because the snapshot
    // predates the boot. Surfaced so the status line can SAY so — a best-effort restore must not read
    // identically to one that matched exactly, or the user learns the wrong thing about what keeps knows.
    public var coldStart: Bool = false
    public var coldStartMatched: Int = 0
    public var deferredBackground: Int { skips[.deferredBackground] ?? 0 }  // the #keeps-12 handoff size
    /// The carry-owned deferrals — background-Space windows, the #keeps-17 guard's cross-display ones, and
    /// visible windows sitting on a wrong Space. The MVP offer's honest count (#keeps-17.3): everything a
    /// tap can actually bring home, nothing more.
    public var carryDeferred: Int {
      (skips[.deferredBackground] ?? 0) + (skips[.deferredCrossDisplay] ?? 0)
        + (skips[.deferredWrongSpace] ?? 0)
    }
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
  public static func restore(
    _ snapshot: Snapshot, apply: Bool, tolerance: Int = Restore.frameTolerance
  ) -> Result {
    guard let live = gatherLiveState() else {  // SkyLight load failed → act on nothing (M4)
      return Result(
        planned: 0, applied: 0, failures: 0, skips: [:], outcomes: [], dryRun: !apply,
        readFailed: true)
    }
    // #keeps-5.4: a prior-session snapshot no longer means "refuse". It means the saved `cgWindowId`s are
    // dead and must be resolved another way — by app + geometry (`ColdStartMatch`). `5.1`'s whole-run refusal
    // survives ONLY as the fallback when nothing can be resolved at all, which is the one case where
    // proceeding would place nothing anyway and a bare "0 restored" would be the ambiguity we removed.
    //
    // The first shape of this was refuse-always, and dogfood killed it the day it shipped: the remedy keeps
    // offered ("Save again") would OVERWRITE the very layout being restored, because `Store.save` keeps no
    // history. Refusing was the safe half of an unfinished thought.
    var remap: [CGWindowID: CGWindowID]? = nil  // nil ⇒ same session, ids are trustworthy
    let coldStart = !SessionFreshness.isCurrent(snapshot)
    if coldStart {
      remap = coldStartRemap(snapshot, live: live)
      DebugTrace.log(
        "=== restore fp=\(snapshot.configFingerprint) COLD START — snapshot predates this boot "
          + "(capturedAt=\(snapshot.capturedAt)); resolved \(remap?.count ?? 0)/\(snapshot.windows.count) "
          + "windows by app+geometry")
      guard !(remap ?? [:]).isEmpty else {  // nothing resolvable ⇒ the honest stop, not a bare zero
        return Result(
          planned: 0, applied: 0, failures: 0, skips: [:], outcomes: [], dryRun: !apply,
          readFailed: false, staleSession: true)
      }
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
    for (cap, action) in classify(snapshot, against: live, tolerance: tolerance, remap: remap) {
      // Same resolve-or-refuse rule as `matchFor`. An unresolved cold-start window never reaches a `.place`
      // (it classified `gone`), so this only has to be self-consistent — but a raw fallback here would still
      // read a stranger's frame into the trace's "before", which is how a wrong-window bug hides in plain sight.
      let wid = coldStart ? (remap?[cap.cgWindowId] ?? 0) : cap.cgWindowId
      let before = live.existence.frames[wid]  // the trace's "before" AND the #keeps-17 restitution target
      var label = action.label  // reclassified to a skip reason when verify-after-place restitutes (#keeps-17)
      switch action {
      case .place(let frame, let verifySpace):
        planned += 1
        if apply, let el = live.reachable[wid]?.element {  // dry run, or lost the element, ⇒ count only
          let ok = setFrame(el, frame)
          var decision = ok ? "placed" : "place-FAILED(axSet)"
          if !ok { failures += 1 }
          if ok, !verifySpace { applied += 1 }
          if ok, verifySpace {
            // #keeps-17 Q1: the guard PREDICTED this cross-display place lands on the window's own Space
            // (landing display's active Space == captured spaceUUID) — but the re-home rule is macOS's, so
            // enforce: POLL membership after the set (the re-home is WindowServer-async; an immediate read
            // races it and restitutes a perfectly good place — Tom hit that live, 2026-07-06 23:45). A landing
            // that still isn't home after the poll restitutes the frame (best-effort, Q4) and reclassifies the
            // window as carry-deferred. Never a silent wrong-Space landing.
            func landedSpace() -> String? {
              // `wid`, not `cap.cgWindowId` (#keeps-5.4): after a cold start the captured id is dead, and
              // polling it would read nothing forever — the poll would time out and restitute a place that
              // actually succeeded. The verification has to ask about the window we really moved.
              cgsSpacesForWindow(live.cid, wid).first
                .flatMap { live.desktopIndex.uuid(ofManagedID: $0) }
            }
            var landed = landedSpace()
            var waited = 0.0
            while landed != cap.spaceUUID && waited < 1.5 {
              Thread.sleep(forTimeInterval: 0.15)
              waited += 0.15
              landed = landedSpace()
            }
            if landed == cap.spaceUUID {
              applied += 1
            } else {
              let restituted = before.map { setFrame(el, $0) } ?? false
              skips[.deferredCrossDisplay, default: 0] += 1
              label = SkipReason.deferredCrossDisplay.rawValue
              decision = "placed-restituted(wrongSpace\(restituted ? "" : "; restitutionFailed"))"
            }
          }
          if DebugTrace.enabled && DebugTrace.traces(bundleId: cap.bundleId, title: cap.title) {
            DebugTrace.log(
              DebugTrace.windowLine(
                bundleId: cap.bundleId, title: cap.title, wid: cap.cgWindowId,
                decision: decision, desired: frame, before: before,
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
          bundleId: cap.bundleId, title: cap.title, cgWindowId: cap.cgWindowId, action: label
        ))
    }
    return Result(
      planned: planned, applied: applied, failures: failures, skips: skips,
      outcomes: outcomes, dryRun: !apply, readFailed: false,
      coldStart: coldStart, coldStartMatched: remap?.count ?? 0)
  }

  // MARK: - I/O helpers

  struct Reachable {
    let element: AXUIElement
    let minimized: Bool
    let identity: String  // #keeps-5: owning app, AppIdentity-encoded — the guard's left-hand side
  }  // internal: held by LiveState (#keeps-12 seam)
  /// #keeps-5: `owners` is not decoration. The gone-test used to be bare-id, and the brief's first draft argued
  /// that was harmless because "every placement goes through the guarded `reachable[…]`". The independent review
  /// disproved it: a bare-id hit here classifies `deferredBackground`, which routes the window into the CARRY —
  /// and the carry reads bounds by bare wid, grabs by geometry, and its membership check then PASSES, because
  /// the impostor really did land on the target Space. A stranger's window moved, reported as success.
  /// Guarding at this seam keeps an impostor out of the carry set entirely, so no grab behavior has to change.
  struct Existence {
    let ids: Set<CGWindowID>
    let frames: [CGWindowID: WindowFrame]
    let owners: [CGWindowID: String]
    /// #keeps-5.4: ids on the NORMAL window layer only — the same `layer == 0` filter capture applies
    /// (`Capture.swift:52`, `notNormalLayer`: "menus, panels, status items, shadows").
    ///
    /// `ids` above stays unfiltered on purpose: it answers "does this window still exist at all", and
    /// narrowing it would change gone-detection. But cold-start MATCHING must only ever consider windows
    /// capture itself would have stored — the first build didn't, and Safari's real window was matched to
    /// Safari's 1800×39 status-bar window at the origin, which has no Space and so classified `minimized`.
    /// 26 of 29 windows came back that way. Two sets, two questions.
    let normalLayer: Set<CGWindowID>
  }

  /// Live windows reachable via public AX — i.e. on each display's ACTIVE desktop (+ minimized). Keyed by
  /// cgWindowId via the private bridge. Every app handle gets a 1s messaging timeout (the #keeps-6 freeze guard).
  private static func reachableWindows() -> [CGWindowID: Reachable] {
    var map: [CGWindowID: Reachable] = [:]
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      // #keeps-5: the owning app is already in hand here — the identity guard costs one field, not a second
      // enumeration. (This is why the fix belongs at this commit: the earlier attempt to land it back at
      // #keeps-3 cascaded conflicts through 14 commits, not because it was hard.)
      let identity = AppIdentity.encode(
        bundleId: app.bundleIdentifier, pid: app.processIdentifier)
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(axApp, 1.0)
      var winsVal: AnyObject?
      guard
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsVal) == .success,
        let windows = winsVal as? [AXUIElement]
      else { continue }
      for w in windows {
        guard let wid = axWindowID(w) else { continue }
        map[wid] = Reachable(
          element: w, minimized: axFlag(w, kAXMinimizedAttribute), identity: identity)
      }
    }
    return map
  }

  /// Every window CGWindowList(.optionAll) sees (all desktops): membership (for gone-detection) + frames
  /// (for the already-correct compare, read from the SAME source capture used — CGWindowList bounds).
  private static func enumerateExistence() -> Existence {
    var ids = Set<CGWindowID>()
    var frames: [CGWindowID: WindowFrame] = [:]
    var owners: [CGWindowID: String] = [:]
    var normalLayer = Set<CGWindowID>()
    let identities = AppIdentity.liveMap()  // #keeps-5: one read, reused for every window below
    for info in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]])
      ?? []
    {
      guard let wid = info[kCGWindowNumber as String] as? CGWindowID, wid != 0 else { continue }
      ids.insert(wid)
      if let f = frame(from: info) { frames[wid] = f }
      // kCGWindowOwnerPID and kCGWindowLayer ride in the SAME dictionary this loop already reads — no
      // extra syscall for either.
      if let pid = info[kCGWindowOwnerPID as String] as? pid_t, let id = identities[pid] {
        owners[wid] = id
      }
      if (info[kCGWindowLayer as String] as? Int ?? -1) == 0 { normalLayer.insert(wid) }
    }
    return Existence(ids: ids, frames: frames, owners: owners, normalLayer: normalLayer)
  }

  /// Lift one captured window's live state into a pure `Match` (nil ⇒ gone).
  /// Costs one CGS Space read per matched window, both branches — see the call site for why the reachable
  /// branch asks the window its Space instead of inferring it from the display under its frame (#keeps-23).
  private static func matchFor(
    _ cap: CapturedWindow, live: LiveState, remap: [CGWindowID: CGWindowID]? = nil
  ) -> Match? {
    // #keeps-5.4: resolve the id, or refuse. In a cold start the captured id is DEAD, so an unresolved
    // window has no live counterpart at all and must be `gone` (nil) — never looked up raw. Recycled ids
    // mean a raw lookup would land on a stranger, and could also hand one live window to two captured
    // records at once. Same-session (`remap == nil`) uses the captured id, exactly as it always has.
    let wid: CGWindowID
    if let remap {
      guard let resolved = remap[cap.cgWindowId] else { return nil }  // unresolved in a cold start ⇒ gone
      wid = resolved
    } else {
      wid = cap.cgWindowId
    }
    // #keeps-5, guard site 1 of 2 (the dangerous one): a reachable hit is placed via AX, so an id whose owner
    // has changed would silently move a stranger's window. `nil` identity ⇒ mismatch: an unattributable owner
    // is exactly the case we refuse to guess about.
    if let r = live.reachable[wid] {
      // #keeps-5 guard site 1 of 2, and the dangerous one: a reachable hit gets placed via AX, so a changed
      // owner would silently move a stranger's window to our captured frame. Still load-bearing under a
      // remap: ColdStartMatch groups by bundleId, so this passes by construction there — but it is the
      // check that MAKES that true rather than assuming it.
      guard r.identity == cap.bundleId else { return Match.impostor }
      let frame = live.existence.frames[wid]
      let landing = live.topology.displayContaining(cap.frame)  // where an AX-set would land TODAY (#keeps-17)
      let current = frame.flatMap { live.topology.displayContaining($0) }
      // #keeps-23: ASK the window which Space it is on — do not infer it from its display.
      //
      // This line used to read `currentSpace: current?.activeSpaceUUID`: "a reachable window sits on the
      // ACTIVE Space of the display under its live frame", justified as saving a CGS read. The premise is
      // this file's header claim — that AX reaches only the active desktop — and it is not reliably true.
      // Tom's 2026-07-28 dogfood disproved it with a single window: cmux `wid=201` was AX-reachable while
      // sitting on desktop 1 with desktop 13 active, so the inference returned desktop 13's uuid, the compare
      // against its captured home failed, and restore called a window that was exactly home
      // `deferredWrongSpace`. The carry, which reads `cgsSpacesForWindow` directly, called the same window
      // `alreadyOnDesktop 1→1` in the same run. Two classifiers, one window, opposite verdicts — and the one
      // that asked was right.
      //
      // `spaces.count == 1` is the same guard the not-reachable branch below carries, and for the same
      // #keeps-15 reason: `spaces.first` on a multi-Space read is an arbitrary member, so it can "prove" a
      // home the window is nowhere near. Anything other than exactly one Space ⇒ nil ⇒ `decide` falls back to
      // frame-only, which is the documented fail-safe, NOT back to the display inference — re-deriving from
      // the display here would reinstate the bug in its own fix.
      //
      // Cost: one CGS read per reachable window, where there were none. The saving this replaces was real but
      // small (19 reachable windows against 30 captured on the live fleet), and it bought a wrong answer.
      let ownSpace = live.desktopIndex.ownSpaceUUID(ofSpaces: cgsSpacesForWindow(live.cid, wid))
      return Match(
        reachable: true, minimized: r.minimized,
        // Still a hardcoded don't-care, deliberately: `decide` tests `liveSpaceCount == 0` for minimized
        // BEFORE it tests `reachable`, so feeding the real count here would newly classify an AX-visible,
        // zero-Space window as minimized. That may even be right, but it is a second behavior change riding
        // in unannounced on a fix for a different bug — so it stays out. `ownSpace` above carries the count
        // guard where it is actually needed.
        liveSpaceCount: 1,
        liveFrame: frame,
        currentDisplay: current?.uuid,
        landingDisplay: landing?.uuid,
        landingActiveSpace: landing?.activeSpaceUUID,
        currentSpace: ownSpace)
    }
    guard live.existence.ids.contains(wid) else { return nil }  // not in .optionAll at all ⇒ gone
    // #keeps-5 guard site 2 of 2 — the one the brief's first draft argued was harmless. It is not: an
    // unguarded hit here classifies `deferredBackground`, which hands the id to the CARRY, and the carry
    // grabs by geometry (Carry.swift:421-423) and then VERIFIES MEMBERSHIP — which passes, because the
    // impostor genuinely landed on the target Space. Wrong window moved, run reports success. Rejecting here
    // keeps an impostor out of the carry set entirely, so no grab behavior needed changing.
    // A window with no attributable owner (`owners[wid] == nil`) is refused for the same reason: capture only
    // ever stored regular-app windows, so an unattributable live owner cannot be the one we captured.
    guard live.existence.owners[wid] == cap.bundleId else { return Match.impostor }
    let spaces = cgsSpacesForWindow(live.cid, wid)
    return Match(
      reachable: false, minimized: false,  // not-in-AX minimized is caught by the 0-space check
      liveSpaceCount: spaces.count,
      liveFrame: live.existence.frames[wid],  // #keeps-17 guard facts stay nil — the guard sits on the place path
      currentSpace: spaces.first.flatMap { live.desktopIndex.uuid(ofManagedID: $0) })  // #keeps-15 slice 2
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
    samePosition(other, tolerance: tolerance) && sameSize(other, tolerance: tolerance)
  }

  /// Same origin within ±tolerance, whatever the size — `ColdStartMatch`'s tier 2 (#keeps-31): a strip whose
  /// width tracks its content, or a window resized in place. Not on its own a proof of "home".
  func samePosition(_ other: WindowFrame, tolerance: Int) -> Bool {
    abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
  }

  /// Same size within ±tolerance, wherever it sits — tier 3: an app that relaunched a window elsewhere.
  func sameSize(_ other: WindowFrame, tolerance: Int) -> Bool {
    abs(w - other.w) <= tolerance && abs(h - other.h) <= tolerance
  }

  /// Squared distance between centres, in px² — the within-tier tiebreak. Squared so it stays an exact Int.
  func centreDistanceSquared(to other: WindowFrame) -> Int {
    let dx = (2 * x + w) - (2 * other.x + other.w)  // 2× the centre delta; the factor cancels in comparison
    let dy = (2 * y + h) - (2 * other.y + other.h)
    return dx * dx + dy * dy
  }
}
