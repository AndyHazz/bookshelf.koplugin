-- tests/_test_folder_sections.lua
-- lib/bookshelf_folder_sections.lua: turning a library walk into shelf
-- sections, one per directory that actually holds books.
--
-- The spine shelf flattens any item carrying `books` into a badged run, so
-- the Home-folders source only has to hand it the right grouping. The rules
-- that are easy to get wrong and impossible to see on a screenshot live
-- here: tree order, and the wrapper-folder fold that stops a Calibre
-- library (Author/Title/book.epub) becoming one section per book.
--
-- Usage (from plugin root): lua tests/_test_folder_sections.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H  = dofile("tests/_helpers.lua")
local t  = H.runner()
local eq = H.eq

local FS = require("lib/bookshelf_folder_sections")

local ROOT = "/books"

-- Walk records, as cachedWalk hands them over.
local function walk(...)
    local out = {}
    for _, fp in ipairs({ ... }) do out[#out + 1] = { fp = fp, mtime = 0, size = 0 } end
    return out
end

-- A section's shape, flattened for readable comparisons.
local function shape(sections)
    local out = {}
    for i, s in ipairs(sections) do
        out[i] = { label = s.label, n = #s.fps }
    end
    return out
end

t.test("sections: books loose at the library root form one unlabelled run", function()
    local s = FS.group(walk(ROOT .. "/one.epub", ROOT .. "/two.epub"), ROOT)
    eq(#s, 1)
    eq(s[1].label, nil)
    eq(s[1].path, ROOT)
    eq(#s[1].fps, 2)
end)

t.test("sections: a subfolder becomes its own run, labelled with its name", function()
    local s = FS.group(walk(
        ROOT .. "/loose.epub",
        ROOT .. "/Culture/a.epub",
        ROOT .. "/Culture/b.epub"), ROOT)
    eq(shape(s), { { label = nil, n = 1 }, { label = "Culture", n = 2 } })
    eq(s[2].path, ROOT .. "/Culture")
end)

t.test("sections: a parent's own books stand before its children's runs", function()
    -- Tree order, so a folder and everything under it stay together on the
    -- shelf instead of being scattered by name.
    local s = FS.group(walk(
        ROOT .. "/Discworld/Witches/w1.epub",
        ROOT .. "/Discworld/Witches/w2.epub",
        ROOT .. "/Discworld/Mort.epub",
        ROOT .. "/Discworld/Guards.epub",
        ROOT .. "/Discworld/CityWatch/c1.epub",
        ROOT .. "/Discworld/CityWatch/c2.epub",
        ROOT .. "/CityBooks/x.epub",
        ROOT .. "/CityBooks/y.epub"), ROOT)
    eq(shape(s), {
        { label = "CityBooks", n = 2 },
        { label = "Discworld", n = 2 },
        { label = "CityWatch", n = 2 },
        { label = "Witches",   n = 2 },
    })
end)

t.test("sections: a wrapper folder's book joins its parent's run", function()
    -- One book, no subfolders: the existing spine rule is that such a folder
    -- stands AS its book, so it must not earn a section of its own.
    local s = FS.group(walk(
        ROOT .. "/Banks/Culture/Excession/Excession.epub",
        ROOT .. "/Banks/Culture/Inversions/Inversions.epub"), ROOT)
    eq(shape(s), { { label = "Culture", n = 2 } })
end)

t.test("sections: a Calibre tree gives one run per author, not one per book", function()
    -- Author/Title/book.epub is the shape that makes the fold load-bearing.
    local s = FS.group(walk(
        ROOT .. "/Iain M. Banks/Consider Phlebas/cp.epub",
        ROOT .. "/Iain M. Banks/Excession/ex.epub",
        ROOT .. "/Terry Pratchett/Mort/mort.epub"), ROOT)
    eq(shape(s), {
        { label = "Iain M. Banks", n = 2 },
        { label = "Terry Pratchett", n = 1 },
    })
end)

t.test("sections: one book beside a subfolder is not a wrapper folder", function()
    -- The fold is for directories that hold a book AND NOTHING ELSE. With a
    -- subfolder present the directory is a real shelf section.
    local s = FS.group(walk(
        ROOT .. "/Series/only.epub",
        ROOT .. "/Series/Extras/e1.epub",
        ROOT .. "/Series/Extras/e2.epub"), ROOT)
    eq(shape(s), { { label = "Series", n = 1 }, { label = "Extras", n = 2 } })
end)

t.test("sections: a folder holding only subfolders gets no run of its own", function()
    local s = FS.group(walk(
        ROOT .. "/Fiction/SF/a.epub",
        ROOT .. "/Fiction/SF/b.epub",
        ROOT .. "/Fiction/Crime/c.epub",
        ROOT .. "/Fiction/Crime/d.epub"), ROOT)
    eq(shape(s), { { label = "Crime", n = 2 }, { label = "SF", n = 2 } })
end)

t.test("sections: nothing in, nothing out", function()
    eq(#FS.group({}, ROOT), 0)
    eq(#FS.group(nil, ROOT), 0)
end)

t.test("sections: a trailing slash on the root is not a different library", function()
    local s = FS.group(walk(ROOT .. "/Culture/a.epub",
                            ROOT .. "/Culture/b.epub"), ROOT .. "/")
    eq(shape(s), { { label = "Culture", n = 2 } })
end)

t.test("sections: books outside the root are ignored rather than mis-filed", function()
    local s = FS.group(walk(
        "/elsewhere/stray.epub",
        ROOT .. "/Culture/a.epub",
        ROOT .. "/Culture/b.epub"), ROOT)
    eq(shape(s), { { label = "Culture", n = 2 } })
end)

t.test("sections: a wrapper folder at the top level joins the root run", function()
    -- Same rule one level up: a lone book in its own directory belongs on
    -- the root shelf, not behind a badge of its own name.
    local s = FS.group(walk(
        ROOT .. "/loose.epub",
        ROOT .. "/Katabasis/Katabasis.epub"), ROOT)
    eq(shape(s), { { label = nil, n = 2 } })
end)

t.done()
