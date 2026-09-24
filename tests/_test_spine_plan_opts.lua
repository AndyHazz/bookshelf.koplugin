-- tests/_test_spine_plan_opts.lua
-- SpineShelf.plan's two callers take the options they must agree on from ONE
-- place.
--
-- Usage (from plugin root): lua tests/_test_spine_plan_opts.lua
--
-- plan() is called two ways. The RENDER plans one page (_buildSpineRows);
-- PAGINATION plans the whole chip and cuts it into pages (_spinePageFirsts).
-- Anything that changes how many books fit a row has to be the same in both,
-- or the page boundaries pagination produces are not the ones the render
-- follows -- which the code has recorded going wrong more than once: row-end
-- ornaments decided differently, face-outs chosen from different lists, "the
-- same page number arrived twice". Seven options decide that, and each call
-- site used to build all seven itself.
--
-- They come from _spinePlanBase now; each caller adds only what is its own
-- (the render: its row count, where it resumes, which page it is;
-- pagination: an unbounded row count, how the result will be cut, no
-- balancing). A refactor, so the other half of the evidence is the rig: the
-- same shelf rendered and paginated before and after, pixel for pixel.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function fnBody(name)
    return src:match("\nfunction BookshelfWidget:" .. name .. "%((.-)%)\n(.-)\nend\n")
end

local SHARED = { "content_w", "row_h", "gap", "group_gap", "face_out",
                 "face_recent_set", "thickness_pct" }

-- ── the helper, run for real ───────────────────────────────────────────────

local args, body = fnBody("_spinePlanBase")
assert(body, "BookshelfWidget:_spinePlanBase is missing")
local SpineShelf = { BOOK_GAP_DP = 0, GROUP_GAP_DP = 12,
                     endMargin = function(h) return math.floor(h / 10) end }
local base = assert(load("return function(self, " .. args .. ")\n" .. body .. "\nend",
    "_spinePlanBase", "t", {
        require = function(name)
            assert(name == "lib/bookshelf_spine_shelf", "unexpected require " .. name)
            return SpineShelf
        end,
        Screen = { scaleBySize = function(_s, v) return v * 2 end },
        Space  = { px = function(v) return v * 2 end },
    }))()

local seen_recent_list
local shelf = {
    _spineFaceOut    = function() return "favorites" end,
    _spineFaceRecent = function(_s, list) seen_recent_list = list; return { list = list } end,
    _chipListValue   = function(_s, key) return key == "spine_thickness_pct" and 120 or nil end,
}

t.test("it produces exactly the options the two passes must agree on", function()
    local o = base(shelf, 1000, 300, { "whole", "list" })
    for _i, k in ipairs(SHARED) do
        assert(o[k] ~= nil, "the shared option " .. k .. " is missing")
    end
    local n = 0
    for _k in pairs(o) do n = n + 1 end
    eq(n, #SHARED, "the base carries an option only one pass should set")
end)

t.test("the fill budget is the width less both end margins", function()
    eq(base(shelf, 1000, 300, {}).content_w, 1000 - 2 * 30)
end)

t.test("the rest are read, not invented", function()
    local o = base(shelf, 1000, 300, {})
    eq(o.row_h, 300)
    eq(o.gap, 0)
    eq(o.group_gap, 24)
    eq(o.face_out, "favorites")
    eq(o.thickness_pct, 120)
end)

t.test("face-outs are chosen from the list the caller names", function()
    -- The render passes the chip's WHOLE list, not the page it draws;
    -- pagination passes the whole list it plans. Both must name it.
    local whole = { "a", "b" }
    base(shelf, 1000, 300, whole)
    assert(seen_recent_list == whole, "the face-out set was built from another list")
end)

-- ── both callers go through it ─────────────────────────────────────────────

local function planCall(fname)
    local _a, b = fnBody(fname)
    assert(b, fname .. " moved")
    local at = b:find("SpineShelf.plan(", 1, true)
    assert(at, fname .. " no longer calls SpineShelf.plan")
    return b, b:sub(1, at - 1)
end

for _i, fname in ipairs({ "_buildSpineRows", "_spinePageFirsts" }) do
    t.test(fname .. " builds its options from _spinePlanBase", function()
        local b = planCall(fname)
        assert(b:find("self:_spinePlanBase(", 1, true),
            fname .. " builds the shared options itself again")
    end)

    t.test(fname .. " sets none of the shared options itself", function()
        -- Only the option building BEFORE the plan call: the render's row
        -- widget has a table of its own further down, with its own gap.
        local _whole, before = planCall(fname)
        local code = before:gsub("%-%-[^\n]*", "")
        for _j, k in ipairs(SHARED) do
            assert(not code:find("opts%." .. k .. "%s*="),
                fname .. " overrides the shared " .. k .. ", so the passes can disagree")
            assert(not code:find("\n%s+" .. k .. "%s*=%s"),
                fname .. " still writes " .. k .. " into a table of its own")
        end
    end)
end

t.test("the render adds only its row count, where it resumes, and its page", function()
    local b = planCall("_buildSpineRows")
    assert(b:find("opts.n_rows     = n_rows", 1, true), "the render's row count")
    assert(b:find("opts.skip       = self:_spineSkip()", 1, true), "where it resumes")
    assert(b:find("opts.page_index = self.page", 1, true), "which page it is")
end)

t.test("pagination adds an unbounded plan, how it is cut, and no balancing", function()
    local b = planCall("_spinePageFirsts")
    assert(b:find("opts.n_rows        = math.huge", 1, true))
    assert(b:find("opts.rows_per_page = self:_nShelves()", 1, true))
    assert(b:find("opts.balance       = false", 1, true))
end)

t.test("the render's row widget uses the same book gap the plan did", function()
    local b = planCall("_buildSpineRows")
    assert(b:find("local gap = opts.gap", 1, true),
        "the row widget computes its own gap, a second source for one number")
end)

t.done()
