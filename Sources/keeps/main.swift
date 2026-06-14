// keeps — the menu-bar host (#keeps-2). Modes:
//   (default)        menu-bar app: a status item + "Save Workspace Layout" + Quit
//   --capture-once   capture → store once, print a summary, exit   (Scenario A/E self-verify)
//   --print          capture → print JSON to stdout (no store), exit
//   --watch          Gate-1 probe: log each reconfig event + how many windows are readable RIGHT NOW
// Automatic capture-on-event is intentionally NOT wired yet — it waits on Gate 1 (see Watcher).
import AppKit
import ApplicationServices  // AXIsProcessTrusted for the restore path
import Core
import CoreGraphics
import os

let log = Logger(subsystem: "com.rigelblu.keeps", category: "main")
let args = CommandLine.arguments

func captureAndStore() throws -> (URL, Snapshot)? {
  let result = Capture.capture()
  guard !result.readFailed else { return nil }  // cid==0 — never persist a 0-window snapshot (M4)
  return (try Store().save(result.snapshot), result.snapshot)
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
final class AppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem!
  var statusLine: NSMenuItem!  // glanceable "last capture" line so you can SEE it's working
  var watcher: Watcher?  // held so the CG reconfig registration survives
  var settleDebounce: Timer?  // coalesces the reconfig burst into one settle action once it's quiet
  var lastSettled: String?  // the config we last acted on — guards the sleep/wake spurious restore (#keeps-3)

  func applicationDidFinishLaunching(_ note: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "▢"  // placeholder glyph; the real icon is packaging (deferred)
    let menu = NSMenu()
    statusLine = NSMenuItem(title: "No activity yet", action: nil, keyEquivalent: "")
    statusLine.isEnabled = false  // info-only; shows what the last capture/restore did
    menu.addItem(statusLine)
    menu.addItem(.separator())
    let restoreItem = NSMenuItem(
      title: "Restore Workspace Layout", action: #selector(restore), keyEquivalent: "r")
    restoreItem.target = self
    menu.addItem(restoreItem)
    let saveItem = NSMenuItem(
      title: "Save Workspace Layout", action: #selector(save), keyEquivalent: "s")
    saveItem.target = self
    menu.addItem(saveItem)
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem.menu = menu

    // Arbitration (#keeps-3): the CG reconfig event is BOTH capture's and restore's trigger, so on a settled
    // config-change we RESTORE a config we've seen before and CAPTURE (learn) one we haven't — never capture a
    // known config on its entry event (that would overwrite its good snapshot with the just-disrupted layout
    // and corrupt the entries #keeps-4 needs). Launch is NOT a "came back" moment, so it only captures-if-unknown
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
      autoCapture(reason: reason)
    case .skipNoChange:
      log.info(
        "settle (\(reason, privacy: .public)): same config [\(fp, privacy: .public)] — skip (sleep/wake guard)"
      )
    case .skipNoDisplays:
      log.info("settle (\(reason, privacy: .public)): no active displays — skip")
    }
  }

  @objc func restore() { performRestore(reason: "manual") }

  private func performRestore(reason: String) {
    let store = Store()
    let fp = ConfigIdentity.fingerprint()
    guard store.exists(fingerprint: fp) else {
      statusLine.title = "No saved layout for this config yet — Save it first"
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
        "restore (\(reason, privacy: .public)): placed \(r.applied)/\(r.planned), deferred \(r.deferredBackground), fp=\(fp, privacy: .public)"
      )
      noteRestore(r, reason)
      tick("⟳")
    } catch {
      log.error("restore (\(reason, privacy: .public)) failed: \(error.localizedDescription)")
      statusLine.title = "Restore failed: \(error.localizedDescription)"
      tick("⚠")
    }
  }

  // Restore needs Accessibility (capture didn't). Lazy: prompt on first need, show a Needs-Accessibility state,
  // and no-op until granted — never a silent do-nothing.
  private func ensureAccessibility() -> Bool {
    if AXIsProcessTrusted() { return true }
    // kAXTrustedCheckOptionPrompt is imported inconsistently across SDKs (CFString vs Unmanaged); its value is
    // the stable string "AXTrustedCheckOptionPrompt", so use that directly to dodge the import ambiguity.
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    statusLine.title = "Needs Accessibility — grant it in System Settings, then Restore again"
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

  // Glanceable status: update the menu's top line so a click shows what the last capture did.
  private func noteCapture(_ snap: Snapshot, _ kind: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    statusLine.title =
      "Last: \(snap.windows.count) windows · \(snap.configFingerprint.prefix(8)) · \(f.string(from: Date())) · \(kind)"
  }

  private func noteRestore(_ r: Restore.Result, _ kind: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    statusLine.title =
      "Restored \(r.applied) · deferred \(r.deferredBackground) · \(ConfigIdentity.fingerprint().prefix(8)) · \(f.string(from: Date())) · \(kind)"
  }

  private func tick(_ glyph: String) {
    statusItem.button?.title = glyph
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      self?.statusItem.button?.title = "▢"
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
