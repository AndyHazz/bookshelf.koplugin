local Device = require("device")
local Settings = require("lib/bookshelf_settings_store")
local logger = require("logger")
local _ = require("lib/bookshelf_i18n").gettext

local SleepScreen = {}
local Screen = Device.screen
local mode_key = "sleep_screen_view"
local quote_key = "sleep_screen_rotate_quote"
local vocab_key = "sleep_screen_rotate_vocab"
local installed = false
local quote_index = 0
local last_home
local home_rotation

local function viewMode()
    return Settings.read(mode_key, Settings.isTrue("use_as_sleep_screen") and "dashboard" or "off")
end

local function matchesScreen(shelf)
    return shelf and shelf._first_paint_done
        and shelf.width == Screen:getWidth() and shelf.height == Screen:getHeight()
end

local function renderHome(shelf)
    local image = shelf._screenLike(Screen:getWidth(), Screen:getHeight())
    local ok, err = pcall(shelf._paintWhole, shelf, image, 0, 0)
    if not ok then
        image:free()
        error(err, 0)
    end
    return image
end

function SleepScreen.rememberHome(shelf)
    if not installed or viewMode() ~= "home" or not matchesScreen(shelf) then return end
    local ok, image = pcall(renderHome, shelf)
    if not ok then
        logger.warn("[bookshelf] could not save the home sleep screen:", image)
        return
    end
    if last_home then last_home:free() end
    last_home = image
    home_rotation = Screen:getRotationMode()
end

local function homeImage(shelf)
    if matchesScreen(shelf) then return renderHome(shelf) end
    if last_home and home_rotation == Screen:getRotationMode()
            and last_home:getWidth() == Screen:getWidth()
            and last_home:getHeight() == Screen:getHeight()
            and last_home:getInverse() == Screen.bb:getInverse() then
        return last_home:copy()
    end
end

local function renderDashboard(shelf)
    local BookshelfWidget = require("lib/bookshelf_widget")
    local screen = Device.screen
    local context = {
        _currentHeroBook = BookshelfWidget._currentHeroBook,
        _buildDeviceState = BookshelfWidget._buildDeviceState,
        _sleep_rotation = { vocab = Settings.isTrue(vocab_key) },
    }
    if Settings.isTrue(quote_key) then
        quote_index = quote_index + 1
        context._sleep_rotation.quote_index = quote_index
    end
    if shelf and shelf.width == screen:getWidth() and shelf.height == screen:getHeight() then
        -- The dashboard writes its own grid state. Reuse the shelf's appearance
        -- without registering the sleep view on the live shelf.
        context._wallpaperWidget = BookshelfWidget._wallpaperWidgetRaw
        setmetatable(context, { __index = shelf })
    end
    return require("lib/bookshelf_micro_fullscreen").renderSnapshot(context)
end

function SleepScreen.install(getShelf)
    if installed or not Device:supportsScreensaver() then return end
    installed = true
    local Screensaver = require("ui/screensaver")
    local original_setup = Screensaver.setup
    local original_expects_portrait = Screensaver.modeExpectsPortrait

    function Screensaver:setup(event, event_message)
        self.bookshelf_sleep_active = nil
        original_setup(self, event, event_message)
        local mode = viewMode()
        if event or not self.ui or mode == "off" then return end
        if self.ui.doc_settings and self.ui.doc_settings:isTrue("exclude_screensaver") then return end

        local render = mode == "home" and homeImage or renderDashboard
        local ok, image = pcall(render, getShelf())
        if not ok then
            logger.warn("[bookshelf] sleep screen could not prepare an image:", image)
            return
        end
        if not image then return end

        -- Keep KOReader's image widget, unlock handling and wake repaint.
        self.bookshelf_sleep_active = true
        self.screensaver_type = "random_image"
        self.screensaver_background = "none"
        self.image_file = nil
        self.image = image
    end

    function Screensaver:modeExpectsPortrait()
        if self.bookshelf_sleep_active and self.image then return false end
        return original_expects_portrait(self)
    end
end

local function selectView(mode)
    Settings.save(mode_key, mode)
    if mode ~= "home" and last_home then
        last_home:free()
        last_home = nil
    end
end

local function viewItem(text, mode)
    return {
        text = text,
        help_text = _("If this view is unavailable, KOReader uses the last standard wallpaper you selected."),
        checked_func = function() return viewMode() == mode end,
        radio = true,
        callback = function() selectView(mode) end,
    }
end

local function useStandardWallpaper(item)
    local checked = item.checked_func
    local select_wallpaper = item.callback
    item.checked_func = function()
        return viewMode() == "off" and checked()
    end
    item.callback = function(...)
        if viewMode() ~= "off" then selectView("off") end
        return select_wallpaper(...)
    end
end

local function rotationItem(text, key)
    return {
        text = text,
        enabled_func = function() return viewMode() == "dashboard" end,
        checked_func = function() return Settings.isTrue(key) end,
        callback = function() Settings.save(key, not Settings.isTrue(key)) end,
    }
end

function SleepScreen.addToMainMenu(menu_items)
    if not installed then return end
    local sleep_menu = menu_items.screensaver
    local wallpaper = sleep_menu and sleep_menu.sub_item_table[1].sub_item_table
    if not wallpaper then return end

    local last_standard_choice = 0
    for index, item in ipairs(wallpaper) do
        if item.radio and item.checked_func and item.callback then
            useStandardWallpaper(item)
            last_standard_choice = index
        end
    end
    table.insert(wallpaper, last_standard_choice + 1, {
        text = _("Bookshelf dashboard options"),
        enabled_func = function() return viewMode() == "dashboard" end,
        sub_item_table = {
            rotationItem(_("New dashboard quote each sleep"), quote_key),
            rotationItem(_("New dashboard vocabulary word each sleep"), vocab_key),
        },
        separator = true,
    })
    table.insert(wallpaper, 1, viewItem(_("Bookshelf dashboard"), "dashboard"))
    table.insert(wallpaper, 1, viewItem(_("Bookshelf home"), "home"))
end

return SleepScreen
