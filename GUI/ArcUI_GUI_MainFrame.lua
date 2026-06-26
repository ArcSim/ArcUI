---@diagnostic disable: undefined-global
local _, ns = ...
local GUI = ns.GUI
local T   = GUI.Theme
local GF  = GUI.Frame

GF.selectedItem = GF.selectedItem or nil

local POS_KEY = "guiWindowPos"

function GF:_GetMainFrame()
    return self._mainFrame
end

function GF:CreateMainFrame()
    if self._mainFrame then return self._mainFrame end

    local f = CreateFrame("Frame", "ArcUIGUIFrame", UIParent, "BackdropTemplate")
    f:SetSize(900, 660)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetResizeBounds(780, 540)
    f:EnableMouse(true)
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = T.borderSize,
    })
    f:SetBackdropColor(T.bgDark[1], T.bgDark[2], T.bgDark[3], T.bgDark[4])
    f:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], 1)
    f:EnableKeyboard(true)
    f:SetScript("OnKeyDown", function(frame, key)
        if key == "ESCAPE" then
            frame:SetPropagateKeyboardInput(false)
            GF:Close()
        else
            frame:SetPropagateKeyboardInput(true)
        end
    end)
    f:Hide()

    self._mainFrame = f
    self:_BuildHeader(f)
    self:_BuildFooter(f)
    self:_BuildContent(f)
    self:CreateSidebar(f)
    return f
end

function GF:_BuildHeader(parent)
    local hdr = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    hdr:SetHeight(T.headerHeight)
    hdr:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    hdr:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    hdr:SetBackdropColor(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], T.bgMedium[4])

    local bb = hdr:CreateTexture(nil, "BORDER")
    bb:SetHeight(T.borderSize)
    bb:SetPoint("BOTTOMLEFT",  hdr, "BOTTOMLEFT",  0, 0)
    bb:SetPoint("BOTTOMRIGHT", hdr, "BOTTOMRIGHT", 0, 0)
    bb:SetColorTexture(T.border[1], T.border[2], T.border[3], 1)

    -- ArcUI title
    local title = hdr:CreateFontString(nil, "OVERLAY")
    title:SetPoint("LEFT", hdr, "LEFT", T.paddingLarge, 0)
    GUI.Font(title, 16)
    title:SetText("|cff8847ffArc|r|cffffffffUI|r")

    local ver = hdr:CreateFontString(nil, "OVERLAY")
    ver:SetPoint("LEFT", title, "RIGHT", T.paddingSmall, -1)
    GUI.Font(ver, T.fontSizeSmall)
    ver:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 0.7)
    local tocVer = C_AddOns and C_AddOns.GetAddOnMetadata("ArcUI", "Version")
                    or GetAddOnMetadata("ArcUI", "Version") or ""
    ver:SetText(tocVer)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, hdr)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", hdr, "RIGHT", -T.paddingMedium, 0)

    local closeFS = closeBtn:CreateFontString(nil, "OVERLAY")
    closeFS:SetAllPoints(closeBtn)
    closeFS:SetJustifyH("CENTER")
    closeFS:SetJustifyV("MIDDLE")
    GUI.Font(closeFS, 18)
    closeFS:SetText("×")
    closeFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 0.8)

    closeBtn:SetScript("OnClick",  function() GF:Close() end)
    closeBtn:SetScript("OnEnter",  function()
        closeFS:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 1)
    end)
    closeBtn:SetScript("OnLeave",  function()
        closeFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 0.8)
    end)

    -- Drag via header
    hdr:EnableMouse(true)
    hdr:RegisterForDrag("LeftButton")
    hdr:SetScript("OnDragStart", function() parent:StartMoving() end)
    hdr:SetScript("OnDragStop",  function()
        parent:StopMovingOrSizing()
        GF:_SavePosition()
    end)

    parent.guiHeader = hdr
end

