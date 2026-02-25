-- ArcUI_CDMContainerSync.lua
-- v8.0.0 - Push-based sync (proxy system removed)
--
-- APPROACH:
--   Push ArcUI group position/size to CDM viewer via UIParent-relative coords.
--   Use hooksecurefunc (NOT function replacement) to snap back when Blizzard
--   changes the viewer. hooksecurefunc never taints the execution context.
--
-- SNAP-BACK TRIGGERS (all via hooksecurefunc):
--   1. viewer:SetSize         — catches Layout() resize
--   2. viewer:SetPoint        — catches Edit Mode layout restore (TOPLEFT 0,0)
--   3. viewer:RefreshLayout   — catches the source of Layout() calls directly
--   4. viewer:SetIsEditing    — catches Edit Mode enter/exit toggle
--   5. viewer:UpdateShownState — catches show/hide state changes

local ADDON_NAME, ns = ...

ns.CDMContainerSync = ns.CDMContainerSync or {}

-- ═══════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════
local DEBUG = false

local GROUP_TO_VIEWER = {
    ["Buffs"]     = "BuffIconCooldownViewer",
    ["Essential"] = "EssentialCooldownViewer",
    ["Utility"]   = "UtilityCooldownViewer",
}

local VIEWER_TO_GROUP = {
    ["BuffIconCooldownViewer"]  = "Buffs",
    ["EssentialCooldownViewer"] = "Essential",
    ["UtilityCooldownViewer"]   = "Utility",
}

-- ═══════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════
local enabled = {}               -- [groupName] = true/false
local hooksInstalled = {}        -- [key] = true
local sizeOverride = {}          -- [viewerName] = {w, h}
local positionOverride = {}      -- [viewerName] = {x, y}
local pushing = false            -- True while WE are setting things
local snapPending = {}           -- [viewerName] = true if snap-back scheduled
local editModeSettling = false   -- True during Edit Mode transition
local libEMO = nil
local initialized = false

-- ═══════════════════════════════════════════════════════════════════
-- DEBUG
-- ═══════════════════════════════════════════════════════════════════
local function DebugPrint(...)
    if DEBUG then
        print("|cff00ff00[CDMSync]|r", ...)
    end
end

-- ═══════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════
local function IsInEditMode()
    local blizzardEditMode = EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive()
    local arcuiDragMode = ns.CDMGroups and ns.CDMGroups.dragModeEnabled
    return blizzardEditMode or arcuiDragMode
end

local function GetLibEMO()
    if libEMO then return libEMO end
    if LibStub then
        local success, lib = pcall(function() return LibStub("LibEditModeOverride-1.0") end)
        if success and lib then
            libEMO = lib
            return libEMO
        end
    end
    return nil
end

-- ═══════════════════════════════════════════════════════════════════
-- PUSH: ArcUI Group → CDM Viewer (position + size)
-- Uses UIParent-relative coordinates. ZERO frame dependency.
-- ═══════════════════════════════════════════════════════════════════
local function PushToViewer(groupName, skipLayoutSave)
    if not enabled[groupName] then return end

    local viewerName = GROUP_TO_VIEWER[groupName]
    if not viewerName then return end

    local viewer = _G[viewerName]
    local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]

    if not viewer or not group or not group.container then return end

    local cx, cy = group.container:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not cx or not ux then return end

    local posX = cx - ux
    local posY = cy - uy
    local w, h = group.container:GetSize()

    if not w or w < 1 then return end

    DebugPrint("PUSH:", groupName, "pos:", math.floor(posX), math.floor(posY),
        "size:", math.floor(w), "x", math.floor(h))

    pushing = true

    positionOverride[viewerName] = { x = posX, y = posY }
    sizeOverride[viewerName] = { w = w, h = h }

    -- CDM viewers are protected — cannot SetSize/SetPoint in combat.
    if InCombatLockdown() then
        DebugPrint("PUSH DEFERRED (combat):", groupName)
        pushing = false
        return
    end

    if not skipLayoutSave then
        local lib = GetLibEMO()
        if lib and lib:IsReady() then
            pcall(function()
                lib:LoadLayouts()
                if lib:CanEditActiveLayout() then
                    lib:ReanchorFrame(viewer, "CENTER", UIParent, "CENTER", posX, posY)
                    lib:SaveOnly()
                end
            end)
        end
    end

    viewer:ClearAllPoints()
    viewer:SetPoint("CENTER", UIParent, "CENTER", posX, posY)
    viewer:SetSize(w, h)

    pushing = false
end

