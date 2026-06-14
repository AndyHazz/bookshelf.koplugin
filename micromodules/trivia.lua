--[[
Start-menu module: Trivia.
Fetches a random trivia question from Open Trivia DB.
Tap to reveal the answer. Tap again to load a new question.
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

-- ─── Helper: URL Decode ────────────────────────────────────────────────────────
local function urlDecode(str)
    if not str then return "" end
    str = string.gsub(str, "+", " ")
    str = string.gsub(str, "%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

-- ─── HTTP helper ─────────────────────────────────────────────────────────────
local function httpGetJSON(url)
    local json = require("json")
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if ok_require then
        local body = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(2, 10)
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
    local handle = io.popen(string.format("curl -s -L --max-time 10 -H 'User-Agent: KOReader-Bookshelf' %q", url))
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
local KEY_DATA       = "micromodule_trivia_data"
local KEY_CATEGORY   = "trivia_category"
local KEY_DIFFICULTY = "trivia_difficulty"
local KEY_TYPE       = "trivia_type"
local KEY_API_LANG   = "trivia_api_lang"
local KEY_API_TOKEN_EN = "trivia_api_token_en"
local KEY_API_TOKEN_PT = "trivia_api_token_pt"

local CATEGORIES = {
    { text = "Any", value = "", icon = "dice-multiple" },
    { text = "General Knowledge", value = "9", icon = "lightbulb-on" },
    { text = "Books", value = "10", icon = "book-open-page-variant" },
    { text = "Film", value = "11", icon = "filmstrip" },
    { text = "Music", value = "12", icon = "music-circle" },
    { text = "Television", value = "14", icon = "television-classic" },
    { text = "Video Games", value = "15", icon = "gamepad-variant" },
    { text = "Science & Nature", value = "17", icon = "atom" },
    { text = "Computers", value = "18", icon = "laptop" },
    { text = "Mathematics", value = "19", icon = "calculator" },
    { text = "Mythology", value = "20", icon = "pillar" },
    { text = "Sports", value = "21", icon = "basketball" },
    { text = "Geography", value = "22", icon = "globe" },
    { text = "History", value = "23", icon = "bank" },
    { text = "Politics", value = "24", icon = "gavel" },
    { text = "Art", value = "25", icon = "palette" },
    { text = "Animals", value = "27", icon = "cat" },
    { text = "Vehicles", value = "28", icon = "car-sports" },
}

local DIFFICULTIES = {
    { text = "Any", value = "", icon = "dice-multiple" },
    { text = "Easy", value = "easy", raw_icon = "★☆☆" },
    { text = "Medium", value = "medium", raw_icon = "★★☆" },
    { text = "Hard", value = "hard", raw_icon = "★★★" },
}

local TYPES = {
    { text = "Any", value = "", icon = "dice-multiple" },
    { text = "Multiple Choice", value = "multiple", icon = "format-list-bulleted" },
    { text = "True/False", value = "boolean", icon = "toggle-switch" },
}

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

-- ─── Fetch ──────────────────────────────────────────────────────────────────
local _implicit_fetch_pending = false

local function fetchTrivia(callback, is_retry)
    if not is_retry and _implicit_fetch_pending then return end
    _implicit_fetch_pending = true
    
    local Store = require("lib/bookshelf_settings_store")
    local NetworkMgr  = require("ui/network/manager")
    local UIManager   = require("ui/uimanager")

    NetworkMgr:runWhenOnline(function()
        UIManager:scheduleIn(0.1, function()
            local cat = Store.read(KEY_CATEGORY)
            local diff = Store.read(KEY_DIFFICULTY)
            
            local api_lang = Store.read(KEY_API_LANG) or "en"
            local url
            local token_url_base
            local token_key
            if api_lang == "pt" then
                url = "https://tryvia.ptr.red/api.php?amount=20"
                token_url_base = "https://tryvia.ptr.red/api_token.php"
                token_key = KEY_API_TOKEN_PT
            else
                url = "https://opentdb.com/api.php?amount=20&encode=url3986"
                token_url_base = "https://opentdb.com/api_token.php"
                token_key = KEY_API_TOKEN_EN
            end
            
            local function isValid(val, list)
                for _, item in ipairs(list) do
                    if item.value == val then return true end
                end
                return false
            end
            
            if type(cat) == "table" and not cat[""] then
                local keys = {}
                for k, v in pairs(cat) do
                    if v and isValid(k, CATEGORIES) then table.insert(keys, k) end
                end
                if #keys > 0 then
                    local random_cat = keys[math.random(#keys)]
                    url = url .. "&category=" .. random_cat
                end
            elseif type(cat) == "string" and cat ~= "" and isValid(cat, CATEGORIES) then
                url = url .. "&category=" .. cat
            end
            
            if type(diff) == "table" and not diff[""] then
                local keys = {}
                for k, v in pairs(diff) do
                    if v and isValid(k, DIFFICULTIES) then table.insert(keys, k) end
                end
                if #keys > 0 then
                    local random_diff = keys[math.random(#keys)]
                    url = url .. "&difficulty=" .. random_diff
                end
            elseif type(diff) == "string" and diff ~= "" and isValid(diff, DIFFICULTIES) then
                url = url .. "&difficulty=" .. diff
            end
            
            local type_val = Store.read(KEY_TYPE)
            if type(type_val) == "table" and not type_val[""] then
                local keys = {}
                for k, v in pairs(type_val) do
                    if v and isValid(k, TYPES) then table.insert(keys, k) end
                end
                if #keys > 0 then
                    local random_type = keys[math.random(#keys)]
                    url = url .. "&type=" .. random_type
                end
            elseif type(type_val) == "string" and type_val ~= "" and isValid(type_val, TYPES) then
                url = url .. "&type=" .. type_val
            end
            local token = Store.read(token_key)
            if token and type(token) == "string" and token ~= "" then
                url = url .. "&token=" .. token
            end
            
            local data = httpGetJSON(url)

            if data and (data.response_code == 3 or data.response_code == 4) then
                if not is_retry then
                    local t_url = token_url_base .. "?command=" .. (token and "reset&token=" .. token or "request")
                    local t_data = httpGetJSON(t_url)
                    if t_data and t_data.response_code == 0 and t_data.token then
                        Store.save(token_key, t_data.token)
                    else
                        Store.save(token_key, nil)
                    end
                    return fetchTrivia(callback, true)
                else
                    _implicit_fetch_pending = false
                    if callback then callback(nil, 5) end
                    return
                end
            end

            if data and data.results and #data.results > 0 then
                local items = {}
                for _, res in ipairs(data.results) do
                    local options = {}
                    if res.incorrect_answers then
                        for _, ans in ipairs(res.incorrect_answers) do
                            table.insert(options, urlDecode(ans))
                        end
                    end
                    table.insert(options, urlDecode(res.correct_answer))
                    -- Shuffle the options
                    for i = #options, 2, -1 do
                        local j = math.random(i)
                        options[i], options[j] = options[j], options[i]
                    end

                    table.insert(items, {
                        category = urlDecode(res.category),
                        difficulty = string.upper(string.sub(urlDecode(res.difficulty), 1, 1)) .. string.sub(urlDecode(res.difficulty), 2),
                        question = urlDecode(res.question),
                        correct_answer = urlDecode(res.correct_answer),
                        options = options,
                    })
                end
                Store.save(KEY_DATA, items)
                _implicit_fetch_pending = false
                if callback then callback(items[1]) end
            else
                _implicit_fetch_pending = false
                local code = data and data.response_code
                if code == 0 and data and data.results and #data.results == 0 then
                    code = 1
                end
                if callback then callback(nil, code) end
            end
        end)
    end)
end

-- ─── View state ─────────────────────────────────────────────────────────────
local _view_mode = "question" -- "question" | "answer"

local _is_fetching_screen = false
local _error_msg = nil

local function cycleView(ctx)
    if _error_msg then
        if _error_msg == _("No questions \xE2\x96\xB6") or _error_msg == _("Rate limit \xE2\x96\xB6") then
            local UIManager = require("ui/uimanager")
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Long-press to change filters"),
                timeout = 2,
            })
            return
        end
        _error_msg = nil
        _is_fetching_screen = false
        return
    end
    if _is_fetching_screen then
        _is_fetching_screen = false
        _view_mode = "question"
        return
    end

    if _view_mode == "question" then
        _view_mode = "answer"
    else
        -- If already in answer mode, tap means "next question"
        _view_mode = "question"
        
        -- Pop current question from the local cache list
        local Store = require("lib/bookshelf_settings_store")
        local data = Store.read(KEY_DATA)
        if type(data) == "table" and #data > 0 then
            table.remove(data, 1)
            if #data > 0 then
                Store.save(KEY_DATA, data)
            else
                Store.save(KEY_DATA, nil)
            end
        else
            Store.save(KEY_DATA, nil)
        end
    end
end

-- ─── Spec ───────────────────────────────────────────────────────────────────
return {
    key   = "trivia",
    title = _("Trivia"),
    keep_open = true,

    show_settings = function(ctx)
        local Store = require("lib/bookshelf_settings_store")
        local Menu = require("ui/widget/menu")
        local MenuHost = require("lib/bookshelf_menu_host")
        local UIManager = require("ui/uimanager")
        local ButtonDialog = require("ui/widget/buttondialog")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Screen = require("device").screen

        local function showRoot()
            local dialog
            local function close(fn)
                return function()
                    UIManager:close(dialog)
                    if fn then fn() end
                end
            end

            local function showMultiSelectMenu(title, store_key, options_list)
                local current = Store.read(store_key)
                if type(current) ~= "table" then
                    if current and current ~= "" then
                        current = { [current] = true }
                    else
                        current = { [""] = true }
                    end
                end

                local menu, center
                local function rebuildItems()
                    local items = {}
                    for i, opt in ipairs(options_list) do
                        local text = _(opt.text)
                        local is_selected = current[opt.value] and true or false
                        local checkbox = is_selected and getIconStr("checkbox-marked") or getIconStr("checkbox-blank-outline")
                        local icon_str = opt.raw_icon or (opt.icon and getIconStr(opt.icon) or nil)
                        if icon_str then
                            if opt.icon_right then
                                text = checkbox .. "  " .. text .. "  " .. icon_str
                            else
                                text = checkbox .. "  " .. icon_str .. "  " .. text
                            end
                        else
                            text = checkbox .. "  " .. text
                        end
                        table.insert(items, {
                            text = text,
                            bold = is_selected,
                            callback = function()
                                if opt.value == "" then
                                    current = { [""] = true }
                                else
                                    current[""] = nil
                                    if current[opt.value] then
                                        current[opt.value] = nil
                                    else
                                        current[opt.value] = true
                                    end
                                    
                                    local count = 0
                                    for k, v in pairs(current) do
                                        if v then count = count + 1 end
                                    end
                                    
                                    if count == 0 or count == #options_list - 1 then 
                                        current = { [""] = true } 
                                    end
                                end
                                Store.save(store_key, current)
                                Store.save(KEY_DATA, nil) -- clear cache
                                _error_msg = nil
                                menu.item_table = rebuildItems()
                                menu:updateItems()
                                UIManager:setDirty(nil, "ui")
                            end,
                        })
                    end
                    return items
                end

                menu = Menu:new{
                    title = title,
                    item_table = rebuildItems(),
                    is_popout = true,
                    width = math.floor(Screen:getWidth() * 0.85),
                    height = math.floor(Screen:getHeight() * 0.85),
                }
                menu.is_enable_shortcut = false
                menu.onMenuSelect = function(self, item)
                    self:onMenuChoice(item)
                    return true
                end
                
                center = CenterContainer:new{
                    dimen = Screen:getSize(),
                    menu
                }
                menu.show_parent = center
                menu:updateItems() -- Force recalculation without shortcuts before showing

                menu.onCloseAllMenus = function(self)
                    UIManager:close(center)
                    showRoot()
                    return true
                end
                UIManager:show(center)
            end

            local function getLabel(store_key, options_list, use_icons)
                local current = Store.read(store_key)
                local label = _("Any")
                if type(current) == "table" and not current[""] then
                    local parts = {}
                    for i, opt in ipairs(options_list) do
                        if current[opt.value] then
                            if use_icons and opt.icon then
                                table.insert(parts, getIconStr(opt.icon))
                            else
                                table.insert(parts, _(opt.text))
                            end
                        end
                    end
                    if #parts > 0 then
                        if use_icons then
                            label = table.concat(parts, " ")
                        else
                            label = table.concat(parts, ", ")
                        end
                    end
                elseif type(current) == "string" and current ~= "" then
                    for i, opt in ipairs(options_list) do 
                        if opt.value == current then 
                            if use_icons and opt.icon then
                                label = getIconStr(opt.icon)
                            else
                                label = _(opt.text) 
                            end
                        end 
                    end
                end
                return label
            end

            local cat_label = getLabel(KEY_CATEGORY, CATEGORIES, true)
            local diff_label = getLabel(KEY_DIFFICULTY, DIFFICULTIES, false)
            local type_label = getLabel(KEY_TYPE, TYPES, false)
            
            local lang_val = Store.read(KEY_API_LANG) or "en"
            local lang_label = (lang_val == "pt") and "Português" or "English"

            dialog = ButtonDialog:new{
                title = _("Trivia Settings"),
                title_align = "center",
                use_info_style = false,
                buttons = {
                    { { text = _("Language") .. ": " .. lang_label, font_bold = false, callback = close(function()
                        Store.save(KEY_API_LANG, lang_val == "en" and "pt" or "en")
                        Store.save(KEY_DATA, nil) -- clear cache
                        _error_msg = nil
                        showRoot()
                    end) } },
                    { { text = _("Category") .. ": " .. cat_label, font_bold = false, callback = close(function() showMultiSelectMenu(_("Categories"), KEY_CATEGORY, CATEGORIES) end) } },
                    { { text = _("Difficulty") .. ": " .. diff_label, font_bold = false, callback = close(function() showMultiSelectMenu(_("Difficulty"), KEY_DIFFICULTY, DIFFICULTIES) end) } },
                    { { text = _("Type") .. ": " .. type_label, font_bold = false, callback = close(function() showMultiSelectMenu(_("Type"), KEY_TYPE, TYPES) end) } },
                }
            }
            UIManager:show(dialog)
        end
        showRoot()
    end,

    render = function(width, scale_pct, is_preview)
        local Blitbuffer      = require("ffi/blitbuffer")
        local Geom            = require("ui/geometry")
        local Fonts           = require("lib/bookshelf_fonts")
        local TextWidget      = require("ui/widget/textwidget")
        local TextBoxWidget   = require("ui/widget/textboxwidget")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local FrameContainer  = require("ui/widget/container/framecontainer")
        local Store           = require("lib/bookshelf_settings_store")
        local UIManager       = require("ui/uimanager")

        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local BLACK, GRAY = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_DARK_GRAY

        if is_preview then
            return VerticalGroup:new{ align = "center",
                TextWidget:new{
                    text = _("Random trivia questions"),
                    face = Fonts:getFace("cfont", sc(15)),
                    fgcolor = GRAY, max_width = mw,
                }
            }
        end

        local cached = Store.read(KEY_DATA)
        local data = nil
        if type(cached) == "table" then
            if cached.question then
                -- Legacy single-item cache, convert to array format
                cached = { cached }
                Store.save(KEY_DATA, cached)
            end
            data = cached[1]
        end
        local group = VerticalGroup:new{ align = "left" }

        local face_h, bold_h = Fonts:getFace("cfont", sc(13), {bold = true})
        
        -- Top row
        local header_text = _("Trivia")
        if data and data.category then
            local cat = data.category:gsub("Entertainment: ", ""):gsub("Science: ", "")
            header_text = string.format("%s (%s)", cat, data.difficulty)
        end
        group[#group + 1] = TextBoxWidget:new{
            text = header_text,
            face = face_h, bold = bold_h,
            fgcolor = GRAY,
            bgcolor = require("lib/bookshelf_start_menu_modules").CARD_BG,
            width = mw,
            height = math.floor(face_h.size * 1.3 + 0.5) * 2,
            height_adjust = true,
        }

        if not data then
            _is_fetching_screen = true
            _view_mode = "question"
            local face_q = Fonts:getFace("cfont", sc(16))
            local fetch_text = _error_msg or _("Fetching question...")
            local text_w = TextWidget:new{
                text = fetch_text,
                face = face_q,
                fgcolor = BLACK,
            }
            local fetch_msg = FrameContainer:new{
                background = require("lib/bookshelf_start_menu_modules").CARD_BG,
                bordersize = 0,
                padding = 0,
                CenterContainer:new{
                    dimen = Geom:new{ w = mw, h = math.floor(face_q.size * 1.3 + 0.5) * 4 },
                    text_w
                }
            }
            if not _error_msg and not _implicit_fetch_pending and not is_preview then
                UIManager:scheduleIn(0.1, function()
                    fetchTrivia(function(res, code)
                        if res then
                            _is_fetching_screen = false
                            _error_msg = nil
                            local StartMenu = require("lib/bookshelf_start_menu")
                            if StartMenu._live and StartMenu._live._reload then
                                StartMenu._live:_reload()
                            end
                        else
                            if code == 5 then _error_msg = _("Rate limit \xE2\x96\xB6")
                            elseif code == 1 then _error_msg = _("No questions \xE2\x96\xB6")
                            else _error_msg = _("Failed. Retry \xE2\x96\xB6") end
                            
                            _is_fetching_screen = false
                            _implicit_fetch_pending = false
                            local StartMenu = require("lib/bookshelf_start_menu")
                            if StartMenu._live and StartMenu._live._reload then
                                StartMenu._live:_reload()
                            end
                        end
                    end)
                end)
            end
            group[#group + 1] = fetch_msg
            return group
        end
        _is_fetching_screen = false

        group[#group + 1] = VerticalSpan:new{ width = sc(4) }
        
        local face_q = Fonts:getFace("cfont", sc(16))
        group[#group + 1] = TextBoxWidget:new{
            text = data.question,
            face = face_q,
            fgcolor = BLACK, 
            bgcolor = require("lib/bookshelf_start_menu_modules").CARD_BG,
            width = mw,
            height = math.floor(face_q.size * 1.3 + 0.5) * 6,
            height_adjust = true,
        }

        group[#group + 1] = VerticalSpan:new{ width = sc(6) }

        if data.options and #data.options > 1 then
            for i, opt in ipairs(data.options) do
                local label = ""
                if i <= 26 then label = string.char(64 + i) .. ") " end
                
                local is_correct = (_view_mode == "answer") and (opt == data.correct_answer)
                local opt_face, opt_bold = Fonts:getFace("cfont", sc(16), is_correct and {bold = true} or nil)
                
                group[#group + 1] = TextBoxWidget:new{
                    text = label .. opt,
                    face = opt_face,
                    bold = opt_bold,
                    fgcolor = BLACK,
                    bgcolor = require("lib/bookshelf_start_menu_modules").CARD_BG,
                    width = mw,
                    height = math.floor(opt_face.size * 1.3 + 0.5) * 4,
                    height_adjust = true,
                }
                group[#group + 1] = VerticalSpan:new{ width = sc(2) }
            end
        end

        group[#group + 1] = VerticalSpan:new{ width = sc(4) }

        if _view_mode == "question" then
            group[#group + 1] = TextWidget:new{
                text = _("Tap to reveal answer \xE2\x96\xB6"),
                face = Fonts:getFace("cfont", sc(12), {italic = true}),
                fgcolor = GRAY, max_width = mw,
            }
        else
            group[#group + 1] = TextWidget:new{
                text = _("Tap for next question \xE2\x96\xB6"),
                face = Fonts:getFace("cfont", sc(12), {italic = true}),
                fgcolor = GRAY, max_width = mw,
            }
        end

        return group
    end,

    on_tap = function(ctx) cycleView(ctx) end,
}
