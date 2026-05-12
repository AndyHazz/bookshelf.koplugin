local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("bookshelf_i18n").gettext

local Updater = {}
local GITHUB_REPO = "komadorirobin/bookshelf.koplugin"
local RELEASES_URL = "https://github.com/" .. GITHUB_REPO .. "/releases"
local API_REPO_BASE = "https://api.github.com/repos/" .. GITHUB_REPO

-- Background check state (session-only, not persisted)
local _cached_version = nil   -- latest available version string, or nil
local _cached_zip_url = nil   -- download URL for the latest release ZIP
local _last_check_time = nil  -- os.time() of last successful or attempted check
local _check_in_flight = false
local CHECK_INTERVAL = 3600   -- 1 hour

function Updater.getInstalledVersion()
    local DataStorage = require("datastorage")
    local meta_path = DataStorage:getDataDir() .. "/plugins/bookshelf.koplugin/_meta.lua"
    local ok_meta, meta = pcall(dofile, meta_path)
    return (ok_meta and meta and meta.version) or "unknown"
end

local function parseVersion(v)
    local parts = {}
    for part in tostring(v):gsub("^v", ""):gmatch("([^.]+)") do
        table.insert(parts, tonumber(part) or 0)
    end
    return parts
end

local function isNewer(v1, v2)
    local a, b = parseVersion(v1), parseVersion(v2)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

--- Compose the GitHub branch-archive URL for a given branch name.
-- Branch path is URL-encoded except for alnum, dash, underscore, dot, tilde
-- and forward slash (so feature/foo keeps its slash). Uses the public
-- api.github.com zipball endpoint.
function Updater.composeBranchUrl(branch)
    local encoded = branch:gsub("[^%w%-_/.~]", function(c)
        return string.format("%%%02X", c:byte())
    end)
    return string.format(
        API_REPO_BASE .. "/zipball/%s",
        encoded)
end

--- Try LuaSocket first, fall back to curl for platforms where SSL crashes.
local function httpGetJSON(url, user_agent)
    local json = require("json")
    local ok_require, http, ltn12, socket, socketutil =
        pcall(function()
            return require("socket/http"),
                   require("ltn12"),
                   require("socket"),
                   require("socketutil")
        end)
    if ok_require then
        local body = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local c = socket.skip(1, http.request({
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = user_agent,
                    ["Accept"]     = "application/vnd.github.v3+json",
                },
                sink = ltn12.sink.table(body),
                redirect = true,
            }))
            socketutil:reset_timeout()
            return c
        end)
        if ok_req and code == 200 then
            local ok, data = pcall(json.decode, table.concat(body))
            if ok then return data end
        end
        pcall(function() socketutil:reset_timeout() end)
    end
    -- Fallback: curl (available on Android, desktop)
    local handle = io.popen(string.format(
        "curl -s -L -H 'User-Agent: KOReader-Bookshelf' -H 'Accept: application/vnd.github.v3+json' %q",
        url))
    if handle then
        local body = handle:read("*a")
        handle:close()
        if body and body ~= "" then
            local ok, data = pcall(json.decode, body)
            if ok then return data end
        end
    end
    return nil
end

function Updater.offerReleasesPage(message)
    local url = RELEASES_URL
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text = message .. "\n\n" .. _("Open the releases page in a browser?"),
            ok_text = _("Open"),
            ok_callback = function()
                Device:openLink(url)
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = 3,
        })
    end
end

--- Return the available update version and zip URL, or nil if none/not checked.
function Updater.getAvailableUpdate()
    return _cached_version, _cached_zip_url
end

--- Fire a silent background update check if the cache is stale (>1h or never checked).
-- Results available via getAvailableUpdate().
-- @param on_update_found function(version): optional callback when a new version is discovered
function Updater.checkBackground(on_update_found)
    if _check_in_flight then return end
    local now = os.time()
    if _last_check_time and (now - _last_check_time) < CHECK_INTERVAL then return end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then return end

    _check_in_flight = true
    _last_check_time = now

    UIManager:scheduleIn(0.1, function()
        local installed_version = Updater.getInstalledVersion()
        local user_agent = "KOReader-Bookshelf/" .. installed_version

        -- Only fetch the latest release (lightweight)
        local release = httpGetJSON(
            API_REPO_BASE .. "/releases/latest",
            user_agent)

        _check_in_flight = false

        if not release or not release.tag_name then return end
        if release.draft or release.prerelease then return end

        local ver = release.tag_name:gsub("^v", "")
        if isNewer(ver, installed_version) then
            _cached_version = ver
            _cached_zip_url = nil
            if release.assets then
                for _, asset in ipairs(release.assets) do
                    if asset.name:match("%.zip$") then
                        _cached_zip_url = asset.browser_download_url
                        break
                    end
                end
            end
            if on_update_found then
                on_update_found(ver)
            end
        else
            _cached_version = nil
            _cached_zip_url = nil
        end
    end)
