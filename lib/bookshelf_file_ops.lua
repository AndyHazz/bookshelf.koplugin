-- lib/bookshelf_file_ops.lua
-- Move engine for books and folders. No UI in this module; dialogs live
-- in lib/bookshelf_move_flow.lua. Composes KOReader core primitives
-- (FileManager:moveFile, DocSettings.updateLocation, ReadHistory /
-- ReadCollection updateItem) and then repairs bookshelf-owned
-- path-keyed stores. KOReader requires are lazy (inside functions) so
-- the pure helpers run under a standalone `lua` for tests/run.sh.
-- Spec: docs/superpowers/specs/2026-08-06-file-move-design.md

local logger = require("logger")

local FileOps = {}

-- ── Pure path helpers ───────────────────────────────────────────────

-- Normalise a directory path to no trailing slash ("/" stays "/").
function FileOps.normDir(p)
    if p == "/" then return "/" end
    return (tostring(p):gsub("/+$", ""))
end

function FileOps.basename(p)
    return tostring(p):match("([^/]+)/*$")
end

function FileOps.parentDir(p)
    local parent = FileOps.normDir(p):match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then return "/" end
    return parent
end

function FileOps.joinDir(dir, name)
    local base = FileOps.normDir(dir)
    if base == "/" then base = "" end
    return base .. "/" .. name
end

-- Destination filepath for moving `path` into `dest_dir`.
function FileOps.destPath(path, dest_dir)
    return FileOps.joinDir(dest_dir, FileOps.basename(path))
end

