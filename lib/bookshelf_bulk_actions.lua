-- lib/bookshelf_bulk_actions.lua
-- The bulk-edit action menu opened by tapping the bucket icon.
-- Mirrors lib/bookshelf_widget.lua _openBookMenu's structure but
-- operates on every filepath in the selection set.
-- See docs/superpowers/specs/2026-05-18-bulk-edit-design.md §5/§6.
--
-- Task 11: stage-and-apply. Non-destructive actions stage into a
-- local `draft`; Apply commits across selection:paths() in spec order
-- (refresh -> status -> rating -> collections remove/add -> remove
-- history). Cancel drops (draft is closure-local). Reset / Delete
-- remain immediate-with-confirm but surface a "Pending changes
-- discarded" toast when fired while the draft was dirty.
--
-- Every dynamic-content button uses text_func (not static `text =`);
-- Apply uses enabled_func. Static fields are snapshotted at
-- construction time with the draft fresh and empty, and never
-- re-evaluate on dialog:reinit -- this was the Task 9 critical bug
-- that left Apply permanently disabled and stage markers invisible.

local BulkActions = {}
local _ = require("lib/bookshelf_i18n").gettext
local Blitbuffer = require("ffi/blitbuffer")
local Focus = require("lib/bookshelf_focus")

local function _resolveLabel(count)
    return string.format(_("Edit selected (%d)"), count)
end

