-- tests/_test_face_out.lua
-- Face out: which covers stand front-on.
--
-- Usage (from plugin root): lua tests/_test_face_out.lua
--
-- WHAT NEEDS PINNING. This was one exclusive choice stored as a string (or
-- nil/true/false) and is now a SET. The risk is not the new behaviour -- it is
-- the OLD values. Every shelf in every existing config carries one of them,
-- and a reader who never opens the new menu must see exactly the shelf they
-- saw yesterday. Normalising rather than migrating is what makes that true,
-- so the normaliser is where the old meanings are pinned.

package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- The model is read out of the source rather than by loading the module: the
-- shelf drags in Screen, fonts and the whole render stack.
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
local chunk = src:match("(SpineShelf%.FACE_REASONS.-\nend\n)\n%-%- \xE2\x94\x80\xE2\x94\x80 Vertical CJK")
    or src:match("(SpineShelf%.FACE_REASONS.-function SpineShelf%.recentSet.-\nend)")
assert(chunk, "the face-out model could not be located")
local SpineShelf = {}
local env = { SpineShelf = SpineShelf, math = math, table = table,
              type = type, tonumber = tonumber, ipairs = ipairs, pairs = pairs }
local fn = load(chunk, "facemodel", "t", env)
assert(fn, "the face-out model would not compile standalone")
fn()

-- ── the old values still mean what they meant ──────────────────────────────

t.test("nil and true are favourites, as they always were", function()
    -- The long-standing default. A config that has never touched this setting
    -- stores nothing at all, so nil is the case that covers most shelves.
    eq(SpineShelf.faceOutSpec(nil).favorites, true)
    eq(SpineShelf.faceOutSpec(true).favorites, true)
end)

t.test("false is none, and none is empty rather than a reason", function()
    local spec = SpineShelf.faceOutSpec(false)
    eq(spec.favorites, nil)
    eq(SpineShelf.faceOutEmpty(spec), true)
end)

t.test("each old string becomes a one-member set", function()
    eq(SpineShelf.faceOutSpec("first").first, true)
    eq(SpineShelf.faceOutSpec("reading").reading, true)
    eq(SpineShelf.faceOutSpec("all").all, true)
    -- "none" was never stored (false was) but the label existed, so it is
    -- accepted rather than read as an unknown reason.
    eq(SpineShelf.faceOutEmpty(SpineShelf.faceOutSpec("none")), true)
end)

t.test("a one-member set does not silently gain others", function()
    local spec = SpineShelf.faceOutSpec("reading")
    eq(spec.favorites, nil)
    eq(spec.recent, nil)
end)

-- ── the set ────────────────────────────────────────────────────────────────

t.test("reasons combine", function()
    local spec = SpineShelf.faceOutSpec{ favorites = true, reading = true }
    eq(spec.favorites, true)
    eq(spec.reading, true)
    eq(SpineShelf.faceOutEmpty(spec), false)
end)

t.test("ALL wins outright rather than joining the set", function()
    -- "All books" is not a reason, it is an answer on its own -- and a set
    -- carrying both would make the other flags dead weight that the menu
    -- still showed as ticked.
    local spec = SpineShelf.faceOutSpec{ all = true, favorites = true }
    eq(spec.all, true)
    eq(spec.favorites, nil)
end)

t.test("a recent count of zero or nonsense is not a reason", function()
    eq(SpineShelf.faceOutSpec{ recent = 0 }.recent, nil)
    eq(SpineShelf.faceOutSpec{ recent = -3 }.recent, nil)
    eq(SpineShelf.faceOutSpec{ recent = "5" }.recent, 5)   -- a stored string
    eq(SpineShelf.faceOutSpec{ recent = 2.7 }.recent, 2)   -- floored, not nil
end)

t.test("an unknown key in a stored set is ignored", function()
    -- A shelf written by a later release, opened by an older one.
    local spec = SpineShelf.faceOutSpec{ favorites = true, sideways = true }
    eq(spec.favorites, true)
    eq(spec.sideways, nil)
end)

