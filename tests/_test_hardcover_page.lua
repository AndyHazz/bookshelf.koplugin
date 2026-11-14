-- tests/_test_hardcover_page.lua
-- Book popup > Edit > Hardcover is a PageDialog (STYLE.md), not a stock
-- ButtonDialog: the link in a summary rather than a greyed button used as a
-- label, the per-book overrides as On | Off, the link actions as chips, and
-- the X back to the book popup instead of a Done row (maintainer, UI branch).
--
-- Usage (from plugin root): lua tests/_test_hardcover_page.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\n(function BookshelfWidget:_openHardcoverMenu%(.-\nend)\n")
assert(body, "_openHardcoverMenu moved")

-- state: what the stubbed Hardcover module was asked, and the page as it
-- read at that moment (to see "Linking..." while the work runs).
local state
local function open(o)
    o = o or {}
    local shown, closed, toasts, calls = nil, 0, {}, {}
    state = { closed = function() return closed end, toasts = toasts }
    local function summary() return shown and shown.page().strip[1].text end
    local flags = { use_cover = o.use_cover or false, use_description = false }
    local HC = {
        getLink = function() return o.link end,
        linkLabel = function() return o.link and "Dune (1965)" end,
        getEmbeddedIdentifiers = function() return o.has_id and {} or nil end,
        getEnrichmentFlags = function() return flags end,
        hasCover = function() return o.has_cover or false end,
        setUseCover = function(_fp, v) flags.use_cover = v; calls[#calls + 1] = "cover=" .. tostring(v); return true end,
        setUseDescription = function(_fp, v) flags.use_description = v; calls[#calls + 1] = "desc=" .. tostring(v) end,
        clearLink = function() calls[#calls + 1] = "clear"; o.link = nil; return true end,
        linkFromEmbeddedIdentifiers = function()
            state.during = summary()
            o.link = { book_id = 9 }
            return true
        end,
        bestGuessLink = function()
            state.during = summary()
            o.link = { book_id = 9 }
            return true, {}
        end,
        refreshBookOnline = function(_b, _o, cb) cb(true) end,
        -- Online unless the test says the reader turned Wi-Fi down.
        isAvailable = function() return not o.not_connected end,
        whenOnline = function(fn)
            state.asked_online = (state.asked_online or 0) + 1
            if not o.offline then fn() end
            return true
        end,
        showBookPicker = function(_b, popts) state.book_picker = popts; return true end,
        showEditionPicker = function(_b, id, popts) state.edition_picker = popts; state.edition_of = id; return true end,
    }
    local dialog = {
        refresh = function(self) self.refreshed = (self.refreshed or 0) + 1 end,
        over = function(self, tail) return { crumbs = tail, from = self } end,
    }
    local Icons = dofile("lib/bookshelf_menu_icons.lua")
    state.icons = Icons
    local env = setmetatable({
        BookshelfWidget = {},
        _ = function(s) return s end,
        T = function(s, a) return (s:gsub("%%1", tostring(a))) end,
        UIManager = { close = function() closed = closed + 1 end, nextTick = function(_s, f) f() end,
                      setDirty = function() end, show = function() end,
                      forceRePaint = function() state.repaints = (state.repaints or 0) + 1 end,
                      isWidgetShown = function() return true end },
        require = function(name)
            if name == "lib/bookshelf_hardcover" then return HC end
            if name == "lib/bookshelf_page_dialog" then
                return { show = function(spec) shown = spec; return dialog end }
            end
            if name == "ui/widget/buttondialog" then error("still a ButtonDialog") end
            if name == "lib/bookshelf_hardcover_key_ui" then
                return { open = function(ko) state.key_dialog = ko end }
            end
            return require(name)
        end,
    }, { __index = _G })
    assert(load(body, "hc", "t", env))()
    local bw = setmetatable({
        _hardcoverToast = function(_s, m) toasts[#toasts + 1] = m end,
        _refreshHardcoverEnrichmentView = function() end,
        _showBookDetail = function(_s, _b, opts) calls[#calls + 1] = "book:" .. tostring(opts and opts.active) end,
    }, { __index = env.BookshelfWidget })
    bw:_openHardcoverMenu({ filepath = "/b/dune.epub" })
    return shown, dialog, calls
end

local function find(model, pred)
    for _i, b in ipairs(model.blocks) do if pred(b) then return b end end
end
local function chipTexts(model)
    local out = {}
    for _i, b in ipairs(model.blocks) do
        if b.type == "chips" then
            for _j, it in ipairs(b.items) do out[#out + 1] = it.text end
        end
    end
    return table.concat(out, " | ")
end

t.test("a page with the X, no Done row", function()
    local spec = open()
    -- The chain link, woven into the menu (maintainer).
    eq(spec.title, state.icons.HARDCOVER .. " Hardcover")
    eq(spec.footer, nil)
end)

t.test("not linked: says so, offers the ways to link and nothing else", function()
    local spec = open()
    local m = spec.page()
    eq(m.strip[1].type, "summary")
    eq(m.strip[1].text, "Not linked to Hardcover.")
    eq(chipTexts(m), "Auto link (best guess) | Manual link\xE2\x80\xA6")
    eq(find(m, function(b) return b.type == "segmented" end), nil)
end)

t.test("linked: the link in words, the overrides as On | Off, edition and clear offered", function()
    local spec = open({ link = { book_id = 7 }, has_id = true, has_cover = true })
    local m = spec.page()
    eq(m.strip[1].text, "Linked to Dune (1965).")
    eq(chipTexts(m), "Auto link | Manual link\xE2\x80\xA6 | Select edition\xE2\x80\xA6 | Clear link")
    local cover = find(m, function(b) return b.type == "segmented" and b.label == "Cover" end)
    assert(cover, "no Cover switch")
    eq(cover.active, "off")
    assert(find(m, function(b) return b.type == "segmented" and b.label == "Description" end), "no Description switch")
end)

t.test("no Hardcover cover downloaded: a hint, not a dead switch", function()
    local m = open({ link = { book_id = 7 } }).page()
    eq(find(m, function(b) return b.type == "segmented" and b.label == "Cover" end), nil)
    assert(find(m, function(b) return b.type == "hint" end), "no hint for the missing cover")
end)

t.test("a switch saves and redraws the page in place", function()
    local spec, dialog, calls = open({ link = { book_id = 7 }, has_cover = true })
    local cover = find(spec.page(), function(b) return b.type == "segmented" and b.label == "Cover" end)
    cover.on_pick("on")
    eq(calls[1], "cover=true")
    eq(dialog.refreshed, 1)
    eq(find(spec.page(), function(b) return b.type == "segmented" and b.label == "Cover" end).active, "on")
end)

-- "When tapping auto link, manual link or select edition, it closes the modal
-- and there's a pause before anything happens. Perhaps we should use the
-- pattern developed for the shelf edit menu, where it all happens in one
-- modal with a breadcrumb?" (maintainer, PW5)
local function chip(model, text)
    for _i, b in ipairs(model.blocks) do
        if b.type == "chips" then
            for _j, it in ipairs(b.items) do if it.text == text then return it end end
        end
    end
end

t.test("Manual link opens the list as a page of this menu, which stays open", function()
    local spec, dialog = open({ link = { book_id = 7 } })
    chip(spec.page(), "Manual link\xE2\x80\xA6").callback()
    eq(state.closed(), 0, "the menu was closed")
    local p = state.book_picker
    assert(p, "no list opened")
    eq(p.over.from, dialog); eq(p.over.crumbs[1], "Manual link")
end)

t.test("Select edition: the same, for the linked book", function()
    local spec, dialog = open({ link = { book_id = 7 } })
    chip(spec.page(), "Select edition\xE2\x80\xA6").callback()
    eq(state.closed(), 0)
    eq(state.edition_of, 7)
    eq(state.edition_picker.over.from, dialog); eq(state.edition_picker.over.crumbs[1], "Select edition")
end)

t.test("a pick says Linking on this menu, then shows the new link", function()
    local spec, dialog = open({ link = { book_id = 7 } })
    chip(spec.page(), "Manual link\xE2\x80\xA6").callback()
    local before = dialog.refreshed or 0
    state.book_picker.on_start({ book_id = 5 })
    eq(spec.page().strip[1].text, "Linking to Hardcover\xE2\x80\xA6")
    assert((state.repaints or 0) > 0, "the line was not painted before the work")
    state.book_picker.on_book_selected({ book_id = 5 }, true)
    state.book_picker.on_close()
    eq(spec.page().strip[1].text, "Linked to Dune (1965).")
    assert(dialog.refreshed > before, "the menu was not redrawn")
end)

t.test("Auto link works in place: Linking while it runs, then the link", function()
    local spec, dialog = open({ has_id = true })
    chip(spec.page(), "Auto link").callback()
    eq(state.closed(), 0, "the menu was closed")
    eq(state.during, "Linking to Hardcover\xE2\x80\xA6")
    eq(spec.page().strip[1].text, "Linked to Dune (1965).")
    assert(chip(spec.page(), "Clear link"), "the page did not change to a linked one")
end)

t.test("Clear link works in place", function()
    local spec = open({ link = { book_id = 7 } })
    chip(spec.page(), "Clear link").callback()
    eq(state.closed(), 0)
    eq(spec.page().strip[1].text, "Not linked to Hardcover.")
end)

-- "We should also check for network connection, offer to connect if not
-- connected, for any hardcover action that requires network" (maintainer).
t.test("offline and Wi-Fi declined: each Hardcover action asks first and does nothing", function()
    for _i, label in ipairs({ "Auto link", "Manual link\xE2\x80\xA6", "Select edition\xE2\x80\xA6" }) do
        local spec = open({ link = { book_id = 7 }, has_id = true, offline = true })
        chip(spec.page(), label).callback()
        eq(state.asked_online, 1, label .. " did not ask for a connection")
        eq(state.book_picker, nil); eq(state.edition_picker, nil)
        eq(state.during, nil, label .. " went ahead offline")
        eq(spec.page().strip[1].text, "Linked to Dune (1965).")
    end
    -- Clear link needs no network, and does not ask.
    local spec = open({ link = { book_id = 7 }, offline = true })
    chip(spec.page(), "Clear link").callback()
    eq(state.asked_online, nil)
end)

-- "now we'd always have all this available, and if no connection available
-- show a help message about what it is and how to connect" (maintainer).
t.test("not connected: what Hardcover is and how to connect, and the key, not the link actions", function()
    local spec, dialog = open({ not_connected = true })
    local m = spec.page()
    eq(m.strip[1].text, "Not connected to Hardcover.")
    local hint = find(m, function(b) return b.type == "hint" end)
    assert(hint and hint.text:find("hardcover.app", 1, true), "no word on what Hardcover is")
    assert(hint.text:find("API key", 1, true) and hint.text:find("sync plugin", 1, true), "no word on how to connect")
    eq(chipTexts(m), "Hardcover API key\xE2\x80\xA6")
    chip(m, "Hardcover API key\xE2\x80\xA6").callback()
    assert(state.key_dialog and state.key_dialog.on_change, "the key dialog was not opened")
end)

t.test("a key given from there: the same menu, now with the ways to link", function()
    local o = { not_connected = true }
    local spec, dialog = open(o)
    chip(spec.page(), "Hardcover API key\xE2\x80\xA6").callback()
    o.not_connected = false
    local before = dialog.refreshed or 0
    state.key_dialog.on_change()
    assert((dialog.refreshed or 0) > before, "the menu was not redrawn")
    eq(chipTexts(spec.page()), "Auto link (best guess) | Manual link\xE2\x80\xA6")
end)

t.test("the link actions wear icons: the link, a search, editions, the link crossed out", function()
    local spec = open({ link = { book_id = 7 }, has_id = true })
    local m = spec.page()
    eq(chip(m, "Auto link").icon, state.icons.HARDCOVER)
    eq(chip(m, "Manual link\xE2\x80\xA6").icon, "\xEE\xA9\x88")        -- magnify
    eq(chip(m, "Select edition\xE2\x80\xA6").icon, "\xEE\x9E\xBA")     -- book-multiple
    eq(chip(m, "Clear link").icon, state.icons.HARDCOVER_OFF)
    local k = chip(open({ not_connected = true }).page(), "Hardcover API key\xE2\x80\xA6")
    eq(k.icon, "\xEE\xA8\x8A")                                          -- key-variant
end)

t.test("the X goes back to the book popup's Edit tab", function()
    local spec, _d, calls = open()
    spec.on_close()
    eq(calls[#calls], "book:edit")
end)

t.done()
