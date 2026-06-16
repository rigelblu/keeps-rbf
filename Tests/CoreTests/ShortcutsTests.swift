// Scenario C made executable — decode com.apple.symbolichotkeys into replayable bindings. macOS stores the
// UI-visible ⌃→ arrow-key bindings with the secondary-Fn bit; dropping that bit silently no-ops, so it's pinned
// red-on-regression. The modifier mask maps 1:1 onto CGEventFlags, which is what lets a decoded binding fire
// verbatim and carry stored/custom modifiers. Pure decode — fed plist-shaped fixtures.
import Testing
import CoreGraphics
@testable import Core

@Suite struct ShortcutsTests {
    // symbolichotkeys entry shape: { enabled, value: { type, parameters: [char, keycode, modifierMask] } }.
    // Masks from the live machine: 8650752 = ⌃(0x40000)+secondary-Fn(0x800000); 1572864 = ⌥(0x80000)+⌘(0x100000).
    private func entry(_ keycode: Int, _ mask: Int, enabled: Bool) -> [String: Any] {
        ["enabled": enabled, "value": ["type": "standard", "parameters": [65, keycode, mask]]]
    }
    private func hotkeys() -> [String: Any] {
        ["81": entry(124, 8650752, enabled: true),    // Move right a space — UI shows ⌃→
         "79": entry(123, 8650752, enabled: true),    // Move left a space  — ⌃←
         "118": entry(18, 1572864, enabled: true),    // Switch to Desktop 1 — ⌥⌘1 (id 117+1)
         "128": entry(29, 1572864, enabled: false)]   // Switch to Desktop 11 — present but DISABLED (id 117+11)
    }

    @Test func decodesMoveRightCarryingSecondaryFnFlag() {   // THE bug class — stored bit must survive decode
        let s = Shortcuts.decode(hotkeys())
        #expect(s.moveRight?.keyCode == 124)
        #expect(s.moveRight?.flags.contains(.maskSecondaryFn) == true)
        #expect(s.moveRight?.flags.contains(.maskControl) == true)
        #expect(s.moveRight?.isEnabled == true)
        #expect(s.moveLeft?.keyCode == 123)
    }

    @Test func decodesSwitchToDesktopModifiers() {   // ⌥⌘1 — command + option, no secondary-Fn
        let s = Shortcuts.decode(hotkeys())
        #expect(s.switchToDesktop[1]?.keyCode == 18)
        #expect(s.switchToDesktop[1]?.flags.contains(.maskCommand) == true)
        #expect(s.switchToDesktop[1]?.flags.contains(.maskAlternate) == true)
        #expect(s.switchToDesktop[1]?.flags.contains(.maskSecondaryFn) == false)
    }

    @Test func disabledBindingReportsUnavailable() {   // a disabled ⌥⌘N drives `unreachableShortcut`
        let s = Shortcuts.decode(hotkeys())
        #expect(s.switchToDesktop[11] != nil)   // decoded (present in the dict)...
        #expect(s.switchTo(11) == nil)          // ...but reported unavailable (it's disabled)
        #expect(s.switchTo(99) == nil)          // never bound
        #expect(s.switchTo(1) != nil)           // enabled
    }

    @Test func navigabilityFromBoundDirections() {
        let s = Shortcuts.decode(hotkeys())
        #expect(s.canStep == true)        // both move-a-space directions enabled
        #expect(s.canSwitch == true)      // at least one ⌥⌘N enabled
        #expect(s.canNavigate == true)
    }

    @Test func emptyBindingsCannotNavigate() {   // neither mechanism bound → the whole run stops honestly
        let s = Shortcuts.decode([:])
        #expect(s.moveLeft == nil && s.moveRight == nil)
        #expect(s.canStep == false)
        #expect(s.canSwitch == false)
        #expect(s.canNavigate == false)
    }

    @Test func onlyStepsWhenSingleDirectionMissing() {   // a carry may step either way — needs BOTH directions
        let oneWay = Shortcuts.decode(["81": entry(124, 8650752, enabled: true)])   // right only
        #expect(oneWay.canStep == false)
    }
}
