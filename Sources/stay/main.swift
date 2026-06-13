// stay — the menu-bar host (#stay-2). Modes:
//   (default)        menu-bar app: a status item + "Save Workspace Layout" + Quit
//   --capture-once   capture → store once, print a summary, exit   (Scenario A/E self-verify)
//   --print          capture → print JSON to stdout (no store), exit
//   --watch          Gate-1 probe: log each reconfig event + how many windows are readable RIGHT NOW
// Automatic capture-on-event is intentionally NOT wired yet — it waits on Gate 1 (see Watcher).
import AppKit
import Core
import CoreGraphics
import os

let log = Logger(subsystem: "com.rigelblu.stay", category: "main")
let args = CommandLine.arguments

func captureAndStore() throws -> (URL, Snapshot) {
    let snap = Capture.snapshot()
    return (try Store().save(snap), snap)
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
    let snap = result.snapshot
    let url = try Store().save(snap)
    let attributed = snap.windows.filter { $0.desktopOrdinal != nil }.count
    let sticky = snap.windows.filter { $0.sticky }.count
    let unmapped = snap.windows.count - attributed - sticky   // single-space but its space wasn't indexed — the failure to surface, not "all-desktops"
    print("captured \(snap.windows.count) windows (\(attributed) desktop-attributed, "
          + "\(sticky) all-desktops, \(unmapped) unmapped) across \(snap.displays.count) display(s)")
    let dropStr = result.drops.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")
    print("dropped \(result.drops.values.reduce(0, +)): [\(dropStr)]")
    print("fingerprint \(snap.configFingerprint) → \(url.path)")
    exit(0)
}

if args.contains("--watch") {
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer: non-TTY stdout block-buffers, hiding live events
    // Gate-1 probe — on each reconfig event, log flags + how many windows are readable NOW.
    // Tom: run this, unplug/replug a monitor, watch whether the begin event still reads the old layout.
    print("watching display reconfiguration — unplug/replug a monitor (Ctrl-C to stop)")
    let watcher = Watcher { flags, display in
        let snap = Capture.snapshot()
        let begin = flags.contains(.beginConfigurationFlag)
        print("reconfig display=\(display) begin=\(begin) flags=\(flags.rawValue) → "
              + "\(snap.windows.count) windows readable, fp=\(snap.configFingerprint)")
        log.info("reconfig display=\(display) begin=\(begin) flags=\(flags.rawValue) windows=\(snap.windows.count)")
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
    CFRunLoopRun()   // CG display callbacks are reliably serviced here; RunLoop.main.run() can miss them
    exit(0)          // a watch run terminates here — never falls through into the menu-bar app below
}

// default: menu-bar app
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!     // glanceable "last capture" line so you can SEE it's working
    var watcher: Watcher?           // held so the CG reconfig registration survives
    var captureDebounce: Timer?     // coalesces the reconfig event burst into one capture once it settles

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▢"   // placeholder glyph; the real icon is packaging (deferred)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "No capture yet", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false   // info-only; shows what the last capture did
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let saveItem = NSMenuItem(title: "Save Workspace Layout", action: #selector(save), keyEquivalent: "s")
        saveItem.target = self
        menu.addItem(saveItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // Automatic capture (Gate 1 resolved 2026-06-13): the CG reconfig event fires reliably in-app, so it
        // TRIGGERS a debounced capture of the now-settled config. capture-on-leave is dead — at the begin
        // callback the fingerprint has already flipped to the new config — so we instead keep each config's
        // snapshot fresh while we're stably in it (keyed by its fingerprint); the config you leave already has
        // one. Manual "Save Workspace Layout" stays as the on-demand refresh. The Watcher only forwards events;
        // the debounce + capture policy lives here in the host.
        watcher = Watcher { [weak self] _, _ in self?.scheduleCapture(reason: "reconfig") }
        watcher?.start()
        scheduleCapture(reason: "launch")   // seed the config we launched into, once it settles
    }

    @objc func save() {
        do {
            let (url, snap) = try captureAndStore()
            log.info("manual save: \(snap.windows.count) windows → \(url.path)")
            noteCapture(snap, "manual")
            tick("✓")
        } catch {
            log.error("manual save failed: \(error.localizedDescription)")
            tick("⚠")
        }
    }

    // The reconfig burst (begin/end × per-display) fires within ~1s; each event resets this timer so we
    // capture once, after the configuration has gone quiet and settled.
    private func scheduleCapture(reason: String) {
        captureDebounce?.invalidate()
        captureDebounce = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.autoCapture(reason: reason)
        }
    }

    private func autoCapture(reason: String) {
        do {
            let (_, snap) = try captureAndStore()
            log.info("auto-capture (\(reason, privacy: .public)): \(snap.windows.count) windows, fp=\(snap.configFingerprint, privacy: .public)")
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
        statusLine.title = "Last: \(snap.windows.count) windows · \(snap.configFingerprint.prefix(8)) · \(f.string(from: Date())) · \(kind)"
    }

    private func tick(_ glyph: String) {
        statusItem.button?.title = glyph
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.statusItem.button?.title = "▢" }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
