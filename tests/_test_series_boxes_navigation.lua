-- Native navigation and chip settings, with repository/UI I/O stubbed.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local function source(file)
    local f = assert(io.open("lib/" .. file .. ".lua"))
    local s = f:read("*a"); f:close(); return s
end
local function compile(code, env)
    setmetatable(env, {__index=_G})
    if setfenv then local f=assert(loadstring(code)); setfenv(f,env); return f end
    return assert(load(code,"series navigation","t",env))
end
local src = source("bookshelf_widget")
local function method(name, env)
    local args, body = src:match("function BookshelfWidget:"..name.."%((.-)%)\n(.-)\nend")
    assert(body,name)
    return compile("return function(self"..(args~="" and ","..args or "")..")\n"..body.."\nend",env)()
end
local tab, metas, settings = {}, {}, {}
local Repo = {
    lightMetaFor=function(fp) return metas[fp] end,
    buildBookMeta=function(fp, opts)
        assert(opts and opts.want_cover==false,"unexpected cover decode")
        return metas[fp] or {filepath=fp}
    end,
}
local Tabs = {getById=function() return tab end}
package.loaded["lib/bookshelf_tab_model"] = Tabs
package.loaded["lib/bookshelf_i18n"] = {gettext=function(s) return s end}
package.loaded["lib/bookshelf_settings_store"] = {
    read=function(k) return settings[k] end, generation=function() return 0 end,
}
package.loaded["lib/bookshelf_scaled_cover_cache"] = {has=function() return true end}
package.loaded["ui/widget/infomessage"] = {new=function() error("unexpected no-match") end}
local Boxes = require("lib/bookshelf_series_boxes")
local env = {Repo=Repo, SPINE_ALL_LIMIT=10000, _gettime=function() return 0 end,
    logger={dbg=function() end}, UIManager={setDirty=function() end}, _=function(s) return s end}
local function book(n, series, title)
    return {filepath="/lib/"..n..".epub",filename=n..".epub",title=title or "Book "..n,
        series_name=series,series_num=tostring(n)}
end
local function widget(raw)
    local w = {chip="home",_drilldown_path={},_cursor=1,
        _isSpineMode=function() return true end, _opdsEffectiveTab=function() end,
        _viewSize=function() return 4 end, _spineSkip=function() return 0 end,
        _clearDpadFocus=function() end, _syncPageFromCursor=function() end,
        _clampCursor=function() end, _swapShelvesInPlace=function() end,
        _markOpdsNav=function() end, _rebuild=function() end,
        _fetchChipItems=function() return raw,#raw end,
        _jumpScanList=function() return raw,"title","test" end,
    }
    for _,name in ipairs({"_seriesBoxesEnabled","_prepareSpineItems","_spineCachedFetch",
        "_spineItemsSig","_spineUpdateBookCounts","_serializeDrillPath","_restoreDrillPath",
        "_drillInto","_drillBackTo","_expandSeries","_applyWithinGroupSort","_jumpToLetterPrefix"}) do
        w[name]=method(name,env)
    end
    return w
end

