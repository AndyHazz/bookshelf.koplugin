-- tests/_test_stack_image_discovery.lua
-- Image-library auto-discovery for stacks (authors/, series/, genres/,
-- collections/ under the library root). It read one folder listing per kind
-- rather than stat-ing up to 16 candidate names per stack (measured 9% of a
-- Genres page turn on a PW5). Pins what it finds, and the cost.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local FILES = {
    ["/lib/.bookshelf-images/genres"] = { "Fantasy.png", "science-fiction.JPG", "notes.txt" },
}
local stats, dirs_read = 0, 0
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(p, key)
        stats = stats + 1
        p = p:gsub("/+$", "")
        if FILES[p] then return key == "mode" and "directory" or { mode = "directory" } end
        local dir, name = p:match("^(.*)/([^/]+)$")
        for _i, n in ipairs(FILES[dir] or {}) do
            if n == name then return key == "mode" and "file" or { mode = "file" } end
        end
        return nil
    end,
    dir = function(p)
        dirs_read = dirs_read + 1
        p = p:gsub("/+$", "")
        local list, i = FILES[p] or {}, 0
        return function() i = i + 1; return list[i] end, {}
    end,
}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
package.loaded["ui/renderimage"] = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function() return nil end, generation = function() return 1 end,
}
_G.G_reader_settings = { readSetting = function(_s, k) if k == "home_dir" then return "/lib" end end }
local IS = dofile("lib/bookshelf_image_source.lua")

t.test("finds an image by name and by slug, whatever the case", function()
    eq(IS.resolveStackImage("genre", "Fantasy"), "/lib/.bookshelf-images/genres/Fantasy.png")
    eq(IS.resolveStackImage("genre", "Science Fiction"), "/lib/.bookshelf-images/genres/science-fiction.JPG")
    eq(IS.resolveStackImage("genre", "Horror"), nil)
end)

t.test("the folder is listed once, and a miss costs no stats", function()
    IS.invalidateCache()
    stats, dirs_read = 0, 0
    for _i, g in ipairs({ "Horror", "Romance", "Thriller", "Mystery", "Western" }) do
        eq(IS.resolveStackImage("genre", g), nil)
    end
    eq(dirs_read, 1)
    assert(stats <= 2, "expected the folder check only, got " .. stats .. " stats")
end)

t.done()
