-- Reproducible, synthetic comparison of the real binding painters.
-- From the plugin root: lua tests/render_book_bindings.lua > /tmp/bindings.svg
-- Labels are SVG text, not a capture of KOReader's fonts or a device screen.
package.path = "./?.lua;" .. package.path
local F = dofile("tests/_binding_fixture.lua")
local Shelf = F.configure(require("lib/bookshelf_spine_shelf"))
local Top = F.upvalue(Shelf.rowWidget, "FaceOutTopBlock")
local out = {}
local function emit(s) out[#out+1]=s end
local function text(x,y,size,s,extra)
    emit(string.format('<text x="%d" y="%d" font-size="%d" %s>%s</text>',x,y,size,extra or "",s))
end
local function rect(x,y,w,h,fill)
    emit(string.format('<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/>',x,y,w,h,fill))
end
local function paint(bb)
    for _,r in ipairs(bb.rects) do
        rect(r.x,r.y,r.w,r.h,string.format("rgb(%d,%d,%d)",r.c.r,r.c.g,r.c.b))
    end
end
emit('<svg xmlns="http://www.w3.org/2000/svg" width="1100" height="720" viewBox="0 0 1100 720" shape-rendering="crispEdges">')
rect(0,0,1100,720,"#faf9f5")
emit('<g font-family="sans-serif" fill="#222">')
text(36,43,24,"Book binding: unchanged default + optional Paperback")
text(36,72,14,"Same colours, heights and thicknesses. Only the binding treatment changes.")
F.dpi=2
local palette={{70,98,120},{126,71,73},{82,110,82},{121,91,58},{99,91,125}}
local widths={58,66,52,78,58}
for n,style in ipairs({"hardcover","paperback"}) do
    local x=36+(n-1)*550
    text(x,118,23,n==1 and "Hardback (default)" or "Paperback (opt-in)")
    text(x,146,14,n==1 and "Raised boards / rounded spine shading" or "Thin flush covers / gentler spine shading")
    local bb=F.surface(1100,720)
    local sx=x
    rect(x,480,470,16,"#b7aa90")
    for i,rgb in ipairs(palette) do
        F.look={r=rgb[1],g=rgb[2],b=rgb[3],aspect=1.5}
        local slot=F.slot(Shelf,style)
        slot.entry.w,slot.entry.h=widths[i],300
        slot.width,slot.height=widths[i],300
        slot:_renderIntoAt(bb,sx,180,false)
        sx=sx+widths[i]
    end
    paint(bb)
    sx=x
    for i,w in ipairs(widths) do
        text(sx+w/2,350,16,"VOLUME "..i,
            string.format('fill="white" text-anchor="middle" transform="rotate(90 %g 350)"',sx+w/2))
        sx=sx+w
    end
    text(x,533,16,"Face-out top edge (detail)")
    F.look={r=70,g=98,b=120,aspect=1.5}
    local top=Top:new{dimen={w=310,h=22},look=F.look,binding=style}
    local head=F.surface(1100,720)
    top:paintTo(head,x,552); paint(head)
    rect(x,574,310,40,"#466278")
    text(x+155,601,14,"COVER",'fill="white" text-anchor="middle"')
end
text(36,666,15,"Shelf style: Book binding   |   Series long-press: Follow shelf / Hardback / Paperback")
text(36,693,13,"Headless painter output with synthetic books and schematic labels; not a device screenshot.")
emit('</g></svg>')
io.write(table.concat(out,"\n"),"\n")
