-- bookshelf_footer_slots.lua
-- How the footer's nav strip is divided between its five buttons. Plain
-- numbers, no widgets, so the arithmetic is testable headless
-- (tests/_test_footer_slots.lua).
--
-- ── WHY ─────────────────────────────────────────────────────────────────────
--
-- The strip holds first, prev, the page counter, next, last. Their shares
-- used to be fixed fractions, which meant the counter's width had nothing to
-- do with the counter: a long range in a wide UI font at a high DPI --
-- "200 - 235 of 248" -- overflowed its slot and the Button wrapped it onto
-- two lines, while the four chevrons sat in slots several times wider than
-- their icons.
--
-- ── THE RULE ────────────────────────────────────────────────────────────────
--
-- The counter is measured at the WIDEST VALUE IT COULD EVER SHOW on this
-- shelf, never its current one. That is what keeps the buttons still: paging
-- from "1 - 9 of 249" to "200 - 235 of 249" must not shuffle the chevrons
-- around, and it cannot, because both were sized for "888 - 888 of 888".
--
-- Anything the counter needs beyond its default share is borrowed EQUALLY
-- from the four chevron slots, so they stay symmetric about the centre, and
-- never below a floor that keeps each one comfortably tappable. A counter
-- too wide even for that takes what is left and shrinks its own text.

local FooterSlots = {}

-- The default shares, which sum to 1. The first/last pair sit in narrower
-- slots than prev/next so they read as a pair with their neighbour rather
-- than drifting to the strip's ends.
FooterSlots.EDGE_FRAC = 0.18   -- first / last
FooterSlots.STEP_FRAC = 0.18   -- prev  / next
FooterSlots.PAGE_FRAC = 0.28   -- the counter

-- probeNumber(total) -> the number to measure the counter with.
--
-- Same digit count as the total, all of them the widest digit the face is
-- likely to have. The range's own numbers can never be wider than the total,
-- so this is an upper bound for every page of this shelf.
function FooterSlots.probeNumber(total)
    total = tonumber(total)
    local digits = 1
    if total and total >= 1 then
        digits = math.floor(math.log(total, 10)) + 1
        -- log is floating point: 1000 can land a hair under 3.
        if 10 ^ digits <= total then digits = digits + 1 end
    end
    local n = 0
    for _ = 1, digits do n = n * 10 + 8 end
    return n
end

-- widths(strip_w, page_need, floor_w) -> { edge, step, page }
--
-- page_need is the measured width of the counter at its widest value,
-- including whatever padding its button adds. floor_w is the narrowest a
-- chevron slot may become.
function FooterSlots.widths(strip_w, page_need, floor_w)
    strip_w = math.floor(tonumber(strip_w) or 0)
    if strip_w <= 0 then return { edge = 0, step = 0, page = 0 } end
    page_need = math.floor(tonumber(page_need) or 0)
    floor_w   = math.floor(tonumber(floor_w) or 0)
    if floor_w < 0 then floor_w = 0 end

    local edge = math.floor(strip_w * FooterSlots.EDGE_FRAC)
    local step = math.floor(strip_w * FooterSlots.STEP_FRAC)
    local page = strip_w - 2 * edge - 2 * step
    if page_need <= page then return { edge = edge, step = step, page = page } end

    -- Borrow equally from the four chevrons, down to the floor. Integer
    -- division means the strip can be left a pixel or three short rather
    -- than a pixel over, which is the safe direction.
    local chevron = math.floor((strip_w - page_need) / 4)
    if chevron < floor_w then chevron = floor_w end
    page = strip_w - 4 * chevron
    if page < 0 then
        -- Even the floors do not fit: give every slot an equal share and let
        -- the caller's text shrink into whatever the counter gets.
        chevron = math.floor(strip_w / 5)
        page = strip_w - 4 * chevron
    end
    return { edge = chevron, step = chevron, page = page }
end

return FooterSlots
