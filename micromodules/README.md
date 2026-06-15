# Bookshelf micro-modules

Each `.lua` file here is one micro-module: a small read-only info panel.
The file must return a spec table:

```lua
return {
    key   = "my_module",          -- stable id stored in user menus
    title = _("My module"),       -- shown in the Add dialog
    -- render(width, scale_pct, preview, avail_h, refresh) -> widget | nil
    render = function(width, scale_pct, preview, avail_h, refresh) ... end,
    on_tap = function(ctx) ... end,   -- optional tap action
    keep_open = true,                 -- optional: tap acts without closing the menu
                                      -- (or a function(ctx) -> bool, resolved at tap time)
    wants_minute_tick = true,         -- optional: re-render every minute (clocks)
    show_settings = function(ctx) ... end, -- optional settings dialog
}
```

`render` is called with:

- `width` - the inner width (px) available to your content.
- `scale_pct` - the font scale to size text against (`100` = normal). The host
  may raise/lower it so the card fills its space; size every font with it (e.g.
  `math.floor(14 * scale_pct / 100 + 0.5)`).
- `preview` - `true` only in the Add-module picker; render a compact, fixed-size
  thumbnail (e.g. the analogue clock forces its small face) so a big square
  doesn't overflow the chooser cell.
- `avail_h` - the cell height (px) the host wants filled, or `nil` when there's
  no height constraint (the start menu). Height-aware modules use it to fill the
  cell instead of clamping to a fixed line count (see `quote_of_day.lua`); modules
  that ignore it render at their natural height.
- `refresh` - see **Refreshing after async work** below.

`on_tap` receives a context table `ctx = { bw = <bookshelf widget>,
menu = <start menu instance> }`; modules that ignore the argument keep
working. By default a tap closes the menu and then runs `on_tap`. With
`keep_open = true` the menu stays open: `on_tap(ctx)` runs first, then the
menu reloads **automatically** so the module re-renders its new state - so do
NOT call `ctx.menu:_reload()` yourself inside `on_tap` (that rebuilds the card
twice, a wasted repaint on e-ink). Just mutate your state and return; see
`random_unread.lua`, which re-rolls on each tap and relies on the auto-reload.
`keep_open` may also be a `function(ctx) -> bool` evaluated at tap time, for
modules whose settings decide per-tap whether the menu stays (see
`quote_of_day.lua`).

The loader exports `menu_generation`, a counter the start menu bumps once
per menu open — modules may key per-open caches on it (it is stable across
the menu's focus-step rebuilds, unlike a TTL).

**Refreshing after async work.** If your module loads data asynchronously
(e.g. a network fetch) and needs to redraw when it lands, call the `refresh`
callback passed to `render` — **do not call `UIManager:setDirty(...)`
yourself**. `refresh()` re-renders only *your* card and scopes the e-ink
update to it; a direct `setDirty` repaints the whole screen and, worse, the
host (start menu vs. hero grid) is the only thing that knows *where* your card
is, so refresh control belongs to the parent, not the module. Capture it
during `render` and call it from your async callback:

```lua
local _refresh  -- module upvalue
...
render = function(width, scale_pct, preview, avail_h, refresh)
    _refresh = refresh
    if needFetch() then
        fetchAsync(function(ok)
            if ok and _refresh then _refresh() end  -- re-renders just this card
        end)
    end
    return buildWidget()
end,
```

`refresh` may be `nil` if an older host renders you, so guard with
`if _refresh then _refresh() end`. It is safe to call later (it re-finds your
card and no-ops if your module has since been removed). The same applies to
taps and settings: rely on the automatic reload after a `keep_open` tap, and
call `ctx.menu:_reload()` (also parent-scoped) from `show_settings` — never a
raw `setDirty`.

Set `wants_minute_tick = true` if your card shows the wall-clock time (a clock,
a countdown): the hero grid then re-renders it once a minute (scoped to the
card) so it stays current while the hero sits on screen. Read the time in
`render` as usual — the flag just asks the host to call `render` each minute.

`show_settings(ctx)` (same ctx shape) adds a "Module settings…" row to the
module's long-press dialog. The module owns the settings UI (typically a
ButtonDialog) and persistence, and calls `ctx.menu:_reload()` after changes
so the card re-renders. Convention: store settings via
`require("lib/bookshelf_settings_store")` under `micromodule_<key>_*` keys
(see `clock.lua` for a minimal example).

If your render output includes a `TextBoxWidget`, set its `bgcolor` to
`require("lib/bookshelf_start_menu_modules").CARD_BG` - the shared grey the
module card is painted with - or the text sits on a white bar.

**Text colours.** Take them from the shared roles on
`require("lib/bookshelf_start_menu_modules")` rather than hardcoding Blitbuffer
constants, so every card reads the same and a future contrast control can
tune them in one place:

- `COLOR_PRIMARY` - the changing / interesting content (the fact, quote, time,
  count, book title, temperature, ...).
- `COLOR_MUTED` - everything else: the category heading, the "Tap to…" hints,
  timestamps, and the muted fallback message.

The idea is a card reads as dark content on a quiet frame. Do NOT pull
`COLOR_*` off `ui/renderimage` - it does not export them, so they come out
`nil` and the text silently falls back to black. `COLOR_MUTED` is a deliberately
dark grey (0x55): a lighter grey on the card surface fails to carry enough
contrast on weaker e-ink panels.

Files are discovered at runtime; invalid specs are logged and skipped, and
`render` is pcall'd, so a broken module never breaks the menu. Keep `render`
fast - it runs on every menu paint, so cache anything slow (see
`reading_stats.lua` for a TTL-cached sqlite read). On failure, return nil.

**Translations.** Wrap user-visible strings in `_("...")` with a string
*literal* - the file has `_ = require("lib/bookshelf_i18n").gettext` in scope,
and the translation template is extracted by scanning for literal `_("...")`
calls. Calling `_()` on a variable (e.g. `_(MONTH_NAMES[i])`) is NOT extracted
and never translates. For locale-aware dates use `os.date("%B")` etc. rather
than a hand-rolled name table (see `clock.lua`).

**Register the key.** Add your file's `key` to the `expected_keys` table in
`tests/_test_start_menu_modules.lua`. That test asserts every shipped
`micromodules/*.lua` is listed (the keys are a stable API - saved user menus
reference modules by key), so an unregistered new module fails the suite.

New modules are welcome as drop-in contributions: one file here, plus its key
in the shipped-module test above.
