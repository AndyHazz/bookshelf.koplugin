--[[
Start-menu module: a random book from the current chip/tab (or the whole
library). See README.md in this directory for the module spec contract.

Book list comes from the same route the bookshelf itself uses for a chip
(Repo.getBySource with the tab's source — see _fetchChipItems), with a
status filter built from the module's settings (default unread-only:
{ statuses = { unread = true } }, the repo's normalised vocabulary for
status nil/"new"; the other keys are reading / on_hold / finished). The
underlying library walk and the per-(source,filter) path list are both
memoized in the repo, so a re-render never re-walks. light_only skips
cover hydration entirely.

Settings (long-press the card > "Module settings…"): pick source (current
chip vs whole library) and which reading statuses are eligible. Stored via
the bookshelf settings store under micromodule_random_unread_* keys (the
module-settings convention; see the README).

Tap behaviour (keep_open module): the tap does NOT open the book. It loads
the displayed candidate into the bookshelf's HERO slot behind the still-open
menu, then re-rolls, so repeated taps cycle fresh candidates through the
hero. The hero load rides the widget's existing preview mechanism
(bw:_previewBook → bw._preview_book), which _buildHero consults before its
normal lastfile choice — a deliberately TRANSIENT override: in-memory only,
cleared by chip switches / opening a book / restart, exactly like a
shelf-cover preview tap. No new persistence, no new hero-selection path.

NO cover image in v1, deliberately: Book.cover_bb is one-shot (ImageWidget
frees it after each paint), and module render output is rebuilt per paint —
a shared cover bb across rebuilds reads freed memory.
]]
local _ = require("lib/bookshelf_i18n").gettext
local SafeText = require("lib/bookshelf_text_safe")

-- Group-card sources have no flat book list to draw from; for those chips
-- the pick falls back to the whole library ("library" = flattened walk).
local GROUP_KINDS = {
    all = true, -- getAll mixes folder cards + top-level books only
    series = true, authors = true, genres = true, tags = true,
    formats = true, ratings = true, languages = true,
}

local FETCH_CAP = 300 -- plenty of candidates for a random pick

-- Cache lifetime: the displayed candidate must be STABLE across focus-step
-- rebuilds (the menu re-renders module rows on every key-nav step) but
-- re-roll after a tap and on each fresh menu open. The tap path invalidates
-- explicitly (see on_tap), which is the primary re-roll trigger; the short
-- TTL is the fallback that keeps fresh menu opens (usually >25s apart)
-- rolling a new book without any open-hook plumbing.
local PICK_TTL_S = 25
local _pick_cache -- { at = <epoch>, book = <light record> | false, die = 1..6 }
local _exclude_fp -- consumed by the next roll: skip the just-loaded book

-- mdi dice-1 .. dice-6 (U+E8C9..U+E8CE in the bundled symbols font); the
-- face is rolled WITH the pick, so it tumbles on every tap / fresh open
-- but holds still across focus-step rebuilds.
local DICE = {
    "\xEE\xA3\x89", "\xEE\xA3\x8A", "\xEE\xA3\x8B",
    "\xEE\xA3\x8C", "\xEE\xA3\x8D", "\xEE\xA3\x8E",
}

-- Drop the cached pick so the next render rolls afresh. exclude_fp (the
-- candidate a tap just loaded into the hero) is skipped by that next roll
-- whenever more than one candidate exists, so consecutive taps always
-- show the user something new.
local function invalidate(exclude_fp)
    _pick_cache = nil
    _exclude_fp = exclude_fp
end

-- KOReader does not seed math.random globally; without this the first
-- pick after every restart would be the same book.
math.randomseed(os.time())

