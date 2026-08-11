-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI CDMGroups Maintain - HOT PATH
-- All timer-based maintenance code consolidated here for easy auditing
-- This file runs at the throttle rate (default 5Hz) set in CDM_Shared
-- ═══════════════════════════════════════════════════════════════════════════

local addonName, ns = ...

-- Dependencies from other modules
local Shared = ns.CDMShared
local Registry = ns.FrameRegistry

-- Profiler handler tracking (nil-safe if profiler not loaded)
local Track = _G.ArcUIProfiler_Track

-- ═══════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Set this to true to re-enable backup fighting in maintainer
-- (Hooks should handle this, but enable if you see flicker)
local MAINTAINER_BACKUP_ENABLED = _G.ARCUI_MAINTAINER_BACKUP or false

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPER: Check if CDMGroups is enabled
-- ═══════════════════════════════════════════════════════════════════════════
local function IsCDMGroupsEnabled()
    return ns.CDMGroups and ns.CDMGroups.IsCDMGroupsEnabled and ns.CDMGroups.IsCDMGroupsEnabled()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME HOOKS - Primary CDM fighting mechanism
-- These hooks fire INSTANTLY when CDM tries to modify our managed frames
-- Maintainers below are BACKUP (catch anything hooks miss)
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- HOOK CALLBACKS - extracted as named locals so profiler can track them
-- ═══════════════════════════════════════════════════════════════════════════

local function OnClearAllPoints_Grouped(self)
    if self._cdmgSettingPosition then return end
    if self._freeDragging or self._groupDragging then return end
    
    local parent = self:GetParent()
    if not parent or not parent._isCDMGContainer then return end
    
    if self._cdmgTargetPoint then
        self._cdmgSettingPosition = true
        self:SetPoint(
            self._cdmgTargetPoint,
            parent,
            self._cdmgTargetRelPoint or "TOPLEFT",
            self._cdmgTargetX or 0,
            self._cdmgTargetY or 0
        )
        self._cdmgSettingPosition = false
    end
end

local function OnSetScale(self, scale)
    if self._cdmgSettingScale then return end
    
    -- Skip Arc Aura frames - they manage their own scale via ArcAuras.ApplySettingsToFrame
    if self._arcAuraID then return end
    
    local parent = self:GetParent()
    -- Check if in container OR if it's a free icon (check frame flag directly, not cdID lookup)
    local isInContainer = parent and parent._isCDMGContainer
    local isFreeIcon = self._cdmgIsFreeIcon
    
    if not isInContainer and not isFreeIcon then return end
    
    -- Force scale to 1 (both container and free icons)
    if math.abs((scale or 1) - 1) > 0.01 then
        self._cdmgSettingScale = true
        self:SetScale(1)
        self._cdmgSettingScale = false
    end
end

