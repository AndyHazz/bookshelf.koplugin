-- tests/_test_i18n_context.lua
-- One English word can need two translations: "Series" is plural on the
-- grouped stack chip and singular on the Just one chip, and Turkish showed
-- the plural on both. A msgctxt entry keeps them apart.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local dir = os.tmpname(); os.remove(dir); os.execute("mkdir -p " .. dir .. "/lib " .. dir .. "/locale")
local function cp(from, to)
    local s = io.open(from):read("*a"); local f = io.open(to, "w"); f:write(s); f:close()
end
cp("lib/bookshelf_i18n.lua", dir .. "/lib/bookshelf_i18n.lua")
local po = io.open(dir .. "/locale/xx.po", "w")
po:write([[
msgid ""
msgstr ""

msgid "Series"
msgstr "Diziler"

msgctxt "one series"
msgid "Series"
msgstr "Dizi"

msgctxt "one series"
msgid "Author"
msgstr ""
]])
po:close()

package.loaded["logger"] = { dbg = function() end }
package.loaded["gettext"] = setmetatable({}, { __call = function(_s, m) return m end })
package.loaded["lib/bookshelf_bytecode"] = nil
package.preload["lib/bookshelf_bytecode"] = function() error("no bytecode in tests") end
_G.G_reader_settings = { readSetting = function(_s, k) if k == "language" then return "xx" end end }
local I = dofile(dir .. "/lib/bookshelf_i18n.lua")

t.test("a plain msgid keeps its own translation", function()
    eq(I.gettext("Series"), "Diziler")
end)

t.test("a msgid in a context takes that context's translation", function()
    eq(I.pgettext("one series", "Series"), "Dizi")
end)

t.test("an untranslated context entry shows the English, not the plain msgid's translation", function()
    eq(I.pgettext("one series", "Author"), "Author")
    eq(I.pgettext("no such context", "Series"), "Series")
end)

os.execute("rm -rf " .. dir)
t.done()
