-- tests/_test_expanded_strip_height.lua
-- A disabled status line reserves no space on the expanded shelf.
--
-- THE REPORT (maintainer, on a PW5). "When the status line is disabled,
-- swiping up to view the full shelf still reserves space for it."
--
-- THE BUG. HeroCard.buildStatusRow returns nil for TWO different reasons:
--
--     if not regions.status or regions.status.disabled then return nil end
--     if not book then return nil end
--
-- "the reader turned this off" and "there is no book to describe". The
-- height probe could not tell them apart and answered both with a fallback:
--
--     local h = probe_row and probe_row:getSize().h or Screen:scaleBySize(20)
--
-- The fallback is right for the second case -- the strip still renders, and
-- the layout has to reserve something for it before the book is known. For
-- the first it booked 20dp for a strip that draws nothing, and the expanded
-- shelf lost a band of height to it on every rebuild.
--
-- _buildMicroHero already got this right: a nil row there returns the grid
-- built at the FULL hero height, reserving nothing. Only the expanded path
-- went through the probe.
--
-- Note this does remove the tap-to-restore affordance while the status line
-- is off, since there is no strip left to tap. Swipe-down still restores,
-- and an invisible 20dp target on blank space was not discoverable anyway.
--
-- Usage (from plugin root): lua tests/_test_expanded_strip_height.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("(function BookshelfWidget:_statusStripHeight.-\nend)")
assert(body, "_statusStripHeight moved or was renamed")

-- Build the method over stubs. `disabled` drives the region; `row_h` is what
-- a real status row would measure.
local function probe(opts)
    opts = opts or {}
    local built = 0
    local env = { type = type, pcall = pcall }
    env.Screen = { scaleBySize = function(_, n) return n end }
    env.Repo   = { buildBook = function(fp) return { filepath = fp } end }
    env.HeroCard = {
        buildStatusRow = function()
            built = built + 1
            -- the real one returns nil when the region is off, or no book
            if opts.disabled or opts.no_book then return nil end
            return { getSize = function() return { h = opts.row_h or 42 } end }
        end,
    }
    env.require = function(name)
        if name == "lib/bookshelf_hero_regions" then
            return { read = function()
                if opts.disabled then return { status = { disabled = true } } end
                return { status = {} }
            end }
        end
        error("unexpected require: " .. tostring(name))
    end
    local BookshelfWidget = {}
    env.BookshelfWidget = BookshelfWidget
    assert(load(body, "probe", "t", env))()
    local self_ = {
        _preview_book = opts.no_book and nil or { filepath = "/b.epub" },
        _currentHeroBook = function() return nil end,
        _buildDeviceState = function() return {} end,
    }
    local h, book = BookshelfWidget._statusStripHeight(self_, 600)
    return h, book, built, self_
end

t.test("a disabled status line reserves nothing", function()
    local h = probe{ disabled = true }
    eq(h, 0, "the expanded shelf must not book height for a strip that draws nothing")
end)

t.test("an enabled one still reserves what it measures", function()
    local h = probe{ row_h = 37 }
    eq(h, 37, "the real row height is what the layout subtracts")
end)

t.test("no book still falls back, because the strip does still render", function()
    -- The fallback has to survive: with the region ON but no current book,
    -- the strip is real and the layout needs a number before it can build it.
    local h = probe{ no_book = true }
    eq(h, 20, "the Screen:scaleBySize(20) fallback is for a missing BOOK, not a disabled line")
end)

t.test("a disabled line does not even build a row to measure", function()
    local _, _, built = probe{ disabled = true }
    eq(built, 0, "asking the region first avoids the probe build entirely")
end)

t.test("the answer is memoised either way", function()
    local h, _, _, self_ = probe{ disabled = true }
    eq(h, 0)
    eq(self_._strip_h_memo and self_._strip_h_memo.h, 0,
       "the zero must be memoised like any other answer")
    local h2 = probe{ row_h = 37 }
    eq(h2, 37)
end)

t.done()
