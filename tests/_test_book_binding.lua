package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local F = dofile("tests/_binding_fixture.lua")
local M = require("lib/bookshelf_book_binding")
local Tabs = require("lib/bookshelf_tab_model")
local Shelf = F.configure(require("lib/bookshelf_spine_shelf"))
local Top = F.upvalue(Shelf.rowWidget, "FaceOutTopBlock")

t.test("untouched shelves stay Hardcover, without writes or migration", function()
    eq(M.resolve({}, {}, {}), "hardcover")
    eq(M.applyOptions({}, "all").book_binding, "hardcover")
    eq(next(F.settings), nil); eq(F.flushes, 0)
end)

t.test("shelf choices survive reloads and stay independent, including sub-shelves", function()
    Tabs.save({{id="plain"}, {id="soft", book_binding="paperback"},
        {id="child", parent="soft"}, {id="pinned", source={kind="single_series", id="Saga"}}})
    package.loaded["lib/bookshelf_book_binding"] = nil
    M = require("lib/bookshelf_book_binding")
    eq(M.applyOptions({}, "plain").book_binding, "hardcover")
    eq(M.applyOptions({}, "soft").book_binding, "paperback")
    eq(M.applyOptions({}, "child").book_binding, "hardcover")
    eq(M.applyOptions({}, "missing").book_binding, "hardcover")
end)

t.test("series overrides win on every shelf; Follow shelf removes only that choice", function()
    assert(M.setSeries("Saga", "hardcover")); assert(M.setSeries("Other", "paperback"))
    local book = {series_name="Saga", filepath="one.cbz", cover_bb="borrowed"}
    eq(M.resolve(book, book, M.applyOptions({}, "soft")), "hardcover")
    eq(M.resolve(book, book, M.applyOptions({}, "plain")), "hardcover")
    assert(M.setSeries("Saga", nil))
    eq(M.resolve(book, book, M.applyOptions({}, "soft")), "paperback")
    eq(M.series("Other"), "paperback")
    eq(book.binding, nil); eq(book.cover_bb, "borrowed")
end)

t.test("invalid values fall back without rewriting or dropping unrelated preferences", function()
    F.settings.series_bindings.Bad = "future"
    local old, count = F.settings.series_bindings, F.flushes
    eq(M.setSeries("", "paperback"), false)
    eq(M.setSeries("Saga", "invalid"), false)
    eq(F.flushes, count)
    eq(M.resolve({}, {}, {book_binding="invalid"}), "hardcover")
    M.setSeries("Saga", "paperback")
    eq(old.Saga, nil); eq(F.settings.series_bindings.Bad, "future")
    eq(M.applyOptions({}, "plain").series_bindings.Bad, nil)
end)

t.test("drilled and pinned series supply identity for light members, not author drills", function()
    eq(M.resolve({}, {}, M.applyOptions({}, "plain", {
        {kind="series", label="display", payload={series_name="Saga"}}})), "paperback")
    eq(M.resolve({}, {}, M.applyOptions({}, "pinned")), "paperback")
    eq(M.resolve({}, {}, M.applyOptions({}, "plain", {{kind="author", label="Saga"}})), "hardcover")
    eq(M.resolve({}, {series_name="Saga"}, M.applyOptions({}, "plain")), "paperback")
end)