-- ═══════════════════════════════════════════════════════════════════
-- SNAP-BACK: Re-push after Blizzard changes the viewer
-- ═══════════════════════════════════════════════════════════════════
local function ScheduleSnapBack(viewerName)
    if snapPending[viewerName] then return end
    snapPending[viewerName] = true

    C_Timer.After(0, function()
        snapPending[viewerName] = false

        local groupName = VIEWER_TO_GROUP[viewerName]
        if not groupName or not enabled[groupName] then return end
        if InCombatLockdown() then return end

        local ovr = sizeOverride[viewerName]
        local posOvr = positionOverride[viewerName]
        if not ovr or not posOvr then return end

        local viewer = _G[viewerName]
        if not viewer then return end

        local vw, vh = viewer:GetSize()
        local needsSize = (math.abs(vw - ovr.w) > 1) or (math.abs(vh - ovr.h) > 1)

        local vx, vy = viewer:GetCenter()
        local ux, uy = UIParent:GetCenter()
        local needsPos = false
        if vx and ux then
            local dx = math.abs((vx - ux) - posOvr.x)
            local dy = math.abs((vy - uy) - posOvr.y)
            needsPos = (dx > 2) or (dy > 2)
        end

        if needsSize or needsPos then
            DebugPrint("SNAP-BACK:", viewerName,
                needsSize and ("size:" .. math.floor(vw) .. "→" .. math.floor(ovr.w)) or "",
                needsPos and "pos:drifted" or "")

            pushing = true
            if needsPos then
                viewer:ClearAllPoints()
                viewer:SetPoint("CENTER", UIParent, "CENTER", posOvr.x, posOvr.y)
            end
            if needsSize then
                viewer:SetSize(ovr.w, ovr.h)
            end
            pushing = false
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════
-- PULL: CDM Viewer moved in Edit Mode → update ArcUI group
-- ═══════════════════════════════════════════════════════════════════
local function PullFromViewer(viewerName)
    local groupName = VIEWER_TO_GROUP[viewerName]
    if not groupName or not enabled[groupName] then return end

    local viewer = _G[viewerName]
    if not viewer then return end

    local cx, cy = viewer:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not cx or not ux then return end

    local posX = cx - ux
    local posY = cy - uy

    local posOvr = positionOverride[viewerName]
    if posOvr then
        local dx = math.abs(posX - posOvr.x)
        local dy = math.abs(posY - posOvr.y)
        if dx < 3 and dy < 3 then return end
    end

    DebugPrint("PULL:", viewerName, "→", groupName, "pos:", math.floor(posX), math.floor(posY))

    local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]
    if not group then return end

    if group.SetPosition then
        pushing = true
        group:SetPosition(posX, posY)
        pushing = false
    end

    positionOverride[viewerName] = { x = posX, y = posY }
end

