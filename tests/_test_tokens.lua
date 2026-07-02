-- tests/_test_tokens.lua
-- Pure-Lua test runner. No KOReader dependencies.
-- Usage: cd into the plugin dir, then `lua tests/_test_tokens.lua`.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = {
    secondsToClockDuration = function(s)
        if not s or s <= 0 then return "" end
        local h = math.floor(s / 3600)
        local m = math.floor((s % 3600) / 60)
        return string.format("%dh %02dm", h, m)
    end,
}
-- Stub both require keys: lib code requires the canonical "lib/bookshelf_i18n"
-- (e.g. bookshelf_tokens for its catalogue descriptions), some callers the
-- bare "bookshelf_i18n". gettext is identity so the catalogue holds source.
local _i18n_stub = {
    gettext = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["bookshelf_i18n"] = _i18n_stub
package.loaded["lib/bookshelf_i18n"] = _i18n_stub
_G.G_reader_settings = setmetatable({}, {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    __index = function() return function() return false end end,
})

local Tokens = dofile("lib/bookshelf_tokens.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

-- ============================================================================
test("smoke: Tokens module loads", function()
    assert(type(Tokens) == "table", "Tokens is not a table")
    assert(type(Tokens.expand) == "function", "Tokens.expand missing")
end)

local function bookFixture()
    return {
        title = "Dune",
        author = "Frank Herbert",
        authors = { "Frank Herbert" },
        series = "Dune #1",
        series_name = "Dune",
        series_num = "1",
        filename = "dune",
        lang = "en",
        format = "EPUB",
    }
end

test("metadata: %title", function()
    eq(Tokens.expand("%title", bookFixture()), "Dune")
end)
test("metadata: %author", function()
    eq(Tokens.expand("%author", bookFixture()), "Frank Herbert")
end)
test("metadata: %series", function()
    eq(Tokens.expand("%series", bookFixture()), "Dune #1")
end)
test("metadata: literal text passes through", function()
    eq(Tokens.expand("Reading %title by %author.", bookFixture()),
       "Reading Dune by Frank Herbert.")
end)
test("metadata: %hardcover_rating formats cached rating", function()
    local b = bookFixture(); b.hardcover_rating = 4.5
    eq(Tokens.expand("%hardcover_rating", b), "4.5")
end)
-- Nerd Font star glyphs: full U+F005, half-empty U+F123, empty U+F006.
local HC_STAR  = "\xef\x80\x85"
local HC_HALF  = "\xef\x84\xa3"
local HC_EMPTY = "\xef\x80\x86"

test("metadata: %hardcover_stars renders half-star ratings", function()
    local b = bookFixture(); b.hardcover_rating = 4.5
    eq(Tokens.expand("%hardcover_stars", b),
       HC_STAR:rep(4) .. HC_HALF)
end)
-- User ratings stay in native KOReader integer format (plain Unicode stars),
-- kept deliberately separate from the Hardcover half-star rendering.
local U_STAR  = "\xE2\x98\x85"  -- ★ U+2605
local U_EMPTY = "\xE2\x98\x86"  -- ☆ U+2606
test("metadata: %rating renders whole stars (native integer)", function()
    local b = bookFixture(); b.rating = 3
    eq(Tokens.expand("%rating", b), U_STAR:rep(3) .. U_EMPTY:rep(2))
end)
test("metadata: %rating floors a fractional rating (no half stars)", function()
    local b = bookFixture(); b.rating = 4.5
    eq(Tokens.expand("%rating", b), U_STAR:rep(4) .. U_EMPTY)
end)
test("metadata: %rating stays empty for an unrated book", function()
    eq(Tokens.expand("%rating", bookFixture()), "")
end)
test("metadata: empty Hardcover rating stays empty", function()
    eq(Tokens.expand("%hardcover_rating|%hardcover_stars", bookFixture()), "|")
end)
test("metadata: missing token resolves to empty", function()
    local b = bookFixture(); b.series = nil
    eq(Tokens.expand("%series", b), "")
end)

test("position: %page_num / %page_count", function()
    local b = bookFixture(); b.page_num = 142; b.page_count = 688
    eq(Tokens.expand("%page_num / %page_count", b), "142 / 688")
end)
test("position: %book_pct rounds to integer percent", function()
    local b = bookFixture(); b.book_pct = 0.213
    eq(Tokens.expand("%book_pct", b), "21%")
end)
test("position: %book_pct_left", function()
    local b = bookFixture(); b.book_pct = 0.213
    eq(Tokens.expand("%book_pct_left", b), "79%")
end)
test("position: %pages_left = page_count - page_num", function()
    local b = bookFixture(); b.page_num = 142; b.page_count = 688
    eq(Tokens.expand("%pages_left", b), "546")
end)

local function clockState()
    return { now = os.time({ year=2026, month=5, day=3, hour=14, min=35, sec=0 }) }
end

test("time: %time_24h", function()
    eq(Tokens.expand("%time_24h", bookFixture(), clockState()), "14:35")
end)
test("time: %time_12h", function()
    eq(Tokens.expand("%time_12h", bookFixture(), clockState()), "2:35 PM")
end)
test("date: %weekday", function()
    eq(Tokens.expand("%weekday", bookFixture(), clockState()), "Sunday")
end)
test("datetime: custom strftime", function()
    eq(Tokens.expand("%datetime{%d %B}", bookFixture(), clockState()), "03 May")
end)

test("stats: %book_time_left formats minutes → 'Nh MMm'", function()
    local b = bookFixture(); b.book_time_left_minutes = 131
    eq(Tokens.expand("%book_time_left", b), "2h 11m")
end)
test("stats: missing → empty", function()
    eq(Tokens.expand("%book_time_left", bookFixture()), "")
end)
test("annotations: %highlights pluralisation", function()
    local b = bookFixture(); b.highlights = 3
    eq(Tokens.expand("%highlights", b), "3")
end)
test("device: %batt with state", function()
    eq(Tokens.expand("%batt", bookFixture(), { batt = 73 }), "73%")
end)
test("device: %wifi off → wifi-off Nerd Font glyph", function()
    eq(Tokens.expand("%wifi", bookFixture(), { wifi = "off" }), "\xee\xb2\xa9")
end)
test("device: %wifi on → wifi Nerd Font glyph", function()
    eq(Tokens.expand("%wifi", bookFixture(), { wifi = "on" }), "\xee\xb2\xa8")
end)

test("if: token-truthy", function()
    local b = bookFixture()
    eq(Tokens.expand("[if:series]Series: %series_name[/if]", b), "Series: Dune")
end)
test("if: token-falsy → empty", function()
    local b = bookFixture(); b.series = nil; b.series_name = nil
    eq(Tokens.expand("[if:series]Series: %series_name[/if]", b), "")
end)
test("if/else: book_pct numeric compare", function()
    local b = bookFixture(); b.book_pct = 0.7
    eq(Tokens.expand("[if:book_pct>50]Almost done[else]%book_pct[/if]", b), "Almost done")
end)
test("if: not operator", function()
    local b = bookFixture(); b.series = nil
    eq(Tokens.expand("[if:not series]Standalone[/if]", b), "Standalone")
end)
test("if: nested", function()
    local b = bookFixture(); b.book_pct = 0.95
    eq(Tokens.expand("[if:book_pct>50][if:book_pct>90]Final![else]Halfway+[/if][/if]", b), "Final!")
end)
test("if: equality with quoted string", function()
    eq(Tokens.expand([=[[if:author="Frank Herbert"]✓[/if]]=], bookFixture()), "✓")
end)
test("if: full_width gates on state.full_width (issue 178)", function()
    eq(Tokens.expand("%title[if:full_width] · DATE[/if]", bookFixture(), { full_width = true }),
       "Dune · DATE")
    -- absent / false -> empty (cover-view narrow status)
    eq(Tokens.expand("%title[if:full_width] · DATE[/if]", bookFixture()), "Dune")
    eq(Tokens.expand("%title[if:full_width] · DATE[/if]", bookFixture(), {}), "Dune")
end)
test("device: [if:connected] gates the Wi-Fi icon on actual link (issue 181)", function()
    eq(Tokens.expand("[if:connected]ON[/if]", bookFixture(), { connected = "yes" }), "ON")
    eq(Tokens.expand("[if:connected]ON[/if]", bookFixture(), { connected = "no"  }), "")
    -- bookends-style explicit comparison works too
    eq(Tokens.expand("[if:connected=yes]ON[/if]", bookFixture(), { connected = "yes" }), "ON")
    eq(Tokens.expand("[if:connected=yes]ON[/if]", bookFixture(), { connected = "no"  }), "")
end)

test("inline: [b]bold[/b] tags survive expansion", function()
    eq(Tokens.expand("[b]%title[/b]", bookFixture()), "[b]Dune[/b]")
end)
test("inline: nested [b][i] preserved", function()
    eq(Tokens.expand("[b][i]%title[/i][/b]", bookFixture()), "[b][i]Dune[/i][/b]")
end)

test("width: {N} cap is preserved as marker for renderer", function()
    -- The token engine resolves the value but leaves {N} intact, so the
    -- renderer can measure pixels and truncate. We test that the token
    -- expansion happens AND the width-cap suffix is preserved.
    local b = bookFixture(); b.title = "An extremely long book title that goes on"
    eq(Tokens.expand("%title{200}", b), "An extremely long book title that goes on{200}")
end)

test("autoHide: line of all empty tokens is hidden", function()
    local b = bookFixture(); b.book_time_left_minutes = nil
    eq(Tokens.isEmpty(Tokens.expand("%book_time_left", b)), true)
end)
test("autoHide: line with literal text is not empty", function()
    eq(Tokens.isEmpty(Tokens.expand("Reading %title", bookFixture())), false)
end)

test("if: or before and (left-to-right operator scan)", function()
    local b = bookFixture(); b.series = nil; b.book_pct = 0.95
    -- 'series' is empty (false), but 'book_pct>50' is true; left-to-right
    -- evaluation: false or true = true; (true) and (true [book_pct>0]) = true
    eq(Tokens.expand("[if:series or book_pct>50]yes[/if]", b), "yes")
end)

test("if: unknown comparison operator → false (defensive default)", function()
    -- '==' is not a supported operator. The atom should evaluate to false,
    -- not silently flip to true via 'not nil'.
    eq(Tokens.expand("[if:not author==\"Frank\"]matched[/if]", bookFixture()), "matched")
end)

test("isEmpty: only [b][i][u] tags strip, not arbitrary single-letter tags", function()
    -- A future hypothetical [c]color[/c] tag should NOT be stripped by isEmpty.
    eq(Tokens.isEmpty("[c]hi[/c]"), false)
end)

test("nightmode: sun glyph when night_mode off (default mock)", function()
    -- The shared mock returns false for any G_reader_settings:isTrue check,
    -- so the expander takes the day branch and emits U+EC98 (weather-sunny).
    eq(Tokens.expand("%nightmode", bookFixture()), "\xee\xb2\x98")
end)

test("nightmode: never expands to literal %nightmode", function()
    local result = Tokens.expand("%nightmode", bookFixture())
    assert(result ~= "%nightmode", "expander missing — token leaked through")
end)

test("bar: %bar survives expansion as literal (renderer splits on it)", function()
    eq(Tokens.expand("%bar", bookFixture()), "%bar")
    -- Other tokens around %bar still expand normally.
    local b = bookFixture(); b.book_pct = 0.36
    eq(Tokens.expand("%book_pct  %bar  done", b), "36%  %bar  done")
end)

test("description: empty when book has no blurb", function()
    local b = bookFixture(); b.description = nil
    eq(Tokens.expand("%description", b), "")
end)

test("description: passes plain text through", function()
    local b = bookFixture(); b.description = "A novel about sandworms."
    eq(Tokens.expand("%description", b), "A novel about sandworms.")
end)

test("description: strips HTML tags", function()
    local b = bookFixture(); b.description = "<p>Hello <b>world</b>.</p>"
    eq(Tokens.expand("%description", b), "Hello world.")
end)

test("description: <br> becomes newline", function()
    local b = bookFixture(); b.description = "Line one<br/>Line two"
    eq(Tokens.expand("%description", b), "Line one\nLine two")
end)

test("description: </p> becomes blank line", function()
    local b = bookFixture(); b.description = "<p>One</p><p>Two</p>"
    eq(Tokens.expand("%description", b), "One\n\nTwo")
end)

test("description: decodes named entities", function()
    local b = bookFixture(); b.description = "Tom &amp; Jerry &lt;3"
    eq(Tokens.expand("%description", b), "Tom & Jerry <3")
end)

test("description: decodes numeric entity to UTF-8", function()
    local b = bookFixture(); b.description = "It&#8217;s good"
    eq(Tokens.expand("%description", b), "It\xE2\x80\x99s good")
end)

test("description: trims surrounding whitespace", function()
    local b = bookFixture(); b.description = "   leading and trailing   "
    eq(Tokens.expand("%description", b), "leading and trailing")
end)

test("description: decodes &rsquo; / &lsquo; / &ldquo; / &rdquo;", function()
    local b = bookFixture()
    b.description = "&lsquo;hi&rsquo; said &ldquo;the cat&rdquo;"
    eq(Tokens.expand("%description", b),
       "\xE2\x80\x98hi\xE2\x80\x99 said \xE2\x80\x9Cthe cat\xE2\x80\x9D")
end)

test("description: decodes &mdash; / &ndash; / &hellip; / &nbsp;", function()
    local b = bookFixture()
    b.description = "wait&hellip; ndash&ndash;mdash&mdash;nbsp&nbsp;end"
    eq(Tokens.expand("%description", b),
       "wait\xE2\x80\xA6 ndash\xE2\x80\x93mdash\xE2\x80\x94nbsp\xC2\xA0end")
end)

test("description: decodes hex numeric entity", function()
    local b = bookFixture()
    b.description = "It&#x2019;s &#xA9; mine"
    eq(Tokens.expand("%description", b), "It\xE2\x80\x99s \xC2\xA9 mine")
end)

test("description: <div> blocks become paragraphs", function()
    local b = bookFixture()
    b.description = "<div>One</div><div>Two</div>"
    eq(Tokens.expand("%description", b), "One\n\nTwo")
end)

test("description: collapses 3+ newlines to 2", function()
    local b = bookFixture()
    -- Source has literal \n between </p> and <p>: </p> → \n\n, then the
    -- existing \n adds a third → would render as a triple-blank line.
    b.description = "<p>One</p>\n<p>Two</p>"
    eq(Tokens.expand("%description", b), "One\n\nTwo")
end)

test("description: case-insensitive tags (BR, P, DIV)", function()
    local b = bookFixture()
    b.description = "<P>Upper</P><BR/>after"
    eq(Tokens.expand("%description", b), "Upper\n\nafter")
end)

-- Hardcover reviews HTML (sanitiser + builder) ------------------------------
local function has(s, sub, msg)
    if not (type(s) == "string" and s:find(sub, 1, true)) then
        error((msg or "missing substring") .. " : [" .. tostring(sub)
            .. "] not in [" .. tostring(s) .. "]", 2)
    end
end
local function hasnt(s, sub, msg)
    if type(s) == "string" and s:find(sub, 1, true) then
        error((msg or "unexpected substring") .. " : [" .. tostring(sub) .. "]", 2)
    end
end

test("sanitiseReviewHtml keeps whitelisted tags, strips attrs + unknown tags", function()
    local out = Tokens.sanitiseReviewHtml(
        '<p class="x">Hi <i>there</i> <span>kept-text</span></p>')
    eq(out, "<p>Hi <i>there</i> kept-text</p>")
end)
test("sanitiseReviewHtml drops script blocks with their content", function()
    local out = Tokens.sanitiseReviewHtml('<p>ok</p><script>alert(1)</script>')
    eq(out, "<p>ok</p>")
end)
test("sanitiseReviewHtml normalises self-closing br and tag case", function()
    eq(Tokens.sanitiseReviewHtml('a<BR/>b'), "a<br>b")
end)
test("sanitiseReviewHtml strips <br> padding at paragraph edges", function()
    -- leading <br> after a blockquote (the quote/attribution gap) is dropped;
    -- the real break after the attribution is kept.
    eq(Tokens.sanitiseReviewHtml(
        "<blockquote>q</blockquote><p><br><strong>cite</strong><br>text<br></p>"),
       "<blockquote>q</blockquote><p><strong>cite</strong><br>text</p>")
end)
test("sanitiseReviewHtml returns empty for nil/empty", function()
    eq(Tokens.sanitiseReviewHtml(nil), "")
    eq(Tokens.sanitiseReviewHtml(""), "")
end)

test("reviewsHtml italicises reviewer names and escapes them", function()
    local html = Tokens.reviewsHtml{
        title = "Dune", rating = 4, ratings_count = 10, reviews_count = 1,
        reviews = { { user_name = "A<B", text = "<p>Great</p>" } },
    }
    has(html, "<i>A&lt;B</i>", "reviewer name not italic+escaped")
    has(html, "<b>Review by</b>", "missing bold Review-by label")
end)
test("reviewsHtml puts the book title in a large h1 heading, escaped", function()
    local html = Tokens.reviewsHtml{
        title = "Tom & Jerry", reviews = { { user_name = "x", text = "hi" } },
    }
    has(html, "<h1>Tom &amp; Jerry</h1>", "title not a large escaped heading")
end)
test("reviewsHtml renders shared star glyphs for each review", function()
    local html = Tokens.reviewsHtml{
        title = "T",
        reviews = { { user_name = "x", rating = 4, text = "hi" } },
    }
    -- Same glyph row as the ratings area (Tokens.starString, F005/F123/F006),
    -- embedded via @font-face, on its own line above each review. 4 -> ★★★★☆
    -- (the overall rating/counts/Refresh line is a native widget row now, not
    -- part of this HTML -- see bookshelf_widget.lua's ReviewsHeader).
    has(html, '<p class="stars">' .. HC_STAR:rep(4) .. HC_EMPTY .. "</p>", "per-review star row")
end)
test("reviewsHtml formats the date (ISO fallback without datetime module)", function()
    local html = Tokens.reviewsHtml{
        title = "T",
        reviews = { { user_name = "x", reviewed_at = "2026-04-02T00:00:00", text = "hi" } },
    }
    has(html, "<i>2026-04-02</i>", "date not rendered in italics")
end)
test("reviewsHtml embeds the sanitised review body (script stripped)", function()
    local html = Tokens.reviewsHtml{
        title = "T",
        reviews = { { user_name = "x", text = "<p>Good <i>read</i></p><script>x</script>" } },
    }
    has(html, "<p>Good <i>read</i></p>", "sanitised body missing")
    hasnt(html, "<script>", "script leaked into output")
end)

test("sanitiseReviewHtml: collapses stacked breaks and malformed </br>", function()
    -- Real shape from a Hardcover review that rendered a big mid-review gap:
    -- stacked "<br><br></br>" runs after a paragraph.
    local out = Tokens.sanitiseReviewHtml(
        "<p>quote</p><br><br></br><p>(p.196)</p><br><br></br><br><br></br><br><br></br>")
    assert(not out:find("</br>", 1, true), "malformed </br> survived: " .. out)
    assert(not out:find("<br>%s*<br>"), "stacked <br> not collapsed: " .. out)
    assert(not out:find("</p>%s*<br>"), "<br> hugging </p> survived: " .. out)
    assert(not out:find("<br>%s*$"), "trailing <br> survived: " .. out)
end)

test("sanitiseReviewHtml: drops break between block boundary and paragraph", function()
    local out = Tokens.sanitiseReviewHtml("</blockquote><br><br><p>x</p>")
    eq(out, "</blockquote><p>x</p>", "boundary break not dropped:")
end)

test("sanitiseReviewHtml: keeps a single intra-paragraph break", function()
    local out = Tokens.sanitiseReviewHtml("<p>line one<br>line two</p>")
    eq(out, "<p>line one<br>line two</p>", "single intra-paragraph break lost:")
end)

test("autoLinkReportHtml: lists linked books and counts no-id (exact mode)", function()
    local html = Tokens.autoLinkReportHtml{
        best_guess = false,
        linked  = { { name = "Time Shelter", matched = "Time Shelter", author = "Georgi Gospodinov" } },
        nomatch = { { name = "Obscure Title" } },
        no_id   = 184,
    }
    assert(html:find("Auto%-link report"), "missing title")
    assert(html:find("Time Shelter", 1, true), "linked book name missing")
    assert(html:find("Georgi Gospodinov", 1, true), "matched author missing")
    assert(html:find("Linked %(1%)"), "linked count missing")
    assert(html:find("Not matched %(1%)"), "not-matched section missing")
    assert(html:find("No identifier %(184%)"), "no-id count missing")
    assert(html:find("Obscure Title", 1, true), "not-matched name missing")
end)

test("autoLinkReportHtml: best-guess shows score and no no-id section", function()
    local html = Tokens.autoLinkReportHtml{
        best_guess = true,
        linked  = { { name = "Dune", matched = "Dune", author = "Frank Herbert", score = 97 } },
        nomatch = {},
        no_id   = 0,
    }
    assert(html:find("97%%"), "confidence score missing")
    assert(not html:find("No identifier"), "no-id section should be absent in best-guess mode")
end)

test("autoLinkReportHtml: escapes HTML in names/titles", function()
    local html = Tokens.autoLinkReportHtml{
        best_guess = false,
        linked  = { { name = "A & B <x>", matched = "M & N" } },
        nomatch = {},
    }
    assert(html:find("A &amp; B &lt;x&gt;", 1, true), "name not escaped: " .. html)
    assert(not html:find("<x>", 1, true), "raw angle bracket leaked")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
