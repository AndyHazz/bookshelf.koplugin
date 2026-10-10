-- tests/_test_shelf_cover_text.lua
-- Shelf style's own text below covers and below groups (Reddit, after 5.4:
-- "author under folders, but only on my series shelf"): the row of two, the
-- picker each opens, and the Custom line written to the shelf, not the
-- settings. The real chip editor is loaded with KOReader's widgets stubbed,
-- and the dialogs it would show are recorded and tapped.
--
-- Usage (from plugin root): lua tests/_test_shelf_cover_text.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local shown, closed, ticks = {}, {}, {}
local UIManager = {
    show = function(_s, w) shown[#shown + 1] = w end,
    close = function(_s, w) closed[#closed + 1] = w end,
    nextTick = function(_s, fn) ticks[#ticks + 1] = fn end,
    scheduleIn = function() end, unschedule = function() end,
    setDirty = function() end,
}
local function newable() return { new = function(_s, o) return o end } end
local TABS = {
    { id = "series", label = "Series" },
    { id = "sub", label = "Sub", parent = "series" },
}
local stubs = {
    ["ui/uimanager"] = UIManager,
    ["ui/widget/buttondialog"] = newable(),
    ["ui/widget/confirmbox"] = newable(),
    ["ui/geometry"] = newable(),
    ["ui/size"] = { padding = { default = 4 }, border = { window = 1 }, margin = {} },
    ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
                              scaleBySize = function(_s, n) return n end } },
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end },
    ["lib/bookshelf_i18n"] = { gettext = function(s) return s end },
    ["ffi/util"] = { template = function(f, ...)
        local a = { ... }
        return (f:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
    end },
    ["lib/bookshelf_tab_model"] = {
        getById = function(id) for _i, tb in ipairs(TABS) do if tb.id == id then return tb end end end,
    },
    ["lib/bookshelf_settings_store"] = { read = function() return nil end, save = function() end,
                                         flush = function() end },
}
for k, v in pairs(stubs) do package.loaded[k] = v end
-- Anything else the module pulls in at load time: an empty table will do.
local real_require = require
require = function(m)  -- luacheck: ignore
    if package.loaded[m] then return package.loaded[m] end
    local ok, mod = pcall(real_require, m)
    if ok then return mod end
    package.loaded[m] = setmetatable({}, { __index = function() return function() end end })
    return package.loaded[m]
end
local Editor = require("lib/bookshelf_chip_editor")
local LE_SPEC
package.loaded["lib/bookshelf_cover_label_editor"] = {
    showForShelf = function(_bw, spec) LE_SPEC = spec end,
}

local function texts(rows)
    local o = {}
    for _i, row in ipairs(rows) do
        for _j, b in ipairs(row) do o[#o + 1] = (b.text_func and b.text_func() or b.text):gsub("^[^%w]+", "") end
    end
    return table.concat(o, " | ")
end
local function find(rows, label)
    for _i, row in ipairs(rows) do
        for _j, b in ipairs(row) do
            local tx = b.text_func and b.text_func() or b.text
            if tx:find(label, 1, true) then return b end
        end
    end
end

t.test("the row names each choice: Default, or Same as for a sub-shelf", function()
    local draft = { id = "series", label = "Series" }
    local row = Editor:_coverTextRow(draft, function() end, function() end, function() end)
    eq(texts({ row }), "Book text: Default | Group text: Default")
    draft.group_text = "author"; draft.cover_text = "none"
    eq(texts({ row }), "Book text: None | Group text: Author")
    local sub = { id = "sub", label = "Sub", parent = "series" }
    eq(texts({ Editor:_coverTextRow(sub, function() end, function() end, function() end) }),
       "Book text: Same as Series | Group text: Same as Series")
end)

t.test("a pick is written to the shelf, shown, and hands back to Shelf style", function()
    local draft = { id = "series", label = "Series" }
    local changes, backs = 0, 0
    shown = {}
    local row = Editor:_coverTextRow(draft, function() changes = changes + 1 end,
        function() end, function() backs = backs + 1 end)
    row[2].callback()                      -- Group text
    local d = shown[#shown]
    eq(d.title, "Show text below groups")
    eq(texts(d.buttons), "Default | None | Author | Custom… | Back")
    -- A grid, not a column: two pairs and Back (PW5, 2026-10-10).
    eq(#d.buttons, 3, "the groups' picker is not two rows and Back")
    find(d.buttons, "Author").callback()
    eq(draft.group_text, "author"); eq(changes, 1); eq(backs, 1)
    -- Default clears it: the shelf follows again.
    row[2].callback()
    find(shown[#shown].buttons, "Default").callback()
    eq(draft.group_text, nil, "Default did not clear the shelf's own choice")
    row[1].callback()                      -- Book text
    eq(texts(shown[#shown].buttons), "Default | None | Title | Author | Series | Custom… | Back")
    local shape = {}
    for i, r in ipairs(shown[#shown].buttons) do shape[i] = #r end
    eq(table.concat(shape, ","), "2,3,1,1", "the books' picker is not laid out as a grid")
    find(shown[#shown].buttons, "Back").callback()
    eq(draft.cover_text, nil, "Back changed the choice")
end)

t.test("Custom… edits the shelf's own line; Save makes Custom its choice", function()
    local draft = { id = "series", label = "Series", group_text_line = { template = "%series" } }
    local changes, backs = 0, 0
    local row = Editor:_coverTextRow(draft, function() changes = changes + 1 end,
        function() end, function() backs = backs + 1 end)
    row[2].callback()
    LE_SPEC = nil
    find(shown[#shown].buttons, "Custom").callback()
    assert(LE_SPEC, "Custom… did not open the line editor")
    eq(LE_SPEC.groups, true)
    eq(LE_SPEC.line.template, "%series", "the editor does not start from the shelf's line")
    eq(draft.group_text, nil, "opening the editor chose Custom before Save")
    LE_SPEC.save({ template = "%author", bold = true })
    eq(draft.group_text, "custom")
    eq(draft.group_text_line.template, "%author"); eq(draft.group_text_line.bold, true)
    eq(changes, 1)
    LE_SPEC.on_closed()
    eq(backs, 1, "Shelf style did not come back after the editor")
end)

t.done()
