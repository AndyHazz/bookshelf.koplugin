--[[
Pacman progress-bar sprite + layout helpers.

The 13x13 frames are hand-authored bit patterns chosen to read as a
chunky arcade silhouette: a flat 5-wide top and bottom, a 11-wide
shoulder band where the disc holds its full width, and an open-frame
wedge that bites deep into the body past the horizontal centre line.

Earlier versions generated the bits from a geometric formula (disc
minus wedge), but a strict circle minus a triangle produces an
hourglass body — the wedge cuts too aggressively through the rows next
to the centre. Holding the shoulder rows wide gives the chunky read
that a smooth taper can't.

Sprite data layout: each frame is a 13-element array. Element i is an
integer whose low 13 bits encode row i of the grid (bit 0 = column 0).
Each row literal is annotated with an ASCII strip so the silhouette is
visible in diff.

The OPEN frame is a strict subset of the CLOSED frame — every "on"
cell in OPEN is also on in CLOSED. The seam in CLOSED is a 3-cell
notch at row 6 cols 10..12, which falls inside the OPEN wedge.

Pure Lua. No KOReader imports.
]]

local Pacman = {}

Pacman.SPRITE_SIZE = 13

-- Open frame. Mouth tip at row 6 col 4 (column 5 is the first cleared
-- cell on the wedge axis — one cell past the centre column 6). Shoulder
-- rows hold their full 11 width; the mouth wedge tapers from 10 wide
-- (row 4) to 5 wide (row 6).
local OPEN_FRAME = {
    0x1F0,  -- row  0: ....XXXXX....
    0x7FC,  -- row  1: ..XXXXXXXXX..
    0xFFE,  -- row  2: .XXXXXXXXXXX.
    0xFFE,  -- row  3: .XXXXXXXXXXX.
    0x3FF,  -- row  4: XXXXXXXXXX...
    0x07F,  -- row  5: XXXXXXX......
    0x01F,  -- row  6: XXXXX........ (mouth tip)
    0x07F,  -- row  7: XXXXXXX......
    0x3FF,  -- row  8: XXXXXXXXXX...
    0xFFE,  -- row  9: .XXXXXXXXXXX.
    0xFFE,  -- row 10: .XXXXXXXXXXX.
    0x7FC,  -- row 11: ..XXXXXXXXX..
    0x1F0,  -- row 12: ....XXXXX....
}

-- Closed frame. Same chunky body, full-width through rows 4..8, with
-- a 3-cell horizontal notch at row 6 cols 10..12 so the closed shape
-- doesn't read as a featureless blob.
local CLOSED_FRAME = {
    0x1F0,   -- row  0: ....XXXXX....
    0x7FC,   -- row  1: ..XXXXXXXXX..
    0xFFE,   -- row  2: .XXXXXXXXXXX.
    0xFFE,   -- row  3: .XXXXXXXXXXX.
    0x1FFF,  -- row  4: XXXXXXXXXXXXX
    0x1FFF,  -- row  5: XXXXXXXXXXXXX
    0x3FF,   -- row  6: XXXXXXXXXX... (3-cell seam at cols 10..12)
    0x1FFF,  -- row  7: XXXXXXXXXXXXX
    0x1FFF,  -- row  8: XXXXXXXXXXXXX
    0xFFE,   -- row  9: .XXXXXXXXXXX.
    0xFFE,   -- row 10: .XXXXXXXXXXX.
    0x7FC,   -- row 11: ..XXXXXXXXX..
    0x1F0,   -- row 12: ....XXXXX....
}

-- Read-only sprite accessor. Returns the array directly; callers must not
-- mutate it.
function Pacman.getFrame(frame_name)
    if frame_name == "open" then return OPEN_FRAME end
    if frame_name == "closed" then return CLOSED_FRAME end
    error("Pacman.getFrame: unknown frame " .. tostring(frame_name), 2)
end

-- Read bit (x, y) from a frame array.
local function readBit(frame, x, y)
    local mask = 2 ^ x
    return (math.floor(frame[y + 1] / mask) % 2) == 1
end

-- Write bit (x, y) into a row-array under construction. Mutates `rows`.
local function setBit(rows, x, y)
    rows[y + 1] = (rows[y + 1] or 0) + 2 ^ x
end

-- Rotate a 13x13 frame by `steps` 90-degree CW turns.
-- Returns a new frame; input is not mutated.
-- Coordinate mapping for one CW step (size 13):
--   (x, y) -> (12 - y, x)
function Pacman.rotate(frame, steps)
    steps = steps % 4
    if steps == 0 then
        -- Defensive copy so callers can treat the return as fresh.
        local out = {}
        for y = 0, 12 do out[y + 1] = frame[y + 1] end
        return out
    end
    local current = frame
    for _step = 1, steps do
        local next_rows = {}
        for y = 0, 12 do next_rows[y + 1] = 0 end
        for y = 0, 12 do
            for x = 0, 12 do
                if readBit(current, x, y) then
                    setBit(next_rows, 12 - y, x)
                end
            end
        end
        current = next_rows
    end
    return current
end

-- Map a direction string ("right" | "down" | "left" | "up") to the number
-- of 90-degree CW rotations needed to face that direction from a
-- right-facing base. Unknown directions default to 0.
function Pacman.directionToSteps(direction)
    if direction == "down" then return 1 end
    if direction == "left" then return 2 end
    if direction == "up" then return 3 end
    return 0
end

-- Lay out dots and a power pellet along an unread region of `length` device
-- pixels. Returns:
--   { dots   = { d1, d2, ... },   -- ascending start offsets of each dot
--     pellet = p_start | nil }     -- start offset of the pellet (nil if no room)
--
-- length        total length of the unread region (px)
-- dot_block     dot side length (px), square
-- pellet_block  pellet side length (px), square; should be >= dot_block
--
-- Layout rules:
--   * pellet sits flush against the far end:   pellet = length - pellet_block
--   * dots placed at pitch = max(dot_block*3, floor(length*0.6))
--     ...except the helper picks a pitch that lets at least one dot fit
--     when length is short. Concretely: pitch = max(dot_block*3, floor(length*0.6))
--     evaluated once; dots stride from dot_block (small margin from start)
--     to first overlap with pellet.
--   * any dot whose footprint would overlap the pellet is skipped.
function Pacman.layoutDots(length, dot_block, pellet_block)
    local result = { dots = {} }
    if length < dot_block + pellet_block then
        -- No room for both a dot and a pellet.
        return result
    end
    result.pellet = length - pellet_block

    -- Pitch is a fixed multiple of dot size, not scaled with bar length
    -- (length-scaling was too aggressive on long bars and read as huge
    -- empty gaps between dots).
    local pitch = dot_block * 4
    -- Start half a pitch in (floored to at least one dot width) so the
    -- strip breathes from the sprite. Then stride by pitch.
    local cursor = math.max(dot_block, math.floor(pitch / 2))
    while cursor + dot_block <= result.pellet do
        table.insert(result.dots, cursor)
        cursor = cursor + pitch
    end

    return result
end

return Pacman
