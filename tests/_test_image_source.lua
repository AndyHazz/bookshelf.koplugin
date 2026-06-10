-- tests/_test_image_source.lua
-- Pure-Lua tests for custom folder/stack image resolution.

local files = {}
local store = {}
local home_dir = "/library"
local generation = 0

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, attr)
        local mode = files[path]
        if not mode then return nil end
        if attr == "mode" then return mode end
        return { mode = mode, modification = 1 }
    end,
}

package.loaded["logger"] = {
    warn = function() end,
}

package.loaded["ui/renderimage"] = {
    renderImageFile = function()
        return nil
    end,
}

package.loaded["lib/bookshelf_settings_store"] = {
    read = function(key, default)
        local v = store[key]
        if v == nil then return default end
        return v
    end,
    save = function(key, value)
        store[key] = value
        generation = generation + 1
    end,
    delete = function(key)
        store[key] = nil
        generation = generation + 1
    end,
    generation = function() return generation end,
}

_G.G_reader_settings = {
    readSetting = function(_, key)
        if key == "home_dir" then return home_dir end
        return nil
    end,
}

local ImageSource = dofile("lib/bookshelf_image_source.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "") .. " expected=" .. tostring(expected) .. " got=" .. tostring(actual), 2)
    end
end

local function reset()
    files = {}
    store = {}
    home_dir = "/library"
    generation = generation + 1
end

test("default library paths include hidden and visible folders", function()
    reset()
    local paths = ImageSource.getImageLibraryPaths()
    eq(paths[1], "/library/.bookshelf-images")
    eq(paths[2], "/library/bookshelf-images")
end)

test("primary library path prefers an existing visible folder when hidden is absent", function()
    reset()
    files["/library/bookshelf-images"] = "directory"
    eq(ImageSource.getImageLibraryPath(), "/library/bookshelf-images")
end)

test("primary library path keeps hidden folder precedence when both exist", function()
    reset()
    files["/library/.bookshelf-images"] = "directory"
    files["/library/bookshelf-images"] = "directory"
    eq(ImageSource.getImageLibraryPath(), "/library/.bookshelf-images")
end)

test("stack auto-discovery reads visible bookshelf-images folder", function()
    reset()
    files["/library/bookshelf-images/authors/"] = "directory"
    files["/library/bookshelf-images/authors/Isaac Asimov.jpg"] = "file"
    eq(ImageSource.resolveStackImage("author", "Isaac Asimov"),
       "/library/bookshelf-images/authors/Isaac Asimov.jpg")
end)

test("exact visible match wins before hidden slug fallback", function()
    reset()
    files["/library/.bookshelf-images/authors/"] = "directory"
    files["/library/bookshelf-images/authors/"] = "directory"
    files["/library/.bookshelf-images/authors/isaac-asimov.jpg"] = "file"
    files["/library/bookshelf-images/authors/Isaac Asimov.jpg"] = "file"
    eq(ImageSource.resolveStackImage("author", "Isaac Asimov"),
       "/library/bookshelf-images/authors/Isaac Asimov.jpg")
end)

test("explicit image library path overrides both default folders", function()
    reset()
    store.image_library_path = "/custom"
    files["/custom/authors/"] = "directory"
    files["/library/bookshelf-images/authors/Isaac Asimov.jpg"] = "file"
    files["/custom/authors/Isaac Asimov.jpg"] = "file"
    eq(ImageSource.getImageLibraryPath(), "/custom")
    eq(ImageSource.resolveStackImage("author", "Isaac Asimov"),
       "/custom/authors/Isaac Asimov.jpg")
end)

if fail > 0 then
    io.stderr:write(string.format("\n%d passed, %d failed\n", pass, fail))
    os.exit(1)
end

print(string.format("\n%d passed, %d failed", pass, fail))
