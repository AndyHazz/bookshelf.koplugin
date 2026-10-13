-- Maps AO3's common summary tags to the supplied symbols and builds the
-- compact four-icon panel used in list rows and the top panel.
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local ImageSource = require("lib/bookshelf_image_source")

local AO3 = {}

local root = (debug.getinfo(1, "S").source:match("^@(.*)/lib/[^/]+$")
              or ".") .. "/assets/ao3/"

local RATING = {
    ["general audiences"] = "rating-general-audience",
    ["teen and up audiences"] = "rating-teen",
    ["mature"] = "rating-mature",
    ["explicit"] = "rating-explicit",
    ["not rated"] = "rating-notrated",
}

local CATEGORY = {
    ["f/m"] = "category-het",
    ["m/f"] = "category-het",
    ["het"] = "category-het",
    ["m/m"] = "category-slash",
    ["slash"] = "category-slash",
    ["f/f"] = "category-femslash",
    ["femslash"] = "category-femslash",
    ["gen"] = "category-gen",
    ["multi"] = "category-multi",
    ["other"] = "category-other",
    ["none"] = "category-none",
}

local function normalize(value)
    if type(value) ~= "string" then return nil end
    local normalized = value:lower():match("^%s*(.-)%s*$")
    normalized = normalized:gsub("^archive warnings?:%s*", "")
    normalized = normalized:gsub("^warnings?:%s*", "")
    normalized = normalized:gsub("^rating:%s*", "")
    normalized = normalized:gsub("^category:%s*", "")
    normalized = normalized:gsub("^complete:%s*", "")
    normalized = normalized:gsub("^completion status:%s*", "")
    normalized = normalized:gsub("^status:%s*", "")
    return normalized
end

local COMPLETE_YES = {
    ["yes"] = true, ["complete"] = true, ["completed"] = true,
    ["complete work"] = true, ["finished"] = true,
}
local COMPLETE_NO = {
    ["no"] = true, ["in progress"] = true, ["in-progress"] = true,
    ["incomplete"] = true, ["work in progress"] = true, ["wip"] = true,
    ["ongoing"] = true, ["hiatus"] = true, ["abandoned"] = true,
}

-- AO3 and FanFicFare exports write "Chapters: 5/5" (done) or "5/?" (not done)
-- into the description when no status tag survives.
local function completionFromText(book)
    local text = type(book) == "table" and book.description
    if type(text) ~= "string" then return nil end
    local have, total = text:match("Chapters:%s*(%d+)%s*/%s*([%d%?]+)")
    if not have then
        if text:match("Status:%s*Completed") then return "complete-yes" end
        if text:match("Status:%s*In%-Progress") then return "complete-no" end
        return nil
    end
    if total == "?" or tonumber(have) ~= tonumber(total) then
        return "complete-no"
    end
    return "complete-yes"
end

-- AO3 EPUB downloads keep "Chapters: 1/1" only inside the preface page, so it
-- is read once from the zip and remembered ("yes"/"no"/"none" per file).
local status_store
local function statusStore()
    if status_store == nil then
        local ok, store = pcall(function()
            local DataStorage = require("datastorage")
            local LuaSettings = require("luasettings")
            return LuaSettings:open(
                DataStorage:getSettingsDir() .. "/bookshelf_ao3_status.lua")
        end)
        status_store = ok and store or false
    end
    return status_store
end

