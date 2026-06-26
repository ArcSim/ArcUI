---@diagnostic disable: undefined-global
local _, ns = ...
local GUI = ns.GUI
local T   = GUI.Theme

GUI.ContentBuilders = {}
GUI.PanelBuilders   = {}

function GUI:RegisterContent(id, fn) self.ContentBuilders[id] = fn end
function GUI:RegisterPanel(id, fn)   self.PanelBuilders[id]   = fn end

-- ── Scrollbar ──────────────────────────────────────────────────
-- Returns a scrollbar frame synced to scrollFrame.
-- container is the visible parent (for positioning).
function GUI:CreateScrollbar(scrollFrame, container)
    local host = container or scrollFrame

    local sb = CreateFrame("Frame", nil, host)
    sb:SetWidth(12)
    sb:SetPoint("TOPRIGHT",    host, "TOPRIGHT",    0, 0)
    sb:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)

    local track = sb:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(sb)
    track:SetColorTexture(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], 0.8)

    local thumb = CreateFrame("Button", nil, sb)
    thumb:SetWidth(8)
    local thumbTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbTex:SetAllPoints(thumb)
    thumbTex:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.5)
    thumb:SetNormalTexture(thumbTex)

    thumb:SetScript("OnEnter", function()
        thumbTex:SetVertexColor(T.accent[1], T.accent[2], T.accent[3], 0.85)
    end)
    thumb:SetScript("OnLeave", function()
        thumbTex:SetVertexColor(T.accent[1], T.accent[2], T.accent[3], 0.5)
    end)

    local dragStartY, dragStartScroll

    thumb:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" then return end
        dragStartY      = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        dragStartScroll = scrollFrame:GetVerticalScroll()
        thumb:SetScript("OnUpdate", function()
            local curY  = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local delta = dragStartY - curY
            local range = scrollFrame:GetVerticalScrollRange()
            local tH    = thumb:GetHeight()
            local sbH   = sb:GetHeight()
            local track = sbH - tH
            if track > 0 then
                local scroll = math.max(0, math.min(range, dragStartScroll + delta * (range / track)))
                scrollFrame:SetVerticalScroll(scroll)
                sb:Sync()
            end
        end)
    end)
    thumb:SetScript("OnMouseUp", function()
        thumb:SetScript("OnUpdate", nil)
    end)

    function sb:Sync()
        local contentH = scrollFrame:GetScrollChild() and scrollFrame:GetScrollChild():GetHeight() or 0
        local frameH   = scrollFrame:GetHeight() or 0
        local range    = scrollFrame:GetVerticalScrollRange() or 0
        if range <= 0 or contentH <= frameH then
            self:Hide()
            return
        end
        self:Show()
        local sbH  = self:GetHeight() or 0
        local ratio = frameH / contentH
        local tH   = math.max(20, sbH * ratio)
        thumb:SetHeight(tH)
        local pct    = scrollFrame:GetVerticalScroll() / range
        local maxTop = sbH - tH
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP",   sb, "TOP",   0, -maxTop * pct)
        thumb:SetPoint("RIGHT", sb, "RIGHT", -2, 0)
    end

    scrollFrame:SetScript("OnVerticalScroll", function(sf, value)
        sf:SetVerticalScroll(value)
        sb:Sync()
    end)

    sb:Hide()
    return sb
end

-- ── Card Mixin ─────────────────────────────────────────────────

local CardMixin = {}

function CardMixin:AddRow(widget, height, spacing)
    height  = height or (widget:GetHeight() > 0 and widget:GetHeight()) or 24
    spacing = spacing or T.paddingSmall
    widget:SetParent(self.content)
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT",  self.content, "TOPLEFT",  0, -self.currentY)
    widget:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", 0, -self.currentY)
    self.currentY = self.currentY + height + spacing
    self.content:SetHeight(self.currentY)
    self:_Resize()
    return widget
end

function CardMixin:AddLabel(text, size)
    local fs = self.content:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("TOPLEFT",  self.content, "TOPLEFT",  0, -self.currentY)
    fs:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", 0, -self.currentY)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    GUI.Font(fs, size)
    fs:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 1)
    fs:SetText(text or "")
    local h = (fs:GetStringHeight() > 0 and fs:GetStringHeight()) or (T.fontSizeNormal + 2)
    self.currentY = self.currentY + h + T.paddingSmall
    self.content:SetHeight(self.currentY)
    self:_Resize()
    return fs
