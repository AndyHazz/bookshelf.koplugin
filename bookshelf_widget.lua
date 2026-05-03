-- bookshelf_widget.lua
-- The top-level home screen widget. Composes TitleBar + HeroCard + ChipStrip
-- + shelf-pair label + two ShelfRows, owns chip-state and refresh.
--
-- Task 6.1: skeleton composition (titlebar stub, hero, chip strip, shelf pair)
-- Task 6.2: real TitleBar with gear icon; tappable shelf-pair label → LibraryView
-- Task 6.3: long-press book menu; series-stack expand-in-place

local InputContainer  = require("ui/widget/container/inputcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget      = require("ui/widget/textwidget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local Font            = require("ui/font")
local UIManager       = require("ui/uimanager")
local TitleBar        = require("ui/widget/titlebar")
local Blitbuffer      = require("ffi/blitbuffer")
local Screen          = require("device").screen

local Repo        = require("book_repository")
local HeroCard    = require("hero_card")
local ChipStrip   = require("chip_strip")
local ShelfRow    = require("shelf_row")
local LibraryView = require("library_view")

-- ─── BookshelfWidget ──────────────────────────────────────────────────────────

local BookshelfWidget = InputContainer:extend{
    name = "bookshelf",
    -- Internal state.
    chip             = "recent",
    _expanded_series = nil,
}

function BookshelfWidget:init()
    self.width  = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen  = Geom:new{ w = self.width, h = self.height }
    self.chip   = G_reader_settings:readSetting("bookshelf_active_chip") or "recent"
    self:_rebuild()
end

-- ─── _rebuild ─────────────────────────────────────────────────────────────────

function BookshelfWidget:_rebuild()
    -- Release previous widget tree before replacing (Phase 5 lesson).
    if self[1] and self[1].free then self[1]:free() end

    local PAD       = Size.padding.default
    local content_w = self.width - PAD * 2

    -- Height constants. Size.item.height_small does not exist (Phase 3-5 lesson);
    -- use height_default (~30dp) for all bar-height components.
    local chip_h  = Size.item.height_default
    local label_h = Size.item.height_default

    -- Hero card ~22% of screen height (spec §3.1).
    local hero_h = math.floor(self.height * 0.22)

    -- Build TitleBar first so we can measure its actual height.
    local titlebar = self:_buildTitleBar(content_w)
    local titlebar_h = titlebar:getHeight()

    -- Each shelf row shares the remaining vertical space equally.
    -- Total reserved: titlebar + hero + chip strip + label + 4 internal gaps.
    local reserved_h = titlebar_h + hero_h + chip_h + label_h + PAD * 4
    local shelf_h    = math.floor((self.height - reserved_h) / 2)

    -- ── Hero card ─────────────────────────────────────────────────────────────
    local current = Repo.getCurrent()
    if current then Repo.enrichStats(current) end
    local lines = G_reader_settings:readSetting("bookshelf_hero_lines") or {
        "%page_num / %page_count · %book_pct%%",
        "[if:book_time_left]%book_time_left LEFT[else]Open to start reading[/if]",
    }
    local hero = HeroCard:new{
        book         = current,
        width        = content_w,
        height       = hero_h,
        lines        = lines,
        device_state = self:_buildDeviceState(),
        on_tap       = function(b) self:_openBook(b) end,
        on_hold      = function(b) self:_openBookMenu(b) end,
    }

    -- ── Chip strip ────────────────────────────────────────────────────────────
    local chips = ChipStrip:new{
        chips = {
            { key = "recent",    label = "Recent"  },
            { key = "latest",    label = "Latest"  },
            { key = "series",    label = "Series"  },
            { key = "favorites", label = "\xe2\x98\x85" },  -- ★ UTF-8
        },
        active   = self.chip,
        width    = content_w,
        height   = chip_h,
        on_change = function(key)
            -- Reset any expanded series when switching chips.
            self._expanded_series = nil
            self.chip = key
            G_reader_settings:saveSetting("bookshelf_active_chip", key)
            self:_rebuild()
            UIManager:setDirty(self, "ui")
        end,
    }

    -- ── Shelf items ───────────────────────────────────────────────────────────
    local items     = self:_fetchChipItems(8)
    local total     = self:_chipTotal()
    local shown     = math.min(8, #items)

    -- ── Shelf-pair label (tappable → LibraryView or collapse series) ────────────
    -- Defined as a local InputContainer subclass using the standard extend-pattern
    -- (cleaner than the plan's inline class-mutation approach).
    -- When a series is expanded, the label reads "← Series name" and tapping
    -- collapses back to the chip's data rather than opening LibraryView.
    local is_expanded = (self._expanded_series ~= nil)
    local label_text
    if is_expanded then
        label_text = "\xe2\x86\x90  " .. (self._expanded_series.series_name or "Series")
    elseif total < 0 then
        -- Total is unknown (e.g. "latest" chip avoids an expensive filesystem
        -- walk), so omit the "of N" portion.
        label_text = string.format(
            "%s  \xc2\xb7  1\xe2\x80\x93%d  \xe2\x80\xba",
            self:_chipLabel(), math.min(8, shown)
        )
    else
        label_text = string.format(
            "%s  \xc2\xb7  1\xe2\x80\x93%d of %d  \xe2\x80\xba",
            self:_chipLabel(), math.min(8, shown), total
        )
    end

    -- We need a reference to self for the closure, but we're building inside
    -- _rebuild; capture in a local.
    local bw = self  -- BookshelfWidget reference for callbacks

    local ShelfLabel = InputContainer:extend{}
    function ShelfLabel:init()
        self.dimen = Geom:new{ w = content_w, h = label_h }
        self[1] = CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = label_h },
            TextWidget:new{
                text = label_text,
                face = Font:getFace("infofont", 11),
            },
        }
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
    function ShelfLabel:onTap()
        if is_expanded then
            -- Collapse back to the chip's data.
            bw._expanded_series = nil
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        else
            -- Close home screen and show LibraryView; schedule re-show on close
            -- via nextTick so the UI stack order is correct (Phase 5 lesson).
            UIManager:close(bw)
            UIManager:nextTick(function()
                UIManager:show(LibraryView:new{
                    chip          = bw.chip,
                    on_book_tap   = function(b) bw:_openBook(b) end,
                    on_book_hold  = function(b) bw:_openBookMenu(b) end,
                    on_series_tap = function(s) bw:_expandSeries(s) end,
                    on_close      = function()
                        UIManager:nextTick(function() UIManager:show(bw) end)
                    end,
                })
            end)
        end
        return true
    end
    local label_widget = ShelfLabel:new{}

    -- ── Shelf rows ────────────────────────────────────────────────────────────
    local items_top    = { items[1], items[2], items[3], items[4] }
    local items_bottom = { items[5], items[6], items[7], items[8] }

    local row_top = ShelfRow.new{
        width          = content_w,
        height         = shelf_h,
        items          = items_top,
        on_book_tap    = function(b) bw:_openBook(b) end,
        on_book_hold   = function(b) bw:_openBookMenu(b) end,
        on_series_tap  = function(s) bw:_expandSeries(s) end,
        on_series_hold = function(s) bw:_openBookMenu(s) end,
    }
    local row_bottom = ShelfRow.new{
        width          = content_w,
        height         = shelf_h,
        items          = items_bottom,
        on_book_tap    = function(b) bw:_openBook(b) end,
        on_book_hold   = function(b) bw:_openBookMenu(b) end,
        on_series_tap  = function(s) bw:_expandSeries(s) end,
        on_series_hold = function(s) bw:_openBookMenu(s) end,
    }

    -- ── Assemble ──────────────────────────────────────────────────────────────
    -- paper-tone background for the whole widget
    local paper_bg
    if type(Blitbuffer.gray) == "function" then
        paper_bg = Blitbuffer.gray(0.93)
    else
        paper_bg = Blitbuffer.COLOR_WHITE
    end

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding    = PAD,
        background = paper_bg,
        VerticalGroup:new{
            align = "left",
            titlebar,
            hero,
            chips,
            label_widget,
            row_top,
            row_bottom,
        },
    }
