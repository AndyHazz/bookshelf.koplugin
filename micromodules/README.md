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
    on_minute = function(ctx) ... end, -- optional: once a minute while on screen, no re-render
    show_settings = function(ctx) ... end, -- optional settings dialog
    -- Hero-grid hints (all optional) -- see "Hero-grid hints" below:
    aspect       = "square",          -- pack as a square (clocks, icon cards)
    min_w        = 2,                 -- smallest size in grid cells (width)
    min_h        = 1,                 -- smallest size in grid cells (height)
    network      = { "api.example.com" }, -- data-source domains; flags network-required
    hero_only    = true,              -- hide from the start-menu picker
    tap_feedback = true,              -- instant pressed border on tap (launchers)
    -- Where it's listed in the Add picker (both optional) -- see "Picker chips":
    pack         = "My Bundle",       -- a chip of its own, shared by the bundle's modules
    category     = "reading",         -- or one of Bookshelf's: shelf, reading, time, fun, actions
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
- `Kit.progressBar{ width, height, fraction }` → the level bar reading_goal and
  battery pass as `bar` (fill in the card's ink, track tinted to match the theme).
- `Kit.shape(width, avail_h)` → `"wide"` / `"tall"` / `"square"` (see aspect).
- `Kit.COLOR_PRIMARY` / `Kit.COLOR_MUTED` / `Kit.CARD_BG` — the shared colour
  roles (primary = the interesting content; muted = headings/hints/timestamps;
  CARD_BG = the grey a `TextBoxWidget` must paint on so it isn't a white bar).

### Simple path (most modules)

Render your content at `scale_pct` (size every font via `Kit.sc`/`Kit.face`) at
its natural height. The host grows/shrinks the card to fill the cell and clips
anything that still overflows. That's it — no `avail_h`, no fit loop. `weather`,
`shelf_size`, `random_unread`, `clock`, `battery` work this way.

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
- `ctx.height` - the cell height (px) the host wants filled, or `nil` (start
  menu: cards take their natural height). Only the advanced path needs it.
  Absence is also what tells `Kit.shape` there is no fixed cell, so never treat
  a ceiling as a height (that's `ctx.max_height`, below).
- `ctx.max_height` - a ceiling (px) on the card's natural height, without
  implying a cell shape. The start menu sets it (one row can never be taller
  than the panel can show); the grids don't, they pass `ctx.height` instead.
  Pass it to `fitText` as `max_h` and the card shrinks-to-fit under the cap
  while still reporting natural height when it already fits.
- `ctx.clamp` - anything past the allowed height WILL be clipped, so if part of
  your card is expendable, truncate it to fit (quote_of_day ellipsises the
  quote so the attribution survives). Sent by the grids' fit engine on its
  last-resort re-render (the card still overflowed `ctx.height` at the smallest
  legible font), and by the start menu on every render alongside
  `ctx.max_height`. Ignoring it keeps the plain clipped behaviour.
- `ctx.refresh` — see **Refreshing after async work**.
- `ctx.shape` — `"wide"` / `"tall"` / `"square"`; see **Aspect** above.
- `ctx.entry` — the hero/menu entry table for THIS card (or `nil` in the picker
  preview). Lets a module store and read PER-INSTANCE config on its own entry,
  so the same module key can appear multiple times with different settings
  (see **Per-instance config** below). Most modules ignore it.
- `ctx.surface` — where you're rendering: `"hero"`, `"fullscreen"`,
  `"shelf"` (among a shelf's books), `"start_menu"`, or `"picker"` (the Add
  preview). Adapt layout if you need to;
  most modules ignore it.
- `ctx.bw`, `ctx.menu` — the bookshelf widget and start menu when available (may
  be `nil`, e.g. in the picker); mainly for `on_tap`.
- `ctx.colors` - your module's own colours (the `colors` spec field, see
  **Colours**), keyed by id, ready to paint: what the reader picked for the
  look on screen, else your defaults. Always a table.
- `ctx.card` - the card your module stands on, for a module that paints a
  card of its own (see **Colours**): `custom` (the reader set this card with
  the palette icon), `bg`, `ink`, `muted`, `border_on` and `border`, ready to
  paint. May be `nil` (the start menu, the picker).

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

For a card that polls (a sensor reading, a feed), declare
`on_minute = function(ctx)` instead. It runs once a minute while the card is on
screen (the hero grid or the full-screen view, current page only; never under
the reader or while the device sleeps), and re-renders nothing by itself: check
whether your data is due, fetch it, and call `ctx.refresh()` only when something
changed, so an unchanged card costs no e-ink refresh. `ctx` carries `entry`,
`config` (read-only), `bw`, `surface` and `refresh`. Keep it cheap and never
block: schedule the fetch.

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
`done(fields)` to seed the new entry, or `done(nil)` to cancel. `done` may be
called later, after async work (a picker, a network fetch); call it exactly
once. Hosts that don't recognise `on_add` just insert the bare entry. See
`action.lua`, `countdown.lua` and `ornament.lua`.

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

- `aspect = "square"` — the card starts as a single square cell when it is
  added (clocks, icon/launcher cards); other cards start two cells wide. Users
  resize either freely afterwards. `ctx.shape` reports the cell's actual aspect
  (see **Aspect** above).
- `bare = true` — draw without the card (no fill, no border), straight onto
  the wallpaper or page, as the Ornament module does. Your render must then
  fit its cell itself: it is centred, not clipped.
- `start_w` / `start_h` — the size, in grid cells, your card starts at when it
  is added (the Ornament module starts at 1 x 1, to fill a small gap). Your
  `min_w` / `min_h` still win. Leave them off for the default above.
- `min_w` / `min_h` — the smallest size, in grid cells, the layout editor lets
  your card be sized to (whole numbers, 1 or more). Use them when the card has
  nothing useful to show below that size. The grid clamps them to its own size,
  so a hint bigger than a small screen's grid still loads. Leave them off and
  the card accepts any size.
- `cache_key = function(entry) return ... end` — in the layout editor each
  module's picture is kept until its own settings, its place or the minute
  change. If yours shows something else that can change meanwhile (the Shelf
  module shows a shelf, edited elsewhere), return a string that changes with
  it.
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

Arrangement is the **host's** job, not yours: in the layout editor (the pencil,
or long-press a card) the user moves, resizes and pages cards on the grid; the
grid renders only the visible page. A module never reads or writes
its page/size/position — just render your content and let the host place it.

## Picker chips (`pack`, `category`)

The Add picker has a chip per group: Bookshelf's categories (Shelf & books,
Reading, Time & device, Fun & info, Actions), one per module pack, and My
modules. A module lands in one of them without saying anything:

