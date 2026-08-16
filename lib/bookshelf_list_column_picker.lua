-- bookshelf_list_column_picker.lua
-- Reorder / add / remove the list-view columns.
--
-- Built on lib/bookshelf_sort_priority_list.lua, the ordered-list widget
-- whose nudge-up/down, per-row delete and on_change callback are exactly the
-- interactions a column set needs.
--
-- Rebuild-the-whole-dialog, not patch-in-place, and the reason is the DIALOG,
-- not the list. Adding or removing a column changes the row count, which
-- changes the height of the frame, the CenterContainer and the ButtonDialog
-- around it -- all fixed at construction from the geometry below -- so the
-- surrounding chrome has to be rebuilt whatever the list does. Every mutation
-- here (reorder, delete, add) therefore closes the current dialog and opens a
-- fresh one. A flicker per tap is a fair price for a picker that is only ever
-- open a few seconds at a time.
--
-- List:_rebuild() used to be a second reason: it replaced its VerticalGroup's
-- children without calling resetLayout(), leaving that group's cached
-- _size/_offsets stale. That is fixed in the widget itself now rather than
-- worked around here, so a future caller that only needs to reorder rows can
-- keep its dialog open.
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local TextWidget      = require("ui/widget/textwidget")
local Button          = require("ui/widget/button")
local Geom            = require("ui/geometry")
local Size            = require("ui/size")
local Blitbuffer      = require("ffi/blitbuffer")
local Screen          = require("device").screen
local BFont           = require("lib/bookshelf_fonts")
local List            = require("lib/bookshelf_sort_priority_list")
local Columns         = require("lib/bookshelf_list_columns")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local _               = require("lib/bookshelf_i18n").gettext

local Picker = {}

-- The MINIMUM the data-model change forces on this file, and no more: it edits
-- the first text row's key instead of the old single key. There is no row-2
-- editor and no cover toggle here -- both are the next pass's, which rebuilds
-- this dialog around the three-key shape documented at the top of
-- lib/bookshelf_list_columns.lua. Until then the cover boolean is reachable
-- from its own checkbox in Settings > List view.
local ROW1_KEY = "list_columns_row1"

local function saveIds(items)
    local ids = {}
    for _i, it in ipairs(items) do ids[#ids + 1] = it.id end
    BookshelfSettings.save(ROW1_KEY, ids)
    BookshelfSettings.flush()
end

-- Columns not currently in the active set, in catalogue order (the same
-- "likely usefulness" ordering the catalogue itself documents).
local function unusedColumns(items)
    local used = {}
    for _i, it in ipairs(items) do used[it.id] = true end
    local out = {}
    for _i, c in ipairs(Columns.CATALOGUE) do
        if not used[c.id] then out[#out + 1] = c end
    end
    return out
end

-- _render(width, opts, rebuild) -> the dialog widget it built and showed.
-- Returns its own dialog so Picker.show can close exactly the right one
-- before the next render, rather than guessing at a variable that may not
-- have been assigned yet.
function Picker._render(width, opts, rebuild)
    local active = Columns.layout().row1
    local items = {}
    for _i, c in ipairs(active) do
        -- can_delete gates the per-row delete glyph in the list widget. The
        -- last column is undeletable: an empty set would render blank rows
        -- with no way back through the UI (Columns.active() would then fall
        -- back to the defaults on the very next read, but the screen in
        -- front of the user in the meantime would be empty and inexplicable).
        items[#items + 1] = {
            id = c.id, label = c.label, can_delete = (#active > 1),
        }
    end

    -- Inner content width: the frame's border + padding on both sides, so
    -- the list, the title and the two buttons all agree with what the
    -- FrameContainer will actually render at.
    local border    = Size.border.window
    local pad       = Size.padding.large
    local content_w = width - 2 * (border + pad)

    local list = List:new{
        items       = items,
        width       = content_w,
        show_delete = true,
        on_change   = function(new_items)
            saveIds(new_items)
            rebuild()
        end,
    }

    local face, bold = BFont:getFace("infofont", 16, { bold = true })
    local content = VerticalGroup:new{ align = "left" }
    content[#content + 1] = TextWidget:new{
        text = _("Columns, in order"),
        face = face, bold = bold, max_width = content_w,
    }
    content[#content + 1] = list:getWidget()

    -- `dialog` is declared before the buttons that close it: their
    -- callbacks only run once the user taps them, by which point this
    -- function has finished and `dialog` has been assigned below, so the
    -- upvalue is never read while still nil.
    local dialog
    local add_btn = Button:new{
        text  = _("Add column"),
        width = content_w,
        callback = function()
            -- `add_dialog` is local to THIS tap: each press of "Add column"
            -- gets its own closure, so there is nothing shared to clobber
            -- across repeated opens.
            local add_dialog
            local unused = unusedColumns(list:getItems())
            local rows = {}
            if #unused == 0 then
                rows[#rows + 1] = { {
                    text = _("All columns are already showing"),
                    callback = function() end,
                } }
            else
                for _i, c in ipairs(unused) do
                    rows[#rows + 1] = { {
                        text = c.label,
                        callback = function()
                            local ids = {}
                            for _j, it in ipairs(list:getItems()) do
                                ids[#ids + 1] = it.id
                            end
                            ids[#ids + 1] = c.id
                            BookshelfSettings.save(ROW1_KEY, ids)
                            BookshelfSettings.flush()
                            UIManager:close(add_dialog)
                            rebuild()
                        end,
                    } }
                end
            end
            rows[#rows + 1] = { {
                text = _("Close"),
                callback = function() UIManager:close(add_dialog) end,
            } }
            add_dialog = ButtonDialog:new{ title = _("Add column"), buttons = rows }
            UIManager:show(add_dialog)
        end,
    }
    local close_btn = Button:new{
        text  = _("Close"),
        width = content_w,
        callback = function()
            UIManager:close(dialog)
            if opts.on_close then opts.on_close() end
        end,
    }
    content[#content + 1] = add_btn
    content[#content + 1] = close_btn

    dialog = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = border,
            padding    = pad,
            content,
        },
    }
    UIManager:show(dialog)
    return dialog
end

-- Picker.show(opts) -- opts = { on_close }. on_close fires once, when the
-- user taps Close on the main list (not on every intermediate rebuild).
function Picker.show(opts)
    opts = opts or {}
    local width = math.floor(Screen:getWidth() * 0.9)
    local current  -- the dialog currently on screen, so rebuild() closes
                    -- the right one instead of leaving a stack behind it.

    local function rebuild()
        if current then UIManager:close(current) end
        current = Picker._render(width, opts, rebuild)
    end

    rebuild()
end

return Picker
