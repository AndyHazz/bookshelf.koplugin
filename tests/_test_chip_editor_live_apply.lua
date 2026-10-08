-- tests/_test_chip_editor_live_apply.lua
-- The shelf editor applies every change as it is made, and closes with Close.
--
-- WHAT NEEDS PINNING. The editor used to hold edits in a draft: some showed on
-- the shelf behind (style, face-out, theme), the source, filters and sort only
-- after OK then Save, and what Cancel would undo was anybody's guess (5.4
-- tutorial recording). The maintainer: "make that all apply on selection and
-- change Save to Close". So every change is saved as it lands (in memory; the
-- editor flushes as it closes), the shelf rebuilds once per run of taps, and
-- Close, the X, a tap outside and Back all do the same thing. Two rules
-- survive from the draft days: a new shelf that never got a source is removed
-- as the editor closes, and a shelf of shelves given another source asks
-- before its shelves are deleted -- refused, it keeps its source.
--
-- The state machine is a block of closures inside Editor:editTab; it is pulled
-- out of the source (from `local committed` to just before the widget
-- constructors) and run against stubs.
--
-- Usage (from plugin root): lua tests/_test_chip_editor_live_apply.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

local edit_tab = src:match("\nfunction Editor:editTab%(tab_id, opts%)\n(.-)\nend\n\n")
assert(edit_tab, "Editor:editTab not found")
local block = edit_tab:match("\n(    local committed = .-)\n%s*%-%- Lazy%-loaded widget constructors")
assert(block, "the editor's state block (committed .. sourceChosen) not found")

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deepCopy(x) end
    return o
