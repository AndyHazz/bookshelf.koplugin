-- bookshelf_list_group.lua
-- How a FOLDER or a STACK renders in list mode, as opposed to a book.
--
-- ── WHY GROUPS ARE HARDCODED HERE ──────────────────────────────────────────
--
-- Every other part of the list model is the user's: how many lines, what is on
-- them, what they are set in. A group is the exception, on the maintainer's
-- ruling:
--
--     "Folders and stacks need to be presented differently to books, probably
--      something we'd hardcoded - let's start by just putting a chevron icon
--      in the cover column, the folder title, then 'x Books' on the second
--      row"
--
-- The reason it has to be an exception rather than a preference is that a
-- template written for books says nothing useful about a folder. "%authors ...
-- %book_pct of %page_count pages" against a folder is at best blank and at
-- worst a lie -- a folder has no author and no reading position. Under the
-- column model each column carried a second, group-shaped accessor to paper
-- over this; a template has no such thing, so the row substitutes its own
-- content instead.
--
-- What it does NOT substitute is the STYLE. Each hardcoded line borrows the
-- face, size, weight, case and alignment of the user's line in the same slot.
-- That is not politeness, it is a load-bearing invariant: the row-height budget
-- measures the user's lines, so a group row that set its own sizes would be a
-- different height from the book rows around it and the page would hold the
-- wrong number of items. Same styles in, same height out, by construction.
--
-- ── THE COUNT ──────────────────────────────────────────────────────────────
--
--     "the count should use the same settings that drive the numbers shown on
--      the badge in cover view mode ... just using the extra width available to
--      make it clear what the numbers are with text labels"
--
-- So this reads the same two settings the cover badge does and answers the same
-- question, in words rather than in the badge's compressed notation:
--
--     cover badge   list line
--     ×12           12 books
--     3/12          3 of 12 finished          (stack_count_badge_format)
--     3/12          3 of 12 selected          (selection, which outranks both)
--
-- Including the OFF case: stack_count_badge_mode decides whether folders,
-- groups, both or neither carry a count, and a user who turned the badge off
-- gets no count line either. That also keeps the cost honest -- a folder's
-- count needs a recursive walk, and nothing here pays for one unless the
-- setting asked for the number.

local Blitbuffer     = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom           = require("ui/geometry")
local CoverProgress  = require("lib/bookshelf_cover_progress")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local Repo           = require("lib/bookshelf_book_repository")
local _              = require("lib/bookshelf_i18n").gettext

local Group = {}

-- chevron-right, U+E841 in the bundled symbols face. PUA only: a non-PUA
-- codepoint has segfaulted this plugin before, and that face covers
-- U+E000..U+F8FF and nothing else (see bookshelf_cover_progress.lua's note on
-- GLYPH_DOWNLOADED).
Group.CHEVRON = "\u{e841}"

-- How much of the cover cell's height the chevron fills. Sized off the cell
-- rather than off the font so it stays proportional when the row's density
-- changes -- at list_font_scale 60 a fixed-size glyph would overflow the
-- thumbnail slot it is standing in for.
local CHEVRON_FILL = 0.55

-- ── The count ──────────────────────────────────────────────────────────────

-- Which kinds carry a count, from the same setting the cover badge reads.
-- Default "groups", matching bookshelf_shelf_row.lua's own resolution.
local function badgeKinds()
    local mode = BookshelfSettings.read("stack_count_badge_mode")
    if not (mode == "off" or mode == "folders" or mode == "groups"
         or mode == "all") then
        mode = "groups"
    end
    return (mode == "folders" or mode == "all"),   -- folders
           (mode == "groups"  or mode == "all")    -- every other group kind
end

-- The member filepaths of a group, or nil when it has none to offer.
-- A folder's are a recursive walk (cached by the repo); every other kind
-- carries its members inline.
local function memberPaths(item)
    if item.kind == "folder" then
        if not item.path then return nil end
        return Repo.getFolderBookPaths(item.path)
    end
    if item.books then
        local out = {}
        for i = 1, #item.books do out[i] = item.books[i].filepath end
        return out
    end
    return nil
end

local function countIn(paths, predicate)
    local n = 0
    for i = 1, #paths do
        local fp = paths[i]
        if fp and predicate(fp) then n = n + 1 end
    end
    return n
end

-- countText(item, selection) -> a labelled count, or nil.
--
-- nil rather than "" when there is nothing to say, so the caller can leave the
-- line's own template in place rather than blanking it.
function Group.countText(item, selection)
    local folders_on, groups_on = badgeKinds()
    local is_folder = item.kind == "folder"
    if is_folder and not folders_on then return nil end
    if not is_folder and not groups_on then return nil end

    local paths = memberPaths(item)
    if not paths or #paths == 0 then return nil end
    local total = #paths

    -- Selection wins, exactly as it does on the badge: while picking books the
    -- user wants to see how much of each stack they have got.
    local sel_active = selection and selection.isActive and selection:isActive()
    if sel_active then
        local k = countIn(paths, function(fp) return selection:contains(fp) end)
        if k > 0 then
            return string.format(_("%d of %d selected"), k, total)
        end
    end

    local format = BookshelfSettings.read("stack_count_badge_format")
    -- Finished is an OUT-of-selection format on the badge too: while a
    -- selection is live the user is being told about the selection instead.
    if format == "finished_total" and not sel_active then
        local f = countIn(paths, function(fp)
            local _pct, status = Repo.readProgress(fp)
            return status == "finished"
        end)
        return string.format(_("%d of %d finished"), f, total)
    end

    if total == 1 then return _("1 book") end
    return string.format(_("%d books"), total)
end

-- ── The cover cell ─────────────────────────────────────────────────────────

-- chevron(width, height) -> a widget filling that cell with a right chevron.
--
-- Stands in for the cover thumbnail. A folder's first book WOULD give a real
-- cover here (that is what the cover grid's stack tiles show), and at 30x45 in
-- a table that is exactly the problem: one arbitrary member's artwork, at a
-- size too small to recognise, is indistinguishable from a book row. The point
-- of the chevron is that it is NOT a cover -- it says "this opens into
-- something" at a glance, which is the one thing a list needs the cell for.
function Group.chevron(width, height)
    local size = math.max(8, math.floor(height * CHEVRON_FILL))
    local glyph = CoverProgress.buildGlyphWidget(
        Group.CHEVRON, size, Blitbuffer.COLOR_BLACK)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        glyph,
    }
end

-- ── The lines ──────────────────────────────────────────────────────────────

-- templates(item, selection, n_lines) -> array of template strings, or nil
-- when `item` is not a group.
--
-- One entry per line the row will draw, so the caller can index it directly.
-- Line 1 is the group's name (through %title, which Lines.groupRecord maps to
-- whichever field this kind of group keeps its name in). Line 2 is the count.
-- Anything below is empty -- a group has nothing else to say, and repeating the
-- name or the count to fill the space would be noise.
--
-- With only ONE line configured the count has nowhere to go and is dropped;
-- the name wins, because a row that says "12 books" without saying which
-- folder is useless.
function Group.templates(item, selection, n_lines)
    local out = {}
    for i = 1, n_lines do out[i] = "" end
    out[1] = "%title"
    if n_lines >= 2 then
        out[2] = Group.countText(item, selection) or ""
    end
    return out
end

return Group