end

function Updater.check(on_success)

    local installed_version = Updater.getInstalledVersion()

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then
        UIManager:show(InfoMessage:new{
            text = _("Wi-Fi is not enabled."),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Checking for updates..."),
        timeout = 1,
    })

    UIManager:scheduleIn(0.1, function()
        local user_agent = "KOReader-Bookshelf/" .. installed_version

        -- Fetch all releases to gather notes between installed and latest
        local releases = httpGetJSON(
            API_REPO_BASE .. "/releases",
            user_agent)
        if not releases or #releases == 0 then
            Updater.offerReleasesPage(_("Could not check for updates."))
            return
        end

        -- Collect releases newer than installed version
        local new_releases = {}
        local latest_zip_url
        for _, rel in ipairs(releases) do
            if rel.draft or rel.prerelease then goto continue end
            local ver = rel.tag_name:gsub("^v", "")
            if isNewer(ver, installed_version) then
                table.insert(new_releases, rel)
                -- Find ZIP asset from the newest release
                if not latest_zip_url and rel.assets then
                    for _, asset in ipairs(rel.assets) do
                        if asset.name:match("%.zip$") then
                            latest_zip_url = asset.browser_download_url
                            break
                        end
                    end
                end
            end
            ::continue::
        end

        -- Update the background cache too
        _last_check_time = os.time()
        if #new_releases > 0 then
            _cached_version = new_releases[1].tag_name:gsub("^v", "")
            _cached_zip_url = latest_zip_url
        else
            _cached_version = nil
            _cached_zip_url = nil
        end

        if #new_releases == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Bookshelf is up to date.") .. "\n\n" ..
                    _("Version: ") .. "v" .. installed_version,
                timeout = 3,
            })
            return
        end

        -- Build combined release notes (newest first)
        local latest_version = new_releases[1].tag_name:gsub("^v", "")
        local function stripMarkdown(text)
            text = text:gsub("#+%s*", "")        -- strip heading markers
            text = text:gsub("%*%*(.-)%*%*", "%1") -- strip bold
            text = text:gsub("%*(.-)%*", "%1")     -- strip italic
            text = text:gsub("`(.-)`", "%1")       -- strip inline code
            return text
        end
        local notes = {}
        for _, rel in ipairs(new_releases) do
            local header = "v" .. rel.tag_name:gsub("^v", "")
            local body = stripMarkdown(rel.body or "")
            table.insert(notes, header .. "\n" .. body)
        end
        local all_notes = table.concat(notes, "\n\n")

        local TextViewer = require("ui/widget/textviewer")
        local viewer
        local buttons = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
                {
                    text = _("Update and restart"),
                    callback = function()
                        UIManager:close(viewer)
                        if not latest_zip_url then
                            UIManager:show(InfoMessage:new{
                                text = _("No download available for this release."),
                                timeout = 3,
                            })
                            return
                        end
                        Updater.install(latest_zip_url, installed_version, latest_version, on_success)
                    end,
                },
            },
        }
        viewer = TextViewer:new{
            title = _("Update available!"),
            text = _("Installed: ") .. "v" .. installed_version .. "\n" ..
                _("Latest: ") .. "v" .. latest_version .. "\n\n" ..
                all_notes,
            buttons_table = buttons,
            add_default_buttons = false,
        }
        UIManager:show(viewer)
    end)
end

