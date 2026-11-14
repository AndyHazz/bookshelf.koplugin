-- bookshelf_hardcover_client.lua
-- Bookshelf's own Hardcover client: a GraphQL request with an API key
-- (lib/bookshelf_hardcover_key), and the handful of lookups the link pickers
-- and auto-link need. It answers to the same calls as the sync plugins'
-- clients (query, me, findBooks, findEditions, findBookByIdentifiers,
-- hydrateBooks), so lib/bookshelf_hardcover can use any of the three.
--
-- Nothing here runs by itself: every request is the end of something the
-- reader asked for.
--
-- The credential is one function's business (bearer()). An API key today; an
-- OAuth access token would be sent the same way, so a sign-in added later
-- changes that function and nothing else here.
--
-- Hardcover says how much of the rate limit is left on every reply
-- (RateLimit header). waitTime() turns that into "seconds until the next
-- request may go", so a bulk job paces itself and does not find the limit by
-- hitting it.

local Client = { enabled = true }

Client.URL = "https://api.hardcover.app/v1/graphql"
-- Seconds one request may take, and the block timeout inside it.
Client.TOTAL_TIMEOUT = 20
Client.BLOCK_TIMEOUT = 10
-- With no usable header on a 429: Hardcover refills one request a second.
Client.DEFAULT_BACKOFF = 10
-- A long job's status-line job (lib/bookshelf_scan_progress). When set and
-- the caller is in a coroutine, the request runs in a forked child under it:
-- the shelf keeps answering taps and only the job's Stop aborts the request.
Client.trap = nil

local function now()
    local ok, gettime = pcall(require, "lib/bookshelf_gettime")
    return ok and gettime() or os.time()
end

-- ── credential ──────────────────────────────────────────────────────────────
local function bearer()
    local ok, Key = pcall(require, "lib/bookshelf_hardcover_key")
    if not ok or not Key then return nil end
    return (Key.get())
end

function Client:hasCredential() return bearer() ~= nil end

-- ── rate limit ──────────────────────────────────────────────────────────────
local _rl = nil   -- { remaining, reset_at, daily_remaining, daily_reset_at }

-- '"Free (JWT)";r=4;t=0, "daily";r=4304;t=2390'. Once the day's budget is
-- gone Hardcover sends only the "daily" entry.
local function readRateLimit(header, at)
    if type(header) ~= "string" then return nil end
    local out = {}
    for name, rest in header:gmatch('"([^"]*)"([^,]*)') do
        local r = tonumber(rest:match("r=(%d+)"))
        local tt = tonumber(rest:match("t=(%d+)"))
        if r then
            if name == "daily" then
                out.daily_remaining, out.daily_reset_at = r, at + (tt or 0)
            else
                out.remaining, out.reset_at = r, at + (tt or 0)
            end
        end
    end
    return next(out) and out or nil
end

-- rateLimit() -> { remaining, daily_remaining } as last heard, or nil.
function Client.rateLimit()
    if not _rl then return nil end
    return { remaining = _rl.remaining, daily_remaining = _rl.daily_remaining }
end

-- waitTime() -> whole seconds until the next request may go. 0 when unknown.
function Client.waitTime()
    if not _rl then return 0 end
    local t = now()
    local wait = 0
    if _rl.daily_remaining == 0 and _rl.daily_reset_at then
        wait = math.max(wait, _rl.daily_reset_at - t)
    end
    if _rl.remaining == 0 and _rl.reset_at then
        wait = math.max(wait, _rl.reset_at - t)
    end
    return math.max(0, math.ceil(wait))
end

function Client._resetRateLimit() _rl = nil end

-- ── JSON nulls ──────────────────────────────────────────────────────────────
-- rapidjson decodes null to a sentinel, which is truthy: `title or ""` would
-- hand a userdata on. Everything downstream expects an absent field.
function Client._scrub(v, null)
    if type(v) ~= "table" then return v end
    for k, x in pairs(v) do
        if x == null then
            v[k] = nil
        elseif type(x) == "table" then
            Client._scrub(x, null)
        end
    end
    return v
end

-- ── transport ───────────────────────────────────────────────────────────────
-- One POST. Runs in this process, or in a forked child (see Client.trap).
-- -> "status\nratelimit\nbody", so a child can hand it back as one string.
local function post(body, token)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(Client.BLOCK_TIMEOUT, Client.TOTAL_TIMEOUT)
    local ok, _one, code, headers = pcall(http.request, {
        url = Client.URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["User-Agent"] = "bookshelf.koplugin",
            ["Authorization"] = "Bearer " .. token,
        },
        source = ltn12.source.string(body),
        sink = socketutil.table_sink(sink),
    })
    socketutil:reset_timeout()
    if not ok then return "\n\n" end
    local rl = type(headers) == "table" and headers["ratelimit"] or ""
    return tostring(tonumber(code) or "") .. "\n" .. tostring(rl or "") .. "\n" .. table.concat(sink)
