-- bookshelf_hardcover_autolink.lua
-- The bulk Hardcover auto-link: every unlinked book, by embedded identifier
-- or by a title and author search.
--
-- Progress goes in the shelf's status line with its Stop button, as Extract
-- page counts' does (lib/bookshelf_scan_progress): nothing covers the shelf
-- and only Stop stops the pass. It used to be a message box over the shelf
-- that any tap cancelled, with each request holding the screen while it ran.
--
-- It waits while a book is open (the device may sleep meanwhile) and carries
-- on back on the shelf.
--
-- The pass runs inside a Trapper coroutine. The Hardcover client is borrowed
-- from a sync plugin and sends each request from a forked child when it is
-- called from a coroutine, so the shelf keeps answering taps. The client's
-- own tap trap comes with that: a tap while a request is in flight reaches
-- the shelf AND aborts the request. Such a book is tried again (RETRIES)
-- before it counts as an error.

local UIManager = require("ui/uimanager")
local T         = require("ffi/util").template
local _         = require("lib/bookshelf_i18n").gettext

local M = {}

-- About two Hardcover calls per book that uses the network (find it, then
-- fetch its details), and Hardcover allows 60 a minute.
M.RATE = 2.5
-- Extra goes at a book whose request failed, before it is an error.
M.RETRIES = 2
-- With Bookshelf's own client Hardcover says on every reply how much of the
-- rate limit is left, so the pass waits for what it is told and no longer
-- than this between books when there are requests to spare.
M.OWN_MIN_WAIT = 0.5
-- A wait longer than this is the day's budget gone: the pass ends and says
-- so; nobody leaves a pass running until midnight UTC.
M.MAX_WAIT = 120
-- Books in a row that end in an error before the pass gives up: a dropped
-- connection should cost seconds, not three timeouts for every book left.
M.MAX_FAILED_RUN = 3

-- Hand control back to UIManager, for `sec` seconds.
local function breathe(sec)
    local co = coroutine.running()
    UIManager:scheduleIn(sec or 0, function() coroutine.resume(co) end)
    coroutine.yield()
end

-- Display name for the report: the book's title, else its file name.
local function nameFor(fp, meta)
    if meta and type(meta.title) == "string" and meta.title ~= "" then
        return meta.title
    end
    return (fp:match("([^/]+)$") or fp):gsub("%.[^%.]+$", "")
end

