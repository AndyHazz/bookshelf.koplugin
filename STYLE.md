# Popup style guide

How Bookshelf's own popups look: the book popup, the shelf editor and its
pages, the library pickers (collections, folders, ornaments, themes,
wallpapers, planks, icons, modules), the colour picker and anything new.
Stock KOReader dialogs (ButtonDialog, InputDialog, ConfirmBox, Menu) are left
as KOReader draws them, but a Bookshelf screen should not reach for one when
a page or a picker below does the job.

The shared pieces live in `lib/bookshelf_popup_kit.lua` (`Kit` below), the
page blocks in `lib/bookshelf_editor_page.lua` (`Page`) and the colour-safe
painting in `lib/bookshelf_color.lua` (`Color`). Use them rather than drawing
a control by hand, so a change lands everywhere.

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
  out: Cancel and Save, Apply. Round the end buttons' corners as the
  frame's (`frame.radius`); never clear a stock Button's background, its
  tap feedback inverts it (that crashed the PW5).
- Close alone is not a footer: it is the X at the right of the title (a
  thin row of one button reads as an afterthought). A stock ButtonDialog
  gets the X with `ModuleKit.withClose`; a LibraryModal whose footer is
  Close alone draws it there itself.
- Rows of a stock button table are the same height; the last one is not
  squeezed against the frame (give it the X above instead of a Close row).
- A bar over the screen that is not a dialog's footer (the layout editor's
  Add | pages | Done) is a row of kit buttons at the inset under a
  full-width line, not a borderless button table whose separators end
  nowhere. Its hint is grey text between them, not a greyed button. It runs
  the screen's full width, and with no room under its buttons they sit
  flush on the bottom edge with square bottom corners (`square_bottom`),
  rather than a margin that crops them.
