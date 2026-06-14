--[[
Start-menu module: Useless Facts.
Fetches a random useless fact from uselessfacts.jsph.pl.
Supports English and German.
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
local KEY_DATA     = "micromodule_useless_facts_data"
local KEY_API_LANG = "useless_facts_api_lang"

local _error_msg = nil
local _is_fetching_screen = false
local _implicit_fetch_pending = false

-- ─── Fetch ──────────────────────────────────────────────────────────────────
local function fetchFact(callback)
    if _implicit_fetch_pending then return end
    _implicit_fetch_pending = true
    
    local Store = require("lib/bookshelf_settings_store")
    local NetworkMgr  = require("ui/network/manager")
    local UIManager   = require("ui/uimanager")
    
    _error_msg = nil

    NetworkMgr:runWhenOnline(function()
        UIManager:scheduleIn(0.1, function()
            local lang = Store.read(KEY_API_LANG) or "en"
            local url = "https://uselessfacts.jsph.pl/api/v2/facts/random?language=" .. lang
            local data = httpGetJSON(url)
            
            if data and data.text then
                local res = { text = data.text, source = data.source }
                local items = Store.read(KEY_DATA) or {}
                if type(items) == "table" and items.text then items = {items} end
                if type(items) ~= "table" then items = {} end
                table.insert(items, res)
                Store.save(KEY_DATA, items)
                
                _implicit_fetch_pending = false
                if callback then callback(res) end
            else
                _error_msg = _("Failed. Retry \xE2\x86\x92")
                _implicit_fetch_pending = false
                if callback then callback(nil) end
            end
        end)
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
    if type(items) == "table" and items.text then items = {items} end
    if type(items) ~= "table" then items = {} end
    
    if #items > 0 then
        table.remove(items, 1)
        Store.save(KEY_DATA, items)
    end
end

local function showSettings(ctx)
    local Store = require("lib/bookshelf_settings_store")
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
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
        local lang_val = Store.read(KEY_API_LANG) or "en"
        local lang_label = (lang_val == "de") and "Deutsch" or "English"

        dialog = ButtonDialog:new{
            title = _("Useless Facts Settings"),
            title_align = "center",
            use_info_style = false,
            buttons = {
                { { text = _("Source: uselessfacts.jsph.pl"), enabled = false, callback = function() end } },
                { { text = _("Language") .. ": " .. lang_label, font_bold = false, callback = close(function()
                    Store.save(KEY_API_LANG, lang_val == "en" and "de" or "en")
                    Store.save(KEY_DATA, nil)
                    _error_msg = nil
                    showRoot()
                end) } },
                { { text = _("Close"), font_bold = true, callback = close() } },
            }
        }
        UIManager:show(dialog)
    end
    
    showRoot()
end

return {
    key   = "useless_facts",
    title = _("Useless Facts"),
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
                    text = _("Random useless facts"),
                    face = Fonts:getFace("cfont", sc(15)),
                    fgcolor = MUTED, max_width = math.max(50, width),
                }
            }
        end

        local Store = require("lib/bookshelf_settings_store")
        local cached = Store.read(KEY_DATA)
        local data = nil
        if type(cached) == "table" then
            if cached.text then
                cached = { cached }
                Store.save(KEY_DATA, cached)
            end
            data = cached[1]
        end
        local UIManager = require("ui/uimanager")
        
        local group = VerticalGroup:new{ align = "left" }
        
        local face_h, bold_h = Fonts:getFace("cfont", sc(12), {bold = true})
        
        group[#group + 1] = TextBoxWidget:new{
            text = _("Useless Fact"),
            face = face_h, bold = bold_h,
            fgcolor = MUTED,
            bgcolor = SM.CARD_BG,
            width = mw,
            height = math.floor(face_h.size * 1.3 + 0.5) * 2,
            height_adjust = true,
        }

        if not data then
            _is_fetching_screen = true
            local face_q = Fonts:getFace("cfont", sc(16))
            local fetch_text = _error_msg or _("Fetching fact...")
            local text_w = TextWidget:new{
                text = fetch_text,
                face = face_q,
                fgcolor = PRIMARY,
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
                UIManager:scheduleIn(0.1, function()
                    fetchFact(function(res)
                        _is_fetching_screen = false
                        _error_msg = nil
                        local StartMenu = require("lib/bookshelf_start_menu")
                        if StartMenu._live and StartMenu._live._reload then
                            StartMenu._live:_reload()
                        end
                    end)
                end)
            end
            group[#group + 1] = fetch_msg
            return group
        end
        _is_fetching_screen = false

        -- Silently prefetch the next fact while this one is displayed
        if type(cached) == "table" and #cached <= 1 then
            fetchFact(nil)
        end

        group[#group + 1] = VerticalSpan:new{ width = sc(4) }
        
        local face_q = Fonts:getFace("cfont", sc(16))
        group[#group + 1] = TextBoxWidget:new{
            text = data.text,
            face = face_q,
            fgcolor = PRIMARY, 
            bgcolor = SM.CARD_BG,
            width = mw,
            height = math.floor(face_q.size * 1.3 + 0.5) * 6,
            height_adjust = true,
        }

        group[#group + 1] = VerticalSpan:new{ width = sc(6) }

        group[#group + 1] = TextWidget:new{
            text = _("Tap for next fact \xE2\x86\x92"),
            face = Fonts:getFace("cfont", sc(12), {italic = true}),
            fgcolor = MUTED, max_width = mw,
        }

        return group
    end,

    on_tap = function(ctx) cycleView(ctx) end,
}
