-- tests/_test_plugin_format_covers.lua
-- Books in a format another plugin provides (Repo.isPluginFormatFile) get their
-- metadata extracted, but the shelf never asks for their cover on its own:
-- for Meguru's .meguru streams a cover is an HTTP request per book.
--
-- Drives the REAL BookshelfWidget:_kickOffMissingMetaExtractionNow, lifted out
-- of the widget source and run against stubs for BIM, the repository and the
-- widget's own extraction plumbing -- the queue it builds is what is checked.
-- Runs standalone: `lua tests/_test_plugin_format_covers.lua`.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

-- BIM rows by path, as BookInfoManager would hold them.
local rows = {}
package.loaded["bookinfomanager"] = {
    max_extract_tries = 3,
    getBookInfo = function(_self, fp) return rows[fp] end,
    isExtractingInBackground = function() return false end,
}

local Repo = {
    bimGetBookInfo = function(BIM, fp) return BIM:getBookInfo(fp), nil end,
    currentFilepath = function() return nil end,
    isPluginFormatFile = function(fp) return fp:match("%.meguru$") ~= nil end,
}

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_kickOffMissingMetaExtractionNow%(items, slot_w, slot_h, hero_w, hero_h%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_kickOffMissingMetaExtractionNow - renamed?")

local BookshelfWidget = {
    -- Same contract as the real helper: too small when under 80% of the target.
    _coverNeedsResize = function(info, specs)
        local w = tonumber((info.cover_sizetag or ""):match("^(%d+)x")) or 0
        return w < (specs.max_cover_w or 0) * 0.8
    end,
}
local env = setmetatable({
    Repo = Repo,
    BookshelfWidget = BookshelfWidget,
    UIManager = { nextTick = function(_self, fn) fn() end },
    logger = { dbg = function() end, warn = function() end },
    _gettime = function() return 0 end,
}, { __index = _G })
local code = "return function(self, items, slot_w, slot_h, hero_w, hero_h)\n" .. body .. "\nend"
local chunk = assert((loadstring or load)(code, "=_kickOffMissingMetaExtractionNow"))
if setfenv then setfenv(chunk, env) else chunk = assert(load(code, "=_kickOffMissingMetaExtractionNow", "t", env)) end
local kickOff = chunk()

-- The widget side: record what would be handed to BIM.
local queued
local function newSelf()
    queued = {}
    return {
        _isRemoteRecord = function() return false end,
        _fireBimExtraction = function(_s, files) for _i, f in ipairs(files) do queued[f.filepath] = f end end,
        _armExtractionPoll = function() end,
    }
end

local function run(paths)
    local items = {}
    for _i, fp in ipairs(paths) do items[#items + 1] = { filepath = fp } end
    kickOff(newSelf(), items, 200, 300, 400, 600)
    return queued
end

t.test("a never-seen plugin-format book is queued for metadata only", function()
    rows = {}
    local q = run({ "/b/Vol 1.meguru", "/b/a.epub" })
    assert(q["/b/Vol 1.meguru"], "metadata never extracted")
    eq(q["/b/Vol 1.meguru"].cover_specs, nil, "a cover was requested for a plugin format")
    assert(q["/b/a.epub"] and q["/b/a.epub"].cover_specs, "an ordinary book lost its cover")
end)

t.test("metadata present, no cover attempt: a plugin format is left alone", function()
    rows = {
        ["/b/Vol 1.meguru"] = { has_meta = "Y", in_progress = 0 },          -- cover_fetched nil
        ["/b/a.epub"]       = { has_meta = "Y", in_progress = 0 },
    }
    local q = run({ "/b/Vol 1.meguru", "/b/a.epub" })
    eq(q["/b/Vol 1.meguru"], nil, "re-queued for the cover the shelf must not fetch")
    assert(q["/b/a.epub"] and q["/b/a.epub"].cover_specs, "an ordinary book is still asked for its cover")
end)

t.test("a small cached cover is not re-extracted for a plugin format", function()
    rows = {
        ["/b/Vol 1.meguru"] = { has_meta = "Y", in_progress = 0, cover_fetched = "Y",
                                has_cover = "Y", cover_sizetag = "30x45" },
        ["/b/a.epub"]       = { has_meta = "Y", in_progress = 0, cover_fetched = "Y",
                                has_cover = "Y", cover_sizetag = "30x45" },
    }
    local q = run({ "/b/Vol 1.meguru", "/b/a.epub" })
    eq(q["/b/Vol 1.meguru"], nil, "a resize would fetch the cover again")
    assert(q["/b/a.epub"], "an ordinary book's resize was suppressed too")
end)

t.test("folder and group members, and the hero, follow the same rule", function()
    rows = {}
    local self_ = newSelf()
    self_._preview_book = { filepath = "/b/hero.meguru" }
    kickOff(self_, {
        { first_book = { filepath = "/b/s/Vol 2.meguru" } },
        { books = { { filepath = "/b/s/Vol 3.meguru" }, { filepath = "/b/s/c.cbz" } } },
    }, 200, 300, 400, 600)
    for _i, fp in ipairs({ "/b/hero.meguru", "/b/s/Vol 2.meguru", "/b/s/Vol 3.meguru" }) do
        assert(queued[fp], fp .. " was not queued for metadata")
        eq(queued[fp].cover_specs, nil, fp .. " was queued for a cover")
    end
    assert(queued["/b/s/c.cbz"].cover_specs, "a .cbz is an ordinary book")
end)

t.test("Refresh metadata lets one cover through, then the rule applies again", function()
    rows = {}   -- the refresh deleted the BIM row
    local self_ = newSelf()
    self_._cover_requested = { ["/b/Vol 1.meguru"] = true }
    kickOff(self_, { { filepath = "/b/Vol 1.meguru" } }, 200, 300, 400, 600)
    assert(queued["/b/Vol 1.meguru"] and queued["/b/Vol 1.meguru"].cover_specs,
        "a refreshed plugin-format book did not get its cover back")
    -- BIM made the attempt and stored a small cover; a later layout wants it
    -- bigger. The permission is spent: no second fetch.
    rows["/b/Vol 1.meguru"] = { has_meta = "Y", in_progress = 0, cover_fetched = "Y",
                                has_cover = "Y", cover_sizetag = "30x45" }
    queued = {}
    kickOff(self_, { { filepath = "/b/Vol 1.meguru" } }, 200, 300, 400, 600)
    eq(queued["/b/Vol 1.meguru"], nil, "the refresh permission outlived its cover attempt")
    eq(self_._cover_requested["/b/Vol 1.meguru"], nil)
end)

t.test("both Refresh metadata paths grant the permission", function()
    local refresh = src:match('local refresh_btn = { text = _%("Refresh metadata"%)(.-)\n    end }')
    assert(refresh, "single-book Refresh metadata button not found")
    assert(refresh:find("bw:_allowCoverFetch(book.filepath)", 1, true),
        "single-book refresh does not allow the cover")
    local bulk = io.open("lib/bookshelf_bulk_actions.lua"):read("*a")
    local i = bulk:find("refresh_paths[#refresh_paths + 1] = fp", 1, true)
    assert(i and bulk:find("bw:_allowCoverFetch(fp)", i, true),
        "bulk refresh does not allow the covers")
end)

t.done()
