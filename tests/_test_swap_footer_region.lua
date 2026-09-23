-- tests/_test_swap_footer_region.lua
-- _swapFooterInPlace must refresh only the footer band, not the whole widget.
--
-- A whole-widget setDirty(self, "ui") repainted the hero above on every
-- d-pad focus move and (previously) every D-pad page turn -- the same flash
-- class as issue #124. The method captures the OUTGOING footer row's dimen
-- before the swap and scopes the refresh to it; only when geometry is
-- missing does it fall back to a full refresh.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local eq  = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nfunction BookshelfWidget:_swapFooterInPlace%(%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_swapFooterInPlace - renamed?")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local Geom = {
    new = function(_, t_) return t_ end,
}

local function harness(opts)
    opts = opts or {}
    local dirty = {}
    local freed = {}
    local old_row = opts.has_old_dimen ~= false and {
        dimen = { x = 0, y = 700, w = 600, h = 80, copy = function(self)
            return { x = self.x, y = self.y, w = self.w, h = self.h }
        end },
    } or nil
    local old_anchor = old_row and { [1] = old_row, free = function()
        freed[#freed + 1] = true
    end } or nil

    local self_ = {
        width  = 600,
        height = 800,
        _shelf_dims = {
            footer_overlap_idx = 3,
            content_w = 560,
            FOOTER_H = 80,
            FOOTER_BOTTOM_MARGIN = 10,
        },
        _overlap_group = (not opts.no_overlap) and {
            [3] = old_anchor,
            resetLayout = function() end,
        } or nil,
        _buildFooterRow = function()
            return { marker = "new-footer" }
        end,
    }

    local env = {
        ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
        pcall = pcall,
        require = function(name)
            if name == "ui/widget/container/bottomcontainer" then
                return { new = function(_, t) return t end }
            end
            error("unexpected require: " .. tostring(name))
        end,
        Geom = Geom,
        UIManager = {
            setDirty = function(_u, w, mode, region)
                dirty[#dirty + 1] = { w = w, mode = mode, region = region }
            end,
            nextTick = function(_u, fn) fn() end,
        },
    }
    env._G = env
    local fn = compile("local self = ...\n" .. body, env, "_swapFooterInPlace")
    fn(self_)
    return dirty, freed, self_
end

t.test("scopes the refresh to the outgoing footer band", function()
    local dirty = harness()
    assert(#dirty == 1, "expected exactly one setDirty, got " .. #dirty)
    eq(dirty[1].mode, "ui", "refresh mode")
    eq(dirty[1].region, { x = 0, y = 700, w = 600, h = 80 },
        "region must be the footer band, not a full-widget refresh")
end)

t.test("falls back to a full refresh when the old footer has no dimen", function()
    local dirty = harness({ has_old_dimen = false })
    assert(#dirty == 1, "expected exactly one setDirty, got " .. #dirty)
    eq(dirty[1].mode, "ui", "refresh mode")
    assert(dirty[1].region == nil,
        "no geometry: expected the full-widget fallback (nil region)")
end)

t.test("no overlap group: early return, no refresh", function()
    local dirty = harness({ no_overlap = true })
    assert(#dirty == 0, "early-returned but still issued " .. #dirty .. " setDirty")
end)

t.test("still swaps the new footer in and frees the old one", function()
    local _dirty, freed, self_ = harness()
    -- BottomContainer:new packs the row as [1]; the anchor is what replaced
    -- overlap_group[footer_overlap_idx].
    local anchor = self_._overlap_group[3]
    assert(anchor and anchor[1] and anchor[1].marker == "new-footer",
        "footer anchor was not replaced")
    assert(#freed == 1, "old footer was not freed")
end)

t.done()
