-- Writes dist/zenheatmap.koplugin.zip (store method, no compression) from
-- the plugin folder. Run from the repo root: luajit tools/build.lua
local PLUGIN = "zenheatmap.koplugin"
local FILES = { "_meta.lua", "main.lua", "heatmap.lua", "dayactivity.lua", "flame.svg" }

local crc_table = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if c % 2 == 1 then c = bit.bxor(bit.rshift(c, 1), 0xEDB88320) else c = bit.rshift(c, 1) end
    end
    crc_table[i] = c
end
local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = bit.bxor(crc_table[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
    end
    return bit.bxor(c, 0xFFFFFFFF) % 4294967296
end
local function le(n, bytes)
    local out = {}
    for _ = 1, bytes do out[#out + 1] = string.char(n % 256); n = math.floor(n / 256) end
    return table.concat(out)
end
local function slurp(path)
    local f = assert(io.open(path, "rb"), "missing " .. path)
    local s = f:read("*a"); f:close(); return s
end

local locals, centrals, offset = {}, {}, 0
local dos_time, dos_date = 0, le(0x21, 2) -- 1980-01-01, reproducible
for _i, name in ipairs(FILES) do
    local data = slurp(PLUGIN .. "/" .. name)
    local path = PLUGIN .. "/" .. name
    local crc = crc32(data)
    local header = "PK\3\4" .. le(20, 2) .. le(0, 2) .. le(0, 2) .. le(dos_time, 2) .. dos_date
        .. le(crc, 4) .. le(#data, 4) .. le(#data, 4) .. le(#path, 2) .. le(0, 2) .. path
    locals[#locals + 1] = header .. data
    centrals[#centrals + 1] = "PK\1\2" .. le(20, 2) .. le(20, 2) .. le(0, 2) .. le(0, 2) .. le(dos_time, 2) .. dos_date
        .. le(crc, 4) .. le(#data, 4) .. le(#data, 4) .. le(#path, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2)
        .. le(0, 4) .. le(offset, 4) .. path
    offset = offset + #header + #data
end
local central = table.concat(centrals)
local eocd = "PK\5\6" .. le(0, 2) .. le(0, 2) .. le(#FILES, 2) .. le(#FILES, 2) .. le(#central, 4) .. le(offset, 4) .. le(0, 2)
os.execute("mkdir -p dist")
local out = assert(io.open("dist/" .. PLUGIN .. ".zip", "wb"))
out:write(table.concat(locals) .. central .. eocd)
out:close()
print(string.format("built dist/%s.zip (%d bytes, %d files)", PLUGIN, offset + #central + #eocd, #FILES))
