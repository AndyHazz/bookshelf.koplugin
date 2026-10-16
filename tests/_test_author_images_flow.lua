-- tests/_test_author_images_flow.lua
-- The bulk "Find author images online" pass (lib/bookshelf_author_images_flow):
-- what it counts, when it stops, and what it says at the end. The finding
-- itself is stubbed; tests/_test_author_images.lua covers that.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

local shown, infos, dismiss_at, results, fetched, repaints
package.loaded["ui/uimanager"] = {
    show = function(_s, w) shown[#shown + 1] = w end,
    setDirty = function() end,
    isWidgetShown = function() return true end,
    preventStandby = function() end, allowStandby = function() end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_s, o) return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(_s, o) o.confirm = true; return o end }
package.loaded["ffi/util"] = { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
-- The bulk pass runs each lookup through dismissableRunInSubprocess (run in
-- place here) and reports in the status line (Progress, stubbed): each
-- update is one author, and Stop at the dismiss_at'th sets job.stopped.
local finished
package.loaded["ui/trapper"] = {
    wrap = function(_s, fn) fn() end,
    info = function(_s, text) infos[#infos + 1] = text; return true end,
    clear = function() end,
    -- Stop while a lookup runs aborts the child: it comes back incomplete.
    dismissableRunInSubprocess = function(_s, task, j, _simple)
        if j and j.stopped then return false end
        return true, task()
    end,
}
local job
package.loaded["lib/bookshelf_scan_progress"] = {
    active = function() return false end,
    begin = function(o) job = { stopped = false, title = o.title }; finished = false; return job end,
    update = function(o)
        infos[#infos + 1] = o.title
        if dismiss_at and #infos >= dismiss_at then job.stopped = true end
    end,
    finish = function() finished = true end,
}
package.loaded["lib/bookshelf_cover_fetch"] = { runWhenOnline = function(fn) fn() end }
local overrides, cleared = {}, {}
package.loaded["lib/bookshelf_image_source"] = {
    invalidateCache = function() repaints = repaints + 1 end,
    getStackImageOverride = function(_k, name) return overrides[name] end,
    clearStackImage = function(_k, name) cleared[#cleared + 1] = name; overrides[name] = nil end,
}
local AI_real = dofile("lib/bookshelf_author_images.lua")
package.loaded["lib/bookshelf_author_images"] = {
    isPlaceholder = AI_real.isPlaceholder,
    fetch = function(name)
        fetched[#fetched + 1] = name
        local r = results[name] or "none"
        if r == "ok" then return "/lib/authors/" .. name .. ".jpg", "openlibrary" end
        return nil, r
    end,
}
local Flow = dofile("lib/bookshelf_author_images_flow.lua")
local bw = { _rebuild = function() end }

local function reset()
    shown, infos, dismiss_at, results, fetched, repaints = {}, {}, nil, {}, {}, 0
end
local function summary() return shown[#shown] and shown[#shown].text end

t.test("counts what it found, and repaints once", function()
    reset()
    results = { A = "ok", B = "none", C = "ok" }
    Flow.run(bw, { "A", "B", "C" })
    eq(#fetched, 3); eq(repaints, 1)
    eq(summary(), "Found images for 2 of 3 authors.")
end)

t.test("placeholders are neither fetched nor counted", function()
    reset()
    results = { Saki = "ok" }
    Flow.run(bw, { "Anonymous", "Saki", "Various" })
    eq(#fetched, 1); eq(summary(), "Found images for 1 of 1 authors.")
end)

t.test("stops after three authors in a row cannot reach either source", function()
    reset()
    results = { A = "ok", B = "unreachable", C = "unreachable", D = "unreachable", E = "ok" }
    Flow.run(bw, { "A", "B", "C", "D", "E" })
    eq(#fetched, 4)
    eq(summary(), "Found images for 1 of 4 authors.\n\nCouldn't reach Open Library or Wikipedia.")
end)

t.test("one unreachable author among answered ones does not stop it", function()
    reset()
    results = { A = "unreachable", B = "unreachable", C = "none", D = "unreachable", E = "ok" }
    Flow.run(bw, { "A", "B", "C", "D", "E" })
    eq(#fetched, 5)
end)

t.test("Stop in the status line says how many were left", function()
    reset()
    dismiss_at = 3
    results = { A = "ok", B = "ok" }
    Flow.run(bw, { "A", "B", "C", "D" })
    eq(#fetched, 2)
    eq(summary(), "Found images for 2 of 2 authors.\n\nStopped before 2 more.")
end)

t.test("nothing found, nothing repainted", function()
    reset()
    Flow.run(bw, { "A" })
    eq(repaints, 0)
end)

t.test("one author: a hand-picked image is set aside so the new photo shows", function()
    reset(); cleared = {}
    overrides["Saki"] = "/books/saki-i-chose.png"
    results = { Saki = "ok" }
    Flow.findOne(bw, "Saki")
    eq(cleared[1], "Saki"); eq(repaints, 1); eq(#shown, 0)
end)

t.test("one author: a miss says so and changes nothing", function()
    reset(); cleared = {}
    overrides["Emily Tesh"] = "/books/tesh.png"
    Flow.findOne(bw, "Emily Tesh")
    eq(#cleared, 0); eq(repaints, 0)
    eq(summary(), "No photo found for Emily Tesh.")
end)

t.test("the bulk pass shows in the status line and always lets go of it", function()
    reset()
    results = { A = "ok" }
    Flow.run(bw, { "A", "B" })
    eq(infos[1], "Finding author images: 1 of 2"); eq(infos[2], "Finding author images: 2 of 2")
    eq(finished, true, "the status line still shows the job")
end)

t.done()