end
local function sameValue(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, x in pairs(a) do if not sameValue(x, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- h(stored_tabs, tab_id, opts?) -> a harness: the saved list, the editor's
-- closures, and a log of everything they asked of the outside.
local function harness(tabs, tab_id, hopts)
    hopts = hopts or {}
    local e = { saved = deepCopy(tabs), log = {}, timers = {}, closed = 0, shown = {},
                changes = {}, rebuilds = 0, discarded = 0 }
    local function log(s) e.log[#e.log + 1] = s end
    e.TabModel = {
        NO_SOURCE = "none", SHELVES_KIND = "shelves",
        load = function() return deepCopy(e.saved) end,
        saveDeferred = function(list) e.saved = deepCopy(list); log("saveDeferred") end,
        save = function(list) e.saved = deepCopy(list); log("save") end,
        flush = function() log("flush") end,
        childrenOf = function(id, list)
            local out = {}
            for _i, x in ipairs(list or e.saved) do if x.parent == id then out[#out + 1] = x end end
            return out
        end,
        removeTree = function(list, id)
            for i = #list, 1, -1 do
                if list[i].id == id or list[i].parent == id then table.remove(list, i) end
            end
        end,
    }
    e.UIManager = {
        unschedule = function(_, fn) e.timers[fn] = nil end,
        scheduleIn = function(_, _s, fn) e.timers[fn] = true end,
        close = function(_, w) e.closed = e.closed + 1; log("close") end,
        show = function(_, w) e.shown[#e.shown + 1] = w end,
    }
    e.ConfirmBox = { new = function(_, o) return o end }
    e.Editor = { _deepCopy = deepCopy, _sameValue = sameValue }
    e._ = function(s) return s end
    e.pairs, e.ipairs, e.type = pairs, ipairs, type
    e.tab_id = tab_id
    local target
    for _i, x in ipairs(tabs) do if x.id == tab_id then target = x end end
    e.target = target
    e.draft = deepCopy(target)
    e.opts = {
        on_change = function(info) e.changes[#e.changes + 1] = info or {} end,
        on_discard = hopts.no_discard and nil or function() e.discarded = e.discarded + 1 end,
    }
    local chunk = block .. "\nreturn { commit = commit, finish = finish, sourceChosen = sourceChosen,"
        .. " onArranged = onArranged, fire = firePreview,"
        .. " set_rebuild = function(f) rebuild = f end, set_dialog = function(d) dialog = d end }"
    local fn, err = load(chunk, "editor-state", "t", e)
    assert(fn, err)
    e.api = fn()
    e.api.set_rebuild(function() e.rebuilds = e.rebuilds + 1 end)
    e.api.set_dialog({ "dialog" })
    e.fireTimers = function()
        for f in pairs(e.timers) do e.timers[f] = nil; f() end
    end
    e.savedTab = function(id)
        for _i, x in ipairs(e.saved) do if x.id == (id or tab_id) then return x end end
    end
    return e
end

local function shelf(id, kind, extra)
    local x = { id = id, label = id, source = { kind = kind }, filter = {}, sort_priority = {}, enabled = true }
    for k, v in pairs(extra or {}) do x[k] = v end
    return x
end

t.test("a change is saved as it is made, in memory, and the shelf rebuilds after the tap", function()
    local e = harness({ shelf("home", "all") }, "home")
    e.draft.spine_rows = 3
    e.api.commit()
    eq(e.savedTab().spine_rows, 3, "the change did not reach the saved shelf")
    eq(e.log[#e.log], "saveDeferred", "a tap must not wait for a settings flush")
    eq(#e.changes, 0, "the shelf rebuild must not run inside the tap")
    e.fireTimers()
    eq(#e.changes, 1, "the shelf behind did not follow the change")
end)

t.test("a run of taps is one rebuild", function()
    local e = harness({ shelf("home", "all") }, "home")
    for n = 1, 3 do e.draft.spine_rows = n; e.api.commit() end
    e.fireTimers()
    eq(#e.changes, 1)
    eq(e.savedTab().spine_rows, 3)
end)

t.test("every field reaches the saved shelf, as a copy", function()
    -- What the old live preview carried field by field (theme, ornaments,
    -- face-out, the + tile...) now goes whole.
    local e = harness({ shelf("home", "all") }, "home")
    e.draft.theme = "Ukiyo-e"; e.draft.ornament_frequency = 2
    e.draft.spine_face_out = "all"; e.draft.hide_add_tile = true; e.draft.label = "Mine"
    e.draft.filter = { genres = { Horror = true } }
    e.api.commit()
    local s = e.savedTab()
    eq(s.theme, "Ukiyo-e"); eq(s.ornament_frequency, 2); eq(s.spine_face_out, "all")
    eq(s.hide_add_tile, true); eq(s.label, "Mine"); eq(s.filter.genres.Horror, true)
    e.draft.filter.genres.Fantasy = true
    eq(e.savedTab().filter.genres.Fantasy, nil, "the saved shelf shares a table with the working copy")
end)

t.test("Close flushes, and runs a rebuild still owed at once", function()
    local e = harness({ shelf("home", "all") }, "home")
    e.draft.list_rows = 5
    e.api.commit()
    e.api.finish()
    eq(e.closed, 1)
    assert(table.concat(e.log, ","):find("close,flush", 1, true), "Close does not flush: " .. table.concat(e.log, ","))
    eq(#e.changes, 1, "the last change never reached the shelf")
    e.fireTimers()
    eq(#e.changes, 1, "the owed rebuild ran twice")
end)

t.test("Close with nothing changed does not rebuild the shelf", function()
    local e = harness({ shelf("home", "all") }, "home")
    e.api.finish()
    eq(#e.changes, 0)
    eq(e.closed, 1)
end)

t.test("Close is once, whichever ways it is reached", function()
    local e = harness({ shelf("home", "all") }, "home")
    e.api.finish(); e.api.finish()
    eq(e.closed, 1)
end)

t.test("a source change tells the shelf, so the old drill is left", function()
    local e = harness({ shelf("home", "all") }, "home")
    e.draft.source = { kind = "series" }
    e.api.sourceChosen()
    eq(e.savedTab().source.kind, "series", "the source is not applied on selection")
    e.fireTimers()
    eq(e.changes[1].source_changed, true)
    eq(e.rebuilds, 1, "the editor's own rows did not follow")
end)

t.test("backing out of the source picker changes nothing", function()
    local e = harness({ shelf("home", "all") }, "home")
    e.api.sourceChosen()
    eq(#e.log, 0, "nothing picked, yet something was saved")
    e.fireTimers()
    eq(#e.changes, 0)
end)

t.test("a shelf of shelves asks before another source deletes its shelves; OK deletes them", function()
    local e = harness({ shelf("box", "shelves"), shelf("a", "all", { parent = "box" }) }, "box")
    e.draft.source = { kind = "recent" }
    e.api.sourceChosen()
    eq(#e.shown, 1, "no question asked")
    eq(e.savedTab().source.kind, "shelves", "the source changed before the reader said yes")
    eq(e.savedTab("a") ~= nil, true)
    e.shown[1].ok_callback()
    eq(e.savedTab().source.kind, "recent")
    eq(e.savedTab("a"), nil, "the shelves inside were stranded")
end)

t.test("refused, the shelf keeps its source and its shelves", function()
    local e = harness({ shelf("box", "shelves"), shelf("a", "all", { parent = "box" }) }, "box")
    e.draft.source = { kind = "recent" }
    e.draft.sort_priority = { { key = "last_opened", reverse = true } }
    e.api.sourceChosen()
    e.shown[1].cancel_callback()
    eq(e.draft.source.kind, "shelves", "the editor still shows the refused source")
    eq(#e.draft.sort_priority, 0, "the refused source's defaults stayed")
    eq(e.savedTab().source.kind, "shelves")
    assert(e.savedTab("a"), "a refused change deleted the shelves")
end)

t.test("a new shelf closed without a source is removed, and the reader goes back", function()
    local e = harness({ shelf("home", "all"), shelf("custom_1", "none", { pending = true }) }, "custom_1")
    e.draft.label = "Named first"
    e.api.commit()
    e.api.finish()
    eq(e.savedTab(), nil, "a shelf with no source was kept")
    eq(e.discarded, 1, "the reader was not taken back to the shelf they came from")
    e.fireTimers()
    eq(#e.changes, 0, "a rebuild of the removed shelf was still owed")
end)

t.test("a new shelf is kept once it has a source, and is no longer pending", function()
    local e = harness({ shelf("custom_1", "none", { pending = true }) }, "custom_1")
    e.draft.source = { kind = "recent" }
    e.api.sourceChosen()
    eq(e.savedTab().pending, nil, "a restart would prune a shelf the reader set up")
    e.api.finish()
    assert(e.savedTab(), "a new shelf with a source was removed")
    eq(e.discarded, 0)
end)

t.test("a confirmed collection arrangement rebuilds the shelf", function()
    local e = harness({ shelf("c", "collection") }, "c")
    e.api.onArranged()
    e.api.finish()
    eq(#e.changes, 1, "the arrangement never reached the shelf")
end)

-- The wiring, at source level: one Close, and every way out reaches finish.
t.test("the footer is Delete, Close, Add: no Save, no Cancel", function()
    local body = edit_tab:gsub("%-%-[^\n]*", "")
    assert(not body:find('_("Save")', 1, true), "the editor still has a Save button")
    assert(body:find('text             = _("Close"),', 1, true), "no Close button")
    assert(body:find("callback         = function() finish() end,", 1, true), "Close does not finish")
    assert(not body:find('text       = _("Cancel"),', 1, true), "the editor still has a Cancel button")
end)

t.test("the X, a tap outside and Back are all Close", function()
    local body = edit_tab:gsub("%-%-[^\n]*", "")
    assert(body:find("close_callback    = function() finish() end,", 1, true), "the X is not Close")
    local tap = body:match("dialog%.onTapClose = function.-\n    end\n")
    assert(tap and tap:find("finish()", 1, true), "a tap outside is not Close")
    local back = body:match("dialog%.onClose = function.-\n    end\n")
    assert(back and back:find("finish()", 1, true), "Back is not Close")
end)

t.test("no preview override or draft dirty flags are left", function()
    for _i, dead in ipairs({ "applyLivePreview", "setOverride", "clearOverride",
                             "data_dirty", "visual_dirty", "repaintOnCancel", "withShelvesResolved" }) do
        assert(not src:find(dead, 1, true), "dead draft code left: " .. dead)
    end
    local tm = io.open("lib/bookshelf_tab_model.lua"):read("*a")
    assert(not tm:find("_override", 1, true), "TabModel still carries the editor's preview override")
end)

t.test("each sub-dialog hands back through commit", function()
    for _i, call in ipairs({
        "Editor:_openFilters(draft, function() commit(); rebuild() end)",
        "Editor:_pickSource(draft, sourceChosen)",
        "local done = function() commit(); rebuild() end",
    }) do
        assert(src:find(call, 1, true), "not applied on selection: " .. call)
    end
    assert(src:find("Editor:_pickGroupDisplay(draft, function()\n                    commit()", 1, true),
        "Shelf style picks do not apply")
    assert(src:find("Editor:_openCatalogSettings(draft, function()\n                        commit()", 1, true),
        "catalog settings do not apply")
end)

t.done()
