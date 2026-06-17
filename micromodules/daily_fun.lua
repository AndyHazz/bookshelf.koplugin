--[[
Start-menu module: Daily Fun.
Fetches random useless facts, jokes, and riddles.
Configurable via settings to select which categories to show.
]]
local _ = require("lib/bookshelf_i18n").gettext
local SafeText = require("lib/bookshelf_text_safe")

math.randomseed(os.time())

-- ─── HTTP helper ─────────────────────────────────────────────────────────────
local function httpGetJSON(url)
    local json = require("json")
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if ok_require then
        local body = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(10, 15)
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
    local handle = io.popen(string.format("curl -s -L --connect-timeout 5 --max-time 15 -H 'User-Agent: KOReader-Bookshelf' %q", url))
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
local KEY_DATA = "micromodule_daily_fun_data"
local KEY_CATS = "micromodule_daily_fun_cats"

local _error_msg = nil
local _is_fetching_screen = false
local _implicit_fetch_pending = false
local _answer_revealed = false
local _seq_index = 0

local API_CONFIGS = {
    fact = {
        url = "https://uselessfacts.jsph.pl/api/v2/facts/random?language=en",
        parse = function(data)
            if data.text then
                return { type = "fact", question = data.text, answer = nil }
            end
        end,
    },
    joke = {
        url = "https://v2.jokeapi.dev/joke/Any?safe-mode",
        parse = function(data)
            if data.type == "single" and data.joke then
                return { type = "joke", question = data.joke, answer = nil }
            elseif data.type == "twopart" and data.setup and data.delivery then
                return { type = "joke", question = data.setup, answer = data.delivery }
            end
        end,
    },
    riddle = {
        url = "https://riddles-api.vercel.app/random",
        parse = function(data)
            if data.riddle and data.answer then
                return { type = "riddle", question = data.riddle, answer = data.answer }
            end
        end,
    },
}

-- ─── Fetch ──────────────────────────────────────────────────────────────────
local MAX_BUFFER = 3

