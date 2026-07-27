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

  /// #keeps-22: this used to read "N windows are on other Spaces" — literally true and still misleading.
  /// The count sums `deferredBackground + deferredCrossDisplay + deferredWrongSpace`, and only the last
  /// means *wrong* Space; the first just means *a Space you aren't looking at*, which is often exactly where
  /// the window belongs with only its size adrift. Naming the location made a correct window sound misplaced,
  /// and would read as an outright lie once the carry started fixing size-only drift. Name the problem instead.
  public static func offerBody(count: Int) -> String {
    count == 1 ? "1 window isn't where you left it" : "\(count) windows aren't where you left them"
  }

  public static func offerActionTitle(count: Int) -> String {
    count == 1 ? "Bring it back" : "Bring them back"
  }

  // MARK: - Verdict copy (partitions CarryResult exactly: aborted first, then carried vs planned)

  /// The completion-notification body. Every reachable (aborted, carried, planned) state has honest copy —
  /// partial non-aborted runs are common (.failed outcomes don't set aborted), so they never wear "success".
  public static func verdictBody(carried: Int, planned: Int, aborted: Bool) -> String {
    // #keeps-21: this branch was the one place the "counts agree at N=1" rule below was broken —
    // a single-candidate abort read "0 of 1 windows". Pluralize on `planned`, the noun being counted.
    if aborted {
      return "Stopped — \(carried) of \(planned) window\(planned == 1 ? "" : "s") brought back"
    }
    if planned == 0 { return "Everything was already in place" }
    if carried == 0 {
      return planned == 1
        ? "Couldn't bring the window back"
        : "Couldn't bring windows back — none of \(planned) moved"
    }
    if carried < planned { return "\(carried) of \(planned) windows brought back" }
    // #keeps-22: was "brought back to its Space" — location-naming, and now sometimes false since a run may
    // fix only a window's size with no Space change. Briefly "brought back where you left it", which rhymed
    // with the offer's "aren't where you left them" — and on an ABORTED run both banners sit in Notification
    // Center together, where two near-identical sentences blur. Bare "brought back" echoes the action button
    // the user actually pressed ("Bring them back") and matches the partial/aborted forms above.
    return carried == 1 ? "1 window brought back" : "\(carried) windows brought back"
  }
}
