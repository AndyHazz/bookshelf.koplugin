-- tests/_test_cover_label.lua
-- The Custom label under covers: how a template becomes one label, what the
-- per-book cache is keyed by, the stored line, and the wiring that reaches it
-- (the settings row, the shelf, the row builder, the editor adapter).
--
-- Usage (from plugin root): lua tests/_test_cover_label.lua
--
-- The expansions go through the REAL Tokens module and the REAL TokenRecord
-- adapter, against the field names the shelf's own record builder emits
-- (pinned at the bottom), because the label's whole job is to read what a
-- grid record really carries. Only the settings store and the repository are
-- stubbed, and the repository is COUNTED: a cache that still reaches the disk
-- on a hit is not a cache.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_localdate"] = { localize = function(s) return s end }

local stored, flushed = {}, 0
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(k, default)
        local v = stored[k]
        if v == nil then return default end
        return v
    end,
    save   = function(k, v) stored[k] = v end,
    isTrue = function(k) return stored[k] == true end,
    flush  = function() flushed = flushed + 1 end,
}

-- The repository: a data generation the tests bump by hand, and a progress
-- lookup that counts its calls.
local gen, progress_calls = 0, 0
local PROGRESS = {}
package.loaded["lib/bookshelf_book_repository"] = {
    dataGeneration = function() return gen end,
    progressFor = function(fp)
        progress_calls = progress_calls + 1
        local p = PROGRESS[fp]
        if not p then return nil, nil, nil, nil, false, nil end
        return p.pct, p.status, p.rating, p.pages, true, nil
    end,
}

-- Uppercasing goes through TextSegments, which needs KOReader's utf8proc.
-- ASCII is enough to see that the case setting is applied.
package.loaded["lib/bookshelf_text_segments"] = {
    upper = function(s) return s:upper() end,
}

