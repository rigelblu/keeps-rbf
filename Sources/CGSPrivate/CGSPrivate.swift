import ApplicationServices  // AXUIElement / AXError for the AX-to-WindowID bridge
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
private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
/// Per-display managed spaces: each element has "Display Identifier", "Current Space", "Spaces".
public func cgsManagedDisplaySpaces(_ cid: CGSConnectionID) -> [[String: Any]] {
  guard let p = Priv.sym("CGSCopyManagedDisplaySpaces") else { return [] }
  let f = unsafeBitCast(p, to: CopyManagedDisplaySpacesFn.self)
  return (f(cid)?.takeRetainedValue() as? [[String: Any]]) ?? []
}

private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
/// Managed space ids a window belongs to. Mask 0x7 = all space types. count != 1 ⇒ sticky/unattributable.
public func cgsSpacesForWindow(_ cid: CGSConnectionID, _ windowID: CGWindowID) -> [Int] {
  guard let p = Priv.sym("CGSCopySpacesForWindows") else { return [] }
  let f = unsafeBitCast(p, to: CopySpacesForWindowsFn.self)
  let wins = [NSNumber(value: windowID)] as CFArray
  return (f(cid, 0x7, wins)?.takeRetainedValue() as? [Int]) ?? []
}

// MARK: - Synthetic input (the VISIBLE carry — #keeps-12). These are PUBLIC CoreGraphics CGEvent calls, not
// private CGS — but they're quarantined here with the other fragile, OS-coupled mechanism: the navigation +
// title-bar hold/carry is the single thing a macOS release is most likely to break, so it sits in the swappable seam,
// never in Core's pure plan. All visible + cursor-hijacking — only ever called from the deliberate carry sweep.

private func hidMouseSource() -> CGEventSource? {
  let src = CGEventSource(stateID: .hidSystemState)
  src?.setLocalEventsFilterDuringSuppressionState([], state: .eventSuppressionStateSuppressionInterval)
  return src
}

private func postMouse(_ type: CGEventType, at p: CGPoint, source: CGEventSource?) {
  let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
  event?.flags = []
  event?.setIntegerValueField(.mouseEventClickState, value: 1)
  event?.post(tap: .cghidEventTap)
}

/// Post a key chord (down then up) with EXACT flags — fired verbatim from a read symbolichotkeys binding so it
/// carries macOS's stored secondary-Fn bit for arrow bindings and any custom modifiers. Hardcoding the user-visible
/// Control+Arrow shape dropped that stored bit and silently no-op'd the step. The 40ms down→up gap is the
/// synthetic-event settle.
public func postKeyChord(_ keyCode: CGKeyCode, flags: CGEventFlags) {
  let src = CGEventSource(stateID: .hidSystemState)
  let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
  down?.flags = flags
  down?.post(tap: .cghidEventTap)
  usleep(40_000)
  let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
  up?.flags = flags
  up?.post(tap: .cghidEventTap)
}

/// Move the hardware cursor (no buttons) — used to park the cursor on a display before stepping, and to set the
/// known point the drift-abort measures against.
public func moveCursor(to p: CGPoint) {
  postMouse(.mouseMoved, at: p, source: hidMouseSource())
}

/// Begin a title-bar hold: mouse-down on a known draggable point. The caller follows it with `dragHeldWindow`
/// (#keeps-26): a plain hold carries only native titlebars — Tom's #keeps-12 manual check was on those — while a
/// custom titlebar (Zed/GPUI) starts its window move on the first drag event.
/// Returns the parked hold point.
@discardableResult
public func beginWindowGrab(at p: CGPoint) -> CGPoint {
  let src = hidMouseSource()
  postMouse(.mouseMoved, at: p, source: src)
  usleep(80_000)
  postMouse(.leftMouseDown, at: p, source: src)
  usleep(180_000)
  return p
}

/// Continue a held drag to a new point — the #keeps-26 proof drag, posted after `beginWindowGrab`.
public func dragHeldWindow(to p: CGPoint) {
  postMouse(.leftMouseDragged, at: p, source: hidMouseSource())
}

/// Release the synthetic drag (leftMouseUp). MUST run on every carry exit path (`defer`) so a crash / early-return
/// / abort never leaves the mouse button stuck down — the carry's floor "never trap the machine" guarantee.
public func endWindowGrab(at p: CGPoint) {
  postMouse(.leftMouseUp, at: p, source: hidMouseSource())
}

/// The current hardware cursor location — the carry parks the cursor at a known point each step, so a drift from
/// it means the user physically moved the mouse ⇒ abort. Mouse-abort needs no event-tap (proven D3).
public func cursorLocation() -> CGPoint? { CGEvent(source: nil)?.location }

// MARK: - AX → CGWindowID bridge (private _AXUIElementGetWindow; SIP-on; ported from #keeps-1/6 SpikeShared)
private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
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