function BulkActions.show(opts)
    local selection = opts.selection
    local bw        = opts.bw
    local on_done   = opts.on_done

    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local count        = selection:count()
    if count == 0 then return end

    -- Staging draft. Same schema as the per-book menu (Task 9) so the
    -- two paths read identically. Nil-vs-false distinction on `rating`
    -- separates "no change staged" (false) from "clear the rating"
    -- (nil) -- so the Apply path can tell whether to skip or commit a
    -- nil-clear.
    local draft = {
        status              = nil,
        rating              = false,
        collections_add     = nil,
        collections_remove  = nil,
        refresh_metadata    = false,
        remove_from_history = false,
    }
    local function isDirty()
        return draft.status ~= nil
            or draft.rating ~= false
            or draft.collections_add ~= nil
            or draft.collections_remove ~= nil
            or draft.refresh_metadata
            or draft.remove_from_history
            or draft.favorite ~= nil
    end
    -- Staged buttons get a light-gray background fill (mutated on tap +
    -- propagated via dialog:reinit). Matches the per-book menu's
    -- staging visual so the language is consistent across single-book
    -- and bulk edits.
    local STAGED_BG = Blitbuffer.COLOR_LIGHT_GRAY

    local dialog
    local function close(fn)
        return function()
            UIManager:close(dialog)
            if fn then fn() end
            if on_done then on_done() end
        end
    end

    -- Status row: four staged buttons. Bulk has no current_status
    -- concept (different books may have different statuses), so unlike
    -- the per-book menu there's no "  ✓" current marker — the staged
    -- value is signalled by the gray-fill background. Status is
    -- mutually-exclusive: every tap must update ALL four backgrounds
    -- so the previously-staged button loses its fill.
    local status_buttons = {}
    local function _refresh_status_backgrounds()
        for _i, b in ipairs(status_buttons) do
            b.background = (draft.status == b._status_value) and STAGED_BG or nil
        end
    end
    local function status_button(label, status_value)
        local btn
        btn = {
            text = label,
            background = (draft.status == status_value) and STAGED_BG or nil,
            callback = function()
                if draft.status == status_value then
                    draft.status = nil  -- tap-again un-stages
                else
                    draft.status = status_value
                end
                _refresh_status_backgrounds()
                if dialog and dialog.reinit then
                    Focus.reinit(dialog)
                    UIManager:setDirty(dialog, "ui")
                end
            end,
        }
        btn._status_value = status_value
        status_buttons[#status_buttons + 1] = btn
        return btn
    end
    local status_row = {
        status_button(_("Unopened"), "new"),
        status_button(_("Reading"),  "reading"),
        status_button(_("On hold"),  "abandoned"),
        status_button(_("Finished"), "complete"),
    }

    -- Rating button + sub-dialog. Sub-dialog writes to draft.rating
    -- instead of persisting; outer button's text_func reflects the
    -- staged target (or "(clear)" when nil is staged). Staged state
    -- signalled by the gray-fill background, mutated by rating_close.
    local rating_button
    rating_button = {
        text_func = function()
            if draft.rating == false then
                return _("Rating")
            elseif draft.rating == nil then
                return _("Rating") .. " " .. _("(clear)")
            else
                local r = draft.rating
                if r < 0 then r = 0 end
                if r > 5 then r = 5 end
                r = math.floor(r)
                return ("\xE2\x98\x85"):rep(r) .. ("\xE2\x98\x86"):rep(5 - r)
            end
        end,
        background = draft.rating ~= false and STAGED_BG or nil,
        callback = function()
            local rating_dialog
            local function rating_close(fn)
                return function()
                    if fn then fn() end
                    UIManager:close(rating_dialog)
                    rating_button.background = draft.rating ~= false and STAGED_BG or nil
                    if dialog and dialog.reinit then
                        Focus.reinit(dialog)
                        UIManager:setDirty(dialog, "ui")
                    end
                end
            end
            local rows = {}
            for i = 1, 5 do
                local star_label = ("\xE2\x98\x85"):rep(i) .. ("\xE2\x98\x86"):rep(5 - i)
                rows[#rows + 1] = {
                    { text = star_label, callback = rating_close(function()
                        draft.rating = i
                    end) },
                }
            end
            rows[#rows + 1] = {
                { text = _("Clear"), callback = rating_close(function()
                    draft.rating = nil  -- nil = "clear" target on Apply
                end) },
            }
            rows[#rows + 1] = {
                { text = _("Cancel"), callback = rating_close() },
            }
            rating_dialog = require("ui/widget/buttondialog"):new{
                title   = _("Set rating"),
                buttons = rows,
            }
            UIManager:show(rating_dialog)
        end,
    }

    -- Favourite: 3-state cycle button (no change → add → remove → none).
    -- Mirrors the long-press menu's ± Favourite toggle but stages across
    -- the whole selection. The default ReadCollection name is "favorites"
    -- (the same key the spine widget's star checks), so add/remove maps
    -- directly to ReadCollection:addItem / :removeItem on apply.
    local favorite_button
    favorite_button = {
        text_func = function()
            if draft.favorite == "add" then
                return "+ " .. _("Favourite")
            elseif draft.favorite == "remove" then
                return "\xE2\x88\x92 " .. _("Favourite")  -- U+2212 minus
            end
            return _("Favourite")
        end,
        background = draft.favorite and STAGED_BG or nil,
        callback = function()
            if draft.favorite == nil then
                draft.favorite = "add"
            elseif draft.favorite == "add" then
                draft.favorite = "remove"
            else
                draft.favorite = nil
            end
            favorite_button.background = draft.favorite and STAGED_BG or nil
            if dialog and dialog.reinit then
                Focus.reinit(dialog)
                UIManager:setDirty(dialog, "ui")
            end
        end,
    }

    -- Collections: opens the collection manager in bulk mode. Manager
    -- renders tri-state cells against the selection (all / some / none)
    -- and returns a {add, remove} diff via on_save. Cancel leaves the
    -- existing staged diff unchanged. Staged state signalled by the
    -- gray-fill background, mutated when on_save updates the draft.
    local collections_button
    collections_button = {
        text = _("Collections") .. "\xE2\x80\xA6",
        background = (draft.collections_add or draft.collections_remove) and STAGED_BG or nil,
        callback = function()
            local CollectionManager = require("lib/bookshelf_collection_manager")
            CollectionManager.show{
                bulk           = true,
                paths          = selection:paths(),
                bw             = bw,
                initial_add    = draft.collections_add,
                initial_remove = draft.collections_remove,
                on_save        = function(diff)
                    draft.collections_add    = diff and diff.add    or nil
                    draft.collections_remove = diff and diff.remove or nil
                    collections_button.background =
                        (draft.collections_add or draft.collections_remove)
                        and STAGED_BG or nil
                    if dialog and dialog.reinit then
                        Focus.reinit(dialog)
                        UIManager:setDirty(dialog, "ui")
                    end
                end,
                on_cancel      = function()
                    -- Draft preserved; nothing to do.
                end,
            }
        end,
    }

    -- Refresh metadata / Remove from history: boolean toggles.
    -- Staged state signalled by gray-fill background.
    local refresh_button
    refresh_button = {
        text = _("Refresh metadata"),
        background = draft.refresh_metadata and STAGED_BG or nil,
        callback = function()
            draft.refresh_metadata = not draft.refresh_metadata
            refresh_button.background = draft.refresh_metadata and STAGED_BG or nil
            if dialog and dialog.reinit then
                Focus.reinit(dialog)
                UIManager:setDirty(dialog, "ui")
            end
        end,
    }
    local remove_history_button
    remove_history_button = {
        text = _("Remove from history"),
        background = draft.remove_from_history and STAGED_BG or nil,
        callback = function()
            draft.remove_from_history = not draft.remove_from_history
            remove_history_button.background = draft.remove_from_history and STAGED_BG or nil
            if dialog and dialog.reinit then
                Focus.reinit(dialog)
                UIManager:setDirty(dialog, "ui")
            end
        end,
    }

    -- Reset: simple ConfirmBox that purges DocSettings for each
    -- selected file. Captures isDirty() BEFORE closing so the
    -- "Pending changes discarded" toast can fire on confirmation when
    -- the draft was non-empty (the destructive op subsumes any
    -- non-destructive staging). A richer checkbox-based reset is
    -- deferred to a later task; for now ds:purge() is a full reset.
    local reset_button = {
        text = _("Reset book data\xE2\x80\xA6"),
        callback = function()
            local discard_toast = isDirty()
            UIManager:close(dialog)
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text    = string.format(_("Reset %d books?"), count),
                ok_text = _("Reset"),
                ok_callback = function()
                    local DocSettings = require("docsettings")
                    local paths = selection:paths()
                    for _i, fp in ipairs(paths) do
                        pcall(function()
                            local ds = DocSettings:open(fp)
                            ds:purge()
                        end)
                    end
                    local Repo = require("lib/bookshelf_book_repository")
                    Repo.invalidateBookCache("bulk-reset")
                    -- Per-file progress cache holds the pre-reset status
                    -- (e.g. "reading") for each file; without flushing
                    -- it, status-filtered chips like Reading keep
                    -- including the now-purged books and the placeholder
                    -- maths goes sideways. Flush each path individually
                    -- so we don't blow away progress data for files that
                    -- weren't part of the reset.
                    for _i, fp in ipairs(paths) do
                        pcall(function() Repo.invalidateProgressCache(fp) end)
                    end
                    -- Reset is a destructive bulk action; like Delete,
                    -- exit selection mode after applying so the bulk-
                    -- select footer (cancel ✕ + count badge) clears.
                    selection:exitMode()
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                    if discard_toast then
                        UIManager:show(require("ui/widget/notification"):new{
                            text    = _("Pending changes discarded"),
                            timeout = 1,
                        })
                    end
                    if on_done then on_done() end
                end,
            })
        end,
    }

    -- Delete: destructive. Same "captured discard_toast" pattern as
    -- Reset. Preview lists up to 5 paths + "… and N more". Exits
    -- selection mode after delete since the affected entries are gone.
    local delete_button = {
        text     = "\xE2\x9C\x95 " .. _("Delete"),  -- ✕ + Delete
        callback = function()
            local discard_toast = isDirty()
            UIManager:close(dialog)
            local ConfirmBox = require("ui/widget/confirmbox")
            local paths = selection:paths()
            local preview = {}
            for i, fp in ipairs(paths) do
                if i > 5 then
                    preview[#preview + 1] = string.format(_("\xE2\x80\xA6 and %d more"), count - 5)
                    break
                end
                preview[#preview + 1] = fp
            end
            UIManager:show(ConfirmBox:new{
                text    = string.format(_("Delete %d books?"), count) .. "\n\n" .. table.concat(preview, "\n"),
                ok_text = _("Delete"),
                ok_callback = function()
                    for _i, fp in ipairs(paths) do
                        pcall(function()
                            os.remove(fp)
                            require("readhistory"):fileDeleted(fp)
                            require("readcollection"):removeItem(fp)
                        end)
                    end
                    local Repo = require("lib/bookshelf_book_repository")
                    Repo.invalidateWalkCache()
                    for _i, fp in ipairs(paths) do
                        pcall(function() Repo.invalidateProgressCache(fp) end)
                    end
                    for _i, fp in ipairs(paths) do
                        bw:_scrubFromDrilldown(fp)
                    end
                    selection:exitMode()
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                    if discard_toast then
                        UIManager:show(require("ui/widget/notification"):new{
                            text    = _("Pending changes discarded"),
                            timeout = 1,
                        })
                    end
                    if on_done then on_done() end
                end,
            })
        end,
    }

    -- Cancel: draft is closure-local, so close() is enough -- on
    -- next-tick the draft goes out of scope and is GC'd.
    local cancel_button = {
        text     = _("Cancel"),
        callback = close(),
    }

    -- Soft confirm threshold: prompt before mutating when the selection
    -- is this large, giving the user a chance to back out before any
    -- changes land. Tune this constant based on real-world feedback.
    local LARGE_SELECTION_THRESHOLD = 50

    -- Apply: enabled iff anything is staged. enabled_func (NOT static
    -- `enabled = isDirty()`) because Button:init re-evaluates
    -- enabled_func on every paint -- a static value would be
    -- snapshotted as false at construction with the draft fresh and
    -- empty, and Apply would stay permanently disabled.
    --
    -- Per-book apply each pcall-wrapped via safe() so a single failure
    -- doesn't abort the rest. Single _rebuild + setDirty at the end.
    -- Spec §6 order: refresh -> status -> rating -> collections
    -- (remove first, then add) -> remove_from_history.
    --
    -- Pre-Apply: scrubMissing drops paths whose files have vanished
    -- (sync deleted them between selection time and Apply tap). Show a
    -- short toast about the skipped count; selection:paths() is
    -- re-read after the scrub because the underlying set has changed.
    --
    -- Large selections (>= LARGE_SELECTION_THRESHOLD): a ConfirmBox
    -- is shown before the loop so the user can back out. The dialog is
    -- already closed at this point; Cancel simply abandons the op and
    -- leaves the shelf as-is (no draft mutation happened yet).
    --
    -- UI yields during the per-book loop: _kickOffMissingMetaExtraction
    -- uses scheduleIn polling rather than coroutine.yield, and that
    -- pattern doesn't compose cleanly into a synchronous apply loop.
    -- For typical selection sizes the per-book work completes in well
    -- under a second on PW5. A yield-based approach can land as a
    -- follow-up if reporters flag freezes on very large selections.
    local apply_button = {
        text         = _("Apply"),
        enabled_func = function() return isDirty() end,
        callback     = function()
            UIManager:close(dialog)
            local lfs = require("libs/libkoreader-lfs")
            local missing = selection:scrubMissing(function(p)
                return lfs.attributes(p, "mode") == "file"
            end)
            if missing > 0 then
                UIManager:show(require("ui/widget/notification"):new{
                    text    = string.format(_("%d files no longer exist; skipped."), missing),
                    timeout = 2,
                })
            end
            local paths = selection:paths()  -- re-read post-scrub
            local n = #paths
            if n == 0 then
                if on_done then on_done() end
                return
            end
            local logger = require("logger")
            local function _do_apply()
                local applied, failed = 0, 0
                -- Paths whose BIM row gets wiped by the refresh action.
                -- After the per-file mutation loop we hand this list to
                -- BIM:extractInBackground in one batch so the books are
                -- actually re-extracted, not just deleted. Without this
                -- final step, _rebuild's _kickOff only re-queues the
                -- visible page; off-page selections stay deleted in BIM
                -- until the user happens to navigate to them, and
                -- meanwhile drop out of any view that queries BIM by
                -- series / author / genre. (Diagnosed earlier: a
                -- bulk-refresh of ~80 books deletes all their BIM rows,
                -- but the kickoff fallback only re-extracts the visible
                -- page (~27), leaving the rest in BIM-row limbo.)
                local refresh_paths = {}
                local function safe(action_name, fn, fp)
                    local ok, err = pcall(fn)
                    if not ok then
                        logger.warn("bookshelf bulk apply:", action_name, fp, err)
                        return false
                    end
                    return true
                end
                for _i, fp in ipairs(paths) do
                    local ok = true
                    if draft.refresh_metadata then
                        ok = safe("refresh", function()
                            local ok_bim, BIM = pcall(require, "bookinfomanager")
                            if ok_bim and BIM and BIM.deleteBookInfo then
                                BIM:deleteBookInfo(fp)
                                -- Drop the in-memory scaled cover so the
                                -- next render re-decodes from the freshly
                                -- re-extracted BIM bytes (matches the
                                -- single-book Refresh metadata path).
                                pcall(function()
                                    require("lib/bookshelf_scaled_cover_cache"):drop(fp)
                                end)
                                refresh_paths[#refresh_paths + 1] = fp
                            end
                        end, fp) and ok
                    end
                    if draft.status then
                        ok = safe("status", function()
                            local DocSettings = require("docsettings")
                            local ds = DocSettings:open(fp)
                            local summary = ds:readSetting("summary") or {}
                            summary.status = draft.status
                            ds:saveSetting("summary", summary)
                            if draft.status == "new" then
                                ds:delSetting("percent_finished")
                                ds:delSetting("last_xp")
                                ds:delSetting("last_page")
                            end
                            ds:flush()
                        end, fp) and ok
                    end
                    if draft.rating ~= false then
                        ok = safe("rating", function()
                            bw:_setBookRatingByPath(fp, draft.rating)
                        end, fp) and ok
                    end
                    if draft.collections_remove then
                        ok = safe("collections_remove", function()
                            local ReadCollection = require("readcollection")
                            for name in pairs(draft.collections_remove) do
                                pcall(function() ReadCollection:removeItem(fp, name) end)
                            end
                        end, fp) and ok
                    end
                    if draft.collections_add then
                        ok = safe("collections_add", function()
                            local ReadCollection = require("readcollection")
                            for name in pairs(draft.collections_add) do
                                pcall(function() ReadCollection:addItem(fp, name) end)
                            end
                        end, fp) and ok
                    end
                    if draft.favorite == "add" then
                        ok = safe("favorite_add", function()
                            local ReadCollection = require("readcollection")
                            ReadCollection:addItem(fp,
                                ReadCollection.default_collection_name)
                        end, fp) and ok
                    elseif draft.favorite == "remove" then
                        ok = safe("favorite_remove", function()
                            local ReadCollection = require("readcollection")
                            ReadCollection:removeItem(fp,
                                ReadCollection.default_collection_name)
                        end, fp) and ok
                    end
                    if draft.remove_from_history then
                        ok = safe("remove_history", function()
                            require("readhistory"):removeItemByPath(fp)
                        end, fp) and ok
                    end
                    if ok then applied = applied + 1 else failed = failed + 1 end
                end
                -- Flush collection changes to disk. ReadCollection:addItem
                -- only mutates in-memory state (unlike removeItem which
                -- calls write() internally), so without this explicit flush
                -- bulk-added collections disappear on next session start.
                -- Favourite add/remove writes to the default collection
                -- ("favorites") and shares the same flush requirement.
                if draft.collections_add or draft.collections_remove
                        or draft.favorite then
                    local ReadCollection = require("readcollection")
                    ReadCollection:write()
                end
                local Repo = require("lib/bookshelf_book_repository")
                Repo.invalidateBookCache("bulk-apply")
                -- Targeted invalidation so the Favourites chip reflects
                -- the bulk toggle without a swipe-down refresh.
                if draft.favorite then
                    pcall(function() Repo.invalidateFavoritesCache() end)
                end
                bw:_rebuild()
                UIManager:setDirty(bw, "ui")
                -- Queue refresh-deleted paths for TEXT-ONLY metadata
                -- re-extraction (title, author, series, etc.). No
                -- cover_specs means BIM's extractBookInfo skips the
                -- image-decode + scale + blob-compress path entirely
                -- -- text extraction is roughly 10x faster per book
                -- (~30ms vs ~300ms), so refreshing 30 books finishes
                -- in ~1s instead of ~9s.
                --
                -- Covers come back via the kickoff path: as each book
                -- becomes visible during the user's normal browsing,
                -- _kickOffMissingMetaExtraction sees cover_fetched=nil
                -- (text-only extraction leaves this unset) and queues
                -- it with cover_specs sized to the current slot. With
                -- the priority-interrupt model in _kickOff, that
                -- visible-page extraction terminates BIM's running
                -- bulk text-pass so the user's current covers appear
                -- immediately; the bulk leftovers stay in the watch
                -- list (see _armExtractionPoll's merge) and the
                -- orphan-retry in _pollExtraction picks them up when
                -- BIM goes idle.
                if #refresh_paths > 0 then
                    local extract_list = {}
                    for _i, fp in ipairs(refresh_paths) do
                        extract_list[#extract_list + 1] = { filepath = fp }
                    end
                    bw:_fireBimExtraction(extract_list, "bulk-refresh")
                    bw:_armExtractionPoll(extract_list)
                end
                if failed > 0 then
                    UIManager:show(require("ui/widget/notification"):new{
                        text    = string.format(_("Applied to %d of %d books \xC2\xB7 %d failed"), applied, n, failed),
                        timeout = 3,
                    })
                end
                if on_done then on_done() end
            end
            if n >= LARGE_SELECTION_THRESHOLD then
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text        = string.format(_("Apply changes to %d books?"), n),
                    ok_callback = _do_apply,
                })
                return
            end
            _do_apply()
        end,
    }

    local buttons = {
        { collections_button, rating_button },
        status_row,
        { favorite_button, refresh_button },
        { remove_history_button },
        { reset_button, delete_button },
        { cancel_button, apply_button },
    }

    dialog = ButtonDialog:new{
        title       = _resolveLabel(count),
        title_align = "center",
        buttons     = buttons,
    }
    UIManager:show(dialog)
end

return BulkActions
