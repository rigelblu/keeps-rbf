// swift-tools-version: 6.0
// @keeps-rbf — product code. First real code (#keeps-2, v0.3.0); spikes were throwaway in rb-drive.
// Design: rb-drive/projects/v0.x/plan-execute/keeps-2-feat-capture.md
import PackageDescription

let package = Package(
  name: "keeps",
  platforms: [.macOS(.v14)],
  targets: [
    // The ONE place private SkyLight/CGS fragility is quarantined (Hanson's swappable seam).
    .target(name: "CGSPrivate"),
    // Capture / identity / store / watch over CGSPrivate + public AppKit/CoreGraphics.
    .target(name: "Core", dependencies: ["CGSPrivate"]),
    // The menu-bar host: NSStatusItem app wiring Watcher → Capture → Store.
    .executableTarget(name: "keeps", dependencies: ["Core"]),
    // Pure-logic unit tests (capture filter decisions, fingerprint, store round-trip).
    .testTarget(
      name: "CoreTests", dependencies: ["Core"],
      // #keeps-15: real store files the pure tests resolve against (a checked-in copy — the live store moves).
      resources: [.copy("Fixtures")]),
  ],
  // 1st-pass (make-work): Swift 5 mode skips strict-concurrency checks on the dlopen'd CGS global
  // pointers (as the spike did). 2nd-pass hardening moves this to Swift 6 concurrency.
  swiftLanguageModes: [.v5]
)
