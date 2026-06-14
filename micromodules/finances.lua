--[[
Start-menu module: Finances.
Fetches exchange rates, stocks, crypto and indices from Yahoo Finance.
All asset types use the same API and the same unified ticker list.

Ticker formats:
  Stocks:     AAPL, MSFT, PETR4.SA
  Forex:      USDBRL=X, EURGBP=X
  Crypto:     BTC-USD, ETH-USD
  Indices:    ^GSPC, ^BVSP
  ETFs:       SPY, QQQ
]]
local _ = require("lib/bookshelf_i18n").gettext
local Fonts = require("lib/bookshelf_fonts")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalSpan = require("ui/widget/verticalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")

-- ─── Currency symbol map ───────────────────────────────────────────────────
local CURRENCY_SYMBOLS = {
    AUD = "A$", BRL = "R$", BTC = "₿", CAD = "CA$", CHF = "CHF", CNY = "CN¥",
    EUR = "€", GBP = "£", HKD = "HK$", IDR = "IDR", ILS = "₪", INR = "₹",
    JPY = "¥", KRW = "₩", MXN = "MX$", NOK = "NOK", NZD = "NZ$", PHP = "₱",
    PLN = "PLN", RUB = "RUB", SEK = "SEK", SGD = "SGD", THB = "THB",
    TRY = "TRY", TWD = "NT$", USD = "$", VND = "₫", ZAR = "ZAR",
}

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
                headers = { ["User-Agent"] = "Mozilla/5.0 (KOReader-Bookshelf)" },
                sink = ltn12.sink.table(body),
                redirect = true,
            }))
            socketutil:reset_timeout()
            return c
        end)
        if ok_req then
            local body_str = table.concat(body)
            if body_str ~= "" then
                local ok, data = pcall(json.decode, body_str)
                if ok then return data end
            end
        end
        pcall(function() socketutil:reset_timeout() end)
    end
    -- curl fallback (needed for HTTPS on some KOReader builds)
    local handle = io.popen(string.format("curl -s -L -A 'Mozilla/5.0' %q", url))
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
local KEY_DATA       = "micromodule_finances_data"
local KEY_PAIRS      = "micromodule_finances_pairs"
local KEY_VIEW_INDEX = "micromodule_finances_index"
local KEY_LAST_FETCH = "micromodule_finances_last_fetch"
local CACHE_TTL_SEC  = 900 -- 15 minutes

local DEFAULT_PAIRS = "USDBRL=X, EURBRL=X, BTC-USD, AAPL, PETR4.SA"

local _error_msg = nil
local _is_fetching_screen = false
local _implicit_fetch_pending = false

-- ─── Fetch ──────────────────────────────────────────────────────────────────
local function fetchData(callback)
    _implicit_fetch_pending = true

    local Store = require("lib/bookshelf_settings_store")
    local UIManager = require("ui/uimanager")
    local raw_pairs = Store.read(KEY_PAIRS) or DEFAULT_PAIRS

    _error_msg = nil

    -- Parse comma-separated tickers
    local list = {}
    for w in raw_pairs:gmatch("[^,]+") do
        local tk = w:match("^%s*(.-)%s*$")
        if tk and tk ~= "" then
            table.insert(list, tk)
        end
    end

    if #list == 0 then
        _error_msg = _("No tickers configured.")
        _implicit_fetch_pending = false
        if callback then callback(nil) end
        return
    end

    local parsed_list = {}
    local current_fetch_idx = 1
    local has_errors = false

    local function fetchNext()
        if current_fetch_idx > #list then
            -- Done with all items
            if #parsed_list > 0 then
                Store.save(KEY_DATA, parsed_list)
                Store.save(KEY_LAST_FETCH, os.time())
                Store.save(KEY_VIEW_INDEX, 1)
                _error_msg = nil
                _implicit_fetch_pending = false
                if callback then callback(parsed_list) end
            else
                _error_msg = _("Failed. Retry \xE2\x86\x92")
                _implicit_fetch_pending = false
                if callback then callback(nil) end
            end
            return
        end

        local symbol = list[current_fetch_idx]
        current_fetch_idx = current_fetch_idx + 1

        local encoded_symbol = string.gsub(symbol, "([^%w _%%%-%.~])", function(c) return string.format("%%%02X", string.byte(c)) end)
        encoded_symbol = string.gsub(encoded_symbol, " ", "%%20")
        
        local url = "https://query1.finance.yahoo.com/v8/finance/chart/" .. encoded_symbol .. "?range=1d&interval=1d"
        local data = httpGetJSON(url)

        if data and data.chart and type(data.chart.result) == "table" and data.chart.result[1] then
            local meta = data.chart.result[1].meta
            if meta and meta.regularMarketPrice and meta.chartPreviousClose then
                local pct_change = ((meta.regularMarketPrice - meta.chartPreviousClose) / meta.chartPreviousClose) * 100
                local cur = meta.currency or "USD"
                local sym = CURRENCY_SYMBOLS[cur] or (cur .. " ")
                table.insert(parsed_list, {
                    pair = meta.symbol or symbol,
                    name = meta.shortName or meta.longName or meta.symbol or symbol,
                    price = meta.regularMarketPrice,
                    currency_sym = sym,
                    pctChange = string.format("%.2f", pct_change),
                })
            end
        else
            -- Skip invalid/failed symbols rather than aborting
            has_errors = true
        end

        -- Yield to UI thread, then fetch next
        UIManager:scheduleIn(0.01, fetchNext)
    end

    UIManager:scheduleIn(0.01, fetchNext)
