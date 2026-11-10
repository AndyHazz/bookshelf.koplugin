-- The shelf widget's source, for suites that read methods out of it by name.
-- BookshelfWidget's methods are spread over lib/bookshelf_widget.lua and the
-- files it installs (OPDS, the book popup); a suite that looks a method up
-- should not care which one holds it. dofile() this for the lot as one string.
local parts = {}
for _i, name in ipairs({ "bookshelf_widget", "bookshelf_widget_opds", "bookshelf_widget_book_popup" }) do
    local f = assert(io.open("lib/" .. name .. ".lua"))
    parts[#parts + 1] = f:read("*a")
    f:close()
end
return table.concat(parts, "\n")
