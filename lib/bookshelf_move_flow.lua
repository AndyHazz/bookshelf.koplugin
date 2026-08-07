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

-- Bookshelf-styled confirmation dialog: bold centered title with an
-- infofont prompt between title and buttons - the same construction as
-- the group long-press menu in bookshelf_widget.lua - instead of
-- KOReader's stock icon-and-text ConfirmBox.
local function showMoveConfirm(args)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local BFont = require("lib/bookshelf_fonts")
    local Screen = require("device").screen
    local dialog
    dialog = ButtonDialog:new{
        title          = args.title,
        title_align    = "center",
        use_info_style = false,  -- bold title face, not infofont
        buttons = {{
            { text = _("Cancel"), callback = function()
                UIManager:close(dialog)
            end },
            { text = args.ok_text, callback = function()
                UIManager:close(dialog)
                args.ok_callback()
            end },
        }},
    }
    local prompt_face, prompt_bold = BFont:getFace("infofont", 16)
    dialog:addWidget(TextBoxWidget:new{
        text      = args.prompt,
        face      = prompt_face,
        bold      = prompt_bold,
        alignment = "center",
        width     = dialog.title_group_width or math.floor(Screen:getWidth() * 0.6),
    })
    UIManager:show(dialog)
end

-- Destination display: folder name plus its home-abbreviated path on a
-- second line, rather than a raw absolute path mid-sentence.
local function destLabel(dest_dir)
    local FileOps = require("lib/bookshelf_file_ops")
    local name = FileOps.basename(dest_dir) or dest_dir
    local shown = dest_dir
    pcall(function()
        shown = require("apps/filemanager/filemanagerutil").abbreviate(dest_dir)
    end)
    if shown == name then
        return name
    end
    return string.format("%s\n(%s)", name, shown)
end

-- One line per skip reason, with the real reason spelled out - we know
-- exactly why each book was skipped, so saying "already exist, in use
-- or missing" would be hiding information the user needs. Each line is
-- its own msgid with a count, which keeps the plurals translatable.
local SKIP_LINES = {
    exists   = _("%d skipped: a book of that name is already there."),
    in_use   = _("%d skipped: currently open."),
    missing  = _("%d skipped: no longer on the device."),
    same_dir = _("%d skipped: already in that folder."),
}
local SKIP_ORDER = { "exists", "same_dir", "in_use", "missing" }

