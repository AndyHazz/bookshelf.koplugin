-- bookshelf_hero_card.lua
-- Currently-reading detail card: cover thumbnail + an editable right column
-- composed from five region templates (status / title / author / description
-- / progress). All region styling and content is driven by hero_regions.

local FrameContainer  = require("ui/widget/container/framecontainer")
local InputContainer  = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
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
local Blitbuffer      = require("ffi/blitbuffer")
local Screen          = require("device").screen
local SpineWidget     = require("bookshelf_spine_widget")
local Tokens          = require("bookshelf_tokens")
local Regions         = require("bookshelf_hero_regions")
local HeroBar         = require("bookshelf_hero_bar")

local HeroCard = InputContainer:extend{
    book         = nil,
    width        = nil,
    height       = nil,
    cover_w      = 116,
    cover_h      = nil,
    pad          = nil,
    device_state = nil,
    on_tap       = nil,
    on_hold      = nil,
}

-- Reads the user's font-scale setting (% of nominal). Applied on top of
-- per-region font_size so the user can dial the whole hero up or down.
-- Defensive fallback: if Font:getFace errors or returns nil for the
-- requested face_name (e.g. a stale "@family:serif" sentinel from a
-- prior bookends-picker tap, or a font file that has since been
-- removed from the filesystem), drop back to "infofont" so the render
-- never crashes on a missing face.
local function fontFace(face_name, base)
    local scale = (G_reader_settings:readSetting("bookshelf_font_scale") or 100) / 100
    local size = math.max(8, math.floor(base * scale + 0.5))
    if face_name then
        local ok, face = pcall(Font.getFace, Font, face_name, size)
        if ok and face then return face end
    end
    return Font:getFace("infofont", size)
end

local BAR_TOKEN_PATTERN = "%%bar"

function HeroCard:init()
    self.cover_h = self.cover_h or self.height
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if not self.book then
        self[1] = self:_renderEmpty()
    else
        self[1] = self:_renderFull()
    end
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
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

-- Build a TextBoxWidget for a single region using the resolved settings.
local function buildText(text, region, width)
    local rendered = text
    if region.uppercase then rendered = rendered:upper() end
    return TextBoxWidget:new{
        text      = rendered,
        face      = regionFace(region),
        bold      = region.bold or false,
        width     = width,
        alignment = region.alignment or "left",
    }
