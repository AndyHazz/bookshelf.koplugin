-- tests/_test_unfill_tap_feedback.lua
-- An unfilled button can still be tapped.
--
-- THE CRASH (#436). A PW5 running Bookshelf as the home screen, flash_ui at
-- its default, KOReader down with:
--
--     frontend/ui/widget/button.lua:406:
--     attempt to index field 'background' (a nil value)
--     ... in function '_doFeedbackHighlight'
--
-- WHY. A wallpaper turns every footer button into a white card floating over
-- the picture, so M.unfill clears the frame's fill. KOReader's tap feedback
-- for a TEXT button inverts that fill in place rather than setting the
-- invert flag:
--
--     if self[1].radius == nil or self.background then
--         self[1].radius = Size.radius.button
--         self[1].background = self[1].background:invert()
--
-- Our page counter is a text button, it is unfilled, and its radius is nil
-- unless it happens to hold d-pad focus. So nil:invert(), on every
-- wallpapered shelf, from a tap on the footer. Button itself never meets
-- this: Button:hide only unfills a button that has an ICON.
--
-- Both halves of that guard have to read false for the flag branch to run.
--
-- Usage (from plugin root): lua tests/_test_unfill_tap_feedback.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_wallpaper.lua"):read("*a")

local body = src:match("\nfunction M%.unfill%(active, %.%.%.%)\n(.-)\nend\n")
assert(body, "M.unfill moved or was renamed")

-- KOReader's own feedback decision, copied here so the test fails if our
-- unfilled buttons ever stop satisfying it. Mirrors button.lua:402 and :425.
local RADIUS_BUTTON = 7
local function koreaderWouldInvertTheFill(btn)
    if not btn.text then return false end            -- icon buttons are safe
    return btn.frame.radius == nil or btn.background
end
local function koreaderWouldInvertBack(btn)
    if not btn.text then return false end
    return btn.frame.radius == RADIUS_BUTTON
end

local function unfilled(btn)
    local env = {
        type = type, select = select, ipairs = ipairs, pairs = pairs,
        require = function() error("unfill should not need a module here") end,
    }
    local fn = assert(load("return function(active, ...)\n" .. body .. "\nend",
                           "unfill", "t", env))()
    fn(true, btn)
    return btn
end

t.test("the page counter survives its own tap", function()
    -- Exactly the shape the footer builds: text, no icon, radius nil because
    -- br() only answers for the focused button.
    local btn = { text = "1-58 of 254", frame = { background = "WHITE" } }
    unfilled(btn)
    eq(btn.frame.background, nil, "the fill has to go, that is the point")
    assert(not koreaderWouldInvertTheFill(btn),
        "KOReader would still invert a fill that is not there")
    assert(not koreaderWouldInvertBack(btn),
        "...and would still try to invert it back afterwards")
end)

t.test("a coloured button is unfilled safely too", function()
    -- self.background is the OTHER half of the guard, and it is true even
    -- when the frame's radius is set.
    local btn = { text = "Go", background = "BLUE",
                  frame = { background = "BLUE", radius = RADIUS_BUTTON } }
    unfilled(btn)
    assert(not koreaderWouldInvertTheFill(btn),
        "a button built with a colour still reaches the crashing branch")
end)

t.test("the fill is stashed where Button looks for it", function()
    local btn = { text = "x", frame = { background = "WHITE" } }
    unfilled(btn)
    eq(btn.frame.orig_background, "WHITE",
       "Button:show puts frame.orig_background back, so leave it there")
end)

t.test("a focused button keeps the radius it was given", function()
    -- br() answers with the focus radius for the focused button, and that
    -- ring is the whole point of it.
    local btn = { text = "x", frame = { background = "WHITE", radius = 3 } }
    unfilled(btn)
    eq(btn.frame.radius, 3, "the focus ring was squared off")
end)

t.test("an icon button is left as it was", function()
    -- These were never at risk: KOReader's text branch does not run for them,
    -- and Button:hide unfills them itself.
    local btn = { icon = "chevron.last", frame = { background = "WHITE" } }
    unfilled(btn)
    eq(btn.frame.background, nil)
    assert(not koreaderWouldInvertTheFill(btn))
end)

t.test("nothing happens when there is nothing behind the buttons", function()
    -- On a plain page the white fill is correct: it is what makes a button
    -- read as a button against the paper.
    local btn = { text = "x", frame = { background = "WHITE" } }
    local env = { type = type, select = select, ipairs = ipairs, pairs = pairs,
                  require = function() error("not needed") end }
    local fn = assert(load("return function(active, ...)\n" .. body .. "\nend",
                           "unfill", "t", env))()
    fn(false, btn)
    eq(btn.frame.background, "WHITE", "the fill went missing on a plain page")
end)

t.done()
