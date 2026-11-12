-- tests/_test_cover_marks.lua
-- Which cover marks show on which kind of shelf (lib/bookshelf_cover_marks.lua).
-- Usage: cd into the plugin dir, then `lua tests/_test_cover_marks.lua`.
--
-- Every mark has a switch for covers and one for spine shelves (issue 597).
-- The covers switch is the setting each mark always had; the spine switch is
-- new, and until a reader touches it a spine shelf looks as it did before:
-- most marks follow the covers switch, the page badge stays off.

package.path = "./?.lua;" .. package.path

local S = {}
package.preload["lib/bookshelf_settings_store"] = function()
    return {
        read = function(k) return S[k] end,
        save = function(k, v) S[k] = v end,
    }
end

local Marks = require("lib/bookshelf_cover_marks")
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local function reset() for k in pairs(S) do S[k] = nil end end

t.test("untouched: covers keep each mark's old default", function()
    reset()
    eq(Marks.shown("progress_bar", "covers"), true)
    eq(Marks.shown("bookmark", "covers"), true)
    eq(Marks.shown("favorite", "covers"), true)
    eq(Marks.shown("finished_fade", "covers"), false, "fading is opt-in")
    eq(Marks.shown("page_badge", "covers"), true)
    eq(Marks.shown("done_badge", "covers"), true)
    eq(Marks.shown("on_hold", "covers"), true)
    eq(Marks.shown("series_num", "covers"), true)
end)

t.test("the covers switch is the setting the mark always had", function()
    reset()
    S.progress_bar_enabled = false
    S.progress_bookmark_enabled = false
    S.show_fav_badge = false
    S.finished_fade_enabled = true
    eq(Marks.shown("progress_bar", "covers"), false)
    eq(Marks.shown("bookmark", "covers"), false)
    eq(Marks.shown("favorite", "covers"), false)
    eq(Marks.shown("finished_fade", "covers"), true)
end)

t.test("untouched: a spine shelf follows the covers switch", function()
    reset()
    eq(Marks.shown("bookmark", "spines"), true)
    S.progress_bookmark_enabled = false
    eq(Marks.shown("bookmark", "spines"), false)
    S.finished_fade_enabled = true
    eq(Marks.shown("finished_fade", "spines"), true)
end)

t.test("untouched: the progress bar stays off a spine shelf", function()
    -- A face-out cover never drew one; the spine switch is how to ask for it.
    reset()
    eq(Marks.shown("progress_bar", "spines"), false)
    eq(Marks.where("progress_bar"), "covers")
    S.progress_bar_spines = true
    eq(Marks.shown("progress_bar", "spines"), true)
end)

t.test("untouched: the page badge stays off a spine shelf", function()
    reset()
    eq(Marks.shown("page_badge", "spines"), false)
end)

t.test("untouched: the series number stays on a spine's foot", function()
    reset()
    S.show_series_num_covers = false
    eq(Marks.shown("series_num", "spines"), true, "it never followed covers")
end)

t.test("a spine switch, once set, wins over the covers switch", function()
    reset()
    S.progress_bar_enabled = false
    S.progress_bar_spines = true
    eq(Marks.shown("progress_bar", "spines"), true)
    S.progress_page_count_spines = true
    eq(Marks.shown("page_badge", "spines"), true)
end)

t.test("explicit says whether a reader has chosen", function()
    reset()
    eq(Marks.explicit("favorite", "spines"), nil)
    S.show_fav_badge_spines = false
    eq(Marks.explicit("favorite", "spines"), false)
end)

t.test("set writes the surface it was asked for", function()
    reset()
    Marks.set("progress_bar", "spines", false)
    eq(S.progress_bar_spines, false)
    eq(Marks.shown("progress_bar", "covers"), true, "covers untouched")
end)

t.test("turning covers off leaves an untouched spine shelf as it was", function()
    -- The two switches sit side by side; flipping one must not flip the other.
    reset()
    Marks.set("bookmark", "covers", false)
    eq(Marks.shown("bookmark", "covers"), false)
    eq(Marks.shown("bookmark", "spines"), true)
end)

t.test("turning covers on does not drag an untouched page badge onto spines", function()
    reset()
    S.progress_page_count_covers = false
    Marks.set("page_badge", "covers", true)
    eq(Marks.shown("page_badge", "spines"), false)
end)

