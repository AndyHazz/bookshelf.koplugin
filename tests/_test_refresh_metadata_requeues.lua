-- tests/_test_refresh_metadata_requeues.lua
-- Refresh metadata stopped working in 6.0: the book's BIM row was deleted,
-- but the extraction check answered from the batch rows read earlier
-- (perf: "the extraction check answers settled books from the batch"),
-- found the old row there, called it "cover-ok" and never queued the
-- re-extraction. The description (and cover) never came back.
--
-- Every place that deletes a book's BIM row now also forgets the batch row
-- (Repo.forgetBook), so the check reads BIM live, finds no row, and queues.
-- Run from the plugin root: lua tests/_test_refresh_metadata_requeues.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local BODY = repo:match("\nfunction Repo%.forgetBook%(fp%)\n(.-)\nend\n")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end

t.test("forgetBook drops the book's batch row in every cached walk, and nothing else", function()
    assert(BODY, "Repo.forgetBook(fp) not found")
    local bumped = 0
    local stale = { has_meta = "Y", has_cover = "Y", cover_fetched = "Y", cover_w = 300 }
    local other = { has_meta = "Y" }
    local cache = {
        ["/home:3"] = { rows = { ["/b/a.epub"] = stale, ["/b/c.epub"] = other }, map = {} },
        ["/home:9"] = { rows = { ["/b/a.epub"] = stale } },
        ["/x:3"]    = {},                                   -- no rows read yet
    }
    local env = setmetatable({ _light_meta_cache = cache,
        _bumpDataGeneration = function() bumped = bumped + 1 end }, { __index = _G })
    compile("local fp = ... ; " .. BODY, env, "forget")("/b/a.epub")
    eq(cache["/home:3"].rows["/b/a.epub"], nil, "the deleted row is still answered from the batch")
    eq(cache["/home:9"].rows["/b/a.epub"], nil, "another walk still holds it")
    eq(cache["/home:3"].rows["/b/c.epub"], other, "another book's row was dropped")
    assert(bumped >= 1, "the data generation was not bumped, so cached records survive")
end)

t.test("every BIM row deletion forgets the batch row", function()
    -- The single-book Refresh metadata, the bulk refresh, the stale-cover
    -- sweep and the cover revert all delete rows.
    local sites = {
        { "lib/bookshelf_widget.lua", 2 },
        { "lib/bookshelf_bulk_actions.lua", 1 },
        { "lib/bookshelf_stale_sweep.lua", 1 },
    }
    for _i, s in ipairs(sites) do
        local src = io.open(s[1]):read("*a")
        local dels = select(2, src:gsub("BIM:deleteBookInfo%(", ""))
        local forgets = select(2, src:gsub("forgetBook%(", ""))
        eq(dels, s[2], s[1] .. ": the number of deletions changed; check each forgets")
        assert(forgets >= dels, s[1] .. ": a BIM row deletion does not forget the batch row")
    end
end)

t.test("the top panel shows the re-read book, not the record from before it", function()
    -- The refresh's own rebuild memoised the hero's record while BIM had no
    -- row (so from the old cached record); when the re-extraction landed the
    -- hero was swapped from that memo, still showing the old description.
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local i = w:find("if hero_fp and ready_paths[hero_fp] then", 1, true)
    assert(i, "the extraction poll's hero swap moved")
    local branch = w:sub(i, i + 300)
    local m = branch:find("self._hero_current_memo = nil", 1, true)
    local s = branch:find("self:_swapHeroInPlace()", 1, true)
    assert(m and s and m < s, "the hero is swapped from a memo made before the re-extraction")
end)

t.done()
