-- tests/_test_epub_metadata.lua
-- Pure-Lua tests for EPUB OPF creator-role parsing.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_fp, key)
        if key == nil then return { modification = 1, size = 1 } end
        if key == "modification" then return 1 end
        if key == "size" then return 1 end
    end,
}

local EpubMetadata = dofile("lib/bookshelf_epub_metadata.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. " got " .. tostring(actual))
end

test("extractAuthorCreatorsFromOpf: ignores translator and keeps role=aut", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                  xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:creator opf:file-as="Alsberg, Rebecca" opf:role="trl">Rebecca Alsberg</dc:creator>
            <dc:creator opf:file-as="Ove Knausgård, Karl" opf:role="aut">Karl Ove Knausgård</dc:creator>
        </metadata>
    ]]
    local authors = EpubMetadata.extractAuthorCreatorsFromOpf(opf)
    assert(authors and #authors == 1, "expected one author")
    eq(authors[1], "Karl Ove Knausgård")
end)

test("extractAuthorCreatorsFromOpf: supports EPUB3 refined role metadata", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:creator id="c1">Rebecca Alsberg</dc:creator>
            <meta refines="#c1" property="role" scheme="marc:relators">trl</meta>
            <dc:creator id="c2">Karl Ove Knausgård</dc:creator>
            <meta refines="#c2" property="role" scheme="marc:relators">aut</meta>
        </metadata>
    ]]
    local authors = EpubMetadata.extractAuthorCreatorsFromOpf(opf)
    assert(authors and #authors == 1, "expected one author")
    eq(authors[1], "Karl Ove Knausgård")
end)

test("extractAuthorCreatorsFromOpf: returns nil when creators have no author role", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                  xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:creator opf:role="trl">Translator Only</dc:creator>
            <dc:creator>Unspecified Creator</dc:creator>
        </metadata>
    ]]
    local authors = EpubMetadata.extractAuthorCreatorsFromOpf(opf)
    assert(authors == nil, "expected nil fallback")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
