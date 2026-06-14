import ApplicationServices  // AXUIElement / AXError for the AX→CGWindowID bridge
import CoreGraphics
// CGSPrivate — every private SkyLight/CGS call behind a typed seam. The ONE place macOS-version
// fragility lives (port of the proven #keeps-1/#keeps-6 SpikeShared wrappers; dlopen-before-dlsym).
// If a macOS release breaks a private symbol, it breaks here and nowhere else. All read-only, SIP-on.
import Foundation
import os

public typealias CGSConnectionID = Int32

private let log = Logger(subsystem: "com.rigelblu.keeps", category: "CGSPrivate")

// MARK: - Private framework loader
// RTLD_DEFAULT only searches already-loaded images; SkyLight isn't loaded into a fresh process, so a
// NULL there means "not loaded", not "absent". dlopen SkyLight first, then fall back to loaded images.
private enum Priv {
  static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
  static let skylight: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

  static func sym(_ name: String) -> UnsafeMutableRawPointer? {
    if let h = skylight, let p = dlsym(h, name) { return p }
    return dlsym(rtldDefault, name)
  }
}

// MARK: - Connection
private typealias MainConnFn = @convention(c) () -> CGSConnectionID
public func cgsMainConnection() -> CGSConnectionID {
  guard let p = Priv.sym("CGSMainConnectionID") else {
    log.error("CGSMainConnectionID unresolved — SkyLight load failed")
    return 0
  }
  return unsafeBitCast(p, to: MainConnFn.self)()
}

// MARK: - Spaces (read-only; proven SIP-on in #keeps-1)
private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<
  CFArray
>?
/// Per-display managed spaces: each element has "Display Identifier", "Current Space", "Spaces".
public func cgsManagedDisplaySpaces(_ cid: CGSConnectionID) -> [[String: Any]] {
  guard let p = Priv.sym("CGSCopyManagedDisplaySpaces") else { return [] }
  let f = unsafeBitCast(p, to: CopyManagedDisplaySpacesFn.self)
  return (f(cid)?.takeRetainedValue() as? [[String: Any]]) ?? []
}

private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) ->
  Unmanaged<CFArray>?
/// Managed space ids a window belongs to. Mask 0x7 = all space types. count != 1 ⇒ sticky/unattributable.
public func cgsSpacesForWindow(_ cid: CGSConnectionID, _ windowID: CGWindowID) -> [Int] {
  guard let p = Priv.sym("CGSCopySpacesForWindows") else { return [] }
  let f = unsafeBitCast(p, to: CopySpacesForWindowsFn.self)
  let wins = [NSNumber(value: windowID)] as CFArray
  return (f(cid, 0x7, wins)?.takeRetainedValue() as? [Int]) ?? []
}

// MARK: - AX → CGWindowID bridge (private _AXUIElementGetWindow; SIP-on; ported from #keeps-1/6 SpikeShared)
private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) ->
  AXError
/// Turn an AXUIElement into its CGWindowID — the keystone that lets #keeps-3 restore key a live AX window by
/// the same `cgWindowId` capture recorded. nil if the private symbol is unresolved or the call errors.
public func axWindowID(_ element: AXUIElement) -> CGWindowID? {
  guard let p = Priv.sym("_AXUIElementGetWindow") else { return nil }
  let f = unsafeBitCast(p, to: AXGetWindowFn.self)
  var wid: CGWindowID = 0
  return f(element, &wid) == .success ? wid : nil
}

// MARK: - Seam health (#keeps-2 review, 2026-07-27)

/// Whether the private space lookups resolve at all — and says so out loud when they don't.
///
/// Both space functions return `[]` on an unresolved symbol, which is indistinguishable from "this window is
/// on no space". So a SkyLight symbol renamed by an OS update would make every window read as space-less, the
/// capture sweep would drop them all "correctly" as `.noSpace`, and a valid-looking EMPTY snapshot would be
/// written over a config's only good copy while the menu ticked a checkmark. Silent, and it destroys data.
/// `Capture` folds this into `readFailed`, which already refuses to persist for `cid == 0`.
///
/// Called once per capture, so the two `dlsym` lookups are noise next to the sweep — and the log lines fire
/// only in the case that actually matters.
public var cgsSpaceLookupAvailable: Bool {
  guard Priv.sym("CGSCopyManagedDisplaySpaces") != nil else {
    log.error("CGSCopyManagedDisplaySpaces unresolved — desktop attribution is dead; refusing to persist")
    return false
  }
  guard Priv.sym("CGSCopySpacesForWindows") != nil else {
    log.error("CGSCopySpacesForWindows unresolved — every window reads as space-less; refusing to persist")
    return false
  }
  return true
}
