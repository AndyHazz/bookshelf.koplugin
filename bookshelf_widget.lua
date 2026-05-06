-- bookshelf_widget.lua
-- The top-level home screen widget. Composes HeroCard + ChipStrip
-- + two ShelfRows + chevron pagination footer. Owns chip-state and refresh.
--
local InputContainer  = require("ui/widget/container/inputcontainer")
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
local Screen          = require("device").screen

local _           = require("bookshelf_i18n").gettext

local Repo        = require("book_repository")
local HeroCard    = require("hero_card")
local ChipStrip   = require("chip_strip")
local ShelfRow    = require("shelf_row")

-- ─── BookshelfWidget ──────────────────────────────────────────────────────────

local BookshelfWidget = InputContainer:extend{
    name = "bookshelf",
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

-- _computeSortFingerprint() — string repr of the four KOReader settings that
-- determine the "All" chip's listing order. Stored on the widget after each
-- _rebuild so main.lua's FileChooser:refreshPath wrapper (auto-refresh-on-sort
-- beta) can detect a real change vs spurious refreshPath fires.
function BookshelfWidget._computeSortFingerprint()
    local rs = G_reader_settings
    local filter = rs:readSetting("show_filter") or {}
    local status = filter.status
    local status_keys = ""
    if type(status) == "table" then
        local keys = {}
        for k, v in pairs(status) do
            if v then keys[#keys + 1] = tostring(k) end
        end
        table.sort(keys)
        status_keys = table.concat(keys, ",")
    end
    return table.concat({
        rs:readSetting("collate") or "",
        tostring(rs:readSetting("reverse_collate") and true or false),
        tostring(rs:readSetting("collate_mixed") and true or false),
        status_keys,
    }, "|")
end

function BookshelfWidget:init()
    self.width  = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen  = Geom:new{ w = self.width, h = self.height }
    self.chip   = G_reader_settings:readSetting("bookshelf_active_chip") or "recent"
    self.page   = 1   -- 1-based; 8 books per page (4 cols × 2 shelves)
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
    self.ges_events = {
        SwipeNextPage = {
            GestureRange:new{ ges = "swipe", range = self.dimen, direction = "west" },
        },
        SwipePrevPage = {
            GestureRange:new{ ges = "swipe", range = self.dimen, direction = "east" },
        },
    }

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
        local zone_lists = {}
        if fm and fm._ordered_touch_zones then
            zone_lists[#zone_lists + 1] = fm._ordered_touch_zones
        end
        if fm and fm.menu and fm.menu._ordered_touch_zones then
            zone_lists[#zone_lists + 1] = fm.menu._ordered_touch_zones
        end
        for _, zones in ipairs(zone_lists) do
            for _, tzone in ipairs(zones) do
                if tzone.gs_range:match(ev) and tzone.handler(ev) then
                    return true
                end
            end
        end
        return false
    end

    if InputContainer.handleEvent(self, event) then return true end
    -- Forward unhandled events to FM so Dispatcher action events
    -- (IncreaseFlIntensity, ToggleNightMode, etc.) reach FM's registered
    -- modules. EXCLUDE lifecycle events that target THIS widget — without
    -- the blacklist, UIManager:close(self) propagates CloseWidget to us,
    -- which forwards it to FM, which then tears itself down (nil'ing
    -- FileManager.instance). That breaks all subsequent gesture forwarding.
    local NEVER_FORWARD = {
        onCloseWidget   = true,
        onFlushSettings = true,
        onShow          = true,
        onClose         = true,
    }
    if NEVER_FORWARD[event.handler] then return end
    local fm = require("apps/filemanager/filemanager").instance
    if fm and fm ~= self then
        return fm:handleEvent(event)
    end
end

-- ─── _rebuild ─────────────────────────────────────────────────────────────────

function BookshelfWidget:_rebuild()
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
    local content_w   = self.width - PAD * 2

    -- Height constants. Size.item.height_small does not exist (Phase 3-5 lesson);
    -- use height_default (~30dp) for the chip strip.
    local chip_h  = Size.item.height_default
    -- Pagination footer reservation. The previous Size.item.height_default
    -- (~30dp) under-counted the actual chevron-button row by ~12dp and the
    -- footer was pushed off-screen at high DPI as the under-count multiplied
    -- through scaleBySize. Now match the *actual* footer geometry one-for-one
    -- with what _buildPaginationFooter constructs: chev_size (32dp icon) plus
    -- the CenterContainer's vertical padding on each side.
    local footer_h = Screen:scaleBySize(32) + Size.padding.default * 2
    local label_h  = footer_h

    -- Detect "all chips disabled" early so the hero can grow into the
    -- chip strip's vertical footprint when it would otherwise be empty.
    -- The chip strip stays visible whenever a drill-down path is active
    -- (so the user can navigate back via the breadcrumb), even if every
    -- chip is disabled.
    local CHIP_LABELS = {
        all = "Home", recent = "Recent", latest = "Latest",
        series = "Series", authors = "Authors", genres = "Genres",
        tags = "Tags", favorites = "Favourites",
    }
    -- "All" leads (folder-aware browse rooted at home_dir, honours the
    -- user's KOReader collate / reverse / mixed / book-status-filter
    -- settings via FileChooser:genItemTableFromPath).
    local CHIP_ORDER = {
        "all", "recent", "latest", "series", "authors", "genres",
        "tags", "favorites",
    }
    local disabled_set = G_reader_settings:readSetting("bookshelf_chips_disabled") or {}
    local active_chips = {}
    for _, key in ipairs(CHIP_ORDER) do
        if not disabled_set[key] then
            active_chips[#active_chips + 1] = { key = key, label = CHIP_LABELS[key] }
        end
    end
    -- Hide the strip when 0 or 1 chips are enabled (a single full-width
    -- chip is just a non-interactive label) AND no drill-down is active
    -- (the breadcrumb still needs the strip's slot for back-navigation).
    local hide_chip_strip = (#active_chips <= 1) and (#self._drilldown_path == 0)
    -- Defensive: the user can disable every chip via the settings menu.
    -- Fall back to the canonical four for chip selection so the shelves
    -- still have a data source even when the strip is hidden.
    if #active_chips == 0 then
        for _, key in ipairs(CHIP_ORDER) do
            active_chips[#active_chips + 1] = { key = key, label = CHIP_LABELS[key] }
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
        self.chip = active_chips[1].key
        G_reader_settings:saveSetting("bookshelf_active_chip", self.chip)
    end
    -- Append a search "chip" (icon-only, action-on-tap rather than
    -- chip-switch). Always appended last so it sits at the right edge.
    -- Tap is intercepted in the on_change closure below — search never
    -- becomes self.chip, so it doesn't enter the swipe-cycle.
    -- Nerd-font glyph U+F002 (fa-search) renders bolder than the
    -- bundled mdlight appbar.search SVG; ChipStrip threads it through
    -- a TextWidget with KOReader's xtext fallback to symbols.ttf.
    active_chips[#active_chips + 1] = { key = "search", nerd_glyph = "\xEF\x80\x82" }
    -- Cache the ordered chip keys + hidden state so the edge-swipe
    -- handlers can cycle between tabs without re-deriving them. The
    -- list reflects whatever ordering active_chips had built (today
    -- it follows CHIP_ORDER, future user-driven reordering would
    -- fill the same slot).
    self._active_chip_keys = {}
    for _, c in ipairs(active_chips) do
        -- Exclude the search action chip from the swipe-cycle ring —
        -- it's an action, not a navigable tab.
        if c.key ~= "search" then
            self._active_chip_keys[#self._active_chip_keys + 1] = c.key
        end
    end
    self._chip_strip_hidden = hide_chip_strip

    -- Hero card sized exactly to its cover (no internal padding budget). The
    -- VerticalSpan separators below the hero supply the gap to the chips, so
    -- adding internal padding here would double-count the space.
    local hero_cover_w = math.floor(content_w * 0.30)
    local hero_cover_h = math.floor(hero_cover_w * 1.5)
    local hero_h       = hero_cover_h
    if hide_chip_strip then
        -- Absorb chip_h + ONE adjacent PAD span. The other PAD span stays
        -- so the hero still has breathing room above the shelves. The
        -- 2:3 cover aspect ratio is preserved — both cover_w and cover_h
        -- grow proportionally.
        local freed = chip_h + PAD
        hero_h       = hero_h + freed
        hero_cover_h = hero_h
        hero_cover_w = math.floor(hero_cover_h / 1.5)
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
    local reserved_h
    if hide_chip_strip then
        reserved_h = titlebar_h + hero_h + label_h + PAD * 3
    else
        reserved_h = titlebar_h + hero_h + chip_h + label_h + PAD * 4
    end
    local shelf_h = math.floor((self.height - reserved_h) / 2)

    -- ── Hero card ─────────────────────────────────────────────────────────────
    -- Hero shows the user's "selected" book: a previewed shelf book if any,
    -- otherwise the lastfile-resolved currently-reading book. Tapping the
    -- hero opens whichever book is shown; tapping a shelf cover sets the
    -- preview without opening.
    --
    -- _buildHero is factored out so _previewBook can swap just the hero into
    -- the existing tree without rebuilding chips/shelves/pagination — see
    -- the fast-path in _previewBook below.
    local hero = self:_buildHero(content_w, hero_cover_w, hero_cover_h, hero_h, PAD)
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
    -- Skipped entirely when hide_chip_strip is true (every chip
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
    -- Search-mode chip pill: the search nerd-font glyph (U+F002) replaces
    -- the active chip's name so the user reads "[search-icon] > query"
    -- instead of "[CHIP] > query" — search is a separate context, not a
    -- filter applied within the active chip.
    local chip_pill_glyph = in_search_mode and "\xEF\x80\x82" or nil
    local chips = not hide_chip_strip and ChipStrip:new{
        chips             = active_chips,
        active            = self.chip,
        width             = content_w,
        height            = chip_h,
        breadcrumb_path   = breadcrumb_path,
        chip_pill_label   = CHIP_LABELS[self.chip] or self.chip,
        chip_pill_glyph   = chip_pill_glyph,
        on_change = function(key)
            -- Search "chip" is an action, not a navigable tab — open
            -- the search dialog and bail before switching self.chip.
            if key == "search" then
                self:_openSearchDialog()
                return
            end
            -- Switch chips → reset drill path and page; preserve
            -- _preview_book so the user's "current selection" survives
            -- a tab tour. The highlight on the new chip's shelf only
            -- paints when the previewed book happens to be visible
            -- there; the hero still shows the previewed book in any
            -- case (it's bound to _preview_book, not the chip).
            self._drilldown_path = {}
            self.chip            = key
            self.page            = 1
            G_reader_settings:saveSetting("bookshelf_active_chip", key)
            self:_rebuild()
            UIManager:setDirty(self, "ui")
        end,
        on_breadcrumb = function(depth)
            -- depth 0 = chip pill (back to top level for this chip).
            -- depth N = pop the path so the Nth crumb is the deepest.
            self:_drillBackTo(depth)
        end,
    }

    -- ── Shelf items ───────────────────────────────────────────────────────────
    -- Pagination: 8 per page (4 covers × 2 shelves). Fetch enough items to
    -- cover all pages, then slice the current window.
    local PAGE_SIZE  = 8
    -- Cap the fetch at a sane upper bound — far below "9999" and well above
    -- realistic libraries (50 pages × 8 = 400 items). This keeps allocation
    -- bounded so a degenerate library size can't blow up GC pressure on
    -- chip switches, while still letting the chevron pagination display
    -- "Page X of Y" accurately for any reasonable user.
    local MAX_FETCH  = 400
    local all_items  = self:_fetchChipItems(MAX_FETCH) or {}
    local total      = #all_items
    local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
    if self.page > total_pages then self.page = total_pages end
    if self.page < 1 then self.page = 1 end
    -- Cache for the swipe handlers (which run outside _rebuild's scope).
    self._total_pages = total_pages
    local start_idx  = (self.page - 1) * PAGE_SIZE + 1
    local items      = {}
    for i = 0, PAGE_SIZE - 1 do items[i + 1] = all_items[start_idx + i] end
    local shown      = #items
    -- Only count non-nil entries (the last page may be partial).
    local shown_count = 0
    for i = 1, PAGE_SIZE do if items[i] then shown_count = shown_count + 1 end end

    -- ── Empty-state placeholder (spec §8: "Selected chip yields zero books") ────
    -- When the active chip returns no items, replace both shelf rows with a
    -- single paper-card placeholder carrying chip-specific guidance text.
    -- This path is reached for:
    --   • "favorites"  when ReadCollection.favorites is empty or missing
    --   • "series"     when no books in ReadHistory carry series metadata
    --   • "recent"     when ReadHistory is empty
    --   • "latest"     when home_dir is empty / yields no supported files
    if #items == 0 then
        local placeholder_text
        local _tip = self._drilldown_path[#self._drilldown_path]
        if _tip and _tip.kind == "search" then
            placeholder_text = string.format(
                _("No matches for \"%s\""), _tip.payload.query or "")
        elseif self.chip == "series" then
            placeholder_text = _("Nothing in Series yet · Add series metadata to your books and they will appear here")
        elseif self.chip == "authors" then
            placeholder_text = _("No authors yet · Add author metadata to your books and they will appear here")
        elseif self.chip == "genres" then
            placeholder_text = _("No genres yet · Add keywords or subject metadata to your books and they will appear here")
        elseif self.chip == "tags" then
            placeholder_text = _("No tags yet · Long-press a book and tap 'Add to collection' to create one")
        elseif self.chip == "favorites" then
            placeholder_text = _("No favourites yet · Long-press a book and tap 'Add to favourites'")
        elseif self.chip == "latest" then
            placeholder_text = _("No books found · Set your library folder in Settings then tap Latest")
        else
            placeholder_text = string.format(_("No books in %s yet"), self:_chipLabel())
        end

        -- Blitbuffer.gray semantics: 0 = white, 1 = black (i.e. "blackness level").
        -- Page background is plain white (matches e-ink unprinted paper);
        -- placeholder card has a faint grey tint to set it apart from the page.
        local paper_bg = Blitbuffer.COLOR_WHITE
        local card_bg  = Blitbuffer.gray(0.07)

        local placeholder = FrameContainer:new{
            bordersize = Size.border.thin,
            background = card_bg,
            padding    = Size.padding.large,
            width      = content_w,
            TextBoxWidget:new{
                text      = placeholder_text,
                face      = Font:getFace("infofont", 12),
                width     = content_w - Size.padding.large * 2,
                alignment = "center",
            },
        }

        local VerticalSpan = require("ui/widget/verticalspan")
        local empty_vgroup
        if hide_chip_strip then
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
        self._sort_fingerprint = BookshelfWidget._computeSortFingerprint()
        return
    end

    local row_top, row_bottom = self:_buildShelfRows(items, content_w, shelf_h, PAD)
    local label_widget = self:_buildPaginationFooter(content_w, label_h, total_pages)

    -- Kick off BIM extraction for any displayed books with no cached
    -- metadata. Cover-spec dims = single shelf slot.
    local n_slots = 4
    local slot_w  = math.floor((content_w - PAD * (n_slots - 1)) / n_slots)
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
    local inner_vgroup
    if hide_chip_strip then
        inner_vgroup = VerticalGroup:new{
            align = "left",
            hero,
            VerticalSpan:new{ width = PAD },
            row_top,
            VerticalSpan:new{ width = PAD },
            row_bottom,
            VerticalSpan:new{ width = PAD },
            label_widget,
        }
    else
        inner_vgroup = VerticalGroup:new{
            align = "left",
            hero,
            VerticalSpan:new{ width = PAD },
            chips,
            VerticalSpan:new{ width = PAD },
            row_top,
            VerticalSpan:new{ width = PAD },
            row_bottom,
            VerticalSpan:new{ width = PAD },
            label_widget,
        }
    end
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
        -- Index layout depends on whether the chip strip is in the
        -- vgroup. With chips: hero, span, chips, span, ROW_TOP, span,
        -- ROW_BOTTOM, span, FOOTER → indices 5/7/9. Without chips:
        -- hero, span, ROW_TOP, span, ROW_BOTTOM, span, FOOTER → 3/5/7.
        shelf_top_idx    = hide_chip_strip and 3 or 5,
        shelf_bottom_idx = hide_chip_strip and 5 or 7,
        footer_idx       = hide_chip_strip and 7 or 9,
    }
    local inner_content = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = PAD,
        padding_right = PAD,
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
        },
    }
    self._sort_fingerprint = BookshelfWidget._computeSortFingerprint()
end

-- ─── Background metadata extraction ──────────────────────────────────────────

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
    if #files > 0 then
        UIManager:nextTick(function()
            pcall(function() BIM:extractInBackground(files) end)
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
local BIM_POLL_INTERVAL_S  = 3
local BIM_POLL_MAX_ATTEMPTS = 20
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
    if not files or #files == 0 then return end
    local ok, BIM = pcall(require, "bookinfomanager")
    if not ok or not BIM or not BIM.getBookInfo then
        self._bim_poll_files = nil
        return
    end
    local max_tries = BIM.max_extract_tries or 3
    local any_new       = false
    local still_pending = {}
    for _, f in ipairs(files) do
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
        if meta_ready and info.has_cover == "Y" then
            cover_ready = not BookshelfWidget._coverNeedsResize(info, f.cover_specs)
        end
        if meta_ready and inprog == 0 and cover_ready then
            any_new = true
        elseif info and inprog >= max_tries then
            -- BIM gave up on this file; stop watching it.
        else
            still_pending[#still_pending + 1] = f
        end
    end
    self._bim_poll_files = #still_pending > 0 and still_pending or nil
    if any_new and self._inner_vgroup and self._shelf_dims then
        -- _swapShelvesInPlace re-fetches Book records (which re-query
        -- BIM) and re-arms polling for whatever is still missing.
        self:_swapShelvesInPlace()
        -- The hero book may have been re-extracted too (it's queued
        -- explicitly in _kickOffMissingMetaExtraction). Swap the hero
        -- card so its cover picks up the new cached bb — _swapShelves
        -- doesn't touch the hero by design.
        if self._hero_parent and self._hero_dims then
            self:_swapHeroInPlace()
        end
        return
    end
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
    -- Drill into a group (series / author / genre / tag): payload.books
    -- already carries Book records, but their cover_bbs may have been
    -- freed by a prior render. Rebuild meta-only from filepath to refresh.
    if tip and (tip.kind == "series" or tip.kind == "author"
            or tip.kind == "genre" or tip.kind == "tag"
            or tip.kind == "search") then
        local fresh = {}
        for _, b in ipairs(tip.payload.books) do
            local nb = b.filepath and Repo.buildBookMeta(b.filepath) or b
            fresh[#fresh + 1] = nb
        end
        return fresh
    end
    if tip and tip.kind == "folder" then
        return Repo.getAll(tip.payload.path, n)
    end
    if self.chip == "all"       then return Repo.getAll(nil, n)     end
    if self.chip == "recent"    then return Repo.getRecent(n)       end
    if self.chip == "latest"    then return Repo.getLatest(n)       end
    if self.chip == "series"    then return Repo.getSeriesGroups(n) end
    if self.chip == "authors"   then return Repo.getAuthors(n)      end
    if self.chip == "genres"    then return Repo.getGenres(n)       end
    if self.chip == "tags"      then return Repo.getTags(n)         end
    if self.chip == "favorites" then return Repo.getFavorites(n)    end
    return {}
end

-- _chipLabel()  — human-readable shelf heading for the active chip.
function BookshelfWidget:_chipLabel()
    local tip = self._drilldown_path[#self._drilldown_path]
    if tip then
        return tip.label or "Drill-down"
    end
    local labels = {
        recent    = "Recently read",
        latest    = "Latest additions",
        series    = "Your series",
        authors   = "Authors",
        genres    = "Genres",
        tags      = "Tags",
        favorites = "Favourites",
    }
    return labels[self.chip] or ""
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
    -- Preserve self.chip / self.page / self._drilldown_path / self._preview_book
    -- across the read so closing the book lands the user back where they were.
    -- Suspend the status timer + drop any pending debounced repaint
    -- before the reader takes over. Keeping the minute heartbeat alive
    -- under the reader is wasted Lua wakeups — battery matters most
    -- during a long read. Bookshelf:show() re-arms us when the user
    -- closes the book.
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
    local current
    if self._preview_book and self._preview_book.filepath then
        current = Repo.buildBook(self._preview_book.filepath) or self._preview_book
        self._preview_book = current
    else
        current = Repo.getCurrent()
    end
    if current then Repo.enrichStats(current) end
    return HeroCard:new{
        book         = current,
        width        = content_w,
        height       = hero_h,
        cover_w      = hero_cover_w,
        cover_h      = hero_cover_h,
        pad          = PAD,
        device_state = self:_buildDeviceState(),
        on_tap       = function(b) self:_openBook(b) end,
        on_hold      = function(b) self:_openBookMenu(b) end,
    }
end

-- _buildShelfRows — top + bottom shelf row from the page's items slice.
-- Extracted so _swapShelvesInPlace can construct them without re-running
-- the full _rebuild path (which would also rebuild hero + chips).
function BookshelfWidget:_buildShelfRows(items, content_w, shelf_h, PAD)
    local items_top, items_bottom = {}, {}
    for i = 1, 4 do items_top[i]    = items[i]      end
    for i = 1, 4 do items_bottom[i] = items[i + 4]  end
    local bw = self
    -- Highlight the spine that matches the currently-previewed filepath
    -- so the user sees which book is showing in the hero. The row builder
    -- threads this down to each SpineWidget; nil means no spine is
    -- highlighted (no preview active).
    local selected_filepath = self._preview_book and self._preview_book.filepath
    local row_opts = {
        width             = content_w,
        height            = shelf_h,
        gap               = PAD,
        selected_filepath = selected_filepath,
        on_book_tap       = function(b) bw:_previewBook(b) end,
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
    row_opts.items = items_top
    local row_top = ShelfRow.new(row_opts)
    row_opts.items = items_bottom
    local row_bottom = ShelfRow.new(row_opts)
    return row_top, row_bottom
end

-- _buildPaginationFooter — chevron nav (or series-back label when expanded).
-- Extracted so _swapShelvesInPlace can construct a fresh footer reflecting
-- the new page's button-enabled states.
function BookshelfWidget:_buildPaginationFooter(content_w, label_h, total_pages)
    local Button         = require("ui/widget/button")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local bw = self
    -- The footer is always pagination chevrons + page label, regardless
    -- of drill state. Earlier the footer doubled as a "← back to chips"
    -- label inside an expanded series, but that hijacked the only
    -- pagination affordance — series with >8 books couldn't be paged
    -- through. Back-out now lives in the chip strip's breadcrumb mode
    -- (tap the chip pill / a crumb), freeing this footer for chevrons
    -- everywhere.
    local chev_size = Screen:scaleBySize(32)
    local nav_span  = Screen:scaleBySize(32)
    local function go(p)
        return function() bw.page = p; bw:_swapShelvesInPlace() end
    end
    local first = Button:new{
        icon = "chevron.first", icon_width = chev_size, icon_height = chev_size,
        callback = go(1), bordersize = 0, enabled = self.page > 1, show_parent = self,
    }
    local prev = Button:new{
        icon = "chevron.left",  icon_width = chev_size, icon_height = chev_size,
        callback = go(self.page - 1), bordersize = 0,
        enabled = self.page > 1, show_parent = self,
    }
    local page_text = Button:new{
        text = string.format("Page %d of %d", self.page, total_pages),
        text_font_size = 15,
        callback = function() end,
        bordersize = 0, show_parent = self,
    }
    local next_btn = Button:new{
        icon = "chevron.right", icon_width = chev_size, icon_height = chev_size,
        callback = go(self.page + 1), bordersize = 0,
        enabled = self.page < total_pages, show_parent = self,
    }
    local last = Button:new{
        icon = "chevron.last", icon_width = chev_size, icon_height = chev_size,
        callback = go(total_pages), bordersize = 0,
        enabled = self.page < total_pages, show_parent = self,
    }
    local nav = HorizontalGroup:new{
        align = "center",
        first,    HorizontalSpan:new{ width = nav_span },
        prev,     HorizontalSpan:new{ width = nav_span },
        page_text,HorizontalSpan:new{ width = nav_span },
        next_btn, HorizontalSpan:new{ width = nav_span },
        last,
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = chev_size + Size.padding.default * 2 },
        nav,
    }
end

-- _swapShelvesInPlace — pagination fast-path. Rebuilds only the shelf rows
-- + footer, leaving hero + chips intact. Avoids redundant work (the chips
-- never change with self.page; the hero only changes with _preview_book)
-- AND avoids the use-after-free path where _buildHero rebuilds a SpineWidget
-- against a freed BIM bb on _preview_book.cover_bb.
function BookshelfWidget:_swapShelvesInPlace()
    if not self._inner_vgroup or not self._shelf_dims then
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        return
    end
    local d = self._shelf_dims
    local PAGE_SIZE = 8
    local MAX_FETCH = 400
    local all_items = self:_fetchChipItems(MAX_FETCH) or {}
    local total = #all_items
    local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
    if self.page > total_pages then self.page = total_pages end
    if self.page < 1 then self.page = 1 end
    self._total_pages = total_pages
    if total == 0 then
        -- Going to empty state needs a structural change (hero + chips +
        -- placeholder, no shelves) — fall back to full rebuild.
        self:_rebuild()
        UIManager:setDirty(self, "ui")
        return
    end
    local start_idx = (self.page - 1) * PAGE_SIZE + 1
    local items = {}
    for i = 0, PAGE_SIZE - 1 do items[i + 1] = all_items[start_idx + i] end

    local row_top, row_bottom = self:_buildShelfRows(items, d.content_w, d.shelf_h, d.PAD)
    local footer = self:_buildPaginationFooter(d.content_w, d.label_h, total_pages)

    -- Kick off BIM extraction for newly-paginated books that aren't
    -- cached yet. Same slot + hero dims as _rebuild's call so both
    -- consumers get a single cached cover sized for the bigger of the two.
    local n_slots = 4
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
        for _, w in ipairs({ old_top, old_bottom, old_footer }) do
            if w and w.free then pcall(function() w:free() end) end
        end
    end)
    UIManager:setDirty(self, "ui")
end

-- Rebuild the hero from current state and swap it into _hero_parent[1].
-- Shared between _previewBook (synchronous swap on user tap) and the async
-- cover-load completion path. No-op if there's no live tree to swap into.
function BookshelfWidget:_swapHeroInPlace()
    if not self._hero_parent or not self._hero_dims then return end
    local d = self._hero_dims
    local new_hero = self:_buildHero(
        d.content_w, d.hero_cover_w, d.hero_cover_h, d.hero_h, d.PAD)
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
    local hero = self._hero_parent[1]
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
function BookshelfWidget:_previewBook(book)
    if not book or not book.filepath then return end
    -- Tap-twice-to-open: a tap on the already-selected spine confirms
    -- the preview and opens the book. Composes with the spine highlight
    -- — first tap marks the spine with the thicker border, second tap
    -- on the same spine commits.
    if self._preview_book and self._preview_book.filepath == book.filepath then
        self:_openBook(book)
        return
    end
    -- Shelf books are built via buildBookMeta (no DocSettings) for speed.
    -- The hero needs book_pct / page_num / last_xp to render the progress
    -- bar and token lines, so upgrade to the full Book record here. Single-
    -- book DocSettings read on each preview tap is fine.
    self._preview_book = Repo.buildBook(book.filepath) or book

    if self._hero_parent and self._hero_dims then
        self:_swapHeroInPlace()
        -- Refresh the shelves so the new selected-spine highlight paints
        -- and any previously-selected spine returns to the normal border.
        -- Cheap (8 SpineWidget rebuilds, scaled covers reused from cache).
        if self._inner_vgroup and self._shelf_dims then
            self:_swapShelvesInPlace()
        end
        return
    end

    -- Cold path: no live tree to swap into yet. Full rebuild.
    self:_rebuild()
    UIManager:setDirty(self, "ui")
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
    local Regions = require("hero_regions")
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
        if UIManager:getTopmostVisibleWidget() ~= self then return end
        if not (self._hero_parent and self._hero_parent[1]
                and self._hero_parent[1].replaceRightColumn) then return end
        if not self:_anyActiveRegionUses(tokens) then return end
        local Regions = require("hero_regions")
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
    if UIManager:getTopmostVisibleWidget() == self
            and self._hero_parent
            and self._hero_parent[1]
            and self._hero_parent[1].replaceRightColumn then
        local Regions = require("hero_regions")
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

-- _setActiveChip(key) — switch tabs as if the user tapped a chip.
-- Mirrors the on_change closure in _rebuild so swipe-cycling and tap
-- both produce identical state transitions.
function BookshelfWidget:_setActiveChip(key)
    if not key or key == self.chip then return end
    self._drilldown_path = {}
    self.chip            = key
    self.page            = 1
    G_reader_settings:saveSetting("bookshelf_active_chip", key)
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

-- _previewNeighbourBook(direction) — cycle self._preview_book through the
-- current chip's books in order (skipping series groups, which can't be
-- previewed). direction = +1 for next, -1 for previous. Wraps at edges.
-- Crosses page boundaries by recomputing self.page from the target book's
-- position in the unsliced list.
function BookshelfWidget:_previewNeighbourBook(direction)
    local PAGE_SIZE = 8
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
    -- Update page so the new preview is on the visible shelf — otherwise
    -- _previewBook's swap-shelves-in-place would highlight a book that
    -- isn't currently rendered.
    local all_idx = books_to_all[next_idx]
    if all_idx then
        self.page = math.floor((all_idx - 1) / PAGE_SIZE) + 1
    end
    self:_previewBook(target)
end

function BookshelfWidget:onSwipeNextPage(_, ges)
    -- Hero-area swipe: cycle preview to next book. Stays inside the
    -- chip; pages flip automatically when the next book lives on a
    -- different page than the current preview.
    if self:_isHeroSwipe(ges) then
        self:_previewNeighbourBook(1)
        return true
    end
    -- Pagination works inside drilled views too — a series / folder with
    -- >8 books needs to page through. Earlier this early-returned on
    -- _expanded_series because the footer label was hijacked for back;
    -- breadcrumb mode in the chip strip handles back now.
    local total = self._total_pages or 1
    if self.page < total then
        self.page = self.page + 1
        self:_swapShelvesInPlace()
        return true
    end
    -- Last page at top level (no drill-down) and chip strip visible
    -- → cycle to the next tab (with wrap). Drilled-in last page is
    -- left as a no-op; back-navigation there happens via the
    -- breadcrumb or east-swipe.
    if #self._drilldown_path == 0 and not self._chip_strip_hidden then
        local next_key = self:_chipNeighbour(1)
        if next_key then self:_setActiveChip(next_key) end
    end
    return true
end
function BookshelfWidget:onSwipePrevPage(_, ges)
    if self:_isHeroSwipe(ges) then
        self:_previewNeighbourBook(-1)
        return true
    end
    if self.page > 1 then
        self.page = self.page - 1
        self:_swapShelvesInPlace()
        return true
    end
    -- Already on page 1: if drilled into a folder/series, treat the
    -- east-swipe as "go up a level" (mirrors tapping the previous
    -- breadcrumb crumb / the chip pill at depth 1). Discoverable
    -- escape from drill-down without aiming at the breadcrumb.
    if #self._drilldown_path > 0 then
        self:_drillBackTo(#self._drilldown_path - 1)
        return true
    end
    -- Top level + page 1 + chip strip visible → cycle to previous tab
    -- (with wrap). Hidden strip means 0 or 1 effective tab; cycling
    -- would either no-op or surface a hidden chip silently, neither
    -- helpful.
    if not self._chip_strip_hidden then
        local prev_key = self:_chipNeighbour(-1)
        if prev_key then self:_setActiveChip(prev_key) end
    end
    return true
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
                  callback = closing(function() require("settings"):show(bw) end) },
                { text = "About",
                  callback = closing(function() require("settings"):_about() end) },
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
    dialog = ButtonDialog:new{
        title = book.title or book.filename or "Book",
        buttons = {
            {
                { text = "Show info",
                  callback = closing(function()
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
                    -- Toggle favourite status. KOReader API quirk: removeItem
                    -- writes the collections file to disk automatically;
                    -- addItem only updates in-memory state and relies on a
                    -- caller-side :write() to persist. Without the explicit
                    -- write, additions are lost on the next KOReader restart.
                    local ok, already = pcall(function()
                        return ReadCollection:isFileInCollection(book.filepath, "favorites")
                    end)
                    if ok and already then
                        ReadCollection:removeItem(book.filepath, "favorites")
                    else
                        ReadCollection:addItem(book.filepath, "favorites")
                        ReadCollection:write({ favorites = true })
                    end
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                  end) },
            },
            {
                { text = "Remove from history",
                  callback = closing(function()
                    require("readhistory"):removeItemByPath(book.filepath)
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                  end) },
            },
            {
                { text = "Cancel", callback = closing() },
            },
        },
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
-- the path's tip. Pagination + preview reset on every drill so you land
-- on page 1 and the hero re-derives.
function BookshelfWidget:_drillInto(entry)
    if not entry or not entry.kind then return end
    -- Stash the page the *outer* context was showing so a later pop can
    -- restore it. Without this, drilling into a folder on page 3 and then
    -- backing out drops you on page 1 of the parent listing — disorienting
    -- when the parent has dozens of folders/series.
    entry.parent_page = self.page
    self._drilldown_path[#self._drilldown_path + 1] = entry
    self.page = 1
    -- Pre-select the first item of the drilled-in target so the hero
    -- reflects what the user just tapped (rather than falling back to
    -- Repo.getCurrent() = lastfile, which is unrelated to the
    -- drill-in target and reads as "the wrong book leaked in").
    -- The shelf below shows the same book with a selection border.
    self._preview_book = nil
    if (entry.kind == "series" or entry.kind == "author"
            or entry.kind == "genre" or entry.kind == "tag"
            or entry.kind == "search")
            and entry.payload and entry.payload.books then
        local first = entry.payload.books[1]
        if first and first.filepath then
            self._preview_book = Repo.buildBook(first.filepath) or first
        end
    elseif entry.kind == "folder" and entry.payload and entry.payload.path then
        -- For folders, the cheap preselect path is to use the cached
        -- first_book carried with the folder entry (already walked when
        -- the folder was listed). buildBook upgrades the meta into a
        -- full Book record so the hero has progress/page data.
        local first = entry.payload.first_book
        if first and first.filepath then
            self._preview_book = Repo.buildBook(first.filepath) or first
        end
    end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- _drillBackTo(depth) — pop the drill path so the new tip is at index
-- `depth`. depth 0 = back to top level (chips list); depth 1 = keep
-- only the first crumb; etc.
function BookshelfWidget:_drillBackTo(depth)
    depth = math.max(0, depth or 0)
    -- The first entry we're about to pop carries `parent_page` — the page
    -- the level we're returning to was on before this drill. Snapshot it
    -- before tearing the entry down. When popping multiple levels at once
    -- (e.g. a deep crumb tap) only the FIRST popped entry's parent_page
    -- matters — that's the page of the level we're landing on.
    -- Search entries also carry `prior_drilldown` (the path that was active
    -- before search was invoked); restore it so backing out of search
    -- returns the user to where they were, not to a bare chip top.
    local restore_page = 1
    local restore_path
    if #self._drilldown_path > depth then
        local first_pop = self._drilldown_path[depth + 1]
        if first_pop and first_pop.parent_page then
            restore_page = first_pop.parent_page
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
    self._preview_book = nil
    self.page          = restore_page
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- Convenience for the existing series-expand call sites.
function BookshelfWidget:_expandSeries(series)
    if not series or not series.series_name then return end
    self:_drillInto{
        kind    = "series",
        label   = series.series_name,
        payload = series,
    }
end

function BookshelfWidget:_expandAuthor(group)
    if not group or not group.series_name then return end
    self:_drillInto{
        kind    = "author",
        label   = group.series_name,
        payload = group,
    }
end

function BookshelfWidget:_expandGenre(group)
    if not group or not group.series_name then return end
    self:_drillInto{
        kind    = "genre",
        label   = group.series_name,
        payload = group,
    }
end

function BookshelfWidget:_expandTag(group)
    if not group or not group.series_name then return end
    self:_drillInto{
        kind    = "tag",
        label   = group.series_name,
        payload = group,
    }
end

-- _openSearchDialog: input modal that runs Repo.searchBooks and drills
-- into the results. Search results live as a regular drill-down entry
-- (kind = "search") so the breadcrumb arrow pill doubles as a "back to
-- whatever I was on" affordance and the existing east-swipe / chip-pill
-- tap clears the search.
function BookshelfWidget:_openSearchDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title      = _("Search library"),
        input      = "",
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
    local books = Repo.searchBooks(query, 200) or {}
    -- Search is its own top-level mode rather than a nested drill under
    -- the active chip. Stash whatever drilldown the user was in so the
    -- back-out path restores it (a folder browse + search-then-back
    -- shouldn't drop the folder context). The active chip is preserved
    -- by self.chip — _drillBackTo to depth 0 leaves us on it.
    local prior_path = self._drilldown_path
    self._drilldown_path = {}
    self:_drillInto{
        kind            = "search",
        label           = query,
        payload         = { query = query, books = books },
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
