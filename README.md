# keeps-rbf

A native macOS menu-bar app that remembers where every window lives in each of your monitor setups and
puts them back when your setup changes — right display, right spot, right virtual desktop.

A modern replacement for [Stay](https://cordlessdog.com/keeps/) (unmaintained since 2021), built because
docking/undocking scatters windows onto the wrong displays and desktops, and re-placing ~17 windows by
hand is enough friction to keep you chained to the desk.

> **Status: early, in active development.** Layout **capture** and **silent restore of the windows on
> your current desktop** both work — unit-tested and dogfooded. Bringing back windows on your *other*
> desktops (Spaces) is the next slice. Solo-dogfooded on the author's machine — not yet something to
> rely on. See [Status / roadmap](#status--roadmap).

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
carry it (synthetic drag + ⌥⌘N). So keeps-rbf is **automatic but visible** — on a setup change it cycles
desktops to put windows back: a brief on-screen ritual, not magic behind your back. We decided that's
worth it; the manual re-placement it replaces is worse.

Display + position + size restore, by contrast, *is* silent (public Accessibility API) — that's the
daily-drivable first slice.

## Status / roadmap

- ✅ **Research** — established what's possible SIP-on (the constraint above)
- ✅ **Capture** — records every window across every desktop via private `CGWindowListCopyWindowInfo`
  (not Accessibility — AX can't see background desktops), keyed per monitor configuration; menu-bar
  **Save Workspace Layout**; unit-tested
- ✅ **Restore — display + position + size (current desktop)** — silent, automatic on a setup change,
  via public Accessibility; the daily-drivable slice. **Scope:** the windows on the desktop you're
  looking at — windows on *other* desktops (Spaces) aren't restored yet (Accessibility can't reach them)
- ⏳ **Restore — other desktops (Spaces)** — a visible carry to bring back the windows not on your
  current desktop, so the whole layout returns; the full hypothesis
- ⏳ **Triggers + reliability** — dock/undock/wake, ≥95% of windows within ~5s

## Build & run

Requires **macOS 14+** (developed on macOS 26) and **Swift 6**.

```sh
swift build
./.build/debug/keeps --capture-once          # snapshot the current layout, print a summary
./.build/debug/keeps --restore-once          # dry-run: print what restore would do (moves nothing)
./.build/debug/keeps --restore-once --apply  # restore the current setup's layout for real
./.build/debug/keeps --print                 # dump the snapshot JSON to stdout
./.build/debug/keeps                          # run the menu-bar app: Save / Restore Workspace Layout
```

Snapshots are written one-per-setup to `~/Library/Application Support/com.rigelblu.keeps/configs/`.
Capture needs no special permission; window *titles* require Screen Recording (optional). **Restore**
moves windows via Accessibility, so the app must be **Accessibility-trusted** (System Settings → Privacy
& Security → Accessibility) — it prompts on first restore and no-ops until granted.

## Principles

- **Never disable SIP.** The whole point is that it works with macOS's security model intact.
- The private-API surface is quarantined in one module (`CGSPrivate`), so a macOS update breaks one file,
  not the codebase.

## Credit

Standing on the shoulders of the macOS window-management lineage — yabai (koekeishiya), Rectangle
(Ryan Hanson), Amethyst (ianyh), and the Hammerspoon community — whose hard-won scar tissue mapped this terrain.
