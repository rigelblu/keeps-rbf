// CGSPrivate — every private SkyLight/CGS call behind a typed seam. The ONE place macOS-version
// fragility lives (port of the proven #keeps-1/#keeps-6 SpikeShared wrappers; dlopen-before-dlsym).
// If a macOS release breaks a private symbol, it breaks here and nowhere else. All read-only, SIP-on.
import Foundation
import CoreGraphics
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
