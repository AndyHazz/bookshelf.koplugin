--[[
Start-menu module: current weather + 3-day forecast for a user-set city,
via Open-Meteo (geocoding + forecast, no API key). See README.md in
micromodules/ for the module spec contract.

Tap toggles "current" <-> "3-day forecast" (keep_open: the auto-reload
after on_tap re-renders the card in the new view; on_tap must NOT call
ctx.menu:_reload() itself). Data is cached under micromodule_weather_*
keys with a 2h refresh; "Force refresh" in module settings bypasses it.
The first render for a configured city has no cached data yet and kicks
off a background fetch -- guarded so it can't re-fire on every
focus-step rebuild while pending -- then nudges a repaint via setDirty
once it lands, since render() has no ctx to call _reload() with.
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template
local SafeText = require("lib/bookshelf_text_safe")

-- ─── HTTP helper ─────────────────────────────────────────────────────────────
-- Falls back from luasocket to curl, like bookshelf_updater.
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
                headers = { ["User-Agent"] = "KOReader-Bookshelf-Weather" },
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
    local handle = io.popen(string.format("curl -s -L -H 'User-Agent: KOReader-Bookshelf-Weather' %q", url))
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

-- ─── Weather codes ──────────────────────────────────────────────────────────

local WMO_CODES = {
    [0] = { icon = "\xE2\x98\xBC", desc = _("Clear sky") },           -- ☼
    [1] = { icon = "\xE2\x98\x81", desc = _("Mostly clear") },        -- ☁
    [2] = { icon = "\xE2\x98\x81", desc = _("Partly cloudy") },       -- ☁
    [3] = { icon = "\xE2\x98\x81", desc = _("Overcast") },            -- ☁
    [45] = { icon = "\xE2\x89\xA1", desc = _("Fog") },                -- ≡
    [48] = { icon = "\xE2\x89\xA1", desc = _("Rime fog") },           -- ≡
    [51] = { icon = "\xE2\x98\x82", desc = _("Light drizzle") },      -- ☂
    [53] = { icon = "\xE2\x98\x82", desc = _("Drizzle") },            -- ☂
    [55] = { icon = "\xE2\x98\x82", desc = _("Heavy drizzle") },      -- ☂
    [56] = { icon = "\xE2\x98\x82", desc = _("Freezing drizzle") },   -- ☂
    [57] = { icon = "\xE2\x98\x82", desc = _("Freezing drizzle") },   -- ☂
    [61] = { icon = "\xE2\x98\x82", desc = _("Light rain") },         -- ☂
    [63] = { icon = "\xE2\x98\x82", desc = _("Rain") },               -- ☂
    [65] = { icon = "\xE2\x98\x82", desc = _("Heavy rain") },         -- ☂
    [66] = { icon = "\xE2\x98\x82", desc = _("Freezing rain") },      -- ☂
    [67] = { icon = "\xE2\x98\x82", desc = _("Freezing rain") },      -- ☂
    [71] = { icon = "\xE2\x9D\x84", desc = _("Light snow") },         -- ❄
    [73] = { icon = "\xE2\x9D\x84", desc = _("Snow") },               -- ❄
    [75] = { icon = "\xE2\x9D\x84", desc = _("Heavy snow") },         -- ❄
    [77] = { icon = "\xE2\x9D\x84", desc = _("Snow grains") },        -- ❄
    [80] = { icon = "\xE2\x98\x82", desc = _("Rain showers") },       -- ☂
    [81] = { icon = "\xE2\x98\x82", desc = _("Rain showers") },       -- ☂
    [82] = { icon = "\xE2\x98\x82", desc = _("Violent showers") },    -- ☂
    [85] = { icon = "\xE2\x9D\x84", desc = _("Snow showers") },       -- ❄
    [86] = { icon = "\xE2\x9D\x84", desc = _("Snow showers") },       -- ❄
    [95] = { icon = "\xE2\x9A\xA1", desc = _("Thunderstorm") },       -- ⚡
    [96] = { icon = "\xE2\x9A\xA1", desc = _("Thunderstorm") },       -- ⚡
    [99] = { icon = "\xE2\x9A\xA1", desc = _("Thunderstorm") },       -- ⚡
}

local function getCodeInfo(code)
    return WMO_CODES[code] or { icon = "?", desc = _("Unknown") }
end

local function urlencode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

-- ─── Settings keys (micromodule_weather_* convention) ──────────────────────
local KEY_CITY       = "micromodule_weather_city"
local KEY_LAT        = "micromodule_weather_lat"
local KEY_LON        = "micromodule_weather_lon"
local KEY_DISPLAY    = "micromodule_weather_city_display"
local KEY_DATA       = "micromodule_weather_data"
local KEY_LAST_FETCH = "micromodule_weather_last_fetch"
local KEY_UNIT       = "micromodule_weather_unit"  -- "celsius" | "fahrenheit"

-- ─── Fetch ──────────────────────────────────────────────────────────────────

local function fetchWeather(city, force, callback)
    local Store = require("lib/bookshelf_settings_store")
    local cached = Store.read(KEY_DATA)
    local last_fetch = Store.read(KEY_LAST_FETCH, 0)
    local now = os.time()

    -- Avoid polling if not forced and cache is fresh (< 2 hours)
    if not force and cached and (now - last_fetch) < 7200 then
        if callback then callback(cached) end
        return
    end

    local NetworkMgr  = require("ui/network/manager")
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")

    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{ text = _("Fetching weather..."), timeout = 1 })
        UIManager:scheduleIn(0.1, function()
            -- 1. Geocode city
            local lat, lon, display_name = Store.read(KEY_LAT), Store.read(KEY_LON), Store.read(KEY_DISPLAY)
            if not lat or not lon or force then
                local geo_url = "https://geocoding-api.open-meteo.com/v1/search?name=" .. urlencode(city) .. "&count=1"
                local geo_data = httpGetJSON(geo_url)
                if geo_data and geo_data.results and #geo_data.results > 0 then
                    local res = geo_data.results[1]
                    lat, lon = res.latitude, res.longitude
                    display_name = res.name
                    if res.admin1 then display_name = display_name .. ", " .. res.admin1 end
                    -- Geocoding API text is untrusted; sanitise before it's
                    -- cached/rendered or invalid UTF-8 can crash the shaper (#163).
                    display_name = SafeText.safe(display_name)
                    Store.save(KEY_LAT, lat)
                    Store.save(KEY_LON, lon)
                    Store.save(KEY_DISPLAY, display_name)
                else
                    UIManager:show(InfoMessage:new{ text = T(_("City not found: %1"), tostring(city)), timeout = 3 })
                    if callback then callback(cached) end
                    return
                end
            end

            -- 2. Fetch weather. Open-Meteo returns Celsius unless asked
            -- otherwise; pass the user's unit through (default celsius).
            local unit = Store.read(KEY_UNIT, "celsius")
            local w_url = "https://api.open-meteo.com/v1/forecast?latitude=" .. lat .. "&longitude=" .. lon
                .. "&current=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto"
                .. "&temperature_unit=" .. unit
            local w_data = httpGetJSON(w_url)
            if w_data and w_data.current and w_data.daily then
                local parsed = {
                    temp_current = w_data.current.temperature_2m,
                    code_current = w_data.current.weather_code,
                    daily = {},
                    display_name = display_name,
                    timestamp = os.time(),
                }
                for i = 1, math.min(3, #w_data.daily.time) do
                    table.insert(parsed.daily, {
                        date = w_data.daily.time[i],
                        max = w_data.daily.temperature_2m_max[i],
                        min = w_data.daily.temperature_2m_min[i],
                        code = w_data.daily.weather_code[i],
                    })
                end
                Store.save(KEY_DATA, parsed)
                Store.save(KEY_LAST_FETCH, os.time())
                if callback then callback(parsed) end
            else
                UIManager:show(InfoMessage:new{ text = _("Weather API error"), timeout = 3 })
                if callback then callback(cached) end
            end
        end)
    end)
end

-- Implicit-fetch guard for render(): bumps to true right before scheduling,
-- and only resets to false on SUCCESS. A failed attempt (bad city, API
-- error) leaves it true, so a broken city name doesn't retry -- and pop up
-- "City not found" -- on every focus-step rebuild; "Force refresh" in
-- module settings is an explicit, ungated call that can still retry.
local _implicit_fetch_pending = false

local function maybeScheduleImplicitFetch(city)
    if _implicit_fetch_pending then return end
    _implicit_fetch_pending = true
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0.1, function()
        fetchWeather(city, false, function(result)
            if result then
                _implicit_fetch_pending = false
                UIManager:setDirty(nil, "ui")
            end
        end)
    end)
end

-- ─── View state ─────────────────────────────────────────────────────────────
-- In-memory only (like other modules' _pick_cache / _nonce): resets on
-- restart, fine for a display toggle.
local _view_mode = "current" -- "current" | "forecast"
local function cycleView()
    _view_mode = _view_mode == "current" and "forecast" or "current"
end

-- ─── Module settings ────────────────────────────────────────────────────────

local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local InputDialog  = require("ui/widget/inputdialog")
    local InfoMessage  = require("ui/widget/infomessage")
    local UIManager    = require("ui/uimanager")
    local Store        = require("lib/bookshelf_settings_store")
    local dialog

    local city = Store.read(KEY_CITY, "")
    local unit = Store.read(KEY_UNIT, "celsius")

    dialog = ButtonDialog:new{
        title       = _("Weather settings"),
        title_align = "center",
        buttons = {
            {
                {
                    text = city == "" and _("Set city") or T(_("City: %1"), city),
                    callback = function()
                        UIManager:close(dialog)
                        local input_dlg
                        input_dlg = InputDialog:new{
                            title = _("Enter city name"),
                            input = city,
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(input_dlg)
                                            showSettings(ctx)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local new_city = input_dlg:getInputText()
                                            if new_city and new_city ~= "" then
                                                Store.save(KEY_CITY, new_city)
                                                Store.delete(KEY_LAT) -- force geocoding again
                                                UIManager:close(input_dlg)
                                                fetchWeather(new_city, true, function()
                                                    if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                                                end)
                                            else
                                                UIManager:close(input_dlg)
                                                showSettings(ctx)
                                            end
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(input_dlg)
                        input_dlg:onShowKeyboard()
                    end,
                },
            },
            {
                {
                    text = (unit == "fahrenheit") and _("Units: °F (tap for °C)")
                                                   or _("Units: °C (tap for °F)"),
                    callback = function()
                        local nxt = (unit == "fahrenheit") and "celsius" or "fahrenheit"
                        Store.save(KEY_UNIT, nxt)
                        -- Cached temps are numbers in the OLD unit, so drop
                        -- them and refetch in the new unit (or re-show
                        -- settings if no city is set yet).
                        Store.delete(KEY_DATA)
                        Store.delete(KEY_LAST_FETCH)
                        UIManager:close(dialog)
                        if city ~= "" then
                            fetchWeather(city, true, function()
                                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                            end)
                        else
                            showSettings(ctx)
                        end
                    end,
                },
            },
            {
                {
                    text = _("Force refresh"),
                    callback = function()
                        UIManager:close(dialog)
                        if city ~= "" then
                            fetchWeather(city, true, function()
                                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                            end)
                        else
                            UIManager:show(InfoMessage:new{ text = _("Please set a city first."), timeout = 2 })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- ─── Spec ───────────────────────────────────────────────────────────────────

return {
    key   = "weather", -- stable id stored in user menus; never change it
    title = _("Weather"),
    keep_open = true,

    render = function(width, scale_pct)
        local Blitbuffer      = require("ffi/blitbuffer")
        local Fonts           = require("lib/bookshelf_fonts")
        local TextWidget      = require("ui/widget/textwidget")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local Store           = require("lib/bookshelf_settings_store")
        local SM              = require("lib/bookshelf_start_menu_modules")

        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local BLACK, GRAY = SM.COLOR_PRIMARY, SM.COLOR_MUTED

        local city = Store.read(KEY_CITY, "")
        local data = Store.read(KEY_DATA)

        local group = VerticalGroup:new{ align = "left" }

        if city == "" then
            local face_h, bold_h = Fonts:getFace("cfont", sc(15), {bold = true})
            group[#group + 1] = TextWidget:new{
                text = _("Weather"),
                face = face_h, bold = bold_h,
                fgcolor = BLACK, max_width = mw,
            }
            group[#group + 1] = TextWidget:new{
                text = _("Tap and hold to set city"),
                face = Fonts:getFace("cfont", sc(14)),
                fgcolor = GRAY, max_width = mw,
            }
            return group
        end

        if not data then
            -- No cached data yet: kick off a background fetch (guarded
            -- against re-firing every rebuild) and show a loading state.
            maybeScheduleImplicitFetch(city)
            local face_h, bold_h = Fonts:getFace("cfont", sc(15), {bold = true})
            group[#group + 1] = TextWidget:new{
                text = city,
                face = face_h, bold = bold_h,
                fgcolor = BLACK, max_width = mw,
            }
            group[#group + 1] = TextWidget:new{
                text = _("Fetching..."),
                face = Fonts:getFace("cfont", sc(14)),
                fgcolor = GRAY, max_width = mw,
            }
            return group
        end

        -- Header: city name
        local face_title, bold_title = Fonts:getFace("cfont", sc(15), {bold = true})
        group[#group + 1] = TextWidget:new{
            text = data.display_name or city,
            face = face_title, bold = bold_title,
            fgcolor = BLACK, max_width = mw,
        }

        if _view_mode == "current" then
            -- View 1: current temp + icon + today's min/max
            local curr_info = getCodeInfo(data.code_current)
            local today = data.daily and data.daily[1]

            local face_big, bold_big = Fonts:getFace("cfont", sc(28), {bold = true})
            local face_suf = Fonts:getFace("cfont", sc(14))

            local t_val = math.floor(data.temp_current + 0.5)
            -- Label the headline temp with the unit so it's unambiguous; the
            -- min/max and forecast lines stay bare "°" for compactness.
            local t_unit = Store.read(KEY_UNIT, "celsius") == "fahrenheit" and "F" or "C"
            local icon_tw = TextWidget:new{
                text = curr_info.icon, face = face_big, bold = bold_big, fgcolor = BLACK,
            }
            local temp_tw = TextWidget:new{
                text = " " .. tostring(t_val) .. "°" .. t_unit, face = face_big, bold = bold_big, fgcolor = BLACK,
            }

            local sub_text = curr_info.desc
            if today then
                local t_max = math.floor(today.max + 0.5)
                local t_min = math.floor(today.min + 0.5)
                sub_text = sub_text .. string.format(" \xE2\x86\x91%d\xC2\xB0 \xE2\x86\x93%d\xC2\xB0", t_max, t_min) -- ↑max ↓min
            end

            group[#group + 1] = HorizontalGroup:new{
                align = "center",
                icon_tw, temp_tw
            }
            group[#group + 1] = TextWidget:new{
                text = sub_text,
                face = face_suf,
                fgcolor = BLACK, max_width = mw,
            }

        else
            -- View 2: 3-day forecast
            local face_suf = Fonts:getFace("cfont", sc(12))
            group[#group + 1] = VerticalSpan:new{ width = sc(4) }
            for i = 1, math.min(3, #data.daily) do
                local d = data.daily[i]
                local info = getCodeInfo(d.code)
                -- format date: YYYY-MM-DD to DD/MM
                local _s, _e, m, day = string.find(d.date or "", "%d+%-(%d+)%-(%d+)")
                local date_str = (day and m) and (day .. "/" .. m) or d.date
                local t_max = math.floor(d.max + 0.5)
                local t_min = math.floor(d.min + 0.5)
                local line = string.format("%s: %s %d\xC2\xB0/%d\xC2\xB0 %s", date_str, info.icon, t_max, t_min, info.desc)
                group[#group + 1] = TextWidget:new{
                    text = line,
                    face = face_suf,
                    fgcolor = BLACK, max_width = mw,
                }
            end
        end

        -- Footer: last updated
        group[#group + 1] = VerticalSpan:new{ width = sc(6) }
        local face_ctx = Fonts:getFace("cfont", sc(11), {italic = true})
        local diff = os.time() - (data.timestamp or 0)
        local h = math.floor(diff / 3600)
        local upd_str
        if h == 0 then
            upd_str = T(_("Updated %1m ago"), math.floor(diff / 60))
        else
            upd_str = T(_("Updated %1h ago"), h)
        end
        group[#group + 1] = TextWidget:new{
            text = upd_str, face = face_ctx,
            fgcolor = GRAY, max_width = mw,
        }

        return group
    end,

    -- keep_open = true: on_tap runs, then the menu auto-reloads and
    -- re-renders this card in the new view -- do NOT call
    -- ctx.menu:_reload() here (that would double-repaint).
    on_tap = function() cycleView() end,

    show_settings = showSettings,
}
