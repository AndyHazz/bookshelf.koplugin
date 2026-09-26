# Shelf sources for other plugins

Bookshelf shelves normally show books from the device's own library. A **shelf source** lets another plugin put its own books on a shelf instead: a server's catalogue, a store's library, anything that is not files Bookshelf walks. The reader adds a shelf, picks your source under **Source / grouping**, and from then on it behaves like any other shelf: it can be renamed, moved, hidden, and (for most sources) sorted and filtered.

Bookshelf's own Kindle library and Kobo library shelves are built this way, through the same interface described here (`lib/bookshelf_builtin_sources.lua`), so it is used every day and not just offered.

This is **version 1** of the interface. The reference that code is checked against is the comment at the top of `lib/bookshelf_sources.lua`; this guide is the friendlier walk through it.

## Registering

From your plugin, once Bookshelf is loaded:

```lua
local function register(ui)
    local bs = ui and ui.bookshelf
    if not (bs and bs.registerSource and (bs.SOURCE_API or 0) >= 1) then
        return false   -- no Bookshelf, or one too old: carry on without it
    end
    local ok, why = bs:registerSource("komga", MySpec)
    if not ok then logger.warn("komga: shelf source refused:", why) end
    return ok
end

function MyPlugin:init()
    -- Plugins load in name order, so Bookshelf may not be there yet.
    if not register(self.ui) then
        UIManager:nextTick(function() register(self.ui) end)
    end
end
```

- The id (`"komga"` here) is what a shelf stores as its `source.kind`. Choose it once and never change it, or readers' shelves stop finding you. It must be a short word; Bookshelf's own kinds (`all`, `series`, `opds` and so on) are refused.
- The registry lives for the whole KOReader session, across the file browser and the reader. Registering again with the same id replaces the old spec, so registering from every `init` is fine.
- `registerSource` returns `true`, or `false` and a reason: a missing function, a spec asking for a newer interface than this Bookshelf has (`api = 2` on a version 1 Bookshelf), and so on.
- `ui.bookshelf:unregisterSource(id)` takes it away again.

A shelf whose source is not registered (your plugin is disabled, or not installed yet) shows empty rather than erroring, and comes back when you register.

## Two ways to supply books

Every spec needs `label` and `available`, and exactly one of `list` or `fetch`.

**List mode** is for a source that can hand over every book at once and let Bookshelf do the rest. Bookshelf filters, sorts and pages the list with the shelf's own settings, counts it for search if you ask, and draws it in any view including Spines. The Kindle and Kobo libraries work like this.

```lua
{
    api       = 1,
    label     = function() return _("My library") end,
    available = function() return MyLibrary:isReady() end,
    list      = function(source) return MyLibrary:allBooks() end,
}
```

**Fetch mode** is for a source that pages and orders itself, such as a server catalogue, possibly with folders to drill into. Bookshelf shows what you return, in your order. The shelf editor shows "Server order" in place of its sort pickers and leaves out its Filters row, and the Spines view is not offered.

```lua
{
    api       = 1,
    label     = function() return "Komga" end,
    available = function() return Komga:hasServer() end,
    remote_prefix = "komga://",
    fetch = function(source, drill, offset, limit)
        return Komga:cachedPage(source, drill, offset, limit)   -- items, total
    end,
}
```

`fetch(source, drill, offset, limit)`:

- `source` is the shelf's own source table, `{ kind = "komga", ... }` plus anything your `pick` put there (see below). One spec can serve several shelves this way, one per library or server.
- `drill` is `nil` at the shelf's top level, or the drill entry for the folder the reader has opened.
- `offset` is 0-based; `limit` is how many items the screen wants.
- Return the items for that slice and the **total** number of items at this level. If you don't know the total yet, return `nil` and the footer offers a next page for as long as pages come back full.

**`fetch` must be quick.** It runs on every redraw of the shelf, on the UI thread. Answer from whatever you already hold, start any network work in the background, and when more has arrived call:

```lua
ui.bookshelf:sourceChanged("komga")
```