end

function CardMixin:AddSeparator()
    local sep = self.content:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(T.borderSize)
    sep:SetPoint("TOPLEFT",  self.content, "TOPLEFT",  0, -(self.currentY + T.paddingSmall))
    sep:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", 0, -(self.currentY + T.paddingSmall))
    sep:SetColorTexture(T.border[1], T.border[2], T.border[3], 0.5)
    self.currentY = self.currentY + T.borderSize + T.paddingSmall * 2
    self.content:SetHeight(self.currentY)
    self:_Resize()
    return sep
end

function CardMixin:AddSpacing(n)
    self.currentY = self.currentY + (n or T.paddingMedium)
    self.content:SetHeight(self.currentY)
    self:_Resize()
end

function CardMixin:_Resize()
    self:SetHeight(self.headerH + self.currentY + T.paddingSmall * 2)
end

function CardMixin:GetNextOffset()
    return self._y + self:GetHeight() + T.paddingSmall
end

function GUI:CreateCard(parent, title, yOffset)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetPoint("TOPLEFT",  parent, "TOPLEFT",  T.paddingSmall,  -(yOffset or 0))
    card:SetPoint("RIGHT",    parent, "RIGHT",    -T.paddingSmall, 0)
    card:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = T.borderSize,
    })
    card:SetBackdropColor(T.bgLight[1], T.bgLight[2], T.bgLight[3], T.bgLight[4])
    card:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], T.border[4])
    card._y = yOffset or 0

    local hdrH = 0
    if title and title ~= "" then
        hdrH = 32
        local hdr = CreateFrame("Frame", nil, card, "BackdropTemplate")
        hdr:SetHeight(hdrH)
        hdr:SetPoint("TOPLEFT",  card, "TOPLEFT",  0, 0)
        hdr:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, 0)
        hdr:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = T.borderSize,
        })
        hdr:SetBackdropColor(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], T.bgMedium[4])
        hdr:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], T.border[4])

        local fs = hdr:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("LEFT", hdr, "LEFT", T.paddingMedium, 0)
        GUI.Font(fs, T.fontSizeLarge)
        fs:SetText(title)
        fs:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 1)
        card.titleText = fs
    end

    card.headerH  = hdrH
    card.currentY = 0

    local content = CreateFrame("Frame", nil, card)
    content:SetPoint("TOPLEFT",  card, "TOPLEFT",  T.paddingMedium,  -hdrH - T.paddingSmall)
    content:SetPoint("TOPRIGHT", card, "TOPRIGHT", -T.paddingMedium, -hdrH - T.paddingSmall)
    content:SetHeight(1)
    card.content = content

    Mixin(card, CardMixin)
    card:_Resize()
    return card
end

-- ── Row Mixin ──────────────────────────────────────────────────
-- Divides its width proportionally among child widgets.

local RowMixin = {}

function RowMixin:AddWidget(widget, pct, spacing)
    widget:SetParent(self)
    widget._wpct = pct or 0.5
    widget._wsp  = spacing or T.paddingSmall
    widget:SetHeight(self._h)
    table.insert(self._widgets, widget)
    local w = self:GetWidth()
    if w and w > 0 then
        self:GetScript("OnSizeChanged")(self, w)
    end
end

function GUI:CreateRow(parent, height)
    height = height or 24
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(height)
    row._h       = height
    row._widgets = {}
    Mixin(row, RowMixin)
    row:SetScript("OnSizeChanged", function(self, w)
        local x = 0
        local n = #self._widgets
        for i, wid in ipairs(self._widgets) do
            local sp = (i < n) and (wid._wsp or T.paddingSmall) or 0
            local ww = w * wid._wpct - sp
            wid:ClearAllPoints()
            wid:SetPoint("TOPLEFT", self, "TOPLEFT", x, 0)
            wid:SetWidth(ww)
            x = x + ww + sp
        end
    end)
    return row
end
