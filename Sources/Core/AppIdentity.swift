// AppIdentity — the one place that turns a running app into the string a snapshot stores.
//
// #keeps-5 needs restore to ask "is this live window still owned by the app I captured?", which means the
// comparison has to encode identity EXACTLY the way capture did. Capture's rule has always been
// `bundleIdentifier ?? "pid:<pid>"` — a fallback that matters, because a regular app is allowed to have no
// bundle id. The review of the #keeps-5 brief caught the trap before it was written: a guard comparing a raw
// nil-able `bundleIdentifier` would make every window of a bundle-less app permanently fail to match ITSELF.
//
// So the encoding lives here once and both sides call it. Two copies of "the same" rule is how they drift.
import AppKit
import Foundation

public enum AppIdentity {

  /// The snapshot's identity string for an app. `nil` bundle id falls back to the pid — stable within a login
  /// session, which is all the fallback is asked to be (across sessions the #keeps-5 boot gate refuses first).
  public static func encode(bundleId: String?, pid: pid_t) -> String {
    bundleId ?? "pid:\(pid)"
  }

  /// pid → identity for every REGULAR app (the same `activationPolicy` filter capture applies, so restore's
  /// view of "who owns this window" can't include owners capture would never have stored).
  public static func liveMap() -> [pid_t: String] {
    var map: [pid_t: String] = [:]
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      map[app.processIdentifier] = encode(
        bundleId: app.bundleIdentifier, pid: app.processIdentifier)
    }
    return map
  }
}
