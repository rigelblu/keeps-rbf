// Scenario A made executable — the carry filter as a truth table, no I/O. Every deferred window maps to exactly
// one of carry / alreadyOnDesktop / targetGone / unreachableShortcut / gone, so a wrong-desktop carry can't slip
// through and no window goes unaccounted. The pure plan computes the TARGET (captured spaceUUID → live global);
// the held-window-follows mechanism is verified live by Tom's one-window #keeps-12 matrix, not here.
import Testing

@testable import Core

@Suite struct CarryPlanTests {
  // Same 21-desktop topology as DesktopIndexTests (12 / 5 / 4): d0s4 → global 5, d1s4 → global 17.
  private func index() -> DesktopIndex {
    func display(_ d: Int, _ count: Int) -> DesktopIndex.Display {
      DesktopIndex.Display(
        identifier: "DISP-\(d)",
        spaces: (0..<count).map {
          DesktopIndex.Space(uuid: "d\(d)s\($0)", managedID: d * 100 + $0)
        },
        currentIndex: 0)
    }
    return DesktopIndex(displays: [display(0, 12), display(1, 5), display(2, 4)])
  }
  private func cap(_ space: String?, sticky: Bool = false, spaces: [Int] = [1]) -> CapturedWindow {
    CapturedWindow(
      bundleId: "com.example.app", pid: 42, title: "t", cgWindowId: 1,
      displayUUID: "DISP-0", desktopOrdinal: 1, spaceUUID: space,
      frame: WindowFrame(x: 0, y: 0, w: 800, h: 600), spaceIds: spaces,
      sticky: sticky, onScreen: false)
  }
  private func deferred(_ space: String?, current: Int?, sticky: Bool = false, spaces: [Int] = [1],
                        liveFrame: WindowFrame? = nil) -> Carry.DeferredWindow
  {
    Carry.DeferredWindow(
      captured: cap(space, sticky: sticky, spaces: spaces), currentGlobalDesktop: current,
      liveFrame: liveFrame)
  }
  private func binding() -> Shortcuts.Binding {
    Shortcuts.Binding(keyCode: 0, flags: [], isEnabled: true)
  }
  private func navAll() -> Shortcuts {  // full navigation: step both ways + ⌥⌘1…10
    Shortcuts(
      switchToDesktop: Dictionary(uniqueKeysWithValues: (1...10).map { ($0, binding()) }),
      moveLeft: binding(), moveRight: binding())
  }
  private func jumpsOnly() -> Shortcuts {  // ⌥⌘1…10 but NO stepping — deep desktops become unreachable
    Shortcuts(
      switchToDesktop: Dictionary(uniqueKeysWithValues: (1...10).map { ($0, binding()) }),
      moveLeft: nil, moveRight: nil)
  }
  private func plan(_ dw: Carry.DeferredWindow, _ s: Shortcuts) -> Carry.CarryAction {
    Carry.plan(deferred: [dw], spaceIndex: index(), shortcuts: s)[0]
  }

