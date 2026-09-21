-- tests/_test_warm_show_rotation.lua
-- The shelf comes back the way round the reader left the screen.
--
-- THE REPORT (#435, from the author of quickmenu.koplugin, who names the
-- commit). "Since v5.1.2 (and probably commit 694ad71) ... if i launch a book
-- and change the orientation and then close the book with my exit tab:
-- filemanager (during its brief apparition) follow the new orientation (i use
-- keep orientation between view) but [bookshelf does not]."
--
-- WHY IT ONLY STARTED THEN. show()'s warm branch restores the rotation the
-- shelf had before the book was opened. That branch used to be reached by the
-- hot-park finish and _safeShow only; the ORDINARY close cold-created a
-- replacement shelf, which was built at whatever rotation the screen was in
-- and so followed it. 694ad71 stopped the ordinary close throwing the shelf
-- away -- which is the whole point of it, the close went from 705ms to 90ms
-- on a PW5 -- and every close now takes the warm branch, restore included.
--
-- TWO RULES COME OUT OF IT:
--
--   * "Keep current rotation across views" (KOReader's lock_rotation) means
--     what its help says: "nothing will ever sneak a rotation behind your
--     back". With it set, we do not put ours back.
--   * However the screen ends up, a tree measured for the other shape cannot
--     just be repainted. softRefresh swaps content inside the existing
--     layout; a turn needs the rebuild.
--
-- Usage (from plugin root): lua tests/_test_warm_show_rotation.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("main.lua"):read("*a")

local warm = src:match("(%-%- %.%.%.unless the reader has asked.-self%._widget:softRefresh%(%))")
assert(warm, "show()'s warm branch moved or was renamed")

t.test("lock_rotation is honoured, and only it suppresses the restore", function()
    assert(warm:find('isTrue("lock_rotation")', 1, true),
        "the warm branch never asks whether the reader locked the rotation")
    -- The stash is still cleared in that case, or the next close would find
    -- a stale rotation waiting for it.
    local locked = warm:match('isTrue%("lock_rotation"%) then\n(.-)\n%s+else')
    assert(locked and locked:find("_pre_read_rotation = nil", 1, true),
        "the stashed rotation is left behind when it is not used")
    assert(locked and not locked:find("setRotationMode", 1, true),
        "it still turns the screen back, which is what the setting forbids")
end)

t.test("without it, the shelf's own rotation is restored as before", function()
    local unlocked = warm:match("\n%s+else\n(.-)\n%s+end\n%s+end")
    assert(unlocked and unlocked:find("setRotationMode", 1, true),
        "the unlocked path stopped restoring, which is the old behaviour")
end)

t.test("a screen that turned gets a rebuild, not a soft refresh", function()
    assert(warm:find("_rebuild()", 1, true),
        "a turn has to re-measure; softRefresh only swaps content")
    local guard = warm:match("(if self%._widget%.width ~= Screen:getWidth%(%).-then)")
    assert(guard, "nothing compares the tree's shape against the screen's")
    assert(guard:find("self._widget.height ~= Screen:getHeight()", 1, true),
        "only one axis is checked; a 180 turn keeps both, a 90 swaps both")
    -- ...and it returns, so the soft path cannot also run.
    local reshape = warm:match('(_diag_branch = "warm%-reshape".-return\n%s+end)')
    assert(reshape and reshape:find("return", 1, true),
        "the rebuild falls through into softRefresh as well")
end)

t.test("an unturned screen still takes the cheap path", function()
    -- The whole value of 694ad71 is that the ordinary close does NOT rebuild.
    -- The guard is two integers; it must not become the common case.
    local i_guard = warm:find("if self._widget.width ~= Screen:getWidth()", 1, true)
    local i_soft  = warm:find("self._widget:softRefresh()", 1, true)
    assert(i_guard and i_soft and i_soft > i_guard,
        "softRefresh should remain the fall-through for a screen that did "
        .. "not turn")
end)

t.done()
