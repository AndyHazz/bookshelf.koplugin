-- tests/_test_spine_cache_buffer_type.lua
-- A colour screen keeps its colour through the spine row's own render cache.
--
-- THE REPORT (issue 430). "On the recent update my book spines turned Black
-- or Gray color", on a colour e-reader, with the wallpaper behind them still
-- in full colour. Measured off the screenshot: every spine fill came back
-- with chroma exactly 0 while the wallpaper beside it reached 84.
--
-- WHY ONLY THE SPINES. A spine row renders once into a buffer of its own and
-- is blitted from there, so it is the one surface that can lose colour
-- without anything else on the page losing it. That buffer has to carry
-- ALPHA when a wallpaper is on, because the row paints no ground and lets the
-- picture through wherever a book is not standing.
--
-- THE BUG. Only two of the six blitbuffer types carry alpha: BB8A, which is
-- grey, and RGB32. The rule read "if it is not RGB32, use BB8A" -- which is
-- right for a greyscale screen and throws the colour away on RGB16 and RGB24,
-- both of which are colour buffers. A colour screen has to be promoted to
-- RGB32, not dropped to BB8A.
--
-- Usage (from plugin root): lua tests/_test_spine_cache_buffer_type.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

-- The six types, as ffi/blitbuffer numbers them.
local BB = {
    TYPE_BB4 = 0, TYPE_BB8 = 1, TYPE_BB8A = 2,
    TYPE_BBRGB16 = 3, TYPE_BBRGB24 = 4, TYPE_BBRGB32 = 5,
}

-- anchored on the rule's own comment: there are three `has_wallpaper`
-- branches in the file and only this one picks a buffer type
local block = src:match("(local colour = .-\n                        or Blitbuffer%.TYPE_BB8A)")
assert(block, "the wallpaper buffer-type branch moved or was renamed")
local pick = assert(load("local btype = ...\n" .. block .. "\nreturn btype",
                         "pick", "t", { Blitbuffer = BB }))

t.test("a colour screen renders the row in colour, with alpha", function()
    -- RGB32 is the only colour type that carries alpha, so all three land on
    -- it. Promoting RGB16/RGB24 costs two bytes a pixel in a cache that is
    -- already bounded; losing their colour costs the feature.
    eq(pick(BB.TYPE_BBRGB16), BB.TYPE_BBRGB32, "RGB16 is a COLOUR buffer")
    eq(pick(BB.TYPE_BBRGB24), BB.TYPE_BBRGB32, "RGB24 is a COLOUR buffer")
    eq(pick(BB.TYPE_BBRGB32), BB.TYPE_BBRGB32, "RGB32 already has alpha")
end)

t.test("a greyscale screen still gets the cheap alpha buffer", function()
    -- Two bytes a pixel rather than four, on the devices that cannot show
    -- the difference. This is the case the original rule was written for.
    eq(pick(BB.TYPE_BB4),  BB.TYPE_BB8A)
    eq(pick(BB.TYPE_BB8),  BB.TYPE_BB8A)
    eq(pick(BB.TYPE_BB8A), BB.TYPE_BB8A)
end)

t.test("every type is decided, none falls through", function()
    for name, v in pairs(BB) do
        local got = pick(v)
        assert(got == BB.TYPE_BBRGB32 or got == BB.TYPE_BB8A,
            name .. " came out as " .. tostring(got) .. ", which carries no alpha")
    end
end)

t.test("the rule is not written as 'not RGB32'", function()
    -- The shape that caused it: a single inequality against RGB32, which
    -- silently folds two colour types in with the greyscale ones.
    assert(not block:match("btype ~= Blitbuffer%.TYPE_BBRGB32"),
        "'not RGB32' is not the same question as 'not colour'")
    assert(block:find("TYPE_BBRGB16", 1, true) and block:find("TYPE_BBRGB24", 1, true),
        "the colour types have to be named, or the next one added is lost too")
end)

t.done()
