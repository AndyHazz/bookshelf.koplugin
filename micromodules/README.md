# Bookshelf micro-modules

Each `.lua` file here is one micro-module: a small read-only info panel drawn,
from one `render(ctx)`, on any surface -- the home-screen hero grid, the
full-screen micro-module view, and the start menu (`ctx.surface` says which). The
file returns a spec table:

```lua
return {
    key   = "my_module",          -- stable id stored in user menus (never change)
    title = _("My module"),       -- shown in the Add picker
    summary = _("Open-Meteo. Needs internet."), -- one line under the title in the
                                  -- picker: data source + connectivity
                                  -- ("… Works offline." / "Needs internet.")
    -- render(ctx) -> widget | nil  (ctx fields under "the context table" below)
    render = function(ctx) ... end,
    on_tap = function(ctx) ... end,   -- optional tap action
    keep_open = true,                 -- optional: tap acts without closing the menu
                                      -- (or a function(ctx) -> bool, resolved at tap time)
    wants_minute_tick = true,         -- optional: re-render every minute (clocks)
    show_settings = function(ctx) ... end, -- optional settings dialog
    -- Hero-grid hints (all optional) -- see "Hero-grid hints" below:
    aspect       = "square",          -- pack as a square (clocks, icon cards)
    network      = { "api.example.com" }, -- data-source domains; flags network-required
    hero_only    = true,              -- hide from the start-menu picker
    tap_feedback = true,              -- instant pressed border on tap (launchers)
}
```

## The one thing to understand: who sizes your card

**The host owns SIZE. You own CONTENT.** The hero grid renders your module into
a cell and then *grows or shrinks the whole card* (by re-rendering you at
different `scale_pct`) until it fills its cell, clipping as a hard backstop. So
you do **not** write your own font loop — render once at the `scale_pct` you're
handed, and the host makes it fit. This is why every module looks right at every
cell size without each author solving it again.

Use the shared kit to size fonts and build common pieces:

```lua
local Kit = require("lib/bookshelf_module_kit")
```

- `Kit.sc(scale_pct)` → `function(n)` — scaled, rounded pixel size (floored at 1).
- `Kit.face(size, scale_pct, opts)` → a `cfont` face scaled by `scale_pct`
  (`opts` = `{bold=true}` / `{italic=true}`; returns `face[, bold]`).
- `Kit.fitText{ text, size, scale_pct, width, max_h, fgcolor, bgcolor, align, opts }`
  → a `TextBoxWidget` for a flexible text block (see the advanced path).
- `Kit.valueCard{ width, scale_pct, heading, value, suffix, bar, sub, context }`
  → the standard "heading + big value + bar + sub + context" stat card (what
  reading_goal and reading_stats use — match it for visual consistency).