local function skipLines(skipped)
    local counts = {}
    for _i, s in ipairs(skipped) do
        counts[s.reason] = (counts[s.reason] or 0) + 1
    end
    local out = {}
    for _i, reason in ipairs(SKIP_ORDER) do
        if counts[reason] then
            out[#out + 1] = string.format(SKIP_LINES[reason], counts[reason])
        end
    end
    return out
end

-- Warn when books landing in dest_dir won't be reachable by the
-- repository walk (outside home_dir, or deeper than the walk depth).
-- Batches this size or larger get the counting progress blocker.
local PROGRESS_THRESHOLD = 5

-- A "Moving 12 of 40..." blocker.
--
-- InfoMessage builds its text into a local TextBoxWidget at init, so
-- there is no supported way to change the text of a shown one. Each
-- update therefore shows a fresh message and closes the previous one -
-- new first, so the screen is never briefly bare.
--
-- Repainting e-ink costs ~100-200ms, so updating per book would make a
-- 200-book move slower than the moves themselves. Update at most ~20
-- times across the batch, always including the first and last step.
local function progressBlocker(total)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local step = math.max(1, math.floor(total / 20))
    local shown, last_at
    -- The number is the item being worked on, not the count completed, so
    -- the first paint reads "1 of 12" rather than a puzzling "0 of 12".
    local function paint(at)
        at = math.min(at, total)
        -- The last step clamps to `total`, which the step before it may
        -- already have shown: skip the repaint rather than pay for e-ink
        -- redrawing the same text.
        if at == last_at then return end
        last_at = at
        local msg = InfoMessage:new{
            text = string.format(_("Moving %d of %d\xE2\x80\xA6"), at, total),
        }
        UIManager:show(msg)
        if shown then UIManager:close(shown) end
        shown = msg
        UIManager:forceRePaint()
    end
    return {
        start = function() paint(1) end,
        progress = function(done, n)
            if done == 1 or done == n or done % step == 0 then paint(done + 1) end
        end,
        -- The files are all moved by now, but the caches still have to be
        -- rebuilt and the shelf re-rendered, which on a large library is
        -- the slowest part. Say so, rather than leaving "Moving 43 of 43"
        -- on screen looking stuck.
        finishing = function()
            local msg = InfoMessage:new{ text = _("Updating library\xE2\x80\xA6") }
            UIManager:show(msg)
            if shown then UIManager:close(shown) end
            shown = msg
            UIManager:forceRePaint()
        end,
        finish = function()
            if shown then UIManager:close(shown); shown = nil end
        end,
    }
end

-- Names WHICH of the two causes applies, because the fix differs: move
-- somewhere inside the home folder, or raise the walk depth. Saying only
-- "will no longer appear" leaves the user with no way to act on it.
local function offShelfWarning(dest_dir)
    local FileOps = require("lib/bookshelf_file_ops")
    local BookshelfSettings = require("lib/bookshelf_settings_store")
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    if FileOps.isVisibleOnShelf(dest_dir, home, depth) then return nil end
    local dest_depth = FileOps.shelfDepth(dest_dir, home)
    if dest_depth == nil then
        return string.format(
            _("Not shown on the shelf: this folder is outside your home folder (%s)."),
            FileOps.basename(home) or home)
    end
    return string.format(
        _("Not shown on the shelf: this folder is %d levels below your home folder, and the shelf scans %d. Raise the folder walk depth in Bookshelf settings to include it."),
        dest_depth, depth)
end

-- Batch-level invalidation after books moved. Per-file steps already
-- ran inside the engine; this is the once-per-batch tail from the spec.
local function afterBooksMoved(bw, summary)
    local UIManager = require("ui/uimanager")
    local Repo = require("lib/bookshelf_book_repository")
    Repo.invalidateWalkCache()
    local SCC = require("lib/bookshelf_scaled_cover_cache")
    for i, old in ipairs(summary.moved) do
        pcall(function() Repo.invalidateProgressCache(old) end)
        pcall(function() SCC:drop(old) end)
        -- Re-key (not scrub) the live drilldown payloads: a moved book is
        -- still a member of a collection / series / author / genre view,
        -- only its path changed. Scrubbing here made a book moved from
        -- inside a collection vanish until the view was re-entered.
        if bw and bw._rekeyDrilldown then
            bw:_rekeyDrilldown(old, summary.moved_to[i])
        end
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
    local n = #summary.moved
    local bits = { n == 1 and _("Moved 1 book.")
        or string.format(_("Moved %d books."), n) }
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
                string.format(_("To: %s"), destLabel(dest_dir)),
                "",
                table.concat(preview, "\n"),
            }
            local skips = skipLines(plan.skipped)
            if #skips > 0 then
                lines[#lines + 1] = ""
                for _i, s in ipairs(skips) do lines[#lines + 1] = s end
            end
            local warn = offShelfWarning(dest_dir)
            if warn then
                lines[#lines + 1] = ""
                lines[#lines + 1] = warn
            end
            showMoveConfirm{
                title       = #plan.moves == 1 and _("Move 1 book")
                    or string.format(_("Move %d books"), #plan.moves),
                prompt      = table.concat(lines, "\n"),
                ok_text     = _("Move"),
                ok_callback = function()
                    local total = #plan.moves
                    local function run(busy)
                        local summary = FileOps.moveBooks(plan,
                            busy and busy.progress or nil)
                        if busy then busy.finishing() end
                        -- Callers that need to change shelf state before it
                        -- re-renders (exiting selection mode, say) do it
                        -- here, so afterBooksMoved's rebuild is the ONLY one.
                        if opts.before_refresh then
                            pcall(opts.before_refresh, summary)
                        end
                        afterBooksMoved(opts.bw, summary)
                        summaryToast(summary)
                        if opts.on_done then opts.on_done(summary) end
                    end
                    if total >= PROGRESS_THRESHOLD then
                        -- Big batches (and any cross-filesystem move, which
                        -- copies rather than renames) take real time. Count
                        -- through them so it never reads as a hang.
                        local busy = progressBlocker(total)
                        busy.start()
                        UIManager:nextTick(function()
                            local ok, err = pcall(run, busy)
                            busy.finish()
                            if not ok then
                                require("logger").warn("bookshelf move:", err)
                            end
                        end)
                    else
                        run(nil)
                    end
                end,
            }
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
    pcall(function()
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end)
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
    in_use  = _("Cannot move this folder: a book inside it is currently open."),
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
                string.format(_("%d books"), n_books),
                "",
                string.format(_("To: %s"), destLabel(dest_dir)),
            }
            local warn = offShelfWarning(new_dir)
            if warn then
                lines[#lines + 1] = ""
                lines[#lines + 1] = warn
            end
            showMoveConfirm{
                title       = string.format(_("Move %s"), FileOps.basename(folder)),
                prompt      = table.concat(lines, "\n"),
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
            }
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