function GF:_BuildFooter(parent)
    local ftr = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ftr:SetHeight(T.footerHeight)
    ftr:SetPoint("BOTTOMLEFT",  parent, "BOTTOMLEFT",  0, 0)
    ftr:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    ftr:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    ftr:SetBackdropColor(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], T.bgMedium[4])

    local tb = ftr:CreateTexture(nil, "BORDER")
    tb:SetHeight(T.borderSize)
    tb:SetPoint("TOPLEFT",  ftr, "TOPLEFT",  0, 0)
    tb:SetPoint("TOPRIGHT", ftr, "TOPRIGHT", 0, 0)
    tb:SetColorTexture(T.border[1], T.border[2], T.border[3], 1)

    -- Resize handle
    local handle = CreateFrame("Button", nil, ftr)
    handle:SetSize(20, 20)
    handle:SetPoint("BOTTOMRIGHT", ftr, "BOTTOMRIGHT", -2, 2)
    handle:EnableMouse(true)

    local hFS = handle:CreateFontString(nil, "OVERLAY")
    hFS:SetAllPoints(handle)
    hFS:SetJustifyH("RIGHT")
    hFS:SetJustifyV("BOTTOM")
    GUI.Font(hFS, 14)
    hFS:SetText("◢")
    hFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 0.4)

    handle:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then parent:StartSizing("BOTTOMRIGHT") end
    end)
    handle:SetScript("OnMouseUp", function()
        parent:StopMovingOrSizing()
        GF:_SavePosition()
        -- Sync content area after resize
        if GF._contentScrollbar then GF._contentScrollbar:Sync() end
        if GF.sidebar and GF.sidebar._scrollbar then GF.sidebar._scrollbar:Sync() end
    end)
    handle:SetScript("OnEnter", function()
        hFS:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 1)
    end)
    handle:SetScript("OnLeave", function()
        hFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 0.4)
    end)

    -- Legacy options button (opens the old AceConfig panel)
    local legacyBtn = CreateFrame("Button", nil, ftr, "BackdropTemplate")
    legacyBtn:SetSize(110, 18)
    legacyBtn:SetPoint("LEFT", ftr, "LEFT", T.paddingMedium, 0)
    legacyBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = T.borderSize,
    })
    legacyBtn:SetBackdropColor(T.bgLight[1], T.bgLight[2], T.bgLight[3], 0.6)
    legacyBtn:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], 0.6)

    local legacyFS = legacyBtn:CreateFontString(nil, "OVERLAY")
    legacyFS:SetAllPoints(legacyBtn)
    legacyFS:SetJustifyH("CENTER")
    GUI.Font(legacyFS, T.fontSizeSmall)
    legacyFS:SetText("Legacy Options")
    legacyFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 0.7)

    legacyBtn:SetScript("OnClick", function()
        if GF._legacyOpenOptions then GF._legacyOpenOptions() end
    end)
    legacyBtn:SetScript("OnEnter", function()
        legacyBtn:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 0.8)
        legacyFS:SetTextColor(T.textPrimary[1], T.textPrimary[2], T.textPrimary[3], 1)
    end)
    legacyBtn:SetScript("OnLeave", function()
        legacyBtn:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], 0.6)
        legacyFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 0.7)
    end)

    -- Hint text
    local hint = ftr:CreateFontString(nil, "OVERLAY")
    hint:SetPoint("LEFT",  legacyBtn, "RIGHT", T.paddingMedium, 0)
    hint:SetPoint("RIGHT", handle, "LEFT", -T.paddingSmall, 0)
    hint:SetJustifyH("LEFT")
    GUI.Font(hint, T.fontSizeSmall)
    hint:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 0.4)
    hint:SetText("/arcui")

    -- Drag via footer (not over handle)
    ftr:EnableMouse(true)
    ftr:RegisterForDrag("LeftButton")
    ftr:SetScript("OnDragStart", function() parent:StartMoving() end)
    ftr:SetScript("OnDragStop",  function()
        parent:StopMovingOrSizing()
        GF:_SavePosition()
    end)

    parent.guiFooter = ftr
end

