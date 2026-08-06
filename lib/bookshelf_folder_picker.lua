-- lib/bookshelf_folder_picker.lua
-- Destination-folder picker for the move flows. Flat searchable list
-- of every folder under home_dir (LibraryModal grid, same pattern as
-- the chip editor's pickById; ButtonDialog fallback when bookends'
-- modal is unavailable), plus "New folder" and "Browse device" escape
-- hatches in the footer.

local _ = require("lib/bookshelf_i18n").gettext

local Picker = {}

-- Pure: assemble + filter the choice list. `choices` are Repo-style
-- { value, label, subtitle }. `exclude` is a list of dirs to drop,
-- each with its descendants (a folder can't move into itself). Home
-- is prepended as an explicit first choice.
function Picker.buildChoices(choices, home, exclude)
    local FileOps = require("lib/bookshelf_file_ops")
    local home_norm = FileOps.normDir(home or "/")
    local ex = {}
    for _i, p in ipairs(exclude or {}) do ex[#ex + 1] = FileOps.normDir(p) end
    local function excluded(path)
        for _i, e in ipairs(ex) do
            if FileOps.prefixSwap(path, e, e) then return true end
        end
        return false
    end
    local out = {}
    if not excluded(home_norm) then
        out[#out + 1] = { value = home_norm, label = _("Home folder"), subtitle = home_norm }
    end
    for _i, c in ipairs(choices or {}) do
        local v = FileOps.normDir(c.value)
        if not excluded(v) then
            out[#out + 1] = { value = v, label = c.label, subtitle = c.subtitle }
        end
    end
    return out
end

-- Picker.show{ title, exclude, on_pick(dir), on_cancel() }
function Picker.show(opts)
    local UIManager = require("ui/uimanager")
    local FileOps = require("lib/bookshelf_file_ops")
    local Repo = require("lib/bookshelf_book_repository")
    local home = G_reader_settings:readSetting("home_dir") or "/"
    local choices = Picker.buildChoices(Repo.getAllFolderChoices(), home, opts.exclude)

    local function cancel() if opts.on_cancel then opts.on_cancel() end end
    local function pick(dir) opts.on_pick(FileOps.normDir(dir)) end

    -- "New folder": created under home_dir, then auto-picked as the
    -- destination. Deeper creation is available inside Browse device
    -- (PathChooser's own plus-menu has New folder).
    local function new_folder()
        local InputDialog = require("ui/widget/inputdialog")
        local input
        input = InputDialog:new{
            title = _("New folder in home folder"),
            input = "",
            buttons = {{
                { text = _("Cancel"), id = "close", callback = function()
                    UIManager:close(input)
                    cancel()
                end },
                { text = _("Create"), is_enter_default = true, callback = function()
                    local name = input:getInputText()
                    UIManager:close(input)
                    local path, err = FileOps.createFolder(home, name)
                    if path then
                        pick(path)
                    else
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = err == "exists"
                                and _("A folder with that name already exists.")
                                or  _("Invalid folder name."),
                            icon = "notice-warning",
                        })
                        cancel()
                    end
                end },
            }},
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end

    -- "Browse device": KOReader's own folder navigator, unrooted -
    -- reaches anywhere including outside home_dir (the move flow warns
    -- about off-shelf destinations). Same config + trailing-slash
    -- normalisation as the chip editor's browse_device.
    local function browse_device()
        local PathChooser = require("ui/widget/pathchooser")
        local confirmed = false
        UIManager:show(PathChooser:new{
            path             = home,
            select_directory = true,
            select_file      = false,
            show_files       = false,
            onConfirm        = function(folder)
                confirmed = true
                pick(folder)
            end,
            close_callback   = function()
                if not confirmed then cancel() end
            end,
        })
    end

    local extra_actions = {
        { label = _("New folder\xE2\x80\xA6"),    on_tap = new_folder },
        { label = _("Browse device\xE2\x80\xA6"), on_tap = browse_device },
    }

    -- LibraryModal grid (searchable, paginated), pickById's shape.
    local ok_lm, LibraryModal = pcall(require, "lib/bookshelf_library_modal")
    if ok_lm and LibraryModal and LibraryModal.new then
        local Screen_ = require("device").screen
        local query = nil
        local visible = choices
        local function recompute()
            if not query or query == "" then
                visible = choices
            else
                visible = {}
                for _i, c in ipairs(choices) do
                    if c.label:lower():find(query:lower(), 1, true)
                        or (c.subtitle or ""):lower():find(query:lower(), 1, true) then
                        visible[#visible + 1] = c
                    end
                end
            end
        end
        local modal
        modal = LibraryModal:new{
            config = {
                title              = opts.title or _("Move to\xE2\x80\xA6"),
                search_placeholder = function() return _("Search\xE2\x80\xA6") end,
                on_search_submit   = function(q)
                    query = q
                    recompute()
                    if modal then modal.page = 1; modal:refresh() end
                end,
                grid_cols      = 2,
                cells_per_page = function()
                    return Screen_:getWidth() > Screen_:getHeight() and 8 or 10
                end,
                item_count = function() return #visible end,
                item_at    = function(idx) return visible[idx] end,
                cell_renderer = function(item, dimen)
                    return require("lib/bookshelf_picker_cell").render(item, dimen)
                end,
                on_cell_tap = function(item)
                    UIManager:close(modal)
                    pick(item.value)
                end,
                footer_actions = (function()
                    local actions = {}
                    for _i, a in ipairs(extra_actions) do
                        actions[#actions + 1] = {
                            label  = a.label,
                            on_tap = function()
                                UIManager:close(modal)
                                a.on_tap()
                            end,
                        }
                    end
                    actions[#actions + 1] = {
                        label  = _("Close"),
                        on_tap = function()
                            UIManager:close(modal)
                            cancel()
                        end,
                    }
                    return actions
                end)(),
            },
        }
        UIManager:show(modal)
        return
    end

    -- Fallback: flat ButtonDialog (works without bookends' modal).
    local ButtonDialog = require("ui/widget/buttondialog")
    local k
    local rows = {}
    for _i, c in ipairs(choices) do
        rows[#rows + 1] = {{
            text     = c.label,
            callback = function() UIManager:close(k); pick(c.value) end,
        }}
    end
    for _i, a in ipairs(extra_actions) do
        rows[#rows + 1] = {{
            text     = a.label,
            callback = function() UIManager:close(k); a.on_tap() end,
        }}
    end
    rows[#rows + 1] = {{
        text     = _("Cancel"),
        callback = function() UIManager:close(k); cancel() end,
    }}
    k = ButtonDialog:new{
        title   = opts.title or _("Move to\xE2\x80\xA6"),
        buttons = rows,
    }
    UIManager:show(k)
end

return Picker
