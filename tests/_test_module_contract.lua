-- Static contract checks over every shipped micromodules/*.lua source.
-- Cheap guardrails so a contributed module can't ship two known footguns:
--   * StartMenu._live / _live:_reload — the start-menu-only refresh path that
--     silently no-ops in the hero grid; use the render `refresh` 5th arg.
--   * a missing `summary` — the picker's data-source/connectivity line.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local function sources()
    local out = {}
    local p = assert(io.popen("ls micromodules/*.lua"))
    for path in p:lines() do
        local f = assert(io.open(path, "r"))
        out[path] = f:read("*a")
        f:close()
    end
    p:close()
    return out
end

t.test("no module uses StartMenu._live (use the render `refresh` arg)", function()
    for path, src in pairs(sources()) do
        assert(not src:find("StartMenu%._live"), path .. " references StartMenu._live")
        assert(not src:find("_live:_reload"), path .. " references _live:_reload")
    end
end)

t.test("every shipped module declares a `summary`", function()
    for path, src in pairs(sources()) do
        assert(src:find("summary%s*="), path .. " missing `summary` field")
    end
end)

t.done()
