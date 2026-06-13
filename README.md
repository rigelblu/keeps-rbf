# stay-rbf

A native macOS menu-bar app that remembers where every window lives in each of your monitor setups and
puts them back when your setup changes — right display, right spot, right virtual desktop.

A modern replacement for [Stay](https://cordlessdog.com/stay/) (unmaintained since 2021), built because
docking/undocking scatters windows onto the wrong displays and desktops, and re-placing ~17 windows by
hand is enough friction to keep you chained to the desk.

> **Status: early, in active development.** The layout **capture** engine works and is unit-tested;
> **restore** is the next slice. Solo-dogfooded on the author's machine — not yet something to rely on.
> See [Status / roadmap](#status--roadmap).

## The honest macOS constraint (the interesting part)

If you've tried to build this, you've hit the wall: **macOS has no public API for Spaces (virtual
desktops)**, and since **macOS Sonoma 14.5 (May 2024)** even the private path is gated. A normal app
**cannot silently move another app's window to a background desktop** without disabling SIP and injecting
into Dock (the yabai model) — a `connection_holds_rights_on_window` check in the WindowServer no-ops the
call for any window your connection doesn't own. We confirmed it three ways: direct probes on this
machine, prior art (`tplobo/restore-spaces`, killed at 14.5), and a deep research pass.
**→ [The full investigation](docs/why-macos-window-restore-is-hard.md).**

That one fact shapes the whole product: **cross-desktop restore cannot be invisible.** With SIP on (we
never disable it), the only way to place a window on a background desktop is to *visibly* switch there and
carry it (synthetic drag + ⌥⌘N). So stay-rbf is **automatic but visible** — on a setup change it cycles
desktops to put windows back: a brief on-screen ritual, not magic behind your back. We decided that's
worth it; the manual re-placement it replaces is worse.

Display + position + size restore, by contrast, *is* silent (public Accessibility API) — that's the
daily-drivable first slice.

## Status / roadmap

- ✅ **Research** — established what's possible SIP-on (the constraint above)
- ✅ **Capture** — records every window across every desktop via private `CGWindowListCopyWindowInfo`
  (not Accessibility — AX can't see background desktops), keyed per monitor configuration; menu-bar
  **Save Workspace Layout**; unit-tested
- ⏳ **Restore — display + position + size** — silent; the daily-drivable slice
- ⏳ **Restore — virtual desktop** — the visible ritual; the full hypothesis
- ⏳ **Triggers + reliability** — dock/undock/wake, ≥95% of windows within ~5s

## Build & run

Requires **macOS 14+** (developed on macOS 26) and **Swift 6**.

```sh
swift build
./.build/debug/stay --capture-once   # snapshot the current layout, print a summary
./.build/debug/stay --print          # dump the snapshot JSON to stdout
./.build/debug/stay                   # run the menu-bar app: "Save Workspace Layout"
```

Snapshots are written one-per-setup to `~/Library/Application Support/com.rigelblu.stay/configs/`.
Capture needs no special permission; window *titles* require Screen Recording (optional).

## Principles

- **Never disable SIP.** The whole point is that it works with macOS's security model intact.
- The private-API surface is quarantined in one module (`CGSPrivate`), so a macOS update breaks one file,
  not the codebase.

## Credit

Standing on the shoulders of the macOS window-management lineage — yabai (koekeishiya), Rectangle
(Ryan Hanson), Amethyst (ianyh), and the Hammerspoon community — whose hard-won scar tissue mapped this terrain.
