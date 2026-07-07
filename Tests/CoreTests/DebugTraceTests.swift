// DebugTrace.displayOf is the one piece of real logic in the diagnostic — which physical display a global frame
// sits on. Get it wrong and the trace would mislabel "landed on LG" vs "off-screen", defeating the diagnosis.
import CoreGraphics
import Testing

@testable import Core

@Suite struct DebugTraceTests {
  // An external LG to the LEFT of the built-in display (negative origin) + the MacBook at the origin.
  private let lg = (uuid: "LG-UUID", bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
  private let mb = (uuid: "MB-UUID", bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))

  @Test func tagsTheDisplayUnderTheWindowCenter() {
    #expect(DebugTrace.displayOf(WindowFrame(x: -1800, y: 100, w: 800, h: 600), in: [lg, mb]) == "LG-UUID")
    #expect(DebugTrace.displayOf(WindowFrame(x: 100, y: 100, w: 800, h: 600), in: [lg, mb]) == "MB-UUID")
  }

  @Test func reportsOffScreenWhenNoDisplayContainsTheCenter() {
    // A frame whose center lands outside every display — the symptom of a coordinate shift on reconnect.
    #expect(DebugTrace.displayOf(WindowFrame(x: 9000, y: 9000, w: 100, h: 100), in: [lg, mb]) == "off-screen")
  }

  // KEEPS_FOCUS lets a dogfood watch one or two apps without closing the rest — it must pass everything when unset,
  // and never let a noise app through when set (else the focused log is back to a wall of text).
  @Test func focusFilterPassesAllWhenUnsetAndMatchesTokensWhenSet() {
    // No filter ⇒ every window traces (KEEPS_FOCUS unset — the default).
    #expect(DebugTrace.matches(tokens: nil, bundleId: "company.thebrowser.dia", title: "New Tab"))
    // A token is a case-insensitive substring of bundleId OR title; a non-match is excluded.
    #expect(DebugTrace.matches(tokens: ["dia"], bundleId: "company.thebrowser.dia", title: nil))
    #expect(DebugTrace.matches(tokens: ["DIA"], bundleId: "company.thebrowser.dia", title: nil))
    #expect(!DebugTrace.matches(tokens: ["dia"], bundleId: "com.google.Chrome", title: "Inbox"))
    // Comma tokens are OR'd — focus on Dia AND Warp in one run (the two apps from the dogfood).
    #expect(DebugTrace.matches(tokens: ["dia", "warp"], bundleId: "dev.warp.Warp-Stable", title: nil))
  }
}