end

-- _transport(request, token) -> status, reply table, ratelimit header
-- status nil: the request did not complete (no connection, timeout, Stop).
-- A seam for tests; everything above it is plain Lua.
function Client._transport(request, token)
    local rapidjson = require("rapidjson")
    local body = rapidjson.encode(request)
    local raw
    local job = Client.trap
    if job and coroutine.running() then
        job.in_run = true
        local completed, out = require("ui/trapper"):dismissableRunInSubprocess(function()
            return post(body, token)
        end, job, true)
        job.in_run = false
        raw = completed and out or nil
    else
        raw = post(body, token)
    end
    if type(raw) ~= "string" then return nil end
    local status, rl, text = raw:match("^([^\n]*)\n([^\n]*)\n(.*)$")
    status = tonumber(status)
    if not status then return nil end
    local ok, reply = pcall(rapidjson.decode, text)
    reply = ok and type(reply) == "table" and Client._scrub(reply, rapidjson.null) or nil
    return status, reply, rl ~= "" and rl or nil
end

-- query(query, variables) -> data | nil, err
-- err: { request_error = text, and one of no_key / auth_error / rate_limited
--        / completed = false } or { errors = { { message = } ... } }
function Client:query(query, variables)
    local token = bearer()
    if not token then
        return nil, { no_key = true, request_error = "No Hardcover API key is set" }
    end
    local request = { query = query }
    if type(variables) == "table" and next(variables) ~= nil then
        request.variables = variables
    end
    local at = now()
    local ok, status, reply, rl = pcall(Client._transport, request, token)
    if not ok then
        require("logger").warn("[bookshelf] Hardcover request failed:", tostring(status))
        return nil, { completed = false, request_error = "The request to Hardcover failed" }
    end
    local heard = readRateLimit(rl, at)
    if heard then _rl = heard end
    if not status then
        return nil, { completed = false, request_error = "No response from Hardcover" }
    end
    if status == 429 then
        if not heard then
            _rl = { remaining = 0, reset_at = at + Client.DEFAULT_BACKOFF }
        end
        return nil, { rate_limited = true, status_code = 429, request_error = "Too Many Requests" }
    end
    if status == 401 or status == 403 then
        return nil, { auth_error = status == 401, status_code = status,
            request_error = status == 401 and "Hardcover rejected the API key"
                or "Hardcover refused the request" }
    end
    if type(reply) == "table" then
        if type(reply.data) == "table" then return reply.data end
        if reply.errors or reply.error then
            return nil, { errors = reply.errors or { { message = tostring(reply.error) } },
                status_code = status }
        end
    end
    return nil, { status_code = status,
        request_error = "Hardcover returned HTTP " .. tostring(status) }
end

-- ── lookups ─────────────────────────────────────────────────────────────────
local BOOK_FIELDS = [[
    book_id: id
    title
    release_year
    users_read_count
    pages
    book_series { position series { name } }
    contributions: cached_contributors
    cached_image
]]

local EDITION_FIELDS = [[
    id
    title
    edition_format
    reading_format_id
    pages
    release_date
    users_count
    cached_image
    language { code2 language }
    publisher { name }
    book { ]] .. BOOK_FIELDS .. [[ }
]]

local FORMATS = { [1] = "Physical Book", [2] = "Audiobook", [4] = "E-Book" }

function Client:editionFormatName(edition_format, format_id)
    if type(edition_format) == "string" and edition_format ~= "" then return edition_format end
    return FORMATS[tonumber(format_id) or 0]
end

-- An edition, as the book record it belongs to with the edition's own title,
-- pages, year, format and cover on top: the shape a link is made from.
local function asEdition(edition)
    local b = type(edition.book) == "table" and edition.book or {}
    b.edition_id = edition.id
    b.edition_format = Client:editionFormatName(edition.edition_format, edition.reading_format_id)
    b.reading_format_id = edition.reading_format_id
    b.filetype = b.edition_format or "Physical Book"
    b.cached_image = edition.cached_image or b.cached_image
    b.publisher = type(edition.publisher) == "table" and edition.publisher.name or nil
    b.release_year = type(edition.release_date) == "string"
        and edition.release_date:match("^(%d%d%d%d)") or nil
    b.language = edition.language
    b.title = edition.title or b.title
    b.pages = edition.pages
    b.users_count = edition.users_count
    return b
end

