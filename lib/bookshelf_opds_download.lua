-- lib/bookshelf_opds_download.lua
-- OPDS acquisition download core: pick a destination directory, name the
-- file, and fetch it. Modelled on bookshelf_cover_fetch.download (User-Agent,
-- socketutil timeouts, pcall + unconditional timeout reset, tmp-then-rename
-- atomic write) and bookshelf_opds_feed.fetch ("auth" for 401/403), with the
-- timeout pair taken from the STOCK OPDS plugin instead of CoverFetch's --
-- see download() for why a cover's budget is the wrong one for a book.
--
-- Contracts this module deliberately does NOT own:
--   * Same-origin credential gating. download() sends whatever user/password
--     it is handed, unconditionally -- the caller (the OPDS widget) decides
--     whether the acquisition URL is same-origin with the server the
--     credentials belong to, exactly as bookshelf_opds_covers already does
--     for thumbnail fetches.
--   * Any UI. Every function here returns data or (nil, err[, extra]); no
--     dialogs, no Trapper, no progress reporting. The caller surfaces errors
--     (including turning "auth"/"downgrade" into a message the reader sees).

local D = {}

-- Settings-store key for the download mapping: OPDS pseudo-path -> the on-disk
-- path a completed download landed at. Lives here rather than in either caller
-- because it has two of them -- the widget writes it and reads it back for the
-- Open row, the book repository reads it for the downloaded decoration -- and a
-- key spelled out twice is a key that can drift. See the long note at the
-- widget's read site for why it stays in the MAIN store and not a sub-store.
D.STORE_KEY = "opds_downloads"

-- Sibling map: <on-disk path> -> the catalog's description text, written on
-- download and read back by Repo.buildBookMeta as the local book's
-- description (Gutenberg's embedded EPUB description is usually empty, so the
-- OPDS Summary is the better source). Same key-drift reasoning as STORE_KEY.
D.DESC_STORE_KEY = "opds_descriptions"

-- Acquisition MIME type -> file extension, shared with the feed module so the
-- two can never disagree: bookshelf_opds_feed.TYPE_EXT is the single source of
-- truth (its key set is the "is this downloadable" filter, its values are the
-- extensions used here). A type kept by the filter but missing an extension
-- would land as ".bin", which no KOReader provider opens; one table makes that
-- impossible rather than merely tested-for.
local EXT_BY_TYPE = require("lib/bookshelf_opds_feed").TYPE_EXT

