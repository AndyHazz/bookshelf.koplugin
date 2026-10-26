-- bookshelf_collection_manager.lua
-- Bookshelf-native replacement for KOReader's full-screen collection
-- picker (filemanagercollection:onShowCollList).
--
-- Built on the same LibraryModal as the shelf editor's "Specific
-- collection" picker, so the two look and behave alike: a two-column grid
-- of collections, paged, with a search row (issue 488: many collections
-- meant a lot of paging). A tap toggles in place and the grid refreshes
-- without closing.
--
-- Modes:
--   book given -> "tag this book" mode: a collection the book is in shows
--     selected. Taps change a draft; Cancel discards, Save commits via
--     ReadCollection:addRemoveItemMultiple + write().
--   bulk       -> the bulk selection menu: a tap cycles no change > add to
--     all > remove from all, against the selection. Save returns the diff
--     via on_save; nothing is written here.
--   neither    -> "manage" mode: a tap opens the collection's Edit menu.
--     Footer is Close (no draft to discard).
--
-- Long-press opens the Edit menu (Rename / Delete / Pin) in every mode.
-- Rename / Delete / Pin run instantly (with their own ConfirmBoxes) even
-- in book mode -- they affect global state across all books, so making
-- them part of a Save/Cancel draft would mean a rename pending Save
-- would have to be tracked by old name in the local toggle state. The
-- split matches user intuition: a toggle feels draftable, deleting a
-- collection should make you stop and read a confirmation.
--
-- The order is KOReader's collection order (the one Manage collections
-- rearranges), not the A to Z of the shelf editor's picker.

local ButtonDialog    = require("ui/widget/buttondialog")
local ConfirmBox      = require("ui/widget/confirmbox")
local InputDialog     = require("ui/widget/inputdialog")
local UIManager       = require("ui/uimanager")
local ReadCollection  = require("readcollection")
local Device          = require("device")
local Screen          = Device.screen

local _ = require("lib/bookshelf_i18n").gettext

local _ = require("lib/bookshelf_i18n").gettext

local CollectionManager = {}

-- "To Be Read" used to be protected when bookshelf had a dedicated
-- +TBR toggle button referencing the literal string. That button is
-- gone (membership is now managed through this manager), so the
-- collection can be renamed / deleted like any other custom one.
-- Favourites stays protected: its internal key "favorites" is wired
-- into KOReader's ReadCollection.default_collection_name and into
-- bookshelf's own favourites chip source -- renaming would orphan
-- both. Deletion is a wash because KOReader recreates an empty
-- "favorites" on next read, but rename would silently break the chip
-- until the user noticed.

