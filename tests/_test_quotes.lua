-- tests/_test_quotes.lua
-- Quote-of-the-day provider: daily-pick persistence across restarts (#247).
-- The sidecar walk is the slow part of the first render after a restart; the
-- daily pick is stable all day by design, so a restart with a still-valid
-- persisted pick must NOT re-walk.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_text_safe"] = { safe = function(s) return s end }
package.loaded["logger"] = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
}

-- Persistent-settings stub shared across simulated restarts.
local kv = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read  = function(k, default) if kv[k] == nil then return default end return kv[k] end,
    save  = function(k, v) kv[k] = v end,
    delete = function(k) kv[k] = nil end,
    flush = function() end,
}

package.loaded["readhistory"] = { hist = { { file = "/b1.epub" } } }

-- DocSettings stub with an open-counter: each sidecar walk costs one open.
local opens = 0
package.loaded["docsettings"] = {
    hasSidecarFile = function(_self, fp) return fp == "/b1.epub" end,
    open = function(_self, _fp)
        opens = opens + 1
        return {
            readSetting = function(_s, k)
                if k == "doc_props" then
                    return { title = "Book One", authors = "Alpha Tester" }
                elseif k == "annotations" then
                    return { { drawer = "lighten", text = "A daily quote.", page = 3 } }
                end
            end,
        }
    end,
}

-- start_menu_modules only matters for "open" mode's cache key.
package.loaded["lib/bookshelf_start_menu_modules"] = { menu_generation = 1 }

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- A fresh dofile = a fresh module instance = a simulated restart (all module
-- locals reset; only the settings stub persists).
local function freshSession()
    return dofile("lib/bookshelf_quotes.lua")
end

t.test("first session walks sidecars and persists the daily pick", function()
    kv = {}; opens = 0
    local Q = freshSession()
    local q = Q.ofTheDay()
    assert(q and q.text == "A daily quote.", "expected the stubbed quote")
    assert(opens == 1, "expected exactly one sidecar open, got " .. opens)
    assert(type(kv.quote_of_day_daily_cache) == "table", "daily pick should persist")
end)

t.test("restart with a valid persisted pick skips the sidecar walk (#247)", function()
    opens = 0
    local Q = freshSession()  -- simulated restart: kv survives, locals reset
    local q = Q.ofTheDay()
    assert(q and q.text == "A daily quote.", "expected the persisted quote")
    assert(opens == 0, "restart should not re-walk sidecars, got " .. opens .. " opens")
end)

t.test("reroll steps past the persisted pick and re-walks", function()
    opens = 0
    local Q = freshSession()
    Q.ofTheDay()          -- adopt persisted (no walk)
    Q.reroll()
    Q.ofTheDay()          -- nonce changed: key mismatch, must re-collect
    assert(opens == 1, "reroll should force one fresh walk, got " .. opens)
end)

t.test("'no highlights' is not persisted (a new first highlight shows same-day)", function()
    kv = {}; opens = 0
    package.loaded["readhistory"].hist = {}
    local Q = freshSession()
    assert(Q.ofTheDay() == nil, "no history should yield no quote")
    assert(kv.quote_of_day_daily_cache == nil,
        "the empty verdict must not persist - a first highlight today should show today")
    package.loaded["readhistory"].hist = { { file = "/b1.epub" } }
end)

t.done()
