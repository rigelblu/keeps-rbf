// CarrySignifier — the pure words-and-glyphs side of #keeps-19: the in-flight status-item title and the
// notification copy (offer + verdict). Pure functions so CoreTests covers every reachable CarryResult state
// without AppKit; the host renders, this decides. Copy obeys the #keeps-16 rules: bodies state facts, verbs
// live on action buttons, counts agree at N=1, no question marks from a system utility.
public enum CarrySignifier {

  // MARK: - In-flight status-item title

  /// The 4-frame cycle a glance reads as "keeps is doing this". Reduce Motion collapses to a static glyph.
  public static let frames = ["◐", "◓", "◑", "◒"]

  /// The status-item title while a carry runs. `progress` is nil until the first progress callback.
  public static func title(frame: Int, progress: (done: Int, total: Int)?, reduceMotion: Bool) -> String {
    let glyph = reduceMotion ? "⟳" : frames[((frame % frames.count) + frames.count) % frames.count]
    guard let p = progress else { return glyph }
    return "\(glyph) \(p.done)/\(p.total)"
  }

  // MARK: - Offer copy (the #keeps-13 nudge, trued: fact body, count-aware action)

  public static func offerBody(count: Int) -> String {
    count == 1 ? "1 window is on another Space" : "\(count) windows are on other Spaces"
  }

  public static func offerActionTitle(count: Int) -> String {
    count == 1 ? "Bring it back" : "Bring them back"
  }

  // MARK: - Verdict copy (partitions CarryResult exactly: aborted first, then carried vs planned)

  /// The completion-notification body. Every reachable (aborted, carried, planned) state has honest copy —
  /// partial non-aborted runs are common (.failed outcomes don't set aborted), so they never wear "success".
  public static func verdictBody(carried: Int, planned: Int, aborted: Bool) -> String {
    if aborted { return "Stopped — \(carried) of \(planned) windows brought back" }
    if planned == 0 { return "Everything was already in place" }
    if carried == 0 {
      return planned == 1
        ? "Couldn't bring the window back"
        : "Couldn't bring windows back — none of \(planned) moved"
    }
    if carried < planned { return "\(carried) of \(planned) windows brought back" }
    return carried == 1
      ? "1 window brought back to its Space"
      : "\(carried) windows brought back to their Spaces"
  }
}
