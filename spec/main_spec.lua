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
