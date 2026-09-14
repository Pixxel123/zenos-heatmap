require("spec_helper")
describe("day activity", function()
    local DayActivity = require("dayactivity")
    -- 2026-09-14 12:00 local time; the fake connection answers the one query
    -- with the rows given.
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
        local out = DayActivity.query(2, { open = fake_conn{ { "2020-01-01", 99 } } , now = noon })
        assert.equals(0, out.days[1].minutes + out.days[2].minutes)
    end)
end)