-- destinationDir(read_setting) -> dir|nil
--
-- read_setting is a function(key) -> value, closure-injected the same way
-- bookshelf_file_poll.effectiveDownloadDir takes it, so this stays testable
-- without G_reader_settings.
--
-- Rule: the stock effective download dir (download_dir, falling back to
-- lastdir -- see FilePoll.effectiveDownloadDir) WHEN it resolves inside
-- home_dir (a prefix match on both, normalised with no trailing slash), else
-- home_dir itself. A book downloaded outside the library folder the shelf
-- actually scans would never show up on the shelf, so an outside download
-- dir is treated as stale rather than honoured. When home_dir itself is
-- unset there is nothing safe to fall back to -- return nil and let the
-- caller refuse the download with a message; this function never invents a
-- destination.
-- preferred: an explicit folder the user chose for catalog downloads
-- (Bookshelf's own opds_download_dir setting, read by the caller since this
-- function only knows how to read G_reader_settings keys). It wins over the
-- stock download dir when it passes the SAME inside-home_dir test - an
-- explicit choice is still not worth honouring once it points outside the
-- folder the shelf scans, because the book would download successfully and
-- then be invisible; falling back keeps the download useful and visible.
-- A folder that has since been deleted or renamed also fails that test, so a
-- stale setting degrades instead of failing the download.
function D.destinationDir(read_setting, preferred)
    if type(read_setting) ~= "function" then return nil end
    local home = read_setting("home_dir")
    if type(home) ~= "string" or home == "" then return nil end
    if home ~= "/" then home = home:gsub("/+$", "") end

    -- Shared by the preferred folder and the stock download dir: normalise,
    -- then require it to be home_dir or below.
    local function inside_home(dir)
        if type(dir) ~= "string" or dir == "" then return nil end
        local d = (dir ~= "/") and dir:gsub("/+$", "") or dir
        if d == home or d:sub(1, #home + 1) == (home .. "/") then return d end
        return nil
    end

    local chosen = inside_home(preferred)
    if chosen then
        -- Only if it still exists: a picked folder can be moved or deleted
        -- later, and downloading into a vanished path fails at the rename.
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs or lfs.attributes(chosen, "mode") == "directory" then
            return chosen
        end
    end

    local FilePoll = require("lib/bookshelf_file_poll")
    return inside_home(FilePoll.effectiveDownloadDir(read_setting)) or home
end

-- filenameFor(rec, acq) -> name
--
-- rec: the Bookshelf-shaped OPDS record (bookshelf_opds_feed.mapEntries'
-- output) -- only rec.title / rec.display_title are read. acq: the chosen
-- acquisition link ({ type, href, title }). Pure: no path, no
-- sanitisation -- the caller runs util.getSafeFilename(name, dir) once it
-- has picked dest_path's directory, keeping this half testable without a
-- filesystem.
--
-- Extension: EXT_BY_TYPE keyed on acq.type; failing that, the acquisition
-- URL's own path suffix when it looks like a short extension (a dot
-- followed by 1-4 word characters at the end of the path, query/fragment
-- stripped); failing that, ".bin".
function D.filenameFor(rec, acq)
    local title = rec and (rec.title or rec.display_title)
    if type(title) ~= "string" or title == "" then title = "book" end

    local mtype = acq and acq.type
    local ext = (type(mtype) == "string") and EXT_BY_TYPE[mtype] or nil
    if not ext then
        local href = acq and acq.href
        if type(href) == "string" then
            local path = href:match("^([^?#]*)") or href
            ext = path:match("%.(%w%w?%w?%w?)$")
        end
    end
    return title .. "." .. (ext or "bin")
end

-- rankAcquisitions(acquisitions) -> ordered_list, recommended_index|nil
--
-- PURE (no I/O): reorders a record's acquisition links into the order worth
-- offering a KOReader user, and names the one to badge "recommended" -- but
-- only when the choice is unambiguous.
--
-- Why this and not the stock plugin's format labels. The stock OPDS browser
-- annotates formats with device-compatibility hints ("for older Kindles", "for
-- older E-readers"); on KOReader those are noise, because crengine opens
-- epub/mobi/azw3/fb2/pdf/djvu/cbz/txt natively. The format that reads best here
-- is EPUB (with images), so the ranking leads with it.
--
-- PRIMARY key is the MIME type, deliberately -- it is robust and i18n-safe,
-- where a link's human title is neither (Gutenberg writes "EPUB (no images)",
-- another catalogue writes it in French, a third not at all). MIME order:
-- epub, then fb2, then mobi, then pdf, then cbz, then djvu, then plain text,
-- then html. Unknown types sort last, keeping their feed order among
-- themselves.
--
-- SECONDARY key is a title tiebreak that only ever reorders WITHIN one MIME
-- group (MIME is compared first, so it can never move a format across groups):
-- a title matching /no%s*image/i sorts AFTER its siblings (an images-stripped
-- EPUB is the worse read), and a title containing "3" sorts BEFORE a plain one
-- (EPUB3 over EPUB). Fragile, Gutenberg-shaped heuristics, confined to breaking
-- ties so they can never drive the badge.
--
-- recommended_index is returned ONLY when confident, and nil whenever in doubt:
--   * the top item after ordering is application/epub+zip, AND
--   * its title does NOT match no-images, AND
--   * it is either the ONLY epub, or it strictly title-beats every epub sibling.
-- A single lone acquisition returns nil too: with no choice to make, a badge
-- says nothing. Everything else reorders without a badge.
local MIME_RANK = {
    ["application/epub+zip"]           = 1,
    ["application/fb2"]                = 2,
    ["application/x-fictionbook+xml"]  = 2,
    ["application/x-mobipocket-ebook"] = 3,
    ["application/pdf"]                = 4,
    ["application/x-cbz"]              = 5,
    ["image/vnd.djvu"]                 = 6,
    ["text/plain"]                     = 7,
    ["text/html"]                      = 8,
}

