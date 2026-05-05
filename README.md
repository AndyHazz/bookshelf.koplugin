# Bookshelf

A nice-looking home screen for KOReader. Lets you pick a book from your shelf
and read it, with some customisation around the book-preview info shown for
the currently-reading book. Books are grouped into four shelves: Recent,
Latest, Series, and Favourites.

<!-- screenshot: TODO -->

---

## Quick start

1. Download the latest release ZIP from [GitHub Releases](https://github.com/AndyHazz/bookshelf.koplugin/releases) and extract `bookshelf.koplugin/` to your KOReader plugins directory ([paths below](#installation)).
2. Restart KOReader — Bookshelf opens automatically as the home screen.
3. Tap **Recent**, **Latest**, **Series**, or **★** to browse your library by shelf.
4. Open the FileManager menu (top of screen) → **Bookshelf** for settings, including the per-region hero card editor.

---

## Home screen layout

```
┌──────────────────────────────────────┐
│ [cover]   14:32  ⚡73%  💡  📶      │  ← Status line (right-aligned, hairline)
│           ─────────────────          │
│           Title of the Book          │  ← Title region
│           Author Name                │  ← Author region
│                                      │
│           Description of the book…   │  ← Description (fills the slack)
│                                      │
│           36% ━━━━━━━━━┯━━━ 3h 12m   │  ← Progress region (text + %bar inline)
├──────────────────────────────────────┤
│  Recent   Latest   Series   ★        │  ← Chip strip
├──────────────────────────────────────┤
│ Recently read  ·  1–8 of 12  ›       │  ← Shelf label
│ [spine] [spine] [spine] [spine]      │  ← Shelf row 1
│ [spine] [spine] [spine] [spine]      │  ← Shelf row 2
└──────────────────────────────────────┘
```

Tap any spine to open that book. Long-press a spine for options (favourite, info, remove from history). Tap the shelf label to open the full paginated library view for the active chip. On the **Series** chip, tap a series stack to expand it; tap the back label to collapse.

---

## Hero card editor

Five regions of the hero card are user-editable token templates with per-region styling. Open **FileManager menu → Bookshelf → Edit hero card** for a drill-down submenu showing all five regions with a live preview snippet:

```
☑ Status: 14:32  ⚡73%  💡 18%  📶
☑ Title: The Great Gatsby
☑ Author: F. Scott Fitzgerald
☑ Description: In my younger and more vulnerable years…
☑ Progress: 36%  ━━━━━━━━━┯━━━  3h 12m LEFT
```

- **Tap a row** — opens the line editor for that region. The chooser hides while editing so you can see the live hero update as you type.
- **Long-press a row** — toggles the region on/off (the checkbox flips and the region appears/disappears in the hero immediately).

### Line editor

The editor offers per-region controls:

| Button | What it does |
|--------|--------------|
| **Bold** | Toggle bold weight |
| **Size** | ±1 / ±5 nudge dialog (range 8–48 px) |
| **Font** | Font family picker (richer UI when [Bookends](https://github.com/AndyHazz/bookends.koplugin) is installed) |
| **Aa / AA** | Case toggle (hidden on Description) |
| **L / C / R** | Alignment cycle (left / centre / right) |
| **Bar style** | Cycle through 7 bar styles (Progress region only, requires Bookends) |
| **+ Bar / − Bar** | Insert or remove the `%bar` token in the Progress template |
| **Bar height** | ±1 / ±5 nudge for the inline bar's pixel height |
| **Tokens…** | Pick from a categorised token catalogue with live preview |
| **Icons…** | Insert icon glyphs (requires Bookends) |
| **Default** | Reset this region's template + styling to defaults |
| **Cancel** | Revert and close (snapshot taken on open is restored) |
| **Save** | Persist and close |

Edits update the hero in real time. The renderer rebuilds **only the right column** of the card on each keystroke — the cover stays untouched, no BIM thumbnail re-fetch.

### Bookends soft-dependencies

Several editor surfaces use the [Bookends](https://github.com/AndyHazz/bookends.koplugin) plugin when it's installed; everything degrades gracefully when it isn't:

| Surface | With Bookends | Without |
|---------|---------------|---------|
| Token picker | Categorised modal with chips, search, live preview | Plain Menu over the catalogue |
| Icon picker | Full Material-Design icon library | Button hidden |
| Font picker | Each font family rendered in its own typeface, weight-variant dedup | Plain Menu over the system font list |
| Progress-bar styles | 7 styles (`bordered`, `solid`, `rounded`, `metro`, `wavy`, `radial`, `radial_hollow`) | 2 styles (`bordered`, `solid`) |

---

## Token cheatsheet

Tokens are placeholders prefixed with `%`. Conditional logic uses `[if:cond]…[else]…[/if]`.

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

---

## Configuration

Settings are stored in KOReader's main settings file alongside all other plugin state:

| Platform | Path |
|----------|------|
| Linux / dev | `~/.config/koreader/settings.reader.lua` |
| Kindle | `/mnt/us/koreader/settings.reader.lua` |
| Kobo | `/mnt/onboard/.adds/koreader/settings.reader.lua` |
| Android | `<koreader-dir>/settings.reader.lua` |

Bookshelf-specific keys are prefixed `bookshelf_`:

| Key | Shape |
|-----|-------|
| `bookshelf_hero_regions` | Per-region overrides (sparse). One entry per region (`status` / `title` / `author` / `description` / `progress`) with a subset of `template`, `font_face`, `font_size`, `bold`, `uppercase`, `alignment`, `disabled`, `bar_style`, `bar_height` — anything not present falls through to defaults. |
| `bookshelf_font_scale` | Global zoom for hero text (50–200%). |
| `bookshelf_active_chip` | Last-selected chip (`recent` / `latest` / `series` / `favorites`). |
| `bookshelf_latest_walk_depth` | How deep the **Latest** chip scans your library. |
| `bookshelf_legacy_keys_retired` | One-shot guard for the v0.1 → v0.2 cleanup. |

The pre-v0.2 keys `bookshelf_clock_line` and `bookshelf_hero_lines` are deleted automatically on first launch with v0.2.

---

## Known limitations

- **`%bar` outside the Progress region** renders as the literal text `%bar`. The inline-bar split only runs in the progress block of the renderer; in other regions there's no bar widget to layer in.
- **Italic** is reachable only via the font picker (selecting an italic family). The line editor has no italic toggle because `TextBoxWidget` doesn't synthesise italic from upright fonts.
- **Inline format tags** `[b]`, `[i]`, `[u]` in templates are stripped before display. Per-region bold is via the Bold button, not the `[b]` tag.
- **"Latest" walk performance** — the Latest chip walks the filesystem at every label refresh. On large libraries the first paint can pause briefly. Caching is on the roadmap.
- **No in-app updater** — install new releases manually from GitHub Releases.

---

## Design docs

- [v0.1 — Bookshelf design](docs/superpowers/specs/2026-05-03-bookshelf-design.md) — original layout, widget hierarchy, token vocabulary.
- [v0.2 — Editable hero regions](docs/superpowers/specs/2026-05-04-editable-hero-regions-design.md) — five-region model, line editor architecture, bar backend, soft-dep matrix.
- [v0.2 — Implementation plan](docs/superpowers/plans/2026-05-04-editable-hero-regions-plan.md) — task-by-task build sequence.

---

## License

AGPL-3.0 — see [LICENSE](LICENSE)
