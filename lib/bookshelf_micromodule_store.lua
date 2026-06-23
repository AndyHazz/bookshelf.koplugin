-- bookshelf_micromodule_store.lua
--
-- The micro-module data file (<datadir>/settings/bookshelf_micromodules.lua),
-- kept separate from the main bookshelf.lua so module prefs + caches don't
-- bloat it or get rewritten on every preference save. See bookshelf_file_store
-- for the mechanism.
--
-- Data lands here two ways:
--   * Transparently: bookshelf_settings_store routes any "micromodule_*" key
--     here (relocating pre-existing ones once).
--   * The clean API: lib/bookshelf_module_kit.moduleStore(key) namespaces a
--     per-module handle over these keys.

return require("lib/bookshelf_file_store").new("bookshelf_micromodules.lua")