function GF:_BuildContent(parent)
    local area = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    area:SetPoint("TOPLEFT",     parent, "TOPLEFT",     T.sidebarWidth, -T.headerHeight)
    area:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0,              T.footerHeight)
    area:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    area:SetBackdropColor(T.bgDark[1], T.bgDark[2], T.bgDark[3], T.bgDark[4])

    -- Left border between sidebar and content
    local lb = area:CreateTexture(nil, "BORDER")
    lb:SetWidth(T.borderSize)
    lb:SetPoint("TOPLEFT",    area, "TOPLEFT",    0, 0)
    lb:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", 0, 0)
    lb:SetColorTexture(T.border[1], T.border[2], T.border[3], 1)

    local sf = CreateFrame("ScrollFrame", nil, area)
    sf:SetPoint("TOPLEFT",     area, "TOPLEFT",     T.borderSize,  -T.paddingSmall)
    sf:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", -14,            T.paddingSmall)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(700)  -- placeholder; OnSizeChanged corrects it once the frame sizes
    sc:SetHeight(1)
    sf:SetScrollChild(sc)
    sf:SetScript("OnSizeChanged", function(s, w) sc:SetWidth(w) end)

    sf:EnableMouseWheel(true)
    local scrollbar = GUI:CreateScrollbar(sf, area)
    sf:SetScript("OnMouseWheel", function(_, delta)
        local cur = sf:GetVerticalScroll()
        local max = sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(max, cur - delta * 24)))
        scrollbar:Sync()
    end)

    self._contentArea      = area
    self._scrollFrame      = sf
    self._scrollChild      = sc
    self._contentScrollbar = scrollbar
    parent.guiContent      = area
end

function GF:RefreshContent()
    if not self._scrollChild then return end
    local sc = self._scrollChild

    -- Clear previous content
    for _, child in ipairs({ sc:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ sc:GetRegions() }) do region:Hide() end

    if self._scrollFrame then self._scrollFrame:SetVerticalScroll(0) end

    local id = self.selectedItem
    if not id then
        sc:SetHeight(1)
        if self._contentScrollbar then self._contentScrollbar:Sync() end
        return
    end

    if self.PanelBuilders[id] then
        self.PanelBuilders[id](self._contentArea)
        return
    end

    if self.ContentBuilders[id] then
        local finalY = self.ContentBuilders[id](sc, T.paddingSmall)
        sc:SetHeight(finalY or T.paddingSmall)
    else
        -- Placeholder
        local card = GUI:CreateCard(sc, "Coming Soon", T.paddingSmall)
        card:AddLabel("This section has no content registered yet.")
        sc:SetHeight(card:GetNextOffset())
    end

    if self._contentScrollbar then self._contentScrollbar:Sync() end
end

-- ── Public API ─────────────────────────────────────────────────

function GF:Open()
    if InCombatLockdown() then
        if ns.lpmsg then ns.lpmsg("ArcUI GUI: will open after combat.") end
        self._pendingOpen = true
        return
    end
    if not self._mainFrame then
        self:CreateMainFrame()
        if not self.selectedItem then
            for _, sec in ipairs(self._sidebarSections) do
                if sec.items and sec.items[1] then
                    self.selectedItem = sec.items[1].id
                    break
                end
            end
        end
    end
    self:_RestorePosition()
    self._mainFrame:Show()
    self._mainFrame:Raise()
    self:RefreshSidebar()
    self:RefreshContent()
    -- Fire the same panel-open callbacks AceConfigDialog:Open("ArcUI") fires
    local wasOpen = ns._arcUIOptionsOpen
    ns._arcUIOptionsOpen = true
    if not wasOpen then
        if ns.CDMShared and ns.CDMShared.FirePanelCallbacks then
            ns.CDMShared.FirePanelCallbacks(true)
        end
        if ns.CDMGroups and ns.CDMGroups.DynamicLayout and ns.CDMGroups.DynamicLayout.OnOptionsPanelOpened then
            ns.CDMGroups.DynamicLayout.OnOptionsPanelOpened()
        end
        if ns.CDMGroups and ns.CDMGroups.OnArcUIPanelChanged then
            ns.CDMGroups.OnArcUIPanelChanged(true)
        end
    end
end

