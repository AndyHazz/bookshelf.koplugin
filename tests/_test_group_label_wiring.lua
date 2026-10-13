-- tests/_test_group_label_wiring.lua
-- Cover display > Show text below groups (issue 486): the wiring.
--
-- WHAT NEEDS PINNING. With "Show text below covers: Author", a standalone book
-- on a Series shelf showed its author and the series stack beside it showed
-- nothing: the stack's one line was reserved for its NAME, which a Divider
-- card, a Ribbon or a Text tile already shows. Groups now have their own
-- choice, apart from the books' (None by default, Author, Custom), so a reader
-- can have titles under books and the author under series stacks.
--
-- The rules are unit-tested elsewhere: StackDisplay.groupLabel and the strip
-- budget in _test_stack_display, the stored line, the groups' resolver and
-- editor in _test_cover_label, the stack's author in _test_book_repository,
-- _shelfLabelMode and the note in _test_grid_labels. This file pins the
-- WIRING in ShelfRow, the widget and the settings menu, which need a whole
-- widget tree to build, so it is matched at source level.
--
-- Usage (from plugin root): lua tests/_test_group_label_wiring.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()

local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end
-- Comments stripped, so a commented-out call cannot satisfy a match.
local function code(p)
    local out = {}
    for line in read(p):gmatch("[^\n]*") do
        out[#out + 1] = (line:gsub("%s*%-%-.*$", ""))
    end
    return table.concat(out, "\n")
end
local row      = code("lib/bookshelf_shelf_row.lua")
local widget   = code("lib/bookshelf_widget.lua")
local settings = code("lib/bookshelf_settings.lua")

-- Each tile branch, from its elseif to the next one.
local function branch(head)
    local s = row:find(head, 1, true)
    assert(s, "branch moved: " .. head)
    local e = row:find("\n        elseif item", s + #head, true)
    assert(e, "branch end not found: " .. head)
    return row:sub(s, e)
end

t.test("every group tile asks groupLabel for its line", function()
    local heads = {
        { 'elseif item and item.kind == "folder" then', "_groupLabel(item, item.label)" },
        { 'elseif item and item.kind == "author" then', "_groupLabel(item, item.series_name)" },
        { 'elseif item and item.kind == "genre" then', "_groupLabel(item, item.series_name)" },
        { 'elseif item and item.kind == "tag" then', "_groupLabel(item, item.series_name)" },
        { 'elseif item and item.kind == "language" then', "_groupLabel(item, item.series_name)" },
        { "elseif item and item.books then", "_groupLabel(item, item.series_name)" },
    }
    for _i, h in ipairs(heads) do
        local b = branch(h[1])
        assert(b:find(h[2], 1, true), h[1] .. " does not offer the groups' text")
        assert(not b:find("StackDisplay.externalLabel(", 1, true), h[1] .. " still prints only its name")
    end
    -- A catalogue link is a Text tile and IS its name: nothing below it.
    local nav = branch('elseif item and item.kind == "opds_nav" then')
    assert(nav:find("StackDisplay.externalLabel(nav_mode, item.label)", 1, true), "the nav tile's label changed")
end)

t.test("_groupLabel hands groupLabel the groups' choice and the author format", function()
    local decl = row:find("local function _groupLabel(", 1, true)
    local loop = row:find("for i = 1, n_slots do", 1, true)
    -- A local declared below its caller reads nil at paint time.
    assert(decl and loop and decl < loop, "_groupLabel must be declared before the slot loop")
    local helper = row:match("local function _groupLabel%(item, name%)(.-)\n    end\n")
    assert(helper and helper:find("StackDisplay.groupLabel(group_mode, item, name, group_text,", 1, true)
        and helper:find("_authorLabel)", 1, true), "_groupLabel's arguments changed")
    local a = row:find("local function _authorLabel(", 1, true)
    assert(a and a < decl, "_authorLabel must be declared before _groupLabel")
    local labelFor = row:match("local function _labelFor%(item%)(.-)\n    end\n")
    assert(labelFor and labelFor:find("return _authorLabel(a)", 1, true),
        "the book label no longer shares the author formatting")
end)

t.test("the groups' choice comes from the caller, else the setting, and only Author counts", function()
    assert(row:find("local group_text = opts.group_label_mode", 1, true))
    assert(row:find('require("lib/bookshelf_cover_label").groupMode()', 1, true),
        "a caller passing no choice does not get the saved one")
    assert(row:find('if group_text ~= "author" then group_text = nil end', 1, true))
    assert(not row:find("groupResolver", 1, true), "the groups' Custom line is still resolved")
end)

t.test("the strip is there for the groups' text, and still gated on the reader's choices", function()
    assert(row:find("local draw_group_label = show_titles and group_text ~= nil", 1, true))
    assert(row:find("if draw_label or draw_group_label then", 1, true),
        "the strip is not reserved when only the groups print")
    local w = row:match("local function wrap_for_title_alignment%(widget, group_name, is_group_text%)(.-)\n        end\n")
    assert(w, "wrap_for_title_alignment moved")
    assert(w:find("if (draw_label or draw_group_label)", 1, true), "group labels are not gated on the choices")
    assert(w:find("face      = is_group_text and group_face or title_face", 1, true),
        "the groups' text is not set in its own face")
    -- A book's label is still the books' choice alone.
    assert(row:find('local title_text = (draw_label and not spine.is_fallback)', 1, true))
end)

t.test("the widget hands the rows the groups' choice", function()
    assert(widget:find("group_label_mode  = self:_groupLabelMode() or false,", 1, true))
    assert(not widget:find("_previewGroupLabel", 1, true), "the groups' editor preview is still there")
end)

t.test("the menu has one switch under the books' row: Show author below series", function()
    local body = settings:match("function Settings:_coverDisplaySubItems%(%)(.-)\nfunction Settings:")
    assert(body, "Settings:_coverDisplaySubItems is gone")
    local books  = body:find('_("Cover captions") .. ": "', 1, true)
    local groups = body:find('_("Show author below series")', 1, true)
    assert(books and groups and books < groups, "the switch is not under the books' row")
    assert(not body:find('_("Show text below groups")', 1, true), "the old None / Author / Custom row is back")
    local sub = body:sub(groups, groups + 900)
    assert(sub:find('CL.saveGroupMode(CL.groupMode() ~= "author")', 1, true), "the switch does not toggle")
end)

t.done()
