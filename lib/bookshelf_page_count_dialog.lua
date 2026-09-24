-- bookshelf_page_count_dialog.lua
-- The dialog in front of "Extract page counts": what the scan does, which
-- sources it may use, whether to fill only the missing counts or recount
-- every book, and a way to delete what earlier scans found.
--
-- Before it, the menu row started the scan straight away and asked one
-- question halfway through ("Paginate them the slow way?"), after the fast
-- passes had already run. The choices now come first and are remembered.
--
-- The dialog redraws in place (every button has an id; a tap rewrites the
-- labels through getButtonById/setText and repaints only the dialog), the
-- same as the chip editor's face-out picker: a ButtonDialog that closes and
-- reopens per tap flashes the whole screen.

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox   = require("ui/widget/confirmbox")
local InfoMessage  = require("ui/widget/infomessage")
local UIManager    = require("ui/uimanager")
local Settings     = require("lib/bookshelf_settings_store")
local T            = require("ffi/util").template
local _            = require("lib/bookshelf_i18n").gettext

local M = {}

M.SETTING = "page_count_scan"   -- { publisher=, hardcover=, render=, recount= }

local TICK, BLANK = "\xE2\x9C\x93 ", "\xE2\x80\x83 "

-- options() -> the remembered choices, every source on by default.
function M.options()
    local saved = Settings.read(M.SETTING)
    local o = { publisher = true, hardcover = true, render = true, recount = false }
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

-- anySource(o, hc) -> whether the scan would have anything to use.
function M.anySource(o, hc)
    return o.publisher or (hc and o.hardcover) or o.render
end

-- deleteScanned(on_done): ask, then clear every count earlier scans stored.
-- Counts KOReader keeps for books that have been opened are not touched, and
-- neither is a p(N) in a file name.
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
function M.show(start, on_deleted)
    local o  = M.options()
    local hc = hardcoverLinked()
    local d

    local function sourceLabel(key)
        local text
        if key == "publisher" then
            text = _("Publisher page numbers in the book (fast)")
        elseif key == "hardcover" then
            text = hc and _("Hardcover editions of linked books (fast)")
                      or _("Hardcover editions (no linked books)")
        else
            text = _("Count at your reading settings (slow)")
        end
        local on = o[key] and (key ~= "hardcover" or hc)
        return (on and TICK or BLANK) .. text
    end
    local function modeLabel(recount)
        local text = recount and _("Recount every book") or _("Only books without a count")
        return ((o.recount == recount) and TICK or BLANK) .. text
    end
    local function save() Settings.save(M.SETTING, o) end

    local function refresh()
        if not d then return end
        local function set(id, text)
            local btn = d:getButtonById(id)
            if btn and text then btn:setText(text, btn.width) end
            return btn
        end
        set("publisher", sourceLabel("publisher"))
        set("hardcover", sourceLabel("hardcover"))
        set("render", sourceLabel("render"))
        set("missing", modeLabel(false))
        set("recount", modeLabel(true))
        local go = set("start")
        if go then
            if M.anySource(o, hc) then go:enable() else go:disable() end
        end
        UIManager:setDirty(d, function() return "ui", d.movable.dimen end)
    end
    local function toggle(key)
        return {
            id = key, text = sourceLabel(key), align = "left",
            enabled = key ~= "hardcover" or hc,
            callback = function() o[key] = not o[key]; save(); refresh() end,
        }
    end
    local function mode(recount)
        return {
            id = recount and "recount" or "missing", text = modeLabel(recount), align = "left",
            callback = function() o.recount = recount; save(); refresh() end,
        }
    end

    d = ButtonDialog:new{
        title = _("Extract page counts") .. "\n\n"
            .. _("Finds page counts for spine thickness, page count badges, sorting and tokens. A page count in a file name, like p(320), is always used as it is.")
            .. "\n\n" .. _("Where counts may come from:"),
        title_align = "left",
        buttons = {
            { toggle("publisher") },
            { toggle("hardcover") },
            { toggle("render") },
            { mode(false) },
            { mode(true) },
            {{
                text = _("Delete scanned page counts\xe2\x80\xa6"),
                callback = function()
                    UIManager:close(d)
                    M.deleteScanned(on_deleted)
                end,
            }},
            {
                { text = _("Cancel"), callback = function() UIManager:close(d) end },
                {
                    id = "start", text = _("Start"),
                    enabled = M.anySource(o, hc),
                    callback = function()
                        UIManager:close(d)
                        local opts = {}
                        for k, v in pairs(o) do opts[k] = v end
                        opts.hardcover = opts.hardcover and hc
                        start(opts)
                    end,
                },
            },
        },
    }
    UIManager:show(d)
    return d
end

return M
