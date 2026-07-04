local _ = require("lib/bookshelf_i18n").gettext
return {
    -- KEEP `name`, equal to the .koplugin directory id ("bookshelf"). Do not
    -- remove again, even though current KOReader deprecates it (koreader#15096:
    -- nightly logs a harmless "name in _meta.lua is deprecated" WARN and keys
    -- enable/disable off the directory id instead).
    --
    -- Why it's load-bearing on stable releases (confirmed v2025.10, before the
    -- ~2026-04 directory-id normalisation): the PluginLoader loads a DISABLED
    -- plugin from its _meta.lua, NOT main.lua. The plugin-manager "enable" toggle
    -- then keys plugins_disabled by that loaded name. With no name in _meta, the
    -- loader falls back to a path match (e.g. "mnt/.../bookshelf"), so enabling
    -- clears the wrong key and never removes plugins_disabled["bookshelf"] (the
    -- directory-id key discovery actually checks) -- the plugin stays stuck
    -- disabled. (Disabling works regardless, because an ENABLED plugin loads
    -- main.lua, which does carry name = "bookshelf".) name in _meta restores the
    -- correct key for the disabled-load path; tests/_test_meta.lua guards it.
    name = "bookshelf",
    fullname = _("Bookshelf"),
    description = _([[A nice-looking home screen for KOReader: pick a book from your shelf and read it.]]),
    version = "3.8.2",
}
