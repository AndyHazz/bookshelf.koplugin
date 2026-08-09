-- lib/bookshelf_opds_catalog_editor.lua
-- The Add / Edit OPDS catalogue dialog and the delete confirmation. Built to
-- match the stock opds.koplugin editor exactly (MultiInputDialog with four
-- fields plus "Use server filenames" and "Sync catalog" checkbuttons), so the
-- experience is identical whether or not the stock plugin is installed.

local UIManager       = require("ui/uimanager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local CheckButton     = require("ui/widget/checkbutton")
local ConfirmBox      = require("ui/widget/confirmbox")
local Notification    = require("ui/widget/notification")
local Catalogs        = require("lib/bookshelf_opds_catalogs")
local OpdsSource      = require("lib/bookshelf_opds_source")
local _              = require("gettext")
local T              = require("ffi/util").template

local M = {}

local ERR_TEXT = {
    title_required = function() return _("Catalog name is required.") end,
    url_required   = function() return _("Catalog URL is required.") end,
    duplicate_url  = function() return _("A catalog with this URL already exists.") end,
    not_found      = function() return _("That catalog no longer exists.") end,
}

function M.show(opts)
    opts = opts or {}
    local item = opts.item
    local editing = item ~= nil
    local dialog, cb_raw, cb_sync

    local fields = {
        { hint = _("Catalog name"),        text = editing and item.title or nil },
        { hint = _("Catalog URL"),         text = editing and item.url or nil },
        { hint = _("Username (optional)"), text = editing and item.username or nil },
        { hint = _("Password (optional)"), text = editing and item.password or nil,
          text_type = "password" },
    }

    dialog = MultiInputDialog:new{
        title  = editing and _("Edit OPDS catalog") or _("Add OPDS catalog"),
        fields = fields,
        buttons = {
            {
                { text = _("Cancel"), id = "close",
                  callback = function()
                      UIManager:close(dialog)
                      if opts.on_cancel then opts.on_cancel() end
                  end },
                { text = _("Save"), callback = function()
                    local f = dialog:getFields()
                    local input = {
                        title = f[1], url = f[2], username = f[3], password = f[4],
                        raw_names = cb_raw.checked or nil,
                        sync      = cb_sync.checked or nil,
                    }
                    local ok, err
                    if editing then
                        ok, err = Catalogs.edit(item.url, input)
                    else
                        ok, err = Catalogs.add(input)
                    end
                    if ok then
                        UIManager:close(dialog)
                        if opts.on_saved then opts.on_saved() end
                    else
                        local msg = ERR_TEXT[err] and ERR_TEXT[err]() or _("Could not save catalog.")
                        UIManager:show(Notification:new{ text = msg })
                    end
                end },
            },
        },
    }
    cb_raw = CheckButton:new{
        text = _("Use server filenames"),
        checked = editing and item.raw_names or false,
        parent = dialog,
    }
    cb_sync = CheckButton:new{
        text = _("Sync catalog"),
        checked = editing and item.sync or false,
        parent = dialog,
    }
    dialog:addWidget(cb_raw)
    dialog:addWidget(cb_sync)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M.confirmDelete(opts)
    opts = opts or {}
    local item = opts.item
    if not item then
        if opts.on_cancel then opts.on_cancel() end
        return
    end
    local n = Catalogs.chipsUsing(OpdsSource.serverKey(item.url))
    local text = (n > 0)
        and T(_("Delete \"%1\"? %2 chip(s) use this catalog and will stop working."),
              item.title or item.url, n)
        or  T(_("Delete \"%1\"?"), item.title or item.url)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Delete"),
        ok_callback = function()
            Catalogs.delete(item.url)
            if opts.on_deleted then opts.on_deleted() end
        end,
        cancel_callback = function()
            if opts.on_cancel then opts.on_cancel() end
        end,
    })
end

return M
