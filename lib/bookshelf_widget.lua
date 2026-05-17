-- bookshelf_widget.lua
-- The top-level home screen widget. Composes HeroCard + ChipBar
-- + two ShelfRows + chevron pagination footer. Owns chip-state and refresh.
--
local InputContainer  = require("ui/widget/container/inputcontainer")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local Font            = require("ui/font")
local UIManager       = require("ui/uimanager")
local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Screen          = Device.screen

local _           = require("lib/bookshelf_i18n").gettext

local Repo        = require("lib/bookshelf_book_repository")
local HeroCard    = require("lib/bookshelf_hero_card")
local ChipBar   = require("lib/bookshelf_chip_bar")
local ShelfRow    = require("lib/bookshelf_shelf_row")
local SpineWidget = require("lib/bookshelf_spine_widget")
local logger      = require("logger")

-- Wall-clock timer for perf instrumentation. LuaSocket's gettime() gives
-- fractional seconds including I/O waits; os.clock() is CPU-only (fallback).
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

-- ─── Module constants ────────────────────────────────────────────────────────

-- Target minimum hero card share of usable (UI-excluded) height. Used by
-- both _baseShelves (dynamic shelf row count) and the in-rebuild layout
-- clamp so they reach the same decision: pick the largest n_shelves that
-- leaves the hero >= this share, otherwise the clamp will shrink shelves
-- to enforce it. Issue #36. Declared at file scope (before any method
-- captures it lexically) -- Lua parses method bodies in the order they
-- appear, so a local declared further down would be invisible up here
-- and the references would silently rebind to the (nil) global.
--
-- Set to 0.25 (was 0.30 in early v2.0.0): the 30% floor was tight
-- enough to drop Pixel-aspect tall screens (1080x2400 ~ 29% hero at
-- n=3) from their natural 3 rows to 2, which users on Pixel 6/8
-- treated as a regression. 0.25 keeps those devices at 3x3 while
-- still triggering Boox Palma (~20% at n=3) to drop to 2 rows.
local MIN_HERO_SHARE = 0.25

-- ─── BookshelfWidget ──────────────────────────────────────────────────────────

local BookshelfWidget = InputContainer:extend{
    name              = "bookshelf",
    covers_fullscreen = true, -- prevents FileManager's 1s dirty cycle from cascading up
    -- Internal state.
    chip             = "recent",
    -- Drill-down path: empty array = top level (chips list shown); non-empty
    -- means the chip strip is in breadcrumb mode and shelf data is scoped
    -- to the deepest entry. Each entry: { kind, label, payload }.
    -- Today only `kind = "series"` is produced (from _expandSeries / now
    -- _drillIntoSeries); the model is array-shaped so future Folders /
    -- Tags / Authors chips can drill multiple levels.
    _drilldown_path  = {},
}

-- _coverNeedsResize(info, specs) — bookshelf-specific re-extract gate.
-- BIM's isCachedCoverInvalid flips true on any pixel difference; with our
-- variable hero/shelf sizing that would re-extract on every orientation flip
-- or font-scale tweak, burning the device's battery without a visible win.
-- Apply a 0.8 tolerance: only re-queue when the cached cover would render
-- to <80% of the size the new spec calls for — i.e. significantly stretched
-- on display, not just sub-pixel different. Once a book's cache reaches
-- that band, it stays put across minor session-to-session perturbations.
function BookshelfWidget._coverNeedsResize(info, specs)
    if not info or not info.cover_w or not info.cover_h then return false end
    if not info.cover_sizetag then return false end
    local BIM = package.loaded["bookinfomanager"]
    if not BIM or type(BIM.isCachedCoverInvalid) ~= "function"
            or type(BIM.getCachedCoverSize) ~= "function" then
        return false
    end
    if not BIM.isCachedCoverInvalid(info, specs) then return false end
    local img_w, img_h = info.cover_sizetag:match("(%d+)x(%d+)")
    if not img_w or not img_h then return false end
    img_w, img_h = tonumber(img_w), tonumber(img_h)
    local target_w, target_h = BIM.getCachedCoverSize(
        img_w, img_h, specs.max_cover_w, specs.max_cover_h)
    return info.cover_w < target_w * 0.8 or info.cover_h < target_h * 0.8
end