-- ── unread (#403: "spines of read and covers of unread books") ────────────

t.test("unread is a reason, in both stored shapes", function()
    eq(SpineShelf.faceOutSpec("unread").unread, true)
    eq(SpineShelf.faceOutSpec{ unread = true }.unread, true)
    eq(SpineShelf.faceOutEmpty(SpineShelf.faceOutSpec("unread")), false)
end)

t.test("unread combines with the other reasons", function()
    local spec = SpineShelf.faceOutSpec{ unread = true, favorites = true }
    eq(spec.unread, true)
    eq(spec.favorites, true)
end)

t.test("isUnread: never opened is unread, however the status was spelled", function()
    -- Three spellings reach records in the wild: no status at all, and the
    -- two strings the sort engine already treats as not-yet-read.
    eq(SpineShelf.isUnread{ _spine_status_checked = true }, true)
    eq(SpineShelf.isUnread{ _spine_status_checked = true, status = "new" }, true)
    eq(SpineShelf.isUnread{ _spine_status_checked = true, status = "unread" }, true)
end)

t.test("isUnread: a book with any read status is not unread", function()
    eq(SpineShelf.isUnread{ _spine_status_checked = true, status = "reading" }, false)
    eq(SpineShelf.isUnread{ _spine_status_checked = true, status = "complete" }, false)
    eq(SpineShelf.isUnread{ _spine_status_checked = true, status = "abandoned" }, false)
end)

t.test("isUnread: an UNCHECKED record is never unread", function()
    -- The loud failure mode. The status ladder fills src.status and then sets
    -- the flag; a record that skipped it has status nil for a reason we do not
    -- know, and reading that as "unread" would face out the ENTIRE shelf.
    eq(SpineShelf.isUnread{}, false)
    eq(SpineShelf.isUnread{ status = nil }, false)
    eq(SpineShelf.isUnread(nil), false)
end)

t.test("the planner actually consults the reason, rather than storing it", function()
    -- This plugin has shipped a setting that nothing read three times. The
    -- model above is only half of a feature; pin the CONSUMER too.
    assert(src:match("face_spec%.unread and SpineShelf%.isUnread%(src%)"),
        "spine_face_out gained an 'unread' reason that the planner ignores")
end)

-- ── recentSet ──────────────────────────────────────────────────────────────

local function flat(...)
    local out = {}
    for _i, pair in ipairs({ ... }) do
        out[#out + 1] = { book = { filepath = pair[1], date_added = pair[2] } }
    end
    return out
end

t.test("the newest N are picked, by date added", function()
    local set = SpineShelf.recentSet(
        flat({ "a", 100 }, { "b", 300 }, { "c", 200 }, { "d", 50 }), 2)
    eq(set.b, true)
    eq(set.c, true)
    eq(set.a, nil)
    eq(set.d, nil)
end)

t.test("books with no date sort last, and are not dropped", function()
    -- A library that never recorded date_added would otherwise face out
    -- nothing, with no way for the reader to tell why.
    local set = SpineShelf.recentSet(flat({ "a" }, { "b" }, { "c" }), 2)
    local n = 0
    for _k in pairs(set) do n = n + 1 end
    eq(n, 2, "a dateless library must still fill the quota")
end)

t.test("ties break stably, so the set does not shuffle between paints", function()
    local a = SpineShelf.recentSet(flat({ "x", 5 }, { "y", 5 }, { "z", 5 }), 2)
    local b = SpineShelf.recentSet(flat({ "z", 5 }, { "y", 5 }, { "x", 5 }), 2)
    for k in pairs(a) do eq(b[k], true, "tie-break is order-dependent") end
end)

t.test("asking for none, or more than exist, is not an error", function()
    eq(SpineShelf.recentSet(flat({ "a", 1 }), nil), nil)
    eq(SpineShelf.recentSet(flat({ "a", 1 }), 0), nil)
    local set = SpineShelf.recentSet(flat({ "a", 1 }), 99)
    eq(set.a, true)
end)

t.test("entries with no filepath are skipped, not counted", function()
    -- Folder and group rows reach the planner in the same list as books.
    local mixed = { { item = { label = "a folder" } },
                    { book = { filepath = "b", date_added = 9 } } }
    local set = SpineShelf.recentSet(mixed, 2)
    eq(set.b, true)
    local n = 0
    for _k in pairs(set) do n = n + 1 end
    eq(n, 1)
end)

t.done()
