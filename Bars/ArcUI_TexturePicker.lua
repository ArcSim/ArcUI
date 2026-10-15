-- ArcUI_TexturePicker: the bar texture picker. A texture select shows the
-- texture on a small bar and opens a window that draws every texture on a bar
-- in the bar's own colour: grouped by the addon its file comes from, searched
-- by name, with favorites and the last ones used. The texture under the mouse
-- (else the one clicked) shows on the real bar until the window closes; Use
-- texture keeps the pick, any other way out puts the old one back.

-- A select opts in with dialogControl = "ArcUI_TexturePicker", and for a live
-- preview arg = { texturePreview = fn } returning nil or { owner, refresh,
-- color, barName }. owner is what the bar's texture read hands
-- ns.API.BarTextureName; refresh restyles that bar alone, never NotifyChange,
-- since a rebuild pulls the widget out from under the window.
local ADDON, ns = ...
local AT = ns.AT
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
if not (AT and AceGUI) then return end

local COL, WHITE = AT.COL, AT.WHITE
local FONT = STANDARD_TEXT_FONT
-- roles the bundled theme copy does not carry yet
local SEL = { 0.055, 0.165, 0.227 }
local FOCUS = { 0.078, 0.353, 0.451 }
local WORD = { 0.835, 0.886, 0.949 }

local TP = { group = "all", q = "", hover = nil }
ns.TexturePicker = TP

local W, H = 720, 540
local ROW_H, ROW_BAR_H = 34, 24
local GROUP_W, GROUP_H = 210, 28
local SCROLL_W = 7
local OWN = "ArcUI"
local GREEN = { 0.482, 0.847, 0.561 }
local GREEN_EDGE = { 0.180, 0.353, 0.227 }
local BAR_BG = { 0.063, 0.078, 0.122 }
local BLACK = { 0, 0, 0 }
local CLEAR = { 0, 0, 0, 0 }
local STAR = "Interface\\Common\\ReputationStar"

local function FolderOf(path)
    if type(path) ~= "string" then return nil end
    return path:match("^[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee][\\/][Aa][Dd][Dd][Oo][Nn][Ss][\\/]([^\\/]+)")
end

local function SameFile(path)
    if type(path) ~= "string" then return tostring(path) end
    return (path:lower():gsub("/", "\\"):gsub("%.%a+$", ""))
end

local function Lower(a, b) return a.name:lower() < b.name:lower() end

-- ArcUI colours are {r=, g=, b=}; the window's own are arrays.
local function ColorOf(c)
    if type(c) ~= "table" then return 1, 1, 1 end
    local r, g, b = c.r or c[1], c.g or c[2], c.b or c[3]
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return 1, 1, 1 end
    return r, g, b
end

-- What a name draws: a list that maps names to files is taken as given, else
-- the shared media file, fetched the way the bars fetch it.
local function PathIn(list, name)
    if name == nil then return WHITE end
    local v = list and list[name]
    if type(v) == "number" or (type(v) == "string" and v ~= name) then return v end
    return (LSM and LSM:Fetch("statusbar", name)) or WHITE
end

local function SourceOf(path)
    local folder = FolderOf(path)
    return (not folder and "Game") or (folder == ADDON and OWN) or folder
end

