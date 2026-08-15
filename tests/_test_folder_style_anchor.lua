-- tests/_test_folder_style_anchor.lua
-- Editor:_pickGroupDisplay -- the anchor it hands MovableContainer.
--
-- Chip menu > Folder style took KOReader down on release 4.2.0:
--
--   movablecontainer.lua:143: attempt to compare nil with number
--     ... in function 'ensureAnchor'
--
-- The picker returned `{ y = 96 }` and left x/w/h unset, on the understanding
-- that MovableContainer fills a missing x with a centred value. It does --
-- since upstream 0d5a2724a ("QuickMenu position", 2026-07-07), first released
-- in KOReader v2026.07. On v2026.03 and every version before it ensureAnchor
-- reads the field raw:
--
--   left = anchor_dimen.x     -- nil
--   if left < 0 then          -- line 143. Crash.
--
-- So the rule this suite holds is: the anchor comes back with x, y, w and h
-- all NUMBERS, whatever KOReader is going to do with them -- and lands the
-- dialog in the SAME place either way. Checked by running the real
-- ensureAnchor arithmetic (copied verbatim below, the four defaulting lines
-- behind a flag, which is the only difference between the two releases) over
-- whatever the picker returns.
package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src  = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local body = src:match(
    "\nfunction Editor:_pickGroupDisplay%(draft, on_change, chrome%)\n(.-)\nend\n")
assert(body, "could not find Editor:_pickGroupDisplay - renamed?")

-- A PW5: 1236x1648 at 264 DPI, where scaleBySize(1) is about 2px.
local SCREEN_W, SCREEN_H = 1236, 1648
-- What ButtonDialog would lay this dialog out at: its default width factor is
-- 0.9 of the screen's smaller side.
local DIALOG_W, DIALOG_H = math.floor(math.min(SCREEN_W, SCREEN_H) * 0.9), 700

-- MovableContainer:ensureAnchor, arithmetic verbatim. `with_defaults` is the
-- ONLY difference between the two releases: v2026.07 fills in missing anchor
-- fields, v2026.03 and earlier do not. Returns left, top.
local function ensureAnchor(anchor_dimen, prefers_pop_down, mirrored, with_defaults)
    local content_w, content_h = DIALOG_W, DIALOG_H
    local screen_w, screen_h = SCREEN_W, SCREEN_H
    if with_defaults then
        anchor_dimen.x = anchor_dimen.x or math.floor((screen_w - content_w) / 2)
        anchor_dimen.y = anchor_dimen.y or math.floor((screen_h - content_h) / 2)
        anchor_dimen.w = anchor_dimen.w or 0
        anchor_dimen.h = anchor_dimen.h or 0
    end
    local left, top
    if mirrored then
        left = anchor_dimen.x + anchor_dimen.w - content_w
    else
        left = anchor_dimen.x
    end
    if left < 0 then
        left = 0
    elseif left + content_w > screen_w then
        left = screen_w - content_w
    end
    local h_remaining_if_above = anchor_dimen.y - content_h
    local h_remaining_if_below = screen_h - (anchor_dimen.y + anchor_dimen.h + content_h)
    if h_remaining_if_above >= 0 and not prefers_pop_down then
        top = anchor_dimen.y - content_h
    elseif h_remaining_if_below >= 0 then
        top = anchor_dimen.y + anchor_dimen.h
    elseif h_remaining_if_above >= 0 then
        top = anchor_dimen.y - content_h
    else
        if h_remaining_if_above >= h_remaining_if_below then
            top = 0
        else
            top = screen_h - content_h
        end
    end
    if top < 0 then top = 0 end
    return left, top
end

-- Enough StackDisplay for the picker to build its rows. The styles themselves
-- are not what is under test; _test_stack_display covers those.
local StackDisplay = {
    FOLLOW_DEFAULT = "default",
    CHIP_OPTIONS = {
        { value = "default", label_func = function() return "Default setting" end },
        { value = "divider", label_func = function() return "Divider"  end },
        { value = "ribbon",  label_func = function() return "Ribbon"   end },
        { value = "stack",   label_func = function() return "Stack"    end },
        { value = "collage", label_func = function() return "Collage"  end },
        { value = "text",    label_func = function() return "Text"     end },
        { value = "none",    label_func = function() return "None"     end },
    },
    pinned = function(v) if v and v ~= "default" then return v end end,
}

local Kit = { radioRow = function(o)
    return { text = (o.active and "\xE2\x9C\x93 " or "") .. o.label,
             callback = o.on_pick }
end }

