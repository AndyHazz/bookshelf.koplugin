<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/AndyHazz/bookshelf.koplugin/master/assets/bookshelf-logo-dark.png">
    <img alt="Bookshelf" src="https://raw.githubusercontent.com/AndyHazz/bookshelf.koplugin/master/assets/bookshelf-logo.png" width="320">
  </picture>
</p>

# Bookshelf

A friendly home screen for KOReader. Browse your library by series, author, genre, collection, or anything you like; pick a book, glance at its cover, blurb, rating, and progress, and start reading. A build-your-own [start menu](#the-start-menu) puts your shortcuts, folders, and live panels a tap away in the corner.

<p align="center">
  <img src="https://github.com/user-attachments/assets/82f95a3e-7914-4236-855f-31d8dd09d83c" width="19%" alt="Bookshelf home screen" />
  <img src="https://github.com/user-attachments/assets/574976b3-c82d-4eeb-a8ac-848ea113aa35" width="19%" alt="Series view" />
  <img src="https://github.com/user-attachments/assets/abcdf0b2-a06b-46d4-9055-e710f2a124b5" width="19%" alt="Chip bar editor" />
  <img src="https://github.com/user-attachments/assets/b916c194-7423-4418-96c3-d0367119f45c" width="19%" alt="Hero card line editor" />
  <img src="https://github.com/user-attachments/assets/95799321-18fe-4495-84f4-73388a1ecc35" width="19%" alt="Library search" />
</p>

## Install

1. Download the latest **bookshelf.koplugin.zip** from [Releases](https://github.com/AndyHazz/bookshelf.koplugin/releases).
2. Unzip it onto your device's KOReader plugins folder:

   | Device | Plugins folder |
   |--------|----------------|
   | Kindle | `/mnt/us/koreader/plugins/` |
   | Kobo | `/mnt/onboard/.adds/koreader/plugins/` |
   | Android | `<koreader-dir>/plugins/` |

3. Restart KOReader.
4. Open KOReader's menu and set **Start with -> Bookshelf**. Without this, KOReader opens its standard file browser on launch; you can still open Bookshelf manually from the menu.

   > The **Start with** setting only appears in the menu of KOReader's **File Manager** screen, not while a book is open. If you can't find it, close the book first (or launch KOReader without one open), then open the menu from the file browser.

> **You also need CoverBrowser enabled** (Settings -> More plugins -> CoverBrowser). It supplies the covers and metadata Bookshelf uses. If it's disabled, Bookshelf shows a one-time notice and steps aside to KOReader's standard file browser.

Once it's running, the top menu has a **Bookshelf** section with everything else: chips, the book detail view, collections, updates, and settings.

---

## A quick tour

### The chip bar (top of the screen)

Each "chip" is a shelf. Tap one to switch shelves. Out of the box you get **Home**, **Recent**, **Series**, and **Favourites**, but you can rename, reorder, hide, or delete any of them and add as many of your own as you like.

A chip can point at:

- **Home** -- your library as folders, or as a flat list of every book.
- **Recent** or **Latest** -- books you read recently, or books added recently.
- A **stack** of series, authors, genres, collections, formats, ratings, or reading statuses. Tap a stack to drill into one of its members.
- A **specific** series, author, genre, collection, format, rating, folder, or reading status -- a shelf showing just that one slice of your library.
- **Favourites** -- the built-in starred shelf.

Each chip remembers its own reading-status filter (Unread, Reading, On hold, Finished), sort priority (up to three levels deep, e.g. *surname, then series, then series number*), label, icon, and whether it's enabled.

**To edit a chip:** long-press it. The footer of the editor has **+ Add new chip** if you'd like to start a fresh one.

The same menu (**menu -> Bookshelf chips…**) also has **Chip bar font size** for adjusting how big the chips render across the top of the screen.

### Searching

Tap the search icon at the right of the chip bar. Search looks across folders, authors, series, genres, collections, and book titles in one go, and groups the results by category. Tapping a result drills into it; back-swipe to return to whichever shelf you were on.

### The hero card (top of the shelf area)

The big card at the top of the screen previews the focused book. Tap a cover on the grid to focus it; the card refreshes with its title, author, description, rating, and progress. Tap the hero card cover to open the book.

The hero card has eight sections you can show, hide, or restyle:

- **Status line** -- top right; defaults to disk space, battery, frontlight, Wi-Fi, and time.
- **Rating** -- five tappable stars (off by default; tap a star to set or clear).
- **Title**
- **Author**
- **Metadata** -- a free-form line; the default shows the series and series number for books in a series.
- **Description** -- the book blurb. Tap to read the full text in a scrollable viewer.
- **Tags (interactive)** -- a strip of tappable pills for the book's author, series, genres, collections, and parent folder. Tap a pill to jump straight to that shelf. Off by default.
- **Progress** -- bottom-anchored line with an inline progress bar.

To edit them, open **menu -> Edit book detail view** (see [Customising the hero card](#customising-the-hero-card) below).

### Micro-modules on the home screen

<p align="center">
  <img src="https://raw.githubusercontent.com/AndyHazz/bookshelf.koplugin/master/assets/hero-grid.png" width="32%" alt="Home screen showing a grid of micro-modules" />
</p>

The home screen can show a grid of **micro-modules** -- small live panels like a clock, a quote from your highlights, your reading goal, the weather, or a launcher button. These are the same modules you can add to the [start menu](#micro-modules).

Under **Bookshelf settings -> Micro-modules** you choose where they live:

- **In the hero area** -- the grid replaces the book preview at the top of the shelf. Tap the **grid chip** (right end of the chip bar) to switch between the book preview and the grid.
- **Full-screen button** -- a grid button sits in the footer opposite the start menu; tapping it opens the modules full-screen as a dashboard, with the status line across the top. Close it with the **X**, a tap on empty space, or Back. The usual KOReader gestures (top-edge menu, edge swipes for brightness, corner actions) still work over it. This is the default for new installs.
- **Off** -- no micro-modules.

In either grid:

- **Long-press a module** to move it, make it wider or narrower (`-` / `+`), or send it to one of four pages.
- **Swipe left/right** on the grid, or tap the in-grid arrows, to flip between pages.
- **Tap the +** in a module's long-press menu to add another from the picker; long-press the **grid chip** (hero placement) to reset the grid to its defaults or turn micro-modules off.
- On **physical-button (D-pad) devices**, move the cursor across the grid with the arrow keys, open a module with the centre key, and long-press to edit it.

The grid packs square modules (clocks, launcher icons) tightly and lets text modules fill the rest of the row, and only the page you're on is rendered. Set the number of **columns and rows** under **menu -> Edit shelf layout**. Hero micro-modules have their own entry under **menu -> Text size** so you can scale the grid independently of the book hero.

### The shelf grid (the books)

Each cover on the grid is either a book or a stack of books (for series, authors, etc.).

- **Tap** a book to preview it in the hero card.
- **Tap** the hero card cover to actually open the book.
- **Long-press** a book to open the book menu (see below).
- **Long-press** a stack to pin it to the chip bar as its own shelf.
- **Swipe up** to collapse the hero and show more books at once.
- **Swipe down** on the hero to restore it; **swipe down** on the shelf area to refresh the library after adding new books over USB or Calibre.

The full gesture reference is in [Gestures cheatsheet](#gestures-cheatsheet) below.

### Folder shortcuts and jump-to-folder gestures

If a KOReader folder shortcut, the "go to parent folder" or "go home" gesture, or any plugin points the file browser at a folder while Bookshelf is open, Bookshelf follows into that folder rather than leaving you on the previous shelf. The folder is added to the breadcrumb trail, so a back-swipe returns you to where you were. Opening an actual book still goes straight to the reader as usual.

---

## The start menu

<p align="center">
  <img src="https://raw.githubusercontent.com/AndyHazz/bookshelf.koplugin/master/assets/start-menu.png" width="32%" alt="Start menu open with a folder flyout" />
  <img src="https://raw.githubusercontent.com/AndyHazz/bookshelf.koplugin/master/assets/micromodules.png" width="32%" alt="Micro-module picker" />
</p>

Tap the menu button in the bottom corner of the shelf, in line with the page arrows, to open a popup launcher you build yourself. Think of it as a Start menu for your home screen.

Each item can be:

- A **KOReader action** -- history, the reading calendar, Wi-Fi, night mode, sleep, frontlight, and anything else from KOReader's action list.
- **Another plugin** -- launch any installed plugin that has a menu entry (games included).
- A **Bookshelf action** -- the full Bookshelf menu (settings, the book detail editor, collections, and the rest), or exit Bookshelf.
- A **folder** -- group items together; it flies out to the side when you tap it.
- A **micro-module** -- a small live panel (see below).

**Building and editing it.** Long-press any item for **rename**, **change icon**, **move up / down**, **move into / out of a folder**, **delete**, and **add new menu item**. Adding walks you through the categories above; the icon picker is a built-in glyph grid (no extra plugins needed). Folders open downward from the row you tapped, overlapping the menu so they read as connected.

**Position.** Under **Bookshelf settings -> Start menu** you can put the button on the **left**, the **right**, or turn it **off**. It works with touch and with physical-button (D-pad) devices.

### Micro-modules

Micro-modules are small live panels. Add them to the start menu through **Add new menu item -> Bookshelf micro-module…**, or to the [home-screen grid](#micro-modules-on-the-home-screen). The ones that ship with Bookshelf:

- **Clock** -- digital (12- or 24-hour) or analogue.
- **Quote of the day** -- a highlight drawn from your own books, refreshed daily or on every open. Tapping it can roll a new quote, open that book's bookmark list, or open the book at the highlight.
- **Reading goal** -- progress towards a daily reading target.
- **Reading stats** -- time and pages read today and this week (needs the `statistics` plugin).
- **Reading streak** -- your current and best reading streak, in days and weeks (needs the `statistics` plugin).
- **Random book** -- rolls an unread book from the current shelf (or your whole library) into the hero card; tap the dice for another.
- **Shelf count** -- how many books are on the current shelf.
- **Weather**, **On this day**, **Trivia**, **Daily fun** (jokes, facts and riddles) -- live content from the internet.
- **Action** -- a launcher card that runs a plugin, a KOReader action, or a Bookshelf action, with your own icon and an optional label.

Each module can carry its own settings (reached via **Module settings…** when you long-press it). Modules that need the internet show their data source in the picker rather than fetching while you browse. Modules are a small self-contained format: if you write a little Lua you can add your own by dropping a file into the plugin's `micromodules/` folder, and a bad one is skipped rather than breaking the menu. See `micromodules/README.md` for the contract.

---

## The book menu (long-press a cover)

Long-press any cover on the shelf or in the hero card to open the book menu. The header shows a cover thumbnail, the book's title and author, and a strip of **navigation pills** -- tappable shortcuts to the book's author, series, collections, genres, and parent folder. Tap any pill to drill into that shelf. When a book has bookmarks or highlights, a **N bookmarks ›** link sits under the header; tap it to open KOReader's bookmark browser for that book (and jump into it).

Below the header you'll find:

| Button | What it does |
|--------|--------------|
| **Unopened / Reading / On hold / Finished** | Reading status. Tap to change. Unopened clears progress and drops the book from Recent without touching highlights or bookmarks. |
| **Show info** | KOReader's built-in book info dialog. |
| **Collections (N)…** | Add or remove the book from any collection (Favourites, To Be Read, your own). The number shows current membership. |
| **Rating** | Set a 1-to-5 star rating, or clear it. |
| **Link to Hardcover** / **Edit Hardcover link** | Sits in its own row at the top of the menu, shown only when `hardcoverapp.koplugin` is enabled. Link the book to a Hardcover edition, or edit an existing link. When linked, a **Hardcover reviews** button appears beside it. See [Hardcover enrichment](#hardcover-enrichment). |
| **Refresh metadata** | Re-read the cover and metadata from the file (useful after editing metadata externally). |
| **Remove from history** | Drop the book from Recent without changing anything else on disk. |
| **Reset book data…** | A wider purge with checkboxes for progress, bookmarks, highlights, notes, custom cover, and custom metadata. |
| **Delete** | Permanently remove the file from disk (with a confirmation). |

Long-pressing a series, author, genre, collection, format, rating, or folder stack instead opens a single **Pin to chip bar** prompt -- the fastest way to turn a stack you've drilled into into a permanent shelf.

---

## Collections

Collections are named lists of books, and Bookshelf uses KOReader's built-in collection system, so anything you collect in Bookshelf shows up in KOReader's collection menu (and vice versa). Two collections come ready:

- **Favourites** -- the built-in starred shelf. Always present; can't be renamed or deleted.
- **To Be Read** -- a reading pile for things you haven't started yet.

Open **menu -> Manage collections…** to add new collections, rename or delete existing ones, and **pin** any collection to your chip bar as a dedicated shelf.

To put a book into a collection, long-press its cover and tap **Collections (N)…**. Tick the collections you want, then Save. The pill strip in the book menu's header updates immediately to reflect what's changed.

---

## Hardcover enrichment

If you also use `hardcoverapp.koplugin`, Bookshelf can link books to Hardcover and cache a small amount of Hardcover metadata for display. These features only appear when that plugin is installed and enabled, so they stay out of the way if you don't use Hardcover. The **Hardcover enrichment** menu (in the bookshelf menu, below Manage collections) also stays available if you've linked books before, so you keep access to already-cached data even after removing the plugin.

**Linking a book.** Long-press a cover; with the plugin enabled, a Hardcover row sits at the top of the book menu. **Link to Hardcover** (or **Edit Hardcover link** once linked) opens the link menu:

- **Auto link** -- links without searching, using identifiers embedded in the EPUB (an ISBN, or a Hardcover id/edition baked into the file). The most specific identifier wins (a Hardcover edition, then ISBN, then a Hardcover book/slug). If the file carries no usable identifier, Auto link falls back to a best-guess search by title and author.
- **Manual link…** -- searches Hardcover by title and author and lets you pick the right book.
- **Select edition…** -- once linked, choose a specific edition (e.g. to get the right cover or page count).
- **Use Hardcover image** / **Use Hardcover description** -- per-book toggles (shown once linked) that override the book's own cover or description with Hardcover's. See below for how these are set automatically.
- **Clear link** -- remove the Hardcover link.

When a book is linked, a **Hardcover reviews** button appears in the book menu (and the hero rating row's "N reviews" opens the same popup). Reviews are filtered to spoiler-free ones, and cached, so they reopen offline once fetched.

**Linking the whole library at once.** **Hardcover enrichment -> Auto-link all books** links every unlinked book in one pass, fetching each match's details (description, cover, rating) as it goes. You pick how to match:

- **Exact match** -- uses an embedded ISBN or Hardcover id. Fast, and only links books that carry one.
- **Best guess** -- searches by title and author and picks the most confident match. Slower, but catches books with no embedded id.

It contacts Hardcover at about one book per second with cancellable progress, and shows a report at the end listing what was linked, what wasn't matched, and what had no identifier to try.

**Choosing covers and descriptions.** Each linked book has its own **Use Hardcover image** and **Use Hardcover description** toggles. When you link a book, Bookshelf sets sensible defaults once: it adopts the Hardcover description if the book has none of its own, and the Hardcover cover if the book has no embedded cover or its cover is lower resolution than Hardcover's. After that the per-book toggle is yours -- it's never changed again by a later refresh. Turning **Use Hardcover image** on saves the Hardcover cover into the book's sidecar (`.sdr`) folder as a custom cover, so KOReader's own file browser shows it too; turning it off restores whatever was there before -- a cover you'd set yourself is preserved, never overwritten.

**Ratings and metadata.** Two more options sit in the **Hardcover enrichment** menu:

- **Show Hardcover ratings in hero** -- the hero rating row shows the cached public Hardcover rating instead of KOReader's local one (and turns the rating row on).
- **Use Hardcover metadata** -- for linked books, shows Hardcover's title, author, series and genres in place of the book's own (a clean switch, no merging). This feeds sorting, search and series grouping for those books; non-linked books are untouched. **Hardcover genres used** caps how many of a book's genres become tag pills and genre stacks. Covers and descriptions stay under their per-book toggles. The metadata is always cached, so this only decides whether it's used.

**Managing the cache.** **Hardcover enrichment -> Manage Hardcover data** holds **Refresh ratings only**, **Clear cache (keeps links)**, and **Remove all Hardcover data** (unlinks everything and restores any covers Bookshelf installed).

Bookshelf does not rewrite EPUB files. Descriptions, ratings and the other cached metadata live in Bookshelf's own cache; a chosen Hardcover cover is stored as KOReader's standard custom cover in the book's `.sdr` folder. Network calls only happen from explicit actions (linking, refreshing ratings, fetching reviews); normal shelf rendering reads only the local cache.

---

## Layout

Open **menu -> Settings -> Edit layout…** for a live overlay that resizes the grid without leaving the home screen. Two controls:

- **Bookshelf size** -- how much room the shelves get relative to the hero card.
- **Book size** -- how large the covers render, which also sets how many fit per row.

The layout auto-fits your screen and orientation, so the same settings adapt between portrait and landscape. Changes preview in real time behind the overlay; **Accept** keeps them, **Cancel** reverts.

---

## Cover indicators

Each cover can show small badges and bars at the corners. Configure them under **menu -> Settings -> Cover display**:

- **Show reading bookmarks** -- a bookmark mark on books you're partway through.
- **Show completed book badge** -- a check-mark pill at the bottom-left of finished books.
- **Show progress bars** -- a thin progress bar above the bottom edge for in-progress books.
- **Show page count** -- a "pN" pill in the bottom-right. (For EPUBs it works once you've opened the book at least once.)
- **Show series #** -- a "#3" badge on covers in a series. Tri-state: Always, Within series folder (so mixed shelves stay clean), or Never.

The colours of these elements are set separately under **Settings -> Colors** (see below).

---

## Colours

Open **menu -> Settings -> Colors** to recolour the cover chrome. Bookshelf keeps **independent day-mode and night-mode palettes** -- the top row of the menu shows which one you're editing ("Editing day-mode colours" / "Editing night-mode colours") and tapping it flips night mode so you can set each theme. Anything you leave unset uses a sensible default for that mode.

Each colour is chosen as a "% black on screen" value (so it reads the same way in both modes), and long-pressing a row resets just that colour. The pickers:

- **Progress bar** / **Progress bar track** -- the filled and unfilled parts of the cover progress bar.
- **Bookmark colour** / **Finished bookmark colour** -- the in-progress bookmark glyph and the finished-book check.
- **Favourite star colour** -- the star on favourited covers.
- **Badge foreground** / **Badge background** -- the text and fill of the "#N" series and "pN" page-count pills.
- **Border colour** -- one shared colour for cover frames, badge borders, the bookmark/star halos, the cardboard edge on folder and stack cards, and placeholder (no-image) covers.
- **Folder overlay background** -- the cardboard fill behind folder and stack cards.
- **Folder text colour** -- the label text on those cards (the card outline follows Border colour).
- **Reset to default colours** -- restore the whole palette for the current mode.

---

## Custom images for folders and stacks

Bookshelf can replace the default folder cover (cardboard card with the first book peeking above) and the stack covers (Authors / Series / Genres / Collections) with your own images. Three ways to set one:

- **Long-press the card** -> *Set folder image…* / *Set author image…* / etc. -> pick an image file. The image renders as that folder's or stack's cover with the cardboard tab + label staying on top so the group identity is still visible.
- **Drop `cover.jpg`, `cover.png`, `folder.jpg`, or `folder.png` into a folder** and Bookshelf picks it up automatically. The hidden dot-file variants (`.cover.jpg`, `.cover.png`, `.folder.jpg`, `.folder.png`) work too, for keeping the image out of the visible file listing; a visible file wins if both are present. The image follows the folder when you move it.
- **Drop named images into an image library** for authors, series, genres, and collections. The default location is `<your-library>/.bookshelf-images/` with subfolders `authors/`, `series/`, `genres/`, and `collections/`. Name each file after the exact stack name (e.g. `authors/Asimov, Isaac.jpg`) or use a slugified form as a fallback. The slug lowercases the name and turns runs of punctuation / whitespace into single dashes, preserving the original order — so `Asimov, Isaac` matches `asimov-isaac.jpg`, and `Isaac Asimov` matches `isaac-asimov.jpg`. Extensions tried in order: `jpg`, `jpeg`, `png`, `gif`, `bmp`, `webp`, `tiff`.

Pick a different image-library location under **menu -> Settings -> Advanced settings -> Image library**.

Long-press an image-set folder or stack and tap *Clear … image* to revert to the cardboard default.

---

## Author names

By default Bookshelf shows author names however each book stores them, so the same person can appear two ways (e.g. *Richard Osman* and *Osman, Richard*). Under **menu -> Settings -> Advanced settings -> Author name formatting** you can pick:

- **Auto** -- leave names as stored (the original behaviour; first form found wins).
- **First Last** -- always *Forename Surname*.
- **Last, First** -- always *Surname, Forename*.

Whichever you choose, variant spellings of the same author are merged into one entry on the Authors shelf, and the alpha-jump / surname sort uses the surname -- including names with particles like *de Maupassant*, which sort under **M**.

---

## Customising the hero card

Open **menu -> Edit book detail view** to toggle each of the eight sections on or off. The same menu has a **Font scale** entry at the top for resizing everything in the hero card at once (50-200%). Tap a section's row to open its **line editor**.

The **Tags** section is an interactive pill strip rather than a line of text, so instead of the line editor its row opens a small submenu: turn the line on or off, choose which pill categories to show (**Author**, **Series**, **Collections**, **Genres**, **Folder**), and set the **Font size** and **Alignment**. Turning off Author and Series, for instance, leaves a line of just the real tags. The **Rating** section is interactive too and is a simple on/off toggle.

The line editor lets you change the text and styling of one section. You'll see these controls:

| Button | What it does |
|--------|--------------|
| **Bold** | Toggle bold weight. |
| **Size** | A nudge dialog (-5 / -1 / +1 / +5) over the font size, range 8 to 48 pixels. |
| **Font** | Pick a font family. Shows previews when [Bookends](https://github.com/AndyHazz/bookends.koplugin) is installed. |
| **Aa / AA** | Toggle uppercase (hidden on the Description section). |
| **L / C / R** | Cycle alignment (left, centre, right). |
| **Bar style** | (Progress only) Cycle the inline progress bar's visual style. |
| **+ Bar / - Bar** | (Progress only) Add or remove the `%bar` placeholder. |
| **Bar height** | (Progress only) Nudge the inline bar's height as a percentage. |
| **Tokens…** | Pick from a categorised list of placeholders (see below). |
| **Icons…** | Insert icon glyphs from the built-in icon library (a searchable, categorised glyph grid). |
| **Default** | Reset this section's text and styling to its defaults. |
| **Cancel** | Revert and close. |
| **Save** | Persist and close. |

Edits update the hero card behind the editor in real time.

### Tokens (placeholders)

Any text in a hero section can include **tokens** -- placeholders that get replaced with live data. For example, `%title` becomes the book title; `%book_pct` becomes the percentage read.

You can wrap things in `[if:...]...[/if]` to show them only when the relevant data exists. For instance, `[if:series]%series_name #%series_num[/if]` only renders when the book is in a series.

The full token list is in the [Token cheatsheet](#token-cheatsheet) below.

---

## Bundled fonts

Bookshelf ships three open-licensed fonts (see `fonts/CREDITS.md`):

- **Roboto Condensed** (Apache 2.0) -- the default Bookshelf UI font on new installs.
- **Inter ExtraBold** (OFL) -- default hero title.
- **Caveat** (OFL) -- default hero author.

Set the interface font under **Bookshelf settings -> Bookshelf UI font** (defaults to
*Follow KOReader UI font* for existing users). The fonts are also copied into your font
folder so they're selectable in the hero card's font picker after a restart. Existing
users can adopt the new detail look via **Reset book detail area to defaults**.

---

## Updates

Open **menu -> Updates** to keep Bookshelf current:

- **Notify on wake when update available** -- opt-in. Once an hour after a Wi-Fi-connected wake, Bookshelf checks the GitHub releases page and posts a quiet notification if a new version is out. Off by default; nothing is ever fetched without your permission.
- **Installed version / Update available** -- the current installed version. When a newer release exists, tap the row to read the release notes and choose **Update and restart**.
- **Developer updates** (advanced) -- type a development branch name (e.g. `feat/foo`) to install the tip of that branch. Use **Reset to latest stable release** to clear the dev branch and pull the latest published release.

The whole download, unpack, and restart sequence runs over Wi-Fi only and needs no extra plugins.

---

## Library refresh

After adding new books over USB, Calibre, Syncthing, or KOReader's network downloads:

- **Automatically** -- Bookshelf watches your library folder in the background and picks up newly added books on its own, with no interaction needed.
- **Tap a chip** -- it also checks for filesystem changes on chip taps.
- **Swipe down** on the shelf area for an immediate, full refresh; a brief "Refreshing library" notice appears.

---

## Reference

Everything beyond this point is the full feature reference. Expand any section you need.

<a id="gestures-cheatsheet"></a>
<details>
<summary><strong>Gestures cheatsheet</strong></summary>

| Gesture | Where | What it does |
|---------|-------|--------------|
| **Tap** | Shelf cover (normal mode) | Preview the book in the hero card |
| **Tap** | Shelf cover (expanded mode) | Open the book directly |
| **Tap** | Hero card cover | Open the previewed book |
| **Tap** | Hero card description | Open the full description in a scrollable viewer |
| **Tap** | Hero card star | Set / clear the book's rating |
| **Tap** | Chip | Switch shelf |
| **Tap** | Search icon | Open the library search |
| **Tap** | "Page N of M" footer | Open the go-to dialog: jump by page number, jump to the first item starting with a letter, or search the library |
| **Tap** | First / prev / next / last chevrons | Page navigation |
| **Long-press** | Chip | Open the chip editor |
| **Long-press** | Shelf book cover | Open the per-book menu |
| **Long-press** | Shelf stack cover (series, author, etc.) | Pin the stack to the chip bar |
| **Long-press** | Prev / next chevron | Skip 10 pages back / forward (clamped to first / last) |
| **Long-press** | Hero card | Open the per-book menu for the previewed book |
| **Swipe west** (<-) | Hero card | Cycle preview to the next book in the active chip |
| **Swipe west** (<-) | Anywhere else | Next page; on the last page, drills out or switches chip |
| **Swipe east** (->) | Hero card | Cycle preview to the previous book |
| **Swipe east** (->) | Anywhere else | Previous page / drill back out / previous chip |
| **Swipe north** (up) | Anywhere | Collapse hero to a thin status strip; expand the grid |
| **Swipe south** (down) | Hero | Restore the full hero from expanded mode |
| **Swipe south** (down) | Shelf area | Refresh the library walk |

The pagination row uses wide tap zones across the middle 75% of the screen. The outer 12.5% on each side is left free so KOReader's bottom-corner gestures (gestures.koplugin profiles for brightness, night mode, etc.) still register.

</details>

<details>
<summary><strong>Chip sources, filters, and sorts</strong></summary>

#### Sources

Each chip points at one of:

- **Home (folders)** -- your library as a folder tree.
- **Home (flat)** -- every book in one list, no folders.
- **Recent** -- books you've opened, newest-read first.
- **Latest added** -- new files on disk, newest-added first (scan depth set under Advanced settings -> "Latest" walk depth).
- **Favourites**
- **Series**, **Authors**, **Genres**, **Collections**, **Formats**, **Ratings**, **Languages** -- a stack of all the values; drill into one to see its books.
- **Specific** series / author / genre / collection / format / rating / language / folder / reading status -- a shelf scoped to a single chosen value.
- **Folder (flattened)** -- a single folder shown as every book beneath it in one list, no sub-folder cards (vs. the plain folder source, which keeps the sub-folder tree).

#### Reading-status filter

Any combination of **Unread**, **Reading**, **On hold**, and **Finished**. Off by default (everything visible).

#### Sort priority

Up to three levels per chip. Available sort keys:

- **Title**, **Filename**
- **Author surname**, **Author (given name)**
- **Series name**, **Series index**, **Series + index** (series name then number, in one pick)
- **Last opened** (most-recent-first by default)
- **Date added** (most-recent-first by default)
- **Percent read** (most progress first by default)
- **Rating** (highest first by default; unrated last)
- **Unread/Reading/Finished** or **Reading/Unread/Finished** (status orderings)
- **File size**
- **Page count**
- **Book count** (for stacks)

Defaults adjust to the source (e.g. Recent defaults to *Last opened*; Latest added defaults to *Date added*). The first-level sort decides the order of stacks for grouped sources; subsequent levels order books within each stack.

</details>

<details>
<summary><strong>Hero card line editor</strong></summary>

The book detail card has **eight editable sections**: Status, Rating, Title, Author, Metadata, Description, Tags (interactive), and Progress. The Tags section shows tappable pills rather than a text template, so it has no line editor; toggle it on or off like the others.

Open **menu -> Edit book detail view** to toggle each section on or off. Tap a section's row (when its toggle is on) to open the **line editor**.

Edits live-update the hero behind the editor on every keystroke; only the right column of the card is rebuilt, so the cover stays untouched.

#### Editor buttons

| Button | What it does |
|--------|--------------|
| **Bold** | Toggle bold weight |
| **Size** | -5 / -1 / +1 / +5 nudge over the font size (range 8-48 px) |
| **Font** | Font family picker |
| **Aa / AA** | Case toggle (hidden on Description) |
| **L / C / R** | Alignment cycle (left / centre / right) |
| **Bar style** | (Progress only) Cycle inline progress-bar styles |
| **+ Bar / - Bar** | (Progress only) Insert or remove the `%bar` token in the template |
| **Bar height** | (Progress only) Nudge the inline bar's height (% of text height) |
| **Tokens…** | Categorised token catalogue with live preview |
| **Icons…** | Insert icon glyphs from the built-in icon library (searchable glyph grid) |
| **Default** | Reset this section's template and styling to defaults |
| **Cancel** | Revert and close |
| **Save** | Persist and close |

#### Bookends extras

Several editor surfaces use the [Bookends](https://github.com/AndyHazz/bookends.koplugin) plugin when it's installed. Everything degrades gracefully when it isn't:

| Surface | With Bookends | Without |
|---------|---------------|---------|
| Token picker | Modal with chips, search, live preview | Plain Menu over the token catalogue |
| Font picker | Each family rendered in its own typeface, weight variants deduped | Plain Menu over the system font list |
| Progress-bar styles | 7 styles (`bordered`, `solid`, `rounded`, `metro`, `wavy`, `radial`, `radial_hollow`) | 2 styles (`bordered`, `solid`) |

The icon picker is built in and needs no extra plugins.

</details>

<a id="token-cheatsheet"></a>
<details>
<summary><strong>Token cheatsheet</strong></summary>

Tokens are placeholders prefixed with `%`. Conditional logic uses `[if:cond]…[/if]` (with optional `[else]`).

#### Book metadata

| Token | Example |
|-------|---------|
| `%title` | *The Great Gatsby* |
| `%author` | *F. Scott Fitzgerald* (first author) |
| `%author_2` / `%author_3` | second / third author (empty if absent) |
| `%authors` | *Neil Gaiman, Terry Pratchett* (all authors) |
| `%author_count` | *2* (number of authors) |
| `%authors_short` | first author, or *A and B*, or *A, B, et al.* for three or more |
| `%series` / `%series_name` | *Dune* |
| `%series_num` | *1* |
| `%rating` | *★★★☆☆* (empty when unrated) |
| `%rating_number` | *3* (1-5, empty when unrated) |
| `%hardcover_rating` | *4.5* (cached Hardcover rating, empty when unavailable) |
| `%hardcover_stars` | Cached Hardcover rating as star glyphs |
| `%status` | *reading* (unread / reading / on_hold / finished) |
| `%filename` | *The_Great_Gatsby* |
| `%format` | *EPUB* |
| `%lang` | *en* |
| `%description` | Book blurb (HTML stripped, entities decoded) |
| `%quote` | A random highlight from this book, in quotation marks (a fresh one each time you select the book; empty if the book has no highlights). Handy in the Description section in place of the blurb. |
| `%quote_source` | The book and author for `%quote` |

#### Position and progress

| Token | Example |
|-------|---------|
| `%page_num` / `%page_count` | *42* / *218* |
| `%pages_left` | *176* |
| `%book_pct` / `%book_pct_left` | *19%* / *81%* |
| `%bar` | Inline progress-bar widget (Progress section only) |
| `%spacer` | Elastic gap that pushes content left/right. `Reading%spacer47%` renders *Reading* on the left and *47%* on the right. |

#### Statistics (requires the `statistics` plugin)

| Token | Example |
|-------|---------|
| `%book_time_left` | *3h 45m* |
| `%book_read_time` | *2h 30m* |
| `%book_pages_read` | *142* |
| `%days_reading_book` | *7* |
| `%pages_per_day` | *12* |
| `%speed` | *42* (pages per hour) |

Statistics tokens auto-hide when the plugin is absent or the book has no recorded reading time.

#### Time and date

| Token | Example |
|-------|---------|
| `%time` / `%time_24h` | *14:35* |
| `%time_12h` | *2:35 pm* |
| `%date` / `%date_long` / `%date_numeric` | *3 May* / *3 May 2026* / *03/05/2026* |
| `%weekday` / `%weekday_short` | *Monday* / *Mon* |
| `%datetime{%H:%M}` | Custom `os.date` format |

#### Device

| Token | Example |
|-------|---------|
| `%batt` / `%batt_icon` | *73%* / charge-aware glyph |
| `%wifi_icon` | Wi-Fi icon (connected / disconnected) |
| `%light` / `%light_pct` / `%light_icon` | *18* / *75%* / lightbulb glyph |
| `%warmth` | Frontlight warmth (natural-light only) |
| `%nightmode` | Moon glyph when night mode is on, sun otherwise |
| `%mem` / `%ram` | System memory (%) / KOReader RSS (MiB) |
| `%disk` | Free space on the books partition (GB) |

#### Conditionals

```
[if:book_time_left]%book_time_left LEFT[else]Open to start reading[/if]
[if:lang!=en]Lang: %lang\n[/if]%description
[if:batt<20]LOW BATTERY %batt[/if]
[if:not series]Standalone[/if]
[if:connected]%wifi_icon[/if]
```

Comparisons: `=` `!=` `<` `>` `<=` `>=`. Boolean: `and`, `or`, `not`. Numeric tokens compare numerically; string tokens compare by string equality. The `connected` condition is true only while actually online, so `[if:connected]%wifi_icon[/if]` shows the Wi-Fi glyph just when connected.

</details>

<details>
<summary><strong>Settings file (advanced)</strong></summary>

Bookshelf stores its settings in a dedicated file alongside KOReader's other plugin data, separate from `settings.reader.lua`:

| Platform | Path |
|----------|------|
| Linux / dev | `~/.config/koreader/settings/bookshelf.lua` |
| Kindle | `/mnt/us/koreader/settings/bookshelf.lua` |
| Kobo | `/mnt/onboard/.adds/koreader/settings/bookshelf.lua` |
| Android | `<koreader-dir>/settings/bookshelf.lua` |

Existing v1 settings migrate automatically on first launch -- legacy keys are read from `settings.reader.lua`, copied across with the `bookshelf_` prefix stripped, and removed from the global file.

#### Selected keys

| Key | Shape |
|-----|-------|
| `tabs` | Ordered list of chip records (id, label, icon, source, filter, sort_priority, enabled). |
| `hero_regions` | Per-section overrides (sparse). One entry per section (status / rating / title / author / metadata / description / tags / progress) with any subset of template, font_face, font_size, bold, uppercase, alignment, disabled, bar_style, bar_height. The interactive **tags** section also takes per-category toggles (show_author / show_series / show_collections / show_genres / show_folder) plus font_size and alignment. |
| `font_scale` | Global zoom for hero text (50-200%). |
| `chip_font_scale` | Chip bar font size (50-300%). |
| `chip_flex_widths` | Boolean. When true, longer-labelled chips get more horizontal space than icon-only ones. |
| `active_chip` / `active_page` / `drill_path` | Persisted navigation state, restored on KOReader restart. |
| `progress_bar_enabled` / `progress_bookmark_enabled` / `progress_badge_enabled` / `progress_page_count_enabled` | Cover indicator toggles. |
| `show_series_num` | "always" / "in_series" / "never". |
| `progress_fill` / `progress_track` / `bookmark_color` / `complete_bookmark_color` / `favorite_star_color` / `badge_fg` / `badge_bg` / `border_color` / `folder_overlay_bg` / `folder_overlay_fg` | Cover-chrome colours (% black). Each also has a `_night` variant for the night-mode palette; unset keys fall back to per-mode defaults. |
| `author_format` | `"auto"` / `"first_last"` / `"last_first"` -- author name display. |
| `bookshelf_ui_font` | Chosen Bookshelf interface font (a resolvable font face). Absent = follow KOReader's UI font. |
| `cover_cache_mb` | Memory budget (MB) for the scaled-cover cache (default 24). The legacy `cover_cache_size` count key is discarded on first load. |
| `hardcover_links` / `hardcover_enrichment` / `hardcover_ratings` / `hardcover_reviews` | Optional Hardcover link and cached description/cover/rating/review metadata used by the Hardcover enrichment menu. |
| `hardcover_hero_rating` | Show cached Hardcover ratings in the hero rating row instead of KOReader's local rating. |
| `hardcover_use_metadata` | Use Hardcover's title/author/series/genres for linked books in place of their own. |
| `hardcover_max_genres` | How many of a linked book's Hardcover genres to use (when `hardcover_use_metadata` is on). |
| `calibre_metadata` | BETA. Read metadata from `metadata.calibre` if present. |
| `latest_walk_depth` | How deep the **Latest** source scans your library. |
| `show_close_msg` | Show the centred "Closing book…" toast when exiting a book. |
| `dev_branch` / `last_install_source` / `check_updates` | Updater state. |
| `start_menu_items` | The start menu tree: an ordered list of entries (actions, plugin launchers, folders with children, and micro-modules). |
| `start_menu_position` | `"left"` / `"right"` / `"off"` -- where the start-menu button sits in the footer. |
| `start_menu_seeded` / `start_menu_next_id` | One-shot seed flag for the default menu, and the counter behind generated entry ids. |
| `micromodule_<key>_*` | Per-micro-module settings (e.g. `micromodule_clock_format`, `micromodule_random_unread_source`). Each module owns its own keys. |
| `migrated` | One-shot flag; presence indicates v1 -> v2 migration has run. |

</details>

<details>
<summary><strong>Known limitations</strong></summary>

- **`%bar` styling lives in the Progress section.** Inserting `%bar` in another section still renders the widget, but uses the bordered default style and 100% height since the Bar style / Bar height buttons only appear in the Progress section's editor.
- **Italic** is reachable only via the font picker (by selecting an italic family). The line editor has no italic toggle because `TextBoxWidget` doesn't synthesise italic from upright fonts.
- **Inline format tags** `[b]`, `[i]`, `[u]` in templates are stripped before display. Use the per-section Bold button instead.
- **Page count for EPUBs** requires opening the book at least once. The count comes from KOReader's pagemap or reading statistics, both of which are populated only after the first paginate.

</details>

---

## License

AGPL-3.0 -- see [LICENSE](LICENSE)

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/O5O5FDLVJ)