-- The stack long-press menu is a PageDialog (STYLE.md): Book binding is a
-- segmented control on its page, saved and redrawn in place.
local function groupMenu(mode, kind)
    local src = F.source("lib/bookshelf_widget.lua")
    local state = {shown=0, closed=0, rebuilds=0, refreshes=0, dirty={}}
    local mocks = {
        ["lib/bookshelf_page_dialog"] = {show=function(spec)
            state.spec = spec; state.shown = state.shown + 1
            state.dialog = {refresh=function() state.refreshes = state.refreshes + 1 end}
            return state.dialog
        end},
        ["ui/widget/buttondialog"] = {new=function() error("still a ButtonDialog") end},
        ["lib/bookshelf_image_source"] = {
            getStackImageOverride=function() end, resolveStackImage=function() end,
            getFolderImageOverride=function() end, resolveFolderImage=function() end,
        },
        ["lib/bookshelf_author_images"] = {isPlaceholder=function() return true end},
    }
    local env = {
        require=function(name) return mocks[name] or require(name) end,
        _=function(s) return s end, T=function(s,a,b) return (s:gsub("%%1",tostring(a)):gsub("%%2",tostring(b))) end,
        GROUP_KINDS={series={source_id_field="series_name"}, author={source_id_field="series_name"},
            folder={source_id_field="path"}},
        ViewMode=require("lib/bookshelf_view_mode"), Focus=require("lib/bookshelf_focus"),
        BFont={getFace=function() return {} end},
        UIManager={
            show=function() end,
            close=function() state.closed=state.closed+1 end,
            setDirty=function(_, w, refresh)
                eq(refresh,"ui"); state.dirty[w]=(state.dirty[w] or 0)+1
            end,
        },
    }
    local function method(name, args)
        local body = assert(src:match("function BookshelfWidget:"..name.."%([^\n]*%)\n(.-)\nend"))
        return F.compile("return function(self"..args..")\n"..body.."\nend",env)()
    end
    local w = {
        _selection={stackState=function() return "none" end, contains=function() return false end},
        _resolveStackPaths=function() return {} end,
        _viewMode=function() return mode end, _isSpineMode=method("_isSpineMode", ""),
        _rebuild=function() state.rebuilds=state.rebuilds+1; Shelf.dropPlanCache() end,
    }
    method("_openGroupMenu", ", group, kind")(w, {series_name="Saga",path="/library"}, kind)
    state.widget = w
    state.binding = function()
        for _, b in ipairs(state.spec.page().blocks) do
            if b.type == "segmented" and b.label == "Book binding" then return b end
        end
    end
    return state
end