-- attempt(fp, best_guess) -> outcome, meta, details
--   "linked" | "nomatch" | "noid" (no request made) | "error" (worth retrying)
local function attempt(Hardcover, Repo, fp, best_guess)
    if best_guess then
        -- Needs title and author, so the record is built first.
        local meta = (Repo.buildBookMeta and Repo.buildBookMeta(fp)) or { filepath = fp }
        local ok_call, linked_ok, details = pcall(Hardcover.bestGuessLink, meta)
        if ok_call and linked_ok then return "linked", meta, details end
        -- An exception, a failed search or a failed link write is an ERROR,
        -- not a verdict about the book (issue 310's second finding).
        if not ok_call or (details ~= "no_match" and details ~= "no_confident_match") then
            return "error", meta
        end
        return "nomatch", meta
    end
    -- Exact: embedded ISBN / Hardcover id only.
    local book = { filepath = fp }
    local ids = Hardcover.getEmbeddedIdentifiers and Hardcover.getEmbeddedIdentifiers(book)
    if not ids then return "noid", book end
    local ok_call, linked_ok, hc = pcall(Hardcover.linkFromEmbeddedIdentifiers, book)
    if not ok_call then return "error", book end
    if linked_ok then
        local meta = (Repo.buildBookMeta and Repo.buildBookMeta(fp)) or book
        return "linked", meta, hc
    end
    return "nomatch", book
end

-- run{ items = { filepath, ... }, best_guess = bool, shelf = widget or nil,
--      on_finish = function(st) }
-- -> false when another job holds the status line, else true.
-- st: i, cancelled, gave_up (three failed books in a row), rate_limited (the
--     day's Hardcover budget is spent), linked, no_match, no_id, errors,
--     linked_list, nomatch_list
function M.run(opts)
    local Progress = require("lib/bookshelf_scan_progress")
    if Progress.active() then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("Another job is running. Try again when it has finished."), timeout = 3 })
        return false
    end
    local items = opts.items or {}
    local total = #items
    local best_guess = opts.best_guess and true or false
    local st = { i = 0, cancelled = false, linked_list = {}, nomatch_list = {} }
    local function title(i) return T(_("Linking book %1 of %2"), i, total) end

    require("ui/trapper"):wrap(function()
        Progress.holdAwake(true)
        local job = Progress.begin{
            title = title(1),
            icons = Progress.BOOK_ICONS,
            shelf = function() return Progress.liveShelf(opts.shelf) end,
        }
        -- Bookshelf's own client runs each request under the job: the shelf
        -- keeps answering taps, and only Stop aborts a request in flight.
        local own
        local ok_run, err_run = xpcall(function()
            local Hardcover = require("lib/bookshelf_hardcover")
            local Repo = require("lib/bookshelf_book_repository")
            if Hardcover.source and Hardcover.source() == "own" then
                own = require("lib/bookshelf_hardcover_client")
                own.trap = job
            end
            -- pace() -> false when there is no budget left to wait for.
            local function pace()
                if not own then breathe(M.RATE); return true end
                local wait = own.waitTime()
                if wait > M.MAX_WAIT then return false end
                breathe(math.max(M.OWN_MIN_WAIT, wait))
                return true
            end
            local failed_run = 0
            for i, fp in ipairs(items) do
                Progress.update{ title = title(i), fraction = (i - 1) / total }
                -- Not while a book is open (maintainer: it pauses there and
                -- carries on back on the shelf), as Extract page counts. The
                -- reader's session is not the pass's to keep awake.
                if Progress.reading and Progress.reading() then
                    Progress.holdAwake(false)
                    while Progress.reading() and not job.stopped do breathe(2) end
                    Progress.holdAwake(true)
                end
                if job.stopped then st.cancelled = true; break end
                st.i = i
                local outcome, meta, details
                for try = 0, M.RETRIES do
                    outcome, meta, details = attempt(Hardcover, Repo, fp, best_guess)
                    if outcome ~= "error" or try == M.RETRIES or job.stopped then break end
                    if not pace() then break end
                end
                if outcome == "linked" then
                    st.linked = (st.linked or 0) + 1
                    -- Details and the cover/description decision now, so the
                    -- book is complete in one pass.
                    pcall(Hardcover.refreshBook, meta, {})
                    local d = type(details) == "table" and details or {}
                    local score
                    if tonumber(d.title_score) and tonumber(d.author_score) then
                        score = math.floor((d.title_score + d.author_score) / 2 + 0.5)
                    end
                    st.linked_list[#st.linked_list + 1] = {
                        name = nameFor(fp, meta), matched = d.title,
                        author = d.author, score = score,
                    }
                elseif outcome == "nomatch" then
                    st.no_match = (st.no_match or 0) + 1
                    st.nomatch_list[#st.nomatch_list + 1] = { name = nameFor(fp, meta) }
                elseif outcome == "noid" then
                    st.no_id = (st.no_id or 0) + 1
                else
                    st.errors = (st.errors or 0) + 1
                end
                failed_run = outcome == "error" and failed_run + 1 or 0
                if failed_run >= M.MAX_FAILED_RUN then
                    st.cancelled, st.gave_up = true, true
                    break
                end
                -- A book that made no request yields a tick now and then; one
                -- that did waits out Hardcover's rate.
                if outcome ~= "noid" then
                    if not pace() then
                        st.cancelled, st.rate_limited = true, true
                        break
                    end
                elseif i % 25 == 0 then
                    breathe(0)
                end
            end
        end, debug.traceback)
        -- Whatever happened, the status line lets go of the job.
        if own then own.trap = nil end
        Progress.finish()
        Progress.holdAwake(false)
        if not ok_run then
            st.errors = (st.errors or 0) + 1
            require("logger").warn("[bookshelf] Hardcover auto-link failed:", tostring(err_run))
        end
        if opts.on_finish then opts.on_finish(st) end
    end)
    return true
end

return M
