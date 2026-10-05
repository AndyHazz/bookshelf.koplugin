-- lib/bookshelf_genre_manage.lua
-- Genre-management actions for a genre shelf's long-press menu: block the
-- genre, rename / merge it, or hide it on chosen books. All of them change the
-- Hardcover cleanup rules (lib/bookshelf_genre_filter), so they only affect
-- books that get the genre from Hardcover -- a book's own embedded / Calibre
-- tags are left alone.

local GenreManage = {}

-- Pure: the paths whose Hardcover candidates include `name` (any case).
-- candidates(fp) -> list of the tags Hardcover could show for that book.
function GenreManage.carriers(paths, name, candidates)
    local key = tostring(name or ""):lower()
    local out = {}
    for _i, fp in ipairs(paths or {}) do
        for _j, t in ipairs(candidates(fp) or {}) do
            if t:lower() == key then out[#out + 1] = fp; break end
        end
    end
    return out
end

local function candidatesFn()
    local BulkGenres = require("lib/bookshelf_bulk_genres")
    return BulkGenres.hardcoverCandidates(BulkGenres.cleanupRules())
end

-- Rules changed: drop the caches the genre shelves are built from and redraw.
local function refresh(bw)
    local Repo = require("lib/bookshelf_book_repository")
    local UIManager = require("ui/uimanager")
    Repo.invalidateBookCache("genre-rules")
    if Repo.invalidateLightMeta then Repo.invalidateLightMeta() end
    bw:_rebuild()
    UIManager:setDirty(bw, "ui")
end

-- Add the genre to the global blocklist, after saying how many of this shelf's
-- books it will leave.
function GenreManage.neverUse(bw, name, paths)
    local _ = require("lib/bookshelf_i18n").gettext
    local T = require("ffi/util").template
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local n = #GenreManage.carriers(paths, name, candidatesFn())
    local text
    if n > 0 then
        text = T(_("Never use \"%1\" as a Hardcover genre?\n\n%2 of the %3 books here get it from Hardcover and will lose it. Their own embedded and Calibre genres are not touched."),
            name, tostring(n), tostring(#paths))
    else
        text = T(_("Never use \"%1\" as a Hardcover genre?\n\nNone of the books here get it from Hardcover, so this shelf will not change: it comes from the books' own tags. It will be blocked on other books."),
            name)
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Block"),
        ok_callback = function()
            if require("lib/bookshelf_genre_filter").addBlocked(name) then refresh(bw) end
        end,
    })
end

-- Rename the genre everywhere; naming it after another genre merges the two.
function GenreManage.rename(bw, name)
    local _ = require("lib/bookshelf_i18n").gettext
    local T = require("ffi/util").template
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local idlg
    idlg = InputDialog:new{
        title = T(_("Replace \"%1\" with"), name), input = name,
        input_hint = _("New name (empty hides it)"),
        description = _("Applies to every book Hardcover tags with this genre. Type the name of another genre to merge the two shelves."),
        buttons = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(idlg) end },
            { text = _("Save"), is_enter_default = true,
              callback = function()
                local to = (idlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(idlg)
                if to:lower() == name:lower() then return end
                if require("lib/bookshelf_genre_filter").renameShown(name, to) then refresh(bw) end
              end },
        }},
    }
    UIManager:show(idlg)
    idlg:onShowKeyboard()
end

-- Pick books from this shelf and hide the genre on them. Offers only the
-- books that get the genre from Hardcover; the rest cannot be changed here.
function GenreManage.hideOnSome(bw, name, paths)
    local _ = require("lib/bookshelf_i18n").gettext
    local T = require("ffi/util").template
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local Repo = require("lib/bookshelf_book_repository")
    local InfoMessage = require("ui/widget/infomessage")
    local candidates = candidatesFn()
    local offered = GenreManage.carriers(paths, name, candidates)
    if #offered == 0 then
        UIManager:show(InfoMessage:new{ text = T(_("None of these books get \"%1\" from Hardcover, so there is nothing to hide here. It comes from the books' own tags."), name) })
        return
    end
    local items = {}
    for _i, fp in ipairs(offered) do
        local lm = Repo.lightMetaFor(fp)
        local author = lm and lm.authors
        if type(author) == "table" then author = table.concat(author, ", ") end
        items[#items + 1] = {
            value = fp,
            label = (lm and lm.title) or (fp:match("([^/]+)$") or fp),
            subtitle = author,
        }
    end
    table.sort(items, function(a, b) return a.label:lower() < b.label:lower() end)

    local sel, count = {}, 0
    local modal
    local function setAll(on)
        sel, count = {}, 0
        if on then for _i, it in ipairs(items) do sel[it.value] = true; count = count + 1 end end
    end
    local function commit()
        local picked = {}
        for _i, it in ipairs(items) do if sel[it.value] then picked[#picked + 1] = it.value end end
        UIManager:close(modal)
        if #picked == 0 then return end
        local BulkGenres = require("lib/bookshelf_bulk_genres")
        local GF = require("lib/bookshelf_genre_filter")
        local updates = BulkGenres.hideUpdates(picked, { hide = { [name:lower()] = name } },
            candidates, GF.excludedFor)
        if next(updates) and pcall(GF.setExcludedMany, updates) then refresh(bw) end
    end
    modal = require("lib/bookshelf_library_modal"):new{ config = {
        title = T(_("Hide \"%1\" on…"), name),
        no_search = true,
        grid_cols = 1,
        cells_per_page = function()
            return Screen:getWidth() > Screen:getHeight() and 5 or 8
        end,
        item_count = function() return #items end,
        item_at = function(idx) return items[idx] end,
        cell_renderer = function(item, dimen)
            return require("lib/bookshelf_picker_cell").render(item, dimen,
                { selected = sel[item.value] == true })
        end,
        on_cell_tap = function(item)
            if sel[item.value] then sel[item.value] = nil; count = count - 1
            else sel[item.value] = true; count = count + 1 end
            if modal then modal:refresh() end
        end,
        footer_rows = {
            { { label_func = function()
                    return (count == #items) and _("Select none") or _("Select all")
                end,
                on_tap = function()
                    setAll(count ~= #items)
                    if modal then modal:refresh() end
                end } },
            {
                { label = _("Cancel"), on_tap = function() UIManager:close(modal) end },
                { label_func = function() return T(_("Hide on %1"), tostring(count)) end,
                  primary = true, on_tap = commit },
            },
        },
    } }
    UIManager:show(modal)
end

return GenreManage
