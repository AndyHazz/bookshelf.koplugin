-- tests/_test_page_count_report.lua
-- Tokens.pageCountReportHtml: the page-count scan's closing report.
--
-- The scan can end three ways and the heading has to tell them apart. Two
-- were already distinct; the third was being reported as the user's doing.
-- Trapper:dismissableRunInSubprocess returns the same "not completed" for a
-- dismissed book and for a fork that never started, and after a long scan on
-- a small device it is the fork that fails -- so a reader who touched nothing
-- was told they had cancelled, and went looking for a stray tap (issue 388).
--
-- Usage (from plugin root): lua tests/_test_page_count_report.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

package.loaded["logger"] = { dbg = function() end, warn = function() end }
local _i18n = {
    gettext  = function(s) return s end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["bookshelf_i18n"] = _i18n
package.loaded["lib/bookshelf_i18n"] = _i18n
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
})

local Tokens = dofile("lib/bookshelf_tokens.lua")

local function heading(html)
    return (html:match("<h1>(.-)</h1>")) or ""
end

t.test("report: a finished scan is just a report", function()
    local html = Tokens.pageCountReportHtml{
        publisher = { { name = "A", pages = 100 } },
    }
    assert(heading(html) == "Page count report",
        "got " .. heading(html))
end)

t.test("report: a scan the reader stopped says cancelled", function()
    local html = Tokens.pageCountReportHtml{
        cancelled = true,
        remaining = 12,
    }
    assert(heading(html):find("cancelled", 1, true),
        "got " .. heading(html))
end)

t.test("report: a scan that could not start does not blame the reader", function()
    local html = Tokens.pageCountReportHtml{
        cancelled       = true,
        could_not_start = true,
        remaining       = 900,
    }
    local h = heading(html)
    assert(not h:find("cancelled", 1, true),
        "a scan that never started was not cancelled by anyone: " .. h)
    assert(h:find("could not start", 1, true) or h:find("couldn't start", 1, true),
        "the heading should say it could not start: " .. h)
    -- And say why, since "it didn't start" on its own helps nobody.
    assert(html:find("memory", 1, true),
        "the report should point at the likely cause")
end)

t.test("report: could_not_start without cancelled is still handled", function()
    -- Defensive: the flag should drive the heading on its own.
    local html = Tokens.pageCountReportHtml{ could_not_start = true }
    assert(not heading(html):find("cancelled", 1, true),
        "got " .. heading(html))
end)

t.done()
