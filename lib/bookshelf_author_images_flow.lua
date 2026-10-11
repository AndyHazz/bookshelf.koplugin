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
-- by itself) and run under Trapper so the progress message can be tapped to
-- stop. The shelf repaints once at the end, not per author.

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

-- run(bw, names) -- the bulk pass itself, once confirmed.
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
    _online(function(Trapper)
        local found, asked, unreachable_run = 0, 0, 0
        local stopped, offline = false, false
        for i, name in ipairs(names) do
            -- fast_refresh: the message is only rewritten in place, so a long
            -- library is not a full-screen refresh per author.
            if not Trapper:info(T(_("Finding author images: %1 of %2\n%3"),
                    i, #names, name), i > 1) then
                stopped = true
                break
            end
            local path, why = AI.fetch(name)
            asked = asked + 1
            if path then found = found + 1 end
            if why == "unreachable" then
                unreachable_run = unreachable_run + 1
                if unreachable_run >= M.MAX_UNREACHABLE then offline = true; break end
            else
                unreachable_run = 0
            end
            if why == "no library" then break end
        end
        Trapper:clear()
        if found > 0 then _repaint(bw) end
        local text = T(_("Found images for %1 of %2 authors."), found, asked)
        if offline then
            text = text .. "\n\n" .. _("Couldn't reach Open Library or Wikipedia.")
        elseif stopped and asked < #names then
            text = text .. "\n\n" .. T(_("Stopped before %1 more."), #names - asked)
        end
        UIManager:show(InfoMessage:new{ text = text })
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
        text = ask .. "\n\n" .. _("Photos come from Open Library, or Wikipedia when it has none, and are saved in your image library. Images you already have are kept. Tap the progress message to stop."),
        ok_text = _("Find images"),
        ok_callback = function() M.run(bw, todo) end,
    })
end

return M
