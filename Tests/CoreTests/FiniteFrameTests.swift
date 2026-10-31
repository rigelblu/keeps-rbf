// #keeps-38.4 — a window's bounds become a WindowFrame only when every value is a finite number in Int range.
// macOS 27 lists a WindowManager window (layer 17) at (inf, inf, 0, 0); `Int(.infinity)` traps, and every
// Restore and Save reads every window's bounds, so one such window crashed keeps on each click (2026-10-30).
import CoreGraphics
import Testing

@testable import Core

@Suite struct FiniteFrameTests {
  private func info(_ r: CGRect) -> [String: Any] {
    [kCGWindowBounds as String: r.dictionaryRepresentation]
  }

  /// The 2026-10-30 crash, read through the two functions that read every window: no frame, no trap.
  @Test func theWindowManagerWindowAtInfinityHasNoFrame() {
    let atInfinity = CGRect(x: CGFloat.infinity, y: .infinity, width: 0, height: 0)
    #expect(Restore.frame(from: info(atInfinity)) == nil)
    #expect(Capture.frame(from: info(atInfinity)) == nil)
  }

  @Test func aNaNOrOutOfRangeValueHasNoFrame() {
    #expect(WindowFrame(CGRect(x: CGFloat.nan, y: 0, width: 800, height: 600)) == nil)
    #expect(WindowFrame(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 600)) == nil)
    #expect(WindowFrame(CGRect(x: 0, y: 5e9, width: 800, height: 600)) == nil)   // inside Int, outside the bound
    #expect(DisplayBounds(CGRect(x: CGFloat.infinity, y: 0, width: 1800, height: 1169)) == nil)
  }

  /// Every real frame converts exactly as before #keeps-38.4: each value truncated toward zero.
  @Test func aRealFrameConvertsAsBefore() {
    #expect(WindowFrame(CGRect(x: 381.7, y: 286.2, width: 888.9, height: 584)) == WindowFrame(x: 381, y: 286, w: 888, h: 584))
    #expect(WindowFrame(CGRect(x: -5104.5, y: -387, width: 800, height: 600)) == WindowFrame(x: -5104, y: -387, w: 800, h: 600))
    #expect(Restore.frame(from: info(CGRect(x: 0, y: 39, width: 1800, height: 1130))) == WindowFrame(x: 0, y: 39, w: 1800, h: 1130))
    #expect(DisplayBounds(CGRect(x: 0, y: 0, width: 1800, height: 1169)) == DisplayBounds(x: 0, y: 0, w: 1800, h: 1169))
  }
}
