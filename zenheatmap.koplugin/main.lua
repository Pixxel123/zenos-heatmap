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
local SIZES = { auto = true, s = true, m = true, l = true }

-- Settings with every key present and valid.
function ZenHeatmap.normalize(cfg)
    cfg = type(cfg) == "table" and cfg or {}
    return {
        range = RANGES[cfg.range] and cfg.range or "year",
        typical_week = cfg.typical_week ~= false,
        month_labels = cfg.month_labels ~= false,
        shading = cfg.shading == "absolute" and "absolute" or "relative",
        size = SIZES[cfg.size] and cfg.size or "auto",
    }
end

-- Home rows the widget asks ZenOS for: the year graph is width-bound, so
-- two rows hold it; the wider quarter cells and the calendar want three.
function ZenHeatmap.sizeFor(cfg)
    if cfg.size and cfg.size ~= "auto" then return cfg.size end
    return cfg.range == "year" and "s" or "m"
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
    end, { label = _("Reading heatmap"), size = ZenHeatmap.sizeFor(self.cfg) }) and true or false
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
    local size_names = { auto = _("Automatic"), s = _("Small"), m = _("Medium"), l = _("Large") }
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
            help_text = _("Rows of the ZenOS Home grid the widget takes: small is two, medium three, large four. Automatic is two for the year and three for the 3-month and Month ranges."),
            sub_item_table = { radio(_("Automatic"), "size", "auto"), radio(_("Small"), "size", "s"), radio(_("Medium"), "size", "m"), radio(_("Large"), "size", "l") },
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
