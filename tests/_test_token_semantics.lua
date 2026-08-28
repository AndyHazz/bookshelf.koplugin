-- tests/_test_token_semantics.lua
-- Runs the SHARED conformance fixture against the vendored semantics module.
-- The identical suite exists in bookends. Bookshelf #348.
-- Usage: cd into the plugin dir, then `lua tests/_test_token_semantics.lua`.

local Semantics = dofile("lib/token_semantics.lua")
local fixture   = dofile("lib/token_conformance.lua")

local unpack = table.unpack or unpack
local t = dofile("tests/_helpers.lua").runner()

t.test("fixture is non-empty", function()
    assert(#fixture > 0, "conformance fixture has no rows")
end)

t.test("every fixture row names a real function", function()
    for _i, row in ipairs(fixture) do
        if type(Semantics[row.fn]) ~= "function" then
            error("row " .. _i .. " names unknown function " .. tostring(row.fn))
        end
    end
end)

for _i, row in ipairs(fixture) do
    t.test(string.format("row %d: %s -> %q (%s)",
                         _i, row.fn, row.expect, row.why or ""), function()
        local got = Semantics[row.fn](unpack(row.args, 1, row.n))
        -- A row with `field` targets one key of a table result.
        if row.field then got = type(got) == "table" and got[row.field] or nil end
        if got ~= row.expect then
            error(string.format("%s expected=%q got=%q",
                                row.fn, tostring(row.expect), tostring(got)))
        end
    end)
end

t.done()
