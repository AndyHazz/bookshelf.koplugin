--[[
Start-menu module: Exchange Rates.
Fetches currency and crypto prices from AwesomeAPI (economia.awesomeapi.com.br).
Supports multiple pairs configured via settings.
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

local CURRENCY_SYMBOLS = {
    AED = "AED ", AFN = "AFN ", ALL = "ALL ", AMD = "AMD ", ANG = "ANG ", AOA = "AOA ", ARS = "ARS ", AUD = "A$ ", AZN = "AZN ", BAM = "BAM ", BBD = "BBD ", BDT = "BDT ", BGN = "BGN ", BHD = "BHD ", BIF = "BIF ", BNB = "BNB ", BND = "BND ", BOB = "BOB ", BRETT = "BRETT ", BRL = "R$ ", BRLPTAX = "BRLPTAX ", BRLT = "BRLT ", BSD = "BSD ", BTC = "₿ ", BWP = "BWP ", BYN = "BYN ", BZD = "BZD ", CAD = "CA$ ", CHF = "CHF ", CLP = "CLP ", CNH = "CNH ", CNY = "CN¥ ", COP = "COP ", CRC = "CRC ", CUP = "CUP ", CVE = "CVE ", CZK = "CZK ", DJF = "DJF ", DKK = "DKK ", DOGE = "Ð ", DOP = "DOP ", DZD = "DZD ", EGP = "EGP ", ETB = "ETB ", ETH = "Ξ ", EUR = "€ ", FJD = "FJD ", GBP = "£ ", GEL = "GEL ", GHS = "GHS ", GMD = "GMD ", GNF = "GNF ", GTQ = "GTQ ", HKD = "HK$ ", HNL = "HNL ", HRK = "HRK ", HTG = "HTG ", HUF = "HUF ", IDR = "IDR ", ILS = "₪ ", INR = "₹ ", IQD = "IQD ", IRR = "IRR ", ISK = "ISK ", JMD = "JMD ", JOD = "JOD ", JPY = "¥ ", KES = "KES ", KGS = "KGS ", KHR = "KHR ", KMF = "KMF ", KRW = "₩ ", KWD = "KWD ", KYD = "KYD ", KZT = "KZT ", LAK = "LAK ", LBP = "LBP ", LKR = "LKR ", LSL = "LSL ", LTC = "Ł ", LYD = "LYD ", MAD = "MAD ", MDL = "MDL ", MGA = "MGA ", MKD = "MKD ", MMK = "MMK ", MNT = "MNT ", MOP = "MOP ", MRO = "MRO ", MUR = "MUR ", MVR = "MVR ", MWK = "MWK ", MXN = "MX$ ", MYR = "MYR ", MZN = "MZN ", NAD = "NAD ", NGN = "NGN ", NGNI = "NGNI ", NIO = "NIO ", NOK = "NOK ", NPR = "NPR ", NZD = "NZ$ ", OMR = "OMR ", PAB = "PAB ", PEN = "PEN ", PGK = "PGK ", PHP = "₱ ", PKR = "PKR ", PLN = "PLN ", PYG = "PYG ", QAR = "QAR ", RON = "RON ", RSD = "RSD ", RUB = "RUB ", RWF = "RWF ", SAR = "SAR ", SCR = "SCR ", SDG = "SDG ", SDR = "SDR ", SEK = "SEK ", SGD = "SGD ", SOL = "SOL ", SOS = "SOS ", STD = "STD ", SVC = "SVC ", SYP = "SYP ", SZL = "SZL ", THB = "THB ", TJS = "TJS ", TMT = "TMT ", TND = "TND ", TRY = "TRY ", TTD = "TTD ", TWD = "NT$ ", TZS = "TZS ", UAH = "UAH ", UGX = "UGX ", USD = "$ ", UYU = "UYU ", UZS = "UZS ", VEF = "VEF ", VND = "₫ ", VUV = "VUV ", XAF = "FCFA ", XAG = "XAG ", XAGG = "XAGG ", XAU = "XAU ", XBR = "XBR ", XCD = "EC$ ", XOF = "F CFA ", XPF = "CFPF ", XRP = "✕ ", YER = "YER ", ZAR = "ZAR ", ZMK = "ZMK ", ZWL = "ZWL ",
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
                headers = { ["User-Agent"] = "KOReader-Bookshelf" },
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
local KEY_DATA       = "micromodule_exchange_rates_data"
local KEY_PAIRS      = "micromodule_exchange_rates_pairs"
local KEY_VIEW_INDEX = "micromodule_exchange_rates_index"
local KEY_LAST_FETCH = "micromodule_exchange_rates_last_fetch"
local CACHE_TTL_SEC  = 900 -- 15 minutes

local DEFAULT_PAIRS = "USD-BRL, EUR-BRL, BTC-USD"

local _error_msg = nil
local _is_fetching_screen = false
local _implicit_fetch_pending = false

-- ─── Fetch ──────────────────────────────────────────────────────────────────
local function fetchExchangeData(callback)
    _implicit_fetch_pending = true
    
    local Store = require("lib/bookshelf_settings_store")
    local NetworkMgr  = require("ui/network/manager")
    local UIManager   = require("ui/uimanager")
    
    _error_msg = nil

    UIManager:scheduleIn(0.1, function()
        local raw_pairs = Store.read(KEY_PAIRS) or DEFAULT_PAIRS
        local clean_pairs = string.upper(string.gsub(raw_pairs, "%s+", ""))
        clean_pairs = string.gsub(clean_pairs, "^,+", "")
        clean_pairs = string.gsub(clean_pairs, ",+$", "")
        clean_pairs = string.gsub(clean_pairs, ",+", ",")
        if clean_pairs == "" then clean_pairs = "USD-BRL" end
        
        local url = "https://economia.awesomeapi.com.br/json/last/" .. clean_pairs
        local data = httpGetJSON(url)
        
        if data then
            if data.status and data.message then
                local bad_coin = string.match(data.message, "moeda nao encontrada (.*)")
                if bad_coin then
                    if not string.find(clean_pairs, bad_coin, 1, true) then
                        local prefix = string.match(bad_coin, "^(.-)%-")
                        if prefix and string.find(clean_pairs, prefix, 1, true) then
                            bad_coin = prefix
                        end
                    end
                    _error_msg = "Invalid symbol: " .. bad_coin
                else
                    _error_msg = string.gsub(data.message, "moeda nao encontrada%s*", "Invalid: ")
                end
                _implicit_fetch_pending = false
                if callback then callback(nil) end
                return
            end
            
            local parsed_list = {}
            -- AwesomeAPI returns keys like "USDBRL" for "USD-BRL"
            for pair_str in string.gmatch(clean_pairs, "[^,]+") do
                local api_key = string.gsub(pair_str, "-", "")
                local item = data[api_key]
                if item and item.bid then
                    table.insert(parsed_list, {
                        pair = pair_str,
                        name = item.name,
                        bid = item.bid,
                        pctChange = item.pctChange
                    })
                end
            end
            
            if #parsed_list > 0 then
                Store.save(KEY_DATA, parsed_list)
                Store.save(KEY_LAST_FETCH, os.time())
                Store.save(KEY_VIEW_INDEX, 1)
                _implicit_fetch_pending = false
                if callback then callback(parsed_list) end
                return
            end
        end
        
        _error_msg = _("Failed. Retry \xE2\x86\x92")
        _implicit_fetch_pending = false
        if callback then callback(nil) end
    end)
end

-- ─── UI Helpers ────────────────────────────────────────────────────────────
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
        -- Refetch if only one item
        fetchExchangeData(function()
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
            if dialog then
                UIManager:close(dialog)
            end
            if callback then callback() end
        end
    end
    
    local function showRoot()
        local current_pairs = Store.read(KEY_PAIRS) or DEFAULT_PAIRS

        local buttons = {}
        table.insert(buttons, { { text = _("Source: economia.awesomeapi.com.br"), enabled = false, callback = function() end } })
        
        table.insert(buttons, { { text = _("Tracked pairs") .. ": " .. current_pairs, font_bold = false, callback = close(function()
            local input_dialog
            input_dialog = InputDialog:new{
                title = _("Edit trading pairs"),
                description = _("Comma-separated (e.g. USD-BRL, EUR-BRL, BTC-USD)"),
                input = current_pairs,
                buttons = {
                    { { text = _("Cancel"), callback = function()
                        UIManager:close(input_dialog)
                        showRoot()
                    end } },
                    { { text = _("Save"), font_bold = true, callback = function()
                        local new_val = input_dialog:getInputValue()
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
        
        table.insert(buttons, { { text = _("Available currencies (Reference)"), font_bold = false, callback = close(function()
            local info = InfoMessage:new{ text = _("Fetching available currencies...") }
            UIManager:show(info)
            UIManager:scheduleIn(0.1, function()
                local data = httpGetJSON("https://economia.awesomeapi.com.br/json/available")
                UIManager:close(info)
                if data then
                    local currencies = {}
                    for pair_code, pair_name in pairs(data) do
                        local base_code, quote_code = pair_code:match("([^-]+)-([^-]+)")
                        local base_name, quote_name = pair_name:match("([^/]+)/(.+)")
                        
                        if base_code and base_name then
                            currencies[base_code] = base_name:match("^%s*(.-)%s*$") or base_name
                        end
                        if quote_code and quote_name then
                            currencies[quote_code] = quote_name:match("^%s*(.-)%s*$") or quote_name
                        end
                    end

                    local fiat = {}
                    local crypto = {}
                    
                    for code, name in pairs(currencies) do
                        local name_lower = string.lower(name)
                        local is_crypto = name_lower:match("bitcoin") or name_lower:match("ethereum") or 
                                          name_lower:match("litecoin") or name_lower:match("dogecoin") or 
                                          name_lower:match("ripple") or name_lower:match("cardano")
                        
                        if is_crypto then
                            table.insert(crypto, {code=code, name=name})
                        else
                            table.insert(fiat, {code=code, name=name})
                        end
                    end
                    table.sort(fiat, function(a,b) return a.code < b.code end)
                    table.sort(crypto, function(a,b) return a.code < b.code end)
                    
                    local function showCategory(title, list)
                        local menu
                        local item_table = { { text = _("← Back"), callback = function() UIManager:close(menu); showRoot() end } }
                        for _, item in ipairs(list) do
                            table.insert(item_table, {
                                text = item.code .. " (" .. item.name .. ")",
                                callback = function()
                                    -- Read-only reference list. Just close and go back to root.
                                    UIManager:close(menu)
                                    showRoot()
                                end
                            })
                        end
                        menu = Menu:new{ title = title, item_table = item_table, is_enable_shortcut = false, onClose = function() UIManager:close(menu); showRoot() end }
                        UIManager:show(menu)
                    end
                    
                    local cat_menu
                    local cat_items = {
                        { text = _("← Cancel"), callback = function() UIManager:close(cat_menu); showRoot() end },
                        { text = _("Fiat Currencies") .. " (" .. #fiat .. ")", callback = function() UIManager:close(cat_menu); showCategory(_("Fiat Currencies"), fiat) end },
                        { text = _("Cryptocurrencies") .. " (" .. #crypto .. ")", callback = function() UIManager:close(cat_menu); showCategory(_("Cryptocurrencies"), crypto) end },
                    }
                    cat_menu = Menu:new{ title = _("Currency Reference"), item_table = cat_items, is_enable_shortcut = false, onClose = function() UIManager:close(cat_menu); showRoot() end }
                    UIManager:show(cat_menu)
                else
                    local msg = InfoMessage:new{ text = _("Failed to fetch currencies.") }
                    UIManager:show(msg)
                    UIManager:scheduleIn(2, function() UIManager:close(msg); showRoot() end)
                end
            end)
        end) } })

        table.insert(buttons, { { text = _("Close"), font_bold = true, callback = close() } })

        dialog = ButtonDialog:new{
            title = _("Exchange Rates Settings"),
            title_align = "center",
            use_info_style = false,
            buttons = buttons
        }
        UIManager:show(dialog)
    end
    
    showRoot()
end

return {
    key   = "exchange_rates",
    title = _("Exchange Rates"),
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
                    text = _("Exchange Rates"),
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
        
        local face_h, bold_h = Fonts:getFace("cfont", sc(12), {bold = true})
        local header_text = data and (data.pair .. " - " .. data.name) or _("Exchange Rates")
        
        group[#group + 1] = TextBoxWidget:new{
            text = header_text,
            face = face_h, bold = bold_h,
            fgcolor = MUTED,
            bgcolor = SM.CARD_BG,
            width = mw,
            height = math.floor(face_h.size * 1.3 + 0.5) * 2,
            height_adjust = true,
        }

        if not data or (is_stale and not _error_msg) then
            _is_fetching_screen = not data
            local fetch_text = _error_msg or (data and data.bid) or _("Fetching data...")
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
                    fetchExchangeData(function(res)
                        _is_fetching_screen = false
                        if res then
                            _error_msg = nil
                        end
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
        
        -- Bid price
        local quote_currency = string.match(data.pair, "%-(.*)") or ""
        local sym = CURRENCY_SYMBOLS[quote_currency] or ""
        
        local face_price, bold_price = Fonts:getFace("cfont", sc(24), {bold = true})
        group[#group + 1] = TextBoxWidget:new{
            text = sym .. data.bid,
            face = face_price, bold = bold_price,
            fgcolor = PRIMARY, 
            bgcolor = SM.CARD_BG,
            width = mw,
            height = math.floor(face_price.size * 1.3 + 0.5) * 2,
            height_adjust = true,
        }

        -- % Change
        local face_pct = Fonts:getFace("cfont", sc(14))
        local pct_prefix = tonumber(data.pctChange) > 0 and "+" or ""
        group[#group + 1] = TextBoxWidget:new{
            text = pct_prefix .. data.pctChange .. "% (24h)",
            face = face_pct,
            fgcolor = PRIMARY, 
            bgcolor = SM.CARD_BG,
            width = mw,
            height = math.floor(face_pct.size * 1.3 + 0.5) * 2,
            height_adjust = true,
        }

        group[#group + 1] = VerticalSpan:new{ width = sc(6) }

        local footer_text
        local is_italic = true
        local footer_color = MUTED
        
        if type(items) == "table" and #items > 1 then
            local dots = {}
            for i = 1, #items do
                table.insert(dots, i == current_idx and "●" or "○")
            end
            footer_text = table.concat(dots, " ")
            is_italic = false
            -- Use a lighter gray for dots because solid symbols appear darker than text
            local bb = require("ffi/blitbuffer")
            footer_color = bb.COLOR_GRAY_9 or MUTED
        else
            footer_text = _("Tap to refresh \xE2\x86\x92")
        end
            
        local footer_widget = TextWidget:new{
            text = footer_text,
            face = Fonts:getFace("cfont", sc(10), {italic = is_italic}),
            fgcolor = footer_color,
        }
        
        local CenterContainer = require("ui/widget/container/centercontainer")
        group[#group + 1] = CenterContainer:new{
            dimen = Geom:new{ w = mw, h = footer_widget:getSize().h },
            footer_widget
        }

        return group
    end,

    on_tap = function(ctx) cycleView(ctx) end,
}
