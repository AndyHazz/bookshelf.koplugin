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

local function open(o)
    o = o or {}
    local shown, closed, toasts, calls = nil, 0, {}, {}
    local flags = { use_cover = o.use_cover or false, use_description = false }
    local HC = {
        getLink = function() return o.link end,
        linkLabel = function() return o.link and "Dune (1965)" end,
        getEmbeddedIdentifiers = function() return o.has_id and {} or nil end,
        getEnrichmentFlags = function() return flags end,
        hasCover = function() return o.has_cover or false end,
        setUseCover = function(_fp, v) flags.use_cover = v; calls[#calls + 1] = "cover=" .. tostring(v); return true end,
        setUseDescription = function(_fp, v) flags.use_description = v; calls[#calls + 1] = "desc=" .. tostring(v) end,
        clearLink = function() calls[#calls + 1] = "clear"; return true end,
    }
    local dialog = { refresh = function(self) self.refreshed = (self.refreshed or 0) + 1 end }
    local env = setmetatable({
        BookshelfWidget = {},
        _ = function(s) return s end,
        T = function(s, a) return (s:gsub("%%1", tostring(a))) end,
        UIManager = { close = function() closed = closed + 1 end, nextTick = function(_s, f) f() end,
                      setDirty = function() end, show = function() end },
        require = function(name)
            if name == "lib/bookshelf_hardcover" then return HC end
            if name == "lib/bookshelf_page_dialog" then
                return { show = function(spec) shown = spec; return dialog end }
            end
            if name == "ui/widget/buttondialog" then error("still a ButtonDialog") end
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
    eq(spec.title, "Hardcover")
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

t.test("the X goes back to the book popup's Edit tab", function()
    local spec, _d, calls = open()
    spec.on_close()
    eq(calls[#calls], "book:edit")
end)

t.done()