-- Title tiebreak rank (lower sorts first). no-images LAST, "3" FIRST, plain in
-- between. no-images is checked before "3" so "no image 3" still sorts last.
local function titleRank(title)
    if type(title) ~= "string" then return 1 end
    if title:lower():match("no%s*image") then return 2 end
    if title:match("3") then return 0 end
    return 1
end

function D.rankAcquisitions(acquisitions)
    if type(acquisitions) ~= "table" then return {}, nil end
    local items = {}
    for i = 1, #acquisitions do
        local a = acquisitions[i]
        items[#items + 1] = {
            acq   = a,
            orig  = i,
            mime  = (type(a) == "table" and MIME_RANK[a.type]) or 99,
            title = titleRank(type(a) == "table" and a.title or nil),
        }
    end
    -- Stable order via the original index as the final tiebreak (table.sort is
    -- not stable on its own).
    table.sort(items, function(x, y)
        if x.mime  ~= y.mime  then return x.mime  < y.mime  end
        if x.title ~= y.title then return x.title < y.title end
        return x.orig < y.orig
    end)
    local ordered = {}
    for i = 1, #items do ordered[i] = items[i].acq end

    local recommended = nil
    -- #items >= 2: a lone acquisition is no choice, so it gets no badge.
    if #items >= 2 then
        local top = items[1]
        if top.mime == 1 and top.title ~= 2 then   -- epub, and not a no-images one
            local only_epub, beats_all = true, true
            for i = 2, #items do
                if items[i].mime == 1 then
                    only_epub = false
                    if not (top.title < items[i].title) then beats_all = false end
                end
            end
            if only_epub or beats_all then recommended = 1 end
        end
    end
    return ordered, recommended
end

-- claimDest(dest, map, filepath, acq) -> dest
--
-- Make sure `dest` doesn't belong to a DIFFERENT catalog record before the
-- caller offers to overwrite it.
--
-- util.getSafeFilename sanitises but does not uniquify, and filenameFor is
-- title + format, so two different records genuinely land on the same path:
-- two catalogues (or two entries in one) carrying the same book, or a
-- reprint under an identical title. Without this the second download
-- overwrites the first and BOTH opds_downloads keys then point at one file,
-- so record A's Open row launches record B's book -- silently, and with no
-- way for the read-side stat to notice (the file is right there).
--
-- map is the opds_downloads table (pseudo-path -> on-disk path); filepath is
-- the record being downloaded FOR. Only a value under a different key
-- counts: the same record downloading again -- the same acquisition, or the
-- other half of a collapsed edition pair -- is one book being replaced, which
-- is what the caller's overwrite prompt is for.
--
-- The disambiguator is a hash of the acquisition URL rather than a counter or
-- a title fragment: deterministic (so re-downloading the same acquisition
-- lands on the same file and still gets the plain overwrite prompt), and
-- collision-free without a retry loop (a title fragment would usually be
-- identical for exactly the records that collide). Reuses OpdsSource's djb2
-- so there is one hash in the plugin, not two.
--
-- Not defended against: a pathological title can push the SUFFIXED basename
-- past NAME_MAX. util.getSafeFilename truncates the stem to 240 bytes and
-- allows a 10-byte extension, so the plain path tops out at 255 exactly -- but
-- " (xxxxxxxx)" adds 11 more, and the ".tmp" the transfer writes first adds 4.
-- io.open then fails and the caller reports "Couldn't reach <server>", which is
-- the wrong diagnosis for the right refusal. It fails clean, and it needs both
-- a ~240-character title AND a genuine cross-record collision, so it is noted
-- here rather than worked around.
function D.claimDest(dest, map, filepath, acq)
    if type(dest) ~= "string" or dest == "" then return dest end
    if type(map) ~= "table" then return dest end
    local taken = false
    for key, value in pairs(map) do
        if value == dest and key ~= filepath then taken = true; break end
    end
    if not taken then return dest end
    local href = acq and acq.href
    if type(href) ~= "string" or href == "" then return dest end
    local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
    if not ok_s then return dest end
    local tag = OpdsSource.serverKey(href)
    -- Split on the LAST dot of the basename only: [^./] keeps a dotted
    -- directory name ("/books/sci.fi/Dune") from being mistaken for a suffix.
    local stem, ext = dest:match("^(.*)%.([^./]+)$")
    if stem then return stem .. " (" .. tag .. ")." .. ext end
    return dest .. " (" .. tag .. ")"
