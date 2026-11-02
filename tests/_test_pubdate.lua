-- tests/_test_pubdate.lua
-- %published's file readers (lib/bookshelf_pubdate): the date each format
-- keeps, and the ones that only look like a publication date.
-- Usage (from plugin root): lua tests/_test_pubdate.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local P = dofile("lib/bookshelf_pubdate.lua")

t.test("dates: ISO, timestamps, compact, PDF and free text", function()
    eq(P.parseDate("2010-05-04T00:00:00+00:00"), "2010-05-04")
    eq(P.parseDate("1869"), "1869")
    eq(P.parseDate("1869-3"), "1869-03")
    eq(P.parseDate("20100504"), "2010-05-04")
    eq(P.parseDate("D:20100504120000Z"), "2010-05-04")
    eq(P.parseDate("1 Jan 1869"), "1869")
    eq(P.parseDate("  2001-13-40 "), "2001")
end)

t.test("dates: calibre's no-date and empty values are no date", function()
    eq(P.parseDate("0101-01-01T00:00:00+00:00"), nil)
    eq(P.parseDate("0000"), nil)
    eq(P.parseDate(""), nil)
    eq(P.parseDate("unknown"), nil)
    eq(P.parseDate(nil), nil)
end)

t.test("year() cuts a stored date to the year", function()
    eq(P.year("1869-03-01"), "1869"); eq(P.year(""), nil); eq(P.year(nil), nil)
end)

t.test("EPUB: a dc:date marked as the publication beats the others", function()
    local opf = [[<metadata>
      <dc:date opf:event="modification">2020-01-01</dc:date>
      <dc:date>1999-01-01</dc:date>
      <dc:date opf:event="publication">1850-06-01</dc:date>
    </metadata>]]
    eq(P.fromOpf(opf), "1850-06-01")
end)

t.test("EPUB: a plain dc:date (calibre, EPUB 3); never a modification", function()
    eq(P.fromOpf([[<dc:date>2016-02-03T00:00:00+00:00</dc:date>
        <meta property="dcterms:modified">2023-01-01T00:00:00Z</meta>]]), "2016-02-03")
    eq(P.fromOpf([[<dc:date opf:event="modification">2020-01-01</dc:date>]]), nil)
    eq(P.fromOpf([[<dc:date id="d" xmlns:dc="x">2001</dc:date>]]), "2001")
end)

t.test("EPUB: dcterms:issued when there is no dc:date, either form", function()
    eq(P.fromOpf([[<meta property="dcterms:issued">1923</meta>]]), "1923")
    eq(P.fromOpf([[<meta name="dcterms:issued" content="1924-05"/>]]), "1924-05")
end)

t.test("EPUB: calibre's undefined date is no date", function()
    eq(P.fromOpf([[<dc:date>0101-01-01T00:00:00+00:00</dc:date>]]), nil)
end)

t.test("FB2: publish-info's year first, then title-info's date", function()
    local both = [[<description><title-info><date value="1866-01-01">1866</date></title-info>
        <document-info><date value="2010-01-01">2010</date></document-info>
        <publish-info><year>2003</year></publish-info></description>]]
    eq(P.fromFb2(both), "2003")
    eq(P.fromFb2([[<title-info><date value="1866-02-03">1866</date></title-info>
        <document-info><date value="2010-01-01"/></document-info>]]), "1866-02-03")
    eq(P.fromFb2([[<title-info><date>1866</date></title-info>]]), "1866")
    eq(P.fromFb2([[<document-info><date value="2010-01-01"/></document-info>]]), nil)
end)

t.test("ComicInfo: Year, Month, Day", function()
    eq(P.fromComicInfo("<ComicInfo><Year>2019</Year><Month>3</Month><Day>7</Day></ComicInfo>"), "2019-03-07")
    eq(P.fromComicInfo("<ComicInfo><Year>2019</Year><Month>3</Month></ComicInfo>"), "2019-03")
    eq(P.fromComicInfo("<ComicInfo><Year>-1</Year></ComicInfo>"), nil)
end)

t.test("PDF: the Info dictionary's CreationDate", function()
    eq(P.fromPdfInfo({ creationDate = "D:19990102030405+01'00'" }), "1999-01-02")
    eq(P.fromPdfInfo({ creationDate = "" }), nil)
end)

-- A MOBI head: PDB header, one record, the MOBI header and an EXTH block.
local function be32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
                       math.floor(n / 256) % 256, n % 256)
end
local function mobiHead(exth_records, flags)
    local rec0 = 86
    local mobi_len = 232
    local pdb = string.rep("\0", 76) .. "\0\1" .. be32(rec0) .. "\0\0\0\0"
    local palm = string.rep("\0", 16)
    local mobi = "MOBI" .. be32(mobi_len) .. string.rep("\0", 128 - 24)
                 .. be32(flags or 0x40)
    mobi = mobi .. string.rep("\0", mobi_len - #mobi)
    local body = {}
    for _i, r in ipairs(exth_records) do
        body[#body + 1] = be32(r[1]) .. be32(#r[2] + 8) .. r[2]
    end
    local b = table.concat(body)
    local exth = "EXTH" .. be32(12 + #b) .. be32(#exth_records) .. b
    return pdb .. palm .. mobi .. exth
end

t.test("MOBI/AZW3: EXTH 106, past other records", function()
    eq(P.fromMobi(mobiHead({ { 100, "Author" }, { 106, "2010-05-04T00:00:00+00:00" } })), "2010-05-04")
end)

t.test("MOBI: no EXTH flag, no EXTH 106, a truncated head", function()
    eq(P.fromMobi(mobiHead({ { 106, "2010" } }, 0)), nil)
    eq(P.fromMobi(mobiHead({ { 100, "Author" } })), nil)
    eq(P.fromMobi(mobiHead({ { 106, "2010" } }):sub(1, 200)), nil)
    eq(P.fromMobi("short"), nil)
end)

t.test("files: FB2 and MOBI read from disk; unknown formats are not handled", function()
    local dir = (os.getenv("TMPDIR") or "/tmp") .. "/bookshelf_pubdate_test"
    os.execute("mkdir -p '" .. dir .. "'")
    local fb2 = dir .. "/b.fb2"
    local f = io.open(fb2, "wb")
    f:write([[<?xml version="1.0"?><FictionBook><description><title-info><date>1877</date></title-info></description><body>x</body></FictionBook>]])
    f:close()
    eq(P.read(fb2), "1877")
    local mobi = dir .. "/b.azw3"
    f = io.open(mobi, "wb"); f:write(mobiHead({ { 106, "2011" } })); f:close()
    eq(P.read(mobi), "2011")
    eq(P.handles(dir .. "/x.txt"), false)
    eq(P.read(dir .. "/x.txt"), nil)
    eq(P.handles(dir .. "/x.EPUB"), true)
    eq(P.handles(dir .. "/x.fb2.zip"), true)
    eq(P.read(dir .. "/missing.fb2"), nil)
    os.remove(fb2); os.remove(mobi)
end)

t.done()