local function OnSetSize(self, w, h)
    if self._cdmgSettingSize then return end
    
    local parent = self:GetParent()
    -- Check if in container OR if it's a free icon (check frame flag directly)
    local isInContainer = parent and parent._isCDMGContainer
    local isFreeIcon = self._cdmgIsFreeIcon
    
    -- Arc Aura frames: Only enforce size if they're in a group container
    -- Free Arc Auras manage their own size via ArcAuras.ApplySettingsToFrame
    if self._arcAuraID and not isInContainer then return end
    
    if not isInContainer and not isFreeIcon then return end
    
    -- Get target size - for free icons, get from freeIcons table using frame ID
    local targetW, targetH
    if isFreeIcon then
        -- Use GetFrameID to support both cooldownID (CDM) and _arcAuraID (custom)
        local frameID = Shared.GetFrameID and Shared.GetFrameID(self) or self.cooldownID
        local freeData = frameID and ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[frameID]
        if freeData then
            -- Calculate effective size: width/height as base, scale as multiplier
            -- NOTE: Free icons ALWAYS apply custom scale/width/height since they don't belong to a group
            local baseSize = freeData.iconSize or 36
            targetW = baseSize
            targetH = baseSize
            if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettings then
                local cfg = ns.CDMEnhance.GetEffectiveIconSettings(frameID)
                if cfg then
                    -- Use width/height as base (if set), otherwise use iconSize
                    local baseW = cfg.width or baseSize
                    local baseH = cfg.height or baseSize
                    -- Apply scale as multiplier on top
                    local scale = cfg.scale or 1.0
                    targetW = baseW * scale
                    targetH = baseH * scale
                end
            end
        else
            -- Fallback to stored target size
            local fallback = self._cdmgFreeTargetSize or 36
            targetW = fallback
            targetH = fallback
        end
    else
        -- GROUPED ICON: Use group's slot dimensions OR custom size
        -- Use GetFrameID to support both cooldownID and _arcAuraID
        local frameID = Shared.GetFrameID and Shared.GetFrameID(self) or self.cooldownID
        
        -- CRITICAL FIX: Use stored slot dimensions as the default
        -- These are set by Layout() and represent the GROUP's size
        local slotW = self._cdmgSlotW or self._cdmgTargetSize or 36
        local slotH = self._cdmgSlotH or self._cdmgTargetSize or 36
        targetW = slotW
        targetH = slotH
        
        if frameID and ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettings then
            local cfg = ns.CDMEnhance.GetEffectiveIconSettings(frameID)
            -- ONLY apply custom size when useGroupScale is explicitly OFF
            if cfg and cfg.useGroupScale == false then
                -- Use width/height as base (if set), otherwise use slot size
                local baseW = cfg.width or slotW
                local baseH = cfg.height or slotH
                -- Apply scale as multiplier on top
                local scale = cfg.scale or 1.0
                targetW = baseW * scale
                targetH = baseH * scale
            end
            -- When useGroupScale is true (default), use group's slot dimensions (already set above)
        end
    end
    
    -- Use 0.5 pixel tolerance (tight like reference CDMGroups)
    if math.abs((w or 0) - targetW) > 0.5 or math.abs((h or 0) - targetH) > 0.5 then
        self._cdmgSettingSize = true
        self:SetSize(targetW, targetH)
        self._cdmgSettingSize = false
    end
end

-- Resolve a free icon's Stack Priority (per-icon strata/frameLevel) LIVE from
-- settings — never cached on the frame. Early-login resolves can see an
-- incomplete spec store; a frame-cached value taken then would be stale
-- forever (the "loads as MEDIUM" bug), while a live read self-heals as soon
-- as the settings cache is correct. GetIconSettings is cache-backed, so this
-- is a table lookup in the hot paths, not a rebuild.
local function GetFreeIconStackPriority(frame, cdIDOverride)
    local cdID = cdIDOverride or frame.cooldownID or frame._arcAuraID
    local cfg = cdID and ns.CDMEnhance and ns.CDMEnhance.GetIconSettings
        and ns.CDMEnhance.GetIconSettings(cdID)
    local fp = cfg and cfg.freePosition
    if not fp then return nil, nil end
    return fp.strata, tonumber(fp.frameLevel)
end

-- Children that PIN a strata don't follow a later parent strata change: glow
-- frames capture the parent's strata when the glow STARTS (ns.Glows), keybind
-- containers when they refresh. After a free icon's strata actually changes,
-- restart/refresh them so the whole icon stack moves together — otherwise the
-- icon drops to LOW while its active glow keeps drawing at the old MEDIUM
-- (the "still looks wrong until I click it in the panel" symptom).
local function ResyncPinnedChildren(frame)
    if ns.Glows and ns.Glows.ResizeAll then ns.Glows.ResizeAll(frame) end
    if ns.Keybinds and ns.Keybinds.QueueRefresh then ns.Keybinds.QueueRefresh() end
end
ns.CDMGroups.ResyncStrataChildren = ResyncPinnedChildren

local function OnSetFrameStrata(self, strata)
    if self._cdmgSettingStrata then return end

    local parent = self:GetParent()
    -- Check if in container OR if it's a free icon
    local isInContainer = parent and parent._isCDMGContainer
    local isFreeIcon = self._cdmgIsFreeIcon

    if not isInContainer and not isFreeIcon then return end

    -- Determine expected strata: container's configured strata, the free icon's
    -- own Stack Priority strata (per-icon option), or MEDIUM as the default
    local freeStrata, freeLevel
    if isFreeIcon and not isInContainer then
        freeStrata, freeLevel = GetFreeIconStackPriority(self)
    end
    local expectedStrata = (isInContainer and parent._cdmgFrameStrata)
        or freeStrata
        or "MEDIUM"

    if strata ~= expectedStrata then
        self._cdmgSettingStrata = true
        self:SetFrameStrata(expectedStrata)
        self._cdmgSettingStrata = false
    end

    -- Piggyback level enforcement: SetParent recalculates frame levels WITHOUT
    -- calling SetFrameLevel (no hook fires), so the strata writes that follow
    -- every reposition sweep are our chance to re-assert the configured level.
    if freeLevel and self:GetFrameLevel() ~= freeLevel then
        self._cdmgSettingLevel = true
        self:SetFrameLevel(freeLevel)
        self._cdmgSettingLevel = false
    end

    -- Change detection (any writer): if this write ended up ACTUALLY changing
    -- the icon's strata, re-sync strata-pinned children (glows, keybind text).
    if isFreeIcon then
        local now = self:GetFrameStrata()
        if self._cdmgLastSeenStrata ~= now then
            self._cdmgLastSeenStrata = now
            ResyncPinnedChildren(self)
        end
    end
