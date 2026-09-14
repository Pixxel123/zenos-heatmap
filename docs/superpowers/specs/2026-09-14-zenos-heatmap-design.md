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
  track three cells wide (capped at S(36)) filled from the left, one per row,
  in the shade the weekday's average earns in the grid (light, normal, heavy), with a 1 px `COLOR_GRAY` hairline between the
  block and the graph. Under the Month header it is the same track standing
  upright (cell wide, 1.5 cells tall) filled from the bottom. Outline means
  "the rest, up to your best weekday", fill means "usual": the grid's own
  outline-versus-fill rule. One switch turns it off; the letters stay.
- **Today** always has exactly one marker in the graph: a thick black
  border in the gap around the whole cell, half the gap thick with a little
  clearance, at every cell size (chosen over dots, which turned to noise in
  small cells). With the gaps closed it sits on the cell's edge.
- **Shading**: relative to the reader's own 28-day mean (below half of it
  light, up to 1.25 times normal, above heavy), or fixed thresholds at 15 and
  60 minutes. Relative falls back to fixed when there is no history.
- **Month labels** under the row graphs, one at each month's first column,
  skipped when they would collide. Toggle. When on they always stay: in a
  short year row their face follows the row pitch like the weekday letters,
  and only when even S(4) cells with the smallest face overflow do they go.
- **Empty cells are outlined, not filled white**, so a library background
  image shows through.

## Settings

Stored by the plugin in `settings/zenheatmap.lua`, edited from the plugin's
menu (KOReader main menu, "Reading heatmap", under More tools; ZenOS lists it
as a plugin menu for Launcher and Controls buttons):

| Setting | Values | Default |
| --- | --- | --- |
| Show on Home | on, off | off |
| Range | Year to date, 3 months, Month | Year to date |
| Typical week | on, off | on |
| Month labels under the graph | on, off | on |
| Shading | Relative to my average, Fixed thresholds | Relative |
| ZenOS stats above the year graph | on, off | on |
| Stats beside the graph | left and right slot: Pages today, Time today, Day streak, Pages this week, Time this week, Days read, None (3 months and Month) | Time today, Day streak |
| Height | Automatic, Extra small (1 unit), Small (2), Medium (3), Large (4) | Automatic (2; 1 for the year without its stats) |

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

## Stats beside the graph (added later on 14 September)

Two stat slots sit beside the graph in every range, as ZenOS's own quarter
layout once had: the graph in the left cell, one
stat centred between it and a second stat flush right, dividing lines midway
with the same clearance rule as ZenOS's stats row, the type stepping down from
18 to 8 until the row fits. The numbers come from ZenOS's `common/db_stats`
`queryHomeStats` (guarded; without it the graph stands alone), so they equal
the Reading stats widget's. The row letters take a face sized from the row
pitch (a capital is about three quarters of the font's pixel size), capped at
the month labels' size, so all seven always show.

The year graph is width-bound, so its stats do not sit beside it. Instead
the three fields ZenOS shows in its Reading stats widget (read from the Home
layout's `middle_stats_triplet`, defaults pages today, time today, day
streak) form a row above the graph: equal cells, value over caption, centred,
dividers between, the type stepping down to 8 until the graph under it is
complete. The starting size is ZenOS's own Reading stats setting
(`modules.stats_triplet`: `font_size` when `automatic_font_size` is false,
else `max_font_size`; 16 and 18 by default), for every range, so lowering
that setting scales the stats here as well. One Home row cannot hold both, so automatic height asks
for two rows when this is on (the "ZenOS stats above the year graph" toggle,
default on) and one when it is off. If the row never fits, the graph stands
alone. Asked for so the widget can replace the Reading stats row and the
year graph keeps a row to itself.

## Show on Home (added later on 14 September)

ZenOS's Widgets list refuses to switch a widget on when Home would go past
its size budget (10 units on a 4:3 screen; the cover is 3.5, a two-row
Book strip 5, Reading stats 1, and nothing may be smaller than 1). Home's
own layout is more forgiving: `Registry.layoutUnits` shrinks the widgets
that can shrink (cover to 2, strip to 1.5 per row) until an over-full page
fits. So the plugin's menu carries **Show on Home**, which flips
`rows.enabled[id]` in the Home layout through ZenOS's `config/preset_store`
(`getSettings("home")` / `saveSettings("home", layout)`), adds the id to
`rows.order` under `stats_triplet` if it is not there yet, and re-registers
so ZenOS rebuilds Home. No note is shown when the page goes over budget:
the shrink is ZenOS's normal behaviour and needs nothing from the user.
Switching off keeps ZenOS's rule that Home holds at least one widget. The
switch is absent when the store cannot be loaded (no ZenOS).

## Non-goals

- No per-preset settings, no ZenOS settings integration beyond the hook.
- No translations catalog in version 1 (strings are wrapped in `_()` for
  KOReader's own gettext).