t.test("series binding is a choice on the menu's page, saved and redrawn in place", function()
    M.setSeries("Saga",nil)
    local flushes, other = F.flushes, M.series("Other")
    local state = groupMenu("spines", "series")
    local seg = assert(state.binding(), "no Book binding on the page")
    eq(seg.active, "follow")
    local keys = {}
    for i, it in ipairs(seg.items) do keys[i] = it.key .. "=" .. it.label end
    eq(table.concat(keys, " "), "follow=Same as shelf hardcover=Hardback paperback=Paperback")
    local picks = {"hardcover","paperback","follow","paperback"}
    for i, key in ipairs(picks) do
        state.binding().on_pick(key)
        eq(M.series("Saga"), key ~= "follow" and key or nil)
        eq(state.binding().active, key)
        eq(F.flushes, flushes+i)
        eq(state.rebuilds,i); eq(state.refreshes,i); eq(state.dirty[state.widget],i)
    end
    -- The one picked again: nothing to save.
    state.binding().on_pick("paperback")
    eq(F.flushes, flushes+#picks); eq(state.rebuilds, #picks)
    eq(state.shown,1); eq(state.closed,0)
    eq(M.series("Other"),other)
    local reopened=groupMenu("spines","series")
    eq(reopened.binding().active,"paperback")
    reopened.binding().on_pick("follow"); eq(M.series("Saga"),nil)
end)

t.test("series binding is absent in covers/list views and on non-series groups", function()
    local flushes=F.flushes
    for _,mode in ipairs({"covers","list","spines"}) do
        for _,kind in ipairs({"series","author","folder"}) do
            local state=groupMenu(mode,kind)
            eq(state.binding()~=nil,mode=="spines" and kind=="series")
            eq(state.rebuilds,0); eq(state.closed,0)
        end
    end
    eq(F.flushes,flushes)
end)

t.test("warm planning caches follow shelf and series changes without changing geometry", function()
    local books={{filepath="one.cbz",title="One",has_cover=false,series_name="Saga",page_count=200}}
    local opts={content_w=800,row_h=300,n_rows=2,face_out="all"}
    local hard=Shelf.plan(books,opts).entries[1]
    opts.book_binding="paperback"
    local soft=Shelf.plan(books,opts).entries[1]
    eq(soft.binding,"paperback"); eq(hard.binding,"hardcover")
    for _,k in ipairs({"w","h","depth","face_h","thick"}) do eq(soft[k],hard[k],k) end
    opts.series_bindings={Saga="hardcover"}
    eq(Shelf.plan(books,opts).entries[1].binding,"hardcover")
    opts.series_bindings.Saga="paperback"
    eq(Shelf.plan(books,opts).entries[1].binding,"paperback")
    eq(books[1].binding,nil)
end)

local function render(shelf, style, title)
    local slot=F.slot(shelf,style,title)
    local bb=F.surface(slot.width,slot.height)
    slot:_renderInto(bb,F.night)
    return bb
end

t.test("nil and explicit Hardcover paint identically; render keys distinguish Paperback", function()
    eq(render(Shelf,nil).rects,render(Shelf,"hardcover").rects)
    local a,b=F.slot(Shelf,"hardcover"),F.slot(Shelf,"paperback")
    assert(a:_renderKey(false)~=b:_renderKey(false))
end)

t.test("paperbacks have flush thin covers and softer page lines at multiple DPI", function()
    for _,dpi in ipairs({1,1.5,2,3}) do
        F.dpi=dpi
        for _,night in ipairs({false,true}) do
            F.night=night
            for _,style in ipairs({"hardcover","paperback"}) do
                local bb=render(Shelf,style)
                local flush=false
                for _,r in ipairs(bb.rects) do if r.y==0 and r.w>5*dpi then flush=true end end
                eq(flush,style=="paperback")
                local top=Top:new{dimen={w=120*dpi,h=8*dpi},look=F.look,binding=style}
                top:paintTo(F.surface(top.dimen.w,top.dimen.h),0,0)
            end
        end
    end
    F.dpi,F.night=1,false
    eq(F.look.binding_skin,nil)
end)

t.test("rotated titles use the paperback background, not a hardback-coloured stripe", function()
    local count=F.text_paints
    local bb=render(Shelf,"paperback","A modern book")
    assert(F.text_paints>count and #bb.blits>0,"title paint was swallowed")
    local band=bb.blits[1].src.original
    assert(band and #band.rects>0,"rotated title background missing")
    for _,r in ipairs(band.rects) do
        assert(r.c.r>=F.look.r*.85 and r.c.g>=F.look.g*.85, "hardcover ramp leaked into title")
    end
    eq(F.look.binding_skin,nil)
end)

t.test("box member slots inherit the series style without touching shared book records", function()
    local Cover=F.Widget:extend{CARD_BORDER=1}
    package.loaded["lib/bookshelf_spine_widget"]=Cover
    package.loaded["lib/bookshelf_image_source"]={resolveStackImage=function() end}
    local Boxes=require("lib/bookshelf_series_boxes")
    local Box=require("lib/bookshelf_series_box_widget")
    for _,style in ipairs({"hardcover","paperback"}) do
        for _,n in ipairs({2,8,30}) do
            local members={}
            for i=1,n do members[i]={filepath="m"..i..".cbz",has_cover=true,series_name="Saga",series_num=i} end
            local book=Boxes.box(members,"Saga")
            local shape=Boxes.geometry(book,{w=160,h=248,aspect=1.5},{row_h=300,content_w=800})
            local box=Box:new{entry={book=book,series_box=shape,binding=style},width=shape.w,height=300}
            assert(#box.slots>0)
            for _,s in ipairs(box.slots) do eq(s.slot.entry.binding,style) end
            for _,m in ipairs(members) do eq(m.binding,nil) end
        end
    end
end)

-- Optional before/after audit against the unmodified upstream painter.
local baseline=os.getenv("BOOKSHELF_BINDING_BASELINE")
if baseline then
    t.test("unmodified upstream and Hardcover issue identical paint operations", function()
        local old=F.configure(dofile(baseline))
        local old_top=F.upvalue(old.rowWidget,"FaceOutTopBlock")
        for _,dpi in ipairs({1,2}) do
            F.dpi=dpi
            for _,night in ipairs({false,true}) do
                F.night=night
                eq(render(old,nil).rects,render(Shelf,"hardcover").rects)
                local a,b=F.surface(120*dpi,8*dpi),F.surface(120*dpi,8*dpi)
                old_top:new{dimen={w=a.w,h=a.h},look=F.look}:paintTo(a,0,0)
                Top:new{dimen={w=b.w,h=b.h},look=F.look,binding="hardcover"}:paintTo(b,0,0)
                eq(a.rects,b.rects)
            end
        end
        F.dpi,F.night=1,false
    end)
end
t.done()
