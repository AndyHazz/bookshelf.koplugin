-- lib/bookshelf_plural_guard.lua
-- KOReader's metadata scanner (coverbrowser's extractBooksInDirectory) calls
-- ngettext WITHOUT a count on its "not refreshing existing books" path. The
-- default plural rule (n ~= 1) shrugs at nil, but a language whose rule
-- compares, French "n > 1" among them, throws, and the scan dies before it
-- indexes anything (issue 516). ngettext looks GetText.getPlural up on every
-- call, so for the length of our scan a missing count is read as "many",
-- the form that message wants.
local M = {}

-- guard(GetText) -> restore(). Restores exactly what was there, including
-- "nothing of its own" when getPlural came from the metatable.
function M.guard(GetText)
    if type(GetText) ~= "table" then return function() end end
    local own = rawget(GetText, "getPlural")
    local orig = GetText.getPlural
    if type(orig) ~= "function" then return function() end end
    rawset(GetText, "getPlural", function(n)
        if n == nil then n = 2 end
        return orig(n)
    end)
    return function() rawset(GetText, "getPlural", own) end
end

return M
