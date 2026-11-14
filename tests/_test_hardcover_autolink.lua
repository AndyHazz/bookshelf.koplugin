-- tests/_test_hardcover_autolink.lua
-- The bulk Hardcover auto-link (lib/bookshelf_hardcover_autolink): what it
-- counts, how it paces, what a dropped request costs, and that it reports in
-- the shelf's status line with Stop, the way Extract page counts does.
--
-- It used to show a message box over the shelf that any tap cancelled, and
-- each request held the screen while it ran.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

-- A scheduler: waits are queued with their delay and run by pump().
local queue, waits
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_s, sec, fn) queue[#queue + 1] = fn; waits[#waits + 1] = sec end,
    nextTick = function(_s, fn) queue[#queue + 1] = fn; waits[#waits + 1] = 0 end,
    show = function() end,
}
local function pump()
    local guard = 0
    while #queue > 0 do
        guard = guard + 1
        assert(guard < 10000, "the run never ends")
        table.remove(queue, 1)()
    end
end
package.loaded["ui/trapper"] = {
    wrap = function(_s, fn) coroutine.wrap(fn)() end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_s, o) return o end }
package.loaded["ffi/util"] = { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["logger"] = { warn = function() end, dbg = function() end }

local job, updates, finished, awake, active, stop_at, reading
package.loaded["lib/bookshelf_scan_progress"] = {
    active = function() return active end,
    reading = function() return reading and reading() or false end,
    BOOK_ICONS = { "a", "b", "c" },
    begin = function(o) job = { stopped = false, title = o.title, icons = o.icons }; return job end,
    update = function(o)
        updates[#updates + 1] = o
        if stop_at and #updates >= stop_at then job.stopped = true end
    end,
    finish = function() finished = finished + 1 end,
    holdAwake = function(on) awake[#awake + 1] = on end,
    liveShelf = function(bw) return bw end,
}

-- Hardcover, scripted per file: a list of results, one per attempt.
local script, calls, refreshed
local function nextResult(fp)
    calls[fp] = (calls[fp] or 0) + 1
    local list = script[fp] or { { false, "no_match" } }
    local r = list[math.min(calls[fp], #list)]
    if r == "throw" then error("boom") end
    return r[1], r[2]
end
-- Which client Hardcover is using, and Bookshelf's own client's view of the
-- rate limit.
local source, wait_time, trap_seen
local OwnClient = { trap = nil, waitTime = function() return wait_time end }
package.loaded["lib/bookshelf_hardcover_client"] = OwnClient
package.loaded["lib/bookshelf_hardcover"] = {
    source = function() return source end,
    bestGuessLink = function(meta)
        trap_seen = OwnClient.trap
        return nextResult(meta.filepath)
    end,
    linkFromEmbeddedIdentifiers = function(book) return nextResult(book.filepath) end,
    getEmbeddedIdentifiers = function(book)
        return not book.filepath:find("noid", 1, true) and "isbn:1" or nil
    end,
    refreshBook = function(meta) refreshed[#refreshed + 1] = meta.filepath; return true end,
}
package.loaded["lib/bookshelf_book_repository"] = {
    buildBookMeta = function(fp) return { filepath = fp, title = "T " .. fp } end,
}

local AutoLink = dofile("lib/bookshelf_hardcover_autolink.lua")

local done
local function run(items, best_guess)
    queue, waits, updates, awake, calls, refreshed = {}, {}, {}, {}, {}, {}
    finished, done, job = 0, nil, nil
    local ok = AutoLink.run{
        items = items, best_guess = best_guess,
        on_finish = function(st) done = st end,
    }
    pump()
    return ok
end
local function reset()
    script, active, stop_at, reading = {}, false, nil, nil
    source, wait_time, trap_seen = "hardcover", 0, nil
    OwnClient.trap = nil
end

t.test("best guess: linked, no match and errors are told apart", function()
    reset()
    script = {
        a = { { true, { title = "A!", author = "Auth", title_score = 90, author_score = 80 } } },
        b = { { false, "no_confident_match" } },
        c = { { false, "Hardcover search failed" } },
    }
    run({ "a", "b", "c" }, true)
    assert(done, "on_finish never ran")
    eq(done.linked, 1); eq(done.no_match, 1); eq(done.errors, 1)
    eq(done.linked_list[1].matched, "A!"); eq(done.linked_list[1].score, 85)
    eq(done.linked_list[1].name, "T a")
    eq(done.nomatch_list[1].name, "T b")
    eq(#refreshed, 1, "a linked book's details are fetched in the same pass")
    eq(done.cancelled, false)
end)

t.test("a dropped request is tried again before it counts as an error", function()
    reset()
    -- A tap on the shelf while a request is in flight aborts that request
    -- (the client's own tap trap). The book gets another go.
    script = { a = { { false, "Hardcover search failed" }, { true, { title = "A" } } } }
    run({ "a" }, true)
    eq(done.linked, 1); eq(done.errors or 0, 0)
    eq(calls.a, 2)
    -- ...but not for ever.
    script = { a = { { false, "Hardcover search failed" } } }
    run({ "a" }, true)
    eq(done.errors, 1)
    eq(calls.a, 1 + AutoLink.RETRIES)
    -- A verdict about the book is not retried.
    script = { a = { { false, "no_match" } } }
    run({ "a" }, true)
    eq(calls.a, 1)
    -- Nor is a throw swallowed as a verdict.
    script = { a = { "throw" } }
    run({ "a" }, true)
    eq(done.errors, 1)
end)

t.test("exact: a book with no identifier costs no request and no wait", function()
    reset()
    script = { ["x"] = { { true, { title = "X" } } }, ["y"] = { { false, "nope" } } }
    run({ "noid1", "noid2", "x", "y" }, false)
    eq(done.no_id, 2); eq(done.linked, 1); eq(done.no_match, 1)
    eq(calls.noid1, nil)
    local paced = 0
    for _i, s in ipairs(waits) do if s >= AutoLink.RATE then paced = paced + 1 end end
    eq(paced, 2, "one paced wait per book that used the network")
end)

t.test("progress is the status line's: begin, a line per book, finish, awake held", function()
    reset()
    run({ "a", "b", "c" }, true)
    eq(job.title, "Linking book 1 of 3")
    eq(job.icons, package.loaded["lib/bookshelf_scan_progress"].BOOK_ICONS,
        "no turning-page icon: the page count scan has one")
    eq(updates[2].title, "Linking book 2 of 3")
    assert(math.abs(updates[2].fraction - 1 / 3) < 1e-9, "fraction " .. tostring(updates[2].fraction))
    eq(finished, 1)
    eq(awake[1], true); eq(awake[#awake], false)
end)

t.test("Stop ends the pass after the book in hand, and the report still shows", function()
    reset()
    stop_at = 2            -- Stop pressed while the second book's line is up
    run({ "a", "b", "c", "d" }, true)
    eq(done.cancelled, true)
    eq(calls.a, 1); eq(calls.b, nil, "a stopped pass must not start the next book")
    eq(finished, 1)
end)

t.test("a failure inside the pass still lets go of the status line", function()
    reset()
    package.loaded["lib/bookshelf_book_repository"].buildBookMeta = function() error("bad record") end
    run({ "a" }, true)
    package.loaded["lib/bookshelf_book_repository"].buildBookMeta =
        function(fp) return { filepath = fp, title = "T " .. fp } end
    eq(finished, 1); eq(awake[#awake], false)
    assert(done, "the report must still show")
end)

t.test("three failed books in a row end the pass", function()
    reset()
    script = { ok = { { true, { title = "K" } } } }
    for _i, fp in ipairs({ "e1", "e2", "e3", "e4" }) do script[fp] = { { false, "Hardcover search failed" } } end
    run({ "e1", "ok", "e2", "e3", "e4", "never" }, true)
    eq(done.linked, 1)
    eq(done.errors, 4, "a success in between starts the count again")
    eq(done.gave_up, true); eq(done.cancelled, true)
    eq(calls.never, nil)
end)

t.test("Bookshelf's own client: requests run under the job, so only Stop aborts one", function()
    reset()
    source = "own"
    run({ "a" }, true)
    eq(trap_seen, job, "the client was not given the job")
    eq(OwnClient.trap, nil, "the job was left on the client after the pass")
    -- A sync plugin's client is left alone.
    reset()
    run({ "a" }, true)
    eq(trap_seen, nil)
end)

t.test("Bookshelf's own client: the wait is what Hardcover says is left, not a fixed rate", function()
    reset()
    source = "own"
    wait_time = 0
    run({ "a", "b" }, true)
    for _i, sec in ipairs(waits) do
        assert(sec <= AutoLink.OWN_MIN_WAIT, "waited " .. tostring(sec) .. "s with requests to spare")
    end
    reset()
    source = "own"
    wait_time = 7
    run({ "a" }, true)
    local seven = false
    for _i, sec in ipairs(waits) do if sec == 7 then seven = true end end
    assert(seven, "did not wait for the bucket to refill")
end)

t.test("Bookshelf's own client: a day's budget spent ends the pass and says so", function()
    reset()
    source = "own"
    wait_time = 3600
    run({ "a", "b", "c" }, true)
    eq(done.rate_limited, true); eq(done.cancelled, true)
    eq(calls.b, nil, "went on asking with no budget left")
    for _i, sec in ipairs(waits) do assert(sec < 3600, "sat waiting for the day to end") end
end)

-- Maintainer: "it pauses when you open a book and resumes when you come back
-- to the shelf", as Extract page counts does. The reader's session is not
-- the pass's to keep awake.
t.test("a book opened mid-pass: it waits, lets the device sleep, and carries on after", function()
    reset()
    local open_for = 0
    reading = function()
        if calls.a and not calls.b and open_for < 3 then open_for = open_for + 1; return true end
        return false
    end
    run({ "a", "b" }, true)
    eq(open_for, 3, "it did not wait while the book was open")
    eq(calls.b, 1, "it did not carry on after")
    eq(done.cancelled, false)
    -- Held awake, let go while reading, held again, let go at the end.
    eq(table.concat((function() local o = {} for i, v in ipairs(awake) do o[i] = tostring(v) end return o end)(), ","),
        "true,false,true,false")
end)

t.test("Stop while waiting for a book to close ends the pass", function()
    reset()
    reading = function() if job then job.stopped = true end return true end
    run({ "a", "b" }, true)
    eq(done.cancelled, true); eq(calls.a, nil)
end)

t.test("one job at a time", function()
    reset()
    active = true
    eq(run({ "a" }, true), false)
    eq(done, nil); eq(finished, 0); eq(calls.a, nil)
end)

t.test("the bulk jobs wait for a connection first", function()
    local f = assert(io.open("lib/bookshelf_settings.lua")); local src = f:read("*a"); f:close()
    assert(src:find('Hardcover.whenOnline(function()\n                require("lib/bookshelf_hardcover_autolink").run{', 1, true),
        "the bulk auto-link does not ask for a connection")
    f = assert(io.open("main.lua")); src = f:read("*a"); f:close()
    assert(src:find("return HC.whenOnline(function() self:refreshHardcoverDetails(true) end)", 1, true),
        "the bulk details refresh does not ask for a connection")
end)

t.test("the settings menu runs this pass, and the old message-box runner is gone", function()
    local f = assert(io.open("lib/bookshelf_settings.lua")); local src = f:read("*a"); f:close()
    assert(src:find('require("lib/bookshelf_hardcover_autolink").run{', 1, true), "not wired")
    assert(not src:find("runPacedScan", 1, true), "the old runner is still there")
    assert(not src:find("(tap to cancel)", 1, true), "a tap anywhere must not cancel")
end)

t.done()