-- ═══════════════════════════════════════════════════════════════════
-- VIEWER HOOKS (all hooksecurefunc — NEVER replace functions)
-- ═══════════════════════════════════════════════════════════════════
local function SetupViewerHooks(viewerName)
    if hooksInstalled["viewer_" .. viewerName] then return end

    local viewer = _G[viewerName]
    if not viewer then return end

    hooksInstalled["viewer_" .. viewerName] = true
    DebugPrint("Installing hooks on:", viewerName)

    hooksecurefunc(viewer, "SetSize", function(self)
        if pushing or editModeSettling then return end
        if IsInEditMode() then return end
        if enabled[VIEWER_TO_GROUP[viewerName]] then
            ScheduleSnapBack(viewerName)
        end
    end)

    hooksecurefunc(viewer, "SetPoint", function(self)
        if pushing or editModeSettling then return end

        if IsInEditMode() then
            if IsMouseButtonDown("LeftButton") then return end
            local point = select(1, self:GetPoint(1))
            if point == "TOPLEFT" then return end
            PullFromViewer(viewerName)
            return
        end

        if enabled[VIEWER_TO_GROUP[viewerName]] then
            ScheduleSnapBack(viewerName)
        end
    end)

    if viewer.RefreshLayout then
        hooksecurefunc(viewer, "RefreshLayout", function(self)
            if pushing or editModeSettling then return end
            if IsInEditMode() then return end
            ScheduleSnapBack(viewerName)
        end)
    end

    if viewer.SetIsEditing then
        hooksecurefunc(viewer, "SetIsEditing", function(self, editing)
            if pushing then return end
            if not editing then
                ScheduleSnapBack(viewerName)
            end
        end)
    end

    if viewer.UpdateShownState then
        hooksecurefunc(viewer, "UpdateShownState", function(self)
            if pushing or editModeSettling then return end
            if IsInEditMode() then return end
            ScheduleSnapBack(viewerName)
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════
-- GROUP HOOKS: Watch ArcUI container changes → push to viewer
-- ═══════════════════════════════════════════════════════════════════
local function SetupGroupHooks(groupName)
    if hooksInstalled["group_" .. groupName] then return end

    local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]
    if not group or not group.container then return end

    hooksInstalled["group_" .. groupName] = true
    DebugPrint("Installing group hooks on:", groupName)

    local pushThrottled = false
    local function ThrottledPush()
        if pushThrottled then return end
        pushThrottled = true
        C_Timer.After(0.05, function()
            pushThrottled = false
            PushToViewer(groupName)
        end)
    end

    hooksecurefunc(group.container, "SetSize", function()
        if not pushing and not editModeSettling then
            ThrottledPush()
        end
    end)

    hooksecurefunc(group.container, "SetPoint", function()
        if pushing or editModeSettling then return end
        if IsMouseButtonDown("LeftButton") then
            PushToViewer(groupName, true)
        else
            ThrottledPush()
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════
-- PROXY CHANGE CALLBACK
-- ═══════════════════════════════════════════════════════════════════
function ns.CDMContainerSync.OnProxySynced(groupName)
    if not enabled[groupName] then return end
    if IsInEditMode() then return end
    PushToViewer(groupName)
end

-- ═══════════════════════════════════════════════════════════════════
-- EDIT MODE HOOKS
-- ═══════════════════════════════════════════════════════════════════
if EditModeManagerFrame then
    hooksecurefunc(EditModeManagerFrame, "EnterEditMode", function()
        DebugPrint("Edit Mode ENTER")
        editModeSettling = true
        pushing = true

        C_Timer.After(0.8, function()
            pushing = false
            for groupName, isEnabled in pairs(enabled) do
                if isEnabled then PushToViewer(groupName) end
            end
            C_Timer.After(0.2, function()
                editModeSettling = false
            end)
        end)
    end)

    hooksecurefunc(EditModeManagerFrame, "ExitEditMode", function()
        DebugPrint("Edit Mode EXIT")
        editModeSettling = true
        pushing = true

        C_Timer.After(0.1, function()
            pushing = false
            for groupName, isEnabled in pairs(enabled) do
                if isEnabled then PushToViewer(groupName) end
            end
        end)

        C_Timer.After(0.5, function()
            editModeSettling = false
            for groupName, isEnabled in pairs(enabled) do
                if isEnabled then PushToViewer(groupName) end
            end
        end)
    end)
end

-- ═══════════════════════════════════════════════════════════════════
-- OPTIONS PANEL CLOSE: Dynamic layout re-enables → container resizes
-- ═══════════════════════════════════════════════════════════════════
local ACD_Sync = LibStub and LibStub("AceConfigDialog-3.0", true)
if ACD_Sync then
    hooksecurefunc(ACD_Sync, "Close", function(self, appName)
        if appName ~= "ArcUI" then return end

        C_Timer.After(0.3, function()
            if IsInEditMode() or InCombatLockdown() then return end
            for groupName, isEnabled in pairs(enabled) do
                if isEnabled then PushToViewer(groupName) end
            end
        end)

        C_Timer.After(1.0, function()
            if IsInEditMode() or InCombatLockdown() then return end
            for groupName, isEnabled in pairs(enabled) do
                if isEnabled then PushToViewer(groupName) end
            end
        end)
    end)
end

-- ═══════════════════════════════════════════════════════════════════
-- COMBAT SAFETY: Re-push after combat ends
-- ═══════════════════════════════════════════════════════════════════
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function()
    if IsInEditMode() then return end
    C_Timer.After(0.1, function()
        for groupName, isEnabled in pairs(enabled) do
            if isEnabled then PushToViewer(groupName) end
        end
    end)
end)

-- ═══════════════════════════════════════════════════════════════════
-- DRAG MODE CALLBACK (ArcUI overlay drag mode)
-- ═══════════════════════════════════════════════════════════════════
local function OnDragModeChanged(dragEnabled)
    if not dragEnabled then
        C_Timer.After(0.1, function()
            if ns.CDMGroups and ns.CDMGroups.SyncAllAnchorProxies then
                ns.CDMGroups.SyncAllAnchorProxies()
            end
            for groupName, isEnabled in pairs(enabled) do
                if isEnabled and not IsInEditMode() then
                    PushToViewer(groupName)
                end
            end
        end)
    end
end
ns.CDMContainerSync.OnDragModeChanged = OnDragModeChanged

