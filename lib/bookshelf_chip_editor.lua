-- bookshelf_chip_editor.lua
-- Per-tab editor modal.
--   editTab(tab_id, opts)  -- open the editor for one tab directly.
--
-- opts.on_change is called after Save, and also immediately after each
-- Move-left / Move-right tap (those persist without going through Save).
-- opts.bw is the BookshelfWidget instance; when present the dialog anchors
-- just below the chip strip so the strip stays visible.
--
-- Pattern mirrors bookshelf_hero_line_editor.lua: in-memory `draft` for
-- live edits; settings only flush on Save; Cancel discards the draft.

local ButtonDialog   = require("ui/widget/buttondialog")
local ConfirmBox     = require("ui/widget/confirmbox")
local UIManager      = require("ui/uimanager")
local Geom           = require("ui/geometry")
local Size           = require("ui/size")
local Screen         = require("device").screen

local TabModel = require("lib/bookshelf_tab_model")
local logger   = require("logger")
local _        = require("lib/bookshelf_i18n").gettext

-- Wall-clock timer for perf instrumentation. Same pattern as
-- bookshelf_widget.lua: LuaSocket's gettime gives fractional seconds
-- including I/O waits; os.clock is CPU-only (fallback).
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

local Editor = {}

-- Per-key default sort direction. Picking one of these auto-sets the
-- matching reverse flag; the up-arrow indicator only renders when the
-- saved direction differs from this default. So "Book count (most
-- first)" / "Most recently added (newest first)" show no arrow at
-- their natural orientation; flipping them to ascending adds the ↑.
-- Same for text keys -- "Title (A-Z)" shows no arrow at default,
-- shows ↑ if the user reverses to Z-A.
local DEFAULT_REVERSE = {
    book_count   = true,
    last_opened  = true,
    date_added   = true,
    -- "Progress" sort defaults to highest-progress-first: a user picking
    -- "Sort by progress" usually wants to see books they're furthest
    -- through (or finished) at the top. Ascending (unread first) is the
    -- niche choice -- still reachable via the picker's toggle.
    percent_read = true,
    -- Rating sort defaults to highest-first, matching the Ratings stack
    -- default and the usual "show my best-rated books at the top" intent.
    rating       = true,
    -- Everything else defaults to false (ascending). The table only
    -- needs entries for keys whose default is true.
}
local function _isDefaultDirection(key, reverse)
    return (DEFAULT_REVERSE[key] == true) == (reverse == true)
end

-- Per-source-kind default sort priority. Applied when the user picks
-- a source in the editor, overwriting the previous sort selection.
-- The user can re-pick sort levels afterwards if they want something
-- different; the defaults are tuned for the "if you didn't think about
-- it, this is probably what you wanted" case.
--
-- Each entry is a sort_priority list -- a sequence of { key, reverse }
-- levels. For group sources (series/authors/genres/tags/formats) the
-- level 1 entry orders the group cards and levels 2+ apply within a
-- drilled-in group (see BookshelfWidget:_applyWithinGroupSort).
-- Forward-declared so `_applySourceDefaults` (defined below) can read
-- it for the auto-rename-new-chip QoL. The actual table populates a
-- few dozen lines further down; this reservation just makes the local
-- visible to the function's upvalue capture.
local SOURCE_LABEL

local SOURCE_SORT_DEFAULTS = {
    -- Book sources (return books, not groups)
    all           = { { key = "filename",        reverse = false } },
    library       = { { key = "author_surname",  reverse = false },
                      { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false } },
    recent        = { { key = "last_opened",     reverse = true  } },
    latest        = { { key = "date_added",      reverse = true  } },
    favorites     = { { key = "last_opened",     reverse = true  } },
    folder        = { { key = "filename",        reverse = false } },
    collection    = { { key = "last_opened",     reverse = true  } },
    tag           = { { key = "last_opened",     reverse = true  } },
    genre         = { { key = "author_surname",  reverse = false },
                      { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false } },
    author        = { { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false },
                      { key = "title",           reverse = false } },
    single_series = { { key = "series_index",    reverse = false } },
    status        = { { key = "last_opened",     reverse = true  } },
    format        = { { key = "last_opened",     reverse = true  } },
    -- Group sources (level 1 -> group cards, levels 2+ -> within group)
    series        = { { key = "last_opened",     reverse = true  },
                      { key = "series_index",    reverse = false } },
    authors       = { { key = "author_surname",  reverse = false },
                      { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false } },
    genres        = { { key = "book_count",      reverse = true  },
                      { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false } },
    tags          = { { key = "book_count",      reverse = true  },
                      { key = "title",           reverse = false } },
    formats       = { { key = "book_count",      reverse = true  },
                      { key = "title",           reverse = false } },
    languages     = { { key = "book_count",      reverse = true  },
                      { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false } },
    -- Ratings group: highest rating first, books within each star
    -- bucket sorted series_name -> series_index -> title.
    ratings       = { { key = "rating",           reverse = true  },
                      { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false },
                      { key = "title",           reverse = false } },
    -- Specific rating: a book list filtered to one star count.
    rating        = { { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false },
                      { key = "title",           reverse = false } },
    -- Specific language: a book list filtered to one language.
    language      = { { key = "author_surname",  reverse = false },
                      { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false } },
}
local function _applySourceDefaults(draft)
    local kind = draft.source and draft.source.kind
    local defaults = kind and SOURCE_SORT_DEFAULTS[kind]
    if defaults then
        -- Deep copy so the SOURCE_SORT_DEFAULTS table isn't mutated when
        -- the user later toggles a level's reverse via the picker.
        local copy = {}
        for i, level in ipairs(defaults) do
            copy[i] = { key = level.key, reverse = level.reverse }
        end
        draft.sort_priority = copy
    end
    -- QoL: if the chip's label is still the default "New chip" (i.e.
    -- the user hasn't customised it), rename it to match the picked
    -- source — e.g. picking "Genres" sets the label to "Genres",
    -- picking a specific author sets it to that author's name. Only
    -- the untouched default is replaced; user-edited labels are
    -- preserved as-is.
    if draft.label == _("New chip") and draft.source then
        local fresh
        if draft.source.id and draft.source.id ~= "" then
            -- Specific-X sources (folder, single_series, etc.): use the
            -- id as the label, with folder basename special-cased so
            -- long paths don't blow out the chip pill.
            if draft.source.kind == "folder" then
                fresh = draft.source.id:match("([^/]+)/?$") or draft.source.id
            else
                fresh = draft.source.id
            end
        elseif kind and SOURCE_LABEL and SOURCE_LABEL[kind] then
            fresh = SOURCE_LABEL[kind]()
        end
        if fresh and fresh ~= "" then draft.label = fresh end
    end
end

-- Group source kinds. These tabs show GROUP CARDS at the top level
-- (one card per author / genre / series / tag / format) and book
-- LISTS inside each card when drilled in. The sort_priority is
-- interpreted as level-1 = order of group cards, levels 2+ = order
-- of books within each group.
local GROUP_KINDS = {
    series  = true, authors = true, genres = true,
    tags    = true, formats = true, languages = true,
}

