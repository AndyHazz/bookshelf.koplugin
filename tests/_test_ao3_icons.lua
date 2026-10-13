-- tests/_test_ao3_icons.lua
-- The AO3 symbols feature: tag matching (lib/bookshelf_ao3_icons.lua's
-- iconsFor), the icon grid's deterministic native-resolution sizing, the
-- two independent settings toggles (list row / top panel) and the shared
-- test both the top panel and the tags pill-width calc read to agree on
-- which books get the small AO3 corner slot.
--
-- Widget construction (newWidget/newCornerWidget) is stubbed with a plain
-- pass-through constructor rather than a real layout engine -- good enough
-- to assert the OUTER box size a caller gets back and whether a grid was
-- actually built, which is what the surrounding code depends on. The pixel
-- geometry inside that box (icon cell size, gaps) is asserted directly
-- against the same formula the module uses, which is the point: a
-- regression there is a silent visual change no screenshot test here would
-- catch either, so the two must be read off the same arithmetic.

package.path = "./?.lua;./?/init.lua;" .. package.path

local BORDER = 1
local GAP = 2
package.loaded["ui/size"] = { border = { thin = BORDER } }
package.loaded["device"] = { screen = { scaleBySize = function(_, n) return n end } }
package.loaded["ui/geometry"] = { new = function(_, t) return t end }
package.loaded["ffi/blitbuffer"] = { COLOR_LIGHT_GRAY = 1 }
package.loaded["lib/bookshelf_image_source"] = { loadImage = function() return nil end }

-- A plain pass-through :new{...} for every container AO3.newWidget /
-- newCornerWidget builds: keeps whatever fields/positional children the
-- real call passed (so dimen and child widgets are still inspectable) and
-- adds a :getSize() that answers dimen when one was set. Not a layout
-- engine -- nested widths/heights inside a grid are asserted against the
-- module's own formula below, not read back out of these stubs.
local function widgetCtor()
    return {
        new = function(_, o)
            o = o or {}
            o.getSize = o.getSize or function(self) return self.dimen or { w = 0, h = 0 } end
            return o
        end,
    }
end
for _, name in ipairs({
    "ui/widget/widget",
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/container/topcontainer",
    "ui/widget/horizontalgroup",
    "ui/widget/verticalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/verticalspan",
    "ui/widget/imagewidget",
}) do
    package.loaded[name] = widgetCtor()
end

-- The settings store, in memory -- the same shape _test_list_lines.lua uses,
-- since listBadgesEnabled/heroBadgesEnabled read through the identical
-- read/isTrue contract.
local STORE = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(k, default)
        local v = STORE[k]
        if v == nil then return default end
        return v
    end,
    save   = function(k, v) STORE[k] = v end,
    isTrue = function(k) return STORE[k] == true end,
    flush  = function() end,
}

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()
local eq      = helpers.eq

local AO3 = dofile("lib/bookshelf_ao3_icons.lua")

local function reset() for k in pairs(STORE) do STORE[k] = nil end end

-- ── iconsFor: the tag-matching logic ────────────────────────────────────────

t.test("rating, category, warning and completion all match from genres", function()
    local book = { genres = {
        "Rating: Teen And Up Audiences",
        "F/M",
        "Graphic Depictions Of Violence",
        "Complete Work",
    } }
    eq(AO3.iconsFor(book), {
        rating   = "rating-teen",
        category = "category-het",
        warning  = "warning-yes",
        complete = "complete-yes",
    })
end)

t.test("case and surrounding whitespace don't matter", function()
    local book = { genres = { "  rating:  MATURE  " } }
    eq(AO3.iconsFor(book).rating, "rating-mature")
end)

t.test("'no archive warnings apply' maps to the no-warning icon", function()
    local book = { genres = { "No Archive Warnings Apply" } }
    eq(AO3.iconsFor(book).warning, "warning-no")
end)

t.test("an explicit 'incomplete' tag wins over a later bare 'complete'", function()
    -- COMPLETE_NO is checked after COMPLETE_YES in the SAME pass, but
    -- "incomplete" contains "complete" as a substring -- the find() guards
    -- against that false positive are the thing under test here.
    local book = { genres = { "Incomplete" } }
    eq(AO3.iconsFor(book).complete, "complete-no")
end)

t.test("an unrecognised tag is silently ignored, not an error", function()
    local book = { genres = { "Crossover", "Alternate Universe" } }
    eq(AO3.iconsFor(book), {})
end)

t.test("completion falls back to 'Chapters: N/M' in the description when no tag has it", function()
    local done = { genres = {}, description = "Chapters: 5/5\nSome summary." }
    local wip  = { genres = {}, description = "Chapters: 2/?\nSome summary." }
    eq(AO3.iconsFor(done).complete, "complete-yes")
    eq(AO3.iconsFor(wip).complete, "complete-no")
end)

t.test("a book with no genres table and no description has nothing to show", function()
    eq(AO3.iconsFor({}), {})
    eq(AO3.iconsFor(nil), {})
end)

-- ── Deterministic sizing ─────────────────────────────────────────────────

