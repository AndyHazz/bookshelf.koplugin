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

H.test("depth grows monotonically, is capped, and preserves the true volume count", function()
    local previous=0
    for _, n in ipairs({1,2,4,6,10,40,500}) do
        local box=Boxes.box(members(n,"Saga"),"Saga")
        local g=Boxes.geometry(box,{w=200,h=290,face_h=280,depth=10},{content_w=1000})
        assert(g.side>=previous and g.side<=90)
        H.eq(g.cover_w,200); H.eq(g.w,g.cover_w+g.side); H.eq(g.count,n)
        H.eq(g.face_h,280); H.eq(g.h,290)
        if n>=6 then H.eq(g.side,90) end
        previous=g.side
    end
    H.eq(Boxes.geometry(book(1),{},{content_w=1000}),nil)
end)

H.test("open sleeves give every visible binding a gap and cap the illustration at six", function()
    for _,n in ipairs({1,2,3,6,16,120}) do
        local box=Boxes.box(members(n,"Saga"),"Saga")
        for _,width in ipairs({1,5,20,80,160,240,480}) do
            for _,stroke in ipairs({1,2,3}) do
                local g=Boxes.geometry(box,{w=width,face_h=width*1.5,depth=8,h=width*1.5+8},
                    {content_w=1000})
                local slots=Boxes.spineSlots(g,stroke)
                assert(#slots<=6 and #slots<=n)
                if width>=160 then H.eq(#slots,math.min(6,n)) end
                local last=0
                for i,s in ipairs(slots) do
                    assert(s.x>=last+stroke and s.x+s.w<=g.side-stroke)
                    assert(s.w>=3)
                    H.eq(s.member,i)
                    last=s.x+s.w
                end
                H.eq(g.count,n)
            end
        end
    end
end)

H.test("narrow screens and cover-size changes share bounded aspect-preserving geometry", function()
    local box=Boxes.box(members(50,"Saga"),"Saga")
    for _, dpi in ipairs({1,2,3}) do
        for _, size in ipairs({.5,1,1.5}) do
            for _, width in ipairs({90,250,800}) do
                local base={w=200*dpi*size,h=290*dpi*size,face_h=280*dpi*size,depth=10*dpi*size}
                local g=Boxes.geometry(box,base,{content_w=width*dpi})
                assert(g.w<=width*dpi and g.h<=base.h)
                assert(math.abs(g.face_h/g.cover_w-1.4)<.04)
            end
        end
    end
end)

local repo={readProgress=function() end}
package.loaded["lib/bookshelf_book_repository"]=repo
package.loaded["lib/bookshelf_night_mode_sync"]={active=function()
    return G_reader_settings and G_reader_settings:isTrue("night_mode")
end}
-- Render the production widget against a bounded drawing surface. Record all
-- rectangles and text, and fail if geometry touches another slot or the dock.
local W=H.widget()
function W:getSize() return self.dimen or {w=self.width or 0,h=self.height or 0} end
function W:paintTo(bb,x,y) bb:paintRect(x,y,self.width,self.height,"cover") end
local HAIR="\xe2\x80\x8a"
local Text=W:extend{}
function Text:init()
    local text=self.text:gsub(HAIR,"")
    local size=self.face.size or 12
    self.dimen={w=math.max(1,math.min(self.max_width or math.huge,math.ceil(#text*size*.5))),h=size}
end
function Text:paintTo(bb,x,y) bb:paintRect(x,y,self.dimen.w,self.dimen.h,"text:"..self.text) end
local Frame=W:extend{}
function Frame:init()
    for _,side in ipairs({"left","right","top","bottom"}) do
        self["padding_"..side]=self["padding_"..side] or self.padding or 0
    end
    self.bordersize=self.bordersize or 0
    local size=self[1]:getSize()
    self.dimen={w=size.w+self.padding_left+self.padding_right+2*self.bordersize,
        h=size.h+self.padding_top+self.padding_bottom+2*self.bordersize}
end
function Frame:paintTo(bb,x,y)
    if self.background then bb:paintRect(x,y,self.dimen.w,self.dimen.h,self.background) end
    self[1]:paintTo(bb,x+self.padding_left+self.bordersize,y+self.padding_top+self.bordersize)
end
for _,name in ipairs({"ui/widget/container/inputcontainer","ui/geometry","ui/gesturerange"}) do
    package.loaded[name]=W
end
package.loaded["ui/widget/textwidget"]=Text
package.loaded["lib/bookshelf_colour_text"]=Text
package.loaded["ui/widget/container/framecontainer"]=Frame
package.loaded["ui/size"]={border={thin=1}}
package.loaded["ui/font"]={}
package.loaded["lib/bookshelf_space"]={px=function(n) return n end,padding={default=4,small=2}}
package.loaded["device"]={screen={scaleBySize=function(_,n) return n end}}
package.loaded["ffi/blitbuffer"]={ColorRGB32=function(r,g,b,a) return {r=r,g=g,b=b,a=a} end}
package.loaded["lib/bookshelf_fonts"]={getFace=function(_,_,size) return {size=size},true end}
local badge_scale, badge_colors, recolours=1,{badge_bg="badge-day",badge_fg="ink-day",
    border="border-day",complete_bookmark="mark-day",shadow="shadow-day"},{}
package.loaded["lib/bookshelf_cover_progress"]={
    badgeSize=function(n) return math.floor(n*badge_scale+.5) end,
    resolvedColors=function() return badge_colors end,
    registerRecolour=function(w,pick) recolours[w]=pick end,
}
package.loaded["ffi/util"]={template=function(s,n) return (s:gsub("%%1",tostring(n))) end}
-- Real native compositor/factory and preference decision, with only the
-- drawing primitives and font metrics replaced. No cover is loaded here.
local Spine=W:extend{}
local BareWidget=H.widget()
function BareWidget:getSize() return self.dimen end
local Group=W:extend{}
function Group:init()
    -- KOReader's OverlapGroup measures EVERY child at construction, even
    -- when the group has explicit dimensions. Widget:getSize returns nil
    -- without dimen; the old permissive zero-size mock hid a device crash.
    for _,child in ipairs(self) do
        local size=child:getSize()
        assert(size and type(size.w)=="number" and type(size.h)=="number",
            "OverlapGroup child has no dimensions")
    end
end
function Group:paintTo(bb,x,y)
    for _,child in ipairs(self) do
        local offset=child.overlap_offset or {0,0}
        child:paintTo(bb,x+offset[1],y+offset[2])
    end
end
local Center=W:extend{}
function Center:paintTo(bb,x,y) bb:paintRect(x,y,self.dimen.w,self.dimen.h,"completion-tick") end
local Vertical=W:extend{}
package.loaded["ui/widget/verticalgroup"]=Vertical
package.loaded["ui/widget/verticalspan"]=W
local CP=package.loaded["lib/bookshelf_cover_progress"]
local env={SpineWidget=Spine,Widget=BareWidget,FrameContainer=Frame,ColorSafeFrame=Frame,
    unpack=unpack or table.unpack,
    CenterContainer=Center,OverlapGroup=Group,Geom=W,Screen=package.loaded.device.screen,
    Size=package.loaded["ui/size"],Space=package.loaded["lib/bookshelf_space"],
    BFont=package.loaded["lib/bookshelf_fonts"],CoverProgress=CP,
    BookshelfSettings=package.loaded["lib/bookshelf_settings_store"],
    CARD_BORDER=1,ON_HOLD_FADE=.6,
    _toggle=function(k) return settings[k]~=false end,
    _badgeSize=CP.badgeSize,_pagePillRefH=function(size) return size end,
    _barBottomPadding=function() return 4 end,_barSideMargin=function() return 3 end,
    _glyphSize=function(w) return math.max(9,math.floor(w*.132)) end,
    _glyphTopLift=function() return .5 end,_glyphLeftInset=function() return 2 end,
    _baseGlyphRenderedH=function(_,base) return math.ceil(base*1.4) end,
    GLYPH_DANGLE_GROWTH_SHARE=.5,LIST_BADGE_CLEARANCE=.12,
}
local spine_source=source("bookshelf_spine_widget")
local function spineMethod(name,dot)
    local args,body=spine_source:match("function SpineWidget"..(dot and "%." or ":")..name.."%((.-)%)\n(.-)\nend")
    assert(body,name)
    local params=dot and args or "self"..(args~="" and ","..args or "")
    return compile("return function("..params..")\n"..body.."\nend",env)()
end
for _,name in ipairs({"_statusIndicators","_renderShadowedCard","_glyphWidth","_listBadgeClearance"}) do
    Spine[name]=spineMethod(name)
end
function Spine:_cardDimensions() return self.width,self.height end
Spine.finishedDecoration=spineMethod("finishedDecoration",true)
local decision=assert(source("bookshelf_cover_progress"):match("function M%.decide%(book%)\n(.-)\nend"))
CP.decide=compile("return function(book)\n"..decision.."\nend",env)()
CP.GLYPH_BOOKMARK_CHECK="completion-bookmark"
CP.glyphRenderedH=function(_,size) return math.ceil(size*1.4) end
CP.buildHaloShadowedGlyphWidget=function(_,size,halo,sx,sy)
    local mark=Group:new{dimen={w=size+halo+sx,h=size+halo+sy}}
    mark[1]=Frame:new{padding_left=halo+sx,padding_top=halo+sy,
        W:new{dimen={w=size,h=math.ceil(size*1.4)},width=size,height=math.ceil(size*1.4)}}
    function mark:paintTo(bb,x,y)
        local s=self[1]:getSize()
        bb:paintRect(x,y,s.w,s.h,"completion-bookmark")
    end
    return mark
end
package.loaded["lib/bookshelf_spine_widget"]=Spine
local BoxWidget=require("lib/bookshelf_series_box_widget")
local function surface(bb)
    bb.paintRectRGB32=bb.paintRectRGB32 or bb.paintRect
    return bb
end

H.test("cover-tinted sleeve inks use the RGB blitter and remain visible rather than near-black", function()
    local box=Boxes.box(members(3,"Saga"),"Saga")
    local shape=Boxes.geometry(box,{w=160,face_h=240,depth=8,h=248},{content_w=800})
    for _,look in ipairs({{r=65,g=120,b=95},{r=150,g=80,b=50},{r=40,g=60,b=160}}) do
        local w=BoxWidget:new{entry={book=box,series_box=shape,look=look},
            width=shape.w,height=300,inset=10}
        local fills,board=0
        w:paintTo({paintRect=function(_,_,_,_,_,c)
            assert(type(c)~="table","RGB ink was sent through the greyscale fast path")
        end,paintRectRGB32=function(_,x,y,rw,rh,c)
            fills=fills+1
            if x==0 and y==w.top+shape.depth and rw==shape.cover_w and rh==shape.face_h then
                board=c
            end
        end},0,0)
        assert(fills>0 and board)
        for _,k in ipairs({"r","g","b"}) do assert(board[k]>=look[k]) end
        assert(board.r~=board.g and board.g~=board.b,"cover hue must survive")
        H.eq(w[2].fgcolor.r,246) -- Title retains its contrasting ink.
    end
end)

H.test("only visible bindings sample cover colours, reusing the first look and never on paint", function()
    local calls={}
    local colors={{r=190,g=70,b=55},{r=40,g=135,b=110},{r=255,g=225,b=20},
        {r=90,g=80,b=180},{r=20,g=75,b=180},{r=225,g=225,b=225}}
    local shelf={_flattenItems=native_flatten,bookLook=function(b)
        local i=tonumber(b.series_num)
        calls[#calls+1]=i
        return colors[i]
    end}
    local box=Boxes.box(members(120,"Saga"),"Saga")
    local g=Boxes.geometry(box,{w=180,face_h=270,depth=10,h=280},{content_w=1000})
    H.eq(#calls,0,"planning must not sample every member")
    local entry={book=box,w=g.w,series_box=g,look=colors[1]}
    local w=BoxWidget:new{entry=entry, width=g.w, height=320, inset=10, book_look=shelf.bookLook}
    H.eq(#w.spines,6); H.eq(#calls,5)
    for i,s in ipairs(w.spines) do H.eq(s.look,colors[i]) end
    for i,n in ipairs(calls) do H.eq(n,i+1) end
    local day={}
    for _,night in ipairs({false,true}) do
        G_reader_settings={isTrue=function() return night end}
        local index=0
        w:paintTo(surface{paintRect=function(_,x,y,rw,rh,c)
            if type(c)=="table" then
                index=index+1
                for _,k in ipairs({"r","g","b"}) do
                    assert(c[k]>=0 and c[k]<=255,"RGB overflow")
                    if night then H.eq(c[k]+day[index][k],255,"material colour changes on night flip") end
                end
                if not night then day[index]=c end
            end
        end},0,0)
        H.eq(#calls,5)
        assert(w[2].fgcolor,"printed title needs contrasting foreground colour")
    end
    G_reader_settings=nil
    -- Missing or still-unextracted covers retain a valid binding, not a crash.
    shelf.bookLook=function() return nil end
    w=BoxWidget:new{entry=entry, width=g.w, height=320, inset=10, book_look=shelf.bookLook}
    for _,s in ipairs(w.spines) do H.eq(s.look,colors[1]) end
end)

local function countText(finished,total)
    return finished..HAIR.."/"..HAIR..total
end

H.test("read-total badges use live cached status only for visible deduplicated box members", function()
    local original=repo.readProgress
    local statuses,calls={},{}
    local raw=members(16,"Saga")
    for i,b in ipairs(raw) do
        b.status="finished" -- Stale light metadata must not supply the count.
        statuses[b.filepath]=i<=12 and "finished" or i==13 and "reading" or i==14 and "on_hold" or nil
    end
    raw[#raw+1]=raw[1]
    repo.readProgress=function(fp)
        calls[fp]=(calls[fp] or 0)+1
        return 1,statuses[fp] -- Even 100% alone is not "finished".
    end
    local items=Boxes.prepare({{series_name="Saga",books=raw,finished_count_total=99,book_count=99},
        {series_name="Offscreen",books=members(100,"Offscreen","/elsewhere")}})
    local box=items[1]
    local shape=Boxes.geometry(box,{w=160,face_h=240,depth=8,h=248},{content_w=800})
    H.eq(next(calls),nil) -- Grouping and planning must not scan progress.
    local function build()
        return BoxWidget:new{entry={book=box,series_box=shape,look={r=90,g=120,b=80}},
            width=shape.w,height=300,inset=10}
    end
    local w=build()
    H.eq(w[3][1].text,countText(12,16)); H.eq(w[2].text,"Saga")
    for _,b in ipairs(box.books) do H.eq(calls[b.filepath],1) end
    local reads=0; for _ in pairs(calls) do reads=reads+1 end
    H.eq(reads,16)
    local bb=surface{paintRect=function() end}
    w:paintTo(bb,0,0); w:paintTo(bb,0,0)
    for _,b in ipairs(box.books) do H.eq(calls[b.filepath],1) end
    statuses[box.books[13].filepath]="finished"
    H.eq(build()[3][1].text,countText(13,16))
    statuses[box.books[1].filepath]="reading"
    H.eq(build()[3][1].text,countText(12,16))
    H.eq(#raw,17); H.eq(raw[1].status,"finished")
    H.eq(box.finished_count_total,99) -- No writes to source aggregates.
    repo.readProgress=original
end)

H.test("zero, complete, single and filtered counts use actual membership without a count cap", function()
    local original=repo.readProgress
    for _,n in ipairs({1,4,120}) do
        for _,finished in ipairs({0,n}) do
            repo.readProgress=function() return nil,finished>0 and "finished" or nil end
            local box=Boxes.box(members(n,"Saga"),"Saga",{finished_count_total=999,book_count=999})
            local shape=Boxes.geometry(box,{w=160,face_h=240,depth=8,h=248},{content_w=800})
            local w=BoxWidget:new{entry={book=box,series_box=shape},width=shape.w,height=300,inset=10}
            H.eq(w[3][1].text,countText(finished,n)); H.eq(w.show_badge,true)
        end
    end
    local scoped={book(2,"Saga"),book(4,"Saga")}
    local box=Boxes.box(scoped,"Saga",{finished_count_total=8,book_count=10})
    repo.readProgress=function(fp) return nil,fp==scoped[1].filepath and "finished" or "reading" end
    local shape=Boxes.geometry(box,{w=160,face_h=240,depth=8,h=248},{content_w=800})
    local w=BoxWidget:new{entry={book=box,series_box=shape},width=shape.w,height=300,inset=10}
    H.eq(w[3][1].text,countText(1,2))
    repo.readProgress=original
end)

H.test("native badges share font scaling and recolour in place when night mode changes", function()
    local box=Boxes.box(members(16,"Saga"),"Saga")
    local shape=Boxes.geometry(box,{w=160,face_h=240,depth=8,h=248},{content_w=800})
    for _,scale in ipairs({.75,1,1.5}) do
        badge_scale=scale
        local w=BoxWidget:new{entry={book=box,series_box=shape},width=shape.w,height=300,inset=10}
        H.eq(w[3][1].face.size,math.floor(12*scale+.5))
        H.eq(w[3].background,"badge-day"); H.eq(w[3][1].fgcolor,"ink-day")
        assert(recolours[w[3]])
        w[3]:_bs_recolour(recolours[w[3]]({badge_bg="badge-night",badge_fg="ink-night"}))
        H.eq(w[3].background,"badge-night"); H.eq(w[3].color,"ink-night")
        H.eq(w[3][1].fgcolor,"ink-night")
        H.eq(w[3][1].text,countText(0,16))
    end
    badge_scale=1
end)

H.test("completion uses the whole nonempty box, not its cover or percentage, and reverses on rebuild", function()
    local original=repo.readProgress
    local raw=members(3,"Saga")
    raw[1].status="finished"
    local box=Boxes.box(raw,"Saga")
    local shape=Boxes.geometry(box,{w=160,face_h=240,depth=8,h=248},{content_w=800})
    local statuses={"finished","reading",nil}
    local reads=0
    repo.readProgress=function(fp)
        reads=reads+1
        return 1,statuses[tonumber(fp:match("(%d+)%.epub"))]
    end
    settings.finished_fade_enabled=true
    local function build()
        return BoxWidget:new{entry={book=box,series_box=shape},width=shape.w,height=300,inset=10}
    end
    local w=build()
    H.eq(w.all_read,false); H.eq(w[4],nil); H.eq(w.fade_amount,nil)
    H.eq(reads,3)
    statuses[2],statuses[3]="finished","finished"
    w=build()
    H.eq(w.all_read,true); H.eq(w.show_mark,true); H.eq(w.fade_amount,.6)
    H.eq(w[3][1].text,countText(3,3)); H.eq(reads,6)
    H.eq(w[1].show_progress,false); H.eq(w[1].show_status,false) -- No double fade.
    statuses[3]="new"
    w=build()
    H.eq(w.all_read,false); H.eq(w[4],nil); H.eq(w.fade_amount,nil)
    H.eq(w[3][1].text,countText(2,3)); H.eq(reads,9)
    local empty=Boxes.copy(box); empty.books={}
    w=BoxWidget:new{entry={book=empty,series_box=shape},width=shape.w,height=300,inset=10}
    H.eq(w.all_read,false); H.eq(w[4],nil); H.eq(w.fade_amount,nil); H.eq(reads,9)
    H.eq(raw[1].status,"finished"); H.eq(raw[2].status,nil); H.eq(box.status,nil)
    settings.finished_fade_enabled=nil
    repo.readProgress=original
end)

H.test("completed boxes reuse native tick/bookmark/off preferences and independent fade settings", function()
    local original=repo.readProgress
    repo.readProgress=function() return 1,"finished" end
    local box=Boxes.box(members(1,"Saga"),"Saga")
    local shape=Boxes.geometry(box,{w=160,face_h=240,depth=8,h=248},{content_w=800})
    for _,style in ipairs({"default","tickbox","bookmark","none","legacy-off"}) do
        settings.progress_badge_style=(style~="default" and style~="legacy-off") and style or nil
        settings.progress_badge_enabled=nil
        if style=="legacy-off" then settings.progress_badge_enabled=false end
        for _,fade in ipairs({false,true}) do
            settings.finished_fade_enabled=fade
            local w=BoxWidget:new{entry={book=box,series_box=shape},width=shape.w,height=300,inset=10}
            H.eq(not not w.show_mark,style~="none" and style~="legacy-off")
            H.eq(w.fade_amount,settings.finished_fade_enabled and .6 or nil)
            if w[4] and style=="tickbox" then
                local mark=w[4]
                H.eq(mark[1][1][2].text,"\xEF\x90\xAE")
                H.eq(mark.background,"badge-day"); H.eq(mark.color,"border-day")
                mark:_bs_recolour(recolours[mark]({badge_bg="night-bg",badge_fg="night-fg",border="night-border"}))
                H.eq(mark.background,"night-bg"); H.eq(mark.color,"night-border")
                H.eq(mark[1][1][2].fgcolor,"night-fg")
            elseif w[4] then
                assert(w.mark_size.h>w[4]:getSize().h,"must measure the real halo/shadow footprint")
                assert(recolours[w[4]],"native bookmark must keep its recolour registration")
            end
        end
    end
    for k in pairs(settings) do settings[k]=nil end
    repo.readProgress=original
end)

H.test("fade touches each silhouette pixel once; labels and native marks stay clear in both modes", function()
    local original=repo.readProgress
    local reads=0
    repo.readProgress=function() reads=reads+1; return 1,"finished" end
    settings.finished_fade_enabled=true
    for _,style in ipairs({"tickbox","bookmark"}) do
        settings.progress_badge_style=style
        for _,width in ipairs({20,80,160,240}) do
            for _,depth in ipairs({0,1,8,17}) do
                for _,night in ipairs({false,true}) do
                    badge_scale=width==20 and 2 or 1
                    G_reader_settings={isTrue=function() return night end}
                    local box=Boxes.box(members(6,"Saga"),"Saga")
                    local shape=Boxes.geometry(box,{w=width,face_h=width*1.5,depth=depth,h=width*1.5+depth},
                        {content_w=800})
                    local w=BoxWidget:new{entry={book=box,series_box=shape,look={r=90,g=120,b=80}},
                        width=shape.w,height=410,inset=10}
                    local painted,faded={},{}
                    local decoration=false
                    local function pixels(x,y,rw,rh,fn)
                        assert(x>=0 and x+rw<=shape.w and y>=0 and y+rh<=400)
                        assert(rw>0 and rh>0)
                        for py=y,y+rh-1 do for px=x,x+rw-1 do fn(py*1000+px) end end
                    end
                    local bb=surface{paintRect=function(_,x,y,rw,rh,c)
                        if c=="badge-day" or (type(c)=="string" and c:match("^text:"))
                                or c=="completion-tick" or c=="completion-bookmark" then decoration=true end
                        pixels(x,y,rw,rh,function(k) if not decoration then painted[k]=true end end)
                    end,lightenRect=function(_,x,y,rw,rh,amount)
                        H.eq(amount,.6); H.eq(decoration,false,"decorations must be painted after fade")
                        pixels(x,y,rw,rh,function(k)
                            assert(painted[k],"fade spilled onto wallpaper")
                            assert(not faded[k],"double fade darkens/lightens an edge twice")
                            faded[k]=true
                        end)
                    end}
                    local before=reads
                    w:paintTo(bb,0,0)
                    H.eq(reads,before,"paint must not query progress")
                    for k in pairs(painted) do assert(faded[k],"unfaded part of the box: "
                        ..table.concat({style,width,depth,k%1000,math.floor(k/1000)},",")) end
                    if w.show_mark then
                        assert(w.mark_y>=2*w.stroke and w.mark_y+w.mark_size.h<shape.face_h)
                        if w.show_title then
                            assert(w.mark_y+w.mark_size.h<shape.face_h-w.label_h-2*w.stroke)
                        end
                    end
                end
            end
        end
    end
    for k in pairs(settings) do settings[k]=nil end
    repo.readProgress=original; badge_scale=1; G_reader_settings=nil
end)

H.test("read badges stay on the front, clear of the title, including small faces", function()
    local box=Boxes.box(members(120,"Saga"),"Saga")
    for _,width in ipairs({20,60,80,160,240}) do
        for _,scale in ipairs({.75,1,1.5,2}) do
            badge_scale=scale
            local shape=Boxes.geometry(box,{w=width,face_h=width*1.5,depth=8,h=width*1.5+8},
                {content_w=800})
            local w=BoxWidget:new{entry={book=box,series_box=shape,look={r=90,g=120,b=80}},
                width=shape.w,height=410,inset=10}
            local badge_rect,title_rect
            local bb=surface{paintRect=function(_,x,y,rw,rh,c)
                assert(x>=0 and x+rw<=shape.w and y>=0 and y+rh<=400)
                if c=="badge-day" then badge_rect={x=x,y=y,w=rw,h=rh} end
                if c=="text:Saga" then title_rect={x=x,y=y,w=rw,h=rh} end
            end}
            w:paintTo(bb,0,0)
            if w.show_badge then
                assert(badge_rect)
                H.eq(badge_rect.x+badge_rect.w,shape.cover_w-2*w.stroke)
                H.eq(badge_rect.y,w.top+shape.depth+2*w.stroke)
                if title_rect then assert(badge_rect.y+badge_rect.h<title_rect.y) end
            else
                H.eq(badge_rect,nil)
                assert(w.badge_size.w>w.label_w or w.badge_size.h>shape.face_h-4*w.stroke)
            end
        end
    end
    badge_scale=1
end)

H.test("top and side share one projection with a sloping lower side edge", function()
    for _, size in ipairs({.5,1,1.5}) do
        for _, n in ipairs({1,6,40}) do
            for _, depth in ipairs({0,1,8,17}) do
                local box=Boxes.box(members(n,"Saga"),"Saga")
                local shape=Boxes.geometry(box,{w=160*size,face_h=240*size,
                    depth=depth,h=240*size+depth},{content_w=800})
                local w=BoxWidget:new{entry={book=box,series_box=shape,look={r=90,g=120,b=80}},
                    width=shape.w,height=410,inset=10}
                local first,last,side_top={},{},{}
                local bb=surface{paintRect=function(_,x,y,rw,rh)
                    if rh<=0 then return end
                    for px=x,x+rw-1 do
                        first[px]=math.min(first[px] or math.huge,y-w.top)
                        last[px]=math.max(last[px] or -math.huge,y-w.top+rh-1)
                        if x>=shape.cover_w and rh==shape.face_h then side_top[px]=y-w.top end
                    end
                end}
                w:paintTo(bb,0,0)
                local columns=Boxes.shadowColumns(shape,13,10)
                assert(#columns<=2*depth+3,"shadow geometry must be bounded by projection depth")
                local cursor=13
                for _,col in ipairs(columns) do
                    H.eq(col.x,cursor); assert(col.w>0)
                    for px=col.x-13,col.x-13+col.w-1 do
                        H.eq(410-col.h,w.top+first[px],"shadow top must meet the actual box")
                        H.eq(410-col.foot,w.top+last[px]+1,"contact shadow must follow the diagonal foot")
                    end
                    cursor=cursor+col.w
                end
                H.eq(cursor,13+shape.w)
                for x=0,shape.cover_w-1 do
                    local top=math.max(0,depth-math.floor(x*depth/shape.side))
                    H.eq(first[x],top,"top plane must recede instead of painting a flat strip")
                    H.eq(last[x],shape.h-1,"front still stands level on the plank")
                end
                for dx=0,shape.side-1 do
                    local rise=math.floor((dx+1)*depth/shape.side)
                    H.eq(first[shape.cover_w+dx],0,"top plane meets the rear edge")
                    H.eq(side_top[shape.cover_w+dx],depth-rise,"upper side edge")
                    H.eq(last[shape.cover_w+dx],shape.h-rise-1,"lower side edge")
                    H.eq(last[shape.cover_w+dx]-side_top[shape.cover_w+dx]+1,shape.face_h)
                end
                H.eq(first[-1],nil); H.eq(first[shape.w],nil)
            end
        end
    end
end)

H.test("box painting stays inside its planned width and above the plank at every size", function()
    for _,size in ipairs({.5,1,1.5}) do
        for _,n in ipairs({1,4,40}) do
            local box=Boxes.box(members(n,"Saga"),"Saga")
            local shape=Boxes.geometry(box,{w=160*size,face_h=240*size,depth=8,h=240*size+8},{content_w=800})
            local entry={book=box,series_box=shape,w=shape.w,look={r=90,g=120,b=80}}
            for _,night in ipairs({false,true}) do
                G_reader_settings={isTrue=function() return night end,readSetting=function() return "sv" end}
                local w=BoxWidget:new{entry=entry,width=shape.w,height=410,inset=10}
                local texts,rects={},0
                local bb=surface{paintRect=function(_,x,y,rw,rh,c)
                    assert(x>=20 and x+rw<=20+shape.w and y>=30 and y+rh<=430,
                        "paint overflow: "..table.concat({x,y,rw,rh},","))
                    assert(rw>0 and rh>=0)
                    if type(c)=="string" and c:match("^text:") then texts[c]=true end
                    rects=rects+1
                end}
                w:paintTo(bb,20,30)
                H.eq(w.dimen.x,20); H.eq(w.dimen.y,30)
                assert(texts["text:"..countText(0,n)])
                assert(texts["text:Saga"])
                H.eq(texts["text:"..n..(n==1 and " del" or " delar")],nil)
                H.eq(texts["text:"..n..(n==1 and " volume" or " volumes")],nil)
                assert(rects<=12*shape.depth+130,"bounded cost, not proportional to series length")
                H.eq(entry._drawn_h,shape.h)
                H.eq(w.ges_events.Tap[1].range,w.dimen)
            end
        end
    end
end)

H.test("tap and double-tap open the series, hold uses its menu, never opens a book", function()
    local box=Boxes.box(members(4,"Saga"),"Saga")
    local shape=Boxes.geometry(box,{w=160,face_h=240,depth=8,h=248},{content_w=800})
    local taps,holds=0,0
    local w=BoxWidget:new{entry={book=box,series_box=shape},width=shape.w,height=300,inset=10,
        callbacks={on_series_tap=function(g) H.eq(g,box); taps=taps+1 end,
            on_series_hold=function(g) H.eq(g,box); holds=holds+1 end,
            on_book_tap=function() error("Must not open the representative book") end}}
    H.eq(w:onTap(),true); H.eq(w:onDoubleTap(),true); H.eq(w:onHold(),true)
    H.eq(taps,2); H.eq(holds,1); H.eq(w[1].on_tap,nil)
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
    local raw={kind="author",series_name="Author",books={}}
    for i=1,10 do for _,b in ipairs(list[i].books) do raw.books[#raw.books+1]=b end end
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
    assert(columns and #columns>1)
    local lead=math.floor((800-shape.w)/2)
    local expected=Boxes.shadowColumns(shape,lead,5)
    H.eq(#columns,#expected)
    for i,col in ipairs(columns) do
        for k,v in pairs(expected[i]) do H.eq(col[k],v) end
    end
end)

H.finish()
