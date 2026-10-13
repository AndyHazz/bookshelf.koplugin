-- bookshelf_tab_model.lua
-- Single source of truth for the bookshelf tab list. Each tab has:
--   id            string — stable identifier (also the chip key)
--   label         string — display name shown in the chip
--   icon          string|nil — nerd-font glyph (UTF-8) shown alongside label
--   source        table — { kind = <string>, id? = <string> } describing data
--   filter        table — { status? = "unread"|"reading"|"on_hold"|"finished" }
--   sort_priority list of { key, reverse } — driven through bookshelf_sort_engine
--   enabled       bool — when false, hidden from the chip strip
--
-- Built-in defaults match the v1.1 chip set so existing users see no change
-- after migration. The legacy `bookshelf_chips_disabled` setting (set of chip
-- keys) is converted to `enabled = false` on the matching tabs and then
-- cleared.

local _ok = pcall(require, "lib/bookshelf_i18n")
local i18n = package.loaded["lib/bookshelf_i18n"]
local function tr(s) if i18n and i18n.gettext then return i18n.gettext(s) end; return s end

local BookshelfSettings = require("lib/bookshelf_settings_store")

local TabModel = {}

-- Settings keys (within the bookshelf settings store; the "bookshelf_"
-- prefix is now the file's job, not the key's). Migration of the legacy
-- v1.1 globals lives in bookshelf_settings_store -- by the time TabModel
-- runs, the values have already moved into the new store with the
-- prefix stripped.
local STORAGE_KEY = "tabs"
local LEGACY_KEY  = "chips_disabled"

