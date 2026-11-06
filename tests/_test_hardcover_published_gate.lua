-- tests/_test_hardcover_published_gate.lua
-- The Hardcover first-published year is a book's publication date only with
-- Use Hardcover metadata on. enrichBook (full records: %published, the
-- Published sort, the book menu) set it regardless, while applyMetadata (the
-- light records the group shelves are built from) gated it, so with the
-- switch off a linked book showed its Hardcover year in the token but went in
-- another decade on the Decades shelf.
-- Usage (from plugin root): lua tests/_test_hardcover_published_gate.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

local src = io.open("lib/bookshelf_hardcover.lua"):read("*a")

local function body(name)
    local s = src:match("\nfunction Hardcover%." .. name .. "%(.-\nend\n")
    assert(s, "Hardcover." .. name .. " moved")
    return s
end

t.test("enrichBook sets the Hardcover year only with Use Hardcover metadata on", function()
    local b = body("enrichBook")
    local at = b:find("book.hardcover_published =", 1, true)
    assert(at, "enrichBook no longer sets hardcover_published")
    -- The nearest enclosing condition before the assignment names the switch.
    local before = b:sub(1, at)
    local last_if = before:match(".*\n%s*(if .-then)%s*\n[^\n]*$")
    assert(last_if and last_if:find("hardcover_use_metadata", 1, true),
        "the assignment is not guarded by hardcover_use_metadata: " .. tostring(last_if))
end)

t.done()
