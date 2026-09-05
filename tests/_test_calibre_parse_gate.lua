-- tests/_test_calibre_parse_gate.lua
-- The size gate on metadata.calibre, and the notice that explains a slow read.
--
-- The old cap was 8MB, justified as "a real transient spike on a 256MB
-- Kindle". Measured on a PW5 (2026-09-05), that is not what happens: a plain
-- parse leaves a map ~0.37x the file's size, the peak is barely above it
-- (~0.41x, slimming keeps `comments`, which is the bulk), an 8MB parse needed
-- no new pages at all, and the device has 485MB. What the cap DID do was drop
-- every custom column for an ordinary library, silently -- 8MB is only about
-- 2,000 books once a few custom columns exist, because calibre repeats each
-- column's entire definition on every book (~412 bytes per column per book,
-- measured against calibre's own JsonCodec).
--
-- So the numbers here are load-bearing, not decoration. SOURCE-SHAPE, because
-- driving the loader needs rapidjson and a real file.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/calibre_metadata.lua"):read("*a")
local main = io.open("main.lua"):read("*a")

local function mb(name)
    local v = src:match("local " .. name .. "%s*=%s*(%d+)%s*%*%s*1024%s*%*%s*1024")
    return tonumber(v)
end

t.test("the parse cap is a backstop, not a limit on ordinary libraries", function()
    local cap = mb("CALIBRE_FULL_PARSE_MAX")
    assert(cap, "CALIBRE_FULL_PARSE_MAX is gone or no longer written in MB")
    assert(cap >= 32, "a cap of " .. cap .. "MB puts ordinary libraries back on "
        .. "the slim parser: at ~412 bytes per custom column per book, 8MB is "
        .. "about 2,000 books")
    -- ~0.4x held and ~100ms/MB, so the ceiling is where a parse threatens the
    -- device rather than merely being slow.
    assert(cap <= 128, "a cap of " .. cap .. "MB is ~" .. math.floor(cap * 0.4)
        .. "MB held and ~" .. math.floor(cap * 0.1) .. "s of parsing")
end)

t.test("the notice threshold sits below the cap and above the imperceptible", function()
    local notice = mb("CALIBRE_NOTICE_MIN")
    local cap    = mb("CALIBRE_FULL_PARSE_MAX")
    assert(notice, "CALIBRE_NOTICE_MIN is gone")
    assert(notice < cap, "a notice threshold at or above the cap never fires")
    -- ~100ms/MB: below ~10MB the message would flash and vanish inside a
    -- second, which reads as a glitch rather than an explanation.
    assert(notice >= 10, "at " .. notice .. "MB the notice fires for a wait of "
        .. "well under a second")
end)

t.test("the notice fires around the parse, and only when it will be felt", function()
    local body = src:match("local CALIBRE_FULL_PARSE_MAX.-\n    end\n")
    assert(body, "could not find the gated parse block")
    assert(body:match('CalibreMeta%.notify, "start"'), "must announce the start")
    assert(body:match('CalibreMeta%.notify, "done"'),  "must clear it afterwards")
    assert(body:match("local slow = size >= CALIBRE_NOTICE_MIN"),
        "the notice must be gated on size, not fired for every read")
    -- A host that has not installed a hook, and a hook that throws, must both
    -- leave the read working.
    for _, call in ipairs({ 'pcall%(CalibreMeta%.notify, "start"',
                            'pcall%(CalibreMeta%.notify, "done"' }) do
        assert(body:match(call), "notify must be called through pcall: " .. call)
    end
    assert(body:match("if slow and CalibreMeta%.notify then"),
        "must tolerate no hook being installed at all")
end)

t.test("the vendored reader stays UI-free", function()
    -- calibre_metadata.lua is byte-identical with bookends and checked by the
    -- parity script; reaching for a widget here would break that repo.
    for _, dep in ipairs({ "ui/widget/infomessage", "ui/uimanager", "ui/widget/" }) do
        assert(not src:find(dep, 1, true),
            "calibre_metadata must not require " .. dep .. "; it is vendored "
            .. "into bookends. Use the notify callback instead")
    end
end)

t.test("the host paints before the parse blocks", function()
    local hook = main:match("local function _installCalibreNotice%(%)\n(.-)\nend\n")
    assert(hook, "the host hook is gone or was renamed")
    assert(hook:match("UIManager:forceRePaint%(%)"),
        "without forcing a repaint the message appears only AFTER the wait it "
        .. "exists to explain")
    assert(hook:match("UIManager:show"), "must show the message")
    assert(hook:match("UIManager:close"), "must close it when done")
    assert(hook:match("if CalibreMeta%.notify then return end"),
        "installing twice would leak the first hook's state")
end)

t.done()
