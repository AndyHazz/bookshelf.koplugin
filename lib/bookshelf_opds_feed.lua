-- lib/bookshelf_opds_feed.lua
-- OPDS 1.x (Atom) feed layer for OPDS chips: fetch, parse, and map feed
-- entries to Bookshelf-shaped records. parse() vendors the normalisation
-- fixes from the stock plugin's opdsparser.lua (luxl is strict about
-- comments, CDATA, self-closing tags and embedded XHTML content) - keep the
-- gsub set in sync with upstream if feeds start failing. Everything network
-- is BLOCKING; callers wrap in Trapper.
--
-- mapEntries() and absolute() are pure so the standalone harness covers
-- them; parse() needs luxl (ffi) and is fixture-tested only where a KOReader
-- tree is available.

local M = {}

-- Minimal RFC3986-ish resolution covering the href shapes OPDS feeds use.
-- Not a general resolver: no dot-segment handling ("../"), which real feeds
-- do not emit (the stock plugin survives on socket.url the same way).
function M.absolute(base, href)
    if type(href) ~= "string" or href == "" then return nil end
    if href:match("^%a[%w+.-]*:") then return href end          -- has scheme
    local scheme, authority_rest = base:match("^(%a[%w+.-]*):(.*)$")
    if not scheme then return href end
    if href:sub(1, 2) == "//" then return scheme .. ":" .. href end -- scheme-relative
    local root = base:match("^(%a[%w+.-]*://[^/]+)") or base
    if href:sub(1, 1) == "/" then return root .. href end        -- host-root
    local dir = base:match("^(.*/)") or (base .. "/")             -- relative
    return dir .. href
end

local ACQUISITION_REL = "^http://opds%-spec%.org/acquisition"
local BORROW_REL      = "http://opds-spec.org/acquisition/borrow"
local CATALOG_TYPE    = "application/atom%+xml"
local THUMB_REL = {
    ["http://opds-spec.org/image/thumbnail"] = true,
    ["http://opds-spec.org/thumbnail"]       = true,   -- ManyBooks
    ["x-stanza-cover-image-thumbnail"]       = true,
}
local IMAGE_REL = {
    ["http://opds-spec.org/image"] = true,
    ["http://opds-spec.org/cover"] = true,             -- ManyBooks
    ["x-stanza-cover-image"]       = true,
}
local NAV_REL = {
    ["subsection"]                            = true,
    ["http://opds-spec.org/subsection"]       = true,
    ["http://opds-spec.org/crawlable"]        = true,
    ["http://opds-spec.org/sort/popular"]     = true,
    ["http://opds-spec.org/sort/new"]         = true,
}
-- Formats KOReader opens; slice 1 only needs "is there at least one".
local SUPPORTED_TYPE = {
    ["application/epub+zip"] = true,
    ["application/pdf"]      = true,
    ["application/fb2"]      = true,
    ["application/x-fictionbook+xml"] = true,
    ["application/x-mobipocket-ebook"] = true,
    ["application/x-cbz"]    = true,
    ["image/vnd.djvu"]       = true,
    ["text/plain"]           = true,
    ["text/html"]            = true,
}

local function entryTitle(entry)
    if type(entry.title) == "string" then return entry.title end
    if type(entry.title) == "table" and type(entry.title.div) == "string"
            and entry.title.div ~= "" then
        return entry.title.div
    end
    return nil
end

local function entryAuthor(entry)
    if type(entry.author) ~= "table" then return nil end
    local name = entry.author.name
    if type(name) == "string" and name ~= "" then return name end
    if type(name) == "table" and #name > 0 then return table.concat(name, ", ") end
    return nil
end

