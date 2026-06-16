// Shortcuts — the user's ACTUAL Mission-Control key bindings, read from com.apple.symbolichotkeys and replayed
// verbatim. NOT hardcoded: the spikes caught the same bug three times — the UI-visible ⌃→ shortcut is stored with
// macOS's secondary-Fn bit (0x800000), and dropping that bit silently no-ops while ⌥⌘<digit> fires fine. The
// symbolichotkeys modifier mask maps 1:1 onto CGEventFlags (⇧0x20000 ⌃0x40000 ⌥0x80000 ⌘0x100000 secondary-Fn
// 0x800000), so a decoded binding fires AS-IS and carries stored modifiers, custom rebinds, and the enabled bit.
//
// Entry ids (com.apple.symbolichotkeys → AppleSymbolicHotKeys): Switch-to-Desktop N is 117+N (118=desktop 1 …
// 127=desktop 10, 128+=11–16, usually disabled); Move-left/right-a-space are 79 / 81. Each entry is
// { enabled, value: { parameters: [char, keycode, modifierMask] } }. We keep keycode + mask + enabled.
// Pure decode (Scenario C) split from the single CFPreferences read so the bit-mapping is unit-testable.
import Foundation
import CoreGraphics

public struct Shortcuts: Equatable {

    /// A replayable key chord — fired verbatim (keycode + the stored modifier flags).
    public struct Binding: Equatable {
        public let keyCode: CGKeyCode
        public let flags: CGEventFlags
        public let isEnabled: Bool
        public init(keyCode: CGKeyCode, flags: CGEventFlags, isEnabled: Bool) {
            self.keyCode = keyCode; self.flags = flags; self.isEnabled = isEnabled
        }
    }

    public let switchToDesktop: [Int: Binding]   // 1-based desktop number → its ⌥⌘N binding (only bound N present)
    public let moveLeft: Binding?                 // "Move left a space"  (⌃←, id 79)
    public let moveRight: Binding?                // "Move right a space" (⌃→, id 81)

    public init(switchToDesktop: [Int: Binding], moveLeft: Binding?, moveRight: Binding?) {
        self.switchToDesktop = switchToDesktop; self.moveLeft = moveLeft; self.moveRight = moveRight
    }

    /// The enabled ⌥⌘N binding that jumps straight to global desktop `n` — nil if that desktop has no live
    /// (enabled, bound) Switch-to-Desktop shortcut (n > 16, or the user left it off). Drives `unreachableShortcut`.
    public func switchTo(_ n: Int) -> Binding? {
        guard let b = switchToDesktop[n], b.isEnabled else { return nil }
        return b
    }

    /// Adjacent stepping reaches ANY desktop on its display — but only if BOTH directions are bound (a carry may
    /// need to step either way), so this gates the step path.
    public var canStep: Bool { (moveLeft?.isEnabled ?? false) && (moveRight?.isEnabled ?? false) }

    /// At least one direct ⌥⌘N jump is available.
    public var canSwitch: Bool { switchToDesktop.values.contains { $0.isEnabled } }

    /// Both navigation mechanisms dead ⇒ the carry can't move at all → the whole run stops with an honest message
    /// ("Can't navigate desktops — enable Switch-to-Desktop shortcuts"), never a silent do-nothing.
    public var canNavigate: Bool { canStep || canSwitch }
}

extension Shortcuts {

    /// Decode the raw AppleSymbolicHotKeys dict (id-string → entry). Pure — Scenario C feeds it plist fixtures.
    public static func decode(_ hotkeys: [String: Any]) -> Shortcuts {
        func binding(id: Int) -> Binding? {
            guard let entry = hotkeys["\(id)"] as? [String: Any],
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let keyCode = intValue(params[1]), let mask = intValue(params[2]) else { return nil }
            // The mask maps 1:1 onto CGEventFlags — fire it verbatim (this carries stored/custom modifiers).
            return Binding(keyCode: CGKeyCode(keyCode), flags: CGEventFlags(rawValue: UInt64(mask)),
                           isEnabled: boolValue(entry["enabled"]))
        }
        var switchMap: [Int: Binding] = [:]
        for n in 1...16 { if let b = binding(id: 117 + n) { switchMap[n] = b } }   // 118=desktop 1 … 133=desktop 16
        return Shortcuts(switchToDesktop: switchMap, moveLeft: binding(id: 79), moveRight: binding(id: 81))
    }

    /// The one I/O point: read the user's live symbolichotkeys plist (CFPreferences resolves the right domain even
    /// though it's another app's). Decode is pure above.
    public static func live() -> Shortcuts {
        let raw = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                            "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
        return decode(raw)
    }

    // Plist numbers/bools arrive as either Swift scalars or bridged NSNumber depending on the source — coerce both.
    private static func intValue(_ any: Any) -> Int? { (any as? Int) ?? (any as? NSNumber)?.intValue }
    private static func boolValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        return ((any as? NSNumber)?.intValue ?? 0) != 0
    }
}