-- DEFAULTS() is a function (not a table constant) because the labels go through
-- gettext — calling it at module load would freeze them to whatever locale was
-- active at first require. As a function the labels resolve at call time.
-- Default chip set for fresh installs. Home / Recent / Series / Favourites
-- are enabled so a new user sees a focused starting bar with the four
-- main browsing modes (everything / currently reading / by series /
-- curated). Latest / Authors / Genres / Tags are present but disabled,
-- visible in the Bookshelf chips menu so the user can opt them on when
-- they're ready. Upgrading users keep whatever they had via migrate()
-- below -- the enabled flags here only affect first-launch installs.
function TabModel.BUILTINS()
    return {
        -- HOME ships as a spine shelf, newest first, with ornaments on.
        -- These are the maintainer's own settings, adopted as defaults for the
        -- sake of the first launch: a grid of covers sorted by FILENAME is
        -- what the shelf could do on day one, not what it is for. Newest-first
        -- puts a book the reader recognises at the front, spines show what the
        -- feature actually looks like, and Always guarantees a piece stands on
        -- the shelf rather than leaving it to a roll a one-row shelf can lose
        -- for ever (see bookshelf_ornaments' frequency stops).
        --
        -- Every one of these is a normal pin the reader can change; none of
        -- them is a new kind of setting.
        { id = "all",       label = tr("Home"),       source = { kind = "all"       },
          filter = {}, sort_priority = { { key = "date_added",  reverse = true  } },
          view_mode = "spines", ornament_frequency = 2,
          spine_face_out = { favorites = true, reading = true, recent = 5 },
          enabled = true  },
        -- RECENT ships as a LIST. Same reasoning as Home's spines: a shelf of
        -- books you are part-way through is about titles and progress, not
        -- cover art you have already looked at, and the list is the view that
        -- shows both. Row density is deliberately NOT pinned -- nil means the
        -- natural, screen-adaptive height (see _listRows), and a fixed count
        -- would read sparse on a larger panel.
        { id = "recent",    label = tr("Recent"),     source = { kind = "recent"    },
          filter = {}, sort_priority = { { key = "last_opened", reverse = true  } },
          view_mode = "list", enabled = true  },
        { id = "latest",    label = tr("Latest"),     source = { kind = "latest"    },
          filter = {}, sort_priority = { { key = "date_added",  reverse = true  } }, enabled = false },
        -- SERIES ships as collage cards, most recently read first and then in
        -- series order within a group -- so the shelf opens on the series the
        -- reader is actually in, rather than alphabetically at whatever starts
        -- with A. Collage shows the member covers, which is the whole reason
        -- to group by series.
        { id = "series",    label = tr("Series"),     source = { kind = "series"    },
          filter = {}, sort_priority = { { key = "last_opened",  reverse = true  },
                                         { key = "series_index", reverse = false } },
          group_display = "collage", enabled = true  },
        { id = "authors",   label = tr("Authors"),    source = { kind = "authors"   },
          filter = {}, sort_priority = { { key = "author_surname", reverse = false } }, enabled = false },
        -- GENRES ships ON and Favourites OFF. Both are the maintainer's own
        -- arrangement, adopted for the same reason as Home's spines and
        -- Series' collage: a first launch should show what the shelf is for.
        -- Genres is the one that demonstrates stacks, and a favourites shelf
        -- is empty until the reader has starred something, so it opens on
        -- nothing. Favourites is one long-press away for anyone who wants it.
        { id = "genres",    label = tr("Genres"),     source = { kind = "genres"    },
          filter = {}, sort_priority = { { key = "book_count",  reverse = true  } },
          group_display = "ribbon", enabled = true  },
        { id = "tags",      label = tr("Tags"),       source = { kind = "tags"      },
          filter = {}, sort_priority = { { key = "book_count",  reverse = true  } }, enabled = false },
        { id = "languages", label = tr("Languages"),  source = { kind = "languages" },
          filter = {}, sort_priority = { { key = "book_count",  reverse = true  } }, enabled = false },
        { id = "favorites", label = tr("Favorites"), source = { kind = "favorites" },
          filter = {}, sort_priority = { { key = "date_added",  reverse = true  } }, enabled = false },
    }
end

-- DEFAULTS(): what a FRESH INSTALL actually ships -- the built-ins that are
-- ON, and nothing else.
--
-- It used to ship all nine, five of them switched off, on the reasoning that
-- a reader could just tick the one they wanted. In practice that fills the
-- shelf editor with rows nobody asked for and pushes the help line and
-- "+ Add new shelf" off the bottom, so the two things a new reader needs to
-- see are the two they cannot (maintainer, on a PW5, after deleting the
-- disabled ones by hand).
--
-- Nothing is lost by leaving them out: every one of these sources is offered
-- by the source picker when adding a shelf, so Authors or Favorites is the
-- same two taps it always was.
--
-- migrate() deliberately still reads BUILTINS, not this: a v1 reader had ALL
-- of them enabled, and rebuilding their list from the shipped subset would
-- delete five shelves they were using.
function TabModel.DEFAULTS()
    local out = {}
    for _i, t in ipairs(TabModel.BUILTINS()) do
        if t.enabled ~= false then out[#out + 1] = t end
    end
    return out
end

-- migrate(): if the legacy disabled-set exists, apply it to a fresh defaults
-- snapshot, save the result, and clear the legacy key. Returns the migrated
-- tabs. No-op if no legacy state present.
--
-- v1 had every built-in chip enabled by default. v2 trims the fresh-install
-- defaults (Latest / Authors / Genres / Tags are disabled out of the box),
-- so an upgrader who never touched chips_disabled would otherwise lose
-- those four chips on their first v2 launch. Explicitly set enabled=true
-- for any tab NOT in the legacy disabled-set so upgraders keep their v1
-- chip layout exactly.
local function migrate()
    local legacy = BookshelfSettings.read(LEGACY_KEY)
    if type(legacy) ~= "table" then return nil end
    -- BUILTINS, not DEFAULTS: v1 shipped every chip enabled, so an upgrader
    -- must get the full set back with their disabled-flags applied. Rebuilding
    -- from the fresh-install subset would quietly delete five shelves.
    local tabs = TabModel.BUILTINS()
    for _i, t in ipairs(tabs) do
        if legacy[t.id] then
            t.enabled = false
        else
            t.enabled = true   -- v1 had all chips enabled; preserve that
        end
    end
    BookshelfSettings.save(STORAGE_KEY, tabs)
    BookshelfSettings.delete(LEGACY_KEY)
    BookshelfSettings.flush()
    return tabs
end

-- load(): returns the current tab list. Applies legacy migration on first
-- call after upgrade. Falls back to DEFAULTS() if nothing's saved.
function TabModel.load()
    local saved = BookshelfSettings.read(STORAGE_KEY)
    if type(saved) == "table" and #saved > 0 then return saved end
    local migrated = migrate()
    if migrated then return migrated end
    return TabModel.DEFAULTS()
end

-- save(tabs): persist a tab list. Caller is responsible for ordering and
-- well-formedness; this function does NO validation beyond writing.
function TabModel.save(tabs)
    BookshelfSettings.save(STORAGE_KEY, tabs)
    BookshelfSettings.flush()
end

-- saveDeferred(tabs): the same write with no flush, for a hot path.
--
-- Two callers: the shelf editor (each change as it is made; it flushes as it
-- closes) and the pinch, which writes a row count onto the chip it is aimed at
-- and must not stop for a settings flush -- hundreds of milliseconds on Kindle
-- flash, landing between the gesture and the repaint. The in-memory value
-- updates immediately, so the rebuild that follows sees the new count;
-- durability rides the shared nav-flush debounce and every close / suspend /
-- onFlushSettings boundary, exactly as the column nudge does.
function TabModel.saveDeferred(tabs)
    BookshelfSettings.saveDeferred(STORAGE_KEY, tabs)
end

-- flush(): write what saveDeferred holds. The shelf editor saves each change
-- in memory as it is made and flushes once, as it closes.
function TabModel.flush()
    BookshelfSettings.flush()
end

-- insertAfter(tabs, anchor_id, new_tab): splice `new_tab` into `tabs`
-- immediately after the entry whose id matches `anchor_id`. Appends to
-- the end when no anchor is found (anchor_id nil, anchor doesn't exist,
-- or new chip created from a context with no active chip). Mutates
-- `tabs` in place; caller still owns persistence via TabModel.save.
function TabModel.insertAfter(tabs, anchor_id, new_tab)
    -- A top-level shelf made from inside a shelf of shelves (a stack pinned
    -- while in a sub-shelf) goes after that whole tree, beside the top-level
    -- shelf it was made under, so the stored list keeps its tree order.
    if anchor_id and not new_tab.parent then
        local by_id = {}
        for _i, t in ipairs(tabs) do by_id[t.id] = t end
        local root, hops = by_id[anchor_id], 0
        while root and root.parent and by_id[root.parent] and hops < 32 do
            root = by_id[root.parent]
            hops = hops + 1
        end
        if root then
            local inside = TabModel.descendantIds(root.id, tabs)
            local at
            for i, t in ipairs(tabs) do
                if t.id == root.id or inside[t.id] then at = i end
            end
            if at then
                table.insert(tabs, at + 1, new_tab)
                return
            end
        end
    end
    if anchor_id then
        for i, t in ipairs(tabs) do
            if t.id == anchor_id then
                table.insert(tabs, i + 1, new_tab)
                return
            end
        end
    end
    tabs[#tabs + 1] = new_tab
end

-- getById(id): find a tab by id from the current loaded list.
function TabModel.getById(id)
    for _i, t in ipairs(TabModel.load()) do
        if t.id == id then return t end
    end
    return nil
end

-- getActive(): list of enabled tabs in their stored order.
--
-- Top-level shelves only: a sub-shelf (see "Shelf of shelves" below) lives
-- inside its parent's shelf, never in the chip strip.
function TabModel.getActive()
    local out = {}
    for _i, t in ipairs(TabModel.load()) do
        if t.enabled ~= false and not t.parent then
            out[#out + 1] = t
        end
    end
    return out
end

-- ── Shelf of shelves (5.4) ─────────────────────────────────────────────────
-- A shelf whose source is { kind = "shelves" } holds other shelves. Each one
-- is an ordinary tab record in the same flat list, with `parent` naming the
-- shelf it sits in -- so every per-shelf setting (style, filters, sort, rows,
-- theme, ornaments) works on it unchanged, keyed by its id like any other.
-- A sub-shelf can itself hold shelves, to any depth. Order among siblings is
-- their order in the list.
TabModel.SHELVES_KIND = "shelves"
-- A cycle cannot be built from the UI, but a hand-edited settings file could
-- hold one; every walk up the chain stops here rather than spinning.
local MAX_DEPTH = 32

function TabModel.isShelves(tab)
    return type(tab) == "table" and type(tab.source) == "table"
        and tab.source.kind == TabModel.SHELVES_KIND
end

-- childrenOf(id[, tabs]) -> the shelves inside `id`, in their stored order.
function TabModel.childrenOf(id, tabs)
    local out = {}
    if id == nil then return out end
    for _i, t in ipairs(tabs or TabModel.load()) do
        if t.parent == id then out[#out + 1] = t end
    end
    return out
end

-- ancestorsOf(id) -> the shelves above `id`, outermost first (empty for a
-- top-level shelf). A parent that no longer exists ends the chain.
function TabModel.ancestorsOf(id)
    local chain, seen = {}, { [id or false] = true }
    local t = TabModel.getById(id)
    while t and t.parent and #chain < MAX_DEPTH and not seen[t.parent] do
        local p = TabModel.getById(t.parent)
        if not p then break end
        seen[t.parent] = true
        table.insert(chain, 1, p)
        t = p
    end
    return chain
end

-- rootOf(id) -> the top-level shelf `id` sits under (itself when top level).
function TabModel.rootOf(id)
    local chain = TabModel.ancestorsOf(id)
    return chain[1] and chain[1].id or id
end

-- descendantIds(id[, tabs]) -> set of every shelf below `id`, any depth.
function TabModel.descendantIds(id, tabs)
    tabs = tabs or TabModel.load()
    local set, frontier = {}, { id }
    while #frontier > 0 do
        local next_f = {}
        for _i, pid in ipairs(frontier) do
            for _j, t in ipairs(tabs) do
                if t.parent == pid and not set[t.id] and t.id ~= id then
                    set[t.id] = true
                    next_f[#next_f + 1] = t.id
                end
            end
        end
        frontier = next_f
    end
    return set
end

-- removeTree(tabs, id): remove `id` and every shelf inside it, in place.
-- Deleting a shelf of shelves takes its shelves with it; leaving them would
-- strand records nothing can reach or edit.
function TabModel.removeTree(tabs, id)
    local doomed = TabModel.descendantIds(id, tabs)
    doomed[id] = true
    for i = #tabs, 1, -1 do
        if doomed[tabs[i].id] then table.remove(tabs, i) end
    end
end

-- isSibling(a, b) -> true when two records sit at the same level (same
-- parent, or both top level): the set the editor's move arrows walk.
function TabModel.isSibling(a, b)
    return type(a) == "table" and type(b) == "table" and a.parent == b.parent
end

-- newId(tabs) -> the first free custom_N id.
function TabModel.newId(tabs)
    tabs = tabs or TabModel.load()
    local taken = {}
    for _i, t in ipairs(tabs) do taken[t.id] = true end
    local n = 1
    while taken["custom_" .. n] do n = n + 1 end
    return "custom_" .. n
end

-- newTab(tabs, label) -> a shelf being created: no source yet (nothing on it
-- while the reader picks one, rather than a placeholder Home showing every
-- book behind the editor), and `pending` until the editor saves it. Leaving
-- the editor any other way removes it (bookshelf_chip_editor).
TabModel.NO_SOURCE = "none"
function TabModel.newTab(tabs, label)
    return {
        id            = TabModel.newId(tabs),
        label         = label,
        source        = { kind = TabModel.NO_SOURCE },
        filter        = {},
        sort_priority = { { key = "title", reverse = false } },
        enabled       = true,
        pending       = true,
    }
end

-- prunePending() -> true when it removed anything: shelves still pending
-- (and anything inside them) from a session that stopped mid-creation.
-- Called once at start-up; never while an editor may hold one.
function TabModel.prunePending()
    local tabs = TabModel.load()
    local doomed = {}
    for _i, t in ipairs(tabs) do
        if t.pending then doomed[#doomed + 1] = t.id end
    end
    if #doomed == 0 then return false end
    for _i, id in ipairs(doomed) do TabModel.removeTree(tabs, id) end
    TabModel.save(tabs)
    return true
end

-- insertChild(tabs, parent_id, new_tab): append `new_tab` as the last shelf
-- inside `parent_id`, placed after the parent's last descendant in the flat
-- list so the stored list still reads in tree order.
function TabModel.insertChild(tabs, parent_id, new_tab)
    new_tab.parent = parent_id
    local inside = TabModel.descendantIds(parent_id, tabs)
    local at
    for i, t in ipairs(tabs) do
        if t.id == parent_id or inside[t.id] then at = i end
    end
    if at then table.insert(tabs, at + 1, new_tab)
    else tabs[#tabs + 1] = new_tab end
end

return TabModel