-- The editor adapter's two collaborators: the shared dialog (only its spec is
-- of interest, so edit() records it) and UIManager's timer, run by hand.
local SPEC
package.loaded["lib/bookshelf_line_editor"] = { edit = function(spec) SPEC = spec end }
local scheduled = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_self, _s, fn) scheduled[#scheduled + 1] = fn end,
    nextTick   = function(_self, fn) scheduled[#scheduled + 1] = fn end,
    unschedule = function(_self, fn)
        for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end
    end,
}
local function runTimers()
    local due = scheduled; scheduled = {}
    for _i, fn in ipairs(due) do fn() end
end

local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local CoverLabel = require("lib/bookshelf_cover_label")
local Tokens     = require("lib/bookshelf_tokens")

-- A grid record: the fields Repo.buildBookMeta stamps (see the last test).
local function book(fp, extra, drop)
    local b = {
        filepath    = fp,
        title       = "Foundation",
        author      = "Isaac Asimov",
        authors     = { "Isaac Asimov" },
        series      = "Foundation #1",
        series_name = "Foundation",
        series_num  = 1,
    }
    for k, v in pairs(extra or {}) do b[k] = v end
    for _i, k in ipairs(drop or {}) do b[k] = nil end
    return b
end

local function fresh()
    CoverLabel.forget()
    CoverLabel.takeStats()
    gen, progress_calls = 0, 0
    for k in pairs(stored) do stored[k] = nil end
end

-- ── One label ──────────────────────────────────────────────────────────────

t.test("a template expands against the book", function()
    fresh()
    local text = CoverLabel.resolver({ template = "%author · %series_name %series_num" })(
        book("/b/f.epub"))
    eq(text, "Isaac Asimov · Foundation 1")
end)

t.test("a field the book does not have is empty, never 'nil'", function()
    fresh()
    local r = CoverLabel.resolver({ template = "%author · %series_name %series_num" })
    local text = r(book("/b/s.epub", nil, { "series", "series_name", "series_num" }))
    eq(text, "Isaac Asimov ·")
    assert(not text:find("nil", 1, true), "a missing field printed 'nil'")
end)

t.test("a template that expands to nothing gives an empty label", function()
    fresh()
    local r = CoverLabel.resolver({ template = "%series_name" })
    eq(r(book("/b/s.epub", nil, { "series_name" })), "")
end)

t.test("a label is one plain line: no style tags, no %bar, no %spacer, no newline",
function()
    fresh()
    local text = CoverLabel.render(
        { template = "[b]%title[/b]\n%bar %spacer[size=-4]%series_num[/size]" },
        book("/b/f.epub"))
    eq(text, "Foundation 1")
end)

t.test("progress tokens resolve through the lazy record, as on a list row", function()
    -- book_pct, status and page_count are not on a grid record: TokenRecord
    -- resolves them from the sidecar, and the label must use it.
    fresh()
    PROGRESS["/b/p.epub"] = { pct = 0.42, status = "reading", pages = 310 }
    local r = CoverLabel.resolver({ template = "%book_pct · %status_label · %page_count" })
    eq(r(book("/b/p.epub")), "42% · Reading · 310")
end)

t.test("Upper case applies to what the tokens expanded to", function()
    fresh()
    eq(CoverLabel.render({ template = "%title", uppercase = true }, book("/b/f.epub")),
       "FOUNDATION")
end)

t.test("a very long label is cut on a UTF-8 boundary", function()
    fresh()
    -- One ASCII letter first, so a byte cut at the (even) cap lands mid-letter.
    local long = "a" .. string.rep("\xC3\xA9", 400)
    local text = CoverLabel.render({ template = "%title" }, book("/b/l.epub", { title = long }))
    assert(#text <= CoverLabel.MAX_BYTES, "the label was not capped: " .. #text)
    eq((#text - 1) % 2, 0, "the cut split a two-byte character")
end)

-- ── The cache ──────────────────────────────────────────────────────────────

t.test("a second build of the same book re-expands nothing", function()
    fresh()
    PROGRESS["/b/p.epub"] = { pct = 0.5, status = "reading", pages = 100 }
    local line = { template = "%title %book_pct" }
    eq(CoverLabel.resolver(line)(book("/b/p.epub")), "Foundation 50%")
    local calls = progress_calls
    -- A NEW record table each time, as the repository hands out per fetch:
    -- the cache must not key on table identity.
    eq(CoverLabel.resolver(line)(book("/b/p.epub")), "Foundation 50%")
    eq(progress_calls, calls, "a cached label still read the sidecar")
    local st = CoverLabel.takeStats()
    eq(st.hits, 1); eq(st.misses, 1)
end)

t.test("a data generation bump re-expands (progress changed)", function()
    fresh()
    PROGRESS["/b/p.epub"] = { pct = 0.5, status = "reading", pages = 100 }
    local line = { template = "%book_pct" }
    eq(CoverLabel.resolver(line)(book("/b/p.epub")), "50%")
    PROGRESS["/b/p.epub"] = { pct = 0.75, status = "reading", pages = 100 }
    eq(CoverLabel.resolver(line)(book("/b/p.epub")), "50%", "no invalidation, no change")
    gen = gen + 1
    eq(CoverLabel.resolver(line)(book("/b/p.epub")), "75%",
        "a closed book's new progress did not reach its label")
end)

t.test("the template, the case setting and the author format are all in the key",
function()
    fresh()
    local b = book("/b/f.epub")
    eq(CoverLabel.resolver({ template = "%title" })(b), "Foundation")
    eq(CoverLabel.resolver({ template = "%author" })(b), "Isaac Asimov")
    eq(CoverLabel.resolver({ template = "%author", uppercase = true })(b), "ISAAC ASIMOV")
    stored.author_format = "last_first"
    local ctx_a = CoverLabel.context({ template = "%author" })
    stored.author_format = nil
    assert(ctx_a ~= CoverLabel.context({ template = "%author" }),
        "changing the author name format would serve stale names")
end)

t.test("metadata arriving late (BIM extraction) is in the per-book key", function()
    fresh()
    local r = CoverLabel.resolver({ template = "%title" })
    eq(r(book("/b/x.epub", { title = "x" })), "x")
    eq(CoverLabel.resolver({ template = "%title" })(book("/b/x.epub", { title = "Real Title" })),
       "Real Title")
end)

t.test("a clock token keys the cache to the minute; a plain template does not",
function()
    fresh()
    local clock = { template = "%title %time_24h" }
    assert(CoverLabel.context(clock, 60) ~= CoverLabel.context(clock, 120),
        "a clock template would show a stale time")
    eq(CoverLabel.context(clock, 60), CoverLabel.context(clock, 119))
    local plain = { template = "%title" }
    eq(CoverLabel.context(plain, 60), CoverLabel.context(plain, 6000),
        "a template with no clock token is re-expanded every minute for nothing")
    assert(CoverLabel.namesClock("[if:books_read>10]x[/if]"), "a condition on a counter")
    assert(CoverLabel.namesClock("%<time_12h>"), "the delimited form")
end)

t.test("a record with no file is never cached", function()
    fresh()
    eq(CoverLabel.bookKey({ title = "x" }), nil)
    local r = CoverLabel.resolver({ template = "%title" })
    r({ title = "a" }); r({ title = "a" })
    eq(CoverLabel.takeStats().hits, 0)
end)

t.test("the cache starts again at its limit instead of growing", function()
    fresh()
    local r = CoverLabel.resolver({ template = "%title" })
    for i = 1, CoverLabel.CACHE_LIMIT + 5 do r(book("/b/" .. i .. ".epub")) end
    CoverLabel.takeStats()
    r(book("/b/1.epub"))
    eq(CoverLabel.takeStats().misses, 1, "the oldest page is still cached past the limit")
end)

-- ── The stored line ────────────────────────────────────────────────────────

t.test("Custom starts from today's Title look", function()
    fresh()
    eq(CoverLabel.line().template, "%title")
    eq(CoverLabel.defaultLine().template, "%title")
end)

t.test("Save stores the line, makes Custom the mode, and flushes", function()
    fresh()
    local f0 = flushed
    CoverLabel.save({ template = "%author", bold = true, font_size = 30 })
    eq(stored.expanded_shelf_label, "custom")
    eq(stored.expanded_shelf_label_custom.template, "%author")
    eq(stored.expanded_shelf_label_custom.bold, true)
    eq(stored.expanded_shelf_label_custom.font_size, nil,
        "a field the label cannot honour was stored")
    eq(flushed, f0 + 1)
end)

t.test("switching back to Title keeps the custom template", function()
    fresh()
    CoverLabel.save({ template = "%author" })
    stored.expanded_shelf_label = "title"       -- what the Title row writes
    eq(CoverLabel.line().template, "%author")
end)

-- ── Text below groups (issue 486) ──────────────────────────────────────────

t.test("author below series: off by default, apart from the books; 5.4's Custom reads as on", function()
    fresh()
    eq(CoverLabel.groupMode(), nil, "a reader who never chose must see no change")
    stored.group_label = "none";   eq(CoverLabel.groupMode(), nil)
    stored.group_label = "title";  eq(CoverLabel.groupMode(), nil, "groups have no Title")
    stored.group_label = "author"; eq(CoverLabel.groupMode(), "author")
    -- Custom only ever had a series' author to print (maintainer, 2026-10-10).
    stored.group_label = "custom"; eq(CoverLabel.groupMode(), "author")
    assert(CoverLabel.groupResolver == nil and CoverLabel.groupLine == nil and CoverLabel.saveGroup == nil,
        "the groups' Custom template is still there")
end)

t.test("the switch never touches the books' choice", function()
    fresh()
    stored.expanded_shelf_label = "title"
    stored.expanded_shelf_label_custom = { template = "%title · %author" }
    local f0 = flushed
    CoverLabel.saveGroupMode(true)
    eq(stored.group_label, "author"); eq(flushed, f0 + 1)
    CoverLabel.saveGroupMode(false)
    eq(stored.group_label, "none"); eq(CoverLabel.groupMode(), nil)
    CoverLabel.saveGroupMode("author"); eq(CoverLabel.groupMode(), "author", "5.4's string form")
    eq(stored.expanded_shelf_label, "title", "the books' mode moved")
    eq(stored.expanded_shelf_label_custom.template, "%title · %author", "the books' line moved")
end)

-- ── The token picker ───────────────────────────────────────────────────────

t.test("the picker leaves out what a label can only ignore", function()
    local kept, dropped = {}, {}
    for _i, e in ipairs(Tokens.CATALOGUE) do
        if CoverLabel.offersToken(e) then kept[e.token] = true
        else dropped[#dropped + 1] = e end
    end
    assert(kept["%title"] and kept["%series_num"] and kept["%book_pct"])
    assert(not kept["%bar"] and not kept["%bar{rel}"] and not kept["%spacer"])
    assert(not kept["[b]"] and not kept["[size=-4]"])
    assert(not kept["%batt"], "a device token answers empty on a label")
    local styles = 0
    for _i, e in ipairs(dropped) do if e.category == "Style" then styles = styles + 1 end end
    assert(styles >= 4, "the catalogue has no Style tokens left to filter: test is vacuous")
end)

-- ── The editor adapter ─────────────────────────────────────────────────────

local function openEditor()
    SPEC, scheduled = nil, {}
    local previews = {}
    local bw = { _previewCoverLabel = function(_self, line) previews[#previews + 1] = line or false end }
    require("lib/bookshelf_cover_label_editor").show(bw, { name = "settings" }, nil)
    assert(SPEC, "the adapter did not open the shared editor")
    return SPEC, previews
end

t.test("the editor offers only what a label can honour", function()
    fresh()
    local spec = openEditor()
    eq(spec.size, false, "Size offered: the strip's size is the Cover captions setting")
    eq(spec.font, false, "Font offered: the strip has its own face")
    eq(spec.alignment, false, "alignment offered: a label is centred")
    eq(spec.italic, false, "the style cycle offered italic")
    assert(not spec.bar, "the %bar row offered")
    assert(spec.uppercase ~= false, "the case toggle was hidden, and a label can honour it")
    assert(spec.token_filter == CoverLabel.offersToken, "the token picker is unfiltered")
    eq(spec.line.template, "%title", "Custom does not start from the Title look")
    eq(spec.defaults.template, "%title")
end)

t.test("keystrokes preview debounced, button taps at once", function()
    fresh()
    local spec, previews = openEditor()
    spec.on_preview({ template = "%a" })
    spec.on_preview({ template = "%au" })
    eq(#previews, 0, "a keystroke rebuilt the shelf immediately")
    runTimers()
    eq(#previews, 1, "a burst of keystrokes did not collapse to one rebuild")
    eq(previews[1].template, "%au")
    spec.on_preview({ template = "%au", bold = true })
    eq(#previews, 2, "a button tap waited for the debounce")
    eq(previews[2].bold, true)
end)

t.test("the editor has no groups' line any more", function()
    eq(require("lib/bookshelf_cover_label_editor")._targets.groups, nil)
end)

t.test("Save writes and drops the preview; Cancel writes nothing", function()
    fresh()
    local spec, previews = openEditor()
    spec.on_preview({ template = "%author" })          -- pending keystroke
    spec.on_save({ template = "%author", uppercase = true })
    eq(#scheduled, 0, "a pending preview outlived Save")
    eq(stored.expanded_shelf_label, "custom")
    eq(stored.expanded_shelf_label_custom.template, "%author")
    eq(previews[#previews], false, "Save left the draft override on the shelf")

    fresh()
    stored.expanded_shelf_label = "title"
    spec, previews = openEditor()
    spec.on_preview({ template = "%title", bold = true })  -- a button: shown at once
    spec.on_cancel()
    eq(stored.expanded_shelf_label, "title", "Cancel changed the mode")
    eq(stored.expanded_shelf_label_custom, nil, "Cancel wrote the template")
    eq(previews[#previews], false, "Cancel left the draft on the shelf")

    fresh()
    spec, previews = openEditor()
    spec.on_cancel()
    eq(#previews, 0, "backing straight out rebuilt the shelf for nothing")
end)

-- ── Wiring, read from source ───────────────────────────────────────────────
--
-- Comments are stripped first: the comments here quote the code they
-- describe, and a check satisfied by its own documentation proves nothing.
local function code(path)
    local out = {}
    for line in io.lines(path) do
        out[#out + 1] = (line:gsub("%-%-.*$", ""))
    end
    return table.concat(out, "\n")
end
local settings_src = code("lib/bookshelf_settings.lua")
local widget_src   = code("lib/bookshelf_widget.lua")
local row_src      = code("lib/bookshelf_shelf_row.lua")
local repo_src     = code("lib/bookshelf_book_repository.lua")

t.test("the label menu has a Custom row between Series and None", function()
    local body = settings_src:match("function Settings:_coverDisplaySubItems%(%)(.-)\nfunction Settings:")
    assert(body, "Settings:_coverDisplaySubItems is gone")
    local s = body:find('labelModeRow("series")', 1, true)
    -- From the Series row on: the first "customLabelRow()" is its definition.
    local c = s and body:find("customLabelRow(),", s, true)
    local n = body:find('labelModeRow("none")', 1, true)
    assert(s and c and n and s < c and c < n, "the Custom row is not listed between Series and None")
    assert(body:find('v == "custom"', 1, true), "readLabelMode does not recognise custom")
    local row = body:match("local function customLabelRow%(%)(.-)\n    end\n")
    assert(row, "customLabelRow could not be located")
    assert(row:find("radio%s*=%s*true"), "Custom is not in the same radio group")
    assert(row:find('require("lib/bookshelf_cover_label_editor").show', 1, true),
        "choosing Custom does not open the editor")
    assert(row:find('readLabelMode() ~= "custom"', 1, true),
        "the row does not switch to a preview once Custom is the mode")
end)

t.test("the shelf reads Custom from the setting and from an open editor", function()
    local body = widget_src:match("\nfunction BookshelfWidget:_shelfLabelMode%(%)\n(.-)\nend\n")
    assert(body, "BookshelfWidget:_shelfLabelMode is gone")
    local function compile(src, env)
        if _G.setfenv then
            local f = assert(_G.loadstring(src)); _G.setfenv(f, env); return f
        end
        return assert(load(src, "_shelfLabelMode", "t", env))
    end
    local mode, groups
    -- The mode comes from CoverLabel.modeFor(self.chip): the shelf's own,
    -- else the setting (its own test above).
    local env = { require = function(m)
        assert(m == "lib/bookshelf_cover_label", m)
        return { modeFor = function(chip) assert(chip == "c", "not the chip on screen"); return mode end }
    end }
    local f = compile("local self = ... ; " .. body, env)
    local shelf = { chip = "c", _gridDrawsLabels = function() return true end,
                    _groupLabelMode = function() return groups end }
    mode = "custom"; eq(f(shelf), "custom")
    mode = "none";   eq(f(shelf), nil)
    groups = "author"
    eq(f(shelf), "none", "books on None, groups on Author: the strip stays, for the groups")
    groups = nil
    shelf._cover_label_preview = { template = "%title" }
    eq(f(shelf), "custom", "the editor's draft did not preview over None")
end)

t.test("the rows are handed the Custom line, and the preview rebuilds", function()
    assert(widget_src:find("label_line%s*=%s*%(label_mode == \"custom\"%) and self:_coverLabelLine%(%)"),
        "_buildShelfRows does not pass the Custom line to the rows")
    local prev = widget_src:match("\nfunction BookshelfWidget:_previewCoverLabel%(line%)\n(.-)\nend\n")
    assert(prev, "BookshelfWidget:_previewCoverLabel is gone")
    assert(prev:find("self._cover_label_preview = line", 1, true))
    assert(prev:find("self:_rebuild()", 1, true), "the preview does not rebuild the rows")
end)

t.test("ShelfRow draws Custom through the cached resolver, and nothing for an empty one",
function()
    assert(row_src:find('label_mode ~= "custom"', 1, true),
        "ShelfRow still demotes custom to none")
    assert(row_src:find('CoverLabel.resolver(opts.label_line', 1, true),
        "ShelfRow does not build the resolver from the row's line")
    local label_for = row_src:match("local function _labelFor%(item%)(.-)\n        local title_fallback")
    assert(label_for and label_for:find("custom_label(item)", 1, true),
        "_labelFor does not route Custom to the resolver")
    assert(row_src:find('if title_text ~= "" then', 1, true),
        "an empty label would still draw a plate")
    assert(row_src:find('if plate_fill and title_text ~= "" then', 1, true),
        "the overhang repaint is not gated on there being a label")
end)

t.test("every invalidation that can change a label bumps the data generation", function()
    for _i, name in ipairs({ "invalidateWalkCache", "invalidateProgressCache",
                             "invalidateLightMeta", "invalidateStatsCache" }) do
        local body = repo_src:match("\nfunction Repo%." .. name .. "%(.-%)\n(.-)\nend\n")
        assert(body, "Repo." .. name .. " is gone")
        assert(body:find("_bumpDataGeneration()", 1, true),
            "Repo." .. name .. " does not bump the data generation")
    end
    -- Declared before its first caller, or the callers read a nil upvalue.
    local decl = repo_src:find("local function _bumpDataGeneration", 1, true)
    local first = repo_src:find("_bumpDataGeneration()", 1, true)
    assert(decl and first and decl < first, "_bumpDataGeneration is declared below a caller")
end)

t.test("the per-book key reads fields the shelf's record builder really emits", function()
    -- buildBookMeta is what the grid draws. A key built from a field it never
    -- sets would be constant, and a late title would never reach its label.
    local body = repo_src:match("\nfunction Repo%.buildBookMeta%(.-%)\n(.-)\nend\n")
    assert(body, "Repo.buildBookMeta is gone")
    for _i, f in ipairs({ "title", "author", "series", "series_num", "page_count" }) do
        assert(body:find("\n%s+" .. f .. "%s+=") , "buildBookMeta no longer sets " .. f)
    end
end)

-- ── Per shelf (Shelf style, after 5.4) ──────────────────────────────────────

t.test("a shelf's own text below covers wins; a sub-shelf follows its shelf of shelves", function()
    for k in pairs(stored) do stored[k] = nil end
    local tabs = {
        series = { id = "series", label = "Series", cover_text = "series" },
        sub    = { id = "sub", label = "Sub", parent = "series" },
        home   = { id = "home", label = "Home" },
        mine   = { id = "mine", label = "Mine", cover_text = "custom",
                   cover_text_line = { template = "%author" } },
        kid    = { id = "kid", label = "Kid", parent = "mine", cover_text = "none" },
    }
    CoverLabel._tab = function(id) return tabs[id] end
    -- Unset everywhere: the setting, as before (nil = Title).
    eq(CoverLabel.modeFor("home"), nil)
    stored[CoverLabel.MODE_SETTING] = "author"
    eq(CoverLabel.modeFor("home"), "author")
    -- The series shelf's own, and its sub-shelf's by inheritance.
    eq(CoverLabel.modeFor("series"), "series")
    eq(CoverLabel.modeFor("sub"), "series", "a sub-shelf does not follow its shelf of shelves")
    -- Custom with the shelf's own template, not the global one.
    stored[CoverLabel.LINE_SETTING] = { template = "%title" }
    eq(CoverLabel.modeFor("mine"), "custom")
    eq(CoverLabel.lineFor("mine").template, "%author", "the shelf's own line is not used")
    eq(CoverLabel.lineFor("home").template, "%title")
    -- The sub-shelf's own None outranks its parent's Custom.
    eq(CoverLabel.modeFor("kid"), "none")
    CoverLabel._tab = nil
end)

t.test("one shelf's editor edits the shelf's line, not the settings, and hands back", function()
    for k in pairs(stored) do stored[k] = nil end
    package.loaded["lib/bookshelf_settings"] = { _pickToken = function() end }
    local saved, closed = nil, 0
    SPEC = nil
    require("lib/bookshelf_cover_label_editor").showForShelf(nil, {
        line = { template = "%author %series" },
        save = function(l) saved = l end,
        on_closed = function() closed = closed + 1 end,
    })
    assert(SPEC, "the editor did not open")
    eq(SPEC.line.template, "%author %series", "the shelf's line is not what it opens on")
    eq(SPEC.title, "Cover captions")
    assert(SPEC.settings_module and SPEC.settings_module._pickToken, "no token picker")
    SPEC.on_save({ template = "%series" })
    eq(saved and saved.template, "%series")
    eq(stored[CoverLabel.LINE_SETTING], nil, "the shelf's Save wrote the settings")
    eq(stored[CoverLabel.MODE_SETTING], nil, "the shelf's Save wrote the settings")
    runTimers()
    eq(closed, 1, "Shelf style is not brought back after Save")
    SPEC.on_cancel(); runTimers()
    eq(closed, 2, "Shelf style is not brought back after Cancel")
    package.loaded["lib/bookshelf_settings"] = nil
end)

t.test("the shelf reads the books' label choice for the chip on screen", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    for _i, pat in ipairs({
        'require%("lib/bookshelf_cover_label"%)%.modeFor%(self%.chip%)',
        'require%("lib/bookshelf_cover_label"%)%.lineFor%(self%.chip%)',
    }) do
        assert(w:find(pat), "the shelf does not ask for the chip's own: " .. pat)
    end
    assert(not w:find('BookshelfSettings.read("expanded_shelf_label")', 1, true),
        "the shelf still reads the global label mode directly, past the shelf's own")
end)

t.done()
