-- tests/_test_list_row_over_ground.lua
-- Over a painted ground, a list row paints no card of its own.
--
-- WHAT NEEDS PINNING. The shelf already draws a scrim panel behind its
-- content when a wallpaper or a background colour is showing, and the listing
-- sits on that. Each row was ALSO painting its own plate, so on device the
-- picture survived only in the gutters between rows (maintainer, with a
-- screenshot: "listing rows already sit on the scrim panel, they don't need
-- an extra background panel for each row").
--
-- Two surfaces fill paper, and both have to stop. The card's FrameContainer
-- is the obvious one. The other is every wrapping paragraph: TextBoxWidget
-- fills its own background whatever the frame does, which is why the row goes
-- through TransparentTextBox over a ground instead - the hero column's
-- solution, one ink composited as an alpha mask. The single-line TextWidget
-- needs nothing: it paints glyphs only.
--
-- ROW_BG is NOT cleared. It stays the notional paper that the muted-ink blend
-- and the focus ring reason about; the flag only decides whether it is filled
-- in. And the row's outer size must not move: dropping the border that
-- reserves the focus ring has to give that space back as padding, or every
-- row in the band changes height.
--
-- Usage (from plugin root): lua tests/_test_list_row_over_ground.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src    = io.open("lib/bookshelf_list_row.lua"):read("*a")
local widget = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nlocal function wrapBox%(line, flat, inner_w, height%)\n(.-)\nend\n")
assert(body, "wrapBox moved or was renamed")

local function wrapBoxWith(over_ground)
    local env = {
        ListRow = { ROW_BG = "PAPER", ROW_FG = "INK", OVER_GROUND = over_ground },
        TextBoxWidget      = { new = function(_, o) o.built = "opaque";      return o end },
        TransparentTextBox = { new = function(_, o) o.built = "transparent"; return o end },
        canEllipsis = function() return false end,
        type = type,
    }
    local fn, err = load("return function(line, flat, inner_w, height)\n" .. body .. "\nend",
        "wrapBox", "t", env)
    assert(fn, err)
    return fn()
end

local LINE = { face = "F", alignment = "left" }

t.test("on plain paper the paragraph fills the row's own paper, as before", function()
    local box = wrapBoxWith(false)(LINE, "hello", 100, 40)
    eq(box.built, "opaque")
    eq(box.bgcolor, "PAPER", "the row's paper must still be named, not defaulted to white")
end)

t.test("over a ground the paragraph composites in one ink and fills nothing", function()
    local box = wrapBoxWith(true)(LINE, "hello", 100, 40)
    eq(box.built, "transparent")
    eq(box.bgcolor, nil, "a filled background would punch the plate back through the scrim")
    eq(box.ink, "INK", "the composite needs the row's ink")
end)

t.test("a paragraph's own colour still wins over the row default", function()
    local box = wrapBoxWith(true)({ face = "F", fgcolor = "OWN" }, "hello", 100, 40)
    eq(box.ink, "OWN")
end)

t.test("the flag is a module-level switch, not a per-row argument", function()
    assert(src:find("\nfunction ListRow.setOverGround(on)\n", 1, true), "ListRow.setOverGround missing")
    assert(src:find("ListRow.OVER_GROUND = false", 1, true), "the default must be off, so a plain shelf is unchanged")
end)

t.test("the card paints no plate over a ground, and the row does not change size", function()
    -- From the marks_itself line through the frame: the branch that decides
    -- the card lives just above the constructor.
    local card = src:match("(local marks_itself = fill_tile.-local content = FrameContainer:new{.-\n    }\n)")
    assert(card, "the row's card frame moved")
    assert(card:find("over_ground", 1, true), "the card must consult the flag")
    -- Comments out of the way first: the code explains this very trap, and
    -- the phrase would otherwise match its own warning.
    local code = card:gsub("%-%-[^\n]*", "")
    -- `over and nil or X` is X, never nil: the background has to be assigned
    -- through a branch, which is what this looks for.
    assert(not code:find("and nil or", 1, true), "an `and nil or` background silently stays opaque")
    assert(card:find("INNER + BORDER", 1, true),
        "dropping the ring border must give its space back as padding, or every row shrinks")
end)

t.test("ROW_BG survives as the notional paper for the muted-ink blend", function()
    assert(src:find("ListRow.ROW_BG:getColor8()", 1, true),
        "the blend still needs a paper colour to reason about")
end)

t.test("the shelf tells the row before it builds anything, like the spine shelf", function()
    local block = widget:match("\n    do\n        local on = self:groundIsPainted%(%)\n(.-)\n    end\n")
    assert(block, "the early ground block in _rebuild moved")
    assert(block:find("setHasWallpaper(on)", 1, true), "the spine shelf is still told here")
    assert(block:find("setOverGround(on)", 1, true),
        "the list row must be told in the SAME early block; later is too late, the rows are already made")
end)

t.done()
