# Why you can't *silently* restore windows across macOS Spaces

*Findings from building [stay-rbf](../README.md). Version-pinned: macOS 26 (arm64), SIP **on**,
"Displays have separate Spaces" on. The load-bearing change landed in macOS Sonoma 14.5 (May 2024).*

## The itch

[Stay](https://cordlessdog.com/stay/) used to put my windows back when I docked and undocked. It's been
unmaintained since 2021, and it never really handled virtual desktops. My MacBook Pro lives across three
setups — two externals, one external, laptop-only — and every switch scatters ~17 windows (10 Zed, 3 Warp,
4 Chrome…) onto the wrong displays and desktops. Re-placing them by hand is enough friction that I'd avoid
undocking entirely.

So: a small menu-bar app that remembers where every window lived in each setup and *silently* puts them
back. How hard could it be?

The answer is a clean, well-defended "you can't do the silent part" — and the *why* is worth writing down,
because it changed recently and most of what's online predates the change.

## The wall

macOS has **no public API for Spaces** (virtual desktops). You can read and set a window's position and
size through the Accessibility API, but "which Space is this window on?" and "move it to that Space" exist
only in the private CoreGraphics / SkyLight (CGS) layer.

And since **macOS Sonoma 14.5 (May 2024)**, even the private path is gated. `CGSMoveWindowsToManagedSpace`
— the call window managers used to throw a window onto an arbitrary Space — now **silently no-ops for any
window your connection doesn't own.** The WindowServer added a `connection_holds_rights_on_window` check;
the function still exists and returns success, the window just doesn't move. Only **Dock.app's connection
is a "universal owner."** That's why yabai injects a scripting addition into Dock — and why it needs you to
partially disable SIP. No TCC permission (Accessibility, Screen Recording, anything) unlocks it.

## Confirming it three ways

I didn't want to trust a forum post, so I triangulated.

**1 — Direct probe** (this machine, macOS 26, SIP on). A ~50-line Swift probe that `dlopen`s SkyLight and
calls the CGS move:

- Moving *my own* process's window to a background Space: **works.**
- The same call on another app's window (TextEdit): **silently no-ops** (`cross_connection: true`); the
  window stays put. The add/remove pair (`CGSAddWindowsToSpaces` + `CGSRemoveWindowsFromSpaces`) fails
  identically.
- The read-back is trustworthy — `CGSCopySpacesForWindows` is accurate (independently validated) — so
  "didn't move" is real, not a misread.

**2 — Prior art that already died.** `tplobo/restore-spaces` is *exactly* this product: a Hammerspoon tool
to "restore organization of windows throughout spaces," explicitly "no need to disable SIP like yabai." It
used `hs.spaces.moveWindowToSpace`. Documented status: **broke on 14.5**, and on Sequoia 15.0 "not
working… no solutions found." Hammerspoon's own `hs.spaces.moveWindowToSpace` broke at 14.5 and again at
15.0. Someone built my idea; the platform killed it; no fix exists.

**3 — A deep research pass** pinned the mechanism to the 14.5 `connection_holds_rights_on_window` check and
called the empirical result "expected and correct." Pre-14.5 this genuinely *was* possible SIP-on (the old
yabai claims were true then); since 14.5 it isn't.

## Two operations everyone conflates

Here's the subtlety that sent me down a hopeful detour. There are **two** different "move window to Space"
operations, and only one is dead:

- **(A) Silent CGS assignment** (`CGSMoveWindowsToManagedSpace`): places any window on any background Space
  with no visible change. *This is what bulk restore wants. Dead SIP-on since 14.5 for cross-app windows.*
- **(B) Synthetic-input move** (what Raycast / Rectangle Pro / BetterTouchTool do): synthesize the native
  gesture — grab the window's title bar, then fire ⌥⌘N ("Switch to Desktop N"). Works SIP-on via
  Accessibility. But it's **visible** (the screen switches to that desktop), **cursor-hijacking**, one
  window at a time, ~1s each.

I'd assumed (B) was adjacent-only (next/previous Space). It isn't — macOS has direct "Switch to Desktop N"
shortcuts, so a synthetic drag + ⌥⌘N lands a window on an *arbitrary* desktop. So full virtual-desktop
restore IS achievable SIP-on… visibly. A scattered ~17-window restore becomes ~20–25 seconds of the screen
flashing through desktops while the cursor drags windows, and you can't use the machine meanwhile.

## The other doors (all locked)

Before accepting a visible-only restore, I checked the remaining silent paths:

- **Accessibility can't even *see* background desktops.** `kAXWindows` returns only the active Space's
  windows (plus minimized). Windows on other desktops are invisible to AX — you can't enumerate them, let
  alone move them. To see everything, you need private `CGWindowListCopyWindowInfo(.optionAll)`.
- **Private CGS *frame*-move is also dead cross-app.** Maybe I couldn't change a window's Space — but could
  I set its frame on a background desktop silently? `CGSMoveWindow` / `SLSMoveWindow` return success
  (error 0) and move **nothing** for cross-app windows — confirmed across 6/6 apps. Same 14.5 wall,
  different call.

So **no silent cross-app window manipulation survives on current macOS, SIP on**: Space-move ✗, frame-move
✗, AX blind. The only way to touch a window on a background desktop is to *visibly switch to it* first.

## What *does* work, SIP-on

- **Reading** Space state: `CGSCopyManagedDisplaySpaces` (per-display Spaces, each with a persistent
  `uuid`), `CGSCopySpacesForWindows`. Solid and accurate.
- **Position / size / display**, silently: public Accessibility (`kAXPosition`, `kAXSize`). "Different
  display" is just different global coordinates. This is what Stay / Rectangle / Moom already do — and it's
  the daily-drivable half.
- **Virtual-desktop** restore: only the **visible** synthetic ritual (B).

## The honest product call

The dream was invisible. The reality is **silent for display + position + size, visible for the desktop.**
I'm building it anyway, eyes open — a brief visible "putting-things-back" ritual on undock beats
re-placing 17 windows by hand or staying chained to the desk. The app is *automatic but visible*, not
magic behind your back.

[stay-rbf](../README.md) is built on exactly that footing: capture every window across every desktop (via
`CGWindowListCopyWindowInfo`, since AX is blind to the others), then restore — silently where macOS allows,
visibly where it doesn't.

## Caveats

The 14.5 `connection_holds_rights_on_window` wall is the load-bearing fact; if Apple ships a public Spaces
API or changes the rights check, this all moves. The synthetic cross-display landing precision I've only
lightly tested. Everything here is macOS 26, SIP on — corrections and counter-results welcome.

## Credit

The macOS window-management lineage mapped this terrain the hard way: yabai (koekeishiya), Rectangle
(Ryan Hanson), Amethyst (ianyh), and the Hammerspoon community.