t.test("opt-in is per shelf; grids, searches, single-series shelves and remote feeds stay native", function()
    local raw={book(1,"Saga"),book(2,"Saga")}
    local w=widget(raw)
    tab={}
    assert(w:_prepareSpineItems(raw,2)==raw)
    tab={series_boxes=true}
    eq(#w:_prepareSpineItems(raw,2),1)
    assert(w:_prepareSpineItems(raw,20)==raw)
    w._isSpineMode=function() return false end
    assert(w:_prepareSpineItems(raw,2)==raw)
    w._isSpineMode=function() return true end
    for _,kind in ipairs({"search","opds_nav","series"}) do
        w._drilldown_path={{kind=kind}}
        assert(w:_prepareSpineItems(raw,2)==raw)
    end
    w._drilldown_path={}; tab.source={kind="single_series"}
    assert(w:_prepareSpineItems(raw,2)==raw)
    tab.source=nil; w._opdsEffectiveTab=function() return {} end
    assert(w:_prepareSpineItems(raw,2)==raw)
    tab={}
end)

t.test("grouping happens before cache signatures, counts and letter-jump positions", function()
    tab={series_boxes=true}
    local a,b=book(1,"Saga","Beta"),book(2,"Saga","Gamma")
    local raw={book(0,nil,"Alpha"),a,b,book(4,nil,"Delta")}
    local w=widget(raw)
    local items,hint=w:_spineCachedFetch(4)
    eq(#items,3); eq(hint,nil)
    assert(w:_spineCachedFetch(4)==items)
    w._cursor=3; w:_spineUpdateBookCounts(items)
    eq(w._spine_books_total,3); eq(w._spine_books_before,2)
    w:_jumpToLetterPrefix("D"); eq(w._cursor,3)
    w:_jumpToLetterPrefix("B"); eq(w._cursor,2)
    eq(items[2].series_name,"Saga")
end)

t.test("partial windows and open-ended feeds are neither boxed nor cached", function()
    tab={series_boxes=true}
    local raw={book(1,"Saga"),book(2,"Saga")}
    local w=widget(raw)
    w._fetchChipItems=function() return raw,100 end
    local items,hint=w:_spineCachedFetch(4)
    assert(items==raw); eq(hint,100); eq(w._spine_fetch_cache,nil)
    raw.opds_open_ended=true
    w._fetchChipItems=function() return raw end
    assert(w:_spineCachedFetch(4)==raw); eq(w._spine_fetch_cache,nil)
end)

t.test("native group stubs gain numeric series order without modifying shared records", function()
    local a,b=book(10,"Saga"),book(2,"Saga")
    metas={[a.filepath]=a,[b.filepath]=b}
    local group={kind="author",series_name="Author",books={{filepath=a.filepath},{filepath=b.filepath}}}
    local out=Boxes.prepare({group},Repo.lightMetaFor)[1]
    assert(out.books==group.books)
    eq(#out._series_display_books,1)
    eq(out._series_display_books[1].first_book.series_num,"2")
    eq(group.books[1].series_num,nil); eq(a._series_box,nil)
    eq(out._series_display_books[1]._series_sort_book.filepath,a.filepath)
    metas={}
end)

t.test("changed compact membership invalidates signatures even with the same raw count", function()
    local a,b,c=book(1,"Saga"),book(2,"Saga"),book(3)
    local raw={kind="author",series_name="Author",books={a,b,c}}
    local w=widget({raw})
    local one=Boxes.prepare({raw})
    b.series_name=nil; c.series_name="Saga"
    local two=Boxes.prepare({raw})
    assert(w:_spineItemsSig(one)~=w:_spineItemsSig(two))
end)

t.test("tap drills and back returns to the same chip and parent cursor", function()
    tab={series_boxes=true}
    local box=Boxes.box({book(1,"Saga"),book(2,"Saga")},"Saga")
    local w=widget({box}); w._cursor=9
    w:_expandSeries(box)
    eq(w.chip,"home"); eq(w._cursor,1); eq(#w._drilldown_path,1)
    assert(w._drilldown_path[1].payload==box)
    eq(w:_seriesBoxesEnabled(),false)
    w:_drillBackTo(0)
    eq(w._cursor,9); eq(w.chip,"home"); eq(#w._drilldown_path,0)
    eq(w:_seriesBoxesEnabled(),true)
end)

t.test("large series drills use the complete light list, not the current grid-sized window", function()
    tab={series_boxes=true}
    local books={}
    for i=1,120 do books[i]=book(i,"Saga"); metas[books[i].filepath]=books[i] end
    local box=Boxes.box(books,"Saga")
    local w=widget({}); w._fetchChipItems=method("_fetchChipItems",env)
    w:_expandSeries(box); w._cursor=51
    local all,total=w:_fetchChipItems(10000,true)
    eq(#all,120); eq(total,120); eq(all[1].series_num,"1")
    assert(all[1]~=metas[all[1].filepath]); eq(all[1].cover_bb,nil)
    eq(Repo.suppress_covers,nil); eq(Repo.spine_light,nil)
    assert(w:_prepareSpineItems(all,total)==all)
    local partial=w:_fetchChipItems(4,false)
    eq(#partial,4); eq(partial[1].series_num,"51")
    local limited=w:_fetchChipItems(8,true)
    eq(#limited,8); eq(limited[1].series_num,"1")
    tab.filter={}
    Repo.filterMembers=function(members)
        local out={}; for _,b in ipairs(members) do
            if tonumber(b.series_num)%2==0 then out[#out+1]=b end
        end; return out
    end
    eq(#w:_fetchChipItems(10000,true),60); eq(#box.books,120)
    w._drilldown_path[1].whole=true
    eq(#w:_fetchChipItems(10000,true),120)
    Repo.filterMembers=nil; metas={}
end)

t.test("restart intersects saved file identifiers with current membership and never widens scope", function()
    tab={series_boxes=true}
    local w=widget({})
    w:_expandSeries(Boxes.box({book(2,"Saga"),book(4,"Saga")},"Saga"))
    local saved=w:_serializeDrillPath()
    eq(#saved[1].series_box_files,2); eq(saved[1].books,nil)
    Repo.findGroup=function(kind,label)
        eq(kind,"series")
        return {series_name=label,books={book(1,"Saga"),book(2,"Saga"),book(3,"Saga")}}
    end
    w._drilldown_path={}; w:_restoreDrillPath(saved)
    local restored=w._drilldown_path[1].payload
    eq(#restored.books,1); eq(restored.books[1].series_num,"2"); assert(Boxes.isBox(restored))
    eq(#w:_serializeDrillPath()[1].series_box_files,1)
    Repo.findGroup=function() return {series_name="Saga",books={book(99,"Saga")}} end
    w._drilldown_path={}; w:_restoreDrillPath(saved)
    eq(#w._drilldown_path,0)
    Repo.findGroup=nil
end)

t.test("the editor toggle changes only its own draft and uses the existing live-apply callback", function()
    local editor=source("bookshelf_chip_editor")
    local body=assert(editor:match('if show_spines then\n(.-)\n%s*%-%- The spine view'))
    local a,b={},{}
    local function toggle(draft)
        local changes=0
        local rows={}
        compile(body,{rows=rows,draft=draft,_=function(s) return s end,
            T=function(s,v) return (s:gsub("%%1",v)) end,
            pick=function(fn) return function() fn(); changes=changes+1 end end})()
        local old=rows[1][1].text_func()
        rows[1][1].callback()
        eq(changes,1)
        return old,rows[1][1].text_func()
    end
    local before,after=toggle(a)
    eq(before,"Series boxes: Off"); eq(after,"Series boxes: On")
    eq(a.series_boxes,true); eq(b.series_boxes,nil)
    toggle(a); eq(a.series_boxes,nil)
end)

t.test("inside a drilled box set every book faces out; elsewhere the shelf's choice holds", function()
    local fenv=setmetatable({BookshelfSettings={read=function() return nil end},
        _faceOutModes=function() return {none=true,all=true,favorites=true} end},{__index=env})
    local faceOut=method("_spineFaceOut",fenv)
    tab.spine_face_out="none"
    local box=Boxes.box({book(1,"Saga"),book(2,"Saga")},"Saga")
    eq(faceOut({_drilldown_path={{kind="series",payload=box,label="Saga"}}}),"all")
    eq(faceOut({_drilldown_path={{kind="series",payload={series_name="Saga"},label="Saga"}}}),"none",
        "a series stack opened (not a box) changed the face-out choice")
    eq(faceOut({_drilldown_path={}}),"none")
    tab.spine_face_out=nil
end)

t.test("an opened box keeps its series order whatever the shelf's later sort levels", function()
    local within=method("_applyWithinGroupSort",env)
    tab.sort_priority={{key="series"},{key="title",reverse=true}}
    local bks={book(1,"Saga","Alpha"),book(2,"Saga","Beta"),book(3,"Saga","Gamma")}
    for _,b in ipairs(bks) do metas[b.filepath]=b end
    local box=Boxes.box(bks,"Saga")
    local before={}
    for i,b in ipairs(box.books) do before[i]=b.filepath end
    within({chip="x"},box)
    for i,b in ipairs(box.books) do eq(b.filepath,before[i],"a box was re-sorted by the shelf") end
    -- The same books as an ordinary series stack do follow the shelf.
    local stack={kind="series",series_name="Saga",books={bks[1],bks[2],bks[3]}}
    within({chip="x"},stack)
    eq(stack.books[1].title,"Gamma","the shelf's later levels no longer sort a series stack")
    for _,b in ipairs(bks) do metas[b.filepath]=nil end
    tab.sort_priority=nil
end)

t.done()
