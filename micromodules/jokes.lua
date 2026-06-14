--[[
Start-menu module: Jokes.
Fetches a random joke from teehee.dev.
All jokes are family-friendly (question & answer format).
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
local KEY_DATA = "micromodule_jokes_data"

local _error_msg = nil
local _is_fetching_screen = false
local _implicit_fetch_pending = false
local _answer_revealed = false

-- ─── Fetch ──────────────────────────────────────────────────────────────────
local function fetchJoke(callback)
    if _implicit_fetch_pending then return end
    _implicit_fetch_pending = true

    local Store = require("lib/bookshelf_settings_store")
    local NetworkMgr  = require("ui/network/manager")
    local UIManager   = require("ui/uimanager")

    _error_msg = nil

    NetworkMgr:runWhenOnline(function()
        UIManager:scheduleIn(0.1, function()
            local url = "https://teehee.dev/api/joke"
            local data = httpGetJSON(url)

            if data and data.question and data.answer then
                local res = { question = data.question, answer = data.answer }
                local items = Store.read(KEY_DATA) or {}
                if type(items) == "table" and items.question then items = {items} end
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

    -- First tap: reveal the answer + prefetch next joke silently
    if not _answer_revealed then
        _answer_revealed = true
        -- Prefetch the next joke in the background while user reads the answer
        fetchJoke(nil)
        return
    end

    -- Second tap: cycle to next joke
    _answer_revealed = false
    local Store = require("lib/bookshelf_settings_store")
    local items = Store.read(KEY_DATA) or {}
    if type(items) == "table" and items.question then items = {items} end
    if type(items) ~= "table" then items = {} end

    if #items > 0 then
        table.remove(items, 1)
        Store.save(KEY_DATA, items)
    end
end

return {
    key   = "jokes",
    title = _("Jokes"),
    keep_open = true,

    render = function(width, scale_pct, is_preview)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local mw = width - sc(30)

        local SM = require("lib/bookshelf_start_menu_modules")
        local PRIMARY, MUTED = SM.COLOR_PRIMARY, SM.COLOR_MUTED

        if is_preview then
            return VerticalGroup:new{ align = "center",
                TextWidget:new{
                    text = _("Random jokes"),
                    face = Fonts:getFace("cfont", sc(15)),
                    fgcolor = MUTED, max_width = math.max(50, width),
                }
            }
        end

        local Store = require("lib/bookshelf_settings_store")
        local cached = Store.read(KEY_DATA)
        local data = nil
        if type(cached) == "table" then
            if cached.question then
                cached = { cached }
                Store.save(KEY_DATA, cached)
            end
            data = cached[1]
        end
        local UIManager = require("ui/uimanager")

        local group = VerticalGroup:new{ align = "left" }

        local face_h, bold_h = Fonts:getFace("cfont", sc(12), {bold = true})

        group[#group + 1] = TextBoxWidget:new{
            text = _("Joke"),
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
            local fetch_text = _error_msg or _("Fetching joke...")
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
                    fetchJoke(function(res)
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

        group[#group + 1] = VerticalSpan:new{ width = sc(4) }

        local CARD_BG = SM.CARD_BG

        if not _answer_revealed then
            -- Question only: large and prominent
            local face_q = Fonts:getFace("cfont", sc(16))
            group[#group + 1] = TextBoxWidget:new{
                text = data.question,
                face = face_q,
                fgcolor = PRIMARY,
                bgcolor = CARD_BG,
                width = mw,
                height = math.floor(face_q.size * 1.3 + 0.5) * 4,
                height_adjust = true,
            }
        else
            -- Question: small and gray (de-emphasized)
            local face_q_small = Fonts:getFace("cfont", sc(12))
            group[#group + 1] = TextBoxWidget:new{
                text = data.question,
                face = face_q_small,
                fgcolor = MUTED,
                bgcolor = CARD_BG,
                width = mw,
                height = math.floor(face_q_small.size * 1.3 + 0.5) * 2,
                height_adjust = true,
            }

            group[#group + 1] = VerticalSpan:new{ width = sc(4) }

            -- Answer: large, bold, and prominent
            local face_a, bold_a = Fonts:getFace("cfont", sc(16), {bold = true})
            group[#group + 1] = TextBoxWidget:new{
                text = data.answer,
                face = face_a, bold = bold_a,
                fgcolor = PRIMARY,
                bgcolor = CARD_BG,
                width = mw,
                height = math.floor(face_a.size * 1.3 + 0.5) * 4,
                height_adjust = true,
            }
        end

        group[#group + 1] = VerticalSpan:new{ width = sc(6) }

        local footer_text = _answer_revealed
            and _("Tap for next joke \xE2\x86\x92")
            or  _("Tap to reveal answer \xE2\x86\x92")
        group[#group + 1] = TextWidget:new{
            text = footer_text,
            face = Fonts:getFace("cfont", sc(12), {italic = true}),
            fgcolor = MUTED, max_width = mw,
        }

        return group
    end,

    show_settings = function(ctx)
        local UIManager = require("ui/uimanager")
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        dialog = ButtonDialog:new{
            title = _("Jokes Settings"),
            title_align = "center",
            use_info_style = false,
            buttons = {
                { { text = _("Source: teehee.dev"), enabled = false, callback = function() end } },
                { { text = _("Close"), font_bold = true, callback = function()
                    UIManager:close(dialog)
                end } },
            }
        }
        UIManager:show(dialog)
    end,

    on_tap = function(ctx) cycleView(ctx) end,
}
