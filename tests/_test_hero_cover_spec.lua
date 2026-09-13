-- tests/_test_hero_cover_spec.lua
-- Issue 398: the hero's cover must be requested at HERO size, not upscaled
-- from a shelf-slot bitmap.
--
-- ── WHAT WENT WRONG ─────────────────────────────────────────────────────────
--
-- BIM keeps ONE bitmap per book, at the largest size ever requested. The hero
-- draws a cover far larger than a shelf slot, so a book whose only cached cover
-- is slot-sized gets blown up there and reads as blurred.
--
-- That larger request is made in exactly one place,
-- _kickOffMissingMetaExtraction, which queues the hero book against hero_specs
-- and every other book against slot_specs. Two paths called it -- _rebuild and
-- _swapShelvesInPlace (a page turn) -- and the third did not:
-- _swapHeroInPlace, which is what runs when a DIFFERENT book is put in the
-- hero. So selecting a freshly added book left it soft until something else
-- forced a rebuild.
--
-- Reported from a Kobo Clara Color with before/after screenshots: sharp after a
-- manual library refresh or a page change, blurred otherwise. The reporter also
-- noticed the first selection was fine and later ones were not, which fits --
-- a selection made while the hero shows micro-modules goes through
-- _rebuildRefreshHeroAndChips (a real rebuild), and only subsequent ones take
-- the in-place swap.
--
-- Nothing device-specific; it is simply most visible on newly added books,
-- whose only cached cover is whatever size the shelf asked for first.
--
-- Usage (from plugin root): lua tests/_test_hero_cover_spec.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

local src = assert(io.open("lib/bookshelf_widget.lua")):read("*a")

local body = src:match("\n(function BookshelfWidget:_swapHeroInPlace%(.-\nend)\n")
assert(body, "_swapHeroInPlace moved or was renamed")

-- Anchored on the CALL, not the word: the explanatory comment names the
-- function in prose, and matching that would pass with no call present.
local at_kick = body:find("self:_kickOffMissingMetaExtraction(", 1, true)

t.test("swapping the hero requests a hero-sized cover", function()
    assert(at_kick,
        "the hero swap never queues an extraction, so a slot-sized cover "
        .. "stays upscaled until an unrelated rebuild happens to re-queue it")
end)

t.test("it asks at HERO dimensions, not slot dimensions", function()
    -- Passing slot dims would queue the same size the shelf already has, i.e.
    -- change nothing: hero_specs is max(slot, hero) per axis.
    local call = body:sub(at_kick or 1)
    call = call:sub(1, call:find(")", 1, true) and #call or #call)
    local args = call:match("_kickOffMissingMetaExtraction%((.-)%)")
    assert(args, "could not read the call's arguments")
    local _, n = args:gsub("hero_cover_[wh]", "")
    assert(n >= 2, "the hero dimensions are not passed: " .. args)
end)

t.test("no shelf items are queued from this path", function()
    -- The shelf rows have not changed -- only which book is in the hero -- so
    -- passing the page's items would re-run a per-book BIM read for every
    -- visible cover on every tap, which is the cost _rebuild defers
    -- post-paint precisely to avoid.
    local args = body:sub(at_kick or 1):match("_kickOffMissingMetaExtraction%((.-)%)")
    assert(args and args:match("^%s*{%s*}"),
        "expected an empty item list, got: " .. tostring(args))
end)

t.test("the expanded strip does not request a hero cover", function()
    -- When expanded the slot holds a status strip, not a cover, so there is
    -- nothing to size up and the BIM read would be wasted. Checked as a GUARD
    -- on the call rather than "_expanded appears somewhere in the function",
    -- which was true before the fix and would have passed against no call.
    local before = body:sub(1, (at_kick or 1) - 1)
    assert(before:sub(-80):find("if not self._expanded then", 1, true),
        "the queue is not guarded by `if not self._expanded then` immediately "
        .. "above it; tail was: " .. before:sub(-80))
end)

t.done()
