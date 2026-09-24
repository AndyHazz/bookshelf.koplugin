-- tests/_test_spine_thickness_pages.lua
-- A spine's thickness comes from a count that does not depend on the font.
--
-- Usage (from plugin root): lua tests/_test_spine_thickness_pages.lua
--
-- Issue 387: "same length books look thicker when it's already read". Once a
-- book is opened, the shelf's count for it was KOReader's rendered one --
-- stats.pages, at the reader's own font size and margins -- and the spine
-- took its width from that. Thickness prefers layout-free counts now
-- (SpineShelf.thicknessPages), tags every persisted count with where it came
-- from (persistProgress), and never lets a rendered count overwrite a
-- scanned one. The page-count scan now also covers opened books whose only
-- count is the rendered one.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local ss = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local rp = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local mn = io.open("main.lua"):read("*a")

local function fn(src, name, args, env)
    local body = src:match("\nfunction SpineShelf%." .. name .. "%(" .. args:gsub("%p", "%%%0")
                           .. "%)\n(.-)\nend\n")
    assert(body, name .. " moved")
    return assert(load("return function(" .. args .. ")\n" .. body .. "\nend", name, "t", env or {}))()
end

-- ── the ladder ─────────────────────────────────────────────────────────────

local thick = fn(ss, "thicknessPages", "c")

t.test("the rendered count is the last resort", function()
    eq(thick{ rendered = 500 }, 500)
    eq(thick{ scan = 320, rendered = 500 }, 320, "the reader's font decided the width")
    eq(thick{ bim = 210, rendered = 500 }, 210)
end)

t.test("stable page numbers, then a scan, then a filename marker", function()
    -- A scan's count beats a p(N) marker: the reader chose its sources, and a
    -- marker is often Calibre's estimate (maintainer).
    eq(thick{ filename = 400, stable = 350, scan = 320, bim = 300, rendered = 500 }, 350)
    eq(thick{ filename = 400, scan = 320, rendered = 500 }, 320)
    eq(thick{ filename = 400, bim = 300, rendered = 500 }, 400)
end)

t.test("nothing known is nothing, and the width takes its default", function()
    eq(thick{}, nil)
end)

-- ── the store keeps a scan's count ────────────────────────────────────────

local rows = {}
local F = {
    get = function(fp) return rows[fp] end,
    put = function(fp, facts)
        local e = rows[fp] or {}
        for k, v in pairs(facts) do
            if v == false then e[k] = nil else e[k] = v end
        end
        rows[fp] = e
    end,
}
local persistPages = fn(ss, "persistPages", "fp, pages, src", {
    _facts = function() return F end,
})
local persist = fn(ss, "persistProgress", "fp, pages, status, src", {
    SCAN_TAGS = { print = true, user = true, layout = true, scan = true },
    _facts = function() return F end,
    _sidecarMtime = function() return 7 end,
    _progress_validated = {},
})

t.test("the scan's store write touches the count alone", function()
    rows = { ["/b.epub"] = { p = 300, psrc = "render", s = "reading", sk = true, m = 5 } }
    persistPages("/b.epub", 412, "print")
    eq(rows["/b.epub"].p, 412); eq(rows["/b.epub"].psrc, "print")
    eq(rows["/b.epub"].s, "reading", "the scan wiped a status it never read")
    eq(rows["/b.epub"].sk, true); eq(rows["/b.epub"].m, 5)
end)

t.test("a count is stored with where it came from", function()
    rows = {}
    persist("/b.epub", 300, "reading", "render")
    eq(rows["/b.epub"].p, 300); eq(rows["/b.epub"].psrc, "render")
end)

t.test("a rendered count does not overwrite a scanned one", function()
    rows = { ["/b.epub"] = { p = 320, psrc = "scan" } }
    persist("/b.epub", 500, "reading", "render")
    eq(rows["/b.epub"].p, 320, "first sight of a book replaced its scanned count")
    eq(rows["/b.epub"].psrc, "scan")
    eq(rows["/b.epub"].s, "reading", "the status must still be recorded")
end)

t.test("a new scan does replace an old one", function()
    rows = { ["/b.epub"] = { p = 320, psrc = "scan" } }
    persist("/b.epub", 330, nil, "print")
    eq(rows["/b.epub"].p, 330); eq(rows["/b.epub"].psrc, "print")
    persist("/b.epub", 900, nil, "layout")
    eq(rows["/b.epub"].psrc, "layout")
end)

t.test("a rendered count does not overwrite a layout one either", function()
    rows = { ["/b.epub"] = { p = 900, psrc = "layout" } }
    persist("/b.epub", 500, "reading", "render")
    eq(rows["/b.epub"].p, 900); eq(rows["/b.epub"].psrc, "layout")
end)

t.test("no count leaves the stored one alone", function()
    rows = { ["/b.epub"] = { p = 320, psrc = "scan" } }
    persist("/b.epub", nil, nil, nil)
    eq(rows["/b.epub"].p, 320)
end)

-- ── the wiring ─────────────────────────────────────────────────────────────

t.test("readProgress says which rung answered", function()
    local body = rp:match("\nfunction Repo%.readProgress%(filepath%)\n(.-)\nend\n")
    assert(body)
    for _i, s in ipairs({ '"stable"', '"render"', '"store"', '"filename"' }) do
        assert(body:find("page_src = " .. s, 1, true), "no " .. s .. " source")
    end
    assert(body:find("return pct, status, rating, page_count, page_num, page_src", 1, true))
end)

t.test("both spine widths come from the thickness ladder", function()
    local n = select(2, ss:gsub("SpineLayout%.spineWidthDp%(%s*SpineShelf%.thicknessPages%(thick%)%)", ""))
    eq(n, 2, "the spine or the face-out's page block still reads the rendered count")
    assert(not ss:find("SpineLayout.spineWidthDp(pages)", 1, true))
end)

t.test("the scan renders at the reader's layout, in the reader's order", function()
    -- Settings before the load, the book's language after it, then render:
    -- the reader's order, and settings applied after the load cost a PW5 2s
    -- a book in restyling.
    local before = mn:find("pcall(Layout.beforeLoad, doc)", 1, true)
    local load   = before and mn:find("doc:loadDocument()", before, true)
    local after  = load and mn:find("pcall(Layout.afterLoad, doc)", load, true)
    local render = after and mn:find("if doc.render then doc:render() end", after, true)
    assert(before, "the render is back at crengine's defaults")
    assert(load and after and render, "beforeLoad, loadDocument, afterLoad, render: out of order")
end)

t.test("the scan tags its counts and probes opened books with only a rendered one", function()
    assert(mn:find('SpineShelf.persistPages(fp, pages, tag)', 1, true))
    for _i, s in ipairs({ 'persist(fp, n, "print")',
                          'persist(fp, linked[fp], "print")',
                          'persist(fp, pages, "user")' }) do
        assert(mn:find(s, 1, true), "the scan no longer tags: " .. s)
    end
    -- Counts live in bookshelf's own store only: no sidecar reads or writes
    -- in the scan's main-process work (device report: the shelf froze).
    local body = mn:match("\nfunction Bookshelf:scanPageCounts%(opts%)\n(.-)\nend\n")
    assert(body, "scanPageCounts moved")
    assert(not body:find("saveSetting(\"pagemap_doc_pages\"", 1, true), "the scan writes sidecars again")
    assert(not body:find("Repo.readProgress(fp)", 1, true) or body:find("local _p, _s, _r, pc", 1, true),
        "the scan reads a sidecar per stored count again")
    assert(mn:find("if trusted then", 1, true),
        "an opened book is still skipped for having any count")
end)

t.done()
