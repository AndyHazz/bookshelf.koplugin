<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bookshelf-logo-dark.png">
    <img alt="Bookshelf" src="assets/bookshelf-logo.png" width="320">
  </picture>
</p>

# Bookshelf

A nice-looking home screen for KOReader. Pick a book from your shelf and read
it, with a fully customisable chip bar across the top, an editable book
detail view, and per-chip sources, filters, and sort priorities.

<p align="center">
  <img src="https://github.com/user-attachments/assets/82f95a3e-7914-4236-855f-31d8dd09d83c" width="19%" alt="Bookshelf home screen" />
  <img src="https://github.com/user-attachments/assets/574976b3-c82d-4eeb-a8ac-848ea113aa35" width="19%" alt="Series view" />
  <img src="https://github.com/user-attachments/assets/abcdf0b2-a06b-46d4-9055-e710f2a124b5" width="19%" alt="Chip bar editor" />
  <img src="https://github.com/user-attachments/assets/b916c194-7423-4418-96c3-d0367119f45c" width="19%" alt="Hero card line editor" />
  <img src="https://github.com/user-attachments/assets/95799321-18fe-4495-84f4-73388a1ecc35" width="19%" alt="Library search" />
</p>

---

## Quick start

1. Download the latest release ZIP from [GitHub Releases](https://github.com/AndyHazz/bookshelf.koplugin/releases) and extract `bookshelf.koplugin/` to your KOReader plugins directory ([paths below](#installation)). **Bookshelf requires the CoverBrowser plugin to be enabled** (it provides the BookInfoManager that supplies covers and metadata).
2. Restart KOReader. Bookshelf opens automatically as the home screen.
3. The default chip bar has **Home**, **Recent**, **Series**, and **Favourites**. Tap any chip to switch shelves; long-press to edit it. The top menu's **Bookshelf chips...** entry lets you add, hide, reorder, or delete chips.
4. Open the menu (top of screen) for the rest: **Edit hero card**, **Cover progress indicators**, font scaling, and advanced settings.

Tap any cover to open the book. Long-press a cover for per-book options.

---

## Chip bar

The bar across the top is fully customisable. Each chip has its own:

- **Source** -- Home (folders or flat), Recently read, Latest added, Series, Authors, Genres, Tags, Formats, Ratings, Favourites, or a specific genre / author / series / tag / format / rating / folder / collection.
- **Reading status filter** -- any combination of Unread / Reading / On hold / Finished.
- **Sort priority** -- up to three levels (e.g. surname, then series name, then series index). New v2 sort keys include Page count, Rating, Most recently read (strict), and Most recently added.
- **Label and icon** -- rename the chip, give it an icon, or both. Text and icons mix in the same label.
- **Enabled flag** -- hide a chip without losing its config.

Open the editor by long-pressing any chip, or via **Bookshelf chips...** in the menu. The "+ Add new chip" footer creates a custom chip you can point at any source.

### Search

Tap the search icon at the right of the chip bar. Results show all matching folders, authors, series, genres, tags, and books regardless of which chips you have enabled. Tapping a stack from the results keeps you in search mode, with the stack name added to the breadcrumb.

### Library refresh

- **Swipe down** on the shelf area to refresh manually after adding books via USB or Calibre. A "Refreshing library" notice appears while it works.
- **Auto-detection** picks up new files on the next chip tap based on actual filesystem changes -- no fixed-interval cache.

---

## Gestures

| Gesture | Where | What it does |
|---------|-------|--------------|
| **Tap** | Shelf cover (normal mode) | Preview the book in the hero card |
| **Tap** | Shelf cover (expanded mode) | Open the book directly |
| **Tap** | Hero card cover | Open the previewed book |
| **Tap** | Hero card description | Open the full description in a scrollable viewer |
| **Tap** | Hero card star | Set / clear the book's rating |
| **Tap** | Chip | Switch shelf |
| **Tap** | Search icon | Open the library search |
| **Tap** | "Page N of M" footer | Open the numeric page-jump dialog |
| **Tap** | First / prev / next / last chevrons | Page navigation |
| **Long-press** | Chip | Open the chip editor |
| **Long-press** | Shelf cover | Open the per-book menu (Show info, Add to favourites, Go to author / series / genre, Remove from history) |
| **Long-press** | Prev / next chevron | Skip 10 pages back / forward (clamped to first / last) |
| **Long-press** | Hero card | Open the per-book menu for the previewed book |
| **Swipe west (<-)** | Hero card | Cycle preview to the next book in the active chip |
| **Swipe west (<-)** | Anywhere else | Next page; on the last page, drills out or switches chip |
| **Swipe east (->)** | Hero card | Cycle preview to the previous book |
| **Swipe east (->)** | Anywhere else | Previous page / drill back out / previous chip |
| **Swipe north (up)** | Anywhere | Collapse hero to a thin status strip, expand the grid (more books on screen) |
| **Swipe south (down)** | Hero | Restore the full hero from expanded mode |
| **Swipe south (down)** | Shelf area | Refresh the library walk |

The pagination row uses wide tap zones across the middle 75% of the screen. The outer 12.5% on each side is left free so KOReader's bottom-corner gestures (gestures.koplugin profiles for brightness, night mode, etc.) still register.

---

## Hero card

The book detail card at the top of the screen has six editable regions:

- **Status line** -- top right, defaults to disk / battery / frontlight / Wi-Fi / time.
- **Rating** -- five tappable stars. Off by default; enable via the editor.
- **Title** -- big, bold by default.
- **Author**
- **Metadata** -- a free-form line; default template shows "Series / #N" when the book is in a series.
- **Description** -- the book blurb. Tap to open in a scrollable full-text viewer.
- **Progress** -- bottom-anchored, includes the inline progress bar.

Open **menu -> Edit hero card** to toggle regions on/off (tap a row) or open the line editor (tap a row when rating is selected just toggles it).

### Line editor

| Button | What it does |
|--------|--------------|
| **Bold** | Toggle bold weight |
| **Size** | +/- 1 / +/- 5 nudge dialog (range 8-48 px) |
| **Font** | Font family picker (richer UI when [Bookends](https://github.com/AndyHazz/bookends.koplugin) is installed) |
| **Aa / AA** | Case toggle (hidden on Description) |
| **L / C / R** | Alignment cycle (left / centre / right) |
| **Bar style** | Cycle through 7 bar styles (Progress region only, requires Bookends) |
| **+ Bar / - Bar** | Insert or remove the `%bar` token in the Progress template |
| **Bar height** | +/- 1 / +/- 5 nudge for the inline bar's pixel height |
| **Tokens...** | Pick from a categorised token catalogue with live preview |
| **Icons...** | Insert icon glyphs (requires Bookends) |
| **Default** | Reset this region's template + styling to defaults |
| **Cancel** | Revert and close |
| **Save** | Persist and close |

Edits update the hero in real time. The renderer rebuilds only the right column on each keystroke -- the cover stays untouched.

### Bookends soft-dependencies

Several editor surfaces use the [Bookends](https://github.com/AndyHazz/bookends.koplugin) plugin when it's installed; everything degrades gracefully when it isn't:

| Surface | With Bookends | Without |
|---------|---------------|---------|
| Token picker | Categorised modal with chips, search, live preview | Plain Menu over the catalogue |
| Icon picker | Full Material-Design icon library | Plain text-only label |
| Font picker | Each font family rendered in its own typeface, weight-variant dedup | Plain Menu over the system font list |
| Progress-bar styles | 7 styles (`bordered`, `solid`, `rounded`, `metro`, `wavy`, `radial`, `radial_hollow`) | 2 styles (`bordered`, `solid`) |

---

## Cover indicators

Settings -> Cover progress indicators:

- **Show reading bookmarks** -- bookmark glyph at the bottom-left of in-progress books.
- **Show completed book badge** -- check-bookmark glyph for finished books.
- **Show progress bars** -- thin pill above the bottom edge of in-progress books.
- **Show page count** -- "pN" pill at the bottom-right corner. Works for EPUBs once you've opened them at least once.
- **Show series #** -- tri-state: Always / Within series folder / Never. "Within series folder" suppresses the "#N" badge on mixed-source views where it just reads as noise.
- Colour rows for the bar fill and track.

---

## Token cheatsheet

Tokens are placeholders prefixed with `%`. Conditional logic uses `[if:cond]...[else]...[/if]`.

### Book metadata

| Token | Example |
|-------|---------|
| `%title` | *The Great Gatsby* |
| `%author` | *F. Scott Fitzgerald* (first author) |
| `%authors` | *Neil Gaiman, Terry Pratchett* (all authors) |
| `%series` / `%series_name` | *Dune* |
| `%series_num` | *1* |
| `%filename` | *The_Great_Gatsby* |
| `%format` | *EPUB* |
| `%lang` | *en* |
| `%description` | Book blurb (HTML stripped, entities decoded) |
| `%rating` | *4* (1-5 stars, or absent if unrated) |

### Position / progress

| Token | Example |
|-------|---------|
| `%page_num` / `%page_count` | *42* / *218* |
| `%pages_left` | *176* |
| `%book_pct` / `%book_pct_left` | *19%* / *81%* |
| `%bar` | Inline progress-bar widget (Progress region only) |

### Statistics (requires the `statistics` plugin)

| Token | Example |
|-------|---------|
| `%book_time_left` | *3h 45m* |
| `%book_read_time` | *2h 30m* |
| `%days_reading_book` | *7* |
| `%pages_per_day` | *12* |
| `%speed` | *42* (pages per hour) |

Stat tokens auto-hide when the statistics plugin is absent or the book has no recorded reading time.

### Time / date

| Token | Example |
|-------|---------|
| `%time` / `%time_24h` | *14:35* |
| `%time_12h` | *2:35 pm* |
| `%date` / `%date_long` / `%date_numeric` | *3 May* / *3 May 2026* / *03/05/2026* |
| `%weekday` / `%weekday_short` | *Monday* / *Mon* |
| `%datetime{%H:%M}` | Custom `os.date` format |

### Device

| Token | Example |
|-------|---------|
| `%batt` / `%batt_icon` | *73%* / charge-aware glyph |
| `%wifi_icon` | Wi-Fi icon (connected / disconnected) |
| `%light` / `%light_icon` | *18* / lightbulb glyph |
| `%warmth` | Frontlight warmth (natural-light only) |
| `%nightmode` | Moon glyph when night mode is on, sun otherwise |
| `%mem` / `%ram` | System memory (%) / KOReader RSS (MiB) |

### Conditionals

```
[if:book_time_left]%book_time_left LEFT[else]Open to start reading[/if]
[if:lang!=en]Lang: %lang\n[/if]%description
[if:batt<20]LOW BATTERY %batt[/if]
[if:not series]Standalone[/if]
```

Operators: `=` `!=` `<` `>` `<=` `>=`. Boolean: `and`, `or`, `not`. Numeric tokens compare numerically; string tokens compare by string equality.

---

## Installation

**Manual install:** Download the latest release ZIP from [GitHub Releases](https://github.com/AndyHazz/bookshelf.koplugin/releases) and extract to your KOReader plugins directory:

| Device | Path |
|--------|------|
| Kindle | `/mnt/us/koreader/plugins/bookshelf.koplugin/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/bookshelf.koplugin/` |
| Android | `<koreader-dir>/plugins/bookshelf.koplugin/` |

Restart KOReader after installing.

Bookshelf requires KOReader's bundled **CoverBrowser** plugin to be enabled (Settings > More plugins > CoverBrowser). It supplies the BookInfoManager that Bookshelf uses for covers and metadata. With CoverBrowser disabled, Bookshelf shows a one-time notification and falls back to the standard FileManager.

---

## Updates

Bookshelf can update itself in place over Wi-Fi. Settings live under **menu -> Updates**:

- **Notify on wake when update available** -- opt-in; once an hour after a Wi-Fi-connected wake, Bookshelf checks the GitHub releases API and posts a brief notification if a newer release exists. Off by default.
- **Installed version / Update available** -- tap the row to fetch release notes and choose **Update and restart**. Requires a published ZIP asset on the GitHub release.
- **Advanced -> Development branch** -- set a branch name (e.g. `feat/foo`); the row labels flip to **Install branch: foo**. Tapping installs the tip of that branch, useful for testing fixes.
- **Advanced -> Reset to latest stable release** -- clears the dev-branch setting and pulls the latest published release ZIP, then restarts KOReader.

The whole pipeline (download -> unpack -> restart prompt) requires only Wi-Fi.

---

## Configuration

Bookshelf settings live in a dedicated file alongside KOReader's other plugin data, separate from `settings.reader.lua`:

| Platform | Path |
|----------|------|
| Linux / dev | `~/.config/koreader/settings/bookshelf.lua` |
| Kindle | `/mnt/us/koreader/settings/bookshelf.lua` |
| Kobo | `/mnt/onboard/.adds/koreader/settings/bookshelf.lua` |
| Android | `<koreader-dir>/settings/bookshelf.lua` |

Existing v1 settings migrate automatically on first launch -- legacy keys are read from `settings.reader.lua`, copied across with the `bookshelf_` prefix stripped, and removed from the global file.

Selected keys:

| Key | Shape |
|-----|-------|
| `tabs` | Ordered list of chip records (id, label, icon, source, filter, sort_priority, enabled). |
| `hero_regions` | Per-region overrides (sparse). One entry per region (status / rating / title / author / metadata / description / progress) with any subset of template, font_face, font_size, bold, uppercase, alignment, disabled, bar_style, bar_height. |
| `font_scale` | Global zoom for hero text (50-200%). |
| `chip_font_scale` | Chip bar font size (50-300%). |
| `chip_flex_widths` | Boolean. When true, longer-labelled chips get more horizontal space than icon-only ones. |
| `active_chip` / `active_page` / `drill_path` | Persisted navigation state, restored on KOReader restart. |
| `progress_bar_enabled` / `progress_bookmark_enabled` / `progress_badge_enabled` / `progress_page_count_enabled` | Cover indicator toggles. |
| `show_series_num` | "always" / "in_series" / "never". |
| `progress_fill` / `progress_track` | Cover-bar colours. |
| `calibre_metadata` | BETA. Read metadata from `metadata.calibre` if present. |
| `latest_walk_depth` | How deep the **Latest** source scans your library. |
| `dev_branch` / `last_install_source` / `check_updates` | Updater state. |
| `migrated` | One-shot flag; presence indicates v1 -> v2 migration has run. |

---

## Known limitations

- **`%bar` outside the Progress region** renders as literal text. The inline-bar split only runs in the progress block of the renderer.
- **Italic** is reachable only via the font picker (selecting an italic family). The line editor has no italic toggle because `TextBoxWidget` doesn't synthesise italic from upright fonts.
- **Inline format tags** `[b]`, `[i]`, `[u]` in templates are stripped before display. Per-region bold is via the Bold button.
- **Page count for EPUBs** requires opening the book at least once. The count comes from KOReader's pagemap or stats, both of which are populated only after the first paginate.

---

## License

AGPL-3.0 -- see [LICENSE](LICENSE)
