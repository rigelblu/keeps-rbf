// keeps — the menu-bar host (#keeps-2). Modes:
 //   (default)        menu-bar app: a status item + "Save/Restore Window Layouts & Spaces" + Quit
 //   --capture-once   capture → store once, print a summary, exit   (Scenario A/E self-verify)
 //   --print          capture → print JSON to stdout (no store), exit
 //   --watch          Gate-1 probe: log each reconfig event + how many windows are readable RIGHT NOW
 // Automatic capture-on-event is intentionally NOT wired yet — it waits on Gate 1 (see Watcher).
 import AppKit
 import ApplicationServices  // AXIsProcessTrusted for the restore path
 import Core
 import CoreGraphics
 import UserNotifications
 import os

 let log = Logger(subsystem: "com.rigelblu.keeps", category: "main")
 let args = CommandLine.arguments

 func captureAndStore() throws -> (URL, Snapshot)? {
   let result = Capture.capture()
   guard !result.readFailed else { return nil }  // cid==0 — never persist a 0-window snapshot (M4)
   return (try Store().save(result.snapshot), result.snapshot)
 }

 // Run the async carry to completion synchronously for the CLI path (the menu drives it as a Task instead, so its
 // ~1.1s/step waits never freeze the UI). The carry yields on its own executor; main just blocks until it's done.
 // Live progress goes to stderr so it doesn't tangle with the summary on stdout.
 func runCarry(_ snapshot: Snapshot, apply: Bool) -> Carry.CarryResult {
   let sem = DispatchSemaphore(value: 0)
   var result: Carry.CarryResult!
   Task.detached {
     result = await Carry.carry(snapshot, apply: apply) { p in
       guard apply else { return }
       FileHandle.standardError.write(
         "  carrying \(p.done)/\(p.total) · desktop \(p.toDesktop) · \(p.bundleId)\n".data(
           using: .utf8)!)
     }
     sem.signal()
   }
   sem.wait()
   return result
 }

 if args.contains("--print") {
   let enc = JSONEncoder()
   enc.outputFormatting = [.prettyPrinted, .sortedKeys]
   enc.dateEncodingStrategy = .iso8601
   print(String(data: try enc.encode(Capture.snapshot()), encoding: .utf8)!)
   exit(0)
 }
 
 if args.contains("--capture-once") {
   let result = Capture.capture()
   guard !result.readFailed else {
     print("SkyLight read failed (cid==0) — captured nothing, nothing saved")
     exit(1)
   }
   let snap = result.snapshot
   let url = try Store().save(snap)
   let attributed = snap.windows.filter { $0.desktopOrdinal != nil }.count
   let sticky = snap.windows.filter { $0.sticky }.count
   let unmapped = snap.windows.count - attributed - sticky  // single-space but its space wasn't indexed — the failure to surface, not "all-desktops"
   print(
     "captured \(snap.windows.count) windows (\(attributed) desktop-attributed, "
       + "\(sticky) all-desktops, \(unmapped) unmapped) across \(snap.displays.count) display(s)")
   let dropStr = result.drops.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)=\($0.value)" }
     .joined(separator: ", ")
   print("dropped \(result.drops.values.reduce(0, +)): [\(dropStr)]")
   print("fingerprint \(snap.configFingerprint) → \(url.path)")
   exit(0)
 }
 
 if args.contains("--restore-once") {
   // Read back the current config's snapshot and restore it. DRY RUN by default (moves nothing);
   // pass --apply to actually place windows (Scenario B/C self-verify before the menu/auto path).
   let apply = args.contains("--apply")
   print(
     "Accessibility: \(AXIsProcessTrusted() ? "trusted" : "NOT trusted — placed/reachable will be empty without it (System Settings → Privacy → Accessibility)")"
   )
   let fp = ConfigIdentity.fingerprint()
   let snap: Snapshot
   do {
     snap = try Store().load(fingerprint: fp)
   } catch {
     print(
       "no snapshot to restore for fp=\(fp): \(error.localizedDescription) — capture this config first (--capture-once)"
     )
     exit(1)
   }
   let r = Restore.restore(snap, apply: apply)
   if r.readFailed {
     print("SkyLight read failed (cid==0) — restored nothing")
     exit(1)
   }
   let skipStr = r.skips.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)=\($0.value)" }
     .joined(separator: ", ")
   print(
     (apply
       ? "restored \(r.applied)/\(r.planned) planned (\(r.failures) failed)"
       : "DRY RUN — would restore \(r.planned)")
       + " of \(snap.windows.count) captured windows, fp=\(fp)")
   print("skipped \(r.skips.values.reduce(0, +)): [\(skipStr)]")
   if args.contains("--verbose") {
     for o in r.outcomes.sorted(by: { $0.action < $1.action }) {
       print("  [\(o.action)] \(o.bundleId) — \(o.title ?? "(no title)")  wid=\(o.cgWindowId)")
     }
   }
   exit(0)
 }
 
 if args.contains("--carry-once") {
   // Carry this config's deferred-background windows back to their captured desktops + frames (#keeps-12, the
   // VISIBLE half). DRY RUN by default — re-classifies, plans, and lists each window's target, moving nothing;
   // pass --apply to run the visible carry. --verbose prints each deferred-background window's decision. The
   // dry-run is side-effect-free, but it validates the PLAN, not the mechanism — whether a held window follows
   // is only provable live (Scenario D2/D3 + G2). Move the mouse mid-run to abort an --apply carry.
   let apply = args.contains("--apply")
   print(
     "Accessibility: \(AXIsProcessTrusted() ? "trusted" : "NOT trusted — the carry's synthetic input is ignored without it (System Settings → Privacy → Accessibility)")"
   )
   let fp = ConfigIdentity.fingerprint()
   let snap: Snapshot
   do {
     snap = try Store().load(fingerprint: fp)
   } catch {
     print(
       "no snapshot to carry for fp=\(fp): \(error.localizedDescription) — capture this config first (--capture-once)"
     )
     exit(1)
   }
   let r = runCarry(snap, apply: apply)
   if r.readFailed {
     print("SkyLight read failed (cid==0) — carried nothing")
     exit(1)
   }
   if r.navigationDead {
     print(
       "Can't navigate desktops — enable Switch-to-Desktop or Move-a-space (System Settings → Keyboard → Shortcuts → Mission Control)"
     )
     exit(1)
   }
   let skipStr = r.skips.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)=\($0.value)" }
     .joined(separator: ", ")
   let deferred = r.outcomes.count
   print(
     (apply
       ? "carried \(r.carried)/\(r.plannedCarries) planned\(r.aborted ? " (aborted after \(r.abortedAfter))" : "")"
       : "DRY RUN — would carry \(r.plannedCarries)")
       + " of \(deferred) deferred windows (background + cross-display; \(snap.windows.count) captured), fp=\(fp)")
   print("skipped \(r.skipped): [\(skipStr)]")
   if args.contains("--verbose") {
     for o in r.outcomes.sorted(by: { $0.outcome < $1.outcome }) {
       let leg = (o.fromGlobal.map(String.init) ?? "?") + "→" + (o.toGlobal.map(String.init) ?? "?")
       print(
         "  [\(o.outcome)] \(o.bundleId) — \(o.title ?? "(no title)")  desktop \(leg)  wid=\(o.cgWindowId)"
       )
     }
   }
   exit(0)
 }

 if args.contains("--watch") {
   setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer: non-TTY stdout block-buffers, hiding live events
   // Gate-1 probe — on each reconfig event, log flags + how many windows are readable NOW.
   // Tom: run this, unplug/replug a monitor, watch whether the begin event still reads the old layout.
   print("watching display reconfiguration — unplug/replug a monitor (Ctrl-C to stop)")
   let watcher = Watcher { flags, display in
     let snap = Capture.snapshot()
     let begin = flags.contains(.beginConfigurationFlag)
     print(
       "reconfig display=\(display) begin=\(begin) flags=\(flags.rawValue) → "
         + "\(snap.windows.count) windows readable, fp=\(snap.configFingerprint)")
     log.info(
       "reconfig display=\(display) begin=\(begin) flags=\(flags.rawValue) windows=\(snap.windows.count)"
     )
   }
   watcher.start()
   // Heartbeat: prove the probe is alive + show the window-count trajectory across the unplug
   // (and the read the debounced-stable fallback would use if the reconfig event proves unreliable).
   let heartbeat = Timer(timeInterval: 3, repeats: true) { _ in
     let snap = Capture.snapshot()
     print("· alive — \(snap.windows.count) windows readable, fp=\(snap.configFingerprint)")
     log.info("heartbeat windows=\(snap.windows.count) fp=\(snap.configFingerprint)")
   }
   RunLoop.main.add(heartbeat, forMode: .common)
   CFRunLoopRun()  // CG display callbacks are reliably serviced here; RunLoop.main.run() can miss them
   exit(0)  // a watch run terminates here — never falls through into the menu-bar app below
 }
 
 // default: menu-bar app
 final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
   var statusItem: NSStatusItem!
   var statusLine: NSMenuItem!  // glanceable "last activity" line — hidden until there's something to say (#keeps-19)
   var statusSeparator: NSMenuItem!  // rides with statusLine so a hidden line doesn't leave a leading separator
   var watcher: Watcher?  // held so the CG reconfig registration survives
   var settleDebounce: Timer?  // coalesces the reconfig burst into one settle action once it's quiet
   var lastSettled: String?  // the config we last acted on — guards the sleep/wake spurious restore (#keeps-3)
   var pendingCarry: PendingCarry? {  // the live carry offer; nil ⇒ nothing stranded off-Space
     didSet {
       refreshAffordance()
       if let p = pendingCarry, p != oldValue { notifyOffer(p) }  // #keeps-13: nudge once when a new offer is raised
     }
   }
   // #keeps-19: the in-flight signifier — while a carry runs, the run is the glyph's ONLY writer (isCarrying
   // guards every other writer, incl. tick()'s uncancellable deferred reset, checked at fire time) and the
   // status item animates with live progress (◐ 2/5; Reduce Motion → static ⟳ 2/5).
   private var isCarrying = false
   private var carryTimer: Timer?
   private var carryFrame = 0
   private var carryProgress: (done: Int, total: Int)?
   // #keeps-13 notification half: a UserNotifications nudge mirroring the menu offer. Gated on a real app bundle —
   // an unbundled SwiftPM binary has no bundleIdentifier and can't post, so it degrades cleanly to menu-only.
   // #keeps-19: TWO offer categories (one/many) — action titles are baked at registration, and re-registering per
   // offer would mutate global category state under an in-flight notification; the verdict posts on its own id.
   private static let carryCategoryOneID = "keeps.carry.one"
   private static let carryCategoryManyID = "keeps.carry.many"
   private static let bringBackActionID = "keeps.bringBack"
   private static let offerNotificationID = "keeps.carry-offer"
   private static let verdictNotificationID = "keeps.carry-verdict"
   private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }
 
   func applicationDidFinishLaunching(_ note: Notification) {
     statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
     statusItem.button?.title = "▢"  // placeholder glyph; the real icon is packaging (deferred)
     let menu = NSMenu()
     // #keeps-19: the status line exists only when it has something real to say (last activity, an
     // in-flight carry, an error) — idle shows nothing: no message beats a filler message, and every
     // "watching…" phrasing reads as surveillance (Tom, 2026-07-07).
     statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
     statusLine.isEnabled = false  // info-only; shows what the last capture/restore did
     statusLine.isHidden = true
     statusSeparator = NSMenuItem.separator()
     statusSeparator.isHidden = true
     menu.addItem(statusLine)
     menu.addItem(statusSeparator)
     // #keeps-16: ONE verb — the user never thinks about which kind of restore this is; keeps figures it out
     // (silent places, then the carry for anything stranded). The badge (▢ N) is the pending-work signifier;
     // the dock-in notification (#keeps-18, packaging-gated) becomes the direct tap.
     let restoreItem = NSMenuItem(
       title: "Restore Window Layouts & Spaces", action: #selector(restore), keyEquivalent: "r")
     restoreItem.target = self
     menu.addItem(restoreItem)
     let saveItem = NSMenuItem(
       title: "Save Window Layouts & Spaces", action: #selector(save), keyEquivalent: "s")
     saveItem.target = self
     menu.addItem(saveItem)
     menu.addItem(.separator())
     menu.addItem(
       NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
     statusItem.menu = menu
     setupNotifications()  // #keeps-13: register the carry nudge if this build can post (bundled); else menu-only
     if DebugTrace.enabled {
       DebugTrace.log(
         "=== keeps launched — debug trace active\(DebugTrace.focusNote) — displays: "
           + DebugTrace.displaysHeader(DebugTrace.activeDisplays()))
     }
 
     // Arbitration (#keeps-3): the CG reconfig event is BOTH capture's and restore's trigger, so on a settled
     // config-change we RESTORE a config we've seen before and CAPTURE (learn) one we haven't — never capture a
     // known config on its entry event (that would overwrite its good snapshot with the just-disrupted layout
     // and corrupt the entries #keeps-12 needs). Launch is NOT a "came back" moment, so it only captures-if-unknown
     // (never auto-restores). The Watcher just forwards; the policy lives here.
     watcher = Watcher { [weak self] _, _ in
       self?.debounceSettle { self?.onSettle(reason: "reconfig") }
     }
     watcher?.start()
     let launchUUIDs = ConfigIdentity.activeDisplayUUIDs()
     lastSettled = launchUUIDs.isEmpty ? nil : ConfigIdentity.fingerprint(of: launchUUIDs)  // baseline for the no-change guard
     if launchUUIDs.isEmpty {
       log.info("launch: no active displays — observing")
     } else if Store().exists(fingerprint: ConfigIdentity.fingerprint(of: launchUUIDs)) {
       log.info(
         "launch: known config — observing (manual Restore available; no auto-restore on launch)")
     } else {
       debounceSettle { [weak self] in self?.autoCapture(reason: "launch") }  // unknown — seed it once it settles
     }
   }
 
   @objc func save() {
     do {
       guard let (url, snap) = try captureAndStore() else {
         log.error("manual save: SkyLight read failed (cid==0), skipped")
         tick("⚠")
         return
       }
       log.info("manual save: \(snap.windows.count) windows → \(url.path)")
       noteCapture(snap, "manual")
       tick("✓")
     } catch {
       log.error("manual save failed: \(error.localizedDescription)")
       tick("⚠")
     }
   }
 
   // Coalesce the reconfig burst (begin/end × per-display, ~1s) into a single action once it goes quiet.
   private func debounceSettle(_ action: @escaping () -> Void) {
     settleDebounce?.invalidate()
     settleDebounce = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in action() }
   }
 
   // A settled config-change: RESTORE a config we've seen, CAPTURE (learn) one we haven't — never both, so a
   // known config's good snapshot is never overwritten on its entry (#keeps-3 arbitration).
   private func onSettle(reason: String) {
     let uuids = ConfigIdentity.activeDisplayUUIDs()
     let fp = ConfigIdentity.fingerprint(of: uuids)
     // Don't fight the user on a non-change: a display SLEEP empties the display list (degenerate config), and
     // sleep/wake re-fires the reconfig with the SAME fingerprint — neither is a real config change (dogfeel
     // 2026-06-14). Only a genuine move to a different config restores (known) or learns (unknown).
     switch SettlePolicy.decide(
       fingerprint: fp, degenerate: uuids.isEmpty,
       lastSettled: lastSettled, known: Store().exists(fingerprint: fp))
     {
     case .restore:
       lastSettled = fp
       performRestore(reason: reason)
     case .capture:
       lastSettled = fp
       pendingCarry = nil  // #keeps-13: a never-seen config has no carry offer — supersede any stale one
       autoCapture(reason: reason)
     case .skipNoChange:
       log.info(
         "settle (\(reason, privacy: .public)): same config [\(fp, privacy: .public)] — skip (sleep/wake guard)"
       )
     case .skipNoDisplays:
       log.info("settle (\(reason, privacy: .public)): no active displays — skip")
     }
   }
 
   // #keeps-16: the explicit verb finishes the job. The restore/carry split is a CONSENT boundary, not a
   // value boundary — the carry hijacks cursor + Space views, so it's never sprung on the AUTO path (reconfig
   // → silent restore → one-tap offer). But an explicit click IS consent: the user asked for their layout and
   // is waiting, so phase 1 flows straight into the carry for whatever remains. Moving the mouse still stops it.
   @objc func restore() {
     performRestore(reason: "manual")
     if pendingCarry != nil { bringBackOffSpaceWindows() }
   }
 
   private func performRestore(reason: String) {
     let store = Store()
     let fp = ConfigIdentity.fingerprint()
     guard store.exists(fingerprint: fp) else {
       note("No saved layout for this config yet — Save it first")
       tick("⚠")
       return
     }
     guard ensureAccessibility() else { return }  // lazy prompt + Needs-Accessibility state; no-op until granted
     do {
       let r = Restore.restore(try store.load(fingerprint: fp), apply: true)
       guard !r.readFailed else {
         log.error("restore (\(reason, privacy: .public)): SkyLight read failed (cid==0)")
         tick("⚠")
         return
       }
       log.info(
         "restore (\(reason, privacy: .public)): placed \(r.applied)/\(r.planned), deferred \(r.carryDeferred), fp=\(fp, privacy: .public)"
       )
       noteRestore(r, reason)
       pendingCarry = CarryAffordance.afterRestore(fingerprint: fp, deferred: r.carryDeferred)  // #keeps-13: offer the carry iff a tap can bring windows home (#keeps-17.3 honest count)
       tick("⟳")
     } catch {
       log.error("restore (\(reason, privacy: .public)) failed: \(error.localizedDescription)")
       note("Restore failed: \(error.localizedDescription)")
       tick("⚠")
     }
   }
 
   // The #keeps-13 one-tap carry: the user taps the "bring back N windows" offer (raised after a phase-1 restore
   // left windows on other Spaces) and we carry this config's deferred-background windows back to their captured
   // desktops via the verified #keeps-12 mechanism. Drives macOS's own ⌥⌘N / ⌃→ shortcuts (takes over the cursor,
   // flips desktops), so it runs OFF the main actor in a Task — its ~1.1s/step waits yield, keeping the menu live
   // and the cursor-drift abort responsive (move the mouse to stop it). UI updates hop back to main.
   @objc func bringBackOffSpaceWindows() {
     guard !isCarrying else { return }  // #keeps-19: one carry at a time — a second tap mid-run (offer banner,
     // ⌘R, menu) would race two synthetic-input drivers and leak the first signifier timer
     guard ensureAccessibility() else { return }  // the carry's synthetic input needs the same trust restore does
     let store = Store()
     let fp = ConfigIdentity.fingerprint()
     guard store.exists(fingerprint: fp), let snap = try? store.load(fingerprint: fp) else {
       note("No saved layout for this config yet — Save it first")
       tick("⚠")
       return
     }
     note("Carrying desktops… (move the mouse to stop)")
     startCarrySignifier()  // #keeps-19: the run owns the glyph from here to finishCarry
     Task { @MainActor in
       let r = await Carry.carry(snap, apply: true) { p in
         DispatchQueue.main.async {
           self.carryProgress = (p.done, p.total)  // #keeps-19: the timer renders this on its next frame
           self.note("Carrying \(p.done)/\(p.total) · desktop \(p.toDesktop)…")
         }
       }
       self.finishCarry(r, fp: fp)  // resumes on the main actor after the carry completes
     }
   }

   // #keeps-19: the in-flight status-item signifier — an animated frame cycle + live progress (◐ 2/5), static
   // under Reduce Motion. Run-scoped: started here, stopped at the TOP of finishCarry (before its early returns,
   // which would leak a bottom-placed invalidate). Rendering is pure (CarrySignifier); this owns only the timer.
   private func startCarrySignifier() {
     isCarrying = true
     carryFrame = 0
     carryProgress = nil
     renderCarrySignifier()
     carryTimer = Timer.scheduledTimer(  // target/selector form: main-runloop, no @Sendable self capture
       timeInterval: 0.25, target: self, selector: #selector(carryTimerTick), userInfo: nil,
       repeats: true)
   }

   @objc private func carryTimerTick() {
     carryFrame += 1
     renderCarrySignifier()
   }

   private func stopCarrySignifier() {
     carryTimer?.invalidate()
     carryTimer = nil
     isCarrying = false
   }

   private func renderCarrySignifier() {
     statusItem?.button?.title = CarrySignifier.title(
       frame: carryFrame, progress: carryProgress,
       reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
   }

   private func finishCarry(_ r: Carry.CarryResult, fp: String) {
     stopCarrySignifier()  // #keeps-19: FIRST, before any early return — a bottom-placed stop would leak the timer
     if r.readFailed {
       log.error("carry: SkyLight read failed (cid==0)")
       note("Carry failed — SkyLight read")
       tick("⚠")
       return
     }
     if r.navigationDead {
       note("Can't navigate desktops — enable Switch-to-Desktop shortcuts")
       tick("⚠")
       return
     }
     log.info(
       "carry: carried \(r.carried)/\(r.plannedCarries), skipped \(r.skipped), aborted=\(r.aborted), fp=\(fp, privacy: .public)"
     )
     let abortNote = r.aborted ? " · stopped after \(r.abortedAfter)" : ""
     note("Last restored: \(stamp()) · \(r.carried) carried\(abortNote)")
     // #keeps-13: a clean carry fulfills the offer; an abort keeps it so the user can resume the remainder.
     if !r.aborted { pendingCarry = nil }
     notifyVerdict(r)  // #keeps-19: the run's outcome is delivered, not fetched
     tick(r.aborted ? "⚠" : "⟳")
   }

   // Restore needs Accessibility (capture didn't). Lazy: prompt on first need, show a Needs-Accessibility state,
   // and no-op until granted — never a silent do-nothing.
   private func ensureAccessibility() -> Bool {
     if AXIsProcessTrusted() { return true }
     // kAXTrustedCheckOptionPrompt is imported inconsistently across SDKs (CFString vs Unmanaged); its value is
     // the stable string "AXTrustedCheckOptionPrompt", so use that directly to dodge the import ambiguity.
     _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
     note("Needs Accessibility — grant it in System Settings, then Restore again")
     statusItem.button?.title = "!"
     return false
   }
 
   private func autoCapture(reason: String) {
     guard !ConfigIdentity.activeDisplayUUIDs().isEmpty else {  // displays asleep ⇒ nothing real to learn (no 0-display snapshot)
       log.info("auto-capture (\(reason, privacy: .public)): no active displays — skipped")
       return
     }
     do {
       guard let (_, snap) = try captureAndStore() else {
         log.error(
           "auto-capture (\(reason, privacy: .public)): SkyLight read failed (cid==0), skipped")
         tick("⚠")
         return
       }
       log.info(
         "auto-capture (\(reason, privacy: .public)): \(snap.windows.count) windows, fp=\(snap.configFingerprint, privacy: .public)"
       )
       noteCapture(snap, reason)
       tick("✓")
     } catch {
       log.error("auto-capture (\(reason, privacy: .public)) failed: \(error.localizedDescription)")
       tick("⚠")
     }
   }
 
   // The ONE status writer: the line (and its separator) exists only while it has something real to say —
   // last activity, an in-flight carry, an error. Idle shows nothing (#keeps-19; Tom: "watching" reads as
   // surveillance, and no message beats a filler message).
   private func note(_ text: String) {
     statusLine.title = text
     statusLine.isHidden = false
     statusSeparator.isHidden = false
   }

   // Glanceable status: the menu's top line says what keeps last did, in words a glance can use — no
   // fingerprint hex, date included (a bare HH:mm goes ambiguous after a day of running). #keeps-19
   private func stamp() -> String {
     let f = DateFormatter()
     f.dateFormat = "MMM d, HH:mm:ss"
     return f.string(from: Date())
   }

   private func noteCapture(_ snap: Snapshot, _ kind: String) {
     note("Last saved: \(stamp()) · \(snap.windows.count) windows")
   }

   private func noteRestore(_ r: Restore.Result, _ kind: String) {
     let tail = r.carryDeferred > 0 ? " · \(r.carryDeferred) on other Spaces" : ""
     note("Last restored: \(stamp()) · \(r.applied) placed\(tail)")
   }
 
   // #keeps-19: one-writer rule for the glyph — while a carry runs, the run's signifier is the ONLY writer.
   // tick()'s deferred reset is uncancellable asyncAfter, so it's guarded at FIRE time; a mid-run save() or a
   // reconfig-driven refreshAffordance is guarded the same way.
   private func tick(_ glyph: String) {
     guard !isCarrying else { return }
     statusItem.button?.title = glyph
     DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
       guard let self, !self.isCarrying else { return }
       self.statusItem.button?.title = self.baseGlyph()
     }
   }

   // #keeps-13/#keeps-16: render the carry offer as the badge alone — the menu carries one verb, not a rival
   // item. The decision lives in CarryAffordance; the badge only reflects it. Runs on `pendingCarry`'s didSet.
   private func refreshAffordance() {
     guard !isCarrying else { return }  // #keeps-19: the run owns the glyph; the badge re-renders at run end
     statusItem?.button?.title = baseGlyph()
   }

   // The resting status-bar glyph: a plain box, badged with the off-Space count while a carry is pending.
   private func baseGlyph() -> String { pendingCarry.map { "▢ \($0.count)" } ?? "▢" }

   // Register the #keeps-13 carry nudge's categories + action and become the center's delegate so taps route to
   // the carry. No-ops on an unbundled build (no bundle id → can't post) so dogfood stays menu-only — by design.
   // #keeps-19: two categories (one/many) carry the count-aware action titles; both route the same action id.
   private func setupNotifications() {
     guard notificationsAvailable else {
       log.info("notifications: unavailable (no bundle id) — carry offer is menu-only")
       return
     }
     let center = UNUserNotificationCenter.current()
     center.delegate = self
     center.setNotificationCategories([
       UNNotificationCategory(
         identifier: Self.carryCategoryOneID,
         actions: [
           UNNotificationAction(
             identifier: Self.bringBackActionID, title: CarrySignifier.offerActionTitle(count: 1),
             options: [.foreground])
         ], intentIdentifiers: [], options: []),
       UNNotificationCategory(
         identifier: Self.carryCategoryManyID,
         actions: [
           UNNotificationAction(
             identifier: Self.bringBackActionID, title: CarrySignifier.offerActionTitle(count: 2),
             options: [.foreground])
         ], intentIdentifiers: [], options: []),
     ])
   }

   // Post (or replace) the carry nudge for a freshly-raised offer. Reuses one notification id so a new offer
   // supersedes the old (no stacking — mirrors the single pending slot). Lazy authorization; silent if denied.
   // #keeps-19 copy: the body states the fact; the action button is the question (CarrySignifier owns the words).
   private func notifyOffer(_ p: PendingCarry) {
     guard notificationsAvailable else { return }  // the menu item carries the offer on unbundled builds
     UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
       guard granted else { return }
       let content = UNMutableNotificationContent()
       content.title = "keeps"
       content.body = CarrySignifier.offerBody(count: p.count)
       content.categoryIdentifier = p.count == 1 ? Self.carryCategoryOneID : Self.carryCategoryManyID
       UNUserNotificationCenter.current().add(
         UNNotificationRequest(identifier: Self.offerNotificationID, content: content, trigger: nil))
     }
   }

   // #keeps-19: the completion verdict — one banner per finished carry run, on its OWN id (never the offer's).
   // The fulfilled offer banner is withdrawn ONLY when no fresh offer stands: a reconfig mid-run re-raises the
   // offer on the reused id, and withdrawing then would kill the fresh offer.
   private func notifyVerdict(_ r: Carry.CarryResult) {
     guard notificationsAvailable else { return }  // the status line carries the verdict on unbundled builds
     let offerStands = pendingCarry != nil
     UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
       guard granted else { return }
       let center = UNUserNotificationCenter.current()
       if !offerStands {
         center.removeDeliveredNotifications(withIdentifiers: [Self.offerNotificationID])
       }
       let content = UNMutableNotificationContent()
       content.title = "keeps"
       content.body = CarrySignifier.verdictBody(
         carried: r.carried, planned: r.plannedCarries, aborted: r.aborted)
       center.add(
         UNNotificationRequest(identifier: Self.verdictNotificationID, content: content, trigger: nil))
     }
   }

   // Show the nudge even while keeps is the active app context (menu-bar apps otherwise suppress it in-foreground).
   func userNotificationCenter(
     _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
     withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
   ) {
     completionHandler([.banner, .sound])
   }

   // A tap on the OFFER (its action button, or the body) runs the same carry as the menu offer. Gated on the
   // offer's id: the #keeps-19 VERDICT banner shares this delegate, and a tap on a report is NOT consent to a
   // carry — only the offer's body-tap carries that meaning.
   func userNotificationCenter(
     _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
     withCompletionHandler completionHandler: @escaping () -> Void
   ) {
     let isOffer = response.notification.request.identifier == Self.offerNotificationID
     if response.actionIdentifier == Self.bringBackActionID
       || (isOffer && response.actionIdentifier == UNNotificationDefaultActionIdentifier)
     {
       DispatchQueue.main.async { [weak self] in self?.bringBackOffSpaceWindows() }
     }
     completionHandler()
   }
 }
 
 let app = NSApplication.shared
 app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
 let delegate = AppDelegate()
 app.delegate = delegate
 app.run()