-- Every texture the select offers once, a file already listed under another
-- name left out. Names go in A-Z, so of two names for one file the same one
-- is always kept.
function TP.Catalog(list)
    local out, names, files = {}, {}, {}
    local sorted = {}
    for name in pairs(list or {}) do
        if type(name) == "string" and name ~= "None" then sorted[#sorted + 1] = name end
    end
    table.sort(sorted, function(a, b) return a:lower() < b:lower() end)
    for _, name in ipairs(sorted) do
        local path = PathIn(list, name)
        local f = SameFile(path)
        if not (names[name] or files[f]) then
            names[name], files[f] = true, true
            local src = SourceOf(path)
            out[#out + 1] = { name = name, path = path, src = src, first = (src == "Game" or src == OWN) }
        end
    end
    return out
end

-- The texture a bar holds stays pickable even when the list left its name out
-- (another name for the same file), so it still reads In use.
function TP.Keep(items, name)
    if not name or name == "" then return end
    for _, it in ipairs(items) do if it.name == name then return end end
    -- a pack that is gone has no file to show
    local path = LSM and LSM:Fetch("statusbar", name, true)
    if not path then return end
    local src = SourceOf(path)
    items[#items + 1] = { name = name, path = path, src = src, first = (src == "Game" or src == OWN) }
end

-- Favorites, recent and the preview colour, kept account-wide.
local function UI()
    local g = (ns.db and ns.db.global) or TP
    local u = g.texturePicker or {}
    g.texturePicker = u
    u.favs = u.favs or {}
    u.recent = u.recent or {}
    return u
end

local function Ctx() return TP.ctx end

-- the bar's fill colour, or white for the texture's own art
local function Tint()
    if TP.white then return 1, 1, 1 end
    local c = Ctx()
    return ColorOf(c and c.color)
end

local function BarTint()
    local c = Ctx()
    return ColorOf(c and c.color)
end

-- One device pixel in a frame's units.
local function Px(f)
    local _, physH = GetPhysicalScreenSize()
    local s = (f and f:GetEffectiveScale()) or UIParent:GetEffectiveScale()
    if not physH or physH <= 0 or not s or s <= 0 then return 1 end
    return (768 / physH) / s
end

-- At a fractional scale a one-pixel strip can fall between two pixel columns
-- and vanish, so there a hairline is two.
local function Hairline(f)
    local px = Px(f)
    local per = 1 / px
    if math.abs(per - math.floor(per + 0.5)) < 0.01 then return px end
    return px * 2
end

-- A dark well with a black edge and a StatusBar inset a pixel, a share full.
local function MakeBar(parent, w, h, share)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    if w then f:SetSize(w, h) else f:SetHeight(h) end
    AT.Skin(f, BAR_BG, BLACK)
    local sb = CreateFrame("StatusBar", nil, f)
    sb:SetPoint("TOPLEFT", 1, -1)
    sb:SetPoint("BOTTOMRIGHT", -1, 1)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(share)
    f.sb = sb
    return f
end

local function Font(parent, size, c)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size, "")
    fs:SetWordWrap(false)
    fs:SetJustifyH("LEFT")
    c = c or COL.ink
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

-- The secondary button: the raised one's geometry, its fill and text a step
-- down until hovered so it does not compete with the main action.
local function QuietButton(parent, label, w)
    local b = AT.MakeSmallButton(parent, label, w)
    local function rest()
        b:SetBackdropColor(0, 0, 0, 0)
        b:SetBackdropBorderColor(COL.line2[1], COL.line2[2], COL.line2[3], 1)
        b.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    end
    rest()
    b:SetScript("OnEnter", function()
        b:SetBackdropColor(COL.btnHover[1], COL.btnHover[2], COL.btnHover[3], 1)
        b:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
        b.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    end)
    b:SetScript("OnLeave", rest)
    return b
end

-- A ScrollFrame with a thin track shown on overflow. The wheel and a drag on
-- a strip wider than the track both move it; the drag polls only while the
-- button is held, so a release anywhere still ends it.
local function Scroll(parent)
    local host = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, host)
    content:SetSize(1, 1)
    host:SetScrollChild(content)
    local track = CreateFrame("Frame", nil, host, "BackdropTemplate")
    track:SetWidth(SCROLL_W)
    track:SetPoint("TOPRIGHT", host, "TOPRIGHT", 2, 0)
    track:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 2, 0)
    AT.Skin(track, COL.well, COL.well)
    local thumb = track:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(WHITE)
    thumb:SetPoint("TOPLEFT", 0, 0)
    thumb:SetPoint("TOPRIGHT", 0, 0)
    track:Hide()
    local sb = { over = 0, travel = 0, th = 0 }
    local function ScrollTo(cur)
        local over = (content:GetHeight() or 0) - (host:GetHeight() or 0)
        if over <= 0 then return end
        if cur < 0 then cur = 0 elseif cur > over then cur = over end
        host:SetVerticalScroll(cur)
        host:UpdateScroll()
    end
    local function Wheel(delta)
        ScrollTo((host:GetVerticalScroll() or 0) - delta * 32)
    end
    local hit = CreateFrame("Frame", nil, track)
    hit:SetPoint("TOPLEFT", track, "TOPLEFT", -3.5, 0)
    hit:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", 3.5, 0)
    hit:EnableMouse(true)
    -- a mouse-enabled strip may swallow the wheel: hand it to the scroll
    hit:EnableMouseWheel(true)
    hit:SetScript("OnMouseWheel", function(_, d) Wheel(d) end)
    local hover, dragging, top, es, grab = false, false, 0, 1, 0
    local function PaintThumb()
        thumb:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], (hover or dragging) and 1 or 0.8)
    end
    local function Stop()
        if not dragging then return end
        dragging = false
        hit:SetScript("OnUpdate", nil)
        PaintThumb()
    end
    -- the thumb's top follows the cursor less the grab point, snapped to
    -- whole device pixels so the rows rest crisp
    local function Follow()
        if sb.over <= 0 or sb.travel <= 0 then return Stop() end
        local _, cy = GetCursorPosition()
        local px = Px(track)
        ScrollTo(math.floor((top - cy / es - grab) / sb.travel * sb.over / px + 0.5) * px)
    end
    local function Tick()
        if not IsMouseButtonDown("LeftButton") then return Stop() end
        Follow()
    end
    hit:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        es, top = track:GetEffectiveScale(), track:GetTop()
        if sb.over <= 0 or sb.travel <= 0 or not (es and es > 0 and top) then return end
        local _, cy = GetCursorPosition()
        grab = top - cy / es - sb.travel * ((host:GetVerticalScroll() or 0) / sb.over)
        dragging = true
        -- off the thumb: its middle jumps to the click and drags from there
        if grab < 0 or grab > sb.th then
            grab = sb.th / 2
            Follow()
        end
        PaintThumb()
        hit:SetScript("OnUpdate", Tick)
    end)
    hit:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then Stop() end
    end)
    hit:SetScript("OnEnter", function() hover = true; PaintThumb() end)
    hit:SetScript("OnLeave", function() hover = false; PaintThumb() end)
    hit:SetScript("OnHide", function() hover = false; Stop(); PaintThumb() end)
    PaintThumb()
    function host:UpdateScroll()
        local viewH = host:GetHeight() or 0
        local contentH = content:GetHeight() or 0
        local over = contentH - viewH
        if over <= 1 or viewH <= 0 then
            host:SetVerticalScroll(0)
            track:Hide()
            sb.over = 0
            return
        end
        track:Show()
        hit:SetFrameLevel(track:GetFrameLevel() + 1)
        local cur = math.min(host:GetVerticalScroll() or 0, over)
        if cur < 0 then cur = 0 end
        host:SetVerticalScroll(cur)
        local thumbH = math.max(20, viewH * (viewH / contentH))
        sb.over, sb.travel, sb.th = over, viewH - thumbH, thumbH
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", 0, -(viewH - thumbH) * (cur / over))
        thumb:SetPoint("TOPRIGHT", 0, -(viewH - thumbH) * (cur / over))
    end
    host:EnableMouseWheel(true)
    host:SetScript("OnMouseWheel", function(_, delta) Wheel(delta) end)
    host:SetScript("OnSizeChanged", function() host:UpdateScroll() end)
    return host, content
