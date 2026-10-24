-- tests/_test_perf.lua
-- lib/bookshelf_perf: one "[bookshelf perf]" line per interaction, its steps
-- listed, at the debug level unless a measuring session turns it up.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local lines = { dbg = {}, warn = {} }
package.loaded["logger"] = {
    dbg  = function(s) lines.dbg[#lines.dbg + 1] = s end,
    warn = function(s) lines.warn[#lines.warn + 1] = s end,
}
local Perf = dofile("lib/bookshelf_perf.lua")

t.test("a span logs once, with its steps, when it finishes", function()
    Perf.start("editor select")
    assert(Perf.active())
    local t0 = Perf.now()
    Perf.part("grid", t0)
    Perf.finish("editor painted")
    assert(not Perf.active())
    Perf.finish("again")
    assert(#lines.dbg == 1, #lines.dbg)
    assert(lines.dbg[1]:find("^%[bookshelf perf%] editor select: %d+ms to editor painted %(grid %d+%)$"), lines.dbg[1])
end)

t.test("parts with no span open are dropped", function()
    Perf.part("grid", Perf.now())
    Perf.finish("x")
    assert(#lines.dbg == 1)
end)

t.test("loud sends them to warn, for a session with debug logging off", function()
    Perf.loud = true
    Perf.start("module colours")
    Perf.finish("editor painted")
    Perf.loud = false
    assert(#lines.warn == 1 and #lines.dbg == 1)
end)

t.done()
