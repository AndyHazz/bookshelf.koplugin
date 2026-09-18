-- tests/_test_template_tokens_survive.lua
-- A translated TEMPLATE must still be a template.
--
-- Two shipped defaults carry English words inside token syntax: the list
-- view's "%book_pct of %page_count pages" (reported untranslated as issue
-- 418) and the top panel's "%book_time_left LEFT". Both are now passed
-- through _(), whole, so a translator can move the words -- some languages
-- want the unit before the count, some want no preposition at all.
--
-- WHAT THAT BUYS AND WHAT IT RISKS. It buys a sentence that reads naturally
-- in each language instead of two context-free msgids ("of", "pages") of the
-- kind that made Light and Medium collide across unrelated menus. It risks a
-- translation that drops %page_count, or writes [/if] where [else] belongs --
-- and msgfmt cannot see any of that, because to gettext these are ordinary
-- strings. So this suite reads it instead: every locale's rendering of a
-- template msgid must carry the same tokens and balanced conditionals.
--
-- Usage (from plugin root): lua tests/_test_template_tokens_survive.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- Entries whose msgid looks like a token template: it carries a %token or a
-- conditional. Obsolete (#~) blocks are skipped -- retired strings are not
-- rendered by anything.
-- OUR templates, not every string with a percent in it. A bookshelf token is
-- a word (%book_pct, %page_count, %bar); %d and %s are C format specifiers in
-- ordinary strings and have nothing to do with this. Conditionals are ours
-- outright.
local function isTemplate(msgid)
    -- Prose ABOUT templates is not a template. The token help text quotes
    -- fragments ("[if:series]...[/if]") to explain the syntax, so it reads as
    -- conditional-bearing and is deliberately unbalanced. A real template's
    -- conditionals close; that is the discriminator, and the shipped defaults
    -- are checked for it directly in their own test below.
    local _a, opens = msgid:gsub("%[if:", "")
    local _b, closes = msgid:gsub("%[/if%]", "")
    -- A conditional is ours outright and nothing else uses the syntax, so
    -- that alone identifies a template. Deliberately NOT falling back to
    -- "contains a %word": "%dm" is a C format specifier followed by the
    -- letter m, and treating it as a token named "dm" reported every
    -- duration string in the catalogue as broken.
    return opens > 0 and opens == closes
end

local function templates(path)
    local out = {}
    local f = io.open(path)
    if not f then return out end
    -- Line-wise, not one big pattern: a msgid or msgstr is one or more quoted
    -- lines and Lua patterns cannot express "repeat this group".
    local cur, field = nil, nil
    local function flush()
        if cur and cur.msgid and cur.msgstr
                and cur.msgid ~= "" and cur.msgstr ~= "" and not cur.obsolete
                and isTemplate(cur.msgid) then
            out[#out + 1] = cur
        end
        cur, field = nil, nil
    end
    for line in f:lines() do
        if line == "" then
            flush()
        else
            local body = line:match('^msgid%s+"(.*)"$')
            if body then
                cur = cur or {}
                cur.msgid, cur.msgstr, field = body, nil, "msgid"
            else
                body = line:match('^msgstr%s+"(.*)"$')
                if body then
                    cur = cur or {}
                    cur.msgstr, field = body, "msgstr"
                else
                    body = line:match('^"(.*)"$')
                    if body and cur and field then
                        cur[field] = (cur[field] or "") .. body
                    elseif line:match("^#~") then
                        cur = cur or {}
                        cur.obsolete = true
                    end
                end
            end
        end
    end
    flush()
    f:close()
    return out
end

-- %token, %token{arg} -- the name is what matters, not the argument.
local function tokensOf(s)
    local seen = {}
    for name in s:gmatch("%%([%a_]+)") do seen[#seen + 1] = name end
    table.sort(seen)
    return table.concat(seen, ",")
end
local function condCounts(s)
    local _o, opens = s:gsub("%[if:", "")
    local _c, closes = s:gsub("%[/if%]", "")
    local _e, elses = s:gsub("%[else%]", "")
    return opens, closes, elses
end

local files = {}
local p = io.popen("ls locale/*.po 2>/dev/null")
if p then
    for line in p:lines() do files[#files + 1] = line end
    p:close()
end

t.test("there are locale files to check, and templates among them", function()
    assert(#files > 10, "expected the full locale set; found " .. #files)
    -- The templates must be EXTRACTED, whether or not anyone has translated
    -- them yet -- a translator who is never offered the string cannot fix it.
    -- The hero one is marked with N_() rather than _(), so the POT command
    -- has to pass --keyword=N_; without it this is the assertion that fails.
    local pot = io.open("locale/bookshelf.pot"):read("*a")
    assert(pot:find("page_count pages", 1, true),
        "the list's progress template is not in the catalogue")
    -- The top panel's templates are deliberately NOT catalogued: they carry
    -- no words, and that module cannot call gettext where its defaults are
    -- built anyway. The test below keeps them wordless.
    assert(not pot:find("book_time_left LEFT", 1, true),
        "the top panel's progress line has its English 'LEFT' back")
end)

t.test("a translated template keeps every token the source had", function()
    local bad = {}
    for _i = 1, #files do
        for _j, e in ipairs(templates(files[_i])) do
            if tokensOf(e.msgid) ~= tokensOf(e.msgstr) then
                bad[#bad + 1] = string.format("%s\n     msgid  %s\n     msgstr %s",
                    files[_i], tokensOf(e.msgid), tokensOf(e.msgstr))
            end
        end
    end
    eq(#bad, 0, "a translation dropped or invented a token:\n   "
       .. table.concat(bad, "\n   "))
end)

t.test("a translated template keeps its conditionals balanced", function()
    local bad = {}
    for _i = 1, #files do
        for _j, e in ipairs(templates(files[_i])) do
          if e.msgid:find("%[if:") then
            local o1, c1, e1 = condCounts(e.msgid)
            local o2, c2, e2 = condCounts(e.msgstr)
            if o2 ~= c2 or o1 ~= o2 or e1 ~= e2 then
                bad[#bad + 1] = string.format(
                    "%s\n     msgid  if=%d /if=%d else=%d\n     msgstr if=%d /if=%d else=%d",
                    files[_i], o1, c1, e1, o2, c2, e2)
            end
          end
        end
    end
    eq(#bad, 0, "a translation broke the conditional structure:\n   "
       .. table.concat(bad, "\n   "))
end)

t.test("the list's progress template is translatable and well formed", function()
    -- It carries English words ("of", "pages") inside token syntax, so it has
    -- to go through _() or it ships untranslated (issue 418).
    local ll = io.open("lib/bookshelf_list_lines.lua"):read("*a")
    assert(ll:match('template%s*=%s*_%('),
        "the list's progress line is no longer translatable")
    local n = 0
    for call in ll:gmatch('template%s*=%s*_%((.-)%),\n') do
        local tpl = ""
        for piece in call:gmatch('"([^"]*)"') do tpl = tpl .. piece end
        if tpl ~= "" then
            n = n + 1
            local _a, o = tpl:gsub("%[if:", "")
            local _b, c = tpl:gsub("%[/if%]", "")
            eq(o, c, "a shipped template's conditionals do not balance: " .. tpl)
        end
    end
    assert(n >= 1, "the list's translatable template is gone")
end)

t.test("no top panel default template contains a word to translate", function()
    -- The other half of issue 418 was "LEFT" in the top panel's progress
    -- line. Rather than translate it, the default now says the same thing
    -- with tokens alone -- the time already reads as remaining -- which is
    -- better than shipping an English word for fifteen languages to carry.
    --
    -- Asserted as an INVARIANT rather than left to memory: bookshelf_hero_
    -- regions is KOReader-free at load and so cannot call gettext where its
    -- defaults are built, which means any English word added to one of these
    -- is untranslatable by construction. Strip the tokens and conditionals
    -- and nothing with letters may remain.
    local hr = io.open("lib/bookshelf_hero_regions.lua"):read("*a")
    local checked = 0
    for tpl in hr:gmatch('template%s*=%s*"([^"]*)"') do
        if tpl ~= "" then
            checked = checked + 1
            local bare = tpl:gsub("%%[%a_]+{[^}]*}", " ")   -- %bar{rel}
                            :gsub("%%[%a_]+", " ")          -- %book_pct
                            :gsub("%[if:[%a_]+%]", " ")     -- [if:x]
                            :gsub("%[/if%]", " ")
                            :gsub("%[else%]", " ")
                            :gsub("\\x%x%x", " ")           -- escaped bytes
            local word = bare:match("%a%a+")
            assert(not word, string.format(
                "a top panel default carries the word %q, which cannot be "
                .. "translated from this module: %s", tostring(word), tpl))
        end
    end
    assert(checked >= 5, "expected the shipped templates; found " .. checked)
end)

t.done()