-- Order-preserving list of collection names. ReadCollection.coll is a
-- hash table; coll_settings[name].order gives display order (favorites
-- = 1, then user-added collections in creation order). Sort ascending,
-- tie-break on name so two collections that happen to share an order
-- value don't shuffle around between renders.
local function _orderedNames()
    ReadCollection:_read()  -- pick up external mutations
    local names = {}
    -- Skip the built-in favourites collection: bookshelf treats it as a
    -- first-class special case with its own dedicated ★ button + cover
    -- badge. Showing it in the generic collections list would be a
    -- duplicate affordance for the same toggle, and the collection
    -- itself can't be renamed or deleted anyway.
    local default_name = ReadCollection.default_collection_name
    for name in pairs(ReadCollection.coll) do
        if name ~= default_name then
            names[#names + 1] = name
        end
    end
    table.sort(names, function(a, b)
        local oa = (ReadCollection.coll_settings[a] or {}).order or 0
        local ob = (ReadCollection.coll_settings[b] or {}).order or 0
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    return names
end

local function _countOf(name)
    local coll = ReadCollection.coll[name]
    if not coll then return 0 end
    local n = 0
    for _ in pairs(coll) do n = n + 1 end
    return n
end

-- Localised display name. ReadCollection stores the favourites
-- collection under the hard-coded key "favorites" (US spelling, never
-- visible to the user normally) -- KOReader's UI translates it to the
-- locale's Favourites/Favoritos/etc. on display. Match that here so
-- the row doesn't read as a raw internal key.
local function _displayName(name)
    if name == ReadCollection.default_collection_name then
        return _("Favorites")
    end
    return name
end

-- True if the user is allowed to rename / delete this collection.
-- Only the system favourites collection is protected -- see the
-- comment block at the top of this file for why TBR isn't on the
-- list any more.
local function _isProtected(name)
    return name == ReadCollection.default_collection_name
end

-- Pin-to-chip-bar. Mirrors _openGroupMenu's create_chip for kind="tag"
-- (source.kind="collection"). Lives here rather than reaching back into
-- bookshelf_widget so this module can be opened from settings too,
-- where no widget context exists -- the widget reference is optional.
local function _pinAsChip(coll_name, bw)
    local TabModel        = require("lib/bookshelf_tab_model")
    local BookshelfSet    = require("lib/bookshelf_settings_store")
    local Repo            = require("lib/bookshelf_book_repository")
    local tabs = TabModel.load()
    local n = 1
    while true do
        local cand = "custom_" .. n
        local taken = false
        for _i, t in ipairs(tabs) do
            if t.id == cand then taken = true; break end
        end
        if not taken then break end
        n = n + 1
    end
    local new_id = "custom_" .. n
    tabs[#tabs + 1] = {
        id            = new_id,
        label         = _displayName(coll_name),
        icon          = nil,
        source        = { kind = "collection", id = coll_name },
        filter        = {},
        -- The editor owns the per-source defaults; a second copy here is how
        -- a collection pinned from the manager ended up sorted differently
        -- from the same collection picked in the editor (issue 441).
        sort_priority = require("lib/bookshelf_chip_editor")
                            .sourceSortDefaults("collection"),
        enabled       = true,
    }
    TabModel.save(tabs)
    if bw then
        bw:_clearDpadFocus()
        bw._drilldown_path = {}
        bw.chip            = new_id
        bw._cursor         = 1
        bw:_syncPageFromCursor()
        BookshelfSet.save("active_chip", new_id)
        Repo.invalidateBookCache("create-chip")
        bw:_rebuild()
        UIManager:setDirty(bw, "ui")
    end
end

-- Public entry point. opts:
--   book      -- book record (with filepath/title/etc). Presence
--                switches the dialog into "tag this book" mode.
--   on_close  -- optional callback invoked once after the dialog closes,
--                however it was closed.
--   bw        -- optional BookshelfWidget reference for chip-pin side
--                effects.
--
--   bulk            -- when true, ignore `book`; operate on `paths`
--                      (array of filepaths). Cells become tri-state
--                      against the selection set. Save returns a diff
--                      via `on_save(diff)`; no ReadCollection writes.
--   paths           -- (bulk mode) array of filepaths to operate on.
--   initial_add     -- (bulk) `{[name]=true}` resume set: collection
--                      names already staged for add, so a return to the
--                      bulk menu still shows the prior diff.
--   initial_remove  -- (bulk) `{[name]=true}` resume set for staged
--                      remove.
--   on_save(diff)   -- (bulk) called with `{add = set|nil, remove =
--                      set|nil}`. Each side is the set of collection
--                      names whose membership should change; nil = "no
--                      change" on that side.
--   on_cancel       -- (bulk) called when the user taps Cancel. Diff is
--                      dropped.
function CollectionManager.show(opts)
    opts = opts or {}
    local book      = opts.book
    local bulk_mode = opts.bulk == true
    local book_mode = book ~= nil and not bulk_mode

    -- Draft membership. book_mode: `draft` is name -> true/false, from the
    -- book's current membership; mutated on tap, written on Save. bulk:
    -- `draft_add` / `draft_remove` are the collections STAGED to add to /
    -- remove from the selection; baseline membership is read per cell.
    local draft, draft_add, draft_remove = {}, {}, {}
    if book_mode then
        local current = ReadCollection:getCollectionsWithFile(book.filepath)
        local default_name = ReadCollection.default_collection_name
        for name in pairs(ReadCollection.coll) do
            -- Match _orderedNames: hide the built-in favourites collection
            -- from book-mode (dedicated ★ button handles it).
            if name ~= default_name then
                draft[name] = current[name] == true
            end
        end
    end
    if bulk_mode then
        for name in pairs(opts.initial_add or {}) do draft_add[name] = true end
        for name in pairs(opts.initial_remove or {}) do draft_remove[name] = true end
    end

    local modal  -- forward decl so callbacks can refresh / close it

    -- The collections shown: all of them in order, or those matching the
    -- search (case-insensitive, on the name shown).
    local names, query, visible = {}, nil, {}
    local function recompute()
        if not query or query == "" then visible = names; return end
        local q = query:lower()
        visible = {}
        for _i, name in ipairs(names) do
            if _displayName(name):lower():find(q, 1, true) then visible[#visible + 1] = name end
        end
    end
    local function reload()
        names = _orderedNames()
        recompute()
    end
    reload()
    local function refresh()
        if modal then modal:refresh() end
    end

    -- Baseline membership for a collection across the bulk selection:
    -- "all" | "some" | "none". Cached per name; dropped when collections
    -- change (reloadBaseline).
    local _baseline_cache = {}
    local function _baselineState(name)
        if _baseline_cache[name] then return _baseline_cache[name] end
        local state = "none"
        local paths = opts.paths or {}
        if #paths > 0 then
            local hits = 0
            for _i, fp in ipairs(paths) do
                if ReadCollection:isFileInCollection(fp, name) then hits = hits + 1 end
            end
            if hits == #paths then state = "all" elseif hits > 0 then state = "some" end
        end
        _baseline_cache[name] = state
        return state
    end

    -- Edit-collection 2x2 menu. Title spells out which collection
    -- you're editing ("Edit collection: To Be Read") so a long-pressed
    -- cell makes its target obvious. Rows:
    --   [ Rename       ] [ Pin to shelf menu ]
    --   [ ✕ Delete     ] [ Cancel          ]
    -- For the protected Favourites collection, the rename / delete
    -- actions collapse to a single Pin / Cancel row.
    local function holdMenu(coll_name)
        local hold_dialog
        local function hclose() UIManager:close(hold_dialog) end

        local can_modify = not _isProtected(coll_name)

        local function doRename()
            hclose()
            local input
            input = InputDialog:new{
                title       = _("Rename collection"),
                input       = coll_name,
                input_hint  = _("New name"),
                buttons = {{
                    { text = _("Cancel"), id = "close",
                      callback = function() UIManager:close(input) end },
                    { text = _("Rename"), is_enter_default = true,
                      callback = function()
                        local new_name = (input:getInputText() or "")
                            :gsub("^%s+", ""):gsub("%s+$", "")
                        if new_name == "" or new_name == coll_name then
                            UIManager:close(input); return
                        end
                        if ReadCollection.coll[new_name] then
                            UIManager:show(require("ui/widget/infomessage"):new{
                                text = _("A collection with that name already exists."),
                                timeout = 3,
                            })
                            return
                        end
                        ReadCollection:renameCollection(coll_name, new_name)
                        ReadCollection:write()
                        if draft[coll_name] ~= nil then
                            draft[new_name]  = draft[coll_name]
                            draft[coll_name] = nil
                        end
                        if draft_add[coll_name] then
                            draft_add[new_name]  = true
                            draft_add[coll_name] = nil
                        end
                        if draft_remove[coll_name] then
                            draft_remove[new_name]  = true
                            draft_remove[coll_name] = nil
                        end
                        _baseline_cache = {}
                        UIManager:close(input)
                        reload(); refresh()
                      end },
                }},
            }
            UIManager:show(input)
            input:onShowKeyboard()
        end

        local function doDelete()
            hclose()
            UIManager:show(ConfirmBox:new{
                text       = _("Delete collection \"") .. _displayName(coll_name)
                    .. _("\"? Books are not deleted, only the tag."),
                ok_text    = _("Delete"),
                ok_callback = function()
                    ReadCollection:removeCollection(coll_name)
                    ReadCollection:write()
                    draft[coll_name]        = nil
                    draft_add[coll_name]    = nil
                    draft_remove[coll_name] = nil
                    reload(); refresh()
                end,
            })
        end

        local function doPin()
            hclose()
            UIManager:close(modal)
            _pinAsChip(coll_name, opts.bw)
        end

        -- 2x2 grid in the editable case, 1x2 in the protected case.
        -- ✕ prefix on Delete matches the book menu's Delete button so
        -- the destructive cue reads the same across the plugin.
        local buttons
        if can_modify then
            buttons = {
                {
                    { text = _("Rename"),          callback = doRename },
                    { text = _("Pin to shelf menu"), callback = doPin    },
                },
                {
                    { text = "\xE2\x9C\x95 " .. _("Delete"),
                      callback = doDelete },
                    { text = _("Cancel"),          callback = hclose },
                },
            }
        else
            buttons = {
                {
                    { text = _("Pin to shelf menu"), callback = doPin    },
                    { text = _("Cancel"),          callback = hclose   },
                },
            }
        end

        hold_dialog = ButtonDialog:new{
            title          = _("Edit collection: ") .. _displayName(coll_name),
            title_align    = "center",
            use_info_style = false,
            width          = math.floor(Screen:getWidth() * 0.7),
            buttons        = buttons,
        }
        UIManager:show(hold_dialog)
    end

    -- + New collection: instant create + auto-tick (in book and bulk
    -- mode) so the new collection is part of the draft immediately.
    -- Instant rather than drafted because a draft toggle on a not-yet-
    -- existing collection has nowhere to live.
    local function newCollection()
        local input
        input = InputDialog:new{
            title       = _("New collection"),
            -- "Collection name", not a bare "Name". That msgid was shared
            -- with the group-order sort label, where it means a PERSON's name
            -- on the Authors shelf -- and a language that distinguishes the
            -- two can only render one of them (Slovak: meno for a person,
            -- nazov for a thing; Czech, Polish, Russian, Ukrainian and German
            -- split the same way). Reported by the Slovak translator, who
            -- could see it from the catalogue but not fix it there (issue
            -- 432). Naming what is being named also reads better here.
            input_hint  = _("Collection name"),
            buttons = {{
                { text = _("Cancel"), id = "close",
                  callback = function() UIManager:close(input) end },
                { text = _("Create"), is_enter_default = true,
                  callback = function()
                    local name = (input:getInputText() or "")
                        :gsub("^%s+", ""):gsub("%s+$", "")
                    if name == "" then UIManager:close(input); return end
                    if ReadCollection.coll[name] then
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = _("A collection with that name already exists."),
                            timeout = 3,
                        })
                        return
                    end
                    ReadCollection:addCollection(name)
                    ReadCollection:write()
                    if book_mode then
                        draft[name] = true
                    elseif bulk_mode then
                        draft_add[name]    = true
                        draft_remove[name] = nil
                    end
                    UIManager:close(input)
                    -- Clear the search so the new collection is in view.
                    query = nil
                    if modal then modal.search_query = nil; modal.page = 1 end
                    reload(); refresh()
                  end },
            }},
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end

    -- A tap: book mode toggles the draft; bulk cycles no change > add to
    -- all > remove from all; manage opens the Edit menu.
    local function onTap(name)
        if book_mode then
            draft[name] = not draft[name]
        elseif bulk_mode then
            if draft_add[name] then
                draft_add[name]    = nil
                draft_remove[name] = true
            elseif draft_remove[name] then
                draft_remove[name] = nil
            else
                draft_add[name]    = true
            end
        else
            holdMenu(name)
            return
        end
        refresh()
    end

    -- A cell, through the shared PickerCell (the same cell every picker
    -- draws). Selected = inverted: the book is in it (book mode), or the
    -- selection will all be in it (bulk). A staged remove is tinted grey;
    -- bulk's staged action or a mixed baseline replaces the book count.
    local PickerCell = require("lib/bookshelf_picker_cell")
    local function renderCell(name, dimen)
        local selected, tint, subtitle = false, false, nil
        if book_mode then
            selected = draft[name] == true
        elseif bulk_mode then
            local baseline = _baselineState(name)
            local effective = baseline
            if draft_add[name] then effective = "all"
            elseif draft_remove[name] then effective = "none" end
            selected = effective == "all"
            tint = draft_remove[name] == true
            if draft_add[name] then
                subtitle = _("Add to all") .. " +"
            elseif draft_remove[name] then
                subtitle = _("Remove from all") .. " \xE2\x88\x92"  -- −
            elseif baseline == "some" then
                subtitle = _("Mixed")
            end
        end
        return PickerCell.render({
            label    = _displayName(name),
            subtitle = subtitle,
            count    = subtitle == nil and _countOf(name) or nil,
        }, dimen, { selected = selected, tint = tint })
    end

    local function save()
        if book_mode then
            -- Convert draft -> the set ReadCollection wants:
            -- collections_to_add = { name = true, ... } with names the book
            -- SHOULD be in. addRemoveItemMultiple iterates ALL collections
            -- and adds/removes accordingly.
            local target = {}
            for name, on in pairs(draft) do
                if on then target[name] = true end
            end
            -- Favourites is never in `draft` (excluded above -- its own
            -- ★ button owns that toggle), but addRemoveItemMultiple
            -- removes membership from every collection absent from
            -- `target`. Preserve its current state exactly, or Save here
            -- would silently un-favourite the book.
            local default_name = ReadCollection.default_collection_name
            if ReadCollection:getCollectionsWithFile(book.filepath)[default_name] then
                target[default_name] = true
            end
            ReadCollection:addRemoveItemMultiple(book.filepath, target)
            ReadCollection:write()
            UIManager:close(modal)
        else
            -- nil-vs-empty matters: the bulk menu's draft uses nil to mean
            -- "no change staged", so an empty set collapses to nil.
            local diff = { add = nil, remove = nil }
            if next(draft_add)    then diff.add    = draft_add    end
            if next(draft_remove) then diff.remove = draft_remove end
            UIManager:close(modal)
            if opts.on_save then opts.on_save(diff) end
        end
    end

    -- Footer: + New collection on its own row above Cancel/Save so the
    -- discard / commit pair stays paired at the bottom. Manage mode has
    -- nothing to discard: + New collection sits beside Close.
    local footer_rows
    if book_mode or bulk_mode then
        footer_rows = {
            { { label = "+ " .. _("New collection"), on_tap = newCollection } },
            {
                { label = _("Cancel"), on_tap = function()
                    UIManager:close(modal)
                    if bulk_mode and opts.on_cancel then opts.on_cancel() end
                end },
                { label = _("Save"), primary = true, on_tap = save },
            },
        }
    else
        footer_rows = {
            {
                { label = "+ " .. _("New collection"), on_tap = newCollection },
                { label = _("Close"), on_tap = function() UIManager:close(modal) end },
            },
        }
    end

    local title, intro
    if bulk_mode then
        title = string.format(_("Collections \xC2\xB7 %d books"), opts.paths and #opts.paths or 0)
        intro = _("Tap a collection to cycle through: no change, "
            .. "add to all, remove from all. Save returns the diff "
            .. "to the bulk menu.")
    elseif book_mode then
        title = _("Edit collections")
    else
        title = _("Manage collections")
        intro = _("Tap a custom collection to rename, delete, or pin "
            .. "it to the shelf menu. Long-press a book on the shelf "
            .. "and tap Collections… to add or remove it from "
            .. "collections.")
    end

    local LibraryModal = require("lib/bookshelf_library_modal")
    modal = LibraryModal:new{ config = {
        title              = title,
        intro              = intro,
        search_placeholder = function() return _("Search\xE2\x80\xA6") end,
        on_search_submit   = function(q)
            query = q
            recompute()
            modal.page = 1
            refresh()
        end,
        -- Same grid as the shelf editor's pickers: 2 columns, 5 rows
        -- portrait, 4 landscape.
        grid_cols      = 2,
        cells_per_page = function()
            return Screen:getWidth() > Screen:getHeight() and 8 or 10
        end,
        item_count     = function() return #visible end,
        item_at        = function(idx) return visible[idx] end,
        cell_renderer  = function(name, dimen) return renderCell(name, dimen) end,
        on_cell_tap    = onTap,
        cell_long_tap  = holdMenu,
        footer_rows    = footer_rows,
        on_closed      = function()
            if opts.on_close then opts.on_close() end
        end,
    } }
    UIManager:show(modal)
end

return CollectionManager