-- Level-1 (group order) labels for group tabs. The engine's labels
-- ("Series name", "Last opened", "Book count") are aimed at per-book
-- semantics and read awkwardly when the records are groups -- "Series
-- name" on the Authors tab actually orders authors alphabetically.
-- Override here for clarity. Used by both the picker buttons and the
-- editor's Sort-row button text_func so the displayed label matches
-- what the user picked.
local GROUP_LEVEL1_LABEL = {
    series_name    = function() return _("Name") end,
    author_surname = function() return _("Surname") end,
    last_opened    = function() return _("Most recently read") end,
    date_added     = function() return _("Most recently added") end,
    book_count     = function() return _("Book count") end,
}

-- Friendly source labels shown on the "Source:" button in the editor.
-- These mirror the source picker's button labels so the user sees the
-- same wording in both places. Functions because gettext expands at
-- call time, not module load.
SOURCE_LABEL = {
    all           = function() return _("Home (folders)")     end,
    library       = function() return _("Home (flattened)")   end,
    recent        = function() return _("Recently read")      end,
    latest        = function() return _("Latest added")       end,
    series        = function() return _("Series")             end,
    authors       = function() return _("Authors")            end,
    genres        = function() return _("Genres")             end,
    tags          = function() return _("Collections")        end,
    formats       = function() return _("Formats")            end,
    ratings       = function() return _("Ratings")            end,
    languages     = function() return _("Languages")          end,
    favorites     = function() return _("Favourites")         end,
    -- "Specific X" kinds carry an id; the resolver appends it.
    folder        = function() return _("Folder")             end,
    collection    = function() return _("Collection")         end,
    tag           = function() return _("Collection")         end,
    genre         = function() return _("Genre")              end,
    author        = function() return _("Author")             end,
    single_series = function() return _("Series")             end,
    status        = function() return _("Status")             end,
    format        = function() return _("Format")             end,
    rating        = function() return _("Rating")             end,
    language      = function() return _("Language")           end,
}

-- _resolveSourceLabel(source): display string for "Source: <label>".
-- For built-in kinds returns just the label ("Recently read"). For
-- specific-X kinds returns "<Category>: <id>" so the user can see at
-- a glance which author / series / folder / etc. is selected.
local function _resolveSourceLabel(source)
    if not source or not source.kind then return _("(none)") end
    local fn = SOURCE_LABEL[source.kind]
    local label = fn and fn() or source.kind
    if source.id and source.id ~= "" then
        -- For folder paths, show the basename to keep the row tidy --
        -- "/mnt/us/Calibre/library/Pratchett" reads worse than "Pratchett".
        local id = source.id
        if source.kind == "folder" then
            id = id:match("([^/]+)/?$") or id
        end
        return label .. ": " .. id
    end
    return label
end

-- Resolve the display label for a (level_index, key) pair on a tab
-- with source_kind. Returns the engine's default short/label unless
-- the (group, level 1) context overrides it.
local function _resolveSortLabel(level_index, key, source_kind)
    local is_group = GROUP_KINDS[source_kind or ""] or false
    if is_group and level_index == 1 and GROUP_LEVEL1_LABEL[key] then
        return GROUP_LEVEL1_LABEL[key]()
    end
    local SortEngine = require("lib/bookshelf_sort_engine")
    local k = SortEngine.KEYS[key]
    return (k and (k.short or k.label)) or key
end