end

-- ─── Cycle view (tap) ──────────────────────────────────────────────────────
local function cycleView(ctx)
    if _error_msg then
        _error_msg = nil
        _is_fetching_screen = false
        return
    end
    if _is_fetching_screen then return end

    local Store = require("lib/bookshelf_settings_store")
    local items = Store.read(KEY_DATA) or {}

    if #items <= 1 then
        fetchData(function()
            local StartMenu = require("lib/bookshelf_start_menu")
            if StartMenu._live and StartMenu._live._reload then
                StartMenu._live:_reload()
            end
        end)
        return
    end

    local current_idx = Store.read(KEY_VIEW_INDEX) or 1
    current_idx = current_idx + 1
    if current_idx > #items then current_idx = 1 end
    Store.save(KEY_VIEW_INDEX, current_idx)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ─── SETTINGS ──────────────────────────────────────────────────────────────
-- ═══════════════════════════════════════════════════════════════════════════
local function showSettings(ctx)
    local Store = require("lib/bookshelf_settings_store")
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    local Menu = require("ui/widget/menu")
    local dialog

    local function close(callback)
        return function()
            if dialog then UIManager:close(dialog) end
            if callback then callback() end
        end
    end

    local function showRoot()
        local current_pairs = Store.read(KEY_PAIRS) or DEFAULT_PAIRS
        local buttons = {}

        table.insert(buttons, { { text = _("Source: Yahoo Finance"), enabled = false, callback = function() end } })

        -- Edit tracked tickers
        table.insert(buttons, { { text = _("Tracked assets") .. ": " .. current_pairs, font_bold = false, callback = close(function()
            local input_dialog
            input_dialog = InputDialog:new{
                title = _("Edit tracked assets"),
                description = _("Comma-separated. Examples:\nForex: USDBRL=X  Stocks: AAPL, PETR4.SA\nCrypto: BTC-USD  Indices: ^GSPC"),
                input = current_pairs,
                buttons = {
                    { { text = _("Cancel"), callback = function()
                        UIManager:close(input_dialog)
                        showRoot()
                    end } },
                    { { text = _("Save"), font_bold = true, callback = function()
                        local new_val = input_dialog:getInputText()
                        Store.save(KEY_PAIRS, new_val)
                        Store.save(KEY_DATA, nil)
                        _error_msg = nil
                        UIManager:close(input_dialog)
                        if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                        showRoot()
                    end } },
                }
            }
            UIManager:show(input_dialog)
        end) } })

        -- Search online
        table.insert(buttons, { { text = _("Search online..."), font_bold = false, callback = close(function()
            local input_dialog
            input_dialog = InputDialog:new{
                title = _("Search Asset / Currency / Company"),
                input = "",
                buttons = {
                    {
                        { text = _("Cancel"), callback = function() UIManager:close(input_dialog); showRoot() end },
                        { text = _("Search"), is_enter_default = true, callback = function()
                            local val = input_dialog:getInputText()
                            UIManager:close(input_dialog)
                            if val and val ~= "" then
                                local info = InfoMessage:new{ text = _("Searching Yahoo Finance...") }
                                UIManager:show(info)
                                UIManager:scheduleIn(0.1, function()
                                    local url_val = string.gsub(val, "([^%w _%%%-%.~])", function(c) return string.format("%%%02X", string.byte(c)) end)
                                    url_val = string.gsub(url_val, " ", "%%20")
                                    local url = "https://query1.finance.yahoo.com/v1/finance/search?q=" .. url_val .. "&quotesCount=10&newsCount=0"
                                    local data = httpGetJSON(url)
                                    UIManager:close(info)
                                    if data and data.quotes and #data.quotes > 0 then
                                        local search_menu
                                        local item_table = { { text = _("← Cancel"), callback = function() UIManager:close(search_menu); showRoot() end } }
                                        for _j, q in ipairs(data.quotes) do
                                            if q.symbol then
                                                local name = q.longname or q.shortname or q.symbol
                                                local type_disp = q.typeDisp or "Asset"
                                                table.insert(item_table, {
                                                    text = string.format("%s (%s) - %s", q.symbol, name, type_disp),
                                                    callback = function()
                                                        UIManager:close(search_menu)
                                                        local cur = Store.read(KEY_PAIRS) or DEFAULT_PAIRS
                                                        cur = (cur == "" or not cur) and q.symbol or (cur .. ", " .. q.symbol)
                                                        Store.save(KEY_PAIRS, cur)
                                                        Store.save(KEY_DATA, nil)
                                                        if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                                                        showRoot()
                                                    end
                                                })
                                            end
                                        end
                                        search_menu = Menu:new{ title = _("Select Asset to Add"), item_table = item_table, is_enable_shortcut = false, onClose = function() UIManager:close(search_menu); showRoot() end }
                                        UIManager:show(search_menu)
                                    else
                                        local no_res = InfoMessage:new{ text = _("No results found.") }
                                        UIManager:show(no_res)
                                        UIManager:scheduleIn(2.0, function() UIManager:close(no_res); showRoot() end)
                                    end
                                end)
                            else
                                showRoot()
                            end
                        end }
                    }
                }
            }
            UIManager:show(input_dialog)
        end) } })

        table.insert(buttons, { { text = _("Force refresh"), font_bold = false, callback = close(function()
            Store.save(KEY_DATA, nil)
            _error_msg = nil
            if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
        end) } })

        table.insert(buttons, { { text = _("Close"), font_bold = true, callback = close() } })

        dialog = ButtonDialog:new{
            title = _("Finances Settings"),
            title_align = "center",
            use_info_style = false,
            buttons = buttons
        }
        UIManager:show(dialog)
    end

    showRoot()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ─── RENDER ────────────────────────────────────────────────────────────────
