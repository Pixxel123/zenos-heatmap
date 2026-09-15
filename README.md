# zenos-heatmap

A KOReader plugin that adds a **Reading heatmap** widget to the
[ZenOS](https://github.com/xZenLabs/zen-os) Home page: a calendar of the
minutes you read each day, drawn in the same flat cells ZenOS uses, with your
typical week beside it. Nothing in ZenOS is changed; delete the folder and
Home is back to stock.

![The Reading heatmap widget in the year and 3-month ranges](docs/screenshot.png)

## Install

1. Download `zenheatmap.koplugin.zip` from the
   [latest release](../../releases/latest) and unzip it into
   `koreader/plugins/`, so you have `koreader/plugins/zenheatmap.koplugin/`.
2. Restart KOReader.
3. Turn it on with **Show on Home** under **More tools > Reading heatmap**
   in the KOReader menu, then move it in Home's edit mode or under
   **Zen Settings > Home > Widgets**.

The heatmap does not count against Home's size budget: ZenOS's Widgets list
lets you switch it, and anything else, on even when Home is full, and Home
then shrinks the other widgets a little to make room. The plugin arranges
this at load by asking ZenOS's registry to count its own item as 0 units;
nothing in ZenOS is changed on disk.

## Settings

Under **More tools > Reading heatmap** in the KOReader menu. ZenOS can also
put it on a Launcher or Controls button.

| Setting | Choices | Default |
| --- | --- | --- |
| Show on Home | on, off | off |
| Range | Year to date, 3 months, Month | Year to date |
| Typical week | on, off | on |
| Month labels under the graph | on, off | on |
| Shading | Relative to my average, Fixed thresholds | Relative |
| ZenOS stats above the year graph | on, off | on |
| Stats beside the graph | Two of: pages today, time today, day streak, pages this week, time this week, days read, or none. 3 months and Month only. | Time today, Day streak |
| Height | Automatic, Extra small, Small, Medium, Large (1 to 4 Home rows) | Automatic: 2 rows, or 1 for the year graph without the stats |

Darker cells mean more reading: relative shading compares each day with your
own recent average, fixed shading uses 15 and 60 minutes. Today has a thick border around it.
The typical week shows each weekday's average over the last 12 weeks as a bar,
filled towards your best weekday and shaded like the cells. The week starts on
the day set in KOReader's statistics plugin. Month labels stay whenever they
are on, shrinking with the cells in a short row. The stats are ZenOS's own
numbers: over the year graph the widget shows the same three as ZenOS's
Reading stats widget, so it can stand in for that row. They follow that
widget's font size setting too (its fixed size, or its maximum when it sizes
itself), and shrink further only when the graph needs the room.

## Compatibility

- ZenOS 3.0 or newer (tested on 3.3.0-alpha16).
- KOReader 2026.07 or newer, on any device.
- Without ZenOS the plugin loads, does nothing, and says so in its menu.
