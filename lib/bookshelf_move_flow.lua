-- lib/bookshelf_move_flow.lua
-- UI orchestration for moves: destination picker, confirm dialog,
-- engine execution, summary toast, shelf refresh. Shared by the bulk
-- menu, the book detail Edit tab and the folder long-press menu, so
-- the confirm/report logic exists exactly once.

local _ = require("lib/bookshelf_i18n").gettext

local MoveFlow = {}

local function notify(text, timeout)
    local UIManager = require("ui/uimanager")
    UIManager:show(require("ui/widget/notification"):new{
        text = text, timeout = timeout or 2,
    })
end

-- Warn when books landing in dest_dir won't be reachable by the
-- repository walk (outside home_dir, or deeper than the walk depth).
local function offShelfWarning(dest_dir)
    local FileOps = require("lib/bookshelf_file_ops")
    local BookshelfSettings = require("lib/bookshelf_settings_store")
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    if not FileOps.isVisibleOnShelf(dest_dir, home, depth) then
        return _("These books will no longer appear on the shelf.")
    end
    return nil
end

-- Batch-level invalidation after books moved. Per-file steps already
-- ran inside the engine; this is the once-per-batch tail from the spec.
local function afterBooksMoved(bw, summary)
    local UIManager = require("ui/uimanager")
    local Repo = require("lib/bookshelf_book_repository")
    Repo.invalidateWalkCache()
    local SCC = require("lib/bookshelf_scaled_cover_cache")
    for _i, old in ipairs(summary.moved) do
        pcall(function() Repo.invalidateProgressCache(old) end)
        pcall(function() SCC:drop(old) end)
        if bw and bw._scrubFromDrilldown then bw:_scrubFromDrilldown(old) end
    end
    pcall(function()
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end)
    if bw then
        bw:_rebuild()
        UIManager:setDirty(bw, "ui")
    end
end

