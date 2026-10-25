-- tests/_test_anchor_has_x.lua
-- A dialog's anchor rect must carry its own x. KOReader v2026.03 (the
-- oldest Bookshelf supports) reads anchor.x straight away in
-- MovableContainer:ensureAnchor and crashed on nil (PW3, adding a module
-- to a spine shelf opened its menu); later versions centre a missing x.
-- The spine module menu centres itself the same way on every version.
--
-- Usage (from plugin root): lua tests/_test_anchor_has_x.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local function lua_files()
    local out = {}
    local p = io.popen("find lib micromodules main.lua -name '*.lua'")
    for f in p:lines() do out[#out + 1] = f end
    p:close()
    return out
end

t.test("no anchor rect is returned without an x", function()
    for _i, f in ipairs(lua_files()) do
        local src = io.open(f):read("*a")
        for line in src:gmatch("[^\n]+") do
            if line:match("return%s*{%s*y%s*=") then
                error(f .. ": an anchor without x: " .. line)
            end
        end
    end
end)

t.test("the spine module menu centres itself from its own width", function()
    local src = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(src:find("local cw = d and d.movable and d.movable.dimen and d.movable.dimen.w", 1, true),
        "the menu doesn't know its width")
    assert(src:find("return { x = math.floor((Screen:getWidth() - cw) / 2), y = r.y - gap, w = cw, h = r.h + 2 * gap }", 1, true),
        "the menu isn't centred by its own x")
end)

t.done()