local shown
local env = {
    ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
    math = math, table = table,
    _ = function(s) return s end,
    Screen = {
        getWidth     = function() return SCREEN_W end,
        getHeight    = function() return SCREEN_H end,
        scaleBySize  = function(_self, n) return math.floor(n * 2) end,
    },
    UIManager = {
        show  = function(_self, d) shown = d end,
        close = function() end,
    },
    -- Stands in for the real ButtonDialog closely enough for the anchor: it
    -- fills in `width` at init, and by the time MovableContainer evaluates the
    -- anchor (from paintTo) `movable.dimen` is already the laid-out size.
    ButtonDialog = { new = function(_self, o)
        o.width  = DIALOG_W
        o.movable = { dimen = { x = 0, y = 0, w = DIALOG_W, h = DIALOG_H } }
        return o
    end },
    require = function(mod)
        if mod == "lib/bookshelf_module_kit" then return Kit end
        if mod == "lib/bookshelf_stack_display" then return StackDisplay end
        error("picker required an unexpected module: " .. tostring(mod))
    end,
}
env._G = env

local function compile(code)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_pickGroupDisplay"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_pickGroupDisplay", "t", env))
end
local run = compile("local self, draft, on_change, chrome = ...\n" .. body)

-- Open the picker and hand back its anchor's two return values.
local function openAnchor(draft)
    shown = nil
    run({}, draft or {}, nil, nil)
    assert(shown, "the picker showed no dialog")
    assert(type(shown.anchor) == "function",
           "the picker's anchor is no longer a function")
    return shown.anchor()
end

t.test("every anchor field is a number, so pre-v2026.07 ensureAnchor survives", function()
    local rect = openAnchor()
    for _i, f in ipairs({ "x", "y", "w", "h" }) do
        eq(type(rect[f]), "number", "anchor." .. f .. " type:")
    end
end)

t.test("the crash from release 4.2.0 does not reproduce", function()
    local rect, pop_down = openAnchor()
    local ok, err = pcall(ensureAnchor, rect, pop_down, false, false)
    assert(ok, "ensureAnchor blew up on the anchor we hand it: " .. tostring(err))
end)

t.test("the dialog lands horizontally centred", function()
    local rect, pop_down = openAnchor()
    local left = ensureAnchor(rect, pop_down, false)
    eq(left, math.floor((SCREEN_W - DIALOG_W) / 2), "left edge:")
end)

t.test("it centres under a mirrored (RTL) layout too", function()
    -- Mirrored takes the OTHER branch: left = x + w - content_w. An anchor
    -- with w = 0 would throw the dialog a full dialog-width to the left.
    local rect, pop_down = openAnchor()
    local left = ensureAnchor(rect, pop_down, true)
    eq(left, math.floor((SCREEN_W - DIALOG_W) / 2), "left edge (mirrored):")
end)

t.test("it opens BELOW the anchor y, not above it", function()
    -- prefers_pop_down is what keeps it there: with room above, ensureAnchor
    -- would otherwise place it at y - content_h, clamp to 0, and cover the
    -- status bar as well as the folder tiles the picker exists to show.
    local rect, pop_down = openAnchor()
    assert(pop_down, "the anchor stopped returning prefers_pop_down")
    local _left, top = ensureAnchor(rect, pop_down, false)
    eq(top, rect.y + rect.h, "top edge:")
end)

t.test("v2026.03 and v2026.07 place the dialog identically", function()
    -- The property that makes this safe to ship without testing every
    -- KOReader: the anchor's x is read off the SAME field ensureAnchor uses
    -- as content_w, so it is by construction the value v2026.07's default
    -- would have computed. With all four fields supplied, the four defaulting
    -- lines that separate the releases are no-ops.
    for _i, mirrored in ipairs({ false, true }) do
        local old_rect, old_pop = openAnchor()
        local new_rect, new_pop = openAnchor()
        local ol, ot = ensureAnchor(old_rect, old_pop, mirrored, false)
        local nl, nt = ensureAnchor(new_rect, new_pop, mirrored, true)
        eq({ ol, ot }, { nl, nt },
           "placement differs between releases (mirrored=" .. tostring(mirrored) .. "):")
    end
end)

t.test("the picker still stays high enough to leave the shelf visible", function()
    -- The point of the anchor at all: sit over the hero, not over the folder
    -- tiles below it. Pin the top to the upper quarter of the screen.
    local rect = openAnchor()
    assert(rect.y > 0 and rect.y < math.floor(SCREEN_H / 4),
           "anchor y drifted out of the hero band: " .. tostring(rect.y))
end)

t.done()