function BookshelfWidget:init()
    self.width  = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen  = Geom:new{ w = self.width, h = self.height }
    self.chip   = BookshelfSettings.read("active_chip") or "recent"
    -- Cursor-based pagination: _cursor is the 1-based index of the first
    -- visible book on the current view. Primary persisted state. self.page
    -- is a derived view-aligned index used for footer display only --
    -- recomputed via _syncPageFromCursor whenever the cursor moves.
    --
    -- Why cursor instead of page-as-primary: the expand/collapse toggle
    -- changes _viewSize (8 → 12 in expanded mode). Page-as-primary would
    -- need to either keep self.page constant (which breaks the user's
    -- visible position since pages have different sizes in each mode) or
    -- recompute page on toggle (which can't preserve the top-row exactly
    -- because (collapsed_page - 1) × 8 is rarely divisible by 12). Cursor
    -- preserves the top row of collapsed-view as the top row of
    -- expanded-view across the toggle by definition.
    --
    -- Backward compat: existing installs persisted "active_page" only.
    -- Fall back to deriving cursor from page × PAGE_SIZE on load. New
    -- saves use "active_cursor"; "active_page" stays in settings for one
    -- or two releases so a downgrade keeps something sensible.
    local _saved_cursor = BookshelfSettings.read("active_cursor")
    if _saved_cursor and _saved_cursor >= 1 then
        self._cursor = _saved_cursor
    else
        local _saved_page = BookshelfSettings.read("active_page") or 1
        -- Use the same PAGE_SIZE the legacy code used (= _baseShelves *
        -- _nCols, which the previous _pageSize() returned). This is a
        -- per-device value -- 5 in landscape, 8 standard portrait, 9 tall
        -- portrait, 6 phone-tall (Palma). _baseShelves and _nCols don't
        -- depend on self._expanded (set later), so it's safe to call here.
        local _legacy_page_size
        if self:_isLandscape() then
            _legacy_page_size = 5
        else
            _legacy_page_size = self:_baseShelves() * self:_nCols()
        end
        self._cursor = math.max(1, (_saved_page - 1) * _legacy_page_size + 1)
    end
    self.page = 1  -- derived; recomputed by _syncPageFromCursor below.
    -- Drill state persists across widget recreations (e.g. KOReader was
    -- restarted while the user had drilled into an author stack). The
    -- saved form is identifiers only -- _restoreDrillPath() re-hydrates
    -- via Repo.findGroup / Repo.buildBookMeta so cover_bbs are fresh
    -- (see memory feedback_image_disposable_shared_book).
    self._drilldown_path = {}
    local saved_drill = BookshelfSettings.read("drill_path")
    if type(saved_drill) == "table" then
        self._pending_restore_drill = saved_drill
    end
    -- Class-level pointer to the live instance. Lets main.lua's
    -- FileChooser:refreshPath wrapper find us without depending on which
    -- plugin context (FM vs Reader) installed the wrapper.
    BookshelfWidget.live = self

    -- Page-flipping swipe gestures (anywhere on the home screen): west = next
    -- page, east = previous page. Bound to a wide screen-zone so users can
    -- flick from anywhere — the chip strip / hero / shelf rows don't claim
    -- swipe gestures themselves so this catches all of them. Uses the
    -- DTAP_ZONE_FORWARD / _BACKWARD ratios from KOReader defaults so it
    -- matches the rest of the app's "swipe to page" muscle memory.
    -- GestureRange.direction is a STRING ("west"/"east"/...), not a set.
    -- The match check is `self.direction ~= gs.direction` — passing a table
    -- never equals a string, which is why the previous { west = true }
    -- attempt produced gestures that never fired.
    -- Runtime expand/collapse flag. When true the hero collapses to a thin
    -- strip via HeroCard's compact mode and an extra shelf row appears (more
    -- books on screen for browse-mode). Sticky within the session, resets on
    -- restart (no settings write — fresh widget instance reseeds false).
    self._expanded = false

    self.ges_events = {
        SwipeNextPage = {
            GestureRange:new{ ges = "swipe", range = self.dimen, direction = "west" },
        },
        SwipePrevPage = {
            GestureRange:new{ ges = "swipe", range = self.dimen, direction = "east" },
        },
        -- North-swipe: collapse the hero / expand the grid.
        -- South-swipe: restore the hero.
        -- Range is the inner 6/8 of screen width, leaving the outer 1/8 on
        -- each side free. KOReader's edge-swipe zones (brightness, warmth)
        -- are defined as DSWIPE_ZONE_LEFT_EDGE = {x=0, w=1/8} and
        -- DSWIPE_ZONE_RIGHT_EDGE = {x=7/8, w=1/8}. If our range covers those
        -- strips, vertical swipes near the edges fire our handler instead of
        -- adjusting brightness/warmth. The 1/8 inset matches that contract.
        SwipeShelvesUp = {
            GestureRange:new{
                ges = "swipe", direction = "north",
                range = Geom:new{
                    x = math.floor(self.width / 8),
                    y = 0,
                    w = self.width - 2 * math.floor(self.width / 8),
                    h = self.height,
                },
            },
        },
        SwipeShelvesDown = {
            GestureRange:new{
                ges = "swipe", direction = "south",
                range = Geom:new{
                    x = math.floor(self.width / 8),
                    y = 0,
                    w = self.width - 2 * math.floor(self.width / 8),
                    h = self.height,
                },
            },
        },
    }

    -- Hardware page-turn buttons (Kindle Oasis/Voyage, Kobo Forma/Libra,
    -- Bigme/Boox/other Android e-ink with key-mapped vol keys) — bind to
    -- the same pagination path as swipes. Without these bindings, key
    -- events fall through to the FileManager underneath us, which
    -- paginates its hidden file list and on Android can wedge the UI
    -- thread long enough to trigger an ANR (issue #1).
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    if Device:hasDPad() then
        self.key_events = self.key_events or {}
        self.key_events.BSFocusUp    = { { "Up"    } }
        self.key_events.BSFocusDown  = { { "Down"  } }
        self.key_events.BSFocusLeft  = { { "Left"  } }
        self.key_events.BSFocusRight = { { "Right" } }
        self.key_events.BSKbPress    = { { "Press" } }
    end

    -- (Top-zone tap/swipe to open the FM menu is handled by the FileManager
    -- touch-zone passthrough in handleEvent below; no need to mirror those
    -- zones here. Doing so previously also ignored the user's
    -- `activation_menu` preference — fixed as a side benefit.)

    self:_rebuild()
    self:_startStatusTimer()
end

-- Bookshelf is the topmost widget while it's on screen, so KOReader's
-- UIManager:sendEvent dispatches gestures to us alone — FileManager
-- underneath us is NOT is_always_active, so its registered touch zones
-- (which include user-configured gestures from gestures.koplugin: corner
-- taps for night mode, edge swipes for brightness/warmth, etc.) never
-- fire on their own.
--
-- The fix: for Gesture events specifically, walk FileManager's touch
-- zones FIRST. If one matches and consumes the gesture, we're done.
-- Otherwise fall through to our normal InputContainer handling so hero
-- taps, chip taps, swipe-to-paginate, etc. continue to work.
--
-- We only check FM's _ordered_touch_zones — NOT fm:handleEvent — to
-- avoid propagating into FM's child widget tree (which would risk
-- accidentally activating the file list underneath us).
function BookshelfWidget:handleEvent(event)
    -- Two dispatch problems to fix, both stemming from KOReader's
    -- UIManager:sendEvent only delivering events to the topmost widget
    -- (us) and not propagating unhandled events down the window stack to
    -- FileManager (which is NOT is_always_active):
    --
    --   1. Gesture events (input → onGesture). gestures.koplugin's
    --      touch zones are registered against FM, so corner taps and
    --      edge swipes (configured in the user's gesture_fm profile)
    --      never get checked. Walk FM's _ordered_touch_zones FIRST and
    --      let a matching zone consume the gesture. Skip fm:handleEvent
    --      to avoid propagating into FM's child widget tree (which would
    --      let the file list underneath activate book taps).
    --
    --   2. Dispatcher-emitted action events (e.g. IncreaseFlIntensity
    --      from a brightness gesture, ToggleNightMode, etc.). These are
    --      sent via UIManager:sendEvent and die in our widget. For any
    --      non-gesture event we don't consume ourselves, forward it to
    --      fm:handleEvent so FM's registered modules (DeviceListener,
    --      etc.) get a chance. Side-effect: events delivered via
    --      broadcastEvent (Suspend, Resume, etc.) get double-handled —
    --      FM gets them via the broadcast loop AND via our forward.
    --      Accepted because the relevant broadcast events are idempotent.
    if event.handler == "onGesture" then
        -- Children first: let our own widget tree (chevron buttons, chip
        -- strip, hero, shelf covers, swipe zones) consume the gesture
        -- before falling through to FM. KOReader's normal dispatch is
        -- parent → child via propagateEvent; an overlay that pre-empts
        -- with FM zones strips that priority and breaks any third-party
        -- plugin (e.g. SimpleUI's bottom navbar) that registers FM-level
        -- zones overlapping our widgets.
        if InputContainer.handleEvent(self, event) then return true end
        -- Fallback: gestures we didn't consume (top-edge swipes, corner
        -- taps from gestures.koplugin profiles, etc.) reach FM via its
        -- registered touch zones. UIManager only delivers events to the
        -- topmost widget (us), so without this explicit walk those zones
        -- would never fire while Bookshelf is up.
        local fm = require("apps/filemanager/filemanager").instance
        local ev = event.args[1]
        -- Absorb any tap our widget tree didn't consume that falls in the inner
        -- screen region. Without this, gaps in our layout (book-cover spans,
        -- footer padding, etc.) fall through to FM touch zones and activate
        -- third-party plugins registered there (e.g. SimpleUI's bottom navbar).
        --
        -- The outer Screen:scaleBySize(24) strip on each side is left open.
        -- SimpleUI's tap zones all begin at side_m = Screen:scaleBySize(24)
        -- from each edge, so that strip is the exact gap where gestures.koplugin
        -- corner/edge actions (night mode, brightness, etc.) live without
        -- SimpleUI intercepting them.
        -- Absorb taps AND hold_release events in the inner screen region.
        -- The hold_release case is subtle: pagination's prev/next buttons
        -- fire hold_callback on a ±10-page skip, which triggers
        -- _swapShelvesInPlace and rebuilds the footer -- destroying the
        -- Button instance that held _hold_handled = true. When the user
        -- then lifts their finger, the hold_release arrives at the NEW
        -- Button which has no record of the original hold and returns
        -- false from onHoldReleaseSelectButton. Without this absorber,
        -- the release leaks to gestures.koplugin's bottom-edge zones
        -- (SimpleUI's bottom bar, etc.) and surprises the user with an
        -- unrelated menu popup.
        if ev.ges == "tap" or ev.ges == "hold_release" then
            local side_m = Screen:scaleBySize(24)
            local top_m  = Screen:scaleBySize(60)
            if ev.pos.x >= side_m and ev.pos.x <= self.width - side_m
               and ev.pos.y >= top_m then
                return true
            end
        end
        local zone_lists = {}
        if fm and fm._ordered_touch_zones then
            zone_lists[#zone_lists + 1] = fm._ordered_touch_zones
        end
        if fm and fm.menu and fm.menu._ordered_touch_zones then
            zone_lists[#zone_lists + 1] = fm.menu._ordered_touch_zones
        end
        for _i, zones in ipairs(zone_lists) do
            for _i, tzone in ipairs(zones) do
                if tzone.gs_range:match(ev) and tzone.handler(ev) then
                    return true
                end
            end
        end
        return false
    end

    if InputContainer.handleEvent(self, event) then return true end
    -- Forward unhandled events to FM so Dispatcher action events
    -- (IncreaseFlIntensity, ToggleNightMode bound to a gesture, etc.)
    -- reach FM's registered modules. UIManager:sendEvent only delivers to
    -- the topmost widget (us); without this forward, FM-side handlers for
    -- gesture-emitted single-target events would never fire while we're up.
    --
    -- TWO exclusions:
    --
    --   1. Lifecycle events that target THIS widget. UIManager:close(self)
    --      propagates CloseWidget to us; forwarding it to FM tears FM
    --      down (nil'ing FileManager.instance) and breaks all subsequent
    --      gesture forwarding.
    --
    --   2. Events delivered via UIManager:broadcastEvent (tagged in
    --      main.lua's _installBroadcastTag). The broadcast loop already
    --      delivers to FM via its window-stack iteration; our forward
    --      would be a redundant second delivery. Harmless for idempotent
    --      lifecycle broadcasts (Suspend, Resume) but corrupting for
    --      toggle broadcasts (ToggleNightMode flips state twice, net
    --      zero -- issue #19). Skipping the forward for any broadcast
    --      lets the loop's natural delivery do its job.
    local NEVER_FORWARD = {
        onCloseWidget   = true,
        onFlushSettings = true,
        onShow          = true,
        onClose         = true,
    }
    if NEVER_FORWARD[event.handler] then return end
    if event._bookshelf_from_broadcast then return end
    local fm = require("apps/filemanager/filemanager").instance
    if fm and fm ~= self then
        return fm:handleEvent(event)
    end
end

-- ─── _rebuild ─────────────────────────────────────────────────────────────────

-- Remove a deleted filepath from any drilldown payload that captured it
-- at descend-time. Series / author / genre / tag drilldowns all keep
-- their book list in tip.payload.books (see _fetchChipItems); without
-- this, deleting a book from inside such a drilldown leaves a ghost
-- entry visible until the user backs out and re-enters.
--
-- Search-mode payloads carry a similar `.books` list and matching
-- group lists; scrub them all.
--
-- Folder drilldown re-queries the filesystem via Repo.getAll on every
-- render, so no payload mutation needed for that path.
function BookshelfWidget:_scrubFromDrilldown(filepath)
    if not filepath or not self._drilldown_path then return end
    for _i, entry in ipairs(self._drilldown_path) do
        local payload = entry and entry.payload
        if type(payload) == "table" then
            local lists = { payload.books, payload.series,
                            payload.authors, payload.genres,
                            payload.folders }
            for _i, list in ipairs(lists) do
                if type(list) == "table" then
                    for i = #list, 1, -1 do
                        local item = list[i]
                        if type(item) == "table" and item.filepath == filepath then
                            table.remove(list, i)
                        elseif type(item) == "table" and type(item.books) == "table" then
                            -- Nested group (e.g. series in a search payload):
                            -- scrub its inner book list too.
                            for j = #item.books, 1, -1 do
                                if item.books[j] and item.books[j].filepath == filepath then
                                    table.remove(item.books, j)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- _serializeDrillPath() -> identifiers-only table suitable for storage.
-- Hydrated payloads carry cover_bbs that can't safely cross widget lifetimes
-- (memory feedback_image_disposable_shared_book), so we save only what's
-- needed to rebuild each entry via Repo lookups on restore.
function BookshelfWidget:_serializeDrillPath()
    local out = {}
    for _i, e in ipairs(self._drilldown_path) do
        if e.kind == "folder" then
            out[#out + 1] = { kind = "folder", label = e.label,
                              path = e.payload and e.payload.path }
        elseif e.kind == "search" then
            out[#out + 1] = { kind = "search",
                              query = e.payload and e.payload.query }
        elseif e.kind == "author" or e.kind == "series"
                or e.kind == "genre" or e.kind == "tag"
                or e.kind == "format" or e.kind == "rating" then
            out[#out + 1] = { kind = e.kind, label = e.label }
        end
        -- Other kinds (transient overlays) are deliberately not persisted.
    end
    return out
end

-- _persistNavState(): saves chip / page / drill path to settings. Called
-- after every _rebuild so the user's exact spot survives KOReader restart
-- (chip already had its own persistence at line 487; page and drill are
-- new). Uses raw saveSetting -- a flush isn't worth the cost on every
-- rebuild, KOReader's own periodic flush will pick it up.
function BookshelfWidget:_persistNavState()
    BookshelfSettings.save("active_chip", self.chip)
    -- Cursor is the primary persisted state; active_page is also written
    -- for back-compat with older bookshelf versions that didn't know
    -- about active_cursor (a user downgrading mid-development should
    -- still land on a sensible page).
    BookshelfSettings.save("active_cursor", self._cursor)
    BookshelfSettings.save("active_page", self.page)
    BookshelfSettings.save("drill_path", self:_serializeDrillPath())
end

-- _restoreDrillPath(saved): rebuild drilldown_path from serialized entries.
-- Walks the saved list and looks up each entry via Repo so the resulting
-- payloads have fresh hydration. Entries whose target no longer exists
-- (e.g. group was renamed, folder was moved) are silently skipped so the
-- user doesn't see a broken drill on the next launch.
function BookshelfWidget:_restoreDrillPath(saved)
    if type(saved) ~= "table" or #saved == 0 then return end
    for _i, e in ipairs(saved) do
        if e.kind == "folder" and e.path then
            self._drilldown_path[#self._drilldown_path + 1] = {
                kind = "folder", label = e.label,
                payload = { path = e.path },
            }
        elseif e.kind == "search" and e.query then
            -- Search restoration intentionally happens via _searchAndDrill
            -- so the payload's folder / author / book lists are rebuilt
            -- against the CURRENT library state, not stale results from
            -- before the device slept.
            self:_searchAndDrill(e.query)
        elseif e.kind == "author" or e.kind == "series"
                or e.kind == "genre" or e.kind == "format"
                or e.kind == "rating" then
            local g = Repo.findGroup(e.kind, e.label)
            if g then
                self._drilldown_path[#self._drilldown_path + 1] = {
                    kind = e.kind, label = e.label, payload = g,
                }
            end
        elseif e.kind == "tag" then
            -- Tag drill uses ReadCollection rather than the group-shape
            -- caches. Restore a minimal payload with .books rebuilt from
            -- the collection; covers re-hydrate per render via the drill
            -- branch in _fetchChipItems.
            local rc = require("readcollection")
            local coll = rc.coll and rc.coll[e.label]
            if type(coll) == "table" then
                local books = {}
                for _file, item in pairs(coll) do
                    local fp = item.file or _file
                    if type(fp) == "string" then
                        books[#books + 1] = { filepath = fp }
                    end
                end
                if #books > 0 then
                    self._drilldown_path[#self._drilldown_path + 1] = {
                        kind = "tag", label = e.label,
                        payload = { kind = "tag", series_name = e.label, books = books },
                    }
                end
            end
        end
    end
end

function BookshelfWidget:_rebuild()
    -- Refresh dimensions; detect landscape from whether Screen swapped them.
    -- Screen:getWidth()/getHeight() DO swap on rotation (KOReader software
    -- rotates the framebuffer content), so raw_w > raw_h reliably means
    -- landscape. The fb0/rotate sysfs node is a permanent panel calibration
    -- constant on PW5 and cannot be used for orientation detection.
    local _raw_w    = Screen:getWidth()
    local _raw_h    = Screen:getHeight()
    self._landscape = (_raw_w > _raw_h)
    self.width      = _raw_w
    self.height     = _raw_h
    self.dimen      = Geom:new{ w = self.width, h = self.height }
    -- One-shot drill restore on the first rebuild after init. Deferred until
    -- here (rather than in init) so the chip-fallback / sort-priority lookups
    -- happen against a fully-loaded TabModel.
    if self._pending_restore_drill then
        local saved = self._pending_restore_drill
        self._pending_restore_drill = nil
        self:_restoreDrillPath(saved)
    end
    local _perf_t0   = _gettime()
    local _perf_chip = self.chip
    local _perf_page = self.page
    -- Defer freeing the previous widget tree to the next UIManager tick.
    -- Calling :free() synchronously during an event handler tears down
    -- ImageWidget bb buffers that may still be referenced by an in-flight
    -- paint, producing native segfaults (notably on rapid swipe-to-paginate).
    -- nextTick lets the current event handler return, the new tree paint to
    -- finish, and only then reaps the old tree's resources.
    if self[1] and self[1].free then
        local old_tree = self[1]
        UIManager:nextTick(function()
            local ok, err = pcall(function() old_tree:free() end)
            if not ok then
                require("logger").warn("[bookshelf] tree free failed:", err)
            end
            -- LuaJIT's incremental GC falls behind the chip-switch rate and
            -- RSS climbs ~5 MiB per toggle while bbs sit eligible-but-not-
            -- collected. We do incremental "step" work each rebuild (cheap,
            -- no visible pause) and a full "collect" only every 4th rebuild
            -- so the user-visible interaction stays snappy.
            collectgarbage("step", 200)
            BookshelfWidget._rebuild_count = (BookshelfWidget._rebuild_count or 0) + 1
            if BookshelfWidget._rebuild_count >= 4 then
                BookshelfWidget._rebuild_count = 0
                collectgarbage("collect")
            end
        end)
    end

    -- ── Single layout constant ────────────────────────────────────────────────
    -- ONE margin/padding value drives every gap on the home screen: page edges,
    -- cover-to-cover gap, hero text indent, and inter-section vertical gaps.
    -- Adjust this to tighten or loosen the entire layout proportionally.
    --
    -- Capped at ~3% of screen width so it stays sensible at extreme DPI /
    -- font scale settings. Without the cap, Size.padding.fullscreen
    -- (which itself scales with DPI) would inflate from ~32px at native
    -- DPI to ~120px at 640dpi — eating 240px of width per row, which
    -- visibly shrinks every cover thumbnail. The cap means at any DPI
    -- the layout reserves the same proportional whitespace, so covers
    -- keep their relative size.
    local pad_natural = math.floor(Size.padding.fullscreen * 2 * 0.8)
    local pad_capped  = math.floor(self.width * 0.03)
    local PAD         = math.min(pad_natural, pad_capped)
    local side_pad  = PAD
    local content_w = self.width - side_pad * 2

    -- Height constants. Size.item.height_small does not exist (Phase 3-5 lesson);
    -- use height_default (~30dp) for the chip strip. Scale by the user's
    -- chip-font setting (100-300) so the strip grows to accommodate larger
    -- text without clipping. ChipBar itself reads the same setting to scale
    -- the fonts it renders -- keep this calc and the strip's _scaled() in
    -- sync (both pull from bookshelf_chip_font_scale).
    local _chip_font_scale = BookshelfSettings.read("chip_font_scale") or 100
    local chip_h  = math.floor(Size.item.height_default * _chip_font_scale / 100 + 0.5)
    -- Pagination footer reservation. Match _buildPaginationFooter's
    -- CenterContainer height exactly: chev_size (32dp icon) + vertical
    -- padding on each side. The footer's per-button downward hit-zone
    -- extension overflows the CC's outer dimen into the outer_bot_PAD
    -- area below the footer; it does NOT count toward this reservation,
    -- so shelves keep their original size.
    local footer_h = Screen:scaleBySize(32) + Size.padding.default * 2
    local label_h  = footer_h

    -- Detect "all chips disabled" early so the hero can grow into the
    -- chip strip's vertical footprint when it would otherwise be empty.
    -- The chip strip stays visible whenever a drill-down path is active
    -- (so the user can navigate back via the breadcrumb), even if every
    -- chip is disabled.
    local TabModel = require("lib/bookshelf_tab_model")
    local active_chips = {}
    -- "Currently reading" action chip at the LEFT edge: always visible so
    -- it serves as a stable anchor and a perma-affordance. Renders in the
    -- selected (inverted/black-fill) state when the hero is showing the
    -- lastfile book (no preview, OR preview matches lastfile) — its
    -- selection state then mirrors "this is what's in your hero right
    -- now". Tap when unselected clears the preview so the hero falls
    -- back to the lastfile; tap when selected is a no-op. Fixed-width
    -- via `action = true` so it doesn't shrink the navigation tabs.
    local _lastfile = Repo.getCurrent and Repo.getCurrent()
    -- The "currently reading" chip's selected state means "the lastfile is
    -- the book the hero is showing right now". In expanded mode there's no
    -- visible hero, so the chip is always deselected — tapping it acts as
    -- "restore hero on the lastfile" (clears _expanded AND _preview_book).
    local current_in_hero = (not self._expanded)
        and ((not self._preview_book)
             or (_lastfile and self._preview_book.filepath == _lastfile.filepath))
    active_chips[#active_chips + 1] = {
        key        = "current",
        nerd_glyph = "\xEE\x9E\xBD",  -- material design open-book (U+E7BD)
        action     = true,
        selected   = current_in_hero or false,
    }
    -- Build nav chips from TabModel: enabled tabs in the user's saved order.
    -- The tab schema now stores label and icons as ONE string (label can
    -- contain inline nerd-font glyphs); the legacy tab.icon field still
    -- gets prepended for back-compat until the user re-saves and the
    -- editor migrates the record to the merged form.
    for _i, tab in ipairs(TabModel.getActive()) do
        local display = tab.label or ""
        if tab.icon and tab.icon ~= "" then
            display = tab.icon .. " " .. display
        end
        active_chips[#active_chips + 1] = { key = tab.id, label = display }
    end
    -- Hide the strip when 0 or 1 chips are enabled (a single full-width
    -- chip is just a non-interactive label) AND no drill-down is active
    -- (the breadcrumb still needs the strip's slot for back-navigation).
    local hide_chip_bar = (#active_chips <= 1) and (#self._drilldown_path == 0)
    -- Defensive: the user can disable every tab via the editor.
    -- Fall back to all defaults so the shelves still have a data source
    -- even when the strip is hidden.
    if #active_chips == 0 then
        for _i, tab in ipairs(TabModel.DEFAULTS()) do
            active_chips[#active_chips + 1] = { key = tab.id, label = tab.label }
        end
    end
    -- If the currently-selected chip was just disabled, switch to the
    -- first surviving chip so render doesn't try to fetch from a
    -- disabled chip's data source.
    local active_in_set = false
    for _i, c in ipairs(active_chips) do
        if c.key == self.chip then active_in_set = true; break end
    end
    if not active_in_set then
        -- Skip action chips (current, search) — they have no data source.
        -- Fall back to the first nav chip instead.
        self.chip = active_chips[1].key
        for _i, c in ipairs(active_chips) do
            if not c.action then self.chip = c.key; break end
        end
        BookshelfSettings.save("active_chip", self.chip)
    end
    -- Append a search "chip" (icon-only, action-on-tap rather than
    -- chip-switch). Always appended last so it sits at the right edge.
    -- Tap is intercepted in the on_change closure below — search never
    -- becomes self.chip, so it doesn't enter the swipe-cycle.
    -- Nerd-font glyph U+F002 (fa-search) renders bolder than the
    -- bundled mdlight appbar.search SVG; ChipBar threads it through
    -- a TextWidget with KOReader's xtext fallback to symbols.ttf.
    active_chips[#active_chips + 1] = {
        key        = "search",
        nerd_glyph = "\xEF\x80\x82",
        action     = true,
    }
    -- Cache the ordered chip keys + hidden state so the edge-swipe
    -- handlers can cycle between tabs without re-deriving them. The
    -- list reflects the ordering TabModel.getActive() returned (the
    -- user's saved tab order from the editor).
    self._active_chip_keys = {}
    self._dpad_chip_keys   = {}
    self._action_chip_keys = {}
    for _i, c in ipairs(active_chips) do
        -- Exclude action chips from the swipe-cycle ring (search, current
        -- book, …) — they're actions, not navigable tabs.
        if not c.action then
            self._active_chip_keys[#self._active_chip_keys + 1] = c.key
        else
            self._action_chip_keys[c.key] = true
        end
        -- D-pad chip ring includes action chips so the user can reach the
        -- search button and "currently reading" indicator by keyboard.
        self._dpad_chip_keys[#self._dpad_chip_keys + 1] = c.key
    end
    self._chip_bar_hidden = hide_chip_bar

    -- The shelf row + chip strip + pagination footer all stay at fixed
    -- positions across the expand/collapse toggle. The HERO is the only
    -- part that flexes: in expanded mode it's a compact strip sized for the
    -- cover-bleed peek; in normal mode it absorbs the vertical slack from
    -- having one fewer shelf row.
    --
    -- shelf_h is locked to what 3 rows + compact hero + chips + label can
    -- afford (the most-constrained mode). Same value applies in normal mode
    -- so toggling never shifts the shelves or the pagination. ShelfRow caps
    -- slot_h to opts.height with aspect preservation, so covers shrink
    -- proportionally to fit shelf_h.
    local hero_cover_w_natural = math.floor(content_w * 0.30)
    local hero_cover_h_natural = math.floor(hero_cover_w_natural * 1.5)

    -- Natural shelf row dimensions: n_cols covers fill content_w with PAD
    -- gaps, preserving the 2:3 cover aspect ratio. Used in BOTH modes so
    -- cover size doesn't shift between expanded / collapsed — the hero is
    -- the only element that flexes. Pagination y stays fixed.
    local n_cols         = self:_nCols()
    local slot_w_natural = math.floor((content_w - PAD * (n_cols - 1)) / n_cols)
    local slot_h_natural = math.floor(slot_w_natural * 1.5)

    -- Vertical layout (outer-top to outer-bottom):
    --   outer_top_PAD + hero + hero_chip_pad
    --   + [chips + chip_row_PAD]   (when chips visible)
    --   + n_shelves × (shelf + after_row_PAD)
    --   + label + outer_bot_PAD
    --
    -- Expanded mode uses a small Size.padding.default between strip and
    -- chips (rather than the full PAD) so the strip + chip transition
    -- doesn't eat into shelf vertical real estate. Normal mode keeps PAD
    -- there so the hero card has visible breathing room.
    local n_shelves     = self:_nShelves()
    local chip_contrib  = hide_chip_bar and 0 or chip_h
    local hero_chip_pad = self._expanded and Size.padding.large or PAD
    local total_pad = PAD * 2                                  -- outer (top + bot)
                    + hero_chip_pad                            -- hero → chips/row1
                    + ((not hide_chip_bar) and PAD or 0)     -- chips → row1
                    + n_shelves * PAD                          -- after each row

    local shelf_h, hero_h
    if self._expanded then
        -- Strip is sized to the status_row's natural height — no padding
        -- slack inside it, so every spare pixel goes to the shelves and
        -- covers stay closer to natural aspect after the title block claims
        -- its slice. We probe HeroCard.buildStatusRow for its rendered
        -- height; falling back to a small fixed dp if no current book.
        local probe_book = (self._preview_book and self._preview_book.filepath
                            and Repo.buildBook(self._preview_book.filepath))
                            or self._preview_book
                            or (Repo.getCurrent and Repo.getCurrent())
        -- Hand the freshly-built probe record off to _buildHero so it
        -- doesn't pay another DocSettings:open() for the same filepath
        -- in the same rebuild cycle. Only when the probe built a
        -- preview-book record (not the fallback to getCurrent), so the
        -- cache is precisely scoped. Cleared in _buildHero after use.
        if probe_book and self._preview_book
                and probe_book.filepath == self._preview_book.filepath then
            self._hero_book_cache = probe_book
        end
        local probe_row  = probe_book and HeroCard.buildStatusRow(
                                probe_book, self:_buildDeviceState(),
                                content_w, false)
        local strip_minimum = probe_row and probe_row:getSize().h
                              or Screen:scaleBySize(20)
        shelf_h = math.max(1, math.floor(
            (self.height - strip_minimum - chip_contrib - label_h - total_pad)
            / n_shelves))
        hero_h = strip_minimum
    else
        -- _nShelves() now picks n dynamically to keep hero >= MIN_HERO_SHARE
        -- of available height (issue #36), so the natural-aspect shelf
        -- math should already satisfy the floor in most cases. The clamp
        -- below is the backstop: catches landscape (where slot_h_natural
        -- exceeds available height and the subtraction goes negative) and
        -- any edge case where n_shelves landed at 1 but slot_h alone still
        -- crowds the hero. Covers shrink uniformly via ShelfRow's slot-h
        -- cap with aspect preservation, so cover/title pairs stay readable.
        local available  = self.height - chip_contrib - label_h - total_pad
        local min_hero_h = math.floor(available * MIN_HERO_SHARE)
        shelf_h = slot_h_natural
        hero_h  = self.height - n_shelves * shelf_h - chip_contrib - label_h - total_pad
        if hero_h < min_hero_h then
            shelf_h = math.max(1, math.floor((available - min_hero_h) / n_shelves))
            hero_h  = math.max(min_hero_h,
                self.height - n_shelves * shelf_h - chip_contrib - label_h - total_pad)
        end
    end

    local hero_cover_w, hero_cover_h
    if self._expanded then
        hero_cover_w = hero_cover_w_natural
        hero_cover_h = hero_cover_h_natural
    else
        hero_cover_h = math.max(1, hero_h)
        hero_cover_w = math.max(1, math.floor(hero_cover_h / 1.5))
    end

    -- Title bar removed: clock + battery moved to the bottom of the hero
    -- card right column (large font, below the progress bar). The gear
    -- menu is reachable via the system top-zone tap/swipe (FileManagerMenu)
    -- and via long-press on the hero or any cover.
    local titlebar_h = 0

    -- Each shelf row shares the remaining vertical space equally. When
    -- the chip strip is hidden the hero already absorbed chip_h + PAD,
    -- so reserved_h's chip-strip contributions drop out and the
    -- shelf_h calculation lands on the same value either way.
    -- shelf_h and n_shelves were locked above; nothing more to compute
    -- here. Kept for callers that read the layout via stashed dims.

    -- ── Hero card ─────────────────────────────────────────────────────────────
    -- Hero shows the user's "selected" book: a previewed shelf book if any,
    -- otherwise the lastfile-resolved currently-reading book. Tapping the
    -- hero opens whichever book is shown; tapping a shelf cover sets the
    -- preview without opening.
    --
    -- _buildHero is factored out so _previewBook can swap just the hero into
    -- the existing tree without rebuilding chips/shelves/pagination — see
    -- the fast-path in _previewBook below.
    local hero
    if self._expanded then
        hero = self:_buildExpandedStrip(content_w, hero_h, PAD)
    else
        hero = self:_buildHero(content_w, hero_cover_w, hero_cover_h, hero_h, PAD)
    end
    local _perf_t1 = _gettime()
    logger.dbg(string.format("[bookshelf perf] _rebuild: hero=%.0fms chip=%s page=%d",
        (_perf_t1 - _perf_t0) * 1000, _perf_chip, _perf_page))
    -- Stash dimensions and the hero's parent vgroup so _previewBook can
    -- rebuild only the hero. Both the populated and empty-state branches
    -- below set _hero_parent at assembly time.
    self._hero_dims = {
        content_w    = content_w,
        hero_cover_w = hero_cover_w,
        hero_cover_h = hero_cover_h,
        hero_h       = hero_h,
        PAD          = PAD,
    }

    -- ── Chip strip ────────────────────────────────────────────────────────────
    -- Two modes share the same widget: chips-list at top level, or a
    -- breadcrumb when the user has drilled into a chip-level item.
    -- Skipped entirely when hide_chip_bar is true (every chip
    -- disabled AND no drill-down) so the hero can claim the slot.
    local breadcrumb_path = nil
    local in_search_mode  = false
    if #self._drilldown_path > 0 then
        breadcrumb_path = {}
        for i, entry in ipairs(self._drilldown_path) do
            breadcrumb_path[i] = { label = entry.label }
            if entry.kind == "search" then in_search_mode = true end
        end
    end
    -- Search-mode chip pill: shows the search nerd-font glyph (U+F002)
    -- followed by "Search results" so the user reads
    -- "< Back  [search-icon] SEARCH RESULTS > query". The Back pill is an
    -- explicit exit from search mode; tapping the chip pill or the query
    -- crumb re-opens the search dialog with the current query prefilled
    -- (lets the user fix typos without starting over).
    local chip_pill_glyph = in_search_mode and "\xEF\x80\x82" or nil
    local chip_pill_label
    if in_search_mode then
        chip_pill_label = "Search results"
    else
        local _t = TabModel.getById(self.chip)
        chip_pill_label = (_t and _t.label) or self.chip
    end
    -- ChipBar prefixes a chevron-left glyph automatically; we just
    -- supply the bare label.
    local back_label = in_search_mode and "Back" or nil
    local chips = not hide_chip_bar and ChipBar:new{
        chips             = active_chips,
        active            = self.chip,
        focused_key       = self._chip_cursor_key,
        width             = content_w,
        height            = chip_h,
        breadcrumb_path   = breadcrumb_path,
        chip_pill_label   = chip_pill_label,
        chip_pill_glyph   = chip_pill_glyph,
        back_label        = back_label,
        -- show_parent points the strip at the window-level widget so
        -- its tap-feedback can flag a repaint. UIManager:setDirty only
        -- accepts widgets registered with UIManager:show.
        show_parent       = self,
        on_change = function(key)
            -- Search "chip" is an action, not a navigable tab — open
            -- the search dialog and bail before switching self.chip.
            if key == "search" then
                self:_openSearchDialog()
                return
            end
            -- "Currently reading" chip clears the preview so the hero
            -- falls back to Repo.getCurrent() (= lastfile). Same effect
            -- as the swipe-up gesture, but discoverable via the visible
            -- icon. Doesn't change self.chip — user stays on whatever
            -- shelf they were browsing. Full _rebuild because the action
            -- chip itself disappears with this clear (its presence is
            -- conditional on preview ≠ lastfile).
            if key == "current" then
                -- Clear preview AND collapse expanded mode so the hero
                -- comes back showing the lastfile. In expanded mode the
                -- chip is rendered deselected (no visible hero), so the
                -- user expects this tap to restore the hero view.
                self:_clearDpadFocus()
                self._preview_book = nil
                self._expanded     = false
                self:_rebuild()
                UIManager:setDirty(self, "ui")
                return
            end
            -- Switch chips → reset drill path and page; preserve
            -- _preview_book so the user's "current selection" survives
            -- a tab tour. The highlight on the new chip's shelf only
            -- paints when the previewed book happens to be visible
            -- there; the hero still shows the previewed book in any
            -- case (it's bound to _preview_book, not the chip).
            self:_clearDpadFocus()
            self._drilldown_path = {}
            self.chip            = key
            self._cursor         = 1
            self:_syncPageFromCursor()
            BookshelfSettings.save("active_chip", key)
            self:_rebuild()
            UIManager:setDirty(self, "ui")
        end,
        on_breadcrumb = function(depth)
            -- depth -1 = back pill (search mode only): exit search
            --            entirely, restoring the prior drilldown path.
            -- depth  0 = chip pill: in search mode, re-open the search
            --            dialog with the current query prefilled (so the
            --            user can fix typos without retyping); in other
            --            drilldowns, pop to top of current chip.
            -- depth  N = crumb at index N: in search mode for the deepest
            --            crumb (= query), same edit-search behaviour as
            --            the chip pill; otherwise pop to that level.
            if depth == -1 then
                self:_drillBackTo(0)
                return
            end
            if in_search_mode then
                local search_entry = self._drilldown_path[#self._drilldown_path]
                local query = search_entry and search_entry.payload
                              and search_entry.payload.query
                self:_openSearchDialog(query)
                return
            end
            self:_drillBackTo(depth)
        end,
        on_hold = function(key)
            local Editor = require("lib/bookshelf_chip_editor")
            Editor:editTab(key, {
                on_change = function()
                    self:_rebuild()
                    UIManager:setDirty(self, "ui")
                end,
                bw        = self,
            })
        end,
    }
    -- Stash the strip so swipe-cycling (_setActiveChip) can ask it to
    -- pre-paint a "pending" border on the destination chip — same
    -- responsiveness affordance that taps already get via onTapStrip.
    self._chip_bar = chips or nil

    -- ── Shelf items ───────────────────────────────────────────────────────────
    -- PAGE_SIZE = _pageSize() = _viewSize(): non-overlapping pagination,
    -- so the next-page chevron always advances by a full screen-worth of
    -- books regardless of expand/collapse state.
    -- Decoupling them means toggling preserves the top rows: expanded reveals
    -- one extra row at the bottom while the rest stays identical.
    local PAGE_SIZE  = self:_pageSize()
    local VIEW_SIZE  = self:_viewSize()
    -- Cap the fetch at a sane upper bound — far below "9999" and well above
    -- realistic libraries (50 pages × 8 = 400 items). This keeps allocation
    -- bounded so a degenerate library size can't blow up GC pressure on
    -- chip switches, while still letting the chevron pagination display
    -- "Page X of Y" accurately for any reasonable user.
    local MAX_FETCH  = 400
    local all_items, _total_hint = self:_fetchChipItems(MAX_FETCH)
    all_items = all_items or {}
    local _perf_t2 = _gettime()
    logger.dbg(string.format("[bookshelf perf] _rebuild: fetch=%.0fms items=%d chip=%s",
        (_perf_t2 - _perf_t1) * 1000, _total_hint or #all_items, _perf_chip))
    local total      = _total_hint or #all_items
    -- Total pages = ceil(total / VIEW_SIZE) under the cursor model (no
    -- overlap on pagination). Clamp the cursor to the valid range
    -- BEFORE deriving self.page for display: total may have changed
    -- since the cursor was last persisted, so the previously-valid
    -- cursor might be off the end.
    local total_pages
    if total <= VIEW_SIZE then
        total_pages = 1
    else
        total_pages = math.ceil(total / VIEW_SIZE)
    end
    -- Cache for the swipe handlers (which run outside _rebuild's scope).
    self._total_pages = total_pages
    self._total_items = total
    self:_clampCursor(total)
    self:_syncPageFromCursor()
    -- all/folder chips return a pre-sliced page; others return the full list.
    local items
    if _total_hint then
        items = all_items
    else
        local start_idx = self._cursor
        items = {}
        for i = 0, VIEW_SIZE - 1 do items[i + 1] = all_items[start_idx + i] end
    end
    -- Only count non-nil entries (the last page may be partial).
    local shown_count = 0
    for i = 1, VIEW_SIZE do if items[i] then shown_count = shown_count + 1 end end
    self._page_items = items
    if self._cursor_idx then
        local last_real = 0
        for i = #items, 1, -1 do if items[i] then last_real = i; break end end
        local clamp_to = last_real > 0 and last_real or 1
        if self._cursor_idx > clamp_to then self._cursor_idx = clamp_to end
    end

    -- ── Empty-state placeholder (spec §8: "Selected chip yields zero books") ────
    -- When the active chip returns no items, replace both shelf rows with a
    -- single paper-card placeholder carrying chip-specific guidance text.
    -- This path is reached for:
    --   • "favorites"  when ReadCollection.favorites is empty or missing
    --   • "series"     when no books in ReadHistory carry series metadata
    --   • "recent"     when ReadHistory is empty
    --   • "latest"     when home_dir is empty / yields no supported files
    if #items == 0 then
        -- Resolve the chip's source kind so we can branch on it (not on
        -- self.chip, which is a chip id -- custom chips have ids like
        -- "custom_3" but their source.kind tells us what view they show).
        -- Default built-in chips have id == source.kind, so the existing
        -- chip-id checks below still hit; the source-kind path catches
        -- custom chips that adopt a built-in source (e.g. user's chip
        -- with source.kind = "all" or "library", i.e. home folders /
        -- home flattened).
        local TabModel = require("lib/bookshelf_tab_model")
        local _tab = TabModel.getById(self.chip)
        local _source_kind = (_tab and _tab.source and _tab.source.kind)
                              or self.chip
        local _is_home_source = _source_kind == "all" or _source_kind == "library"

        -- Branch on _source_kind, NOT self.chip. Chip IDs stay sticky
        -- after the user changes a chip's source via the editor (a chip
        -- created as "genres" keeps id="genres" even when re-pointed at
        -- "library"), so keying off self.chip lights the wrong empty
        -- message ("No genres yet" on a home-flattened chip). Default
        -- built-in chips have id == source.kind so this still serves
        -- them correctly.
        local placeholder_text
        local _tip = self._drilldown_path[#self._drilldown_path]
        if _tip and _tip.kind == "search" then
            placeholder_text = string.format(
                _("No matches for \"%s\""), _tip.payload.query or "")
        elseif _source_kind == "series" then
            placeholder_text = _("Nothing in Series yet · Add series metadata to your books and they will appear here")
        elseif _source_kind == "authors" then
            placeholder_text = _("No authors yet · Add author metadata to your books and they will appear here")
        elseif _source_kind == "genres" then
            placeholder_text = _("No genres yet · Add keywords or subject metadata to your books and they will appear here")
        elseif _source_kind == "tags" then
            placeholder_text = _("No tags yet · Long-press a book and tap 'Add to collection' to create one")
        elseif _source_kind == "favorites" then
            placeholder_text = _("No favourites yet · Long-press a book and tap 'Add to favourites'")
        elseif _source_kind == "latest" then
            placeholder_text = _("No books found · Set your library folder in Settings then tap Latest")
        elseif _source_kind == "recent" then
            placeholder_text = _("No recent reads yet · Open a book and it will appear here")
        elseif _is_home_source then
            -- "Home (folders)" (kind "all") + "Home (flattened)" (kind
            -- "library") both depend on KOReader's home_dir being set.
            -- The "Set home folder" button below drives KOReader's
            -- path-chooser dialog directly.
            placeholder_text = _("No books here yet \xC2\xB7 Pick a folder to use as your KOReader library and books in it will appear here.")
        else
            -- Source kinds without a bespoke message: formats / ratings,
            -- "specific" group drill-ins (folder / collection / tag /
            -- genre / author), or anything else not enumerated above.
            local builtin_kinds = { all=1, library=1, recent=1, latest=1,
                series=1, authors=1, genres=1, tags=1, formats=1,
                ratings=1, favorites=1 }
            if _source_kind and not builtin_kinds[_source_kind] then
                placeholder_text = string.format(
                    _("No books in %s yet \xC2\xB7 Long-press the chip to edit its source or filter"),
                    _tab and _tab.label or self.chip)
            else
                placeholder_text = string.format(_("No books in %s yet"), self:_chipLabel())
            end
        end

        -- Blitbuffer.gray semantics: 0 = white, 1 = black (i.e. "blackness level").
        -- Page background is plain white (matches e-ink unprinted paper);
        -- placeholder card has a faint grey tint to set it apart from the page.
        local paper_bg = Blitbuffer.COLOR_WHITE
        local card_bg  = Blitbuffer.gray(0.07)

        -- Split the placeholder text into headline + sub on the bullet
        -- marker. Most chip-specific messages already follow this shape
        -- ("No favourites yet · Long-press a book and tap..."), so we
        -- can render the parts with different weights. Strings without
        -- a bullet render as headline only.
        local headline_text, sub_text
        local sep_start, sep_end = placeholder_text:find(" \xC2\xB7 ", 1, true)
        if sep_start then
            headline_text = placeholder_text:sub(1, sep_start - 1)
            sub_text      = placeholder_text:sub(sep_end + 1)
        else
            headline_text = placeholder_text
            sub_text      = nil
        end

        -- Card claims all available shelf-area height so the empty state
        -- has visible presence -- the original card was a thin strip pinned
        -- to the chip-strip bottom with the rest of the screen blank, which
        -- read as broken UI rather than guidance. Account for outer
        -- FrameContainer padding (PAD * 2), the hero + chip strip + their
        -- gaps inside the vgroup, and an extra PAD margin around the card.
        local VerticalSpan = require("ui/widget/verticalspan")
        local card_h
        if hide_chip_bar then
            card_h = self.height - 3 * PAD - hero_h
        else
            card_h = self.height - 4 * PAD - hero_h - chip_h
        end
        -- Floor at a sensible minimum so an unusually tall hero doesn't
        -- squash the card into nothing.
        local min_card_h = Screen:scaleBySize(140)
        if card_h < min_card_h then card_h = min_card_h end

        local card_inner_w = content_w - Size.padding.large * 2

        local card_children = { align = "center" }
        -- bgcolor must match the card -- TextBoxWidget defaults to
        -- COLOR_WHITE and paints its own background fill, which shows up
        -- as a white block on the grey card if we don't override.
        card_children[#card_children + 1] = TextBoxWidget:new{
            text      = headline_text,
            face      = Font:getFace("infofont", 22),
            bold      = true,
            bgcolor   = card_bg,
            width     = card_inner_w,
            alignment = "center",
        }
        if sub_text and sub_text ~= "" then
            card_children[#card_children + 1] = VerticalSpan:new{
                width = Size.padding.large,
            }
            card_children[#card_children + 1] = TextBoxWidget:new{
                text      = sub_text,
                face      = Font:getFace("infofont", 15),
                bgcolor   = card_bg,
                width     = card_inner_w,
                alignment = "center",
            }
        end
        if _is_home_source then
            local Button = require("ui/widget/button")
            card_children[#card_children + 1] = VerticalSpan:new{
                width = Size.padding.fullscreen,
            }
            local bw = self
            card_children[#card_children + 1] = Button:new{
                text           = _("Set home folder"),
                width          = math.floor(card_inner_w * 0.5),
                text_font_size = 16,
                callback       = function()
                    local filemanagerutil =
                        require("apps/filemanager/filemanagerutil")
                    local current = G_reader_settings:readSetting("home_dir")
                    local default = filemanagerutil.getDefaultDir()
                    filemanagerutil.showChooseDialog(
                        _("Current home folder:"),
                        function(path)
                            G_reader_settings:saveSetting("home_dir", path)
                            if Repo.invalidateWalkCache then
                                Repo.invalidateWalkCache()
                            end
                            bw:_rebuild()
                            UIManager:setDirty(bw, "ui")
                        end,
                        current,
                        default)
                end,
            }
        end

        local placeholder = FrameContainer:new{
            bordersize = Size.border.thin,
            background = card_bg,
            padding    = Size.padding.large,
            width      = content_w,
            height     = card_h,
            CenterContainer:new{
                dimen = Geom:new{
                    w = card_inner_w,
                    h = card_h - Size.padding.large * 2,
                },
                VerticalGroup:new(card_children),
            },
        }

        local empty_vgroup
        if hide_chip_bar then
            empty_vgroup = VerticalGroup:new{
                align = "left",
                hero,
                VerticalSpan:new{ width = PAD },
                placeholder,
            }
        else
            empty_vgroup = VerticalGroup:new{
                align = "left",
                hero,
                VerticalSpan:new{ width = PAD },
                chips,
                VerticalSpan:new{ width = PAD },
                placeholder,
            }
        end
        self._hero_parent = empty_vgroup        -- hero lives at index 1
        self[1] = FrameContainer:new{
            bordersize = 0,
            padding    = PAD,
            background = paper_bg,
            -- Force the page background to fill the whole screen so the
            -- underlying FileManager doesn't bleed through below the content.
            width      = self.width,
            height     = self.height,
            empty_vgroup,
        }
        logger.dbg(string.format("[bookshelf perf] _rebuild: EMPTY total=%.0fms chip=%s",
            (_gettime() - _perf_t0) * 1000, _perf_chip))
        return
    end

    local rows = self:_buildShelfRows(items, content_w, shelf_h, PAD, n_shelves)
    local _perf_t3 = _gettime()
    logger.dbg(string.format("[bookshelf perf] _rebuild: shelves=%.0fms",
        (_perf_t3 - _perf_t2) * 1000))
    local label_widget = self:_buildPaginationFooter(content_w, label_h, total_pages)

    -- Kick off BIM extraction for any displayed books with no cached
    -- metadata. Cover-spec dims = single shelf slot.
    local slot_w  = math.floor((content_w - PAD * (n_cols - 1)) / n_cols)
    local slot_h  = math.floor(slot_w * 1.5)
    self:_kickOffMissingMetaExtraction(items, slot_w, slot_h, hero_cover_w, hero_cover_h)

    -- ── Assemble ──────────────────────────────────────────────────────────────
    -- Page background = pure white (e-ink unprinted paper). The defensive
    -- gray() guard from earlier was redundant AND used inverted semantics
    -- (0 = white, 1 = black per Blitbuffer.gray), which produced a near-black
    -- page on first render.
    local paper_bg = Blitbuffer.COLOR_WHITE

    -- Layout order: titlebar / hero / chips / shelf1 / shelf2 / footer-label.
    -- Pagination label moved BELOW the shelves so the shelves dominate the
    -- visual hierarchy and "1–8 of 10 ›" reads as a footer. VerticalSpan
    -- separators between sections give the home screen breathing room.
    local VerticalSpan = require("ui/widget/verticalspan")

    -- Inner content gets horizontal padding only; the titlebar above does
    -- not, so it spans the full screen width. Vertical PADs come from the
    -- VerticalSpan separators in the inner VerticalGroup. When the chip
    -- strip is hidden, the chip widget and one of its surrounding PAD
    -- spans drop out — the remaining PAD keeps the hero from butting
    -- straight against the top shelf row.
    -- Build the inner vgroup as a list so we can splice in N shelf rows
    -- (2 or 3) without separate hide_chip_bar × n_shelves branches.
    -- Expanded mode uses Size.padding.default between strip and chips
    -- (rather than the larger PAD) — the strip + chip strip already give
    -- visual separation, so just a tight standard pad keeps proportions
    -- without eating shelf height.
    local inner_vgroup = VerticalGroup:new{ align = "left", hero }
    local hero_chip_pad = self._expanded and Size.padding.large or PAD
    inner_vgroup[#inner_vgroup + 1] = VerticalSpan:new{ width = hero_chip_pad }
    if not hide_chip_bar then
        inner_vgroup[#inner_vgroup + 1] = chips
        inner_vgroup[#inner_vgroup + 1] = VerticalSpan:new{ width = PAD }
    end
    -- First shelf row index in the vgroup — stashed below for
    -- _swapShelvesInPlace's fast-path swap.
    local shelf_first_idx = #inner_vgroup + 1
    for r = 1, n_shelves do
        inner_vgroup[#inner_vgroup + 1] = rows[r]
        inner_vgroup[#inner_vgroup + 1] = VerticalSpan:new{ width = PAD }
    end
    -- Layout-slack absorber: shelf_h is computed via floor(), which can lose
    -- up to (n_shelves - 1) pixels per render. Without compensating, the
    -- label sits a few pixels above its math-derived y → visible pagination
    -- shift between modes. This VerticalSpan absorbs that exact shortfall
    -- so pagination y locks to self.height - PAD - label_h regardless of
    -- which mode rendered.
    local layout_sum = PAD * 2  -- outer top + bottom
                     + hero_h
                     + hero_chip_pad
                     + ((not hide_chip_bar) and (chip_h + PAD) or 0)
                     + n_shelves * shelf_h
                     + n_shelves * PAD  -- after each row
                     + label_h
    local layout_slack = self.height - layout_sum
    if layout_slack > 0 then
        inner_vgroup[#inner_vgroup + 1] = VerticalSpan:new{ width = layout_slack }
    end
    inner_vgroup[#inner_vgroup + 1] = label_widget
    local footer_idx = #inner_vgroup
    -- shelf_first_idx points at row 1; rows live at first, first+2, first+4
    -- (each separated by a VerticalSpan). Footer index is the actual final
    -- slot (label_widget); compensates for an optional slack VerticalSpan
    -- inserted just before the footer.
    self._hero_parent = inner_vgroup            -- hero lives at index 1
    -- Pagination fast-path stash: _swapShelvesInPlace re-renders only
    -- indices [shelf_top_idx, shelf_bottom_idx, footer_idx] of inner_vgroup,
    -- leaving hero + chips untouched. Avoids the use-after-free path where
    -- a freed BIM bb on _preview_book gets re-rendered as a different book's
    -- pixels (hence corrupted hero covers on every other page flip).
    self._inner_vgroup = inner_vgroup
    self._shelf_dims = {
        content_w        = content_w,
        shelf_h          = shelf_h,
        label_h          = label_h,
        PAD              = PAD,
        hero_cover_w     = hero_cover_w,
        hero_cover_h     = hero_cover_h,
        n_shelves        = n_shelves,
        -- Index layout depends on whether the chip strip is in the vgroup
        -- AND on n_shelves. shelf_first_idx is the row-1 index; each row is
        -- followed by a VerticalSpan, so subsequent rows live at +2.
        shelf_top_idx    = shelf_first_idx,
        shelf_bottom_idx = shelf_first_idx + 2 * (n_shelves - 1),
        footer_idx       = footer_idx,
    }
    local inner_content = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = side_pad,
        padding_right = side_pad,
        inner_vgroup,
    }

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding    = 0,           -- no outer padding — titlebar spans full width
        background = paper_bg,
        -- Force the page background to fill the whole screen so the
        -- underlying FileManager doesn't bleed through below the content.
        width      = self.width,
        height     = self.height,
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = PAD },
            inner_content,
            VerticalSpan:new{ width = PAD },  -- bottom margin so pagination
                                              -- isn't flush with the screen
                                              -- edge; pairs with the leading
                                              -- VerticalSpan above.
        },
    }
    logger.info(string.format("[bookshelf perf] _rebuild: TOTAL=%.0fms chip=%s page=%d/%d items=%d",
        (_gettime() - _perf_t0) * 1000, _perf_chip, _perf_page, total_pages, total))
    self:_persistNavState()
end

-- ─── Background metadata extraction ──────────────────────────────────────────

local BIM_POLL_INTERVAL_S  = 3
local BIM_POLL_MAX_ATTEMPTS = 20

-- _kickOffMissingMetaExtraction(items, slot_w, slot_h)
-- BookInfoManager only knows about books KOReader has already indexed. Books
-- the user has dropped into their library but never opened (typical for a
-- fresh sync from Calibre / Syncthing) have no cached title or cover; the
-- shelf renders them with the filename + paper-tone fallback. Trigger BIM's
-- background extraction subprocess for those files so the next render of the
-- bookshelf has proper covers + titles. We pass through the slot dimensions
-- as cover_specs so the cached cover thumbnail matches our display size.
--
-- Skips items where:
--   * BIM already has metadata (info.has_meta == "Y")
--   * BIM has tried max_extract_tries times and failed (info.in_progress >=
--     max). Those will keep their filename fallback indefinitely; no point
--     re-trying every render.
--   * The item has no filepath (folder records, empty slots).
--
-- Folder records carry their own first_book — we queue that too so a folder
-- whose representative book isn't indexed yet gets a real cover next render.
function BookshelfWidget:_kickOffMissingMetaExtraction(items, slot_w, slot_h, hero_w, hero_h)
    local ok, BIM = pcall(require, "bookinfomanager")
    if not ok or not BIM or not BIM.getBookInfo then return end
    local max_tries = BIM.max_extract_tries or 3
    local files = {}
    local seen  = {}
    -- Extract at hero-sized specs uniformly. BIM stores ONE bb per book,
    -- and the hero slot is bigger than the shelf slot — so caching at hero
    -- size keeps both paths sharp (shelf downscales cleanly; the existing
    -- spine_widget comment notes downscale is the corruption-free path).
    -- Caching at slot size and letting hero upscale leaves the hero
    -- pixelated for the previewed/last-read book even after re-extraction.
    local cover_specs = {
        max_cover_w = math.max(slot_w, hero_w or slot_w),
        max_cover_h = math.max(slot_h, hero_h or slot_h),
    }
    local function maybe_queue(fp)
        if not fp or seen[fp] then return end
        seen[fp] = true
        local info = BIM:getBookInfo(fp, false)
        local needs = false
        if not info then
            needs = true
        elseif info.has_meta == nil
                and (tonumber(info.in_progress) or 0) < max_tries then
            needs = true
        elseif info.cover_fetched == nil
                and (tonumber(info.in_progress) or 0) < max_tries then
            -- Metadata was extracted (e.g. by "Scan all library metadata")
            -- but no cover attempt has been made yet.
            needs = true
        elseif info.has_cover == "Y"
                and (tonumber(info.in_progress) or 0) < max_tries
                and BookshelfWidget._coverNeedsResize(info, cover_specs) then
            -- Cached cover was extracted at a smaller spec than the current
            -- slot needs (e.g. the user previously browsed in FM list-mode,
            -- which extracts at ~30px wide; bookshelf wants ~150px). Re-queue
            -- so BIM's subprocess overwrites the row with a sharper thumbnail.
            -- The helper applies a tolerance band so we don't thrash on minor
            -- dimension changes — important since extraction is expensive.
            needs = true
        end
        if needs then
            files[#files + 1] = {
                filepath    = fp,
                cover_specs = cover_specs,
            }
        end
    end
    for _i, item in ipairs(items or {}) do
        if item then
            -- Flat-book items (Recent / Latest / drilldown) carry filepath.
            maybe_queue(item.filepath)
            -- Folder items (Home chip drilldown) carry first_book.
            if item.first_book then
                maybe_queue(item.first_book.filepath)
            end
            -- Group items (series / authors / genres / tags) carry a books
            -- array. series_stack renders books[1] as the front cover plus
            -- books[2..3] peeking out behind — queue all three so the
            -- visible stack is sharp end-to-end. Capped at 3 to keep the
            -- queue size proportional to what's actually painted.
            if item.books then
                for i = 1, math.min(3, #item.books) do
                    local b = item.books[i]
                    if b then maybe_queue(b.filepath) end
                end
            end
        end
    end
    -- Hero book (preview / lastfile) may not appear in the visible shelf
    -- items — e.g. series drilldown shows other titles in the series while
    -- the hero stays on the user's currently-reading book. Queue it
    -- explicitly so its cover gets the hero-sized extraction.
    local hero_fp
    if self._preview_book and self._preview_book.filepath then
        hero_fp = self._preview_book.filepath
    else
        local cur = Repo.getCurrent and Repo.getCurrent()
        hero_fp = cur and cur.filepath
    end
    if hero_fp then maybe_queue(hero_fp) end
    logger.dbg(string.format("[bookshelf perf] _kickOffMeta: queued=%d displayed=%d",
        #files, #(items or {})))
    if #files > 0 then
        UIManager:nextTick(function()
            -- If CoverBrowser already has a background job running, don't
            -- interrupt it (terminateBackgroundJobs + re-fork is what causes
            -- the "Start-up of background extraction job failed" toast when
            -- the killed process is still in the table). Schedule a retry
            -- instead; the poll below catches covers whenever they appear.
            if BIM:isExtractingInBackground() then
                UIManager:scheduleIn(BIM_POLL_INTERVAL_S, function()
                    pcall(function() BIM:extractInBackground(files) end)
                end)
            else
                pcall(function() BIM:extractInBackground(files) end)
            end
        end)
    end
    self:_armExtractionPoll(files)
end

-- _armExtractionPoll(files): start a polling loop that watches BIM for
-- the queued filepaths and refreshes the shelf when their metadata
-- appears. Polls every BIM_POLL_INTERVAL_S seconds for up to
-- BIM_POLL_MAX_ATTEMPTS attempts (≈ 60s) — the typical extraction
-- subprocess completes well within that window. Cancels any earlier
-- polling timer so consecutive renders don't stack timers.
function BookshelfWidget:_armExtractionPoll(pending_files)
    if self._bim_poll_fn then
        UIManager:unschedule(self._bim_poll_fn)
        self._bim_poll_fn = nil
    end
    if not pending_files or #pending_files == 0 then
        self._bim_poll_files = nil
        return
    end
    self._bim_poll_files    = pending_files
    self._bim_poll_attempts = 0
    self:_scheduleExtractionPoll()
end

function BookshelfWidget:_scheduleExtractionPoll()
    if not self._bim_poll_files then return end
    if self._bim_poll_attempts >= BIM_POLL_MAX_ATTEMPTS then
        self._bim_poll_files = nil
        return
    end
    self._bim_poll_attempts = self._bim_poll_attempts + 1
    self._bim_poll_fn = function() self:_pollExtraction() end
    UIManager:scheduleIn(BIM_POLL_INTERVAL_S, self._bim_poll_fn)
end

function BookshelfWidget:_pollExtraction()
    self._bim_poll_fn = nil
    local files = self._bim_poll_files
    if not files or #files == 0 then
        return
    end
    local poll_t0 = os.time()
    local ok, BIM = pcall(require, "bookinfomanager")
    if not ok or not BIM or not BIM.getBookInfo then
        self._bim_poll_files = nil
        return
    end
    local max_tries = BIM.max_extract_tries or 3
    local ready_paths   = {}
    local still_pending = {}
    for _i, f in ipairs(files) do
        local info = BIM:getBookInfo(f.filepath, false)
        local inprog = tonumber(info and info.in_progress) or 0
        local meta_ready = info and info.has_meta == "Y"
        -- Cover-readiness check: matters for *re-extractions*. A pre-existing
        -- row already has has_meta=Y, so the prior poll would flag it done
        -- the instant we polled — before the subprocess had actually
        -- overwritten the bb with a sharper one. We use the same tolerance
        -- helper as the queue gate so the poll considers it done as soon as
        -- the new bb lands within the band we'd have stopped queueing at.
        local cover_ready = true
        if f.cover_specs then
            -- File was queued specifically for cover extraction. Don't
            -- consider it done until BIM has actually attempted the cover
            -- (cover_fetched = "Y"). Without this, metadata-scanned books
            -- (has_meta="Y", cover_fetched=nil) are immediately flagged done,
            -- which triggers _swapShelvesInPlace → _kickOff → kills the
            -- running BIM subprocess before it finishes the queue.
            if not info or info.cover_fetched ~= "Y" then
                cover_ready = false
            elseif info.has_cover == "Y" then
                cover_ready = not BookshelfWidget._coverNeedsResize(info, f.cover_specs)
            end
        end
        if meta_ready and inprog == 0 and cover_ready then
            ready_paths[f.filepath] = true
        elseif info and inprog >= max_tries then
            -- BIM gave up on this file; stop watching it.
        else
            still_pending[#still_pending + 1] = f
        end
    end
    self._bim_poll_files = #still_pending > 0 and still_pending or nil
    if next(ready_paths) and self._inner_vgroup and self._shelf_dims then
        -- _swapShelvesInPlace re-fetches Book records (which re-query
        -- BIM) and re-arms polling for whatever is still missing.
        self:_swapShelvesInPlace()
        -- Only swap the hero if its specific book was in the just-ready
        -- set. In expanded mode the "hero slot" is the static status strip
        -- (time/battery), which doesn't depend on book covers, so skip
        -- entirely. In collapsed mode, an unrelated grid book finishing
        -- extraction shouldn't trigger a hero rebuild — that was the
        -- bleed-through bug where _swapHeroInPlace slotted a tall
        -- HeroCard into the thin-strip slot during expanded mode, and
        -- also wasteful in collapsed mode (16 grid covers loading meant
        -- ~16 hero rebuilds for nothing).
        if not self._expanded
                and self._hero_parent and self._hero_dims then
            local hero_fp
            if self._preview_book then
                hero_fp = self._preview_book.filepath
            else
                local cur = Repo.getCurrent and Repo.getCurrent()
                hero_fp = cur and cur.filepath
            end
            if hero_fp and ready_paths[hero_fp] then
                self:_swapHeroInPlace()
            end
        end
        return
    end
    local poll_t1 = os.time()
    if self._bim_poll_files then
        self:_scheduleExtractionPoll()
    end
end

-- ─── Data helpers ─────────────────────────────────────────────────────────────

-- _fetchChipItems(n)
-- Returns up to n items for the current chip (or the expanded-series flat list).
function BookshelfWidget:_fetchChipItems(n)
    -- Drill-down: when the path tip is a series, show that series' books
    -- as flat spine widgets. Rebuild from filepaths so each render gets
    -- a fresh cover_bb — the cached Book objects on .books had their
    -- bbs freed by the prior SeriesStack render (image_disposable=true
    -- on the shelf path), and reusing them would dereference freed
    -- memory and SEGV.
    local tip = self._drilldown_path[#self._drilldown_path]
    -- Search mode: emit all matching tiles in order (folders -> authors ->
    -- series -> genres -> books). Search results are an exploratory
    -- "everything we found that matches" view, decoupled from which chips
    -- the user has enabled -- a user who hid the Authors tab can still
    -- jump to an author from search results without first re-enabling it.
    --
    -- Each render re-hydrates from identifiers stored in the payload --
    -- buildBookMeta / findGroup return records with fresh cover_bbs. The
    -- payload itself never holds hydrated records because ImageWidget
    -- frees cover_bb after first paint; subsequent re-renders (e.g.
    -- backing out of a drilled-into author) would read freed memory and
    -- the search result covers would corrupt (memory feedback:
    -- feedback_image_disposable_shared_book).
    if tip and tip.kind == "search" then
        local fresh = {}
        for _i, f in ipairs(tip.payload.folders or {}) do
            fresh[#fresh + 1] = {
                kind       = "folder",
                path       = f.path,
                label      = f.label,
                first_book = f.first_book_fp and Repo.buildBookMeta(f.first_book_fp),
            }
        end
        for _i, name in ipairs(tip.payload.author_names or {}) do
            local g = Repo.findGroup("author", name)
            if g then fresh[#fresh + 1] = g end
        end
        for _i, name in ipairs(tip.payload.series_names or {}) do
            local g = Repo.findGroup("series", name)
            if g then fresh[#fresh + 1] = g end
        end
        for _i, name in ipairs(tip.payload.genre_names or {}) do
            local g = Repo.findGroup("genre", name)
            if g then fresh[#fresh + 1] = g end
        end
        for _i, fp in ipairs(tip.payload.book_fps or {}) do
            local b = Repo.buildBookMeta(fp)
            if b then fresh[#fresh + 1] = b end
        end
        return fresh
    end
    -- Drill into a group (series / author / genre / tag): build Book records
    -- only for the visible page slice. Previously this iterated every book in
    -- the group and called Repo.buildBookMeta — which decompresses a cover
    -- BlitBuffer per book — meaning a 700+ book genre held 700 covers in
    -- memory simultaneously and OOM-killed KOReader on Kindle Color
    -- (issue #17). With offset+limit applied here, only the current page's
    -- 8-16 covers are materialised and total is returned so the caller's
    -- _total_hint path takes over for pagination.
    if tip and (tip.kind == "series" or tip.kind == "author"
            or tip.kind == "genre" or tip.kind == "tag"
            or tip.kind == "format" or tip.kind == "rating") then
        local books = tip.payload.books or {}
        local total = #books
        -- Cursor-based: offset is 0-based, cursor is 1-based. Clamp upstream
        -- in _rebuild keeps cursor within range; defensive guard here too.
        local offset = math.max(0, (self._cursor or 1) - 1)
        local stop = math.min(offset + self:_viewSize(), total)
        local fresh = {}
        for i = offset + 1, stop do
            local b = books[i]
            local nb = b.filepath and Repo.buildBookMeta(b.filepath) or b
            fresh[#fresh + 1] = nb
        end
        return fresh, total
    end
    -- For the all-chip and folder drill-down, fetch only the current
    -- visible window and return the total count as a second value.
    -- Cursor model: offset = cursor - 1 (cursor is 1-based, offset is
    -- 0-based). Limit = view size for the current mode (8 standard
    -- collapsed, 12 expanded, etc) so a single fetch covers the page.
    local offset    = math.max(0, (self._cursor or 1) - 1)
    local LIMIT     = self:_viewSize()
    local TabModel  = require("lib/bookshelf_tab_model")
    local tab       = TabModel.getById(self.chip)
    if tip and tip.kind == "folder" then
        -- Drilldown inheritance: the chip's sort_priority levels 2+ drive
        -- the order of books inside the drilled-into folder, mirroring how
        -- _applyWithinGroupSort treats group-source drilldowns. Level 1 was
        -- used at the parent view; levels 2+ apply within. Folder cards at
        -- this level still sort by level-1 key (typically filename), since
        -- SortEngine's filename comparator falls back to a.name for lfs
        -- entries -- so passing the full sp also works. Match the group-
        -- source convention and pass sp[2..#] for "within-folder" semantics.
        local within
        local sp = tab and tab.sort_priority
        if sp and #sp >= 2 then
            within = {}
            for i = 2, #sp do within[#within + 1] = sp[i] end
        end
        return Repo.getAll(tip.payload.path, LIMIT, offset, within)
    end
    if tab then
        return Repo.getBySource(tab.source, tab.filter, tab.sort_priority, offset, LIMIT)
    end
    return Repo.getBySource({ kind = self.chip }, nil, nil, offset, LIMIT)
end

-- _chipLabel()  — human-readable shelf heading for the active chip.
function BookshelfWidget:_chipLabel()
    local tip = self._drilldown_path[#self._drilldown_path]
    if tip then
        return tip.label or "Drill-down"
    end
    local TabModel = require("lib/bookshelf_tab_model")
    local tab = TabModel.getById(self.chip)
    return (tab and tab.label) or self.chip
end

-- ─── Device state ─────────────────────────────────────────────────────────────

-- Per-rebuild device state cache. Hardware/sysfs reads (PowerD frontlight,
-- isCharging, /proc/self/status) fire on every hero build and every preview
-- tap — way faster than the user can perceive a stale clock or battery
-- digit. The TTL caps how often we touch hardware; a 2s window is short
-- enough that the clock minute and battery percent stay current.
local _device_state_cache = nil
local _device_state_expires_at = 0
local DEVICE_STATE_TTL = 2  -- seconds

function BookshelfWidget:_buildDeviceState()
    local now = os.time()
    if _device_state_cache and _device_state_expires_at > now then
        -- Mutate `now` in the returned table so token rendering sees the
        -- current second; everything else (hardware reads) is fine to keep.
        _device_state_cache.now = now
        return _device_state_cache
    end

    local ok_pd, PowerD = pcall(function()
        return require("device"):getPowerDevice()
    end)
    local ok_nm, NetMgr = pcall(require, "ui/network/manager")
    local light, light_pct, warmth
    if ok_pd and PowerD then
        if PowerD.frontlightIntensity then
            local ok, v = pcall(function() return PowerD:frontlightIntensity() end)
            if ok then light = v end
        end
        -- Kindle PW5 frontlight maxes out at 24, Kobo varies. Mirror
        -- bookends's normalisation so users get a familiar 0–100 scale
        -- via %light_pct (the raw %light is still available).
        if light and PowerD.fl_max and PowerD.fl_max > 0 then
            light_pct = math.floor(light / PowerD.fl_max * 100 + 0.5)
        end
        if PowerD.frontlightWarmth then
            local ok, v = pcall(function() return PowerD:frontlightWarmth() end)
            if ok then warmth = v end
        end
    end
    -- Memory stats. util.calcFreeMem returns (free_bytes, total_bytes).
    -- Our process RSS comes from /proc/self/status on Linux/Kindle.
    local mem_pct, ram_mib
    local ok_util, util = pcall(require, "util")
    if ok_util and util and util.calcFreeMem then
        local free, total = util.calcFreeMem()
        if free and total and total > 0 then
            mem_pct = math.floor((1 - free / total) * 100 + 0.5)
        end
    end
    -- Single read + one match instead of fh:lines() (which allocates a
    -- string per line and walks ~25 lines before VmRSS).
    local fh = io.open("/proc/self/status", "r")
    if fh then
        local content = fh:read("*a") or ""
        fh:close()
        local kb = content:match("VmRSS:%s+(%d+)%s+kB")
        if kb then ram_mib = math.floor(tonumber(kb) / 1024 + 0.5) end
    end
    local disk_free
    if ok_util and util and util.diskUsage then
        local ok_dev, Device = pcall(require, "device")
        if ok_dev and Device then
            local drive = Device.home_dir or "/"
            local ok_du, usage = pcall(util.diskUsage, drive)
            if ok_du and usage and type(usage.available) == "number" and usage.available > 0 then
                disk_free = string.format("%.1fG", usage.available / 1024 / 1024 / 1024)
            end
        end
    end
    _device_state_cache = {
        now      = now,
        batt     = (ok_pd and PowerD and PowerD.getCapacity)
                       and PowerD:getCapacity() or nil,
        charging = (ok_pd and PowerD and PowerD.isCharging)
                       and PowerD:isCharging() or false,
        wifi     = (ok_nm and NetMgr and NetMgr.isWifiOn and NetMgr:isWifiOn())
                       and "on" or "off",
        light    = light,
        light_pct= light_pct,
        warmth   = warmth,
        mem      = mem_pct,
        ram_mib  = ram_mib,
        disk_free= disk_free,
    }
    _device_state_expires_at = now + DEVICE_STATE_TTL
    return _device_state_cache
end

-- ─── Navigation ───────────────────────────────────────────────────────────────

-- _openBook(book)  — open ReaderUI for the given book WITHOUT closing
-- the home screen. The Reader is shown on top in UIManager's stack;
-- when the Reader closes, Bookshelf is exposed automatically with no
-- intermediate FileManager flash. (Closing Bookshelf first leaves
-- FileManager visible for one paint cycle before the close-document
-- handler shows a fresh Bookshelf instance back on top.)
function BookshelfWidget:_openBook(book)
    if not book or not book.filepath then return end
    -- Stale records (Send-to-Kindle moved/removed the file after BIM cached
    -- the path) crash KOReader's filemanagerbookinfo:show via lfs.attributes
    -- on nil. ReaderUI:showReader nil-checks itself, but presenting a "file
    -- missing" toast here is friendlier than its silent no-op.
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(book.filepath, "mode") ~= "file" then
        UIManager:show(require("ui/widget/infomessage"):new{
            text    = _("File no longer exists. The bookshelf entry is stale."),
            timeout = 3,
        })
        return
    end
    -- Preserve self.chip / self.page / self._drilldown_path / self._preview_book
    -- across the read so closing the book lands the user back where they were.
    -- Suspend the status timer + drop any pending debounced repaint
    -- before the reader takes over. Keeping the minute heartbeat alive
    -- under the reader is wasted Lua wakeups — battery matters most
    -- during a long read. Bookshelf:show() re-arms us when the user
    -- closes the book.
    -- Save rotation so we can restore portrait orientation on return — the
    -- reader may have been opened in a different rotation (e.g. upside-down
    -- on Kobo) and KOReader leaves the rotation active when it closes.
    self._pre_read_rotation = Screen:getRotationMode()
    self:_stopStatusTimer()
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(book.filepath)
end

-- _buildHero — constructs a HeroCard reflecting current preview / lastfile.
-- Shared between the full _rebuild path and the _previewBook fast path so
-- both produce structurally-identical heroes.
--
-- Cover: HeroCard relies on book.cover_bb (the BIM thumbnail) via SpineWidget's
-- cover_fill + bb:scale upscale path. The Lua-side bb:scale is Kindle-safe
-- (sidesteps MuPDF's broken upscaler) and the slight nearest-neighbour
-- blockiness from a ~1.3× upscale is invisible at hero size on e-ink. We
-- previously opened the document fresh for a high-res publisher cover, but
-- that froze the UI for several seconds on fat CBRs and the visual gain
-- wasn't worth it.
function BookshelfWidget:_buildHero(content_w, hero_cover_w, hero_cover_h, hero_h, PAD)
    local _perf_t0 = _gettime()
    local current
    if self._preview_book and self._preview_book.filepath then
        -- _rebuild's expanded-mode probe stashed a freshly-built record
        -- for this same filepath -- reuse it instead of paying
        -- DocSettings:open() a second time. Cache is consumed
        -- destructively so a subsequent _swapHeroInPlace / previewBook
        -- rebuild gets fresh data.
        local cached = self._hero_book_cache
        if cached and cached.filepath == self._preview_book.filepath then
            current = cached
            self._hero_book_cache = nil
        else
            current = Repo.buildBook(self._preview_book.filepath) or self._preview_book
            self._hero_book_cache = nil
        end
        self._preview_book = current
    else
        current = Repo.getCurrent()
    end
    local _perf_t1 = _gettime()
    if current then Repo.enrichStats(current) end
    local _perf_t2 = _gettime()
    local device_state = self:_buildDeviceState()
    local _perf_t3 = _gettime()
    local card = HeroCard:new{
        book         = current,
        width        = content_w,
        height       = hero_h,
        cover_w      = hero_cover_w,
        cover_h      = hero_cover_h,
        pad          = PAD,
        device_state = device_state,
        -- The "Require double-tap to open" setting only gates SHELF
        -- cover taps. The hero cover already represents the user's
        -- current selection (preview or lastfile), so a double-tap
        -- requirement here was redundant -- it forced the user to
        -- "select" what was already selected. Single-tap commits.
        on_tap       = function(b) self:_openBook(b) end,
        on_hold      = function(b) self:_openBookMenu(b) end,
        on_description_tap = function(b) self:_showFullDescription(b) end,
        on_rating_change   = function(b, r) self:_setBookRating(b, r) end,
        is_selected  = (self._focus_zone == "hero"),
    }
    local _perf_t4 = _gettime()
    logger.dbg(string.format(
        "[bookshelf perf] _buildHero: buildBook=%.0fms stats=%.0fms"
        .. " device=%.0fms card=%.0fms TOTAL=%.0fms",
        (_perf_t1 - _perf_t0) * 1000,
        (_perf_t2 - _perf_t1) * 1000,
        (_perf_t3 - _perf_t2) * 1000,
        (_perf_t4 - _perf_t3) * 1000,
        (_perf_t4 - _perf_t0) * 1000))
    self._hero_card = card
    return card
end

-- _buildExpandedStrip(content_w, strip_h, PAD) — the thin replacement for
-- the hero card while in expanded mode. Renders the hero's status region
-- (time / battery / wifi / charging — same content the user sees at the
-- top of the right column in normal mode) full-width, with a hairline
-- separator and a small chevron-down "swipe to restore" indicator. Tapping
-- anywhere on the strip clears self._expanded and rebuilds (so the user
-- always has both a swipe-down and a tap-to-restore affordance).
--
-- Why a fresh widget instead of HeroCard.compact: HeroCard's geometry is
-- driven by cover_w / cover_h / right_w (cover-anchored), which makes a
-- thin status-only strip with NO cover awkward to express. A bespoke
-- builder is shorter and decouples the expanded-mode chrome from any
-- future hero-card changes.
function BookshelfWidget:_buildExpandedStrip(content_w, strip_h, PAD)
    local InputContainer = require("ui/widget/container/inputcontainer")
    local VerticalSpan   = require("ui/widget/verticalspan")

    local current = (self._preview_book and self._preview_book.filepath
                     and Repo.buildBook(self._preview_book.filepath))
                     or self._preview_book
                     or (Repo.getCurrent and Repo.getCurrent())

    -- No hairline: the chip strip below acts as the visual separator already.
    local status_row = HeroCard.buildStatusRow(current, self:_buildDeviceState(),
                                                content_w, false)

    -- Outer VerticalGroup pads the strip to strip_h (= the height the layout
    -- math reserved). Without this the strip's natural getSize would be just
    -- the status_row height, shifting the chip strip / shelves / pagination
    -- upward in expanded mode and breaking pagination's fixed y position.
    --
    -- Compute slack from status_row directly (NOT via outer:getSize()) — once
    -- VerticalGroup:getSize is called, it caches _size + _offsets. Adding
    -- children afterwards leaves _offsets stale and paintTo crashes when it
    -- indexes self._offsets[i] for the new child.
    local content_h = (status_row and status_row:getSize().h) or 0
    -- Honour the layout's reserved strip_h, but if the strip is bigger than
    -- needed (= bigger than status_row), this just lets the slack VerticalSpan
    -- fill it.
    local slack = strip_h - content_h
    local outer = VerticalGroup:new{ align = "left" }
    if status_row then outer[#outer + 1] = status_row end
    if slack > 0 then
        outer[#outer + 1] = VerticalSpan:new{ width = slack }
    end

    -- Wrap in InputContainer so a tap on the strip restores the full hero.
    -- IMPORTANT: each container that takes `dimen = ...` must get its OWN
    -- Geom — sharing a Geom between InputContainer + TopContainer caused
    -- both to mutate the SAME object's x/y on paint, doubling the offset
    -- on each level of nesting. (That bug shifted the status text down by
    -- ~28dp until we tracked it down via on-screen pixel scans.)
    local strip_dimen = Geom:new{ w = content_w, h = strip_h }
    local strip = InputContainer:new{ dimen = strip_dimen, outer }
    local bw   = self
    strip.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = strip_dimen } },
    }
    function strip:onTap()
        bw._expanded = false
        bw:_rebuild()
        UIManager:setDirty(bw, "ui")
        return true
    end
    return strip
end

-- _buildShelfRows — top + bottom shelf row from the page's items slice.
-- Extracted so _swapShelvesInPlace can construct them without re-running
-- the full _rebuild path (which would also rebuild hero + chips).
function BookshelfWidget:_buildShelfRows(items, content_w, shelf_h, PAD, n_rows)
    n_rows = n_rows or 2
    local bw = self
    -- Highlight the spine that matches the currently-previewed filepath
    -- so the user sees which book is showing in the hero. The row builder
    -- threads this down to each SpineWidget; nil means no spine is
    -- highlighted (no preview active).
    -- In expanded mode there's no visible hero, so the "selected"
    -- highlight (thick border) on a shelf cover would have no preview
    -- counterpart on screen — pass nil so nothing renders selected.
    -- _preview_book itself is preserved on self, so the highlight returns
    -- automatically when the user collapses back to 2-row.
    local selected_filepath
    if self._cursor_idx and self._page_items then
        local ci = self._page_items[self._cursor_idx]
        if ci then
            if     ci.filepath              then selected_filepath = ci.filepath
            elseif ci.first_book            then selected_filepath = ci.first_book.filepath
            elseif ci.books and ci.books[1] then selected_filepath = ci.books[1].filepath
            end
        end
    end
    if not selected_filepath and not self._expanded and self._preview_book then
        selected_filepath = self._preview_book.filepath
    end
    -- on_book_tap branches on _expanded so a tap on a shelf book in
    -- expanded mode auto-restores the full hero AND stages the tapped
    -- book as the preview — single tap collapses-back-and-shows-it. In
    -- normal mode it's the existing _previewBook (preview-only) behaviour.
    -- in_series: this page renders books that all belong to a single
    -- series. SpineWidget uses this to honour the "Within series folder"
    -- option of the Show series # setting. Two activation paths:
    --   1. The user has drilled into a series stack (drill tip kind ==
    --      "series").
    --   2. The current chip's source is a specific single series
    --      (kind == "single_series"), with no further drill on top
    --      (a deeper author/genre drill would mix series back in).
    local in_series = false
    local tip = self._drilldown_path and self._drilldown_path[#self._drilldown_path]
    if tip and tip.kind == "series" then
        in_series = true
    elseif (not tip) and self.chip then
        -- _buildShelfRows runs in its own scope; the TabModel local
        -- inside _rebuild isn't visible here. Require lazily so the
        -- dependency stays explicit and idempotent.
        local TabModel = require("lib/bookshelf_tab_model")
        for _i, c in ipairs(TabModel.getActive()) do
            if c.id == self.chip and c.source and c.source.kind == "single_series" then
                in_series = true
                break
            end
        end
    end

    local n_cols   = self:_nCols()
    local row_opts = {
        width             = content_w,
        height            = shelf_h,
        gap               = PAD,
        n_slots           = n_cols,
        selected_filepath = selected_filepath,
        show_titles       = self._expanded,
        in_series         = in_series,
        -- Expanded mode is "browse to open" — single tap opens the book.
        -- Normal mode is "preview, then commit" — tap shelf cover stages it
        -- in the hero, tap hero opens.
        on_book_tap       = function(b, tap_t)
            if bw._expanded then
                bw:_openBook(b)
            else
                bw:_previewBook(b, tap_t)
            end
        end,
        on_book_hold      = function(b) bw:_openBookMenu(b) end,
        on_series_tap     = function(s) bw:_expandSeries(s) end,
        on_series_hold    = function(s) bw:_openBookMenu(s) end,
        on_author_tap     = function(g) bw:_expandAuthor(g) end,
        on_author_hold    = function(_) end,
        on_genre_tap      = function(g) bw:_expandGenre(g) end,
        on_genre_hold     = function(_) end,
        on_tag_tap        = function(g) bw:_expandTag(g) end,
        on_tag_hold       = function(_) end,
        on_folder_tap     = function(f) bw:_expandFolder(f) end,
        on_folder_hold    = function(_) end,  -- no folder menu yet
    }
    local rows = {}
    for r = 1, n_rows do
        local row_items = {}
        for i = 1, n_cols do row_items[i] = items[(r - 1) * n_cols + i] end
        row_opts.items = row_items
        rows[r] = ShelfRow.new(row_opts)
    end
    return rows
end

-- _buildPaginationFooter — chevron nav (or series-back label when expanded).
-- Extracted so _swapShelvesInPlace can construct a fresh footer reflecting
-- the new page's button-enabled states.
function BookshelfWidget:_buildPaginationFooter(content_w, label_h, total_pages)
    local Button         = require("ui/widget/button")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan   = require("ui/widget/verticalspan")
    local bw = self
    local focused_btn = self._footer_cursor_btn   -- "prev", "next", or nil
    -- The footer is always pagination chevrons + page label, regardless
    -- of drill state. Earlier the footer doubled as a "← back to chips"
    -- label inside an expanded series, but that hijacked the only
    -- pagination affordance — series with >8 books couldn't be paged
    -- through. Back-out now lives in the chip strip's breadcrumb mode
    -- (tap the chip pill / a crumb), freeing this footer for chevrons
    -- everywhere.
    local chev_size    = Screen:scaleBySize(32)
    local focus_border = Screen:scaleBySize(4)
    local focus_radius = Screen:scaleBySize(4)
    -- Nav strip: 75% of content_w, centred. The outer 12.5% on each
    -- side is left clear for gestures.koplugin's bottom-corner gesture
    -- zones (night mode, brightness, etc.).
    --
    -- Within the strip, the 5 buttons take UNEQUAL slot widths so the
    -- first/last double-chevrons sit visually closer to their prev/next
    -- neighbours (the previous even 1/5 split spaced them at the strip
    -- edges with a noticeable gap). Splits sum to 1.00:
    --     first 12% | prev 24% | page 28% | next 24% | last 12%
    -- The whole strip is still tap-live -- the 12% first/last slots
    -- are wider than the chevron icon and accept taps across the slot.
    local nav_strip_w = math.floor(content_w * 0.75)
    local function slot(ratio) return math.floor(nav_strip_w * ratio) end
    local SLOT_EDGE   = 0.18  -- first / last
    local SLOT_STEP   = 0.18  -- prev  / next
    local SLOT_PAGE   = 0.28  -- centre "Page N of M"
    -- Bottom hit-zone extension. Each button's frame grows by this many
    -- pixels downward (via padding_bottom). The outer CenterContainer
    -- grows by the same amount so its centring math leaves the icons at
    -- the same y as before -- only the tap-receptive area extends. The
    -- extension reaches into what was previously outer_bot_PAD slack
    -- below the footer, taking back wasted pixels without colliding
    -- with anything below the screen edge.
    local hit_extension = Screen:scaleBySize(12)
    local function go_page(p)
        -- "Go to page N" callback used by the Page X of Y dialog. Page is
        -- a display concept; translate to a cursor snapped to that page's
        -- aligned start in the current view size.
        return function()
            local view = bw:_viewSize()
            bw._cursor = math.max(1, (p - 1) * view + 1)
            bw:_clampCursor()
            bw:_syncPageFromCursor()
            bw:_swapShelvesInPlace()
        end
    end
    local function step(direction)
        -- Chevron callback. Advance cursor by view-size in the given
        -- direction (+1 next, -1 prev). After a misaligned-cursor swipe-up,
        -- this still steps cleanly by the current view's full size.
        return function()
            bw:_advanceCursor(direction)
            bw:_syncPageFromCursor()
            bw:_swapShelvesInPlace()
        end
    end
    -- Long-press ±10: skip 10 pages instead of 1. Clamped via go_page()
    -- so we can't land outside [1, total_pages] regardless of how many
    -- holds the user fires. Returns nil rather than a no-op callback
    -- when the button is disabled so Button hides the long-press
    -- affordance too.
    local function skip(direction)
        local target = self.page + direction * 10
        if target < 1            then target = 1 end
        if target > total_pages  then target = total_pages end
        if target == self.page then return nil end
        return go_page(target)
    end
    -- margin/bordersize swap: every button allocates the same outer footprint
    -- (margin + bordersize = focus_border) so moving focus never shifts layout.
    -- Focused: bordersize = focus_border (visible thick ring), margin = 0.
    -- Unfocused: bordersize = 0 (invisible), margin = focus_border (slack space).
    local function bm(k) return (focused_btn == k) and 0           or focus_border end
    local function bs(k) return (focused_btn == k) and focus_border or 0           end
    local function br(k) return (focused_btn == k) and focus_radius or nil         end
    -- Cursor-based enable conditions. The display page (self.page) can
    -- show the same value for several cursor positions when the cursor
    -- is misaligned after a swipe-up. Gating chevron-enabled on cursor
    -- directly means books before/after the visible window are always
    -- reachable regardless of what the page indicator shows.
    local view_size_now    = self:_viewSize()
    local max_cursor_now   = self:_maxCursor()
    local can_step_back    = self._cursor > 1
    local can_step_forward = self._cursor < max_cursor_now
    local first = Button:new{
        icon = "chevron.first", icon_width = chev_size, icon_height = chev_size,
        width      = slot(SLOT_EDGE),
        callback   = go_page(1),
        margin     = bm("first"), bordersize = bs("first"), radius = br("first"),
        enabled    = can_step_back, show_parent = self,
    }
    local prev = Button:new{
        icon = "chevron.left",  icon_width = chev_size, icon_height = chev_size,
        width         = slot(SLOT_STEP),
        callback      = step(-1),
        hold_callback = skip(-1),
        margin        = bm("prev"), bordersize = bs("prev"), radius = br("prev"),
        enabled       = can_step_back, show_parent = self,
    }
    local page_text = Button:new{
        text = string.format("Page %d of %d", self.page, total_pages),
        text_font_size = 15,
        width      = slot(SLOT_PAGE),
        callback   = function() bw:_openPageJump() end,
        margin     = bm("page"), bordersize = bs("page"), radius = br("page"),
        show_parent = self,
    }
    self._page_text_button = page_text
    local next_btn = Button:new{
        icon = "chevron.right", icon_width = chev_size, icon_height = chev_size,
        width         = slot(SLOT_STEP),
        callback      = step(1),
        hold_callback = skip(1),
        margin        = bm("next"), bordersize = bs("next"), radius = br("next"),
        enabled       = can_step_forward, show_parent = self,
    }
    local last = Button:new{
        icon = "chevron.last", icon_width = chev_size, icon_height = chev_size,
        width      = slot(SLOT_EDGE),
        callback   = go_page(total_pages),
        margin     = bm("last"), bordersize = bs("last"), radius = br("last"),
        enabled    = can_step_forward, show_parent = self,
    }
    -- Extend each button's hit zone downward by hit_extension. Two
    -- mutations are needed:
    --
    --   1. frame.padding_bottom: makes the rendered frame taller. The
    --      FrameContainer re-derives its outer size from padding on
    --      every paint, so this takes effect on first render.
    --
    --   2. b.dimen.h: Button captures dimen ONCE in init via
    --      `self.dimen = self.frame:getSize()`, and the Tap/Hold/
    --      HoldRelease GestureRanges all hold a reference to that
    --      same Geom object. Without bumping dimen.h, the rendered
    --      frame is taller than the gesture range -- hold gestures
    --      in the lower extension fall through to the next listener
    --      below us (e.g. SimpleUI's bottom-bar zone) instead of
    --      firing hold_callback. Mutating dimen.h propagates to the
    --      stored GestureRange.range via the shared reference.
    for _i, b in ipairs({first, prev, page_text, next_btn, last}) do
        if b.frame then
            b.frame.padding_bottom = (b.frame.padding_bottom or 0) + hit_extension
        end
        if b.dimen then
            b.dimen.h = b.dimen.h + hit_extension
        end
    end
    -- Pad the row to its ORIGINAL top offset (default_pad) so the icons
    -- stay at the same y they had before the hit-extension was added.
    -- Without this, CenterContainer's ignore_if_over="height" pins the
    -- (now-taller) row to the CC's top edge, shifting icons up by
    -- default_pad. The VerticalSpan re-introduces that pad above the row.
    local nav = HorizontalGroup:new{
        align = "center",
        first, prev, page_text, next_btn, last,
    }
    local stack = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.default },
        nav,
    }
    return CenterContainer:new{
        -- Outer dimen stays at the ORIGINAL footer height -- _rebuild
        -- reserves exactly this many pixels, shelves keep their full
        -- vertical space. The button frames' extra padding_bottom
        -- overflows downward into the outer_bot_PAD area below the
        -- footer; ignore_if_over="height" tells CC not to vertical-
        -- centre the taller content (which would shift icons up).
        dimen = Geom:new{
            w = content_w,
            h = chev_size + Size.padding.default * 2,
        },
        ignore_if_over = "height",
        stack,
    }
end

-- _totalPages — returns the cached total page count for the current shelf.
-- Updated by _rebuild (and its fast-path siblings) every time the shelf is
-- repainted, so it is always consistent with the current dataset size.
function BookshelfWidget:_totalPages()
    return self._total_pages or 1
end

-- _openPageJump — opens a numeric InputDialog so the user can type a page
-- number to jump to. Uses KOReader's standard InputDialog with input_type =
-- "number" so the on-screen keyboard shows the numeric keypad on touch
-- devices. The Go button validates the input is in [1, total_pages]; bad
-- input shows a brief InfoMessage and leaves the dialog open.
function BookshelfWidget:_openPageJump()
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    local bw          = self
    local total       = bw:_totalPages()
    local dialog
    dialog = InputDialog:new{
        title       = _("Go to page"),
        input       = tostring(bw.page),
        input_type  = "number",
        description = string.format(_("Page 1 to %d"), total),
        buttons = {
            {
                {
                    text     = _("Cancel"),
                    id       = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text             = _("Go"),
                    is_enter_default = true,
                    callback         = function()
                        local n = tonumber(dialog:getInputText())
                        if not n or n < 1 or n > total then
                            UIManager:show(InfoMessage:new{
                                text    = string.format(_("Page must be between 1 and %d"), total),
                                timeout = 2,
                            })
                            return
                        end
                        local view = bw:_viewSize()
                        bw._cursor = math.max(1, (math.floor(n) - 1) * view + 1)
                        bw:_clampCursor()
                        bw:_syncPageFromCursor()
                        UIManager:close(dialog)
                        bw:_swapShelvesInPlace()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- _swapShelvesInPlace — pagination fast-path. Rebuilds only the shelf rows
-- + footer, leaving hero + chips intact. Avoids redundant work (the chips
-- never change with self.page; the hero only changes with _preview_book)
-- AND avoids the use-after-free path where _buildHero rebuilds a SpineWidget
-- against a freed BIM bb on _preview_book.cover_bb.
function BookshelfWidget:_swapShelvesInPlace()
    local _perf_t0 = _gettime()
    if not self._inner_vgroup or not self._shelf_dims then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        return
    end
    -- Fast path only handles the 2-row (standard, non-expanded) layout.
    -- Expanded mode and tall screens use more rows; fall back to _rebuild.
    if self:_nShelves() ~= 2 then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        return
    end
    local d = self._shelf_dims
    local VIEW_SIZE = self:_viewSize()
    local MAX_FETCH = 400
    local all_items, _total_hint = self:_fetchChipItems(MAX_FETCH)
    all_items = all_items or {}
    local _perf_t1 = _gettime()
    logger.dbg(string.format("[bookshelf perf] _swapShelves: fetch=%.0fms items=%d chip=%s",
        (_perf_t1 - _perf_t0) * 1000, _total_hint or #all_items, self.chip))
    local total = _total_hint or #all_items
    local total_pages
    if total <= VIEW_SIZE then
        total_pages = 1
    else
        total_pages = math.ceil(total / VIEW_SIZE)
    end
    self._total_pages = total_pages
    self._total_items = total
    self:_clampCursor(total)
    self:_syncPageFromCursor()
    if total == 0 then
        -- Going to empty state needs a structural change (hero + chips +
        -- placeholder, no shelves) — fall back to full rebuild.
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        return
    end
    local items
    if _total_hint then
        items = all_items
    else
        local start_idx = self._cursor
        items = {}
        for i = 0, VIEW_SIZE - 1 do items[i + 1] = all_items[start_idx + i] end
    end

    self._page_items = items
    if self._cursor_idx then
        local last_real = 0
        for i = #items, 1, -1 do if items[i] then last_real = i; break end end
        local clamp_to = last_real > 0 and last_real or 1
        if self._cursor_idx > clamp_to then self._cursor_idx = clamp_to end
    end
    local rows = self:_buildShelfRows(items, d.content_w, d.shelf_h, d.PAD, 2)
    local row_top, row_bottom = rows[1], rows[2]
    local _perf_t2 = _gettime()
    logger.dbg(string.format("[bookshelf perf] _swapShelves: shelves=%.0fms",
        (_perf_t2 - _perf_t1) * 1000))
    local footer = self:_buildPaginationFooter(d.content_w, d.label_h, total_pages)

    -- Kick off BIM extraction for newly-paginated books that aren't
    -- cached yet. Same slot + hero dims as _rebuild's call so both
    -- consumers get a single cached cover sized for the bigger of the two.
    local n_slots = self:_nCols()
    local slot_w  = math.floor((d.content_w - d.PAD * (n_slots - 1)) / n_slots)
    local slot_h  = math.floor(slot_w * 1.5)
    self:_kickOffMissingMetaExtraction(items, slot_w, slot_h, d.hero_cover_w, d.hero_cover_h)

    local old_top    = self._inner_vgroup[d.shelf_top_idx]
    local old_bottom = self._inner_vgroup[d.shelf_bottom_idx]
    local old_footer = self._inner_vgroup[d.footer_idx]

    self._inner_vgroup[d.shelf_top_idx]    = row_top
    self._inner_vgroup[d.shelf_bottom_idx] = row_bottom
    self._inner_vgroup[d.footer_idx]       = footer

    if self._inner_vgroup.resetLayout then
        self._inner_vgroup:resetLayout()
    end
    UIManager:nextTick(function()
        for _i, w in ipairs({ old_top, old_bottom, old_footer }) do
            if w and w.free then pcall(function() w:free() end) end
        end
    end)
    logger.dbg(string.format("[bookshelf perf] _swapShelves: TOTAL=%.0fms page=%d/%d",
        (_gettime() - _perf_t0) * 1000, self.page, self._total_pages or 0))
    UIManager:setDirty(self, "ui")
    -- Pagination via _swapShelvesInPlace bypasses _rebuild's persist hook;
    -- repeat the save here so a forward/back swipe is enough to land back
    -- on the right page after a book read or KOReader restart.
    self:_persistNavState()
end

-- Walk a widget tree looking for the SpineWidget whose .book.filepath
-- matches `fp`. Returns (parent_container, index_in_parent, spine_widget)
-- so the caller can do `parent[idx] = new_slot`.
--
-- _inner_vgroup[shelf_idx] may be the row HorizontalGroup directly, OR a
-- CenterContainer wrapping it (kicks in when slot_w is shrunk to
-- preserve cover aspect — see lib/bookshelf_shelf_row.lua:298-305),
-- OR (expanded mode) the slot itself may be an InputContainer wrapping
-- VerticalGroup{ spine, title }. Descend up to 3 levels.
--
-- Shared by _repaintSelectionHighlight (preview-tap highlight swap) and
-- _refreshSpineInPlace (post-read refresh of the closed book's spine).
local function _descendFindSpine(node, fp, depth)
    if not node or depth > 3 then return nil, nil end
    for i, c in ipairs(node) do
        if c and c.book and c.book.filepath == fp then
            -- Found a direct SpineWidget child — return the container
            -- holding it (for slot replacement) and the index.
            return node, i, c
        end
    end
    -- No direct match — descend into children.
    for _i, c in ipairs(node) do
        if c then
            local parent, idx, spine = _descendFindSpine(c, fp, depth + 1)
            if parent then return parent, idx, spine end
        end
    end
    return nil, nil, nil
end

-- _repaintSelectionHighlight(old_fp, new_fp) — preview-tap fast path.
--
-- _swapShelvesInPlace was costing ~950ms per tap on a 329-item chip because
-- it re-runs _fetchChipItems (8 × Repo.buildBookMeta ≈ 120ms/book) just so
-- the selected-spine border can repaint. The on-screen shelves haven't
-- changed — only two slots' borders flip — so we rebuild those two slots
-- and leave the rest alone.
--
-- Limitations:
--   * SeriesStack slots ignored: their is_selected flag is also baked at
--     init time; if the changed selection happens to be the first book of
--     a visible series, the series border won't update until the next
--     _rebuild. Rare enough to defer.
--   * Falls back to _swapShelvesInPlace if both old + new are off the
--     current page (e.g. preview was set before pagination): without a
--     matching slot to swap, the visible state would be wrong.
function BookshelfWidget:_repaintSelectionHighlight(old_fp, new_fp)
    local _perf_t0 = _gettime()
    if not self._inner_vgroup or not self._shelf_dims then return end
    local d = self._shelf_dims
    local replaced = 0
    local union_dimen

    local function expand_union(g)
        if not g then return end
        if not union_dimen then
            union_dimen = g:copy()
            return
        end
        local x1 = math.min(union_dimen.x, g.x)
        local y1 = math.min(union_dimen.y, g.y)
        local x2 = math.max(union_dimen.x + union_dimen.w, g.x + g.w)
        local y2 = math.max(union_dimen.y + union_dimen.h, g.y + g.h)
        union_dimen.x, union_dimen.y = x1, y1
        union_dimen.w, union_dimen.h = x2 - x1, y2 - y1
    end

    local function find_and_swap(root, fp, want_selected)
        if not fp then return end
        local parent, idx, old_spine = _descendFindSpine(root, fp, 0)
        if not parent then return end
        local fresh = Repo.buildBookMeta(fp) or old_spine.book
        local new_slot = SpineWidget:new{
            book          = fresh,
            width         = old_spine.width,
            height        = old_spine.height,
            on_tap        = old_spine.on_tap,
            on_hold       = old_spine.on_hold,
            is_selected   = want_selected,
            show_progress = old_spine.show_progress,
            show_titles   = old_spine.show_titles,
            in_series     = old_spine.in_series,
        }
        expand_union(old_spine.dimen)
        parent[idx] = new_slot
        replaced = replaced + 1
        if parent.resetLayout then parent:resetLayout() end
        UIManager:nextTick(function()
            if old_spine and old_spine.free then
                pcall(function() old_spine:free() end)
            end
        end)
    end

    for _i, idx in ipairs({ d.shelf_top_idx, d.shelf_bottom_idx }) do
        local hg = self._inner_vgroup[idx]
        if hg then
            find_and_swap(hg, old_fp, false)
            find_and_swap(hg, new_fp, true)
            if hg.resetLayout then hg:resetLayout() end
        end
    end

    -- If neither old nor new slot was found on the visible shelves, the
    -- caller must still get the selection state to render somewhere — fall
    -- back to the heavier swap so the user isn't stuck looking at a stale
    -- highlight. (Happens when preview was set on a different page before
    -- the user paginated.)
    if replaced == 0 then
        logger.info("[bookshelf perf] _repaintHighlight: no slot match -> fallback _swapShelves")
        self:_swapShelvesInPlace()
        return
    end

    if union_dimen then
        -- BorderOverlay (the selection ring) paints OUTSIDE the spine's
        -- dimen by SELECTED_BORDER pixels on each side -- see
        -- bookshelf_spine_widget.lua:127, which calls paintRoundedRect
        -- at (x - t, y - t) with size (w + 2t, h + 2t). union_dimen is
        -- built from old_spine.dimen which only covers the card area,
        -- so without this pad the OLD selection ring leaves an outer
        -- band un-refreshed and the deselected slot shows a partial
        -- border ghost. SELECTED_BORDER = SHADOW_OFFSET; mirroring the
        -- constant inline keeps spine_widget's module-locals private.
        local PAD = Screen:scaleBySize(4)
        union_dimen.x = union_dimen.x - PAD
        union_dimen.y = union_dimen.y - PAD
        union_dimen.w = union_dimen.w + 2 * PAD
        union_dimen.h = union_dimen.h + 2 * PAD
        UIManager:setDirty(self, function() return "ui", union_dimen end)
    else
        UIManager:setDirty(self, "ui")
    end
    logger.dbg(string.format(
        "[bookshelf perf] _repaintHighlight: replaced=%d TOTAL=%.0fms",
        replaced, (_gettime() - _perf_t0) * 1000))
end

-- _refreshSpineInPlace(fp) — rebuild a single spine in place, preserving
-- its current is_selected state. Used after a book is closed: the spine
-- needs to pick up the new percent_finished / status / progress glyph
-- without re-sorting the whole shelf. main.lua's onCloseDocument has
-- already invalidated _progress_cache for `fp`, so Repo.buildBookMeta
-- returns fresh state on the next CoverProgress.decide call.
--
-- No-op when the closed book isn't visible on either shelf row (off the
-- current page, drilled into a different group, etc). softRefresh's
-- gate / _swapShelvesInPlace handles those cases separately when the
-- sort order itself needs refreshing.
function BookshelfWidget:_refreshSpineInPlace(fp)
    if not fp or not self._inner_vgroup or not self._shelf_dims then return end
    local d = self._shelf_dims
    local replaced_dimen
    for _i, idx in ipairs({ d.shelf_top_idx, d.shelf_bottom_idx }) do
        local hg = self._inner_vgroup[idx]
        if hg then
            local parent, slot_idx, old_spine = _descendFindSpine(hg, fp, 0)
            if parent then
                local fresh = Repo.buildBookMeta(fp) or old_spine.book
                local new_slot = SpineWidget:new{
                    book          = fresh,
                    width         = old_spine.width,
                    height        = old_spine.height,
                    on_tap        = old_spine.on_tap,
                    on_hold       = old_spine.on_hold,
                    is_selected   = old_spine.is_selected or false,
                    show_progress = old_spine.show_progress,
                    show_titles   = old_spine.show_titles,
                    in_series     = old_spine.in_series,
                }
                if old_spine.dimen then
                    replaced_dimen = replaced_dimen and replaced_dimen
                                  or old_spine.dimen:copy()
                end
                parent[slot_idx] = new_slot
                if parent.resetLayout then parent:resetLayout() end
                UIManager:nextTick(function()
                    if old_spine and old_spine.free then
                        pcall(function() old_spine:free() end)
                    end
                end)
            end
        end
    end
    if replaced_dimen then
        UIManager:setDirty(self, function() return "ui", replaced_dimen end)
    end
end

-- softRefresh — lightweight return-to-bookshelf update. Splits the work
-- the warm-path show() previously did as a single _rebuild() into two
-- phases: the hero swap (synchronous, ~10ms — only depends on the current
-- book, which is the dominant thing that changed during the reader
-- session) and the shelf swap (deferred ~150ms, much heavier because of
-- the fetch + sort + BIM hydration).
--
-- The user-perceived effect is that bookshelf "reappears" instantly with
-- the existing shelves still on screen, then re-sorts a moment later. A
-- full _rebuild() would have held the EPDC on a black screen for the
-- whole fetch+sort cost.
--
-- The shelf swap is further gated on _needsReaderReturnShelfRefresh: most
-- chip+sort combos can't have their visible order changed by a single
-- book closing (e.g. All sorted by title), so for those the deferred
-- swap is skipped entirely. The just-closed book's spine briefly shows
-- a stale progress bar until the next page-flip / chip switch — a fair
-- trade for a snappier return.
--
-- Falls back to _rebuild() when the live tree can't be reused (cold widget,
-- expanded/tall layouts the in-place swap helpers don't handle).
function BookshelfWidget:softRefresh()
    local has_live_tree =
        self._inner_vgroup and self._shelf_dims
        and self._hero_parent and self._hero_dims
    -- Metadata edited while bookshelf was hidden (BookMetadataChanged
    -- handler in main.lua sets this flag): chip membership and sort order
    -- may both have shifted, but _needsReaderReturnShelfRefresh's gate is
    -- keyed on chip+sort assumptions about progress changes only, so it
    -- would otherwise skip a shelf refresh that's actually needed. Force
    -- the heavy path here, clearing the flag. (Issue #40.)
    if self._metadata_dirty_force_full_refresh then
        self._metadata_dirty_force_full_refresh = nil
        self:_rebuild()
        if self._startStatusTimer then self:_startStatusTimer() end
        UIManager:setDirty(self, "ui")
        return
    end
    -- Two-shelf gate: _swapShelvesInPlace's own fast-path bailout. Falling
    -- back to _rebuild here is cheaper than triggering it from the deferred
    -- callback after we've already painted a stale tree.
    if not has_live_tree or self:_nShelves() ~= 2 then
        self:_rebuild()
        if self._startStatusTimer then self:_startStatusTimer() end
        UIManager:setDirty(self, "ui")
        return
    end
    -- Right-column-only swap: the hero cover doesn't change on book close
    -- (same book is still "currently reading"), so rebuilding the cover is
    -- wasted work AND the broad setDirty(self, "ui") it triggers causes
    -- the full-screen e-ink flash users report in issue #35. The
    -- right-column path scopes setDirty to the changed rect only,
    -- removing the flash. Falls back to the whole-hero rebuild for
    -- expanded mode (where the hero is a different widget without
    -- replaceRightColumn) and book-switch cases.
    local hero = self._hero_card or (self._hero_parent and self._hero_parent[1])
    local right_col_ok = false
    if hero and hero.replaceRightColumn and not self._expanded then
        local Regions = require("lib/bookshelf_hero_regions")
        right_col_ok = self:_swapHeroRightColumnInPlace(Regions.read(), nil)
    end
    if not right_col_ok then
        -- Fallback: full hero rebuild with broad refresh.
        self:_swapHeroInPlace()
        UIManager:setDirty(self, "ui")
    end
    if self._startStatusTimer then self:_startStatusTimer() end
    -- Targeted spine refresh for the just-closed book. Runs even when the
    -- gate below skips the full shelf swap, so the closed book's progress
    -- bar / bookmark glyph picks up the new percent_finished without the
    -- user needing to swipe-down. onCloseDocument invalidated the progress
    -- cache for this fp already; buildBookMeta returns fresh data.
    local lastfile = Repo.getCurrent and Repo.getCurrent()
    if lastfile and lastfile.filepath then
        self:_refreshSpineInPlace(lastfile.filepath)
    end
    if not self:_needsReaderReturnShelfRefresh() then
        return
    end
    -- Cancel any earlier deferred shelf swap that hasn't fired (two quick
    -- reader open/close cycles); the later one supersedes.
    if self._soft_refresh_shelves_fn then
        UIManager:unschedule(self._soft_refresh_shelves_fn)
    end
    self._soft_refresh_shelves_fn = function()
        self._soft_refresh_shelves_fn = nil
        self:_swapShelvesInPlace()
    end
    UIManager:scheduleIn(0.15, self._soft_refresh_shelves_fn)
end

-- Does the current chip+sort combination depend on read state? Used by
-- softRefresh to decide whether closing a book could have reordered the
-- visible shelves. Chips driven purely by file metadata (title, mtime,
-- date_added, size) can't be affected; chips driven by read history /
-- progress can. Drilldown views are skipped — their group membership
-- can't change just because one of the group's books was read.
function BookshelfWidget:_needsReaderReturnShelfRefresh()
    if #self._drilldown_path > 0 then return false end
    local chip = self.chip
    if chip == "recent" then return true end
    if chip == "latest" then return false end
    if chip == "favorites" then
        return Repo.getSortKey("favorites") == "recently_read"
    end
    if chip == "all" then
        local sk = Repo.getSortKey("all")
        return sk == "last_read"
            or sk == "percent_unopened_first"
            or sk == "percent_unopened_last"
            or sk == "percent_natural"
    end
    if chip == "series" or chip == "authors"
       or chip == "genres" or chip == "tags" then
        return Repo.getSortKey(chip) == "latest_read"
    end
    -- Unknown chip: refresh to be safe.
    return true
end

-- Rebuild the hero from current state and swap it into _hero_parent[1].
-- Shared between _previewBook (synchronous swap on user tap) and the async
-- cover-load completion path. No-op if there's no live tree to swap into.
--
-- Must mirror _rebuild's expanded/collapsed dispatch — building a full
-- HeroCard while we're in expanded mode would slot a tall widget into a
-- slot sized for the thin expanded strip. The previous build's hero pixels
-- (cover image + title) then bleed through the chip strip area on the next
-- BIM-poll repaint, which is what the user sees as "the hero card reappears
-- behind the listing" after swiping up while covers are still loading.
function BookshelfWidget:_swapHeroInPlace()
    if not self._hero_parent or not self._hero_dims then return end
    local d = self._hero_dims
    local new_hero
    if self._expanded then
        new_hero = self:_buildExpandedStrip(d.content_w, d.hero_h, d.PAD)
    else
        new_hero = self:_buildHero(
            d.content_w, d.hero_cover_w, d.hero_cover_h, d.hero_h, d.PAD)
    end
    local old_hero = self._hero_parent[1]
    self._hero_parent[1] = new_hero
    if self._hero_parent.resetLayout then
        self._hero_parent:resetLayout()
    end
    if old_hero and old_hero.free then
        UIManager:nextTick(function()
            pcall(function() old_hero:free() end)
        end)
    end
    -- Scope the refresh to the hero's painted rect so the chip strip and
    -- shelves below don't flash. The peer right-column-only path is
    -- already scoped (issue #35); this one was missed. Falls back to a
    -- full-widget refresh when the old hero's painted dimen isn't
    -- available (e.g. first-paint races where the swap fires before the
    -- previous hero rendered).
    local scope = old_hero and old_hero.dimen
    if scope then
        UIManager:setDirty(self, function() return "ui", scope end)
    else
        UIManager:setDirty(self, "ui")
    end
end

-- Live-preview hook used by the hero line editor. Rebuilds only the
-- right OverlapGroup of the current HeroCard from the supplied regions
-- table (so we don't pay the cover BIM re-fetch on every keystroke).
-- Returns true if the swap happened, false if the live tree isn't there.
-- _swapHeroRightColumnInPlace(regions, region_hint)
-- region_hint (optional): "status" scopes the panel refresh to the
-- status strip only — used by the minute-tick + frontlight / charging /
-- wifi event paths so a clock update doesn't refresh the entire right
-- column. nil = whole right column (line-editor live preview, where any
-- region might have changed).
function BookshelfWidget:_swapHeroRightColumnInPlace(regions, region_hint)
    if not self._hero_parent then return false end
    local hero = self._hero_card or self._hero_parent[1]
    if not hero or not hero.replaceRightColumn then return false end
    local current = self._preview_book or (Repo.getCurrent and Repo.getCurrent()) or hero.book
    if current and Repo.enrichStats then
        Repo.enrichStats(current)
    end
    local ok, rect = hero:replaceRightColumn(regions, current,
        self:_buildDeviceState(), region_hint)
    -- "ui" rather than "fast": the size-nudge dialog (and any other style
    -- adjuster) sits OVER bookshelf, and a "fast" panel refresh is 1-bit
    -- monochrome — it strips greyscale across the whole screen including
    -- the dialog itself, until the next non-fast paint. "ui" is partial
    -- but greyscale-preserving; the small flicker per keystroke is a
    -- better trade than the dialog turning black-and-white.
    --
    -- Scoping setDirty to `rect` (when available) limits the e-ink panel
    -- update to the area that actually changed — for a clock tick that's
    -- ~30dp tall instead of the whole right column, so any overlay
    -- happens to be unaffected by the refresh entirely.
    if ok then UIManager:setDirty(self, "ui", rect) end
    return ok
end

-- _previewBook(book) — load a shelf book into the hero area as a preview.
-- The user reads the title/author/description there, then taps the hero
-- to actually open it. Cleared automatically on chip change; replaced by
-- another _previewBook call when the user taps a different shelf cover.
--
-- Fast path: previewing only changes the hero — chips, shelves, and the
-- pagination footer are unchanged. If a previous _rebuild has stashed the
-- hero's parent VerticalGroup, we build a new HeroCard, swap it into
-- index 1, defer the old hero's free, and dirty the screen. This avoids
-- 8 SpineWidget reconstructions plus the bb:scale work for any small
-- covers — perceptible on every shelf-cover tap.
function BookshelfWidget:_previewBook(book, tap_t)
    if not book or not book.filepath then return end
    local _perf_t0 = _gettime()
    local _perf_gap_ms = tap_t and ((_perf_t0 - tap_t) * 1000) or -1
    -- Tap-twice-to-open: a tap on the already-selected spine confirms
    -- the preview and opens the book. Composes with the spine highlight
    -- — first tap marks the spine with the thicker border, second tap
    -- on the same spine commits.
    if self._preview_book and self._preview_book.filepath == book.filepath then
        logger.info(string.format(
            "[bookshelf perf] _previewBook: branch=open-same tap_gap=%.0fms",
            _perf_gap_ms))
        self:_openBook(book)
        return
    end
    -- Snapshot the preview≠lastfile state BEFORE we update the preview
    -- so we can decide whether the chip strip needs rebuilding. The
    -- "currently reading" action chip's *selected* state flips between
    -- preview-matches-lastfile (selected) and preview-is-different
    -- (unselected); rendering that flip needs a chip-strip rebuild
    -- since _swapHeroInPlace only touches the hero card.
    local lastfile = Repo.getCurrent and Repo.getCurrent()
    local was_diff = self._preview_book and lastfile
                     and self._preview_book.filepath ~= lastfile.filepath
    -- Capture the previously-selected filepath BEFORE the assignment below
    -- so _repaintSelectionHighlight can deselect the old spine.
    local prior_preview_fp = self._preview_book and self._preview_book.filepath
    local _perf_t1 = _gettime()
    -- Shelf books are built via buildBookMeta (no DocSettings) for speed.
    -- The hero needs book_pct / page_num / last_xp to render the progress
    -- bar and token lines, so upgrade to the full Book record here. Single-
    -- book DocSettings read on each preview tap is fine.
    self._preview_book = Repo.buildBook(book.filepath) or book
    -- Stash the freshly-built record so the _swapHeroInPlace ->
    -- _buildHero call below doesn't pay DocSettings:open() a second time
    -- for the same filepath. _buildHero consumes destructively. Skipped
    -- when buildBook returned nil (fell back to the shelf record), since
    -- _buildHero still needs to attempt a real build in that case.
    if self._preview_book and self._preview_book.filepath == book.filepath
            and self._preview_book ~= book then
        self._hero_book_cache = self._preview_book
    end
    local _perf_t2 = _gettime()
    logger.dbg(string.format(
        "[bookshelf perf] _previewBook: buildBook=%.0fms",
        (_perf_t2 - _perf_t1) * 1000))
    local is_diff = self._preview_book and lastfile
                    and self._preview_book.filepath ~= lastfile.filepath

    -- Selection-state boundary crossed → full rebuild (cheap; chip strip
    -- + shelves + footer in one pass) so the "currently reading" action
    -- chip flips its inverted/normal styling in lockstep with the
    -- preview state.
    if was_diff ~= is_diff then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        logger.info(string.format(
            "[bookshelf perf] _previewBook: branch=rebuild tap_gap=%.0fms TOTAL=%.0fms",
            _perf_gap_ms, (_gettime() - _perf_t0) * 1000))
        return
    end

    if self._hero_parent and self._hero_dims then
        local _perf_t_hero = _gettime()
        self:_swapHeroInPlace()
        local _perf_t_after_hero = _gettime()
        -- Update the selected-spine highlight: deselect the prior slot
        -- (prior_preview_fp), select the newly-tapped slot. Only rebuilds
        -- the 1-2 SpineWidgets whose state actually changed, avoiding the
        -- ~950ms _swapShelvesInPlace fetch on heavy chips. Falls back to
        -- the full shelf swap if neither old nor new is on the current page.
        if self._inner_vgroup and self._shelf_dims then
            self:_repaintSelectionHighlight(
                prior_preview_fp, self._preview_book.filepath)
        end
        local _perf_t_end = _gettime()
        logger.info(string.format(
            "[bookshelf perf] _previewBook: branch=swap tap_gap=%.0fms"
            .. " hero=%.0fms shelves=%.0fms TOTAL=%.0fms",
            _perf_gap_ms,
            (_perf_t_after_hero - _perf_t_hero) * 1000,
            (_perf_t_end - _perf_t_after_hero) * 1000,
            (_perf_t_end - _perf_t0) * 1000))
        return
    end

    -- Cold path: no live tree to swap into yet. Full rebuild.
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    logger.info(string.format(
        "[bookshelf perf] _previewBook: branch=cold-rebuild tap_gap=%.0fms TOTAL=%.0fms",
        _perf_gap_ms, (_gettime() - _perf_t0) * 1000))
end

-- Cleanup hook: clears the plugin's tracked widget reference when this
-- BookshelfWidget instance is closed for any reason. main.lua wires the
-- callback in show().
function BookshelfWidget:onCloseWidget()
    self:_stopStatusTimer()
    if BookshelfWidget.live == self then BookshelfWidget.live = nil end
    if self._on_close_callback then self._on_close_callback() end
end

-- ─── Status-line auto-refresh ───────────────────────────────────────────────
-- Two refresh paths, both targeting the hero's right column (the cover
-- stays untouched):
--
--   1. A minute-aligned heartbeat for tokens that drift purely with
--      wall-clock time (clock, dates, time-left projections, battery %).
--   2. Event handlers for state that changes asynchronously (charging,
--      network, frontlight) — these get a 0.3s debounce so a slider drag
--      doesn't fire ten setDirty calls in a second.
--
-- Both paths gate on whether any *active* region template actually uses
-- a token from the relevant set. If your status line is e.g. just
-- `%title`, the minute heartbeat correctly stays silent — saves e-ink
-- ghost-refreshes and Lua wakeups.
--
-- The timer's callback is stored on self so UIManager:unschedule can
-- pull it out of the queue cleanly when the widget is closed or pushed
-- to the background by ReaderUI; not just bail on next fire (which
-- still costs a per-minute wakeup during a long read).

-- Tokens whose displayed value drifts with time alone — caught by the
-- minute heartbeat. Battery percent is here because the icon glyph
-- changes via Charging/NotCharging events but the numeric % only drifts
-- as time passes.
local TIMER_TOKENS = {
    "time", "time_12h", "time_24h",
    "date", "date_long", "date_numeric", "weekday", "weekday_short",
    "book_time_left", "book_read_time", "days_reading_book",
    "pages_per_day", "speed", "batt",
}
local FRONTLIGHT_TOKENS = { "light", "light_icon", "warmth" }
local BATTERY_TOKENS    = { "batt", "batt_icon" }
local WIFI_TOKENS       = { "wifi", "wifi_icon" }
local NIGHTMODE_TOKENS  = { "nightmode" }

-- Returns true iff any non-disabled region's template references a
-- token from `tokens`. Pattern matches "%name" + a non-identifier
-- boundary so "%light" doesn't accidentally fire on "%light_icon"
-- (the boundary check makes that a separate match the caller can
-- target precisely if needed).
function BookshelfWidget:_anyActiveRegionUses(tokens)
    local Regions = require("lib/bookshelf_hero_regions")
    local resolved = Regions.read()
    for _i, key in ipairs(Regions.ORDER) do
        local r = resolved[key]
        if r and not r.disabled and type(r.template) == "string" then
            for _i, name in ipairs(tokens) do
                -- "%name" followed by anything that isn't [A-Za-z0-9_]
                -- (or end-of-string). %% in a Lua pattern matches a
                -- literal %.
                if r.template:find("%%" .. name .. "[^%w_]")
                        or r.template:match("%%" .. name .. "$") then
                    return true
                end
            end
        end
    end
    return false
end

-- Repaint the right column iff any active region uses one of `tokens`.
-- Skipped silently when bookshelf is not the topmost visible widget
-- (line editor open, FM menu open, ReaderUI on top during a read).
-- Optional debounce coalesces rapid event bursts (slider drags).
function BookshelfWidget:_gatedRepaint(tokens, debounce)
    local function fire()
        self._gated_repaint_pending = nil
        if UIManager:getTopmostVisibleWidget() ~= self then return end
        local _hc = self._hero_card or (self._hero_parent and self._hero_parent[1])
        if not (_hc and _hc.replaceRightColumn) then return end
        if not self:_anyActiveRegionUses(tokens) then return end
        local Regions = require("lib/bookshelf_hero_regions")
        -- Every gated repaint here is driven by status-line state
        -- (clock tick / battery / wifi / brightness / nightmode) so the
        -- "status" hint scopes the panel refresh to just the status
        -- strip rather than the whole right column.
        self:_swapHeroRightColumnInPlace(Regions.read(), "status")
    end
    if debounce and debounce > 0 then
        if self._gated_repaint_pending then
            UIManager:unschedule(self._gated_repaint_pending)
        end
        self._gated_repaint_pending = fire
        UIManager:scheduleIn(debounce, fire)
    else
        UIManager:nextTick(fire)
    end
end

function BookshelfWidget:_startStatusTimer()
    if self._status_timer_func then return end -- already armed
    self._status_timer_func = function()
        -- Fire only if active templates actually need a time-driven repaint.
        self:_gatedRepaint(TIMER_TOKENS)
        -- Re-arm at the next minute boundary.
        if self._status_timer_func then
            local now_sec = os.date("*t").sec
            local delay = 60 - now_sec
            if delay <= 0 then delay = 60 end
            UIManager:scheduleIn(delay, self._status_timer_func)
        end
    end
    -- First tick aligns to the next minute boundary too.
    local now_sec = os.date("*t").sec
    local delay = 60 - now_sec
    if delay <= 0 then delay = 60 end
    UIManager:scheduleIn(delay, self._status_timer_func)
end

function BookshelfWidget:_stopStatusTimer()
    -- Same hook also cancels the BIM-extraction poll — no point watching
    -- BIM while the reader is foregrounded; Bookshelf:show will re-arm
    -- everything on the next render.
    if self._bim_poll_fn then
        UIManager:unschedule(self._bim_poll_fn)
        self._bim_poll_fn    = nil
        self._bim_poll_files = nil
    end
    if self._status_timer_func then
        UIManager:unschedule(self._status_timer_func)
        self._status_timer_func = nil
    end
    if self._gated_repaint_pending then
        UIManager:unschedule(self._gated_repaint_pending)
        self._gated_repaint_pending = nil
    end
    -- Cancel the 150ms deferred shelf swap too. _openBook calls this
    -- function before opening the reader; without the cancel, a
    -- softRefresh that scheduled _swapShelvesInPlace fires DURING the
    -- reader's startup paint and marks the bookshelf dirty under the
    -- reader -- wasted work plus a potential extra EPDC cycle while
    -- the reader is trying to claim the screen.
    if self._soft_refresh_shelves_fn then
        UIManager:unschedule(self._soft_refresh_shelves_fn)
        self._soft_refresh_shelves_fn = nil
    end
end

-- ─── Event hooks for non-time state changes ────────────────────────────────
-- KOReader broadcasts these via UIManager:broadcastEvent — they reach
-- widgets in the window stack including covered ones. We still gate on
-- the topmost check inside _gatedRepaint so a battery state change
-- during a read doesn't try to paint over the reader.

function BookshelfWidget:onFrontlightStateChanged()
    self:_gatedRepaint(FRONTLIGHT_TOKENS, 0.3)
end
function BookshelfWidget:onCharging()
    self:_gatedRepaint(BATTERY_TOKENS, 0.3)
end
function BookshelfWidget:onNotCharging()
    self:_gatedRepaint(BATTERY_TOKENS, 0.3)
end
function BookshelfWidget:onNetworkConnected()
    self:_gatedRepaint(WIFI_TOKENS, 0.3)
end
function BookshelfWidget:onNetworkDisconnected()
    self:_gatedRepaint(WIFI_TOKENS, 0.3)
end
-- KOReader broadcasts ToggleNightMode (no-arg toggle) AND SetNightMode
-- (pass true/false) — both routed to DeviceListener which actually flips
-- night_mode and dirty-marks "all" widgets. Bookshelf needs its own
-- repaint after the flip so the %nightmode glyph picks up the new
-- moon/sun state. Don't return true — we want DeviceListener's handler
-- to also run.
function BookshelfWidget:onToggleNightMode()
    self:_gatedRepaint(NIGHTMODE_TOKENS, 0.3)
end
function BookshelfWidget:onSetNightMode()
    self:_gatedRepaint(NIGHTMODE_TOKENS, 0.3)
end

-- Sleep / wake hooks: stop the timer entirely on suspend so the device
-- can sleep cleanly with no pending callbacks; re-arm + immediate tick
-- on wake so visible state catches up without the user waiting up to
-- a full minute.
function BookshelfWidget:onSuspend()
    self:_stopStatusTimer()
end

function BookshelfWidget:onResume()
    self:_startStatusTimer()
    -- Repaint immediately so post-wake clock + batt + wifi state shows
    -- without waiting for the next minute boundary. Hint "status" so
    -- the panel refresh stays scoped to the status strip.
    local _hc_resume = self._hero_card or (self._hero_parent and self._hero_parent[1])
    if UIManager:getTopmostVisibleWidget() == self
            and _hc_resume
            and _hc_resume.replaceRightColumn then
        local Regions = require("lib/bookshelf_hero_regions")
        self:_swapHeroRightColumnInPlace(Regions.read(), "status")
    end
end

-- Swipe gesture handlers. Layering by Y-position and state, most specific
-- first:
--   1. Swipe in the hero region → cycle previewed book on the shelf
--      (with wrap; pages flip automatically to keep the preview visible).
--   2. Else page through the chip's data (west = next page, east = previous).
--   3. East-swipe at page 1 + drilled-in → pop one drill level.
--   4. Edge swipe at top level + chip strip visible → cycle tabs (wrap).

-- _chipNeighbour(direction) -> chip key or nil
-- direction = +1 → next chip (with wrap), -1 → previous chip (with wrap).
-- Returns nil when there's only one (or zero) chips in the active list,
-- since cycling would no-op and we don't want a phantom rebuild.
function BookshelfWidget:_chipNeighbour(direction)
    local keys = self._active_chip_keys
    if not keys or #keys <= 1 then return nil end
    local idx
    for i, k in ipairs(keys) do
        if k == self.chip then idx = i; break end
    end
    if not idx then return keys[1] end
    -- Lua's % on negatives follows the sign of the divisor, so
    -- (idx-1 + direction) % n correctly wraps -1 → n-1.
    local n = #keys
    return keys[((idx - 1 + direction) % n) + 1]
end

-- _chipKeyNeighbour(key, direction) -> chip key or nil
-- Like _chipNeighbour but looks up an arbitrary key rather than self.chip.
-- Used by D-pad chip-row navigation where the focused key != the active chip.
-- Returns nil when there's only one (or zero) chips in the active list.
function BookshelfWidget:_chipKeyNeighbour(key, direction)
    local keys = self._dpad_chip_keys or self._active_chip_keys
    if not keys or #keys <= 1 then return nil end
    local idx
    for i, k in ipairs(keys) do
        if k == key then idx = i; break end
    end
    if not idx then return keys[1] end
    local n = #keys
    return keys[((idx - 1 + direction) % n) + 1]
end

function BookshelfWidget:_moveCursor(delta)
    local items = self._page_items
    if not items or #items == 0 then return true end
    local n_cols    = self:_nCols()
    local view_size = self:_nShelves() * n_cols
    local cur       = self._cursor_idx or 1
    local new_idx   = cur + delta

    if new_idx < 1 then
        if self.page > 1 then
            self:_advanceCursor(-1)
            self:_syncPageFromCursor()
            self._cursor_idx = view_size
            self:_swapShelvesInPlace()
        end
        return true
    end

    if new_idx > view_size then
        local total = self._total_pages or 1
        if self.page < total then
            self:_advanceCursor(1)
            self:_syncPageFromCursor()
            self._cursor_idx = 1
            self:_swapShelvesInPlace()
        end
        return true
    end

    if not items[new_idx] then return true end

    self._cursor_idx = new_idx
    self:_swapShelvesInPlace()
    return true
end

function BookshelfWidget:_swapFooterInPlace()
    if not self._inner_vgroup or not self._shelf_dims then return end
    local d      = self._shelf_dims
    local total  = self._total_pages or 1
    local footer = self:_buildPaginationFooter(d.content_w, d.label_h, total)
    local old    = self._inner_vgroup[d.footer_idx]
    self._inner_vgroup[d.footer_idx] = footer
    if self._inner_vgroup.resetLayout then self._inner_vgroup:resetLayout() end
    UIManager:nextTick(function()
        if old and old.free then pcall(function() old:free() end) end
    end)
    UIManager:setDirty(self, "ui")
end

function BookshelfWidget:onBSFocusUp()
    if not self._focus_zone then
        self._focus_zone = "grid"
        self._cursor_idx = 1
        self:_swapShelvesInPlace()
        return true
    end

    if self._focus_zone == "grid" then
        local n_cols = self:_nCols()
        if self._cursor_idx and self._cursor_idx <= n_cols then
            if not self._chip_bar_hidden then
                self._focus_zone = "chips"
                if #self._drilldown_path > 0 then
                    local zones = self._chip_bar and self._chip_bar._breadcrumb_zones
                    if zones and #zones > 0 then
                        self._crumb_cursor_depth = zones[#zones].depth
                        if self._chip_bar.focusCrumb then
                            self._chip_bar:focusCrumb(self._crumb_cursor_depth)
                        end
                    end
                else
                    self._chip_cursor_key = self.chip
                    if self._chip_bar and self._chip_bar.focusCursor then
                        self._chip_bar:focusCursor(self._chip_cursor_key)
                    end
                end
            elseif not self._expanded then
                self._focus_zone = "hero"
                self._cursor_idx = nil
                self:_swapShelvesInPlace()   -- clear cursor border from grid
                self:_swapHeroInPlace()
            end
            return true
        end
        return self:_moveCursor(-n_cols)
    end

    if self._focus_zone == "chips" then
        if not self._expanded then
            if self._chip_bar and self._chip_bar.focusCursor then
                self._chip_bar:focusCursor(nil)
            end
            if self._chip_bar and self._chip_bar.focusCrumb then
                self._chip_bar:focusCrumb(nil)
            end
            self._chip_cursor_key    = nil
            self._crumb_cursor_depth = nil
            self._focus_zone         = "hero"
            self:_swapHeroInPlace()
        end
        return true
    end

    if self._focus_zone == "footer" then
        local items    = self._page_items or {}
        local last_idx = 0
        for i = #items, 1, -1 do if items[i] then last_idx = i; break end end
        self._footer_cursor_btn = nil
        self._focus_zone        = "grid"
        self._cursor_idx        = last_idx > 0 and last_idx or 1
        self:_swapFooterInPlace()
        self:_swapShelvesInPlace()
        return true
    end

    return true
end

function BookshelfWidget:onBSFocusDown()
    if not self._focus_zone then
        self._focus_zone = "grid"
        self._cursor_idx = 1
        self:_swapShelvesInPlace()
        return true
    end

    if self._focus_zone == "hero" then
        self._focus_zone = nil
        self:_swapHeroInPlace()
        if not self._chip_bar_hidden then
            self._focus_zone = "chips"
            if #self._drilldown_path > 0 then
                local zones = self._chip_bar and self._chip_bar._breadcrumb_zones
                if zones and #zones > 0 then
                    self._crumb_cursor_depth = zones[#zones].depth
                    if self._chip_bar.focusCrumb then
                        self._chip_bar:focusCrumb(self._crumb_cursor_depth)
                    end
                end
            else
                self._chip_cursor_key = self.chip
                if self._chip_bar and self._chip_bar.focusCursor then
                    self._chip_bar:focusCursor(self._chip_cursor_key)
                end
            end
        else
            self._focus_zone = "grid"
            self._cursor_idx = 1
            self:_swapShelvesInPlace()
        end
        return true
    end

    if self._focus_zone == "chips" then
        if self._chip_bar and self._chip_bar.focusCursor then
            self._chip_bar:focusCursor(nil)
        end
        if self._chip_bar and self._chip_bar.focusCrumb then
            self._chip_bar:focusCrumb(nil)
        end
        self._chip_cursor_key    = nil
        self._crumb_cursor_depth = nil
        self._focus_zone         = "grid"
        self._cursor_idx         = 1
        self:_swapShelvesInPlace()
        return true
    end

    if self._focus_zone == "grid" then
        local n_shelves      = self:_nShelves()
        local n_cols         = self:_nCols()
        local last_row_start = (n_shelves - 1) * n_cols + 1
        if self._cursor_idx and self._cursor_idx >= last_row_start then
            local total = self._total_pages or 1
            if total <= 1 then return true end   -- single page: footer has nothing actionable
            self._footer_cursor_btn = "next"
            self._focus_zone        = "footer"
            self:_swapFooterInPlace()
            return true
        end
        return self:_moveCursor(n_cols)
    end

    return true
end

-- _footerNeighbour(cur, page, total, dir)
-- Returns the key of the nearest enabled footer button in direction dir
-- (dir=1 for right, dir=-1 for left), or nil if there is none.
local _FOOTER_ORDER = {"first","prev","page","next","last"}
local function _footerBtnEnabled(k, page, total)
    if k == "first" or k == "prev" then return page > 1 end
    if k == "page"                  then return true end
    -- "next" or "last"
    return page < total
end
local function _footerNeighbour(cur, page, total, dir)
    local cur_i = 0
    for i, k in ipairs(_FOOTER_ORDER) do
        if k == cur then cur_i = i; break end
    end
    if cur_i == 0 then return nil end
    local i = cur_i + dir
    while i >= 1 and i <= #_FOOTER_ORDER do
        local k = _FOOTER_ORDER[i]
        if _footerBtnEnabled(k, page, total) then return k end
        i = i + dir
    end
    return nil
end

function BookshelfWidget:onBSFocusLeft()
    if not self._focus_zone then
        self._focus_zone = "grid"
        self._cursor_idx = 1
        self:_swapShelvesInPlace()
        return true
    end

    if self._focus_zone == "grid" then
        return self:_moveCursor(-1)
    end

    if self._focus_zone == "chips" then
        if #self._drilldown_path > 0 then
            local zones = self._chip_bar and self._chip_bar._breadcrumb_zones
            if zones then
                local cur_i
                for i, z in ipairs(zones) do
                    if z.depth == self._crumb_cursor_depth then cur_i = i; break end
                end
                if cur_i and cur_i > 1 then
                    self._crumb_cursor_depth = zones[cur_i - 1].depth
                    if self._chip_bar.focusCrumb then
                        self._chip_bar:focusCrumb(self._crumb_cursor_depth)
                    end
                end
            end
            return true
        end
        local key = self:_chipKeyNeighbour(self._chip_cursor_key, -1)
        if key and key ~= self._chip_cursor_key then
            self._chip_cursor_key = key
            if self._chip_bar and self._chip_bar.focusCursor then
                self._chip_bar:focusCursor(key)
            end
        end
        return true
    end

    if self._focus_zone == "footer" then
        local total   = self._total_pages or 1
        local new_btn = _footerNeighbour(self._footer_cursor_btn, self.page, total, -1)
        if new_btn then
            self._footer_cursor_btn = new_btn
            self:_swapFooterInPlace()
        end
        return true
    end

    return true
end

function BookshelfWidget:onBSFocusRight()
    if not self._focus_zone then
        self._focus_zone = "grid"
        self._cursor_idx = 1
        self:_swapShelvesInPlace()
        return true
    end

    if self._focus_zone == "grid" then
        return self:_moveCursor(1)
    end

    if self._focus_zone == "chips" then
        if #self._drilldown_path > 0 then
            local zones = self._chip_bar and self._chip_bar._breadcrumb_zones
            if zones then
                local cur_i
                for i, z in ipairs(zones) do
                    if z.depth == self._crumb_cursor_depth then cur_i = i; break end
                end
                if cur_i and cur_i < #zones then
                    self._crumb_cursor_depth = zones[cur_i + 1].depth
                    if self._chip_bar.focusCrumb then
                        self._chip_bar:focusCrumb(self._crumb_cursor_depth)
                    end
                end
            end
            return true
        end
        local key = self:_chipKeyNeighbour(self._chip_cursor_key, 1)
        if key and key ~= self._chip_cursor_key then
            self._chip_cursor_key = key
            if self._chip_bar and self._chip_bar.focusCursor then
                self._chip_bar:focusCursor(key)
            end
        end
        return true
    end

    if self._focus_zone == "footer" then
        local total   = self._total_pages or 1
        local new_btn = _footerNeighbour(self._footer_cursor_btn, self.page, total, 1)
        if new_btn then
            self._footer_cursor_btn = new_btn
            self:_swapFooterInPlace()
        end
        return true
    end

    return true
end

function BookshelfWidget:onBSKbPress()
    if self._focus_zone == "hero" then
        local book = self._preview_book
            or (Repo.getCurrent and Repo.getCurrent())
        if book then
            self:_clearDpadFocus()
            self:_swapHeroInPlace()
            self:_openBook(book)
        end
        return true
    end

    if self._focus_zone == "chips" then
        if #self._drilldown_path > 0 then
            -- Breadcrumb mode: fire on_breadcrumb for the focused zone depth.
            local depth = self._crumb_cursor_depth
            if depth ~= nil and self._chip_bar and self._chip_bar.on_breadcrumb then
                self:_clearDpadFocus()
                self._chip_bar.on_breadcrumb(depth)
            end
            return true
        end
        local key = self._chip_cursor_key
        if key then
            if self._action_chip_keys and self._action_chip_keys[key] then
                -- Action chips (search, currently-reading): dispatch via
                -- on_change closure, same path as a touch tap.
                self:_clearDpadFocus()
                if self._chip_bar and self._chip_bar.on_change then
                    self._chip_bar.on_change(key)
                end
            else
                self:_clearDpadFocus()
                self:_setActiveChip(key)
                self._focus_zone = "grid"
                self._cursor_idx = 1
                self:_swapShelvesInPlace()
            end
        end
        return true
    end

    if self._focus_zone == "grid" then
        local idx  = self._cursor_idx
        local item = idx and self._page_items and self._page_items[idx]
        if not item then return true end
        if item.filepath then
            -- Preview on first press (updates hero); _previewBook opens on
            -- second press when the same book is already the preview.
            self:_previewBook(item)
        else
            -- Non-book items: drill in and clear focus (same as touch tap).
            self:_clearDpadFocus()
            if item.kind == "folder" then
                self:_expandFolder(item)
            elseif item.kind == "author" then
                self:_expandAuthor(item)
            elseif item.kind == "genre" then
                self:_expandGenre(item)
            elseif item.kind == "tag" then
                self:_expandTag(item)
            elseif item.kind == "format" then
                self:_expandFormat(item)
            elseif item.kind == "rating" then
                self:_expandRating(item)
            elseif item.books then
                self:_expandSeries(item)
            end
        end
        return true
    end

    if self._focus_zone == "footer" then
        local btn   = self._footer_cursor_btn
        local total = self._total_pages or 1
        if btn == "first" and self.page > 1 then
            self._cursor = 1
            self:_syncPageFromCursor()
            self._footer_cursor_btn = "next"
            self:_swapShelvesInPlace()
            self:_swapFooterInPlace()
        elseif btn == "prev" and self.page > 1 then
            self:_advanceCursor(-1)
            self:_syncPageFromCursor()
            if self.page <= 1 then self._footer_cursor_btn = "next" end
            self:_swapShelvesInPlace()
            self:_swapFooterInPlace()
        elseif btn == "next" and self.page < total then
            self:_advanceCursor(1)
            self:_syncPageFromCursor()
            if self.page >= total then self._footer_cursor_btn = "prev" end
            self:_swapShelvesInPlace()
            self:_swapFooterInPlace()
        elseif btn == "last" and self.page < total then
            self._cursor = self:_maxCursor()
            self:_syncPageFromCursor()
            self._footer_cursor_btn = "prev"
            self:_swapShelvesInPlace()
            self:_swapFooterInPlace()
        elseif btn == "page" then
            self:_clearDpadFocus()
            -- D-pad enter on focused page button opens page-jump dialog.
            -- Sort is now configured via the chip editor (long-press focused chip).
            self:_openPageJump()
        end
        return true
    end

    return true
end

-- _setActiveChip(key) — switch tabs as if the user tapped a chip.
-- Mirrors the on_change closure in _rebuild so swipe-cycling and tap
-- both produce identical state transitions.
function BookshelfWidget:_setActiveChip(key)
    if not key or key == self.chip then return end
    self:_clearDpadFocus()
    -- Pre-paint feedback on the destination chip: same affordance taps
    -- get, so a swipe-driven tab change feels just as responsive even
    -- when the new tab is slow to fetch (Genres / Authors). The strip
    -- handles the actual paint and clears itself when _rebuild swaps in
    -- a fresh strip below.
    if self._chip_bar and self._chip_bar.flashPending then
        self._chip_bar:flashPending(key)
    end
    self._drilldown_path = {}
    self.chip            = key
    self._cursor         = 1
    self:_syncPageFromCursor()
    BookshelfSettings.save("active_chip", key)
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- _isHeroSwipe(ges) -> bool
-- True when the swipe started inside the hero card's Y-band. Uses the
-- cached _hero_dims set during _rebuild — PAD is the leading
-- VerticalSpan, then hero_h tall.
function BookshelfWidget:_isHeroSwipe(ges)
    if not ges or not ges.pos or not self._hero_dims then return false end
    local widget_y = (self.dimen and self.dimen.y) or 0
    local local_y  = ges.pos.y - widget_y
    local d        = self._hero_dims
    return local_y >= d.PAD and local_y < (d.PAD + d.hero_h)
end

-- _isShelfSwipe(ges) -> bool
-- True when the swipe started in the shelf area (below the hero's
-- bottom edge). Used by refresh-on-swipe-down so the upper region
-- (top edge + chip strip + hero) stays clear for KOReader's
-- top-of-screen menu gesture and for the hero's own gesture surface.
function BookshelfWidget:_isShelfSwipe(ges)
    if not ges or not ges.pos or not self._hero_dims then return false end
    local widget_y = (self.dimen and self.dimen.y) or 0
    local local_y  = ges.pos.y - widget_y
    local d        = self._hero_dims
    return local_y >= (d.PAD + d.hero_h)
end

local TALL_RATIO = 0.65   -- width/height below which the screen is "phone-tall"

-- _isTallScreen() — true when the device aspect ratio is phone-like.
-- Computed from self.width / self.height which are fixed at init time.
function BookshelfWidget:_isTallScreen()
    return self.width / self.height < TALL_RATIO
end

-- paintTo override: if screen dimensions changed since the last _rebuild()
-- (e.g. the user rotated while the widget was already open), rebuild before
-- painting so the widget tree matches the new coordinate space. Without this,
-- UIManager calls paintTo in the new rotated frame while self.dimen still
-- holds the old portrait size, placing the bottom of the widget off-screen.
function BookshelfWidget:paintTo(bb, x, y)
    -- Skip painting when the seamless ReaderUI-reload "Opening file..."
    -- InfoMessage placeholder is on top of us. That placeholder is
    -- invisible (readerui.lua:670, invisible = seamless) and its refresh
    -- callback returns ("ui", self.movable.dimen) with movable.dimen ==
    -- nil (an invisible InfoMessage never paints, so its movable never
    -- receives a dimen). UIManager:_refresh treats nil as full-screen,
    -- so without this guard the entire shelf flashes for ~1s between
    -- the old reader page and the new ReaderUI repainting over us.
    --
    -- The check is narrow: only suppress when the invisible widget has
    -- a .text field, which is the CRE-reload InfoMessage's signature
    -- (it carries the localised "Opening file '%1'." string). KOReader
    -- v2026.03 on PW6 keeps a separate long-lived invisible widget on
    -- the stack that has no .text -- an earlier broader guard
    -- (top.invisible alone) suppressed every bookshelf paint on that
    -- device and left users staring at the FileManager forever. See #23.
    local stack = UIManager._window_stack
    local top = stack and stack[#stack] and stack[#stack].widget
    if top and top.invisible and top.text then return end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    if sw ~= self.width or sh ~= self.height then
        self:_rebuild()
    end
    InputContainer.paintTo(self, bb, x, y)
end

-- _isLandscape() — true when the device is rotated 90° or 270°.
-- Cached from Screen:getWidth() > Screen:getHeight() at the top of _rebuild();
-- Screen swaps those values on rotation, so the comparison is authoritative.
function BookshelfWidget:_isLandscape()
    return self._landscape == true
end

-- _layoutPrimitives() — pure, deterministic from self.width / self.height /
-- chip_font_scale. Returns the values the layout math depends on so both
-- _nShelves() (called from many code paths) and _rebuild() agree.
function BookshelfWidget:_layoutPrimitives()
    local pad_natural = math.floor(Size.padding.fullscreen * 2 * 0.8)
    local pad_capped  = math.floor(self.width * 0.03)
    local PAD         = math.min(pad_natural, pad_capped)
    local content_w   = self.width - PAD * 2
    local chip_font_scale = BookshelfSettings.read("chip_font_scale") or 100
    local chip_h = math.floor(Size.item.height_default * chip_font_scale / 100 + 0.5)
    local footer_h = Screen:scaleBySize(32) + Size.padding.default * 2
    return PAD, content_w, chip_h, footer_h
end

-- _baseShelves() — non-expanded shelf count. On tall screens the natural
-- "3 shelves" can squeeze the hero card below MIN_HERO_SHARE (the Boox
-- Palma's 0.5 aspect gets the hero down to ~17% with 3 rows); this loop
-- picks the largest n in [base, 1] that still leaves the hero its
-- proportional share. Pure function of self.width / self.height /
-- chip_font_scale, so callers don't need to be inside _rebuild.
-- Issue #36.
function BookshelfWidget:_baseShelves()
    if self:_isLandscape() then return 1 end
    local base = self:_isTallScreen() and 3 or 2

    local PAD, content_w, chip_h, footer_h = self:_layoutPrimitives()
    local n_cols = self:_nCols()
    local slot_w = math.floor((content_w - PAD * (n_cols - 1)) / n_cols)
    local slot_h = math.floor(slot_w * 1.5)
    for n = base, 1, -1 do
        local total_pad = PAD * 2 + PAD + PAD + n * PAD  -- outer + hero gap + chip gap + per-row
        local available = self.height - chip_h - footer_h - total_pad
        if available > 0 then
            local hero_h = self.height - n * slot_h - chip_h - footer_h - total_pad
            if hero_h >= math.floor(available * MIN_HERO_SHARE) then
                return n
            end
        end
    end
    return 1
end

-- _nShelves() — shelf row count for the current mode.
--   landscape normal → 1,  landscape expanded → 2
--   standard / tall normal → _baseShelves() (dynamic, see above)
--   expanded → base + 1 (hero collapses to a status strip; squeeze in
--                        one more row of covers to use the freed space)
function BookshelfWidget:_nShelves()
    if self._expanded then
        if self:_isLandscape() then return 2 end
        return self:_baseShelves() + 1
    end
    return self:_baseShelves()
end

-- _nCols() — column count per shelf row.
-- Landscape: 5 (wide screen fits more covers per row).
-- Tall screens: 3 for larger covers. Standard: 4.
function BookshelfWidget:_nCols()
    if self:_isLandscape() then return 5 end
    return self:_isTallScreen() and 3 or 4
end

-- _pageSize() — page-advance step. Matches _viewSize so paging forward
-- reveals an entire new view's worth of books with no row overlap. The
-- expand/collapse toggle (swipe-up) still reveals one extra row at the
-- bottom on collapsed→expanded transition (that's a self.page-preserving
-- view-size change, not a page advance), but within expanded mode the
-- next-page chevron advances by the full visible count.
--
-- Tracks _nShelves rather than _baseShelves so expanded mode advances by
-- _nShelves×_nCols (e.g. 12 on a standard expanded screen) instead of
-- the previous _baseShelves×_nCols (8) which left the last row of page
-- N visible as the first row of page N+1.
--
-- Landscape: 5 (1×5). Standard: 8 (2×4) collapsed / 12 (3×4) expanded.
-- Tall PW-aspect: 9 (3×3) collapsed / 12 (4×3) expanded.
function BookshelfWidget:_pageSize()
    if self:_isLandscape() then return 5 end
    return self:_nShelves() * self:_nCols()
end

-- _syncPageFromCursor() — recomputes self.page (display-only) from
-- self._cursor + current view size + total items. Call this whenever
-- cursor moves so the pagination footer stays in sync.
--
-- Two cases:
--   * View contains the last book of the list  → last page (the user
--     reasons "we're at the end, so this is the last page" regardless
--     of where the cursor literally falls).
--   * Otherwise                                → aligned page from
--     cursor (floor((cursor-1)/view) + 1).
--
-- Example: 18 books, view=12, cursor=9. View shows books 9-18 which
-- contains book 18 (the last). page = 2 (the last page). Without this
-- special case the aligned formula would give page 1, leaving the user
-- looking at end-of-list content while the footer claims "page 1 of 2"
-- and the prev button is disabled.
function BookshelfWidget:_syncPageFromCursor()
    -- "Page of the last visible book". For a clamped near-end view
    -- (cursor=9, view=12, total=18: visible 9-18), the last visible
    -- book is 18 which is on page 2 -- the user reads this as "I'm at
    -- the end". For a misaligned mid-list cursor (cursor=9, view=12,
    -- total=30: visible 9-20), the last visible book is 20 which is on
    -- page 2 -- also reasonable, since most of the view is page-2-ish
    -- content. Aligned cursors are unaffected (cursor=1 → page 1,
    -- cursor=13 → page 2, etc).
    local view  = self:_viewSize()
    local total = self._total_items or 0
    local last_visible = self._cursor + view - 1
    if total > 0 and last_visible > total then last_visible = total end
    self.page = math.max(1, math.ceil(last_visible / view))
    if self._total_pages and self.page > self._total_pages then
        self.page = self._total_pages
    end
end

-- _maxCursor(total) — last cursor position that shows non-empty content.
-- Partial last view allowed: with total=25, view=12, max_cursor=25 (last
-- view shows just book 25). Falls back to self._total_pages × view_size
-- when total is missing, since handler call sites often don't have
-- direct access to the unsliced item count.
function BookshelfWidget:_maxCursor(total)
    local view = self:_viewSize()
    if total and total > 0 then
        local n_pages = math.max(1, math.ceil(total / view))
        return (n_pages - 1) * view + 1
    end
    local n_pages = math.max(1, self._total_pages or 1)
    return (n_pages - 1) * view + 1
end

-- _clampCursor(total) — keep cursor inside [1, _maxCursor(total)].
function BookshelfWidget:_clampCursor(total)
    if total ~= nil and total <= 0 then
        self._cursor = 1
        return
    end
    local mx = self:_maxCursor(total)
    if self._cursor > mx then self._cursor = mx end
    if self._cursor < 1 then self._cursor = 1 end
end

-- _advanceCursor(delta_views, total) — chevron pagination. Adds
-- delta_views × VIEW_SIZE to the cursor (no boundary snapping). After a
-- swipe-up that left the cursor misaligned (e.g. cursor=9 in expanded
-- mode with view=12, top row preserved from collapsed page 2), each
-- chevron-next still reveals a full new view's worth of books with no
-- row overlap -- the user just navigates from a non-page-aligned start.
-- Snapping back to page boundaries would re-introduce the overlap the
-- whole cursor rework was meant to remove. total is optional; falls
-- through to _total_pages × view_size for the chevron handlers that
-- don't carry the items count.
function BookshelfWidget:_advanceCursor(delta_views, total)
    local view = self:_viewSize()
    self._cursor = self._cursor + delta_views * view
    if self._cursor < 1 then self._cursor = 1 end
    self:_clampCursor(total)
end

-- _viewSize() — books shown per page: current rows × cols.
-- Standard normal: 8, standard expanded: 12, tall normal: 9, tall expanded: 12.
-- Landscape normal: 5, landscape expanded: 10.
-- Expanded pages overlap _pageSize by one row so paging forward reveals
-- one new row at the bottom while the top rows stay fixed.
function BookshelfWidget:_viewSize()
    return self:_nShelves() * self:_nCols()
end

-- _previewNeighbourBook(direction) — cycle self._preview_book through the
-- current chip's books in order (skipping series groups, which can't be
-- previewed). direction = +1 for next, -1 for previous. Wraps at edges.
-- Crosses page boundaries by recomputing self.page from the target book's
-- position in the unsliced list.
function BookshelfWidget:_previewNeighbourBook(direction)
    local PAGE_SIZE = self:_pageSize()
    local all_items = self:_fetchChipItems(400) or {}
    -- Series groups have no filepath; skip them — only books are previewable.
    -- Track the all_items index of each book so we can map back to a page.
    local books, books_to_all = {}, {}
    for i, item in ipairs(all_items) do
        if item and item.filepath then
            books[#books + 1] = item
            books_to_all[#books] = i
        end
    end
    if #books == 0 then return end
    local n = #books
    local current_idx
    if self._preview_book and self._preview_book.filepath then
        for i, b in ipairs(books) do
            if b.filepath == self._preview_book.filepath then
                current_idx = i; break
            end
        end
    end
    -- No preview yet: a forward swipe should land on book 1, a backward
    -- swipe on the last book. Anchor current_idx so the wrap arithmetic
    -- below produces the right destination.
    if not current_idx then
        current_idx = direction > 0 and 0 or 1
    end
    local next_idx = ((current_idx - 1 + direction) % n) + 1
    local target = books[next_idx]
    if not target or not target.filepath then return end
    if self._preview_book and self._preview_book.filepath == target.filepath then
        return  -- single-book chip; cycling would otherwise re-trigger open
    end
    -- Update cursor so the new preview is on the visible shelf -- snap
    -- to the page that contains the target so the user lands at a clean
    -- page-aligned cursor rather than carrying a stale misalignment
    -- across an explicit "go to that book" action.
    local all_idx = books_to_all[next_idx]
    if all_idx then
        local view = self:_viewSize()
        self._cursor = math.max(1, math.floor((all_idx - 1) / view) * view + 1)
        self:_clampCursor()
        self:_syncPageFromCursor()
    end
    self:_previewBook(target)
end

-- Shared pagination logic for swipe and hardware-key page-turn handlers.
-- Hero-position-aware preview cycling is gesture-only (depends on swipe
-- coordinates) so it stays in the swipe wrappers; everything else —
-- page-step, chip-cycle at edges, drill-back at page 1 — is identical
-- between input modes.
function BookshelfWidget:_paginateNext()
    -- Pagination works inside drilled views too — a series / folder with
    -- >8 books needs to page through. Earlier this early-returned on
    -- _expanded_series because the footer label was hijacked for back;
    -- breadcrumb mode in the chip strip handles back now.
    local total = self._total_pages or 1
    if self.page < total then
        self:_advanceCursor(1)
        self:_syncPageFromCursor()
        self:_swapShelvesInPlace()
        return true
    end
    -- Last page at top level (no drill-down) and chip strip visible
    -- → cycle to the next tab (with wrap). Drilled-in last page is
    -- left as a no-op; back-navigation there happens via the
    -- breadcrumb or east-swipe.
    if #self._drilldown_path == 0 and not self._chip_bar_hidden then
        local next_key = self:_chipNeighbour(1)
        if next_key then self:_setActiveChip(next_key) end
    end
    return true
end

function BookshelfWidget:_paginatePrev()
    if self.page > 1 then
        self:_advanceCursor(-1)
        self:_syncPageFromCursor()
        self:_swapShelvesInPlace()
        return true
    end
    -- Already on page 1: if drilled into a folder/series, treat this as
    -- "go up a level" (mirrors tapping the previous breadcrumb crumb /
    -- the chip pill at depth 1). Discoverable escape from drill-down
    -- without aiming at the breadcrumb.
    if #self._drilldown_path > 0 then
        self:_drillBackTo(#self._drilldown_path - 1)
        return true
    end
    -- Top level + page 1 + chip strip visible → cycle to previous tab
    -- (with wrap). Hidden strip means 0 or 1 effective tab; cycling
    -- would either no-op or surface a hidden chip silently, neither
    -- helpful.
    if not self._chip_bar_hidden then
        local prev_key = self:_chipNeighbour(-1)
        if prev_key then self:_setActiveChip(prev_key) end
    end
    return true
end

function BookshelfWidget:onSwipeNextPage(_, ges)
    -- Hero-area swipe: cycle preview to next book. Stays inside the
    -- chip; pages flip automatically when the next book lives on a
    -- different page than the current preview.
    if self:_isHeroSwipe(ges) then
        self:_previewNeighbourBook(1)
        return true
    end
    return self:_paginateNext()
end

function BookshelfWidget:onSwipePrevPage(_, ges)
    if self:_isHeroSwipe(ges) then
        self:_previewNeighbourBook(-1)
        return true
    end
    return self:_paginatePrev()
end

-- Hardware page-turn key handlers. Skip the hero-position branch (no
-- gesture coordinates) and dispatch straight to pagination.
function BookshelfWidget:onNextPage() return self:_paginateNext() end
function BookshelfWidget:onPrevPage() return self:_paginatePrev() end

function BookshelfWidget:onBookshelfNextChip()
    if self._chip_bar_hidden then return true end
    local key = self:_chipNeighbour(1)
    if key then self:_setActiveChip(key) end
    return true
end

function BookshelfWidget:onBookshelfPrevChip()
    if self._chip_bar_hidden then return true end
    local key = self:_chipNeighbour(-1)
    if key then self:_setActiveChip(key) end
    return true
end

function BookshelfWidget:onBookshelfToggleHero()
    self:_clearDpadFocus()
    self._expanded = not self._expanded
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    return true
end

function BookshelfWidget:_clearDpadFocus()
    self._focus_zone         = nil
    self._cursor_idx         = nil
    self._chip_cursor_key    = nil
    self._crumb_cursor_depth = nil
    self._footer_cursor_btn  = nil
    if self._chip_bar and self._chip_bar.focusCursor then
        self._chip_bar:focusCursor(nil)
    end
    if self._chip_bar and self._chip_bar.focusCrumb then
        self._chip_bar:focusCrumb(nil)
    end
end

-- North-swipe anywhere on screen: collapse hero to compact strip, expand
-- the grid from 2 to 3 rows. No-op when already expanded.
function BookshelfWidget:onSwipeShelvesUp(_, ges)
    if self._expanded then return false end
    self._expanded = true
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    return true
end

-- South-swipe handling.
--   * Expanded mode (hero hidden): restore the hero -- pair to the
--     north-swipe collapse. Fires regardless of swipe start position
--     since the hero isn't drawn.
--   * Normal mode + swipe started on the shelf area: refresh the
--     library. The mtime check in cachedWalk handles auto-detection
--     for the common case; this is the user's explicit "I just plugged
--     in a USB cable and added books, re-check now" affordance.
--   * Normal mode + swipe started on the hero: no-op, so the hero's
--     own gesture surface stays clean (east/west already cycle
--     preview; south is reserved).
function BookshelfWidget:onSwipeShelvesDown(_, ges)
    if self._expanded then
        self._expanded = false
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        return true
    end
    -- Only claim the gesture for a refresh when it started in the shelf
    -- area. Returning false elsewhere (top edge, chip strip, hero) lets
    -- KOReader's top-of-screen menu swipe-down through to its handler
    -- and leaves the hero's own gesture surface alone.
    if not self:_isShelfSwipe(ges) then return false end
    self:_refreshLibrary()
    return true
end

-- Synchronous refresh: shows a "Refreshing library..." notice, wipes the
-- walk cache (which cascades to all downstream group/source caches), then
-- rebuilds. The InfoMessage is painted via forceRePaint so the user sees
-- the notice before the rebuild blocks the main loop. Same pattern as the
-- "Closing book..." feedback in main.lua's _closeAndShowBookshelf.
--
-- Cancellation: a prior version tried dismiss_callback + scheduleIn(0.5)
-- so the user could tap the message to abort. That broke the message
-- entirely: the swipe gesture's touch-release was being interpreted as a
-- tap on the freshly-shown modal, firing the dismiss callback before the
-- e-ink panel had even painted -- the scheduled work then bailed early,
-- leaving a torn screen state. An accident-cancel needs a different
-- mechanism (e.g. pre-confirmation dialog) that doesn't share input
-- focus with the gesture that triggered it.
function BookshelfWidget:_refreshLibrary()
    local InfoMessage = require("ui/widget/infomessage")
    local Repo        = require("lib/bookshelf_book_repository")
    local msg = InfoMessage:new{
        text    = _("Refreshing library\xE2\x80\xA6"),
        timeout = 0.0,
    }
    UIManager:show(msg)
    UIManager:setDirty(msg, function() return "partial", msg.dimen end)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        if Repo.invalidateWalkCache then Repo.invalidateWalkCache() end
        self:_rebuild()
        UIManager:close(msg)
        UIManager:setDirty(self, "ui")
    end)
end

-- _browseFiles()  — close home screen, open FileManager.
function BookshelfWidget:_browseFiles()
    local FileManager = require("apps/filemanager/filemanager")
    local home = G_reader_settings:readSetting("home_dir") or "/"
    UIManager:close(self)
    UIManager:nextTick(function()
        FileManager:showFiles(home)
    end)
end

-- ─── Gear menu (Task 6.2) ─────────────────────────────────────────────────────

function BookshelfWidget:_openGearMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local bw = self
    local dialog
    local function closing(fn)
        return function()
            if fn then fn() end
            UIManager:close(dialog)
        end
    end
    dialog = ButtonDialog:new{
        title = "Bookshelf",
        buttons = {
            {
                { text = G_reader_settings:readSetting("start_with") == "bookshelf"
                      and _("\xe2\x9c\x93 Bookshelf is my home screen")
                      or  _("Set as home screen"),
                  callback = closing(function()
                    G_reader_settings:saveSetting("start_with", "bookshelf")
                    G_reader_settings:flush()
                    local ok_notif, Notification = pcall(require, "ui/widget/notification")
                    if ok_notif and Notification then
                        UIManager:show(Notification:new{
                            text = _("Bookshelf will load on next launch"),
                        })
                    else
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text    = _("Bookshelf will load on next launch"),
                            timeout = 2,
                        })
                    end
                  end) },
            },
            {
                { text = "Browse files\xe2\x80\xa6",
                  callback = closing(function() bw:_browseFiles() end) },
            },
            {
                { text = "Settings\xe2\x80\xa6",
                  callback = closing(function() require("lib/bookshelf_settings"):show(bw) end) },
                { text = "About",
                  callback = closing(function() require("lib/bookshelf_settings"):_about() end) },
            },
            {
                { text = "Cancel", callback = closing() },
            },
        },
    }
    UIManager:show(dialog)
end

-- ─── Long-press book menu (Task 6.3) ─────────────────────────────────────────

-- _openBookMenu(item)
-- item may be a Book record (from a SpineWidget tap) or a SeriesGroup record
-- _setBookRating(book, new_rating): persist the rating to the book's
-- DocSettings summary, refresh the per-file progress cache so reads
-- pick up the new value, and rebuild the hero so the star row updates.
-- new_rating is 1-5 or nil (to clear). Matches KOReader's BookStatusWidget
-- storage: summary.rating in the .sdr/metadata.X.lua sidecar.
function BookshelfWidget:_setBookRating(book, new_rating)
    if not book or not book.filepath then return end
    local DocSettings = require("docsettings")
    local ok_ds, ds = pcall(function() return DocSettings:open(book.filepath) end)
    if not ok_ds or not ds then return end
    local summary = ds:readSetting("summary") or {}
    summary.rating = new_rating  -- nil clears it
    ds:saveSetting("summary", summary)
    ds:flush()
    -- Update the in-memory book record so the immediate rebuild reflects
    -- the new value without waiting for a fresh BIM read.
    book.rating = new_rating
    -- Refresh the per-file progress cache (it caches rating alongside
    -- pct/status). Otherwise the next read would return the stale value.
    if Repo.invalidateProgressCache then
        Repo.invalidateProgressCache(book.filepath)
    end
    -- Rebuild the hero so the star row redraws with the new state.
    -- _swapHeroInPlace would be lighter but the rating row builds inside
    -- _renderRight which the in-place swap doesn't re-run.
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- Open a scrollable viewer with the full book description. Same
-- TextViewer the updater uses for release notes -- KOReader's stock
-- modal for "here's some text, more than fits on screen, you can
-- scroll it." The description is run through cleanDescription to
-- strip HTML tags and decode entities; the viewer renders plain
-- text with paragraph breaks preserved.
function BookshelfWidget:_showFullDescription(book)
    if not book or not book.description or book.description == "" then return end
    local Tokens     = require("lib/bookshelf_tokens")
    local TextViewer = require("ui/widget/textviewer")
    local text = Tokens.cleanDescription(book.description) or ""
    if text == "" then return end
    local title = book.title or _("Description")
    if book.author then title = title .. " — " .. book.author end
    local viewer
    viewer = TextViewer:new{
        title = title,
        text  = text,
        buttons_table = {
            { { text = _("Close"), callback = function() UIManager:close(viewer) end } },
        },
    }
    UIManager:show(viewer)
end

-- (from on_series_hold on a SeriesStack). Series groups have a .books field;
-- we route to a series-specific dialog in that case.
function BookshelfWidget:_openBookMenu(item)
    if not item then return end
    -- If the item is a series group, show a simpler series dialog.
    if item.books then
        return self:_openSeriesMenu(item)
    end
    local book = item
    local ButtonDialog   = require("ui/widget/buttondialog")
    local ReadCollection = require("readcollection")
    local bw = self
    local ok_fav, in_fav = pcall(function()
        return ReadCollection:isFileInCollection(book.filepath, "favorites")
    end)
    local fav_label = (ok_fav and in_fav)
        and "Remove from favourites" or "Add to favourites"
    -- ButtonDialog does NOT auto-close on a button tap — each callback has to
    -- call UIManager:close itself. Wrap with a closing helper so all callbacks
    -- close the dialog after their action runs.
    local dialog
    local function closing(fn)
        return function()
            if fn then fn() end
            UIManager:close(dialog)
        end
    end
    -- Build optional navigation rows (author / series / genres).
    -- Each item is only included if the book has the field AND the
    -- corresponding tab is enabled in TabModel.
    local TabModel = require("lib/bookshelf_tab_model")
    local enabled = {}
    for _i, tab in ipairs(TabModel.getActive()) do enabled[tab.id] = true end
    local nav_rows = {}
    -- Long-press nav rows are JUMPS, not descents — reset the drilldown
    -- path before each so the breadcrumb starts fresh (otherwise repeated
    -- long-press jumps stack: SERIES > DISCWORLD > TERRY PRATCHETT >
    -- TERRY PRATCHETT > Discworld …). The chip-tap on_*_tap path leaves
    -- this alone so descending into a group from the groups list still
    -- builds the expected hierarchy.
    -- Go to Author
    if book.author and book.author ~= "" and enabled["authors"] then
        local author_name = book.author
        nav_rows[#nav_rows + 1] = {
            { text = "Go to author: " .. author_name,
              callback = closing(function()
                local group = Repo.findGroup("author", author_name)
                if not group then
                    group = { kind = "author", series_name = author_name,
                              books = { book }, latest = 0 }
                end
                bw._drilldown_path = {}
                bw:_expandAuthor(group)
              end) },
        }
    end
    -- Go to Series
    -- Book records carry `series_name` (cleaned, e.g. "Foundation") which
    -- is the same key used by series group records. `book.series` is the
    -- raw BIM string (e.g. "Foundation #1") — do NOT use it here.
    if book.series_name and book.series_name ~= "" and enabled["series"] then
        local series_name = book.series_name
        nav_rows[#nav_rows + 1] = {
            { text = "Go to series: " .. series_name,
              callback = closing(function()
                local group = Repo.findGroup("series", series_name)
                if not group then
                    group = { kind = "series", series_name = series_name,
                              books = { book }, latest = 0 }
                end
                bw._drilldown_path = {}
                bw:_expandSeries(group)
              end) },
        }
    end
    -- Go to Genre (up to 3)
    if book.genres and #book.genres > 0 and enabled["genres"] then
        local max_genres = math.min(#book.genres, 3)
        for i = 1, max_genres do
            local genre_name = book.genres[i]
            nav_rows[#nav_rows + 1] = {
                { text = "Go to genre: " .. genre_name,
                  callback = closing(function()
                    local group = Repo.findGroup("genre", genre_name)
                    if not group then
                        group = { kind = "genre", series_name = genre_name,
                                  books = { book }, latest = 0 }
                    end
                    bw._drilldown_path = {}
                    bw:_expandGenre(group)
                  end) },
            }
        end
    end

    -- Build the complete buttons table before construction — ButtonDialog
    -- processes self.buttons into a ButtonTable widget synchronously in
    -- init(), so any mutations after new{} are invisible to the rendered dialog.
    local buttons = {
        {
            { text = "Show info",
              callback = closing(function()
                -- filemanagerbookinfo:show does lfs.attributes(file).size with
                -- no nil guard — passing a missing filepath panics LuaJIT and
                -- drops to stock Kindle. Bail with a toast for stale records.
                local lfs = require("libs/libkoreader-lfs")
                if lfs.attributes(book.filepath, "mode") ~= "file" then
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text    = _("File no longer exists. The bookshelf entry is stale."),
                        timeout = 3,
                    })
                    return
                end
                local FileManager = require("apps/filemanager/filemanager")
                local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
                if FileManager.instance and FileManager.instance.bookinfo then
                    FileManager.instance.bookinfo:show(book.filepath)
                else
                    FileManagerBookInfo:new{}:show(book.filepath)
                end
              end) },
            { text = fav_label,
              callback = closing(function()
                -- KOReader API quirks (frontend/readcollection.lua):
                --   * addItem only updates in-memory state -- needs a
                --     caller-side :write() to persist.
                --   * removeItem DOES call :write({ collection_name = true })
                --     internally (line 189) BUT passes the literal string
                --     "collection_name" as the table key rather than the
                --     variable's value. :write at line 76 then checks
                --     updated_collections[coll_name] (e.g. "favorites"),
                --     finds nil, and skips persisting the affected
                --     collection. In-memory state updates correctly, but
                --     the on-disk file stays stale -- so removed
                --     favourites come back on the next KOReader restart.
                -- Workaround: explicit :write({ favorites = true }) on
                -- both branches, with the right key, so removal actually
                -- persists.
                local ok, already = pcall(function()
                    return ReadCollection:isFileInCollection(book.filepath, "favorites")
                end)
                if ok and already then
                    ReadCollection:removeItem(book.filepath, "favorites")
                    ReadCollection:write({ favorites = true })
                else
                    ReadCollection:addItem(book.filepath, "favorites")
                    ReadCollection:write({ favorites = true })
                end
                -- Chip caches store filepath lists post-filter -- a
                -- favourites add/remove changes membership in the
                -- favourites chip AND in any custom chip that filters on
                -- collections, so the per-source caches must be wiped or
                -- the toggle won't surface until swipe-down. (Issue #40.)
                Repo.invalidateBookCache("favorites-toggle")
                bw:_rebuild()
                UIManager:setDirty(bw, "ui")
              end) },
        },
        {
            { text = "Remove from history",
              callback = closing(function()
                require("readhistory"):removeItemByPath(book.filepath)
                -- Recent chip + any custom chip sorted by last_opened or
                -- filtered on history membership caches the post-filter
                -- filepath list; the removal won't surface until we clear
                -- those caches. (Issue #40.)
                Repo.invalidateBookCache("remove-from-history")
                bw:_rebuild()
                UIManager:setDirty(bw, "ui")
              end) },
        },
    }

    -- Status row (Reading / On hold / Finished) + Reset / Delete row.
    -- KOReader's filemanagerutil provides the canonical button generators
    -- (status enum + cache updates + Reset confirmation dialog), and
    -- FileManager:showDeleteFileDialog the canonical Delete flow -- reuse
    -- both so we inherit any future behavioural fixes for free.
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local function refresh_book_state()
        Repo.invalidateProgressCache(book.filepath)
        -- Status changes also shift the book's membership in any
        -- status-filtered chip and its position in a "Reading" /
        -- "Unread first" sort, so wipe the per-source caches too --
        -- otherwise the user has to swipe-down to see a status edit.
        -- (Issue #40.) genStatusButtonsRow does not broadcast
        -- BookMetadataChanged itself, so onBookMetadataChanged in main.lua
        -- won't catch this either.
        Repo.invalidateBookCache("openBookMenu/status")
        bw:_rebuild()
        UIManager:setDirty(bw, "ui")
    end
    local function status_callback()
        UIManager:close(dialog)
        refresh_book_state()
    end
    buttons[#buttons + 1] = filemanagerutil.genStatusButtonsRow(
        book.filepath, status_callback)

    -- Reset: KOReader's generator opens its own ConfirmBox with checkboxes
    -- (settings / cover / metadata). Close our dialog before the ConfirmBox
    -- shows so it appears on a clean backdrop; the generator's caller_callback
    -- runs only on confirmation (handles the rebuild after).
    local reset_btn = filemanagerutil.genResetSettingsButton(
        book.filepath, function()
            Repo.invalidateProgressCache(book.filepath)
            Repo.invalidateWalkCache()  -- sidecar gone -> walk results stale
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end)
    local orig_reset_cb = reset_btn.callback
    reset_btn.callback = function()
        UIManager:close(dialog)
        orig_reset_cb()
    end

    -- Delete: prefer FileManager:showDeleteFileDialog when available so the
    -- per-file confirmation, history/collection cleanup, and sdr purge all
    -- match FM. Fall back to a minimal inline confirm + os.remove when
    -- bookshelf is running outside an FM context.
    local delete_btn = {
        text = _("Delete"),
        callback = function()
            UIManager:close(dialog)
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance and FileManager.instance.showDeleteFileDialog then
                FileManager.instance:showDeleteFileDialog(book.filepath, function()
                    Repo.invalidateProgressCache(book.filepath)
                    Repo.invalidateWalkCache()
                    bw:_scrubFromDrilldown(book.filepath)
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                end)
            else
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text     = _("Delete file permanently?") .. "\n\n" .. book.filepath,
                    ok_text  = _("Delete"),
                    ok_callback = function()
                        if os.remove(book.filepath) then
                            require("readhistory"):fileDeleted(book.filepath)
                            ReadCollection:removeItem(book.filepath)
                            Repo.invalidateProgressCache(book.filepath)
                            Repo.invalidateWalkCache()
                            bw:_scrubFromDrilldown(book.filepath)
                            bw:_rebuild()
                            UIManager:setDirty(bw, "ui")
                        else
                            UIManager:show(require("ui/widget/infomessage"):new{
                                text = _("Failed to delete file."),
                                icon = "notice-warning",
                            })
                        end
                    end,
                })
            end
        end,
    }
    buttons[#buttons + 1] = { reset_btn, delete_btn }

    for _i, row in ipairs(nav_rows) do
        buttons[#buttons + 1] = row
    end
    buttons[#buttons + 1] = { { text = "Cancel", callback = closing() } }
    dialog = ButtonDialog:new{
        title   = book.title or book.filename or "Book",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- _openSeriesMenu(series)  — long-press on a series stack.
function BookshelfWidget:_openSeriesMenu(series)
    local ButtonDialog = require("ui/widget/buttondialog")
    local bw = self
    local dialog
    local function closing(fn)
        return function()
            if fn then fn() end
            UIManager:close(dialog)
        end
    end
    dialog = ButtonDialog:new{
        title = series.series_name or "Series",
        buttons = {
            {
                { text = "Browse series",
                  callback = closing(function() bw:_expandSeries(series) end) },
            },
            {
                { text = "Cancel", callback = closing() },
            },
        },
    }
    UIManager:show(dialog)
end

-- ─── Series expand-in-place (Task 6.3) ───────────────────────────────────────

-- _drillInto(entry) — push a drill-down level. Each entry has the shape
--   { kind = "series" | "folder" | ..., label = "...", payload = ... }
-- The chip strip enters breadcrumb mode and _fetchChipItems scopes to
-- the path's tip. Page resets to 1; the hero stays untouched — only an
-- explicit cover tap (_previewBook) updates self._preview_book.
function BookshelfWidget:_drillInto(entry)
    if not entry or not entry.kind then return end
    self:_clearDpadFocus()
    -- Stash the page the *outer* context was showing so a later pop can
    -- restore it. Without this, drilling into a folder on page 3 and then
    -- backing out drops you on page 1 of the parent listing — disorienting
    -- when the parent has dozens of folders/series.
    entry.parent_cursor = self._cursor
    self._drilldown_path[#self._drilldown_path + 1] = entry
    self._cursor = 1
    self:_syncPageFromCursor()
    -- self._preview_book intentionally NOT reset: the hero is now sticky
    -- across drilldowns / chip switches / search until the user taps a
    -- cover. Earlier we pre-selected the first book on every drill so the
    -- hero reflected the drill target, but that meant casual browsing
    -- (open a folder, look around, back out) kept overwriting whatever
    -- book the user had been reading. Sticky-hero feels less twitchy and
    -- gives the user a stable reference point regardless of where they
    -- navigate.
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- _drillBackTo(depth) — pop the drill path so the new tip is at index
-- `depth`. depth 0 = back to top level (chips list); depth 1 = keep
-- only the first crumb; etc.
function BookshelfWidget:_drillBackTo(depth)
    depth = math.max(0, depth or 0)
    self:_clearDpadFocus()
    -- The first entry we're about to pop carries `parent_page` — the page
    -- the level we're returning to was on before this drill. Snapshot it
    -- before tearing the entry down. When popping multiple levels at once
    -- (e.g. a deep crumb tap) only the FIRST popped entry's parent_page
    -- matters — that's the page of the level we're landing on.
    -- Search entries also carry `prior_drilldown` (the path that was active
    -- before search was invoked); restore it so backing out of search
    -- returns the user to where they were, not to a bare chip top.
    local restore_cursor = 1
    local restore_path
    if #self._drilldown_path > depth then
        local first_pop = self._drilldown_path[depth + 1]
        if first_pop and first_pop.parent_cursor then
            restore_cursor = first_pop.parent_cursor
        end
        if first_pop and first_pop.kind == "search" and first_pop.prior_drilldown then
            restore_path = first_pop.prior_drilldown
        end
    end
    while #self._drilldown_path > depth do
        self._drilldown_path[#self._drilldown_path] = nil
    end
    if restore_path then
        for _i, entry in ipairs(restore_path) do
            self._drilldown_path[#self._drilldown_path + 1] = entry
        end
    end
    -- self._preview_book intentionally NOT reset here either — see the
    -- sticky-hero rationale in _drillInto. Backing out keeps the user's
    -- last-tapped book in the hero, regardless of which level they pop to.
    self._cursor = restore_cursor
    self:_syncPageFromCursor()
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- Convenience for the existing series-expand call sites.
-- These switch self.chip to the matching tab so the breadcrumb pill shows
-- the right kind ("AUTHORS > Stephen King") when entered from a long-press
-- on a different tab. When entered from the matching chip's own tap
-- callback the assignment is a no-op.
local function _switchChip(self, key)
    if self.chip ~= key then
        self.chip = key
        BookshelfSettings.save("active_chip", key)
    end
end

-- _applyWithinGroupSort(group): when the current chip's tab has sort_priority
-- levels 2+, those levels apply to the books WITHIN this group at drill time.
-- The group already has a default series-aware order from _buildGroups
-- (series_name -> series_index -> title); this function lets the user
-- override that via the tab editor.
--
-- group.books_meta is the parallel array of sort-relevant fields per book
-- (carried through _cacheGroupShapes / _hydrateGroupShape). We sort it,
-- then realign group.books (which has full BIM only for [1] and stubs for
-- the rest) to match the new filepath order.
function BookshelfWidget:_applyWithinGroupSort(group)
    if not group or not group.books_meta then return end
    local TabModel = require("lib/bookshelf_tab_model")
    local tab = TabModel.getById(self.chip)
    local sp  = tab and tab.sort_priority
    if not sp or #sp < 2 then return end  -- default series-aware order wins
    local within = {}
    for i = 2, #sp do within[#within + 1] = sp[i] end
    local SortEngine = require("lib/bookshelf_sort_engine")
    SortEngine.sort(group.books_meta, within)
    local fp_to_book = {}
    for _i, b in ipairs(group.books) do fp_to_book[b.filepath] = b end
    local new_books = {}
    for _i, m in ipairs(group.books_meta) do
        local b = fp_to_book[m.filepath]
        if b then new_books[#new_books + 1] = b end
    end
    group.books = new_books
end

-- _expand* handlers: drill INTO a stack without switching the underlying
-- chip. The drilldown_path carries the navigation context (and the
-- breadcrumb reads from it), so the chip itself can stay wherever the
-- user was. Older builds switched to a hardcoded chip id ("authors",
-- "series", etc.) which broke once users started repurposing built-in
-- chip ids -- e.g. a tab with id="all" but source.kind="authors" was
-- still "the authors view" semantically but didn't have id="authors".
-- The chip switch sent the user to a wrong tab on rebuild; the chip-
-- fallback logic then re-pointed them at their first tab. Easier and
-- correct to never switch: drilling is path-level, not chip-level.

function BookshelfWidget:_expandSeries(series)
    if not series or not series.series_name then return end
    self:_applyWithinGroupSort(series)
    self:_drillInto{
        kind    = "series",
        label   = series.series_name,
        payload = series,
    }
end

function BookshelfWidget:_expandAuthor(group)
    if not group or not group.series_name then return end
    self:_applyWithinGroupSort(group)
    self:_drillInto{
        kind    = "author",
        label   = group.series_name,
        payload = group,
    }
end

function BookshelfWidget:_expandGenre(group)
    if not group or not group.series_name then return end
    self:_applyWithinGroupSort(group)
    self:_drillInto{
        kind    = "genre",
        label   = group.series_name,
        payload = group,
    }
end

function BookshelfWidget:_expandTag(group)
    if not group or not group.series_name then return end
    self:_applyWithinGroupSort(group)
    self:_drillInto{
        kind    = "tag",
        label   = group.series_name,
        payload = group,
    }
end

function BookshelfWidget:_expandFormat(group)
    if not group or not group.series_name then return end
    -- Formats is a custom tab source -- there is no built-in "formats" chip
    -- to switch to, so we drill in on whatever chip the user is currently on.
    self:_applyWithinGroupSort(group)
    self:_drillInto{
        kind    = "format",
        label   = group.series_name,
        payload = group,
    }
end

function BookshelfWidget:_expandRating(group)
    if not group or not group.series_name then return end
    self:_applyWithinGroupSort(group)
    self:_drillInto{
        kind    = "rating",
        label   = group.series_name,
        payload = group,
    }
end

-- _openSearchDialog: input modal that runs Repo.searchBooks and drills
-- into the results. Search results live as a regular drill-down entry
-- (kind = "search") so the breadcrumb arrow pill doubles as a "back to
-- whatever I was on" affordance and the existing east-swipe / chip-pill
-- tap clears the search.
function BookshelfWidget:_openSearchDialog(prefill)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title      = _("Search library"),
        input      = prefill or "",
        input_hint = _("title, author, series, genre…"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id   = "close",
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text             = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = dlg:getInputText()
                        UIManager:close(dlg)
                        if query and query:match("%S") then
                            self:_searchAndDrill(query)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function BookshelfWidget:_searchAndDrill(query)
    local results = Repo.searchAll(query)
    -- Don't store the hydrated records in the drill payload -- their
    -- cover_bb gets freed by ImageWidget after first paint, and any
    -- subsequent re-render (e.g. backing out of a drilled-into stack)
    -- would read freed memory and corrupt the cover (see memory
    -- feedback_image_disposable_shared_book). Stash identifiers only;
    -- _fetchChipItems re-hydrates on every render so covers are always
    -- fresh.
    local author_names, series_names, genre_names = {}, {}, {}
    for _i, g in ipairs(results.authors or {}) do author_names[#author_names + 1] = g.series_name end
    for _i, g in ipairs(results.series  or {}) do series_names[#series_names + 1] = g.series_name end
    for _i, g in ipairs(results.genres  or {}) do genre_names[#genre_names + 1]   = g.series_name end
    local folders = {}
    for _i, f in ipairs(results.folders or {}) do
        folders[#folders + 1] = {
            path          = f.path,
            label         = f.label,
            first_book_fp = f.first_book and f.first_book.filepath,
        }
    end
    local book_fps = {}
    for _i, b in ipairs(results.books or {}) do
        if b.filepath then book_fps[#book_fps + 1] = b.filepath end
    end
    -- Search is its own top-level mode rather than a nested drill under
    -- the active chip. Stash whatever drilldown the user was in so the
    -- back-out path restores it (a folder browse + search-then-back
    -- shouldn't drop the folder context). The active chip is preserved
    -- by self.chip — _drillBackTo to depth 0 leaves us on it.
    --
    -- Re-search-from-search special case: if the existing top-of-path is
    -- a search entry (user tapped the chip pill / query crumb to edit
    -- their query), inherit ITS prior_drilldown rather than nesting
    -- search-on-search. Otherwise repeated edits would stack search
    -- entries forever, and back-out would walk through every prior
    -- query before reaching the original drilldown.
    local prior_path
    local current_top = self._drilldown_path[#self._drilldown_path]
    if current_top and current_top.kind == "search" and current_top.prior_drilldown then
        prior_path = current_top.prior_drilldown
    else
        prior_path = self._drilldown_path
    end
    self._drilldown_path = {}
    self:_drillInto{
        kind            = "search",
        label           = query,
        payload         = {
            query        = query,
            folders      = folders,
            author_names = author_names,
            series_names = series_names,
            genre_names  = genre_names,
            book_fps     = book_fps,
        },
        prior_drilldown = prior_path,
    }
end

function BookshelfWidget:_expandFolder(folder)
    if not folder or not folder.path then return end
    -- FileChooser sometimes appends a trailing slash to the item.text;
    -- strip it before drilling in so the breadcrumb pill renders the
    -- folder name cleanly.
    local label = folder.label or folder.path:match("([^/]+)$") or folder.path
    label = label:gsub("/$", "")
    self:_drillInto{
        kind    = "folder",
        label   = label,
        payload = { path = folder.path, first_book = folder.first_book },
    }
end

-- ─── Dismiss / passthrough ───────────────────────────────────────────────────

function BookshelfWidget:onClose()
    UIManager:close(self)
    return true
end

return BookshelfWidget
