-- bookshelf_collection_manager.lua
-- Bookshelf-native replacement for KOReader's full-screen collection
-- picker (filemanagercollection:onShowCollList). The stock picker is
-- a Menu widget: full-screen for any number of collections, no per-row
-- state shown, no book context in the header, no in-place rename /
-- delete / pin actions.
--
-- This widget is a ButtonDialog: dialog height tracks content, so a
-- typical user with 3-5 collections gets a compact modal rather than a
-- mostly-empty full-screen list. Rows are laid out two per line to keep
-- the dialog short on a typical e-ink screen. Each row supports tap
-- (toggle membership) and hold (per-row "Edit collection" 2x2 menu).
--
-- Modes:
--   book given -> "tag this book" mode: rows show ▢ / ▢✓ checkboxes
--     against a draft set; Cancel discards, Save commits via
--     ReadCollection:addRemoveItemMultiple + write(). Header reuses
--     the book menu's _buildBookMenuHeader for visual continuity.
--   book nil   -> "manage" mode: no checkboxes, just collection names +
--     counts. Rename / Delete / Pin live on the hold menu. Footer is
--     Close (no draft to discard).
--
-- Rename / Delete / Pin run instantly (with their own ConfirmBoxes) even
-- in book mode -- they affect global state across all books, so making
-- them part of a Save/Cancel draft would mean a rename pending Save
-- would have to be tracked by old name in the local toggle state. The
-- split matches user intuition: a checkbox feels draftable, deleting a
-- collection should make you stop and read a confirmation.
--
-- Semi-built-in collections (Favourites, "To Be Read") are protected
-- from rename / delete because other parts of bookshelf reference them
-- by their literal collection-name string (the book menu's Favourites
-- / To Be Read toggle buttons). A rename would orphan those buttons
-- and a tap would try to addItem on a non-existent collection ->
-- nil-index panic in ReadCollection:addItem.

