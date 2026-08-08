-- tests/_test_cover_fetch_base64.lua
-- CoverFetch._base64decode: the pure-Lua decoder used for inline data: cover
-- URIs (Project Gutenberg embeds thumbnails as data:image/png;base64,...).
-- The module's other requires are stubbed so it loads in the pure-Lua harness.

package.path = "./?.lua;" .. package.path
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end
package.preload["logger"] = function()
    return { dbg = function() end, info = function() end,
             warn = function() end, err = function() end }
end

local CoverFetch = dofile("lib/bookshelf_cover_fetch.lua")

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. label .. ": got " .. tostring(got)
                                 .. " want " .. tostring(want)) end
end

-- Known vectors (RFC 4648), including the "=" padding cases.
eq(CoverFetch._base64decode("aGVsbG8="), "hello", "hello (1 pad)")
eq(CoverFetch._base64decode("Zm9vYmFy"), "foobar", "foobar (no pad)")
eq(CoverFetch._base64decode("Zm9vYg=="), "foob", "foob (2 pad)")
eq(CoverFetch._base64decode(""), "", "empty")
-- Whitespace/newlines inside the payload are ignored (wrapped base64).
eq(CoverFetch._base64decode("aGVs\nbG8="), "hello", "hello with newline")
eq(CoverFetch._base64decode("  aGVsbG8=  "), "hello", "hello with spaces")

-- A one-pixel PNG survives the decode with its signature intact (the real
-- failure was these never being decoded at all).
local png_b64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
local png = CoverFetch._base64decode(png_b64)
eq(png:sub(1, 8), "\137PNG\r\n\26\n", "decoded PNG signature")

eq(CoverFetch._base64decode(nil), nil, "nil tolerated")

print(string.format("cover_fetch_base64: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