t.test("a spine choice already made is not overwritten by a covers change", function()
    reset()
    S.progress_bar_spines = false
    Marks.set("progress_bar", "covers", false)
    Marks.set("progress_bar", "covers", true)
    eq(Marks.shown("progress_bar", "spines"), false)
end)

t.test("summary names the surfaces a mark is on", function()
    reset()
    eq(Marks.where("bookmark"), "both")
    S.progress_bookmark_spines = false
    eq(Marks.where("bookmark"), "covers")
    S.progress_bookmark_enabled = false
    eq(Marks.where("bookmark"), "none")
    S.progress_bookmark_spines = true
    eq(Marks.where("bookmark"), "spines")
end)

t.test("an unknown mark is shown rather than an error at paint time", function()
    reset()
    eq(Marks.shown("no_such_mark", "covers"), true)
    eq(Marks.shown("no_such_mark", "spines"), true)
end)

-- ── The menu rows (Settings > Cover display) ───────────────────────────────
--
-- Each mark's row opens a submenu that starts with the two switches. Run
-- from the source against the real Marks and the settings stub above.
local st = io.open("lib/bookshelf_settings.lua"):read("*a")
local function fn(name, args)
    local body = assert(st:match("\nfunction " .. name:gsub("%.", "%%.") .. "%(" .. args .. "%)\n(.-)\nend\n"),
        name .. " missing")
    local env = setmetatable({ _ = function(x) return x end, Marks = Marks },
        { __index = _G })
    local loader = load or loadstring
    local chunk
    if setfenv then
        chunk = assert(loadstring("return function(" .. args .. ")\n" .. body .. "\nend"))
        setfenv(chunk, env)
    else
        chunk = assert(loader("return function(" .. args .. ")\n" .. body .. "\nend", name, "t", env))
    end
    return chunk()
end
local surfaceRows = fn("Settings._markSurfaceRows", "mark, markDirty, enabled")
local whereLabel  = fn("Settings._markWhereLabel", "mark")

t.test("two switches: covers first, spine shelves second, then a rule", function()
    reset()
    local rows = surfaceRows("bookmark", function() end)
    eq(#rows, 2)
    eq(rows[1].text, "Show on covers")
    eq(rows[2].text, "Show on spine shelves")
    eq(rows[2].separator, true)
    eq(rows[1].checked_func(), true)
    eq(rows[2].checked_func(), true)
end)

t.test("a switch flips its own surface, repaints and refreshes the menu", function()
    reset()
    local dirty, refreshed = 0, 0
    local rows = surfaceRows("bookmark", function() dirty = dirty + 1 end)
    rows[2].callback({ updateItems = function() refreshed = refreshed + 1 end })
    eq(rows[2].checked_func(), false)
    eq(rows[1].checked_func(), true, "covers left alone")
    eq(dirty, 1); eq(refreshed, 1)
    rows[1].callback()
    eq(rows[1].checked_func(), false)
    eq(S.progress_bookmark_enabled, false, "covers is still the old setting")
end)

t.test("the page badge's spine switch starts off", function()
    reset()
    local rows = surfaceRows("page_badge", function() end)
    eq(rows[1].checked_func(), true)
    eq(rows[2].checked_func(), false)
end)

t.test("a switch can be greyed per surface (a style set to None)", function()
    reset()
    local rows = surfaceRows("done_badge", function() end,
        { covers = function() return false end })
    eq(rows[1].enabled_func(), false)
    eq(rows[2].enabled_func, nil, "no rule given for spines: always enabled")
    local both = surfaceRows("done_badge", function() end, function() return false end)
    eq(both[1].enabled_func(), false); eq(both[2].enabled_func(), false)
end)

t.test("the parent row says where the mark shows", function()
    reset()
    eq(whereLabel("bookmark"), "Covers and spine shelves")
    S.progress_bookmark_spines = false
    eq(whereLabel("bookmark"), "Covers only")
    S.progress_bookmark_enabled = false
    eq(whereLabel("bookmark"), "Off")
    S.progress_bookmark_spines = true
    eq(whereLabel("bookmark"), "Spine shelves only")
end)

t.test("every cover mark has its two switches in the menu", function()
    local menu = assert(st:match("function Settings:_coverDisplaySubItems%(%)(.-)\nfunction Settings:"))
    for _, mark in ipairs({ "progress_bar", "bookmark", "page_badge", "done_badge",
            "finished_fade", "on_hold", "series_num", "favorite" }) do
        assert(menu:find('[sS]urface%a*%("' .. mark .. '"'),
            mark .. " has no per-surface switches")
    end
end)

t.done()