-- ═══════════════════════════════════════════════════════════════════════════
return {
    key   = "finances",
    title = _("Finances"),
    keep_open = true,

    show_settings = function(ctx)
        showSettings(ctx)
    end,

    render = function(width, scale_pct, is_preview)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local mw = width - sc(30)

        local SM = require("lib/bookshelf_start_menu_modules")
        local PRIMARY, MUTED = SM.COLOR_PRIMARY, SM.COLOR_MUTED

        if is_preview then
            return VerticalGroup:new{ align = "center",
                TextWidget:new{
                    text = _("Stocks, Crypto & Forex"),
                    face = Fonts:getFace("cfont", sc(15)),
                    fgcolor = MUTED, max_width = math.max(50, width),
                }
            }
        end

        local Store = require("lib/bookshelf_settings_store")
        local items = Store.read(KEY_DATA)
        local current_idx = Store.read(KEY_VIEW_INDEX) or 1
        local data = nil

        if type(items) == "table" and #items > 0 then
            if current_idx > #items then current_idx = 1 end
            data = items[current_idx]
        end

        -- TTL Check
        local last_fetch = Store.read(KEY_LAST_FETCH) or 0
        local is_stale = (os.time() - last_fetch) > CACHE_TTL_SEC

        local UIManager = require("ui/uimanager")
        local group = VerticalGroup:new{ align = "left" }

        -- ── Header ─────────────────────────────────────────────────────
        local face_h, bold_h = Fonts:getFace("cfont", sc(12), {bold = true})
        local header_text
        if data then
            header_text = data.pair
            if data.name and data.name ~= data.pair then
                header_text = header_text .. " - " .. data.name
            end
        else
            header_text = _("Finances")
        end

        group[#group + 1] = TextBoxWidget:new{
            text = header_text,
            face = face_h, bold = bold_h,
            fgcolor = MUTED,
            bgcolor = SM.CARD_BG,
            width = mw,
            height = math.floor(face_h.size * 1.3 + 0.5) * 2,
            height_adjust = true,
        }

        -- ── Fetching / stale logic ─────────────────────────────────────
        if not data or (is_stale and not _error_msg) then
            _is_fetching_screen = not data
            local fetch_text
            if _error_msg then
                fetch_text = _error_msg
            elseif data then
                fetch_text = data.currency_sym .. string.format("%.2f", data.price)
            else
                fetch_text = _("Fetching data...")
            end
            local face_q = Fonts:getFace("cfont", sc(16))
            local text_w = TextBoxWidget:new{
                text = fetch_text,
                face = face_q,
                fgcolor = PRIMARY,
                bgcolor = SM.CARD_BG,
                width = mw,
                height = math.floor(face_q.size * 1.3 + 0.5) * 4,
                height_adjust = true,
                align = "center",
            }
            local fetch_msg = FrameContainer:new{
                background = SM.CARD_BG,
                bordersize = 0,
                padding = 0,
                CenterContainer:new{
                    dimen = Geom:new{ w = mw, h = math.floor(face_q.size * 1.3 + 0.5) * 4 },
                    text_w
                }
            }

            if not _error_msg and not _implicit_fetch_pending and not is_preview then
                _implicit_fetch_pending = true
                UIManager:scheduleIn(0.1, function()
                    fetchData(function(res)
                        _is_fetching_screen = false
                        if res then _error_msg = nil end
                        local StartMenu = require("lib/bookshelf_start_menu")
                        if StartMenu._live and StartMenu._live._reload then
                            StartMenu._live:_reload()
                        end
                    end)
                end)
            end

            if not data then
                group[#group + 1] = fetch_msg
                return group
            end
        end
        _is_fetching_screen = false

        group[#group + 1] = VerticalSpan:new{ width = sc(4) }

        -- ── Price ──────────────────────────────────────────────────────
        local price_text = data.currency_sym .. string.format("%.2f", data.price)
        local face_price, bold_price = Fonts:getFace("cfont", sc(24), {bold = true})
        group[#group + 1] = TextBoxWidget:new{
            text = price_text,
            face = face_price, bold = bold_price,
            fgcolor = PRIMARY,
            bgcolor = SM.CARD_BG,
            width = mw,
            height = math.floor(face_price.size * 1.3 + 0.5) * 2,
            height_adjust = true,
        }

        -- ── % Change ───────────────────────────────────────────────────
        local face_pct = Fonts:getFace("cfont", sc(14))
        local pct_val = tonumber(data.pctChange) or 0
        local pct_arrow = ""
        if pct_val > 0 then
            pct_arrow = "\xE2\x86\x91 " -- ↑
        elseif pct_val < 0 then
            pct_arrow = "\xE2\x86\x93 " -- ↓
        end
        group[#group + 1] = TextBoxWidget:new{
            text = pct_arrow .. string.format("%.2f", math.abs(pct_val)) .. "%",
            face = face_pct,
            fgcolor = PRIMARY,
            bgcolor = SM.CARD_BG,
            width = mw,
            height = math.floor(face_pct.size * 1.3 + 0.5) * 2,
            height_adjust = true,
        }

        -- Footer removed to keep it cleaner

        if last_fetch > 0 then
            group[#group + 1] = VerticalSpan:new{ width = sc(6) }

            local diff = os.time() - last_fetch
            local upd_str
            if diff < 60 then
                upd_str = _("Just now")
            elseif diff < 3600 then
                local m = math.floor(diff / 60)
                upd_str = string.format(_("Updated %dm ago"), m)
            else
                local h = math.floor(diff / 3600)
                upd_str = string.format(_("Updated %dh ago"), h)
            end
            local face_ctx = Fonts:getFace("cfont", sc(11), {italic = true})
            local upd_widget = TextWidget:new{
                text = upd_str, face = face_ctx,
                fgcolor = MUTED, max_width = mw,
            }
            group[#group + 1] = upd_widget
        end

        return group
    end,

    on_tap = function(ctx) cycleView(ctx) end,
}
