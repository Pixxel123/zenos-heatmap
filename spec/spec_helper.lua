-- KOReader stubbed just enough for the renderer, plus a Blitbuffer that
-- records what was painted. Text is 6 px per character and 12 px tall in
-- every face, and S(v) == v, so geometry can be asserted by hand.
local H = {}

local function stub(name, value) package.loaded[name] = value end

stub("ffi/blitbuffer", {
    COLOR_WHITE = "white", COLOR_LIGHT_GRAY = "light_gray", COLOR_GRAY = "gray",
    COLOR_DARK_GRAY = "dark_gray", COLOR_GRAY_5 = "gray_5", COLOR_GRAY_3 = "gray_3",
    COLOR_BLACK = "black",
})
stub("device", {
    screen = {
        scaleBySize = function(_, v) return v end,
        getWidth = function() return 1000 end,
        getHeight = function() return 1300 end,
    },
})
stub("ui/font", { getFace = function(_, name, size) return { name = name, size = size } end })
stub("ui/geometry", { new = function(_, t) return t end })
stub("ui/widget/container/framecontainer", { new = function(_, t) return t end })
stub("ui/widget/textwidget", { new = function(_, t)
    t.getSize = function() return { w = #tostring(t.text) * 6, h = 12 } end
    t.paintTo = function(self, bb, x, y) bb.calls[#bb.calls + 1] = { "text", x, y, self.text } end
    t.free = function() end
    return t
end })
stub("gettext", function(s) return s end)

function H.bb()
    local bb = { calls = {} }
    function bb:paintRect(x, y, w, h, color) self.calls[#self.calls + 1] = { "rect", x, y, w, h, color } end
    function bb:paintBorder(x, y, w, h, thick, color) self.calls[#self.calls + 1] = { "border", x, y, w, h, thick, color } end
    return bb
end

-- Calls of one kind, e.g. H.only(bb, "rect").
function H.only(bb, op)
    local out = {}
    for _i, c in ipairs(bb.calls) do if c[1] == op then out[#out + 1] = c end end
    return out
end

return H
