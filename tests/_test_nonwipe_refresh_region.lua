-- tests/_test_nonwipe_refresh_region.lua
-- The non-wipe page-turn refresh is ONE contiguous region, not two rects.
--
-- THE ARTIFACT. After a footer chevron tap (no _wipe_dir), _swapShelvesInPlace
-- used to issue setDirty(self, "ui", rows-band) plus setDirty(nil, "ui",
-- label-rect). Those two rects left a gap in the footer band that
-- UIManager's edge-sharing merge could not close, so one tap drained as two
-- back-to-back EPDC updates. The fix: a single region from the rows to the
-- bottom of the widget.
--
-- Extracted from the non-wipe tail of _swapShelvesInPlace by the distinctive
-- contiguous-region comment, so a reintroduction of the split fails here.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("non-wipe branch issues a single contiguous setDirty", function()
    -- The non-wipe tail: `if not wiped then` ... through the closing of
    -- the shelf_top branch. Isolate the body after the contiguous comment.
    local block = src:match(
        'if not wiped then\n.-local ry = math.max.-\n(.-)\n        else\n            UIManager:setDirty%(self, "ui"%)\n        end\n    end')
    assert(block,
        "could not find the non-wipe refresh tail in _swapShelvesInPlace - moved?")

    -- Exactly one setDirty in the shelf_top success path: no second
    -- setDirty(nil, ...) label-rect companion.
    local calls = 0
    for _ in block:gmatch('UIManager:setDirty') do calls = calls + 1 end
    assert(calls == 1,
        "expected ONE setDirty in the contiguous path, found " .. calls)

    assert(block:find("h = self.height - ry", 1, true),
        "region no longer runs to the bottom of the widget")
    assert(not block:find("footer_band.y - ry", 1, true),
        "the old split (rows band ending at footer_band.y) is back")
    assert(not block:find('setDirty%(nil', 1, true),
        "the disjoint setDirty(nil, label-rect) companion is back")
end)

t.test("step() arms wipe direction (source-level guard)", function()
    -- Nested step() must not call _swapShelvesInPlace bare; it delegates
    -- to _footerStep which arms _wipe_dir. Belt-and-braces on top of
    -- _test_footer_step's behavioural coverage.
    local footer = src:match("local function step%(direction%)\n(.-)\n    end\n")
    assert(footer, "could not find nested step()")
    assert(footer:find("_footerStep", 1, true),
        "step() bypasses _footerStep")
end)

t.done()