-- catalog: OPDSParser-shaped table. feed_url: the URL it was fetched from
-- (base for relative hrefs). server_key: OpdsSource.serverKey of the server.
-- Returns { records, nav, next_url, total }.
function M.mapEntries(catalog, feed_url, server_key)
    local out = { records = {}, nav = {}, next_url = nil, total = nil }
    local feed = catalog and (catalog.feed or catalog)
    if type(feed) ~= "table" then return out end

    out.total = tonumber(feed["opensearch:totalResults"])

    for _i, link in ipairs(feed.link or {}) do
        if link.rel == "next" and link.href then
            out.next_url = M.absolute(feed_url, link.href)
        end
    end

    for idx, entry in ipairs(feed.entry or {}) do
        local title = entryTitle(entry)
        local acquisitions, thumb, image, nav_url = {}, nil, nil, nil
        for _j, link in ipairs(entry.link or {}) do
            local rel, ltype, href = link.rel, link.type, link.href
            if href then
                if rel and rel ~= BORROW_REL and rel:match(ACQUISITION_REL)
                        and SUPPORTED_TYPE[ltype] then
                    acquisitions[#acquisitions + 1] = {
                        type = ltype, href = M.absolute(feed_url, href),
                        title = type(link.title) == "string" and link.title or nil,
                    }
                elseif rel and THUMB_REL[rel] then
                    thumb = M.absolute(feed_url, href)
                elseif rel and IMAGE_REL[rel] then
                    image = M.absolute(feed_url, href)
                elseif ltype and ltype:find(CATALOG_TYPE)
                        and (not rel or NAV_REL[rel]) then
                    nav_url = M.absolute(feed_url, href)
                end
            end
        end

        if #acquisitions > 0 then
            local id = (type(entry.id) == "string" and entry.id ~= "" and entry.id)
                or (feed_url .. "#" .. idx)
            local author = entryAuthor(entry)
            local summary = entry.content or entry.summary
            out.records[#out.records + 1] = {
                is_remote     = true,
                filepath      = "OPDS://" .. server_key .. "/" .. id,
                filename      = title or id,
                title         = title or "Unknown",
                display_title = title or "Unknown",
                author        = author,
                authors       = author and { author } or nil,
                status        = "unread",
                read_status   = "unread",
                added_time    = 0,
                attr          = { mode = "file", size = 0, modification = 0 },
                opds = {
                    acquisitions  = acquisitions,
                    thumbnail_url = thumb,
                    image_url     = image,
                    summary       = type(summary) == "string" and summary or nil,
                    feed_url      = feed_url,
                },
            }
        elseif nav_url and title then
            out.nav[#out.nav + 1] = {
                is_remote = true, is_opds_nav = true,
                label = title, feed_url = nav_url,
            }
        end
    end
    return out
end

-- Vendored from the stock plugin's opdsparser.lua: luxl pre-normalisation.
local unescape_map = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }
local function unescape(str)
    return (str:gsub('(&(#?)([%d%a]+);)', function(orig, n, s)
        if unescape_map[s] then return unescape_map[s] end
        if n == "#" then
            local cp = (s:sub(1, 1) == "x") and tonumber(s:sub(2), 16) or tonumber(s)
            if cp then
                local ok_u, util = pcall(require, "util")
                if ok_u and util and util.unicodeCodepointToUtf8 then
                    return util.unicodeCodepointToUtf8(cp)
                end
            end
        end
        return orig
    end))
end

local function createFlatXTable(luxl_mod, xlex, curr_element)
    local ffi = require("ffi")
    curr_element = curr_element or {}
    local curr_attr_name
    for event, offset, size in xlex:Lexemes() do
        local txt = ffi.string(xlex.buf + offset, size)
        if event == luxl_mod.EVENT_START then
            if txt ~= "xml" then
                local tab = createFlatXTable(luxl_mod, xlex)
                if txt == "entry" or txt == "link" then
                    if curr_element[txt] == nil then curr_element[txt] = {} end
                    table.insert(curr_element[txt], tab)
                elseif type(curr_element) == "table" then
                    curr_element[txt] = tab
                end
            end
        elseif event == luxl_mod.EVENT_ATTR_NAME then
            curr_attr_name = unescape(txt)
        elseif event == luxl_mod.EVENT_ATTR_VAL then
            curr_element[curr_attr_name] = unescape(txt)
            curr_attr_name = nil
        elseif event == luxl_mod.EVENT_TEXT then
            curr_element = unescape(txt)
        elseif event == luxl_mod.EVENT_END then
            return curr_element
        end
    end
    return curr_element
end

function M.parse(text)
    local ok_luxl, luxl = pcall(require, "luxl")
    if not ok_luxl then return nil end
    text = text:gsub("<%?xml%-stylesheet.-%?>", "")
    text = text:gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<([%l:]+)/>", "<%1 />")
    text = text:gsub("<([bh]r)>", "<%1 />")
    text = text:gsub("<!%[CDATA%[(.-)%]%]>", function(s)
        return s:gsub("%p", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" })
    end)
    text = text:gsub("<content%s+[^<>]-/>", "<content />")
    text = text:gsub('<content type=".-">', "<content>")
    text = text:gsub("<content>(.-)</content>", function(s)
        return '<content type="text">'
            .. s:gsub("%p", { ["<"] = "&lt;", [">"] = "&gt;",
                              ['"'] = "&quot;", ["'"] = "&apos;" })
            .. "</content>"
    end)
    local xlex = luxl.new(text, #text)
    local ok_parse, result = pcall(createFlatXTable, luxl, xlex)
    if not ok_parse then return nil end
    return result
end

-- Blocking GET with the stock plugin's header discipline (identity encoding;
-- some servers 403 generic UAs, so socketutil's KOReader UA matters).
-- Returns body string or nil, err. Callers wrap in Trapper.
function M.fetch(url, username, password)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, http.request{
        url = url,
        headers = { ["Accept-Encoding"] = "identity" },
        sink = ltn12.sink.table(sink),
        user = username,
        password = password,
    })
    socketutil:reset_timeout()
    if code == 200 then
        local body = table.concat(sink)
        if body ~= "" then return body end
        return nil, "empty response"
    end
    if code == 401 or code == 403 then
        return nil, "auth"
    end
    return nil, tostring(status or code or "network unreachable")
end

return M
