# Shelf Expand / Collapse — Design Spec

**Date:** 2026-05-08

## Overview

Swipe-up on the shelves collapses the hero into a thin compact strip (cover
bleed + title + status), expands the shelf grid from 2×4 to 3×4, and shows
more books at a glance for library-browsing trips. Swipe-down restores the
full hero. State is sticky within a session and resets on KOReader restart.

## Goals

- More books on screen when the user is in "browse mode" rather than
  "I'm reading X" mode.
- Keep the hero discoverable: a thin compact strip remains so the user always
  sees the current book + a clear "expand back" target.
- Auto-restore on shelf-tap so picking a book seamlessly stages it in the
  newly-restored hero, ready to commit to with a second tap on the hero card.

## Non-Goals

- No persistent setting. Mode resets on cold launch.
- No animation between collapsed and expanded states. E-ink waveform tradeoffs
  outweigh the visual polish on a state change.
- No portrait/landscape adaptation in v1. Layout assumes the existing portrait
  Kindle geometry.
- No dedicated UI control (button or toggle). The mode is gesture-driven only.

## Files Changed

- `bookshelf_widget.lua` — `init` (initialise `_expanded`); gesture
  registration (~line 100, add south range); two new gesture handlers; layout
  branch in `_rebuild`; PAGE_SIZE branch in `_swapShelvesInPlace`; shelf-row
  `on_tap` closure update; new helper `_isShelfSwipe`; pass `compact` flag
  through to `_buildHero`.
- `hero_card.lua` — new `compact` field; `_renderCompact()` returns a thin
  strip with cover-bleed + title + status; routed via `init` when
  `self.compact == true`.

No new files.

## State

- `BookshelfWidget.live._expanded` (boolean) — runtime field on the widget
  instance. Initialised `false` in `init()`. Survives `_rebuild` and
  `_swapShelvesInPlace` because the field lives on the persistent live
  instance, not on locals. Cleared on KOReader restart (a fresh widget is
  constructed, init reseeds `false`).

## Gesture wiring

| Direction | Zone     | Behaviour                                      |
|-----------|----------|------------------------------------------------|
| west      | anywhere | next page (existing)                           |
| east      | anywhere | prev page (existing)                           |
| north     | hero     | shoo preview, return-to-current (existing)     |
| north     | shelves  | **NEW:** set `_expanded = true`, `_rebuild`    |
| south     | shelves  | **NEW:** set `_expanded = false`, `_rebuild`   |
| tap       | hero     | open `_preview_book` (existing)                |
| tap       | shelf book (normal)   | `_openBook` (existing)            |
| tap       | shelf book (expanded) | **NEW:** set `_preview_book = b`, clear `_expanded`, `_rebuild` |
| tap       | compact-hero strip    | **NEW:** clear `_expanded`, `_rebuild` |

`_isShelfSwipe(ges)` mirrors `_isHeroSwipe`: returns true when the swipe
origin's y is below the hero region's bottom. The two helpers' zones don't
overlap, so a north swipe routes to exactly one of `onSwipeReturnToCurrent`
(hero zone) or `onSwipeShelvesUp` (shelf zone).

A south-direction GestureRange must be registered in `init` — currently only
west/east/north are wired.

## Layout — `_rebuild` branching

Today, `reserved_h = titlebar + hero_h + chip + label + PAD*4`, with
`shelf_h = floor((screen_h - reserved_h) / 2)`.

When `self._expanded`:

```
compact_hero_h = Screen:scaleBySize(120)   -- thin strip, 120dp
reserved_h     = titlebar + compact_hero_h + chip + label + PAD * 4
shelf_h        = floor((screen_h - reserved_h) / 3)
shelves        = 3 (top, middle, bottom)
PAGE_SIZE      = 12
```

`_rebuild`'s `_buildHero` call passes `compact = self._expanded` so the hero
renders the compact variant. `_buildShelfRows` is called once for each shelf
row; in expanded mode it's called three times (existing pattern just adds a
middle row).

## `HeroCard` compact mode

```lua
HeroCard = InputContainer:extend{
    -- existing fields
    compact = false,  -- new
}

function HeroCard:init()
    -- existing branches: empty / full
    if self.compact and self.book then
        self[1] = self:_renderCompact()
    elseif not self.book then
        self[1] = self:_renderEmpty()
    else
        self[1] = self:_renderFull()
    end
    -- existing gesture wiring (Tap / Hold) unchanged
end
```

`_renderCompact()` returns:

- A `FrameContainer` of size `(self.width, self.height)` where `self.height`
  is the 120dp passed by the widget.
