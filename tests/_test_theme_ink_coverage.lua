-- tests/_test_theme_ink_coverage.lua
-- Every piece of shelf chrome has to say what colour its ink is.
--
-- WHAT NEEDS PINNING, and why it is a whole test file rather than a fix.
--
-- KOReader's TextWidget defaults to BLACK and FrameContainer's border defaults
-- to BLACK. In device night mode that is correct and invisible: the frame
-- inversion turns black into white for free, which is why none of this was
-- ever needed. Under the shelf's OWN dark theme on a light device nothing
-- inverts, so every widget that stayed silent about its colour paints black
-- on a black panel and disappears.
--
-- That has now been found by hand four separate times -- the footer icons,
-- the footer page label, the chip strip's outline, and the hero's title,
-- stars, review count and description. Each time it was one omission among
-- neighbours that did it correctly, which is exactly the kind of thing a
-- reviewer's eye slides over. So this walks the constructors instead.
--
-- Usage (from plugin root): lua tests/_test_theme_ink_coverage.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- The chrome that paints on the themed panel. NOT a list of every file with
-- text in it: a book's own cover art, a modal over the page and the settings
-- menus all sit on their own opaque ground and are right to stay silent.
local CHROME = {
    "lib/bookshelf_hero_card.lua",
    "lib/bookshelf_chip_bar.lua",
    -- The module cards. Their hairline was the case that proved the border
    -- half of this audit earns its keep: FrameContainer defaults to black, so
    -- on the light card and in device night mode (which inverts the frame) it
    -- looked right, and only the shelf's own dark theme -- where nothing
    -- inverts -- lost every card edge.
    "lib/bookshelf_hero_modules.lua",
}

local function read(path)
    local f = io.open(path)
    assert(f, "could not read " .. path)
    local s = f:read("a"); f:close()
    return s
end

