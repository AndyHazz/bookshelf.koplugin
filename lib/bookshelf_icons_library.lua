--- Icons library: grid-style glyph picker. Renders the curated catalogue
--- in browse mode (chip-filtered grid) and the full Nerd Font name set in
--- search mode (lazy-loaded on first search submit). Chrome comes from
--- lib/bookshelf_library_modal.lua; the curated picks live in
--- lib/bookshelf_icons_catalogue.lua.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LibraryModal = require("lib/bookshelf_library_modal")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Catalogue = require("lib/bookshelf_icons_catalogue")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local Screen = Device.screen

local IconsLibrary = {}

-- Catalogue tables (chip list, curated picks, pattern fill rules,
-- per-chip excludes) live in lib/bookshelf_icons_catalogue.lua so the
-- data stays separate from the projection/rendering code.
local CHIPS = Catalogue.CHIPS
IconsLibrary.CURATED_BY_CHIP = Catalogue.CURATED_BY_CHIP
local PATTERNS_BY_CHIP = Catalogue.PATTERNS_BY_CHIP
local PATTERN_EXCLUDES = Catalogue.PATTERN_EXCLUDES

-- Lazy-loaded full Nerd Font names data. nil until first search.
local nerdfont_names = nil

local function loadNerdFontNames()
    if nerdfont_names == nil then
        nerdfont_names = require("lib/bookshelf_nerdfont_names") or {}
    end
    return nerdfont_names
end

-- Convert a Unicode codepoint integer to its UTF-8 byte sequence.
local function utf8FromCodepoint(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40),
                           0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + math.floor((cp % 0x1000) / 0x40),
                           0x80 + (cp % 0x40))
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
                           0x80 + math.floor((cp % 0x40000) / 0x1000),
                           0x80 + math.floor((cp % 0x1000) / 0x40),
                           0x80 + (cp % 0x40))
    end
end

-- One-time cell projection of the full Nerd Font names list. Both the All
-- view and the search filter consume this same list, so we build it once
-- on first access and reuse it for the rest of the session. Label uses the
-- font's own cmap name verbatim (e.g. "checkbox-blank-circle-outline") so
-- the displayed string matches what search hits.
local _all_cells = nil
local function getAllNerdFontCells()
    if _all_cells then return _all_cells end
    local names = loadNerdFontNames()
    _all_cells = {}
    for _i, entry in ipairs(names) do
        _all_cells[#_all_cells + 1] = {
            glyph = utf8FromCodepoint(entry.code),
            label = entry.name,
            canonical = entry.name,
            -- Pre-lowercased haystack for the search path. Avoids re-lowering
            -- ~2,800 names on every keystroke-submit refresh: see currentItemList
            -- below which does query-tokenisation + cell-match using this.
            search_lc = entry.name:lower(),
            code = entry.code,
            insert_value = utf8FromCodepoint(entry.code),
        }
    end
    return _all_cells
end

-- Reverse lookup of the Nerd Font index by UTF-8 byte sequence. Used to
-- swap curated entries' hand-written labels for their canonical cmap name
-- (e.g. "Memory chip" -> "memory") so search by partial name finds them.
local _bytes_to_entry = nil
local function getNerdFontEntryByBytes(bytes)
    if _bytes_to_entry == nil then
        _bytes_to_entry = {}
        local names = loadNerdFontNames()
        for _i, entry in ipairs(names) do
            _bytes_to_entry[utf8FromCodepoint(entry.code)] = entry
        end
    end
    return _bytes_to_entry[bytes]
end

local function nameMatchesAnyPattern(name, patterns)
    for _i, pat in ipairs(patterns) do
        if name:find(pat, 1, true) then return true end
    end
    return false
end

-- Cache so each chip's projection (curated + pattern-fill) is built
-- once per session. The cmap data is static, the curated table is
-- module-scope, so the projection is invariant after first access.
local _projection_cache = {}