- A module from a plugin pack (`bookshelf_modules/` in a `.koplugin`) is
  listed under that plugin's name.
- A module dropped in your own modules folder whose title starts `Name · `
  (for example `"Reading Log · Activity rings"`) is listed under `Name`, with
  every other module that shares the prefix.
- Anything else in your folder is under My modules.

`pack = "Name"` puts a module under its own chip by name, whatever its file
or title; `category = "reading"` (or `shelf`, `time`, `fun`, `actions`)
puts it in one of Bookshelf's.

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

### Per-region taps - `ctx.set_tap_regions` (optional)

A module that shows several discrete things (a row of covers, a list of items)
can make them individually tappable by declaring hit regions during `render`:

```lua
ctx.set_tap_regions({
    { id = "book1", x = 0,   y = 0, w = 90, h = 135 },
    { id = "book2", x = 100, y = 0, w = 90, h = 135 },
})
```

Rects are in the coordinate space of the widget you RETURN from `render`
(its top-left is 0,0) - never screen coordinates. The host owns all geometry:
the cell's painted position, card chrome and the clip container's centring are
translated for you, on every surface (start menu, flyouts, hero,
full-screen), so the same declaration works everywhere. Never reconstruct
screen positions inside a module: render output may be painted into an
offscreen buffer, so render-time coordinates are wrong by construction.

### Widgets with their own taps

The widget you return may also handle taps itself: a `Button`, or any
`InputContainer` with `ges_events`, the way KOReader's own widgets do. The host
passes taps and double taps to it in the frame it was painted in (on a card,
the clip container translates them; see lib/bookshelf_clip_container.lua), and
a tap your widgets don't take still reaches `on_tap`. Long-press and swipes
stay the host's: long-press edits the layout, swipes turn pages. Tap regions
remain the lighter choice for a module of your own; this is for modules built
from ready-made widgets, another plugin's included.

On a card, your widget is painted into an offscreen buffer (that's what keeps a
module inside its cell), so a widget that places a popup from its own position
would put it in the wrong place. Set `in_place = true` and it's painted straight
onto its card instead, the way a `bare` module is: popups land where they
should, but nothing stops it drawing past its cell, so size it to `ctx.width`
and `ctx.height`.

