-- tests/_test_close_releases_shelf.lua
-- A closed shelf is let go: the hooks installed at init name the newest
-- shelf, and a closed one kept its whole widget tree, page items and fetch
-- cache alive until the next open (kindle_benchmark's post-stress heap).
-- Hooks a NEWER shelf has since taken over are left alone.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local function compile(code, env)
    setmetatable(env, {__index=_G})
    if setfenv then local f=assert(loadstring(code)); setfenv(f,env); return f end
    return assert(load(code,"close","t",env))
end
local function method(name, env)
    local args, body = src:match("function BookshelfWidget:"..name.."%((.-)%)\n(.-)\nend")
    assert(body, name)
    return compile("return function(self"..(args~="" and ","..args or "")..")\n"..body.."\nend",env)()
end
local Repo, Pub, released = {}, {}, {}
local Orn = { handlers = {} }
local HM = { _hosts = setmetatable({}, { __mode = "k" }) }
package.loaded["lib/bookshelf_ornaments"] = Orn
package.loaded["lib/bookshelf_hero_modules"] = HM
package.loaded["lib/bookshelf_published"] = Pub
package.loaded["lib/bookshelf_underlay"] = { release = function(bw) released[#released + 1] = bw end }
local BW = {}
local env = { Repo = Repo, BookshelfWidget = BW, UIManager = { unschedule = function() end } }
local close = method("onCloseWidget", env)
local function shelf()
    local s = { _stopStatusTimer = function() end, _flushNavStateNow = function() end,
                _pageCacheClear = function() end, _heroKeptClear = function() end }
    s._on_book_invalidated = function() end
    s._on_published_filled = function() end
    s._orn_handlers = {}
    s._shelf_module_owners = { home = { owner = true } }
    return s
end

t.test("closing the newest shelf releases every hook that names it", function()
    local s = shelf()
    BW._clip_target, Repo.on_book_invalidated, Pub.on_filled = s, s._on_book_invalidated, s._on_published_filled
    released = {}
    close(s)
    eq(BW._clip_target, nil, "the clip hook kept the closed shelf")
    eq(Repo.on_book_invalidated, nil, "the repository kept the closed shelf's callback")
    eq(Pub.on_filled, nil, "the date reader kept the closed shelf's callback")
    eq(released[1], s, "the underlay was not told the shelf closed")
end)

t.test("closing releases the ornament handlers (to empty) and the shelf's module hosts", function()
    local s, other = shelf(), shelf()
    Orn.handlers = s._orn_handlers
    local e1, e2 = {}, {}
    HM._hosts[e1] = s._shelf_module_owners.home
    HM._hosts[e2] = other._shelf_module_owners.home
    close(s)
    assert(Orn.handlers ~= s._orn_handlers and next(Orn.handlers) == nil, "ornament handlers kept the closed shelf")
    eq(HM._hosts[e1], nil, "a module host kept the closed shelf")
    eq(HM._hosts[e2], other._shelf_module_owners.home, "another shelf's module host was dropped")
end)

t.test("closing an older shelf leaves the newer shelf's hooks in place", function()
    local old, new = shelf(), shelf()
    BW._clip_target, Repo.on_book_invalidated, Pub.on_filled = new, new._on_book_invalidated, new._on_published_filled
    close(old)
    eq(BW._clip_target, new)
    eq(Repo.on_book_invalidated, new._on_book_invalidated)
    eq(Pub.on_filled, new._on_published_filled)
end)

t.test("sources drop a listener only while it is still the one named", function()
    package.loaded["lib/bookshelf_sources"] = nil
    local Sources = dofile("lib/bookshelf_sources.lua")
    local hits = 0
    local a, b = function() hits = hits + 1 end, function() hits = hits + 10 end
    Sources.onChanged("widget", a)
    Sources.offChanged("widget", b)     -- not the one installed: stays
    Sources.changed(nil); eq(hits, 1)
    Sources.offChanged("widget", a)
    Sources.changed(nil); eq(hits, 1, "a released listener still fired")
end)

t.test("the underlay forgets a released shelf, and only that one", function()
    local src2 = io.open("lib/bookshelf_underlay.lua"):read("*a")
    assert(src2:find("function M.release(bw)\n    if bw ~= nil and _bw == bw then M._reset() end\nend", 1, true),
        "release does not reset only for the installed shelf")
end)

t.done()
