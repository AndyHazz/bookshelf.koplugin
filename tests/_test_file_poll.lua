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

-- nextInterval: how often the new-file poll re-arms itself
eq(FilePoll.nextInterval{ wifi_on = false, idle_s = 1000 }, nil, "wifi off returns nil even when idle")
eq(FilePoll.nextInterval{ wifi_on = nil, idle_s = 0 }, 5, "unknown wifi (nil) polls")
eq(FilePoll.nextInterval{ wifi_on = true, covered = true, idle_s = 1000 }, 30, "covered beats idle")
eq(FilePoll.nextInterval{ wifi_on = true, idle_s = 60 }, 60, "idle at exactly IDLE_AFTER_S returns the idle interval")
eq(FilePoll.nextInterval{ wifi_on = true, idle_s = 59 }, 5, "idle just under IDLE_AFTER_S returns the active interval")
eq(FilePoll.nextInterval{ wifi_on = true, idle_s = math.huge }, 60, "math.huge idle returns the idle interval")
eq(FilePoll.nextInterval{ wifi_on = true }, 5, "nil idle_s returns active")
eq(FilePoll.nextInterval{ wifi_on = true, idle_s = -5 }, 5, "negative idle_s behaves as 0 (active)")
eq(FilePoll.nextInterval{ wifi_on = true, idle_s = 0 / 0 }, 5, "NaN idle_s behaves as 0 (active)")
eq(FilePoll.ACTIVE_INTERVAL_S, 5, "ACTIVE_INTERVAL_S constant")
eq(FilePoll.IDLE_INTERVAL_S, 60, "IDLE_INTERVAL_S constant")
eq(FilePoll.IDLE_AFTER_S, 60, "IDLE_AFTER_S constant")
eq(FilePoll.COVERED_INTERVAL_S, 30, "COVERED_INTERVAL_S constant")

print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