end

-- The lists

-- a search shown back in a FontString, its pipes kept as text
local function Shown(q) return (q:gsub("|", "||")) end

local function Filtered()
    local all, q = TP.items or {}, (TP.q or ""):lower()
    local out = {}
    if q ~= "" then
        for _, it in ipairs(TP.ordered) do
            if it.name:lower():find(q, 1, true) then out[#out + 1] = it end
        end
        return out, #out .. (#out == 1 and " match" or " matches") .. " for \"" .. Shown(TP.q) .. "\" in every group",
            "No texture has \"" .. Shown(TP.q) .. "\" in its name."
    end
    local g = TP.group
    if g == "fav" then
        local favs = UI().favs
        for _, it in ipairs(all) do if favs[it.name] then out[#out + 1] = it end end
        table.sort(out, Lower)
        return out, "Favorites", "No favorites yet: click the star on a texture to keep it here."
    elseif g == "recent" then
        local by = {}
        for _, it in ipairs(all) do by[it.name] = it end
        for _, n in ipairs(UI().recent) do if by[n] then out[#out + 1] = by[n] end end
        return out, "Recently used", "Textures you use show here."
    elseif g == "all" then
        return TP.ordered, "All " .. #TP.ordered .. " textures", ""
    end
    for _, it in ipairs(all) do if it.src == g then out[#out + 1] = it end end
    table.sort(out, Lower)
    return out, #out .. " from " .. g, ""
end

-- The window

local function Hair(parent, edge)
    local t = parent:CreateTexture(nil, "BORDER")
    t:SetColorTexture(COL.line[1], COL.line[2], COL.line[3], 1)
    local px = Hairline(parent)
    if edge == "bottom" then
        t:SetPoint("BOTTOMLEFT", 0, 0); t:SetPoint("BOTTOMRIGHT", 0, 0); t:SetHeight(px)
    elseif edge == "top" then
        t:SetPoint("TOPLEFT", 0, 0); t:SetPoint("TOPRIGHT", 0, 0); t:SetHeight(px)
    else
        t:SetPoint("TOPRIGHT", 0, 0); t:SetPoint("BOTTOMRIGHT", 0, 0); t:SetWidth(px)
    end
    return t
end

-- A two-way switch's half: lit while picked.
local function SegButton(parent, text, w)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, 26)
    AT.Skin(b, COL.well, COL.line2)
    b.fs = Font(b, 11)
    b.fs:SetPoint("CENTER", 0, 0)
    b.fs:SetText(text)
    function b:SetLit(on)
        local bg, edge, ink = COL.well, COL.line2, COL.dim
        if on then bg, edge, ink = SEL, COL.arc, COL.ink end
        self:SetBackdropColor(bg[1], bg[2], bg[3], 1)
        self:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)
        self.fs:SetTextColor(ink[1], ink[2], ink[3])
    end
    return b
end

local function GroupButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(GROUP_H)
    b.fill = b:CreateTexture(nil, "BACKGROUND")
    b.fill:SetAllPoints()
    b.fill:SetTexture(WHITE)
    b.edge = b:CreateTexture(nil, "BORDER")
    b.edge:SetTexture(WHITE)
    b.edge:SetPoint("TOPLEFT", 0, 0); b.edge:SetPoint("BOTTOMLEFT", 0, 0); b.edge:SetWidth(2)
    b:SetHighlightTexture(WHITE)
    b:GetHighlightTexture():SetVertexColor(COL.btnHover[1], COL.btnHover[2], COL.btnHover[3], 0.35)
    b.count = Font(b, 10, COL.dim)
    b.count:SetPoint("RIGHT", -8, 0)
    b.count:SetJustifyH("RIGHT")
    b.fs = Font(b, 12)
    b.fs:SetPoint("LEFT", 10, 0)
    b.fs:SetPoint("RIGHT", b.count, "LEFT", -6, 0)
    function b:SetLit(on)
        local s = on and SEL or CLEAR
        self.fill:SetVertexColor(s[1], s[2], s[3], on and 1 or 0)
        local e = on and COL.arc or CLEAR
        self.edge:SetVertexColor(e[1], e[2], e[3], on and 1 or 0)
        local c = on and COL.ink or WORD
        self.fs:SetTextColor(c[1], c[2], c[3])
    end
    return b
end

local function ListRow(parent)
    local r = CreateFrame("Button", nil, parent, "BackdropTemplate")
    r:SetHeight(ROW_H)
    AT.Skin(r, CLEAR, CLEAR)
    r.star = CreateFrame("Button", nil, r)
    r.star:SetSize(24, 24)
    r.star:SetPoint("RIGHT", -4, 0)
    r.star.t = r.star:CreateTexture(nil, "ARTWORK")
    r.star.t:SetTexture(STAR)
    r.star.t:SetTexCoord(0, 0.5, 0, 0.5)
    r.star.t:SetDesaturated(true)
    r.star.t:SetSize(16, 16)
    r.star.t:SetPoint("CENTER", 0, 0)
    r.chip = CreateFrame("Frame", nil, r, "BackdropTemplate")
    r.chip:SetSize(44, 16)
    r.chip:SetPoint("RIGHT", r.star, "LEFT", -6, 0)
    AT.Skin(r.chip, CLEAR, GREEN_EDGE)
    r.chip.fs = Font(r.chip, 9, GREEN)
    r.chip.fs:SetPoint("CENTER", 0, 0)
    r.chip.fs:SetText("In use")
    r.bar = MakeBar(r, nil, ROW_BAR_H, 0.72)
    r.bar:SetPoint("LEFT", 4, 0)
    r.bar:EnableMouse(false)
    r.name = Font(r.bar, 11, { 1, 1, 1 })
    r.name:SetShadowColor(0, 0, 0, 1)
    r.name:SetShadowOffset(1, -1)
    r.name:SetPoint("LEFT", 8, 0)
    r.name:SetPoint("RIGHT", -6, 0)
    return r
end

local function Draw()
    if not (TP.win and TP.win:IsShown()) then return end
    local list, title, empty = Filtered()
    TP.list = list
    TP.listTitle:SetText(title)
    TP.empty:SetText(empty)
    TP.empty:SetShown(#list == 0)
    -- the groups and their counts
    local favs, n = UI().favs, 0
    for _, it in ipairs(TP.items) do if favs[it.name] then n = n + 1 end end
    local recent = 0
    local seen = {}
    for _, it in ipairs(TP.items) do seen[it.name] = true end
    for _, nm in ipairs(UI().recent) do if seen[nm] then recent = recent + 1 end end
    for _, gb in ipairs(TP.groupButtons) do
        if gb.id == "fav" then gb.count:SetText(n)
        elseif gb.id == "recent" then gb.count:SetText(recent) end
        gb:SetLit(TP.q == "" and TP.group == gb.id)
    end
    TP.content:SetHeight(math.max(1, #list * ROW_H))
    TP.scroll:UpdateScroll()
end

-- Only the rows in sight exist: a pool follows the scroll.
local function DrawRows()
    if not (TP.rows and TP.footBar) then return end
    local list = TP.list or {}
    local off = TP.scroll:GetVerticalScroll() or 0
    local first = math.floor(off / ROW_H)
    local cw = TP.content:GetWidth()
    local r, g, b = Tint()
    local c = Ctx()
    local favs = UI().favs
    for i, row in ipairs(TP.rows) do
        local idx = first + i
        local it = list[idx]
        if it then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", TP.content, "TOPLEFT", 0, -(idx - 1) * ROW_H)
            row:SetWidth(cw)
            row.it = it
            row.bar.sb:SetStatusBarTexture(it.path)
            row.bar.sb:SetStatusBarColor(r, g, b, 1)
            row.name:SetText(it.name)
            local inUse = it.name == TP.orig
            row.chip:SetShown(inUse)
            row.bar:SetPoint("RIGHT", inUse and row.chip or row.star, "LEFT", -6, 0)
            local fav = favs[it.name] and true or false
            local sc = fav and COL.arc or COL.steel
            row.star.t:SetVertexColor(sc[1], sc[2], sc[3], fav and 1 or 0.6)
            local picked, hot = it.name == TP.pending, it.name == TP.hover
            local fill = picked and SEL or CLEAR
            row:SetBackdropColor(fill[1], fill[2], fill[3], picked and 1 or 0)
            local edge = (picked and COL.arc) or (hot and COL.steel) or CLEAR
            row:SetBackdropBorderColor(edge[1], edge[2], edge[3], (picked or hot) and 1 or 0)
            row:Show()
        else
            row.it = nil
            row:Hide()
        end
    end
    -- the footer: the bar in its own colour with what it would show
    local shown = TP.hover or TP.pending
    local it = shown and TP.byName and TP.byName[shown]
    TP.footBar.sb:SetStatusBarTexture(it and it.path or WHITE)
    local br, bg, bb = BarTint()
    TP.footBar.sb:SetStatusBarColor(br, bg, bb, 1)
    TP.footName:SetText(shown or "")
    TP.footLabel:SetText(c and c.barName or "")
end

-- Point the live preview at a bar, or at none; a bar it leaves is restyled
-- back to its saved texture.
local function SetPreview(owner, key, refresh)
    local was = TP.live
    if owner ~= nil and key ~= nil then
        ns.TexPreview = { owner = owner, key = key }
        TP.live = { owner = owner, refresh = refresh }
    else
        ns.TexPreview = nil
        TP.live = nil
    end
    if TP.live and refresh then refresh() end
    if was and was.refresh and not (TP.live and TP.live.owner == was.owner) then was.refresh() end
end

-- One restyle per frame however fast the mouse moves over the rows.
local function QueuePreview()
    if TP.queued then return end
    TP.queued = true
    C_Timer.After(0, function()
        TP.queued = false
        local c = Ctx()
        if not (c and c.owner ~= nil and c.refresh and TP.win and TP.win:IsShown()) then return end
        local shown = TP.hover or TP.pending
        local key = nil
        if shown ~= TP.orig then key = shown end
        if key == TP.previewKey then return end
        TP.previewKey = key
        SetPreview(c.owner, key, c.refresh)
    end)
end

local function Repaint()
    DrawRows()
    QueuePreview()
end

local function Remember(name)
    local u = UI()
    local out = { name }
    for _, n in ipairs(u.recent) do
        if n ~= name and #out < 6 then out[#out + 1] = n end
    end
    u.recent = out
end

function TP.Use()
    local c = Ctx()
    TP.used = true
    if c and TP.pending ~= nil then
        Remember(TP.pending)
        if TP.pending ~= TP.orig then c.set(TP.pending) end
    end
    TP.win:Hide()
end

function TP.Cancel()
    if TP.win then TP.win:Hide() end
end

local function Build()
    local p = AT.CreateWindow("ArcUITexturePicker", {
        w = W, h = H, minW = W, minH = H, resizable = false, title = "Bar texture",
    })
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:Hide()
    TP.win = p
    TP.sub = Font(p.titleBar, 11, COL.dim)
    TP.sub:SetPoint("LEFT", p.titleText, "RIGHT", 8, 0)

    -- search, and the colour the textures are drawn in
    local tools = CreateFrame("Frame", nil, p)
    tools:SetPoint("TOPLEFT", 1, -31)
    tools:SetPoint("TOPRIGHT", -1, -31)
    tools:SetHeight(44)
    Hair(tools, "bottom")
    local box = CreateFrame("EditBox", nil, tools, "BackdropTemplate")
    box:SetSize(300, 26)
    box:SetPoint("LEFT", 12, 0)
    AT.Skin(box, COL.well, COL.line2)
    box:SetFont(FONT, 12, "")
    box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    box:SetTextInsets(8, 8, 0, 0)
    box:SetAutoFocus(false)
    local hint = Font(box, 12, COL.faint)
    hint:SetPoint("LEFT", 8, 0)
    TP.hint = hint
    box:SetScript("OnTextChanged", function(self)
        TP.q = self:GetText() or ""
        hint:SetShown(TP.q == "")
        TP.scroll:SetVerticalScroll(0)
        Draw()
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(FOCUS[1], FOCUS[2], FOCUS[3], 1) end)
    box:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(COL.line2[1], COL.line2[2], COL.line2[3], 1) end)
    TP.box = box
    local white = SegButton(tools, "White", 64)
    white:SetPoint("RIGHT", -12, 0)
    local barc = SegButton(tools, "Bar color", 86)
    barc:SetPoint("RIGHT", white, "LEFT", 0, 0)
    local pin = Font(tools, 11, COL.dim)
    pin:SetPoint("RIGHT", barc, "LEFT", -10, 0)
    pin:SetText("Preview in")
    local function lit()
        barc:SetLit(not TP.white)
        white:SetLit(TP.white)
    end
    TP.litTint = lit
    barc:SetScript("OnClick", function() TP.white = false; UI().white = nil; lit(); DrawRows() end)
    white:SetScript("OnClick", function() TP.white = true; UI().white = true; lit(); DrawRows() end)

    -- the groups: what you keep, then one per addon the files come from
    local side = CreateFrame("Frame", nil, p, "BackdropTemplate")
    side:SetPoint("TOPLEFT", 1, -75)
    side:SetPoint("BOTTOMLEFT", 1, 49)
    side:SetWidth(GROUP_W)
    AT.Skin(side, COL.well, COL.well)
    Hair(side, "right")
    local gHost, gContent = Scroll(side)
    gHost:SetPoint("TOPLEFT", 8, -8)
    gHost:SetPoint("BOTTOMRIGHT", -8, 8)
    TP.gHost, TP.gContent = gHost, gContent
    TP.groupButtons = {}
    TP.fromLabel = Font(gContent, 10, COL.dim)
    TP.fromLabel:SetText("FROM")

    -- the list
    local main = CreateFrame("Frame", nil, p)
    main:SetPoint("TOPLEFT", side, "TOPRIGHT", 0, 0)
    main:SetPoint("BOTTOMRIGHT", -1, 49)
    TP.listTitle = Font(main, 10, COL.dim)
    TP.listTitle:SetPoint("TOPLEFT", 12, -9)
    TP.listTitle:SetPoint("TOPRIGHT", -12, -9)
    local host, content = Scroll(main)
    host:SetPoint("TOPLEFT", 10, -28)
    host:SetPoint("BOTTOMRIGHT", -12, 8)
    TP.scroll, TP.content = host, content
    TP.empty = Font(main, 11, COL.dim)
    TP.empty:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -12)
    TP.empty:SetPoint("RIGHT", host, "RIGHT", -4, 0)
    TP.empty:SetWordWrap(true)
    host:SetScript("OnSizeChanged", function(self)
        content:SetWidth(self:GetWidth())
        self:UpdateScroll()
    end)
    local up = host.UpdateScroll
    function host:UpdateScroll()
        up(self)
        DrawRows()
        -- a scroll moves new textures under a resting mouse with no enter or
        -- leave, so the row under it is asked again
        local under
        for _, row in ipairs(TP.rows or {}) do
            if row:IsVisible() and row.it and row:IsMouseOver() then under = row.it.name; break end
        end
        if under ~= TP.hover then
            TP.hover = under
            Repaint()
        end
    end
    local rows = {}
    for i = 1, math.ceil((H - 75 - 49 - 36) / ROW_H) + 2 do
        local row = ListRow(content)
        row:SetScript("OnEnter", function(self)
            if self.it then TP.hover = self.it.name; Repaint() end
        end)
        row:SetScript("OnLeave", function(self)
            if TP.hover == (self.it and self.it.name) then TP.hover = nil; Repaint() end
        end)
        row:SetScript("OnClick", function(self)
            if self.it then TP.pending = self.it.name; Repaint() end
        end)
        row.star:SetScript("OnClick", function()
            local it = row.it
            if not it then return end
            local favs = UI().favs
            favs[it.name] = (not favs[it.name]) or nil
            Draw()
        end)
        AT.Tooltip(row.star, "Favorite", "Keep this texture under Favorites.")
        rows[i] = row
    end

    -- the bar as it would look, then the way out
    local foot = CreateFrame("Frame", nil, p, "BackdropTemplate")
    foot:SetPoint("BOTTOMLEFT", 1, 1)
    foot:SetPoint("BOTTOMRIGHT", -1, 1)
    foot:SetHeight(48)
    AT.Skin(foot, COL.well, COL.well)
    Hair(foot, "top")
    TP.footLabel = Font(foot, 11, COL.dim)
    TP.footLabel:SetPoint("LEFT", 12, 0)
    local use = AT.MakeSmallButton(foot, "Use texture", 110)
    use:SetHeight(26)
    use:SetPoint("RIGHT", -12, 0)
    use:SetScript("OnClick", TP.Use)
    local cancel = QuietButton(foot, "Cancel", 80)
    cancel:SetHeight(26)
    cancel:SetPoint("RIGHT", use, "LEFT", -8, 0)
    cancel:SetScript("OnClick", TP.Cancel)
    TP.footBar = MakeBar(foot, 220, 18, 0.64)
    TP.footBar:SetPoint("LEFT", TP.footLabel, "RIGHT", 10, 0)
    TP.footName = Font(foot, 11, WORD)
    TP.footName:SetPoint("LEFT", TP.footBar, "RIGHT", 10, 0)
    TP.footName:SetPoint("RIGHT", cancel, "LEFT", -10, 0)
    -- the rows draw once everything they paint into exists
    TP.rows = rows

    -- Any way out puts the bar back unless Use texture kept the pick.
    p:HookScript("OnHide", function()
        TP.hover = nil
        TP.previewKey = nil
        SetPreview(nil)
        TP.ctx, TP.root = nil, nil
        if TP.box then TP.box:ClearFocus() end
    end)
end

-- The groups for this open: Favorites, Recent, All, then a source each.
local function LayoutGroups()
    local srcs, have = {}, {}
    for _, it in ipairs(TP.items) do
        if it.src and not have[it.src] then
            have[it.src] = true
            if it.src ~= "Game" and it.src ~= OWN then srcs[#srcs + 1] = it.src end
        end
    end
    table.sort(srcs, function(a, b) return a:lower() < b:lower() end)
    local order = { { "fav", "Favorites" }, { "recent", "Recent" }, { "all", "All" } }
    if have.Game then order[#order + 1] = { "Game", "Game", true } end
    if have[OWN] then order[#order + 1] = { OWN, OWN, true } end
    for _, s in ipairs(srcs) do order[#order + 1] = { s, s, true } end
    local y, content, fromAt = 0, TP.gContent, nil
    local w = GROUP_W - 16
    for i, g in ipairs(order) do
        if g[3] and not fromAt then
            fromAt = y + 8
            TP.fromLabel:ClearAllPoints()
            TP.fromLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -fromAt)
            y = fromAt + 18
        end
        local b = TP.groupButtons[i]
        if not b then
            b = GroupButton(content)
            TP.groupButtons[i] = b
            b:SetScript("OnClick", function(self)
                TP.group = self.id
                TP.q = ""
                TP.box:SetText("")
                TP.scroll:SetVerticalScroll(0)
                Draw()
            end)
        end
        b.id = g[1]
        b.fs:SetText(g[2])
        local count = 0
        if g[3] then
            for _, it in ipairs(TP.items) do if it.src == g[1] then count = count + 1 end end
        elseif g[1] == "all" then
            count = #TP.ordered
        end
        b.count:SetText(count)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        b:SetWidth(w)
        b:Show()
        y = y + GROUP_H + 2
    end
    TP.fromLabel:SetShown(fromAt ~= nil)
    for i = #order + 1, #TP.groupButtons do
        TP.groupButtons[i]:Hide()
        TP.groupButtons[i].id = nil
    end
    content:SetSize(w, y)
    TP.gHost:UpdateScroll()
end

-- The options window closing takes the picker with it, the old texture back.
local hookedRoots = {}

-- ctx: value (the current pick), list (the select's values), set(v), barName,
-- color, owner and refresh (the live bar, nil for none), rootFrame.
function TP.Open(ctx)
    if not TP.win then Build() end
    if TP.win:IsShown() then TP.win:Hide() end
    TP.ctx = ctx
    TP.used, TP.hover, TP.previewKey = false, nil, nil
    TP.orig = ctx.value
    TP.pending = TP.orig
    TP.white = UI().white == true
    TP.items = TP.Catalog(ctx.list)
    TP.Keep(TP.items, TP.orig)
    local firsts, rest = {}, {}
    for _, it in ipairs(TP.items) do
        if it.first then firsts[#firsts + 1] = it else rest[#rest + 1] = it end
    end
    table.sort(firsts, Lower)
    table.sort(rest, Lower)
    for _, it in ipairs(rest) do firsts[#firsts + 1] = it end
    TP.ordered = firsts
    TP.byName = {}
    for _, it in ipairs(TP.items) do TP.byName[it.name] = it end
    TP.q = ""
    TP.box:SetText("")
    TP.hint:SetText("Search all " .. #TP.ordered .. " textures")
    TP.hint:Show()
    TP.win.titleText:SetText("Bar texture")
    TP.sub:SetText(ctx.barName or "")
    TP.litTint()
    -- beside the options window, where the board drew it
    local root = ctx.rootFrame
    TP.win:ClearAllPoints()
    if root and root:IsShown() then
        TP.win:SetPoint("TOPRIGHT", root, "TOPRIGHT", -24, -92)
        TP.root = root
        if not hookedRoots[root] then
            hookedRoots[root] = true
            root:HookScript("OnHide", function(self)
                if TP.root == self then TP.Cancel() end
            end)
        end
    else
        TP.win:SetPoint("CENTER", 0, 40)
    end
    TP.win:Show()
    TP.win:Raise()
    LayoutGroups()
    -- the current pick in sight, in its group
    if TP.group ~= "all" and TP.group ~= "fav" and TP.group ~= "recent" then
        local cur = TP.byName[TP.orig]
        TP.group = (cur and cur.src) or "all"
    end
    Draw()
    local list = TP.list or {}
    for i, it in ipairs(list) do
        if it.name == TP.orig then
            local view = TP.scroll:GetHeight() or 0
            local want = (i - 1) * ROW_H - math.floor(view / 2) + ROW_H
            local over = (#list * ROW_H) - view
            if want > over then want = over end
            if want < 0 then want = 0 end
            TP.scroll:SetVerticalScroll(want)
            TP.scroll:UpdateScroll()
            break
        end
    end
    DrawRows()
end

-- The select: an AceGUI widget the options use in place of a texture
-- dropdown. Its button is a swatch of the texture on a small bar with the
-- name beside it, clicked like a colour swatch (nothing drops down); a click
-- opens the window and Use texture fires OnValueChanged so the option's own
-- set runs.

local WIDGET, WIDGET_VERSION = "ArcUI_TexturePicker", 1
local liveWidgets = setmetatable({}, { __mode = "k" })

local function PreviewFor(option)
    local arg = option and option.arg
    if type(arg) == "table" and type(arg.texturePreview) == "function" then
        return arg.texturePreview()
    end
    return nil
end

local function PreviewOf(self)
    return PreviewFor(self.userdata and self.userdata.option)
end

-- An option that now edits another bar than the window opened for (the
-- panel picked another bar) must not take this pick.
local function SameBar(option, owner)
    if owner == nil then return true end
    local pv = PreviewFor(option)
    return pv ~= nil and pv.owner == owner
end

local function Paint(self)
    local v = self.value
    self.name:SetText(v or "")
    self.swatch.sb:SetStatusBarTexture(PathIn(self.list, v))
    local opt = self.userdata and self.userdata.option
    local pv = PreviewFor(opt)
    local r, g, b = ColorOf(pv and pv.color)
    self.swatch.sb:SetStatusBarColor(r, g, b, 1)
    local c = TP.ctx
    if opt and c and c.option == opt and not SameBar(opt, c.owner) then TP.Cancel() end
end

-- The select the window opened from may have been rebuilt while it was open:
-- commit through whichever widget now shows that option, else its own set.
local function Commit(w, option, appName, value, owner)
    if not SameBar(option, owner) then return end
    local function owns(x) return x.userdata and x.userdata.option == option end
    if not owns(w) then
        w = nil
        for x in pairs(liveWidgets) do
            if owns(x) then w = x; break end
        end
    end
    if w then
        w:Fire("OnValueChanged", value)
        return
    end
    if option and type(option.set) == "function" then
        option.set({ option = option, appName = appName, type = "select" }, value)
        local reg = LibStub("AceConfigRegistry-3.0", true)
        if reg and appName then reg:NotifyChange(appName) end
    end
end

local function OpenFor(self)
    if self.disabled then return end
    local user = self.userdata or {}
    local option, appName = user.option, user.appName
    local pv = PreviewOf(self)
    local barName = pv and pv.barName
    if type(barName) == "function" then barName = barName() end
    local owner = pv and pv.owner
    TP.Open({
        value = self.value, list = self.list, option = option,
        barName = barName, color = pv and pv.color,
        owner = owner, refresh = pv and pv.refresh,
        rootFrame = user.rootframe and user.rootframe.frame,
        set = function(v) Commit(self, option, appName, v, owner) end,
    })
end

local methods = {
    OnAcquire = function(self)
        self:SetHeight(44)
        self:SetWidth(200)
        self:SetDisabled(false)
        liveWidgets[self] = true
    end,
    OnRelease = function(self)
        liveWidgets[self] = nil
        self.value, self.list = nil, nil
        self.label:SetText("")
        self.name:SetText("")
        self.frame:ClearAllPoints()
        self.frame:Hide()
    end,
    SetValue = function(self, value)
        self.value = value
        Paint(self)
    end,
    GetValue = function(self) return self.value end,
    SetList = function(self, list)
        self.list = list or (LSM and LSM:HashTable("statusbar")) or {}
    end,
    AddItem = function(self, key, value)
        self.list = self.list or {}
        self.list[key] = value
    end,
    SetLabel = function(self, text) self.label:SetText(text or "") end,
    SetText = function(self, text) self.name:SetText(text or "") end,
    SetDisabled = function(self, disabled)
        self.disabled = disabled
        self.button:SetEnabled(not disabled)
        self.button:SetAlpha(disabled and 0.5 or 1)
        if disabled then self.label:SetTextColor(0.5, 0.5, 0.5)
        else self.label:SetTextColor(1, 0.82, 0) end
    end,
    SetMultiselect = function() end,
    GetMultiselect = function() return false end,
    SetItemDisabled = function() end,
    ClearFocus = function() end,
}
methods.SetItemValue = methods.AddItem

local function Constructor()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(200, 44)
    frame:Hide()
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetPoint("TOPRIGHT", 0, 0)
    label:SetJustifyH("LEFT")
    label:SetHeight(18)
    local b = CreateFrame("Button", nil, frame)
    b:SetPoint("TOPLEFT", 0, -20)
    b:SetPoint("TOPRIGHT", 0, -20)
    b:SetHeight(20)
    local sw = MakeBar(b, 72, 16, 0.72)
    sw:SetPoint("LEFT", 0, 0)
    local fs = Font(b, 11)
    fs:SetPoint("LEFT", sw, "RIGHT", 8, 0)
    fs:SetPoint("RIGHT", 0, 0)
    local self = {
        type = WIDGET, frame = frame, label = label, button = b, swatch = sw, name = fs,
        alignoffset = 30,
    }
    for k, fn in pairs(methods) do self[k] = fn end
    frame.obj, b.obj = self, self
    b:SetScript("OnEnter", function()
        sw:SetBackdropBorderColor(FOCUS[1], FOCUS[2], FOCUS[3], 1)
        self:Fire("OnEnter")
    end)
    b:SetScript("OnLeave", function()
        sw:SetBackdropBorderColor(0, 0, 0, 1)
        self:Fire("OnLeave")
    end)
    b:SetScript("OnClick", function() OpenFor(self) end)
    -- the option's colour is only known once the options injected it, which
    -- is after SetValue and before the frame shows
    frame:SetScript("OnShow", function() Paint(self) end)
    return AceGUI:RegisterAsWidget(self)
end

AceGUI:RegisterWidgetType(WIDGET, Constructor, WIDGET_VERSION)