function Updater.install(zip_url, old_version, new_version, on_success, error_label)

    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")

    UIManager:show(InfoMessage:new{
        text = _("Downloading update..."),
        timeout = 1,
    })

    UIManager:scheduleIn(0.1, function()
        -- Download ZIP to temp location
        local cache_dir = DataStorage:getSettingsDir() .. "/bookshelf_cache"
        if lfs.attributes(cache_dir, "mode") ~= "directory" then
            lfs.mkdir(cache_dir)
        end
        local zip_path = cache_dir .. "/bookshelf.koplugin.zip"

        -- Try LuaSocket first, fall back to curl
        local downloaded = false
        local ok_require, http, ltn12, socket, socketutil =
            pcall(function()
                return require("socket/http"),
                       require("ltn12"),
                       require("socket"),
                       require("socketutil")
            end)
        if ok_require then
            local file = io.open(zip_path, "wb")
            if file then
                local ok_dl, code = pcall(function()
                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                    local c = socket.skip(1, http.request({
                        url = zip_url,
                        method = "GET",
                        headers = {
                            ["User-Agent"] = "KOReader-Bookshelf/" .. old_version,
                        },
                        sink = ltn12.sink.file(file),
                        redirect = true,
                    }))
                    socketutil:reset_timeout()
                    return c
                end)
                if not ok_dl then
                    pcall(function() socketutil:reset_timeout() end)
                end
                downloaded = ok_dl and code == 200
            end
        end
        -- Fallback: curl (available on Android, desktop). The -f flag makes
        -- curl exit non-zero on HTTP errors (e.g. 404 for a missing branch);
        -- without it, curl would write the 404 HTML body to the zip file and
        -- the unpack step would surface a misleading "extracting failed".
        if not downloaded then
            pcall(os.remove, zip_path)
            local ret = os.execute(string.format(
                "curl -sfL -o %q %q", zip_path, zip_url))
            downloaded = ret == 0 or ret == true
        end
        if not downloaded then
            pcall(os.remove, zip_path)
            if error_label then
                UIManager:show(InfoMessage:new{
                    text = error_label,
                    timeout = 3,
                })
            else
                Updater.offerReleasesPage(_("Download failed."))
            end
            return
        end

        -- Extract to plugin directory (strip root folder from ZIP)
        local plugin_path = DataStorage:getDataDir() .. "/plugins/bookshelf.koplugin"
        local ok, err = Device:unpackArchive(zip_path, plugin_path, true)
        pcall(os.remove, zip_path)

        if not ok then
            UIManager:show(InfoMessage:new{
                text = error_label or (_("Installation failed: ") .. tostring(err)),
                timeout = 5,
            })
            return
        end

        -- Stamp install context (e.g. last_install_source) before the restart
        -- prompt fires; runs only when unpack succeeded.
        if on_success then
            local ok_cb = pcall(on_success)
            if not ok_cb then
                -- Don't let a misbehaving callback abort the restart prompt.
            end
        end

        -- Restart KOReader to load the new version
        UIManager:show(ConfirmBox:new{
            text = _("Bookshelf updated to v") .. new_version .. ".\n\n" ..
                _("Restart KOReader now?"),
            ok_text = _("Restart"),
            ok_callback = function()
                UIManager:restartKOReader()
            end,
        })
    end)
end

--- Install from a GitHub branch's archive zip.
-- Same install pipeline as the release path; just composes a different URL.
-- @param branch string: branch name (e.g. "feature/v5.2-test")
-- @param on_success function or nil: fired after successful unpack
function Updater.installBranch(branch, on_success)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then
        UIManager:show(InfoMessage:new{
            text = _("Wi-Fi is not enabled."),
            timeout = 3,
        })
        return
    end

    local installed_version = Updater.getInstalledVersion()
    local zip_url = Updater.composeBranchUrl(branch)
    local error_label = _("Could not install branch:") .. " " .. branch
    Updater.install(zip_url, installed_version, "branch:" .. branch, on_success, error_label)
end

--- Install the latest stable (non-prerelease) release, regardless of installed version.
-- Used by the "Reset to latest stable release" entry: even when on a branch whose
-- _meta.lua reports a higher version than the current release, we still want to
-- pull the release zip and re-stamp last_install_source = "release".
-- @param on_success function or nil: fired after successful unpack
function Updater.installLatestStable(on_success)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then
        UIManager:show(InfoMessage:new{
            text = _("Wi-Fi is not enabled."),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Downloading latest release..."),
        timeout = 1,
    })

    UIManager:scheduleIn(0.1, function()
        local installed_version = Updater.getInstalledVersion()
        local user_agent = "KOReader-Bookshelf/" .. installed_version
        local release = httpGetJSON(
            API_REPO_BASE .. "/releases/latest",
            user_agent)
        if not release or not release.tag_name or release.draft or release.prerelease then
            Updater.offerReleasesPage(_("Could not fetch latest release."))
            return
        end
        local zip_url
        if release.assets then
            for _, asset in ipairs(release.assets) do
                if asset.name:match("%.zip$") then
                    zip_url = asset.browser_download_url
                    break
                end
            end
        end
        if not zip_url then
            Updater.offerReleasesPage(_("Latest release has no downloadable zip."))
            return
        end
        local new_version = release.tag_name:gsub("^v", "")
        Updater.install(zip_url, installed_version, new_version, on_success)
    end)
end

return Updater