local ButtonDialog    = require("ui/widget/buttondialog")
local ConfirmBox      = require("ui/widget/confirmbox")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local InputDialog     = require("ui/widget/inputdialog")
local LineWidget      = require("ui/widget/linewidget")
local Blitbuffer      = require("ffi/blitbuffer")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local ReadCollection  = require("readcollection")
local Font            = require("ui/font")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Device          = require("device")
local Screen          = Device.screen

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
        return _("Favourites")
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
        sort_priority = { { key = "last_opened", reverse = true } },
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
--   on_close  -- optional callback invoked after the dialog closes.
--   bw        -- optional BookshelfWidget reference for chip-pin side
--                effects + reusing _buildBookMenuHeader.
--
--   bulk            -- when true, ignore `book`; operate on `paths`
--                      (array of filepaths). Cells become tri-state
--                      against the selection set. Save returns a diff
--                      via `on_save(diff)`; no ReadCollection writes.
--   paths           -- (bulk mode) array of filepaths to operate on.
--   stage_only      -- (single-book) skip persistence; Save returns
--                      a `{add, remove}` diff via `on_save(diff)` so
--                      the per-book menu can fold the change into its
--                      outer stage-and-apply draft.
--   initial_add     -- (bulk + stage_only) `{[name]=true}` resume set:
--                      collection names already staged for add. Used
--                      by the per-book menu's reopen flow so a return
--                      from Cancel / Save still shows the prior diff.
--   initial_remove  -- (bulk + stage_only) `{[name]=true}` resume set
--                      for staged remove.
--   on_save(diff)   -- (bulk + stage_only) called with
--                      `{add = set|nil, remove = set|nil}`. Each side
--                      is the set of collection names whose membership
--                      should change; nil = "no change" on that side.
--   on_cancel       -- (bulk + stage_only) called when the user taps
--                      Cancel. Diff is dropped.
function CollectionManager.show(opts)
    opts = opts or {}
    local book      = opts.book
    -- Mode flags. `bulk_mode` ignores `book` entirely. `stage_only`
    -- requires `book` and behaves like book_mode except Save returns
    -- a diff via on_save instead of writing through to ReadCollection.
    -- book_mode (the existing single-book-persist path) is unchanged
    -- when neither bulk nor stage_only is set.
    local bulk_mode  = opts.bulk == true
    local stage_only = opts.stage_only == true and book ~= nil and not bulk_mode
    local book_mode  = book ~= nil and not bulk_mode and not stage_only

    -- Width / layout constants. Match the book menu's ButtonDialog
    -- (default width_factor = 0.9 of min(W, H)) so the manager sits at
    -- the same width as the book modal it sprang from -- visual
    -- continuity, no jarring rescaling. Inner content width subtracts
    -- ButtonDialog's own chrome (window border + button-padding * 2)
    -- and the title-group's padding/margin so the header + rows fit
    -- inside the title_group_width.
    local sw           = Screen:getWidth()
    local sh           = Screen:getHeight()
    local dialog_w     = math.floor(math.min(sw, sh) * 0.9)
    local content_w    = dialog_w - 2 * Size.border.window - 2 * Size.padding.button
    local inner_w      = content_w - 2 * (Size.padding.large + Size.margin.title)
    -- Visible gap between the two columns -- "large" (the standard
    -- inter-element gap in KOReader) rather than ButtonTable's
    -- shared-edge zero-gap, so the cells read as distinct items.
    local cell_gap     = Size.padding.large
    local cell_w       = math.floor((inner_w - cell_gap) / 2)

    -- Draft membership set: name -> true/false. Pre-populated from
    -- current membership so the first paint shows accurate checkboxes;
    -- mutated locally on tap; written to disk on Save. We never mutate
    -- ReadCollection.coll until Save fires.
    --
    -- book_mode (persist) uses `draft` as a single membership hash.
    -- bulk / stage_only modes use `draft_add` + `draft_remove` instead:
    -- each is a `{[name]=true}` set of collections the user has STAGED
    -- to add to / remove from the operating set (selection for bulk,
    -- single book for stage_only). Baseline membership is computed
    -- per-cell from ReadCollection so the staged diff layers ON TOP of
    -- whatever the live state is at paint time -- no need to
    -- pre-populate from current membership the way book_mode does.
    local draft        = {}
    local draft_add    = {}
    local draft_remove = {}
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
    if bulk_mode or stage_only then
        if opts.initial_add then
            for name in pairs(opts.initial_add) do draft_add[name] = true end
        end
        if opts.initial_remove then
            for name in pairs(opts.initial_remove) do draft_remove[name] = true end
        end
    end
    -- Internal hand-off so rebuild() preserves in-progress checkbox
    -- state across the close + reopen cycle. Each mode preserves its
    -- own draft shape: book_mode carries `_draft`, bulk/stage_only
    -- carry `_draft_add` + `_draft_remove`.
    if opts._draft then
        for k, v in pairs(opts._draft) do draft[k] = v end
    end
    if opts._draft_add then
        for k, v in pairs(opts._draft_add) do draft_add[k] = v end
    end
    if opts._draft_remove then
        for k, v in pairs(opts._draft_remove) do draft_remove[k] = v end
    end

    local dialog  -- forward decl so callbacks can close + reopen

    local function close()
        UIManager:close(dialog)
    end

    -- Pagination state. `page` is the 1-indexed current cell page.
    -- Survives rebuild() so a tap doesn't bounce the user back to
    -- page 1 mid-edit.
    local cur_page = opts._page or 1

    local function rebuild()
        close()
        CollectionManager.show{
            book           = book,
            on_close       = opts.on_close,
            bw             = opts.bw,
            bulk           = bulk_mode or nil,
            paths          = opts.paths,
            stage_only     = stage_only or nil,
            on_save        = opts.on_save,
            on_cancel      = opts.on_cancel,
            _draft         = book_mode and draft or nil,
            _draft_add     = (bulk_mode or stage_only) and draft_add or nil,
            _draft_remove  = (bulk_mode or stage_only) and draft_remove or nil,
            _page          = cur_page,
        }
    end

    -- Edit-collection 2x2 menu. Title spells out which collection
    -- you're editing ("Edit collection: To Be Read") so a long-pressed
    -- row makes its target obvious. Rows:
    --   [ Rename       ] [ Pin to chip bar ]
    --   [ ✕ Delete     ] [ Cancel          ]
    -- For protected collections (Favourites, To Be Read), the rename /
    -- delete actions collapse to a single Pin / Cancel row -- the
    -- protected collections back bookshelf's built-in toggle buttons
    -- and would crash those buttons if renamed.
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
                        UIManager:close(input)
                        rebuild()
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
                    rebuild()
                end,
            })
        end

        local function doPin()
            hclose()
            close()
            _pinAsChip(coll_name, opts.bw)
            if opts.on_close then opts.on_close() end
        end

        -- 2x2 grid in the editable case, 1x2 in the protected case.
        -- ✕ prefix on Delete matches the book menu's Delete button so
        -- the destructive cue reads the same across the plugin.
        local buttons
        if can_modify then
            buttons = {
                {
                    { text = _("Rename"),          callback = doRename },
                    { text = _("Pin to chip bar"), callback = doPin    },
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
                    { text = _("Pin to chip bar"), callback = doPin    },
                    { text = _("Cancel"),          callback = hclose   },
                },
            }
        end

        hold_dialog = ButtonDialog:new{
            title          = _("Edit collection: ") .. _displayName(coll_name),
            title_align    = "center",
            use_info_style = false,
            width          = math.floor(sw * 0.7),
            buttons        = buttons,
        }
        UIManager:show(hold_dialog)
    end

    -- + New collection: instant create + auto-tick (in book mode) so
    -- the new collection becomes part of this book's draft immediately.
    -- Instant rather than drafted because a draft toggle on a not-yet-
    -- existing collection has nowhere to live.
    local function newCollection()
        local input
        input = InputDialog:new{
            title       = _("New collection"),
            input_hint  = _("Name"),
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
                    -- Auto-tick the new collection in whatever editing
                    -- mode we're in. book_mode = persisted membership;
                    -- bulk + stage_only = stage an add diff so Save will
                    -- propagate it.
                    if book_mode then
                        draft[name] = true
                    elseif bulk_mode or stage_only then
                        draft_add[name]    = true
                        draft_remove[name] = nil
                    end
                    UIManager:close(input)
                    rebuild()
                  end },
            }},
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end

    -- Footer rows.
    -- Book mode: + New collection on its own row above Cancel/Save so
    -- the discard / commit pair stays visually paired at the bottom.
    -- Manage mode: + New collection sits beside Close on a single row
    -- because there's nothing destructive to pair Close with -- one
    -- compact action bar reads as the natural floor of the dialog.
    local buttons = {}
    if bulk_mode or stage_only then
        -- Stage-and-return path. Save emits the {add, remove} diff via
        -- on_save; Cancel discards via on_cancel. on_close (if any)
        -- runs in BOTH branches as a "dialog finished" hook.
        buttons[#buttons + 1] = {
            { text = "+ " .. _("New collection"), callback = newCollection },
        }
        buttons[#buttons + 1] = {
            { text = _("Cancel"), callback = function()
                close()
                if opts.on_cancel then opts.on_cancel() end
                if opts.on_close then opts.on_close() end
            end },
            { text = _("Save"), is_enter_default = true,
              callback = function()
                -- Pack the staged sets into the diff shape consumers
                -- expect: nil-vs-empty distinction matters because the
                -- outer draft uses `nil` to mean "no change staged"
                -- and any non-nil table (even empty) reads as "user
                -- went here". So we collapse empty -> nil.
                local diff = { add = nil, remove = nil }
                if next(draft_add)    then diff.add    = draft_add    end
                if next(draft_remove) then diff.remove = draft_remove end
                close()
                if opts.on_save then opts.on_save(diff) end
                if opts.on_close then opts.on_close() end
              end },
        }
    elseif book_mode then
        buttons[#buttons + 1] = {
            { text = "+ " .. _("New collection"), callback = newCollection },
        }
        buttons[#buttons + 1] = {
            { text = _("Cancel"), callback = function()
                close()
                if opts.on_close then opts.on_close() end
            end },
            { text = _("Save"), is_enter_default = true,
              callback = function()
                -- Convert draft -> the set ReadCollection wants:
                -- collections_to_add = { name = true, ... } with names
                -- the book SHOULD be in. addRemoveItemMultiple iterates
                -- ALL collections and adds/removes accordingly.
                local target = {}
                for name, on in pairs(draft) do
                    if on then target[name] = true end
                end
                ReadCollection:addRemoveItemMultiple(book.filepath, target)
                ReadCollection:write()
                close()
                if opts.on_close then opts.on_close() end
              end },
        }
    else
        buttons[#buttons + 1] = {
            { text = "+ " .. _("New collection"), callback = newCollection },
            { text = _("Close"), callback = function()
                close()
                if opts.on_close then opts.on_close() end
            end },
        }
    end

    -- No ButtonDialog title slot in either mode. Book mode leads with
    -- the reused book header for context; manage mode builds its own
    -- left-aligned title + divider + intro inside the content
    -- VerticalGroup below so the dialog reads like a settings panel
    -- rather than a quick-action ButtonDialog.
    dialog = ButtonDialog:new{
        title          = nil,
        use_info_style = false,
        width          = dialog_w,
        buttons        = buttons,
    }

    -- Compose ALL extra content (header + collection grid) into a
    -- single VerticalGroup and call addWidget exactly once. Each
    -- addWidget triggers a full ButtonDialog:reinit (free + init), so
    -- N rows = N reinit cycles, which gets expensive AND tears down /
    -- rebuilds the title_group repeatedly. One addWidget = one reinit.
    local content = VerticalGroup:new{ align = "center" }

    -- Shared horizontal divider helper.
    local function _divider()
        return LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = inner_w, h = Size.line.medium },
        }
    end

    if bulk_mode then
        -- Bulk header: count of selected books + intro paragraph.
        -- No book record to render a thumbnail header from, and the
        -- selection set spans arbitrarily many books so reusing the
        -- single-book header would be misleading. Mirror manage-mode's
        -- titled-panel layout instead.
        local n_paths = (opts.paths and #opts.paths) or 0
        local title_row = HorizontalGroup:new{ align = "center" }
        title_row[#title_row + 1] = FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            margin     = 0,
            TextBoxWidget:new{
                text  = string.format(_("Collections \xC2\xB7 %d books"), n_paths),
                face  = Font:getFace("tfont", 20),
                bold  = true,
                width = inner_w,
            },
        }
        content[#content + 1] = title_row
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.default }
        content[#content + 1] = _divider()
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
        content[#content + 1] = TextBoxWidget:new{
            text  = _("Tap a collection to cycle through: no change, "
                .. "add to all, remove from all. Save returns the diff "
                .. "to the bulk menu."),
            face  = Font:getFace("infofont", 16),
            width = inner_w,
        }
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
        content[#content + 1] = _divider()
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
    elseif (book_mode or stage_only) and opts.bw and opts.bw._buildBookMenuHeader then
        -- Book mode (persist OR stage_only): render the SAME book menu
        -- header here, including the nav pill strip. In persist mode
        -- pills mirror the live `draft` membership; in stage_only the
        -- pill specs reflect current persisted state because the diff
        -- is held externally and not visible in the live ReadCollection.
        -- For now stage_only passes nil pill specs (the per-book menu
        -- carries its own outline marker via the Collections button
        -- text_func). Tapping a pill closes the manager (draft
        -- discarded) and drills into the relevant facet view.
        local pill_specs
        if book_mode and opts.bw._buildPillSpecs then
            pill_specs = opts.bw:_buildPillSpecs(book, draft, function()
                UIManager:close(dialog)
            end)
        end
        local header = opts.bw:_buildBookMenuHeader(book, inner_w, pill_specs)
        if header then
            content[#content + 1] = header
            content[#content + 1] = VerticalSpan:new{ width = Size.padding.small }
            content[#content + 1] = _divider()
            content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
        end
    else
        -- Manage mode: left-aligned title, divider below, intro
        -- paragraph in a padded info panel, another divider, then the
        -- collection grid. The two dividers + breathing room around the
        -- intro stop the title / intro / list from running into each
        -- other as one undifferentiated text block.
        local title_row = HorizontalGroup:new{ align = "center" }
        title_row[#title_row + 1] = FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            margin     = 0,
            TextBoxWidget:new{
                text  = _("Manage collections"),
                face  = Font:getFace("tfont", 20),
                bold  = true,
                width = inner_w,
            },
        }
        content[#content + 1] = title_row
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.default }
        content[#content + 1] = _divider()
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
        content[#content + 1] = TextBoxWidget:new{
            text  = _("Tap a custom collection to rename, delete, or pin "
                .. "it to the chip bar. Long-press a book on the shelf "
                .. "and tap Collections… to add or remove it from "
                .. "collections."),
            face  = Font:getFace("infofont", 16),
            width = inner_w,
        }
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
        content[#content + 1] = _divider()
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.large }
    end

    -- Two-column grid of collections. Cell rendering delegates to the
    -- shared PickerCell so the Manager looks identical to every other
    -- chip-source picker (folder / author / series / genre / etc.).
    -- - In book mode, `selected = draft[name]` inverts the cell when
    --   the book is in that collection (filled black with white text);
    --   no checkbox glyph, the inverted block IS the selected cue.
    -- - In bulk mode, baseline is computed across opts.paths ("all" /
    --   "some" / "none"). Staged intent is read from draft_add /
    --   draft_remove and surfaced via a subtitle override ("Add to all"
    --   / "Remove from all"). "all" baseline shows as the inverted
    --   cell; "some" shows as not-inverted plus a "(Mixed)" subtitle.
    -- - In stage_only mode, baseline is the single book's current
    --   membership, layered with draft_add / draft_remove to compute
    --   the EFFECTIVE membership shown. Tap cycles the diff relative
    --   to the persisted state (current=in + draft_remove -> "remove"
    --   pending; current=out + draft_add -> "add" pending).
    -- - In manage mode, no cell is "selected" (the action on tap is to
    --   open the edit menu, not toggle membership).
    local PickerCell = require("lib/bookshelf_picker_cell")
    local names      = _orderedNames()

    -- Baseline membership for a collection across the operating set.
    -- bulk: scan opts.paths via ReadCollection. stage_only: single book.
    -- Returns "all" | "some" | "none". Cached per collection name for
    -- this rebuild so we don't rescan paths once per cell tap reroute.
    local _baseline_cache = {}
    local function _baselineState(name)
        if _baseline_cache[name] then return _baseline_cache[name] end
        local state
        if bulk_mode then
            local paths = opts.paths or {}
            if #paths == 0 then
                state = "none"
            else
                local hits = 0
                for _i, fp in ipairs(paths) do
                    if ReadCollection:isFileInCollection(fp, name) then
                        hits = hits + 1
                    end
                end
                if hits == 0 then
                    state = "none"
                elseif hits == #paths then
                    state = "all"
                else
                    state = "some"
                end
            end
        elseif stage_only then
            state = ReadCollection:isFileInCollection(book.filepath, name)
                and "all" or "none"
        else
            state = "none"
        end
        _baseline_cache[name] = state
        return state
    end
    -- Compact card height: enough room for two text lines + breathing
    -- space, without making the dialog feel like it's full of giant
    -- tiles. The picker grid pages sit on a fullscreen modal and can
    -- afford taller cells; the Manager dialog is a popup so we tune
    -- shorter here.
    local cell_h = Screen:scaleBySize(60)

    local function makeCell(name)
        if not name then
            return HorizontalSpan:new{ width = cell_w }
        end

        -- Compute the cell's visual state. `selected` -> inverted cell
        -- background (PickerCell.invert). `subtitle` overrides the
        -- count-of-books footer with whatever staged status we want to
        -- surface (e.g. "Add to all"). The label may also get a
        -- staged-action prefix arrow for redundancy when the inverted
        -- pixel state alone could be ambiguous.
        local selected = false
        local tint     = false
        local subtitle_override
        local label = _displayName(name)
        if book_mode then
            selected = draft[name] == true
        elseif bulk_mode then
            local baseline = _baselineState(name)
            local staged_add    = draft_add[name]    == true
            local staged_remove = draft_remove[name] == true
            -- Effective membership = baseline ± staged.
            local effective = baseline
            if staged_add then
                effective = "all"
            elseif staged_remove then
                effective = "none"
            end
            selected = (effective == "all")
            -- Stage-remove gets a gray fill so it's visually distinct
            -- from a plain "out" cell (which also has effective=none).
            -- Stage-add keeps the inverted-black look from selected=true
            -- (effective=all) — the inversion alone is unambiguous.
            tint = staged_remove
            if staged_add then
                subtitle_override = _("Add to all") .. " +"
            elseif staged_remove then
                subtitle_override = _("Remove from all") .. " \xE2\x88\x92"  -- −
            elseif baseline == "some" then
                subtitle_override = _("Mixed")
            end
        elseif stage_only then
            -- Effective membership for stage_only is current ± diff.
            local current = (_baselineState(name) == "all")
            local staged_add    = draft_add[name]    == true
            local staged_remove = draft_remove[name] == true
            local effective     = current
            if staged_add    then effective = true  end
            if staged_remove then effective = false end
            selected = effective
            tint     = staged_remove
            if staged_add then
                subtitle_override = _("Add") .. " +"
            elseif staged_remove then
                subtitle_override = _("Remove") .. " \xE2\x88\x92"
            end
        end

        local cell_dimen  = Geom:new{ w = cell_w, h = cell_h }
        local item = {
            label    = label,
            subtitle = subtitle_override,
            count    = subtitle_override == nil and _countOf(name) or nil,
        }
        local cell_widget = PickerCell.render(
            item,
            cell_dimen,
            { selected = selected, tint = tint }
        )
        -- Wrap the cell in an InputContainer with a fixed dimen so the
        -- enclosing HorizontalGroup measures it at cell_w (not natural
        -- width) -- otherwise short labels make cells narrower and the
        -- cell_gap between columns gets absorbed. Same trick used by
        -- LibraryModal's grid renderer.
        local cell = InputContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            cell_widget,
        }
        cell.ges_events = {
            Tap  = { GestureRange:new{ ges = "tap",  range = cell.dimen } },
            Hold = { GestureRange:new{ ges = "hold", range = cell.dimen } },
        }
        cell.onTap = function()
            if book_mode then
                draft[name] = not draft[name]
                rebuild()
            elseif bulk_mode then
                -- Tri-state cycle: no-staged-action -> stage-add ->
                -- stage-remove -> no-staged-action. The baseline
                -- (all/some/none) is independent of the staged action;
                -- both render together so the user sees what they're
                -- changing FROM and TO.
                if draft_add[name] then
                    draft_add[name]    = nil
                    draft_remove[name] = true
                elseif draft_remove[name] then
                    draft_remove[name] = nil
                else
                    draft_add[name]    = true
                end
                rebuild()
            elseif stage_only then
                -- For stage_only the cycle relative to the book's
                -- CURRENT membership feels more natural than a free
                -- tri-state: "currently in, tap once -> stage remove,
                -- tap again -> back to no-change". So we cycle the
                -- effective membership and recompute the staged diff
                -- from current.
                local current        = (_baselineState(name) == "all")
                local staged_add     = draft_add[name]    == true
                local staged_remove  = draft_remove[name] == true
                local effective      = current
                if staged_add    then effective = true  end
                if staged_remove then effective = false end
                local target = not effective
                draft_add[name]    = nil
                draft_remove[name] = nil
                if target ~= current then
                    if target then
                        draft_add[name]    = true
                    else
                        draft_remove[name] = true
                    end
                end
                rebuild()
            else
                holdMenu(name)
            end
            return true
        end
        cell.onHold = function() holdMenu(name); return true end
        return cell
    end

    -- Pagination: compute the rough vertical budget the cell grid is
    -- allowed (screen height minus header, dividers, footer, plus a
    -- safety margin) then cap rows per page accordingly. Cells then
    -- get sliced into pages and a chevron row is appended when there's
    -- more than one page. The book header is the dominant variable
    -- height factor; we approximate via Screen height * 0.40 (works
    -- across portrait orientations on 6"/7" panels).
    local row_h        = cell_h + cell_gap
    local max_rows     = math.max(2,
        math.floor((Screen:getHeight() * 0.40) / row_h))
    local cells_per_page = max_rows * 2  -- 2-column grid
    local total_cells  = #names
    local total_pages  = math.max(1, math.ceil(total_cells / cells_per_page))
    if cur_page > total_pages then cur_page = total_pages end
    if cur_page < 1 then cur_page = 1 end
    local first_idx    = (cur_page - 1) * cells_per_page + 1
    local last_idx     = math.min(first_idx + cells_per_page - 1, total_cells)

    local i = first_idx
    local first_pair = true
    local rendered_pairs = 0
    while i <= last_idx do
        if not first_pair then
            -- Same gap between rows as between columns -- so the grid
            -- reads as cells in a uniform grid rather than a rigid
            -- two-column stack.
            content[#content + 1] = VerticalSpan:new{ width = cell_gap }
        end
        first_pair = false
        content[#content + 1] = HorizontalGroup:new{
            align = "center",
            makeCell(names[i]),
            HorizontalSpan:new{ width = cell_gap },
            makeCell(names[i + 1]),  -- nil-safe via makeCell
        }
        rendered_pairs = rendered_pairs + 1
        i = i + 2
    end

    -- Height stability across pages: when the last page is shorter than
    -- a full page, the dialog would shrink and the pager row would
    -- jump up -- jarring during paging. Pad the remaining rows with
    -- an empty VerticalSpan so the cell area always reserves the same
    -- vertical real estate.
    if total_pages > 1 then
        local max_pairs    = math.ceil(cells_per_page / 2)
        local phantom_rows = max_pairs - rendered_pairs
        if phantom_rows > 0 then
            content[#content + 1] = VerticalSpan:new{
                width = phantom_rows * (cell_h + cell_gap),
            }
        end
    end

    -- Page indicator + chevrons when there's more than one page.
    -- Pager goes inside the content VG (not the buttons table) so it
    -- visually anchors with the cells. Chevrons are borderless to
    -- match the rest of bookshelf's pagination (LibraryModal + the
    -- main shelf footer both use bordersize=0 icon buttons).
    if total_pages > 1 then
        local Button = require("ui/widget/button")
        local chev_size = Screen:scaleBySize(28)
        local indicator = TextWidget:new{
            text = string.format(_("Page %d of %d"), cur_page, total_pages),
            face = Font:getFace("cfont", 14),
        }
        local function _chev(icon, enabled, target_page)
            return Button:new{
                icon         = icon,
                icon_width   = chev_size,
                icon_height  = chev_size,
                bordersize   = 0,
                enabled      = enabled,
                show_parent  = dialog,
                callback     = enabled
                    and function() cur_page = target_page; rebuild() end
                    or  function() end,
            }
        end
        local prev = _chev("chevron.left",  cur_page > 1,           cur_page - 1)
        local next = _chev("chevron.right", cur_page < total_pages, cur_page + 1)
        content[#content + 1] = VerticalSpan:new{ width = Size.padding.default }
        content[#content + 1] = HorizontalGroup:new{
            align = "center",
            prev,
            HorizontalSpan:new{ width = Size.padding.large },
            indicator,
            HorizontalSpan:new{ width = Size.padding.large },
            next,
        }
    end

    dialog:addWidget(content)
    UIManager:show(dialog)
end

return CollectionManager
