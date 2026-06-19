-- bookshelf_hero_card.lua
-- Currently-reading detail card: cover thumbnail + an editable right column
-- composed from five region templates (status / title / author / description
-- / progress). All region styling and content is driven by hero_regions.

local FrameContainer  = require("ui/widget/container/framecontainer")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local InputContainer  = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TopContainer    = require("ui/widget/container/topcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local OverlapGroup    = require("ui/widget/overlapgroup")
local LineWidget      = require("ui/widget/linewidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local Font            = require("ui/font")
local BFont           = require("lib/bookshelf_fonts")
local Blitbuffer      = require("ffi/blitbuffer")
local Screen          = require("device").screen
local SpineWidget     = require("lib/bookshelf_spine_widget")
local Tokens          = require("lib/bookshelf_tokens")
local Regions         = require("lib/bookshelf_hero_regions")
local HeroBar         = require("lib/bookshelf_hero_bar")
local TextSegments    = require("lib/bookshelf_text_segments")
local RenderText      = require("ui/rendertext")

local HC_STAR       = "\xef\x80\x85" -- nf-fa-star            (U+F005)
local HC_HALF_STAR  = "\xef\x84\xa3" -- nf-fa-star_half_empty (U+F123)
local HC_EMPTY_STAR = "\xef\x80\x86" -- nf-fa-star_o          (U+F006)

local HeroCard = InputContainer:extend{
    book                = nil,
    width               = nil,
    height              = nil,
    cover_w             = 116,
    cover_h             = nil,
    pad                 = nil,
    device_state        = nil,
    on_tap              = nil,
    on_hold             = nil,
    -- Fires when the user taps inside the description region. Receives
    -- the book record so the widget can open a scrollable viewer for
    -- the full text. Tap on the rest of the hero still goes to on_tap
    -- (open the book) -- the description's tap zone is a child input
    -- area that consumes the event before the parent sees it.
    on_description_tap  = nil,
    -- Fires when the user taps a star in the rating row. Receives the
    -- book record and the new rating (1-5, or nil to clear). The widget
    -- is responsible for persisting to DocSettings and triggering a
    -- hero rebuild.
    on_rating_change    = nil,
    -- Fires when the user taps the display-only Hardcover rating row.
    -- The parent fetches/shows reviews explicitly so normal hero
    -- rendering remains cache-only and offline.
    on_hardcover_reviews_tap = nil,
    is_selected         = false,
    is_bulk_selected    = false,
    -- Builder callback returning a fresh tappable pill-strip widget for
    -- the "Tags (interactive)" hero region. BookshelfWidget supplies it
    -- (it owns _buildPillSpecs + _buildPillGroup); HeroCard calls it on
    -- every right-column rebuild so a fresh widget tree is wired in
    -- after each free(), rather than reusing one whose internals have
    -- been torn down.
    tags_builder        = nil,
}

-- Reads the user's font-scale setting (% of nominal). Applied on top of
-- per-region font_size so the user can dial the whole hero up or down.
-- Defensive fallback: if Font:getFace errors or returns nil for the
-- requested face_name (e.g. a stale "@family:serif" sentinel from a
-- prior bookends-picker tap, or a font file that has since been
-- removed from the filesystem), drop back to "infofont" so the render
-- never crashes on a missing face.
local function fontFace(face_name, base)
    local scale = (BookshelfSettings.read("font_scale") or 100) / 100
    local size = math.max(8, math.floor(base * scale + 0.5))
    if face_name then
        local ok, face = pcall(Font.getFace, Font, face_name, size)
        if ok and face then return face end
    end
    return (BFont:getFace("infofont", size))
end

-- Elastic tokens: tokens that, when present in a region's expanded text,
-- trigger horizontal-layout rendering ([before-text, elastic-widget, after-
-- text]) where the elastic widget fills the remaining width. The order
-- here matters only as documentation; the renderer detects whichever
-- elastic token appears first in the template.
--   %bar    -> progress-bar widget (HeroBar). Has a small visual gap on
--              either side so the bar doesn't weld onto adjacent glyphs.
--   %spacer -> HorizontalSpan. Pure whitespace; no boundary gap (the span
--              pixels ARE the gap). Lets users right-align some tokens
--              against left-aligned ones in any region, e.g.
--              "Reading%spacer47%" -> "Reading" left, "47%" right.
local BAR_TOKEN_PATTERN    = "%%bar"
local SPACER_TOKEN_PATTERN = "%%spacer"

function HeroCard:init()
    self.cover_h = self.cover_h or self.height
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if not self.book then
        self[1] = self:_renderEmpty()
    else
        self[1] = self:_renderFull()
    end
    -- Only Hold is registered at the HeroCard level. A whole-hero Tap
    -- zone caused two problems: (1) it absorbed taps that the cover /
    -- description / star children needed to receive, and (2) when it
    -- matched, InputContainer:onGesture dispatches a generic "Tap"
    -- event that propagates through children -- firing the cover
    -- SpineWidget's onTap and opening the book even on taps far outside
    -- the cover's pixel bounds. Children own their own Tap zones now.
    self.ges_events = {
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function HeroCard:_renderEmpty()
    return FrameContainer:new{
        width      = self.width,
        height     = self.height,
        bordersize = Size.border.thin,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            TextBoxWidget:new{
                text      = "Welcome to Bookshelf · Tap a cover to start reading",
                face      = fontFace("infofont", 14),
                width     = self.width - Size.padding.large * 2,
                alignment = "center",
            },
        },
    }
end

-- Resolve a region's face: honour the user's saved font_face when set,
-- otherwise fall through to the default infofont. font_size is always
-- multiplied by the global bookshelf_font_scale via fontFace().
local function regionFace(region)
    return fontFace(region.font_face, region.font_size)
end

-- _buildSegmentedInline(text, face, bold) -- returns a single widget
-- (TextWidget if homogeneous, HorizontalGroup of TextWidgets if the
-- text mixes text + icon segments). When bold is false the function
-- short-circuits to a plain TextWidget regardless of content -- the
-- whole point of segmenting is to keep glyphs out of the bold path,
-- so non-bold lines have nothing to gain. The returned widget always
-- has a getSize() so callers' width math works.
local function _buildSegmentedInline(text, face, bold, max_width, truncate_left)
    -- max_width set => truncate to one line with an ellipsis (issue #170). The
    -- segmented icon/bold path can't be partially truncated, so a clamped side
    -- always uses the plain TextWidget path (loses the per-segment bold split on
    -- that side only, which is an overflow edge case). truncate_left puts the
    -- ellipsis at the START (used for the right-aligned, after-spacer side so its
    -- right-anchored tail -- battery/wifi/etc -- stays and the cut sits by the spacer).
    if max_width or not bold or not text:find("[\x80-\xFF]") then
        return TextWidget:new{ text = text, face = face, bold = bold or false,
            max_width = max_width, truncate_left = truncate_left or false }
    end
    local segments = TextSegments.labelSegments(text)
    if #segments <= 1 then
        return TextWidget:new{ text = text, face = face, bold = bold }
    end
    local hg = HorizontalGroup:new{ align = "center" }
    for _i, seg in ipairs(segments) do
        hg[#hg + 1] = TextWidget:new{
            text = seg.text,
            face = face,
            bold = seg.class == "text",
        }
    end
    return hg
end

-- balanceLines(text, face, max_width, bold) — redistribute words across
-- wrapped lines so each line is roughly the same width. Avoids the
-- "widow" effect where a long title's last line is one or two words.
-- TextBoxWidget wraps greedily (fill each line to capacity); this
-- rebalances by enumerating valid break-point combinations and picking
-- the one that minimises the *widest* resulting line.
--
-- Returns text with manual "\n" inserted at the chosen break points,
-- or the original text when balancing isn't possible (single line,
-- words too long to fit, line count > 3 — for which the search space
-- explodes and the natural wrap is usually acceptable).
local function balanceLines(text, face, max_width, bold)
    if not text or text == "" or text:find("\n") then return text end
    -- Tokenize on whitespace. Drop any pre-existing manual breaks above.
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    local nw = #words
    if nw < 2 then return text end

    -- Measure each word once. Space width is constant for the face.
    local widths = {}
    for i = 1, nw do
        widths[i] = RenderText:sizeUtf8Text(0, max_width, face, words[i], true, bold).x
    end
    local space_w = RenderText:sizeUtf8Text(0, false, face, " ", true, bold).x

    -- line_w(i, j) — width of joined words[i..j] with single spaces.
    local function line_w(i, j)
        local w = 0
        for k = i, j do w = w + widths[k] end
        return w + (j - i) * space_w
    end

    -- Greedy wrap to determine natural line count. If everything fits on
    -- one line, nothing to balance.
    local n_lines = 0
    do
        local i = 1
        while i <= nw do
            local j = i
            while j < nw and line_w(i, j + 1) <= max_width do
                j = j + 1
            end
            -- If a single word doesn't fit, give up — TextBoxWidget will
            -- glyph-truncate it and balancing wouldn't help.
            if j < i then return text end
            n_lines = n_lines + 1
            i = j + 1
        end
    end
    if n_lines < 2 then return text end
    if n_lines > 3 then return text end

    -- Brute-force search over break combinations. For n_lines = 2 we
    -- choose 1 break in [1..nw-1]; for n_lines = 3 we choose 2 breaks.
    -- Picks the configuration that minimises max line width while still
    -- satisfying every line ≤ max_width. Ties broken by smallest sum-
    -- of-squared-deviations from the mean (lightly favours the visually
    -- "tightest" balance).
    local best_breaks
    local best_max  = math.huge
    local best_dev  = math.huge
    local function consider(breaks)
        local prev = 0
        local mx, sum = 0, 0
        local line_ws = {}
        for _i, b in ipairs(breaks) do
            local w = line_w(prev + 1, b)
            if w > max_width then return end
            line_ws[#line_ws + 1] = w
            if w > mx then mx = w end
            sum = sum + w
            prev = b
        end
        local last = line_w(prev + 1, nw)
        if last > max_width then return end
        line_ws[#line_ws + 1] = last
        sum = sum + last
        if last > mx then mx = last end
        local mean = sum / (#breaks + 1)
        local dev = 0
        for _i, w in ipairs(line_ws) do
            local d = w - mean
            dev = dev + d * d
        end
        if mx < best_max or (mx == best_max and dev < best_dev) then
            best_max    = mx
            best_dev    = dev
            best_breaks = breaks
        end
    end
    if n_lines == 2 then
        for k = 1, nw - 1 do consider({ k }) end
    else  -- n_lines == 3
        for k1 = 1, nw - 2 do
            for k2 = k1 + 1, nw - 1 do
                consider({ k1, k2 })
            end
        end
    end
    if not best_breaks then return text end

    -- Reassemble with manual newlines at the chosen break points.
    local parts = {}
    local prev = 0
    for _i, b in ipairs(best_breaks) do
        parts[#parts + 1] = table.concat(words, " ", prev + 1, b)
        prev = b
    end
    parts[#parts + 1] = table.concat(words, " ", prev + 1, nw)
    return table.concat(parts, "\n")
end

-- Build a widget for a single region using the resolved settings. Uses
-- TextBoxWidget for the normal multi-line wrapping case. Switches to a
-- segmented HorizontalGroup when the region is bold AND the rendered
-- text contains nerd-font / emoji glyphs AND it's a single line --
-- keeps the glyphs at the font's native weight while bolding the
-- surrounding text. (TextBoxWidget can't do per-segment bold, so the
-- segmented path loses line wrapping; reserved for short single-line
-- content like the status clock line, which is the common case for
-- icon-bearing region templates.)
local function buildText(text, region, width, max_height)
    -- [font=NAME] whole-region override (issue #144): when the text is wrapped
    -- in a single [font=NAME]...[/font] spanning the whole content, render this
    -- region in that font -- FACE ONLY; size, bold and alignment stay from the
    -- region. Lets a template conditionally pick a font (e.g.
    -- [if:lang=ja][font=...]%title[/font][else]...[/if]) on top of the line
    -- editor's default. An unresolvable name falls back to the region font;
    -- partial / mid-line [font] tags are stripped (inline spans unsupported).
    local override_face
    -- Apply the FIRST [font=NAME] found anywhere to the WHOLE region, not only
    -- when it wraps the entire line. Mid-line spans aren't supported, so if a
    -- font tag is present at all the whole line takes that font (text outside
    -- the tag included). After a conditional resolves only one branch's [font]
    -- survives, so the first match is the right one.
    local fname = text:match("%[font=([^%]]+)%]")
    if fname then
        local file = BFont.resolveFontNameToFile(fname)
        if file then override_face = fontFace(file, region.font_size) end
    end
    text = text:gsub("%[font=[^%]]*%]", ""):gsub("%[/font%]", "")
    local rendered = text
    if region.uppercase then rendered = TextSegments.upper(rendered) end
    local face = override_face or regionFace(region)
    local is_bold = region.bold or false
    if is_bold and rendered:find("[\x80-\xFF]") and not rendered:find("\n") then
        local segments = TextSegments.labelSegments(rendered)
        if #segments > 1 then
            local hg = HorizontalGroup:new{ align = "center" }
            for _i, seg in ipairs(segments) do
                hg[#hg + 1] = TextWidget:new{
                    text    = seg.text,
                    face    = face,
                    bold    = seg.class == "text",
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            end
            -- HorizontalGroup doesn't honour region.alignment the way
            -- TextBoxWidget does -- it just sits at its natural width.
            -- Wrap in the matching alignment container sized to the
            -- region's allotted width so center / right alignment work.
            local alignment = region.alignment or "left"
            local hg_h = hg:getSize().h
            local dimen = Geom:new{ w = width, h = hg_h }
            if alignment == "center" then
                return CenterContainer:new{ dimen = dimen, hg }
            elseif alignment == "right" then
                return RightContainer:new{ dimen = dimen, hg }
            end
            return LeftContainer:new{ dimen = dimen, hg }
        end
    end
    return TextBoxWidget:new{
        text        = rendered,
        face        = face,
        bold        = is_bold,
        width       = width,
        alignment   = region.alignment or "left",
        -- region.line_height (em multiplier) overrides TextBoxWidget's
        -- 0.3 default. Only the title region sets this today; other
        -- regions fall through to the default leading.
        line_height = region.line_height,
        -- Optional height cap (the title in a short hero): truncate with an
        -- ellipsis rather than wrapping unbounded. height_adjust keeps short
        -- text tight (shrinks to natural height, no reserved gap below).
        height                        = max_height,
        height_adjust                 = max_height and true or nil,
        height_overflow_show_ellipsis = max_height and true or nil,
    }
end

-- Forward declaration so HeroCard.buildStatusRow below can reference
-- buildLine before the function body is parsed. Lua free-variable
-- resolution captures by lexical position, so without this the call
-- inside buildStatusRow would resolve to a missing global.
local buildLine

-- buildStatusRow(book, state, width) — module-level helper that produces the
-- exact status block (status TextBoxWidget + hairline + small gap) rendered
-- inside _buildRightColumn. Exposed so BookshelfWidget can drop the same
-- widget tree into its expanded-mode strip, guaranteeing the status sits at
-- the same y position and uses identical face / alignment / region settings
-- as the in-hero version.
-- with_hairline (default true): include the gray hairline + small gap below
-- the status text. Normal-mode hero passes default; collapsed-mode strip
-- passes false because the chip strip below it serves the same separator
-- role and doubling up reads as visual noise.
function HeroCard.buildStatusRow(book, state, width, with_hairline)
    if with_hairline == nil then with_hairline = true end
    local regions = Regions.read()
    if not regions.status or regions.status.disabled then return nil end
    if not book then return nil end
    local status_text = Tokens.expand(regions.status.template, book, state)
    status_text = status_text:gsub("%[/?[biu]%]", "")
    if Tokens.isEmpty(status_text) then return nil end
    local vg = VerticalGroup:new{ align = "left" }
    vg[#vg + 1] = buildLine(status_text, regions.status, width, book, nil, true)
    if with_hairline then
        vg[#vg + 1] = LineWidget:new{
            dimen      = Geom:new{ w = width, h = Size.line.medium },
            background = Blitbuffer.gray(0.4),
        }
        vg[#vg + 1] = VerticalSpan:new{ width = Size.padding.default }
    end
    return vg
end

-- buildLine: if `expanded` contains an elastic token (%bar or %spacer),
-- returns a HorizontalGroup of [text-before, elastic-widget, text-after]
-- where the elastic widget fills the remaining width. Without an elastic
-- token, returns a plain TextBoxWidget via buildText. The first elastic
-- token wins; any further occurrences of either elastic pattern in the
-- trailing segment are stripped so they don't render as literal text.
-- Assigned (not `local function`) so the forward declaration above
-- resolves; HeroCard.buildStatusRow references this by name.
buildLine = function(expanded, region, width, book, max_height, single_line)
    -- Locate the first elastic token (%bar or %spacer), whichever appears
    -- earliest. Same one-shot semantics either way.
    local bar_pos    = expanded:find(BAR_TOKEN_PATTERN)
    local spacer_pos = expanded:find(SPACER_TOKEN_PATTERN)
    local first_pos, first_pattern, kind
    if bar_pos and (not spacer_pos or bar_pos <= spacer_pos) then
        first_pos, first_pattern, kind = bar_pos, BAR_TOKEN_PATTERN, "bar"
    elseif spacer_pos then
        first_pos, first_pattern, kind = spacer_pos, SPACER_TOKEN_PATTERN, "spacer"
    end
    if not first_pattern then
        -- single_line (the status strip): no elastic token, but the line must
        -- stay one line -- truncate instead of wrapping (issue #170). The
        -- truncated TextWidget is sized to its own (clamped) text width, so it
        -- ignores region.alignment on its own; wrap it in the matching alignment
        -- container sized to the full width so left/center/right work again
        -- (issue #182 regression). The ellipsis sits on the end the alignment
        -- does NOT anchor to: right-aligned keeps its right (ellipsis at start),
        -- otherwise keep the left (ellipsis at end).
        if single_line then
            local display   = region.uppercase and TextSegments.upper(expanded) or expanded
            local alignment = region.alignment or "left"
            local seg = _buildSegmentedInline(display, regionFace(region),
                region.bold or false, width, alignment == "right")
            local dimen = Geom:new{ w = width, h = seg:getSize().h }
            if alignment == "center" then
                return CenterContainer:new{ dimen = dimen, seg }
            elseif alignment == "right" then
                return RightContainer:new{ dimen = dimen, seg }
            end
            return LeftContainer:new{ dimen = dimen, seg }
        end
        return buildText(expanded, region, width, max_height)
    end

    -- Split on the FIRST occurrence of the winning token. Defensively
    -- strip any further occurrences of either elastic pattern from the
    -- trailing segment so a hand-edited template containing more than one
    -- doesn't render extras as literal text.
    local before, after = expanded:match("^(.-)" .. first_pattern .. "(.*)$")
    before = before or expanded
    after  = (after or ""):gsub(BAR_TOKEN_PATTERN, ""):gsub(SPACER_TOKEN_PATTERN, "")
    -- Trim LINE-EDGE whitespace only -- leading of `before` and trailing
    -- of `after`. Preserve whatever the user typed at the TOKEN BOUNDARY
    -- (trailing of before, leading of after) so a template like
    -- "%book_pct  %bar  %book_time_left" honours the double space as
    -- visual breathing room. TextWidget renders the spaces as part of
    -- its text, so their pixels contribute to the widget's width and
    -- naturally form the gap to the elastic widget.
    before = before:gsub("^%s+", "")
    after  = after:gsub("%s+$", "")

    local face = regionFace(region)

    -- Build a text side, optionally clamped to max_w (truncates, one line).
    local function mkseg(text, max_w, trunc_left)
        local display = region.uppercase and TextSegments.upper(text) or text
        return _buildSegmentedInline(display, face, region.bold or false, max_w, trunc_left)
    end
    local b_widget = before ~= "" and mkseg(before) or nil
    local a_widget = after  ~= "" and mkseg(after)  or nil
    local b_w = b_widget and b_widget:getSize().w or 0
    local a_w = a_widget and a_widget:getSize().w or 0

    -- Boundary gap: padding.small only kicks in for %bar (the bar has a
    -- visible body that benefits from breathing room from adjacent text)
    -- and only when the user has NOT typed any whitespace at that
    -- boundary. With a typed space, the rendered TextWidget already
    -- contains those pixels and adding more would compound the gap. For
    -- %spacer the elastic widget IS the gap -- adding padding around it
    -- would just shift the right text inward by a few pixels.
    local apply_gap  = (kind == "bar")
    local before_gap = (apply_gap and b_widget and not before:match("%s$")) and Size.padding.small or 0
    local after_gap  = (apply_gap and a_widget and not after:match("^%s"))  and Size.padding.small or 0

    -- #170: a %spacer line must stay on ONE line within `width`. When the two
    -- sides together overflow, the centred HorizontalGroup renders at its
    -- natural (over-)width and spills LEFT over the cover. Truncate to fit,
    -- the RIGHT side first (keep the left text whole); only if the left alone
    -- still doesn't fit is the left truncated too (and the right dropped).
    if kind == "spacer" and (b_w + a_w) > width then
        -- Reserve a little separation so a truncated line reads
        -- "4:27 PM   …right", not "4:27 PM…right" -- the leftover becomes the
        -- elastic span (gap) between the two sides.
        local trunc_gap = Size.padding.large
        if a_widget and (b_w + trunc_gap) < width then
            -- truncate_left: the after-spacer side is right-aligned, so keep its
            -- right-anchored tail and put the ellipsis by the spacer (issue #170).
            a_widget = mkseg(after, math.max(0, width - b_w - trunc_gap), true)
            a_w = a_widget:getSize().w
        else
            a_widget, a_w = nil, 0
            if b_widget then b_widget = mkseg(before, width); b_w = b_widget:getSize().w end
        end
    end

    local used_w    = b_w + a_w
    local elastic_w = math.max(0, width - used_w - before_gap - after_gap)

    if kind == "bar" and elastic_w < 1 then
        -- No room for the bar. Render text only, joined.
        local joined = before
        if after ~= "" then joined = joined ~= "" and (joined .. " " .. after) or after end
        return buildText(joined ~= "" and joined or "", region, width, max_height)
    end

    local elastic_widget
    if kind == "bar" then
        -- Bar height: percentage of the face's nominal point size. The
        -- earlier probe-via-getSize().h approach measured the FULL line
        -- height (height + leading + descender), so 100% rendered ~2x
        -- taller than the visible glyphs -- user reported 50% looked
        -- right, which is roughly the cap height. Using face.size
        -- directly gives the cap-height-ish baseline the user expects,
        -- matching how bookends sizes its own bars. region.bar_height
        -- (default 100 = match text) scales from there.
        local face_size = face.size or region.font_size or 14
        local bar_pct   = region.bar_height or 100
        local bar_h     = math.max(2, math.floor(face_size * bar_pct / 100 + 0.5))
        local pct       = book and book.book_pct or 0
        local style     = region.bar_style or "bordered"
        -- Resolve user-chosen Progress bar / Progress bar track colors for
        -- the hero strip:
        --
        -- * Pacman has a fixed identity baked into bookends's render path
        --   (yellow body, peach pellets) and ignores per-bar color
        --   overrides. Skip the color plumbing entirely for this style
        --   so the user's bar-color picks don't bleed in.
        --
        -- * For every other style, only pass the color fields when the
        --   user has actually picked something. Each bookends style has
        --   its own internal defaults; passing bookshelf's default fill /
        --   track values (dark grey + white) would wash those out for
        --   users who never opened the colors menu.
        local colors
        if style ~= "pacman" then
            local custom_fill  = BookshelfSettings.read("progress_fill")
            local custom_track = BookshelfSettings.read("progress_track")
            if custom_fill or custom_track then
                local Color    = require("lib/bookshelf_color")
                local is_color = Screen:isColorEnabled()
                colors = {
                    fill = custom_fill and Color.parseColorValue(custom_fill, is_color) or nil,
                    bg   = custom_track and Color.parseColorValue(custom_track, is_color) or nil,
                }
            end
        end
        elastic_widget = HeroBar:new{
            width      = elastic_w,
            height     = bar_h,
            percentage = pct,
            style      = style,
            colors     = colors,
        }
    else  -- "spacer"
        elastic_widget = HorizontalSpan:new{ width = elastic_w }
    end

    local hg = HorizontalGroup:new{ align = "center" }
    if b_widget then
        hg[#hg + 1] = b_widget
        if before_gap > 0 then
            hg[#hg + 1] = HorizontalSpan:new{ width = before_gap }
        end
    end
    hg[#hg + 1] = elastic_widget
    if a_widget then
        if after_gap > 0 then
            hg[#hg + 1] = HorizontalSpan:new{ width = after_gap }
        end
        hg[#hg + 1] = a_widget
    end
    return hg
end

-- _buildRightColumn(book, regions, state, dimen) — builds the OverlapGroup
-- that lives to the right of the cover. Both _renderFull and the live
-- preview path call this so renders stay structurally identical.
function HeroCard:_buildRightColumn(book, regions, state, dimen)
    local right_w = dimen.w
    local cover_h = dimen.h

    local right_top    = VerticalGroup:new{ align = "left" }
    local right_bottom = VerticalGroup:new{ align = "left" }

    -- Status (with hairline + small gap below if non-empty). Stash the
    -- three widgets on self so getStatusStripDimen can compute the
    -- combined screen rect after they've been painted once — used to
    -- scope the e-ink refresh footprint on minute-tick / frontlight /
    -- charging / wifi events to just this strip.
    self._status_strip_widgets = nil
    if not regions.status.disabled then
        local status_text = Tokens.expand(regions.status.template, book, state)
        status_text = status_text:gsub("%[/?[biu]%]", "")
        if not Tokens.isEmpty(status_text) then
            local status_widget = buildLine(status_text, regions.status, right_w, book, nil, true)
            local hairline_widget = LineWidget:new{
                dimen      = Geom:new{ w = right_w, h = Size.line.medium },
                background = Blitbuffer.gray(0.4),
            }
            local gap_widget = VerticalSpan:new{ width = Size.padding.default }
            right_top[#right_top + 1] = status_widget
            right_top[#right_top + 1] = hairline_widget
            right_top[#right_top + 1] = gap_widget
            self._status_strip_widgets = { status_widget, hairline_widget, gap_widget }
        end
    end

    -- Rating: a 5-star row, tappable to set / clear the book's rating.
    -- Uses Unicode star glyphs (U+2605 filled / U+2606 outlined) rendered
    -- as TextWidgets rather than mdlight IconWidgets. The SVG icons
    -- collapse into a near-solid blob on Kindle e-ink at hero-region
    -- font sizes, with filled stars rendering indistinguishably from
    -- the white background. Font glyphs hint and render reliably at the
    -- same small sizes the rest of the hero text uses.
    -- Sits ABOVE title/author so the stars anchor to a fixed y position
    -- regardless of how long the title is or whether the author line is
    -- present -- predictable target for tap-to-rate.
    if regions.rating and not regions.rating.disabled and book then
        local hardcover_mode = BookshelfSettings.isTrue("hardcover_hero_rating")
        local rating
        if hardcover_mode then
            rating = tonumber(book.hardcover_rating)
        else
            rating = tonumber(book.rating) or 0
        end
        if (hardcover_mode or self.on_rating_change) and (not hardcover_mode or rating) then
            local star_size = regions.rating.font_size or 16
            local face      = fontFace(nil, hardcover_mode and star_size
                or math.floor(star_size * 1.25 + 0.5))
            local gap       = Screen:scaleBySize(4)
            local row       = HorizontalGroup:new{ align = "center" }
            local hero_self = self
            for i = 1, 5 do
                local glyph
                if hardcover_mode then
                    -- Hardcover ratings are fractional: full / half / empty
                    -- using the Nerd Font glyph set.
                    local whole = math.floor(rating)
                    if i <= whole then
                        glyph = HC_STAR
                    elseif i == whole + 1 and rating - whole >= 0.5 then
                        glyph = HC_HALF_STAR
                    else
                        glyph = HC_EMPTY_STAR
                    end
                else
                    -- The user's own rating stays native integer with plain
                    -- Unicode stars, kept separate from Hardcover's half-stars.
                    glyph = (i <= rating) and "\xE2\x98\x85" or "\xE2\x98\x86"
                end
                local tw = TextWidget:new{
                    text = glyph,
                    face = face,
                    bold = true,
                }
                local sz = tw:getSize()
                if hardcover_mode or not self.on_rating_change then
                    row[#row + 1] = tw
                else
                    local Star = InputContainer:extend{}
                    function Star:onTap()
                        -- Tapping the current rating clears it (matches KOReader's
                        -- BookStatusWidget toggle behaviour).
                        local new_rating
                        if i == rating then
                            new_rating = nil
                        else
                            new_rating = i
                        end
                        hero_self.on_rating_change(hero_self.book, new_rating)
                        return true
                    end
                    local star = Star:new{
                        dimen = Geom:new{ w = sz.w, h = sz.h },
                        tw,
                    }
                    star.ges_events = {
                        Tap = { GestureRange:new{ ges = "tap", range = star.dimen } },
                    }
                    row[#row + 1] = star
                end
                if i < 5 then
                    row[#row + 1] = HorizontalSpan:new{ width = gap }
                end
            end
            if hardcover_mode then
                local reviews_count = tonumber(book.hardcover_reviews_count)
                if reviews_count and reviews_count > 0 then
                    row[#row + 1] = HorizontalSpan:new{ width = gap * 2 }
                    row[#row + 1] = TextWidget:new{
                        text = string.format("%d reviews", reviews_count),
                        face = fontFace(nil, math.max(10, math.floor(star_size * 0.65 + 0.5))),
                        bold = true,
                    }
                end
                if self.on_hardcover_reviews_tap then
                    local RatingTap = InputContainer:extend{}
                    local hero = self
                    function RatingTap:onTap()
                        hero.on_hardcover_reviews_tap(hero.book)
                        return true
                    end
                    local row_size = row:getSize()
                    local tappable = RatingTap:new{
                        dimen = Geom:new{
                            w = right_w,
                            h = row_size and row_size.h or star_size,
                        },
                        row,
                    }
                    tappable.ges_events = {
                        Tap = { GestureRange:new{ ges = "tap", range = tappable.dimen } },
                    }
                    right_top[#right_top + 1] = tappable
                else
                    right_top[#right_top + 1] = row
                end
            else
                right_top[#right_top + 1] = row
            end
        end
    end

    -- Title (rendered after rating so the stars sit at a fixed y above it).
    -- Pre-balance the title text when it would wrap to 2-3 lines, so the
    -- last line isn't a one- or two-word widow. Single-line titles and
    -- titles long enough to span 4+ lines fall through to the natural
    -- greedy wrap.
    if not regions.title.disabled then
        local title_text = Tokens.expand(regions.title.template, book, state)
        title_text = title_text:gsub("%[/?[biu]%]", "")
        if not Tokens.isEmpty(title_text) then
            local title_face = regionFace(regions.title)
            -- Skip widow-balancing when a [font=...] tag is present: balanceLines
            -- measures with the region face (not the tag's) and could split the
            -- tag across lines, breaking buildText's whole-region [font] match.
            -- The title just greedy-wraps in that case (issue #144).
            if not title_text:find("%[font=") then
                title_text = balanceLines(title_text, title_face, right_w,
                                          regions.title.bold or false)
            end
            -- Cap the title so the top block (status/rating already placed +
            -- title + the author/metadata lines still to come) fits the hero.
            -- A long title then truncates with an ellipsis instead of wrapping
            -- unbounded and pushing author/metadata out of a short hero. Tall
            -- heros leave a large cap so normal titles never truncate;
            -- height_adjust keeps short titles tight. Always >= 1 title line.
            local title_lh = (title_face.size or 16) * (1 + (regions.title.line_height or 0.3))
            local top_used = 0  -- status + rating placed above the title so far
            for i = 1, #right_top do
                local g = right_top[i]:getSize()
                top_used = top_used + (g and g.h or 0)
            end
            local function regionLineH(r)
                if not r or r.disabled then return 0 end
                local f = regionFace(r)
                return (f.size or 14) * 1.35
            end
            local reserve = regionLineH(regions.author)
                + regionLineH(regions.metadata) + Size.padding.default * 2
            local max_title_h = math.max(math.floor(title_lh),
                cover_h - top_used - reserve)
            right_top[#right_top + 1] =
                buildLine(title_text, regions.title, right_w, book, max_title_h)
        end
    end

    -- Author
    if not regions.author.disabled then
        local author_text = Tokens.expand(regions.author.template, book, state)
        author_text = author_text:gsub("%[/?[biu]%]", "")
        if not Tokens.isEmpty(author_text) then
            right_top[#right_top + 1] = buildLine(author_text, regions.author, right_w, book)
        end
    end

    -- Metadata (between author and description). Default template is
    -- conditional on series, so books without a series collapse this line
    -- entirely via the Tokens.isEmpty check rather than leaving a blank
    -- vertical gap.
    if regions.metadata and not regions.metadata.disabled then
        local metadata_text = Tokens.expand(regions.metadata.template, book, state)
        metadata_text = metadata_text:gsub("%[/?[biu]%]", "")
        if not Tokens.isEmpty(metadata_text) then
            right_top[#right_top + 1] = buildLine(metadata_text, regions.metadata, right_w, book)
        end
    end

    -- Tags pill strip (above progress, after description). A fresh
    -- widget per rebuild — replaceRightColumn frees the previous right
    -- column, which would tear down the pill widget too if we reused
    -- one. Gap below so the pills don't run straight into the progress
    -- text.
    local tags_n = 0  -- right_bottom elements the tags block contributes (for progressive-hide)
    if regions.tags and not regions.tags.disabled and self.tags_builder then
        local ok, widget = pcall(self.tags_builder, book)
        if ok and widget then
            local sz = widget:getSize()
            if sz and sz.h and sz.h > 0 then
                -- BottomContainer (the parent of right_bottom) centers
                -- its content horizontally. Wrapping the pill widget in a
                -- full-column-width container forces the right column's
                -- effective width to match the column, so the
                -- BottomContainer's own centering offset is zero and the
                -- pills land where the user's alignment setting (#99) puts
                -- them. Default "left" preserves the prior flush-left look.
                local tags_align = (regions.tags and regions.tags.alignment) or "left"
                local AlignContainer = (tags_align == "center" and CenterContainer)
                    or (tags_align == "right" and RightContainer)
                    or LeftContainer
                right_bottom[#right_bottom + 1] = AlignContainer:new{
                    dimen = Geom:new{ w = right_w, h = sz.h },
                    widget,
                }
                -- A little extra breathing room than the usual default gap so
                -- the pills don't crowd the progress line below them.
                right_bottom[#right_bottom + 1] = VerticalSpan:new{
                    width = Size.padding.default + Screen:scaleBySize(4),
                }
                tags_n = 2  -- the AlignContainer + the gap span above
            end
        end
    end

    -- Progress (bottom-anchored). If the book has never been opened
    -- (book.book_pct nil — note that 0 is *truthy* in Lua so a
    -- briefly-opened-but-unread book at 0% still keeps its %bar) the
    -- bar would render at 0% fill, which reads as broken rather than
    -- meaningful. Strip both elastic tokens (%bar AND %spacer) from the
    -- expanded text in that case so the region either collapses
    -- entirely (default template, leaves only whitespace) or reduces to
    -- whatever surrounding text the user typed. Without the %spacer
    -- strip, a template like "Reading%spacer%book_pct" on a never-
    -- opened book renders as a floating "Reading" word with dead space
    -- to its right instead of collapsing.
    if not regions.progress.disabled then
        local progress_text = Tokens.expand(regions.progress.template, book, state)
        progress_text = progress_text:gsub("%[/?[biu]%]", "")
        if not (book and book.book_pct) then
            progress_text = progress_text:gsub("%%bar", ""):gsub("%%spacer", "")
        end
        if not Tokens.isEmpty(progress_text) then
            right_bottom[#right_bottom + 1] = buildLine(progress_text, regions.progress, right_w, book)
        end
    end

    -- Progressive hide: when the hero is too short to fit the top block
    -- (status/rating/title/author/metadata) AND the bottom block, trim the
    -- bottom block — tags first (least essential), then the progress line —
    -- until they fit cover_h. This is the same idea the description already
    -- uses (it self-limits to leftover slack); extending it to tags/progress
    -- keeps title/author readable when a small hero (e.g. after a pinch-zoom
    -- to many columns + rows) would otherwise cram the regions on top of each
    -- other. Title/author/metadata are kept; the description, added next,
    -- budgets itself against whatever bottom block survives.
    do
        local breath = Size.padding.default
        -- Sum child heights directly rather than calling the GROUP's getSize():
        -- the group caches per-child paint offsets on getSize(), and the
        -- description is appended to right_top AFTER this, so a premature group
        -- getSize() here would leave the offset table one short at paint time
        -- (nil-index crash). Per-child getSize() is safe — those children don't
        -- change.
        local function sumChildren(group)
            local h = 0
            for i = 1, #group do
                local g = group[i].getSize and group[i]:getSize()
                h = h + (g and g.h or 0)
            end
            return h
        end
        local function overflows()
            return (sumChildren(right_top) + sumChildren(right_bottom) + breath) > cover_h
        end
        if overflows() and tags_n > 0 then
            for _i = 1, tags_n do table.remove(right_bottom, 1) end
            if right_bottom.resetLayout then right_bottom:resetLayout() end
            tags_n = 0
        end
        if overflows() then
            while #right_bottom > 0 do table.remove(right_bottom) end
            if right_bottom.resetLayout then right_bottom:resetLayout() end
        end
    end

    -- Description (fills the slack between right_top and right_bottom)
    local desc_text = ""
    if not regions.description.disabled then
        desc_text = Tokens.expand(regions.description.template, book, state)
        desc_text = desc_text:gsub("%[/?[biu]%]", "")
        -- Normalize line endings, then clamp any run of newlines mixed
        -- with whitespace-only lines down to a clean \n\n paragraph break.
        -- EPUB descriptions sometimes emit \n \n or \n\t\n (a "blank" line
        -- that's actually whitespace), which our paragraph splitter would
        -- otherwise miss — and the whitespace-only line then renders at
        -- a full 1.3× line height inside a single TextBoxWidget,
        -- defeating the per-paragraph spacing below. \n stays as a soft
        -- line break; \n\n marks a paragraph (its own TextBoxWidget).
        desc_text = desc_text:gsub("\r\n", "\n")
        desc_text = desc_text:gsub("\n%s*\n", "\n\n")
        desc_text = desc_text:match("^%s*(.-)%s*$") or desc_text
    end
    if not Tokens.isEmpty(desc_text) then
        right_top[#right_top + 1] = VerticalSpan:new{ width = Size.padding.default }
        local top_used = 0
        for i = 1, #right_top do
            local g = right_top[i]:getSize()
            top_used = top_used + (g and g.h or 0)
        end
        local bottom_h = right_bottom:getSize().h
        local breath   = Size.padding.default
        local available = cover_h - top_used - bottom_h - breath
        if available > Screen:scaleBySize(40) then
            local desc_face  = regionFace(regions.description)
            local desc_bold  = regions.description.bold or false
            local desc_align = regions.description.alignment or "left"
            -- ~40% of body font size — enough to mark a paragraph onset
            -- without eating a full empty line (which would be 1.3× the
            -- font size and cost too much of the limited slot).
            local para_gap = math.floor(desc_face.size * 0.4)

            -- Split on \n\n (paragraph breaks). \n inside a paragraph
            -- stays as a soft line break inside that paragraph's TextBox.
            local paragraphs = {}
            for para in (desc_text .. "\n\n"):gmatch("(.-)\n\n") do
                if para ~= "" then paragraphs[#paragraphs + 1] = para end
            end

            local desc_group = VerticalGroup:new{ align = "left" }
            local total_h = 0
            for i, ptext in ipairs(paragraphs) do
                local gap = (i > 1) and para_gap or 0
                if total_h + gap >= available then break end
                local rem = available - total_h - gap
                if rem < desc_face.size then break end
                if gap > 0 then
                    desc_group[#desc_group + 1] =
                        VerticalSpan:new{ width = gap }
                    total_h = total_h + gap
                end
                local pwid = TextBoxWidget:new{
                    text                          = ptext,
                    face                          = desc_face,
                    bold                          = desc_bold,
                    width                         = right_w,
                    height                        = rem,
                    alignment                     = desc_align,
                    height_overflow_show_ellipsis = true,
                    -- height_adjust shrinks the widget to the natural
                    -- text_height when the content is shorter than the
                    -- height cap, so subsequent paragraphs aren't pushed
                    -- below an empty reservation.
                    height_adjust                 = true,
                    -- 1.3× line height. line_height_px = (1+line_height)
                    -- * face.size; pinned here so it can't drift if the
                    -- TextBoxWidget default ever shifts.
                    line_height                   = 0.3,
                }
                desc_group[#desc_group + 1] = pwid
                total_h = total_h + pwid:getSize().h
            end
            if #desc_group > 0 then
                -- Tappable wrapper: tapping the description opens the
                -- full text in a scrollable viewer. Useful when the
                -- hero's height budget truncated the blurb (ellipsis at
                -- the end). The wrapper consumes the tap so the
                -- parent's "tap hero -> open book" doesn't fire here.
                if self.on_description_tap then
                    local DescTap = InputContainer:extend{}
                    local hero    = self
                    function DescTap:onTap()
                        hero.on_description_tap(hero.book)
                        return true
                    end
                    local desc_size = desc_group:getSize()
                    local tap_w     = right_w
                    local tap_h     = desc_size and desc_size.h or 0
                    if tap_h > 0 then
                        local tappable = DescTap:new{
                            dimen = Geom:new{ w = tap_w, h = tap_h },
                            desc_group,
                        }
                        tappable.ges_events = {
                            -- Key MUST be "Tap" so InputContainer:onGesture's
                            -- eventname (= key) dispatches Event("Tap"), which
                            -- routes to DescTap:onTap. With any other key the
                            -- match emits an event no handler listens for, the
                            -- tap isn't consumed, and HeroCard's outer dispatch
                            -- can fire the cover SpineWidget's onTap as a side
                            -- effect (opening the book instead of the viewer).
                            Tap = {
                                GestureRange:new{
                                    ges = "tap",
                                    range = tappable.dimen,
                                },
                            },
                        }
                        right_top[#right_top + 1] = tappable
                    else
                        right_top[#right_top + 1] = desc_group
                    end
                else
                    right_top[#right_top + 1] = desc_group
                end
            end
        end
    end

    local rd = Geom:new{ w = right_w, h = cover_h }
    -- No background fill: lets parent (and any theme plugin's themed bg) show
    -- through. The earlier paper-white wipe was intended to prevent ghosting
    -- when a region's text re-wraps between renders, but ghosting hasn't been
    -- observed in practice and the white wipe clashes with applied themes.
    return FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        width      = rd.w,
        height     = rd.h,
        OverlapGroup:new{
            dimen = rd,
            TopContainer:new{    dimen = rd, right_top },
            BottomContainer:new{ dimen = rd, right_bottom },
        },
    }
end

function HeroCard:_renderFull()
    local cover_h = self.cover_h or self.height

    -- SpineWidget's BorderOverlay (drawn when is_selected) paints at
    -- (-SHADOW_OFFSET, -SHADOW_OFFSET) relative to its own origin -- it
    -- extends OUTSIDE the spine widget on the top and left edges,
    -- relying on the parent context having that much outer breathing
    -- room available. Shelf rows accommodate this naturally; the hero
    -- cover sits flush against the hero card's top-left with nothing
    -- outside, so the top and left edges of the selection border got
    -- clipped (reporter on the test branch).
    --
    -- Reserve the SHADOW_OFFSET on top + left by wrapping the
    -- SpineWidget in a FrameContainer that pushes the cover down-right
    -- by SHADOW_OFFSET. The BorderOverlay's outward paint then lands
    -- inside the wrapper's bounds. Shrink the SpineWidget by
    -- SHADOW_OFFSET in each dimension so the outer cover footprint
    -- stays unchanged (the hero layout was sized for cover_w x cover_h).
    local SHADOW_OFFSET = Screen:scaleBySize(4)

    local cover = SpineWidget:new{
        book        = self.book,
        width       = self.cover_w - SHADOW_OFFSET,
        height      = cover_h - SHADOW_OFFSET,
        on_tap      = self.on_tap,
        on_hold     = self.on_hold,
        is_selected      = self.is_selected,
        is_bulk_selected = self.is_bulk_selected,
        suppress_favorite_badge = true,
        -- Cache the scaled hero cover in ScaledCoverCache (issue #103).
        -- Previously skipped to avoid pinning one oversized entry, but the
        -- cost of NOT caching is far worse: the hero is rebuilt on every
        -- show / chip-switch / book-close, and each rebuild re-acquires the
        -- source cover via a BIM getBookInfo read. On Kobo the bookinfo_cache
        -- is non-WAL, so that SELECT blocks on any concurrent cover-extraction
        -- writer (coverbrowser, our own kickoff, the stale-sweep) for up to
        -- BIM's 5s busy_timeout -- producing the multi-second hero stalls in
        -- the report. Caching lets repeat renders paint from the in-memory
        -- scaled bb (paired with _buildHero's record memo, which skips the
        -- read entirely). One hero-sized entry is bounded by the cache's byte
        -- budget and evicted LRU like any other, so the displacement worry
        -- is negligible against eliminating the per-cycle blocking read.
    }
    local cover_widget = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = SHADOW_OFFSET,
        padding_left = SHADOW_OFFSET,
        cover,
    }

    local text_padding = self.pad or Size.padding.fullscreen
    -- #87 belt-and-braces: floor at 1 so a too-wide cover (from any caller)
    -- can never hand the right-column TextWidgets a max_width <= 0, which
    -- aborts makeLine natively. The real fix caps cover_w upstream in
    -- bookshelf_widget._rebuild; this just guarantees the abort is impossible.
    local right_w = math.max(1, self.width - self.cover_w - text_padding)

    local regions = Regions.read()
    local right = self:_buildRightColumn(
        self.book, regions, self.device_state,
        Geom:new{ w = right_w, h = cover_h })

    -- Stash the outer HorizontalGroup + right slot index so the live
    -- preview path can swap [3] without rebuilding the cover.
    local hg = HorizontalGroup:new{
        align = "top",
        cover_widget,
        HorizontalSpan:new{ width = text_padding },
        right,
    }
    self._right_holder    = hg
    self._right_slot      = 3
    self._right_dimen     = Geom:new{ w = right_w, h = cover_h }
    return hg
end

-- getStatusStripDimen() — returns the combined screen rect of the status
-- text + hairline + gap (the top strip of the right column), or nil if
-- status is empty/disabled or the strip hasn't been painted yet. Used by
-- the BookshelfWidget's status-tick + state-event refreshes to scope the
-- e-ink panel update to the strip rather than the whole right column.
function HeroCard:getStatusStripDimen()
    local s = self._status_strip_widgets
    if not s or not s[1] or not s[1].dimen then return nil end
    local status, hairline, gap = s[1], s[2], s[3]
    local h = status.dimen.h
    if hairline and hairline.dimen then h = h + hairline.dimen.h end
    if gap      and gap.dimen      then h = h + gap.dimen.h      end
    return Geom:new{
        x = status.dimen.x,
        y = status.dimen.y,
        w = status.dimen.w,
        h = h,
    }
end

-- replaceRightColumn(regions, book, state, region_hint)
--   Swaps the right OverlapGroup with a fresh build from the supplied
--   regions table. Returns (ok, refresh_rect):
--     ok  — true on success, false when the holder hasn't been built yet
--           (empty-state hero).
--     refresh_rect — Geom in screen coordinates of the area that actually
--           needs panel refresh. Caller passes this to setDirty so the
--           e-ink update is bounded:
--             * region_hint == "status"  → just the status strip rect;
--             * any other hint / nil      → the whole right column rect;
--             * may itself be nil on the very first swap (before any
--               paint has populated dimens) — caller falls back to a
--               full-widget setDirty in that case.
--   region_hint must be captured BEFORE the swap because afterwards
--   self._status_strip_widgets points at the new (un-painted) widgets
--   whose dimens aren't set yet.
function HeroCard:replaceRightColumn(regions, book, state, region_hint)
    if not self._right_holder or not self._right_dimen then return false end
    local refresh_rect
    if region_hint == "status" then
        refresh_rect = self:getStatusStripDimen()
    end
    local fresh = self:_buildRightColumn(book or self.book, regions,
        state or self.device_state, self._right_dimen)
    local old = self._right_holder[self._right_slot]
    self._right_holder[self._right_slot] = fresh
    if self._right_holder.resetLayout then self._right_holder:resetLayout() end
    -- Fallback when the status-strip rect wasn't applicable: refresh
    -- the FULL right column. We take the painted screen rect from the
    -- old column for the x/y origin (HorizontalGroup's layout doesn't
    -- shift on slot replacement, so the new column paints there too)
    -- but expand w/h to the full right-column bound (self._right_dimen)
    -- to avoid tearing when the new column is taller than the old one
    -- — e.g. font-size edits that grow widget heights would otherwise
    -- leave the bottom strip un-refreshed.
    if not refresh_rect and old and old.dimen and self._right_dimen then
        refresh_rect = Geom:new{
            x = old.dimen.x,
            y = old.dimen.y,
            w = self._right_dimen.w,
            h = self._right_dimen.h,
        }
    elseif not refresh_rect then
        refresh_rect = old and old.dimen
    end
    if old and old.free then
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function() pcall(function() old:free() end) end)
    end
    return true, refresh_rect
end

function HeroCard:onTap(_, ges)
    -- Open-book is wired only on the SpineWidget (cover) so the description,
    -- star rating, and other interactive regions own their tap zones without
    -- conflict. Taps elsewhere on the hero are absorbed (return true) — only
    -- the top strip falls through so the FM touch-zone walk in
    -- BookshelfWidget:handleEvent can reach KOReader's top-menu zone.
    if ges and ges.pos and ges.pos.y < Screen:scaleBySize(60) then
        return false
    end
    return true
end
function HeroCard:onHold() if self.on_hold then self.on_hold(self.book) end; return true end

return HeroCard
