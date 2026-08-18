-- tests/_test_preview_selection_ring.lua
-- The selection ring must follow the previewed book, even after a hero tap has
-- staged the hero as "tap once more to open" (#335).
--
-- The bug it pins: _selectedFilepath() ranks _tap_selected_fp ABOVE
-- _preview_book. The hero's on_tap latches _tap_selected_fp when
-- tap_to_open_double is on, and no collapsed shelf tap cleared it, so every
-- later preview left the ring pinned to the hero's book.
--
-- Why it only showed in some chips: _previewBook has two repaint paths. The
-- fast one passes is_selected explicitly to _repaintSelectionHighlight, which
-- masks the stale latch. The _rebuild() path derives the ring from
-- _selectedFilepath() instead, and it only runs when the preview crosses the
-- "is this the currently-reading book" boundary (was_diff ~= is_diff) - i.e.
-- only in a chip that CONTAINS the current book, such as a STATUS:Reading chip
-- sorted by Opened, where lastfile is the first tile.
--
-- Both method bodies are extracted by name and run under stubs, as
-- _test_hero_preview_cycle does.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function bodyOf(signature, name)
    local pat = "\nfunction BookshelfWidget:" .. signature .. "\n(.-)\nend\n"
    local body = src:match(pat)
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    return body
end

local preview_body  = bodyOf("_previewBook%(book, tap_t%)", "_previewBook(book, tap_t)")
local selected_body = bodyOf("_selectedFilepath%(%)",       "_selectedFilepath()")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local function book(name) return { filepath = "/b/" .. name .. ".epub", title = name } end

-- Drive one shelf-cover tap through the real _previewBook body.
--   lastfile - what Repo.currentFilepath() reports (KOReader's current book)
--   preview  - the record currently previewed in the hero
--   staged   - a pending _tap_selected_fp latch (what a hero tap leaves)
--   tapped   - the book whose cover the user just tapped
-- Returns the self table afterwards, plus which branch it took.
local function tap(opts)
    local now = 0
    local took = {}
    local self_tbl = {
        _hero_mode        = "current",
        _preview_book     = opts.preview,
        _tap_selected_fp  = opts.staged,
        _hero_parent      = opts.hero_mounted and {} or nil,
        _hero_dims        = opts.hero_mounted and {} or nil,
        _inner_vgroup     = {},
        _shelf_dims       = { n_shelves = 2, shelf_top_idx = 1 },
        _opdsEnsurePreviewCover = function() end,
        _hydrateBook      = function(_s, b) return b end,
        _clearDpadFocus   = function() end,
        _rebuild          = function() took.rebuild = true end,
        _swapHeroInPlace  = function() took.swap_hero = true end,
        _repaintSelectionHighlight = function(_s, old, new)
            took.repaint = { old = old, new = new }
        end,
        _swapShelvesInPlace = function() took.swap_shelves = true end,
        _openBook         = function(_s, b) took.opened = b.filepath end,
    }
    local env = {
        string = string, math = math, ipairs = ipairs, pairs = pairs,
        tostring = tostring, type = type, pcall = pcall,
        _gettime = function() now = now + 0.001; return now end,
        logger   = { dbg = function() end, warn = function() end },
        UIManager = { setDirty = function() end, nextTick = function() end },
        Screen   = { scaleBySize = function(_s, n) return n end },
        Repo     = { currentFilepath = function() return opts.lastfile end },
        require  = function(name)
            if name == "lib/bookshelf_quotes" then
                return { rerollBook = function() end }
            end
            error("unexpected require: " .. tostring(name))
        end,
    }
    compile("local self, book, tap_t = ... ; " .. preview_body, env, "_previewBook")(
        self_tbl, opts.tapped, nil)
    return self_tbl, took
end

local function selectedFilepath(self_tbl)
    local f = compile("local self = ... ; return (function() " .. selected_body
                      .. "\nend)()", { ipairs = ipairs }, "_selectedFilepath")
    return f(self_tbl)
end

local A, C, D = book("A"), book("C"), book("D")

-- ── The reported sequence ────────────────────────────────────────────────────
-- Chip contains the currently-reading book C. Tap A (works), tap the hero
-- (stages A), then tap C: the preview crosses the boundary, so the ring is
-- rebuilt from _selectedFilepath() - and must name C, not the staged A.
t.test("a preview supersedes a staged hero tap (#335)", function()
    local self_tbl, took = tap{
        lastfile = C.filepath, preview = A, staged = A.filepath, tapped = C,
        hero_mounted = true,
    }
    assert(took.rebuild, "expected the boundary-crossing rebuild branch")
    assert(not took.opened, "tapping a different book must not open it")
    assert(self_tbl._preview_book.filepath == C.filepath, "preview must move to C")
    local ring = selectedFilepath(self_tbl)
    assert(ring == C.filepath,
        "ring must follow the preview, got " .. tostring(ring))
end)

-- The same staleness on the fast path. The explicit is_selected there hides it
-- today, but the latch must still be cleared so the NEXT rebuild is correct.
t.test("the staged latch is cleared on the fast swap path too", function()
    local self_tbl, took = tap{
        lastfile = C.filepath, preview = A, staged = A.filepath, tapped = D,
        hero_mounted = true,
    }
    assert(took.swap_hero, "expected the fast hero-swap branch")
    assert(took.repaint and took.repaint.new == D.filepath,
        "fast path must repaint the new spine")
    assert(selectedFilepath(self_tbl) == D.filepath,
        "a later rebuild must not resurrect the staged path")
end)

-- Regression guard: the staged latch is what makes the hero's second tap open,
-- so previewing the SAME book must still commit rather than restage.
t.test("tapping the already-previewed book still opens it", function()
    local _self_tbl, took = tap{
        lastfile = C.filepath, preview = A, staged = A.filepath, tapped = A,
        hero_mounted = true,
    }
    assert(took.opened == A.filepath, "second tap on the same cover opens")
end)

-- With no hero tap in play the ring already followed the preview; keep it that
-- way so the fix can't be read as "clear it only sometimes".
t.test("no staged latch: ring follows the preview as before", function()
    local self_tbl = tap{
        lastfile = C.filepath, preview = A, staged = nil, tapped = C,
        hero_mounted = true,
    }
    assert(selectedFilepath(self_tbl) == C.filepath)
end)

-- The d-pad focus cell still outranks both (it is the live cursor).
t.test("d-pad focus cell still wins over the preview", function()
    local self_tbl = tap{
        lastfile = C.filepath, preview = A, staged = A.filepath, tapped = C,
        hero_mounted = true,
    }
    self_tbl._cursor_idx = 1
    self_tbl._page_items = { { filepath = D.filepath } }
    assert(selectedFilepath(self_tbl) == D.filepath,
        "focus cell must outrank the preview")
end)

t.done()
