local _ = require("lib/bookshelf_i18n").gettext
local logger = require("logger")
local Store = require("lib/bookshelf_settings_store")

local function readNumBooks()
    return Store.read("lastbooks_num_books", 3)
end

local function readShowProgress()
    return Store.read("lastbooks_show_progress", false)
end

local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local dialog
    
    local function radio(label, value, is_num)
        local active = (is_num and readNumBooks() == value) or (not is_num and readShowProgress() == value)
        return {
            text = (active and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if is_num then
                    if readNumBooks() == value then return end
                    Store.save("lastbooks_num_books", value)
                else
                    if readShowProgress() == value then return end
                    Store.save("lastbooks_show_progress", value)
                end
                UIManager:close(dialog)
                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                showSettings(ctx)
            end,
        }
    end

    dialog = ButtonDialog:new{
        title = _("Last Books Settings"),
        title_align = "center",
        width_factor = 0.65,
        buttons = {
            { { text = _("Appearance"), enabled = false } },
            { radio(_("Show progress"), true, false), radio(_("Hide progress"), false, false) },
            { { text = _("Quantity"), enabled = false } },
            { radio("1", 1, true), radio("2", 2, true), radio("3", 3, true) },
        }
    }
    UIManager:show(dialog)
end

local last_tap_x = nil

local mymodule = {
    key = "lastbooks",
    title = _("Last Books"),
    summary = _("Shows covers of the last read books."),
    show_settings = showSettings,
}

mymodule.render = function(width, scale_pct, is_preview, avail_h, _refresh, _shape, _entry)
        local lfs = require("libs/libkoreader-lfs")
        local ReadHistory = require("readhistory")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local TextWidget = require("ui/widget/textwidget")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        local Geom = require("ui/geometry")
        local ImageWidget = require("ui/widget/imagewidget")
        
        local ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
        local Repo = require("lib/bookshelf_book_repository")
        local SM = require("lib/bookshelf_start_menu_modules")
        local Kit = require("lib/bookshelf_module_kit")
        local sc = Kit.sc(scale_pct)

        local mw = math.max(sc(110), width or sc(110))

        local hist = ReadHistory.hist or {}
        local n_items = readNumBooks()
        local items = {}
        local items_pct = {}
        
        -- Get currently open book (if any) to avoid showing it in "Last Books"
        local ReaderUI = require("apps/reader/readerui")
        local current_file = nil
        if ReaderUI.instance and ReaderUI.instance.document then
            current_file = ReaderUI.instance.document.file
        end

        for i = 1, #hist do
            local file = hist[i].file
            if file and lfs.attributes(file, "mode") == "file" then
                if not current_file or current_file ~= file then
                    table.insert(items, file)
                    local pct = Repo.readProgress(file)
                    items_pct[file] = pct or 0
                    if #items >= n_items then break end
                end
            end
        end

        if is_preview then
            local face, bold = Kit.face(15, scale_pct, { bold = true })
            local face2 = Kit.face(13, scale_pct)
            return VerticalGroup:new{
                align = "left",
                TextWidget:new{ text = _("Last Books"), face = face, bold = bold, fgcolor = SM.COLOR_PRIMARY, max_width = mw },
                TextWidget:new{ text = _("Shows last 3 covers"), face = face2, fgcolor = SM.COLOR_MUTED, max_width = mw },
            }
        end

        local gap = sc(8)
        local text_h = readShowProgress() and sc(20) or 0
        local cols = math.max(2, n_items)
        local card_w = math.floor((mw - (cols - 1) * gap) / cols)
        local card_h = math.floor(card_w * 1.45)
        
        if avail_h and avail_h > 0 then
            local max_h = avail_h - sc(35) -- Leave space for title "Last Books"
            if card_h + text_h > max_h then
                card_h = max_h - text_h
                card_w = math.floor(card_h / 1.45)
            end
        end
        local total_h = card_h + text_h

        local function getCoverWidget(file, card_w, card_h, pct)
            local cached = ScaledCoverCache:get(file)
            local bb = nil

            if cached and cached:getWidth() >= card_w and cached:getHeight() >= card_h then
                bb = cached
            else
                local ok, raw_bb = pcall(Repo.getCoverBB, file)
                bb = ok and raw_bb or nil
                if bb then
                    ScaledCoverCache:put(file, bb)
                    bb = ScaledCoverCache:get(file)
                else
                    logger.debug("[lastbooks] No cover for:", file)
                end
            end

            local img
            if bb then
                img = ImageWidget:new{
                    image = bb,
                    image_disposable = false,
                    width = card_w,
                    height = card_h,
                    scale_factor = 0,
                }
            else
                local face, bold = Kit.face(11, scale_pct)
                img = CenterContainer:new{
                    dimen = Geom:new{ w = card_w, h = card_h },
                    TextBoxWidget:new{
                        text = file:match("([^/]+)$") or "",
                        face = face,
                        bold = bold,
                        fgcolor = SM.COLOR_PRIMARY,
                        bgcolor = SM.CARD_BG,
                        width = card_w - sc(4),
                        height = card_h - sc(4),
                        height_adjust = true,
                        alignment = "center",
                    }
                }
            end

            local border = 1
            local cell = FrameContainer:new{
                width = card_w,
                height = card_h,
                bordersize = border,
                bordercolor = SM.COLOR_MUTED,
                padding = 0,
                CenterContainer:new{ dimen = Geom:new{ w = card_w - border * 2, h = card_h - border * 2 }, img }
            }

            if readShowProgress() then
                local face, bold = Kit.face(11, scale_pct, { bold = true })
                return VerticalGroup:new{
                    align = "center",
                    cell,
                    TextWidget:new{
                        text = math.floor(pct * 100) .. "%",
                        face = face,
                        bold = bold,
                        fgcolor = SM.COLOR_MUTED,
                    }
                }
            end

            return cell
        end

        local items_group = HorizontalGroup:new{ align = "center" }
        
        local touch_area
        if #items == 0 then
            local face = Kit.face(14, scale_pct)
            touch_area = CenterContainer:new{
                dimen = Geom:new{ w = mw, h = total_h },
                TextWidget:new{ text = _("No recent books found."), face = face, fgcolor = SM.COLOR_MUTED }
            }
        else
            for i, file in ipairs(items) do
                local card = getCoverWidget(file, card_w, card_h, items_pct[file])
                items_group[#items_group + 1] = card
                if i < #items then
                    items_group[#items_group + 1] = HorizontalSpan:new{ width = gap }
                end
            end

            local Device = require("device")
            touch_area = items_group

            -- O truque mestre: um InputContainer invisivel que intercepta os toques
            -- da tela para gravar a posicao X globalmente ANTES do ClipContainer estragar tudo.
            local interceptor = require("ui/widget/container/inputcontainer"):new{
                dimen = Geom:new{ w = mw, h = total_h },
                require("ui/widget/container/centercontainer"):new{
                    dimen = Geom:new{ w = mw, h = total_h },
                    touch_area
                }
            }

            if Device:isTouchDevice() then
                local GestureRange = require("ui/gesturerange")
                local TapTracker = GestureRange:new{
                    ges = "tap",
                    range = interceptor.dimen,
                }
                function TapTracker:match(gs)
                    if gs.ges == "tap" then
                        last_tap_x = gs.pos.x
                    end
                    return false -- Retorna falso para NUNCA consumir o toque. Deixa a row do StartMenu tratar!
                end

                interceptor.ges_events = {
                    Tap = { TapTracker }
                }
            end
            
            touch_area = interceptor
        end

        function mymodule.on_tap(ctx)
            local tap_x = last_tap_x
            last_tap_x = nil
            if not tap_x or not ctx or not ctx.menu then 
                return nil 
            end
            
            local menu_dimen = ctx.menu.dimen
            if not menu_dimen then 
                return nil 
            end
            
            -- Ignoramos a sugestão do Claude de usar paintTo, pois o KOReader usa ClipContainer (Blitbuffer)
            -- o que faz o 'x' do paintTo virar 0 local e quebra as coordenadas globais.
            -- A matemática fixa de layout do StartMenu é a única forma segura de obter a coordenada global real!
            local panel_border = ctx.menu._panel_border or 2
            local panel_pad = ctx.menu._panel_pad or 3
            local focus_border = ctx.menu._focus_border or 2
            local pad = ctx.menu._pad or 15
            local card_margin = math.floor(pad / 2)
            
            local inner_x = menu_dimen.x + panel_border + panel_pad + focus_border + card_margin + pad
            
            -- Centralizamos o grupo de cards na largura disponível (mw)
            local items_w = #items * card_w + (#items - 1) * gap
            local cx = inner_x + math.floor((mw - items_w) / 2)
            
            local target_file = nil
            for _, file in ipairs(items) do
                if tap_x >= cx and tap_x < cx + card_w then
                    target_file = file
                    break
                end
                cx = cx + card_w + gap
            end
            
            if target_file then
                local bw = ctx.bw or require("lib/bookshelf_widget").live
                if bw and bw._openBook then
                    -- Abrimos o livro correspondente
                    bw:_openBook({ filepath = target_file })
                else
                    local Event = require("ui/event")
                    local UIManager = require("ui/uimanager")
                    UIManager:broadcastEvent(Event:new("ShowReader", target_file))
                end
                return "lastbooks_opened"
            end
            return nil
        end

        local title_face, title_bold = Kit.face(12, scale_pct, { bold = true })
        return VerticalGroup:new{
            align = "left",
            TextBoxWidget:new{
                text = _("Last Books"),
                face = title_face,
                bold = title_bold,
                fgcolor = SM.COLOR_MUTED,
                bgcolor = SM.CARD_BG,
                width = mw,
                height = sc(16),
                height_adjust = true,
                alignment = "left",
            },
            require("ui/widget/verticalspan"):new{ width = sc(8) },
            touch_area
        }
    end

return mymodule