local function fetchFun(callback)
    if _implicit_fetch_pending then return end
    _implicit_fetch_pending = true
    
    local Store = require("lib/bookshelf_settings_store")
    local NetworkMgr  = require("ui/network/manager")
    local UIManager   = require("ui/uimanager")
    
    _error_msg = nil

    NetworkMgr:runWhenOnline(function()
        UIManager:scheduleIn(0.1, function()
            local cats = Store.read(KEY_CATS)
            if type(cats) ~= "table" then
                cats = { fact = true, joke = true, riddle = true }
            end
            
            -- Ensure at least one is active (fallback)
            if not cats.fact and not cats.joke and not cats.riddle then
                cats = { fact = true, joke = true, riddle = true }
            end
            
            local IDEAL_SEQUENCE = { "joke", "fact", "riddle", "fact" }
            local choice = "fact" -- fallback
            
            for _ = 1, #IDEAL_SEQUENCE do
                _seq_index = (_seq_index % #IDEAL_SEQUENCE) + 1
                local candidate = IDEAL_SEQUENCE[_seq_index]
                if cats[candidate] then
                    choice = candidate
                    break
                end
            end
            local config = API_CONFIGS[choice]
            local res = nil
            
            if config then
                local data = httpGetJSON(config.url)
                if data then
                    res = config.parse(data)
                end
            end
            
            if res then
                -- Joke/fact/riddle bodies are untrusted API text; sanitise
                -- before caching/rendering so invalid UTF-8 can't crash the
                -- text shaper at paint (issue #163).
                res.question = SafeText.safe(res.question)
                if res.answer then res.answer = SafeText.safe(res.answer) end
                local items = Store.read(KEY_DATA) or {}
                if type(items) ~= "table" or items.type then items = {} end
                table.insert(items, res)
                Store.save(KEY_DATA, items)
                
                _implicit_fetch_pending = false
                if _is_fetching_screen then
                    _is_fetching_screen = false
                    local StartMenu = require("lib/bookshelf_start_menu")
                    if StartMenu._live and StartMenu._live._reload then
                        StartMenu._live:_reload()
                    end
                end
                if callback then callback(res) end
            else
                _error_msg = _("Failed. Retry \xE2\x86\x92")
                _implicit_fetch_pending = false
                if _is_fetching_screen then
                    local StartMenu = require("lib/bookshelf_start_menu")
                    if StartMenu._live and StartMenu._live._reload then
                        StartMenu._live:_reload()
                    end
                end
                if callback then callback(nil) end
            end
        end)
    end)
end

local function prefetchIfNeeded()
    local Store = require("lib/bookshelf_settings_store")
    local items = Store.read(KEY_DATA) or {}
    if type(items) ~= "table" or items.type then items = {} end
    if #items >= MAX_BUFFER then return end
    if _implicit_fetch_pending then return end
    
    fetchFun(function(res)
        if res then
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(0.5, function() prefetchIfNeeded() end)
        end
    end)
end

-- ─── UI Helpers ────────────────────────────────────────────────────────────
local function cycleView(ctx)
    if _is_fetching_screen then
        if _error_msg then
            _error_msg = nil
            _is_fetching_screen = false
            prefetchIfNeeded()
        end
        return
    end
    
    _error_msg = nil
    
    local Store = require("lib/bookshelf_settings_store")
    local items = Store.read(KEY_DATA) or {}
    if type(items) ~= "table" or items.type then items = {} end
    local data = items[1]
    
    if data and data.answer and not _answer_revealed then
        _answer_revealed = true
        prefetchIfNeeded()
        return
    end
    
    _answer_revealed = false
    if #items > 0 then
        table.remove(items, 1)
        Store.save(KEY_DATA, items)
    end
    
    prefetchIfNeeded()
end

local function getIconStr(name)
    local NerdfontNames = require("lib/bookshelf_nerdfont_names")
    if not name then return "" end
    for _, entry in ipairs(NerdfontNames) do
        if entry.name == name then
            local c = entry.code
            if c < 0x80 then return string.char(c) end
            if c < 0x800 then return string.char(0xC0 + math.floor(c/64), 0x80 + (c%64)) end
            if c < 0x10000 then return string.char(0xE0 + math.floor(c/4096), 0x80 + (math.floor(c/64)%64), 0x80 + (c%64)) end
            if c < 0x110000 then return string.char(0xF0 + math.floor(c/262144), 0x80 + (math.floor(c/4096)%64), 0x80 + (math.floor(c/64)%64), 0x80 + (c%64)) end
        end
    end
    return ""
end

local function showSettings(ctx)
    local Store = require("lib/bookshelf_settings_store")
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Menu = require("ui/widget/menu")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Screen = require("device").screen
    local dialog
    
    local function close(callback)
        return function()
            if dialog then UIManager:close(dialog) end
            if callback then callback() end
        end
    end
    
    local function showCatsMenu()
        local current = Store.read(KEY_CATS)
        if type(current) ~= "table" then
            current = { fact = true, joke = true, riddle = true }
        end
        
        local menu, center
        local options = {
            { key = "fact", text = _("Useless Facts"), icon = "lightbulb-on" },
            { key = "joke", text = _("Jokes"), icon = "emoticon-happy" },
            { key = "riddle", text = _("Riddles"), icon = "help-circle" },
        }
        
        local function rebuild()
            local items = {}
            for _, opt in ipairs(options) do
                local is_selected = current[opt.key]
                local cb = is_selected and getIconStr("checkbox-marked") or getIconStr("checkbox-blank-outline")
                table.insert(items, {
                    text = cb .. "  " .. opt.text,
                    bold = is_selected,
                    callback = function()
                        current[opt.key] = not current[opt.key]
                        -- Check if all are false, if so force 'Any' (all true)
                        if not current.fact and not current.joke and not current.riddle then
                            current = { fact = true, joke = true, riddle = true }
                        end
                        Store.save(KEY_CATS, current)
                        Store.save(KEY_DATA, nil)
                        _error_msg = nil
                        menu.item_table = rebuild()
                        menu:updateItems()
                        UIManager:setDirty(nil, "ui")
                    end
                })
            end
            return items
        end
        
        menu = Menu:new{
            title = _("Categories"),
            item_table = rebuild(),
            is_popout = true,
            width = math.floor(Screen:getWidth() * 0.85),
            height = math.floor(Screen:getHeight() * 0.85),
        }
        menu.is_enable_shortcut = false
        menu.onMenuSelect = function(self, item)
            self:onMenuChoice(item)
            return true
        end
        center = CenterContainer:new{ dimen = Screen:getSize(), menu }
        menu.show_parent = center
        menu:updateItems()
        
        menu.onCloseAllMenus = function(self)
            UIManager:close(center)
            if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
            return true
        end
        UIManager:show(center)
    end
    
    dialog = ButtonDialog:new{
        title = _("Daily Fun Settings"),
        title_align = "center",
        use_info_style = false,
        buttons = {
            { { text = _("Sources: uselessfacts.jsph.pl, jokeapi.dev, riddles-api.vercel.app"), enabled = false, callback = function() end } },
            { { text = _("Choose Categories"), font_bold = false, callback = close(showCatsMenu) } },
            { { text = _("Close"), font_bold = true, callback = close() } },
        }
    }
    UIManager:show(dialog)
end

return {
    key   = "daily_fun",
    title = _("Daily Fun"),
    keep_open = true,

    show_settings = function(ctx)
        showSettings(ctx)
    end,

    render = function(width, scale_pct, is_preview)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local mw = width - sc(30)
        
        local SM = require("lib/bookshelf_start_menu_modules")
        local PRIMARY, MUTED = SM.COLOR_PRIMARY, SM.COLOR_MUTED
        local Fonts = require("lib/bookshelf_fonts")
        local Geom = require("ui/geometry")
        local TextWidget = require("ui/widget/textwidget")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local VerticalSpan = require("ui/widget/verticalspan")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local VerticalGroup = require("ui/widget/verticalgroup")

        if is_preview then
            return VerticalGroup:new{ align = "center",
                TextWidget:new{
                    text = _("Random facts,"),
                    face = Fonts:getFace("cfont", sc(15)),
                    fgcolor = MUTED, max_width = mw,
                },
                TextWidget:new{
                    text = _("jokes & riddles"),
                    face = Fonts:getFace("cfont", sc(15)),
                    fgcolor = MUTED, max_width = mw,
                }
            }
        end

        local Store = require("lib/bookshelf_settings_store")
        local items = Store.read(KEY_DATA) or {}
        if type(items) ~= "table" or items.type then items = {} end
        local data = items[1]

        local UIManager = require("ui/uimanager")
        local group = VerticalGroup:new{ align = "left" }
        
        local face_h, bold_h = Fonts:getFace("cfont", sc(12), {bold = true})
        local header_text = _("Daily Fun")
        if data then
            if data.type == "fact" then header_text = _("Useless Fact")
            elseif data.type == "joke" then header_text = _("Joke")
            elseif data.type == "riddle" then header_text = _("Riddle")
            end
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

        if not data then
            _answer_revealed = false
            _is_fetching_screen = true
            local face_q = Fonts:getFace("cfont", sc(16))
            local fetch_text = _error_msg or _("Fetching fun...")
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
                    prefetchIfNeeded()
                end)
            end
            group[#group + 1] = fetch_msg
            return group
        end
        _is_fetching_screen = false
        
        if not is_preview then
            prefetchIfNeeded()
        end

        group[#group + 1] = VerticalSpan:new{ width = sc(4) }
        
        local CARD_BG = SM.CARD_BG

        local function getFontSize(text)
            local len = string.len(text or "")
            if len > 200 then return 12
            elseif len > 120 then return 13
            elseif len > 60 then return 14
            else return 16 end
        end

        if not _answer_revealed then
            -- Show only question/fact
            local q_size = getFontSize(data.question)
            local face_q = Fonts:getFace("cfont", sc(q_size))
            group[#group + 1] = TextBoxWidget:new{
                text = data.question,
                face = face_q,
                fgcolor = PRIMARY,
                bgcolor = CARD_BG,
                width = mw,
                height = math.floor(face_q.size * 1.3 + 0.5) * 25,
                height_adjust = true,
            }
        else
            -- Show small question
            local face_q_small = Fonts:getFace("cfont", sc(12))
            group[#group + 1] = TextBoxWidget:new{
                text = data.question,
                face = face_q_small,
                fgcolor = MUTED,
                bgcolor = CARD_BG,
                width = mw,
                height = math.floor(face_q_small.size * 1.3 + 0.5) * 2,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
            }
            group[#group + 1] = VerticalSpan:new{ width = sc(4) }
            -- Show prominent answer
            local a_size = getFontSize(data.answer)
            local face_a, bold_a = Fonts:getFace("cfont", sc(a_size), {bold = true})
            group[#group + 1] = TextBoxWidget:new{
                text = data.answer,
                face = face_a, bold = bold_a,
                fgcolor = PRIMARY,
                bgcolor = CARD_BG,
                width = mw,
                height = math.floor(face_a.size * 1.3 + 0.5) * 20,
                height_adjust = true,
            }
        end

        group[#group + 1] = VerticalSpan:new{ width = sc(6) }

        local footer_text = ""
        if data.answer and not _answer_revealed then
            footer_text = _("Tap to reveal answer \xE2\x86\x92")
        else
            footer_text = _("Tap for next \xE2\x86\x92")
        end

        group[#group + 1] = TextWidget:new{
            text = footer_text,
            face = Fonts:getFace("cfont", sc(12), {italic = true}),
            fgcolor = MUTED, max_width = mw,
        }

        return group
    end,

    on_tap = function(ctx) cycleView(ctx) end,
}
