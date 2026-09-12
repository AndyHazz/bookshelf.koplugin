-- tests/_test_pagemap_probe.lua
-- lib/bookshelf_pagemap_probe.lua: the publisher page-count probe.
--
-- The probe opens a libarchive reader per book and must hand it back on
-- EVERY exit, including the ones it did not plan for. Its allocations are
-- ffi.gc-wrapped, so a reader it drops is not freed when it goes out of
-- scope -- it waits for LuaJIT to collect the small cdata handle, and
-- LuaJIT paces its collector off the Lua heap, which a scan like this barely
-- moves. Across a library that is how a device runs out of memory (issue
-- 388: a 1228-book scan hanging at a different book every run).
--
-- Everything inside publisherPages runs in one pcall, so a corrupt entry
-- that throws mid-parse used to skip the close entirely.
--
-- Usage (from plugin root): lua tests/_test_pagemap_probe.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

package.loaded["logger"] = { dbg = function() end, warn = function() end }

-- A fake archive. `throw_on` names a key whose extraction blows up, standing
-- in for a corrupt or truncated entry.
local function installArchiver(entries, throw_on)
    local state = { closed = 0, opened = 0 }
    package.loaded["ffi/archiver"] = {
        Reader = {
            new = function(_self)
                return {
                    entries = entries,
                    open = function(_s) state.opened = state.opened + 1 return true end,
                    iterate = function() return function() return nil end end,
                    extractToMemory = function(_s, key)
                        if key == throw_on then
                            error("corrupt entry: " .. tostring(key))
                        end
                        return entries[key]
                    end,
                    close = function() state.closed = state.closed + 1 end,
                }
            end,
        },
    }
    return state
end

local function freshProbe()
    package.loaded["lib/bookshelf_pagemap_probe"] = nil
    return dofile("lib/bookshelf_pagemap_probe.lua")
end

local CONTAINER = [[<?xml version="1.0"?><container><rootfiles>
<rootfile full-path="OEBPS/content.opf"/></rootfiles></container>]]

local OPF_NAV = [[<package><manifest>
<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
</manifest><spine/></package>]]

local NAV = [[<html><nav epub:type="page-list"><ol>
<li><a href="c1.html#p1">1</a></li>
<li><a href="c1.html#p2">2</a></li>
<li><a href="c1.html#p3">3</a></li>
</ol></nav></html>]]

t.test("probe: counts an EPUB3 page-list and hands the reader back", function()
    local state = installArchiver({
        ["META-INF/container.xml"] = CONTAINER,
        ["OEBPS/content.opf"]      = OPF_NAV,
        ["OEBPS/nav.xhtml"]        = NAV,
    })
    local pages, source = freshProbe().publisherPages("/books/a.epub")
    assert(pages == 3, "expected 3 pages, got " .. tostring(pages))
    assert(source == "page-list", "got " .. tostring(source))
    assert(state.closed == 1, "reader not closed on the success path")
end)

t.test("probe: a book with no page list still hands the reader back", function()
    local state = installArchiver({
        ["META-INF/container.xml"] = CONTAINER,
        ["OEBPS/content.opf"]      = [[<package><manifest/><spine/></package>]],
    })
    local pages = freshProbe().publisherPages("/books/b.epub")
    assert(pages == nil, "no page list, so no count")
    assert(state.closed == 1, "reader not closed when nothing was found")
end)

t.test("probe: a corrupt entry must not cost the reader", function()
    -- The bug: the throw propagated to publisherPages' own pcall, which
    -- swallowed it, and the reader was never closed -- left for a collector
    -- that cannot see what it holds.
    local state = installArchiver({
        ["META-INF/container.xml"] = CONTAINER,
        ["OEBPS/content.opf"]      = OPF_NAV,
        ["OEBPS/nav.xhtml"]        = NAV,
    }, "OEBPS/nav.xhtml")
    local pages = freshProbe().publisherPages("/books/c.epub")
    assert(pages == nil, "a corrupt entry yields no count")
    assert(state.closed == 1,
        "the reader was dropped instead of closed, so its libarchive memory "
        .. "waits on a collector that cannot see it (issue 388)")
end)

t.test("probe: a container that throws still hands the reader back", function()
    local state = installArchiver({
        ["META-INF/container.xml"] = CONTAINER,
    }, "META-INF/container.xml")
    local pages = freshProbe().publisherPages("/books/d.epub")
    assert(pages == nil, "no container, no count")
    assert(state.closed == 1, "reader not closed when the very first read threw")
end)

t.test("probe: a file that is not an EPUB opens nothing at all", function()
    local state = installArchiver({})
    local pages = freshProbe().publisherPages("/books/e.pdf")
    assert(pages == nil, "not an epub")
    assert(state.opened == 0, "should not have opened a non-epub")
    assert(state.closed == 0, "nothing opened, nothing to close")
end)

t.done()
