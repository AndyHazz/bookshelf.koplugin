-- bookshelf_widget.lua
-- The top-level home screen widget. Composes HeroCard + ChipBar
-- + two ShelfRows + chevron pagination footer. Owns chip-state and refresh.
--
local InputContainer  = require("ui/widget/container/inputcontainer")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local Breaker = require("lib/bookshelf_module_breaker")
local Focus           = require("lib/bookshelf_focus")
local TextSegments    = require("lib/bookshelf_text_segments")
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
local BFont           = require("lib/bookshelf_fonts")
local UIManager       = require("ui/uimanager")
local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Screen          = Device.screen

local _           = require("lib/bookshelf_i18n").gettext

local Repo        = require("lib/bookshelf_book_repository")
local Filter      = require("lib/bookshelf_filter")
local HeroCard    = require("lib/bookshelf_hero_card")
local ChipBar   = require("lib/bookshelf_chip_bar")
local ShelfRow    = require("lib/bookshelf_shelf_row")
local SpineWidget = require("lib/bookshelf_spine_widget")
local logger      = require("logger")
local T           = require("ffi/util").template

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

-- DPI-INDEPENDENT column model (portrait). The cover-size setting maps
-- directly to a column count, the same on every device regardless of DPI or
-- screen size -- covers are sized to fit that many columns (so they come out
-- smaller on a dense phone, larger on a wide e-reader, but the GRID is
-- consistent across devices). All these layout constants are declared at file
-- scope (before any method body references them) -- Lua parses method bodies
-- in source order, so a local declared further down would be invisible to the
-- methods above and silently rebind to a nil global.
local COVER_SIZE_COLS = {
    small  = 5,
    medium = 4,
    large  = 3,
}

-- Hero height as a fraction of the usable (hero+shelves) height, instead of
-- "eat N integer cover-rows" (which had no effect on screens where the row
-- count couldn't change). Rows fill the rest at ~natural cover height; "large"
-- hero takes one more row's worth than "regular" (see _baseShelves), so the
-- hero setting is always visibly different.
local HERO_HEIGHT_FRAC = {
    regular = 0.30,
    large   = 0.42,
}
-- Columns + Rows layout model: the user sets the shelf grid directly
-- (bookshelf_columns / bookshelf_rows) and the hero auto-sizes from the
-- leftover vertical space. HERO_MIN_FRAC is the floor the hero never shrinks
-- below, and the same floor Rows is clamped against so the grid + a usable
-- hero always fit. When the two settings are unset the legacy cover-size /
-- hero-size derivation is used instead (preserving existing layouts until the
-- user opens the editor).
local HERO_MIN_FRAC = 0.20
-- Sensible bounds for the explicit knobs (portrait); landscape may raise the
-- column floor so covers don't get too tall.
local COLUMNS_MIN, COLUMNS_MAX = 2, 6
local ROWS_MIN = 1
-- Landscape/widescreen: a fixed column count makes covers too tall, so there
-- the cover-size setting instead drives cover HEIGHT as a fraction of screen
-- height; columns fall out of that (shorter cover -> narrower -> more fit).
-- Keeps small/medium/large distinct when wide. Portrait still uses COVER_SIZE_COLS.
local SHELF_HEIGHT_FRAC = {
    small  = 0.25,
    medium = 0.35,
    large  = 0.45,
}
-- Count rows at ~natural cover height. Squashing covers vertically to cram an
-- extra row also shrinks them horizontally (2:3 preserved), leaving empty
-- space left/right of the shelf -- worse than a slightly bigger hero. So we
-- only take rows that fit at (near) natural size; leftover vertical slack goes
-- to the hero. 1.0 = no shrink-to-cram (covers keep natural width, fill the row).
local SHELF_PACK_FLOOR = 1.0
-- Hero cover never wider than this fraction of content_w, so the title/details
-- column keeps the rest. Relaxed from 0.50 so a tall (large) hero's cover can
-- fill its card better while still leaving room for details.
local HERO_COVER_MAX_FRAC = 0.58

-- FrameContainer that pixel-inverts its own rect after painting (selected
-- chips): paints black-on-white then flips, so the inversion is device-
-- independent (some Kindles don't honour TextWidget fgcolor). Mirrors the
-- segmented chips in the description tab. Defined here (above its first use in
-- _segmentedChips) so the file-scope local is in scope.
local InvertedFrame = require("ui/widget/container/framecontainer"):extend{}
function InvertedFrame:paintTo(bb, x, y)
    require("ui/widget/container/framecontainer").paintTo(self, bb, x, y)
    if self._invert and self.dimen then
        bb:invertRect(x, y, self.dimen.w, self.dimen.h)
    end
end

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
    -- Diag: cradle init so the cold-start trace shows init time
    -- distinct from the _rebuild it triggers at the end. Two markers
    -- (entry, post-settings-and-gesture-setup) plus the existing
    -- _rebuild log line tell the whole story.
    local _diag_init_t0 = _gettime()
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
    -- books on screen for browse-mode). Seeded from home_expanded so the home
    -- screen comes back the way the user last left it (only deliberate
    -- show/hide-hero actions write it, via _setExpanded). Seeding at init means
    -- it restores on launch AND on widget re-creation (e.g. reader return).
    self._expanded = BookshelfSettings.isTrue("home_expanded")

    -- Hero content mode: "current" (the currently-reading / preview book
    -- card) or "micro" (the micro-module grid). Seeded from the
    -- hero_area_mode setting ("Hero area starts with…"); toggled live by the
    -- chip bar. Like _expanded, this is session state — only the *starting*
    -- mode persists, so a fresh widget instance reseeds from the setting.
    -- The hero only starts in micro mode when micro-modules are placed "in the
    -- hero area" (placement == "hero"); "fullscreen" (footer-button overlay) and
    -- "off" both keep the book hero, and the modules chip is omitted below, so
    -- in-hero micro mode is unreachable in those placements.
    self._hero_mode = (BookshelfSettings.microInHero()
        and BookshelfSettings.read("hero_area_mode") == "micro_modules")
        and "micro" or "current"

    -- Home-screen crash recovery (issue #163): if the hero micro grid's paint
    -- crashed last launch, its light-touch sentinel marker survived on disk.
    -- Come up with the cover hero this session so the user isn't locked out of
    -- the home screen, and clear the marker so the next launch retries the grid.
    if self._hero_mode == "micro" then
        local mp = Breaker.heroMarkerPath()
        local ok_c, crashed = pcall(Breaker.fileCrashed, mp)
        if ok_c and crashed then
            self._hero_mode = "current"
            pcall(Breaker.endFile, mp)
        end
    end

    local Selection = require("lib/bookshelf_selection")
    self._selection = Selection.new()

    -- KOReader's Screenshoter listens for "swipe" with scale near the
    -- screen diagonal (no direction filter) and "two_finger_tap" with
    -- a similar scale. When bookshelf is the home overlay, our gesture
    -- ranges sit above the Screenshoter in the dispatch stack, so a
    -- corner-to-corner diagonal swipe would land on SwipeNextPage /
    -- SwipePrevPage first and never reach Screenshoter. Forward those
    -- specific gestures to the Screenshot event ourselves so the
    -- default KOReader screenshot gesture works even when bookshelf is
    -- the active home screen (and even when SimpleUI / similar shells
    -- bypass the regular FileManager dispatch).
    local SCREEN_DIAG = math.sqrt(self.width * self.width + self.height * self.height)
    local SCREENSHOT_MIN = SCREEN_DIAG - Screen:scaleBySize(200)
    self.ges_events = {
        TakeScreenshotTap = {
            GestureRange:new{
                ges = "two_finger_tap",
                scale = { SCREENSHOT_MIN, SCREEN_DIAG },
                rate = 1.0,
            },
        },
        TakeScreenshotSwipe = {
            GestureRange:new{
                ges = "swipe",
                scale = { SCREENSHOT_MIN, SCREEN_DIAG },
                rate = 1.0,
            },
        },
        SwipeNextPage = {
            -- scale cap leaves long corner-to-corner swipes for the
            -- screenshot handler above. A page-turn swipe is naturally a
            -- short flick; we'd only collide with screenshot gestures by
            -- not bounding.
            GestureRange:new{
                ges = "swipe", range = self.dimen, direction = "west",
                scale = { 0, SCREENSHOT_MIN - 1 },
            },
        },
        SwipePrevPage = {
            GestureRange:new{
                ges = "swipe", range = self.dimen, direction = "east",
                scale = { 0, SCREENSHOT_MIN - 1 },
            },
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
                scale = { 0, SCREENSHOT_MIN - 1 },
            },
        },
        SwipeShelvesDown = {
            GestureRange:new{
                ges = "swipe", direction = "south",
                -- y starts below the top 1/8th so the top strip stays
                -- exclusively for KOReader's filemanager_swipe zone
                -- (DTAP_ZONE_MENU.h = 1/8, full width). Once
                -- onSwipeShelvesDown's range MATCHES a south-swipe,
                -- the gesture is consumed inside InputContainer's
                -- dispatch regardless of the handler's return value —
                -- returning false from the handler does not propagate
                -- back to FM. The only way to let FM's top-strip swipe
                -- reach its menu handler is to not match here in the
                -- first place.
                range = Geom:new{
                    x = math.floor(self.width / 8),
                    y = math.floor(self.height / 8),
                    w = self.width - 2 * math.floor(self.width / 8),
                    h = self.height - math.floor(self.height / 8),
                },
                scale = { 0, SCREENSHOT_MIN - 1 },
            },
        },
        -- Pinch / spread to zoom the cover grid: spread (fingers apart) =
        -- bigger covers = FEWER columns; pinch = smaller covers = MORE
        -- columns. Adjusts the bookshelf_columns setting (the cover-size
        -- knob); rows reflow to fit.
        ShelfSpread = {
            GestureRange:new{ ges = "spread", range = self.dimen },
        },
        ShelfPinch = {
            GestureRange:new{ ges = "pinch", range = self.dimen },
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
        self.key_events.BSKbPress = { { "Press" } }
        -- Context-menu ("hold") gesture. Non-touch devices have no real
        -- long-press; KOReader's FocusManager maps hold to modifier+Press
        -- chords, so we mirror exactly those (focusmanager.lua HoldShift /
        -- HoldScreenKB / HoldSymAA):
        --   * ScreenKB+Press -- the standard on Kindle 4/5 (hasScreenKB)
        --   * Shift+Press    -- external / desktop keyboards
        --   * Sym+AA         -- other key layouts
        -- Deliberately NOT { "Menu" }: that's KOReader's own open-menu key
        -- on normal-keys hardware (FileManagerMenu.KeyPressShowMenu), and
        -- binding it stole the KOReader menu on physical-Menu devices like
        -- the Kindle 4 -- the bug this fix exists to undo.
        --
        -- An earlier revision derived hold from Press *duration* (no modifier
        -- needed). It worked, but (a) diverged from KOReader convention --
        -- Kindle users expect ScreenKB+Press, not a plain long-press on the
        -- centre key -- and (b) cost tap latency: a tap couldn't fire until
        -- key-release, because we had to wait and see if it became a hold.
        -- Binding the chords instead means a plain Press acts instantly on
        -- press-down again, which is the more noticeable everyday win.
        self.key_events.BSKbHold = {
            { "ScreenKB", "Press" },
            { "Shift", "Press" },
            { "Sym", "AA" },
        }
    end

    -- (Top-zone tap/swipe to open the FM menu is handled by the FileManager
    -- touch-zone passthrough in handleEvent below; no need to mirror those
    -- zones here. Doing so previously also ignored the user's
    -- `activation_menu` preference — fixed as a side benefit.)

    local _diag_init_t_pre_rebuild = _gettime()
    self:_rebuild()
    self:_startStatusTimer()
    logger.dbg(string.format(
        "[bookshelf perf] BookshelfWidget:init: pre_rebuild=%.0fms"
        .. " rebuild+timer=%.0fms TOTAL=%.0fms chip=%s",
        (_diag_init_t_pre_rebuild - _diag_init_t0) * 1000,
        (_gettime() - _diag_init_t_pre_rebuild) * 1000,
        (_gettime() - _diag_init_t0) * 1000, self.chip))
end

-- Bookshelf is the topmost widget while it's on screen, so KOReader's
-- UIManager:sendEvent dispatches gestures to us alone -- FileManager
-- underneath us is NOT is_always_active, so its registered touch zones
-- (which include user-configured gestures from gestures.koplugin: corner
-- taps for night mode, edge swipes for brightness/warmth, etc.) never
-- fire on their own.
--
-- The fix: after our own children get first crack, walk FM's touch
-- zones for events we didn't consume. The walk is FILTERED to
-- KOReader-native zones only:
--
--   * FM's own zones (id prefix "filemanager_") -- the top-edge tap
--     and swipe that open the FM menu (filemanager_tap, _ext_tap,
--     _swipe on FM.menu); FM's east/west file-chooser swipe at the
--     FM root, consumed by our own SwipeNextPage / SwipePrevPage
--     above this walk before it would otherwise fire.
--
--   * gestures.koplugin zones whose id is a key in
--     fm.gestures.gestures -- i.e., gestures the user has actually
--     configured. The Gestures plugin is attached at fm.gestures by
--     FM's registerModule. Unconfigured gestures.koplugin zones are
--     skipped here (their handler no-ops via the action_list == nil
--     branch anyway).
--
-- Third-party plugins that register FM-level touch zones (SimpleUI's
-- bottom navbar / top header, etc.) are blocked across the whole
-- screen so a tap, hold, or swipe in a gap of our layout can't put
-- another widget in front of us. Stale state from that scenario was
-- the motivation: bookshelf's plugin-menu entry would still say
-- "Close Bookshelf" while bookshelf wasn't the visible widget,
-- because another plugin's zone had taken over the foreground.
--
-- We only walk FM's _ordered_touch_zones and FM.menu's -- NOT
-- fm:handleEvent -- to avoid propagating into FM's child widget tree
-- (which would risk activating the file list underneath us).
--
-- Replaces a prior geometric absorber + bottom-corner carveout: same
-- observable behaviour for stock KOReader paths (corner taps via
-- gestures.koplugin, top-edge tap/swipe to menu via filemanager_*),
-- with the third-party back door closed everywhere on screen rather
-- than just inside the absorbed [side_m, w - side_m] × [top_m, h]
-- rectangle. The hold_release leak from a pagination hold (chev
-- hold_callback rebuilds the footer, destroying the originating
-- Button, then the release arrives at the new Button) is still
-- handled: gestures.koplugin doesn't register hold_release types and
-- filemanager_* doesn't either, so the release finds no allowed zone
-- and falls cleanly to return false (the event dies; UIManager only
-- delivers to the topmost widget, so nothing further sees it).
function BookshelfWidget:handleEvent(event)
    -- Two dispatch problems to fix, both stemming from KOReader's
    -- UIManager:sendEvent only delivering events to the topmost widget
    -- (us) and not propagating unhandled events down the window stack to
    -- FileManager (which is NOT is_always_active):
    --
    --   1. Gesture events (input → onGesture). See block comment above
    --      for the filtered FM-zone walk that handles these.
    --
    --   2. Dispatcher-emitted action events (e.g. IncreaseFlIntensity
    --      from a brightness gesture, ToggleNightMode, etc.). These are
    --      sent via UIManager:sendEvent and die in our widget. For any
    --      non-gesture event we don't consume ourselves, forward it to
    --      fm:handleEvent so FM's registered modules (DeviceListener,
    --      etc.) get a chance. Side-effect: events delivered via
    --      broadcastEvent (Suspend, Resume, etc.) get double-handled --
    --      FM gets them via the broadcast loop AND via our forward.
    --      Accepted because the relevant broadcast events are idempotent.
    if event.handler == "onGesture" then
        -- While a gesture-unlock screensaver is showing, don't touch the
        -- gesture at all -- let it reach the modal ScreenSaverLock widget
        -- that's waiting for the "Exit sleep screen" gesture. Consuming
        -- it here (or firing an FM zone via the walk below) can stop the
        -- device from waking when bookshelf is the home and the exit
        -- gesture is a corner tap (issue #84). Device.screen_saver_lock
        -- is true only in that gesture-lock window, so normal use is
        -- unaffected.
        if Device.screen_saver_lock then return false end

        -- Children first: let our own widget tree (chevron buttons, chip
        -- strip, hero, shelf covers, swipe zones) consume the gesture
        -- before falling through to FM. KOReader's normal dispatch is
        -- parent → child via propagateEvent; pre-empting with FM zones
        -- would strip that priority.
        if InputContainer.handleEvent(self, event) then return true end

        local fm = require("apps/filemanager/filemanager").instance
        if not fm then return false end
        local ev = event.args[1]
        local user_gestures = (fm.gestures and fm.gestures.gestures) or {}

        -- Walk every FM module's touch zones, not just fm + fm.menu.
        -- KOReader v2026.03 on Kobo / SimpleUI navbar setups registers
        -- the menu-open zones (filemanager_tap / _ext_tap / _swipe) on
        -- FM modules other than fm.menu, which the old fm + fm.menu
        -- walk missed entirely -- leaving the user unable to open the
        -- KOReader menu from inside bookshelf (issue #79).
        --
        -- FileManager:registerModule (filemanager.lua:385) stores each
        -- module both at self[name] AND via table.insert(self, ...), so
        -- ipairs(fm) reaches every registered module in registration
        -- order. We collect each module's _ordered_touch_zones.
        --
        -- Explicit exception: fm.file_chooser. It's the Menu widget for
        -- the file list painted underneath bookshelf; its row-tap /
        -- row-hold zones cover the body area, so a tap in a gap of
        -- bookshelf's layout could otherwise open an unintended file.
        -- The filemanager_* prefix filter below is a secondary safety
        -- net (file_chooser zones have generic Menu IDs), but excluding
        -- it explicitly keeps the contract obvious.
        local zone_lists = { fm._ordered_touch_zones }
        for _, child in ipairs(fm) do
            if child ~= fm.file_chooser
               and type(child) == "table"
               and child._ordered_touch_zones then
                zone_lists[#zone_lists + 1] = child._ordered_touch_zones
            end
        end
        for _i, zones in ipairs(zone_lists) do
            for _i, tzone in ipairs(zones) do
                local id = tzone.def and tzone.def.id
                local allowed = id and (id:find("^filemanager_")
                                        or user_gestures[id])
                if allowed
                   and tzone.gs_range:match(ev)
                   and tzone.handler(ev) then
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
                or e.kind == "format" or e.kind == "rating"
                or e.kind == "language" then
            out[#out + 1] = { kind = e.kind, label = e.label }
        end
        -- Other kinds (transient overlays) are deliberately not persisted.
    end
    return out
end

-- Debounce window for the coalesced nav-state flush. Rapid pagination /
-- chip-cycling writes nav state in-memory each time and resets this timer,
-- so the disk write happens once, ~this many seconds after the user settles.
local NAV_FLUSH_DELAY = 3

-- _persistNavState(): saves chip / page / drill path to settings. Called
-- after every _rebuild AND every _swapShelvesInPlace pagination so the
-- user's exact spot survives KOReader restart (chip already had its own
-- persistence at line 487; page and drill are new).
--
-- Writes are DEFERRED (in-memory saveSetting, no per-call flush). Each
-- Store.save previously flushed the whole bookshelf.lua file, so the four
-- calls here cost four synchronous disk writes (~550ms total on Kindle
-- flash) on EVERY rebuild and EVERY page-turn -- the single largest hidden
-- cost in the render path, and pure waste since nav state is a restore-my-
-- spot convenience, not durable data. Instead we write in-memory and
-- schedule one coalesced flush (debounced via NAV_FLUSH_DELAY), with a
-- guaranteed flush at close / suspend / onFlushSettings so durability still
-- lands at every real boundary. bookshelf.lua is a standalone LuaSettings
-- file NOT covered by G_reader_settings autosave, so we must own these
-- flush points ourselves.
function BookshelfWidget:_persistNavState()
    local drill = self:_serializeDrillPath()
    -- Change-guard: _rebuild runs on many non-navigation events (cover-
    -- extraction polls, onResume, metadata refreshes), and each call used to
    -- mark the state dirty and schedule a flush even when chip / cursor / page
    -- / drill were identical -- a needless full rewrite of bookshelf.lua (flash
    -- wear). Skip entirely when nothing actually moved since the last persist.
    local snap = {}
    for _i, e in ipairs(drill) do
        snap[#snap + 1] = (e.kind or "") .. "\2" .. (e.path or e.query or e.label or "")
    end
    snap = tostring(self.chip) .. "\1" .. tostring(self._cursor) .. "\1"
        .. tostring(self.page) .. "\1" .. table.concat(snap, "\3")
    if snap == self._nav_snapshot then return end
    self._nav_snapshot = snap

    BookshelfSettings.saveDeferred("active_chip", self.chip)
    -- Cursor is the primary persisted state; active_page is also written
    -- for back-compat with older bookshelf versions that didn't know
    -- about active_cursor (a user downgrading mid-development should
    -- still land on a sensible page).
    BookshelfSettings.saveDeferred("active_cursor", self._cursor)
    BookshelfSettings.saveDeferred("active_page", self.page)
    BookshelfSettings.saveDeferred("drill_path", drill)
    self._nav_dirty = true
    self:_scheduleNavFlush()
end

-- Schedule (or reschedule) the coalesced nav-state flush. Cancels any
-- pending flush first so a burst of page-turns collapses to a single disk
-- write fired NAV_FLUSH_DELAY seconds after the LAST navigation.
function BookshelfWidget:_scheduleNavFlush()
    if self._nav_flush_cb then UIManager:unschedule(self._nav_flush_cb) end
    self._nav_flush_cb = function()
        self._nav_flush_cb = nil
        self:_flushNavStateNow()
    end
    UIManager:scheduleIn(NAV_FLUSH_DELAY, self._nav_flush_cb)
end

-- Flush pending nav state to disk immediately and cancel any pending
-- debounced flush. Called at lifecycle boundaries (close / suspend /
-- onFlushSettings) so the deferred write is never lost on a clean exit.
-- No-op when nothing is pending, so it doesn't trigger a pointless full
-- file write on, e.g., a suspend with no navigation since the last flush.
function BookshelfWidget:_flushNavStateNow()
    if self._nav_flush_cb then
        UIManager:unschedule(self._nav_flush_cb)
        self._nav_flush_cb = nil
    end
    if self._nav_dirty then
        self._nav_dirty = nil
        BookshelfSettings.flush()
    end
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
                or e.kind == "rating" or e.kind == "language" then
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
    -- A structural rebuild (chip switch, drill, settings change) invalidates
    -- any in-flight next-page preload — it was queued for the old view.
    if self._cancelPreload then self:_cancelPreload() end
    -- Kick off chip preload as a deferred one-shot. Internally gated: returns
    -- immediately if already done, in-flight, disabled, or drilled in. nextTick
    -- so it runs after this rebuild's paint queue drains.
    UIManager:nextTick(function() self:_maybeStartChipPreload() end)
    -- Start (or keep alive) the periodic file-poll so books sideloaded by
    -- Syncthing / Calibre / KOReader's network browser appear without a
    -- manual swipe-down refresh. Internally gated -- idempotent, returns
    -- immediately if already polling.
    UIManager:nextTick(function() self:_startFilePoll() end)
    -- Detect external toggles of KOReader's "Folders and files mixed"
    -- setting. The menu callback flips collate_mixed in G_reader_settings
    -- and refreshes the File Browser, but doesn't dispatch an Event we
    -- could subscribe to. Polling at the top of every _rebuild is
    -- effectively free (one boolean read) and catches both menu toggles
    -- and dispatcher actions. When the value changed since last build,
    -- wipe the All shape cache so the next getAll picks up the new
    -- folders-first vs interleaved layout.
    do
        local current_mixed = G_reader_settings
                              and G_reader_settings:isTrue("collate_mixed") or false
        if self._last_collate_mixed ~= nil
           and self._last_collate_mixed ~= current_mixed then
            local Repo = require("lib/bookshelf_book_repository")
            if Repo.invalidateAllCache then Repo.invalidateAllCache() end
        end
        self._last_collate_mixed = current_mixed
    end

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
    -- Footer reservation. The footer row (chev nav, plus selection
    -- bucket+✕ when in select mode) is anchored to the SCREEN BOTTOM
    -- via a BottomContainer in the outer OverlapGroup — it is NOT
    -- flowed in inner_vgroup. The buttons have their own padding
    -- (hit_extension) baked into their hitboxes, so we place the
    -- footer flush with the screen edge — a tap on the very bottom
    -- pixel still lands inside a button.
    --
    -- FOOTER_H matches the chev BUTTON's actual outer height so the
    -- chev row and the bucket/X icons all occupy hitboxes of the same
    -- height. The button's outer size is constant regardless of focus
    -- state — bordersize and margin swap when focused, but together
    -- they always reserve 2*focus_border of outer space.
    --   outer = chev_size + 2*focus_border + hit_extension
    local FOOTER_H             = Screen:scaleBySize(32) + 2 * Screen:scaleBySize(4)
                                 + Screen:scaleBySize(12)
    local FOOTER_BOTTOM_MARGIN = 0
    local footer_h             = FOOTER_H + FOOTER_BOTTOM_MARGIN
    local label_h              = footer_h

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
    -- Only the PATH is needed for the selected-state comparison below, so
    -- use currentFilepath() - the full getCurrent() pays a BIM cover-blob
    -- decode + DocSettings parse, and this runs on every chip-bar rebuild
    -- (issue #103's side door).
    local _lastfile_fp = Repo.currentFilepath and Repo.currentFilepath()
    -- The "currently reading" chip's selected state means "the lastfile is
    -- the book the hero is showing right now". In expanded mode there's no
    -- visible hero, so the chip is always deselected — tapping it acts as
    -- "restore hero on the lastfile" (clears _expanded AND _preview_book).
    -- In micro mode the hero shows the module grid, not the lastfile, so the
    -- "currently reading" chip is deselected (the "modules" chip owns the
    -- active triangle instead — only one can point at the hero at a time).
    local current_in_hero = (self._hero_mode ~= "micro")
        and (not self._expanded)
        and ((not self._preview_book)
             or (_lastfile_fp and self._preview_book.filepath == _lastfile_fp))
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
    -- Kobo virtual library: a synthetic nav chip, present only when the user has
    -- opted into the beta AND OGKevin's kobo.koplugin is installed + active (Kobo
    -- devices only). isAvailable() is cheap + false everywhere else, so the chip
    -- never appears on non-Kobo devices or without the opt-in.
    if BookshelfSettings.isTrue("kobo_shelf") then
        local ok_kobo, KoboSource = pcall(require, "lib/bookshelf_kobo_source")
        if ok_kobo and KoboSource and KoboSource.isAvailable() then
            active_chips[#active_chips + 1] = { key = "kobo", label = _("Kobo") }
        end
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
        -- Deferred: this runs inside the rebuild path, whose
        -- _persistNavState owns the coalesced flush. A sync save here
        -- cost a full settings-file write (~140ms on Kindle flash).
        BookshelfSettings.saveDeferred("active_chip", self.chip)
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
    -- "Micro modules" hero toggle at the right end, after search. Like the
    -- "currently reading" chip it's an action chip that renders an upward
    -- triangle when active, pointing at the hero slot it controls; the two
    -- are mutually exclusive (current_in_hero is gated off in micro mode), so
    -- exactly one points at the hero at any time. Nerd-font glyph U+EC6F
    -- (view-grid) → UTF-8 EE B1 AF.
    -- Only present when the hero micro-module surface is on; the full-screen
    -- button and start-menu surfaces have their own access points, not a chip.
    if BookshelfSettings.microInHero() then
        active_chips[#active_chips + 1] = {
            key        = "modules",
            nerd_glyph = "\xEE\xB1\xAF",
            action     = true,
            -- Action chip, but long-pressable: routes to on_hold("modules")
            -- (the micro-module options menu) rather than the tab editor.
            holdable   = true,
            -- Deselected while expanded (the grid is hidden behind the strip),
            -- mirroring the "currently reading" chip's expanded-mode behaviour;
            -- tapping it then restores the grid.
            selected   = (self._hero_mode == "micro") and (not self._expanded),
        }
    end
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

    -- Natural shelf row dimensions: n_cols covers fill content_w with the
    -- inter-cover gap, preserving the 2:3 cover aspect ratio. n_cols is the
    -- same in both modes; the only per-mode difference is the gap (book_gap
    -- below), so covers are a touch larger in collapsed mode and natural in
    -- expanded. Pagination y stays fixed within a mode.
    local n_cols         = self:_nCols()
    -- book_gap tightens the inter-cover gap at the "small" bookshelf size so
    -- covers render a touch larger; full PAD at other sizes. Used for the
    -- shelf-row layout + cover spec only -- outer/inter-row PAD is unchanged.
    -- Applied in BOTH modes. The expanded row COUNT (_maxRows) deliberately
    -- stays on full PAD, so a wider book_gap cover doesn't cost a row: instead
    -- it's filled into the (full-PAD-budgeted) slot, which is a touch shorter
    -- than the cover's natural 2:3 -- i.e. covers come out wider and slightly
    -- vertically compressed rather than dropping the bottom row.
    local book_gap       = self:_bookGap(PAD)
    local slot_w_natural = math.floor((content_w - book_gap * (n_cols - 1)) / n_cols)
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
    -- total_pad: sum of vertical padding/gaps in inner_vgroup. Only ONE
    -- outer PAD now (the top margin) — the footer is screen-anchored,
    -- not flowed inside the outer VerticalGroup, so there's no outer
    -- bottom VerticalSpan eating space below the inner_content.
    local total_pad = PAD                                      -- outer top
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
                            or self:_currentHeroBook()
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
        -- Cap shelf_h so covers don't grow past the ShelfRow stretch cap
        -- (5% over natural 2:3). With a label, the strip claims its share
        -- of vertical real estate before the cap kicks in; with label_mode
        -- = "none", the whole row is cover. Mirrors ShelfRow's bounds so
        -- inter-row slack is distributed cleanly below instead of leaking
        -- into oversized covers.
        local label_mode = BookshelfSettings.read("expanded_shelf_label") or "none"
        if label_mode ~= "title" and label_mode ~= "author" and label_mode ~= "series" then
            label_mode = "none"
        end
        local title_block_h = 0
        if label_mode ~= "none" then
            local label_scale     = BookshelfSettings.read("expanded_shelf_font_scale") or 100
            local title_face_size = math.floor(14 * label_scale / 100 + 0.5)
            title_block_h = Size.padding.default + math.floor(title_face_size * 1.3)
        end
        local capped_shelf_h = math.floor(slot_h_natural * 1.05) + title_block_h
        if shelf_h > capped_shelf_h then shelf_h = capped_shelf_h end
        hero_h = strip_minimum
    else
        -- Hero-fraction model. `available` = hero_h + sum(shelf_h) (pads
        -- already removed via total_pad). Hero gets its target share; the rows
        -- (count from _baseShelves) split the rest, each clamped to ShelfRow's
        -- squash/stretch band so covers fill the row. The hero absorbs any
        -- leftover, so it's always >= its target (never starved).
        local available  = self.height - chip_contrib - label_h - total_pad
        -- Columns/Rows model: the hero auto-sizes from the leftover space, so
        -- hero_target is just the MINIMUM floor (HERO_MIN_FRAC). n_shelves
        -- (_baseShelves) is already clamped to _maxShelfRows so the rows at
        -- natural cover height plus this floor always fit; the hero then
        -- takes whatever vertical slack remains above the floor — fewer rows
        -- = a bigger hero, more rows = a smaller one.
        local hero_target = math.floor(available * HERO_MIN_FRAC)
        local lo = math.floor(slot_h_natural * SHELF_PACK_FLOOR)
        -- Cap shelf height at natural 2:3 (no vertical stretch). Spare
        -- vertical slack flows to the hero instead of inflating the shelf
        -- covers off-aspect -- the hero wins the leftover-space competition,
        -- and every cover (hero + shelves) renders at a matching 2:3 ratio.
        -- (Floor stays at SHELF_PACK_FLOOR=1.0: squashing below natural would
        -- shrink covers horizontally too, reopening the PW5 side-gap problem.)
        local hi = math.floor(slot_h_natural * 1.0)
        local raw = math.floor((available - hero_target) / n_shelves)
        shelf_h = math.max(1, math.min(hi, math.max(lo, raw)))
        hero_h  = math.max(hero_target, available - n_shelves * shelf_h)
    end

    local hero_cover_w, hero_cover_h
    if self._expanded then
        hero_cover_w = hero_cover_w_natural
        hero_cover_h = hero_cover_h_natural
    else
        hero_cover_h = math.max(1, hero_h)
        hero_cover_w = math.max(1, math.floor(hero_cover_h / 1.5))
        -- hero_cover_w is derived from the VERTICAL hero_h, so on a tall/narrow
        -- screen it can come out WIDER than content_w. HeroCard then computes
        -- right_w = content_w - cover_w - pad < 0, and a TextWidget with
        -- max_width <= 0 aborts makeLine in native code (no Lua crash.log) --
        -- the size-dependent crash in issue 87 (e.g. cov_w=384 > content_w=366
        -- -> right_w=-29). Cap the cover width at HERO_COVER_MAX_FRAC of
        -- content_w so the details column always keeps room, shrinking the
        -- height to preserve 2:3. No-op where hero_h/1.5 is already under it.
        local max_cover_w = math.max(1, math.floor(content_w * HERO_COVER_MAX_FRAC))
        if hero_cover_w > max_cover_w then
            hero_cover_w = max_cover_w
            hero_cover_h = math.max(1, math.floor(hero_cover_w * 1.5))
        end
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
        -- Expanded (swipe-up) collapses the hero to the thin status strip and
        -- frees a shelf row — in BOTH modes. In micro mode this is the
        -- "hide the micro modules" affordance; swipe-down (or tapping the
        -- modules chip) restores the grid.
        hero = self:_buildExpandedStrip(content_w, hero_h, PAD)
    elseif self._hero_mode == "micro" then
        -- Micro-module grid (with the full-width status line pinned above it,
        -- same as the expanded strip) fills the content_w × hero_h slot the
        -- book hero would.
        hero = self:_buildMicroHero(content_w, hero_h, PAD)
        -- No HeroCard is mounted under the grid; clear the stale reference so
        -- the in-place hero / right-column swap paths (status ticks, rating,
        -- description) no-op on a grid instead of touching a detached card.
        self._hero_card = nil
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
    -- Each crumb is just its label. The chip pill already conveys what
    -- kind of drill the user is in (Authors / Series / Genres / etc.),
    -- the chevron separators make the nesting obvious, and the names
    -- themselves are clear enough in context that prefixing every
    -- crumb with "Author: ", "Series: ", "Folder: " read as noise.
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
        chip_pill_label = _("Search results")
    else
        local _t = TabModel.getById(self.chip)
        chip_pill_label = (_t and _t.label) or self.chip
        -- When a drilldown is active AND the deepest entry's kind is a
        -- different "view" than the active chip's source.kind, override
        -- the chip pill label so the breadcrumb reads correctly. Example:
        -- the user is on the Genres chip, taps an Author pill in the
        -- long-press menu — without this override the breadcrumb says
        -- "Genres > Author X", which is misleading. With it the chip
        -- pill changes to "Authors" so the breadcrumb is "Authors > X".
        -- Active chip stays unchanged; only the label is decoupled from
        -- self.chip for the duration of the cross-kind drill.
        local tip = self._drilldown_path[#self._drilldown_path]
        if tip and tip.kind then
            local DRILL_LABEL = {
                author = _("Authors"),
                series = _("Series"),
                genre  = _("Genres"),
                tag    = _("Tags"),
                folder = _("Folder"),
                rating = _("Ratings"),
            }
            local chip_kind = (_t and _t.source and _t.source.kind) or self.chip
            local plural_for_chip = {
                authors = "author", series = "series", genres = "genre",
                tags = "tag", all = "folder", library = "folder",
            }
            -- Only override when the drilled kind doesn't match the chip's
            -- own kind (so the user can still tap "Authors" chip → drill
            -- into an author group, and the breadcrumb reads "Authors >
            -- X" via the chip's own label, no override needed).
            if plural_for_chip[chip_kind] ~= tip.kind and DRILL_LABEL[tip.kind] then
                chip_pill_label = DRILL_LABEL[tip.kind]
            end
        end
    end
    -- ChipBar prefixes a chevron-left glyph automatically; we just
    -- supply the bare label.
    local back_label = in_search_mode and _("Back") or nil
    local chips = not hide_chip_bar and ChipBar:new{
        chips             = active_chips,
        active            = self.chip,
        selected_key      = self.chip,   -- seeds the chip page (infinite-chips)
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
        -- Page changed (swipe/chevron): warm the chips the new page reveals.
        on_page_change = function() self:_queueWarmForVisible() end,
        on_change = function(key)
            -- Search "chip" is an action, not a navigable tab — open
            -- the search dialog and bail before switching self.chip.
            if key == "search" then
                self:_openSearchDialog()
                return
            end
            -- "Micro modules" chip: switch the hero to the module grid.
            -- Mutually exclusive with the book hero — clears _expanded so
            -- the grid claims the full (non-strip) hero slot. No-op when
            -- already in micro mode (mirrors the "current" chip's no-op
            -- when already selected). Full rebuild: the chip's own selected
            -- state and the "current" chip's both flip.
            if key == "modules" then
                -- No-op only when the grid is already visible; when collapsed
                -- (expanded strip showing) this restores it, like swipe-down.
                if self._hero_mode == "micro" and not self._expanded then return end
                local was_expanded = self._expanded
                self:_clearDpadFocus()
                self._hero_mode = "micro"
                self._hero_page = 1 -- always enter the grid on the first page
                self:_setExpanded(false)
                require("lib/bookshelf_start_menu_modules").bumpGeneration()
                if was_expanded then
                    -- Leaving expanded mode also changes the shelf row count,
                    -- so the whole layout shifts — full refresh.
                    self:_rebuild()
                    UIManager:setDirty(self, "ui")
                else
                    -- Book hero <-> grid: same hero height, shelves unchanged,
                    -- so scope the refresh to the hero + chip band instead of
                    -- flashing the whole screen.
                    self:_rebuildRefreshHeroAndChips()
                end
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
                -- The drill-down path is preserved: the user is asking
                -- to pop their open book back into the hero slot, not
                -- to leave the stack/folder they're browsing.
                local was_expanded = self._expanded
                local prior_fp = self._preview_book and self._preview_book.filepath
                local lastfile_fp = Repo.currentFilepath and Repo.currentFilepath()
                self:_clearDpadFocus()
                self._hero_mode    = "current"
                self._preview_book = nil
                self:_setExpanded(false)
                if was_expanded then
                    -- Leaving expanded mode shifts the shelf row count — full
                    -- refresh.
                    self:_rebuild()
                    UIManager:setDirty(self, "ui")
                else
                    -- Only the hero + chips change; scope the refresh to that
                    -- band rather than flashing the whole screen.
                    self:_rebuildRefreshHeroAndChips()
                    -- If a non-lastfile book was previewed and is showing a
                    -- highlight ring on a visible shelf cover, clear it with a
                    -- scoped per-cover repaint (otherwise the ring lingers,
                    -- which is what previously forced a full refresh here).
                    if prior_fp and prior_fp ~= lastfile_fp then
                        self:_repaintSelectionHighlight(prior_fp, nil)
                    end
                end
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
            -- Deferred: _rebuild's _persistNavState saves + schedules the
            -- coalesced flush; a sync save here added a ~140ms file write
            -- to every chip tap.
            BookshelfSettings.saveDeferred("active_chip", key)
            self:_rebuildRefreshBelowHero()
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
            -- The modules chip isn't an editable tab; its long-press opens the
            -- micro-module options menu instead of the tab editor.
            if key == "modules" then
                self:_showModulesOptions()
                return
            end
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
            placeholder_text = _("No collections yet · Long-press a book and tap 'Collections…' to create one")
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
        -- Status-filtered chips (custom chips whose source is e.g. "all"
        -- but whose filter narrows to status=reading / finished / etc.)
        -- fall into one of the branches above with a generic message. The
        -- filter is the actual reason there are no books, so override the
        -- placeholder when statuses are set.
        if _tab and _tab.filter and Filter.isActive(_tab.filter) then
            local label = _tab.label or self:_chipLabel()
            placeholder_text = string.format(
                _("Nothing in %s yet \xC2\xB7 Long-press the chip to edit its filter"),
                label)
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
        -- The placeholder card stops short of the screen-anchored footer
        -- (pagination + bulk-select bar). Without subtracting footer_h
        -- the card extended through the bottom of the screen and the
        -- footer chrome painted on top of the card border / set-home
        -- button.
        local card_h
        if hide_chip_bar then
            card_h = self.height - 3 * PAD - hero_h - footer_h
        else
            card_h = self.height - 4 * PAD - hero_h - chip_h - footer_h
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
        local hl_face, hl_bold = BFont:getFace("infofont", 22, { bold = true })
        card_children[#card_children + 1] = TextBoxWidget:new{
            text      = headline_text,
            face      = hl_face,
            bold      = hl_bold,
            bgcolor   = card_bg,
            width     = card_inner_w,
            alignment = "center",
        }
        if sub_text and sub_text ~= "" then
            card_children[#card_children + 1] = VerticalSpan:new{
                width = Size.padding.large,
            }
            local sub_face, sub_bold = BFont:getFace("infofont", 15)
            card_children[#card_children + 1] = TextBoxWidget:new{
                text      = sub_text,
                face      = sub_face,
                bold      = sub_bold,
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
        local empty_frame = FrameContainer:new{
            bordersize = 0,
            padding    = PAD,
            background = paper_bg,
            -- Force the page background to fill the whole screen so the
            -- underlying FileManager doesn't bleed through below the content.
            width      = self.width,
            height     = self.height,
            empty_vgroup,
        }
        -- Wrap with OverlapGroup so the screen-anchored footer (with the
        -- selection bucket+✕, when active) can render on the empty-library
        -- screen too.
        local OverlapGroup    = require("ui/widget/overlapgroup")
        local BottomContainer = require("ui/widget/container/bottomcontainer")
        local empty_overlap = OverlapGroup:new{
            dimen           = Geom:new{ w = self.width, h = self.height },
            allow_mirroring = false,
            empty_frame,
        }
        -- Always build the footer on an empty tab: it hosts the start-menu
        -- hamburger (and, in selection mode, the bucket+✕ bar). The gate
        -- used to be `if self._selection:isActive()`, which dropped the
        -- launcher whenever a tab had no items -- e.g. an empty Series tab
        -- left the user with no way to open the start menu.
        local empty_footer = self:_buildFooterRow(content_w, 1, FOOTER_H)
        empty_overlap[#empty_overlap + 1] = BottomContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height - FOOTER_BOTTOM_MARGIN },
            empty_footer,
        }
        self[1] = empty_overlap
        logger.dbg(string.format("[bookshelf perf] _rebuild: EMPTY total=%.0fms chip=%s",
            (_gettime() - _perf_t0) * 1000, _perf_chip))
        return
    end

    local rows = self:_buildShelfRows(items, content_w, shelf_h, book_gap, n_shelves)
    local _perf_t3 = _gettime()
    logger.dbg(string.format("[bookshelf perf] _rebuild: shelves=%.0fms",
        (_perf_t3 - _perf_t2) * 1000))
    -- Footer row (chev nav + optional selection bucket/✕) is built
    -- BELOW after the inner_vgroup is composed — it's anchored at the
    -- screen bottom in the outer OverlapGroup, not flowed in
    -- inner_vgroup.

    -- Kick off BIM extraction for any displayed books with no cached
    -- metadata. Cover-spec dims = single shelf slot (book_gap so the
    -- extracted cover matches the rendered, slightly-larger small-size slot).
    local slot_w  = math.floor((content_w - book_gap * (n_cols - 1)) / n_cols)
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
    -- In expanded mode shelf_h is capped at natural 2:3 (covers don't
    -- stretch), so n_shelves × shelf_h often leaves vertical slack. Spread
    -- that slack equally across the gap below every row (including the
    -- last) so the grid reads as evenly distributed top-to-bottom — the
    -- bottom row floats up to match the inter-row spacing instead of
    -- pinning to the footer. Non-expanded mode keeps the bottom absorber
    -- (the hero already takes the slack on that path).
    local pre_rows_h      = PAD + label_h + hero_h + hero_chip_pad
                          + ((not hide_chip_bar) and (chip_h + PAD) or 0)
    local rows_block_h    = n_shelves * shelf_h + n_shelves * PAD
    local after_row_bonus = 0
    if self._expanded and n_shelves >= 1 then
        local slack = self.height - pre_rows_h - rows_block_h
        if slack > 0 then
            after_row_bonus = math.floor(slack / n_shelves)
        end
    end
    -- First shelf row index in the vgroup — stashed below for
    -- _swapShelvesInPlace's fast-path swap.
    local shelf_first_idx = #inner_vgroup + 1
    for r = 1, n_shelves do
        inner_vgroup[#inner_vgroup + 1] = rows[r]
        inner_vgroup[#inner_vgroup + 1] = VerticalSpan:new{ width = PAD + after_row_bonus }
    end
    -- Layout-slack absorber: shelf_h is computed via floor(), which can
    -- lose up to (n_shelves - 1) pixels per render. The slack VerticalSpan
    -- fills the remaining gap between the last shelf and the bottom of
    -- the inner_content (where the screen-anchored footer is reserved).
    --
    -- The footer is NOT in inner_vgroup any more. Reserved bottom space
    -- = label_h (= FOOTER_H + FOOTER_BOTTOM_MARGIN). PAD is the outer
    -- top margin. inner_vgroup must fit in (screen_h - PAD - label_h).
    local layout_sum = PAD + label_h           -- top margin + reserved bottom
                     + hero_h
                     + hero_chip_pad
                     + ((not hide_chip_bar) and (chip_h + PAD) or 0)
                     + n_shelves * shelf_h
                     + n_shelves * PAD         -- after each row
                     + n_shelves * after_row_bonus  -- expanded-mode even slack
    local layout_slack = self.height - layout_sum
    if layout_slack > 0 then
        inner_vgroup[#inner_vgroup + 1] = VerticalSpan:new{ width = layout_slack }
    end
    -- shelf_first_idx points at row 1; rows live at first, first+2, first+4
    -- (each separated by a VerticalSpan). No footer_idx in inner_vgroup
    -- now — the footer lives in the outer OverlapGroup (see below).
    self._hero_parent = inner_vgroup            -- hero lives at index 1
    self._inner_vgroup = inner_vgroup
    local inner_content = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = side_pad,
        padding_right = side_pad,
        inner_vgroup,
    }

    local main_frame = FrameContainer:new{
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
            -- No bottom VerticalSpan: the footer row below is anchored
            -- at the screen bottom independently of this VerticalGroup
            -- (which only needs to flow chips + shelves + hero).
        },
    }
    -- Footer row: chev nav centered + (when selecting) bucket+✕
    -- right-aligned. Anchored at the screen bottom via a
    -- BottomContainer wrapping a footer-row OverlapGroup. Corner
    -- absorbers (gesture pass-through suppression in select mode) are
    -- appended as separate OverlapGroup children below.
    local OverlapGroup    = require("ui/widget/overlapgroup")
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local overlap_group = OverlapGroup:new{
        dimen      = Geom:new{ w = self.width, h = self.height },
        allow_mirroring = false,
        main_frame,
    }
    -- Build the footer row and anchor it.
    local footer_row = self:_buildFooterRow(content_w, total_pages, FOOTER_H)
    overlap_group[#overlap_group + 1] = BottomContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height - FOOTER_BOTTOM_MARGIN },
        footer_row,
    }
    local footer_idx = #overlap_group   -- index of the footer in overlap_group

    -- Pagination fast-path stash: _swapShelvesInPlace re-renders only
    -- the shelf rows in inner_vgroup, plus the footer in overlap_group.
    -- Hero + chips remain untouched, avoiding the use-after-free path
    -- where a freed BIM bb on _preview_book.cover_bb gets re-rendered
    -- as different book pixels.
    self._shelf_dims = {
        content_w            = content_w,
        shelf_h              = shelf_h,
        label_h              = label_h,
        FOOTER_H             = FOOTER_H,
        FOOTER_BOTTOM_MARGIN = FOOTER_BOTTOM_MARGIN,
        PAD                  = PAD,
        book_gap             = book_gap,
        hero_cover_w         = hero_cover_w,
        hero_cover_h         = hero_cover_h,
        n_shelves            = n_shelves,
        -- Actual cover-area dims this render used (reported by ShelfRow).
        -- Drives _currentSlotDims so the preload warms next-page covers at the
        -- exact size the shelf draws -- no re-deriving the stretch/shrink/label
        -- math here. Falls back to the width-slot computation if absent.
        cover_w              = rows[1] and rows[1].cover_w,
        cover_h              = rows[1] and rows[1].cover_h,
        -- Index layout depends on whether the chip strip is in the vgroup
        -- AND on n_shelves. shelf_first_idx is the row-1 index; each row
        -- is followed by a VerticalSpan, so subsequent rows live at +2.
        shelf_top_idx        = shelf_first_idx,
        shelf_bottom_idx     = shelf_first_idx + 2 * (n_shelves - 1),
        footer_overlap_idx   = footer_idx,
    }
    self._overlap_group = overlap_group
    -- Corner-gesture absorbers in select mode: transparent InputContainers
    -- covering the outer 12.5% of each bottom corner so corner gestures
    -- (page-turn, bookmark, brightness, etc.) wired via gestures.koplugin
    -- don't fire while a selection is in flight. The selection overlay
    -- (bucket + ✕) is appended FIRST so its icons consume taps on their
    -- own hitboxes before the absorbers see them; the absorbers handle
    -- any corner taps that miss the icons.
    if self._selection:isActive() then
        local Absorber = InputContainer:extend{}
        function Absorber:onTap()  return true end
        function Absorber:onHold() return true end
        local corner_w = math.floor(self.dimen.w * 0.125)
        local corner_h = Screen:scaleBySize(80)
        local left_dim  = Geom:new{
            x = 0,
            y = self.dimen.h - corner_h,
            w = corner_w,
            h = corner_h,
        }
        local right_dim = Geom:new{
            x = self.dimen.w - corner_w,
            y = self.dimen.h - corner_h,
            w = corner_w,
            h = corner_h,
        }
        for _, dim in ipairs({ left_dim, right_dim }) do
            local a = Absorber:new{ dimen = dim }
            a.ges_events = {
                Tap  = { GestureRange:new{ ges = "tap",  range = dim } },
                Hold = { GestureRange:new{ ges = "hold", range = dim } },
            }
            overlap_group[#overlap_group + 1] = a
        end
    end
    self[1] = overlap_group
    local _perf_t4 = _gettime()
    logger.dbg(string.format("[bookshelf perf] _rebuild: assemble=%.0fms",
        (_perf_t4 - _perf_t3) * 1000))
    logger.dbg(string.format(
        "[bookshelf perf] _rebuild: TOTAL=%.0fms chip=%s page=%d/%d items=%d"
        .. " (hero=%.0f fetch=%.0f shelves=%.0f assemble=%.0f)",
        (_perf_t4 - _perf_t0) * 1000, _perf_chip, _perf_page, total_pages, total,
        (_perf_t1 - _perf_t0) * 1000,
        (_perf_t2 - _perf_t1) * 1000,
        (_perf_t3 - _perf_t2) * 1000,
        (_perf_t4 - _perf_t3) * 1000))
    local _perf_persist_t0 = _gettime()
    self:_persistNavState()
    logger.dbg(string.format("[bookshelf perf] _rebuild: persist=%.0fms",
        (_gettime() - _perf_persist_t0) * 1000))
    -- Proactive forward preload. The reactive preload (in _paginateNext/Prev)
    -- can't arm until a swipe reveals direction, so the FIRST page-turn after
    -- any rebuild is always a cold cover decode. From a freshly-settled page
    -- the user's likeliest next action is a forward swipe, so warm the next
    -- page now. No-op on the last page; _schedulePreload cancels any prior
    -- preload and re-syncs cache capacity.
    if (self._total_pages or 1) > (self.page or 1) then
        self:_schedulePreload(1)
    end
end

-- ─── Background metadata extraction ──────────────────────────────────────────

-- Adaptive polling for BIM extraction completion. The subprocess
-- commits to SQLite per-book (bookinfomanager.lua's set_stmt:step at
-- line ~484), so we can observe per-book progress and refresh covers
-- as they appear instead of batching at the end. Start fast for
-- perceived real-time feedback; back off if a poll finds no new
-- metadata (BIM stuck on a slow book / book skipped). Resets to the
-- fast end whenever ANY book completes (_armExtractionPoll re-runs
-- through _swapShelvesInPlace -> _kickOffMissingMetaExtraction). The
-- 60s total wall-clock budget protects against runaway polling when
-- BIM has effectively abandoned the queued books.
local BIM_POLL_INTERVALS_S    = { 0.4, 0.6, 1.0, 2.0, 3.0 }
local BIM_POLL_TOTAL_BUDGET_S = 60

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
    -- Two extraction specs, by where the book is shown:
    --   * HERO book -> hero-sized spec (the currently-reading card is the
    --     one place a cover is drawn large, so it earns the bigger bitmap).
    --   * Every other book -> SLOT-sized spec. Those only ever appear in a
    --     shelf cell, and BIM stores ONE bb per book at the largest size ever
    --     requested. Judging shelf covers against the hero target re-queued
    --     covers that already dwarf the slot (e.g. 446x696 cached vs a
    --     ~225x337 small-size slot) as "cover-too-small"; worse, the hero
    --     target drifts with layout/mode/preview, so the same covers crossed
    --     the 0.8 tolerance back and forth and re-extracted on every page
    --     (the per-page shimmer). Slot-sized covers downscale cleanly and
    --     the target is stable, so each book heals once and stays put.
    -- The hero book is queued FIRST (below) so seen[] keeps its larger spec
    -- when the same book also appears in a shelf row.
    local slot_specs = {
        max_cover_w = slot_w,
        max_cover_h = slot_h,
    }
    local hero_specs = {
        max_cover_w = math.max(slot_w, hero_w or slot_w),
        max_cover_h = math.max(slot_h, hero_h or slot_h),
    }
    local function maybe_queue(fp, specs)
        if not fp or seen[fp] then return end
        seen[fp] = true
        -- pcall-guarded: BIM can throw a SQLite error when its DB is being
        -- recreated mid-import (issue #71, same family as #63). Without this
        -- the error escapes _rebuild and crashes KOReader.
        local ok_bim, info_or_err = pcall(BIM.getBookInfo, BIM, fp, false)
        if not ok_bim then
            logger.warn("[bookshelf] BIM getBookInfo failed for", fp, ":",
                        tostring(info_or_err))
            return
        end
        local info = info_or_err
        local needs   = false
        local reason  = "?"
        local inprog  = tonumber(info and info.in_progress) or 0
        if not info then
            needs  = true
            reason = "no-row"
        elseif info.has_meta == nil and inprog < max_tries then
            needs  = true
            reason = "no-meta"
        elseif info.has_meta == nil then
            reason = "no-meta-but-max-tries"
        elseif info.cover_fetched == nil and inprog < max_tries then
            -- Metadata was extracted (e.g. by "Scan all library metadata")
            -- but no cover attempt has been made yet.
            needs  = true
            reason = "no-cover-attempt"
        elseif info.cover_fetched == nil then
            reason = "no-cover-attempt-but-max-tries"
        elseif info.has_cover == "Y" and inprog < max_tries
                and BookshelfWidget._coverNeedsResize(info, specs) then
            -- Cached cover was extracted at a smaller spec than the current
            -- slot needs (e.g. the user previously browsed in FM list-mode,
            -- which extracts at ~30px wide; bookshelf wants ~150px). Re-queue
            -- so BIM's subprocess overwrites the row with a sharper thumbnail.
            -- The helper applies a tolerance band so we don't thrash on minor
            -- dimension changes — important since extraction is expensive.
            needs  = true
            reason = "cover-too-small"
        elseif info.has_cover == "Y" then
            reason = "cover-ok"
        elseif info.has_cover ~= "Y" then
            reason = (inprog >= max_tries) and "no-cover-given-up" or "no-cover-fetched"
        end
        logger.dbg(string.format(
            "[bim queue] fp=%s queue=%s reason=%s in_progress=%d has_meta=%s has_cover=%s cover_fetched=%s",
            fp, tostring(needs), reason, inprog,
            tostring(info and info.has_meta), tostring(info and info.has_cover),
            tostring(info and info.cover_fetched)))
        if needs then
            files[#files + 1] = {
                filepath    = fp,
                cover_specs = specs,
            }
        end
    end
    -- Hero book (preview / lastfile) FIRST, at hero size. It may not appear
    -- in the visible shelf items — e.g. series drilldown shows other titles
    -- in the series while the hero stays on the user's currently-reading
    -- book — so queue it explicitly. Queued before the shelf loop so seen[]
    -- keeps its larger hero_specs if the same book also sits in a shelf row.
    local hero_fp
    if self._preview_book and self._preview_book.filepath then
        hero_fp = self._preview_book.filepath
    else
        -- Path only - don't pay getCurrent()'s BIM read just to learn
        -- which file to queue (issue #103's side door).
        hero_fp = Repo.currentFilepath and Repo.currentFilepath()
    end
    if hero_fp then maybe_queue(hero_fp, hero_specs) end
    for _i, item in ipairs(items or {}) do
        if item then
            -- Flat-book items (Recent / Latest / drilldown) carry filepath.
            maybe_queue(item.filepath, slot_specs)
            -- Folder items (Home chip drilldown) carry first_book.
            if item.first_book then
                maybe_queue(item.first_book.filepath, slot_specs)
            end
            -- Group items (series / authors / genres / tags) carry a books
            -- array. series_stack renders books[1] as the front cover plus
            -- books[2..3] peeking out behind — queue all three so the
            -- visible stack is sharp end-to-end. Capped at 3 to keep the
            -- queue size proportional to what's actually painted.
            if item.books then
                for i = 1, math.min(3, #item.books) do
                    local b = item.books[i]
                    if b then maybe_queue(b.filepath, slot_specs) end
                end
            end
        end
    end
    logger.dbg(string.format("[bookshelf perf] _kickOffMeta: queued=%d displayed=%d",
        #files, #(items or {})))
    logger.dbg(string.format(
        "[bim kickoff] queued=%d displayed=%d bim_busy=%s",
        #files, #(items or {}),
        tostring(BIM:isExtractingInBackground())))
    if #files > 0 then
        UIManager:nextTick(function()
            -- Priority interrupt model:
            --   * BIM idle -> FIRE (start our extraction).
            --   * BIM busy + we own a TEXT-ONLY batch -> SKIP. Bulk
            --     text-only runs at ~30 ms/book and will finish in
            --     seconds; visible books get their text + series
            --     indicator from that batch, then the orphan-retry
            --     fires cover-only extractions for the visible files
            --     (text is now cached) so covers appear separately.
            --     This gives the user the "text first, cover next"
            --     UX. Interrupting here would force a full re-extract
            --     for visible books and arrive cover + text together,
            --     making the series indicator wait for the cover.
            --   * BIM busy + we own a COVER batch -> INTERRUPT. Cover
            --     work is slow (~300 ms/book) and the user's visible
            --     page should jump to the front. Whatever was queued
            --     before stays in the poll watch list (see merge in
            --     _armExtractionPoll) and the orphan-retry picks the
            --     leftovers up when BIM idles.
            --   * BIM busy + NOT owned -> SKIP. Something else (e.g.
            --     scan-all via extractBooksInDirectory, or another
            --     plugin) owns BIM; interrupting would kill its work.
            --     Pre-#68 we'd terminate-and-restart unconditionally
            --     here, which aborted a 17k-book scan at letter O when
            --     bookshelf re-paginated mid-scan.
            local bim_busy = BIM:isExtractingInBackground()
            if bim_busy then
                if not self._bim_owned_extraction then
                    logger.dbg(string.format(
                        "[bim extract] SKIP files=%d (BIM busy, not owned)",
                        #files))
                    return
                end
                -- Owned text-only batches (bulk-refresh) finish fast
                -- enough that interrupting to slot in a visible-page
                -- cover fire wasn't worth the added complexity --
                -- subjectively felt worse than just waiting for the
                -- text-only pass to finish.
                if not self._bim_owned_has_covers then
                    logger.dbg(string.format(
                        "[bim extract] SKIP files=%d (owned text-only batch)",
                        #files))
                    return
                end
                -- Subset check: if every visible file is already in
                -- BIM's current queue, don't re-fire -- re-firing kills
                -- BIM's in-flight book and we'd thrash through the
                -- N..N-1..N-2 sequence as each render-cycle after a
                -- book completes re-kickoffs with one fewer file.
                if self._bim_submitted_set then
                    local all_in_queue = true
                    for _i, f in ipairs(files) do
                        if not self._bim_submitted_set[f.filepath] then
                            all_in_queue = false
                            break
                        end
                    end
                    if all_in_queue then
                        logger.dbg(string.format(
                            "[bim extract] SKIP files=%d (all already in BIM queue)",
                            #files))
                        return
                    end
                end
            end
            self:_fireBimExtraction(files,
                bim_busy and "kickoff-interrupt" or "kickoff")
        end)
    end
    self:_armExtractionPoll(files)
end

-- _fireBimExtraction(files, label): wrapper around BIM:extractInBackground
-- that sets the ownership flag so subsequent kickoffs can tell the
-- current BIM job is ours (safe to interrupt for higher-priority work)
-- vs. someone else's (don't kill it). Also tracks whether the current
-- job is doing covers: a text-only batch (no cover_specs) finishes
-- ~10x faster than a cover batch, so the kickoff path lets text-only
-- runs complete and only interrupts cover work. `label` is for log
-- readability.
function BookshelfWidget:_fireBimExtraction(files, label)
    if not files or #files == 0 then return false end
    local ok_bim, BIM = pcall(require, "bookinfomanager")
    if not (ok_bim and BIM and BIM.extractInBackground) then return false end
    local has_covers   = false
    local submitted    = {}
    for _i, f in ipairs(files) do
        if f.cover_specs then has_covers = true end
        submitted[f.filepath] = true
    end
    logger.dbg(string.format(
        "[bim extract] FIRE files=%d label=%s covers=%s",
        #files, label or "?", tostring(has_covers)))
    local ok, err = pcall(function() BIM:extractInBackground(files) end)
    if ok then
        self._bim_owned_extraction = true
        self._bim_owned_has_covers = has_covers
        -- Set of filepaths in BIM's current queue. Kickoff uses this
        -- to detect "no new context": if every visible file is already
        -- being processed (subset of submitted), skip the kickoff to
        -- avoid the thrash where each render-cycle after one book
        -- completes re-fires extractInBackground for the N-1 still
        -- pending, killing BIM's in-flight book each time.
        self._bim_submitted_set = submitted
        return true
    end
    logger.warn(string.format(
        "[bim extract] FAILED files=%d label=%s err=%s",
        #files, label or "?", tostring(err)))
    return false
end

-- _armExtractionPoll(files): start a polling loop that watches BIM for
-- the queued filepaths and refreshes the shelf when their metadata
-- appears. Adaptive cadence (see BIM_POLL_INTERVALS_S) -- fast at the
-- start so covers appear in near-real-time as the subprocess commits
-- them, backs off if successive polls find nothing new, total
-- wall-clock budget of BIM_POLL_TOTAL_BUDGET_S. Cancels any earlier
-- polling timer so consecutive renders don't stack timers.
function BookshelfWidget:_armExtractionPoll(pending_files)
    if self._bim_poll_fn then
        UIManager:unschedule(self._bim_poll_fn)
        self._bim_poll_fn = nil
    end
    if not pending_files or #pending_files == 0 then
        -- Don't drop the existing watch list -- callers that arm with
        -- zero new files should be no-ops on the watch state. The
        -- previous behaviour (clear-on-empty) caused orphans from a
        -- prior bulk-refresh to be forgotten when a subsequent
        -- rebuild's kickoff had nothing new to queue.
        return
    end
    -- Merge into the existing watch list, de-duped by filepath. New
    -- entries' cover_specs win when both are present so the latest
    -- visible context (a kickoff arming with the user's current slot
    -- size) overrides a text-only bulk-refresh arming. This keeps the
    -- watch list as the union of "everything we want BIM to process,
    -- not yet observed complete" -- the orphan-retry path in
    -- _pollExtraction fires this list when BIM goes idle.
    local existing  = self._bim_poll_files or {}
    local idx_by_fp = {}
    for i, f in ipairs(existing) do
        idx_by_fp[f.filepath] = i
    end
    local added = 0
    for _i, nf in ipairs(pending_files) do
        local i = idx_by_fp[nf.filepath]
        if i then
            if nf.cover_specs then
                existing[i].cover_specs = nf.cover_specs
            end
        else
            existing[#existing + 1] = nf
            idx_by_fp[nf.filepath] = #existing
            added = added + 1
        end
    end
    self._bim_poll_files        = existing
    self._bim_poll_started_at   = os.time()  -- reset budget on every arm
    self._bim_poll_empty_streak = 0          -- and the burst-poll cadence
    logger.dbg(string.format(
        "[bim arm] watching %d files (added %d)", #existing, added))
    self:_scheduleExtractionPoll()
end

function BookshelfWidget:_scheduleExtractionPoll()
    if not self._bim_poll_files then return end
    local elapsed = os.time() - (self._bim_poll_started_at or os.time())
    if elapsed >= BIM_POLL_TOTAL_BUDGET_S then
        logger.dbg(string.format(
            "[bim sched] budget exhausted elapsed=%ds pending=%d -- giving up",
            elapsed, #(self._bim_poll_files or {})))
        self._bim_poll_files = nil
        return
    end
    local streak   = self._bim_poll_empty_streak or 0
    local idx      = math.min(streak + 1, #BIM_POLL_INTERVALS_S)
    local interval = BIM_POLL_INTERVALS_S[idx]
    logger.dbg(string.format(
        "[bim sched] next=%.1fs streak=%d elapsed=%ds pending=%d",
        interval, streak, elapsed, #(self._bim_poll_files or {})))
    self._bim_poll_fn = function() self:_pollExtraction() end
    UIManager:scheduleIn(interval, self._bim_poll_fn)
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
    -- Subset of ready_paths whose extraction included a COVER (had
    -- cover_specs). These need their ScaledCoverCache entry dropped before
    -- the re-render: the bb we seeded on first paint may be an UPSCALE of a
    -- too-small thumbnail (blurry), and the re-render skips re-decoding while
    -- has(fp) is true -- so without the drop it repaints the stale blurry bb
    -- and the cover only sharpens once a larger (hero) render forces a fresh
    -- decode, i.e. when the user taps it (issue #125).
    local ready_cover_paths = {}
    local still_pending = {}
    local gave_up_count = 0
    for _i, f in ipairs(files) do
        -- pcall-guarded; see maybe_queue comment for rationale (#71/#63).
        local ok_bim, info_or_err = pcall(BIM.getBookInfo, BIM, f.filepath, false)
        if not ok_bim then
            logger.warn("[bookshelf] BIM getBookInfo (poll) failed for",
                        f.filepath, ":", tostring(info_or_err))
        end
        local info = ok_bim and info_or_err or nil
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
        local outcome
        if meta_ready and inprog == 0 and cover_ready then
            ready_paths[f.filepath] = true
            if f.cover_specs then ready_cover_paths[f.filepath] = true end
            outcome = "READY"
        elseif info and inprog >= max_tries then
            -- BIM gave up on this file; stop watching it.
            outcome = "GAVE-UP"
            gave_up_count = gave_up_count + 1
        else
            still_pending[#still_pending + 1] = f
            outcome = "PENDING"
        end
        logger.dbg(string.format(
            "[bim poll] %s fp=%s in_progress=%d has_meta=%s has_cover=%s cover_fetched=%s cover_ready=%s",
            outcome, f.filepath, inprog,
            tostring(info and info.has_meta), tostring(info and info.has_cover),
            tostring(info and info.cover_fetched), tostring(cover_ready)))
    end
    local ready_count = 0
    for _k in pairs(ready_paths) do ready_count = ready_count + 1 end
    local bim_busy_now = BIM:isExtractingInBackground()
    logger.dbg(string.format(
        "[bim poll] SUMMARY ready=%d pending=%d gave_up=%d bim_busy=%s",
        ready_count, #still_pending, gave_up_count, tostring(bim_busy_now)))
    self._bim_poll_files = #still_pending > 0 and still_pending or nil
    -- Clear ownership state when BIM is observed idle. These flags
    -- describe "the BIM job we last fired" -- once that job ends,
    -- they're stale and would mislead the kickoff path's interrupt /
    -- subset decisions on the next fire.
    if not bim_busy_now and self._bim_owned_extraction then
        self._bim_owned_extraction = nil
        self._bim_owned_has_covers = nil
        self._bim_submitted_set    = nil
    end
    -- Orphan-retry: when BIM is idle and our watch list still has
    -- pending files, fire them. These are typically the leftovers
    -- from a previous fire that got interrupted by a higher-priority
    -- kickoff (priority interrupt model), or files armed by
    -- bulk-refresh that the kickoff path never saw. Without this
    -- step the leftovers sit unfetched forever.
    if #still_pending > 0 and not bim_busy_now then
        local fire_list = still_pending
        UIManager:nextTick(function()
            if BIM:isExtractingInBackground() then
                logger.dbg(string.format(
                    "[bim retry] SKIP files=%d (BIM busy at fire time)",
                    #fire_list))
                return
            end
            self:_fireBimExtraction(fire_list, "orphan-retry")
        end)
    end
    if next(ready_paths) and self._inner_vgroup and self._shelf_dims then
        -- A just-extracted cover is sharper than whatever we seeded on first
        -- paint -- which, for a thumbnail that started smaller than the slot,
        -- was an upscale (blurry). Drop those stale ScaledCoverCache entries
        -- so the re-render below decodes the fresh BIM cover instead of
        -- repainting the cached blurry bb. Without this the cover only
        -- sharpens once a larger (hero) render forces a fresh decode, i.e.
        -- when the user taps the book (issue #125). drop() is a no-op when
        -- there's no entry (the no-cover -> cover case never seeded one).
        if next(ready_cover_paths) then
            local ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
            for fp in pairs(ready_cover_paths) do ScaledCoverCache:drop(fp) end
        end
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
                -- Path only - this runs on every extraction-poll tick, so
                -- getCurrent()'s BIM read here was a per-tick tax while
                -- covers extract (issue #103's side door).
                hero_fp = Repo.currentFilepath and Repo.currentFilepath()
            end
            if hero_fp and ready_paths[hero_fp] then
                self:_swapHeroInPlace()
            end
        end
        return
    end
    -- Poll completed with no books transitioning to ready. Bump the
    -- empty-streak counter so _scheduleExtractionPoll backs off the
    -- next interval (cheap on a quiet BIM, snappy when a book lands
    -- next tick). Progress polls don't reach here -- they early-return
    -- via the ready_paths branch above, which re-runs _kickOff via
    -- _swapShelvesInPlace and _armExtractionPoll resets the streak.
    self._bim_poll_empty_streak = (self._bim_poll_empty_streak or 0) + 1
    if self._bim_poll_files then
        self:_scheduleExtractionPoll()
    end
end

-- ─── Data helpers ─────────────────────────────────────────────────────────────

-- _fetchChipItems(n)
-- Returns up to n items for the current chip (or the expanded-series flat
-- list). Sets opts.lazy_cover=true on the Repo call so the HIT hydration
-- path probes ScaledCoverCache per filepath and skips the BIM zstd decode
-- for books already cached. SpineWidget reads from the cache directly when
-- book.cover_bb arrives nil.
function BookshelfWidget:_fetchChipItems(n)
    local fetch_opts = { lazy_cover = true }
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
    -- Hydrate only the VISIBLE page slice of the combined result list
    -- (folders ++ authors ++ series ++ genres ++ books, in that order) and
    -- return the total so the caller's _total_hint pagination takes over.
    -- Previously this hydrated EVERY match -- a broad query over a large
    -- library decoded hundreds of cover BlitBuffers per render (the same
    -- unbounded-hydration shape that OOM-killed group drilldowns in
    -- issue #17). Covers already in ScaledCoverCache skip the BIM zstd
    -- decode via want_cover=false; SpineWidget repaints them from the
    -- cache by filepath key.
    if tip and tip.kind == "search" then
        local pay      = tip.payload
        local folders  = pay.folders or {}
        local authors  = pay.author_names or {}
        local series   = pay.series_names or {}
        local genres   = pay.genre_names or {}
        local book_fps = pay.book_fps or {}
        local total    = #folders + #authors + #series + #genres + #book_fps
        local offset   = math.max(0, (self._cursor or 1) - 1)
        local stop     = math.min(offset + self:_viewSize(), total)
        local ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
        local function lazyMeta(fp)
            if not fp then return nil end
            local meta_opts
            if ScaledCoverCache:has(fp) then
                meta_opts = { want_cover = false }
            end
            return Repo.buildBookMeta(fp, meta_opts)
        end
        local fresh = {}
        for i = offset + 1, stop do
            local idx, item = i, nil
            if idx <= #folders then
                local f = folders[idx]
                item = {
                    kind       = "folder",
                    path       = f.path,
                    label      = f.label,
                    first_book = lazyMeta(f.first_book_fp),
                }
            else
                idx = idx - #folders
                if idx <= #authors then
                    item = Repo.findGroup("author", authors[idx])
                else
                    idx = idx - #authors
                    if idx <= #series then
                        item = Repo.findGroup("series", series[idx])
                    else
                        idx = idx - #series
                        if idx <= #genres then
                            item = Repo.findGroup("genre", genres[idx])
                        else
                            idx = idx - #genres
                            item = lazyMeta(book_fps[idx])
                        end
                    end
                end
            end
            -- findGroup / buildBookMeta can return nil for stale
            -- identifiers (book deleted since the search ran); skip the
            -- hole -- a partial page is fine, same as the last page.
            if item then fresh[#fresh + 1] = item end
        end
        return fresh, total
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
            or tip.kind == "format" or tip.kind == "rating"
            or tip.kind == "language") then
        -- Re-apply the within-group sort on EVERY fetch, not just at drill time.
        -- A return-from-book rebuild restores the drill payload fresh, and the
        -- tag restore rebuilds .books in non-deterministic pairs() order, so
        -- without this the drilled view shows random order until you re-enter
        -- the collection (#205). Re-sorting also lets a just-opened book pick up
        -- its new last-opened position. Idempotent while paging (order is stable
        -- unless a book was opened).
        self:_applyWithinGroupSort(tip.payload)
        local books = tip.payload.books or {}
        local total = #books
        -- Cursor-based: offset is 0-based, cursor is 1-based. Clamp upstream
        -- in _rebuild keeps cursor within range; defensive guard here too.
        local offset = math.max(0, (self._cursor or 1) - 1)
        local stop = math.min(offset + self:_viewSize(), total)
        local ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
        local fresh = {}
        for i = offset + 1, stop do
            local b = books[i]
            local nb = b
            if b.filepath then
                -- Covers already in ScaledCoverCache skip the BIM zstd
                -- decode; SpineWidget repaints from the cache by filepath.
                local meta_opts
                if ScaledCoverCache:has(b.filepath) then
                    meta_opts = { want_cover = false }
                end
                nb = Repo.buildBookMeta(b.filepath, meta_opts) or b
            end
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
        return Repo.getAll(tip.payload.path, LIMIT, offset, within, nil, fetch_opts)
    end
    if tab then
        return Repo.getBySource(tab.source, tab.filter, tab.sort_priority, offset, LIMIT, fetch_opts)
    end
    return Repo.getBySource({ kind = self.chip }, nil, nil, offset, LIMIT, fetch_opts)
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
-- tap; without caching, real-device measurement shows the fan-out costs
-- ~30–50ms per hero build (frontlight probe ×3 + diskUsage statfs +
-- calcFreeMem + /proc/self/status + isCharging + getCapacity + isWifiOn).
--
-- Two-tier TTLs:
--
--   * Fast state (5s): light, light_pct, warmth, batt, charging, wifi.
--     Frontlight is gesture-toggleable in mid-browsing; 5s keeps it
--     responsive while catching consecutive chip switches (typical 2-4s
--     apart) that the previous 2s window kept missing.
--
--   * Slow state (60s): mem, ram_mib, disk_free. Disk usage is the
--     heaviest single probe (statfs) and the slowest-changing value —
--     a 1-minute resolution on a 0.1G-precision display is invisible.
--     RSS and free-mem drift on the order of MiB per minute during
--     normal browsing.
--
-- Both tiers share the same returned table; the fast tier rebuilds the
-- volatile fields and reuses the slow tier's already-resolved values
-- when its TTL hasn't expired.
local _device_state_cache      = nil
local _device_state_expires_at = 0
local DEVICE_STATE_TTL         = 5     -- seconds — fast hardware

local _device_slow_cache       = nil   -- { mem, ram_mib, disk_free }
local _device_slow_expires_at  = 0
local DEVICE_SLOW_TTL          = 60    -- seconds — disk + memory

local function _readSlowState(now)
    if _device_slow_cache and _device_slow_expires_at > now then
        return _device_slow_cache
    end
    local out = {}
    local ok_util, util = pcall(require, "util")
    if ok_util and util and util.calcFreeMem then
        local free, total = util.calcFreeMem()
        if free and total and total > 0 then
            out.mem = math.floor((1 - free / total) * 100 + 0.5)
        end
    end
    -- Single read + one match instead of fh:lines() (which allocates a
    -- string per line and walks ~25 lines before VmRSS).
    local fh = io.open("/proc/self/status", "r")
    if fh then
        local content = fh:read("*a") or ""
        fh:close()
        local kb = content:match("VmRSS:%s+(%d+)%s+kB")
        if kb then out.ram_mib = math.floor(tonumber(kb) / 1024 + 0.5) end
    end
    if ok_util and util and util.diskUsage then
        local ok_dev, Device = pcall(require, "device")
        if ok_dev and Device then
            local drive = Device.home_dir or "/"
            local ok_du, usage = pcall(util.diskUsage, drive)
            if ok_du and usage and type(usage.available) == "number" and usage.available > 0 then
                out.disk_free = string.format("%.1fG", usage.available / 1024 / 1024 / 1024)
            end
        end
    end
    _device_slow_cache      = out
    _device_slow_expires_at = now + DEVICE_SLOW_TTL
    return out
end

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
        -- PowerD keeps fl_intensity at its prior value when the user
        -- toggles the frontlight OFF -- only is_fl_on flips and the
        -- HW gets setIntensityHW(fl_min). frontlightIntensity() reads
        -- self.fl_intensity directly (no live HW probe), so a fresh
        -- read after toggle-off returns the same non-zero value the
        -- light had before. Override to 0 in the off state so:
        --   * [if:light] gates the status section out cleanly,
        --   * %light_icon picks the lightbulb-outline (off) glyph
        --     (s.light > 0 check in Tokens.expanders.light_icon),
        --   * %light_pct calculates to 0 ("0%" in custom templates).
        local fl_on
        if PowerD.isFrontlightOn then
            local ok, v = pcall(function() return PowerD:isFrontlightOn() end)
            if ok then fl_on = v end
        end
        if fl_on == nil and PowerD.is_fl_on ~= nil then
            fl_on = PowerD.is_fl_on
        end
        if fl_on == false then light = 0 end
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
    local slow = _readSlowState(now)
    _device_state_cache = {
        now      = now,
        batt     = (ok_pd and PowerD and PowerD.getCapacity)
                       and PowerD:getCapacity() or nil,
        charging = (ok_pd and PowerD and PowerD.isCharging)
                       and PowerD:isCharging() or false,
        wifi     = (ok_nm and NetMgr and NetMgr.isWifiOn and NetMgr:isWifiOn())
                       and "on" or "off",
        -- Actual link state (radio on AND connected), for the %connected
        -- condition: [if:connected]%wifi_icon[/if] shows the icon only when
        -- online. Mirrors bookends' `connected` state (issue #181).
        connected = (ok_nm and NetMgr and NetMgr.isWifiOn and NetMgr:isWifiOn()
                       and NetMgr.isConnected and NetMgr:isConnected())
                       and "yes" or "no",
        light    = light,
        light_pct= light_pct,
        warmth   = warmth,
        mem      = slow.mem,
        ram_mib  = slow.ram_mib,
        disk_free= slow.disk_free,
    }
    _device_state_expires_at = now + DEVICE_STATE_TTL
    return _device_state_cache
end

-- ─── Navigation ───────────────────────────────────────────────────────────────

-- _openBook(book, after_open_callback)  — open ReaderUI for the given book
-- WITHOUT closing the home screen. The Reader is shown on top in UIManager's
-- stack; when the Reader closes, Bookshelf is exposed automatically with no
-- intermediate FileManager flash. (Closing Bookshelf first leaves
-- FileManager visible for one paint cycle before the close-document
-- handler shows a fresh Bookshelf instance back on top.)
-- after_open_callback (optional) is handed to ReaderUI:showReader and runs
-- with the ready ReaderUI once the document is open — same hook the bookmark
-- browser's "View in book" uses to jump to a position after opening.
function BookshelfWidget:_openBook(book, after_open_callback)
    if not book or not book.filepath then return end
    -- Stale records (Send-to-Kindle moved/removed the file after BIM cached
    -- the path) crash KOReader's filemanagerbookinfo:show via lfs.attributes
    -- on nil. ReaderUI:showReader nil-checks itself, but presenting a "file
    -- missing" toast here is friendlier than its silent no-op.
    -- The path to actually hand ReaderUI: a real file on disk. For Kobo virtual
    -- records (kobo.koplugin) the path is a KOBO_VIRTUAL:// URI with no real file,
    -- so resolve it through the plugin (decrypting on demand) first -- passing the
    -- virtual path straight to showReader silently fails, as its showReader patch
    -- matches a different scheme (#203).
    local open_path = book.filepath
    if book.is_kobo then
        local ok_kobo, KoboSource = pcall(require, "lib/bookshelf_kobo_source")
        local real = ok_kobo and KoboSource and KoboSource.realPathForOpen(book.filepath) or nil
        if not real then
            UIManager:show(require("ui/widget/infomessage"):new{
                text    = _("Couldn't open this Kobo book."),
                timeout = 3,
            })
            return
        end
        -- Map the decrypted /tmp copy back to this virtual book so the hero can
        -- show it as recently-opened (#203 pt3).
        if Repo.noteKoboOpen then Repo.noteKoboOpen(real, book) end
        -- The decrypted copy can still be mid-write when realPathForOpen returns
        -- (#203); opening an empty file silently failed and needed the "open
        -- another, come back" dance. Wait until it has a size -- polling ~1s up
        -- to 5s behind a notice -- then open, or show a clear try-again message.
        self:_openKoboWhenReady(real, after_open_callback)
        return
    else
        -- Stale records (Send-to-Kindle moved/removed the file after BIM cached
        -- the path) crash filemanagerbookinfo:show via lfs.attributes on nil; a
        -- "file missing" toast is friendlier than a silent no-op.
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(book.filepath, "mode") ~= "file" then
            UIManager:show(require("ui/widget/infomessage"):new{
                text    = _("File no longer exists. The bookshelf entry is stale."),
                timeout = 3,
            })
            return
        end
    end
    self:_launchReader(open_path, after_open_callback)
end

-- Hand a real on-disk path to the reader after the pre-read bookkeeping. Shared
-- by the normal open and the deferred Kobo open.
-- Preserves self.chip / page / drilldown / preview across the read (Bookshelf:show
-- restores them on return). Saves rotation so portrait is restored on return (the
-- reader may open in a different rotation, e.g. upside-down on Kobo). Suspends the
-- status timer -- the minute heartbeat is wasted wakeups under the reader.
function BookshelfWidget:_launchReader(open_path, after_open_callback)
    self._pre_read_rotation = Screen:getRotationMode()
    -- Drop the memoised hero record: reading changes progress, so the
    -- close-rebuild must re-read fresh state, not the pre-read snapshot (#103).
    self._hero_current_memo = nil
    self:_stopStatusTimer()
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(open_path, nil, nil, nil, after_open_callback)
end

-- Kobo books decrypt to a /tmp copy that can still be mid-write when
-- realPathForOpen returns; opening an empty file silently fails (#203). Wait
-- until the file has a size -- polling once a second up to 5s behind a "Preparing"
-- notice -- then open, or give a clear try-again message if it never readies.
function BookshelfWidget:_openKoboWhenReady(open_path, after_open_callback)
    local lfs = require("libs/libkoreader-lfs")
    local function ready()
        local sz = lfs.attributes(open_path, "size")
        return type(sz) == "number" and sz > 0
    end
    if ready() then
        self:_launchReader(open_path, after_open_callback)
        return
    end
    -- Bump a token so a later open supersedes this poll (user navigated away).
    self._kobo_open_token = (self._kobo_open_token or 0) + 1
    local token = self._kobo_open_token
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = _("Preparing this book…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local attempts = 0
    local poll
    poll = function()
        if self._kobo_open_token ~= token then UIManager:close(msg); return end
        attempts = attempts + 1
        if ready() then
            UIManager:close(msg)
            self:_launchReader(open_path, after_open_callback)
        elseif attempts >= 5 then
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{
                text    = _("This book is still being prepared. Please try again in a moment."),
                timeout = 3,
            })
        else
            UIManager:scheduleIn(1, poll)
        end
    end
    UIManager:scheduleIn(1, poll)
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
-- How long a memoised current-hero record stays valid. The memo exists to
-- collapse the BURST of identical hero rebuilds the report shows (re-entering
-- the bookshelf, chip-switching, the per-second status churn) onto a single
-- BIM read; a short TTL means any genuine out-of-band progress change (sync,
-- another device) self-heals within seconds without explicit invalidation.
-- _openBook drops the memo outright so the post-read close-rebuild is fresh.
local HERO_MEMO_TTL_S = 12

-- _currentHeroBook() — the lastfile-resolved hero record, memoised.
--
-- Repo.getCurrent() pays a BIM getBookInfo (cover blob decode) + DocSettings
-- read every call. On Kobo bookinfo_cache is non-WAL, so under concurrent
-- cover extraction that read blocks on the DB write lock for up to BIM's 5s
-- busy_timeout. Because the hero is rebuilt on every show / chip-switch /
-- book-close, re-paying that read each time is what produced the multi-second
-- hero stalls (issue #103). We memoise the resolved record keyed by filepath.
--
-- The cached record has cover_bb STRIPPED: a BIM cover_bb is one-shot (freed
-- after its first paint), so handing the same bb to a second render would
-- read freed memory. Instead the scaled cover lives in ScaledCoverCache
-- (HeroCard no longer sets skip_cover_cache), and SpineWidget repaints the
-- hero from there via its filepath key. On a memo hit we therefore return a
-- cover-less copy; SpineWidget's lazy path finds the cached scaled bb.
function BookshelfWidget:_currentHeroBook()
    local fp = Repo.currentFilepath and Repo.currentFilepath()
    if not fp then
        self._hero_current_memo = nil
        return Repo.getCurrent()
    end
    local memo = self._hero_current_memo
    local now  = os.time()
    if memo and memo.fp == fp and memo.expires_at > now and memo.record then
        local copy = {}
        for k, v in pairs(memo.record) do copy[k] = v end
        return copy
    end
    local rec = Repo.getCurrent()
    if rec then
        local stripped = {}
        for k, v in pairs(rec) do
            if k ~= "cover_bb" then stripped[k] = v end
        end
        self._hero_current_memo =
            { fp = fp, record = stripped, expires_at = now + HERO_MEMO_TTL_S }
    else
        self._hero_current_memo = nil
    end
    return rec
end

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
        current = self:_currentHeroBook()
    end
    local _perf_t1 = _gettime()
    if current then Repo.enrichStats(current) end
    local _perf_t2 = _gettime()
    local device_state = self:_buildDeviceState()
    local _perf_t3 = _gettime()
    -- Tags-region builder, prepared up-front so HeroCard:init's eager
    -- _buildRightColumn pass (which runs during HeroCard:new) can see
    -- it. Setting card.tags_builder after construction misses that
    -- first paint and the pills only appear once a subsequent
    -- replaceRightColumn fires.
    local tags_builder
    do
        local Regions = require("lib/bookshelf_hero_regions")
        local regions = Regions.read()
        if current and regions.tags and not regions.tags.disabled then
            local pill_w = math.max(1, content_w - hero_cover_w - PAD)
            local bw = self
            tags_builder = function(book)
                if not book or not book.filepath then return nil end
                -- Read the tags-region config fresh each call (not captured)
                -- so a live in-place hero refresh after a settings change
                -- reflects new categories / font size / alignment without a
                -- full rebuild. read() returns the shared memoised table.
                local tcfg = require("lib/bookshelf_hero_regions").read().tags or {}
                -- #99: per-category visibility filter for the hero pill strip.
                -- Hero only -- the long-press book menu passes nil (all shown).
                local filter = {
                    author      = tcfg.show_author ~= false,
                    series      = tcfg.show_series ~= false,
                    collections = tcfg.show_collections ~= false,
                    genres      = tcfg.show_genres ~= false,
                    folder      = tcfg.show_folder ~= false,
                }
                local ReadCollection = require("readcollection")
                local in_collections = ReadCollection.getCollectionsWithFile
                    and ReadCollection:getCollectionsWithFile(book.filepath) or {}
                local pill_specs = bw:_buildPillSpecs(book, in_collections, nil, filter)
                -- Scale the tag pills with the Hero card font-size knob, so the
                -- whole hero (text + tags) grows/shrinks together. The region's
                -- font_size is the base (default 12 = prior fixed size).
                local hero_scale = (BookshelfSettings.read("font_scale") or 100) / 100
                local pill_size  = math.max(8, math.floor((tcfg.font_size or 14) * hero_scale + 0.5))
                local max_rows = tonumber(tcfg.max_rows) or 2
                if max_rows < 1 then max_rows = 1 end
                return bw:_buildPillGroup(pill_specs, pill_w, max_rows, pill_size,
                    tcfg.alignment or "left", nil,
                    -- +N opens the combined book-detail popup (pills + description).
                    function() bw:_showBookDetail(book, { active = "tags" }) end)
            end
        end
    end
    local card = HeroCard:new{
        book         = current,
        width        = content_w,
        height       = hero_h,
        cover_w      = hero_cover_w,
        cover_h      = hero_cover_h,
        pad          = PAD,
        device_state = device_state,
        tags_builder = tags_builder,
        -- Tap gating:
        --   * selection mode: toggle the book in/out of the bucket.
        --   * tap_to_open_double setting ON: first tap stages the
        --     hero as "tap-selected" (focus ring around the cover),
        --     second tap on the same book opens. Mirrors the
        --     preview-then-open pattern shelf covers use in non-
        --     expanded mode, for users who tend to fat-finger the
        --     hero while browsing.
        --   * otherwise: single tap opens. The hero already
        --     represents the user's current selection, so requiring
        --     a confirmation tap is redundant when the user has
        --     opted out of the setting.
        on_tap       = function(b)
            if self._selection:isActive() then
                self._selection:toggle(b.filepath)
                self:_refreshCoverFrame(b.filepath)
                self:_refreshBucket()
                return
            end
            if BookshelfSettings.isTrue("tap_to_open_double")
                    and self._tap_selected_fp ~= b.filepath then
                self._tap_selected_fp = b.filepath
                self:_swapHeroInPlace()
                return
            end
            self._tap_selected_fp = nil
            self:_openBook(b)
        end,
        on_hold      = function(b)
            if self._selection:isActive() then
                return true  -- suppress: no per-book menu in select mode
            end
            self:_showBookDetail(b, { active = "edit" })
        end,
        on_description_tap = function(b) self:_showFullDescription(b) end,
        on_rating_change   = function(b, r) self:_setBookRating(b, r) end,
        -- Left tappable even when the Hardcover plugin is disabled: reviews
        -- are served cache-first (fetchReviews returns within-TTL cached
        -- reviews without touching the API), so a book whose reviews were
        -- already fetched still opens them. Only a cold/expired fetch needs
        -- the plugin, and that path already shows a graceful error.
        on_hardcover_reviews_tap = function(b) self:_showHardcoverReviews(b) end,
        is_selected      = (self._focus_zone == "hero")
                           or (current and self._selection:contains(current.filepath) or false)
                           or (current and self._tap_selected_fp == current.filepath or false),
        is_bulk_selected = current and self._selection:contains(current.filepath) or false,
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

-- _buildMicroHero(content_w, hero_h, PAD) — the micro-module grid with the
-- hero's status line (time / battery / wifi) pinned full-width above it, no
-- hairline, the same treatment the expanded strip uses. Keeps the status line
-- visible in micro mode. Shared by _rebuild and _swapMicroHeroInPlace so both
-- build the same structure. Falls back to a bare grid when the status region
-- is disabled / empty (buildStatusRow returns nil). The grid is sized to the
-- height left under the status line so the whole thing still fits hero_h.
-- D-pad build opts for the in-hero micro grid: reserve the focus ring on any
-- d-pad device (so moving focus in/out of the hero never resizes cells), and
-- draw it on the cursor cell only while the hero zone holds focus.
function BookshelfWidget:_microHeroOpts()
    local dpad = Device:hasDPad()
    return {
        focusable  = dpad or nil,
        focused_id = (dpad and self._focus_zone == "hero")
                     and self._hero_cell_cursor or nil,
    }
end

-- True when the hero zone is a navigable micro-module grid (d-pad device,
-- micro placement, grid showing). The book hero and expanded strip keep their
-- existing single-unit focus behaviour.
function BookshelfWidget:_heroIsMicroGrid()
    return Device:hasDPad() and self._hero_mode == "micro" and not self._expanded
end

-- Enter the hero zone onto its micro grid. Focus always arrives from below (the
-- chips or book grid), so seed the cursor on the bottom row, nearest column.
function BookshelfWidget:_enterHeroMicro(col_hint)
    self._focus_zone = "hero"
    local rows = self._hero_grid_rows
    local last = rows and rows[#rows]
    if last and #last > 0 then
        self._hero_cell_cursor = last[math.min(col_hint or 1, #last)]
    else
        self._hero_cell_cursor = nil
    end
    self:_swapMicroHeroInPlace()
end

-- Move the hero-grid cursor. Returns true if it moved within the grid, false at
-- the edge (the caller then runs the normal zone transition / stays put).
function BookshelfWidget:_heroMicroNav(dir)
    local HeroModules = require("lib/bookshelf_hero_modules")
    local nid = HeroModules.navMove(self._hero_grid_rows, self._hero_cell_cursor, dir)
    if nid and nid ~= self._hero_cell_cursor then
        self._hero_cell_cursor = nid
        self:_swapMicroHeroInPlace()
        return true
    end
    return false
end

function BookshelfWidget:_buildMicroHero(content_w, hero_h, PAD)
    local HeroModules = require("lib/bookshelf_hero_modules")
    local mopts = self:_microHeroOpts()
    -- Same current-book resolution as _buildExpandedStrip; the status row only
    -- needs the book for its progress/title tokens (device tokens come from
    -- _buildDeviceState).
    local current = (self._preview_book and self._preview_book.filepath
                     and Repo.buildBook(self._preview_book.filepath))
                     or self._preview_book
                     or self:_currentHeroBook()
    -- Keep the full-width status hairline in micro mode (issue #176/#180
    -- follow-up): same separator + Y as the book hero's right-column status,
    -- just spanning the full width like the status text already does.
    local status_row = HeroCard.buildStatusRow(current, self:_buildDeviceState(),
                                               content_w, true)
    if not status_row then
        return HeroModules.build(self, content_w, hero_h, PAD, mopts)
    end
    local VerticalSpan = require("ui/widget/verticalspan")
    -- Tight gap under the status line (half the hero PAD); a full PAD read as
    -- slightly too much space above the grid.
    local gap     = math.max(1, math.floor((PAD or 0) / 2))
    local grid_h  = math.max(1, hero_h - status_row:getSize().h - gap)
    return VerticalGroup:new{
        align = "left",
        status_row,
        VerticalSpan:new{ width = gap },
        HeroModules.build(self, content_w, grid_h, PAD, mopts),
    }
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
                     -- Memoised; the strip renders status text only (no
                     -- cover), so the cover-stripped memo record is fine.
                     or self:_currentHeroBook()

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
        bw:_setExpanded(false)
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
    -- Highlight the selected book's cover in BOTH modes (expanded grid and
    -- 2-row), so the same book stays highlighted across an expand/collapse
    -- toggle and matches whatever the hero previews. _selectedFilepath unifies
    -- the d-pad focus cell, the open-double pending tap, and the hero preview.
    local selected_filepath = self:_selectedFilepath()
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
        selection         = bw._selection,
        show_titles       = self._expanded,
        in_series         = in_series,
        -- Expanded mode is "browse to open" — single tap opens the book.
        -- Normal mode is "preview, then commit" — tap shelf cover stages it
        -- in the hero, tap hero opens.
        on_book_tap       = function(b, tap_t)
            if bw._selection:isActive() then
                bw._selection:toggle(b.filepath)
                bw:_refreshCoverFrame(b.filepath)
                bw:_refreshBucket()
                return
            end
            if bw._expanded then
                local action = BookshelfSettings.expandedTapAction()
                if action == "show_detail" then
                    -- Restore the full hero showing this book (and remember
                    -- hero, per expand-memory; swipe up to go back). Must be a
                    -- FULL rebuild, NOT _previewBook: coming from the expanded
                    -- shelf the hero isn't mounted and the shelf row count
                    -- changes, so _previewBook's fast in-place hero swap would
                    -- leave the grid expanded with the hero bleeding behind the
                    -- chip bar. Mirror the currently-reading chip's was_expanded
                    -- path: set the preview state, then rebuild the whole layout.
                    -- Capture the book's page position WHILE still expanded
                    -- (cursor + its slot), so after collapse we can page the
                    -- shorter grid to keep its cover on screen too.
                    local gidx = bw:_globalIndexOfFilepath(b.filepath)
                    bw._tap_selected_fp = nil
                    bw:_clearDpadFocus()
                    bw._hero_mode    = "current"
                    bw._preview_book = Repo.buildBook(b.filepath) or b
                    pcall(function() require("lib/bookshelf_quotes").rerollBook() end)
                    bw:_setExpanded(false)
                    bw:_setCursorToShow(gidx)
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                    return
                end
                if action == "open_double" and bw._tap_selected_fp ~= b.filepath then
                    bw._tap_selected_fp = b.filepath
                    bw:_refreshCoverFrame(b.filepath)
                    return
                end
                bw._tap_selected_fp = nil
                bw:_openBook(b)
            else
                bw:_previewBook(b, tap_t)
            end
        end,
        on_book_hold      = function(b)
            if bw._selection:isActive() then
                return true  -- suppress: no per-book menu in select mode
            end
            bw:_showBookDetail(b, { active = "edit" })
        end,
        on_series_tap     = function(s) bw:_expandSeries(s) end,
        on_series_hold    = function(s) bw:_openGroupMenu(s, "series") end,
        on_author_tap     = function(g) bw:_expandAuthor(g) end,
        on_author_hold    = function(g) bw:_openGroupMenu(g, "author") end,
        on_genre_tap      = function(g) bw:_expandGenre(g) end,
        on_genre_hold     = function(g) bw:_openGroupMenu(g, "genre") end,
        on_tag_tap        = function(g) bw:_expandTag(g) end,
        on_tag_hold       = function(g) bw:_openGroupMenu(g, "tag") end,
        on_language_tap   = function(g) bw:_expandLanguage(g) end,
        on_language_hold  = function(g) bw:_openGroupMenu(g, "language") end,
        on_folder_tap     = function(f) bw:_expandFolder(f) end,
        on_folder_hold    = function(f) bw:_openGroupMenu(f, "folder") end,
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
        text = string.format(_("Page %d of %d"), self.page, total_pages),
        -- Adopt the Bookshelf UI font (a FontList-resolvable face), like the
        -- rest of the chrome; falls back to cfont in follow mode. Button
        -- resolves text_font_face via Font:getFace, and the UI-font setting
        -- stores a resolvable face, so the name can be passed straight in.
        text_font_face = BFont.getUIFontFace() or "cfont",
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
    -- Returns the chev HorizontalGroup directly. The caller
    -- (_buildFooterRow) wraps it in a CenterContainer sized to the
    -- full footer height for vertical centering — same way the X and
    -- bucket icons are centered. No leading VerticalSpan or wrapping
    -- CenterContainer here; all positioning lives in one place.
    return HorizontalGroup:new{
        align = "center",
        first, prev, page_text, next_btn, last,
    }
end

-- ─── Selection overlay ────────────────────────────────────────────────────────

-- Bottom hit-zone extension baked into every footer button's frame
-- (padding_bottom). Exposed as a class constant so other widgets that
-- overlay a footer button's region (e.g. the start menu's close glyph
-- over the hamburger) can subtract the same amount.
BookshelfWidget.FOOTER_HIT_EXTENSION = Screen:scaleBySize(12)

-- Stroke thickness of the custom-painted footer art (the hamburger bars,
-- and the start menu's close X painted over them). Exposed as a class
-- constant so the start menu can paint its X at EXACTLY the same weight —
-- a glyph X always read heavier than the painted bars. Formula matches
-- _buildStartMenuIcon's bar_t: art square scaled at 32, bars at ~art/14.
BookshelfWidget.FOOTER_STROKE_W =
    math.max(1, math.floor(Screen:scaleBySize(32) / 14))

-- _wrapAsFooterButton(content_widget, frame_width, focused, on_tap)
-- Wraps an arbitrary content widget in the same FrameContainer
-- structure KOReader's Button widget produces internally — same
-- margin/bordersize/radius swap on focus, same `padding_bottom =
-- hit_extension` for a generous bottom tap area, same outer footprint
-- math. Use this for any footer button whose content isn't an icon or
-- text Button can render itself (e.g. the custom-painted U-bucket).
function BookshelfWidget:_wrapAsFooterButton(content_widget, frame_width, focused, on_tap)
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local focus_border    = Screen:scaleBySize(4)
    local focus_radius    = Screen:scaleBySize(4)
    local hit_extension   = BookshelfWidget.FOOTER_HIT_EXTENSION
    -- Focus swap: when focused, paint a focus_border-thick ring at the
    -- frame edge; when not focused, reserve the same space as
    -- transparent margin. Outer footprint stays constant.
    local margin     = focused and 0           or focus_border
    local bordersize = focused and focus_border or 0
    local radius     = focused and focus_radius or nil
    -- Center the content horizontally within frame_width by padding
    -- with HorizontalSpans (same trick Button uses for fixed-width
    -- buttons).
    local content_size = content_widget:getSize()
    local outer_chrome = 2 * focus_border
    local inner_w      = math.max(0, frame_width - outer_chrome)
    local left_pad     = math.max(0, math.floor((inner_w - content_size.w) / 2))
    local right_pad    = math.max(0, inner_w - content_size.w - left_pad)
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = left_pad },
        content_widget,
        HorizontalSpan:new{ width = right_pad },
    }
    local frame = FrameContainer:new{
        margin         = margin,
        bordersize     = bordersize,
        radius         = radius,
        padding        = 0,
        padding_bottom = hit_extension,
        row,
    }
    local container = InputContainer:new{
        dimen = frame:getSize(),
        frame,
    }
    container.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = container.dimen } },
    }
    function container:onTap()
        if on_tap then return on_tap() end
        return true
    end
    return container
end

-- _buildBucketIcon(focused, frame_width) — custom U-bucket button with a
-- count digit nested inside. The bucket's WIDTH grows with the digit
-- count (1 digit = narrow, 2 digits = wider, 3+ digits = wider still)
-- so the digit always sits comfortably inside the trough. Height stays
-- equal to chev_size so the outer frame footprint matches the chev
-- buttons (and the X close button) — same _wrapAsFooterButton chrome.
function BookshelfWidget:_buildBucketIcon(focused, frame_width)
    local art_h        = Screen:scaleBySize(34)   -- a touch taller than chev_size
    frame_width        = frame_width or art_h
    local bucket_h     = math.floor(art_h * 0.75)
    local count        = self._selection:count()
    local count_str    = tostring(count)
    local color       = count == 0 and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
    -- Probe the digit's text size first so we can size the bucket's
    -- internal width to fit. Use the same face the paint loop uses.
    local count_font_size = math.floor(art_h * 0.5)
    local count_face, count_bold = BFont:getFace("infofont", count_font_size, { bold = true })
    local probe = TextWidget:new{ text = count_str, face = count_face, bold = count_bold }
    local text_w = probe:getSize().w
    probe:free()
    -- Bucket inner cavity width = text_w + a small horizontal margin
    -- inside the walls; bucket outer width = cavity + 2 wall strokes.
    local stroke_w   = Screen:scaleBySize(5)
    local cavity_pad = Screen:scaleBySize(4)   -- breathing room each side of the digit
    local bucket_w   = math.max(art_h, text_w + 2 * stroke_w + 2 * cavity_pad)
    local art_w      = bucket_w                -- the art region is as wide as the bucket
    local Widget = require("ui/widget/widget")
    local UWidget = Widget:extend{}
    function UWidget:getSize() return Geom:new{ w = art_w, h = art_h } end
    function UWidget:paintTo(bb, x, y)
        -- Vertically center the bucket within the art region, then
        -- nudge the whole thing down a small padding so it sits below
        -- the chev row's optical centerline (visual balance).
        local bucket_y = y + math.floor((art_h - bucket_h) / 2) + Size.padding.small
        local cap_r    = math.floor(stroke_w / 2)
        local left_cx  = x + cap_r + 1
        local right_cx = x + bucket_w - cap_r - 1
        local top_cy   = bucket_y + cap_r
        local bot_cy   = bucket_y + bucket_h - cap_r - 1
        -- Three-stroke U with rounded caps + corner fillets.
        bb:paintRect(left_cx - cap_r,  top_cy,
                     stroke_w, bot_cy - top_cy + 1, color)
        bb:paintRect(right_cx - cap_r, top_cy,
                     stroke_w, bot_cy - top_cy + 1, color)
        bb:paintRect(left_cx, bot_cy - cap_r,
                     right_cx - left_cx + 1, stroke_w, color)
        bb:paintCircle(left_cx,  top_cy, cap_r, color)
        bb:paintCircle(right_cx, top_cy, cap_r, color)
        bb:paintCircle(left_cx,  bot_cy, cap_r, color)
        bb:paintCircle(right_cx, bot_cy, cap_r, color)
        -- Count digit anchored by BASELINE (not by bounding-box height,
        -- which varies font-to-font with ascender/descender padding).
        -- Baseline sits inside the bottom wall by cap_r so the digit
        -- reads as resting in the bucket regardless of font choice.
        local tw = TextWidget:new{ text = count_str, face = count_face, bold = count_bold,
                                   fgcolor = color }
        local ts = tw:getSize()
        local baseline_h = (tw.getBaseline and tw:getBaseline()) or tw._baseline_h or ts.h
        local tx = x + math.floor((bucket_w - ts.w) / 2)
        -- Baseline sits a breathing gap above the bottom wall so the
        -- digit's bottom doesn't kiss the trough floor.
        local baseline_y = bot_cy - cap_r - Size.padding.small * 2
        local ty = baseline_y - baseline_h
        tw:paintTo(bb, tx, ty)
        tw:free()
    end
    local u_widget = UWidget:new{}
    local bw_ref   = self
    return self:_wrapAsFooterButton(u_widget, frame_width, focused, function()
        if count == 0 then return true end
        bw_ref:_openBulkMenu()
        return true
    end)
end

-- _buildStartMenuIcon(focused, frame_width) — Footer hamburger; opens the start menu. Hidden in multi-select (the close-X takes the slot).
-- Custom-painted three bars rather than the obvious U+2630 glyph: the
-- fallback face that renders U+2630 has a font box far taller than the
-- art size (odd ascent/descent), which both inflated the button frame
-- (so it reached up under the start-menu panel) and left the bar ink
-- sitting below the chevrons' vertical midline. Painting the bars
-- directly (same precedent as _buildBucketIcon) keeps the geometry
-- deterministic: the box is exactly art_size tall, bars centered.
function BookshelfWidget:_buildStartMenuIcon(focused, frame_width)
    local art_size = Screen:scaleBySize(32)
    frame_width    = frame_width or art_size
    local bar_w    = art_size
    -- Thin black bars: solid horizontal rects read heavier than the
    -- chevrons' anti-aliased diagonal arms at equal pixel width, so the
    -- bars run thinner (art_size/14 vs the arms' ~1/12) to land at the
    -- same VISUAL stroke weight. Single source: FOOTER_STROKE_W (the
    -- start menu's close X consumes the same constant).
    local bar_t    = BookshelfWidget.FOOTER_STROKE_W
    local span     = math.floor(art_size * 0.62)
    local gap      = math.max(1, math.floor((span - 3 * bar_t) / 2))
    span = 3 * bar_t + 2 * gap
    local Widget = require("ui/widget/widget")
    local BarsWidget = Widget:extend{}
    function BarsWidget:getSize() return Geom:new{ w = bar_w, h = art_size } end
    function BarsWidget:paintTo(bb, x, y)
        local top = y + math.floor((art_size - span) / 2)
        for i = 0, 2 do
            bb:paintRect(x, top + i * (bar_t + gap), bar_w, bar_t,
                Blitbuffer.COLOR_BLACK)
        end
    end
    local bw_ref = self
    local btn = self:_wrapAsFooterButton(BarsWidget:new{}, frame_width, focused, function()
        bw_ref:_openStartMenu()
        return true
    end)
    self._burger_dimen = btn.dimen
    return btn
end

-- _buildMicroModuleIcon(focused, frame_width) — footer grid button (Micro-
-- modules placement == "fullscreen"); opens the full-screen micro-module grid.
-- Custom-painted 2x2 OUTLINE grid (the chip's view-grid glyph is the filled
-- variant) at the same visual stroke weight as the hamburger's bars.
function BookshelfWidget:_buildMicroModuleIcon(focused, frame_width)
    local art_size = Screen:scaleBySize(32)
    frame_width    = frame_width or art_size
    -- Match the hamburger EXACTLY so the two footer corners balance: same art box
    -- (art_size square), same ink width (bar_w = art_size) and ink height
    -- (span = 62% of art, vertically centred), same stroke (FOOTER_STROKE_W). A
    -- 2x2 box grid = outer rectangle + a centre cross, all at the bar weight.
    local t = BookshelfWidget.FOOTER_STROKE_W
    -- Match the hamburger's ink box EXACTLY: width = art_size (= bar_w), height =
    -- its recomputed bar span (computed identically here, so the two icons are
    -- the same height). FOUR SEPARATE outlined boxes in a 2x2 fill that box, with
    -- a gap between them (a joined rect-with-cross read as one shape).
    local span = math.floor(art_size * 0.62)
    local bgap = math.max(1, math.floor((span - 3 * t) / 2))
    span = 3 * t + 2 * bgap
    -- Stretch 125% vertically: four separate boxes read shorter than the solid
    -- bars at equal span, so the grid needs the extra height to balance.
    local W, H = art_size, math.floor(span * 1.25)
    local gap  = math.max(2, 2 * t)
    local cw   = math.floor((W - gap) / 2)
    local ch   = math.floor((H - gap) / 2)
    local Widget = require("ui/widget/widget")
    local GridWidget = Widget:extend{}
    function GridWidget:getSize() return Geom:new{ w = art_size, h = art_size } end
    function GridWidget:paintTo(bb, x, y)
        local oy = y + math.floor((art_size - H) / 2)  -- centre the ink like the bars
        local function box(rx, ry)
            bb:paintRect(rx, ry, cw, t, Blitbuffer.COLOR_BLACK)          -- top
            bb:paintRect(rx, ry + ch - t, cw, t, Blitbuffer.COLOR_BLACK) -- bottom
            bb:paintRect(rx, ry, t, ch, Blitbuffer.COLOR_BLACK)          -- left
            bb:paintRect(rx + cw - t, ry, t, ch, Blitbuffer.COLOR_BLACK) -- right
        end
        for r = 0, 1 do
            for c = 0, 1 do
                box(x + c * (cw + gap), oy + r * (ch + gap))
            end
        end
    end
    local bw_ref = self
    local btn = self:_wrapAsFooterButton(GridWidget:new{}, frame_width, focused, function()
        bw_ref:_openMicroModulesFullscreen()
        return true
    end)
    self._micromod_dimen = btn.dimen
    return btn
end

-- _buildExitIcon(focused) — Renders the close icon as the mdi-close nerd-
-- font glyph (U+E855) via KOReader's bundled `symbols` font face. Earlier
-- iterations rasterised the X pixel-by-pixel because paintLine isn't in
-- this Blitbuffer build, but a glyph reads cleaner at e-ink scale and
-- matches the visual weight of other nerd-font icons in the plugin
-- (chip-editor delete, mdi-chevron-left/right, etc.).
function BookshelfWidget:_buildExitIcon(focused, frame_width)
    local CLOSE_GLYPH = "\xEE\xA1\x95"   -- U+E855 mdi-close
    -- Use the chev_size content area so the X frame shares the same
    -- outer footprint as the chev buttons. The X glyph is rendered at
    -- a font size that fills most of the content area.
    local art_size  = Screen:scaleBySize(32)
    frame_width     = frame_width or art_size
    local glyph_pt  = math.floor(art_size * 0.75)
    local face      = Font:getFace("symbols", glyph_pt)
    local glyph     = TextWidget:new{
        text    = CLOSE_GLYPH,
        face    = face,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local bw_ref = self
    return self:_wrapAsFooterButton(glyph, frame_width, focused, function()
        local prev = bw_ref._selection:count()
        bw_ref._selection:exitMode()
        bw_ref:_rebuild()
        UIManager:setDirty(bw_ref, "ui")
        if prev > 0 then
            local ok_n, Notification = pcall(require, "ui/widget/notification")
            if ok_n and Notification then
                UIManager:show(Notification:new{
                    text    = _("Selection cleared"),
                    timeout = 1,
                })
            end
        end
        return true
    end)
end

-- _startMenuPosition() — sanitised read of the start-menu position
-- setting: "left" (default; an absent or unknown value reads as left),
-- "right", or "off".
function BookshelfWidget:_startMenuPosition()
    local v = BookshelfSettings.read("start_menu_position", "left")
    if v == "right" or v == "off" then return v end
    return "left"
end

-- _buildFooterRow(content_w, total_pages, footer_h) — the screen-anchored
-- footer row. Composes the pagination chev nav (centered) with the
-- selection-mode close-X (left-aligned) and bucket (right-aligned). All
-- three live in a single OverlapGroup of `footer_h` height; the caller
-- anchors this row at the screen bottom via a BottomContainer.
--
-- The X and bucket each get a hitbox the same size as a chev button —
-- specifically the full footer height tall and the full side-strip
-- wide (the gap between the chev row and the screen edge). This makes
-- the bottom-left and bottom-right "feel" tappable everywhere.
function BookshelfWidget:_buildFooterRow(content_w, total_pages, footer_h)
    local OverlapGroup    = require("ui/widget/overlapgroup")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local RightContainer  = require("ui/widget/container/rightcontainer")
    local chev_row  = self:_buildPaginationFooter(content_w, footer_h, total_pages)
    -- Wrap chev_row in a CenterContainer of footer_h height so the row
    -- centers vertically — same treatment the X and bucket get below.
    local centered_chev = CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = footer_h },
        chev_row,
    }
    local row = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = footer_h },
        allow_mirroring = false,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = footer_h },
            centered_chev,
        },
    }
    if self._selection:isActive() then
        -- Side-strip width = space between the chev nav strip (75% of
        -- content_w, centered) and the screen edge. The chev nav strip
        -- is centered within content_w which is centered within
        -- self.width, so this resolves to (self.width - nav_strip_w)/2.
        local nav_strip_w  = math.floor(content_w * 0.75)
        local side_strip_w = math.floor((self.width - nav_strip_w) / 2)
        local in_overlay     = (self._focus_zone == "selection_overlay")
        local focused_slot   = in_overlay and (self._sel_overlay_slot or "bucket")
        local exit_focused   = focused_slot == "exit_x"
        local bucket_focused = focused_slot == "bucket"
        local exit_icon   = self:_buildExitIcon(exit_focused, side_strip_w, footer_h)
        local bucket_icon = self:_buildBucketIcon(bucket_focused, side_strip_w, footer_h)
        row[#row + 1] = LeftContainer:new{
            dimen = Geom:new{ w = self.width, h = footer_h },
            exit_icon,
        }
        row[#row + 1] = RightContainer:new{
            dimen = Geom:new{ w = self.width, h = footer_h },
            bucket_icon,
        }
    else
        local menu_pos = self:_startMenuPosition()
        if menu_pos == "off" then
            -- No hamburger this build: clear the stashed dimen so a
            -- stale region from a previous build can't anchor the
            -- start-menu close indicator (defensive; _openStartMenu
            -- also no-ops when off).
            self._burger_dimen = nil
        else
            local nav_strip_w  = math.floor(content_w * 0.75)
            local side_strip_w = math.floor((self.width - nav_strip_w) / 2)
            local burger_focused = (self._focus_zone == "footer")
                and (self._footer_cursor_btn == "menu")
            local burger = self:_buildStartMenuIcon(burger_focused, side_strip_w, footer_h)
            local Container = menu_pos == "right" and RightContainer or LeftContainer
            row[#row + 1] = Container:new{
                dimen = Geom:new{ w = self.width, h = footer_h },
                burger,
            }
        end
        -- Footer micro-module button (full-screen surface on): a grid icon in
        -- the corner OPPOSITE the start menu so they don't collide; tap opens the
        -- full-screen grid. start_menu "off" -> default the grid to the right.
        if BookshelfSettings.microFullscreenButton() then
            local grid_side = (menu_pos == "left") and "right"
                or ((menu_pos == "right") and "left" or "right")
            local nav_strip_w  = math.floor(content_w * 0.75)
            local side_strip_w = math.floor((self.width - nav_strip_w) / 2)
            local mm_focused   = (self._focus_zone == "footer")
                and (self._footer_cursor_btn == "micromod")
            local mm_icon      = self:_buildMicroModuleIcon(mm_focused, side_strip_w)
            local MMContainer  = grid_side == "right" and RightContainer or LeftContainer
            row[#row + 1] = MMContainer:new{
                dimen = Geom:new{ w = self.width, h = footer_h },
                mm_icon,
            }
        else
            self._micromod_dimen = nil
        end
    end
    self._footer_h_last = footer_h
    self._footer_row_widget = row
    return row
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
-- _jumpToLetterPrefix(prefix) -- shared by the page-jump dialog's "Go to
-- letter" button. Fetches the full sorted list, finds the first item whose
-- sort-key value starts with `prefix` (case-insensitive), and sets the
-- cursor to that page. Used in any chip, regardless of sort -- mirrors
-- KOReader's file-manager pattern where the same input dialog accepts
-- both a page number and a letter and the user picks which to act on.
function BookshelfWidget:_jumpToLetterPrefix(prefix)
    local InfoMessage = require("ui/widget/infomessage")
    local SortEngine  = require("lib/bookshelf_sort_engine")
    if not prefix or prefix == "" then return end
    local p = prefix:lower()
    local TabModel = require("lib/bookshelf_tab_model")
    local tab      = TabModel.getById(self.chip)
    local sp       = tab and tab.sort_priority
    local sort_key = sp and sp[1] and sp[1].key
    local _t0      = _gettime()

    -- Source the full sorted list. Group drilldowns (series/author/genre/
    -- tag) already have hydrated books in tip.payload.books; otherwise
    -- fetch via Repo.getBySource with a large LIMIT + lazy_cover so we
    -- don't decode covers for items we won't render.
    local items
    local fetched_via
    local tip = self._drilldown_path[#self._drilldown_path]
    if tip and tip.payload and tip.payload.books then
        items = tip.payload.books
        fetched_via = "drilldown-payload"
    else
        -- light_only: we only read sort-key fields to find a page boundary
        -- and never render these records, so the repo serves light metadata
        -- (one batched SELECT) instead of hydrating thousands of full Book
        -- records. lazy_cover stays set as a belt-and-braces for any path
        -- that ignores light_only.
        local fetch_opts = { lazy_cover = true, light_only = true }
        local BIG_LIMIT  = math.max(self._total_items or 0, 10000)
        local ok, fetched = pcall(function()
            if tab then
                return Repo.getBySource(tab.source, tab.filter, tab.sort_priority,
                                        0, BIG_LIMIT, fetch_opts)
            end
            return Repo.getBySource({ kind = self.chip }, nil, nil,
                                    0, BIG_LIMIT, fetch_opts)
        end)
        items = ok and fetched or nil
        fetched_via = ok and "getBySource" or ("getBySource-ERR:" .. tostring(fetched))
    end
    local _t_fetch = _gettime()
    if not items or #items == 0 then
        logger.dbg(string.format(
            "[bookshelf jump] chip=%s sort_key=%s via=%s items=0 fetch=%.0fms",
            tostring(self.chip), tostring(sort_key), tostring(fetched_via),
            (_t_fetch - _t0) * 1000))
        return
    end
    -- Diagnostic: first few items' resolved sort-key values, so a mismatch
    -- between the visible order and what the matcher sees is visible in-log.
    do
        local sample = {}
        for i = 1, math.min(5, #items) do
            sample[i] = string.format("%q", SortEngine.sortKeyValue(items[i], sort_key) or "?")
        end
        logger.dbg(string.format(
            "[bookshelf jump] chip=%s sort_key=%s via=%s items=%d fetch=%.0fms head=[%s]",
            tostring(self.chip), tostring(sort_key), tostring(fetched_via),
            #items, (_t_fetch - _t0) * 1000, table.concat(sample, ", ")))
    end

    -- Find first item whose canonical sort-key value (the SAME derivation the
    -- chip's sort uses, via SortEngine.sortKeyValue) starts with the prefix.
    for i, item in ipairs(items) do
        local v = SortEngine.sortKeyValue(item, sort_key)
        if v and v:sub(1, #p) == p then
            local view  = self:_viewSize()
            local page0 = math.floor((i - 1) / view)
            self._cursor = page0 * view + 1
            self:_clampCursor()
            self:_syncPageFromCursor()
            self:_swapShelvesInPlace()
            logger.dbg(string.format(
                "[bookshelf jump] matched %q at idx=%d (page0=%d) scan=%.0fms total=%.0fms",
                v, i, page0, (_gettime() - _t_fetch) * 1000,
                (_gettime() - _t0) * 1000))
            return
        end
    end
    logger.dbg(string.format(
        "[bookshelf jump] NO MATCH for %q scan=%.0fms total=%.0fms",
        p, (_gettime() - _t_fetch) * 1000, (_gettime() - _t0) * 1000))
    UIManager:show(InfoMessage:new{
        text    = string.format(_("No items start with %q"), prefix),
        timeout = 2,
    })
end

-- _openPageJump -- unified input dialog matching KOReader's file-manager
-- pagination tap (issue 24): user types either a page number OR a letter /
-- prefix, then chooses the appropriate action button. One dialog handles
-- both navigation modes regardless of the chip's current sort.
function BookshelfWidget:_openPageJump()
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    local bw          = self
    local total       = bw:_totalPages()
    local dialog
    dialog = InputDialog:new{
        title       = _("Enter text, letter or page number"),
        -- Start empty: pre-filling the current page number just forced the
        -- user to clear it before typing anything else. Show the current
        -- page as a placeholder hint instead so the context is still there.
        input       = "",
        input_hint  = tostring(bw.page),
        description = string.format(_("(a - z) or (1 - %d)"), total),
        buttons = {
            {
                {
                    -- Hand off whatever the user typed to bookshelf's full
                    -- library search (Repo.searchAll across title / author /
                    -- series / genre). The page-jump dialog pre-fills the
                    -- search dialog so the user doesn't have to retype.
                    text     = _("Search\xE2\x80\xA6"),  -- Search…
                    callback = function()
                        local s = dialog:getInputText()
                        UIManager:close(dialog)
                        bw:_openSearchDialog(s)
                    end,
                },
                {
                    text     = _("Go to letter"),
                    callback = function()
                        local s = dialog:getInputText()
                        if s == "" then return end
                        -- Skip the letter path when the input is purely
                        -- numeric -- the user almost certainly meant the
                        -- page-number action; mistaking it for a "go to
                        -- letter '5'" would be a frustrating no-op.
                        if tonumber(s) ~= nil then return end
                        UIManager:close(dialog)
                        bw:_jumpToLetterPrefix(s)
                    end,
                },
            },
            {
                {
                    text     = _("Cancel"),
                    id       = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text             = _("Go to page"),
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
    -- Fast path handles ANY row count, not just the standard 2-row layout --
    -- as long as the stashed layout still matches the current mode. A changed
    -- _nShelves (rotation, expand/collapse toggle, cover-size change) means the
    -- stashed shelf-row indices are stale, so fall back to a full rebuild.
    -- Expand/collapse and rotation already route through _rebuild anyway; this
    -- guard just protects against a stale _shelf_dims.
    local d = self._shelf_dims
    local n_shelves = self:_nShelves()
    if n_shelves ~= (d.n_shelves or 2) then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        return
    end
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
    local rows = self:_buildShelfRows(items, d.content_w, d.shelf_h, d.book_gap or d.PAD, n_shelves)
    -- Keep the stashed cover-area dims current (layout is unchanged within a
    -- mode, but cheap to refresh and keeps _currentSlotDims authoritative).
    if rows[1] then
        d.cover_w = rows[1].cover_w
        d.cover_h = rows[1].cover_h
    end
    local _perf_t2 = _gettime()
    logger.dbg(string.format("[bookshelf perf] _swapShelves: shelves=%.0fms",
        (_perf_t2 - _perf_t1) * 1000))
    -- Rebuild the entire footer row (chev nav + optional bucket+✕),
    -- wrapped in its screen-anchor BottomContainer. Swap it into the
    -- overlap_group at the stashed footer_overlap_idx.
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local new_footer_row = self:_buildFooterRow(d.content_w, total_pages, d.FOOTER_H)
    local new_footer_anchor = BottomContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height - d.FOOTER_BOTTOM_MARGIN },
        new_footer_row,
    }

    -- Kick off BIM extraction for newly-paginated books that aren't
    -- cached yet. Same slot + hero dims as _rebuild's call so both
    -- consumers get a single cached cover sized for the bigger of the two.
    local n_slots = self:_nCols()
    local slot_w  = math.floor((d.content_w - (d.book_gap or d.PAD) * (n_slots - 1)) / n_slots)
    local slot_h  = math.floor(slot_w * 1.5)
    self:_kickOffMissingMetaExtraction(items, slot_w, slot_h, d.hero_cover_w, d.hero_cover_h)

    -- Swap each shelf row in place. Rows sit at shelf_top_idx, +2, +4, ...
    -- (each separated by a VerticalSpan we leave untouched, so inter-row
    -- spacing -- including expanded mode's even-slack after_row_bonus -- is
    -- preserved). Capture the old row widgets to free after the next paint.
    local old_rows = {}
    for r = 1, n_shelves do
        local idx = d.shelf_top_idx + 2 * (r - 1)
        old_rows[r] = self._inner_vgroup[idx]
        self._inner_vgroup[idx] = rows[r]
    end
    local old_footer = self._overlap_group and self._overlap_group[d.footer_overlap_idx]
    if self._overlap_group then
        self._overlap_group[d.footer_overlap_idx] = new_footer_anchor
    end

    if self._inner_vgroup.resetLayout then
        self._inner_vgroup:resetLayout()
    end
    if self._overlap_group and self._overlap_group.resetLayout then
        self._overlap_group:resetLayout()
    end
    UIManager:nextTick(function()
        for _i = 1, #old_rows do
            local w = old_rows[_i]
            if w and w.free then pcall(function() w:free() end) end
        end
        if old_footer and old_footer.free then
            pcall(function() old_footer:free() end)
        end
    end)
    logger.dbg(string.format("[bookshelf perf] _swapShelves: TOTAL=%.0fms page=%d/%d items=%d chip=%s",
        (_gettime() - _perf_t0) * 1000, self.page, self._total_pages or 0,
        self._total_items or 0, self.chip))
    -- Scope the refresh to the shelf area (top of row 1 down to the screen
    -- bottom, covering the rows + pagination footer). The swap only changed
    -- the shelves and footer; the hero and chip strip above are untouched, so
    -- a whole-widget "ui" refresh needlessly repaints the hero cover -- which
    -- flashes visibly on slower e-ink panels on book-return / page-turn
    -- (issue #124). Fall back to a full refresh if the old rows carry no
    -- painted dimen to anchor the region.
    local shelf_top = old_rows[1] and old_rows[1].dimen and old_rows[1].dimen.y
    if shelf_top then
        UIManager:setDirty(self, "ui", Geom:new{
            x = 0, y = shelf_top, w = self.width, h = self.height - shelf_top })
    else
        UIManager:setDirty(self, "ui")
    end
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
            is_selected      = want_selected,
            is_bulk_selected = old_spine.is_bulk_selected or false,
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

    for r = 1, (d.n_shelves or 2) do
        local idx = d.shelf_top_idx + 2 * (r - 1)
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
        logger.dbg("[bookshelf perf] _repaintHighlight: no slot match -> fallback _swapShelves")
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
-- Returns true if at least one matching spine was found and replaced, so
-- callers can fall back to a heavier refresh when the book isn't on the
-- current page / live tree.
function BookshelfWidget:_refreshSpineInPlace(fp)
    if not fp or not self._inner_vgroup or not self._shelf_dims then return false end
    local d = self._shelf_dims
    local replaced_dimen
    local replaced = false
    for r = 1, (d.n_shelves or 2) do
        local idx = d.shelf_top_idx + 2 * (r - 1)
        local hg = self._inner_vgroup[idx]
        if hg then
            local parent, slot_idx, old_spine = _descendFindSpine(hg, fp, 0)
            if parent then
                replaced = true
                local fresh = Repo.buildBookMeta(fp) or old_spine.book
                local new_slot = SpineWidget:new{
                    book          = fresh,
                    width         = old_spine.width,
                    height        = old_spine.height,
                    on_tap        = old_spine.on_tap,
                    on_hold       = old_spine.on_hold,
                    is_selected      = old_spine.is_selected or false,
                    is_bulk_selected = old_spine.is_bulk_selected or false,
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
    return replaced
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
    -- Row-count gate: the in-place swap helpers (_swapShelvesInPlace and the
    -- hero right-column swap below) reuse the live tree's stashed shelf-row
    -- indices, so they're valid only while the current _nShelves() still
    -- matches the count the tree was built with. A mismatch means the layout
    -- changed (rotation, expand/collapse, cover-size) and the indices are
    -- stale -- fall back to a full _rebuild.
    --
    -- This was previously gated on "== 2", an outdated proxy for "collapsed,
    -- hero visible" from before the cover-size / hero-size settings existed.
    -- Those settings now let a hero-visible layout have 1 or 3 rows, which
    -- were needlessly forced down the heavy whole-screen rebuild + broad
    -- refresh on every book return (issue #124). Comparing against the
    -- stashed count instead lets any unchanged row count take the scoped,
    -- flash-free path, mirroring _swapShelvesInPlace's own guard.
    if not has_live_tree or (self._shelf_dims.n_shelves or 2) ~= self:_nShelves() then
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
    -- Path only - getCurrent()'s BIM read is at its most contended right
    -- after a book close (extraction often resumes), and the spine
    -- refresh only needs to know WHICH file to repaint.
    local lastfile_fp = Repo.currentFilepath and Repo.currentFilepath()
    if lastfile_fp then
        self:_refreshSpineInPlace(lastfile_fp)
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

-- Rebuild ONLY the micro-module grid and swap it into _hero_parent[1],
-- scoping the refresh to the hero region. Used after a module tap/edit so the
-- reload re-renders the grid (the tapped module reflects its new state, the
-- others return cached content) WITHOUT rebuilding or refreshing the shelf
-- below — a full _rebuild + full setDirty flashed the whole shelf on every
-- tap. Returns true if it swapped; false (so the caller can fall back to a
-- full rebuild) when not in the grid state or the live tree isn't there.
function BookshelfWidget:_swapMicroHeroInPlace()
    if self._hero_mode ~= "micro" or self._expanded then return false end
    if not self._hero_parent or not self._hero_dims then return false end
    local d = self._hero_dims
    local old_hero = self._hero_parent[1]
    -- The grid is a plain VerticalGroup, which doesn't stash a .dimen on paint
    -- (unlike the book hero's HeroCard/InputContainer), so derive the hero's
    -- screen rect from the geometry: full width, from the top down through the
    -- top margin + hero height. Scopes the refresh to the hero band so the
    -- chips and shelves below don't flash.
    local scope = Geom:new{
        x = 0, y = 0,
        w = self.width,
        h = (d.PAD or 0) + (d.hero_h or 0),
    }
    self._hero_parent[1] = self:_buildMicroHero(d.content_w, d.hero_h, d.PAD)
    self._hero_card = nil
    if self._hero_parent.resetLayout then self._hero_parent:resetLayout() end
    if old_hero and old_hero.free then
        UIManager:nextTick(function() pcall(function() old_hero:free() end) end)
    end
    if scope then
        UIManager:setDirty(self, function() return "ui", scope end)
    else
        UIManager:setDirty(self, "ui")
    end
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
    -- While the module grid is showing (micro + not expanded) there's no book
    -- hero to swap; re-render the GRID instead so a d-pad focus-ring change
    -- (entering/leaving the hero zone, moving the cell cursor) shows. Mode
    -- switches still go through a full _rebuild. When expanded the slot holds
    -- the same status strip as book mode, so let it through.
    if self._hero_mode == "micro" and not self._expanded then
        self:_swapMicroHeroInPlace()
        return
    end
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
    -- No book-hero right column under the module grid (micro + not expanded),
    -- so status ticks / line-editor previews no-op there. When expanded the
    -- strip is the same widget as book mode, so let it through.
    if self._hero_mode == "micro" and not self._expanded then return false end
    if not self._hero_parent then return false end
    local hero = self._hero_card or self._hero_parent[1]
    if not hero or not hero.replaceRightColumn then return false end
    -- Memoised: this path fires on every minute tick / charging / wifi
    -- event and on each line-editor keystroke; the right column renders
    -- text only, so the cover-stripped memo record is fine.
    local current = self._preview_book or self:_currentHeroBook() or hero.book
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
    -- Tapping a shelf cover while the hero is showing the micro-module grid
    -- means "put this book in the hero" — leave micro mode for the book hero.
    -- The hero (grid -> book) and chip strip (the modules triangle clears)
    -- change, plus the tapped cover gains its highlight ring. Scope the
    -- refresh to the hero + chips band and a per-cover repaint, rather than
    -- flashing the whole shelf. (The fast in-place hero swap further down
    -- assumes a book hero is already mounted, so it can't cross this
    -- boundary; _rebuildRefreshHeroAndChips rebuilds the tree first.)
    if self._hero_mode == "micro" then
        -- Capture the tapped cover's PAINTED rect from the current tree before
        -- rebuilding: covers don't move between micro and book hero, so this
        -- rect still locates the cover afterwards, and the rebuilt tree isn't
        -- painted yet (its spine dimens are nil). Iterate the shelves the same
        -- way _repaintSelectionHighlight does so the finder depth matches.
        local cover_dimen
        if self._inner_vgroup and self._shelf_dims then
            local d = self._shelf_dims
            for r = 1, (d.n_shelves or 2) do
                local hg = self._inner_vgroup[(d.shelf_top_idx or 1) + 2 * (r - 1)]
                if hg then
                    local _p, _i, spine = _descendFindSpine(hg, book.filepath, 0)
                    if spine and spine.dimen then
                        cover_dimen = spine.dimen:copy()
                        break
                    end
                end
            end
        end
        self:_clearDpadFocus()
        self._hero_mode    = "current"
        self._expanded     = false
        self._preview_book = Repo.buildBook(book.filepath) or book
        -- #174: re-roll the per-book %quote token so each selection shows a
        -- different random highlight from the newly-selected book.
        pcall(function() require("lib/bookshelf_quotes").rerollBook() end)
        -- Hero (grid -> book) + chip strip change; scope to that band.
        self:_rebuildRefreshHeroAndChips()
        -- The rebuilt tree paints the tapped cover with its selection ring;
        -- refresh just that cover's rect (padded for the ring, which paints
        -- outside the card) so the border shows without flashing the shelf.
        if cover_dimen then
            local t = Screen:scaleBySize(4)
            cover_dimen.x = cover_dimen.x - t
            cover_dimen.y = cover_dimen.y - t
            cover_dimen.w = cover_dimen.w + 2 * t
            cover_dimen.h = cover_dimen.h + 2 * t
            UIManager:setDirty(self, function() return "ui", cover_dimen end)
        end
        return
    end
    local _perf_t0 = _gettime()
    local _perf_gap_ms = tap_t and ((_perf_t0 - tap_t) * 1000) or -1
    -- Tap-twice-to-open: a tap on the already-selected spine confirms
    -- the preview and opens the book. Composes with the spine highlight
    -- — first tap marks the spine with the thicker border, second tap
    -- on the same spine commits.
    if self._preview_book and self._preview_book.filepath == book.filepath then
        logger.dbg(string.format(
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
    -- Path only - both diff checks below compare filepaths; this runs on
    -- every preview tap, directly in the tap-latency path.
    local lastfile_fp = Repo.currentFilepath and Repo.currentFilepath()
    local was_diff = self._preview_book and lastfile_fp
                     and self._preview_book.filepath ~= lastfile_fp
    -- Capture the previously-selected filepath BEFORE the assignment below
    -- so _repaintSelectionHighlight can deselect the old spine.
    local prior_preview_fp = self._preview_book and self._preview_book.filepath
    local _perf_t1 = _gettime()
    -- Shelf books are built via buildBookMeta (no DocSettings) for speed.
    -- The hero needs book_pct / page_num / last_xp to render the progress
    -- bar and token lines, so upgrade to the full Book record here. Single-
    -- book DocSettings read on each preview tap is fine.
    self._preview_book = Repo.buildBook(book.filepath) or book
    -- #174: re-roll the per-book %quote token on each selection.
    pcall(function() require("lib/bookshelf_quotes").rerollBook() end)
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
    local is_diff = self._preview_book and lastfile_fp
                    and self._preview_book.filepath ~= lastfile_fp

    -- Selection-state boundary crossed → full rebuild (cheap; chip strip
    -- + shelves + footer in one pass) so the "currently reading" action
    -- chip flips its inverted/normal styling in lockstep with the
    -- preview state.
    if was_diff ~= is_diff then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        logger.dbg(string.format(
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
        logger.dbg(string.format(
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
    logger.dbg(string.format(
        "[bookshelf perf] _previewBook: branch=cold-rebuild tap_gap=%.0fms TOTAL=%.0fms",
        _perf_gap_ms, (_gettime() - _perf_t0) * 1000))
end

-- Cleanup hook: clears the plugin's tracked widget reference when this
-- BookshelfWidget instance is closed for any reason. main.lua wires the
-- callback in show().
function BookshelfWidget:onCloseWidget()
    self:_stopStatusTimer()
    -- Land any deferred nav state before we go away (e.g. closing bookshelf
    -- to open a book) so the page/cursor is durable for the next launch.
    self:_flushNavStateNow()
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
        -- Skip ONLY if a covers_fullscreen widget (typically ReaderUI)
        -- is above us -- in that case bookshelf isn't visible at all
        -- and the paint would be wasted (KOReader's compositor skips
        -- widgets under a covers_fullscreen widget anyway). A modal on
        -- top (KOReader's TouchMenu, an InfoMessage, a ConfirmBox)
        -- doesn't set covers_fullscreen, and bookshelf remains
        -- partially visible behind it -- in those cases keep updating
        -- the widget tree so that when the modal closes, the
        -- already-current pixels show through, instead of stale state
        -- that has to wait for the next minute timer to refresh
        -- (Wi-Fi token was the observed case: toggle Wi-Fi via the
        -- KOReader Network menu, expect bookshelf's Wi-Fi icon to
        -- reflect the new state when the menu closes).
        local stack = UIManager._window_stack
        if stack then
            local our_idx
            for i = 1, #stack do
                if stack[i].widget == self then our_idx = i; break end
            end
            if not our_idx then return end
            for i = our_idx + 1, #stack do
                local w = stack[i] and stack[i].widget
                if w and w.covers_fullscreen then return end
            end
        end
        local _hc = self._hero_card or (self._hero_parent and self._hero_parent[1])
        if not (_hc and _hc.replaceRightColumn) then return end
        if not self:_anyActiveRegionUses(tokens) then return end
        -- Force a fresh _buildDeviceState read at paint time. The event
        -- handlers above already invalidate the cache when the
        -- triggering event fires, but any intermediate paint between
        -- the event and this deferred fire() can re-warm the cache
        -- before the underlying hardware state has actually settled
        -- (Wi-Fi was the observed case: NetworkConnected fires, cache
        -- invalidated, an intermediate paint reads NetMgr:isWifiOn()
        -- while the radio state still lags by a few ms, caches the
        -- stale value with a 2s TTL, and the +300ms gated repaint
        -- then renders the stale cached state). Invalidating right
        -- before the read guarantees the hardware value used here is
        -- as up-to-date as it can be.
        _device_state_expires_at = 0
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
        if self._hero_mode == "micro" and not self._expanded then
            -- Micro grid is the hero: advance its clock cells in place
            -- (scoped, no re-roll of the other modules). No-op if the grid
            -- has no clock.
            require("lib/bookshelf_hero_modules").tickClocks(self)
        else
            -- Book hero: repaint the status strip iff a template uses a
            -- time-driven token.
            self:_gatedRepaint(TIMER_TOKENS)
        end
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
    -- Cancel any pending cover-preload chunks (next-page warm-up). Open-book
    -- and teardown both route through here, so the deferred decode never
    -- fires against a backgrounded / torn-down widget.
    self:_cancelPreload()
    -- Chip preload is a background task; cancel its in-flight chunks too.
    -- _warmed_chip_keys is intentionally NOT reset -- if the pre-warm got far
    -- enough before being cancelled, those covers stay cached and we don't
    -- want to re-warm them when the widget comes back.
    self:_cancelChipPreload()
    -- File-poll: stop probing the filesystem while bookshelf isn't visible
    -- (reader has the foreground / widget torn down). Restarts on the next
    -- _rebuild when the user returns.
    self:_cancelFilePoll()
end

-- ─── Event hooks for non-time state changes ────────────────────────────────
-- KOReader broadcasts these via UIManager:broadcastEvent — they reach
-- widgets in the window stack including covered ones. We still gate on
-- the topmost check inside _gatedRepaint so a battery state change
-- during a read doesn't try to paint over the reader.

-- _device_state_expires_at is the 2s TTL guard on hardware reads in
-- _buildDeviceState. The repaints these handlers schedule call
-- _swapHeroRightColumnInPlace, which calls _buildDeviceState -- and
-- the cache served stale values inside the TTL window, so the broadcast
-- "state changed" event ended up painting the OLD light / batt / wifi
-- reading until the cache expired naturally. The fix is to mark the
-- cache expired here, before queueing the repaint, so the upcoming
-- _buildDeviceState forces a fresh PowerD / NetMgr read. The TTL still
-- coalesces unrelated rapid rebuilds (preview taps, _rebuild bursts);
-- it just no longer overrides "we know this just changed."
function BookshelfWidget:onFrontlightStateChanged()
    _device_state_expires_at = 0
    self:_gatedRepaint(FRONTLIGHT_TOKENS, 0.3)
end
function BookshelfWidget:onCharging()
    _device_state_expires_at = 0
    self:_gatedRepaint(BATTERY_TOKENS, 0.3)
end
function BookshelfWidget:onNotCharging()
    _device_state_expires_at = 0
    self:_gatedRepaint(BATTERY_TOKENS, 0.3)
end
function BookshelfWidget:onNetworkConnected()
    _device_state_expires_at = 0
    self:_gatedRepaint(WIFI_TOKENS, 0.3)
end
function BookshelfWidget:onNetworkDisconnected()
    _device_state_expires_at = 0
    self:_gatedRepaint(WIFI_TOKENS, 0.3)
end
-- KOReader broadcasts ToggleNightMode (no-arg toggle) AND SetNightMode
-- (pass true/false) — both routed to DeviceListener which actually flips
-- night_mode and dirty-marks "all" widgets. Bookshelf needs its own
-- repaint after the flip so the %nightmode glyph picks up the new
-- moon/sun state. Don't return true — we want DeviceListener's handler
-- to also run.
-- Night mode toggles invalidate the resolvedColors cache (it's keyed on
-- is_night), but the live widget tree still holds spine widgets painted
-- with the OLD palette. Without an explicit rebuild, KOReader's
-- framebuffer-level night inversion flips those stale paints, so a
-- user who has set both day and night border colors to dark sees the
-- old palette inverted instead of the matching night palette applied.
--
-- The rebuild MUST be deferred to nextTick. DeviceListener:onToggleNightMode
-- writes the new "night_mode" setting LAST (after broadcasting the event),
-- so if we rebuild synchronously inside the broadcast loop, resolvedColors
-- still reads the OLD is_night value and bakes the wrong palette into
-- folder cards / placeholder covers (those bake at construction time;
-- paintBorder reads colors per-paint and isn't affected). Running on
-- nextTick lets DeviceListener's write land first.
local function _scheduleNightModeRebuild(self)
    UIManager:nextTick(function()
        if self._rebuild then
            self:_rebuild()
            UIManager:setDirty(self, "ui")
        end
    end)
    self:_gatedRepaint(NIGHTMODE_TOKENS, 0.3)
end
function BookshelfWidget:onToggleNightMode()
    _scheduleNightModeRebuild(self)
end
function BookshelfWidget:onSetNightMode()
    _scheduleNightModeRebuild(self)
end

-- Sleep / wake hooks: stop the timer entirely on suspend so the device
-- can sleep cleanly with no pending callbacks; re-arm + immediate tick
-- on wake so visible state catches up without the user waiting up to
-- a full minute.
function BookshelfWidget:onSuspend()
    self:_stopStatusTimer()
    -- Suspend can be followed by a SIGTERM (Kindle frame switch) that never
    -- reaches onCloseWidget, so land deferred nav state here too.
    self:_flushNavStateNow()
end

-- KOReader broadcasts onFlushSettings on its periodic autosave and on a
-- clean exit. Piggy-back our coalesced nav-state flush onto it so the
-- deferred write lands on the same cadence as the rest of KOReader's
-- settings, independent of the debounce timer.
function BookshelfWidget:onFlushSettings()
    self:_flushNavStateNow()
end

function BookshelfWidget:onResume()
    self:_startStatusTimer()
    -- File poll cancelled by onSuspend / _stopStatusTimer on the way
    -- into sleep; bring it back so a wake-up detects any files synced
    -- while the device was suspended. Idempotent.
    self:_startFilePoll()
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

-- Auto-rotate (gyro) + manual rotate. KOReader's gesture/gyro layer sends a
-- SetRotationMode event through the main loop's sendEvent rather than
-- broadcasting it (device/input.lua), so "only widgets that know how to handle
-- a rotation will do so" -- a widget opts in by implementing this handler.
-- ReaderView and FileManager both do, which is why the book auto-rotates but
-- the bookshelf homescreen didn't: it had rotation-aware layout (_rebuild reads
-- the swapped Screen dims) but no event handler to trigger it, so it only
-- caught up when some other action forced a repaint (issue #123).
--
-- _rebuild re-reads Screen:getWidth/Height (which swap on rotation) and
-- re-lays-out for the new orientation, so a single rebuild + full (flashing)
-- refresh handles both the portrait<->landscape and 180-degree-flip cases and
-- clears e-ink ghosting from the old orientation. Returns true to consume:
-- bookshelf is the visible homescreen and has fully handled the rotation.
function BookshelfWidget:onSetRotationMode(mode)
    local old_mode = Screen:getRotationMode()
    if mode ~= nil and mode ~= old_mode then
        Screen:setRotationMode(mode)
        self:_rebuild()
        UIManager:setDirty(self, "full")
        -- Stamp the new geometry so a SetRotationMode+onScreenResize pair (some
        -- platforms fire both) doesn't rebuild twice.
        self._last_geom_w, self._last_geom_h = Screen:getWidth(), Screen:getHeight()
    end
    return true
end

-- Android (Boox etc.) and the desktop deliver an orientation change as a window/
-- surface RESIZE -- onScreenResize, often with NO SetRotationMode event -- so
-- onSetRotationMode above never fires. Without this handler the homescreen stays
-- laid out for the old geometry and, crucially, nothing issues a full refresh,
-- so the panel goes white and only recovers when something else forces a flush
-- (a Boox user saw white-until-sleep/wake on portrait->landscape). Rebuild for
-- the new dimensions and do a full (flashing) refresh, mirroring the rotation
-- path. Coalesced onto nextTick so a desktop resize-drag's event storm rebuilds
-- once after the dimensions settle; guarded on an actual change so a same-size
-- resize (or the post-rotation duplicate) is a no-op. NOT consumed (no `return
-- true`): ReaderView and others also handle resize.
function BookshelfWidget:onScreenResize()
    if self._resize_rebuild_pending then return end
    self._resize_rebuild_pending = true
    UIManager:nextTick(function()
        self._resize_rebuild_pending = false
        local w, h = Screen:getWidth(), Screen:getHeight()
        if self._last_geom_w == w and self._last_geom_h == h then return end
        self._last_geom_w, self._last_geom_h = w, h
        self:_rebuild()
        UIManager:setDirty(self, "full")
    end)
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
    if not self._overlap_group or not self._shelf_dims then return end
    local d      = self._shelf_dims
    local total  = self._total_pages or 1
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local new_row    = self:_buildFooterRow(d.content_w, total, d.FOOTER_H)
    local new_anchor = BottomContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height - d.FOOTER_BOTTOM_MARGIN },
        new_row,
    }
    local old = self._overlap_group[d.footer_overlap_idx]
    self._overlap_group[d.footer_overlap_idx] = new_anchor
    if self._overlap_group.resetLayout then self._overlap_group:resetLayout() end
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

    -- Hero micro grid: step up a row; at the top row stay put (hero is the
    -- topmost zone).
    if self._focus_zone == "hero" and self:_heroIsMicroGrid() then
        self:_heroMicroNav("up")
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
            elseif self:_heroIsMicroGrid() then
                -- Micro grid: enter the hero and land on its bottom row.
                self._cursor_idx = nil
                self:_swapShelvesInPlace()   -- clear cursor border from grid
                self:_enterHeroMicro()
            elseif not self._expanded and self._hero_mode ~= "micro" then
                -- Book hero is a single focusable unit; the expanded strip and
                -- non-d-pad micro mode have no focusable hero, so skip it.
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
            if self:_heroIsMicroGrid() then
                self:_enterHeroMicro()
            else
                self._focus_zone = "hero"
                self:_swapHeroInPlace()
            end
        end
        return true
    end

    if self._focus_zone == "selection_overlay" then
        local items    = self._page_items or {}
        local last_idx = 0
        for i = #items, 1, -1 do if items[i] then last_idx = i; break end end
        self._sel_overlay_slot  = nil
        self._focus_zone        = "grid"
        self._cursor_idx        = last_idx > 0 and last_idx or 1
        self:_refreshBucket()
        self:_swapShelvesInPlace()
        return true
    end

    if self._focus_zone == "footer" then
        local items    = self._page_items or {}
        local last_idx = 0
        for i = #items, 1, -1 do if items[i] then last_idx = i; break end end
        self._footer_cursor_btn = nil
        if self._selection:isActive() then
            self._sel_overlay_slot = "bucket"
            self._focus_zone       = "selection_overlay"
            self:_swapFooterInPlace()
            self:_refreshBucket()
        else
            self._focus_zone = "grid"
            self._cursor_idx = last_idx > 0 and last_idx or 1
            self:_swapFooterInPlace()
            self:_swapShelvesInPlace()
        end
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
        -- Micro grid: step down a row first; only leave the hero (to chips /
        -- grid) once the cursor is on the bottom row.
        if self:_heroIsMicroGrid() and self:_heroMicroNav("down") then
            return true
        end
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
            if self._selection:isActive() then
                -- In select mode: land on selection_overlay before footer.
                self._sel_overlay_slot = "bucket"
                self._focus_zone       = "selection_overlay"
                self:_refreshBucket()
                return true
            end
            if total <= 1 then
                -- Single page: pagination buttons are disabled, but the
                -- start-menu slot is still reachable (selection is off here;
                -- the active-selection branch above exits before this point).
                if self:_startMenuPosition() == "off" then
                    -- ...unless the start menu is hidden: nothing in the
                    -- footer is focusable, so keep focus in the grid.
                    return true
                end
                self._footer_cursor_btn = "menu"
                self._focus_zone        = "footer"
                self:_swapFooterInPlace()
                return true
            end
            self._footer_cursor_btn = "next"
            self._focus_zone        = "footer"
            self:_swapFooterInPlace()
            return true
        end
        return self:_moveCursor(n_cols)
    end

    if self._focus_zone == "selection_overlay" then
        self._sel_overlay_slot  = nil
        self._focus_zone        = "footer"
        self._footer_cursor_btn = "page"
        self:_refreshBucket()
        self:_swapFooterInPlace()
        return true
    end

    return true
end

-- _footerNeighbour(cur, page, total, dir, sel_active, menu_pos)
-- Returns the key of the nearest enabled footer button in direction dir
-- (dir=1 for right, dir=-1 for left), or nil if there is none.
-- menu_pos is the start-menu position setting ("left"/"right"/"off"):
-- two static order tables (rather than one runtime-built list) keep the
-- d-pad order matching the on-screen order - the menu slot sits before
-- the chevrons when the hamburger is on the left and after them when it
-- is on the right. "off" disables the slot via _footerBtnEnabled.
-- "micromod" (the full-screen grid button) sits in the corner OPPOSITE the
-- start menu, so it caps the order on the far side from "menu" (and, when the
-- menu is "off", on the right via the LEFT table the off case falls back to).
local _FOOTER_ORDER_LEFT  = {"menu","first","prev","page","next","last","micromod"}
local _FOOTER_ORDER_RIGHT = {"micromod","first","prev","page","next","last","menu"}
local function _footerBtnEnabled(k, page, total, sel_active, menu_pos)
    if k == "menu" then return not sel_active and menu_pos ~= "off" end
    if k == "micromod" then
        return not sel_active and BookshelfSettings.microFullscreenButton()
    end
    if k == "first" or k == "prev" then return page > 1 end
    if k == "page"                  then return true end
    -- "next" or "last"
    return page < total
end
local function _footerNeighbour(cur, page, total, dir, sel_active, menu_pos)
    local order = menu_pos == "right" and _FOOTER_ORDER_RIGHT or _FOOTER_ORDER_LEFT
    local cur_i = 0
    for i, k in ipairs(order) do
        if k == cur then cur_i = i; break end
    end
    if cur_i == 0 then return nil end
    local i = cur_i + dir
    while i >= 1 and i <= #order do
        local k = order[i]
        if _footerBtnEnabled(k, page, total, sel_active, menu_pos) then return k end
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

    -- Hero micro grid: move to the previous cell in the row; stay put at the
    -- left edge (the hero is a closed 2D field — Back leaves it).
    if self._focus_zone == "hero" and self:_heroIsMicroGrid() then
        self:_heroMicroNav("left")
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

    if self._focus_zone == "selection_overlay" then
        -- Left moves focus to exit_x slot (the ✕ on the left).
        if (self._sel_overlay_slot or "bucket") ~= "exit_x" then
            self._sel_overlay_slot = "exit_x"
            self:_refreshBucket()
        end
        return true
    end

    if self._focus_zone == "footer" then
        local total   = self._total_pages or 1
        local new_btn = _footerNeighbour(self._footer_cursor_btn, self.page, total, -1,
            self._selection:isActive(), self:_startMenuPosition())
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

    -- Hero micro grid: move to the next cell in the row; stay put at the right
    -- edge.
    if self._focus_zone == "hero" and self:_heroIsMicroGrid() then
        self:_heroMicroNav("right")
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

    if self._focus_zone == "selection_overlay" then
        -- Right moves focus to bucket slot (the U-bucket on the right).
        if (self._sel_overlay_slot or "bucket") ~= "bucket" then
            self._sel_overlay_slot = "bucket"
            self:_refreshBucket()
        end
        return true
    end

    if self._focus_zone == "footer" then
        local total   = self._total_pages or 1
        local new_btn = _footerNeighbour(self._footer_cursor_btn, self.page, total, 1,
            self._selection:isActive(), self:_startMenuPosition())
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
        -- Micro grid: activate the focused cell exactly as a tap would.
        if self:_heroIsMicroGrid() then
            local HeroModules = require("lib/bookshelf_hero_modules")
            local rec = self._hero_cell_cursor and self._hero_cells
                        and self._hero_cells[self._hero_cell_cursor]
            if rec and rec.entry then
                HeroModules._tap(self, rec.entry,
                    function() HeroModules._reloadCellById(self, rec.entry.id) end)
            end
            return true
        end
        local book = self._preview_book
            or self:_currentHeroBook()
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
            elseif key == self.chip then
                -- Already-active navigable chip: tap opens the editor
                -- (same affordance as touch — chip_bar.onTapStrip
                -- dispatches to on_hold when chip.key == self.active).
                -- Without this branch, pressing Enter on the focused
                -- active chip is a silent no-op.
                self:_clearDpadFocus()
                if self._chip_bar and self._chip_bar.on_hold then
                    self._chip_bar.on_hold(key)
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
        if item.filepath and not item.kind then
            -- Single-book cover.
            if self._selection:isActive() then
                -- In select mode: toggle selection instead of opening/previewing.
                self._selection:toggle(item.filepath)
                self:_refreshCoverFrame(item.filepath)
                self:_refreshBucket()
                return true
            end
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
            elseif item.kind == "language" then
                self:_expandLanguage(item)
            elseif item.books then
                self:_expandSeries(item)
            end
        end
        return true
    end

    if self._focus_zone == "selection_overlay" then
        local slot = self._sel_overlay_slot or "bucket"
        if slot == "bucket" then
            self:_openBulkMenu()
        else
            -- exit_x slot: exit selection mode.
            local prev = self._selection:count()
            self._sel_overlay_slot = nil
            self._focus_zone       = nil
            self._selection:exitMode()
            self:_rebuild()
            UIManager:setDirty(self, "ui")
            if prev > 0 then
                local ok_n, Notification = pcall(require, "ui/widget/notification")
                if ok_n and Notification then
                    UIManager:show(Notification:new{
                        text    = _("Selection cleared"),
                        timeout = 1,
                    })
                end
            end
        end
        return true
    end

    if self._focus_zone == "footer" then
        local btn   = self._footer_cursor_btn
        local total = self._total_pages or 1
        if btn == "menu" and not self._selection:isActive() then
            self:_openStartMenu()
            return true
        elseif btn == "micromod" and not self._selection:isActive() then
            self:_openMicroModulesFullscreen()
            return true
        elseif btn == "first" and self.page > 1 then
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

-- onBSKbHold: keyboard / d-pad equivalent of long-press. Triggered by
-- the ScreenKB+Press / Shift+Press / Sym+AA chords (defined in init,
-- mirroring KOReader's FocusManager hold gestures). Dispatches to
-- the touch on_hold-equivalent for the currently focused zone:
--   hero  → _showBookDetail(book) on the previewed/lastfile
--   chips → on_hold(chip_key) which opens the chip editor
--           (action chips and breadcrumb mode get no menu)
--   grid  → _showBookDetail for books, _openGroupMenu for stacks /
--           folders. Books in selection mode are suppressed (matching
--           the touch contract); stacks in selection mode still open
--           the Pin / Add / Remove dialog.
function BookshelfWidget:onBSKbHold()
    if self._focus_zone == "hero" then
        -- Micro grid: long-press the focused cell (opens the module's edit /
        -- pin / remove menu, same as a touch hold).
        if self:_heroIsMicroGrid() then
            local HeroModules = require("lib/bookshelf_hero_modules")
            local rec = self._hero_cell_cursor and self._hero_cells
                        and self._hero_cells[self._hero_cell_cursor]
            if rec and rec.entry and HeroModules._hold then
                HeroModules._hold(self, rec.entry)
            end
            return true
        end
        if self._selection and self._selection:isActive() then return true end
        local book = self._preview_book
            or self:_currentHeroBook()
        if book then
            self:_clearDpadFocus()
            self:_showBookDetail(book, { active = "edit" })
        end
        return true
    end
    if self._focus_zone == "chips" then
        -- Breadcrumb mode: no edit affordance, mirror touch behaviour.
        if #self._drilldown_path > 0 then return true end
        local key = self._chip_cursor_key
        if not key then return true end
        -- Action chips (current, search) don't expose an editor on
        -- long-press in chips mode either.
        if self._action_chip_keys and self._action_chip_keys[key] then
            return true
        end
        self:_clearDpadFocus()
        if self._chip_bar and self._chip_bar.on_hold then
            self._chip_bar.on_hold(key)
        end
        return true
    end
    if self._focus_zone == "grid" then
        local idx  = self._cursor_idx
        local item = idx and self._page_items and self._page_items[idx]
        if not item then return true end
        if item.filepath and not item.kind then
            -- Book cover: suppressed in selection mode (no per-book
            -- menu while bulk-selecting — same as touch).
            if self._selection and self._selection:isActive() then return true end
            self:_clearDpadFocus()
            self:_showBookDetail(item, { active = "edit" })
        else
            -- Stack / folder. Selection-mode shows the Pin / Add /
            -- Remove dialog rather than the chip-pin menu — both end
            -- up in _openGroupMenu which routes by current state.
            self:_clearDpadFocus()
            if item.kind == "folder" then
                self:_openGroupMenu(item, "folder")
            elseif item.books then
                self:_openGroupMenu(item, item.kind)
            end
        end
        return true
    end
    -- Selection overlay / footer / search bar: no hold action today.
    return true
end

-- _setActiveChip(key) — switch tabs as if the user tapped a chip.
-- Mirrors the on_change closure in _rebuild so swipe-cycling and tap
-- both produce identical state transitions.
-- Rebuild, then refresh ONLY below the hero so the unchanged hero cover isn't
-- repainted -- repainting it flashes on panels with HW dithering, on chip
-- switch / page nav (issue #124). Both the chip-tap closure and _setActiveChip
-- (swipe) route through here so the scoping can't drift between them. Prefers
-- the hero's live painted dimen; falls back to the stashed hero geometry, then
-- a full refresh.
function BookshelfWidget:_rebuildRefreshBelowHero()
    local prev_hero  = self._hero_parent and self._hero_parent[1]
    local hero_dimen = prev_hero and prev_hero.dimen
    self:_rebuild()
    local below_y
    if hero_dimen and hero_dimen.y and hero_dimen.h then
        below_y = hero_dimen.y + hero_dimen.h
    elseif self._hero_dims and self._hero_dims.hero_h then
        below_y = (self._hero_dims.PAD or 0) + self._hero_dims.hero_h
    end
    -- The hero cover's drop shadow fills the bottom SHADOW_OFFSET strip of the
    -- card, so its lower edge lands exactly on below_y. A scoped "ui" refresh
    -- whose hard top boundary sits flush against that soft-grey gradient leaves
    -- a faint residual flash there on weak panels with HW dithering (the #124
    -- tail). Nudge the band down past the shadow into the neutral PAD gap above
    -- the chip strip -- still well clear of the chips, which must stay in the
    -- refresh. SHADOW_OFFSET mirrors the value in bookshelf_spine_widget /
    -- bookshelf_hero_card.
    if below_y then
        below_y = below_y + Screen:scaleBySize(4)
        UIManager:setDirty(self, function()
            return "ui", Geom:new{ x = 0, y = below_y, w = self.width, h = self.height - below_y }
        end)
    else
        UIManager:setDirty(self, "ui")
    end
end

-- _rebuildRefreshHeroAndChips() — the mirror of _rebuildRefreshBelowHero, for
-- changes that touch the hero + chip strip but not the shelves below (the
-- hero-mode toggle: book hero <-> micro-module grid, which also flips the
-- chip triangles). Rebuilds the tree, then scopes the "ui" refresh to the
-- band from the top down to the bottom of the chip strip, so the shelves and
-- footer don't flash. Falls back to a full refresh if the chip strip's
-- painted geometry isn't available (e.g. chips hidden).
function BookshelfWidget:_rebuildRefreshHeroAndChips()
    local chip       = self._chip_bar
    local chip_dimen = chip and chip.dimen
    self:_rebuild()
    local bottom
    if chip_dimen and chip_dimen.y and chip_dimen.h then
        bottom = chip_dimen.y + chip_dimen.h
    end
    if bottom then
        -- Include a hair below the chip strip so its lower border refreshes
        -- cleanly (same margin rationale as _rebuildRefreshBelowHero).
        bottom = bottom + Screen:scaleBySize(4)
        UIManager:setDirty(self, function()
            return "ui", Geom:new{ x = 0, y = 0, w = self.width, h = bottom }
        end)
    else
        UIManager:setDirty(self, "ui")
    end
end

function BookshelfWidget:_setActiveChip(key)
    if not key or key == self.chip then return end
    -- Diag: wrap the chip-switch flow so the log shows the elapsed time
    -- between user action and rebuild-done. _rebuild logs its own
    -- breakdown; this outer log is the user-facing TOTAL.
    local _diag_t0   = _gettime()
    local _diag_from = self.chip
    self:_clearDpadFocus()
    -- Pre-paint feedback on the destination chip: same affordance taps
    -- get, so a swipe-driven tab change feels just as responsive even
    -- when the new tab is slow to fetch (Genres / Authors). The strip
    -- handles the actual paint and clears itself when _rebuild swaps in
    -- a fresh strip below.
    if self._chip_bar and self._chip_bar.flashPending then
        self._chip_bar:flashPending(key)
    end
    local _diag_t_flash = _gettime()
    self._drilldown_path = {}
    self.chip            = key
    self._cursor         = 1
    self:_syncPageFromCursor()
    -- Deferred: _rebuild's _persistNavState saves + schedules the
    -- coalesced flush; a sync save here added a ~140ms file write to
    -- every chip swipe.
    BookshelfSettings.saveDeferred("active_chip", key)
    -- Switching chips never changes the hero: it shows the previewed /
    -- currently-reading book, which is independent of the active chip
    -- (_setActiveChip doesn't touch _preview_book, and _rebuild re-resolves
    -- the hero to the same book, so it rebuilds pixel-identical). Refreshing
    -- the whole widget therefore re-flashed the hero on e-ink for no reason
    -- (issue #124). Capture the hero's painted bottom edge and scope the
    -- refresh to the chip strip + shelves + footer below it; the hero region
    -- is left untouched. Falls back to a full refresh if the hero hasn't
    -- painted yet (no dimen).
    self:_rebuildRefreshBelowHero()
    logger.dbg(string.format(
        "[bookshelf perf] chip-switch: from=%s to=%s flash=%.0fms rebuild=%.0fms TOTAL=%.0fms",
        _diag_from, key,
        (_diag_t_flash - _diag_t0) * 1000,
        (_gettime() - _diag_t_flash) * 1000,
        (_gettime() - _diag_t0) * 1000))
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

    -- Issue #172: same flash, NON-seamless path. Opening a book from inside
    -- the reader (History / Collections / Book shortcuts / prev-next) tears the
    -- old ReaderUI down and shows a *visible* "Opening file…" InfoMessage with a
    -- forced repaint before the new document loads. By then the old reader is
    -- gone and the parked shelf is the only window left, so that repaint paints
    -- us full-screen for ~1s. The guard above only catches the seamless
    -- (invisible) variant; this flag is set by Bookshelf:onCloseDocument when
    -- ReaderUI is tearing down to open another book, and cleared once the new
    -- reader is ready (or whenever the shelf is intentionally shown again).
    if self._suppress_transition_paint then return end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    if sw ~= self.width or sh ~= self.height then
        self:_rebuild()
    end
    -- Detect external toggles of KOReader's "Folders and files mixed"
    -- (e.g. user opens the FM Sort menu, flips the checkbox, closes the
    -- menu). The menu callback writes G_reader_settings directly with
    -- no Event broadcast, so we can't subscribe — but paintTo always
    -- fires when the overlying menu widget closes and bookshelf comes
    -- back to the top of the stack. The check is two boolean reads;
    -- only the actual-change path schedules a rebuild (deferred via
    -- nextTick so the current paint frame finishes cleanly).
    if not self._collate_mixed_refresh_pending then
        local cur_mixed = G_reader_settings
                          and G_reader_settings:isTrue("collate_mixed") or false
        if self._last_collate_mixed ~= nil
           and self._last_collate_mixed ~= cur_mixed then
            self._collate_mixed_refresh_pending = true
            UIManager:nextTick(function()
                self._collate_mixed_refresh_pending = false
                if self._rebuild then
                    self:_rebuild()
                    UIManager:setDirty(self, "ui")
                end
            end)
        end
    end
    -- Diag: one-shot first-paint marker for cold-start traces. The init
    -- log fires at end of :init() (well before the paint actually
    -- happens), and the Bookshelf:show TOTAL fires before UIManager has
    -- drained the show queue. This marker captures the actual
    -- show-to-first-pixel latency. Cleared so subsequent paints stay
    -- silent.
    if not self._diag_first_paint_done then
        self._diag_first_paint_done = true
        local _diag_paint_t0 = _gettime()
        InputContainer.paintTo(self, bb, x, y)
        self:_clearHeroMarker()
        do
            local FG = require("lib/bookshelf_footer_geom")
            if self._burger_dimen and self._burger_dimen.x then FG.rememberButtonRect(self._burger_dimen) end
            if self._micromod_dimen and self._micromod_dimen.x then FG.rememberGridRect(self._micromod_dimen) end
        end
        logger.dbg(string.format(
            "[bookshelf perf] paintTo: FIRST first_paint=%.0fms chip=%s",
            (_gettime() - _diag_paint_t0) * 1000, self.chip))
        return
    end
    InputContainer.paintTo(self, bb, x, y)
    self:_clearHeroMarker()
    -- Remember the footer buttons' real painted rects so the in-reader launcher
    -- matches them exactly (single Lua state; see bookshelf_footer_geom).
    do
        local FG = require("lib/bookshelf_footer_geom")
        if self._burger_dimen and self._burger_dimen.x then FG.rememberButtonRect(self._burger_dimen) end
        if self._micromod_dimen and self._micromod_dimen.x then FG.rememberGridRect(self._micromod_dimen) end
    end
end

-- Clear the home-screen hero crash marker once the shelf has actually painted.
-- If a hero module segfaults the paint pass, InputContainer.paintTo above never
-- returns, the sentinel survives, and the next launch falls back to the cover
-- hero (issue #163). Only meaningful in micro mode, which is what arms it.
function BookshelfWidget:_clearHeroMarker()
    if self._hero_mode == "micro" then
        pcall(Breaker.endFile, Breaker.heroMarkerPath())
    end
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

local function _readCoverSize()
    local v = BookshelfSettings.read("bookshelf_size")
    if v == "small" or v == "medium" or v == "large" then return v end
    return "medium"
end

local function _readHeroSize()
    local v = BookshelfSettings.read("hero_size")
    if v == "large" then return "large" end
    return "regular"  -- absorbs legacy "small"/"medium" and missing value
end

-- _bookGap(pad) — horizontal gap BETWEEN covers in a shelf row. The "small"
-- bookshelf size tightens the standard padding here to 0.75x (only the
-- inter-cover gap; outer margins and inter-row spacing keep the full pad) so
-- the otherwise-small covers reclaim a little of that space and render a
-- touch larger. The column count (_nCols) deliberately stays on the full
-- pad, so this widens each cover rather than fitting more of them. Must be a
-- method: _rebuild / _maxRows / _swapShelvesInPlace are defined earlier in
-- the file and reach it via the metatable, which a module-local declared
-- here wouldn't allow.
function BookshelfWidget:_bookGap(pad)
    if _readCoverSize() == "small" then
        return math.max(1, math.floor(pad * 0.75))
    end
    return pad
end

-- _maxRows() — max natural-cover rows that fit at the current n_cols
-- assuming the hero collapses to its minimum (status strip only). Used
-- as the expanded-mode row count and as the ceiling _baseShelves works
-- back from. Pure function of self dimensions + cover-size setting.
function BookshelfWidget:_maxRows()
    local PAD, content_w, chip_h, footer_h = self:_layoutPrimitives()
    local n_cols = self:_nCols()
    if n_cols < 1 then return 1 end
    -- Row-count budget uses the FULL pad, not _bookGap: this is the natural
    -- "how many 2:3 cover rows fit" ceiling. The render fills covers at the
    -- (wider) book_gap width into these full-PAD-budgeted rows, so a tighter
    -- gap yields slightly compressed covers rather than dropping a row.
    -- Computing the budget on book_gap instead inflated slot_h and silently
    -- cost an expanded row.
    local slot_w = math.floor((content_w - PAD * (n_cols - 1)) / n_cols)
    if slot_w < 1 then return 1 end
    local slot_h = math.floor(slot_w * 1.5)
    local row_h  = slot_h + PAD  -- shelf body + after-row PAD
    -- Chrome above + below the shelves. Mirrors the expanded-mode layout
    -- sum in _rebuild (outer top PAD + status strip + hero→chips gap +
    -- chip strip + chips→row1 PAD + footer).
    local strip_minimum   = Screen:scaleBySize(20)
    local hero_chip_pad   = Size.padding.large
    local outer_top_pad   = PAD
    local chip_to_row_pad = PAD
    local available = self.height - outer_top_pad - strip_minimum - hero_chip_pad
                    - chip_h - chip_to_row_pad - footer_h
    return math.max(1, math.floor(available / row_h))
end

-- _maxShelfRows() — the most shelf rows that fit at natural cover height
-- while still leaving the hero its minimum (HERO_MIN_FRAC) slice. Rows is
-- clamped to this so the grid + a usable hero never overflow the screen.
function BookshelfWidget:_maxShelfRows()
    local PAD, content_w, chip_h, footer_h = self:_layoutPrimitives()
    local n_cols = self:_nCols()
    if n_cols < 1 then return 1 end
    local slot_w = math.floor((content_w - PAD * (n_cols - 1)) / n_cols)
    if slot_w < 1 then return 1 end
    local slot_h = math.floor(slot_w * 1.5)
    local hero_chip_pad = Size.padding.large
    local usable = self.height - PAD - hero_chip_pad - chip_h - PAD - footer_h
    local row_unit = math.floor(slot_h * SHELF_PACK_FLOOR) + PAD
    if row_unit < 1 then return 1 end
    local min_hero = math.floor(usable * HERO_MIN_FRAC)
    return math.max(1, math.floor((usable - min_hero) / row_unit))
end

-- _baseShelves() — non-expanded shelf-row count.
--   * New model: the explicit bookshelf_rows setting, clamped to _maxShelfRows
--     (so the grid + minimum hero always fit). The hero then auto-sizes from
--     the leftover vertical space (see the geometry in _rebuild).
--   * Legacy fallback (bookshelf_rows unset): the old hero-size derivation —
--     rows fill the height left after a "regular" hero, "large" hero shows one
--     fewer — so existing layouts are preserved until the user opens the
--     Columns/Rows editor and writes an explicit value.
function BookshelfWidget:_baseShelves()
    local max_fit = self:_maxShelfRows()
    local rows = BookshelfSettings.read("bookshelf_rows")
    if type(rows) == "number" then
        return math.max(ROWS_MIN, math.min(math.floor(rows), max_fit))
    end
    -- Legacy derivation.
    local PAD, content_w, chip_h, footer_h = self:_layoutPrimitives()
    local n_cols = self:_nCols()
    if n_cols < 1 then return 1 end
    local slot_w = math.floor((content_w - PAD * (n_cols - 1)) / n_cols)
    if slot_w < 1 then return 1 end
    local slot_h = math.floor(slot_w * 1.5)
    local hero_chip_pad = Size.padding.large
    local usable = self.height - PAD - hero_chip_pad - chip_h - PAD - footer_h
    local hero_target  = math.floor(usable * (HERO_HEIGHT_FRAC.regular or 0.30))
    local row_unit = math.floor(slot_h * SHELF_PACK_FLOOR) + PAD
    if row_unit < 1 then return 1 end
    local n_regular = math.max(1, math.floor((usable - hero_target) / row_unit))
    if _readHeroSize() == "large" then
        n_regular = math.max(1, n_regular - 1)
    end
    return math.min(n_regular, max_fit)
end

-- _nShelves() — shelf row count for the current mode.
--   collapsed → _baseShelves() (= _maxRows - hero rows eaten)
--   expanded  → _maxRows() (hero collapses to a status strip so all
--                          rows the screen can natively hold render)
function BookshelfWidget:_nShelves()
    if self._expanded then
        -- Expanding (swipe-up, hero -> strip) must always reveal at least one
        -- more row than collapsed; covers squash via ShelfRow to make room.
        return math.max(self:_maxRows(), self:_baseShelves() + 1)
    end
    return self:_baseShelves()
end

-- _nCols() — columns per shelf row, DPI-independent.
--   * Portrait: the cover-size setting maps straight to a column count
--     (small=5 / medium=4 / large=3), identical on every device; covers are
--     sized to fit that many across content_w.
--   * Landscape/widescreen: a fixed column count would make covers too tall
--     for the short screen, so the size instead sets cover HEIGHT (% of screen
--     height) and the column count derives from that (shorter covers are
--     narrower, so more fit). CEIL the count so covers never exceed the target
--     height and still fill the width.
function BookshelfWidget:_nCols()
    -- Explicit Columns setting (new model); falls back to the legacy
    -- cover-size→columns mapping until the user sets it in the editor.
    local cols = BookshelfSettings.read("bookshelf_columns")
    if type(cols) ~= "number" then
        cols = COVER_SIZE_COLS[_readCoverSize()] or 4
    end
    cols = math.max(COLUMNS_MIN, math.min(COLUMNS_MAX, math.floor(cols)))
    if self:_isLandscape() then
        -- A fixed column count makes covers too tall on the short landscape
        -- screen, so raise the count until a cover is at most ~half the screen
        -- height (cover_h <= H/2  ⇔  cols >= 3*content_w/H). The user's column
        -- choice acts as a floor; landscape only ever adds more.
        local PAD, content_w = self:_layoutPrimitives()
        local min_cols = math.ceil(3 * content_w / math.max(1, self.height))
        return math.max(2, math.min(10, math.max(cols, min_cols)))
    end
    return cols
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

-- _selectedFilepath() — the single "selected book" across expand/collapse, so
-- the same book highlights in the 2-row grid, the expanded grid, and previews
-- in the hero. Priority: live d-pad focus cell > a pending expanded tap
-- (open-double's first tap) > the hero preview book. nil = nothing selected.
function BookshelfWidget:_selectedFilepath()
    if self._cursor_idx and self._page_items then
        local ci = self._page_items[self._cursor_idx]
        if ci then
            if     ci.filepath              then return ci.filepath end
            if     ci.first_book            then return ci.first_book.filepath end
            if     ci.books and ci.books[1] then return ci.books[1].filepath end
        end
    end
    if self._tap_selected_fp then return self._tap_selected_fp end
    if self._preview_book then return self._preview_book.filepath end
    return nil
end

-- _globalIndexOfFilepath(fp) — 1-based index of a book VISIBLE on the current
-- page within the active ordering, derived from the live cursor + the book's
-- slot in _page_items. Chip-agnostic: it never searches the whole library, so
-- it works for pre-sliced chips (search / all / folder) too. nil if fp isn't on
-- the current page.
function BookshelfWidget:_globalIndexOfFilepath(fp)
    if not fp or not self._page_items then return nil end
    for k, item in ipairs(self._page_items) do
        local ifp = item and (item.filepath
            or (item.first_book and item.first_book.filepath)
            or (item.books and item.books[1] and item.books[1].filepath))
        if ifp == fp then
            return (self._cursor or 1) + (k - 1)
        end
    end
    return nil
end

-- _setCursorToShow(global_idx) — move the cursor so the given 1-based global
-- index lands on the visible page, page-aligned at the CURRENT view size. Call
-- AFTER toggling expand/collapse so it aligns to the new row count. No-op for a
-- nil index (book not located).
function BookshelfWidget:_setCursorToShow(global_idx)
    if not global_idx then return end
    local view = self:_viewSize()
    self._cursor = math.max(1, math.floor((global_idx - 1) / view) * view + 1)
    self:_clampCursor()
    self:_syncPageFromCursor()
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

-- ─── Experimental: next-page cover preload ───────────────────────────────
-- Cold pages are slow because each cover is decoded (BIM zstd) + scaled on
-- first paint. When the "Preload next page" setting is on, after a page-turn
-- settles we warm the NEXT page's covers (in the direction last paged) into
-- ScaledCoverCache during idle time, so the following turn paints from cache.
--
-- KOReader is single-threaded, so this is a CHUNKED deferred task: a couple
-- of covers per scheduled tick, re-armed until done. It yields to input
-- between chunks and is cancelled the instant the user pages again, switches
-- chip, opens a book, or the widget rebuilds/closes.
--
-- OOM safety (this plugin has crashed on large Series/Authors/Genres
-- libraries before): warms at most one page, optionally one page of each
-- OTHER chip; routes through the bounded LRU cache; and NEVER calls
-- buildBookMeta for off-screen books -- group drilldowns are sliced straight
-- from the payload, search is skipped, and every other path fetches lazily
-- (no cover decode) then decodes one cover at a time, freeing the source bb
-- after scaling.
local PRELOAD_START_DELAY_S = 0.35   -- let the current page's EPDC flush drain first
local PRELOAD_TICK_S        = 0.05   -- gap between chunks
local PRELOAD_CHUNK         = 4      -- covers warmed per tick (upper bound)
-- Main-thread time budget per chunk. PRELOAD_CHUNK alone is a count budget:
-- fine on fast hardware (4 jobs ≈ a few ms) but on a 1GHz e-ink device 4
-- cover decodes can hold the main thread 200-600ms per 50ms tick, so taps
-- land with visible lag for several seconds right after the boot paint --
-- "shelf is shown but not responsive". The deadline caps each chunk to
-- roughly one frame of work; slow devices degrade to 1 job per tick and the
-- preload stretches out instead of starving gestures.
local PRELOAD_CHUNK_BUDGET_S = 0.03
-- Chip preload starts later than next-page preload so the initial _rebuild's
-- paint and the first user gestures get a clear main-thread runway. It only
-- ever runs once per widget instance (see _maybeStartChipPreload).
local CHIP_PRELOAD_DELAY_S  = 1.0
-- When next-page preload is active (queued or running), the chip-preload step
-- defers itself by this amount to avoid competing for the main thread mid
-- page-turn. ~250ms is two next-page chunks: long enough for one chunk to
-- complete, short enough that chip preload resumes promptly when idle.
local CHIP_PRELOAD_YIELD_S  = 0.25

-- Apply the user's cover-cache RAM budget (in MB). Called on every page turn
-- (cheap) so the setting tracks live even when preload is off -- a bigger
-- budget also helps plain back-and-forth browsing.
local COVER_CACHE_DEFAULT_MB = 24
function BookshelfWidget:_applyCoverCacheBudget()
    -- One-time migration: the cache used to be sized by entry COUNT
    -- (cover_cache_size). It's now an explicit RAM budget in MB, so discard the
    -- stale count key -- everyone starts fresh on the MB default. Cheap: the
    -- read returns nil once deleted, so this no-ops after the first call.
    if BookshelfSettings.read("cover_cache_size") ~= nil then
        BookshelfSettings.delete("cover_cache_size")
    end
    local mb = BookshelfSettings.read("cover_cache_mb") or COVER_CACHE_DEFAULT_MB
    require("lib/bookshelf_scaled_cover_cache"):setByteBudget(mb * 1024 * 1024)
end

function BookshelfWidget:_cancelPreload()
    if self._preload_fn then
        UIManager:unschedule(self._preload_fn)
        self._preload_fn = nil
    end
    self._preload_queue = nil
    self._preload_seen  = nil
end

function BookshelfWidget:_cancelChipPreload()
    if self._chip_preload_fn then
        UIManager:unschedule(self._chip_preload_fn)
        self._chip_preload_fn = nil
    end
    self._chip_preload_queue = nil
    self._chip_preload_seen  = nil
    self._chip_preload_keys  = nil
end

-- Cover-area dimensions of the shelf slots the LAST render actually produced,
-- so the preload warms next-page covers at exactly that size and the render
-- gets a cache HIT instead of a synchronous re-decode. ShelfRow reports the
-- real dims (cover_w/cover_h) it computed -- already accounting for DPI,
-- expanded vs collapsed, the stretch/shrink-to-budget logic, and the title
-- strip -- which is far more robust than re-deriving that math here (it would
-- drift the moment any of those inputs changed). The cover area is >= the
-- bordered image SpineWidget paints, so a warm at this size always satisfies
-- ScaledCoverCache's "cached >= requested" check.
--
-- Falls back to the width-based slot only if a render hasn't reported dims yet
-- (e.g. first preload before the very first shelf build). Returns nil if
-- layout dims aren't ready at all.
function BookshelfWidget:_currentSlotDims()
    local d = self._shelf_dims
    if not d or not d.content_w then return nil end
    if d.cover_w and d.cover_h and d.cover_w >= 1 and d.cover_h >= 1 then
        return d.cover_w, d.cover_h
    end
    local n = self:_nCols()
    if not n or n < 1 then return nil end
    local sw = math.floor((d.content_w - (d.book_gap or d.PAD or 0) * (n - 1)) / n)
    if sw < 1 then return nil end
    return sw, math.floor(sw * 1.5)
end

-- Append up to one page of {fp,w,h} cover jobs for `chip_key` at `cursor`
-- into `jobs` (deduped via `seen`). Read-only: borrows self.chip/_cursor for
-- the fetch then restores them. Avoids the buildBookMeta-heavy paths.
function BookshelfWidget:_collectPageCovers(jobs, seen, chip_key, cursor, w, h)
    if cursor < 1 then return end
    local view = self:_viewSize()
    local function add(fp)
        if fp and fp ~= "" and not seen[fp] then
            seen[fp] = true
            jobs[#jobs + 1] = { fp = fp, w = w, h = h }
        end
    end
    -- Folder items on the Home chip pay a hidden cost at render time: shelf
    -- row's folder-card branch calls Repo.getFolderBookPaths(path) (recursive
    -- lfs walk) for badge counts. That walk is cached after the first call,
    -- so backwards-paging is fast (folders previously walked), but a cold
    -- forward page pays the walks during _buildShelfRows. Pre-warm them as
    -- separate job entries so the deferred preload chunks pay the cost
    -- instead of the page turn.
    local function add_folder(path)
        local key = path and ("folder:" .. path)
        if key and not seen[key] then
            seen[key] = true
            jobs[#jobs + 1] = { folder_path = path }
        end
    end
    local tip = self._drilldown_path[#self._drilldown_path]
    -- Group drilldown of the current view: slice filepaths straight from the
    -- payload (no buildBookMeta). Search: skip (always decodes).
    if chip_key == self.chip and tip then
        if tip.kind == "search" then return end
        if tip.payload and tip.payload.books then
            local books = tip.payload.books
            local off = cursor - 1
            for i = off + 1, math.min(off + view, #books) do
                if books[i] then add(books[i].filepath) end
            end
            return
        end
    end
    -- Top-level chip (or folder drilldown for the current chip): borrow
    -- chip + cursor, fetch lazily (lazy_cover -> no cover decode), restore.
    local save_chip, save_cursor = self.chip, self._cursor
    self.chip    = chip_key
    self._cursor = cursor
    local ok, items = pcall(self._fetchChipItems, self, 400)
    self.chip    = save_chip
    self._cursor = save_cursor
    if not ok or not items then return end
    -- _fetchChipItems applies the cursor offset itself (LIMIT == viewSize),
    -- so the returned list IS the target window -- iterate it directly,
    -- capped defensively at one page.
    for i = 1, math.min(#items, view) do
        local item = items[i]
        if item then
            add(item.filepath)
            if item.first_book then add(item.first_book.filepath) end
            if item.books then
                for j = 1, math.min(3, #item.books) do
                    if item.books[j] then add(item.books[j].filepath) end
                end
            end
            -- Folder items: pre-warm the recursive walk used by the folder
            -- badge so the page turn doesn't pay it. item.kind=="folder"
            -- is the Home-chip folder card; item.path is the folder root.
            if item.kind == "folder" and item.path then
                add_folder(item.path)
            end
        end
    end
end

-- Shared cover-warm primitive: given a list of {fp, w, h} jobs, decode +
-- scale each that's not already cached, putting the scaled bb into the cache.
-- Updates a counter table (decoded/already/failed) so the caller can log
-- progress. Processes up to `chunk` jobs and returns the count actually done.
local function _warmChunk(jobs, chunk, counters)
    local ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
    local done = 0
    -- Count cap AND time budget: the first job always runs, then we stop as
    -- soon as the budget is spent, so one slow decode can't chain into a
    -- multi-hundred-ms main-thread block (see PRELOAD_CHUNK_BUDGET_S).
    local deadline = _gettime() + PRELOAD_CHUNK_BUDGET_S
    while done < chunk and #jobs > 0 and (done == 0 or _gettime() < deadline) do
        local job = table.remove(jobs, 1)
        done = done + 1
        if job.folder_path then
            -- Folder badge pre-warm: invoke the recursive walk so its result
            -- is in Repo's _folder_book_paths_cache before the page render.
            -- Also queue per-book readProgress warm jobs (one per contained
            -- book filepath) at the end of the queue so finished_count's
            -- per-book sidecar reads also hit cache. Spreading those across
            -- subsequent ticks keeps each chunk's main-thread time bounded
            -- regardless of folder size.
            local ok_paths, paths = pcall(Repo.getFolderBookPaths, job.folder_path)
            counters.folders = (counters.folders or 0) + 1
            if ok_paths and paths then
                for _i = 1, #paths do
                    jobs[#jobs + 1] = { progress_fp = paths[_i] }
                end
            end
        elseif job.progress_fp then
            -- Per-book status pre-warm so finished_count's readProgress hits
            -- _progress_cache (120s TTL) on the next page render.
            pcall(Repo.readProgress, job.progress_fp)
            counters.progress = (counters.progress or 0) + 1
        elseif job.fp then
            if ScaledCoverCache:has(job.fp) then
                counters.already = counters.already + 1
            else
                local ok_bb, bb = pcall(Repo.getCoverBB, job.fp)
                if ok_bb and bb then
                    local ok_s, scaled = pcall(function() return bb:scale(job.w, job.h) end)
                    if ok_s and scaled then
                        pcall(function() ScaledCoverCache:put(job.fp, scaled) end)
                        counters.decoded = counters.decoded + 1
                    else
                        counters.failed = counters.failed + 1
                    end
                    pcall(function() bb:free() end)
                else
                    counters.failed = counters.failed + 1
                end
            end
        end
    end
    return done
end

-- Build the cover-job queue for the next page of the current chip in the
-- paged direction. Cheap fetch (one chip, lazy_cover), small queue (~8
-- covers). (The chip warm-up no longer batches here: _chipPreloadStep pulls
-- one chip's page per tick so a cold multi-chip fetch can't occupy a single
-- tick.)
function BookshelfWidget:_buildPhaseJobs(phase, seen)
    local jobs = {}
    local w, h = self:_currentSlotDims()
    if not w then return jobs end
    local view = self:_viewSize()
    if phase == "next" then
        local total = self._total_items or 0
        local target = (self._cursor or 1) + (self._preload_dir or 1) * view
        if target >= 1 and (total == 0 or target <= total) then
            self:_collectPageCovers(jobs, seen, self.chip, target, w, h)
        end
    end
    return jobs
end

-- ── Next-page preload step ───────────────────────────────────────────────
-- Cancellable, re-armed on every page turn. Warms ~8 covers (one page) in
-- the last paged direction.
function BookshelfWidget:_preloadStep()
    if not self._preload_fn then return end   -- cancelled before this tick ran
    if not self._preload_queue then
        self._preload_seen = {}
        self._preload_counters = { decoded = 0, already = 0, failed = 0 }
        local _qb_t0 = _gettime()
        local ok, jobs = pcall(self._buildPhaseJobs, self, "next", self._preload_seen)
        self._preload_queue = (ok and jobs) or {}
        self._preload_total = #self._preload_queue
        logger.dbg(string.format(
            "[bookshelf perf] preload-next: built in %.0fms size=%d chip=%s cursor=%d dir=%d",
            (_gettime() - _qb_t0) * 1000, self._preload_total,
            tostring(self.chip), self._cursor or 0, self._preload_dir or 0))
    end
    local q = self._preload_queue
    if q and #q > 0 then
        _warmChunk(q, PRELOAD_CHUNK, self._preload_counters)
    end
    if not q or #q == 0 then
        if self._preload_total > 0 then
            local c = self._preload_counters
            logger.dbg(string.format(
                "[bookshelf perf] preload-next: done warmed=%d already=%d failed=%d folders=%d progress=%d total=%d",
                c.decoded, c.already, c.failed,
                c.folders or 0, c.progress or 0, self._preload_total))
        end
        self._preload_fn = nil
        self._preload_queue = nil
        self._preload_seen = nil
        return
    end
    if self._preload_fn then
        UIManager:scheduleIn(PRELOAD_TICK_S, self._preload_fn)
    end
end

-- ── Chip preload step ────────────────────────────────────────────────────
-- One-shot per widget instance, kicked off by _maybeStartChipPreload at the
-- end of the first _rebuild (and any subsequent _rebuild where it hasn't yet
-- completed -- so a drill-out re-trigger naturally retries). NOT cancelled
-- by page turns: only by _cancelChipPreload (widget teardown). Yields to
-- next-page preload to avoid stealing main-thread time mid page-turn.
function BookshelfWidget:_chipPreloadStep()
    if not self._chip_preload_fn then return end
    -- Yield to next-page preload: if it's scheduled or running, defer.
    if self._preload_fn then
        UIManager:scheduleIn(CHIP_PRELOAD_YIELD_S, self._chip_preload_fn)
        return
    end
    -- Drain the queue/keys seeded by _queueWarmForVisible (page-bounded). One
    -- cold chip fetch per tick (a full shape build + sort, potentially hundreds
    -- of ms on device), then warm its covers in chunks.
    local q    = self._chip_preload_queue or {}
    local keys = self._chip_preload_keys  or {}
    self._chip_preload_queue    = q
    self._chip_preload_seen     = self._chip_preload_seen or {}
    self._chip_preload_counters = self._chip_preload_counters or { decoded = 0, already = 0, failed = 0 }
    if #q == 0 and #keys > 0 then
        local key = table.remove(keys, 1)
        local w, h = self:_currentSlotDims()
        if w then
            local _qb_t0 = _gettime()
            pcall(self._collectPageCovers, self, q, self._chip_preload_seen, key, 1, w, h)
            logger.dbg(string.format(
                "[bookshelf perf] preload-chips: fetched %s in %.0fms jobs=%d",
                tostring(key), (_gettime() - _qb_t0) * 1000, #q))
        end
    elseif #q > 0 then
        _warmChunk(q, PRELOAD_CHUNK, self._chip_preload_counters)
    end
    if #q == 0 and #keys == 0 then
        -- Idle. NOT permanently done: a page change re-arms the loop via
        -- _queueWarmForVisible, which only queues chips not already warmed.
        self._chip_preload_fn = nil
        return
    end
    if self._chip_preload_fn then
        UIManager:scheduleIn(PRELOAD_TICK_S, self._chip_preload_fn)
    end
end

-- Nav chip keys worth warming from the current view: the chip bar's current
-- page plus the next one (so warm cost is O(page), not O(total chips) -- the
-- point of "infinite chips"). Falls back to every active key if the bar isn't
-- paginated / not built yet (single-page bars warm everything, as before).
function BookshelfWidget:_visibleWarmKeys()
    local cb = self._chip_bar
    if cb and cb.warmKeys then
        local ks = cb:warmKeys()
        if ks and #ks > 0 then return ks end
    end
    return self._active_chip_keys or {}
end

-- Queue any not-yet-warmed chips reachable from the current page and arm the
-- background warm loop. Idempotent: dedups against _warmed_chip_keys, so it's
-- safe to call on every rebuild AND on every page change -- each chip warms at
-- most once per widget instance.
function BookshelfWidget:_queueWarmForVisible()
    if not BookshelfSettings.nilOrTrue("prewarm_chip_cache") then return end
    if #(self._drilldown_path or {}) ~= 0 then return end
    self._warmed_chip_keys      = self._warmed_chip_keys      or {}
    self._chip_preload_keys     = self._chip_preload_keys     or {}
    self._chip_preload_queue    = self._chip_preload_queue    or {}
    self._chip_preload_seen     = self._chip_preload_seen     or {}
    self._chip_preload_counters = self._chip_preload_counters or { decoded = 0, already = 0, failed = 0 }
    for _i, key in ipairs(self:_visibleWarmKeys()) do
        if key ~= self.chip and not self._warmed_chip_keys[key] then
            self._warmed_chip_keys[key] = true
            self._chip_preload_keys[#self._chip_preload_keys + 1] = key
        end
    end
    if (#self._chip_preload_keys > 0 or #self._chip_preload_queue > 0)
            and not self._chip_preload_fn then
        self._chip_preload_fn = function() self:_chipPreloadStep() end
        UIManager:scheduleIn(CHIP_PRELOAD_DELAY_S, self._chip_preload_fn)
    end
end

-- Cheap to call from _rebuild on every invocation; gated internally. Applies
-- the cover-cache budget (governs the next/prev PAGE preload too, regardless of
-- the chip-warm toggle) then queues the page-bounded chip warm.
function BookshelfWidget:_maybeStartChipPreload()
    self:_applyCoverCacheBudget()
    self:_queueWarmForVisible()
end

-- ── Periodic file poll ──────────────────────────────────────────────────
-- Detect books sideloaded into the library (Syncthing / Calibre / KOReader
-- network browser / etc.) WITHOUT requiring a manual swipe-down refresh.
-- Once per FILE_POLL_INTERVAL_S we stat the home dir + its immediate
-- subdirectories and compare mtimes to a saved snapshot; if anything
-- moved, invalidate the walk cache and rebuild.
--
-- Why one level deep, not full recursion: a file added at
-- ~/calibre/Author/Book.epub bumps Author/'s mtime but NOT calibre/'s,
-- so a single stat on home_dir alone misses ~all real sideloads. One
-- level of subdirs catches the calibre/per-author layout that 90% of
-- users actually use. Deeper changes (Author/Series/Book.epub) still
-- need an explicit swipe-down -- recursing would defeat the "cheap"
-- property the user asked for. ~10-50 stats per tick, ~0.5ms each on
-- Kindle, total under 25ms.
--
-- Power: cancelled in onSuspend (via _stopStatusTimer), restarted in
-- onResume. Many modern e-readers run Android where the KOReader main
-- loop keeps running with the screen off; the explicit suspend/resume
-- pair makes sure the poll doesn't fire while the device is meant to
-- be idle.
local FILE_POLL_INTERVAL_S = 5

-- Maximum top-level subdirs to track. Defends against pathological cases
-- (a flat library with thousands of immediate subdirs) where lfs probes
-- would dominate the tick. Catches the typical Calibre/Author and
-- per-collection layouts (~10-100 dirs) without paying for outliers.
local FILE_POLL_MAX_SUBDIRS = 200

local function _snapshotHomeDirs()
    local home = G_reader_settings:readSetting("home_dir")
    if not home or home == "" then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local snap = {}
    -- Every lfs call is pcall-guarded: on Android the storage sandbox
    -- can refuse certain paths with an actual error rather than a nil
    -- return, and we never want a file-poll failure to surface as a
    -- crash. Same defensive pattern Repo uses for BIM access.
    local ok_attr, attr = pcall(lfs.attributes, home)
    if not ok_attr or not attr then return nil end
    snap[home] = attr.modification or 0
    -- The lfs.dir call goes INSIDE the pcall'd function -- a previous
    -- version pulled only `iter` out of `pcall(lfs.dir, home)`, which
    -- silently dropped the second return (the directory metatable) and
    -- the for-generator then crashed with "directory metatable expected,
    -- got nil" on PW5 (Kindle, KOReader v2026.03). Calling lfs.dir
    -- inside the pcall'd closure lets the generic for consume both
    -- returns naturally; any error in lfs.dir itself still propagates
    -- as a pcall failure that we silently swallow.
    local count = 0
    local ok_loop = pcall(function()
        for entry in lfs.dir(home) do
            if entry ~= "." and entry ~= ".." then
                count = count + 1
                if count > FILE_POLL_MAX_SUBDIRS then break end
                local path = home .. "/" .. entry
                local ok_a, a = pcall(lfs.attributes, path)
                if ok_a and a and a.mode == "directory" then
                    snap[path] = a.modification or 0
                end
            end
        end
    end)
    if not ok_loop then return snap end
    return snap
end

function BookshelfWidget:_startFilePoll()
    if self._file_poll_fn then return end   -- already polling
    -- Establish baseline so the first tick doesn't false-positive on
    -- the very mtimes we'll be comparing against.
    self._home_dir_mtimes = _snapshotHomeDirs()
    self._file_poll_fn    = function() self:_filePollTick() end
    UIManager:scheduleIn(FILE_POLL_INTERVAL_S, self._file_poll_fn)
end

function BookshelfWidget:_cancelFilePoll()
    if self._file_poll_fn then
        UIManager:unschedule(self._file_poll_fn)
        self._file_poll_fn = nil
    end
end

function BookshelfWidget:_filePollTick()
    if not self._file_poll_fn then return end
    local snap = _snapshotHomeDirs()
    local changed = false
    local prev = self._home_dir_mtimes
    if snap and prev then
        for path, mtime in pairs(snap) do
            if not prev[path] or mtime > prev[path] then
                changed = true; break
            end
        end
        if not changed then
            -- Detect a removed directory (deletion / rename).
            for path in pairs(prev) do
                if not snap[path] then changed = true; break end
            end
        end
    end
    self._home_dir_mtimes = snap or prev
    if changed then
        logger.dbg("[bookshelf] file poll detected dir mtime change; rebuilding")
        local Repo = require("lib/bookshelf_book_repository")
        if Repo.invalidateWalkCache then Repo.invalidateWalkCache() end
        -- Defer the rebuild to the next event-loop tick instead of running
        -- it inline. The poll callback should always return fast; if the
        -- rebuild itself errors out, the throw doesn't leak through our
        -- scheduled-task callback (which Lua's pcall protection inside
        -- UIManager already provides, but nextTick decouples the failure
        -- domain too). Also avoids holding up the next tick's re-arm if a
        -- rebuild ever takes longer than expected.
        UIManager:nextTick(function()
            if self._file_poll_fn == nil then return end  -- widget torn down
            self:_rebuild()
            UIManager:setDirty(self, "ui")
            -- Walk cache was just invalidated for ALL chips, but _rebuild
            -- only re-walks the active chip. Clear the warmed set + seen so the
            -- page-bounded pre-warm re-warms the reachable chips with fresh
            -- data (and subsequent taps don't pay the full walk cost).
            self._warmed_chip_keys = nil
            self._chip_preload_seen = nil
            self._chip_preload_queue = nil
            self:_maybeStartChipPreload()
        end)
    end
    -- Re-arm.
    if self._file_poll_fn then
        UIManager:scheduleIn(FILE_POLL_INTERVAL_S, self._file_poll_fn)
    end
end

-- Entry point: called after a page-turn settles. `direction` is +1 (next) or
-- -1 (prev). Re-syncs the cache capacity, then schedules the next-page cover
-- warm-up. Always on as of v2.3.0 (previously gated behind an experimental
-- setting that's now removed).
function BookshelfWidget:_schedulePreload(direction)
    self:_cancelPreload()
    self:_applyCoverCacheBudget()
    self._preload_dir = direction
    self._preload_fn = function() self:_preloadStep() end
    UIManager:scheduleIn(PRELOAD_START_DELAY_S, self._preload_fn)
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
    local _diag_t0     = _gettime()
    local _diag_page0  = self.page
    local total = self._total_pages or 1
    if self.page < total then
        self:_advanceCursor(1)
        self:_syncPageFromCursor()
        self:_swapShelvesInPlace()
        self:_schedulePreload(1)
        logger.dbg(string.format(
            "[bookshelf perf] paginate: dir=next %d->%d/%d TOTAL=%.0fms chip=%s",
            _diag_page0, self.page, total,
            (_gettime() - _diag_t0) * 1000, self.chip))
        return true
    end
    -- Last page at top level (no drill-down) and chip strip visible:
    -- stay in the chip and wrap to the first page instead of switching to
    -- the neighbouring chip (issue #115). Drilled-in last page is left as a
    -- no-op; back-navigation there happens via the breadcrumb or east-swipe.
    if #self._drilldown_path == 0 and not self._chip_bar_hidden
            and total > 1 and self._cursor > 1 then
        self._cursor = 1
        self:_syncPageFromCursor()
        self:_swapShelvesInPlace()
        self:_schedulePreload(1)
        logger.dbg(string.format(
            "[bookshelf perf] paginate: dir=next at end -> wrap to first page elapsed=%.0fms",
            (_gettime() - _diag_t0) * 1000))
    end
    return true
end

function BookshelfWidget:_paginatePrev()
    local _diag_t0    = _gettime()
    local _diag_page0 = self.page
    if self.page > 1 then
        self:_advanceCursor(-1)
        self:_syncPageFromCursor()
        self:_swapShelvesInPlace()
        self:_schedulePreload(-1)
        logger.dbg(string.format(
            "[bookshelf perf] paginate: dir=prev %d->%d/%d TOTAL=%.0fms chip=%s",
            _diag_page0, self.page, self._total_pages or 1,
            (_gettime() - _diag_t0) * 1000, self.chip))
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
    -- Top level + page 1 + chip strip visible: stay in the chip and wrap to
    -- the last page instead of switching to the previous tab (issue #115).
    if not self._chip_bar_hidden then
        local total       = self._total_pages or 1
        local last_cursor = self:_maxCursor()
        if total > 1 and self._cursor < last_cursor then
            self._cursor = last_cursor
            self:_syncPageFromCursor()
            self:_swapShelvesInPlace()
            self:_schedulePreload(-1)
            logger.dbg(string.format(
                "[bookshelf perf] paginate: dir=prev at start -> wrap to last page elapsed=%.0fms",
                (_gettime() - _diag_t0) * 1000))
        end
    end
    return true
end

-- Take a screenshot of the home screen. Bookshelf consumes the stock
-- screenshot gestures (two-finger diagonal tap + diagonal swipe) above the
-- dispatch stack, so they never reach a Screenshoter on their own. The
-- previous implementation broadcast a "Screenshot" event and relied on some
-- Screenshoter being registered to catch it -- but when bookshelf is the
-- home screen there often ISN'T one reachable (FileManager's module isn't
-- always on the broadcast path, and SimpleUI-style shells register none), so
-- the broadcast silently no-op'd and no file was ever written (diagnosed
-- 2026-05-29: gesture matched + consumed, zero screenshots saved).
--
-- Instead, drive a Screenshoter directly. It's instantiated with a stub `ui`
-- because Screenshoter:onScreenshot only reads self.ui.document /
-- file_chooser for the in-book filename prefix and post-save FM refresh --
-- neither applies on the home screen, and both short-circuit safely on a
-- bare table. onScreenshot writes the PNG via Screen:shot and shows its own
-- "saved to…" dialog, so the user gets visible confirmation.
function BookshelfWidget:_dispatchScreenshot()
    local Screenshoter = require("ui/widget/screenshoter")
    local shooter = Screenshoter:new{ ui = {} }
    shooter:onScreenshot()
    return true
end

function BookshelfWidget:onTakeScreenshotTap()
    return self:_dispatchScreenshot()
end

function BookshelfWidget:onTakeScreenshotSwipe()
    return self:_dispatchScreenshot()
end

-- Diagnostic: latency from the swipe gesture's own timestamp (set by the
-- GestureDetector) to this handler firing -- i.e. the detection + dispatch
-- portion of a page turn. The pagination work itself is timed separately by
-- _paginateNext/_paginatePrev's "[bookshelf perf] paginate" line, so the two
-- together cover swipe-to-repaint.
--
-- ges.time's CLOCK SOURCE is platform-dependent: KOReader's GestureDetector
-- stamps it from whatever InputEvent carries (realtime/epoch on the Kindle MTK
-- input stack, monotonic on SDL). So we can't assume it matches time.now()
-- (monotonic) -- subtracting the wrong base gave a -1.7e12 ms reading on the
-- Kindle. Instead, try each available "now" clock and keep the first delta
-- that lands in a sane page-turn window; the mismatched clock yields a wildly
-- out-of-range value and is discarded. dbg level: enable debug logging to see.
function BookshelfWidget:_logSwipeLatency(dir, ges)
    if not (ges and ges.time) then return end
    local ok, ms = pcall(function()
        local time = require("ui/time")
        local nows = {}
        if time.now then nows[#nows + 1] = time.now() end
        if time.realtime_coarse then nows[#nows + 1] = time.realtime_coarse() end
        if time.realtime then nows[#nows + 1] = time.realtime() end
        for _i = 1, #nows do
            local v = time.to_ms(nows[_i] - ges.time)
            if v >= 0 and v < 5000 then return v end
        end
        return nil
    end)
    if ok and ms then
        logger.dbg(string.format(
            "[bookshelf swipe] dir=%s gesture->handler=%.0fms", dir, ms))
    end
end

-- Long-press on the modules chip: options for the micro-module grid as a whole.
-- "Reset" reseeds the hero list to defaults; "Disable" turns micro-modules off
-- (revertible from Settings) and restores the book hero.
function BookshelfWidget:_showModulesOptions()
    local ButtonDialog = require("ui/widget/buttondialog")
    local HeroModel    = require("lib/bookshelf_hero_modules_model")
    local dialog
    local function close(fn)
        return function() UIManager:close(dialog); if fn then fn() end end
    end
    dialog = ButtonDialog:new{
        title        = _("Micro-modules"),
        title_align  = "center",
        width_factor = 0.75,
        buttons = {
            { { text = _("Reset modules to default"), callback = close(function()
                HeroModel.save(HeroModel.DEFAULTS())
                self._hero_page = 1
                self:_rebuildRefreshHeroAndChips()
            end) } },
            -- This is the hero chip's menu, so "disable" turns off only the hero
            -- surface (the start-menu and full-screen surfaces are independent
            -- now, toggled in Settings). Persist all three explicitly so we stop
            -- depending on the legacy placement key, mirroring the settings menu.
            { { text = _("Remove micro-modules from hero (re-enable in settings)"),
                callback = close(function()
                    BookshelfSettings.save("micro_in_start_menu", BookshelfSettings.microInStartMenu())
                    BookshelfSettings.save("micro_in_hero", false)
                    BookshelfSettings.save("micro_fullscreen_button", BookshelfSettings.microFullscreenButton())
                    BookshelfSettings.delete("micro_modules_placement")  -- fully migrated
                    BookshelfSettings.delete("micro_modules_disabled")   -- legacy
                    BookshelfSettings.flush()
                    self._hero_mode = "current"
                    self._hero_page = 1
                    self:_rebuild()
                    UIManager:setDirty(self, "ui")
                end) } },
        },
    }
    UIManager:show(dialog)
end

function BookshelfWidget:onSwipeNextPage(_, ges)
    -- Hero-area swipe. In micro-module mode the hero shows no book, so page the
    -- module grid instead (if it's paginated); a single page consumes the swipe
    -- rather than falling through to shelf paging. In book-detail mode it cycles
    -- the preview to the next book as before (pages flip automatically when the
    -- next book lives on a different shelf page).
    if self:_isHeroSwipe(ges) then
        if self._hero_mode == "micro" then
            if (self._hero_pages or 1) > 1 then
                require("lib/bookshelf_hero_modules")._gotoPage(self, 1)
            end
            return true
        end
        self:_previewNeighbourBook(1)
        return true
    end
    self:_logSwipeLatency("next", ges)
    return self:_paginateNext()
end

function BookshelfWidget:onSwipePrevPage(_, ges)
    if self:_isHeroSwipe(ges) then
        if self._hero_mode == "micro" then
            if (self._hero_pages or 1) > 1 then
                require("lib/bookshelf_hero_modules")._gotoPage(self, -1)
            end
            return true
        end
        self:_previewNeighbourBook(-1)
        return true
    end
    self:_logSwipeLatency("prev", ges)
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
    -- Collapse/restore the hero in both modes (in micro mode this hides /
    -- shows the module grid).
    self:_clearDpadFocus()
    self._expanded = not self._expanded
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    return true
end

function BookshelfWidget:onBookshelfToggleSelectionMode()
    if self._selection:isActive() then
        self._selection:exitMode()
    else
        self._selection:enterMode()
    end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    return true
end

-- _focusedBookFilepath() — returns the filepath of the item currently under
-- the D-pad cursor, but ONLY when the cursor is on a single-book cover (not
-- a stack/folder). Used by the BookshelfSelectFocusedBook dispatcher action.
function BookshelfWidget:_focusedBookFilepath()
    if self._focus_zone ~= "grid" then return nil end
    local idx  = self._cursor_idx
    if not idx or not self._page_items then return nil end
    local item = self._page_items[idx]
    if not item then return nil end
    -- Single-book items have item.filepath and no item.kind (no kind means
    -- a plain book entry, not a grouped stack).
    if item.filepath and not item.kind then return item.filepath end
    return nil
end

-- _focusedStack() — returns the item under the D-pad cursor when it is a
-- grouped stack (folder, series, author, genre, tag, format, or rating).
-- Used by the BookshelfAddFocusedStackToSelection dispatcher action.
function BookshelfWidget:_focusedStack()
    if self._focus_zone ~= "grid" then return nil end
    local idx  = self._cursor_idx
    if not idx or not self._page_items then return nil end
    local item = self._page_items[idx]
    if not item then return nil end
    if item.books or item.kind == "folder" or item.kind == "author"
        or item.kind == "genre" or item.kind == "tag"
        or item.kind == "format" or item.kind == "rating"
        or item.kind == "language" then
        return item
    end
    return nil
end

function BookshelfWidget:onBookshelfSelectFocusedBook()
    local fp = self:_focusedBookFilepath()
    if not fp then return true end
    if not self._selection:isActive() then self._selection:enterMode() end
    self._selection:toggle(fp)
    self:_refreshCoverFrame(fp)
    self:_refreshBucket()
    return true
end

function BookshelfWidget:onBookshelfAddFocusedStackToSelection()
    local group = self:_focusedStack()
    if not group then return true end
    local paths = self:_resolveStackPaths(group)
    if #paths == 0 then return true end
    if not self._selection:isActive() then self._selection:enterMode() end
    self._selection:addMany(paths)
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    return true
end

function BookshelfWidget:onBookshelfOpenBulkMenu()
    self:_openBulkMenu()
    return true
end

function BookshelfWidget:_clearDpadFocus()
    self._focus_zone         = nil
    self._cursor_idx         = nil
    self._chip_cursor_key    = nil
    self._crumb_cursor_depth = nil
    self._footer_cursor_btn  = nil
    self._sel_overlay_slot   = nil
    self._hero_cell_cursor   = nil
    if self._chip_bar and self._chip_bar.focusCursor then
        self._chip_bar:focusCursor(nil)
    end
    if self._chip_bar and self._chip_bar.focusCrumb then
        self._chip_bar:focusCrumb(nil)
    end
end

-- North-swipe anywhere on screen: collapse hero to compact strip, expand
-- the grid from 2 to 3 rows. No-op when already expanded.
-- Pinch / spread zoom: nudge the column count (the cover-size knob).
-- delta -1 = fewer columns (bigger covers, "spread"); +1 = more columns
-- (smaller covers, "pinch"). Reads the stored setting so the step is off the
-- user's chosen value, not the landscape-adjusted effective count. Clamped to
-- [COLUMNS_MIN, COLUMNS_MAX]; a no-op at the limit still consumes the gesture.
function BookshelfWidget:_nudgeColumns(delta)
    local cur = BookshelfSettings.read("bookshelf_columns")
    if type(cur) ~= "number" then cur = self:_nCols() end
    cur = math.max(COLUMNS_MIN, math.min(COLUMNS_MAX, math.floor(cur)))
    local new = math.max(COLUMNS_MIN, math.min(COLUMNS_MAX, cur + delta))
    if new == cur then return true end
    -- DEFERRED write, not save(): a synchronous full bookshelf.lua flush here
    -- (~hundreds of ms on Kindle flash) blocked the pinch before the regrid
    -- repainted, so each zoom step felt laggy. saveDeferred still updates the
    -- in-memory value, so the _rebuild below reads the new column count and the
    -- zoom is instant; only the disk persistence is coalesced onto the shared
    -- nav-flush channel (Store.flush writes the whole file, so columns rides
    -- along). Durability still lands at the debounce and at every
    -- close / suspend / onFlushSettings boundary.
    BookshelfSettings.saveDeferred("bookshelf_columns", new)
    self._nav_dirty = true
    self:_scheduleNavFlush()
    self:_clearDpadFocus()
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    return true
end

-- Spread (fingers apart) = zoom in = bigger covers = fewer columns.
function BookshelfWidget:onShelfSpread() return self:_nudgeColumns(-1) end
-- Pinch (fingers together) = zoom out = smaller covers = more columns.
function BookshelfWidget:onShelfPinch() return self:_nudgeColumns(1) end

-- Set the expand/collapse state AND remember it (home_expanded), so the home
-- screen comes back the way the user last left it. Only the deliberate
-- show/hide-hero actions call this (swipe up/down, strip tap, currently-reading
-- / micro-modules chips, and the expanded-tap "show detail" action). Sets the
-- flag + persists; callers do their own rebuild.
function BookshelfWidget:_setExpanded(expanded)
    expanded = expanded and true or false
    self._expanded = expanded
    BookshelfSettings.save("home_expanded", expanded)
    BookshelfSettings.flush()
end

function BookshelfWidget:onSwipeShelvesUp(_, ges)
    -- Collapses the hero to the thin strip in both modes; in micro mode this
    -- hides the module grid (swipe-down / modules-chip restores it).
    if self._expanded then return false end
    local _diag_t0 = _gettime()
    self:_setExpanded(true)
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    logger.dbg(string.format(
        "[bookshelf perf] toggle: dir=expand TOTAL=%.0fms chip=%s",
        (_gettime() - _diag_t0) * 1000, self.chip))
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
        local _diag_t0 = _gettime()
        -- Carry the expanded selection back to the collapsed view: show it in
        -- the restored hero, and page the (now shorter) grid so its cover stays
        -- on screen. Index is captured WHILE expanded; _setCursorToShow runs
        -- after collapse so it aligns to the collapsed row count.
        local sel_fp = self:_selectedFilepath()
        local gidx   = sel_fp and self:_globalIndexOfFilepath(sel_fp) or nil
        self:_setExpanded(false)
        if sel_fp then
            if not (self._preview_book and self._preview_book.filepath == sel_fp) then
                self._hero_mode    = "current"
                self._preview_book = Repo.buildBook(sel_fp) or self._preview_book
            end
            self._tap_selected_fp = nil
            self:_setCursorToShow(gidx)
        end
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        logger.dbg(string.format(
            "[bookshelf perf] toggle: dir=collapse TOTAL=%.0fms chip=%s",
            (_gettime() - _diag_t0) * 1000, self.chip))
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

-- ─── Bulk action menu (Task 10 stub) ─────────────────────────────────────────

-- _openBulkMenu() — entry point for the bulk-action dialog. No-op when the
-- selection is empty (the bucket icon's onTap already guards, but guard here
-- too for safety).
function BookshelfWidget:_openBulkMenu()
    if self._selection:count() == 0 then return end
    local BulkActions = require("lib/bookshelf_bulk_actions")
    BulkActions.show{ selection = self._selection, bw = self }
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

-- _buildBookMenuHeader(book) -- header widget for the long-press menu,
-- shown above the action buttons via ButtonDialog:addWidget(). Replaces
-- the plain text title with a cover thumbnail (when available) next to
-- a stacked title / author / series text block. Falls back to text-only
-- when there's no cover_bb (BIM unavailable, file just imported, etc).
--
-- The cover_bb is sourced from a fresh Repo.buildBookMeta() call so it's
-- a one-time-use bb -- ImageWidget frees it after first paint, which
-- means the bb in `book` itself (potentially shared with other UI) is
-- never touched. Same disposable-bb invariant as the hero card.
function BookshelfWidget:_buildBookMenuHeader(book, override_width, pill_specs, bookmark_action, opts)
    if not book or not book.filepath then return nil end
    -- rich = the book-detail popup's header: +2pt detail fonts, a page count,
    -- "Last read" wording, and the folder path with the filename. The long-press
    -- menu (opts nil) keeps the compact original.
    local rich = opts and opts.rich or false
    local Font           = require("ui/font")
    local ImageWidget    = require("ui/widget/imagewidget")
    local HorizontalGroup_   = require("ui/widget/horizontalgroup")
    local HorizontalSpan_    = require("ui/widget/horizontalspan")
    local VerticalGroup_     = require("ui/widget/verticalgroup")
    local VerticalSpan_      = require("ui/widget/verticalspan")
    local TextBoxWidget_     = require("ui/widget/textboxwidget")
    local TextWidget_        = require("ui/widget/textwidget")

    -- Caller can pass override_width (e.g. the collection manager, which
    -- nests inside the book menu and needs a narrower header).
    -- Match the dialog's added-widget width (= the button-table width) so
    -- the header fills exactly the button area -- neither narrower (margins
    -- around the cover) nor wider (margins around the buttons, which would
    -- grow the whole dialog). The book menu passes that width as
    -- override_width; the fallback mirrors ButtonDialog's own default width
    -- so a no-override caller still fits.
    local header_w = override_width
        or math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    -- Cover thumbnail is the visual anchor of the header; size it large
    -- enough that the title block on a real cover is legible, but not
    -- so large the menu starts to dominate the screen. Height is
    -- derived from the actual cover aspect once we've fetched the bb
    -- (a few lines down) so the FrameContainer matches the painted
    -- image exactly -- no horizontal or vertical letterboxing.
    local thumb_w  = Screen:scaleBySize(110)
    local thumb_h  = math.floor(thumb_w * 1.5)  -- default 2:3 if no cover
    -- Cover<->text gap = the shelf's inter-column book gap, so the menu
    -- matches the main grid. The header's outer inset is supplied by the
    -- DIALOG's title_padding (the book menu sets it to this same gap), so we
    -- add NO frame inset here -- stacking a frame inset on the dialog's own
    -- padding was the doubling.
    local gap_w    = self:_bookGap(math.min(
        math.floor(Size.padding.fullscreen * 2 * 0.8),
        math.floor(Screen:getWidth() * 0.03)))

    -- Rebuild the book record so we get an independent cover_bb that
    -- ImageWidget can own + free (cover_bb is one-shot per the
    -- feedback_image_disposable_shared_book memory; reusing the bb on
    -- `book` here would tear out from under whoever painted last).
    -- Wrap the ImageWidget in a thin FrameContainer so the cover has a
    -- 1dp border; without it pale covers (white sky, light typography)
    -- bleed straight into the dialog's white background and the
    -- thumbnail loses its rectangular shape.
    local fresh = Repo.buildBookMeta(book.filepath) or book
    local thumb_widget

    -- Prefer the external (Hardcover/custom) cover whenever enrichBook set
    -- cover_image_path on the rebuilt record -- otherwise the header keeps
    -- showing the embedded cover even after "Use Hardcover image" is on, so
    -- the menu thumbnail disagrees with the shelf. The external bb is owned
    -- by ImageSource's cache (keyed by path+mtime+size), so paint it with
    -- image_disposable=false; freeing it would corrupt the shared cache.
    local ext_cover = fresh.cover_image_path
    local thumb_bb, thumb_disposable
    if ext_cover then
        -- Native (true-aspect) load: the box below is derived from the bb's own
        -- dimensions, so a non-2:3 Hardcover cover isn't stretched tall/narrow
        -- the way a fixed w*h resize would. The cache owns the bb.
        local ok_img, ImageSource = pcall(require, "lib/bookshelf_image_source")
        thumb_bb = ok_img and ImageSource.loadImageNative(ext_cover) or nil
        thumb_disposable = false
    end
    if not thumb_bb and fresh.cover_bb then
        -- Fallback: the embedded cover_bb is one-shot (ImageWidget frees it
        -- after first paint) per feedback_image_disposable_shared_book.
        thumb_bb = fresh.cover_bb
        thumb_disposable = true
    end

    -- The rich (popup) header is CACHED + repainted across every _assemble, so a
    -- one-shot disposable bb would be freed after the first paint and the next
    -- repaint would blit garbage. Keep the embedded bb alive instead and hand it
    -- back via owned_cover_bb so the modal frees it once, at close. (External
    -- covers are already non-disposable -- the ImageSource cache owns them.)
    local owned_cover_bb
    if rich and thumb_disposable then
        thumb_disposable = false
        owned_cover_bb = thumb_bb
    end

    if thumb_bb then
        -- Resize the container to the cover's true aspect ratio so the
        -- image fills the frame with no letterboxing. The bb is a
        -- blitbuffer with .w/.h fields; falling back to 2:3 if either
        -- is missing keeps the layout sane for malformed covers.
        local bw = thumb_bb.w or (thumb_bb.getWidth and thumb_bb:getWidth())
        local bh = thumb_bb.h or (thumb_bb.getHeight and thumb_bb:getHeight())
        if bw and bh and bw > 0 then
            thumb_h = math.floor(thumb_w * (bh / bw))
        end
        local thumb_frame = FrameContainer:new{
            bordersize = Size.border.thin,
            padding    = 0,
            margin     = 0,
            ImageWidget:new{
                image            = thumb_bb,
                image_disposable = thumb_disposable,
                width            = thumb_w,
                height           = thumb_h,
                scale_factor     = 0,
            },
        }
        -- Wrap in an InputContainer so a tap on the thumbnail opens a
        -- full-screen preview. The embedded bb is one-shot (freed after
        -- first paint), so the tap handler reloads the cover for
        -- ImageViewer. The external cover comes from ImageSource's cache,
        -- so the viewer must NOT free it (image_disposable=false).
        local fp = book.filepath
        local ext_for_viewer = ext_cover
        local title_for_viewer = book.title or book.filename or ""
        thumb_widget = InputContainer:new{
            dimen = Geom:new{
                w = thumb_w + 2 * Size.border.thin,
                h = thumb_h + 2 * Size.border.thin,
            },
            thumb_frame,
        }
        thumb_widget.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = thumb_widget.dimen } },
        }
        thumb_widget.onTap = function()
            if ext_for_viewer then
                local ok_img, ImageSource = pcall(require, "lib/bookshelf_image_source")
                -- Native load: ImageViewer fits it to the screen preserving
                -- aspect. A fixed w*h resize here stretched the cover.
                local pv_bb = ok_img and ImageSource.loadImageNative(ext_for_viewer) or nil
                if pv_bb then
                    UIManager:show(require("ui/widget/imageviewer"):new{
                        image            = pv_bb,
                        image_disposable = false,  -- ImageSource cache owns it
                        title_text       = title_for_viewer,
                        fullscreen       = true,
                    })
                    return true
                end
            end
            local preview = Repo.buildBookMeta(fp)
            if not preview or not preview.cover_bb then return true end
            UIManager:show(require("ui/widget/imageviewer"):new{
                image            = preview.cover_bb,
                image_disposable = true,
                title_text       = title_for_viewer,
                fullscreen       = true,
            })
            return true
        end
    end

    -- Bookmark link (#67): "N bookmark(s) ›" in the header's top-right
    -- corner, opening KOReader's bookmark browser. A text link rather than
    -- a bare icon -- clearer, and the count says what's there. Built only
    -- when bookmark_action is passed (book has annotations + browser
    -- available). Reserve its width off the text column so a long title
    -- doesn't run under it.
    local bm_link, bm_reserve = nil, 0
    if bookmark_action then
        local n = bookmark_action.count
        local bm_text = n == 1 and _("1 bookmark") or T(_("%1 bookmarks"), n)
        local bm_face, bm_bold = BFont:getFace("cfont", 16, { bold = true })
        -- The chevron is a real glyph (U+E841 mdi-chevron-right) from the
        -- symbols/nerdfont face -- NOT an ASCII ">" -- so it's its own widget:
        -- the count label's cfont doesn't carry that PUA codepoint.
        local bm_row = HorizontalGroup_:new{
            align = "center",
            TextWidget_:new{ text = bm_text, face = bm_face, bold = bm_bold },
            HorizontalSpan_:new{ width = Size.padding.small },
            TextWidget_:new{ text = "\xEE\xA1\x81", face = BFont:getFace("symbols", 20) },
        }
        local bm_frame = FrameContainer:new{
            bordersize = 0,
            margin     = 0,
            padding    = 0,
            bm_row,
        }
        local bm_sz = bm_frame:getSize()
        bm_link = InputContainer:new{
            dimen = Geom:new{ w = bm_sz.w, h = bm_sz.h },
            bm_frame,
        }
        bm_link.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = bm_link.dimen } },
        }
        bm_link.onTap = function() bookmark_action.on_tap(); return true end
        bm_reserve = bm_sz.w + Size.padding.default
    end
    -- No frame inset: header_w (the dialog's added-widget width) is already
    -- inset from the button rows by the dialog's title_padding. The content
    -- fills it edge to edge; only the TITLE row reserves space for the
    -- bookmark link (below), overlaying the title's right-hand whitespace.
    local text_w = thumb_widget and (header_w - thumb_w - gap_w) or header_w

    -- Top of text column: title (bold) + author + one-line metadata
    -- strip (format · size · added · last opened) + filename. Series
    -- info is no longer rendered here -- it lives as a tappable pill
    -- in the nav strip below.
    local top_stack = VerticalGroup_:new{ align = "left" }
    local mtitle_face, mtitle_bold = BFont:getFace("smalltfont", rich and 26 or 22, { bold = true })
    top_stack[#top_stack + 1] = TextBoxWidget_:new{
        text  = book.title or book.filename or _("(no title)"),
        face  = mtitle_face,
        bold  = mtitle_bold,
        -- Title wraps before the top-right bookmark link (bm_reserve = 0
        -- when there's no link, so this is the full width otherwise).
        width = text_w - bm_reserve,
    }
    if book.author and book.author ~= "" then
        local mauthor_face, mauthor_bold = BFont:getFace("cfont", rich and 22 or 18)
        top_stack[#top_stack + 1] = TextBoxWidget_:new{
            text  = book.author,
            face  = mauthor_face,
            bold  = mauthor_bold,
            width = text_w,
        }
    end

    -- Metadata + filename block: cheap-to-fetch supporting detail in a
    -- compact bottom slice of the top stack. Each chunk skipped when
    -- its source is unavailable.
    local meta_face, meta_bold = BFont:getFace("cfont", rich and 18 or 14)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local size_bytes, mtime
    if ok_lfs and lfs and lfs.attributes then
        -- One stat for both fields: attributes(path) returns the full
        -- record, so asking twice with mode strings doubles the syscall.
        local attr = lfs.attributes(book.filepath)
        if attr then
            size_bytes = attr.size
            mtime      = attr.modification
        end
    end
    local function _fmt_size(bytes)
        if not bytes or bytes <= 0 then return nil end
        if bytes < 1024              then return string.format("%d B", bytes) end
        if bytes < 1024 * 1024       then return string.format("%d KB", math.floor(bytes / 1024 + 0.5)) end
        return string.format("%.1f MB", bytes / 1024 / 1024)
    end
    local function _fmt_short_date(ts)
        if not ts or ts <= 0 then return nil end
        return os.date("%d %b %Y", ts)
    end
    -- ReadHistory lookup for "last opened" timestamp -- KOReader's
    -- canonical source for "when did the user last touch this book"
    -- (Repo.readProgress returns rating + status but not last_opened).
    local function _last_opened(fp)
        local ok_rh, rh = pcall(require, "readhistory")
        if not (ok_rh and rh and rh.hist) then return nil end
        for _i, item in ipairs(rh.hist) do
            if item.file == fp then return item.time end
        end
        return nil
    end
    -- A small leading glyph from the symbols (nerdfont) face. The glyph is
    -- centred within ONE text-line's height (FA icons sit centred in a tall em
    -- box, so a raw top-align drops them below the text's cap line); the row is
    -- top-aligned, so a wrapping value keeps the glyph beside the first line.
    local CenterContainer_ = require("ui/widget/container/centercontainer")
    local function _icon_row(glyph, text)
        local icon = TextWidget_:new{ text = glyph,
            face = BFont:getFace("symbols", 15) }
        local gap    = Screen:scaleBySize(6)
        local line_h = TextWidget_:new{ text = "Ag", face = meta_face }:getSize().h
        local icon_box = CenterContainer_:new{
            dimen = Geom:new{ w = icon:getSize().w, h = line_h },
            icon,
        }
        local txt  = TextBoxWidget_:new{
            text  = text,
            face  = meta_face,
            bold  = meta_bold,
            width = text_w - icon:getSize().w - gap,
        }
        return HorizontalGroup_:new{ align = "top",
            icon_box, HorizontalSpan_:new{ width = gap }, txt }
    end

    local added_str = _fmt_short_date(mtime)
    local last_str  = _fmt_short_date(_last_opened(book.filepath))

    -- Format · size · pages. In the compact header the dates ride along on this
    -- same row (the original one-line strip); the rich popup header breaks them
    -- onto their own calendar-prefixed row below.
    local meta_parts = {}
    if book.format then meta_parts[#meta_parts + 1] = book.format end
    local size_str = _fmt_size(size_bytes)
    if size_str then meta_parts[#meta_parts + 1] = size_str end
    if rich then
        local pages = tonumber(book.page_count)  -- nil for un-rendered EPUBs
        if pages and pages > 0 then
            meta_parts[#meta_parts + 1] = _("Pages") .. " " .. tostring(pages)
        end
    else
        if added_str then meta_parts[#meta_parts + 1] = _("Added") .. " " .. added_str end
        if last_str  then meta_parts[#meta_parts + 1] = _("Read") .. " " .. last_str end
    end
    if #meta_parts > 0 then
        top_stack[#top_stack + 1] = TextBoxWidget_:new{
            text  = table.concat(meta_parts, "  \xC2\xB7  "),  -- middle-dot
            face  = meta_face,
            bold  = meta_bold,
            width = text_w,
        }
    end

    -- Dates on their own row with a calendar glyph (rich popup header only).
    if rich then
        local date_parts = {}
        if added_str then date_parts[#date_parts + 1] = _("Added") .. " " .. added_str end
        if last_str  then date_parts[#date_parts + 1] = _("Last read") .. " " .. last_str end
        if #date_parts > 0 then
            top_stack[#top_stack + 1] = _icon_row(
                "\xEF\x81\xB3", table.concat(date_parts, "  \xC2\xB7  "))  -- U+F073 calendar
        end
    end

    -- Filename. The compact (long-press menu) header shows the basename only --
    -- the directory is reachable via the Folder pill. The rich (book-detail
    -- popup) header includes the folder path (relative to home_dir when under
    -- it, else the full path) and a leading file glyph.
    local fname = (book.filepath or ""):match("([^/]+)$") or book.filepath or ""
    if rich and book.filepath then
        local shown = book.filepath
        local ok_gs, gs = pcall(function() return G_reader_settings end)
        local home = ok_gs and gs and gs:readSetting("home_dir")
        if type(home) == "string" then
            home = home:gsub("/+$", "")
            if home ~= "" and shown:sub(1, #home + 1) == home .. "/" then
                shown = shown:sub(#home + 2)  -- strip "home_dir/"
            end
        end
        fname = shown
    end
    if rich then
        top_stack[#top_stack + 1] = _icon_row("\xEF\x80\x96", fname)  -- U+F016 file
    else
        top_stack[#top_stack + 1] = TextBoxWidget_:new{
            text  = fname,
            face  = meta_face,
            bold  = meta_bold,
            width = text_w,
        }
    end

    -- Bottom-aligned pill strip: tappable nav facets (series, author,
    -- collections, genres, folder, rating). Each pill is a small
    -- bordered rounded rectangle, packed into rows that wrap to
    -- text_w. Pill text is rendered UPPERCASED (small-caps style) --
    -- KOReader's TextWidget has no small-caps font variant, so the
    -- uppercase fallback is the convention. TextSegments.upper is
    -- UTF-8-aware (Lua's :upper() leaves accented letters untouched,
    -- so "videojáték" would render "VIDEOJáTéK" -- issue #130).
    -- Padding is symmetric on
    -- both axes for a balanced look. Built only when the caller passes
    -- pill_specs -- the collection-manager call site for instance
    -- passes nil because it doesn't want nav-into-self affordances.
    local pill_group = VerticalGroup_:new{ align = "left" }
    if pill_specs and #pill_specs > 0 then
        local pill_face, pill_bold = BFont:getFace("cfont", 13, { bold = true })
        local pill_pad_h  = Size.padding.default  -- L/R inner padding
        local pill_pad_v  = Size.padding.small    -- T/B inner padding
        local pill_gap    = Size.padding.default  -- between pills
        local MAX_PILL_ROWS = 2  -- bounds the header height when the
                                 -- caller pours dozens of pills at us;
                                 -- the overflow collapses into a single
                                 -- "+N" pill so the visible row count
                                 -- never grows past this cap.

        -- #177: cap a single pill's label so a very long tag truncates
        -- (one line, ellipsis) inside text_w instead of spilling off-screen.
        local pill_label_max = math.max(1, text_w - 2 * pill_pad_h - 2 * Size.border.thin)

        -- Build all pill widgets first so we know their widths up
        -- front (the packing pass needs them to greedily wrap).
        -- extra_pad widens a pill's L/R padding (and so its tap target) without
        -- touching the others -- used for the small "+N" overflow pill.
        local function _buildPill(label_text, on_tap_cb, extra_pad)
            local label_w = TextWidget_:new{
                text = TextSegments.upper(label_text or ""),
                face = pill_face,
                bold = pill_bold,
                max_width = pill_label_max,
            }
            -- Explicit white bg so the tap-feedback inversion has
            -- something to flip to black. Matches the hero pill builder.
            local frame = FrameContainer:new{
                bordersize     = Size.border.thin,
                background     = Blitbuffer.COLOR_WHITE,
                radius         = Size.radius.button,
                padding_left   = pill_pad_h + (extra_pad or 0),
                padding_right  = pill_pad_h + (extra_pad or 0),
                padding_top    = pill_pad_v,
                padding_bottom = pill_pad_v,
                margin         = 0,
                label_w,
            }
            local frame_size = frame:getSize()
            local pill = InputContainer:new{
                dimen = Geom:new{ w = frame_size.w, h = frame_size.h },
                frame,
            }
            pill.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = pill.dimen } },
            }
            pill.onTap = function()
                -- Same instant-feedback pattern as the hero pill builder
                -- (BookshelfWidget:_buildPillGroup): invert, repaint into
                -- the fb, force a refresh-queue drain, then run the
                -- callback. Without the forceRePaint the highlight only
                -- queues and the callback's rebuild wipes it before any
                -- pixels reach the panel.
                if on_tap_cb and frame and frame.dimen then
                    frame.background = frame.background:invert()
                    label_w.fgcolor  = label_w.fgcolor:invert()
                    UIManager:widgetRepaint(frame, frame.dimen.x, frame.dimen.y)
                    UIManager:setDirty(nil, "fast", frame.dimen)
                    UIManager:forceRePaint()
                    on_tap_cb()
                elseif on_tap_cb then
                    on_tap_cb()
                end
                return true
            end
            return pill, frame_size.w
        end

        local pill_widgets = {}
        for _i, spec in ipairs(pill_specs) do
            local on_tap = spec.on_tap  -- per-iteration capture
            local pill, pw = _buildPill(spec.label, on_tap)
            pill_widgets[#pill_widgets + 1] = { widget = pill, w = pw }
        end

        -- Pack pills into rows (greedy, width-bounded). Stop once we
        -- hit MAX_PILL_ROWS; anything left becomes a "+N" pill that
        -- gets squeezed into the last row, dropping trailing pills if
        -- it doesn't fit.
        local rows = {}                 -- array of { pill_entries }
        local cur_row = {}
        local cur_w   = 0
        local stopped_at = nil          -- index of first pill that
                                        -- didn't fit (nil if all fit)
        for i, p in ipairs(pill_widgets) do
            local need = (cur_w == 0) and p.w or (cur_w + pill_gap + p.w)
            if need > text_w and cur_w > 0 then
                rows[#rows + 1] = cur_row
                if #rows >= MAX_PILL_ROWS then
                    stopped_at = i
                    cur_row = {}
                    cur_w   = 0
                    break
                end
                cur_row = {}
                cur_w   = 0
            end
            cur_row[#cur_row + 1] = p
            cur_w = (#cur_row == 1) and p.w or (cur_w + pill_gap + p.w)
        end
        if #cur_row > 0 and #rows < MAX_PILL_ROWS then
            rows[#rows + 1] = cur_row
            cur_row = nil
        end

        -- If we stopped early, append a "+N" pill. Tapping it opens the combined
        -- book-detail popup (every facet, still tappable, above the description).
        -- All "+N" widgets here share one callback.
        if stopped_at then
            local more_cb = function() self:_showBookDetail(book, { active = "tags" }) end
            local more_extra = Screen:scaleBySize(8)
            local hidden = #pill_widgets - stopped_at + 1
            local more_pill, more_w = _buildPill("+" .. hidden, more_cb, more_extra)
            -- Squeeze into the last row, evicting trailing pills if
            -- needed to make room.
            local last_row = rows[#rows]
            local last_w = 0
            for j, p in ipairs(last_row) do
                last_w = last_w + ((j == 1) and p.w or (pill_gap + p.w))
            end
            while #last_row > 0
                and (last_w + pill_gap + more_w) > text_w do
                local dropped = table.remove(last_row)
                hidden = hidden + 1
                last_w = last_w - dropped.w
                if #last_row > 0 then last_w = last_w - pill_gap end
                more_pill, more_w = _buildPill("+" .. hidden, more_cb, more_extra)
            end
            last_row[#last_row + 1] = { widget = more_pill, w = more_w }
        end

        -- Render rows into pill_group with vertical gaps between.
        for ri, row_pills in ipairs(rows) do
            local row_widget = HorizontalGroup_:new{ align = "center" }
            for j, p in ipairs(row_pills) do
                if j > 1 then
                    row_widget[#row_widget + 1] = HorizontalSpan_:new{
                        width = pill_gap,
                    }
                end
                row_widget[#row_widget + 1] = p.widget
            end
            if ri > 1 then
                pill_group[#pill_group + 1] = VerticalSpan_:new{
                    width = pill_gap,
                }
            end
            pill_group[#pill_group + 1] = row_widget
        end
    end

    -- Compose the text column so the top block anchors at the top of
    -- the thumbnail and the filepath block anchors at the bottom.
    -- VerticalSpan with the leftover height grows in the middle so
    -- total column height matches the thumbnail. Without the explicit
    -- flex span, the column would compress to its natural height and
    -- the filepath would sit immediately under the title block.
    local top_h     = top_stack:getSize().h
    local fp_h      = pill_group:getSize().h
    -- Minimum vertical gap between the filename line and the pill
    -- strip, so the pills don't crowd the metadata when the cover is
    -- tall enough to let flex_h collapse to zero. Only enforced when
    -- pills exist; pill-less headers (collection manager's manage
    -- mode etc.) don't pay the gap.
    local has_pills = pill_specs and #pill_specs > 0
    local min_gap   = has_pills and Size.padding.large or 0
    local target_h  = thumb_widget and thumb_h or (top_h + min_gap + fp_h)
    local flex_h    = math.max(min_gap, target_h - top_h - fp_h)
    local text_stack = VerticalGroup_:new{
        align = "left",
        top_stack,
        VerticalSpan_:new{ width = flex_h },
        pill_group,
    }

    local body
    if thumb_widget then
        -- text_stack now spans the cover's full height (top block of
        -- title/author/series, flex span, filepath at the bottom), so
        -- top-align is correct -- the column tops line up, the
        -- filepath sits flush with the cover's bottom edge.
        body = HorizontalGroup_:new{
            align = "top",
            thumb_widget,
            HorizontalSpan_:new{ width = gap_w },
            text_stack,
        }
    else
        body = text_stack
    end
    -- Vertical padding matches the existing horizontal frame padding so
    -- the cover doesn't sit flush against the dialog's top / bottom
    -- edges. ButtonDialog's title_group already contributes ~5dp of
    -- info_padding all around; this FrameContainer adds Size.padding.large
    -- on top + bottom so the cover gets a balanced visual frame
    -- (matching the left gap from dialog edge to cover).
    local header_frame = FrameContainer:new{
        bordersize = 0,
        margin     = 0,
        padding    = 0,
        body,
    }
    local result = header_frame
    if bm_link then
        -- Overlay the bookmark link in the top-right corner. RightContainer
        -- right-aligns it to the header width; the height-bounded dimen keeps
        -- it in the top band, and the link's own padding_top aligns it with
        -- the title. Same corner-anchoring idiom the hero card uses.
        local RightContainer = require("ui/widget/container/rightcontainer")
        local OverlapGroup   = require("ui/widget/overlapgroup")
        local hsize = header_frame:getSize()
        result = OverlapGroup:new{
            dimen = Geom:new{ w = hsize.w, h = hsize.h },
            header_frame,
            RightContainer:new{
                dimen = Geom:new{ w = hsize.w, h = bm_link:getSize().h },
                bm_link,
            },
        }
    end
    -- Expose the persistent cover bb (rich header only) so the caller frees it
    -- once the cached header is discarded.
    result._owned_cover_bb = owned_cover_bb
    return result
end

-- _buildPillSpecs(book, collection_set, close_cb) -> { { label, on_tap }, ... }
--
-- Shared pill-strip data builder used by the book menu AND the
-- Collection Manager. The two contexts disagree on which collections
-- to show:
--   - Book menu: actual saved membership (ReadCollection:getCollectionsWithFile)
--   - Collection Manager: DRAFT membership (toggles in flight, not yet saved)
-- so the caller passes whichever set is appropriate as a {name = true}
-- table.
--
-- close_cb is invoked AFTER each pill's drill action so the parent
-- dialog dismisses on tap. Tappable pills include: author, series,
-- collections, deduped genres, and folder.
function BookshelfWidget:_buildPillSpecs(book, collection_set, close_cb, filter)
    if not book then return {} end
    local bw   = self
    -- #99: optional per-category filter for the hero tags line. nil shows
    -- every category (the long-press book menu's pill strip passes nil, so
    -- it is unaffected). A category is hidden only when filter sets it
    -- explicitly false.
    local function _show(cat)
        return (filter == nil) or (filter[cat] ~= false)
    end
    local ReadCollection = require("readcollection")
    local default_coll_name = ReadCollection.default_collection_name
    local function _wrap(drill_fn)
        return function()
            drill_fn()
            if close_cb then close_cb() end
        end
    end
    local function _navResetAndClose()
        bw._drilldown_path = {}
    end

    local pill_specs = {}

    -- 1. Author(s): one pill per co-author (book.authors, KOReader's own
    -- one-per-<dc:creator>-line split), not just book.author (= authors[1]),
    -- so a multi-author book doesn't silently lose every name but the
    -- first. Falls back to the single book.author field for older/simpler
    -- records that never populated the authors array. Display respects the
    -- "Author name formatting" setting so each pill matches the form used
    -- elsewhere (hero, Authors chip). Drilldown still keys on the RAW name
    -- so the lookup matches the group regardless of the display form.
    if _show("author") then
        local names = (type(book.authors) == "table" and #book.authors > 0)
            and book.authors
            or (book.author and book.author ~= "" and { book.author } or nil)
        if names then
            local fmt = BookshelfSettings.read("author_format") or "auto"
            local AuthorName
            if fmt ~= "auto" then
                local ok_a, mod = pcall(require, "lib/bookshelf_author_name")
                if ok_a then AuthorName = mod end
            end
            for _i = 1, #names do
                local author_name = names[_i]
                local display_author = author_name
                if AuthorName and AuthorName.formatted then
                    display_author = AuthorName.formatted(author_name, fmt)
                end
                pill_specs[#pill_specs + 1] = {
                    cat    = "author",
                    label  = display_author,
                    on_tap = _wrap(function()
                        local group = Repo.findGroup("author", author_name)
                        if not group then
                            group = { kind = "author", series_name = author_name,
                                      books = { book }, latest = 0 }
                        end
                        _navResetAndClose()
                        bw:_expandAuthor(group)
                    end),
                }
            end
        end
    end

    -- 2. Series -- appends " #N" when book.series_num is set so the
    -- pill reads "[Southern Reach #2]" rather than the bare series
    -- name. Tapping still drills into the series view; the number is
    -- decoration on the pill itself.
    if _show("series") and book.series_name and book.series_name ~= "" then
        local series_name  = book.series_name
        local series_label = series_name
        if book.series_num then
            series_label = series_label .. " #" .. tostring(book.series_num)
        end
        pill_specs[#pill_specs + 1] = {
            cat    = "series",
            label  = series_label,
            on_tap = _wrap(function()
                local group = Repo.findGroup("series", series_name)
                if not group then
                    group = { kind = "series", series_name = series_name,
                              books = { book }, latest = 0 }
                end
                _navResetAndClose()
                bw:_expandSeries(group)
            end),
        }
    end

    -- 3. Collections (one pill per, sorted by name for stable order).
    -- The built-in "favorites" collection is intentionally excluded here:
    -- favourites has its own dedicated ★ button + cover badge, so a pill
    -- for it would be a duplicate UI affordance for the same toggle.
    -- Favourites is kept in the pill strip even though it has a dedicated
    -- ★ toggle button: the pill's role is NAVIGATION (tap to jump to the
    -- full favourites view), distinct from the button's TOGGLE role.
    local coll_names = {}
    for n, v in pairs(collection_set or {}) do
        if v then coll_names[#coll_names + 1] = n end
    end
    table.sort(coll_names, function(a, b) return a:lower() < b:lower() end)
    for _i, coll_name in ipairs(_show("collections") and coll_names or {}) do
        local display = (coll_name == default_coll_name) and _("Favourites") or coll_name
        pill_specs[#pill_specs + 1] = {
            cat    = "collections",
            label  = display,
            on_tap = _wrap(function()
                local rc = require("readcollection")
                local coll = rc.coll and rc.coll[coll_name]
                local books = {}
                if type(coll) == "table" then
                    for _file, item in pairs(coll) do
                        local fp = item.file or _file
                        if type(fp) == "string" then
                            books[#books + 1] = { filepath = fp }
                        end
                    end
                end
                _navResetAndClose()
                bw:_expandTag({ kind = "tag", series_name = coll_name,
                                books = books, latest = 0 })
            end),
        }
    end

    -- 4. Genres -- deduped against series name and collections so the
    -- same string doesn't render twice.
    if _show("genres") and book.genres and #book.genres > 0 then
        local _seen = {}
        -- Only dedup against categories that are actually on screen: if
        -- series / collections are hidden, a genre that happens to match one
        -- isn't a visible duplicate, so let it show.
        if _show("series") and book.series_name and book.series_name ~= "" then
            _seen[book.series_name:lower()] = true
        end
        for _i, coll_name in ipairs(_show("collections") and coll_names or {}) do
            _seen[coll_name:lower()] = true
            -- Localised display too -- "Favourites" UI label could collide
            -- with a same-named genre.
            local display = (coll_name == default_coll_name) and _("Favourites") or coll_name
            _seen[display:lower()] = true
        end
        for _i, genre_name in ipairs(book.genres) do
            local key = (genre_name or ""):lower()
            if key ~= "" and not _seen[key] then
                _seen[key] = true
                pill_specs[#pill_specs + 1] = {
                    cat    = "genres",
                    label  = genre_name,
                    on_tap = _wrap(function()
                        local group = Repo.findGroup("genre", genre_name)
                        if not group then
                            group = { kind = "genre", series_name = genre_name,
                                      books = { book }, latest = 0 }
                        end
                        _navResetAndClose()
                        bw:_expandGenre(group)
                    end),
                }
            end
        end
    end

    -- 5. Folder (skip when book sits at home_dir's top level).
    local parent_dir = book.filepath and book.filepath:match("^(.*)/[^/]+$")
    local home_dir
    do
        local ok_gs, gs = pcall(function() return G_reader_settings end)
        if ok_gs and gs then
            home_dir = gs:readSetting("home_dir")
            if type(home_dir) == "string" then
                home_dir = home_dir:gsub("/+$", "")
            end
        end
    end
    if _show("folder") and parent_dir and parent_dir ~= "" and parent_dir ~= home_dir then
        local folder_label = parent_dir:match("([^/]+)$") or parent_dir
        pill_specs[#pill_specs + 1] = {
            cat    = "folder",
            label  = folder_label,
            on_tap = _wrap(function()
                _navResetAndClose()
                bw:_expandFolder({ path = parent_dir, label = folder_label })
            end),
        }
    end

    return pill_specs
end

-- _sectionHeadingBar(text, content_w, font_size, inset) — a full-width black
-- strip with white uppercase text, the section heading used by the book-detail
-- Edit and Tags tabs. Paints a hair wider than content_w so the bar reaches the
-- window border (FrameContainer:getSize ignores `width`, so the slop can't widen
-- the layout). Left-inset so the heading text aligns with the body text.
function BookshelfWidget:_sectionHeadingBar(text, content_w, font_size, inset)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local TextWidget     = require("ui/widget/textwidget")
    local face, bold = BFont:getFace("cfont", math.max(10, (font_size or 18) - 3), { bold = true })
    return FrameContainer:new{
        background  = Blitbuffer.COLOR_BLACK,
        bordersize  = 0, margin = 0, width = content_w + Size.border.window,
        padding_left = inset, padding_right = inset,
        padding_top = Screen:scaleBySize(7), padding_bottom = Screen:scaleBySize(4),
        TextWidget:new{ text = TextSegments.upper(text), face = face, bold = bold,
            fgcolor = Blitbuffer.COLOR_WHITE },
    }
end

-- _segmentedChips(items, active_key, on_pick, font_size, inset) — a compact
-- segmented control matching the description tab's source chips: uppercase
-- labels, square corners, cells butted with thin separators inside one bordered
-- frame, the active cell inverted. items = { {key=, label=}, ... }. Tapping an
-- inactive chip fires on_pick(key). Left-inset to align with the body text.
function BookshelfWidget:_segmentedChips(items, active_key, on_pick, font_size, inset)
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local TextWidget      = require("ui/widget/textwidget")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LineWidget      = require("ui/widget/linewidget")
    local GestureRange    = require("ui/gesturerange")
    local sep_w = Size.border.thin
    local h_pad = Size.padding.large
    local v_pad = Size.padding.small
    -- Match the main bookshelf nav chip bar exactly: a logical 16pt label scaled
    -- by the user's chip-font setting (chip_font_scale). NOT Screen:scaleBySize,
    -- which the font layer scales a second time (font_size, passed in, is the
    -- larger body size and would make these read like the tab bar).
    local _chip_scale = BookshelfSettings.read("chip_font_scale") or 100
    local size  = math.floor(16 * _chip_scale / 100 + 0.5)
    local labels, cell_h = {}, 0
    for i, it in ipairs(items) do
        local face, bold = BFont:getFace("infofont", size, { bold = true })
        labels[i] = TextWidget:new{ text = TextSegments.upper(it.label or ""),
            face = face, bold = bold, fgcolor = Blitbuffer.COLOR_BLACK }
        cell_h = math.max(cell_h, labels[i]:getSize().h)
    end
    cell_h = cell_h + 2 * v_pad
    local row = HorizontalGroup:new{ align = "center" }
    local focus_row = {}
    for i, it in ipairs(items) do
        if i > 1 then
            row[#row + 1] = LineWidget:new{ background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = sep_w, h = cell_h } }
        end
        local cell_w = labels[i]:getSize().w + 2 * h_pad
        local is_active = (it.key == active_key)
        local body = InvertedFrame:new{
            _invert = is_active,
            bordersize = 0, margin = 0, padding = 0, background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h }, labels[i] },
        }
        local chip = InputContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h }, body }
        chip.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = chip.dimen } } }
        local key = it.key
        chip.onTap = function()
            if key ~= active_key and on_pick then on_pick(key) end
            return true
        end
        -- Dpad/keyboard focus highlight -- restores to the chip's own
        -- active/inactive baseline on unfocus, not unconditionally false,
        -- so the active chip stays visibly selected once focus moves away.
        chip.onFocus = function() body._invert = true; return true end
        chip.onUnfocus = function() body._invert = is_active; return true end
        row[#row + 1] = chip
        focus_row[#focus_row + 1] = chip
    end
    local framed = FrameContainer:new{
        bordersize = Size.border.thin, margin = 0, padding = 0, row }
    local outer = FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = inset, padding_right = inset,
        padding_top = Screen:scaleBySize(12), padding_bottom = Screen:scaleBySize(12),
        framed,
    }
    -- Second return value: the chips as one dpad row, left-to-right, for
    -- callers that want focus support (see _buildPillGroup's focus_rows).
    return outer, { focus_row }
end

-- _buildPillGroup(pill_specs, available_w, max_rows)
-- Render the same tappable pill strip used in the long-press book menu
-- as a self-contained widget that callers can drop into any layout.
-- Greedy width-bounded packing, capped at max_rows; overflow collapses
-- into a non-tappable "+N" pill. Returns a VerticalGroup (possibly
-- empty if pill_specs is empty / nil), plus a second return value:
-- focus_rows, the same row-wrapped pills (widgets only, left-to-right)
-- for callers that want dpad focus support -- see _buildPill's
-- onFocus/onUnfocus and FocusManager:mergeLayoutInVertical. Pure widget
-- builder — no state on self other than what the spec callbacks capture.
function BookshelfWidget:_buildPillGroup(pill_specs, available_w, max_rows, base_size, align, gap, on_overflow)
    local Font            = require("ui/font")
    local TextWidget_     = require("ui/widget/textwidget")
    local FrameContainer_ = require("ui/widget/container/framecontainer")
    local HorizontalGroup_ = require("ui/widget/horizontalgroup")
    local HorizontalSpan_  = require("ui/widget/horizontalspan")
    local VerticalGroup_   = require("ui/widget/verticalgroup")
    local VerticalSpan_    = require("ui/widget/verticalspan")
    local InputContainer_  = require("ui/widget/container/inputcontainer")
    local GestureRange_    = require("ui/gesturerange")

    max_rows = max_rows or 2
    -- align controls horizontal placement of the pill block (#99). Rows
    -- align within the block; the block is then aligned within available_w
    -- by the wrapper at the end.
    local row_align = (align == "center" or align == "right") and align or "left"
    local pill_group = VerticalGroup_:new{ align = row_align }
    if not pill_specs or #pill_specs == 0 then return pill_group, {} end

    local pill_face, pill_bold = BFont:getFace("cfont", base_size or 14, { bold = true })
    local pill_pad_h = Size.padding.default
    local pill_pad_v = Size.padding.small
    -- gap (optional) overrides the inter-pill / inter-row spacing; the tags
    -- sheet passes a larger value since it has room, while the space-tight
    -- hero/menu strips keep the default.
    local pill_gap   = gap or Size.padding.default
    -- #177: a single tag longer than the row would otherwise render at full
    -- natural width and spill off the screen edge (the packer only rejects a
    -- pill that isn't first in its row). Cap the label so one pill never exceeds
    -- available_w; TextWidget truncates with an ellipsis on one line (no wrap).
    local pill_label_max = math.max(1, available_w - 2 * pill_pad_h - 2 * Size.border.thin)

    -- extra_pad widens a pill's L/R padding (and so its tap target) without
    -- touching the others -- used to make the small "+N" overflow pill easier
    -- to hit. link_style renders an action (e.g. "Edit…") inline with the
    -- data pills but styled as a link -- no border, underlined label --
    -- so it reads as an action rather than another tag.
    local function _buildPill(label_text, on_tap_cb, extra_pad, on_hold_cb, link_style)
        local label_w = TextWidget_:new{
            text = TextSegments.upper(label_text or ""),
            face = pill_face,
            bold = pill_bold,
            max_width = pill_label_max,
        }
        -- Explicit white bg so the tap-feedback inversion has something to
        -- invert to black (without this, the frame's transparent fill
        -- can't be flipped). Matches KOReader's Button feedback pattern.
        local frame = FrameContainer_:new{
            bordersize     = link_style and 0 or Size.border.thin,
            background     = Blitbuffer.COLOR_WHITE,
            radius         = Size.radius.button,
            padding_left   = pill_pad_h + (extra_pad or 0),
            padding_right  = pill_pad_h + (extra_pad or 0),
            padding_top    = pill_pad_v,
            padding_bottom = pill_pad_v,
            margin         = 0,
            label_w,
        }
        local frame_size = frame:getSize()
        -- link_style paints the underline as an overlay inside the frame's
        -- own bottom padding (the same padding a bordered pill already
        -- reserves) instead of wrapping label_w in a taller container --
        -- that would grow this pill past its siblings' height and shift
        -- its text upward once the row vertically centres pills of
        -- different heights. Fixed black, never inverted on tap: a bordered
        -- pill's own border (FrameContainer's `color` field) is likewise
        -- left untouched by the bg/fg invert below, so it blends into the
        -- black fill instead of reading as a cutout -- the underline should
        -- do the same rather than flip to a visible white notch.
        if link_style then
            local ul_h     = Size.line.medium
            local ul_w     = label_w:getSize().w
            local ul_x_off = pill_pad_h + (extra_pad or 0)
            local ul_y_off = frame_size.h - ul_h
            function frame:paintTo(bb, x, y)
                FrameContainer_.paintTo(self, bb, x, y)
                bb:paintRect(x + ul_x_off, y + ul_y_off, ul_w, ul_h, Blitbuffer.COLOR_BLACK)
            end
        end
        local pill = InputContainer_:new{
            dimen = Geom:new{ w = frame_size.w, h = frame_size.h },
            frame,
        }
        pill.ges_events = {
            Tap = { GestureRange_:new{ ges = "tap", range = pill.dimen } },
        }
        if on_hold_cb then
            pill.ges_events.Hold = { GestureRange_:new{ ges = "hold", range = pill.dimen } }
            pill.onHold = function() on_hold_cb(); return true end
        end
        pill.onTap = function()
            -- Pre-callback tap feedback: invert the pill's bg/fg, paint
            -- the new state into the fb, drain the refresh queue with
            -- forceRePaint so the eink panel actually updates BEFORE
            -- the drilldown's rebuild runs. Modelled on KOReader's
            -- Button:_doFeedbackHighlight + forceRePaint pair
            -- (frontend/ui/widget/button.lua). The drilldown that
            -- follows rebuilds the widget tree, so no undo needed --
            -- the pill itself is gone by the next paint.
            if on_tap_cb and frame and frame.dimen then
                frame.background = frame.background:invert()
                label_w.fgcolor  = label_w.fgcolor:invert()
                UIManager:widgetRepaint(frame, frame.dimen.x, frame.dimen.y)
                UIManager:setDirty(nil, "fast", frame.dimen)
                -- This is the critical bit -- without it, setDirty
                -- only QUEUES a refresh, and the queue doesn't drain
                -- until the next UIManager iteration. Meanwhile the
                -- callback below runs synchronously and queues its
                -- own paint, so the user never sees the highlight.
                UIManager:forceRePaint()
                on_tap_cb()
            elseif on_tap_cb then
                on_tap_cb()
            end
            return true
        end
        -- Dpad/keyboard focus highlight -- frame is a stock FrameContainer,
        -- so its native `invert` field (the same one KOReader's own Button
        -- uses for onFocus/onUnfocus) works without any custom paintTo.
        pill.onFocus = function() frame.invert = true; return true end
        pill.onUnfocus = function() frame.invert = false; return true end
        return pill, frame_size.w
    end

    -- Build all pills first so the packer knows widths up front.
    local pill_widgets = {}
    for _i, spec in ipairs(pill_specs) do
        local on_tap = spec.on_tap
        local pill, pw = _buildPill(spec.label, on_tap, nil, spec.on_hold, spec.link)
        pill_widgets[#pill_widgets + 1] = { widget = pill, w = pw }
    end

    -- Greedy width-bounded pack into rows; stop at max_rows and track
    -- the first index that didn't fit.
    local rows = {}
    local cur_row, cur_w = {}, 0
    local stopped_at
    for i, p in ipairs(pill_widgets) do
        local need = (cur_w == 0) and p.w or (cur_w + pill_gap + p.w)
        if need > available_w and cur_w > 0 then
            rows[#rows + 1] = cur_row
            if #rows >= max_rows then
                stopped_at = i
                cur_row, cur_w = {}, 0
                break
            end
            cur_row, cur_w = {}, 0
        end
        cur_row[#cur_row + 1] = p
        cur_w = (#cur_row == 1) and p.w or (cur_w + pill_gap + p.w)
    end
    if #cur_row > 0 and #rows < max_rows then
        rows[#rows + 1] = cur_row
    end

    if stopped_at then
        -- The +N pill opens the overflow view (every pill, still tappable):
        -- on_overflow when the caller supplies one (e.g. the combined book-detail
        -- popup routes it to the full tags sheet on top of itself), else the bare
        -- tags sheet. All "+N" widgets share one callback over the full spec
        -- list, and get extra L/R padding for a bigger tap target.
        -- on_overflow opens the overflow view (the book-detail popup's Tags tab);
        -- nil leaves the "+N" non-tappable (no caller wants a bare list now).
        local more_cb = on_overflow
        local more_extra = Screen:scaleBySize(8)
        local hidden = #pill_widgets - stopped_at + 1
        local more_pill, more_w = _buildPill("+" .. hidden, more_cb, more_extra)
        local last_row = rows[#rows]
        local last_w = 0
        for j, p in ipairs(last_row) do
            last_w = last_w + ((j == 1) and p.w or (pill_gap + p.w))
        end
        while #last_row > 0
                and (last_w + pill_gap + more_w) > available_w do
            local dropped = table.remove(last_row)
            hidden = hidden + 1
            last_w = last_w - dropped.w
            if #last_row > 0 then last_w = last_w - pill_gap end
            more_pill, more_w = _buildPill("+" .. hidden, more_cb, more_extra)
        end
        last_row[#last_row + 1] = { widget = more_pill, w = more_w }
    end

    -- Focus rows mirror `rows`' wrapping exactly (one dpad row per visual
    -- row, widgets left-to-right) so a caller can hand this straight to
    -- FocusManager:mergeLayoutInVertical (via a `{layout=...}` wrapper)
    -- without re-deriving the pack. Most callers (hero pills, menu strips)
    -- ignore this second return value.
    local focus_rows = {}
    for ri, row_pills in ipairs(rows) do
        local row_widget = HorizontalGroup_:new{ align = "center" }
        local focus_row = {}
        for j, p in ipairs(row_pills) do
            if j > 1 then
                row_widget[#row_widget + 1] = HorizontalSpan_:new{ width = pill_gap }
            end
            row_widget[#row_widget + 1] = p.widget
            focus_row[#focus_row + 1] = p.widget
        end
        if ri > 1 then
            pill_group[#pill_group + 1] = VerticalSpan_:new{ width = pill_gap }
        end
        pill_group[#pill_group + 1] = row_widget
        focus_rows[#focus_rows + 1] = focus_row
    end
    -- row_align (set above) aligns each row WITHIN the block when rows have
    -- unequal widths. Aligning the whole block within the hero column is the
    -- caller's job (the hero wraps this in a Left/Centre/Right container at
    -- the authoritative column width).
    return pill_group, focus_rows
end

-- _setBookRating(book, new_rating): persist the rating to the book's
-- DocSettings summary, refresh the per-file progress cache so reads
-- pick up the new value, and rebuild the hero so the star row updates.
-- new_rating is 1-5 or nil (to clear). Matches KOReader's BookStatusWidget
-- storage: summary.rating in the .sdr/metadata.X.lua sidecar.
function BookshelfWidget:_setBookRating(book, new_rating, opts)
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
    --
    -- opts.skip_rebuild lets the staged-Apply path defer the rebuild
    -- so a multi-step apply (rating + status + collections + ...) only
    -- pays for one _rebuild + setDirty at the end of the loop rather
    -- than one per mutation. The cover-tap rating change still gets
    -- the immediate rebuild because it calls without opts.
    if not (opts and opts.skip_rebuild) then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
    end
end

-- _setBookRatingByPath(filepath, rating) — set a rating on a book by
-- filepath, without requiring the full Book table. Used by the bulk
-- actions module to apply a single rating across the selection.
-- Passes skip_rebuild = true so the bulk loop defers the single
-- _rebuild + setDirty to the caller after all mutations are done.
function BookshelfWidget:_setBookRatingByPath(filepath, rating)
    local fake_book = { filepath = filepath, rating = nil }
    self:_setBookRating(fake_book, rating, { skip_rebuild = true })
end

-- _refreshBucket — re-render the bucket/exit overlay after a
-- selection-set change. Called from cover-tap dispatch (wired in
-- Task 8) and from the ✕ exit handler.
--
-- Targeted swap of the selection overlay (bucket + ✕ icons) in
-- _refreshBucket() — re-render the bucket+✕ in the footer row after a
-- selection-set change. Rebuilds the footer row widget (chev nav stays
-- structurally unchanged but the selection row reflects the new count)
-- and swaps it into the overlap_group at the stashed footer index.
-- Scoped setDirty against the old footer's dimen keeps the refresh
-- bounded to the bottom strip instead of a full-screen flash.
function BookshelfWidget:_refreshBucket()
    if not self._selection:isActive() then return end
    if not self._overlap_group or not self._shelf_dims then return end
    local d = self._shelf_dims
    local old_anchor = self._overlap_group[d.footer_overlap_idx]
    local old_dimen  = old_anchor and old_anchor.dimen
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local new_footer_row = self:_buildFooterRow(d.content_w, self._total_pages or 1, d.FOOTER_H)
    local new_anchor = BottomContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height - d.FOOTER_BOTTOM_MARGIN },
        new_footer_row,
    }
    self._overlap_group[d.footer_overlap_idx] = new_anchor
    if self._overlap_group.resetLayout then self._overlap_group:resetLayout() end
    UIManager:setDirty(self, function()
        if old_dimen and old_dimen.h and old_dimen.h > 0 then
            return "ui", old_dimen
        end
        return "ui"
    end)
end

-- _refreshCoverFrame(filepath) — scoped repaint of a single cover
-- after its is_bulk_selected state changed. Currently a placeholder
-- that falls back to a full _rebuild + "ui" setDirty; the cell-
-- scoped optimisation should mirror _setBookRating's per-cell
-- refresh path. Called from cover-tap dispatch (wired in Task 8).
function BookshelfWidget:_refreshCoverFrame(_filepath)
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- Open a scrollable viewer with the full book description. Same
-- TextViewer the updater uses for release notes -- KOReader's stock
-- modal for "here's some text, more than fits on screen, you can
-- scroll it." The description is run through cleanDescription to
-- strip HTML tags and decode entities; the viewer renders plain
-- text with paragraph breaks preserved.
-- _descriptionArgs(book) — build the ReviewsModal args (title + tabs/html_body
-- + on_tab_close) for a book's description(s), or nil when the book has no
-- usable description. Shared by _showFullDescription and the combined
-- book-detail popup (_showBookDetail).
function BookshelfWidget:_descriptionArgs(book)
    if not book then return nil end
    local Tokens = require("lib/bookshelf_tokens")
    -- Render a raw description (either source) to HTML. Two shapes:
    --   * EPUB / Calibre blurbs are HTML (<p>, <b>, <br>, …) -> keep the markup
    --     via the shared sanitiser (whitelisted tags, attributes stripped).
    --   * Hardcover blurbs are PLAIN TEXT with \n\n paragraph breaks and no
    --     tags -> the HTML renderer would collapse those newlines into a single
    --     block, so convert paragraph/line breaks to HTML instead.
    -- A real tag is "<" immediately followed by an (optional "/" then a) letter
    -- -- e.g. <p> or </p>. This deliberately does NOT match prose like "x < y"
    -- (space after "<"), so plain-text blurbs with a stray angle bracket still
    -- take the plain-text path.
    local function toHtml(raw)
        if type(raw) ~= "string" or raw == "" then return nil end
        local html
        if raw:find("</?%a") then html = Tokens.sanitiseReviewHtml(raw) end
        if not html or html:gsub("%s+", "") == "" then
            local text = Tokens.cleanDescription(raw) or ""
            if text == "" then return nil end
            local esc = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
            html = "<p>" .. (esc:gsub("\n\n+", "</p><p>"):gsub("\n", "<br>")) .. "</p>"
        end
        return html
    end

    -- The book's OWN (embedded / Calibre) description and Hardcover's. enrichBook
    -- stashes file_description (the original, even when Hardcover's is the one
    -- shown) and hardcover_description_text. For an un-enriched book there's no
    -- Hardcover text and book.description is its own.
    local file_desc
    if book.file_description ~= nil then
        file_desc = book.file_description
    elseif not book.hardcover_description then
        file_desc = book.description
    end
    local file_html = toHtml(file_desc)
    local hc_html   = toHtml(book.hardcover_description_text
        or (book.hardcover_description and book.description) or nil)
    if not file_html and not hc_html then return nil end

    local title = book.title or _("Description")
    if book.author then title = title .. " — " .. book.author end

    local args = { title = title }
    if file_html and hc_html then
        -- Both available: an Embedded / Hardcover toggle (a chip bar at the top
        -- of the Description tab). Default to whichever the hero currently shows.
        args.tabs = {
            -- "Embedded" = the book file's own (KOReader/EPUB/Calibre) field;
            -- "Hardcover" = the fetched blurb.
            { label = _("Embedded"),  html = file_html },   -- 1 = book's own
            { label = _("Hardcover"), html = hc_html },      -- 2 = Hardcover
        }
        args.active_tab = book.hardcover_description and 2 or 1
        -- On close, adopt the chosen source: switching the chip and closing
        -- changes what the hero (and the book's other surfaces) use -- same
        -- effect as the per-book "Use Hardcover description" toggle. Only writes
        -- when the choice actually changed.
        args.on_tab_close = function(active_idx)
            local use_hc = (active_idx == 2)
            if use_hc ~= (book.hardcover_description == true) then
                local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
                if ok_hc and Hardcover and Hardcover.setUseDescription then
                    Hardcover.setUseDescription(book.filepath, use_hc)
                    self:_refreshHardcoverEnrichmentView(
                        "hardcover-use-description", book.filepath)
                end
            end
        end
    else
        -- Single source: show it, and note Hardcover-sourced descriptions.
        args.html_body = hc_html or file_html
        if hc_html and not file_html then args.subtitle = _("(from Hardcover)") end
    end
    return args
end

-- Tapping the description opens the unified book-detail popup (pills always on
-- top, description + reviews tabs below) -- the pills are shown here too, not
-- only via the "+N" overflow.
function BookshelfWidget:_showFullDescription(book)
    return self:_showBookDetail(book)
end

-- _commitBookStatus(book, status) — write a reading status ("new" | "reading" |
-- "abandoned" | "complete") to the book's DocSettings and bust the caches the
-- shelf + menu read. Immediate (no staging); the Edit tab uses it directly.
-- Mirrors the long-press menu's Apply-status step.
function BookshelfWidget:_commitBookStatus(book, status)
    if not (book and book.filepath and status) then return end
    local DocSettings = require("docsettings")
    local ds = DocSettings:open(book.filepath)
    local summary = ds:readSetting("summary") or {}
    summary.status   = status
    summary.modified = os.date("%Y-%m-%d", os.time())  -- #66: stamp like KOReader
    ds:saveSetting("summary", summary)
    if status == "new" then
        ds:delSetting("percent_finished")
        ds:delSetting("last_xp")
        ds:delSetting("last_page")
    end
    ds:flush()
    Repo.invalidateProgressCache(book.filepath)
    Repo.invalidateBookCache("edit-status")
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and BookList and BookList.resetBookInfoCache then
        BookList.resetBookInfoCache(book.filepath)
    end
end

-- A ScrollableContainer whose vertical scrollbar sits flush against the right
-- edge with no side padding. The stock container reserves 3x the bar width
-- (gap | bar | gap); this reclaims both gaps so the content butts the bar and
-- the bar butts the frame. LTR only -- RTL falls back to the stock layout.
local SnugScroll = require("ui/widget/container/scrollablecontainer"):extend{}
function SnugScroll:initState()
    require("ui/widget/container/scrollablecontainer").initState(self)
    if not self._is_scrollable or require("ui/bidi").mirroredUILayout() then return end
    if self._v_scroll_bar then
        self._crop_w = self.dimen.w - self.scroll_bar_width  -- content up to the bar
    end
    -- The parent decided horizontal overflow against its 3x reserve, so content
    -- sized to the snug crop still triggered a spurious horizontal bar (and ate
    -- height). Re-decide it against the real crop width and drop the h-bar when
    -- the content actually fits.
    local content_w = self[1]:getSize().w
    self._max_scroll_offset_x = math.max(0, content_w - self._crop_w)
    if self._max_scroll_offset_x == 0 and self._h_scroll_bar then
        self._h_scroll_bar = nil
        self._crop_h = self.dimen.h
    end
end
function SnugScroll:paintTo(bb, x, y)
    if self._is_scrollable == nil then self:initState() end
    local real_w = self.dimen.w
    -- The parent paints the v-bar at dimen.w - 2*bar_width; inflating dimen.w by
    -- one bar width during paint shifts it to dimen.w - bar_width (flush right).
    if self._v_scroll_bar and not require("ui/bidi").mirroredUILayout() then
        self.dimen.w = real_w + self.scroll_bar_width
    end
    require("ui/widget/container/scrollablecontainer").paintTo(self, bb, x, y)
    self.dimen.w = real_w
end

-- Used by the Edit tab's infoRow (File & metadata / Hardcover rows): a thin
-- gray separator + a pre-built Button, both centred in a cell row_h tall. The
-- separator is inset top/bottom by Size.span.vertical_default -- the same
-- gap ButtonTable leaves around ITS OWN row separators (buttontable.lua's
-- addVerticalSpan calls either side of addVerticalSeparator) -- rather than
-- running edge-to-edge against the row's top/bottom, so it reads as the
-- same "standard menu button" separator used everywhere else in this popup.
--
-- want_bottom_border: pass true when nothing below this row already closes
-- it off visually -- i.e. the next thing isn't another section's black
-- heading bar (whose top edge otherwise reads as this row's bottom border,
-- same reasoning as why the row has no top border of its own). Total
-- height always comes out to row_h either way, so callers don't need to
-- adjust their own sizing based on which case applies.
-- A minimal `{layout=...}` wrapper satisfying FocusManager:mergeLayoutInVertical's
-- contract (child.layout + child:disableFocusManagement) for a one-off custom
-- row that isn't itself a real FocusManager instance -- e.g. a single stock
-- Button, or a hand-built row of custom InputContainers (star ratings, tag
-- pills). disableFocusManagement is a no-op beyond recording the parent:
-- unlike a real FocusManager (ButtonTable), this wrapper never independently
-- owns a "currently selected" sub-widget to unfocus -- its rows are merged
-- straight into the caller's own layout and never interacted with directly.
local function focusRow(layout)
    return {
        layout = layout,
        disableFocusManagement = function(self, parent) self._parent = parent end,
    }
end

function BookshelfWidget:_actionButtonColumn(btn, box_w, row_h, want_bottom_border)
    local LineWidget = require("ui/widget/linewidget")
    local sep_w = Size.line.medium
    local gap   = Size.span.vertical_default
    local border_w = want_bottom_border and Size.line.medium or 0
    local cell_h = row_h - border_w
    local sep_h = math.max(Screen:scaleBySize(4), cell_h - 2 * gap)
    local sep = CenterContainer:new{
        dimen = Geom:new{ w = sep_w, h = cell_h },
        LineWidget:new{ background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = sep_w, h = sep_h } },
    }
    local btn_cell = CenterContainer:new{
        dimen = Geom:new{ w = box_w, h = cell_h }, btn }
    local col = HorizontalGroup:new{ align = "top", sep, btn_cell }
    if not want_bottom_border then return col end
    return VerticalGroup:new{ align = "left", col,
        LineWidget:new{ background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = sep_w + box_w, h = border_w } } }
end

-- _buildBookEditTab(book, modal, avail_w, avail_h) — the Edit tab body:
-- immediate-commit book actions (no draft / Apply / Cancel) grouped under
-- section headings (Reading status / Ratings / Collections / Hardcover / File &
-- metadata / Plugin actions). In-place actions (status, rating, favourite,
-- remove-from-history) rebuild the shelf and refresh this tab via
-- modal:rebuildTab(); surface-opening actions (Show info, Manage collections,
-- Reset, Delete, Refresh, Link Hardcover, Select) close the popup first.
-- All text (buttons, headings, stars) scales with the modal's +/- font size.
-- Hardcover reviews aren't here -- they're the Reviews tab.
function BookshelfWidget:_buildBookEditTab(book, modal, avail_w, avail_h)
    local bw = self
    local ButtonTable         = require("ui/widget/buttontable")
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local FrameContainer      = require("ui/widget/container/framecontainer")
    local ReadCollection      = require("readcollection")
    local LineWidget          = require("ui/widget/linewidget")
    local TextWidget          = require("ui/widget/textwidget")
    local TextBoxWidget       = require("ui/widget/textboxwidget")
    local InputContainer      = require("ui/widget/container/inputcontainer")
    local HorizontalGroup     = require("ui/widget/horizontalgroup")
    local HorizontalSpan      = require("ui/widget/horizontalspan")
    local VerticalSpan        = require("ui/widget/verticalspan")
    local GestureRange        = require("ui/gesturerange")

    -- Hydrate rating from the sidecar (shelf records skip it for speed).
    if book.rating == nil and book.filepath then
        local _pct, _st, fresh = Repo.readProgress(book.filepath)
        book.rating = fresh
    end

    local font_size = (modal and modal.font_size) or 20

    local function closeModal() if modal then UIManager:close(modal) end end
    local function refreshShelf() bw:_rebuild(); UIManager:setDirty(bw, "ui") end
    local function refreshInPlace()  -- commit done; refresh shelf + this tab
        bw:_rebuild(); UIManager:setDirty(bw, "ui")
        if modal and modal.rebuildTab then modal:rebuildTab() end
    end

    -- ── Hardcover availability + cached rating (read-only) ───────────────────
    local _ok_hc, _HC = pcall(require, "lib/bookshelf_hardcover")
    local hc_available = _ok_hc and _HC and _HC.isAvailable and _HC.isAvailable()
    local hc_rating
    if hc_available and book.filepath then
        local link = _HC.getLink and _HC.getLink(book.filepath)
        local book_id = book.hardcover_book_id or (link and link.book_id)
        if book_id and _HC.getCachedRating then
            hc_rating = _HC.getCachedRating(book_id)
        end
    end

    -- ── Show info ────────────────────────────────────────────────────────────
    local show_info = { text = _("Show info"), callback = function()
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(book.filepath, "mode") ~= "file" then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("File no longer exists. The bookshelf entry is stale."),
                timeout = 3 })
            return
        end
        closeModal()
        local FileManager = require("apps/filemanager/filemanager")
        local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
        if FileManager.instance and FileManager.instance.bookinfo then
            FileManager.instance.bookinfo:show(book.filepath)
        else
            FileManagerBookInfo:new{}:show(book.filepath)
        end
    end }

    -- Favourite toggle keys off the default collection (Collections membership
    -- itself is shown/edited on the Tags tab, not here).
    local default_coll = ReadCollection.default_collection_name

    -- ── Reading status quad ──────────────────────────────────────────────────
    local BookList = require("ui/widget/booklist")
    local function statusBtn(label, value)
        return {
            text_func = function()
                local cur = BookList.getBookStatus(book.filepath)
                return (cur == value) and (label .. "  \xE2\x9C\x93") or label  -- ✓
            end,
            callback = function()
                if BookList.getBookStatus(book.filepath) == value then return end
                bw:_commitBookStatus(book, value)
                refreshInPlace()
            end,
        }
    end

    -- ── Favourite / Remove from history ──────────────────────────────────────
    local remove_history = { text = _("Remove from history"), callback = function()
        pcall(function() require("readhistory"):removeItemByPath(book.filepath) end)
        Repo.invalidateBookCache("edit-remove-history")
        refreshInPlace()
        UIManager:show(require("ui/widget/notification"):new{
            text = _("Removed from history"), timeout = 1 })
    end }
    local function inFav()
        local s = ReadCollection:getCollectionsWithFile(book.filepath) or {}
        return s[default_coll] and true or false
    end
    local fav = {
        text_func = function() return (inFav() and "\xE2\x88\x92 " or "+ ") .. _("Favourite") end,
        callback = function()
            if inFav() then
                pcall(function() ReadCollection:removeItem(book.filepath, default_coll) end)
            else
                pcall(function() ReadCollection:addItem(book.filepath, default_coll) end)
            end
            pcall(function() ReadCollection:write() end)
            pcall(function() Repo.invalidateFavoritesCache() end)
            refreshInPlace()
        end,
    }

    -- ── File & metadata ──────────────────────────────────────────────────────
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local reset_btn = filemanagerutil.genResetSettingsButton(book.filepath, function()
        Repo.invalidateProgressCache(book.filepath)
        Repo.invalidateWalkCache()
        refreshShelf()
    end)
    reset_btn.text = _("Reset book data\xE2\x80\xA6")
    local orig_reset = reset_btn.callback
    reset_btn.callback = function() closeModal(); orig_reset() end

    local delete_btn = { text = "\xE2\x9C\x95 " .. _("Delete"), callback = function()  -- ✕
        closeModal()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance and FileManager.instance.showDeleteFileDialog then
            FileManager.instance:showDeleteFileDialog(book.filepath, function()
                Repo.invalidateProgressCache(book.filepath)
                Repo.invalidateWalkCache()
                bw:_scrubFromDrilldown(book.filepath)
                refreshShelf()
            end)
        else
            UIManager:show(require("ui/widget/confirmbox"):new{
                text    = _("Delete file permanently?") .. "\n\n" .. book.filepath,
                ok_text = _("Delete"),
                ok_callback = function()
                    if os.remove(book.filepath) then
                        require("readhistory"):fileDeleted(book.filepath)
                        ReadCollection:removeItem(book.filepath)
                        Repo.invalidateProgressCache(book.filepath)
                        Repo.invalidateWalkCache()
                        bw:_scrubFromDrilldown(book.filepath)
                        refreshShelf()
                    else
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = _("Failed to delete file."), icon = "notice-warning" })
                    end
                end,
            })
        end
    end }

    local refresh_btn = { text = _("Refresh metadata"), callback = function()
        closeModal()
        local ok_bim, BIM = pcall(require, "bookinfomanager")
        if ok_bim and BIM and BIM.deleteBookInfo then
            pcall(function() BIM:deleteBookInfo(book.filepath) end)
        end
        pcall(function() require("lib/bookshelf_scaled_cover_cache"):drop(book.filepath) end)
        Repo.invalidateProgressCache(book.filepath)
        Repo.invalidateBookCache("refresh-metadata")
        if bw._hero_current_memo and bw._hero_current_memo.fp == book.filepath then
            bw._hero_current_memo = nil
        end
        bw:_rebuild(); UIManager:setDirty(bw, "ui")
        UIManager:show(require("ui/widget/notification"):new{
            text = _("Metadata refresh queued"), timeout = 2 })
    end }
    local select_btn = { text = _("Select"), callback = function()
        closeModal()
        if not bw._selection:isActive() then bw._selection:enterMode() end
        bw._selection:add(book.filepath)
        bw:_rebuild(); UIManager:setDirty(bw, "ui")
    end }

    -- Third-party file-dialog buttons (e.g. Incognito). Run their specs RAW --
    -- exactly as the old long-press menu did -- rather than wrapping them to
    -- close the popup first; a plugin callback that opens the reader triggers our
    -- onShowingReader handler, which closes the popup cleanly.
    local plugin_rows = bw:_fileDialogPluginRows(book.filepath)

    -- ── Section row groups ───────────────────────────────────────────────────
    local status_rows = {
        {
            statusBtn(_("Unopened"), "new"),       statusBtn(_("Reading"),  "reading"),
            statusBtn(_("On hold"),  "abandoned"), statusBtn(_("Finished"), "complete"),
        },
        { fav, remove_history },
    }
    local file_rows = {
        { show_info, refresh_btn, select_btn },
        { reset_btn, delete_btn },
    }

    -- This is our own widget tree (not a ButtonDialog), so the body is a
    -- VerticalGroup we compose freely. Section headings are a full-width BLACK
    -- STRIP with white text -- a strong, compact divider, so option rows butt
    -- straight up against it with no rules between sections (only the very last
    -- section gets a closing rule). ButtonTable draws gray separators BETWEEN
    -- rows but no outer border, so a section's first button meets the strip
    -- above it and its last meets the next strip.
    local bar_w     = Screen:scaleBySize(3)   -- thin scrollbar; minimal right reserve
    local sb        = bar_w   -- SnugScroll reserves exactly the bar width (no gaps)
    local pad_top    = 0   -- first heading strip butts against the tab strip
    local pad_bottom = Screen:scaleBySize(10)
    -- Left inset = the modal's shared side pad, so heading text + info-row text
    -- line up with the tab strip and the description body.
    local inset      = (modal and modal._side_pad) or Screen:scaleBySize(28)

    -- Stamp the font size onto every button spec so the +/- zoom scales them.
    -- Also stamp an explicit `height`, floored to what the footer's Zoom-/
    -- Zoom+ buttons render at: those are the tallest thing in the footer's
    -- row, since they use the bundled Nerd Font "symbols" face (an on-device
    -- probe confirmed this face renders taller than bold "cfont" text at the
    -- same nominal size -- 55px vs 48px on the maintainer's PW5). The footer's
    -- Close/Open text buttons don't set their own height; ButtonTable just
    -- takes the row's max, so the whole row inherits the icon buttons'
    -- height. None of this tab's rows have an icon glyph, so without an
    -- explicit floor they render shorter than the footer even at the same
    -- font_size.
    local Button = require("ui/widget/button")
    local function labelHeightAt(sz, face, bold)
        local probe = Button:new{ text = "Ag", text_font_size = sz,
            text_font_face = face, text_font_bold = bold }
        local h = probe.label_widget:getSize().h
        probe:free()
        return h
    end
    local row_label_h = math.max(
        labelHeightAt(font_size, "cfont", true),
        labelHeightAt(20, "symbols", false))
    local function sizeRows(rows)
        for _r = 1, #rows do
            for _c = 1, #rows[_r] do
                rows[_r][_c].font_size = font_size
                rows[_r][_c].height    = row_label_h
            end
        end
        return rows
    end

    local function buildBody(content_w)
        local function rule()
            return LineWidget:new{
                background = Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{ w = content_w, h = Size.line.medium },
            }
        end
        local function heading(text)
            -- Pass the FULL tab width (not the scroll-reduced content_w) so the
            -- bar reaches the frame edge; getSize ignores width, so it can't widen
            -- the layout, and the scroll crop trims any overhang behind the bar.
            return bw:_sectionHeadingBar(text, avail_w, font_size, inset)
        end
        local function padded(widget, top, bottom)
            return FrameContainer:new{
                bordersize = 0, margin = 0,
                padding_left = inset, padding_right = inset,
                padding_top = top, padding_bottom = bottom,
                widget,
            }
        end
        local vg = VerticalGroup:new{ align = "left" }
        -- Every focusable section/row, in visual top-to-bottom order, so the
        -- modal's dpad nav can chain across ALL of them -- not just the
        -- first ButtonTable (each one already builds its own `.layout`,
        -- see ui/widget/buttontable.lua; one-off custom rows below get a
        -- `{layout=...}` wrapper to match that same shape).
        local focus_tables = {}
        local function btSection(title, rows)
            vg[#vg + 1] = heading(title)
            local bt = ButtonTable:new{
                width = content_w, buttons = sizeRows(rows), show_parent = modal }
            vg[#vg + 1] = bt
            focus_tables[#focus_tables + 1] = bt
            return bt
        end

        -- 1. Reading status.
        btSection(_("Reading status"), status_rows)

        -- 2. Ratings: editable "Your rating" stars and, inline, the read-only
        -- Hardcover rating (same star glyphs + spacing; a half star where the
        -- rating lands on a half) plus the numeric value.
        -- nf-fa-star / star_half_empty / star_o (the half matches the hero glyphs).
        local STAR_FULL, STAR_HALF, STAR_EMPTY = "\xEF\x80\x85", "\xEF\x84\xA3", "\xEF\x80\x86"
        local star_size = font_size + 4
        -- A padded star glyph. With on_tap it's an interactive (tappable) star;
        -- without, just the padded glyph -- so interactive and read-only star rows
        -- get identical per-star spacing.
        local function buildStar(glyph, on_tap)
            local tw = TextWidget:new{ text = glyph,
                face = BFont:getFace("symbols", star_size), fgcolor = Blitbuffer.COLOR_BLACK }
            local frame = FrameContainer:new{
                bordersize = 0, margin = 0, padding = Screen:scaleBySize(3), tw }
            if not on_tap then return frame end
            local fsz = frame:getSize()
            local star = InputContainer:new{ dimen = Geom:new{ w = fsz.w, h = fsz.h }, frame }
            star.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = star.dimen } } }
            star.onTap = function() on_tap(); return true end
            -- Dpad/keyboard focus highlight -- frame is a stock FrameContainer.
            star.onFocus = function() frame.invert = true; return true end
            star.onUnfocus = function() frame.invert = false; return true end
            return star
        end
        -- Rating labels match the body text size (the number, collection names).
        local lbl_face = BFont:getFace("cfont", font_size)
        local function lbl(text)
            return TextWidget:new{ text = text, face = lbl_face, fgcolor = Blitbuffer.COLOR_BLACK }
        end
        local cur = tonumber(book.rating) or 0
        if cur < 0 then cur = 0 elseif cur > 5 then cur = 5 end
        cur = math.floor(cur)
        -- "Your rating": label + tappable stars.
        local your_group = HorizontalGroup:new{ align = "center" }
        your_group[#your_group + 1] = lbl(_("Your rating"))
        your_group[#your_group + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(10) }
        local your_stars = {}
        for i = 1, 5 do
            local glyph = (i <= cur) and STAR_FULL or STAR_EMPTY
            local star = buildStar(glyph, function()
                local newv = (i == cur) and nil or i   -- tap current rating clears it
                bw:_setBookRating(book, newv); book.rating = newv
                if modal and modal.rebuildTab then modal:rebuildTab() end
            end)
            your_group[#your_group + 1] = star
            your_stars[#your_stars + 1] = star
        end
        -- One dpad row, left-to-right across the 5 stars.
        focus_tables[#focus_tables + 1] = focusRow({ your_stars })

        local ratings_widget = your_group
        if hc_rating then
            -- The Hardcover stars tap through to the Reviews tab when present.
            local reviews_idx
            if modal and modal._tabs then
                for ti, t in ipairs(modal._tabs) do
                    if t.id == "reviews" then reviews_idx = ti; break end
                end
            end
            -- Read-only stars built the same way as the user-rating stars (same
            -- per-star padding) so the two rows line up, with a half star where
            -- the rating falls on a half.
            local halves = math.floor(hc_rating * 2 + 0.5)  -- 0..10 half-units
            local hc_stars = HorizontalGroup:new{ align = "center" }
            for i = 1, 5 do
                local glyph = STAR_EMPTY
                if halves >= 2 * i then glyph = STAR_FULL
                elseif halves == 2 * i - 1 then glyph = STAR_HALF end
                hc_stars[#hc_stars + 1] = buildStar(glyph, nil)
            end
            local hc_stars_widget = hc_stars
            if reviews_idx and modal._switchTab then
                local fsz = hc_stars:getSize()
                local ic  = InputContainer:new{ dimen = Geom:new{ w = fsz.w, h = fsz.h }, hc_stars }
                ic.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
                ic.onTap = function() modal:_switchTab(reviews_idx); return true end
                -- Dpad/keyboard focus highlight: ic is a plain InputContainer
                -- (no stock `invert`, unlike FrameContainer), so paint then
                -- pixel-invert on top -- the same idiom as InvertedFrame
                -- elsewhere in this file.
                ic._focused = false
                function ic:paintTo(bb, x, y)
                    InputContainer.paintTo(self, bb, x, y)
                    if self._focused then bb:invertRect(x, y, self.dimen.w, self.dimen.h) end
                end
                ic.onFocus = function() ic._focused = true; return true end
                ic.onUnfocus = function() ic._focused = false; return true end
                hc_stars_widget = ic
                focus_tables[#focus_tables + 1] = focusRow({ { ic } })
            end
            local hc_group = HorizontalGroup:new{ align = "center",
                lbl(_("Hardcover")),
                HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                hc_stars_widget,
                HorizontalSpan:new{ width = Screen:scaleBySize(8) },
                TextWidget:new{ text = string.format("%.1f", hc_rating),
                    face = BFont:getFace("cfont", font_size), fgcolor = Blitbuffer.COLOR_BLACK },
            }
            -- Side by side when they fit; otherwise wrap onto two lines (needed
            -- at large zoom / high DPI where one row would overflow).
            local avail = content_w - 2 * inset
            local sep   = Screen:scaleBySize(28)
            if your_group:getSize().w + sep + hc_group:getSize().w <= avail then
                ratings_widget = HorizontalGroup:new{ align = "center",
                    your_group, HorizontalSpan:new{ width = sep }, hc_group }
            else
                ratings_widget = VerticalGroup:new{ align = "left",
                    your_group, VerticalSpan:new{ width = Screen:scaleBySize(8) }, hc_group }
            end
        end
        -- Centre the rating row(s) within the section instead of hugging the
        -- left inset -- reads better as a standalone block of content rather
        -- than a left-aligned label/value pair like the rows above it.
        ratings_widget = CenterContainer:new{
            dimen = Geom:new{ w = content_w - 2 * inset, h = ratings_widget:getSize().h },
            ratings_widget,
        }
        vg[#vg + 1] = heading(_("Ratings"))
        vg[#vg + 1] = padded(ratings_widget, Screen:scaleBySize(8), Screen:scaleBySize(10))

        -- An info row styled like a File-&-metadata button row: the value on the
        -- left (inset to align with the headings), a thin vertical gray separator
        -- matching the ButtonTable column separators, then a real (borderless)
        -- Button on the right -- same font, weight and height as the other
        -- buttons. Used by the Hardcover row.
        local function infoRow(text, btn_label, cb, want_bottom_border)
            local btn_w = Screen:scaleBySize(150)
            local btn = Button:new{
                text = btn_label, callback = cb,
                text_font_size = font_size,
                height = row_label_h,
                bordersize = 0, margin = 0, radius = 0,
                -- Match the ButtonTable buttons' (taller) padding so the row is
                -- the same height as the File & metadata rows.
                padding = Size.padding.buttontable,
                padding_h = Size.padding.button,
                width = btn_w, show_parent = modal,
            }
            local btn_h = btn:getSize().h
            -- Left cell: the value text, inset on the left to align with headings.
            local left_w = math.max(Screen:scaleBySize(60),
                content_w - Size.line.medium - btn_w)
            local txt = TextBoxWidget:new{ text = text,
                face  = BFont:getFace("cfont", font_size),
                width = math.max(Screen:scaleBySize(40), left_w - inset - Screen:scaleBySize(8)) }
            -- Row height matches a button-table row: the button band plus the
            -- vertical spans ButtonTable puts around each row. Grows only if the
            -- value wraps. Value + button vertically centred within it.
            local row_h = math.max(btn_h, txt:getSize().h) + 2 * Size.span.vertical_default
            local top_pad = math.floor((row_h - txt:getSize().h) / 2)
            local left_cell = FrameContainer:new{
                bordersize = 0, margin = 0,
                padding_left = inset, padding_right = Screen:scaleBySize(8),
                padding_top = top_pad, padding_bottom = row_h - txt:getSize().h - top_pad,
                txt,
            }
            -- btn is a stock Button (native onFocus/onUnfocus) -- just needs
            -- registering as its own dpad row.
            focus_tables[#focus_tables + 1] = focusRow({ { btn } })
            return HorizontalGroup:new{ align = "top", left_cell,
                bw:_actionButtonColumn(btn, btn_w, row_h, want_bottom_border) }
        end

        -- 3. File & metadata.
        btSection(_("File & metadata"), file_rows)

        -- 4. Hardcover link (brand name -> heading not translated). Edition text
        -- + inline Edit/Link button, below File & metadata. (Collections live on
        -- the Tags tab, which has its own per-collection pills + Edit affordance
        -- -- no need to duplicate the same membership here in a second style.)
        if hc_available then
            local label = _HC.linkLabel and _HC.linkLabel(book.filepath)
            vg[#vg + 1] = heading("Hardcover")
            -- No bottom border needed here: whatever follows (Plugin
            -- actions' heading, or the unconditional closing rule() below
            -- if this is the last section) already closes this row off.
            vg[#vg + 1] = infoRow(
                label or _("Not linked"),
                label and _("Edit\xE2\x80\xA6") or _("Link\xE2\x80\xA6"),
                function()
                    closeModal()
                    UIManager:nextTick(function() bw:_openHardcoverMenu(book) end)
                end)
        end

        -- 5. Plugin actions (only when a plugin contributed buttons).
        if plugin_rows and #plugin_rows > 0 then
            btSection(_("Plugin actions"), plugin_rows)
        end

        -- Close the last section so its final button has a bottom edge.
        vg[#vg + 1] = rule()
        return vg, focus_tables
    end

    -- Full width first; if the body overflows the tab height it will scroll, so
    -- rebuild scrollbar-width narrower to leave the bar its own strip.
    local body, focus_tables = buildBody(avail_w)
    if body:getSize().h + pad_top + pad_bottom > avail_h then
        body, focus_tables = buildBody(avail_w - sb)
    end
    local padded_body = FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = 0, padding_right = 0,
        padding_top = pad_top, padding_bottom = pad_bottom,
        body,
    }
    local scroll = SnugScroll:new{
        dimen = Geom:new{ w = avail_w, h = avail_h },
        scroll_bar_width = bar_w,
        show_parent = modal,
        padded_body,
    }
    -- Every section's focusable row(s), in visual order, so the modal's
    -- FocusManager can chain dpad nav across the whole tab (see
    -- ReviewsModal:_assemble's handling of an ARRAY focus_tables).
    scroll.focus_tables = focus_tables
    return scroll
end

-- Native "★★★★☆ 3.6 · 54 ratings · 14 reviews  [reload Refresh]" header row for
-- the Reviews tab, sitting above its own HTML review list (_buildReviewsTab
-- below). The summary used to be part of that HTML with an inline "Refresh"
-- <a> link; moved out to a native row so Refresh gets real tap feedback
-- (pixel-inverts while the fetch is in flight) and its label can match the
-- summary text's own (zoom-adjustable) font size, using the same small-button
-- style as the Icons Library's search/close buttons (bookshelf_chip_button).
function BookshelfWidget:_buildReviewsHeader(tab, modal, avail_w, refreshReviews)
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan   = require("ui/widget/verticalspan")
    local ChipButton     = require("lib/bookshelf_chip_button")
    local font_size = (modal and modal.font_size) or 20
    local inset = (modal and modal._side_pad) or Screen:scaleBySize(28)
    local content_w = avail_w - 2 * inset

    -- Same read-only star glyphs as the Edit tab's Hardcover rating row, but
    -- sized to match the per-review stars below (REVIEW_CSS's ".stars"
    -- rule, "font-size: 1.15em" of the HTML body's base size) rather than
    -- the Edit tab's own "+4" -- the two rows sit one above the other here,
    -- so a size mismatch reads as inconsistent glyph weight.
    local STAR_FULL, STAR_HALF, STAR_EMPTY = "\xEF\x80\x85", "\xEF\x84\xA3", "\xEF\x80\x86"
    local star_face = BFont:getFace("symbols", font_size * 1.15)
    local text_face = BFont:getFace("cfont", font_size)

    local left = HorizontalGroup:new{ align = "center" }
    local data = tab.data
    local rating = data and tonumber(data.rating)
    if rating and rating > 0 then
        local halves = math.floor(rating * 2 + 0.5)  -- 0..10 half-units
        for i = 1, 5 do
            local glyph = STAR_EMPTY
            if halves >= 2 * i then glyph = STAR_FULL
            elseif halves == 2 * i - 1 then glyph = STAR_HALF end
            -- No per-star padding here (unlike the Edit tab's tappable "Your
            -- rating" stars, which need the extra gap as a bigger touch
            -- target) -- read-only, so they sit flush like the per-review
            -- star rows in the HTML below.
            left[#left + 1] = TextWidget:new{
                text = glyph, face = star_face, fgcolor = Blitbuffer.COLOR_BLACK }
        end
        left[#left + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(6) }
        left[#left + 1] = TextWidget:new{
            text = string.format("%.1f", rating), face = text_face, fgcolor = Blitbuffer.COLOR_BLACK }
    end
    local function addStat(text)
        if #left > 0 then
            left[#left + 1] = TextWidget:new{
                text = "  \xC2\xB7  ", face = text_face, fgcolor = Blitbuffer.COLOR_BLACK }
        end
        left[#left + 1] = TextWidget:new{ text = text, face = text_face, fgcolor = Blitbuffer.COLOR_BLACK }
    end
    if data and tonumber(data.ratings_count) and tonumber(data.ratings_count) > 0 then
        addStat(string.format(_("%d ratings"), tonumber(data.ratings_count)))
    end
    if data and tonumber(data.reviews_count) and tonumber(data.reviews_count) > 0 then
        addStat(string.format(_("%d reviews"), tonumber(data.reviews_count)))
    end

    -- Refresh chip: sized to the summary text's own line height so it reads as
    -- part of the same line, pixel-inverted while a fetch is in flight. The
    -- reload glyph is a Nerd Font PUA icon (nf-md-reload, U+EB52) rendered
    -- through the bundled "symbols" face -- a plain circular arrow, cleaner
    -- at this size than the stock document+arrow SVG icon.
    local probe = TextWidget:new{ text = "Hg", face = text_face }
    local text_h = probe:getSize().h
    local refresh_btn = ChipButton.build{
        text       = _("Refresh"),
        face       = text_face,
        icon_glyph = "\xEE\xAD\x92",
        icon_face  = BFont:getFace("symbols", font_size),
        icon_after = true,
        height     = text_h + 2 * Screen:scaleBySize(5),
        inverted   = tab.busy or false,
        on_tap     = function() if not tab.busy then refreshReviews() end end,
    }

    local left_w, right_w = left:getSize().w, refresh_btn:getSize().w
    local gap = Screen:scaleBySize(10)
    local row
    if left_w > 0 and left_w + gap + right_w <= content_w then
        row = HorizontalGroup:new{ align = "center",
            left, HorizontalSpan:new{ width = content_w - left_w - right_w }, refresh_btn }
    elseif left_w > 0 then
        -- Doesn't fit side by side (narrow screen / large zoom) -- stack.
        row = VerticalGroup:new{ align = "left",
            left, VerticalSpan:new{ width = Screen:scaleBySize(6) }, refresh_btn }
    else
        -- No rating data yet (still loading) -- just the button, flush right
        -- where it'll end up once the summary text appears.
        row = HorizontalGroup:new{ align = "center",
            HorizontalSpan:new{ width = math.max(0, content_w - right_w) }, refresh_btn }
    end

    return FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = inset, padding_right = inset,
        padding_top = Screen:scaleBySize(10), padding_bottom = Screen:scaleBySize(10),
        row,
    }
end

-- _buildReviewsTab: the Reviews tab's body -- the native header above, then
-- the review-list HTML in its own scroller sized to whatever height the
-- header leaves. A dedicated ScrollHtmlWidget rather than the modal's shared
-- one, so this tab's own native header can sit above it without disturbing
-- the shared scroller's fixed height used by the other (headerless) HTML tabs.
function BookshelfWidget:_buildReviewsTab(tab, modal, avail_w, avail_h, refreshReviews)
    local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
    local LineWidget = require("ui/widget/linewidget")
    local header = self:_buildReviewsHeader(tab, modal, avail_w, refreshReviews)
    local header_h = header:getSize().h
    -- Hairline marking the top of the scrollable area -- now that Refresh has
    -- moved out of the HTML, the gap between the native header and the review
    -- list read as ambiguous whitespace without a line to define the boundary.
    local hairline = LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen = Geom:new{ w = avail_w, h = Size.line.medium },
    }
    local hairline_h = hairline:getSize().h
    -- Most of the shared body top padding is now redundant -- the header and
    -- hairline already supply a gap above the first review -- so shrink it to
    -- a small residual rather than dropping it to 0 (_buildSourcedBody's
    -- padding-top override, same technique).
    local css = modal._css .. string.format("\nbody { padding-top: %dpx; }", Screen:scaleBySize(8))
    local scroller = ScrollHtmlWidget:new{
        html_body         = tab.html or "<p></p>",
        css               = css,
        default_font_size = Screen:scaleBySize((modal and modal.font_size) or 20),
        width             = avail_w,
        height            = math.max(Screen:scaleBySize(80), avail_h - header_h - hairline_h),
        dialog            = modal,
    }
    return VerticalGroup:new{ align = "left", header, hairline, scroller }
end

-- _showBookDetail(book, opts) — the combined book-detail popup, a tabbed window:
-- the book/Hardcover Description tab(s), a Hardcover Reviews tab when linked,
-- a Tags tab (all the author / series / collections / genres / folder pills,
-- tappable to drill in), and an Edit tab (the book actions, immediate-commit
-- -- replaces the long-press ButtonDialog menu) LAST, since it's reached for
-- less often than the others. One tab body is mounted at a time, so the
-- native scrollers never fight each other. Replaces the separate description
-- / reviews modals and the standalone tags sheet.
-- opts.active = "edit" | "tags" | "reviews" picks the starting tab (default:
-- description, else Edit); opts.on_close fires once on dismiss.
function BookshelfWidget:_showBookDetail(book, opts)
    opts = opts or {}
    if not book or not book.filepath then return end
    local ReadCollection = require("readcollection")
    local in_collections = ReadCollection.getCollectionsWithFile
        and ReadCollection:getCollectionsWithFile(book.filepath) or {}
    -- All categories (like the long-press menu); close_cb nil -- we close the
    -- popup explicitly so the drilldown tears the stack down before navigating.
    local pill_specs = self:_buildPillSpecs(book, in_collections, nil, nil)

    local modal  -- forward ref so a pill tap closes the popup before navigating

    -- Genre-source switching (Tags tab, Embedded/Hardcover chips) is cheap to
    -- preview live -- just a persisted preference write + a local pill-list
    -- swap -- but the shelf-wide consequences (which genre set this book
    -- contributes to elsewhere: the shelves it appears on, its hero tags)
    -- require invalidating the shared light-meta cache and a full shelf
    -- _rebuild. [bookshelf perf] logging showed that pair costing ~600-900ms,
    -- ~90% of a chip tap, entirely behind this modal while the user is just
    -- previewing sources. Deferred to modal close (Close or Open both route
    -- through onClose), and only paid if the source actually ended up
    -- different from what it was when the modal opened.
    local genre_source_at_open, genre_source_changed

    local tabs = {}
    local edit_idx, tags_idx, desc_idx, reviews_idx

    -- Edit tab spec: the book actions (the old long-press menu), immediate-
    -- commit, scrollable. show_parent is the live modal instance during
    -- build. Placed into `tabs` LAST (after Description/Reviews/Tags below)
    -- so it renders as the final tab, not the first.
    local edit_tab = {
        id = "edit",
        label = _("Edit"),
        -- The Edit body starts with a black heading strip, so the active tab's
        -- open-bottom should stay black (not erase to white) to avoid a notch.
        dark_body = true,
        widget_builder = function(avail_w, avail_h, show_parent)
            return self:_buildBookEditTab(book, show_parent, avail_w, avail_h)
        end,
    }

    -- Tags tab (appended LAST, after description + reviews): the pill set split
    -- into sections under the same black heading bars as the Edit tab (Author /
    -- Series / Collections / Genres / Folder), scrollable, each pill tappable
    -- (closes the popup then drills). Built lazily as a native widget body.
    local TAG_SECTIONS = {
        { cat = "author",      title = _("Author(s)") },
        { cat = "series",      title = _("Series") },
        { cat = "collections", title = _("Collections") },
        { cat = "genres",      title = _("Genres") },
        { cat = "folder",      title = _("Folder") },
    }
    local tags_tab
    if #pill_specs > 0 then
        tags_tab = {
            id = "tags",
            label = _("Tags"),
            -- Starts with a black heading strip, like the Edit tab, so keep the
            -- active tab's open-bottom black (no white notch).
            dark_body = true,
            widget_builder = function(avail_w, avail_h, show_parent)
                local FrameContainer = require("ui/widget/container/framecontainer")
                local LineWidget = require("ui/widget/linewidget")
                local ChipButton = require("lib/bookshelf_chip_button")
                local HorizontalSpan = require("ui/widget/horizontalspan")
                -- Group the specs by category, wrapping each tap to close first.
                local by_cat = {}
                for _i, s in ipairs(pill_specs) do
                    local cat  = s.cat or "folder"
                    local orig = s.on_tap
                    by_cat[cat] = by_cat[cat] or {}
                    by_cat[cat][#by_cat[cat] + 1] = {
                        label  = s.label,
                        on_tap = orig and function()
                            if modal then UIManager:close(modal) end
                            orig()
                        end or nil,
                    }
                end
                local lpad  = (show_parent and show_parent._side_pad)
                    or Screen:scaleBySize(20)
                local bar_w = Screen:scaleBySize(3)   -- flush snug scrollbar
                local base  = (show_parent and show_parent.font_size) or 18
                local pills_w   = avail_w - 2 * lpad - bar_w
                -- Every section's focusable row(s), in visual top-to-bottom
                -- order -- pillsFrame/editActionRow below register into this
                -- as they're called, so each section's own call site doesn't
                -- need to change. See ReviewsModal:_assemble's handling of an
                -- ARRAY focus_tables (bookshelf_reviews_modal.lua).
                local focus_tables = {}
                local function pillsFrame(specs)
                    local pills, focus_rows = self:_buildPillGroup(specs, pills_w, 9999, base, "left",
                        Screen:scaleBySize(8))
                    if focus_rows and #focus_rows > 0 then
                        focus_tables[#focus_tables + 1] = focusRow(focus_rows)
                    end
                    return FrameContainer:new{
                        bordersize = 0, margin = 0,
                        padding_left = lpad, padding_right = lpad,
                        padding_top = Screen:scaleBySize(10),
                        -- Section heading bars have no top margin of their own
                        -- (self:_sectionHeadingBar) -- this is the only gap
                        -- between one section's pills and the next heading, so
                        -- it's a bit larger than the pill row's own top pad.
                        padding_bottom = Screen:scaleBySize(20),
                        pills,
                    }
                end
                -- A full-width hairline then a left-aligned "Edit" button
                -- (same ChipButton style as the Reviews tab's Refresh) below
                -- an editable section's pills -- replaces the earlier inline
                -- "Edit…" link pill, which read as just another tag rather
                -- than a distinct action. An optional help/empty-state
                -- message (e.g. "Not in any collection.") sits inline to the
                -- button's right, in the same row, instead of its own line.
                local function editActionRow(on_tap, msg)
                    local edit_face = BFont:getFace("cfont", base)
                    local probe = TextWidget:new{ text = "Hg", face = edit_face }
                    local text_h = probe:getSize().h
                    local hairline = LineWidget:new{
                        background = Blitbuffer.COLOR_DARK_GRAY,
                        dimen = Geom:new{ w = avail_w, h = Size.line.medium },
                    }
                    local btn = ChipButton.build{
                        text      = _("Edit"),
                        face      = edit_face,
                        icon      = "edit",
                        icon_size = text_h,
                        height    = text_h + 2 * Screen:scaleBySize(5),
                        on_tap    = on_tap,
                    }
                    focus_tables[#focus_tables + 1] = focusRow({ { btn } })
                    local row = btn
                    if msg and msg ~= "" then
                        local gap = Screen:scaleBySize(12)
                        local msg_w = math.max(Screen:scaleBySize(40),
                            pills_w - btn:getSize().w - gap)
                        row = HorizontalGroup:new{ align = "center",
                            btn,
                            HorizontalSpan:new{ width = gap },
                            TextBoxWidget:new{ text = msg,
                                face = BFont:getFace("cfont", math.max(10, base - 2)),
                                fgcolor = Blitbuffer.COLOR_DARK_GRAY, width = msg_w },
                        }
                    end
                    return VerticalGroup:new{ align = "left",
                        hairline,
                        FrameContainer:new{
                            bordersize = 0, margin = 0,
                            padding_left = lpad, padding_right = lpad,
                            padding_top = Screen:scaleBySize(10),
                            padding_bottom = Screen:scaleBySize(20),
                            row,
                        },
                    }
                end
                local vg = VerticalGroup:new{ align = "left" }
                for _s = 1, #TAG_SECTIONS do
                    local sec = TAG_SECTIONS[_s]
                    if sec.cat == "genres" then
                        -- Genres are special: a source chip bar (Embedded /
                        -- Calibre / Hardcover) over the SELECTED source's genres.
                        -- Picking a source persists a per-book preference and
                        -- re-resolves genres app-wide.
                        local srcs = book.genre_sources or {}
                        local function has(k) return type(srcs[k]) == "table" and #srcs[k] > 0 end
                        if has("calibre") or has("embedded") or has("hardcover") then
                            local pref = BookshelfSettings.genreSource
                                and BookshelfSettings.genreSource(book.filepath)
                            local active = (pref and (has(pref) or pref == "embedded") and pref)
                                or (has("hardcover") and "hardcover")
                                or (has("calibre")  and "calibre")
                                or "embedded"
                            -- Captured once: the widget_builder re-runs on every
                            -- modal:rebuildTab() (each chip tap), so `active` itself
                            -- already reflects the latest pick by the second run --
                            -- genre_source_at_open must only ever be set from the
                            -- FIRST run to stay a true "at open" baseline.
                            if genre_source_at_open == nil then
                                genre_source_at_open = active
                            end
                            vg[#vg + 1] = self:_sectionHeadingBar(sec.title, avail_w, base, lpad)
                            -- Embedded is always offered (it's the editable source);
                            -- Calibre / Hardcover only when that source has genres.
                            local SRC = {
                                { key = "embedded",  label = _("Embedded") },
                                { key = "calibre",   label = _("Calibre") },
                                { key = "hardcover", label = _("Hardcover") },
                            }
                            local items = {}
                            for _j = 1, #SRC do
                                if SRC[_j].key == "embedded" or has(SRC[_j].key) then
                                    items[#items + 1] = SRC[_j]
                                end
                            end
                            -- Pills for the active source's genres. When Embedded
                            -- is active they're editable: long-press removes a tag
                            -- and a trailing "+ Add" pill prompts for a new one.
                            -- Edits go to the shared KOReader Keywords override.
                            local editable = (active == "embedded")
                            -- Its own row above the pills, for every source --
                            -- editable and read-only sources share the same
                            -- pill-row shape below; only whether an Edit… link
                            -- pill gets appended to it differs.
                            local source_chips
                            if #items > 1 then
                                local chips_focus_rows
                                source_chips, chips_focus_rows = self:_segmentedChips(items, active, function(key)
                                    -- The expensive part (light-meta invalidation + a full
                                    -- shelf _rebuild -- confirmed via [bookshelf perf] logging
                                    -- to cost ~600-900ms, ~90% of a tap) is deferred to modal
                                    -- close; see genre_source_changed above. Only the cheap,
                                    -- per-book/per-chip caches refresh immediately so the Tags
                                    -- tab itself updates fast.
                                    BookshelfSettings.setGenreSource(book.filepath, key)
                                    Repo.invalidateBookCache("genre-source")
                                    genre_source_changed = (key ~= genre_source_at_open)
                                    if modal and modal.rebuildTab then modal:rebuildTab() end
                                end, base, lpad)
                                focus_tables[#focus_tables + 1] = focusRow(chips_focus_rows)
                            end
                            local function applyEdit(new_list)
                                Repo.setEmbeddedGenres(book.filepath, new_list)
                                book.genre_sources = book.genre_sources or {}
                                book.genre_sources.embedded = new_list
                                if active == "embedded" then
                                    book.genres = (#new_list > 0) and new_list or nil
                                end
                                self:_rebuild(); UIManager:setDirty(self, "ui")
                                if modal and modal.rebuildTab then modal:rebuildTab() end
                            end
                            local function withoutGenre(gname)
                                local new = {}
                                for _g2 = 1, #(srcs[active] or {}) do
                                    if srcs[active][_g2] ~= gname then new[#new + 1] = srcs[active][_g2] end
                                end
                                return new
                            end
                            local function addOne(name)
                                name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
                                if name == "" then return end
                                local new = {}
                                local dup = false
                                for _g2 = 1, #(srcs[active] or {}) do
                                    new[#new + 1] = srcs[active][_g2]
                                    if srcs[active][_g2]:lower() == name:lower() then dup = true end
                                end
                                if not dup then new[#new + 1] = name end
                                applyEdit(new)
                            end
                            local function newTagDialog()
                                local InputDialog = require("ui/widget/inputdialog")
                                local idlg
                                idlg = InputDialog:new{
                                    title = _("New tag"), input = "",
                                    buttons = {{
                                        { text = _("Cancel"), id = "close",
                                          callback = function() UIManager:close(idlg) end },
                                        { text = _("Add"), is_enter_default = true,
                                          callback = function()
                                            local v = idlg:getInputText()
                                            UIManager:close(idlg); addOne(v)
                                          end },
                                    }},
                                }
                                UIManager:show(idlg)
                                idlg:onShowKeyboard()
                            end
                            -- Multi-select editor (mirrors the collections "Edit…"
                            -- model): the library's genre list UNION the book's
                            -- current tags, shown in the searchable grid picker
                            -- with the current tags pre-selected (inverted cells).
                            -- Tap toggles a cell, "New tag…" adds a novel one to
                            -- the selection, "Apply" commits the whole set in one
                            -- write. Falls back to free-text add if the modal
                            -- can't load.
                            local function editGenres()
                                local ok_lm, LibraryModal = pcall(require, "lib/bookshelf_library_modal")
                                if not (ok_lm and LibraryModal and LibraryModal.new) then
                                    newTagDialog(); return
                                end
                                local current = srcs[active] or {}
                                -- selection set: lowercase key -> canonical value.
                                local sel = {}
                                for _i = 1, #current do sel[current[_i]:lower()] = current[_i] end
                                -- candidates = current tags + library genres, deduped.
                                local choices, seen = {}, {}
                                local function addChoice(value, count)
                                    if not value or value == "" then return end
                                    local k = value:lower()
                                    if seen[k] then return end
                                    seen[k] = true
                                    choices[#choices + 1] = { value = value, label = value, count = count }
                                end
                                for _i = 1, #current do addChoice(current[_i]) end
                                local all = Repo.getGroupChoices and Repo.getGroupChoices("genre") or {}
                                for _i = 1, #all do addChoice(all[_i].value, all[_i].count) end
                                local function sortChoices()
                                    table.sort(choices, function(a, b)
                                        return (a.label or ""):lower() < (b.label or ""):lower() end)
                                end
                                sortChoices()
                                local query, visible = nil, choices
                                local function recompute()
                                    if not query or query == "" then visible = choices; return end
                                    visible = {}
                                    for _i = 1, #choices do
                                        if (choices[_i].label or ""):lower():find(query:lower(), 1, true) then
                                            visible[#visible + 1] = choices[_i]
                                        end
                                    end
                                end
                                local modal2
                                local function commit()
                                    -- Retained current tags keep their order; newly
                                    -- selected ones append in (sorted) candidate order.
                                    local final, kept = {}, {}
                                    for _i = 1, #current do
                                        local k = current[_i]:lower()
                                        if sel[k] then final[#final + 1] = current[_i]; kept[k] = true end
                                    end
                                    for _i = 1, #choices do
                                        local v = choices[_i].value
                                        if sel[v:lower()] and not kept[v:lower()] then
                                            final[#final + 1] = v; kept[v:lower()] = true
                                        end
                                    end
                                    UIManager:close(modal2)
                                    applyEdit(final)
                                end
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
                                                local v = (idlg:getInputText() or "")
                                                    :gsub("^%s+", ""):gsub("%s+$", "")
                                                UIManager:close(idlg)
                                                if v ~= "" then
                                                    addChoice(v); sel[v:lower()] = v
                                                    sortChoices(); recompute()
                                                    if modal2 then modal2.page = 1; modal2:refresh() end
                                                end
                                              end },
                                        }},
                                    }
                                    UIManager:show(idlg)
                                    idlg:onShowKeyboard()
                                end
                                modal2 = LibraryModal:new{ config = {
                                    title = _("Edit tags"),
                                    search_placeholder = function() return _("Search\xE2\x80\xA6") end,
                                    on_search_submit = function(q)
                                        query = q; recompute()
                                        if modal2 then modal2.page = 1; modal2:refresh() end
                                    end,
                                    grid_cols = 2,
                                    cells_per_page = function()
                                        return Screen:getWidth() > Screen:getHeight() and 8 or 10
                                    end,
                                    item_count = function() return #visible end,
                                    item_at = function(idx) return visible[idx] end,
                                    cell_renderer = function(item, dimen)
                                        return require("lib/bookshelf_picker_cell").render(item, dimen,
                                            { selected = sel[(item.value or ""):lower()] ~= nil })
                                    end,
                                    on_cell_tap = function(item)
                                        local k = (item.value or ""):lower()
                                        if sel[k] then sel[k] = nil else sel[k] = item.value end
                                        if modal2 then modal2:refresh() end
                                    end,
                                    -- Same bottom layout as the collection editor:
                                    -- a full-width "+ New tag" above a Cancel/Save pair.
                                    footer_rows = {
                                        { { label = "+ " .. _("New tag"), on_tap = promptNewTag } },
                                        {
                                            { label = _("Cancel"),
                                              on_tap = function() UIManager:close(modal2) end },
                                            { label = _("Save"), primary = true, on_tap = commit },
                                        },
                                    },
                                } }
                                -- Cancel closes modal2 without ever calling applyEdit, so
                                -- nothing else clears the "Edit…" pill's tap-feedback invert
                                -- left over from opening this modal -- rebuild unconditionally
                                -- on any close (mirrors the collection editor's on_close),
                                -- not just the Save path.
                                local orig_on_close_widget = modal2.onCloseWidget
                                modal2.onCloseWidget = function(w)
                                    orig_on_close_widget(w)
                                    self:_rebuild(); UIManager:setDirty(self, "ui")
                                    if modal and modal.rebuildTab then modal:rebuildTab() end
                                end
                                UIManager:show(modal2)
                            end
                            -- Pin this genre as a nav chip (global -- surfaces
                            -- every book with the genre), mirroring the collection
                            -- "Pin to chip bar". Splices the chip after the current
                            -- one and switches to it, like the stack-hold pin.
                            local function pinGenreChip(gname)
                                local TabModel = require("lib/bookshelf_tab_model")
                                local tabs = TabModel.load()
                                local n = 1
                                while true do
                                    local cand, taken = "custom_" .. n, false
                                    for _i = 1, #tabs do
                                        if tabs[_i].id == cand then taken = true; break end
                                    end
                                    if not taken then break end
                                    n = n + 1
                                end
                                local new_id = "custom_" .. n
                                TabModel.insertAfter(tabs, self.chip, {
                                    id = new_id, label = gname, icon = nil,
                                    source = { kind = "genre", id = gname },
                                    filter = {},
                                    -- Most-recently-opened first (same default as
                                    -- a pinned collection chip), not the Genres
                                    -- tab's surname/series ordering.
                                    sort_priority = { { key = "last_opened", reverse = true } },
                                    enabled = true,
                                })
                                TabModel.save(tabs)
                                if modal then UIManager:close(modal) end
                                self:_clearDpadFocus()
                                self._drilldown_path = {}
                                self.chip = new_id
                                self._cursor = 1
                                self:_syncPageFromCursor()
                                BookshelfSettings.saveDeferred("active_chip", new_id)
                                Repo.invalidateBookCache("create-chip")
                                self:_rebuild(); UIManager:setDirty(self, "ui")
                            end
                            -- Rename this book's copy of the tag (per-book: edits
                            -- the Embedded keywords -- genres aren't a global entity
                            -- to rename across books). Replaces in place; a rename
                            -- onto an existing tag just collapses into it.
                            local function renameTag(gname)
                                local InputDialog = require("ui/widget/inputdialog")
                                local idlg
                                idlg = InputDialog:new{
                                    title = _("Rename tag"), input = gname,
                                    input_hint = _("New name"),
                                    buttons = {{
                                        { text = _("Cancel"), id = "close",
                                          callback = function() UIManager:close(idlg) end },
                                        { text = _("Rename"), is_enter_default = true,
                                          callback = function()
                                            local newn = (idlg:getInputText() or "")
                                                :gsub("^%s+", ""):gsub("%s+$", "")
                                            UIManager:close(idlg)
                                            if newn == "" or newn == gname then return end
                                            local new, seen = {}, {}
                                            for _g2 = 1, #(srcs[active] or {}) do
                                                local g = srcs[active][_g2]
                                                local v = (g == gname) and newn or g
                                                if not seen[v:lower()] then
                                                    new[#new + 1] = v; seen[v:lower()] = true
                                                end
                                            end
                                            applyEdit(new)
                                          end },
                                    }},
                                }
                                UIManager:show(idlg)
                                idlg:onShowKeyboard()
                            end
                            -- Long-press menu, mirroring the collection editor's
                            -- hold menu. Editable (Embedded) source gets the full
                            -- 2x2 (Rename / Pin / Delete / Cancel); read-only
                            -- sources get Pin / Cancel only.
                            local function holdMenu(gname)
                                local ButtonDialog = require("ui/widget/buttondialog")
                                local hold_dialog
                                local function hclose() UIManager:close(hold_dialog) end
                                local function doDelete()
                                    hclose()
                                    local ConfirmBox = require("ui/widget/confirmbox")
                                    UIManager:show(ConfirmBox:new{
                                        text = T(_("Remove the tag \"%1\" from this book?"), gname),
                                        ok_text = _("Remove"),
                                        ok_callback = function() applyEdit(withoutGenre(gname)) end,
                                    })
                                end
                                local buttons
                                if editable then
                                    buttons = {
                                        { { text = _("Rename"),
                                            callback = function() hclose(); renameTag(gname) end },
                                          { text = _("Pin to chip bar"),
                                            callback = function() hclose(); pinGenreChip(gname) end } },
                                        { { text = "\xE2\x9C\x95 " .. _("Delete"), callback = doDelete },
                                          { text = _("Cancel"), callback = hclose } },
                                    }
                                else
                                    buttons = {
                                        { { text = _("Pin to chip bar"),
                                            callback = function() hclose(); pinGenreChip(gname) end },
                                          { text = _("Cancel"), callback = hclose } },
                                    }
                                end
                                hold_dialog = ButtonDialog:new{
                                    title = _("Edit tag: ") .. gname,
                                    title_align = "center",
                                    use_info_style = false,
                                    width = math.floor(Screen:getWidth() * 0.7),
                                    buttons = buttons,
                                }
                                UIManager:show(hold_dialog)
                            end
                            local gpills = {}
                            for _g = 1, #(srcs[active] or {}) do
                                local gname = srcs[active][_g]
                                gpills[#gpills + 1] = {
                                    label  = gname,
                                    on_tap = function()
                                        if modal then UIManager:close(modal) end
                                        local group = Repo.findGroup("genre", gname)
                                            or { kind = "genre", series_name = gname,
                                                 books = { book }, latest = 0 }
                                        self._drilldown_path = {}
                                        self:_expandGenre(group)
                                    end,
                                    on_hold = function() holdMenu(gname) end,
                                }
                            end
                            if source_chips then vg[#vg + 1] = source_chips end
                            if #gpills > 0 then vg[#vg + 1] = pillsFrame(gpills) end
                            -- Editable (Embedded) source: the help line sits
                            -- inline with the Edit button's hairline row, not
                            -- another pill or its own line. Read-only sources
                            -- (Calibre/Hardcover) get no edit action, so an
                            -- empty-source message (if any) stays on its own
                            -- line -- there's no button row to pair it with.
                            if editable then
                                local msg = (#(srcs[active] or {}) > 0)
                                    and _("Long-press a tag for options.")
                                    or _("This book has no embedded tags.")
                                vg[#vg + 1] = editActionRow(editGenres, msg)
                            elseif #gpills == 0 then
                                vg[#vg + 1] = FrameContainer:new{
                                    bordersize = 0, margin = 0,
                                    padding_left = lpad, padding_right = lpad,
                                    padding_top = Screen:scaleBySize(2),
                                    padding_bottom = Screen:scaleBySize(20),
                                    TextBoxWidget:new{ text = _("No tags from this source."),
                                        face = BFont:getFace("cfont", math.max(10, base - 2)),
                                        fgcolor = Blitbuffer.COLOR_DARK_GRAY, width = pills_w },
                                }
                            end
                        end
                    elseif sec.cat == "collections" then
                        -- Collections: the per-collection drill-in pills, then
                        -- a hairline + Edit button opening the collection
                        -- manager. Always shown (even with no memberships) so
                        -- the manager is reachable here -- this is the single
                        -- place collections are surfaced (the Edit tab no
                        -- longer duplicates them).
                        local specs = by_cat[sec.cat]
                        vg[#vg + 1] = self:_sectionHeadingBar(sec.title, avail_w, base, lpad)
                        local function editCollections()
                            -- Leave the everything-modal OPEN behind the
                            -- collection dialog (no_header drops its
                            -- redundant book header). On close, refresh the
                            -- membership in place: reassign the captured
                            -- pill_specs upvalue and rebuild the Tags tab
                            -- body (which re-reads it), so no flash from
                            -- closing/reopening the popup.
                            require("lib/bookshelf_collection_manager").show{
                                book = book, bw = self, no_header = true,
                                on_close = function()
                                    local rc = require("readcollection")
                                    in_collections = (rc.getCollectionsWithFile
                                        and rc:getCollectionsWithFile(book.filepath)) or {}
                                    pill_specs = self:_buildPillSpecs(book, in_collections, nil, nil)
                                    self:_rebuild(); UIManager:setDirty(self, "ui")
                                    if modal and modal.rebuildTab then modal:rebuildTab() end
                                end }
                        end
                        -- Empty state sits inline with the Edit button's
                        -- hairline row rather than its own line above it.
                        local collections_msg
                        if specs and #specs > 0 then
                            vg[#vg + 1] = pillsFrame(specs)
                        else
                            collections_msg = _("Not in any collection.")
                        end
                        vg[#vg + 1] = editActionRow(editCollections, collections_msg)
                    else
                        local specs = by_cat[sec.cat]
                        if specs and #specs > 0 then
                            vg[#vg + 1] = self:_sectionHeadingBar(sec.title, avail_w, base, lpad)
                            vg[#vg + 1] = pillsFrame(specs)
                        end
                    end
                end
                local scroll = SnugScroll:new{
                    dimen = Geom:new{ w = avail_w, h = avail_h },
                    scroll_bar_width = bar_w,
                    show_parent = show_parent,
                    vg,
                }
                scroll.focus_tables = focus_tables
                return scroll
            end,
        }
    end

    -- 2. Description tab. When both the embedded and Hardcover descriptions
    -- exist, the single tab carries both as toggleable "sources" (an
    -- Embedded/Hardcover chip bar inside it) instead of a second top-level
    -- Hardcover tab -- making it obvious both are descriptions and keeping the
    -- tab strip short. The chosen source persists on close (on_source_close).
    local desc_args = self:_descriptionArgs(book) or {}
    if desc_args.tabs then
        desc_idx = #tabs + 1
        tabs[desc_idx] = {
            id = "description", label = _("Description"),
            sources = {
                { label = desc_args.tabs[1].label, html = desc_args.tabs[1].html },
                { label = desc_args.tabs[2].label, html = desc_args.tabs[2].html },
            },
            active_source   = desc_args.active_tab or 1,
            on_source_close = desc_args.on_tab_close,
        }
    elseif desc_args.html_body then
        desc_idx = #tabs + 1
        tabs[desc_idx] = { id = "description", label = _("Description"),
            html = desc_args.html_body }
    end

    -- 3. Hardcover reviews tab, only when linked. Cache-first so the common case
    -- shows instantly; otherwise a "Loading" placeholder an async fetch fills in.
    local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
    local Tokens = require("lib/bookshelf_tokens")
    local link = ok_hc and Hardcover and Hardcover.getLink
        and Hardcover.getLink(book.filepath) or nil
    local book_id = book.hardcover_book_id or (link and link.book_id)
    local has_reviews = (ok_hc and Hardcover and book_id) and true or false
    -- No title: the popup header already shows the book title/author. The
    -- rating/counts summary is a native row (_buildReviewsHeader), not part
    -- of this HTML -- only the review list itself renders here.
    local function reviewsListHtml(result)
        return Tokens.reviewsHtml{ reviews = result and result.reviews }
    end
    local reviews_pending
    local reviews_tab  -- forward ref: refreshReviews mutates it, its
                        -- widget_builder (below) reads it back each rebuild.
    -- Named so both the initial cache-miss load and the header's Refresh
    -- button can trigger the same re-fetch; `modal` is assigned after this
    -- closure is created but before either caller can actually invoke it
    -- (upvalue, read at call time).
    local function refreshReviews()
        if not reviews_tab then return end
        reviews_tab.busy = true
        if modal and modal._active_tab == reviews_idx and modal.rebuildTab then
            modal:rebuildTab()
            -- fetchReviewsOnline's network call runs on this same thread with
            -- no yield back to UIManager's event loop, so the queued "busy"
            -- repaint would otherwise never actually hit the screen before it
            -- returns (KOReader only drains the paint queue between events).
            -- Force it now so the black-fill feedback is visible immediately.
            -- Same pre-paint pattern as the chip-strip's flashPending().
            UIManager:forceRePaint()
        end
        Hardcover.fetchReviewsOnline(book_id, {}, function(ok, result)
            if modal._dismissed then return end
            reviews_tab.busy = false
            if ok and type(result) == "table" then
                reviews_tab.data = result
                reviews_tab.html = reviewsListHtml(result)
            else
                reviews_tab.html = "<p>" .. _("Reviews couldn't be fetched.") .. "</p>"
            end
            if modal._active_tab == reviews_idx and modal.rebuildTab then
                modal:rebuildTab()
            end
        end)
    end
    if has_reviews then
        reviews_idx = #tabs + 1
        local data, html
        local ok_cached, cached = Hardcover.fetchReviews(book_id, { cache_only = true })
        if ok_cached and type(cached) == "table" then
            data = cached
            html = reviewsListHtml(cached)
        else
            html = "<p>" .. _("Loading reviews\xE2\x80\xA6") .. "</p>"
            reviews_pending = true
        end
        reviews_tab = {
            id = "reviews", label = _("Reviews"), data = data, html = html,
            widget_builder = function(avail_w, avail_h, show_parent)
                return self:_buildReviewsTab(reviews_tab, show_parent, avail_w, avail_h, refreshReviews)
            end,
        }
        tabs[reviews_idx] = reviews_tab
    end

    -- Tags next-to-last.
    if tags_tab then
        tags_idx = #tabs + 1
        tabs[tags_idx] = tags_tab
    end

    -- Edit last: the actions tab is reached for less often than Description/
    -- Reviews/Tags, so it sits at the end of the strip rather than hogging
    -- the first (default-focus) slot.
    edit_idx = #tabs + 1
    tabs[edit_idx] = edit_tab

    if #tabs == 0 then return end  -- no pills, no description, no reviews

    -- Active tab: edit / tags / reviews on request, else the description source
    -- the hero shows, else the Edit tab (always present).
    local active_tab
    if opts.active == "edit" and edit_idx then
        active_tab = edit_idx
    elseif opts.active == "tags" and tags_idx then
        active_tab = tags_idx
    elseif opts.active == "reviews" and reviews_idx then
        active_tab = reviews_idx
    elseif desc_idx then
        active_tab = desc_idx  -- the chip bar defaults to the hero's source
    else
        active_tab = edit_idx or 1
    end

    local args = {
        tabs       = tabs,
        active_tab = active_tab,
        -- Flush the deferred genre-source invalidation (see
        -- genre_source_changed above) before the caller's own on_close --
        -- ReviewsModal:onClose runs this for BOTH the Close button and the
        -- Open button (Open routes through onClose first), so the shelf is
        -- caught up whichever way the popup closes.
        on_close   = function()
            if genre_source_changed then
                Repo.invalidateLightMeta()
                self:_rebuild(); UIManager:setDirty(self, "ui")
            end
            if opts.on_close then opts.on_close() end
        end,
        -- "Open" footer button opens the book in the reader (the popup closes
        -- first via onClose). _openBook handles stale files + the Kobo path.
        on_open    = function() self:_openBook(book) end,
        -- Cover + metadata header in place of a title bar. Rebuilt fresh on each
        -- layout by the modal (cover bb is one-shot); no pills here (Tags tab),
        -- no bookmark button.
        header_builder = function(avail_w)
            return self:_buildBookMenuHeader(book, avail_w, nil, nil, { rich = true })
        end,
    }
    -- The description-source choice (Embedded vs Hardcover) now persists via the
    -- Description tab's on_source_close (fired by the modal on dismiss), so no
    -- top-level on_tab_close mapping is needed here.

    local ReviewsModal = require("lib/bookshelf_reviews_modal")
    modal = ReviewsModal:new(args)
    UIManager:show(modal)

    -- Cache miss: fetch reviews online, then drop them into the reviews tab in
    -- place. refreshReviews itself guards against the user closing the popup
    -- before it returns.
    if reviews_pending then
        refreshReviews()
    end
end

-- Hardcover reviews now live as a tab in the unified book-detail popup, so this
-- just opens that popup on the Reviews tab. opts.on_close reopens the caller
-- (e.g. the book menu) on dismiss.
function BookshelfWidget:_showHardcoverReviews(book, opts)
    opts = opts or {}
    self:_showBookDetail(book, { active = "reviews", on_close = opts.on_close })
end

function BookshelfWidget:_refreshHardcoverEnrichmentView(reason, filepath)
    Repo.invalidateBookCache(reason or "hardcover")
    -- A cover toggle / re-link changes the cover image; drop the per-filepath
    -- scaled bitmap (and progress memo) so the rebuild re-renders it. No
    -- BIM re-extract needed -- the render prefers cover_image_path directly.
    -- NOT a global image_source.invalidateCache() here: that re-decodes EVERY
    -- visible cover (measured ~1.7-2s refresh on a single toggle). The new
    -- cover is at a new path (or new mtime), so the path+mtime-keyed image
    -- cache misses for it anyway; only this book's scaled bitmap needs dropping.
    if filepath then
        pcall(function() require("lib/bookshelf_scaled_cover_cache"):drop(filepath) end)
        pcall(function()
            if Repo.invalidateProgressCache then Repo.invalidateProgressCache(filepath) end
        end)
    end
    -- Per-book cover / description toggles can't reorder the shelf or change
    -- chip membership (cover_image_path and description aren't sort keys),
    -- so the whole _rebuild -- fetch + sort + assemble, ~450ms on the All
    -- chip -- is wasted on a one-book change. Refresh just the affected
    -- spine in place, plus the hero when this is the previewed book, and
    -- skip the rebuild. Falls through to _rebuild when the in-place path
    -- can't reach the book (off the current page, expanded layout, cold
    -- tree) or for any other reason (re-link / select-edition / metadata
    -- refresh -- those DO change sort keys and membership).
    local toggle_only = (reason == "hardcover-use-cover"
                         or reason == "hardcover-use-description")
    if toggle_only and filepath
            and self._inner_vgroup and self._shelf_dims
            and (self._shelf_dims.n_shelves or 2) == self:_nShelves() then
        local spine_done = self:_refreshSpineInPlace(filepath)
        local preview_fp = self._preview_book and self._preview_book.filepath
        local hero_done = false
        if preview_fp == filepath and not self._expanded then
            -- The toggled book is the one shown in the hero, so its cover /
            -- description there needs refreshing too. _swapHeroInPlace
            -- rebuilds from _preview_book (now reading fresh enrichment) and
            -- scopes its own setDirty to the hero rect.
            self:_swapHeroInPlace()
            hero_done = true
        end
        if spine_done or hero_done then
            return
        end
    end
    if self._rebuild then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
    end
end

function BookshelfWidget:_hardcoverToast(text, timeout)
    UIManager:show(require("ui/widget/notification"):new{
        text    = text,
        timeout = timeout or 3,
    })
end

function BookshelfWidget:_openHardcoverMenu(book)
    if not (book and book.filepath) then return end
    local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
    if not ok_hc or not Hardcover then
        self:_hardcoverToast(_("Hardcover integration could not be loaded"))
        return
    end

    local bw = self
    local link = Hardcover.getLink(book.filepath)
    local dialog

    -- Most actions here apply immediately and keep you in this menu (reopened,
    -- refreshed -- e.g. a successful link now shows the override toggles), so
    -- you can chain link + toggles. Only "Done" exits back to the book menu.
    local function returnToBookMenu()
        -- Back to the book-detail popup on its Edit tab (the long-press surface).
        UIManager:nextTick(function() bw:_showBookDetail(book, { active = "edit" }) end)
    end
    local function returnToHardcoverMenu()
        UIManager:nextTick(function() bw:_openHardcoverMenu(book) end)
    end

    -- closeThen: close this menu, run the action, then reopen THIS menu
    -- refreshed. Actions that open their own sub-dialog (the pickers) pass
    -- chains=true and reopen from that sub-dialog's completion callback.
    local function closeThen(fn, chains)
        return function()
            UIManager:close(dialog)
            UIManager:nextTick(function()
                if fn then fn() end
                if not chains then returnToHardcoverMenu() end
            end)
        end
    end

    local function refreshAfterAction(reason)
        -- Pass the filepath so the scaled-cover cache is dropped too: cover
        -- toggles / re-links change the cover, and a stale cached bitmap would
        -- otherwise keep showing the old one.
        bw:_refreshHardcoverEnrichmentView(reason or "hardcover-link", book.filepath)
    end

    local function refreshLinkedMetadata(success_text)
        Hardcover.refreshBookOnline(book, { force = true }, function(ok, err)
            refreshAfterAction("hardcover-refresh-one")
            if ok then
                bw:_hardcoverToast(success_text or _("Hardcover metadata refreshed"))
            else
                bw:_hardcoverToast(tostring(err or _("Hardcover refresh failed")), 5)
            end
        end)
    end

    -- Pick the auto-link mode up front from whether the book carries an
    -- embedded ISBN / Hardcover id (reads the EPUB OPF once; cached on the book
    -- + instant for non-EPUBs). With an id we resolve exactly; without one the
    -- button becomes a title+author best-guess search instead of a dead end.
    local has_embedded_id = Hardcover.getEmbeddedIdentifiers
        and Hardcover.getEmbeddedIdentifiers(book) ~= nil or false
    local embedded_button = {
        text = has_embedded_id and _("Auto link") or _("Auto link (best guess)"),
        callback = closeThen(function()
            if has_embedded_id then
                local ok, result = Hardcover.linkFromEmbeddedIdentifiers(book)
                if not ok then
                    bw:_hardcoverToast(tostring(result or _("No embedded Hardcover identifier found")), 5)
                    return
                end
                refreshLinkedMetadata(_("Hardcover book linked"))
            else
                -- No embedded id: search Hardcover by title + author and link
                -- the most confident match (the auto-link-all "Best guess").
                local ok, result = Hardcover.bestGuessLink(book)
                if not ok then
                    local msg = (result == "no_confident_match" or result == "no_match")
                        and _("No confident Hardcover match -- try Manual link")
                        or tostring(result or _("Hardcover search failed"))
                    bw:_hardcoverToast(msg, 5)
                    return
                end
                refreshLinkedMetadata(_("Hardcover book linked (best guess)"))
            end
        end),
    }
    -- (embedded_button is terminal: closeThen reopens the book menu for it.)

    local select_book_button = {
        text = _("Manual link") .. "\xE2\x80\xA6",
        callback = closeThen(function()
            -- on_close fires when the picker closes either way (cancel or
            -- selection), so the return to the book menu is handled there
            -- uniformly -- the per-result callbacks only show toasts / refresh.
            local ok, err = Hardcover.showBookPicker(book, {
                on_close = returnToHardcoverMenu,
                on_error = function(msg)
                    bw:_hardcoverToast(tostring(msg or _("Hardcover link failed")), 5)
                end,
                on_book_selected = function(_selected, ok_refresh, refresh_err)
                    refreshAfterAction("hardcover-select-book")
                    if ok_refresh == false then
                        bw:_hardcoverToast(T(_("Book linked, but metadata refresh failed: %1"),
                                             tostring(refresh_err)), 5)
                    else
                        bw:_hardcoverToast(_("Hardcover book linked"))
                    end
                end,
            })
            -- Picker failed to even open: no dialog, so on_close never fires --
            -- reopen the Hardcover menu now.
            if not ok then
                bw:_hardcoverToast(tostring(err or _("Hardcover search failed")), 5)
                returnToHardcoverMenu()
            end
        end, true),
    }

    local select_edition_button = {
        text = _("Select edition") .. "\xE2\x80\xA6",
        enabled = link and link.book_id and true or false,
        callback = closeThen(function()
            local current = Hardcover.getLink(book.filepath)
            if not current or not current.book_id then
                bw:_hardcoverToast(_("Link a Hardcover book first"))
                returnToHardcoverMenu()
                return
            end
            local ok, err = Hardcover.showEditionPicker(book, current.book_id, {
                on_close = returnToHardcoverMenu,
                on_error = function(msg)
                    bw:_hardcoverToast(tostring(msg or _("Hardcover link failed")), 5)
                end,
                on_edition_selected = function(_selected, ok_refresh, refresh_err)
                    refreshAfterAction("hardcover-select-edition")
                    if ok_refresh == false then
                        bw:_hardcoverToast(T(_("Edition linked, but metadata refresh failed: %1"),
                                             tostring(refresh_err)), 5)
                    else
                        bw:_hardcoverToast(_("Hardcover edition linked"))
                    end
                end,
            })
            if not ok then
                bw:_hardcoverToast(tostring(err or _("Hardcover edition search failed")), 5)
                returnToHardcoverMenu()
            end
        end, true),
    }

    local clear_button = {
        text = _("Clear link"),
        enabled = link and true or false,
        callback = closeThen(function()
            local ok, err = Hardcover.clearLink(book.filepath)
            refreshAfterAction("hardcover-clear-link")
            if ok then
                bw:_hardcoverToast(_("Hardcover link cleared"))
            else
                bw:_hardcoverToast(tostring(err or _("Could not clear Hardcover link")), 5)
            end
        end),
    }

    -- "Done", not "Cancel": every action here (link, toggles, clear) applies
    -- immediately, so there's nothing to cancel -- this just exits to the book
    -- menu.
    local done_button = {
        text = _("Done"),
        callback = function()
            UIManager:close(dialog)
            returnToBookMenu()
        end,
    }

    -- Per-book override toggles (only meaningful once linked). They flip the
    -- link record's use_cover / use_description flags in place and reinit the
    -- dialog so the checkbox updates without leaving the menu.
    local CHK_ON, CHK_OFF = "\xE2\x98\x91 ", "\xE2\x98\x90 "  -- ☑ / ☐
    local function flagOn(field)
        local f = Hardcover.getEnrichmentFlags and Hardcover.getEnrichmentFlags(book.filepath)
        return (f and f[field]) or false
    end
    local use_cover_button = {
        text_func = function()
            return (flagOn("use_cover") and CHK_ON or CHK_OFF) .. _("Use Hardcover image")
        end,
        -- Greyed out unless a Hardcover cover is actually downloaded for this
        -- book: with cover download off (issue #111), or for a book Hardcover
        -- has no cover for, there's nothing to apply.
        enabled_func = function()
            return (Hardcover.hasCover and Hardcover.hasCover(book.filepath)) or false
        end,
        callback = function()
            local ok, err = Hardcover.setUseCover(book.filepath, not flagOn("use_cover"))
            if not ok then bw:_hardcoverToast(tostring(err or _("Could not update")), 5) end
            -- Light refresh: the render now prefers cover_image_path directly
            -- (see SpineWidget._renderCover), so no BIM re-extract is needed.
            refreshAfterAction("hardcover-use-cover")
            -- reinit() rebuilds the button tree so the ☑/☐ text_func
            -- re-evaluates, but doesn't repaint itself. The full-screen
            -- _rebuild refresh used to redraw the dialog as a side effect;
            -- the in-place refresh path scopes its setDirty to the spine /
            -- hero rect, so repaint the dialog explicitly here.
            if dialog and dialog.reinit then
                Focus.reinit(dialog)
                UIManager:setDirty(dialog, "ui")
            end
        end,
    }
    local use_desc_button = {
        text_func = function()
            return (flagOn("use_description") and CHK_ON or CHK_OFF) .. _("Use Hardcover description")
        end,
        callback = function()
            Hardcover.setUseDescription(book.filepath, not flagOn("use_description"))
            refreshAfterAction("hardcover-use-description")
            -- See use_cover_button: reinit rebuilds the checkbox text but
            -- the scoped in-place refresh no longer repaints the dialog.
            if dialog and dialog.reinit then
                Focus.reinit(dialog)
                UIManager:setDirty(dialog, "ui")
            end
        end,
    }

    -- Reviews and Refresh metadata are intentionally NOT here: Reviews was
    -- promoted to the book long-press menu, and Refresh duplicated that
    -- menu's own "Refresh metadata" button.
    local linked_text = link
        and (T(_("Linked: %1"), Hardcover.linkLabel(book.filepath) or tostring(link.book_id)))
        or _("Not linked to Hardcover")
    local button_rows = { { { text = linked_text, enabled = false } } }
    if link and link.book_id then
        button_rows[#button_rows + 1] = { use_cover_button, use_desc_button }
    end
    button_rows[#button_rows + 1] = { embedded_button, select_book_button, select_edition_button }
    button_rows[#button_rows + 1] = { clear_button, done_button }
    dialog = require("ui/widget/buttondialog"):new{
        title   = _("Hardcover"),
        buttons = button_rows,
    }
    UIManager:show(dialog)
end

-- Button rows contributed by other plugins through KOReader's standard
-- long-press file-dialog hook (FileManager:addFileDialogButtons), so they appear
-- in bookshelf's book menu exactly as they would in the stock file browser
-- (issue #102). Returns a list of ButtonDialog rows, or nil when none apply.
--
-- Each row builder is called as it would be by FileManager:showFileDialog --
-- row_func(file, is_file=true, book_props) -- and pcall-guarded so a broken or
-- FM-context-assuming plugin button can never break bookshelf's menu. book_props
-- is built best-effort in KOReader's shape (via coverbrowser when present) so
-- metadata-dependent buttons render; metadata-independent ones (e.g. Incognito)
-- ignore it.
function BookshelfWidget:_fileDialogPluginRows(file)
    if not file then return nil end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return nil end
    local fm = FileManager.instance
    -- Instance first (plugins may register per-instance); fall back to the class
    -- field (incognito registers on the class, also reachable via the instance).
    local added = (fm and fm.file_dialog_added_buttons)
        or FileManager.file_dialog_added_buttons
    if type(added) ~= "table" or #added == 0 then return nil end

    -- Reverse the id->position index so we can skip whole registrations by id.
    -- coverbrowser is bookshelf's BIM provider; its long-press buttons (Ignore
    -- cover / Ignore metadata / Refresh cached book information) are redundant
    -- here -- bookshelf already integrates that metadata and has its own
    -- "Refresh metadata". Everything else still passes through generically.
    local id_at = {}
    if type(added.index) == "table" then
        for id, pos in pairs(added.index) do id_at[pos] = id end
    end

    local book_props
    pcall(function()
        if fm and fm.coverbrowser and fm.coverbrowser.getBookInfo then
            book_props = fm.coverbrowser:getBookInfo(file)
        end
    end)

    local rows = {}
    for _i = 1, #added do
        local id = id_at[_i]
        if not (type(id) == "string" and id:find("^coverbrowser")) then
            local ok, row = pcall(added[_i], file, true, book_props)
            if ok and type(row) == "table" and #row > 0 then
                rows[#rows + 1] = row
            end
        end
    end
    return (#rows > 0) and rows or nil
end

-- _openGroupMenu(group) -- long-press menu shared by folder cards and
-- every group-stack kind (series / author / genre / tag / format).
-- A regular tap already drills into the stack (handled by the
-- per-kind on_*_tap callbacks), so this menu only carries the
-- non-redundant action: "Create chip from this", which appends a new
-- TabModel entry pre-configured to surface the held group and
-- switches to it. Cancel below.
--
-- Per-kind data (source.kind written to the new chip, the field on
-- the group record that carries the identity name, default
-- sort_priority) lives in the GROUP_KINDS table so adding a new stack
-- type is a single entry.
local GROUP_KINDS = {
    folder = {
        source_kind     = "folder",
        -- folder id is the absolute path, not the visible label
        source_id_field = "path",
        -- chip-editor SOURCE_SORT_DEFAULTS["folder"]
        sort_priority   = { { key = "filename", reverse = false } },
    },
    series = {
        source_kind     = "single_series",
        source_id_field = "series_name",
        sort_priority   = { { key = "series_index", reverse = false } },
    },
    author = {
        source_kind     = "author",
        source_id_field = "series_name",  -- group records reuse series_name as the identity field
        sort_priority   = {
            { key = "series_name",  reverse = false },
            { key = "series_index", reverse = false },
            { key = "title",        reverse = false },
        },
    },
    genre = {
        source_kind     = "genre",
        source_id_field = "series_name",
        sort_priority   = {
            { key = "author_surname", reverse = false },
            { key = "series_name",    reverse = false },
            { key = "series_index",   reverse = false },
        },
    },
    tag = {
        source_kind     = "collection",  -- chip editor maps "Specific tag…" to kind=collection
        source_id_field = "series_name",
        sort_priority   = { { key = "last_opened", reverse = true } },
    },
    format = {
        source_kind     = "format",
        source_id_field = "series_name",
        sort_priority   = { { key = "last_opened", reverse = true } },
    },
    rating = {
        source_kind     = "rating",
        -- Rating groups carry their value on .avg_rating (numeric 0..5;
        -- 0 == "unrated"). The chip editor's Specific-rating picker
        -- writes ids as the digit string or the literal "unrated", so
        -- match that shape.
        source_id_from_group = function(g)
            local r = tonumber(g.avg_rating)
            if not r or r == 0 then return "unrated" end
            return tostring(math.floor(r))
        end,
        sort_priority   = {
            { key = "series_name",  reverse = false },
            { key = "series_index", reverse = false },
            { key = "title",        reverse = false },
        },
    },
    language = {
        source_kind     = "language",
        source_id_field = "series_name",
        sort_priority   = {
            { key = "author_surname", reverse = false },
            { key = "series_name",    reverse = false },
            { key = "series_index",   reverse = false },
        },
    },
}

-- _resolveStackPaths(group) — flat list of book.filepath strings for a
-- stack regardless of kind. Non-folder GROUP_KINDS carry a group.books
-- array with filepath on each entry. Folder stacks carry group.path and
-- need a directory walk; we reuse Repo.getAll (the same call that
-- _fetchChipItems uses for folder drilldown) and keep only book items
-- (skipping any nested folder items so the count matches what the user
-- sees at this level).
function BookshelfWidget:_resolveStackPaths(group)
    local paths = {}
    if group.books then
        -- For groups, `group.books` has already been filtered by the
        -- hydrator when the chip's filter is active, so the bulk
        -- add/remove actions naturally operate on the visible subset.
        for _, b in ipairs(group.books) do
            if b.filepath then paths[#paths + 1] = b.filepath end
        end
        return paths
    end
    if group.path then
        -- Folder stack: every book at any depth under group.path. The
        -- previous single-level Repo.getAll(group.path) only saw direct
        -- children, so a folder of folders reported "0 books" in the
        -- dialog and the Add/Remove actions had nothing to act on.
        -- Repo.getFolderBookPaths rides the cached recursive walk.
        --
        -- When the chip has an active status filter, scope the bulk
        -- action to the visible (filtered) subset — selecting "all
        -- visible" under a folder should respect what the user sees,
        -- not silently pull in books filtered out of the view.
        local fpaths = Repo.getFolderBookPaths(group.path) or {}
        local TabModel = require("lib/bookshelf_tab_model")
        local tab = TabModel.getById(self.chip)
        local filter = tab and tab.filter
        if filter and filter.statuses and next(filter.statuses) then
            local Repo_local = Repo  -- alias for the inner readProgress calls
            local kept = {}
            for _i, fp in ipairs(fpaths) do
                local _pct, status = Repo_local.readProgress(fp)
                if status == nil or status == "new" then status = "unread" end
                if filter.statuses[status] then kept[#kept + 1] = fp end
            end
            return kept
        end
        return fpaths
    end
    return paths
end

-- _applyStackSelection(group, action) — mutate the selection set by
-- stack. action ∈ {"add", "remove", nil}.
--   "add"    -> ensure every book in this stack is selected (top-up).
--   "remove" -> remove every book in this stack from the selection.
--   nil      -> toggle-by-state: "all" removes, "none"/"some" tops up.
--              Kept for callers that only want a single tap entry point
--              (dispatcher action, back-compat _showStackSelectionConfirm).
-- Selection mode is entered automatically when adding.
function BookshelfWidget:_applyStackSelection(group, action)
    local paths = self:_resolveStackPaths(group)
    if #paths == 0 then return end
    if action == "add" then
        if not self._selection:isActive() then self._selection:enterMode() end
        self._selection:addMany(paths)
    elseif action == "remove" then
        self._selection:removeMany(paths)
    else
        local state = self._selection:stackState(paths)
        if state == "all" then
            self._selection:removeMany(paths)
        else
            if not self._selection:isActive() then self._selection:enterMode() end
            self._selection:addMany(paths)
        end
    end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- Back-compat alias: callers that used to invoke the confirm-then-apply
-- helper get the no-confirm apply path now.
function BookshelfWidget:_showStackSelectionConfirm(group)
    self:_applyStackSelection(group)
end

function BookshelfWidget:_openGroupMenu(group, kind)
    -- Dialog shows in BOTH selection-on and selection-off modes so the
    -- user gets visible feedback on every long-press. The dialog's
    -- Select/Deselect button is state-aware and applies its action
    -- directly (no second confirm).
    if not group then return end
    -- kind isn't always carried on the group record itself. Folder
    -- shapes have group.kind = "folder", but the hydrated series /
    -- author / genre / tag / format groups returned by
    -- _hydrateGroupShape only carry { series_name, books, latest } --
    -- the kind context lives in the chip the user is on, not the
    -- payload. Callers pass kind explicitly; fall back to group.kind
    -- for the folder case so both call shapes work.
    kind = kind or group.kind
    if not kind then return end
    local spec = GROUP_KINDS[kind]
    if not spec then return end

    local source_id
    if spec.source_id_from_group then
        source_id = spec.source_id_from_group(group)
    else
        source_id = group[spec.source_id_field]
    end
    if not source_id or source_id == "" then return end

    local bw = self
    local display_name = group.label or group.series_name
        or (type(source_id) == "string" and source_id) or kind

    -- Per-kind "this <thing>" fragment for the prompt. Translatable.
    local this_kind
    if     kind == "folder"   then this_kind = _("this folder")
    elseif kind == "series"   then this_kind = _("this series")
    elseif kind == "author"   then this_kind = _("this author")
    elseif kind == "genre"    then this_kind = _("this genre")
    elseif kind == "tag"      then this_kind = _("this collection")
    elseif kind == "format"   then this_kind = _("this format")
    elseif kind == "rating"   then this_kind = _("this rating")
    elseif kind == "language" then this_kind = _("this language")
    else                           this_kind = _("this group")
    end

    -- Prompt + action buttons are state-aware. For "some" (the Venn
    -- middle), both Add and Remove are offered; for "all" only Remove;
    -- for "none" only Add.
    local stack_paths_for_prompt = self:_resolveStackPaths(group)
    local n_for_prompt = #stack_paths_for_prompt
    local sel_state = self._selection:stackState(stack_paths_for_prompt)
    local in_sel_count = 0
    for _, p in ipairs(stack_paths_for_prompt) do
        if self._selection:contains(p) then
            in_sel_count = in_sel_count + 1
        end
    end
    local remaining_count = n_for_prompt - in_sel_count
    -- Hard line break after the first action so each option reads as
    -- its own line ("Pin …" / "or add/remove …") rather than wrapping
    -- mid-phrase.
    local prompt
    if sel_state == "all" then
        prompt = string.format(
            _("Pin %s to the chip bar for quick access,\nor remove its %d books from your selection."),
            this_kind, n_for_prompt)
    elseif sel_state == "some" then
        -- Partial overlap: surface both numbers in the prompt so the
        -- two action buttons read unambiguously without parsing.
        prompt = string.format(
            _("Pin %s to the chip bar for quick access,\nor add %d more / remove the %d already selected."),
            this_kind, remaining_count, in_sel_count)
    else  -- "none"
        prompt = string.format(
            _("Pin %s to the chip bar for quick access,\nor add its %d books to a selection for bulk edits."),
            this_kind, n_for_prompt)
    end

    local function create_chip()
        -- Find a free custom_N id by walking existing tabs. Same pattern
        -- the chip editor's "+ Add new chip" footer uses.
        local TabModel = require("lib/bookshelf_tab_model")
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
        -- Deep-copy the per-kind sort priority so editing this tab's
        -- sort later doesn't mutate the shared GROUP_KINDS table.
        local sort_copy = {}
        for i, lv in ipairs(spec.sort_priority) do
            sort_copy[i] = { key = lv.key, reverse = lv.reverse }
        end
        -- Splice the new chip immediately after the chip the user was
        -- on when they pinned. Putting it at the end of a long chip
        -- strip hides it off-screen; users expect the new chip to land
        -- next to where they were working.
        TabModel.insertAfter(tabs, bw.chip, {
            id            = new_id,
            label         = display_name,
            icon          = nil,
            source        = { kind = spec.source_kind, id = source_id },
            filter        = {},
            sort_priority = sort_copy,
            enabled       = true,
        })
        TabModel.save(tabs)
        -- Switch to the new chip immediately so the user sees the
        -- result of their action (otherwise it's a silent append to a
        -- chip strip that might be off-screen). Persist + rebuild so
        -- the chip bar redraws with the new tab selected.
        bw:_clearDpadFocus()
        bw._drilldown_path = {}
        bw.chip            = new_id
        bw._cursor         = 1
        bw:_syncPageFromCursor()
        -- Deferred: _rebuild's _persistNavState owns the flush (and
        -- TabModel.save above already flushed the tab change durably).
        BookshelfSettings.saveDeferred("active_chip", new_id)
        Repo.invalidateBookCache("create-chip")
        bw:_rebuild()
        UIManager:setDirty(bw, "ui")
    end

    -- Custom ButtonDialog. Shape:
    --
    --   +-----------------------------------------------------+
    --   |              Hercule Poirot Mystery                 |  <- title (bold)
    --   | Pin this series to the chip bar for quick access,   |  <- prompt
    --   |   or add its 37 books to a selection for bulk edits.|
    --   +-----------------------------------------------------+
    --   |   Cancel    |     Pin     |      Select             |
    --   +-----------------------------------------------------+
    local ButtonDialog  = require("ui/widget/buttondialog")
    local Font          = require("ui/font")
    local TextBoxWidget = require("ui/widget/textboxwidget")

    local dialog
    local function close_dialog() UIManager:close(dialog) end

    local bw_ref = self
    local buttons = {
        {
            { text = _("Cancel"), callback = close_dialog },
            { text = _("Pin"),    callback = function()
                close_dialog()
                create_chip()
            end },
        },
    }
    -- Append action buttons to the same row, state-aware:
    --   "none" → Add N
    --   "some" → Add N more | Remove M  (the Venn-diagram middle)
    --   "all"  → Remove N
    -- Each action applies directly with no extra confirmation.
    if n_for_prompt > 0 then
        if sel_state ~= "all" and remaining_count > 0 then
            table.insert(buttons[1], {
                text = (sel_state == "some")
                    and string.format(_("Add %d"), remaining_count)
                    or  string.format(_("Add %d"), n_for_prompt),
                callback = function()
                    close_dialog()
                    bw_ref:_applyStackSelection(group, "add")
                end,
            })
        end
        if sel_state ~= "none" and in_sel_count > 0 then
            table.insert(buttons[1], {
                text = string.format(_("Remove %d"), in_sel_count),
                callback = function()
                    close_dialog()
                    bw_ref:_applyStackSelection(group, "remove")
                end,
            })
        end
    end

    -- Custom-image row (#70). Folders take a filesystem path and may
    -- already have an auto-detected cover.jpg; author/series/genre/tag
    -- stacks take a (kind, name) pair and look the image up in the
    -- user's bookshelf image library. The two share storage and
    -- render path through ImageSource, but the picker / clear actions
    -- diverge slightly per kind.
    local ImageSource = require("lib/bookshelf_image_source")
    if kind == "folder" and group.path then
        local has_override = ImageSource.getFolderImageOverride(group.path) ~= nil
        local has_resolved = ImageSource.resolveFolderImage(group.path) ~= nil
        local folder_row = {
            { text = _("Set folder image\xE2\x80\xA6"), callback = function()
                close_dialog()
                bw_ref:_pickFolderImage(group.path)
            end },
        }
        if has_override or has_resolved then
            folder_row[#folder_row + 1] = {
                text = _("Clear folder image"),
                callback = function()
                    close_dialog()
                    ImageSource.clearFolderImage(group.path)
                    ImageSource.invalidateCache()
                    bw_ref:_rebuild()
                    UIManager:setDirty(bw_ref, "ui")
                end,
            }
        end
        table.insert(buttons, folder_row)
    elseif (kind == "author" or kind == "series" or kind == "genre" or kind == "tag")
           and type(source_id) == "string" and source_id ~= "" then
        -- Per-kind button label so a user holding an author stack sees
        -- "Set author image..." rather than a generic phrase that
        -- would read wrong on the four kinds. The translation lookups
        -- are dynamic but each msgid is also written verbatim in the
        -- false-branch below so xgettext can find them.
        if false then
            local _ignore = {
                _("Set author image\xE2\x80\xA6"),
                _("Set series image\xE2\x80\xA6"),
                _("Set genre image\xE2\x80\xA6"),
                _("Set collection image\xE2\x80\xA6"),
                _("Clear author image"),
                _("Clear series image"),
                _("Clear genre image"),
                _("Clear collection image"),
            }
        end
        local set_labels = {
            author = _("Set author image\xE2\x80\xA6"),
            series = _("Set series image\xE2\x80\xA6"),
            genre  = _("Set genre image\xE2\x80\xA6"),
            tag    = _("Set collection image\xE2\x80\xA6"),
        }
        local clear_labels = {
            author = _("Clear author image"),
            series = _("Clear series image"),
            genre  = _("Clear genre image"),
            tag    = _("Clear collection image"),
        }
        local has_override = ImageSource.getStackImageOverride(kind, source_id) ~= nil
        local has_resolved = ImageSource.resolveStackImage(kind, source_id) ~= nil
        local row = {
            { text = set_labels[kind], callback = function()
                close_dialog()
                bw_ref:_pickStackImage(kind, source_id)
            end },
        }
        if has_override or has_resolved then
            row[#row + 1] = {
                text = clear_labels[kind],
                callback = function()
                    close_dialog()
                    ImageSource.clearStackImage(kind, source_id)
                    ImageSource.invalidateCache()
                    bw_ref:_rebuild()
                    UIManager:setDirty(bw_ref, "ui")
                end,
            }
        end
        table.insert(buttons, row)
    end

    dialog = ButtonDialog:new{
        title          = display_name,
        title_align    = "center",
        use_info_style = false,  -- use the bold title face, not infofont
        buttons        = buttons,
    }
    -- Subtitle prompt: explains both actions so the user knows what
    -- each button does. Sits between the title and the button row.
    local prompt_face, prompt_bold = BFont:getFace("infofont", 16)
    dialog:addWidget(TextBoxWidget:new{
        text      = prompt,
        face      = prompt_face,
        bold      = prompt_bold,
        alignment = "center",
        width     = dialog.title_group_width or math.floor(Screen:getWidth() * 0.6),
    })
    UIManager:show(dialog)
end

-- _pickFolderImage(folder_path) -- file picker for the "Set folder
-- image..." action on a folder card's long-press menu (#70). Opens
-- KOReader's PathChooser rooted at home_dir, filtered to image files,
-- and on confirm persists the chosen path against this folder. Picker
-- uses tap-to-navigate / long-press-to-select; we surface that via the
-- chooser's default title because the alternative is a confusing
-- silent-tap-on-the-folder UX (PathChooser's default behaviour for
-- file selection is exactly long-press-to-choose).
function BookshelfWidget:_pickFolderImage(folder_path)
    if type(folder_path) ~= "string" or folder_path == "" then return end
    local PathChooser = require("ui/widget/pathchooser")
    local ImageSource = require("lib/bookshelf_image_source")
    local bw = self
    local start_path = G_reader_settings:readSetting("home_dir") or folder_path
    local chooser
    chooser = PathChooser:new{
        title            = _("Choose folder image"),
        path             = start_path,
        select_directory = false,
        select_file      = true,
        show_files       = true,
        file_filter      = function(file) return ImageSource.isImageFile(file) end,
        onConfirm        = function(image_path)
            ImageSource.setFolderImage(folder_path, image_path)
            -- Invalidate so the next paint loads from the new path
            -- instead of any leftover entry keyed under the previous
            -- override (or under the auto-detected fallback we just
            -- overrode). _rebuild kicks the shelf to repaint at once.
            ImageSource.invalidateCache()
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end,
    }
    UIManager:show(chooser)
end

-- _pickStackImage(kind, name) -- file picker for the "Set <kind>
-- image..." action on author / series / genre / tag stacks (#70
-- extension). Same shape as _pickFolderImage; persists the choice in
-- the stack_images override table keyed on (kind, name) so the
-- override survives even when the user later organises an image
-- library matching by sanitised slug.
function BookshelfWidget:_pickStackImage(kind, name)
    if type(kind) ~= "string" or type(name) ~= "string" or name == "" then
        return
    end
    local PathChooser = require("ui/widget/pathchooser")
    local ImageSource = require("lib/bookshelf_image_source")
    local bw = self
    -- Open the picker rooted at the image library so the user lands
    -- in the right place when they've already organised files there.
    local start_path = ImageSource.getImageLibraryPath()
        or G_reader_settings:readSetting("home_dir") or "/"
    local chooser
    chooser = PathChooser:new{
        title            = _("Choose image"),
        path             = start_path,
        select_directory = false,
        select_file      = true,
        show_files       = true,
        file_filter      = function(file) return ImageSource.isImageFile(file) end,
        onConfirm        = function(image_path)
            ImageSource.setStackImage(kind, name, image_path)
            ImageSource.invalidateCache()
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end,
    }
    UIManager:show(chooser)
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
    if not group then return end
    local TabModel = require("lib/bookshelf_tab_model")
    local tab = TabModel.getById(self.chip)
    local sp  = tab and tab.sort_priority
    if not sp or #sp < 2 then return end  -- default group order wins
    -- books_meta (the parallel sort-fields array) doesn't reliably survive the
    -- trip from the repo group to the rendered tile, so rebuild it from the
    -- group's book filepaths when it's missing. want_cover=false keeps it
    -- light (no cover decode) -- we only need the sort-key fields. Without
    -- this the within-stack sort silently no-ops and the stack stays in
    -- default series order (e.g. "Reading 1st" never promotes in-progress
    -- books inside a series stack).
    if not group.books_meta and group.books then
        local bm = {}
        for _i, b in ipairs(group.books) do
            if b.filepath then
                bm[#bm + 1] = Repo.buildBookMeta(b.filepath, { want_cover = false })
                              or { filepath = b.filepath }
            end
        end
        group.books_meta = bm
    end
    if not group.books_meta then return end
    local within = {}
    for i = 2, #sp do within[#within + 1] = sp[i] end
    -- books_meta is the light parallel array (no read-status; page_count nil
    -- for EPUBs), so a within-stack sort by reading-status / progress /
    -- rating / page count would see all-nil and silently fall through to the
    -- next level -- e.g. "Reading 1st" not promoting in-progress books inside
    -- a series stack. Hydrate just the fields this sort needs, via the cached
    -- Repo.readProgress (.sdr fast-path: unread books cost nothing).
    local w_progress, w_rating, w_pages = false, false, false
    local w_opened, w_added = false, false
    for _i, lv in ipairs(within) do
        local k = lv.key
        if k == "percent_read" or k == "read_status"
                or k == "read_status_active" then w_progress = true end
        if k == "rating"      then w_rating = true end
        if k == "page_count"  then w_pages  = true end
        if k == "last_opened" then w_opened = true end
        if k == "date_added"  then w_added  = true end
    end
    if w_progress or w_rating or w_pages or w_added then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        local lfs_attr = ok_lfs and lfs and lfs.attributes or nil
        for _i, m in ipairs(group.books_meta) do
            if m.filepath and lfs_attr then
                -- date_added is the book file's own mtime (same source getAll's
                -- prefetch uses), independent of any sidecar.
                if w_added and m.date_added == nil then
                    m.date_added = lfs_attr(m.filepath, "modification") or 0
                end
                if w_progress or w_rating or w_pages then
                    local sdr = m.filepath:gsub("%.[^.]+$", "") .. ".sdr"
                    if lfs_attr(sdr, "mode") == "directory" then
                        local pct, status, rating, page_count = Repo.readProgress(m.filepath)
                        if w_progress then m._pct = pct; m._status = status end
                        if w_rating and m.rating == nil then m.rating = rating end
                        if w_pages  and m.page_count == nil then m.page_count = page_count end
                    end
                end
            end
        end
    end
    -- last_opened isn't in the light BIM meta (buildBookMeta omits it), so a
    -- within-stack sort by "Opened" would compare all-nil and silently no-op,
    -- leaving a drilled collection in its default order (#205). Populate it from
    -- KOReader's ReadHistory, the same source getAll's prefetch uses.
    if w_opened then
        local ok_rh, ReadHistory = pcall(require, "readhistory")
        if ok_rh and ReadHistory and ReadHistory.hist then
            local rh = {}
            for _i, item in ipairs(ReadHistory.hist) do rh[item.file] = item.time end
            for _i, m in ipairs(group.books_meta) do
                if m.filepath and m.last_opened == nil and m._last_read == nil then
                    m._last_read = rh[m.filepath] or 0
                end
            end
        end
    end
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

function BookshelfWidget:_expandLanguage(group)
    if not group or not group.series_name then return end
    self:_applyWithinGroupSort(group)
    self:_drillInto{
        kind    = "language",
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

-- force: open even when the start menu is set to Off. Set only by the explicit
-- "open start menu" gesture action; the footer button / focus slot leave it nil
-- so the Off guard still protects against a stale dispatcher action or queued
-- gesture.
function BookshelfWidget:_openStartMenu(force)
    if not force and self:_startMenuPosition() == "off" then return end
    local ok, StartMenu = pcall(require, "lib/bookshelf_start_menu")
    if not ok or not StartMenu then
        logger.warn("[bookshelf] start menu unavailable:", tostring(StartMenu))
        return
    end
    StartMenu.open(self, self._footer_h_last or Screen:scaleBySize(40),
        self._burger_dimen, "library")
end

-- Open the full-screen micro-module grid (Micro-modules placement ==
-- "fullscreen"), launched by the footer grid button. force: open even when
-- placement isn't "fullscreen" -- set only by the explicit gesture action; the
-- footer button leaves it nil so the placement guard still applies there.
function BookshelfWidget:_openMicroModulesFullscreen(force)
    if not force and not BookshelfSettings.microFullscreenButton() then return end
    local ok, Mod = pcall(require, "lib/bookshelf_micro_fullscreen")
    if not ok or not Mod then
        logger.warn("[bookshelf] micro-module fullscreen unavailable:", tostring(Mod))
        return
    end
    Mod.open(self, self._micromod_dimen, self._footer_h_last or Screen:scaleBySize(40))
end

function BookshelfWidget:onClose()
    UIManager:close(self)
    return true
end

return BookshelfWidget
