-- The order a grouped-source picker lists its choices in (Home > Source >
-- Author, Series, Genre...): A-Z, or the ones with the most books first. The
-- picker offers the switch only when its choices carry book counts.
local _ = require("lib/bookshelf_i18n").gettext

local Sort = {}

-- The switch's cells, for Kit.segmented / a LibraryModal chip strip.
function Sort.items()
    return {
        { key = "az",    label = _("A-Z") },
        { key = "count", label = _("Most books") },
    }
end

-- hasCounts(choices) -> true when any choice says how many books it holds.
function Sort.hasCounts(choices)
    for _i, c in ipairs(choices or {}) do
        if c.count then return true end
    end
    return false
end

-- sort(choices, by) -> a sorted copy. by = "count": most books first, ties
-- A-Z; anything else A-Z. Case is ignored, as people type it in the search.
function Sort.sort(choices, by)
    local out = {}
    for i, c in ipairs(choices or {}) do out[i] = c end
    local function az(a, b) return (a.label or ""):lower() < (b.label or ""):lower() end
    if by == "count" then
        table.sort(out, function(a, b)
            local ca, cb = a.count or 0, b.count or 0
            if ca ~= cb then return ca > cb end
            return az(a, b)
        end)
    else
        table.sort(out, az)
    end
    return out
end

return Sort