- `Kit.shape(width, avail_h)` → `"wide"` / `"tall"` / `"square"` (see aspect).
- `Kit.COLOR_PRIMARY` / `Kit.COLOR_MUTED` / `Kit.CARD_BG` — the shared colour
  roles (primary = the interesting content; muted = headings/hints/timestamps;
  CARD_BG = the grey a `TextBoxWidget` must paint on so it isn't a white bar).

### Simple path (most modules)

Render your content at `scale_pct` (size every font via `Kit.sc`/`Kit.face`) at
its natural height. The host grows/shrinks the card to fill the cell and clips
anything that still overflows. That's it — no `avail_h`, no fit loop. `weather`,
`shelf_size`, `random_unread`, `clock` work this way.

### Advanced path (height-aware / flexible text)

If you have a long text block that should fill the cell and truncate gracefully
at the extreme, render it with `Kit.fitText` and pass `max_h` = the room left in
the cell:

```lua
render = function(ctx)
    local width, scale_pct, avail_h = ctx.width, ctx.scale, ctx.height
    local Kit = require("lib/bookshelf_module_kit")
    local fixed = buildHeaderEtc(...)            -- the non-flexible parts
    local max_h = (avail_h and avail_h > 0)
        and math.max(1, avail_h - fixed:getSize().h) or nil
    local body = Kit.fitText{ text = longText, size = 16, scale_pct = scale_pct,
        width = math.max(50, width), max_h = max_h }
    return VerticalGroup:new{ align = "left", fixed, body }
end
```

`fitText` reports its **natural** height when the text fits within `max_h` (so
the host's grow can still enlarge the font), and ellipsis-clamps to `max_h` only
at the extreme. Do **not** run your own scale loop — it fights the host's.

**Pass `max_h` only to protect *other* parts of the card.** `trivia` does: it
reserves room for the answer options, so a very long question ellipsis-clamps
rather than pushing the options off. But if the flexible text *is* the whole
card (e.g. `quote_of_day`), **omit `max_h`** and return the text at its natural
height — clamping it would make the card "fit" by truncating, so the host would
never see the overflow and never shrink the font. Without the clamp the host
shrinks the font to fit and only clips at the very extreme.

### Aspect (optional `shape`)

`ctx.shape` is `"wide"`, `"tall"`, or `"square"` (from the cell's aspect). Use it
to pick a *layout* (not just a font size) — e.g. lay two columns side-by-side in
a wide cell, stacked otherwise. Derive it yourself if it's absent:
`local shape = ctx.shape or Kit.shape(ctx.width, ctx.height)`. Most modules
ignore it and still fit via the size engine; see `reading_stats` for a reference
reflow.

## `render(ctx)` — the context table

`render`, `on_tap` and `show_settings` all receive the same `ctx` table. The
fields `render` reads:

- `ctx.width` — inner width (px) for your content.
- `ctx.scale` — the font scale to size against (`100` = normal). The host
  raises/lowers it to fit your card; size every font with it via `Kit.sc`/`Kit.face`.
- `ctx.preview` — `true` only in the Add picker; render a compact thumbnail and
  (see below) do NOT start any network fetch.
- `ctx.height` — the cell height (px) the host wants filled, or `nil` (start menu
  / no height constraint). Only the advanced path needs it.
- `ctx.clamp` — `true` only on the fit engine's last-resort re-render: the card
  still overflowed `ctx.height` at the smallest legible font, so anything past
  the cell bottom WILL be clipped. If part of your card is expendable, truncate
  it to fit `ctx.height` (quote_of_day ellipsises the quote so the attribution
  survives). Ignoring it keeps the plain clipped behaviour.
- `ctx.refresh` — see **Refreshing after async work**.
- `ctx.shape` — `"wide"` / `"tall"` / `"square"`; see **Aspect** above.
- `ctx.entry` — the hero/menu entry table for THIS card (or `nil` in the picker
  preview). Lets a module store and read PER-INSTANCE config on its own entry,
  so the same module key can appear multiple times with different settings
  (see **Per-instance config** below). Most modules ignore it.
- `ctx.surface` — where you're rendering: `"hero"`, `"fullscreen"`,
  `"start_menu"`, or `"picker"` (the Add preview). Adapt layout if you need to;
  most modules ignore it.
- `ctx.bw`, `ctx.menu` — the bookshelf widget and start menu when available (may
  be `nil`, e.g. in the picker); mainly for `on_tap`.

A common first line just pulls what you need:
`local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh`.

## Refreshing after async work

If your module loads data asynchronously (a network fetch) and must redraw when
it lands, **capture the `refresh` callback in `render` and call it** from your
async completion:

```lua
local _refresh  -- module upvalue
...
render = function(ctx)
    _refresh = ctx.refresh
    if needFetch() and not ctx.preview then
        fetchAsync(function(ok) if ok and _refresh then _refresh() end end)
    end
    return buildWidget()
end,
```

`refresh()` re-renders only *your* card and scopes the e-ink update to it.

**Never use `StartMenu._live` / `StartMenu._live:_reload()`, and never call
`UIManager:setDirty(...)` yourself.** `StartMenu._live` only exists while the
start menu is open — in the hero grid it is nil, so your refresh silently no-ops
there. The `refresh` arg works in both. This is enforced by
`tests/_test_module_contract.lua`, which fails the suite if any module
references `StartMenu._live`. The same applies to taps/settings: rely on the
automatic reload after a `keep_open` tap, and call `ctx.menu:_reload()` from
`show_settings`.

`refresh` may be `nil` if an older host renders you, so guard:
`if _refresh then _refresh() end`.

Set `wants_minute_tick = true` if your card shows wall-clock time (a clock): the
hero re-renders it once a minute (scoped) so it stays current. Read the time in
`render` as usual.

## Storing settings

Two kinds of settings, two APIs. **Neither writes the main `bookshelf.lua`** —
per-instance config rides on the card's entry, and shared/module data lives in a
separate `bookshelf_micromodules.lua` file.

### Per-instance config — `ctx.config`

For a module addable multiple times with **different settings each** (e.g. the
`action` launcher, or `countdown`'s date + label). Use `ctx.config`, a handle
over fields on this card's entry:

```lua
render = function(ctx)
    local label = ctx.config:get("label", "Countdown")   -- read (default if unset)
    ...
end,
show_settings = function(ctx)
    ctx.config:set("label", newLabel)   -- write + persist + reload this card
end,
```

`:get(name, default)` reads; `:set(name, value)` / `:delete(name)` write and
persist (only in `on_tap`/`show_settings` — in `render` the config is read-only,
so `:set` there is a no-op). Config travels with the card and is removed when the
card is deleted — no orphans. To configure a module interactively at add time,
declare `on_add = function(host_ctx, done)`: gather fields and call
`done(fields)` to seed the new entry, or `done(nil)` to cancel. Hosts that don't
recognise `on_add` just insert the bare entry. See `action.lua` and
`countdown.lua`.

(Under the hood this is the entry table + a host save; you can still read raw
fields off `ctx.entry` if you need to, but `ctx.config` is the supported path.)

### Shared / cache data — `Kit.moduleStore(key)`

For data shared by **all instances** of a module (a per-type default) or a
**fetch cache** (weather, on-this-day). Namespaced by module key, backed by the
separate file:

```lua
local store = require("lib/bookshelf_module_kit").moduleStore("weather")
store:set("data", fetched)          -- store:get(name, default) / :delete(name)
```

Don't reach for `lib/bookshelf_settings_store` or hand-built `micromodule_<key>_*`
keys directly — `moduleStore` is the clean wrapper (and existing modules using
those keys are transparently routed to the same file).

## No blocking work on render

`render` runs on every menu/hero paint, on the UI thread. **Never block it** —
no synchronous network, no slow sqlite. Cache slow reads behind a TTL (see
`reading_stats.lua`), and do network fetches in a `UIManager:scheduleIn` task
that calls `refresh()` when it lands. **Guard network behind `not preview`** —
the Add picker renders *every* registered module's preview, so an unguarded
fetch fires a burst of network calls (and has crashed the picker before). A
broken `render` is `pcall`'d and skipped, so it won't take down the menu — but a
blocking one will freeze the UI.

## Hero-grid hints (optional spec fields)

These tune how a module behaves in the home-screen hero grid. All are optional;
omit them and you get the sensible default (a flex/text card offered everywhere).

- `aspect = "square"` — pack this card as a square (the grid fits more per row
  and centres your content) instead of letting it stretch across the row. Use it
  for clocks and icon/launcher cards; leave it off for text cards, which should
  fill the row width. The 6th `render` arg `shape` reports the resulting cell
  aspect (see **Aspect** above).
- `network = { "host", ... }` — the data-source domains your module fetches from.
  Declaring it marks the module network-required: the Add picker shows a
  "Network required / Data provided by: …" panel for it instead of live-rendering
  a preview, so browsing the picker never fires a fetch. Pair it with a `summary`
  that ends in "Needs internet."
- `hero_only = true` — the module only makes sense in the hero grid (e.g.
  `action`, a launcher); it's hidden from the start-menu module picker.
- `tap_feedback = true` — draw an instant pressed border when the card is tapped,
  for launcher-style cards that *do* something on tap. Leave it off for passive
  cards (a tap that only re-rolls or does nothing shouldn't flash a border).

Arrangement is the **host's** job, not yours: the user moves a card, resizes its
width, and assigns it to one of the grid's pages from the long-press menu; the
grid paginates and renders only the visible page. A module never reads or writes
its page/size/position — just render your content and let the host place it.

## `summary`

A one-line string shown under the title in the Add picker, stating where the
data comes from and whether it needs internet:
`"Open-Meteo. Needs internet."`, `"Device clock. Works offline."`,
`"From your library. Works offline."`. Required for shipped modules (the
contract test checks for it).

## `on_tap` / `show_settings`

`on_tap(ctx)` and `show_settings(ctx)` receive the same `ctx` as `render`
(above): `ctx.bw`, `ctx.menu`, `ctx.entry`, `ctx.surface`, plus `ctx.config` for
per-instance settings (and `ctx.save()`, the lower-level persist it wraps). By
default a tap closes the menu then runs `on_tap`. With `keep_open = true` the
menu stays open: `on_tap(ctx)` runs, then the card reloads **automatically** — do
NOT call `ctx.menu:_reload()` yourself inside `on_tap`. `keep_open` may be a
`function(ctx) -> bool` evaluated at tap time. `show_settings(ctx)` adds a
"Module settings…" row to the long-press dialog; persist per-instance settings
via `ctx.config` and shared/per-type settings via `Kit.moduleStore` (see
**Storing settings** above). The loader exports `menu_generation`, a counter
bumped once per menu open that modules may key per-open caches on.

On physical-button (D-pad) devices the host draws the focus ring and handles
grid navigation; the same `on_tap` fires when the focused card is activated with
the centre key, and `show_settings` via the hold key. A module needs no d-pad
code of its own.

## Colours

Take colours from `Kit.COLOR_PRIMARY` / `Kit.COLOR_MUTED` (or the equivalents on
`lib/bookshelf_start_menu_modules`) rather than hardcoding Blitbuffer constants,
so every card reads the same and a future contrast control tunes them in one
place. `COLOR_MUTED` is a deliberately dark grey (0x55) — a lighter grey fails on
weaker e-ink panels. A `TextBoxWidget` paints an opaque background, so set its
`bgcolor = Kit.CARD_BG` (fitText does this for you) or the text sits on a white
bar.

## Translations

Wrap user-visible strings in `_("...")` with a string **literal** — the file has
`_ = require("lib/bookshelf_i18n").gettext` in scope, and the `.pot` is extracted
by scanning for literal `_("...")` calls. `_()` on a variable is NOT extracted.
For locale-aware dates use `os.date("%B")` rather than a hand-rolled name table
(see `clock.lua`).

## Adding a module (drop-in)

Drop a `.lua` file with a unique `key` into one of two places — there's no
registry or list to edit:

- **`micromodules/`** (this folder, bundled with the plugin) — for a module you
  want to contribute upstream via a PR.
- **`<koreader settings>/bookshelf/micromodules/`** — a user dir scanned first,
  OUTSIDE the plugin, so your module survives a plugin update. A file here with
  the same `key` as a bundled one *overrides* it — handy for iterating on a
  shipped module locally.

That's the whole registration step. The loader discovers, validates and
registers every `.lua` file in both dirs; an invalid spec (bad/missing
`key`/`title`/`render`, or a wrong-typed optional field) is logged and skipped,
and a `render` that errors is contained — it never takes down the menu or hero.

`key` is a stable API (saved user menus reference modules by it) — pick one and
never change it. For a module shipped in this repo,
`tests/_test_start_menu_modules.lua` auto-checks the contract (including
`summary`, the load-cleanly rule, and the no-`StartMenu._live` rule) on every
file here — you do **not** add it to any list; the test covers it automatically.
