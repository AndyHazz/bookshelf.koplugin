local pass, fail = 0, 0

local function ok(cond, msg)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL: " .. msg .. "\n")
    end
end

local f = assert(io.open("lib/bookshelf_widget.lua", "r"))
local src = f:read("*a")
f:close()

local next_body = src:match("function BookshelfWidget:(_paginateNext%(%).-)function BookshelfWidget:_paginatePrev")
local prev_body = src:match("function BookshelfWidget:(_paginatePrev%(%).-)%-%- Take a screenshot")

ok(next_body and next_body:find("local%s+_diag_t0%s*=%s*_gettime%(%s*%)"),
    "_paginateNext declares _diag_t0 before wrap logging")
ok(prev_body and prev_body:find("local%s+_diag_t0%s*=%s*_gettime%(%s*%)"),
    "_paginatePrev declares _diag_t0 before wrap logging")

io.write(("pagination_diag: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
