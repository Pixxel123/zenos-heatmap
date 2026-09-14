require("spec_helper")
describe("plugin entry", function()
    local registered, unregistered
    local settings_data
    local shown = {}
    -- ZenOS's Home store, in memory: getSettings hands out a copy, like a
    -- fresh read from disk, and saveSettings keeps one.
    local store
    local function copy(t)
        if type(t) ~= "table" then return t end
        local o = {}
        for k, v in pairs(t) do o[k] = copy(v) end
        return o
    end
    local function zen_home(enabled, two_rows)
        store = { saves = 0, settings = {
            rows = { enabled = enabled, order = { "datetime", "featured", "stats_triplet", "reading_goals", "strip", "quotes" } },
            modules = { strip = { two_rows = two_rows == true } },
        } }
        package.loaded["config/preset_store"] = {
            getSettings = function(kind) if kind ~= "home" then error("kind " .. tostring(kind)) end; return copy(store.settings) end,
            saveSettings = function(kind, data) if kind ~= "home" then error("kind " .. tostring(kind)) end; store.settings = copy(data); store.saves = store.saves + 1; return true end,
        }
        shown = {}
    end
    local function no_zen_home()
        package.loaded["config/preset_store"] = nil
    end
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
        package.loaded["ui/uimanager"] = { show = function(_, w) shown[#shown + 1] = w end }
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
        assert.equals("auto", cfg.size)
        assert.equals("today_duration", cfg.stat_left)
        assert.equals("streak", cfg.stat_right)
        assert.equals("none", ZenHeatmap.normalize({ stat_left = "none", stat_right = "bogus" }).stat_left)
        assert.equals("streak", ZenHeatmap.normalize({ stat_left = "none", stat_right = "bogus" }).stat_right)
        local odd = ZenHeatmap.normalize({ range = "week", size = "xl", shading = "absolute", typical_week = false })
        assert.equals("year", odd.range)
        assert.equals("auto", odd.size)
        assert.equals("absolute", odd.shading)
        assert.is_false(odd.typical_week)
    end)
    it("registers the widget on init when ZenOS is up, with the label and size", function()
        registered = nil
        plugin()
        assert.equals("zenheatmap.heatmap", registered.id)
        assert.equals("Reading heatmap", registered.opts.label)
        assert.equals("s", registered.opts.size)
        assert.is_function(registered.build)
        assert.is_function(registered.opts.settings)
        assert.is_true(#registered.opts.settings() >= 5)
    end)
    it("builds a widget from the builder", function()
        plugin()
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
        local beside
        for _i, it_ in ipairs(items) do if it_.text == "Stats beside the graph" then beside = it_ end end
        assert.is_table(beside)
        assert.is_false(beside.enabled_func())
        assert.equals("Left stat: Time today", beside.sub_item_table[1].text_func())
        for _i, opt in ipairs(height.sub_item_table) do if opt.text == "Large" then opt.callback() end end
        assert.equals("l", registered.opts.size)
        assert.equals("l", settings_data.cfg.size)
        p:onCloseWidget()
        assert.equals("zenheatmap.heatmap", unregistered)
    end)
    it("picks the height from the range unless overridden", function()
        local ZenHeatmap = require("main")
        assert.equals("s", ZenHeatmap.sizeFor({ range = "year", size = "auto", year_stats = true }))
        assert.equals("xs", ZenHeatmap.sizeFor({ range = "year", size = "auto", year_stats = false }))
        assert.is_true(ZenHeatmap.normalize(nil).year_stats)
        assert.same({ "today_pages", "today_duration", "streak" }, ZenHeatmap.zenStatFields())
        assert.equals(18, ZenHeatmap.zenStatFont())
        zen_home({ featured = true }, false)
        store.settings.modules.stats_triplet = { automatic_font_size = false, font_size = 12 }
        assert.equals(12, ZenHeatmap.zenStatFont())
        store.settings.modules.stats_triplet = { automatic_font_size = true, max_font_size = 14 }
        assert.equals(14, ZenHeatmap.zenStatFont())
        store.settings.middle_stats_triplet = { "week_pages", "bogus", "streak" }
        assert.same({ "week_pages", "streak" }, ZenHeatmap.zenStatFields())
        no_zen_home()
        assert.equals("s", ZenHeatmap.sizeFor({ range = "quarter", size = "auto" }))
        assert.equals("s", ZenHeatmap.sizeFor({ range = "month", size = "auto" }))
        assert.equals("xs", ZenHeatmap.normalize({ size = "xs" }).size)
        assert.equals("l", ZenHeatmap.sizeFor({ range = "year", size = "l" }))
    end)
    it("offers no Home switch without ZenOS's store", function()
        no_zen_home()
        local ZenHeatmap = require("main")
        assert.is_nil(ZenHeatmap.homeEnabled())
        local p = plugin()
        assert.is_false(p:setHomeEnabled(true))
        for _i, it_ in ipairs(p:menuItems()) do assert.is_true(it_.text ~= "Show on Home") end
    end)
    it("switches the widget on in ZenOS's Home layout, below the stats row, and rebuilds Home", function()
        zen_home({ featured = true, stats_triplet = true, strip = true }, false)
        local ZenHeatmap = require("main")
        local p = plugin()
        assert.is_false(ZenHeatmap.homeEnabled())
        registered = nil
        assert.is_true(p:setHomeEnabled(true))
        assert.is_true(store.settings.rows.enabled["zenheatmap.heatmap"])
        assert.same({ "datetime", "featured", "stats_triplet", "zenheatmap.heatmap", "reading_goals", "strip", "quotes" }, store.settings.rows.order)
        assert.is_true(store.settings.modules.strip.two_rows == false)
        assert.equals(1, store.saves)
        assert.is_table(registered)
        assert.is_true(ZenHeatmap.homeEnabled())
        assert.equals(0, #shown)
        -- and off again, without touching the order
        assert.is_true(p:setHomeEnabled(false))
        assert.is_false(store.settings.rows.enabled["zenheatmap.heatmap"])
        assert.equals(7, #store.settings.rows.order)
    end)
    it("stays quiet when Home goes over its budget and ZenOS shrinks the rest", function()
        zen_home({ featured = true, stats_triplet = true, strip = true }, true)
        local p = plugin()
        assert.is_true(p:setHomeEnabled(true))
        assert.is_true(store.settings.rows.enabled["zenheatmap.heatmap"])
        assert.equals(0, #shown)
    end)
    it("keeps the last Home widget", function()
        zen_home({ ["zenheatmap.heatmap"] = true }, false)
        local p = plugin()
        assert.is_false(p:setHomeEnabled(false))
        assert.is_true(store.settings.rows.enabled["zenheatmap.heatmap"])
        assert.equals(0, store.saves)
        assert.equals(1, #shown)
    end)
    it("puts Show on Home first in the menu, checked from the live layout", function()
        zen_home({ featured = true }, false)
        local p = plugin()
        local first = p:menuItems()[1]
        assert.equals("Show on Home", first.text)
        assert.is_false(first.checked_func())
        first.callback()
        assert.is_true(first.checked_func())
        first.callback()
        assert.is_false(first.checked_func())
    end)
    it("registers again on ZenOSReady", function()
        registered = nil
        local p = plugin()
        registered = nil
        p:onZenOSReady()
        assert.is_table(registered)
    end)
end)