-- ═══════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════
function ns.CDMContainerSync.SetEnabled(groupName, isEnabled)
    if not GROUP_TO_VIEWER[groupName] then return end

    enabled[groupName] = isEnabled

    if isEnabled then
        local viewerName = GROUP_TO_VIEWER[groupName]
        if viewerName then SetupViewerHooks(viewerName) end
        SetupGroupHooks(groupName)
        if not InCombatLockdown() then PushToViewer(groupName) end
    else
        local viewerName = GROUP_TO_VIEWER[groupName]
        if viewerName then
            sizeOverride[viewerName] = nil
            positionOverride[viewerName] = nil
            snapPending[viewerName] = nil
        end
    end

    if ns.db and ns.db.profile then
        ns.db.profile.cdmGroups = ns.db.profile.cdmGroups or {}
        ns.db.profile.cdmGroups.containerSync = ns.db.profile.cdmGroups.containerSync or {}
        ns.db.profile.cdmGroups.containerSync[groupName] = isEnabled
    end
end

function ns.CDMContainerSync.IsEnabled(groupName)
    return enabled[groupName] == true
end

function ns.CDMContainerSync.SyncAll()
    if IsInEditMode() or InCombatLockdown() then return end
    for groupName, isEnabled in pairs(enabled) do
        if isEnabled then PushToViewer(groupName) end
    end
end

ns.CDMContainerSync.RefreshFromContainers = ns.CDMContainerSync.SyncAll

function ns.CDMContainerSync.GetViewerForGroup(groupName)
    return GROUP_TO_VIEWER[groupName]
end

function ns.CDMContainerSync.GetGroupForViewer(viewerName)
    return VIEWER_TO_GROUP[viewerName]
end

-- ═══════════════════════════════════════════════════════════════════
-- SLASH COMMAND
-- ═══════════════════════════════════════════════════════════════════
SLASH_CDMSYNC1 = "/cdmsync"
SlashCmdList["CDMSYNC"] = function(msg)
    if msg == "debug on" then
        DEBUG = true
        print("|cff00ff00[CDMSync]|r Debug ON")
    elseif msg == "debug off" then
        DEBUG = false
        print("|cff00ff00[CDMSync]|r Debug OFF")
    elseif msg == "status" then
        print("|cff00ff00[CDMSync]|r Status:")
        for groupName, isEnabled in pairs(enabled) do
            local viewerName = GROUP_TO_VIEWER[groupName]
            local viewer = viewerName and _G[viewerName]
            local vw, vh = 0, 0
            if viewer then vw, vh = viewer:GetSize() end
            local posOvr = viewerName and positionOverride[viewerName]
            local sizeOvr = viewerName and sizeOverride[viewerName]
            print(string.format("  %s: %s  viewer:%dx%d",
                groupName, isEnabled and "ON" or "off", math.floor(vw), math.floor(vh)))
            if posOvr then print("    pos:", math.floor(posOvr.x), math.floor(posOvr.y)) end
            if sizeOvr then print("    size:", math.floor(sizeOvr.w), "x", math.floor(sizeOvr.h)) end
        end
        print("  Edit Mode:", (EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive()) and "ACTIVE" or "inactive")
    elseif msg == "sync" then
        ns.CDMContainerSync.SyncAll()
        print("|cff00ff00[CDMSync]|r Synced")
    else
        print("|cff00ff00[CDMSync]|r Commands: debug on/off, status, sync")
    end
end

-- ═══════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════
function ns.CDMContainerSync.Initialize()
    if initialized then return end
    initialized = true

    local hasSavedSettings = ns.db and ns.db.profile and ns.db.profile.cdmGroups and ns.db.profile.cdmGroups.containerSync
    
    if hasSavedSettings then
        -- Restore saved per-group settings
        for groupName, isEnabled in pairs(ns.db.profile.cdmGroups.containerSync) do
            if isEnabled and GROUP_TO_VIEWER[groupName] then
                ns.CDMContainerSync.SetEnabled(groupName, true)
            end
        end
    else
        -- DEFAULT: Enable sync for all 3 base CDM groups on first run
        for groupName in pairs(GROUP_TO_VIEWER) do
            ns.CDMContainerSync.SetEnabled(groupName, true)
        end
    end

    -- Multi-pass sync for load-in
    for _, delay in ipairs({ 0, 1, 5 }) do
        C_Timer.After(delay, function()
            for groupName, isEnabled in pairs(enabled) do
                if isEnabled then PushToViewer(groupName) end
            end
        end)
    end
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function(self, event)
    C_Timer.After(3, function()
        if ns.CDMGroups and ns.db then
            ns.CDMContainerSync.Initialize()
        end
    end)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
end)