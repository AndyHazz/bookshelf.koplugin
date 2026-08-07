-- tests/_test_file_poll.lua
-- Decision logic for BookshelfWidget's file poll when the shelf is NOT the
-- topmost visible widget, plus resolution of the stock effective download dir.
package.path = "./?.lua;./?/init.lua;" .. package.path

local FilePoll = dofile("lib/bookshelf_file_poll.lua")

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. label .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end

-- covered by a transient UI (OPDS browser, terminal): keep ticking, no I/O
eq(FilePoll.coveredDecision{ shelf_on_stack = true, reader_active = false, reader_parked = false },
   "idle", "transient cover idles")
-- active reading session on top: stop entirely (the #304 battery case)
eq(FilePoll.coveredDecision{ shelf_on_stack = true, reader_active = true, reader_parked = false },
   "cancel", "active reader cancels")
-- reader exists but is hot-parked BELOW the shelf; something else covers us: idle
eq(FilePoll.coveredDecision{ shelf_on_stack = true, reader_active = true, reader_parked = true },
   "idle", "parked reader idles")
-- shelf torn off the stack: nothing to refresh, stop
eq(FilePoll.coveredDecision{ shelf_on_stack = false, reader_active = false, reader_parked = false },
   "cancel", "off-stack cancels")

-- effectiveDownloadDir mirrors opdsbrowser.lua:1204: download_dir || lastdir
local function rs(t) return function(k) return t[k] end end
eq(FilePoll.effectiveDownloadDir(rs{ download_dir = "/mnt/us/dl" }), "/mnt/us/dl", "download_dir wins")
eq(FilePoll.effectiveDownloadDir(rs{ lastdir = "/mnt/us/books" }), "/mnt/us/books", "lastdir fallback")
eq(FilePoll.effectiveDownloadDir(rs{ download_dir = "/mnt/us/dl/", lastdir = "/x" }), "/mnt/us/dl", "trailing slash stripped")
eq(FilePoll.effectiveDownloadDir(rs{ download_dir = "/" }), "/", "root stays root")
eq(FilePoll.effectiveDownloadDir(rs{}), nil, "nothing set -> nil")
eq(FilePoll.effectiveDownloadDir(rs{ download_dir = 42 }), nil, "non-string -> nil")

print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
