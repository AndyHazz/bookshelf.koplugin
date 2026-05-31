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
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local Font            = require("ui/font")
local BFont           = require("lib/bookshelf_fonts")
local UIManager       = require("ui/uimanager")
local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Screen          = Device.screen

local _           = require("lib/bookshelf_i18n").gettext

local Repo        = require("lib/bookshelf_book_repository")
local Profiles    = require("lib/bookshelf_profiles")
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

local function _getSimpleUIBottombar()
    local ok, mod = pcall(require, "sui_bottombar")
    return ok and mod or nil
end

local function _getSimpleUIConfig()
    local ok, mod = pcall(require, "sui_config")
    return ok and mod or nil
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

local function _androidSafeModeEnabled()
    return Device:isAndroid()
        and BookshelfSettings.nilOrTrue("android_safe_mode")
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

function BookshelfWidget:_hasPrevPaginationTarget()
    return self.page > 1
        or #self._drilldown_path > 0
        or not self._chip_bar_hidden
end

function BookshelfWidget:_hasNextPaginationTarget()
    local total = self._total_pages or 1
    return self.page < total
        or (#self._drilldown_path == 0 and not self._chip_bar_hidden)
end

function BookshelfWidget:_simpleUIPageLabel()
    return string.format("%d of %d", self.page or 1, self._total_pages or 1)
end

function BookshelfWidget:_getSimpleUIBarContext()
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FM and FM.instance or nil
    local plugin = fm and fm._simpleui_plugin
    if not (fm and plugin and plugin._onTabTap) then return nil end

    local Bottombar = _getSimpleUIBottombar()
    local Config = _getSimpleUIConfig()
    if not (Bottombar and Config) then return nil end

    local total_h = Bottombar.TOTAL_H and Bottombar.TOTAL_H() or 0
    if total_h <= 0 then return nil end

    local tabs = Config.loadTabConfig and Config.loadTabConfig() or nil
    if type(tabs) ~= "table" or #tabs == 0 then return nil end

    local navpager_on = Config.isNavpagerEnabled and Config.isNavpagerEnabled() or false
    local active_action = plugin.active_action or tabs[1] or "home"
    local slot_count = navpager_on and (#tabs + 2)
        or ((Config.getNumTabs and Config.getNumTabs()) or #tabs)

    return {
        fm            = fm,
        plugin        = plugin,
        bottombar     = Bottombar,
        tabs          = tabs,
        active_action = active_action,
        navpager_on   = navpager_on,
        mode          = Config.getNavbarMode and Config.getNavbarMode() or nil,
        total_h       = total_h,
        slot_count    = slot_count,
        side_m        = Bottombar.SIDE_M(),
        top_sp        = Bottombar.TOP_SP(),
        bot_sp        = Bottombar.BOT_SP(),
        bar_h         = Bottombar.BAR_H(),
        sep_h         = Bottombar.SEP_H(),
    }
end

function BookshelfWidget:_simpleUIReservedBottom()
    local ctx = self._simpleui_bar_ctx or self:_getSimpleUIBarContext()
    return (ctx and ctx.total_h) or 0
end

function BookshelfWidget:_simpleUIBarTopY()
    local ctx = self._simpleui_bar_ctx
    if not ctx then return nil end
    return self.height - ctx.total_h + ctx.top_sp
end

function BookshelfWidget:_isInSimpleUIBottomBand(pos)
    local ctx = self._simpleui_bar_ctx
    if not (ctx and pos) then return false end
    return pos.y >= (self.height - ctx.total_h)
end

function BookshelfWidget:_isSimpleUIInPlaceAction(action_id)
    if action_id == "wifi_toggle"
            or action_id == "frontlight"
            or action_id == "power"
            or action_id == "stats_calendar"
            or action_id == "bookmark_browser" then
        return true
    end
    if action_id and action_id:match("^custom_qa_%d+$") then
        local ok, QA = pcall(require, "sui_quickactions")
        return ok and QA and QA.isInPlaceCustomQA and QA.isInPlaceCustomQA(action_id) or false
    end
    return false
end

function BookshelfWidget:_dispatchSimpleUIBarAction(action_id)
    local ctx = self._simpleui_bar_ctx
    if not (ctx and action_id) then return true end

    local plugin = ctx.plugin
    local fm = ctx.fm
    if self:_isSimpleUIInPlaceAction(action_id) then
        plugin:_onTabTap(action_id, fm)
        return true
    end

    UIManager:close(self)
    UIManager:nextTick(function()
        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
        local live_fm = (ok_fm and FM and FM.instance) or fm
        local live_plugin = live_fm and live_fm._simpleui_plugin or plugin
        if live_plugin and live_plugin._onTabTap then
            live_plugin:_onTabTap(action_id, live_fm or fm)
        end
    end)
    return true
end

function BookshelfWidget:_handleSimpleUIBottomBarTap(ev)
    local ctx = self._simpleui_bar_ctx
    if not (ctx and ev and ev.ges == "tap" and ev.pos) then return false end
    if not self:_isInSimpleUIBottomBand(ev.pos) then return false end

    local bar_y = self:_simpleUIBarTopY()
    if not bar_y then return true end
    local bar_x = ctx.side_m
    local bar_w = self.width - ctx.side_m * 2
    if ev.pos.x < bar_x or ev.pos.x >= (bar_x + bar_w)
            or ev.pos.y < bar_y or ev.pos.y >= (bar_y + ctx.bar_h) then
        return true
    end

    local widths = ctx.bottombar.getTabWidths(ctx.slot_count, bar_w)
    local local_x = ev.pos.x - bar_x
    local slot = nil
    local acc = 0
    for i = 1, ctx.slot_count do
        acc = acc + widths[i]
        if local_x < acc then
            slot = i
            break
        end
    end
    if not slot then return true end

    if ctx.navpager_on then
        if slot == 1 then
            self:_paginatePrev()
            return true
        elseif slot == ctx.slot_count then
            self:_paginateNext()
            return true
        end
        slot = slot - 1
    end

    local action_id = ctx.tabs[slot]
    if not action_id then return true end
    return self:_dispatchSimpleUIBarAction(action_id)
end

function BookshelfWidget:_wrapWithSimpleUIBottomBar(content_widget)
    local ctx = self._simpleui_bar_ctx
    self._simpleui_page_overlay_parent = nil
    self._simpleui_page_overlay_idx = nil
    if not ctx then
        return content_widget
    end

    local LineWidget = require("ui/widget/linewidget")
    local bar
    if ctx.navpager_on and ctx.bottombar.buildBarWidgetWithArrows then
        bar = ctx.bottombar.buildBarWidgetWithArrows(
            ctx.active_action,
            ctx.tabs,
            ctx.mode,
            self:_hasPrevPaginationTarget(),
            self:_hasNextPaginationTarget())
    else
        bar = ctx.bottombar.buildBarWidget(ctx.active_action, ctx.tabs)
    end
    local bar_y = self.height - ctx.total_h

    local sep_line = LineWidget:new{
        dimen = Geom:new{ w = self.width - ctx.side_m * 2, h = ctx.sep_h },
        background = ctx.bottombar.sepColor(),
        overlap_offset = { ctx.side_m, bar_y + ctx.top_sp - ctx.sep_h },
    }
    bar.overlap_offset = { 0, bar_y + ctx.top_sp }

    local bot_pad = LineWidget:new{
        dimen = Geom:new{ w = self.width, h = ctx.bot_sp },
        background = Blitbuffer.COLOR_WHITE,
        overlap_offset = { 0, self.height - ctx.bot_sp },
    }
    local overlay = self:_buildSimpleUIPaginationOverlay()
    local children = {
        content_widget,
        sep_line,
    }
    if overlay then
        children[#children + 1] = overlay
    end
    children[#children + 1] = bar
    children[#children + 1] = bot_pad
    local overlap = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{ w = self.width, h = self.height },
        unpack(children),
    }
    if overlay then
        self._simpleui_page_overlay_parent = overlap
        self._simpleui_page_overlay_idx = 3
    end
    return overlap
end

function BookshelfWidget:_buildSimpleUIPaginationOverlay()
    local ctx = self._simpleui_bar_ctx
    if not ctx then
        return nil
    end
    local overlay_h = math.max(Screen:scaleBySize(16), Size.item.height_default - Screen:scaleBySize(10))
    -- Anchor the page label to SimpleUI's separator instead of the top of the
    -- whole reserved navbar area. When SimpleUI's bar grows taller (e.g. icon
    -- labels), anchoring to total_h pushes this label up into the last shelf.
    local sep_y = self.height - ctx.total_h + (ctx.top_sp or 0) - (ctx.sep_h or 0)
    -- Optical correction: the bottom shelf shadows make the true midpoint feel
    -- a little high, so let the label sit slightly closer to the navbar rule.
    local optical_drop = Screen:scaleBySize(4)
    local overlay_y = math.max(0, sep_y - overlay_h + optical_drop)
    local label = TextWidget:new{
        text = self:_simpleUIPageLabel(),
        face = Font:getFace("smallinfofont", 13),
        bold = true,
    }
    local label_w = label:getSize().w
    local overlay_w = math.min(self.width, math.max(
        label_w + Size.padding.large * 2,
        Screen:scaleBySize(56)))
    local overlay_x = math.max(0, self.width - (ctx.side_m or 0) - overlay_w)
    local overlay = InputContainer:new{
        dimen = Geom:new{ w = overlay_w, h = overlay_h },
        CenterContainer:new{
            dimen = Geom:new{ w = overlay_w, h = overlay_h },
            label,
        },
    }
    overlay.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = overlay.dimen } },
    }
    overlay.onTap = function()
        self:_openSortMenu()
        return true
    end
    overlay.overlap_offset = { overlay_x, overlay_y }
    self._page_text_button = overlay
    return overlay
end

function BookshelfWidget:_refreshSimpleUIPageOverlay()
    if not self._simpleui_page_overlay_parent or not self._simpleui_page_overlay_idx then return end
    local parent = self._simpleui_page_overlay_parent
    local idx = self._simpleui_page_overlay_idx
    local old = parent[idx]
    local new = self:_buildSimpleUIPaginationOverlay()
    if not new then return end
    parent[idx] = new
    if parent.resetLayout then
        parent:resetLayout()
    end
    if old and old.free then
        UIManager:nextTick(function()
            pcall(function() old:free() end)
        end)
    end
end

function BookshelfWidget:init()
    local diag_init_t0 = _gettime()
    self.width  = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen  = Geom:new{ w = self.width, h = self.height }
    self.profile = Profiles.get(self.profile_key)
    if self.profile then
        self.chip = BookshelfSettings.read("active_chip_" .. self.profile.key)
            or Profiles.defaultChip(self.profile)
            or "latest"
        self._cursor = 1
    else
        self.chip = BookshelfSettings.read("active_chip") or "recent"
        local saved_cursor = BookshelfSettings.read("active_cursor")
        if saved_cursor and saved_cursor >= 1 then
            self._cursor = saved_cursor
        else
            local saved_page = BookshelfSettings.read("active_page") or 1
            local legacy_page_size = self:_isLandscape()
                and 5 or (self:_baseShelves() * self:_nCols())
            self._cursor = math.max(1, (saved_page - 1) * legacy_page_size + 1)
        end
    end
    self.page = 1
    -- Drill state persists across widget recreations (e.g. KOReader was
    -- restarted while the user had drilled into an author stack). The
    -- saved form is identifiers only -- _restoreDrillPath() re-hydrates
    -- via Repo.findGroup / Repo.buildBookMeta so cover_bbs are fresh
    -- (see memory feedback_image_disposable_shared_book).
    self._drilldown_path = {}
    local saved_drill = self.profile and nil or BookshelfSettings.read("drill_path")
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
        -- Hold-equivalent for keyboard / d-pad users. Bound to two
        -- chords so users have an option regardless of their device:
        --   * Menu key: instant; standard on Kindle / Kobo hardware.
        --   * Shift + Press: works on every keyboard (desktop, external
        --     keyboards, on-screen keyboards). Chord rather than
        --     long-press-on-Enter so we don't add latency to taps.
        self.key_events.BSKbHold     = {
            { "Menu" },
            { "Shift", "Press" },
        }
    end

    -- (Top-zone tap/swipe to open the FM menu is handled by the FileManager
    -- touch-zone passthrough in handleEvent below; no need to mirror those
    -- zones here. Doing so previously also ignored the user's
    -- `activation_menu` preference — fixed as a side benefit.)

    local diag_init_t_pre_rebuild = _gettime()
    self:_rebuild()
    self:_startStatusTimer()
    logger.dbg(string.format(
        "[bookshelf perf] BookshelfWidget:init: pre_rebuild=%.0fms rebuild+timer=%.0fms TOTAL=%.0fms chip=%s",
        (diag_init_t_pre_rebuild - diag_init_t0) * 1000,
        (_gettime() - diag_init_t_pre_rebuild) * 1000,
        (_gettime() - diag_init_t0) * 1000,
        self.chip))
end

function BookshelfWidget:_profileScope()
    return Profiles.scope(self.profile)
end

function BookshelfWidget:_profileChip(key)
    return Profiles.chip(self.profile, key or self.chip)
end

function BookshelfWidget:_profileSettingKey()
    if self.profile then
        return "active_chip_" .. self.profile.key
    end
    return "active_chip"
end

function BookshelfWidget:setProfile(profile_key)
    local profile = Profiles.get(profile_key)
    if self.profile == profile then return end
    self.profile_key = profile_key
    self.profile = profile
    self._drilldown_path = {}
    self._cursor = 1
    self.page = 1
    if profile then
        self.chip = BookshelfSettings.read("active_chip_" .. profile.key)
            or Profiles.defaultChip(profile)
            or "latest"
    else
        self.chip = BookshelfSettings.read("active_chip") or "recent"
    end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

function BookshelfWidget:refreshAfterReaderReturn()
    if self.softRefresh then
        return self:softRefresh()
    end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
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
        local ev = event.args[1]
        -- SimpleUI's navbar is part of our visible Bookshelf chrome in this
        -- fork, so handle it locally before upstream's FM-zone filter skips
        -- third-party zones.
        if self:_handleSimpleUIBottomBarTap(ev) then return true end
        if self:_isInSimpleUIBottomBand(ev and ev.pos) then return true end

        if not fm then return false end
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
    for _, entry in ipairs(self._drilldown_path) do
        local payload = entry and entry.payload
        if type(payload) == "table" then
            local lists = { payload.books, payload.series,
                            payload.authors, payload.genres,
                            payload.folders }
            for _, list in ipairs(lists) do
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
    for _, e in ipairs(self._drilldown_path) do
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
    if self.profile then
        BookshelfSettings.save(self:_profileSettingKey(), self.chip)
        return
    end
    BookshelfSettings.save("active_chip", self.chip)
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
    for _, e in ipairs(saved) do
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
            local g = Repo.findGroup(e.kind, e.label, self:_profileScope())
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
            and type(G_reader_settings.isTrue) == "function"
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
    self._simpleui_bar_ctx = self:_getSimpleUIBarContext()
    local usable_h = self.height - self:_simpleUIReservedBottom()

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
    local show_footer_row      = (not self._simpleui_bar_ctx)
                                 or self._selection:isActive()
    local label_h              = show_footer_row and footer_h or 0

    -- Detect "all chips disabled" early so the hero can grow into the
    -- chip strip's vertical footprint when it would otherwise be empty.
    -- The chip strip stays visible whenever a drill-down path is active
    -- (so the user can navigate back via the breadcrumb), even if every
    -- chip is disabled.
    local TabModel = require("lib/bookshelf_tab_model")
    local active_chips = {}
    if self.profile then
        for _, chip in ipairs(self.profile.chips or {}) do
            active_chips[#active_chips + 1] = { key = chip.key, label = chip.label }
        end
    else
        -- "Currently reading" action chip at the LEFT edge: always visible so
        -- it serves as a stable anchor and a perma-affordance.
        local _lastfile = Repo.getCurrent and Repo.getCurrent()
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
        for _, tab in ipairs(TabModel.getActive()) do
            local display = tab.label or ""
            if tab.icon and tab.icon ~= "" then
                display = tab.icon .. " " .. display
            end
            active_chips[#active_chips + 1] = { key = tab.id, label = display }
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
        for _, tab in ipairs(TabModel.DEFAULTS()) do
            active_chips[#active_chips + 1] = { key = tab.id, label = tab.label }
        end
    end
    -- If the currently-selected chip was just disabled, switch to the
    -- first surviving chip so render doesn't try to fetch from a
    -- disabled chip's data source.
    local active_in_set = false
    for _, c in ipairs(active_chips) do
        if c.key == self.chip then active_in_set = true; break end
    end
    if not active_in_set then
        -- Skip action chips (current, search) — they have no data source.
        -- Fall back to the first nav chip instead.
        self.chip = active_chips[1].key
        for _, c in ipairs(active_chips) do
            if not c.action then self.chip = c.key; break end
        end
        BookshelfSettings.save(self:_profileSettingKey(), self.chip)
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
    for _, c in ipairs(active_chips) do
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
                            or (Repo.getCurrent and Repo.getCurrent())
        local probe_row  = probe_book and HeroCard.buildStatusRow(
                                probe_book, self:_buildDeviceState(),
                                content_w, false)
        local strip_minimum = probe_row and probe_row:getSize().h
                              or Screen:scaleBySize(20)
        shelf_h = math.max(1, math.floor(
            (usable_h - strip_minimum - chip_contrib - label_h - total_pad)
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
        -- _nShelves() now picks n dynamically to keep hero >= MIN_HERO_SHARE
        -- of available height (issue #36), so the natural-aspect shelf
        -- math should already satisfy the floor in most cases. The clamp
        -- below is the backstop: catches landscape (where slot_h_natural
        -- exceeds available height and the subtraction goes negative) and
        -- any edge case where n_shelves landed at 1 but slot_h alone still
        -- crowds the hero. Covers shrink uniformly via ShelfRow's slot-h
        -- cap with aspect preservation, so cover/title pairs stay readable.
        local available  = usable_h - chip_contrib - label_h - total_pad
        local min_hero_h = math.floor(available * MIN_HERO_SHARE)
        shelf_h = slot_h_natural
        hero_h  = usable_h - n_shelves * shelf_h - chip_contrib - label_h - total_pad
        if hero_h < min_hero_h then
            shelf_h = math.max(1, math.floor((available - min_hero_h) / n_shelves))
            hero_h  = math.max(min_hero_h,
                usable_h - n_shelves * shelf_h - chip_contrib - label_h - total_pad)
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
        chip_pill_label = "Search results"
    else
        local profile_chip = self:_profileChip(self.chip)
        local _t = not profile_chip and TabModel.getById(self.chip) or nil
        chip_pill_label = (profile_chip and profile_chip.label)
            or (_t and _t.label)
            or self.chip
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
            local chip_kind = (profile_chip and profile_chip.kind)
                or (_t and _t.source and _t.source.kind)
                or self.chip
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
                -- The drill-down path is preserved: the user is asking
                -- to pop their open book back into the hero slot, not
                -- to leave the stack/folder they're browsing.
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
            self.page            = 1
            BookshelfSettings.save(self:_profileSettingKey(), key)
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
            if self.profile then return end
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
    -- Cursor-based pagination keeps the first visible book stable across
    -- expand/collapse while page remains a derived display label.
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
    local total = _total_hint or #all_items
    local total_pages
    if total <= VIEW_SIZE then
        total_pages = 1
    else
        total_pages = math.ceil(total / VIEW_SIZE)
    end
    self._total_pages = total_pages
    self._total_items = total
    local cursor_before_clamp = self._cursor
    self:_clampCursor(total)
    self:_syncPageFromCursor()
    if _total_hint and self._cursor ~= cursor_before_clamp then
        all_items, _total_hint = self:_fetchChipItems(MAX_FETCH)
        all_items = all_items or {}
        total = _total_hint or #all_items
        if total <= VIEW_SIZE then
            total_pages = 1
        else
            total_pages = math.ceil(total / VIEW_SIZE)
        end
        self._total_pages = total_pages
        self._total_items = total
        self:_clampCursor(total)
        self:_syncPageFromCursor()
    end
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
        local TabModel = require("lib/bookshelf_tab_model")
        local _tab = TabModel.getById(self.chip)
        local _source_kind = (_tab and _tab.source and _tab.source.kind)
                              or self.chip
        local _is_home_source = _source_kind == "all" or _source_kind == "library"
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
            placeholder_text = _("No books here yet \xC2\xB7 Pick a folder to use as your KOReader library and books in it will appear here.")
        else
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
        if _tab and _tab.filter and _tab.filter.statuses
                and next(_tab.filter.statuses) then
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

        local headline_text, sub_text
        local sep_start, sep_end = placeholder_text:find(" \xC2\xB7 ", 1, true)
        if sep_start then
            headline_text = placeholder_text:sub(1, sep_start - 1)
            sub_text      = placeholder_text:sub(sep_end + 1)
        else
            headline_text = placeholder_text
            sub_text      = nil
        end

        local VerticalSpan = require("ui/widget/verticalspan")
        -- The placeholder card stops short of the screen-anchored footer
        -- (pagination + bulk-select bar). Without subtracting footer_h
        -- the card extended through the bottom of the screen and the
        -- footer chrome painted on top of the card border / set-home
        -- button.
        local card_h
        if hide_chip_bar then
            card_h = usable_h - 3 * PAD - hero_h - label_h
        else
            card_h = usable_h - 4 * PAD - hero_h - chip_h - label_h
        end
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
                    local filemanagerutil = require("apps/filemanager/filemanagerutil")
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
        if show_footer_row and self._selection:isActive() then
            local empty_footer = self:_buildFooterRow(content_w, 1, FOOTER_H)
            empty_overlap[#empty_overlap + 1] = BottomContainer:new{
                dimen = Geom:new{ w = self.width, h = usable_h - FOOTER_BOTTOM_MARGIN },
                empty_footer,
            }
        end
        self[1] = self:_wrapWithSimpleUIBottomBar(empty_overlap)
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
        local slack = usable_h - pre_rows_h - rows_block_h
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
    local layout_slack = usable_h - layout_sum
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
    local footer_idx = nil
    if show_footer_row then
        -- Build the footer row and anchor it.
        local footer_row = self:_buildFooterRow(content_w, total_pages, FOOTER_H)
        overlap_group[#overlap_group + 1] = BottomContainer:new{
            dimen = Geom:new{ w = self.width, h = usable_h - FOOTER_BOTTOM_MARGIN },
            footer_row,
        }
        footer_idx = #overlap_group   -- index of the footer in overlap_group
    end

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
        local absorber_bottom = usable_h
        local left_dim  = Geom:new{
            x = 0,
            y = absorber_bottom - corner_h,
            w = corner_w,
            h = corner_h,
        }
        local right_dim = Geom:new{
            x = self.dimen.w - corner_w,
            y = absorber_bottom - corner_h,
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
    self[1] = self:_wrapWithSimpleUIBottomBar(overlap_group)
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
    -- preload, re-syncs cache capacity, and is Android-gated internally.
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
                and BookshelfWidget._coverNeedsResize(info, cover_specs) then
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
                cover_specs = cover_specs,
            }
        end
    end
    for _, item in ipairs(items or {}) do
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
    -- Android safe mode (issue 87): BIM:extractInBackground forks a subprocess
    -- (FFIUtil.runInSubProcess -> C.fork()). On the reporter's Android device
    -- (Galaxy S24 Ultra, Android 16, Vulkan renderer) this aborts at launch
    -- with "FORTIFY: pthread_mutex_lock on a destroyed mutex" in hwuiTask0 --
    -- the classic fork-in-a-multithreaded-process mutex corruption, surfaced
    -- by that device's render thread. Default to gating the fork on Android,
    -- but expose a toggle so users can test whether their device is affected.
    if _androidSafeModeEnabled() then return false end
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
    -- Android safe mode: with the extraction fork gated there's nothing to
    -- poll for (no subprocess will complete), so skip the watch loop entirely
    -- rather than let it back off against work that never runs.
    if _androidSafeModeEnabled() then return end
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
    if tip and tip.kind == "search" then
        local fresh = {}
        for _, f in ipairs(tip.payload.folders or {}) do
            fresh[#fresh + 1] = {
                kind       = "folder",
                path       = f.path,
                label      = f.label,
                first_book = f.first_book_fp and Repo.buildBookMeta(f.first_book_fp),
            }
        end
        for _, name in ipairs(tip.payload.author_names or {}) do
            local g = Repo.findGroup("author", name, self:_profileScope())
            if g then fresh[#fresh + 1] = g end
        end
        for _, name in ipairs(tip.payload.series_names or {}) do
            local g = Repo.findGroup("series", name, self:_profileScope())
            if g then fresh[#fresh + 1] = g end
        end
        for _, name in ipairs(tip.payload.genre_names or {}) do
            local g = Repo.findGroup("genre", name, self:_profileScope())
            if g then fresh[#fresh + 1] = g end
        end
        for _, fp in ipairs(tip.payload.book_fps or {}) do
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
        local offset = (self._cursor or 1) - 1
        local stop = math.min(offset + self:_viewSize(), total)
        local fresh = {}
        for i = offset + 1, stop do
            local b = books[i]
            local nb = b.filepath and Repo.buildBookMeta(b.filepath) or b
            fresh[#fresh + 1] = nb
        end
        return fresh, total
    end
    -- For the all-chip and folder drill-down, fetch only the current page
    -- slice and return the total count as a second value. Callers use the
    -- count to compute total_pages without hydrating the full item list.
    local offset    = (self._cursor or 1) - 1
    local LIMIT     = self:_viewSize()
    local profile_scope = self:_profileScope()
    local folder_read_summary = self.profile ~= nil
    local TabModel = require("lib/bookshelf_tab_model")
    local tab      = TabModel.getById(self.chip)
    if tip and tip.kind == "folder" then
        if self.profile then
            return Repo.getAll(tip.payload.path, LIMIT, offset, {
                sort_priority       = Profiles.folderSortPriority(self.profile),
                reverse             = false,
                folder_read_summary = folder_read_summary,
                lazy_cover          = true,
            })
        end
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
    local profile_chip = self:_profileChip(self.chip)
    if profile_chip and profile_chip.kind == "folder" then
        return Repo.getAll(profile_chip.path, LIMIT, offset, {
            sort_priority       = Profiles.folderSortPriority(self.profile),
            reverse             = false,
            folder_read_summary = folder_read_summary,
            lazy_cover          = true,
        })
    end
    if profile_chip and profile_chip.kind == "next" then
        return Repo.getNextUnreadInSeries(LIMIT, offset, profile_scope)
    end
    if profile_chip and profile_chip.kind == "latest" then
        return Repo.getLatest(LIMIT, offset, profile_scope, fetch_opts)
    end
    if profile_chip and profile_chip.kind == "authors" then
        return Repo.getAuthors(LIMIT, offset, nil, profile_scope)
    end
    if tab then
        return Repo.getBySource(tab.source, tab.filter, tab.sort_priority, offset, LIMIT, profile_scope, fetch_opts)
    end
    return Repo.getBySource({ kind = self.chip }, nil, nil, offset, LIMIT, profile_scope, fetch_opts)
end

-- _chipLabel()  — human-readable shelf heading for the active chip.
function BookshelfWidget:_chipLabel()
    local tip = self._drilldown_path[#self._drilldown_path]
    if tip then
        return tip.label or "Drill-down"
    end
    local profile_chip = self:_profileChip(self.chip)
    if profile_chip then
        return profile_chip.label or self.chip
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
        current = Repo.buildBook(self._preview_book.filepath) or self._preview_book
        self._preview_book = current
    else
        current = Repo.getCurrent()
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
                local ReadCollection = require("readcollection")
                local in_collections = ReadCollection.getCollectionsWithFile
                    and ReadCollection:getCollectionsWithFile(book.filepath) or {}
                local pill_specs = bw:_buildPillSpecs(book, in_collections, nil)
                -- Scale the tag pills with the Hero card font-size knob, so the
                -- whole hero (text + tags) grows/shrinks together. Base 12 = the
                -- prior fixed size, so 100% is unchanged.
                local hero_scale = (BookshelfSettings.read("font_scale") or 100) / 100
                local pill_size  = math.max(8, math.floor(12 * hero_scale + 0.5))
                return bw:_buildPillGroup(pill_specs, pill_w, 2, pill_size)
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
            self:_openBookMenu(b)
        end,
        on_description_tap = function(b) self:_showFullDescription(b) end,
        on_rating_change   = function(b, r) self:_setBookRating(b, r) end,
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
    -- In expanded mode the hero is hidden, so there's no preview to
    -- highlight. When tap_to_open_double is enabled and the user has
    -- tapped a cover once (waiting for the confirm tap), surface that
    -- here so the cover paints with its focus ring.
    if not selected_filepath and self._expanded and self._tap_selected_fp then
        selected_filepath = self._tap_selected_fp
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
        for _, c in ipairs(TabModel.getActive()) do
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
                if BookshelfSettings.isTrue("tap_to_open_double")
                        and bw._tap_selected_fp ~= b.filepath then
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
            bw:_openBookMenu(b)
        end,
        on_series_tap     = function(s) bw:_expandSeries(s) end,
        on_series_hold    = function(s) bw:_openGroupMenu(s, "series") end,
        on_author_tap     = function(g) bw:_expandAuthor(g) end,
        on_author_hold    = function(g) bw:_openGroupMenu(g, "author") end,
        on_genre_tap      = function(g) bw:_expandGenre(g) end,
        on_genre_hold     = function(g) bw:_openGroupMenu(g, "genre") end,
        on_tag_tap        = function(g) bw:_expandTag(g) end,
        on_tag_hold       = function(g) bw:_openGroupMenu(g, "tag") end,
        on_folder_tap     = function(f) bw:_expandFolder(f) end,
        on_folder_hold    = function(f) bw:_openFolderMenu(f) end,
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
    local function go(p)
        return function()
            local view = bw:_viewSize()
            bw._cursor = math.max(1, (p - 1) * view + 1)
            bw:_clampCursor()
            bw:_syncPageFromCursor()
            bw:_swapShelvesInPlace()
        end
    end
    -- Long-press ±10: skip 10 pages instead of 1. Clamped via go() so we
    -- can't land outside [1, total_pages] regardless of how many holds
    -- the user fires. Returns nil rather than a no-op callback when the
    -- button is disabled so Button hides the long-press affordance too.
    local function skip(direction)
        local target = self.page + direction * 10
        if target < 1            then target = 1 end
        if target > total_pages  then target = total_pages end
        if target == self.page then return nil end
        return go(target)
    end
    -- margin/bordersize swap: every button allocates the same outer footprint
    -- (margin + bordersize = focus_border) so moving focus never shifts layout.
    -- Focused: bordersize = focus_border (visible thick ring), margin = 0.
    -- Unfocused: bordersize = 0 (invisible), margin = focus_border (slack space).
    local function bm(k) return (focused_btn == k) and 0           or focus_border end
    local function bs(k) return (focused_btn == k) and focus_border or 0           end
    local function br(k) return (focused_btn == k) and focus_radius or nil         end
    local first = Button:new{
        icon = "chevron.first", icon_width = chev_size, icon_height = chev_size,
        width      = slot(SLOT_EDGE),
        callback   = go(1),
        margin     = bm("first"), bordersize = bs("first"), radius = br("first"),
        enabled    = self.page > 1, show_parent = self,
    }
    local prev = Button:new{
        icon = "chevron.left",  icon_width = chev_size, icon_height = chev_size,
        width         = slot(SLOT_STEP),
        callback      = go(self.page - 1),
        hold_callback = skip(-1),
        margin        = bm("prev"), bordersize = bs("prev"), radius = br("prev"),
        enabled       = self.page > 1, show_parent = self,
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
        callback      = go(self.page + 1),
        hold_callback = skip(1),
        margin        = bm("next"), bordersize = bs("next"), radius = br("next"),
        enabled       = self.page < total_pages, show_parent = self,
    }
    local last = Button:new{
        icon = "chevron.last", icon_width = chev_size, icon_height = chev_size,
        width      = slot(SLOT_EDGE),
        callback   = go(total_pages),
        margin     = bm("last"), bordersize = bs("last"), radius = br("last"),
        enabled    = self.page < total_pages, show_parent = self,
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
    for _, b in ipairs({first, prev, page_text, next_btn, last}) do
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
    local hit_extension   = Screen:scaleBySize(12)
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
    end
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
        input       = tostring(bw.page),
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
    local cursor_before_clamp = self._cursor
    self:_clampCursor(total)
    self:_syncPageFromCursor()
    if _total_hint and self._cursor ~= cursor_before_clamp then
        all_items, _total_hint = self:_fetchChipItems(MAX_FETCH)
        all_items = all_items or {}
        total = _total_hint or #all_items
        if total <= VIEW_SIZE then
            total_pages = 1
        else
            total_pages = math.ceil(total / VIEW_SIZE)
        end
        self._total_pages = total_pages
        self._total_items = total
        self:_clampCursor(total)
        self:_syncPageFromCursor()
    end
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
    local new_footer_anchor = nil
    if d.footer_overlap_idx then
        local BottomContainer = require("ui/widget/container/bottomcontainer")
        local new_footer_row = self:_buildFooterRow(d.content_w, total_pages, d.FOOTER_H)
        local footer_anchor_h = self.height - self:_simpleUIReservedBottom()
        new_footer_anchor = BottomContainer:new{
            dimen = Geom:new{ w = self.width, h = footer_anchor_h - d.FOOTER_BOTTOM_MARGIN },
            new_footer_row,
        }
    end

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
    local old_footer = (self._overlap_group and d.footer_overlap_idx)
        and self._overlap_group[d.footer_overlap_idx] or nil
    if self._overlap_group and d.footer_overlap_idx and new_footer_anchor then
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
    self:_refreshSimpleUIPageOverlay()
    logger.dbg(string.format("[bookshelf perf] _swapShelves: TOTAL=%.0fms page=%d/%d items=%d chip=%s",
        (_gettime() - _perf_t0) * 1000, self.page, self._total_pages or 0,
        self._total_items or 0, self.chip))
    UIManager:setDirty(self, "ui")
    -- Pagination via _swapShelvesInPlace bypasses _rebuild's persist hook;
    -- repeat the save here so a forward/back swipe is enough to land back
    -- on the right page after a book read or KOReader restart.
    self:_persistNavState()
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

    -- _inner_vgroup[idx] may be the row HorizontalGroup directly, OR a
    -- CenterContainer wrapping it (kicks in when slot_w is shrunk to
    -- preserve cover aspect — see lib/bookshelf_shelf_row.lua:298-305),
    -- OR (expanded mode) the slot itself may be an InputContainer wrapping
    -- VerticalGroup{ spine, title }. Descend up to 3 levels looking for a
    -- container whose direct children include a SpineWidget with the
    -- target filepath.
    local function descend_find_spine(node, fp, depth)
        if not node or depth > 3 then return nil, nil end
        for i, c in ipairs(node) do
            if c and c.book and c.book.filepath == fp then
                -- Found a direct SpineWidget child — return the container
                -- holding it (for slot replacement) and the index.
                return node, i, c
            end
        end
        -- No direct match — descend into children.
        for _, c in ipairs(node) do
            if c then
                local parent, idx, spine = descend_find_spine(c, fp, depth + 1)
                if parent then return parent, idx, spine end
            end
        end
        return nil, nil, nil
    end

    local function find_and_swap(root, fp, want_selected)
        if not fp then return end
        local parent, idx, old_spine = descend_find_spine(root, fp, 0)
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
    for r = 1, (d.n_shelves or 2) do
        local idx = d.shelf_top_idx + 2 * (r - 1)
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
    UIManager:setDirty(self, "ui")
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
    for _, key in ipairs(Regions.ORDER) do
        local r = resolved[key]
        if r and not r.disabled and type(r.template) == "string" then
            for _, name in ipairs(tokens) do
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
    -- Cancel any pending cover-preload chunks (next-page warm-up). Open-book
    -- and teardown both route through here, so the deferred decode never
    -- fires against a backgrounded / torn-down widget.
    self:_cancelPreload()
    -- Chip preload is the one-shot background task; cancel its in-flight
    -- chunks too. _chip_preload_done is intentionally NOT reset -- if the
    -- pre-warm got far enough before being cancelled, those covers stay
    -- cached and we don't want to re-do the work.
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
            self.page        = self.page - 1
            self._cursor_idx = view_size
            self:_swapShelvesInPlace()
        end
        return true
    end

    if new_idx > view_size then
        local total = self._total_pages or 1
        if self.page < total then
            self.page        = self.page + 1
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
    if not d.footer_overlap_idx then
        self:_refreshSimpleUIPageOverlay()
        return
    end
    local total  = self._total_pages or 1
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local new_row    = self:_buildFooterRow(d.content_w, total, d.FOOTER_H)
    local footer_anchor_h = self.height - self:_simpleUIReservedBottom()
    local new_anchor = BottomContainer:new{
        dimen = Geom:new{ w = self.width, h = footer_anchor_h - d.FOOTER_BOTTOM_MARGIN },
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
            if total <= 1 then return true end   -- single page: footer has nothing actionable
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
            self._cursor = self:_maxCursor(self._total_items)
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
-- the Menu key OR Shift+Press chord (defined in init). Dispatches to
-- the touch on_hold-equivalent for the currently focused zone:
--   hero  → _openBookMenu(book) on the previewed/lastfile
--   chips → on_hold(chip_key) which opens the chip editor
--           (action chips and breadcrumb mode get no menu)
--   grid  → _openBookMenu for books, _openGroupMenu for stacks /
--           folders. Books in selection mode are suppressed (matching
--           the touch contract); stacks in selection mode still open
--           the Pin / Add / Remove dialog.
function BookshelfWidget:onBSKbHold()
    if self._focus_zone == "hero" then
        if self._selection and self._selection:isActive() then return true end
        local book = self._preview_book
            or (Repo.getCurrent and Repo.getCurrent())
        if book then
            self:_clearDpadFocus()
            self:_openBookMenu(book)
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
            self:_openBookMenu(item)
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
    self.page            = 1
    BookshelfSettings.save(self:_profileSettingKey(), key)
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
            and type(G_reader_settings.isTrue) == "function"
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
        logger.dbg(string.format(
            "[bookshelf perf] paintTo: FIRST first_paint=%.0fms chip=%s",
            (_gettime() - _diag_paint_t0) * 1000, self.chip))
        return
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
    local footer_full_h = Screen:scaleBySize(32) + 2 * Screen:scaleBySize(4)
                         + Screen:scaleBySize(12)
    local has_simpleui = self._simpleui_bar_ctx ~= nil
        or self:_getSimpleUIBarContext() ~= nil
    local show_footer_row = (not has_simpleui)
        or (self._selection and self._selection:isActive())
    local footer_h = show_footer_row and footer_full_h or 0
    return PAD, content_w, chip_h, footer_h
end

-- Cover size buckets: each maps to a target physical cover width in
-- screen-scaled units. The actual n_cols emerges from how many of these
-- fit in content_w (with the standard PAD between them), so the same
-- bookshelf-size setting produces consistent physical cover sizes across
-- portrait and landscape, and across devices with different aspect
-- ratios (a Palma's narrow screen lands on fewer columns than a Kindle's
-- wider one, but each cover stays the same size on the user's eye).
-- Numbers chosen so the medium default lands on 4 cols on a typical
-- Kindle portrait (the pre-rework default), 5 in landscape, and degrades
-- gracefully on narrower screens.
local COVER_SIZE_TARGET_DP = {
    small  = 120,
    medium = 155,
    large  = 200,
}

-- Hero size buckets: how many natural-cover rows the hero claims in
-- collapsed mode. Two options because in practice only "1 row" and "2
-- rows" give visibly different layouts; finer grades all collapsed to
-- one of the two outcomes once max_rows was integer-rounded.
local HERO_SIZE_ROWS = {
    regular = 1,
    large   = 2,
}

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
    local usable_h = self.height - self:_simpleUIReservedBottom()
    local available = usable_h - outer_top_pad - strip_minimum - hero_chip_pad
                    - chip_h - chip_to_row_pad - footer_h
    local rows = math.max(1, math.floor(available / row_h))

    -- When Bookshelf is embedded above SimpleUI's navbar, the reserved bottom
    -- band can drop the natural 2:3 row budget from 3 rows to 2. The render
    -- path already shrinks ShelfRow heights proportionally, so allow one
    -- extra row if it can still be kept at a readable size. This preserves the
    -- pre-2.3 density without letting very small screens explode into tiny
    -- thumbnails.
    local has_simpleui = self._simpleui_bar_ctx ~= nil
        or self:_getSimpleUIBarContext() ~= nil
    if has_simpleui then
        local min_row_h = math.max(1, math.floor(row_h * 0.70))
        local shrink_rows = math.max(1, math.floor(available / min_row_h))
        rows = math.max(rows, math.min(rows + 1, shrink_rows))
    end

    return rows
end

-- _baseShelves() — non-expanded shelf count. The hero claims
-- HERO_SIZE_ROWS rows of vertical space; the rest of the screen becomes
-- shelves at natural 2:3 aspect.
function BookshelfWidget:_baseShelves()
    local n_max = self:_maxRows()
    local eaten = HERO_SIZE_ROWS[_readHeroSize()] or 1
    return math.max(1, n_max - eaten)
end

-- _nShelves() — shelf row count for the current mode.
--   collapsed → _baseShelves() (= _maxRows - hero rows eaten)
--   expanded  → _maxRows() (hero collapses to a status strip so all
--                          rows the screen can natively hold render)
function BookshelfWidget:_nShelves()
    if self._expanded then return self:_maxRows() end
    return self:_baseShelves()
end

-- _nCols() — column count per shelf row. The cover-size setting picks a
-- target physical cover width (DPI-scaled); n_cols is then "how many of
-- these fit in content_w with the standard PAD between them". Same path
-- for portrait + landscape so the same setting gives consistent physical
-- cover sizes across orientations — landscape just lands on more columns
-- because the screen is wider.
function BookshelfWidget:_nCols()
    local PAD, content_w = self:_layoutPrimitives()
    local target_dp     = COVER_SIZE_TARGET_DP[_readCoverSize()] or 170
    local target_slot_w = Screen:scaleBySize(target_dp)
    if target_slot_w < 1 then return 4 end
    local n = math.floor((content_w + PAD) / (target_slot_w + PAD))
    -- Floor at 2 so even very narrow / sub-target screens (small phones)
    -- still show a grid; ceiling at 8 to keep the per-cover width above
    -- the readability threshold even on wide-aspect landscape tablets.
    return math.max(2, math.min(8, n))
end

-- _pageSize() — page-advance step. Matches the current view so paging
-- forward reveals a full new view without row overlap.
function BookshelfWidget:_pageSize()
    if self:_isLandscape() then return 5 end
    return self:_nShelves() * self:_nCols()
end

function BookshelfWidget:_syncPageFromCursor()
    local view  = self:_viewSize()
    local total = self._total_items or 0
    local last_visible = (self._cursor or 1) + view - 1
    if total > 0 and last_visible > total then last_visible = total end
    self.page = math.max(1, math.ceil(last_visible / view))
    if self._total_pages and self.page > self._total_pages then
        self.page = self._total_pages
    end
end

function BookshelfWidget:_maxCursor(total)
    local view = self:_viewSize()
    if total and total > 0 then
        local n_pages = math.max(1, math.ceil(total / view))
        return (n_pages - 1) * view + 1
    end
    local n_pages = math.max(1, self._total_pages or 1)
    return (n_pages - 1) * view + 1
end

function BookshelfWidget:_clampCursor(total)
    if total ~= nil and total <= 0 then
        self._cursor = 1
        return
    end
    local mx = self:_maxCursor(total)
    if (self._cursor or 1) > mx then self._cursor = mx end
    if (self._cursor or 1) < 1 then self._cursor = 1 end
end

function BookshelfWidget:_advanceCursor(delta_views, total)
    local view = self:_viewSize()
    self._cursor = (self._cursor or 1) + delta_views * view
    if self._cursor < 1 then self._cursor = 1 end
    self:_clampCursor(total)
end

-- _viewSize() — books shown per page: current rows × cols.
-- Standard normal: 8, standard expanded: 12, tall normal: 9, tall expanded: 12.
-- Landscape normal: 5, landscape expanded: 10.
function BookshelfWidget:_viewSize()
    return self:_nShelves() * self:_nCols()
end

-- _previewNeighbourBook(direction) — cycle self._preview_book through the
-- current chip's books in order (skipping series groups, which can't be
-- previewed). direction = +1 for next, -1 for previous. Wraps at edges.
-- Crosses page boundaries by recomputing self.page from the target book's
-- position in the unsliced list.
function BookshelfWidget:_previewNeighbourBook(direction)
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
    -- Update cursor so the new preview is on the visible shelf — otherwise
    -- _previewBook's swap-shelves-in-place would highlight a book that
    -- isn't currently rendered.
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
local PRELOAD_CHUNK         = 4      -- covers warmed per tick
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
    while done < chunk and #jobs > 0 do
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

-- Build the cover-job queue for one of two scopes:
--   "next"  -> next page of the current chip in the paged direction.
--              Cheap fetch (one chip, lazy_cover), small queue (~8 covers).
--   "chips" -> first page of each OTHER active chip. Heavier (each chip's
--              _fetchChipItems runs sequentially) -- runs as a one-shot
--              background task, NOT on every page turn.
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
    elseif phase == "chips" then
        -- Top level only: _fetchChipItems short-circuits to the drilldown
        -- branch when a tip is present, so borrowing self.chip mid-drilldown
        -- would fetch the wrong list.
        if #(self._drilldown_path or {}) ~= 0 then return jobs end
        for _i, key in ipairs(self._active_chip_keys or {}) do
            if key ~= self.chip then
                self:_collectPageCovers(jobs, seen, key, 1, w, h)
            end
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
    if not self._chip_preload_queue then
        self._chip_preload_counters = { decoded = 0, already = 0, failed = 0 }
        local _qb_t0 = _gettime()
        local ok, jobs = pcall(self._buildPhaseJobs, self, "chips", {})
        self._chip_preload_queue = (ok and jobs) or {}
        self._chip_preload_total = #self._chip_preload_queue
        logger.dbg(string.format(
            "[bookshelf perf] preload-chips: built in %.0fms size=%d",
            (_gettime() - _qb_t0) * 1000, self._chip_preload_total))
    end
    local q = self._chip_preload_queue
    if q and #q > 0 then
        _warmChunk(q, PRELOAD_CHUNK, self._chip_preload_counters)
    end
    if not q or #q == 0 then
        if self._chip_preload_total > 0 then
            local c = self._chip_preload_counters
            logger.dbg(string.format(
                "[bookshelf perf] preload-chips: done warmed=%d already=%d failed=%d folders=%d progress=%d total=%d",
                c.decoded, c.already, c.failed,
                c.folders or 0, c.progress or 0, self._chip_preload_total))
        end
        -- Mark as done so subsequent _rebuilds don't re-trigger.
        self._chip_preload_done = true
        self._chip_preload_fn = nil
        self._chip_preload_queue = nil
        return
    end
    if self._chip_preload_fn then
        UIManager:scheduleIn(PRELOAD_TICK_S, self._chip_preload_fn)
    end
end

-- One-shot trigger: schedule chip preload if conditions are right and we
-- haven't already done it this session. Idempotent and cheap to call from
-- _rebuild on every invocation; gated internally.
function BookshelfWidget:_maybeStartChipPreload()
    if self._chip_preload_done then return end
    if self._chip_preload_fn then return end  -- already in flight
    -- Android safe mode: the always-on background preload is implicated in an
    -- Android/HWUI crash (issue 87). Keep it off by default on Android, but
    -- allow users to disable safe mode when testing unaffected devices.
    if _androidSafeModeEnabled() then return end
    if #(self._drilldown_path or {}) ~= 0 then return end
    self:_applyCoverCacheBudget()
    self._chip_preload_fn = function() self:_chipPreloadStep() end
    UIManager:scheduleIn(CHIP_PRELOAD_DELAY_S, self._chip_preload_fn)
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
    -- Android safe mode: the periodic file-poll is another always-on
    -- background task. Sideloaded-book auto-detect pauses while safe mode is
    -- on; manual swipe-down refresh still works.
    if _androidSafeModeEnabled() then return end
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
            -- only re-walks the active chip. Re-arm the chip preload so
            -- subsequent taps on other chips don't pay the full walk cost.
            self._chip_preload_done = false
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
    if _androidSafeModeEnabled() then return end
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
    local total = self._total_pages or 1
    if self.page < total then
        self:_advanceCursor(1)
        self:_syncPageFromCursor()
        self:_swapShelvesInPlace()
        self:_schedulePreload(1)
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
        self:_schedulePreload(-1)
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

function BookshelfWidget:onSwipeNextPage(_, ges)
    if self:_isInSimpleUIBottomBand(ges and ges.pos) then
        return true
    end
    -- Hero-area swipe: cycle preview to next book. Stays inside the
    -- chip; pages flip automatically when the next book lives on a
    -- different page than the current preview.
    if self:_isHeroSwipe(ges) then
        self:_previewNeighbourBook(1)
        return true
    end
    self:_logSwipeLatency("next", ges)
    return self:_paginateNext()
end

function BookshelfWidget:onSwipePrevPage(_, ges)
    if self:_isInSimpleUIBottomBand(ges and ges.pos) then
        return true
    end
    if self:_isHeroSwipe(ges) then
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
        or item.kind == "format" or item.kind == "rating" then
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
function BookshelfWidget:_buildBookMenuHeader(book, override_width, pill_specs)
    if not book or not book.filepath then return nil end
    local Font           = require("ui/font")
    local ImageWidget    = require("ui/widget/imagewidget")
    local HorizontalGroup_   = require("ui/widget/horizontalgroup")
    local HorizontalSpan_    = require("ui/widget/horizontalspan")
    local VerticalGroup_     = require("ui/widget/verticalgroup")
    local VerticalSpan_      = require("ui/widget/verticalspan")
    local TextBoxWidget_     = require("ui/widget/textboxwidget")
    local TextWidget_        = require("ui/widget/textwidget")

    -- Target header width: leave generous side margin so the ButtonDialog
    -- chrome (padding + border) doesn't push us past the screen edge.
    -- Caller can pass override_width (e.g. the collection manager, which
    -- nests inside the book menu and needs a narrower header).
    local sw = Screen:getWidth()
    local header_w = override_width or math.floor(sw * 0.82)
    -- Cover thumbnail is the visual anchor of the header; size it large
    -- enough that the title block on a real cover is legible, but not
    -- so large the menu starts to dominate the screen. Height is
    -- derived from the actual cover aspect once we've fetched the bb
    -- (a few lines down) so the FrameContainer matches the painted
    -- image exactly -- no horizontal or vertical letterboxing.
    local thumb_w  = Screen:scaleBySize(110)
    local thumb_h  = math.floor(thumb_w * 1.5)  -- default 2:3 if no cover
    local gap_w    = Size.padding.large

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
    if fresh.cover_bb then
        -- Resize the container to the cover's true aspect ratio so the
        -- image fills the frame with no letterboxing. cover_bb is a
        -- blitbuffer with .w/.h fields; falling back to 2:3 if either
        -- is missing keeps the layout sane for malformed covers.
        local bb = fresh.cover_bb
        if bb.w and bb.h and bb.w > 0 then
            thumb_h = math.floor(thumb_w * (bb.h / bb.w))
        end
        local thumb_frame = FrameContainer:new{
            bordersize = Size.border.thin,
            padding    = 0,
            margin     = 0,
            ImageWidget:new{
                image            = fresh.cover_bb,
                image_disposable = true,
                width            = thumb_w,
                height           = thumb_h,
                scale_factor     = 0,
            },
        }
        -- Wrap in an InputContainer so a tap on the thumbnail opens a
        -- full-screen preview. The bb above is one-shot (ImageWidget
        -- frees it after first paint), so the tap handler rebuilds the
        -- record to get a fresh bb for ImageViewer. ImageViewer takes
        -- ownership of the new bb via image_disposable=true.
        local fp = book.filepath
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

    local text_w = thumb_widget and (header_w - thumb_w - gap_w) or header_w

    -- Top of text column: title (bold) + author + one-line metadata
    -- strip (format · size · added · last opened) + filename. Series
    -- info is no longer rendered here -- it lives as a tappable pill
    -- in the nav strip below.
    local top_stack = VerticalGroup_:new{ align = "left" }
    local mtitle_face, mtitle_bold = BFont:getFace("smalltfont", 20, { bold = true })
    top_stack[#top_stack + 1] = TextBoxWidget_:new{
        text  = book.title or book.filename or _("(no title)"),
        face  = mtitle_face,
        bold  = mtitle_bold,
        width = text_w,
    }
    if book.author and book.author ~= "" then
        local mauthor_face, mauthor_bold = BFont:getFace("cfont", 16)
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
    local meta_face, meta_bold = BFont:getFace("cfont", 12)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local size_bytes, mtime
    if ok_lfs and lfs and lfs.attributes then
        size_bytes = lfs.attributes(book.filepath, "size")
        mtime      = lfs.attributes(book.filepath, "modification")
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
    -- All four metadata facets land on ONE row, middle-dot separated:
    -- format · size · Added <date> · Read <date>. Compresses what used
    -- to be three rows down to one.
    local meta_parts = {}
    if book.format then meta_parts[#meta_parts + 1] = book.format end
    local size_str = _fmt_size(size_bytes)
    if size_str then meta_parts[#meta_parts + 1] = size_str end
    local added_str = _fmt_short_date(mtime)
    if added_str then meta_parts[#meta_parts + 1] = _("Added") .. " " .. added_str end
    local last_str  = _fmt_short_date(_last_opened(book.filepath))
    if last_str then meta_parts[#meta_parts + 1] = _("Read") .. " " .. last_str end
    if #meta_parts > 0 then
        top_stack[#top_stack + 1] = TextBoxWidget_:new{
            text  = table.concat(meta_parts, "  \xC2\xB7  "),  -- middle-dot
            face  = meta_face,
            bold  = meta_bold,
            width = text_w,
        }
    end

    -- Filename (basename only, no directory). Directory is reachable
    -- through the Folder pill in the nav strip below, so duplicating
    -- the full path here is noise.
    local basename = (book.filepath or ""):match("([^/]+)$") or book.filepath or ""
    top_stack[#top_stack + 1] = TextBoxWidget_:new{
        text  = basename,
        face  = meta_face,
        bold  = meta_bold,
        width = text_w,
    }

    -- Bottom-aligned pill strip: tappable nav facets (series, author,
    -- collections, genres, folder, rating). Each pill is a small
    -- bordered rounded rectangle, packed into rows that wrap to
    -- text_w. Pill text is rendered UPPERCASED (small-caps style) --
    -- KOReader's TextWidget has no small-caps font variant, so the
    -- :upper() fallback is the convention. Padding is symmetric on
    -- both axes for a balanced look. Built only when the caller passes
    -- pill_specs -- the collection-manager call site for instance
    -- passes nil because it doesn't want nav-into-self affordances.
    local pill_group = VerticalGroup_:new{ align = "left" }
    if pill_specs and #pill_specs > 0 then
        local pill_face, pill_bold = BFont:getFace("cfont", 12, { bold = true })
        local pill_pad_h  = Size.padding.default  -- L/R inner padding
        local pill_pad_v  = Size.padding.small    -- T/B inner padding
        local pill_gap    = Size.padding.default  -- between pills
        local MAX_PILL_ROWS = 2  -- bounds the header height when the
                                 -- caller pours dozens of pills at us;
                                 -- the overflow collapses into a single
                                 -- "+N" pill so the visible row count
                                 -- never grows past this cap.

        -- Build all pill widgets first so we know their widths up
        -- front (the packing pass needs them to greedily wrap).
        local function _buildPill(label_text, on_tap_cb)
            local label_w = TextWidget_:new{
                text = (label_text or ""):upper(),
                face = pill_face,
                bold = pill_bold,
            }
            -- Explicit white bg so the tap-feedback inversion has
            -- something to flip to black. Matches the hero pill builder.
            local frame = FrameContainer:new{
                bordersize     = Size.border.thin,
                background     = Blitbuffer.COLOR_WHITE,
                radius         = Size.radius.button,
                padding_left   = pill_pad_h,
                padding_right  = pill_pad_h,
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

        -- If we stopped early, append a "+N more" pill so the user
        -- knows there are hidden facets. Non-tappable -- a future
        -- enhancement could open a full list, but for now it's just
        -- an overflow indicator.
        if stopped_at then
            local hidden = #pill_widgets - stopped_at + 1
            local more_pill, more_w = _buildPill("+" .. hidden, nil)
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
                more_pill, more_w = _buildPill("+" .. hidden, nil)
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
    return FrameContainer:new{
        bordersize     = 0,
        margin         = 0,
        padding        = 0,
        padding_top    = Size.padding.large,
        padding_bottom = Size.padding.large,
        body,
    }
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
function BookshelfWidget:_buildPillSpecs(book, collection_set, close_cb)
    if not book then return {} end
    local bw   = self
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

    -- 1. Author. Display respects the "Author name formatting" setting
    -- so the pill matches the form used elsewhere (hero, Authors chip).
    -- Drilldown still keys on the RAW author so the lookup matches the
    -- group regardless of which form the user has selected.
    if book.author and book.author ~= "" then
        local author_name = book.author
        local display_author = author_name
        local fmt = BookshelfSettings.read("author_format") or "auto"
        if fmt ~= "auto" then
            local ok_a, _AN = pcall(require, "lib/bookshelf_author_name")
            if ok_a and _AN and _AN.formatted then
                display_author = _AN.formatted(author_name, fmt)
            end
        end
        pill_specs[#pill_specs + 1] = {
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

    -- 2. Series -- appends " #N" when book.series_num is set so the
    -- pill reads "[Southern Reach #2]" rather than the bare series
    -- name. Tapping still drills into the series view; the number is
    -- decoration on the pill itself.
    if book.series_name and book.series_name ~= "" then
        local series_name  = book.series_name
        local series_label = series_name
        if book.series_num then
            series_label = series_label .. " #" .. tostring(book.series_num)
        end
        pill_specs[#pill_specs + 1] = {
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
    for _i, coll_name in ipairs(coll_names) do
        local display = (coll_name == default_coll_name) and _("Favourites") or coll_name
        pill_specs[#pill_specs + 1] = {
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
    if book.genres and #book.genres > 0 then
        local _seen = {}
        if book.series_name and book.series_name ~= "" then
            _seen[book.series_name:lower()] = true
        end
        for _i, coll_name in ipairs(coll_names) do
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
    if parent_dir and parent_dir ~= "" and parent_dir ~= home_dir then
        local folder_label = parent_dir:match("([^/]+)$") or parent_dir
        pill_specs[#pill_specs + 1] = {
            label  = folder_label,
            on_tap = _wrap(function()
                _navResetAndClose()
                bw:_expandFolder({ path = parent_dir, label = folder_label })
            end),
        }
    end

    return pill_specs
end

-- _buildPillGroup(pill_specs, available_w, max_rows)
-- Render the same tappable pill strip used in the long-press book menu
-- as a self-contained widget that callers can drop into any layout.
-- Greedy width-bounded packing, capped at max_rows; overflow collapses
-- into a non-tappable "+N" pill. Returns a VerticalGroup (possibly
-- empty if pill_specs is empty / nil). Pure widget builder — no state
-- on self other than what the spec callbacks capture.
function BookshelfWidget:_buildPillGroup(pill_specs, available_w, max_rows, base_size)
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
    local pill_group = VerticalGroup_:new{ align = "left" }
    if not pill_specs or #pill_specs == 0 then return pill_group end

    local pill_face, pill_bold = BFont:getFace("cfont", base_size or 12, { bold = true })
    local pill_pad_h = Size.padding.default
    local pill_pad_v = Size.padding.small
    local pill_gap   = Size.padding.default

    local function _buildPill(label_text, on_tap_cb)
        local label_w = TextWidget_:new{
            text = (label_text or ""):upper(),
            face = pill_face,
            bold = pill_bold,
        }
        -- Explicit white bg so the tap-feedback inversion has something to
        -- invert to black (without this, the frame's transparent fill
        -- can't be flipped). Matches KOReader's Button feedback pattern.
        local frame = FrameContainer_:new{
            bordersize     = Size.border.thin,
            background     = Blitbuffer.COLOR_WHITE,
            radius         = Size.radius.button,
            padding_left   = pill_pad_h,
            padding_right  = pill_pad_h,
            padding_top    = pill_pad_v,
            padding_bottom = pill_pad_v,
            margin         = 0,
            label_w,
        }
        local frame_size = frame:getSize()
        local pill = InputContainer_:new{
            dimen = Geom:new{ w = frame_size.w, h = frame_size.h },
            frame,
        }
        pill.ges_events = {
            Tap = { GestureRange_:new{ ges = "tap", range = pill.dimen } },
        }
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
        return pill, frame_size.w
    end

    -- Build all pills first so the packer knows widths up front.
    local pill_widgets = {}
    for _i, spec in ipairs(pill_specs) do
        local on_tap = spec.on_tap
        local pill, pw = _buildPill(spec.label, on_tap)
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
        local hidden = #pill_widgets - stopped_at + 1
        local more_pill, more_w = _buildPill("+" .. hidden, nil)
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
            more_pill, more_w = _buildPill("+" .. hidden, nil)
        end
        last_row[#last_row + 1] = { widget = more_pill, w = more_w }
    end

    for ri, row_pills in ipairs(rows) do
        local row_widget = HorizontalGroup_:new{ align = "center" }
        for j, p in ipairs(row_pills) do
            if j > 1 then
                row_widget[#row_widget + 1] = HorizontalSpan_:new{ width = pill_gap }
            end
            row_widget[#row_widget + 1] = p.widget
        end
        if ri > 1 then
            pill_group[#pill_group + 1] = VerticalSpan_:new{ width = pill_gap }
        end
        pill_group[#pill_group + 1] = row_widget
    end
    return pill_group
end

-- _openBookMenu(item)
-- item may be a Book record (from a SpineWidget tap) or a SeriesGroup record
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
    if not d.footer_overlap_idx then return end
    local old_anchor = self._overlap_group[d.footer_overlap_idx]
    local old_dimen  = old_anchor and old_anchor.dimen
    local BottomContainer = require("ui/widget/container/bottomcontainer")
    local new_footer_row = self:_buildFooterRow(d.content_w, self._total_pages or 1, d.FOOTER_H)
    local footer_anchor_h = self.height - self:_simpleUIReservedBottom()
    local new_anchor = BottomContainer:new{
        dimen = Geom:new{ w = self.width, h = footer_anchor_h - d.FOOTER_BOTTOM_MARGIN },
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

local function _formatHardcoverReviewRating(rating)
    rating = tonumber(rating)
    if not rating or rating <= 0 then return nil end
    local text = string.format("%.1f", rating):gsub("%.0$", "")
    return text .. " \xE2\x98\x85"
end

local function _formatHardcoverReviewDate(ts)
    if type(ts) ~= "string" then return nil end
    return ts:match("^(%d%d%d%d%-%d%d%-%d%d)") or ts
end

local function _repaintHardcoverReviewViewer(viewer)
    UIManager:setDirty(viewer, function()
        if viewer and viewer.dimen then
            return "ui", viewer.dimen
        end
        return "full"
    end)
end

local function _scrollHardcoverReviewViewer(viewer, direction)
    local scroll = viewer and viewer.scroll_text_w
    local textw = scroll and scroll.text_widget
    if not textw or not textw.vertical_string_list or not textw.lines_per_page then
        return true
    end

    local line_count = #textw.vertical_string_list
    local lines_per_page = math.max(1, tonumber(textw.lines_per_page) or 1)
    local max_top = math.max(1, line_count - lines_per_page + 1)
    local old_top = math.max(1, tonumber(textw.virtual_line_num) or 1)
    local new_top = old_top + (direction > 0 and lines_per_page or -lines_per_page)
    if new_top < 1 then
        new_top = 1
    elseif new_top > max_top then
        new_top = max_top
    end

    if new_top ~= old_top then
        textw.image_show_alt_text = nil
        textw:free(false)
        textw.virtual_line_num = new_top
        textw:_updateLayout()
        if scroll.updateScrollBar then
            scroll:updateScrollBar(true)
        end
        _repaintHardcoverReviewViewer(viewer)
    end
    return true
end

local function _stabiliseHardcoverReviewViewer(viewer)
    local scroll = viewer and viewer.scroll_text_w
    if not scroll then return end

    -- TextViewer's stock TextBoxWidget can advance a non-editable text view
    -- past the last full page, which leaves mostly/entirely blank pages on
    -- some KOReader builds. Reviews are read-only, so clamp page turns here
    -- and repaint the full popup after each move.
    function scroll:scrollDown()
        return _scrollHardcoverReviewViewer(viewer, 1)
    end
    function scroll:scrollUp()
        return _scrollHardcoverReviewViewer(viewer, -1)
    end
    function scroll:scrollText(direction)
        return _scrollHardcoverReviewViewer(viewer, direction)
    end
    function scroll:onScrollDown()
        return _scrollHardcoverReviewViewer(viewer, 1)
    end
    function scroll:onScrollUp()
        return _scrollHardcoverReviewViewer(viewer, -1)
    end

    if Device:hasKeys() then
        viewer.key_events = viewer.key_events or {}
        viewer.key_events.BSHardcoverReviewsNextPage = { { Device.input.group.PgFwd } }
        viewer.key_events.BSHardcoverReviewsPrevPage = { { Device.input.group.PgBack } }
        function viewer:onBSHardcoverReviewsNextPage()
            return _scrollHardcoverReviewViewer(viewer, 1)
        end
        function viewer:onBSHardcoverReviewsPrevPage()
            return _scrollHardcoverReviewViewer(viewer, -1)
        end
    end
end

function BookshelfWidget:_showHardcoverReviews(book, opts)
    opts = opts or {}
    if not (book and book.filepath) then return end
    local Hardcover = require("lib/bookshelf_hardcover")
    local InfoMessage = require("ui/widget/infomessage")
    local link = Hardcover.getLink(book.filepath)
    local book_id = book.hardcover_book_id or (link and link.book_id)
    if not book_id then
        UIManager:show(InfoMessage:new{
            text = _("No Hardcover book is linked yet."),
            icon = "notice-warning",
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Fetching Hardcover reviews..."),
        timeout = 1,
    })
    UIManager:nextTick(function()
        local ok, result = Hardcover.fetchReviews(book_id, {
            force = opts.force == true,
        })
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Hardcover reviews could not be fetched: ") .. tostring(result),
                icon = "notice-warning",
                timeout = 5,
            })
            return
        end

        local Tokens = require("lib/bookshelf_tokens")
        local parts = {}
        local title = result.title or book.hardcover_title or book.title or _("Hardcover reviews")
        parts[#parts + 1] = title

        local meta = {}
        local rating = _formatHardcoverReviewRating(result.rating)
        if rating then meta[#meta + 1] = rating end
        if tonumber(result.ratings_count) and tonumber(result.ratings_count) > 0 then
            meta[#meta + 1] = string.format(_("%d ratings"), tonumber(result.ratings_count))
        end
        if tonumber(result.reviews_count) and tonumber(result.reviews_count) > 0 then
            meta[#meta + 1] = string.format(_("%d reviews"), tonumber(result.reviews_count))
        end
        if #meta > 0 then
            parts[#parts + 1] = table.concat(meta, " · ")
        end
        parts[#parts + 1] = _("Showing non-spoiler reviews from Hardcover.")

        local reviews = type(result.reviews) == "table" and result.reviews or {}
        if #reviews == 0 then
            parts[#parts + 1] = ""
            parts[#parts + 1] = _("No non-spoiler reviews found.")
        else
            for i, review in ipairs(reviews) do
                parts[#parts + 1] = ""
                parts[#parts + 1] = "--------------------"
                local line = {}
                line[#line + 1] = review.user_name or review.username or _("Unknown reader")
                local r = _formatHardcoverReviewRating(review.rating)
                if r then line[#line + 1] = r end
                local d = _formatHardcoverReviewDate(review.reviewed_at)
                if d then line[#line + 1] = d end
                if tonumber(review.likes_count) and tonumber(review.likes_count) > 0 then
                    line[#line + 1] = string.format(_("%d likes"), tonumber(review.likes_count))
                end
                parts[#parts + 1] = table.concat(line, " · ")
                local text = Tokens.cleanDescription(review.text or "") or ""
                if text == "" then text = _("No review text.") end
                parts[#parts + 1] = text
            end
        end

        local viewer
        viewer = require("ui/widget/textviewer"):new{
            title = _("Hardcover reviews"),
            text  = table.concat(parts, "\n"),
            buttons_table = {
                {
                    { text = _("Refresh"), callback = function()
                        UIManager:close(viewer)
                        self:_showHardcoverReviews(book, { force = true })
                    end },
                    { text = _("Close"), callback = function()
                        UIManager:close(viewer)
                    end },
                },
            },
        }
        _stabiliseHardcoverReviewViewer(viewer)
        UIManager:show(viewer)
    end)
end

function BookshelfWidget:_afterHardcoverLinkChanged(book, message)
    local Hardcover = require("lib/bookshelf_hardcover")
    Hardcover.invalidate()
    if book and book.filepath then
        local link = Hardcover.getLink(book.filepath)
        if link then
            book.hardcover_book_id = tonumber(link.book_id) or link.book_id
            book.hardcover_edition_id = tonumber(link.edition_id) or link.edition_id
            book.hardcover_title = link.title
            book.hardcover_rating = Hardcover.getCachedRating(link.book_id)
        else
            book.hardcover_book_id = nil
            book.hardcover_edition_id = nil
            book.hardcover_title = nil
            book.hardcover_rating = nil
            book.hardcover_reviews_count = nil
        end
    end
    if Repo.invalidateBookCache then
        Repo.invalidateBookCache("hardcover-link")
    end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    if message then
        UIManager:show(require("ui/widget/notification"):new{
            text = message,
            timeout = 2,
        })
    end
end

function BookshelfWidget:_openHardcoverMenu(book)
    if not (book and book.filepath) then return end
    local Hardcover = require("lib/bookshelf_hardcover")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")
    local bw = self
    local dialog
    local function warn(err)
        UIManager:show(InfoMessage:new{
            text = _("Hardcover action failed: ") .. tostring(err),
            icon = "notice-warning",
            timeout = 4,
        })
    end
    local function closing(fn)
        return function()
            UIManager:close(dialog)
            if fn then UIManager:nextTick(fn) end
        end
    end
    local function linkedLabel()
        local label = Hardcover.linkLabel(book.filepath)
        if label then
            return _("Linked: ") .. label
        end
        if Hardcover.hasHardcoverIdentifiers(book) then
            return _("Not linked · embedded Hardcover ID found")
        end
        return _("Not linked")
    end
    local function linkEmbedded()
        UIManager:show(InfoMessage:new{
            text = _("Linking from embedded Hardcover ID..."),
            timeout = 1,
        })
        UIManager:nextTick(function()
            local ok, result = Hardcover.linkFromEmbeddedIdentifiers(book, {
                on_linked = function()
                    bw:_afterHardcoverLinkChanged(book, _("Hardcover book linked"))
                end,
            })
            if not ok then warn(result) end
        end)
    end
    local function afterBookSelected(selected)
        bw:_afterHardcoverLinkChanged(book, _("Hardcover book linked"))
        if selected and selected.book_id then
            UIManager:nextTick(function()
                local ok, err = Hardcover.showEditionPicker(book, selected.book_id, {
                    on_edition_selected = function()
                        bw:_afterHardcoverLinkChanged(book, _("Hardcover edition linked"))
                    end,
                    on_error = warn,
                })
                if not ok then warn(err) end
            end)
        end
    end
    local function selectBook()
        UIManager:show(InfoMessage:new{
            text = _("Fetching Hardcover matches..."),
            timeout = 1,
        })
        UIManager:nextTick(function()
            local ok, err = Hardcover.showBookPicker(book, {
                on_book_selected = afterBookSelected,
                on_error = warn,
            })
            if not ok then warn(err) end
        end)
    end
    local function selectEdition()
        local link = Hardcover.getLink(book.filepath)
        if not (link and link.book_id) then
            warn(_("No Hardcover book is linked yet."))
            return
        end
        UIManager:show(InfoMessage:new{
            text = _("Fetching Hardcover editions..."),
            timeout = 1,
        })
        UIManager:nextTick(function()
            local ok, err = Hardcover.showEditionPicker(book, link.book_id, {
                on_edition_selected = function()
                    bw:_afterHardcoverLinkChanged(book, _("Hardcover edition linked"))
                end,
                on_error = warn,
            })
            if not ok then warn(err) end
        end)
    end
    local function clearLink()
        local ok, err = Hardcover.clearLink(book.filepath)
        if not ok then
            warn(err)
            return
        end
        bw:_afterHardcoverLinkChanged(book, _("Hardcover link cleared"))
    end
    local function showReviews()
        bw:_showHardcoverReviews(book)
    end

    local is_linked = Hardcover.getLink(book.filepath) ~= nil
    local buttons = {
        {
            { text_func = linkedLabel, enabled = false },
        },
    }
    if (not is_linked) and Hardcover.hasHardcoverIdentifiers(book) then
        buttons[#buttons + 1] = {
            { text = _("Link from embedded Hardcover ID"), callback = closing(linkEmbedded) },
        }
    end
    buttons[#buttons + 1] = {
        { text = _("Select book..."), callback = closing(selectBook) },
        { text = _("Select edition..."),
          enabled = is_linked,
          callback = closing(selectEdition) },
    }
    buttons[#buttons + 1] = {
        { text = _("Clear link"),
          enabled = is_linked,
          callback = closing(clearLink) },
        { text = _("Reviews..."),
          enabled = is_linked,
          callback = closing(showReviews) },
    }
    buttons[#buttons + 1] = {
        { text = _("Cancel"), callback = closing() },
    }

    dialog = ButtonDialog:new{
        title = _("Hardcover"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function BookshelfWidget:_refreshBookMetadata(book)
    if not (book and book.filepath) then return end

    local InfoMessage = require("ui/widget/infomessage")
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(book.filepath, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{
            text    = _("File no longer exists. The bookshelf entry is stale."),
            timeout = 3,
        })
        return
    end

    local ok_bim, BIM = pcall(require, "bookinfomanager")
    if not ok_bim or not BIM or type(BIM.deleteBookInfo) ~= "function"
            or type(BIM.extractInBackground) ~= "function" then
        UIManager:show(InfoMessage:new{
            text    = _("Book information manager is not available."),
            timeout = 3,
        })
        return
    end

    local deleted = pcall(function()
        BIM:deleteBookInfo(book.filepath)
    end)
    if not deleted then
        UIManager:show(InfoMessage:new{
            text    = _("Could not clear cached book information."),
            timeout = 3,
        })
        return
    end

    if Repo.invalidateProgressCache then
        Repo.invalidateProgressCache(book.filepath)
    end
    if Repo.invalidateWalkCache then
        Repo.invalidateWalkCache()
    end
    if Repo.invalidateBookCache then
        Repo.invalidateBookCache("refreshBookMetadata")
    end

    local ok_cache, ScaledCoverCache = pcall(require, "lib/bookshelf_scaled_cover_cache")
    if ok_cache and ScaledCoverCache and type(ScaledCoverCache.remove) == "function" then
        ScaledCoverCache:remove(book.filepath)
    end

    local d = self._shelf_dims or {}
    local n_cols = self:_nCols()
    local slot_w
    if d.content_w and d.PAD then
        slot_w = math.floor((d.content_w - d.PAD * (n_cols - 1)) / n_cols)
    else
        slot_w = math.floor((self.width or Screen:getWidth()) / math.max(1, n_cols))
    end
    local slot_h = math.floor(slot_w * 1.5)
    local files = {
        {
            filepath = book.filepath,
            cover_specs = {
                max_cover_w = math.max(slot_w, d.hero_cover_w or slot_w),
                max_cover_h = math.max(slot_h, d.hero_cover_h or slot_h),
            },
        },
    }

    UIManager:show(InfoMessage:new{
        text    = _("Refreshing cached book information..."),
        timeout = 2,
    })

    local function extract_when_idle()
        if type(BIM.isExtractingInBackground) == "function"
                and BIM:isExtractingInBackground() then
            UIManager:scheduleIn(BIM_POLL_INTERVAL_S, extract_when_idle)
            return
        end
        pcall(function()
            BIM:extractInBackground(files)
        end)
    end

    UIManager:nextTick(extract_when_idle)
    self:_armExtractionPoll(files)
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
    -- Hydrate the rating from DocSettings if it's missing. Shelf book
    -- records come from Repo.buildBookMeta which deliberately skips the
    -- per-file DocSettings:open() for speed (rating, percent, status
    -- live in the sidecar, not BIM). Without this, the menu's Rating
    -- button always showed ☆☆☆☆☆ for shelf books even when the user
    -- had set a rating from the hero card or a previous long-press --
    -- the button is reading book.rating which the shelf record never
    -- populated. readProgress is cheap (sidecar fast-path, memoised
    -- via _progress_cache) so doing it once on menu open is fine.
    if book.rating == nil and book.filepath then
        local _pct, _status, fresh_rating = Repo.readProgress(book.filepath)
        book.rating = fresh_rating
    end

    -- Stage-and-apply draft (spec §6 / Task 9). Every non-destructive
    -- button writes into this local table instead of persisting on
    -- tap; Apply commits the lot in deterministic order; Cancel drops
    -- it (the table is local, dies when this closure goes out of
    -- scope). Header reflects PERSISTED state -- staged values are
    -- visible only on the button that staged them (text_func + "  •"
    -- suffix per the staged-marker convention).
    --
    -- rating uses `false` as the "no change" sentinel because nil is a
    -- valid target (Clear stars). All other fields use nil/false per
    -- their natural type.
    local draft = {
        status              = nil,    -- nil | "new" | "reading" | "abandoned" | "complete"
        rating              = false,  -- false = no change | nil = clear | 1..5 = set
        collections_add     = nil,    -- nil | table<name, true>
        collections_remove  = nil,    -- nil | table<name, true>
        remove_from_history = false,
    }
    -- Recover a draft stashed by a previous invocation that closed
    -- the menu to open a sub-dialog (Collections). Single-shot:
    -- consume + clear so subsequent menu opens for OTHER books
    -- don't see stale draft state.
    if bw._pending_book_draft and bw._pending_book_draft.book_filepath == book.filepath then
        local stashed = bw._pending_book_draft.draft
        bw._pending_book_draft = nil
        if stashed then
            draft.status              = stashed.status
            draft.rating              = stashed.rating
            draft.collections_add     = stashed.collections_add
            draft.collections_remove  = stashed.collections_remove
            draft.remove_from_history = stashed.remove_from_history
        end
    end
    local function isDirty()
        return draft.status ~= nil
            or draft.rating ~= false
            or draft.collections_add ~= nil
            or draft.collections_remove ~= nil
            or draft.remove_from_history
    end

    -- Staged-marker glyph. Trailing "  •" appended to the button's
    -- text on every staged button (status, rating, collections,
    -- refresh, remove-history). ButtonTable hardcodes bordersize=0 on
    -- Staged buttons get painted with a light-gray background fill
    -- instead of a trailing glyph marker. ButtonTable forwards the row
    -- spec's `background` field straight to the underlying Button (see
    -- frontend/ui/widget/buttontable.lua:97), so we can mutate this
    -- field on tap and call dialog:reinit() to pick up the new shade.
    -- COLOR_LIGHT_GRAY (0xCC, ~80% white) reads cleanly on e-ink
    -- without fighting the black text.
    local STAGED_BG = Blitbuffer.COLOR_LIGHT_GRAY

    -- Fav and TBR no longer have dedicated toggle buttons -- both are
    -- managed through the Collections… modal (one management surface,
    -- avoids the KOReader removeItem persist-quirk that the dedicated
    -- buttons had to work around). Membership remains visible at a
    -- glance via the pill strip in the header, and the Collections
    -- button below shows the membership count.
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
    -- Navigation pill specs are built by the shared _buildPillSpecs
    -- helper (so the Collection Manager's book-mode header can reuse
    -- the exact same pill set, reflecting the in-flight draft state).
    -- close_cb runs after each pill's drill so the menu dismisses on
    -- tap. in_collections is the SAVED membership set -- pills mirror
    -- what's in ReadCollection right now.
    local in_collections = ReadCollection:getCollectionsWithFile(book.filepath) or {}
    local pill_specs = self:_buildPillSpecs(book, in_collections,
        function() UIManager:close(dialog) end)

    -- _reinitDialog(): rebuild the header before calling dialog:reinit
    -- so the header's disposable cover_bb (BIM one-shot invariant) is
    -- a fresh widget for the next paint. Naked dialog:reinit() re-uses
    -- the original ImageWidget whose bb was freed after first paint,
    -- and the symptom is "book title / metadata disappears from the
    -- heading" the next time a button callback fires reinit (e.g.
    -- staging a status change). The rating-close path used to do this
    -- inline at one call site; centralising means every reinit path
    -- (status / collections / rating-close / etc.) gets it. bw is
    -- already in scope from the outer function.
    local function _reinitDialog()
        if not (dialog and dialog.reinit) then return end
        if dialog._added_widgets then
            local new_header = bw:_buildBookMenuHeader(book, nil, pill_specs)
            if new_header then
                dialog._added_widgets[1] = new_header
            end
        end
        dialog:reinit()
        UIManager:setDirty(dialog, "ui")
    end

    -- Build each button spec as a named local so the final buttons
    -- table assembles in the visual order we want without re-deriving
    -- closures. Order layout:
    --   1. Show info / Collections / Rating
    --   2. Status row (Unopened / Reading / On hold / Finished)
    --   3. Reset / Remove from history
    --   4. Delete / Refresh metadata
    --   5. Select / Cancel / Apply

    local show_info_button = {
        text = "Show info",
        callback = closing(function()
            -- filemanagerbookinfo:show does lfs.attributes(file).size with
            -- no nil guard -- passing a missing filepath panics LuaJIT
            -- and drops to stock Kindle. Bail with a toast for stale
            -- records.
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
        end),
    }

    -- Favourites / To Be Read quick-toggle buttons removed: both are
    -- managed through Collections… now (one management surface, no
    -- removeItem persist-quirk workarounds, pills above show
    -- membership at a glance).

    -- Remove-from-history: staged boolean. Gray-fill background appears
    -- when staged; the actual readhistory removal runs from Apply.
    local remove_history_button
    remove_history_button = {
        text = _("Remove from history"),
        background = draft.remove_from_history and STAGED_BG or nil,
        callback = function()
            draft.remove_from_history = not draft.remove_from_history
            remove_history_button.background = draft.remove_from_history and STAGED_BG or nil
            _reinitDialog()
        end,
    }

    -- Dedicated ★ Favourites toggle: treats the favourites collection as a
    -- first-class action distinct from the generic Collections... manager
    -- (the corner-badge counterpart on covers ties to this). Immediate
    -- persist + rebuild, matching the pre-v2 quick-toggle behaviour --
    -- favourites is special enough that the cover badge should reflect
    -- the change as soon as the menu closes, without waiting for Apply.
    local default_coll_name = ReadCollection.default_collection_name
    local in_fav = in_collections[default_coll_name] and true or false
    local fav_button
    fav_button = {
        -- Compact +/- action label: long-form "Add to / Remove from
        -- favourites" pushed this button past its width budget in the
        -- three-button row next to "Reset book data..." and "Remove
        -- from history". The "+" / "-" prefix is the universal
        -- shorthand for "this tap adds" / "this tap removes", which is
        -- the only thing the label needs to communicate at the moment
        -- of tap -- the cover star badge carries the steady-state
        -- "is favourited" signal.
        text = (in_fav and "\xE2\x88\x92 " or "+ ") .. _("Favourite"),
        -- "\u{2212}" MINUS SIGN, not "-" HYPHEN: visually balances with
        -- "+" at the same x-height in the menu font; the hyphen sits
        -- noticeably lower and reads as "and" rather than "minus" at
        -- glance.
        callback = closing(function()
            if in_fav then
                pcall(function() ReadCollection:removeItem(book.filepath, default_coll_name) end)
            else
                pcall(function() ReadCollection:addItem(book.filepath, default_coll_name) end)
            end
            pcall(function() ReadCollection:write() end)
            -- The Favourites chip with any sort_priority routes through
            -- _bySource_cache (Repo.getBySource's custom-kind predicate
            -- path). That cache holds the filepath list captured at the
            -- last fetch and isn't aware of the toggle we just did --
            -- without invalidating it, switching to the Favourites tab
            -- would show stale membership until a swipe-down refresh.
            pcall(function() Repo.invalidateFavoritesCache() end)
            if bw._rebuild then
                bw:_rebuild()
                UIManager:setDirty(bw, "ui")
            end
        end),
    }

    -- Count current collections so the button reads e.g.
    -- "Collections (2)…" -- mirrors the favourites / TBR toggle buttons
    -- showing their own state in the label.
    local _coll_count = 0
    -- _k (not _) so the loop variable doesn't shadow the bookshelf-wide
    -- `_ = require("bookshelf_i18n").gettext` import per
    -- feedback_gettext_shadowing.
    for _k in pairs(in_collections) do _coll_count = _coll_count + 1 end
    local _collections_label = _("Collections")
    if _coll_count > 0 then
        _collections_label = _collections_label .. " (" .. _coll_count .. ")"
    end
    _collections_label = _collections_label .. "\xE2\x80\xA6"
    -- Collections: stage_only flag tells the manager to return the
    -- add/remove diff via on_save instead of persisting. The flag is
    -- consumed by bookshelf_collection_manager in Task 12 -- until then
    -- the manager ignores it and still persists. Wire the new flags
    -- now so the call site is final.
    local tags_button
    tags_button = {
        text = _collections_label,
        background = (draft.collections_add or draft.collections_remove) and STAGED_BG or nil,
        callback = closing(function()
            -- Stash current draft so the on_save/on_cancel reopen
            -- via _openBookMenu(book) can recover it. Without this,
            -- any staged status/rating/refresh/remove-history would
            -- be lost when the menu closes to open the manager.
            bw._pending_book_draft = {
                book_filepath = book.filepath,
                draft         = {
                    status              = draft.status,
                    rating              = draft.rating,
                    collections_add     = draft.collections_add,
                    collections_remove  = draft.collections_remove,
                    remove_from_history = draft.remove_from_history,
                },
            }
            local CollectionManager = require("lib/bookshelf_collection_manager")
            CollectionManager.show{
                book           = book,
                bw             = bw,
                stage_only     = true,
                initial_add    = draft.collections_add,
                initial_remove = draft.collections_remove,
                on_save        = function(diff)
                    -- Update the stashed draft so the reopened menu sees the
                    -- new diff alongside any other previously-staged values.
                    if bw._pending_book_draft then
                        bw._pending_book_draft.draft.collections_add    = diff and diff.add    or nil
                        bw._pending_book_draft.draft.collections_remove = diff and diff.remove or nil
                    end
                    -- Reopen the menu so the button reflects the new
                    -- pending state (and Apply switches enabled).
                    UIManager:nextTick(function() bw:_openBookMenu(book) end)
                end,
                on_cancel      = function()
                    -- Stash is preserved; reopen pulls everything back.
                    UIManager:nextTick(function() bw:_openBookMenu(book) end)
                end,
                -- on_close intentionally OMITTED in stage_only mode:
                -- both Save and Cancel in the manager fire on_save /
                -- on_cancel respectively AND would fire on_close, so
                -- with on_close set we ended up scheduling two
                -- _openBookMenu calls on the same tick. First reopen
                -- consumed the stash; second reopened a fresh menu
                -- without it — symptoms: Apply grey, collection diff
                -- lost. Bookshelf rebuild also runs for nothing here
                -- (stage_only doesn't persist; the cache invalidation
                -- belongs to Apply).
            }
        end),
    }

    -- Refresh metadata: immediate action. Unlike status / rating /
    -- collections (which stage and commit on Apply so the user can
    -- preview the new state in the menu), refresh has no in-menu
    -- preview -- there's nothing visual to stage. Pre-v2.2 this was a
    -- one-tap action; v2.2.0's staged-Apply rework swept it into the
    -- staged pattern for consistency, but reporters read the gray
    -- staged background as "the button stopped working" (issue #57).
    -- Restore the immediate behaviour: tap deletes BIM's cached row,
    -- invalidates progress + book caches, fires a notification, and
    -- closes the dialog. Bulk selection still stages refresh -- that's
    -- where batching across many books earns its keep.
    local refresh_button = {
        text = _("Refresh metadata"),
        callback = closing(function()
            local ok_bim, BIM = pcall(require, "bookinfomanager")
            if ok_bim and BIM and BIM.deleteBookInfo then
                pcall(function() BIM:deleteBookInfo(book.filepath) end)
            end
            -- Drop the scaled cover so the next render re-decodes from
            -- BIM's freshly-extracted bytes instead of serving the
            -- in-memory copy of the pre-refresh cover.
            pcall(function()
                require("lib/bookshelf_scaled_cover_cache"):drop(book.filepath)
            end)
            Repo.invalidateProgressCache(book.filepath)
            Repo.invalidateBookCache("refresh-metadata")
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
            UIManager:show(require("ui/widget/notification"):new{
                text    = _("Metadata refresh queued"),
                timeout = 2,
            })
        end),
    }

    -- Rating button + sub-dialog. Sub-dialog writes draft.rating
    -- instead of persisting; the outer Rating button's text_func reads
    -- staged value first (falling back to book.rating when nothing is
    -- staged).
    local function _ratingLabel()
        -- Five star glyphs (filled + empty). When a rating change is
        -- staged, render the staged target; otherwise fall back to the
        -- persisted book.rating. Clamps weird values (NaN, negative,
        -- >5) to the valid range. Staged state is signalled by the
        -- gray-fill background on the rating button itself (set on
        -- the row spec, mutated on tap).
        local r
        if draft.rating == false then
            r = tonumber(book.rating) or 0
        elseif draft.rating == nil then
            r = 0
        else
            r = draft.rating
        end
        if r < 0 then r = 0 end
        if r > 5 then r = 5 end
        r = math.floor(r)
        local filled = ("\xE2\x98\x85"):rep(r)
        local empty  = ("\xE2\x98\x86"):rep(5 - r)
        return filled .. empty
    end
    -- Forward declaration: the rating_close closure below references
    -- rating_button inside its body (line 5905 area) to repaint the
    -- staged-fill on dialog reinit. The local definition is further
    -- down (~line 5940) inside the same outer scope. Without a
    -- forward decl here, the reference resolves to a global which is
    -- nil at runtime — the rating dialog's button callback crashes
    -- with "attempt to index global 'rating_button' (a nil value)".
    local rating_button
    local function _openRatingDialog()
        local rating_dialog
        local function rating_close(fn)
            return function()
                if fn then fn() end
                UIManager:close(rating_dialog)
                -- Refresh the outer book menu so the Rating button's
                -- text_func re-evaluates against the (possibly newly
                -- staged) draft.rating. Without this the book menu
                -- stays open showing the OLD star count -- text_func
                -- only fires at dialog construction time.
                --
                -- Rebuild the cover-thumbnail header too before reinit.
                -- The header's ImageWidget owns the cover_bb with
                -- image_disposable=true (per the BIM one-shot
                -- invariant -- memory
                -- feedback_image_disposable_shared_book), so the bb is
                -- freed after first paint. A naked reinit() re-uses
                -- the same ImageWidget instance and paints from the
                -- freed buffer -- the user sees a garbled cover.
                -- Replacing _added_widgets[1] with a fresh header
                -- (which builds a fresh bb via Repo.buildBookMeta)
                -- gives reinit a clean widget to paint from.
                --
                -- (This was load-bearing pre-staging because
                -- _setBookRating mutated the cover invalidation path;
                -- post-staging book.rating doesn't change until Apply,
                -- but the disposable cover_bb invariant means we still
                -- need to rebuild the header on every reinit anyway --
                -- the reinit walks all child widgets and may repaint
                -- the freed bb regardless of whether we touched it.)
                -- Mutate the rating button's background so the
                -- rebuilt ButtonTable paints the gray fill (or
                -- clears it) per the now-current draft.rating.
                rating_button.background = draft.rating ~= false and STAGED_BG or nil
                _reinitDialog()
            end
        end
        local rows = {}
        for i = 1, 5 do
            local star_label = ("\xE2\x98\x85"):rep(i) .. ("\xE2\x98\x86"):rep(5 - i)
            rows[#rows + 1] = {
                { text = star_label, callback = rating_close(function()
                    draft.rating = i
                end) },
            }
        end
        rows[#rows + 1] = {
            { text = _("Clear"), callback = rating_close(function()
                draft.rating = nil  -- nil = "clear" target on Apply
            end) },
        }
        rows[#rows + 1] = {
            { text = _("Cancel"), callback = rating_close() },
        }
        rating_dialog = require("ui/widget/buttondialog"):new{
            title   = _("Set rating"),
            buttons = rows,
        }
        UIManager:show(rating_dialog)
    end
    -- Rating button callback does NOT close the outer menu -- the
    -- sub-dialog opens on top, the user picks (or cancels), and on
    -- close the rating sub-dialog reinits the outer menu so the
    -- Rating button text reflects the new draft value in place.
    -- background is mutated by rating_close (in _openRatingDialog
    -- above) when the draft value changes. The `rating_button` name
    -- itself is forward-declared above so _openRatingDialog's
    -- closure captures it as an upvalue rather than a global; we
    -- assign here (no `local` keyword) so the same upvalue is
    -- populated for both readers.
    rating_button = {
        text_func  = _ratingLabel,
        background = draft.rating ~= false and STAGED_BG or nil,
        callback   = _openRatingDialog,
    }

    local hardcover_button = {
        text_func = function()
            local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
            if ok_hc and Hardcover then
                local label = Hardcover.linkLabel(book.filepath)
                if label then
                    if #label > 34 then label = label:sub(1, 33) .. "\xE2\x80\xA6" end
                    return _("Hardcover") .. ": " .. label
                end
            end
            return _("Hardcover\xE2\x80\xA6")
        end,
        callback = closing(function()
            UIManager:nextTick(function()
                bw:_openHardcoverMenu(book)
            end)
        end),
    }

    -- Status row: four staged buttons. Tap stages draft.status; tap
    -- the same status again un-stages (back to no change). The
    -- currently-persisted status keeps the trailing "  ✓"; the staged
    -- value (if different from current) gets the gray-fill background.
    -- Because status is mutually-exclusive, every tap must update ALL
    -- four buttons' backgrounds — the previously-staged one needs to
    -- lose its fill when a new value is staged.
    local BookList = require("ui/widget/booklist")
    local current_status = BookList.getBookStatus(book.filepath)  -- "new" / "reading" / "abandoned" / "complete"
    local status_buttons = {}
    local function _is_staged_status(status_value)
        local is_current = (current_status == status_value)
        return (draft.status == status_value) and not is_current
    end
    local function _refresh_status_backgrounds()
        for _i, b in ipairs(status_buttons) do
            b.background = _is_staged_status(b._status_value) and STAGED_BG or nil
        end
    end
    local function status_button(label, status_value)
        local btn
        btn = {
            text_func = function()
                local t = label
                if current_status == status_value then
                    t = t .. "  \xE2\x9C\x93"  -- ✓
                end
                return t
            end,
            background = _is_staged_status(status_value) and STAGED_BG or nil,
            callback = function()
                if status_value == current_status then
                    -- Tap on persisted status: no-op.
                    return
                end
                if draft.status == status_value then
                    draft.status = nil  -- tap-again un-stages
                else
                    draft.status = status_value
                end
                _refresh_status_backgrounds()
                _reinitDialog()
            end,
        }
        btn._status_value = status_value
        status_buttons[#status_buttons + 1] = btn
        return btn
    end
    local status_row = {
        status_button(_("Unopened"), "new"),
        status_button(_("Reading"),  "reading"),
        status_button(_("On hold"),  "abandoned"),
        status_button(_("Finished"), "complete"),
    }

    -- Reset: KOReader's generator opens its own ConfirmBox with
    -- checkboxes (settings / cover / metadata). Close our dialog
    -- before the ConfirmBox shows so it appears on a clean backdrop;
    -- the generator's caller_callback runs only on confirmation.
    --
    -- Relabelled "Reset book data…" (the generator's default "Reset"
    -- collided with "Mark as new" -- both read as state-resets, but
    -- this one is the much wider sidecar purge with checkboxes for
    -- progress / bookmarks / highlights / notes / custom cover /
    -- custom metadata). The trailing ellipsis signals that tapping
    -- it opens a follow-up confirmation rather than firing
    -- immediately.
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local reset_btn = filemanagerutil.genResetSettingsButton(
        book.filepath, function()
            Repo.invalidateProgressCache(book.filepath)
            Repo.invalidateWalkCache()  -- sidecar gone -> walk results stale
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end)
    reset_btn.text = _("Reset book data\xE2\x80\xA6")
    local orig_reset_cb = reset_btn.callback
    reset_btn.callback = function()
        local discard_toast = isDirty()
        UIManager:close(dialog)
        orig_reset_cb()
        if discard_toast then
            UIManager:show(require("ui/widget/notification"):new{
                text    = _("Pending changes discarded"),
                timeout = 1,
            })
        end
    end

    -- Delete: prefer FileManager:showDeleteFileDialog when available so
    -- the per-file confirmation, history/collection cleanup, and sdr
    -- purge all match FM. Fall back to a minimal inline confirm +
    -- os.remove when bookshelf is running outside an FM context.
    --
    -- Destructive cue via a leading ✕ glyph plus the "Delete" word so
    -- the affordance is unambiguous. Stays in the standard cfont: the
    -- mdi-delete glyph the chip editor uses needs the symbols font,
    -- which doesn't carry Latin letters, and ButtonDialog rows only
    -- support a single font per button, so a real icon + text would
    -- need a custom widget. ✕ renders bold like every other button
    -- label here -- consistent weight reads as one cohesive row.
    --
    -- Like Reset, fires a "Pending changes discarded" toast when the
    -- draft was dirty at fire time -- the destructive op subsumes any
    -- non-destructive staging.
    local delete_btn = {
        text     = "\xE2\x9C\x95 " .. _("Delete"),  -- ✕ + Delete
        callback = function()
            local discard_toast = isDirty()
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
            if discard_toast then
                UIManager:show(require("ui/widget/notification"):new{
                    text    = _("Pending changes discarded"),
                    timeout = 1,
                })
            end
        end,
    }

    -- Bottom row: Select | Cancel | Apply.
    --   Select  -- meta action; disabled while the draft is dirty so
    --             the user has to Apply or Cancel first (avoids the
    --             ambiguity of whether Select should also commit the
    --             draft).
    --   Cancel  -- closes the dialog; draft is local so it's dropped
    --             automatically.
    --   Apply   -- enabled iff anything is staged; commits in
    --             deterministic order: status -> rating ->
    --             collections remove/add -> remove-history. Refresh
    --             metadata is no longer in this list -- it's an
    --             immediate action above (see refresh_button).
    --             Each step pcall-wrapped so a single failure doesn't
    --             abort the rest. Single _rebuild + setDirty at the
    --             end.
    local select_btn = {
        text = _("Select"),
        -- enabled_func re-evaluates on every paint (Button:paintTo calls
        -- enabled_func when present). A static `enabled = not isDirty()`
        -- was snapshotted at construction with an empty draft, so the
        -- value stayed `true` for the lifetime of the dialog.
        enabled_func = function() return not isDirty() end,
        callback = closing(function()
            if not bw._selection:isActive() then
                bw._selection:enterMode()
            end
            bw._selection:add(book.filepath)
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end),
    }
    local cancel_btn = {
        text = _("Cancel"),
        callback = closing(),
    }
    local apply_btn = {
        text    = _("Apply"),
        -- enabled_func re-evaluates on every paint. Critical bug fix:
        -- the static `enabled = isDirty()` was snapshotted as `false` at
        -- construction time (draft fresh and empty), and Button:init
        -- never re-read it on dialog:reinit -- Apply was permanently
        -- disabled, the user could not commit any staged changes.
        enabled_func = function() return isDirty() end,
        callback = function()
            local lfs = require("libs/libkoreader-lfs")
            if lfs.attributes(book.filepath, "mode") ~= "file" then
                UIManager:close(dialog)
                UIManager:show(require("ui/widget/infomessage"):new{
                    text    = _("File no longer exists."),
                    timeout = 3,
                })
                return
            end
            UIManager:close(dialog)
            -- Apply order: status -> rating -> collections (remove
            -- first, then add) -> remove_history. (refresh_metadata is
            -- no longer staged -- it fires immediately from its button
            -- and isn't recorded in `draft`.)
            -- pcall-wrap each step; failures logged via logger.warn so
            -- a single failing mutation doesn't abort the others.
            local logger = require("logger")
            local function safe(name, fn)
                local ok, err = pcall(fn)
                if not ok then
                    logger.warn("bookshelf draft apply:", name, book.filepath, err)
                end
            end
            if draft.status then
                safe("status", function()
                    local DocSettings = require("docsettings")
                    local ds = DocSettings:open(book.filepath)
                    local summary = ds:readSetting("summary") or {}
                    summary.status = draft.status
                    -- Stamp the modified date the same way KOReader's own
                    -- status writers do (filemanagerutil.saveSummary,
                    -- readerstatus, bookstatuswidget). Without this stamp
                    -- the status change is invisible to KOReader's
                    -- sort-by-recently-read and to any third-party
                    -- tooling that scrapes summary.modified. Reported in
                    -- issue #66.
                    summary.modified = os.date("%Y-%m-%d", os.time())
                    ds:saveSetting("summary", summary)
                    if draft.status == "new" then
                        ds:delSetting("percent_finished")
                        ds:delSetting("last_xp")
                        ds:delSetting("last_page")
                    end
                    ds:flush()
                    Repo.invalidateProgressCache(book.filepath)
                    Repo.invalidateBookCache("apply-status")
                    -- BookList.book_info_cache is keyed on filepath and is
                    -- the source the per-book menu reads via
                    -- BookList.getBookStatus(filepath) → "current_status"
                    -- at menu construction. Cover progress indicators
                    -- pick up the new status (they go via
                    -- Repo.readProgress whose cache we just invalidated),
                    -- but the menu's button-tick / staged-fill state read
                    -- stale "current" from this separate cache and the
                    -- next open couldn't change the status again until
                    -- the cache was busted by opening the book or
                    -- restarting KOReader. Reported on r/koreader.
                    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
                    if ok_bl and BookList and BookList.resetBookInfoCache then
                        BookList.resetBookInfoCache(book.filepath)
                    end
                end)
            end
            if draft.rating ~= false then
                -- skip_rebuild: the Apply loop issues a single _rebuild +
                -- setDirty at the end. Without this flag, _setBookRating
                -- would trigger an interim rebuild + e-ink paint before
                -- the remaining steps (collections, remove-history) ran,
                -- producing a spurious double refresh.
                safe("rating", function() bw:_setBookRating(book, draft.rating, { skip_rebuild = true }) end)
            end
            if draft.collections_remove then
                safe("collections_remove", function()
                    for name in pairs(draft.collections_remove) do
                        -- no_write=true on purpose: ReadCollection:removeItem's
                        -- internal write passes { collection_name = true } as
                        -- its updated_collections filter -- literal key, not
                        -- the variable -- so no real collection matches the
                        -- per-coll allowlist and nothing is re-serialised to
                        -- disk. The flush still bumps mtime, so the next
                        -- _read() reloads the unchanged disk state and the
                        -- in-memory removal is silently reverted. Skip the
                        -- broken internal write; the unconditional full
                        -- write() below persists every collection correctly.
                        -- Issue #75.
                        ReadCollection:removeItem(book.filepath, name, true)
                    end
                end)
            end
            if draft.collections_add then
                safe("collections_add", function()
                    for name in pairs(draft.collections_add) do
                        ReadCollection:addItem(book.filepath, name)
                    end
                end)
            end
            if draft.collections_add or draft.collections_remove then
                -- write() with no argument re-serialises every collection
                -- (the updated_collections allowlist is bypassed when nil),
                -- which also sidesteps the removeItem typo above. Must run
                -- for pure-removal edits too -- pre-fix the flush was nested
                -- inside the collections_add branch and removals were
                -- silently dropped on disk.
                safe("collections_flush", function()
                    require("readcollection"):write()
                end)
                -- Bust the chip-list cache so the collection chip reflects
                -- the new membership on next paint. Without this the chip
                -- holds the pre-edit list until something else invalidates
                -- (manual swipe-refresh, opening a book, etc).
                Repo.invalidateBookCache("apply-collections")
                -- Tag drilldowns (kind="tag") render from a books list
                -- captured in tip.payload.books at descend time --
                -- _fetchChipItems iterates that list rather than re-querying
                -- ReadCollection per render (see comment near line 2066).
                -- invalidateBookCache only busts the chip-level cache, not
                -- captured drilldown payloads, so without this scrub the
                -- book stays visible inside a collection drilldown until
                -- the user backs out and re-enters. Mirror payload
                -- mutations of removals and additions so the current view
                -- updates in-place.
                if bw._drilldown_path then
                    for _i, entry in ipairs(bw._drilldown_path) do
                        if entry and entry.kind == "tag"
                           and entry.payload
                           and type(entry.payload.books) == "table" then
                            local books = entry.payload.books
                            local removed_here =
                                draft.collections_remove and draft.collections_remove[entry.label]
                            local added_here =
                                draft.collections_add and draft.collections_add[entry.label]
                            if removed_here then
                                for i = #books, 1, -1 do
                                    if books[i] and books[i].filepath == book.filepath then
                                        table.remove(books, i)
                                    end
                                end
                            elseif added_here then
                                local present = false
                                for _j, b in ipairs(books) do
                                    if b and b.filepath == book.filepath then
                                        present = true; break
                                    end
                                end
                                if not present then
                                    books[#books + 1] = { filepath = book.filepath }
                                end
                            end
                        end
                    end
                end
            end
            if draft.remove_from_history then
                safe("remove_history", function()
                    require("readhistory"):removeItemByPath(book.filepath)
                    Repo.invalidateBookCache("apply-remove-history")
                end)
            end
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end,
    }

    -- Final assembly. Order:
    --   1. Show info / Collections / Rating
    --   2. Status row (Unopened / Reading / On hold / Finished)
    --   3. Reset book data… / Remove from history
    --   4. Delete / Refresh metadata
    --   5. Select / Cancel / Apply
    --
    -- Top row pairs Show info / Collections / Rating so the Collections
    -- button sits right under the header pills (visual anchor to the
    -- pill strip it manages). Destructive rows at the bottom-left,
    -- paired with their lighter cleanup sibling on the right.
    local buttons = {
        { show_info_button, tags_button, rating_button },
        { hardcover_button },
        status_row,
        { reset_btn,        remove_history_button, fav_button },
        { delete_btn,       refresh_button },
    }
    buttons[#buttons + 1] = { select_btn, cancel_btn, apply_btn }

    dialog = ButtonDialog:new{ buttons = buttons }
    -- Cover thumbnail + title/author/metadata/filename header above
    -- the button rows, with the tappable nav pill strip at the bottom
    -- of the header. addWidget composes header into the dialog's
    -- title group; no title= field on the dialog itself -- the header
    -- carries the book identity.
    local header = self:_buildBookMenuHeader(book, nil, pill_specs)
    if header then
        dialog:addWidget(header)
    end
    UIManager:show(dialog)
end

function BookshelfWidget:_openFolderMenu(folder)
    if not folder then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local bw = self
    local dialog
    local function info(text, timeout)
        local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
        if ok_info and InfoMessage then
            UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 2 })
        end
    end
    local function closing(fn)
        return function()
            if fn then fn() end
            UIManager:close(dialog)
        end
    end
    local function markRead()
        info(_("Marking folder as read..."), 1)
        UIManager:nextTick(function()
            local count = Repo.markFolderRead(folder.path, 3)
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
            info(string.format(_("Marked %d books as read"), count), 2)
        end)
    end
    dialog = ButtonDialog:new{
        title = folder.label or "Folder",
        buttons = {
            {
                { text = "Browse folder",
                  callback = closing(function() bw:_expandFolder(folder) end) },
            },
            {
                { text = "Mark folder as read",
                  callback = closing(markRead) },
            },
            {
                { text = "Pin folder to chip bar",
                  callback = closing(function()
                    UIManager:nextTick(function()
                        bw:_openGroupMenu(folder, "folder")
                    end)
                  end) },
            },
            {
                { text = "Cancel", callback = closing() },
            },
        },
    }
    UIManager:show(dialog)
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
    if     kind == "folder" then this_kind = _("this folder")
    elseif kind == "series" then this_kind = _("this series")
    elseif kind == "author" then this_kind = _("this author")
    elseif kind == "genre"  then this_kind = _("this genre")
    elseif kind == "tag"    then this_kind = _("this collection")
    elseif kind == "format" then this_kind = _("this format")
    elseif kind == "rating" then this_kind = _("this rating")
    else                         this_kind = _("this group")
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
        BookshelfSettings.save("active_chip", new_id)
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

-- _openSeriesMenu kept as a back-compat alias; the _openBookMenu
-- dispatch checks item.books to route series groups here, so the
-- existing call site keeps working. New code should call
-- _openGroupMenu directly.
function BookshelfWidget:_openSeriesMenu(series)
    self:_openGroupMenu(series)
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
    -- Stash the cursor the *outer* context was showing so a later pop can
    -- restore it. Without this, drilling into a folder on page 3 and then
    -- backing out drops you on page 1 of the parent listing — disorienting
    -- when the parent has dozens of folders/series.
    entry.parent_cursor = self._cursor
    self._drilldown_path[#self._drilldown_path + 1] = entry
    self._cursor = 1
    self.page = 1
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
    -- The first entry we're about to pop carries `parent_cursor` — the cursor
    -- the level we're returning to was on before this drill. Snapshot it
    -- before tearing the entry down.
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
        for _, entry in ipairs(restore_path) do
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
        BookshelfSettings.save(self:_profileSettingKey(), key)
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
    for _, b in ipairs(group.books) do fp_to_book[b.filepath] = b end
    local new_books = {}
    for _, m in ipairs(group.books_meta) do
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
    local results = Repo.searchAll(query, self:_profileScope())
    -- Don't store the hydrated records in the drill payload -- their
    -- cover_bb gets freed by ImageWidget after first paint, and any
    -- subsequent re-render (e.g. backing out of a drilled-into stack)
    -- would read freed memory and corrupt the cover (see memory
    -- feedback_image_disposable_shared_book). Stash identifiers only;
    -- _fetchChipItems re-hydrates on every render so covers are always
    -- fresh.
    local author_names, series_names, genre_names = {}, {}, {}
    for _, g in ipairs(results.authors or {}) do author_names[#author_names + 1] = g.series_name end
    for _, g in ipairs(results.series  or {}) do series_names[#series_names + 1] = g.series_name end
    for _, g in ipairs(results.genres  or {}) do genre_names[#genre_names + 1]   = g.series_name end
    local folders = {}
    for _, f in ipairs(results.folders or {}) do
        folders[#folders + 1] = {
            path          = f.path,
            label         = f.label,
            first_book_fp = f.first_book and f.first_book.filepath,
        }
    end
    local book_fps = {}
    for _, b in ipairs(results.books or {}) do
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
