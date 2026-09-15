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
local SIZES = { auto = true, xs = true, s = true, m = true, l = true }
local STATS = { today_pages = true, today_duration = true, streak = true, week_pages = true, week_duration = true, period_days = true, none = true }

-- Settings with every key present and valid.
function ZenHeatmap.normalize(cfg)
    cfg = type(cfg) == "table" and cfg or {}
    return {
        range = RANGES[cfg.range] and cfg.range or "year",
        typical_week = cfg.typical_week ~= false,
        month_labels = cfg.month_labels ~= false,
        shading = cfg.shading == "absolute" and "absolute" or "relative",
        size = SIZES[cfg.size] and cfg.size or "auto",
        stat_left = STATS[cfg.stat_left] and cfg.stat_left or "today_duration",
        stat_right = STATS[cfg.stat_right] and cfg.stat_right or "streak",
        year_stats = cfg.year_stats ~= false,
    }
end

-- Home rows the widget asks ZenOS for: the year graph alone is width-bound
-- and fits one row; with ZenOS's stats over it, and for the taller quarter
-- cells and the calendar, two.
function ZenHeatmap.sizeFor(cfg)
    if cfg.size and cfg.size ~= "auto" then return cfg.size end
    return (cfg.range == "year" and cfg.year_stats == false) and "xs" or "s"
end

-- ZenOS's Home layout, when its store can be read.
local function zen_home_layout()
    local ok, PresetStore = pcall(require, "config/preset_store")
    if not (ok and type(PresetStore) == "table" and type(PresetStore.getSettings) == "function") then return nil end
    local ok2, dcfg = pcall(PresetStore.getSettings, "home")
    return ok2 and type(dcfg) == "table" and dcfg or nil
end

-- The type size of ZenOS's Reading stats widget: its fixed size, or its
-- maximum when it sizes itself; the stats here start from the same size
-- and step down only when the graph needs the room. ZenOS's defaults
-- (16 fixed, 18 automatic) when nothing is set.
function ZenHeatmap.zenStatFont()
    local dcfg = zen_home_layout()
    local mcfg = dcfg and type(dcfg.modules) == "table" and dcfg.modules.stats_triplet
    mcfg = type(mcfg) == "table" and mcfg or {}
    local size = mcfg.automatic_font_size ~= false and (tonumber(mcfg.max_font_size) or 18)
        or (tonumber(mcfg.font_size) or 16)
    return math.max(8, math.min(64, size))
end

-- The three fields ZenOS shows in its Reading stats widget, from its Home
-- layout; its defaults when that cannot be read.
local ZEN_TRIPLET = { "today_pages", "today_duration", "streak" }
function ZenHeatmap.zenStatFields()
    local dcfg = zen_home_layout()
    local triplet = dcfg and dcfg.middle_stats_triplet
    local out = {}
    for _i, id in ipairs(type(triplet) == "table" and triplet or {}) do
        if Heatmap.FIELDS[id] then out[#out + 1] = id end
    end
    return #out > 0 and out or ZEN_TRIPLET
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

-- The numbers beside the graph come from ZenOS's own home stats, so they
-- match its Reading stats widget; without ZenOS's module there are none.
local function home_stats(cfg)
    if cfg.range == "year" then
        if not cfg.year_stats then return nil end
    elseif cfg.stat_left == "none" and cfg.stat_right == "none" then
        return nil
    end
    local ok, StatsDB = pcall(require, "common/db_stats")
    if not (ok and type(StatsDB) == "table" and type(StatsDB.queryHomeStats) == "function") then return nil end
    local ok2, stats = pcall(StatsDB.queryHomeStats, { "today_pages", "today_duration", "streak", "week_pages", "week_duration" })
    return ok2 and type(stats) == "table" and stats or nil
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

-- ZenOS's Home settings store, once ZenOS is loaded.
local function preset_store()
    local ok, PresetStore = pcall(require, "config/preset_store")
    if ok and type(PresetStore) == "table" and type(PresetStore.getSettings) == "function"
            and type(PresetStore.saveSettings) == "function" then
        return PresetStore
    end
end

-- The live Home layout with its row tables present.
local function home_layout(store)
    local ok, dcfg = pcall(store.getSettings, "home")
    if not ok or type(dcfg) ~= "table" then return nil end
    dcfg.rows = type(dcfg.rows) == "table" and dcfg.rows or {}
    dcfg.rows.enabled = type(dcfg.rows.enabled) == "table" and dcfg.rows.enabled or {}
    dcfg.rows.order = type(dcfg.rows.order) == "table" and dcfg.rows.order or {}
    return dcfg
end

-- Whether ZenOS's Home layout has the widget switched on; nil without ZenOS.
function ZenHeatmap.homeEnabled()
    local store = preset_store()
    local dcfg = store and home_layout(store)
    if not dcfg then return nil end
    return dcfg.rows.enabled[ZenHeatmap.ITEM_ID] == true
end

local function notify(text)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text })
end