-- me() -> { id = } | nil, err
function Client:me()
    local data, err = self:query("{ me { id username } }")
    if not data then return nil, err end
    local me = type(data.me) == "table" and (data.me[1] or data.me) or nil
    if type(me) ~= "table" or not me.id then return nil, { request_error = "No account in the reply" } end
    return me
end

-- hydrateBooks(ids) -> books in the order of ids | nil, err
function Client:hydrateBooks(ids, _user_id)
    if type(ids) ~= "table" or #ids == 0 then return {} end
    local data, err = self:query(
        "query ($ids: [Int!]) { books(where: { id: { _in: $ids }}) { " .. BOOK_FIELDS .. " } }",
        { ids = ids })
    if not data or type(data.books) ~= "table" then return nil, err end
    local order = {}
    for i, id in ipairs(ids) do order[tonumber(id) or id] = i end
    table.sort(data.books, function(a, b)
        return (order[a.book_id] or math.huge) < (order[b.book_id] or math.huge)
    end)
    return data.books
end

-- findBooks(title, author) -> books, best match first | nil, err
function Client:findBooks(title, author, _user_id)
    if type(title) ~= "string" or title:match("^%s*$") then return {} end
    -- A subtitle skews Hardcover's search; the work is under the main title.
    title = title:gsub(":.+", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local q = title
    if type(author) == "string" and author ~= "" then q = q .. " " .. author end
    local data, err = self:query(
        'query ($query: String!) { search(query: $query, per_page: 25, page: 1, query_type: "Book") { ids } }',
        { query = q })
    if not data then return nil, err or { request_error = "No response from Hardcover" } end
    local raw = type(data.search) == "table" and data.search.ids or nil
    local ids = {}
    for _i, id in ipairs(type(raw) == "table" and raw or {}) do
        ids[#ids + 1] = tonumber(id)
    end
    if #ids == 0 then return {} end
    return self:hydrateBooks(ids)
end

-- findEditions(book_id) -> editions as book records | nil
-- Audiobooks are left out. E-books first, then the most widely held.
function Client:findEditions(book_id, _user_id)
    local data = self:query(
        "query ($id: Int!) { editions(where: { book_id: { _eq: $id }, "
        .. "_or: [{ reading_format_id: { _is_null: true }}, { reading_format_id: { _neq: 2 }}] }, "
        .. "order_by: { users_count: desc_nulls_last }) { " .. EDITION_FIELDS .. " } }",
        { id = tonumber(book_id) or book_id })
    if not data or type(data.editions) ~= "table" then return nil end
    local list = {}
    for i, e in ipairs(data.editions) do
        local rec = asEdition(e)
        rec._order = i
        list[#list + 1] = rec
    end
    table.sort(list, function(a, b)
        local ea, eb = a.reading_format_id == 4, b.reading_format_id == 4
        if ea ~= eb then return ea end
        local ua, ub = tonumber(a.users_count) or 0, tonumber(b.users_count) or 0
        if ua ~= ub then return ua > ub end
        return a._order < b._order
    end)
    for _i, rec in ipairs(list) do rec._order = nil end
    return list
end

local function firstEdition(self, where, variables, decl)
    local data = self:query(
        "query (" .. decl .. ") { editions(where: " .. where .. ", limit: 1) { "
        .. EDITION_FIELDS .. " } }", variables)
    local e = data and type(data.editions) == "table" and data.editions[1] or nil
    return e and asEdition(e) or nil
end

-- findBookByIdentifiers({ edition_id, book_slug, isbn_13, isbn_10 }) -> book | nil
function Client:findBookByIdentifiers(ids, _user_id)
    if type(ids) ~= "table" then return nil end
    local edition_id = tonumber(ids.edition_id)
    if edition_id then
        local b = firstEdition(self, "{ id: { _eq: $id }}", { id = edition_id }, "$id: Int!")
        if b then return b end
    end
    if type(ids.book_slug) == "string" and ids.book_slug ~= "" then
        local data = self:query(
            "query ($slug: String!) { books(where: { slug: { _eq: $slug }}, limit: 1) { "
            .. BOOK_FIELDS .. " } }", { slug = ids.book_slug })
        local b = data and type(data.books) == "table" and data.books[1] or nil
        if b then return b end
        -- A numeric "slug" is an edition id some tools write there.
        local as_edition = tonumber(ids.book_slug)
        if as_edition then
            b = firstEdition(self, "{ id: { _eq: $id }}", { id = as_edition }, "$id: Int!")
            if b then return b end
        end
    end
    local field = ids.isbn_13 and "isbn_13" or (ids.isbn_10 and "isbn_10") or nil
    if field then
        return firstEdition(self, "{ " .. field .. ": { _eq: $isbn }}",
            { isbn = tostring(ids[field]) }, "$isbn: String!")
    end
    return nil
end

return Client
