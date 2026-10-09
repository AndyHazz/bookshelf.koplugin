-- tests/_test_colour_resolver.lua
-- What the shelf PAINTS for each colour setting, over every kind of theme
-- (Custom, Plain, a pack with a colours.json, a pack without) and every
-- state of the part (the pack has it, lacks it, edited, edited to unset),
-- in both slots. Table-driven, so the readers can be folded into one
-- resolver (bookshelf_theme_pack) without a single answer changing: the
-- night slot pre-inverted, the plank the exception (display space), Plain
-- the defaults, Custom the reader's own, an edit over everything, UNSET the
-- default.
-- Run from the plugin root: lua tests/_test_colour_resolver.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local H  = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local function sh(cmd)
    local f = io.popen(cmd .. " 2>/dev/null"); local out = f:read("*a"); f:close(); return out
end
local lfs_shim = {
    attributes = function(path, attr)
        if attr ~= "mode" then return nil end
        local q = "'" .. path .. "'"
        if sh("test -d " .. q .. " && echo d"):match("d") then return "directory" end
        if sh("test -e " .. q .. " && echo f"):match("f") then return "file" end
        return nil
    end,
    dir = function(path)
        local list = {}
        for name in sh("ls -a '" .. path .. "'"):gmatch("[^\n]+") do list[#list + 1] = name end
        local i = 0
        return function() i = i + 1; return list[i] end
    end,
}
local function tiny_json(s)
    return assert((loadstring or load)("return " .. s:gsub('"([^"]-)"%s*:', '["%1"]=')))()
end
local d = string.format("%s/bookshelf_colour_resolver_%d_%d", os.getenv("TMPDIR") or "/tmp", os.time(), math.random(1e6))
local function touch(p, body)
    os.execute("mkdir -p \"$(dirname '" .. p .. "')\"")
    local f = io.open(p, "wb"); f:write(body or "x"); f:close()
end
os.execute("rm -rf '" .. d .. "'")
-- Lends text, page and plank, in both slots; not the badge.
touch(d .. "/Lends/theme/colours.json",
    '{"day":{"text":"#112233","page":"#445566","plank":"#806040"},"night":{"text":"#112233","page":"#445566","plank":"#403020"}}')
touch(d .. "/Lends/a.png")
touch(d .. "/Bare/theme/wallpaper.png"); touch(d .. "/Bare/b.png")

local settings = {}
local gen = 0
package.loaded["lib/bookshelf_theme_pack"] = nil
local TP = dofile("lib/bookshelf_theme_pack.lua")
TP._lfs, TP._decode, TP.SCAN_TTL, TP._plugin_root = lfs_shim, tiny_json, 0, "."
TP._orn = { dir = function() return d end, listAll = function() return {}, { "Bare", "Lends" } end,
            list = function() return {} end, listFor = function() return {} end,
            isOff = function() return false end, isPackOff = function() return false end }
local reads = 0
TP._store = { read = function(k) reads = reads + 1; return settings[k] end,
              save = function(k, v) settings[k] = v; gen = gen + 1 end, flush = function() end,
              generation = function() return gen end, bump = function() gen = gen + 1 end }
local tabs = {}
TP._tab = function(id) return tabs[id] end

-- shown(key): what the shelf paints, as the colour readers ask
-- (CoverProgress, the chip bar, the page ground): nil is the default.
local function shown(key)
    local v = TP.colour(key)
    return v and v.hex or "default"
end

local KEYS = { "ink_color", "badge_bg", "spine_plank_color", "wallpaper_bg" }
-- The reader's own value of each key in each slot.
local function own(key, night) return string.format("#%s%s", night and "A" or "B", ({ ink_color = "00001", badge_bg = "00002",
    spine_plank_color = "00003", wallpaper_bg = "00004" })[key]) end
-- What the pack lends, in its stored convention (night pre-inverted, the
-- plank not), or nil.
local LENDS = { ink_color = { "#112233", "#EEDDCC" }, wallpaper_bg = { "#445566", "#BBAA99" },
                spine_plank_color = { "#806040", "#403020" } }

local function setTheme(th)
    tabs.s = { id = "s", theme = th }
    TP._store.bump(); TP.setShelf("s")
end
local function reset()
    for k in pairs(settings) do settings[k] = nil end
    for _i, k in ipairs(KEYS) do
        settings[k] = { hex = own(k, false) }; settings[k .. "_night"] = { hex = own(k, true) }
    end
    TP._cur = nil; gen = gen + 1
end

t.test("every theme kind x part state x slot paints as before", function()
    local rows = 0
    for _i, kind in ipairs({ "mine", "plain", "Lends", "Bare" }) do
        for _j, state in ipairs({ "as is", "edited", "unset" }) do
            for _k, key in ipairs(KEYS) do
                for _n, night in ipairs({ false, true }) do
                    reset()
                    setTheme(kind)
                    local k = key .. (night and "_night" or "")
                    if state == "edited" then TP.partSave(k, { hex = "#0E0E0E" })
                    elseif state == "unset" then TP.partDelete(k) end
                    local want
                    if state == "edited" then want = "#0E0E0E"
                    elseif state == "unset" then want = "default"
                    elseif kind == "mine" then want = own(key, night)
                    elseif kind == "plain" then want = "default"
                    elseif kind == "Lends" and LENDS[key] then want = LENDS[key][night and 2 or 1]
                    else want = own(key, night) end
                    eq(shown(k), want, table.concat({ kind, state, key, night and "night" or "day" }, " / "))
                    rows = rows + 1
                end
            end
        end
    end
    eq(rows, 96)
end)

t.test("one theme_edits read a generation: a page of covers reads nothing more", function()
    reset(); setTheme("Lends")
    TP.partSave("badge_bg", { hex = "#0E0E0E" })
    TP._store.bump()
    local function cover() for _i, key in ipairs(KEYS) do shown(key); shown(key .. "_night") end end
    reads = 0
    cover()
    local first = reads
    assert(first <= 2 * 2 * #KEYS, "the first cover read the settings more than twice a key: " .. first)
    reads = 0
    for _cover = 2, 40 do cover() end
    eq(reads, 0, "the rest of a page of 40 covers read the settings again")
    TP._store.bump()
    shown("ink_color")
    assert(reads > 0, "a new generation was served the old colours")
end)

os.execute("rm -rf '" .. d .. "'")
t.done()
