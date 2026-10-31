-- tests/_test_genre_sets_filter.lua
-- Filters > Genre is a page of three lists, as Filters > Folders is: genres a
-- book needs any of, all of, and none of (GitHub issues 293: Romance AND
-- Fantasy; 453: everything but FanFiction). Filters > Collection has any of
-- and none of. Each list adds through the filter's own picker, ticking that
-- list.
--
-- Usage (from plugin root): lua tests/_test_genre_sets_filter.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
for _, m in ipairs({ "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/uimanager",
        "ui/geometry", "ui/size", "lib/bookshelf_tab_model" }) do
    package.loaded[m] = {}
end
package.loaded["device"] = { screen = {} }
package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)]) end))
end }

local Editor = dofile("lib/bookshelf_chip_editor.lua")
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local spec
Editor._menu = function(s) spec = s; return { refresh = function() end } end
local picked
Editor._pickMultiFilter = function(_self, draft, dim_key, on_close, opts)
    picked = { draft = draft, dim = dim_key, opts = opts or {}, on_close = on_close }
end

local function page(dim, filter)
    local draft = { filter = filter or {} }
    Editor:_pickSetsFilter(draft, dim, function() end)
    return spec.page(), draft
end
local function headings(model)
    local out = {}
    for _i, b in ipairs(model.blocks) do
        if b.type == "heading" then out[#out + 1] = b.text .. (b.tag and " [" .. b.tag .. "]" or "") end
    end
    return table.concat(out, " | ")
end
-- The add chip under a heading.
local function addUnder(model, heading)
    local seen = false
    for _i, b in ipairs(model.blocks) do
        if b.type == "heading" then seen = b.text == heading end
        if seen and b.type == "chips" then return b.items[1] end
    end
end

t.test("Genre: any, all and leave out", function()
    eq(headings(page("genres")), "Any of these genres [OR] | All of these genres [AND] | Leave out these genres [NOT]")
end)

t.test("Collection: any and leave out", function()
    eq(headings(page("collections")), "In any of these collections [OR] | Leave out these collections [NOT]")
end)

-- As the book menu's tags in edit mode: small pills in a line, each with a
-- cross inside that drops it; "+ Add" stays a card (maintainer).
t.test("each list shows its picks as pills, each with a cross that drops it", function()
    local model, draft = page("genres", { genres_not = { FanFiction = true } })
    local pill
    for _i, b in ipairs(model.blocks) do
        if b.type == "pills" then pill = b.items[1] end
        assert(b.type ~= "row", "a pick is still a full-width row")
    end
    eq(pill.label, "FanFiction")
    eq(pill.trailing, "\xE2\x9C\x95")
    pill.on_tap()
    eq(next(draft.filter.genres_not), nil)
end)

t.test("a list's add opens the genre picker on that list", function()
    local model, draft = page("genres")
    addUnder(model, "All of these genres").callback()
    eq(picked.dim, "genres")
    eq(picked.opts.set_key, "genres_all")
    eq(picked.draft, draft)
    addUnder(model, "Leave out these genres").callback()
    eq(picked.opts.set_key, "genres_not")
end)

-- The logic named as anyone who knows it reads it, as a tag beside the
-- heading, not at the end of its sentence (maintainer).
t.test("each list's logic is a tag on its heading", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(src:find('{ key = "genres_all",  heading = _("All of these genres"), tag = _("AND") }', 1, true))
    assert(src:find('{ type = "heading", text = sec.heading, tag = sec.tag }', 1, true))
    local ep = io.open("lib/bookshelf_editor_page.lua"):read("*a")
    local h = assert(ep:match("\nfunction R.heading%(ctx, b%)\n(.-)\nend\n"))
    assert(h:find("b.tag", 1, true), "a heading's tag is not drawn")
end)

t.test("Filters opens Genre and Collection as these pages", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local i = src:find("function Editor:_openFilters", 1, true)
    local body = src:sub(i, src:find("\nend\n", i, true))
    assert(body:find("_pickSetsFilter", 1, true), "Genre still opens the plain picker")
    -- The row's cross clears every list of the filter, not just any-of.
    assert(body:find("Filter.dimKeys(key)", 1, true), "the cross leaves all-of and not behind")
end)

t.test("the picker ticks the list it was opened for", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local i = src:find("function Editor:_pickMultiFilter", 1, true)
    local body = src:sub(i, src:find("\nend\n", i, true))
    assert(body:find("local set_key = opts and opts.set_key or dim_key", 1, true), "no set_key")
    assert(body:find("draft.filter[set_key]", 1, true), "the picker still writes the any-of list")
end)

t.done()
