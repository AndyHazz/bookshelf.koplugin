-- bookshelf_chip_editor.lua
-- Per-tab editor modal.
--   editTab(tab_id, opts)  -- open the editor for one tab directly.
--
-- Every change applies as it is made: it is saved (in memory, flushed when
-- the editor closes) and the shelf behind rebuilds, once per run of taps.
-- The editor closes with Close; there is no Save and no Cancel.
-- opts.on_change(info) is that rebuild (info.source_changed when the source
-- moved).
-- opts.bw is the BookshelfWidget instance; when present the dialog anchors
-- just below the chip strip so the strip stays visible.

local ButtonDialog   = require("ui/widget/buttondialog")
local ConfirmBox     = require("ui/widget/confirmbox")
local UIManager      = require("ui/uimanager")
local Geom           = require("ui/geometry")
local Size           = require("ui/size")
local Screen         = require("device").screen
local Space          = require("lib/bookshelf_space")

local TabModel = require("lib/bookshelf_tab_model")
local ViewMode = require("lib/bookshelf_view_mode")
local Filter   = require("lib/bookshelf_filter")
local logger   = require("logger")
local _        = require("lib/bookshelf_i18n").gettext
local T        = require("ffi/util").template

local Editor = {}

-- _highAnchor(get_dialog) -> an `anchor` function for ButtonDialog.
--
-- Puts the dialog HIGH on the screen, over the hero, so the shelf rows it is
-- about stay visible underneath. The shelf-style picker had this to itself;
-- every chip-editor picker now shares it, because the reason is the same
-- everywhere: a setting about the shelf is chosen by looking at the shelf
-- (maintainer request). get_dialog is a getter rather than the dialog because
-- the dialog does not exist yet when this is passed to its own constructor.
--
-- prefers_pop_down (the second return) is required: MovableContainer places
-- content ABOVE its anchor by default, which for a near-top anchor means
-- clamping back to y=0 and covering the status bar too.
--
-- EVERY FIELD A NUMBER, deliberately. MovableContainer fills in a missing
-- x/y/w/h -- centring horizontally when x is nil -- only since KOReader
-- v2026.07; v2026.03 and earlier read them raw, so a nil x arrives at
-- `if left < 0` in ensureAnchor and takes the whole app down. Release 4.2.0
-- did exactly that on opening the style picker. The centring the older
-- versions will not do for us is done here instead, which is also the same
-- placement on both.
local function _highAnchor(get_dialog)
    return function()
        local d  = get_dialog()
        -- The width comes off the LAID-OUT dialog: MovableContainer sets its
        -- dimen from the content size on the line before it evaluates the
        -- anchor, so by now it is the real rendered width. ButtonDialog's own
        -- `width` is the fallback -- that is the width it ASKED for, which a
        -- scrollable dialog can exceed.
        local mv = d and d.movable
        local dw = (mv and mv.dimen and mv.dimen.w) or (d and d.width) or 0
        return {
            -- Not clamped to 0: ensureAnchor already does `if left < 0 then
            -- left = 0`, and clamping here first would instead trip its
            -- `left + content_w > screen_w` branch, hanging a too-wide dialog
            -- off the LEFT edge (title first) rather than the right.
            x = math.floor((Screen:getWidth() - dw) / 2),
            y = Space.px(96),
            -- w matches the dialog so a mirrored (RTL) layout, which takes the
            -- other branch (left = x + w - content_w), lands on that same
            -- centred x instead of a dialog's width to the left of it. h stays
            -- 0: with prefers_pop_down the top edge is y + h, and y is already
            -- where we want the top.
            w = dw,
            h = 0,
        }, true
    end
end

-- _shownMode(value, no_spines) -> a stored style as the shelf shows it. A
-- catalogue (OPDS, or a source that fetches its own pages) has no spines,
-- and shows a spines pin set before its source changed as covers, the
-- default; the pin is kept for a source that can show it again.
function Editor._shownMode(value, no_spines)
    local v = ViewMode.chipOverride(value)
    if no_spines and v == ViewMode.SPINES then return nil end
    return v
end

-- The chip's view-mode pin, as words. lib/bookshelf_view_mode.lua deliberately
-- holds no strings and no gettext -- it is a pure resolver, testable headless --
-- so the wording lives here, where every other chip-editor label already does.
-- nil when the chip has no mode of its own: a caller that wants a word for
-- that supplies it.
function Editor._chipModeLabel(value)
    local v = ViewMode.chipOverride(value)
    if v == ViewMode.LIST   then return _("List")   end
    if v == ViewMode.COVERS then return _("Covers") end
    if v == ViewMode.AUTO   then return _("Auto")   end
    if v == ViewMode.SPINES then return _("Spines") end
    return nil
end

-- _modeIcon(value, no_spines) -> the View mode card's icon: the look the
-- shelf has (maintainer). No mode of its own is Covers, the default.
function Editor._modeIcon(value, no_spines)
    local v = Editor._shownMode(value, no_spines)
    if v == ViewMode.LIST then return "\u{EC71}" end     -- view-list
    if v == ViewMode.SPINES then return "\u{EE26}" end   -- view-parallel
    if v == ViewMode.AUTO then return "\u{EC6D}" end     -- view-dashboard
    return "\u{EC72}"                                    -- view-module
end

-- Per-key default sort direction. Picking one of these auto-sets the
-- matching reverse flag; the Sort card names the direction only when the
-- saved one differs from this default ("Title (Z-A)", but plain "Title").
local DEFAULT_REVERSE = {
    book_count   = true,
    last_opened  = true,
    date_added   = true,
    added_or_opened = true,
    -- "Progress" sort defaults to highest-progress-first: a user picking
    -- "Sort by progress" usually wants to see books they're furthest
    -- through (or finished) at the top. Ascending (unread first) is the
    -- niche choice -- still reachable via the picker's toggle.
    percent_read = true,
    -- Rating sort defaults to highest-first, matching the Ratings stack
    -- default and the usual "show my best-rated books at the top" intent.
    rating       = true,
    -- Publication year: newest first, like the other dates.
    published    = true,
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
    -- Flattened folder (#76): a recursive book list with no folder cards,
    -- so it sorts like "library" (Home flattened) rather than by filename.
    folder_flat   = { { key = "author_surname",  reverse = false },
                      { key = "series_name",     reverse = false },
                      { key = "series_index",    reverse = false } },
    -- A collection is the one book source with an order of its own: KOReader
    -- stores a per-item `order` and files the collection by it. Level two
    -- carries the collections it stores no order for -- only a manually
    -- collated one persists it -- where every book ties on level one and the
    -- shelf comes out as it always did (issue 441).
    collection    = { { key = "collection_order", reverse = false },
                      { key = "last_opened",      reverse = true  } },
    -- NOT collection_order, although a pinned tag chip is also kind
    -- "collection": the id is a tag name, there is rarely a KOReader
    -- collection behind it, and a tag has no curated order to preserve.
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
    -- OPDS catalogue: the feed's own order is authoritative (it may encode
    -- the remote library's curation -- "recently added", a shelf order,
    -- etc.) and this plugin has no independent metadata to re-sort by
    -- until books are actually fetched. Empty list means "no sort levels",
    -- not "fall through to an engine default" -- see _applySourceDefaults.
    opds          = {},
    -- Shelf of shelves: its shelves stand in the order they were added (and
    -- moved), like chips in the strip. No sort levels, as for OPDS.
    shelves       = {},
}
-- A registered source (lib/bookshelf_sources) brings its own default. The
-- Kindle's is title rather than filename: its files are named things like
-- "01. The Colour of Magic - Terry Pratchett_127FE891….kfx", so a filename sort
-- would look arbitrary next to the titles on screen.
setmetatable(SOURCE_SORT_DEFAULTS, { __index = function(_t, kind)
    local spec = require("lib/bookshelf_sources").get(kind)
    return spec and type(spec.sort_default) == "table" and spec.sort_default or nil
end })