end

-- Fight frame-level changes on free icons that have a Stack Priority level set.
-- Resolves live (see GetFreeIconStackPriority); icons without a configured
-- level are never fought.
local function OnSetFrameLevel(self, level)
    if self._cdmgSettingLevel then return end
    if not self._cdmgIsFreeIcon then return end
    local _, expected = GetFreeIconStackPriority(self)
    if expected and level ~= expected then
        self._cdmgSettingLevel = true
        self:SetFrameLevel(expected)
        self._cdmgSettingLevel = false
    end
end

local function OnSetParent(self, newParent)
    if self._cdmgSettingParent then return end
    
    -- Only fight for free icons
    if not self._cdmgIsFreeIcon then return end
    
    -- Free icons must stay parented to UIParent
    if newParent ~= UIParent then
        self._cdmgSettingParent = true
        self:SetParent(UIParent)
        self._cdmgSettingParent = false
    end
end

local function OnClearAllPoints_Free(self)
    if self._cdmgSettingPosition then return end
    if self._freeDragging then return end
    
    -- Only fight for free icons
    if not self._cdmgIsFreeIcon then return end
    
    -- Restore position from freeIcons data
    -- Use GetFrameID to support both cooldownID (CDM) and _arcAuraID (custom)
    local frameID = Shared.GetFrameID and Shared.GetFrameID(self) or self.cooldownID
    local freeData = frameID and ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[frameID]
    if freeData then
        self._cdmgSettingPosition = true
        self:SetPoint("CENTER", UIParent, "CENTER", freeData.x, freeData.y)
        self._cdmgSettingPosition = false
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- VISIBILITY HOOKS: Fight CDM's SetShown(false) / Hide() on managed frames
-- CDM calls these during rearrangement while its settings panel is open.
-- Post-hooks immediately re-Show the frame if it should be visible.
-- ═══════════════════════════════════════════════════════════════════════════
local function OnSetShown_Managed(self, shown)
    if shown then return end  -- Only fight SetShown(false)
    if self._arcAllowHide then return end  -- ArcUI cleanup
    if self._arcHiddenByBar or self._arcHiddenUnequipped or self._arcSlotEmpty then return end
    if self._groupDragging or self._freeDragging then return end
    
    -- Check: is this frame still managed by us?
    local parent = self:GetParent()
    local isGrouped = parent and parent._isCDMGContainer
    local isFree = self._cdmgIsFreeIcon
    if not isGrouped and not isFree then return end
    
    self:Show()
end

local function OnHide_Managed(self)
    if self._arcAllowHide then return end
    if self._arcHiddenByBar or self._arcHiddenUnequipped or self._arcSlotEmpty then return end
    if self._groupDragging or self._freeDragging then return end
    
    local parent = self:GetParent()
    local isGrouped = parent and parent._isCDMGContainer
    local isFree = self._cdmgIsFreeIcon
    if not isGrouped and not isFree then return end
    
    self:Show()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Wrap callbacks for profiler tracking (nil-safe if profiler not loaded)
