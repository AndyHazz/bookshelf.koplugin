-- lib/bookshelf_cover_marks.lua
-- Which cover marks show on which kind of shelf (issue 597).
--
-- A mark is one of the things drawn on or over a book: the progress bar, the
-- reading bookmark, the page badge and so on. Each has two switches, one for
-- covers (the grid, and every other place a cover is drawn) and one for spine
-- shelves (a face-out cover there, and the small glyph a narrow spine carries
-- where it has one).
--
-- The covers switch is the setting the mark always had, where it had a plain
-- on/off one, so nothing stored changes meaning. The spine switch is new.
-- Left unset, a spine shelf looks as it did before there was one: most marks
-- follow the covers switch, the page badge stays off (a book's length is its
-- width there), the progress bar stays off (a face-out cover never had one),
-- and the series number stays on a spine's foot.

local BookshelfSettings = require("lib/bookshelf_settings_store")

local M = {}

-- covers / spines: the setting keys. covers_default: what an unset covers key
-- reads as. spines_default: what an unset spines key reads as; nil means
-- "whatever covers says".
local MARKS = {
    -- A face-out cover never drew a bar, so its switch starts off.
    progress_bar  = { covers = "progress_bar_enabled",       covers_default = true,
                      spines = "progress_bar_spines",        spines_default = false },
    bookmark      = { covers = "progress_bookmark_enabled",  covers_default = true,
                      spines = "progress_bookmark_spines" },
    finished_fade = { covers = "finished_fade_enabled",      covers_default = false,
                      spines = "finished_fade_spines" },
    favorite      = { covers = "show_fav_badge",             covers_default = true,
                      spines = "show_fav_badge_spines" },
    -- These four have a choice of style as well, with its own "none". The
    -- switches here are extra gates beside it, so they get keys of their own.
    page_badge    = { covers = "progress_page_count_covers", covers_default = true,
                      spines = "progress_page_count_spines", spines_default = false },
    done_badge    = { covers = "progress_badge_covers",      covers_default = true,
                      spines = "progress_badge_spines" },
    on_hold       = { covers = "on_hold_covers",             covers_default = true,
                      spines = "on_hold_spines" },
    series_num    = { covers = "show_series_num_covers",     covers_default = true,
                      spines = "show_series_num_spines",     spines_default = true },
}

-- What the reader chose for this mark on this surface: true, false, or nil
-- when they have not chosen. For callers whose untouched behaviour is not the
-- one shown() falls back to.
function M.explicit(mark, surface)
    local m = MARKS[mark]
    if not m then return nil end
    local v = BookshelfSettings.read(surface == "spines" and m.spines or m.covers)
    if v == nil then return nil end
    return v == true
end

-- Is this mark drawn on this surface ("covers" or "spines")? An unknown mark
-- is shown: this runs at paint time, where a typo should not be an error.
function M.shown(mark, surface)
    local m = MARKS[mark]
    if not m then return true end
    if surface == "spines" then
        local v = M.explicit(mark, "spines")
        if v ~= nil then return v end
        if m.spines_default ~= nil then return m.spines_default end
    end
    local v = M.explicit(mark, "covers")
    if v == nil then return m.covers_default end
    return v
end

-- Flip one switch. A spine switch that has never been touched is written down
-- first when the covers one changes, so the switch beside it stays where the
-- reader saw it.
function M.set(mark, surface, on)
    local m = MARKS[mark]
    if not m then return end
    if surface == "spines" then
        BookshelfSettings.save(m.spines, on == true)
        return
    end
    if M.explicit(mark, "spines") == nil then
        BookshelfSettings.save(m.spines, M.shown(mark, "spines"))
    end
    BookshelfSettings.save(m.covers, on == true)
end

-- "both", "covers", "spines" or "none": for a menu row's summary.
function M.where(mark)
    local c, s = M.shown(mark, "covers"), M.shown(mark, "spines")
    if c and s then return "both" end
    if c then return "covers" end
    if s then return "spines" end
    return "none"
end

return M
