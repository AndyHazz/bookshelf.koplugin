-- tests/_test_plugin_formats.lua
-- lib/bookshelf_plugin_formats: which extensions other plugins' document
-- providers add to the shelf, against a fake DocumentRegistry.
-- Runs standalone: `lua tests/_test_plugin_formats.lua`.

package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local PF = require("lib/bookshelf_plugin_formats")

local function prov(key) return { provider = key } end
local cre, mupdf, pic = prov("crengine"), prov("mupdf"), prov("picdocument")
local meguru, other = prov("meguru"), prov("someplugin")

local function registry(list)
    local r = { providers = {}, image_ext = { png = true, jpg = true } }
    for _i, p in ipairs(list) do
        r.providers[#r.providers + 1] = { extension = p[1], provider = p[2] }
    end
    return r
end

t.test("core engines contribute nothing, however many formats they list", function()
    PF._reset()
    local set = PF.extensions(registry{
        { "epub", cre }, { "xml", cre }, { "log", cre }, { "zip", mupdf },
        { "tar", mupdf }, { "png", pic }, { "cfb", mupdf },
    })
    eq(next(set), nil, "no plugin formats")
end)

t.test("a plugin's own extension is a book", function()
    PF._reset()
    local set = PF.extensions(registry{ { "epub", cre }, { "meguru", meguru }, { "cbz", meguru } })
    eq(set.meguru, "meguru")
    eq(set.cbz, "meguru", "a plugin re-registering a core format is harmless")
    eq(set.epub, nil)
end)

t.test("extensions are lowercased; images are never books", function()
    PF._reset()
    local set = PF.extensions(registry{ { "FOO", other }, { "png", other }, { "bmp", other } })
    eq(set.foo, "someplugin")
    eq(set.png, nil, "registry image_ext")
    eq(set.bmp, nil, "extra image extension")
end)

t.test("the set follows providers registered after the first lookup", function()
    PF._reset()
    local reg = registry{ { "epub", cre } }
    eq(PF.extensions(reg).meguru, nil, "not yet registered")
    reg.providers[#reg.providers + 1] = { extension = "meguru", provider = meguru }
    eq(PF.extensions(reg).meguru, "meguru", "picked up once the list grows")
end)

t.test("malformed provider entries are skipped, not fatal", function()
    PF._reset()
    local reg = { providers = { {}, { extension = 5 }, { extension = "x", provider = {} },
                               { extension = "ok", provider = other } } }
    local set = PF.extensions(reg)
    eq(set.ok, "someplugin")
    eq(set.x, nil)
end)

t.test("no registry: nothing extra, no error", function()
    PF._reset()
    eq(next(PF.extensions({})), nil)
    package.loaded["document/documentregistry"] = nil
    PF._reset()
    eq(PF.isPluginFormat("meguru"), false)
end)

t.test("isPluginFormat reads the live DocumentRegistry", function()
    package.loaded["document/documentregistry"] = registry{ { "meguru", meguru } }
    PF._reset()
    eq(PF.isPluginFormat("meguru"), true)
    eq(PF.isPluginFormat("epub"), false)
    eq(PF.isPluginFormat(nil), false)
    package.loaded["document/documentregistry"] = nil
    PF._reset()
end)

t.test("fingerprint: sorted, comma-joined, empty without plugin formats", function()
    package.loaded["document/documentregistry"] = nil
    PF._reset()
    eq(PF.fingerprint(), "", "no registry")
    package.loaded["document/documentregistry"] = registry{
        { "epub", cre }, { "zzz", other }, { "meguru", meguru }, { "cbz", meguru } }
    PF._reset()
    eq(PF.fingerprint(), "cbz,meguru,zzz", "stable order whatever the registration order")
    local reg = package.loaded["document/documentregistry"]
    reg.providers[#reg.providers + 1] = { extension = "abc", provider = other }
    eq(PF.fingerprint(), "abc,cbz,meguru,zzz", "follows a later registration")
    package.loaded["document/documentregistry"] = nil
    PF._reset()
    eq(PF.fingerprint(), "")
end)

t.done()
