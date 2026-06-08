# Bookshelf tests

Fast, dependency-free unit tests for the plugin's pure-Lua logic. They run under
a plain `lua` (or `luajit`) interpreter - **not** inside KOReader - by stubbing
the KOReader modules a unit under test reaches for.

## Running

```sh
sh tests/run.sh            # uses `lua` from PATH
LUA=luajit sh tests/run.sh # or pick an interpreter
```

The runner globs `tests/_test_*.lua`, runs each in its own interpreter, and
prints one line per suite plus a final `ran N suites, M failed, K skipped`. It
exits non-zero if any suite fails, so it drops straight into CI or a pre-push
hook. A suite counts as failed if it exits non-zero, prints a `FAIL ` line, or
reports a non-zero `N fail` count.

Run a single suite directly while iterating:

```sh
lua tests/_test_settings_store.lua
```

A few suites are **skipped** by `run.sh` because they need KOReader's native
libraries (`libkoreader-lfs`, `ffi`/`utf8proc`); exercise those on-device. The
skip list lives in `skip_reason()` in `run.sh`.

## How a suite works

Each suite is self-contained. Before requiring the unit under test, it installs
stubs into `package.loaded` for whatever KOReader modules that unit pulls in
(`logger`, `datastorage`, `luasettings`, `bookinfomanager`, widgets, ...), then
drives the real code and asserts on the results. Most KOReader UI modules are
only `require`d at load (never called), so an empty `{}` stub is enough to load
a UI module standalone - see `_test_chip_editor.lua`.

```lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
-- ...more stubs for what the unit requires...
local Unit = dofile("lib/bookshelf_<unit>.lua")
```

## Shared helpers (`tests/_helpers.lua`)

`_helpers.lua` is **not** a suite (the runner only globs `_test_*.lua`). Newer
suites use it to avoid re-implementing boilerplate:

```lua
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()   -- t.test(name, fn) / t.done()
local eq = helpers.eq         -- deep value/sequence equality

t.test("does the thing", function()
    eq(Unit.thing(), { 1, 2, 3 })
end)
t.done()                      -- prints "PASS n  FAIL n"; exits non-zero on fail
```

`helpers.install_hardcover_cache_fake()` installs an in-memory backend for the
SQLite-backed Hardcover cache (the `lua-ljsqlite3` + `rapidjson` libraries don't
exist standalone). Call it **before** loading `lib/bookshelf_hardcover` (or
anything that loads it, e.g. `book_repository`). It returns
`{ seed(kind, ckey, value), kind(kind) -> table, clear() }` so a test can seed
the cache and read back what the code stored, exercising the real
`_cacheGet`/`_cachePut`/... paths.

## Adding a test

1. Prefer pure logic: parsers, normalisers, predicates, sort, data shaping,
   config tables. These are cheap to test and where most regressions hide.
2. Create `tests/_test_<area>.lua`, stub what the unit requires, use
   `helpers.runner()` + `helpers.eq()`.
3. If the logic you want to test is a `local` inside a big module, expose it via
   a small `Module._test = { ... }` table at the end of the module (see
   `bookshelf_chip_editor.lua`). Keep it clearly marked "unused at runtime".
4. Run `sh tests/run.sh` and make sure the whole suite is still green.
