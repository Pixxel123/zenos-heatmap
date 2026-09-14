# zenos-heatmap Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `zenheatmap.koplugin`, a KOReader plugin that adds a "Reading heatmap" Home widget to ZenOS through its external home-item hook, drawn in the heatmap's own square-cell vocabulary with a typical-week track.

**Architecture:** Three plugin files with one responsibility each: `heatmap.lua` is a pure renderer (classification, calendar spans, layout geometry, painting) that takes data and settings as arguments; `dayactivity.lua` reads KOReader's statistics database; `main.lua` owns settings, the ZenOS registration and the menu. Specs run under a self-contained busted-style runner with KOReader stubbed, so no luarocks or emulator is needed.

**Tech Stack:** Lua 5.1 / LuaJIT (KOReader's runtime), KOReader widget API (Blitbuffer, TextWidget, FrameContainer, LuaSettings), lua-ljsqlite3 for the statistics database, ZenOS `__ZENOS_REGISTER_HOME_ITEM`.

**Spec:** `docs/superpowers/specs/2026-09-14-zenos-heatmap-design.md`

## Global Constraints

- Plugin folder name `zenheatmap.koplugin`; item id `"zenheatmap.heatmap"`; widget label `Reading heatmap`.
- Shades: `COLOR_LIGHT_GRAY` outline for none, `COLOR_GRAY` light, `COLOR_GRAY_5` normal, `COLOR_BLACK` heavy; track fill `COLOR_GRAY_5`; hairline `COLOR_GRAY`.
- Sizes go through `S(v) = Screen:scaleBySize(v)`; specs stub it as identity.
- Track: three cells wide, clamped to `[S(18), S(36)]`; Month track `floor(cell * 1.5)` tall.
- Today: dotted `S(1)` border with `S(2)` inset when `cell >= S(12)`, else solid border `max(1, floor(gap / 2))` thick around the cell.
- Ranges: `"year"`, `"quarter"`, `"month"`. Settings keys: `range`, `typical_week`, `month_labels`, `shading` (`"relative"` | `"absolute"`), `size` (`"s"` | `"m"` | `"l"`).
- Every user-visible string wrapped in `_()`. No em dashes anywhere.
- Commits: plain messages, no attribution trailers (the author's convention for published repos).
- Run specs with KOReader's LuaJIT: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua` from the repo root.

---

## File structure

```
zenos-heatmap/
  zenheatmap.koplugin/
    _meta.lua           plugin metadata (name, version, description)
    main.lua            settings store, ZenOS registration, menu
    heatmap.lua         pure renderer: classify, spans, layout, build/paint
    dayactivity.lua     statistics database query, injectable opener
  spec/
    spec_helper.lua     KOReader stubs and a recording Blitbuffer
    heatmap_spec.lua    classify, spans, shares, layout, paint
    dayactivity_spec.lua
    main_spec.lua       registration, settings normalisation, menu
  tools/
    spec_runner.lua     busted-style runner (from xray-timeline-patch, extended)
    build.lua           writes dist/zenheatmap.koplugin.zip (store-only zip)
  docs/superpowers/{specs,plans}/
  .github/workflows/ci.yml
  README.md  LICENSE  .gitignore
```

`zenheatmap.koplugin/heatmap.lua` starts as a copy of the ZenOS branch widget after the typical-week rewrite (commit `wip/typical-week-track` in `~/Programming/zen-os`); Tasks 3 to 5 strip it to the plugin's needs.

---

### Task 1: Spec runner and KOReader stubs

**Files:**
- Modify: `tools/spec_runner.lua` (spec list, `assert.has_no.errors`, `assert.is_function`, `assert.near`)
- Create: `spec/spec_helper.lua`
- Create: `spec/helper_spec.lua`

**Interfaces:**
- Produces: `require("spec_helper")` returning `{ bb = function() -> recording blitbuffer, reset = function() }`. The recording bb records `paintRect`, `paintBorder` calls as `{ op, x, y, w, h, thick_or_color, color }` in `bb.calls`.
- Produces: globals for specs: `describe`, `it`, `setup`, `before_each`, `assert.*` including `assert.has_no.errors(fn)`, `assert.is_function(v)`, `assert.near(expected, actual, tolerance)`.

- [ ] **Step 1: Point the runner at this repo's specs and add the missing asserts**

In `tools/spec_runner.lua` replace the `package.path` line and the `specs` list:

```lua
package.path = "./?.lua;./spec/?.lua;./zenheatmap.koplugin/?.lua;" .. package.path
```

```lua
local specs = {
    "spec/helper_spec.lua",
    "spec/heatmap_spec.lua",
    "spec/dayactivity_spec.lua",
    "spec/main_spec.lua",
}
```

After `_G.assert.is_truthy = _G.assert.truthy` add:

```lua
_G.assert.is_function = function(val)
    if type(val) ~= "function" then error("Expected function, got " .. type(val), 2) end
end
_G.assert.near = function(expected, actual, tolerance)
    if math.abs(expected - actual) > (tolerance or 1e-6) then
        error("Expected " .. tostring(expected) .. " within " .. tostring(tolerance) .. ", got " .. tostring(actual), 2)
    end
end
_G.assert.has_no = {
    errors = function(fn)
        local ok, err = pcall(fn)
        if not ok then error("Expected no error, got: " .. tostring(err), 2) end
    end,
}
_G.assert.has_error = function(fn)
    if pcall(fn) then error("Expected an error", 2) end
end
```

Also replace the banner string `"=== Running KOReader X-Ray Unit Tests ==="` with `"=== zenos-heatmap specs ==="`.

- [ ] **Step 2: Write the KOReader stubs**

`spec/spec_helper.lua`:

```lua
-- KOReader stubbed just enough for the renderer, plus a Blitbuffer that
-- records what was painted. Text is 6 px per character and 12 px tall in
-- every face, and S(v) == v, so geometry can be asserted by hand.
local H = {}

local function stub(name, value) package.loaded[name] = value end

stub("ffi/blitbuffer", {
    COLOR_WHITE = "white", COLOR_LIGHT_GRAY = "light_gray", COLOR_GRAY = "gray",
    COLOR_DARK_GRAY = "dark_gray", COLOR_GRAY_5 = "gray_5", COLOR_GRAY_3 = "gray_3",
    COLOR_BLACK = "black",
})
stub("device", {
    screen = {
        scaleBySize = function(_, v) return v end,
        getWidth = function() return 1000 end,
        getHeight = function() return 1300 end,
    },
})
stub("ui/font", { getFace = function(_, name, size) return { name = name, size = size } end })
stub("ui/geometry", { new = function(_, t) return t end })
stub("ui/widget/container/framecontainer", { new = function(_, t) return t end })
stub("ui/widget/textwidget", { new = function(_, t)
    t.getSize = function() return { w = #tostring(t.text) * 6, h = 12 } end
    t.paintTo = function(self, bb, x, y) bb.calls[#bb.calls + 1] = { "text", x, y, self.text } end
    t.free = function() end
    return t
end })
stub("gettext", function(s) return s end)
stub("luasettings", nil)  -- main.lua tests supply their own

function H.bb()
    local bb = { calls = {} }
    function bb:paintRect(x, y, w, h, color) self.calls[#self.calls + 1] = { "rect", x, y, w, h, color } end
    function bb:paintBorder(x, y, w, h, thick, color) self.calls[#self.calls + 1] = { "border", x, y, w, h, thick, color } end
    return bb
end

-- Calls of one kind, e.g. H.only(bb, "rect").
function H.only(bb, op)
    local out = {}
    for _i, c in ipairs(bb.calls) do if c[1] == op then out[#out + 1] = c end end
    return out
end

return H
```

- [ ] **Step 3: Write a spec that proves the harness works**

`spec/helper_spec.lua`:

```lua
local H = require("spec_helper")
describe("spec helper", function()
    it("records paints", function()
        local bb = H.bb()
        bb:paintRect(1, 2, 3, 4, "black")
        bb:paintBorder(0, 0, 10, 10, 1, "gray")
        assert.equals(2, #bb.calls)
        assert.same({ "rect", 1, 2, 3, 4, "black" }, bb.calls[1])
        assert.equals(1, #H.only(bb, "border"))
    end)
    it("stubs text at six pixels a character", function()
        local T = require("ui/widget/textwidget")
        assert.equals(60, T:new{ text = "day streak" }:getSize().w)
    end)
    it("has the extra asserts", function()
        assert.has_no.errors(function() end)
        assert.is_function(print)
        assert.near(1.0, 1.0000001, 1e-3)
    end)
end)
```

- [ ] **Step 4: Run the runner and see the helper spec pass and the others fail to load**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua`
Expected: helper spec passes (3 passed); the three missing spec files print "Error loading spec file"; the process still exits 0 because no `it` failed. (Comment the missing files out of the list until their tasks land, or accept the load errors; they must be gone by Task 7.)

- [ ] **Step 5: Commit**

```bash
git add tools/spec_runner.lua spec/spec_helper.lua spec/helper_spec.lua .gitignore LICENSE
git commit -m "spec runner and KOReader stubs"
```

---

### Task 2: Day activity query

**Files:**
- Create: `zenheatmap.koplugin/dayactivity.lua`
- Create: `spec/dayactivity_spec.lua`

**Interfaces:**
- Produces: `DayActivity.query(days, opts)` returning `{ days = { { date = "YYYY-MM-DD", minutes = number }, ... } (oldest first, exactly `days` entries ending today), avg_28 = number, max = number }`. `opts.open` (a function returning a connection with `exec(sql)` and `close()`) and `opts.now` (unix time) exist for tests; defaults open KOReader's statistics database and use `os.time()`.
- Produces: `DayActivity.flushPending(opts)` flushes the statistics plugin's pending rows at most every 30 s.

- [ ] **Step 1: Write the failing spec**

`spec/dayactivity_spec.lua`:

```lua
require("spec_helper")
describe("day activity", function()
    local DayActivity = require("dayactivity")
    -- 2026-09-14 12:00 local time; the fake connection answers the one query
    -- with two days of reading.
    local noon = os.time{ year = 2026, month = 9, day = 14, hour = 12 }
    local function fake_conn(rows)
        return function()
            return {
                exec = function(_, sql)
                    assert.is_true(sql:find("FROM page_stat_data") ~= nil)
                    local dates, minutes = {}, {}
                    for _i, r in ipairs(rows) do dates[#dates + 1] = r[1]; minutes[#minutes + 1] = r[2] end
                    return { dates, minutes }
                end,
                close = function() end,
            }
        end
    end
    it("returns one entry per day ending today, minutes filled from the rows", function()
        local out = DayActivity.query(5, { open = fake_conn{ { "2026-09-14", 49 }, { "2026-09-12", 30 } }, now = noon })
        assert.equals(5, #out.days)
        assert.equals("2026-09-10", out.days[1].date)
        assert.equals("2026-09-14", out.days[5].date)
        assert.equals(49, out.days[5].minutes)
        assert.equals(30, out.days[3].minutes)
        assert.equals(0, out.days[4].minutes)
    end)
    it("averages the last 28 days that had reading and reports the maximum", function()
        local out = DayActivity.query(40, { open = fake_conn{ { "2026-09-14", 40 }, { "2026-09-13", 20 }, { "2026-08-01", 500 } }, now = noon })
        assert.equals(30, out.avg_28)
        assert.equals(40, out.max)
    end)
    it("copes with no database", function()
        local out = DayActivity.query(3, { open = function() return nil, "no db" end, now = noon })
        assert.equals(3, #out.days)
        assert.equals(0, out.avg_28)
    end)
    it("ignores rows outside the window", function()
        local out = DayActivity.query(2, { open = fake_conn{ { "2020-01-01", 99 } }, now = noon })
        assert.equals(0, out.days[1].minutes + out.days[2].minutes)
    end)
end)
```

- [ ] **Step 2: Run it and watch it fail**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua spec/dayactivity_spec.lua`
Expected: "module 'dayactivity' not found".

- [ ] **Step 3: Implement**

`zenheatmap.koplugin/dayactivity.lua`:

```lua
-- Minutes read per local day from KOReader's statistics database.
local M = {}

M.SERIES_DAYS = 371
local FLUSH_MIN_INTERVAL_S = 30
local last_flush_at = 0

local function db_path()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then return nil end
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

local function default_open()
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    local path = db_path()
    if not (ok_sq and path) then return nil, "no sqlite" end
    local ok, conn = pcall(SQ3.open, path)
    if not ok then return nil, conn end
    return conn
end

-- The statistics plugin keeps recent page rows in memory; ask it to write
-- them out before reading, at most every 30 seconds.
function M.flushPending(opts)
    local now = opts and opts.now or os.time()
    if now - last_flush_at < FLUSH_MIN_INTERVAL_S then return false end
    last_flush_at = now
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not (ok and PluginLoader and PluginLoader.getPluginInstance) then return false end
    local stats = PluginLoader:getPluginInstance("statistics")
    if type(stats) ~= "table" or type(stats.insertDB) ~= "function" then return false end
    if type(stats.isEnabled) == "function" and not stats:isEnabled() then return false end
    return pcall(stats.insertDB, stats) and true or false
end

local function start_of_day(ts)
    local t = os.date("*t", ts)
    return os.time{ year = t.year, month = t.month, day = t.day, hour = 0 }
end

function M.query(days, opts)
    opts = opts or {}
    days = math.max(1, math.floor(tonumber(days) or M.SERIES_DAYS))
    local now = opts.now or os.time()
    local today_start = start_of_day(now)
    local start_time = today_start - (days - 1) * 86400
    local out = { days = {}, avg_28 = 0, max = 0 }
    local by_date = {}
    for offset = days - 1, 0, -1 do
        local date = os.date("%Y-%m-%d", today_start - offset * 86400)
        local row = { date = date, minutes = 0 }
        out.days[#out.days + 1] = row
        by_date[date] = row
    end
    if not opts.open then M.flushPending(opts) end
    local conn = (opts.open or default_open)()
    if conn then
        local ok, result = pcall(function()
            return conn:exec(string.format([[
                SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS day,
                       SUM(duration) / 60.0 AS minutes
                FROM page_stat_data
                WHERE start_time >= %d
                GROUP BY day
                ORDER BY day;
            ]], start_time))
        end)
        if ok and result and result[1] then
            for i = 1, #result[1] do
                local row = by_date[result[1][i]]
                if row then row.minutes = tonumber(result[2][i]) or 0 end
            end
        end
        pcall(conn.close, conn)
    end
    local sum, n = 0, 0
    for i = math.max(1, #out.days - 27), #out.days do
        local m = out.days[i].minutes
        if m > 0 then sum, n = sum + m, n + 1 end
        if m > out.max then out.max = m end
    end
    out.avg_28 = n > 0 and sum / n or 0
    return out
end

return M
```

- [ ] **Step 4: Run the spec**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua spec/dayactivity_spec.lua`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add zenheatmap.koplugin/dayactivity.lua spec/dayactivity_spec.lua
git commit -m "day activity query"
```

---

### Task 3: Renderer core, pure functions

**Files:**
- Modify: `zenheatmap.koplugin/heatmap.lua` (the seeded copy of the ZenOS widget)
- Create: `spec/heatmap_spec.lua`

**Interfaces:**
- Produces: `Heatmap.classify(minutes, baseline, mode) -> 0..3`, `Heatmap.weekdayShares(days, today_col, weeks) -> shares[0..6], raw[0..6]`, `Heatmap.spanShape(year, month_from, month_to, start) -> span`, `Heatmap.spanFor(range, now, start) -> span`, `Heatmap.weekdayCol(wday, start) -> 0..6`, `Heatmap.WEEKDAY_LETTERS`.
- Removes from the seeded file: everything about stat slots and row A.

- [ ] **Step 1: Strip the seeded renderer to its pure core**

Edit `zenheatmap.koplugin/heatmap.lua`:

1. Replace the require block at the top with:

```lua
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local _ = require("gettext")

local Screen = Device.screen

local M = {}
```

2. Delete the `_icons_dir` block and `flame_icon_path`; delete `fmt_time`; delete `M.range`, `M.monthLabels`, `M.showStats`, `M.typicalWeek`, `M.FIELDS`, `M.DEFAULT_SLOTS`, `M.rowFields` (settings arrive normalised from main.lua; the renderer reads `cfg.range`, `cfg.typical_week`, `cfg.month_labels`, `cfg.shading`).
3. Keep `FILL_*`, `TEXT_MUTED`, `FILLS`, `SERIES_DAYS`, `AVERAGE_WEEKS`, `WEEKDAY_LETTERS` (export it: `M.WEEKDAY_LETTERS = WEEKDAY_LETTERS`), `S`, `M.classify`, `M.weekdayShares`, `M.spanShape`, `M.spanFor`, `paint_dotted_border`, `paint_cell`.
4. Delete `week_start` (main.lua resolves it) and rename `weekday_col` to an exported `M.weekdayCol`.
5. Delete everything from `-- Same floors as the Numbers triplet` through the end of the file for now (layout and build come back in Tasks 4 and 5). End the file with `return M`.

- [ ] **Step 2: Write the specs for the core (ported from the ZenOS branch)**

`spec/heatmap_spec.lua`:

```lua
local H = require("spec_helper")
describe("heatmap core", function()
    local Heatmap = require("heatmap")
    describe("classify", function()
        it("returns 0 for no reading", function()
            assert.equals(0, Heatmap.classify(0, 40, "relative"))
            assert.equals(0, Heatmap.classify(nil, 40, "relative"))
            assert.equals(0, Heatmap.classify(-5, 0, "absolute"))
        end)
        it("shades relative to the baseline", function()
            assert.equals(1, Heatmap.classify(10, 40, "relative"))
            assert.equals(2, Heatmap.classify(20, 40, "relative"))
            assert.equals(2, Heatmap.classify(50, 40, "relative"))
            assert.equals(3, Heatmap.classify(51, 40, "relative"))
        end)
        it("uses fixed thresholds without a baseline and in absolute mode", function()
            assert.equals(1, Heatmap.classify(14, 0, "relative"))
            assert.equals(2, Heatmap.classify(15, 200, "absolute"))
            assert.equals(2, Heatmap.classify(60, 200, "absolute"))
            assert.equals(3, Heatmap.classify(61, 200, "absolute"))
        end)
    end)
    describe("weekdayShares", function()
        it("averages each weekday column over the window and normalises to the best", function()
            local days = {}
            for i = 1, 14 do days[i] = { minutes = (i % 7 == 0) and 60 or 30 } end
            local shares, raw = Heatmap.weekdayShares(days, 6, 2)
            assert.equals(1, shares[6])
            assert.equals(0.5, shares[0])
            assert.equals(60, raw[6])
        end)
        it("returns zeros without history", function()
            local shares = Heatmap.weekdayShares({}, 3)
            for col = 0, 6 do assert.equals(0, shares[col]) end
        end)
    end)
    describe("spans", function()
        it("shapes a run of months from its first weekday", function()
            local q = Heatmap.spanShape(2026, 7, 9, 2)
            assert.equals(92, q.days)
            assert.equals(3, #q.months)
            assert.equals("Jul", q.months[1].label)
            assert.equals("2026-07-01", q.start_date)
            assert.equals(14, q.weeks)
        end)
        it("rolls month numbers over and picks the range window", function()
            local wrap = Heatmap.spanFor("quarter", { year = 2026, month = 1, day = 5 }, 2)
            assert.equals("2025-11-01", wrap.start_date)
            assert.equals(365, Heatmap.spanFor("year", { year = 2026, month = 9 }, 2).days)
            assert.equals(30, Heatmap.spanFor("month", { year = 2026, month = 9 }, 2).days)
        end)
        it("maps a weekday to its column from the week start", function()
            assert.equals(0, Heatmap.weekdayCol(2, 2))
            assert.equals(6, Heatmap.weekdayCol(1, 2))
            assert.equals(0, Heatmap.weekdayCol(1, 1))
        end)
    end)
end)
```

- [ ] **Step 3: Run the specs**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua spec/heatmap_spec.lua`
Expected: 8 passed. If `spanShape` numbers differ, check the week start argument (2 = Monday) before touching the code; these values passed in the ZenOS branch.

- [ ] **Step 4: Commit**

```bash
git add zenheatmap.koplugin/heatmap.lua spec/heatmap_spec.lua
git commit -m "renderer core: classify, shares, spans"
```

---

### Task 4: Layout geometry

**Files:**
- Modify: `zenheatmap.koplugin/heatmap.lua` (append layout code)
- Modify: `spec/heatmap_spec.lua` (append layout specs)

**Interfaces:**
- Produces: `Heatmap.layout(width, height, cfg, span, probe) -> m` where `cfg = { range, typical_week, month_labels }`, `span` from `spanFor`, `probe(str, face) -> w, h` (defaults to a TextWidget prober). `height` nil means natural. Fields on `m` used by Task 5 and the specs: `pad_x, pad_y, inner_w, range, typical, letter_w, left_w, track_w, track_h, cell, cell_w, gap, grid_w, grid_h, block_x, labels, header_h, label_h, month_face, letter_face, month_label_h, col_span, content_h, fits_h, complete`.
- Produces: `Heatmap.preferredHeight(width, cfg, span)`.

- [ ] **Step 1: Write the failing layout specs**

Append inside the `describe("heatmap core"...)` block of `spec/heatmap_spec.lua`, or in a new top-level describe:

```lua
describe("heatmap layout", function()
    local Heatmap = require("heatmap")
    -- 2026 with a Monday week start: Jan 1 is a Thursday, 53 week columns.
    local YEAR = { first_col = 3, days = 365, weeks = 53, months = {}, start_ts = 0, start_date = "2026-01-01" }
    local MONTH = { first_col = 1, days = 30, weeks = 5, months = {}, start_ts = 0, start_date = "2026-09-01" }
    local Q = { first_col = 2, days = 92, weeks = 14, months = {}, start_ts = 0, start_date = "2026-07-01" }
    local function cfg(t) t.range = t.range or "year"; if t.typical_week == nil then t.typical_week = true end; if t.month_labels == nil then t.month_labels = true end; return t end

    it("reserves a left block for the letters and the track in the year graph", function()
        local m = Heatmap.layout(1000, nil, cfg{}, YEAR)
        -- letters are one 6 px character; block = 6 + 5 + 36 + 6 + 1 + 6
        assert.equals(6, m.letter_w)
        assert.equals(60, m.left_w)
        assert.equals(988 - 60, m.grid_w)
        assert.is_true(m.track_w >= 18 and m.track_w <= 36)
        assert.equals(3 * m.cell + 2 * m.gap, m.track_w)
        assert.is_true(m.labels)
    end)
    it("drops the track but keeps the letters with the typical week off", function()
        local m = Heatmap.layout(1000, nil, cfg{ typical_week = false }, YEAR)
        assert.equals(11, m.left_w)
        assert.equals(0, m.track_w)
    end)
    it("fits a short row by shrinking cells, then dropping the month labels", function()
        local tall = Heatmap.layout(1000, nil, cfg{}, YEAR)
        local short = Heatmap.layout(1000, 70, cfg{}, YEAR)
        assert.is_true(short.cell < tall.cell)
        assert.is_true(short.content_h <= 70)
        local tiny = Heatmap.layout(1000, 40, cfg{}, YEAR)
        assert.is_false(tiny.labels)
        assert.is_true(tiny.content_h <= 40)
    end)
    it("widens quarter cells up to 2:1 and stacks the month header", function()
        local q = Heatmap.layout(1000, nil, cfg{ range = "quarter" }, Q)
        assert.is_true(q.cell_w >= q.cell and q.cell_w <= 2 * q.cell)
        local mo = Heatmap.layout(1000, nil, cfg{ range = "month" }, MONTH)
        assert.equals(12 + 3 + math.floor(mo.cell * 1.5) + 4, mo.header_h)
        assert.equals(math.floor(mo.cell * 1.5), mo.track_h)
        local off = Heatmap.layout(1000, nil, cfg{ range = "month", typical_week = false }, MONTH)
        assert.equals(12 + 3, off.header_h)
        assert.equals(math.floor((988 - mo.grid_w) / 2), mo.block_x)
    end)
    it("reports the natural height", function()
        local m = Heatmap.layout(1000, nil, cfg{}, YEAR)
        assert.equals(m.content_h, Heatmap.preferredHeight(1000, cfg{}, YEAR))
    end)
end)
```

- [ ] **Step 2: Run and watch the layout specs fail**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua spec/heatmap_spec.lua`
Expected: the five layout cases fail with "attempt to call field 'layout'".

- [ ] **Step 3: Append the layout code**

Append to `zenheatmap.koplugin/heatmap.lua` before `return M` (this is the year, quarter and month layout from the ZenOS rewrite with row A removed; the shapes of `grid_size`, `left_block_w`, `track_width`, `fit_left_block` are unchanged):

```lua
-- Width and height of `cols` by `rows` square cells.
local function grid_size(cell, gap, cols, rows)
    return cell * cols + gap * (cols - 1), cell * rows + gap * (rows - 1)
end

-- Width and height of `str` set in `face`, cached per face.
local function text_prober()
    local cache = {}
    return function(str, face)
        local for_face = cache[face]
        if not for_face then for_face = {}; cache[face] = for_face end
        local hit = for_face[str]
        if hit then return hit[1], hit[2] end
        local w = TextWidget:new{ text = str, face = face }
        local size = w:getSize()
        if w.free then w:free() end
        for_face[str] = { size.w or 0, size.h or 1 }
        return size.w or 0, size.h or 1
    end
end

-- The typical week's track beside a graph: three cells wide, within limits.
local TRACK_MAX = 36
local function track_width(m, cell, gap)
    return m.typical and math.max(S(18), math.min(S(TRACK_MAX), 3 * cell + 2 * gap)) or 0
end

-- Width of the block left of a graph: the weekday letters, then, with the
-- typical week on, room for its widest track, a gap, a hairline and a gap.
local function left_block_w(m)
    return m.letter_w + S(5) + (m.typical and (S(TRACK_MAX) + S(6) + S(1) + S(6)) or 0)
end

-- Year to date: a week-column graph of the whole year with the letters and
-- track down its left side. The grid grows into spare room; a short row
-- shrinks the cells under the month labels as far as S(6), drops the
-- labels only when the cells would have to go below that, then shrinks
-- the cells to S(4) and closes the gaps.
local function layout_year(m, cfg, avail_h)
    local cols = m.span.weeks
    local labels_wanted = cfg.month_labels ~= false
    local labels_h = S(3) + m.month_label_h
    m.gap = S(2)
    m.left_w = left_block_w(m)
    local graph_w = m.inner_w - m.left_w
    local by_w = math.floor((graph_w - (cols - 1) * m.gap) / cols)
    local cell_max = math.max(S(4), math.min(S(8), by_w))
    local cell_labelled_min = math.min(S(6), cell_max)
    local function by_h(with_labels)
        return math.floor((avail_h - (with_labels and labels_h or 0) - 6 * m.gap) / 7)
    end
    m.labels = labels_wanted and by_h(true) >= cell_labelled_min
    local room = by_h(m.labels)
    if room >= cell_max then
        m.cell = math.max(cell_max, math.min(S(14), by_w, room))
    else
        if room < S(4) then
            m.gap = S(1)
            room = by_h(false)
        end
        m.cell = math.max(S(4), math.min(cell_max, room))
    end
    m.complete = m.cell >= cell_max and (m.labels or not labels_wanted)
    m.grid_w, m.grid_h = grid_size(m.cell, m.gap, cols, 7)
    -- Integer cells leave up to a column's worth of slack on the right; the
    -- columns spread across the graph's width instead.
    if m.cell >= S(6) and m.grid_w < graph_w and graph_w - m.grid_w <= cols * S(2) then
        m.col_span = graph_w - m.cell
        m.grid_w = graph_w
    end
    m.track_w = track_width(m, m.cell, m.gap)
    m.block_x = 0
    m.content_h = m.pad_y + m.grid_h + (m.labels and labels_h or 0)
end

-- Quarter and month: cells shrink from `cell_max` to `cell_min` until the
-- block fits `avail_h`; the gaps close as a last resort.
local function fit_block(m, avail_h, cell_max, cell_min, block_h)
    local cell, gap = cell_max, S(4)
    while cell > cell_min and block_h(cell, gap) > avail_h do cell = cell - 1 end
    if block_h(cell, gap) > avail_h then gap = S(2) end
    m.cell, m.gap = cell, gap
    m.content_h = m.pad_y + block_h(cell, gap)
    m.complete = block_h(cell, gap) <= avail_h
end

-- Three months: a week-column graph with the letters and track beside it.
local function layout_quarter(m, cfg, avail_h)
    local cols = m.span.weeks
    m.labels = cfg.month_labels ~= false
    local labels_h = m.labels and (S(3) + m.month_label_h) or 0
    m.left_w = left_block_w(m)
    local room_w = m.inner_w - m.left_w
    local by_w = math.floor((room_w - (cols - 1) * S(4)) / cols)
    fit_block(m, avail_h, math.max(S(8), math.min(S(32), by_w)), S(8), function(cell, gap)
        return cell * 7 + gap * 6 + labels_h
    end)
    m.cell_w = math.max(m.cell, math.min(m.cell * 2, math.max(S(8), math.min(S(32), by_w))))
    m.grid_w, m.grid_h = grid_size(m.cell_w, m.gap, cols, 7)
    m.grid_h = m.cell * 7 + m.gap * 6
    m.track_w = track_width(m, m.cell_w, m.gap)
    m.block_x = 0
end

-- Month: the weekday letters over the calendar and, with the typical week
-- on, an upright track under each letter. The calendar is centred.
local function layout_month(m, cfg, avail_h)
    local rows = m.span.weeks
    local by_w = math.floor((m.inner_w / 3 - 6 * S(4)) / 7)
    local function track_h(cell) return m.typical and math.floor(cell * 1.5) or 0 end
    local function header_h(cell)
        return m.label_h + S(3) + (m.typical and (track_h(cell) + S(4)) or 0)
    end
    fit_block(m, avail_h, math.max(S(14), math.min(S(32), by_w)), S(14), function(cell, gap)
        return header_h(cell) + S(3) + cell * rows + gap * (rows - 1)
    end)
    m.header_h = header_h(m.cell)
    m.track_h = track_h(m.cell)
    m.grid_w, m.grid_h = grid_size(m.cell, m.gap, 7, rows)
    m.left_w, m.track_w = 0, 0
    m.block_x = math.floor((m.inner_w - m.grid_w) / 2)
end

-- Geometry for one row. `height` is the row height to fit into (nil for the
-- natural size); `cfg` is normalised settings; `span` from spanFor.
function M.layout(width, height, cfg, span, probe)
    probe = probe or text_prober()
    local m = { range = cfg.range or "year", typical = cfg.typical_week ~= false, span = span }
    m.pad_x = S(6)
    m.pad_y = S(6)
    m.inner_w = math.max(1, width - m.pad_x * 2)
    -- The month labels and the row letters share a small face; the
    -- calendar's column letters take the caption face.
    m.month_face = Font:getFace("smallinfofont", S(7))
    m.letter_face = Font:getFace("smallinfofont", S(11))
    m.month_label_h = select(2, probe("W", m.month_face))
    m.label_h = select(2, probe("A", m.letter_face))
    m.letter_w = 0
    for i = 1, 7 do m.letter_w = math.max(m.letter_w, (probe(WEEKDAY_LETTERS[i], m.month_face))) end
    local avail_h = height and (height - m.pad_y) or math.huge
    if m.range == "quarter" then
        layout_quarter(m, cfg, avail_h)
    elseif m.range == "month" then
        layout_month(m, cfg, avail_h)
    else
        layout_year(m, cfg, avail_h)
    end
    m.fits_h = not height or m.content_h <= height
    return m
end

function M.preferredHeight(width, cfg, span)
    return M.layout(width, nil, cfg, span).content_h
end
```

Two spec expectations depend on the stub metrics: `letter_w` is 6 (one character at 6 px) and `label_h` is 12, so `left_w` with the track is `6 + 5 + 36 + 6 + 1 + 6 = 60` and without it `6 + 5 = 11`.

- [ ] **Step 4: Run the specs**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua spec/heatmap_spec.lua`
Expected: 13 passed. If the short-row case fails on `labels`, check `by_h` against the stub's 12 px label height: at height 40, `avail_h = 34`, `by_h(true) = floor((34 - 15 - 12) / 7) = 1 < 6`, so labels drop.

- [ ] **Step 5: Commit**

```bash
git add zenheatmap.koplugin/heatmap.lua spec/heatmap_spec.lua
git commit -m "renderer layout: year, quarter, month with the typical-week track"
```

---

### Task 5: Build and paint

**Files:**
- Modify: `zenheatmap.koplugin/heatmap.lua` (append `M.build`)
- Modify: `spec/heatmap_spec.lua` (append paint specs)

**Interfaces:**
- Consumes: `M.layout`, `M.spanFor`, `M.classify`, `M.weekdayShares`, `M.weekdayCol` from Tasks 3 and 4; `activity` shaped as `DayActivity.query` returns.
- Produces: `Heatmap.build(ctx, cfg, activity) -> FrameContainer` where `ctx = { width, height, setContentBounds? }`, `cfg = { range, typical_week, month_labels, shading, week_start, now? }` (`now` is an `os.date("*t")` table for tests).

- [ ] **Step 1: Write the failing paint specs**

Append to `spec/heatmap_spec.lua`:

```lua
describe("heatmap paint", function()
    local H = require("spec_helper")
    local Heatmap = require("heatmap")
    local NOW = { year = 2026, month = 9, day = 14, wday = 2 }   -- a Monday
    local function activity(n, minutes)
        local out = { days = {}, avg_28 = 30, max = 60 }
        for i = 1, n do out.days[i] = { date = "2026-01-01", minutes = minutes(i) } end
        return out
    end
    local function paint(cfg, act)
        cfg.week_start = 2; cfg.now = NOW
        local frame = Heatmap.build({ width = 1000, height = 300 }, cfg, act)
        local bb = H.bb()
        frame[1].paintTo(frame[1], bb, 0, 0)
        return bb, frame
    end
    it("fills each track by the weekday's share and outlines the rest", function()
        local bb = paint({ range = "year", typical_week = true }, activity(371, function(i) return (i % 7 == 0) and 60 or 30 end))
        local borders, rects = H.only(bb, "border"), H.only(bb, "rect")
        assert.is_true(#borders >= 7)          -- seven track outlines at least
        local fills = {}
        for _i, r in ipairs(rects) do if r[6] == "gray_5" and r[4] > 0 then fills[#fills + 1] = r end end
        assert.is_true(#fills >= 7)
    end)
    it("paints no track and no hairline with the typical week off", function()
        local bb = paint({ range = "year", typical_week = false }, activity(371, function() return 10 end))
        for _i, r in ipairs(H.only(bb, "rect")) do assert.is_true(r[6] ~= "gray") end
    end)
    it("marks today once, solid on small cells and dotted on large ones", function()
        local bb = paint({ range = "year", typical_week = true }, activity(371, function() return 10 end))
        local black_borders = 0
        for _i, b in ipairs(H.only(bb, "border")) do if b[7] == "black" then black_borders = black_borders + 1 end end
        assert.equals(1, black_borders)
        local bb2 = paint({ range = "month", typical_week = true }, activity(371, function() return 10 end))
        local dotted = 0
        for _i, r in ipairs(H.only(bb2, "rect")) do if r[6] == "black" and r[4] <= 2 and r[5] <= 2 then dotted = dotted + 1 end end
        assert.is_true(dotted > 4)
    end)
    it("frees its text widgets and reports bounds", function()
        local bounds
        local frame = Heatmap.build({ width = 1000, height = 300, setContentBounds = function(b) bounds = b end },
            { range = "quarter", typical_week = true, week_start = 2, now = NOW }, activity(371, function() return 0 end))
        assert.is_table(bounds)
        assert.is_true(bounds.bottom > bounds.top)
        assert.has_no.errors(function() frame[1].free() end)
    end)
    it("always asks for 371 days of history", function()
        assert.equals(371, Heatmap.SERIES_DAYS)
    end)
end)
```

- [ ] **Step 2: Run and watch them fail**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua spec/heatmap_spec.lua`
Expected: the five paint cases fail with "attempt to call field 'build'".

- [ ] **Step 3: Append the build and paint code**

Append to `zenheatmap.koplugin/heatmap.lua` before `return M`:

```lua
M.SERIES_DAYS = SERIES_DAYS

-- A paintable the FrameContainer frees with its text widgets.
local function managed(dimen, resources, paint)
    return {
        dimen = dimen,
        getSize = function(self) return self.dimen end,
        handleEvent = function() return false end,
        paintTo = paint,
        free = function()
            for _i, w in ipairs(resources) do if w.free then w:free() end end
        end,
    }
end

function M.build(ctx, cfg, activity)
    cfg = type(cfg) == "table" and cfg or {}
    local shading = cfg.shading == "absolute" and "absolute" or "relative"
    local start = tonumber(cfg.week_start) or 2
    local range = cfg.range or "year"
    local days = activity and activity.days or {}
    local baseline = tonumber(activity and activity.avg_28) or 0
    local now = cfg.now or os.date("*t")
    local today_col = M.weekdayCol(now.wday, start)
    local shares = M.weekdayShares(days, today_col)
    local span = M.spanFor(range, now, start) or M.spanFor("year", now, start)
    local today_noon = os.time{ year = now.year, month = now.month, day = now.day, hour = 12 }
    local today_offset = math.floor((today_noon - span.start_ts) / 86400 + 0.5)

    -- Shade of each day of the window, -1 for days still to come.
    local levels = {}
    local n = #days
    for k = 0, span.days - 1 do
        local back = today_offset - k
        if back < 0 then
            levels[k] = -1
        else
            local entry = days[n - back]
            levels[k] = M.classify(entry and entry.minutes or 0, baseline, shading)
        end
    end

    local width, height = ctx.width, ctx.height
    local m = M.layout(width, height, cfg, span)

    local resources = {}
    local function text(str, face)
        local w = TextWidget:new{ text = str, face = face, fgcolor = TEXT_MUTED }
        resources[#resources + 1] = w
        local size = w:getSize()
        return { widget = w, w = size.w or 0, h = size.h or 0 }
    end
    local row_labels, day_labels = {}, {}
    for col = 0, 6 do
        local letter = WEEKDAY_LETTERS[((start - 1 + col) % 7) + 1]
        row_labels[col] = text(letter, m.month_face)
        day_labels[col] = text(letter, m.letter_face)
    end
    local month_labels
    if range ~= "month" and m.labels then
        month_labels = {}
        for _i, month in ipairs(span.months) do
            local lbl = text(month.label, m.month_face)
            lbl.col = math.floor((span.first_col + month.day - 1) / 7)
            month_labels[#month_labels + 1] = lbl
        end
    end

    -- A graph on its own is centred in the row.
    local top = math.max(0, math.floor((height - m.content_h) / 2))
    local shift = { value = 0 }
    local cell_w = m.cell_w or m.cell
    local function col_x(col)
        if m.col_span and span.weeks > 1 then
            return math.floor(col * m.col_span / (span.weeks - 1))
        end
        return col * (cell_w + m.gap)
    end

    -- One square per day, future days outlined. Today keeps its shade inset
    -- under a dotted outline once the cells have room for it; smaller cells
    -- keep the whole shade under a solid border that takes the gap.
    local function paint_days(bb, gx, gy, weeks_down)
        local step = m.cell + m.gap
        local dotted = m.cell >= S(12)
        for k = 0, span.days - 1 do
            local slot = span.first_col + k
            local week, day = math.floor(slot / 7), slot % 7
            local x, y, w = gx + col_x(week), gy + day * step, cell_w
            if weeks_down then x, y, w = gx + day * step, gy + week * step, m.cell end
            local level = levels[k]
            if level < 0 then
                bb:paintBorder(x, y, w, m.cell, 1, FILL_EDGE, 0)
            elseif k == today_offset then
                if dotted then
                    if level > 0 then
                        local inset = S(2)
                        bb:paintRect(x + inset, y + inset, w - 2 * inset, m.cell - 2 * inset, FILLS[level])
                    end
                    paint_dotted_border(bb, x, y, w, m.cell, S(1), Blitbuffer.COLOR_BLACK)
                else
                    paint_cell(bb, x, y, w, m.cell, level)
                    local t = math.max(1, math.floor(m.gap / 2))
                    bb:paintBorder(x - t, y - t, w + 2 * t, m.cell + 2 * t, t, Blitbuffer.COLOR_BLACK, 0)
                end
            else
                paint_cell(bb, x, y, w, m.cell, level)
            end
        end
    end

    -- Letters down the rows, the typical week's track filled from the left,
    -- and a hairline before the graph.
    local function paint_left(bb, ox, gy)
        local step = m.cell + m.gap
        local tx = ox + m.letter_w + S(5)
        for col = 0, 6 do
            local y = gy + col * step
            local lbl = row_labels[col]
            lbl.widget:paintTo(bb, ox + m.letter_w - lbl.w, y + math.floor((m.cell - lbl.h) / 2))
            if m.typical then
                bb:paintBorder(tx, y, m.track_w, m.cell, 1, FILL_EDGE, 0)
                local fill = math.floor(m.track_w * shares[col] + 0.5)
                if fill > 0 then bb:paintRect(tx, y, fill, m.cell, FILL_MID) end
            end
        end
        if m.typical then
            bb:paintRect(ox + m.left_w - S(7), gy, S(1), 7 * step - m.gap, FILL_LIGHT)
        end
    end

    -- Month header: letters centred on each column and, with the typical
    -- week on, an upright track under each, filled from the bottom.
    local function paint_header(bb, ox, y)
        local step = m.cell + m.gap
        for col = 0, 6 do
            local x = ox + col * step
            local lbl = day_labels[col]
            lbl.widget:paintTo(bb, x + math.floor((m.cell - lbl.w) / 2), y)
            if m.typical then
                local ty = y + m.label_h + S(3)
                bb:paintBorder(x, ty, m.cell, m.track_h, 1, FILL_EDGE, 0)
                local fill = math.floor(m.track_h * shares[col] + 0.5)
                if fill > 0 then bb:paintRect(x, ty + m.track_h - fill, m.cell, fill, FILL_MID) end
            end
        end
    end

    local function paint_graph(bb, gx, gy)
        paint_days(bb, gx, gy, false)
        if not month_labels then return end
        local ly = gy + m.grid_h + S(3)
        local last_right = -math.huge
        for _i, lbl in ipairs(month_labels) do
            local x = gx + col_x(lbl.col)
            if x >= last_right + S(6) and x + lbl.w <= gx + m.grid_w then
                lbl.widget:paintTo(bb, x, ly)
                last_right = x + lbl.w
            end
        end
    end

    local content = managed(Geom:new{ w = width, h = height }, resources, function(_self, bb, x, y)
        local ox = x + m.pad_x + m.block_x
        local oy = y + top + m.pad_y + shift.value
        if m.range == "month" then
            paint_header(bb, ox, oy)
            paint_days(bb, ox, oy + m.header_h + S(3), true)
        else
            paint_left(bb, ox, oy)
            paint_graph(bb, ox + m.left_w, oy)
        end
    end)

    if type(ctx.setContentBounds) == "function" then
        ctx.setContentBounds{
            top = top, bottom = top + m.content_h,
            min_shift = -top, max_shift = math.max(0, height - (top + m.content_h)),
            set_shift = function(v) shift.value = v end,
        }
    end

    return FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, content }
end
```

- [ ] **Step 4: Run the whole suite**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua`
Expected: all heatmap, dayactivity and helper cases pass; only `spec/main_spec.lua` fails to load.

- [ ] **Step 5: Commit**

```bash
git add zenheatmap.koplugin/heatmap.lua spec/heatmap_spec.lua
git commit -m "renderer build and paint"
```

---

### Task 6: Plugin entry: settings, registration, menu

**Files:**
- Create: `zenheatmap.koplugin/_meta.lua`
- Create: `zenheatmap.koplugin/main.lua`
- Create: `spec/main_spec.lua`

**Interfaces:**
- Consumes: `Heatmap.build(ctx, cfg, activity)`, `DayActivity.query(days)`, `DayActivity.SERIES_DAYS`.
- Produces: `ZenHeatmap.normalize(cfg) -> cfg` (pure, exported for tests), `ZenHeatmap:register() -> boolean`, `ZenHeatmap:menuItems() -> table`, `ZenHeatmap.ITEM_ID`.

- [ ] **Step 1: Write the failing spec**

`spec/main_spec.lua`:

```lua
require("spec_helper")
describe("plugin entry", function()
    local registered, unregistered
    local settings_data
    setup(function()
        package.loaded["luasettings"] = { open = function(_, path)
            settings_data = settings_data or {}
            return {
                readSetting = function(_, k) return settings_data[k] end,
                saveSetting = function(_, k, v) settings_data[k] = v end,
                flush = function() end,
            }
        end }
        package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end }
        package.loaded["ui/uimanager"] = { show = function() end }
        package.loaded["ui/widget/infomessage"] = { new = function(_, t) return t end }
        package.loaded["ui/widget/container/widgetcontainer"] = { extend = function(_, t)
            t.new = function(cls, o) o = o or {}; setmetatable(o, { __index = cls }); return o end
            return t
        end }
        package.loaded["pluginloader"] = { getPluginInstance = function() return nil end }
        package.loaded["dayactivity"] = { SERIES_DAYS = 371, query = function() return { days = {}, avg_28 = 0, max = 0 } end }
        _G.__ZENOS_REGISTER_HOME_ITEM = function(id, build, opts) registered = { id = id, build = build, opts = opts }; return true end
        _G.__ZENOS_UNREGISTER_HOME_ITEM = function(id) unregistered = id end
    end)
    local function plugin()
        local ZenHeatmap = require("main")
        local p = ZenHeatmap:new{ ui = { menu = { registerToMainMenu = function() end } } }
        p:init()
        return p
    end
    it("normalises settings to their defaults", function()
        local ZenHeatmap = require("main")
        local cfg = ZenHeatmap.normalize(nil)
        assert.equals("year", cfg.range)
        assert.is_true(cfg.typical_week)
        assert.is_true(cfg.month_labels)
        assert.equals("relative", cfg.shading)
        assert.equals("m", cfg.size)
        local odd = ZenHeatmap.normalize({ range = "week", size = "xl", shading = "absolute", typical_week = false })
        assert.equals("year", odd.range)
        assert.equals("m", odd.size)
        assert.equals("absolute", odd.shading)
        assert.is_false(odd.typical_week)
    end)
    it("registers the widget on init when ZenOS is up, with the label and size", function()
        registered = nil
        plugin()
        assert.equals("zenheatmap.heatmap", registered.id)
        assert.equals("Reading heatmap", registered.opts.label)
        assert.equals("m", registered.opts.size)
        assert.is_function(registered.build)
    end)
    it("builds a widget from the builder", function()
        local p = plugin()
        local w = registered.build({ width = 600, height = 200 })
        assert.is_table(w)
        assert.equals(600, w.width)
    end)
    it("re-registers with the new size after a menu change and unregisters on close", function()
        local p = plugin()
        local items = p:menuItems()
        local height
        for _i, it_ in ipairs(items) do if it_.text_func and it_.text_func():find("Height") then height = it_ end end
        assert.is_table(height)
        for _i, opt in ipairs(height.sub_item_table) do if opt.text == "Large" then opt.callback() end end
        assert.equals("l", registered.opts.size)
        assert.equals("l", settings_data.cfg.size)
        p:onCloseWidget()
        assert.equals("zenheatmap.heatmap", unregistered)
    end)
    it("registers again on ZenOSReady", function()
        registered = nil
        local p = plugin()
        registered = nil
        p:onZenOSReady()
        assert.is_table(registered)
    end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua spec/main_spec.lua`
Expected: "module 'main' not found".

- [ ] **Step 3: Write `_meta.lua` and `main.lua`**

`zenheatmap.koplugin/_meta.lua`:

```lua
local _ = require("gettext")
return {
    name = "zenheatmap",
    fullname = _("Reading heatmap"),
    description = _([[Adds a reading heatmap widget to the ZenOS Home page: a calendar of minutes read with your typical week beside it.]]),
    version = "0.1.0",
}
```

`zenheatmap.koplugin/main.lua`:

```lua
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local DayActivity = require("dayactivity")
local Heatmap = require("heatmap")

local ZenHeatmap = WidgetContainer:extend{
    name = "zenheatmap",
    is_doc_only = false,
}

ZenHeatmap.ITEM_ID = "zenheatmap.heatmap"

local RANGES = { year = true, quarter = true, month = true }
local SIZES = { s = true, m = true, l = true }

-- Settings with every key present and valid.
function ZenHeatmap.normalize(cfg)
    cfg = type(cfg) == "table" and cfg or {}
    return {
        range = RANGES[cfg.range] and cfg.range or "year",
        typical_week = cfg.typical_week ~= false,
        month_labels = cfg.month_labels ~= false,
        shading = cfg.shading == "absolute" and "absolute" or "relative",
        size = SIZES[cfg.size] and cfg.size or "m",
    }
end

-- The statistics plugin's week start: 1 = Sunday .. 7 = Saturday, Monday by default.
local function week_start()
    local ok, PluginLoader = pcall(require, "pluginloader")
    if ok and PluginLoader and PluginLoader.getPluginInstance then
        local stats = PluginLoader:getPluginInstance("statistics")
        local v = stats and stats.settings and tonumber(stats.settings.calendar_start_day_of_week)
        if v then return v end
    end
    return 2
end

function ZenHeatmap:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/zenheatmap.lua")
    self.cfg = ZenHeatmap.normalize(self.settings:readSetting("cfg"))
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:register()
end

function ZenHeatmap:save()
    self.settings:saveSetting("cfg", self.cfg)
    self.settings:flush()
end

local function hook(name)
    local f = rawget(_G, "__ZENOS_" .. name) or rawget(_G, "__ZEN_UI_" .. name)
    return type(f) == "function" and f or nil
end

-- Register (or re-register) the Home item. Re-registering replaces the
-- builder and options and makes ZenOS rebuild Home.
function ZenHeatmap:register()
    local register = hook("REGISTER_HOME_ITEM")
    if not register then return false end
    local plugin = self
    return register(ZenHeatmap.ITEM_ID, function(ctx)
        local cfg = ZenHeatmap.normalize(plugin.cfg)
        cfg.week_start = week_start()
        local activity = DayActivity.query(DayActivity.SERIES_DAYS)
        return Heatmap.build(ctx, cfg, activity)
    end, { label = _("Reading heatmap"), size = self.cfg.size }) and true or false
end

function ZenHeatmap:onZenOSReady()
    self:register()
end
ZenHeatmap.onZenUIReady = ZenHeatmap.onZenOSReady

function ZenHeatmap:onCloseWidget()
    local unregister = hook("UNREGISTER_HOME_ITEM")
    if unregister then unregister(ZenHeatmap.ITEM_ID) end
end

function ZenHeatmap:set(key, value)
    self.cfg[key] = value
    self:save()
    self:register()
end

function ZenHeatmap:menuItems()
    local plugin = self
    local function radio(text, key, value)
        return {
            text = text, radio = true,
            checked_func = function() return plugin.cfg[key] == value end,
            callback = function() plugin:set(key, value) end,
        }
    end
    local function toggle(text, key, help)
        return {
            text = text, help_text = help,
            checked_func = function() return plugin.cfg[key] ~= false end,
            callback = function() plugin:set(key, plugin.cfg[key] == false) end,
        }
    end
    local range_names = { year = _("Year to date"), quarter = _("3 months"), month = _("Month") }
    local size_names = { s = _("Small"), m = _("Medium"), l = _("Large") }
    local items = {
        {
            text_func = function() return string.format("%s %s", _("Range:"), range_names[plugin.cfg.range]) end,
            sub_item_table = { radio(_("Year to date"), "range", "year"), radio(_("3 months"), "range", "quarter"), radio(_("Month"), "range", "month") },
        },
        toggle(_("Typical week"), "typical_week",
            _("Your average reading time on each weekday over the last 12 weeks, as a bar beside each row of the graph or under each column in Month range. The bar fills to your best weekday.")),
        toggle(_("Month labels under the graph"), "month_labels"),
        {
            text_func = function()
                return string.format("%s %s", _("Shading:"), plugin.cfg.shading == "absolute" and _("Fixed thresholds") or _("Relative to my average"))
            end,
            sub_item_table = { radio(_("Relative to my average"), "shading", "relative"), radio(_("Fixed thresholds"), "shading", "absolute") },
        },
        {
            text_func = function() return string.format("%s %s", _("Height:"), size_names[plugin.cfg.size]) end,
            help_text = _("Rows of the ZenOS Home grid the widget takes: small is two, medium three, large four."),
            sub_item_table = { radio(_("Small"), "size", "s"), radio(_("Medium"), "size", "m"), radio(_("Large"), "size", "l") },
        },
    }
    if not hook("REGISTER_HOME_ITEM") then
        table.insert(items, 1, { text = _("ZenOS is not running; the widget appears on the ZenOS Home page."), enabled = false })
    end
    return items
end

function ZenHeatmap:addToMainMenu(menu_items)
    menu_items.zenheatmap = {
        text = _("Reading heatmap"),
        sorting_hint = "more_tools",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

return ZenHeatmap
```

- [ ] **Step 4: Run the whole suite**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/spec_runner.lua`
Expected: every spec file loads and passes.

- [ ] **Step 5: Commit**

```bash
git add zenheatmap.koplugin/_meta.lua zenheatmap.koplugin/main.lua spec/main_spec.lua
git commit -m "plugin entry: settings, ZenOS registration, menu"
```

---

### Task 7: Build, CI, README, and a real run

**Files:**
- Create: `tools/build.lua`
- Create: `.github/workflows/ci.yml`
- Create: `README.md`

**Interfaces:**
- Produces: `dist/zenheatmap.koplugin.zip` with the plugin folder at its root (store-only zip written in pure Lua, so no `zip` binary is needed).

- [ ] **Step 1: Write the zip builder**

`tools/build.lua`:

```lua
-- Writes dist/zenheatmap.koplugin.zip (store method, no compression) from
-- the plugin folder. Run from the repo root: luajit tools/build.lua
local PLUGIN = "zenheatmap.koplugin"
local FILES = { "_meta.lua", "main.lua", "heatmap.lua", "dayactivity.lua" }

local crc_table = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if c % 2 == 1 then c = bit.bxor(bit.rshift(c, 1), 0xEDB88320) else c = bit.rshift(c, 1) end
    end
    crc_table[i] = c
end
local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = bit.bxor(crc_table[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
    end
    return bit.bxor(c, 0xFFFFFFFF) % 4294967296
end
local function le(n, bytes)
    local out = {}
    for _ = 1, bytes do out[#out + 1] = string.char(n % 256); n = math.floor(n / 256) end
    return table.concat(out)
end
local function slurp(path)
    local f = assert(io.open(path, "rb"), "missing " .. path)
    local s = f:read("*a"); f:close(); return s
end

local locals, centrals, offset = {}, {}, 0
local dos_time, dos_date = 0, le(0x21, 2) -- 1980-01-01, reproducible
for _i, name in ipairs(FILES) do
    local data = slurp(PLUGIN .. "/" .. name)
    local path = PLUGIN .. "/" .. name
    local crc = crc32(data)
    local header = "PK\3\4" .. le(20, 2) .. le(0, 2) .. le(0, 2) .. le(dos_time, 2) .. dos_date
        .. le(crc, 4) .. le(#data, 4) .. le(#data, 4) .. le(#path, 2) .. le(0, 2) .. path
    locals[#locals + 1] = header .. data
    centrals[#centrals + 1] = "PK\1\2" .. le(20, 2) .. le(20, 2) .. le(0, 2) .. le(0, 2) .. le(dos_time, 2) .. dos_date
        .. le(crc, 4) .. le(#data, 4) .. le(#data, 4) .. le(#path, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2)
        .. le(0, 4) .. le(offset, 4) .. path
    offset = offset + #header + #data
end
local central = table.concat(centrals)
local eocd = "PK\5\6" .. le(0, 2) .. le(0, 2) .. le(#FILES, 2) .. le(#FILES, 2) .. le(#central, 4) .. le(offset, 4) .. le(0, 2)
os.execute("mkdir -p dist")
local out = assert(io.open("dist/" .. PLUGIN .. ".zip", "wb"))
out:write(table.concat(locals) .. central .. eocd)
out:close()
print(string.format("built dist/%s.zip (%d bytes, %d files)", PLUGIN, offset + #central + #eocd, #FILES))
```

- [ ] **Step 2: Build and verify the zip with unzip**

Run: `~/squashfs-root/usr/lib/koreader/luajit tools/build.lua && unzip -tq dist/zenheatmap.koplugin.zip && unzip -l dist/zenheatmap.koplugin.zip`
Expected: "No errors detected", four entries under `zenheatmap.koplugin/`.

- [ ] **Step 3: CI**

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install LuaJIT
        run: sudo apt-get update && sudo apt-get install -y luajit
      - name: Run specs
        run: luajit tools/spec_runner.lua
      - name: Build the plugin zip
        run: luajit tools/build.lua && unzip -tq dist/zenheatmap.koplugin.zip
```

- [ ] **Step 4: README**

`README.md` covering: what it is (one paragraph), install (unzip into `koreader/plugins/`, restart, enable under Zen Settings > Home > Widgets > Reading heatmap, settings under the plugin's menu), the settings table from the spec, compatibility (ZenOS 3.0+, alias back to 2.4.0-beta2, KOReader 2026.07+), development (`luajit tools/spec_runner.lua`, `luajit tools/build.lua`), license MIT. No em dashes.

- [ ] **Step 5: Run it in the desktop KOReader**

1. Install upstream ZenOS dev (alpha16) on the desktop so the test matches what users run: in `~/Programming/zen-os`, `git worktree add /tmp/zen-dev origin/dev`, `PATH=~/Programming/zen-os-dist/tools/bin:$PATH ./build.sh` inside it, back up `~/.config/koreader/plugins/zenos.koplugin` and unzip the result there.
2. Symlink the plugin: `ln -s ~/Programming/zenos-heatmap/zenheatmap.koplugin ~/.config/koreader/plugins/zenheatmap.koplugin`.
3. Seed the statistics database from `~/Programming/zen-os-dist/tools/statistics.sqlite3.seeded` (back up the real one first).
4. Start: `cd ~/Programming/koreader && EMULATE_READER_W=1272 EMULATE_READER_H=1696 EMULATE_READER_DPI=300 ./dev/dev.sh run`.
5. Enable the widget under Zen Settings > Home > Widgets and screenshot each range with the typical week on and off (adapt `~/Programming/zen-os-dist/tools/2-zz-dev-heatmap-shots.lua` to call the plugin's `set` through `FileManager.instance.zenheatmap`).
6. Stop with `./dev/dev.sh stop`, restore the statistics database.

Expected: the widget appears in the Widgets list as "Reading heatmap", renders in all three ranges, the log has no errors mentioning `zenheatmap`.

- [ ] **Step 6: Commit and tag**

```bash
git add tools/build.lua .github/workflows/ci.yml README.md docs
git commit -m "build, CI and README"
git tag v0.1.0
```

---

## Self-review

- Spec coverage: shades and marks (Task 5), ranges without "week only" (Tasks 4 and 6), letters always shown (Task 5 paints `row_labels` and `day_labels` unconditionally), typical week track beside and upright (Tasks 4 and 5), today rule (Task 5), shading modes (Task 3 `classify`, Task 6 setting), month labels toggle (Tasks 4 and 6), outlined empties (Task 3 `paint_cell`), settings table and re-register on change (Task 6), registration on init and `ZenOSReady`, unregister on close (Task 6), data query and flush (Task 2), compatibility aliases (Task 6 `hook`), no ZenOS internals required (Tasks 2 to 6 require only KOReader modules), build zip and CI (Task 7).
- Placeholders: none; every code step carries its code.
- Names: `Heatmap.layout/preferredHeight/build/classify/weekdayShares/spanShape/spanFor/weekdayCol/SERIES_DAYS/WEEKDAY_LETTERS`, `DayActivity.query/flushPending/SERIES_DAYS`, `ZenHeatmap.normalize/ITEM_ID/register/menuItems/set/save/onZenOSReady/onCloseWidget` are used consistently across tasks.
