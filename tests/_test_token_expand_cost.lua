-- tests/_test_token_expand_cost.lua
-- Tokens.expand's final pass walks every REGISTERED token and rewrites the
-- string for each. There are 78 of them, so a four-token line paid for 78
-- gsubs over the whole result. Guarding each with a plain find makes the
-- skipped ones nearly free: 0.158ms -> 0.056ms per expand (2.8x) on a short
-- template, measured over 3000 expands.
--
-- That matters out of proportion to its size because expand is not called
-- once per screen: it runs for every region of the hero, every line of every
-- list row, and every status-line tick.
--
-- Correctness of the expansion itself is covered by _test_tokens.lua's 118
-- cases; this pins the guard, which is invisible to them -- remove it and
-- every one still passes, only slower.
package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local src  = io.open("lib/bookshelf_tokens.lua"):read("*a")
local body = src:match("\nfunction Tokens%.expand%(format, book, state%)\n(.-)\nend\n")

t.test("Tokens.expand is still there under that name", function()
    assert(body, "Tokens.expand is gone or its signature changed")
end)

t.test("a token absent from the template is not gsub'd", function()
    assert(body:match('result:find%("%%" %.%. name, 1, true%)'),
        "the per-token gsub must be guarded by a plain find, or every expand "
        .. "rewrites the string once per registered token")
end)

t.test("the guard tests the CURRENT result, not the original format", function()
    -- A token can be introduced by an earlier expansion. Testing `format`
    -- instead of `result` would silently stop expanding those, which no
    -- output test would catch unless it happened to use such a template.
    local guard = body:match("(result:find%(\"%%\" %.%. name[^\n]*)")
    assert(guard and not guard:match("format:find"),
        "the guard must look at result, so a token produced by an earlier "
        .. "expansion is still picked up")
end)

t.test("length-descending order is preserved", function()
    -- %authors must resolve before %author, or "%authors" becomes the %author
    -- expansion followed by a stray "s".
    assert(body:match("tokenNamesByLengthDesc%(%)"),
        "the ordering the loop depends on is gone")
end)

t.done()
