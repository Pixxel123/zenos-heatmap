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
        -- three cells of 14 with 2 px gaps would be 46; the track is capped at 36
        assert.equals(36, m.track_w)
        assert.is_true(m.labels)
    end)
    it("drops the track but keeps the letters with the typical week off", function()
        local m = Heatmap.layout(1000, nil, cfg{ typical_week = false }, YEAR)
        assert.equals(11, m.left_w)
        assert.equals(0, m.track_w)
    end)
    it("fits a short row by shrinking cells and labels, dropping the labels only when nothing else fits", function()
        local tall = Heatmap.layout(1000, nil, cfg{}, YEAR)
        local short = Heatmap.layout(1000, 70, cfg{}, YEAR)
        assert.is_true(short.cell < tall.cell)
        assert.is_true(short.content_h <= 70)
        assert.is_true(short.labels)
        assert.equals(short.cell * 2, short.cell_w) -- widened to fill the row
        assert.equals(tall.cell, tall.cell_w)
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
    it("sizes the row letters to the row pitch, capped at the month labels' size", function()
        -- pitch 16 (cells of 14, gaps of 2) allows 18, capped at 13; pitch 9 allows 9
        assert.equals(13, Heatmap.layout(1000, nil, cfg{}, YEAR).row_face.size)
        assert.equals(6, Heatmap.layout(1000, 70, cfg{}, YEAR).row_face.size)
        assert.equals(13, Heatmap.layout(1000, nil, cfg{ range = "quarter" }, Q).row_face.size)
    end)
    it("puts two stats beside the quarter graph and sizes the type to fit", function()
        local texts = { mid_value = "49m", mid_label = "read today", mid_icon = false,
            right_value = "34", right_label = "day streak", right_icon = true }
        local m = Heatmap.fitLayout(1000, nil, cfg{ range = "quarter" }, Q, texts)
        assert.is_true(m.stats)
        assert.equals(18, m.value_size)
        assert.equals(988 - m.right_w, m.cell3_x)
        assert.is_true(m.grid_w < 988 / 2)
        assert.is_true(m.sep1_x - m.cell1_w >= 12 and m.mid_x - m.sep1_x >= 12)
        assert.is_true(m.cell3_x - m.sep2_x >= 12)
        -- A narrow row cannot keep the lines clear at any size; the fit ends at the floor.
        local tight = Heatmap.fitLayout(380, nil, cfg{ range = "quarter" }, Q, texts)
        assert.equals(8, tight.value_size)
        -- The year graph never takes stats.
        assert.is_false(Heatmap.fitLayout(1000, nil, cfg{}, YEAR, texts).stats)
    end)
    it("keeps the month calendar at the left when stats sit beside it", function()
        local texts = { mid_value = "49m", mid_label = "read today", mid_icon = false }
        local m = Heatmap.fitLayout(1000, nil, cfg{ range = "month" }, MONTH, texts)
        assert.is_true(m.stats)
        assert.equals(0, m.block_x)
        assert.equals(m.grid_w, m.cell1_w)
        assert.equals(0, m.right_w)
    end)
    it("reports the natural height", function()
        local m = Heatmap.layout(1000, nil, cfg{}, YEAR)
        assert.equals(m.content_h, Heatmap.preferredHeight(1000, cfg{}, YEAR))
    end)
end)

