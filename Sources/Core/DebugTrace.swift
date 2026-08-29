// DebugTrace — opt-in placement diagnostics for restore + carry (#keeps-13 dogfood). OFF unless KEEPS_DEBUG is
// set in the environment; then it appends human-readable per-window lines to a log file: each window's DESIRED
// state (target display + frame, from the snapshot), where it was BEFORE, and where it ended up AFTER — every
// frame tagged with the physical display it actually sits on, plus a header of the live display arrangement.
// That turns "Chrome didn't land on the LG" into a line you can read (wrong target? off-screen after a
// coordinate shift on reconnect? AX set rejected?), instead of a guess.
//
// Why a file (not os_log): the menu-bar app's *automatic* restore is what we need to trace, and a file is the
// simplest thing to hand back. `KEEPS_DEBUG=/path` → that path; `KEEPS_DEBUG=1` → /tmp/keeps-debug.log.
import CoreGraphics
import Foundation

public enum DebugTrace {
  /// Resolved log path, or nil when disabled. Read once at process start.
  /// `KEEPS_DEBUG=/path` → that path; `KEEPS_DEBUG=1` → ~/Library/Logs/keeps-debug.log. NOT /tmp: the lines
  /// carry window titles (email subjects, doc names, cwds) that this codebase deliberately keeps out of os_log,
  /// and /tmp is world-readable and world-writable — a pre-planted symlink there would redirect our appends.
  /// ~/Library/Logs is the macOS convention and Console.app picks it up for free.
  public static let path: String? = {
    guard let v = ProcessInfo.processInfo.environment["KEEPS_DEBUG"], !v.isEmpty else { return nil }
    guard v == "1" || v.lowercased() == "true" else { return v }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/keeps-debug.log").path
  }()
  public static var enabled: Bool { path != nil }

  /// One append-only descriptor for the whole process, created 0600. `O_APPEND` puts every write at the end of
  /// the file atomically, so the main-thread restore and the off-main carry can both log without seeking over
  /// each other — the old open-seek-write-per-line raced, and its first-write branch could truncate a racing
  /// creator. Nil when disabled or unopenable, which is simply a silent no-op (see `log`).
  private static let handle: FileHandle? = {
    guard let path else { return nil }
    try? FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    return fd < 0 ? nil : FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }()

  /// Optional focus filter (`KEEPS_FOCUS=dia` or `KEEPS_FOCUS=company.thebrowser.dia,warp`): when set, only window
  /// lines whose bundleId/title contains one of the comma-separated tokens are emitted — the display headers always
  /// emit. Lets a dogfood trace one or two apps without closing everything else; the real full restore still runs
  /// unchanged (this gates only what's LOGGED, never what's placed). Read once at process start.
  public static let focus: [String]? = {
    guard let v = ProcessInfo.processInfo.environment["KEEPS_FOCUS"], !v.isEmpty else { return nil }
    let tokens = v.lowercased().split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    return tokens.isEmpty ? nil : tokens
  }()

  /// A header suffix naming the active focus filter, so a filtered log is self-explaining ("" when unfiltered).
  public static var focusNote: String { focus.map { " focus=\($0.joined(separator: ","))" } ?? "" }

  /// Whether this window's line should be emitted under the active focus filter (thin env wrapper over `matches`).
  public static func traces(bundleId: String, title: String?) -> Bool {
    matches(tokens: focus, bundleId: bundleId, title: title)
  }

  /// Pure focus predicate: nil/empty tokens ⇒ everything; else a case-insensitive substring of ANY token against
  /// "bundleId title". Pure (no env read) so it's unit-testable, the way `Restore.decide` is. (#keeps-15 dogfood)
  static func matches(tokens: [String]?, bundleId: String, title: String?) -> Bool {
    guard let tokens, !tokens.isEmpty else { return true }
    let hay = (bundleId + " " + (title ?? "")).lowercased()
    return tokens.contains { hay.contains($0.lowercased()) }
  }