function GF:Close()
    if not self._mainFrame then return end
    self._mainFrame:Hide()
    self:_SavePosition()
    -- Fire the same panel-close callbacks AceConfigDialog:Close("ArcUI") fires
    ns._arcUIOptionsOpen = false
    if ns.CDMShared and ns.CDMShared.FirePanelCallbacks then
        ns.CDMShared.FirePanelCallbacks(false)
    end
    if ns.CDMGroups and ns.CDMGroups.DynamicLayout and ns.CDMGroups.DynamicLayout.OnOptionsPanelClosed then
        ns.CDMGroups.DynamicLayout.OnOptionsPanelClosed()
    end
    if ns.CDMGroups and ns.CDMGroups.OnArcUIPanelChanged then
        ns.CDMGroups.OnArcUIPanelChanged(false)
    end
end

function GF:Toggle()
    if self._mainFrame and self._mainFrame:IsShown() then
        self:Close()
    else
        self:Open()
    end
end

-- ── Position persistence ───────────────────────────────────────

function GF:_SavePosition()
    if not self._mainFrame then return end
    if not (ns.db and ns.db.global) then return end
    local pt, _, rpt, x, y = self._mainFrame:GetPoint()
    if not pt then return end
    ns.db.global[POS_KEY] = {
        point = pt, relPoint = rpt or "CENTER",
        x = x or 0, y = y or 40,
        w = self._mainFrame:GetWidth(),
        h = self._mainFrame:GetHeight(),
    }
end

function GF:_RestorePosition()
    if not self._mainFrame then return end
    if not (ns.db and ns.db.global) then return end
    local pos = ns.db.global[POS_KEY]
    if pos and pos.point then
        self._mainFrame:ClearAllPoints()
        self._mainFrame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
        if pos.w and pos.h then
            self._mainFrame:SetSize(pos.w, pos.h)
        end
    end
end

-- ── Combat events ──────────────────────────────────────────────

local combatF = CreateFrame("Frame")
combatF:RegisterEvent("PLAYER_REGEN_DISABLED")
combatF:RegisterEvent("PLAYER_REGEN_ENABLED")
combatF:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        if GF._mainFrame and GF._mainFrame:IsShown() then
            GF._pendingOpen = true
            GF:Close()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if GF._pendingOpen then
            GF._pendingOpen = nil
            GF:Open()
        end
    end
end)

-- ── PLAYER_LOGIN: register sidebar + redirect /arcui ──────────
-- Runs after every module has Init()'d so all ns.* are populated.

local loginF = CreateFrame("Frame")
loginF:RegisterEvent("PLAYER_LOGIN")
loginF:SetScript("OnEvent", function()
    loginF:UnregisterAllEvents()

    -- Default sidebar sections (content built out progressively)
    if #GF._sidebarSections == 0 then
        GF:AddSection("bars", "Bars", {
            { id = "bars_aura",      label = "Aura Bars"       },
            { id = "bars_resource",  label = "Resource Bars"   },
            { id = "bars_cooldown",  label = "Cooldown Bars"   },
            { id = "bars_timer",     label = "Timer Bars"      },
            { id = "bars_custom",    label = "Custom Tracking" },
        })
        GF:AddSection("cdm", "CDM", {
            { id = "cdm_groups",      label = "Groups"       },
            { id = "cdm_icons",       label = "Icon Style"   },
            { id = "cdm_arc_auras",   label = "Arc Auras"    },
            { id = "cdm_custom_icons",label = "Custom Icons" },
        })
        GF:AddSection("utils", "Utilities", {
            { id = "util_reminder",  label = "Cooldown Reminder" },
            { id = "util_import",    label = "Import / Export"   },
            { id = "util_repair",    label = "Data Repair"       },
        })
    end

    -- Redirect ns.API.OpenOptions → new GUI window.
    -- Keep the original accessible via GF._legacyOpenOptions for a fallback button.
    if ns.API and ns.API.OpenOptions then
        GF._legacyOpenOptions = ns.API.OpenOptions
        ns.API.OpenOptions = function()
            GF:Toggle()
        end
    end
end)

-- ── Slash commands ─────────────────────────────────────────────
-- /arcgui kept as a direct alias in case ns.API.OpenOptions isn't ready yet.
SLASH_ARCGUI1 = "/arcgui"
SlashCmdList["ARCGUI"] = function() GF:Toggle() end