-- editTab(tab_id, opts) -- modal editor for one tab.
-- opts = { on_change = function() end, bw = <BookshelfWidget> }
-- on_change fires after Save, and after each Move-left / Move-right tap.
function Editor:editTab(tab_id, opts)
    opts = opts or {}
    local tabs = TabModel.load()
    local idx, target
    for i, t in ipairs(tabs) do
        if t.id == tab_id then idx = i; target = t; break end
    end
    if not target then return end

    -- In-memory draft. All sub-modals mutate this; settings only writes on Save.
    -- Cancel discards the draft without saving.
    local draft = {}
    for k, v in pairs(target) do
        if type(v) == "table" then
            local copy = {} for kk, vv in pairs(v) do copy[kk] = vv end
            draft[k] = copy
        else
            draft[k] = v
        end
    end
    -- Ensure required nested tables exist even if a legacy schema is missing them.
    draft.filter        = draft.filter        or {}
    draft.sort_priority = draft.sort_priority or {}
    draft.source        = draft.source        or { kind = tab_id }

    -- One-time schema migration: tab.icon used to be a separate field.
    -- Now label may contain inline nerd-font glyphs. If the persisted tab
    -- still has an icon field, fold it into the front of the label so the
    -- editor presents one unified string. Save clears tab.icon to lock the
    -- migration in (chip strip falls back on the legacy field meanwhile).
    if draft.icon and draft.icon ~= "" then
        draft.label = draft.icon .. " " .. (draft.label or "")
        draft.icon  = nil
    end

    -- Two-flag dirty tracking:
    --   data_dirty   - source / filter / sort changes (book lists need
    --                  refetching; book cache must invalidate on close).
    --   visual_dirty - label / icon changes (chip strip repaints but the
    --                  underlying book lists are unaffected; cache stays
    --                  valid).
    -- Cancel / Save invalidate the book cache only when data_dirty;
    -- on_change fires when either flag is set. "Open, close untouched"
    -- is near-instant (both false).
    local data_dirty   = false
    local visual_dirty = false
    local function is_dirty() return data_dirty or visual_dirty end

    -- applyLivePreview(affects_data):
    --   affects_data = false (label / icon): live-preview the change by
    --     pushing a "visual-only" override (persisted data fields + draft's
    --     label/icon) into TabModel and firing on_change. The chip strip
    --     repaints immediately; the underlying book listing is unaffected
    --     so the rebuild stays cheap (cache reuse).
    --   affects_data = true (source / filter / sort): defer entirely.
    --     Just mark data_dirty and return -- no override, no on_change,
    --     no shelf rebuild. The editor's own rebuild() refreshes the
    --     button labels via draft. The shelf only re-sorts on Save.
    --
    -- This avoids the bookends-pattern trap where every sort pick triggers
    -- a 4-9 second rebuild on the genres tab. Visual previews stay live
    -- because they're cheap; data previews are too expensive to be live.
    local function applyLivePreview(affects_data)
        if affects_data then
            data_dirty = true
            return
        end
        visual_dirty = true
        -- Build a visual-only override: persisted record + draft's
        -- label/icon. Reading TabModel.load() bypasses the override
        -- lookup so we get the unmodified persisted state and don't
        -- leak any pending data changes from draft into the preview.
        local persisted
        for _i,t in ipairs(TabModel.load()) do
            if t.id == tab_id then persisted = t; break end
        end
        if not persisted then return end
        local override = {}
        for k, v in pairs(persisted) do
            if type(v) == "table" then
                local copy = {} for kk, vv in pairs(v) do copy[kk] = vv end
                override[k] = copy
            else
                override[k] = v
            end
        end
        override.label = draft.label
        override.icon  = draft.icon
        TabModel.setOverride(tab_id, override)
        if opts.on_change then opts.on_change() end
    end

    -- Lazy-loaded widget constructors (avoids polluting the module-level scope).
    local FrameContainer    = require("ui/widget/container/framecontainer")
    local CenterContainer   = require("ui/widget/container/centercontainer")
    local WidgetContainer   = require("ui/widget/container/widgetcontainer")
    local InputContainer    = require("ui/widget/container/inputcontainer")
    local MovableContainer  = require("ui/widget/container/movablecontainer")
    local VerticalGroup     = require("ui/widget/verticalgroup")
    local HorizontalGroup   = require("ui/widget/horizontalgroup")
    local TitleBar          = require("ui/widget/titlebar")
    local ButtonTable       = require("ui/widget/buttontable")
    local Button            = require("ui/widget/button")
    local InputDialog       = require("ui/widget/inputdialog")
    local GestureRange      = require("ui/gesturerange")
    local Blitbuffer        = require("ffi/blitbuffer")
    local Device            = require("device")

    local sw       = Screen:getWidth()
    local sh       = Screen:getHeight()
    local dialog_w = math.floor(math.min(sw, sh) * 0.85)

    local dialog
    local frame

    -- rebuild() -- swap frame[1] in-place so the button labels and enabled
    -- states refresh without touching the MovableContainer. The anchor-based
    -- positioning set on first paint is therefore preserved across rebuilds.
    local function rebuild()
        -- Reload tabs for the move buttons so enabled state is always current.
        local current_tabs = TabModel.load()
        local current_idx = 0
        for i, t in ipairs(current_tabs) do
            if t.id == tab_id then current_idx = i; break end
        end
        -- A chevron is "at the edge" only if there's no ENABLED neighbour
        -- in that direction. Hidden tabs don't count toward visible order
        -- so they shouldn't gate the move buttons.
        local at_left = true
        for i = current_idx - 1, 1, -1 do
            if current_tabs[i].enabled ~= false then at_left = false; break end
        end
        local at_right = true
        for i = current_idx + 1, #current_tabs do
            if current_tabs[i].enabled ~= false then at_right = false; break end
        end

        -- Bookends-style nudge chevrons (mdi-chevron-left / right from the
        -- Symbols Nerd Font). Same glyph + render-size as the line editor's
        -- position nudges so the visual language is consistent.
        local CHEV_LEFT  = "\xEE\xA1\x80"  -- U+E840 mdi-chevron-left
        local CHEV_RIGHT = "\xEE\xA1\x81"  -- U+E841 mdi-chevron-right
        local CHEV_SIZE  = 28

        local function open_label_dialog()
            local label_dialog
            -- Build the button row. "Insert icon..." only appears when
            -- bookends's IconsLibrary is available; without it the row
            -- collapses to Cancel / OK.
            local row = {
                {
                    text     = _("Cancel"),
                    id       = "close",
                    callback = function() UIManager:close(label_dialog) end,
                },
            }
            local ok_il, IconsLibrary = pcall(require, "menu.icons_library")
            if ok_il and IconsLibrary and IconsLibrary.show then
                row[#row + 1] = {
                    text     = _("Insert icon\xE2\x80\xA6"),
                    callback = function()
                        -- Dismiss the on-screen keyboard before showing the
                        -- icon picker -- otherwise the keyboard covers the
                        -- bottom half of the icon library on portrait
                        -- e-readers. Re-show after the picker closes so the
                        -- user can keep typing.
                        if label_dialog and label_dialog.onCloseKeyboard then
                            pcall(function() label_dialog:onCloseKeyboard() end)
                        end
                        -- Guard against tap-fall-through. With the keyboard
                        -- hidden, InputDialog:onTap treats any tap outside
                        -- the dialog frame as "close the dialog" (see
                        -- frontend/ui/widget/inputdialog.lua:557-560).
                        -- Rapid pagination taps on the icon picker can leak
                        -- through, dismissing the dialog underneath; the
                        -- picker then has nothing to send its glyph to,
                        -- leaving the keyboard orphaned on screen after the
                        -- user's pick (issue #43). Setting
                        -- deny_keyboard_hiding short-circuits onTap entirely
                        -- so the dialog can't dismiss itself while the
                        -- picker is the modal on top. Restored when the
                        -- picker callback runs.
                        if label_dialog then
                            label_dialog.deny_keyboard_hiding = true
                        end
                        IconsLibrary:show(function(glyph)
                            if label_dialog then
                                label_dialog.deny_keyboard_hiding = false
                            end
                            -- Insert the glyph at cursor in the InputDialog.
                            -- KOReader's InputDialog exposes addTextToInput
                            -- (lifts the bookends_line_editor pattern).
                            if glyph and glyph ~= ""
                                    and label_dialog and label_dialog.addTextToInput then
                                pcall(function() label_dialog:addTextToInput(glyph) end)
                            end
                            if label_dialog and label_dialog.onShowKeyboard then
                                pcall(function() label_dialog:onShowKeyboard() end)
                            end
                        end)
                    end,
                }
            end
            row[#row + 1] = {
                text             = _("OK"),
                is_enter_default = true,
                callback         = function()
                    draft.label = label_dialog:getInputText()
                    UIManager:close(label_dialog)
                    applyLivePreview(false)  -- label is visual-only
                    rebuild()
                end,
            }
            label_dialog = InputDialog:new{
                title           = _("Chip label"),
                input           = draft.label or "",
                allow_newline   = false,
                text_height     = Screen:scaleBySize(40),
                edited_callback = function() end,
                buttons         = { row },
            }
            UIManager:show(label_dialog)
            label_dialog:onShowKeyboard()
        end

        -- Sort-button text for level N. Reads draft.sort_priority[N] and
        -- resolves the key's label through _resolveSortLabel so the
        -- group-tab context-renames ("Name", "Surname", etc.) show up
        -- consistently with what the picker offered. The ↑ glyph is
        -- appended only when the direction is inverted from the key's
        -- natural default -- a "Book count" sort at default (most-first)
        -- reads cleaner without an arrow that would suggest ascending.
        local function _sortButtonText(d, level_index)
            local lv = d.sort_priority and d.sort_priority[level_index]
            if not lv then
                return _("Sort ") .. level_index .. _(": (none)")
            end
            local kind = d.source and d.source.kind
            local lbl = _resolveSortLabel(level_index, lv.key, kind)
            if not _isDefaultDirection(lv.key, lv.reverse) then
                lbl = lbl .. " " .. "\xE2\x86\x91"
            end
            return level_index .. ": " .. lbl
        end

        local function move_tab(delta)
            local move_tabs = TabModel.load()
            local mi = 0
            for i, t in ipairs(move_tabs) do
                if t.id == tab_id then mi = i; break end
            end
            if mi == 0 then rebuild(); return end
            -- Walk in the delta direction looking for the next ENABLED
            -- neighbour. Hidden tabs are skipped so the swap moves THIS
            -- tab past any hidden ones between it and the next visible
            -- chip in the strip. If no enabled neighbour exists, no-op.
            local target = mi + delta
            while target >= 1 and target <= #move_tabs do
                if move_tabs[target].enabled ~= false then break end
                target = target + delta
            end
            if target >= 1 and target <= #move_tabs then
                move_tabs[mi], move_tabs[target] = move_tabs[target], move_tabs[mi]
                TabModel.save(move_tabs)
                -- Position moves are visual only (book lists unchanged);
                -- don't invalidate the book cache. Fire on_change so the
                -- chip strip repaints in its new order.
                if opts.on_change then opts.on_change() end
            end
            rebuild()
        end

        local buttons = {
            -- Row 0: [chev_left] [Label] [chev_right]. Label is a tappable
            -- button that opens an InputDialog where the user can type plain
            -- text, insert nerd-font glyphs via 'Insert icon...', and remove
            -- them by editing the field as usual. One field for both text
            -- and icons; no separate icon picker on the main dialog.
            {
                {
                    text           = CHEV_LEFT,
                    font_face      = "symbols",
                    font_size      = CHEV_SIZE,
                    font_bold      = false,
                    enabled_func   = function() return not at_left end,
                    callback       = function() move_tab(-1) end,
                },
                {
                    -- Title bar already shows the live label ("Editing: ..."),
                    -- so the button just describes its action -- no need to
                    -- repeat the label text.
                    text     = _("Edit label"),
                    callback = open_label_dialog,
                },
                {
                    text           = CHEV_RIGHT,
                    font_face      = "symbols",
                    font_size      = CHEV_SIZE,
                    font_bold      = false,
                    enabled_func   = function() return not at_right end,
                    callback       = function() move_tab(1) end,
                },
            },
            -- Row 1a: source + status. Splitting source/status off from the
            -- sort row gives each cell room to breathe without the long
            -- "Sort 1: Author surname" labels wrapping.
            {
                {
                    text_func = function()
                        return _("Source: ") .. _resolveSourceLabel(draft.source)
                    end,
                    callback = function()
                        Editor:_pickSource(draft, function() applyLivePreview(true); rebuild() end)
                    end,
                },
                {
                    text_func = function()
                        local s = draft.filter and draft.filter.statuses or {}
                        local count, single_key = 0, nil
                        for k in pairs(s) do count = count + 1; single_key = k end
                        if count == 0 then return _("Status: any") end
                        if count == 1 then
                            local labels = {
                                unread   = _("Unread"),
                                reading  = _("Reading"),
                                on_hold  = _("On hold"),
                                finished = _("Finished"),
                            }
                            return _("Status: ") .. (labels[single_key] or single_key)
                        end
                        return _("Status: ") .. count .. _(" selected")
                    end,
                    callback = function()
                        Editor:_pickStatusFilter(draft, function() applyLivePreview(true); rebuild() end)
                    end,
                },
            },
            -- Row 1b: sort priority levels 1, 2, 3. Engine already supports
            -- unbounded levels via chainedComparator; three covers the
            -- common nested case "author surname -> series -> series index"
            -- with zero meaningful perf cost since deeper levels only fire
            -- when earlier ones tie.
            {
                {
                    text_func = function() return _sortButtonText(draft, 1) end,
                    callback = function()
                        Editor:_pickSortLevel(draft, 1, function() applyLivePreview(true); rebuild() end)
                    end,
                },
                {
                    text_func = function() return _sortButtonText(draft, 2) end,
                    callback = function()
                        Editor:_pickSortLevel(draft, 2, function() applyLivePreview(true); rebuild() end)
                    end,
                },
                {
                    text_func = function() return _sortButtonText(draft, 3) end,
                    callback = function()
                        Editor:_pickSortLevel(draft, 3, function() applyLivePreview(true); rebuild() end)
                    end,
                },
            },
            -- Row 2: actions [delete] [Cancel] [Save] [add].
            -- Delete (U+E8BF, mdi-delete) is enabled only for custom tabs;
            -- built-ins are hidden via the bookshelf menu's checkbox.
            -- Add (U+F055, fa-plus-circle) creates a new custom_N tab.
            -- All buttons borderless so the dialog frame's bottom edge
            -- serves as the action-row boundary (no double-border).
            {
                {
                    text           = "\xEE\xA2\xBF",  -- U+E8BF mdi-delete
                    font_face      = "symbols",
                    font_size      = CHEV_SIZE,
                    font_bold      = false,
                    bordersize     = 0,
                    callback   = function()
                        UIManager:show(ConfirmBox:new{
                            text       = _("Delete this chip?? This cannot be undone."),
                            ok_text    = _("Delete"),
                            ok_callback = function()
                                -- Deleting a tab changes the list of tabs,
                                -- not the contents of any tab. Book caches
                                -- for other tabs stay valid; the deleted
                                -- tab's cache entries are harmless orphans
                                -- (never read again). No invalidateBookCache.
                                TabModel.clearOverride()
                                local del_tabs = TabModel.load()
                                for di = #del_tabs, 1, -1 do
                                    if del_tabs[di].id == tab_id then
                                        table.remove(del_tabs, di)
                                        break
                                    end
                                end
                                TabModel.save(del_tabs)
                                UIManager:close(dialog)
                                if opts.on_change then opts.on_change() end
                            end,
                        })
                    end,
                },
                {
                    text       = _("Cancel"),
                    id         = "close",
                    bordersize = 0,
                    callback   = function()
                        local _t0 = _gettime()
                        -- Drop the visual-preview override and let the
                        -- persisted state surface. Data changes were never
                        -- previewed (just held in draft), so the cache is
                        -- still valid -- no invalidation needed. Only rebuild
                        -- if visual_dirty (to undo the icon/label preview);
                        -- data-only cancel is instant.
                        TabModel.clearOverride()
                        local _t1 = _gettime()
                        UIManager:close(dialog)
                        local _t2 = _gettime()
                        if visual_dirty and opts.on_change then opts.on_change() end
                        local _t3 = _gettime()
                        logger.dbg(string.format(
                            "[bookshelf perf] editor-cancel: data_dirty=%s visual_dirty=%s clearOverride=%.0fms close=%.0fms on_change=%.0fms TOTAL=%.0fms",
                            tostring(data_dirty), tostring(visual_dirty),
                            (_t1 - _t0) * 1000, (_t2 - _t1) * 1000,
                            (_t3 - _t2) * 1000, (_t3 - _t0) * 1000))
                    end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    bordersize       = 0,
                    callback         = function()
                        local _t0 = _gettime()
                        -- Clear the live-preview override BEFORE writing the
                        -- persisted record, so the subsequent on_change reads
                        -- the saved tab via the normal path, not the override.
                        TabModel.clearOverride()
                        local _t1 = _gettime()
                        -- Re-load to get the latest order (may have changed via
                        -- move buttons), find the tab by id, and update it in place.
                        -- Only persist if anything changed. Save-with-no-edits
                        -- skips the settings flush + cache invalidation.
                        if is_dirty() then
                            local save_tabs = TabModel.load()
                            for si, t in ipairs(save_tabs) do
                                if t.id == tab_id then
                                    save_tabs[si] = draft
                                    break
                                end
                            end
                            TabModel.save(save_tabs)
                        end
                        local _t2 = _gettime()
                        -- No cache invalidation needed. The _bySource_cache
                        -- is keyed on (source, filter, sort_priority), so
                        -- editing those produces a new key -- the next
                        -- render of THIS tab cache-misses and builds fresh
                        -- against the new settings. Other tabs keep their
                        -- warm cache entries (different keys, untouched).
                        -- Group caches (_authors_cache etc.) are keyed on
                        -- (home, depth) which doesn't change when a tab is
                        -- edited; they reflect the whole library's group
                        -- memberships regardless of tab preferences.
                        local _t3 = _gettime()
                        UIManager:close(dialog)
                        local _t4 = _gettime()
                        if is_dirty() and opts.on_change then opts.on_change() end
                        local _t5 = _gettime()
                        logger.dbg(string.format(
                            "[bookshelf perf] editor-save: data_dirty=%s visual_dirty=%s clearOverride=%.0fms TabModel.save=%.0fms invalidate=%.0fms close=%.0fms on_change=%.0fms TOTAL=%.0fms",
                            tostring(data_dirty), tostring(visual_dirty),
                            (_t1 - _t0) * 1000, (_t2 - _t1) * 1000,
                            (_t3 - _t2) * 1000, (_t4 - _t3) * 1000,
                            (_t5 - _t4) * 1000, (_t5 - _t0) * 1000))
                    end,
                },
                {
                    -- Add button placed last in the row to balance the
                    -- destructive Delete on the far left.
                    text           = "\xEF\x81\x95",  -- U+F055 fa-plus-circle
                    font_face      = "symbols",
                    font_bold      = false,
                    font_size  = CHEV_SIZE,
                    bordersize = 0,
                    callback   = function()
                        -- Persist any pending edits before spawning the
                        -- new tab so the user's current work isn't lost.
                        TabModel.clearOverride()
                        if is_dirty() then
                            local save_tabs = TabModel.load()
                            for si, t in ipairs(save_tabs) do
                                if t.id == tab_id then save_tabs[si] = draft; break end
                            end
                            TabModel.save(save_tabs)
                            -- Same reasoning as the Save path: the
                            -- _bySource_cache is keyed on (source, filter,
                            -- sort_priority), so a render with new settings
                            -- naturally cache-misses; other tabs keep
                            -- their warm entries. No invalidate needed.
                        end
                        -- Generate unique custom_N id and append the new tab.
                        local fresh = TabModel.load()
                        local n = 1
                        while true do
                            local cand = "custom_" .. n
                            local taken = false
                            for _i,t in ipairs(fresh) do
                                if t.id == cand then taken = true; break end
                            end
                            if not taken then break end
                            n = n + 1
                        end
                        local new_id = "custom_" .. n
                        -- Splice the new chip right after the chip
                        -- the user is currently editing rather than
                        -- appending to the end of the strip. Matches
                        -- the Pin-from-stack flow and keeps newly
                        -- created chips visually adjacent to their
                        -- origin.
                        TabModel.insertAfter(fresh, tab_id, {
                            id            = new_id,
                            label         = _("New chip"),
                            icon          = nil,
                            source        = { kind = "all" },
                            filter        = {},
                            sort_priority = { { key = "title", reverse = false } },
                            enabled       = true,
                        })
                        TabModel.save(fresh)
                        UIManager:close(dialog)
                        if opts.on_change then opts.on_change() end
                        Editor:editTab(new_id, opts)
                    end,
                },
            },
        }

        -- Strip empty rows. The conditional delete row's IIFE returns {}
        -- for built-in tabs; ButtonTable renders a zero-cell row as a
        -- thin separator strip which visually doubles with the adjacent
        -- row borders. Filtering keeps the dialog cleanly grid-shaped.
        local non_empty_buttons = {}
        for _i,row in ipairs(buttons) do
            if #row > 0 then non_empty_buttons[#non_empty_buttons + 1] = row end
        end
        local button_table = ButtonTable:new{
            width   = dialog_w - 2 * Size.padding.default,
            buttons = non_empty_buttons,
            zero_sep = true,
        }

        -- Dynamic title: shows the tab's current label so the user can see
        -- which tab they're editing at a glance, even while the Label
        -- button below is being edited. Falls back to a generic string
        -- when the label is empty / nil. with_bottom_line is off so the
        -- titlebar separator doesn't double with the top_row's top border.
        local title_text = _("Edit chip")
        if draft.label and draft.label ~= "" then
            title_text = _("Editing: ") .. draft.label
        end
        local title_bar = TitleBar:new{
            width             = dialog_w,
            title             = title_text,
            with_bottom_line  = false,
            close_callback    = function()
                -- X-button close == Cancel: drop visual preview, no cache
                -- invalidation, repaint only if a visual preview was active.
                TabModel.clearOverride()
                UIManager:close(dialog)
                if visual_dirty and opts.on_change then opts.on_change() end
            end,
        }

        frame[1] = VerticalGroup:new{
            align = "center",
            title_bar,
            CenterContainer:new{
                dimen = Geom:new{ w = dialog_w, h = button_table:getSize().h },
                button_table,
            },
        }

        if dialog then
            UIManager:setDirty(dialog, "ui")
        end
    end

    -- Build frame shell once; rebuild() will fill frame[1].
    frame = FrameContainer:new{
        radius     = Size.radius.window,
        padding    = 0,
        margin     = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{},  -- placeholder; filled by rebuild() below
    }

    -- Populate frame[1] for the first time before show.
    rebuild()

    local bw = opts.bw

    -- Build the dialog shell with MovableContainer + anchor.
    -- The anchor positions the dialog just below the chip strip on first paint
    -- and stays there because rebuild() only swaps frame[1] (the content),
    -- never the MovableContainer.
    dialog = InputContainer:new{}

    if Device:isTouchDevice() then
        dialog.ges_events = dialog.ges_events or {}
        dialog.ges_events.TapClose = {
            GestureRange:new{
                ges   = "tap",
                range = Geom:new{ x = 0, y = 0, w = sw, h = sh },
            },
        }
    end
    if Device:hasKeys() then
        dialog.key_events = dialog.key_events or {}
        dialog.key_events.Close = { { Device.input.group.Back } }
    end

    dialog.onTapClose = function(self_d, arg, ges_ev)
        if not frame.dimen or ges_ev.pos:notIntersectWith(frame.dimen) then
            -- Tap-outside-close == Cancel.
            TabModel.clearOverride()
            UIManager:close(self_d)
            if visual_dirty and opts.on_change then opts.on_change() end
        end
        return true
    end
    dialog.onClose = function(self_d)
        UIManager:close(self_d)
        return true
    end
    dialog.onCloseWidget = function()
        -- Repaint the region under the dialog. setDirty(nil, fn) only
        -- queues an EPDC flush -- it does NOT trigger any widget's
        -- paintTo, so the stale dialog pixels still sit in the buffer
        -- and would be sent to e-ink as a ghost. Passing the
        -- BookshelfWidget below gives UIManager a tree to paint before
        -- the flush. Falls back to a tree-less flush if bw isn't
        -- attached (caller didn't pass opts.bw).
        UIManager:setDirty(bw or nil, function()
            return "ui", frame.dimen
        end)
    end

    dialog[1] = WidgetContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        MovableContainer:new{
            frame,
            -- Anchor just below the chip strip so the strip stays visible
            -- while the user taps the Move-left / Move-right chevrons.
            -- The anchor is evaluated ONCE on the first paint (MovableContainer
            -- sets _anchor_ensured = true after that), so subsequent rebuild()
            -- calls never shift the dialog.
            anchor = function()
                local fsize = frame:getSize()
                -- Anchor the dialog in the bottom third of the screen so it
                -- sits below the hero card + chip strip and over the lower
                -- shelf rows, leaving the top half (hero, chips) visible.
                -- Clamp so a tall dialog doesn't fall off the bottom edge.
                local target_y = math.floor(sh * 2 / 3)
                local max_y    = sh - fsize.h
                return Geom:new{
                    x = math.floor((sw - fsize.w) / 2),
                    y = math.min(target_y, max_y),
                    w = fsize.w,
                    h = fsize.h,
                }
            end,
        },
    }

    UIManager:show(dialog, function() return "partial", frame.dimen end)
