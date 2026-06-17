--[[
Start-menu module: On This Day.
Uses Wikipedia's free REST API to fetch historical events for today's date.
Tap cycles through different events.
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template
local SafeText = require("lib/bookshelf_text_safe")

-- ─── HTTP helper ─────────────────────────────────────────────────────────────
local function httpGetJSON(url)
    local json = require("json")
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if ok_require then
        local body = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local c = socket.skip(1, http.request({
                url = url,
                method = "GET",
                headers = { ["User-Agent"] = "KOReader-Bookshelf" },
                sink = ltn12.sink.table(body),
                redirect = true,
            }))
            socketutil:reset_timeout()
            return c
        end)
        if ok_req and code == 200 then
            local ok, data = pcall(json.decode, table.concat(body))
            if ok then return data end
        end
        pcall(function() socketutil:reset_timeout() end)
    end
    -- Fallback: curl
    local handle = io.popen(string.format("curl -s -L -H 'User-Agent: KOReader-Bookshelf' %q", url))
    if handle then
        local body = handle:read("*a")
        handle:close()
        if body and body ~= "" then
            local ok, data = pcall(json.decode, body)
            if ok then return data end
        end
    end
    return nil
end

-- ─── Settings keys ─────────────────────────────────────────────────────────
local KEY_DATA       = "micromodule_otd_data"
local KEY_LAST_FETCH = "micromodule_otd_last_fetch"
local KEY_DAY        = "micromodule_otd_day"

-- ─── Fetch ──────────────────────────────────────────────────────────────────

local function fetchOTD(force, callback)
    local Store = require("lib/bookshelf_settings_store")
    local cached = Store.read(KEY_DATA)
    local current_day = os.date("%Y-%m-%d")
    local last_day = Store.read(KEY_DAY, "")

    if not force and cached and current_day == last_day then
        if callback then callback(cached) end
        return
    end

    local NetworkMgr  = require("ui/network/manager")
    local UIManager   = require("ui/uimanager")

    NetworkMgr:runWhenOnline(function()
        UIManager:scheduleIn(0.1, function()
            local m = string.format("%02d", os.date("*t").month)
            local d = string.format("%02d", os.date("*t").day)
            local url = "https://en.wikipedia.org/api/rest_v1/feed/onthisday/events/" .. m .. "/" .. d
            local data = httpGetJSON(url)

            if data and data.events and #data.events > 0 then
                local events = {}
                -- Save up to 10 events
                for i = 1, math.min(10, #data.events) do
                    table.insert(events, {
                        year = data.events[i].year,
                        -- Wikipedia event text is untrusted; sanitise before
                        -- caching/rendering to avoid a shaper crash (#163).
                        text = SafeText.safe(data.events[i].text)
                    })
                end
                
                Store.save(KEY_DATA, events)
                Store.save(KEY_DAY, current_day)
                Store.save(KEY_LAST_FETCH, os.time())
                
                -- Invalidate in-memory pages cache
                _pages_cache = nil
                _total_pages = 1
                _view_index = 1
                
                if callback then callback(events) end
            else
                if callback then callback(cached) end
            end
        end)
    end)
end

local _implicit_fetch_pending = false

local function maybeScheduleImplicitFetch()
    if _implicit_fetch_pending then return end
    _implicit_fetch_pending = true
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0.1, function()
        fetchOTD(false, function(result)
            _implicit_fetch_pending = false
            if result then
                local StartMenu = require("lib/bookshelf_start_menu")
                if StartMenu._live and StartMenu._live._reload then
                    StartMenu._live:_reload()
                end
            end
        end)
    end)
end

-- ─── View state ─────────────────────────────────────────────────────────────
local _view_index = 1
local _total_pages = 1
local _pages_cache = nil
local _last_mw = nil

local function cycleView()
    _view_index = _view_index + 1
    if _view_index > _total_pages then _view_index = 1 end
end

-- Settings removed.

-- ─── Spec ───────────────────────────────────────────────────────────────────
return {
    key   = "otd",
    title = _("On This Day"),
    keep_open = true,

    render = function(width, scale_pct, is_preview)
        local Blitbuffer      = require("ffi/blitbuffer")
        local Fonts           = require("lib/bookshelf_fonts")
        local TextWidget      = require("ui/widget/textwidget")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local Store           = require("lib/bookshelf_settings_store")

        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local SM = require("lib/bookshelf_start_menu_modules")
        local BLACK, GRAY = SM.COLOR_PRIMARY, SM.COLOR_MUTED

        if is_preview then
            local VG = require("ui/widget/verticalgroup")
            local group = VG:new{ align = "center" }
            group[1] = TextWidget:new{
                text = _("Daily historical events"),
                face = Fonts:getFace("cfont", sc(15)),
                fgcolor = GRAY, max_width = mw,
            }
            group[2] = TextWidget:new{
                text = _("from Wikipedia"),
                face = Fonts:getFace("cfont", sc(15)),
                fgcolor = GRAY, max_width = mw,
            }
            return group
        end

        local data = Store.read(KEY_DATA)

        -- Invalidate stale cache from a previous day
        local current_day = os.date("%Y-%m-%d")
        local cached_day = Store.read(KEY_DAY, "")
        if data and current_day ~= cached_day then
            data = nil
            Store.save(KEY_DATA, nil)
            _pages_cache = nil
            _total_pages = 1
            _view_index = 1
        end

        if data and #data > 10 then
            local limited = {}
            for i = 1, 10 do table.insert(limited, data[i]) end
            data = limited
        end

        local group = VerticalGroup:new{ align = "left" }

        -- Title is deferred until we know the year

        if not data or #data == 0 then
            if not is_preview then
                maybeScheduleImplicitFetch()
            end
            local face_h, bold_h = Fonts:getFace("cfont", sc(13), {bold = true})
            group[#group + 1] = TextWidget:new{
                text = _("On This Day"),
                face = face_h, bold = bold_h,
                fgcolor = GRAY, max_width = mw,
            }
            group[#group + 1] = TextWidget:new{
                text = _("Fetching..."),
                face = Fonts:getFace("cfont", sc(16)),
                fgcolor = BLACK, max_width = mw,
            }
            return group
        end

        -- Check cache compatibility
        if data[1] and data[1].lines then
            Store.save(KEY_DATA, nil)
            _pages_cache = nil
            _total_pages = 1
            _view_index = 1
            if not is_preview then
                maybeScheduleImplicitFetch()
            end
            local face_h, bold_h = Fonts:getFace("cfont", sc(13), {bold = true})
            group[#group + 1] = TextWidget:new{
                text = _("On This Day"),
                face = face_h, bold = bold_h,
                fgcolor = GRAY, max_width = mw,
            }
            group[#group + 1] = TextWidget:new{
                text = _("Updating format..."),
                face = Fonts:getFace("cfont", sc(16)),
                fgcolor = BLACK, max_width = mw,
            }
            return group
        end

        -- Rebuild pages cache if needed
        if not _pages_cache or _last_mw ~= mw then
            _pages_cache = {}
            _last_mw = mw
            local face = Fonts:getFace("cfont", sc(14))
            local RenderText = require("ui/rendertext")
            local lines_per_page = 3
            local safe_mw = mw - sc(10) -- safety margin for xtext HarfBuzz kerning differences
            
            for ev_index, ev in ipairs(data) do
                local current_page = {}
                local current_line = ""
                for word in ev.text:gmatch("%S+") do
                    if current_line == "" then
                        current_line = word
                    else
                        local test_line = current_line .. " " .. word
                        -- Use exact render text engine to calculate real pixels width
                        local line_width = RenderText:sizeUtf8Text(0, 10000, face, test_line, true, false).x
                        if line_width <= safe_mw then
                            current_line = test_line
                        else
                            table.insert(current_page, current_line)
                            current_line = word
                            if #current_page == lines_per_page then
                                table.insert(_pages_cache, {year = ev.year, lines = current_page, ev_idx = ev_index})
                                current_page = {}
                            end
                        end
                    end
                end
                if current_line ~= "" then
                    table.insert(current_page, current_line)
                end
                if #current_page > 0 then
                    while #current_page < lines_per_page do
                        table.insert(current_page, " ")
                    end
                    table.insert(_pages_cache, {year = ev.year, lines = current_page, ev_idx = ev_index})
                end
            end
            _total_pages = math.max(1, #_pages_cache)
        end

        if _view_index > #_pages_cache then _view_index = 1 end
        local page = _pages_cache[_view_index]

        if not page then return group end

        local face_h, bold_h = Fonts:getFace("cfont", sc(13), {bold = true})
        group[#group + 1] = HorizontalGroup:new{
            TextWidget:new{
                text = _("On This Day") .. " \xE2\x80\xA2 ",
                face = face_h, bold = bold_h,
                fgcolor = GRAY,
            },
            TextWidget:new{
                text = tostring(page.year),
                face = face_h, bold = bold_h,
                fgcolor = BLACK,
            }
        }
        
        group[#group + 1] = VerticalSpan:new{ width = sc(4) }
        
        local font_14 = Fonts:getFace("cfont", sc(14))
        for _, line_text in ipairs(page.lines) do
            group[#group + 1] = TextWidget:new{
                text = line_text,
                face = font_14,
                fgcolor = BLACK, max_width = mw,
            }
        end

        if not is_preview then
            group[#group + 1] = VerticalSpan:new{ width = sc(6) }

            local next_index = _view_index + 1
            if next_index > #_pages_cache then next_index = 1 end
            local next_page = _pages_cache[next_index]
            
            local is_same_event = false
            if _total_pages > 1 and next_page then
                is_same_event = (next_page.ev_idx == page.ev_idx)
            end
            
            local total_events = data and #data or 1
            local footer_text
            if _total_pages <= 1 then
                footer_text = T(_("%1 / %2"), page.ev_idx, total_events)
            elseif is_same_event then
                footer_text = T(_("%1 / %2 \xE2\x80\xA2 Tap to read more..."), page.ev_idx, total_events)
            else
                footer_text = T(_("%1 / %2 \xE2\x80\xA2 Tap for next event \xE2\x86\x92"), page.ev_idx, total_events)
            end

            group[#group + 1] = TextWidget:new{
                text = footer_text,
                face = Fonts:getFace("cfont", sc(11), {italic = true}),
                fgcolor = GRAY, max_width = mw,
            }
        end

        return group
    end,

    on_tap = function()
        local Store = require("lib/bookshelf_settings_store")
        local data = Store.read(KEY_DATA)
        if data and #data > 0 then
            cycleView()
        end
    end,
}
