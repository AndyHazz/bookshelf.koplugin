local _ = require("lib/bookshelf_i18n").gettext
return {
    -- `name` removed -- deprecated in koreader/koreader#15096; the
    -- PluginLoader now uses the directory name ("bookshelf" here)
    -- for enabled/disabled tracking. Setting `name` here triggers a
    -- WARN on every plugin load in nightly builds.
    fullname = _("Bookshelf"),
    description = _([[A nice-looking home screen for KOReader: pick a book from your shelf and read it.]]),
    version = "3.3.3",
}
