# keeps-rbf

A native macOS menu-bar app that remembers where every window lives in each of your monitor setups and
puts them back when your setup changes — right display, right spot, right Space (virtual desktop).

A modern replacement for [Stay](https://cordlessdog.com/keeps/) (unmaintained since 2021), built because
docking/undocking scatters windows onto the wrong displays and desktops, and re-placing ~17 windows by
hand is enough friction to keep you chained to the desk.

> **Status: early, in active development — but the whole loop works and is dogfooded daily.** Silent
> current-Space restore, the one-tap carry for windows stranded on other Spaces, Space-correctness
> guarantees (a silent placement never changes a window's Space), a packaged app whose carry offer
> reaches you as a clickable notification, and live progress + a completion verdict while a carry runs.
> **Landing:** trust on wake/login, and layouts surviving a physical display rearrangement. Solo project
> on the author's machine — not yet something to rely on. See [Status / roadmap](#status--roadmap).

## Quick start

```sh
bash scripts/package-dmg.sh                            # build an installable image → .build/keeps-<version>.dmg
open .build/keeps-*.dmg                                # then drag keeps to Applications, like any Mac app
```

Prefer to run it straight from the build directory? That works too:

```sh
bash scripts/package-app.sh && open .build/keeps.app   # build, sign, launch (look for ▢ in the menu bar)
```

> **On the image you just built:** `package-dmg.sh` signs with whatever certificate is on *your* machine and
> prints an honest STATUS line saying whether the result can open on anyone else's Mac. Signed with an Apple
> Development certificate it installs fine for you and Gatekeeper **blocks it everywhere else** — notarization
> requires a Developer ID certificate, so this is a hard wall, not a flag you can flip. The script climbs to a
> genuinely distributable image the moment such a certificate exists.

1. Click the menu-bar icon → **Save Window Layouts & Spaces** (⌘S) to remember where your windows are.
   keeps remembers one layout *per display setup* — docked and undocked each get their own memory.
2. Change your display setup (dock/undock, plug in a monitor).
3. The windows on the Space you're looking at **snap back on their own** — silent, automatic.
4. If windows are stranded on other Spaces, keeps **offers** — a notification (*"2 windows are on other
   Spaces" → **Bring them back***) and a menu-bar badge (`▢ 2`). Tap it and keeps visibly carries them
   home, animating progress in the menu bar (`◐ 1/2`) and telling you the moment it's done. Moving your
   mouse stops a running carry.
5. Or do it all in one click: **Restore Window Layouts & Spaces** (⌘R) restores silently and flows
   straight into the carry for whatever remains — your click is the consent.

(keeps restores windows *to* their Spaces; it doesn't create or rearrange Spaces themselves.)

First run of the packaged app asks for **Accessibility** once (on your first restore) and **notification
permission** once (on the first offer) — both stick across rebuilds thanks to the signed bundle.

That's the whole loop. *Why* the cross-Space step has to be visible is just below; the full command list
is under [Build & run](#build--run).

## The honest macOS constraint (the interesting part)

If you've tried to build this, you've hit the wall: **macOS has no public API for Spaces (virtual
desktops)**, and since **macOS Sonoma 14.5 (May 2024)** even the private path is gated. A normal app
**cannot silently move another app's window to a background desktop** without disabling SIP and injecting
into Dock (the yabai model) — a `connection_holds_rights_on_window` check in the WindowServer no-ops the
call for any window your connection doesn't own. We confirmed it three ways: direct probes on this
machine, prior art (`tplobo/restore-spaces`, killed at 14.5), and a deep research pass.
**→ [The full investigation](docs/why-macos-window-restore-is-hard.md).**

That one fact shapes the whole product: **cross-Space restore cannot be invisible.** With SIP on (we
never disable it), moving a window to a background Space on its own display means *visibly* switching
there while holding the window — we press its title bar, nudge it a few pixels to prove the window is in
our hand, drive your own macOS Space-switch shortcut, then drop it; a window that doesn't move under the
nudge is left alone and counted. Moving a window to a Space on *another* display uses a second
lever: switch that display's view to the target Space and place the window there via Accessibility —
membership-verified after every move. Because all of this takes over the cursor and flips Spaces,
keeps-rbf never springs it on you: the silent restore runs automatically, and when windows remain
stranded it **offers** (notification + badge) instead of hijacking your screen mid-task. Your explicit
click on **Restore Window Layouts & Spaces** *is* consent, so that one verb finishes the whole job —
and moving your mouse is always the brake. You stay in control; the manual re-placement it replaces is worse.

Display + position + size restore, by contrast, *is* silent (public Accessibility API) — with one
guarantee layered on: **a silent placement never changes a window's Space.** Cross-display placements
must prove the landing Space matches the captured one, are verified after the fact, and are restituted
on violation; anything unprovable defers honestly to the visible carry.

## Status / roadmap

- ✅ **Research** — established what's possible SIP-on (the constraint above)
- ✅ **Capture** — records every window across every Space via private `CGWindowListCopyWindowInfo`
  (not Accessibility — AX can't see background Spaces), keyed per monitor configuration; automatic on a
  settled setup change + menu-bar **Save Window Layouts & Spaces**; unit-tested
- ✅ **Restore — display + position + size (current Space)** — silent, automatic on a setup change,
  via public Accessibility; the daily-drivable first slice
- ✅ **Restore — other Spaces** — the visible carry, offered (notification + badge) after the silent
  restore or flowed into an explicit Restore click; grip-profile same-display carry + view-switch
  cross-display carry, membership-verified, mouse-move abort; **dogfooded daily**
- ✅ **Space correctness** — a silent placement never changes a window's Space (proven, verified,
  restituted on violation); honest deferrals with real counts
- ✅ **Packaged app** — signed `keeps.app`; the carry offer arrives as a clickable notification;
  permissions survive rebuilds
- ✅ **Legible lifecycle** — live progress in the menu bar while a carry runs; a completion verdict
  notification the moment it ends
- ⏳ **Trust on wake/login** — reliability across sleep/wake and login sessions
- ⏳ **Layouts survive rearranging displays** — captured frames are per-arrangement today; after
  physically rearranging or rescaling displays, placement is best-effort until you re-save

Known honest limits today: windows assigned to *All Desktops* are (correctly) left alone; keeps doesn't
re-create Spaces that no longer exist; a hand-rearranged window can be reverted by a re-dock until
capture-on-stable lands; Stage Manager is untested.

## Build & run

Requires **macOS 14+** (developed on macOS 26) and **Swift 6**.

```sh
swift build                                   # plain binary at .build/debug/keeps (no bundle id ⇒ no notifications)
swift test                                    # the unit suite — see the note below on reading its output

bash scripts/package-app.sh                   # build + assemble + codesign .build/keeps.app (debug|release)
open .build/keeps.app                         # run it as a real app (notifications live)
bash scripts/package-dmg.sh                   # wrap that bundle in a drag-to-Applications .dmg

# CLI verification surface (same binary; works unbundled via `swift build` too):
./.build/keeps.app/Contents/MacOS/keeps --capture-once          # snapshot the current layout, print a summary
./.build/keeps.app/Contents/MacOS/keeps --restore-once          # dry-run: print what restore would do (moves nothing)
./.build/keeps.app/Contents/MacOS/keeps --restore-once --apply  # silently restore this Space's windows for real
./.build/keeps.app/Contents/MacOS/keeps --carry-once            # dry-run the cross-Space carry plan
./.build/keeps.app/Contents/MacOS/keeps --print                 # dump the snapshot JSON to stdout
./.build/keeps.app/Contents/MacOS/keeps --watch                 # log each display-reconfig event live
```

**Reading `swift test` output.** The suite is written against **swift-testing**, not XCTest — so every run also
prints XCTest's own summary, `Executed 0 tests, with 0 failures`. That line is truthful (there are no XCTest
tests) and completely misleading. The real result is:

```
􁁛  Test run with 115 tests passed after 0.018 seconds.
```

Trust the exit code and that line. Anything grepping for `Executed N tests` will build a green dashboard that
can never show a test.

**Dogfooding with the trace armed:**

```sh
bash scripts/keeps-relaunch-armed.sh          # relaunch the signed bundle with KEEPS_DEBUG set
```

Run that **from your own terminal**, never from an agent shell or an embedded one. macOS attributes
Accessibility trust to the *launching* app, so keeps launched from a shell that has no AX grant comes up unable
to read or move a single window — and it will look like a keeps bug rather than a launch problem.

Snapshots are written one-per-setup to `~/Library/Application Support/com.rigelblu.keeps/configs/`.
Capture needs no special permission; window *titles* require Screen Recording (optional). **Restore**
moves windows via Accessibility, so the app must be **Accessibility-trusted** (System Settings → Privacy
& Security → Accessibility) — it prompts on first restore and no-ops until granted. The signed bundle
keeps that grant across rebuilds. One nuance for script users: a terminal-exec'd binary rides the
*terminal's* Accessibility grant (macOS attributes trust to the launching app); `open keeps.app` gives
keeps its own.

## Principles

- **Never disable SIP.** The whole point is that it works with macOS's security model intact.
- The private-API surface is quarantined in one module (`CGSPrivate`), so a macOS update breaks one file,
  not the codebase.

## Credit

Standing on the shoulders of the macOS window-management lineage — yabai (koekeishiya), Rectangle
(Ryan Hanson), Amethyst (ianyh), and the Hammerspoon community — whose hard-won scar tissue mapped this terrain.