end

-- ─── Data helpers ─────────────────────────────────────────────────────────────

-- _fetchChipItems(n)
-- Returns up to n items for the current chip (or the expanded-series flat list).
function BookshelfWidget:_fetchChipItems(n)
    -- When a series is expanded, show that series' books as flat spine widgets.
    if self._expanded_series then
        return self._expanded_series.books
    end
    if self.chip == "recent"    then return Repo.getRecent(n)       end
    if self.chip == "latest"    then return Repo.getLatest(n)       end
    if self.chip == "series"    then return Repo.getSeriesGroups(n) end
    if self.chip == "favorites" then return Repo.getFavorites(n)    end
    return {}
end

-- _chipLabel()  — human-readable shelf heading for the active chip.
function BookshelfWidget:_chipLabel()
    if self._expanded_series then
        return (self._expanded_series.series_name or "Series")
    end
    local labels = {
        recent    = "Recently read",
        latest    = "Latest additions",
        series    = "Your series",
        favorites = "Favourites",
    }
    return labels[self.chip] or ""
end

-- _chipTotal() — total item count for the active chip (used in the label).
-- Returns -1 to signal "unknown" for chips where counting would be expensive
-- (e.g. "latest" requires a filesystem walk). The label-formatter omits the
-- total in that case.
function BookshelfWidget:_chipTotal()
    if self._expanded_series then
        return #self._expanded_series.books
    end
    -- For the active chip, count from the cheapest available source. The
    -- "latest" chip is filesystem-bound; counting it would re-walk every
    -- rebuild, so we return -1 to signal "unknown" and the label-formatter
    -- omits the total.
    if self.chip == "recent" then
        local rh = require("readhistory")
        return #rh.hist
    elseif self.chip == "latest" then
        return -1
    elseif self.chip == "series" then
        return #Repo.getSeriesGroups(9999)
    elseif self.chip == "favorites" then
        local rc = require("readcollection")
        local count = 0
        for _ in pairs(rc.coll and rc.coll.favorites or {}) do count = count + 1 end
        return count
    end
    return 0
