-- tests/_test_ornament_json.lua
-- ornaments.json: per-ornament placement (size, height, padding, hang,
-- night, mirror, tap action) that follows the FILE onto every shelf. One in
-- the ornaments folder for the reader's own changes, one in each pack for
-- what the pack ships. Numbers are in the ornament's own proportions and the
-- books' height, so they hold at any DPI and shelf size.

package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }
package.loaded["ui/widget/widget"] = { extend = function(_, t) return t end }
package.loaded["ui/geometry"] = { new = function(_, t) return t end }
local function sh(cmd)
    local f = io.popen(cmd .. " 2>/dev/null"); local out = f:read("*a"); f:close(); return out
end
local lfs_shim = {
    attributes = function(path, attr)
        local q = "'" .. path .. "'"
        if attr == "mode" then
            if sh("test -d " .. q .. " && echo d"):match("d") then return "directory" end
            if sh("test -e " .. q .. " && echo f"):match("f") then return "file" end
            return nil
        elseif attr == "modification" then
            local m = sh("stat -c %Y " .. q)
            return tonumber(m)
        end
        return nil
    end,
    mkdir = function(path) return os.execute("mkdir -p '" .. path .. "'") end,
    dir = function(path)
        local list = {}
        for name in sh("ls -a '" .. path .. "'"):gmatch("[^\n]+") do list[#list + 1] = name end
        local i = 0
        return function() i = i + 1; return list[i] end
    end,
}


local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local mem = {}
local function fresh()
    package.loaded["lib/bookshelf_ornaments"] = nil
    local O = dofile("lib/bookshelf_ornaments.lua")
    O.SCAN_TTL = 0
    mem = {}
    O._store = { read = function(k) return mem[k] end, save = function(k, v) mem[k] = v end }
    return O
end
local tmp = os.getenv("TMPDIR") or "/tmp"
local function scratch()
    local d = string.format("%s/bookshelf_orn_json_%d_%d", tmp, os.time(), math.random(1e6))
    os.execute("rm -rf '" .. d .. "' && mkdir -p '" .. d .. "'")
    return d
end
local function svg(path, extra)
    local f = assert(io.open(path, "w")); f:write('<svg viewBox="0 0 10 10">' .. (extra or "") .. '</svg>'); f:close()
end
local function write(path, text) local f = assert(io.open(path, "w")); f:write(text); f:close() end
-- A tiny JSON reader for the test: the device uses rapidjson.
local function decode(text)
    local lua = text:gsub('"([^"]-)"%s*:', '["%1"]=')
    local f = assert(load("return " .. lua), "bad json")
    return f()
end
local function setup()
    local O = fresh()
    local d = scratch()
    O._data_dir = d; O._lfs = lfs_shim; O._decode = decode
    local new = d .. "/settings/bookshelf/ornaments"
    os.execute("mkdir -p '" .. new .. "/Autumn'")
    return O, new
end
local function byName(O)
    local out = {}
    for _i, e in ipairs(O.listAll()) do out[e.name] = e end
    return out
end

t.test("defaults when there is no file", function()
    local O, new = setup()
    svg(new .. "/cat.svg")
    local e = byName(O)["cat.svg"]
    eq(e.scale, 1); eq(e.lift, 0); eq(e.pad, 0); eq(e.mirror, "off")
    eq(e.anchor, "bottom", "a piece does not stand by default")
    eq(e.tap, nil)
end)

t.test("a pack's file places its pieces", function()
    local O, new = setup()
    svg(new .. "/Autumn/owl.svg")
    write(new .. "/Autumn/ornaments.json", '{ "owl.svg": { "scale": 1.5, "anchor": "top", "mirror": "alternate" }, "fox.svg": { "lift": 1 } }')
    svg(new .. "/Autumn/fox.svg")
    local e = byName(O)["Autumn/owl.svg"]
    eq(e.scale, 1.5); eq(e.anchor, "top"); eq(e.mirror, "alternate")
    local fox = byName(O)["Autumn/fox.svg"]
    eq(fox.anchor, "bottom", "a raised piece is not one hanging from the shelf above")
end)

t.test("the reader's own file adjusts the pack's, field by field, keyed Pack/file", function()
    local O, new = setup()
    svg(new .. "/Autumn/owl.svg")
    write(new .. "/Autumn/ornaments.json", '{ "owl.svg": { "scale": 1.5, "pad": 0.1 } }')
    write(new .. "/ornaments.json", '{ "Autumn/owl.svg": { "scale": 0.8 } }')
    local e = byName(O)["Autumn/owl.svg"]
    eq(e.scale, 1.2, "the reader's scale, on top of the pack's")
    eq(e.pad, 0.1, "the pack's padding, which the reader did not change")
end)

t.test("a directive still works beside the files", function()
    -- The overhang is the file's own (where its feet are); height is a place
    -- between the shelves, set on top of it.
    local O, new = setup()
    svg(new .. "/pot.svg", "<!-- bookshelf:overhang=2 -->")
    local e = byName(O)["pot.svg"]
    eq(e.overhang, 0.2, "overhang 2 of 10"); eq(e.lift, 0)
    write(new .. "/ornaments.json", '{ "pot.svg": { "lift": 0.5 } }')
    O.invalidate()
    local e2 = byName(O)["pot.svg"]
    eq(e2.lift, 0.5); eq(e2.overhang, 0.2, "a height lost the file's overhang")
end)

t.test("bad values are skipped and clamped, the rest applies", function()
    local O, new = setup()
    svg(new .. "/cat.svg")
    write(new .. "/ornaments.json", '{ "cat.svg": { "scale": 99, "lift": "high", "mirror": "sideways", "pad": -0.05 } }')
    local e = byName(O)["cat.svg"]
    eq(e.scale, 4, "clamped to the most a nudge allows")
    eq(e.lift, 0, "a non-number is ignored")
    eq(e.mirror, "off")
    eq(e.pad, -0.05, "negative padding tightens")
end)

t.test("an edited file is seen without a restart", function()
    local O, new = setup()
    O.SCAN_TTL = 0
    svg(new .. "/cat.svg")
    write(new .. "/ornaments.json", '{ "cat.svg": { "scale": 1.2 } }')
    eq(byName(O)["cat.svg"].scale, 1.2)
    os.execute("sleep 1")
    write(new .. "/ornaments.json", '{ "cat.svg": { "scale": 1.4 } }')
    eq(byName(O)["cat.svg"].scale, 1.4, "the change was missed")
end)

t.test("a broken file is logged and ignored, not fatal", function()
    local O, new = setup()
    svg(new .. "/cat.svg")
    write(new .. "/ornaments.json", '{ this is not json')
    O._decode = function() error("bad json") end
    local e = byName(O)["cat.svg"]
    assert(e, "the ornament vanished")
    eq(e.scale, 1)
end)

t.test("a reader's change applies at once, and is written when asked", function()
    local O, new = setup()
    svg(new .. "/Autumn/owl.svg")
    write(new .. "/Autumn/ornaments.json", '{ "owl.svg": { "scale": 1.5, "pad": 0.1 } }')
    local e = byName(O)["Autumn/owl.svg"]
    O.readerSet(e, "scale", 0.7)
    eq(e.scale, 1.05, "not applied to the piece, on top of the pack's")
    eq(e.pad, 0.1, "the pack's other values went")
    local written
    O._encode = function(t) written = t; return "{}" end
    assert(O.saveReader())
    eq(written["Autumn/owl.svg"].scale, 0.7, "keyed Pack/file in the reader's file")
    local f = io.open(new .. "/Autumn/ornaments.json"):read("*a")
    assert(not f:find("0.7", 1, true), "the pack's own file was written")
end)

t.test("a pack's values are the reader's starting point: size multiplies, padding and height add", function()
    -- Maintainer: a pack maker's sizes and heights "become the 0% settings",
    -- so a reader's Reset goes back to the pack's own, and the menu shows 100%
    -- and 0% there. Anchor, mirror and tap still simply replace the pack's.
    local O, new = setup()
    svg(new .. "/Autumn/owl.svg")
    write(new .. "/Autumn/ornaments.json", '{ "owl.svg": { "scale": 1.6, "lift": 0.1, "pad": 0.05, "mirror": "always" } }')
    local e = byName(O)["Autumn/owl.svg"]
    eq(e.scale, 1.6); eq(e.lift, 0.1)
    eq(O.readerValue(e, "scale"), 1, "the menu does not start from 100% at the pack's size")
    eq(O.readerValue(e, "lift"), 0)
    O.readerSet(e, "scale", 1.25); O.readerSet(e, "lift", -0.05); O.readerSet(e, "pad", 0.05)
    O.readerSet(e, "mirror", "off")
    eq(e.scale, 2.0); eq(e.lift, 0.05); eq(e.pad, 0.1); eq(e.mirror, "off")
    O.readerSet(e, "scale", 4)
    eq(e.scale, 4, "the product is not kept to the limits")
    O.readerReset(e)
    eq(e.scale, 1.6, "reset does not go back to the pack's own size"); eq(e.lift, 0.1)
end)

t.test("reset drops the reader's record; the pack shows again", function()
    local O, new = setup()
    svg(new .. "/Autumn/owl.svg")
    write(new .. "/Autumn/ornaments.json", '{ "owl.svg": { "scale": 1.5 } }')
    local e = byName(O)["Autumn/owl.svg"]
    O.readerSet(e, "scale", 0.7)
    O.readerSet(e, "lift", 0.2)
    O.readerReset(e)
    eq(e.scale, 1.5); eq(e.lift, 0)
    eq(O.readerTable()["Autumn/owl.svg"], nil)
end)

t.test("a directive survives a reader's change to another field", function()
    local O, new = setup()
    svg(new .. "/pot.svg", "<!-- bookshelf:overhang=2 -->")
    local e = byName(O)["pot.svg"]
    O.readerSet(e, "scale", 1.2)
    eq(e.overhang, 0.2, "the directive's overhang was lost on re-apply")
    O.readerSet(e, "lift", nil)
    eq(e.overhang, 0.2); eq(e.lift, 0)
end)

t.test("nudges step on a grid and stop at the limits", function()
    package.loaded["ffi/util"] = { template = function(s) return s end }
    package.loaded["lib/bookshelf_ornaments"] = fresh()
    local O = package.loaded["lib/bookshelf_ornaments"]
    local Menu = dofile("lib/bookshelf_ornament_menu.lua")
    -- Nudges step the reader's own adjustment (Ornaments.readerValue).
    O._reader, O._reader_mtime = {}, nil
    O.readerTable = function() return O._reader end
    local e = { name = "x.svg" }
    for _i = 1, 3 do O.readerSet(e, "lift", Menu.nudged(e, "lift", 0.1)) end
    eq(O.readerValue(e, "lift"), 0.3, "three steps of 0.1 drifted")
    O.readerSet(e, "scale", 3.9)
    eq(Menu.nudged(e, "scale", 0.25), 4, "past the most a nudge allows")
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(src:find("\\xEE\\xA1\\x82", 1, true) and src:find("\\xEE\\xA0\\xBF", 1, true),
        "up/down are not the bookends chevrons")
    assert(src:find("hold_callback", 1, true), "no big step on hold")
    assert(src:find("function dialog:onCloseWidget%(%.%.%.%)\n%s*Orn%.saveReader%(%)"),
        "nothing writes the file when the menu closes")
end)

t.test("the piece on the shelf answers long-press and, with an action, tap", function()
    local O = fresh()
    local held, tapped
    O.handlers = { hold = function(e) held = e return true end, tap = function(e) tapped = e return true end }
    local plain = { entry = { name = "a.svg" } }
    local w = setmetatable({ placement = plain }, { __index = O.Ornament })
    assert(w:onHoldOrnament(), "long-press not taken")
    eq(held, plain.entry)
    eq(w:onTapOrnament(), false, "a piece with no action took the tap from the shelf")
    local acting = { entry = { name = "b.svg", tap = { action = "x" } } }
    local w2 = setmetatable({ placement = acting }, { __index = O.Ornament })
    assert(w2:onTapOrnament())
    eq(tapped, acting.entry)
    local wsrc = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(wsrc:find('Gestures.on("ornament_hold")', 1, true) and wsrc:find('Gestures.on("ornament_tap")', 1, true),
        "the ornament gestures cannot be switched off")
end)

t.test("the menu opens clear of the piece it adjusts", function()
    package.loaded["ffi/util"] = { template = function(s) return s end }
    package.loaded["lib/bookshelf_ornaments"] = fresh()
    local Menu = dofile("lib/bookshelf_ornament_menu.lua")
    eq(Menu.offsetFor({ y = 700, h = 200 }, 1648), 412, "a piece in the top half: menu goes down")
    eq(Menu.offsetFor({ y = 1200, h = 200 }, 1648), -412, "bottom half: menu goes up")
    eq(Menu.offsetFor(nil, 1648), 0)
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(src:find("dialog:reinit(); place()", 1, true), "a redraw loses the offset")
end)

t.test("menu fix: rapid nudges cannot dismiss the menu by missing it", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local show = src:match("dialog = dialogClass%(%):new{(.-)\n    }")
    assert(show and show:find("dismissable = false", 1, true), "a tap outside still closes the nudge menu")
end)

t.test("an edit reaches the piece the shelf draws, even after a rescan made new entries", function()
    -- Device report: "sometimes I'll make changes in the ornament menu and
    -- nothing changes; if I close and reopen, it has reverted". The menu
    -- held the entry from before a rescan (the reader's own save changes
    -- the file's mtime, which is in the scan key), and edited that one.
    local O, new = setup()
    O.SCAN_TTL = 0
    O._encode = function() return "{}" end
    svg(new .. "/cat.svg")
    local old = byName(O)["cat.svg"]
    O.readerSet(old, "scale", 1.2)
    O.saveReader()
    os.execute("sleep 1")
    write(new .. "/ornaments.json", '{ "cat.svg": { "scale": 1.2 } }')   -- as saved
    local fresh = byName(O)["cat.svg"]
    assert(fresh ~= old, "the rescan was expected to build new entries")
    O.readerSet(old, "scale", 1.5)       -- the menu still holds the old entry
    eq(byName(O)["cat.svg"].scale, 1.5, "the shelf's entry did not get the edit")
    eq(O.current(old).scale, 1.5, "the menu cannot find the live entry")
end)

t.test("an edit reaches the list() entry the shelf draws, while list() is still cached", function()
    -- The shelf draws from list(), which is served from its cache for
    -- SCAN_TTL. A save changes the file's mtime, so listAll() builds new
    -- entries; list() still hands out the old ones until the TTL runs out,
    -- and an edit applied only to listAll()'s never reached the shelf (rig:
    -- a hanging piece's height nudge did nothing).
    local O, new = setup()
    O.SCAN_TTL = 1000
    O._encode = function() return "{}" end
    svg(new .. "/cat.svg")
    local drawn = O.list()[1]
    O.readerSet(drawn, "scale", 1.2)
    O.saveReader()
    os.execute("sleep 1")
    write(new .. "/ornaments.json", '{ "cat.svg": { "scale": 1.2 } }')
    local live = O.current(drawn)
    assert(live ~= drawn, "the rescan was expected to build new entries")
    assert(O.list()[1] == drawn, "list() was expected to still be cached")
    O.readerSet(live, "lift", 0.2)       -- the menu edits the live entry
    eq(O.list()[1].lift, 0.2, "the entry the shelf draws did not get the edit")
end)

t.test("menu: Swap, Shuffle all and a Switch off/on toggle share a row; the toggle keeps the menu open", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local row = src:match('\n        {\n            { text = _%("Swap"%).-\n        },\n')
    assert(row, "no Swap row")
    assert(row:find('_("Shuffle all")', 1, true), "Shuffle all is not on the Swap row")
    assert(row:find('_("Switch on")', 1, true) and row:find('_("Switch off")', 1, true),
        "the Switch off/on toggle is not on the Swap row")
    local toggle = row:match("text_func = function%(%)%s*return Orn%.isOff%(entry%.name%).-end },")
    assert(toggle, "the toggle's label does not follow the piece's state")
    assert(not toggle:find("closeAnd", 1, true), "switching off closes the menu")
    assert(toggle:find("Orn.setOff(entry.name, not Orn.isOff(entry.name))", 1, true), "the toggle does not toggle")
    assert(src:find("Deck.swap(entry.name, chosen.name, shelf)", 1, true), "Swap does not trade places on this shelf")
    assert(src:find("bw:onBookshelfShuffleOrnaments()", 1, true), "Shuffle all is not the shuffle action")
end)

t.test("menu: each nudge row has 10-point buttons either side", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local pm = src:match("local function plusMinus%(field, label_func%)(.-)\n    end\n")
    assert(pm and pm:find("bigButton(field, -1)", 1, true) and pm:find("bigButton(field, 1)", 1, true),
        "size and padding have no 10-point buttons")
    assert(src:find('bigButton("lift", 1)', 1, true) and src:find('bigButton("lift", -1)', 1, true),
        "height has no 10-point buttons")
    package.loaded["lib/bookshelf_ornaments"] = nil
    local Menu = dofile("lib/bookshelf_ornament_menu.lua")
    eq(Menu.STEPS.scale[2], 0.10); eq(Menu.STEPS.pad[2], 0.10); eq(Menu.STEPS.lift[2], 0.10)
    eq(Menu.STEPS.pad[1], 0.01, "padding does not step by 1%"); eq(Menu.STEPS.lift[1], 0.01, "height does not step by 1%")
end)

t.test("size goes down to 5%, not stopping at half", function()
    local O = dofile("lib/bookshelf_ornaments.lua")
    eq(O.cleanField("scale", 0.2), 0.2)
    eq(O.cleanField("scale", 0), 0.05)
end)

t.test("menu: a picture of the piece under its name, even while it is switched off", function()
    package.loaded["lib/bookshelf_ornaments"] = nil
    local O = dofile("lib/bookshelf_ornaments.lua")
    local e = { name = "fox.png", path = "/o/fox.png", aspect = 2, overhang = 0.1,
                scale = 3, lift = 0.5, mirror = "always" }
    local pl = O.previewPlacement(e, 60, 1000)
    eq(pl.h, 60, "the preview is not the fixed height")
    eq(pl.w, 120, "the preview lost the piece's shape")
    eq(pl.mirror, true, "the preview ignores the mirror setting")
    eq(pl.offset, 0, "the preview shows the piece's height, not its drawing")
    eq(pl.anchor, "bottom", "the preview shows the piece's anchor"); eq(pl.below, 6, "the file's own 10% overhang")
    assert(pl.entry == e, "the preview does not render the piece itself")
    eq(O.previewPlacement(e, 60, 50).w, 50, "a wide piece overflows the dialog")
    local src = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    local paint = src:match("function M%.Ornament:paintTo%(bb, x, y%)(.-)\nend\n")
    assert(paint and paint:find("M.paintPlacement(", 1, true), "the shelf and the preview paint differently")
    local menu = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(menu:find("dialog:addWidget(headerWidget())", 1, true), "no picture in the menu")
    local rd = menu:match("local function redraw%(%)(.-)\n    end\n")
    assert(rd and rd:find("headerWidget()", 1, true), "the picture is not redrawn with the piece")
    local pw = menu:match("local function headerWidget%(%)(.-)\n    end\n")
    assert(pw and not pw:find("Orn.Ornament:new", 1, true), "the picture is a live ornament (a hold would open another menu)")
end)

t.test("silhouette: a flat-colour copy that keeps the drawing's shape, at a fraction of its alpha", function()
    package.loaded["lib/bookshelf_ornaments"] = nil
    local O = dofile("lib/bookshelf_ornaments.lua")
    local px = { [0] = { [0] = 255, [1] = 0 }, [1] = { [0] = 128, [1] = 40 } }   -- px[y][x] alpha
    local src = {
        getWidth = function() return 2 end, getHeight = function() return 2 end,
        getType = function() return 5 end,
        getPixel = function(_s, x, y)
            return { getColorRGB32 = function() return { r = 200, g = 10, b = 90, alpha = px[y][x] } end }
        end,
    }
    local set = {}
    local BB = {
        TYPE_BBRGB32 = 9,
        new = function(w, h) return { w = w, h = h, setPixel = function(_d, x, y, c) set[y * 2 + x] = c end } end,
        ColorRGB32 = function(r, g, b, a) return { r = r, g = g, b = b, alpha = a } end,
    }
    local dst = O.silhouette(src, 0, 0.4, BB)
    eq(dst.w, 2); eq(dst.h, 2)
    eq(set[0].alpha, 102, "full alpha at 40%"); eq(set[0].r, 0); eq(set[0].g, 0)
    eq(set[1] == nil or set[1].alpha == 0, true, "a clear pixel gained a shadow")
    eq(set[2].alpha, 51); eq(set[3].alpha, 16)
    local white = O.silhouette(src, 255, 0.4, BB)
    eq(set[0].r, 255, "the night shadow is not painted light (pre-inverted)")
end)

t.test("menu: the picture stands top left, may rise a quarter above the frame, with a drop shadow", function()
    local menu = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(menu:find("OrnDialog = ButtonDialog:extend", 1, true), "no dialog that can hold an overhang")
    local init = menu:match("function OrnDialog:init%(%)(.-)\n    end\n")
    assert(init and init:find("ButtonDialog.init(self)", 1, true) and init:find("VerticalSpan", 1, true),
        "the dialog does not reserve the strip the picture rises into (it would ghost on e-ink)")
    assert(menu:find("M%.OVERHANG%s*=%s*0%.25"), "the rise is not a quarter")
    local hdr = menu:match("local function headerWidget%(%)(.-)\n    end\n")
    assert(hdr and hdr:find("HorizontalGroup", 1, true), "the picture is not beside the name")
    assert(hdr:find("Orn.shadowFor(", 1, true), "no drop shadow")
    local paint = hdr:match("function pic:paintTo%(bb, x, y%)(.-)\n        end")
    assert(paint and paint:find("shadow", 1, true) and paint:find("Orn.paintPlacement", 1, true)
           and paint:find("shadow", 1, true) < paint:find("Orn.paintPlacement", 1, true),
        "the shadow is not painted under the picture")
    assert(not menu:match("dialogClass%(%):new{%s*\n%s*title ="), "the plain text title is still there")
end)

t.test("the menu picture is sized by the drawing, not by the file's transparent room", function()
    -- Rig: a lantern whose PNG carries room above the drawing barely rose
    -- above the frame, because the ROOM filled the box (the browser crops
    -- the same way, through contentBox).
    package.loaded["lib/bookshelf_ornaments"] = nil
    local O = dofile("lib/bookshelf_ornaments.lua")
    local e = { name = "lan.png", path = "/o/lan.png", aspect = 0.5, overhang = 0 }
    O._content["/o/lan.png|0.5"] = { 0.1, 0.25, 0.9, 1 }    -- the top quarter is empty
    local pl = O.previewPlacement(e, 60, 1000)
    assert(pl.crop, "no crop to the drawing")
    eq(pl.crop.h, 60, "the drawing is not the box's height")
    eq(pl.h, 80, "rendered too small to crop to 60")
    eq(pl.crop.y, 20)
    local src = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    local paint = src:match("function M%.paintPlacement%(bb, x, y, p, night%)(.-)\nend\n")
    assert(paint and paint:find("p.crop", 1, true), "the crop is not painted")
end)

t.test("menu: the piece's place in the order, with Earlier and Later, and Shuffle all asks first", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(src:find('local CHEV_LEFT  = "\\xEE\\xA1\\x80"', 1, true) and src:find('local CHEV_RIGHT = "\\xEE\\xA1\\x81"', 1, true),
        "not the shelf editor's left / right chevrons")
    assert(src:find('_("Place: %1 of %2")', 1, true), "the place in the order is not shown")
    assert(src:find("Deck.move(entry.name, delta, onNames(), shelf)", 1, true)
           and src:find("placeGlyph(CHEV_LEFT, -1)", 1, true)
           and src:find("placeGlyph(CHEV_RIGHT, 1)", 1, true)
           and src:find("enabled_func", 1, true)
           and src:find("return i ~= nil and #on > 1", 1, true),
        "Earlier / Later do not move the piece")
    local shuffle = src:match('{ text = _%("Shuffle all"%)(.-)end },')
    assert(shuffle and shuffle:find("ConfirmBox", 1, true), "Shuffle all does not ask first")
end)

t.test("the menu never moves past the screen's edge, however tall it is", function()
    package.loaded["lib/bookshelf_ornaments"] = nil
    local Menu = dofile("lib/bookshelf_ornament_menu.lua")
    -- 1648px screen, a 1300px menu: centred it has 174px either side, so a
    -- quarter-screen move (412) would push it off; it stops at the edge.
    eq(Menu.offsetFor({ y = 700, h = 200 }, 1648, 1300), 174)
    eq(Menu.offsetFor({ y = 1200, h = 200 }, 1648, 1300), -174)
    eq(Menu.offsetFor({ y = 700, h = 200 }, 1648, 600), 412, "a short menu still moves the full quarter")
    eq(Menu.offsetFor({ y = 700, h = 200 }, 1648, 1700), 0, "a menu taller than the screen stays centred")
end)

t.test("menu: mirror and tap share one row, short; no hang switch; the place row is first", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local b = src:match("local buttons = {(.-)\n    }\n")
    assert(b, "no buttons table")
    local first = b:gsub("%-%-[^\n]*", ""):match("^%s*(%b{})")
    assert(first and first:find("placeGlyph(CHEV_LEFT, -1)", 1, true), "the place row is not the first row")
    local row = b:match('\n        {\n(%s*{ text_func = function%(%) return MIRROR_LABEL.-)\n        },')
    assert(row and row:find("Tap: ", 1, true), "mirror and tap are not one row")
    assert(not src:find('_("Hang: on")', 1, true) and not src:find('set("hang"', 1, true),
        "the hang switch is still in the menu (a height of 100% replaces it)")
end)

t.test("menu: the height row runs down to up, left to right, like - and +", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local row = src:match('\n        {\n            bigButton%("lift", %-1%),(.-)\n        },')
    assert(row, "the height row does not start with -10")
    local d, u = row:find("CHEV_DOWN", 1, true), row:find("CHEV_UP", 1, true)
    assert(d and u and d < u and row:find('bigButton("lift", 1)', 1, true) > u, "up is not on the right")
end)

t.test("the collection: one icon on its menu row and in the long-press menu's header", function()
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local row = st:match("function Settings:_ornamentsRow%(%)(.-)\nend\n")
    assert(row, "no ornaments row")
    assert(row:find('_("Ornament collection: %1/%2 enabled")', 1, true), "the row is not the collection with its count")
    assert(row:find("#O.listAll()", 1, true), "the count has no total")
    assert(row:find("COLLECTION_ICON", 1, true), "the row has no icon")
    local orn = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    assert(orn:find('M.COLLECTION_ICON = "\\xEF\\x83\\xB4"', 1, true), "the icon is not U+F0F4, kept in one place")
    local menu = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local hdr = menu:match("local function headerWidget%(%)(.-)\n    end\n")
    assert(hdr and hdr:find("Orn.COLLECTION_ICON", 1, true), "the header has no collection button")
    assert(hdr:find('require("lib/bookshelf_ornament_browser").show(', 1, true), "the header button does not open the collection")
end)

t.done()
