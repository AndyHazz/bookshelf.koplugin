-- bookshelf_author_images_flow.lua
-- The two ways a reader asks for author photos (lib/bookshelf_author_images
-- does the finding and saving):
--
--   findOne(bw, name) -- an author's long-press menu, "Find author image
--                        online". Replaces the author's image: the reader
--                        asked for this one.
--   findAll(bw)       -- Settings > Library & search, "Find author images
--                        online...". Every author with no image yet, after a
--                        confirm that says how many and where they come from.
--                        Never replaces an image the reader already has.
--
-- Both wait for Wi-Fi the KOReader way (runWhenOnline asks; nothing connects
-- by itself). findAll's pass shows its progress in the status line, with Stop
-- (see run); findOne's single lookup keeps Trapper's message. The shelf
-- repaints once at the end, not per author.

local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local T           = require("ffi/util").template
local _           = require("lib/bookshelf_i18n").gettext

local M = {}

-- Consecutive authors that could not reach either source before the bulk
-- pass gives up: a dropped connection should cost a few seconds, not one
-- timeout per author in the library.
M.MAX_UNREACHABLE = 3

local function _repaint(bw)
    local ImageSource = require("lib/bookshelf_image_source")
    ImageSource.invalidateCache()
    if bw and bw._rebuild then
        bw:_rebuild()
        UIManager:setDirty(bw, "ui")
    end
end

local function _failText(why, name)
    if why == "unreachable" then
        return _("Couldn't reach Open Library or Wikipedia.")
    elseif why == "no library" then
        return _("There is no image library to save into. Choose one under Settings > Library & search > Image library.")
    end
    return T(_("No photo found for %1."), name)
end

local function _online(fn)
    require("lib/bookshelf_cover_fetch").runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function() fn(Trapper) end)
    end)
end

function M.findOne(bw, name)
    if type(name) ~= "string" or name == "" then return end
    local AI = require("lib/bookshelf_author_images")
    _online(function(Trapper)
        Trapper:info(T(_("Looking for a photo of %1\xE2\x80\xA6"), name))
        local path, why = AI.fetch(name)
        Trapper:clear()
        if not path then
            UIManager:show(InfoMessage:new{ text = _failText(why, name) })
            return
        end
        -- An image chosen by hand outranks the library, so the new photo
        -- would not show while one is set. Asking for a photo is asking for
        -- it to be shown; the file that was chosen is left where it is.
        local ImageSource = require("lib/bookshelf_image_source")
        if ImageSource.getStackImageOverride("author", name) then
            ImageSource.clearStackImage("author", name)
        end
        _repaint(bw)
    end)
end

-- liveShelf(bw) -> the shelf showing now, for the progress line. The one the
-- pass started from may have been replaced (a book opened and closed); the
-- host's current one is found the way KOReader keeps it.
local function liveShelf(bw)
    for _i, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
        local ok, C = pcall(require, mod)
        local inst = ok and type(C) == "table" and C.instance
        local w = inst and inst.bookshelf and inst.bookshelf._widget
        if w and UIManager:isWidgetShown(w) then return w end
    end
    return bw
end

-- holdAwake(on): a pass over a few hundred authors runs for minutes, and the
-- device must not suspend in the middle of one (as Extract page counts holds
-- it, main.lua). The flag's earlier value comes back afterwards.
local _held_prev
local function holdAwake(on)
    local ok_ps, PluginShare = pcall(require, "pluginshare")
    if on and _held_prev == nil then
        _held_prev = (ok_ps and PluginShare.pause_auto_suspend) and true or false
        if ok_ps then PluginShare.pause_auto_suspend = true end
        pcall(function() UIManager:preventStandby() end)
    elseif not on and _held_prev ~= nil then
        if ok_ps then PluginShare.pause_auto_suspend = _held_prev end
        _held_prev = nil
        pcall(function() UIManager:allowStandby() end)
    end
end

