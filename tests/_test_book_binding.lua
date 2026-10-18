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

t.test("series picker saves, rebuilds immediately, and can return to Follow shelf", function()
    local src = F.source("lib/bookshelf_widget.lua")
    local body = assert(src:match("function BookshelfWidget:_pickSeriesBinding%(name%)\n(.-)\nend"))
    local menu, closed, rebuilds, dirty = nil, 0, 0, 0
    local host = { show=function(opts) menu=opts; return opts end,
        close=function(w) eq(w,menu); closed=closed+1 end }
    local fn = F.compile("return function(self, name)\n"..body.."\nend", {
        require=function(name) if name=="lib/bookshelf_menu_host" then return host end; return require(name) end,
        _=function(s) return s end, UIManager={setDirty=function() dirty=dirty+1 end},
    })()
    local w={_rebuild=function() rebuilds=rebuilds+1; Shelf.dropPlanCache() end}
    fn(w,"Saga"); eq(#menu.item_table,3); eq(menu.item_table[3].checked_func(),true)
    menu.item_table[2].callback(); eq(M.series("Saga"),"hardcover")
    fn(w,"Saga"); menu.item_table[1].callback(); eq(M.series("Saga"),nil)
    eq(closed,2); eq(rebuilds,2); eq(dirty,2)
end)

t.test("shelf style toggles only its own presentation pin and applies each pick", function()
    local src=F.source("lib/bookshelf_chip_editor.lua")
    local block=assert(src:match('if show_spines then\n(.-)\n            rows%[#rows %+ 1%] = {{\n                text_func = function%(%)\n                    return T%(_%("Series boxes:'))
    local draft, applied={id="soft"},0
    local row=F.compile("local rows={}\n"..block.."\nreturn rows[1][1]", {
        draft=draft, _=function(s) return s end, T=function(s,v) return s:gsub("%%1",v) end,
        pick=function(fn) return function() fn(); applied=applied+1 end end,
    })()
    eq(row.text_func(),"Book binding: Hardback")
    row.callback(); eq(draft.book_binding,"paperback")
    row.callback(); eq(draft.book_binding,nil); eq(applied,2)
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
