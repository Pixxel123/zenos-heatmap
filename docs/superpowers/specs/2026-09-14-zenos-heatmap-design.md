# zenos-heatmap: design

Written 14 September 2026, after the ZenOS maintainer asked for the reading
heatmap to ship as an add-on rather than a change to ZenOS itself.

## What it is

`zenheatmap.koplugin` is a KOReader plugin that adds one Home page widget to
ZenOS, **Reading heatmap**: a GitHub-style calendar of minutes read, taken from
KOReader's statistics database, with the reader's typical week drawn beside it.
It registers through ZenOS's documented hook (`__ZENOS_REGISTER_HOME_ITEM`,
with the `__ZEN_UI_` alias for older ZenOS) and changes nothing in ZenOS. The
numbers (pages today, time today, streak) stay in ZenOS's own Reading stats
widget; users stack the two.

## Visual design (direction D2)

Decided from a design critique and a side-by-side mock on 14 September:

- **One vocabulary.** Everything is a flat square cell in four shades: outlined
  light grey for none (`COLOR_LIGHT_GRAY`), `COLOR_GRAY` light, `COLOR_GRAY_5`
  normal, black heavy. No circles, arcs, dots or anti-aliased strokes; nothing
  thinner than 1 px, no dashes shorter than S(1).
- **Ranges.** Year to date (week columns, 53 wide), 3 months (week columns,
  cells may widen up to 2:1), Month (a calendar, weeks down). No "week only".
- **Weekday letters** label the graph's rows (year, 3 months) at the left in
  the month labels' face, and head the calendar's columns (Month) in the
  caption face. They are always shown.
- **Typical week**: each weekday's mean minutes over the last 12 weeks, as a
  share of the best weekday (0 to 1). Beside the row graphs it is an outlined
  track three cells wide (capped at S(36)) filled from the left in
  `COLOR_GRAY_5`, one per row, with a 1 px `COLOR_GRAY` hairline between the
  block and the graph. Under the Month header it is the same track standing
  upright (cell wide, 1.5 cells tall) filled from the bottom. Outline means
  "the rest, up to your best weekday", fill means "usual": the grid's own
  outline-versus-fill rule. One switch turns it off; the letters stay.
- **Today** always has exactly one marker in the graph: a dotted S(1) border
  over an inset shade when the cell is at least S(12), otherwise a solid
  border half the gap thick around the whole shade.
- **Shading**: relative to the reader's own 28-day mean (below half of it
  light, up to 1.25 times normal, above heavy), or fixed thresholds at 15 and
  60 minutes. Relative falls back to fixed when there is no history.
- **Month labels** under the row graphs, one at each month's first column,
  skipped when they would collide. Toggle.
- **Empty cells are outlined, not filled white**, so a library background
  image shows through.

## Settings

Stored by the plugin in `settings/zenheatmap.lua`, edited from the plugin's
menu (KOReader main menu, "Reading heatmap", under More tools; ZenOS lists it
as a plugin menu for Launcher and Controls buttons):

| Setting | Values | Default |
| --- | --- | --- |
| Range | Year to date, 3 months, Month | Year to date |
| Typical week | on, off | on |
| Month labels under the graph | on, off | on |
| Shading | Relative to my average, Fixed thresholds | Relative |
| Height | Small (2 units), Medium (3), Large (4) | Medium |

Changing a setting saves and re-registers the item, which makes ZenOS rebuild
Home. Enabling and positioning the widget is done in ZenOS under
Zen Settings > Home > Widgets, like any external item. The week starts on the
day the statistics plugin uses (`calendar_start_day_of_week`), Monday by
default.

## Integration contract

- Register on `init` if the hook already exists, and again on the `ZenOSReady`
  event (the plugin loads before ZenOS alphabetically). Unregister on
  `onCloseWidget` so a stale builder never outlives its plugin instance.
- `register(id, build, { label, size })`: `id = "zenheatmap.heatmap"`,
  `size` is a class string from the Height setting.
- The builder receives `{ width, height, is_first_row, module_cfg, ... }`
  and returns a KOReader widget sized to width and height. It must not read
  `ctx.data` (external items get none); the plugin queries the statistics
  database itself. `ctx.setContentBounds` is called when present.
- Data: `page_stat_data` summed per local day for the last 371 days, the
  28-day baseline of days with reading, and the maximum. Pending statistics
  are flushed through the statistics plugin's `insertDB` at most once every
  30 seconds before a query.

## Compatibility

- ZenOS 3.0 or newer (the `__ZENOS_` hook); the `__ZEN_UI_` alias reaches back
  to 2.4.0-beta2. Tested against 3.3.0-alpha16.
- KOReader 2026.07 or newer (tested), any device; the renderer uses only
  Blitbuffer rectangles and TextWidgets.
- Only ZenOS registers the hook; without ZenOS the plugin loads, does nothing
  and shows its menu with a note.

## Non-goals

- No stats row inside the widget, no stat slots, no dividers.
- No per-preset settings, no ZenOS settings integration beyond the hook.
- No translations catalog in version 1 (strings are wrapped in `_()` for
  KOReader's own gettext).