-- Swap the old_dir prefix of `path` for new_dir. Returns nil when path
-- is not under old_dir. Segment-safe: "/a/bb" is NOT under "/a/b".
function FileOps.prefixSwap(path, old_dir, new_dir)
    old_dir = FileOps.normDir(old_dir)
    new_dir = FileOps.normDir(new_dir)
    if path == old_dir then return new_dir end
    if path:sub(1, #old_dir + 1) == old_dir .. "/" then
        return new_dir .. path:sub(#old_dir + 1)
    end
    return nil
end

-- Directory depth of `dir` relative to `home`: 0 = home itself, 1 = a
-- direct child, nil = not under home. Matches walkBooks' current_depth
-- arithmetic: books inside a depth-N directory are found when N <= the
-- walk depth (bookshelf_book_repository.lua walkBooks, guard
-- `current_depth > depth`).
function FileOps.shelfDepth(dir, home)
    home = FileOps.normDir(home)
    dir  = FileOps.normDir(dir)
    if dir == home then return 0 end
    local rel = FileOps.prefixSwap(dir, home, "")
    if not rel then return nil end
    local n = 0
    for _seg in rel:gmatch("/[^/]+") do n = n + 1 end
    return n
end

-- Will books placed directly in dest_dir appear on the shelf?
function FileOps.isVisibleOnShelf(dest_dir, home, walk_depth)
    local d = FileOps.shelfDepth(dest_dir, home)
    return d ~= nil and d <= (walk_depth or 3)
end

-- planMoves(paths, dest_dir, opts): pre-check pass. Never overwrites:
-- a name collision at the destination is a skip, not a prompt (spec).
-- opts.exists(path) -> bool (default: lfs stat), opts.in_use_paths =
-- { [fp] = true } for books that must not move (open/parked reader).
function FileOps.planMoves(paths, dest_dir, opts)
    opts = opts or {}
    local exists = opts.exists or function(p)
        local lfs = require("libs/libkoreader-lfs")
        return lfs.attributes(p, "mode") ~= nil
    end
    local in_use = opts.in_use_paths or {}
    local dest_norm = FileOps.normDir(dest_dir)
    local plan = { moves = {}, skipped = {} }
    for _i, fp in ipairs(paths) do
        local to = FileOps.destPath(fp, dest_norm)
        if in_use[fp] then
            plan.skipped[#plan.skipped + 1] = { path = fp, reason = "in_use" }
        elseif FileOps.parentDir(fp) == dest_norm then
            plan.skipped[#plan.skipped + 1] = { path = fp, reason = "same_dir" }
        elseif not exists(fp) then
            plan.skipped[#plan.skipped + 1] = { path = fp, reason = "missing" }
        elseif exists(to) then
            plan.skipped[#plan.skipped + 1] = { path = fp, reason = "exists" }
        else
            plan.moves[#plan.moves + 1] = { from = fp, to = to }
        end
    end
    return plan
end

-- ── Move engine ─────────────────────────────────────────────────────

-- Books that must not be moved right now: the document open in a live
-- ReaderUI and a hot-parked reader's document. Moving a file out from
-- under a live reader risks the close-time sidecar flush recreating
-- data at the old path.
function FileOps.inUsePaths()
    local set = {}
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local rui = ok and ReaderUI and ReaderUI.instance or nil
    if rui and rui.document and rui.document.file then
        set[rui.document.file] = true
    end
    local ok2, Park = pcall(require, "lib/bookshelf_reader_park")
    if ok2 and Park and Park.parkedFile then
        local fp = Park.parkedFile()
        if fp then set[fp] = true end
    end
    return set
end

-- Physical move. os.rename first: it is a single syscall, atomic within
-- a filesystem, and measured on a PW5 at 0.6ms against 10.8ms for the
-- fork+exec of /bin/mv (18x). It cannot cross filesystems (EXDEV), and
-- fails for any number of other reasons, so ANY failure falls back to
-- core's /bin/mv - which handles cross-device by copy+unlink.
--
-- Overwrite semantics match what we already had: POSIX rename replaces
-- an existing destination silently, and core's mv carries no -n either.
-- planMoves is what protects the destination, by skipping collisions.
local function _physicalMove(old_path, new_path)
    if os.rename(old_path, new_path) then return true end
    local FileManager = require("apps/filemanager/filemanager")
    return FileManager:moveFile(old_path, new_path) and true or false
end

-- Relocate a book's sidecar by renaming its directory: one syscall that
-- carries the metadata, any custom cover, AND anything another plugin
-- wrote in there - which DocSettings.updateLocation does not, since it
-- only copies the files it knows about and leaves the rest orphaned.
--
-- Measured per book on a PW5: 1.4ms against 17.2ms for updateLocation,
-- or 31.4ms when a custom cover has to be copied.
--
-- Safe despite the sidecar's stored `doc_path` still naming the old path:
-- DocSettings:open(path) ends by overwriting data.doc_path with the path
-- it was opened with (docsettings.lua:293), so every consumer that reads
-- doc_path reads it from an object opened at the current path, and the
-- on-disk value is corrected by the next flush.
--
-- Returns true when the sidecar is dealt with (moved, or there was
-- nothing to move); false means "fall back to updateLocation", which is
-- the thorough path for every case this cannot do with one rename.
local function _renameSidecar(old_path, new_path, batch)
    local DocSettings = require("docsettings")
    local lfs = require("libs/libkoreader-lfs")
    -- Hash location keys the sidecar by file content, so a move does not
    -- move it. updateLocation deliberately no-ops here too.
    if G_reader_settings:readSetting("document_metadata_folder", "doc") == "hash" then
        return true
    end
    -- no_legacy: the legacy history location is a flat directory, not a
    -- per-book one, so there is no directory to rename.
    local sidecar_file, location = DocSettings:findSidecarFile(old_path, true)
    if not sidecar_file then return true end   -- never opened: nothing to move
    -- A book with sidecars in BOTH locations (flush's read-only-storage
    -- fallback can produce that) needs a merge, not a rename.
    local name = DocSettings.getSidecarFilename(old_path)
    local held = 0
    for _i, loc in ipairs({ "doc", "dir" }) do
        local dir = DocSettings:getSidecarDir(old_path, loc)
        if dir ~= "" and lfs.attributes(dir .. "/" .. name, "mode") == "file" then
            held = held + 1
        end
    end
    if held > 1 then return false end

    local old_sdr = DocSettings:getSidecarDir(old_path, location)
    local new_sdr = DocSettings:getSidecarDir(new_path, location)
    if old_sdr == "" or new_sdr == "" or old_sdr == new_sdr then return false end
    -- Occupied destination (a stale sidecar from a deleted book of the
    -- same name): renaming onto it would either fail or discard it.
    if lfs.attributes(new_sdr, "mode") then return false end
    -- "dir" location mirrors the library tree, so the parent may not exist.
    -- Every book in a batch shares one destination, so the mkdir chain is
    -- worth doing once: it was 23.9ms/book of the dir-mode cost.
    local parent = new_sdr:match("^(.*)/[^/]+$")
    if parent and not (batch and batch.made_paths and batch.made_paths[parent]) then
        pcall(function() require("util").makePath(parent) end)
        if batch then
            batch.made_paths = batch.made_paths or {}
            batch.made_paths[parent] = true
        end
    end
    return os.rename(old_sdr, new_sdr) and true or false
end

-- Files KOReader derives from a book and keeps BESIDE it, named
-- "<book filename>.<ext>" rather than living in the sidecar:
--
--   .txt   the per-book notebook (Book information > "Notebook file"),
--          whose default path is exactly this sibling
--   .html  the Convert feature's output, which persists next to the
--          original and is itself a book with its own reading state
--
-- Core re-keys neither: its own file manager leaves them behind. A moved
-- book therefore either kept notes it could no longer reach beside it or,
-- with the derived notebook path, resolved to a new empty notebook while
-- the real one stayed in the old folder.
--
-- Books without any of these pay one stat each: the common case finds
-- nothing and stops.
local DERIVED_SIBLING_EXTS = { "txt", "html" }

local function _relocateSiblings(old_path, new_path, batch)
    local lfs = require("libs/libkoreader-lfs")
    for _i, ext in ipairs(DERIVED_SIBLING_EXTS) do
        local old_sib = old_path .. "." .. ext
        local new_sib = new_path .. "." .. ext
        local present = lfs.attributes(new_sib, "mode") == "file"  -- folder move: came along
        if not present and lfs.attributes(old_sib, "mode") == "file" then
            -- Never clobber a file already sitting at the destination.
            present = _physicalMove(old_sib, new_sib)
            if not present then
                logger.warn("bookshelf file-ops: sibling move failed", old_sib)
            end
        end
        if present then
            -- The sibling can be a document in its own right (a converted
            -- HTML certainly is), so its own sidecar has to follow it.
            if not _renameSidecar(old_sib, new_sib, batch) then
                pcall(function()
                    require("docsettings").updateLocation(old_sib, new_sib)
                end)
            end
            if ext == "txt" then
                -- The book's sidecar may pin its notebook by absolute
                -- path. Follow it only when it named the sibling we just
                -- moved; a path the user chose elsewhere, or a shared
                -- global notebook, is left exactly as they set it.
                local DocSettings = require("docsettings")
                if DocSettings:hasSidecarFile(new_path) then
                    local ds = DocSettings:open(new_path)
                    if ds:readSetting("notebook_file") == old_sib then
                        ds:saveSetting("notebook_file", new_sib)
                        ds:flush()
                    end
                end
            end
        end
    end
end

-- Shared BIM connection for a batch. Opening the cache costs ~11ms on a
-- PW5 (186 MB db), so opening it once per batch instead of once per book
-- is most of that cost gone. Canonical opener lives in bookshelf_bim_db.
local function _openBimDb()
    return require("lib/bookshelf_bim_db").open()
end

-- BIM (CoverBrowser's bookinfo_cache.sqlite3) keys rows on
-- (directory, filename) with directory slash-terminated -- stale_sweep
-- reconstructs fp as directory .. filename. Re-key the row in place so
-- the extracted cover survives the move instead of forcing a full
-- re-extraction. Raw-SQL precedent: lib/bookshelf_stale_sweep.lua.
-- Returns true when the old path can't be stale (no db) or the UPDATE
-- ran; false tells the caller to fall back to delete-and-re-extract.
--
-- `shared_db` (batch mode) skips the per-book open/close.
local function _updateBimRow(old_path, new_path, shared_db)
    local db, why = shared_db, nil
    if not db then
        db, why = _openBimDb()
        if not db then
            -- "no db yet" is not a failure: there is no stale row to fix.
            return why == "no-db"
        end
    end
    local old_dir, old_name = old_path:match("^(.*/)([^/]+)$")
    local new_dir, new_name = new_path:match("^(.*/)([^/]+)$")
    local ok_upd = pcall(function()
        local stmt = db:prepare(
            "UPDATE bookinfo SET directory = ?, filename = ? WHERE directory = ? AND filename = ?;")
        stmt:bind(new_dir, new_name, old_dir, old_name)
        stmt:step()
        stmt:close()
    end)
    if not shared_db then pcall(function() db:close() end) end
    return ok_upd and old_dir ~= nil
end

-- State repairs after a successful physical move, in spec order.
-- Each step pcall'd: a failed fix-up is logged and the move stands
-- (worst case a stale cache entry the stale sweep / walk-cache
-- staleness check recovers). updateLocation must run AFTER the
-- physical move; it reads the old sidecar, which mv of the book file
-- did not touch.
-- `batch` (optional) defers the stores that rewrite a whole file on
-- every call - history, collections and Hardcover links - to one pass at
-- the end of the batch. Measured per book on a PW5: history 11.9ms
-- per-call against 1.2ms amortised over a batched call. Collections and
-- the Hardcover link store have the same write-the-lot shape.
--
-- The deferral only moves state forward in time; it never writes state
-- for a move that did not happen. The exception it buys us is narrow: a
-- crash between the last file moving and the batch flush leaves history
-- and collection entries pointing at old paths, which the next move or a
-- manual re-add corrects.
local function _fixupBook(old_path, new_path, batch)
    local function safe(name, fn)
        local ok, err = pcall(fn)
        if not ok then
            logger.warn("bookshelf file-ops fixup:", name, old_path, err)
        end
    end
    safe("docsettings", function()
        if not _renameSidecar(old_path, new_path, batch) then
            require("docsettings").updateLocation(old_path, new_path)
        end
    end)
    safe("siblings", function() _relocateSiblings(old_path, new_path, batch) end)
    if batch then
        batch.files[old_path] = true
        batch.hc[#batch.hc + 1] = { old_path, new_path }
    else
        safe("history", function()
            require("readhistory"):updateItem(old_path, new_path)
        end)
        safe("collections", function()
            require("readcollection"):updateItem(old_path, new_path)
        end)
        safe("hardcover", function()
            require("lib/bookshelf_hardcover").relinkPath(old_path, new_path)
        end)
    end
    safe("booklist-cache", function()
        require("ui/widget/booklist").resetBookInfoCache(old_path)
    end)
    if not _updateBimRow(old_path, new_path, batch and batch.db or nil) then
        safe("bim-invalidate", function()
            local UIManager = require("ui/uimanager")
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", old_path))
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", new_path))
        end)
    end
end

-- Batch context. Only opened when every move in the plan shares one
-- destination folder, because core's batch APIs take a single new_path
-- (ReadHistory:updateItems / ReadCollection:updateItems append the
-- stored basename to it). A "/" destination is excluded: new_path .. "/"
-- .. name would store a doubled slash that later lookups would miss.
local function _newBatch(plan)
    local first = plan.moves and plan.moves[1]
    if not first then return nil end
    local dest = FileOps.parentDir(first.to)
    if dest == "/" then return nil end
    for _i, m in ipairs(plan.moves) do
        if FileOps.parentDir(m.to) ~= dest then return nil end
    end
    local db = _openBimDb()   -- nil is fine: per-book path handles it
    return { dest = dest, files = {}, hc = {}, db = db }
end

-- Apply the deferred work: one history flush, one collections write, one
-- Hardcover link save, and close the shared BIM connection.
local function _finishBatch(batch)
    if not batch then return end
    local function safe(name, fn)
        local ok, err = pcall(fn)
        if not ok then logger.warn("bookshelf file-ops batch:", name, err) end
    end
    if next(batch.files) then
        safe("history", function()
            require("readhistory"):updateItems(batch.files, batch.dest)
        end)
        safe("collections", function()
            require("readcollection"):updateItems(batch.files, batch.dest)
        end)
    end
    if #batch.hc > 0 then
        safe("hardcover", function()
            require("lib/bookshelf_hardcover").relinkPaths(batch.hc)
        end)
    end
    if batch.db then safe("bim-close", function() batch.db:close() end) end
end

-- moveBook: physical move + fix-ups for one book. Callers run
-- pre-checks via planMoves and batch-level invalidation themselves.
-- Move failure = nothing else runs (never rewrite state for a move that
-- did not happen).
function FileOps.moveBook(old_path, new_path, batch)
    if not _physicalMove(old_path, new_path) then
        logger.warn("bookshelf file-ops: move failed", old_path, new_path)
        return nil, "error"
    end
    _fixupBook(old_path, new_path, batch)
    return true
end

-- moveBooks: execute a planMoves plan. Per-file pcall so one bad file
-- never aborts the batch (bulk-actions safe() pattern).
--
-- on_progress(done, total, path) fires after each file so the caller can
-- update a progress message. The loop stays synchronous deliberately: a
-- yielding loop would let the user tap into a half-moved library, and
-- every intermediate state here is a real filesystem state, not a
-- transaction we could roll back.
function FileOps.moveBooks(plan, on_progress)
    local summary = { moved = {}, moved_to = {}, failed = 0, skipped = {} }
    for _i, s in ipairs(plan.skipped) do
        summary.skipped[s.reason] = (summary.skipped[s.reason] or 0) + 1
    end
    local total = #plan.moves
    local batch = _newBatch(plan)
    for i, m in ipairs(plan.moves) do
        local ok_call, ok = pcall(FileOps.moveBook, m.from, m.to, batch)
        if ok_call and ok then
            summary.moved[#summary.moved + 1] = m.from
            summary.moved_to[#summary.moved_to + 1] = m.to
        else
            summary.failed = summary.failed + 1
        end
        if on_progress then
            pcall(on_progress, i, total, m.from)
        end
    end
    _finishBatch(batch)
    return summary
end

-- listBooksUnder(dir): every shelf book under dir, at ANY depth.
--
-- Deliberately NOT Repo.getFolderBookPaths: that reads the depth-bounded
-- library walk (latest_walk_depth, default 3), so a folder move would
-- skip the per-book sidecar fix-up for anything nested deeper - and in
-- "dir" metadata mode that silently detaches progress, bookmarks and
-- highlights from those books. Correctness beats speed for a one-off
-- user-initiated move, so this walks the real tree with no depth budget.
--
-- MAX_LEVELS is a runaway guard, not a feature: lfs.attributes follows
-- symlinks, so a symlinked directory cycle would otherwise recurse
-- forever.
local MAX_LEVELS = 40

function FileOps.listBooksUnder(dir)
    local lfs = require("libs/libkoreader-lfs")
    local Repo = require("lib/bookshelf_book_repository")
    local out = {}
    local function walk(root, level)
        if level > MAX_LEVELS then
            logger.warn("bookshelf file-ops: depth guard hit at", root)
            return
        end
        local ok, iter, dir_obj = pcall(lfs.dir, root)
        if not ok or type(iter) ~= "function" then return end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." and entry:sub(-4) ~= ".sdr" then
                local fp = FileOps.joinDir(root, entry)
                local mode = lfs.attributes(fp, "mode")
                if mode == "directory" then
                    walk(fp, level + 1)
                elseif mode == "file" and Repo.isBookFile(entry) then
                    out[#out + 1] = fp
                end
            end
        end
    end
    walk(FileOps.normDir(dir), 1)
    return out
end

-- ── Folder operations ───────────────────────────────────────────────

-- Create a directory under `parent`. Name rules: non-empty after trim,
-- no path separators, no leading dot (the walk skips dot-dirs, so a
-- dot-named destination would swallow books invisibly).
function FileOps.createFolder(parent, name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or name:find("/", 1, true) or name:sub(1, 1) == "." then
        return nil, "bad_name"
    end
    local lfs = require("libs/libkoreader-lfs")
    local path = FileOps.joinDir(parent, name)
    if lfs.attributes(path, "mode") then return nil, "exists" end
    if not lfs.mkdir(path) then return nil, "error" end
    return path
end

-- Rewrite folder-path references inside the persisted chip tabs:
-- source.id for folder / folder_flat chips, plus the folder include /
-- exclude filter lists. prefixSwap so descendants re-key too.
function FileOps._rewriteTabPaths(old_dir, new_dir)
    local TabModel = require("lib/bookshelf_tab_model")
    local tabs = TabModel.load() or {}
    local changed = false
    local function swap(p)
        local np = FileOps.prefixSwap(FileOps.normDir(tostring(p)), old_dir, new_dir)
        if np then changed = true end
        return np
    end
    for _i, tab in ipairs(tabs) do
        local src = tab.source
        if src and (src.kind == "folder" or src.kind == "folder_flat")
                and type(src.id) == "string" then
            src.id = swap(src.id) or src.id
        end
        local folders = tab.filter and tab.filter.folders
        if folders then
            for _j, key in ipairs({ "include", "exclude" }) do
                local set = folders[key]
                if type(set) == "table" then
                    local out = {}
                    for p in pairs(set) do out[swap(p) or p] = true end
                    folders[key] = out
                end
            end
        end
    end
    if changed then TabModel.save(tabs) end
    return changed
end

-- relocateFolder: one mv of the directory, then repair every book that
-- was under it plus the folder-keyed stores. The book list is captured
-- BEFORE the physical move (the old paths must still be walkable).
--
-- DocSettings.updateLocation per book is safe to call unconditionally:
-- with "doc" sidecars the .sdr travelled inside the folder (the
-- function early-outs when nothing exists at the old path); with "dir"
-- it rescues the mirrored DOCSETTINGS_DIR tree that core's own folder
-- paste orphans; with "hash" it deliberately no-ops.
function FileOps.relocateFolder(old_dir, new_dir)
    old_dir = FileOps.normDir(old_dir)
    new_dir = FileOps.normDir(new_dir)
    local lfs = require("libs/libkoreader-lfs")
    if old_dir == new_dir or FileOps.prefixSwap(new_dir, old_dir, old_dir) then
        return nil, "self"   -- destination is the folder or inside it
    end
    if lfs.attributes(old_dir, "mode") ~= "directory" then return nil, "missing" end
    if lfs.attributes(new_dir, "mode") then return nil, "exists" end
    for fp in pairs(FileOps.inUsePaths()) do
        if FileOps.prefixSwap(fp, old_dir, old_dir) then
            return nil, "in_use"
        end
    end

    -- Unbounded walk, captured BEFORE the physical move: the depth-bounded
    -- library walk would miss deeply-nested books and leave their "dir"
    -- mode sidecars orphaned (see listBooksUnder).
    local ok_books, books = pcall(FileOps.listBooksUnder, old_dir)
    books = (ok_books and books) or {}

    local FileManager = require("apps/filemanager/filemanager")
    if not FileManager:moveFile(old_dir, new_dir) then
        logger.warn("bookshelf file-ops: folder mv failed", old_dir, new_dir)
        return nil, "error"
    end

    local function safe(name, fn)
        local ok, err = pcall(fn)
        if not ok then logger.warn("bookshelf file-ops folder fixup:", name, err) end
    end
    for _i, old_fp in ipairs(books) do
        local new_fp = FileOps.prefixSwap(old_fp, old_dir, new_dir)
        if new_fp then
            safe("docsettings", function()
                require("docsettings").updateLocation(old_fp, new_fp)
            end)
            safe("siblings", function() _relocateSiblings(old_fp, new_fp) end)
            safe("hardcover", function()
                require("lib/bookshelf_hardcover").relinkPath(old_fp, new_fp)
            end)
            safe("booklist-cache", function()
                require("ui/widget/booklist").resetBookInfoCache(old_fp)
            end)
            if not _updateBimRow(old_fp, new_fp) then
                safe("bim-invalidate", function()
                    local UIManager = require("ui/uimanager")
                    local Event = require("ui/event")
                    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", old_fp))
                    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", new_fp))
                end)
            end
        end
    end
    -- History / collections keep per-book entries; their ByPath calls
    -- prefix-rewrite everything at once (core parity: filemanager.lua
    -- does exactly these three on a folder paste).
    safe("history", function()
        require("readhistory"):updateItemsByPath(old_dir, new_dir)
    end)
    safe("collections", function()
        require("readcollection"):updateItemsByPath(old_dir, new_dir)
    end)
    safe("folder-shortcuts", function()
        require("apps/filemanager/filemanagershortcuts"):updateItemsByPath(old_dir, new_dir)
    end)
    safe("folder-images", function()
        require("lib/bookshelf_image_source").rekeyFolderPaths(old_dir, new_dir)
    end)
    safe("tabs", function() FileOps._rewriteTabPaths(old_dir, new_dir) end)
    return true, #books
end

-- renameFolder: same operation, destination is a sibling name.
function FileOps.renameFolder(old_dir, new_name)
    new_name = tostring(new_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if new_name == "" or new_name:find("/", 1, true) or new_name:sub(1, 1) == "." then
        return nil, "bad_name"
    end
    old_dir = FileOps.normDir(old_dir)
    return FileOps.relocateFolder(old_dir,
        FileOps.joinDir(FileOps.parentDir(old_dir), new_name))
end

return FileOps