-- Project a curated chip's entries into render cells. Two input shapes:
--   { code = 0xNNNN, ... }   - Nerd Font glyph; bytes derived via
--                              utf8FromCodepoint, label from cmap unless
--                              the entry overrides via `label = ...`
--                              (used by the `dynamic` chip to keep the
--                              friendly token names).
--   { glyph = "<bytes>", label = "..." }
--                            - Pure-Unicode glyph not in the Nerd Font cmap.
--                              Bytes and label flow through as-is.
-- After the curated picks, any cmap entries matching the chip's pattern
-- list are appended (deduped against curated codepoints, alphabetised).
local function projectCuratedItems(chip_key)
    if _projection_cache[chip_key] then
        return _projection_cache[chip_key]
    end
    local items = IconsLibrary.CURATED_BY_CHIP[chip_key] or {}
    local out = {}
    local seen_codes = {}
    for _i, item in ipairs(items) do
        local cell = { insert_value = item.insert_value }
        if item.code then
            cell.glyph = utf8FromCodepoint(item.code)
            cell.code = item.code
            local entry = getNerdFontEntryByBytes(cell.glyph)
            cell.canonical = entry and entry.name or nil
            cell.label = item.label or cell.canonical or string.format("U+%04X", item.code)
            seen_codes[item.code] = true
        else
            cell.glyph = item.glyph
            cell.label = item.label
        end
        out[#out + 1] = cell
    end
    local patterns = PATTERNS_BY_CHIP[chip_key]
    if patterns then
        local excludes = PATTERN_EXCLUDES[chip_key] or {}
        for _i, cell in ipairs(getAllNerdFontCells()) do
            if cell.code and not seen_codes[cell.code]
                    and not excludes[cell.canonical]
                    and nameMatchesAnyPattern(cell.canonical, patterns) then
                seen_codes[cell.code] = true
                out[#out + 1] = cell
            end
        end
    end
    -- Sort every chip alphabetically so prefix-related glyphs stay adjacent
    -- (bluetooth, bluetooth-audio, bluetooth-off) and chip behaviour is
    -- consistent. Block ramp labels use sequential N/8 so alphabetical =
    -- fill order.
    table.sort(out, function(a, b)
        local ka = (a.canonical or a.label or ""):lower()
        local kb = (b.canonical or b.label or ""):lower()
        return ka < kb
    end)
    _projection_cache[chip_key] = out
    return out
end

-- Build the visible item list for the current chip + search state.
local function currentItemList(state)
    if state.search_query and #state.search_query >= 2 then
        -- Search across the full Nerd Font index; cap at 200 to keep
        -- pagination sensible. Reuse the cached cell projections.
        --
        -- Hot path: with ~2,800 cells and 16 grid slots per page, the parent
        -- LibraryModal calls into this list multiple times per refresh. We
        -- tokenise the query once and match against each cell's pre-lowered
        -- search_lc -- avoids ~2,800 query:lower() + gmatch reparses and
        -- ~2,800 haystack:lower() calls per refresh that the generic
        -- LibraryModal._matchesQuery would do.
        local terms = {}
        for term in state.search_query:lower():gmatch("%S+") do
            terms[#terms + 1] = term
        end
        local cells = getAllNerdFontCells()
        local items = {}
        for _i, cell in ipairs(cells) do
            local lc = cell.search_lc
            local match = true
            for _t = 1, #terms do
                if not lc:find(terms[_t], 1, true) then
                    match = false
                    break
                end
            end
            if match then
                items[#items + 1] = cell
                if #items >= 200 then break end
            end
        end
        return items
    end
    if state.active_chip == "all" or not state.active_chip then
        -- All: the entire Nerd Font index (~2,800 entries) for free browsing,
        -- alphabetised by cmap name. Curated category chips show smaller
        -- hand-picked lists, with cmap-name labels where applicable.
        return getAllNerdFontCells()
    end
    return projectCuratedItems(state.active_chip)
end

-- Scan KOReader's standard user icons dir (koreader/icons/) for user-supplied
-- images. Top-level *.svg / *.png only (plugins keep their own subdirs here,
-- e.g. casualchess/ -- we don't recurse). .svg wins over a same-named .png.
-- Filenames containing ']' are skipped: the [icon=NAME] token reads NAME up to
-- the first ']', so such a name couldn't round-trip. Cached per session; the
-- cache is dropped on each picker open (see :show) so freshly-added files show
-- up without a restart.
local _user_icons = nil
function IconsLibrary._scanUserIcons()
    if _user_icons then return _user_icons end
    _user_icons = {}
    local dir = DataStorage:getDataDir() .. "/icons"
    if lfs.attributes(dir, "mode") ~= "directory" then return _user_icons end
    local seen = {}
    -- Two passes so .svg takes precedence over a same-named .png.
    local function collect(want_ext)
        -- lfs.dir can throw on some Kindle/KOReader builds; this scan runs on
        -- the home-screen path, so a throw must degrade to "no icons" rather
        -- than crash the launcher. Wrap the loop (not pcall(lfs.dir, dir),
        -- which would drop lfs.dir's iterator state second return).
        pcall(function()
            for f in lfs.dir(dir) do
                local name, ext = f:match("^(.+)%.([^.]+)$")
                if name and ext and ext:lower() == want_ext
                        and name:sub(1, 1) ~= "."
                        and not seen[name]
                        and not name:find("]", 1, true)
                        and lfs.attributes(dir .. "/" .. f, "mode") == "file" then
                    seen[name] = true
                    _user_icons[#_user_icons + 1] = {
                        icon = name,
                        label = name,
                        insert_value = "[icon=" .. name .. "]",
                        is_image = true,
                    }
                end
            end
        end)
    end
    collect("svg")
    collect("png")
    table.sort(_user_icons, function(a, b) return a.label:lower() < b.label:lower() end)
    return _user_icons
end

-- Render a single icon cell: glyph centred large, label below.
-- Glyph size scales with cell width -- wider cells (e.g. the 3-col
-- Dynamic chip) get a bigger glyph so the extra space isn't wasted.
-- Glyphs always render through the "symbols" face (KOReader's bundled
-- Symbols Nerd Font); labels follow the bookshelf UI font.
function IconsLibrary._renderCell(item, dimen)
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    local BFont = require("lib/bookshelf_fonts")
    local glyph_size = math.max(36, math.floor(dimen.w * 0.16))
    local glyph_w = TextWidget:new{
        text = item.glyph or "",
        face = Font:getFace("symbols", glyph_size),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_face = (BFont:getFace("cfont", 11))
    local label_w = TextWidget:new{
        text = item.label or "",
        face = label_face,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = dimen.w - Screen:scaleBySize(8),
    }
    local stack = VerticalGroup:new{
        align = "center",
        glyph_w,
        VerticalSpan:new{ width = Size.span.vertical_default or 4 },
        label_w,
    }
    return FrameContainer:new{
        bordersize = Size.border.thin,
        radius = Size.radius.default,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = dimen.w, h = dimen.h },
            stack,
        },
    }
end

-- Brief notification with the canonical name + codepoint on long-tap.
function IconsLibrary._showCellTooltip(item)
    if not item.canonical then return end
    local code_str = item.code and string.format("U+%04X", item.code) or ""
    local body = item.canonical .. (code_str ~= "" and (" \xC2\xB7 " .. code_str) or "")
    UIManager:show(Notification:new{ text = body, timeout = 3 })
end

--- Open the icons library modal. on_select is called with the chosen
--- glyph (or %token, for dynamic entries) when the user taps a cell.
--- opts (optional table):
---   dynamic = false   -- hide the Dynamic category. Use this wherever the
---                        picked value is rendered literally (chip labels/
---                        icons, start menu icons) rather than expanded
---                        through lib/bookshelf_tokens.lua.
function IconsLibrary:show(on_select, opts)
    opts = opts or {}
    -- Chip strip for this invocation: drop the Dynamic category when the
    -- caller can't expand %tokens. The dynamic entries only surface under
    -- their own chip (the All view and search cover the Nerd Font index
    -- only), so omitting the chip removes them entirely.
    local chips = CHIPS
    if opts.dynamic == false then
        chips = {}
        for _i, c in ipairs(CHIPS) do
            if c.key ~= "dynamic" then chips[#chips + 1] = c end
        end
    end
    -- Captures the runtime state used by the config callbacks. This lives in
    -- a closure rather than on the modal so taps/chips/search can mutate it
    -- without going through LibraryModal's own state.
    local state = { active_chip = "all", search_query = nil }
    -- Memoise the filtered list per (chip, query) key. LibraryModal calls
    -- item_count + item_at-per-cell + pagination's second item_count per
    -- refresh, so without this the search path was scanning all ~2,800
    -- nerd-font cells multiple times per keystroke-submit. Curated chips
    -- benefit too: projectCuratedItems builds a fresh table every time.
    local items_key, items_cache = nil, nil
    local function items()
        local key = (state.active_chip or "") .. "\0" .. (state.search_query or "")
        if items_key ~= key then
            items_cache = currentItemList(state)
            items_key = key
        end
        return items_cache
    end
    local self_ref = self
    local config
    config = {
        title = _("Icons library"),
        chip_strip = function()
            local out = {}
            for _i, c in ipairs(chips) do
                out[#out + 1] = {
                    key = c.key, label = c.label,
                    is_active = (c.key == state.active_chip) and true or false,
                }
            end
            return out
        end,
        on_chip_tap = function(chip_key)
            state.active_chip = chip_key
            -- Tapping a category chip while a search is active doesn't make
            -- sense (the chips filter the curated catalogue, search hits the
            -- full Nerd Font index -- there's no overlap). Clear the search
            -- across all three layers -- the icons-state, the modal-level
            -- search_query (which gets re-applied to the InputText on next
            -- refresh), and the InputText's own text -- so the chip-filtered
            -- curated view becomes the consistent visible state.
            if state.search_query then
                state.search_query = nil
                if self_ref.modal then
                    self_ref.modal.search_query = nil
                    if self_ref.modal._search_input then
                        self_ref.modal._search_input:setText("")
                    end
                end
            end
        end,
        search_placeholder = function()
            local names = loadNerdFontNames()
            return T(_("Search %1 icons by name…"), tostring(#names))
        end,
        on_search_submit = function(query)
            state.search_query = query
            -- Search hits the full Nerd Font index regardless of the active
            -- chip, so the chip strip should reflect that by snapping back
            -- to "All" -- otherwise the highlighted chip lies about what's
            -- visible. The chip-strip callback rebuilds is_active from
            -- state.active_chip on the next refresh.
            if query then state.active_chip = "all" end
        end,
        -- Dynamic chip uses a 3-col grid in both orientations so its small
        -- entry count gets wider cards. Default chips run 4 cols x 4 rows in
        -- portrait, 5 cols x 3 rows in landscape -- same browse density (16
        -- vs 15 cells) but reshaped to the available aspect.
        grid_cols = function()
            if state.active_chip == "dynamic" then return 3 end
            return Screen:getWidth() > Screen:getHeight() and 5 or 4
        end,
        cells_per_page = function()
            local landscape = Screen:getWidth() > Screen:getHeight()
            if state.active_chip == "dynamic" then
                return landscape and 6 or 9
            end
            return landscape and 15 or 16
        end,
        cell_renderer = IconsLibrary._renderCell,
        cell_long_tap = IconsLibrary._showCellTooltip,
        on_cell_tap = function(item)
            local val = item.insert_value or item.glyph
            if self_ref.modal then UIManager:close(self_ref.modal); self_ref.modal = nil end
            if on_select then on_select(val) end
        end,
        item_count = function() return #items() end,
        item_at = function(idx) return items()[idx] end,
        footer_actions = {
            { key = "close", label = _("Close"), on_tap = function()
                if self_ref.modal then UIManager:close(self_ref.modal); self_ref.modal = nil end
            end },
        },
    }
    self.modal = LibraryModal:new{ config = config }
    UIManager:show(self.modal)
end

return IconsLibrary