local function summaryToast(summary)
    local bits = { string.format(_("Moved %d books."), #summary.moved) }
    local skip_n = 0
    for _r, n in pairs(summary.skipped) do skip_n = skip_n + n end
    if skip_n > 0 then
        bits[#bits + 1] = string.format(_("%d skipped."), skip_n)
    end
    if summary.failed > 0 then
        bits[#bits + 1] = string.format(_("%d failed."), summary.failed)
    end
    notify(table.concat(bits, " "), 3)
end

-- MoveFlow.moveBooks{ bw, paths, on_done, on_cancel }
function MoveFlow.moveBooks(opts)
    local UIManager = require("ui/uimanager")
    local FileOps = require("lib/bookshelf_file_ops")
    local Picker = require("lib/bookshelf_folder_picker")
    local paths = opts.paths or {}
    if #paths == 0 then return end
    Picker.show{
        title     = string.format(_("Move %d books to\xE2\x80\xA6"), #paths),
        on_cancel = opts.on_cancel,
        on_pick   = function(dest_dir)
            local plan = FileOps.planMoves(paths, dest_dir,
                { in_use_paths = FileOps.inUsePaths() })
            if #plan.moves == 0 then
                notify(_("Nothing to move: all selected books were skipped."), 3)
                if opts.on_done then opts.on_done(nil) end
                return
            end
            local preview = {}
            for i, m in ipairs(plan.moves) do
                if i > 5 then
                    preview[#preview + 1] = string.format(
                        _("\xE2\x80\xA6 and %d more"), #plan.moves - 5)
                    break
                end
                preview[#preview + 1] = FileOps.basename(m.from)
            end
            local lines = {
                string.format(_("Move %d books to %s?"), #plan.moves, dest_dir),
                "",
                table.concat(preview, "\n"),
            }
            if #plan.skipped > 0 then
                lines[#lines + 1] = ""
                lines[#lines + 1] = string.format(
                    _("%d will be skipped (already exist, in use or missing)."),
                    #plan.skipped)
            end
            local warn = offShelfWarning(dest_dir)
            if warn then
                lines[#lines + 1] = ""
                lines[#lines + 1] = warn
            end
            UIManager:show(require("ui/widget/confirmbox"):new{
                text        = table.concat(lines, "\n"),
                ok_text     = _("Move"),
                ok_callback = function()
                    local function run()
                        local summary = FileOps.moveBooks(plan)
                        afterBooksMoved(opts.bw, summary)
                        summaryToast(summary)
                        if opts.on_done then opts.on_done(summary) end
                    end
                    if #plan.moves >= 10 then
                        -- Big batches (or cross-device moves) can take
                        -- seconds; paint a blocker first.
                        local InfoMessage = require("ui/widget/infomessage")
                        local busy = InfoMessage:new{ text = _("Moving\xE2\x80\xA6") }
                        UIManager:show(busy)
                        UIManager:forceRePaint()
                        UIManager:nextTick(function()
                            run()
                            UIManager:close(busy)
                        end)
                    else
                        run()
                    end
                end,
            })
        end,
    }
end

-- Shared tail for folder move + rename.
local function afterFolderChanged(bw)
    local UIManager = require("ui/uimanager")
    local Repo = require("lib/bookshelf_book_repository")
    Repo.invalidateWalkCache()
    pcall(function() Repo.invalidateBookCache("folder-move") end)
    pcall(function() require("lib/bookshelf_image_source").invalidateCache() end)
    if bw then
        -- The drill stack may reference the old folder path; reset to
        -- the shelf root rather than re-keying the persisted stack.
        bw._drilldown_path = {}
        pcall(function() bw:_persistNavState() end)
        bw:_rebuild()
        UIManager:setDirty(bw, "ui")
    end
end

local FOLDER_ERRORS = {
    missing = _("Folder no longer exists."),
    exists  = _("A folder with that name already exists there."),
    self    = _("Cannot move a folder into itself."),
    error   = _("Failed to move folder."),
    bad_name = _("Invalid folder name."),
}

-- MoveFlow.moveFolder{ bw, folder_path }
function MoveFlow.moveFolder(opts)
    local UIManager = require("ui/uimanager")
    local FileOps = require("lib/bookshelf_file_ops")
    local Picker = require("lib/bookshelf_folder_picker")
    local Repo = require("lib/bookshelf_book_repository")
    local folder = FileOps.normDir(opts.folder_path)
    local ok_books, books = pcall(Repo.getFolderBookPaths, folder)
    local n_books = (ok_books and books and #books) or 0
    Picker.show{
        title   = string.format(_("Move %s to\xE2\x80\xA6"), FileOps.basename(folder)),
        exclude = { folder },
        on_pick = function(dest_dir)
            local new_dir = FileOps.joinDir(dest_dir, FileOps.basename(folder))
            local lines = {
                string.format(_("Move folder %s (%d books) to %s?"),
                    FileOps.basename(folder), n_books, dest_dir),
            }
            local warn = offShelfWarning(new_dir)
            if warn then
                lines[#lines + 1] = ""
                lines[#lines + 1] = warn
            end
            UIManager:show(require("ui/widget/confirmbox"):new{
                text        = table.concat(lines, "\n"),
                ok_text     = _("Move"),
                ok_callback = function()
                    local ok, n_or_err = FileOps.relocateFolder(folder, new_dir)
                    if ok then
                        afterFolderChanged(opts.bw)
                        notify(string.format(_("Moved folder %s."),
                            FileOps.basename(folder)), 3)
                    else
                        notify(FOLDER_ERRORS[n_or_err] or FOLDER_ERRORS.error, 3)
                    end
                end,
            })
        end,
    }
end

-- MoveFlow.renameFolder{ bw, folder_path }
function MoveFlow.renameFolder(opts)
    local UIManager = require("ui/uimanager")
    local FileOps = require("lib/bookshelf_file_ops")
    local folder = FileOps.normDir(opts.folder_path)
    local InputDialog = require("ui/widget/inputdialog")
    local input
    input = InputDialog:new{
        title = _("Rename folder"),
        input = FileOps.basename(folder),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(input)
            end },
            { text = _("Rename"), is_enter_default = true, callback = function()
                local new_name = input:getInputText()
                UIManager:close(input)
                if new_name == FileOps.basename(folder) then return end
                local ok, err = FileOps.renameFolder(folder, new_name)
                if ok then
                    afterFolderChanged(opts.bw)
                    notify(string.format(_("Renamed to %s."), new_name), 3)
                else
                    notify(FOLDER_ERRORS[err] or FOLDER_ERRORS.error, 3)
                end
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

return MoveFlow