- A panel over content (the layout editor's toolbar) is as wide as its
  controls, not the screen, so it hides as little as it can. Moves are a
  d-pad, not a row of arrows; its keys are grey cards (`card` on the
  editor's buttons), so the pad reads as one thing beside the outlined
  buttons. Its title is a menu's: bold, as tall as the text and the X.
- The ornament menu is a panel of its own: its actions on the bar under
  the title (what acts on this piece at the left: Swap with the
  collection's icon, Hide, Reset; Shuffle this shelf, the one for the
  whole shelf, at the right), then two columns of labelled steppers and switches: the piece
  in its slot (Size, Height, Padding) and the rest (Place, Mirror, Anchor),
  Tap a row of its own under them with a tip beside the button. Size,
  Height and Padding step by − and + (a hold: the big step) and by −10 and
  +10 cards outside them; a tap on a value resets it. No hint line: the
  buttons say it. No d-pad: moving along the deal is not the same as moving
  up and down in the piece's slot (maintainer).
- Keys move by where the buttons are on screen: the nearest that way, so
  a d-pad or two columns are walked as they look, not in list order.
- Every popup takes the keys: the cursor seeded on the first thing a
  reader would reach for (the shelf editor's Source card, not the strip
  above it), hidden until the first key, which shows it there; kept where
  it was across a rebuild (`Kit.keyFocus`). A KOReader ButtonTable inside
  our own FocusManager is quieted (`Kit.quietFocus`): events reach children
  first, and it took every arrow and pressed its own button. A control
  that can't act (greyed) is no stop for the keys, and the cursor is kept
  by its place among all the controls, so a neighbour greying (a slider's
  −5 at its minimum) never moves it onto another (+10).

## Controls

- Anything tappable is a closed rounded shape with the kit's corner
  (`Kit.RADIUS`). Nothing gets an outline unless it is tappable.
- Black means only "on": selected, current, in use. Never decoration.
- Picking one of a few that changes what a screen shows (a source, a
  status, a filter): `Kit.segmented`. The active cell is black with a bold
  white label. A form to fill in and submit (Extract page counts) keeps
  KOReader's checkboxes and radio buttons.
- More options than one line holds: `Kit.segmentedWrap`. Two rows at most,
  split evenly, joined into one control (`Kit.segmentedGrid`: rows stretched
  to one width inside one outline). Past two rows the last cell is More, a
  list; the option picked from it takes the last place shown.
- A screen's own actions (Edit, Refresh, Add, New collection, Select all,
  Reset, Help): `Kit.headerButton`, label then icon, all the same height.
  `Kit.iconButton` for an icon alone. Greyed (`enabled = false`) when they
  can't act now.
- A button that can't act now is grey all over: a light grey border, a grey
  label and icon (`enabled = false` on any kit button). A grey label in a
  black border is too easy to miss, and dark grey reads as black on e-ink.
- A yes/no that only changes what is shown (Include spoilers): a checkbox
  glyph and label on `Kit.tapCell`. Not saved unless it is a real setting.
  A saved on/off is an On | Off segmented control (`Page` segmented); on a
  card of the editor's front page it reads as its value ("Add shelf tile:
  On"), as Filters does, never a tick.
- Which look a button takes goes by what the tap does: a grey card nudges a
  value in place or opens a thing (a setting's row, an option, a theme, a
  colour, −/+ and ±10, a slider's steps, the d-pad's keys); an outline chooses or commits
  (chips, a segmented control's cells, header actions, the footer's way
  out). A dialog that holds both reads as adjusters beside choices.
- A number: a stepper, − value + (`Page` stepper), Auto below the minimum.
  Its − and + are grey cards, the symbols font's minus and plus.
- A size or amount over a range (a font scale, an ornament's size): a
  slider (`Page` slider, `lib/bookshelf_slider.lua`). Tap the track to jump,
  drag the knob (applied when the finger lifts, not on every move; it snaps
  to the fine step), grey cards either side for the fine step (−5 +5, or
  −1 +1) and, outside them, the big one (−10 +10, `big`), the
  range's ends and Default ticked under it. A size nudge is a slim panel low
  on the screen so the preview stays in sight, its footer Cancel | Default |
  Done (Default greyed at the default, maintainer). The font picker's
  footer reads the same. These and the colour picker (Cancel | Default |
  Apply, White where it has one) are the footers that hold more than the
  way out. Its steps are kept in memory and written once as it closes.
- A button with an icon and a label has them at its left, not centred, so
  buttons stacked in a column (one width) line up.
- Hints and notes: `Kit.hintText`, grey. Never a greyed-out button used as
  a label. Give it the room it has (`width`, and `"center"` in a bar):
  with none it takes a fixed box, off centre.
- A Shelf order row's name is outlined as its chip is on the shelf menu bar
  (black for the shelf being edited), though it is not tapped: the one
  outline that is not a button, so the list reads as the bar.
- Icons from the bundled symbols font (Private Use Area glyphs only) mark
  what a card or row is about: Source, Filters, Sort, View mode, each
  filter and grouped source, each style. The same thing has the same icon
  everywhere it appears. The favourites mark follows the reader's
  Favorites icon setting (heart unless they chose the star), never a fixed
  star.
- A "Heading: value" card, and a row whose value doesn't fit beside its
  label, is two lines: the icon beside the grey heading
  (`Kit.iconHeading`, its grey from `Kit.headInk`: light grey on a black
  card, `DIM_ON_GREY` on a grey one), then the value across the card's
  whole width. A
  clear cross beside a card is as tall as the card. The editor's
  Source card shows the source's own icon (`Editor._sourceIcon`), the one
  it has on the Source page.

## Strips

- A screen's controls sit on one grey strip under the title or tabs
  (`Kit.headerRow`): edge to edge, the search box on top (`top`), the switch
  or chips at the left inset, the header buttons at the right end, and a
  1 px shadow line under it (`Kit.withShadow`; grey alone is too faint on
  e-ink). With no chips, the header buttons share the search row while the
  field keeps at least half of it. With neither chips nor a search box, the
  screen's main action (Add theme pack) sits at the left end
  (`at_left`), so the strip isn't half empty. A lone Edit stays at the
  right, where it is on every tab.
- The strip doesn't move or split when content loads. Extra lines (a
  summary, a checkbox) go inside the same strip.

## Cards

- Cards are light grey with a hairline shadow down and right, no outline
  (`Kit.card`, or `Kit.cardify` on a card a picker builds itself). Black
  when selected (`Kit.invertRounded` keeps the corners), a heavy outline
  when it is the one in use and black would hide a picture.
- A card built with `cardify` has no border: size its content without one,
  or the card in use (a thicker border) comes out narrower than the rest.
- A picture on a card is drawn on the card's grey, so transparent parts
  show the card and not a white box.
- The keys' focus ring follows the card's corner. It is a ring, not the
  cell inverted (inverted reads as selected), and it stays hidden until the
  first key: a menu opened by a tap shows no cursor, and the first key shows
  it where it was seeded rather than moving it or pressing the row.
- A ring never runs over an outline drawn round the cell: a segmented
  control's cells set it in (`focus_inset`) with rounded corners. A stock
  KOReader Button inverts itself on focus; in our footers it gets the ring
  instead (`Kit.ringFocus`, `Kit.ringFocusTable`), set in clear of the
  frame's corners and the label.
- Grids of actions: icon over a short label, an even grid (four columns,
  fewer when a label would need three lines). Long-press arranges them.
- A menu of actions on a page (a stack's long-press) is option cards, not
  bare chips: the action's icon, its name, and a grey line saying what it
  does ("Selects its books, to change their status, rating or collections
  together"). Two short ones may pair on a line (`half`). Use the room to
  explain, not to repeat the label.
- Colour chips (the colour picker) are cards too: the colour set in a grey
  card, the picked one's card black.

## Pages (the shelf editor and anything like it)

- A menu inside a menu is a page of it, not a window over it: the same
  frame, a breadcrumb title (Home › View mode › Covers), a back chevron at
  the left and the X at the right that leaves the whole menu. Back on the
  keys goes back a page. Leaving by the X keeps what a page holds (a
  filter's ticks before Apply), as going back does.
- A page is a list of blocks (`Page`): summary, heading, hint, chips,
  segmented, stepper, row, option, slot. Lay a page out by what it holds,
  not as a grid of equal buttons.
- Say what the setting does: a summary sentence in the strip that reads the
  result ("Newest added first, then A-Z by title"), a line under an option
  saying what it shows, a row's value in words. No bare percentages where
  a picture or a word will do.
- Group by meaning under headings, a short heading close to what it heads.
- A page fits any screen, any shape, either way round: past the room it
  pages (‹ 2 of 3 ›), never splitting a heading from what it heads, a
  section's heading repeated where it carries on. Squeezing controls to fit
  one tall portrait screen is not the fix.
- Keep pages short: a style or a group with several settings is a card on
  its page ("Spines › Auto rows, face out: Favorites") that opens a page of
  its own; one with a single setting has it inline instead.
- Show only what applies: a catalogue offers no spines; a setting stored for
  a style the source cannot show is shown as what the shelf actually draws.
- A library picker opened from a page opens as a page too (LibraryModal
  `config.over`), not as a window lined up over the menu, and needs no fade
  behind it. Its back is its lone Close or Back, else its Cancel; a page
  shorter than the menu under it puts the spare height above its footer.
- A screen of its own that would be a stock button grid (the bulk Edit
  selected) is a `PageDialog` (`lib/bookshelf_page_dialog.lua`): the title
  with its X, the same page blocks, a Cancel | Apply footer when changes are
  staged, and `dialog:over(tail)` for the pickers it opens.
- Staged changes show as what they will be: the choice black at once, a
  summary sentence saying what Apply will do, Apply greyed until something
  is staged. A choice that can be left as it is takes `allow_none`: tapping
  the picked cell again un-picks it.
- Two short controls may pair on a line (`half`); a row too narrow for its
  label and value puts the label as a heading over the value, and a pair
  does it together.

## Headings and text

- Section headings: grey (COLOR_DARK_GRAY), bold, upper case, a step
  smaller than body, space above, no line. On a card, `Kit.headInk`'s grey.
- Secondary details (page, date, counts): grey, a step smaller.
- A file path in a header stays on one line: folders go from the front
  first, then the start of the name, keeping its end
  (`TextFit.pathOneLine`). Wrapped, a long path took three lines from the
  tabs under it.
- Grey text on a grey card or strip (a theme's description, an option's
  line under it, a hint in the strip) is `Kit.DIM_ON_GREY` (0x55), not the
  dark grey used on white: 0x88 on the cards' 0xEE is too faint to read.
- Two short sections side by side when both fit on one line (Author(s) and
  Series), stacked otherwise.
- One word for one thing on a page: "Default" for following the library,
  not "Default" in one place and "Default setting" beside it. No internal
  words in hints ("diff", "draft", "staged").
- Counts: "1 like" and "%d likes" as two strings (ngettext is a stub).
  Source strings in American English; British only in en_GB.po.
- Whole strings for the translators: `T(_("Theme: %1"), name)`, not
  `_("Theme: ") .. name`; a list of changes as whole phrases, one a line,
  never a translated word lower-cased into another phrase ("mark %s").
- A summary built of lower-case parts starts with a capital.

## Colour

- A picked colour is painted through `Color.paintRect`,
  `Color.paintRoundedRect`, `Color.paintBorder`, or a frame wrapped with
  `Color.colourBorder`. KOReader's plain calls, and FrameContainer's border,
  keep only a colour's grey on a screen with the C blitter (colour Kobo,
  Kindle Colorsoft), and `fill()` keeps only the grey everywhere.
- Every colour buffer type is a colour buffer: RGB16, RGB24 (PocketBook)
  and RGB32. A test for RGB32 alone made PocketBook cards grey.
- Never compare a colour with nil or `==` it against a maybe-nil value:
  test `type(c) == "nil"` first (a colour's `__eq` indexes the other side).
- A greyscale screen picks a colour from the same picker, its chips greys
  from white to black painted as they look (night mode too). Not a
  "% black" number.
- Auto text (black or white on a picked background) is whichever has the
  more contrast (WCAG), not a half-way switch.
- A picker opens on what is drawn now, an Auto value included, not on a
  default number.

## Editing

- One Edit per screen, not one per section. Editing puts a cross on each
  removable item and "+ Add" after each editable group; the rest goes
  inert grey. Edit reads Done while editing.

## Refresh (e-ink)

- Rebuild in place and refresh only the popup's own box. Opening, closing
  or backing out of a popup shouldn't flash the whole screen unless what is
  underneath really changed. A widget that spans the screen to catch taps
  outside it (the colour picker) passes its frame's box, or a bare
  `setDirty(self)` refreshes the whole screen.
- One paint per tap. A tap that selects (a theme, a colour chip) shows the
  selection at once and nothing else first: no pressed look before it. A
  pressed look (`Kit.pressThen`) is for a tap whose action is slow to show.
  A tap cell for a choice passes `instant` (`Kit.tapCell`'s last argument);
  on editor pages, on/off chips, options and slots are instant, and a chip
  that opens something (Edit collection order >) is not. A tap that changes
  nothing saved (picking a sort level) redraws the page, not the shelf.
- A nudge (a − or +, a slider's step) acts at once with no pressed look:
  its value is the feedback. The shelf behind is rebuilt once the taps
  pause (about a third of a second), not per tap, so rapid taps never
  queue behind whole-screen rebuilds.
- A preview of a change behind a picker (a theme on the shelf) refreshes as
  ui while the picker is up; the one full refresh that clears e-ink ghosts
  comes when it closes, and only if something changed.
- No fade or scrim behind a popup: it costs a whole-screen refresh. A popup
  over a menu should be a page of it instead.
