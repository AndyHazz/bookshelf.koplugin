-- tests/_test_group_drill_kind.lua
-- What kind a group drill records, and why it matters after a restart.
--
-- Format and Rating groups have no branch of their own in the shelf row's
-- dispatcher (bookshelf_shelf_row.lua:448-676 names folder, opds_nav, author,
-- genre, tag, language and then falls through on "has a .books array"), so a
-- TOUCH tap on one is wired to on_series_tap and lands in _expandSeries. The
-- keyboard path dispatches on kind and gets it right, which is why this only
-- ever bit touch.
--
-- Recording them as "series" saved the drill under a kind Repo.findGroup could
-- never resolve -- a SERIES named "EPUB" -- so _restoreDrillPath dropped the
-- frame and reopening put the reader back at the top of the chip. The same
-- wrong kind mislabelled the breadcrumb pill.
--
-- Driven against the real method body, extracted by name and run under a stub
-- self, as _test_opds_drill_restore does.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t  = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function bodyOf(sig, name)
    local body = src:match("\nfunction BookshelfWidget:" .. sig .. "\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    return body
end

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local EXPAND_BODY = bodyOf("_expandSeries%(series%)", "_expandSeries")

-- Runs the real body and returns the entry it tried to drill into.
local function drilledEntry(group)
    local captured
    local self_ = {
        _applyWithinGroupSort = function() end,
        _drillInto = function(_self, entry) captured = entry end,
    }
    local env = { ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
                  table = table, string = string, math = math }
    env._G = env
    compile("local self, series = ...\n" .. EXPAND_BODY, env, "expand")(self_, group)
    return captured
end

t.test("a series group still records itself as a series", function()
    -- Series records are the one group kind with no `kind` field; the fallback
    -- exists for them and must keep working.
    local e = drilledEntry({ series_name = "Discworld", books = {} })
    assert(e, "nothing was drilled")
    assert(e.kind == "series", "got " .. tostring(e.kind))
    assert(e.label == "Discworld", "wrong label: " .. tostring(e.label))
end)

t.test("a format group records itself as a format, not a series", function()
    -- The bug: saved as "series", so the restore looked for a series named
    -- EPUB, found nothing, and dropped the frame.
    local e = drilledEntry({ kind = "format", series_name = "EPUB", books = {} })
    assert(e.kind == "format",
        "a Format drill was recorded as '" .. tostring(e.kind) .. "'")
end)

t.test("a rating group records itself as a rating", function()
    local e = drilledEntry({ kind = "rating", series_name = "4 stars", books = {} })
    assert(e.kind == "rating",
        "a Rating drill was recorded as '" .. tostring(e.kind) .. "'")
end)

t.test("a kind that arrives here later is recorded as itself", function()
    -- The fallback must not swallow anything that is not a series. A future
    -- group kind with no dispatcher branch should record correctly by default
    -- rather than silently becoming a series again.
    local e = drilledEntry({ kind = "publisher", series_name = "Gollancz", books = {} })
    assert(e.kind == "publisher",
        "an unrecognised kind was flattened to '" .. tostring(e.kind) .. "'")
end)

t.test("the recorded kind is one the restore can actually resolve", function()
    -- The bug was only visible through Repo.findGroup, which resolves a saved
    -- frame by (kind, label). These are the kinds it knows; recording anything
    -- else is the same silent drop by another name.
    local RESOLVABLE = { author = true, series = true, genre = true,
                         format = true, rating = true, language = true }
    for _, g in ipairs({
        { kind = "format",   series_name = "EPUB" },
        { kind = "rating",   series_name = "4 stars" },
        { series_name = "Discworld" },
    }) do
        local e = drilledEntry(g)
        assert(RESOLVABLE[e.kind],
            "recorded kind '" .. tostring(e.kind) .. "' is not one findGroup resolves")
    end
end)

t.done()
