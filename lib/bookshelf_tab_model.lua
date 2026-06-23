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
function TabModel.DEFAULTS()
    return {
        { id = "all",       label = tr("Home"),       source = { kind = "all"       },
          filter = {}, sort_priority = { { key = "filename",    reverse = false } }, enabled = true  },
        { id = "recent",    label = tr("Recent"),     source = { kind = "recent"    },
          filter = {}, sort_priority = { { key = "last_opened", reverse = true  } }, enabled = true  },
        { id = "latest",    label = tr("Latest"),     source = { kind = "latest"    },
          filter = {}, sort_priority = { { key = "date_added",  reverse = true  } }, enabled = false },
        { id = "series",    label = tr("Series"),     source = { kind = "series"    },
          filter = {}, sort_priority = { { key = "series_name", reverse = false } }, enabled = true  },
        { id = "authors",   label = tr("Authors"),    source = { kind = "authors"   },
          filter = {}, sort_priority = { { key = "author_surname", reverse = false } }, enabled = false },
        { id = "genres",    label = tr("Genres"),     source = { kind = "genres"    },
          filter = {}, sort_priority = { { key = "book_count",  reverse = true  } }, enabled = false },
        { id = "tags",      label = tr("Tags"),       source = { kind = "tags"      },
          filter = {}, sort_priority = { { key = "book_count",  reverse = true  } }, enabled = false },
        { id = "languages", label = tr("Languages"),  source = { kind = "languages" },
          filter = {}, sort_priority = { { key = "book_count",  reverse = true  } }, enabled = false },
        { id = "favorites", label = tr("Favourites"), source = { kind = "favorites" },
          filter = {}, sort_priority = { { key = "date_added",  reverse = true  } }, enabled = true  },
    }
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
    local tabs = TabModel.DEFAULTS()
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

-- insertAfter(tabs, anchor_id, new_tab): splice `new_tab` into `tabs`
-- immediately after the entry whose id matches `anchor_id`. Appends to
-- the end when no anchor is found (anchor_id nil, anchor doesn't exist,
-- or new chip created from a context with no active chip). Mutates
-- `tabs` in place; caller still owns persistence via TabModel.save.
function TabModel.insertAfter(tabs, anchor_id, new_tab)
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

-- In-memory override used by the editor to drive live preview without
-- persisting to disk on every keystroke. setOverride(tab_id, tab) makes
-- getById(tab_id) / getActive() return the override in place of the
-- persisted record. clearOverride() restores normal lookup. Override
-- is cleared on every editor close (Save / Cancel / X).
local _override = nil  -- { id = <string>, tab = <tab record> }

function TabModel.setOverride(tab_id, tab)
    _override = { id = tab_id, tab = tab }
end

function TabModel.clearOverride()
    _override = nil
end

-- getById(id): find a tab by id from the current loaded list. Consults the
-- in-memory override first so live preview during edits doesn't require
-- hitting disk.
-- Synthetic tab for the Kobo virtual library (kobo.koplugin). NOT part of
-- DEFAULTS / the persisted, editable set -- it only exists when the kobo plugin
-- is present (the widget injects the chip on bookshelf_kobo_source.isAvailable()),
-- so non-Kobo users never see it. source.kind == "kobo" routes Repo.getBySource
-- to the kobo source. Sort priority is read from a dedicated setting so the chip
-- can be made sortable without touching the persisted tab list.
function TabModel.koboTab()
    local sp = { { key = "title", reverse = false } }
    local ok, Store = pcall(require, "lib/bookshelf_settings_store")
    if ok and Store then
        local saved = Store.read("kobo_sort_priority")
        if type(saved) == "table" and #saved > 0 then sp = saved end
    end
    return {
        id = "kobo", label = tr("Kobo"),
        source = { kind = "kobo" }, filter = {},
        sort_priority = sp, enabled = true, synthetic = true,
    }
end

function TabModel.getById(id)
    if _override and _override.id == id then return _override.tab end
    if id == "kobo" then return TabModel.koboTab() end
    for _i, t in ipairs(TabModel.load()) do
        if t.id == id then return t end
    end
    return nil
end

-- getActive(): list of enabled tabs in their stored order. If an override
-- is set, the matching tab is substituted in-place so position is preserved
-- and live label/icon edits surface immediately.
function TabModel.getActive()
    local out = {}
    for _i, t in ipairs(TabModel.load()) do
        if _override and _override.id == t.id then
            if _override.tab.enabled ~= false then out[#out + 1] = _override.tab end
        elseif t.enabled ~= false then
            out[#out + 1] = t
        end
    end
    return out
end

return TabModel