  @Test func carriesWhenTargetResolvesAndReachable() {
    #expect(
      plan(deferred("d0s4", current: 1), navAll())
        == .carry(cap("d0s4"), fromGlobal: 1, toGlobal: 5))
  }

  @Test func skipsAlreadyOnDesktop() {  // current == target → idempotent no-op
    #expect(plan(deferred("d0s4", current: 5), navAll()) == .skip(.alreadyOnDesktop, cap("d0s4")))
  }

  // MARK: #keeps-22 — same desktop is not "already home"; correctness is frame AND Space
  //
  // Restore counts a background window as carry work when its frame OR its Space is wrong. The carry used to
  // skip on the Space alone, so a right-Space/wrong-size window was both counted (offer overpromised) and
  // never repaired by anyone — restore can't reach a background window, and the carry walked past it.

  @Test func placesWhenOnTargetDesktopButFrameDrifted() {
    let drifted = WindowFrame(x: 400, y: 300, w: 800, h: 600)  // moved, same size
    #expect(
      plan(deferred("d0s4", current: 5, liveFrame: drifted), navAll())
        == .placeOnly(cap("d0s4"), onGlobal: 5))
  }

  @Test func resizedOnTargetDesktopAlsoPlaces() {
    let resized = WindowFrame(x: 0, y: 0, w: 1200, h: 900)  // same origin, different size
    #expect(
      plan(deferred("d0s4", current: 5, liveFrame: resized), navAll())
        == .placeOnly(cap("d0s4"), onGlobal: 5))
  }

  @Test func matchingFrameOnTargetDesktopIsStillASkip() {  // the genuine no-op — nothing to do
    let same = WindowFrame(x: 0, y: 0, w: 800, h: 600)
    #expect(
      plan(deferred("d0s4", current: 5, liveFrame: same), navAll())
        == .skip(.alreadyOnDesktop, cap("d0s4")))
  }

  @Test func frameWithinToleranceIsNotDrift() {  // ±2px, same as Restore.decide — no rounding thrash
    let jitter = WindowFrame(x: 2, y: -2, w: 798, h: 602)
    #expect(
      plan(deferred("d0s4", current: 5, liveFrame: jitter), navAll())
        == .skip(.alreadyOnDesktop, cap("d0s4")))
  }

  @Test func unknownLiveFrameFailsSafeToSkip() {  // can't prove drift ⇒ don't move the user's screen
    #expect(
      plan(deferred("d0s4", current: 5, liveFrame: nil), navAll())
        == .skip(.alreadyOnDesktop, cap("d0s4")))
  }

  @Test func placeStillNeedsTheDesktopNavigable() {  // placing means navigating the view there first
    let drifted = WindowFrame(x: 400, y: 300, w: 800, h: 600)
    #expect(  // global 17 is beyond ⌥⌘1…10 and stepping is unbound
      plan(deferred("d1s4", current: 17, liveFrame: drifted), jumpsOnly())
        == .skip(.unreachableShortcut, cap("d1s4")))
  }

  @Test func skipsTargetGoneWhenSpaceUUIDAbsent() {  // captured desktop deleted since capture
    #expect(plan(deferred("ghost", current: 3), navAll()) == .skip(.targetGone, cap("ghost")))
  }

  @Test func skipsTargetGoneWhenNoSpaceUUID() {  // never had a single-desktop anchor
    #expect(plan(deferred(nil, current: 3), navAll()) == .skip(.targetGone, cap(nil)))
  }

  @Test func skipsGoneWhenNoCurrentDesktop() {  // window has no resolvable live desktop (closed/vanished)
    #expect(plan(deferred("d0s4", current: nil), navAll()) == .skip(.gone, cap("d0s4")))
  }

  @Test func skipsUnreachableWhenTargetNeedsUnboundShortcut() {  // global 17 needs stepping; jumpsOnly has none
    #expect(
      plan(deferred("d1s4", current: 3), jumpsOnly()) == .skip(.unreachableShortcut, cap("d1s4")))
  }

  @Test func reachableByStepEvenWhenJumpUnavailable() {  // ⌃→ stepping reaches any desktop → still carries
    #expect(
      plan(deferred("d1s4", current: 3), navAll())
        == .carry(cap("d1s4"), fromGlobal: 3, toGlobal: 17))
  }

  @Test func everyWindowLandsInExactlyOneBucket() {  // totality — no deferred window goes unaccounted
    let set = [
      deferred("d0s4", current: 1), deferred("d0s4", current: 5),
      deferred("ghost", current: 3), deferred("d0s4", current: nil), deferred("d1s4", current: 3),
    ]
    let actions = Carry.plan(deferred: set, spaceIndex: index(), shortcuts: navAll())
    #expect(actions.count == set.count)
  }

  @Test func skipsStickyAllDesktopWindowsBeforeAttemptingCarry() {
    #expect(
      plan(deferred("d0s4", current: 1, sticky: true, spaces: [1, 2]), navAll())
        == .skip(.stickyAllDesktops, cap("d0s4", sticky: true, spaces: [1, 2])))
  }

  @Test func runtimeFailureOutcomesStayDistinct() {
    let outcomes: Set<Carry.CarrySkip> = [
      .noCandidateGrip,
      .offDisplayGrip,
      .spaceSwitchFailed,
      .membershipMismatch,
      .axPlaceFailed,
      .userInterrupt,
    ]

    #expect(outcomes.count == 6)
    #expect(outcomes.map(\.rawValue).contains("axPlaceFailed"))
  }

  @Test func carryOwnsAllDeferredReasons() {  // #keeps-17.3 + #keeps-13 dogfood: everything a tap can fix
    #expect(Carry.isCarryDeferred(.skip(.deferredBackground)))
    #expect(Carry.isCarryDeferred(.skip(.deferredCrossDisplay)))
    #expect(Carry.isCarryDeferred(.skip(.deferredWrongSpace)))
    #expect(!Carry.isCarryDeferred(.skip(.unprovableSpace)))  // count-only: no resolvable carry target
    #expect(!Carry.isCarryDeferred(.skip(.offScreenTarget)))  // count-only: #keeps-15 owns the repair
    #expect(!Carry.isCarryDeferred(.skip(.alreadyCorrect)))
    #expect(
      !Carry.isCarryDeferred(.place(WindowFrame(x: 0, y: 0, w: 800, h: 600), verifySpace: false)))
  }
}
