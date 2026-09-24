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

-- The status bar's reserve: what the reader adds to the bottom margin for it.
--
-- ReaderTypeset adds footer:getHeight() unless "Overlap status bar"
-- (reclaim_height) is on -- whether the bar is SHOWN or not. Found on a PW5
-- with the bar hidden: the reader's bottom margin was 192, the scan's 166,
-- and the 26 between them was the whole of the last 2-3% page gap. The bar's
-- height depends on more than its settings say (progress bar position,
-- fonts), so the number the reader actually used is recorded whenever
-- bookshelf runs inside one (recordFooter), and the formula below is only
-- for a device that has not opened a book since.
M.FOOTER_KEY = "reader_footer_reserve"

-- recordFooter(ui): from the reader, at ReaderReady.
function M.recordFooter(ui)
    local ok, h = pcall(function()
        local footer = ui.view and ui.view.footer
        if not footer then return nil end
        if footer.reclaim_height or (footer.settings and footer.settings.reclaim_height) then
            return 0
        end
        return footer:getHeight()
    end)
    if not ok or type(h) ~= "number" then return end
    local ok_s, Store = pcall(require, "lib/bookshelf_settings_store")
    if ok_s and Store and Store.read(M.FOOTER_KEY) ~= h then Store.save(M.FOOTER_KEY, h) end
end

-- footerHeight(Screen) -> the pixels the reader reserves at the bottom of the
-- page for its status bar.
function M.footerHeight(Screen)
    local ok_s, Store = pcall(require, "lib/bookshelf_settings_store")
    local seen = ok_s and Store and Store.read(M.FOOTER_KEY)
    if type(seen) == "number" then return seen end
    local fs = g("footer", nil, {}) or {}
    if fs.reclaim_height then return 0 end
    local h = Screen:scaleBySize(fs.container_height
        or (G_defaults and G_defaults:readSetting("DMINIBAR_CONTAINER_HEIGHT")) or 7)
    h = h + Screen:scaleBySize(fs.container_bottom_padding or 1)
    return h
end

-- BLOCK_RENDERING_FLAGS in ReaderTypeset, by copt_block_rendering_mode; a
-- book never opened gets 'web' (3).
local BLOCK_FLAGS = { [0] = 0x00000000, 0x03030031, 0x03375131, 0x7FFFFFFF }

-- The reader's language for hyphenation and line breaking: a default the
-- reader chose (Hold in the language menu) wins; otherwise the book's own
-- language; otherwise the reader's fallback, then en-US. ReaderTypography
-- onReadSettings + onPreRenderDocument.
--
-- Before the document loads there is no book language to read, so the
-- reader sets default / fallback / en-US then, and switches to the book's own
-- at pre-render (bookLang) only when no default was chosen.
function M.presetLang()
    return g("text_lang_default", nil, nil) or g("text_lang_fallback", nil, nil) or "en-US"
end

function M.bookLang(doc)
    if g("text_lang_default", nil, nil) then return nil end
    local book_lang
    pcall(function()
        local props = doc.getProps and doc:getProps()
        local lang = props and props.language
        if type(lang) == "string" and lang ~= "" then
            local ok_t, RT = pcall(require, "apps/reader/modules/readertypography")
            book_lang = (ok_t and RT and RT.fixLangTag) and RT.fixLangTag(RT, lang) or lang
        end
    end)
    return book_lang
end

function M.textLang(doc)
    local default = g("text_lang_default", nil, nil)
    if default then return default end
    local book_lang
    pcall(function()
        local props = doc.getProps and doc:getProps()
        local lang = props and props.language
        if type(lang) == "string" and lang ~= "" then
            local ok_t, RT = pcall(require, "apps/reader/modules/readertypography")
            book_lang = (ok_t and RT and RT.fixLangTag) and RT.fixLangTag(RT, lang) or lang
        end
    end)
    return book_lang or g("text_lang_fallback", nil, nil) or "en-US"
end

-- The font-family faces (serif, sans-serif, monospace...): the reader's own
-- mapping, and FreeSerif for maths when none is set, as ReaderFont does.
function M.familyFonts()
    local map = {}
    for k, v in pairs(g("cre_font_family_fonts", nil, {}) or {}) do map[k] = v end
    if map.math == nil then map.math = "FreeSerif" end
    return map
end

-- LuaSettings' isTrue / nilOrTrue, through readSetting alone.
local function isTrue(key) return g(key, nil, nil) == true end
local function nilOrTrue(key)
    local v = g(key, nil, nil)
    return v == nil or v == true