end

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
    vg[#vg + 1] = buildText(status_text, regions.status, width)
    if with_hairline then
        vg[#vg + 1] = LineWidget:new{
            dimen      = Geom:new{ w = width, h = Size.line.medium },
            background = Blitbuffer.gray(0.4),
        }
        vg[#vg + 1] = VerticalSpan:new{ width = Size.padding.default }
    end
    return vg
end

-- Build a HorizontalGroup of [text-before, BarWidget, text-after] when the
-- progress template contains %bar. If no %bar, returns a plain TextBoxWidget.
local function buildProgressLine(expanded, region, width, book)
    local has_bar = expanded:find(BAR_TOKEN_PATTERN) ~= nil
    if not has_bar then
        return buildText(expanded, region, width)
    end
    -- Split on the FIRST %bar; defensively strip any further %bar tokens
    -- from the trailing segment so a hand-edited template containing two
    -- doesn't render the second as literal text.
    local before, after = expanded:match("^(.-)%%bar(.*)$")
    before = before or expanded
    after  = (after or ""):gsub("%%bar", "")
    -- Trim LINE-EDGE whitespace only — leading of `before` and trailing
    -- of `after`. Preserve whatever the user typed at the BAR BOUNDARY
    -- (trailing of before, leading of after) so a template like
    -- "%book_pct  %bar  %book_time_left" honours the double space as
    -- visual breathing room. TextWidget renders the spaces as part of
    -- its text, so their pixels contribute to the widget's width and
    -- naturally form the gap to the bar.
    before = before:gsub("^%s+", "")
    after  = after:gsub("%s+$", "")

    local face = regionFace(region)

    local used_w = 0
    local b_widget = nil
    if before ~= "" then
        local display = region.uppercase and before:upper() or before
        b_widget = TextWidget:new{ text = display, face = face, bold = region.bold or false }
        used_w = used_w + b_widget:getSize().w
    end
    local a_widget = nil
    if after ~= "" then
        local display = region.uppercase and after:upper() or after
        a_widget = TextWidget:new{ text = display, face = face, bold = region.bold or false }
        used_w = used_w + a_widget:getSize().w
    end

    -- Bar height: percentage of the face's nominal point size. The earlier
    -- probe-via-getSize().h approach measured the FULL line height (height
    -- + leading + descender), so 100% rendered ~2x taller than the visible
    -- glyphs — user reported 50% looked right, which is roughly the cap
    -- height. Using face.size directly gives the cap-height-ish baseline
    -- the user expects, matching how bookends sizes its own bars. region.
    -- bar_height (default 100 = match text) scales from there.
    local face_size = face.size or region.font_size or 14
    local bar_pct   = region.bar_height or 100
    local bar_h     = math.max(2, math.floor(face_size * bar_pct / 100 + 0.5))
    -- Boundary gap: padding.small only kicks in when the user has NOT
    -- typed any whitespace at that boundary. With a typed space (or
    -- two), the rendered TextWidget already contains those pixels and
    -- adding more would compound the gap. Without one,
    -- padding.small keeps "%book_pct%bar" from looking welded.
    local before_gap = (b_widget and not before:match("%s$")) and Size.padding.small or 0
    local after_gap  = (a_widget and not after:match("^%s"))  and Size.padding.small or 0
    local bar_w = math.max(0, width - used_w - before_gap - after_gap)

    local pct = book and book.book_pct or 0

    if bar_w < 1 then
        -- No room for bar. Render text only, joined.
        local joined = before
        if after ~= "" then joined = joined ~= "" and (joined .. " " .. after) or after end
        return buildText(joined ~= "" and joined or "", region, width)
    end

    local bar = HeroBar:new{
        width      = bar_w,
        height     = bar_h,
        percentage = pct,
        style      = region.bar_style or "bordered",
    }

    local hg = HorizontalGroup:new{ align = "center" }
    if b_widget then
        hg[#hg + 1] = b_widget
        if before_gap > 0 then
            hg[#hg + 1] = HorizontalSpan:new{ width = before_gap }
        end
    end
    hg[#hg + 1] = bar
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
            local status_widget = buildText(status_text, regions.status, right_w)
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

    -- Title
    if not regions.title.disabled then
        local title_text = Tokens.expand(regions.title.template, book, state)
        title_text = title_text:gsub("%[/?[biu]%]", "")
        if not Tokens.isEmpty(title_text) then
            right_top[#right_top + 1] = buildText(title_text, regions.title, right_w)
        end
    end

    -- Author
    if not regions.author.disabled then
        local author_text = Tokens.expand(regions.author.template, book, state)
        author_text = author_text:gsub("%[/?[biu]%]", "")
        if not Tokens.isEmpty(author_text) then
            right_top[#right_top + 1] = buildText(author_text, regions.author, right_w)
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
            right_top[#right_top + 1] = buildText(metadata_text, regions.metadata, right_w)
        end
    end

    -- Progress (bottom-anchored). If the book has never been opened
    -- (book.book_pct nil — note that 0 is *truthy* in Lua so a
    -- briefly-opened-but-unread book at 0% still keeps its %bar) the
    -- bar would render at 0% fill, which reads as broken rather than
    -- meaningful. Strip %bar from the expanded text in that case so the
    -- region either collapses entirely (default template, leaves only
    -- whitespace) or reduces to whatever surrounding text the user
    -- typed.
    if not regions.progress.disabled then
        local progress_text = Tokens.expand(regions.progress.template, book, state)
        progress_text = progress_text:gsub("%[/?[biu]%]", "")
        if not (book and book.book_pct) then
            progress_text = progress_text:gsub("%%bar", "")
        end
        if not Tokens.isEmpty(progress_text) then
            right_bottom[#right_bottom + 1] = buildProgressLine(progress_text, regions.progress, right_w, book)
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
                right_top[#right_top + 1] = desc_group
            end
        end
    end

    local rd = Geom:new{ w = right_w, h = cover_h }
    -- Wrap in a FrameContainer with a paper-white background so each
    -- rebuild paints WHITE over the right-column area BEFORE the
    -- children paint. Without this, when a region's rendered text moves
    -- up/down/wraps differently between renders (most visibly when the
    -- user types more whitespace into a template), the old pixels at
    -- positions the new content doesn't repaint remain on the
    -- framebuffer and the panel refresh shows old + new overlaid as
    -- "double" text. FrameContainer.paintTo paints background first
    -- then walks children — so the wipe happens for free at no extra
    -- paint pass.
    return FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        background = Blitbuffer.COLOR_WHITE,
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

    local cover = SpineWidget:new{
        book   = self.book,
        width  = self.cover_w,
        height = cover_h,
        on_tap = self.on_tap,
        on_hold = self.on_hold,
    }
    local cover_widget = cover

    local text_padding = self.pad or Size.padding.fullscreen
    local right_w = self.width - self.cover_w - text_padding

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
    -- Let taps in the top strip fall through to the FM touch-zone walk in
    -- BookshelfWidget:handleEvent, where KOReader's top-menu zone lives.
    if ges and ges.pos and ges.pos.y < Screen:scaleBySize(60) then
        return false
    end
    if self.on_tap then self.on_tap(self.book) end
    return true
end
function HeroCard:onHold() if self.on_hold then self.on_hold(self.book) end; return true end

return HeroCard