end

-- pruneMap(map, is_file) -> map, removed
--
-- Drop mapping entries whose destination is no longer a file. Mutates and
-- returns `map` (the caller stores the same table it handed in), plus a count
-- for logging.
--
-- is_file is a function(path) -> boolean, closure-injected the same way
-- destinationDir takes read_setting, so this stays testable with no
-- filesystem. With no such function there is nothing to judge an entry by, so
-- nothing is dropped -- a prune that guesses would delete live mappings.
--
-- WHY, and why HERE. The mapping is keyed by OPDS pseudo-path (which never
-- moves) and valued by the on-disk path (which does), and deliberately gets no
-- bookkeeping pass on move or delete -- every reader stats before trusting the
-- value, so a stale entry degrades to a benign false negative ("no tick, no
-- Open row") and never to an Open row that launches the wrong book. What the
-- staleness does cost is growth, and one sharper edge: a dead value still
-- counts as "taken" in claimDest's scan, so an unrelated record that
-- legitimately wants that filename gets a spurious "(a1b2c3d4)" in its name.
-- Retiring dead entries at the one moment we are already writing the store
-- costs one stat per entry at an action boundary and closes both.
function D.pruneMap(map, is_file)
    if type(map) ~= "table" then return map, 0 end
    if type(is_file) ~= "function" then return map, 0 end
    local dead, removed = {}, 0
    for key, value in pairs(map) do
        if type(value) ~= "string" or value == "" or not is_file(value) then
            dead[#dead + 1] = key
        end
    end
    -- Collected first, deleted after: assigning nil to the key being visited is
    -- allowed in Lua, but adding to `dead` inside the loop keeps that rule out
    -- of the reader's way.
    for _i = 1, #dead do
        map[dead[_i]] = nil
        removed = removed + 1
    end
    return map, removed
end

-- download(url, dest_path[, user, password]) -> path|nil, err[, extra]
--
-- Blocking; wrap in Trapper if calling from a UI context that must stay
-- responsive.
--
-- Timeouts are socketutil's FILE pair (15s block / 60s total), matching the
-- stock OPDS plugin's own downloadFile. NOT CoverFetch's LARGE pair, which
-- this otherwise copies: LARGE is 10s/30s, sized for an API call, and a real
-- book over a slow connection routinely runs past 30s -- the transfer was
-- cut off mid-file and reported to the caller as an ordinary non-200
-- failure, i.e. "couldn't reach the server", which is the wrong thing to
-- tell the user and the wrong thing for them to do about it.
--
-- Fetches url to dest_path atomically (tmp-then-rename,
-- overwriting any existing dest_path), the same discipline as
-- bookshelf_cover_fetch.download with one difference: CoverFetch always
-- removes dest_path before renaming, which is fine for its disposable cache
-- files, but dest_path here is the user's permanent library book. The rename
-- is tried directly first (POSIX rename replaces an existing file
-- atomically, so this is the common case); only if that fails is the
-- existing file removed and the rename retried, so a re-download never
-- deletes the original before confirming the replacement can land.
--
-- user/password are OPTIONAL basic-auth credentials sent exactly as given,
-- with NO same-origin check -- see the header note above.
--
-- err is one of:
--   "auth"       -- the server answered 401/403.
--   "downgrade"  -- the server tried to redirect an https request to a
--                   non-https URL; extra carries that Location value for the
--                   caller's warning message. LuaSocket's http module
--                   already refuses to auto-follow such a redirect
--                   (socket/http.lua's shouldredirect: 'avoid https
--                   downgrades'), so it returns the bare 3xx response with a
--                   Location header instead of chasing it -- this is that
--                   response, surfaced rather than silently swallowed.
--   otherwise    -- a short human-unreadable-but-loggable string (bad args,
--                   an unavailable destination directory, a non-2xx status,
--                   a failed rename, ...).
function D.download(url, dest_path, user, password, redirect_depth)
    if type(url) ~= "string" or url == "" or type(dest_path) ~= "string" or dest_path == "" then
        return nil, "bad args"
    end

    local lfs = require("libs/libkoreader-lfs")
    local parent = dest_path:match("^(.*)/[^/]+$")
    if not parent or lfs.attributes(parent, "mode") ~= "directory" then
        return nil, "destination dir unavailable"
    end

    local auth_user = (type(user) == "string" and user ~= "") and user or nil
    local auth_pass = (type(password) == "string" and password ~= "") and password or nil

    local ok_req, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"),
               require("ltn12"),
               require("socket"),
               require("socketutil")
    end)
    if not ok_req then return nil, "socket unavailable" end

    local tmp = dest_path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return nil, "cannot open temp file" end

    local code, headers
    local ok_req2 = pcall(function()
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local c, h = socket.skip(1, http.request({
            url = url, method = "GET",
            -- Accept-Encoding: identity for the same reason
            -- bookshelf_opds_feed.fetch and the stock plugin's downloadFile
            -- both send it: LuaSocket advertises no encoding of its own and
            -- cannot decode a content-encoded body, so a server that answers
            -- with Content-Encoding: gzip would leave a gzipped file carrying
            -- an .epub name -- the transfer "succeeds", the mapping records
            -- it, and the book simply will not open.
            headers = {
                ["User-Agent"]      = "KOReader-Bookshelf",
                ["Accept-Encoding"] = "identity",
            },
            sink = ltn12.sink.file(file),
            redirect = true,
            user = auth_user,
            password = auth_pass,
        }))
        code, headers = c, h
    end)
    pcall(function() socketutil:reset_timeout() end)

    if not ok_req2 then
        pcall(os.remove, tmp)
        return nil, "download failed"
    end

    if code == 401 or code == 403 then
        pcall(os.remove, tmp)
        return nil, "auth"
    end

    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        pcall(os.remove, tmp)
        local location = headers and headers.location
        if type(location) == "string" then
            local scheme = location:match("^(%a[%w+.-]*):")
            if url:match("^[Hh][Tt][Tt][Pp][Ss]:") and scheme and scheme:lower() ~= "https" then
                return nil, "downgrade", location
            end
            -- LuaSocket auto-follows same-scheme 301/302/303/307 but never
            -- 308 (its shouldredirect list predates RFC 7538), so a 308 with
            -- a usable Location lands here. Follow it manually, forwarding
            -- the credentials only when the target is same-origin with the
            -- URL the caller vetted -- the redirect target is
            -- server-controlled and must not siphon Basic auth off-origin.
            if code == 308 and (redirect_depth or 0) < 5 then
                local Feed = require("lib/bookshelf_opds_feed")
                local target = Feed.absolute(url, location)
                if type(target) == "string" then
                    local same = Feed.sameOrigin(url, target)
                    return D.download(target, dest_path,
                        same and user or nil, same and password or nil,
                        (redirect_depth or 0) + 1)
                end
            end
        end
        return nil, "download failed (" .. tostring(code) .. ")"
    end

    if code ~= 200 then
        pcall(os.remove, tmp)
        return nil, "download failed (" .. tostring(code) .. ")"
    end

    if not os.rename(tmp, dest_path) then
        -- The direct rename can fail for reasons unrelated to dest_path
        -- existing (e.g. a stale lock); only clear it out and retry once,
        -- rather than removing it up front and risking an unrecoverable
        -- loss if the retry then also fails.
        pcall(os.remove, dest_path)
        if not os.rename(tmp, dest_path) then
            pcall(os.remove, tmp)
            return nil, "rename failed"
        end
    end
    return dest_path
end

return D
