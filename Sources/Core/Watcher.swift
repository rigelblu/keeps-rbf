import CoreGraphics
// Watcher — registers for display-reconfiguration events and forwards them to a handler.
// Gate 1 (resolved 2026-06-13): the reconfig event DOES fire in-app, but by the `begin` callback the config
// fingerprint has already flipped to the new config — so capture-on-leave is impossible; the host debounces
// each event and captures the current *stable* config instead. The Watcher stays forward-only by design: it
// owns no capture policy — the host (menu-bar app) decides (debounced auto-capture + manual Save).
import Foundation
import os

public final class Watcher {
  private let log = Logger(subsystem: "com.rigelblu.keeps", category: "Watcher")
  private let handler: (CGDisplayChangeSummaryFlags, CGDirectDisplayID) -> Void

  public init(_ handler: @escaping (CGDisplayChangeSummaryFlags, CGDirectDisplayID) -> Void) {
    self.handler = handler
  }

  public func start() {
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    let err = CGDisplayRegisterReconfigurationCallback(
      { display, flags, ctx in
        guard let ctx else { return }
        Unmanaged<Watcher>.fromOpaque(ctx).takeUnretainedValue().handler(flags, display)
      }, ctx)
    log.info("watcher registered (err=\(err.rawValue), automatic trigger Gate-1-pending)")
  }
}
