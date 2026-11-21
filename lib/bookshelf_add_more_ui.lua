-- lib/bookshelf_add_more_ui.lua
-- "Add more to a shelf": from one book, the whole series, everything by its
-- author, or the rest of its folder, in reading order, onto a shelf.
--
-- The ways (lib/bookshelf_add_more) are listed with how many books each adds.
-- A long list asks first; then the books go to the same chooser as any other
-- add (lib/bookshelf_curated_ui.pick), which says which shelf, and where on
-- it (first or last place).

local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local UI = {}

local function Curated() return require("lib/bookshelf_curated_ui") end

-- What each way is called in the list.
local function title(way)
    if way.kind == "series" then return T(_("The series %1"), way.name) end
    if way.kind == "author" then return T(_("All by %1"), way.name) end
    return T(_("The folder %1"), way.name)
end

-- dirname without the plugin's other path helpers: "/a/b/c.epub" -> "/a/b".
local function dirname(path)
    return (tostring(path):gsub("/[^/]*$", ""))
end

-- ways(book) -> the ways, read from the repository's cached groups.
function UI.ways(book)
    local Repo = require("lib/bookshelf_book_repository")
    local folder = book.filepath and dirname(book.filepath) or nil
    return require("lib/bookshelf_add_more").ways(book, {
        series = Repo.getGroupFilepaths("series"),
        author = Repo.getGroupFilepaths("author"),
        folder = folder and Repo.getFolderBookPaths(folder) or nil,
        folder_name = folder and (folder:match("([^/]+)$") or folder) or nil,
    })
end

-- open{ book, after_id, view_mode, on_done }: the list of ways; a tap picks one.
function UI.open(opts)
    local book = opts.book
    local UIManager = require("ui/uimanager")
    local AddMore = require("lib/bookshelf_add_more")
    local ways = UI.ways(book)
    if #ways == 0 then
        UIManager:show(require("ui/widget/notification"):new{ text = _("No more books to add") })
        return
    end
    local dialog
    local function choose(way)
        if dialog then dialog:_dismiss() end
        local function pick()
            Curated().pick{ paths = way.paths, after_id = opts.after_id, view_mode = opts.view_mode,
                on_done = opts.on_done }
        end
        if #way.paths > AddMore.CONFIRM_ABOVE then
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = T(_("Add %1 books to a shelf?"), #way.paths),
                ok_text = T(_("Choose a shelf for %1"), #way.paths),
                ok_callback = pick,
            })
        else
            pick()
        end
    end
    dialog = require("lib/bookshelf_page_dialog").show{
        title = _("Add more to a shelf"),
        page = function()
            local blocks = {}
            for _i, way in ipairs(ways) do
                blocks[#blocks + 1] = { type = "option", text = title(way), icon = Curated().ICON_SHELF,
                    desc = T(_("%1 books, in reading order"), #way.paths),
                    callback = function() choose(way) end }
            end
            return { blocks = blocks }
        end,
    }
    return dialog
end

return UI
