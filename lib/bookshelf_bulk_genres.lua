-- lib/bookshelf_bulk_genres.lua
-- Bulk genre editing for the bulk-edit menu. Stages genres to add to / remove
-- from every selected book, the same tri-state model the bulk Collections
-- editor uses; the bulk menu's Apply commits the diff through
-- Repo.setEmbeddedGenres (the KOReader Keywords override the single-book
-- editor writes), so both paths edit the same field.
--
-- Diff shape: { add = { [lowercase] = "Name" }, remove = { [lowercase] = "Name" } }
-- Keys are lowercase because genres match case-insensitively everywhere else.

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

-- Apply a diff to `paths`. Reads every book's current list BEFORE the first
-- write: each write invalidates the light-meta cache, so a read after it would
-- rebuild the cache per book. Returns applied, failed counts.
function BulkGenres.applyTo(paths, diff, Repo)
    Repo = Repo or require("lib/bookshelf_book_repository")
    local plan = {}
    for _i, fp in ipairs(paths) do
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
    local add, remove = {}, {}
    for k, v in pairs(opts.initial_add or {}) do add[k] = v end
    for k, v in pairs(opts.initial_remove or {}) do remove[k] = v end

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
    local function sortChoices()
        table.sort(choices, function(a, b) return a.label:lower() < b.label:lower() end)
    end
    sortChoices()

    local query, visible = nil, choices
    local function recompute()
        if not query or query == "" then visible = choices; return end
        visible = {}
        for _i, c in ipairs(choices) do
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
                        addChoice(v)
                        remove[v:lower()] = nil
                        add[v:lower()] = v
                        sortChoices(); recompute()
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
        if opts.on_save then opts.on_save(has and { add = add, remove = remove } or nil) end
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