local function scanEpubStatus(filepath)
    local ok, result = pcall(function()
        local Archiver = require("ffi/archiver")
        local rd = Archiver.Reader:new()
        if not rd:open(filepath) then return "none" end
        local names = {}
        for entry in rd:iterate() do
            local path = entry.path
            if path and path:lower():match("%.x?html?$") then
                names[#names + 1] = path
            end
        end
        table.sort(names)
        local verdict = "none"
        for i = 1, math.min(#names, 4) do
            local page = rd:extractToMemory(names[i])
            local have, total
            if page then
                have, total = page:match("Chapters:%s*(%d+)%s*/%s*([%d%?]+)")
            end
            if have then
                verdict = (total ~= "?" and tonumber(have) == tonumber(total))
                    and "yes" or "no"
                break
            end
        end
        pcall(function() rd:close() end)
        return verdict
    end)
    return ok and result or "none"
end

local function completionFromFile(book)
    local path = type(book) == "table" and book.filepath
    if type(path) ~= "string" or not path:lower():match("%.epub$") then
        return nil
    end
    local store = statusStore()
    local cached = store and store:readSetting(path)
    if cached == nil then
        cached = scanEpubStatus(path)
        if store then
            store:saveSetting(path, cached)
            pcall(function() store:flush() end)
        end
    end
    if cached == "yes" then return "complete-yes" end
    if cached == "no" then return "complete-no" end
    return nil
end

-- iconsFor(book) -> { rating=, warning=, category=, complete= }, any of which
-- may be absent. Reads book.genres (BIM/Calibre tags), each matched case-
-- insensitively against AO3's own vocabulary; completion falls back to
-- "Chapters: N/M" in the description, then to a cached scan of the EPUB
-- itself (completionFromFile) when neither tags nor description carry it.
function AO3.iconsFor(book)
    local found = {}
    local tags = type(book) == "table" and book.genres
    if type(tags) ~= "table" then
        found.complete = completionFromText(book) or completionFromFile(book)
        return found
    end

    local warning_yes, warning_external, warning_no, warning_choose_not_to
    for _, tag in ipairs(tags) do
        local value = normalize(tag)
        if value then
            found.rating = found.rating or RATING[value]
            found.category = found.category or CATEGORY[value]
            if value == "no archive warnings apply" then
                warning_no = true
            elseif value == "creator chose not to use archive warnings"
                    or value == "choose not to use archive warnings" then
                warning_choose_not_to = true
            elseif value == "external work" then
                warning_external = true
            elseif value == "graphic depictions of violence"
                    or value == "major character death"
                    or value == "rape/non-con"
                    or value == "underage" then
                warning_yes = true
            end
            local done_tag = value:match("^complete work:%s*(.+)$") or value
            if COMPLETE_YES[done_tag] or (done_tag:find("complete", 1, true)
                    and not done_tag:find("incomplete", 1, true)
                    and not done_tag:find("not complete", 1, true)) then
                found.complete = "complete-yes"
            elseif COMPLETE_NO[done_tag] or done_tag:find("in progress", 1, true)
                    or done_tag:find("incomplete", 1, true)
                    or done_tag:find("not complete", 1, true) then
                if found.complete ~= "complete-yes" then
                    found.complete = "complete-no"
                end
            end
        end
    end
    if not found.complete then
        found.complete = completionFromText(book) or completionFromFile(book)
    end
    if warning_yes then
        found.warning = "warning-yes"
    elseif warning_choose_not_to then
        found.warning = "warning-choosenotto"
    elseif warning_no then
        found.warning = "warning-no"
    elseif warning_external then
        found.warning = "warning-external-work"
    end
    return found
end

local function iconCell(name, side, border)
    local icon_side = side - 2 * border
    local bb = name and ImageSource.loadImage(
        root .. name .. ".png", icon_side, icon_side)
    local content = bb and ImageWidget:new{ image = bb, image_disposable = false }
        or Widget:new{ dimen = Geom:new{ w = icon_side, h = icon_side } }
    return FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.COLOR_LIGHT_GRAY,
        padding = 0,
        margin = 0,
        content,
    }
end

-- newWidget(book, width, height) -> the 2x2 icon grid, centred in a
-- width x height box, or a bare spacer Widget when the book has no matching
-- tags / the box is too small to hold even one icon. Each cell is capped at
-- a native 25dp (the source PNGs are 25x25 themselves) so it stays crisp at
-- any box size; a box bigger than the grid needs just centres it, leaving
-- margin rather than upscaling the bitmaps past their own resolution.
function AO3.newWidget(book, width, height)
    if type(width) ~= "number" or type(height) ~= "number"
            or width < 1 or height < 1 then
        return nil
    end
    local icons = AO3.iconsFor(book)
    if not next(icons) then
        return Widget:new{ dimen = Geom:new{ w = width, h = height } }
    end
    local border = Size.border.thin
    local gap = math.max(2, Screen:scaleBySize(2))
    local side = math.min(
        math.floor(width / 2), math.floor(height / 2),
        Screen:scaleBySize(25) + 2 * border)
    side = math.floor(math.min(side, (math.min(width, height) - gap) / 2))
    if side <= 2 * border then
        return Widget:new{ dimen = Geom:new{ w = width, h = height } }
    end
    local top = HorizontalGroup:new{ align = "center" }
    top[#top + 1] = iconCell(icons.rating, side, border)
    top[#top + 1] = HorizontalSpan:new{ width = gap }
    top[#top + 1] = iconCell(icons.warning, side, border)
    local bottom = HorizontalGroup:new{ align = "center" }
    bottom[#bottom + 1] = iconCell(icons.category, side, border)
    bottom[#bottom + 1] = HorizontalSpan:new{ width = gap }
    bottom[#bottom + 1] = iconCell(icons.complete, side, border)
    local grid = VerticalGroup:new{
        align = "center", top, VerticalSpan:new{ width = gap }, bottom }
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        grid,
    }
end

-- footprintSize() -> w, h: the exact pixel footprint the 2x2 grid occupies
-- at its NATIVE resolution (two 25dp cells plus the gap between them, each
-- way). A caller that wants to reserve just enough box for the grid itself,
-- rather than hand it a bigger box and let newWidget centre the grid inside
-- the slack -- the top panel's own cover slot is cover-sized, not
-- thumbnail-sized, and centring a small grid in it just left the grid
-- looking lost -- reserves this exact span instead of duplicating the
-- cell/gap formula.
function AO3.footprintSize()
    local border = Size.border.thin
    local gap = math.max(2, Screen:scaleBySize(2))
    local side = Screen:scaleBySize(25) + 2 * border
    local span = 2 * side + gap
    return span, span
end

-- heroSlotSize() -> slot_w, slot_h: footprintSize() plus a small margin for
-- breathing room, same idea as a cover's own drop-shadow reservation. A
-- second caller that needs to know how much width this slot choice leaves
-- behind for the text column uses this rather than duplicating the margin
-- constant alongside footprintSize().
function AO3.heroSlotSize()
    local fw, fh = AO3.footprintSize()
    local margin = Screen:scaleBySize(8)
    return fw + margin, fh + margin
end

-- newCornerWidget(book, max_w, max_h, top_offset) -> the SAME grid as
-- newWidget, at the SAME native resolution, anchored to the TOP-LEFT of a
-- max_w x max_h box instead of centred in it -- for a caller (the top
-- panel) that has shrunk the box to just bigger than footprintSize() and
-- wants the badges to read as a small marker in its corner. nil, same as
-- newWidget, when the book has no matching tags; unlike newWidget it
-- returns nil rather than a spacer when the box genuinely cannot hold even
-- one icon, since a caller positioning its own box has no use for an empty
-- placeholder the size of that box.
--
-- `top_offset` (optional) pushes the grid down from the box's top edge, so
-- it can be lined up with whatever sits below the first tier of a caller's
-- own layout rather than always sitting flush at the very top. Clamped so
-- the grid can never be pushed below the box's own bottom edge.
function AO3.newCornerWidget(book, max_w, max_h, top_offset)
    if type(max_w) ~= "number" or type(max_h) ~= "number"
            or max_w < 1 or max_h < 1 then
        return nil
    end
    local icons = AO3.iconsFor(book)
    if not next(icons) then return nil end
    local border = Size.border.thin
    local gap = math.max(2, Screen:scaleBySize(2))
    -- The same floor newWidget applies: native size, shrunk only if max_w /
    -- max_h genuinely cannot hold it.
    local side = math.min(
        math.floor(max_w / 2), math.floor(max_h / 2),
        Screen:scaleBySize(25) + 2 * border)
    side = math.floor(math.min(side, (math.min(max_w, max_h) - gap) / 2))
    if side <= 2 * border then return nil end
    local top = HorizontalGroup:new{ align = "center" }
    top[#top + 1] = iconCell(icons.rating, side, border)
    top[#top + 1] = HorizontalSpan:new{ width = gap }
    top[#top + 1] = iconCell(icons.warning, side, border)
    local bottom = HorizontalGroup:new{ align = "center" }
    bottom[#bottom + 1] = iconCell(icons.category, side, border)
    bottom[#bottom + 1] = HorizontalSpan:new{ width = gap }
    bottom[#bottom + 1] = iconCell(icons.complete, side, border)
    local grid = VerticalGroup:new{
        align = "center", top, VerticalSpan:new{ width = gap }, bottom }
    local grid_h = 2 * side + gap
    local offset = (type(top_offset) == "number" and top_offset > 0)
        and math.min(top_offset, math.max(0, max_h - grid_h)) or 0
    local inner = grid
    if offset > 0 then
        inner = VerticalGroup:new{
            align = "left", VerticalSpan:new{ width = offset }, grid }
    end
    -- Nested, not one combined container: TopContainer alone would centre
    -- the grid horizontally within max_w, and LeftContainer alone would
    -- centre it vertically within max_h. The inner LeftContainer's own box
    -- is max_w wide (so left-alignment has the full width to work against)
    -- but only offset+grid_h tall (so the OUTER TopContainer, which sees a
    -- child that tall, pushes it flush to the top rather than centring gap
    -- above it) -- with offset folded into that same height, the grid ends
    -- up offset pixels below the box's top rather than flush against it.
    return TopContainer:new{
        dimen = Geom:new{ w = max_w, h = max_h },
        LeftContainer:new{
            dimen = Geom:new{ w = max_w, h = offset + grid_h },
            inner,
        },
    }
end

-- listBadgesEnabled() / heroBadgesEnabled() -> the two settings
-- (menu > Settings > List view) that gate each surface independently: a
-- reader can have list-row badges on and top-panel badges off, or either
-- alone, or both. Both default OFF -- a fresh install shows nothing new
-- until a reader opts in, same as the stock plain placeholder everywhere
-- a cover would otherwise be missing.
function AO3.listBadgesEnabled()
    local ok, Store = pcall(require, "lib/bookshelf_settings_store")
    return (ok and Store.isTrue("list_ao3_badges")) or false
end

function AO3.heroBadgesEnabled()
    local ok, Store = pcall(require, "lib/bookshelf_settings_store")
    return (ok and Store.isTrue("hero_ao3_badges")) or false
end

-- heroUsesCorner(book) -> true when the top panel should show the small
-- top-left AO3 marker for this book instead of its own cover art:
-- heroBadgesEnabled() is on, the book has no cover, and it has at least one
-- matching tag. Exposed so a caller OTHER than the top panel itself --
-- bookshelf_widget.lua, sizing the tags pill strip to the width the text
-- column will actually have -- can ask the same question and never
-- disagree with the top panel about which books get the small slot.
function AO3.heroUsesCorner(book)
    if type(book) ~= "table" or book.has_cover then return false end
    if not AO3.heroBadgesEnabled() then return false end
    return next(AO3.iconsFor(book)) ~= nil
end

return AO3
