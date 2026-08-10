-- tests/_test_changelog.lua
-- lib/bookshelf_changelog's pure parts: seeding the cache from a GitHub
-- /releases payload (draft/prerelease/malformed filtering, tag dedupe,
-- count + body caps, one-flush batching) and formatting a release for the
-- viewer. The fetch/viewer halves need KOReader and are device-tested.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = {
    template = function(str, ...)
        local args = { ... }
        return (str:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
    end,
}
-- In-memory file store (same stub shape as _test_file_store).
local flushes = 0
package.loaded["datastorage"] = { getSettingsDir = function() return "/settings" end }
package.loaded["luasettings"] = {
    open = function(_self, path)
        local s = { data = {}, path = path }
        function s:readSetting(k) return self.data[k] end
        function s:saveSetting(k, v) self.data[k] = v; return self end
        function s:delSetting(k) self.data[k] = nil; return self end
        function s:flush() flushes = flushes + 1 end
        return s
    end,
}

local C = dofile("lib/bookshelf_changelog.lua")
local t = dofile("tests/_helpers.lua").runner()

local function rel(tag, body, extra)
    local r = { tag_name = tag, body = body or ("notes for " .. tag),
                published_at = "2026-08-0" .. (extra and extra.day or 1) .. "T10:00:00Z" }
    if extra then for k, v in pairs(extra) do if k ~= "day" then r[k] = v end end end
    return r
end

t.test("seed filters drafts, prereleases and malformed entries", function()
    local n = C.seed({
        rel("v3.11.1"),
        rel("v3.11.0", nil, { draft = true }),
        rel("v3.10.9", nil, { prerelease = true }),
        { body = "no tag at all" },
        "not even a table",
        rel("v3.10.8"),
    })
    assert(n == 2, "kept 2, got " .. n)
    local cached = C.cached()
    assert(cached[1].tag == "v3.11.1" and cached[2].tag == "v3.10.8",
        "newest-first order preserved")
end)

t.test("seed dedupes by tag, first (newest) occurrence wins", function()
    C.seed({ rel("v1", "first copy"), rel("v1", "second copy"), rel("v0") })
    local cached = C.cached()
    assert(#cached == 2)
    assert(cached[1].body == "first copy")
end)

t.test("seed caps the release count and body size", function()
    local rels = {}
    for i = 60, 1, -1 do rels[#rels + 1] = rel("v" .. i) end
    assert(C.seed(rels) == C.MAX_RELEASES)
    assert(#C.cached() == C.MAX_RELEASES)
    C.seed({ rel("vbig", string.rep("x", C.MAX_BODY + 5000)) })
    assert(#C.cached()[1].body == C.MAX_BODY, "body capped")
end)

t.test("seed batches to one flush and rejects junk without clobbering", function()
    C.seed({ rel("vkeep") })
    flushes = 0
    C.seed({ rel("vnew") })
    assert(flushes == 1, "releases + stamp land in ONE write, got " .. flushes)
    assert(C.seed(nil) == 0)
    assert(C.seed({}) == 0)
    assert(C.seed({ rel("vdraft", nil, { draft = true }) }) == 0,
        "all-filtered payload stores nothing")
    assert(C.cached()[1].tag == "vnew", "a rejected seed keeps the old cache")
end)

t.test("stripMarkdown flattens the release-notes idioms", function()
    assert(C.stripMarkdown("## Heading\n**bold** and *italic* and `code`")
        == "Heading\nbold and italic and code")
    assert(C.stripMarkdown(nil) == "")
end)

t.test("format: headline with date, stripped body, v-prefix normalised", function()
    local out = C.format({ tag = "3.11.1", date = "2026-08-03", body = "**Fixed** things" })
    assert(out == "v3.11.1  (2026-08-03)\n\nFixed things", out)
    local bare = C.format({ tag = "v2.0.0" })
    assert(bare:find("^v2%.0%.0\n\n"), "no date, no brackets: " .. bare)
    assert(bare:find("(no notes for this release)", 1, true), "empty body placeholder")
    assert(C.format(nil) == "")
end)

t.done()