  /// Append one timestamped line to the trace file. No-op when disabled.
  ///
  /// Deliberately best-effort and SILENT on failure (Tom's call, 2026-07-27): this runs per-window inside the
  /// restore it is watching, so a diagnostic that raised, retried, or shouted would become the incident. The
  /// old code used `seekToEndOfFile()`/`write(_:)` — the legacy APIs that raise uncatchable NSExceptions — so a
  /// full or unmounted volume mid-restore killed the app with the layout half-placed. The tradeoff accepted
  /// here: a trace that cannot write is indistinguishable from a quiet one.
  public static func log(_ line: String) {
    guard let h = handle, let data = (stamp() + " " + line + "\n").data(using: .utf8) else { return }
    try? h.write(contentsOf: data)
  }

  // MARK: - Display geometry (the coordinate lens)

  /// (uuid, bounds) for every active display, in the global top-left space frames live in — so we can name which
  /// physical display a captured/live frame sits on, and spot an off-screen landing after a reconnect shift.
  public static func activeDisplays() -> [(uuid: String, bounds: CGRect)] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.prefix(Int(count)).map { (ConfigIdentity.uuid($0) ?? "?", CGDisplayBounds($0)) }
  }

  /// Short UUID of the display whose bounds contain the frame's center; "off-screen" if none does.
  public static func displayOf(_ f: WindowFrame, in displays: [(uuid: String, bounds: CGRect)]) -> String {
    let c = CGPoint(x: Double(f.x) + Double(f.w) / 2, y: Double(f.y) + Double(f.h) / 2)
    return displays.first { $0.bounds.contains(c) }.map { String($0.uuid.prefix(8)) } ?? "off-screen"
  }

  // MARK: - Formatting

  /// One window's trace line: decision + desired/before/after, each frame tagged with its display.
  public static func windowLine(
    bundleId: String, title: String?, wid: UInt32, decision: String,
    desired: WindowFrame?, before: WindowFrame?, after: WindowFrame?,
    displays: [(uuid: String, bounds: CGRect)]
  ) -> String {
    func fr(_ f: WindowFrame?) -> String {
      guard let f else { return "—" }
      return "(\(f.x),\(f.y) \(f.w)×\(f.h)) @\(displayOf(f, in: displays))"
    }
    return "[\(decision)] \(bundleId) wid=\(wid) \"\(title ?? "")\"\n"
      + "    desired \(fr(desired))  |  before \(fr(before))  |  after \(fr(after))"
  }

  /// #keeps-15: what the resolve did per display, in the snapshot's `displays` order. Pure, so it's asserted
  /// without a restore. `=== resolve fp=… — 37D8832A unchanged, 943BF734 shifted (+333,0), 47D9AC15 shifted
  /// (+333,-167)`; a whole pre-#keeps-15 snapshot reads `absolute (no saved display bounds)`.
  public static func resolveLine(fp: String, notes: [ResolveNote]) -> String {
    func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }
    func size(_ b: DisplayBounds) -> String { "\(b.w)×\(b.h)" }
    let body = notes.map { note -> String in
      switch note {
      case .noSavedBounds: return "absolute (no saved display bounds)"
      case .unchanged(let u): return "\(u.prefix(8)) unchanged"
      case .shifted(let u, let dx, let dy): return "\(u.prefix(8)) shifted (\(signed(dx)),\(signed(dy)))"
      case .absolute(let u, .noSavedBounds): return "\(u.prefix(8)) absolute (no saved display bounds)"
      case .absolute(let u, .resized(let s, let l)): return "\(u.prefix(8)) absolute (resized \(size(s)) → \(size(l)))"
      case .absolute(let u, .absent): return "\(u.prefix(8)) absolute (absent live)"
      }
    }.joined(separator: ", ")
    return "=== resolve fp=\(fp) — \(body)"
  }

  /// The live display arrangement, one short line — the reference for spotting a coordinate shift.
  public static func displaysHeader(_ displays: [(uuid: String, bounds: CGRect)]) -> String {
    displays.map {
      "\($0.uuid.prefix(8))@(\(Int($0.bounds.minX)),\(Int($0.bounds.minY)) \(Int($0.bounds.width))×\(Int($0.bounds.height)))"
    }.joined(separator: ", ")
  }

  private static let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()
  private static func stamp() -> String { clock.string(from: Date()) }
}
