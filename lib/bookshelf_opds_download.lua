-- lib/bookshelf_opds_download.lua
-- OPDS acquisition download core: pick a destination directory, name the
-- file, and fetch it. Modelled on bookshelf_cover_fetch.download (User-Agent,
-- socketutil timeouts, pcall + unconditional timeout reset, tmp-then-rename
-- atomic write) and bookshelf_opds_feed.fetch ("auth" for 401/403).
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

-- Acquisition MIME type -> file extension (no leading dot). Covers the
-- formats bookshelf_opds_feed.SUPPORTED_TYPE advertises as downloadable,
-- minus djvu (KOReader has no djvu file extension convention to target here).
local EXT_BY_TYPE = {
    ["application/epub+zip"]           = "epub",
    ["application/pdf"]                = "pdf",
    ["application/x-mobipocket-ebook"] = "mobi",
    ["application/fb2"]                = "fb2",
    ["application/x-fictionbook+xml"]  = "fb2",
    ["application/x-cbz"]              = "cbz",
    ["text/plain"]                     = "txt",
    ["text/html"]                      = "html",
}

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
function D.destinationDir(read_setting)
    if type(read_setting) ~= "function" then return nil end
    local home = read_setting("home_dir")
    if type(home) ~= "string" or home == "" then return nil end
    if home ~= "/" then home = home:gsub("/+$", "") end

    local FilePoll = require("lib/bookshelf_file_poll")
    local eff = FilePoll.effectiveDownloadDir(read_setting)
    if type(eff) == "string" and eff ~= "" then
        local e = (eff ~= "/") and eff:gsub("/+$", "") or eff
        if e == home or e:sub(1, #home + 1) == (home .. "/") then
            return e
        end
    end
    return home
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

-- download(url, dest_path[, user, password]) -> path|nil, err[, extra]
--
-- Blocking; wrap in Trapper if calling from a UI context that must stay
-- responsive. Fetches url to dest_path atomically (tmp-then-rename,
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
function D.download(url, dest_path, user, password)
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
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local c, h = socket.skip(1, http.request({
            url = url, method = "GET",
            headers = { ["User-Agent"] = "KOReader-Bookshelf" },
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

    if code == 301 or code == 302 or code == 303 or code == 307 then
        pcall(os.remove, tmp)
        local location = headers and headers.location
        if type(location) == "string" then
            local scheme = location:match("^(%a[%w+.-]*):")
            if url:match("^[Hh][Tt][Tt][Pp][Ss]:") and scheme and scheme:lower() ~= "https" then
                return nil, "downgrade", location
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
