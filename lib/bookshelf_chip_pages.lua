-- bookshelf_chip_pages.lua
-- Pure pagination math for the chip bar's nav (flex) chips. No UI / KOReader
-- deps, so it unit-tests headlessly. The chip bar feeds in each flex chip's
-- natural width and the geometry; this partitions them into pages, reserving
-- room for the page chevrons that the bar draws on the inside when there is a
-- neighbouring page. See /tmp/bookshelf-infinite-chips-design.md.

local Pages = {}

-- Width of chips[i..j] laid out adjacently, including inter-chip spacing.
local function runWidth(widths, spacing, i, j)
    if j < i then return 0 end
    local w = 0
    for k = i, j do w = w + widths[k] end
    return w + spacing * (j - i)
end

-- paginate(opts) -> { pages = { {first=,last=}, ... }, num_pages = n, multi = bool }
--   opts.widths    : array of each flex chip's natural width (px), in flex order
--   opts.spacing   : inter-chip spacing (px) between adjacent chips
--   opts.avail     : width available for flex chips + chevrons
--   opts.chevron_w : width one chevron occupies when shown
-- `multi` is true only when there is more than one page (i.e. chevrons show).
function Pages.paginate(opts)
    local widths    = opts.widths or {}
    local spacing   = opts.spacing or 0
    local avail     = opts.avail or 0
    local chevron_w = opts.chevron_w or 0
    local n = #widths
    if n == 0 then return { pages = {}, num_pages = 0, multi = false } end

    -- Everything fits: one page, no chevrons (no width reserved for them).
    if runWidth(widths, spacing, 1, n) <= avail then
        return { pages = { { first = 1, last = n } }, num_pages = 1, multi = false }
    end

    -- Greedy fill. A page that is not first reserves a left chevron; a page is
    -- the last one exactly when the rest fits without a right chevron, so we
    -- reserve a right chevron unless that holds. The chevron footprint is its
    -- own width plus one spacing gap to the chips.
    local pages = {}
    local chev  = chevron_w + spacing
    local first = 1
    while first <= n do
        local left      = (first > 1) and chev or 0
        local rem_fits  = runWidth(widths, spacing, first, n) <= (avail - left)
        local right     = rem_fits and 0 or chev
        local cap       = avail - left - right
        -- Always place at least one chip, even if it alone exceeds cap (the
        -- renderer truncates that degenerate case); then add while they fit.
        local last = first
        local cum  = widths[first]
        local k = first + 1
        while k <= n and (cum + spacing + widths[k]) <= cap do
            cum  = cum + spacing + widths[k]
            last = k
            k = k + 1
        end
        pages[#pages + 1] = { first = first, last = last }
        first = last + 1
    end
    return { pages = pages, num_pages = #pages, multi = #pages > 1 }
end

-- pageOf(result, flex_index) -> 1-based page number holding that chip (1 if out of range).
function Pages.pageOf(result, idx)
    if not result or not result.pages then return 1 end
    for p, range in ipairs(result.pages) do
        if idx >= range.first and idx <= range.last then return p end
    end
    return 1
end

return Pages
