---
title: Changelog
---

# 🔵⋯ [Unreleased]
(none)

# 🔵⋯ v0.9.0 (2026-07-07)
*A running carry is legible end to end: the menu-bar item animates with live progress while keeps works, and a notification delivers the honest verdict the moment it's done — you never open the menu to find out what happened. — `#keeps-19`*

## 🟠⋯ Added
- 2026-07-07 - while a carry runs, the menu-bar item animates with live progress — `◐ 2/5`; static `⟳ 2/5` under Reduce Motion (feat carry signifier) | a glance says it's keeps moving your windows, and how far along [@keeps-rbf]
- 2026-07-07 - a completion notification on every finished carry — brought-back count, "Stopped — 2 of 5" honesty on an abort, "Everything was already in place" when there was nothing to do (feat carry verdict) | know the moment it's done and what actually happened, without opening the menu [@keeps-rbf]

## 🟠⋯ Improved
- 2026-07-07 - notification copy states facts, buttons carry the verbs — "1 window is on another Space" with a count-aware "Bring it back" action, no more question-mark body (fix notification copy) | the offer reads like a system utility, not an unsure app [@keeps-rbf]
- 2026-07-07 - the fulfilled offer notification is withdrawn when its carry completes (fix notifications) | Notification Center never shows a stale offer above a fresh verdict [@keeps-rbf]

# 🔵⋯ v0.8.0 (2026-07-07)
*keeps is a real app now: packaged and signed, so the carry offer reaches you as a clickable notification — not just a menu-bar badge you have to remember to check — and permissions stick across updates. — `#keeps-18`*

## 🟠⋯ Added
- 2026-07-07 - the carry offer arrives as a clickable notification when windows are stranded on other Spaces — tap "Bring them back" and the carry runs (feat offer notification) | the app tells you, you don't poll the badge [@keeps-rbf]
- 2026-07-07 - package as a signed `keeps.app` — `scripts/package-app.sh` builds, assembles, and codesigns with a stable identity (feat packaging) | grant Accessibility once; the grant survives rebuilds [@keeps-rbf]

# 🔵⋯ v0.7.0 (2026-07-07)
*One clear restore action: a single menu verb restores everything — silent placements first, then the visible carry for whatever remains — because your explicit click is the consent. The auto path still only offers. — `#keeps-16`*

## 🟠⋯ Added
- 2026-07-07 - "Restore Window Layouts & Spaces" (⌘R in the menu) runs the whole restore: silent placements flow straight into the visible carry for windows still stranded — moving the mouse stops it (feat one-verb restore) | one click restores everything, Spaces included; no guessing between two restore-ish options [@keeps-rbf]

## 🟠⋯ Improved
- 2026-07-07 - menu pair renamed to "Save / Restore Window Layouts & Spaces" — the object first, the destination second, verbs distinct at the first glyph (feat menu naming) | you know what each item acts on without reading twice [@keeps-rbf]
- 2026-07-07 - the status line speaks only when it has something real to say — last save/restore with a human date, in-flight progress, errors; idle shows nothing (feat status line) | no filler "watching…" message pretending to be information [@keeps-rbf]

## 🟠⋯ Removed
- 2026-07-07 - the separate "Bring back N windows" menu item — the pending-carry badge (`▢ N`) and the notification carry the offer; the one verb does whatever restore is needed (feat menu) | one obvious action instead of two rival ones [@keeps-rbf]

# 🔵⋯ v0.6.0 (2026-07-07)
*Whole-layout restore — the first real MVP: the windows on your current Space still come back silently; the ones stranded on other Spaces are offered back with one tap, with an honest count. — `#keeps-13` + `#keeps-15` slice 2*

## 🟠⋯ Added
- 2026-06-17 - on a monitor-setup change, offer a one-tap carry for the windows on your *other* Spaces — badge + "Bring back N windows on other Spaces" — that visibly carries each back to its Space and restores its frame (feat auto-restore-on-reconfig) | your whole layout returns after a re-dock, not just the Space you're looking at [@keeps-rbf]