-- run(bw, names) -- the bulk pass itself, once confirmed.
--
-- Progress goes in the shelf's status line with its Stop button, as Extract
-- page counts' does (lib/bookshelf_scan_progress): nothing covers the shelf,
-- and only Stop stops the pass. Each author is looked up in a forked child
-- (Trapper:dismissableRunInSubprocess), so the shelf keeps answering taps
-- through the seconds a lookup takes; the child saves the photo itself and
-- answers with one line.
function M.run(bw, names)
    local AI = require("lib/bookshelf_author_images")
    -- findAll hands over missing() already, which drops these; a caller that
    -- does not should not count "Anonymous" as an author without a photo.
    local real = {}
    for _i, n in ipairs(names or {}) do
        if not AI.isPlaceholder(n) then real[#real + 1] = n end
    end
    names = real
    if #names == 0 then return end
    local Progress = require("lib/bookshelf_scan_progress")
    if Progress.active() then
        UIManager:show(InfoMessage:new{
            text = _("Another job is running. Try again when it has finished."), timeout = 3 })
        return
    end
    require("lib/bookshelf_cover_fetch").runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local found, asked, unreachable_run = 0, 0, 0
            local stopped, offline = false, false
            local function title(i)
                return T(_("Finding author images: %1 of %2"), i, #names)
            end
            holdAwake(true)
            local job = Progress.begin{ title = title(1), shelf = function() return liveShelf(bw) end }
            local ok_run, err_run = xpcall(function()
                for i, name in ipairs(names) do
                    if job.stopped then stopped = true; break end
                    Progress.update{ title = title(i), fraction = (i - 1) / #names }
                    job.in_run = true
                    local completed, out = Trapper:dismissableRunInSubprocess(function()
                        local path, why = require("lib/bookshelf_author_images").fetch(name)
                        return (path and "found" or "missed") .. "\n" .. tostring(why or "")
                    end, job, true)
                    job.in_run = false
                    -- Stopped, or the fork could not start: the pass ends.
                    if not completed then stopped = true; break end
                    local what, why = tostring(out or ""):match("^(%a+)\n(.*)$")
                    asked = asked + 1
                    if what == "found" then found = found + 1 end
                    if why == "unreachable" then
                        unreachable_run = unreachable_run + 1
                        if unreachable_run >= M.MAX_UNREACHABLE then offline = true; break end
                    else
                        unreachable_run = 0
                    end
                    if why == "no library" then break end
                end
            end, debug.traceback)
            -- Whatever happened, the status line lets go of the job.
            Progress.finish()
            holdAwake(false)
            if not ok_run then
                require("logger").warn("[bookshelf] author images pass failed:", tostring(err_run))
            end
            if found > 0 then _repaint(bw) end
            local text = T(_("Found images for %1 of %2 authors."), found, asked)
            if offline then
                text = text .. "\n\n" .. _("Couldn't reach Open Library or Wikipedia.")
            elseif stopped and asked < #names then
                text = text .. "\n\n" .. T(_("Stopped before %1 more."), #names - asked)
            end
            UIManager:show(InfoMessage:new{ text = text })
        end)
    end)
end

function M.findAll(bw)
    local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
    local names = {}
    if ok and Repo and Repo.getGroupChoices then
        for _i, c in ipairs(Repo.getGroupChoices("author") or {}) do
            names[#names + 1] = c.value
        end
    end
    local todo = require("lib/bookshelf_author_images").missing(names)
    if #todo == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Every author on your shelves already has an image."),
            timeout = 3,
        })
        return
    end
    local ask = #todo == 1
        and T(_("Look for a photo of %1, the one author with no image yet?"), todo[1])
        or T(_("Look for photos of the %1 authors with no image yet?"), #todo)
    UIManager:show(ConfirmBox:new{
        text = ask .. "\n\n" .. _("Photos come from Open Library, or Wikipedia when it has none, and are saved in your image library. Images you already have are kept. Progress shows in the status line, with Stop."),
        ok_text = _("Find images"),
        ok_callback = function() M.run(bw, todo) end,
    })
end

return M