-- ═══════════════════════════════════════════════════════════════════════════
local TrackedClearAllPoints  = Track and Track("Maintain.ClearAllPoints",  OnClearAllPoints_Grouped) or OnClearAllPoints_Grouped
local TrackedSetScale        = Track and Track("Maintain.SetScale",        OnSetScale) or OnSetScale
local TrackedSetSize         = Track and Track("Maintain.SetSize",         OnSetSize) or OnSetSize
local TrackedSetFrameStrata  = Track and Track("Maintain.SetFrameStrata",  OnSetFrameStrata) or OnSetFrameStrata
local TrackedSetFrameLevel   = Track and Track("Maintain.SetFrameLevel",   OnSetFrameLevel) or OnSetFrameLevel
local TrackedSetParent       = Track and Track("Maintain.SetParent",       OnSetParent) or OnSetParent
local TrackedClearAllPointsF = Track and Track("Maintain.ClearAllPointsF", OnClearAllPoints_Free) or OnClearAllPoints_Free
local TrackedSetShown        = Track and Track("Maintain.SetShown",        OnSetShown_Managed) or OnSetShown_Managed
local TrackedHide            = Track and Track("Maintain.Hide",            OnHide_Managed) or OnHide_Managed

-- ═══════════════════════════════════════════════════════════════════════════
-- HOOK INSTALLERS - use tracked callbacks
-- ═══════════════════════════════════════════════════════════════════════════

-- Hook ClearAllPoints - restore position immediately for grouped icons
local function HookFrameClearAllPoints(frame)
    if frame._cdmgClearPointsHooked then return end
    hooksecurefunc(frame, "ClearAllPoints", TrackedClearAllPoints)
    frame._cdmgClearPointsHooked = true
end

-- Hook SetScale - force scale back to 1
local function HookFrameScale(frame)
    if frame._cdmgScaleHooked then return end
    hooksecurefunc(frame, "SetScale", TrackedSetScale)
    frame._cdmgScaleHooked = true
end

-- Hook SetSize - force size back to target
local function HookFrameSize(frame, targetSize)
    if frame._cdmgSizeHooked then return end
    hooksecurefunc(frame, "SetSize", TrackedSetSize)
    frame._cdmgSizeHooked = true
end

-- Hook SetFrameStrata - force strata back to group's configured strata
local function HookFrameStrata(frame)
    if frame._cdmgStrataHooked then return end
    hooksecurefunc(frame, "SetFrameStrata", TrackedSetFrameStrata)
    frame._cdmgStrataHooked = true
end

-- Hook SetFrameLevel - force level back to the free icon's Stack Priority level
local function HookFrameLevel(frame)
    if frame._cdmgLevelHooked then return end
    hooksecurefunc(frame, "SetFrameLevel", TrackedSetFrameLevel)
    frame._cdmgLevelHooked = true
end

-- Hook SetParent - fight CDM trying to reparent free icons
local function HookFrameParent(frame)
    if frame._cdmgParentHooked then return end
    hooksecurefunc(frame, "SetParent", TrackedSetParent)
    frame._cdmgParentHooked = true
end

-- Hook ClearAllPoints - restore position immediately for free icons
local function HookFrameClearAllPointsFree(frame)
    if frame._cdmgClearPointsFreeHooked then return end
    hooksecurefunc(frame, "ClearAllPoints", TrackedClearAllPointsF)
    frame._cdmgClearPointsFreeHooked = true
end

-- Hook SetShown - fight CDM's SetShown(false) on managed frames
local function HookFrameSetShown(frame)
    if frame._cdmgSetShownHooked then return end
    hooksecurefunc(frame, "SetShown", TrackedSetShown)
    frame._cdmgSetShownHooked = true
end

-- Hook Hide - fight CDM's Hide() on managed frames
local function HookFrameHide(frame)
    if frame._cdmgHideHooked then return end
    hooksecurefunc(frame, "Hide", TrackedHide)
    frame._cdmgHideHooked = true
end

-- Apply all hooks to a grouped frame
local function HookFrame(frame, targetSize)
    HookFrameClearAllPoints(frame)
    HookFrameScale(frame)
    HookFrameSize(frame, targetSize)
    HookFrameStrata(frame)
    HookFrameSetShown(frame)
    HookFrameHide(frame)
    frame._cdmgTargetSize = targetSize
end

-- Apply all hooks to a free icon frame
local function HookFreeIcon(frame, iconSize)
    HookFrameScale(frame)
    HookFrameSize(frame, iconSize)
    HookFrameParent(frame)
    HookFrameClearAllPointsFree(frame)
    HookFrameSetShown(frame)
    HookFrameHide(frame)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HOOK EXPORTS
