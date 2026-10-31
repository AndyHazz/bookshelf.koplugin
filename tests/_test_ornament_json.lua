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
            local m = sh(dofile("tests/_helpers.lua").statCmd("mtime", q))
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

t.test("trim is read from a pack's file and clamped to half the piece", function()
    local O, new = setup()
    svg(new .. "/Autumn/owl.svg"); svg(new .. "/Autumn/bat.svg"); svg(new .. "/Autumn/fox.svg")
    write(new .. "/Autumn/ornaments.json",
          '{ "owl.svg": { "trim": 0.12 }, "bat.svg": { "trim": 3 }, "fox.svg": { "trim": "lots" } }')
    eq(byName(O)["Autumn/owl.svg"].trim, 0.12)
    eq(byName(O)["Autumn/bat.svg"].trim, 0.5, "no more than half each side")
    eq(byName(O)["Autumn/fox.svg"].trim, 0, "a non-number is ignored")
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
    assert(src:find("local function big(sign) return function() nudge(field, sign, true) end end", 1, true)
           and src:find("hold = big(1), big = big(1)", 1, true), "no big step on hold")
    local cw = src:match("function dialog:onCloseWidget%(%)(.-)\n    end\n")
    assert(cw and cw:find("Orn.saveReader()", 1, true), "nothing writes the file when the menu closes")
    -- A shelf rebuild still waiting for the taps to pause runs first.
    assert(cw:find("if shelf_pending then", 1, true) and cw:find("rebuildShelf()", 1, true)
           and cw:find("rebuildShelf()", 1, true) < cw:find("Orn.saveReader()", 1, true),
        "a pending shelf rebuild is lost on close")
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

t.test("menu: a tap outside closes it; KOReader's gestures work around it", function()
    -- Rapid nudges once landed outside while a slow one caught up, so the
    -- menu swallowed them; nudges act at once now, and a tap outside closes
    -- it as every page does (maintainer). The top menu and brightness go to
    -- KOReader's zones first, off the panel.
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local to = src:match("function dialog:onTapOutside%(_arg, ges%)(.-)\n    end\n")
    assert(to and to:find("close()", 1, true) and to:find("not ges.pos:notIntersectWith(r)", 1, true),
        "a tap outside does not close the menu, or a tap on it does")
    assert(src:find("function dialog:onHoldOutside() return true end", 1, true), "a hold outside closes it")
    local he = src:match("function dialog:handleEvent%(event%)(.-)\n    end\n")
    assert(he and he:find("GZ.overlayEvent(self, event, InputContainer,", 1, true)
           and he:find("GZ.onWindow(event,", 1, true), "KOReader's gestures are dead round it")
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

t.test("menu: Swap, Shuffle this shelf and a Switch off/on toggle share a row; the toggle keeps the menu open", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    -- Left out for a pinned piece (opts.pinned), which is out of the deal.
    -- On the action bar; left out for a pinned piece (opts.pinned), which
    -- is out of the deal.
    local row = src:match('\n        if not opts%.pinned then\n(.-)\n        end\n        %-%- Fixed where it stands')
    assert(row and row:find('barButton(_("Swap"), Orn.COLLECTION_ICON', 1, true), "no Swap on the bar, with the collection's icon")
    assert(row:find('_("Shuffle this shelf")', 1, true), "Shuffle this shelf is not with Swap")
    assert(row:find('_("Show")', 1, true) and row:find('_("Hide")', 1, true),
        "the Hide/Show toggle is not with Swap")
    -- Through the seam (SW: the set of the theme on screen, or the collection's).
    local toggle = row:match("barButton%(sw%.isOff%(entry%.name%).-end%)")
    assert(toggle, "the toggle's label does not follow the piece's state")
    assert(not toggle:find("close()", 1, true), "switching off closes the menu")
    assert(toggle:find("sw.setOff(entry.name, not sw.isOff(entry.name))", 1, true), "the toggle does not toggle")
    assert(src:find("Deck.swap(entry.name, chosen.name, shelf)", 1, true), "Swap does not trade places on this shelf")
    assert(src:find("bw:onBookshelfShuffleOrnaments()", 1, true), "Shuffle all is not the shuffle action")
end)

t.test("menu: each nudge takes 10 points on a hold", function()
    -- The panel (maintainer: no more room than the grid): a tap is the small
    -- step, a hold the big one, on size and padding's - and + and on the
    -- d-pad's up and down (the height).
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    -- -10 / +10 cards outside - and +, and a hold on - or + (maintainer:
    -- room for the buttons, no hint for the hold).
    local nd = src:match("local function nudger%(field%)(.-)\n        end\n")
    assert(nd and nd:find("hold = big(-1), big = big(-1)", 1, true)
           and nd:find("hold = big(1), big = big(1)", 1, true),
        "the steppers have no 10-point step")
    assert(src:find('kbutton{ glyph = MINUS_GLYPH, glyph_size = FS - 4, text = "10"', 1, true)
           and src:find('kbutton{ glyph = PLUS_GLYPH, glyph_size = FS - 4, text = "10"', 1, true),
        "no -10 / +10 cards")
    -- One width: the symbols font's pair, not the text minus (maintainer).
    assert(src:find("local MINUS_GLYPH, PLUS_GLYPH = Kit.MINUS, Kit.PLUS", 1, true),
        "the minus and plus are not the kit's matched icons")
    assert(not src:find("Hold a button to step by 10", 1, true), "the hint is back")
    for _i, f in ipairs({ "scale", "pad", "lift" }) do
        assert(src:find('nudger("' .. f .. '")', 1, true), f .. " is not a stepper")
    end
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
    assert(menu:find("local head, head_keys = headerWidget(close)", 1, true), "no picture in the menu")
    local rd = menu:match("local redraw = M%.held%(function%(soon%)(.-)\n    end%)\n")
    assert(rd and rd:find("dialog:reinit()", 1, true), "the picture is not redrawn with the piece")
    local pw = menu:match("local function headerWidget%(close%)(.-)\n    end\n")
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
    -- The panel's refresh reaches the strip the picture rises into, or it
    -- would ghost on e-ink.
    assert(menu:find("rect = Geom:new{ x = math.floor((sw - sz.w) / 2), y = y - dialog.overhang,", 1, true)
           and menu:find("h = sz.h + dialog.overhang }", 1, true),
        "the panel does not reserve the strip the picture rises into")
    assert(menu:find("M%.OVERHANG%s*=%s*0%.25"), "the rise is not a quarter")
    local hdr = menu:match("local function headerWidget%(close%)(.-)\n    end\n")
    assert(hdr and hdr:find("HorizontalGroup", 1, true), "the picture is not beside the name")
    assert(hdr:find("Orn.shadowFor(", 1, true), "no drop shadow")
    local paint = hdr:match("function pic:paintTo%(bb, x, y%)(.-)\n        end")
    assert(paint and paint:find("shadow", 1, true) and paint:find("Orn.paintPlacement", 1, true)
           and paint:find("shadow", 1, true) < paint:find("Orn.paintPlacement", 1, true),
        "the shadow is not painted under the picture")
    assert(not menu:find("dialogClass", 1, true), "the plain ButtonDialog is still there")
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
    -- In the d-pad's middle, left and right either side.
    assert(src:find('T(_("%1 of %2"), i_on, n_on)', 1, true), "the place in the order is not shown")
    assert(src:find("Deck.move(entry.name, delta, onNames(), shelf)", 1, true)
           and src:find("{ glyph = CHEV_LEFT, enabled = can_move, tap = function() step(-1) end }", 1, true)
           and src:find("{ glyph = CHEV_RIGHT, enabled = can_move, tap = function() step(1) end }", 1, true)
           and src:find("local can_move = placed and i_on ~= nil and n_on > 1", 1, true),
        "left / right do not move the piece")
    local shuffle = src:match('barButton%(_%("Shuffle this shelf"%)(.-)end%)')
    assert(shuffle and shuffle:find("ConfirmBox", 1, true), "Shuffle this shelf does not ask first")
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

t.test("menu: two columns, the slot then the rest; mirror and anchor segmented; no hang switch", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local build = src:match("local function build%(close%)(.-)\n    end\n")
    assert(build, "no panel")
    local cols = build:match("local cols = {(.-)\n        }")
    assert(cols, "no columns")
    -- Left: Size, Height, Padding; right: Place, Mirror and Anchor together;
    -- Tap a row of its own under them, with a tip (maintainer).
    assert(build:find('local tip = not tap and _("Give this ornament a job!") or nil', 1, true)
           and build:find("local tap_row = line(tap_items, gap)", 1, true),
        "Tap is not a row of its own with a tip while no action is set")
    local order = { "Size", "Height", "Padding", "Place", "Mirror", "Anchor" }
    local last = 0
    for _i, l in ipairs(order) do
        local at = cols:find('_("' .. l .. '")', 1, true)
        assert(at and at > last, l .. " is out of order")
        last = at
    end
    assert(build:find('{ key = "alternate", label = _("Alternate") }', 1, true), "mirror is not segmented")
    assert(not src:find("local dpad", 1, true), "the d-pad is back")
    assert(not src:find('_("Hang: on")', 1, true) and not src:find('set("hang"', 1, true),
        "the hang switch is still in the menu (a height of 100% replaces it)")
end)

t.test("menu: Height steps down and up with chevrons", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(src:find('local l_dec, l_inc = nudger("lift")', 1, true)
           and src:find("l_dec.glyph, l_inc.glyph = CHEV_DOWN, CHEV_UP", 1, true),
        "height does not step down and up")
end)

t.test("menu: no collection button of its own; Swap carries the collection's icon", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local hdr = src:match("local function headerWidget%(close%)(.-)\n    end\n")
    assert(hdr and not hdr:find("COLLECTION_ICON", 1, true), "the header still has the collection button")
    assert(src:find('barButton(_("Swap"), Orn.COLLECTION_ICON', 1, true), "Swap has not got the icon")
end)

t.test("the collection: one icon on its menu row and in the long-press menu's header", function()
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local row = st:match("function Settings:_ornamentsRow%(%)(.-)\nend\n")
    assert(row, "no ornaments row")
    assert(row:find('_("Ornaments: %1 of %2 on")', 1, true), "the row is not the collection with its count")
    assert(row:find("#O.listAll()", 1, true), "the count has no total")
    assert(row:find("COLLECTION_ICON", 1, true), "the row has no icon")
    local orn = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    assert(orn:find('M.COLLECTION_ICON = "\\xEF\\x83\\xB4"', 1, true), "the icon is not U+F0F4, kept in one place")
    local menu = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    -- In the long-press menu it is Swap's icon (the pieces to swap in).
    assert(menu:find('barButton(_("Swap"), Orn.COLLECTION_ICON', 1, true), "the menu does not show the icon")
end)

-- With the top panel up the menus go at the top, over it, so the whole
-- shelf shows; on a full-screen shelf they keep clear of the piece. And they
-- can be dragged out of the way (maintainer), without a long-press making
-- them see-through.
t.test("menus: at the top with the top panel up, clear of the piece without; dragged", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(src:find("if bw and bw.hasTopPanel and bw:hasTopPanel() then\n            y = dialog.overhang", 1, true),
        "the ornament menu is not at the top with the top panel up")
    assert(src:find("M.offsetFor(piece, sh, sz.h + dialog.overhang)", 1, true), "full screen no longer keeps clear of the piece")
    assert(src:find('dialog.movable = MovableContainer:new{ ignore_events = { "hold", "hold_release", "hold_pan" } }', 1, true),
        "the ornament menu cannot be dragged")
    local pd = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
    assert(pd:find('self.movable = MovableContainer:new{ ignore_events = { "hold", "hold_release", "hold_pan" },', 1, true),
        "a page dialog cannot be dragged")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("function BookshelfWidget:hasTopPanel()\n    return not self._expanded\nend", 1, true), "no hasTopPanel")
    assert(w:find("if cw and bw:hasTopPanel() then", 1, true), "the module menu is not at the top with the top panel up")
    -- Off a page dialog KOReader's zones go first (the top menu,
    -- brightness), then a tap none took closes it.
    local he = pd:match("function PageDialog:handleEvent%(event%)(.-)\nend\n")
    assert(he and he:find("GZ.overlayEvent(self, event, InputContainer,", 1, true)
           and not he:find("_dismiss", 1, true), "a tap outside is taken before KOReader's zones")
    -- At the top it covers KOReader's menu band: a swipe from there still
    -- opens the menu (maintainer).
    assert(he:find("GZ.onWindow(event,", 1, true), "the menu swipe is lost over a dialog at the top")
    local gz = io.open("lib/bookshelf_gesture_zones.lua"):read("*a")
    assert(gz:find('G_defaults:readSetting("DTAP_ZONE_MENU")', 1, true), "the band is not KOReader's menu zone")
end)

-- Rapid taps on a nudge were slow: each drew the button pressed (and waited
-- for the panel), then rebuilt the whole shelf (maintainer, PW5). Nudges act
-- at once with no pressed look, and the shelf is rebuilt once the taps pause.
t.test("nudges: at once, no pressed look; the shelf rebuilt once the taps pause", function()
    local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    assert(src:find("glyph = o.glyph, instant = true,", 1, true), "the steppers still press first")
    local rd = src:match("local redraw = M%.held%(function%(soon%)(.-)\n    end%)\n")
    assert(rd and rd:find("UIManager:scheduleIn(M.SETTLE, rebuildShelf)", 1, true), "every nudge rebuilds the shelf")
    assert(src:find("set(field, v, true)", 1, true), "a nudge does not wait")
    -- At its limit a step does nothing (review 2026-10-31: a no-op set and a
    -- shelf rebuild per tap), and its button is greyed.
    assert(src:find("if v == Orn.readerValue(entry, field) then return end", 1, true), "a step at the limit still sets")
    assert(src:find("enabled = M.nudged(entry, field, small) ~= cur", 1, true), "the + is not greyed at the limit")
    assert(src:find("if Orn.readerGet(entry.name)[field] == nil then return box end", 1, true),
        "the value at its default can be tapped to reset")
    local cb = io.open("lib/bookshelf_chip_button.lua"):read("*a")
    assert(cb:find("if opts.instant then opts.on_tap()", 1, true), "the kit button cannot act at once")
end)

t.done()