t.test("footprintSize is two native 25dp cells plus the gap, both ways", function()
    local side = 25 + 2 * BORDER
    local span = 2 * side + GAP
    local w, h = AO3.footprintSize()
    eq({ w, h }, { span, span })
end)

t.test("heroSlotSize adds an 8dp margin on top of the footprint", function()
    local fw, fh = AO3.footprintSize()
    local w, h = AO3.heroSlotSize()
    eq({ w, h }, { fw + 8, fh + 8 })
end)

-- ── newWidget: the list row's call ──────────────────────────────────────────

t.test("newWidget rejects a non-numeric or non-positive box", function()
    eq(AO3.newWidget({}, 0, 50), nil)
    eq(AO3.newWidget({}, 50, "x"), nil)
end)

t.test("newWidget returns a bare box, no grid, for a book with no matching tags", function()
    local w = AO3.newWidget({ genres = { "Crossover" } }, 60, 60)
    eq(w:getSize(), { w = 60, h = 60 })
    eq(w[1], nil, "a tagless book must not get a grid child")
end)

t.test("newWidget returns the requested outer size AND a grid child when tags match", function()
    local w = AO3.newWidget({ genres = { "Mature" } }, 60, 60)
    eq(w:getSize(), { w = 60, h = 60 })
    assert(w[1] ~= nil, "a tagged book must get a grid child")
end)

t.test("newWidget degrades to a bare box when the box is too small for even one icon", function()
    local w = AO3.newWidget({ genres = { "Mature" } }, 4, 4)
    eq(w:getSize(), { w = 4, h = 4 })
    eq(w[1], nil)
end)

-- ── newCornerWidget: the top panel's call ───────────────────────────────────

t.test("newCornerWidget is nil for a book with no matching tags", function()
    eq(AO3.newCornerWidget({ genres = { "Crossover" } }, 200, 200), nil)
end)

t.test("newCornerWidget's outer box is exactly max_w x max_h", function()
    local w = AO3.newCornerWidget({ genres = { "Mature" } }, 200, 300)
    eq(w:getSize(), { w = 200, h = 300 })
end)

t.test("newCornerWidget's inner block is flush to the top with no offset", function()
    local side = math.min(math.floor(200 / 2), math.floor(300 / 2), 25 + 2 * BORDER)
    local grid_h = 2 * side + GAP
    local w = AO3.newCornerWidget({ genres = { "Mature" } }, 200, 300)
    -- w[1] is the LeftContainer; its own dimen.h is offset + grid_h, 0 offset here.
    eq(w[1]:getSize(), { w = 200, h = grid_h })
end)

t.test("newCornerWidget's top_offset pushes the inner block down by that much", function()
    local side = math.min(math.floor(200 / 2), math.floor(300 / 2), 25 + 2 * BORDER)
    local grid_h = 2 * side + GAP
    local w = AO3.newCornerWidget({ genres = { "Mature" } }, 200, 300, 40)
    eq(w[1]:getSize(), { w = 200, h = 40 + grid_h })
end)

t.test("newCornerWidget clamps an offset bigger than the box can hold", function()
    local side = math.min(math.floor(60 / 2), math.floor(70 / 2), 25 + 2 * BORDER)
    local grid_h = 2 * side + GAP
    local w = AO3.newCornerWidget({ genres = { "Mature" } }, 60, 70, 500)
    -- Offset clamps to (max_h - grid_h): the block can never be pushed past
    -- the box's own bottom edge.
    eq(w[1]:getSize(), { w = 60, h = (70 - grid_h) + grid_h })
end)

-- ── The two independent toggles ─────────────────────────────────────────────

t.test("both toggles default off", function()
    reset()
    eq(AO3.listBadgesEnabled(), false)
    eq(AO3.heroBadgesEnabled(), false)
end)

t.test("the two toggles are independent of each other", function()
    reset()
    STORE["list_ao3_badges"] = true
    eq(AO3.listBadgesEnabled(), true)
    eq(AO3.heroBadgesEnabled(), false, "the top panel toggle must not follow the list row one")

    reset()
    STORE["hero_ao3_badges"] = true
    eq(AO3.heroBadgesEnabled(), true)
    eq(AO3.listBadgesEnabled(), false, "the list row toggle must not follow the top panel one")
end)

-- ── heroUsesCorner: the shared decision the top panel and the tags pill-
--    width calc (bookshelf_widget.lua) both have to agree on ──────────────

t.test("heroUsesCorner is false when the toggle is off, even with a tagged coverless book", function()
    reset()
    eq(AO3.heroUsesCorner({ genres = { "Mature" } }), false)
end)

t.test("heroUsesCorner is false for a book that already has a cover", function()
    reset()
    STORE["hero_ao3_badges"] = true
    eq(AO3.heroUsesCorner({ genres = { "Mature" }, has_cover = true }), false)
end)

t.test("heroUsesCorner is false for a coverless book with no matching tags", function()
    reset()
    STORE["hero_ao3_badges"] = true
    eq(AO3.heroUsesCorner({ genres = { "Crossover" } }), false)
end)

t.test("heroUsesCorner is true only when all three conditions hold", function()
    reset()
    STORE["hero_ao3_badges"] = true
    eq(AO3.heroUsesCorner({ genres = { "Mature" } }), true)
end)

t.done()
