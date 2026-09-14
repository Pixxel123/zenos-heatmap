local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
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

-- Dotted rectangle outline from short paintRect dashes; Blitbuffer has no
-- dashed border.
local function paint_dotted_border(bb, x, y, w, h, thick, color)
    local dash = math.max(2, thick * 2)
    local step = dash * 2
    for dx = 0, w - 1, step do
        local len = math.min(dash, w - dx)
        bb:paintRect(x + dx, y, len, thick, color)
        bb:paintRect(x + dx, y + h - thick, len, thick, color)
    end
    for dy = 0, h - 1, step do
        local len = math.min(dash, h - dy)
        bb:paintRect(x, y + dy, thick, len, color)
        bb:paintRect(x + w - thick, y + dy, thick, len, color)
    end
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

return M