At tap time `on_tap(ctx)` gets `ctx.tapped_region` - the `id` of the first
declared region containing the tap, or `nil`. **Always handle `nil`**: D-pad
centre-key activation, taps outside every region, and modules that declare no
regions all produce it, so treat it as the ordinary whole-card tap. Regions
reset on every render - declare them each time (with rects matching that
render's layout, which may change with `ctx.width`/`ctx.scale`).

"But my size varies with the cell" - it does, and that's fine: your render
COMPUTES its layout from `ctx.width`/`ctx.scale`, so the same arithmetic that
positions a child positions its region. When the fit engine re-renders you at
another scale, you recompute both, and they stay in lockstep:

```lua
render = function(ctx)
    local sc = Kit.sc(ctx.scale)
    local card_w, card_h, gap = sc(90), sc(135), sc(10)
    local group, regions = HorizontalGroup:new{}, {}
    for i, book in ipairs(books) do
        group[#group + 1] = coverCard(book, card_w, card_h)
        regions[#regions + 1] = { id = book.filepath,
            x = (i - 1) * (card_w + gap), y = 0, w = card_w, h = card_h }
    end
    ctx.set_tap_regions(regions)
    return group
end
```

Rather than tracking arithmetic, you can also measure: build the sub-widgets,
ask them `getSize()`, and derive the rects from the measured dimensions before
returning. This mechanism suits GEOMETRIC layouts (a row of covers, a list of
items, a left/right split); it is not for tappable words inside a wrapped
TextBoxWidget, whose internal line geometry you can't cheaply query.
Miscalibration degrades safely: a rect that's slightly off means the tap lands
outside the region, `tapped_region` arrives as `nil`, and your whole-card
fallback runs - a miss, never a wrong-target action.

## Colours

Take colours from `Kit.COLOR_PRIMARY` / `Kit.COLOR_MUTED` (or the equivalents on
`lib/bookshelf_start_menu_modules`) rather than hardcoding Blitbuffer constants,
so every card reads the same and a future contrast control tunes them in one
place. `COLOR_MUTED` is a deliberately dark grey (0x55) — a lighter grey fails on
weaker e-ink panels. A `TextBoxWidget` paints an opaque background, so set its
`bgcolor = Kit.CARD_BG` (fitText does this for you) or the text sits on a white
bar.

The reader can give each module its own card: tap the palette icon in the
layout editor's toolbar for **Card background**, **Card border** (on or off),
**Card border color** and **Card text**, each kept separately for the light and
dark looks and stored on the module. You don't need to do anything for this:
`Kit.CARD_BG`, `Kit.COLOR_PRIMARY` and `Kit.COLOR_MUTED` are pointed at that
card's colours while your module renders. A card with its own background gets
black or white text, whichever reads on it, unless the reader picks a text
colour too.

If your module paints a card of its own over Bookshelf's (its own colours, its
own frame), check `ctx.card.custom`: when it is true the reader has set this
card's colours or border with the palette icon, so draw on `ctx.card` instead
(`bg` and `ink`, and a border of `border` only when `border_on`). Those
settings are meant to reach every module; without this they are hidden under
your card.

Colours of your own (a bar, an accent) can go in the same menu. List them in
the spec, and read them back from `ctx.colors`:

```lua
colors = {
    { id = "bar", text = _("Bar color"),
      default = { hex = "#4A7A9C" },        -- as the reader sees it, light look
      default_dark = { hex = "#9CC4E0" } }, -- and dark look (optional)
},
render = function(ctx)
    local bar = ctx.colors.bar   -- a Blitbuffer colour, ready to paint
    ...
end,
```

`default` and `default_dark` are storage shapes like the Colors menu's:
`{ hex = "#RRGGBB" }` or `{ grey = 0..255 }`. On a greyscale screen a hex
colour is drawn as its grey. Ids may not be `bg`, `border`, `border_color` or
`ink` (the card's own); a spec that breaks this is skipped with a warning in
the log. A bare module (no card) can declare colours too: only its own appear.

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

A file may also return a **list** of specs, `{ spec1, spec2, ... }`: for a pack
that finds out when it loads what it can offer (one module per thing it found,
or an empty list when what it needs isn't installed). Each spec is checked on
its own, and the same rules apply to each.

`key` is a stable API (saved user menus reference modules by it) — pick one and
never change it. For a module shipped in this repo,
`tests/_test_start_menu_modules.lua` auto-checks the contract (including
`summary`, the load-cleanly rule, and the no-`StartMenu._live` rule) on every
file here — you do **not** add it to any list; the test covers it automatically.

## Publishing a module pack (installs and updates on the device)

The drop-in folder above works, but it needs a computer. To let readers install
and update your modules from the device, ship them as a **module pack**: a
small KOReader plugin with a `bookshelf_modules/` folder. KOReader's plugin
stores (App Store, Storefront) already install and update plugins, so a pack
published as one installs and updates with no help from Bookshelf, and
Bookshelf never goes online for it.

```
readinglog.koplugin/
  _meta.lua             -- name, fullname, description, version
  main.lua              -- KOReader needs one; it can do nothing
  bookshelf_modules/
    rings.lua           -- module files, exactly as in the drop-in folder
    week.lua
```

A `main.lua` that does nothing is enough:

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
return WidgetContainer:extend{ name = "readinglog", is_doc_only = false }
```

Bookshelf looks for `bookshelf_modules/` in every plugin folder KOReader loads
from (its own `plugins` folder and any `extra_plugin_paths`), and skips a pack
switched off in KOReader's plugin manager. Module files there follow every rule
in this guide; a pack can keep shared code in a subfolder and `dofile` it from
its module files. Every module file is called with its own folder as `...`
(the drop-in and bundled folders too), so find the shared code from there:

```lua
local MODULE_DIR = ...   -- e.g. .../readinglog.koplugin/bookshelf_modules
local Shared = dofile(MODULE_DIR .. "/../shared/stats.lua")
```

**Precedence.** A module in the user drop-in folder wins over one of the same
key in a pack, and a pack's wins over a bundled one. Keep your keys distinctive
(`readinglog_rings`, not `rings`) so two packs never collide.

**Getting listed.** Publish the pack as a GitHub repository whose release
assets include the `.koplugin` zip:

- App Store finds repositories tagged with the `koreader-plugin` topic.
- Storefront lists plugins from its catalogue; ask its maintainer to add yours.
