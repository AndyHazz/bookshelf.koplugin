-- lib/bookshelf_bulk_genres.lua
-- Bulk genre editing for the bulk-edit menu. Stages genres to add to / remove
-- from every selected book, the same tri-state model the bulk Collections
-- editor uses; the bulk menu's Apply commits the diff through
-- Repo.setEmbeddedGenres (the KOReader Keywords override the single-book
-- editor writes), so both paths edit the same field.
--
-- Diff shape: { add = { [lowercase] = "Name" }, remove = { [lowercase] = "Name" } }
-- Keys are lowercase because genres match case-insensitively everywhere else.
--
-- The diff can also carry `hide` / `unhide` (same map shape): Hardcover genres
-- to hide on, or bring back to, every selected book that has them. Those go to
-- the per-book exclusion lists (lib/bookshelf_genre_filter), not the file.

local BulkGenres = {}

-- Pure: the genre list a book ends up with. Removal runs before add, existing
-- tags keep their order and spelling, new ones append sorted. `current` is an
-- array of strings (or nil); add / remove are the maps above (or nil).
function BulkGenres.merge(current, add, remove)
    local out, seen = {}, {}
    for _i, g in ipairs(current or {}) do
        local k = g:lower()
        if not (remove and remove[k]) and not seen[k] then
            seen[k] = true
            out[#out + 1] = g
        end
    end
    if add then
        local fresh = {}
        for k, name in pairs(add) do
            if not seen[k] then fresh[#fresh + 1] = name end
        end
        table.sort(fresh, function(a, b) return a:lower() < b:lower() end)
        for _i, name in ipairs(fresh) do out[#out + 1] = name end
    end
    return out
end

-- Pure: do two genre lists differ (as ordered lists)? Lets Apply skip writes
-- (and their cache invalidation) for books the diff doesn't change.
function BulkGenres.changed(before, after)
    before = before or {}
    if #before ~= #after then return true end
    for i = 1, #after do
        if before[i] ~= after[i] then return true end
    end
    return false
end

-- Pure: the per-book exclusion lists a hide / unhide diff leads to. Returns
-- { [filepath] = new list } for the books that actually change.
--   candidates(fp) -> the Hardcover tags the book could show (cleanup rules
--                     applied, per-book hiding not): a hide only lands on a
--                     book that has the tag.
--   excluded(fp)   -> the book's current hidden list.
--   raw(fp)        -> optional: the tags as Hardcover names them, so a tag typed
--                     by its original name still matches when an alias renames it.
function BulkGenres.hideUpdates(paths, diff, candidates, excluded, raw)
    local GF = require("lib/bookshelf_genre_filter")
    local updates = {}
    for _i, fp in ipairs(paths) do
        local cur = excluded(fp) or {}
        local new = cur
        if diff.hide and next(diff.hide) then
            local has = {}
            for _j, t in ipairs(candidates(fp) or {}) do has[t:lower()] = true end
            for _j, t in ipairs(raw and raw(fp) or {}) do has[t:lower()] = true end
            local names = {}
            for k, name in pairs(diff.hide) do
                if has[k] then names[#names + 1] = name end
            end
            table.sort(names, function(a, b) return a:lower() < b:lower() end)
            for _j, name in ipairs(names) do new = GF.listAdd(new, name) or new end
        end
        for _k, name in pairs(diff.unhide or {}) do new = GF.listRemove(new, name) or new end
        if BulkGenres.changed(cur, new) then updates[fp] = new end
    end
    return updates
end

-- Hardcover tags `fp` could show, using the saved blocklist and aliases.
function BulkGenres.hardcoverCandidates(rules)
    local GF = require("lib/bookshelf_genre_filter")
    local HC = require("lib/bookshelf_hardcover")
    return function(fp) return GF.filter(HC.rawGenres(fp) or {}, rules) end
end

function BulkGenres.cleanupRules()
    local GF = require("lib/bookshelf_genre_filter")
    return { blocklist = GF.blocklist(), aliases = GF.aliases() }
end

-- Apply a diff to `paths`. Reads every book's current list BEFORE the first
-- write: each write invalidates the light-meta cache, so a read after it would
-- rebuild the cache per book. Returns applied, failed counts.
function BulkGenres.applyTo(paths, diff, Repo)
    Repo = Repo or require("lib/bookshelf_book_repository")
    local plan = {}
    local edits = (diff.add and next(diff.add)) or (diff.remove and next(diff.remove))
    for _i, fp in ipairs(edits and paths or {}) do
        local lm = Repo.lightMetaFor(fp)
        local cur = lm and lm.genre_sources and lm.genre_sources.embedded or {}
        local new = BulkGenres.merge(cur, diff.add, diff.remove)
        if BulkGenres.changed(cur, new) then plan[#plan + 1] = { fp = fp, list = new } end
    end
    local applied, failed = 0, 0
    for _i, p in ipairs(plan) do
        if pcall(Repo.setEmbeddedGenres, p.fp, p.list) then
            applied = applied + 1
        else
            failed = failed + 1
        end
    end
    -- Hardcover hide / unhide: one settings write for the whole selection.
    if (diff.hide and next(diff.hide)) or (diff.unhide and next(diff.unhide)) then
        local GF = require("lib/bookshelf_genre_filter")
        local updates = BulkGenres.hideUpdates(paths, diff,
            BulkGenres.hardcoverCandidates(BulkGenres.cleanupRules()), GF.excludedFor,
            function(fp) return require("lib/bookshelf_hardcover").rawGenres(fp) end)
        if next(updates) then
            if pcall(GF.setExcludedMany, updates) then
                for _fp in pairs(updates) do applied = applied + 1 end
                if Repo.invalidateLightMeta then Repo.invalidateLightMeta() end
            else
                for _fp in pairs(updates) do failed = failed + 1 end
            end
        end
    end
    return applied, failed
end

-- opts: paths, initial_add, initial_remove, on_save(diff|nil)
-- Cell tap cycles: no change -> add to all -> remove from all -> no change.
-- Cells show how many selected books already carry the genre.
function BulkGenres.show(opts)
    local _ = require("lib/bookshelf_i18n").gettext
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local Repo = require("lib/bookshelf_book_repository")
    local LibraryModal = require("lib/bookshelf_library_modal")
    local PickerCell = require("lib/bookshelf_picker_cell")

    local paths = opts.paths or {}
    local add, remove, hide, unhide = {}, {}, {}, {}
    for k, v in pairs(opts.initial_add or {}) do add[k] = v end
    for k, v in pairs(opts.initial_remove or {}) do remove[k] = v end
    for k, v in pairs(opts.initial_hide or {}) do hide[k] = v end
    for k, v in pairs(opts.initial_unhide or {}) do unhide[k] = v end
    -- "embedded": edit the files' own genres. "hardcover": hide / bring back
    -- Hardcover's genres on the selected books.
    local mode = "embedded"

    -- How many selected books carry each genre now, and the choice list:
    -- library genres plus anything the selection or the draft already names.
    local held, choices, seen = {}, {}, {}
    local function addChoice(name, count)
        if not name or name == "" then return end
        local k = name:lower()
        if seen[k] then return end
        seen[k] = true
        choices[#choices + 1] = { value = name, label = name, count = count }
    end
    for _i, fp in ipairs(paths) do
        local lm = Repo.lightMetaFor(fp)
        for _j, g in ipairs(lm and lm.genre_sources and lm.genre_sources.embedded or {}) do
            held[g:lower()] = (held[g:lower()] or 0) + 1
            addChoice(g)
        end
    end
    for _k, name in pairs(add) do addChoice(name) end
    for _i, c in ipairs(Repo.getGroupChoices and Repo.getGroupChoices("genre") or {}) do
        addChoice(c.value, c.count)
    end
    local function sortList(list)
        table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    end
    local function sortChoices() sortList(choices) end
    sortChoices()

    -- Hardcover side: the tags the selection could show (blocklist and aliases
    -- applied), and per tag how many books show it / have it hidden.
    local hc_choices, hc_seen, hc_shown, hc_hidden = {}, {}, {}, {}
    do
        local candidates = BulkGenres.hardcoverCandidates(BulkGenres.cleanupRules())
        local excluded = require("lib/bookshelf_genre_filter").excludedFor
        for _i, fp in ipairs(paths) do
            local ex = {}
            for _j, t in ipairs(excluded(fp)) do ex[t:lower()] = true end
            for _j, t in ipairs(candidates(fp)) do
                local k = t:lower()
                if not hc_seen[k] then
                    hc_seen[k] = true
                    hc_choices[#hc_choices + 1] = { value = t, label = t }
                end
                if ex[k] then hc_hidden[k] = (hc_hidden[k] or 0) + 1
                else hc_shown[k] = (hc_shown[k] or 0) + 1 end
            end
            -- A tag hidden here no longer appears in the candidates' effective
            -- list but must stay offered, to bring it back.
            for _j, t in ipairs(excluded(fp)) do
                local k = t:lower()
                if not hc_seen[k] then
                    hc_seen[k] = true
                    hc_choices[#hc_choices + 1] = { value = t, label = t }
                    hc_hidden[k] = (hc_hidden[k] or 0) + 1
                end
            end
        end
        sortList(hc_choices)
    end

    local query, visible = nil, choices
    local function recompute()
        local list = (mode == "hardcover") and hc_choices or choices
        if not query or query == "" then visible = list; return end
        visible = {}
        for _i, c in ipairs(list) do
            if c.label:lower():find(query:lower(), 1, true) then visible[#visible + 1] = c end
        end
    end

    local modal
    local function promptNewTag()
        local InputDialog = require("ui/widget/inputdialog")
        local idlg
        idlg = InputDialog:new{
            title = _("New tag"), input = "",
            buttons = {{
                { text = _("Cancel"), id = "close",
                  callback = function() UIManager:close(idlg) end },
                { text = _("Add"), is_enter_default = true,
                  callback = function()
                    local v = (idlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(idlg)
                    if v ~= "" then
                        if mode == "hardcover" then
                            -- Name a Hardcover tag to hide on the books that have it.
                            if not hc_seen[v:lower()] then
                                hc_seen[v:lower()] = true
                                hc_choices[#hc_choices + 1] = { value = v, label = v }
                                sortList(hc_choices)
                            end
                            unhide[v:lower()] = nil
                            hide[v:lower()] = v
                        else
                            addChoice(v)
                            remove[v:lower()] = nil
                            add[v:lower()] = v
                            sortChoices()
                        end
                        recompute()
                        if modal then modal.page = 1; modal:refresh() end
                    end
                  end },
            }},
        }
        UIManager:show(idlg)
        idlg:onShowKeyboard()
    end

    local function commit()
        UIManager:close(modal)
        local has = next(add) ~= nil or next(remove) ~= nil
            or next(hide) ~= nil or next(unhide) ~= nil
        if opts.on_save then
            opts.on_save(has and { add = add, remove = remove, hide = hide, unhide = unhide } or nil)
        end
    end

    modal = LibraryModal:new{ config = {
        title = _("Edit genres"),
        search_placeholder = function() return _("Search\xE2\x80\xA6") end,
        on_search_submit = function(q)
            query = q; recompute()
            if modal then modal.page = 1; modal:refresh() end
        end,
        grid_cols = 2,
        cells_per_page = function()
            return Screen:getWidth() > Screen:getHeight() and 8 or 10
        end,
        item_count = function() return #visible end,
        item_at = function(idx) return visible[idx] end,
        cell_renderer = function(item, dimen)
            local k = item.value:lower()
            if mode == "hardcover" then
                local shown, hid = hc_shown[k] or 0, hc_hidden[k] or 0
                local sub
                if hide[k] then
                    sub = _("Hide on all") .. " \xE2\x88\x92"
                elseif unhide[k] then
                    sub = _("Show on all") .. " +"
                elseif hid > 0 then
                    sub = string.format(_("%d shown, %d hidden"), shown, hid)
                else
                    sub = (shown == #paths) and _("All") or string.format("%d/%d", shown, #paths)
                end
                return PickerCell.render({ label = item.label, subtitle = sub }, dimen,
                    { selected = unhide[k] ~= nil, tint = hide[k] ~= nil })
            end
            local n = held[k] or 0
            local subtitle
            if add[k] then
                subtitle = _("Add to all") .. " +"
            elseif remove[k] then
                subtitle = _("Remove from all") .. " \xE2\x88\x92"
            elseif n > 0 then
                subtitle = (n == #paths) and _("All") or string.format("%d/%d", n, #paths)
            end
            return PickerCell.render(
                { label = item.label, subtitle = subtitle }, dimen,
                { selected = add[k] ~= nil, tint = remove[k] ~= nil })
        end,
        on_cell_tap = function(item)
            local k = item.value:lower()
            if mode == "hardcover" then
                -- none -> hide -> show again (only offered where something is
                -- hidden) -> none
                if hide[k] then
                    hide[k] = nil
                    if (hc_hidden[k] or 0) > 0 then unhide[k] = item.value end
                elseif unhide[k] then
                    unhide[k] = nil
                else
                    hide[k] = item.value
                end
                if modal then modal:refresh() end
                return
            end
            if add[k] then
                add[k] = nil; remove[k] = item.value
            elseif remove[k] then
                remove[k] = nil
            else
                add[k] = item.value
            end
            if modal then modal:refresh() end
        end,
        footer_rows = {
            {
                { label_func = function()
                    return (mode == "hardcover") and _("Editing: Hardcover genres (hide)")
                        or _("Editing: the books' own genres")
                  end,
                  on_tap = function()
                    mode = (mode == "hardcover") and "embedded" or "hardcover"
                    recompute()
                    if modal then modal.page = 1; modal:refresh() end
                  end },
            },
            { { label = "+ " .. _("New tag"), on_tap = promptNewTag } },
            {
                { label = _("Cancel"), on_tap = function() UIManager:close(modal) end },
                { label = _("Save"), primary = true, on_tap = commit },
            },
        },
    } }
    UIManager:show(modal)
end

return BulkGenres
