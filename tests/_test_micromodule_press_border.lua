-- tests/_test_micromodule_press_border.lua
-- A micro-module keeps its hairline after it has been tapped.
--
-- THE REPORT (#429). "Clicking any micro-module causes its outline stroke to
-- disappear. The outline only reappears after the micro-module panel is
-- reloaded."
--
-- THE BUG. An action card gets pressed-border feedback: swap margin into
-- border so the outer size does not move, repaint with the fast waveform,
-- then put it back. Putting it back is where it went wrong:
--
--     frame.bordersize = press_b   -- pressed
--     frame.margin     = 0
--     ...repaint...
--     frame.bordersize = 0         -- "reset to rest"
--     frame.margin     = press_b
--
-- Rest is NOT zero. The card is built with `bordersize = card_border`, the
-- Screen:scaleBySize(1) hairline. Zero was the correct rest value when this
-- was written, because the card was borderless then -- the hairline was added
-- afterwards ("Hairline, where this used to be borderless") and this reset
-- was never updated with it. So the first tap ate the outline and only a
-- rebuild of the panel put it back, which is precisely the report.
--
-- Nothing failed and nothing was logged: assigning a valid number to a live
-- field is not an error, it is just the wrong number.
--
-- Usage (from plugin root): lua tests/_test_micromodule_press_border.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")

-- The press-feedback block, lifted out whole. Anchored on the guard and on
-- the margin restore that closes it, so a changed comment cannot move it.
local block = src:match("(if press_b > 0 then\n.-frame%.margin = press_b\n        end)")
assert(block, "the press-feedback block moved or was renamed")

-- What the card is BUILT with, read from the source rather than assumed, so
-- this test tracks the real rest state instead of a copy of it.
local built_border = src:match("bordersize  = (card_border),")
local built_margin = src:match("margin      = (press_b), %-%- empty ring at rest")
assert(built_border, "the card no longer builds with card_border")
assert(built_margin, "the card no longer builds with press_b as its rest margin")

-- Run the block with the surrounding upvalues stubbed, exactly as it runs in
-- the widget: a live frame table, a press border, and a UIManager that does
-- nothing but let the sequence through.
local function press(card_border, press_b)
    local frame = { bordersize = card_border, margin = press_b }
    local seen = {}
    local env = {
        frame    = frame,
        press_b  = press_b,
        bw       = {},
        self     = { dimen = {} },
        UIManager = {
            setDirty = function(_, _, fn)
                -- snapshot what the pressed frame looked like at repaint time
                seen.at_paint_border = frame.bordersize
                seen.at_paint_margin = frame.margin
            end,
            forceRePaint = function() end,
        },
        card_border = card_border,
    }
    -- NB: load() returns the CHUNK; calling that yields the function, which
    -- then has to be called too. Missing the second call makes every
    -- assertion pass vacuously.
    local run = assert(load("return function()\n" .. block .. "\nend",
                            "press", "t", env))()
    run()
    return frame, seen
end

t.test("the press itself still shows a border and eats the margin", function()
    local _, seen = press(2, 6)
    eq(seen.at_paint_border, 6, "the pressed card paints with the press border")
    eq(seen.at_paint_margin, 0, "and with no margin, so its outer size does not move")
end)

t.test("and it is restored to the hairline afterwards, not to zero", function()
    local frame = press(2, 6)
    eq(frame.bordersize, 2, "the hairline must come back after a tap (#429)")
    eq(frame.margin, 6, "and the resting margin with it")
end)

t.test("the pressed ring is card_border narrower than the resting one", function()
    -- Recorded rather than asserted-as-correct. The comment in the widget says
    -- the swap leaves the outer size unchanged, and that stopped being true
    -- when the hairline was added: rest is card_border + press_b, pressed is
    -- press_b alone. It is a scaleBySize(1) difference for one fast repaint,
    -- nobody has reported it, and #429 is about the hairline never coming
    -- back -- so this pins what the code ACTUALLY does instead of quietly
    -- widening the fix. If the press geometry is ever revisited, this is the
    -- test that should change with it.
    local card_border, press_b = 2, 6
    local frame, seen = press(card_border, press_b)
    eq(seen.at_paint_border + seen.at_paint_margin, press_b,
       "pressed ring")
    eq(frame.bordersize + frame.margin, card_border + press_b,
       "resting ring")
end)

t.test("a passive card is left alone entirely", function()
    -- press_b == 0 means no tap feedback; the block must not touch the frame,
    -- or a passive module would lose its hairline without even being pressed.
    local frame = press(2, 0)
    eq(frame.bordersize, 2, "a passive card keeps its hairline")
    eq(frame.margin, 0, "and its margin")
end)

t.done()
