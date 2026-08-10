-- lib/bookshelf_changelog.lua
-- Cached, browsable release notes. The update-check dialog shows notes once
-- and they're gone; this keeps them revisitable: releases are cached in
-- their own settings file (seeded for free whenever the updater fetches the
-- releases list, or fetched on demand from the Updates menu), and show()
-- pages through them one release per screen, Newer/Older.
--
-- Network is USER-INITIATED only: opening the viewer with an empty cache
-- fetches (behind runWhenOnline, with a toast); a populated cache renders
-- instantly and offline, with a Refresh button for pulling newer entries.

local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local M = {}

-- Bounds. MAX_RELEASES covers a year-plus of this repo's cadence; MAX_BODY
-- keeps one pathological release from bloating the settings file.
M.MAX_RELEASES = 25
M.MAX_BODY     = 8 * 1024

local _store
local function store()
    _store = _store or require("lib/bookshelf_file_store").new("bookshelf_changelog.lua")
    return _store
end

-- Markdown -> plain text for TextViewer, same rules the update dialog uses.
function M.stripMarkdown(text)
    text = tostring(text or "")
    text = text:gsub("#+%s*", "")          -- heading markers
    text = text:gsub("%*%*(.-)%*%*", "%1") -- bold
    text = text:gsub("%*(.-)%*", "%1")     -- italic
    text = text:gsub("`(.-)`", "%1")       -- inline code
    return text
end

-- seed(releases) -> n_stored
-- Normalise a GitHub /releases payload into the cache: skip drafts,
-- prereleases and malformed entries, keep newest-first order, dedupe by tag
-- (first occurrence wins - the payload is newest-first), cap count and body
-- size. Total replacement, not a merge: the payload IS the canonical list.
function M.seed(releases)
    if type(releases) ~= "table" then return 0 end
    local out, seen = {}, {}
    for _i, rel in ipairs(releases) do
        if type(rel) == "table" and not rel.draft and not rel.prerelease
                and type(rel.tag_name) == "string" and rel.tag_name ~= "" then
            local tag = rel.tag_name
            if not seen[tag] then
                seen[tag] = true
                out[#out + 1] = {
                    tag  = tag,
                    date = type(rel.published_at) == "string"
                           and rel.published_at:sub(1, 10) or nil,
                    body = tostring(rel.body or ""):sub(1, M.MAX_BODY),
                }
                if #out >= M.MAX_RELEASES then break end
            end
        end
    end
    if #out == 0 then return 0 end
    local s = store()
    s.saveDeferred("releases", out)
    s.save("fetched_at", os.time())
    return #out
end

function M.cached()
    local rels = store().read("releases")
    return (type(rels) == "table" and #rels > 0) and rels or nil
end

-- One release as viewer text: "v3.11.1 - 2026-08-03" headline + stripped body.
function M.format(rel)
    if type(rel) ~= "table" then return "" end
    local head = "v" .. tostring(rel.tag or ""):gsub("^v", "")
    if rel.date then head = head .. "  (" .. rel.date .. ")" end
    local body = M.stripMarkdown(rel.body)
    body = body:match("^%s*(.-)%s*$") or ""
    if body == "" then body = _("(no notes for this release)") end
    return head .. "\n\n" .. body
end

-- Fetch the releases list (blocking, like every updater call - hence the
-- toast) and reseed the cache. cb(releases|nil) runs on completion.
function M.fetch(cb)
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr  = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{
            text = _("Fetching changelog..."), timeout = 1,
        })
        UIManager:scheduleIn(0.1, function()
            local Updater = require("lib/bookshelf_updater")
            local releases = require("lib/bookshelf_http").getJSON(
                "https://api.github.com/repos/AndyHazz/bookshelf.koplugin/releases",
                {
                    user_agent = "KOReader-Bookshelf/" .. Updater.getInstalledVersion(),
                    accept     = "application/vnd.github.v3+json",
                    curl_max_time = 20,
                })
            if type(releases) == "table" then M.seed(releases) end
            if cb then cb(M.cached()) end
        end)
    end)
end

-- The paginated viewer. idx 1 = newest. Buttons: Newer / Older page through;
-- Refresh re-fetches (kept subordinate - cache-first is the point).
local function showAt(rels, idx)
    local UIManager  = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local function repage(new_idx)
        UIManager:close(viewer)
        showAt(rels, new_idx)
    end
    -- Timeline layout: older releases sit to the LEFT (back in time), newer
    -- to the right. Chevrons (U+2039/203A) rather than triangles - the
    -- chip bar's Nerd-font chevrons don't render in a stock TextViewer
    -- button, and these carry the same shape in the standard UI font.
    local buttons = {
        {
            {
                text    = "\xE2\x80\xB9 " .. _("Older"),
                enabled = idx < #rels,
                callback = function() repage(idx + 1) end,
            },
            {
                text    = _("Newer") .. " \xE2\x80\xBA",
                enabled = idx > 1,
                callback = function() repage(idx - 1) end,
            },
        },
        {
            {
                text = _("Refresh"),
                callback = function()
                    UIManager:close(viewer)
                    M.fetch(function(fresh)
                        if fresh then showAt(fresh, 1) end
                    end)
                end,
            },
            {
                text = _("Close"),
                callback = function() UIManager:close(viewer) end,
            },
        },
    }
    viewer = TextViewer:new{
        title = T(_("Changelog (%1 of %2)"), idx, #rels),
        text  = M.format(rels[idx]),
        buttons_table = buttons,
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

function M.show()
    local rels = M.cached()
    if rels then
        showAt(rels, 1)
        return
    end
    M.fetch(function(fresh)
        if fresh then
            showAt(fresh, 1)
        else
            local UIManager = require("ui/uimanager")
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Could not fetch the changelog."), timeout = 3,
            })
        end
    end)
end

return M
