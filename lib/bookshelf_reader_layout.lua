-- bookshelf_reader_layout.lua
-- Lay a freshly loaded CreDocument out the way the reader will: the reader's
-- global defaults for font, size, spacing, margins, style sheet, style tweaks
-- and block rendering, and room for the status bar. For "Extract page counts",
-- whose render used crengine's own defaults and so counted 3-4x fewer pages
-- than the reader shows (measured on a PW5: 27 against 75, 218 against 852).
--
-- What the reader modules do on open (ReaderFont / ReaderTypeset /
-- ReaderStyleTweak / ReaderRolling onReadSettings), restated from the
-- settings alone, since none of those modules exist outside a ReaderUI. A
-- book's OWN settings are never read: the books this is for have no sidecar.
-- Every setter is pcall'd on its own, so a KOReader that renamed one loses
-- that one adjustment rather than the count.
--
-- Measured against a real open on the PW5 before the tweaks and footer were
-- added: +10% render time over the bare layout, counts 0-14% low.

local M = {}

local function g(key, default_key, fallback)
    local v = G_reader_settings and G_reader_settings:readSetting(key)
    if v == nil and default_key and G_defaults then v = G_defaults:readSetting(default_key) end
    if v == nil then v = fallback end
    return v
end

-- tweakCss() -> the global style tweaks' CSS, in the reader's order: the
-- built-in tweaks from ui/data/css_tweaks, then the user's own .css files in
-- koreader/styletweaks (priority 10), lower priority first, then by id.
function M.tweakCss()
    local ok_ct, CssTweaks = pcall(require, "ui/data/css_tweaks")
    if not ok_ct or type(CssTweaks) ~= "table" then return "" end
    local global = g("style_tweaks", nil, nil) or CssTweaks.DEFAULT_GLOBAL_STYLE_TWEAKS or {}
    local by_id = {}
    local function walk(item)
        if type(item) ~= "table" then return end
        if item.id then
            by_id[item.id] = item
        else
            for _i, it in ipairs(item) do walk(it) end
        end
    end
    walk(CssTweaks)
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local function walkDir(dir)
            if lfs.attributes(dir, "mode") ~= "directory" then return end
            for f in lfs.dir(dir) do
                if f ~= "." and f ~= ".." then
                    local path = dir .. "/" .. f
                    local mode = lfs.attributes(path, "mode")
                    if mode == "directory" then
                        walkDir(path)
                    elseif mode == "file" and f:match("%.css$") and f:sub(1, 2) ~= "._" then
                        by_id[f] = { id = f, priority = 10, css_path = path }
                    end
                end
            end
        end
        walkDir(require("datastorage"):getDataDir() .. "/styletweaks")
    end)
    local tweaks = {}
    for id, on in pairs(global) do
        if on and by_id[id] then tweaks[#tweaks + 1] = by_id[id] end
    end
    table.sort(tweaks, function(l, r)
        local lp, rp = l.priority or 0, r.priority or 0
        if lp ~= rp then return lp < rp end
        return l.id < r.id
    end)
    local out = {}
    for _i, tw in ipairs(tweaks) do
        local css = tw.css
        if not css and tw.css_path then
            local f = io.open(tw.css_path, "r")
            if f then css = f:read("*a"); f:close() end
        end
        css = css and css:match("^%s*(.-)%s*$") or ""
        if css ~= "" then out[#out + 1] = css end
    end
    return table.concat(out, "\n")
end

-- footerHeight(Screen) -> the pixels the reader's status bar takes from the
-- bottom of the page: none when it is off or overlaps the text.
function M.footerHeight(Screen)
    local mode = g("reader_footer_mode", nil, 1)
    local fs = g("footer", nil, {}) or {}
    if mode == 0 or fs.reclaim_height then return 0 end
    local h = Screen:scaleBySize(fs.container_height
        or (G_defaults and G_defaults:readSetting("DMINIBAR_CONTAINER_HEIGHT")) or 7)
    h = h + Screen:scaleBySize(fs.container_bottom_padding or 1)
    return h
end

-- BLOCK_RENDERING_FLAGS in ReaderTypeset, by copt_block_rendering_mode; a
-- book never opened gets 'web' (3).
local BLOCK_FLAGS = { [0] = 0x00000000, 0x03030031, 0x03375131, 0x7FFFFFFF }

-- apply(doc): call between loadDocument() and render().
function M.apply(doc)
    local Screen = require("device").screen
    local function try(name, ...)
        local fn = doc[name]
        if type(fn) == "function" then pcall(fn, doc, ...) end
    end
    local css = g("copt_css", nil, nil)
    if doc.is_fb2 then css = g("copt_fb2_css", nil, nil) end
    try("setStyleSheet", css or doc.default_css, M.tweakCss())
    try("setEmbeddedFonts", g("copt_embedded_fonts", nil, 1))
    try("setEmbeddedStyleSheet", g("copt_embedded_css", nil, 1))
    try("setBlockRenderingFlags", BLOCK_FLAGS[g("copt_block_rendering_mode", nil, 3)] or BLOCK_FLAGS[3])
    try("setRenderDPI", g("copt_render_dpi", nil, 96))
    local face = g("cre_font", nil, nil)
    if face then try("setFontFace", face) end
    try("setFontSize", Screen:scaleBySize(g("copt_font_size", "DCREREADER_CONFIG_DEFAULT_FONT_SIZE", 22)))
    try("setFontBaseWeight", g("copt_font_base_weight", nil, 0))
    try("setFontHinting", g("copt_font_hinting", nil, 2))
    try("setFontKerning", g("copt_font_kerning", nil, 3))
    try("setWordSpacing", g("copt_word_spacing", "DCREREADER_CONFIG_WORD_SPACING_MEDIUM", { 95, 75 }))
    try("setWordExpansion", g("copt_word_expansion", nil, 0))
    try("setCJKWidthScaling", g("copt_cjk_width_scaling", nil, 100))
    try("setInterlineSpacePercent", g("copt_line_spacing", "DCREREADER_CONFIG_LINE_SPACE_PERCENT_MEDIUM", 100))
    try("setStatusLineProp", g("copt_status_line", nil, 1))
    local h = g("copt_h_page_margins", "DCREREADER_CONFIG_H_MARGIN_SIZES_MEDIUM", { 10, 10 })
    local t = g("copt_t_page_margin", "DCREREADER_CONFIG_T_MARGIN_SIZES_LARGE", 15)
    local b = g("copt_b_page_margin", "DCREREADER_CONFIG_B_MARGIN_SIZES_LARGE", 15)
    if type(h) == "table" and tonumber(h[1]) and tonumber(h[2]) and tonumber(t) and tonumber(b) then
        try("setPageMargins", Screen:scaleBySize(h[1]), Screen:scaleBySize(t),
            Screen:scaleBySize(h[2]), Screen:scaleBySize(b) + M.footerHeight(Screen))
    end
end

return M