The shelf redraws if it is showing your source, and asks `fetch` again. Bookshelf itself never fetches on your behalf. That also means you decide when to reach the network; readers generally expect that to happen only when they have asked for something, such as opening your shelf, turning a page or pulling down to refresh.

## Records

A record is a plain Lua table with the same fields a book on the device has. The ones worth setting:

| Field | Meaning |
|---|---|
| `filepath` | Required. A real path for a book on the device, or under your `remote_prefix` for one that is not (see below). It is the book's identity, so keep it stable. |
| `title`, `display_title` | The title, and optionally the form to show. |
| `author`, `authors` | The first author as a string, and all of them as a list of strings. |
| `series_name`, `series_num` | Series and number (the number as a string). |
| `cover_image_path` | A cover image **on the device** (jpg or png). Download remote covers yourself and point this at the file. |
| `book_pct`, `percent_finished` | Progress, 0 to 1. Set both: one is drawn, the other sorted on. |
| `status`, `read_status` | `"unread"`, `"reading"` or `"finished"`. Set both, for the same reason. |
| `rating` | 1 to 5, or nil. |
| `last_opened`, `last_read_time`, `added_time` | Unix times, for the sorts. |
| `format` | Upper case, e.g. `"EPUB"`, `"CBZ"`. The Format filter compares it literally. |

Bookshelf adds `source_kind = "<your id>"` to every record it gets from you, so it can find its way back. Anything else you put on a record is left alone and comes back to your hooks, so carry your own ids there.

For a record whose `filepath` is a real file, Bookshelf reads that book's KOReader progress and status itself as it would for any book. It does not look up a cover in KOReader's cover cache for your records, so set `cover_image_path` (or give a `cover` hook) if you want covers.

## Folders (fetch mode)

A record with `is_folder = true` is a folder. It draws as a navigation tile, the kind OPDS subcatalogues use, showing its `title` and, if you give one, `cover_image_path`.

Tapping it drills in. Bookshelf asks `open_folder(record)` for a **drill entry**, or uses the record's own `drill` field if you don't give the hook:

```lua
open_folder = function(folder)
    return { label = folder.title, series_id = folder.komga_id }
end,
```

The drill entry can be any table; its `label` names the breadcrumb. Bookshelf then calls `fetch(source, <that entry>, 0, limit)`. Back-swipe and the breadcrumb return the reader up a level as with any other folder.

The folder the reader is in is **not** restored after KOReader restarts: they land on the shelf's top level. (A drill entry may hold anything, so Bookshelf does not try to save it.)

## Books that are not on the device yet

Set `remote_prefix = "komga://"` in the spec and give such books a `filepath` under it (`"komga://book/1234"`). Bookshelf then treats them as not being files: it never looks for a sidecar, statistics or a KOReader cover for them, and the book popup's file actions are not offered.

The prefix must look like `name://`, and should be unique to your plugin.

## Opening a book

```lua
open = function(book, ctx)
    if MyCache:has(book) then return MyCache:path(book) end   -- open this file
    MyServer:download(book, function(path)
        ctx.open(path)                                         -- open it when it lands
    end)
    return true                                                -- handled
end,
```

`open(book, ctx)` can return:

- a **path**: Bookshelf opens that file;
- **`true`**: you handled it. Call `ctx.open(path)` later to open a file, for example when a download finishes;
- **`false` or nothing**: Bookshelf opens `book.filepath` itself, if it is a file.

`ctx.widget` is the shelf. Without an `open` hook, a record with a real `filepath` opens normally.

On the shelf, the first tap on a remote book previews it in the top panel and the second tap opens it (through your `open`), the same as a catalogue book. Long-press calls `info(book, ctx)` if you give it, for your own details or download dialog; otherwise Bookshelf shows the title and author.

## The source picker

Your source appears as a row in the **Source / grouping** picker while `available()` is true. Set `picker = false` to leave it out.

Without a `pick` hook, choosing the row sets the shelf's source to `{ kind = "<your id>" }`. With one, you can ask your own question first, such as which server or which library:

