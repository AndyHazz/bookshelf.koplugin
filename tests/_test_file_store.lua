-- tests/_test_file_store.lua
-- lib/bookshelf_file_store: per-file LuaSettings-backed store used for large
-- routed values (micromodule data, hardcover links, opds cache). Contracts
-- under test: lazy open (requiring costs nothing until a key is touched),
-- save/delete flush per call, saveDeferred + flush batches to ONE write -
-- the batching the weather/on_this_day fixes rely on.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

local opens, flushes = 0, 0
package.loaded["datastorage"] = {
    getSettingsDir = function() return "/settings" end,
}
package.loaded["luasettings"] = {
    open = function(_self, path)
        opens = opens + 1
        local s = { data = {}, path = path }
        function s:readSetting(k) return self.data[k] end
        function s:saveSetting(k, v) self.data[k] = v; return self end
        function s:delSetting(k) self.data[k] = nil; return self end
        function s:flush() flushes = flushes + 1 end
        return s
    end,
}

local FileStore = dofile("lib/bookshelf_file_store.lua")

t.test("path() and lazy open", function()
    opens = 0
    local store = FileStore.new("bookshelf_x.lua")
    assert(store.path() == "/settings/bookshelf_x.lua")
    assert(opens == 0, "creating a store must not open the file")
    store.flush()
    assert(opens == 0, "flush before any access must not open the file")
    store.read("k")
    assert(opens == 1, "first read opens")
    store.save("k", 1)
    assert(opens == 1, "the settings object is reused")
end)

t.test("read returns default only when unset", function()
    local store = FileStore.new("bookshelf_x.lua")
    assert(store.read("missing", "fallback") == "fallback")
    store.save("k", false)
    assert(store.read("k", "fallback") == false,
        "a stored false must win over the default")
end)

t.test("save flushes once per call", function()
    local store = FileStore.new("bookshelf_x.lua")
    store.read("warm")   -- open outside the counted window
    flushes = 0
    store.save("a", 1)
    store.save("b", 2)
    assert(flushes == 2, "one flush per save, got " .. flushes)
end)

t.test("saveDeferred writes in-memory only; flush() lands the batch", function()
    local store = FileStore.new("bookshelf_x.lua")
    store.read("warm")
    flushes = 0
    store.saveDeferred("lat", 51.5)
    store.saveDeferred("lon", -0.1)
    assert(flushes == 0, "deferred saves must not flush")
    assert(store.read("lat") == 51.5, "deferred value readable immediately")
    store.flush()
    assert(flushes == 1, "the batch lands in ONE write")
end)

t.test("deferred batch closed by a final save() also lands once", function()
    -- The exact weather/on_this_day pattern: N saveDeferred + 1 save.
    local store = FileStore.new("bookshelf_x.lua")
    store.read("warm")
    flushes = 0
    store.saveDeferred("data", { temp = 21 })
    store.saveDeferred("day", "2026-08-10")
    store.save("last_fetch", 1234)
    assert(flushes == 1, "N deferred + 1 save = one write, got " .. flushes)
    assert(store.read("data").temp == 21)
end)

t.test("delete removes and flushes", function()
    local store = FileStore.new("bookshelf_x.lua")
    store.save("k", "v")
    flushes = 0
    store.delete("k")
    assert(store.read("k", "gone") == "gone")
    assert(flushes == 1)
end)

t.done()
