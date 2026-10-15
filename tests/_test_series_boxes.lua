package.path = "./?.lua;" .. package.path
local runner = dofile("tests/_helpers.lua").runner()
local H = { test = runner.test, finish = runner.done }
function H.eq(a, b, message)
    assert(a == b, (message or "Mismatch") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end
function H.widget()
    local W = {}
    function W:extend(o) self.__index = self; return setmetatable(o or {}, self) end
    function W:new(o)
        o = self:extend(o)
        if o.init then o:init() end
        return o
    end
    return W
end
local Boxes = require("lib/bookshelf_series_boxes")
local settings={}
package.loaded["lib/bookshelf_settings_store"] = {
    read=function(k) return settings[k] end, isTrue=function(k) return settings[k]==true end,
    generation=function() return 0 end,
}
package.loaded["lib/bookshelf_i18n"] = {gettext=function(s) return s end}

local function source(file)
    local f = assert(io.open("lib/" .. file .. ".lua"))
    local text = f:read("*a"); f:close(); return text
end
local function compile(code, env)
    setmetatable(env, {__index=_G})
    if setfenv then local f=assert(loadstring(code)); setfenv(f, env); return f end
    return assert(load(code, "series boxes", "t", env))
end
local shelf_source = source("bookshelf_spine_shelf")
local flat_body = assert(shelf_source:match("function SpineShelf%._flattenItems%(items%)\n(.-)\nend"))
local native_flatten = compile("return function(items)\n" .. flat_body .. "\nend", {})()
local function book(n, series, dir)
    return {filepath=(dir or "/books") .. "/" .. tostring(n) .. ".epub", filename=tostring(n)..".epub",
        title="Book "..n, series_name=series, series_num=tostring(n), author="Vilhelm Moberg",
        has_cover=true, shelf_section_path=dir}
end
local function members(n, name, dir)
    local out={}; for i=1,n do out[i]=book(i,name,dir) end; return out
end

H.test("loose metadata series become one box in place without changing source records", function()
    local a, b = book(4,"Utvandrarna"), book(1,"Utvandrarna")
    a.cover_bb = "borrowed"
    local single = book(0)
    local raw={single,a,b}
    local out=Boxes.prepare(raw)
    H.eq(#out,2); H.eq(out[1],single)
    local box=out[2]
    assert(Boxes.isBox(box)); H.eq(#box.books,2); H.eq(box.first_book.filepath,b.filepath)
    H.eq(box.books[2].filepath,a.filepath); H.eq(box.books[2].cover_bb,nil)
    H.eq(box.filepath,nil); H.eq(box.series_num,nil); H.eq(box.title,"Utvandrarna")
    H.eq(#raw,3); H.eq(raw[2],a); H.eq(a.cover_bb,"borrowed"); H.eq(a._series_box,nil)
end)

H.test("grouped series preserve all volumes, remove duplicates and use numeric order", function()
    local raw={series_name="Saga", books={book(10,"Saga"),book(2,"Saga"),book(2,"Saga"),book(1,"Saga")}}
    local box=Boxes.prepare({raw})[1]
    H.eq(#box.books,3); H.eq(box.first_book.series_num,"1")
    H.eq(box.books[2].series_num,"2"); H.eq(box.books[3].series_num,"10")
    H.eq(#raw.books,4); H.eq(raw.books[1].series_num,"10")
    H.eq(Boxes.prepare({box})[1],box)
end)

H.test("metadata-free folders, distinct sections and standalone books are not merged", function()
    local a,b=book(1),book(2)
    a.shelf_section,b.shelf_section="Fiction","Fiction"
    local one,two=book(1,"Saga","/one"),book(2,"Saga","/two")
    local out=Boxes.prepare({a,b,one,two})
    H.eq(#out,4); H.eq(out[1],a); H.eq(out[2],b)
    -- one volume per section: each stays a plain book, not a box of one
    H.eq(out[3],one); H.eq(out[4],two)
end)

H.test("a series with one volume on the shelf stays a book", function()
    local lone=book(3,"Saga")
    local out=Boxes.prepare({book(0),lone})
    H.eq(#out,2); H.eq(out[2],lone); assert(not Boxes.isBox(out[2]))
    local dup={series_name="Saga",books={lone,lone}}
    H.eq(Boxes.prepare({dup})[1],lone)
    local pair=Boxes.prepare({{series_name="Saga",books={book(1,"Saga"),book(2,"Saga")}}})[1]
    assert(Boxes.isBox(pair))
end)

H.test("author shelves retain raw membership and compact only their display list", function()
    local raw={kind="author",series_name="Moberg",books={book(0),book(1,"Saga"),book(2,"Saga")}}
    local group=Boxes.prepare({raw})[1]
    H.eq(group.books,raw.books); H.eq(#group.books,3)
    H.eq(#group._series_display_books,2)
    local flat=native_flatten({group})
    H.eq(#flat,2); H.eq(flat[1].book,raw.books[1]); H.eq(flat[2].item,group)
    assert(Boxes.isBox(flat[2].book)); H.eq(flat[2].section_label,nil)
    H.eq(Boxes.displayCount(group),2)
    H.eq(#native_flatten({raw}),3) -- standalone component remains native
end)

H.test("boxes flatten to a single drillable item with unchanged item indices", function()
    local items=Boxes.prepare({{series_name="Saga",books=members(80,"Saga")},book(0)})
    local flat=native_flatten(items)
    H.eq(#flat,2); H.eq(flat[1].book,items[1]); H.eq(flat[1].item_idx,1)
    H.eq(flat[2].item_idx,2); H.eq(flat[1].section_label,nil)
    H.eq(#flat[1].book.books,80); H.eq(Boxes.displayCount(items[1]),1)
end)

-- ── The slipcase: geometry, widget, row ───────────────────────────────────
-- Stubs for what the box reaches for. The spine layout is the real one (pure
-- maths); the spine shelf answers only the four things a box asks of it, and
-- its spine slot records where it is painted.
package.loaded["device"]={screen={scaleBySize=function(_,n) return n end}}
package.loaded["lib/bookshelf_space"]={px=function(n) return n end,padding={default=4,small=2}}
package.loaded["ffi/blitbuffer"]={ColorRGB32=function(r,g,b,a) return {r=r,g=g,b=b,a=a} end,
    new=function(w,h) local t={w=w,h=h}
        function t:paintRectRGB32() end
        function t:paintRect() end
        function t:free() end
        return t end}
local W=H.widget()
function W:getSize() return self.dimen or {w=self.width or 0,h=self.height or 0} end
function W:paintTo(bb,x,y) bb:paintRect(x,y,self.width,self.height,"cover") end
function W:free() end
for _,name in ipairs({"ui/widget/container/inputcontainer","ui/geometry","ui/gesturerange",
        "ui/widget/horizontalgroup","ui/widget/horizontalspan","ui/widget/overlapgroup"}) do
    package.loaded[name]=W
end
-- Text a face size wide per character, so a name's width follows its size.
local Text=W:extend{}
function Text:init()
    local size=self.face.size or 12
    -- Characters, not bytes: a hairline space is three bytes.
    local w=#(self.text:gsub("[\128-\191]",""))*size
    if self.max_width and w>self.max_width then w=self.max_width; self.cut=true end
    self.dimen={w=math.max(1,w),h=size}
end
function Text:paintTo(bb,x,y) bb:paintRect(x,y,self.dimen.w,self.dimen.h,"text:"..self.text) end
package.loaded["lib/bookshelf_colour_text"]=Text
package.loaded["lib/bookshelf_fonts"]={getFace=function(_,_,size) return {size=size} end,
    getUIFontFace=function() return "cfont" end, bundledFaceId=function() return "Inter-ExtraBold.ttf" end}
package.loaded["lib/bookshelf_night_mode_sync"]={active=function() return false end}
local finished={}
package.loaded["lib/bookshelf_book_repository"]={
    readProgress=function(fp) return nil, finished[fp] and "finished" or nil end,
    buildBookMeta=function() return {} end,
}
package.loaded["lib/bookshelf_spine_widget"]=W
local painted_slots
local Slot=W:extend{}
function Slot:_renderIntoAt(bb,x,y)
    painted_slots[#painted_slots+1]={x=x,y=y,w=self.width,h=self.height}
    bb:paintRect(x,y,self.width,self.height,"spine")
end
package.loaded["lib/bookshelf_spine_shelf"]={
    titleSize=function(ref) return math.max(8,math.min(18,math.floor((ref or 22)*.5))) end,
    textHeight=function(size) return math.floor(size*1.5) end,
    cachedProgress=function() return nil end,
    bookLook=function() return {r=90,g=120,b=80,aspect=1.5} end,
    boardColor=function() return "board" end,
    _SpineBookSlot=Slot,
}
local BoxWidget=require("lib/bookshelf_series_box_widget")

-- A drawing surface that fails on any paint outside the box's rectangle.
local function surface(x0,y0,w,h)
    local bb={rects={}}
    function bb:paintRect(x,y,rw,rh,what)
        assert(x>=x0 and y>=y0 and x+rw<=x0+w and y+rh<=y0+h,
            string.format("%s painted outside the box: %d,%d %dx%d",tostring(what),x,y,rw,rh))
        self.rects[#self.rects+1]={x=x,y=y,w=rw,h=rh,what=what}
    end
    bb.paintRectRGB32=bb.paintRect
    function bb:addblitFrom(_,x,y,_,_,rw,rh) self:paintRect(x,y,rw,rh,"art") end
    function bb:getType() return 1 end
    return bb
end
local BASE={w=160,face_h=240,depth=8,h=248,ref_w_dp=22}

H.test("tap and double-tap open the series, hold uses its menu, never opens a book", function()
    local box=Boxes.box(members(4,"Saga"),"Saga")
    local shape=Boxes.geometry(box,BASE,{content_w=800})
    local taps,holds=0,0
    local w=BoxWidget:new{entry={book=box,series_box=shape},width=shape.w,height=300,
        callbacks={on_series_tap=function(g) H.eq(g,box); taps=taps+1 end,
            on_series_hold=function(g) H.eq(g,box); holds=holds+1 end,
            on_book_tap=function() error("Must not open a member book") end}}
    H.eq(w:onTap(),true); H.eq(w:onDoubleTap(),true); H.eq(w:onHold(),true)
    H.eq(taps,2); H.eq(holds,1)
end)

H.test("every box carries its read count, whether or not all its books show", function()
    local few=Boxes.box(members(3,"Saga"),"Saga")
    local w=BoxWidget:new{entry={book=few,series_box=Boxes.geometry(few,BASE,{content_w=2000})},width=200,height=300}
    H.eq(w.count.text,"0\xE2\x80\x8A/\xE2\x80\x8A3")
    local many=Boxes.box(members(12,"Saga"),"Saga")
    finished[many.books[1].filepath]=true; finished[many.books[2].filepath]=true
    w=BoxWidget:new{entry={book=many,series_box=Boxes.geometry(many,BASE,{content_w=2000})},width=400,height=300}
    H.eq(w.count.text,"2\xE2\x80\x8A/\xE2\x80\x8A12")
end)

-- ── The face-out slipcase ────────────────────────────────────────────────────
local SLIP={content_w=2000}

H.test("a slipcase takes a face-out cover's footprint, its places filling the inside", function()
    for _,n in ipairs({1,3,8}) do
        local box=Boxes.box(members(n,"Saga"),"Saga")
        local g=Boxes.geometry(box,BASE,SLIP)
        H.eq(g.style,"slipcase"); H.eq(g.h,BASE.h); H.eq(g.count,n)
        H.eq(#g.spines,n)
        local sum=0
        for i,sp in ipairs(g.spines) do H.eq(sp.member,i); H.eq(sp.x,sum); sum=sum+sp.w end
        H.eq(sum,g.w-2*g.wall,"the places do not fill the inside")
        assert(g.rise>0 and g.front_h+g.rise==g.h)
    end
end)

H.test("a slipcase is as wide as its books, up to a face-out cover", function()
    local two=Boxes.geometry(Boxes.box(members(2,"Saga"),"Saga"),BASE,SLIP)
    assert(two.w<BASE.w, "a two-book slipcase still filled a cover's width")
    local sum=0
    for _,sp in ipairs(two.spines) do sum=sum+sp.w end
    H.eq(two.w,sum+2*two.wall,"the box is not as wide as its books")
    local many=Boxes.geometry(Boxes.box(members(8,"Saga"),"Saga"),BASE,SLIP)
    assert(many.w<=BASE.w, "a slipcase ran past a cover's width")
    local more=Boxes.geometry(Boxes.box(members(20,"Saga"),"Saga"),BASE,SLIP)
    assert(more.w<=BASE.w and more.w>=two.w)
    -- Never thinner than the share of a cover, and wide enough for its name
    -- within the cover's width.
    assert(two.w>=math.floor(BASE.w*Boxes.SLIPCASE_MIN_SHARE), "a slipcase went below its minimum")
    -- A long two-word name wraps to two lines rather than widening the box
    -- to fit it on one; the box fits the longer line.
    local name="Twelvechar Lettersmore"
    local named=Boxes.geometry(Boxes.box(members(2,name),name),BASE,SLIP)
    if Boxes.SLIPCASE_NAME_FIT then
        local size=math.floor(BASE.ref_w_dp*0.5)
        assert(named.name_lines, "a name too long for one line did not wrap")
        H.eq(named.name_lines[1],"Twelvechar"); H.eq(named.name_lines[2],"Lettersmore")
        assert(named.w>=#"Lettersmore"*size, "the slipcase is narrower than its longer line")
        assert(named.w<#name*size, "the box widened for the whole name on one line")
        local one=Boxes.geometry(Boxes.box(members(2,"Saga"),"Saga"),BASE,SLIP)
        H.eq(one.name_lines,nil,"a short name wrapped")
        assert(named.strip_h>one.strip_h, "a two-line name kept a one-line strip")
    end
    local huge=("Long "):rep(20)
    H.eq(Boxes.geometry(Boxes.box(members(2,huge),huge),BASE,SLIP).w,BASE.w,"a long name widened it past a cover")
end)

H.test("a slipcase of more than eight is filled with eight; its label says how many", function()
    for k in pairs(finished) do finished[k]=nil end
    local box=Boxes.box(members(20,"Saga"),"Saga")
    local g=Boxes.geometry(box,BASE,SLIP)
    H.eq(#g.spines,Boxes.SLIPCASE_SPINES); H.eq(g.count,20)
    for i=1,8 do H.eq(g.spines[i].member,i) end
    local w=BoxWidget:new{entry={book=box,series_box=g},width=g.w,height=300}
    H.eq(w.plus,nil); H.eq(w.count.text,"0\xE2\x80\x8A/\xE2\x80\x8A20"); H.eq(#w.slots,8)
end)

H.test("a slipcase casts its shadow from its books and walls, not one rectangle", function()
    local box=Boxes.box(members(5,"Saga"),"Saga")
    local g=Boxes.geometry(box,BASE,SLIP)
    assert(g.wall_top>0 and g.wall_top<=g.rise, "the walls do not stop below the books' tops")
    local cols=Boxes.shadowColumns(g,100,5)
    H.eq(#cols,3)
    H.eq(cols[1].x,100); H.eq(cols[1].w,g.wall); H.eq(cols[1].h,g.front_h+g.wall_top)
    H.eq(cols[2].x,100+g.wall); H.eq(cols[2].w,g.w-2*g.wall); H.eq(cols[2].h,g.h)
    H.eq(cols[3].x,100+g.w-g.wall); H.eq(cols[3].h,g.front_h+g.wall_top)
end)

H.test("a slipcase paints inside its own rectangle, its books under the front", function()
    for _,n in ipairs({2,8,12}) do
        local box=Boxes.box(members(n,"Saga"),"Saga")
        local g=Boxes.geometry(box,BASE,SLIP)
        local w=BoxWidget:new{entry={book=box,series_box=g},width=g.w,height=320}
        painted_slots={}
        local bb=surface(20,10,g.w,320)
        w:paintTo(bb,20,10)
        H.eq(#painted_slots,math.min(n,8))
        for _,sl in ipairs(painted_slots) do
            H.eq(sl.y,10+320-g.h,"a book does not stand at the box's top")
        end
    end
end)

H.test("the native planner paginates boxes as single slots and resumes inside compacted groups", function()
    local SL=require("lib/bookshelf_spine_layout")
    local shelf={_flattenItems=native_flatten,VIEW_SIN=.2,FACE_GAP_DP=8,
        faceOutSpec=function() return {all=true} end,recentSet=function() end,
        cachedProgress=function() return nil,nil,true end,
        persistProgress=function() end,prefetchFacts=function() end,
        markSeriesHeads=function() end,thicknessPages=function() return 300 end,
        bookLook=function() return {r=90,g=120,b=80,aspect=1.5} end,
    }
    local plan_body=assert(shelf_source:match("function SpineShelf%.plan%(items, opts%)\n(.-)\nend"))
    local pe={SpineShelf=shelf,SpineLayout=SL,Screen=package.loaded.device.screen,
        Space=package.loaded["lib/bookshelf_space"],_gettime=function() return 0 end,
        _optsKey=function(o) return tostring(o.content_w)..":"..o.row_h end,
        _isFavourite=function() return false end,_flushLooks=function() end,
        _hydrate_cache={},_stable_checked={},SCAN_TAGS={},SHOWN_TAGS={},
        logger={dbg=function() end},require=function(name)
            if name=="lib/bookshelf_ornaments" then error("no ornaments in this fixture") end
            if name=="lib/bookshelf_theme_pack" then return {} end
            return require(name)
        end,
    }
    local plan=compile("return function(items,opts)\n"..plan_body.."\nend",pe)()
    local list={}
    for i=1,10 do list[#list+1]={series_name="Saga "..i,books=members(3,"Saga "..i,"/s"..i)} end
    local items=Boxes.prepare(list)
    local opts={row_h=240,content_w=550,n_rows=2,gap=10,balance=false}
    local p=plan(items,opts)
    H.eq(#p.entries,10); H.eq(#p.rows,2)
    for _,e in ipairs(p.entries) do
        assert(e.series_box and e.face_out)
        H.eq(e.w,e.series_box.w); H.eq(e.h,e.series_box.h)
        assert(e.w<=550 and e.h<=240)
    end
    H.eq(p.next_item,p.rows[2].last+1); H.eq(p.next_skip,0)
    -- Native page-map and visible-page passes must choose the same first page.
    opts.n_rows=math.huge
    local full=plan(items,opts)
    H.eq(full.rows[2].last,p.rows[2].last)
    -- Enough series that the author's boxes run past one page: a box is as
    -- narrow as the spines it holds.
    local raw={kind="author",series_name="Author",books={}}
    for i=1,40 do for _,b in ipairs(members(3,"Saga "..i,"/a"..i)) do raw.books[#raw.books+1]=b end end
    local groups=Boxes.prepare({raw})
    opts.n_rows=2
    p=plan(groups,opts)
    H.eq(p.next_item,1); H.eq(p.next_skip,p.rows[2].last)
    local seen=p.next_skip
    opts.skip=seen
    local next_page=plan(groups,opts)
    H.eq(next_page.entries[1].book,groups[1]._series_display_books[seen+1])
end)

H.test("native row construction routes taps and projected shadows through the series widget", function()
    local box=Boxes.box(members(3,"Saga"),"Saga")
    local shape=Boxes.geometry(box,{w=160,face_h=240,depth=8,h=248},{content_w=800})
    local entry={book=box,item=box,w=shape.w,h=shape.h,series_box=shape,face_out=true}
    local columns
    local shelf={bookLook=function() return {r=90,g=120,b=80} end,
        plankUnit=function() return 10 end,plankFace=function() return 20 end,
        plankInset=function() return 5 end,plankSurface=function() return 10 end,
        plankDesignWidget=function() end,endMargin=function() return 10 end,
        shadowsEnabled=function() return true end,shadowAssets=function() return true end,
        paintShadowAssets=function(_,_,_,cols) columns=cols; return true end,
    }
    local body=assert(shelf_source:match("function SpineShelf%.rowWidget%(opts%)\n(.-)\nend"))
    local row=compile("return function(opts)\n"..body.."\nend",{
        SpineShelf=shelf,Geom=W,Widget=W,ShelfPlank=W,ShelfBadges=W,SpineBookSlot=W,
        Screen=package.loaded.device.screen,_gettime=function() return 0 end,
        _nightMode=function() return false end,RECESS_HALO_DP=2,RECESS_SIDE_DP=2,
        require=function(name)
            if name=="lib/bookshelf_wallpaper" then return {shadeRect=function() end} end
            if name=="ui/widget/horizontalgroup" or name=="ui/widget/horizontalspan"
                or name=="ui/widget/overlapgroup" then return W end
            return require(name)
        end,
    })()
    local taps=0
    local out=row{plan={entries={entry}},row={first=1,last=1},width=800,height=320,gap=10,
        callbacks={on_series_tap=function(b) H.eq(b,box); taps=taps+1 end}}
    H.eq(out._shelf_badges,nil,"no duplicate section label under the box")
    local tile=out[#out][2]
    H.eq(tile.book,box); H.eq(tile:onTap(),true); H.eq(taps,1)
    out[2]:paintTo({},0,0)
    assert(columns and #columns==3, "a slipcase casts its books and two walls")
    local lead=math.floor((800-shape.w)/2)
    local expected=Boxes.shadowColumns(shape,lead,5)
    H.eq(#columns,#expected)
    for i,col in ipairs(columns) do
        for k,v in pairs(expected[i]) do H.eq(col[k],v) end
    end
end)

H.finish()
