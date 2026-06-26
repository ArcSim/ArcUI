---@diagnostic disable: undefined-global
local _, ns = ...
local GUI = ns.GUI
local T   = GUI.Theme

GUI.Frame = GUI.Frame or {}
local GF  = GUI.Frame

GF._sidebarSections = GF._sidebarSections or {}
GF._expanded        = GF._expanded        or {}

-- Register a sidebar section with child items.
-- items: array of { id = string, label = string }
function GF:AddSection(id, label, items)
    table.insert(self._sidebarSections, { id = id, label = label, items = items or {} })
    if self._expanded[id] == nil then
        self._expanded[id] = true
    end
end

function GF:CreateSidebar(parent)
    local sb = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    sb:SetWidth(T.sidebarWidth)
    sb:SetPoint("TOPLEFT",    parent, "TOPLEFT",    0, -T.headerHeight)
    sb:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, T.footerHeight)
    sb:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    sb:SetBackdropColor(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], T.bgMedium[4])

    -- Right border line
    local border = sb:CreateTexture(nil, "OVERLAY")
    border:SetWidth(T.borderSize)
    border:SetPoint("TOPRIGHT",    sb, "TOPRIGHT",    0, 0)
    border:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
    border:SetColorTexture(T.border[1], T.border[2], T.border[3], T.border[4])

    local sf = CreateFrame("ScrollFrame", nil, sb)
    sf:SetPoint("TOPLEFT",     sb, "TOPLEFT",     0, 0)
    sf:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", -12, 0)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(T.sidebarWidth)  -- placeholder; OnSizeChanged corrects it
    sc:SetHeight(1)
    sf:SetScrollChild(sc)
    sf:SetScript("OnSizeChanged", function(s, w) sc:SetWidth(w) end)

    sf:EnableMouseWheel(true)
    local scrollbar = GUI:CreateScrollbar(sf, sb)
    sf:SetScript("OnMouseWheel", function(_, delta)
        local cur = sf:GetVerticalScroll()
        local max = sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(max, cur - delta * T.itemHeight)))
        scrollbar:Sync()
    end)

    sb._sf        = sf
    sb._sc        = sc
    sb._scrollbar = scrollbar
    self.sidebar  = sb
    return sb
end

function GF:RefreshSidebar()
    if not self.sidebar then return end
    local sc = self.sidebar._sc
    if not sc then return end

    -- Clear existing children
    for _, child in ipairs({ sc:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ sc:GetRegions() }) do
        region:Hide()
    end

    local y = T.paddingSmall

    for _, section in ipairs(self._sidebarSections) do
        local expanded = self._expanded[section.id]

        -- Section header
        local hdrBtn = CreateFrame("Button", nil, sc, "BackdropTemplate")
        hdrBtn:SetHeight(T.sectionHeight)
        hdrBtn:SetPoint("TOPLEFT",  sc, "TOPLEFT",  0, -y)
        hdrBtn:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, -y)
        hdrBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
        hdrBtn:SetBackdropColor(0, 0, 0, 0)

        -- Left accent bar
        local accentBar = hdrBtn:CreateTexture(nil, "ARTWORK")
        accentBar:SetWidth(3)
        accentBar:SetPoint("TOPLEFT",    hdrBtn, "TOPLEFT",    0, 0)
        accentBar:SetPoint("BOTTOMLEFT", hdrBtn, "BOTTOMLEFT", 0, 0)
        accentBar:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.8)

        -- Expand/collapse arrow
        local arrowFS = hdrBtn:CreateFontString(nil, "OVERLAY")
        arrowFS:SetPoint("RIGHT", hdrBtn, "RIGHT", -T.paddingSmall, 0)
        GUI.Font(arrowFS, T.fontSizeSmall)
        arrowFS:SetText(expanded and "▼" or "▶")
        arrowFS:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 0.8)

        local hdrFS = hdrBtn:CreateFontString(nil, "OVERLAY")
        hdrFS:SetPoint("LEFT",  hdrBtn, "LEFT",   T.paddingMedium, 0)
        hdrFS:SetPoint("RIGHT", arrowFS, "LEFT",  -T.paddingSmall, 0)
        hdrFS:SetJustifyH("LEFT")
        GUI.Font(hdrFS, T.fontSizeLarge)
        hdrFS:SetText(section.label)
        hdrFS:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 1)

        y = y + T.sectionHeight

        hdrBtn:SetScript("OnEnter", function()
            hdrBtn:SetBackdropColor(T.accentHover[1], T.accentHover[2], T.accentHover[3], T.accentHover[4])
        end)
        hdrBtn:SetScript("OnLeave", function()
            hdrBtn:SetBackdropColor(0, 0, 0, 0)
        end)
        hdrBtn:SetScript("OnClick", function()
            self._expanded[section.id] = not self._expanded[section.id]
            self:RefreshSidebar()
        end)

        if expanded then
            for _, item in ipairs(section.items) do
                local itemBtn = CreateFrame("Button", nil, sc, "BackdropTemplate")
                itemBtn:SetHeight(T.itemHeight)
                itemBtn:SetPoint("TOPLEFT",  sc, "TOPLEFT",  0, -y)
                itemBtn:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, -y)
                itemBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })

                local selBar = itemBtn:CreateTexture(nil, "ARTWORK")
                selBar:SetWidth(3)
                selBar:SetPoint("TOPLEFT",    itemBtn, "TOPLEFT",    0, 0)
                selBar:SetPoint("BOTTOMLEFT", itemBtn, "BOTTOMLEFT", 0, 0)

                local itemFS = itemBtn:CreateFontString(nil, "OVERLAY")
                itemFS:SetPoint("LEFT",  itemBtn, "LEFT",  T.paddingLarge, 0)
                itemFS:SetPoint("RIGHT", itemBtn, "RIGHT", -T.paddingSmall, 0)
                itemFS:SetJustifyH("LEFT")
                GUI.Font(itemFS)
                itemFS:SetText(item.label)

                local isSelected = (self.selectedItem == item.id)
                if isSelected then
                    itemBtn:SetBackdropColor(T.accentHover[1], T.accentHover[2], T.accentHover[3], T.accentHover[4])
                    selBar:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
                    itemFS:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 1)
                else
                    itemBtn:SetBackdropColor(0, 0, 0, 0)
                    selBar:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0)
                    itemFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 1)
                end

                itemBtn:SetScript("OnEnter", function()
                    if self.selectedItem ~= item.id then
                        itemBtn:SetBackdropColor(T.accentHover[1], T.accentHover[2], T.accentHover[3], T.accentHover[4] * 0.5)
                        itemFS:SetTextColor(T.textPrimary[1], T.textPrimary[2], T.textPrimary[3], 1)
                    end
                end)
                itemBtn:SetScript("OnLeave", function()
                    if self.selectedItem ~= item.id then
                        itemBtn:SetBackdropColor(0, 0, 0, 0)
                        itemFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 1)
                    end
                end)
                itemBtn:SetScript("OnClick", function()
                    self.selectedItem = item.id
                    self:RefreshSidebar()
                    self:RefreshContent()
                end)

                y = y + T.itemHeight
            end
        end
    end

    sc:SetHeight(y + T.paddingSmall)
    if self.sidebar._scrollbar then self.sidebar._scrollbar:Sync() end
end
