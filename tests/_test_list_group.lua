-- tests/_test_list_group.lua
-- How a folder or a stack presents in list mode: the hardcoded lines, and the
-- count that has to agree with the cover badge.
--
-- Usage (from plugin root): lua tests/_test_list_group.lua
--
-- The count is the part worth pinning. It reads the SAME two settings the cover
-- badge does, so the two surfaces can never disagree about whether there is a
-- number or what it counts -- and getting that wrong is invisible until someone
-- puts the two views side by side.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

-- Widget-shaped dependencies, stubbed: this suite is about the numbers and the
-- strings. The chevron itself is a CoverProgress.buildGlyphWidget call, which
-- needs a real framebuffer to say anything interesting about.
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = "black" }
package.loaded["ui/widget/container/centercontainer"] = {
    new = function(_self, t) return t end,
}
package.loaded["ui/geometry"] = { new = function(_self, t) return t end }
package.loaded["lib/bookshelf_cover_progress"] = {
    buildGlyphWidget = function(glyph, size) return { glyph = glyph, size = size } end,
}

local STORE = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(k, default)
        local v = STORE[k]
        if v == nil then return default end
        return v
    end,
    save   = function(k, v) STORE[k] = v end,
    isTrue = function(k) return STORE[k] == true end,
    flush  = function() end,
}

-- The repository, stubbed: a folder's count is a recursive walk, every other
-- group carries its members inline.
local FOLDER_PATHS, PROGRESS = {}, {}
local walks = 0
package.loaded["lib/bookshelf_book_repository"] = {
    getFolderBookPaths = function(path)
        walks = walks + 1
        return FOLDER_PATHS[path]
    end,
    readProgress = function(fp)
        local p = PROGRESS[fp]
        if not p then return nil, nil end
        return p.pct, p.status
    end,
}

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()
local eq      = helpers.eq

local Group = require("lib/bookshelf_list_group")

local function reset()
    for k in pairs(STORE) do STORE[k] = nil end
    for k in pairs(FOLDER_PATHS) do FOLDER_PATHS[k] = nil end
    for k in pairs(PROGRESS) do PROGRESS[k] = nil end
    walks = 0
end

local function folder(path, n)
    local paths = {}
    for i = 1, n do paths[i] = path .. "/b" .. i .. ".epub" end
    FOLDER_PATHS[path] = paths
    return { kind = "folder", path = path, label = "Sci-fi" }
end

local function stack(n)
    local books = {}
    for i = 1, n do books[i] = { filepath = "/s/b" .. i .. ".epub" } end
    return { kind = "author", name = "Le Guin", books = books }
end

-- A selection set with the same surface the real one exposes.
local function selectionOf(...)
    local set = {}
    for _i, fp in ipairs({ ... }) do set[fp] = true end
    return {
        isActive = function() return true end,
        contains = function(_self, fp) return set[fp] == true end,
    }
end

-- ── The count, against the badge settings ──────────────────────────────────

t.test("the default badge mode counts groups but not folders", function()
    reset()
    -- stack_count_badge_mode unset == "groups", which is what the cover badge
    -- resolves an absent value to (bookshelf_shelf_row.lua:318-322).
    eq(Group.countText(stack(4), nil), "4 books")
    assert(Group.countText(folder("/f", 9), nil) == nil,
        "a folder must carry no count under the default mode")
end)

t.test("each badge mode gates exactly the kinds it names", function()
    reset()
    local cases = {
        off     = { folder = false, group = false },
        folders = { folder = true,  group = false },
        groups  = { folder = false, group = true  },
        all     = { folder = true,  group = true  },
    }
    for mode, want in pairs(cases) do
        STORE["stack_count_badge_mode"] = mode
        assert((Group.countText(folder("/f", 3), nil) ~= nil) == want.folder,
            mode .. ": folder count wrong")
        assert((Group.countText(stack(3), nil) ~= nil) == want.group,
            mode .. ": group count wrong")
    end
end)

t.test("a count switched off costs no folder walk", function()
    reset()
    STORE["stack_count_badge_mode"] = "off"
    Group.countText(folder("/f", 200), nil)
    eq(walks, 0, "the recursive walk must not run for a count nobody asked for")
end)

t.test("one book is not '1 books'", function()
    reset()
    STORE["stack_count_badge_mode"] = "all"
    eq(Group.countText(folder("/f", 1), nil), "1 book")
end)

t.test("an empty group has nothing to say", function()
    reset()
    STORE["stack_count_badge_mode"] = "all"
    assert(Group.countText({ kind = "folder", path = "/nope" }, nil) == nil)
    assert(Group.countText({ kind = "author", books = {} }, nil) == nil)
end)

t.test("finished_total counts finished members, labelled", function()
    reset()
    STORE["stack_count_badge_mode"]   = "all"
    STORE["stack_count_badge_format"] = "finished_total"
    local f = folder("/f", 4)
    PROGRESS["/f/b1.epub"] = { status = "finished" }
    PROGRESS["/f/b3.epub"] = { status = "finished" }
    PROGRESS["/f/b2.epub"] = { status = "reading" }
    eq(Group.countText(f, nil), "2 of 4 finished")
end)

t.test("a live selection outranks both formats", function()
    reset()
    STORE["stack_count_badge_mode"]   = "all"
    STORE["stack_count_badge_format"] = "finished_total"
    local f = folder("/f", 4)
    PROGRESS["/f/b1.epub"] = { status = "finished" }
    eq(Group.countText(f, selectionOf("/f/b2.epub", "/f/b3.epub")),
       "2 of 4 selected")
    -- Nothing of THIS group selected, but a selection is live: falls back to
    -- the plain total, NOT to the finished format.
    --
    -- That looks like an oversight and is not. The badge gates finished on
    -- `sel_active_global` -- whether ANY selection is running, not whether this
    -- stack is part of it (bookshelf_shelf_row.lua:341-344) -- so while picking
    -- books every stack shows a total or a K/N and none of them show F/N. This
    -- reproduces that, quirk included, because a list row and a cover tile
    -- disagreeing about the same stack is worse than either rule alone.
    eq(Group.countText(f, selectionOf("/elsewhere.epub")), "4 books")
end)

-- ── The lines ──────────────────────────────────────────────────────────────

t.test("line 1 is the name, line 2 the count, the rest empty", function()
    reset()
    STORE["stack_count_badge_mode"] = "all"
    local out = Group.templates(folder("/f", 7), nil, 4)
    eq(#out, 4, "one entry per line the row will draw")
    eq(out[1], "%title")
    eq(out[2], "7 books")
    eq(out[3], "")
    eq(out[4], "")
end)

t.test("with one line configured the name wins and the count is dropped",
function()
    reset()
    STORE["stack_count_badge_mode"] = "all"
    local out = Group.templates(folder("/f", 7), nil, 1)
    eq(#out, 1)
    eq(out[1], "%title", "a row saying '7 books' without saying which folder"
        .. " would be useless")
end)

t.test("a suppressed count leaves line 2 empty, not stale", function()
    reset()
    STORE["stack_count_badge_mode"] = "off"
    local out = Group.templates(folder("/f", 7), nil, 2)
    eq(out[2], "",
        "the user's book template must not survive onto a group row")
end)

t.done()
