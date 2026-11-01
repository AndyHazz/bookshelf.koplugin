-- tests/_test_dpad_footer_refresh.lua
-- Moving D-pad focus along the footer must refresh the FOOTER, on screen.
--
-- _swapFooterInPlace refreshed the outgoing footer row's dimen. That row is
-- painted by a BottomContainer, which never writes a screen position back
-- into its child, so the dimen sat at x = 0, y = 0: every focus move along
-- the footer refreshed a band across the TOP of the screen, and on e-ink the
-- focus ring around the page arrows, the page number and the start-menu
-- button never appeared (GitHub issue 361; rig panel mirror: "refresh 0,0
-- 1236x87" for a footer at the bottom of a 1648 px screen).
--
-- Driven against the real method body, extracted by name from the source.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local src  = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_swapFooterInPlace%(%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_swapFooterInPlace() - renamed?")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_swapFooterInPlace"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_swapFooterInPlace", "t", env))
end

local Geom = {}
Geom.__index = Geom
function Geom:new(o) o = o or {}; return setmetatable(o, Geom) end
function Geom:copy() return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h } end

local function row(w, h)
    -- As a painted row really is: sized, but never told where it went.
    return { dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
             getSize = function(s) return Geom:new{ w = w, h = h } end }
end

local function run(opts)
    local dirty = {}
    local env = {
        -- The bar's own height (Behavior > Footer bar): 0 keeps the band
        -- to the outgoing row, as these tests measure it.
        _footerBarH = function() return 0 end,
        Geom = Geom,
        require = function(name)
            if name == "ui/widget/container/bottomcontainer" then
                return { new = function(_, o) return o end }
            end
            error("unexpected require " .. name)
        end,
        UIManager = {
            setDirty = function(_, _w, mode, region) dirty[#dirty + 1] = { mode = mode, region = region } end,
            nextTick = function() end,
        },
        pcall = pcall,
        math = math,
        Screen = { scaleBySize = function(_, v) return v * 2 end },
    }
    local old_anchor = { row(opts.row_w, opts.row_h) }
    local self_tbl = {
        width = opts.width, height = opts.height,
        dimen = Geom:new{ x = 0, y = 0, w = opts.width, h = opts.height },
        _total_pages = 3,
        _shelf_dims = { content_w = opts.row_w, FOOTER_H = opts.row_h,
                        FOOTER_BOTTOM_MARGIN = opts.margin or 0, footer_overlap_idx = 2 },
        _overlap_group = { "main", old_anchor },
        _buildFooterRow = function() return row(opts.row_w, opts.row_h) end,
    }
    compile("local self = ... ; " .. body, env)(self_tbl)
    return dirty
end

t.test("the refresh covers the footer at the bottom of the screen", function()
    local dirty = run{ width = 1236, height = 1648, row_w = 1100, row_h = 87 }
    eq(#dirty, 1, "one refresh")
    local r = dirty[1].region
    assert(r, "a bounded refresh, not the whole screen")
    eq(r.y, 1648 - 87 - 24, "the band starts above the footer, by the ring's reach")
    eq(r.y + r.h, 1648, "and ends at the screen bottom")
    eq(r.x, 0, "full width: the row is centred, the band spans it")
    eq(r.w, 1236, "full width")
end)

t.test("a bottom margin lifts the band with the footer", function()
    local r = run{ width = 1236, height = 1648, row_w = 1100, row_h = 87, margin = 10 }[1].region
    eq(r.y + r.h, 1648 - 10, "band ends at the footer's bottom")
    eq(r.y, 1648 - 10 - 87 - 24, "and starts above it")
end)

t.done()
