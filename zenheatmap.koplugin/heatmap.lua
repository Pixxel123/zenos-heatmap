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

return M