end

-- _pickSource -- full picker. Top-level ButtonDialog choosing a source kind;
-- selecting a kind that needs an id (folder, collection, genre, author) opens
-- a second-level picker populated from real data (KOReader PathChooser,
-- ReadCollection, or the repository's group fetchers).
--
-- NOTE (v1.4): "Specific tag" and "Reading status" kinds are intentionally
-- absent from the kinds list. getTags predicates on ReadCollection tags
-- (distinct from the `tags` built-in) and getBySource "status" predicates on
-- b.read_status, neither of which is produced by buildBookMeta from lfs
-- entries. These sub-options will be restored once those data paths are wired.
-- Tracked: requires follow-up before enabling tag/status custom sources.
function Editor:_pickSource(draft, on_close)
    local Repo = require("lib/bookshelf_book_repository")
    local d

    -- pickById: search-enabled, paginated 2-column card picker for
    -- choosing from a list of N items (collections, genres, authors).
    -- Uses bookshelf_library_modal (ported from bookends) so bookshelf
    -- works standalone. ButtonDialog fallback retained as a safety net
    -- in case the LibraryModal require ever fails.
    local function pickById(kind, choices, on_pick)
        local ok_lm, LibraryModal = pcall(require, "lib/bookshelf_library_modal")
        if ok_lm and LibraryModal and LibraryModal.new then
            local Font          = require("ui/font")
            local TextWidget    = require("ui/widget/textwidget")
            local VerticalGroup_ = require("ui/widget/verticalgroup")
            local VerticalSpan  = require("ui/widget/verticalspan")
            local FrameContainer_ = require("ui/widget/container/framecontainer")
            local CenterContainer_= require("ui/widget/container/centercontainer")
            local Blitbuffer_   = require("ffi/blitbuffer")
            local Screen_       = require("device").screen

            local query = nil
            local function matches(label, q)
                if not q or q == "" then return true end
                return label:lower():find(q:lower(), 1, true) ~= nil
            end
            local visible = choices
            local function recompute()
                if not query or query == "" then
                    visible = choices
                else
                    visible = {}
                    for _i,c in ipairs(choices) do
                        if matches(c.label, query) then visible[#visible + 1] = c end
                    end
                end
            end

            local modal
            modal = LibraryModal:new{
                config = {
                    title              = _("Choose ") .. kind,
                    search_placeholder = function() return _("Search\xE2\x80\xA6") end,
                    on_search_submit   = function(q)
                        query = q
                        recompute()
                        if modal then modal.page = 1; modal:refresh() end
                    end,
                    grid_cols    = 2,
                    cells_per_page = function()
                        -- 2-column grid; 5 rows portrait, 4 landscape.
                        return Screen_:getWidth() > Screen_:getHeight() and 8 or 10
                    end,
                    item_count   = function() return #visible end,
                    item_at      = function(idx) return visible[idx] end,
                    -- Shared cell renderer: same visual treatment in every
                    -- picker (folder, author, series, genre, format, rating,
                    -- collection) AND in the Collection Manager. No selected
                    -- state here -- pickers are one-shot select-and-close.
                    cell_renderer = function(item, dimen)
                        return require("lib/bookshelf_picker_cell").render(item, dimen)
                    end,
                    on_cell_tap = function(item)
                        UIManager:close(modal)
                        on_pick(item.value)
                    end,
                    footer_actions = {
                        {
                            label  = _("Close"),
                            -- Signal cancel via nil so the caller can
                            -- reopen the parent picker. Without this, Close
                            -- just dismissed back to the editor's dialog,
                            -- losing the user's place in the picker chain.
                            on_tap = function()
                                UIManager:close(modal)
                                on_pick(nil)
                            end,
                        },
                    },
                },
            }
            UIManager:show(modal)
            return
        end
        -- Fallback: flat ButtonDialog (limited for huge lists, but works
        -- when bookends isn't installed).
        local k
        local rows = {}
        for _i,c in ipairs(choices) do
            rows[#rows + 1] = {{
                text     = c.label,
                callback = function() on_pick(c.value); UIManager:close(k) end,
            }}
        end
        rows[#rows + 1] = {{
            text     = _("Cancel"),
            callback = function() UIManager:close(k); on_pick(nil) end,
        }}
        k = ButtonDialog:new{ title = _("Choose " .. kind), buttons = rows }
        UIManager:show(k)
    end
    -- Built-in shortcuts + working custom kinds.
    -- "Specific tag..." and "Reading status..." are deferred (see note above).
    -- Folder pair (row 3) lists every directory under home_dir that holds a
    -- book; selecting one writes source = { kind="folder", id=path/ } and
    -- getBySource prefix-matches book filepaths against the trailing-slash id.
    -- Row order favours the chip sources users reach for most often: the
    -- two date-based shortcuts sit at the top, the full-library flattened
    -- view spans the row below, then the folder pair sits with the rest of
    -- the browse-all / specific-picker pairs.
    local function set_simple(kind_value)
        return function()
            draft.source = { kind = kind_value }
            _applySourceDefaults(draft)
            UIManager:close(d)
            on_close()
        end
    end

    -- Generic specific-picker. fetcher_kind is a string ("series", "author",
    -- "genre", "format") routed through Repo.getGroupChoices for a pure-data
    -- read of the cached shapes -- no _hydrateGroupShape, no cover loads.
    -- On a 200-author library that takes the picker from ~1-2s to open down
    -- to ~tens of ms (the cache build, if cold) or single-digit ms (warm).
    local function open_group_picker(picker_kind, fetcher_kind, target_kind)
        local choices = Repo.getGroupChoices(fetcher_kind) or {}
        table.sort(choices, function(a, b) return a.label:lower() < b.label:lower() end)
        UIManager:close(d)
        pickById(picker_kind, choices, function(name)
            if not name then
                -- User tapped Close in the choose modal. Reopen the
                -- source picker so they can pick a different category
                -- without re-entering the editor's main dialog.
                Editor:_pickSource(draft, on_close)
                return
            end
            draft.source = { kind = target_kind, id = name }
            _applySourceDefaults(draft)
            on_close()
        end)
    end

    -- Specific-rating picker: a fixed list (1..5 stars + Unrated) rather
    -- than something derived from the library. Built inline because the
    -- option set is constant and tiny.
    local function open_rating_picker()
        local choices = {
            { value = "5",       label = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85" },
            { value = "4",       label = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85" },
            { value = "3",       label = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85" },
            { value = "2",       label = "\xE2\x98\x85\xE2\x98\x85" },
            { value = "1",       label = "\xE2\x98\x85" },
            { value = "unrated", label = _("Unrated") },
        }
        UIManager:close(d)
        pickById("rating", choices, function(picked)
            if not picked then
                Editor:_pickSource(draft, on_close)
                return
            end
            draft.source = { kind = "rating", id = picked }
            _applySourceDefaults(draft)
            on_close()
        end)
    end

    local function open_tag_picker()
        local ReadCollection = require("readcollection")
        local default_name = ReadCollection.default_collection_name
        local choices = {}
        for name, coll in pairs(ReadCollection.coll or {}) do
            -- Skip the built-in favourites collection: it has its own
            -- dedicated "★ Favourites" button at the top of the source
            -- picker. Showing it here too would be a duplicate entry that
            -- can't be edited or deleted as a regular collection.
            if name ~= default_name then
                local count = 0
                for _ in pairs(coll) do count = count + 1 end
                choices[#choices + 1] = {
                    value = name,
                    label = name,
                    count = count,
                }
            end
        end
        table.sort(choices, function(a, b) return a.label:lower() < b.label:lower() end)
        UIManager:close(d)
        pickById("collection", choices, function(picked)
            if not picked then
                Editor:_pickSource(draft, on_close)
                return
            end
            draft.source = { kind = "collection", id = picked }
            _applySourceDefaults(draft)
            on_close()
        end)
    end

    -- Folder picker: flat list of every directory under home_dir that
    -- contains a book at any depth. Each choice carries the full path as a
    -- subtitle (rendered by pickById's cell renderer) so duplicate basenames
    -- can be disambiguated. The picked path is the source id; getBySource
    -- prefix-matches it against book filepaths.
    local function open_folder_picker()
        local choices = Repo.getFolderChoices() or {}
        UIManager:close(d)
        pickById("folder", choices, function(picked)
            if not picked then
                Editor:_pickSource(draft, on_close)
                return
            end
            draft.source = { kind = "folder", id = picked }
            _applySourceDefaults(draft)
            on_close()
        end)
    end

    local function btn(kind_value, label, on_tap)
        local prefix = (draft.source.kind == kind_value) and "\xE2\x9C\x93 " or "  "
        return { text = prefix .. label, callback = on_tap or set_simple(kind_value) }
    end

    -- For the "specific" right-column buttons the check should also trip
    -- when the persisted source.kind matches that specific kind (e.g.
    -- collection / genre / author / single_series).
    local function specific_btn(picked_kind, label, on_tap)
        local prefix = (draft.source.kind == picked_kind) and "\xE2\x9C\x93 " or "  "
        return { text = prefix .. label, callback = on_tap }
    end

    local rows = {
        -- Row 1: the most-reached-for shortcuts — date-based plus the
        -- favourites curated shortcut. Favourites was previously on its
        -- own row but it's the same "curated shortcut" tier as Recent /
        -- Latest, so it earns the same row visually too.
        {
            btn("recent",    _("Recently read")),
            btn("latest",    _("Latest added")),
            btn("favorites", _("\xE2\x98\x85 Favourites")),  -- ★ Favourites
        },
        -- Row 2: full-library flattened view, full-width (no specific pair)
        {
            btn("library",   _("Home (flattened)")),
        },
        -- Row 3: folder pair -- Home (folders) browses the tree, the
        -- specific-picker pins one folder subtree as the chip target.
        {
            btn("all",       _("Home (folders)")),
            specific_btn("folder", _("Specific folder\xE2\x80\xA6"), open_folder_picker),
        },
        -- Rows 4+: browse-all on the left, specific-picker on the right
        {
            btn("series",    _("Series")),
            specific_btn("single_series", _("Specific series\xE2\x80\xA6"),
                function() open_group_picker("series", "series", "single_series") end),
        },
        {
            btn("authors",   _("Authors")),
            specific_btn("author", _("Specific author\xE2\x80\xA6"),
                function() open_group_picker("author", "author", "author") end),
        },
        {
            btn("genres",    _("Genres")),
            specific_btn("genre", _("Specific genre\xE2\x80\xA6"),
                function() open_group_picker("genre", "genre", "genre") end),
        },
        {
            btn("tags",      _("Collections")),
            specific_btn("collection", _("Specific collection\xE2\x80\xA6"), open_tag_picker),
        },
        {
            btn("formats",   _("Formats")),
            specific_btn("format", _("Specific format\xE2\x80\xA6"),
                function() open_group_picker("format", "format", "format") end),
        },
        {
            btn("ratings",   _("Ratings")),
            specific_btn("rating", _("Specific rating\xE2\x80\xA6"), open_rating_picker),
        },
        {
            btn("languages", _("Languages")),
            specific_btn("language", _("Specific language\xE2\x80\xA6"),
                function() open_group_picker("language", "language", "language") end),
        },
        -- Cancel row
        {
            { text = _("Cancel"), callback = function() UIManager:close(d); on_close() end },
        },
    }
    d = ButtonDialog:new{ title = _("Chip source"), buttons = rows }
    UIManager:show(d)
end
-- _pickStatusFilter -- multi-select picker for the reading-status filter.
-- draft.filter.statuses is a set keyed by status string; nil/empty = "any".
-- Each tap toggles the entry; re-opens the dialog so the checkmark updates.
function Editor:_pickStatusFilter(draft, on_close)
    draft.filter = draft.filter or {}
    draft.filter.statuses = draft.filter.statuses or {}
    local d

    local function toggle(value)
        if draft.filter.statuses[value] then
            draft.filter.statuses[value] = nil
        else
            draft.filter.statuses[value] = true
        end
        UIManager:close(d)
        Editor:_pickStatusFilter(draft, on_close)
    end

    -- "Any status" reads better than "Clear all": clearing the filter set
    -- is semantically equivalent to "match any status", so the label
    -- describes the resulting behaviour rather than the action's mechanism.
    local function any_checked()
        for _k in pairs(draft.filter.statuses) do return false end
        return true
    end
    local function is_on(v) return draft.filter.statuses[v] == true end
    local function btn(value, label, on_tap)
        local checked = (value == "__any__") and any_checked() or is_on(value)
        return { text = (checked and "\xE2\x9C\x93 " or "  ") .. label, callback = on_tap }
    end

    local rows = {
        -- Row 1: "Any status" (full width) -- selecting it clears all the
        -- individual status flags. Equivalent to the previous "Clear all"
        -- button but named for the resulting behaviour.
        {
            btn("__any__", _("Any status"), function()
                draft.filter.statuses = {}
                UIManager:close(d)
                Editor:_pickStatusFilter(draft, on_close)
            end),
        },
        -- Rows 2 & 3: status pairs. Each tap toggles and re-opens the
        -- modal so the checkmark refreshes.
        {
            btn("unread",   _("Unread"),  function() toggle("unread")  end),
            btn("reading",  _("Reading"), function() toggle("reading") end),
        },
        {
            btn("on_hold",  _("On hold"),  function() toggle("on_hold")  end),
            btn("finished", _("Finished"), function() toggle("finished") end),
        },
        -- Row 4: Done (full width)
        {
            { text = _("Done"), callback = function() UIManager:close(d); on_close() end },
        },
    }
    d = ButtonDialog:new{
        title   = _("Reading status filter"),
        buttons = rows,
    }
    UIManager:show(d)
end
-- _pickSortLevel -- single-level sort key picker.
-- Opens a ButtonDialog listing all sort keys. Tapping an already-selected key
-- toggles its reverse flag. Tapping "(none)" clears the slot.
-- level_index is 1 or 2 (Sort 1 / Sort 2); L3+ is preserved in the data
-- array but not exposed in the main editor dialog.
function Editor:_pickSortLevel(draft, level_index, on_close)
    local current = draft.sort_priority and draft.sort_priority[level_index]
    local d
    local kind = draft.source and draft.source.kind
    local is_group = GROUP_KINDS[kind or ""] or false

    -- Build a button for a sort key (with checkmark + reverse arrow). Second
    -- tap on the already-selected key toggles its reverse flag. The label
    -- comes from _resolveSortLabel so the editor's main Sort row and the
    -- picker row show the same text for the same key in the same context.
    -- The ↑ glyph appears only when the saved direction differs from this
    -- key's natural default -- consistent with how the editor's Sort row
    -- displays the same selection.
    local function key_btn(key_id)
        local selected = current and current.key == key_id
        local prefix   = selected and "\xE2\x9C\x93 " or "  "
        local is_inverted = selected
            and not _isDefaultDirection(key_id, current and current.reverse)
        local rev_suffix = is_inverted and " \xE2\x86\x91" or ""
        local lbl = _resolveSortLabel(level_index, key_id, kind)
        return {
            text     = prefix .. lbl .. rev_suffix,
            callback = function()
                draft.sort_priority = draft.sort_priority or {}
                local rev
                if selected then
                    rev = not (current and current.reverse)  -- toggle
                else
                    rev = DEFAULT_REVERSE[key_id] == true    -- natural default
                end
                draft.sort_priority[level_index] = { key = key_id, reverse = rev }
                UIManager:close(d); on_close()
            end,
        }
    end

    -- "Clear sort" removes this level's sort_priority entry (the old
    -- full-width "(none)" row, moved to a bottom-left button beside Close so
    -- the picker leads with the actual sort options). Checkmark shows when no
    -- sort is currently set for this level. Per-book tabs only -- group tabs
    -- deliberately have no clear option (a group view must have an order).
    local clear_btn = {
        text     = (not current and "\xE2\x9C\x93 " or "  ") .. _("Clear sort"),
        callback = function()
            if draft.sort_priority then
                table.remove(draft.sort_priority, level_index)
            end
            UIManager:close(d); on_close()
        end,
    }
    local close_btn = { text = _("Close"),
                        callback = function() UIManager:close(d); on_close() end }
    local close_row = { close_btn }

    local rows
    if is_group and level_index == 1 then
        -- Group tabs: level 1 orders the GROUP CARDS (author / genre /
        -- series stacks on the tab). Keys that have no data on group
        -- records are omitted -- only those whose comparator can read
        -- something useful from a group shape are exposed.
        --   * series_name        -> alphabetical by group display name
        --   * author_surname     -> Authors-tab surname extraction; falls
        --     back to series_name on other group tabs
        --   * book_count         -> #group.filepaths
        --   * last_opened        -> group.latest (max read time)
        --   * date_added         -> group.latest_added (max member mtime)
        --
        -- No (none) row at level 1 on group tabs: the whole point of a
        -- group view is to have an order, and the user can always tap a
        -- different option to switch. Compacts the picker to 3 rows.
        rows = {
            { key_btn("series_name"), key_btn("author_surname"), key_btn("book_count") },
            { key_btn("last_opened"), key_btn("date_added")    },
            close_row,
        }
    else
        -- Per-book tabs get the full 2-col layout. Pairs grouped by
        -- meaning (identity / author / series / time / progress); the
        -- numeric/size sorts (file size / page count / stack size) share
        -- the final 3-up row.
        rows = {
            { key_btn("title"),          key_btn("filename")          },
            { key_btn("author_surname"), key_btn("author_name")       },
            -- Series name / index / combined ("Series + #") share one row
            -- so the one-tap combined option sits beside the pair it merges.
            { key_btn("series_name"),    key_btn("series_index"),
              key_btn("series_combined") },
            { key_btn("last_opened"),    key_btn("date_added")        },
            { key_btn("percent_read"),   key_btn("rating")            },
            { key_btn("read_status"),    key_btn("read_status_active")},
            { key_btn("size"),           key_btn("page_count"),
              key_btn("book_count") },
            { clear_btn, close_btn },
        }
    end

    local title
    if is_group and level_index == 1 then
        title = _("Sort groups by")
    elseif is_group then
        title = _("Within each group, then by")
    elseif level_index == 1 then
        title = _("Sort by")
    else
        title = _("Then by")
    end
    d = ButtonDialog:new{
        title   = title,
        buttons = rows,
    }
    UIManager:show(d)
end
-- _pickIcon -- opens bookends's IconsLibrary if present, otherwise falls back
-- to a small built-in list of useful nerd-font glyphs. Selection writes the
-- glyph (UTF-8 string) into draft.icon; "(none)" clears it.
function Editor:_pickIcon(draft, on_close)
    -- Try bookends IconsLibrary first (richer picker with categories)
    local ok, IconsLibrary = pcall(require, "menu.icons_library")
    if ok and IconsLibrary and IconsLibrary.show then
        IconsLibrary:show(function(value)
            draft.icon = value and value ~= "" and value or nil
            on_close()
        end)
        return
    end
    -- Fallback: a curated short list of bookshelf-relevant glyphs.
    local FALLBACK_ICONS = {
        { glyph = nil,            label = _("(none)")        },
        { glyph = "\xE2\x98\x85", label = _("Star")          }, -- ★
        { glyph = "\xE2\x99\xA5", label = _("Heart")         }, -- ♥
        { glyph = "\xE2\x9C\x93", label = _("Check")         }, -- ✓
        { glyph = "\xE2\x96\xB6", label = _("Play")          }, -- ▶
        { glyph = "\xF0\x9F\x93\x96", label = _("Book")      }, -- 📖
        { glyph = "\xF0\x9F\x93\x9A", label = _("Books")     }, -- 📚
        { glyph = "\xF0\x9F\x94\x8D", label = _("Search")    }, -- 🔍
    }
    local d
    local buttons = {}
    for _i,opt in ipairs(FALLBACK_ICONS) do
        local prefix = (draft.icon == opt.glyph) and "\xE2\x9C\x93 " or "  "
        local display = opt.glyph and (opt.glyph .. "  " .. opt.label) or opt.label
        buttons[#buttons + 1] = {{
            text     = prefix .. display,
            callback = function()
                draft.icon = opt.glyph
                UIManager:close(d)
                on_close()
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text     = _("Close"),
        callback = function() UIManager:close(d); on_close() end,
    }}
    d = ButtonDialog:new{
        title   = _("Chip icon"),
        buttons = buttons,
    }
    UIManager:show(d)
end

return Editor
