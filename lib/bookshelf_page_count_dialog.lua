-- bookshelf_page_count_dialog.lua
-- The dialog in front of "Extract page counts": what the scan does, which
-- sources it may use, whether to fill only the missing counts or recount
-- every book, and a way to delete what earlier scans found.
--
-- Before it, the menu row started the scan straight away and asked one
-- question halfway through ("Paginate them the slow way?"), after the fast
-- passes had already run. The choices now come first and are remembered.
--
-- A tap repaints only what it changed (a checkbox, the Start button): a
-- dialog that closes and reopens per tap flashes the whole screen.

local ConfirmBox   = require("ui/widget/confirmbox")
local InfoMessage  = require("ui/widget/infomessage")
local UIManager    = require("ui/uimanager")
local Settings     = require("lib/bookshelf_settings_store")
local T            = require("ffi/util").template
local _            = require("lib/bookshelf_i18n").gettext

local M = {}

M.SETTING = "page_count_scan"   -- { publisher=, hardcover=, calibre=, filename=, render=, recount= }

-- options() -> the remembered choices, every source on by default.
function M.options()
    local saved = Settings.read(M.SETTING)
    local o = { publisher = true, hardcover = true, calibre = true, filename = true,
                render = true, recount = false }
    if type(saved) == "table" then
        for k in pairs(o) do
            if saved[k] ~= nil then o[k] = saved[k] and true or false end
        end
    end
    return o
end

local function hardcoverLinked()
    local ok, HC = pcall(require, "lib/bookshelf_hardcover")
    if not (ok and HC and HC.isAvailable and HC.isAvailable()) then return false end
    local ok_l, linked = pcall(HC.linkedPages)
    return ok_l and type(linked) == "table" and next(linked) ~= nil
end

-- calibreColumn() -> the Calibre page column's name and how many books fill
-- it, or nil (see Repo.calibrePageColumn).
local function calibreColumn()
    local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
    if not (ok and Repo and Repo.calibrePageColumn) then return nil end
    local ok_c, key, n = pcall(Repo.calibrePageColumn)
    if ok_c and key then return key, n end
    return nil
end

-- anySource(o, hc, cal) -> whether the scan would have anything to use.
function M.anySource(o, hc, cal)
    return o.publisher or (hc and o.hardcover) or (cal and o.calibre) or o.filename or o.render
end

-- deleteScanned(on_done): ask, then clear every count earlier scans stored.
-- Counts KOReader keeps for books that have been opened are not touched, and
-- neither is a p(N) in a file name (which is read again whenever no scanned
-- count stands in front of it).
function M.deleteScanned(on_done)
    local ok_f, Facts = pcall(require, "lib/bookshelf_book_facts_db")
    local n = ok_f and Facts.countPageCounts and Facts.countPageCounts() or 0
    if n == 0 then
        UIManager:show(InfoMessage:new{ text = _("There are no scanned page counts to delete."), timeout = 3 })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete %1 page counts found by earlier scans?\n\nCounts for books you have opened, and page counts in file names, are kept."), n),
        ok_text = _("Delete"),
        ok_callback = function()
            local cleared = Facts.clearPageCounts()
            local ok_r, Repo = pcall(require, "lib/bookshelf_book_repository")
            if ok_r and Repo.invalidateProgressCache then Repo.invalidateProgressCache() end
            UIManager:show(InfoMessage:new{
                text = T(_("Deleted %1 page counts."), cleared or n), timeout = 3 })
            if on_done then on_done() end
        end,
    })
end

-- show(start, on_deleted): start(options) runs the scan; on_deleted() lets the
-- caller redraw the shelf once counts are gone.
--
-- A dialog of its own rather than a ButtonDialog: the choices are two kinds
-- (sources, any mix; which books, one of two) and each source needs a word on
-- what it is and what it costs, which a list of ticked buttons could not say.
-- KOReader's own CheckButton gives the checkboxes and radio marks and repaints
-- just itself on a tap.
local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton     = require("ui/widget/checkbutton")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("lib/bookshelf_colour_text")
local SnugScroll      = require("lib/bookshelf_snug_scroll")
local TitleBar        = require("ui/widget/titlebar")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Device          = require("device")
local Space           = require("lib/bookshelf_space")
local Screen          = Device.screen