- Inside: a `HorizontalGroup` with two children:
  - **Left:** the cover at its FULL natural height (~600dp) wrapped in an
    `OverlapGroup` with the FrameContainer clipping the top portion. Visual
    effect: cover top half bleeds above the visible strip — only the bottom
    ~120dp slice shows. Implemented by giving the OverlapGroup `dimen.h =
    compact_hero_h` and positioning the SpineWidget at `y = -(cover_h -
    compact_hero_h)`. SpineWidget already paints into the OverlapGroup's
    region; KOReader's blitbuffer auto-clips at the framebuffer edge so the
    overflow doesn't spill into the chip strip below.
  - **Right:** a `VerticalGroup` with the title (top, single-line truncated)
    and status (below, single line). HeroBar / description / metadata /
    author are NOT rendered.

Tap on the compact strip routes to a new callback `on_compact_tap` (set by
the widget) that clears `_expanded` and rebuilds. The existing `on_tap` (open
the previewed book) is reserved for the full-hero variant.

## `_swapShelvesInPlace`

Currently hard-codes `PAGE_SIZE = 8`. Change to:

```lua
local PAGE_SIZE = self._expanded and 12 or 8
```

The shelf-rows-only fast path doesn't reconstruct hero or chips, so toggling
expansion via swipe takes the slower `_rebuild` path. `_swapShelvesInPlace` is
only used for pagination — when a swipe-up triggers expansion the rebuild is
unavoidable (hero changes shape; chip strip and shelf count change).

`_total_pages` recomputes naturally inside `_rebuild`. The `self.page` clamp
already runs at the bottom of the page-count math (`if self.page >
total_pages then self.page = total_pages end`).

## Shelf-row tap closure

Currently:

```lua
on_tap = function(b) self:_openBook(b) end,
```

Updated to:

```lua
on_tap = function(b)
    if self._expanded then
        self._preview_book = b
        self._expanded     = false
        self:_rebuild()
        UIManager:setDirty(self, "ui")
    else
        self:_openBook(b)
    end
end,
```

The on-hold callback (long-press menu) is unaffected and continues to work
in both modes.

## Edge cases

- **Empty shelves:** the swipe handlers no-op when `total == 0`; expanded
  mode would just leave a chip strip + 3 empty rows below the compact hero,
  which reads as "your library is empty" same as the normal mode does today.
  Not worth a special case.
- **Page index after toggle:** `_rebuild` recomputes `total_pages` and clamps
  `self.page`. Going from PAGE_SIZE=8 to 12 may move the user back a page;
  going 12→8 may move them forward. Acceptable — the shelf shifts but the
  active book stays visible (it's the user's own intent that triggered the
  rebuild).
- **No book / "Welcome" hero:** `_renderEmpty` runs even in compact mode
  (the `if self.compact and self.book` branch only fires when `book` is
  set). User in expanded mode without a current book sees the chip strip +
  3 shelves directly under the title bar. Acceptable.
- **`_isHeroSwipe` boundary in expanded mode:** when expanded, the "hero"
  zone is the compact strip (~120dp), not the full hero. `_isHeroSwipe` reads
  the dimen of the rendered hero, so it auto-adapts.

## Testing

No automated tests for the layout — this is `bookshelf_widget` widget logic
and `bookshelf` has no UI test harness for layout.

Manual verification checklist:

1. Bookshelf home, normal mode: confirm hero + 2 shelves + pagination as today.
2. Swipe up on a shelf: hero collapses to compact strip with cover bleed,
   3 shelf rows visible.
3. Swipe down on a shelf: hero restores to full size, back to 2 rows.
4. Swipe up on the hero (full mode): existing "shoo preview" still fires
   (does NOT collapse).
5. Swipe up on the compact strip: NOT a shelf-up swipe, so should NOT toggle.
   (The compact hero is in its own zone via `_isHeroSwipe`.)
6. Tap a shelf book in expanded mode: hero restores, that book is staged in
   the hero as the preview. Tap hero → opens.
7. Tap the compact-hero strip directly: hero restores (no preview change).
8. Switch chip while expanded: chip switches, mode persists (still expanded).
9. Page nav while expanded: pagination works with PAGE_SIZE=12; page numbers
   recomputed.
10. Sort menu while expanded: opens normally, picks re-render the expanded
    layout.
11. Cold restart KOReader: bookshelf opens in normal (non-expanded) mode.
12. Open a book in expanded mode (via tap → restore → tap hero): close the
    book and confirm bookshelf returns to normal mode (per restart rule, the
    in-memory `_expanded` was already cleared by the shelf-book-tap handler).
