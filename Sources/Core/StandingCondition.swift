// StandingCondition — the state class #keeps-20 found missing.
//
// keeps modelled two kinds of status and needed a third. It had TRANSIENT EVENTS (`tick`, a glyph that
// decays back to base after 1.2s) and a RESTING GLYPH (`baseGlyph()`, which knew only about the carry
// offer). A permission that is off is neither: it stays true until the user changes it, and it must not be
// lost by the events that repaint the status item.
//
// The house law was already written, at the Accessibility path: "never a silent do-nothing". The
// notification path skipped it outright — four `guard granted else { return }` sites, all silent, which is
// how #keeps-18's whole promise sat dead for weeks. The Accessibility path only half-kept it: it wrote "!"
// straight onto the status item, unguarded, and the next tick() or badge refresh erased it — leaving a
// confident "▢" while keeps still could not move a single window.
//
// Scope note, so the header does not overclaim the way the first draft did: a standing condition survives
// every RESET to the resting glyph, because the mark lives inside `baseGlyph()`. It is still deliberately
// suppressed WHILE a transient is showing (a 1.2s tick) and while a carry owns the glyph (#keeps-19's
// one-writer rule) — those are the run's turn to speak, and the mark returns when they finish.
//
// This file owns what a standing condition SAYS. The host owns when to ask and how to render.
public enum StandingCondition: Equatable, CaseIterable {

  /// Accessibility is not trusted. Restore and carry both `guard ensureAccessibility()`, so keeps does
  /// nothing at all — which is why this outranks anything about notifications.
  case accessibilityOff

  /// Notifications have never been asked for (`.notDetermined`). `requestAuthorization` genuinely works
  /// from here, so keeps can fix this itself and the label is allowed to be a real command.
  case notificationsNotAsked

  /// Notifications are denied. `requestAuthorization` returns false forever — only the user, in System
  /// Settings, can clear it. The label must therefore never imply keeps will grant it.
  case notificationsDenied

  /// Authorized, but the alert style is "None" — so no banner ever appears. USER-IDENTICAL to denied (the
  /// nudge never shows up), with a different cause and therefore a different fix, which is why it earns its
  /// own line rather than being folded into `.notificationsDenied`.
  ///
  /// Added after review: `setupNotifications`' own comment already named this as one of three distinct
  /// faults that "used to present as the same evidence", and the first draft handled only two of them —
  /// leaving the original #keeps-20 failure mode live for a case the file explicitly enumerated.
  case notificationBannersOff

  // MARK: - What the user can do about it

  /// Who can actually resolve the condition. The distinction is not cosmetic: it decides whether the label
  /// is honest. keeps' agency differs by state, so one label for every state would lie in most of them.
  public enum Remedy: Equatable {
    /// keeps raises the OS prompt itself and the condition can clear without leaving the app.
    case promptInApp
    /// Only System Settings can clear it; keeps can route the user there and nothing more.
    case openSettings(String)
  }

  public var remedy: Remedy {
    switch self {
    case .accessibilityOff:
      // AX exposes no denied-vs-never-asked distinction (`AXIsProcessTrusted()` is a bare Bool), and macOS
      // shows the trust prompt only once per app — so a second prompt may silently do nothing. Settings is
      // the only remedy that always works, so it is the one advertised.
      //
      // The legacy prefPane anchor is deliberate: `/System/Library/PreferencePanes/Security.prefPane` is
      // present on macOS 26.5 and this anchor is the conventional one. The modern id would be
      // `com.apple.settings.PrivacySecurity.extension`. Neither the tests nor `NSWorkspace.open` can detect
      // a stale anchor (open() returns true for any registered scheme regardless of pane validity), so this
      // one is verified by a human scenario, not by the suite — see test-suite/review.md.
      return .openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    case .notificationsNotAsked:
      return .promptInApp
    case .notificationsDenied, .notificationBannersOff:
      return .openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
  }

  /// True only where keeps can actually deliver the thing a verb-first label would promise. The tests assert
  /// the PROPERTY (verb-first iff we can act) rather than the exact strings, so a copy edit doesn't fail the
  /// suite while a dishonest label would.
  public var keepsCanFixItself: Bool {
    if case .promptInApp = remedy { return true }
    return false
  }

  // MARK: - Copy
  //
  // #keeps-16 menu-copy rules carry over: a label states its object first, and a verb-first label is a
  // promise that the click will do the thing. Only `.notificationsNotAsked` earns a verb — it is the one
  // state where keeps can actually deliver.

  public var label: String {
    switch self {
    case .accessibilityOff: return "Accessibility is off — open Settings"
    case .notificationsNotAsked: return "Turn on notifications"
    case .notificationsDenied: return "Notifications are off — open Settings"
    case .notificationBannersOff: return "Notification banners are off — open Settings"
    }
  }

  // MARK: - Ordering

  /// Lower sorts first. Accessibility leads because without it keeps does nothing at all, while
  /// notifications only decide whether it can reach you.
  public var severity: Int {
    switch self {
    case .accessibilityOff: return 0
    case .notificationsNotAsked, .notificationsDenied, .notificationBannersOff: return 1
    }
  }

  /// One line per condition, most severe first — never collapsed into a "2 things need attention" summary,
  /// which would trade a specific fix for an extra click.
  ///
  /// `Array.sorted(by:)` is NOT stable in Swift, so equal severities would otherwise come out in an
  /// unspecified order. Ties break on declaration order to make the result a total, deterministic one —
  /// menu lines that shuffle between reads would be their own defect.
  public static func sorted(_ conditions: [StandingCondition]) -> [StandingCondition] {
    conditions.sorted {
      $0.severity != $1.severity
        ? $0.severity < $1.severity
        : (allCases.firstIndex(of: $0) ?? 0) < (allCases.firstIndex(of: $1) ?? 0)
    }
  }

  /// A stable, greppable name for the trace. Deliberately NOT the label — labels are copy and will be
  /// reworded; a log line that drifts with the copy stops being a fingerprint you can search for.
  public var traceName: String {
    switch self {
    case .accessibilityOff: return "accessibilityOff"
    case .notificationsNotAsked: return "notificationsNotAsked"
    case .notificationsDenied: return "notificationsDenied"
    case .notificationBannersOff: return "notificationBannersOff"
    }
  }

  // MARK: - The resting glyph

  /// The status-bar title at rest. The condition mark LEADS: a permission that is off outranks a pending
  /// count, because the count describes work keeps intends to do and the mark says it cannot.
  ///
  /// Deliberately not "⚠" — that glyph already means *this run had a problem* and it decays. A standing
  /// condition must not wear a transient's glyph.
  public static func glyph(conditions: [StandingCondition], offerCount: Int?) -> String {
    let mark = conditions.isEmpty ? "" : "!"
    guard let n = offerCount else { return mark + "▢" }
    return "\(mark)▢ \(n)"
  }
}