local Dialog = InputContainer:extend{}

function Dialog:init()
    local o, hc, cal = self.o, self.hc, self.cal
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.width = math.floor(math.min(sw, sh) * 0.9)
    local pad = Space.padding.large
    local gap = Space.padding.default
    local dialog = self
    local iw   -- the body's inner width; set per build below

    local function text(t, face, color, width)
        return TextBoxWidget:new{
            text = t, face = face, width = width or iw,
            fgcolor = color or Blitbuffer.COLOR_BLACK,
        }
    end
    local function heading(t)
        return TextWidget:new{ text = t, face = Font:getFace("smallinfofontbold") }
    end
    local hint_face = Font:getFace("x_smallinfofont")

    -- A checkbox (or radio) and, under its label, a grey line on what it is.
    local function option(spec)
        local cb = CheckButton:new{
            text = spec.label, checked = spec.checked, enabled = spec.enabled ~= false,
            radio = spec.radio, width = iw, parent = dialog, show_parent = dialog,
            callback = spec.callback,
        }
        local g = VerticalGroup:new{ align = "left", cb }
        if spec.hint then
            local indent = cb._checkmark and cb._checkmark.dimen.w or Screen:scaleBySize(30)
            g[#g + 1] = HorizontalGroup:new{
                HorizontalSpan:new{ width = indent },
                text(spec.hint, hint_face, Blitbuffer.COLOR_DARK_GRAY, iw - indent),
            }
        end
        g[#g + 1] = VerticalSpan:new{ width = gap }
        return g, cb
    end

    local save = function() Settings.save(M.SETTING, o) end
    local function updateStart()
        local btn = self.buttons and self.buttons:getButtonById("start")
        if not btn then return end
        if M.anySource(o, hc, cal) then btn:enable() else btn:disable() end
        UIManager:setDirty(self, function() return "ui", btn.dimen end)
    end
    local function source(key)
        return function()
            o[key] = not o[key]
            save()
            updateStart()
        end
    end

    -- Full width, so its own top rule (zero_sep) runs border to border and is
    -- the one line between the body and the buttons: a separate full-width
    -- rule above it plus the table's inset one read as two misaligned lines,
    -- worst where a scrolled body's bar meets them.
    self.buttons = ButtonTable:new{
        width = self.width,
        zero_sep = true,
        show_parent = self,
        buttons = {
            {{
                text = _("Delete scanned page counts\xe2\x80\xa6"),
                callback = function()
                    UIManager:close(self)
                    M.deleteScanned(self.on_deleted)
                end,
            }},
            {
                { text = _("Cancel"), callback = function() UIManager:close(self) end },
                {
                    id = "start", text = _("Start"), enabled = M.anySource(o, hc, cal),
                    callback = function()
                        UIManager:close(self)
                        local opts = {}
                        for k, v in pairs(o) do opts[k] = v end
                        opts.hardcover = opts.hardcover and hc
                        opts.calibre = (opts.calibre and cal) or false
                        self.start(opts)
                    end,
                },
            },
        },
    }

    -- build(inner_w) -> the body. Built twice when it does not fit the
    -- screen: the second time a scrollbar's width narrower, to go in a
    -- ScrollableContainer.
    local function build(inner_w)
        iw = inner_w
        local pub, _pub = option{
            label = _("Publisher page numbers (fast)"),
            hint  = _("Printed page numbers that some books carry."),
            checked = o.publisher, callback = source("publisher"),
        }
        local hcv, _hcv = option{
            label = _("Hardcover editions (fast)"),
            hint  = hc and _("The page count of the edition each linked book is matched to.")
                       or _("No books are linked to Hardcover."),
            checked = hc and o.hardcover, enabled = hc, callback = source("hardcover"),
        }
        local cal_hint
        if cal then
            cal_hint = T(_("The #%1 column in your Calibre metadata, as the Count Pages plugin fills in. Often an estimate."), cal)
        elseif require("lib/bookshelf_settings_store").read("calibre_metadata") ~= true then
            cal_hint = _("Needs Calibre metadata, which is off.")
        else
            cal_hint = _("No page count column in your Calibre metadata.")
        end
        local clb, _clb = option{
            label = _("Calibre page column (fast)"),
            hint  = cal_hint,
            checked = cal and o.calibre, enabled = cal ~= nil, callback = source("calibre"),
        }
        local fnm, _fnm = option{
            label = _("Page counts in file names (fastest)"),
            hint  = _("A count in the file name, like p(320), as some Calibre setups add. Often an estimate."),
            checked = o.filename, callback = source("filename"),
        }
        local ren, _ren = option{
            label = _("Your reading settings (slow)"),
            hint  = _("Lays out each remaining book in your font and margins, so the count matches what you see when reading."),
            checked = o.render, callback = source("render"),
        }
        local radios = {}
        local function pick(recount)
            return function()
                o.recount = recount
                save()
                for want, rb in pairs(radios) do
                    rb:initCheckButton(want == recount)
                    UIManager:setDirty(self, function() return "ui", rb.dimen end)
                end
            end
        end
        local missing, rb_missing = option{
            label = _("Only books without a page count"), radio = true,
            checked = not o.recount, callback = pick(false),
        }
        local every, rb_every = option{
            label = _("Every book, replacing earlier counts"), radio = true,
            checked = o.recount, callback = pick(true),
        }
        radios[false], radios[true] = rb_missing, rb_every

        local body = VerticalGroup:new{
            align = "left",
            text(_("Finds how long each book is, for spine thickness, page count badges, sorting and the page count token."),
                 Font:getFace("smallinfofont")),
            VerticalSpan:new{ width = pad },
            heading(_("Use page counts from, in this order")),
            VerticalSpan:new{ width = gap },
            pub, hcv, ren, clb, fnm,
            VerticalSpan:new{ width = gap },
            heading(_("Which books")),
            VerticalSpan:new{ width = gap },
            missing, every,
        }
        return body
    end

    -- The fixed parts are the title bar and the buttons; the body gets what
    -- is left of the screen, and scrolls when that is not enough. At a high
    -- screen DPI setting (480 on a PW5) the body alone outgrew the screen and
    -- the title bar went off the top (maintainer, on device).
    local title_bar = TitleBar:new{
        width = self.width,
        title = _("Extract page counts"),
        with_bottom_line = true,
        -- Nothing under the rule: the body brings its own padding, and a
        -- scrolled body's bar should start AT the rule, not a strip below it.
        bottom_v_padding = 0,
        close_callback = function() UIManager:close(self) end,
        show_parent = self,
    }
    local fixed_h = title_bar:getSize().h + self.buttons:getSize().h
                    + 2 * Size.border.window
    local avail_h = sh - 2 * Space.margin.default - fixed_h
    local body = build(self.width - 2 * pad)
    local body_block = FrameContainer:new{ bordersize = 0, padding = pad, body }
    if body_block:getSize().h > avail_h then
        -- A flush-right rail (lib/bookshelf_snug_scroll): its left rule runs
        -- the scroll area's height, and the title's rule, the border and the
        -- buttons' rule are its other edges.
        local sb = SnugScroll.scroll_bar_width
        body = build(self.width - 2 * pad - sb)
        self.cropping_widget = SnugScroll:new{
            dimen = Geom:new{ w = self.width, h = avail_h },
            show_parent = self,
            FrameContainer:new{ bordersize = 0, padding = pad, body },
        }
        body_block = self.cropping_widget
    end

    local frame = FrameContainer:new{
        radius = Space.radius.window,
        bordersize = Size.border.window,
        padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            title_bar,
            body_block,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = self.buttons:getSize().h },
                self.buttons,
            },
        },
    }
    self.frame = frame
    self.movable = MovableContainer:new{ frame }
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self[1] = CenterContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }, self.movable }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function Dialog:onTapOutside(_arg, ges)
    if self.frame.dimen and ges and ges.pos and not ges.pos:intersectWith(self.frame.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end

function Dialog:onClose()
    UIManager:close(self)
    return true
end

function Dialog:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    return true
end

function Dialog:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

function M.show(start, on_deleted)
    local d = Dialog:new{
        o = M.options(), hc = hardcoverLinked(), cal = calibreColumn(),
        start = start, on_deleted = on_deleted,
    }
    UIManager:show(d)
    return d
end

return M
