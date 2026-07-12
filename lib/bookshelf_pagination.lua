-- bookshelf_pagination.lua
-- Shared pagination control: the first / prev / "Page X of Y" / next / last row
-- used by the LibraryModal (the tag + genre picker) and the collection manager,
-- so both read identically (same chevron set, font, and spacing). Returns just
-- the chevron HorizontalGroup; callers frame it (dividers / spacing) themselves.

local Button          = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Device          = require("device")
local Screen          = Device.screen
local T               = require("ffi/util").template
local _               = require("lib/bookshelf_i18n").gettext

local Pagination = {}

-- buildNav(opts) -> HorizontalGroup
--   opts.page         current 1-indexed page
--   opts.total_pages  total page count (>= 1)
--   opts.on_goto      function(target_page) called when a chevron is tapped
--   opts.show_parent  owning widget (required so icon buttons resolve their
--                     icon atlas path)
--   opts.text_chevrons  render the chevrons as text glyphs (« ‹ › ») rather
--                     than SVG icons, keeping them off the widgetInvert flash
--                     path. Required for callers hosted inside a modal that
--                     sets a cropping_widget (the Cover tab), where the icon
--                     invert path can segfault on some framebuffers.
function Pagination.buildNav(opts)
    local page        = opts.page or 1
    local total_pages = math.max(1, opts.total_pages or 1)
    local on_goto     = opts.on_goto or function() end
    local show_parent = opts.show_parent

    local chev_size = Screen:scaleBySize(32)
    -- Text-glyph chevrons instead of stock SVG icons. ICON buttons flash via
    -- UIManager:widgetInvert (a raw, unclamped Screen.bb:invertRect); TEXT
    -- buttons flash via widgetRepaint, which paints within bounds (and,
    -- inside a modal with a cropping_widget, delegates to it safely). Inside
    -- the book-detail modal the icon path segfaulted on some framebuffers
    -- (issue 266... err, the InkPad crash) -- so callers hosted in that modal
    -- (the Cover tab) pass text_chevrons=true to stay on the safe path.
    local CHEV_GLYPH = {
        ["chevron.first"] = "\xC2\xAB",  -- «
        ["chevron.left"]  = "\xE2\x80\xB9",  -- ‹
        ["chevron.right"] = "\xE2\x80\xBA",  -- ›
        ["chevron.last"]  = "\xC2\xBB",  -- »
    }
    -- enabled chevrons fire on_goto(target); disabled ones are inert.
    local function chev(icon_name, enabled, target)
        if opts.text_chevrons then
            return Button:new{
                text = CHEV_GLYPH[icon_name] or "?",
                text_font_size = 22, text_font_bold = true,
                bordersize = 0, enabled = enabled,
                callback = enabled and function() on_goto(target) end or function() end,
                show_parent = show_parent,
            }
        end
        return Button:new{
            icon = icon_name, icon_width = chev_size, icon_height = chev_size,
            bordersize = 0, enabled = enabled,
            callback = enabled and function() on_goto(target) end or function() end,
            show_parent = show_parent,
        }
    end
    -- Fresh span per slot -- sharing one widget across HGroup positions
    -- corrupts paint geometry.
    local pn_span = Screen:scaleBySize(32)
    local function gap() return HorizontalSpan:new{ width = pn_span } end

    return HorizontalGroup:new{
        align = "center",
        chev("chevron.first", page > 1,           1),
        gap(),
        chev("chevron.left",  page > 1,           page - 1),
        gap(),
        Button:new{
            text = T(_("Page %1 of %2"), page, total_pages),
            text_font_size = 15,
            bordersize = 0,
            callback = function() end,
            show_parent = show_parent,
        },
        gap(),
        chev("chevron.right", page < total_pages, page + 1),
        gap(),
        chev("chevron.last",  page < total_pages, total_pages),
    }
end

return Pagination