-- Walk from the "{" of a constructor to its matching "}", counting depth so a
-- nested widget or table does not end the block early. Comments are stripped
-- first, so a brace inside one cannot unbalance the count.
local function constructorBlocks(src, pattern)
    local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
    local out = {}
    local pos = 1
    while true do
        local s, e = code:find(pattern, pos)
        if not s then break end
        local depth, i = 0, e
        repeat
            local ch = code:sub(i, i)
            if ch == "{" then depth = depth + 1
            elseif ch == "}" then depth = depth - 1 end
            i = i + 1
        until depth == 0 or i > #code
        local _, line = code:sub(1, s):gsub("\n", "")
        -- A widget built only to be MEASURED never paints, so its colour is
        -- nobody's business: `local tw = TextWidget:new{...}` followed by
        -- tw:getSize() and tw:free(). Match the name and look for the free.
        local var  = code:sub(math.max(1, s - 40), s - 1):match("local%s+([%w_]+)%s*=%s*$")
        local tail = code:sub(i, i + 400)
        local measured = var and tail:find(var .. ":free%(%)") ~= nil
        if not measured then
            out[#out + 1] = { body = code:sub(s, i - 1), line = line + 1 }
        end
        pos = i
    end
    return out
end

t.test("every text widget in the themed chrome sets an ink colour", function()
    local missing = {}
    for _i, path in ipairs(CHROME) do
        local src = read(path)
        for _j, b in ipairs(constructorBlocks(src, "Text[%a]*Widget:new%s*{")) do
            if not b.body:find("fgcolor") then
                missing[#missing + 1] = path .. ":" .. b.line
            end
        end
    end
    assert(#missing == 0,
        "text that will paint black on a dark panel:\n  "
        .. table.concat(missing, "\n  "))
end)

t.test("every bordered frame in the themed chrome sets a border colour", function()
    -- FrameContainer's border is COLOR_BLACK unless told otherwise, so an
    -- outline on a dark panel is an outline nobody can see. bordersize 0 is
    -- fine: there is no border to colour.
    local missing = {}
    for _i, path in ipairs(CHROME) do
        local src = read(path)
        for _j, b in ipairs(constructorBlocks(src, "FrameContainer:new%s*{")) do
            local size = b.body:match("bordersize%s*=%s*([^,\n]+)")
            local zero = size and size:match("^%s*0%s*$")
            -- %f[%w]: the attribute is `color`, and "bordercolor" contains
            -- "color =" as a substring. This test passed on a frame whose
            -- border colour FrameContainer never reads -- an unknown key on a
            -- widget table is silently ignored, so the border stayed black and
            -- the audit said it was fine. Match the whole word or nothing.
            if size and not zero and not b.body:find("%f[%w]color%s*=") then
                missing[#missing + 1] = path .. ":" .. b.line
            end
        end
    end
    assert(#missing == 0,
        "borders that will paint black on a dark panel:\n  "
        .. table.concat(missing, "\n  "))
end)

t.test("the walker actually finds the constructors it is auditing", function()
    -- A pattern that silently matches nothing would make both tests above
    -- pass forever. Pin that it sees a realistic number of each.
    local n_text, n_frame = 0, 0
    for _i, path in ipairs(CHROME) do
        local src = read(path)
        n_text  = n_text  + #constructorBlocks(src, "Text[%a]*Widget:new%s*{")
        n_frame = n_frame + #constructorBlocks(src, "FrameContainer:new%s*{")
    end
    assert(n_text >= 8, "the text walker found only " .. n_text)
    assert(n_frame >= 3, "the frame walker found only " .. n_frame)
end)

t.test("the chrome files have an ink helper to reach for", function()
    -- The omissions all happened in files that already had one.
    for _i, path in ipairs(CHROME) do
        local src = read(path)
        assert(src:find("CP%.ink") or src:find("_chipInk") or src:find("_ink"),
            path .. " has no themed ink helper")
    end
end)

t.test("the page itself follows the theme when nothing is set", function()
    -- Ink and ground are one decision. Threading a white ink through the
    -- chrome and leaving the page white gives white on white, which is what
    -- turning the wallpaper OFF under a dark shelf produced on device.
    local src = read("lib/bookshelf_widget.lua")
    local fn = src:match("function BookshelfWidget:_pageGroundColor%(%).-\nend")
    assert(fn, "_pageGroundColor could not be located")
    assert(fn:find("_manualDark"),
        "the page ground no longer asks whether the shelf is dark")
    assert(fn:find("COLOR_WHITE"),
        "the day default has gone; the page should still be paper by default")
    -- ...and it must not borrow the PANEL's colour. It did, and that made the
    -- Panel background setting repaint the whole screen.
    -- Comments in there name panel_bg to explain why it is NOT used, so look
    -- at the code only.
    local body = fn:gsub("%-%-[^\n]*", "")
    assert(body:find("page_bg") and not body:find("panel_bg"),
        "the page ground is borrowing panel_bg again")
end)

t.test("no local helper is declared after the one that closes over it", function()
    -- Lua binds the upvalue that exists when a body is COMPILED, so a helper
    -- declared below its caller reads nil at call time and the shelf dies on
    -- its first paint. That has now happened three times in one day
    -- (PLANK_BANDS, then _stripInk), always as a clean-looking "put the new
    -- helper near the top" edit.
    local FILES = { "lib/bookshelf_chip_bar.lua", "lib/bookshelf_spine_shelf.lua",
                    "lib/bookshelf_hero_card.lua" }
    local bad = {}
    for _i, path in ipairs(FILES) do
        local code = read(path):gsub("%-%-[^\n]*", "")
        -- Where each file-local helper is DECLARED.
        local at = {}
        for pos, name in code:gmatch("()local function ([%w_]+)") do
            if not at[name] then at[name] = pos end
        end
        -- ...and where each one is first CALLED from inside another local
        -- function body. A call before the declaration is the bug.
        -- Skip anything reached through a table: Wallpaper.shade is not the
        -- local `shade`, and matching it as one is a false positive that
        -- costs more attention than the bug it is guarding against.
        for pos, lead, name in code:gmatch("()([%s,({=]?)([%w_]+)%(") do
            if lead == "" then goto continue end
            local decl = at[name]
            if decl and pos < decl then
                -- Only a problem if the call site is itself inside a function
                -- that runs later; a forward reference at file scope would
                -- not even parse. Report it and let a human look.
                bad[#bad + 1] = path .. ": " .. name .. " called before it is declared"
                at[name] = nil   -- one report per helper
            end
            ::continue::
        end
    end
    assert(#bad == 0, table.concat(bad, "\n  "))
end)

t.test("the spine selection repaint finds slots by name, not by position", function()
    -- It read row[2], assuming OverlapGroup{ plank, HorizontalGroup{slots} }.
    -- The shelf recess is inserted at index 2 whenever there is a ground
    -- behind the shelf, so row[2] became the recess, the walk found no slots
    -- and tapping a book stopped lifting it -- with a wallpaper only, which
    -- is exactly how it presented.
    local w = read("lib/bookshelf_widget.lua")
    local fn = w:match("function BookshelfWidget:_repaintSpineSelection.-\nend")
    assert(fn, "_repaintSpineSelection could not be located")
    assert(fn:find("_slots_by_fp"),
        "the repaint is back to walking the row by index")
    -- ...and the row has to actually carry the registry.
    local sh = read("lib/bookshelf_spine_shelf.lua")
    assert(sh:find("row_group%._slots_by_fp = slots_by_fp"),
        "rowWidget no longer registers its slots")
    assert(sh:find("slots_by_fp%[e%.book%.filepath%] = tile"),
        "slots are registered but never filled in")
end)

t.test("nothing indexes a shelf row by a fixed child position", function()
    -- The recess taught us that row children are not a stable layout. Any
    -- new reader of row[N] is the same bug waiting.
    -- Positional access is allowed as a FALLBACK -- a row built before the
    -- registry existed still has to work -- but never as the primary route.
    -- So every row[N] must sit within the same block as a _slots_by_fp lookup
    -- (900 chars of comment-stripped code, which is roughly one function body).
    -- Checked per LINE rather than by proximity: the expression itself has
    -- to say it is the fallback. A character-window test kept needing widening
    -- every time the function above it grew, which is a test measuring the
    -- wrong thing.
    local bad = {}
    local n = 0
    for line in read("lib/bookshelf_widget.lua"):gmatch("[^\n]*") do
        n = n + 1
        local code = line:gsub("%-%-.*$", "")
        if code:find("row%s*%[%s*%d+%s*%]")
                and not (code:find("slots") or code:find("direct")) then
            bad[#bad + 1] = "line " .. n .. ": " .. line:gsub("^%s+", "")
        end
    end
    assert(#bad == 0, "row[N] read without a registry guard:\n  "
        .. table.concat(bad, "\n  "))
end)

t.done()
