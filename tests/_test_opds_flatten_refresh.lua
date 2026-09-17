-- tests/_test_opds_flatten_refresh.lua
-- A refresh drops the child feeds a page's flattening decisions came from.
--
-- WHAT NEEDS PINNING. An OPDS category holding exactly one acquisition entry
-- renders as that book rather than as a folder, which is what keeps Gutenberg
-- and ManyBooks usable: they model every work as a subcatalog of one. The
-- decision is made from the CHILD feed, cached separately from the page on
-- screen.
--
-- Flattening then removes the folder, and drilling into a folder is the only
-- way a child feed ever becomes the refresh target. So the tile could never
-- be re-examined: a swipe-down refreshes the feed on screen, the resolve pass
-- skips anything already fetched, and every other write is append-only.
-- Reported on issue 411 with a Grimmory catalogue: "refreshing does not revert
-- it back to a folder even if more entries are added back".
--
-- Two things have to hold, and the second is what stops the fix being
-- expensive: the flattened children ARE dropped, and the ones that stayed
-- folders are NOT, because those can still be drilled into and refreshed
-- there. One round trip per tile on every refresh would be the alternative.
--
-- Usage (from plugin root): lua tests/_test_opds_flatten_refresh.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match(
    "\nfunction BookshelfWidget:_opdsResetFlattenedChildren%(server_key, win%)\n(.-)\nend\n")
assert(body, "_opdsResetFlattenedChildren moved or was renamed")

-- `lone` decides which child urls look like a one-entry category.
local function run(page, lone, opts)
    opts = opts or {}
    local reset = {}
    local env = {
        pcall = pcall, require = function(name)
            if name == "lib/bookshelf_opds_window" then
                return {
                    slice = function(win, off, lim)
                        if opts.slice_error then error("boom") end
                        return win.page
                    end,
                    reset = function(key, url) reset[#reset + 1] = url end,
                }
            end
            error("unexpected require: " .. tostring(name))
        end,
        Repo = { opdsLoneChildBook = function(_key, url) return lone[url] or nil end },
        type = type,
    }
    local fn = assert(load(
        "return function(self, server_key, win)\n" .. body .. "\nend",
        "reset", "t", env))
    local n = fn()({}, opts.key == nil and "srv" or opts.key, { page = page, count = #page })
    return reset, n
end

local NAV_A  = { is_opds_nav = true, opds = { feed_url = "http://x/a" } }
local NAV_B  = { is_opds_nav = true, opds = { feed_url = "http://x/b" } }
local BOOK   = { opds = { feed_url = "http://x/book" } }   -- not a nav record

t.test("a child that flattened into a book is dropped", function()
    local reset = run({ NAV_A }, { ["http://x/a"] = { title = "lone" } })
    eq(#reset, 1)
    eq(reset[1], "http://x/a")
end)

t.test("a child that is still a folder is left alone", function()
    -- It keeps its drill-in, so a refresh can reach it there. Dropping it
    -- would cost a round trip per tile on every refresh.
    local reset = run({ NAV_B }, {})
    eq(#reset, 0, "a multi-entry folder's cache was thrown away for nothing")
end)

t.test("a mixed page drops only the flattened ones", function()
    local reset, n = run({ NAV_A, NAV_B, BOOK },
                         { ["http://x/a"] = { title = "lone" },
                           ["http://x/book"] = { title = "not a nav" } })
    eq(#reset, 1, "only the flattened nav belongs in the list")
    eq(reset[1], "http://x/a")
    eq(n, 1, "the count must match what was dropped")
end)

t.test("a record with no feed url cannot reset anything", function()
    local reset = run({ { is_opds_nav = true }, { is_opds_nav = true, opds = {} } }, {})
    eq(#reset, 0)
end)

t.test("a failure inside leaves the refresh itself alone", function()
    -- This runs in the middle of a refresh that has just landed its first
    -- page. Throwing here would lose that page.
    local ok, reset = pcall(run, { NAV_A }, { ["http://x/a"] = {} }, { slice_error = true })
    assert(ok, "the helper let an error escape into the refresh")
    eq(#reset, 0)
end)

t.test("no server key means no resets at all", function()
    local reset = run({ NAV_A }, { ["http://x/a"] = {} }, { key = false })
    eq(#reset, 0, "a missing server key must not reset another catalogue's feeds")
end)

t.test("it runs BEFORE the parent window is cleared", function()
    -- The old window is the only place the pre-refresh page can be read from,
    -- and OpdsWindow.reset on the parent destroys it.
    local mine   = src:find("self:_opdsResetFlattenedChildren(tab.source.id, win)", 1, true)
    local parent = src:find("OpdsWindow.reset(tab.source.id, feed_url)", 1, true)
    assert(mine, "the call site moved out of the refresh path")
    assert(parent, "the parent reset moved")
    assert(mine < parent,
        "the children are read from the OLD window, so this must come first")
    -- Adjacent, not merely earlier somewhere in a 20k-line file.
    assert(parent - mine < 400,
        "the two have drifted apart; they are one step and belong together")
end)

t.done()
