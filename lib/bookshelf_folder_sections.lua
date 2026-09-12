-- bookshelf_folder_sections.lua
-- Turns a library walk into shelf sections, one per directory that actually
-- holds books. Pure string and table work -- no lfs, no Screen, no i18n --
-- so the rules are testable headless (tests/_test_folder_sections.lua).
--
-- ── WHY ─────────────────────────────────────────────────────────────────────
--
-- The spine shelf flattens any item carrying `books` into a run of spines
-- with a name badge hung off the plank beneath it -- that is how a series or
-- an author's shelf reads. The Home-folders source had nothing to flatten:
-- its folders arrive as single drillable spines carrying only a first book,
-- so a folder-organised library got no sections at all. This module supplies
-- the missing grouping: the books, grouped by the directory they live in.
--
-- ── THE RULES ───────────────────────────────────────────────────────────────
--
--   one section per directory that directly holds books. A subdirectory is
--   its OWN section, never a member of its parent's, so the shelf shows the
--   real structure rather than one enormous run per top-level folder.
--
--   tree order: a directory's own books stand first, then its subdirectories
--   in name order, each recursively. A folder and everything under it stay
--   together on the shelf instead of being scattered alphabetically.
--
--   wrapper folders fold. A directory holding exactly one book and no
--   subdirectories is not a shelf section -- it is a container around a
--   single book, and its book joins its parent's section. This is the same
--   rule the spine shelf already applies when it stands such a folder AS its
--   book (_folderIsSingleBook in bookshelf_spine_shelf.lua), and it is what
--   stops a Calibre library -- Author/Title/book.epub, every leaf directory
--   holding exactly one file -- from becoming one section per book.
--
--   books loose at the library root form one section with no label. Badging
--   them with the home directory's name would say nothing.

local FolderSections = {}

-- Trailing slashes are a spelling of the same directory, not a different one.
local function _stripTrailing(p)
    if type(p) ~= "string" then return nil end
    while #p > 1 and p:sub(-1) == "/" do p = p:sub(1, -2) end
    return p
end

-- group(entries, root) -> { {label=<dir name or nil>, path=<abs>, fps={...}}, ... }
--
-- entries are the walk's records ({ fp = <absolute path>, ... }); bare path
-- strings are accepted too. Anything outside `root` is dropped rather than
-- filed somewhere arbitrary. fps keep the order they arrived in, since the
-- caller's sort_priority is what decides how a section's books stand.
function FolderSections.group(entries, root)
    root = _stripTrailing(root)
    if not entries or not root or root == "" then return {} end

    -- Build the directory tree the paths imply. `order` records first-seen
    -- child order; the emit pass sorts by name, but keeping the list means a
    -- node knows how many subdirectories it has, which is half the
    -- wrapper-folder test.
    local prefix = root .. "/"
    local tree = { path = root, fps = {}, dirs = {}, order = {} }
    for i = 1, #entries do
        local e = entries[i]
        local fp = type(e) == "table" and e.fp or e
        if type(fp) == "string" and fp:sub(1, #prefix) == prefix then
            local node, start = tree, #prefix + 1
            while true do
                local slash = fp:find("/", start, true)
                if not slash then break end
                local name = fp:sub(start, slash - 1)
                local child = node.dirs[name]
                if not child then
                    child = { path = node.path .. "/" .. name, name = name,
                              fps = {}, dirs = {}, order = {} }
                    node.dirs[name] = child
                    node.order[#node.order + 1] = name
                end
                node, start = child, slash + 1
            end
            node.fps[#node.fps + 1] = fp
        end
    end

    local sections = {}
    local function visit(node)
        local names = {}
        for i = 1, #node.order do names[i] = node.order[i] end
        table.sort(names)
        -- The wrapper test reads the ORIGINAL directory: one book file and
        -- no subdirectories. Checked before descending, so a parent that
        -- collects a folded book cannot be mistaken for a wrapper itself --
        -- a directory containing only another directory is not a container
        -- around a book, whatever ends up in it here.
        local own, keep = node.fps, {}
        for _, name in ipairs(names) do
            local child = node.dirs[name]
            if #child.fps == 1 and #child.order == 0 then
                own[#own + 1] = child.fps[1]
            else
                keep[#keep + 1] = child
            end
        end
        if #own > 0 then
            sections[#sections + 1] =
                { label = node.name, path = node.path, fps = own }
        end
        for _, child in ipairs(keep) do visit(child) end
    end
    visit(tree)
    return sections
end

return FolderSections
