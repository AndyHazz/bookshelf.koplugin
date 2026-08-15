-- tests/_test_opds_drill_restore.lua
-- Keeping the OPDS subcatalog you were reading across a restart.
--
-- Drilled OPDS frames used to be dropped on the way to disk, so restarting
-- inside "Internet Archive > English > Biography" put you back on the
-- catalog root. The reason given was sound at the time: a restored frame
-- could land on an empty feed, and the only remedy would be a network fetch
-- at launch that nobody asked for.
--
-- Both halves of that stopped being true - feeds persist in SQLite and
-- accumulate as they are paged, and the refresh default is swipe-down only -
-- but the second half is a PROMISE, not just a circumstance. These tests hold
-- the restore to it: a frame comes back only when its window already has
-- entries, and nothing here may ever reach the network.
--
-- Driven against the real method bodies, extracted by name and run under a
-- stub self (as _test_jump_scan_list does).
package.path = "./?.lua;./?/init.lua;" .. package.path

local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function bodyOf(sig, name)
    local body = src:match("\nfunction BookshelfWidget:" .. sig .. "\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    return body
end

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local SER_BODY = bodyOf("_serializeDrillPath%(%)", "_serializeDrillPath")
local RES_BODY = bodyOf("_restoreDrillPath%(saved%)", "_restoreDrillPath")

-- Counts the window lookups so a test can prove the restore ASKED, and prove
-- it stopped asking once it decided to stop.
local counted
local function env(cached)
    counted = {}
    local fake_window = {
        count = function(server_key, feed_url)
            counted[#counted + 1] = server_key .. "|" .. feed_url
            return cached[server_key .. "|" .. feed_url] or 0
        end,
    }
    local e = {
        ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
        table = table, string = string, math = math,
        -- Anything the restore reaches for other than the window module is a
        -- test failure by construction: a launch-time restore must not touch
        -- the library, the network, or collections.
        require = function(mod)
            if mod == "lib/bookshelf_opds_window" then return fake_window end
            error("restore required an unexpected module: " .. tostring(mod))
        end,
        Repo = setmetatable({}, { __index = function(_, k)
            error("restore reached Repo." .. tostring(k))
        end }),
    }
    e._G = e
    return e
end

local function serialize(path)
    local self_ = { _drilldown_path = path }
    return compile("local self = ...\n" .. SER_BODY, env({}), "ser")(self_)
end

local function restore(saved, cached)
    local self_ = { _drilldown_path = {} }
    local e = env(cached or {})
    compile("local self, saved = ...\n" .. RES_BODY, e, "res")(self_, saved)
    return self_._drilldown_path
end

local IA = "ia"
local ENGLISH  = "https://bookserver.archive.org/c/english"
local BIOGRAPHY = "https://bookserver.archive.org/c/english/biography"

local function navFrame(label, feed_url)
    return { kind = "opds_nav", label = label,
             payload = { server_key = IA, feed_url = feed_url } }
end

-- ── the round trip ─────────────────────────────────────────────────────────

t.test("a drilled subcatalog survives serialization", function()
    local out = serialize{ navFrame("English", ENGLISH) }
    eq(#out, 1, "frames written:")
    eq(out[1].kind, "opds_nav", "kind:")
    eq(out[1].server_key, IA, "server key:")
    eq(out[1].feed_url, ENGLISH, "feed url:")
    eq(out[1].label, "English", "label:")
end)

t.test("and comes back when its window has entries", function()
    local saved = serialize{ navFrame("English", ENGLISH),
                             navFrame("Biography", BIOGRAPHY) }
    local path = restore(saved, { [IA .. "|" .. ENGLISH] = 300,
                                  [IA .. "|" .. BIOGRAPHY] = 120 })
    eq(#path, 2, "frames restored:")
    eq(path[2].label, "Biography", "deepest frame:")
    eq(path[2].payload.feed_url, BIOGRAPHY, "addressed by feed url:")
end)

-- ── the promise: no network, no guessing ───────────────────────────────────

t.test("an empty window is not restored", function()
    local saved = serialize{ navFrame("English", ENGLISH) }
    -- Nothing cached: the shelf must land on the catalog root rather than in
    -- front of a subcatalog it can only fill by fetching.
    eq(#restore(saved, {}), 0, "frames restored for an uncached feed:")
end)

t.test("restoring STOPS at the first uncached frame, leaving no hole", function()
    local saved = serialize{ navFrame("English", ENGLISH),
                             navFrame("Biography", BIOGRAPHY) }
    -- The deeper feed is cached, the one above it is not. Restoring only the
    -- deeper one would give a path whose Back climbs to a parent the reader
    -- never came through.
    local path = restore(saved, { [IA .. "|" .. BIOGRAPHY] = 120 })
    eq(#path, 0, "frames restored when the parent is gone:")
    eq(#counted, 1, "and it stopped asking after the first miss:")
end)

t.test("a frame missing its identity is not restored", function()
    -- Written by a build before the pair was persisted, or a truncated file.
    local path = restore({ { kind = "opds_nav", label = "English" } }, {})
    eq(#path, 0, "frames restored from an unaddressable frame:")
    eq(#counted, 0, "and no window lookup was attempted:")
end)

t.done()
