--[[
safeText: make untrusted text safe to render.

Micro-modules render text from network APIs, file metadata and user input. The
text shaper (crengine/HarfBuzz) can hard-segfault on invalid UTF-8 - a C-level
crash no Lua pcall can catch - which is the most likely cause of issue #163
(trivia's urlDecode emits raw bytes from %XX sequences with no validation, so a
question with a stray high byte becomes invalid UTF-8 and crashes at paint).

Prevention beats recovery: sanitise at the boundary so the bad input never
reaches the shaper. This runs KOReader's util.fixUtf8 (replaces invalid byte
sequences with U+FFFD), strips C0 control characters (except tab/newline/CR,
which TextBoxWidget handles), and caps pathological lengths.

util is required defensively: under the standalone test runner it's absent, in
which case fixUtf8 is skipped and the control-char/length passes still apply.
]]

local ok_util, util = pcall(require, "util")

local M = {}

-- U+FFFD REPLACEMENT CHARACTER - the conventional stand-in for a bad byte.
local REPLACEMENT = "\xEF\xBF\xBD"
-- Upper bound on a single rendered string. A multi-thousand-char run with no
-- break opportunity is itself a shaper risk and never sensible on a card.
local MAX_LEN = 4000

-- Strip C0 controls (0x00-0x1F) and DEL (0x7F), but keep tab (0x09), newline
-- (0x0A) and carriage return (0x0D) which the text widgets handle.
local CONTROL_PATTERN = "[%z\1-\8\11\12\14-\31\127]"

function M.safe(s)
    if type(s) ~= "string" then return "" end
    if ok_util and util.fixUtf8 then
        s = util.fixUtf8(s, REPLACEMENT)
    end
    s = s:gsub(CONTROL_PATTERN, "")
    if #s > MAX_LEN then s = s:sub(1, MAX_LEN) end
    return s
end

return M
