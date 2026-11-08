-- tests/_test_spine_extraction_refresh.lua
-- A book whose metadata arrives after the shelf first painted it must lose
-- its stand-in spine: the file name ("Author - Title", as OPDS names
-- downloads) and the grey default look. The poll's ready branch rebuilt
-- the rows from the spine caches, which still held the stand-in, so the
-- spine kept the author in its title with authors switched off (GitHub
-- issue 477).
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("the extraction poll drops the spine caches of the books that became ready", function()
    -- The poll collects ready books; _applyExtractionReady applies them.
    local poll = src:match("function BookshelfWidget:_pollExtraction%(.-\nend\n")
    assert(poll and poll:find("self:_applyExtractionReady()", 1, true), "the poll no longer applies ready books")
    local apply = src:match("function BookshelfWidget:_applyExtractionReady%(.-\nend\n")
    assert(apply, "_applyExtractionReady moved")
    local branch = apply:match("(.-)self:_swapShelvesInPlace%(%)")
    assert(branch, "the ready branch no longer swaps the shelves")
    assert(branch:find("invalidateBook(fp, true)", 1, true), "a ready book's spine caches are kept")
    assert(branch:find("self:_expireSpineFetch()", 1, true), "the cached spine page still holds the stand-in")
end)

t.done()
