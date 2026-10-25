-- tests/_test_progress_facts.lua
-- Repo.readProgress answers from the book facts store while the book's
-- sidecar is unchanged (its mtime), instead of parsing the sidecar on the
-- first visit of every session.
--
-- Usage (from plugin root): lua tests/_test_progress_facts.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local function fn(name)
    local body = src:match("\n(function Repo%." .. name .. "%(.-\nend)\n")
    assert(body, name .. " moved")
    return body
end

local finished = {}
local function load_helpers(facts, mtime)
    local Repo = { _PROG_SEP = "\31" }
    package.loaded["lib/bookshelf_book_facts_db"] = facts
    package.loaded["lib/bookshelf_spine_shelf"] = { sidecarMtime = function() return mtime end }
    local env = setmetatable({ Repo = Repo, _finished_on = finished }, { __index = _G })
    for _i, n in ipairs({ "_progressFacts", "_unpackProgress", "_keepProgress" }) do
        assert(load(fn(n), n, "t", env))()
    end
    return Repo
end

t.test("kept, then answered while the sidecar is unchanged; read again once it moves", function()
    local rows = {}
    local facts = { get = function(fp) return rows[fp] end,
                    put = function(fp, f) rows[fp] = rows[fp] or {}; for k, v in pairs(f) do rows[fp][k] = v end end }
    local R = load_helpers(facts, 50)
    local F, smt, kept = R._progressFacts("/a.epub")
    assert(F == facts and smt == 50 and kept == nil)
    finished["/a.epub"] = "2026-01-02"
    R._keepProgress(F, "/a.epub", smt, 0.25, "reading", 4, 320, "render", 80)
    local _F2, _s2, kept2 = R._progressFacts("/a.epub")
    assert(kept2, "not answered from the store")
    finished["/a.epub"] = nil
    local pct, status, rating, pc, psrc, pnum = R._unpackProgress(kept2, "/a.epub")
    eq(pct, 0.25); eq(status, "reading"); eq(rating, 4); eq(pc, 320); eq(psrc, "render"); eq(pnum, 80)
    eq(finished["/a.epub"], "2026-01-02", "the finish date was lost")
    -- No summary: nothing set; a summary without a date: false.
    R._keepProgress(F, "/b.epub", smt, nil, nil, nil, nil, nil, nil)
    local _a, _b, kb = R._progressFacts("/b.epub")
    local p2 = R._unpackProgress(kb, "/b.epub")
    eq(p2, nil); eq(finished["/b.epub"], nil)
    -- The sidecar moved: read it again.
    local R2 = load_helpers(facts, 51)
    local _F3, _s3, kept3 = R2._progressFacts("/a.epub")
    eq(kept3, nil, "a changed sidecar was answered from the store")
end)

t.test("readProgress opens the sidecar only when the store can't answer", function()
    local body = src:match("\nfunction Repo%.readProgress%(filepath%)\n(.-)\nend\n")
    assert(body:find("local Facts, smt, kept = Repo._progressFacts(filepath)", 1, true))
    assert(body:find("if kept then", 1, true) and body:find("Repo._keepProgress(Facts, filepath, smt,", 1, true))
end)

t.done()
