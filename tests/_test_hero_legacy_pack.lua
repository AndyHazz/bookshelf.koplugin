-- tests/_test_hero_legacy_pack.lua
-- HeroModules._legacyPack: the old aspect-aware row packer, kept as the
-- source the grid migration snaps from. Pins its output on a known input so
-- the extraction out of HeroModules.build is a pure move (same widths, same
-- row height) and so migration keeps seeing what users saw.
--
-- Driven against the real function body, extracted by name, as
-- _test_hero_flex_width does.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")

local body = src:match(
    "\nfunction HeroModules%._legacyPack%(items, content_w, hero_h, gap, row_avail%)\n(.-)\nend\n")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local SQUARE = { analogue_clock = true }

local function pack(items, content_w, hero_h, gap, row_avail)
    assert(body, "could not find HeroModules._legacyPack - renamed?")
    local env = {
        math = math, ipairs = ipairs, tonumber = tonumber,
        Modules = { get = function(key) return { aspect = SQUARE[key] and "square" or nil } end },
        HeroModules = { _flexMinWidth = function() return 300 end },
    }
    local fn = compile("local items, content_w, hero_h, gap, row_avail = ...\n" .. body,
        env, "_legacyPack")
    return fn(items, content_w, hero_h, gap, row_avail)
end

local function E(id, module, size) return { id = id, module = module, size = size } end

t.test("a clock and two flex cards share one row, square capped", function()
    local res = pack({ E("c", "analogue_clock"), E("q", "quote"), E("g", "goal") }, 1000, 400, 10)
    assert(res.cell_h == 400, "cell_h " .. tostring(res.cell_h))
    assert(#res.rows == 1, "rows " .. #res.rows)
    local ws = {}
    for i, cell in ipairs(res.rows[1]) do ws[i] = cell.w end
    assert(table.concat(ws, ",") == "380,300,300", table.concat(ws, ","))
    assert(res.rows[1][1].entry.id == "c")
end)

t.test("size weights still scale a flex card", function()
    local res = pack({ E("a", "x", 2), E("b", "y") }, 1000, 400, 10)
    assert(#res.rows == 1, "rows " .. #res.rows)
    local a, b = res.rows[1][1].w, res.rows[1][2].w
    -- 990 split 1.6 : 1, rounding slack to the last flex card.
    assert(a == 609 and b == 381, a .. "," .. b)
end)

t.test("row_avail narrows one row", function()
    local res = pack({ E("q", "quote") }, 1000, 400, 10, function() return 900 end)
    assert(res.rows[1][1].w == 900, tostring(res.rows[1][1].w))
end)

t.done()
