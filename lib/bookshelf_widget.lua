-- bookshelf_widget.lua
-- The top-level home screen widget. Composes HeroCard + ChipBar
-- + two ShelfRows + chevron pagination footer. Owns chip-state and refresh.
--
local InputContainer  = require("ui/widget/container/inputcontainer")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local Breaker = require("lib/bookshelf_module_breaker")
local Focus           = require("lib/bookshelf_focus")
local GestureZones    = require("lib/bookshelf_gesture_zones")
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
-- The one declaration of how a tap band (chip strip, list row) is sized, and
-- of which setting key drives each. Required at file scope because
-- _layoutPrimitives and _rebuild both need it on every layout pass.
local BandMetrics = require("lib/bookshelf_band_metrics")
local ShelfRow    = require("lib/bookshelf_shelf_row")
local SpineWidget = require("lib/bookshelf_spine_widget")
-- Covers-or-list, and the two setting keys that decide it. At file scope
-- because _viewMode()/_isListMode() are on the hot path -- several calls per
-- geometry pass, dozens per rebuild -- and a per-call require() of a
-- dependency-free 70-line table is a cost with nothing to show for it.
local ViewMode    = require("lib/bookshelf_view_mode")
local logger      = require("logger")
local T           = require("ffi/util").template

-- Shared wall-clock for [bookshelf perf] timestamps (and elapsed-time
-- bookkeeping); see lib/bookshelf_gettime.lua for the fallback contract.
local _gettime = require("lib/bookshelf_gettime")

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
-- Idle delay before a draft regrid (shelf-size dialog / pinch-zoom) upgrades its
-- soft/placeholder covers to correct-size decodes. Long enough to coalesce a
-- burst of taps/pinches, short enough to feel immediate once you stop.
local COVER_SETTLE_DELAY = 0.3
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

-- _footerReserveH() — vertical space the screen-anchored pagination footer
-- occupies. _rebuild reserves exactly this at the bottom of the layout
-- (label_h), so any code deciding how many rows fit has to subtract the SAME
-- number or it budgets rows into the footer's space. Declared at file scope
-- because both _rebuild and the row-count helpers (defined thousands of lines
-- apart) read it, and a `local` declared between them would resolve to a nil
-- global in the earlier one.
--
-- Not folded into _layoutPrimitives, whose own footer_h is a slightly smaller,
-- long-standing approximation: the cover grid derives shelf_h by DIVIDING the
-- leftover height, so it absorbs the difference silently, and correcting it
-- there would change every existing user's row count. List mode has a fixed row
-- height and cannot absorb anything, so its budget uses the real number.
local function _footerReserveH()
    return Screen:scaleBySize(32) + 2 * Screen:scaleBySize(4)
           + Screen:scaleBySize(12)
end

-- _asCoverGrid(fn) — run fn() with the view mode pinned to covers, then drop
-- the pin, whether fn returned or threw. The pin is the whole mechanism: every
-- geometry helper asks _isListMode() rather than taking a mode argument, so
-- this is how a caller asks them the counterfactual "what would the cover grid
-- be on this screen".
--
-- A DEPTH COUNTER, not a saved-and-restored setting. It used to arm the
-- session override and put the previous value back; there is no override any
-- more (the view mode is two persisted booleans plus the expand state -- see
-- lib/bookshelf_view_mode.lua), and a counterfactual measurement has no
-- business writing anything a user could observe. Counter rather than a
-- boolean so a nested ask (a pinned helper calling another pinned helper)
-- cannot drop the pin early on the way out.
--
-- File scope rather than per-widget, on two counts. It is a synchronous
-- bracket around a pure measurement -- nothing inside fn yields, shows a
-- widget or reaches another shelf -- so there is no window in which a second
-- instance could read it. And it has to be readable from both ends of this
-- file: _rebuild reaches it through _listCollapsedHeroHeight, the row-count
-- helpers thousands of lines below reach it directly, and a `local` declared
-- between the two would resolve to a nil global in _rebuild. (Same constraint
-- as _footerReserveH above; it used to sit next to _gridBaseRows.)
-- _viewMode() consults the counter below.
local _covers_pin = 0
local function _asCoverGrid(fn)
    _covers_pin = _covers_pin + 1
    local ok, v = pcall(fn)
    _covers_pin = _covers_pin - 1
    if not ok then return nil end
    return v
end

-- _itemFilepath(item) — the filepath that identifies a shelf item for
-- selection/highlight purposes, whatever kind it is. Same precedence as
-- _selectedFilepath's own read and as bookshelf_list_row.lua's itemFilepath
-- (folder → its first book, group → its first member, book → itself).
local function _itemFilepath(item)
    if not item then return nil end
    return item.filepath
        or (item.first_book and item.first_book.filepath)
        or (item.books and item.books[1] and item.books[1].filepath)
end

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
    self:_refreshDitherFlag()   -- colour-panel cover saturation, #289
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
        -- Short diagonal swipe -- KOReader's default "refresh the screen".
        --
        -- WHY BOOKSHELF HAS TO CARRY THIS AT ALL. KOReader registers that
        -- gesture as a TOUCH ZONE on the FileManager (gestures.koplugin
        -- registers `short_diagonal_swipe` via self.ui:registerTouchZones).
        -- Touch zones only fire on the widget that owns them, and
        -- UIManager:sendEvent hands an input event to the TOPMOST widget and
        -- then, if it declines, only to widgets flagged is_always_active --
        -- which the FileManager is not. So while the shelf is up, the
        -- FileManager never sees a gesture at all and the refresh cannot fire.
        --
        -- Nothing broke it; it has never been reachable from inside the shelf.
        -- It works in the plain file browser and inside a book, which is
        -- exactly where it would have been last seen working.
        --
        -- FOUR ranges rather than one direction-less range: an unconstrained
        -- swipe entry would sit in the same ges_events table as SwipeNextPage
        -- and friends, which InputContainer:onGesture walks with pairs() -- in
        -- an arbitrary order. It would eventually swallow a page turn.
        --
        -- The scale cap is KOReader's own definition of "short"
        -- (gestures.koplugin: gest.distance > Screen:scaleBySize(300) -> not
        -- this gesture), so a long diagonal still reaches the screenshot
        -- handler above.
        ShelfDiagonalSwipe = (function()
            local ranges = {}
            for _i, dir in ipairs({ "northeast", "northwest",
                                    "southeast", "southwest" }) do
                ranges[#ranges + 1] = GestureRange:new{
                    ges       = "swipe",
                    range     = self.dimen,
                    direction = dir,
                    scale     = { 0, Screen:scaleBySize(300) },
                }
            end
            return ranges
        end)(),
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
        -- Device Back inside a chip drilldown pops one breadcrumb level
        -- (#239), matching the "Back in file browser: parent folder"
        -- expectation. Without this the key falls through to the
        -- FileChooser underneath, which walks the REAL file browser up to
        -- its parent -- and bookshelf mirrors that as a folder view of
        -- whatever lies above the library. At top level the handler
        -- declines the event, keeping the historical fall-through.
        self.key_events.BSDrillBack = { { Device.input.group.Back } }
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
-- taps for night mode, edge swipes for brightness/warmth, etc.) never fire
-- on their own. lib/bookshelf_gesture_zones carries the fix (and the #79/#84
-- bug history) for both gesture and action-event forwarding; the book-detail
-- popup (ReviewsModal) reuses the exact same helpers for the same reason.
function BookshelfWidget:handleEvent(event)
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
        local ev = event.args[1]
        if fm then return GestureZones.tryFMZones(ev, fm) end
        -- Hot parking: no FileManager exists while a reader is parked
        -- beneath the shelf. A menu-intent gesture (the reader's top-strip
        -- menu zones) converts on the spot: finish the deferred close and
        -- open the real FM menu, so the user never sees book actions on
        -- the home screen. Everything else forwards to the reader host's
        -- allowlisted zones (user gestures; page-turn zones excluded).
        local Park = require("lib/bookshelf_reader_park")
        if Park.isParked() then
            local rui = require("apps/reader/readerui").instance
            if GestureZones.matchesReaderMenuZone(ev, rui) then
                Park.finishToMenu()
                return true
            end
            return GestureZones.tryReaderZones(ev, rui)
        end
        return false
    end

    if InputContainer.handleEvent(self, event) then return true end
    if require("apps/filemanager/filemanager").instance then
        return GestureZones.forwardToFM(event, self)
    end
    -- Parked reader hosts Dispatcher actions when there's no FM (see above).
    local Park = require("lib/bookshelf_reader_park")
    if Park.isParked() then
        local rui = require("apps/reader/readerui").instance
        return GestureZones.forwardToReader(event, self, rui)
    end
    return false
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

-- Re-key a moved filepath inside any drilldown payload that captured it
-- at descend-time. A move (unlike a delete) keeps the book's membership
-- in series / author / genre / tag drilldowns - only the path changed -
-- so the payload item is renamed in place rather than removed. Without
-- this, moving a book from inside a collection view makes it vanish
-- until the user backs out and re-enters. Folder drilldowns re-query
-- the filesystem on render, so they need no payload mutation (and a
-- book moved out of the drilled folder correctly disappears there).
-- Logic lives in lib/bookshelf_drill_rekey so it can be unit-tested (this
-- file can't load under the standalone test runner, and the re-key has
-- regressed twice). See that module for why every parallel list matters.
function BookshelfWidget:_rekeyDrilldown(old_fp, new_fp)
    if not self._drilldown_path then return end
    return require("lib/bookshelf_drill_rekey").apply(
        self._drilldown_path, old_fp, new_fp)
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
        elseif e.kind == "opds_nav" then
            -- A drilled subcatalog, by identity: the pair that addresses its
            -- window, so the restore can ask whether it has anything cached
            -- before putting the reader in front of it.
            --
            -- This USED to be dropped, on the grounds that a restored frame
            -- could land on an empty feed whose only remedy was a network
            -- fetch at launch that nobody asked for. Both halves of that have
            -- since stopped being true: feeds persist in SQLite and accumulate
            -- as they are paged, so a subcatalog someone was reading almost
            -- always has entries, and the refresh default is swipe-down only,
            -- so a restore cannot trigger a fetch on its own. The restore side
            -- still checks rather than assumes.
            out[#out + 1] = { kind = "opds_nav", label = e.label,
                              server_key = e.payload and e.payload.server_key,
                              feed_url   = e.payload and e.payload.feed_url }
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
        -- feed_url before label: two subcatalogs under different parents share
        -- a label often enough ("English", "Fiction") that a label-only key
        -- would read a real navigation as "nothing moved" and skip the save.
        snap[#snap + 1] = (e.kind or "") .. "\2"
            .. (e.path or e.query or e.feed_url or e.label or "")
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
        elseif e.kind == "opds_nav" and e.server_key and e.feed_url then
            -- Restored only when the feed still has something cached. An empty
            -- window would put the reader in front of "No books yet" on
            -- launch, and the only way out of it is a fetch - which is exactly
            -- the network-at-startup this must not do. Nothing cached means
            -- dropping the frame, which lands them on the catalog root.
            --
            -- STOPS the walk rather than skipping the frame: a path with a
            -- hole in it is worse than a short one, because Back would then
            -- climb to a parent the reader never came through.
            local OpdsWindow = require("lib/bookshelf_opds_window")
            if (OpdsWindow.count(e.server_key, e.feed_url) or 0) == 0 then
                break
            end
            self._drilldown_path[#self._drilldown_path + 1] = {
                kind = "opds_nav", label = e.label,
                payload = { server_key = e.server_key, feed_url = e.feed_url },
            }
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

-- Make `key` the active chip and repaint. Mirrors the chip-tap switch in
-- _rebuild's on_change (reset drilldown + cursor, persist, full rebuild), but
-- as a reusable method so long-press-to-edit and add-new-chip can select the
-- tab too. Full _rebuild (not the below-hero fast path) because the chip bar
-- itself changes -- the selected highlight moves, and a freshly-added chip
-- needs to appear.
function BookshelfWidget:_selectChip(key)
    -- User picked this chip: arm the OPDS fetch gate (see _markOpdsNav).
    self:_markOpdsNav()
    -- A recorded fetch failure belongs to the feed it happened on, and the
    -- empty state reads it without knowing which feed is up. Leaving it set
    -- would have one catalog's timeout explaining the next one's silence.
    self._opds_fail_url, self._opds_fail_err = nil, nil
    self:_clearDpadFocus()
    self._drilldown_path = {}
    self.chip    = key
    self._cursor = 1
    self:_syncPageFromCursor()
    BookshelfSettings.saveDeferred("active_chip", key)
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- The shelf side of a chip EDIT: the chip editor changed something and handed
-- control back, so re-render the shelf under it. Passed in as the editor's
-- on_change, and reached from every one of its exits that can change what the
-- active chip shows (Save, a delete, the icon/label live previews, an X-close
-- that has to undo one).
--
-- Arms the OPDS fetch gate, for the same reason the chip-tap leg does (see
-- _markOpdsNav): pointing a chip at an OPDS catalog happens HERE, in the
-- editor, and this rebuild is the FIRST render of that feed. Every OPDS
-- network call is gated on the one-shot arm, and nothing else in the add-a-
-- catalog-chip flow is left to set it:
--
--   * the add-chip button's own _selectChip DOES arm -- and spends it on the
--     placeholder source every new chip is born with ({ kind = "all" }), long
--     before the user has picked a catalog;
--   * picking the source is a DATA change, which the editor deliberately does
--     not live-preview (a data preview costs a full rebuild per tap), so no
--     shelf render happens between the pick and Save;
--   * Save closes the dialog and calls this. Without an arm here the shelf
--     renders the feed's empty window and stops -- which is exactly the device
--     report: a brand-new OPDS chip shows the empty state, and pulling down
--     (_opdsRefresh calls the fetch directly) or switching away and back
--     (_selectChip re-arms) fixes it.
--
-- Unconditional rather than "only when the new source is OPDS": the arm is
-- one-shot and _opdsAfterPage consumes it on the very rebuild below, whether or
-- not there is a feed to fetch. A chip edit that touched nothing about a
-- catalog simply spends it on a render that had nothing to fetch, which is the
-- same no-op every non-OPDS chip tap already performs.
function BookshelfWidget:_afterChipEdit()
    self:_markOpdsNav()
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

function BookshelfWidget:_rebuild()
    -- Drop the list-geometry memo. Everything it caches -- the band, the row
    -- height, the one-line minimum -- is derived from settings and screen
    -- geometry, and every path that changes either comes through a rebuild:
    -- a font nudge, a pinch, a chip switch, a rotation. One table, cleared in
    -- one place, so a stale entry cannot outlive the layout it described.
    self._list_geom_memo = nil
    -- FIRST LIST RENDER: take up the slack once, before anything is built.
    -- "yes I think we want that first render scale implemented, if there's a
    -- list on screen" -- so it is gated on list mode, which means a session
    -- that starts in the cover grid settles the first time the list appears
    -- rather than never.
    --
    -- ONCE PER SESSION, on a flag, and here rather than as a second rebuild:
    -- the band plan is a pure function of the widget's geometry and settings,
    -- so it can be asked before the tree exists, and settling first means the
    -- build below is the only one. Doing it after would cost a full second
    -- rebuild on the first paint of every session.
    --
    -- Per session rather than once ever, because it is idempotent and only
    -- ever grows the type when there is slack to take up: a rotation, a
    -- KOReader font change or a new device profile all leave slack that this
    -- then closes, and re-running it costs nothing when there is none.
        -- Re-read the colour-dither hint so toggling "Colour panel dithering"
    -- takes effect on the next refresh (#289).
    self:_refreshDitherFlag()
    -- Drop last render's status-strip measurement: the book, the width or the
    -- status template may all have changed since. Everything inside this
    -- rebuild then shares ONE fresh probe (see _statusStripHeight), which is
    -- what makes the row-count budget and the layout agree on the hero's height.
    self._strip_h_memo = nil
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
    -- "Go to home screen" (#223) requested before this widget existed: skip the
    -- saved-drilldown restore below so the first paint is the top level. Class-
    -- level because the requesting code runs before the instance does (same
    -- reason as BookshelfWidget.live); cleared on consumption so it can never
    -- send a later, unrelated rebuild home.
    if BookshelfWidget.go_home_pending then
        BookshelfWidget.go_home_pending = nil
        self._pending_restore_drill = nil
        self._drilldown_path = {}
        self._cursor = 1
    end
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
    -- chip-font setting (50-300) so the strip grows to accommodate larger
    -- text without clipping.
    --
    -- Through BandMetrics, which is where that derivation is declared -- this
    -- line used to carry its own copy of it, alongside a comment asking
    -- whoever touched it to keep the copy in sync with the chip strip's own.
    -- There are now two scale keys and three sites; a sync note would not have
    -- survived that.
    local chip_h = BandMetrics.cellHeight(BandMetrics.CHIP_KEY)
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
    local FOOTER_H             = _footerReserveH()
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
    local slot_h_natural = math.floor(slot_w_natural * self:_coverAspect())

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
    -- Gap after each row: PAD between cover shelves, a hairline between list
    -- rows (see _rowGap). Bound once here and used by every term below that
    -- counts it, so the budget and the layout spend the same number.
    local row_gap       = self:_rowGap(PAD)
    -- total_pad: sum of vertical padding/gaps in inner_vgroup. Only ONE
    -- outer PAD now (the top margin) — the footer is screen-anchored,
    -- not flowed inside the outer VerticalGroup, so there's no outer
    -- bottom VerticalSpan eating space below the inner_content.
    local total_pad = PAD                                      -- outer top
                    + hero_chip_pad                            -- hero → chips/row1
                    + ((not hide_chip_bar) and PAD or 0)     -- chips → row1
                    + n_shelves * row_gap                      -- after each row

    local shelf_h, hero_h
    if self._expanded then
        -- Strip is sized to the status_row's natural height — no padding
        -- slack inside it, so every spare pixel goes to the shelves and
        -- covers stay closer to natural aspect after the title block claims
        -- its slice. The probe lives in _statusStripHeight because _maxRows
        -- has to subtract the SAME height from its row budget; it falls back
        -- to a small fixed dp if there is no current book.
        local strip_minimum, probe_book = self:_statusStripHeight(content_w)
        -- Hand the freshly-built probe record off to _buildHero so it
        -- doesn't pay another DocSettings:open() for the same filepath
        -- in the same rebuild cycle. Only when the probe built a
        -- preview-book record (not the fallback to getCurrent), so the
        -- cache is precisely scoped. Cleared in _buildHero after use.
        if probe_book and self._preview_book
                and probe_book.filepath == self._preview_book.filepath then
            self._hero_book_cache = probe_book
        end
        shelf_h = math.max(1, math.floor(
            (self.height - strip_minimum - chip_contrib - label_h - total_pad)
            / n_shelves))
        -- Cap shelf_h so covers don't grow past the ShelfRow stretch cap
        -- (5% over natural 2:3). With a label, the strip claims its share
        -- of vertical real estate before the cap kicks in; with label_mode
        -- = "none", the whole row is cover. Mirrors ShelfRow's bounds so
        -- inter-row slack is distributed cleanly below instead of leaking
        -- into oversized covers.
        local label_mode = self:_shelfLabelMode()
        local title_block_h = 0
        if label_mode then
            local label_scale     = BookshelfSettings.read("expanded_shelf_font_scale") or 100
            local title_face_size = math.floor(14 * label_scale / 100 + 0.5)
            title_block_h = Size.padding.default + math.floor(title_face_size * 1.3)
        end
        -- The 1.05 lets uniform covers stretch 5% past 2:3 to soak up slack.
        -- With true-aspect on, covers never stretch (they render at their own
        -- ratio up to the 1.65 cap), so cap at exactly the reserved row height
        -- -- extra slack stays below the grid instead of as dead headroom
        -- above every bottom-anchored cover.
        local cap_mult = BookshelfSettings.isTrue("true_cover_aspect") and 1.0 or 1.05
        local capped_shelf_h = math.floor(slot_h_natural * cap_mult) + title_block_h
        if shelf_h > capped_shelf_h then shelf_h = capped_shelf_h end
        -- List rows are a fixed height decided by the column set, not by the
        -- cover-aspect budget above; _maxRows already counted them at exactly
        -- this height, so the row block fits by construction. Decided BEFORE
        -- hero_h so the hero (a status strip here, the leftover-absorbing card
        -- in the collapsed branch below) is sized against the height the rows
        -- will really take -- overriding after hero_h would strand the
        -- difference as dead space at the bottom of the screen.
        if self:_isListMode() then shelf_h = self:_listRowHeight() end
        hero_h = strip_minimum
    else
        -- Hero-fraction model. `available` = hero_h + sum(shelf_h) (pads
        -- already removed via total_pad). Hero gets its target share; the rows
        -- (count from _baseShelves) split the rest, each clamped to ShelfRow's
        -- squash/stretch band so covers fill the row. The hero absorbs any
        -- leftover, so it's always >= its target (never starved). The whole of
        -- that arithmetic now lives in _collapsedGridSplit, so list mode can
        -- ask what the cover grid WOULD do without a second copy of it.
        --
        -- List mode takes the cover grid's HERO and nothing else. Its rows are
        -- a fixed height decided by the font scale, not by the cover-aspect
        -- band, and the hero must not move when the user flips the view mode --
        -- so the hero is the number the grid would have produced (that is what
        -- _listCollapsedHeroHeight asks for) and the rows fit into what is
        -- left. _listBandPlan, which is where the row COUNT came from, derives
        -- the hero the same way, so the two agree by construction.
        --
        -- Note the reversal: the collapsed cover grid sizes the rows and lets
        -- the hero absorb the leftover; collapsed list mode sizes the hero and
        -- lets the MARGINS absorb the leftover. That is the whole of the "the
        -- hero shrinks when I switch to list" fix.
        if self:_isListMode() then
            shelf_h = self:_listRowHeight()
            hero_h  = self:_listCollapsedHeroHeight(hide_chip_bar)
        else
            shelf_h, hero_h =
                self:_collapsedGridSplit(hide_chip_bar, n_shelves, slot_h_natural)
        end
    end

    local hero_cover_w, hero_cover_h
    if self._expanded then
        hero_cover_w = hero_cover_w_natural
        hero_cover_h = hero_cover_h_natural
    else
        hero_cover_h = math.max(1, hero_h)
        -- Cover WIDTH stays 2:3-derived so an ordinary cover fills the region at
        -- full size (matching the shelf, where 2:3 covers keep their size). True
        -- aspect is applied inside HeroCard: it keeps this width for covers that
        -- fit, and narrows ONLY genuinely tall (>1.5) books enough to fit the
        -- region height undistorted. So nothing shrinks or squashes needlessly.
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
    -- Cleared each rebuild; the micro / expanded builders below re-record their
    -- status strip so the minute tick + device events can swap it in place
    -- (#292). Left nil for the book-detail hero, which uses the right-column
    -- swap path instead.
    self._hero_status_strip = nil
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
            -- No "opds_nav" entry, deliberately. An OPDS chip's label IS the
            -- catalog's title, and drilling into one of its navigation entries
            -- stays inside that catalog -- so the pill should keep saying
            -- "Standard Ebooks", giving "Standard Ebooks > Science Fiction"
            -- rather than a generic "Catalog > Science Fiction" that throws the
            -- catalog's identity away. Same call the folder case makes below
            -- (plural_for_chip maps the Library chip to "folder" so a folder
            -- drill keeps "Library" in the pill); absent from this map, the
            -- override simply never fires and the chip label stands.
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
        on_pill_hold      = in_search_mode and function()
            self:_showSearchViewModePicker()
        end or nil,
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
            --
            -- WHICH search depends on what is on screen. On an OPDS view
            -- (the catalog chip's root feed, or a subcatalog drilled from
            -- it) the books listed are not on disk, so running the local
            -- library search there would answer a question the user did
            -- not ask -- they are looking at a catalog and expect to
            -- search THAT. _opdsEffectiveTab is the same "is this view a
            -- feed" test every other OPDS path uses, so the two searches
            -- can never both apply. Every non-OPDS view is unchanged.
            if key == "search" then
                local opds_tab = self:_opdsEffectiveTab()
                if opds_tab then
                    self:_opdsOpenSearchDialog(opds_tab)
                else
                    self:_openSearchDialog()
                end
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
            -- User TAPPED this chip: arm the OPDS fetch gate. The swipe path
            -- (_setActiveChip) and _selectChip arm their own; this leg inlines
            -- the same transition, so without this a tapped OPDS chip renders
            -- its empty window and never fetches.
            self:_markOpdsNav()
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
            -- Long-pressing a chip that isn't the active one selects it first,
            -- so editing a tab always leaves you on that tab (request). The
            -- editor then opens over the now-selected shelf.
            if key ~= self.chip then self:_selectChip(key) end
            local Editor = require("lib/bookshelf_chip_editor")
            Editor:editTab(key, {
                on_change = function() self:_afterChipEdit() end,
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
    local all_items, _total_hint
    if self._draft_regrid and self._draft_items_cache then
        -- Draft regrid: only the grid geometry changed, not the book set, so
        -- reuse the last full fetch and let the slicing below reflow it to the
        -- new page size. Skips _fetchChipItems (the library/sort read). The
        -- cache is repopulated by every normal (non-draft) rebuild, so it can't
        -- go stale across a chip switch or library refresh.
        all_items   = self._draft_items_cache.all_items
        _total_hint = self._draft_items_cache.total_hint
    else
        all_items, _total_hint = self:_fetchChipItems(MAX_FETCH)
        all_items = all_items or {}
        self._draft_items_cache = { all_items = all_items, total_hint = _total_hint }
    end
    -- Open-ended OPDS window: the repo's total is a lower bound (what the
    -- cached window holds), not the size of the feed. Captured HERE, before
    -- the cursor clamp and the footer build -- both read it. nil on every
    -- other chip, since only the OPDS page table carries the field.
    self._opds_open_ended = (type(all_items) == "table")
                            and all_items.opds_open_ended or nil
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
            placeholder_text = _("No favorites yet · Long-press a book and tap 'Add to favorites'")
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
        elseif _source_kind == "opds" then
            -- A CATALOG IS NOT YOUR LIBRARY, and the generic message below
            -- treats it as one: "No books in Internet Archive yet · Long-press
            -- the chip to edit its source or filter". Every part of that is
            -- wrong here. The books are on someone else's server, so there is
            -- no "yet" and nothing the reader can add; the source is a URL
            -- they already chose; and the overwhelmingly common reason a
            -- catalog shelf is empty is not that the catalog is empty.
            --
            -- Three cases, and telling them apart is the whole point:
            --
            --   * THE FETCH FAILED. Recorded at the failure site, keyed by
            --     url. Seen on archive.org's language facets, which are slow
            --     enough to trip the TLS read timeout ("wantread") -- the
            --     shelf then shows an empty state for a feed nobody managed to
            --     read. A retry is the action, so name it.
            --   * A START FOLDER IS SET. The reader pointed this chip at a
            --     subcatalog, and if that one is unreachable or genuinely
            --     empty they are looking at a shelf with no way back that they
            --     can see -- the clear lives in Catalog settings, so say so.
            --   * Genuinely empty, which does happen and is not an error.
            local _label = _tab and _tab.label or self:_chipLabel()
            local _start = select(2, self:_opdsStartFeed(_tab))
            if self._opds_fail_url then
                placeholder_text = string.format(
                    _("Couldn't load %s \xC2\xB7 Pull down to try again"),
                    _label)
            elseif _start then
                placeholder_text = string.format(
                    _("Nothing in \"%s\" \xC2\xB7 Pull down to refresh, or clear the start folder in Catalog settings"),
                    _start)
            else
                placeholder_text = string.format(
                    _("Nothing in %s \xC2\xB7 Pull down to refresh"), _label)
            end
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
        -- An OPDS chip lands HERE on its first tap -- the window starts empty,
        -- so the repo returns nothing and flags the page for fetching. The
        -- trigger has to run on this branch too, or a fresh catalog chip
        -- dead-ends on "No books yet" and nothing ever fetches it.
        self:_opdsAfterPage(self._page_items)
        return
    end

    -- Both builders return the same thing -- n_shelves uniform-height widgets --
    -- so everything downstream (the vgroup splice, the slack absorber, the
    -- cover-dim readback, _swapShelvesInPlace's in-place swap) is mode-agnostic.
    local rows
    if self:_isListMode() then
        rows = self:_buildListRows(items, content_w, shelf_h, book_gap, n_shelves)
    else
        rows = self:_buildShelfRows(items, content_w, shelf_h, book_gap, n_shelves)
    end
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
    local slot_h  = math.floor(slot_w * self:_coverAspect())
    -- In list mode that slot formula reads _nCols() == 1 and asks BIM to
    -- extract every cover at the full content width -- a poster per book. Send
    -- the list thumbnail size instead. Sent even when the cover column is OFF:
    -- extraction is also what supplies the titles and authors the text columns
    -- render, and sizing any incidentally-extracted cover small is right.
    if self:_isListMode() then
        local ListGeom = require("lib/bookshelf_list_geom")
        local ListRow  = require("lib/bookshelf_list_row")
        slot_w, slot_h = ListGeom.thumbSize(shelf_h, ListRow.RING)
    end
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
    -- The list's top margin (see _listBandPlan). The plan wants the STANDARD
    -- pad above row 1 -- which is the span this layout already carries there --
    -- so top_extra is 0 in every case a device can reach, and this line exists
    -- for the one case it is not. Nothing is added to the vgroup -- the
    -- existing span just gets wider or narrower -- so _swapShelvesInPlace's
    -- stride-of-2 walk from shelf_first_idx is untouched, and the layout_slack
    -- absorber at the bottom takes the surplus without being told about any of
    -- this. That surplus IS the bottom margin, and it is meant to be larger
    -- than the top one when there is not room for another row.
    --
    -- Zero in cover mode, where the hero already absorbs the leftover and the
    -- two gaps are both PAD.
    --
    -- SIGNED. base_top_pad below is the span the layout already carries above
    -- row 1 -- PAD with the chip strip up, the hero->chips gap without it --
    -- and the plan's top_extra is the difference between that and the top gap
    -- it wants, so `base + extra` is plan.top_gap exactly, in both branches. It
    -- is negative only when the band cannot afford base_top_pad at both ends,
    -- and then the span has to be able to SHRINK or the bottom margin pays for
    -- a top margin the screen has not got (see _listBandPlan). Never negative
    -- as a width: base + (top_gap - base) is top_gap, which is >= 0.
    local list_top_extra = 0
    if self:_isListMode() then
        list_top_extra = self:_listBandPlan(self._expanded, hide_chip_bar).top_extra
    end
    inner_vgroup[#inner_vgroup + 1] = VerticalSpan:new{
        width = hero_chip_pad + (hide_chip_bar and list_top_extra or 0) }
    if not hide_chip_bar then
        inner_vgroup[#inner_vgroup + 1] = chips
        inner_vgroup[#inner_vgroup + 1] = VerticalSpan:new{
            width = PAD + list_top_extra }
    end
    -- In expanded mode shelf_h is capped at natural 2:3 (covers don't
    -- stretch), so n_shelves × shelf_h often leaves vertical slack. Spread
    -- that slack equally across the gap below every row (including the
    -- last) so the grid reads as evenly distributed top-to-bottom — the
    -- bottom row floats up to match the inter-row spacing instead of
    -- pinning to the footer. Non-expanded mode keeps the bottom absorber
    -- (the hero already takes the slack on that path).
    -- Everything above row 1, plus the reserved footer. list_top_extra counts:
    -- wipe_rows_top is derived from this and is the screen-y the rows really
    -- start at, which anchors the page-turn wipe and the scoped refresh -- both
    -- of which would clip the top of row 1 if this said the rows began where
    -- they used to.
    local pre_rows_h      = PAD + label_h + hero_h + hero_chip_pad
                          + ((not hide_chip_bar) and (chip_h + PAD) or 0)
                          + list_top_extra
    local rows_block_h    = n_shelves * shelf_h + n_shelves * row_gap
    local after_row_bonus = 0
    -- List mode opts out: its gap is a hairline by design, and dealing the
    -- leftover pixels into it would reopen the airy spacing this mode was
    -- tightened to escape (the bonus is up to a whole row's worth, i.e. tens
    -- of pixels per gap). The slack absorber below parks the remainder under
    -- the last row, where it reads as a bottom margin above the footer.
    if self._expanded and n_shelves >= 1 and not self:_isListMode() then
        local slack = self.height - pre_rows_h - rows_block_h
        if slack > 0 then
            after_row_bonus = math.floor(slack / n_shelves)
        end
    end
    -- First shelf row index in the vgroup — stashed below for
    -- _swapShelvesInPlace's fast-path swap.
    local shelf_first_idx = #inner_vgroup + 1
    local list_rows = self:_isListMode()
    local ListRow   = list_rows and require("lib/bookshelf_list_row") or nil
    for r = 1, n_shelves do
        inner_vgroup[#inner_vgroup + 1] = rows[r]
        -- Exactly ONE widget after every row, in both modes: _swapShelvesInPlace
        -- walks the vgroup on a stride of 2 (shelf_top_idx, +2, +4 ...) to swap
        -- rows in place, so a divider after some rows and nothing after others
        -- would slide the rows out from under their stashed indices.
        --
        -- The divider is exactly row_gap tall (both are Size.line.thin), so the
        -- rule IS the gap rather than something added to it. None below the
        -- last VISIBLE row: a rule with nothing under it reads as an underline
        -- on the final book, not as a separator -- and on a partial last page
        -- the trailing rows are blank spacers (ListRow.new with a nil item), so
        -- the test is "is there a row of content below this one", not "is there
        -- a row".
        if list_rows and r < n_shelves and self:_listRowFilled(items, r + 1) then
            inner_vgroup[#inner_vgroup + 1] =
                ListRow.divider(content_w, self:_listDividerOpts(items, r))
        else
            inner_vgroup[#inner_vgroup + 1] =
                VerticalSpan:new{ width = row_gap + after_row_bonus }
        end
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
                     + list_top_extra          -- list mode's symmetric margin
                     + n_shelves * shelf_h
                     + n_shelves * row_gap     -- after each row
                     + n_shelves * after_row_bonus  -- expanded-mode even slack
    local layout_slack = self.height - layout_sum
    if layout_slack > 0 then
        inner_vgroup[#inner_vgroup + 1] = VerticalSpan:new{ width = layout_slack }
    end
    -- shelf_first_idx points at row 1; rows live at first, first+2, first+4
    -- (each separated by one gap widget). No footer_idx in inner_vgroup
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
        -- Which presentation these dims were measured for. n_shelves alone
        -- can't tell the two apart -- both modes can legitimately show the same
        -- row count -- so without this a mode change would slip past the
        -- staleness check in _swapShelvesInPlace and the next page turn would
        -- render cover rows into a list layout (or the reverse).
        view_mode            = self:_viewMode(),
        -- Actual cover-area dims this render used (reported by ShelfRow).
        -- Drives _currentSlotDims so the preload warms next-page covers at the
        -- exact size the shelf draws -- no re-deriving the stretch/shrink/label
        -- math here. Falls back to the width-slot computation if absent.
        cover_w              = rows[1] and rows[1].cover_w,
        cover_h              = rows[1] and rows[1].cover_h,
        -- Index layout depends on whether the chip strip is in the vgroup
        -- AND on n_shelves. shelf_first_idx is the row-1 index; each row
        -- is followed by exactly one gap widget (a VerticalSpan, or the
        -- hairline divider in list mode), so subsequent rows live at +2.
        shelf_top_idx        = shelf_first_idx,
        shelf_bottom_idx     = shelf_first_idx + 2 * (n_shelves - 1),
        footer_overlap_idx   = footer_idx,
        -- Screen-y where the shelf rows begin (pre_rows_h includes the
        -- bottom-reserved footer label_h, so subtract it). Anchors the scoped
        -- refresh + page-turn wipe region, since bare HorizontalGroup rows
        -- carry no painted .dimen to read it from.
        wipe_rows_top        = pre_rows_h - label_h,
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
        function Absorber:onDoubleTap() return true end
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
                DoubleTap = { GestureRange:new{ ges = "double_tap", range = dim } },
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
    -- OPDS chips only: pull more feed pages if the repo flagged this page as
    -- running past the cached window, and fill in missing thumbnails. No-op
    -- (one tab lookup) on every other chip.
    self:_opdsAfterPage(self._page_items)
    -- A full rebuild is followed by a full-screen refresh. On colour e-ink
    -- the very next page-turn wipe stalls badly while that refresh is still
    -- draining (issue #247); flag it so _swapShelvesInPlace can skip the
    -- animation for that one turn. Consumed by the first real page-turn.
    self._full_refresh_pending = true
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
        -- OPDS pseudo-paths have no file behind them. Queueing one sends the
        -- BIM subprocess off to extract metadata from something that isn't on
        -- this device, on every rebuild of the chip (spec 6.6). Filtered here
        -- rather than at the two call sites so the hero-spec queue is covered
        -- by the same guard.
        if self:_isRemoteRecord(fp) then return end
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
            -- 4, not 3: a Collage tile draws up to four member covers, and a
            -- member whose cover was never queued has none to draw -- BIM
            -- extracts lazily, so an unqueued book returns nothing from
            -- getCoverBB however many times the tile asks. The old cap of 3
            -- dates from when series_stack rendered three covers.
            if item.books then
                for i = 1, math.min(4, #item.books) do
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

-- Ceiling on a single "Select all in this shelf" (issue #320). Far above a
-- realistic shelf and well below "every book on the device", so a bulk action
-- stays a bounded operation; the caller says so out loud when it bites rather
-- than quietly selecting a prefix.
local SELECT_ALL_LIMIT = 5000

-- _fetchChipItems(n)
-- Returns up to n items for the current chip (or the expanded-series flat
-- list). Sets opts.lazy_cover=true on the Repo call so the HIT hydration
-- path probes ScaledCoverCache per filepath and skips the BIM zstd decode
-- for books already cached. SpineWidget reads from the cache directly when
-- book.cover_bb arrives nil.
-- want_all: fetch the WHOLE view rather than the visible page. Several sources
-- (Home / folder drills / OPDS / search) are window-fetched - they return one
-- page plus a total, and the caller paginates on that - so their "all_items" is
-- a single page. "Select all in this shelf" needs the real set, and reading the
-- page cache silently selected only what was on screen (issue #320 follow-up:
-- Home reported 59 of 246 books). Everything else already returns the full
-- list, so this only widens the window.
function BookshelfWidget:_fetchChipItems(n, want_all)
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
        local stop     = math.min(offset + (want_all and SELECT_ALL_LIMIT
                                              or self:_viewSize()), total)
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
    local offset    = want_all and 0 or math.max(0, (self._cursor or 1) - 1)
    local LIMIT     = want_all and SELECT_ALL_LIMIT or self:_viewSize()
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
        -- The chip's status filter is inherited by the drill, exactly as its
        -- sort is. A filter is a property of the CHIP ("this shelf shows
        -- unread books"), not of the one listing you happened to be on when
        -- you set it -- so dropping it a level in made finished books
        -- reappear inside every subfolder while the chip's own listing hid
        -- them (#323). getAll applies it to books and to folder cards alike
        -- (_filterAllShapes), so a subfolder holding nothing that matches
        -- disappears here for the same reason it does at the top level.
        return Repo.getAll(tip.payload.path, LIMIT, offset, within,
                           tab and tab.filter or nil, fetch_opts)
    end
    if tip and tip.kind == "opds_nav" then
        -- Drilled into a navigation entry: the same cache-only OPDS branch the
        -- chip's root feed uses, pointed at the subcatalog's own feed_url.
        -- OpdsWindow keys its persisted windows on server_key|feed_url, so each
        -- subcatalog accumulates its own window and backing out then drilling
        -- back in costs no re-fetch. The page table it returns carries
        -- opds_needs_fetch / opds_open_ended exactly as the chip's does, which
        -- is what makes the fetch-on-overshoot and the open-ended pagination
        -- headroom work unchanged down here. filter / sort_priority are nil:
        -- feed order is semantic and the repo's OPDS branch ignores them.
        local pay = tip.payload or {}
        return Repo.getBySource(
            { kind = "opds", id = pay.server_key, feed_url = pay.feed_url },
            nil, nil, offset, LIMIT, fetch_opts)
    end
    if tab then
        return Repo.getBySource(tab.source, tab.filter, tab.sort_priority, offset, LIMIT, fetch_opts)
    end
    return Repo.getBySource({ kind = self.chip }, nil, nil, offset, LIMIT, fetch_opts)
end

-- _groupDisplayMode() -> the style every group tile on this shelf draws
-- itself in: the active chip's override, or nil to take the library default.
--
-- The chip is the unit, so a drill INSIDE a chip keeps the chip's choice --
-- opening a folder on a shelf set to Ribbon shows its subfolders as ribbons
-- too, which is what "this shelf looks like this" has to mean.
--
-- Search results are the exception: they are one list mixing folders,
-- authors, series and genres, reached from whichever chip you happened to be
-- on, and that chip's opinion about its own tiles says nothing about a list it
-- did not produce. They take the library default.
function BookshelfWidget:_groupDisplayMode()
    local tip = self._drilldown_path and self._drilldown_path[#self._drilldown_path]
    if tip and tip.kind == "search" then return nil end
    local TabModel = require("lib/bookshelf_tab_model")
    local tab = TabModel.getById(self.chip)
    return tab and tab.group_display or nil
end

-- _chipViewMode() -> ViewMode.COVERS | ViewMode.LIST | nil
--
-- The active chip's own view-mode pin, or nil to follow the global settings.
--
-- Search results answer nil for the same reason they take the default tile
-- style: a search mixes folders, authors, series and genres from everywhere,
-- so there is no single chip whose opinion applies. Left in, the pin from
-- whichever chip you happened to search from would follow you into results
-- that have nothing to do with it.
function BookshelfWidget:_chipViewMode()
    local tip = self._drilldown_path and self._drilldown_path[#self._drilldown_path]
    if tip and tip.kind == "search" then return nil end
    local TabModel = require("lib/bookshelf_tab_model")
    local tab = TabModel.getById(self.chip)
    return ViewMode.chipOverride(tab and tab[ViewMode.CHIP_KEY])
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
            -- Total - free gives used memory in bytes; convert to MiB.
            -- calcFreeMem already handles MemAvailable fallback (pre-3.14
            -- kernels), so this works on old Kindle devices too.
            out.sysused_mib = math.floor((total - free) / 1024 / 1024 + 0.5)
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
        sysused_mib = slow.sysused_mib,
        ram_mib  = slow.ram_mib,
        disk_free= slow.disk_free,
    }
    -- %books_read / %books_started are LAZY: the finished count's cold start
    -- stats every sidecar in the library (measured at ~1s for 242 books on
    -- the PW5), and paying that on the hero's critical path when no template
    -- mentions the token is a tax on everyone for a feature few use. The
    -- metatable computes on first ACCESS -- i.e. only when a status line,
    -- region or micromodule actually expands the token -- and caches the
    -- answer in the table for the rest of this state's TTL.
    local LAZY = {
        books_read    = "countFinishedBooks",
        books_started = "countStartedBooks",
    }
    setmetatable(_device_state_cache, { __index = function(t, k)
        local fn = LAZY[k]
        if not fn then return nil end
        local v
        local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
        if ok and type(Repo[fn]) == "function" then
            local ok2, n = pcall(Repo[fn])
            v = ok2 and n or nil
        end
        -- Only a real number is cached, so a transient failure retries on
        -- the next read instead of pinning nil for the whole TTL.
        if v ~= nil then rawset(t, k, v) end
        return v
    end })
    _device_state_expires_at = now + DEVICE_STATE_TTL
    return _device_state_cache
end

-- ─── Navigation ───────────────────────────────────────────────────────────────

-- _openOnDoubleTap(book) — direct-open used by the double_tap gesture on
-- covers and the hero. A double tap is an unambiguous "open this book"
-- intent, so it bypasses the single-tap preview/stage behaviour and the
-- "Open with a double tap" two-tap dance — except in selection mode, where
-- it toggles the book like a single tap. Only reachable when the user has
-- KOReader's global double tap enabled (otherwise no double_tap is emitted);
-- fixes #271, where the unhandled double_tap leaked to the parked reader.
function BookshelfWidget:_openOnDoubleTap(book)
    if not book or not book.filepath then return end
    if self._selection:isActive() then
        self._selection:toggle(book.filepath)
        self:_refreshCoverFrame(book.filepath)
        self:_refreshBucket()
        return
    end
    self._tap_selected_fp = nil
    self:_openBook(book)
end

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
    -- OPDS records carry an "OPDS://server/id" pseudo-path, not a file: there
    -- is nothing on disk to hand ReaderUI. Open the catalog book modal instead
    -- (what the feed said about it, plus a download button per format, plus
    -- Open when a previous download is still on disk). Guarded before every
    -- file probe below, and matched on the path prefix so a hero-hydrated
    -- record (flags stripped) is caught too.
    if self:_isRemoteRecord(book) then
        self:_showRemoteBookInfo(book)
        return
    end
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
        -- Opening feedback at TAP time (the Kobo readiness poll below can
        -- take seconds): flush pending paints so the capture sees current
        -- pixels, then squeeze the tapped cover.
        UIManager:forceRePaint()
        pcall(function() self:_paintOpeningEffect(book.filepath) end)
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
    -- Opening feedback: flush pending paints so the capture sees current
    -- pixels, then squeeze the tapped cover (validated against this book;
    -- no-op when the tap didn't land on a visible cover). Painted before
    -- the launch so it also precedes an unpark splice - the squeeze then
    -- reads as the opening motion completing into the page.
    UIManager:forceRePaint()
    pcall(function() self:_paintOpeningEffect(book.filepath) end)
    self:_launchReader(open_path, after_open_callback)
end

-- Hand a real on-disk path to the reader after the pre-read bookkeeping. Shared
-- by the normal open and the deferred Kobo open.
-- Preserves self.chip / page / drilldown / preview across the read (Bookshelf:show
-- restores them on return). Saves rotation so portrait is restored on return (the
-- reader may open in a different rotation, e.g. upside-down on Kobo). Suspends the
-- status timer -- the minute heartbeat is wasted wakeups under the reader.
function BookshelfWidget:_launchReader(open_path, after_open_callback)
    -- Hot parking fast path: the requested book IS the parked document
    -- (the dominant open - continuing the current read). Splice the live
    -- reader back on top instead of a full document load. Kobo virtual
    -- books arrive here with the resolved on-disk path, so the comparison
    -- holds for them too.
    local Park = require("lib/bookshelf_reader_park")
    if Park.isParked() and Park.parkedFile() == open_path then
        if Park.unpark(self, after_open_callback) then return end
    end
    self._pre_read_rotation = Screen:getRotationMode()
    -- Mark that BOOKSHELF launched this book. onCloseDocument's re-show is
    -- gated on this, not on mere stack presence: another home UI (SimpleUI
    -- etc.) can bury the shelf without closing it, and a book opened from
    -- THERE must close back to there, not to us. "You return to whatever
    -- opened the book."
    self._opened_book = true
    -- Drop the memoised hero record: reading changes progress, so the
    -- close-rebuild must re-read fresh state, not the pre-read snapshot (#103).
    self._hero_current_memo = nil
    self:_stopStatusTimer()
    -- Seamless open is tied to the cover-opening effect. With the effect ON,
    -- the flex squeeze (painted at tap time in _openBook) IS the feedback, so
    -- go seamless: suppress KOReader's own "Opening file" InfoMessage
    -- (readerui.lua showReaderCoroutine) and take the lighter "ui" arrival
    -- refresh (onReaderReady issues one full refresh to clear ghosting). With
    -- the effect OFF there's no flex, so DON'T suppress the message -- opening
    -- a book with no feedback at all read as an unresponsive freeze (Reddit).
    -- Let the native "Opening <file>" message show and take the normal arrival.
    local seamless = BookshelfSettings.nilOrTrue("open_cover_effect")
    self._seamless_open_full_pending = seamless or nil
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(open_path, nil, seamless, nil, after_open_callback)
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
            current = self:_hydrateBook(self._preview_book)
            self._hero_book_cache = nil
        end
        self._preview_book = current
    else
        current = self:_currentHeroBook()
    end
    local _perf_t1 = _gettime()
    -- Remote catalog records have no file behind them: enrichStats would
    -- DocSettings:open() and then util.partialMD5 an OPDS:// pseudo-path
    -- before giving up. Harmless (only flush() creates a sidecar) but wasted
    -- on every hero render of a feed entry, and the feed record already
    -- carries everything the hero can show for it.
    if current and not self:_isRemoteRecord(current) then
        Repo.enrichStats(current)
    end
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
        -- A genuine double tap opens directly, skipping the stage-then-open
        -- confirmation (#271). Inert unless the user enabled KOReader's
        -- global double tap.
        on_double_tap = function(b) self:_openOnDoubleTap(b) end,
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
        self._hero_status_strip = nil
        return HeroModules.build(self, content_w, hero_h, PAD, mopts)
    end
    local VerticalSpan = require("ui/widget/verticalspan")
    -- Tight gap under the status line (half the hero PAD); a full PAD read as
    -- slightly too much space above the grid.
    local gap     = math.max(1, math.floor((PAD or 0) / 2))
    local grid_h  = math.max(1, hero_h - status_row:getSize().h - gap)
    local vg = VerticalGroup:new{
        align = "left",
        status_row,
        VerticalSpan:new{ width = gap },
        HeroModules.build(self, content_w, grid_h, PAD, mopts),
    }
    -- Record the status row (index 1 of vg) so the minute tick and device-state
    -- events can swap it in place (#292). In micro mode the hero card IS the
    -- grid, so _gatedRepaint's hero-card path doesn't apply -- without this the
    -- status line (time / battery / wifi) only refreshes on a full grid reload.
    -- with_hairline matches the buildStatusRow arg so a swap re-renders it
    -- identically (the expanded strip records the same shape without hairline).
    self._hero_status_strip = { group = vg, idx = 1, content_w = content_w,
                                with_hairline = true }
    return vg
end

-- Rebuild the hero status strip (micro-module page header OR expanded strip) in
-- place -- same swap-and-scope pattern as HeroModules._swapCell -- so its
-- clock / battery / wifi line stays current without re-rolling the grid or
-- rebuilding the whole strip (#292). Both surfaces record self._hero_status_strip
-- so this one path serves both. Returns true on success.
function BookshelfWidget:_swapHeroStatusStrip()
    local rec = self._hero_status_strip
    local vg  = rec and rec.group
    local old = vg and vg[rec.idx]
    if not old then return false end
    local current = (self._preview_book and self._preview_book.filepath
                     and Repo.buildBook(self._preview_book.filepath))
                     or self._preview_book
                     or self:_currentHeroBook()
    -- Fresh device read (see the same invalidation in _gatedRepaint).
    _device_state_expires_at = 0
    local new_row = HeroCard.buildStatusRow(current, self:_buildDeviceState(),
                                            rec.content_w, rec.with_hairline)
    if not new_row then return false end
    vg[rec.idx] = new_row
    if vg.resetLayout then vg:resetLayout() end
    if old.free then
        UIManager:nextTick(function() pcall(function() old:free() end) end)
    end
    local scope = old.dimen and old.dimen:copy()
    if scope then
        UIManager:setDirty(self, function() return "ui", scope end)
    else
        UIManager:setDirty(self, "ui")
    end
    return true
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
    if status_row then
        outer[#outer + 1] = status_row
        -- Record for the in-place status swap (#292), same as the micro page --
        -- one path keeps both surfaces' clock/battery/wifi line current.
        self._hero_status_strip = { group = outer, idx = 1, content_w = content_w,
                                    with_hairline = false }
    end
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

-- Effective label mode for the REGULAR (non-expanded) grid, or nil when the
-- "Labels under grid covers" toggle is off. Reuses the expanded-shelf label
-- controls (content mode + font scale, both already in the Text size menu),
-- defaulting to Title when the shared mode is "none" so turning the toggle on
-- always shows something. The expanded shelf keeps its own path (it reads the
-- setting directly and treats "none" as no labels).
-- Unified label mode for every shelf surface (regular grid AND expanded
-- shelf): the "Show text below covers" mode in Cover display. Returns
-- "title"/"author"/"series", or nil for None (no label strip; covers claim
-- the full row). Defaults to Title when unset - a deliberate 4.0 default
-- change; the stored key keeps its 3.x name so explicit choices carry over,
-- and the old grid_shelf_labels checkbox is retired (its content already
-- followed this mode, so the mode alone now decides).
function BookshelfWidget:_shelfLabelMode()
    local mode = BookshelfSettings.read("expanded_shelf_label")
    if mode == "none" then return nil end
    if mode ~= "author" and mode ~= "series" then mode = "title" end
    return mode
end

-- ─── List view ───────────────────────────────────────────────────────────────

-- _viewMode() — "covers" or "list". The single answer to "which presentation
-- am I rendering", so no site has to re-derive it from the two persisted
-- booleans. See lib/bookshelf_view_mode.lua for the model.
--
-- The counterfactual pin is checked FIRST and short-circuits everything: a
-- caller inside _asCoverGrid is asking what the cover grid would do here, and
-- must get that answer whatever the user's settings say. Nothing calls
-- _rebuild under the pin, so the mode stamped into _shelf_dims.view_mode is
-- always the real one.
function BookshelfWidget:_viewMode()
    if _covers_pin > 0 then return ViewMode.COVERS end
    -- A chip pinned to either mode wins outright, over all three globals.
    --
    -- Resolved HERE rather than as a sixth argument to ViewMode.effective:
    -- effective() answers "what do the three global settings say", which is a
    -- pure question about three booleans, and threading a chip lookup through
    -- it would make that resolver need a TabModel. This function is already the
    -- one place that answers "which mode am I in"; the chip sits beside the
    -- pin rather than inside the settings maths.
    --
    -- Note this is the only thing in the model that can force COVERS. The
    -- globals and the folder key can only ever turn a list ON; a chip is where
    -- a reader says "not here", explicitly and per shelf.
    -- Search results carry their OWN mode, decoupled from every chip the
    -- same way their content is: covers by default (the pre-list-view look),
    -- switchable by long-pressing the Search results pill. Only while the
    -- results themselves are on screen -- drill INTO a result and the
    -- normal chip resolution below takes over again.
    if self:_isSearchResults() then
        local m = BookshelfSettings.read("search_view_mode")
        if m == ViewMode.LIST then return ViewMode.LIST end
        if m == ViewMode.AUTO then
            return ViewMode.effective(self._expanded, true)
        end
        return ViewMode.COVERS
    end
    local chip_mode = self:_chipViewMode()
    if chip_mode == ViewMode.AUTO then
        return ViewMode.effective(self._expanded, self:_isDrilledIn())
    end
    if chip_mode then return chip_mode end
    -- Unset is COVERS: the shelf a user who never opened the Show as picker
    -- has always had. Auto must be chosen, never inherited.
    return ViewMode.COVERS
end

-- _isSearchResults() — is the shelf showing search RESULTS right now?
-- Deepest entry only: a drill into an author found via search is that
-- author's shelf, not the results page.
function BookshelfWidget:_isSearchResults()
    local path = self._drilldown_path
    local tip = path and path[#path]
    return tip ~= nil and tip.kind == "search"
end

-- Long-press on the Search results pill: pick the results' view mode.
-- A global setting rather than per anything -- search is one surface.
function BookshelfWidget:_showSearchViewModePicker()
    local ButtonDialog = require("ui/widget/buttondialog")
    local current = BookshelfSettings.read("search_view_mode")
    if current ~= ViewMode.LIST and current ~= ViewMode.AUTO then
        current = ViewMode.COVERS
    end
    local dialog
    local function pick(value)
        return function()
            UIManager:close(dialog)
            -- Covers is the default, stored as absence like a chip's pin.
            BookshelfSettings.save("search_view_mode",
                value ~= ViewMode.COVERS and value or nil)
            BookshelfSettings.flush()
            self:_rebuild()
            UIManager:setDirty(self, "ui")
        end
    end
    local function row(text, value)
        local mark = (current == value) and "\xE2\x9C\x93 " or ""
        return { { text = mark .. text, callback = pick(value) } }
    end
    dialog = ButtonDialog:new{
        title = _("Show search results as"),
        buttons = {
            row(_("Covers"), ViewMode.COVERS),
            row(_("List"), ViewMode.LIST),
            row(_("Auto"), ViewMode.AUTO),
        },
    }
    UIManager:show(dialog)
end

-- _isDrilledIn() — is the shelf showing the CONTENTS of something the user
-- opened, rather than a chip's top level?
--
-- Any drill counts, not only a filesystem folder: a series, an author, a genre
-- and a tag all drill the same way and all put the user in the same "I am
-- inside one thing now" place, which is the state the setting is about. The
-- setting's label says "folders and stacks" for that reason.
function BookshelfWidget:_isDrilledIn()
    return self._drilldown_path ~= nil and #self._drilldown_path > 0
end

function BookshelfWidget:_isListMode()
    return ViewMode.isList(self:_viewMode())
end

-- _flipViewMode() -- the footer-hold gesture: pin THIS CHIP to the other mode.
--
-- It used to write the shelf-wide boolean for the current state (expanded or
-- collapsed), because those globals were the model. They are gone -- the mode
-- lives on the chip, over one fixed Auto policy (lib/bookshelf_view_mode.lua)
-- -- so the gesture now writes the same pin the Shelf style dialog writes:
-- whatever is on screen flips, here, for this chip.
--
-- Always effective, which the old one was not: a global write could be
-- outranked by a chip pin and appear to do nothing, and needed a notification
-- to explain which setting was really deciding. A pin outranks everything, so
-- the explanations went with the globals. The one exception is a search
-- drill, where chip pins are deliberately not consulted; the gesture is a
-- no-op there and says so instead of silently writing something invisible.
--
-- Synchronous save: a deliberate, user-visible preference change is exactly
-- the action boundary settings flush at.
function BookshelfWidget:_flipViewMode()
    if self:_isSearchResults() then
        -- The same gesture semantics as everywhere else: flip whatever is on
        -- screen. It writes the search results' own mode (the maintainer's
        -- ruling), never a chip pin; the three-way picker with Auto lives on
        -- the Search results pill's long-press instead.
        local target = self:_isListMode() and ViewMode.COVERS or ViewMode.LIST
        BookshelfSettings.save("search_view_mode",
            target ~= ViewMode.COVERS and target or nil)
        BookshelfSettings.flush()
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        return true
    end
    self:_markOpdsNav()
    local anchor_fp = self._page_items and _itemFilepath(self._page_items[1])
    local TabModel = require("lib/bookshelf_tab_model")
    local target = self:_isListMode() and ViewMode.COVERS or ViewMode.LIST
    local tabs, hit = TabModel.load(), nil
    for _i, t in ipairs(tabs or {}) do
        if t.id == self.chip then hit = t break end
    end
    if hit then
        hit[ViewMode.CHIP_KEY] = target
        TabModel.save(tabs)
    end
    logger.dbg("[bookshelf perf] view mode pinned: chip=" .. tostring(self.chip)
        .. " -> " .. tostring(target))
    if anchor_fp then
        local gidx = self:_globalIndexOfFilepath(anchor_fp)
        if gidx then self:_setCursorToShow(gidx) end
    end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    return true
end

-- _listLines() — the list's line LAYOUT: { show_cover, lines }, where each
-- line is a token template plus its own face, size, weight, case and
-- alignment. The cover is a boolean and the line COUNT is a user setting, so
-- nothing here may assume two. See lib/bookshelf_list_lines.lua's header for
-- the saved shape.
--
-- The preview override outranks the saved value while the line editor is open,
-- so the shelf behind the dialog shows the draft without a settings write per
-- keystroke. It is the ONE hook the editor needs, precisely because this
-- function is the only read: row heights, the row budget, the cover cell and
-- the renderer all come through here, so overriding it moves all four together.
-- An override that only reached the renderer would draw draft text into rows
-- measured for the saved lines.
function BookshelfWidget:_listLines()
    if self._list_lines_preview then return self._list_lines_preview end
    return require("lib/bookshelf_list_lines").layout()
end

-- _previewListLines(layout) — show `layout` instead of the saved lines, or
-- clear the override when it is nil. Rebuilds, because the line set decides
-- the row HEIGHT and therefore how many rows fit: a repaint alone would leave
-- the page holding the wrong number of items.
function BookshelfWidget:_previewListLines(layout)
    self._list_lines_preview = layout
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- _listRowHeight() — height of one list row at the current font settings.
-- Every list-mode geometry site must call THIS rather than re-deriving, or the
-- row-count budget and the render disagree about how tall a row is -- the exact
-- failure mode #329 was on the cover grid.
--
-- Both terms come from ListRow, which asks lib/bookshelf_band_metrics.lua for
-- the band on the LIST key: the row measures like a chip (same shape, same
-- face) on its own setting, and a second copy of that derivation here is
-- exactly the drift the split is designed to prevent.
--
-- The one thing the line layout decides is HOW MANY LINES there are and how
-- tall each one is: every line carries its own point size, so a row is the sum
-- of what its lines really measure and the budget has to ask. It is not the old
-- has-cover branch coming back -- covers do not enter this at all, so turning
-- them off cannot make rows taller the way it once did.
--
-- Every term is ListRow's or ListGeom's; this function only wires them
-- together and asks the line layout the one question it owns. The per-line
-- face resolution and MEASUREMENT (and its memo) live in ListRow.lineHeights
-- because the renderer needs exactly the same numbers -- the budget and the
-- renderer resolving the same faces through two paths is how they come to
-- disagree.
-- _listNaturalRowHeight() — as tall as the configured lines want to be.
--
-- What the row height USED to be, full stop, and now the DEFAULT row count's
-- basis: with nothing saved, the shelf shows as many rows as the configured
-- lines naturally give. Not a migration -- none is owed, list mode has never
-- been released -- but a better starting point than a constant, because it
-- follows the lines the reader has actually set up.
-- _listGeomMemo(key, compute) -- per-rebuild cache for the geometry chain.
--
-- _listRowHeight reaches _listBand, the collapsed hero split and the minimum
-- row height, and one rebuild asks for it from seven call sites -- the perf
-- log showed the same _maxShelfRows computation six-plus times per rebuild.
-- Everything cached here is a pure function of settings and screen geometry,
-- both of which only change through paths that call _rebuild, which clears
-- the table.
function BookshelfWidget:_listGeomMemo(key, compute)
    local memo = self._list_geom_memo
    if not memo then memo = {}; self._list_geom_memo = memo end
    local hit = memo[key]
    if hit ~= nil then return hit end
    local v = compute()
    memo[key] = v
    return v
end

function BookshelfWidget:_listNaturalRowHeight()
    local ListGeom = require("lib/bookshelf_list_geom")
    local ListRow  = require("lib/bookshelf_list_row")
    -- The ring reservation is ListRow's own (it insets by RING on every side so
    -- selecting a row never moves a pixel of its content), read from ListRow
    -- rather than restated, so the row height and the row layout can't drift
    -- apart. Same for the padding trim and the leading: ListRow.pageLayout
    -- lays the bands out from the same three numbers.
    -- MEASURED AT 100, not at the reader's text size. This figure only ever
    -- decides the DEFAULT row count, and a default that moved with the font
    -- would put the density model back: bigger type, taller natural row, fewer
    -- rows -- "it should now control the size of text lines within the rows
    -- without changing the row height".
    --
    -- So the default is a property of the LINES -- how many there are and what
    -- sizes they are set to -- and the text size slides underneath it. Once a
    -- reader picks a row count none of this is consulted at all.
    return self:_listGeomMemo("natural", function()
        return ListGeom.rowHeight{
            chip_h       = ListRow.chipRowHeight(100),
            line_heights = ListRow.lineHeights(self:_listLines().lines, 100),
            ring         = ListRow.RING,
            text_pad     = ListRow.TEXT_PAD,
            lead         = ListRow.INTRA_LEAD,
        }
    end)
end

-- _listMinRowHeight() — the shortest a row is allowed to be: one line of the
-- FIRST line's face.
--
-- Line 1 is the one line every row keeps (ListGeom.linePriority), so a row
-- that cannot hold it cannot hold anything. This is what bounds the row COUNT:
-- ask for more rows than this many and the count, not the row, gives way.
function BookshelfWidget:_listMinRowHeight()
    local ListGeom = require("lib/bookshelf_list_geom")
    local ListRow  = require("lib/bookshelf_list_row")
    return self:_listGeomMemo("min", function()
        local heights = ListRow.lineHeights(self:_listLines().lines)
        return ListGeom.rowHeight{
            chip_h       = ListRow.chipRowHeight(),
            line_heights = { heights[1] or 0 },
            ring         = ListRow.RING,
            text_pad     = ListRow.TEXT_PAD,
            lead         = ListRow.INTRA_LEAD,
        }
    end)
end

-- _listRows() — how many rows the reader asked for, clamped to what fits.
--
-- THE INVERSION. The row height used to come from the font and the row count
-- from whatever then fitted, which meant one control moved both things:
-- "increasing or decreasing the rows can make the font too small or too large,
-- these controls should be separate." Now the COUNT is chosen and the height
-- follows from it, so the font is free to be whatever is legible.
--
-- Per chip first, exactly like the column count: a catalogue of covers and a
-- shelf of text want different densities. nil means "not chosen", and the
-- caller falls back to the natural height rather than to a constant -- see
-- _listNaturalRowHeight.
function BookshelfWidget:_listRows(max_rows)
    local n = self:_chipListValue("list_rows")
    if type(n) ~= "number" then return nil end
    n = math.floor(n)
    if n < 1 then n = 1 end
    if max_rows and n > max_rows then n = max_rows end
    return n
end

-- _chipListValue(key) -> the density number in force here.
--
-- The chip's own override first -- set by a pinch or by the chip's
-- shelf-style dialog -- then the library key. The preset layer that sat
-- between them is gone with the preset feature itself: with rows and columns
-- per chip and the lines degrading to fit the row, a saved layout had nothing
-- left to carry.
function BookshelfWidget:_chipListValue(key)
    local tab = require("lib/bookshelf_tab_model").getById(self.chip)
    local own = tab and tab[key]
    if type(own) == "number" then return own end
    return BookshelfSettings.read(key)
end

-- _setChipListRows(n) — write the row count onto THIS chip.
--
-- Deferred, like the column nudge: a synchronous flush is hundreds of
-- milliseconds on Kindle flash and would land between the gesture and the
-- repaint. The in-memory tab updates immediately, so the rebuild that follows
-- already sees the new count.
function BookshelfWidget:_setChipListRows(n)
    self:_setChipDensity("list_rows", n)
end

-- _setChipDensity(key, n) -- write a density number onto THIS chip, deferred.
function BookshelfWidget:_setChipDensity(key, n)
    local TabModel = require("lib/bookshelf_tab_model")
    local tabs = TabModel.load()
    local hit
    for _i, t in ipairs(tabs or {}) do
        if t.id == self.chip then hit = t break end
    end
    -- No tab of that id -- a drilldown, a search, the Kobo shelf -- so the
    -- library default is the only thing there is to move.
    if not hit then
        BookshelfSettings.saveDeferred(key, n)
        return
    end
    hit[key] = n
    TabModel.saveDeferred(tabs)
end

-- _listRowHeight() — the band divided by the reader's row count.
--
-- Taken from the COLLAPSED band whatever the shelf is doing, so expanding the
-- shelf reveals more rows rather than growing the ones already there. A row
-- height that moved when the hero collapsed would undo the whole point of
-- setting it once.
function BookshelfWidget:_listRowHeight()
    return self:_listGeomMemo("row_h", function()
        return self:_listRowHeightUncached()
    end)
end

function BookshelfWidget:_listRowHeightUncached()
    local ListGeom = require("lib/bookshelf_list_geom")
    local b   = self:_listBand(false, self._chip_bar_hidden)
    local gap = self:_listRowGap()
    local min_row = self:_listMinRowHeight()
    local max_rows = ListGeom.rowsThatFit(b.band - 2 * b.min_edge_pad,
                                          min_row, gap)
    local rows = self:_listRows(max_rows)
    if not rows then return self:_listNaturalRowHeight() end
    -- The standard pad at each end comes off FIRST, then the rest is divided.
    -- Dividing the whole band and letting the margins be the remainder is what
    -- made the top gap a modular residue once before.
    local usable = b.band - 2 * b.base_top_pad
    local pitch  = math.floor((usable + gap) / rows)
    return math.max(min_row, pitch - gap)
end

-- _listRowGap() — the vertical gap between two list rows.
--
-- One number, declared once in ListGeom.ROW_GAP_DP and scaled here, by
-- ListRow.divider, and by the pure row-count test. Restating it as
-- Size.line.thin here (which is what it scales to) would leave the budget and
-- the rule agreeing only by coincidence -- and would let the test keep passing
-- while the widget spent PAD per row, which is the exact hole this closes.
function BookshelfWidget:_listRowGap()
    local ListGeom = require("lib/bookshelf_list_geom")
    return Screen:scaleBySize(ListGeom.ROW_GAP_DP)
end

-- _rowGap(PAD) — the after-row spacing for whichever mode is live. One helper
-- so the row-count budget (_maxRows / _maxShelfRows) and the layout that lays
-- the rows down (_rebuild) can never disagree about it; they disagreed about
-- row HEIGHT once already and it cost a clipped bottom row.
function BookshelfWidget:_rowGap(PAD)
    if self:_isListMode() then return self:_listRowGap() end
    return PAD
end

-- _shelfCallbacks() — the tap/hold callback set both row builders share, plus
-- the selected-filepath both need. Extracted from _buildShelfRows so cover mode
-- and list mode dispatch through ONE copy: a divergence here would mean a hold
-- opens the detail view on a cover but not on a row, which is the kind of
-- inconsistency users report as "list view is broken" without being able to say
-- how. The closures below are unchanged from their long-standing inline form.
function BookshelfWidget:_shelfCallbacks()
    local bw = self
    return {
        -- Highlight the selected book's cover in BOTH modes (expanded grid and
        -- 2-row), so the same book stays highlighted across an expand/collapse
        -- toggle and matches whatever the hero previews. _selectedFilepath
        -- unifies the d-pad focus cell, the open-double pending tap, and the
        -- hero preview.
        selected_filepath = self:_selectedFilepath(),
        -- Expanded mode is "browse to open" — single tap opens the book.
        -- Normal mode is "preview, then commit" — tap shelf cover stages it
        -- in the hero, tap hero opens.
        on_book_tap       = function(b, tap_t)
            if bw._selection:isActive() then
                -- Remote (catalog) records can't join a bulk selection: the
                -- bulk actions all operate on local files. Reachable when a
                -- selection started on a local chip and the user swiped to an
                -- OPDS chip - say why the tap did nothing rather than
                -- silently ignoring it.
                if bw:_isRemoteRecord(b) then
                    UIManager:show(require("ui/widget/notification"):new{
                        text = _("Catalog books can't be selected."),
                    })
                    return
                end
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
                    bw._preview_book = bw:_hydrateBook(b)
                    bw:_opdsEnsurePreviewCover(bw._preview_book)
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
                -- A remote (OPDS) book that is ALREADY the previewed hero
                -- book: the second tap is the commit gesture, and for a
                -- catalogue book the commit is the download modal (mirrors
                -- local books, where the second gesture - hero tap or double
                -- tap - opens the book). Local books keep preview-only here.
                -- In micro-module hero mode the tap swaps the hero back to the
                -- book instead (the preview state is stale there), so the modal
                -- needs a book hero actually showing.
                if bw:_isRemoteRecord(b) and bw._hero_mode ~= "micro"
                        and bw._preview_book
                        and bw._preview_book.filepath == b.filepath then
                    bw:_showRemoteBookInfo(b)
                    return
                end
                bw:_previewBook(b, tap_t)
            end
        end,
        -- Double tap on a shelf cover opens directly (#271), whether the
        -- cover is a bare SpineWidget (collapsed) or wrapped in a titled
        -- slot (expanded).
        on_book_open      = function(b) bw:_openOnDoubleTap(b) end,
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
        on_opds_nav_tap   = function(n) bw:_expandOpdsNav(n) end,
        on_opds_nav_hold  = function(n) bw:_openOpdsNavMenu(n) end,
    }
end

-- The callback keys _shelfCallbacks supplies that a row builder copies through
-- verbatim (selected_filepath is handled separately - both builders pass it
-- under the same name but alongside their own layout opts).
local SHELF_CALLBACK_KEYS = {
    "on_book_tap", "on_book_open", "on_book_hold",
    "on_series_tap", "on_series_hold", "on_author_tap", "on_author_hold",
    "on_genre_tap", "on_genre_hold", "on_tag_tap", "on_tag_hold",
    "on_language_tap", "on_language_hold", "on_folder_tap",
    "on_folder_hold", "on_opds_nav_tap", "on_opds_nav_hold",
}

-- _buildListRows — the list-mode counterpart of _buildShelfRows. Returns the
-- same thing: n_rows widgets of uniform height for inner_vgroup. That sameness
-- is what lets _swapShelvesInPlace's row-swap loop stay mode-agnostic.
--
-- items are sliced (r-1)*n_cols + c, the SAME formula the cover grid uses --
-- which at the one-column default is just items[r], and is why this file's
-- pagination never had to know the difference.
--
-- Each column is an independent ListRow of its share of the width, laid side by
-- side with the standard gap. Sharing one pageLayout across the columns would
-- be wrong: text_w is solved from the row width, so both halves have to be
-- solved at the HALF width or the second column's text runs off the row.
function BookshelfWidget:_buildListRows(items, content_w, row_h, gap, n_rows)
    local ListRow = require("lib/bookshelf_list_row")
    -- Required here rather than at file scope, matching every other user of it
    -- in this file. HorizontalGroup IS a file-scope local; HorizontalSpan is
    -- not, and reaching for it as a global compiles fine and blows up on the
    -- first multi-column render.
    local HorizontalSpan = require("ui/widget/horizontalspan")
    n_rows = n_rows or 1
    local n_cols = self:_listCols()
    local col_w  = math.max(1,
        math.floor((content_w - gap * (n_cols - 1)) / n_cols))
    local lines = self:_listLines()
    -- Reuse the EXACT callback table _buildShelfRows assembles, so tap,
    -- double-tap-to-open, hold-for-detail, drill-in and bulk selection behave
    -- identically in both modes with no second copy of that logic.
    local shared = self:_shelfCallbacks()
    local row_opts = {
        width             = col_w,
        height            = row_h,
        gap               = gap,
        lines             = lines,
        selected_filepath = shared.selected_filepath,
        selection         = self._selection,
        -- Whether a bulk selection is RUNNING, as distinct from which items are
        -- in it. It has to reach pageLayout rather than the per-row render
        -- because it adds a checkbox gutter, and the gutter comes out of the
        -- text width -- a per-row decision would have each row solving a
        -- different width for the same page.
        selection_active  = self._selection ~= nil
                            and self._selection.isActive ~= nil
                            and self._selection:isActive() == true,
        -- The chip's folder style, for the fallback tile a group row draws
        -- when it has no member covers to fan (ListGroup.tile). Same value the
        -- cover grid passes its own rows, so the two surfaces render the same
        -- group the same way.
        group_display     = self:_groupDisplayMode(),
    }
    for _k = 1, #SHELF_CALLBACK_KEYS do
        local name = SHELF_CALLBACK_KEYS[_k]
        row_opts[name] = shared[name]
    end
    -- The line bands, thumbnail size and each line's face are page-constant, so
    -- solve them ONCE here rather than per row: the per-row path would re-run a
    -- font lookup plus a TextWidget probe for every line, n_rows times over,
    -- for n_rows identical answers.
    row_opts.layout = ListRow.pageLayout(row_opts)
    local rows = {}
    for r = 1, n_rows do
        if n_cols == 1 then
            row_opts.item = items[r]
            rows[r] = ListRow.new(row_opts)
        else
            -- A HorizontalGroup of column widgets. ListRow.new already returns
            -- a full-height, full-col_w widget for a nil item (a sized blank),
            -- so a ragged last row needs no special case here -- the empty
            -- halves are spacers that keep the group the right width.
            local hg = HorizontalGroup:new{ align = "center" }
            for c = 1, n_cols do
                if c > 1 then
                    hg[#hg + 1] = HorizontalSpan:new{ width = gap }
                end
                row_opts.item = items[(r - 1) * n_cols + c]
                local cell = ListRow.new(row_opts)
                -- _rebuild stashes rows[1].cover_w as the real thumbnail size
                -- the preloader warms next-page covers at. Carry it up from the
                -- first cell: without it the stash reads nil and
                -- _currentSlotDims falls back to re-deriving the same number,
                -- which is correct but is a second derivation of a value we are
                -- holding.
                hg.cover_w = hg.cover_w or cell.cover_w
                hg.cover_h = hg.cover_h or cell.cover_h
                hg[#hg + 1] = cell
            end
            rows[r] = hg
        end
    end
    return rows
end

-- _buildShelfRows — top + bottom shelf row from the page's items slice.
-- Extracted so _swapShelvesInPlace can construct them without re-running
-- the full _rebuild path (which would also rebuild hero + chips).
function BookshelfWidget:_buildShelfRows(items, content_w, shelf_h, PAD, n_rows)
    n_rows = n_rows or 2
    local bw = self
    -- Tap/hold handlers and the selected filepath now come from
    -- _shelfCallbacks, shared verbatim with the list-mode row builder.
    -- on_book_tap branches on _expanded so a tap on a shelf book in
    -- expanded mode auto-restores the full hero AND stages the tapped
    -- book as the preview — single tap collapses-back-and-shows-it. In
    -- normal mode it's the existing _previewBook (preview-only) behaviour.
    local shared = self:_shelfCallbacks()
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
    -- Labels under covers: one unified mode for both surfaces (Cover display's
    -- "Show text below covers"); nil = None = no strip anywhere.
    local label_mode = self:_shelfLabelMode()
    local row_opts = {
        width             = content_w,
        height            = shelf_h,
        gap               = PAD,
        n_slots           = n_cols,
        selected_filepath = shared.selected_filepath,
        selection         = bw._selection,
        show_titles       = (label_mode ~= nil),
        label_mode        = label_mode,
        in_series         = in_series,
        group_display     = self:_groupDisplayMode(),
    }
    for _k = 1, #SHELF_CALLBACK_KEYS do
        local name = SHELF_CALLBACK_KEYS[_k]
        row_opts[name] = shared[name]
    end
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
            bw:_markOpdsNav()
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
            bw:_markOpdsNav()
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
    -- Open-ended OPDS feed: total_pages counts only the cached window, so it's
    -- a lower bound. The label gains its "+", "last" goes dark (there is no
    -- known last page to jump to), and forward stepping stays live at the end
    -- of the window, since that step is what fetches the next feed page.
    local open_ended       = self._opds_open_ended == true
    -- The "can I go forward" test must NOT reuse _maxCursor's answer here.
    -- _maxCursor withholds the open-ended headroom unless a navigation is
    -- already in flight (deliberately -- it is also the clamp, and a clamp
    -- must never bless a cursor with no fetch behind it), but the footer is
    -- rebuilt on plenty of passive paths too -- the cover-landing rebuild, the
    -- fetch tail, the file poll, relaunch, _swapFooterInPlace from the d-pad
    -- focus sites. On every one of those the flag is nil, so the chevron would
    -- render dead on the last cached page and the only forward affordance for
    -- tap and d-pad users would be gone. The tap itself is safe: step(1) arms
    -- before _advanceCursor, so the headroom is there when it is acted on.
    local can_step_forward = self._cursor < max_cursor_now or open_ended
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
        -- "Page %1 of %2+" is the SAME source string bookshelf_pagination.lua
        -- uses for its open-ended nav, so the two share one POT entry.
        text = open_ended and T(_("Page %1 of %2+"), self.page, total_pages)
                           or string.format(_("Page %d of %d"), self.page, total_pages),
        -- Adopt the Bookshelf UI font (a FontList-resolvable face), like the
        -- rest of the chrome; falls back to cfont in follow mode. Button
        -- resolves text_font_face via Font:getFace, and the UI-font setting
        -- stores a resolvable face, so the name can be passed straight in.
        text_font_face = BFont.getUIFontFace() or "cfont",
        text_font_size = 15,
        width         = slot(SLOT_PAGE),
        callback      = function() bw:_openPageJump() end,
        -- Long-press: flip covers <-> list. The only footer button that
        -- reached this file without a hold -- prev/next already spend theirs
        -- on skip-ten-pages.
        hold_callback = function() bw:_flipViewMode() end,
        margin        = bm("page"), bordersize = bs("page"), radius = br("page"),
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
    -- On an open-ended feed "last page" is a QUESTION, not a jump: we do not
    -- know where the feed ends, and the only way to find out is to walk it.
    -- The button used to go dark here, which is honest about the jump and
    -- unhelpful about the question - "how big is this category?" had no answer
    -- available anywhere in the UI. It now runs the walk, which is bounded
    -- only by the feed itself and stoppable at any point, and lands on the
    -- last page that has books either way.
    local last = Button:new{
        icon = "chevron.last", icon_width = chev_size, icon_height = chev_size,
        width      = slot(SLOT_EDGE),
        callback   = open_ended and function() bw:_opdsWalkToEnd() end
                                 or go_page(total_pages),
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
-- _jumpScanList() -> items, sort_key, via
-- The ordered list "Go to letter" scans, for the view the user is ACTUALLY
-- looking at, plus the sort key that order is keyed on.
--
-- The distinction is the whole of #307: a drilled folder shows its OWN
-- listing, but this used to fetch the CHIP's source unconditionally -- so a
-- jump inside a subfolder matched against the parent's books and reported "No
-- items start with X" for a letter sitting on screen. The branches below
-- mirror _fetchChipItems one for one, and must keep doing so: whatever the
-- shelf renders is what a letter has to be found in.
--
-- Fetches are light_only -- we read sort-key fields to find a page boundary
-- and never render these records, so the repo serves light metadata (one
-- batched SELECT) rather than hydrating thousands of full Book records.
-- lazy_cover stays set as belt-and-braces for any path that ignores it.
function BookshelfWidget:_jumpScanList()
    local TabModel   = require("lib/bookshelf_tab_model")
    local tab        = TabModel.getById(self.chip)
    local sp         = tab and tab.sort_priority
    local chip_key   = sp and sp[1] and sp[1].key
    local tip        = self._drilldown_path[#self._drilldown_path]
    local fetch_opts = { lazy_cover = true, light_only = true }
    local BIG_LIMIT  = math.max(self._total_items or 0, 10000)

    -- Group drill (series / author / genre / tag / format / rating /
    -- language): the books are already hydrated on the payload, in the order
    -- the shelf shows them. _applyWithinGroupSort put them in the chip's
    -- level-2+ order, so the matcher reads THAT level; with no level 2 the
    -- group's own default order stands and the chip's level 1 is the best
    -- available guess, as before.
    if tip and tip.payload and tip.payload.books then
        local within_key = sp and sp[2] and sp[2].key
        return tip.payload.books, within_key or chip_key, "drilldown-payload"
    end

    -- Folder drill: the drilled path's listing, with the chip's filter and
    -- its level-2+ sort -- the same call _fetchChipItems makes, unpaginated.
    if tip and tip.kind == "folder" then
        local within
        if sp and #sp >= 2 then
            within = {}
            for i = 2, #sp do within[#within + 1] = sp[i] end
        end
        local ok, fetched = pcall(Repo.getAll, tip.payload.path, BIG_LIMIT, 0,
                                  within, tab and tab.filter or nil, fetch_opts)
        -- getAll falls back to the "all" tab's priority when handed none, so
        -- ask it the same question to name the key the list came back in.
        local eff = within or Repo.getSortPriority("all")
        return ok and fetched or nil,
               eff and eff[1] and eff[1].key,
               ok and "getAll-folder" or ("getAll-ERR:" .. tostring(fetched))
    end

    -- OPDS subcatalog drill: the subcatalog's own cached window. Feed order
    -- is semantic (the repo ignores sort_priority here), so there is no sort
    -- key to name -- sortKeyValue falls back to a title-ish value.
    if tip and tip.kind == "opds_nav" then
        local pay = tip.payload or {}
        local ok, fetched = pcall(Repo.getBySource,
            { kind = "opds", id = pay.server_key, feed_url = pay.feed_url },
            nil, nil, 0, BIG_LIMIT, fetch_opts)
        return ok and fetched or nil, nil,
               ok and "getBySource-opds_nav"
                   or ("getBySource-ERR:" .. tostring(fetched))
    end

    -- No drill (and search results, which have no alphabetical order of
    -- their own): the chip's own source.
    local ok, fetched = pcall(function()
        if tab then
            return Repo.getBySource(tab.source, tab.filter, tab.sort_priority,
                                    0, BIG_LIMIT, fetch_opts)
        end
        return Repo.getBySource({ kind = self.chip }, nil, nil,
                                0, BIG_LIMIT, fetch_opts)
    end)
    return ok and fetched or nil, chip_key,
           ok and "getBySource" or ("getBySource-ERR:" .. tostring(fetched))
end

function BookshelfWidget:_jumpToLetterPrefix(prefix)
    local InfoMessage = require("ui/widget/infomessage")
    local SortEngine  = require("lib/bookshelf_sort_engine")
    if not prefix or prefix == "" then return end
    local p = prefix:lower()
    local _t0 = _gettime()

    local items, sort_key, fetched_via = self:_jumpScanList()
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
    local first_row = {
        {
            text     = _("Search\xE2\x80\xA6"),  -- Search…
            callback = function()
                local s = dialog:getInputText()
                UIManager:close(dialog)
                -- Route by view: an OPDS view's books aren't on disk, so the
                -- local library search would answer the wrong question.
                local t = bw:_opdsEffectiveTab()
                if t then bw:_opdsOpenSearchDialog(t, s) else bw:_openSearchDialog(s) end
            end,
        },
        {
            text     = _("Go to letter"),
            callback = function()
                local s = dialog:getInputText()
                if s == "" then return end
                if tonumber(s) ~= nil then return end
                UIManager:close(dialog)
                bw:_jumpToLetterPrefix(s)
            end,
        },
    }
    dialog = InputDialog:new{
        title       = _("Enter text, letter or page number"),
        -- Start empty: pre-filling the current page number just forced the
        -- user to clear it before typing anything else. Show the current
        -- page as a placeholder hint instead so the context is still there.
        input       = "",
        input_hint  = tostring(bw.page),
        description = string.format(_("(a - z) or (1 - %d)"), total),
        buttons = {
            first_row,
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

-- Shelf-pagination "wipe" animation (e-ink only, see bookshelf_page_wipe.lua).
-- _pageAnimSteps() resolves the "shelf_page_animation" setting to a step count,
-- or nil when the animation should not run (off, or not an e-ink screen — on
-- LCD the per-strip refreshes coalesce so nothing shows and it's wasted work).
local PageWipe = require("lib/bookshelf_page_wipe")
-- Delegates to the shared resolver: e-ink + the "shelf_page_animation" setting,
-- which now governs shelf pagination, chip-bar pagination, and the start menu.
local function _pageAnimSteps()
    return PageWipe.resolveSteps()
end

-- _swapShelvesInPlace — pagination fast-path. Rebuilds only the shelf rows
-- + footer, leaving hero + chips intact. Avoids redundant work (the chips
-- never change with self.page; the hero only changes with _preview_book)
-- AND avoids the use-after-free path where _buildHero rebuilds a SpineWidget
-- against a freed BIM bb on _preview_book.cover_bb.
function BookshelfWidget:_swapShelvesInPlace()
    local _perf_t0 = _gettime()
    -- Page-turn animation direction, set by the paginate handlers just before
    -- they call us (1 = next, -1 = prev); nil for every other caller (selection
    -- changes, refreshes) so only real pagination animates. Consumed once.
    local _wipe_dir = self._wipe_dir
    self._wipe_dir = nil
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
    -- The view mode is part of "still matches the current mode": shelf_h, the
    -- row widgets and the cover dims all differ between covers and list, and a
    -- row COUNT that happens to be equal in both would otherwise let a stale
    -- stash through and paint the wrong row type on the next page turn.
    if n_shelves ~= (d.n_shelves or 2) or self:_viewMode() ~= d.view_mode then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        return
    end
    local VIEW_SIZE = self:_viewSize()
    local MAX_FETCH = 400
    local all_items, _total_hint = self:_fetchChipItems(MAX_FETCH)
    all_items = all_items or {}
    -- Same open-ended capture as _rebuild: set before the clamp + footer.
    self._opds_open_ended = (type(all_items) == "table")
                            and all_items.opds_open_ended or nil
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
    -- Same dispatch as _rebuild; the stash is guaranteed to belong to this mode
    -- by the guard above, so d.shelf_h is already the right kind of height.
    local rows
    if self:_isListMode() then
        rows = self:_buildListRows(items, d.content_w, d.shelf_h, d.book_gap or d.PAD, n_shelves)
    else
        rows = self:_buildShelfRows(items, d.content_w, d.shelf_h, d.book_gap or d.PAD, n_shelves)
    end
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
    local slot_h  = math.floor(slot_w * self:_coverAspect())
    -- Second of the two extraction sites; see _rebuild's for why list mode
    -- substitutes the thumbnail size (n_slots is 1 here, so the slot maths
    -- above would order a full-width cover for every book on the page).
    if self:_isListMode() then
        local ListGeom = require("lib/bookshelf_list_geom")
        local ListRow  = require("lib/bookshelf_list_row")
        slot_w, slot_h = ListGeom.thumbSize(d.shelf_h, ListRow.RING)
    end
    self:_kickOffMissingMetaExtraction(items, slot_w, slot_h, d.hero_cover_w, d.hero_cover_h)

    -- Swap each shelf row in place. Rows sit at shelf_top_idx, +2, +4, ...
    -- (each separated by exactly one gap widget -- a VerticalSpan in cover
    -- mode, the hairline divider in list mode -- so inter-row spacing,
    -- including expanded mode's even-slack after_row_bonus, is preserved).
    -- Capture the old row widgets to free after the next paint.
    --
    -- The gap widgets are left alone in cover mode but NOT in list mode: which
    -- of them is a divider depends on where the page's items run out, and a
    -- turn onto a partial last page would otherwise leave the previous page's
    -- rules hanging under blank rows.
    local list_rows    = self:_isListMode()
    local ListRow      = list_rows and require("lib/bookshelf_list_row") or nil
    local VerticalSpan = list_rows and require("ui/widget/verticalspan") or nil
    local old_rows = {}
    for r = 1, n_shelves do
        local idx = d.shelf_top_idx + 2 * (r - 1)
        old_rows[r] = self._inner_vgroup[idx]
        self._inner_vgroup[idx] = rows[r]
        if list_rows then
            -- Rewritten unconditionally rather than inspected: the two are the
            -- same height (the divider IS Size.line.thin), so this can never
            -- move a row, and neither widget owns a blitbuffer to free.
            if r < n_shelves and self:_listRowFilled(items, r + 1) then
                self._inner_vgroup[idx + 1] = ListRow.divider(
                    d.content_w, self:_listDividerOpts(items, r))
            else
                self._inner_vgroup[idx + 1] =
                    VerticalSpan:new{ width = self:_listRowGap() }
            end
        end
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
    -- (issue #124). Bare HorizontalGroup rows carry no painted .dimen, so
    -- anchor the region on the layout-derived row-top y stashed in _shelf_dims
    -- (falling back to a full refresh only if even that is missing).
    local shelf_top = (old_rows[1] and old_rows[1].dimen and old_rows[1].dimen.y)
                   or (d and d.wipe_rows_top)
    -- Page-turn wipe animation: only when a paginate handler set a direction
    -- AND the animation is enabled on an e-ink screen. Screen.bb still holds
    -- the old page here (nothing above painted to it), so copy it, render the
    -- new page in, copy that, and wipe between. The region reclaims the PAD
    -- gap above the rows so overhanging cover badges (favourite heart, issue
    -- #92) aren't clipped. On any failure, fall back to the scoped refresh.
    local anim_steps = _wipe_dir and shelf_top and _pageAnimSteps()
    -- Colour e-ink (Kaleido): the FIRST page-turn wipe after a full-screen
    -- refresh (cold start, chip switch, book return) stalls ~1.6s - its
    -- per-strip partial refreshes contend with the panel still draining the
    -- full refresh, every other strip waiting ~340ms (issue #247; measured
    -- on a Clara Colour). Warm wipes run ~35ms/strip and greyscale panels
    -- never exhibit it, so skip the animation only for that one turn, only
    -- on colour: an instant page now, smooth wipes once the panel settles.
    if anim_steps and self._full_refresh_pending
            and Device.hasColorScreen and Device:hasColorScreen() then
        anim_steps = nil
    end
    -- Consume the flag on any real page-turn (whether or not we skipped),
    -- so only the immediate post-refresh turn is affected.
    if _wipe_dir then self._full_refresh_pending = nil end
    local wiped = false
    if anim_steps then
        local ry = math.max(0, shelf_top - (d and d.PAD or 0))
        local region = Geom:new{ x = 0, y = ry, w = self.width, h = self.height - ry }
        wiped = pcall(function()
            local old_bb = Screen.bb:copy()
            self:paintTo(Screen.bb, 0, 0)
            local new_bb = Screen.bb:copy()
            PageWipe.run(Screen, old_bb, new_bb, region, _wipe_dir > 0, anim_steps)
            old_bb:free()
            new_bb:free()
        end)
    end
    if not wiped then
        if shelf_top then
            -- Reclaim the PAD gap ABOVE row 1, same as the wipe path's region.
            -- Cover badges overhang their cell: the favourite heart sits ~35%
            -- above the cover top and the selection ring extends a few px
            -- beyond it, both landing in this gap. A reshuffle (e.g. the
            -- just-read book jumping to the top of Recent) changes which slot
            -- carries them, and a refresh anchored AT shelf_top leaves the old
            -- glyphs' above-cover pixels on the panel -- the ghost borders /
            -- hearts reported on reader return. Starting the region a PAD
            -- higher sweeps them.
            local ry = math.max(0, shelf_top - (d and d.PAD or 0))
            UIManager:setDirty(self, "ui", Geom:new{
                x = 0, y = ry, w = self.width, h = self.height - ry })
        else
            UIManager:setDirty(self, "ui")
        end
    end
    -- Pagination via _swapShelvesInPlace bypasses _rebuild's persist hook;
    -- repeat the save here so a forward/back swipe is enough to land back
    -- on the right page after a book read or KOReader restart.
    self:_persistNavState()
    -- ...and bypasses _rebuild's OPDS hook too: a page turn INTO the tail of
    -- an OPDS window is exactly the moment the next feed page is needed.
    self:_opdsAfterPage(self._page_items)
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

-- A copy of `item` that is safe to hand to a SECOND SpineWidget.
--
-- ListRow gives its thumbnail the item's own book record and does not set
-- SpineWidget.cover_bb, so SpineWidget:_renderCover reads `self.cover_bb == nil`
-- as "we own the source bb" and frees it -- on the cache-hit branch before
-- painting from cache, on the scale branch right after scaling. The record it
-- came from, `book.cover_bb`, still points at that freed buffer.
--
-- The hazard is the READ, not a double free. BB:free() clears the ALLOCATED bit
-- and detaches the ffi finalizer (ffi/blitbuffer.lua's BB_mt.__index:free, at
-- lines 1471-1477 on KOReader v2026.07.1), so calling it twice on the same bb
-- is a no-op -- which is precisely why this has not
-- crashed yet: once a ScaledCoverCache entry exists, the second render takes
-- the cache-hit branch, whose only use of the stale bb is that inert second
-- free. Miss the cache instead (a big library, a cover-size change, a different
-- slot size, an eviction between the two renders) and the second render falls
-- through to bb:getWidth() and the scaler, reading memory that C.free() has
-- already returned -- a use-after-free, i.e. a segfault with no traceback
-- rather than a Lua error.
--
-- So: shallow-copy the record and drop the stale bb. SpineWidget then takes
-- its own from Repo.getCoverBB / ScaledCoverCache and owns what it frees. The
-- ORIGINAL record is left alone deliberately -- it may still hold a live bb
-- (the external-cover branch returns before any free), and clearing the only
-- reference to a live bb would leak it. The cover-mode twin gets the same
-- guarantee a different way, by rebuilding through Repo.buildBookMeta.
local function _coverSafeCopy(rec)
    if type(rec) ~= "table" or rec.cover_bb == nil then return rec end
    local copy = {}
    for k, v in pairs(rec) do copy[k] = v end
    copy.cover_bb = nil
    return copy
end

-- The same, for a row's item: only the record ListRow's coverBookFor() picks
-- out actually reaches a SpineWidget, so only that one needs replacing -- but
-- it has to be replaced inside a COPY of the group, never by mutating the live
-- page record the rest of the page still renders from.
local function _listSwapSafeItem(item)
    if type(item) ~= "table" then return item end
    if item.kind == "folder" then
        if type(item.first_book) ~= "table" then return item end
        local safe = _coverSafeCopy(item.first_book)
        if safe == item.first_book then return item end
        local copy = {}
        for k, v in pairs(item) do copy[k] = v end
        copy.first_book = safe
        return copy
    end
    if type(item.books) == "table" and type(item.books[1]) == "table" then
        local safe = _coverSafeCopy(item.books[1])
        if safe == item.books[1] then return item end
        local books = {}
        for i = 1, #item.books do books[i] = item.books[i] end
        books[1] = safe
        local copy = {}
        for k, v in pairs(item) do copy[k] = v end
        copy.books = books
        return copy
    end
    -- opds_nav renders from cover_image_path (SpineWidget's external-cover
    -- branch, which never touches a bb), and a plain book IS its own record.
    if item.kind == "opds_nav" then return item end
    return _coverSafeCopy(item)
end

-- _listRowFilled(items, r) — does list row `r` hold any content?
--
-- What the hairline divider is decided on. "Is there a row of content BELOW
-- this one" rather than "is there a row": on a partial last page the trailing
-- rows are blank spacers, and a rule with nothing under it reads as an
-- underline on the final book instead of a separator.
--
-- With more than one column a row is filled when its FIRST slot is -- items
-- fill left to right, so a row with anything on it has something in slot 1.
function BookshelfWidget:_listRowFilled(items, r)
    if not items then return false end
    return items[(r - 1) * self:_listCols() + 1] ~= nil
end

-- _listDividerOpts(items, r) — how to draw the rule that sits BELOW row `r`.
--
-- Returns what ListRow.divider takes: the column count, the inter-column gap,
-- and the set of columns whose segment must not be drawn.
--
-- A segment is skipped when the focused cell is directly above or directly
-- below it, so the rounded selection box lands in clear space instead of
-- running its corners along a hairline. BOTH neighbours matter: one rule is
-- the bottom edge of row r and the top edge of row r+1, and the box can be on
-- either side of it.
--
-- Computed per rule rather than stashed on a row, because a rule sits BETWEEN
-- two rows and belongs to neither -- and because the in-place repaint paths
-- rebuild rules and rows independently of each other.
function BookshelfWidget:_listDividerOpts(items, r)
    local ListGroup = require("lib/bookshelf_list_group")
    local n_cols = self:_listCols()
    local opts = { n_cols = n_cols, gap = self:_listRowColumnGap() }
    if not items then return opts end
    local fp = self:_selectedFilepath()
    local skip
    for c = 1, n_cols do
        for _j, row in ipairs({ r, r + 1 }) do
            local item = items[(row - 1) * n_cols + c]
            -- A BUTTON ROW BRINGS ITS OWN EDGE. A subcatalog fills its row
            -- with a bordered card, so a hairline hard against that border is
            -- a second line doing the first one's job -- "get rid of the
            -- hairline borders between cells when the folder button style is
            -- used". Same skip the focused cell uses and for the same reason:
            -- the rule is what a drawn edge collides with.
            -- `fp and` is load-bearing: with no selection fp is nil, and so is
            -- _itemFilepath for an item that has no path -- a nav entry has
            -- one, but nil == nil would skip the rule under anything that did
            -- not, for the wrong reason.
            if item and ((fp and _itemFilepath(item) == fp)
                         or ListGroup.fillsRow(item)) then
                skip = skip or {}
                skip[c] = true
            end
        end
    end
    opts.skip = skip
    return opts
end

-- The gap BETWEEN list columns. The same number _buildListRows divides the
-- content width by, so the rule's segments line up with the cells above them
-- -- read from the live layout when there is one, since that is what the rows
-- on screen were actually built with.
function BookshelfWidget:_listRowColumnGap()
    local d = self._shelf_dims
    if d and d.book_gap then return d.book_gap end
    if d and d.PAD then return d.PAD end
    local PAD = self:_layoutPrimitives()
    return PAD
end

-- _listRowItems(r) — the page items that make up list row `r`.
--
-- The whole row, not one item: with more than one column a row is a group, and
-- rebuilding it from a single item would blank its neighbours. Same
-- (r-1)*n_cols + c slice _buildListRows uses, so the two cannot disagree about
-- what is on a row.
--
-- Returns the array and, as a convenience for the callers that only need to
-- know "is this book here", the column it was found in.
function BookshelfWidget:_listRowItems(r, want_fp)
    local items  = self._page_items or {}
    local n_cols = self:_listCols()
    local out, found = {}, nil
    for c = 1, n_cols do
        local item = items[(r - 1) * n_cols + c]
        out[c] = item
        if want_fp and item and _itemFilepath(item) == want_fp then found = c end
    end
    return out, found
end

-- _swapListRowInPlace(r, row_items) — rebuild list row `r` and splice it into
-- the live vgroup, returning the row it replaced (for the refresh region and
-- the deferred free) or nil when that row isn't live.
--
-- The list's counterpart to swapping a single SpineWidget inside a shelf row.
-- It has to be the whole ROW: a list row draws the selection ring around
-- itself (bookshelf_list_row.lua wraps the row in an OverlapGroup +
-- BorderOverlay), its text lives in its own bands, and the thumbnail is an
-- inert SpineWidget with no selection state of its own. Rebuilding one row is
-- still nothing like _swapShelvesInPlace: no chip fetch, no footer, no hero.
function BookshelfWidget:_swapListRowInPlace(r, row_items)
    local d = self._shelf_dims
    if not d or not self._inner_vgroup or not d.shelf_top_idx then return nil end
    local idx = d.shelf_top_idx + 2 * (r - 1)
    local old = self._inner_vgroup[idx]
    if not old then return nil end
    -- Every item on the row goes through the cover-safe copy, not just the one
    -- that changed: they are all about to be handed to fresh SpineWidgets, and
    -- a shared one-shot cover_bb is disposed by whichever widget frees first.
    local safe = {}
    for c = 1, #row_items do safe[c] = _listSwapSafeItem(row_items[c]) end
    local built = self:_buildListRows(safe, d.content_w, d.shelf_h,
                                      d.book_gap or d.PAD, 1)
    local new_row = built and built[1]
    if not new_row then return nil end
    self._inner_vgroup[idx] = new_row
    return old
end

-- _repaintListSelection(old_fp, new_fp) — the list-mode half of
-- _repaintSelectionHighlight, same contract: repaint the two rows whose
-- selection state changed and nothing else.
--
-- Not shareable with the cover path. _descendFindSpine gives up past depth 3
-- and a row's thumbnail sits four levels below the row root (five once the
-- ring's OverlapGroup is inserted), so that walker matches nothing here,
-- reports replaced == 0, and falls through to _swapShelvesInPlace — which
-- re-runs _fetchChipItems on EVERY preview tap, the ~950ms path this whole
-- fast path exists to avoid. Deepening the walk wouldn't help either: it would
-- find the thumbnail and hang a cover's ring on it, which is not where a list
-- row's selection cue lives.
function BookshelfWidget:_repaintListSelection(old_fp, new_fp)
    local _perf_t0 = _gettime()
    local d = self._shelf_dims
    -- Stale-stash guard, mirroring _swapShelvesInPlace's own check. This
    -- function indexes the live vgroup by row NUMBER rather than walking the
    -- tree (that's the whole point of the nCols()==1 trick), so a d left over
    -- from before a view-mode flip would otherwise splice a ListRow into a
    -- slot that is still a cover shelf's HorizontalGroup. _swapShelvesInPlace
    -- re-checks the same mismatch and forces the rebuild this needs.
    if d.view_mode ~= self:_viewMode() then
        self:_swapShelvesInPlace()
        return
    end
    local union_dimen
    local old_rows = {}
    for r = 1, (d.n_shelves or 0) do
        -- The rows that changed are found by INDEX, not by a tree walk: the
        -- page items map onto rows by the same slice the renderer used, so a
        -- row either holds one of the two filepaths or it does not.
        local row_items = self:_listRowItems(r)
        local hit = false
        for c = 1, #row_items do
            local fp = _itemFilepath(row_items[c])
            if fp and (fp == old_fp or fp == new_fp) then hit = true end
        end
        if hit then
            local old = self:_swapListRowInPlace(r, row_items)
            if old then
                old_rows[#old_rows + 1] = old
                if old.dimen then
                    if union_dimen then
                        union_dimen = union_dimen:combine(old.dimen)
                    else
                        union_dimen = old.dimen:copy()
                    end
                end
            end
        end
    end
    if #old_rows == 0 then
        -- Neither book is on this page (the preview was set before a page
        -- turn): same fallback the cover path takes, for the same reason —
        -- the new selection state still has to render somewhere.
        logger.dbg("[bookshelf perf] _repaintListSelection: no row match -> fallback _swapShelves")
        self:_swapShelvesInPlace()
        return
    end
    -- Rebuild the RULES too, not just the rows.
    --
    -- A rule now depends on the selection: the segment above and below the
    -- focused cell is blanked so the rounded box does not run its corners along
    -- a hairline. Swapping only the rows would leave the rule the selection
    -- just left still blanked and the one it arrived at still drawn -- the mark
    -- would look like it had smeared across two rows.
    --
    -- ALL of them, rather than working out which two moved: they are LineWidgets
    -- of a few pixels with no blitbuffer to free, so rebuilding the page's worth
    -- costs less than the bookkeeping to be clever about it.
    -- Required here, not at file scope: every other user of ListRow in this
    -- file does the same, and reaching for it as a global compiles fine and
    -- blows up on the first selection move.
    local ListRow = require("lib/bookshelf_list_row")
    local items_all = self._page_items or {}
    for r = 1, (d.n_shelves or 0) - 1 do
        local idx = (d.shelf_top_idx or 1) + 2 * (r - 1) + 1
        if self._inner_vgroup[idx] and self:_listRowFilled(items_all, r + 1) then
            self._inner_vgroup[idx] = ListRow.divider(
                d.content_w, self:_listDividerOpts(items_all, r))
        end
    end
    -- The union has to grow to cover them: a rule sits OUTSIDE the row's dimen,
    -- in the gap below it, so a region computed from the rows alone would leave
    -- the changed rules unrefreshed.
    if union_dimen then
        local g = self:_listRowGap()
        union_dimen.y = math.max(0, union_dimen.y - g)
        union_dimen.h = union_dimen.h + 2 * g
    end
    if self._inner_vgroup.resetLayout then self._inner_vgroup:resetLayout() end
    UIManager:nextTick(function()
        for _i = 1, #old_rows do
            local w = old_rows[_i]
            if w and w.free then pcall(function() w:free() end) end
        end
    end)
    if union_dimen then
        -- No ring padding needed, unlike the cover path: ListRow reserves
        -- ListRow.RING inside the row box on all four sides, so the ring
        -- paints within the dimen we already have. (Not SELECTED_BORDER --
        -- that is the cover grid's much thicker ring; see
        -- bookshelf_list_geom.lua's ROW_RING_DP.)
        UIManager:setDirty(self, function() return "ui", union_dimen, self.dithered end)
    else
        UIManager:setDirty(self, "ui")
    end
    logger.dbg(string.format(
        "[bookshelf perf] _repaintListSelection: rows=%d TOTAL=%.0fms",
        #old_rows, (_gettime() - _perf_t0) * 1000))
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
    if self:_isListMode() then
        return self:_repaintListSelection(old_fp, new_fp)
    end
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
        UIManager:setDirty(self, function() return "ui", union_dimen, self.dithered end)
    else
        UIManager:setDirty(self, "ui")
    end
    logger.dbg(string.format(
        "[bookshelf perf] _repaintHighlight: replaced=%d TOTAL=%.0fms",
        replaced, (_gettime() - _perf_t0) * 1000))
end

-- _refreshListRowInPlace(fp) — the list-mode half of _refreshSpineInPlace.
-- Same contract (true when the book was on screen and got repainted), same
-- reason for existing separately as _repaintListSelection: the row is the unit
-- that changes, and its progress cell is text in a column, not state on the
-- thumbnail. The page item is re-read from the repository first so the row
-- renders the progress the reader just wrote, not the copy the page was built
-- from.
function BookshelfWidget:_refreshListRowInPlace(fp)
    local d = self._shelf_dims
    -- Same stale-stash guard as _repaintListSelection (see its comment).
    -- _swapShelvesInPlace already forces the rebuild this needs, so report
    -- "handled" rather than let the caller redo it a second time.
    if d.view_mode ~= self:_viewMode() then
        self:_swapShelvesInPlace()
        return true
    end
    local items  = self._page_items or {}
    local n_cols = self:_listCols()
    for r = 1, (d.n_shelves or 0) do
        local row_items, col = self:_listRowItems(r, fp)
        if col then
            local item = row_items[col]
            -- Only a plain book record can be replaced wholesale; a folder or
            -- group row keeps its own record (its bands summarise members, not
            -- this one file) and is simply rebuilt.
            if item.filepath == fp then
                local fresh = Repo.buildBookMeta(fp)
                if fresh then
                    -- Write back into the PAGE, not just the local slice: the
                    -- next rebuild reads _page_items, and leaving the stale
                    -- record there would undo this repaint.
                    items[(r - 1) * n_cols + col] = fresh
                    row_items[col] = fresh
                end
            end
            local old = self:_swapListRowInPlace(r, row_items)
            if old then
                if self._inner_vgroup.resetLayout then
                    self._inner_vgroup:resetLayout()
                end
                local region = old.dimen and old.dimen:copy()
                UIManager:nextTick(function()
                    if old.free then pcall(function() old:free() end) end
                end)
                if region then
                    UIManager:setDirty(self, function()
                        return "ui", region, self.dithered
                    end)
                end
                return true
            end
        end
    end
    return false
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
    if self:_isListMode() then return self:_refreshListRowInPlace(fp) end
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
        UIManager:setDirty(self, function() return "ui", replaced_dimen, self.dithered end)
    end
    return replaced
end

-- _paintOpeningEffect(fp) — transient "book opening" feedback painted
-- straight onto the framebuffer: the tapped cover squeezes ~5% toward its
-- left edge (the spine), revealing page-white along the right and thin
-- wedges top/bottom — the front cover starting to swing open. Replaces
-- KOReader's centre-screen "Opening file" box (suppressed via
-- showReader's seamless flag). No widget is created and no re-render
-- happens: the CURRENT on-screen pixels are captured, rescaled and
-- blitted back, so the card's hairline border squeezes with the artwork
-- while the drop shadow and everything outside the card stay untouched.
--
-- E-ink cannot animate during the blocking document open (the UI loop is
-- busy inside openDocument), so this is a single frame, not a tween.
--
-- Target resolution: SpineWidget.last_tapped (recorded in its onTap) is
-- validated against the opened filepath — a hero cover and a shelf spine
-- can show the SAME book, so a filepath search cannot disambiguate which
-- was tapped (the badge this replaces got that wrong). Opens with no
-- tapped cover on screen (start menu, bookmarks, search) paint nothing.
function BookshelfWidget:_paintOpeningEffect(fp)
    if not fp then return end
    local spine = SpineWidget.last_tapped
    -- Consume the rendezvous flag even when the effect is off, so a stale
    -- last_tapped can't corrupt a later paint (see the reviews-modal note).
    SpineWidget.last_tapped = nil
    -- Opt-out: the cover-opening flex is purely cosmetic. When disabled, open
    -- plainly with no flex frame.
    if not BookshelfSettings.nilOrTrue("open_cover_effect") then return end
    if not (spine and spine.book and spine.book.filepath == fp) then return end
    local card = spine._cover_card
    local rect = card and card.dimen
    if not (rect and rect.x and rect.w and rect.w > 8 and rect.h > 8) then return end
    -- A selected book wears the thick ring (BorderOverlay) just outside the
    -- card, which visually cages the flex - the 3D lift can't extend past
    -- it. Erase the ring band in the same frame, so the cover pops free of
    -- its highlight as it opens. Plain white restores the page background
    -- (and inverts to the night background correctly). Band thickness
    -- mirrors SELECTED_BORDER (= SHADOW_OFFSET, 4dp) plus rounding slack.
    local ringed = spine.is_selected or spine.is_bulk_selected
    local ring_t = Screen:scaleBySize(4) + 2
    if ringed and Screen.bb then
        local bb = Screen.bb
        local W = Blitbuffer.COLOR_WHITE
        -- Full-band erase; badge glyphs that overhang into the bands are
        -- REPAINTED after the flex (their widgets are stashed with painted
        -- rects), so nothing gets beheaded and no ring stub remains.
        bb:paintRect(rect.x - ring_t, rect.y - ring_t, rect.w + 2 * ring_t, ring_t, W)
        bb:paintRect(rect.x - ring_t, rect.y + rect.h, rect.w + 2 * ring_t, ring_t, W)
        bb:paintRect(rect.x - ring_t, rect.y, ring_t, rect.h, W)
        bb:paintRect(rect.x + rect.w, rect.y, ring_t, rect.h, W)
        -- The selected cover's corner MASK is painted BLACK to blend with
        -- the ring backdrop (RoundedCornerCard bg_color) - with the ring
        -- gone, those pixels read as square black corners on the flexed
        -- cover. Convert the outside-arc corner pixels to page white with
        -- the same monotonic arc scan the mask painter uses.
        local r = Screen:scaleBySize(4) -- mirrors CARD_RADIUS
        local r_sq = r * r
        for dy = 0, r - 1 do
            local dx = 0
            while dx < r do
                local cx = r - dx - 0.5
                local cy = r - dy - 0.5
                if cx * cx + cy * cy <= r_sq then break end
                dx = dx + 1
            end
            if dx > 0 then
                local y_top = rect.y + dy
                local y_bot = rect.y + rect.h - 1 - dy
                bb:paintRect(rect.x, y_top, dx, 1, W)
                bb:paintRect(rect.x + rect.w - dx, y_top, dx, 1, W)
                bb:paintRect(rect.x, y_bot, dx, 1, W)
                bb:paintRect(rect.x + rect.w - dx, y_bot, dx, 1, W)
            end
        end
    end
    -- A selected cover wears the ring INSTEAD of a drop shadow (the selected
    -- branch of _wrapCoverInCard sets no shadow_color), so erasing the ring
    -- above left the opening cover flat and thin -- the "thicker book" cue was
    -- lost only in the selected state (#271 follow-up). Restore the drop
    -- shadow a non-selected cover would have, done BEFORE the flex so the
    -- flex's lifted bands paint OVER it, exactly as the real card shadow sits
    -- behind the cover (painting it after chopped across the lifting cover).
    -- Method: paint the card's rounded shadow over the whole footprint, then
    -- blit the clean cover face back on top -- only the rounded L outside the
    -- cover survives, pixel-identical to a non-selected cover (rounded corners,
    -- no square edges, no manual corner math). Non-selected / popup opens keep
    -- their own real shadow untouched, so every path stays consistent.
    if ringed and Screen.bb then
        local sbb  = Screen.bb
        local SO   = SpineWidget.SHADOW_OFFSET or Screen:scaleBySize(4)
        local rad  = SpineWidget.CARD_RADIUS or Screen:scaleBySize(4)
        local gray = SpineWidget.shadowGray and SpineWidget.shadowGray()
        if gray then
            pcall(function()
                local snap = Blitbuffer.new(rect.w, rect.h, sbb:getType())
                snap:blitFrom(sbb, 0, 0, rect.x, rect.y, rect.w, rect.h)
                sbb:paintRoundedRect(rect.x + SO, rect.y + SO, rect.w, rect.h, gray, rad)
                sbb:blitFrom(snap, rect.x, rect.y, 0, 0, rect.w, rect.h)
                snap:free()
            end)
        end
    end
    -- Paint the flex WITHOUT refreshing: the ring erase (above), the flex,
    -- and the glyph repaints (below) must land in ONE EPDC frame - separate
    -- refreshes played out as visible steps (border blanking, then the
    -- cover, then the icons popping back).
    -- Which effect: the grid's trapezoid flex, or the list thumbnail's flat
    -- squash. Branching on flat_thumb rather than on the rect's SIZE, because
    -- flat_thumb is the caller's own declaration that this is a table cell and
    -- not a card (bookshelf_list_row.lua sets it for exactly that reason), and
    -- a size threshold would have to be re-guessed for every panel and every
    -- list_font_scale.
    local flex = spine.flat_thumb and BookshelfWidget.squashCoverOpen
                                   or BookshelfWidget.flexCoverOpen
    local fx, fy, fw, fh = flex(rect, { skip_refresh = true })
    -- Union of everything painted this frame, starting from the flex region.
    local ux0, uy0 = fx or rect.x, fy or rect.y
    local ux1 = (fx or rect.x) + (fw or rect.w)
    local uy1 = (fy or rect.y) + (fh or rect.h)
    if ringed then
        ux0 = math.min(ux0, rect.x - ring_t)
        uy0 = math.min(uy0, rect.y - ring_t)
        ux1 = math.max(ux1, rect.x + rect.w + ring_t)
        uy1 = math.max(uy1, rect.y + rect.h + ring_t)
    end
    -- Repaint the overhanging badge glyphs (heart above, bookmark dangle
    -- below) at their original painted positions, on top of the ring erase
    -- and the flexed cover - the glyphs stay whole and unmoved while the
    -- cover opens beneath them.
    local bb = Screen.bb
    if bb and spine._overhang_glyph_widgets then
        local m = Screen:scaleBySize(4) -- halo/shadow paint past the dimen
        for _i, gw in ipairs(spine._overhang_glyph_widgets) do
            local gd = gw.dimen
            if gd and gd.x and gd.w and gd.w > 0 then
                pcall(function() gw:paintTo(bb, gd.x, gd.y) end)
                ux0 = math.min(ux0, gd.x - m)
                uy0 = math.min(uy0, gd.y - m)
                ux1 = math.max(ux1, gd.x + gd.w + m)
                uy1 = math.max(uy1, gd.y + gd.h + m)
            end
        end
    end
    pcall(function() Screen:refreshUI(ux0, uy0, ux1 - ux0, uy1 - uy0) end)
end

-- How much of its width a list thumbnail's artwork keeps while opening.
--
-- 0.90 -- a 10% squash. The first attempt took 30%, which is what the spec
-- asked for and read as too much on hardware: at thumbnail size the artwork
-- visibly deformed rather than suggesting a cover swinging open, and the
-- revealed page was wider than the spine of the book it was meant to be
-- opening. Retuned on the device to "scale the cover by less, maybe 10%".
local THUMB_SQUASH = 0.90

-- squashCoverOpen(rect, opts) — the opening effect for a LIST THUMBNAIL.
--
-- Same contract as flexCoverOpen (paints straight to the framebuffer, honours
-- opts.skip_refresh, returns the affected region), and a deliberately much
-- simpler picture: the artwork compresses to 70% of its width against the left
-- edge and page colour fills what it leaves. No trapezoid, no lift, no bands.
--
-- ── WHY THE GRID'S EFFECT DOES NOT WORK HERE ───────────────────────────────
--
-- flexCoverOpen reads as a book swinging open because it has room to: a 5%
-- axis inset, a 5% squeeze and a 6% vertical lift, banded across up to 24
-- strips. On a grid cover ~200px wide those are 10px, 10px and 12px -- legible
-- gestures. On a 30x45 list thumbnail they are 1px, 1px and 3px, spread over
-- two bands. The maintainer's report: the effect "doesn't really work on the
-- small thumbnails", which is the arithmetic, not the taste.
--
-- So the small version spends its whole budget on the ONE cue that survives at
-- that size -- a large horizontal compression -- and drops the two that do
-- not. 30% of a 30px thumbnail is 9px of movement, which reads.
--
-- ── LEAVING THE BORDER ALONE ───────────────────────────────────────────────
--
-- The grid effect squeezes the card's hairline frame along with the artwork,
-- because there the frame IS part of the object swinging open. A list
-- thumbnail's frame is the table cell's edge: squashing it would read as the
-- ROW deforming rather than the cover opening, and would leave a notch in a
-- column of otherwise flush cells. So everything here works on the interior,
-- inset by the border, and the frame is never touched.
--
-- One consequence worth stating: nothing paints outside `rect`, which is
-- already on screen by construction. flexCoverOpen needs careful per-band
-- clamping because its lift blits taller-than-cover bands that can run off the
-- top or bottom of the framebuffer -- an out-of-bounds blit segfaults the C
-- blitter with no Lua trace. Without the lift, that entire failure mode is
-- absent rather than guarded against.
function BookshelfWidget.squashCoverOpen(rect, opts)
    opts = opts or {}
    if not (rect and rect.x and rect.w and rect.w > 4 and rect.h > 4) then return end
    local bb = Screen.bb
    if not bb then return end
    -- Night mode inverts the framebuffer at refresh, so the revealed page must
    -- be PAINTED black to DISPLAY white. Same rule as flexCoverOpen's.
    local night = G_reader_settings:isTrue("night_mode")
    local page_color = night and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE

    local border = SpineWidget.CARD_BORDER or Screen:scaleBySize(1)
    local ix, iy = rect.x + border, rect.y + border
    local iw, ih = rect.w - 2 * border, rect.h - 2 * border
    if iw < 6 or ih < 4 then return end
    local new_w = math.floor(iw * THUMB_SQUASH)
    -- Nothing to show: at a thumbnail small enough that 30% rounds away, the
    -- effect would be a no-op paint and a wasted EPDC region.
    if new_w < 2 or new_w >= iw then return end

    local ok = pcall(function()
        local src = Blitbuffer.new(iw, ih, bb:getType())
        src:blitFrom(bb, 0, 0, ix, iy, iw, ih)
        local scaled = src:scale(new_w, ih)
        bb:blitFrom(scaled, ix, iy, 0, 0, new_w, ih)
        bb:paintRect(ix + new_w, iy, iw - new_w, ih, page_color)
        src:free()
        scaled:free()
    end)
    if not ok then
        logger.dbg("[bookshelf] thumbnail opening effect failed; skipping")
        return
    end
    if not opts.skip_refresh then
        pcall(function() Screen:refreshUI(rect.x, rect.y, rect.w, rect.h) end)
    end
    return rect.x, rect.y, rect.w, rect.h
end

-- flexCoverOpen(rect, opts) — the shared cover-opening flex painter,
-- callable without a widget instance (the book-detail popup flexes its
-- header cover through this too). rect is the cover's painted screen
-- rect. opts.skip_refresh: paint only; the caller batches one refresh
-- over a wider union so multi-part effects land in a single EPDC frame.
-- Returns the affected region (x, y, w, h) for that union.
function BookshelfWidget.flexCoverOpen(rect, opts)
    if not (rect and rect.x and rect.w and rect.w > 8 and rect.h > 8) then return end
    local bb = Screen.bb
    if not bb then return end
    -- Night mode inverts the framebuffer at refresh, so paint the logical
    -- colours swapped there: the page block must DISPLAY white and the
    -- hairline frame dark in both modes.
    local night = G_reader_settings:isTrue("night_mode")
    local page_color = night and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local ink_color  = night and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    -- Flex the cover open around an axis ~5% in from its left edge, as if
    -- the spine of a new book hasn't fully flexed yet: ONLY the region
    -- right of the axis is captured and squeezed, strictly inside the
    -- card. Everything else - the spine sliver, the drop shadow, a
    -- selection ring, the page background, and the badge glyphs' out-of-
    -- card overhang - is never touched. The glyphs sit right next to the
    -- axis, so their in-card pixels shift by ~a pixel: no visible tear
    -- against their untouched overhang. This replaced two rounds of
    -- capture-and-restore geometry that tried to move the whole card and
    -- separate travelling badges from static chrome - flexing around a
    -- near-spine axis makes the separation unnecessary.
    local SQUEEZE = 0.95
    local LIFT    = 0.06
    local ax = rect.x + math.floor(rect.w * 0.05)
    local rw = rect.x + rect.w - ax
    local rh = rect.h
    if rw < 12 then return end
    local new_w = math.floor(rw * SQUEEZE)
    local lift_pad = math.ceil(rh * LIFT / 2) + 2
    -- Screen bounds for clamping. The trapezoid lift blits taller-than-cover
    -- bands whose dest can run above y=0 (top row / hero) or past the bottom
    -- (last row); an out-of-bounds blit segfaults the C blitter with no Lua
    -- trace (PW3, greyscale). pcall can't catch a native segfault, so we
    -- must never hand blitFrom an off-screen dest - clamp every band.
    local scr_w = (bb.getWidth and bb:getWidth()) or Screen:getWidth()
    local scr_h = (bb.getHeight and bb:getHeight()) or Screen:getHeight()
    local ok = pcall(function()
        local src_bb = Blitbuffer.new(rw, rh, bb:getType())
        src_bb:blitFrom(bb, 0, 0, ax, rect.y, rw, rh)
        -- Banded trapezoid: bands grow taller toward the free edge (up to
        -- +LIFT of the height, split above/below), so the cover face reads
        -- as lifting OUT of the screen. Only the PAINT overdraws past the
        -- card top/bottom near the right edge - a one-frame effect the
        -- reader's arrival replaces; the capture itself stays in-card, and
        -- bands near the axis barely grow, keeping the badge glyphs whole.
        local n_bands = math.max(8, math.min(24, math.floor(new_w / 12)))
        local prev_sx, prev_dx = 0, 0
        for k = 1, n_bands do
            local sx = math.floor(rw * k / n_bands)
            local dx = math.floor(new_w * k / n_bands)
            local bw_src = sx - prev_sx
            local bw_dst = dx - prev_dx
            if bw_src > 0 and bw_dst > 0 then
                local grow = LIFT * ((k - 0.5) / n_bands)
                local bh   = rh + 2 * math.floor(rh * grow / 2)
                local band = Blitbuffer.new(bw_src, rh, bb:getType())
                band:blitFrom(src_bb, 0, 0, prev_sx, 0, bw_src, rh)
                local scaled = band:scale(bw_dst, bh)
                -- Clamp the dest vertically into the framebuffer: shave any
                -- overshoot above 0 / below scr_h and feed blitFrom the
                -- matching source offset + reduced height, so the C blitter
                -- only ever sees an in-bounds rect.
                local dx2 = ax + prev_dx
                local dy2 = rect.y - math.floor((bh - rh) / 2)
                local sy2, hh2 = 0, bh
                if dy2 < 0 then sy2 = -dy2; hh2 = hh2 + dy2; dy2 = 0 end
                if dy2 + hh2 > scr_h then hh2 = scr_h - dy2 end
                local ww2 = bw_dst
                if dx2 + ww2 > scr_w then ww2 = scr_w - dx2 end
                if hh2 > 0 and ww2 > 0 and dx2 >= 0 then
                    bb:blitFrom(scaled, dx2, dy2, 0, sy2, ww2, hh2)
                end
                band:free()
                scaled:free()
            end
            prev_sx, prev_dx = sx, dx
        end
        -- Page block where the cover face pulled away, hairline-framed on
        -- its top/right/bottom so the book's top edge runs unbroken to
        -- the corner (borderless, it read as a gap by the drop shadow).
        local strip_x = ax + new_w
        local strip_w = rect.x + rect.w - strip_x
        if strip_w > 0 then
            bb:paintRect(strip_x, rect.y, strip_w, rh, page_color)
            local hair = math.max(1, Screen:scaleBySize(1))
            bb:paintRect(strip_x, rect.y, strip_w, hair, ink_color)
            bb:paintRect(strip_x, rect.y + rh - hair, strip_w, hair, ink_color)
            bb:paintRect(rect.x + rect.w - hair, rect.y, hair, rh, ink_color)
        end
        src_bb:free()
    end)
    if not ok then
        logger.dbg("[bookshelf] opening effect failed; skipping")
        return
    end
    -- Push the flexed region (plus the lift overdraw above/below) to the
    -- panel now - the document open that follows blocks the UI loop, so a
    -- queued refresh would never land. Skipped when the caller batches.
    if not (opts and opts.skip_refresh) then
        pcall(function()
            Screen:refreshUI(ax, rect.y - lift_pad, rw, rh + 2 * lift_pad)
        end)
    end
    return ax, rect.y - lift_pad, rw, rh + 2 * lift_pad
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
    -- Returning from a book triggers a full-screen refresh; on colour e-ink
    -- the first page-turn wipe after it stalls (issue #247). Flag it like
    -- _rebuild does so the first real turn skips the animation on colour.
    self._full_refresh_pending = true
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
        UIManager:setDirty(self, function() return "ui", scope, self.dithered end)
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
        UIManager:setDirty(self, function() return "ui", scope, self.dithered end)
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
-- A previewed OPDS book earns its cover: the tap is the user gesture that
-- licenses this one fetch (nothing else prefetches). If the cover is
-- already on disk - e.g. a long-press download modal cached it without
-- rebuilding the shelf - attach it to the record right here, before the
-- caller's rebuild reads it, rather than fetching it again. Otherwise fetch
-- it: when it lands, patch the previewed record in place - _hydrateBook
-- returns remote records unchanged and Repo.buildBook is nil for
-- OPDS:// paths, so a rebuild reuses this same table and would otherwise
-- keep the placeholder - then one _refreshCoverFrame repaints hero AND
-- shelf cell (its rebuild re-slices, and opdsDecorate attaches the
-- cached cover to the cell's record independently).
-- Shared by _previewBook (normal-mode tap) and the expanded show_detail tap
-- (on_book_tap), both of which stage `book` as self._preview_book just
-- before calling this, so the pre/on_cached identity check below matches
-- either caller.
function BookshelfWidget:_opdsEnsurePreviewCover(book)
    if not (book and book.filepath) then return end
    if not self:_isRemoteRecord(book) then return end
    local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
    if not ok_c then return end
    local cp = OpdsCovers.cachedPath(book)
    if cp then
        -- Already on disk, but THIS record can predate the cache
        -- entry (sliced before the cover landed, or the download
        -- modal fetched it without rebuilding the shelf). Attach in
        -- place now - this trigger runs before the preview rebuild
        -- below, so the hero renders it with no extra refresh.
        logger.dbg("[bookshelf perf] _opdsEnsurePreviewCover: cached attach",
            tostring(book.title or book.filepath))
        book.cover_image_path = book.cover_image_path or cp
        if not book.cover_sizetag then
            local ok_is, ImageSource =
                pcall(require, "lib/bookshelf_image_source")
            if ok_is and ImageSource.imageSizeTag then
                book.cover_sizetag = ImageSource.imageSizeTag(cp)
            end
        end
    else
        self:_opdsFetchCover(book, {
            -- The cover download blocks the main loop for up to 10s, and the
            -- previewed hero alone (placeholder cover, feed description) can
            -- read as "nothing happened" on a slow catalog - say what's going
            -- on. Shown only when a fetch actually starts.
            --
            -- Names the cover, because the cover is all this fetches. The
            -- title, author and summary are already in the hero by the time
            -- this runs - they came with the feed - so "book information"
            -- described work that had visibly already happened.
            notice = _("Retrieving book cover\xE2\x80\xA6"),
            -- A later tap can supersede this preview before the fetch even
            -- starts (checked here, before fetchMissing) or while it's mid
            -- air (checked again below when it lands). Either way, a
            -- superseded preview's fetch is simply skipped: the disk cache
            -- still serves the cell on its next natural rebuild.
            pre = function()
                return self._preview_book ~= nil
                   and self._preview_book.filepath == book.filepath
            end,
            on_cached = function()
                local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
                if not ok_c then return end
                local cp = OpdsCovers.cachedPath(book)
                if cp and self._preview_book
                        and self._preview_book.filepath == book.filepath then
                    self._preview_book.cover_image_path = cp
                    if not self._preview_book.cover_sizetag then
                        local ok_is, ImageSource =
                            pcall(require, "lib/bookshelf_image_source")
                        if ok_is and ImageSource.imageSizeTag then
                            self._preview_book.cover_sizetag =
                                ImageSource.imageSizeTag(cp)
                        end
                    end
                    -- Same freeze + geometry shift as the modal's re-show:
                    -- fetchMissing held the loop, queued taps would land on
                    -- covers that moved when the cell takes its true aspect.
                    local Input = Device.input
                    if Input and Input.inhibitInputUntil then
                        Input:inhibitInputUntil(true)
                    end
                    self:_refreshCoverFrame(book.filepath)
                end
            end,
        })
    end
end

function BookshelfWidget:_previewBook(book, tap_t)
    if not book or not book.filepath then return end
    -- A preview supersedes any pending tap-stage. _selectedFilepath ranks
    -- _tap_selected_fp above the preview book, and the hero's on_tap latches it
    -- when tap_to_open_double is on ("tap once more to open"), so without this
    -- clear the ring stayed pinned to the hero's book while the preview moved on.
    -- Invisible on the fast repaint path below (it passes is_selected
    -- explicitly) and plain wrong on the _rebuild path, which derives the ring
    -- from _selectedFilepath - which is why it only showed in chips that
    -- contain the currently-reading book, the ones whose taps cross the
    -- was_diff/is_diff boundary and rebuild (#335). Same invalidation the
    -- pagination (#265) and _drillInto paths already do on a context change.
    self._tap_selected_fp = nil
    self:_opdsEnsurePreviewCover(book)
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
        self._preview_book = self:_hydrateBook(book)
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
            UIManager:setDirty(self, function() return "ui", cover_dimen, self.dithered end)
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
    self._preview_book = self:_hydrateBook(book)
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
    -- Invalidate any pending Kobo prepare-poll (_openKoboWhenReady). The poll
    -- closure captures self and would otherwise call _launchReader on this
    -- torn-down widget when the decrypted file readies after we're gone.
    self._kobo_open_token = (self._kobo_open_token or 0) + 1
    -- Drop any pending draft-cover settle so it can't rebuild a torn-down widget.
    if self._cover_settle_cb then
        UIManager:unschedule(self._cover_settle_cb)
        self._cover_settle_cb = nil
    end
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
        if not self:_anyActiveRegionUses(tokens) then return end
        -- Micro-page header or expanded strip: the status line lives above the
        -- grid, not in a hero card, so refresh it via its own in-place swap
        -- (#292). One record serves both surfaces.
        if self._hero_status_strip then
            _device_state_expires_at = 0
            self:_swapHeroStatusStrip()
            return
        end
        local _hc = self._hero_card or (self._hero_parent and self._hero_parent[1])
        if not (_hc and _hc.replaceRightColumn) then return end
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
        end
        if self._hero_status_strip then
            -- Micro-page header or expanded strip: the status line isn't a
            -- clock cell, so tick it here when it carries a time token (#292);
            -- otherwise it lags behind the grid's own clock.
            if self:_anyActiveRegionUses(TIMER_TOKENS) then
                self:_swapHeroStatusStrip()
            end
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
            self:_markOpdsNav()
            self:_advanceCursor(-1)
            self:_syncPageFromCursor()
            self._cursor_idx = view_size
            self:_swapShelvesInPlace()
        end
        return true
    end

    if new_idx > view_size then
        local total = self._total_pages or 1
        -- Open-ended OPDS window: same allowance _paginateNext gets, so a
        -- keyboard-only user can also step past the cached window and pull
        -- the next feed page in.
        if self.page < total or self._opds_open_ended then
            self:_markOpdsNav()
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
        local items          = self._page_items or {}
        local view_size      = n_shelves * n_cols
        local cur            = self._cursor_idx or 1
        -- Where "down" lands, resolved against the OCCUPIED slots rather than
        -- the grid's geometry. A shelf with room for two rows but only one
        -- row of books has an empty second row, and asking _moveCursor to
        -- step into it just returned true and moved nothing -- so a
        -- keyboard/d-pad user on a part-full shelf could never reach the
        -- footer at all (Reddit report). Three cases, in order:
        --   * a book directly below            -> step onto it
        --   * a shorter row below (ragged tail) -> its last real slot, which
        --     is the nearest book in the direction travelled
        --   * nothing below                     -> fall through to the footer
        -- The old geometric test (cursor >= last row start) is subsumed: from
        -- the bottom row `below` is past view_size, so target stays nil.
        local target
        local below = cur + n_cols
        if below <= view_size then
            if items[below] then
                target = below
            else
                local row_start = below - ((below - 1) % n_cols)
                for i = below - 1, row_start, -1 do
                    if items[i] then target = i break end
                end
            end
        end
        if target then
            self._cursor_idx = target
            self:_swapShelvesInPlace()
            return true
        end
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
            elseif item.kind == "opds_nav" then
                -- Remote navigation tile. It carries a filepath (the synthetic
                -- OPDS:// one), so without an arm of its own it would fall
                -- through every branch here and Enter would silently no-op --
                -- the tile is only reachable by touch otherwise.
                self:_expandOpdsNav(item)
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
-- Colour e-ink (Kaleido / PocketBook Color / Kindle Colorsoft): book covers
-- only pick up the panel's colour-dither waveform when the refresh that draws
-- them carries the dither hint. UIManager honours a top-level widget's
-- `dithered` flag on plain "ui" refreshes automatically, and via the 3rd return
-- of closure refreshes (see uimanager.lua). KOReader's own cover browser flags
-- itself the same way (covermenu.lua: show_parent.dithered + "ui", region,
-- dithered). We never did, so on colour panels our covers rendered desaturated
-- until an unrelated full refresh (idle timer, task-switch) applied the colour
-- waveform -- #289. Flagging ourselves fixes it. Colour panels only (nil on
-- B&W, so their refresh behaviour is unchanged); gated behind the "Colour panel
-- dithering" performance tweak so testers can compare with/without. Re-read on
-- each rebuild so toggling the setting takes effect on the next refresh.
function BookshelfWidget:_refreshDitherFlag()
    local colour = Screen.isColorEnabled and Screen:isColorEnabled()
    self.dithered = (colour and BookshelfSettings.nilOrTrue("color_panel_dithering"))
        or nil
end

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
            return "ui", Geom:new{ x = 0, y = below_y, w = self.width, h = self.height - below_y }, self.dithered
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
            return "ui", Geom:new{ x = 0, y = 0, w = self.width, h = bottom }, self.dithered
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
    -- User swiped/tapped to this chip: arm the OPDS fetch gate.
    self:_markOpdsNav()
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
--
-- chip_h comes from BandMetrics rather than being derived here: _rebuild
-- computes the same number for the strip it actually builds, and the two used
-- to be separate copies of the arithmetic.
function BookshelfWidget:_layoutPrimitives()
    local pad_natural = math.floor(Size.padding.fullscreen * 2 * 0.8)
    local pad_capped  = math.floor(self.width * 0.03)
    local PAD         = math.min(pad_natural, pad_capped)
    local content_w   = self.width - PAD * 2
    local chip_h      = BandMetrics.cellHeight(BandMetrics.CHIP_KEY)
    local footer_h = Screen:scaleBySize(32) + Size.padding.default * 2
    return PAD, content_w, chip_h, footer_h
end

-- _statusStripHeight(content_w) -> height, probe_book
--
-- The height the hero collapses to in expanded mode: HeroCard.buildStatusRow's
-- own rendered height, or a small fixed dp when there is no current book (or
-- the status region is switched off). Returns the record it probed with, so
-- _rebuild can hand it to _buildHero instead of opening the same DocSettings
-- twice.
--
-- Shared because two sites must agree on this number: _rebuild sizes the hero
-- to it, and _maxRows subtracts it from the height it hands the rows. The cover
-- grid survives a disagreement (shelf_h is derived by DIVIDING the leftover, so
-- a wrong estimate just makes every cover a little shorter); a list row's height
-- is fixed, so an underestimate paints the last row under the footer instead.
--
-- Memoised for one rebuild — _rebuild clears the memo on entry — so the probe
-- costs the same single DocSettings open it always did, however many times
-- _nShelves asks along the way. Between rebuilds the memo is deliberately KEPT:
-- it is then the height of the strip currently on screen, which is exactly what
-- a pagination handler reasoning about the live layout should see.
function BookshelfWidget:_statusStripHeight(content_w)
    local memo = self._strip_h_memo
    if memo and memo.content_w == content_w then return memo.h, memo.book end
    local probe_book = (self._preview_book and self._preview_book.filepath
                        and Repo.buildBook(self._preview_book.filepath))
                        or self._preview_book
                        or self:_currentHeroBook()
    local probe_row = probe_book and HeroCard.buildStatusRow(
                          probe_book, self:_buildDeviceState(), content_w, false)
    local h = probe_row and probe_row:getSize().h or Screen:scaleBySize(20)
    self._strip_h_memo = { content_w = content_w, h = h, book = probe_book }
    return h, probe_book
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
-- _coverAspect() — natural cover-height ratio for shelf-row height budgeting
-- and pagination row counts. 2:3 (1.5) normally; the 1.65 cap when "True cover
-- aspect ratio" is on, so the grid reserves enough vertical space for the
-- tallest untrimmed cover. Covers then render at their own aspect (fixed
-- width, variable height), bottom-anchored, up to that cap (see ShelfRow).
-- Every collapsed-grid site that derives a row height from slot width must use
-- this so the render, the vertical budget, and the row-count math stay in lockstep.
-- The aspect the ROW-COUNT maths reserves per row. Must be the same number
-- shelf_row sizes slots with, or the two disagree about how tall a row is:
-- this was a hardcoded 1.65 while SpineWidget.COVER_ASPECT_CAP was retuned to
-- 1.60, so tightening the cap shrank the covers and did not give back the row
-- it was tightened for.
function BookshelfWidget:_coverAspect()
    if not BookshelfSettings.isTrue("true_cover_aspect") then return 1.5 end
    local ok, SpineWidget = pcall(require, "lib/bookshelf_spine_widget")
    if ok and SpineWidget and SpineWidget.COVER_ASPECT_CAP then
        return SpineWidget.COVER_ASPECT_CAP
    end
    return 1.5
end

function BookshelfWidget:_bookGap(pad)
    if _readCoverSize() == "small" then
        return math.max(1, math.floor(pad * 0.75))
    end
    return pad
end

-- _collapsedGridSplit(hide_chip_bar, n_shelves, slot_h_natural)
--     -> shelf_h, hero_h
--
-- The collapsed layout's vertical split, for the COVER GRID: how tall a shelf
-- row is and how tall the hero card is. Lifted out of _rebuild's non-expanded
-- branch verbatim, because list mode now has to ask for the answer the cover
-- grid WOULD give — see _listCollapsedHeroHeight — and a second copy of this
-- arithmetic in the list path is exactly the kind of drift this file has paid
-- for before (see ListGeom's header on the row-height budget).
--
-- Every term is the one _rebuild spends, and the two callers differ only in
-- what they already know: _rebuild passes the n_shelves and slot_h_natural it
-- has computed, the counterfactual passes neither and they are derived here.
-- The cover-grid column count comes from _gridCols() rather than _nCols() so
-- this stays honest even if a caller forgets the _asCoverGrid pin: _nCols()
-- answers 1 in list mode, which would make one full-width "cover" 1.5 screens
-- tall. The pin is still required for n_shelves (_baseShelves reads the mode).
--
-- row_gap is written as PAD rather than self:_rowGap(PAD) for the same reason:
-- the collapsed cover grid's after-row gap IS PAD, and asking the mode-aware
-- helper for it would answer with the list hairline when called unpinned.
function BookshelfWidget:_collapsedGridSplit(hide_chip_bar, n_shelves, slot_h_natural)
    local PAD, content_w, chip_h = self:_layoutPrimitives()
    local label_h      = _footerReserveH()
    local chip_contrib = hide_chip_bar and 0 or chip_h
    n_shelves = n_shelves or self:_baseShelves()
    if n_shelves < 1 then n_shelves = 1 end
    if not slot_h_natural then
        local n_cols = self:_gridCols()
        if n_cols < 1 then n_cols = 1 end
        local book_gap = self:_bookGap(PAD)
        local slot_w   = math.floor((content_w - book_gap * (n_cols - 1)) / n_cols)
        slot_h_natural = math.floor(slot_w * self:_coverAspect())
    end
    local hero_chip_pad = PAD                   -- collapsed
    local row_gap       = PAD                   -- collapsed cover grid
    local total_pad = PAD + hero_chip_pad
                    + ((not hide_chip_bar) and PAD or 0)
                    + n_shelves * row_gap
    local available   = self.height - chip_contrib - label_h - total_pad
    local hero_target = math.floor(available * HERO_MIN_FRAC)
    local grid_title_block_h = 0
    if self:_shelfLabelMode() then
        local lscale = BookshelfSettings.read("expanded_shelf_font_scale") or 100
        local lsize  = math.floor(14 * lscale / 100 + 0.5)
        grid_title_block_h = Size.padding.default + math.floor(lsize * 1.3)
    end
    local lo  = math.floor(slot_h_natural * SHELF_PACK_FLOOR) + grid_title_block_h
    local hi  = math.floor(slot_h_natural * 1.0) + grid_title_block_h
    local raw = math.floor((available - hero_target) / n_shelves)
    local shelf_h = math.max(1, math.min(hi, math.max(lo, raw)))
    local hero_h  = math.max(hero_target, available - n_shelves * shelf_h)
    return shelf_h, hero_h
end

-- _listCollapsedHeroHeight(hide_chip_bar) — the hero a COLLAPSED list shows.
--
-- Exactly the height the cover grid would give it on the same screen with the
-- same settings, so flipping the view mode leaves the hero card untouched: the
-- maintainer's ask is "ideally staying the exact same size before/after the
-- list mode switch", and the only way to be exactly the same size is to be the
-- same number.
--
-- What it replaces: list mode used to fill the screen with rows and leave the
-- hero its HERO_MIN_FRAC floor, because _baseShelves answered _maxShelfRows()
-- and _rebuild then handed the hero whatever survived. Shorter rows therefore
-- bought MORE rows and a SMALLER hero -- the hero shrank on the flip, which is
-- the bug. Cover mode has always worked the other way round (size the hero,
-- then fit rows into the remainder) and that is now the shared order.
--
-- The clamp is the one thing the cover grid does not need. A cover hero is
-- sized against cover rows, and a list row is a different height entirely, so
-- on a short screen the counterfactual hero can be tall enough to leave no room
-- for even one row. Capped at "the band, less one row and its two margins", so
-- the list always shows something. Where the cap bites the hero is no longer
-- identical across the flip, and that is reported rather than hidden: the sweep
-- prints both numbers.
function BookshelfWidget:_listCollapsedHeroHeight(hide_chip_bar)
    local PAD, _content_w, chip_h = self:_layoutPrimitives()
    local hero_h = _asCoverGrid(function()
        local _shelf_h, h = self:_collapsedGridSplit(hide_chip_bar)
        return h
    end)
    if type(hero_h) ~= "number" then
        -- _asCoverGrid swallowed an error. Fall back to the floor the old
        -- model gave, rather than rendering a heroless screen.
        hero_h = math.floor(self.height * HERO_MIN_FRAC)
    end
    local chip_contrib = hide_chip_bar and 0 or chip_h
    local room = self.height - PAD - _footerReserveH() - chip_contrib
               - (hide_chip_bar and 0 or PAD)
    -- The MINIMUM row, not the current one. What this cap says is "the hero
    -- must leave room for at least one row", and the minimum is exactly that
    -- -- but it is also the only version that terminates: the row height is
    -- now solved from the band, the band is what is left after the hero, and
    -- asking for it here would have the two call each other forever.
    local cap = room - 2 * PAD - self:_listMinRowHeight()
    if hero_h > cap then hero_h = cap end
    if hero_h < 1 then hero_h = 1 end
    return hero_h
end

-- _listBandPlan(expanded, hide_chip_bar) -> plan
--
-- The whole of list mode's vertical layout, in one place, because three
-- callers have to agree about it to the pixel: _maxShelfRows (the collapsed
-- row count), _maxRows (the expanded one) and _rebuild (which lays the rows
-- down). They each carried their own copy of the chrome sum before, and the
-- copies were already subtly different -- one used _footerReserveH and one
-- _layoutPrimitives' smaller approximation, and each had its own idea of what
-- to subtract for the gap after the last row.
--
-- plan = {
--   hero_h        the hero card (collapsed) or status strip (expanded)
--   hero_chip_pad the span between the hero and the chip strip
--   base_top_pad  the span the plan wants immediately above row 1
--   min_edge_pad  the span it will settle for, to keep a row that would
--                 otherwise not fit
--   band          top_gap + rows + bottom_gap: everything between the chip
--                 strip (or the hero, when the strip is hidden) and the
--                 footer reservation
--   row_h, row_gap
--   rows          how many rows fit, honouring the symmetric margin
--   top_gap, bottom_gap, top_extra   the split for `rows` rows
-- }
--
-- THE MARGINS are the maintainer's second ruling: "There should always be at
-- least the same gap at the bottom of the list above the footer icons, as
-- there is at the top of the list between the chip bar and the first row ...
-- this will often mean losing a row, that's fine." The list used to pack rows
-- until they ran out of screen and leave the hairline row gap (one pixel on
-- most panels) above the footer, against a full PAD above the first row.
--
-- "At least" is a MINIMUM. An earlier revision read it as an equality and split
-- the leftover evenly, which turned the top margin into a modular remainder --
-- see the split itself, below, for the measurements. The ruling that settles it
-- is "keep the top padding the standard amount, leave a larger gap at the
-- bottom if there's no room for another row", so:
--
--   top_gap    = base_top_pad, the standard pad, fixed
--   bottom_gap = everything the rows did not use
--
-- ...with one later exception, "add a bit more leeway for the last row to be
-- filled". Where dropping the top gap to min_edge_pad buys a row the band
-- would otherwise waste, the plan takes the row and both gaps fall together.
--
-- Implemented as a budget, not as a second spacer mechanism fighting the
-- existing one. The row COUNT reserves min_edge_pad at BOTH ends -- see there
-- for why it is the floor rather than the want, and for what that trades away
-- -- so the bottom can never come out smaller than the top; _rebuild adjusts
-- the span above row 1 by top_extra, and its existing layout_slack absorber --
-- which already parks the remainder under the last row -- lands on bottom_gap
-- without being told.
-- _listBand(expanded, hide_chip_bar) -> the vertical space the ROWS get, plus
-- the three padding numbers the plan and the row height both need.
--
-- Split out of _listBandPlan so _listRowHeight can ask for the band without
-- asking for the plan: the plan now needs the row height, so the two would
-- otherwise call each other forever.
function BookshelfWidget:_listBand(expanded, hide_chip_bar)
    return self:_listGeomMemo(
        "band:" .. tostring(expanded and 1 or 0)
                .. tostring(hide_chip_bar and 1 or 0),
        function() return self:_listBandUncached(expanded, hide_chip_bar) end)
end

function BookshelfWidget:_listBandUncached(expanded, hide_chip_bar)
    local PAD, content_w, chip_h = self:_layoutPrimitives()
    hide_chip_bar = hide_chip_bar and true or false
    local hero_chip_pad = expanded and Size.padding.large or PAD
    local hero_h
    if expanded then
        hero_h = self:_statusStripHeight(content_w)
    else
        hero_h = self:_listCollapsedHeroHeight(hide_chip_bar)
    end
    local chip_contrib = hide_chip_bar and 0 or chip_h
    -- When the chip strip is hidden the hero→chips span IS the gap above row 1,
    -- so it belongs inside the band rather than above it.
    --
    -- TWO numbers, and conflating them is a bug this already shipped once.
    --
    --   layout_top_pad  what the LAYOUT already lays down above row 1 -- the
    --                   span _rebuild emits before the first row. Not a
    --                   preference; a fact about the widget tree.
    --   base_top_pad    what the plan WANTS that gap to be.
    --
    -- They used to be the same value, and top_extra -- the correction _rebuild
    -- adds to the span it already carries -- was written as
    -- top_gap - base_top_pad. Halving base_top_pad alone therefore changed
    -- nothing on screen: top_gap came back equal to the halved base, the
    -- correction computed as zero, and the layout went on emitting the full
    -- PAD. The rows still gained the room, so the budget and the layout
    -- disagreed by half a PAD -- the optimistic direction, which is the one
    -- that paints the last row under the footer.
    --
    -- HALVED on the maintainer's ruling: "reduce the padding above the listing
    -- by half the existing pad amount - and make the equivalent change to the
    -- bottom". The cover grid's PAD is sized to separate blocks of ARTWORK; a
    -- table wants far less air between the chip strip and its first rule.
    --
    -- Halving the WANT rather than the render is what makes it "the equivalent
    -- change to the bottom" for free: base_top_pad is reserved twice in the row
    -- budget below, once per end.
    local layout_top_pad = hide_chip_bar and hero_chip_pad or PAD
    local base_top_pad   = math.floor(layout_top_pad / 2)
    local band = self.height - PAD - hero_h - _footerReserveH()
               - chip_contrib - (hide_chip_bar and 0 or hero_chip_pad)
    -- rowsThatFit counts the gaps BETWEEN rows, which is exactly the dividers
    -- the layout paints; the span after the LAST row is bottom_gap and is
    -- reserved here rather than counted as a row cost.
    --
    -- THE THIRD NUMBER: min_edge_pad, the margin the count is not allowed to
    -- go below. base_top_pad is what the plan WANTS at each end; this is what
    -- it will settle for to keep a row that would otherwise be thrown away.
    --
    -- Reserving the full want at both ends is what the count used to do, and
    -- it discards a row for as little as one pixel. Measured on the
    -- maintainer's own four-line layout on the PW5: band 793, row 253, so
    -- three rows need 761 and the reservation left 757 -- four pixels short,
    -- and the screen rendered two rows above 271px of white, which is more
    -- than a whole row of it. "What's on screen now looks like it could cope
    -- with an extra row" is that arithmetic seen from the other side.
    --
    -- Half the want, so the leeway is exactly one base_top_pad of band. Of the
    -- eight sweep cases it moves two -- a PW5 one-line collapsed list 14 -> 15
    -- rows and a PW3 two-line one 8 -> 9 -- and leaves the other six alone,
    -- which is the shape wanted: it claws back the row that nearly fitted and
    -- does not start shaving margins that were never in the way.
    --
    -- IT COSTS THE TOP GAP, in the cases where it buys the row, and that is a
    -- deliberate departure from "keep the top padding the standard amount".
    -- The extra row can only come out of the margins -- there is nowhere else
    -- in the band -- so one of the two earlier rulings has to give. The split
    -- below spends it SYMMETRICALLY (top and bottom both fall to slack/2)
    -- rather than taking it all from the bottom, which keeps the other ruling,
    -- "the bottom gap is at least the top gap", intact and keeps the block
    -- centred in its band instead of hanging off the chip strip.
    local min_edge_pad = math.floor(base_top_pad / 2)
    return {
        band           = band,
        hero_h         = hero_h,
        hero_chip_pad  = hero_chip_pad,
        layout_top_pad = layout_top_pad,
        base_top_pad   = base_top_pad,
        min_edge_pad   = min_edge_pad,
    }
end

-- _listBandPlan(expanded, hide_chip_bar) -> everything _rebuild and the row
-- counters need: the band, the row height, how many rows, and where the slack
-- goes.
--
-- The row height is the reader's now (see _listRowHeight), so the COUNT is no
-- longer solved from it -- except when the shelf is expanded, where the extra
-- band buys extra ROWS at the same height rather than taller ones.
function BookshelfWidget:_listBandPlan(expanded, hide_chip_bar)
    -- Memoised like the band under it. The inputs were all cached already, so
    -- each call was cheap arithmetic -- but SIXTEEN calls per rebuild
    -- (measured; _nShelves alone accounts for eight) meant sixteen copies of
    -- the perf log line per rebuild, and a dbg write is real I/O on a Kindle.
    return self:_listGeomMemo(
        "plan:" .. tostring(expanded and 1 or 0)
                .. tostring(hide_chip_bar and 1 or 0),
        function() return self:_listBandPlanUncached(expanded, hide_chip_bar) end)
end

function BookshelfWidget:_listBandPlanUncached(expanded, hide_chip_bar)
    local ListGeom = require("lib/bookshelf_list_geom")
    local b = self:_listBand(expanded, hide_chip_bar)
    local band, hero_h, hero_chip_pad = b.band, b.hero_h, b.hero_chip_pad
    local layout_top_pad = b.layout_top_pad
    local base_top_pad   = b.base_top_pad
    local min_edge_pad   = b.min_edge_pad
    local row_h   = self:_listRowHeight()
    local row_gap = self:_listRowGap()
    local rows = ListGeom.rowsThatFit(band - 2 * min_edge_pad, row_h, row_gap)
    -- Collapsed, the reader's count is the answer as long as it fits -- and it
    -- is what row_h was solved against, so it does. Expanded, the hero has
    -- shrunk to a strip and the extra band shows MORE rows of the same height.
    if not expanded then
        rows = self:_listRows(rows) or rows
    end
    local block = rows * row_h + (rows - 1) * row_gap
    local slack = band - block
    if slack < 0 then slack = 0 end
    -- THE TOP GAP IS A DESIGNED VALUE; THE BOTTOM GAP IS WHAT IS LEFT.
    --
    -- It used to be an even split -- floor(slack / 2) at the top, the rest at
    -- the bottom -- and that made the top margin a MODULAR REMAINDER dressed
    -- up as a margin. slack is `band - block`, and block is a whole number of
    -- rows, so slack is `2 * base_top_pad + ((band - 2 * base_top_pad) mod
    -- (row_h + row_gap))`. Half of that residue landed on top of the intended
    -- pad. Its scale is the ROW HEIGHT, so a two-line item doubles the worst
    -- case: the maintainer measured 74px above row 1 on a Paperwhite 5 where
    -- the intended pad is 37, against a half-row of ~57. The clearest proof it
    -- carried no intent is that shortening the row moved a stock panel's
    -- margin 41 -> 87 while moving the same panel's expanded figure 71 -> 48,
    -- in opposite directions, from one change.
    --
    -- base_top_pad IS the standard padding: the span the layout already
    -- carries immediately above row 1 -- PAD with the chip strip up, which is
    -- the same PAD the cover grid spends between the chips and its first shelf
    -- row, and the hero->row1 span without it. Taking it verbatim is what
    -- makes the top gap the same in list mode as in cover mode, rather than a
    -- second opinion about what a standard pad is.
    --
    -- The maintainer's ruling, verbatim: "keep the top padding the standard
    -- amount, leave a larger gap at the bottom if there's no room for another
    -- row". So the surplus is NOT equalised, capped, spent on the hero (whose
    -- height must not move -- see _listCollapsedHeroHeight) or dealt back into
    -- the rows. It sits below the last row, which is where "no room for
    -- another row" is visible, and satisfies the earlier ruling that the
    -- bottom gap be AT LEAST the top one -- a minimum, not an equality.
    --
    -- The min() fires in TWO cases now, and it used to be one.
    --
    --   * The band bought a row with the leeway above. slack is then somewhere
    --     between 2 * min_edge_pad and 2 * base_top_pad, and both ends take
    --     half of it. This is the ordinary case on a panel where the rows
    --     nearly fit, and it is the price of the extra row.
    --   * The starved band: rowsThatFit floors at 1, so a band that cannot
    --     hold one row plus both minimums still gets a row, and slack can fall
    --     below 2 * min_edge_pad or to nothing at all.
    --
    -- Both want the same answer -- an even split, odd pixel to the bottom --
    -- because it is the only rule that keeps bottom_gap >= top_gap when
    -- neither end can have what it wants. Above 2 * base_top_pad of slack the
    -- min() picks base_top_pad and the top gap is the standard pad exactly, as
    -- before.
    local top_gap = math.min(base_top_pad, math.floor(slack / 2))
    -- THE perf line for this plan, in the one place it is computed. The
    -- callers used to log it per call, which multiplied a cached lookup into
    -- sixteen identical lines per rebuild.
    logger.dbg(string.format(
        "[bookshelf perf] listBandPlan(%s%s) rows=%d row_h=%d gap=%d band=%d "
        .. "hero=%d top=%d bottom=%d",
        expanded and "exp" or "col", hide_chip_bar and ",nochips" or "",
        rows, row_h, row_gap, band, hero_h, top_gap, slack - top_gap))
    return {
        hero_h        = hero_h,
        hero_chip_pad = hero_chip_pad,
        base_top_pad  = base_top_pad,
        min_edge_pad  = min_edge_pad,
        band          = band,
        row_h         = row_h,
        row_gap       = row_gap,
        rows          = rows,
        top_gap        = top_gap,
        bottom_gap     = slack - top_gap,
        layout_top_pad = layout_top_pad,
        -- SIGNED: what _rebuild adds to the span it ALREADY carries to reach
        -- top_gap. Measured against layout_top_pad, never against
        -- base_top_pad: the span in the tree is the full pad, so a correction
        -- computed against the halved want would be off by the difference and
        -- the screen would not move. Normally negative now, since the plan
        -- wants half of what the layout lays down.
        top_extra      = top_gap - layout_top_pad,
    }
end

-- _maxRows() — max natural-cover rows that fit at the current n_cols
-- assuming the hero collapses to its minimum (status strip only). Used
-- as the expanded-mode row count and as the ceiling _baseShelves works
-- back from. Pure function of self dimensions + cover-size setting.
function BookshelfWidget:_maxRows()
    local PAD, content_w, chip_h, footer_h = self:_layoutPrimitives()
    -- List mode budgets by ROW HEIGHT, not by cover aspect: a list row is as
    -- tall as its text (or its thumbnail) says, and nothing about it scales
    -- with the column width. The cover-grid maths below would read _nCols() as
    -- 1 and compute a full-content_w slot 1.5x as tall as the screen, i.e. one
    -- row, every time. Same chrome sum as the cover branch, so both modes agree
    -- about how much vertical space the shelves are allowed.
    if self:_isListMode() then
        -- Every term the row count spends is _listBandPlan's, because a list
        -- row cannot absorb a mismatch the way a cover row does (there,
        -- shelf_h is whatever is left over divided by the row count; here it
        -- is a constant), and because _rebuild lays the rows down from the
        -- SAME plan. Get the budget wrong in the optimistic direction and the
        -- last row paints under the screen-anchored footer: layout_slack is
        -- only ever applied when positive, so nothing downstream catches it.
        -- No log here: the plan logs itself, once, when it is actually
        -- computed. Sixteen callers re-logging a cached table per rebuild was
        -- measured, and a dbg write is real I/O on a Kindle.
        return self:_listBandPlan(true, self._chip_bar_hidden).rows
    end
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
    local slot_h = math.floor(slot_w * self:_coverAspect())
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
    local out = math.max(1, math.floor(available / row_h))
    -- Every input to the row-count decision, because the arithmetic cannot be
    -- reproduced off-device (PAD, chip_h and footer_h are all screen-derived)
    -- and "why 3 rows and not 4" is otherwise pure guesswork. Issue #329.
    logger.dbg(string.format(
        "[bookshelf perf] _maxRows=%d cols=%d slot=%dx%d aspect=%.2f row_h=%d "
        .. "avail=%d (h=%d top=%d strip=%d herogap=%d chip=%d chippad=%d footer=%d)",
        out, n_cols, slot_w, slot_h, self:_coverAspect(), row_h, available,
        self.height, outer_top_pad, strip_minimum, hero_chip_pad, chip_h,
        chip_to_row_pad, footer_h))
    return out
end

-- _maxShelfRows() — the most shelf rows that fit at natural cover height
-- while still leaving the hero its minimum (HERO_MIN_FRAC) slice. Rows is
-- clamped to this so the grid + a usable hero never overflow the screen.
function BookshelfWidget:_maxShelfRows()
    local PAD, content_w, chip_h, footer_h = self:_layoutPrimitives()
    -- Same substitution as _maxRows: fixed row height instead of a
    -- cover-aspect budget, but still leaving the hero its HERO_MIN_FRAC slice
    -- so the collapsed list keeps a usable hero above it.
    if self:_isListMode() then
        -- No search, and no hero fraction, any more. The collapsed hero is
        -- decided FIRST and independently -- it is whatever the cover grid
        -- would show (see _listCollapsedHeroHeight) -- so the circularity that
        -- forced the previous revision to step a candidate count down until it
        -- satisfied a fraction-of-the-remainder test is simply gone: the band
        -- left for rows is a constant before the first row is counted.
        return self:_listBandPlan(false, self._chip_bar_hidden).rows
    end
    local n_cols = self:_nCols()
    if n_cols < 1 then return 1 end
    local slot_w = math.floor((content_w - PAD * (n_cols - 1)) / n_cols)
    if slot_w < 1 then return 1 end
    local slot_h = math.floor(slot_w * self:_coverAspect())
    local hero_chip_pad = Size.padding.large
    local usable = self.height - PAD - hero_chip_pad - chip_h - PAD - footer_h
    local row_unit = math.floor(slot_h * SHELF_PACK_FLOOR) + PAD
    if row_unit < 1 then return 1 end
    local min_hero = math.floor(usable * HERO_MIN_FRAC)
    local out = math.max(1, math.floor((usable - min_hero) / row_unit))
    logger.dbg(string.format(
        "[bookshelf perf] _maxShelfRows=%d slot_h=%d row_unit=%d usable=%d min_hero=%d",
        out, slot_h, row_unit, usable, min_hero))
    return out
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
    -- The explicit bookshelf_rows setting is a COVER-GRID number: the user
    -- chose it in the Columns/Rows editor while looking at cover rows, against
    -- cover heights. A list row is a different size entirely, so honouring that
    -- number here would leave a screen half empty (or clipped) depending on
    -- which way the two heights happen to differ. List mode simply fills.
    if self:_isListMode() then return self:_maxShelfRows() end
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
    local slot_h = math.floor(slot_w * self:_coverAspect())
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
    -- No log line here any more, same treatment as the band plan's: this is a
    -- CALLER, asked eight times per rebuild, and everything it printed is
    -- logged once where it is computed (_maxShelfRows for the cover split,
    -- listBandPlan for the list). The old line was worse than spam -- it
    -- called _baseShelves() and _maxRows() purely to print them, so in cover
    -- mode every _nShelves call did its geometry twice.
    if self._expanded then
        -- List mode takes the count that FITS, full stop. The +1 below is
        -- affordable for covers because ShelfRow squashes them to make room; a
        -- list row's height is a constant, so an extra row is simply painted
        -- past the bottom of the screen, under the anchored footer (layout_slack
        -- is only ever applied when positive, so nothing downstream catches it).
        -- Measured on a 1648x1248 landscape screen, where collapsing the hero to
        -- its status strip frees 97px and a row needs 195: _maxRows says 4,
        -- _baseShelves + 1 asked for 5, and the fifth row hung 70px off the
        -- bottom. Same rows expanded as collapsed there, with the freed pixels
        -- spread between them, is the honest answer.
        if self:_isListMode() then return self:_maxRows() end
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
-- The list's own column count: how many items sit side by side on one row.
--
-- One by default. Two is the top request off the preview thread, and on a
-- 1248px panel two columns of a two-line row is a genuinely different way to
-- browse -- twice the books per page, at the cost of the width a long title
-- needs.
--
-- The MINIMUM is what stops it being a foot-gun. A second column is only worth
-- having if each half can still hold a recognisable title; below that the row
-- degenerates into two columns of ellipses.
--
-- 190dp is roughly "a cover thumbnail, a tick gutter and twenty-odd characters
-- of title", measured against a rendered two-line row rather than guessed. The
-- first attempt at 260 was too cautious in a way that mattered: it clamped
-- three columns to two on a PW5, i.e. on the flagship device the setting was
-- offered on, which reads as the option being broken rather than as the screen
-- being too small.
local LIST_COLUMNS_MAX  = 3
local LIST_MIN_COL_DP   = 190

function BookshelfWidget:_listCols()
    local n = self:_chipListValue("list_columns")
    if type(n) ~= "number" then return 1 end
    n = math.max(1, math.min(LIST_COLUMNS_MAX, math.floor(n)))
    if n == 1 then return 1 end
    local PAD, content_w = self:_layoutPrimitives()
    local min_w = Screen:scaleBySize(LIST_MIN_COL_DP)
    -- n columns cost n*min_w + (n-1)*PAD. Solve for the most that fit and take
    -- the smaller of that and what the user asked for, so a phone-sized screen
    -- or a landscape flip silently degrades to one column instead of rendering
    -- unusable slivers.
    local fit = math.floor((content_w + PAD) / (min_w + PAD))
    return math.max(1, math.min(n, fit))
end

function BookshelfWidget:_nCols()
    -- List mode routes through its OWN column count, and that single fact is
    -- what lets the entire cursor stack (_viewSize, _pageSize, _clampCursor,
    -- _maxCursor, _advanceCursor, _moveCursor, _setCursorToShow, the page-jump
    -- dialog and the OPDS open-ended lookahead headroom) work unchanged:
    -- _viewSize() is literally _nShelves() * _nCols(). A parallel
    -- list-pagination path would duplicate ~200 lines of arithmetic that has
    -- already absorbed #329 and the misaligned-cursor rework -- and would have
    -- had to grow a second column concept of its own the moment this one did.
    --
    -- The cost of the shortcut is that every consumer using _nCols() for cover
    -- SIZING arithmetic gets a nonsense input (a slot sized for list columns,
    -- against the cover aspect), so those sites branch on _isListMode() first:
    -- _maxRows, _maxShelfRows, _baseShelves, _currentSlotDims, and both
    -- _kickOffMissingMetaExtraction call sites. That branching was already
    -- required when this returned a flat 1, so multi-column list mode needed no
    -- new guards -- only the RENDER had to learn to put more than one item on a
    -- row.
    if self:_isListMode() then return self:_listCols() end
    return self:_gridCols()
end

-- _gridCols() — the COVER GRID's column count, whatever mode is on screen.
-- _nCols's body, split out so the Columns/Rows editor can ask what the grid
-- is set to while list mode is showing: that editor SAVES what it reads, and
-- reading 1 there would rewrite bookshelf_columns to the minimum on the first
-- "+" tap. Nothing else should call this — the renderer wants _nCols.
function BookshelfWidget:_gridCols()
    -- The GLOBAL, on purpose, and not the chip layer: "column numbers for
    -- cover view cannot be per chip as it changes the layout of the whole
    -- screen (hero size and chip bar position)". A cover slot's width decides
    -- its height, the rows' height decides the hero's, so a per-chip count
    -- would make the entire screen jump on every chip switch. List columns
    -- ARE per chip -- they only divide the shelf band and nothing above it
    -- moves. Falls back to the legacy cover-size mapping when unset.
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

-- _gridBaseRows() / _gridMaxRows() — the COVER GRID's row count and row
-- ceiling, whatever mode is on screen. Same reason as _gridCols: the
-- Columns/Rows editor writes back what it reads, and in list mode
-- _baseShelves() answers with a count of LIST rows, which would land in
-- bookshelf_rows as a cover-grid row count and resize the grid the user
-- returns to. Renderers must keep calling _baseShelves / _maxShelfRows.
function BookshelfWidget:_gridBaseRows()
    return _asCoverGrid(function() return self:_baseShelves() end)
end

function BookshelfWidget:_gridMaxRows()
    return _asCoverGrid(function() return self:_maxShelfRows() end)
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
    -- The landscape 5 is a COVER-GRID number: one row of five covers, standing
    -- in for the rows × columns product on a screen where _nCols derives the
    -- count from cover height. List mode has its own product (n rows × 1
    -- column) and must use it — a fixed 5 against a view showing fewer rows
    -- skips books nothing can then reach, and against more rows repeats the
    -- overlap the cursor rework removed.
    if self:_isLandscape() and not self:_isListMode() then return 5 end
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
-- An open-ended OPDS window adds one page of headroom: the total is only
-- what's cached, and the cursor MUST be allowed one view past it, because
-- that overshooting read is exactly what sets opds_needs_fetch and pulls the
-- next feed page in. Clamping to the cached total pins the user at the end
-- of the window forever.
--
-- The headroom is granted ONLY while a user navigation is in flight
-- (_opds_nav_pending, armed by the page-turn gestures and consumed by the
-- render that follows). Otherwise it would also legitimise a cursor that has
-- no fetch behind it: a persisted cursor restored at launch, or one left past
-- the window by a fetch that failed. Passive clamps therefore pull the cursor
-- back onto real books, which is what makes the out-of-range state
-- self-healing rather than sticky.
function BookshelfWidget:_maxCursor(total)
    local view = self:_viewSize()
    local n_pages
    if total and total > 0 then
        n_pages = math.max(1, math.ceil(total / view))
    else
        n_pages = math.max(1, self._total_pages or 1)
    end
    if self._opds_open_ended and self._opds_nav_pending then
        n_pages = n_pages + 1
    end
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

-- _previewNeighbourBook(direction) — step self._preview_book one book along
-- the VISIBLE page, wrapping at either end. direction = +1 for next, -1 for
-- previous. Folder and series tiles have no filepath and are skipped: only
-- books can be previewed.
--
-- Scoped to the page on purpose. The shelf does not move (that was #303 --
-- recomputing the cursor here snapped it back to page 1), so a cycle that ran
-- past the page edge would preview books the user cannot see while the shelf
-- sat still. One page, cycling, is what the hero can actually show (#325).
--
-- The page window has TWO shapes, and conflating them is what broke the cycle:
-- window-fetched sources (Home, folder drills, group drills, search, OPDS)
-- return just the visible page, indexed 1..view, and signal that by returning
-- a total alongside it; everything else returns the whole list, which
-- _rebuild slices with the absolute cursor. `first` below is the one line
-- that has to know the difference -- reading the absolute cursor against a
-- page-local list put EVERY item out of view, so the anchor was always
-- discarded and the swipe landed on the page's first or last book every time
-- rather than stepping (#325).
function BookshelfWidget:_previewNeighbourBook(direction)
    local all_items, total_hint = self:_fetchChipItems(400)
    all_items = all_items or {}
    local view  = self:_viewSize()
    local first = total_hint and 1 or (self._cursor or 1)
    local last  = math.min(first + view - 1, #all_items)
    local books = {}
    for i = first, last do
        local item = all_items[i]
        if item and item.filepath then books[#books + 1] = item end
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
    -- Nothing previewed on this page yet (first swipe, or the user paged away
    -- since): start just off the edge so the step below lands on the page's
    -- first book going forward, its last going back.
    if not current_idx then
        current_idx = direction > 0 and 0 or 1
    end
    local next_idx = ((current_idx - 1 + direction) % n) + 1
    local target = books[next_idx]
    if not target or not target.filepath then return end
    if self._preview_book and self._preview_book.filepath == target.filepath then
        return  -- single-book page; cycling would otherwise re-trigger open
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
    -- List mode must NOT fall through to the grid-slot derivation below: at
    -- _nCols() == 1 it computes a slot the full content width and 1.5x as tall,
    -- so the preloader would warm every next-page cover at poster size. With no
    -- cover column there is nothing to warm at all.
    if self:_isListMode() then
        local ListGeom = require("lib/bookshelf_list_geom")
        if not self:_listLines().show_cover then return nil end
        -- Only reached before the first list render has reported real dims.
        -- ListGeom.thumbSize takes the ROW height and subtracts the ring
        -- itself, so this is the same arithmetic ListRow.pageLayout runs and
        -- the warmed cover is exactly the size the render will ask for. The
        -- old form passed the row height with the PAD taken off instead of the
        -- ring, deliberately over-estimating on the grounds that
        -- ScaledCoverCache's "cached >= requested" test still hits -- true, but
        -- it hits with a bb bigger than any row can use, pinned in a cache
        -- sized for the real ones. Exact is strictly better than generous here.
        local ListRow = require("lib/bookshelf_list_row")
        return ListGeom.thumbSize(self:_listRowHeight(), ListRow.RING)
    end
    local n = self:_nCols()
    if not n or n < 1 then return nil end
    local sw = math.floor((d.content_w - (d.book_gap or d.PAD or 0) * (n - 1)) / n)
    if sw < 1 then return nil end
    return sw, math.floor(sw * self:_coverAspect())
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
-- Slower cadence while another widget covers the shelf: the tick skips the
-- disk snapshot entirely in that state, so a 5s re-arm is pure wakeup cost.
local FILE_POLL_COVERED_INTERVAL_S = 30

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
    -- Also watch the stock effective download folder (OPDS / cloud storage /
    -- news downloader target). It may sit deeper than the depth-1 watch set,
    -- where a landing file changes only ITS mtime. One extra stat per tick.
    local FilePoll = require("lib/bookshelf_file_poll")
    local dl = FilePoll.effectiveDownloadDir(function(k)
        return G_reader_settings:readSetting(k)
    end)
    if dl and snap[dl] == nil then
        local ok_d, da = pcall(lfs.attributes, dl)
        if ok_d and da and da.mode == "directory" then
            snap[dl] = da.modification or 0
        end
    end
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
    -- Self-correcting visibility guard (#304): the poll is only meant to run
    -- while this widget is the actual foreground thing. It's normally
    -- cancelled via _stopStatusTimer (onCloseWidget / _launchReader /
    -- onSuspend), but a book opened by a route that bypasses all three --
    -- e.g. KOReader's own History/Collections screens, or a Dispatcher
    -- action that calls ReaderUI:showReader directly -- never hits any of
    -- them, so the poll would otherwise keep re-arming and waking the
    -- device every FILE_POLL_INTERVAL_S for the rest of that reading
    -- session. isWidgetShown is a stack-membership check (true even while
    -- hot-parked underneath a reader), so this specifically needs
    -- getTopmostVisibleWidget, the same check onResume already uses.
    if UIManager:getTopmostVisibleWidget() ~= self then
        -- Covered. Cancel only for the #304 battery case (an active reading
        -- session) or when the shelf is gone from the stack; for a TRANSIENT
        -- cover (stock OPDS browser, terminal, ...) idle instead: skip the
        -- disk snapshot but keep the tick and, critically, the pre-cover
        -- mtime baseline - re-arming via _startFilePoll re-baselines, which
        -- silently swallows any file that arrived while covered.
        local FilePoll = require("lib/bookshelf_file_poll")
        local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
        local ok_park, Park = pcall(require, "lib/bookshelf_reader_park")
        local decision = FilePoll.coveredDecision{
            shelf_on_stack = UIManager:isWidgetShown(self) == true,
            reader_active  = (ok_rui and ReaderUI and ReaderUI.instance ~= nil) or false,
            reader_parked  = (ok_park and Park and Park.isParked()) or false,
        }
        if decision == "cancel" then
            self:_cancelFilePoll()
            return
        end
        if self._file_poll_fn then
            -- Idle tick: the snapshot is skipped while covered, so the 5s
            -- cadence buys nothing but wakeups (12/min behind any open menu
            -- or dialog). Re-arm slower; the first uncovered tick after the
            -- cover closes still compares against the pre-cover baseline, so
            -- nothing is missed, just noticed within 30s instead of 5s.
            UIManager:scheduleIn(FILE_POLL_COVERED_INTERVAL_S, self._file_poll_fn)
        end
        return
    end
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
    -- Selection/focus is per-page: clear the d-pad focus cell and any pending
    -- tap-to-open selection before the page changes, so their highlight can't
    -- reappear on a DIFFERENT book at the same grid position on the new page
    -- (issue #265). The hero-preview highlight (a real, filepath-matched book
    -- choice) is left alone. D-pad arrow paging goes through _moveCursor, not
    -- here, so key navigation keeps its focus cell.
    self:_clearDpadFocus()
    self._tap_selected_fp = nil
    local _diag_t0     = _gettime()
    local _diag_page0  = self.page
    local total = self._total_pages or 1
    -- Open-ended OPDS window: total_pages counts the cached window only, so
    -- "already on the last page" is wrong -- stepping past it is what fetches
    -- the next feed page. Without this the swipe wraps to page 1 instead and
    -- the feed can never grow (the chevron path has the same allowance via
    -- _maxCursor's headroom).
    if self.page < total or self._opds_open_ended then
        -- Armed inside the branch, not at the top: the no-op legs below return
        -- without rebuilding, and a flag armed there would sit waiting for the
        -- next PASSIVE rebuild (file poll, resume) to spend it on a fetch the
        -- user never asked for. Must precede _advanceCursor, which reads it
        -- through _maxCursor for the open-ended headroom.
        self:_markOpdsNav()
        self:_advanceCursor(1)
        self:_syncPageFromCursor()
        self._wipe_dir = 1   -- animate this pagination (next)
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
        self:_markOpdsNav()
        self._cursor = 1
        self:_syncPageFromCursor()
        self._wipe_dir = 1   -- animate this pagination (next)
        self:_swapShelvesInPlace()
        self:_schedulePreload(1)
        logger.dbg(string.format(
            "[bookshelf perf] paginate: dir=next at end -> wrap to first page elapsed=%.0fms",
            (_gettime() - _diag_t0) * 1000))
    end
    return true
end

function BookshelfWidget:_paginatePrev()
    -- See _paginateNext: clear per-page focus/tap-selection so a stale grid
    -- position can't re-highlight a different book on the new page (issue #265).
    self:_clearDpadFocus()
    self._tap_selected_fp = nil
    local _diag_t0    = _gettime()
    local _diag_page0 = self.page
    if self.page > 1 then
        -- See _paginateNext: armed per-branch, never at the top.
        self:_markOpdsNav()
        self:_advanceCursor(-1)
        self:_syncPageFromCursor()
        self._wipe_dir = -1  -- animate this pagination (prev)
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
        -- Evaluated BEFORE the flag is armed, deliberately: _maxCursor only
        -- grants the open-ended headroom while a navigation is in flight, so
        -- this wrap targets the last page with real books rather than the
        -- blank fetch-me page one beyond it.
        local last_cursor = self:_maxCursor()
        if total > 1 and self._cursor < last_cursor then
            self:_markOpdsNav()
            self._cursor = last_cursor
            self:_syncPageFromCursor()
            self._wipe_dir = -1  -- animate this pagination (prev, wrap)
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

-- Device Back key: pop one drilldown level when drilled in (#239).
-- Returning false at top level lets the event keep falling through to
-- whatever KOReader would do without us (unchanged behaviour).
function BookshelfWidget:onBSDrillBack()
    local n = self._drilldown_path and #self._drilldown_path or 0
    if n > 0 then
        self:_drillBackTo(n - 1)
        return true
    end
    return false
end

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

-- Flip the chip STRIP's page (the paging the edge chevrons / a swipe on the
-- strip do), as a gesture-assignable action (#257) -- the chevrons sit at
-- the far screen edges, out of one-handed reach. Wraps at either end so a
-- single repeated gesture cycles through every page. No-op while drilled
-- into a folder (breadcrumb mode never sets _pages) or with one page.
function BookshelfWidget:_flipChipPage(direction)
    if self._chip_bar_hidden then return true end
    local bar = self._chip_bar
    local pages = bar and bar._pages
    if not pages then return true end
    local num = math.max(1, pages.num_pages)
    if num <= 1 then return true end
    local cur = bar._page or 1
    bar:_gotoPage(((cur - 1 + direction) % num) + 1)
    return true
end

function BookshelfWidget:onBookshelfNextChipPage()
    return self:_flipChipPage(1)
end

function BookshelfWidget:onBookshelfPrevChipPage()
    return self:_flipChipPage(-1)
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
        -- No bulk selection over a catalog view: the tiles are remote
        -- records (OPDS pseudo-paths), and every bulk action - move, delete,
        -- collections - operates on local files. Entering the mode here
        -- would render a selection UI that can select nothing.
        if self:_opdsEffectiveTab() then
            UIManager:show(require("ui/widget/notification"):new{
                text = _("Bulk selection isn't available in remote catalog views."),
            })
            return true
        end
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

-- Dispatcher entry point for "select all books in this shelf" (issue #320).
function BookshelfWidget:onBookshelfSelectAllInView()
    self:_selectAllInView()
    return true
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
-- Draft regrid: a normal _rebuild with SpineWidget draft mode raised for its
-- (synchronous) duration, so grid + hero covers reuse cached bitmaps rescaled
-- to the new slot instead of decoding fresh ones (the slow BIM read). Each
-- column/row step is drawn at full layout fidelity with soft/placeholder
-- covers; _scheduleCoverSettle upgrades them once adjustments stop. pcall so
-- the module flag is always lowered even if _rebuild throws.
function BookshelfWidget:_draftRebuild()
    SpineWidget.setDraftMode(true)
    self._draft_regrid = true
    local ok, err = pcall(self._rebuild, self)
    self._draft_regrid = false
    SpineWidget.setDraftMode(false)
    if not ok then error(err) end
end

-- Debounced full-quality cover upgrade after draft regrid steps. Each call
-- pushes the timer out; when adjustments stop for COVER_SETTLE_DELAY the shelf
-- rebuilds normally, decoding correct-size covers.
function BookshelfWidget:_scheduleCoverSettle()
    if self._cover_settle_cb then UIManager:unschedule(self._cover_settle_cb) end
    self._cover_settle_cb = function()
        self._cover_settle_cb = nil
        self:_rebuild()
        UIManager:setDirty(self, "ui")
    end
    UIManager:scheduleIn(COVER_SETTLE_DELAY, self._cover_settle_cb)
end

-- Run the cover upgrade now, cancelling any pending settle timer. For the
-- dialog's Accept/Cancel where the sharp covers should land immediately.
function BookshelfWidget:_settleCoversNow()
    if self._cover_settle_cb then
        UIManager:unschedule(self._cover_settle_cb)
        self._cover_settle_cb = nil
    end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- Pinch / spread in LIST mode: the row density knob, which is list_font_scale.
--
-- Same gesture, same direction, the mode's own answer to "make these bigger":
-- covers have a column count, a table has a text size, and both move row height
-- with them. Rewriting bookshelf_columns from list mode would silently change
-- the grid the user comes back to, which is why this used to be a swallowed
-- no-op.
--
-- `delta` keeps _nudgeColumns's convention (-1 = spread = zoom in), so the sign
-- flips here: zooming in means MORE scale, where it meant FEWER columns.
--
-- Step of 10 to match the nudge dialog's coarse button. The fine +/-1 is for
-- someone dialling in a value they can see; a pinch is a gesture, and a step
-- too small to notice reads as the gesture not working.
local LIST_SCALE_STEP = 10
local LIST_SCALE_MIN  = 50
local LIST_SCALE_MAX  = 300

-- PINCH CHANGES THE ROW COUNT, and nothing else.
--
-- It used to snap the FONT SCALE to whatever produced one more or one fewer
-- row, because the row height was derived from the type size and there was no
-- other way to ask. That is what made the two inseparable:
--
--     "increasing or decreasing the rows can make the font too small or too
--      large, these controls should be separate ... Pinch/zoom would change
--      the number of rows but not the font size."
--
-- Now the count is a setting in its own right, so the gesture just moves it.
-- The searching, the counterfactual scale pin and the settle pass that
-- followed a layout change are all gone with it -- there is nothing left to
-- solve.
--
-- Written as the CHIP's override, not the library default: a pinch is aimed at
-- the shelf in front of you. It therefore beats a pinned preset too, which is
-- the only precedence that keeps the gesture alive on a chip that has one.
function BookshelfWidget:_nudgeListRows(delta)
    local ListGeom = require("lib/bookshelf_list_geom")
    local b   = self:_listBand(false, self._chip_bar_hidden)
    local gap = self:_listRowGap()
    local max_rows = ListGeom.rowsThatFit(b.band - 2 * b.min_edge_pad,
                                          self:_listMinRowHeight(), gap)
    -- Where the count stands today: the reader's if they have one, otherwise
    -- what the configured lines naturally give, so the first pinch steps from
    -- what is on screen rather than from a number nobody chose.
    local cur = self:_listRows(max_rows)
    if not cur then
        cur = ListGeom.rowsThatFit(b.band - 2 * b.min_edge_pad,
                                   self:_listNaturalRowHeight(), gap)
    end
    -- delta > 0 is the pinch: denser, so MORE rows -- the same sign convention
    -- the column nudge uses.
    local new = math.max(1, math.min(max_rows, cur + delta))
    -- A no-op at the limit still CONSUMES the gesture: falling through would
    -- hand the pinch to whatever is underneath, which at the edge of the range
    -- is the last thing the reader expects.
    if new == cur then return true end
    self:_setChipListRows(new)
    self._nav_dirty = true
    self:_scheduleNavFlush()
    self:_clearDpadFocus()
    -- Thumbnails are sized off the row height, so a row step resizes every
    -- cover on the page: draft regrid rescales from cache and the settle timer
    -- sharpens them once the pinching stops, exactly as the grid does.
    self:_draftRebuild()
    UIManager:setDirty(self, "ui")
    self:_scheduleCoverSettle()
    return true
end

function BookshelfWidget:_nudgeColumns(delta)
    -- One item per row: there is no column count to adjust, so the gesture
    -- means the other density knob instead.
    if self:_isListMode() then return self:_nudgeListRows(delta) end
    -- The GLOBAL, matching _gridCols: cover columns shape the whole screen
    -- (hero size, chip bar position), so they cannot be per chip and the
    -- pinch moves the one shared count.
    local cur = BookshelfSettings.read("bookshelf_columns")
    if type(cur) ~= "number" then cur = self:_nCols() end
    cur = math.max(COLUMNS_MIN, math.min(COLUMNS_MAX, math.floor(cur)))
    local new = math.max(COLUMNS_MIN, math.min(COLUMNS_MAX, cur + delta))
    if new == cur then return true end
    -- DEFERRED write, not save(): a synchronous full bookshelf.lua flush here
    -- (~hundreds of ms on Kindle flash) blocked the pinch before the regrid
    -- repainted, so each zoom step felt laggy. saveDeferred still updates the
    -- in-memory value, so the _rebuild below reads the new count; durability
    -- rides the shared nav-flush debounce and every close / suspend boundary.
    BookshelfSettings.saveDeferred("bookshelf_columns", new)
    self._nav_dirty = true
    self:_scheduleNavFlush()
    self:_clearDpadFocus()
    -- Draft regrid so a burst of pinches steps instantly (covers rescaled from
    -- cache, not re-decoded); the settle timer sharpens them once you stop.
    self:_draftRebuild()
    UIManager:setDirty(self, "ui")
    self:_scheduleCoverSettle()
    return true
end

-- onShelfDiagonalSwipe — run whatever the user has bound to KOReader's short
-- diagonal swipe, or its default (a full screen refresh) if nothing is.
--
-- Forwards to the FileManager's OWN registered zone rather than hardcoding the
-- refresh, so a reader who rebound the gesture gets what they bound. Reaching
-- for the single zone by id, not by replaying the Gesture event at the
-- FileManager: that would offer the swipe to every zone it has, and its own
-- swipe handlers would happily act on a shelf the user is looking at.
--
-- The zone's handler does its own direction and distance filtering, so a
-- gesture that reaches here and does not qualify simply does nothing -- which
-- is why the fallback is gated on the zone being absent rather than on the
-- handler's return value.
function BookshelfWidget:onShelfDiagonalSwipe(_, ges)
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local host = ok_fm and FileManager and FileManager.instance
    local zone = host and host._zones and host._zones["short_diagonal_swipe"]
    if zone and zone.handler then
        local ok = pcall(zone.handler, ges)
        if ok then return true end
        logger.dbg("[bookshelf] short_diagonal_swipe handler errored")
    end
    -- Unbound, or no FileManager to ask: KOReader's default binding, which is
    -- DeviceListener:onFullRefresh's one meaningful line for a docless view.
    UIManager:setDirty(nil, "full")
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
-- _setExpanded(expanded) - collapse the hero to a strip, or restore it.
--
-- Arms the OPDS nav flag, because changing this changes the VIEW SIZE: the
-- shelf grows by a row, the slice the repo is asked for grows with it, and on
-- a catalog that slice can now run past the cached window. The repo flags that
-- (opds_needs_fetch), but _opdsAfterPage only acts on the flag when the user
-- asked for the change -- so without arming it here, expanding a catalog shelf
-- revealed a row of empty slots and nothing ever fetched the books to fill
-- them. A swipe that says "show me more books" is exactly the user-initiated
-- navigation that gate is meant to admit.
--
-- Costs nothing off a catalog: the flag is one-shot and every non-OPDS render
-- path ignores it.
function BookshelfWidget:_setExpanded(expanded)
    expanded = expanded and true or false
    local changed = (self._expanded ~= expanded)
    self._expanded = expanded
    if changed then self:_markOpdsNav() end
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
    -- An OPDS feed has no walk cache to wipe -- its content is remote, not the
    -- filesystem. Swipe-down there means "throw the cached window away and pull
    -- the feed from the top again", which is _opdsRefresh's job. Whose feed is
    -- _opdsEffectiveTab's call: inside a drilled navigation entry it is the
    -- SUBCATALOG that gets re-pulled, not the chip's root feed, because the
    -- subcatalog is what the user is looking at. Any other drilldown tip
    -- (search results, a folder) is a library view and takes the normal
    -- walk-cache path below.
    local _opds_tab = self:_opdsEffectiveTab()
    if _opds_tab then
        self:_opdsRefresh(_opds_tab)
        return
    end
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

-- ─── OPDS chip data flow ─────────────────────────────────────────────────────
--
-- The repository's OPDS branch (bookshelf_book_repository, kind == "opds") is
-- deliberately cache-only: it slices whatever the persisted window already
-- holds and flags the returned page with opds_needs_fetch when the requested
-- slice ran past it. The network half lives HERE, in the widget, because it
-- must stay user-initiated -- a tap on a chip whose window is empty, a page
-- turn past the end of the window, or a swipe-down refresh. Nothing below
-- reaches the network on a timer or on a passive repaint.

-- _isRemoteRecord(book_or_path) -> bool
-- Is this an OPDS catalog entry rather than a real file? The is_remote /
-- opds fields do NOT survive a Repo.buildBook round trip -- buildBookMeta
-- rebuilds a record from BIM / Calibre / the filename and knows nothing
-- about feeds, so a hero re-hydration hands back a stripped stand-in that
-- still carries the OPDS:// pseudo-path. The prefix is therefore the
-- authoritative test and every guard uses it; the flags are only a
-- secondary check for records that never touched the repo.
-- Accepts a record or a bare filepath (the BIM extraction queue only has
-- the path).
function BookshelfWidget:_isRemoteRecord(book)
    if not book then return false end
    local is_path = type(book) == "string"
    local fp = is_path and book or book.filepath
    if type(fp) == "string" and fp:find("^OPDS://") then return true end
    if not is_path and book.is_remote and book.opds then return true end
    return false
end

-- _hydrateBook(book) -> book
-- Repo.buildBook upgrades a shelf record to a full Book (a DocSettings read
-- for progress / page position). There is no file behind a remote record and
-- the upgrade would strip it (see _isRemoteRecord), so pass those through
-- untouched -- the feed record already holds everything the hero can show.
function BookshelfWidget:_hydrateBook(book)
    if not book or not book.filepath then return book end
    if self:_isRemoteRecord(book) then return book end
    return Repo.buildBook(book.filepath) or book
end

-- _markOpdsNav() - arm the one-shot "the user caused the rebuild that is
-- about to happen" flag. EVERY OPDS network call is gated on it: the shelf
-- rebuilds for plenty of reasons the user did not ask for (startup restore
-- with a persisted chip + cursor, the 5s sideload file-poll, a cover
-- landing, a settings change), and none of those may reach the network.
-- Armed by the navigation gestures only -- chip select, page turn, page
-- jump, swipe-down refresh -- and consumed by the next _opdsAfterPage.
function BookshelfWidget:_markOpdsNav()
    self._opds_nav_pending = true
end

-- _opdsEffectiveTab() -> tab-like | nil
-- WHICH OPDS feed is the shelf actually showing right now? Every network
-- helper below needs the same answer, and it is not simply "the active tab":
-- drilling into a navigation entry puts a different feed on screen while the
-- chip underneath is unchanged. Resolved in the precedence _fetchChipItems
-- itself uses -- drill tip first, chip second:
--
--   * tip.kind == "opds_nav" -> a synthesised stand-in for the subcatalog the
--     user drilled into. It carries exactly the three fields the helpers read
--     off a tab (source.id, source.feed_url, label), so _opdsFetchMore /
--     _opdsRefresh work against a drilled feed with no change of their own.
--   * any OTHER tip kind (search, folder, a group) -> nil. That view is a
--     library view reachable from any chip; the feed is not what is rendered,
--     so no OPDS work applies. Same answer the old inline drill guards gave.
--   * no tip at all -> the real tab, when its source is an OPDS one.
--
-- Factored into one function deliberately: three hand-rolled copies of this
-- precedence is how the "the drilled page doesn't fetch / refresh / show
-- covers" rounds happen.
function BookshelfWidget:_opdsEffectiveTab()
    local path = self._drilldown_path or {}
    local tip  = path[#path]
    if tip then
        if tip.kind ~= "opds_nav" then return nil end
        local pay = tip.payload or {}
        if not (pay.server_key and pay.feed_url) then return nil end
        return {
            label  = tip.label,
            source = { kind = "opds", id = pay.server_key,
                       feed_url = pay.feed_url },
        }
    end
    local TabModel = require("lib/bookshelf_tab_model")
    local tab = TabModel.getById(self.chip)
    if tab and tab.source and tab.source.kind == "opds" then return tab end
    return nil
end

-- _opdsBatchSize() -> how many entries one fetch should pull: one screenful.
--
-- Exactly the page being rendered, so the first paint comes as fast as the
-- layout allows. It used to be max(view, a per-chip number), which was the
-- wrong shape in both directions - a small number made every page turn wait
-- on a round trip, a large one made the FIRST page wait on all of them - and
-- was chosen against a page size that changes underneath it when the shelf
-- expands.
--
-- A background lookahead was built here and REVERTED, because there is no
-- quiet way to fetch a feed yet. _opdsFetchMore is the user-facing fetch: it
-- runs inside Trapper and shows a modal "Fetching..." that yields for input,
-- and its tail re-clamps self._cursor and rebuilds. Driving it from a
-- background prefetch therefore blocked input on a page the user had already
-- been given, showed the message a second time on the next swipe, and moved
-- the cursor under a swipe in flight - the page slipping one further than
-- asked for.
--
-- Doing it properly needs a silent fetch path: no Trapper, no progress line,
-- no cursor arithmetic, and an abandon-on-navigation token like the cover
-- chain's. That is a real piece of work on a function whose every branch is
-- load-bearing, not a flag.
function BookshelfWidget:_opdsBatchSize()
    return self:_viewSize() or 24
end

-- _opdsFeedRef(tab) -> server_key, feed_url  (nil when the tab is not a
-- resolvable catalog). One resolution shared by every caller that needs to
-- reach a chip's cached window; two copies of this drift the moment one of
-- them learns about a new source shape.
function BookshelfWidget:_opdsFeedRef(tab)
    if not (tab and tab.source and tab.source.id) then return nil end
    local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
    if not ok_s then return nil end
    local server = OpdsSource.getServer(tab.source.id)
    local feed_url = tab.source.feed_url or (server and server.url)
    if not feed_url then return nil end
    return tab.source.id, feed_url
end

-- want_count sentinel: "walk this feed until it actually ends".
--
-- Every other want is derived from a cursor and is therefore a guess at how
-- much the reader is about to need, which is why they are all capped. This one
-- is a question the reader asked outright by tapping "last page" on a feed of
-- unknown length, and a cap would answer it with a number that is not the
-- answer. math.huge rather than a magic integer so the walk's own
-- `count < want_count` test needs no special case.
local FETCH_ALL = math.huge

-- _opdsPrefsTab() -> the real CHIP behind the current view, or nil.
--
-- Not the same question as _opdsEffectiveTab, and the two must not be
-- confused. That one answers "which feed is on screen", and when the user has
-- drilled into a subcatalog it answers with a synthesised stand-in carrying
-- only label + source -- a table that has never been persisted and so holds
-- none of the chip's settings. This one answers "whose settings govern that
-- view", which is always the chip the drill started from: the catalog is what
-- was configured, and drilling into one of its subcatalogs does not leave it.
--
-- Returns nil for a non-OPDS chip, so every caller can hand the result
-- straight to bookshelf_opds_prefs (whose readers all treat nil as "defaults").
function BookshelfWidget:_opdsPrefsTab()
    local TabModel = require("lib/bookshelf_tab_model")
    local tab = TabModel.getById(self.chip)
    if tab and tab.source and tab.source.kind == "opds" then return tab end
    return nil
end

-- Fetch feed pages for an OPDS tab until the window covers want_count
-- entries (or the feed runs out), then rebuild. User-initiated only: chip
-- tap on an empty window, page-turn past the window, swipe-down refresh.
-- Trapper gives a cancellable progress line; runWhenOnline gates Wi-Fi
-- with a prompt, never silently.
--
-- replace = true (swipe-down refresh) fetches into a FRESH window instead of
-- extending the cached one, and only overwrites the persisted window once
-- the feed has actually given us entries. Resetting up front would empty the
-- chip the moment the user declined the Wi-Fi prompt -- runWhenOnline's
-- callback simply never fires -- leaving them worse off than before they
-- asked. No user action may leave the chip emptier than it started unless
-- the feed itself genuinely got smaller.
--
-- `tab` is a tab-LIKE, not necessarily a real one: only source.id,
-- source.feed_url and label are read off it. Inside a drilled navigation entry
-- the caller passes the stand-in _opdsEffectiveTab synthesises for the
-- subcatalog, and every line below works against it unchanged -- which is the
-- whole reason the drill needed no fetch machinery of its own.
-- on_done (optional): a ONE-SHOT continuation run at the very end of the tail,
-- after the rebuild and the cover pass, for a caller that has a decision to
-- make once the feed has actually landed (today: _expandOpdsNav deciding
-- between a book modal and a drill for a subcatalog nothing had fetched yet).
-- It never fires when the fetch never ran -- an unknown server, or a Wi-Fi
-- prompt the user declined, in which case runWhenOnline simply never calls
-- back -- which is the correct "stay put" in both cases. Nothing about the
-- marker discipline changes: the markers are already released above, and this
-- runs inside the same single synchronous run of the coroutine.
function BookshelfWidget:_opdsFetchMore(tab, want_count, replace, on_done)
    local OpdsSource = require("lib/bookshelf_opds_source")
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local CoverFetch = require("lib/bookshelf_cover_fetch")
    local Notification = require("ui/widget/notification")
    local Trapper    = require("ui/trapper")
    local server = OpdsSource.getServer(tab.source.id)
    if not server then return end
    local feed_url = tab.source.feed_url or server.url
    -- Bound the WALK, not the storage. "Go to last page" on a category
    -- advertising 10000 results computes a want of 10000 and the loop below
    -- would ask the server for page after page until its chain ran out -
    -- hundreds of round trips with a modal progress line up throughout. That
    -- happened on device.
    --
    -- Clamped here rather than at each caller because every caller derives
    -- want from a cursor, and a cursor can always be sent further than any one
    -- fetch should chase.
    --
    -- FETCH_ALL is the one exception, and it is exempt on purpose. It is not a
    -- cursor overshoot - it is the reader tapping "last page" on a feed of
    -- unknown length, which is a direct question ("where does this end?") that
    -- a cap can only answer wrongly. It is safe to leave unbounded precisely
    -- because it is explicit: the progress line counts up, a tap stops it
    -- within about a tenth of a second, and everything already fetched is
    -- kept, so the worst case of a long walk is that the reader ends it early.
    if want_count ~= FETCH_ALL then
        local _OW = require("lib/bookshelf_opds_window")
        want_count = math.min(want_count or 0, _OW.MAX_FETCH_ENTRIES)
    end
    -- Per-catalog socket budget, resolved once for the whole walk rather than
    -- per page: every page of one fetch belongs to the same catalog, and the
    -- chip cannot change under a running coroutine. Read off the CHIP, not the
    -- effective tab - a drilled subcatalog's stand-in carries no settings.
    local feed_timeouts = require("lib/bookshelf_opds_prefs")
        .timeouts(self:_opdsPrefsTab())
    -- Is `t` (an _opdsEffectiveTab result) the same feed this fetch is for?
    -- Compared on the RESOLVED url, not the raw field: a chip's own tab leaves
    -- source.feed_url nil and means "the server's root url", which is exactly
    -- what feed_url resolved to above, so a raw comparison would call the root
    -- feed a different feed from itself. Server id checked first, so falling
    -- back to the captured server's url is the right substitution.
    local function sameFeed(t)
        if not (t and t.source and t.source.id == tab.source.id) then return false end
        return (t.source.feed_url or server.url) == feed_url
    end
    CoverFetch.runWhenOnline(function()
        -- Liveness, same test the _opdsAfterPage / _opdsEnsureCovers deferrals
        -- make: the Wi-Fi prompt is modal and the user can answer it long after
        -- the shelf closed (or after a re-open replaced this widget). Every
        -- line below fetches, moves this widget's cursor and rebuilds it, so
        -- running it against a dead shelf is at best waste and at worst a
        -- Trapper progress line over whatever is on screen now.
        if BookshelfWidget.live ~= self then return end
        Trapper:wrap(function()
            -- Held for the whole fetch so any rebuild landing mid-fetch can't
            -- queue a second FETCH. It does NOT block the user: an explicit
            -- swipe-down refresh during a feed fetch is deliberately exempt
            -- (see _opdsRefresh, which reads only the download marker), and a
            -- navigation that lands here is queued rather than refused. A
            -- timestamp rather than a boolean:
            -- Trapper:info yields, so this body can't be pcall-wrapped (LuaJIT
            -- can't yield across a C-call boundary) and an error inside the
            -- coroutine would otherwise wedge the flag on for the rest of the
            -- session. It expires instead.
            --
            -- ...and WHICH feed the fetch is for, as the sameFeed predicate
            -- itself. _opdsAfterPage needs to tell "the feed on screen is
            -- already being fetched" (refuse, nothing to do) from "some OTHER
            -- feed is being fetched" (queue, see there) -- previously it could
            -- not, so a drill landing mid-fetch was refused as busy and left
            -- the user on an empty subcatalog, and an errored fetch blocked
            -- every feed for the full 120s. A predicate rather than the url
            -- string because the comparison is on the RESOLVED url: recomputing
            -- "the chip's root feed" at the far end would mean an
            -- OpdsSource.getServer -- a re-read and re-parse of the stock OPDS
            -- plugin's opds.lua -- on every page render.
            self._opds_fetch_started_at = os.time()
            self._opds_fetch_feed = sameFeed
            local _dbg_want = want_count
            -- Shape matches OpdsWindow.load's miss exactly, field for field:
            -- the two have to stay interchangeable since everything below
            -- treats `win` the same either way.
            -- "Replace" means the cached window may be WRONG rather than
            -- merely short, so it is emptied before the walk refills it.
            --
            -- It must still be a REAL handle. A window carries its own
            -- identity now (server_key + feed_url) and everything that writes
            -- reaches storage through it; the bare table this used to build
            -- had neither, so every append bound a nil key, SQLite rejected
            -- the row, and the walk fetched page after page into nothing. The
            -- shelf showed a progress message and then no change at all.
            -- REPLACE DOES NOT DESTROY THE CACHE UP FRONT.
            --
            -- It used to: reset, then walk. So a refresh that could not reach
            -- the server - offline, catalog down, a transient error - threw
            -- away a perfectly good cached feed and left the reader looking at
            -- "No books yet" over a shelf that had been full a second earlier.
            -- Refreshing is not a request to be shown nothing, and a cached
            -- feed is the only thing an OPDS chip HAS when offline.
            --
            -- Held until the first page actually lands instead (see
            -- pending_replace below), so the old window survives every way a
            -- refresh can fail.
            local pending_replace = replace or false
            local win = OpdsWindow.load(tab.source.id, feed_url)
            -- Follow the chain when we have it. When we do not AND the feed
            -- has never been seen to end, the chain is LOST rather than
            -- finished - start again from the top and re-walk. Dedupe is a
            -- unique index now, so re-treading known pages costs requests and
            -- adds nothing twice; the alternative is a category frozen at
            -- whatever it happens to hold, which is what a bug left behind on
            -- Internet Archive.
            --
            -- A replace always starts at the top, decided here rather than
            -- inferred from a window we have deliberately not cleared yet.
            local url
            if pending_replace then
                url = feed_url
            else
                url = OpdsWindow.fetchUrl(win, feed_url)
            end
            -- Consecutive unusable pages seen (parsed fine, zero usable
            -- records). Reset by any page that yields records; when it hits
            -- OpdsWindow.UNUSABLE_PAGE_LIMIT the category is judged unusable
            -- and the walk stops terminally.
            local unusable_streak = 0
            -- Did the walk end TERMINALLY (chain finished, or category judged
            -- unusable) rather than by error, cancel or want_count? Terminal
            -- ends mark the window complete, which clamps the promised page
            -- count to what is cached (OpdsWindow.slice).
            local terminal = false
            -- Every url fetched by THIS walk. A feed whose rel=next loops back
            -- on itself (Internet Archive's faceted feeds have returned a next
            -- pointing at the very page it came from) can never make progress:
            -- the refetched page dedupes to nothing, the window stops growing,
            -- and without this guard the walk refetched the same page once a
            -- second forever. Any url seen twice ends the chain terminally --
            -- everything reachable was already fetched the first time round.
            local seen_urls = {}
            -- What this walk can count as already held.
            --
            -- Not simply win.count while a replace is pending: those entries
            -- are about to be thrown away, so counting them against the target
            -- says the work is already done. That is exactly what happened -
            -- deferring the reset (below) left a category holding 25 entries
            -- measured against a batch of 24, the loop never ran, and
            -- swipe-down refresh silently did nothing at all. Zero until the
            -- old window is actually gone, then the real count.
            local function heldCount()
                return pending_replace and 0 or (win.count or 0)
            end
            -- Discard the tap that STARTED this fetch.
            --
            -- The progress message traps input so it can be dismissed, and it
            -- goes up within milliseconds of the tap that asked for the fetch -
            -- so on e-ink, where the release event arrives well after the
            -- widget exists, that same tap dismissed it. The walk was cancelled
            -- before its first page landed ("stopped by the reader at 0
            -- entries", twice in one session, neither of them the reader), the
            -- shelf rebuilt an empty window as "No books yet", and the next
            -- top-up quietly refilled it a second later. Drills got it worst:
            -- the tap on a category cancelled the very fetch it had just
            -- requested.
            --
            -- This is the same guard the stock widgets use as
            -- flush_events_on_show, and the same reason: 400ms for the refresh
            -- to actually land plus 400ms for a human to react to it.
            -- dismissableRunInSubprocess does not do it for a trap widget we
            -- pass in, so it is ours to do.
            if Device.input and Device.input.inhibitInputUntil then
                Device.input:inhibitInputUntil(true)
            end
            while url and heldCount() < want_count do
                if seen_urls[url] then
                    logger.dbg("[bookshelf perf] opds next-chain loop detected at", url)
                    win.next_url = nil
                    terminal = true
                    break
                end
                seen_urls[url] = true
                -- Report progress THROUGH the walk, not just that a walk is
                -- happening. One fetch can be many feed pages -- a catalog
                -- serving 25 records a page needs eleven of them to satisfy a
                -- batch of 200 -- and a line that reads "Fetching X…" on every
                -- one of them is indistinguishable from eleven separate
                -- fetches, which is exactly how it was read on device. The
                -- count is what makes one long operation legible as one.
                -- The second line is the point of making cancel responsive: an
                -- operation the reader is allowed to stop should say so. It
                -- matters most on exactly the walk that takes longest - "last
                -- page" on a feed of unknown length, which is unbounded and
                -- can run for a while before the chain gives out.
                --
                -- One function because it is needed twice: at the top of every
                -- page, and again after a "keep loading", where Trapper:confirm
                -- has replaced the progress message with its ConfirmBox and
                -- closed it. Retrying without putting it back would leave the
                -- reader watching a frozen shelf with nothing to tap.
                local function showProgress()
                    if heldCount() > 0 then
                        return self:_showFetchProgress(
                            T(_("Fetching %1… (%2 books)\n(Tap to cancel)"),
                              tab.label or server.title, heldCount()))
                    end
                    return self:_showFetchProgress(
                        T(_("Fetching %1…\n(Tap to cancel)"),
                          tab.label or server.title))
                end
                if not showProgress() then break end
                -- Gated per request, not just the entry feed_url: a
                -- rel=next link came from the server's XML and could in
                -- principle hop to a foreign host, and credentials must
                -- only ever travel to the catalog's own origin.
                local same_origin = OpdsFeed.sameOrigin(server.url, url)
                -- OFF THE MAIN LOOP, so that "tap to stop" is true.
                --
                -- Fetching in-process blocks UIManager for the whole request -
                -- three to four seconds a page against Internet Archive - and
                -- Trapper only samples input during the 0.1s window inside
                -- info(). So a tap almost always landed while the main loop was
                -- blocked and was never seen: the reported "tapping to cancel
                -- does nothing until you frantically tap everywhere", which is
                -- exactly what having one narrow window per multi-second page
                -- feels like.
                --
                -- dismissableRunInSubprocess forks the request and hands
                -- control back to UIManager every 125ms (backing off to 1s),
                -- so a tap is acted on within about that, and the shelf stays
                -- painted underneath rather than frozen.
                --
                -- A dismissal here cancels outright, with no "are you sure".
                -- Trapper's own info() path raises a Paused/Continue/Abort box
                -- because a stray tap could throw away a long job; nothing is
                -- thrown away here, since every page is written to the database
                -- as it lands and the tail below keeps the window and lands the
                -- reader on the last page that has books. Cheap to undo, so it
                -- does not deserve a confirmation.
                local fetch_user = same_origin and server.username or nil
                local fetch_pass = same_origin and server.password or nil
                local fetch_url  = url
                local body, err
                local cancelled = false
                repeat
                    local retry = false
                    if Trapper.dismissableRunInSubprocess then
                        -- The task's own returns come back SPREAD, not packed:
                        -- the helper ends with `return completed,
                        -- unpack(ret_values, ...)`. Reading it as a table
                        -- indexed a string, so both values came back nil and
                        -- every fetch reported a failure with no error - a
                        -- pair no path in OpdsFeed.fetch can return.
                        local completed, b, e = Trapper:dismissableRunInSubprocess(
                            function()
                                return OpdsFeed.fetch(fetch_url, fetch_user,
                                                      fetch_pass, feed_timeouts)
                            end,
                            -- Trap on the progress message already on screen,
                            -- so the reader taps the thing they can see. Nil
                            -- falls back to an invisible trap widget, which
                            -- still catches the tap.
                            Trapper.current_widget)
                        if completed then
                            body, err = b, e
                        else
                            -- ASK before throwing the walk away. Trapper's own
                            -- info() path does this and it was right to; what
                            -- was wrong was that a blocked main loop made the
                            -- tap itself unreliable, so the prompt was
                            -- unreachable rather than unwanted. Sampling every
                            -- 125ms fixes the reaching; a tap on a shelf is
                            -- cheap enough to be accidental, so it still has to
                            -- be meant. ConfirmBox flushes pending events on
                            -- show, so the dismissing tap cannot answer it.
                            cancelled = Trapper:confirm(
                                heldCount() > 0
                                    and T(_("Stop loading %1?\n%2 books so far."),
                                          tab.label or server.title, heldCount())
                                    or  T(_("Stop loading %1?"),
                                          tab.label or server.title),
                                _("Keep loading"), _("Stop"))
                            -- Kept going: the request was killed with the
                            -- dismissal, so this page has to be asked for
                            -- again. Costs one round trip and nothing else -
                            -- re-treading a page dedupes to nothing. It cannot
                            -- go round the outer loop instead: seen_urls has
                            -- already recorded this url, and re-entering would
                            -- read as a self-referential rel=next chain and end
                            -- the walk.
                            retry = not cancelled
                            if retry and not showProgress() then
                                cancelled = true
                                retry = false
                            end
                        end
                    else
                        -- Ancient KOReader without the helper: fetch in-process.
                        -- Correct, just unresponsive to a cancel mid-request.
                        body, err = OpdsFeed.fetch(fetch_url, fetch_user,
                                                   fetch_pass, feed_timeouts)
                    end
                until not retry
                if cancelled then
                    logger.dbg("[bookshelf perf] opds walk: stopped by the reader at",
                               (win.count or 0), "entries")
                    break
                end
                if not body then
                    Trapper:clear()
                    -- The toast says "Couldn't reach <server>" for everything
                    -- that isn't an auth rejection, which is the right thing to
                    -- tell a reader and useless in a bug report: a gateway
                    -- timeout from a catalog that is plainly up reads exactly
                    -- like a DNS failure. OpdsFeed.fetch already hands back the
                    -- HTTP status line as `err` (or "network unreachable" /
                    -- "empty response"), so log the pair rather than widening
                    -- the notification. dbg, not warn: an unreachable server is
                    -- a normal thing to hit offline, and the log is for the
                    -- session where someone is looking.
                    logger.dbg("[bookshelf] opds fetch failed:", url, err)
                    -- Remembered for the EMPTY STATE. A toast is gone in three
                    -- seconds and the shelf underneath it then says "No books
                    -- in Internet Archive yet", which is a sentence about the
                    -- reader's own library and wrong in every particular: the
                    -- books are on someone else's server, there is no "yet",
                    -- and nothing was counted because nothing was fetched.
                    -- Keyed by url so a failure on one feed cannot explain
                    -- another feed's emptiness.
                    self._opds_fail_url = url
                    self._opds_fail_err = err
                    UIManager:show(Notification:new{
                        text = err == "auth"
                            and T(_("Authentication failed for %1"), server.title)
                            or err == "format"
                            and T(_("%1 refused every format Bookshelf asked for"), server.title)
                            or T(_("Couldn't reach %1"), server.title),
                    })
                    break
                end
                -- The server answered, so whatever it last refused is history.
                if self._opds_fail_url == url then
                    self._opds_fail_url, self._opds_fail_err = nil, nil
                end
                local catalog = OpdsFeed.parse(body)
                local mapped = catalog and OpdsFeed.mapEntries(catalog, url, tab.source.id)
                -- Did the page carry any raw items at all? Separates a genuinely
                -- empty feed from one that HAS items this device just can't use.
                local raw_count = catalog and (
                    (catalog.publications and #catalog.publications or 0)
                    + (catalog.navigation and #catalog.navigation or 0)
                    + (catalog.entry and #catalog.entry or 0)) or 0
                logger.dbg("[bookshelf perf] opds page", url,
                    "records", mapped and #mapped.records or -1,
                    "raw", raw_count,
                    "next", tostring((mapped and mapped.next_url) ~= nil))
                if not mapped then
                    -- Parse failure (transient): an HTML error page from a
                    -- throttling server (IA does this mid-chain) is the common
                    -- cause. Leave next_url ALONE so the chain stays
                    -- retryable - a later page turn resumes from the last
                    -- good checkpoint and reaches this page again. Nilling it
                    -- here and then saving the window (which the tail below
                    -- does) permanently amputated every page behind the
                    -- failure: the reported "nothing loads after page 10 of
                    -- 15".
                    if (win.count or 0) == 0 then
                        Trapper:clear()
                        UIManager:show(Notification:new{
                            text = T(_("No books found in %1"), server.title),
                        })
                    end
                    break
                end
                if #mapped.records == 0 then
                    -- Parsed fine, but nothing on this page is usable. Do not
                    -- give up on the first one: a single mid-chain page of
                    -- unsupported entries (borrow-only, formats we can't
                    -- read) says nothing about the pages behind it, and
                    -- stopping here used to amputate them permanently. Skip
                    -- forward instead - up to UNUSABLE_PAGE_LIMIT consecutive
                    -- unusable pages, after which the category is judged
                    -- genuinely unusable (IA's all-borrow loan categories
                    -- advertise ~10000 items and every page maps to zero;
                    -- three in a row is enough to know the rest match).
                    unusable_streak = unusable_streak + 1
                    if mapped.next_url
                            and unusable_streak < OpdsWindow.UNUSABLE_PAGE_LIMIT then
                        url = mapped.next_url
                        -- No appendPage (nothing usable to add); loop again.
                    else
                        win.fetched_at = os.time()
                        win.next_url = nil
                        terminal = true
                        if (win.count or 0) == 0 then
                            Trapper:clear()
                            UIManager:show(Notification:new{
                                text = raw_count > 0
                                    and _("No downloadable titles in this category.")
                                    or T(_("No books found in %1"), server.title),
                            })
                        end
                        break
                    end
                else
                    -- The replacement has arrived, so now the old one can go.
                    -- Everything up to this line was reachable with the cached
                    -- window still intact, which is the point: a refresh that
                    -- never gets a page leaves the reader exactly where they
                    -- were rather than emptying the shelf.
                    if pending_replace then
                        OpdsWindow.reset(tab.source.id, feed_url)
                        win = OpdsWindow.load(tab.source.id, feed_url)
                        pending_replace = false
                    end
                    unusable_streak = 0
                    win.fetched_at = os.time()
                    OpdsWindow.appendPage(win, mapped)
                    url = win.next_url
                end
            end
            -- The chain ended by running out of next links (url == nil after a
            -- successful append), or a terminal stop above. NOT on error,
            -- cancel, or simply having covered want_count (url still set).
            if url == nil then terminal = true end
            if terminal then win.complete = true end
            Trapper:clear()
            -- A refresh that came back with nothing (server down, feed
            -- unreachable, user cancelled at the first page) keeps the
            -- window it already had.
            if not replace or (win.count or 0) > 0 then
                logger.dbg(string.format(
                    "[bookshelf perf] opds walk END: entries=%d next=%s terminal=%s "
                    .. "complete=%s want=%s", win.count or 0, tostring(win.next_url ~= nil),
                    tostring(terminal), tostring(win.complete), tostring(_dbg_want)))
                OpdsWindow.save(tab.source.id, feed_url, win)
            end
            -- No Repo.invalidateBookCache here: the OPDS branch of getBySource
            -- reads OpdsWindow (the settings store) on every call and never
            -- touches the walk / group / _bySource caches, so there is nothing
            -- stale to clear. Invalidating would only make the next tap on a
            -- LOCAL chip re-derive the whole library for free.

            -- Paging forward left the cursor one page PAST the window (that
            -- overshoot is what asked for this fetch). If the fetch did not
            -- actually reach it -- server down, auth rejected, user cancelled,
            -- or the feed simply ended -- pull the cursor back onto the last
            -- page with books BEFORE rebuilding. Otherwise the user is stranded
            -- on a blank page in front of a perfectly good cached window, and
            -- _persistNavState saves that cursor for next launch. Skipped when
            -- a refresh declined to save (win is the discarded fresh one, not
            -- what will be rendered).
            -- A DECLINED Wi-Fi prompt never gets here (runWhenOnline simply
            -- never calls back); that case is caught by _maxCursor withholding
            -- the headroom from the next passive clamp instead.
            --
            -- Gated on the shelf STILL showing this feed, re-resolved rather
            -- than assumed. runWhenOnline can sit on a Wi-Fi prompt for many
            -- seconds with the shelf fully interactive underneath it, so the
            -- user can back out of the drill (or drill somewhere else) before
            -- this tail runs. The fetch and the save above are keyed off the
            -- CAPTURED feed and stay correct either way -- but the cursor
            -- belongs to whatever is on screen NOW, and measuring it against
            -- THIS window's entry count would yank the user to page 1 of a view
            -- that was never short. The overshoot this pull-back exists to
            -- repair went away with the navigation that abandoned it.
            local still_here  = sameFeed(self:_opdsEffectiveTab())
            local entry_count = win.count or 0
            if still_here and (not replace or entry_count > 0)
                    and self._cursor > entry_count then
                local view = self:_viewSize()
                local pages = math.max(1, math.ceil(entry_count / view))
                self._cursor = (pages - 1) * view + 1
                self:_syncPageFromCursor()
            end
            -- Released BEFORE the rebuild, not after. A navigation that landed
            -- while this fetch held the marker left the nav arm SET rather
            -- than spending it (see _opdsAfterPage), specifically so this
            -- rebuild can start the fetch it was refused; with the marker
            -- still held it would be refused again and the user would sit on
            -- an empty subcatalog until they touched something. Nothing can
            -- interleave between these lines and the rebuild -- one
            -- synchronous run of the coroutine -- so the "no second fetch
            -- mid-fetch" guarantee the marker exists for is unaffected: a
            -- rebuild with no arm set returns at the top of _opdsAfterPage.
            self._opds_fetch_started_at = nil
            self._opds_fetch_feed = nil
            self:_rebuild()
            UIManager:setDirty(self, "ui")
            -- The cover pass for this page. This rebuild is passive in the
            -- ordinary case (nothing re-armed the nav flag), so it renders
            -- from cache and runs no cover pass of its own -- this is the
            -- single pass, and its token stays current through to the repaint.
            -- In the queued case above it has just scheduled the next fetch
            -- instead, and that fetch runs its own pass against the fuller
            -- page; this one still fills whatever is on screen right now, and
            -- a superseded batch only loses its repaint, never its downloads.
            self:_opdsEnsureCovers()
            -- Last, so the continuation decides against the window this fetch
            -- just saved and a view it has already rebuilt. Gated on liveness
            -- only. NOT on still_here: the whole point of this continuation is
            -- to act on the feed THIS fetch just loaded, which is a DIFFERENT
            -- feed from the one on screen when the tap fired (tapping an
            -- uncached category fetches the child feed while the parent is
            -- still shown, then drills in). still_here compares the on-screen
            -- feed to the fetched one, so it is always false here and
            -- suppressed the drill entirely -- the reported "have to tap the
            -- category twice" (first tap fetched, second drilled). The narrow
            -- case it guarded (user navigates away during a Wi-Fi prompt, then
            -- gets drilled) is rare and Back-recoverable; correctness of the
            -- common one-tap drill wins.
            if on_done and BookshelfWidget.live == self then
                on_done()
            end
        end)
    end)
end

-- _opdsWalkToEnd() - "last page" on a feed whose length nobody knows.
--
-- The footer can only offer a jump when there is a known last page to jump to.
-- On an OPDS feed there usually is not: totalResults is absent or a lie (see
-- OpdsWindow.slice), so the page count is a lower bound and the chevron used
-- to be disabled. Walking the chain is the only way to answer the question, so
-- that is what this does - unbounded, because a cap cannot answer "where does
-- it end", and stoppable, because an unbounded walk that could not be stopped
-- would be a trap.
--
-- Landing is the same for all three outcomes - reached the end, hit an error,
-- reader stopped it - because all three mean the same thing to someone looking
-- at a shelf: put me on the last page that has books.
function BookshelfWidget:_opdsWalkToEnd()
    local tab = self:_opdsEffectiveTab()
    if not tab or not tab.source or tab.source.kind ~= "opds" then return end
    local OpdsSource = require("lib/bookshelf_opds_source")
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local server = OpdsSource.getServer(tab.source.id)
    if not server then return end
    local feed_url = tab.source.feed_url or server.url
    self:_opdsFetchMore(tab, FETCH_ALL, false, function()
        -- Counted back out of storage rather than captured before the walk:
        -- what landed is the only thing that decides where the reader goes,
        -- and the walk may have stopped anywhere.
        local n     = OpdsWindow.count(tab.source.id, feed_url)
        local view  = self:_viewSize() or 1
        local pages = math.max(1, math.ceil(n / view))
        self._cursor = (pages - 1) * view + 1
        self:_syncPageFromCursor()
        -- Armed, as every other page change arms it. _opdsAfterPage returns at
        -- its first line without it, so the page this lands on got no cover or
        -- nav-resolve pass at all: on a catalog that models each book as a
        -- one-entry subcatalog (Gutenberg does) the last page stayed a grid of
        -- unresolved folders until the reader paged away and back. There is no
        -- risk of it spending itself on a fetch - the walk it follows has just
        -- filled the window, so the page is usable and the silent branch takes
        -- it straight to the cover pass.
        self:_markOpdsNav()
        self:_swapShelvesInPlace()
    end)
end

-- Swipe-down on an OPDS view: re-fetch the feed from the start, replacing
-- the cached window only if the fetch succeeds (see _opdsFetchMore's
-- replace mode -- the old window survives a declined Wi-Fi prompt or a
-- dead server untouched).
--
-- `tab` is the tab-LIKE _opdsEffectiveTab hands back, so a swipe-down inside a
-- drilled navigation entry re-pulls THAT subcatalog, not the chip's root feed.
-- No liveness guard of its own: this runs synchronously off the gesture and
-- everything deferred past a Wi-Fi prompt happens inside _opdsFetchMore, which
-- carries the guard.
function BookshelfWidget:_opdsRefresh(tab)
    local OpdsSource = require("lib/bookshelf_opds_source")
    local server = OpdsSource.getServer(tab.source.id)
    if not server then return end
    -- The one path that reaches _opdsFetchMore without passing _opdsAfterPage's
    -- busy branch, so it needs its own check against a modal download holding
    -- Trapper. Reachable: the download's Trapper:info yields, and a swipe
    -- queued behind the blocking transfer is delivered in that window (the
    -- progress InfoMessage catches taps, not swipes), landing here while the
    -- download's coroutine is very much alive.
    --
    -- Deliberately narrower than _opdsFetchBusy: a swipe-down during a FEED
    -- fetch stays allowed exactly as it always has been -- that exemption is
    -- the whole point of the explicit refresh -- and _opdsFetchMore's own
    -- marker handling covers it. Narrower in WHICH marker it reads, not in how
    -- it reads it: _opdsDownloadBusy applies the same 120s expiry every other
    -- reader gets, so a wedged marker can't leave refresh permanently dead.
    if self:_opdsDownloadBusy() then
        UIManager:show(require("ui/widget/notification"):new{
            text = _("The catalog is busy. Try again in a moment."),
        })
        return
    end
    -- Deliberately does NOT arm the nav flag: this calls _opdsFetchMore
    -- directly, so the gate has nothing to gate, and leaving it disarmed keeps
    -- the fetch's own tail rebuild passive (one cover pass, no second fetch).
    self:_opdsFetchMore(tab, self:_opdsBatchSize(), true)
end

-- Gap between one background page fetch and the next. Not a throttle on the
-- server -- the fetches are serial anyway -- but the window in which UIManager
-- gets to process input, so a page turn lands promptly instead of queueing
-- behind the rest of the page's work. 0.2s is opds_plus's ImageLoader interval.
local OPDS_COVER_TICK = 0.2
-- Items to let land before repainting. Every repaint is a full _rebuild and,
-- on e-ink, a visible flash; painting per item costs more than it buys.
local OPDS_COVER_REBUILD_EVERY = 4

-- ...EXCEPT THE FIRST ONE. Waiting for a full batch means nothing appears
-- until the second round of fetches lands - measured at roughly 2.5s on device
-- with three workers at ~1.3s a cover - so a new page sat blank and then
-- filled all at once. The first cover is the one that says "this is working",
-- and it earns a repaint on its own; after that the batch cadence takes over
-- and the rest arrive together anyway.
-- Ramped, not a flat batch: 1, then 2, then the full cadence. The first cover
-- says "this is working", the next couple keep saying it while the pipeline
-- warms, and only once several are already on screen does batching take over
-- to stop a full _rebuild (measured 141-887ms) running per cover. A flat
-- cadence made a page arrive in one lump; a flat 1 would spend more of the UI
-- thread repainting than fetching ever did.
local function _opdsPaintThreshold(painted)
    painted = painted or 0
    if painted < 1 then return 1 end
    if painted < 3 then return 2 end
    return OPDS_COVER_REBUILD_EVERY
end

-- _storeChildFeed(server_key, feed_url, body) -> did anything get cached
-- Parse a nav tile's child feed and persist it as that feed's window. That is
-- the whole of "resolving" a folder: the repo's opds branch already flattens a
-- cached single-book child into the book at render time, so populating the
-- cache is all this has to do.
--
-- Returns false for a body that parsed to nothing usable, and stores nothing in
-- that case, so a throttled or error page leaves the tile unresolved and
-- retryable rather than caching an empty window that would read as "fetched,
-- genuinely empty" forever. Restored from 1477764^ unchanged; it was never the
-- part that failed.
local function _storeChildFeed(server_key, feed_url, body)
    if type(body) ~= "string" or body == "" then return false end
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local catalog = OpdsFeed.parse(body)
    local mapped = catalog and OpdsFeed.mapEntries(catalog, feed_url, server_key)
    if not (mapped and (#mapped.records > 0 or mapped.next_url)) then return false end
    local win = OpdsWindow.load(server_key, feed_url)
    win.fetched_at = os.time()
    OpdsWindow.appendPage(win, mapped)
    OpdsWindow.save(server_key, feed_url, win)
    return true
end

-- _storeFeedPage(server_key, store_url, fetched_url, body) -> did records land
-- Append the NEXT page of a feed to that feed's own window.
--
-- Sibling of _storeChildFeed, and separate from it for two reasons. The window
-- is keyed by the feed the user is LOOKING at (store_url) while the body came
-- from its rel=next (fetched_url), and mapEntries has to resolve relative
-- hrefs against the url the body actually came from - passing one for both
-- would either file the page under the wrong key or resolve its links against
-- the wrong base.
--
-- fetched_at is deliberately NOT touched. It records when this feed was last
-- REFRESHED, which is what the five-minute expiry reads; appending page seven
-- does not make page one any newer, and stamping it here would let a deep
-- crawl hold a stale first page fresh forever.
local function _storeFeedPage(server_key, store_url, fetched_url, body)
    if type(body) ~= "string" or body == "" then return false end
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local catalog = OpdsFeed.parse(body)
    local mapped = catalog and OpdsFeed.mapEntries(catalog, fetched_url, server_key)
    if not (mapped and (#mapped.records > 0 or mapped.next_url)) then return false end
    local win = OpdsWindow.load(server_key, store_url)
    local before = win.count or 0
    OpdsWindow.appendPage(win, mapped)
    OpdsWindow.save(server_key, store_url, win)
    return (win.count or 0) > before
end

-- _opdsNavResolveQueue(records, chip) -> { work items }, { skip set }
-- Nav tiles on this page whose child feed has never been fetched. The skip set
-- is those same tiles keyed by filepath, so the cover queue can leave them
-- alone: resolving one turns it into a book whose cover comes from the CHILD
-- feed, so fetching the tile's own thumbnail first is a download spent on a
-- tile that is about to stop existing.
--
-- Credentials are resolved here rather than at fetch time, and gated on
-- sameOrigin exactly as the feed fetch and the cover fetch are: a nav href came
-- out of the server's XML and could name any host.
local function _opdsNavResolveQueue(records, chip)
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local OpdsSource = require("lib/bookshelf_opds_source")
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    local Prefs      = require("lib/bookshelf_opds_prefs")
    local timeouts   = Prefs.timeouts(chip)
    local queue, skip = {}, {}
    for _i, rec in ipairs(records) do
        if rec.is_opds_nav and rec.opds and rec.opds.feed_url
                and type(rec.filepath) == "string" then
            local sk = rec.filepath:match("^OPDS://([^/]+)/")
            if sk then
                -- fetched_at is the self-limiting signal: a resolved child
                -- window persists, so a multi-item folder is fetched once,
                -- stays a folder, and is never fetched again. Without it this
                -- would re-fetch every folder on every pass.
                -- A tile that TELLS US it holds more than one item cannot be
                -- the one-book folder this is looking for, so fetching it can
                -- never change how it renders. Internet Archive's category
                -- tiles declare ~10000 apiece, and resolving eight of them cost
                -- 13 seconds on device for no visual change whatsoever.
                -- Unknown count still gets fetched -- most catalogs say
                -- nothing, and those are exactly the ones worth asking.
                local declared = tonumber(rec.nav_item_count)
                local one_book_possible = not declared or declared <= 1
                local win = OpdsWindow.load(sk, rec.opds.feed_url)
                if one_book_possible and (win.fetched_at or 0) <= 0 then
                    local server = OpdsSource.getServer(sk)
                    if server then
                        local same = OpdsFeed.sameOrigin(server.url, rec.opds.feed_url)
                        queue[#queue + 1] = {
                            kind       = "resolve",
                            server_key = sk,
                            feed_url   = rec.opds.feed_url,
                            user       = same and server.username or nil,
                            password   = same and server.password or nil,
                            timeouts   = timeouts,
                        }
                        skip[rec.filepath] = true
                    end
                end
            end
        end
    end
    return queue, skip
end

-- _opdsResolvedCoverItem(server_key, feed_url) -> queue item | nil
-- The cover work a just-resolved folder created, ready to append to the queue
-- that is still running.
--
-- Resolving a one-book folder turns a tile into a BOOK, and that book has a
-- cover the queue was built before anyone knew about. The chain used to learn
-- this only at its very end, by re-arming and recomputing from the new page
-- shape - so on a catalog where every tile is a folder (Gutenberg's shape, and
-- ManyBooks'), not one cover could be fetched until the LAST resolve came
-- back. Twelve resolves at a second or two each is a shelf that stays blank
-- for the whole chain and then fills at once.
--
-- Appending here instead means the first resolve's cover is in flight while
-- the eleventh is still resolving: same requests, same order, but the page
-- starts filling seconds in. The tail re-arm stays as the backstop for
-- everything this cannot see (a resolved folder holding several books whose
-- own covers are wanted).
--
-- opdsLoneChildBook is the same predicate the render path flattens with, so
-- what gets queued here is exactly the record the next repaint will paint --
-- nil for a folder that turned out to hold more than one book, which correctly
-- stays a folder and has no cover of its own to fetch.
local function _opdsResolvedCoverItem(server_key, feed_url)
    local ok, lone = pcall(Repo.opdsLoneChildBook, server_key, feed_url)
    if not (ok and type(lone) == "table") then return nil end
    local OpdsCovers = require("lib/bookshelf_opds_covers")
    if not OpdsCovers.cachePath(lone) then return nil end
    if not OpdsCovers.needsFetch(lone) then return nil end
    return { kind = "cover", rec = lone }
end

-- Cover fill for an OPDS page. OFF by default and per catalog: the shelf does
-- NOT bulk-download remote cover images unless the chip asks it to.
--
-- Why the default is off. A full page of remote covers is a serial blocking
-- download; over a slow public catalog it made paging feel stuck, and the
-- covers themselves are often heavy. So the shelf shows the title+author
-- placeholder card and a cover is fetched only when a book is TAPPED
-- (_opdsFetchDetailCover, for the detail modal), which then also lands it on
-- that shelf cell on the next rebuild.
--
-- Why it is now switchable. That reasoning is about PUBLIC catalogs. On a
-- server on your own network the covers are a few milliseconds away and the
-- placeholders are just worse, and two users have now read tap-only covers as
-- the feature being broken. The batching, token and re-arm machinery below is
-- unchanged from when this ran unconditionally, so the opt-in path is the one
-- that was already proven on device rather than a fresh one.
-- Despite the name this drives ALL background page work, covers and nav-tile
-- resolution alike: one queue, one token, one abandon path, so the two can
-- never race each other or double the fetches in flight. Kept as the name every
-- render path already calls.
function BookshelfWidget:_opdsEnsureCovers()
    -- Effective, not active: a drilled navigation entry renders remote records
    -- exactly like the chip's root feed does, so its thumbnails have to fill
    -- too. Non-OPDS views resolve to nil and bail here as before.
    if not self:_opdsEffectiveTab() then return end
    -- The chip, not the effective tab: a drilled subcatalog's stand-in carries
    -- no settings (see _opdsPrefsTab), and the catalog's choice governs its
    -- subcatalogs too.
    local Prefs = require("lib/bookshelf_opds_prefs")
    local chip  = self:_opdsPrefsTab()
    local want_covers  = Prefs.autoCovers(chip)
    local want_resolve = Prefs.resolveNav(chip)
    if not (want_covers or want_resolve) then return end
    local records = self._page_items
    if not records then return end
    -- Offline (or Wi-Fi off): skip rather than let each miss block the main
    -- loop on a socket timeout. isConnected() answers true on platforms with
    -- no Wi-Fi toggle, so desktop builds still fill their thumbnails. Never
    -- prompts -- a passive cover fill must not raise a Wi-Fi dialog.
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isConnected
            and not NetworkMgr:isConnected() then
        return
    end
    -- "Missing" = has a thumbnail worth fetching (cachePath resolves - a
    -- deterministic name, no disk check) AND the repo did NOT already attach
    -- the record's OWN cover_image_path for it. The repo already did the one
    -- lfs stat per record this pass needs (OpdsCovers.cachedPath, inside
    -- getBySource); a second `not rec.has_cover` gate here would re-select
    -- every record on every pass, because the repo never sets has_cover for
    -- OPDS records (see the cover_image_path comment there) --
    -- rec.cover_image_path is the up-to-date signal instead.
    --
    -- rec.cover_borrowed is the exception: a nav tile with none of its own
    -- artwork yet borrows a child feed's cached cover so it isn't a bare
    -- placeholder (see the borrow in bookshelf_book_repository.lua's opds
    -- branch), but that borrow is not the tile's own download landing. Without
    -- also selecting borrowed records here, the borrow's non-nil
    -- cover_image_path would permanently look "already fetched" and the
    -- tile's own cover would never enter fetchMissing -- borrowed forever,
    -- never self-healing even once the tile's own artwork appears on disk.
    -- Once it does, the repo's own-cover check (which runs first and wins)
    -- fills cover_image_path from the tile's own cachedPath and leaves
    -- cover_borrowed unset, so this stops selecting it on the very next pass.
    local OpdsCovers = require("lib/bookshelf_opds_covers")
    -- The resolve queue is BUILT first, because it decides which tiles the
    -- cover queue must skip -- but COVERS RUN FIRST.
    --
    -- They used to run second, on the reasoning that resolution changes the
    -- page shape so covers should follow it. That reasoning is already
    -- satisfied by the skip set: a tile queued for resolution is excluded from
    -- the cover queue, so every cover in it is one the page wants whatever
    -- resolution does. Meanwhile the cost of going second was severe and
    -- measured: on a page of folder tiles the whole first chain was eight nav
    -- fetches at 1.0-3.6s each, nine seconds that landed ZERO covers, and only
    -- the re-armed second chain fetched any. The shelf sat blank throughout
    -- and then filled at once.
    --
    -- Covers first means something appears in about a second, and the folder
    -- resolution -- which changes tiles the user can already see and read --
    -- happens behind it.
    -- The skip set the builder also returns is deliberately NOT taken: nav
    -- tiles now get their own thumbnail fetched as well as being resolved
    -- (see the cover queue below for the measurement that changed this).
    local resolve_queue = {}
    if want_resolve then
        resolve_queue = _opdsNavResolveQueue(records, chip)
    end
    local queue = {}
    if want_covers then
        for _i, rec in ipairs(records) do
            if rec.is_remote and (not rec.cover_image_path or rec.cover_borrowed)
                    and OpdsCovers.cachePath(rec) then
                    -- NOT skipped when the tile is also queued for resolution.
                    --
                    -- It used to be, to avoid downloading a thumbnail that
                    -- resolution might supersede. Measured cost of that
                    -- optimisation on device: a ManyBooks-style catalog is
                    -- ENTIRELY nav tiles, so the skip emptied the cover queue,
                    -- and the shelf sat blank for the whole eight-second
                    -- resolve chain before the re-arm fetched anything at all.
                    --
                    -- Those tiles carry their own thumbnails, and on the
                    -- catalogs that present each book as a folder that
                    -- thumbnail IS the book's cover - so fetching it shows the
                    -- right image about a second in, and resolution then
                    -- changes what the tile IS behind an already-populated
                    -- shelf. The waste is one image per tile whose resolved
                    -- book turns out to have a different cover url, which is
                    -- cheap and cached either way.
                queue[#queue + 1] = { kind = "cover", rec = rec }
            end
        end
    end
    for _i, item in ipairs(resolve_queue) do queue[#queue + 1] = item end
    -- FIRST in the queue, not last.
    --
    -- Last was the intuitive order - the page in front of the user matters
    -- more than the one after it - and it meant the item never ran at all. On
    -- Internet Archive a cover takes 3-5 seconds, so a chain of ten covers
    -- outlives the reader: they page before the queue reaches its final item,
    -- the token bumps, and the pool kills a lookahead that never started. The
    -- log said so plainly - the decision to fetch was made three times and not
    -- one kind=page worker was ever launched - while the blocking fetch it
    -- exists to prevent ran five seconds later every time.
    --
    -- Ordering only bites when the queue is longer than the pool is wide, and
    -- at ten wide a page of covers plus this one item nearly all start in the
    -- first wave anyway. So the real cost of going first is at most one cover
    -- deferred by one wave, against a modal progress dialog avoided.
    local ahead = self:_opdsLookaheadItem()
    if ahead then table.insert(queue, 1, ahead) end
    -- Bumped BEFORE the empty early return, not after it: an earlier chain may
    -- still be in flight for a page the user has since left, and if this pass
    -- returns without moving the token that chain still matches on completion
    -- and repaints a page it knows nothing about. Harmless as repaints go, but
    -- the guard is meant to be exact -- reaching this line at all means "the
    -- current page's background work is now this pass's business".
    self._opds_cover_token = (self._opds_cover_token or 0) + 1
    if #queue == 0 then return end
    local token = self._opds_cover_token
    UIManager:scheduleIn(OPDS_COVER_TICK, function()
        -- Teardown guard: the widget can be closed inside the window, and a
        -- blocking fetch against a torn-down shelf is pure waste. Same liveness
        -- test onCloseWidget maintains for _cover_settle_cb.
        if BookshelfWidget.live ~= self then return end
        -- Superseded guard: if the user paged (or drilled) within the window,
        -- a newer pass has bumped the token and owns the page now.
        if token ~= self._opds_cover_token then return end
        -- want_covers travels with the chain: a resolve that lands mid-run
        -- wants to queue the resolved book's cover, and on a catalog set to
        -- tap-only covers it must not. So does the pool width, resolved off
        -- the chip here rather than read again deeper in - a drilled
        -- subcatalog's stand-in carries no settings.
        self:_opdsCoverPool(queue, token,
                            { creds = {}, landed = 0, painted = 0, resolved = 0,
                              want_covers = want_covers,
                              concurrency  = Prefs.concurrency(chip) })
    end)
end

-- How many background page fetches may be in flight at once is a PER-CATALOG
-- setting now (Prefs.concurrency / CONCURRENCY_OPTIONS, where the measurement
-- and the throttling history that set the default live). The chain carries the
-- resolved number on its state, so there is no second copy of it here to drift
-- out of step with the option list.
--
-- How far ahead of the cursor the cached window is kept, in screenfuls.
--
-- FIVE, raised from two once storage stopped costing anything. Appending a
-- page was 399ms of whole-store re-serialisation and is now about 1ms of
-- INSERT, so the only remaining cost of reading ahead is the round trip - and
-- that already happens in a forked worker that a page turn kills.
--
-- Why depth rather than bigger pages: the server decides page size and will
-- not be told otherwise. Measured - Gutenberg serves 25 and ignores count,
-- limit, length, per_page, page_size and items; Internet Archive returns
-- byte-identical responses for all of those and declares itemsPerPage 25 in
-- the feed itself. So the only lever the client has is how many pages it asks
-- for, and how quietly.
--
-- The walk stays sequential because it must: a page's url exists only in the
-- previous page's rel=next, so there is nothing to parallelise within one
-- feed. Each landed page queues the next, in the pool, until the depth is
-- satisfied.
local OPDS_LOOKAHEAD_VIEWS = 5
-- Ceiling on requests one lookahead run may spend, whatever the arithmetic
-- says. A server that serves two records a page would otherwise turn five
-- screens into fifty round trips; the reader gets what this buys and the rest
-- arrives on the next render.
local OPDS_LOOKAHEAD_MAX_REQUESTS = 6

-- _opdsLookaheadItem() -> a "page" work item, or nil.
--
-- The second attempt at keeping a screen in hand. The first drove
-- _opdsFetchMore, which is the USER-FACING fetch - Trapper, a modal progress
-- line that yields for input, and a tail that re-clamps the cursor - so it
-- blocked input on a page already delivered and moved the shelf under a swipe
-- in flight.
--
-- This one rides the cover pool instead, which is already everything a
-- background fetch has to be: the request happens in a forked child so the UI
-- thread never blocks, the parent only parses and appends, a page turn kills
-- the workers via the token, and nothing it does touches the cursor or shows
-- a widget. Appending to the window is invisible until the user pages into it.
--
-- Declines whenever the answer might be someone else's: no rel=next (the feed
-- is complete), the window is already deep enough, or a user-facing fetch
-- holds the marker.
function BookshelfWidget:_opdsLookaheadItem()
    local tab = self:_opdsEffectiveTab()
    if not tab then return nil end
    if self:_opdsFetchBusy() then return nil end
    local server_key, feed_url = self:_opdsFeedRef(tab)
    if not server_key then return nil end
    local ok_w, OpdsWindow = pcall(require, "lib/bookshelf_opds_window")
    if not ok_w then return nil end
    local win = OpdsWindow.load(server_key, feed_url)
    if not win then return nil end
    -- Follow the chain when we have it. When we do not AND the feed has never
    -- been seen to end, the chain is LOST rather than finished, so start again
    -- from the top - the same rule the user-facing walk uses. Dedupe is a
    -- unique index, so re-treading a known page adds nothing twice and
    -- restores the next link for the run after this one.
    --
    -- Returning nil here instead was a dead end: once the top-up went silent
    -- for any page that already had books on it, a feed with no next link had
    -- nothing left that would ever fetch for it, and paging past what it held
    -- showed "no books yet" forever.
    local fetch_url = OpdsWindow.fetchUrl(win, feed_url)
    if not fetch_url then return nil end
    local have = win.count or 0
    local view = self:_viewSize() or 24
    local want = math.max(0, (self._cursor or 1) - 1)
                 + view * OPDS_LOOKAHEAD_VIEWS
    -- Cost the depth in REQUESTS, from the page size the server declared
    -- (itemsPerPage). It is the only thing the server lets us know about its
    -- pagination - it will not accept a page size, but it will tell us one -
    -- and without it a depth of five screens is an unknown number of round
    -- trips: four against a server serving 25, fifty against one serving two.
    --
    -- Capped so one run can never turn into a crawl. Whatever the cap leaves
    -- unfetched, the next render asks for again, so depth is still reached -
    -- just in bounded bites, with a page turn free to cancel between them.
    local per_page = win.items_per_page
    local plan = OPDS_LOOKAHEAD_MAX_REQUESTS
    if per_page and per_page > 0 and have < want then
        plan = math.min(plan, math.max(1, math.ceil((want - have) / per_page)))
    end
    logger.dbg(string.format(
        "[bookshelf perf] opds lookahead: have=%d want=%d cursor=%s view=%d "
        .. "per_page=%s plan=%d next=%s decision=%s",
        have, want, tostring(self._cursor), view, tostring(per_page), plan,
        tostring(win.next_url ~= nil), have >= want and "deep enough" or "FETCH"))
    if have >= want then return nil end
    local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
    if not ok_s then return nil end
    local server = OpdsSource.getServer(server_key)
    if not server then return nil end
    -- Credentials gated on same-origin exactly as the cover and resolve
    -- fetches are: a rel=next came out of the server's own feed and could
    -- name any host.
    local ok_f, OpdsFeed = pcall(require, "lib/bookshelf_opds_feed")
    local same = ok_f and OpdsFeed.sameOrigin(server.url, fetch_url)
    local Prefs = require("lib/bookshelf_opds_prefs")
    return {
        kind       = "page",
        plan       = plan,          -- requests this run may spend
        server_key = server_key,
        feed_url   = feed_url,        -- where the records are FILED
        fetch_url  = fetch_url,       -- where the body comes FROM
        user       = same and server.username or nil,
        password   = same and server.password or nil,
        timeouts   = Prefs.timeouts(self:_opdsPrefsTab()),
    }
end

-- How often the parent checks its workers. Short enough that a finished
-- download lands promptly, long enough that polling is not itself the cost.
local OPDS_POOL_POLL = 0.15

-- _opdsCoverPool(queue, token, state) - run the queue through forked workers
-- instead of one blocking fetch per tick.
--
-- Same contract as _opdsCoverStep, which it replaces when forking is available:
-- same queue of typed items, same token, same abandon-on-supersede, same
-- repaint cadence, same re-arm when something resolved. ONLY the fetching
-- moves off the UI thread - which is the whole point, because the fetching is
-- what was blocking it.
--
-- Each worker does exactly one item and reports through its pipe. A cover
-- worker writes the image to the cache path itself and pipes back only
-- "1"/"" - piping the bytes would mean holding a whole image in the parent to
-- write it out again. A resolve worker pipes its feed body, because the parent
-- is the one that must parse and store it (the child's memory is discarded).
--
-- Falls back to the sequential chain when forking is unavailable (Android) or
-- a fork fails mid-run, so no platform loses the feature.
function BookshelfWidget:_opdsCoverPool(queue, token, state)
    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    if not (ok_ffi and ffiutil and ffiutil.runInSubProcess) then
        return self:_opdsCoverStep(queue, 1, token, state)
    end
    local OpdsCovers = require("lib/bookshelf_opds_covers")
    local OpdsFeed   = require("lib/bookshelf_opds_feed")
    -- The pool's width. Starts at the measured opening bid and NARROWS on
    -- failure: halve on any timeout or error, floor of 1, and never widen
    -- again for the life of this chain.
    --
    -- Measurement says 10 scales cleanly on a healthy catalog and 16 collapses
    -- (see Prefs.CONCURRENCY). But only one catalog was reachable to measure,
    -- and the one that ISN'T -- Internet Archive -- is the one with a
    -- throttling history: an always-wide pool was removed once (1477764)
    -- because public catalogs answered a burst with half-filled pages. A fixed
    -- number cannot be right for both, so the pool watches what it gets back
    -- instead of trusting the constant.
    --
    -- Narrowing only, deliberately. Recovering mid-chain would re-widen into a
    -- server that has just said no, and a chain is one page of covers - the
    -- next page opens at full width again, so a server that was briefly busy
    -- is not punished for the rest of the session.
    local cap = state.concurrency
                or require("lib/bookshelf_opds_prefs").CONCURRENCY
    local next_i, in_flight, fork_broken = 0, {}, false
    state.t_begin = state.t_begin or _gettime()
    state.t_fetch = state.t_fetch or 0
    state.t_paint = state.t_paint or 0
    state.n_fetch = state.n_fetch or 0

    local function stillCurrent()
        return BookshelfWidget.live == self and token == self._opds_cover_token
    end
    local function paint(why)
        if not stillCurrent() then return end
        local t0 = _gettime()
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        local ms = (_gettime() - t0) * 1000
        state.t_paint = state.t_paint + ms
        logger.dbg(string.format(
            "[bookshelf perf] opds pool repaint: %s rebuild+dirty=%.0fms", why, ms))
    end
    -- A worker whose output we read while it was still alive must still be
    -- reaped, or it lingers as a zombie for the rest of the session.
    local function collectLater(pid)
        local c
        c = function()
            if not ffiutil.isSubProcessDone(pid) then
                UIManager:scheduleIn(1, c)
            end
        end
        UIManager:scheduleIn(1, c)
    end
    local function launch(item)
        local payload
        if item.kind == "resolve" or item.kind == "page" then
            -- Both are "fetch a feed body and hand it back for the parent to
            -- parse". The child's memory is discarded, so it cannot store
            -- anything itself.
            payload = function(_pid, fd)
                local body = OpdsFeed.fetch(item.fetch_url or item.feed_url,
                                            item.user, item.password,
                                            item.timeouts)
                ffiutil.writeToFD(fd, body or "", true)
            end
        else
            -- Plan resolved in the PARENT so the child cannot disagree about
            -- which url this cover is, where it caches, or whether credentials
            -- may travel to it (see OpdsCovers.fetchPlan).
            local plan = OpdsCovers.fetchPlan(item.rec, state.creds)
            if not plan then return false end
            payload = function(_pid, fd)
                local CoverFetch = require("lib/bookshelf_cover_fetch")
                local got = CoverFetch.download(plan.url, plan.path, plan.user,
                                                plan.password, plan.net_opts)
                ffiutil.writeToFD(fd, got and "1" or "", true)
            end
        end
        local pid, rfd = ffiutil.runInSubProcess(payload, true)
        if not pid then fork_broken = true; return false end
        in_flight[#in_flight + 1] =
            { pid = pid, fd = rfd, item = item, t0 = _gettime() }
        return true
    end
    local function fill()
        while #in_flight < cap
                and next_i < #queue and not fork_broken do
            next_i = next_i + 1
            local item = queue[next_i]
            -- Tested POSITIVELY on "cover", not as "anything that is not a
            -- resolve". The negative form silently swallowed every later item
            -- kind: a page item carries no .rec, needsFetch(nil) is false, and
            -- "not false" skipped it as already-cached. The lookahead decided
            -- to fetch on every page turn for a whole session and not one
            -- worker was ever launched. A new kind must never be droppable by
            -- a branch that predates it.
            if item.kind == "cover" and not OpdsCovers.needsFetch(item.rec) then
                -- Already on disk: costs nothing, and must not occupy a worker.
            else
                launch(item)
            end
        end
    end

    local poll
    poll = function()
        if not stillCurrent() then
            -- Superseded or torn down: kill the workers rather than let them
            -- finish into a page nobody is looking at.
            --
            -- Killing is not collecting. terminateSubProcess sends SIGKILL and
            -- says so in its own comment: "Process will still have to be
            -- collected with calls to util.isSubProcessDone()". Without the
            -- collectLater below, every worker abandoned by a page turn stayed
            -- a ZOMBIE for the rest of the session - four of them were sitting
            -- on the test device, parented to the reader, after an evening's
            -- browsing. Each holds a PID slot and a kernel task struct, and
            -- nothing ever reaps them because this loop is the last thing that
            -- knew the pid.
            for _k, e in ipairs(in_flight) do
                pcall(ffiutil.terminateSubProcess, e.pid)
                if e.fd then pcall(ffiutil.readAllFromFD, e.fd) end
                collectLater(e.pid)
            end
            in_flight = {}
            return
        end
        local still = {}
        for _k, e in ipairs(in_flight) do
            local done     = ffiutil.isSubProcessDone(e.pid)
            local readable = e.fd and ffiutil.getNonBlockingReadSize(e.fd) ~= 0
            if done or readable then
                local out = e.fd and ffiutil.readAllFromFD(e.fd) or ""
                local ms = (_gettime() - e.t0) * 1000
                state.t_fetch = state.t_fetch + ms
                state.n_fetch = state.n_fetch + 1
                -- A worker that came back with nothing is the server saying
                -- no: a timeout, a refused connection, an error page. Halve
                -- and keep going rather than finishing the queue at a width
                -- the server has already rejected.
                if out == "" and cap > 1 then
                    cap = math.max(1, math.floor(cap / 2))
                    logger.dbg("[bookshelf perf] opds pool: narrowing to", cap)
                end
                if e.item.kind == "page" then
                    -- The next page of the feed on screen. Nothing about the
                    -- CURRENT page changes, so this needs no repaint of its
                    -- own; it just means the page after this one is already
                    -- here when the user turns to it. The tail repaint picks
                    -- up the new page count.
                    if out ~= "" and _storeFeedPage(e.item.server_key,
                                                    e.item.feed_url,
                                                    e.item.fetch_url, out) then
                        state.paged = (state.paged or 0) + 1
                        -- Keep walking. The chain is sequential - the next
                        -- url only exists in the page that just landed - so
                        -- depth is reached one request at a time, each queued
                        -- into the pool that is already running. The
                        -- lookahead declines as soon as the window is deep
                        -- enough, which is what ends this.
                        -- Spend no more than this run was budgeted, so a
                        -- server with a tiny page size cannot turn one render
                        -- into a crawl.
                        local budget = e.item.plan or OPDS_LOOKAHEAD_MAX_REQUESTS
                        if (state.paged or 0) < budget then
                            local more = self:_opdsLookaheadItem()
                            if more then
                                queue[#queue + 1] = more
                                logger.dbg(string.format(
                                    "[bookshelf perf] opds pool: reading further ahead (%d/%d)",
                                    state.paged, budget))
                            end
                        end
                    end
                elseif e.item.kind == "resolve" then
                    if out ~= "" and _storeChildFeed(e.item.server_key,
                                                     e.item.feed_url, out) then
                        state.resolved = state.resolved + 1
                        -- Pipeline: this folder is a book now, so its cover
                        -- joins the queue this loop is still draining rather
                        -- than waiting for the whole chain's re-arm.
                        local extra = state.want_covers and _opdsResolvedCoverItem(
                            e.item.server_key, e.item.feed_url)
                        if extra then
                            queue[#queue + 1] = extra
                            logger.dbg(
                                "[bookshelf perf] opds pool: queued resolved cover, "
                                .. #queue .. " item(s) now")
                        end
                    end
                else
                    if out == "1" then state.landed = state.landed + 1 end
                end
                logger.dbg(string.format(
                    "[bookshelf perf] opds pool item: kind=%s %.0fms ok=%s",
                    e.item.kind or "cover", ms, tostring(out ~= "")))
                if not done then collectLater(e.pid) end
            else
                still[#still + 1] = e
            end
        end
        in_flight = still
        fill()
        if state.landed - state.painted >= _opdsPaintThreshold(state.painted) then
            local first = state.painted < 1
            state.painted = state.landed
            paint(first and "first-cover" or "cover-batch")
        end
        if #in_flight > 0 or (next_i < #queue and not fork_broken) then
            UIManager:scheduleIn(OPDS_POOL_POLL, poll)
            return
        end
        if fork_broken and next_i < #queue then
            -- Forking died mid-run: finish what is left the old way rather
            -- than dropping it.
            local rest = {}
            for i = next_i + 1, #queue do rest[#rest + 1] = queue[i] end
            return self:_opdsCoverStep(rest, 1, token, state)
        end
        -- Done.
        -- Sweep on ANY cover having landed, not just unpainted ones: the cache
        -- byte cap is a property of the chain, not of whether its last paint
        -- happened to be owed. Gating it on "unpainted" meant a chain whose
        -- covers were all painted mid-run never enforced the cap at all.
        -- Before the paint, so the shelf renders what survives the sweep.
        if state.landed > 0 then OpdsCovers.sweepCache() end
        if (state.landed > state.painted) or state.resolved > 0
                or (state.paged or 0) > 0 then
            paint("tail")
        end
        local total = (_gettime() - state.t_begin) * 1000
        local tf, tp, nf = state.t_fetch, state.t_paint, state.n_fetch
        logger.dbg(string.format(
            "[bookshelf perf] opds POOL DONE: items=%d fetched=%d landed=%d "
            .. "resolved=%d cap=%d | fetch=%.0fms (%.0fms avg, OFF-THREAD) "
            .. "paint=%.0fms | blocking=%.0fms of %.0fms wall (%.0f%%)",
            #queue, nf, state.landed, state.resolved, cap,
            tf, (nf > 0) and (tf / nf) or 0, tp, tp, total,
            (total > 0) and (tp / total * 100) or 0))
        if state.resolved > 0 then self:_opdsEnsureCovers() end
    end

    fill()
    if #in_flight == 0 and fork_broken then
        return self:_opdsCoverStep(queue, 1, token, state)
    end
    UIManager:scheduleIn(OPDS_POOL_POLL, poll)
end

-- _opdsCoverStep(queue, idx, token, state) - fetch ONE cover, then hand the
-- main loop back before taking the next.
--
-- Replaces a single blocking pass over the whole page. fetchMissing downloads
-- serially with a 20-second budget and nothing yields inside it, so on a slow
-- catalog the shelf froze in 20-second blocks: on Internet Archive, whose
-- cover server has been measured at 8 seconds a request, that is two or three
-- covers per freeze and a page turn that does not register until it ends. This
-- is opds_plus's ImageLoader shape (one image per tick, re-scheduled), which
-- is the model that reads as responsive rather than stuck.
--
-- What this does NOT fix: one cover is still a blocking download, so a single
-- 8-second request still holds the loop for 8 seconds. The per-request
-- timeouts (THUMB_BLOCK/THUMB_TOTAL, 5s/10s) are the ceiling on that. Fixing
-- it properly needs the download off the UI thread entirely, which the forked
-- subprocess pool in b73887b tried and lost to server throttling.
--
-- Guards are re-tested on EVERY tick, not once at the start. The entire point
-- is that the user can act between ticks, and paging is exactly what bumps the
-- token -- so an abandoned chain must notice at its next step rather than run
-- the queue out against a page nobody is looking at.
function BookshelfWidget:_opdsCoverStep(queue, idx, token, state)
    local OpdsCovers = require("lib/bookshelf_opds_covers")
    if BookshelfWidget.live ~= self then return end
    if token ~= self._opds_cover_token then return end
    local item = queue[idx]
    if not item then
        -- Chain complete. Paint whatever landed since the last repaint, and
        -- sweep BEFORE that paint so the shelf renders what is on disk after
        -- the sweep rather than briefly showing a cover the sweep just dropped
        -- (the ordering fetchMissing established).
        -- Sweep on ANY cover having landed (see the pool's tail for why).
        if state.landed > 0 then OpdsCovers.sweepCache() end
        local unpainted = (state.landed > state.painted) or state.resolved > 0
        if unpainted then
            local t0 = _gettime()
            self:_rebuild()
            UIManager:setDirty(self, "ui")
            state.t_paint = (state.t_paint or 0) + (_gettime() - t0) * 1000
        end
        -- The verdict line: where the chain's wall time actually went, and how
        -- much of it blocked the UI thread. fetch >> paint means the downloads
        -- are the problem and belong off-thread; paint >> fetch means they do
        -- not and the repaint strategy is what needs changing.
        if (state.n_fetch or 0) > 0 or (state.t_paint or 0) > 0 then
            local total = (_gettime() - (state.t_begin or _gettime())) * 1000
            local tf, tp, nf = state.t_fetch or 0, state.t_paint or 0, state.n_fetch or 0
            logger.dbg(string.format(
                "[bookshelf perf] opds cover chain DONE: items=%d fetched=%d "
                .. "landed=%d resolved=%d | fetch=%.0fms (%.0fms avg) "
                .. "paint=%.0fms | blocking=%.0fms of %.0fms wall (%.0f%%)",
                #queue, nf, state.landed, state.resolved, tf,
                (nf > 0) and (tf / nf) or 0, tp, tf + tp, total,
                (total > 0) and ((tf + tp) / total * 100) or 0))
        end
        -- Resolution changed the page: folders became books, and those books
        -- have covers of their own that this queue never knew about. ONE re-arm
        -- recomputes from the new page shape and fetches them.
        --
        -- Terminates because both kinds of work are self-limiting: a resolved
        -- child window persists (fetched_at > 0), so the next pass finds nothing
        -- to resolve, and covers that landed are on disk, so needsFetch stops
        -- selecting them. Gated on resolved > 0 so a pass that only fetched
        -- covers does not re-arm at all.
        if state.resolved > 0 then self:_opdsEnsureCovers() end
        return
    end
    -- Per-item timing, split FETCH from REPAINT. The two call for opposite
    -- fixes: if the downloads dominate, moving them off the UI thread is the
    -- answer; if the repaints do, threading changes nothing and the fix is to
    -- stop calling a full _rebuild per batch. Guessing between those is how
    -- this loop has already been rewritten twice.
    local _t_start = _gettime()
    state.t_fetch  = state.t_fetch  or 0
    state.t_paint  = state.t_paint  or 0
    state.n_fetch  = state.n_fetch  or 0
    state.t_begin  = state.t_begin  or _t_start
    local function _paint(why)
        local t0 = _gettime()
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        local ms = (_gettime() - t0) * 1000
        state.t_paint = state.t_paint + ms
        logger.dbg(string.format(
            "[bookshelf perf] opds cover repaint: %s rebuild+dirty=%.0fms", why, ms))
    end
    if item.kind == "resolve" then
        local OpdsFeed = require("lib/bookshelf_opds_feed")
        local _tf = _gettime()
        local body = OpdsFeed.fetch(item.feed_url, item.user, item.password,
                                    item.timeouts)
        local fetch_ms = (_gettime() - _tf) * 1000
        state.t_fetch = state.t_fetch + fetch_ms
        state.n_fetch = state.n_fetch + 1
        logger.dbg(string.format(
            "[bookshelf perf] opds resolve fetch: %.0fms ok=%s %s",
            fetch_ms, tostring(body ~= nil), tostring(item.feed_url)))
        if body and _storeChildFeed(item.server_key, item.feed_url, body) then
            state.resolved = state.resolved + 1
            -- Pipeline, as in the pool: the folder is a book now and its cover
            -- joins the queue still being walked, instead of waiting for the
            -- tail re-arm to discover it.
            local extra = state.want_covers and _opdsResolvedCoverItem(
                item.server_key, item.feed_url)
            if extra then queue[#queue + 1] = extra end
            -- Same cadence as covers, counted separately: resolving four
            -- folders is four tiles changing shape, worth a repaint, and
            -- mixing the two counters would delay whichever is in the minority.
            if state.resolved % OPDS_COVER_REBUILD_EVERY == 0 then
                _paint("resolve-batch")
            end
        end
    else
        local rec = item.rec
        -- Already on disk: skip it within THIS tick rather than spending a tick
        -- to discover it. A page whose covers are all cached would otherwise
        -- take a fifth of a second per cell to walk. A Lua tail call, so a long
        -- run of cached records costs no stack.
        if not OpdsCovers.needsFetch(rec) then
            return self:_opdsCoverStep(queue, idx + 1, token, state)
        end
        local _tf = _gettime()
        local got = OpdsCovers.fetchOne(rec, state.creds)
        local fetch_ms = (_gettime() - _tf) * 1000
        state.t_fetch = state.t_fetch + fetch_ms
        state.n_fetch = state.n_fetch + 1
        logger.dbg(string.format(
            "[bookshelf perf] opds cover fetch: %.0fms ok=%s %s",
            fetch_ms, tostring(got), tostring(rec.filepath)))
        if got then
            state.landed = state.landed + 1
            -- Repaint every few covers rather than every one: a full _rebuild
            -- per cover costs more than it buys, and on e-ink every one of them
            -- is a visible flash.
            if state.landed - state.painted >= _opdsPaintThreshold(state.painted) then
                local _first = state.painted < 1
                state.painted = state.landed
                _paint(_first and "first-cover" or "cover-batch")
            end
        end
    end
    UIManager:scheduleIn(OPDS_COVER_TICK, function()
        self:_opdsCoverStep(queue, idx + 1, token, state)
    end)
end

-- _opdsAfterPage(items) - the one post-render hook for an OPDS chip, called
-- from both render paths (_rebuild and the _swapShelvesInPlace page-turn
-- fast path) with the page the repo just handed back. Two jobs:
--
--   * items.opds_needs_fetch: the requested slice ran past the cached window,
--     so pull more feed pages. This covers BOTH "first tap, empty cache"
--     (fetch page 1) and "paged past the window" (fetch the next feed page) --
--     the repo sets the flag for both.
--   * thumbnails for the visible page, off the paint path.
--
-- Both are gated on the one-shot _markOpdsNav flag, which this consumes: a
-- rebuild the user did not ask for renders from the cached window and makes
-- no network call of any kind. That gate doubles as the re-entry guard --
-- a fetch that fails leaves the window short, so opds_needs_fetch is STILL
-- set on the rebuild _opdsFetchMore ends with, and without the gate the hook
-- would spin forever against an unreachable server, one toast per turn. The
-- user re-arms it by turning the page, re-tapping the chip, or swiping down.
--
-- Exactly one path puts the flag back instead of spending it: a fetch for
-- another feed is in flight, so this one is queued rather than run (see the
-- busy branch below). That is a deferral of the user's own navigation, not a
-- flag surviving into an unrelated passive rebuild -- the in-flight fetch's
-- tail rebuild is what picks it up, moments later.
function BookshelfWidget:_opdsAfterPage(items)
    -- One-shot: consumed here whether or not it gets used, so it can never
    -- leak into a later passive rebuild (bar the one queue case above, which
    -- re-arms deliberately and is picked up by the very next rebuild).
    local user_nav = self._opds_nav_pending
    self._opds_nav_pending = nil
    if not user_nav then return end
    -- Which feed the page belongs to, resolved the same way _fetchChipItems
    -- picked what to render: a drilled navigation entry's subcatalog wins over
    -- the chip's own source, and any other drilldown tip (search results, a
    -- folder) means the page on screen isn't a feed's at all -- nil, nothing to
    -- do. Resolved AFTER the one-shot flag is consumed, never before: the
    -- consume must happen on every path through this function or a flag armed
    -- for a rebuild that turned out not to be a feed's would leak into the next
    -- passive one and spend itself on a fetch the user never asked for.
    local tab = self:_opdsEffectiveTab()
    if not tab then
        -- Not looking at a feed (a local chip, a search, a folder drill), so
        -- the next OPDS view is an entry again. Without this, switching to a
        -- local chip and back would read as "still in the same feed" and skip
        -- the age check the user asked for on opening it.
        self._opds_age_checked_key = nil
        return
    end
    -- 120s (see _opdsFetchBusy): comfortably longer than a slow feed page over
    -- 2G-ish Wi-Fi, short enough that a fetch killed by an error (which never
    -- reaches the tail that clears this) unblocks itself well before the user
    -- gives up and swipes down. Overlap protection only -- the explicit
    -- swipe-down refresh calls _opdsFetchMore directly and is never blocked.
    -- A modal download holds the same marker with _opds_fetch_feed left nil,
    -- so it reads here as "another feed is busy" -> the queue branch below.
    local busy = self:_opdsFetchBusy()
    -- ...and busy for WHICH feed. _opds_fetch_feed is the in-flight fetch's own
    -- sameFeed predicate (see _opdsFetchMore), so this compares on the resolved
    -- feed url without re-reading the stock plugin's server list here.
    local busy_this = busy and self._opds_fetch_feed ~= nil
                      and self._opds_fetch_feed(tab)
    -- Age-based refresh: the one automatic refetch the shelf performs, and the
    -- fix for a feed that was otherwise cached until the user found the
    -- swipe-down gesture (issue #321). Off unless the chip asks for it.
    --
    -- Scoped to ENTERING a feed rather than to every navigation gesture, which
    -- is what the setting's own wording ("every time I open it") promises. A
    -- page turn is a nav gesture too, and checking there would refetch from
    -- the top mid-catalog -- and against a server that is down, on every
    -- single turn, which is the retry spin the nav gate exists to stop. Leaving
    -- and coming back re-checks, so a failed refresh is retried when the user
    -- next asks for the feed and not before.
    --
    -- Still inside the user_nav gate above: a passive rebuild (file poll, a
    -- cover landing, startup restore) must never reach the network, and an
    -- expiry rule that fired on those would quietly undo that.
    if not busy and type(items) == "table" then
        local Prefs = require("lib/bookshelf_opds_prefs")
        local chip  = self:_opdsPrefsTab()
        if Prefs.refreshAge(chip) ~= nil then
            local OpdsSource = require("lib/bookshelf_opds_source")
            local OpdsWindow = require("lib/bookshelf_opds_window")
            local _sk, feed_url = self:_opdsFeedRef(tab)
            if feed_url then
                local key = tostring(tab.source.id) .. "|" .. feed_url
                local entering = self._opds_age_checked_key ~= key
                self._opds_age_checked_key = key
                local win = OpdsWindow.load(tab.source.id, feed_url)
                if entering and Prefs.isStale(chip, win.fetched_at, os.time()) then
                    -- replace = true, so the refetch REPLACES the stale window
                    -- rather than topping it up: the whole point is that what
                    -- is cached may be wrong, not merely short. _opdsFetchMore
                    -- keeps the old window if the refetch comes back empty, so
                    -- an expiry against a dead server does not blank the shelf.
                    UIManager:nextTick(function()
                        if BookshelfWidget.live ~= self then return end
                        self:_opdsFetchMore(tab, self:_opdsBatchSize(), true)
                    end)
                    return
                end
            end
        end
    end
    if type(items) == "table" and items.opds_needs_fetch then
        if busy_this then
            -- A fetch for THIS feed is already running and its tail rebuilds
            -- this page. Spending the arm is right here: re-arming would let
            -- that tail fire a second fetch for a feed that just finished one,
            -- which against an unreachable server is exactly the per-turn
            -- retry spin the arm exists to prevent.
            self:_opdsEnsureCovers()
            return
        end
        if busy then
            -- A fetch for a DIFFERENT feed holds the marker. Queue rather than
            -- race, so the automatic paths only ever have one feed fetch in
            -- flight (the explicit swipe-down refresh stays exempt, as it
            -- always has been): Trapper's progress widget is module-level
            -- singleton state (Trapper.current_widget, frontend/ui/trapper.lua).
            -- A second wrapped coroutine's info() closes the first's
            -- InfoMessage and installs its own -- whose dismiss_callback
            -- resumes the WRONG coroutine -- and either one's clear() then
            -- closes the other's widget. A coroutine left suspended that way
            -- never returns from Trapper:wrap's pcalled_func, so its
            -- UIManager:preventStandby() is never balanced by allowStandby():
            -- a device that will not sleep again this session. Not worth two
            -- progress lines.
            --
            -- Queueing means putting the one-shot arm BACK rather than
            -- spending it. The in-flight fetch releases the marker before its
            -- tail rebuild, so that rebuild reaches this function with the arm
            -- still set and no marker held, and starts the fetch there. Before
            -- this, the arm was consumed here and nothing rebuilt afterwards:
            -- a nav-tile tap that landed mid-fetch dead-ended on an empty
            -- subcatalog until the user paged or swiped.
            self._opds_nav_pending = user_nav
            self:_opdsEnsureCovers()
            return
        end
        -- LOUD ONLY WHEN THE SHELF WOULD OTHERWISE BE EMPTY.
        --
        -- _opdsFetchMore is the user-facing fetch: Trapper, a modal progress
        -- line that yields for input, and a tail that re-clamps the cursor.
        -- That is right when the reader is staring at nothing and waiting for
        -- this feed to arrive - a blank shelf with no explanation is worse
        -- than a message.
        --
        -- It is wrong when there are already books on screen. Then the reader
        -- has simply outrun the read-ahead, and interrupting a page they can
        -- already use, to tell them about one they have not asked for yet, is
        -- the "blocking Fetching message" complaint. The silent path handles
        -- it: _opdsEnsureCovers queues the same page fetch into the forked
        -- pool, which repaints when it lands and dies quietly if it does not.
        -- What the READER can see, not what the store holds. A window with
        -- entries can still render an empty page - the cursor sits past them
        -- after a deep restore - and calling that "usable" sent it down the
        -- silent path to stare at "no books yet".
        local have_something = false
        for _i = 1, #(self._page_items or {}) do
            if self._page_items[_i] then have_something = true break end
        end
        if have_something then
            logger.dbg("[bookshelf perf] opds top-up: silent (page already usable)")
            self:_opdsEnsureCovers()
            return
        end
        -- Same offset/limit _fetchChipItems asked the repo for, so want_count
        -- is exactly "enough entries to fill the page being rendered".
        local want = math.max(0, (self._cursor or 1) - 1) + self:_opdsBatchSize()
        UIManager:nextTick(function()
            -- Teardown guard, as in _opdsEnsureCovers: don't open a Wi-Fi
            -- prompt / Trapper progress line for a shelf that has gone away.
            if BookshelfWidget.live ~= self then return end
            self:_opdsFetchMore(tab, want)
        end)
        -- No cover pass here: the page is about to change under us and
        -- _opdsFetchMore runs one against the fuller page. Two passes would
        -- fight over _opds_cover_token -- the first batch's downloads land,
        -- then find their token superseded and skip the repaint.
        return
    end
    self:_opdsEnsureCovers()
end

-- ─── OPDS catalog search ─────────────────────────────────────────────────────
--
-- _opdsOpenSearchDialog(tab, prefill) - the shelf's search entry, pointed at
-- a catalog instead of the local library (see the chip strip's search leg
-- for the routing rule). `tab` is the tab-LIKE _opdsEffectiveTab hands
-- back, so this works from a drilled subcatalog exactly as it does from the
-- chip's root. `prefill` carries text the user already typed elsewhere
-- (the page-jump dialog's Search… button) so it isn't thrown away --
-- parity with `_openSearchDialog`, which already prefills.
--
-- Discovery happens HERE, before the keyboard opens, not on submit: a catalog
-- that cannot be searched should say so while the user's question is still
-- "can I search this?", rather than after they have typed one. Two places to
-- look, in order:
--
--   * the CURRENT feed's window (win.search, captured by mapEntries and
--     persisted by appendPage). A feed that advertises its own search link
--     wins -- on a Calibre-style templated href that link is the feed's own.
--   * the server ROOT window's, when the current feed carries none. Most
--     catalogs advertise the search link on their root document only, so a
--     drilled subcatalog would otherwise have nothing to search with even
--     though the catalog plainly supports it. Both windows are cache reads
--     (OpdsWindow never touches the network), so the fallback costs one
--     settings lookup, not a fetch.
--
-- Neither: say which of the two honest reasons applies. An unseen root window
-- (never fetched, or evicted by OpdsWindow's LRU) means we genuinely do not
-- know whether this catalog offers search, and the fix is to load it; a root
-- we HAVE seen that carries no link is a catalog that really does not offer
-- search, and no amount of waiting will change that.
function BookshelfWidget:_opdsOpenSearchDialog(tab, prefill)
    local OpdsSource   = require("lib/bookshelf_opds_source")
    local OpdsWindow   = require("lib/bookshelf_opds_window")
    local Notification = require("ui/widget/notification")
    local server = OpdsSource.getServer(tab.source.id)
    -- A chip pointing at a server the user deleted from the stock OPDS plugin.
    -- Silent, exactly as _opdsFetchMore / _opdsRefresh are: the view itself is
    -- already empty and a search-specific complaint would name the wrong
    -- problem.
    if not server then return end
    local feed_url = tab.source.feed_url or server.url
    local win  = OpdsWindow.load(tab.source.id, feed_url)
    local src  = win.search
    -- The root IS this window when the view is the chip's own feed; only a
    -- drilled subcatalog pays for the second load.
    local root = win
    if not src and feed_url ~= server.url then
        root = OpdsWindow.load(tab.source.id, server.url)
        src  = root.search
    end
    if not src then
        -- "Known" = we have actually seen this catalog's root document, so its
        -- links are a fact rather than an absence. Both signals, not just
        -- fetched_at: a window persisted before fetched_at was written would
        -- otherwise be misread as never fetched and the user told to load a
        -- catalog they are already looking at.
        local root_known = (root.fetched_at or 0) > 0
                           or (root.count or 0) > 0
        UIManager:show(Notification:new{
            text = root_known
                and _("This catalog does not offer search.")
                or  _("Load the catalog first, then search it."),
        })
        return
    end
    -- Named for the CATALOG, not the drilled feed: the search runs against the
    -- whole catalog whenever the link came from its root, and telling the user
    -- they are searching "Science Fiction" when the results span everything
    -- would be the wrong promise. server.title is what the chip itself is
    -- labelled with, so the two agree.
    local who = server.title or tab.label or ""
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = T(_("Search %1"), who),
        input = prefill or "",
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
                        local query = dlg:getInputText() or ""
                        UIManager:close(dlg)
                        -- Trimmed before it becomes a url: a trailing space
                        -- percent-encodes to %20 and several catalogs answer
                        -- that with zero results.
                        query = query:match("^%s*(.-)%s*$")
                        if query ~= "" then
                            self:_opdsSearch(tab, server, src, query)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- _opdsSearch(tab, server, src, query) - turn the discovered search source
-- into a feed url and drill into it. The RESULTS are an ordinary opds_nav
-- frame: back-out, pagination, covers and downloads all already work against
-- one, so this function ends where every other OPDS navigation does and adds
-- no machinery of its own.
--
-- Two source shapes, one exit. type "osd" needs the network (the link points
-- at an OpenSearch description document that holds the actual template);
-- type "template" is a Calibre-style href that already carries
-- {searchTerms} and only needs the substitution. Both run inside ONE Trapper
-- wrap so there is a single marker discipline to read rather than two paths
-- to keep in step -- the template branch simply never calls Trapper:info, so
-- it costs a coroutine and nothing else.
--
-- The wrap holds the FEED marker pair for its whole life so nothing else can
-- start a wrapped coroutine underneath it (the Trapper singleton hazard the
-- long note in _opdsAfterPage describes), and clears BOTH on every exit that
-- set them. It does NOT fetch the results: it clears the markers and drills,
-- and the drill's rebuild schedules _opdsFetchMore on the next tick -- after
-- this coroutine has finished, so the two wraps never nest. That ordering is
-- the same one _opdsFetchMore's tail uses and for the same reason: with the
-- markers still held, the rebuild's fetch would be refused as busy and the
-- user would land on an empty results page.
function BookshelfWidget:_opdsSearch(tab, server, src, query)
    local OpdsFeed     = require("lib/bookshelf_opds_feed")
    local CoverFetch   = require("lib/bookshelf_cover_fetch")
    local Notification = require("ui/widget/notification")
    local Trapper      = require("ui/trapper")
    local feed_url = tab.source.feed_url or server.url
    -- The identity the marker publishes, built exactly as _opdsFetchMore
    -- builds its own (resolved url, server id first) so _opdsAfterPage can
    -- read it with no special case: while this runs, the feed the search was
    -- launched from is the one that counts as busy.
    local function sameFeed(t)
        if not (t and t.source and t.source.id == tab.source.id) then return false end
        return (t.source.feed_url or server.url) == feed_url
    end
    local busy_text = _("The catalog is busy. Try again in a moment.")
    if self:_opdsFetchBusy() then
        UIManager:show(Notification:new{ text = busy_text })
        return
    end
    local function resolve()
        Trapper:wrap(function()
            -- Re-tested FIRST, inside the wrap, for the reason
            -- _opdsRunDownload re-tests: the check above is a snapshot taken
            -- before the Wi-Fi prompt, which the user can leave open for as
            -- long as they like, and a feed fetch sitting in runWhenOnline
            -- holds no marker yet so that snapshot could not have seen it.
            -- Bails BEFORE setting anything: the markers belong to whoever is
            -- busy right now, and clearing them here would advertise a live
            -- coroutine as idle.
            if self:_opdsFetchBusy() then
                UIManager:show(Notification:new{ text = busy_text })
                return
            end
            self._opds_fetch_started_at = os.time()
            self._opds_fetch_feed = sameFeed
            local target
            if src.type == "osd" then
                Trapper:info(T(_("Searching %1…"), server.title or tab.label or ""))
                -- Credentials only ever travel to the catalog's own origin:
                -- the osd href came out of the server's XML and could name any
                -- host, same gate the feed fetch and the download apply.
                local same_origin = OpdsFeed.sameOrigin(server.url, src.href)
                local body, err = OpdsFeed.fetch(src.href,
                    same_origin and server.username or nil,
                    same_origin and server.password or nil)
                local template = body and OpdsFeed.parseOsd(body) or nil
                Trapper:clear()
                if not template then
                    self._opds_fetch_started_at = nil
                    self._opds_fetch_feed = nil
                    -- Same reason as the feed fetch's line: the toast collapses
                    -- every cause into one sentence. The third argument tells
                    -- the two halves of this branch apart -- a transport
                    -- failure carries its status from OpdsFeed.fetch, while a
                    -- document that arrived and did not parse has no err at all
                    -- and is a very different thing to chase.
                    logger.dbg("[bookshelf] opds fetch failed:", src.href,
                               err or "no search template in the response")
                    -- A document that came back but did not parse reports as
                    -- unreachable too: from here the two are the same failure
                    -- (no template, nothing to search with) and the user's
                    -- move is identical, so this reuses the messages the feed
                    -- fetch already speaks rather than minting a third.
                    UIManager:show(Notification:new{
                        text = err == "auth"
                            and T(_("Authentication failed for %1"), server.title)
                            or err == "format"
                            and T(_("%1 refused every format Bookshelf asked for"), server.title)
                            or  T(_("Couldn't reach %1"), server.title),
                    })
                    return
                end
                -- Resolved against the OSD DOCUMENT's own url before the
                -- query goes in, because that is what the template is
                -- relative to. Catalogs are free to advertise a relative one
                -- and some do: bookorbit's is "/api/v1/opds/catalog?q=
                -- {searchTerms}", which substitutes into something that is
                -- not a url at all, so the drill failed without a single
                -- request reaching the server and reported as unreachable
                -- (#322). An already-absolute template resolves to itself, so
                -- catalogs that were working are untouched.
                target = OpdsFeed.substituteQuery(
                    OpdsFeed.absolute(src.href, template), query)
            else
                -- No resolve here: a templated search link is captured by
                -- mapEntries, which already made it absolute against the feed
                -- it was found in.
                target = OpdsFeed.substituteQuery(src.href, query)
            end
            -- Released BEFORE the drill, never after: see the header.
            self._opds_fetch_started_at = nil
            self._opds_fetch_feed = nil
            -- The drill IS the user navigation that licenses the results
            -- fetch, armed like every other nav gesture.
            self:_markOpdsNav()
            self:_drillInto{
                kind    = "opds_nav",
                label   = T(_("Search: \"%1\""), query),
                payload = { server_key = tab.source.id, feed_url = target },
            }
        end)
    end
    if src.type == "osd" then
        -- Only the osd branch talks to the network here, so only it needs the
        -- Wi-Fi gate. The template branch drills straight in and the results
        -- fetch raises the prompt itself (_opdsFetchMore's own runWhenOnline),
        -- which keeps it to one prompt either way.
        CoverFetch.runWhenOnline(function()
            -- The Wi-Fi prompt is modal and can be answered long after the
            -- shelf closed or was replaced. Same liveness test every other
            -- deferred OPDS path makes.
            if BookshelfWidget.live ~= self then return end
            -- ...and the shelf can still be showing something else entirely:
            -- Wi-Fi off is the resting state on an e-reader, so the FIRST
            -- search of a session routinely waits on that prompt, with the
            -- shelf fully interactive underneath it. The user can back out of
            -- the drill, switch chips, even land on a local one before this
            -- runs, and a search drill pushed under THAT context is a results
            -- frame the user never asked for in a place it does not belong.
            -- Re-resolved rather than assumed, exactly as _opdsFetchMore's
            -- tail re-resolves before touching the cursor. Silent: the user
            -- navigated away, which is answer enough -- a toast about a search
            -- they abandoned would be noise.
            if not sameFeed(self:_opdsEffectiveTab()) then return end
            resolve()
        end)
    else
        resolve()
    end
end

-- ─── OPDS book detail modal ──────────────────────────────────────────────────
--
-- What "open" means for a remote catalog record. Reached from the tap path
-- (_openBook) and the long-press path (_showBookDetail): both bounce here
-- because there is no file behind an OPDS:// pseudo-path, so the tabbed
-- book-detail popup would be inert at best and destructive at worst (its Edit
-- tab offers Delete).
--
-- The chrome is a plain ButtonDialog: cover + title / author + the first few
-- lines of the feed's blurb as one added header widget, then a full-width row
-- per downloadable format. NOT the ReviewsModal engine the local book detail
-- uses -- its footer is a fixed row (Close / zoom / Open) with nowhere to put a
-- variable number of download buttons, so they would have had to live inside a
-- native tab: an extra tap to reach the only action the screen exists for, and
-- a composition this file has learned to be careful with (widgets that behave
-- standalone can misbehave inside a cropped modal -- see the text_chevrons
-- note). The blurb still gets the full ReviewsModal treatment (scrollable,
-- sanitised HTML, A-/A+ zoom) one tap away behind Description, built from the
-- same header builder so the two read as one surface.

-- Store key: OPDS pseudo-path -> the on-disk path a completed download landed
-- at. Small and flat (two short strings per downloaded book), so it stays in
-- the MAIN settings store rather than earning a subStoreFor route of its own:
-- it is READ on every OPDS page render (bookshelf_book_repository's opds
-- branch, for the downloaded decoration), where an already-open in-memory
-- table is exactly what's wanted, and WRITTEN only when a download completes --
-- so the main file's re-serialise is paid once per download, never per render.
-- The sub-stores exist for values that are large (opds_cache) or rewritten
-- constantly (hardcover_links); this is neither.
--
-- The key itself lives in bookshelf_opds_download (its other reader is the book
-- repository, which is nowhere near this file) -- one spelling, two callers.
local OPDS_DOWNLOADS_KEY = require("lib/bookshelf_opds_download").STORE_KEY
-- Sibling map (path -> catalog description); written here on download, read by
-- Repo.buildBookMeta so the downloaded book keeps the catalog's blurb.
local OPDS_DESC_KEY = require("lib/bookshelf_opds_download").DESC_STORE_KEY

-- Is ANY OPDS network job holding Trapper right now? Trapper's progress widget
-- is module-level singleton state, so a second wrapped coroutine started under
-- a live one closes the first's InfoMessage and leaves its coroutine suspended
-- forever -- preventStandby never balanced, a device that won't sleep again
-- this session (the long note in _opdsAfterPage's busy branch has the full
-- shape). Downloads are modal-driven and never touch the _markOpdsNav gate,
-- but they DO wrap Trapper, so they answer to the same rule.
--
-- TWO markers, not one. A feed fetch owns _opds_fetch_started_at (paired with
-- _opds_fetch_feed, its identity); a modal download owns
-- _opds_download_started_at. Each side clears only its own, because they can
-- legitimately be set in either order and a shared field means whichever
-- finishes first clears the other's claim -- leaving a live coroutine
-- advertising itself as idle, which is exactly the state this test exists to
-- prevent. A download deliberately publishes NO feed identity, so
-- _opdsAfterPage reads it as "someone else is busy" and queues the user's
-- navigation rather than spending it.
--
-- 120s, and timestamps rather than booleans, for the reason the feed marker is
-- set that way in the first place: a wrapped body can't be pcall'd (Trapper
-- yields, and LuaJIT can't yield across a C-call boundary), so an error inside
-- it must expire rather than wedge the flag on for the session.
local OPDS_BUSY_WINDOW = 120

function BookshelfWidget:_opdsFetchBusy()
    local now = os.time()
    local feed = self._opds_fetch_started_at
    if feed and (now - feed) < OPDS_BUSY_WINDOW then return true end
    return self:_opdsDownloadBusy()
end

-- Just the DOWNLOAD half of the test above, for the one caller that has to be
-- narrower (_opdsRefresh: a swipe-down during a FEED fetch stays allowed). It
-- exists so that caller cannot read the marker as a bare boolean: with a plain
-- truthiness test the two readers disagree the moment the marker wedges, and
-- swipe-down refresh would stay dead for the life of the widget -- "the catalog
-- is busy" with nothing actually busy -- while everything else recovered after
-- the window. Same expiry, one constant, one rule.
function BookshelfWidget:_opdsDownloadBusy()
    local dl = self._opds_download_started_at
    return (dl ~= nil) and (os.time() - dl) < OPDS_BUSY_WINDOW
end

-- _opdsDownloadedPath(book) -> path | nil
-- The file a previous download of this record left on disk, when it is still
-- there. Statted rather than trusted: the user can delete the book in the file
-- manager and the mapping has no way to hear about it, so the mapping alone is
-- a claim and the stat is the answer. Same rule the repo's `downloaded`
-- decoration follows -- one source of truth, two readers.
function BookshelfWidget:_opdsDownloadedPath(book)
    if not (book and type(book.filepath) == "string") then return nil end
    local map = BookshelfSettings.read(OPDS_DOWNLOADS_KEY)
    local dest = (type(map) == "table") and map[book.filepath] or nil
    if type(dest) ~= "string" or dest == "" then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return nil end
    local ok_a, mode = pcall(lfs.attributes, dest, "mode")
    if ok_a and mode == "file" then return dest end
    return nil
end

-- Button label for one acquisition link. The feed's own link title wins when it
-- gave one ("EPUB (no images)" on Gutenberg) -- it is the only thing that tells
-- two same-format editions apart after the edition collapse merged them. With
-- no title, fall back to the extension the file will actually be saved with,
-- uppercased, taken from OpdsDownload.filenameFor rather than a second MIME
-- table here so the label can never disagree with the filename produced.
local function opdsAcquisitionLabel(book, acq)
    if type(acq.title) == "string" and acq.title ~= "" then return acq.title end
    local ok_d, D = pcall(require, "lib/bookshelf_opds_download")
    local name = ok_d and D.filenameFor(book, acq) or nil
    local ext = type(name) == "string" and name:match("%.([^.]+)$") or nil
    return ext and ext:upper() or nil
end

-- _buildRemoteBookHeader(book, header_w, opts) -> widget | nil
-- Cover + title + author for a remote record, optionally followed by the first
-- `opts.summary_lines` lines of the blurb. Shared by the ButtonDialog (as its
-- added widget) and the Description modal (as its header_builder), so the two
-- screens show the same book the same way.
--
-- The cover comes from the OPDS cover cache through ImageSource, whose bb is
-- CACHE-OWNED: image_disposable stays false and the widget never hands the bb
-- back as _owned_cover_bb (which ReviewsModal frees at close) -- freeing a
-- shared cache bb is the corruption the OPDS cover path was rebuilt to avoid.
function BookshelfWidget:_buildRemoteBookHeader(book, header_w, opts)
    opts = opts or {}
    if not book or type(header_w) ~= "number" or header_w <= 0 then return nil end
    local ImageWidget    = require("ui/widget/imagewidget")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan   = require("ui/widget/verticalspan")

    -- Cover box, capped so it can't crowd the text column on a narrow screen.
    local thumb_w = math.min(Screen:scaleBySize(110), math.floor(header_w * 0.35))
    local thumb_h = math.floor(thumb_w * 1.5)
    local gap_w   = self:_bookGap(math.min(
        math.floor(Size.padding.fullscreen * 2 * 0.8),
        math.floor(Screen:getWidth() * 0.03)))

    -- Whatever is on disk right now: the repo attaches cover_image_path to the
    -- page record, but a re-show after the on-open fetch (below) is handed the
    -- same record the repo built BEFORE the file landed, so ask the cache too.
    local cover_path = book.cover_image_path
    if not cover_path then
        local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
        if ok_c then
            local ok_p, p = pcall(OpdsCovers.cachedPath, book)
            cover_path = ok_p and p or nil
        end
    end
    local cover_bb
    if cover_path then
        local ok_img, ImageSource = pcall(require, "lib/bookshelf_image_source")
        cover_bb = ok_img and ImageSource.loadImageNative(cover_path) or nil
    end

    local thumb
    if cover_bb then
        -- True aspect from the bb itself, so a non-2:3 cover isn't letterboxed
        -- or stretched (same derivation as the book menu header).
        local bw = cover_bb.w or (cover_bb.getWidth and cover_bb:getWidth())
        local bh = cover_bb.h or (cover_bb.getHeight and cover_bb:getHeight())
        if bw and bh and bw > 0 then thumb_h = math.floor(thumb_w * (bh / bw)) end
        thumb = FrameContainer:new{
            bordersize = Size.border.thin, padding = 0, margin = 0,
            ImageWidget:new{
                image            = cover_bb,
                image_disposable = false,   -- ImageSource's cache owns it
                width            = thumb_w,
                height           = thumb_h,
                scale_factor     = 0,
            },
        }
    else
        -- Placeholder: an empty bordered box with a centred book glyph, so the
        -- header keeps its shape while the cover is still on its way (or the
        -- feed never offered one). A Private-Use-Area codepoint from the
        -- bundled Nerd Font -- the only range that renders safely here.
        thumb = FrameContainer:new{
            bordersize = Size.border.thin, padding = 0, margin = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = thumb_w, h = thumb_h },
                TextWidget:new{
                    text = "\xEF\x80\xAD",   -- U+F02D, nf-fa-book
                    face = BFont:getFace("symbols", 28),
                },
            },
        }
    end

    -- Text column. max_width/width must stay positive (a zero-width TextWidget
    -- is a crash, not a clip), so floor it rather than trusting the arithmetic.
    local text_w = math.max(Screen:scaleBySize(60),
        header_w - thumb_w - 2 * Size.border.thin - gap_w)
    local stack = VerticalGroup:new{ align = "left" }
    local t_face, t_bold = BFont:getFace("smalltfont", 22, { bold = true })
    stack[#stack + 1] = TextBoxWidget:new{
        text  = book.display_title or book.title or _("(no title)"),
        face  = t_face,
        bold  = t_bold,
        width = text_w,
    }
    if type(book.author) == "string" and book.author ~= "" then
        local a_face, a_bold = BFont:getFace("cfont", 18)
        stack[#stack + 1] = VerticalSpan:new{ width = Size.padding.small }
        stack[#stack + 1] = TextBoxWidget:new{
            text = book.author, face = a_face, bold = a_bold, width = text_w,
        }
    end

    local group = VerticalGroup:new{ align = "left",
        HorizontalGroup:new{ align = "top",
            thumb, HorizontalSpan:new{ width = gap_w }, stack },
    }

    -- Blurb preview. Plain text via the shared cleanDescription (feed summaries
    -- are usually HTML), capped to a fixed line count: the dialog's added
    -- widget sits OUTSIDE its scrollable button area, so an uncapped blurb
    -- would push the buttons off screen. height + height_adjust +
    -- height_overflow_show_ellipsis gives "at most N lines, shrink to fit,
    -- ellipsis when there's more" in one widget; the rest is behind
    -- Description.
    local max_lines = tonumber(opts.summary_lines) or 0
    local raw = book.opds and book.opds.summary
    if max_lines > 0 and type(raw) == "string" and raw ~= "" then
        local ok_tok, Tokens = pcall(require, "lib/bookshelf_tokens")
        local text = ok_tok and Tokens.cleanDescription(raw) or nil
        if type(text) == "string" and text ~= "" then
            local s_face, s_bold = BFont:getFace("cfont", 16)
            -- Throwaway probe purely to read the face's line height. Freed
            -- straight after: it shapes a real text run, and a book modal gets
            -- opened many times over a browsing session.
            local probe = TextBoxWidget:new{ text = "Ag", face = s_face, width = header_w }
            local line_h = probe.line_height_px or Screen:scaleBySize(20)
            probe:free()
            group[#group + 1] = VerticalSpan:new{ width = Screen:scaleBySize(10) }
            group[#group + 1] = TextBoxWidget:new{
                text   = text,
                face   = s_face,
                bold   = s_bold,
                width  = header_w,
                height = line_h * max_lines,
                height_adjust                 = true,
                height_overflow_show_ellipsis = true,
            }
        end
    end
    -- Nothing in here is interactive, and ButtonDialog puts every added widget
    -- into its dpad focus layout unless told otherwise -- without this, arrow
    -- navigation gets a dead row above the buttons that swallows a press.
    group.not_focusable = true
    return group
end

-- ReviewsModal args for a remote record's blurb, or nil when it has none.
-- _descriptionArgs is written against a Book's own description fields; a feed
-- record keeps its blurb under opds.summary instead, so hand the helper a
-- shallow stand-in rather than duplicating what it does -- sanitised markup for
-- an HTML blurb, paragraph-preserving escaping for a plain-text one, which is
-- exactly the pair of shapes OPDS summaries arrive in.
function BookshelfWidget:_remoteDescriptionArgs(book)
    local raw = book and book.opds and book.opds.summary
    if type(raw) ~= "string" or raw == "" then return nil end
    return self:_descriptionArgs{
        title = book.title, author = book.author, description = raw,
    }
end

-- opts.no_cover_fetch: set on the ONE re-show the on-open cover fetch triggers,
-- so the reopened dialog can't start another (and can't loop against a server
-- that answers with something undecodable).
function BookshelfWidget:_showRemoteBookInfo(book, opts)
    opts = opts or {}
    if not book then return end
    local _perf_t0 = _gettime()
    local ButtonDialog = require("ui/widget/buttondialog")
    local acquisitions = (book.opds and type(book.opds.acquisitions) == "table")
        and book.opds.acquisitions or {}

    -- Runtime format filter. bookshelf_opds_feed's SUPPORTED_TYPE stays the
    -- parse-time filter it already is (what's worth keeping in the window);
    -- this is the narrower "can THIS build actually open it" question, which
    -- only DocumentRegistry can answer -- djvu, for instance, is in the feed
    -- map but needs a provider that not every build ships.
    local usable = {}
    local ok_reg, DocumentRegistry = pcall(require, "document/documentregistry")
    for _i, acq in ipairs(acquisitions) do
        if type(acq) == "table" and type(acq.href) == "string" and acq.href ~= "" then
            local ok_p, has = pcall(function()
                return ok_reg and DocumentRegistry:hasProvider(nil, acq.type)
            end)
            if ok_p and has then usable[#usable + 1] = acq end
        end
    end

    local dialog
    local buttons = {}

    -- Already downloaded (and still on disk): read it instead of fetching it
    -- again. The download rows stay below -- a re-download is how the user
    -- replaces a truncated or wrong-format copy.
    local have = self:_opdsDownloadedPath(book)
    if have then
        buttons[#buttons + 1] = { {
            text = _("Open"),
            callback = function()
                UIManager:close(dialog)
                self:_launchReader(have)
            end,
        } }
    end

    -- Ranked order, with the best-for-KOReader format called out. The ranking
    -- is pure and lives in OpdsDownload so it can be tested without a UI; here
    -- it only decides button order and, when the pick is unambiguous, splits
    -- the rows under "Recommended" / "Alternatives" headings (the download
    -- equivalent of the library edit tab's sections) rather than tagging one
    -- label.
    local ok_rank, OpdsDownload = pcall(require, "lib/bookshelf_opds_download")
    local ordered, rec_idx = usable, nil
    if ok_rank and OpdsDownload.rankAcquisitions then
        ordered, rec_idx = OpdsDownload.rankAcquisitions(usable)
    end
    -- A disabled, centred, bold row reads as a section heading in a
    -- ButtonDialog (it can't take focus or a tap).
    local function headingRow(label)
        return { { text = label, enabled = false,
                   align = "center", text_font_bold = true } }
    end
    local function downloadRow(acq)
        local label = opdsAcquisitionLabel(book, acq)
        local text = label and T(_("Download %1"), label) or _("Download")
        return { { text = text,
                   callback = function() self:_opdsStartDownload(book, acq, dialog) end } }
    end
    if rec_idx and ordered[rec_idx] and #ordered >= 2 then
        -- Confident pick with at least one other format: headed sections.
        buttons[#buttons + 1] = headingRow(_("Recommended"))
        buttons[#buttons + 1] = downloadRow(ordered[rec_idx])
        buttons[#buttons + 1] = headingRow(_("Alternatives"))
        for _i, acq in ipairs(ordered) do
            if _i ~= rec_idx then buttons[#buttons + 1] = downloadRow(acq) end
        end
    else
        -- One format, or no confident pick: a plain list, no headings.
        for _i, acq in ipairs(ordered) do
            buttons[#buttons + 1] = downloadRow(acq)
        end
    end
    if #usable == 0 then
        -- Note row in the established disabled-button style: the record is real
        -- and its blurb is worth reading, there is just nothing here this
        -- device can open.
        buttons[#buttons + 1] = { {
            text = _("No formats this device can open"), enabled = false,
        } }
    end

    local desc_args = self:_remoteDescriptionArgs(book)
    local last_row = {}
    if desc_args then
        last_row[#last_row + 1] = {
            text = _("Description"),
            callback = function()
                UIManager:close(dialog)
                desc_args.bw = self
                desc_args.header_builder = function(avail_w)
                    return self:_buildRemoteBookHeader(book, avail_w, { summary_lines = 0 })
                end
                UIManager:show(require("lib/bookshelf_reviews_modal"):new(desc_args))
            end,
        }
    end
    last_row[#last_row + 1] = {
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    }
    buttons[#buttons + 1] = last_row

    dialog = ButtonDialog:new{ buttons = buttons }
    -- addWidget BEFORE show: it reinits the dialog, and reinit on a dialog that
    -- is already up rebuilds self.movable with its default drag/hold gestures
    -- (which then eat taps and wedge the touch state machine, with no
    -- traceback). Built-then-shown, that hazard doesn't exist.
    local header = self:_buildRemoteBookHeader(
        book, dialog:getAddedWidgetAvailableWidth(), { summary_lines = 5 })
    if header then dialog:addWidget(header) end
    logger.dbg(string.format(
        "[bookshelf perf] _showRemoteBookInfo: build=%.0fms %s",
        (_gettime() - _perf_t0) * 1000, tostring(book.title or book.filepath)))
    UIManager:show(dialog)

    if not opts.no_cover_fetch then
        self:_opdsFetchDetailCover(book, dialog)
    end
end

-- Fetch one remote book's cover into the disk cache, off the tap path.
-- Shared by the download modal (re-shows itself with the cover) and the hero
-- preview (repaints hero + shelf cell). opts.pre: extra liveness the caller
-- needs (e.g. "the dialog is still shown"), checked after the defer and again
-- when the fetch lands. opts.on_cached: runs when the cover file is on disk -
-- whether THIS fetch downloaded it or a concurrent pass cached it first.
function BookshelfWidget:_opdsFetchCover(book, opts)
    opts = opts or {}
    if not (book and book.opds) then return end
    local ok_c, OpdsCovers = pcall(require, "lib/bookshelf_opds_covers")
    if not ok_c then return end
    -- Match the SHELF's own cover pass exactly: it fetches via image_url OR
    -- thumbnail_url (OpdsCovers.cachePath / fetchMissing both key on
    -- coverUrl = image_url or thumbnail_url). Gating this modal fetch on
    -- image_url alone left a folder-of-one whose child carries only a
    -- thumbnail with a loaded cover on the shelf cell but a permanent
    -- book-glyph placeholder in the modal: a normal book tap hides the gap
    -- because the grid pass had already fetched and attached its cover before
    -- the tap, but the lone-child modal opens straight off the feed fetch,
    -- before any grid pass has run for that record, so it depends entirely on
    -- this fetch -- which then silently bailed. cachePath is non-nil exactly
    -- when there is a cover URL to fetch, and nil when there is none.
    -- One decision line per call: which guard ended it, or that a fetch is
    -- being scheduled. This is the "why did no toast appear" diagnostic.
    local function _bail(reason)
        logger.dbg("[bookshelf perf] _opdsFetchCover: skip (" .. reason .. ")",
            tostring(book.title or book.filepath))
    end
    if not OpdsCovers.cachePath(book) then _bail("no cover url") return end
    if OpdsCovers.cachedPath(book) then _bail("already cached") return end
    -- A feed fetch in flight is suspended at a Trapper yield with the main loop
    -- free, so a blocking image download scheduled underneath it would stall
    -- that fetch for as long as the image takes. Skip; the grid's own cover
    -- pass picks this record up on the next render anyway.
    if self:_opdsFetchBusy() then _bail("feed fetch busy") return end
    -- Never prompts: a passive-looking cover fill must not raise a Wi-Fi
    -- dialog (isConnected answers true on platforms with no Wi-Fi toggle, so
    -- desktop builds still fill).
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and NetworkMgr.isConnected
            and not NetworkMgr:isConnected() then
        _bail("offline")
        return
    end
    local _perf_t_sched = _gettime()
    logger.dbg("[bookshelf perf] _opdsFetchCover: scheduling fetch"
        .. (opts.notice and " (with toast)" or ""),
        tostring(book.title or book.filepath))
    -- Feedback while the (blocking) download runs. Shown only once every
    -- synchronous guard has passed -- i.e. a fetch really is about to start --
    -- so a tap on an already-cached cover never flashes it. The 0.1s defer
    -- below is what lets it paint before fetchMissing freezes the loop. The
    -- timeout is a backstop; every exit below dismisses it explicitly.
    local notice
    if opts.notice then
        notice = require("ui/widget/notification"):new{
            text = opts.notice, timeout = 30,
        }
        UIManager:show(notice)
    end
    local function dismiss_notice()
        if notice then
            if UIManager:isWidgetShown(notice) then UIManager:close(notice) end
            notice = nil
        end
    end
    UIManager:scheduleIn(0.1, function()
        if BookshelfWidget.live ~= self then dismiss_notice() return end
        if opts.pre and not opts.pre() then dismiss_notice() return end
        -- fetchMissing blocks the main loop (10s worst case); one at a time.
        -- Queued schedule callbacks that fire while another fetch is mid-air
        -- bail here and rely on their next preview/modal open to retry.
        if self._opds_cover_fetch_busy then dismiss_notice() return end
        self._opds_cover_fetch_busy = true
        -- Paint BEFORE blocking. This callback is usually overdue by the time
        -- the tap handler's (heavy) rebuild returns, and UIManager runs due
        -- tasks before it repaints -- so without this the toast, the new hero
        -- and the selection ring all sat dirty-but-unpainted behind the old
        -- frame for the whole download (8s+ against a slow cover server, and
        -- the toast was then dismissed on completion without ever being
        -- seen). Same primitive Trapper:info uses for exactly this reason.
        UIManager:forceRePaint()
        local _perf_t_fetch = _gettime()
        logger.dbg(string.format(
            "[bookshelf perf] _opdsFetchCover: fetch start, sched_gap=%.0fms",
            (_perf_t_fetch - _perf_t_sched) * 1000))
        OpdsCovers.fetchMissing({ book }, function(fetched)
            self._opds_cover_fetch_busy = nil
            -- The fetch is over either way; the toast must not outlive it.
            dismiss_notice()
            logger.dbg(string.format(
                "[bookshelf perf] _opdsFetchCover: fetch done in %.0fms"
                .. " fetched=%s cached_now=%s",
                (_gettime() - _perf_t_fetch) * 1000,
                tostring(fetched),
                tostring(OpdsCovers.cachedPath(book) ~= nil)))
            if BookshelfWidget.live ~= self then return end
            if opts.pre and not opts.pre() then return end
            -- Cached NOW is the question, not whether THIS fetch downloaded
            -- it: a concurrent pass often lands the same cover first.
            if not OpdsCovers.cachedPath(book) then return end
            if opts.on_cached then opts.on_cached() end
        end)
    end)
end

-- The download modal's cover fetch: re-show the dialog once the cover is on
-- disk.
function BookshelfWidget:_opdsFetchDetailCover(book, dialog)
    self:_opdsFetchCover(book, {
        pre = function() return UIManager:isWidgetShown(dialog) end,
        on_cached = function()
            -- Discard the tap backlog before the geometry moves under it.
            -- fetchMissing is fully blocking (a synchronous download loop with
            -- a 10s total budget), so the main loop can be frozen with the
            -- modal on screen for seconds, and every tap the user made in that
            -- window is still queued. The re-shown dialog is a DIFFERENT
            -- height -- thumb_h switches from the 1.5 placeholder ratio to the
            -- cover's true aspect -- so those taps land on rows that have
            -- moved, and the rows they can land on include "Download <format>":
            -- an unrequested network transfer, not just a stray dismissal.
            -- Same primitive, and the same reason, as the Read-now ConfirmBox's
            -- flush_events_on_show (which is literally this one call).
            local Input = Device.input
            if Input and Input.inhibitInputUntil then
                Input:inhibitInputUntil(true)
            end
            -- Rebuild rather than patch: the cover is baked into the added
            -- header widget, and reinit on a shown ButtonDialog is the movable
            -- hazard noted above. Close and re-show with the fetch disarmed.
            UIManager:close(dialog)
            self:_showRemoteBookInfo(book, { no_cover_fetch = true })
        end,
    })
end

-- Pre-flight for one download: refuse politely when we can't do it, confirm an
-- overwrite, then hand off. Everything here is local (a settings read and one
-- stat); the network half is _opdsRunDownload.
function BookshelfWidget:_opdsStartDownload(book, acq, dialog)
    local Notification = require("ui/widget/notification")
    local D = require("lib/bookshelf_opds_download")
    if self:_opdsFetchBusy() then
        UIManager:show(Notification:new{
            text = _("The catalog is busy. Try again in a moment."),
        })
        return
    end
    -- nil means home_dir is unset: there is no folder the shelf actually scans,
    -- so a download would land somewhere the user would never see it. Name the
    -- problem rather than inventing a destination.
    -- Per-chip download folder (issue #319): read from the chip this book came
    -- from, NOT from _opdsEffectiveTab - that synthesises a bare tab while
    -- drilled into a nav feed, which carries no user settings. The originating
    -- chip is self.chip either way, so resolve the stored record by id and use
    -- its folder when it is an OPDS chip.
    local chip_dir
    do
        local ok_tm, TabModel = pcall(require, "lib/bookshelf_tab_model")
        local tab = ok_tm and TabModel.getById and TabModel.getById(self.chip)
        if tab and tab.source and tab.source.kind == "opds" then
            chip_dir = tab.download_dir
        end
    end
    local dir = D.destinationDir(function(key)
        return G_reader_settings:readSetting(key)
    end, chip_dir)
    if not dir then
        UIManager:show(Notification:new{
            text = _("Set a home folder in KOReader before downloading books."),
        })
        return
    end
    local util = require("util")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local function is_file(p)
        if not ok_lfs then return false end
        local ok_a, mode = pcall(lfs.attributes, p, "mode")
        return ok_a and mode == "file"
    end
    local map = BookshelfSettings.read(OPDS_DOWNLOADS_KEY)
    -- A record we have downloaded before keeps the name its file already has.
    -- filenameFor's output changed when the #336 author prefix landed, so
    -- deriving a fresh name here would hand an already-downloaded book a NEW
    -- path: no overwrite prompt, and two copies on disk. mappedDest is nil for
    -- anything we have no live file for, which is every first download.
    local dest = D.mappedDest(map, book.filepath, is_file, dir)
    local name
    if dest then
        name = dest:match("([^/]+)$")
    else
        name = util.getSafeFilename(D.filenameFor(book, acq), dir)
        dest = (dir ~= "/" and dir or "") .. "/" .. name
        -- Don't offer to overwrite a file that belongs to a DIFFERENT catalog
        -- record: filenameFor is author + title + format and getSafeFilename
        -- doesn't uniquify, so two records carrying the same book land on one
        -- path, and overwriting would leave both opds_downloads keys pointing at
        -- it -- one record's Open row then launches the other's book. claimDest
        -- hands back a suffixed sibling in that case and the original path in
        -- every other, including this record re-downloading its own file (which
        -- is what the overwrite prompt below is actually for).
        dest = D.claimDest(dest, map, book.filepath, acq)
        name = dest:match("([^/]+)$") or name
    end
    local function go() self:_opdsRunDownload(book, acq, dest, dialog) end

    if is_file(dest) then
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = T(_("%1 already exists. Download it again?"), name),
            ok_text = _("Overwrite"),
            ok_callback = go,
        })
        return
    end
    go()
end

-- The network half. Wi-Fi is gated by runWhenOnline (a prompt, never a silent
-- connect); the transfer itself runs inside Trapper so the progress line is a
-- real widget rather than a frozen screen.
--
-- Credentials only ever travel to the catalog's own origin. The acquisition
-- href came out of the server's own XML and could name any host, so the
-- same-origin test is this layer's job -- OpdsDownload.download sends whatever
-- it is handed, by design (see its header), exactly as the cover fetcher's
-- credential gate works.
function BookshelfWidget:_opdsRunDownload(book, acq, dest, dialog)
    local D            = require("lib/bookshelf_opds_download")
    local OpdsSource   = require("lib/bookshelf_opds_source")
    local OpdsFeed     = require("lib/bookshelf_opds_feed")
    local CoverFetch   = require("lib/bookshelf_cover_fetch")
    local Notification = require("ui/widget/notification")
    local Trapper      = require("ui/trapper")

    local key = type(book.filepath) == "string"
        and book.filepath:match("^OPDS://([^/]+)/") or nil
    local server = key and OpdsSource.getServer(key) or nil
    local same_origin = (server and OpdsFeed.sameOrigin(server.url, acq.href)) or false
    local user     = same_origin and server.username or nil
    local password = same_origin and server.password or nil
    local title    = book.display_title or book.title or ""
    local who      = (server and server.title) or title

    CoverFetch.runWhenOnline(function()
        -- The Wi-Fi prompt is modal and can be answered long after the shelf
        -- closed (or was replaced by a re-open). Same liveness test every other
        -- deferred OPDS path makes.
        if BookshelfWidget.live ~= self then return end
        Trapper:wrap(function()
            -- Re-test, FIRST, inside the wrap. The tap-time check in
            -- _opdsStartDownload is a snapshot taken before two waits that can
            -- run for as long as the user likes: the overwrite ConfirmBox, and
            -- runWhenOnline's Wi-Fi prompt. A feed fetch can be armed or can
            -- reach its own Trapper:wrap during either -- and while a feed
            -- fetch is itself sitting in runWhenOnline it holds NO marker yet,
            -- so the earlier check could not have seen it. Bail with the same
            -- message the tap-time refusal uses; the user retries in a moment.
            if self:_opdsFetchBusy() then
                UIManager:show(Notification:new{
                    text = _("The catalog is busy. Try again in a moment."),
                })
                return
            end
            -- Our OWN marker for the transfer (never the feed's -- see
            -- _opdsFetchBusy): it is what stops a feed fetch (page turn, chip
            -- tap) starting a second wrapped coroutine underneath this one,
            -- and it carries no feed identity, so _opdsAfterPage reads it as
            -- "someone else is busy" and QUEUES the user's navigation rather
            -- than spending it.
            self._opds_download_started_at = os.time()
            local go_on = Trapper:info(T(_("Downloading %1…"), title))
            local path, err, extra
            if go_on then
                path, err, extra = D.download(acq.href, dest, user, password)
            end
            Trapper:clear()
            self._opds_download_started_at = nil
            if not go_on then return end   -- dismissed before the transfer began

            if not path then
                -- Once, before the branching, so every failure shape is
                -- represented: the three toasts below name the server but not
                -- the cause, and a download that dies on a 504 halfway through
                -- a catalog looks identical to one that never resolved. `extra`
                -- carries the redirect target on the downgrade branch and is
                -- nil elsewhere, so it rides along only when it says something.
                logger.dbg("[bookshelf] opds fetch failed:", acq.href, err, extra)
                if err == "downgrade" then
                    -- Warning-style (an InfoMessage with the notice icon, not a
                    -- toast): this is the one failure the user should be able
                    -- to act on, by telling the catalog's administrator.
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = T(_("Insecure redirect refused.\n\nThe server tried to send this download to a non-HTTPS address:\n\n%1\n\nMany apps refuse this because it could be a downgrade attack."),
                            tostring(extra or "")),
                        icon = "notice-warning",
                    })
                elseif err == "auth" then
                    UIManager:show(Notification:new{
                        text = T(_("Authentication failed for %1"), who),
                    })
                else
                    UIManager:show(Notification:new{
                        text = T(_("Couldn't reach %1"), who),
                    })
                end
                return
            end

            -- Landed. Record it before anything else can fail: the mapping is
            -- what the repo's downloaded decoration reads, and a file on disk
            -- the shelf doesn't know about is the worse of the two failures.
            local map = BookshelfSettings.read(OPDS_DOWNLOADS_KEY)
            if type(map) ~= "table" then map = {} end
            -- Retire entries whose file is gone, at the one moment we are
            -- already paying for a write. Nothing else ever removes one: the
            -- mapping deliberately gets no bookkeeping pass on move or delete
            -- (see the repo's downloaded comment), so without this it grows for
            -- the life of the install, and a dead value still counts as "taken"
            -- in claimDest's scan -- giving an unrelated record a spurious
            -- "(a1b2c3d4)" in its filename. One stat per entry, at an action
            -- boundary, and BEFORE the new entry goes in so this download's own
            -- destination is never a candidate.
            local ok_lfs2, lfs2 = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs2 and lfs2 then
                D.pruneMap(map, function(p)
                    local ok_s, m = pcall(lfs2.attributes, p, "mode")
                    return ok_s and m == "file"
                end)
            end
            map[book.filepath] = path
            -- No explicit flush: Store.save already flushes (it ends in
            -- s:flush()), and a second call here bought a full re-serialise of
            -- the settings file per download for nothing. The action boundary
            -- is honoured -- just not twice.
            BookshelfSettings.save(OPDS_DOWNLOADS_KEY, map)

            -- Carry the catalog's description onto the downloaded file so the
            -- local library shows it too. Gutenberg's embedded EPUB
            -- description is routinely empty, so without this the book loses
            -- the blurb the moment it lands. Keyed by the on-disk path (read
            -- back in Repo.buildBookMeta); pruned with the same file-exists
            -- predicate as the downloads map so a deleted/replaced file leaves
            -- no dangling text. book.opds.summary is already just the Summary
            -- section (OpdsFeed.summaryText strips Gutenberg's other headings).
            local desc = book.description
                         or (book.opds and book.opds.summary) or nil
            if type(desc) == "string" and desc ~= "" then
                local dmap = BookshelfSettings.read(OPDS_DESC_KEY)
                if type(dmap) ~= "table" then dmap = {} end
                if ok_lfs2 and lfs2 then
                    D.pruneMap(dmap, function(p)
                        local ok_s, m = pcall(lfs2.attributes, p, "mode")
                        return ok_s and m == "file"
                    end)
                end
                dmap[path] = desc
                BookshelfSettings.save(OPDS_DESC_KEY, dmap)
            end
            -- A new file inside the library the shelf walks -- the local chips
            -- have to re-derive or the book simply isn't there.
            Repo.invalidateWalkCache()

            -- Shown-check first: the user can dismiss the dialog while the
            -- transfer runs, and closing an already-closed widget re-sends it
            -- CloseWidget (a second repaint of a rect nothing occupies).
            if dialog and UIManager:isWidgetShown(dialog) then
                UIManager:close(dialog)
            end

            -- Re-render the shelf HERE, on the transfer landing, rather than
            -- from one of the two answers below.
            --
            -- The page records under this prompt were built by the repo BEFORE
            -- the download, so the catalog cell still carries no `downloaded`
            -- flag (no tick), and the local chips have never seen the new file.
            -- Only a re-fetch fixes that, and it has to happen on EVERY way out
            -- of this prompt, not one of them:
            --
            --   * "Not now" used to own the refresh, and looked fine.
            --   * "Read" parks the shelf and hands the screen to ReaderUI. The
            --     way back is main.lua's _raiseInPlace, which reorders the
            --     window stack and repaints the widget it finds there -- it
            --     never re-fetches. So the shelf the user returns to is the one
            --     rendered before the download: the book they just read shows
            --     no downloaded tick, for the rest of the visit. It reappears
            --     later only by accident, on the next unrelated rebuild (the
            --     sideload file poll noticing the new file, a page turn, a chip
            --     tap), which reads as a tick that comes and goes.
            --
            -- Hoisting it also means one rebuild per download instead of one
            -- per download plus one per dismissal.
            --
            -- Same liveness guard the ok_callback below makes: with the shelf
            -- closed (or replaced by a re-open) mid-transfer, this would be
            -- rebuilding a dead widget.
            if BookshelfWidget.live == self then
                self:_rebuild()
                UIManager:setDirty(self, "ui")
            end

            UIManager:show(require("ui/widget/confirmbox"):new{
                text        = T(_("%1 downloaded. Read it now?"), title),
                ok_text     = _("Read"),
                -- Liveness guard: with the shelf gone (closed, or replaced by a
                -- re-open), _launchReader would be stamping pre-read state onto
                -- a dead widget.
                ok_callback = function()
                    if BookshelfWidget.live ~= self then return end
                    self:_launchReader(path)
                end,
                cancel_text = _("Not now"),
                -- The transfer blocked the main loop, so every tap the user
                -- made while waiting is still queued and would land on this box
                -- the moment it appears -- answering a question they have not
                -- read yet. confirmbox.lua documents this exact case as what
                -- the flag is for (Input:inhibitInputUntil on show).
                flush_events_on_show = true,
                -- No cancel_callback: the refresh it used to carry now runs
                -- above, before this box is shown, so every dismissal (Cancel,
                -- Read, or a tap outside the box) already has a current shelf
                -- underneath it.
            })
        end)
    end)
end

-- _browseFiles()  — close home screen, open FileManager.
function BookshelfWidget:_browseFiles()
    -- Hot parking: with a reader parked underneath, spawning a
    -- FileManager while ReaderUI is still alive would leave two hosts
    -- running (the state KOReader's doShowReader explicitly prevents).
    -- Real-close the parked book out to the file manager instead.
    local Park = require("lib/bookshelf_reader_park")
    if Park.closeShelfToFileManager(self) then return end
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
            -- Embedded cover: load the FULL-resolution cover straight from the
            -- document, exactly like KOReader's native Book information > Cover
            -- image (filemanagerbookinfo:getCoverImage, which also picks up a
            -- DocSettings custom cover). The BIM cover_bb used as the fallback
            -- below is a grid-sized THUMBNAIL -- feeding it to ImageViewer
            -- upscales blurry, even at "original size" (#228). Guarded with a
            -- pcall + the thumbnail fallback so an older build still shows
            -- something.
            local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
            if ok_bi and BookInfo and BookInfo.getCoverImage then
                local ok_bb, full_bb = pcall(function()
                    return BookInfo:getCoverImage(nil, fp, false)
                end)
                if ok_bb and full_bb then
                    UIManager:show(require("ui/widget/imageviewer"):new{
                        image            = full_bb,
                        image_disposable = true,  -- getCoverPageImage bb is ours
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
        -- CenterContainer below centers on the glyph's full reported em-box,
        -- but this Nerd Font's calendar/file glyphs still sit visibly lower
        -- within that box than meta_face's own ink does within its box (measured
        -- ~4px low on a PW5) -- nudge the paint position up to compensate.
        -- getSize() is untouched, so the gap/width math below (which reads it)
        -- doesn't shift.
        local icon_nudge_up = Screen:scaleBySize(2)
        local orig_icon_paintTo = icon.paintTo
        function icon:paintTo(bb, x, y)
            orig_icon_paintTo(self, bb, x, y - icon_nudge_up)
        end
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
    -- Expose the cover thumb frame (stamps its painted dimen) so the detail
    -- popup can flex it open as tap feedback on its Open button.
    result._cover_thumb = thumb_widget and thumb_widget[1] or nil
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
    --
    -- CHIP_KEY, explicitly: this control follows the chip strip and always
    -- did. List rows are on their own key now, and a copy of the arithmetic
    -- here would have made that impossible to see.
    local size  = BandMetrics.fontSize(BandMetrics.CHIP_KEY)
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
    -- A bit more than Size.padding.default: at default gave the label so
    -- little breathing room against the border it read as cramped.
    local pill_pad_h = Screen:scaleBySize(8)
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
    -- The hero's star row is reachable while a remote record is previewed.
    -- DocSettings:open + flush on an OPDS:// pseudo-path would CREATE a
    -- sidecar directory for a book that doesn't exist on this device.
    if self:_isRemoteRecord(book) then return end
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
            return "ui", old_dimen, self.dithered
        end
        return "ui", nil, self.dithered
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

-- _showFetchProgress(text) - the OPDS walk's progress line, sat just above the
-- footer rather than in the middle of the shelf.
--
-- Trapper:info centres its InfoMessage on the screen, which for a message that
-- stays up for the length of a multi-page walk means covering the books the
-- reader is waiting to see. There is no positioning option, so this builds the
-- same widget and swaps its outer container: InfoMessage assigns self[1] once
-- and never reads it back by name (only as [1][1].dimen, which a BottomContainer
-- answers exactly as a CenterContainer does), so the swap is a placement change
-- and nothing else.
--
-- It is still registered as Trapper.current_widget, which is what makes this
-- safe to drop in: every existing Trapper:clear() closes it, Trapper:confirm
-- replaces it, and dismissableRunInSubprocess traps on it, all unchanged.
--
-- The lift is the footer plus the shelf's own book gap, so the message sits off
-- the footer by the same distance books sit from each other.
function BookshelfWidget:_showFetchProgress(text)
    local InfoMessage     = require("ui/widget/infomessage")
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local Trapper         = require("ui/trapper")
    if Trapper.current_widget then
        UIManager:close(Trapper.current_widget)
        Trapper.current_widget = nil
    end
    local msg = InfoMessage:new{
        text = text,
        -- Trapper's own marker for "an InfoMessage I put up", so its
        -- fast_refresh and dismissal bookkeeping recognise this one as theirs.
        is_infomessage = true,
        -- Discards the tap that asked for the fetch, so it cannot immediately
        -- dismiss the message announcing it. Same guard the stock path uses.
        flush_events_on_show = true,
    }
    local d    = self._shelf_dims or {}
    local lift = (d.FOOTER_H or 0) + (d.FOOTER_BOTTOM_MARGIN or 0)
                 + (d.book_gap or Size.padding.large)
    msg[1] = BottomContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(),
                          h = math.max(1, Screen:getHeight() - lift) },
        msg.movable,
    }
    Trapper.current_widget = msg
    UIManager:show(msg)
    UIManager:forceRePaint()
    return true
end

-- _markTapped(fp) - draw the selection border on a tile NOW, before starting
-- work that will take a moment.
--
-- Tapping a category can sit for a second or two while a feed is fetched and
-- the new view is built, with nothing on screen acknowledging the tap, so it
-- reads as a tap that missed. Books already get this feedback on their
-- open-double gesture; folders and OPDS navigation tiles never did.
--
-- forceRePaint is the whole point. setDirty only queues, and the caller's work
-- runs before UIManager next paints - so the border would appear at the same
-- instant as the view it was supposed to precede, which is no feedback at all.
function BookshelfWidget:_markTapped(fp)
    if not fp or self._tap_selected_fp == fp then return end
    self._tap_selected_fp = fp
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    UIManager:forceRePaint()
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
    -- height). Re-decide it against dimen.w itself, not the narrower _crop_w:
    -- callers (section heading bars, pill-row frames) build their backgrounds
    -- to fill dimen.w exactly, with the scrollbar meant to overlay their
    -- trailing edge rather than reserve extra width beyond it -- so content
    -- flush with dimen.w is "fits", not overflow. Comparing to _crop_w here
    -- flagged that flush fill as a permanent scroll_bar_width of bogus
    -- horizontal overflow on any tab tall enough to need vertical scrolling
    -- (invisible on short tabs, since _is_scrollable is false there).
    local content_w = self[1]:getSize().w
    self._max_scroll_offset_x = math.max(0, content_w - self.dimen.w)
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

-- Used by the Edit tab's infoRow (Hardcover row): a pre-built button,
-- centred in a cell row_h tall.
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
    local border_w = want_bottom_border and Size.line.medium or 0
    local cell_h = row_h - border_w
    local btn_cell = CenterContainer:new{
        dimen = Geom:new{ w = box_w, h = cell_h }, btn }
    if not want_bottom_border then return btn_cell end
    return VerticalGroup:new{ align = "left", btn_cell,
        LineWidget:new{ background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = box_w, h = border_w } } }
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
        -- Book info needs a live FileManager: its bookinfo module carries
        -- the `ui` context getDocProps reads (self.ui.coverbrowser). While a
        -- reader is parked there is no FileManager, so finish the park first
        -- (close the book, FM reborn under the shelf) then show -- same move
        -- as the menu tap. A bare FileManagerBookInfo:new{} has no ui and
        -- crashes in getDocProps.
        require("lib/bookshelf_reader_park").runInFileManager(function(fm)
            fm = fm or require("apps/filemanager/filemanager").instance
            if fm and fm.bookinfo then
                fm.bookinfo:show(book.filepath)
            else
                -- Last resort (no FM at all -- shouldn't happen once the park
                -- has finished): a stub ui keeps getDocProps from indexing
                -- nil, so at least the info opens rather than crashing.
                require("apps/filemanager/filemanagerbookinfo"):new{ ui = {} }:show(book.filepath)
            end
        end)
    end }

    -- Favourite toggle keys off the default collection (Collections membership
    -- itself is shown/edited on the Tags tab, not here).
    local default_coll = ReadCollection.default_collection_name

    -- ── Reading status quad ──────────────────────────────────────────────────
    -- Selected state reads as a light-gray fill rather than an appended
    -- checkmark: a checkmark changes the label's own width every time a
    -- different status is picked, which visibly shifts the row's layout
    -- (Button's own text repositions, and its neighbours can reflow at
    -- narrow zoom levels). A fixed-width background swap has no such
    -- shift. Evaluated once per buildBody() call, which already reruns via
    -- modal:rebuildTab() on every status change (refreshInPlace below).
    local BookList = require("ui/widget/booklist")
    local function statusBtn(label, value)
        local selected = BookList.getBookStatus(book.filepath) == value
        return {
            id   = "status_" .. value,
            text = label,
            background = selected and Blitbuffer.COLOR_LIGHT_GRAY or nil,
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
    -- Same checkbox-marked / checkbox-blank-outline glyph pair as the start
    -- menu's toggle items (lib/bookshelf_menu_host.lua's GLYPH_CHECK_ON/OFF).
    -- Rendered by the hand-built Favourite row below, not embedded in this
    -- spec -- see that row's comment for why.
    local FAV_CHECK_ON  = "\xEE\xA0\xB1" -- U+E831 checkbox-marked
    local FAV_CHECK_OFF = "\xEE\xA0\xB0" -- U+E830 checkbox-blank-outline
    local fav = {
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
        local function afterDelete()
            Repo.invalidateProgressCache(book.filepath)
            Repo.invalidateWalkCache()
            bw:_scrubFromDrilldown(book.filepath)
            refreshShelf()
        end
        -- Delete goes through the FileManager's own delete dialog (sidecar +
        -- history + collections cleanup). That needs a live FM, so finish the
        -- park first when a reader is parked -- same rule as Show info. The
        -- confirmbox below is a defensive last resort only (no FM at all).
        require("lib/bookshelf_reader_park").runInFileManager(function(fm)
            fm = fm or require("apps/filemanager/filemanager").instance
            if fm and fm.showDeleteFileDialog then
                fm:showDeleteFileDialog(book.filepath, afterDelete)
            else
                UIManager:show(require("ui/widget/confirmbox"):new{
                    text    = _("Delete file permanently?") .. "\n\n" .. book.filepath,
                    ok_text = _("Delete"),
                    ok_callback = function()
                        if os.remove(book.filepath) then
                            require("readhistory"):fileDeleted(book.filepath)
                            ReadCollection:removeItem(book.filepath)
                            afterDelete()
                        else
                            UIManager:show(require("ui/widget/infomessage"):new{
                                text = _("Failed to delete file."), icon = "notice-warning" })
                        end
                    end,
                })
            end
        end)
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

    -- Move: disabled while this book is the open/parked document
    -- (moving the file under a live reader risks the close-time
    -- sidecar flush recreating data at the old path).
    local FileOpsMod = require("lib/bookshelf_file_ops")
    local move_in_use = FileOpsMod.inUsePaths()[book.filepath] and true or false
    local move_btn = {
        text    = _("Move\xE2\x80\xA6"),
        enabled = not move_in_use,
        callback = function()
            closeModal()
            require("lib/bookshelf_move_flow").moveBooks{
                bw    = bw,
                paths = { book.filepath },
            }
        end,
    }

    -- Third-party file-dialog buttons (e.g. Incognito). Run their specs RAW --
    -- exactly as the old long-press menu did -- rather than wrapping them to
    -- close the popup first; a plugin callback that opens the reader triggers our
    -- onShowingReader handler, which closes the popup cleanly.
    local plugin_rows = bw:_fileDialogPluginRows(book.filepath)

    -- ── Section row groups ───────────────────────────────────────────────────
    -- The status quad is a real ButtonTable row; Favourite/Remove-from-history
    -- is hand-built below instead (see "Favourite row" comment) so the
    -- checkbox glyph can be its own non-bold TextWidget.
    local status_rows = {
        {
            statusBtn(_("Unopened"), "new"),       statusBtn(_("Reading"),  "reading"),
            statusBtn(_("On hold"),  "abandoned"), statusBtn(_("Finished"), "complete"),
        },
    }
    local file_rows = {
        { show_info, refresh_btn, select_btn },
        { move_btn, reset_btn, delete_btn },
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
            -- A thin Size.border.window gap either side, same as KOReader's
            -- own ButtonDialog separator -- close to full width, not
            -- perfectly edge-to-edge.
            return FrameContainer:new{
                bordersize = 0, margin = 0,
                padding_left = Size.border.window, padding_right = Size.border.window,
                LineWidget:new{
                    background = Blitbuffer.COLOR_GRAY,
                    dimen = Geom:new{ w = content_w - 2 * Size.border.window, h = Size.line.medium },
                },
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
        local status_bt = btSection(_("Reading status"), status_rows)
        -- Button's background-implies-rounded-corners coupling (button.lua:
        -- radius defaults to Size.radius.button whenever background is set,
        -- and ButtonTable doesn't forward a per-row radius override) can't be
        -- overridden via the row spec -- square off the selected pill's fill
        -- directly on the built Button instance instead. Also underline the
        -- label itself (not the full button width -- a full-width bar reads
        -- as just another edge, a text-width underline as a deliberate
        -- mark), and extend the fill down through ButtonTable's own
        -- inter-row span gap (addVerticalSpan, a sibling widget below this
        -- frame, not part of it) so it meets the row separator directly
        -- instead of stopping short with a visible white sliver before it.
        do
            local cur_status = BookList.getBookStatus(book.filepath)
            local selected_btn = cur_status and status_bt.button_by_id["status_" .. cur_status]
            if selected_btn and selected_btn.frame then
                local frame = selected_btn.frame
                frame.radius = 0
                local orig_paintTo = frame.paintTo
                local underline_h = Size.line.medium
                local underline_gap = Screen:scaleBySize(1)
                -- Gap between this button's own frame and the row separator
                -- immediately below it in status_bt's own layout (ButtonTable's
                -- internal addVerticalSpan after its row). status_bt's own
                -- reported height runs Size.line.medium past the separator's
                -- own position (measured on-device), so subtract that back out
                -- -- else the fill bleeds past the separator into row 2's own
                -- top padding instead of stopping flush against it.
                local fill_extend = status_bt:getSize().h - frame:getSize().h - Size.line.medium
                function frame:paintTo(bb, x, y)
                    orig_paintTo(self, bb, x, y)
                    local sz = self:getSize()
                    bb:paintRect(x, y + sz.h, sz.w, fill_extend, self.background)
                    local label_sz = selected_btn.label_widget:getSize()
                    local ux = x + math.floor((sz.w - label_sz.w) / 2)
                    local uy = y + math.floor((sz.h + label_sz.h) / 2) + underline_gap
                    bb:paintRect(ux, uy, label_sz.w, underline_h, Blitbuffer.COLOR_BLACK)
                end
            end
        end

        -- Favourite row: hand-built rather than a ButtonTable entry, so the
        -- checkbox glyph is its own plain (non-bold) TextWidget, sized and
        -- centred independently of the "Favourite" label. Embedding the
        -- glyph inline in a bold button string (the previous approach) faux-
        -- bolds it -- BFont:getFace only has a real bold *.ttf for the UI
        -- font, so a bold request against the bundled Nerd Font symbols face
        -- falls back to synthetically emboldening the regular glyph, which
        -- reads as heavier/muddier strokes than the label text next to it.
        -- Matches ButtonTable's own row metrics (row_label_h, buttontable
        -- padding, gray column/row separators) so it reads as a continuation
        -- of the ButtonTable above rather than a visually distinct element.
        -- The label font is plain stock Font:getFace, NOT BFont:getFace --
        -- Button itself resolves its label face via stock Font:getFace
        -- (button.lua), bypassing bookshelf's own "follow UI font"
        -- substitution wrapper entirely. Using BFont here rendered a
        -- visibly different typeface from its ButtonTable siblings whenever
        -- that substitution is active.
        do
            local row_face = Font:getFace("cfont", font_size)
            local check_size = font_size + 8
            local check_face = BFont:getFace("symbols", check_size)
            local function favContent()
                local glyph = inFav() and FAV_CHECK_ON or FAV_CHECK_OFF
                return HorizontalGroup:new{ align = "center",
                    TextWidget:new{ text = glyph, face = check_face, fgcolor = Blitbuffer.COLOR_BLACK },
                    HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                    TextWidget:new{ text = _("Favourite"), face = row_face, bold = true },
                }
            end
            local remove_label = TextWidget:new{ text = _("Remove from history"),
                face = row_face, bold = true }
            local cell_w = math.floor((content_w - Size.line.medium) / 2)
            -- ButtonTable buttons total row_label_h PLUS its own padding
            -- (buttontable.lua passes padding = Size.padding.buttontable,
            -- which Button applies as extra top/bottom frame padding beyond
            -- the label height) -- match that here or this row renders
            -- visibly shorter than the quad above it.
            local row_h = row_label_h + 2 * Size.padding.buttontable
            local function tappableCell(widget, on_tap)
                local framed = FrameContainer:new{
                    bordersize = 0, margin = 0, padding = 0,
                    CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = row_h }, widget },
                }
                local cell = InputContainer:new{
                    dimen = Geom:new{ w = cell_w, h = row_h }, framed }
                cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
                cell.onTap = function() on_tap(); return true end
                cell.onFocus = function() framed.invert = true; return true end
                cell.onUnfocus = function() framed.invert = false; return true end
                return cell
            end
            local fav_cell    = tappableCell(favContent(), fav.callback)
            local remove_cell = tappableCell(remove_label, remove_history.callback)
            local sep = LineWidget:new{ background = Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{ w = Size.line.medium, h = row_h } }
            focus_tables[#focus_tables + 1] = focusRow({ { fav_cell, remove_cell } })
            -- No extra VerticalSpan here: ButtonTable's own addVerticalSpan
            -- already ran once after the quad row (baked into status_bt's
            -- own rendered height above) -- adding a second one doubled the
            -- gap between the quad and this separator versus the original
            -- two-row ButtonTable layout.
            vg[#vg + 1] = LineWidget:new{ background = Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{ w = avail_w, h = Size.line.medium } }
            vg[#vg + 1] = HorizontalGroup:new{ align = "top", fav_cell, sep, remove_cell }
        end

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
        -- left (inset to align with the headings), then a bordered ChipButton
        -- on the right -- same style as the Tags tab's Edit button (pencil glyph
        -- after the label). Used by the Hardcover row.
        local ChipButton = require("lib/bookshelf_chip_button")
        local function infoRow(text, btn_label, cb, want_bottom_border)
            local btn_w = Screen:scaleBySize(150)
            local edit_face = BFont:getFace("cfont", font_size)
            -- Match the Tags-tab Edit button's height exactly (the Tags-tab
            -- pill height: bold cfont label + Size.padding.small + border.thin,
            -- top and bottom) so the two Edit buttons look identical.
            local pf = BFont:getFace("cfont", font_size, { bold = true })
            local btn_h = TextWidget:new{ text = "Hg", face = pf }:getSize().h
                + 2 * Size.padding.small + 2 * Size.border.thin
            local btn = ChipButton.build{
                text       = btn_label,
                face       = edit_face,
                icon_glyph = "\xEE\xAB\xAA", -- nf-md-pencil, U+EAEA
                icon_face  = BFont:getFace("symbols", font_size),
                icon_after = true,
                height     = btn_h,
                on_tap     = cb,
            }
            local btn_h = btn:getSize().h
            -- Left cell: the value text, inset on the left to align with headings.
            local left_w = math.max(Screen:scaleBySize(60), content_w - btn_w)
            local txt = TextBoxWidget:new{ text = text,
                face  = BFont:getFace("cfont", font_size),
                width = math.max(Screen:scaleBySize(40), left_w - inset - Screen:scaleBySize(8)) }
            -- Extra room OUTSIDE the button/text (not inside the button itself):
            -- same total top+bottom budget as Plugin actions' chip row
            -- (padded(rows_vg, 10, 20) below), so the two sections carry the
            -- same visual weight even though this row centres its content
            -- instead of stacking it top-down.
            local row_h = math.max(btn_h, txt:getSize().h)
                + Screen:scaleBySize(10) + Screen:scaleBySize(20)
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
                label and _("Edit") or _("Link\xE2\x80\xA6"),
                function()
                    closeModal()
                    UIManager:nextTick(function() bw:_openHardcoverMenu(book) end)
                end)
        end

        -- 5. Plugin actions (only when a plugin contributed buttons) --
        -- bordered ChipButtons, same style as the Tags tab's Edit button
        -- (minus its pencil glyph: these are arbitrary third-party actions
        -- with no shared icon), rather than plain ButtonTable menu rows.
        if plugin_rows and #plugin_rows > 0 then
            vg[#vg + 1] = heading(_("Plugin actions"))
            local edit_face = BFont:getFace("cfont", font_size)
            local probe = TextWidget:new{ text = "Hg", face = edit_face }
            local chip_h = probe:getSize().h + 2 * Screen:scaleBySize(5)
            local chip_gap = Screen:scaleBySize(12)
            local row_gap  = Screen:scaleBySize(10)
            -- Flatten every registration's row into one list, then lay the
            -- chips out as a wrapping horizontal flow. Plugins each register a
            -- single-button "row", so the old row-per-line layout stacked them
            -- vertically once more than one plugin contributed; wrapping keeps
            -- them inline (like the pill groups), only breaking to a new line
            -- when the next chip wouldn't fit the content width.
            local avail = content_w - 2 * inset
            local specs = {}
            for _ri, row in ipairs(plugin_rows) do
                for _ci, spec in ipairs(row) do specs[#specs + 1] = spec end
            end
            local rows_vg = VerticalGroup:new{ align = "left" }
            local line, line_w, line_focus
            local function newLine()
                line = HorizontalGroup:new{ align = "center" }; line_w = 0; line_focus = {}
            end
            local function commitLine()
                if line and #line_focus > 0 then
                    if #rows_vg > 0 then
                        rows_vg[#rows_vg + 1] = VerticalSpan:new{ width = row_gap }
                    end
                    rows_vg[#rows_vg + 1] = line
                    focus_tables[#focus_tables + 1] = focusRow({ line_focus })
                end
            end
            newLine()
            for _si, spec in ipairs(specs) do
                local label = (spec.text_func and spec.text_func()) or spec.text or ""
                local chip = ChipButton.build{
                    text = label, face = edit_face, height = chip_h, on_tap = spec.callback,
                }
                local cw = chip:getSize().w
                if #line_focus > 0 and (line_w + chip_gap + cw) > avail then
                    commitLine(); newLine()
                end
                if #line_focus > 0 then
                    line[#line + 1] = HorizontalSpan:new{ width = chip_gap }
                    line_w = line_w + chip_gap
                end
                line[#line + 1] = chip
                line_w = line_w + cw
                line_focus[#line_focus + 1] = chip
            end
            commitLine()
            vg[#vg + 1] = padded(rows_vg, Screen:scaleBySize(10), Screen:scaleBySize(20))
        end

        -- Close the last section so its final button has a bottom edge --
        -- unless Plugin actions rendered: its ChipButtons already read as a
        -- complete block without a trailing rule under them.
        if not (plugin_rows and #plugin_rows > 0) then
            vg[#vg + 1] = rule()
        end
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
    -- Through the modal's _scroller, NOT a raw ScrollHtmlWidget: the stock
    -- widget claims every south swipe even with nothing above the fold, so
    -- swipe-down-to-close (issue 338) worked on every tab except this one.
    local opts = {
        html_body         = tab.html or "<p></p>",
        css               = css,
        default_font_size = Screen:scaleBySize((modal and modal.font_size) or 20),
        width             = avail_w,
        height            = math.max(Screen:scaleBySize(80), avail_h - header_h - hairline_h),
        dialog            = modal,
    }
    local scroller = (modal and modal._scroller) and modal:_scroller(opts)
                     or ScrollHtmlWidget:new(opts)
    return VerticalGroup:new{ align = "left", header, hairline, scroller }
end

-- _buildBookCoverTab — the Cover tab body: a toolbar (device picker + online
-- search) above a paginated grid of candidate covers. Local candidates are
-- cached on `state` for the modal's life; online ones live there after a search.
-- Tapping a cell applies it immediately (self:_applyCoverCandidate). Returns the
-- body with .focus_tables set for dpad nav. `state` is the cross-rebuild upvalue
-- from _showBookDetail; `modal` the live ReviewsModal (== show_parent).
function BookshelfWidget:_buildBookCoverTab(book, show_parent, avail_w, avail_h, state, modal)
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local TextWidget      = require("ui/widget/textwidget")
    local CoverApply      = require("lib/bookshelf_cover_apply")
    local CoverGridCell   = require("lib/bookshelf_cover_grid_cell")
    local Pagination      = require("lib/bookshelf_pagination")
    local ChipButton      = require("lib/bookshelf_chip_button")
    local SpineWidget     = require("lib/bookshelf_spine_widget")
    local bw = self
    -- show_parent IS the live ReviewsModal (see ReviewsModal:_activeBody). The
    -- `modal` upvalue from _showBookDetail is still nil during the modal's first
    -- _assemble (it's assigned only after ReviewsModal:new returns), so prefer
    -- show_parent -- always the current instance.
    modal = modal or show_parent

    -- The body must fill the SAME region the other tabs do: full body height
    -- (avail_h) and the same left/right content inset (_side_pad). avail_w is the
    -- full modal width; other tabs inset their content by _side_pad. Matching it
    -- keeps the modal frame the same size across tabs -- otherwise a shorter/
    -- wider Cover body shrinks + recentres the whole modal and leaves the prior
    -- tab's pixels around it (the reported painting glitch).
    local side_pad  = (show_parent and show_parent._side_pad) or Screen:scaleBySize(28)
    local content_w = avail_w - 2 * side_pad

    if not state.local_candidates then
        state.local_candidates = CoverApply.localCandidates(book)
    end
    local candidates = {}
    local seen_local = {}
    for _i, c in ipairs(state.local_candidates) do
        candidates[#candidates + 1] = c
        if c.filesize then
            seen_local[table.concat({ c.width or "?", c.height or "?", c.filesize }, "\1")] = true
        end
    end
    if type(state.online_candidates) == "table" then
        for _i, c in ipairs(state.online_candidates) do
            -- Skip an online result that IS a local candidate (e.g. the cover
            -- just applied from this very search, now showing as "Current
            -- cover") so it doesn't appear twice.
            local key = c.filesize
                and table.concat({ c.width or "?", c.height or "?", c.filesize }, "\1")
            if not (key and seen_local[key]) then
                candidates[#candidates + 1] = c
            end
        end
    end
    local total = #candidates

    -- Toolbar (text-only chips), left-aligned and inset by _side_pad -- the
    -- same left edge + padding as the tab content below.
    -- Match the Edit/Tags-tab chip buttons exactly: cfont at the modal's base
    -- size, sized to the same "pill height" (base text + small pad + thin
    -- border top/bottom) as makeEditButton, rather than the old chunky fixed
    -- 40px / 15pt look.
    local base     = (modal and modal.font_size) or 18
    local btn_face = BFont:getFace("cfont", base)
    local btn_h
    do
        local pf = BFont:getFace("cfont", base, { bold = true })
        btn_h = TextWidget:new{ text = "Hg", face = pf }:getSize().h
            + 2 * Size.padding.small + 2 * Size.border.thin
    end
    local device_btn = ChipButton.build{
        text = _("Choose from device"), face = btn_face, height = btn_h,
        on_tap = function() bw:_pickBookCoverFromDevice(book, modal, state) end,
    }
    local online_btn = ChipButton.build{
        text = _("Search online\xE2\x80\xA6"), face = btn_face, height = btn_h,
        on_tap = function() bw:_searchOnlineCovers(book, state, modal) end,
    }
    local toolbar = HorizontalGroup:new{
        align = "center",
        device_btn, HorizontalSpan:new{ width = Screen:scaleBySize(10) }, online_btn,
    }
    local toolbar_row = LeftContainer:new{
        dimen = Geom:new{ w = content_w, h = toolbar:getSize().h }, toolbar,
    }
    local toolbar_h = toolbar_row:getSize().h

    -- Grid geometry: 2-4 columns by width; rows to fill the height.
    local gap      = Screen:scaleBySize(10)
    local min_cell = Screen:scaleBySize(120)
    local n_cols   = math.max(2, math.min(4, math.floor((content_w + gap) / (min_cell + gap))))
    local cell_w   = math.floor((content_w - gap * (n_cols - 1)) / n_cols)

    local caption_font = math.max(10, math.min((modal and modal.font_size) or 13, 15))
    local cap_h  = CoverGridCell.captionHeight(caption_font)
    local ring   = SpineWidget.SELECTED_BORDER
    -- Non-cover part of a cell (caption + gap + ring headroom top/bottom).
    local chrome = Screen:scaleBySize(4) + cap_h + 2 * ring

    local top_pad     = Screen:scaleBySize(12)   -- gap below the tab bar / above toolbar
    local tb_gap      = Screen:scaleBySize(12)    -- gap below the toolbar
    -- Space reserved below the grid for the pagination row plus a standard gap
    -- beneath it (matching the pagination spacing used elsewhere) so the page
    -- nav sits just off the modal's Close/Open footer, not jammed against it.
    local nav_bottom_pad = Size.padding.fullscreen
    local nav_reserve = Screen:scaleBySize(44) + nav_bottom_pad
    local grid_avail_h = math.max(1, avail_h - top_pad - toolbar_h - tb_gap - nav_reserve)
    -- Pack as many rows as fit while each cover stays at least ~1.05x its width
    -- tall (still portrait), so the grid FILLS the body instead of one tall row
    -- with dead space below. Capped by the candidate count so a handful of
    -- candidates don't leave an empty trailing row.
    local rows = 1
    for r = 1, 4 do
        local ch = math.floor((grid_avail_h - gap * (r - 1)) / r)
        if (ch - chrome) >= math.floor(cell_w * 1.05) then rows = r end
    end
    rows = math.min(rows, math.max(1, math.ceil(total / n_cols)))
    local cell_h = math.floor((grid_avail_h - gap * (rows - 1)) / rows)
    -- Cap cell height to a natural cover (2:3) so a single row of one or two
    -- candidates renders normal-sized covers, not full-body-height slabs. The
    -- unused space becomes the trailing fill spacer below.
    local cell_cap = math.floor(cell_w * 1.5) + chrome
    if cell_h > cell_cap then cell_h = cell_cap end

    local page_size   = n_cols * rows
    local total_pages = math.max(1, math.ceil(total / math.max(1, page_size)))
    if state.page > total_pages then state.page = total_pages end
    if state.page < 1 then state.page = 1 end

    local col = VerticalGroup:new{ align = "center" }
    col[#col + 1] = VerticalSpan:new{ width = top_pad }   -- breathing room below the tab bar
    col[#col + 1] = toolbar_row
    col[#col + 1] = VerticalSpan:new{ width = tb_gap }

    local focus_tables = {}
    if total == 0 then
        col[#col + 1] = CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = math.max(cell_h, Screen:scaleBySize(80)) },
            TextWidget:new{
                text = _("No covers stored yet. Use Search online or Choose from device."),
                face = BFont:getFace("cfont", 15),
                max_width = content_w - Screen:scaleBySize(20),
            },
        }
    else
        -- Build the grid as a FIXED-height block (rows * cell_h) so the
        -- pagination row below sits at the same Y on every page -- a final page
        -- with fewer rows pads the remainder rather than pulling the nav up.
        local grid = VerticalGroup:new{ align = "center" }
        local grid_h = 0
        local start_i = (state.page - 1) * page_size
        for r = 0, rows - 1 do
            local has_any = false
            for c = 0, n_cols - 1 do
                if candidates[start_i + r * n_cols + c + 1] then has_any = true break end
            end
            if not has_any then break end  -- remaining rows are the block padding
            local row_group = HorizontalGroup:new{ align = "top" }
            local row_layout = {}
            for c = 0, n_cols - 1 do
                local idx = start_i + r * n_cols + c + 1
                local cand = candidates[idx]
                if cand then
                    local cell = CoverGridCell.new{
                        width = cell_w, height = cell_h, candidate = cand,
                        font_size = caption_font,
                        on_tap = function(cc) bw:_applyCoverCandidate(book, cc, modal, state) end,
                    }
                    row_group[#row_group + 1] = cell
                    row_layout[#row_layout + 1] = cell
                else
                    row_group[#row_group + 1] = HorizontalSpan:new{ width = cell_w }
                end
                if c < n_cols - 1 then
                    row_group[#row_group + 1] = HorizontalSpan:new{ width = gap }
                end
            end
            if #grid > 0 then
                grid[#grid + 1] = VerticalSpan:new{ width = gap }; grid_h = grid_h + gap
            end
            grid[#grid + 1] = row_group; grid_h = grid_h + cell_h
            if #row_layout > 0 then focus_tables[#focus_tables + 1] = focusRow(row_layout) end
        end
        local grid_block_h = rows * cell_h + (rows - 1) * gap
        if grid_h < grid_block_h then
            grid[#grid + 1] = VerticalSpan:new{ width = grid_block_h - grid_h }
        end
        col[#col + 1] = grid
    end

    if total_pages > 1 then
        local nav = Pagination.buildNav{
            page = state.page, total_pages = total_pages, show_parent = show_parent,
            -- Text chevrons: this nav lives inside the book-detail modal, whose
            -- cropping_widget routes icon-button flash through the raw
            -- widgetInvert/invertRect path that segfaulted on a PocketBook
            -- InkPad framebuffer. Text buttons use the bounds-safe repaint path.
            text_chevrons = true,
            on_goto = function(target)
                state.page = target
                if modal and modal.rebuildTab then modal:rebuildTab() end
            end,
        }
        local nav_h = nav:getSize().h
        -- Bottom-anchor the nav: push any leftover grid slack ABOVE it so it
        -- always sits exactly nav_bottom_pad above the footer, instead of the
        -- trailing fill piling up below it when the covers don't fill the
        -- height (which was making the gap balloon).
        local used = 0
        for _i, ch in ipairs(col) do used = used + (ch.getSize and ch:getSize().h or 0) end
        local slack = avail_h - used - nav_h - nav_bottom_pad
        if slack > 0 then col[#col + 1] = VerticalSpan:new{ width = slack } end
        col[#col + 1] = CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = nav_h }, nav,
        }
        col[#col + 1] = VerticalSpan:new{ width = nav_bottom_pad }
    end

    -- Pad the column to the full body height so the modal frame matches the
    -- other tabs (they size their scroller to avail_h). Then inset horizontally
    -- by side_pad. The white background erases the whole region on every
    -- (re)assemble, so switching to/from this tab leaves no stale pixels.
    -- Sum children directly rather than calling col:getSize() mid-build --
    -- VerticalGroup caches its size/offsets on first getSize(), so measuring the
    -- group before appending the spacer would freeze the short height and ignore
    -- the pad (the VerticalGroup getSize caching gotcha).
    local used_h = 0
    for _i, ch in ipairs(col) do
        used_h = used_h + (ch.getSize and ch:getSize().h or 0)
    end
    if used_h < avail_h then
        col[#col + 1] = VerticalSpan:new{ width = avail_h - used_h }
    end
    local framed = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        padding_left = side_pad, padding_right = side_pad,
        background = Blitbuffer.COLOR_WHITE,
        col,
    }
    framed.focus_tables = focus_tables
    -- Expose the grid's pagination so the modal's horizontal swipe pages the
    -- covers first and only cycles tabs once you're off the end (see
    -- ReviewsModal:onSwipe). Absent when there's a single page.
    if total_pages > 1 then
        framed._pager = {
            page = state.page,
            total_pages = total_pages,
            goto_page = function(target)
                state.page = target
                if modal and modal.rebuildTab then modal:rebuildTab() end
            end,
        }
    end
    return framed
end

-- Apply a tapped candidate as the book's cover (or revert to embedded), then
-- close + reopen the modal on the Cover tab so the (cached) header thumbnail and
-- the grid rings reflect the new active cover. Immediate-apply per the design.
-- `state` is the Cover tab's cross-rebuild table, threaded through the reopen.
function BookshelfWidget:_applyCoverCandidate(book, candidate, modal, state)
    if not (book and book.filepath and candidate) then return end
    local CoverApply = require("lib/bookshelf_cover_apply")
    local ok, err
    if candidate.kind == "embedded" then
        ok, err = CoverApply.revertToEmbedded(book.filepath)
        -- BIM's cached cover_bb may still hold the previously-applied cover:
        -- while a custom cover was active, a shelf re-extract cached IT (BIM
        -- extracts the active DocSettings custom cover). With the custom cover
        -- now removed, the render falls back to that stale cover_bb, so the
        -- header/hero keep showing the old cover after "revert to embedded".
        -- Force a fresh extraction (custom gone -> embedded) so cover_bb is
        -- correct before the reopened modal's buildBookMeta reads it. delete +
        -- extract mirrors the stale-sweep's proven re-extract pattern.
        if ok then
            pcall(function()
                local BIM = require("bookinfomanager")
                if BIM and BIM.extractBookInfo then
                    local sw = Screen:getWidth()
                    local cw = math.max(1, math.floor(sw * 0.5))
                    if BIM.deleteBookInfo then BIM:deleteBookInfo(book.filepath) end
                    BIM:extractBookInfo(book.filepath,
                        { max_cover_w = cw, max_cover_h = math.floor(cw * 1.5) })
                end
            end)
        end
    elseif not candidate.local_path then
        self:_hardcoverToast(_("That cover is unavailable"))
        return
    else
        ok, err = CoverApply.apply(book.filepath, candidate.local_path,
                                   { label = candidate.source_label })
    end
    if not ok then
        self:_hardcoverToast(err and tostring(err) or _("Couldn't set the cover"))
        return
    end
    -- Stop Hardcover auto-injecting its own cover over a manual pick on linked
    -- books (flag-only; the sidecar file is already handled here).
    local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
    if ok_hc and Hardcover and Hardcover.isAvailable and Hardcover.isAvailable()
            and Hardcover.getLink and Hardcover.getLink(book.filepath)
            and Hardcover.markUseCover then
        pcall(Hardcover.markUseCover, book.filepath, false)
    end
    self:_refreshSingleBookCover(book.filepath, "cover-picker")

    -- Keep the grid order stable across the reopen. Re-deriving the local list
    -- inserts a new front-of-list "Current cover" (+ "Previous cover") and
    -- drops the applied online result from its slot, so the whole grid
    -- reshuffled on every apply. Instead, when the tapped candidate is one
    -- that's already on screen, reuse the cached lists and just move the active
    -- ring onto it -- dropping only entries whose file has since vanished (the
    -- removed custom cover after a revert) so no blank tile lingers. The fresh
    -- "Current cover"/"Previous cover" entries re-derive on the next open. An
    -- off-grid apply (device file picker) isn't in the lists, so fall back to
    -- re-deriving there or the new cover wouldn't appear at all.
    if type(state) == "table" then
        local function inList(list)
            if type(list) == "table" then
                for _i, c in ipairs(list) do if c == candidate then return true end end
            end
            return false
        end
        if inList(state.local_candidates) or inList(state.online_candidates) then
            local function reflag(list)
                if type(list) ~= "table" then return list end
                local kept = {}
                for _i, c in ipairs(list) do
                    if c.kind == "embedded" or CoverApply.fileSize(c.local_path) then
                        c.is_active = (c == candidate)
                        kept[#kept + 1] = c
                    end
                end
                return kept
            end
            state.local_candidates  = reflag(state.local_candidates)
            state.online_candidates = reflag(state.online_candidates)
        else
            state.local_candidates = nil  -- off-grid pick: re-derive so it shows
        end
    end
    local bw = self
    local fresh = Repo.buildBookMeta(book.filepath, { want_cover = true }) or book
    if modal then UIManager:close(modal) end
    UIManager:nextTick(function()
        bw:_showBookDetail(fresh, { active = "cover", cover_state = state })
    end)
    self:_hardcoverToast(candidate.kind == "embedded"
        and _("Reverted to embedded cover") or _("Cover updated"))
end

-- File picker (any image) -> apply as cover. Same PathChooser shape as
-- _pickFolderImage; routes through _applyCoverCandidate so refresh/reopen match.
function BookshelfWidget:_pickBookCoverFromDevice(book, modal, state)
    if not (book and book.filepath) then return end
    local PathChooser = require("ui/widget/pathchooser")
    local ImageSource = require("lib/bookshelf_image_source")
    local bw = self
    local start_path = G_reader_settings:readSetting("home_dir")
        or (book.filepath:match("^(.*)/[^/]+$")) or "/"
    UIManager:show(PathChooser:new{
        title            = _("Choose cover image"),
        path             = start_path,
        select_directory = false,
        select_file      = true,
        show_files       = true,
        file_filter      = function(file) return ImageSource.isImageFile(file) end,
        onConfirm        = function(image_path)
            bw:_applyCoverCandidate(book,
                { kind = "device", local_path = image_path, source_label = _("Device") },
                modal, state)
        end,
    })
end

-- "Search online" -> fetch candidates (Wi-Fi-gated, user-initiated), then drop
-- them into the grid. Wrapped in Trapper so per-source progress shows and the
-- user can cancel; never auto-fetches (privacy invariant).
function BookshelfWidget:_searchOnlineCovers(book, state, modal)
    local CoverFetch = require("lib/bookshelf_cover_fetch")
    local bw = self
    CoverFetch.runWhenOnline(function()
        local CoverSources = require("lib/bookshelf_cover_sources")
        local ok_t, Trapper = pcall(require, "ui/trapper")
        local function run()
            local results = CoverSources.searchOnline(book)
            state.online_candidates = results
            state.page = 1
            if modal and not modal._dismissed and modal.rebuildTab then
                modal:rebuildTab()
            end
            if not results or #results == 0 then
                bw:_hardcoverToast(_("No cover matches found"))
            end
        end
        if ok_t and Trapper and Trapper.wrap then
            Trapper:wrap(run)
        else
            run()
        end
    end, function(err)
        bw:_hardcoverToast(_("Cover search failed"))
        logger.warn("[bookshelf cover] online search error", tostring(err))
    end)
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
    -- Remote (OPDS) records have no sidecar, no collections and no file to act
    -- on, so every tab here would be inert at best and a file op on a
    -- pseudo-path at worst (the Edit tab offers Delete). Long-press gets the
    -- same read-only viewer the tap path shows. Path-prefix match, so a
    -- hero-hydrated record with its flags stripped is caught too.
    if self:_isRemoteRecord(book) then
        self:_showRemoteBookInfo(book)
        return
    end
    local ReadCollection = require("readcollection")
    local in_collections = ReadCollection.getCollectionsWithFile
        and ReadCollection:getCollectionsWithFile(book.filepath) or {}
    -- Favourites isn't editable through the Collection Manager (it has its
    -- own ★ toggle, see bookshelf_collection_manager's _orderedNames) and
    -- Save there doesn't preserve memberships outside its own list -- so
    -- don't show it as a collection pill in the Tags tab, where it would sit
    -- right above that Edit button.
    in_collections[ReadCollection.default_collection_name] = nil
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
    local edit_idx, tags_idx, desc_idx, reviews_idx, cover_idx
    -- Cover tab's cross-rebuild state (current page, cached candidate lists).
    -- An upvalue so pagination taps and "Search online" survive the tab's
    -- rebuildTab (which re-invokes the widget_builder). An apply tears the modal
    -- down and reopens; opts.cover_state carries this table across that reopen
    -- so a completed online search isn't lost (re-searching would re-download
    -- every candidate just to try a second cover).
    local cover_tab_state = (type(opts.cover_state) == "table" and opts.cover_state)
        or { page = 1 }

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
                -- order -- pillsFrame/pillsWithEdit below register into this
                -- as they're called, so each section's own call site doesn't
                -- need to change. See ReviewsModal:_assemble's handling of an
                -- ARRAY focus_tables (bookshelf_reviews_modal.lua).
                local focus_tables = {}
                local function pillsFrame(specs, top_pad)
                    local pills, focus_rows = self:_buildPillGroup(specs, pills_w, 9999, base, "left",
                        Screen:scaleBySize(8))
                    if focus_rows and #focus_rows > 0 then
                        focus_tables[#focus_tables + 1] = focusRow(focus_rows)
                    end
                    return FrameContainer:new{
                        bordersize = 0, margin = 0,
                        padding_left = lpad, padding_right = lpad,
                        padding_top = top_pad or Screen:scaleBySize(10),
                        -- Section heading bars have no top margin of their own
                        -- (self:_sectionHeadingBar) -- this is the only gap
                        -- between one section's pills and the next heading, so
                        -- it's a bit larger than the pill row's own top pad.
                        padding_bottom = Screen:scaleBySize(20),
                        pills,
                    }
                end
                -- A section's pills laid out in a column that RESERVES the Edit
                -- button's width on the right, with the button pinned top-right
                -- (issue #230). Replaces the old hairline + separate padded Edit
                -- row + empty-state label: each editable section is now just its
                -- heading + this block, reclaiming the vertical space #230 flagged
                -- (genres pushed below the fold on a short screen). Empty `specs`
                -- => just the button, so a book with no tags can still add some.
                -- Pills wrap inside the narrowed column so they never run under
                -- the button.
                -- The pencil "Edit" ChipButton. Focus is NOT registered here so
                -- the caller can order it relative to sibling widgets (pills, the
                -- source-chip row).
                -- Height a Tags-tab pill renders at, so the Edit button lines up
                -- with them: a bold cfont label at `base` + Size.padding.small
                -- top/bottom + a thin border top/bottom (mirrors _buildPillGroup).
                local pill_h
                do
                    local pf = BFont:getFace("cfont", base, { bold = true })
                    pill_h = TextWidget:new{ text = "Hg", face = pf }:getSize().h
                        + 2 * Size.padding.small + 2 * Size.border.thin
                end
                local function makeEditButton(on_edit_tap)
                    return ChipButton.build{
                        text       = _("Edit"),
                        face       = BFont:getFace("cfont", base),
                        icon_glyph = "\xEE\xAB\xAA", -- nf-md-pencil, U+EAEA
                        icon_face  = BFont:getFace("symbols", base),
                        icon_after = true,
                        -- Same height as the pills so it sits level with them,
                        -- while staying a distinct bordered chip (not pill-styled).
                        height     = pill_h,
                        on_tap     = on_edit_tap,
                    }
                end
                local function pillsWithEdit(specs, on_edit_tap, top_pad, empty_msg)
                    local btn = makeEditButton(on_edit_tap)
                    local gap   = Screen:scaleBySize(12)
                    local col_w = math.max(Screen:scaleBySize(40),
                        pills_w - btn:getSize().w - gap)
                    local left
                    -- Pills top-align with the button (multi-row pills start at
                    -- the top); a lone empty-state note instead centres against
                    -- the button, like the Hardcover title row in the Edit tab.
                    local valign = "center"
                    if specs and #specs > 0 then
                        valign = "top"
                        local pills, focus_rows = self:_buildPillGroup(specs, col_w, 9999,
                            base, "left", Screen:scaleBySize(8))
                        if focus_rows and #focus_rows > 0 then
                            focus_tables[#focus_tables + 1] = focusRow(focus_rows)
                        end
                        -- Pin the pill column to the FULL reserved width so the
                        -- Edit button sits at the section's right edge -- a bare
                        -- pill group sizes to its widest row, which left the
                        -- button floating just right of the pills (#230 review).
                        local LeftContainer = require("ui/widget/container/leftcontainer")
                        left = LeftContainer:new{
                            dimen = Geom:new{ w = col_w, h = pills:getSize().h },
                            pills,
                        }
                    elseif empty_msg and empty_msg ~= "" then
                        -- Empty section: a left-aligned note where the pills would
                        -- be (e.g. "Not in any collection."), Edit still top-right.
                        left = TextBoxWidget:new{ text = empty_msg,
                            face = BFont:getFace("cfont", base),
                            fgcolor = Blitbuffer.COLOR_DARK_GRAY, width = col_w }
                    else
                        left = HorizontalSpan:new{ width = col_w }
                    end
                    -- Register the button's focus AFTER the pills so dpad reads
                    -- pills -> Edit, matching the visual top-left-to-right order.
                    focus_tables[#focus_tables + 1] = focusRow({ { btn } })
                    return FrameContainer:new{
                        bordersize = 0, margin = 0,
                        padding_left = lpad, padding_right = lpad,
                        padding_top = top_pad or Screen:scaleBySize(10),
                        padding_bottom = Screen:scaleBySize(16),
                        HorizontalGroup:new{ align = valign,
                            left,
                            HorizontalSpan:new{ width = gap },
                            btn,
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
                        -- Always render the Genres section (even with no genres in
                        -- any source) so its inline Edit button stays reachable to
                        -- add the first tag -- previously it was hidden entirely,
                        -- leaving no way to add tags to an untagged book.
                        do
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
                            -- The source-chip strip (Embedded/Calibre/Hardcover)
                            -- is built at the render tail below, because the Edit
                            -- button rides its row and needs editGenres (defined
                            -- further down) as its handler.
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
                            -- Source-chip strip (Embedded/Calibre/Hardcover) as
                            -- its own full-width row when there's more than one
                            -- source. The Edit button then pins top-right of the
                            -- first pill row (pillsWithEdit below).
                            if #items > 1 then
                                local chip_cb = function(key)
                                    -- The expensive part (light-meta invalidation + a full
                                    -- shelf _rebuild -- ~600-900ms, ~90% of a tap) is
                                    -- deferred to modal close (see genre_source_changed);
                                    -- only the cheap per-book caches refresh now.
                                    BookshelfSettings.setGenreSource(book.filepath, key)
                                    Repo.invalidateBookCache("genre-source")
                                    genre_source_changed = (key ~= genre_source_at_open)
                                    if modal and modal.rebuildTab then modal:rebuildTab() end
                                end
                                local source_chips, chips_focus_rows =
                                    self:_segmentedChips(items, active, chip_cb, base, lpad)
                                focus_tables[#focus_tables + 1] = focusRow(chips_focus_rows)
                                vg[#vg + 1] = source_chips
                            end
                            -- Editable (Embedded) source: pills + inline top-right
                            -- Edit button (empty gpills -> just the button, so an
                            -- untagged book can still add tags). Read-only sources
                            -- (Calibre/Hardcover): pills only, full width.
                            if editable then
                                vg[#vg + 1] = pillsWithEdit(gpills, editGenres,
                                    (#items > 1) and Screen:scaleBySize(6) or nil)
                            elseif #gpills > 0 then
                                vg[#vg + 1] = pillsFrame(gpills)
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
                                    in_collections[rc.default_collection_name] = nil
                                    pill_specs = self:_buildPillSpecs(book, in_collections, nil, nil)
                                    self:_rebuild(); UIManager:setDirty(self, "ui")
                                    if modal and modal.rebuildTab then modal:rebuildTab() end
                                end }
                        end
                        -- Pills + inline top-right Edit button. When empty, a
                        -- left-aligned "Not in any collection." note fills the
                        -- pill column (Edit stays top-right), rather than its own
                        -- extra line as before.
                        vg[#vg + 1] = pillsWithEdit(specs, editCollections, Screen:scaleBySize(16),
                            (not specs or #specs == 0) and _("Not in any collection.") or nil)
                    else
                        local specs = by_cat[sec.cat]
                        if specs and #specs > 0 then
                            vg[#vg + 1] = self:_sectionHeadingBar(sec.title, avail_w, base, lpad)
                            vg[#vg + 1] = pillsFrame(specs, Screen:scaleBySize(16))
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
    -- Only when the plugin is live: with it uninstalled/disabled we suppress all
    -- Hardcover.app data, so no community-reviews tab even if reviews are cached.
    local has_reviews = (ok_hc and Hardcover and Hardcover.isAvailable
        and Hardcover.isAvailable() and book_id) and true or false
    -- No title: the popup header already shows the book title/author. The
    -- rating/counts summary is a native row (_buildReviewsHeader), not part
    -- of this HTML -- only the review list itself renders here.
    local function reviewsListHtml(result)
        return Tokens.reviewsHtml{ reviews = result and result.reviews }
    end
    local reviews_tab  -- forward ref: refreshReviews mutates it, its
                        -- widget_builder (below) reads it back each rebuild.
    -- The ONLY thing that fetches reviews (a network call that prompts for WiFi
    -- when offline) is the header's Refresh button -- never opening the popup
    -- and never just viewing the Reviews tab. This keeps battery/network use to
    -- explicit user action; opening a linked book to read its description no
    -- longer prompts for WiFi (issue 253). Cached reviews still show offline.
    -- `modal` is assigned after this closure is created but before Refresh can
    -- invoke it (upvalue, read at call time).
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
            -- No cached reviews: invite an explicit fetch rather than loading
            -- automatically (that would hit the network on open -- issue 253).
            html = "<p>" .. _("Tap Refresh to load reviews.") .. "</p>"
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

    -- Edit next: the actions tab is reached for less often than Description/
    -- Reviews/Tags, so it sits toward the end of the strip rather than hogging
    -- the first (default-focus) slot.
    edit_idx = #tabs + 1
    tabs[edit_idx] = edit_tab

    -- Cover tab LAST: pick the book's cover from local sources / the device /
    -- an online search. Native, paginated grid. Being last keeps its own
    -- left/right swipe pagination out of the way of the tab-cycling swipe until
    -- you page off the end (see ReviewsModal:onSwipe).
    cover_idx = #tabs + 1
    tabs[cover_idx] = {
        id = "cover", label = _("Cover"),
        widget_builder = function(avail_w, avail_h, show_parent)
            return self:_buildBookCoverTab(book, show_parent, avail_w, avail_h,
                                           cover_tab_state, modal)
        end,
    }

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
    elseif opts.active == "cover" and cover_idx then
        active_tab = cover_idx
    elseif desc_idx then
        active_tab = desc_idx  -- the chip bar defaults to the hero's source
    else
        active_tab = edit_idx or 1
    end

    local args = {
        tabs       = tabs,
        bw         = self,
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
            -- Empty the Cover tab's transient working dir (embedded-cover
            -- PNGs + online search downloads + any older per-book cruft) so it
            -- doesn't pile up in the settings folder (issue 267). Applied
            -- covers live in the book's .sdr and are untouched. Fires only on a
            -- real dismiss/Open, NOT on the apply flow's reopen (that goes
            -- through UIManager:close -> onCloseWidget, which doesn't run
            -- on_close), so the carried online candidates survive that trip.
            pcall(function() require("lib/bookshelf_cover_apply").resetWorkingCache() end)
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
    -- No fetch on open: reviews load only when the user taps Refresh on the
    -- Reviews tab (see refreshReviews / issue 253). Cached reviews, if any,
    -- are already shown from the cache_only peek above.
end

-- Hardcover reviews now live as a tab in the unified book-detail popup, so this
-- just opens that popup on the Reviews tab. opts.on_close reopens the caller
-- (e.g. the book menu) on dismiss.
function BookshelfWidget:_showHardcoverReviews(book, opts)
    opts = opts or {}
    self:_showBookDetail(book, { active = "reviews", on_close = opts.on_close })
end

-- Scoped single-book cover refresh. A cover change (Hardcover toggle, or the
-- Cover picker applying an image) can't reorder the shelf or change chip
-- membership (cover_image_path isn't a sort key), so the whole _rebuild -- fetch
-- + sort + assemble, ~450ms on the All chip -- is wasted on a one-book change.
-- Invalidate this book's caches, then refresh just its spine in place plus the
-- hero when it's the previewed book. Returns true when handled in place; falls
-- back to a full _rebuild (and returns false) when the in-place path can't reach
-- the book (off the current page, expanded layout, cold tree).
--
-- Drops only this book's scaled bitmap + progress memo -- NOT a global
-- image_source.invalidateCache(), which re-decodes EVERY visible cover
-- (measured ~1.7-2s). The new cover is at a new path (or new mtime), so the
-- path+mtime-keyed image cache misses for it anyway.
function BookshelfWidget:_refreshSingleBookCover(filepath, reason)
    Repo.invalidateBookCache(reason or "cover-change")
    if filepath then
        pcall(function() require("lib/bookshelf_scaled_cover_cache"):drop(filepath) end)
        pcall(function()
            if Repo.invalidateProgressCache then Repo.invalidateProgressCache(filepath) end
        end)
    end
    if filepath and self._inner_vgroup and self._shelf_dims
            and (self._shelf_dims.n_shelves or 2) == self:_nShelves() then
        local spine_done = self:_refreshSpineInPlace(filepath)
        local preview_fp = self._preview_book and self._preview_book.filepath
        local hero_done = false
        if preview_fp == filepath and not self._expanded then
            self:_swapHeroInPlace()
            hero_done = true
        end
        if spine_done or hero_done then
            return true
        end
    end
    if self._rebuild then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
    end
    return false
end

function BookshelfWidget:_refreshHardcoverEnrichmentView(reason, filepath)
    -- Per-book cover / description toggles refresh a single spine in place; a
    -- re-link / select-edition / metadata refresh DO change sort keys and
    -- membership, so those fall through to a full rebuild below.
    local toggle_only = (reason == "hardcover-use-cover"
                         or reason == "hardcover-use-description")
    if toggle_only then
        self:_refreshSingleBookCover(filepath, reason)
        return
    end
    Repo.invalidateBookCache(reason or "hardcover")
    if filepath then
        pcall(function() require("lib/bookshelf_scaled_cover_cache"):drop(filepath) end)
        pcall(function()
            if Repo.invalidateProgressCache then Repo.invalidateProgressCache(filepath) end
        end)
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

-- _currentViewBookPaths() -> { filepath, ... }
--
-- Every BOOK the current view holds, across all its pages - not just the page
-- on screen. A chip built from filters is flat, so there is no folder or stack
-- to long-press for a group selection (issue #320): this is what "Select all"
-- resolves instead, and it means the chip's own filters and sort decide the
-- set, exactly as the shelf shows it.
--
-- Stacks (series / author / folder tiles) contribute their MEMBER books, so
-- "select all" on a grouped chip selects the books rather than the tiles - the
-- same paths _applyStackSelection would add for each tile in turn.
--
-- Remote (OPDS) records are skipped: every bulk action operates on local
-- files, which is why bulk selection is refused on catalog views outright.
function BookshelfWidget:_currentViewBookPaths()
    local out, seen = {}, {}
    local function add(fp)
        if type(fp) == "string" and fp ~= "" and not seen[fp]
                and not self:_isRemoteRecord(fp) then
            seen[fp] = true
            out[#out + 1] = fp
        end
    end
    -- Fetch the whole view, NOT the page cache: Home / folder drills / search
    -- are window-fetched, so their cached item list is one page and reading it
    -- selected only what was on screen (Home reported 59 of 246 books).
    local ok_fetch, items = pcall(function()
        return (self:_fetchChipItems(SELECT_ALL_LIMIT, true))
    end)
    if not (ok_fetch and type(items) == "table") then
        items = self._page_items or {}
    end
    for _i = 1, #items do
        local it = items[_i]
        if type(it) == "table" then
            if it.books or it.kind then
                -- A stack tile: take its members via the same resolver the
                -- group menu uses, so the two paths cannot disagree.
                local ok, paths = pcall(function() return self:_resolveStackPaths(it) end)
                if ok and type(paths) == "table" then
                    for _j = 1, #paths do add(paths[_j]) end
                end
            else
                add(it.filepath)
            end
        end
    end
    return out
end

-- Select every book in the current view. Enters selection mode if needed, so
-- this works as the FIRST action (a flat filtered chip has no tile to
-- long-press) as well as from inside an existing selection.
function BookshelfWidget:_selectAllInView()
    -- Required locally: bookshelf_widget has no file-level Notification, and
    -- the bare global crashed the reader the first time this ran on an OPDS
    -- shelf (the guard below was the first line to reach for it).
    local Notification = require("ui/widget/notification")
    if self:_opdsEffectiveTab() then
        UIManager:show(Notification:new{
            text = _("Bulk selection isn't available in remote catalog views."),
        })
        return
    end
    local paths = self:_currentViewBookPaths()
    if #paths == 0 then
        UIManager:show(Notification:new{ text = _("No books to select here.") })
        return
    end
    if not self._selection:isActive() then self._selection:enterMode() end
    self._selection:addMany(paths)
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    -- Say the count out loud, and say so when the ceiling bit: a bulk action
    -- that silently selected a prefix of a big library would be acted on in
    -- good faith.
    if #paths >= SELECT_ALL_LIMIT then
        UIManager:show(Notification:new{
            text = T(_("Selected the first %1 books (the most one selection holds)."),
                     #paths),
        })
    else
        UIManager:show(Notification:new{
            text = T(_("Selected %1 books."), #paths),
        })
    end
end

-- Back-compat alias: callers that used to invoke the confirm-then-apply
-- helper get the no-confirm apply path now.
function BookshelfWidget:_showStackSelectionConfirm(group)
    self:_applyStackSelection(group)
end

-- _opdsStartFeed(tab) / _setOpdsStartFeed(...) — a catalogue chip's START
-- FOLDER: which feed the chip opens on, rather than the server's root.
--
-- "add a feature to opds catalog settings that lets you pick the starting
-- folder ... on the shelf long press a folder to set as chip root folder
-- (would still need a way to go back up to higher levels)".
--
-- NO NEW SETTING. tab.source.feed_url already means exactly this and is
-- already resolved everywhere -- _opdsEffectiveTab reads
-- `tab.source.feed_url or server.url`, and the comment on sameFeed spells out
-- that nil means the server's root. A chip has simply never had a way to SET
-- it; only a drilled subcatalog's stand-in tab carried one. So this is a
-- gesture and a menu over machinery that was already in place, and clearing it
-- is the way back up: nil is the root.
function BookshelfWidget:_opdsStartFeed(tab)
    tab = tab or require("lib/bookshelf_tab_model").getById(self.chip)
    if not (tab and tab.source and tab.source.kind == "opds") then return nil end
    return tab.source.feed_url, tab.source.feed_label
end

-- Writes through TabModel, the same load / patch / save the chip editor's own
-- Save does. feed_url = nil clears it back to the server root.
function BookshelfWidget:_setOpdsStartFeed(feed_url, label)
    local TabModel = require("lib/bookshelf_tab_model")
    local tabs = TabModel.load()
    local found
    for _i, t in ipairs(tabs) do
        if t.id == self.chip and t.source and t.source.kind == "opds" then
            t.source.feed_url   = feed_url
            -- Carried alongside so the chip editor can NAME the start folder
            -- rather than showing a url, and so clearing it can say what it is
            -- clearing. Dropped with the url, never left behind.
            t.source.feed_label = feed_url and label or nil
            found = true
            break
        end
    end
    if not found then return false end
    TabModel.save(tabs)
    -- Re-select the chip rather than just rebuilding. Changing where a chip
    -- STARTS is the same event as arriving at it: the drilldown has to go
    -- (whatever the reader had drilled into was reached from the old root and
    -- may sit above the new one), the cursor has to go back to the first item,
    -- and the OPDS fetch gate has to be armed because this rebuild is the
    -- first render of a feed the chip has never shown. _selectChip is that
    -- whole sequence and is already the thing a chip tap runs.
    self:_selectChip(self.chip)
    return true
end

-- _openOpdsNavMenu(rec) — long-press on a catalogue subcatalog.
--
-- Long-press did nothing at all on these rows before: handlersFor answered nil
-- for an opds_nav hold and the cover grid's tile swallowed it with a bare
-- `return true`. So this is the first thing the gesture has ever done there,
-- and what it does is the start folder.
--
-- Two entries, and the second is the answer to "would still need a way to go
-- back up to higher levels": with a start folder set, the levels above it are
-- not reachable by drilling -- they are above the root -- so the way back is
-- to clear it. Offered from any row of the catalogue, which is where a reader
-- who wants out of a too-deep start will be standing.
function BookshelfWidget:_openOpdsNavMenu(rec)
    if not (rec and rec.opds and rec.opds.feed_url) then return end
    local tab = require("lib/bookshelf_tab_model").getById(self.chip)
    if not (tab and tab.source and tab.source.kind == "opds") then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local current, current_label = self:_opdsStartFeed(tab)
    local label = rec.label or rec.display_title or rec.title or _("this folder")
    local dialog
    local buttons = {}
    if current == rec.opds.feed_url then
        -- Already the start folder. Say so rather than offering to set it
        -- again: a button that cannot change anything is a button that makes
        -- the reader wonder whether it worked.
        buttons[#buttons + 1] = {{
            text = _("Already the start folder"), enabled = false,
        }}
    else
        buttons[#buttons + 1] = {{
            text = T(_("Start this chip at \"%1\""), label),
            callback = function()
                UIManager:close(dialog)
                self:_setOpdsStartFeed(rec.opds.feed_url, label)
            end,
        }}
    end
    if current then
        buttons[#buttons + 1] = {{
            text = current_label
                   and T(_("Back to the top (now starts at \"%1\")"),
                         current_label)
                   -- "catalog", not "catalogue": source strings are American
                   -- and the British forms live in en_GB.po. The rest of this
                   -- dialog's neighbours already say "Catalog settings".
                   or _("Back to the top of the catalog"),
            callback = function()
                UIManager:close(dialog)
                self:_setOpdsStartFeed(nil, nil)
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("Cancel"), is_enter_default = true,
        callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{ title = label, title_align = "center",
                               buttons = buttons }
    UIManager:show(dialog)
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
            _("Pin %s to the chip bar for quick access,\nor select its %d books for bulk edits."),
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
    --   "none" → Select N        (nothing to add to yet: this STARTS a
    --                             selection, matching the book detail
    --                             tab's own "Select" button)
    --   "some" → Add N more | Remove M  (the Venn-diagram middle, where
    --                             "add" is right: a selection exists)
    --   "all"  → Remove N
    -- Each action applies directly with no extra confirmation.
    if n_for_prompt > 0 then
        if sel_state ~= "all" and remaining_count > 0 then
            table.insert(buttons[1], {
                text = (sel_state == "some")
                    and string.format(_("Add %d more"), remaining_count)
                    or  string.format(_("Select %d"), n_for_prompt),
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

        -- File management row (feature/file-move): relocate or rename
        -- the real directory behind this folder card.
        table.insert(buttons, {
            { text = _("Move folder\xE2\x80\xA6"), callback = function()
                close_dialog()
                require("lib/bookshelf_move_flow").moveFolder{
                    bw = bw_ref, folder_path = group.path,
                }
            end },
            { text = _("Rename folder\xE2\x80\xA6"), callback = function()
                close_dialog()
                require("lib/bookshelf_move_flow").renameFolder{
                    bw = bw_ref, folder_path = group.path,
                }
            end },
        })
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
    -- The tile that was tapped belongs to the view being left (see
    -- _markTapped); carrying its filepath into the new one would leave
    -- _selectedFilepath answering with something that is not on screen.
    self._tap_selected_fp = nil
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
    -- Backing out is user navigation, so it licenses a fetch the same way
    -- drilling in and turning a page do. It matters because the level being
    -- POPPED TO can legitimately have no cached window any more: OpdsWindow's
    -- LRU evicts on fetched_at (a read never refreshes it) and a deep browse
    -- can mint a window per subcatalog visited, so a catalog's own root feed
    -- can be evicted by the drilling that happened underneath it. Without the
    -- arm, that pop lands on the empty placeholder and _opdsAfterPage is not
    -- allowed to refill it -- the user is stranded until they think to swipe
    -- down. Costs nothing anywhere else: the hook still requires the page to
    -- come back flagged opds_needs_fetch, which only an OPDS page ever is, so
    -- every non-OPDS pop and every pop onto a still-cached window consumes the
    -- flag and does nothing.
    self:_markOpdsNav()
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
    -- Keyed on the first book, which is what the row compares a folder tile
    -- against (folder_fp in bookshelf_shelf_row).
    self:_markTapped(folder.first_book and folder.first_book.filepath)
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

-- _expandOpdsNav(rec, no_fetch) - tap handler for an OPDS navigation tile (a
-- subcatalog link within a remote feed), and the D-pad Enter on the same tile.
-- Ordinarily it drills in exactly as a folder does: push a path frame naming
-- the feed and let _fetchChipItems scope the shelf to it. The breadcrumb, the
-- east-swipe back-out and the page-1 "go up a level" all come for free from the
-- shared drill machinery.
--
-- ...but a "folder" holding exactly one book is not worth a shelf. Catalogs
-- like Project Gutenberg model every WORK as a subcatalog whose feed carries a
-- single acquisition entry, so drilling in landed the user on a one-tile shelf
-- they had to tap again and then back out of twice. The repo already flattens
-- those tiles once their child feed is cached (see the opds branch of
-- getBySource); this is the tap side of the SAME predicate --
-- Repo.opdsLoneChildBook, single-sourced deliberately, because a tile rendered
-- as a book that then drilled in like a folder would be worse than either.
--
-- So the tap is a decision over the child window, in three states:
--
--   * cached and it IS a folder of one -> open that book's own modal, and
--     nothing else. No _markOpdsNav: the arm is a one-shot licence for the NEXT
--     rebuild to reach the network, this path does not rebuild at all, and an
--     unspent arm would be picked up by whatever passive rebuild came next (a
--     cover landing, the 5s file poll) and spent on a fetch nobody asked for.
--   * cached and it is anything else (several books, subfolders, a feed with
--     more pages behind it) -> drill, armed, exactly as before.
--   * UNCACHED -> neither answer is knowable without asking the server, and the
--     tap is precisely the user action that licenses asking. Fetch the child
--     feed first, then re-run this decision against what landed.
--
-- The pre-fetch calls _opdsFetchMore DIRECTLY and arms nothing, the same shape
-- (and for the same reason) as _opdsRefresh: with no rebuild of ours to gate,
-- the arm would have nothing to gate and its tail rebuild stays passive. The
-- busy test is _opdsRefresh's rule widened to both markers -- a second Trapper
-- coroutine over a live one is the standby-leak hazard documented at
-- _opdsAfterPage's queue branch -- and applies ONLY to this branch: a cached
-- tile is pure local work, and refusing to open it during a download would be a
-- folder that cannot be opened for no reason.
--
-- no_fetch marks the re-entry from that fetch's completion callback, and is
-- what stops it looping. "The window is cached now" is NOT enough on its own:
-- a fetch that failed (server down, feed empty, user cancelled, Wi-Fi declined)
-- leaves the window exactly as uncached as it found it, having already shown
-- its own notification, and an unguarded re-entry would fetch again on every
-- round. One fetch per tap, then stay put.
--
-- The server key rides the synthetic filepath ("OPDS://<server_key>/nav/...")
-- rather than a field of its own, because that path is the one part of a
-- remote record guaranteed to survive a repo round trip (see
-- _isRemoteRecord). Both it and the feed_url are required: a frame missing
-- either would render an empty shelf with no way to fetch into it.
--
-- The frame is deliberately NOT persisted (_serializeDrillPath drops it), so
-- a relaunch lands the user back on the chip's root feed. Restoring it would
-- mean a network fetch at startup that nobody asked for.
function BookshelfWidget:_expandOpdsNav(rec, no_fetch)
    -- THE TWO SILENT RETURNS, now audible. A nav tile that does nothing when
    -- tapped is this function's known failure shape -- the cache-test comment
    -- below records an earlier one -- and both of these dropped the tap with
    -- no trace at all, which is a tap you cannot tell apart from a tap that
    -- never arrived. Cost is two string builds on a gesture, and only when the
    -- record is already malformed.
    if not (rec and rec.opds and rec.opds.feed_url) then
        logger.dbg(string.format(
            "[bookshelf perf] _expandOpdsNav: DROPPED, no feed_url (kind=%s "
            .. "fp=%s opds=%s)",
            tostring(rec and rec.kind), tostring(rec and rec.filepath),
            tostring(rec and rec.opds)))
        return
    end
    local server_key = type(rec.filepath) == "string"
                       and rec.filepath:match("^OPDS://([^/]+)/") or nil
    if not server_key then
        logger.dbg(string.format(
            "[bookshelf perf] _expandOpdsNav: DROPPED, filepath is not an "
            .. "OPDS key (fp=%s)", tostring(rec.filepath)))
        return
    end
    -- Say the tap landed, before doing anything that takes time. Not on the
    -- no_fetch re-entry: that one arrives after a fetch the reader already
    -- watched, and re-marking the tile there would only cost a second repaint.
    if not no_fetch then self:_markTapped(rec.filepath) end
    local _perf_t0 = _gettime()
    local feed_url = rec.opds.feed_url
    local label = rec.label or rec.display_title or rec.title
    -- fetched_at is the cache question, not #entries: a feed that legitimately
    -- came back empty has a stamp and no entries, and re-fetching that on every
    -- tap would be a round trip per tap against a server that already answered.
    -- OpdsWindow.load's miss shape stamps 0, so the two are never confusable.
    local OpdsWindow = require("lib/bookshelf_opds_window")
    local win = OpdsWindow.load(server_key, feed_url)
    -- Cached means "there is something to show", not "a timestamp exists".
    --
    -- Asking only about fetched_at was a silent dead end: the walk stamps the
    -- timestamp and appends the entries as separate steps, so a window can
    -- legitimately hold records with no stamp. This tap then dispatched a
    -- fetch, re-entered with no_fetch, failed the same test again and hit
    -- `return` - a tile that did NOTHING when tapped, over a feed with 26
    -- entries already cached. Seen on ManyBooks: Genres worked, Titles and
    -- Authors did not, and the only difference was the stamp.
    --
    -- Entries still win over the stamp for the empty case: a feed that
    -- genuinely came back empty has a stamp and no entries, and must not be
    -- re-fetched on every tap.
    local cached = (win.fetched_at or 0) > 0 or (win.count or 0) > 0
    logger.dbg(string.format(
        "[bookshelf perf] _expandOpdsNav: load=%.0fms cached=%s entries=%d %s",
        (_gettime() - _perf_t0) * 1000,
        tostring(cached), win.count or 0, tostring(feed_url)))
    if not cached then
        if no_fetch then return end
        if self:_opdsFetchBusy() then
            UIManager:show(require("ui/widget/notification"):new{
                text = _("The catalog is busy. Try again in a moment."),
            })
            return
        end
        -- want_count is a page's worth, not the one entry the decision needs:
        -- the likely outcome is a drill, and fetching less would land the user
        -- on a part-filled shelf that immediately fetched again.
        logger.dbg("[bookshelf perf] _expandOpdsNav: cache miss, dispatching feed fetch")
        self:_opdsFetchMore(
            { label = label,
              source = { kind = "opds", id = server_key, feed_url = feed_url } },
            self:_viewSize() or 24, false,
            function() self:_expandOpdsNav(rec, true) end)
        return
    end
    local lone = Repo.opdsLoneChildBook(server_key, feed_url)
    if lone then
        -- Same journey as a plain book tap: the first tap stages the
        -- flattened book in the hero (cover and description fetch included),
        -- and a second tap on the same tile opens the download modal. The
        -- lone child is a DIFFERENT record from the nav tile, so the
        -- "already previewed" test compares against the child's filepath.
        -- Micro-hero mode is excluded for the same reason as the book
        -- re-tap branch: the preview state is stale there, and the tap
        -- should swap the hero back to the book instead.
        if self._hero_mode ~= "micro" and self._preview_book
                and self._preview_book.filepath == lone.filepath then
            logger.dbg(string.format(
                "[bookshelf perf] _expandOpdsNav: lone re-tap -> modal, pre_modal=%.0fms",
                (_gettime() - _perf_t0) * 1000))
            self:_showRemoteBookInfo(lone)
            return
        end
        logger.dbg(string.format(
            "[bookshelf perf] _expandOpdsNav: lone flatten -> hero preview, pre_preview=%.0fms",
            (_gettime() - _perf_t0) * 1000))
        self:_previewBook(lone)
        return
    end
    -- The tap IS the user navigation that licenses a fetch: a subcatalog whose
    -- window is cached but short (a feed with more pages behind it) comes back
    -- flagged opds_needs_fetch from the rebuild _drillInto ends with, and
    -- _opdsAfterPage has to be allowed to act on it. Armed before the rebuild,
    -- like every other nav gesture (chip select, page turn, swipe-down).
    self:_markOpdsNav()
    self:_drillInto{
        kind    = "opds_nav",
        label   = label,
        payload = { server_key = server_key, feed_url = feed_url },
    }
end

-- ─── Dismiss / passthrough ───────────────────────────────────────────────────

-- force: open even when the start menu is set to Off. Set only by the explicit
-- "open start menu" gesture action; the footer button / focus slot leave it nil
-- so the Off guard still protects against a stale dispatcher action or queued
-- gesture.
function BookshelfWidget:_openStartMenu(force)
    if not force and self:_startMenuPosition() == "off" then return end
    -- Hot parking: a reader is still alive under the shelf, so the start menu's
    -- captured menu-action shortcuts would resolve against the READER menu --
    -- confusing on the home screen. Finish the park to the file manager first
    -- (the same move the koreader-menu gesture makes via Park.finishToMenu),
    -- then re-open against the live FM. runInFileManager real-closes the book
    -- and re-instantiates the FM; that blocks briefly on sidecar/DocCache work,
    -- so show the standard "Closing book…" affordance and defer a tick so it
    -- paints first. The re-open targets BookshelfWidget.live because the finish
    -- re-shows a fresh shelf widget; it is no longer parked, so it opens
    -- normally against the FileManager.
    local Park = require("lib/bookshelf_reader_park")
    if Park.isParked() then
        local msg
        if BookshelfSettings.nilOrTrue("show_close_msg") then
            local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
            if ok_im and InfoMessage then
                msg = InfoMessage:new{ text = _("Closing book…"), timeout = 0.0 }
                UIManager:show(msg)
                UIManager:setDirty(msg, function() return "partial", msg.dimen end)
            end
        end
        UIManager:forceRePaint()
        UIManager:nextTick(function()
            Park.runInFileManager(function()
                -- Close the message AND flush the shelf back over its region
                -- before opening the menu: the start-menu open animation
                -- snapshots the screen as its backdrop, so a still-present
                -- "Closing book…" would be baked into that backdrop and show as
                -- a fragment when the menu is later closed.
                if msg then
                    UIManager:close(msg)
                    UIManager:forceRePaint()
                end
                local live = BookshelfWidget.live
                if live then live:_openStartMenu(force) end
            end)
        end)
        return
    end
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
    -- Hot parking: a reader is parked underneath, so plainly closing the
    -- shelf would drop the user back INTO the book. Leaving the shelf
    -- means going to the file manager - real-close the parked book out
    -- to raw FM instead.
    local Park = require("lib/bookshelf_reader_park")
    if Park.closeShelfToFileManager(self) then return true end
    UIManager:close(self)
    return true
end

return BookshelfWidget