-- ═══════════════════════════════════════════════════════════════════════════
ns.CDMGroups = ns.CDMGroups or {}
ns.CDMGroups.HookFrameClearAllPoints = HookFrameClearAllPoints
ns.CDMGroups.HookFrameScale = HookFrameScale
ns.CDMGroups.HookFrameSize = HookFrameSize
ns.CDMGroups.HookFrameStrata = HookFrameStrata
ns.CDMGroups.HookFrame = HookFrame
ns.CDMGroups.HookFrameParent = HookFrameParent
ns.CDMGroups.HookFrameClearAllPointsFree = HookFrameClearAllPointsFree
ns.CDMGroups.HookFrameSetShown = HookFrameSetShown
ns.CDMGroups.HookFrameHide = HookFrameHide
ns.CDMGroups.HookFreeIcon = HookFreeIcon

-- ═══════════════════════════════════════════════════════════════════════════
-- SHARED HELPER: Find a frame by cooldownID in CDM viewers
-- Returns frame, viewerType, viewerName or nil
-- ═══════════════════════════════════════════════════════════════════════════
local function FindFrameInViewers(cdID)
    for _, viewerInfo in ipairs(Shared.CDM_VIEWERS) do
        local viewer = _G[viewerInfo.name]
        if viewer then
            local children = { viewer:GetChildren() }
            for _, child in ipairs(children) do
                if child.cooldownID == cdID then
                    return child, viewerInfo.type, viewerInfo.name
                end
            end
        end
    end
    return nil, nil, nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FREE ICON STACK PRIORITY (per-icon strata/frameLevel for stacked free icons)
-- Installs the fight-back hooks and applies the CURRENT setting to the frame.
-- The hooks resolve live from settings on every write (GetFreeIconStackPriority),
-- so this apply is only the "right now" push — there is no frame-cached state
-- to go stale. No freePosition config = default MEDIUM, level never fought —
-- identical to pre-feature behavior.
-- ═══════════════════════════════════════════════════════════════════════════
local function ApplyFreeIconStrata(cdID, frame)
    if not frame then return end
    -- Self-contained: install the strata/level fight-back hooks here (idempotent),
    -- because the various free-icon setup sites install differing hook subsets.
    HookFrameStrata(frame)
    HookFrameLevel(frame)
    local strata, level = GetFreeIconStackPriority(frame, cdID)
    local changed = false
    if strata and frame:GetFrameStrata() ~= strata then
        frame._cdmgSettingStrata = true
        frame:SetFrameStrata(strata)
        frame._cdmgSettingStrata = false
        changed = true
    end
    if level and frame:GetFrameLevel() ~= level then
        frame._cdmgSettingLevel = true
        frame:SetFrameLevel(level)
        frame._cdmgSettingLevel = false
    end
    -- Guarded writes bypass the hooks (shared guard), so re-sync strata-pinned
    -- children (glows, keybind text) here when the strata actually changed.
    if changed then
        frame._cdmgLastSeenStrata = frame:GetFrameStrata()
        ResyncPinnedChildren(frame)
    end
end
ns.CDMGroups.ApplyFreeIconStrata = ApplyFreeIconStrata
ns.CDMGroups.GetFreeIconStackPriority = GetFreeIconStackPriority

-- Export helpers
ns.CDMGroups.FindFrameInViewers = FindFrameInViewers


-- ═══════════════════════════════════════════════════════════════════════════
-- MAINTAINERS REMOVED - Now handled by FrameController
-- ═══════════════════════════════════════════════════════════════════════════
-- The following have been moved to ArcUI_FrameController.lua:
--
-- FreeIconMaintainer (was ~280 lines):
--   - Position enforcement → FrameController.VisualMaintainer
--   - Size enforcement → FrameController.VisualMaintainer
--   - Visual updates (ApplyIconVisuals) → FrameController.VisualMaintainer
--   - Edit button updates → FrameController.VisualMaintainer
--   - Frame recovery → FrameController.Reconcile + DoFollowupSweep
--
-- GroupIconStateMaintainer (was ~120 lines):
--   - Group icon visuals → FrameController.VisualMaintainer
--   - Options panel state tracking → FrameController.VisualMaintainer
--   - Placeholder editing mode → FrameController.VisualMaintainer
--   - Group Layout triggers → FrameController.Reconcile
--
-- The hook functions above (HookFrameScale, HookFrameSize, etc.) are kept
-- as they're still called by CDMGroups.TrackFreeIcon and SetupFrameInSlot.
-- FrameController also installs its own hooks via InstallFrameHooks().
-- ═══════════════════════════════════════════════════════════════════════════