end

-- The reader's order, which is also the fast one: ReaderUI applies every
-- module's settings BEFORE loadDocument (in a post-init callback) and only the
-- book's language after it (PreRenderDocument). Settings changed after the
-- load make crengine redo its style work -- on a PW5 that cost 2s a book.
--
--   doc = DocumentRegistry:openDocument(fp)
--   Layout.beforeLoad(doc); doc:loadDocument(); Layout.afterLoad(doc)
--   doc:render()
--
-- Verified call for call against a real open, on the desktop rig and on a
-- PW5 (every CreDocument setter logged on both sides); the counts then match.
function M.beforeLoad(doc)
    M._apply(doc, M.presetLang())
end

function M.afterLoad(doc)
    local lang = M.bookLang(doc)
    if lang and lang ~= M.presetLang() and type(doc.setTextMainLang) == "function" then
        pcall(doc.setTextMainLang, doc, lang)
    end
end

-- apply(doc): everything at once, on a document already loaded. Slower than
-- beforeLoad + afterLoad; kept for callers that only have a loaded document.
function M.apply(doc)
    M._apply(doc, M.textLang(doc))
end

function M._apply(doc, text_lang)
    local Screen = require("device").screen
    local function try(name, ...)
        local fn = doc[name]
        if type(fn) == "function" then pcall(fn, doc, ...) end
    end
    -- crengine's defaults as the reader starts from them: DPI-adjusted font
    -- sizes, fallback fonts, monospace scaling (ReaderUI, before the modules).
    try("setupDefaultView")
    try("setViewMode", "page")
    local css = g("copt_css", nil, nil)
    if doc.is_fb2 then css = g("copt_fb2_css", nil, nil) end
    try("setStyleSheet", css or doc.default_css, M.tweakCss())
    try("setEmbeddedFonts", g("copt_embedded_fonts", nil, 1))
    try("setEmbeddedStyleSheet", g("copt_embedded_css", nil, 1))
    try("setBlockRenderingFlags", BLOCK_FLAGS[g("copt_block_rendering_mode", nil, 3)] or BLOCK_FLAGS[3])
    try("setRenderDPI", g("copt_render_dpi", nil, 96))
    try("setFontFace", g("cre_font", nil, nil) or doc.default_font)
    try("setFontSize", Screen:scaleBySize(g("copt_font_size", "DCREREADER_CONFIG_DEFAULT_FONT_SIZE", 22)))
    try("setFontBaseWeight", g("copt_font_base_weight", nil, 0))
    try("setFontHinting", g("copt_font_hinting", nil, 2))
    try("setFontKerning", g("copt_font_kerning", nil, 3))
    try("setWordSpacing", g("copt_word_spacing", "DCREREADER_CONFIG_WORD_SPACING_MEDIUM", { 95, 75 }))
    try("setWordExpansion", g("copt_word_expansion", nil, 0))
    try("setCJKWidthScaling", g("copt_cjk_width_scaling", nil, 100))
    try("setInterlineSpacePercent", g("copt_line_spacing", "DCREREADER_CONFIG_LINE_SPACE_PERCENT_MEDIUM", 100))
    try("setFontFamilyFontFaces", M.familyFonts(), isTrue("cre_font_family_ignore_font_names"))
    -- Typography: hyphenation above all, which decides how much of a line a
    -- word may fill (ReaderTypography).
    try("setTextEmbeddedLangs", nilOrTrue("text_lang_embedded_langs"))
    try("setTextHyphenation", nilOrTrue("hyphenation"))
    try("setTrustSoftHyphens", isTrue("hyph_trust_soft_hyphens"))
    try("setTextHyphenationSoftHyphensOnly", isTrue("hyph_soft_hyphens_only"))
    try("setTextHyphenationForceAlgorithmic", isTrue("hyph_force_algorithmic"))
    try("setHyphLeftHyphenMin", g("hyph_left_hyphen_min", nil, 0))
    try("setHyphRightHyphenMin", g("hyph_right_hyphen_min", nil, 0))
    try("setFloatingPunctuation", isTrue("floating_punctuation") and 1 or 0)
    try("setTextMainLang", text_lang)
    -- ReaderRolling: one page at a time, and non-linear flows as the reader
    -- shows them.
    try("setVisiblePageCount", 1)
    try("setHideNonlinearFlows", isTrue("hide_nonlinear_flows"))
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