-- Switch the widget on or off in ZenOS's Home layout. ZenOS's Widgets list
-- refuses a widget that would take Home past its size budget, but Home
-- itself lays out an over-full page by shrinking the widgets that can
-- shrink, so writing the layout directly lets the heatmap in regardless.
function ZenHeatmap:setHomeEnabled(on)
    local store = preset_store()
    local dcfg = store and home_layout(store)
    if not dcfg then return false end
    local rows = dcfg.rows
    if on then
        rows.enabled[ZenHeatmap.ITEM_ID] = true
        local present = false
        for _i, id in ipairs(rows.order) do
            if id == ZenHeatmap.ITEM_ID then present = true end
        end
        if not present then
            -- Below the Reading stats row, where ZenOS's own stats sit.
            local order, placed = {}, false
            for _i, id in ipairs(rows.order) do
                order[#order + 1] = id
                if id == "stats_triplet" then
                    order[#order + 1] = ZenHeatmap.ITEM_ID
                    placed = true
                end
            end
            if not placed then order[#order + 1] = ZenHeatmap.ITEM_ID end
            rows.order = order
        end
    else
        local others = 0
        for id, value in pairs(rows.enabled) do
            if value == true and id ~= ZenHeatmap.ITEM_ID then others = others + 1 end
        end
        if others == 0 then
            notify(_("Home keeps at least one widget: switch another one on first."))
            return false
        end
        rows.enabled[ZenHeatmap.ITEM_ID] = false
    end
    if not pcall(store.saveSettings, "home", dcfg) then return false end
    self:register()
    return true
end

-- ZenOS's Widgets list refuses a widget once the units it counts pass
-- Home's budget, though Home itself lays out an over-full page by
-- shrinking what can shrink. So this item asks ZenOS's registry to count
-- it as 0 units in that sum: it never blocks another widget, or itself,
-- from being switched on there, and Home still gives it its row, since
-- the layout works from the registered size class. Nothing in ZenOS is
-- changed on disk; should the registry ever look different, this does
-- nothing and the list behaves as stock.
function ZenHeatmap.shieldBudget()
    local ok, Registry = pcall(require, "modules/filebrowser/patches/home/components/registry")
    if not (ok and type(Registry) == "table") then return false end
    if Registry.__zenheatmap_shield then return true end
    if type(Registry.sizeUnits) ~= "function" or type(Registry.baseSizeUnits) ~= "function" then return false end
    local size_units, size_label = Registry.sizeUnits, Registry.sizeLabel
    local function ours(component) return type(component) == "table" and component.id == ZenHeatmap.ITEM_ID end
    Registry.sizeUnits = function(component, module_cfg)
        if ours(component) then return 0 end
        return size_units(component, module_cfg)
    end
    if type(size_label) == "function" then
        Registry.sizeLabel = function(component, module_cfg)
            if ours(component) then
                local class = type(Registry.sizeClass) == "function" and Registry.sizeClass(component)
                return class and class:upper() or tostring(Registry.baseSizeUnits(component))
            end
            return size_label(component, module_cfg)
        end
    end
    Registry.__zenheatmap_shield = true
    return true
end

-- Register (or re-register) the Home item. Re-registering replaces the
-- builder and options and makes ZenOS rebuild Home.
function ZenHeatmap:register()
    local register = hook("REGISTER_HOME_ITEM")
    if not register then return false end
    ZenHeatmap.shieldBudget()
    local plugin = self
    return register(ZenHeatmap.ITEM_ID, function(ctx)
        local cfg = ZenHeatmap.normalize(plugin.cfg)
        cfg.week_start = week_start()
        cfg.font_size = ZenHeatmap.zenStatFont()
        if cfg.range == "year" and cfg.year_stats then cfg.stat_fields = ZenHeatmap.zenStatFields() end
        local activity = DayActivity.query(DayActivity.SERIES_DAYS)
        return Heatmap.build(ctx, cfg, activity, home_stats(cfg))
    end, {
        label = _("Reading heatmap"),
        size = ZenHeatmap.sizeFor(self.cfg),
        -- ZenOS versions with a settings hook for external items open these
        -- from the Widgets list and Home's edit mode; older ones ignore it.
        settings = function() return plugin:menuItems() end,
    }) and true or false
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
    local stat_names = { today_pages = _("Pages today"), today_duration = _("Time today"), streak = _("Day streak"),
        week_pages = _("Pages this week"), week_duration = _("Time this week"), period_days = _("Days read"), none = _("None") }
    local stat_order = { "today_pages", "today_duration", "streak", "week_pages", "week_duration", "period_days", "none" }
    local function stat_menu(text, key)
        local options = {}
        for _i, id in ipairs(stat_order) do options[#options + 1] = radio(stat_names[id], key, id) end
        return {
            text_func = function() return string.format("%s %s", text, stat_names[plugin.cfg[key]]) end,
            sub_item_table = options,
        }
    end
    local size_names = { auto = _("Automatic"), xs = _("Extra small"), s = _("Small"), m = _("Medium"), l = _("Large") }
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
        toggle(_("ZenOS stats above the year graph"), "year_stats",
            _("The three numbers of ZenOS's Reading stats widget in a row over the year graph, so the widget can stand in for that row. The year then takes two Home rows in automatic height.")),
        {
            text = _("Stats beside the graph"),
            help_text = _("In the 3-month and Month ranges two of ZenOS's reading stats sit beside the graph."),
            enabled_func = function() return plugin.cfg.range ~= "year" end,
            sub_item_table = { stat_menu(_("Left stat:"), "stat_left"), stat_menu(_("Right stat:"), "stat_right") },
        },
        {
            text_func = function() return string.format("%s %s", _("Height:"), size_names[plugin.cfg.size]) end,
            help_text = _("Rows of the ZenOS Home grid the widget takes: extra small is one, small two, medium three, large four. Automatic is two, or one for the year graph without ZenOS's stats over it."),
            sub_item_table = { radio(_("Automatic"), "size", "auto"), radio(_("Extra small"), "size", "xs"), radio(_("Small"), "size", "s"), radio(_("Medium"), "size", "m"), radio(_("Large"), "size", "l") },
        },
    }
    if ZenHeatmap.homeEnabled() ~= nil then
        table.insert(items, 1, {
            text = _("Show on Home"),
            help_text = _("Puts the widget on the ZenOS Home page. It does not count against Home's size budget: when Home is full, ZenOS shrinks the other widgets a little to make room. Move it in Home's edit mode or under Zen Settings > Home > Widgets."),
            checked_func = function() return ZenHeatmap.homeEnabled() == true end,
            callback = function() plugin:setHomeEnabled(ZenHeatmap.homeEnabled() ~= true) end,
            separator = true,
        })
    end
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
