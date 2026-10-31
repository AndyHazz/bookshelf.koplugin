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
-- The menu is a page (lib/bookshelf_page_dialog, STYLE.md), laid out
-- again from the draft after every tap, so what is staged shows black at
-- once and Apply greys until something is.

local BulkActions = {}
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local function _resolveLabel(count)
    return string.format(_("Edit selected (%d)"), count)
end

function BulkActions.show(opts)
    local selection = opts.selection
    local bw        = opts.bw
    local on_done   = opts.on_done

    local UIManager    = require("ui/uimanager")
    local count        = selection:count()
    if count == 0 then return end

    -- Staging draft. Same schema as the per-book menu so the two paths
    -- read identically. Nil-vs-false distinction on `rating`
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
    -- What has been staged shows at once: the page is laid out again from
    -- the draft (dialog:refresh()).
    local dialog
    local function close(fn)
        return function()
            UIManager:close(dialog)
            if fn then fn() end
            if on_done then on_done() end
        end
    end

    local function restage()
        if dialog then dialog:refresh() end
    end

    -- Collections: opens the collection manager in bulk mode. Manager
    -- renders tri-state cells against the selection (all / some / none)
    -- and returns a {add, remove} diff via on_save. Cancel leaves the
    -- existing staged diff unchanged.
    local collections_button
    collections_button = {
        text = _("Collections") .. "\xE2\x80\xA6",
        callback = function()
            local CollectionManager = require("lib/bookshelf_collection_manager")
            CollectionManager.show{
                bulk           = true,
                over           = dialog and dialog:over({ _("Collections") }),
                paths          = selection:paths(),
                bw             = bw,
                initial_add    = draft.collections_add,
                initial_remove = draft.collections_remove,
                on_save        = function(diff)
                    draft.collections_add    = diff and diff.add    or nil
                    draft.collections_remove = diff and diff.remove or nil
                    restage()
                end,
                on_cancel      = function()
                    -- Draft preserved; nothing to do.
                end,
            }
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
        text     = _("Delete"),
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

    -- Move: immediate action like Delete (NOT staged into the draft --
    -- a path-changing op doesn't compose with staged actions keyed on
    -- the old paths). scrubMissing first, same as Apply; exits
    -- selection mode after a successful move since the selection's
    -- keys are the old paths.
    local move_button = {
        text     = _("Move to folder\xE2\x80\xA6"),
        callback = function()
            local discard_toast = isDirty()
            UIManager:close(dialog)
            local lfs = require("libs/libkoreader-lfs")
            selection:scrubMissing(function(p)
                return lfs.attributes(p, "mode") == "file"
            end)
            local paths = selection:paths()
            if #paths == 0 then
                if on_done then on_done() end
                return
            end
            require("lib/bookshelf_move_flow").moveBooks{
                bw      = bw,
                paths   = paths,
                -- Leave selection mode BEFORE the shelf re-renders, so the
                -- move flow's own rebuild is the only one. Rebuilding again
                -- from on_done meant every bulk move built the widget tree
                -- twice, which is what made the tail drag on a big library.
                before_refresh = function(summary)
                    if summary and #summary.moved > 0 then
                        selection:exitMode()
                    end
                end,
                on_done = function(summary)
                    if discard_toast then
                        UIManager:show(require("ui/widget/notification"):new{
                            text    = _("Pending changes discarded"),
                            timeout = 1,
                        })
                    end
                    if on_done then on_done() end
                end,
            }
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
    -- `enabled = isDirty()`): the page's footer asks it each time the page
    -- is drawn again, and a static value would be the fresh draft's false
    -- for good.
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
                                require("lib/bookshelf_book_repository").forgetBook(fp)
                                -- Drop the in-memory scaled cover so the
                                -- next render re-decodes from the freshly
                                -- re-extracted BIM bytes (matches the
                                -- single-book Refresh metadata path).
                                pcall(function()
                                    require("lib/bookshelf_scaled_cover_cache"):drop(fp)
                                end)
                                refresh_paths[#refresh_paths + 1] = fp
                                -- A refresh is the user asking, so the
                                -- cover may be fetched even for a
                                -- plugin-provided format.
                                if bw._allowCoverFetch then
                                    bw:_allowCoverFetch(fp)
                                end
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

    -- "Select all in this shelf": the answer for a flat, filter-built chip,
    -- which has no folder or stack tile to long-press for a group selection
    -- (issue #320). Takes every book the current view holds across ALL its
    -- pages, so the chip's own filters and sort decide the set. Sits at the
    -- top because it changes WHAT is selected, where every row below acts on
    -- the selection; closes the dialog so the newly selected covers are
    -- visible (reopen from the bucket to act on them).
    local select_all_button = {
        text = _("Select all in this shelf"),
        callback = function()
            UIManager:close(dialog)
            if bw and bw._selectAllInView then bw:_selectAllInView() end
        end,
    }


    -- The page (STYLE.md): what Apply will do in a sentence, then each
    -- staged change as the book popup's Edit tab shows it, then the actions
    -- that happen at once. Nothing is black until it is staged; tapping a
    -- staged choice again un-stages it.
    local STAR = "\xE2\x98\x85"   -- ★
    local function stars(n) return STAR:rep(n) end
    local function collectionsValue()
        local add, rem = 0, 0
        for _k in pairs(draft.collections_add or {}) do add = add + 1 end
        for _k in pairs(draft.collections_remove or {}) do rem = rem + 1 end
        if add == 0 and rem == 0 then return _("Leave as is") end
        -- Whole phrases, each with its noun, for the translators.
        local parts = {}
        if add > 0 then
            parts[#parts + 1] = add == 1 and _("Add to 1 collection") or T(_("Add to %1 collections"), add)
        end
        if rem > 0 then
            parts[#parts + 1] = rem == 1 and _("Remove from 1 collection") or T(_("Remove from %1 collections"), rem)
        end
        return table.concat(parts, ", ")
    end
    -- What Apply will do, one change a line: each a whole phrase, not
    -- "mark %s" filled with a lower-cased status, which broke languages
    -- whose nouns keep their capitals and could not be reordered.
    local STATUS_PHRASES = { new = _("Mark as Unopened"), reading = _("Mark as Reading"),
        abandoned = _("Mark as On hold"), complete = _("Mark as Finished") }
    local function summary()
        local parts = {}
        if draft.status then parts[#parts + 1] = STATUS_PHRASES[draft.status] end
        if draft.rating == nil then
            parts[#parts + 1] = _("Clear the rating")
        elseif draft.rating then
            parts[#parts + 1] = T(_("Rate %1"), stars(draft.rating))
        end
        if draft.favorite == "add" then parts[#parts + 1] = _("Add to Favorites")
        elseif draft.favorite == "remove" then parts[#parts + 1] = _("Remove from Favorites") end
        if draft.collections_add or draft.collections_remove then
            parts[#parts + 1] = _("Change collections")
        end
        if draft.refresh_metadata then parts[#parts + 1] = _("Refresh metadata") end
        if draft.remove_from_history then parts[#parts + 1] = _("Remove from history") end
        if #parts == 0 then return _("Pick what to change, then Apply.") end
        return T(_("Apply will:\n%1"), table.concat(parts, "\n"))
    end
    local function stage(field)
        return function(key)
            if field == "rating" then
                -- No key: the staged one tapped again, leave ratings as they are.
                if key == nil then draft.rating = false
                elseif key == "clear" then draft.rating = nil
                else draft.rating = tonumber(key) end
            else
                draft[field] = key
            end
            restage()
        end
    end
    local function ratingActive()
        if draft.rating == false then return nil end
        if draft.rating == nil then return "clear" end
        return tostring(draft.rating)
    end
    local function toggle(field)
        return function() draft[field] = not draft[field]; restage() end
    end

    local function page()
        local rating_items = {}
        -- "3 ★", not three stars: five stars do not fit a sixth of the line.
        for i = 1, 5 do rating_items[i] = { key = tostring(i), label = i .. " " .. STAR } end
        -- "Clear", not "None": beside nothing staged (leave the ratings as
        -- they are), None read as "no change".
        rating_items[6] = { key = "clear", label = _("Clear") }
        return {
            strip = {
                { type = "summary", text = summary() },
                { type = "chips", items = {
                    { text = select_all_button.text, icon = "\xEE\xA0\xB8", -- checkbox-multiple-marked-outline
                      callback = select_all_button.callback },
                } },
            },
            blocks = {
                { type = "heading", text = _("Reading status") },
                { type = "segmented", items = {
                    { key = "new",       label = _("Unopened") },
                    { key = "reading",   label = _("Reading") },
                    { key = "abandoned", label = _("On hold") },
                    { key = "complete",  label = _("Finished") },
                  }, active = draft.status, allow_none = true, on_pick = stage("status") },
                { type = "heading", text = _("Rating") },
                { type = "segmented", items = rating_items, active = ratingActive(),
                  allow_none = true, on_pick = stage("rating") },
                { type = "heading", text = _("Collections") },
                { type = "segmented", label = _("Favorite"), items = {
                    { key = "add",    label = _("Add") },
                    { key = "remove", label = _("Remove") },
                  }, active = draft.favorite, allow_none = true, on_pick = stage("favorite") },
                { type = "row", label = _("Collections"), value = collectionsValue(),
                  icon = "\u{E7BF}", -- bookmark (as the Collections filter)
                  on = (draft.collections_add or draft.collections_remove) and true or false,
                  callback = collections_button.callback },
                { type = "heading", text = _("Also on Apply") },
                { type = "chips", items = {
                    { text = _("Refresh metadata"), on = draft.refresh_metadata,
                      callback = toggle("refresh_metadata") },
                    { text = _("Remove from history"), on = draft.remove_from_history,
                      callback = toggle("remove_from_history") },
                } },
                { type = "heading", text = _("Right away") },
                { type = "chips", items = {
                    { text = move_button.text, callback = move_button.callback },
                    { text = reset_button.text, callback = reset_button.callback },
                    { text = _("Delete\xE2\x80\xA6"), callback = delete_button.callback },
                } },
            },
        }
    end

    dialog = require("lib/bookshelf_page_dialog").show{
        title    = _resolveLabel(count),
        page     = page,
        footer   = {
            { text = cancel_button.text, callback = cancel_button.callback },
            { text = apply_button.text, primary = true,
              enabled_func = apply_button.enabled_func, callback = apply_button.callback },
        },
        on_close = function() if on_done then on_done() end end,
    }
end

return BulkActions