-- _resolveOpdsTitle(id): the configured title for an OPDS server key, or nil
-- if bookshelf_opds_source can't be loaded or the server has since been
-- removed from the stock plugin's list. pcall-guarded because the source
-- file is plugin-owned (see bookshelf_opds_source.lua's header) and this
-- editor must degrade gracefully rather than error if it's ever malformed.
local function _resolveOpdsTitle(id)
    if not id or id == "" then return nil end
    local ok, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
    if not ok or not OpdsSource then return nil end
    local ok2, server = pcall(OpdsSource.getServer, id)
    if ok2 and server and server.title then return server.title end
    return nil
end

-- Editor.sourceSortDefaults(kind) -> a fresh { {key, reverse}, ... }, or nil.
--
-- Public because chips are created in more than one place: the collection
-- manager pins one straight into the tab list without building a draft, and
-- carrying its own copy of the collection default is how the two drifted.
-- Always a copy -- the caller stores it on a tab the reader then edits, and a
-- reference would let a toggled `reverse` rewrite the default for every chip
-- made afterwards.
function Editor.sourceSortDefaults(kind)
    local defaults = kind and SOURCE_SORT_DEFAULTS[kind]
    if not defaults then return nil end
    local copy = {}
    for i, level in ipairs(defaults) do
        copy[i] = { key = level.key, reverse = level.reverse }
    end
    return copy
end

local function _applySourceDefaults(draft)
    local kind = draft.source and draft.source.kind
    local copy = Editor.sourceSortDefaults(kind)
    if copy then
        draft.sort_priority = copy
    end
    -- A registered source can have the last word on a new shelf's defaults
    -- (the Kindle's filters out formats KOReader cannot open).
    local Sources = require("lib/bookshelf_sources")
    local src_spec = kind and Sources.get(kind)
    if src_spec and src_spec.new_shelf then Sources.call(src_spec, "new_shelf", draft) end
    -- QoL: if the chip's label is still the default "New shelf" (i.e.
    -- the user hasn't customised it), rename it to match the picked
    -- source — e.g. picking "Genres" sets the label to "Genres",
    -- picking a specific author sets it to that author's name. Only
    -- the untouched default is replaced; user-edited labels are
    -- preserved as-is.
    -- "New chip" was this sentinel's wording before the shelf rename. A tab
    -- saved under the old name still carries that literal label, so accept it
    -- too or those chips silently lose the auto-rename. English only: a
    -- translated old label cannot be recognised without keeping the retired
    -- msgid alive purely to compare against, which is not worth a string in
    -- every locale for a label the reader can change in two taps.
    if (draft.label == _("New shelf") or draft.label == "New chip")
            and draft.source then
        local fresh
        if draft.source.id and draft.source.id ~= "" then
            -- Specific-X sources (folder, single_series, etc.): use the
            -- id as the label, with folder basename special-cased so
            -- long paths don't blow out the chip pill.
            if draft.source.kind == "folder" or draft.source.kind == "folder_flat" then
                fresh = draft.source.id:match("([^/]+)/?$") or draft.source.id
            elseif draft.source.kind == "opds" then
                -- The id is an opaque server-key hash (bookshelf_opds_source's
                -- djb2 digest of the feed URL), not human-readable -- use the
                -- configured title instead, falling back to the raw key only
                -- if the server has since vanished.
                fresh = _resolveOpdsTitle(draft.source.id) or draft.source.id
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
--
-- `series_name` is not only the series key: the sort engine uses that field
-- as the GROUP CARD's name for every group shape (see its comment at
-- "5. b.series_name -- group shape (Authors / Genres tab)"). So one label
-- covered both a thing's name and a PERSON's, and English is unusually
-- relaxed about that. Slovak is not -- meno for a person, nazov for a thing --
-- and nor are Czech, Polish, Russian, Ukrainian or German, so a translator
-- had to pick one and be wrong elsewhere (issue 432, from the Slovak
-- translator reviewing the catalogue).
--
-- Split by what is being named rather than per tab: the Authors shelf is the
-- only group whose cards are people, and "Full name" pairs with the Surname
-- option sitting next to it. Everything else is a thing and keeps "Name",
-- which is now unambiguous because the collection dialog no longer shares it.
local GROUP_LEVEL1_NAME_BY_KIND = {
    authors = function() return _("Full name") end,
}
local GROUP_LEVEL1_LABEL = {
    series_name    = function(kind)
        local person = GROUP_LEVEL1_NAME_BY_KIND[kind or ""]
        if person then return person() end
        return _("Name")
    end,
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
    favorites     = function() return _("Favorites")          end,
    -- "Specific X" kinds carry an id; the resolver appends it.
    folder        = function() return _("Folder")             end,
    folder_flat   = function() return _("Folder (flattened)")  end,
    collection    = function() return _("Collection")         end,
    tag           = function() return _("Collection")         end,
    genre         = function() return _("Genre")              end,
    author        = function() return _("Author")             end,
    single_series = function() return _("Series")             end,
    status        = function() return _("Status")             end,
    format        = function() return _("Format")             end,
    rating        = function() return _("Rating")             end,
    language      = function() return _("Language")           end,
    -- No id yet (picker not used, or the source table was hand-built):
    -- generic fallback. Once an id is present _resolveSourceLabel takes
    -- the "OPDS: <title>" branch instead of this one.
    opds          = function() return _("OPDS catalog")       end,
    -- A shelf holding other shelves (5.4), each with its own source.
    shelves       = function() return _("Shelf of shelves") end,
    -- A shelf being created, before a source is picked (TabModel.newTab).
    none          = function() return _("(none)") end,
}
-- A registered source (lib/bookshelf_sources: the Kindle's own library, a
-- plugin's) names itself.
setmetatable(SOURCE_LABEL, { __index = function(_t, kind)
    local Sources = require("lib/bookshelf_sources")
    if not Sources.get(kind) then return nil end
    return function() return Sources.label(kind) or kind end
end })

-- _resolveSourceLabel(source): display string for "Source: <label>".
-- For built-in kinds returns just the label ("Recently read"). For
-- specific-X kinds returns "<Category>: <id>" so the user can see at
-- a glance which author / series / folder / etc. is selected.
local function _resolveSourceLabel(source)
    if not source or not source.kind then return _("(none)") end
    if source.kind == "opds" and source.id and source.id ~= "" then
        -- Distinct "OPDS: <title>" shape rather than the generic
        -- "<Category>: <id>" below -- the id is an opaque hash key, not
        -- something worth showing to the user; the title is what they
        -- recognise. Falls back to the raw key if the server has since
        -- been removed from the stock plugin's list.
        return T(_("OPDS: %1"), _resolveOpdsTitle(source.id) or source.id)
    end
    local fn = SOURCE_LABEL[source.kind]
    local label = fn and fn() or source.kind
    if source.id and source.id ~= "" then
        -- For folder paths, show the basename to keep the row tidy --
        -- "/mnt/us/Calibre/library/Pratchett" reads worse than "Pratchett".
        local id = source.id
        if source.kind == "folder" or source.kind == "folder_flat" then
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
        -- kind is passed through: the name label depends on whether the
        -- cards are people or things (issue 432).
        return GROUP_LEVEL1_LABEL[key](source_kind)
    end
    local SortEngine = require("lib/bookshelf_sort_engine")
    local k = SortEngine.KEYS[key]
    return (k and (k.short or k.label)) or key
end

-- editTab(tab_id, opts) -- modal editor for one tab.
-- opts = { on_change = function(info) end, bw = <BookshelfWidget>,
--          pick_source_first = bool, on_discard = function() end }
-- _deepCopy(v) / _sameValue(a, b): for the plain values a shelf record holds
-- (strings, numbers, booleans and tables of them).
function Editor._deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Editor._deepCopy(x) end
    return out
end

-- An empty table is the same as none: opening a filter's picker gives the
-- working copy an empty set, which is no change.
local function blank(t)
    for _k, v in pairs(t) do
        if type(v) ~= "table" or not blank(v) then return false end
    end
    return true
end

function Editor._sameValue(a, b)
    local ta, tb = type(a) == "table", type(b) == "table"
    if ta and tb then
        for k, x in pairs(a) do if not Editor._sameValue(x, b[k]) then return false end end
        for k, y in pairs(b) do
            if a[k] == nil and not Editor._sameValue(nil, y) then return false end
        end
        return true
    end
    if ta and b == nil then return blank(a) end
    if tb and a == nil then return blank(b) end
    return a == b
end

-- _menu(spec) -> a sub-menu (ButtonDialog's options). While a shelf
-- editor is open it is a page inside the editor (Editor._host: a heading
-- and a back chevron, the rows as the editor's cards), not a dialog over
-- it; otherwise a ButtonDialog, shown. _closeMenu(d) closes either.
function Editor._menu(spec)
    if Editor._host then return Editor._host.push(spec) end
    if spec.page then
        -- No editor up to hold it: the page's blocks as a ButtonDialog,
        -- reopened to show a change.
        local holder = { _fallback = true }
        local function open()
            local rows = require("lib/bookshelf_editor_page").toButtons(spec.page())
            rows[#rows + 1] = { { text = _("Back"), callback = function()
                UIManager:close(holder.d)
                if spec.on_back then spec.on_back() end
            end } }
            holder.d = require("ui/widget/buttondialog"):new{ title = spec.title,
                buttons = rows, tap_close_callback = spec.on_back }
            UIManager:show(holder.d)
        end
        function holder:refresh() UIManager:close(holder.d); open() end
        open()
        return holder
    end
    local d = require("ui/widget/buttondialog"):new(spec)
    UIManager:show(d)
    return d
end

-- _over(tail) -> a LibraryModal's config.over while the editor is up, so a
-- picker opens as a page of it (its breadcrumb + tail), else nil.
function Editor._over(tail)
    local host = Editor._host
    if not (host and host.rect and host.rect()) then return nil end
    return { rect = host.rect, crumbs = host.crumbs(tail), on_exit = host.exit }
end

function Editor._closeMenu(d)
    if type(d) == "table" and d._fallback then
        if d.d then UIManager:close(d.d) end
        return
    end
    if type(d) == "table" and d._page then
        if Editor._host then Editor._host.close(d) end
        return
    end
    if d then UIManager:close(d) end
end

function Editor:editTab(tab_id, opts)
    opts = opts or {}
    local target
    for _i, t in ipairs(TabModel.load()) do
        if t.id == tab_id then target = t; break end
    end
    if not target then return end

    -- The shelf being edited, as a working copy. Every change lands on the
    -- saved shelf as it is made (commit, below): there is no Save and no
    -- Cancel any more, only Close (maintainer, after the 5.4 tutorial: "make
    -- that all apply on selection and change Save to Close"). A copy rather
    -- than the stored record itself so a change can still be refused before it
    -- lands (a shelf of shelves' source, sourceChosen) and so the pickers,
    -- which edit it in place, never leave half a change in the settings table.
    -- Deep: a registered source's editor buttons edit tables inside
    -- draft.source.
    local draft = Editor._deepCopy(target)
    -- Ensure required nested tables exist even if a legacy schema is missing them.
    draft.filter        = draft.filter        or {}
    draft.sort_priority = draft.sort_priority or {}
    draft.source        = draft.source        or { kind = tab_id }

    -- One-time schema migration: tab.icon used to be a separate field.
    -- Now label may contain inline nerd-font glyphs. If the persisted tab
    -- still has an icon field, fold it into the front of the label so the
    -- editor presents one unified string. The first change written locks the
    -- migration in (the chip strip falls back on the legacy field meanwhile).
    if draft.icon and draft.icon ~= "" then
        draft.label = draft.icon .. " " .. (draft.label or "")
        draft.icon  = nil
    end

    -- What the saved shelf holds: the working copy as last committed, which a
    -- refused change goes back to.
    local committed = Editor._deepCopy(draft)

    -- A shelf being created (TabModel.newTab) has no source until one is
    -- picked, and stays `pending` until then. Closing the editor while it
    -- still has none removes it and hands back to opts.on_discard (the shelf
    -- the reader came from); once it has one it is an ordinary shelf.
    local is_new = target.pending == true
    -- The settings' generation as the editor opened: closing writes the
    -- file only when something moved it (~130 ms a write on a PW5).
    local gen_at_open = require("lib/bookshelf_settings_store").generation()
    local function hasSource()
        return draft.source ~= nil and draft.source.kind ~= TabModel.NO_SOURCE
    end
    local dialog   -- the editor window, built below; discardNew closes it
    local closed = false   -- once, whichever way the editor is left

    -- THE SHELF BEHIND follows every change, on a rebuild DEFERRED and
    -- coalesced. A rebuild inside the tap (several hundred milliseconds on a
    -- Kindle in spine mode) held the picker up, and taps in that window were
    -- dropped ("there's a lag after tapping one where tapping another does
    -- nothing"). Lua has one thread, so the work cannot move off it; it can
    -- move AFTER the tap: armed for PREVIEW_DEBOUNCE_S after the LAST change,
    -- run at once by the close paths (finish) if it is still owed. A source,
    -- filter or sort change is one change and one rebuild: those pickers hand
    -- back when the reader leaves them, not per tap inside them.
    local PREVIEW_DEBOUNCE_S = 0.4
    local owed, owed_info = false, {}
    local function firePreview()
        if not owed then return end
        owed = false
        local info = owed_info
        owed_info = {}
        if opts.on_change then opts.on_change(info) end
    end
    local function schedulePreview()
        owed = true
        UIManager:unschedule(firePreview)
        UIManager:scheduleIn(PREVIEW_DEBOUNCE_S, firePreview)
    end
    -- A close path: the rebuild still owed, now. Or not at all (drop).
    local function settlePreview(drop)
        UIManager:unschedule(firePreview)
        if drop then owed = false; owed_info = {} else firePreview() end
    end

    -- dropShelves(tabs): delete this shelf's shelves from `tabs`, in place.
    local function dropShelves(tabs)
        for _i, kid in ipairs(TabModel.childrenOf(tab_id, tabs)) do
            TabModel.removeTree(tabs, kid.id)
        end
    end

    -- commit([drop_shelves]): write the working copy onto the saved shelf and
    -- arm the rebuild. In memory only (saveDeferred): a tap on a nudge must
    -- not wait for a settings flush, hundreds of milliseconds on a Kindle. The
    -- editor flushes once, as it closes (finish), which is the action
    -- boundary. A source change (or a source's own list / sort choice) tells
    -- the shelf, so a folder drilled into under the old one is left.
    local function commit(drop_shelves)
        if draft.pending and hasSource() then draft.pending = nil end
        -- Back from a page that changed nothing (Filters, a picker opened
        -- and left): no write, no rebuild of the shelf.
        if Editor._sameValue(draft, committed) then return end
        local save_tabs = TabModel.load()
        for i, t in ipairs(save_tabs) do
            if t.id == tab_id then
                if not Editor._sameValue(t.source, draft.source) then
                    owed_info.source_changed = true
                end
                save_tabs[i] = Editor._deepCopy(draft)
                break
            end
        end
        if drop_shelves then dropShelves(save_tabs) end
        -- The shelf's own settings changed: what it fetches, or how it lays
        -- out its pages, may have (the shelf drops its fetch cache). Shelf
        -- order changes neither and does not come through here.
        owed_info.fetch_changed = true
        TabModel.saveDeferred(save_tabs)
        committed = Editor._deepCopy(draft)
        schedulePreview()
    end
    -- revert(): put the working copy back to what is saved, in place (the
    -- pickers hold it by reference).
    local function revert()
        for k in pairs(draft) do draft[k] = nil end
        for k, v in pairs(Editor._deepCopy(committed)) do draft[k] = v end
    end

    local function discardNew()
        closed = true
        settlePreview(true)
        local tabs = TabModel.load()
        TabModel.removeTree(tabs, tab_id)
        TabModel.save(tabs)
        if dialog then UIManager:close(dialog) end
        if opts.on_discard then opts.on_discard()
        elseif opts.on_change then opts.on_change() end
    end

    -- finish(): Close, the title bar X, a tap outside and Back all end here.
    -- Each change is saved as it is made; what can be left is a filter's
    -- ticks, left by the X before its Apply: kept, as Back keeps them. Then
    -- the flush, and the shelf's rebuild if the last change has not had it
    -- yet. A new shelf that never got a source is not kept (see is_new).
    local function finish()
        if closed then return end
        if is_new and not hasSource() then return discardNew() end
        if not Editor._sameValue(draft, committed) then commit() end
        closed = true
        UIManager:close(dialog)
        if require("lib/bookshelf_settings_store").generation() ~= gen_at_open then TabModel.flush() end
        settlePreview()
    end

    -- The shelf's name as a picker row shows it: [icon=...] markup off.
    local function plainName(t)
        local l = type(t.label) == "string" and t.label or ""
        l = l:gsub("%[icon=[^%]]*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        return l ~= "" and l or t.id
    end

    -- leaveFor(id): this editor's changes are saved; close it and show `id`
    -- wherever it now sits (the shelf menu or inside a shelf of shelves).
    local function leaveFor(id)
        closed = true
        settlePreview(true)
        TabModel.flush()
        UIManager:close(dialog)
        if opts.bw and opts.bw._openShelf then
            opts.bw:_openShelf(id)
        elseif opts.on_change then
            opts.on_change()
        end
    end

    -- copyShelf(): a copy of this shelf, everything in it included (a shelf
    -- of shelves' own shelves, a Shelf module's own shelf), right after it,
    -- opened in its editor so the one thing to change is a tap away.
    local function copyShelf()
        if closed then return end
        TabModel.flush()
        local tabs = TabModel.load()
        local new_id = TabModel.copyTree(tabs, tab_id, T(_("%1 (copy)"), plainName(draft)))
        if not new_id then return end
        TabModel.save(tabs)
        leaveFor(new_id)
        -- This editor's opts, less what belonged to a NEW shelf: the copy
        -- has its source already, and backing out keeps it.
        local copy_opts = {}
        for k, v in pairs(opts) do
            if k ~= "pick_source_first" and k ~= "on_discard" then copy_opts[k] = v end
        end
        Editor:editTab(new_id, copy_opts)
    end

    -- editOther(id): Shelf order's pencil. This editor closes as Close does
    -- (a new shelf with no source is not kept) and id's opens, on id's shelf
    -- as Copy's does, so its changes show behind it.
    local function editOther(id)
        if closed then return end
        local other = {}
        for k, v in pairs(opts) do
            if k ~= "pick_source_first" and k ~= "on_discard" then other[k] = v end
        end
        if is_new and not hasSource() then discardNew() else leaveFor(id) end
        Editor:editTab(id, other)
    end

    -- canMove(): somewhere to go -- a shelf of shelves other than this one
    -- and its own, or the shelf menu when it sits inside one.
    local function canMove()
        if draft.card_only then return false end
        local targets = TabModel.moveTargets(TabModel.load(), tab_id)
        return #targets > 1 or draft.parent ~= nil
    end

    -- moveShelf(): pick where it goes: the shelf menu, or any shelf of
    -- shelves it is not already in (and not one inside it). Where it is now
    -- is ticked and greyed.
    local function moveShelf()
        if closed then return end
        local targets = TabModel.moveTargets(TabModel.load(), tab_id)
        local picker
        local function moveTo(t)
            return function()
                Editor._closeMenu(picker)
                TabModel.flush()
                local tabs = TabModel.load()
                if not TabModel.moveTree(tabs, tab_id, t.id) then return end
                TabModel.save(tabs)
                leaveFor(tab_id)
            end
        end
        -- A page: where the shelf is now (black, nothing to do) and where it
        -- can go, the shelf menu first, then each shelf of shelves.
        picker = Editor._menu{
            title = _("Move to"),
            page = function()
                local here_name
                local top, inside = {}, {}
                for _i, t in ipairs(targets) do
                    local here = (t.id == draft.parent)
                    local name = t.id and plainName(t) or _("Shelf menu")
                    -- In the sentence, "Now in the shelf menu", not "Now in
                    -- Shelf menu" (the option's own label).
                    if here then here_name = t.id and name or _("the shelf menu") end
                    local b = { type = "option", text = name, on = here,
                        icon = t.id and "\u{EA30}" or nil,   -- library: a shelf of shelves
                        callback = (not here) and moveTo(t) or nil }
                    if t.id then b.half = true; inside[#inside + 1] = b else top[#top + 1] = b end
                end
                local blocks = {}
                for _i, b in ipairs(top) do blocks[#blocks + 1] = b end
                if #inside > 0 then
                    blocks[#blocks + 1] = { type = "heading", text = _("Into a shelf of shelves") }
                    for _i, b in ipairs(inside) do blocks[#blocks + 1] = b end
                end
                return { strip = { { type = "summary", text = here_name
                    and T(_("Now in %1. Tap where it should go."), here_name)
                    or _("Tap where it should go.") } }, blocks = blocks }
            end,
        }
    end

    -- A confirmed arrangement of the collection, from the sort picker's "Edit
    -- collection order". Not shelf state: it is written to KOReader the moment
    -- it is confirmed (and drops the book cache itself), so all the editor owes
    -- it is the shelf's rebuild, the same deferred one any change gets
    -- (maintainer, on the PW5: the shelf behind shows it when the arrange
    -- window closes, not only once the editor is closed).
    --
    -- Declared below schedulePreview: a local function resolves the names in
    -- its body where it is written, so above that point schedulePreview would
    -- be a nil global at the moment of the confirm.
    local function onArranged()
        -- A new order is a new fetch (the shelf's cache goes).
        owed_info.fetch_changed = true
        schedulePreview()
    end

    -- sourceChosen(): the source picker has handed back. Nothing picked is
    -- nothing to do. A shelf of shelves given another source would keep its
    -- shelves but never show them again -- nothing else lists a sub-shelf, so
    -- they could be neither reached nor deleted -- so that change ASKS first,
    -- and deletes them with it; refused, the shelf keeps its source. Anything
    -- else applies at once: one change, one fetch.
    local rebuild   -- the dialog's own redraw, defined below
    local function sourceChosen()
        -- The source it already has: the picker ran its defaults on the
        -- working copy (the sort), which is put back, or the card would show
        -- a sort that is not saved and the next change would save it.
        if Editor._sameValue(draft.source, committed.source) then revert(); rebuild(); return end
        if draft.source.kind ~= TabModel.SHELVES_KIND
                and #TabModel.childrenOf(tab_id) > 0 then
            UIManager:show(ConfirmBox:new{
                text        = _("Changing this shelf's source deletes the shelves inside it. This cannot be undone."),
                ok_text     = _("Change"),
                ok_callback = function() commit(true); rebuild() end,
                -- Cancel, a tap outside, Back.
                cancel_callback = function() revert(); rebuild() end,
            })
            return
        end
        commit()
        rebuild()
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

    -- `dialog` is declared above, with discardNew, which closes it.
    local frame
    local current_bt   -- the ButtonTable on screen; rebuilt on every edit
    -- The keys' cursor across rebuilds (Kit.keyFocus): where it is, and
    -- whether the first key has shown it yet.
    local key_state = {}

    -- editorRefresh() -> "ui" over the editor's own box, for setDirty to
    -- resolve after the paint. With no region a "ui" covers the whole screen,
    -- and UIManager merges it with the flashui of a picker closing over the
    -- editor (Filters, Shelf style) into one whole-screen flash (maintainer,
    -- PW5). frame.dimen moves with each paint but keeps its first size, so
    -- the box is the larger of that and the size now: the editor is anchored
    -- at its top, so that covers it both grown and shrunk.
    local function editorRefresh()
        local d = frame and frame.dimen
        if not d then return "ui" end
        local size = frame:getSize()
        return "ui", Geom:new{ x = d.x, y = d.y,
                               w = math.max(d.w, size.w), h = math.max(d.h, size.h) }
    end

    -- markDirty(): repaint the editor after frame[1] changed. When it came out
    -- smaller (a short page after a long one), what it covered and no longer
    -- does is repainted from the windows underneath, or the old rows stay on
    -- screen below it; and frame.dimen is dropped so a tap outside is judged
    -- by the new size.
    local last_rect
    local function markDirty()
        if not (dialog and UIManager:isWidgetShown(dialog)) then return end
        local d = frame.dimen
        local size = frame:getSize()
        if d and d.x then
            local now = { x = d.x, y = d.y, w = size.w, h = size.h }
            -- Before the first change: the size it was first painted at.
            local prev = last_rect or { x = d.x, y = d.y, w = d.w, h = d.h }
            if prev and (prev.h > now.h or prev.w > now.w) then
                UIManager:setDirty("all", "ui", Geom:new{ x = prev.x, y = prev.y, w = prev.w, h = prev.h })
            end
            if prev and (prev.h ~= now.h or prev.w ~= now.w) then
                frame.dimen = nil
                -- The window keeps its first size too, and a drag refreshes
                -- that box: a page taller than the front one left its foot
                -- (the pager) behind on e-ink (maintainer, PW5).
                local mv = dialog.movable
                if mv and mv.dimen then mv.dimen.w, mv.dimen.h = size.w, size.h end
            end
            last_rect = now
        end
        UIManager:setDirty(dialog, editorRefresh)
    end

    -- rebuild() -- swap frame[1] in-place so the button labels and enabled
    -- states refresh without touching the MovableContainer. The anchor-based
    -- positioning set on first paint is therefore preserved across rebuilds.
    -- Declared above, with sourceChosen, which calls it.
    -- ── The popup style pieces (STYLE.md), for the editor's front page and
    -- for its sub-menus, which open as pages inside it (Editor._menu). ──────
    local Kit = require("lib/bookshelf_popup_kit")
    local FocusManager = require("ui/widget/focusmanager")
    local TextWidget = require("lib/bookshelf_colour_text")
    local Font = require("ui/font")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan = require("ui/widget/verticalspan")
    local FS = 20
    local inset = Space.px(16)
    local content_w = dialog_w - 2 * inset
    local function cellText(c)
        if c.text_func then return c.text_func() end
        return c.text or ""
    end
    local function cellEnabled(c)
        if c.enabled_func then return c.enabled_func() end
        return c.enabled ~= false
    end
    -- card(c, w, as_choice) -> body, pad, enabled, on. "Heading: value"
    -- splits into a grey heading over the value. A leading tick (or radio
    -- dot) is a checkbox on the front page; on a sub-menu's page it marks
    -- the choice in use, which is black (as_choice).
    local value_face = require("lib/bookshelf_fonts"):getFace("cfont", FS)
    local CHECKED, UNCHECKED = "\xEE\xA0\xB1", "\xEE\xA0\xB0"
    local function card(c, w, as_choice)
        local text = cellText(c)
        local enabled = cellEnabled(c)
        local pad = Space.px(12)
        local inner_w = w - 2 * pad
        local icon
        local glyph = c.icon_func and c.icon_func() or c.icon
        if glyph then
            -- What the card is about, at a glance (Source, Filters, Sort...).
            icon = TextWidget:new{ text = glyph, face = Font:getFace("symbols", FS + 6),
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY }
            inner_w = inner_w - icon:getSize().w - Space.px(14)
        end
        local tick = text:match("^\xE2\x9C\x93%s+(.*)$") or text:match("^\xE2\x97\x8F%s+(.*)$")
        -- Unticked: a hollow dot, or blank padding (spaces, or an em space
        -- as Face out pads its labels).
        local untick = not tick and (text:match("^\xE2\x97\x8B%s+(.*)$") or text:match("^%s%s+(.*)$")
            or text:match("^\xE2\x80\x83%s*(.*)$"))
        local on = as_choice and tick ~= nil
        local ink = (on and Blitbuffer.COLOR_WHITE)
            or (enabled and Blitbuffer.COLOR_BLACK) or Blitbuffer.COLOR_DARK_GRAY
        if as_choice then text = tick or untick or text end
        local body
        if not as_choice and (tick or untick) then
            body = HorizontalGroup:new{ align = "center",
                TextWidget:new{ text = tick and CHECKED or UNCHECKED,
                    face = Font:getFace("symbols", FS + 4), fgcolor = ink },
                HorizontalSpan:new{ width = Space.px(8) },
                TextWidget:new{ text = tick or untick, face = value_face, fgcolor = ink,
                    max_width = inner_w - Space.px(40) } }
        else
            local head, value = text:match("^(.-):%s+(.+)$")
            if head and #head <= 24 then
                -- The icon beside the heading on a line of their own, the
                -- value under them across the card's whole width, as the
                -- editor's pages show a row too long for one line
                -- (maintainer).
                icon = nil
                body = VerticalGroup:new{ align = "left",
                    Kit.iconHeading(glyph, head, FS, ink),
                    VerticalSpan:new{ width = Space.px(4) },
                    TextWidget:new{ text = value, face = value_face, bold = true,
                        fgcolor = ink, max_width = w - 2 * pad } }
            else
                body = TextWidget:new{ text = text, face = value_face, bold = not as_choice or on,
                    fgcolor = ink, max_width = inner_w }
            end
        end
        if icon then
            body = HorizontalGroup:new{ align = "center", icon,
                HorizontalSpan:new{ width = Space.px(14) }, body }
        end
        return body, pad, enabled, on
    end
    -- buildCards(rows, layout, as_choice) -> the rows as cards (a row of
    -- notes only, nothing to tap, as grey hint text); each row's cards are
    -- added to layout for the keys.
    local function buildCards(rows, layout, as_choice)
        local rows_vg = VerticalGroup:new{ align = "left" }
        local gap = Space.px(10)
        -- A row whose cards would each be too narrow (a small screen) stacks
        -- them full width (maintainer).
        local stacked = {}
        for _i, row in ipairs(rows) do
            local n = #row
            if n > 1 and (content_w - (n - 1) * gap) / n < Screen:scaleBySize(160) then
                for _j, c in ipairs(row) do stacked[#stacked + 1] = { c } end
            else
                stacked[#stacked + 1] = row
            end
        end
        rows = stacked
        for ri, row in ipairs(rows) do
            if ri > 1 then rows_vg[#rows_vg + 1] = VerticalSpan:new{ width = gap } end
            local all_notes = true
            for _i, c in ipairs(row) do
                if c.callback or cellEnabled(c) then all_notes = false end
            end
            if all_notes then
                local t = {}
                for _i, c in ipairs(row) do t[#t + 1] = cellText(c) end
                rows_vg[#rows_vg + 1] = Kit.hintText(table.concat(t, "  "), FS, content_w)
            else
                local n = #row
                local w = math.floor((content_w - (n - 1) * gap) / n)
                local built, h = {}, 0
                for i, c in ipairs(row) do
                    local body, pad, enabled, on = card(c, w, as_choice)
                    built[i] = { body = body, pad = pad, enabled = enabled, on = on, c = c }
                    h = math.max(h, body:getSize().h + 2 * pad)
                end
                local hg, focus = HorizontalGroup:new{ align = "top" }, {}
                for i, b in ipairs(built) do
                    if i > 1 then hg[#hg + 1] = HorizontalSpan:new{ width = gap } end
                    local cw = (i == n) and (content_w - (n - 1) * (w + gap)) or w
                    local frame_c = Kit.card{ width = cw, height = h, on = b.on,
                        padding_left = b.pad, padding_right = b.pad,
                        LeftContainer:new{ dimen = Geom:new{ w = cw - 2 * b.pad, h = h }, b.body } }
                    local cell = Kit.tapCell(frame_c, cw, h, b.c.callback, b.enabled)
                    cell.focus_radius = Kit.RADIUS
                    hg[#hg + 1], focus[#focus + 1] = cell, cell
                end
                rows_vg[#rows_vg + 1] = hg
                layout[#layout + 1] = focus
            end
        end
        return rows_vg
    end

    -- Sub-menus as pages inside the editor (Editor._menu while it is open):
    -- the newest on top, a breadcrumb title and a back chevron. A menu's
    -- Close, Back or Cancel is that chevron (its callback runs).
    local pages = {}
    local renderPage
    local function goBack()
        local page = pages[#pages]
        if not page then return end
        if page.back then
            page.back()
        elseif page.spec.tap_close_callback then
            pcall(page.spec.tap_close_callback)
        end
        for i = #pages, 1, -1 do
            if pages[i] == page then table.remove(pages, i) end
        end
        rebuild()
    end
    local host = {
        push = function(spec)
            local page = { _page = true, spec = spec }
            -- What a menu that updates itself in place (Face out) calls on a
            -- ButtonDialog: its buttons by id, and the box it fills.
            local queued = false
            local function redraw()
                if queued then return end
                queued = true
                UIManager:nextTick(function()
                    queued = false
                    if pages[#pages] == page then rebuild() end
                end)
            end
            function page:getButtonById(id)
                for _r, row in ipairs(spec.buttons or {}) do
                    for _i, b in ipairs(row) do
                        if b.id == id then
                            return {
                                setText = function(_s, text) b.text, b.text_func = text, nil; redraw() end,
                                enable  = function() b.enabled, b.enabled_func = true, nil; redraw() end,
                                disable = function() b.enabled, b.enabled_func = false, nil; redraw() end,
                            }
                        end
                    end
                end
            end
            -- A page made of blocks (spec.page) is laid out afresh from the
            -- draft: what its taps call once they have changed it.
            function page:refresh() redraw() end
            page.movable = setmetatable({}, { __index = function(_t, k)
                if k == "dimen" then return frame and frame.dimen end
            end })
            pages[#pages + 1] = page
            rebuild()
            return page
        end,
        close = function(page)
            for i = #pages, 1, -1 do
                if pages[i] == page then table.remove(pages, i) end
            end
            rebuild()
        end,
        -- For a picker opened as a page of the editor (LibraryModal's
        -- config.over): where the editor is, the breadcrumb so far plus
        -- tail, and leaving the editor.
        rect = function()
            local d = (frame and frame.dimen and frame.dimen.x) and frame.dimen or last_rect
            local size = frame:getSize()
            if not d then return nil end
            return { x = d.x, y = d.y, w = size.w, h = math.max(d.h or 0, size.h) }
        end,
        crumbs = function(tail)
            local out = { (draft.label and draft.label ~= "") and draft.label or _("Shelf") }
            for _i, p in ipairs(pages) do out[#out + 1] = p.spec.title or "\xE2\x80\xA6" end
            for _i, t in ipairs(tail or {}) do out[#out + 1] = t end
            return table.concat(out, " \xE2\x80\xBA ")
        end,
        exit = function() finish() end,
    }
    local EditorPage = require("lib/bookshelf_editor_page")
    -- A page of blocks (spec.page(), lib/bookshelf_editor_page): its strip
    -- under the breadcrumb, then its body.
    -- Past the room under the title on this screen, in this orientation, the
    -- blocks go onto pages of their own (page.pg, from 1).
    local function renderBlocks(page, title_h)
        local max_h = Screen:getHeight() - Space.px(96) - Space.px(16) - title_h
            - 2 * Size.border.window
        local strip, body_w, layout = EditorPage.render(page.spec.page(),
            { width = dialog_w, inset = inset, font_size = FS, max_h = max_h,
              page = page.pg or 1,
              on_page = function(n) page.pg = n; rebuild() end })
        page.back = page.spec.on_back
        local vg = VerticalGroup:new{ align = "left" }
        if strip then vg[#vg + 1] = strip end
        vg[#vg + 1] = body_w
        return vg, layout
    end
    renderPage = function(page)
        local spec = page.spec
        local rows, back = {}, nil
        for _r, row in ipairs(spec.buttons or {}) do
            local out = {}
            for _i, b in ipairs(row) do
                local t = cellText(b)
                if b.callback and (t == _("Close") or t == _("Back") or t == _("Cancel")) then
                    back = back or b.callback
                else
                    out[#out + 1] = b
                end
            end
            if #out > 0 then rows[#rows + 1] = out end
        end
        local crumbs = { (draft.label and draft.label ~= "") and draft.label or _("Shelf") }
        for _i, p in ipairs(pages) do crumbs[#crumbs + 1] = p.spec.title or "\xE2\x80\xA6" end
        local title_bar = TitleBar:new{
            title_face = Kit.titleFace(),
            width            = dialog_w,
            title            = table.concat(crumbs, " \xE2\x80\xBA "),
            with_bottom_line = true,
            bottom_v_padding = 0,
            left_icon        = "chevron.left",
            left_icon_tap_callback = goBack,
            close_callback   = function() finish() end,
        }
        -- The shelf's name with its pictures, as the shelf menu shows it.
        Kit.iconTitle(title_bar, title_bar.title)
        Kit.centreTitle(title_bar)
        Kit.backLabel(title_bar)
        local blocks_vg, blocks_layout
        if spec.page then blocks_vg, blocks_layout = renderBlocks(page, title_bar:getSize().h) end
        if not spec.page then page.back = back end
        -- A long list of single-card rows (Filters) two to a row, so the
        -- page fits the screen.
        local singles = #rows > 4
        for _i, r in ipairs(rows) do if #r ~= 1 then singles = false end end
        if singles then
            local paired = {}
            for i = 1, #rows, 2 do
                paired[#paired + 1] = { rows[i][1], rows[i + 1] and rows[i + 1][1] or nil }
            end
            rows = paired
        end
        local layout = {}
        local vg = VerticalGroup:new{ align = "left" }
        for _i, wdg in ipairs(spec._added_widgets or {}) do
            -- A help paragraph laid out for the dialog's width: wrapped again
            -- to the editor's.
            if type(wdg.text) == "string" and wdg.face and wdg.width then
                wdg = require("ui/widget/textboxwidget"):new{ text = wdg.text,
                    face = wdg.face, fgcolor = wdg.fgcolor, width = content_w }
            end
            vg[#vg + 1] = wdg
            vg[#vg + 1] = VerticalSpan:new{ width = Space.px(10) }
        end
        vg[#vg + 1] = buildCards(rows, layout, true)
        local body = FocusManager:new{
            layout = blocks_layout or layout,
            show_parent = dialog,
            blocks_vg or FrameContainer:new{ bordersize = 0, padding = inset, vg },
        }
        current_bt = body
        -- A page's cursor starts on its first control, shown at the first
        -- key; each page (named by its crumbs) seeds afresh.
        Kit.keyFocus(body, key_state, 1, table.concat(crumbs, ">"))
        frame[1] = VerticalGroup:new{ align = "left", title_bar, body }
        markDirty()
    end

    rebuild = function()
        if #pages > 0 then return renderPage(pages[#pages]) end
        -- Sized as the rest of the editor's symbol buttons.
        local CHEV_SIZE  = 28

        local function open_label_dialog()
            local label_dialog
            local IconsLibrary = require("lib/bookshelf_icons_library")
            local row = {
                {
                    text     = _("Cancel"),
                    id       = "close",
                    callback = function() UIManager:close(label_dialog) end,
                },
                {
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
                        -- Shelf labels render literally (no token
                        -- expansion), so dynamic %tokens are excluded. The
                        -- SVG icon folder is offered (svg): an [icon=NAME]
                        -- in a label draws that image (issue 469).
                        IconsLibrary:show(function(glyph)
                            if label_dialog then
                                label_dialog.deny_keyboard_hiding = false
                            end
                            -- Insert the glyph at cursor in the InputDialog
                            -- via KOReader's InputDialog addTextToInput.
                            if glyph and glyph ~= ""
                                    and label_dialog and label_dialog.addTextToInput then
                                pcall(function() label_dialog:addTextToInput(glyph) end)
                            end
                            if label_dialog and label_dialog.onShowKeyboard then
                                pcall(function() label_dialog:onShowKeyboard() end)
                            end
                        end, { dynamic = false, svg = true })
                    end,
                },
            }
            row[#row + 1] = {
                text             = _("OK"),
                is_enter_default = true,
                callback         = function()
                    -- Applied on OK, not per keystroke: a text field is the
                    -- one control here with a commit of its own.
                    draft.label = label_dialog:getInputText()
                    UIManager:close(label_dialog)
                    commit()
                    rebuild()
                end,
            }
            label_dialog = InputDialog:new{
                title           = _("Shelf name"),
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
        -- consistently with what the picker offered. A direction other than
        -- the key's natural one is named in the Sort page's words ("Added
        -- (Oldest first)"); at its natural one the key alone reads cleaner.
        local function _sortButtonText(d)
            local kind = d.source and d.source.kind
            local parts = {}
            for i, lv in ipairs(d.sort_priority or {}) do
                local lbl = _resolveSortLabel(i, lv.key, kind)
                if not _isDefaultDirection(lv.key, lv.reverse) then
                    -- Editor's: the local is declared further down.
                    local asc, desc = Editor._dirLabels(lv.key)
                    lbl = T(_("%1 (%2)"), lbl, lv.reverse and desc or asc)
                end
                parts[#parts + 1] = lbl
            end
            if #parts == 0 then return _("Sort: (none)") end
            -- "Sort: Added, Title": the card shows "Sort" as its heading.
            return T(_("Sort: %1"), table.concat(parts, ", "))
        end

        -- Row 1b's contents: sort priority levels 1-3 for most sources, but
        -- OPDS feeds have no independent sort -- the remote server's own
        -- order is authoritative (see SOURCE_SORT_DEFAULTS.opds) -- so that
        -- row collapses to a single disabled row naming the constraint
        -- rather than offering pickers that would silently do nothing.
        local sort_row
        -- A fetch-mode registered source (lib/bookshelf_sources) orders itself
        -- the same way.
        local is_paged_src = draft.source
            and require("lib/bookshelf_sources").isPaged(draft.source.kind) or false
        -- ...unless it offers editor buttons of its own (its list, sort and
        -- filters: SOURCE_API.md "Editor rows"), which take that row's place.
        -- A button edits draft.source and calls done(), which saves it; the
        -- shelf fetches again, draft.source being part of its cache key.
        local src_rows
        if is_paged_src then
            local Sources = require("lib/bookshelf_sources")
            local spec_rows = Sources.editorRows(draft.source.kind, draft)
            for _r, row in ipairs(spec_rows or {}) do
                local out = {}
                for _b, b in ipairs(row) do
                    out[#out + 1] = {
                        text_func = function() return Sources.buttonText(b, draft) end,
                        callback = function()
                            local done = function() commit(); rebuild() end
                            local ok, err = pcall(b.callback, draft, done)
                            if not ok then logger.warn("[bookshelf] source: editor button failed:", tostring(err)) end
                        end,
                    }
                end
                src_rows = src_rows or {}
                src_rows[#src_rows + 1] = out
            end
        end
        if draft.source and (draft.source.kind == "opds" or is_paged_src) then
            sort_row = {
                { text = _("Server order"), enabled = false },
            }
        elseif draft.source and draft.source.kind == "shelves" then
            -- Its shelves stand in your order; the arrows in each one's
            -- editor move it.
            sort_row = {
                { text = _("Shelves stand in the order you arrange them"), enabled = false },
            }
        else
            -- One card for the whole order: its levels open together on the
            -- Sort page.
            sort_row = {
                {
                    text_func = function() return _sortButtonText(draft) end,
                    icon = "\u{EBB9}",   -- sort
                    callback = function()
                        Editor:_openSort(draft, function() commit() end, onArranged,
                            function() rebuild() end)
                    end,
                },
            }
        end

        -- Source + Filters row. The local-library filters (genre / tags /
        -- status / rating / ...) do nothing on an OPDS chip -- its books come
        -- straight from the remote feed, unfiltered by these -- so drop the
        -- Filters cell for OPDS sources. OPDS filtering is the feed's own facets
        -- (Language / Category), shown as folder tiles at the top of the shelf.
        local is_opds_src = draft.source and draft.source.kind == "opds"
        -- A shelf of shelves shows shelves, each with filters of its own, so
        -- it has none to offer.
        local is_shelves_src = draft.source and draft.source.kind == "shelves"
        -- Source gets a row to itself: it is the one choice that changes what
        -- every other control on this dialog means, and sharing a row made it
        -- read as a peer of the things it governs.
        local source_row = {
            {
                text_func = function()
                    -- "grouping" in the label: readers asking how to make a
                    -- shelf of series or authors did not look for it under
                    -- "Source" (maintainer).
                    -- A Shelf module's shelf is offered no grouping
                    -- (_pickSource), so its row says Source alone.
                    if TabModel.isCardOnly(draft) then
                        return _("Source: ") .. _resolveSourceLabel(draft.source)
                    end
                    return _("Source / grouping: ") .. _resolveSourceLabel(draft.source)
                end,
                icon_func = function() return Editor._sourceIcon(draft.source) end,
                callback = function()
                    Editor:_pickSource(draft, sourceChosen)
                end,
            },
        }
        -- Beneath it, the two per-chip overrides, paired: what this shelf
        -- SHOWS (filters, or a catalog's own settings) and how its group tiles
        -- LOOK.
        local shelf_row = {}
        if is_shelves_src then
            -- No filters (see is_shelves_src). In their place, whether the
            -- "+ Add shelf" tile shows: wanted while the shelves are being
            -- set up, clutter once they are (maintainer).
            shelf_row[#shelf_row + 1] = {
                -- A saved setting reads as its value (as Filters: None), not
                -- a tick (STYLE.md: a tick is for what is only shown).
                text_func = function()
                    return T(_("Add shelf tile: %1"), draft.hide_add_tile and _("Off") or _("On"))
                end,
                callback = function()
                    draft.hide_add_tile = (not draft.hide_add_tile) or nil
                    commit()
                    rebuild()
                end,
            }
        elseif is_paged_src then   -- luacheck: ignore 542
            -- A fetch-mode source filters on its own side; no local Filters.
        elseif not is_opds_src then
            shelf_row[#shelf_row + 1] = {
                text_func = function()
                    return T(_("Filters: %1"), Filter.summary(draft.filter or {}))
                end,
                icon = "\u{E931}",   -- filter
                callback = function()
                    Editor:_openFilters(draft, function() commit(); rebuild() end)
                end,
            }
        else
            -- The slot the local filters would occupy: this catalog's own
            -- settings (download folder from issue #319, plus the refresh /
            -- cover / page-size / timeout overrides). Per chip rather than
            -- one global setting so each catalog can be tuned for what it
            -- actually is - a public catalog wants the conservative shelf
            -- defaults, a server on your own network usually does not.
            shelf_row[#shelf_row + 1] = {
                text_func = function() return _("Catalog settings") end,
                callback = function()
                    Editor:_openCatalogSettings(draft, function()
                        commit()
                        rebuild()
                    end)
                end,
            }
        end

        -- Shelf style: whether this chip is a LIST, and if it is a grid, how
        -- its folder / stack tiles are drawn. Per chip because a chip IS a
        -- kind of shelf -- and because an OPDS catalog's subcatalogs render as
        -- folder tiles, so without this they were bound to whatever the
        -- filesystem's folders were set to.
        --
        -- It used to be "Folder style" and to be hidden for catalogues, on the
        -- grounds that an OPDS subcatalog has no artwork of its own so every
        -- tile style renders the same text tile -- a row that changed nothing.
        -- That reasoning holds for the tile styles and NOT for List, which is
        -- as meaningful on a catalogue as anywhere else (arguably more: a
        -- catalogue page is mostly titles). So the row is now always shown and
        -- a catalogue is offered the two options that mean something.
        shelf_row[#shelf_row + 1] = {
            text_func = function()
                -- The mode, as the card's icon shows it: no mode of its own is
                -- Covers, the default. A tile style named here ("View mode:
                -- Ribbon") read as a mode of its own; the page shows both.
                local shown = Editor._shownMode(draft[ViewMode.CHIP_KEY], is_opds_src or is_paged_src)
                local mode = Editor._chipModeLabel(shown)
                -- Spines with books face out read as covers on the shelf
                -- behind, so the card says both (a fresh Home said "Spines"
                -- over a row of covers).
                if shown == ViewMode.SPINES then
                    local SS = require("lib/bookshelf_spine_shelf")
                    if not SS.faceOutEmpty(SS.faceOutSpec(draft.spine_face_out)) then
                        mode = _("Spines, face out")
                    end
                end
                return T(_("View mode: %1"), mode or _("Covers"))
            end,
            icon_func = function()
                return Editor._modeIcon(draft[ViewMode.CHIP_KEY], is_opds_src or is_paged_src)
            end,
            callback = function()
                -- now: the shelf behind rebuilt at once, not on the
                -- debounce; the Theme library debounces its taps itself and
                -- refreshes the whole screen as it applies, so a rebuild left
                -- for later was a flash that showed nothing, then a second
                -- one with the theme (maintainer on the PW5, 2026-10-09).
                Editor:_pickGroupDisplay(draft, function(now)
                    commit()
                    if now then settlePreview() end
                    rebuild()
                end, {
                    -- Stand the editor down while the picker is up: it sits
                    -- over the shelf rows whose tiles are being previewed.
                    -- No hide/show: the picker is a page inside the editor now.
                    -- "ui", not a bare show. UIManager:show passes its
                    -- refreshtype straight to setDirty, which only enqueues a
                    -- refresh when it HAS one - so a bare show put the editor
                    -- back on the window stack, taking taps, without ever
                    -- painting it. It read as an invisible dialog swallowing
                    -- the screen: a tap in the middle opened the source menu.
                    -- Over its own box (editorRefresh), not the whole screen.

                    -- A catalogue gets Default and List only; see above.
                    is_opds = is_opds_src or is_paged_src,
                    -- The live shelf, so the density nudges can seed from the
                    -- numbers actually on screen instead of from a constant.
                    bw = opts.bw,
                })
            end,
        }

        -- The shelf's Theme, on the front page beside its modules: out of
        -- View mode, a level down before (maintainer). The shelf's own, in the
        -- Theme library; a sub-shelf with none of its own reads "Same as
        -- Fiction" (TP.followOf). Following the default reads "Default
        -- theme", never "library" nor a bare "Default".
        local look_row = {}
        do
            local TP = require("lib/bookshelf_theme_pack")
            local follow = draft.parent ~= nil and TP.followOf(draft.id) or nil
            look_row[#look_row + 1] = {
                text_func = function()
                    local v = draft.theme
                    return T(_("Theme: %1"), (v == nil and follow) and follow.title or TP.choiceLabel(v))
                end,
                icon = "\u{EAD7}",   -- palette
                callback = function()
                    require("lib/bookshelf_theme_library").show{
                        shelf = draft.label or "",
                        -- A page of the editor: Home > Theme.
                        over = Editor._over({ _("Theme") }),
                        current = function() return draft.theme end,
                        follow = follow,
                        choose = function(value) draft.theme = value end,
                        -- The shelf behind at once: the library refreshes
                        -- the whole screen as it applies (see View mode).
                        apply = function() commit(); settlePreview() end,
                        on_closed = function() rebuild() end,
                    }
                end,
            }
        end
        -- A module among this shelf's books (covers or spines). The shelf
        -- on screen only, never a module's own shelf. With Modules > On the
        -- shelf off, or on a List shelf, the card stays, greyed, saying why:
        -- it vanished with nothing to say so (maintainer).
        if opts.bw and opts.bw.chip == tab_id and not draft.card_only
                and opts.bw._editShelfModules then
            local why
            if not require("lib/bookshelf_settings_store").microOnShelf() then
                why = _("Off in Settings")
            elseif opts.bw:_isListMode() then
                why = _("Not in List view")
            end
            -- How many the shelf has (maintainer); none yet, the way to add one.
            local n_mods = #(require("lib/bookshelf_shelf_modules").list(draft) or {})
            local value = why or (n_mods > 0 and T(_("%1 on this shelf"), n_mods))
            look_row[#look_row + 1] = {
                text = value and T(_("Modules: %1"), value) or _("Modules: Add to this shelf\xE2\x80\xA6"),
                icon = "\u{EB94}",   -- shape-plus
                enabled = why == nil,
                -- The picker as a page of the editor (Home > Modules), like
                -- Theme: it was a window of its own over the editor, titled
                -- differently, with no way back (user test). Picking closes
                -- the editor and adds the module as before.
                callback = why == nil and function()
                    local function addOne()
                        require("lib/bookshelf_module_picker"):show(function(key)
                            finish()
                            opts.bw:_editShelfModules(nil, { add = true, key = key })
                        end, { for_hero = true, over = Editor._over({ _("Modules") }) })
                    end
                    -- On spines: a page of them, each to its own menu (a
                    -- spine row is no grid, so the layout editor is the
                    -- covers' only; the card closed the editor and opened
                    -- nothing, maintainer), and Add module.
                    local function modulesPage()
                        local Modules = require("lib/bookshelf_start_menu_modules")
                        local d
                        d = Editor._menu{ title = _("Modules"), page = function()
                            local blocks = {}
                            for _i, m in ipairs(require("lib/bookshelf_shelf_modules").list(draft) or {}) do
                                local def = Modules.get(m.module)
                                blocks[#blocks + 1] = { type = "row",
                                    label = (def and def.title) or m.module,
                                    value = m.ornament and m.ornament:gsub("%.%w+$", "") or nil,
                                    icon = "\u{EB94}",
                                    callback = function()
                                        finish()
                                        opts.bw:_spineShowModule(m.id)
                                        opts.bw:_spineModuleMenu(m)
                                    end }
                            end
                            blocks[#blocks + 1] = { type = "row", label = _("Add module\xE2\x80\xA6"),
                                icon = "\xEF\x91\x8D", callback = addOne }   -- plus, as + Add
                            return { strip = { { type = "summary",
                                text = _("Modules stand among this shelf's books. Tap one to move, size or remove it.") } },
                                blocks = blocks }
                        end }
                        return d
                    end
                    -- Some there: on covers the layout editor, which moves,
                    -- removes and adds them; none: straight to the picker.
                    if n_mods > 0 and opts.bw:_isSpineMode() then return modulesPage() end
                    if n_mods > 0 then
                        finish()
                        opts.bw:_editShelfModules()
                        return
                    end
                    addOne()
                end or nil,
            }
        end

        -- Short values side by side (maintainer): View mode beside Source,
        -- then Filters (or what stands in their place) beside Sort, for a
        -- shorter page. View mode is always shelf_row's last card. A source
        -- with rows of its own in Sort's place keeps them under Filters.
        local view_cell = table.remove(shelf_row)
        if view_cell then source_row[#source_row + 1] = view_cell end
        local pair_row = {}
        for _i, c in ipairs(shelf_row) do pair_row[#pair_row + 1] = c end
        if not src_rows then
            for _i, c in ipairs(sort_row or {}) do pair_row[#pair_row + 1] = c end
        end
        local buttons = {
            -- Row 0: Edit shelf name, then Shelf order: a page listing the
            -- shelves beside this one, each as the menu bar draws it, with up
            -- and down. It replaced Position's two nudges, which moved this
            -- shelf one step at a time without showing where it was going
            -- (maintainer).
            {
                {
                    -- Title bar already shows the live label ("Editing shelf: ..."),
                    -- so the button just describes its action -- no need to
                    -- repeat the label text.
                    text     = _("Edit shelf name"),
                    callback = open_label_dialog,
                },
                {
                    text     = _("Shelf order\xE2\x80\xA6"),
                    callback = function()
                        self:_openShelfOrder(tab_id, function()
                            -- Visual only (book lists unchanged): no book
                            -- cache to invalidate. The strip repaints in its
                            -- new order once the taps pause.
                            schedulePreview()
                        end, editOther)
                    end,
                },
            },
            -- The source and View mode.
            source_row,
            -- Filters (or a catalog's settings, or the + tile) and Sort --
            -- for an OPDS source, the disabled "Server order" card.
            pair_row,
            -- Where a source's own rows replace Sort (src_rows, below).
            src_rows and sort_row or {},
            -- The shelf's Theme, and a module among its books (look_row).
            look_row,
            -- The foot row: Delete | New shelf | Close (maintainer). One
            -- Close, not Cancel and Save: every change has already been
            -- applied and saved, so there is nothing left to keep or throw
            -- away (maintainer, 2026-10-08). Delete works on any shelf, a
            -- built-in one too (it asks first).
            {
                {
                    text           = "\xEE\xA2\xBF",  -- U+E8BF mdi-delete
                    footer_text    = _("Delete"),   -- in the bottom row
                    font_face      = "symbols",
                    font_size      = CHEV_SIZE,
                    font_bold      = false,
                    bordersize     = 0,
                    callback   = function()
                        local has_shelves = #TabModel.childrenOf(tab_id) > 0
                        UIManager:show(ConfirmBox:new{
                            text       = has_shelves
                                and _("Delete this shelf and the shelves inside it? This cannot be undone.")
                                or _("Delete this shelf? This cannot be undone."),
                            ok_text    = _("Delete"),
                            ok_callback = function()
                                -- Deleting a tab changes the list of tabs,
                                -- not the contents of any tab. Book caches
                                -- for other tabs stay valid; the deleted
                                -- tab's cache entries are harmless orphans
                                -- (never read again). No invalidateBookCache.
                                closed = true
                                settlePreview(true)
                                local del_tabs = TabModel.load()
                                -- Where the shelf on screen goes if it was
                                -- this one or inside it: up to this one's
                                -- shelf of shelves, read before the delete.
                                local parent_id
                                for _i, t in ipairs(del_tabs) do
                                    if t.id == tab_id then parent_id = t.parent; break end
                                end
                                local gone = TabModel.descendantIds(tab_id, del_tabs)
                                gone[tab_id] = true
                                TabModel.removeTree(del_tabs, tab_id)
                                TabModel.save(del_tabs)
                                UIManager:close(dialog)
                                local bw = opts.bw
                                if bw and gone[bw.chip] and parent_id and bw._openShelf then
                                    bw:_openShelf(parent_id)
                                elseif opts.on_change then
                                    opts.on_change()
                                end
                            end,
                        })
                    end,
                },
                -- Copy and Move to, between Delete and Add: what readers did
                -- by hand in the settings file (copying a set-up shelf to
                -- change one thing; moving shelves into a shelf of shelves).
                -- Close went to make room: the title bar's X, a tap outside
                -- and Back all close the editor (maintainer).
                {
                    text         = _("Copy"),
                    bordersize   = 0,
                    enabled_func = function() return hasSource() end,
                    callback     = function() copyShelf() end,
                },
                {
                    text         = _("Move to\xE2\x80\xA6"),
                    bordersize   = 0,
                    -- Not greyed when there is nowhere to go: a fresh install
                    -- has no shelf of shelves, and a dead button said nothing
                    -- about why (user test). A tap says how to make one.
                    enabled_func = function() return hasSource() and not draft.card_only end,
                    callback     = function()
                        if canMove() then return moveShelf() end
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = _("There is no shelf of shelves to move this shelf into yet. Make one with New shelf > Shelf of shelves."),
                        })
                    end,
                },
                {
                    -- Add button placed last in the row to balance the
                    -- destructive Delete on the far left.
                    text           = "\xEF\x81\x95",  -- U+F055 fa-plus-circle
                    footer_text    = _("New shelf"),   -- in the bottom row
                    font_face      = "symbols",
                    font_bold      = false,
                    font_size  = CHEV_SIZE,
                    bordersize = 0,
                    -- Not from a new shelf that has no source yet: it would
                    -- only make a second empty one beside it.
                    enabled_func = function() return hasSource() end,
                    callback   = function()
                        -- This shelf's changes are saved already; leave its
                        -- editor (the new shelf's selection rebuilds the
                        -- shelf, so no rebuild is owed here).
                        closed = true
                        settlePreview(true)
                        TabModel.flush()
                        -- Inside a shelf of shelves, the new shelf joins this
                        -- one's siblings: the widget makes it, opens it and
                        -- puts its editor up.
                        if draft.parent and opts.bw and opts.bw._addSubShelf then
                            UIManager:close(dialog)
                            opts.bw:_addSubShelf(draft.parent)
                            return
                        end
                        -- A new shelf (TabModel.newTab: no source yet, pending
                        -- until it has one), spliced right after the chip being
                        -- edited rather than at the end of the strip. Matches
                        -- the Pin-from-stack flow and keeps newly created
                        -- chips visually adjacent to their origin.
                        local fresh = TabModel.load()
                        local new_tab = TabModel.newTab(fresh, _("New shelf"))
                        local new_id = new_tab.id
                        TabModel.insertAfter(fresh, tab_id, new_tab)
                        TabModel.save(fresh)
                        UIManager:close(dialog)
                        -- Auto-select the new tab so the user lands on it after
                        -- editing (request), not back on the tab they added from.
                        -- _selectChip does its own rebuild; fall back to on_change
                        -- for any caller without a widget handle.
                        if opts.bw and opts.bw._selectChip then
                            opts.bw:_selectChip(new_id)
                        elseif opts.on_change then
                            opts.on_change()
                        end
                        -- Copied rather than mutated: opts belongs to the
                        -- editor we were opened from and outlives this call.
                        local new_opts = {}
                        for k, v in pairs(opts) do new_opts[k] = v end
                        new_opts.pick_source_first = true
                        -- Backing out of it lands back on this shelf.
                        new_opts.on_discard = function()
                            if opts.bw and opts.bw._selectChip then
                                opts.bw:_selectChip(tab_id)
                            elseif opts.on_change then
                                opts.on_change()
                            end
                        end
                        Editor:editTab(new_id, new_opts)
                    end,
                },
            },
        }

        -- A new shelf without a source yet: say what keeps it, above the
        -- source row, since Close reads the same as on any other shelf.
        if is_new and not hasSource() then
            table.insert(buttons, 2, {
                { text = _("Choose a source to keep this new shelf."), enabled = false },
            })
        end

        -- A Shelf module's own shelf: not in the shelf menu, so nothing to
        -- move along it; and it lives and dies with its module (removing the
        -- module deletes it, its settings switch to another), so no Delete,
        -- Copy, Move to or new shelf beside it. The first row keeps Edit
        -- shelf name alone; the last row is the actions.
        if draft.card_only then
            buttons[1] = { buttons[1][1] }
            buttons[#buttons] = {}
        end

        -- Laid out to the popup style guide (STYLE.md), from the same rows:
        -- the first row (move left, Edit label, move right) and the last
        -- (Delete, Copy, Move to, Add) are the screen's own actions, on the
        -- grey strip; every row between is a setting, shown as grey cards
        -- with a heading and its value; a row that can't be tapped and only
        -- says something is grey hint text.
        local top_row, action_row = buttons[1], buttons[#buttons]
        local middle = {}
        for i = 2, #buttons - 1 do
            local row = buttons[i]
            if row == sort_row and src_rows then
                for _r, r in ipairs(src_rows) do middle[#middle + 1] = r end
            elseif #row > 0 then middle[#middle + 1] = row end
        end
        local function stripButton(c)
            if c.font_face == "symbols" then
                return Kit.iconButton{ icon = cellText(c), font_size = FS,
                    enabled = cellEnabled(c), on_tap = c.callback }
            end
            return Kit.headerButton{ text = cellText(c), font_size = FS,
                enabled = cellEnabled(c), on_tap = c.callback }
        end
        local layout = {}
        local function group(cells)
            local hg, focus = HorizontalGroup:new{ align = "center" }, {}
            for i, c in ipairs(cells or {}) do
                if i > 1 then hg[#hg + 1] = HorizontalSpan:new{ width = c.gap_before or Space.px(10) } end
                if c.label_text then
                    -- A grey word naming the buttons after it (Move).
                    hg[#hg + 1] = TextWidget:new{ text = c.label_text,
                        face = require("lib/bookshelf_fonts"):getFace("cfont", FS - 2), fgcolor = Kit.DIM_ON_GREY }
                else
                    local btn = stripButton(c)
                    hg[#hg + 1], focus[#focus + 1] = btn, btn
                end
            end
            return (#cells or 0) > 0 and hg or nil, focus
        end
        -- Delete and New shelf go to a button row at the foot with Close: the
        -- strip was crowded (maintainer). Copy and Move to stay on it.
        local strip_cells, foot_cells = {}, {}
        for _i, c in ipairs(action_row ~= top_row and action_row or {}) do
            if c.footer_text then foot_cells[#foot_cells + 1] = c
            else strip_cells[#strip_cells + 1] = c end
        end
        local left, left_focus = group(top_row)
        local right, right_focus = group(strip_cells)
        local strip_focus = {}
        for _i, w in ipairs(left_focus) do strip_focus[#strip_focus + 1] = w end
        for _i, w in ipairs(right_focus) do strip_focus[#strip_focus + 1] = w end
        if #strip_focus > 0 then layout[#layout + 1] = strip_focus end
        local strip = Kit.headerRow{ width = dialog_w, inset = inset,
            left = left, buttons = right and { right } or nil }

        local rows_vg = buildCards(middle, layout, false)

        -- The foot: KOReader's own button row, edge to edge (as a
        -- ButtonDialog's), Delete | New shelf | Close.
        local foot_row = {}
        for _i, c in ipairs(foot_cells) do
            foot_row[#foot_row + 1] = { text = c.footer_text, enabled = cellEnabled(c),
                callback = c.callback }
        end
        foot_row[#foot_row + 1] = { text = _("Close"), callback = function() finish() end }
        local foot = require("ui/widget/buttontable"):new{
            width = dialog_w, buttons = Kit.uiFontButtons({ foot_row }), zero_sep = true, show_parent = dialog }
        -- Its buttons are keyed by the editor's FocusManager below. Left to
        -- itself this one-row table (a FocusManager too, and nearer the keys)
        -- took every arrow and could move nowhere, and pressed its own
        -- button on Press: no key reached the editor (maintainer, desktop).
        Kit.quietFocus(foot)
        local foot_focus = {}
        for _i, row in ipairs(foot.layout or {}) do
            for _j, b in ipairs(row) do foot_focus[#foot_focus + 1] = b end
        end
        if #foot_focus > 0 then layout[#layout + 1] = foot_focus end

        -- One FocusManager over the strip and the cards, so keys move through
        -- them (GitHub issue 361); it repaints the dialog when focus moves.
        local button_table = FocusManager:new{
            layout = layout,
            show_parent = dialog,
            VerticalGroup:new{ align = "left",
                strip,
                VerticalSpan:new{ width = inset },
                FrameContainer:new{ bordersize = 0, padding = 0,
                    padding_left = inset, padding_right = inset, padding_bottom = inset,
                    rows_vg },
                require("ui/widget/linewidget"):new{ background = Blitbuffer.COLOR_GRAY,
                    dimen = Geom:new{ w = dialog_w, h = Size.line.medium } },
                foot,
            },
        }
        -- FocusManager repaints `show_parent or self` on a D-pad move, and the
        -- body is not on the window stack, so without this the highlight never
        -- moved on screen (GitHub issue 361). The first build runs before the
        -- dialog exists: its creation below catches that one up.
        button_table.show_parent = dialog
        current_bt = button_table
        -- The cursor starts on the first card (Source), the strip of Edit
        -- shelf name / Shelf order above it: shown at the first key.
        Kit.keyFocus(button_table, key_state, #strip_focus > 0 and 2 or 1, "main")

        -- Dynamic title: shows the tab's current label so the user can see
        -- which tab they're editing at a glance. Falls back to a generic
        -- string when the label is empty / nil.
        local title_text = _("Edit shelf")
        if draft.label and draft.label ~= "" then
            title_text = T(_("Editing shelf: %1"), draft.label)
        end
        local title_bar = TitleBar:new{
            title_face = Kit.titleFace(),
            width             = dialog_w,
            title             = title_text,
            with_bottom_line  = true,
            bottom_v_padding  = 0,
            -- No X: Close is in the button row at the foot.
        }
        Kit.iconTitle(title_bar, title_text)
        Kit.centreTitle(title_bar)

        frame[1] = VerticalGroup:new{
            align = "left",
            title_bar,
            button_table,
        }

        -- Only a dialog that is on screen gets marked dirty. While a picker
        -- has hidden this one, setDirty(dialog, "ui") with no region enqueued
        -- a FULL-SCREEN ui refresh for a widget nobody could see, and merged
        -- with the picker's own close refresh it became a whole-screen flash
        -- on every tap. The re-show that follows a picker repaints anyway.
        markDirty()
    end

    -- Build frame shell once; rebuild() will fill frame[1].
    frame = FrameContainer:new{
        radius     = Space.radius.window,
        padding    = 0,
        margin     = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{},  -- placeholder; filled by rebuild() below
    }
    -- The grid runs to the frame's edge: its border is drawn again over it.
    function frame:paintTo(bb, x, y)
        FrameContainer.paintTo(self, bb, x, y)
        local sz = self:getSize()
        bb:paintBorder(x, y, sz.w, sz.h, self.bordersize, Blitbuffer.COLOR_BLACK, self.radius)
    end

    -- Populate frame[1] for the first time before show.
    rebuild()

    local bw = opts.bw

    -- Build the dialog shell with MovableContainer + anchor.
    -- The anchor positions the dialog just below the chip strip on first paint
    -- and stays there because rebuild() only swaps frame[1] (the content),
    -- never the MovableContainer.
    dialog = InputContainer:new{}
    if current_bt then current_bt.show_parent = dialog end

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

    -- A tap outside and Back are Close too. Back used to close the window
    -- and nothing else, which kept a half-made new shelf.
    -- KOReader's own gestures (the menu, brightness, a reader's own) work
    -- outside it as they do over the shelf: UIManager hands every event to
    -- the top window only, so they were dead while it was up (maintainer,
    -- PW5). The same walk as the book popup (GestureZones).
    local GestureZones = require("lib/bookshelf_gesture_zones")
    local function outside(ev)
        return ev and ev.pos and (not frame.dimen or ev.pos:notIntersectWith(frame.dimen))
    end
    dialog.onTapClose = function(_self_d, _arg, ges_ev)
        if outside(ges_ev) then
            if GestureZones.tryLiveZones(ges_ev) then return true end
            finish()
        end
        return true
    end
    function dialog:handleEvent(event)
        return GestureZones.overlayEvent(self, event, InputContainer,
            function(pos) return not outside({ pos = pos }) end)
    end
    dialog.onClose = function()
        if #pages > 0 then goBack() else finish() end
        return true
    end
    dialog.onCloseWidget = function()
        if Editor._host == host then Editor._host = nil end
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

    -- The same high anchor every picker this editor opens uses: over the hero,
    -- above the shelf menu bar, so the shelf menu bar below the top panel
    -- stays in sight; an editor placed somewhere different from the dialogs
    -- it spawns reads as a different kind of thing (maintainer report).
    --
    -- _highAnchor takes its width off the laid-out MovableContainer, so the
    -- container is held here for it to read rather than built inline.
    local movable = MovableContainer:new{
        frame,
        anchor = _highAnchor(function() return dialog end),
    }
    dialog.movable = movable
    -- Not centred: the anchor places it, from the screen's corner. Centred,
    -- its place hung on the window's size, so a page of another height
    -- (the window's size kept up to date in markDirty) moved it.
    dialog[1] = WidgetContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        movable,
    }

    -- Its sub-menus open as pages inside it while it is up (Editor._menu).
    Editor._host = host
    -- "ui": "partial" counts towards KOReader's periodic full flash.
    UIManager:show(dialog, function() return "ui", frame.dimen end)

    -- A chip that has just been created has no source the user chose: it holds
    -- the placeholder every new chip starts from. Picking one is the first
    -- thing to do and it is also what names the chip (_applySourceDefaults
    -- renames a label still reading "New shelf"), so the editor would otherwise
    -- open on a chip presenting a Home (folders) source and a generic name as
    -- though they had been decided.
    --
    -- Shown AFTER the editor so the picker sits on top of it: cancelling
    -- returns to the editor rather than to nothing, and the placeholder source
    -- stands as the fallback exactly as it did before.
    if opts.pick_source_first then
        Editor:_pickSource(draft, function()
            -- Backing out of the very first pick of a shelf being created,
            -- with nothing picked, is backing out of creating it.
            if is_new and not hasSource() then
                return discardNew()
            end
            sourceChosen()
        end)
    end
end

-- _openCatalogSettings(draft, on_close) - the per-catalog tuning menu for an
-- OPDS chip: download folder, refresh age, cover loading, page size and
-- timeout. Everything in here is an override of a shelf default chosen for
-- PUBLIC catalogs; see bookshelf_opds_prefs for why each default is what it
-- is, and why these live on the chip rather than on the server.
--
-- Rows read "Thing: current value" to match the Filters / Saves-to cells the
-- editor already uses; the fuller wording is the sub-dialog's title, so the
-- menu stays narrow enough not to wrap on a small screen.
--
-- Every pick hands back through on_close, which saves it (the caller passes
-- commit + rebuild), and the menu reopens on its new value.
-- _openShelfOrder(tab_id, on_change): the shelves at tab_id's level (the
-- menu bar's, or a shelf of shelves'), each drawn as its chip is on the bar,
-- tab_id's black, with up and down on every one, so any of them can be put
-- in its place from here. A move saves at once and calls on_change.
-- on_edit(id): a pencil on each other shelf's row, into its editor
-- (maintainer).
function Editor:_openShelfOrder(tab_id, on_change, on_edit)
    local d
    local function move(id, delta)
        local all = TabModel.load()
        if TabModel.moveAmong(all, id, delta) then
            -- In memory: the editor flushes as it closes. A write per tap
            -- was ~130 ms on a PW5.
            TabModel.saveDeferred(all)
            if on_change then on_change() end
            if d and d.refresh then d:refresh() end
        end
    end
    local function page()
        local list = TabModel.orderSiblings(TabModel.load(), tab_id)
        local blocks = {}
        for i, t in ipairs(list) do
            -- As the bar builds a chip's label (an old record's separate
            -- icon before it).
            local label = t.label or ""
            if t.icon and t.icon ~= "" then label = t.icon .. " " .. label end
            local id = t.id
            blocks[#blocks + 1] = { type = "order", label = label, selected = id == tab_id,
                up_enabled = i > 1, down_enabled = i < #list,
                on_up = function() move(id, -1) end,
                on_down = function() move(id, 1) end,
                -- A tap on the pill; not on the shelf being edited, whose
                -- editor is the one open.
                on_edit = (on_edit and id ~= tab_id) and function() on_edit(id) end or nil }
        end
        return { blocks = blocks }
    end
    d = Editor._menu{
        title = _("Shelf order"),
        page  = page,
        anchor = _highAnchor(function() return d end),
    }
    return d
end

function Editor:_openCatalogSettings(draft, on_close)
    local Prefs  = require("lib/bookshelf_opds_prefs")
    local Picker = require("lib/bookshelf_folder_picker")
    local d
    local function changed()
        if on_close then on_close() end
        if d and d.refresh then d:refresh() end
    end
    -- A page: where the catalog starts, where its books are saved, and how
    -- often it is fetched again, each said in words and changed in place.
    local function page()
        local blocks = {}
        local function add(b) blocks[#blocks + 1] = b end

        -- THE START FOLDER. Setting one is a long-press on the subcatalog out
        -- on the shelf, where the reader can see what they are choosing; what
        -- belongs here is what it is now, and the way back above it.
        local start_url   = draft.source and draft.source.feed_url
        local start_label = draft.source and draft.source.feed_label
        add({ type = "heading", text = _("Starts at") })
        add({ type = "option", icon = "\u{E94A}",   -- folder
            text = start_url and (start_label or _("a subcatalog")) or _("The top of the catalog"),
            desc = _("Long-press a subcatalog on the shelf to start there."),
            links = start_url and { { text = _("Back to the top"), callback = function()
                draft.source.feed_url   = nil
                draft.source.feed_label = nil
                changed()
            end } } or nil })

        -- WHERE DOWNLOADS GO: KOReader's own folder, or one the reader picks.
        local dir = draft.download_dir
        local own = type(dir) == "string" and dir ~= ""
        add({ type = "heading", text = _("Saves downloads to") })
        add({ type = "option", half = true, text = _("KOReader's download folder"), on = not own,
            callback = (own and function() draft.download_dir = nil; changed() end) or nil })
        add({ type = "option", half = true, icon = "\u{E94A}",
            text = (own and (dir:match("([^/]+)/?$") or dir) or _("A folder of your own")) .. " \xE2\x80\xBA",
            on = own,
            callback = function()
                -- A page of the editor, as Filters > Folders' picker is.
                Picker.show{
                    title     = _("Save downloads to\xE2\x80\xA6"),
                    over      = Editor._over({ _("Saves downloads to") }),
                    on_cancel = function() end,
                    on_pick   = function(picked)
                        draft.download_dir = picked
                        changed()
                    end,
                }
            end })

        -- HOW OFTEN IT IS FETCHED AGAIN. Unset is options[1] (Prefs): tick
        -- what the catalog DOES, not what is stored.
        local current = draft.opds_refresh_age
        if current == nil and Prefs.REFRESH_OPTIONS[1] then current = Prefs.REFRESH_OPTIONS[1].value end
        add({ type = "heading", text = _("Refresh this catalog") })
        for _i, opt in ipairs(Prefs.REFRESH_OPTIONS) do
            local value = opt.value
            add({ type = "option", half = true, text = opt.label_func(), on = current == value,
                callback = function() draft.opds_refresh_age = value; changed() end })
        end
        return { blocks = blocks }
    end
    d = Editor._menu{
        title   = _("Catalog settings"),
        page    = page,
        on_back = on_close,
        anchor  = _highAnchor(function() return d end),
    }
end


-- _pickFaceCollection(draft, on_change, back) -- which collection the "In a
-- collection" face-out reason reads (issue 470). Favourites is left out: it
-- is a reason of its own. Picking one switches the reason on; `back` reopens
-- the face-out dialog.
function Editor:_pickFaceCollection(draft, on_change, back)
    local SS = require("lib/bookshelf_spine_shelf")
    local d
    local cur = SS.faceOutSpec(draft.spine_face_out).collection
    local names = {}
    local ok, rc = pcall(require, "readcollection")
    if ok and rc and rc.coll then
        local default_name = rc.default_collection_name
        for name in pairs(rc.coll) do
            if name ~= default_name then names[#names + 1] = name end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    -- A page of the collections, the one in use black; a tap picks it and
    -- goes back to Face out, where the reason now reads it.
    local function page()
        if #names == 0 then
            return { blocks = { { type = "hint", text = _("No collections yet. Make one from a book's menu.") } } }
        end
        local items = {}
        for _i, name in ipairs(names) do
            items[#items + 1] = { text = name, icon = "\u{E7BF}", on = cur == name, callback = function()
                local spec = SS.faceOutSpec(draft.spine_face_out)
                spec.collection = name
                spec.all = nil
                draft.spine_face_out = spec
                if on_change then on_change() end
                Editor._closeMenu(d)
                if back then back() end
            end }
        end
        return { blocks = {
            { type = "hint", text = _("Books in this collection stand face out.") },
            { type = "chips", items = items },
        } }
    end
    d = Editor._menu{
        title   = _("In a collection"),
        page    = page,
        on_back = back,
        anchor  = _highAnchor(function() return d end),
    }
end

-- _pickGroupDisplay(draft, on_change) - how THIS chip draws its folder and
-- stack tiles.
--
-- The list leads with "Default setting", so following the library default is
-- a choice a chip can be put back to rather than only a state it starts in.
-- Picking a named style pins it, and the chip keeps that look even if the
-- library default changes underneath it later.
-- The list STAYS OPEN and each pick lands on the shelf immediately, matching
-- the library-wide row in the settings menu. A folder style is a look, and a
-- look is chosen by seeing it: the old behaviour closed on the first tap, so
-- comparing two styles meant reopening the picker for each one.
--
-- Re-shown rather than reinit'd between picks. ButtonDialog:reinit unlocks the
-- MovableContainer, after which the dialog eats taps and wedges with no
-- traceback; closing and building a fresh one is a repaint on e-ink and cannot
-- get into that state. The dialog is centred, so it comes back where it was.
-- chrome (optional): { hide, show } for the editor dialog itself. The picker
-- previews a change to folder tiles, and the editor sits squarely over the
-- shelf rows those tiles are on - so it goes away for the duration and comes
-- back when the picker does. Closing it is safe and cheap: its onCloseWidget
-- only repaints the region it occupied (which is what reveals the shelf), and
-- nothing is freed, so the same widget re-shows intact and keeps the position
-- it was anchored to.
-- _capFirst(s) -> s with its first letter capitalised (a summary built from
-- lower-case parts).
function Editor._capFirst(s)
    return (s:gsub("^%l", string.upper))
end

function Editor:_pickGroupDisplay(draft, on_change, chrome)
    local StackDisplay = require("lib/bookshelf_stack_display")
    local CHEV = " \xE2\x80\xBA"
    local no_spines = (chrome and chrome.is_opds) and true or false
    local bw = chrome and chrome.bw

    -- open(title, build, on_back) -> a page whose controls apply at once:
    -- each pick is saved (on_change), so the shelf behind shows it, and the
    -- page is laid out again from the draft. build(pick) -> its model.
    local function open(title, build, on_back)
        local d
        local function pick(apply)
            return function()
                apply()
                if on_change then on_change() end
                if d and d.refresh then d:refresh() end
            end
        end
        d = Editor._menu{
            title   = title,
            page    = function() return build(pick) end,
            on_back = on_back,
            -- HIGH, over the hero rather than the shelf: the page exists to
            -- show a change to the shelf, so covering it defeats it.
            anchor  = _highAnchor(function() return d end),
        }
        return d
    end
    local function onOff(pick, label, on, set)
        return { type = "segmented", label = label,
            items = { { key = true, label = _("On") }, { key = false, label = _("Off") } },
            active = on and true or false,
            on_pick = function(v) pick(function() set(v) end)() end }
    end
    -- A number: nil is Auto, the automatic count. The first step seeds from
    -- live(), the number on screen, so + from Auto shows one more of what the
    -- reader sees; below lo goes back to Auto. inherit_key: unset shows that
    -- key's value (Level 2's list numbers follow Level 1's).
    local function stepper(pick, label, key, lo, hi, live, inherit_key)
        local v = draft[key]
        if v == nil and inherit_key then v = draft[inherit_key] end
        local function step(delta)
            return pick(function()
                local cur = draft[key]
                if not cur then
                    -- From the number shown: the one followed, else live.
                    local base = (inherit_key and draft[inherit_key]) or (live and live()) or lo
                    draft[key] = math.max(lo, math.min(hi, base + delta))
                else
                    local n = cur + delta
                    if n < lo then draft[key] = nil
                    else draft[key] = math.min(hi, n) end
                end
            end)
        end
        return { type = "stepper", label = label, value = v and tostring(v) or _("Auto"),
            on_dec = step(-1), on_inc = step(1) }
    end
    local function numText(v) return v and tostring(v) or _("Auto") end

    -- ── The three styles' own settings ──────────────────────────────────
    -- On the View mode page itself for a shelf with one style; under Auto,
    -- one page per level, reached from that level's card.
    -- List numbers only: cover columns change the whole screen's layout (hero
    -- size, chip bar), so they stay global. With Auto listing on both levels,
    -- a set per level (ViewMode.listLevelsSplit); level (1 or 2, nil for a
    -- shelf with no levels) picks which.
    local function listBlocks(pick, add, level)
        local split = ViewMode.listLevelsSplit(draft)
        local function listRows(sfx, inherit)
            add(stepper(pick, _("Columns"), "list_columns" .. sfx, 1, 3,
                bw and function() return bw:_listCols() end,
                inherit and "list_columns" or nil))
            add(stepper(pick, _("Rows"), "list_rows" .. sfx, 1, 12,
                bw and function()
                    local ok, plan = pcall(bw._listBandPlan, bw, false, bw._chip_bar_hidden)
                    return ok and plan and plan.rows or 4
                end, inherit and "list_rows" or nil))
        end
        if split and level == 2 then
            listRows(ViewMode.LEVEL2_SUFFIX, true)
        else
            listRows("")
        end
    end
    local function listSummary(level)
        local function one(sfx, inherit)
            local c = draft["list_columns" .. sfx]
            local r = draft["list_rows" .. sfx]
            if inherit then c = c or draft.list_columns; r = r or draft.list_rows end
            -- "columns: Auto", not "Auto columns".
            return T(_("columns: %1, rows: %2"), numText(c), numText(r))
        end
        if ViewMode.listLevelsSplit(draft) and level == 2 then
            return Editor._capFirst(one(ViewMode.LEVEL2_SUFFIX, true))
        end
        return Editor._capFirst(one(""))
    end

    -- Ornaments: only ever on a spine shelf. Four stops picked for what they
    -- look like (Often and Lots once drew the same shelf); the nearest stop
    -- shows, so an unpinned shelf reads its default's word and a value from
    -- an older build cannot fall off the list.
    local function ornamentStop()
        local Orn = require("lib/bookshelf_ornaments")
        local ORN_STOPS = { { 0, _("None") }, { 0.5, _("Rarely") }, { 1, _("Often") }, { 2, _("Always") } }
        local v = draft.ornament_frequency
        if v == nil then v = Orn.FREQ_DEFAULT end
        local best, dist = 1, math.huge
        for i, st in ipairs(ORN_STOPS) do
            if math.abs(st[1] - v) < dist then best, dist = i, math.abs(st[1] - v) end
        end
        return ORN_STOPS, best
    end
    local function authorOn()
        local v = draft.spine_show_author
        if v == nil then return true end
        return v and true or false
    end
    local function spinesBlocks(pick, add)
        local Binding = require("lib/bookshelf_book_binding")
        -- Face out first: which books show their covers is the spine shelf's
        -- biggest choice (maintainer).
        add({ type = "row", label = _("Face out"), value = Editor._faceOutText(draft),
            icon = "\u{E7B9}",   -- book
            callback = function() Editor:_openFaceOut(draft, on_change) end })
        add(stepper(pick, _("Rows"), "spine_rows", 1, 6,
            bw and function()
                local ok, n = pcall(bw._nShelves, bw)
                return ok and n or 2
            end))
        -- Thickness: a multiplier on the page-count width, in steps of 10%;
        -- 100 is the default and stores nothing.
        local function thick(delta)
            return pick(function()
                local n = (draft.spine_thickness_pct or 100) + delta * 10
                n = math.max(60, math.min(200, n))
                draft.spine_thickness_pct = (n ~= 100) and n or nil
            end)
        end
        -- 100% is the default, not "Auto": Auto is the steppers' word for
        -- below the minimum, where the shelf works it out.
        add({ type = "stepper", label = _("Thickness"),
            value = tostring(draft.spine_thickness_pct or 100) .. "%",
            on_dec = thick(-1), on_inc = thick(1) })
        add({ type = "segmented", label = _("Book binding"),
            items = { { key = "hardcover", label = Binding.label("hardcover") },
                      { key = "paperback", label = Binding.label("paperback") } },
            active = (draft.book_binding == "paperback") and "paperback" or "hardcover",
            on_pick = function(v) pick(function()
                draft.book_binding = (v == "paperback") and "paperback" or nil
            end)() end })
        add(onOff(pick, _("Series boxes"), draft.series_boxes, function(v)
            draft.series_boxes = v or nil
        end))
        -- Stored as false only, nil meaning the default (on). Not
        -- `on and false or nil`: in Lua that is always nil (#439).
        add(onOff(pick, _("Author on spine"), authorOn(), function(v)
            if v then draft.spine_show_author = nil else draft.spine_show_author = false end
        end))
        local ORN_STOPS, best = ornamentStop()
        local items = {}
        for i, st in ipairs(ORN_STOPS) do items[i] = { key = i, label = st[2] } end
        add({ type = "segmented", label = _("Ornaments"), items = items, active = best,
            on_pick = function(i) pick(function() draft.ornament_frequency = ORN_STOPS[i][1] end)() end })
        -- A card's own shelf stands on a plank of its own (6.0); unset
        -- follows the main shelf's.
        if draft.card_only then
            add({ type = "row", label = _("Plank"), value = Editor._plankLabel(draft.plank),
                callback = function()
                    Editor:_pickCardPlank(draft, function()
                        if on_change then on_change() end
                    end)
                end })
        end
    end
    local function spinesSummary()
        local parts = { T(_("face out: %1"), Editor._faceOutText(draft)),
            T(_("rows: %1"), numText(draft.spine_rows)) }
        if draft.spine_thickness_pct then parts[#parts + 1] = T(_("%1% thick"), draft.spine_thickness_pct) end
        if draft.book_binding == "paperback" then parts[#parts + 1] = _("paperbacks") end
        if draft.series_boxes then parts[#parts + 1] = _("series boxes") end
        if not authorOn() then parts[#parts + 1] = _("no author on spines") end
        local ORN_STOPS, best = ornamentStop()
        parts[#parts + 1] = T(_("ornaments: %1"), ORN_STOPS[best][2])
        return Editor._capFirst(table.concat(parts, ", "))
    end

    -- Folder tiles: how group tiles are drawn, every style in view so the
    -- shelf behind shows each as it is tapped. Not for a catalogue (its
    -- subcatalogs have no artwork: every style is the same text tile). Cover
    -- captions: text below covers, this shelf's own (Reddit, after 5.4), on
    -- a page of its own since Custom opens the line editor.
    local function tilesLabel()
        local cur = StackDisplay.pinned(draft.group_display) or StackDisplay.FOLLOW_DEFAULT
        for _i, opt in ipairs(StackDisplay.CHIP_OPTIONS) do
            if opt.value == cur then return opt.label_func(), cur end
        end
        return "", cur
    end
    local function coversBlocks(pick, add)
        if not no_spines then
            local _l, cur = tilesLabel()
            local items = {}
            for _i, opt in ipairs(StackDisplay.CHIP_OPTIONS) do
                local value = opt.value
                items[#items + 1] = { text = opt.label_func(), on = value == cur,
                    callback = pick(function() draft.group_display = value end) }
            end
            add({ type = "heading", text = _("Folder tiles") })
            add({ type = "chips", items = items })
        end
        add({ type = "row", label = _("Cover captions"), icon = "\u{EA15}",   -- label-outline
            value = Editor._coverTextLabel(draft, draft.cover_text),
            callback = function()
                Editor:_pickCoverText(draft, function()
                    if on_change then on_change() end
                end, function() end, bw)
            end })
    end
    local function coversSummary()
        local parts = {}
        if not no_spines then
            -- Following the library reads "Default", as captions does: the
            -- chip says "Default setting" to stand apart from the styles.
            local label, cur = tilesLabel()
            if cur == StackDisplay.FOLLOW_DEFAULT then label = _("Default") end
            parts[#parts + 1] = T(_("folder tiles: %1"), label)
        end
        parts[#parts + 1] = T(_("captions: %1"), Editor._coverTextLabel(draft, draft.cover_text))
        return Editor._capFirst(table.concat(parts, ", "))
    end

    local function section(title, build, level)
        return function()
            open(title, function(pick)
                local blocks = {}
                build(pick, function(b) blocks[#blocks + 1] = b end, level)
                return { blocks = blocks }
            end)
        end
    end

    open(_("View mode"), function(pick)
        local blocks = {}
        local function add(b) blocks[#blocks + 1] = b end

        -- Show as pins the shelf to a style (or lets Auto choose per level);
        -- the sections below follow it. COVERS is the default and stores
        -- absence, so a shelf that never saw this page looks as it always
        -- did. A shelf of shelves is never drilled into, so Auto's levels
        -- would be one level: not offered there (maintainer, 2026-10-11),
        -- and one stored before shows as the style it gives.
        local mode = Editor._shownMode(draft[ViewMode.CHIP_KEY], no_spines)
        local is_shelves = TabModel.isShelves(draft)
        if is_shelves and mode == ViewMode.AUTO then
            mode = ViewMode.auto(draft, false)
            if mode == ViewMode.COVERS then mode = nil end
        end
        -- Order (maintainer): Auto first, as it is not a style but the
        -- choice to let the shelf pick; then Covers, the default.
        local show_items = {}
        if not is_shelves then show_items[#show_items + 1] = { key = "auto", label = _("Auto") } end
        show_items[#show_items + 1] = { key = "covers", label = _("Covers") }
        show_items[#show_items + 1] = { key = "list", label = _("List") }
        -- Not for a catalogue: remote records have nothing for spines to
        -- stand on, and the widget degrades a stored pin to covers there.
        if not (chrome and chrome.is_opds) then
            show_items[#show_items + 1] = { key = "spines", label = _("Spines") }
        end
        local active = (mode == ViewMode.AUTO and "auto") or (mode == ViewMode.LIST and "list")
            or (mode == ViewMode.SPINES and "spines") or "covers"
        local show_as = { type = "segmented", label = _("Show as"), items = show_items,
            active = active, on_pick = function(key) pick(function()
                draft[ViewMode.CHIP_KEY] = (key == "auto" and ViewMode.AUTO)
                    or (key == "list" and ViewMode.LIST)
                    or (key == "spines" and ViewMode.SPINES) or nil
            end)() end }

        -- Which sections to offer: the styles this shelf can show, its pin or
        -- under Auto each level's. chipPin, not `mode`: Covers is stored as
        -- ABSENCE, so mode is nil for a Covers shelf (a Covers shelf was once
        -- offered List columns that way).
        local pin = ViewMode.chipPin(mode)
        local no_spines = (chrome and chrome.is_opds) and true or false
        local shows = {}
        if pin == ViewMode.AUTO then
            shows[ViewMode.auto(draft, false)] = true
            shows[ViewMode.auto(draft, true)] = true
        else
            shows[pin] = true
        end
        local show_covers = shows[ViewMode.COVERS] == true
        local show_list   = shows[ViewMode.LIST] == true
        local show_spines = shows[ViewMode.SPINES] == true and not no_spines
        local show_levels = (pin == ViewMode.AUTO)

        add(show_as)

        -- Auto's levels: Level 1 is the shelf's top level, collapsed or
        -- expanded; Level 2 everything drilled into. A level on its default
        -- stores nothing.
        if show_levels then
            for level = 1, 2 do
                local key = ViewMode.LEVEL_KEYS[level]
                local items = {
                    { key = ViewMode.COVERS, label = _("Covers") },
                    { key = ViewMode.LIST, label = _("List") },
                }
                if not no_spines then items[#items + 1] = { key = ViewMode.SPINES, label = _("Spines") } end
                local shown = ViewMode.levelMode(draft[key], level)
                if no_spines and shown == ViewMode.SPINES then shown = ViewMode.COVERS end
                add({ type = "segmented",
                    label = (level == 1) and _("Top level") or _("Inside folders and stacks"),
                    items = items, active = shown,
                    on_pick = function(m) pick(function()
                        draft[key] = (m ~= ViewMode.LEVEL_DEFAULTS[level]) and m or nil
                    end)() end })
            end
        end

        -- One style: its settings right here (maintainer). Under Auto, a
        -- card per level, "Top level: Spines", each with its own page: two
        -- cards even when both levels show the same style, as a level can
        -- have settings of its own (List's columns and rows).
        local STYLES = {
            [ViewMode.SPINES] = { _("Spines"), spinesSummary, spinesBlocks },
            [ViewMode.LIST]   = { _("List"), listSummary, listBlocks },
            [ViewMode.COVERS] = { _("Covers"), coversSummary, coversBlocks },
        }
        if show_levels then
            add({ type = "heading", text = _("Settings") })
            for level = 1, 2 do
                local style = ViewMode.auto(draft, level == 2)
                if no_spines and style == ViewMode.SPINES then style = ViewMode.COVERS end
                local st = STYLES[style] or STYLES[ViewMode.COVERS]
                local title = T(_("%1: %2"),
                    (level == 1) and _("Top level") or _("Inside folders and stacks"), st[1])
                add({ type = "option", text = title .. CHEV, desc = st[2](level),
                    icon = Editor._modeIcon(style, no_spines),
                    callback = section(title, st[3], level) })
            end
        else
            local st = (show_spines and STYLES[ViewMode.SPINES])
                or (show_list and STYLES[ViewMode.LIST]) or STYLES[ViewMode.COVERS]
            -- No heading: Show as already names the style (maintainer).
            st[3](pick, add)
        end
        return { blocks = blocks }
    end, function() if chrome and chrome.show then chrome.show() end end)
end

-- The Face out reasons as the page and the Shelf style row name them.
local function _faceLabels()
    return {
        none      = _("None"),
        favorites = _("Favorites"),
        first     = _("First in series"),
        first_unread = _("First unread in series"),
        -- "Reading", as the book's long-press menu says it.
        reading   = _("Reading"),
        finished  = _("Finished"),
        on_hold   = _("On hold"),
        unread    = _("Unread"),
        standalone = _("Unread standalone"),
        collection = _("In a collection"),
        recent    = _("Recently added"),
        all       = _("All books"),
    }
end

-- _faceOutText(draft, full) -> the set, for the Shelf style row: "Favorites +
-- Reading", or how many past two (all of them with full).
function Editor._faceOutText(draft, full)
    local SS = require("lib/bookshelf_spine_shelf")
    local L = _faceLabels()
    local spec = SS.faceOutSpec(draft.spine_face_out)
    if spec.all then return L.all end
    if SS.faceOutEmpty(spec) then return L.none end
    local parts = {}
    for _i, k in ipairs(SS.FACE_REASONS) do
        if k == "recent" then
            if spec.recent then parts[#parts + 1] = T(_("Newest %1"), spec.recent) end
        elseif k == "collection" then
            if spec.collection then parts[#parts + 1] = spec.collection end
        elseif spec[k] then
            parts[#parts + 1] = L[k]
        end
    end
    -- Past two, the first and a count: "3 reasons" said nothing about which.
    if #parts > 2 and not full then return T(_("%1 + %2 more"), parts[1], #parts - 1) end
    return table.concat(parts, " + ")
end

-- _openFaceOut: which books stand face out (front cover, bookstore style).
-- Reasons are toggles, as a book can be a favourite AND newly added; All and
-- None are the whole-shelf answers. Each tap is saved (on_change) and the
-- page laid out again in place.
function Editor:_openFaceOut(draft, on_change)
    local SS = require("lib/bookshelf_spine_shelf")
    local L = _faceLabels()
    local d
    local function spec() return SS.faceOutSpec(draft.spine_face_out) end
    -- Written back in the SIMPLEST shape that carries the set, so a shelf
    -- using one reason still stores the string it always did and an
    -- untouched setting never grows a table: nil = favourites (the default),
    -- false = none.
    local function save(sp)
        if sp.all then draft.spine_face_out = "all"; return end
        local n, only = 0, nil
        for _i, k in ipairs(SS.FACE_REASONS) do
            if sp[k] then n = n + 1; only = k end
        end
        if n == 0 then draft.spine_face_out = false
        elseif n == 1 and only ~= "recent" and only ~= "collection" then
            draft.spine_face_out = (only == "favorites") and nil or only
        else
            draft.spine_face_out = sp
        end
    end
    local function changed()
        if on_change then on_change() end
        if d and d.refresh then d:refresh() end
    end
    local function isOn(sp, k)
        if k == "recent" then return sp.recent ~= nil end
        if k == "collection" then return sp.collection ~= nil end
        return sp[k] == true
    end
    local function pickCollection()
        self:_pickFaceCollection(draft, function()
            if on_change then on_change() end
        end, function() end)
    end
    local function toggle(k, icon)
        local sp = spec()
        return { text = L[k], icon = icon, on = (not sp.all) and isOn(sp, k), callback = function()
            local n = spec()
            -- Switching the collection reason ON needs a name first.
            if k == "collection" and not n.collection then return pickCollection() end
            n.all = nil     -- a reason un-picks "All"
            if k == "recent" then
                n.recent = (n.recent == nil) and SS.FACE_RECENT_DEFAULT or nil
            elseif k == "collection" then
                n.collection = nil
            else
                n[k] = (not n[k]) or nil
            end
            save(n)
            changed()
        end }
    end

    local function page()
        local sp = spec()
        -- What the page is for, not what is ticked below it (maintainer).
        local summary = _("Choose which books show their cover facing out on this shelf. The rest show their spines.")
        local none = (not sp.all) and SS.faceOutEmpty(sp)
        local blocks = {
            -- Reading state first, the reasons most people answer with, in
            -- the order the book's long-press menu sets them.
            { type = "heading", text = _("Reading status") },
            { type = "chips", items = { toggle("unread"), toggle("reading"),
                toggle("on_hold"), toggle("finished") } },
            -- The series reasons together: the same question asked of a
            -- series started and one not.
            { type = "heading", text = _("Series") },
            { type = "chips", items = { toggle("first"), toggle("first_unread"), toggle("standalone") } },
            { type = "heading", text = _("Other") },
            { type = "chips", items = { toggle("favorites", Editor._favGlyph()),
                toggle("recent"), toggle("collection") } },
        }
        if sp.recent and not sp.all then
            -- How many count as recently added: a 20-book shelf and a
            -- 2000-book one want different answers.
            local items = {}
            for _i, n in ipairs({ 1, 3, 5, 10, 20 }) do items[#items + 1] = { key = n, label = tostring(n) } end
            blocks[#blocks + 1] = { type = "segmented", label = _("How many of the newest"), items = items,
                active = sp.recent, on_pick = function(n)
                    local x = spec(); x.recent = n; x.all = nil; save(x); changed()
                end }
        end
        if sp.collection and not sp.all then
            local name = sp.collection
            -- Deleted or renamed since: say so, rather than a tick on a
            -- shelf that faces nothing out.
            local ok_rc, rc = pcall(require, "readcollection")
            if ok_rc and rc and rc.coll and rc.coll[name] == nil then
                name = T(_("%1 (not found)"), name)
            end
            blocks[#blocks + 1] = { type = "row", label = _("Collection"), value = name,
                callback = pickCollection }
        end
        blocks[#blocks + 1] = { type = "heading", text = _("Whole shelf") }
        blocks[#blocks + 1] = { type = "chips", items = {
            { text = L.all, on = sp.all == true, callback = function()
                draft.spine_face_out = "all"; changed() end },
            { text = L.none, on = none, callback = function()
                draft.spine_face_out = false; changed() end },
        } }
        return { strip = { { type = "summary", text = summary } }, blocks = blocks }
    end
    d = Editor._menu{
        title  = _("Face out"),
        page   = page,
        anchor = _highAnchor(function() return d end),
    }
    return d
end

-- _plankLabel(choice) -> a card shelf's plank as its row names it.
function Editor._plankLabel(choice)
    if choice == nil then return _("Same as main shelf") end
    if choice == "colour" then return _("Plain color") end
    if choice == "oak" then return _("Oak") end
    local ok, TP = pcall(require, "lib/bookshelf_theme_pack")
    local pl = ok and TP and TP._packPlank and TP._packPlank(choice)
    if pl then return (pl.pack and pl.name) and T(_("%1 (%2 pack)"), pl.name, pl.pack) or (pl.name or choice) end
    return choice
end

-- _pickCardPlank(draft, done): a card shelf's plank, from the same options
-- as the plank picker (ThemePack.plankOptions), plus following the main
-- shelf. done() after a pick or a close.
function Editor:_pickCardPlank(draft, done)
    local PB = require("lib/bookshelf_plank_browser")
    local TP = require("lib/bookshelf_theme_pack")
    local d
    -- A page of the planks, the one in use black; a tap picks it, shows on
    -- the shelf behind (done), and the page stays for another try.
    local function choose(v)
        return function()
            draft.plank = v
            done()
            if d and d.refresh then d:refresh() end
        end
    end
    local function page()
        local items = { { text = Editor._plankLabel(nil), on = draft.plank == nil, callback = choose(nil) } }
        for _i, o in ipairs(TP.plankOptions()) do
            local v = PB.choiceOf(o)
            if v ~= nil then
                items[#items + 1] = { text = Editor._plankLabel(v), on = draft.plank == v, callback = choose(v) }
            end
        end
        return { blocks = {
            { type = "hint", text = _("The plank this module's shelf stands on.") },
            { type = "chips", items = items },
        } }
    end
    d = Editor._menu{
        title   = _("Plank"),
        page    = page,
        on_back = done,
        anchor  = _highAnchor(function() return d end),
    }
end

-- _coverTextRow(draft, on_change, close, reshow, bw) -> Shelf style's
-- "Cover captions: Title" button, opening its picker (_pickCoverText).
-- `close` takes Shelf style down, `reshow` brings it back.
function Editor:_coverTextRow(draft, on_change, close, reshow, bw)
    return {{
        text_func = function()
            return T(_("Cover captions: %1"), Editor._coverTextLabel(draft, draft.cover_text))
        end,
        callback = function()
            close()
            Editor:_pickCoverText(draft, on_change, reshow, bw)
        end,
    }}
end

-- The choices, laid out as a grid rather than a column of one per row (on
-- the PW5 the column was seven rows for one question, maintainer
-- 2026-10-10): what it follows and None, the line's contents, then Custom.
-- "follow" is unset.
local COVER_TEXT_LAYOUT = { { "follow", "none" }, { "title", "author", "series" }, { "custom" } }

-- _coverTextLabel(draft, value) -> how a choice reads: its name, or for
-- unset what it follows, "Default" (Cover display's) or "Same as Fiction"
-- (a sub-shelf's shelf of shelves).
function Editor._coverTextLabel(draft, value)
    if value == "title"  then return _("Title") end
    if value == "author" then return _("Author") end
    if value == "series" then return _("Series") end
    if value == "custom" then return _("Custom") end
    if value == "none"   then return _("None") end
    if draft.parent ~= nil then
        local parent = TabModel.getById(draft.parent)
        return T(_("Same as %1"), (parent and parent.label) or draft.parent)
    end
    return _("Default")
end

-- _pickCoverText(draft, on_change, back, bw): the shelf's own text below
-- covers. A pick is written to the draft, shown on the shelf, and hands back
-- to Shelf style: one question, one answer, and no close-and-reopen of this
-- picker per tap, which flashes the whole screen on a Kindle (see the Face
-- out picker). Custom... opens the line editor on the shelf's own line
-- (CoverLabelEditor.showForShelf), and its Save is what makes Custom the
-- choice, as in Cover display. Back returns unchanged.
function Editor:_pickCoverText(draft, on_change, back, bw)
    local CL = require("lib/bookshelf_cover_label")
    local d
    -- A page: the lines a cover can carry as chips (the one in use black),
    -- and a line of the reader's own, which opens its editor. A pick shows on
    -- the shelf behind at once (on_change) and the page stays.
    local function page()
        local cur = draft.cover_text
        local items = {}
        for _i, layout_row in ipairs(COVER_TEXT_LAYOUT) do
            for _j, v in ipairs(layout_row) do
                if v ~= "custom" then
                    local value = (v ~= "follow") and v or nil
                    items[#items + 1] = { text = Editor._coverTextLabel(draft, value), on = cur == value,
                        callback = function()
                            draft.cover_text = value
                            on_change()
                            if d and d.refresh then d:refresh() end
                        end }
                end
            end
        end
        return { blocks = {
            { type = "hint", text = _("The text under each cover on this shelf.") },
            { type = "chips", items = items },
            { type = "option", text = _("A line of your own") .. " \xE2\x80\xBA", on = cur == "custom",
              desc = _("Choose what it shows, from the book's details."),
              callback = function()
                  -- Starts from the shelf's own line, else the one it shows
                  -- now, so Custom changes nothing until it is edited.
                  require("lib/bookshelf_cover_label_editor").showForShelf(bw, {
                      line = draft.cover_text_line or CL.lineFor(draft.id),
                      save = function(l)
                          draft.cover_text_line = CL.normalise(l)
                          draft.cover_text = "custom"
                          on_change()
                      end,
                      on_closed = function() if d and d.refresh then d:refresh() end end,
                  })
              end },
        } }
    end
    d = Editor._menu{
        title   = _("Cover captions"),
        page    = page,
        on_back = back,
        anchor  = _highAnchor(function() return d end),
    }
end

-- _pickSource(draft, on_close) -- the Source page: Grouped (a stack for
-- each) and Just one; a kind that needs an id (a folder, a collection, a
-- genre, an author...) opens a picker of its own, as a page of the editor,
-- populated from real data (the folder list, ReadCollection, or the
-- repository's group fetchers).
-- _searchGrid(spec) -> a LibraryModal shown as a page of the editor: a
-- search box, two columns of picker cells (bookshelf_picker_cell), and with
-- spec.sortable (and choices that carry book counts) an A-Z | Most books
-- switch beside the search box, the order kept for the session. The Source
-- page's pickers and the filter pickers share it.
--   spec.choices { {value, label, count?}... }, spec.title, spec.over,
--   spec.selected(item) -> ticked (a multi-select), spec.select_on_tap,
--   spec.on_cell_tap(item), spec.cell_long_tap(item), spec.header_actions,
--   spec.footer_actions
function Editor._searchGrid(spec)
    local LibraryModal = require("lib/bookshelf_library_modal")
    local PickerSort = require("lib/bookshelf_picker_sort")
    local Screen_ = require("device").screen
    local choices = spec.choices or {}
    local sortable = spec.sortable and PickerSort.hasCounts(choices)
    if sortable then choices = PickerSort.sort(choices, Editor._picker_order) end
    local query, visible = nil, choices
    local function recompute()
        if not query or query == "" then visible = choices; return end
        visible = {}
        local q = query:lower()
        for _i, c in ipairs(choices) do
            if c.label:lower():find(q, 1, true) then visible[#visible + 1] = c end
        end
    end
    local modal
    modal = LibraryModal:new{ config = {
        title              = spec.title,
        over               = spec.over,
        search_placeholder = function() return _("Search\xE2\x80\xA6") end,
        on_search_submit   = function(q)
            query = q
            recompute()
            if modal then modal.page = 1; modal:refresh() end
        end,
        chip_strip = sortable and function()
            local items = {}
            for _i, it in ipairs(PickerSort.items()) do
                items[#items + 1] = { key = it.key, label = it.label,
                    is_active = it.key == (Editor._picker_order or "az") }
            end
            return items
        end or nil,
        chips_beside_search = true,
        on_chip_tap = function(key)
            Editor._picker_order = key
            choices = PickerSort.sort(choices, key)
            recompute()
        end,
        grid_cols      = 2,
        -- 5 rows portrait, 4 landscape.
        cells_per_page = function()
            return Screen_:getWidth() > Screen_:getHeight() and 8 or 10
        end,
        item_count  = function() return #visible end,
        item_at     = function(idx) return visible[idx] end,
        -- The same cell in every picker and in the Collection Manager.
        cell_renderer = function(item, dimen)
            return require("lib/bookshelf_picker_cell").render(item, dimen,
                spec.selected and { selected = spec.selected(item) } or nil)
        end,
        select_on_tap  = spec.select_on_tap,
        on_cell_tap    = spec.on_cell_tap,
        cell_long_tap  = spec.cell_long_tap,
        header_actions = spec.header_actions,
        footer_actions = spec.footer_actions,
    } }
    UIManager:show(modal)
    return modal
end

function Editor:_pickSource(draft, on_close)
    local Repo = require("lib/bookshelf_book_repository")
    local d

    -- pickById: a searchable picker (Editor._searchGrid) for choosing one
    -- of a list (collections, genres, authors...).
    -- The picker's breadcrumb, by kind.
    local PICK_CRUMB = {
        series = _("Series"), author = _("Author"), genre = _("Genre"),
        format = _("Format"), language = _("Language"), rating = _("Rating"),
        collection = _("Collection"), folder = _("Folder"),
        ["OPDS catalog"] = _("OPDS catalog"),
    }
    local function pickById(kind, choices, on_pick, opts)
        local modal
        modal = Editor._searchGrid{
            choices  = choices,
            sortable = true,
            title    = (opts and opts.title) or PICK_CRUMB[kind] or kind,
            -- A page of the editor: Home > Source > Series.
            over     = Editor._over({
                TabModel.isCardOnly(draft) and _("Shelf module source") or _("Source"),
                PICK_CRUMB[kind] or kind }),
            -- No selected state: pickers are one-shot select-and-close.
            on_cell_tap = function(item)
                UIManager:close(modal)
                on_pick(item.value)
            end,
            cell_long_tap = (opts and opts.on_cell_hold) and function(item)
                UIManager:close(modal)
                opts.on_cell_hold(item)
            end or nil,
            -- Extra actions (the folder picker's Browse device, Add
            -- catalog...) are the screen's own: on the strip under the
            -- title, each closing the picker before it runs.
            header_actions = (function()
                local actions = {}
                for _i, a in ipairs(opts and opts.extra_footer_actions or {}) do
                    actions[#actions + 1] = { label = a.label, on_tap = function()
                        UIManager:close(modal)
                        a.on_tap()
                    end }
                end
                return actions
            end)(),
            -- Close signals cancel with nil, so the caller can reopen the
            -- picker it came from rather than dropping back to the editor.
            footer_actions = { { label = _("Close"), on_tap = function()
                UIManager:close(modal)
                on_pick(nil)
            end } },
        }
    end
    -- Built-in shortcuts + working custom kinds.
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
            Editor._closeMenu(d)
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
        Editor._closeMenu(d)
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
        Editor._closeMenu(d)
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
        Editor._closeMenu(d)
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

    -- OPDS catalogue picker AND manager. Rows come from bookshelf's own catalog
    -- store (Catalogs.list gives stock-shaped records), which reads/writes the
    -- same opds.lua as the stock plugin. Tap selects a catalogue for this chip;
    -- the "Add catalog" footer button and long-press Edit/Delete manage the
    -- list, so the stock opds plugin is no longer needed to add catalogues.
    local function open_opds_picker()
        local Catalogs   = require("lib/bookshelf_opds_catalogs")
        local Editor_    = require("lib/bookshelf_opds_catalog_editor")
        local OpdsSource = require("lib/bookshelf_opds_source")

        local function build_choices()
            local choices = {}
            for _i, s in ipairs(Catalogs.list() or {}) do
                choices[#choices + 1] = {
                    value    = OpdsSource.serverKey(s.url),
                    label    = s.title,
                    subtitle = s.url,
                    _catalog = s,   -- carry the raw record for edit/delete
                }
            end
            return choices
        end

        Editor._closeMenu(d)

        local reopen  -- forward declaration so handlers can re-open the picker
        reopen = function()
            pickById("OPDS catalog", build_choices(), function(picked)
                if not picked then
                    Editor:_pickSource(draft, on_close)
                    return
                end
                draft.source = { kind = "opds", id = picked }
                _applySourceDefaults(draft)
                on_close()
            end, {
                title = _("Choose OPDS catalog"),
                extra_footer_actions = {
                    { label = _("Add catalog\xE2\x80\xA6"), on_tap = function()
                        Editor_.show{ on_saved = reopen, on_cancel = reopen }
                    end },
                },
                on_cell_hold = function(item)
                    if not item or not item._catalog then
                        reopen(); return
                    end
                    local menu
                    menu = Editor._menu{
                        -- The catalog's name as its title: the breadcrumb
                        -- read "Shelf > …" with none.
                        title = item.label or item._catalog.title,
                        -- Dismissing the menu (tap outside) returns to the
                        -- picker rather than dropping out to the chip editor.
                        tap_close_callback = reopen,
                        buttons = {
                            {{ text = _("Edit"), callback = function()
                                Editor._closeMenu(menu)
                                Editor_.show{ item = item._catalog, on_saved = reopen, on_cancel = reopen }
                            end }},
                            {{ text = _("Delete"), callback = function()
                                Editor._closeMenu(menu)
                                Editor_.confirmDelete{ item = item._catalog, on_deleted = reopen, on_cancel = reopen }
                            end }},
                        },
                    }
                end,
            })
        end
        reopen()
    end

    -- Folder picker: flat list of every directory under home_dir that
    -- contains a book at any depth. Each choice carries the full path as a
    -- subtitle (rendered by pickById's cell renderer) so duplicate basenames
    -- can be disambiguated. The picked path is the source id; getBySource
    -- prefix-matches it against book filepaths.
    -- folder_kind is "folder" (tree view, subfolders as cards) or
    -- "folder_flat" (#76: every book under the path, no folder cards).
    -- Both share the same picker + Browse-device flow; only the stored
    -- source kind differs.
    local function open_folder_picker(folder_kind)
        folder_kind = folder_kind or "folder"
        local choices = Repo.getFolderChoices() or {}
        Editor._closeMenu(d)

        local function pick_path(picked)
            draft.source = { kind = folder_kind, id = picked }
            _applySourceDefaults(draft)
            on_close()
        end

        -- "Browse device": KOReader's own folder navigator, unrooted, so any
        -- folder on the device can back a chip -- including ones outside the
        -- home folder that getFolderChoices (home-tree + book-bearing only)
        -- never offers. Folder-only config matches Settings:_pickImageLibraryPath.
        local function browse_device()
            local PathChooser = require("ui/widget/pathchooser")
            local confirmed = false
            UIManager:show(PathChooser:new{
                path             = require("lib/bookshelf_home_dir").get() or "/",
                select_directory = true,
                select_file      = false,
                show_files       = false,
                onConfirm        = function(folder)
                    confirmed = true
                    -- Normalise to getFolderChoices' no-trailing-slash id form
                    -- so both entry points store the path identically.
                    folder = (folder == "/") and "/" or folder:gsub("/+$", "")
                    pick_path(folder)
                end,
                -- Backing out of the browser without choosing returns to the
                -- source picker rather than dropping to the shelf -- the
                -- editor's dialog `d` was already closed when the flat-list
                -- picker opened, so there's nothing underneath to fall back to.
                -- close_callback fires on any close, hence the confirmed guard.
                close_callback   = function()
                    if not confirmed then
                        Editor:_pickSource(draft, on_close)
                    end
                end,
            })
        end

        pickById("folder", choices, function(picked)
            if not picked then
                Editor:_pickSource(draft, on_close)
                return
            end
            pick_path(picked)
        end, {
            title = _("Choose folder within home folder"),
            extra_footer_actions = {
                { label = _("Browse device\xE2\x80\xA6"), on_tap = browse_device },
            },
        })
    end

    local cur = draft.source and draft.source.kind
    local cur_id = draft.source and draft.source.id
    local function idText(id)
        if type(id) ~= "string" or id == "" then return nil end
        return id:match("([^/]+)/?$") or id
    end
    local CHEV = " \xE2\x80\xBA"
    -- What the Home and folder sources show, in a line on their cards.
    local DESC = {
        library   = _("Every book, ungrouped."),
        all       = _("Grouped by folder."),
        folder_flat = _("Every book in one folder and its subfolders."),
    }
    local function chip(kind_value, label)
        return { text = label, on = cur == kind_value, callback = set_simple(kind_value) }
    end
    -- A stack source: a tile for each series, author...
    local function stackChip(kind_value, label, icon)
        return { text = label, icon = icon, on = cur == kind_value, callback = set_simple(kind_value) }
    end
    -- A shelf of one of them, picked from a list; once picked it names it.
    local function oneChip(specific, label, on_pick)
        local on = cur == specific
        return { text = (on and idText(cur_id) and (label .. ": " .. idText(cur_id)) or label) .. CHEV,
            on = on, callback = on_pick }
    end
    -- A module's shelf: one of a kind only.
    local function one(specific, label, on_pick)
        local on = cur == specific
        return { type = "row", half = true, label = label,
            value = on and idText(cur_id) or _("Pick one"), on = on, callback = on_pick }
    end
    local function group_pick(kind_value)
        return function() open_group_picker(kind_value, kind_value,
            kind_value == "series" and "single_series" or kind_value) end
    end

    local function page()
        local blocks = {}
        local function add(b) blocks[#blocks + 1] = b end
        local card_only = TabModel.isCardOnly(draft)
        local more
        add({ type = "heading", text = _("Books") })
        if card_only then
            -- The module shows a folder shelf's books flattened anyway (its
            -- bookSource), so the folder-tree twins were the same shelf twice
            -- (maintainer).
            add({ type = "option", half = true, text = _("Home"), desc = DESC.library,
                on = cur == "library", callback = set_simple("library") })
            add({ type = "option", half = true, text = _("A folder"), desc = DESC.folder_flat,
                on = cur == "folder_flat", callback = function() open_folder_picker("folder_flat") end })
        else
            add({ type = "option", half = true, text = _("Home (flattened)"), desc = DESC.library,
                icon = "\u{EA31}",
                on = cur == "library", callback = set_simple("library") })
            add({ type = "option", half = true, text = _("Home (folders)"), desc = DESC.all,
                icon = "\u{E952}",
                on = cur == "all", callback = set_simple("all") })
            -- One folder, as folders or flattened (#76): the same picker,
            -- differing only in how the shelf draws it.
            add({ type = "option", text = _("A folder"), icon = "\u{E94A}",
                desc = ((cur == "folder" or cur == "folder_flat") and idText(cur_id)) or _("Any folder on the device."),
                on = cur == "folder" or cur == "folder_flat",
                callback = function() open_folder_picker("folder") end,
                links = {
                    { text = _("As folders") .. CHEV, on = cur == "folder",
                      callback = function() open_folder_picker("folder") end },
                    { text = _("Flattened") .. CHEV, on = cur == "folder_flat",
                      callback = function() open_folder_picker("folder_flat") end },
                } })
        end
        add({ type = "chips", items = {
            chip("recent", _("Recently read")),
            chip("latest", _("Latest added")),
            { text = _("Favorites"), icon = Editor._favGlyph(), on = cur == "favorites",
              callback = set_simple("favorites") },
        } })
        if card_only then
            -- It shows books, so no stacks (series, authors, a shelf of
            -- shelves...) and nothing online; a shelf of one of them is books.
            add({ type = "heading", text = _("Just one") })
            add(one("single_series", _("Series"), group_pick("series")))
            add(one("author", _("Author"), group_pick("author")))
            add(one("genre", _("Genre"), group_pick("genre")))
            add(one("collection", _("Collection"), open_tag_picker))
            add(one("format", _("Format"), group_pick("format")))
            add(one("rating", _("Rating"), open_rating_picker))
            add(one("language", _("Language"), group_pick("language")))
        else
            -- Grouped: what readers looked for and did not find under
            -- "Source" (maintainer). Stacks and a shelf of one of them are
            -- two sections, so each reads as a choice of its own.
            add({ type = "heading", text = _("Grouped: a stack for each") })
            add({ type = "chips", items = {
                stackChip("series", _("Series"), "\u{E97A}"),
                stackChip("authors", _("Authors"), "\u{E703}"),
                stackChip("genres", _("Genres"), "\u{EA14}"),
                stackChip("tags", _("Collections"), "\u{E7BF}"),
                stackChip("formats", _("Formats"), "\u{E918}"),
                stackChip("ratings", _("Ratings"), "\u{EBCD}"),
                stackChip("languages", _("Languages"), "\u{ECC9}"),
            } })
            add({ type = "heading", text = _("Just one") })
            add({ type = "chips", items = {
                oneChip("single_series", _("A series"), group_pick("series")),
                oneChip("author", _("An author"), group_pick("author")),
                oneChip("genre", _("A genre"), group_pick("genre")),
                oneChip("collection", _("A collection"), open_tag_picker),
                oneChip("format", _("A format"), group_pick("format")),
                oneChip("rating", _("A rating"), open_rating_picker),
                oneChip("language", _("A language"), group_pick("language")),
            } })
            add({ type = "heading", text = _("More") })
            -- Shelf of shelves (5.4): tiles that are shelves of their own.
            -- OPDS always offered, even with no catalog set up yet: its
            -- picker is also where catalogs are added, edited and deleted.
            more = {
                { text = _("Shelf of shelves"), on = cur == "shelves", callback = set_simple("shelves") },
                { text = ((cur == "opds") and _resolveSourceLabel(draft.source) or _("OPDS catalog")) .. CHEV,
                  on = cur == "opds", callback = function() open_opds_picker() end },
            }
        end
        -- Registered sources (lib/bookshelf_sources): the Kindle's own
        -- library, and any plugin's (issue 452), shown only when usable.
        local Sources = require("lib/bookshelf_sources")
        for _i, id in ipairs(Sources.pickerIds()) do
            local spec = Sources.get(id)
            local on_tap = set_simple(id)
            if spec.pick then
                -- The source asks its own question (which server, which
                -- library) and fills draft.source; done() carries on as a
                -- plain pick would.
                on_tap = function()
                    Editor._closeMenu(d)
                    local prev = draft.source
                    draft.source = { kind = id }
                    local ok = Sources.call(spec, "pick", draft, function(accepted)
                        if accepted == false then draft.source = prev; on_close() return end
                        if type(draft.source) ~= "table" then draft.source = { kind = id } end
                        draft.source.kind = id
                        _applySourceDefaults(draft)
                        on_close()
                    end)
                    if not ok then draft.source = prev; on_close() end
                end
            end
            more = more or {}
            more[#more + 1] = { text = Sources.label(id) or id, on = cur == id, callback = on_tap }
        end
        if more then
            if card_only then add({ type = "heading", text = _("More") }) end
            add({ type = "chips", items = more })
        end
        return { blocks = blocks }
    end

    d = Editor._menu{
        -- A module's shelf is offered no grouping, so the title says what it
        -- is choosing (maintainer).
        title   = TabModel.isCardOnly(draft) and _("Shelf module source") or _("Source"),
        page    = page,
        on_back = on_close,
        anchor  = _highAnchor(function() return d end),
    }
end

-- Each filter's icon on the Filters page.
local FILTER_ICONS = {
    statuses = "\u{ECDF}",          -- check-circle
    genres = "\u{EA14}",            -- label
    langs = "\u{ECC9}",             -- translate
    formats = "\u{E918}",           -- file-document
    ratings = "\u{EBCD}",           -- star
    collections = "\u{E7BF}",       -- bookmark
    series_membership = "\u{E97A}", -- format-list-numbers
    folders = "\u{E94A}",           -- folder
}

function Editor:_openFilters(draft, on_close)
    draft.filter = draft.filter or {}
    local d
    local function changed()
        if on_close then on_close() end
        if d and d.refresh then d:refresh() end
    end
    local function dimOn(key)
        return Filter.dimSummary(draft.filter, key) ~= Filter.dimSummary({}, key)
    end
    -- A filter's own picker opens over this page; this page is laid out
    -- again when it closes, its rows saying what was picked.
    local function openDim(dim)
        local back = function() if on_close then on_close() end end
        if dim.kind == "folder" then
            Editor:_pickFolderFilter(draft, back)
        elseif #Filter.dimKeys(dim.key) > 1 then
            Editor:_pickSetsFilter(draft, dim.key, back)
        elseif dim.kind == "choice" then
            Editor:_pickChoiceFilter(draft, dim.key, back)
        else
            Editor:_pickMultiFilter(draft, dim.key, back)
        end
    end
    local function page()
        local dims = Filter.dimensions()
        local set = {}
        local rows = {}
        for _i, dim in ipairs(dims) do
            local key = dim.key
            local on = dimOn(key)
            if on then set[#set + 1] = T("%1: %2", dim.label, Filter.dimSummary(draft.filter, key)) end
            rows[#rows + 1] = { type = "row", half = true, label = dim.label, icon = FILTER_ICONS[key],
                value = Filter.dimSummary(draft.filter, key), on = on,
                callback = function() openDim(dim) end,
                on_clear = function()
                    for _j, k in ipairs(Filter.dimKeys(key)) do draft.filter[k] = nil end
                    changed()
                end }
        end
        -- What the page is for; the rows say what is set (maintainer).
        local strip = { { type = "summary", text = _("Books matching the filters you choose below will show in this shelf.") } }
        if #set > 0 then
            strip[#strip + 1] = { type = "chips", items = { { text = _("Clear all filters"),
                callback = function() draft.filter = {}; changed() end } } }
        end
        return { strip = strip, blocks = rows }
    end
    d = Editor._menu{
        title   = _("Filters"),
        page    = page,
        anchor  = _highAnchor(function() return d end),
    }
end

-- Generic multi-select picker for a categorical dimension. Status uses a fixed
-- value list; the others enumerate distinct library values via Repo.
-- Single-choice ("choice" kind) filter picker -- currently only the Series
-- dimension (standalone vs in a series). A page of options, the active one
-- marked; tapping sets it and goes back to the filter list. "both" persists
-- as an explicit value: on
-- book-list chips it still compiles to no effect, but the Series source reads
-- it to mix standalone books in with the stacks (#160).
-- Leaving it goes back to the filter list via on_close.
function Editor:_pickChoiceFilter(draft, dim_key, on_close)
    draft.filter = draft.filter or {}
    local values = (dim_key == "series_membership") and Filter.seriesValues() or {}
    -- The UNSET marker must show what unset actually DOES (issue 350). On a
    -- book-list chip an absent value compiles to no effect, i.e. "both"; but
    -- the SERIES source reads absent as its historical stacks-only mode, so
    -- marking "both" there claimed a state the shelf was not in.
    local unset_means = "both"
    if dim_key == "series_membership"
            and draft.source and draft.source.kind == "series" then
        unset_means = "in_series"
    end
    local d
    -- A page: one card per choice, the one in force black; a tap sets it and
    -- goes back to Filters, where its row now reads it.
    local function page()
        local current = draft.filter[dim_key] or unset_means
        local blocks = {}
        for _i, v in ipairs(values) do
            local value = v.value
            blocks[#blocks + 1] = { type = "option", text = v.label, on = value == current,
                callback = function()
                    draft.filter[dim_key] = value
                    Editor._closeMenu(d)
                    on_close()
                end }
        end
        return { blocks = blocks }
    end
    d = Editor._menu{
        -- The filter's own name, as its row on Filters says it: the
        -- breadcrumb reads Home > Filters > Series.
        title   = _("Series"),
        page    = page,
        on_back = on_close,
        anchor  = _highAnchor(function() return d end),
    }
end

-- opts.set_key: the list of the filter it ticks (a genre's genres_all,
-- genres_not; default its any-of list), opts.crumb: its name in the
-- breadcrumb.
function Editor:_pickMultiFilter(draft, dim_key, on_close, opts)
    draft.filter = draft.filter or {}
    local set_key = opts and opts.set_key or dim_key
    draft.filter[set_key] = draft.filter[set_key] or {}
    local sel = draft.filter[set_key]

    local titles = {
        statuses    = _("Reading status filter"),
        genres      = _("Genre filter"),
        langs       = _("Language filter"),
        formats     = _("Format filter"),
        ratings     = _("Rating filter"),
        collections = _("Collection filter"),
    }
    local title = titles[dim_key] or _("Filter")
    local function dimLabel(key)
        for _i, dim in ipairs(Filter.dimensions()) do if dim.key == key then return dim.label end end
    end

    -- Build choices list.
    local choices
    local Repo = require("lib/bookshelf_book_repository")
    if dim_key == "statuses" then
        choices = {}
        for _i, v in ipairs(Filter.statusValues()) do
            choices[#choices + 1] = { value = v.value, label = v.label }
        end
    elseif dim_key == "ratings" then
        choices = {}
        for _i, v in ipairs(Filter.ratingValues()) do
            choices[#choices + 1] = { value = v.value, label = v.label }
        end
    else
        choices = Repo.distinctFilterValues(dim_key, draft.source) or {}
    end

    -- Overlay faceted counts: replace static library totals with counts
    -- reflecting the OTHER active filter dimensions (filter minus dim_key).
    -- Computed once here (picker open); stable while the user toggles within
    -- this dimension because those selections are excluded. nil return means
    -- no other dim is active so static counts already reflect reality.
    --
    -- draft.source scopes both halves to the chip's own source, so a Kindle or
    -- Kobo chip offers and counts ITS books rather than the walked library's.
    local facet = Repo.filterValueCounts(dim_key, draft.filter, draft.source)
    if facet then
        for _i, c in ipairs(choices) do c.count = facet[c.value] or 0 end
    end


    -- A-Z or most books first, as the Source page's pickers (statuses and
    -- ratings are short fixed lists, kept in their own order).
    local modal
    modal = Editor._searchGrid{
        choices  = choices,
        sortable = dim_key ~= "statuses" and dim_key ~= "ratings",
        title    = title,
        -- A page of the editor, over the Filters page it came from, named as
        -- its row there names it (Home > Filters > Genre).
        over     = Editor._over({ opts and opts.crumb or dimLabel(dim_key) or title }),
        selected = function(item) return sel[item.value] == true end,
        -- A tick marks the value at once (no pressed look first), in place:
        -- never close and reopen (that lost the page).
        select_on_tap = true,
        on_cell_tap = function(item)
            if sel[item.value] then sel[item.value] = nil else sel[item.value] = true end
            -- That card alone, not the whole picker (perf review 2026-10-31).
            modal:refreshCell(item)
        end,
        -- Clear: the screen's own action, on the strip under the title. The
        -- set is emptied in place, so `sel` stays the draft's.
        header_actions = { { label = _("Clear"), on_tap = function()
            for k in pairs(sel) do sel[k] = nil end
            modal:refresh()
        end } },
        -- Back to the Filters list: a button of its own, as with several to
        -- tick the chevron wasn't an obvious way on (maintainer). Back (the
        -- chevron, or the keys') runs it too (done); the X closes the
        -- editor, which keeps the ticks as well (finish).
        footer_actions = { { label = _("Apply"), done = true, primary = true, on_tap = function()
            UIManager:close(modal)
            on_close()
        end } },
    }
end

-- Genre and Collection as pages of lists, as Folders is: what a book needs
-- any of, all of (genres) and none of (GitHub issues 293, 453). Each list
-- adds through the filter's own picker, ticking that list.
local CROSS = "\xE2\x9C\x95"   -- U+2715, as on the book menu's tags

-- Each list's logic (OR, AND, NOT) is a tag beside its heading, for readers
-- who know it, not the end of the heading's sentence (maintainer).
local SET_SECTIONS = {
    genres = {
        { key = "genres",      heading = _("Any of these genres"), tag = _("OR") },
        { key = "genres_all",  heading = _("All of these genres"), tag = _("AND") },
        { key = "genres_not",  heading = _("Leave out these genres"), tag = _("NOT") },
        add = _("Add genres"),
        hint = _("A book needs one genre from the first list, every genre in the second and none from the third. An empty list is ignored."),
    },
    collections = {
        { key = "collections",     heading = _("In any of these collections"), tag = _("OR") },
        { key = "collections_not", heading = _("Leave out these collections"), tag = _("NOT") },
        add = _("Add collections"),
        hint = _("A book needs to be in one collection from the first list and in none from the second. An empty list is ignored."),
    },
}

function Editor:_pickSetsFilter(draft, dim_key, on_close)
    draft.filter = draft.filter or {}
    local sections = SET_SECTIONS[dim_key]
    local label
    for _i, dim in ipairs(Filter.dimensions()) do if dim.key == dim_key then label = dim.label end end
    local d
    local function changed()
        if on_close then on_close() end
        if d and d.refresh then d:refresh() end
    end
    local function page()
        local blocks = {}
        for _i, sec in ipairs(sections) do
            local set = draft.filter[sec.key] or {}
            blocks[#blocks + 1] = { type = "heading", text = sec.heading, tag = sec.tag }
            -- The picks as the book menu's tags in edit mode: small pills,
            -- each with a cross that drops it; "+ Add" stays a card under
            -- them (maintainer).
            local keys = {}
            for v in pairs(set) do keys[#keys + 1] = v end
            table.sort(keys)
            local items = {}
            for _j, v in ipairs(keys) do
                items[#items + 1] = { label = tostring(v), trailing = CROSS,
                    on_tap = function() set[v] = nil; changed() end }
            end
            if #items > 0 then blocks[#blocks + 1] = { type = "pills", items = items } end
            blocks[#blocks + 1] = { type = "chips", items = { { text = "+ " .. sections.add,
                callback = function()
                    Editor:_pickMultiFilter(draft, dim_key, changed,
                        { set_key = sec.key, crumb = sec.heading })
                end } } }
        end
        blocks[#blocks + 1] = { type = "hint", text = sections.hint }
        return { blocks = blocks }
    end
    d = Editor._menu{
        title   = label or dim_key,
        page    = page,
        on_back = on_close,
        anchor  = _highAnchor(function() return d end),
    }
end

-- Folder include/exclude manager. Lists current include (+) and exclude (-)
-- entries; tapping one removes it. "Add include / Add exclude" open the
-- KOReader folder chooser to add a path. Recursive matching + exclude-wins are
-- enforced by Filter.matches; this screen only edits the path sets.
function Editor:_pickFolderFilter(draft, on_close)
    draft.filter = draft.filter or {}
    draft.filter.folders = draft.filter.folders or { include = {}, exclude = {} }
    local folders = draft.filter.folders
    folders.include = folders.include or {}
    folders.exclude = folders.exclude or {}
    local d
    local function changed()
        if on_close then on_close() end
        if d and d.refresh then d:refresh() end
    end
    -- Bookshelf's folder list (Move to's), as a page of this one; Browse
    -- device on its strip reaches a folder outside it.
    local function add_via_chooser(set, label)
        require("lib/bookshelf_folder_picker").show{
            title      = label,
            new_folder = false,
            over       = Editor._over({ label }),
            on_cancel  = function() end,
            on_pick    = function(folder)
                set[folder] = true
                changed()
            end,
        }
    end
    -- A page: the folders the shelf keeps to and the ones it leaves out, each
    -- with a cross to drop it, and a way to add one under each.
    local function page()
        local blocks = {}
        local function section(heading, tag, set, add_label)
            blocks[#blocks + 1] = { type = "heading", text = heading, tag = tag }
            local keys = {}
            for p in pairs(set) do keys[#keys + 1] = p end
            table.sort(keys)
            for _i, p in ipairs(keys) do
                blocks[#blocks + 1] = { type = "row", icon = "\u{E94A}",   -- folder
                    label = p, path = true, on = true,
                    on_clear = function() set[p] = nil; changed() end }
            end
            blocks[#blocks + 1] = { type = "chips", items = { { text = "+ " .. add_label,
                callback = function() add_via_chooser(set, add_label) end } } }
        end
        section(_("Only books in these folders"), _("OR"), folders.include, _("Add a folder"))
        section(_("Leave out these folders"), _("NOT"), folders.exclude, _("Add a folder to leave out"))
        blocks[#blocks + 1] = { type = "hint",
            text = _("Leave the first list empty to include every folder except those left out.") }
        return { blocks = blocks }
    end
    d = Editor._menu{
        title   = _("Folders"),
        page    = page,
        on_back = on_close,
        anchor  = _highAnchor(function() return d end),
    }
end

-- Sort directions in words, per key: { reverse = false, reverse = true }.
-- What the shelf does, where a bare arrow said only "the other way".
local function _dirLabels(key)
    if key == "series_index" then return "1, 2, 3", "3, 2, 1" end
    if key == "last_opened" or key == "date_added" or key == "added_or_opened"
            or key == "published" then
        return _("Oldest first"), _("Newest first")
    end
    if key == "percent_read" then return _("Least read first"), _("Most read first") end
    if key == "rating" then return _("Lowest first"), _("Highest first") end
    if key == "size" then return _("Smallest first"), _("Largest first") end
    if key == "page_count" then return _("Shortest first"), _("Longest first") end
    if key == "book_count" then return _("Fewest first"), _("Most first") end
    -- Named for what leads: "First" / "Last" read "Favorites first: Last".
    if key == "read_status" then return _("Unread first"), _("Finished first") end
    if key == "read_status_active" then return _("Reading first"), _("Finished first") end
    if key == "favorites_first" then return _("Favorites first"), _("Favorites last") end
    if key == "collection_order" then return _("Your order"), _("Reversed") end
    return "A-Z", "Z-A"
end
Editor._dirLabels = _dirLabels

-- _favGlyph() -> the reader's favourites mark (Favorites icon setting:
-- a heart unless they chose the star), for a Favorites chip.
function Editor._favGlyph()
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if not ok or not CP or not CP.favoriteIcon then return nil end
    return CP.favoriteIcon() == "star" and CP.FAV_GLYPH_STAR or CP.FAV_GLYPH_HEART
end

-- _sourceIcon(source) -> the glyph for the editor's Source card: the one
-- the source has on the Source page (a star for ratings), so the card shows
-- what the shelf holds at a glance. Anything else: the library's.
local SOURCE_ICONS = {
    library = "\u{EA31}", all = "\u{E952}",                     -- library-books, folder-multiple
    folder = "\u{E94A}", folder_flat = "\u{E94A}",              -- folder
    recent = "\u{E9D9}", latest = "\u{EA93}",                   -- history, new-box
    series = "\u{E97A}", single_series = "\u{E97A}",            -- format-list-numbers
    authors = "\u{E703}", author = "\u{E703}",                  -- account
    genres = "\u{EA14}", genre = "\u{EA14}",
    tags = "\u{E7BF}", collection = "\u{E7BF}",
    formats = "\u{E918}", format = "\u{E918}",
    ratings = "\u{EBCD}", rating = "\u{EBCD}",                  -- star
    languages = "\u{ECC9}", language = "\u{ECC9}",
    shelves = "\u{EC6F}", opds = "\u{EC9E}",                    -- view-grid, web
}
function Editor._sourceIcon(source)
    local kind = type(source) == "table" and source.kind
    if kind == "favorites" then return Editor._favGlyph() or SOURCE_ICONS.library end
    return SOURCE_ICONS[kind or ""] or SOURCE_ICONS.library
end

-- _openSort -- every sort level on one page: the levels in the strip (each
-- with its direction in words), the keys below under headings; a tap on a
-- key sets the level picked in the strip, or adds one. Each change is saved
-- at once (on_change), so the shelf behind shows it.
-- Group shelves: level 1 orders the group cards and offers only the keys a
-- group can be sorted by; it cannot be cleared (a group view must have an
-- order). Levels 2+ sort the books inside a group.
function Editor:_openSort(draft, on_change, on_arranged, on_back)
    local kind = draft.source and draft.source.kind
    local is_group = GROUP_KINDS[kind or ""] or false
    local MAX = 3
    local sel = 1
    local d
    local function changed()
        if on_change then on_change() end
        if d and d.refresh then d:refresh() end
    end
    -- pick(): a level picked in the strip changes nothing saved, so the page
    -- alone is drawn again, not the shelf behind it too.
    local function pick()
        if d and d.refresh then d:refresh() end
    end
    local function levels()
        draft.sort_priority = draft.sort_priority or {}
        return draft.sort_priority
    end

    local function keyChip(key)
        local lv = levels()[sel]
        return {
            text = _resolveSortLabel(sel, key, kind),
            on = lv ~= nil and lv.key == key,
            callback = function()
                local list = levels()
                local cur = list[sel]
                if cur and cur.key == key then return end
                list[sel] = { key = key, reverse = DEFAULT_REVERSE[key] == true }
                changed()
            end,
        }
    end
    local function chips(keys)
        local items = {}
        for _i, k in ipairs(keys) do items[#items + 1] = keyChip(k) end
        return { type = "chips", items = items }
    end

    local function page()
        local list = levels()
        if sel > #list + 1 then sel = #list + 1 end
        if sel > MAX then sel = MAX end
        -- No summary sentence: the levels say it, and the page is tall
        -- enough already (maintainer).
        local strip = {}
        for i, lv in ipairs(list) do
            local asc, desc = _dirLabels(lv.key)
            local items = { { key = false, label = asc }, { key = true, label = desc } }
            if DEFAULT_REVERSE[lv.key] then items = { items[2], items[1] } end
            strip[#strip + 1] = {
                type = "slot", badge = tostring(i),
                text = _resolveSortLabel(i, lv.key, kind),
                selected = (sel == i),
                callback = function() sel = i; pick() end,
                seg = { items = items, active = lv.reverse == true,
                    on_pick = function(rev) lv.reverse = rev; changed() end },
                on_clear = not (is_group and i == 1) and function()
                    table.remove(list, i)
                    if sel > i then sel = sel - 1 end
                    changed()
                end or nil,
            }
        end
        if #list < MAX then
            strip[#strip + 1] = {
                type = "slot", badge = "+",
                text = (#list == 0) and _("Add a sort")
                    or (is_group and #list == 1) and _("Sort the books inside each")
                    or _("Add a tie-breaker"),
                selected = (sel == #list + 1),
                callback = function() sel = #list + 1; pick() end,
            }
        end

        local blocks = {}
        local function add(b) blocks[#blocks + 1] = b end
        if is_group and sel == 1 then
            add({ type = "heading", text = _("Order the groups by") })
            add(chips({ "series_name", "author_surname", "book_count",
                        "last_opened", "date_added", "added_or_opened" }))
        else
            -- A collection is the only book source carrying an order of its
            -- own: the one the reader arranged by hand in KOReader. It
            -- leads, with the way to change that order beside it, which
            -- otherwise meant leaving for KOReader's collections view. Only
            -- when a collection is really behind the shelf: a pinned tag is
            -- kind "collection" too, with nothing to arrange (issue 441).
            if kind == "collection" then
                add({ type = "heading", text = _("Collection") })
                local c = chips({ "collection_order" })
                local CollectionOrder = require("lib/bookshelf_collection_order")
                local coll_id = draft.source and draft.source.id
                if CollectionOrder.exists(coll_id) then
                    -- Over this page rather than instead of it: confirming or
                    -- backing out of the arrange window lands here. A confirm
                    -- drops the book cache and calls on_arranged, which
                    -- repaints the shelf.
                    c.items[#c.items + 1] = { text = _("Edit collection order") .. " \xE2\x80\xBA",
                        callback = function() CollectionOrder.arrange(coll_id, on_arranged) end }
                end
                add(c)
            end
            add({ type = "heading", text = _("Book") })
            add(chips({ "title", "author_name", "author_surname", "filename", "published" }))
            add({ type = "heading", text = _("Series") })
            add(chips({ "series_name", "series_index", "series_combined", "series_or_title" }))
            -- Added/opened first: Home's own sort (maintainer).
            add({ type = "heading", text = _("Reading") })
            add(chips({ "added_or_opened", "date_added", "last_opened", "percent_read", "rating" }))
            add({ type = "heading", text = _("Status") })
            add(chips({ "read_status", "read_status_active", "favorites_first" }))
            add({ type = "heading", text = _("Size") })
            add(chips({ "page_count", "size", "book_count" }))
        end
        return { strip = strip, blocks = blocks }
    end

    d = Editor._menu{
        title   = _("Sort"),
        page    = page,
        on_back = on_back,
        anchor  = _highAnchor(function() return d end),
    }
    return d
end
-- _pickIcon -- opens the bundled icons library (categorised glyph grid) for
-- the start-menu icon slot. Selection writes the chosen value into draft.icon.
-- Dynamic %tokens are excluded: the start-menu icon slot does not expand them.
-- SVG icons are enabled because the start-menu renderer turns [icon=NAME]
-- values into IconWidget images.
function Editor:_pickIcon(draft, on_close)
    local IconsLibrary = require("lib/bookshelf_icons_library")
    IconsLibrary:show(function(value)
        draft.icon = value and value ~= "" and value or nil
        on_close()
    end, { dynamic = false, svg = true })
end

-- Exposed for tests/_test_chip_editor.lua (config tables + the pure
-- defaults-applier). Not referenced at runtime.
Editor._test = {
    SOURCE_SORT_DEFAULTS = SOURCE_SORT_DEFAULTS,
    GROUP_KINDS          = GROUP_KINDS,
    applySourceDefaults  = _applySourceDefaults,
    resolveSourceLabel   = _resolveSourceLabel,
}

return Editor
