-- tests/_test_no_gettext_clobber.lua
-- No plugin file assigns to `_` when `_` is the file's gettext.
--
-- Usage (from plugin root): lua tests/_test_no_gettext_clobber.lua
--
-- Most files hold gettext in `local _ = require("lib/bookshelf_i18n").gettext`
-- and also use `_` as a throwaway name. A throwaway written WITHOUT `local`
-- (`_, a, b = f()`) doesn't throw anything away: it overwrites the file's
-- gettext, and every `_("...")` after it fails. Shelf size did exactly this in
-- its two-column fallback (PR 544): once drawn too narrow, the card showed only
-- its title until KOReader restarted.
--
-- The stray-globals guard can't see it -- `_` is a local captured by an inner
-- function, not a global, so the write compiles to SETUPVAL. The compiler's
-- listing annotates each one with the upvalue's name; fail on any that names
-- `_`.

package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local function which(cmd)
    local p = io.popen("command -v " .. cmd .. " 2>/dev/null")
    local out = p and p:read("*l"); if p then p:close() end
    return out and out ~= "" and out or nil
end
local luac = which("luac5.4") or which("luac5.5") or which("luac")

if not luac then
    print("SKIP  no luac on PATH")
    t.done()
    return
end

local files = {}
do
    local p = io.popen("find lib micromodules -name '*.lua' | sort")
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    files[#files + 1] = "main.lua"
end

t.test("no file writes to the upvalue `_`", function()
    local hits = {}
    for _i, f in ipairs(files) do
        local p = io.popen(luac .. " -l -l -p '" .. f .. "' 2>&1")
        local out = p:read("*a")
        p:close()
        for line in out:gmatch("[^\n]+") do
            -- e.g. "	100	[105]	SETUPVAL 	18 5	; _"
            local src_line = line:match("^%s*%d+%s+%[(%d+)%]%s+SETUPVAL%s.-;%s+_%s*$")
            if src_line then hits[#hits + 1] = f .. ":" .. src_line end
        end
    end
    assert(#hits == 0, "assigns to the gettext `_` (declare the throwaway local): "
        .. table.concat(hits, ", "))
end)

t.test("the scan sees real files", function()
    assert(#files > 50, "found only " .. #files .. " files")
end)

t.done()