```lua
pick = function(draft, done)
    MyUI:chooseLibrary(function(lib)
        if not lib then return done(false) end   -- cancelled: the shelf keeps its old source
        draft.source.library = lib.id            -- draft.source.kind is already set
        draft.label = lib.name                   -- optional: name the shelf after it
        done()
    end)
end,
```

Whatever you put in `draft.source` is saved with the shelf and handed back to `fetch` or `list` as `source`. Keep it to plain values (strings, numbers, booleans, and tables of them), because it is written to the settings file.

## Refresh

When the reader swipes down on your shelf, Bookshelf calls `refresh(source, drill, done)` for the level on screen. Fetch what is new, then call `done()` and the shelf redraws. Without a `refresh` hook, a swipe down does Bookshelf's usual library refresh and redraw.

## The rest of the spec

| Field | Mode | Purpose |
|---|---|---|
| `api` | both | The interface version you wrote against. `1` for now. |
| `sort_default` | list | `{ { key = "title", reverse = false } }`, the sort a new shelf starts with. |
| `new_shelf(draft)` | both | Adjust a new shelf's defaults (a starting filter, say). |
| `library` | list | `true` to count your books as part of the library for search and the finished-books tallies, once the reader has a shelf of your source. Off unless you set it. |
| `cover(record)` | both | Return `bb, w, h`, a fresh blitbuffer for a record with no cover file. Called for the visible page only. The grid frees it after painting, so return a new one each call. |
| `owns(book)` | both | `true` if a book is yours even without the `source_kind` stamp, for example after Bookshelf rebuilt it from its path. |
| `invalidate(filepath)` | list | A file changed (or everything did, with `nil`): drop any cache. |

## What to expect from Bookshelf

- **Every call into your spec is guarded.** If a hook throws, Bookshelf logs `[bookshelf] source: <hook> failed: ...` and carries on: a failing `fetch` or `list` is an empty shelf, a failing `open` falls back as if it returned nothing.
- **`available()` is asked often.** Keep it cheap.
- **Version 1 will not change under you.** New optional hooks may appear in a later version; a change that could break a version 1 spec would come as version 2, with `SOURCE_API` telling you which you have.
- **Not in version 1:** shelf-editor rows of your own (your own sort and filter controls), custom badges on folder tiles, a saved drill position across restarts, and Spines for fetch-mode shelves. Tell us which of these you need.

## A complete example

A fetch-mode source with folders, remote books and downloads, trimmed to the parts that matter:

```lua
local Komga = { pages = {} }   -- your cache, keyed however suits you

local spec = {
    api = 1,
    label = function() return "Komga" end,
    available = function() return Komga.server ~= nil end,
    remote_prefix = "komga://",

    pick = function(draft, done)
        Komga:chooseLibrary(function(lib)
            if not lib then return done(false) end
            draft.source.library = lib.id
            draft.label = lib.name
            done()
        end)
    end,

    fetch = function(source, drill, offset, limit)
        local key = (source.library or "") .. "|" .. (drill and drill.series_id or "top")
        local page = Komga.pages[key]
        if not page then
            Komga:fetchInBackground(key, source, drill, function()
                Komga.ui.bookshelf:sourceChanged("komga")   -- Komga.ui: kept at init
            end)
            return {}, nil
        end
        local out = {}
        for i = offset + 1, math.min(offset + limit, #page.items) do
            out[#out + 1] = page.items[i]
        end
        return out, page.total
    end,

    open_folder = function(folder)
        return { label = folder.title, series_id = folder.komga_id }
    end,

    open = function(book, ctx)
        local local_path = Komga:downloadedPath(book.komga_id)
        if local_path then return local_path end
        Komga:download(book, function(path) ctx.open(path) end)
        return true
    end,

    refresh = function(source, drill, done)
        Komga:dropCache(source, drill)
        Komga:fetchInBackground(nil, source, drill, done)
    end,
}
```

A series from Komga would come back from `fetch` as `{ is_folder = true, title = "Saga", komga_id = "abc", cover_image_path = "/mnt/.../abc.jpg" }`, and a book as `{ filepath = "komga://book/xyz", title = "Saga #1", komga_id = "xyz", cover_image_path = ... }`.
