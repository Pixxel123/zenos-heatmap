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

-- A face for the row letters that fits between rows: a capital is about
-- three quarters of the font's pixel size, and Font:getFace scales the
-- size it is given by the screen's DPI. Capped at the month labels' size.
local ROW_FACE_MAX = 13
local function row_face_for(pitch)
    local size = math.floor((pitch - S(2)) / (0.75 * S(1)))
    return Font:getFace("smallinfofont", math.max(6, math.min(ROW_FACE_MAX, size)))
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
    m.row_face = row_face_for(m.cell + m.gap)
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
    m.row_face = row_face_for(m.cell + m.gap)
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

    -- Letters down the rows in a face sized to fit them, the typical week's
    -- track filled from the left, and a hairline before the graph.
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

return M
