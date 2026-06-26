local MS = dofile("lib/bookshelf_menu_shortcut.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(label, got, want)
    if got ~= want then error(label .. ": got " .. tostring(got) .. ", want " .. tostring(want)) end
end

-- A fake file-manager menu tree (TouchMenu shape).
local function fakeTree()
    return {
        { id = "setting", text = "Settings", sub_item_table = {
            { id = "network", text = "Network", sub_item_table = {
                { id = "network_proxy", text = "HTTP proxy", callback = function() end },
                { id = "network_wifi",  text = "Wi-Fi",       callback = function() end },
            }},
            -- a plugin's own submenu: inner leaf has NO id (text fallback)
            { id = "plugin_x", text = "Plugin X", sub_item_table = {
                { text = "Do the thing", callback = function() end },
            }},
        }},
        { text = "----------" },  -- separator-ish, non-actionable (no id/callback/sub)
    }
end

test("_label reads text or text_func", function()
    eq("text", MS._label({ text = "A" }), "A")
    eq("func", MS._label({ text_func = function() return "B" end }), "B")
    eq("none", MS._label({}), "")
end)

test("_segment prefers id, falls back to text", function()
    eq("id", MS._segment({ id = "x", text = "X" }).id, "x")
    local seg = MS._segment({ text = "Y" })
    eq("text", seg.text, "Y")
    eq("no id", seg.id, nil)
end)

test("walk resolves an id path to the leaf", function()
    local tree = fakeTree()
    local leaf = MS.walk(tree, { {id="setting"}, {id="network"}, {id="network_proxy"} })
    eq("found", MS._label(leaf), "HTTP proxy")
end)

test("walk uses text fallback for an id-less leaf", function()
    local tree = fakeTree()
    local leaf = MS.walk(tree, { {id="setting"}, {id="plugin_x"}, {text="Do the thing"} })
    eq("found", MS._label(leaf), "Do the thing")
end)

test("walk returns nil when a segment does not resolve", function()
    local tree = fakeTree()
    eq("missing", MS.walk(tree, { {id="setting"}, {id="nope"} }), nil)
    eq("missing leaf", MS.walk(tree, { {id="setting"}, {id="network"}, {text="Gone"} }), nil)
end)

test("buildCaptureTree: leaf callback captures its path + label", function()
    local tree = fakeTree()
    local captured
    local cap = MS.buildCaptureTree(tree, function(menu_path, label)
        captured = { path = menu_path, label = label }
    end, {})
    -- drill: cap[1] = Settings (submenu). Submenus are lazy: resolve children
    -- via sub_item_table_func() on drill-in.
    local settings = cap[1]
    assert(settings.sub_item_table_func, "Settings should be a (lazy) submenu")
    local network = settings.sub_item_table_func()[1]
    local proxy   = network.sub_item_table_func()[1]
    assert(proxy.callback, "proxy leaf should have a capture callback")
    proxy.callback()  -- simulate tap
    eq("label", captured.label, "HTTP proxy")
    eq("p1", captured.path[1].id, "setting")
    eq("p2", captured.path[2].id, "network")
    eq("p3", captured.path[3].id, "network_proxy")
end)

test("buildCaptureTree: id-less leaf records text segment; separators dropped", function()
    local tree = fakeTree()
    local captured
    local cap = MS.buildCaptureTree(tree, function(mp, l) captured = mp end, {})
    -- separator row (no id/callback/sub) is not included
    eq("no separator row", #cap, 1)
    -- Settings > Plugin X > Do the thing (lazy submenus)
    local thing = cap[1].sub_item_table_func()[2].sub_item_table_func()[1]
    thing.callback()
    eq("leaf text seg", captured[3].text, "Do the thing")
    eq("leaf no id", captured[3].id, nil)
end)

-- MenuSorter-shaped tree: a node IS an array of its children, carrying
-- id/text/icon as hash fields. Top-level tabs are icon-only (blank text).
local function fakeSorterTree()
    local network = { id = "network", text = "Network",
        { id = "network_proxy", text = "HTTP proxy", callback = function() end },
    }
    -- "setting" tab: array of children + id + icon, NO .text, NO .sub_item_table
    local setting = { id = "setting", icon = "x", network }
    return { setting }
end

test("_childrenOf treats a node's array part as its children", function()
    local n = { id = "setting", icon = "x", { id = "a" }, { id = "b" } }
    local kids = MS._childrenOf(n)
    eq("array is children", #kids, 2)
    eq("first child", kids[1].id, "a")
    eq("leaf has no children", MS._childrenOf({ text = "x", callback = function() end }), nil)
end)

test("_displayLabel: text, else humanised id, else placeholder", function()
    eq("text wins", MS._displayLabel({ text = "Network", id = "network" }), "Network")
    eq("humanise id", MS._displayLabel({ id = "network_proxy" }), "Network proxy")
    eq("placeholder", MS._displayLabel({}), "(unnamed)")
end)

test("capture + walk through an icon-only tab (array node, blank text)", function()
    local tree = fakeSorterTree()
    -- the blank-text tab still renders (humanised id) and drills in
    local captured
    local cap = MS.buildCaptureTree(tree, function(mp, l) captured = { path = mp, label = l } end, {})
    eq("tab row shown", cap[1].text, "Setting")             -- humanised id, not blank
    assert(cap[1].sub_item_table_func, "tab should be a (lazy) submenu")
    -- Setting > Network > HTTP proxy (resolve lazily on drill)
    local proxy = cap[1].sub_item_table_func()[1].sub_item_table_func()[1]
    proxy.callback()
    eq("captured label", captured.label, "HTTP proxy")
    eq("seg1", captured.path[1].id, "setting")
    eq("seg2", captured.path[2].id, "network")
    eq("seg3", captured.path[3].id, "network_proxy")
    -- and the captured path walks back to the leaf against a fresh tree
    local leaf = MS.walk(fakeSorterTree(), captured.path)
    eq("walk resolves", MS._label(leaf), "HTTP proxy")
end)

test("buildCaptureTree flags a toggle leaf (has checked_func)", function()
    local items = {
        { id = "wifi",  text = "Wi-Fi", checked_func = function() return true end, callback = function() end },
        { id = "plain", text = "Plain", callback = function() end },
    }
    local seen
    local cap = MS.buildCaptureTree(items, function(_p, _l, is_toggle) seen = is_toggle end, {})
    cap[1].callback(); eq("wifi is toggle", seen, true)
    cap[2].callback(); eq("plain not toggle", seen, false)
end)

test("walk reaches a toggle leaf whose checked_func reads live state", function()
    local state = false
    local tree = {
        { id = "setting", icon = "x",
          { id = "wifi", text = "Wi-Fi", checked_func = function() return state end, callback = function() end } },
    }
    local leaf = MS.walk(tree, { { id = "setting" }, { id = "wifi" } })
    assert(leaf and type(leaf.checked_func) == "function", "leaf carries checked_func")
    eq("off", leaf.checked_func(), false)
    state = true
    eq("live on", leaf.checked_func(), true)  -- re-read each call
end)

test("isAvailable: resolves a callable leaf in the current menu (#211)", function()
    local orig = MS.buildMenuTree
    MS.buildMenuTree = function() return fakeTree() end
    eq("present", MS.isAvailable({ {id="setting"}, {id="network"}, {id="network_wifi"} }), true)
    eq("absent",  MS.isAvailable({ {id="setting"}, {id="nope"} }), false)
    -- a submenu node (no callback) is not "available" as a shortcut
    eq("submenu not callable", MS.isAvailable({ {id="setting"}, {id="network"} }), false)
    MS.buildMenuTree = orig
end)

test("isAvailable: fail-open when the tree can't be built / bad path", function()
    local orig = MS.buildMenuTree
    MS.buildMenuTree = function() return nil end
    eq("no tree -> show", MS.isAvailable({ {id="setting"} }), true)
    MS.buildMenuTree = orig
    eq("non-table path -> show", MS.isAvailable("nope"), true)
end)

io.write(("menu_shortcut: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
