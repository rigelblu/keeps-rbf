// Scenario A made executable — the carry filter as a truth table, no I/O. Every deferred window maps to exactly
// one of carry / alreadyOnDesktop / targetGone / unreachableShortcut / gone, so a wrong-desktop carry can't slip
// through and no window goes unaccounted. The pure plan computes the TARGET (captured spaceUUID → live global);
// the held-window-follows mechanism is verified live (D2/D3 + Scenario G2), not here.
import Testing
@testable import Core

@Suite struct CarryPlanTests {
    // Same 21-desktop topology as DesktopIndexTests (12 / 5 / 4): d0s4 → global 5, d1s4 → global 17.
    private func index() -> DesktopIndex {
        func display(_ d: Int, _ count: Int) -> DesktopIndex.Display {
            DesktopIndex.Display(identifier: "DISP-\(d)",
                                 spaces: (0..<count).map { DesktopIndex.Space(uuid: "d\(d)s\($0)", managedID: d * 100 + $0) },
                                 currentIndex: 0)
        }
        return DesktopIndex(displays: [display(0, 12), display(1, 5), display(2, 4)])
    }
    private func cap(_ space: String?) -> CapturedWindow {
        CapturedWindow(bundleId: "com.example.app", pid: 42, title: "t", cgWindowId: 1,
                       displayUUID: "DISP-0", desktopOrdinal: 1, spaceUUID: space,
                       frame: WindowFrame(x: 0, y: 0, w: 800, h: 600), spaceIds: [1], sticky: false, onScreen: false)
    }
    private func deferred(_ space: String?, current: Int?) -> Carry.DeferredWindow {
        Carry.DeferredWindow(captured: cap(space), currentGlobalDesktop: current)
    }
    private func binding() -> Shortcuts.Binding { Shortcuts.Binding(keyCode: 0, flags: [], isEnabled: true) }
    private func navAll() -> Shortcuts {   // full navigation: step both ways + ⌥⌘1…10
        Shortcuts(switchToDesktop: Dictionary(uniqueKeysWithValues: (1...10).map { ($0, binding()) }),
                  moveLeft: binding(), moveRight: binding())
    }
    private func jumpsOnly() -> Shortcuts {   // ⌥⌘1…10 but NO stepping — deep desktops become unreachable
        Shortcuts(switchToDesktop: Dictionary(uniqueKeysWithValues: (1...10).map { ($0, binding()) }),
                  moveLeft: nil, moveRight: nil)
    }
    private func plan(_ dw: Carry.DeferredWindow, _ s: Shortcuts) -> Carry.CarryAction {
        Carry.plan(deferred: [dw], spaceIndex: index(), shortcuts: s)[0]
    }

    @Test func carriesWhenTargetResolvesAndReachable() {
        #expect(plan(deferred("d0s4", current: 1), navAll()) == .carry(cap("d0s4"), fromGlobal: 1, toGlobal: 5))
    }

    @Test func skipsAlreadyOnDesktop() {   // current == target → idempotent no-op
        #expect(plan(deferred("d0s4", current: 5), navAll()) == .skip(.alreadyOnDesktop, cap("d0s4")))
    }

    @Test func skipsTargetGoneWhenSpaceUUIDAbsent() {   // captured desktop deleted since capture
        #expect(plan(deferred("ghost", current: 3), navAll()) == .skip(.targetGone, cap("ghost")))
    }

    @Test func skipsTargetGoneWhenNoSpaceUUID() {   // never had a single-desktop anchor
        #expect(plan(deferred(nil, current: 3), navAll()) == .skip(.targetGone, cap(nil)))
    }

    @Test func skipsGoneWhenNoCurrentDesktop() {   // window has no resolvable live desktop (closed/vanished)
        #expect(plan(deferred("d0s4", current: nil), navAll()) == .skip(.gone, cap("d0s4")))
    }

    @Test func skipsUnreachableWhenTargetNeedsUnboundShortcut() {   // global 17 needs stepping; jumpsOnly has none
        #expect(plan(deferred("d1s4", current: 3), jumpsOnly()) == .skip(.unreachableShortcut, cap("d1s4")))
    }

    @Test func reachableByStepEvenWhenJumpUnavailable() {   // ⌃→ stepping reaches any desktop → still carries
        #expect(plan(deferred("d1s4", current: 3), navAll()) == .carry(cap("d1s4"), fromGlobal: 3, toGlobal: 17))
    }

    @Test func everyWindowLandsInExactlyOneBucket() {   // totality — no deferred window goes unaccounted
        let set = [deferred("d0s4", current: 1), deferred("d0s4", current: 5),
                   deferred("ghost", current: 3), deferred("d0s4", current: nil), deferred("d1s4", current: 3)]
        let actions = Carry.plan(deferred: set, spaceIndex: index(), shortcuts: navAll())
        #expect(actions.count == set.count)
    }
}
