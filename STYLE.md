# Popup style guide

How Bookshelf's own popups look: the book popup, the library pickers
(collections, folders, ornaments, themes, wallpapers, planks, icons,
modules) and anything new. Stock KOReader dialogs (ButtonDialog, InputDialog,
ConfirmBox, Menu) are left as KOReader draws them.

The shared pieces live in `lib/bookshelf_popup_kit.lua` (`Kit` below). Use
them rather than drawing a control by hand, so a change lands everywhere.

## Lines and edges

- Lines belong to the frame: its border, the rule under a title or tab row,
  the line above the footer. No rules inside the content, between sections
  or between list items. Space separates them.
- Every control is a closed shape. Nothing leans on the frame or a
  neighbour to finish its outline: stock ButtonTable separators assume they
  run into the frame's border, and set in from it they end nowhere.
- Content shares one left edge, the popup's inset.
- A footer runs edge to edge under a full-width line, its separators the
  full height of its buttons, and closes the frame. It holds only the way
  out: Close, Cancel and Save, Apply.

## Controls

- Anything tappable is a closed rounded shape with the kit's corner
  (`Kit.RADIUS`). Nothing gets an outline unless it is tappable.
- Black means only "on": selected, current, in use. Never decoration.
- Picking one of a few (a source, a status, a filter): `Kit.segmented`.
  The active cell is black with a bold white label.
- More options than one line holds: `Kit.segmentedWrap`. Two rows at most,
  split evenly, joined into one control (`Kit.segmentedGrid`: rows stretched
  to one width inside one outline). Past two rows the last cell is More, a
  list; the option picked from it takes the last place shown.
- A screen's own actions (Edit, Refresh, Add, New collection, Select all,
  Reset, Help): `Kit.headerButton`, label then icon, all the same height.
  `Kit.iconButton` for an icon alone. Greyed (`enabled = false`) when they
  can't act now.
- A yes/no that only changes what is shown (Include spoilers): a checkbox
  glyph and label on `Kit.tapCell`. Not saved unless it is a real setting.
- Hints and notes: `Kit.hintText`, grey. Never a greyed-out button used as
  a label.

## Strips

- A screen's controls sit on one grey strip under the title or tabs
  (`Kit.headerRow`): edge to edge, the search box on top (`top`), the switch
  or chips at the left inset, the header buttons at the right end, and a
  1 px shadow line under it (`Kit.withShadow`; grey alone is too faint on
  e-ink). With no chips, the header buttons share the search row while the
  field keeps at least half of it.
- The strip doesn't move or split when content loads. Extra lines (a
  summary, a checkbox) go inside the same strip.

## Cards

- Cards are light grey with a hairline shadow down and right, no outline
  (`Kit.card`, or `Kit.cardify` on a card a picker builds itself). Black
  when selected (`Kit.invertRounded` keeps the corners), a heavy outline
  when it is the one in use and black would hide a picture.
- A picture on a card is drawn on the card's grey, so transparent parts
  show the card and not a white box.
- The keys' focus ring follows the card's corner.
- Grids of actions: icon over a short label, an even grid (four columns,
  fewer when a label would need three lines). Long-press arranges them.

## Headings and text

- Section headings: grey (COLOR_DARK_GRAY), bold, upper case, a step
  smaller than body, space above, no line.
- Secondary details (page, date, counts): grey, a step smaller.
- Two short sections side by side when both fit on one line (Author(s) and
  Series), stacked otherwise.
- Counts: "1 like" and "%d likes" as two strings (ngettext is a stub).
  Source strings in American English; British only in en_GB.po.

## Editing

- One Edit per screen, not one per section. Editing puts a cross on each
  removable item and "+ Add" after each editable group; the rest goes
  inert grey. Edit reads Done while editing.

## Refresh (e-ink)

- Rebuild in place and refresh only the popup's own box. Opening, closing
  or backing out of a popup shouldn't flash the whole screen unless what is
  underneath really changed.
