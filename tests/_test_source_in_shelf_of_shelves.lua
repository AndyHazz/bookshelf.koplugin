-- tests/_test_source_in_shelf_of_shelves.lua
-- A registered source (issue 452) as a shelf inside a Shelf of shelves (5.4).
--
-- Opened, a sub-shelf is the shelf on screen, so the source API works as on a
-- top-level shelf. Two things are read from the PARENT instead, and both are
-- pinned here against the real method bodies, extracted by name:
--   * a folder from a fetch-mode source's run on a spine shelf of shelves
--     opens that sub-shelf before drilling, so the drill fetches with the
--     sub-shelf's own source table (it was built from the parent's, losing
--     e.g. which library);
--   * news from a source (ui.bookshelf:sourceChanged) redraws a shelf of
--     shelves whose tiles / spine runs read it.
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

-- A flat tab list: "top" is a shelf of shelves holding "kom" (a registered
-- source) and "nest" (another shelf of shelves) holding "kin" (Kindle).
local TABS = {
    { id = "top",  source = { kind = "shelves" } },
    { id = "kom",  parent = "top",  source = { kind = "komga", library = "L7" } },
    { id = "nest", parent = "top",  source = { kind = "shelves" } },
    { id = "kin",  parent = "nest", source = { kind = "kindle" } },
    { id = "solo", source = { kind = "all" } },
}
local TabModel = {
    load = function() return TABS end,
    getById = function(id) for _i, x in ipairs(TABS) do if x.id == id then return x end end end,
    isShelves = function(x) return type(x) == "table" and type(x.source) == "table"
                                   and x.source.kind == "shelves" end,
    descendantIds = function(id, tabs)
        local set, frontier = {}, { id }
        while #frontier > 0 do
            local nf = {}
            for _i, pid in ipairs(frontier) do
                for _j, x in ipairs(tabs) do
                    if x.parent == pid and not set[x.id] then set[x.id] = true; nf[#nf + 1] = x.id end
                end
            end
            frontier = nf
        end
        return set
    end,
}
local REGISTERED = { komga = true, kindle = true }
local Sources = {
    get = function(k) return REGISTERED[k] and {} or nil end,
    drillFor = function(rec) return { label = rec.title, id = rec.komga_id } end,
}
local function env()
    local e = { ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
                table = table, string = string, math = math, next = next }
    e.require = function(name)
        if name == "lib/bookshelf_tab_model" then return TabModel end
        if name == "lib/bookshelf_sources" then return Sources end
        error("unexpected require " .. name)
    end
    e._G = e
    return e
end

local HOLD = compile("local self, id = ...\n"
    .. bodyOf("_shelvesHoldSource%(id%)", "_shelvesHoldSource"), env(), "hold")
local EXPAND = compile("local self, rec = ...\n"
    .. bodyOf("_expandSourceNav%(rec%)", "_expandSourceNav"), env(), "expand")

t.test("a shelf of shelves hears news from a source inside it, at any depth", function()
    local bw = { chip = "top", _drilldown_path = {} }
    eq(HOLD(bw, "komga"), true)
    eq(HOLD(bw, "kindle"), true, "a shelf two levels down")
    eq(HOLD(bw, "other"), false)
    eq(HOLD(bw, nil), true, "nil = any registered source")
end)

t.test("...but not a plain shelf, nor a drilled-in level", function()
    eq(HOLD({ chip = "solo", _drilldown_path = {} }, "komga"), false)
    eq(HOLD({ chip = "top", _drilldown_path = { { kind = "folder" } } }, "komga"), false)
end)

t.test("a folder from a sub-shelf's spine run opens that shelf, then drills", function()
    local calls = {}
    local bw = {
        chip = "top",
        _openShelf = function(self, id, going_in)
            calls[#calls + 1] = "open:" .. id .. ":" .. tostring(going_in)
            self.chip = id
        end,
        _markTapped = function() end,
        _drillInto = function(self, entry)
            calls[#calls + 1] = "drill:" .. entry.kind .. ":" .. self.chip
        end,
    }
    EXPAND(bw, { title = "Saga", komga_id = "abc", source_kind = "komga",
                 shelf_subshelf = "kom", filepath = "id://nav/abc" })
    eq(table.concat(calls, ","), "open:kom:true,drill:source_nav:kom")
end)

t.test("a folder on the sub-shelf itself drills without reopening it", function()
    local calls = {}
    local bw = {
        chip = "kom",
        _openShelf = function() calls[#calls + 1] = "open" end,
        _markTapped = function() end,
        _drillInto = function(_self, entry) calls[#calls + 1] = "drill:" .. entry.kind end,
    }
    EXPAND(bw, { title = "Saga", source_kind = "komga", filepath = "id://nav/abc" })
    eq(table.concat(calls, ","), "drill:source_nav")
end)

t.done()
