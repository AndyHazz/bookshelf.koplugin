-- Headless tests for lib/bookshelf_kindle_source.lua — the bridge that surfaces
-- the Kindle native library (kaikozlov/kindle.koplugin) as a Bookshelf shelf.
--
-- The module reads Amazon's own catalogue (/var/local/cc.db) directly and only
-- touches the plugin to OPEN a book (KFX->EPUB conversion + DRM). Both of those
-- are injected here (M._query / M._plugin / M._fileExists / M._sidecar), so no
-- Kindle hardware, no SQLite and no plugin are needed to run this.
package.path = "./?.lua;./?/init.lua;" .. package.path

local M = dofile("lib/bookshelf_kindle_source.lua")
-- The REAL _sidecar, captured before reset() swaps in the injection stub. Every
-- other test replaces that seam, so without this the actual sidecar read is
-- never exercised and could stop reading the rating unnoticed.
local REAL_SIDECAR = M._sidecar
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- Build lua-ljsqlite3's COLUMNAR result shape (results[column][row], nrow) from
-- a plain list of row tables, so the tests exercise the same indexing the real
-- query path does rather than a friendlier shape invented for testing.
local function fakeQuery(rows)
    return function()
        local cols = {}
        for i, row in ipairs(rows) do
            for k, v in pairs(row) do
                cols[k] = cols[k] or {}
                cols[k][i] = v
            end
        end
        return cols, #rows
    end
end

-- One local, non-archived KFX book as cc.db actually returns it.
local function ccRow(over)
    local row = {
        p_uuid             = "00000000-1111-2222-3333-444444444444",
        p_location         = "/mnt/us/documents/Goldratt/The Goal.kfx",
        p_titles_0_nominal = "The Goal: A Process of Ongoing Improvement",
        j_credits          = '[{"name":{"display":"Goldratt, Eliyahu M."},"kind":"Author"}]',
        p_mimeType         = "application/x-kfx-ebook",
        p_cdeKey           = "B002LHRM2O",
        p_isDRMProtected   = 0,
        p_diskUsage        = 1613748,
        p_contentSize      = 1613748,
        p_thumbnail        = "/mnt/us/system/thumbnails/thumbnail_B002LHRM2O_EBOK_portrait.jpg",
        p_percentFinished  = 88.60803,
        p_publisher        = "Fourth Estate",
        p_languages_0      = "en-GB",
        p_lastAccess       = 1665491913,
    }
    for k, v in pairs(over or {}) do
        if v == "\0nil" then row[k] = nil else row[k] = v end
    end
    return row
end

-- A stand-in for the plugin's lua/open_file_ext singleton: main.lua wires
-- .virtual_library / .cache_manager onto it at init, and prepareKnownKindlePath
-- is the one call we make (conversion, DRM, freshness, its own progress UI).
local function fakePlugin(opts)
    opts = opts or {}
    return {
        prepareKnownKindlePath = function(_self, file)
            if opts.prepare_error then return nil, opts.prepare_error end
            return opts.prepared_path or file
        end,
        virtual_library = opts.virtual_library or {},
        cache_manager = opts.cache_manager or {
            getCachePaths = function(_self, book)
                local safe = (book.id or ""):gsub("[^%w%.%-_]", "_")
                return "/cache/kindle.koplugin/" .. safe .. ".epub"
            end,
        },
    }
end

-- Files that "exist" on the fake device: path -> stat table.
local disk = {}
local function onDisk(path, over)
    local st = { mode = "file", size = 20000, modification = 1700000000 }
    for k, v in pairs(over or {}) do st[k] = v end
    disk[path] = st
    return st
end

-- Reset every injection seam to a known-empty state between tests.
local function reset()
    disk = {}
    M._query = fakeQuery({})
    M._plugin = function() return nil end
    M._stat = function(path) return disk[path] end
    M._sidecar = function() return nil end
    M._magic = function() return nil end
    M._hasProvider = function() return true end
    M.invalidate()
end

-- cc.db readable and the plugin loaded, but NOTHING else on disk.
local function readyBare(rows, plugin_opts, magic)
    reset()
    onDisk(M.CC_DB_PATH)
    M._query = fakeQuery(rows or {})
    M._plugin = function() return fakePlugin(plugin_opts) end
    -- What each file's opening bytes are, for the DRM sniff. Defaults to a
    -- plain MOBI marker so nothing is treated as protected unless a test says so.
    M._magic = function(path) return (magic or {})[path] end
end

-- The normal case: as above, plus each row's source file actually present.
local function ready(rows, plugin_opts, magic)
    readyBare(rows, plugin_opts, magic)
    for _i, r in ipairs(rows or {}) do
        if type(r.p_location) == "string" and r.p_location ~= "" then onDisk(r.p_location) end
    end
end