describe("heatmap paint", function()
    local Heatmap = require("heatmap")
    local NOW = { year = 2026, month = 9, day = 14, wday = 2 }   -- a Monday
    local function activity(n, minutes)
        local out = { days = {}, avg_28 = 30, max = 60 }
        for i = 1, n do out.days[i] = { date = "2026-01-01", minutes = minutes(i) } end
        return out
    end
    local function paint(cfg, act, height)
        cfg.week_start = 2; cfg.now = NOW
        local frame = Heatmap.build({ width = 1000, height = height or 300 }, cfg, act)
        local bb = H.bb()
        frame[1].paintTo(frame[1], bb, 0, 0)
        return bb, frame
    end
    it("fills each track by the weekday's share and outlines the rest", function()
        local bb = paint({ range = "year", typical_week = true }, activity(371, function(i) return (i % 7 == 0) and 60 or 30 end))
        local borders, rects = H.only(bb, "border"), H.only(bb, "rect")
        assert.is_true(#borders >= 7)
        local fills = {}
        for _i, r in ipairs(rects) do if r[6] == "gray_5" and r[4] > 0 then fills[#fills + 1] = r end end
        assert.is_true(#fills >= 7)
    end)
    it("shades each track by what its weekday's average earns in the grid", function()
        -- Weekdays average 30 against a 30 baseline (normal), weekends 60 (heavy).
        local bb = paint({ range = "year", typical_week = true }, activity(371, function(i) return (i % 7 == 0 or i % 7 == 6) and 60 or 30 end))
        local track_x = 6 + 6 + 5
        local shades = {}
        for _i, r in ipairs(H.only(bb, "rect")) do if r[2] == track_x and r[5] == 14 then shades[r[6]] = (shades[r[6]] or 0) + 1 end end
        assert.equals(5, shades.gray_5)
        assert.equals(2, shades.black)
    end)
    it("paints no track and no hairline with the typical week off", function()
        local bb = paint({ range = "year", typical_week = false }, activity(371, function() return 0 end))
        for _i, r in ipairs(H.only(bb, "rect")) do assert.is_true(r[6] ~= "gray") end
        for _i, b in ipairs(H.only(bb, "border")) do assert.is_true(b[4] ~= 36) end
    end)
    it("marks today with one thick border around the cell at every size", function()
        local function marker(bb)
            local borders, dots = {}, 0
            for _i, b in ipairs(H.only(bb, "border")) do if b[7] == "black" then borders[#borders + 1] = b end end
            for _i, r in ipairs(H.only(bb, "rect")) do if r[6] == "black" and (r[4] <= 2 or r[5] <= 2) then dots = dots + 1 end end
            return borders, dots
        end
        local borders, dots = marker(paint({ range = "year", typical_week = true }, activity(371, function() return 10 end), 70))
        assert.equals(1, #borders)
        assert.equals(0, dots)
        borders, dots = marker(paint({ range = "month", typical_week = true }, activity(371, function() return 10 end)))
        assert.equals(1, #borders)
        assert.equals(0, dots)
        assert.equals(2, borders[1][6]) -- half the S(4) gap
    end)
    it("frees its text widgets and reports bounds", function()
        local bounds
        local frame = Heatmap.build({ width = 1000, height = 300, setContentBounds = function(b) bounds = b end },
            { range = "quarter", typical_week = true, week_start = 2, now = NOW }, activity(371, function() return 0 end))
        assert.is_table(bounds)
        assert.is_true(bounds.bottom > bounds.top)
        assert.has_no.errors(function() frame[1].free() end)
    end)
    it("paints all seven letters however short the rows are", function()
        local function letters(bb)
            local n = 0
            for _i, c in ipairs(bb.calls) do if c[1] == "text" and #c[4] == 1 then n = n + 1 end end
            return n
        end
        assert.equals(7, letters(paint({ range = "year", typical_week = true }, activity(371, function() return 0 end), 70)))
        assert.equals(7, letters(paint({ range = "year", typical_week = true }, activity(371, function() return 0 end))))
        assert.equals(7, letters(paint({ range = "quarter", typical_week = false }, activity(371, function() return 0 end))))
    end)
    it("paints the stats beside the quarter graph with dividers and the flame", function()
        local stats = { today_duration = 49 * 60, streak = 34 }
        local frame = Heatmap.build({ width = 1000, height = 300 },
            { range = "quarter", typical_week = true, week_start = 2, now = NOW, stat_left = "today_duration", stat_right = "streak" },
            activity(371, function() return 10 end), stats)
        local bb = H.bb(); frame[1].paintTo(frame[1], bb, 0, 0)
        local texts, dividers, icons = {}, 0, 0
        for _i, c in ipairs(bb.calls) do
            if c[1] == "text" then texts[c[4]] = true end
            if c[1] == "rect" and c[6] == "dark_gray" and c[4] == 2 then dividers = dividers + 1 end
            if c[1] == "icon" then icons = icons + 1 end
        end
        assert.is_true(texts["49m"] and texts["read today"] and texts["34"] and texts["day streak"])
        assert.equals(2, dividers)
        assert.equals(1, icons)
    end)
    it("paints the year graph alone, with month labels, even when stats are handed in", function()
        local stats = { today_pages = 42, today_duration = 49 * 60, streak = 34 }
        local frame = Heatmap.build({ width = 1000, height = 200 },
            { range = "year", typical_week = true, week_start = 2, now = NOW, stat_left = "today_duration", stat_right = "streak" },
            activity(371, function() return 10 end), stats)
        local bb = H.bb(); frame[1].paintTo(frame[1], bb, 0, 0)
        local seen, dividers, letters = {}, 0, 0
        for _i, c in ipairs(bb.calls) do
            if c[1] == "text" then seen[c[4]] = true; if #c[4] == 1 then letters = letters + 1 end end
            if c[1] == "rect" and c[6] == "dark_gray" and c[4] == 2 then dividers = dividers + 1 end
        end
        assert.is_nil(seen["49m"]); assert.is_nil(seen["read today"]); assert.is_nil(seen["34"]); assert.is_nil(seen["day streak"])
        assert.is_true(seen["Jan"] and seen["Sep"])
        assert.equals(0, dividers)
        assert.equals(7, letters)
    end)
    it("keeps the month labels in a short year row by shrinking their face", function()
        local tall = Heatmap.layout(1000, 200, { range = "year", typical_week = true, month_labels = true }, Heatmap.spanFor("year", NOW, 2))
        local short = Heatmap.layout(1000, 60, { range = "year", typical_week = true, month_labels = true }, Heatmap.spanFor("year", NOW, 2))
        assert.is_true(tall.labels and short.labels)
        assert.is_true(short.month_face.size < tall.month_face.size)
        assert.is_true(short.content_h <= 60)
        assert.is_false(Heatmap.layout(1000, 60, { range = "year", month_labels = false }, Heatmap.spanFor("year", NOW, 2)).labels)
    end)
    it("formats durations and renders every field", function()
        assert.equals("0m", Heatmap.fmtTime(0))
        assert.equals("49m", Heatmap.fmtTime(49 * 60))
        assert.equals("1h 5m", Heatmap.fmtTime(65 * 60))
        local s, x = { today_pages = 42, today_duration = 60, streak = 3, week_pages = 7, week_duration = 120 }, { period_days = 8, period_caption = "days in Sep" }
        for id, f in pairs(Heatmap.FIELDS) do
            assert.is_string(f.value(s, x)); assert.is_string(f.caption(s, x))
            assert.equals(id == "streak", f.icon == true)
        end
        assert.equals("8", Heatmap.FIELDS.period_days.value(s, x))
    end)
    it("always asks for 371 days of history", function()
        assert.equals(371, Heatmap.SERIES_DAYS)
    end)
end)
