-- bookshelf_scan_progress.lua
-- A long background job's progress ("Extract page counts"), shown in the
-- shelf's own status line: what it is doing, a bar, and a Stop button.
--
-- It replaces Trapper's own TrapWidget, which had two problems: it is a strip
-- pinned to the bottom-left corner with almost no padding, and its tap range
-- is the whole screen, so ANY tap anywhere cancelled the scan -- "it's not
-- really running in the background". Here nothing covers the shelf and only
-- Stop stops the job. The status line is the one place in the layout that
-- already has room for a line of text; when the reader has switched it off,
-- it is shown for as long as the job runs.
--
-- Trapper-compatible: pass the job table (M.job()) to
-- Trapper:dismissableRunInSubprocess in place of a message string. Trapper
-- only sets job.dismiss_callback on a table it did not create, for the length
-- of that call; Stop fires it only while `in_run` is set, since between calls
-- it would resume the coroutine somewhere else entirely.

local UIManager = require("ui/uimanager")

local M = {}

local _job = nil

-- Minimum time between progress repaints: an e-ink panel should not refresh
-- for every one of hundreds of millisecond-long steps.
M.MIN_UPDATE_S = 1

local function now()
    local ok, gettime = pcall(require, "lib/bookshelf_gettime")
    return ok and gettime() or os.time()
end

function M.active() return _job ~= nil end
function M.job() return _job end

local function shelf()
    return _job and _job.shelf and _job.shelf() or nil
end

local function shown(w)
    return w ~= nil and UIManager:isWidgetShown(w)
end

-- The status line changes size when the job starts or ends (it may not have
-- been shown at all), so the shelf lays itself out again.
local function relayout(w)
    if not shown(w) then return end
    w._strip_h_memo = nil
    if w._rebuild then
        w:_rebuild()
        UIManager:setDirty(w, "ui")
    end
end

-- Between the two, only the line's text and bar change, and the line keeps
-- its height, so the status strip alone is swapped and repainted.
local function repaint()
    local w = shelf()
    if not shown(w) or UIManager:getTopmostVisibleWidget() ~= w then return end
    if w.refreshStatusLine then w:refreshStatusLine() end
end

-- The icon's own clock. A book can take several seconds to render, and one
-- frame per book read as stuck, so the icon turns on a timer while the job
-- runs, independent of progress. Each turn repaints only the status strip.
M.ANIMATE_S = 1

local function tick(job)
    if _job ~= job or job.stopped then return end
    if job.icons and #job.icons > 1 then
        job.frame = job.frame % #job.icons + 1
        job._last_paint = now()
        repaint()
    end
    UIManager:scheduleIn(M.ANIMATE_S, job._tick)
end

-- begin{title=, icons=, shelf=function() -> the live shelf widget} -> the job
-- icons (optional): glyphs shown before the title in turn, on the ANIMATE_S
-- timer.
function M.begin(opts)
    if _job and _job._tick then UIManager:unschedule(_job._tick) end
    _job = {
        title    = opts.title or "",
        icons    = opts.icons,
        frame    = 1,
        detail   = opts.detail,
        fraction = 0,
        stopped  = false,
        in_run   = false,
        shelf    = opts.shelf,
        _last_paint = 0,
    }
    local job = _job
    job._tick = function() tick(job) end
    relayout(shelf())
    if job.icons and #job.icons > 1 then UIManager:scheduleIn(M.ANIMATE_S, job._tick) end
    return job
end

-- update{title=, detail=, fraction=, force=}
function M.update(opts)
    if not _job then return end
    if opts.title ~= nil then _job.title = opts.title end
    if opts.detail ~= nil then _job.detail = opts.detail end
    if opts.fraction ~= nil then _job.fraction = opts.fraction end
    local t = now()
    if not opts.force and t - _job._last_paint < M.MIN_UPDATE_S then return end
    _job._last_paint = t
    repaint()
end

function M.stop()
    if not _job or _job.stopped then return end
    _job.stopped = true
    local _ = require("lib/bookshelf_i18n").gettext
    M.update{ title = _("Stopping\xe2\x80\xa6"), detail = "", force = true }
    if _job.in_run and _job.dismiss_callback then _job.dismiss_callback() end
end

function M.stopped() return _job ~= nil and _job.stopped end

-- icon() -> the glyph for the current frame, or nil.
function M.icon()
    local icons = _job and _job.icons
    return icons and icons[_job.frame] or nil
end

-- A shelf widget that was rebuilt or replaced while the job ran is still
-- found through the getter, so the last one showing gets the relayout.
function M.finish()
    local w = shelf()
    if _job and _job._tick then UIManager:unschedule(_job._tick) end
    _job = nil
    relayout(w)
end

-- reading() -> true while a book the user opened is on screen. Pages are
-- rendered in forks, each seconds of CPU the reader would feel, so the job
-- waits. A reader sits ABOVE the shelf in the window stack when it was opened
-- from it; a parked one (bookshelf's hot reader parking) sits below and does
-- not count. With no shelf in the stack at all, any reader counts.
function M.reading()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    local w = shelf()
    local shelf_idx = 0
    for i, entry in ipairs(stack) do
        if entry.widget == w then shelf_idx = i end
    end
    for i, entry in ipairs(stack) do
        if i > shelf_idx and entry.widget and entry.widget.name == "ReaderUI" then
            return true
        end
    end
    return false
end

-- For tests.
function M._reset()
    if _job and _job._tick then UIManager:unschedule(_job._tick) end
    _job = nil
end

return M