## 🟠⋯ Fixed
- 2026-07-07 - the offer count is honest: background windows already home count as correct, and a visible window on the *wrong* Space is noticed even at its captured frame — correctness is frame AND Space (fix idempotence) | the badge number is windows a tap will actually move, no more, no less [@keeps-rbf]

## 🟠⋯ Removed
- 2026-06-17 - the standalone "Restore Desktops" menu item — the carry is offered contextually after a restore instead of being a separate manual action (feat menu) | fewer things to think about; the app tells you when there's a carry to do [@keeps-rbf]

# 🔵⋯ v0.5.0 (2026-07-06)
*Space correctness: your windows return to the right Space too — including across displays — and when keeps can't do that silently it never fakes it; it defers honestly and offers the carry. — `#keeps-17`*

## 🟠⋯ Added
- 2026-07-06 - cross-display Space carry: keeps switches the target display's view to the captured Space and places the window there, verifying membership after every move (feat cross-display carry) | a window that belongs on another display's Space actually lands on that Space, not just that monitor [@keeps-rbf]

## 🟠⋯ Fixed
- 2026-07-06 - a silent placement never changes a window's Space: cross-display placements must prove the landing Space matches, are verified after the fact, and are restituted on violation; unprovable cases defer to the carry (fix space guard) | re-docking never silently teleports a window onto the wrong Space [@keeps-rbf]
- 2026-07-06 - the placement verify polls briefly instead of ruling on an instant read — WindowServer re-homes asynchronously (fix verify timing) | good placements aren't falsely undone [@keeps-rbf]

# 🔵⋯ v0.4.0 (2026-07-06)
*A diagnostic trace for the dogfooding user: see exactly what restore wanted, where each window was, and where it ended up. — `#keeps-14`*

## 🟠⋯ Added
- 2026-07-06 - env-gated per-window trace (`KEEPS_DEBUG=/path`, `KEEPS_FOCUS=app` filter): desired/before/after frames, display-tagged, every carry outcome including fail-closed ones (feat diagnostic trace) | when a window doesn't land where expected, diagnose instead of guess [@keeps-rbf]

# 🔵⋯ v0.3.0 (2026-06-16)
*The first cross-Space mechanism, manual and one window at a time: a visible carry reliable enough to trust, driven through your own macOS shortcuts. — `#keeps-12`*

## 🟠⋯ Added
- 2026-06-16 - visible Space carry with per-app grip profiles derived from real AX window-control geometry: hold the titlebar, switch Spaces through your own macOS shortcut, verify membership, place the frame — fail-closed with a named reason on any doubt, and a physical mouse move aborts (feat grip-profile carry) | windows on other Spaces can be brought home reliably, one at a time, and never behind your back [@keeps-rbf]

# 🔵⋯ [v0.2.0] - 2026-06-14
*Silent restore: the windows on your current desktop come back on their own when your monitor setup changes — right display, position, and size, with nothing to touch. Honest scope — only the windows on the desktop you're looking at; windows on other desktops are next. — `#keeps-3`*

## 🟠⋯ Added
- 2026-06-14 - restore the windows on your current desktop to their captured display, position, and size when your monitor setup changes — silent and automatic, via public Accessibility (feat restore) | re-dock and the windows on the desktop you're looking at snap back to where they belong for that setup, nothing to touch [@keeps-rbf]
- 2026-06-14 - menu-bar "Restore Workspace Layout" — replay the current setup's saved layout on demand (feat menu) | put your windows back without waiting for a setup change [@keeps-rbf]

# 🔵⋯ [v0.1.0] - 2026-06-13
*Capture: the app records where every window lives in each monitor setup, automatically. — `#keeps-2`*

## 🟠⋯ Added
- 2026-06-13 - capture window layout per monitor setup — display, position, size, virtual desktop (feat capture) | the app remembers where every window lived in the setup you're leaving, with no save button to press [@keeps-rbf]
- 2026-06-13 - menu-bar "Save Workspace Layout" (feat menu) | snapshot your current setup on demand, without waiting for it to change [@keeps-rbf]
