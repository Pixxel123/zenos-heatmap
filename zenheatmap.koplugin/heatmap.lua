local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local TextWidget = require("ui/widget/textwidget")
local _ = require("gettext")

local Screen = Device.screen

local M = {}

-- Three greys plus white. COLOR_GRAY and COLOR_LIGHT_GRAY are too close to
-- separate on e-ink at cell sizes this small.
local FILL_EDGE = Blitbuffer.COLOR_LIGHT_GRAY
local FILL_LIGHT = Blitbuffer.COLOR_GRAY
local FILL_MID = Blitbuffer.COLOR_GRAY_5
local FILL_BIG = Blitbuffer.COLOR_BLACK
local TEXT_MUTED = Blitbuffer.COLOR_GRAY_3
local FILLS = { [1] = FILL_LIGHT, [2] = FILL_MID, [3] = FILL_BIG }

local SERIES_DAYS = 371
local AVERAGE_WEEKS = 12
local WEEKDAY_LETTERS = { _("S"), _("M"), _("T"), _("W"), _("T"), _("F"), _("S") }
M.SERIES_DAYS = SERIES_DAYS
M.WEEKDAY_LETTERS = WEEKDAY_LETTERS

local function S(v) return Screen:scaleBySize(v) end

local function fmt_time(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0" .. _("m") end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return h .. _("h") .. " " .. m .. _("m") end
    return m .. _("m")
end
M.fmtTime = fmt_time

-- The flame beside the streak ships with the plugin.
local flame_icon_path
do
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("^(.*)/[^/]+$")
        local path = dir and (dir .. "/flame.svg")
        local f = path and io.open(path, "r")
        if f then f:close(); flame_icon_path = path end
    end
end

-- What a stat slot beside the graph can show. `value` and `caption` take
-- ZenOS's home stats and the `extra` table build() derives from the day
-- series. `icon` marks the streak, which carries the flame.
M.FIELDS = {
    streak = { icon = true, value = function(s) return tostring(s.streak or 0) end, caption = function() return _("day streak") end },
    period_days = { value = function(_s, x) return tostring(x.period_days or 0) end, caption = function() return _("days read") end },
    today_pages = { value = function(s) return tostring(s.today_pages or 0) end, caption = function() return _("pages today") end },
    today_duration = { value = function(s) return fmt_time(s.today_duration or 0) end, caption = function() return _("read today") end },
    week_pages = { value = function(s) return tostring(s.week_pages or 0) end, caption = function() return _("pages this week") end },
    week_duration = { value = function(s) return fmt_time(s.week_duration or 0) end, caption = function() return _("this week") end },
}

-- Same floors as ZenOS's Reading stats widget, so a short row shrinks type
-- the same way.
local MIN_VALUE_SIZE = 8
local MAX_VALUE_SIZE = 64
local function value_size_for(cfg)
    return math.max(MIN_VALUE_SIZE, math.min(MAX_VALUE_SIZE, tonumber(cfg.font_size) or 18))
end
local function faces(value_size)
    return Font:getFace("smallinfofont", S(value_size)),
        Font:getFace("smallinfofont", S(math.max(4, math.floor(value_size * 0.6))))
end
-- Height of a value with its caption drawn beneath it, as paint_stat lays them out.
local function stat_height(value_h, label_h)
    return value_h - math.floor(value_h * 0.18) + 1 + label_h
end
-- Clear space a dividing line keeps on each side of the stats.
local SEP_CLEAR = 12

-- 0 none, 1 light, 2 normal, 3 big. Relative mode compares against the
-- reader's own baseline; absolute mode is also the fallback with no history.
function M.classify(minutes, baseline, mode)
    minutes = tonumber(minutes) or 0
    if minutes <= 0 then return 0 end
    baseline = tonumber(baseline) or 0
    if mode == "relative" and baseline > 0 then
        if minutes < baseline * 0.5 then return 1 end
        if minutes <= baseline * 1.25 then return 2 end
        return 3
    end
    if minutes < 15 then return 1 end
    if minutes <= 60 then return 2 end
    return 3
end

-- Mean minutes per weekday column over the last `weeks` weeks (zero days
-- count), as a share of the busiest weekday. `days` is oldest to newest with
-- today last; columns are 0..6 from the configured week start.
function M.weekdayShares(days, today_col, weeks)
    weeks = weeks or AVERAGE_WEEKS
    local sum, count = {}, {}
    for col = 0, 6 do sum[col], count[col] = 0, 0 end
    local n = #days
    for back = 0, math.min(n - 1, weeks * 7 - 1) do
        local col = (today_col - back) % 7
        sum[col] = sum[col] + (tonumber(days[n - back].minutes) or 0)
        count[col] = count[col] + 1
    end
    local raw, max = {}, 0
    for col = 0, 6 do
        raw[col] = count[col] > 0 and sum[col] / count[col] or 0
        if raw[col] > max then max = raw[col] end
    end
    local shares = {}
    for col = 0, 6 do shares[col] = max > 0 and raw[col] / max or 0 end
    return shares, raw
end

-- Column of a weekday from the week start (both 1 = Sunday .. 7 = Saturday).
function M.weekdayCol(wday, start)
    return (wday - start) % 7
end

-- Calendar shape of a run of whole months: the weekday column of its first
-- day (from the week start), its length in days, the weeks it spans (the
-- graphs' columns, the calendar's rows) and where each month starts, for
-- the labels. Month numbers outside 1..12 roll over.
function M.spanShape(year, month_from, month_to, start)
    local first_ts = os.time{ year = year, month = month_from, day = 1, hour = 12 }
    local last_ts = os.time{ year = year, month = month_to + 1, day = 0, hour = 12 }
    local first = os.date("*t", first_ts)
    local days = math.floor((last_ts - first_ts) / 86400 + 0.5) + 1
    local first_col = M.weekdayCol(first.wday, start)
    local weeks = math.ceil((first_col + days) / 7)
    local months = {}
    for month = month_from, month_to do
        local ts = os.time{ year = year, month = month, day = 1, hour = 12 }
        months[#months + 1] = {
            day = math.floor((ts - first_ts) / 86400 + 0.5) + 1,
            label = os.date("%b", ts),
        }
    end
    return { first_col = first_col, days = days, weeks = weeks,
        start_ts = first_ts, start_date = os.date("%Y-%m-%d", first_ts), months = months }
end

-- The window a range shows, as of `now`.
function M.spanFor(range, now, start)
    if range == "year" then return M.spanShape(now.year, 1, 12, start) end
    if range == "quarter" then return M.spanShape(now.year, now.month - 2, now.month, start) end
    if range == "month" then return M.spanShape(now.year, now.month, now.month, start) end
    return nil
end

-- Empty cells are outlined rather than filled white so a library background
-- image shows through, matching home_frame_bg.
local function paint_cell(bb, x, y, w, h, level)
    if level == 0 then
        bb:paintBorder(x, y, w, h, 1, FILL_EDGE, 0)
    else
        bb:paintRect(x, y, w, h, FILLS[level])
    end
end

-- Width and height of `cols` by `rows` square cells.
local function grid_size(cell, gap, cols, rows)
    return cell * cols + gap * (cols - 1), cell * rows + gap * (rows - 1)
end

-- Width and height of `str` set in `face`, cached per face.
local function text_prober()
    local cache = {}
    return function(str, face, bold)
        local for_face = cache[face]
        if not for_face then for_face = {}; cache[face] = for_face end
        local key = (bold and "b" or "") .. tostring(str)
        local hit = for_face[key]
        if hit then return hit[1], hit[2] end
        local w = TextWidget:new{ text = str, face = face, bold = bold }
        local size = w:getSize()
        if w.free then w:free() end
        for_face[key] = { size.w or 0, size.h or 1 }
        return size.w or 0, size.h or 1
    end
end

-- A face for the row letters that fits between rows: a capital is about
-- three quarters of the font's pixel size, and Font:getFace scales the
-- size it is given by the screen's DPI. Capped at the month labels' size
-- unless a cap is given.
local ROW_FACE_MAX = 13
local function row_face_for(pitch, cap)
    local size = math.floor((pitch - S(2)) / (0.75 * S(1)))
    return Font:getFace("smallinfofont", math.max(6, math.min(cap or ROW_FACE_MAX, size)))
end

-- The calendar's column letters take the caption face.
local LETTER_FACE_SIZE = S(11)

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

-- The two stat cells beside a graph: slot 2 centred between the graph and
-- slot 3, which sits flush right; dividing lines midway between neighbours.
-- The row is wide enough once each line keeps SEP_CLEAR from the text.
local function place_row_a(m, row_w)
    m.row_w = row_w
    m.cell3_x = row_w - m.right_w
    m.cell2_x = m.cell1_w + m.cell_gap
    m.cell2_w = m.cell3_x - m.cell_gap - m.cell2_x
    m.mid_x = m.cell2_x + math.floor((m.cell2_w - m.mid_w) / 2)
    m.sep1_x = math.floor((m.cell1_w + m.mid_x) / 2)
    m.sep2_x = math.floor((m.mid_x + m.mid_w + m.cell3_x) / 2)
    if m.mid_w == 0 then m.sep1_x = math.floor((m.cell1_w + m.cell3_x) / 2) end
    local min_slack = 2 * math.max(0, 2 * S(SEP_CLEAR) - m.cell_gap)
    m.fits_w = m.mid_w == 0 or m.cell2_w - m.mid_w >= min_slack
end

-- A face that shrinks with the cells: `face_for` names the face for a
-- pitch, `by_h(text_h)` the cell the row allows beside text that tall.
-- Two passes settle a face sized for the cells that fit under it.
local function fit_face(m, gap, face_for, by_h)
    local cell = by_h(0)
    local face, h
    for _pass = 1, 2 do
        face = face_for(math.max(S(4), cell) + gap)
        h = select(2, m.probe("W", face))
        cell = by_h(h)
    end
    return face, h
end

-- Height of the month labels under a row graph, 0 with them off. They
-- stay whenever they are wanted: in the month face while it costs the
-- cells nothing, else in a face that follows the row pitch like the
-- weekday letters, so labels and cells shrink together.
local function month_labels_h(m, cfg, cell_max, gap, by_h)
    m.labels = cfg.month_labels ~= false
    if not m.labels then return 0 end
    local labels_h = S(3) + m.month_label_h
    if by_h(labels_h) < cell_max then
        local face, h = fit_face(m, gap, row_face_for, function(lh) return by_h(S(3) + lh) end)
        m.month_face, labels_h = face, S(3) + h
    end
    return labels_h
end

-- Year to date: a week-column graph of the whole year with the letters and
-- track down its left side. The grid grows into spare room; a short row
-- shrinks the cells under the month labels as far as S(3), drops the
-- labels only when the cells would have to go below that, then shrinks
-- the cells to S(4) and closes the gaps. The graph keeps the row to
-- itself: no stats sit beside or over it. Width-bound with room to
-- spare, the block centres itself in the row.
local function layout_year(m, cfg, avail_h)
    local cols = m.span.weeks
    local labels_wanted = cfg.month_labels ~= false
    m.gap = S(2)
    m.left_w = left_block_w(m)
    local graph_w = m.inner_w - m.left_w
    local by_w = math.floor((graph_w - (cols - 1) * m.gap) / cols)
    local cell_max = math.max(S(4), math.min(S(8), by_w))
    local function by_h(labels_h)
        return math.floor((avail_h - labels_h - 6 * m.gap) / 7)
    end
    local labels_h = month_labels_h(m, cfg, cell_max, m.gap, by_h)
    local function solve(lh, floor)
        m.gap = S(2)
        local room = by_h(lh)
        if room >= cell_max then
            return math.max(cell_max, math.min(S(14), by_w, room))
        end
        if room < floor then
            m.gap = S(1)
            room = by_h(lh)
        end
        return math.max(floor, math.min(cell_max, room))
    end
    -- Labelled, the cells may go as small as S(3) to keep the labels.
    m.cell = solve(labels_h, m.labels and S(3) or S(4))
    -- Only when even the smallest cells and labels overflow do the labels go.
    if m.labels and m.cell * 7 + m.gap * 6 + labels_h > avail_h then
        m.labels, labels_h = false, 0
        m.cell = solve(0, S(4))
    end
    -- Height-bound cells widen up to 2:1 so the graph still fills the row.
    m.cell_w = m.cell < math.min(S(14), by_w) and math.min(m.cell * 2, by_w) or m.cell
    m.grid_w = m.cell_w * cols + m.gap * (cols - 1)
    m.grid_h = m.cell * 7 + m.gap * 6
    -- Integer cells leave up to a column's worth of slack on the right; the
    -- columns spread across the graph's width instead.
    if m.cell_w >= S(6) and m.grid_w < graph_w and graph_w - m.grid_w <= cols * S(2) then
        m.col_span = graph_w - m.cell_w
        m.grid_w = graph_w
    end
    m.track_w = track_width(m, m.cell, m.gap)
    m.row_face = row_face_for(m.cell + m.gap)
    m.block_x = 0
    local block_h = m.grid_h + labels_h
    m.content_h = m.pad_y + block_h
    m.complete = m.cell >= cell_max and (m.labels or not labels_wanted)
    if m.complete and avail_h < math.huge then
        m.block_y = math.max(0, math.floor((avail_h - m.pad_y - block_h) / 2))
    end
end

-- Quarter and month: cells shrink from `cell_max` to `cell_min` until the
-- block fits `avail_h`; the gaps close as a last resort, to S(2) and
-- then S(1) as the year graph's do.
local function fit_block(m, avail_h, cell_max, cell_min, left_h)
    local function block_h(cell, gap)
        return math.max(left_h(cell, gap), m.stats and m.stat_h or 0)
    end
    local cell, gap = cell_max, S(4)
    while cell > cell_min and block_h(cell, gap) > avail_h do cell = cell - 1 end
    for _i, closed in ipairs({ S(2), S(1) }) do
        if block_h(cell, gap) > avail_h then gap = closed end
    end
    m.cell, m.gap = cell, gap
    m.row_a_h = block_h(cell, gap)
    m.content_h = m.pad_y + m.row_a_h
    m.complete = m.row_a_h <= avail_h
end

-- Three months: a week-column graph with the letters and track beside it.
-- The month labels shrink with the cells as in the year graph and go only
-- when even S(4) cells overflow. Without stats the graph is centred.
local function layout_quarter(m, cfg, avail_h)
    local cols = m.span.weeks
    m.left_w = left_block_w(m)
    local room_w = (m.stats and m.inner_w * 0.5 or m.inner_w) - m.left_w
    local by_w = math.floor((room_w - (cols - 1) * S(4)) / cols)
    local cell_max = math.max(S(8), math.min(S(32), by_w))
    local labels_h = month_labels_h(m, cfg, cell_max, S(4), function(lh)
        return math.floor((avail_h - lh - 6 * S(4)) / 7)
    end)
    local function graph_h(cell, gap) return cell * 7 + gap * 6 + labels_h end
    fit_block(m, avail_h, cell_max, S(4), graph_h)
    if m.labels and graph_h(m.cell, m.gap) > avail_h then
        m.labels, labels_h = false, 0
        fit_block(m, avail_h, cell_max, S(4), graph_h)
    end
    m.cell_w = math.max(m.cell, math.min(m.cell * 2, cell_max))
    m.grid_w, m.grid_h = grid_size(m.cell_w, m.gap, cols, 7)
    m.grid_h = m.cell * 7 + m.gap * 6
    m.track_w = track_width(m, m.cell_w, m.gap)
    m.row_face = row_face_for(m.cell + m.gap)
    m.cell1_w = m.left_w + m.grid_w
    if m.stats then
        m.block_x = 0
        place_row_a(m, m.inner_w)
    else
        m.block_x = math.floor((m.inner_w - m.cell1_w) / 2)
    end
end

-- Month: the weekday letters over the calendar and, with the typical week
-- on, an upright track under each letter. The calendar is centred. In a
-- short row the cells shrink as far as S(4), the tracks with them, and
-- the letters keep the caption face while it costs the cells nothing,
-- else follow the column pitch like the row letters.
local function layout_month(m, cfg, avail_h)
    local rows = m.span.weeks
    local by_w = math.floor((m.inner_w / 3 - 6 * S(4)) / 7)
    local cell_max = math.max(S(14), math.min(S(32), by_w))
    local track_rows = m.typical and 1.5 or 0
    local function track_h(cell) return math.floor(cell * track_rows) end
    local function header_h(cell)
        return m.label_h + S(3) + (m.typical and (track_h(cell) + S(4)) or 0)
    end
    local function calendar_h(cell, gap)
        return header_h(cell) + S(3) + cell * rows + gap * (rows - 1)
    end
    if calendar_h(cell_max, S(4)) > avail_h then
        local fixed = 2 * S(3) + (m.typical and S(4) or 0) + S(4) * (rows - 1)
        m.letter_face, m.label_h = fit_face(m, S(4), function(pitch) return row_face_for(pitch, LETTER_FACE_SIZE) end,
            function(lh) return math.floor((avail_h - lh - fixed) / (rows + track_rows)) end)
    end
    fit_block(m, avail_h, cell_max, S(4), calendar_h)
    m.header_h = header_h(m.cell)
    m.track_h = track_h(m.cell)
    m.grid_w, m.grid_h = grid_size(m.cell, m.gap, 7, rows)
    m.left_w, m.track_w = 0, 0
    m.cell1_w = m.grid_w
    if m.stats then
        m.block_x = 0
        place_row_a(m, m.inner_w)
    else
        m.block_x = math.floor((m.inner_w - m.grid_w) / 2)
    end
end

-- Geometry for one row at one type size. `height` is the row height to fit
-- into (nil for the natural size); `cfg` is normalised settings; `span`
-- from spanFor; `texts` carries the stat strings when two stats sit beside
-- the graph. The year graph never takes them.
local function layout(width, height, cfg, span, value_size, texts, probe)
    local m = { range = cfg.range or "year", typical = cfg.typical_week ~= false, span = span }
    m.stats = m.range ~= "year" and texts ~= nil and (texts.mid_value ~= nil or texts.right_value ~= nil)
    m.cell_gap = S(14)
    local value_face, label_face = faces(value_size)
    m.value_size, m.value_face, m.label_face = value_size, value_face, label_face
    local value_h = select(2, probe("8", value_face, true))
    local caption_h = select(2, probe("A", label_face))
    m.stat_h = stat_height(value_h, caption_h)
    local icon_w = math.max(8, math.floor(value_h * 0.62)) + S(3)
    local function stat_w(value, label, icon)
        if not (texts and value) then return 0 end
        return math.max((probe(value, value_face, true)) + (icon and icon_w or 0), (probe(label, label_face)))
    end
    m.mid_w = m.stats and stat_w(texts.mid_value, texts.mid_label, texts.mid_icon) or 0
    m.right_w = m.stats and stat_w(texts.right_value, texts.right_label, texts.right_icon) or 0
    m.fits_w = true
    m.block_y = 0
    m.pad_x = S(6)
    m.pad_y = S(6)
    m.inner_w = math.max(1, width - m.pad_x * 2)
    -- The month labels and the row letters share a small face; the
    -- calendar's column letters take the caption face.
    m.month_face = Font:getFace("smallinfofont", S(7))
    m.letter_face = Font:getFace("smallinfofont", LETTER_FACE_SIZE)
    m.probe = probe
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

-- Geometry without stats, at the configured type size.
function M.layout(width, height, cfg, span, probe)
    return layout(width, height, cfg, span, value_size_for(cfg), nil, probe or text_prober())
end

-- Geometry at one type size, with stats when `texts` is given (for tools and tests).
function M.layoutAt(width, height, cfg, span, value_size, texts, probe)
    return layout(width, height, cfg, span, value_size, texts, probe or text_prober())
end

-- With stats beside the graph, the largest type whose row fits; without
-- them the one layout there is.
function M.fitLayout(width, height, cfg, span, texts, probe)
    probe = probe or text_prober()
    local best, last
    for size = value_size_for(cfg), MIN_VALUE_SIZE, -1 do
        local m = layout(width, height, cfg, span, size, texts, probe)
        last = m
        if not m.stats then return m end
        if m.fits_h and m.fits_w then
            if m.complete then return m end
            -- Labels outrank cell size; then the larger cell wins.
            if not best or (m.labels and not best.labels)
                    or (m.labels == best.labels and (m.cell or 0) > (best.cell or 0)) then
                best = m
            end
        end
    end
    return best or last
end

function M.preferredHeight(width, cfg, span)
    return M.layout(width, nil, cfg, span).content_h
end

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

function M.build(ctx, cfg, activity, stats)
    cfg = type(cfg) == "table" and cfg or {}
    local shading = cfg.shading == "absolute" and "absolute" or "relative"
    local start = tonumber(cfg.week_start) or 2
    local range = cfg.range or "year"
    local days = activity and activity.days or {}
    local baseline = tonumber(activity and activity.avg_28) or 0
    local now = cfg.now or os.date("*t")
    local today_col = M.weekdayCol(now.wday, start)
    local shares, weekday_minutes = M.weekdayShares(days, today_col)
    -- Each track's fill takes the shade its weekday's average earns in the
    -- grid, so a heavy Saturday reads as heavy beside the graph too.
    local track_fill = {}
    for col = 0, 6 do
        track_fill[col] = FILLS[math.max(1, M.classify(weekday_minutes[col], baseline, shading))]
    end
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

    -- The window's days read, for the "days read" stat.
    local period_days = 0
    for _i, d in ipairs(days) do
        if (d.minutes or 0) > 0 and d.date and d.date >= span.start_date then period_days = period_days + 1 end
    end
    local extra = { period_days = period_days }
    local texts
    if type(stats) == "table" and range ~= "year" then
        texts = {}
        for role, id in pairs({ mid = cfg.stat_left, right = cfg.stat_right }) do
            local field = M.FIELDS[id]
            if field then
                texts[role .. "_value"] = field.value(stats, extra)
                texts[role .. "_label"] = field.caption(stats, extra)
                texts[role .. "_icon"] = flame_icon_path ~= nil and field.icon or false
            end
        end
    end

    local width, height = ctx.width, ctx.height
    local m = M.fitLayout(width, height, cfg, span, texts)

    local resources = {}
    local function text(str, face, bold, color)
        local w = TextWidget:new{ text = str, face = face, bold = bold, fgcolor = color or TEXT_MUTED }
        resources[#resources + 1] = w
        local size = w:getSize()
        return { widget = w, w = size.w or 0, h = size.h or 0 }
    end
    -- A value with its caption beneath, spaced as stat_height counts them.
    local function stat(role)
        local value = text(texts[role .. "_value"], m.value_face, true, Blitbuffer.COLOR_BLACK)
        local s = { value = value, caption = text(texts[role .. "_label"], m.label_face),
            caption_dy = value.h - math.floor(value.h * 0.18) + 1 }
        if texts[role .. "_icon"] and flame_icon_path then
            local icon_size = math.max(8, math.floor(value.h * 0.62))
            local flame = IconWidget:new{ file = flame_icon_path, width = icon_size, height = icon_size, alpha = true }
            resources[#resources + 1] = flame
            local size = flame:getSize()
            s.icon = { widget = flame, w = size.w or 0, h = size.h or 0 }
        end
        return s
    end
    local mid = m.stats and texts.mid_value and stat("mid") or nil
    local right = m.stats and texts.right_value and stat("right") or nil
    local row_labels, day_labels = {}, {}
    for col = 0, 6 do
        local letter = WEEKDAY_LETTERS[((start - 1 + col) % 7) + 1]
        row_labels[col] = text(letter, m.row_face or m.month_face)
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

    -- A graph on its own is centred in the row. A block that has centred
    -- itself (block_y) holds its row, as ZenOS's quote widget does; any
    -- other slack is ZenOS's to slide, evening out the gaps between rows.
    local held = m.block_y > 0
    local top = held and 0 or math.max(0, math.floor((height - m.content_h) / 2))
    local shift = { value = 0 }
    local cell_w = m.cell_w or m.cell
    local function col_x(col)
        if m.col_span and span.weeks > 1 then
            return math.floor(col * m.col_span / (span.weeks - 1))
        end
        return col * (cell_w + m.gap)
    end

    -- One square per day, future days outlined. Today keeps its whole shade
    -- and wears a thick black border in the gap around it, half the gap
    -- thick with a little clearance; with the gaps closed the border sits
    -- on the cell's edge instead.
    local function paint_days(bb, gx, gy, weeks_down)
        local step = m.cell + m.gap
        local ring = math.max(1, math.floor(m.gap / 2))
        local o = ring + math.max(0, math.floor((m.gap - ring) / 2))
        for k = 0, span.days - 1 do
            local slot = span.first_col + k
            local week, day = math.floor(slot / 7), slot % 7
            local x, y, w = gx + col_x(week), gy + day * step, cell_w
            if weeks_down then x, y, w = gx + day * step, gy + week * step, m.cell end
            local level = levels[k]
            if level < 0 then
                bb:paintBorder(x, y, w, m.cell, 1, FILL_EDGE, 0)
            elseif k == today_offset then
                paint_cell(bb, x, y, w, m.cell, level)
                if m.gap >= 3 then
                    bb:paintBorder(x - o, y - o, w + 2 * o, m.cell + 2 * o, ring, Blitbuffer.COLOR_BLACK, 0)
                else
                    bb:paintBorder(x, y, w, m.cell, 1, Blitbuffer.COLOR_BLACK, 0)
                end
            else
                paint_cell(bb, x, y, w, m.cell, level)
            end
        end
    end

    -- Letters down the rows in a face sized to fit them, the typical week's
    -- track filled from the left in the weekday's shade, and a hairline
    -- before the graph.
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
                if fill > 0 then bb:paintRect(tx, y, fill, m.cell, track_fill[col]) end
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
                if fill > 0 then bb:paintRect(x, ty + m.track_h - fill, m.cell, fill, track_fill[col]) end
            end
        end
    end

    -- Value with its icon, caption beneath. `align` is "left" (anchor is the
    -- left edge) or "right" (anchor is the right edge).
    local function paint_stat(bb, anchor_x, y, align, st)
        local icon_w = st.icon and (st.icon.w + S(3)) or 0
        local left = align == "right" and anchor_x - st.value.w - icon_w or anchor_x
        if st.icon then
            st.icon.widget:paintTo(bb, left, y + math.floor((st.value.h - st.icon.h) / 2))
        end
        st.value.widget:paintTo(bb, left + icon_w, y)
        local caption_x = align == "right" and anchor_x - st.caption.w or left
        st.caption.widget:paintTo(bb, caption_x, y + st.caption_dy)
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
        local oy = y + top + m.pad_y + m.block_y + shift.value
        if m.range == "month" then
            paint_header(bb, ox, oy)
            paint_days(bb, ox, oy + m.header_h + S(3), true)
        else
            paint_left(bb, ox, oy)
            paint_graph(bb, ox + m.left_w, oy)
        end
        if m.stats then
            -- Beside the graph the stats sit centred on the block's height,
            -- with dividing lines midway between neighbours.
            local stat_y = oy + math.floor((m.row_a_h - m.stat_h) / 2)
            if mid then paint_stat(bb, ox + m.mid_x, stat_y, "left", mid) end
            if right then paint_stat(bb, ox + m.row_w, stat_y, "right", right) end
            local trim = S(4)
            if mid then
                bb:paintRect(ox + m.sep1_x - 1, oy + trim, 2, m.row_a_h - trim * 2, Blitbuffer.COLOR_DARK_GRAY)
            end
            if right then
                bb:paintRect(ox + (mid and m.sep2_x or m.sep1_x) - 1, oy + trim, 2, m.row_a_h - trim * 2, Blitbuffer.COLOR_DARK_GRAY)
            end
        end
    end)

    if type(ctx.setContentBounds) == "function" then
        ctx.setContentBounds{
            top = top, bottom = held and height or top + m.content_h,
            min_shift = held and 0 or -top,
            max_shift = held and 0 or math.max(0, height - (top + m.content_h)),
            lock_shift = held or nil,
            set_shift = function(v) shift.value = held and 0 or v end,
        }
    end

    return FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, content }
end

return M
