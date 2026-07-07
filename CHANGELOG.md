---
title: Changelog
---

# 🔵⋯ [Unreleased]
*Whole-layout restore: the windows on your current desktop still come back silently; the ones stranded on other desktops (Spaces) are now brought back with one tap, so your whole layout returns — not just what you're looking at. Built and passing automated tests; dogfood pending before release.*

## 🟠⋯ Added
- 2026-06-17 - on a monitor-setup change, offer a one-tap carry for the windows on your *other* desktops — "Bring back N windows on other Spaces" (menu item, plus a notification when the app is packaged) — that visibly carries each back to its Space and restores its frame (feat auto-restore-on-reconfig) | your whole layout returns after a re-dock, not just the desktop you're looking at [@keeps-rbf]

## 🟠⋯ Changed
- 2026-06-17 - silent current-desktop restore and the cross-desktop carry are now one flow: "Restore Workspace Layout" restores what it can silently, then offers the carry for the rest — never a surprise cursor takeover (feat menu) | one action restores your whole layout, on your tap [@keeps-rbf]

## 🟠⋯ Removed
- 2026-06-17 - the standalone "Restore Desktops" menu item — the carry is offered contextually after a restore instead of being a separate manual action (feat menu) | fewer things to think about; the app tells you when there's a carry to do [@keeps-rbf]

# 🔵⋯ [v0.2.0] - 2026-06-14
*Silent restore: the windows on your current desktop come back on their own when your monitor setup changes — right display, position, and size, with nothing to touch. Honest scope — only the windows on the desktop you're looking at; windows on other desktops are next.*

## 🟠⋯ Added
- 2026-06-14 - restore the windows on your current desktop to their captured display, position, and size when your monitor setup changes — silent and automatic, via public Accessibility (feat restore) | re-dock and the windows on the desktop you're looking at snap back to where they belong for that setup, nothing to touch [@keeps-rbf]
- 2026-06-14 - menu-bar "Restore Workspace Layout" — replay the current setup's saved layout on demand (feat menu) | put your windows back without waiting for a setup change [@keeps-rbf]

# 🔵⋯ [v0.1.0] - 2026-06-13
*Capture: the app records where every window lives in each monitor setup, automatically.*

## 🟠⋯ Added
- 2026-06-13 - capture window layout per monitor setup — display, position, size, virtual desktop (feat capture) | the app remembers where every window lived in the setup you're leaving, with no save button to press [@keeps-rbf]
- 2026-06-13 - menu-bar "Save Workspace Layout" (feat menu) | snapshot your current setup on demand, without waiting for it to change [@keeps-rbf]
