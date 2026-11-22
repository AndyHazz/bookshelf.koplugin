-- Vocab Word's hint card: with Vocabulary Builder off, or too few words for
-- a tap to move on, the card says how to collect words instead of showing
-- one word that never changes.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }

local settings = {}
_G.G_reader_settings = { readSetting = function(_self, k) return settings[k] end }

local V = dofile("micromodules/vocab_word.lua")._test

t.test("plugin disabled: plugin_off, whatever the auto-add switch says", function()
    settings = { plugins_disabled = { vocabbuilder = true },
                 vocabulary_builder = { enabled = true } }
    H.eq(V.vocabStatus(), "plugin_off")
end)

t.test("plugin on, auto add off: auto_off", function()
    settings = { plugins_disabled = {}, vocabulary_builder = { enabled = false } }
    H.eq(V.vocabStatus(), "auto_off")
end)

t.test("plugin on, auto add on: no status", function()
    settings = { vocabulary_builder = { enabled = true } }
    H.eq(V.vocabStatus(), nil)
end)

t.test("plugin off: the hint shows even with words saved", function()
    local h = V.hintText("plugin_off", 40)
    assert(h and h:find("Plugin management", 1, true), tostring(h))
end)

t.test("one word with auto add off: says how to save more", function()
    local h = V.hintText("auto_off", 1)
    assert(h and h:find("Auto add new words", 1, true), tostring(h))
end)

t.test("no words, collecting: a plain prompt to look words up", function()
    local h = V.hintText(nil, 0)
    assert(h and not h:find("Auto add", 1, true), tostring(h))
end)

t.test("enough words: no hint, the card shows a word", function()
    H.eq(V.hintText(nil, 1), nil)
    H.eq(V.hintText("auto_off", 2), nil)
end)

t.done()
