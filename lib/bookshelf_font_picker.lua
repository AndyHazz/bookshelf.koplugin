-- bookshelf_font_picker.lua
-- The font picker: one row per font family, each drawn in its own typeface,
-- paged ten to a page. Ported from bookends' showFontPicker (issue 450).
-- Bookshelf used to borrow that one when bookends was installed and fall back
-- to a Menu of raw file paths otherwise, which listed every weight as its own
-- row with no preview -- and, reading FontList:getFontList() rather than
-- FontList.fontinfo, every file in the font folders, including ones FreeType
-- cannot open (Kobo's encrypted system fonts under /mnt/onboard/fonts/kobo).
--
-- Differences from the bookends original: no "@family:" rows (those resolve
-- through CRengine's font-family settings, which only exist inside the
-- Reader), bookshelf's own pagination row, and a current face given as a bare
-- file name (the bundled fonts are named that way) still finds its row.
--
-- show(current_face, on_select, default_face)
--   on_select(file) fires on every tap, so callers preview live; Close and a
--   tap outside revert to current_face, Reset picks default_face (nil means
--   "follow KOReader" for callers that have no default file), Done keeps.

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Size            = require("ui/size")
local TextWidget      = require("lib/bookshelf_colour_text")
local TopContainer    = require("ui/widget/container/topcontainer")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local logger          = require("logger")
local Space           = require("lib/bookshelf_space")
local Screen          = Device.screen
local _               = require("lib/bookshelf_i18n").gettext

local FontPicker = {}

local VARIANT_WORDS = { "light", "thin", "heavy", "black", "medium", "semibold",
    "extrabold", "extralight", "ultralight", "demibold", "book" }

-- families(FontList) -> sorted list of {file=, name=}, plus family -> entry.
-- One entry per family, preferring its Regular. A family with only bold or
-- italic files (script fonts that are italic by design) keeps its best
-- variant, so it stays pickable. Fonts FreeType cannot load are left out.
function FontPicker.families(FontList)
    local base, variant = {}, {}
    for file, info_list in pairs(FontList.fontinfo or {}) do
        local info = info_list and info_list[1]
        if info then
            local lbase = (file:match("([^/]+)$") or ""):lower()
            local is_variant = info.bold or info.italic
                or lbase:find("bold") or lbase:find("italic") or lbase:find("oblique")
            -- By family name ("Amazon Ember"), not the per-weight localised
            -- one ("Amazon Ember Bold"), or every weight gets its own bucket.
            local name = info.name or FontList:getLocalizedFontName(file, 0)
            if name then
                local rank = 0
                if info.bold then rank = rank + 2 end
                if info.italic then rank = rank + 2 end
                if lbase:find("regular") then
                    rank = rank - 1
                elseif lbase:find("bold") or lbase:find("italic") or lbase:find("oblique") then
                    rank = rank + 2
                else
                    for _i, w in ipairs(VARIANT_WORDS) do
                        if lbase:find(w, 1, true) then rank = rank + 1; break end
                    end
                end
                local bucket = is_variant and variant or base
                local prev = bucket[name]
                -- Ties go to the shorter path, so the pick does not depend
                -- on pairs() order.
                if not prev or rank < prev.rank
                        or (rank == prev.rank and file < prev.file) then
                    bucket[name] = { file = file, name = name, rank = rank }
                end
            end
        end
    end
    local by_family = {}
    for name, e in pairs(base) do by_family[name] = e end
    for name, e in pairs(variant) do
        if not by_family[name] then by_family[name] = e end
    end
    local list, skipped = {}, 0
    for _name, e in pairs(by_family) do
        if Font:getFace(e.file, 12) then
            list[#list + 1] = e
        else
            skipped = skipped + 1
        end
    end
    local ok_u, ffiUtil = pcall(require, "ffi/util")
    local coll = ok_u and ffiUtil.strcoll or function(a, b) return a < b end
    table.sort(list, function(a, b)
        if a.name == b.name then return a.file < b.file end
        return coll(a.name, b.name)
    end)
    if skipped > 0 then
        logger.info(string.format(
            "bookshelf: font picker skipped %d font(s) that FreeType couldn't load", skipped))
    end
    return list, by_family
end

-- visibleFace(face, list, by_family, FontList) -> the listed file standing
-- for `face`: itself if listed, its family's pick if it is another weight,
-- or the listed file with the same name if it came as a bare file name.
function FontPicker.visibleFace(face, list, by_family, FontList)
    if type(face) ~= "string" then return face end
    for _i, e in ipairs(list) do
        if e.file == face then return face end
    end
    local info = FontList.fontinfo and FontList.fontinfo[face]
    if info and info[1] then
        local name = FontList:getLocalizedFontName(face, 0) or info[1].name
        if name and by_family[name] then return by_family[name].file end
        if info[1].name and by_family[info[1].name] then
            return by_family[info[1].name].file
        end
    end
    if not face:find("/", 1, true) then
        for file, _l in pairs(FontList.fontinfo or {}) do
            if file:match("([^/]+)$") == face then
                return FontPicker.visibleFace(file, list, by_family, FontList)
            end
        end
    end
    return face
end

function FontPicker.show(current_face, on_select, default_face)
    local FontList = require("fontlist")
    local fonts, by_family = FontPicker.families(FontList)
    local names = {}
    for _i, f in ipairs(fonts) do names[f.file] = f.name end

    local original_face = current_face
    local selected = FontPicker.visibleFace(current_face, fonts, by_family, FontList)
    default_face = FontPicker.visibleFace(default_face, fonts, by_family, FontList)
    local function pick(face)
        selected = face
        -- The caller's own value when that is what was picked back, so a
        -- revert hands back exactly what it was given.
        if face == FontPicker.visibleFace(original_face, fonts, by_family, FontList) then
            on_select(original_face)
        else
            on_select(face)
        end
    end

    local per_page = 10
    local total_pages = math.max(1, math.ceil(#fonts / per_page))
    local page = 1
    for i, f in ipairs(fonts) do
        if f.file == selected then page = math.ceil(i / per_page); break end
    end

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local width = math.floor(math.min(screen_w, screen_h) * 0.9)
    local font_size = 22
    local row_height = Screen:scaleBySize(42)
    local left_pad = Space.padding.large
    local check_width = Screen:scaleBySize(30)

    local picker

    local function buildPage()
        -- "Pick font: <name>", the name in its own typeface.
        local title_row_height = Screen:scaleBySize(48)
        local title_baseline = math.floor(title_row_height * 0.7)
        local title_text = TextWidget:new{
            text = _("Pick font") .. ": ",
            face = Font:getFace("infofont", font_size),
            fgcolor = Blitbuffer.COLOR_BLACK,
            bold = true,
            forced_height = title_row_height,
            forced_baseline = title_baseline,
        }
        local name_face = selected and Font:getFace(selected, font_size)
                          or Font:getFace("cfont", font_size)
        local name_widget = TextWidget:new{
            text = selected and (names[selected] or selected:match("([^/]+)$") or selected)
                   or _("Default"),
            face = name_face,
            max_width = width - title_text:getWidth() - 2 * left_pad,
            fgcolor = Blitbuffer.COLOR_BLACK,
            forced_height = title_row_height,
            forced_baseline = title_baseline,
        }
        local title_row = LeftContainer:new{
            dimen = Geom:new{ w = width, h = title_row_height },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = left_pad },
                title_text,
                name_widget,
            },
        }

        local list_group = VerticalGroup:new{ align = "left" }
        local baseline = math.floor(row_height * 0.65)
        local first = (page - 1) * per_page + 1
        for i = first, math.min(first + per_page - 1, #fonts) do
            local f = fonts[i]
            local is_selected = f.file == selected
            -- A face that loaded for the check above can still fail here
            -- (cache eviction, a file removed since); the row falls back to
            -- the UI font rather than failing the page.
            local face = Font:getFace(f.file, font_size) or Font:getFace("cfont", font_size)
            local label = f.name .. ((f.file == default_face) and "  \xE2\x98\x85" or "")
            local row = InputContainer:new{
                dimen = Geom:new{ w = width, h = row_height },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = left_pad },
                    CenterContainer:new{
                        dimen = Geom:new{ w = check_width, h = row_height },
                        TextWidget:new{
                            -- A radio mark, as KOReader's own RadioMark draws
                            -- it: only one font is ever the chosen one, so a
                            -- tick (which reads as "any number of these") was
                            -- the wrong control.
                            text = is_selected and "\xE2\x97\x89 " or "\xE2\x97\xAF ",
                            face = Font:getFace("cfont", font_size),
                            forced_height = row_height,
                            forced_baseline = baseline,
                            fgcolor = Blitbuffer.COLOR_BLACK,
                            bold = true,
                        },
                    },
                    TextWidget:new{
                        text = label,
                        face = face,
                        forced_height = row_height,
                        forced_baseline = baseline,
                        max_width = width - 2 * left_pad - check_width,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        bold = is_selected,
                    },
                },
            }
            row.ges_events = {
                TapSelect = { GestureRange:new{ ges = "tap", range = row.dimen } },
            }
            local file = f.file
            row.onTapSelect = function()
                pick(file)
                picker:rebuild()
                return true
            end
            list_group[#list_group + 1] = row
        end

        local page_nav = require("lib/bookshelf_pagination").buildNav{
            page = page,
            total_pages = total_pages,
            on_goto = function(p) page = p; picker:rebuild() end,
            show_parent = picker,
        }
        local actions = ButtonTable:new{
            width = width - 2 * Space.padding.default,
            buttons = {{
                {
                    text = _("Close"),
                    callback = function() picker:revertAndClose() end,
                },
                {
                    text = _("Reset"),
                    enabled = selected ~= default_face,
                    callback = function()
                        selected = default_face
                        on_select(default_face)
                        UIManager:close(picker)
                    end,
                },
                {
                    text = _("Done"),
                    is_enter_default = true,
                    callback = function() UIManager:close(picker) end,
                },
            }},
            zero_sep = true,
            show_parent = picker,
        }

        return FrameContainer:new{
            radius = Space.radius.window,
            bordersize = Size.border.window,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{
                align = "center",
                title_row,
                LineWidget:new{
                    background = Blitbuffer.COLOR_BLACK,
                    dimen = Geom:new{ w = width, h = Size.line.thick },
                },
                TopContainer:new{
                    dimen = Geom:new{ w = width, h = per_page * row_height },
                    list_group,
                },
                CenterContainer:new{
                    dimen = Geom:new{ w = width, h = Size.line.thin },
                    LineWidget:new{
                        background = Blitbuffer.COLOR_DARK_GRAY,
                        dimen = Geom:new{ w = width - 2 * Space.padding.default, h = Size.line.thin },
                    },
                },
                VerticalSpan:new{ width = Space.span.vertical_default },
                CenterContainer:new{
                    dimen = Geom:new{ w = width, h = page_nav:getSize().h },
                    page_nav,
                },
                VerticalSpan:new{ width = Space.span.vertical_default },
                CenterContainer:new{
                    dimen = Geom:new{ w = width, h = actions:getSize().h },
                    actions,
                },
            },
        }
    end

    picker = InputContainer:new{
        ges_events = {
            TapClose = { GestureRange:new{ ges = "tap",
                range = Geom:new{ w = screen_w, h = screen_h } } },
            Swipe = { GestureRange:new{ ges = "swipe",
                range = Geom:new{ w = screen_w, h = screen_h } } },
        },
    }

    function picker:revertAndClose()
        if selected ~= FontPicker.visibleFace(original_face, fonts, by_family, FontList) then
            on_select(original_face)
        end
        UIManager:close(self)
    end

    function picker:rebuild()
        local ok, frame = xpcall(buildPage, debug.traceback)
        if not ok then
            logger.warn("bookshelf: font picker failed to build:", frame)
            UIManager:close(self)
            return
        end
        self[1] = CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            frame,
        }
        self.frame = frame
        UIManager:setDirty(self, "ui")
    end

    function picker:onSwipe(_arg, ges_ev)
        local dir = ges_ev.direction
        if (dir == "west" or dir == "north") and page < total_pages then
            page = page + 1
            self:rebuild()
        elseif (dir == "east" or dir == "south") and page > 1 then
            page = page - 1
            self:rebuild()
        end
        return true
    end

    function picker:onTapClose(_arg, ges_ev)
        if self.frame and ges_ev.pos and not ges_ev.pos:intersectWith(self.frame.dimen) then
            self:revertAndClose()
            return true
        end
        return false
    end

    function picker:onShow()
        UIManager:setDirty(self, "ui")
        return true
    end

    function picker:onCloseWidget()
        UIManager:setDirty(nil, "ui")
    end

    picker:rebuild()
    UIManager:show(picker)
    return picker
end

return FontPicker