-- Settings (micromodule_<key>_* store convention):
--   source: "chip" (default, today's behaviour) | "all" (whole library)
--   statuses: set keyed on the repo's normalised status vocabulary
--             (unread / reading / on_hold / finished); default unread-only.
local SRC_KEY = "micromodule_random_unread_source"
local ST_KEY  = "micromodule_random_unread_statuses"

local function readSource()
    local Store = require("lib/bookshelf_settings_store")
    return Store.read(SRC_KEY, "chip")
end

local function readStatuses()
    local Store = require("lib/bookshelf_settings_store")
    local s = Store.read(ST_KEY)
    if type(s) ~= "table" or next(s) == nil then
        return { unread = true } -- default = the original unread-only pick
    end
    return s
end

local function unreadOnly(statuses)
    return statuses.unread == true
        and not (statuses.reading or statuses.on_hold or statuses.finished)
end

local function pickUnread()
    local Store    = require("lib/bookshelf_settings_store")
    local TabModel = require("lib/bookshelf_tab_model")
    local Repo     = require("lib/bookshelf_book_repository")
    local statuses = readStatuses()
    local src
    if readSource() == "all" then
        src = { kind = "library" } -- whole library, regardless of chip
    else
        local chip = Store.read("active_chip") or "recent"
        local tab  = TabModel.getById(chip)
        src = (tab and tab.source) or { kind = chip }
        if GROUP_KINDS[src.kind] then
            src = { kind = "library" }
        elseif src.kind == "folder" then
            -- folder + status filter returns folder cards; folder_flat gives
            -- the books-only descent we want.
            src = { kind = "folder_flat", id = src.id }
        end
        -- A chip whose own status filter shares no status with the
        -- configured set cannot contain a candidate; don't waste a fetch
        -- learning that. (Both sets use the repo's normalised vocabulary.)
        local tf = tab and tab.filter and tab.filter.statuses
        if tf and next(tf) ~= nil then
            local overlap = false
            for k in pairs(statuses) do
                if tf[k] then overlap = true; break end
            end
            if not overlap then return false end
        end
    end
    local books = Repo.getBySource(src, { statuses = statuses },
        nil, 0, FETCH_CAP, { light_only = true })
    if not books or #books == 0 then return false end
    if _exclude_fp and #books > 1 then
        local filtered = {}
        for _i, bk in ipairs(books) do
            if bk.filepath ~= _exclude_fp then filtered[#filtered + 1] = bk end
        end
        if #filtered > 0 then books = filtered end
    end
    return books[math.random(#books)] or false
end

local function currentPick()
    if _pick_cache and os.time() - _pick_cache.at < PICK_TTL_S then
        return _pick_cache.book or nil
    end
    local ok, book = pcall(pickUnread)
    if not ok then
        require("logger").warn("[bookshelf] random unread pick failed:", book)
        book = false
    end
    _exclude_fp = nil -- one-shot: only the roll right after a tap skips it
    _pick_cache = { at = os.time(), book = book or false,
                    die = math.random(#DICE) }
    return book or nil
end

-- Module settings dialog (long-press > "Module settings…"). Each tap
-- saves, invalidates the pick cache, reloads the menu beneath (so the card
-- re-renders with the new scope) and re-opens the dialog so the checkmarks
-- refresh — same close-and-reopen pattern as the chip editor's status
-- filter. At least one status must stay selected: unchecking the last one
-- is refused with a brief Notification.
local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local Notification = require("ui/widget/notification")
    local UIManager    = require("ui/uimanager")
    local Store        = require("lib/bookshelf_settings_store")
    local dialog
    local function applyAndReopen()
        UIManager:close(dialog)
        invalidate()
        if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
        showSettings(ctx)
    end
    local function srcBtn(label, mode)
        local active = readSource() == mode
        return {
            text = (active and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if readSource() == mode then return end
                Store.save(SRC_KEY, mode)
                applyAndReopen()
            end,
        }
    end
    local function statusBtn(label, key)
        local on = readStatuses()[key] == true
        return {
            text = on and (label .. " \xE2\x9C\x93") or label,
            callback = function()
                local s = readStatuses()
                if s[key] then
                    local n = 0
                    for _k in pairs(s) do n = n + 1 end
                    if n <= 1 then
                        UIManager:show(Notification:new{
                            text = _("At least one status must stay selected"),
                        })
                        return
                    end
                    s[key] = nil
                else
                    s[key] = true
                end
                Store.save(ST_KEY, s)
                applyAndReopen()
            end,
        }
    end
    dialog = ButtonDialog:new{
        title        = _("Random book"),
        title_align  = "center",
        width_factor = 0.65,
        buttons      = {
            { srcBtn(_("Current chip"), "chip"), srcBtn(_("All books"), "all") },
            { statusBtn(_("Unread"), "unread") },
            { statusBtn(_("In progress"), "reading") },
            { statusBtn(_("On hold"), "on_hold") },
            { statusBtn(_("Finished"), "finished") },
        },
    }
    UIManager:show(dialog)
end

return {
    key   = "random_unread", -- stable id stored in user menus; never change it
    title = _("Random book"),
    render = function(width, scale_pct)
        local Blitbuffer    = require("ffi/blitbuffer")
        local Fonts         = require("lib/bookshelf_fonts")
        local TextWidget    = require("ui/widget/textwidget")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local SM = require("lib/bookshelf_start_menu_modules")
        local CARD_BG = SM.CARD_BG
        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local statuses = readStatuses()
        local b = currentPick()
        if not b then
            return TextWidget:new{
                text = unreadOnly(statuses) and _("Nothing unread here")
                    or _("Nothing to pick from here"),
                face = Fonts:getFace("cfont", sc(15)),
                fgcolor = SM.COLOR_MUTED,
                max_width = mw,
            }
        end
        local TextBoxWidget  = require("ui/widget/textboxwidget")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan  = require("ui/widget/horizontalspan")
        local Screen = require("device").screen
        -- The die hugs the card's bottom-right corner: the text block takes
        -- a FIXED width (mw minus die and gap — the title TextBoxWidget
        -- always occupies the full text_w, so the die's x never moves as
        -- the title wraps over 1-3 lines) and the bottom alignment pins the
        -- die to the block's baseline edge. Its face tumbles on every
        -- re-roll.
        -- The glyph's font box carries descender space below the ink, so a
        -- bottom-aligned TextWidget shows extra padding under the die. PUA
        -- icon glyphs render above the baseline, so forcing the widget's
        -- height to its own baseline trims the box to the ink bottom and
        -- the die sits with even bottom/right padding in the card.
        local die_face = Fonts:getFace("cfont", sc(38))
        local die_text = DICE[(_pick_cache and _pick_cache.die) or 1]
        local probe = TextWidget:new{ text = die_text, face = die_face }
        probe:getSize() -- populates _baseline_h
        local die_ink_h = probe._baseline_h
        probe:free()
        local die = TextWidget:new{
            text = die_text,
            face = die_face,
            fgcolor = SM.COLOR_PRIMARY,
            forced_height   = die_ink_h,
            forced_baseline = die_ink_h,
        }
        local gap = Screen:scaleBySize(sc(8))
        local text_w = math.max(50, mw - die:getSize().w - gap)
        local face_title, bold_title = Fonts:getFace("cfont", sc(15), {bold=true})
        local group = VerticalGroup:new{
            align = "left",
            TextWidget:new{
                -- Unread-only scope keeps the original framing; once read
                -- books are eligible "new" would be wrong.
                text = unreadOnly(statuses) and _("Try something new:")
                    or _("Why not this one:"),
                face = Fonts:getFace("cfont", sc(13), {italic=true}),
                fgcolor = SM.COLOR_MUTED,
                max_width = text_w,
            },
            TextBoxWidget:new{
                text  = SafeText.safe(b.title or b.filename or "?"),
                face  = face_title,
                bold  = bold_title,
                width = text_w,
                fgcolor = SM.COLOR_PRIMARY,
                -- TextBoxWidget paints an opaque background (unlike
                -- TextWidget); match the module card's grey or the title
                -- sits on a white bar.
                bgcolor = CARD_BG,
            },
        }
        if b.author and b.author ~= "" then
            group[#group + 1] = TextWidget:new{
                text = SafeText.safe(b.author),
                face = Fonts:getFace("cfont", sc(14)),
                fgcolor = SM.COLOR_PRIMARY,
                max_width = text_w,
            }
        end
        return HorizontalGroup:new{
            align = "bottom",
            group,
            HorizontalSpan:new{ width = gap },
            die,
        }
    end,
    show_settings = showSettings,
    -- keep_open: the menu stays up while the hero changes underneath it,
    -- and the _reload that follows re-renders this module with the fresh
    -- roll — each tap cycles a new candidate into view.
    keep_open = true,
    on_tap = function(ctx)
        local b = _pick_cache and _pick_cache.book
        if not (b and b.filepath) then return end
        -- Same stale-record guard as bookshelf_widget._openBook.
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs.attributes(b.filepath, "mode") ~= "file" then return end
        local bw = ctx and ctx.bw
        if bw and bw._previewBook then
            -- Load the displayed candidate into the hero via the widget's
            -- preview path (covers the in-place hero swap + scoped repaint;
            -- the menu above repaints on top). Guard the same-book case:
            -- _previewBook treats a re-tap of the current preview as
            -- "confirm and open", which must never fire from here (it can
            -- recur when only one unread candidate exists, so the re-roll
            -- lands on the same book).
            if not (bw._preview_book
                    and bw._preview_book.filepath == b.filepath) then
                bw:_previewBook(b)
            end
        end
        -- Re-roll for the menu reload that follows; don't show the book
        -- we just loaded again when there's any alternative.
        invalidate(b.filepath)
    end,
}
