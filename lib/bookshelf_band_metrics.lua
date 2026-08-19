-- bookshelf_band_metrics.lua
-- The ONE declaration of how a tap band is sized, parameterised by which
-- font-scale setting drives it.
--
-- A "band" here is a full-width strip holding one line of text that you tap:
-- the chip strip at the top of the shelf, and a list-view row. They are the
-- same kind of surface and are measured by the same arithmetic; they are NOT
-- the same surface, and since the two scale keys were separated they no longer
-- move together. Which is exactly why the arithmetic has to live in one place:
-- with two keys and the derivation copied per call site, "the two keys are
-- independent" and "the derivations agree" stop being checkable at once.
--
-- What it replaces: three inline copies of
--     floor(Size.item.height_default * <scale> / 100 + 0.5)
-- (bookshelf_widget.lua's _rebuild and _layoutPrimitives, and
-- bookshelf_list_row.lua's chipRowHeight), plus four copies of
--     floor(16 * <scale> / 100 + 0.5)
-- for the font size. The comment above the first of those already admitted the
-- hazard -- "keep this calc and the strip's _scaled() in sync" -- and a manual
-- sync note is not a mechanism. Adding a second scale key to that shape would
-- have made it two keys across seven copies.
--
-- ── The split of responsibilities ───────────────────────────────────────────
--
--   bookshelf_list_geom.lua  the ARITHMETIC. Pure, widget-free, and tested
--                            off-device against measured device numbers.
--   this file                the ENVIRONMENT READS the arithmetic needs --
--                            KOReader's Size primitives and the settings
--                            store -- bound to a scale key.
--
-- ListGeom deliberately cannot read either (see its header), so something has
-- to, and until now that something was every caller.
--
-- Every function takes the scale key as its first argument and reads it on
-- demand. Both are deliberate:
--   * the key is a parameter, so the two surfaces cannot accidentally share a
--     derivation the way they did when the row read chip_font_scale;
--   * the read is per call, so the nudge dialog takes effect on the next
--     rebuild without a restart -- the same reason bookshelf_chip_bar.lua has
--     always read its scale on demand rather than at load.

local Size     = require("ui/size")
local Store    = require("lib/bookshelf_settings_store")
local ListGeom = require("lib/bookshelf_list_geom")

local BandMetrics = {}

-- The two keys, named here so no call site spells one as a bare string. Both
-- are 50-300 in the nudge dialogs and default to 100.
--
-- CHIP_KEY keeps its historical name: it predates list view and is what a
-- user's existing settings file has in it.
BandMetrics.CHIP_KEY = "chip_font_scale"
BandMetrics.LIST_KEY = "list_font_scale"
BandMetrics.DEFAULT_SCALE = 100

-- scale(key) -> percent. An unset key, and any non-number a hand-edited
-- settings file might hold, reads as 100.
function BandMetrics.scale(key)
    local v = Store.read(key)
    if type(v) ~= "number" then return BandMetrics.DEFAULT_SCALE end
    return v
end

-- cellHeight(key) -> the band's CONTENT height, before any frame around it.
--
-- Size.item.height_default is KOReader's Screen:scaleBySize(30). This is the
-- number bookshelf_widget.lua hands ChipBar as its `height`, so the chip cells
-- are built at exactly this and nothing else in the widget tree needs to know
-- how it was derived.
function BandMetrics.cellHeight(key)
    return ListGeom.scalePercent(Size.item.height_default, BandMetrics.scale(key))
end

-- paintedHeight(key) -> what the band actually OCCUPIES on screen.
--
-- cellHeight plus the strip's outer frame twice. bookshelf_chip_bar.lua's
-- _buildChipRow wraps the whole strip in a FrameContainer with
-- bordersize = Size.border.thin, and a FrameContainer paints its border
-- OUTSIDE the content it wraps -- so a surface matching the chip band has to
-- match this, not cellHeight. On a 1248x1648 panel that is 52px against a
-- cellHeight of 50, measured; see ListGeom.CHIP_BORDER_DP.
--
-- The chip strip itself never asks for this (it is handed cellHeight and the
-- frame is added around it by the widget stack); the list row does, because it
-- has to land on the same painted band.
--
-- scale_pct overrides the key's saved scale, for a caller that needs the
-- figure at a stated size rather than at the reader's. One today: the list's
-- DEFAULT row count, measured at 100 so it is a property of the configured
-- lines. Without the override this term alone re-introduced the coupling the
-- inversion exists to remove -- the line heights were pinned but the band the
-- row sits in was not, and above 120% it overtook them and drove the row
-- height again.
function BandMetrics.paintedHeight(key, scale_pct)
    return ListGeom.chipRowHeight(Size.item.height_default,
                                  scale_pct or BandMetrics.scale(key),
                                  Size.border.thin)
end

-- fontSize(key) -> the point size a band's text renders at: ListGeom's
-- FONT_SIZE_DP (16, the chip strip's base) at this key's scale.
function BandMetrics.fontSize(key)
    return ListGeom.fontSize(BandMetrics.scale(key))
end

-- No secondaryFontSize(key) here any more. It bound ListGeom.SECONDARY_PCT to
-- a scale key for the list's second line, back when a row had exactly two of
-- them and the second one's size was not the user's to choose. Every line
-- carries its own point size now (lib/bookshelf_list_lines.lua), so the row
-- asks for that size through scaled() below, and SECONDARY_PCT survives only
-- as the derivation of the DEFAULT second line -- which is a constant computed
-- once at module load, not a per-render read of a settings key.

-- scaled(n, key) -> an arbitrary dp at this key's scale, rounded the one way
-- every band site rounds (floor(x + 0.5)). The chip strip needs this for the
-- 18pt icon runs beside its 16pt labels, and a list line for its own declared
-- point size.
function BandMetrics.scaled(n, key)
    return ListGeom.scalePercent(n, BandMetrics.scale(key))
end

return BandMetrics