local function firstBook(rows, plugin_opts, magic)
    ready(rows or { ccRow() }, plugin_opts, magic)
    local books = M.listBooks()
    assert(#books == 1, "expected exactly 1 record, got " .. tostring(#books))
    return books[1]
end

------------------------------------------------------------------------------
-- isAvailable: both halves must be present
------------------------------------------------------------------------------

t.test("isAvailable: false when cc.db is not on this device", function()
    reset()
    M._plugin = function() return fakePlugin() end
    assert(M.isAvailable() == false, "no cc.db -> no Kindle source")
end)

t.test("isAvailable: false when the Kindle plugin is not loaded", function()
    reset()
    -- cc.db is readable, but without the plugin a KFX book cannot be opened at
    -- all, so offering the shelf would only produce dead covers.
    onDisk(M.CC_DB_PATH)
    M._plugin = function() return nil end
    assert(M.isAvailable() == false, "no plugin -> no Kindle source")
end)

t.test("isAvailable: true with cc.db readable and the plugin loaded", function()
    reset()
    onDisk(M.CC_DB_PATH)
    M._plugin = function() return fakePlugin() end
    assert(M.isAvailable() == true)
end)

t.test("isAvailable: false when the plugin's resolver has been renamed away", function()
    reset()
    onDisk(M.CC_DB_PATH)
    -- A future plugin release drops/renames prepareKnownKindlePath: the shape
    -- check must fail closed rather than crash at open time.
    M._plugin = function() return { virtual_library = {}, cache_manager = {} } end
    assert(M.isAvailable() == false, "resolver missing -> unavailable")
end)

t.test("isAvailable: false when cc.db exists but is a directory", function()
    reset()
    onDisk(M.CC_DB_PATH, { mode = "directory" })
    M._plugin = function() return fakePlugin() end
    assert(M.isAvailable() == false, "only a real file counts")
end)

------------------------------------------------------------------------------
-- listBooks: cc.db row -> Bookshelf Book record
------------------------------------------------------------------------------

t.test("listBooks: maps a KFX catalogue row to a Book record", function()
    local thumb = "/mnt/us/system/thumbnails/thumbnail_B002LHRM2O_EBOK_portrait.jpg"
    ready({ ccRow() })
    onDisk(thumb)
    local b = M.listBooks()[1]
    helpers.eq(b.title, "The Goal: A Process of Ongoing Improvement", "title")
    helpers.eq(b.display_title, "The Goal: A Process of Ongoing Improvement", "display_title")
    helpers.eq(b.author, "Goldratt, Eliyahu M.", "author")
    helpers.eq(b.authors, { "Goldratt, Eliyahu M." }, "authors")
    -- UPPERCASE, like every other record: the Format filter compares this
    -- against the value the picker stored, and "kfx" never matched "KFX".
    helpers.eq(b.format, "KFX", "format from the source extension")
    helpers.eq(b.cover_image_path, thumb, "cover comes from p_thumbnail")
    helpers.eq(b.lang, "en-GB", "lang (NOT 'language' -- see buildBookMeta)")
    helpers.eq(b.last_read_time, 1665491913, "last_read_time from p_lastAccess")
    helpers.eq(b.kindle_book_id, "cc:00000000-1111-2222-3333-444444444444", "stable cc.db id")
    helpers.eq(b.is_kindle, true, "marker for the file-op guards")
    helpers.eq(b.attr.size, 1613748, "size from p_diskUsage")
    assert(b.filename == "The Goal.kfx", "filename is the basename, got " .. tostring(b.filename))
end)

t.test("listBooks: never attaches a cover_bb", function()
    -- A synthetic record is painted by the grid cell AND the hero. cover_bb is
    -- one-shot by BIM convention, so two painters would double-free it; only a
    -- plain path string is safe here (see the OPDS note in the repository).
    ready({ ccRow() })
    onDisk("/mnt/us/system/thumbnails/thumbnail_B002LHRM2O_EBOK_portrait.jpg")
    local b = M.listBooks()[1]
    assert(b.cover_bb == nil, "cover_bb must stay nil")
    assert(b.has_cover == nil, "has_cover must stay nil (cover_image_path is the channel)")
end)

t.test("listBooks: ignores Amazon's 'No image available' placeholder", function()
    -- Amazon writes a 1015-byte placeholder graphic as the thumbnail for a book
    -- with no cover art, byte-identical across books. Rendering it shows a grey
    -- "No image available" card where Bookshelf's own placeholder would at least
    -- show the title and author. Real covers on the maintainer's device run
    -- 11187..51896 bytes, so a size floor separates them with room to spare and
    -- costs nothing: the thumbnail is already stat'ed.
    local thumb = "/mnt/us/system/thumbnails/thumbnail_B002LHRM2O_EBOK_portrait.jpg"
    ready({ ccRow() })
    onDisk(thumb, { size = 1015 })
    helpers.eq(M.listBooks()[1].cover_image_path, nil, "placeholder must not be used")
end)

t.test("listBooks: keeps the smallest real cover seen in the wild", function()
    local thumb = "/mnt/us/system/thumbnails/thumbnail_B002LHRM2O_EBOK_portrait.jpg"
    ready({ ccRow() })
    onDisk(thumb, { size = 11187 })
    helpers.eq(M.listBooks()[1].cover_image_path, thumb, "11KB is a real cover")
end)

t.test("listBooks: the cover floor is inclusive at its own threshold", function()
    local thumb = "/mnt/us/system/thumbnails/thumbnail_B002LHRM2O_EBOK_portrait.jpg"
    ready({ ccRow() })
    onDisk(thumb, { size = M.MIN_COVER_BYTES })
    helpers.eq(M.listBooks()[1].cover_image_path, thumb, "at the threshold -> used")
    ready({ ccRow() })
    onDisk(thumb, { size = M.MIN_COVER_BYTES - 1 })
    helpers.eq(M.listBooks()[1].cover_image_path, nil, "below the threshold -> dropped")
end)

t.test("listBooks: no cover when the thumbnail jpg is not on disk", function()
    -- 5 of 111 books on the maintainer's device have a catalogue thumbnail path
    -- whose file is missing; those must fall back to the placeholder, not to a
    -- broken image path.
    ready({ ccRow() })
    local b = M.listBooks()[1]
    assert(b.cover_image_path == nil, "missing jpg -> no cover path")
end)

t.test("listBooks: identity is the source file until a conversion exists", function()
    local b = firstBook()
    helpers.eq(b.filepath, "/mnt/us/documents/Goldratt/The Goal.kfx", "unprepared -> source path")
end)

t.test("listBooks: flags a book that still needs converting", function()
    -- A first open runs the KFX->EPUB converter, which took 4m40s for a 1.5MB
    -- book on a PW5 with the screen unresponsive throughout. The shelf has to
    -- know that in advance so it can warn instead of appearing to freeze.
    local b = firstBook()
    helpers.eq(b.kindle_needs_prepare, true, "unprepared KFX needs converting")
end)

t.test("listBooks: a converted book does not need preparing again", function()
    local cached = "/cache/kindle.koplugin/cc_00000000-1111-2222-3333-444444444444.epub"
    ready({ ccRow() })
    onDisk(cached)
    helpers.eq(M.listBooks()[1].kindle_needs_prepare, nil, "already converted -> instant")
end)

t.test("listBooks: a directly-openable book never needs preparing", function()
    -- MOBI/AZW go straight to KOReader; there is nothing to convert.
    local azw = "/mnt/us/documents/Fine.azw"
    local b = firstBook({ ccRow({
        p_mimeType = "application/x-mobipocket-ebook", p_location = azw,
    }) })
    helpers.eq(b.kindle_needs_prepare, nil, "no conversion for mobi-family")
end)

t.test("listBooks: a blocked book never needs preparing", function()
    -- No point warning about work that will not be attempted.
    local azw3 = "/mnt/us/documents/Locked.azw3"
    ready({ ccRow({ p_mimeType = "application/x-mobi8-ebook", p_location = azw3 }) })
    M._hasProvider = function() return false end
    local b = M.listBooks()[1]
    helpers.eq(b.kindle_blocked, true, "blocked")
    helpers.eq(b.kindle_needs_prepare, nil, "and so not offered for preparing")
end)

t.test("listBooks: identity becomes the cached EPUB once it exists", function()
    -- Matching what KOReader actually opened means the sidecar, BIM, Recent and
    -- the hero all line up with no shim -- the thing Kobo needed noteKoboOpen for.
    local cached = "/cache/kindle.koplugin/cc_00000000-1111-2222-3333-444444444444.epub"
    ready({ ccRow() })
    onDisk(cached)
    local b = M.listBooks()[1]
    helpers.eq(b.filepath, cached, "prepared -> cached EPUB path")
    helpers.eq(b.kindle_source_path, "/mnt/us/documents/Goldratt/The Goal.kfx",
        "the real source is kept for opening + the file-op guard")
end)

t.test("listBooks: skips cloud-only entries with no local file", function()
    -- 563 of the maintainer's 674 catalogue rows are archived/cloud-only. There
    -- is nothing to open, so they must not reach the shelf.
    ready({ ccRow({ p_location = "" }), ccRow({ p_location = "\0nil" }), ccRow() })
    helpers.eq(#M.listBooks(), 1, "only the row with a real location survives")
end)

t.test("listBooks: skips rows whose source file has been deleted", function()
    -- The catalogue outlives the filesystem: on the maintainer's device one
    -- p_thumbnail already points at a jpg that is gone, so a p_location can go
    -- stale the same way. Listing it would only produce an entry that fails at
    -- open time.
    readyBare({ ccRow() })          -- nothing but cc.db is on disk
    helpers.eq(#M.listBooks(), 0, "stale location -> not on the shelf")
    onDisk("/mnt/us/documents/Goldratt/The Goal.kfx", { modification = 1650000000 })
    M.invalidate()
    local b = M.listBooks()[1]
    assert(b ~= nil, "present once the source file is really there")
    helpers.eq(b.attr.modification, 1650000000, "mtime for the date-added sort")
    helpers.eq(b.added_time, 1650000000, "added_time = when the file landed on the device")
end)

t.test("listBooks: keeps a prepared book whose source has since gone", function()
    -- The conversion is what KOReader opens; if the EPUB is there the book is
    -- still readable even though the Kindle has since removed the source.
    local cached = "/cache/kindle.koplugin/cc_00000000-1111-2222-3333-444444444444.epub"
    readyBare({ ccRow() })          -- source deliberately absent
    onDisk(cached)
    helpers.eq(#M.listBooks(), 1, "cached EPUB is enough to keep it")
end)

t.test("listBooks: derives status from the catalogue percentage", function()
    local unread = firstBook({ ccRow({ p_percentFinished = "\0nil" }) })
    helpers.eq(unread.book_pct, nil, "no percentage -> no progress")
    helpers.eq(unread.status, "unread", "status")
    helpers.eq(unread._status, "unread", "_status (what the filter reads)")
    helpers.eq(unread.read_status, "unread", "read_status (what the sort engine reads)")

    local reading = firstBook({ ccRow({ p_percentFinished = 88.60803 }) })
    assert(math.abs(reading.book_pct - 0.8860803) < 1e-9, "percentage scaled to 0-1")
    helpers.eq(reading.status, "reading", "part-read")

    local done = firstBook({ ccRow({ p_percentFinished = 100 }) })
    helpers.eq(done.status, "finished", "100% -> finished (Bookshelf's vocabulary)")

    local zero = firstBook({ ccRow({ p_percentFinished = 0 }) })
    helpers.eq(zero.status, "unread", "0% -> unread")
end)

t.test("listBooks: a KOReader sidecar overrides the catalogue percentage", function()
    -- Once the book has been read in KOReader, KOReader's own position is the
    -- truth: the two readers measure different content lengths, so the Kindle
    -- percentage is only ever a fallback.
    local cached = "/cache/kindle.koplugin/cc_00000000-1111-2222-3333-444444444444.epub"
    ready({ ccRow({ p_percentFinished = 12 }) })
    onDisk(cached)
    M._sidecar = function(path)
        if path == cached then return { percent_finished = 0.5, status = "complete" } end
    end
    local b = M.listBooks()[1]
    assert(math.abs(b.book_pct - 0.5) < 1e-9, "sidecar percentage wins, got " .. tostring(b.book_pct))
    helpers.eq(b.status, "finished", "KOReader's 'complete' normalises to 'finished'")
end)

t.test("listBooks: includes azw3 books, which the plugin's own list omits", function()
    -- ccdb_scanner.lua filters on x-kfx-ebook + x-mobipocket-ebook only, so
    -- x-mobi8-ebook (azw3) never appears in the plugin's Kindle Library.
    local b = firstBook({ ccRow({
        p_mimeType = "application/x-mobi8-ebook",
        p_location = "/mnt/us/documents/What If.azw3",
    }) })
    helpers.eq(b.format, "AZW3", "format")
    helpers.eq(b.kindle_blocked, nil, "DRM-free azw3 opens directly")
end)

t.test("listBooks: blocks a format KOReader has no provider for", function()
    -- KOReader registers document providers for "azw" and "mobi" but NOT for
    -- "azw3", so every .azw3 is refused by extension whether or not it has DRM.
    -- Handing one to ReaderUI drops the user out into the file browser, so ask
    -- the registry instead of assuming a format is openable.
    local azw3 = "/mnt/us/documents/What If 2.azw3"
    ready({ ccRow({ p_mimeType = "application/x-mobi8-ebook", p_location = azw3 }) })
    M._hasProvider = function(path) return path ~= azw3 end
    local b = M.listBooks()[1]
    helpers.eq(b.kindle_blocked, true, "no provider -> blocked")
    helpers.eq(b.kindle_block_reason, "unsupported", "reason distinguishes it from DRM")
end)

t.test("listBooks: KFX is never judged by KOReader's providers", function()
    -- Nothing can open a .kfx directly -- the point is that the plugin converts
    -- it to an EPUB first, so the source extension is irrelevant.
    ready({ ccRow() })
    M._hasProvider = function() return false end
    local b = M.listBooks()[1]
    helpers.eq(b.kindle_blocked, nil, "KFX stays openable via conversion")
end)

t.test("listBooks: an openable format is left alone", function()
    local azw = "/mnt/us/documents/Fine.azw"
    ready({ ccRow({ p_mimeType = "application/x-mobipocket-ebook", p_location = azw }) })
    M._hasProvider = function() return true end
    local b = M.listBooks()[1]
    helpers.eq(b.kindle_blocked, nil, "provider exists -> not blocked")
end)

t.test("listBooks: detects MOBI DRM from the file, not the catalogue flag", function()
    -- p_isDRMProtected is not usable: on a real device it reads 0 for every
    -- mobi-family book, including the six that are actually protected. The
    -- reliable signal is the file's own PalmDB database name, which Amazon
    -- prefixes with "CR!" on a DRM'd book. Without this the book reaches
    -- ReaderUI, which cannot decode it and bounces the user out to the file
    -- browser with "file not supported".
    local azw3 = "/mnt/us/documents/What If.azw3"
    local b = firstBook({ ccRow({
        p_mimeType = "application/x-mobi8-ebook",
        p_location = azw3,
        p_isDRMProtected = 0,          -- the catalogue's claim, which is wrong
    }) }, nil, { [azw3] = "CR!" })
    helpers.eq(b.kindle_blocked, true, "protected azw3 must be blocked")
    helpers.eq(b.kindle_block_reason, "drm", "reported as protected, not unsupported")
end)

t.test("listBooks: a clear mobi-family file is not blocked", function()
    local azw3 = "/mnt/us/documents/Clear.azw3"
    local b = firstBook({ ccRow({
        p_mimeType = "application/x-mobi8-ebook",
        p_location = azw3,
    }) }, nil, { [azw3] = "TPZ" })
    helpers.eq(b.kindle_blocked, nil, "DRM-free azw3 opens directly")
end)

t.test("listBooks: DRM on a KFX is not a blocker -- the plugin decrypts it", function()
    -- Every KFX purchase is protected; conversion is exactly what handles that.
    local kfx = "/mnt/us/documents/Goldratt/The Goal.kfx"
    local b = firstBook({ ccRow() }, nil, { [kfx] = "CR!" })
    helpers.eq(b.kindle_blocked, nil, "KFX is the plugin's job, DRM or not")
end)

t.test("listBooks: marks DRM-protected mobipocket books as blocked", function()
    -- cc.db declares p_isDRMProtected as INTEGER, but the plugin's own scanner
    -- compares it to the STRING "1"; accept either so the classification can't
    -- silently invert on a typing change in the sqlite binding.
    for _i, drm in ipairs({ 1, "1" }) do
        local b = firstBook({ ccRow({
            p_mimeType = "application/x-mobipocket-ebook",
            p_location = "/mnt/us/documents/Locked.azw",
            p_isDRMProtected = drm,
        }) })
        helpers.eq(b.kindle_blocked, true, "DRM'd mobi is not openable (" .. type(drm) .. ")")
    end
    -- KFX is converted (and decrypted) by the plugin, so DRM is NOT a blocker.
    local kfx = firstBook({ ccRow({ p_isDRMProtected = 1 }) })
    helpers.eq(kfx.kindle_blocked, nil, "DRM'd KFX is fine -- the plugin decrypts it")
end)

t.test("listBooks: parses every credited author", function()
    local b = firstBook({ ccRow({
        j_credits = '[{"name":{"display":"Pratchett, Terry"},"kind":"Author"},'
            .. '{"name":{"display":"Gaiman, Neil"},"kind":"Author"}]',
    }) })
    helpers.eq(b.authors, { "Pratchett, Terry", "Gaiman, Neil" }, "authors")
    helpers.eq(b.author, "Pratchett, Terry", "author is the first credit")
end)

t.test("listBooks: survives a row with no title", function()
    local b = firstBook({ ccRow({ p_titles_0_nominal = "\0nil" }) })
    assert(b.title ~= nil and b.title ~= "", "must fall back to something renderable")
end)

t.test("listBooks: caches for the session and re-reads after invalidate", function()
    local calls = 0
    ready({ ccRow() })
    local inner = M._query
    M._query = function(...) calls = calls + 1; return inner(...) end
    M.listBooks(); M.listBooks()
    helpers.eq(calls, 1, "second call served from cache")
    M.invalidate()
    M.listBooks()
    helpers.eq(calls, 2, "invalidate forces a re-read")
end)

-- The catalogue is validated against cc.db itself, not a clock. Nothing can
-- change that file while KOReader is running with the framework stopped, so a
-- timer only ever re-queried SQLite for an identical answer -- and, being a
-- timer, was also the only thing that repaired a record after a conversion,
-- which is now explicit.
t.test("listBooks: an unchanged catalogue is never re-read, however long it sits", function()
    local calls = 0
    ready({ ccRow() })
    local inner = M._query
    M._query = function(...) calls = calls + 1; return inner(...) end
    for _i = 1, 5 do M.listBooks() end
    helpers.eq(calls, 1, "an unchanged cc.db must be read exactly once")
end)

t.test("listBooks: a newer catalogue is picked up", function()
    local calls = 0
    ready({ ccRow() })
    local inner = M._query
    M._query = function(...) calls = calls + 1; return inner(...) end
    M.listBooks()
    -- What a delivery on a keep_framework device looks like.
    onDisk(M.CC_DB_PATH, { modification = 1700009999 })
    M.listBooks()
    helpers.eq(calls, 2, "a changed mtime must force a re-read")
end)

t.test("listBooks: a same-second write is caught by the size", function()
    -- mtime has one-second resolution, so a write landing in the same second
    -- as the read is invisible to it. Size is what closes that window.
    local calls = 0
    ready({ ccRow() })
    local inner = M._query
    M._query = function(...) calls = calls + 1; return inner(...) end
    M.listBooks()
    onDisk(M.CC_DB_PATH, { size = 999999 })   -- mtime deliberately unchanged
    M.listBooks()
    helpers.eq(calls, 2, "a changed size at the same mtime must force a re-read")
end)

t.test("listBooks: an unstattable catalogue re-reads rather than serving a stale cache", function()
    -- The cache must be BUILT while the stat is failing, so the stored stamp is
    -- nil too. Comparing nil to nil is the trap: it reads as "unchanged" and
    -- serves a cache nothing has vouched for. Failing the stat only after the
    -- cache exists passes either way, so it tests nothing.
    local calls = 0
    ready({ ccRow() })
    local inner = M._query
    M._query = function(...) calls = calls + 1; return inner(...) end
    M._stat = function() return nil end
    M.listBooks()
    M.listBooks()
    helpers.eq(calls, 2, "no stamp means the cache cannot be vouched for")
end)

t.test("listBooks: empty and safe when the catalogue read fails", function()
    ready({ ccRow() })
    M._query = function() error("database is locked") end
    helpers.eq(M.listBooks(), {}, "a failed query must not propagate")
end)

------------------------------------------------------------------------------
-- Title tidying
--
-- The Kindle catalogue derives a side-loaded book's title from its filename, so
-- roughly half of a real library arrives as "Title - Author", "Author - Title",
-- "NN. Title - Author", or with scene-site junk attached. Every author removal
-- here is MATCH-BASED: a name only comes off when it matches a name the
-- catalogue credits, so an unrecognised trailing phrase is left alone rather
-- than guessed at. Cases below are all real titles from a 106-book library.
------------------------------------------------------------------------------

local function tidy(raw, authors)
    return M._cleanTitle(raw, authors)
end

t.test("title: leaves a clean title alone", function()
    helpers.eq(tidy("The Goal: A Process of Ongoing Improvement", { "Goldratt, Eliyahu M." }),
        "The Goal: A Process of Ongoing Improvement")
    helpers.eq(tidy("Ready Player One", { "Cline, Ernest" }), "Ready Player One")
end)

t.test("title: strips a trailing author that the catalogue credits", function()
    helpers.eq(tidy("01. The Colour of Magic - Terry Pratchett", { "Terry Pratchett" }),
        "01. The Colour of Magic")
    -- "Surname, First" in the title vs "First Surname" credited, and vice versa.
    helpers.eq(tidy("Ready Player Two - Cline, Ernest", { "Cline, Ernest" }), "Ready Player Two")
    helpers.eq(tidy("Ready Player Two - Ernest Cline", { "Cline, Ernest" }), "Ready Player Two")
end)

t.test("title: strips a leading author that the catalogue credits", function()
    helpers.eq(tidy("Richard Matheson - I Am Legend", { "Richard Matheson" }), "I Am Legend")
    -- The remaining " - " is part of the real title and must survive.
    helpers.eq(tidy("Yuval Noah Harari - Sapiens - A Brief History of Humankind",
        { "Yuval Noah Harari" }), "Sapiens - A Brief History of Humankind")
end)

t.test("title: strips a co-author list when the first name is credited", function()
    helpers.eq(tidy("Battle of the Big Bang - Niayesh Afshordi & Phil Halper",
        { "Niayesh Afshordi" }), "Battle of the Big Bang")
end)

t.test("title: strips a trailing 'by Author'", function()
    helpers.eq(tidy("Sphereland: A Fantasy About Curved Spaces by Dionys Burger",
        { "Dionys Burger" }), "Sphereland: A Fantasy About Curved Spaces")
end)

t.test("title: leaves an UNRECOGNISED trailing name alone", function()
    -- A real case: the catalogue credits whoever converted the file rather than
    -- the writer, so the trailing name cannot be confirmed against it and must
    -- stay. Guessing would be worse than leaving a slightly long title.
    helpers.eq(tidy("50 Math Tricks That Will Change Your Life - Tanya Zakowich",
        { "File Converter" }),
        "50 Math Tricks That Will Change Your Life - Tanya Zakowich")
end)

t.test("title: strips a credited author in trailing parentheses", function()
    -- What scene-site naming leaves behind once the site tag is gone.
    helpers.eq(tidy("Lord of the flies (Golding, William)", { "Golding, William" }),
        "Lord of the flies")
    helpers.eq(tidy("You Like It Darker (Stephen King)", { "Stephen King" }),
        "You Like It Darker")
    -- A parenthetical that is NOT the author is part of the title.
    helpers.eq(tidy("The Maze Runner (Maze Runner Trilogy, Book 1)", { "Dashner, James" }),
        "The Maze Runner (Maze Runner Trilogy, Book 1)")
end)

t.test("title: drops a truncated trailing fragment", function()
    -- Long names get cut mid-parenthesis, leaving an unclosed tail.
    helpers.eq(tidy("The Scorch Trials The Maze Runner (Book 2) (Jam...", nil),
        "The Scorch Trials The Maze Runner (Book 2)")
    helpers.eq(tidy("Why Cant I Just Enjoy Things A Comedians Guide...", nil),
        "Why Cant I Just Enjoy Things A Comedians Guide")
    -- A balanced parenthetical is untouched.
    helpers.eq(tidy("Randomize (Forward Collection)", nil), "Randomize (Forward Collection)")
end)

t.test("title: removes scene-site junk", function()
    helpers.eq(tidy("The Collected Short Stories of Roald Dahl (z-lib.org)", { "Dahl, Roald" }),
        "The Collected Short Stories of Roald Dahl")
    helpers.eq(tidy("Some Book (Z-Library)", nil), "Some Book")
end)

t.test("title: repairs filename underscores", function()
    -- "_ " is a colon the filesystem could not keep; all-underscore names are
    -- word separators.
    helpers.eq(tidy("Sphereland_ A Fantasy About Curved Spaces", { "Dionys Burger" }),
        "Sphereland: A Fantasy About Curved Spaces")
    helpers.eq(tidy("50_Math_Tricks_That_Will_Change_Your_Life", nil),
        "50 Math Tricks That Will Change Your Life")
end)

t.test("title: never strips its way to nothing", function()
    -- A title that IS just the author's name keeps it: an empty card is worse
    -- than a redundant one.
    helpers.eq(tidy("Terry Pratchett", { "Terry Pratchett" }), "Terry Pratchett")
    helpers.eq(tidy("", { "Terry Pratchett" }), "")
    helpers.eq(tidy(nil, nil), nil)
end)

t.test("listBooks: the shelf gets tidied titles", function()
    local b = firstBook({ ccRow({
        p_titles_0_nominal = "01. The Colour of Magic - Terry Pratchett",
        j_credits = '[{"name":{"display":"Terry Pratchett"},"kind":"Author"}]',
    }) })
    helpers.eq(b.title, "01. The Colour of Magic", "title")
    helpers.eq(b.display_title, "01. The Colour of Magic", "display_title")
    helpers.eq(b.kindle_raw_title, "01. The Colour of Magic - Terry Pratchett",
        "the catalogue's own wording is kept, for diagnosis")
end)

------------------------------------------------------------------------------
-- Sorting, end to end through the real SortEngine
--
-- Being sortable is the entire point of the exercise: the Kindle plugin's own
-- list has one hardcoded title order (library_index.lua:sortBooks). The engine
-- reads specific field names — last_opened, percent_finished, attr.modification
-- — and a record carrying last_read_time / book_pct instead sorts as though
-- every book were identical, silently. These go through the real comparator so
-- that can't happen unnoticed.
------------------------------------------------------------------------------

-- Stubbed before loading the engine so this suite is hermetic: bookshelf_i18n
-- needs KOReader's gettext, which isn't here.
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

local function titlesSortedBy(rows, priority)
    ready(rows)
    local books = M.listBooks()
    table.sort(books, SortEngine.chainedComparator(priority))
    local out = {}
    for i, b in ipairs(books) do out[i] = b.title end
    return out
end

local function row(title, over)
    local o = { p_titles_0_nominal = title, p_location = "/mnt/us/documents/" .. title .. ".kfx",
                p_uuid = "uuid-" .. title }
    for k, v in pairs(over or {}) do o[k] = v end
    return ccRow(o)
end

t.test("sort: most recently opened first", function()
    helpers.eq(
        titlesSortedBy({
            row("Old",    { p_lastAccess = 100 }),
            row("Newest", { p_lastAccess = 300 }),
            row("Middle", { p_lastAccess = 200 }),
        }, { { key = "last_opened", reverse = true } }),
        { "Newest", "Middle", "Old" })
end)

t.test("sort: furthest through first", function()
    helpers.eq(
        titlesSortedBy({
            row("Barely",   { p_percentFinished = 10 }),
            row("Almost",   { p_percentFinished = 90 }),
            row("Untouched",{ p_percentFinished = 0  }),
        }, { { key = "percent_read", reverse = true } }),
        { "Almost", "Barely", "Untouched" })
end)

t.test("sort: most recently added to the device first", function()
    ready({ row("First"), row("Second"), row("Third") })
    disk["/mnt/us/documents/First.kfx"].modification  = 100
    disk["/mnt/us/documents/Second.kfx"].modification = 300
    disk["/mnt/us/documents/Third.kfx"].modification  = 200
    M.invalidate()
    local books = M.listBooks()
    table.sort(books, SortEngine.chainedComparator({ { key = "date_added", reverse = true } }))
    helpers.eq({ books[1].title, books[2].title, books[3].title },
        { "Second", "Third", "First" })
end)

t.test("sort: unread before reading before finished", function()
    helpers.eq(
        titlesSortedBy({
            row("Done",    { p_percentFinished = 100 }),
            row("Fresh",   { p_percentFinished = 0   }),
            row("Started", { p_percentFinished = 40  }),
        }, { { key = "read_status", reverse = false } }),
        { "Fresh", "Started", "Done" })
end)

------------------------------------------------------------------------------
-- realPathForOpen: hand the book to the plugin, which converts and decrypts
------------------------------------------------------------------------------

t.test("realPathForOpen: returns the EPUB the plugin prepared", function()
    local prepared = "/cache/kindle.koplugin/cc_x.epub"
    ready({ ccRow() }, { prepared_path = prepared })
    local b = M.listBooks()[1]
    local path, err = M.realPathForOpen(b)
    helpers.eq(path, prepared, "resolved path")
    helpers.eq(err, nil, "no error")
end)

-- A conversion changes which FILE a book is: the record was built around the
-- .kfx, and afterwards the book is the converted EPUB, which is what the
-- sidecar, BIM, Recent and the hero all key on. cc.db does not move for this,
-- so the catalogue stamp cannot notice it and the cache has to be dropped by
-- hand. Until it is, the shelf keeps handing out a record pointing at the file
-- the reader is no longer using.
t.test("realPathForOpen: a conversion drops the cached record", function()
    local prepared = "/cache/kindle.koplugin/cc_x.epub"
    ready({ ccRow() }, { prepared_path = prepared })
    local calls = 0
    local inner = M._query
    M._query = function(...) calls = calls + 1; return inner(...) end
    local b = M.listBooks()[1]
    helpers.eq(calls, 1, "listed once")
    M.realPathForOpen(b)
    M.listBooks()
    helpers.eq(calls, 2, "the conversion must force the catalogue to be rebuilt")
end)

t.test("realPathForOpen: opening an already-converted book does not", function()
    -- The plugin hands back the same path it was given when there is nothing to
    -- do. Dropping the cache there would re-query SQLite on every open.
    ready({ ccRow() })
    local calls = 0
    local inner = M._query
    M._query = function(...) calls = calls + 1; return inner(...) end
    local b = M.listBooks()[1]
    local path = M.realPathForOpen(b)
    helpers.eq(path, b.filepath, "precondition: the plugin returned the same path")
    M.listBooks()
    helpers.eq(calls, 1, "an open that converted nothing must keep the cache")
end)

t.test("realPathForOpen: passes the plugin's own failure text straight through", function()
    -- The plugin already phrases these for the reader ("This Kindle firmware
    -- cannot extract this book's access key by itself…"); re-wording them here
    -- would only lose detail.
    ready({ ccRow() }, { prepare_error = "Could not extract this book's access key." })
    local b = M.listBooks()[1]
    local path, err = M.realPathForOpen(b)
    helpers.eq(path, nil, "no path")
    helpers.eq(err, "Could not extract this book's access key.", "plugin's wording kept")
end)

t.test("realPathForOpen: refuses a DRM-locked book without calling the plugin", function()
    local asked = false
    ready({ ccRow({
        p_mimeType = "application/x-mobipocket-ebook",
        p_location = "/mnt/us/documents/Locked.azw",
        p_isDRMProtected = 1,
    }) })
    local plugin = fakePlugin()
    plugin.prepareKnownKindlePath = function() asked = true; return "/nope.epub" end
    M._plugin = function() return plugin end
    local b = M.listBooks()[1]
    local path, reason = M.realPathForOpen(b)
    helpers.eq(path, nil, "no path")
    helpers.eq(reason, "drm", "a reason key, so the string stays in Bookshelf's own POT")
    assert(asked == false, "the plugin must not be asked to convert a blocked book")
end)

t.test("realPathForOpen: nil when the plugin has gone away since listing", function()
    ready({ ccRow() })
    local b = M.listBooks()[1]
    M._plugin = function() return nil end
    local path, reason = M.realPathForOpen(b)
    helpers.eq(path, nil, "no path")
    assert(reason ~= nil, "must give the caller something to show")
end)

t.test("realPathForOpen: nil for anything that is not a Kindle record", function()
    ready({ ccRow() })
    helpers.eq(M.realPathForOpen(nil), nil, "nil book")
    helpers.eq(M.realPathForOpen({ filepath = "/mnt/us/ebooks/Normal.epub" }), nil,
        "a plain local book is not ours to resolve")
end)

------------------------------------------------------------------------------
-- isKindlePath: the guard that keeps file-ops off the user's Kindle books
------------------------------------------------------------------------------

t.test("recordFor: finds a listed book by either of its paths", function()
    -- Repo.buildBook uses this to put the Kindle identity back onto a record
    -- rebuilt from a bare filepath, so it must answer for the source file and
    -- for the converted EPUB alike.
    local cached = "/cache/kindle.koplugin/cc_00000000-1111-2222-3333-444444444444.epub"
    ready({ ccRow() })
    onDisk(cached)
    M.listBooks()
    local by_cache = M.recordFor(cached)
    local by_source = M.recordFor("/mnt/us/documents/Goldratt/The Goal.kfx")
    assert(by_cache ~= nil and by_cache.is_kindle == true, "found by cached EPUB path")
    assert(by_source ~= nil and by_source.is_kindle == true, "found by source path")
    assert(by_cache == by_source, "both paths resolve to the same record")
    assert(M.recordFor("/mnt/us/ebooks/Normal.epub") == nil, "not a Kindle book")
    assert(M.recordFor(nil) == nil, "nil path")
end)

t.test("recordFor: nil before anything has been listed", function()
    -- Asked from a cold Repo.buildBook (a cold start straight into the reader),
    -- it must not trigger a catalogue scan as a side effect.
    local queried = false
    ready({ ccRow() })
    local inner = M._query
    M._query = function(...) queried = true; return inner(...) end
    assert(M.recordFor("/mnt/us/documents/Goldratt/The Goal.kfx") == nil, "no answer yet")
    assert(queried == false, "must not scan the catalogue just to answer a lookup")
end)

t.test("isKindlePath: true for the source file and for the cached EPUB", function()
    local cached = "/cache/kindle.koplugin/cc_00000000-1111-2222-3333-444444444444.epub"
    ready({ ccRow() })
    onDisk(cached)
    M.listBooks()
    assert(M.isKindlePath(cached) == true, "cached EPUB")
    assert(M.isKindlePath("/mnt/us/documents/Goldratt/The Goal.kfx") == true, "source file")
    assert(M.isKindlePath("/mnt/us/ebooks/Normal.epub") == false, "an ordinary book")
    assert(M.isKindlePath(nil) == false, "nil")
end)

-- Rating
--
-- The Kindle catalogue holds no rating, so the shelf's Rating sort had nothing
-- to order by and silently left every book where it was -- the same failure the
-- sort tests above exist to catch, on the one field that has no catalogue
-- source. KOReader's own rating for the converted file is the answer, and it
-- lives in the same sidecar summary the status already comes from.

t.test("rating: comes from the sidecar of the converted file", function()
    local cached = "/cache/kindle.koplugin/cc_00000000-1111-2222-3333-444444444444.epub"
    ready({ ccRow() })
    onDisk(cached)
    M._sidecar = function(path)
        if path == cached then return { rating = 4 } end
    end
    local b = M.listBooks()[1]
    assert(b, "no book")
    assert(b.rating == 4, "rating did not reach the record: " .. tostring(b.rating))
end)

t.test("rating: nil for a book that has never been rated here", function()
    local cached = "/cache/kindle.koplugin/cc_00000000-1111-2222-3333-444444444444.epub"
    ready({ ccRow() })
    onDisk(cached)
    M._sidecar = function() return { percent_finished = 0.5 } end
    local b = M.listBooks()[1]
    assert(b.rating == nil, "invented a rating: " .. tostring(b.rating))
end)

t.test("rating: a string in an older sidecar still sorts as a number", function()
    local cached = "/cache/kindle.koplugin/cc_00000000-1111-2222-3333-444444444444.epub"
    ready({ ccRow() })
    onDisk(cached)
    M._sidecar = function() return { rating = "3" } end
    local b = M.listBooks()[1]
    assert(b.rating == 3, "a string rating was not converted: " .. tostring(b.rating))
end)

t.test("sort: by rating, highest first", function()
    -- The end-to-end check. Without a rating on the record the engine compares
    -- every book equal and this returns the input order unchanged.
    local ratings = {}
    ready({
        row("Poor",   { p_uuid = "u-poor" }),
        row("Great",  { p_uuid = "u-great" }),
        row("Middle", { p_uuid = "u-mid" }),
    })
    for _, t2 in ipairs({ { "Poor", 1 }, { "Great", 5 }, { "Middle", 3 } }) do
        ratings["/mnt/us/documents/" .. t2[1] .. ".kfx"] = t2[2]
    end
    M._sidecar = function(path) return { rating = ratings[path] } end
    local books = M.listBooks()
    table.sort(books, SortEngine.chainedComparator({ { key = "rating", reverse = true } }))
    local out = {}
    for i, b in ipairs(books) do out[i] = b.title end
    helpers.eq(out, { "Great", "Middle", "Poor" })
end)

t.test("rating: the real sidecar read picks the rating out of the summary", function()
    -- Drives REAL_SIDECAR against a stubbed DocSettings, so this covers the
    -- read itself rather than the stub every other test installs.
    local asked = {}
    package.loaded["docsettings"] = {
        hasSidecarFile = function(_self, path) asked[#asked + 1] = path; return true end,
        open = function(_self, _path)
            return {
                readSetting = function(_s, key)
                    if key == "summary" then
                        return { status = "complete", rating = 5 }
                    elseif key == "percent_finished" then
                        return 0.75
                    end
                end,
            }
        end,
    }
    local out = REAL_SIDECAR("/cache/x.epub")
    package.loaded["docsettings"] = nil
    assert(out, "the real sidecar read returned nothing")
    assert(out.rating == 5, "rating not read from the summary: " .. tostring(out.rating))
    assert(out.status == "complete", "status regressed: " .. tostring(out.status))
    assert(out.percent_finished == 0.75, "progress regressed")
end)

-- %added and %size
--
-- The sort engine's date_added and size comparators fall back to
-- attr.modification and attr.size, so both sorts worked whether or not the
-- record carried the top-level fields. The TOKENS have no such fallback: %added
-- reads b.date_added and %size reads b.size, and rendered empty on a Kindle
-- shelf while filling in on every other one. So these assert through the real
-- token resolvers -- a sort test passes either way and would not have caught it.

local Tokens = dofile("lib/bookshelf_tokens.lua")

t.test("%added renders for a Kindle book", function()
    ready({ ccRow() })
    onDisk("/mnt/us/documents/Goldratt/The Goal.kfx", { modification = 1700000000 })
    local b = M.listBooks()[1]
    assert(b, "no book")
    local out = Tokens.expanders.added(b)
    assert(out and out ~= "", "%added rendered empty for a Kindle book")
end)

t.test("%size renders for a Kindle book", function()
    ready({ ccRow({ p_diskUsage = 5 * 1024 * 1024 }) })
    onDisk("/mnt/us/documents/Goldratt/The Goal.kfx")
    local b = M.listBooks()[1]
    assert(b, "no book")
    local out = Tokens.expanders.size(b)
    assert(out and out ~= "", "%size rendered empty for a Kindle book")
end)

t.test("size comes from the catalogue's own figure", function()
    ready({ ccRow({ p_diskUsage = 3 * 1024 * 1024 }) })
    onDisk("/mnt/us/documents/Goldratt/The Goal.kfx")
    local b = M.listBooks()[1]
    assert(b.size == 3 * 1024 * 1024, "wrong size: " .. tostring(b.size))
    assert(b.attr.size == b.size, "attr.size and size disagree")
end)

t.test("size falls back to the download size when disk usage is absent", function()
    ready({ ccRow({ p_diskUsage = "\0nil", p_contentSize = 777 }) })
    onDisk("/mnt/us/documents/Goldratt/The Goal.kfx")
    local b = M.listBooks()[1]
    assert(b.size == 777, "wrong size: " .. tostring(b.size))
end)

t.done()
