-- tests/_test_dpad_cursor.lua
-- Unit tests for D-pad cursor movement arithmetic (pure logic, no KOReader).
-- Run: cd bookshelf.koplugin && lua tests/_test_dpad_cursor.lua

local pass, fail = 0, 0
local function check(desc, cond)
    if cond then
        io.write("  PASS: " .. desc .. "\n")
        pass = pass + 1
    else
        io.write("  FAIL: " .. desc .. "\n")
        fail = fail + 1
    end
end

-- cursor_step: pure version of the movement logic inside _moveCursor.
-- Returns new_idx (integer) on success, nil + page_delta on boundary.
-- page_delta: -1 = prev page, +1 = next page, 0 = nil slot (no-op).
local function cursor_step(cursor_idx, delta, page_items, view_size)
    local new_idx = cursor_idx + delta
    if new_idx < 1 then return nil, -1 end
    if new_idx > view_size then return nil, 1 end
    if not page_items[new_idx] then return nil, 0 end
    return new_idx, 0
end

-- Helper: last non-nil index in items table (cursor clamp target).
local function last_real(items)
    for i = #items, 1, -1 do
        if items[i] then return i end
    end
    return 0
end

local FULL = {1,2,3,4,5,6,7,8}
-- Partial last page: 3 real books, rest nil
local PART = {1,2,3,nil,nil,nil,nil,nil}

print("--- cursor_step ---")
do
    local i, d = cursor_step(1, 1, FULL, 8)
    check("right from 1 → 2", i == 2 and d == 0)
end
do
    local i, d = cursor_step(8, 1, FULL, 8)
    check("right from last → fwd page flip", i == nil and d == 1)
end
do
    local i, d = cursor_step(1, -1, FULL, 8)
    check("left from first → back page flip", i == nil and d == -1)
end
do
    local i, d = cursor_step(3, 4, FULL, 8)
    check("down from row1 col3 → 7", i == 7 and d == 0)
end
do
    local i, d = cursor_step(5, -4, FULL, 8)
    check("up from row2 col1 → 1", i == 1 and d == 0)
end
do
    local i, d = cursor_step(1, -4, FULL, 8)
    check("up from row1 → back page flip", i == nil and d == -1)
end
do
    local i, d = cursor_step(3, 1, PART, 8)
    check("right into nil slot → no-op (d=0)", i == nil and d == 0)
end
do
    local i, d = cursor_step(3, 4, PART, 8)
    check("down into nil slot → no-op (d=0)", i == nil and d == 0)
end

print("--- last_real ---")
do check("full page → 8",    last_real(FULL) == 8) end
do check("partial page → 3", last_real(PART) == 3) end
do check("empty page → 0",   last_real({}) == 0) end

print(string.format("\nResults: %d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
