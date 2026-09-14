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

-- { days = { { date, minutes }, ... } (oldest first, ending today), avg_28, max }
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
    -- Baseline: the mean over the last 28 days that had any reading.
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