end

-- ─── TitleBar (Task 6.2) ──────────────────────────────────────────────────────
-- Uses KOReader's TitleBar widget. A custom OverlapGroup approach is explicitly
-- avoided because TitleBar handles clock/battery/system-icon positioning
-- correctly (Phase 5 confirmed its API).

function BookshelfWidget:_buildTitleBar(w)
    -- Build a subtitle carrying the current time and, where available, battery%.
    local ds = self:_buildDeviceState()
    local subtitle = os.date("%H:%M")
    if ds.batt then
        local batt_str = tostring(ds.batt) .. "%"
        if ds.charging then batt_str = batt_str .. " \xe2\x96\xb2" end  -- ▲ charging indicator
        subtitle = subtitle .. "  " .. batt_str
    end
    return TitleBar:new{
        title                    = "BOOKSHELF",
        subtitle                 = subtitle,
        align                    = "left",
        width                    = w,
        fullscreen               = false,
        with_bottom_line         = true,
        right_icon               = "appbar.menu",
        right_icon_tap_callback  = function() self:_openGearMenu() end,
        show_parent              = self,
    }
end

-- ─── Device state ─────────────────────────────────────────────────────────────

function BookshelfWidget:_buildDeviceState()
    local ok_pd, PowerD = pcall(function()
        return require("device"):getPowerDevice()
    end)
    local ok_nm, NetMgr = pcall(require, "ui/network/manager")
    return {
        now      = os.time(),
        batt     = (ok_pd and PowerD and PowerD.getCapacity)
                       and PowerD:getCapacity() or nil,
        charging = (ok_pd and PowerD and PowerD.isCharging)
                       and PowerD:isCharging() or false,
        wifi     = (ok_nm and NetMgr and NetMgr.isWifiOn and NetMgr:isWifiOn())
                       and "on" or "off",
    }
end

-- ─── Navigation ───────────────────────────────────────────────────────────────

-- _openBook(book)  — close home screen, open ReaderUI for the given book.
-- ReaderUI is required inside the function to avoid boot-order issues (Phase 5 lesson).
function BookshelfWidget:_openBook(book)
    if not book or not book.filepath then return end
    -- Returning from a book should land on the chip-level view, not in the
    -- middle of an expanded series.
    self._expanded_series = nil
    local ReaderUI = require("apps/reader/readerui")
    UIManager:close(self)
    UIManager:nextTick(function()
        ReaderUI:showReader(book.filepath)
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
    UIManager:show(ButtonDialog:new{
        title = "Bookshelf",
        buttons = {
            {
                { text = "Browse files\xe2\x80\xa6",
                  callback = function() bw:_browseFiles() end },
            },
            {
                { text = "Settings\xe2\x80\xa6",
                  callback = function()
                    require("settings"):show()
                  end },
                { text = "About",
                  callback = function()
                    require("settings"):_about()
                  end },
            },
            {
                { text = "Cancel", callback = function() end },
            },
        },
    })
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
    UIManager:show(ButtonDialog:new{
        title = book.title or book.filename or "Book",
        buttons = {
            {
                { text = "Show info",
                  callback = function()
                    local FileManager = require("apps/filemanager/filemanager")
                    local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
                    if FileManager.instance and FileManager.instance.bookinfo then
                        FileManager.instance.bookinfo:show(book.filepath)
                    else
                        FileManagerBookInfo:new{}:show(book.filepath)
                    end
                  end },
                { text = fav_label,
                  callback = function()
                    -- Toggle favourite status.
                    local ok, already = pcall(function()
                        return ReadCollection:isFileInCollection(book.filepath, "favorites")
                    end)
                    if ok and already then
                        ReadCollection:removeItem(book.filepath, "favorites")
                    else
                        ReadCollection:addItem(book.filepath, "favorites")
                    end
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                  end },
            },
            {
                { text = "Remove from history",
                  callback = function()
                    require("readhistory"):removeItemByPath(book.filepath)
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                  end },
                { text = "Cancel", callback = function() end },
            },
        },
    })
end

-- _openSeriesMenu(series)  — long-press on a series stack.
function BookshelfWidget:_openSeriesMenu(series)
    local ButtonDialog = require("ui/widget/buttondialog")
    local bw = self
    UIManager:show(ButtonDialog:new{
        title = series.series_name or "Series",
        buttons = {
            {
                { text = "Browse series",
                  callback = function() bw:_expandSeries(series) end },
            },
            {
                { text = "Cancel", callback = function() end },
            },
        },
    })
end

-- ─── Series expand-in-place (Task 6.3) ───────────────────────────────────────

-- _expandSeries(series)  — replace the current shelf-pair with the series'
-- books as flat spine widgets. Tapping any chip resets this state.
function BookshelfWidget:_expandSeries(series)
    if not series then return end
    self._expanded_series = series
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- ─── Dismiss / passthrough ───────────────────────────────────────────────────

function BookshelfWidget:onClose()
    UIManager:close(self)
    return true
end

return BookshelfWidget
