# Bookshelf micro-modules

Each `.lua` file here is one micro-module: a small read-only info panel.
The file must return a spec table:

```lua
return {
    key   = "my_module",          -- stable id stored in user menus
    title = _("My module"),       -- shown in the Add dialog
    render = function(width) ... end, -- return a widget (or nil to show a muted fallback)
    on_tap = function(ctx) ... end,   -- optional tap action
    keep_open = true,                 -- optional: tap acts without closing the menu
                                      -- (or a function(ctx) -> bool, resolved at tap time)
    show_settings = function(ctx) ... end, -- optional settings dialog
}
```

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

`show_settings(ctx)` (same ctx shape) adds a "Module settings…" row to the
module's long-press dialog. The module owns the settings UI (typically a
ButtonDialog) and persistence, and calls `ctx.menu:_reload()` after changes
so the card re-renders. Convention: store settings via
`require("lib/bookshelf_settings_store")` under `micromodule_<key>_*` keys
(see `clock.lua` for a minimal example).

If your render output includes a `TextBoxWidget`, set its `bgcolor` to
`require("lib/bookshelf_start_menu_modules").CARD_BG` - the shared grey the
module card is painted with - or the text sits on a white bar.

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
