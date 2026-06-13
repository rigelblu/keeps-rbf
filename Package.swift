// swift-tools-version: 6.0
// @stay-rbf — product code. First real code (#stay-2, v0.3.0); spikes were throwaway in .rb-drive.
// Design: .rb-drive/projects/v0.x/plan-execute/stay-2-feat-capture.md
import PackageDescription

let package = Package(
    name: "stay",
    platforms: [.macOS(.v14)],
    targets: [
        // The ONE place private SkyLight/CGS fragility is quarantined (Hanson's swappable seam).
        .target(name: "CGSPrivate"),
        // Capture / identity / store / watch over CGSPrivate + public AppKit/CoreGraphics.
        .target(name: "Core", dependencies: ["CGSPrivate"]),
        // The menu-bar host: NSStatusItem app wiring Watcher → Capture → Store.
        .executableTarget(name: "stay", dependencies: ["Core"]),
        // Pure-logic unit tests (capture filter decisions, fingerprint, store round-trip).
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ],
    // 1st-pass (make-work): Swift 5 mode skips strict-concurrency checks on the dlopen'd CGS global
    // pointers (as the spike did). 2nd-pass hardening moves this to Swift 6 concurrency.
    swiftLanguageModes: [.v5]
)
