-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_FrameController.lua
-- UNIFIED FRAME MANAGEMENT - Replaces scattered maintenance systems
-- 
-- LOCATION: CDM_Module\CDM_Groups\ArcUI_FrameController.lua
-- LOAD ORDER: After Registry.lua, before Maintain.lua (or replaces it)
--
-- This is the SINGLE AUTHORITY for:
--   1. Detecting CDM rebuilds (NotifyListeners hook)
--   2. Scanning CDM viewers (ONE scan, not 30+)
--   3. Assigning frames to groups/free positions
--   4. Fighting CDM's attempts to reclaim frames (hooks)
--   5. Applying visual state to managed frames
-- ═══════════════════════════════════════════════════════════════════════════

local addonName, ns = ...

-- Profiler handler tracking (nil-safe if profiler not loaded)
local Track = _G.ArcUIProfiler_Track

-- Ensure namespace exists
ns.CDMGroups = ns.CDMGroups or {}
ns.FrameController = ns.FrameController or {}

local Controller = ns.FrameController

-- Dependencies
local Shared = ns.CDMShared
local Registry = ns.FrameRegistry

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME REBIND CALLBACK REGISTRY
--
-- CDM repools frames silently between events (spec change, talent change,
-- pet (un)summon, instance enter, vehicle exit, etc.). When a frame's
-- cooldownID rebinds, modules with per-frame caches keyed on that frame
-- (visual state, throttle caches, lookup caches in Display, etc.) need to
-- know so they can invalidate.
--
-- Architecture: SINGLE dispatch point. The mixin-level SetCooldownID hook
-- below already fires for every CDM rebind across all viewers — we just
-- add a callback registry to it. Each module subscribes once and gets
-- notified with (frame, oldCdID, newCdID). oldCdID may be nil (first bind),
-- newCdID may be nil (release via ClearCooldownID).
--
-- CPU cost: registry is a 1-3 entry array. Per rebind = O(N_subscribers)
-- function calls. Rebinds are rare events (login, spec change, etc.) so
-- the practical cost is negligible. No new tickers, no new event registrations.
--
-- Subscribers MUST NOT call any CDM API that touches secret data (no
-- frame:ShouldBeActive, no frame:GetAuraData) — same taint rules as anywhere.
-- ═══════════════════════════════════════════════════════════════════════════
local frameRebindSubscribers = {}

function Controller.OnFrameRebind(callback)
    if type(callback) ~= "function" then return end
    -- Idempotent: don't double-subscribe the same closure
    for _, existing in ipairs(frameRebindSubscribers) do
        if existing == callback then return end
    end
    frameRebindSubscribers[#frameRebindSubscribers + 1] = callback
end

local function DispatchFrameRebind(frame, oldCdID, newCdID)
    -- Synchronous dispatch — runs in same tick as CDM's SetCooldownID.
    -- Subscribers do their own targeted cleanup; failures in one
    -- subscriber don't affect others.
    for i = 1, #frameRebindSubscribers do
        local cb = frameRebindSubscribers[i]
        if cb then cb(frame, oldCdID, newCdID) end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- SECRET-SAFE AURA INSTANCE ID CHECK
-- auraInstanceID may become secret in future WoW versions
-- Uses ns.API.HasAuraInstanceID from Core.lua (handles secret values)
-- ═══════════════════════════════════════════════════════════════════════════
-- Live-frame aura presence: auraInstanceID == 0 is a valid self-aura (Voidfall),
-- not the saved-variable "no aura" default that HasAuraInstanceID rejects. nil = none.
local function HasFrameAura(value)
    return value ~= nil
end

local function HasAuraInstanceID(value)
    -- Use Core's implementation if available
    if ns.API and ns.API.HasAuraInstanceID then
        return ns.API.HasAuraInstanceID(value)
    end
    -- Fallback (shouldn't happen - Core loads first)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return true end
    if type(value) == "number" and value == 0 then return false end
    return value ~= nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════

local CONFIG = {
    -- Debounce times (seconds)
    -- CDM does multiple rebuild waves: immediate, +100-200ms, sometimes +500ms, rarely +1000ms
    DEBOUNCE_TALENT = 0.6,        -- Wait after talent changes (CDM does 2-3 rebuilds)
    DEBOUNCE_SPEC = 1.0,          -- Wait after spec changes (even more chaotic, 6-8 rebuilds)
    DEBOUNCE_NORMAL = 0.15,       -- Wait after normal CDM changes
    DEBOUNCE_FOLLOWUP = 0.25,     -- First follow-up sweep
    DEBOUNCE_FOLLOWUP2 = 1.5,     -- Second follow-up - CDM can swap frames up to 1.2s after!
    
    -- Visual maintainer throttle
    VISUAL_THROTTLE = 0.5,        -- 2Hz for visual updates (was 4Hz) - cut in half
    
    -- Protection window after reconcile
    POST_RECONCILE_PROTECTION = 0.2,
    
    -- Debug output
    DEBUG_ENABLED = false,
}

-- Allow runtime debug toggle
_G.ARCUI_FC_DEBUG = CONFIG.DEBUG_ENABLED

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME VALIDATION HELPER
-- Avoid creating anonymous functions in hot paths (causes GC pressure)
-- ═══════════════════════════════════════════════════════════════════════════

-- Check if a frame reference is still valid (not garbage collected or replaced)
local function IsFrameValid(frame)
    if not frame then return false end
    local getType = frame.GetObjectType
    if not getType then return false end
    return getType(frame) ~= nil
end

-- Check if frame is hidden by bar tracking (with cooldownID verification)
local function IsFrameHiddenByBar(frame)
    if not frame then return false end
    if ns.CDMEnhance and ns.CDMEnhance.IsFrameHiddenByBar then
        return ns.CDMEnhance.IsFrameHiddenByBar(frame)
    end
    return frame._arcHiddenByBar == true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

-- Forward declarations for functions used before definition
local InstallFrameHooks
local CountTable

local state = {
    -- Processing flags
    isProcessing = false,           -- TRUE during reconcile
    lastReconcileTime = 0,          -- GetTime() of last reconcile
    protectionEndTime = 0,          -- Block other systems until this time
    
    -- Debounce state
    pendingReconcile = false,
    lastEventTime = 0,
    currentDebounceTime = CONFIG.DEBOUNCE_NORMAL,
    
    -- Event tracking
    specChangeDetected = false,
    talentChangeDetected = false,
    layoutChangeDetected = false,   -- Set when profile/layout is loaded (needs frame visibility fix)
    
    -- Hooks installed
    hooksInstalled = false,
    frameHooksInstalled = {},       -- frame address -> true
    
    -- Stats
    stats = {
        reconcileCount = 0,
        framesAssigned = 0,
        framesRecovered = 0,
        hookFights = { position = 0, scale = 0, size = 0, strata = 0 },
    },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME HOOK CALLBACKS (extracted for profiler tracking)
-- ═══════════════════════════════════════════════════════════════════════════

local function FcOnClearAllPoints(self)
    if self._cdmgSettingPosition then return end
    if self._freeDragging or self._groupDragging then return end
    
    local parent = self:GetParent()
    if not parent then return end
    
    -- Check if in container
    if parent._isCDMGContainer and self._cdmgTargetPoint then
        self._cdmgSettingPosition = true
        self:SetPoint(
            self._cdmgTargetPoint,
            parent,
            self._cdmgTargetRelPoint or "TOPLEFT",
            self._cdmgTargetX or 0,
            self._cdmgTargetY or 0
        )
        self._cdmgSettingPosition = false
        state.stats.hookFights.position = state.stats.hookFights.position + 1
    end
end

local function FcOnSetScale(self, scale)
    if self._cdmgSettingScale then return end
    if self._arcAuraID then return end
    if issecretvalue and issecretvalue(scale) then return end
    
    local parent = self:GetParent()
    local isManaged = (parent and parent._isCDMGContainer) or self._cdmgIsFreeIcon
    
    if isManaged and math.abs((scale or 1) - 1) > 0.01 then
        self._cdmgSettingScale = true
        self:SetScale(1)
        self._cdmgSettingScale = false
        state.stats.hookFights.scale = state.stats.hookFights.scale + 1
    end
end

local function FcOnSetSize(self, w, h)
    if self._cdmgSettingSize then return end
    if self._arcAuraID then return end
    if issecretvalue and (issecretvalue(w) or issecretvalue(h)) then return end
    
    local parent = self:GetParent()
    local isInContainer = parent and parent._isCDMGContainer
    local isFreeIcon = self._cdmgIsFreeIcon
    
    if not isInContainer and not isFreeIcon then return end
    
    local targetW, targetH
    local cdID = self.cooldownID
    
    if cdID and ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettings then
        local cfg = ns.CDMEnhance.GetEffectiveIconSettings(cdID)
        if cfg then
            if isFreeIcon then
                local freeData = cdID and ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[cdID]
                local baseW = cfg.width or (freeData and freeData.iconSize) or 36
                local baseH = cfg.height or (freeData and freeData.iconSize) or 36
                local scale = cfg.scale or 1.0
                targetW = baseW * scale
                targetH = baseH * scale
            elseif cfg.useGroupScale == false then
                local baseW = cfg.width or 36
                local baseH = cfg.height or 36
                local scale = cfg.scale or 1.0
                targetW = baseW * scale
                targetH = baseH * scale
            end
        end
    end
    
    if not targetW then
        if isFreeIcon then
            local freeData = cdID and ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[cdID]
            targetW = freeData and freeData.iconSize or self._cdmgFreeTargetSize or 36
            targetH = targetW
        else
            targetW = self._cdmgTargetSize or 36
            targetH = targetW
        end
    end
    
    if math.abs((w or 0) - targetW) > 0.5 or math.abs((h or 0) - targetH) > 0.5 then
        self._cdmgSettingSize = true
        self:SetSize(targetW, targetH)
        self._cdmgSettingSize = false
        state.stats.hookFights.size = state.stats.hookFights.size + 1
    end
end

local function FcOnSetFrameStrata(self, strata)
    if self._cdmgSettingStrata then return end
    
    local parent = self:GetParent()
    local isInContainer = parent and parent._isCDMGContainer
    local isFreeIcon = self._cdmgIsFreeIcon
    local isManaged = isInContainer or isFreeIcon
    
    if isManaged then
        local expectedStrata = (isInContainer and parent._cdmgFrameStrata) or "MEDIUM"
        if strata ~= expectedStrata then
            self._cdmgSettingStrata = true
            self:SetFrameStrata(expectedStrata)
            self._cdmgSettingStrata = false
            state.stats.hookFights.strata = state.stats.hookFights.strata + 1
        end
    end
end

-- Wrap for profiler (nil-safe)
state._trackedFcClearAllPoints  = Track and Track("FC.ClearAllPoints",  FcOnClearAllPoints) or FcOnClearAllPoints
state._trackedFcSetScale        = Track and Track("FC.SetScale",        FcOnSetScale) or FcOnSetScale
state._trackedFcSetSize         = Track and Track("FC.SetSize",         FcOnSetSize) or FcOnSetSize
state._trackedFcSetFrameStrata  = Track and Track("FC.SetFrameStrata",  FcOnSetFrameStrata) or FcOnSetFrameStrata
-- ═══════════════════════════════════════════════════════════════════════════

local function Debug(...)
    if _G.ARCUI_FC_DEBUG then
        print("|cff00FFFF[FrameController]|r", ...)
    end
end

local function DebugEvent(event, ...)
    if _G.ARCUI_FC_DEBUG then
        print("|cffFFFF00[FC Event]|r", event, ...)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TIMELINE DEBUGGER
-- Tracks events, actions, and frame changes for debugging talent/spec changes
-- ═══════════════════════════════════════════════════════════════════════════

local timeline = {}
local timelineEnabled = false
local timelineStartTime = 0
local MAX_TIMELINE_ENTRIES = 200

-- Enable timeline recording
_G.ARCUI_FC_TIMELINE = false

-- External callback for debugger to hook into
local externalTimelineCallback = nil

-- Get short source from debugstack (file:line) - WoW's sandboxed alternative to debug.getinfo
local function GetCallSource(skipLevels)
    skipLevels = skipLevels or 3  -- Skip: GetCallSource, TimelineAdd, actual caller
    local stack = debugstack(skipLevels, 1, 0)
    if not stack then return nil end
    
    -- Extract filename and line from stack trace
    -- Format: "path/to/File.lua:123: in function..."
    local file, line = stack:match("([^/\\]+%.lua):(%d+)")
    if file and line then
        -- Shorten known files
        if file:find("ArcUI") then
            return "ARC:" .. file:gsub("ArcUI_", ""):gsub("%.lua", "") .. ":" .. line
        elseif file:find("Cooldown") or file:find("Buff") then
            return "CDM:" .. file:gsub("%.lua", "") .. ":" .. line
        else
            return file:gsub("%.lua", "") .. ":" .. line
        end
    end
    
    return nil
end

local function TimelineAdd(category, action, details)
    -- Get caller source for debugging
    local source = GetCallSource(3)
    
    -- Always call external callback if set (for debugger integration)
    if externalTimelineCallback then
        externalTimelineCallback(category, action, details, source)
    end
    
    if not _G.ARCUI_FC_TIMELINE then return end
    
    if timelineStartTime == 0 then
        timelineStartTime = GetTime()
    end
    
    local entry = {
        time = GetTime() - timelineStartTime,
        category = category,
        action = action,
        details = details or "",
        timestamp = date("%H:%M:%S"),
        source = source,
    }
    
    table.insert(timeline, entry)
    
    -- Trim old entries
    while #timeline > MAX_TIMELINE_ENTRIES do
        table.remove(timeline, 1)
    end
    
    -- Also print if debug is on
    if _G.ARCUI_FC_DEBUG then
        local color = "|cff888888"
        if category == "EVENT" then color = "|cffFFFF00"
        elseif category == "ACTION" then color = "|cff00FF00"
        elseif category == "FRAME" then color = "|cff00FFFF"
        elseif category == "CDM" then color = "|cffFF8800"
        elseif category == "ERROR" then color = "|cffFF0000"
        end
        print(string.format("%s[%.3f] [%s] %s|r %s", color, entry.time, category, action, details or ""))
    end
end

-- Allow external modules to hook into timeline
local function SetTimelineCallback(callback)
    externalTimelineCallback = callback
end

-- Clear timeline
local function TimelineClear()
    wipe(timeline)
    timelineStartTime = 0
end

-- Print timeline
local function TimelinePrint(filter, count)
    count = count or 50
    print("|cff00FFFF═══════════════════════════════════════════════════════════════|r")
    print("|cff00FFFF  FRAMECONTROLLER TIMELINE|r")
    print("|cff00FFFF═══════════════════════════════════════════════════════════════|r")
    
    if #timeline == 0 then
        print("  No events recorded. Enable with: /arcuifc timeline on")
        return
    end
    
    local printed = 0
    for i = math.max(1, #timeline - count + 1), #timeline do
        local e = timeline[i]
        if e and (not filter or e.category == filter:upper() or e.action:find(filter)) then
            local color = "|cff888888"
            if e.category == "EVENT" then color = "|cffFFFF00"
            elseif e.category == "ACTION" then color = "|cff00FF00"
            elseif e.category == "FRAME" then color = "|cff00FFFF"
            elseif e.category == "CDM" then color = "|cffFF8800"
            elseif e.category == "ERROR" then color = "|cffFF0000"
            end
            local sourceStr = e.source and (" |cff666666[" .. e.source .. "]|r") or ""
            print(string.format("  %s[%6.3f] [%-6s] %-30s|r %s%s", 
                color, e.time, e.category, e.action, e.details or "", sourceStr))
            printed = printed + 1
        end
    end
    
    print("|cff00FFFF═══════════════════════════════════════════════════════════════|r")
    print(string.format("  Showing %d of %d entries", printed, #timeline))
end

-- Export for external access
Controller.Timeline = {
    Add = TimelineAdd,
    Clear = TimelineClear,
    Print = TimelinePrint,
    GetEntries = function() return timeline end,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- PROTECTION CHECKING
-- ═══════════════════════════════════════════════════════════════════════════

-- Check if controller is currently processing (other systems should yield)
function Controller.IsProcessing()
    if state.isProcessing then return true end
    if GetTime() < state.protectionEndTime then return true end
    return false
end

-- Check if we're in a protection window (for external systems)
function Controller.IsInProtection()
    return GetTime() < state.protectionEndTime
end

-- Set protection window
local function SetProtection(duration)
    state.protectionEndTime = GetTime() + (duration or CONFIG.POST_RECONCILE_PROTECTION)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPER: Check if CDMGroups is enabled
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- MODULE-LEVEL CACHED ENABLED STATE
-- Direct boolean check - NO function call overhead
-- Updated by RefreshCachedEnabledState() on settings change
-- ═══════════════════════════════════════════════════════════════════════════
local _cdmGroupsEnabled = true  -- Module-level boolean, assume enabled until init

local function RefreshCachedEnabledState()
    local db = Shared and Shared.GetCDMGroupsDB and Shared.GetCDMGroupsDB()
    _cdmGroupsEnabled = db and db.enabled ~= false
end

-- Export for other modules to call when settings change
Controller.RefreshCachedEnabledState = RefreshCachedEnabledState

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPER: Get viewer info for a cooldownID
-- ═══════════════════════════════════════════════════════════════════════════

local function GetViewerInfoForCooldownID(cdID)
    if not cdID then return nil end
    
    -- Use safe wrapper (handles string IDs from Arc Auras)
    local viewerType, defaultGroup = Shared.GetViewerTypeFromCooldownID(cdID)
    if not viewerType then return nil, nil, nil end
    
    -- Map viewerType to viewer name
    local viewerName
    if viewerType == "aura" then
        viewerName = "BuffIconCooldownViewer"
    elseif viewerType == "utility" then
        viewerName = "UtilityCooldownViewer"
    elseif viewerType == "custom" then
        viewerName = "ArcAurasViewer"
    else
        viewerName = "EssentialCooldownViewer"
    end
    
    return viewerType, defaultGroup, viewerName
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CORE: SCAN CDM VIEWERS
-- This is THE ONLY place that should scan CDM viewers
-- Returns: { [cooldownID] = { frame, viewerName, viewerType, layoutIndex } }
-- ═══════════════════════════════════════════════════════════════════════════

local function ScanCDMViewers()
    local cdmState = {}
    local CDM_VIEWERS = Shared and Shared.CDM_VIEWERS or {}
    
    for _, viewerInfo in ipairs(CDM_VIEWERS) do
        -- Skip bar viewer (we don't manage bars)
        if not viewerInfo.skipInGroups then
            local viewer = _G[viewerInfo.name]
            if viewer and viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    local cdID = frame.cooldownID
                    if cdID then
                        cdmState[cdID] = {
                            frame = frame,
                            viewerName = viewerInfo.name,
                            viewerType = viewerInfo.type,
                            defaultGroup = viewerInfo.defaultGroup,
                            layoutIndex = frame.layoutIndex,
                            isShown = frame:IsShown(),
                            isActive = frame.isActive,
                            auraInstanceID = frame.auraInstanceID,
                        }
                    end
                end
            end
        end
    end
    
    Debug("ScanCDMViewers: Found", CountTable(cdmState), "cooldownIDs")
    return cdmState
end
ScanCDMViewers = (Track and Track("FC.ScanCDMViewers", ScanCDMViewers)) or ScanCDMViewers

-- Helper to count table entries
CountTable = function(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CORE: ASSIGN FRAME TO OWNER
-- Takes a frame and assigns it to its saved position (group or free)
-- ═══════════════════════════════════════════════════════════════════════════

-- Check if an aura frame should be hidden from grid for dynamic layout
-- Returns true if: dynamicLayout enabled AND aura AND aura is inactive
-- NOTE: This is PURELY aura-state-based (auraInstanceID/totem), NOT frame visibility
local function ShouldHideFromDynamicGrid(group, frame, viewerType)
    if not group or not group.dynamicLayout then
        return false
    end
    
    -- Only affects aura frames
    if viewerType ~= "aura" then
        return false
    end
    
    if not frame then
        return true  -- No frame = can't position
    end
    
    local ArcUI = ArcUI_NS
    
    -- First check: Is this a totem?
    local GetTotemState = ArcUI and ArcUI.CDMEnhance and ArcUI.CDMEnhance.GetTotemState
    if GetTotemState then
        local isTotem, isTotemActive = GetTotemState(frame)
        if isTotem then
            return not isTotemActive  -- Hide from grid if totem inactive
        end
    end
    
    -- Second check: Regular aura with auraInstanceID (secret-safe)
    if HasAuraInstanceID(frame.auraInstanceID) then
        -- Has a real auraInstanceID - check if still active
        local CS = ArcUI and ArcUI.CooldownState
        if CS and CS.IsAuraActive then
            local isActive = CS.IsAuraActive(frame.auraInstanceID)
            return not isActive  -- Hide from grid if inactive
        end
        return false  -- Can't verify, assume active
    elseif HasFrameAura(frame.auraInstanceID) then
        -- Self-aura: auraInstanceID == 0 means the aura EXISTS but has no queryable
        -- instance id (e.g. Voidfall). Keep it in the grid; don't query with 0.
        return false
    end

    -- No aura instance (nil) and not a totem = aura not active
    -- Hide from grid (treat as gap)
    return true
end

local function AssignFrameToGroup(cdID, frame, groupName, row, col, viewerType, viewerName)
    local group = ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]
    if not group then
        Debug("AssignFrameToGroup: Group", groupName, "not found for cdID", cdID)
        return false
    end
    
    -- CRITICAL: Detect if this was a placeholder becoming real
    -- If so, we need to restore all icons to their saved positions first
    local wasPlaceholder = false
    local member = group.members[cdID]
    if member and member.isPlaceholder then
        wasPlaceholder = true
    end
    if ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID] and ns.CDMGroups.savedPositions[cdID].isPlaceholder then
        wasPlaceholder = true
    end
    
    -- CRITICAL: Hide any placeholder for this cdID immediately
    -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
    if type(cdID) == "number" and ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.HidePlaceholder then
        ns.CDMGroups.Placeholders.HidePlaceholder(cdID)
    end
    
    -- Clear placeholder flag in savedPositions since we now have a real frame
    if ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID] then
        ns.CDMGroups.savedPositions[cdID].isPlaceholder = nil
    end
    
    -- CRITICAL: If a placeholder becomes real and group has autoReflow:
    -- 1. PUSH any real frame at the saved position first
    -- 2. Restore ALL icons to their saved positions  
    -- 3. This ensures the new icon can claim its saved position
    -- 4. Icons that reflowed into that position go back to their own saved positions
    -- 5. If options panel is closed, trigger ReflowIcons to compact gaps
    local needsPostReflow = false
    if wasPlaceholder then
        -- Get the saved position this placeholder wants to claim
        local saved = ns.CDMGroups.savedPositions[cdID]
        local targetRow = saved and saved.row or (member and member.row) or row or 0
        local targetCol = saved and saved.col or (member and member.col) or col or 0
        
        -- PUSH LOGIC: Push any real frame at this position to make room
        -- This prevents position conflicts when placeholder becomes real
        -- Pass cdID so slot-sharing (mutually exclusive talents) is detected
        if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.PushFramesFromSlot then
            Debug("AssignFrameToGroup: Placeholder->real, pushing frames from [%d,%d]", targetRow, targetCol)
            ns.CDMGroups.Placeholders.PushFramesFromSlot(group, targetRow, targetCol, cdID)
        end
        
        if group.autoReflow and group.RestoreToSavedPositions then
            Debug("AssignFrameToGroup: Placeholder->real, restoring group to saved positions")
            group:RestoreToSavedPositions()
            -- Re-fetch member after restore (it should still exist)
            member = group.members[cdID]
            
            -- Check if options panel is closed - if so, we need to reflow after assignment
            -- Note: IsOptionsPanelOpen() now checks BOTH ArcUI and CDM panels
            local panelOpen = ns.CDMGroups.IsOptionsPanelOpen and ns.CDMGroups.IsOptionsPanelOpen()
            if not panelOpen then
                needsPostReflow = true
            end
        end
    end
    
    -- Get or create member entry
    if not member then
        -- Create new member at specified position
        member = {
            cooldownID = cdID,
            row = row or 0,
            col = col or 0,
            viewerType = viewerType,
            originalViewerName = viewerName,
        }
        group.members[cdID] = member
        
        -- Update grid (skip if hidden aura in dynamic layout)
        if group.grid and not ShouldHideFromDynamicGrid(group, frame, viewerType) then
            group.grid[row] = group.grid[row] or {}
            group.grid[row][col] = cdID
        end
    else
        -- Check if this is a hidden aura that should be removed from grid
        local shouldHide = ShouldHideFromDynamicGrid(group, frame, viewerType or member.viewerType)
        
        if shouldHide then
            -- Remove from grid if present (dynamic layout hides inactive auras)
            if group.grid and member.row ~= nil and member.col ~= nil then
                if group.grid[member.row] and group.grid[member.row][member.col] == cdID then
                    group.grid[member.row][member.col] = nil
                end
            end
            -- Keep member.row/col unchanged so it knows where to go when aura activates
        else
            -- Existing member - update row/col from savedPositions (authoritative)
            -- This is important when converting a placeholder to real frame
            -- because placeholder's member.row/col may have become stale
            local oldRow, oldCol = member.row, member.col
            if row ~= oldRow or col ~= oldCol then
                -- Clear old grid position
                if group.grid and oldRow ~= nil and oldCol ~= nil and group.grid[oldRow] then
                    if group.grid[oldRow][oldCol] == cdID then
                        group.grid[oldRow][oldCol] = nil
                    end
                end
                -- Update member position
                member.row = row or 0
                member.col = col or 0
                -- Update grid
                if group.grid then
                    group.grid[row] = group.grid[row] or {}
                    group.grid[row][col] = cdID
                end
            end
        end
    end
    
    -- Clean up old frame if different
    if member.frame and member.frame ~= frame then
        -- Return old frame to CDM
        if ns.CDMGroups.ReturnFrameToCDM then
            ns.CDMGroups.ReturnFrameToCDM(member.frame, member.entry)
        end
    end
    
    -- Assign new frame and clear placeholder status
    member.frame = frame
    member.frameLostAt = nil
    member.isPlaceholder = nil  -- No longer a placeholder
    member.placeholderInfo = nil
    
    -- CRITICAL: Notify DynamicLayout that placeholder was resolved
    -- This clears stale visibility tracking so the real frame is properly detected
    if ns.CDMGroups.DynamicLayout and ns.CDMGroups.DynamicLayout.OnPlaceholderResolved then
        ns.CDMGroups.DynamicLayout.OnPlaceholderResolved(cdID, groupName)
    end
    
    -- Update cooldownCatalog with new frame reference
    if ns.CDMGroups.cooldownCatalog then
        ns.CDMGroups.cooldownCatalog[cdID] = {
            cooldownID = cdID,
            frame = frame,
            viewerType = viewerType,
            viewerName = viewerName,
            group = groupName,
            row = row,
            col = col,
        }
    end
    
    -- Register in registry
    if Registry and Registry.Register then
        member.entry = Registry:Register(frame, viewerName)
        if member.entry then
            member.entry.manipulated = true
            member.entry.group = group
        end
    end
    
    -- Setup frame in container
    if ns.CDMGroups.SetupFrameInContainer then
        local slotW, slotH = 36, 36
        if ns.CDMGroups.GetSlotDimensions and group.layout then
            slotW, slotH = ns.CDMGroups.GetSlotDimensions(group.layout)
        end
        ns.CDMGroups.SetupFrameInContainer(frame, group.container, slotW, slotH, cdID)
    else
        -- Fallback: basic setup
        frame:SetParent(group.container)
        frame:SetFrameStrata(group.container._cdmgFrameStrata or "MEDIUM")
        frame:SetScale(1)
        if not (frame._arcIsArcAura or frame._arcAuraID) then frame:SetAlpha(1) end
    end
    
    -- Ensure frame is shown (unless hidden by bar tracking or unequipped hiding)
    if not frame._arcHiddenUnequipped and not IsFrameHiddenByBar(frame) then
        frame:Show()
    end
    
    -- Install frame hooks
    InstallFrameHooks(frame)
    
    -- Apply enhancements (skip during heavy processing)
    if not state.specChangeDetected and ns.CDMEnhance and ns.CDMEnhance.EnhanceFrame then
        ns.CDMEnhance.EnhanceFrame(frame, cdID, viewerType, viewerName)
    end
    
    -- CRITICAL: If placeholder became real and options panel is closed, trigger reflow
    -- This compacts any gaps from the restored saved positions
    if needsPostReflow and group.ReflowIcons then
        Debug("AssignFrameToGroup: Triggering post-placeholder reflow")
        group:ReflowIcons()
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- SAVE POSITION: Ensure savedPositions is updated
    -- This is important for NEW icons that didn't go through AddMember
    -- ═══════════════════════════════════════════════════════════════════════════
    -- CRITICAL FIX: Use GetProfileSavedPositions to ensure we write to the correct table
    -- This verifies the reference before every write
    -- ═══════════════════════════════════════════════════════════════════════════
    local profileSavedPositions = ns.CDMGroups.GetProfileSavedPositions and ns.CDMGroups.GetProfileSavedPositions()
    local savedPositions = profileSavedPositions or ns.CDMGroups.savedPositions
    
    local hadSavedPosition = savedPositions and savedPositions[cdID] ~= nil
    if not hadSavedPosition and not ns.CDMGroups._blockPositionSaves then
        -- Only save if profile is fully loaded
        local profileFullyLoaded = not ns.CDMGroups.initialLoadInProgress and 
                                   not ns.CDMGroups._profileNotLoaded
        if profileFullyLoaded and savedPositions then
            -- COLLISION GUARD (same intent as the post-reconcile save pass): never mint a
            -- duplicate saved slot. If another saved icon in this group already owns
            -- (member.row, member.col), skip persisting now - it resolves on the next clean
            -- reconcile/reload. Recognized slot partners always already HAVE a saved position
            -- (hadSavedPosition is true above, so we never reach here), so this cannot break them.
            local r, c = member.row or 0, member.col or 0
            local slotTaken = false
            for ocdID, osaved in pairs(savedPositions) do
                if ocdID ~= cdID and type(osaved) == "table" and osaved.type == "group"
                   and osaved.target == groupName and (osaved.row or 0) == r and (osaved.col or 0) == c then
                    slotTaken = true
                    break
                end
            end
            if slotTaken then
                Debug("AssignFrameToGroup: SKIP duplicate slot for", cdID, "->", groupName)
            else
                local positionData = {
                    type = "group",
                    target = groupName,
                    row = member.row,
                    col = member.col,
                    viewerType = viewerType or member.viewerType,
                }
                -- Write to verified profile table
                savedPositions[cdID] = positionData

                -- Also call SavePositionToSpec for any additional processing
                if ns.CDMGroups.SavePositionToSpec then
                    ns.CDMGroups.SavePositionToSpec(cdID, positionData)
                end
                Debug("AssignFrameToGroup: Saved NEW position for", cdID)
            end
        end
    end
    
    -- Setup drag handlers for member
    if group.SetupMemberDrag then
        group:SetupMemberDrag(cdID)
    end
    
    state.stats.framesAssigned = state.stats.framesAssigned + 1
    Debug("AssignFrameToGroup:", cdID, "->", groupName, "[" .. (row or 0) .. "," .. (col or 0) .. "]")
    return true
end
AssignFrameToGroup = (Track and Track("FC.AssignFrameToGroup", AssignFrameToGroup)) or AssignFrameToGroup

local function AssignFrameToFree(cdID, frame, x, y, iconSize, viewerType, viewerName)
    ns.CDMGroups.freeIcons = ns.CDMGroups.freeIcons or {}
    
    -- Ensure defaults
    x = x or 0
    y = y or 0
    iconSize = iconSize or 36
    
    -- CRITICAL: Hide any placeholder for this cdID immediately
    -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
    if type(cdID) == "number" and ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.HidePlaceholder then
        ns.CDMGroups.Placeholders.HidePlaceholder(cdID)
    end
    
    -- Clear placeholder flag in savedPositions since we now have a real frame
    if ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID] then
        ns.CDMGroups.savedPositions[cdID].isPlaceholder = nil
    end
    
    -- Clean up old frame if different
    local existing = ns.CDMGroups.freeIcons[cdID]
    if existing and existing.frame and existing.frame ~= frame then
        if ns.CDMGroups.ReturnFrameToCDM then
            ns.CDMGroups.ReturnFrameToCDM(existing.frame, existing.entry)
        end
    end
    
    -- Register in registry
    local entry = nil
    if Registry and Registry.Register then
        entry = Registry:Register(frame, viewerName)
        if entry then
            entry.manipulated = true
            entry.manipulationType = "free"
            entry.originalParent = entry.originalParent or frame:GetParent()
        end
    end
    
    -- Store free icon data
    ns.CDMGroups.freeIcons[cdID] = {
        frame = frame,
        entry = entry,
        originalParent = entry and entry.originalParent,
        x = x,
        y = y,
        iconSize = iconSize,
        viewerType = viewerType,
        originalViewerName = viewerName,
    }
    
    -- Update cooldownCatalog with new frame reference
    if ns.CDMGroups.cooldownCatalog then
        ns.CDMGroups.cooldownCatalog[cdID] = {
            cooldownID = cdID,
            frame = frame,
            viewerType = viewerType,
            viewerName = viewerName,
            isFree = true,
            x = x,
            y = y,
        }
    end
    
    -- Mark as free icon for hooks (BEFORE any frame manipulation)
    frame._cdmgIsFreeIcon = true
    frame._cdmgFreeTargetSize = iconSize
    
    -- Setup frame
    frame:SetParent(UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetScale(1)
    frame:SetSize(iconSize, iconSize)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
    
    -- Only show if not hidden due to hideWhenUnequipped or bar tracking settings
    if not frame._arcHiddenUnequipped and not IsFrameHiddenByBar(frame) then
        if not (frame._arcIsArcAura or frame._arcAuraID) then frame:SetAlpha(1) end
        frame:Show()
    end
    
    -- Install frame hooks (generic hooks for position/scale/size/strata)
    InstallFrameHooks(frame)
    
    -- Install free-icon-specific hooks from Maintain.lua
    if ns.CDMGroups.HookFrameScale then
        ns.CDMGroups.HookFrameScale(frame)
    end
    if ns.CDMGroups.HookFrameSize then
        ns.CDMGroups.HookFrameSize(frame, iconSize)
    end
    if ns.CDMGroups.HookFrameParent then
        ns.CDMGroups.HookFrameParent(frame)
    end
    if ns.CDMGroups.HookFrameClearAllPointsFree then
        ns.CDMGroups.HookFrameClearAllPointsFree(frame)
    end
    
    -- Apply enhancements
    if not state.specChangeDetected and ns.CDMEnhance and ns.CDMEnhance.EnhanceFrame then
        ns.CDMEnhance.EnhanceFrame(frame, cdID, viewerType, viewerName)
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- CRITICAL FIX: Use GetProfileSavedPositions to ensure we write to the correct table
    -- This verifies the reference before every write
    -- ═══════════════════════════════════════════════════════════════════════════
    local positionData = {
        type = "free",
        x = x,
        y = y,
        iconSize = iconSize,
        viewerType = viewerType,
    }
    
    -- Get verified profile table and write to it
    -- CRITICAL: Only write to profile when it's fully loaded.
    -- If profile isn't loaded yet, savedPositions is empty and writing here would
    -- overwrite the correct saved group/free position with a spurious free-icon entry.
    local profileFullyLoaded = not ns.CDMGroups.initialLoadInProgress and
                               not ns.CDMGroups._profileNotLoaded
    local profileSavedPositions = ns.CDMGroups.GetProfileSavedPositions and ns.CDMGroups.GetProfileSavedPositions()
    if profileFullyLoaded and profileSavedPositions then
        profileSavedPositions[cdID] = positionData
    end
    
    -- Also call SavePositionToSpec for any additional processing
    if ns.CDMGroups.SavePositionToSpec then
        ns.CDMGroups.SavePositionToSpec(cdID, positionData)
    end
    
    -- Also save to freeIcons spec data (separate table with runtime fields)
    if ns.CDMGroups.SaveFreeIconToSpec then
        ns.CDMGroups.SaveFreeIconToSpec(cdID, { x = x, y = y, iconSize = iconSize })
    end
    
    -- Setup drag handlers for free icon
    if ns.CDMGroups.SetupFreeIconDrag then
        ns.CDMGroups.SetupFreeIconDrag(cdID)
    end
    
    state.stats.framesAssigned = state.stats.framesAssigned + 1
    Debug("AssignFrameToFree:", cdID, "at", x, y, "(saved)")
    return true
end

local function AssignFrameToOwner(cdID, cdmData)
    local frame = cdmData.frame
    local viewerType = cdmData.viewerType
    local viewerName = cdmData.viewerName
    local defaultGroup = cdmData.defaultGroup
    
    -- Check savedPositions for existing assignment
    local saved = ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID]
    
    if saved then
        if saved.type == "group" and saved.target then
            -- Has saved group position
            local targetGroup = ns.CDMGroups.groups and ns.CDMGroups.groups[saved.target]
            local targetRow, targetCol = saved.row, saved.col
            
            -- DYNAMIC LAYOUT: Use current member position (from reflow), not saved position
            -- This preserves the compacted layout that ReflowIcons created
            if targetGroup and targetGroup.dynamicLayout and targetGroup.members then
                local member = targetGroup.members[cdID]
                if member and member.row ~= nil and member.col ~= nil then
                    targetRow = member.row
                    targetCol = member.col
                end
            end
            
            return AssignFrameToGroup(cdID, frame, saved.target, targetRow, targetCol, viewerType, viewerName)
        elseif saved.type == "free" then
            return AssignFrameToFree(cdID, frame, saved.x, saved.y, saved.iconSize, viewerType, viewerName)
        end
    end
    
    -- No saved position - check if already in a group
    for groupName, group in pairs(ns.CDMGroups.groups or {}) do
        if group.members and group.members[cdID] then
            local member = group.members[cdID]
            return AssignFrameToGroup(cdID, frame, groupName, member.row, member.col, viewerType, viewerName)
        end
    end
    
    -- Check if already a free icon
    if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[cdID] then
        local freeData = ns.CDMGroups.freeIcons[cdID]
        return AssignFrameToFree(cdID, frame, freeData.x, freeData.y, freeData.iconSize, viewerType, viewerName)
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- TRULY NEW ICON (no saved position, not in any group, not a free icon)
    -- ═══════════════════════════════════════════════════════════════════════════
    
    -- CHECK IMPORT MODE: If active, unknown icons go to free positions
    if ns.CDMGroups.ImportRestore and ns.CDMGroups.ImportRestore.GetPlacementOverride then
        -- Check savedPositions with both key types (number and string) for consistency
        local hasSavedPosition = false
        if ns.CDMGroups.savedPositions then
            hasSavedPosition = ns.CDMGroups.savedPositions[cdID] ~= nil
            -- Also try string key if numeric
            if not hasSavedPosition and type(cdID) == "number" then
                hasSavedPosition = ns.CDMGroups.savedPositions[tostring(cdID)] ~= nil
            end
            -- Also try number key if string
            if not hasSavedPosition and type(cdID) == "string" then
                local numID = tonumber(cdID)
                if numID then
                    hasSavedPosition = ns.CDMGroups.savedPositions[numID] ~= nil
                end
            end
        end
        local importOverride = ns.CDMGroups.ImportRestore.GetPlacementOverride(cdID, hasSavedPosition)
        
        if importOverride and importOverride.type == "free" then
            -- Place as free icon during import mode
            Debug("AssignFrameToOwner: Import mode override - placing as free icon at", importOverride.x, importOverride.y)
            return AssignFrameToFree(cdID, frame, importOverride.x, importOverride.y, importOverride.iconSize, viewerType, viewerName)
        end
    end
    
    -- Define base groups that should always exist
    local BASE_GROUPS = { "Essential", "Utility", "Buffs" }
    
    -- Try to assign to default group first
    if defaultGroup and ns.CDMGroups.groups then
        -- If group doesn't exist but it's a base group, try to create it
        if not ns.CDMGroups.groups[defaultGroup] then
            for _, baseName in ipairs(BASE_GROUPS) do
                if defaultGroup == baseName then
                    -- Create the base group
                    if ns.CDMGroups.CreateGroup then
                        Debug("AssignFrameToOwner: Creating missing base group", defaultGroup)
                        ns.CDMGroups.CreateGroup(defaultGroup)
                    end
                    break
                end
            end
        end
        
        -- Now try to add to the group
        local group = ns.CDMGroups.groups[defaultGroup]
        if group and group.AddMember then
            local added = group:AddMember(cdID)
            if added then
                -- AddMember created the member, now assign the frame
                local member = group.members[cdID]
                if member then
                    return AssignFrameToGroup(cdID, frame, defaultGroup, member.row, member.col, viewerType, viewerName)
                end
            end
        end
    end
    
    -- defaultGroup didn't work - try ANY existing base group as fallback
    if ns.CDMGroups.groups then
        for _, baseName in ipairs(BASE_GROUPS) do
            local group = ns.CDMGroups.groups[baseName]
            if group and group.AddMember then
                local added = group:AddMember(cdID)
                if added then
                    local member = group.members[cdID]
                    if member then
                        Debug("AssignFrameToOwner: Assigned to fallback group", baseName)
                        return AssignFrameToGroup(cdID, frame, baseName, member.row, member.col, viewerType, viewerName)
                    end
                end
            end
        end
    end
    
    -- NO BASE GROUPS AVAILABLE: Create as free icon in a line formation
    -- This handles when all default groups have been deleted by the user
    -- Count existing free icons to calculate line position (avoid stacking)
    local freeIconCount = 0
    if ns.CDMGroups.freeIcons then
        for _ in pairs(ns.CDMGroups.freeIcons) do
            freeIconCount = freeIconCount + 1
        end
    end
    
    -- Position in a horizontal line, starting from center
    -- Each icon offset by 45 pixels to avoid stacking
    local iconSize = 36
    local spacing = 45
    local iconsPerRow = 10
    local startX = -((math.min(freeIconCount, iconsPerRow - 1)) * spacing) / 2
    local rowOffset = math.floor(freeIconCount / iconsPerRow) * spacing
    
    local freeX = startX + (freeIconCount % iconsPerRow) * spacing
    local freeY = 100 - rowOffset  -- Start above center, move down for each row
    
    Debug("AssignFrameToOwner: No default group for cdID", cdID, "- creating as free icon at", freeX, freeY)
    return AssignFrameToFree(cdID, frame, freeX, freeY, iconSize, viewerType, viewerName)
end
AssignFrameToOwner = (Track and Track("FC.AssignFrameToOwner", AssignFrameToOwner)) or AssignFrameToOwner

-- ═══════════════════════════════════════════════════════════════════════════
-- CORE: RECONCILE
-- The main reconciliation function - runs after debounce
-- ═══════════════════════════════════════════════════════════════════════════

local function Reconcile()
    if not _cdmGroupsEnabled then
        Debug("Reconcile: CDMGroups disabled, skipping")
        TimelineAdd("ACTION", "RECONCILE_SKIP", "CDMGroups disabled")
        state.pendingReconcile = false
        return
    end
    
    -- CRITICAL FIX: Don't reconcile until profile is loaded!
    -- FrameController can run before CDMGroups.Initialize() completes.
    -- If we reconcile now, savedPositions is empty and icons get wrong positions.
    if ns.CDMGroups._profileNotLoaded then
        Debug("Reconcile: Profile not loaded yet, deferring...")
        TimelineAdd("ACTION", "RECONCILE_DEFERRED", "Profile not loaded yet - will retry")
        state.pendingReconcile = false
        -- Retry in a bit - profile should load soon
        C_Timer.After(0.2, function()
            Controller.ScheduleReconcile(CONFIG.DEBOUNCE_NORMAL)
        end)
        return
    end
    
    TimelineAdd("ACTION", "RECONCILE_BEGIN", string.format("specChange=%s talentChange=%s layoutChange=%s", 
        tostring(state.specChangeDetected), tostring(state.talentChangeDetected), tostring(state.layoutChangeDetected)))
    Debug("═══════════════════════════════════════════════════")
    Debug("RECONCILE START - specChange:", state.specChangeDetected, "talentChange:", state.talentChangeDetected, "layoutChange:", state.layoutChangeDetected)
    
    state.isProcessing = true
    state.pendingReconcile = false
    local startTime = debugprofilestop()
    
    -- CRITICAL: Block position saves during reconcile
    -- Reflow may have changed member.row/col for visual compaction
    -- We don't want to save those visual positions as authoritative
    ns.CDMGroups._blockPositionSaves = true
    
    -- 1. Scan CDM viewers to get current state (MUST happen before slot-partner map)
    local cdmState = ScanCDMViewers()
    local cdmCount = 0
    for _ in pairs(cdmState) do cdmCount = cdmCount + 1 end
    TimelineAdd("CDM", "SCAN_COMPLETE", string.format("Found %d cooldownIDs in CDM viewers", cdmCount))
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- SLOT-PARTNER MAP: Snapshot shared positions BEFORE any processing
    -- Mutually exclusive talents (e.g. Halo/Void Torrent) share the same saved
    -- position. CDM's internal layout can corrupt these during reconcile, breaking
    -- the slot-sharing detection in PushFramesFromSlot. This map preserves the
    -- pairing so it can be used as a fallback.
    --
    -- CRITICAL FILTER: If CDM has real frames for BOTH partners, they are NOT
    -- mutually exclusive in this build. The user may have placed a placeholder
    -- at a position where a real frame already exists, and a spec/build change
    -- made both real. These need real conflict resolution, not partner treatment.
    --
    -- Format: _slotPartnerMap[cdID] = { {partnerCdID, group, row, col}, ... }
    -- ═══════════════════════════════════════════════════════════════════════════
    local slotPartnerMap = {}
    do
        local savedPositions_snapshot = ns.CDMGroups.savedPositions or {}
        -- Build position -> list of cdIDs map
        local posMap = {}  -- "groupName:row:col" -> { cdID1, cdID2, ... }
        for cdID, saved in pairs(savedPositions_snapshot) do
            if saved.type == "group" and saved.target and saved.row ~= nil and saved.col ~= nil then
                local key = saved.target .. ":" .. saved.row .. ":" .. saved.col
                posMap[key] = posMap[key] or {}
                table.insert(posMap[key], cdID)
            end
        end
        -- Find pairs that share positions, but ONLY if they're truly exclusive
        for key, cdIDs in pairs(posMap) do
            if #cdIDs >= 2 then
                -- Count how many of these cdIDs have real CDM frames RIGHT NOW
                local realCount = 0
                for _, id in ipairs(cdIDs) do
                    if cdmState[id] then
                        realCount = realCount + 1
                    end
                end
                
                if realCount >= 2 then
                    -- CDM has frames for 2+ partners = NOT mutually exclusive
                    -- This is a genuine conflict (e.g. user placed placeholder at occupied slot
                    -- and a build change made both real). Let normal conflict resolution handle it.
                    TimelineAdd("ACTION", "SLOT_PARTNERS_CONFLICT", string.format(
                        "Shared position %s: cdIDs %s — ALL REAL, treating as conflict", 
                        key, table.concat(cdIDs, ", ")))
                else
                    -- Only 0-1 have real frames = mutually exclusive talent pair
                    -- Link all partners to each other
                    for i = 1, #cdIDs do
                        local saved = savedPositions_snapshot[cdIDs[i]]
                        slotPartnerMap[cdIDs[i]] = slotPartnerMap[cdIDs[i]] or {}
                        for j = 1, #cdIDs do
                            if i ~= j then
                                table.insert(slotPartnerMap[cdIDs[i]], {
                                    partnerCdID = cdIDs[j],
                                    group = saved.target,
                                    row = saved.row,
                                    col = saved.col,
                                })
                            end
                        end
                    end
                    TimelineAdd("ACTION", "SLOT_PARTNERS", string.format(
                        "Shared position %s: cdIDs %s (real=%d)", 
                        key, table.concat(cdIDs, ", "), realCount))
                end
            end
        end
    end
    -- Store on namespace for PushFramesFromSlot to access
    ns.CDMGroups._slotPartnerMap = slotPartnerMap
    
    -- 2. Clean up registry
    if Registry then
        if Registry.CleanupStaleEntries then Registry:CleanupStaleEntries() end
        if Registry.CleanupCooldownIDMappings then Registry:CleanupCooldownIDMappings() end
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- 3. PRE-PASS: Create placeholder members from savedPositions FIRST
    -- This claims positions BEFORE any frame assignment, preventing position corruption
    -- when frames are processed in CDM's order instead of savedPositions order
    -- ═══════════════════════════════════════════════════════════════════════════
    local prePassCreated = 0
    local savedPositions = ns.CDMGroups.savedPositions or {}
    
    for cdID, saved in pairs(savedPositions) do
        -- GUARD: Skip string IDs (Arc Auras) - they register via RegisterExternalFrame
        -- Creating nil-frame members here causes Layout to search for old dead frames
        -- and re-parent them as ghosts on top of the new frames ArcAuras creates
        if type(cdID) == "string" then
            -- Arc Auras managed externally - skip prepass
        elseif saved.type == "group" and saved.target then
            -- For placeholders, skip the IsCooldownIDValid check - they're meant for unlearned spells
            local isPlaceholderEntry = saved.isPlaceholder
            local isValidForSpec = ns.CDMGroups.IsCooldownIDValid and ns.CDMGroups.IsCooldownIDValid(cdID) or true
            
            if not isPlaceholderEntry and not isValidForSpec then
                -- Skip - this cooldownID belongs to a different spec (and isn't a placeholder)
            else
                -- Check if this type is enabled
                local viewerType = saved.viewerType
                if not viewerType and Shared and Shared.GetViewerTypeFromCooldownID then
                    viewerType = Shared.GetViewerTypeFromCooldownID(cdID)
                end
                
                local group = ns.CDMGroups.groups and ns.CDMGroups.groups[saved.target]
                
                -- Create placeholder member if icon not in group yet
                if group and group.members and not group.members[cdID] then
                    local row = saved.row or 0
                    local col = saved.col or 0
                    
                    -- Check bounds (for placeholders, clamp into the existing grid)
                    local withinBounds = group.layout and row < group.layout.gridRows and col < group.layout.gridCols

                    if isPlaceholderEntry and not withinBounds and group.layout then
                        -- A FRAMELESS placeholder must NOT grow the grid. Doing so resurrects
                        -- rows/columns the user removed and renders a phantom empty row/column at
                        -- login (the grid is never auto-shrunk). Clamp the placeholder into the
                        -- current grid instead; if a real frame later appears for this cdID it
                        -- claims/expands the grid legitimately (matches CreatePlaceholder's contract).
                        row = math.min(row, group.layout.gridRows - 1)
                        col = math.min(col, group.layout.gridCols - 1)
                        withinBounds = true
                    end
                    
                    if withinBounds or not group.layout then
                        -- Check if position is already claimed in grid
                        local positionOccupied = group.grid and group.grid[row] and group.grid[row][col] and group.grid[row][col] ~= cdID
                        
                        -- Create member at saved position (no frame yet)
                        local memberData = {
                            frame = nil,
                            entry = nil,
                            row = row,
                            col = col,
                            targetParent = group.container,
                            viewerType = viewerType,
                            isPlaceholder = isPlaceholderEntry or nil,
                            _needsDisplacement = positionOccupied or nil,
                        }
                        
                        -- For placeholders, get placeholder info
                        if isPlaceholderEntry and type(cdID) == "number" and ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.GetCooldownInfo then
                            memberData.placeholderInfo = ns.CDMGroups.Placeholders.GetCooldownInfo(cdID)
                        end
                        
                        group.members[cdID] = memberData
                        
                        -- Only claim grid position if it's NOT occupied
                        if not positionOccupied then
                            if group.grid then
                                group.grid[row] = group.grid[row] or {}
                                group.grid[row][col] = cdID
                            end
                        end
                        
                        prePassCreated = prePassCreated + 1
                    end
                end
            end
        end
    end
    
    if prePassCreated > 0 then
        TimelineAdd("ACTION", "PREPASS_COMPLETE", string.format("Created %d placeholder members from savedPositions", prePassCreated))
    end
    
    -- Resolve grid conflicts after loading saved positions
    if ns.CDMGroups.ResolveAllGridConflicts then
        ns.CDMGroups.ResolveAllGridConflicts()
    end
    
    -- 4. Process each cooldownID from CDM
    local assigned = 0
    local skipped = 0
    local reassigned = 0
    
    for cdID, cdmData in pairs(cdmState) do
        local frame = cdmData.frame
        local currentParent = frame:GetParent()
        
        -- Check if frame is already where it should be
        local alreadyManaged = false
        local wasReassigned = false
        
        -- Check groups
        for groupName, group in pairs(ns.CDMGroups.groups or {}) do
            if group.members and group.members[cdID] then
                local member = group.members[cdID]
                if member.frame == frame and currentParent == group.container then
                    alreadyManaged = true
                    break
                elseif member.frame ~= frame then
                    -- Frame changed - reassign
                    alreadyManaged = false
                    wasReassigned = true
                    TimelineAdd("FRAME", "FRAME_CHANGED", string.format("cdID=%d in group %s - CDM gave us different frame", cdID, groupName))
                    break
                end
            end
        end
        
        -- Check free icons
        if not alreadyManaged and ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[cdID] then
            local freeData = ns.CDMGroups.freeIcons[cdID]
            if freeData.frame == frame and currentParent == UIParent then
                alreadyManaged = true
            elseif freeData.frame ~= frame then
                wasReassigned = true
                TimelineAdd("FRAME", "FRAME_CHANGED", string.format("cdID=%d free icon - CDM gave us different frame", cdID))
            end
        end
        
        if alreadyManaged then
            skipped = skipped + 1
            
            -- CRITICAL: Even if parent is correct, verify frame state after talent/spec changes
            -- CDM may have hidden frames or changed their properties
            -- This runs during spec/talent changes OR after profile/layout loads
            if state.talentChangeDetected or state.specChangeDetected or state.layoutChangeDetected then
                local needsFix = false
                local issues = {}
                
                -- Check visibility
                if not frame:IsShown() then
                    needsFix = true
                    table.insert(issues, "hidden")
                end
                
                -- Check alpha (skip if secret value in WoW 12.0)
                local alpha = frame:GetAlpha()
                if alpha and not (issecretvalue and issecretvalue(alpha)) and alpha < 0.1 then
                    needsFix = true
                    table.insert(issues, string.format("alpha=%.2f", alpha))
                end
                
                -- Check scale (skip if secret value in WoW 12.0)
                local scale = frame:GetScale()
                if scale and not (issecretvalue and issecretvalue(scale)) and math.abs(scale - 1) > 0.1 then
                    needsFix = true
                    table.insert(issues, string.format("scale=%.2f", scale))
                end
                
                if needsFix then
                    TimelineAdd("FRAME", "STATE_FIX_NEEDED", string.format("cdID=%d issues: %s", cdID, table.concat(issues, ", ")))
                    
                    -- Fix the frame state (skip if legitimately hidden by bar tracking)
                    frame:SetScale(1)
                    if not frame._arcHiddenUnequipped and not IsFrameHiddenByBar(frame) then
                        if not (frame._arcIsArcAura or frame._arcAuraID) then frame:SetAlpha(1) end
                        frame:Show()
                    end
                    frame._arcRecoveryProtection = GetTime() + 0.5
                    
                    -- Re-enhance the frame
                    if ns.CDMEnhance and ns.CDMEnhance.EnhanceFrame then
                        local vType = cdmData.viewerType
                        local vName = cdmData.viewerName
                        C_Timer.After(0.1, function()
                            if frame and frame.cooldownID == cdID then
                                ns.CDMEnhance.EnhanceFrame(frame, cdID, vType, vName)
                            end
                        end)
                    end
                end
                
                -- CRITICAL: Re-apply drag handlers for all managed frames during talent/spec changes
                -- CDM may have reset frame scripts, so we need to re-setup drag
                if ns.CDMGroups.ShouldAllowDrag and ns.CDMGroups.ShouldAllowDrag() then
                    -- Check if this is in a group
                    for groupName, group in pairs(ns.CDMGroups.groups or {}) do
                        if group.members and group.members[cdID] then
                            if group.SetupMemberDrag then
                                group:SetupMemberDrag(cdID)
                            end
                            break
                        end
                    end
                    -- Check if this is a free icon
                    if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[cdID] then
                        if ns.CDMGroups.SetupFreeIconDrag then
                            ns.CDMGroups.SetupFreeIconDrag(cdID)
                        end
                    end
                end
            end
        else
            -- Assign to owner
            if AssignFrameToOwner(cdID, cdmData) then
                assigned = assigned + 1
                if wasReassigned then
                    reassigned = reassigned + 1
                end
            end
        end
    end
    
    TimelineAdd("ACTION", "ASSIGNMENT_DONE", string.format("assigned=%d skipped=%d reassigned=%d", assigned, skipped, reassigned))
    
    -- 4. Handle frames that CDM no longer has - REMOVE stale entries
    local lostCount = 0
    local removedEntries = {}
    
    -- Check groups for stale members
    for groupName, group in pairs(ns.CDMGroups.groups or {}) do
        if group.members then
            for cdID, member in pairs(group.members) do
                -- GUARD: Skip string IDs (Arc Auras) - they don't come from CDM
                if type(cdID) == "string" then
                    -- Arc Auras are managed by Integration, not stale frame handling
                elseif not cdmState[cdID] and not member.isPlaceholder then
                    -- CDM no longer has this cooldownID - mark for removal
                    table.insert(removedEntries, {type = "group", groupName = groupName, cdID = cdID, member = member})
                    lostCount = lostCount + 1
                    TimelineAdd("FRAME", "FRAME_LOST", string.format("cdID=%d in group %s - REMOVING", cdID, groupName))
                end
            end
        end
    end
    
    -- Check freeIcons for stale entries
    for cdID, freeData in pairs(ns.CDMGroups.freeIcons or {}) do
        -- GUARD: Skip string IDs (Arc Auras) - they don't come from CDM
        if type(cdID) == "string" then
            -- Arc Auras are managed by Integration, not stale frame handling
        elseif not cdmState[cdID] then
            table.insert(removedEntries, {type = "free", cdID = cdID, freeData = freeData})
            lostCount = lostCount + 1
            TimelineAdd("FRAME", "FREE_LOST", string.format("cdID=%d free icon - REMOVING", cdID))
        end
    end
    
    -- Actually remove stale entries (or convert to placeholders if saved position exists)
    for _, entry in ipairs(removedEntries) do
        if entry.type == "group" then
            local group = ns.CDMGroups.groups and ns.CDMGroups.groups[entry.groupName]
            if group and group.members then
                local member = entry.member
                local cdID = entry.cdID
                
                -- Check if there's a saved position - if so, convert to placeholder instead of removing
                local saved = ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID]
                local shouldConvertToPlaceholder = saved and saved.type == "group" and saved.target == entry.groupName
                
                if shouldConvertToPlaceholder then
                    -- Convert to placeholder instead of removing
                    TimelineAdd("FRAME", "CONVERT_TO_PLACEHOLDER", string.format("cdID=%d in group %s - converting to placeholder", cdID, entry.groupName))
                    
                    -- Return frame to CDM if it still exists
                    if member.frame then
                        if ns.CDMGroups.ReturnFrameToCDM then
                            ns.CDMGroups.ReturnFrameToCDM(member.frame, member.entry)
                        end
                    end
                    
                    -- Get row/col before converting (for pull-back logic)
                    local savedRow = saved.row or member.row or 0
                    local savedCol = saved.col or member.col or 0
                    
                    -- SLOT-PARTNER FIX: If this cdID has a slot partner, restore saved
                    -- position to the shared slot. CDM's internal layout may have moved
                    -- this cdID before our reconcile processed it, corrupting the saved pos.
                    if slotPartnerMap and slotPartnerMap[cdID] then
                        local partnerInfo = slotPartnerMap[cdID][1]  -- First partner
                        if partnerInfo and partnerInfo.group == entry.groupName then
                            savedRow = partnerInfo.row
                            savedCol = partnerInfo.col
                            saved.row = savedRow
                            saved.col = savedCol
                            member.row = savedRow
                            member.col = savedCol
                            TimelineAdd("FRAME", "SLOT_PARTNER_RESTORE", string.format(
                                "cdID=%d restored to shared slot [%d,%d] (partner=%d)", 
                                cdID, savedRow, savedCol, partnerInfo.partnerCdID))
                        end
                    end
                    
                    -- Convert member to placeholder (keep row/col, remove frame)
                    member.frame = nil
                    member.entry = nil
                    member.isPlaceholder = true
                    member.frameLostAt = GetTime()
                    
                    -- CRITICAL: Notify DynamicLayout that member became placeholder
                    if ns.CDMGroups.DynamicLayout and ns.CDMGroups.DynamicLayout.OnPlaceholderCreated then
                        ns.CDMGroups.DynamicLayout.OnPlaceholderCreated(cdID, entry.groupName)
                    end
                    
                    -- Get placeholder info if available
                    -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
                    if type(cdID) == "number" and ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.GetCooldownInfo then
                        member.placeholderInfo = ns.CDMGroups.Placeholders.GetCooldownInfo(cdID)
                    end
                    
                    -- Mark savedPosition as placeholder
                    saved.isPlaceholder = true
                    if ns.CDMGroups.SavePositionToSpec then
                        ns.CDMGroups.SavePositionToSpec(cdID, saved)
                    end
                    
                    -- PULL-BACK LOGIC: Check if any frame was pushed from this position
                    -- If so, move it back now that the slot is available
                    if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.PullFrameBackToSlot then
                        ns.CDMGroups.Placeholders.PullFrameBackToSlot(group, savedRow, savedCol)
                    end
                    
                    -- Show placeholder frame if in editing mode
                    -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
                    if type(cdID) == "number" and ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.IsEditingMode and 
                       ns.CDMGroups.Placeholders.IsEditingMode() and ns.CDMGroups.Placeholders.ShowPlaceholder then
                        ns.CDMGroups.Placeholders.ShowPlaceholder(cdID)
                    end
                else
                    -- No saved position or different group - remove completely
                    -- Return frame to CDM if it still exists
                    if member.frame then
                        if ns.CDMGroups.ReturnFrameToCDM then
                            ns.CDMGroups.ReturnFrameToCDM(member.frame, member.entry)
                        end
                    end
                    -- Remove from grid
                    if group.grid and member.row and member.col then
                        if group.grid[member.row] then
                            group.grid[member.row][member.col] = nil
                        end
                    end
                    -- Remove from members
                    group.members[cdID] = nil
                end
            end
        elseif entry.type == "free" then
            local freeData = entry.freeData
            local cdID = entry.cdID
            
            -- Check if there's a saved position for free icon
            local saved = ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID]
            local shouldConvertToPlaceholder = saved and saved.type == "free"
            
            if shouldConvertToPlaceholder then
                -- Convert to placeholder
                TimelineAdd("FRAME", "CONVERT_FREE_TO_PLACEHOLDER", string.format("cdID=%d free - converting to placeholder", cdID))
                
                if freeData.frame then
                    if ns.CDMGroups.ReturnFrameToCDM then
                        ns.CDMGroups.ReturnFrameToCDM(freeData.frame, freeData.entry)
                    end
                end
                
                -- Mark as placeholder
                saved.isPlaceholder = true
                if ns.CDMGroups.SavePositionToSpec then
                    ns.CDMGroups.SavePositionToSpec(cdID, saved)
                end
                
                -- Remove from freeIcons (placeholder system handles display)
                ns.CDMGroups.freeIcons[cdID] = nil
                
                -- Show placeholder if in editing mode
                -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
                if type(cdID) == "number" and ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.IsEditingMode and 
                   ns.CDMGroups.Placeholders.IsEditingMode() and ns.CDMGroups.Placeholders.ShowPlaceholder then
                    ns.CDMGroups.Placeholders.ShowPlaceholder(cdID)
                end
            else
                -- No saved position - remove completely
                if freeData.frame then
                    if ns.CDMGroups.ReturnFrameToCDM then
                        ns.CDMGroups.ReturnFrameToCDM(freeData.frame, freeData.entry)
                    end
                end
                ns.CDMGroups.freeIcons[cdID] = nil
            end
        end
    end
    
    -- Clean up cooldownCatalog for FULLY removed entries (not placeholder conversions)
    if ns.CDMGroups.cooldownCatalog then
        for _, entry in ipairs(removedEntries) do
            local cdID = entry.cdID
            -- Only remove from catalog if it wasn't converted to placeholder
            local saved = ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID]
            local wasConvertedToPlaceholder = saved and saved.isPlaceholder
            if not wasConvertedToPlaceholder then
                ns.CDMGroups.cooldownCatalog[cdID] = nil
            end
        end
    end
    
    if lostCount > 0 then
        TimelineAdd("ACTION", "STALE_HANDLED", string.format("%d stale entries handled (removed or converted to placeholders)", lostCount))
    end
    
    -- 5. Trigger layouts for all groups
    for groupName, group in pairs(ns.CDMGroups.groups or {}) do
        if group.Layout then
            group:Layout()
        end
    end
    TimelineAdd("ACTION", "LAYOUTS_DONE", "All group layouts triggered")
    
    -- 6. Resolve placeholders if available
    if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.ResolvePlaceholders then
        ns.CDMGroups.Placeholders.ResolvePlaceholders()
    end
    
    -- Finish up
    local elapsed = debugprofilestop() - startTime
    state.isProcessing = false
    
    -- CRITICAL: Unblock position saves now that main reconcile processing is done
    ns.CDMGroups._blockPositionSaves = false
    
    -- Clear slot partner map (only needed during reconcile)
    ns.CDMGroups._slotPartnerMap = nil
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- POST-RECONCILE SAVE PASS: Save positions for any icons with real frames
    -- that don't have a saved position yet. This captures auto-assigned icons
    -- for new characters/profiles.
    -- ═══════════════════════════════════════════════════════════════════════════
    -- CRITICAL FIX: Use GetProfileSavedPositions to ensure we write to the correct table
    -- ═══════════════════════════════════════════════════════════════════════════
    local profileFullyLoaded = not ns.CDMGroups.initialLoadInProgress and 
                               not ns.CDMGroups._profileNotLoaded
    local profileSavedPositions = ns.CDMGroups.GetProfileSavedPositions and ns.CDMGroups.GetProfileSavedPositions()
    local savedPositions = profileSavedPositions or ns.CDMGroups.savedPositions
    
    if profileFullyLoaded and savedPositions then
        local savedCount = 0

        -- COLLISION GUARD: build a per-group set of (row,col) already claimed by an
        -- existing saved position. The auto-save below must NEVER mint a DUPLICATE
        -- saved slot: during a talent change an existing icon can be displaced off its
        -- saved slot (its savedPositions left intact) while a newly-talented icon lands
        -- on that same slot. Persisting the newcomer there would create two saved entries
        -- at one (row,col) -> overlapping icons that survive reload. We only persist a new
        -- position into a slot no other saved icon in that group already owns; collisions
        -- stay unsaved and resolve on the next clean reconcile/reload.
        local groupOccupied = {}
        for ocdID, osaved in pairs(savedPositions) do
            if type(osaved) == "table" and osaved.type == "group" and osaved.target then
                local occ = groupOccupied[osaved.target]
                if not occ then occ = {}; groupOccupied[osaved.target] = occ end
                occ[(osaved.row or 0) .. "," .. (osaved.col or 0)] = true
            end
        end

        -- Check group members
        for groupName, group in pairs(ns.CDMGroups.groups or {}) do
            if group.members then
                local occ = groupOccupied[groupName]
                if not occ then occ = {}; groupOccupied[groupName] = occ end
                for cdID, member in pairs(group.members) do
                    -- Has frame but no saved position?
                    if member.frame and not savedPositions[cdID] then
                        local row = member.row or 0
                        local col = member.col or 0
                        local slotKey = row .. "," .. col
                        if occ[slotKey] then
                            -- Slot already owned by another saved icon - don't create a duplicate
                            Debug("PostReconcile: SKIP duplicate slot for", cdID, "->", groupName, slotKey)
                        else
                            local positionData = {
                                type = "group",
                                target = groupName,
                                row = row,
                                col = col,
                                viewerType = member.viewerType,
                            }
                            savedPositions[cdID] = positionData
                            occ[slotKey] = true
                            if ns.CDMGroups.SavePositionToSpec then
                                ns.CDMGroups.SavePositionToSpec(cdID, positionData)
                            end
                            savedCount = savedCount + 1
                            Debug("PostReconcile: Saved unsaved position for", cdID, "->", groupName)
                        end
                    end
                end
            end
        end
        
        -- Check free icons
        for cdID, data in pairs(ns.CDMGroups.freeIcons or {}) do
            if data.frame and not savedPositions[cdID] then
                local positionData = {
                    type = "free",
                    x = data.x or 0,
                    y = data.y or 0,
                    iconSize = data.iconSize or 36,
                    viewerType = data.viewerType,
                }
                savedPositions[cdID] = positionData
                if ns.CDMGroups.SavePositionToSpec then
                    ns.CDMGroups.SavePositionToSpec(cdID, positionData)
                end
                savedCount = savedCount + 1
                Debug("PostReconcile: Saved unsaved free position for", cdID)
            end
        end
        
        if savedCount > 0 then
            TimelineAdd("ACTION", "POST_RECONCILE_SAVE", string.format("Saved %d unsaved positions", savedCount))
            Debug("PostReconcile: Saved", savedCount, "previously unsaved positions")
        end
    end
    
    state.lastReconcileTime = GetTime()
    
    -- Capture state before clearing (for follow-up logic)
    local wasTalentChange = state.talentChangeDetected
    local wasSpecChange = state.specChangeDetected
    local wasLayoutChange = state.layoutChangeDetected
    
    state.specChangeDetected = false
    state.talentChangeDetected = false
    state.layoutChangeDetected = false
    state.stats.reconcileCount = state.stats.reconcileCount + 1
    
    -- Set protection window
    SetProtection(CONFIG.POST_RECONCILE_PROTECTION)
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- POST-RECONCILE VISUAL REFRESH: When frames were newly assigned or reassigned,
    -- force a visual refresh to ensure per-icon settings (borders, textures, colors)
    -- are applied to the correct frames. This is the same thing that panel-close does
    -- via RefreshIconType("all"), but targeted at post-reconcile changes.
    -- Without this, per-icon visuals only update when the options panel closes.
    -- ═══════════════════════════════════════════════════════════════════════════
    if (assigned > 0 or reassigned > 0) and not wasTalentChange and not wasSpecChange then
        -- Short delay to let frame setup complete (EnhanceFrame may still be finishing)
        C_Timer.After(0.05, function()
            if state.isProcessing then return end
            
            TimelineAdd("ACTION", "POST_RECONCILE_REFRESH", string.format(
                "Refreshing visuals after %d assigned, %d reassigned", assigned, reassigned))
            
            -- Clear cached visual states so everything recalculates
            for groupName, group in pairs(ns.CDMGroups.groups or {}) do
                if group.members then
                    for cdID, member in pairs(group.members) do
                        if member and member.frame and not member.isPlaceholder then
                            member.frame._arcTargetAlpha = nil
                            member.frame._arcTargetDesat = nil
                            member.frame._arcTargetTint = nil
                            member.frame._arcTargetGlow = nil
                            member.frame._arcCooldownEventDriven = nil
                            member.frame._arcCurrentGlowSig = nil
                        end
                    end
                end
            end
            for _, data in pairs(ns.CDMGroups.freeIcons or {}) do
                if data.frame then
                    data.frame._arcTargetAlpha = nil
                    data.frame._arcTargetDesat = nil
                    data.frame._arcTargetTint = nil
                    data.frame._arcTargetGlow = nil
                    data.frame._arcCooldownEventDriven = nil
                    data.frame._arcCurrentGlowSig = nil
                end
            end
            
            -- Re-apply per-icon styles (borders, textures, pandemic, etc.)
            if ns.CDMEnhance and ns.CDMEnhance.RefreshIconType then
                ns.CDMEnhance.RefreshIconType("all")
            end
            
            -- Refresh keybind overlays on reassigned/repooled frames
            if ns.Keybinds and ns.Keybinds.IsEnabled and ns.Keybinds.IsEnabled() then
                ns.Keybinds.RefreshAll()
            end
            
            -- Restore click-through / tooltip state on newly assigned/reassigned
            -- frames, which Reconcile left clickable. Skip while editing.
            local editing = (ns.CDMGroups.IsOptionsPanelOpen and ns.CDMGroups.IsOptionsPanelOpen())
                or ns.CDMGroups.dragModeEnabled
            if not editing and ns.CDMGroups.RefreshIconSettings then
                ns.CDMGroups.RefreshIconSettings()
            end
        end)
    end
    
    -- CRITICAL: Refresh drag handlers after reconcile if drag mode is enabled
    -- This ensures all icons (including newly assigned ones) have working drag
    if ns.CDMGroups.ShouldAllowDrag and ns.CDMGroups.ShouldAllowDrag() then
        -- Slight delay to let frames fully settle
        C_Timer.After(0.1, function()
            if not state.isProcessing then
                for groupName, group in pairs(ns.CDMGroups.groups or {}) do
                    if group.members and group.SetupMemberDrag then
                        for cdID, member in pairs(group.members) do
                            if member.frame then
                                group:SetupMemberDrag(cdID)
                            end
                        end
                    end
                end
                for cdID, data in pairs(ns.CDMGroups.freeIcons or {}) do
                    if data.frame and ns.CDMGroups.SetupFreeIconDrag then
                        ns.CDMGroups.SetupFreeIconDrag(cdID)
                    end
                end
                Debug("Post-reconcile: Refreshed drag handlers")
            end
        end)
    end
    
    -- CRITICAL: After talent changes, check if we need to switch profiles
    if wasTalentChange and ns.CDMGroups.CheckAndActivateMatchingProfile then
        -- Wait a moment for CDM to fully settle, then check profiles
        C_Timer.After(0.2, function()
            if not state.isProcessing then
                TimelineAdd("ACTION", "PROFILE_CHECK", "Checking for matching profile after talent change")
                ns.CDMGroups.CheckAndActivateMatchingProfile()
            end
        end)
    end
    
    -- Helper function for follow-up sweeps (reusable)
    local function DoFollowupSweep(sweepName)
        if state.isProcessing then return end
        
        TimelineAdd("ACTION", sweepName, "Catching late frame swaps")
        
        -- Do a quick rescan without full debounce
        local cdmState = ScanCDMViewers()
        local fixCount = 0
        local newCount = 0
        local staleCount = 0
        
        -- Build lookup for what CDM currently has
        local cdmHas = {}
        for cdID in pairs(cdmState) do
            cdmHas[cdID] = true
        end
        
        -- Check for frame reference mismatches AND new cooldownIDs
        for cdID, cdmData in pairs(cdmState) do
            local frame = cdmData.frame
            local foundInGroups = false
            local foundInFree = false
            
            -- Check groups
            for groupName, group in pairs(ns.CDMGroups.groups or {}) do
                if group.members and group.members[cdID] then
                    foundInGroups = true
                    local member = group.members[cdID]
                    if member.frame ~= frame then
                        -- Frame was swapped - update reference
                        TimelineAdd("FRAME", "FOLLOWUP_FIX", string.format("cdID=%d frame swapped in %s", cdID, groupName))
                        member.frame = frame
                        
                        -- CRITICAL: Clear placeholder flags since we now have a real frame
                        -- This fixes the STALE_PH_FLAG bug where isPlaceholder wasn't cleared
                        member.isPlaceholder = nil
                        member.placeholderInfo = nil
                        if ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID] then
                            ns.CDMGroups.savedPositions[cdID].isPlaceholder = nil
                        end
                        
                        -- Update cooldownCatalog too
                        if ns.CDMGroups.cooldownCatalog and ns.CDMGroups.cooldownCatalog[cdID] then
                            ns.CDMGroups.cooldownCatalog[cdID].frame = frame
                        end
                        
                        -- Re-setup in container
                        if ns.CDMGroups.SetupFrameInContainer then
                            local slotW, slotH = 36, 36
                            if ns.CDMGroups.GetSlotDimensions and group.layout then
                                slotW, slotH = ns.CDMGroups.GetSlotDimensions(group.layout)
                            end
                            ns.CDMGroups.SetupFrameInContainer(frame, group.container, slotW, slotH, cdID)
                        end
                        
                        InstallFrameHooks(frame)
                        
                        -- CRITICAL: Re-enable drag handlers if drag mode is active
                        if ns.CDMGroups.ShouldAllowDrag and ns.CDMGroups.ShouldAllowDrag() and group.SetupMemberDrag then
                            group:SetupMemberDrag(cdID)
                            frame:EnableMouse(true)
                        end
                        
                        -- CRITICAL: Re-apply per-icon settings (borders, textures, colors, etc.)
                        -- Use ApplyIconStyle directly - it doesn't have protection checks that block EnhanceFrame
                        if ns.CDMEnhance and ns.CDMEnhance.ApplyIconStyle then
                            ns.CDMEnhance.ApplyIconStyle(frame, cdID)
                        end
                        
                        fixCount = fixCount + 1
                    end
                    break
                end
            end
            
            -- Check freeIcons
            if not foundInGroups and ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[cdID] then
                foundInFree = true
                local freeData = ns.CDMGroups.freeIcons[cdID]
                if freeData.frame ~= frame then
                    TimelineAdd("FRAME", "FOLLOWUP_FIX", string.format("cdID=%d free frame swapped", cdID))
                    freeData.frame = frame
                    
                    if ns.CDMGroups.cooldownCatalog and ns.CDMGroups.cooldownCatalog[cdID] then
                        ns.CDMGroups.cooldownCatalog[cdID].frame = frame
                    end
                    
                    InstallFrameHooks(frame)
                    
                    -- CRITICAL: Re-enable drag handlers if drag mode is active
                    if ns.CDMGroups.ShouldAllowDrag and ns.CDMGroups.ShouldAllowDrag() and ns.CDMGroups.SetupFreeIconDrag then
                        ns.CDMGroups.SetupFreeIconDrag(cdID)
                    end
                    
                    -- CRITICAL: Re-apply per-icon settings (borders, textures, colors, etc.)
                    -- Use ApplyIconStyle directly - it doesn't have protection checks that block EnhanceFrame
                    if ns.CDMEnhance and ns.CDMEnhance.ApplyIconStyle then
                        ns.CDMEnhance.ApplyIconStyle(frame, cdID)
                    end
                    
                    fixCount = fixCount + 1
                end
            end
            
            -- Handle cooldownIDs that aren't tracked at all
            if not foundInGroups and not foundInFree then
                -- Try to assign via normal flow
                if AssignFrameToOwner(cdID, cdmData) then
                    TimelineAdd("FRAME", "FOLLOWUP_NEW", string.format("cdID=%d assigned during followup", cdID))
                    newCount = newCount + 1
                end
            end
        end
        
        -- Clean up stale entries (ArcUI has but CDM doesn't)
        -- Check for entries even if frame is nil (might have been cleared previously)
        -- CRITICAL: Skip string IDs (Arc Auras) - they're our own frames, not in CDM viewers
        local toRemove = {}
        for groupName, group in pairs(ns.CDMGroups.groups or {}) do
            if group.members then
                for cdID, member in pairs(group.members) do
                    -- Skip string IDs (Arc Auras) - they won't be in CDM scan
                    if type(cdID) == "string" then
                        -- Arc Aura - skip stale check, these are our own frames
                    elseif not cdmHas[cdID] and not member.isPlaceholder then
                        table.insert(toRemove, {type = "group", groupName = groupName, cdID = cdID, member = member})
                    end
                end
            end
        end
        for cdID, freeData in pairs(ns.CDMGroups.freeIcons or {}) do
            -- Skip string IDs (Arc Auras) - they won't be in CDM scan
            if type(cdID) == "string" then
                -- Arc Aura - skip stale check
            elseif not cdmHas[cdID] then
                table.insert(toRemove, {type = "free", cdID = cdID, freeData = freeData})
            end
        end
        
        -- Also check cooldownCatalog for orphaned entries
        if ns.CDMGroups.cooldownCatalog then
            for cdID in pairs(ns.CDMGroups.cooldownCatalog) do
                -- Skip string IDs (Arc Auras) - they won't be in CDM scan
                if type(cdID) == "string" then
                    -- Arc Aura - skip stale check
                elseif not cdmHas[cdID] then
                    -- Check if already in toRemove
                    local found = false
                    for _, entry in ipairs(toRemove) do
                        if entry.cdID == cdID then
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(toRemove, {type = "catalog", cdID = cdID})
                    end
                end
            end
        end
        
        -- Actually remove stale entries
        for _, entry in ipairs(toRemove) do
            if entry.type == "group" then
                local group = ns.CDMGroups.groups and ns.CDMGroups.groups[entry.groupName]
                if group and group.members then
                    local member = entry.member
                    if member.frame then
                        if ns.CDMGroups.ReturnFrameToCDM then
                            ns.CDMGroups.ReturnFrameToCDM(member.frame, member.entry)
                        end
                    end
                    if group.grid and member.row and member.col then
                        if group.grid[member.row] then
                            group.grid[member.row][member.col] = nil
                        end
                    end
                    group.members[entry.cdID] = nil
                    TimelineAdd("FRAME", "FOLLOWUP_STALE", string.format("cdID=%d removed from %s", entry.cdID, entry.groupName))
                    staleCount = staleCount + 1
                end
            elseif entry.type == "free" then
                local freeData = entry.freeData
                if freeData.frame then
                    if ns.CDMGroups.ReturnFrameToCDM then
                        ns.CDMGroups.ReturnFrameToCDM(freeData.frame, freeData.entry)
                    end
                end
                ns.CDMGroups.freeIcons[entry.cdID] = nil
                TimelineAdd("FRAME", "FOLLOWUP_STALE", string.format("cdID=%d removed from free", entry.cdID))
                staleCount = staleCount + 1
            elseif entry.type == "catalog" then
                -- Catalog-only entry (not in groups or free, just orphaned catalog)
                TimelineAdd("FRAME", "FOLLOWUP_STALE", string.format("cdID=%d removed from catalog only", entry.cdID))
                staleCount = staleCount + 1
            end
            
            -- Also clean from cooldownCatalog
            if ns.CDMGroups.cooldownCatalog then
                ns.CDMGroups.cooldownCatalog[entry.cdID] = nil
            end
        end
        
        -- CRITICAL: Sync cooldownCatalog directly with CDM state
        -- This fixes CATALOG-STALE where catalog has old frame refs
        -- We sync against cdmState (CDM reality) not groups.members which might be stale
        local catalogSyncCount = 0
        if ns.CDMGroups.cooldownCatalog then
            -- First pass: sync all catalog entries against CDM's actual frames
            for cdID, cdmData in pairs(cdmState) do
                local cdmFrame = cdmData.frame
                local catEntry = ns.CDMGroups.cooldownCatalog[cdID]
                
                if catEntry then
                    if catEntry.frame ~= cdmFrame then
                        TimelineAdd("FRAME", "CATALOG_SYNC", string.format("cdID=%d frame updated in catalog", cdID))
                        catEntry.frame = cdmFrame
                        catalogSyncCount = catalogSyncCount + 1
                    end
                else
                    -- Create catalog entry if missing
                    ns.CDMGroups.cooldownCatalog[cdID] = {
                        cooldownID = cdID,
                        frame = cdmFrame,
                        viewerType = cdmData.viewerType,
                        viewerName = cdmData.viewerName,
                    }
                    catalogSyncCount = catalogSyncCount + 1
                end
            end
            
            -- Second pass: also ensure groups.members frame refs are in sync with CDM
            for cdID, cdmData in pairs(cdmState) do
                local cdmFrame = cdmData.frame
                
                for groupName, group in pairs(ns.CDMGroups.groups or {}) do
                    if group.members and group.members[cdID] then
                        local member = group.members[cdID]
                        -- Update frame ref if different (skip placeholders - they shouldn't have frames)
                        if member.frame ~= cdmFrame then
                            -- If this was a placeholder, clear the flag now that we have a real frame
                            if member.isPlaceholder then
                                TimelineAdd("FRAME", "PLACEHOLDER_RESOLVED", string.format("cdID=%d placeholder->real in %s", cdID, groupName))
                                member.isPlaceholder = nil
                                member.placeholderInfo = nil
                                if ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID] then
                                    ns.CDMGroups.savedPositions[cdID].isPlaceholder = nil
                                end
                            else
                                TimelineAdd("FRAME", "MEMBER_SYNC", string.format("cdID=%d member frame updated in %s", cdID, groupName))
                            end
                            member.frame = cdmFrame
                            
                            -- Re-setup in container with correct frame
                            if ns.CDMGroups.SetupFrameInContainer then
                                local slotW, slotH = 36, 36
                                if ns.CDMGroups.GetSlotDimensions and group.layout then
                                    slotW, slotH = ns.CDMGroups.GetSlotDimensions(group.layout)
                                end
                                ns.CDMGroups.SetupFrameInContainer(cdmFrame, group.container, slotW, slotH, cdID)
                            end
                            
                            InstallFrameHooks(cdmFrame)
                            
                            -- CRITICAL: Re-enable drag handlers if drag mode is active
                            if ns.CDMGroups.ShouldAllowDrag and ns.CDMGroups.ShouldAllowDrag() and group.SetupMemberDrag then
                                group:SetupMemberDrag(cdID)
                                cdmFrame:EnableMouse(true)
                            end
                            
                            -- CRITICAL: Re-apply per-icon settings (borders, textures, colors, etc.)
                            -- Use ApplyIconStyle directly - it doesn't have protection checks that block EnhanceFrame
                            if ns.CDMEnhance and ns.CDMEnhance.ApplyIconStyle then
                                ns.CDMEnhance.ApplyIconStyle(cdmFrame, cdID)
                            end
                            
                            fixCount = fixCount + 1
                        end
                        break
                    end
                end
                
                -- Also check freeIcons
                if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[cdID] then
                    local freeData = ns.CDMGroups.freeIcons[cdID]
                    if freeData.frame ~= cdmFrame then
                        TimelineAdd("FRAME", "FREE_SYNC", string.format("cdID=%d free frame updated", cdID))
                        freeData.frame = cdmFrame
                        InstallFrameHooks(cdmFrame)
                        
                        -- CRITICAL: Re-enable drag handlers if drag mode is active
                        if ns.CDMGroups.ShouldAllowDrag and ns.CDMGroups.ShouldAllowDrag() and ns.CDMGroups.SetupFreeIconDrag then
                            ns.CDMGroups.SetupFreeIconDrag(cdID)
                        end
                        
                        -- CRITICAL: Re-apply per-icon settings (borders, textures, colors, etc.)
                        -- Use ApplyIconStyle directly - it doesn't have protection checks that block EnhanceFrame
                        if ns.CDMEnhance and ns.CDMEnhance.ApplyIconStyle then
                            ns.CDMEnhance.ApplyIconStyle(cdmFrame, cdID)
                        end
                        
                        fixCount = fixCount + 1
                    end
                end
            end
        end
        
        if fixCount > 0 or newCount > 0 or staleCount > 0 or catalogSyncCount > 0 then
            TimelineAdd("ACTION", sweepName .. "_DONE", string.format("Fixed %d swaps, assigned %d new, removed %d stale, synced %d catalog", fixCount, newCount, staleCount, catalogSyncCount))
        else
            TimelineAdd("ACTION", sweepName .. "_DONE", "No issues found")
        end
        
        -- ALWAYS trigger layouts after a sweep to ensure positioning is correct
        -- For auto-flow groups, call ReflowIcons ONLY if BOTH panels are CLOSED
        -- When options panel is open, user needs to see gaps for editing
        -- Note: IsOptionsPanelOpen() now checks BOTH ArcUI and CDM panels
        local optionsPanelOpen = ns.CDMGroups.IsOptionsPanelOpen and ns.CDMGroups.IsOptionsPanelOpen()
        
        for groupName, group in pairs(ns.CDMGroups.groups or {}) do
            if group.autoReflow and group.ReflowIcons and not optionsPanelOpen then
                local wasReflowing = group._reflowing
                group._reflowing = false
                group:ReflowIcons()
                group._reflowing = wasReflowing
            elseif group.Layout then
                group:Layout()
            end
        end
        
        return fixCount + newCount + staleCount + catalogSyncCount
    end
    
    -- Helper to reposition all frames after talent/spec changes
    -- For auto-flow groups: Call ReflowIcons() to enforce saved positions + fill gaps
    -- For non-auto-flow groups: Just call Layout() to position at saved row/col
    -- For free icons: Position at saved coordinates
    local function ForceRepositionAllFrames()
        TimelineAdd("ACTION", "FORCE_REPOSITION", "Running Layout/ReflowIcons on all groups")
        local layoutCount = 0
        local reflowCount = 0
        local restoredCount = 0
        
        -- Temporarily clear protection flags that might block ReflowIcons
        -- By the time this runs (1.5s after talent change), frames have settled
        -- These flags feed into IsRestoring() which ReflowIcons checks
        ns.CDMGroups.specChangeInProgress = false
        ns.CDMGroups._pendingSpecChange = false
        ns.CDMGroups._restorationProtectionEnd = nil
        ns.CDMGroups._talentRestorationEnd = nil
        ns.CDMGroups.talentChangeInProgress = false
        ns.CDMGroups.initialLoadInProgress = false
        ns.CDMGroups.profileLoadInProgress = false
        
        -- CRITICAL: First restore member.row/col from savedPositions
        -- During talent changes, member positions may have drifted from saved positions
        -- because fill gaps or other logic may have changed them
        local savedPositions = ns.CDMGroups.savedPositions or {}
        
        for groupName, group in pairs(ns.CDMGroups.groups or {}) do
            if group.members then
                -- Clear the grid first - we'll rebuild it from savedPositions
                if group.grid then
                    wipe(group.grid)
                end
                
                for cdID, member in pairs(group.members) do
                    local saved = savedPositions[cdID]
                    if saved and saved.type == "group" and saved.target == groupName then
                        local oldRow, oldCol = member.row, member.col
                        local newRow, newCol = saved.row or 0, saved.col or 0
                        
                        -- Restore position from saved
                        if oldRow ~= newRow or oldCol ~= newCol then
                            member.row = newRow
                            member.col = newCol
                            restoredCount = restoredCount + 1
                            TimelineAdd("FRAME", "POS_RESTORE", 
                                string.format("cdID=%d [%d,%d] -> [%d,%d] in %s", 
                                    cdID, oldRow or -1, oldCol or -1, newRow, newCol, groupName))
                        end
                        
                        -- Rebuild grid entry
                        if not member.isPlaceholder then
                            group.grid[newRow] = group.grid[newRow] or {}
                            group.grid[newRow][newCol] = cdID
                        end
                    end
                end
            end
        end
        
        if restoredCount > 0 then
            TimelineAdd("ACTION", "POS_RESTORED", string.format("Restored %d positions from savedPositions", restoredCount))
        end
        
        -- Note: IsOptionsPanelOpen() now checks BOTH ArcUI and CDM panels
        local optionsPanelOpen = ns.CDMGroups.IsOptionsPanelOpen and ns.CDMGroups.IsOptionsPanelOpen()
        
        for groupName, group in pairs(ns.CDMGroups.groups or {}) do
            -- For auto-flow groups, call ReflowIcons to properly arrange by sortIndex
            -- This ensures saved positions have precedence, then fills gaps
            -- BUT: Skip reflow if ANY options panel is open (user needs to see gaps for editing)
            if group.autoReflow and group.ReflowIcons and not optionsPanelOpen then
                local wasReflowing = group._reflowing
                group._reflowing = false
                
                group:ReflowIcons()
                reflowCount = reflowCount + 1
                
                group._reflowing = wasReflowing
            elseif group.Layout then
                -- Non-auto-flow groups just use Layout()
                -- Also use Layout() when options panel is open (shows gaps)
                group:Layout()
                layoutCount = layoutCount + 1
            end
        end
        
        -- Free icons: position them at their saved coordinates
        for cdID, freeData in pairs(ns.CDMGroups.freeIcons or {}) do
            if freeData.frame and freeData.x and freeData.y then
                -- Skip frames hidden due to hideWhenUnequipped setting
                -- Skip frames hidden due to hideWhenUnequipped or bar tracking settings
                if not freeData.frame._arcHiddenUnequipped and not freeData.frame._arcHiddenNotInSpec and not IsFrameHiddenByBar(freeData.frame) then
                    freeData.frame:ClearAllPoints()
                    freeData.frame:SetPoint("CENTER", UIParent, "CENTER", freeData.x, freeData.y)
                    freeData.frame:SetParent(UIParent)
                    freeData.frame:SetFrameStrata("MEDIUM")
                    freeData.frame:SetScale(1)
                    if not (freeData.frame._arcIsArcAura or freeData.frame._arcAuraID) then freeData.frame:SetAlpha(1) end
                    freeData.frame:Show()
                end
            end
        end
        
        TimelineAdd("ACTION", "REPOSITION_DONE", string.format("Layout=%d Reflow=%d Restored=%d", layoutCount, reflowCount, restoredCount))
    end
    
    -- Schedule follow-up sweeps for talent/spec changes
    -- CDM does multiple rebuild rounds - can take up to 1.5s to fully settle
    -- CRITICAL: These must check panel state when they run, not just when scheduled
    if wasTalentChange or wasSpecChange then
        -- First follow-up: catches most late swaps
        C_Timer.After(CONFIG.DEBOUNCE_FOLLOWUP, function()
            -- Skip if options panel opened (user is editing)
            local panelOpen = ns.CDMGroups.IsOptionsPanelOpen and ns.CDMGroups.IsOptionsPanelOpen()
            if panelOpen then
                TimelineAdd("ACTION", "FOLLOWUP_SWEEP_1_SKIP", "Options panel open - skipping")
                return
            end
            DoFollowupSweep("FOLLOWUP_SWEEP_1")
        end)
        
        -- Second follow-up: catches very late swaps AND forces reposition
        C_Timer.After(CONFIG.DEBOUNCE_FOLLOWUP2, function()
            -- Skip if options panel opened (user is editing)
            local panelOpen = ns.CDMGroups.IsOptionsPanelOpen and ns.CDMGroups.IsOptionsPanelOpen()
            if panelOpen then
                TimelineAdd("ACTION", "FOLLOWUP_SWEEP_2_SKIP", "Options panel open - skipping")
                return
            end
            DoFollowupSweep("FOLLOWUP_SWEEP_2")
            ForceRepositionAllFrames()
            
            -- ═══════════════════════════════════════════════════════════════════════════
            -- CRITICAL: Clear protection flags so EnhanceFrame can run
            -- EnhanceFrame in CDMEnhance checks these flags and skips if set!
            -- ═══════════════════════════════════════════════════════════════════════════
            state.specChangeDetected = false
            state.talentChangeDetected = false
            state.layoutChangeDetected = false
            
            -- ═══════════════════════════════════════════════════════════════════════════
            -- CRITICAL FIX: EnhanceFrame was SKIPPED during spec change for many frames
            -- because specChangeDetected=true blocks it. Before calling RefreshAllIcons,
            -- we must call EnhanceFrame on any frames that were missed.
            -- _arcShowPandemic == nil indicates frame was never enhanced.
            -- ═══════════════════════════════════════════════════════════════════════════
            local enhancedCount = 0
            
            -- Helper to determine viewerType from frame if not stored
            local function GetViewerTypeForFrame(frame, storedType)
                if storedType then return storedType end
                local parent = frame:GetParent()
                if parent then
                    local parentName = parent:GetName()
                    if parentName then
                        if parentName:find("BuffIcon") or parentName:find("Aura") then
                            return "aura"
                        elseif parentName:find("Essential") then
                            return "cooldown"
                        elseif parentName:find("Utility") then
                            return "utility"
                        end
                    end
                end
                return "aura"
            end
            
            -- Check group members
            for groupName, group in pairs(ns.CDMGroups.groups or {}) do
                if group.members then
                    for cdID, member in pairs(group.members) do
                        if member.frame and member.frame._arcShowPandemic == nil then
                            if ns.CDMEnhance and ns.CDMEnhance.EnhanceFrame then
                                local vType = GetViewerTypeForFrame(member.frame, member.viewerType)
                                local vName = member.originalViewerName or (vType == "aura" and "BuffIconCooldownViewer" or "EssentialCooldownViewer")
                                ns.CDMEnhance.EnhanceFrame(member.frame, cdID, vType, vName)
                                enhancedCount = enhancedCount + 1
                            end
                        end
                    end
                end
            end
            
            -- Check free icons
            for cdID, data in pairs(ns.CDMGroups.freeIcons or {}) do
                if data.frame and data.frame._arcShowPandemic == nil then
                    if ns.CDMEnhance and ns.CDMEnhance.EnhanceFrame then
                        local vType = GetViewerTypeForFrame(data.frame, data.viewerType)
                        local vName = data.originalViewerName or (vType == "aura" and "BuffIconCooldownViewer" or "EssentialCooldownViewer")
                        ns.CDMEnhance.EnhanceFrame(data.frame, cdID, vType, vName)
                        enhancedCount = enhancedCount + 1
                    end
                end
            end
            
            if enhancedCount > 0 then
                TimelineAdd("ACTION", "ENHANCE_MISSED_FRAMES", string.format("Enhanced %d frames that were skipped during spec change", enhancedCount))
            end
            
            -- ═══════════════════════════════════════════════════════════════════════════
            -- CRITICAL: Use RefreshIconType("all") instead of RefreshAllIcons
            -- RefreshAllIcons only iterates over enhancedFrames table
            -- RefreshIconType iterates over CDMGroups.groups, freeIcons, AND enhancedFrames
            -- This ensures ALL frames get their per-icon settings refreshed for current spec
            -- ═══════════════════════════════════════════════════════════════════════════
            if ns.CDMEnhance and ns.CDMEnhance.RefreshIconType then
                TimelineAdd("ACTION", "ENHANCE_REFRESH", "Applying per-icon settings via RefreshIconType('all')")
                ns.CDMEnhance.RefreshIconType("all")
            elseif ns.CDMEnhance and ns.CDMEnhance.RefreshAllIcons then
                TimelineAdd("ACTION", "ENHANCE_REFRESH", "Fallback: Applying per-icon settings via RefreshAllIcons")
                ns.CDMEnhance.RefreshAllIcons()
            end
            
            -- ═══════════════════════════════════════════════════════════════════════════
            -- CRITICAL: Force-refresh alpha/desat/glow visual states after talent change.
            -- RefreshIconType only handles borders, textures, and config cache. It does NOT
            -- call OptimizedApplyIconVisuals (aura alpha) or ApplyCooldownStateVisuals.
            -- Without this, aura frames with missing-alpha=0 get stuck at alpha=1.0 after
            -- talent changes until the options panel is opened (which calls this same function).
            -- ═══════════════════════════════════════════════════════════════════════════
            if ns.CDMEnhance and ns.CDMEnhance.ForceRefreshAllVisualStates then
                TimelineAdd("ACTION", "FORCE_REFRESH_VISUALS", "Recalculating alpha/desat/glow after followup sweep")
                ns.CDMEnhance.ForceRefreshAllVisualStates()
            end

            -- Arc Aura spell frames have the same problem as CDM aura frames above:
            -- ready-state alpha/desat doesn't apply after spec change until the options
            -- panel is opened. RefreshAllSpellVisuals clears the state guards and re-applies.
            if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshAllSpellVisuals then
                TimelineAdd("ACTION", "ARC_SPELL_REFRESH_VISUALS", "Recalculating arc spell alpha/desat/glow after followup sweep")
                ns.ArcAurasCooldown.RefreshAllSpellVisuals()
            end
            
            -- ═══════════════════════════════════════════════════════════════════════════
            -- ORPHAN CLEANUP: Hide CDM viewer children that have no cooldownID.
            -- When switching to a spec with fewer icons, CDM repools frames but the
            -- old frames stay visible inside the viewer with cooldownID=nil/0.
            -- Masque skin regions (Backdrop, Shadow, Normal) are children of these
            -- frames, so hiding the parent kills the ghost skin artifacts.
            -- ═══════════════════════════════════════════════════════════════════════════
            if wasSpecChange then
                local hiddenOrphans = 0
                
                -- Scan CDM viewer children (frames CDM hasn't reassigned to a new spell)
                local viewerNames = {"BuffIconCooldownViewer", "EssentialCooldownViewer", "UtilityCooldownViewer"}
                for _, viewerName in ipairs(viewerNames) do
                    local viewer = _G[viewerName]
                    if viewer then
                        local children = {viewer:GetChildren()}
                        for _, child in ipairs(children) do
                            if (not child.cooldownID or child.cooldownID == 0) and child:IsShown() then
                                child:Hide()
                                hiddenOrphans = hiddenOrphans + 1
                            end
                        end
                    end
                end
                
                -- Also scan CDMGroups container children for ghost frames that CDM
                -- repooled but CDMGroups moved into a group container before cleanup ran.
                -- These won't be in the viewer children list above.
                for groupName, group in pairs(ns.CDMGroups.groups or {}) do
                    if group.container then
                        local children = {group.container:GetChildren()}
                        for _, child in ipairs(children) do
                            if (not child.cooldownID or child.cooldownID == 0) and child:IsShown() then
                                -- Verify it's not a legitimate CDMGroups UI element
                                if not child._cdmgIsContainer and not child._arcEditButton then
                                    child:Hide()
                                    hiddenOrphans = hiddenOrphans + 1
                                end
                            end
                        end
                    end
                end
                
                if hiddenOrphans > 0 then
                    TimelineAdd("ACTION", "ORPHAN_CLEANUP", string.format("Hidden %d orphaned frames (no cooldownID)", hiddenOrphans))
                    Debug("Orphan cleanup: hidden", hiddenOrphans, "frames with no cooldownID")
                end
            end
            
            -- Invalidate group visibility cache so UpdateGroupVisibility re-evaluates
            -- conditions (e.g. hide OOC) from scratch after spec change
            if wasSpecChange and ns.CDMGroups.InvalidateVisibilityCache then
                ns.CDMGroups.InvalidateVisibilityCache()
                if ns.CDMGroups.UpdateGroupVisibility then
                    ns.CDMGroups.UpdateGroupVisibility()
                end
            end
            
            -- ═══════════════════════════════════════════════════════════════════════════
            -- BAR RE-ANCHOR: Re-apply appearance for all bar systems.
            -- Bars tried to anchor to CDMGroups containers during spec change but
            -- containers didn't exist yet (Resources@0.1s, Display@0.2s, CooldownBars@0.5s
            -- vs CDMGroups rebuild@0.8s). Now that groups are settled, re-anchor them.
            -- ═══════════════════════════════════════════════════════════════════════════
            if wasSpecChange then
                -- Aura bars (Display) - calls ApplyAppearance per bar
                if ns.Display and ns.Display.RefreshAllBars then
                    ns.Display.RefreshAllBars()
                    TimelineAdd("ACTION", "BAR_REANCHOR", "Display.RefreshAllBars (aura bars re-anchored)")
                end
                
                -- Cooldown/Charge/Resource/Timer bars - calls ApplyAppearance per bar
                if ns.CooldownBars and ns.CooldownBars.ReapplyAllAppearance then
                    ns.CooldownBars.ReapplyAllAppearance()
                    TimelineAdd("ACTION", "BAR_REANCHOR", "CooldownBars.ReapplyAllAppearance (cooldown bars re-anchored)")
                end
                
                -- Resource bars - calls ApplyAppearance per bar
                if ns.Resources and ns.Resources.RefreshAllBars then
                    ns.Resources.RefreshAllBars()
                    TimelineAdd("ACTION", "BAR_REANCHOR", "Resources.RefreshAllBars (resource bars re-anchored)")
                end
                
                Debug("Bar re-anchor: all bar systems refreshed after spec change")
            end
            
            -- Notify DynamicLayout that frames are now stable
            -- This triggers fill gaps logic to re-sync after talent changes
            local DL = ns.CDMGroups.DynamicLayout
            if DL and DL.OnReconcileComplete then
                DL.OnReconcileComplete()
            end

            -- ═══════════════════════════════════════════════════════════════════════════
            -- ANCHOR RE-APPLY: Sync all proxy rects then reapply group-to-group and
            -- group-to-frame anchors. Must run AFTER bars are re-anchored and containers
            -- have their final sizes — SafeAnchorCenter reads GetRect() which returns wrong
            -- values if called before containers finish resizing.
            -- Also covers external frames (e.g. ElvUI unit frames) attached to groups:
            -- DetachAllExternalFrames ran during OnSpecChange but ReapplyAll is the only
            -- path that re-attaches them to the correct new-spec group.
            -- ═══════════════════════════════════════════════════════════════════════════
            if ns.CDMGroupsAnchors then
                if ns.CDMGroups.SyncAllAnchorProxies then
                    ns.CDMGroups.SyncAllAnchorProxies()
                    TimelineAdd("ACTION", "ANCHOR_PROXY_SYNC", "SyncAllAnchorProxies after spec settle")
                end
                if ns.CDMGroupsAnchors.ReapplyAll then
                    ns.CDMGroupsAnchors.ReapplyAll()
                    TimelineAdd("ACTION", "ANCHOR_REAPPLY", "CDMGroupsAnchors.ReapplyAll after spec settle")
                end
            end
            
            -- Refresh keybind overlays after spec/talent change repooling
            if ns.Keybinds and ns.Keybinds.IsEnabled and ns.Keybinds.IsEnabled() then
                ns.Keybinds.RefreshAll()
            end
            
            -- Aura bars: force full segment re-layout now that containers are fully settled.
            -- RefreshAllBars at 0.8s runs before CDMGroups reflow completes, leaving bars
            -- sized against the old container width. InvalidateSpecCache busts the early-exit
            -- cache so the next UpdateBar recalculates against the final container size.
            if ns.Display then
                if ns.Display.InvalidateSpecCache then
                    ns.Display.InvalidateSpecCache()
                end
                if ns.Display.RefreshAllBars then
                    ns.Display.RefreshAllBars()
                    TimelineAdd("ACTION", "BAR_REANCHOR_FINAL", "Display bars re-laid out against settled containers")
                end
            end
            
            -- ═══════════════════════════════════════════════════════════════════════════
            -- CLICK-THROUGH RE-APPLY: Reconcile re-enables mouse on repooled/reassigned
            -- frames (and CDM re-enables it on its own frames during spec/talent rebuilds).
            -- Nothing restores the saved click-through / tooltip state afterward unless the
            -- user opens the options panel. Run the same RefreshIconSettings sweep the panel
            -- triggers so click-through survives spec and talent changes. Skip while editing
            -- (panel open / drag mode) so it doesn't fight active dragging.
            -- ═══════════════════════════════════════════════════════════════════════════
            local editing = (ns.CDMGroups.IsOptionsPanelOpen and ns.CDMGroups.IsOptionsPanelOpen())
                or ns.CDMGroups.dragModeEnabled
            if not editing and ns.CDMGroups.RefreshIconSettings then
                ns.CDMGroups.RefreshIconSettings()
                TimelineAdd("ACTION", "CLICKTHROUGH_REAPPLY", "RefreshIconSettings after spec/talent settle")
            end
        end)
    end
    
    TimelineAdd("ACTION", "RECONCILE_COMPLETE", string.format("assigned=%d skipped=%d lost=%d time=%.2fms", assigned, skipped, lostCount, elapsed))
    Debug("RECONCILE COMPLETE - assigned:", assigned, "skipped:", skipped, "time:", string.format("%.2fms", elapsed))
    Debug("═══════════════════════════════════════════════════")
end

Reconcile = (Track and Track("FC.Reconcile", Reconcile)) or Reconcile

-- ═══════════════════════════════════════════════════════════════════════════
-- DEBOUNCE SYSTEM
-- ═══════════════════════════════════════════════════════════════════════════

local debounceTimer = nil

local function ScheduleReconcile(debounceTime)
    local now = GetTime()
    state.lastEventTime = now
    state.currentDebounceTime = debounceTime or CONFIG.DEBOUNCE_NORMAL
    
    if state.pendingReconcile then
        -- Already pending - the timer will check if more events came in
        TimelineAdd("ACTION", "RECONCILE_COALESCE", string.format("Already pending, coalescing (debounce=%.2fs)", state.currentDebounceTime))
        return
    end
    
    TimelineAdd("ACTION", "RECONCILE_SCHEDULED", string.format("Debounce=%.2fs", state.currentDebounceTime))
    state.pendingReconcile = true
    
    C_Timer.After(state.currentDebounceTime, function()
        -- Check if more events came in during debounce
        local timeSinceLastEvent = GetTime() - state.lastEventTime
        
        if timeSinceLastEvent < (state.currentDebounceTime - 0.05) then
            -- More events came in - reschedule
            TimelineAdd("ACTION", "RECONCILE_RESCHEDULED", string.format("More events came in (%.3fs since last)", timeSinceLastEvent))
            state.pendingReconcile = false
            ScheduleReconcile(state.currentDebounceTime)
        else
            -- Debounce complete - reconcile
            TimelineAdd("ACTION", "RECONCILE_STARTING", string.format("Debounce complete (%.3fs since last event)", timeSinceLastEvent))
            Reconcile()
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CDM HOOKS - Detect when CDM rebuilds
-- ═══════════════════════════════════════════════════════════════════════════

local function OnNotifyListeners()
    if not _cdmGroupsEnabled then return end
    
    TimelineAdd("CDM", "NotifyListeners", "CDM is rebuilding frames")
    DebugEvent("NotifyListeners", "- CDM is rebuilding")
    
    -- Use appropriate debounce based on current state
    -- Don't override with shorter debounce if talent/spec change is pending
    if state.specChangeDetected then
        ScheduleReconcile(CONFIG.DEBOUNCE_SPEC)
    elseif state.talentChangeDetected then
        ScheduleReconcile(CONFIG.DEBOUNCE_TALENT)
    else
        ScheduleReconcile(CONFIG.DEBOUNCE_NORMAL)
    end
end
OnNotifyListeners = (Track and Track("FC.OnNotifyListeners", OnNotifyListeners)) or OnNotifyListeners

local function OnSpecializationChanged(unit)
    if unit and unit ~= "player" then return end
    if not _cdmGroupsEnabled then return end
    
    TimelineAdd("EVENT", "SPEC_CHANGED", "Player changed specialization")
    DebugEvent("PLAYER_SPECIALIZATION_CHANGED")
    state.specChangeDetected = true
    
    -- Notify DynamicLayout to clear stale visibility state
    local DL = ns.CDMGroups.DynamicLayout
    if DL and DL.OnTalentChangeStart then
        DL.OnTalentChangeStart()
    end
    
    ScheduleReconcile(CONFIG.DEBOUNCE_SPEC)
end

local function OnTalentUpdate(configID)
    if not _cdmGroupsEnabled then return end
    
    -- Skip if spec change is happening (spec change handles it)
    if state.specChangeDetected then 
        TimelineAdd("EVENT", "TALENT_SKIPPED", "Skipped - spec change in progress")
        return 
    end
    
    TimelineAdd("EVENT", "TALENT_CHANGED", string.format("configID=%s", tostring(configID)))
    DebugEvent("TRAIT_CONFIG_UPDATED", configID)
    state.talentChangeDetected = true

    -- CRITICAL: Protect saved positions through the talent transition. Unlike the spec
    -- path, the talent path set NO IsRestoring-visible protection, so position saves
    -- (SavePositionToSpec only gates on IsRestoring(), NOT _blockPositionSaves) ran
    -- mid-reconcile and persisted TRANSIENT/compacted positions - moving an existing
    -- icon's saved slot onto another icon's (duplicate saved positions in dynamic
    -- groups). A time-boxed window makes IsRestoring() true so non-forced saves and
    -- reflows skip until frames settle. Self-expires; the +1.5s follow-up's
    -- ForceRepositionAllFrames clears it before its own reflow runs.
    ns.CDMGroups._talentRestorationEnd = GetTime() + 3.0

    -- Notify DynamicLayout to clear stale visibility state
    local DL = ns.CDMGroups.DynamicLayout
    if DL and DL.OnTalentChangeStart then
        DL.OnTalentChangeStart()
    end
    
    ScheduleReconcile(CONFIG.DEBOUNCE_TALENT)
end

local function OnSpellsChanged()
    if not _cdmGroupsEnabled then return end
    
    -- Skip if already handling spec/talent/layout change
    if state.specChangeDetected or state.talentChangeDetected or state.layoutChangeDetected then return end
    
    DebugEvent("SPELLS_CHANGED")
    ScheduleReconcile(CONFIG.DEBOUNCE_NORMAL)
end

local function OnPvPTalentUpdate()
    if not _cdmGroupsEnabled then return end

    -- Skip if already handling a bigger change
    if state.specChangeDetected then return end

    TimelineAdd("EVENT", "PVP_TALENT_UPDATE", "War Mode / PvP talent change detected")
    DebugEvent("PLAYER_PVP_TALENT_UPDATE")
    state.talentChangeDetected = true

    -- Notify DynamicLayout to clear stale visibility state (same as talent change)
    local DL = ns.CDMGroups.DynamicLayout
    if DL and DL.OnTalentChangeStart then
        DL.OnTalentChangeStart()
    end

    ScheduleReconcile(CONFIG.DEBOUNCE_TALENT)
end

-- Called when profile or layout is loaded/changed
-- Ensures hidden frames get fixed during reconcile
local function OnLayoutChange()
    if not _cdmGroupsEnabled then return end
    
    TimelineAdd("EVENT", "LAYOUT_CHANGED", "Profile or layout loaded")
    DebugEvent("LAYOUT_CHANGED")
    state.layoutChangeDetected = true
    
    -- Schedule reconcile with short delay to let groups settle
    ScheduleReconcile(CONFIG.DEBOUNCE_NORMAL)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME HOOKS - Fight CDM's attempts to reclaim managed frames
-- ═══════════════════════════════════════════════════════════════════════════

InstallFrameHooks = function(frame)
    if not frame then return end
    local addr = tostring(frame)
    if state.frameHooksInstalled[addr] then return end
    
    -- Hook ClearAllPoints - restore position for grouped icons
    -- Skip if CDMGroups already hooked this (avoid duplicate hooks)
    if not frame._fcClearPointsHooked and not frame._cdmgClearPointsHooked then
        hooksecurefunc(frame, "ClearAllPoints", state._trackedFcClearAllPoints)
        frame._fcClearPointsHooked = true
    end
    
    -- Hook SetScale - force scale to 1
    -- Skip if CDMGroups already hooked this (avoid duplicate hooks)
    if not frame._fcScaleHooked and not frame._cdmgScaleHooked then
        hooksecurefunc(frame, "SetScale", state._trackedFcSetScale)
        frame._fcScaleHooked = true
    end
    
    -- Hook SetSize - prevent CDM from resizing, but allow ArcUI size changes
    -- Skip if CDMGroups already hooked this (avoid duplicate hooks)
    if not frame._fcSizeHooked and not frame._cdmgSizeHooked then
        hooksecurefunc(frame, "SetSize", state._trackedFcSetSize)
        frame._fcSizeHooked = true
    end
    
    -- Hook SetFrameStrata - force strata to group's configured strata
    -- Skip if CDMGroups already hooked this (avoid duplicate hooks)
    if not frame._fcStrataHooked and not frame._cdmgStrataHooked then
        hooksecurefunc(frame, "SetFrameStrata", state._trackedFcSetFrameStrata)
        frame._fcStrataHooked = true
    end
    
    -- Hook SetShown/Hide - fight CDM hiding managed frames during reshuffles
    -- Delegate to Maintain's hooks (they handle all guard checks)
    -- Skip if CDMGroups already hooked this (avoid duplicate hooks)
    if ns.CDMGroups.HookFrameSetShown and not frame._cdmgSetShownHooked then
        ns.CDMGroups.HookFrameSetShown(frame)
    end
    if ns.CDMGroups.HookFrameHide and not frame._cdmgHideHooked then
        ns.CDMGroups.HookFrameHide(frame)
    end
    
    state.frameHooksInstalled[addr] = true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI PANEL STATE CHANGE HANDLER
-- Called directly by ArcUI_Options.lua hooks (Open/Close/OnHide)
-- Replaces the old 1.0s polling detection for instant response.
-- ═══════════════════════════════════════════════════════════════════════════

local function OnArcUIPanelChanged(isOpen)
    if not _cdmGroupsEnabled then return end
    
    -- Sync flags
    lastOptionsOpenState = isOpen
    ns.optionsPanelOpen = isOpen
    ns._arcUIOptionsOpen = isOpen
    
    -- Update caches
    if ns.CDMGroups.UpdateCachedPanelState then
        ns.CDMGroups.UpdateCachedPanelState()
    end
    if Shared and Shared.SetCDMSettingsOpen then
        local cdmPanelOpen = ns.CDMGroups.cdmOptionsPanelOpen or false
        Shared.SetCDMSettingsOpen(isOpen or cdmPanelOpen)
    end
    
    -- Handle panel state transitions for reflow/restore
    -- Skip during spec changes or restoration periods
    local skipTransition = ns.CDMGroups.specChangeInProgress 
        or ns.CDMGroups._pendingSpecChange
        or (ns.CDMGroups._restorationProtectionEnd and GetTime() < ns.CDMGroups._restorationProtectionEnd)
        or (ns.CDMGroups.lastSpecChangeTime and (GetTime() - ns.CDMGroups.lastSpecChangeTime) < 2)
    
    if not skipTransition then
        if isOpen then
            -- Panel just OPENED - scan for any frame changes, then restore to saved positions
            if ns.CDMGroups.ScanAllViewers then
                ns.CDMGroups.ScanAllViewers()
            end
            if ns.CDMGroups.RestoreIconsToSavedPositions then
                ns.CDMGroups.RestoreIconsToSavedPositions()
            end
            -- Re-setup free icon drag — Layout() re-enables group members
            -- but nothing re-enables free icons after click-through was applied
            for cdID, data in pairs(ns.CDMGroups.freeIcons or {}) do
                if data.frame and ns.CDMGroups.SetupFreeIconDrag then
                    ns.CDMGroups.SetupFreeIconDrag(cdID)
                end
            end
        else
            -- Panel just CLOSED - trigger reflow to close gaps
            local cdmPanelOpen = ns.CDMGroups.cdmOptionsPanelOpen or false
            if not cdmPanelOpen and ns.CDMGroups.ReflowAllGroups then
                ns.CDMGroups.ReflowAllGroups()
            end
            -- NOTE: Do NOT call SetupFreeIconDrag here!
            -- UpdateGroupSelectionVisuals → RefreshIconSettings (below) already
            -- handles free icons with correct click-through/tooltip state.
        end
    end
    
    -- Clear cached alpha/desat/tint/glow so icons recalculate visibility
    if ns.CDMGroups.groups then
        for _, group in pairs(ns.CDMGroups.groups) do
            if group.members then
                for _, member in pairs(group.members) do
                    if member and member.frame then
                        member.frame._arcTargetAlpha = nil
                        member.frame._arcTargetDesat = nil
                        member.frame._arcTargetTint = nil
                        member.frame._arcTargetGlow = nil
                        member.frame._arcCooldownEventDriven = nil
                    end
                end
            end
        end
    end
    for _, data in pairs(ns.CDMGroups.freeIcons or {}) do
        if data.frame then
            data.frame._arcTargetAlpha = nil
            data.frame._arcTargetDesat = nil
            data.frame._arcTargetTint = nil
            data.frame._arcTargetGlow = nil
            data.frame._arcCooldownEventDriven = nil
        end
    end
    
    -- Update group selection visuals (edit mode based on ArcUI panel only)
    if ns.CDMGroups.UpdateGroupSelectionVisuals then
        ns.CDMGroups.UpdateGroupSelectionVisuals()
    end
    
    -- Update edit button visibility
    if ns.CDMGroups.UpdateEditButtonVisibility then
        ns.CDMGroups.UpdateEditButtonVisibility()
    end
    
    -- Update placeholder editing mode (suspend/restore preserves DB preference)
    if ns.CDMGroups.Placeholders then
        if isOpen then
            -- Restore from DB: only enables if user had it enabled
            if ns.CDMGroups.Placeholders.RestoreEditingMode then
                ns.CDMGroups.Placeholders.RestoreEditingMode()
            end
        else
            -- Suspend: hides visuals WITHOUT writing false to DB
            if ns.CDMGroups.Placeholders.SuspendEditingMode then
                ns.CDMGroups.Placeholders.SuspendEditingMode()
            end
        end
    end
    
    -- Update group visibility
    if ns.CDMGroups.UpdateGroupVisibility then
        ns.CDMGroups.UpdateGroupVisibility()
    end

    -- Re-anchor all bars after panel state change.
    -- Container size may not change (e.g. all icons active → compact=full grid),
    -- so OnSizeChanged never fires. We must explicitly re-apply bar appearance
    -- so center-x anchor offsets (-barWidth/2) reflect the current container state.
    C_Timer.After(0.05, function()
        if ns.Display and ns.Display.RefreshAllBars then
            ns.Display.RefreshAllBars()
        end
        if ns.CooldownBars and ns.CooldownBars.ReapplyAllAppearance then
            ns.CooldownBars.ReapplyAllAppearance()
        end
        if ns.Resources and ns.Resources.RefreshAllBars then
            ns.Resources.RefreshAllBars()
        end
        -- On panel close: re-drive aura icons so preview opacity (0.35) is cleared.
        -- Closing the panel clears _arcTargetAlpha cache but never calls OptimizedApplyIconVisuals
        -- with optionsPanelOpen=false, leaving icons stuck at preview alpha.
        if not isOpen and ns.CDMEnhance and ns.CDMEnhance.RefreshIconType then
            ns.CDMEnhance.RefreshIconType("aura")
        end
    end)
    
    -- Second pass after reflow settles — aura bar segments need to recalculate
    -- their pixel widths against the compact container size, not the open-panel size.
    if not isOpen then
        C_Timer.After(0.5, function()
            if ns.Display then
                if ns.Display.InvalidateSpecCache then
                    ns.Display.InvalidateSpecCache()
                end
                if ns.Display.RefreshAllBars then
                    ns.Display.RefreshAllBars()
                end
            end
        end)
    end
end
ns.CDMGroups.OnArcUIPanelChanged = OnArcUIPanelChanged

-- ═══════════════════════════════════════════════════════════════════════════
-- VISUAL MAINTAINER
-- Applies visual state, handles edit mode, options panel detection
-- This is the equivalent of GroupIconStateMaintainer from Maintain.lua
-- ═══════════════════════════════════════════════════════════════════════════

local VisualMaintainer = CreateFrame("Frame")
_G.ArcUIVisualMaintainer = VisualMaintainer  -- exposed for profiler frame discovery
local visualMaintainerElapsed = 0
local optionsPanelCheckElapsed = 0
local editButtonUpdateElapsed = 0
local lastOptionsOpenState = false

local _vmOnUpdateFn = function(self, elapsed)
    if not _cdmGroupsEnabled then return end
    
    visualMaintainerElapsed = visualMaintainerElapsed + elapsed
    optionsPanelCheckElapsed = optionsPanelCheckElapsed + elapsed
    editButtonUpdateElapsed = editButtonUpdateElapsed + elapsed
    
    -- Update edit button visibility every 0.8 seconds (was 0.4) - cut in half
    if editButtonUpdateElapsed >= 0.8 then
        editButtonUpdateElapsed = 0
        if ns.CDMGroups.UpdateEditButtonVisibility then
            ns.CDMGroups.UpdateEditButtonVisibility()
        end
    end
    
    -- CDM panel detection only (ArcUI panel is now handled by direct hooks)
    -- Check every 1.0s for CDM settings panel open/close
    if optionsPanelCheckElapsed >= 1.0 then
        optionsPanelCheckElapsed = 0
        
        local cdmPanelOpen = ns.CDMGroups.cdmOptionsPanelOpen or false
        
        -- UPDATE GLOBAL CACHE
        if ns.CDMGroups.UpdateCachedPanelState then
            ns.CDMGroups.UpdateCachedPanelState()
        end
        
        -- Track CDM panel state separately (only for visibility updates)
        local lastCDMPanelOpen = state.lastCDMPanelOpen or false
        state.lastCDMPanelOpen = cdmPanelOpen
        
        -- Update shared throttle state
        local arcUIOpen = ns.optionsPanelOpen
        if Shared and Shared.SetCDMSettingsOpen then
            Shared.SetCDMSettingsOpen((arcUIOpen or cdmPanelOpen) and true or false)
        end
        
        -- Update group visibility when CDM panel state changes
        if cdmPanelOpen ~= lastCDMPanelOpen then
            if ns.CDMGroups.UpdateGroupVisibility then
                ns.CDMGroups.UpdateGroupVisibility()
            end
        end
    end
    
    -- Throttle visual updates
    if visualMaintainerElapsed < CONFIG.VISUAL_THROTTLE then return end
    visualMaintainerElapsed = 0
    
    -- ═══════════════════════════════════════════════════════════════════
    -- EXPERIMENTAL: Skip the frame iteration loop entirely.
    -- This disables: ApplyIconVisuals polling, frame reassignment detection,
    -- placeholder creation, drag handler setup, free icon size enforcement,
    -- and position drift correction. Event-driven hooks should cover
    -- most visual updates. Remove this return to re-enable.
    -- ═══════════════════════════════════════════════════════════════════
    do return end
    
    -- Skip during reconcile processing
    if state.isProcessing then return end
    
    -- Skip during protection window (let frames settle)
    if Controller.IsInProtection() then return end
    
    -- Skip if CDMEnhance not available
    if not ns.CDMEnhance or not ns.CDMEnhance.ApplyIconVisuals then return end
    
    -- Skip if groups table doesn't exist yet
    if not ns.CDMGroups.groups then return end
    
    -- Apply visuals to all group members
    for groupName, group in pairs(ns.CDMGroups.groups) do
        if group.members then
            local needsLayout = false
            
            for cdID, member in pairs(group.members) do
                if member then
                    -- Skip placeholders - they intentionally have no frame
                    if member.isPlaceholder then
                        -- Placeholders don't need attention here
                    else
                        local frame = member.frame
                        
                        if frame then
                            if IsFrameValid(frame) then
                                -- Check if frame still belongs to this cooldownID
                                local currentCdID = frame.cooldownID
                                if currentCdID and currentCdID ~= cdID then
                                    -- Frame was reassigned by CDM - need full reconcile to update membership
                                    needsLayout = true
                                    -- Clear stale caches on this frame so it doesn't use old cdID's settings
                                    frame._arcCfg = nil
                                    frame._arcCfgVersion = nil
                                    frame._arcCfgCdID = nil
                                    frame._arcTargetAlpha = nil
                                    frame._arcTargetDesat = nil
                                    frame._arcTargetTint = nil
                                    frame._arcTargetGlow = nil
                                    frame._arcCooldownEventDriven = nil
                                    -- Schedule reconcile as fallback (SetCooldownID hook is primary detection)
                                    if not state.pendingReconcile then
                                        ScheduleReconcile(CONFIG.DEBOUNCE_NORMAL)
                                    end
                                else
                                    -- CRITICAL: Call EnhanceFrame if settings haven't been applied yet
                                    if frame._arcShowPandemic == nil and ns.CDMEnhance.EnhanceFrame then
                                        ns.CDMEnhance.EnhanceFrame(frame, cdID, member.viewerType, member.originalViewerName)
                                    end
                                    
                                    -- OPTIMIZATION: Skip ApplyIconVisuals for event-driven icons
                                    -- - Aura icons with hooks: _arcAuraEventDriven (unless ignoreAuraOverride)
                                    -- - Cooldown icons: _arcCooldownEventDriven set by SPELL_UPDATE_COOLDOWN
                                    local isEventDriven = frame._arcCooldownEventDriven
                                        or (frame._arcAuraEventDriven and not frame._arcIgnoreAuraOverride)
                                    if frame._arcTargetAlpha == nil and not isEventDriven then
                                        -- Not event-driven, needs 2Hz updates
                                        ns.CDMEnhance.ApplyIconVisuals(frame)
                                    end
                                    
                                    -- CRITICAL: Setup drag handlers ONLY when dragModeEnabled is true
                                    -- Do NOT use ShouldAllowDrag() because it uses cached panel state
                                    -- which can be stale for 0.25s after panel closes, causing the
                                    -- visual maintainer to re-enable mouse and undo click-through!
                                    if ns.CDMGroups.dragModeEnabled then
                                        -- Apply mouse state (handles click-through logic too)
                                        if ns.CDMEnhance.ApplyFrameMouseState then
                                            ns.CDMEnhance.ApplyFrameMouseState(frame, cdID)
                                        end
                                        
                                        local hasDragHandler = frame:GetScript("OnDragStart") ~= nil
                                        if not hasDragHandler and group.SetupMemberDrag then
                                            group:SetupMemberDrag(cdID)
                                        end
                                    end
                                end
                            else
                                -- Frame became invalid - check if we should show placeholder
                                needsLayout = true
                                
                                -- If in editing mode, convert to placeholder and show
                                if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.IsEditingMode and
                                   ns.CDMGroups.Placeholders.IsEditingMode() then
                                    local saved = ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID]
                                    if saved and saved.type == "group" and saved.target == groupName then
                                        -- Get row/col for pull-back logic
                                        local savedRow = saved.row or member.row or 0
                                        local savedCol = saved.col or member.col or 0
                                        
                                        -- Clear invalid frame reference
                                        member.frame = nil
                                        member.entry = nil
                                        -- Convert to placeholder
                                        if not member.isPlaceholder then
                                            member.isPlaceholder = true
                                            member.frameLostAt = member.frameLostAt or GetTime()
                                            -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
                                            if type(cdID) == "number" and ns.CDMGroups.Placeholders.GetCooldownInfo then
                                                member.placeholderInfo = ns.CDMGroups.Placeholders.GetCooldownInfo(cdID)
                                            end
                                            -- Notify DynamicLayout
                                            if ns.CDMGroups.DynamicLayout and ns.CDMGroups.DynamicLayout.OnPlaceholderCreated then
                                                ns.CDMGroups.DynamicLayout.OnPlaceholderCreated(cdID, groupName)
                                            end
                                            -- PULL-BACK LOGIC
                                            if ns.CDMGroups.Placeholders.PullFrameBackToSlot then
                                                ns.CDMGroups.Placeholders.PullFrameBackToSlot(group, savedRow, savedCol)
                                            end
                                        end
                                        -- Show placeholder
                                        -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
                                        if type(cdID) == "number" and ns.CDMGroups.Placeholders.ShowPlaceholder then
                                            ns.CDMGroups.Placeholders.ShowPlaceholder(cdID)
                                        end
                                    end
                                end
                            end
                        else
                            -- No frame reference - check if we should show placeholder
                            needsLayout = true
                            
                            -- If in editing mode and there's a saved position, show placeholder
                            if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.IsEditingMode and
                               ns.CDMGroups.Placeholders.IsEditingMode() then
                                local saved = ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID]
                                if saved and saved.type == "group" and saved.target == groupName then
                                    -- Get row/col for pull-back logic
                                    local savedRow = saved.row or member.row or 0
                                    local savedCol = saved.col or member.col or 0
                                    
                                    -- Convert to placeholder if not already
                                    if not member.isPlaceholder then
                                        member.isPlaceholder = true
                                        member.frameLostAt = member.frameLostAt or GetTime()
                                        -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
                                        if type(cdID) == "number" and ns.CDMGroups.Placeholders.GetCooldownInfo then
                                            member.placeholderInfo = ns.CDMGroups.Placeholders.GetCooldownInfo(cdID)
                                        end
                                        -- Notify DynamicLayout
                                        if ns.CDMGroups.DynamicLayout and ns.CDMGroups.DynamicLayout.OnPlaceholderCreated then
                                            ns.CDMGroups.DynamicLayout.OnPlaceholderCreated(cdID, groupName)
                                        end
                                        -- PULL-BACK LOGIC
                                        if ns.CDMGroups.Placeholders.PullFrameBackToSlot then
                                            ns.CDMGroups.Placeholders.PullFrameBackToSlot(group, savedRow, savedCol)
                                        end
                                    end
                                    -- Show placeholder
                                    -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
                                    if type(cdID) == "number" and ns.CDMGroups.Placeholders.ShowPlaceholder then
                                        ns.CDMGroups.Placeholders.ShowPlaceholder(cdID)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            
            -- Trigger Layout() if frames need attention
            if needsLayout and group.Layout then
                group:Layout()
            end
        end
    end
    
    -- Apply visuals to free icons AND enforce size
    for cdID, data in pairs(ns.CDMGroups.freeIcons or {}) do
        if data.frame then
            local frame = data.frame
            if frame:IsObjectType("Frame") then

                -- Call EnhanceFrame if not yet applied
                if frame._arcShowPandemic == nil and ns.CDMEnhance.EnhanceFrame then
                    ns.CDMEnhance.EnhanceFrame(frame, cdID, data.viewerType, data.originalViewerName)
                end
                
                -- ═══════════════════════════════════════════════════════════════
                -- CRITICAL: Enforce size for free icons every tick
                -- Free icons ALWAYS use scale settings (no group scale to opt out of)
                -- ═══════════════════════════════════════════════════════════════
                local effectiveW = data.iconSize or 36
                local effectiveH = data.iconSize or 36
                
                if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettings then
                    local cfg = ns.CDMEnhance.GetEffectiveIconSettings(cdID)
                    if cfg then
                        -- FREE ICONS: Always apply scale/width/height settings
                        local baseW = cfg.width or data.iconSize or 36
                        local baseH = cfg.height or data.iconSize or 36
                        local iconScale = cfg.scale or 1.0
                        effectiveW = baseW * iconScale
                        effectiveH = baseH * iconScale
                    end
                end
                
                -- Check current size and fix if needed
                local w, h = frame:GetSize()
                w = w or 0
                h = h or 0
                -- Skip size comparison if w or h are secret values (WoW 12.0)
                local wSecret = issecretvalue and issecretvalue(w)
                local hSecret = issecretvalue and issecretvalue(h)
                if not wSecret and not hSecret and (math.abs(w - effectiveW) > 0.5 or math.abs(h - effectiveH) > 0.5) then
                    frame._cdmgSettingSize = true
                    frame:SetSize(effectiveW, effectiveH)
                    frame._cdmgSettingSize = nil
                end
                
                -- OPTIMIZATION: Skip ApplyIconVisuals for event-driven icons
                -- - Aura icons with hooks: _arcAuraEventDriven (unless ignoreAuraOverride)
                -- - Cooldown icons: _arcCooldownEventDriven set by SPELL_UPDATE_COOLDOWN
                local isEventDriven = frame._arcCooldownEventDriven
                    or (frame._arcAuraEventDriven and not frame._arcIgnoreAuraOverride)
                if frame._arcTargetAlpha == nil and not isEventDriven then
                    ns.CDMEnhance.ApplyIconVisuals(frame)
                end
                
                -- Setup drag for free icons ONLY when dragModeEnabled is true
                -- Do NOT use ShouldAllowDrag() because it uses cached panel state
                -- which can be stale for 0.25s after panel closes
                if ns.CDMGroups.dragModeEnabled then
                    -- Apply mouse state (handles click-through logic too)
                    if ns.CDMEnhance.ApplyFrameMouseState then
                        ns.CDMEnhance.ApplyFrameMouseState(frame, cdID)
                    end
                    
                    local hasDragHandler = frame:GetScript("OnDragStart") ~= nil
                    if not hasDragHandler and ns.CDMGroups.SetupFreeIconDrag then
                        ns.CDMGroups.SetupFreeIconDrag(cdID)
                    end
                end
                
                -- Check position drift (only if not dragging)
                if not frame._freeDragging then
                    local cx, cy = frame:GetCenter()
                    if cx and cy then
                        -- Skip position comparison if cx or cy are secret values (WoW 12.0)
                        local cxSecret = issecretvalue and issecretvalue(cx)
                        local cySecret = issecretvalue and issecretvalue(cy)
                        if cxSecret or cySecret then
                            -- Can't compare, skip drift check
                        else
                            local ux, uy = UIParent:GetCenter()
                            local currentX, currentY = cx - ux, cy - uy
                            
                            -- Fix position if drifted more than 2 pixels
                            if math.abs(currentX - data.x) > 2 or math.abs(currentY - data.y) > 2 then
                                frame:ClearAllPoints()
                                frame:SetPoint("CENTER", UIParent, "CENTER", data.x, data.y)
                            end
                        end
                    else
                        -- Frame has no valid position, force set it
                        frame:ClearAllPoints()
                        frame:SetPoint("CENTER", UIParent, "CENTER", data.x, data.y)
                    end
                end
            end
        else
            -- Free icon has no frame - check if we should show placeholder
            if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.IsEditingMode and
               ns.CDMGroups.Placeholders.IsEditingMode() then
                local saved = ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID]
                if saved and saved.type == "free" then
                    -- Show placeholder for this free icon
                    -- GUARD: Only for numeric IDs (Arc Auras use string IDs)
                    if type(cdID) == "number" and ns.CDMGroups.Placeholders.ShowPlaceholder then
                        ns.CDMGroups.Placeholders.ShowPlaceholder(cdID)
                    end
                end
            end
        end
    end
end
VisualMaintainer:SetScript("OnUpdate", Track and Track("FC.VisualMaintainer.OnUpdate", _vmOnUpdateFn) or _vmOnUpdateFn)

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

local function InstallCDMHooks()
    if state.hooksInstalled then return end
    
    -- Hook LayoutManager.NotifyListeners
    if CooldownViewerSettings then
        local layoutMgr = CooldownViewerSettings:GetLayoutManager()
        if layoutMgr and layoutMgr.NotifyListeners then
            hooksecurefunc(layoutMgr, "NotifyListeners", OnNotifyListeners)
            Debug("Hooked LayoutManager.NotifyListeners")
        end
    end
    
    -- Hook CooldownViewerMixin.OnAcquireItemFrame to catch new frames
    if CooldownViewerMixin and CooldownViewerMixin.OnAcquireItemFrame then
        hooksecurefunc(CooldownViewerMixin, "OnAcquireItemFrame", function(viewer, frame)
            if not _cdmGroupsEnabled then return end
            -- Schedule reconcile when frames are acquired
            ScheduleReconcile(CONFIG.DEBOUNCE_NORMAL)
        end)
        Debug("Hooked CooldownViewerMixin.OnAcquireItemFrame")
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- INSTANT RESHUFFLE DETECTION: Hook SetCooldownID / ClearCooldownID
    -- CDM calls SetCooldownID on every frame when it reshuffles cooldownIDs.
    -- This fires during: settings panel drags, add/remove cooldowns, talent changes,
    -- and any other CDM RefreshLayout → RefreshData cycle.
    -- Previously we only detected this on panel close. Now it's instant.
    -- ═══════════════════════════════════════════════════════════════════════════

    -- ─── FAST-PATH PLACEMENT ────────────────────────────────────────────────
    -- Problem: after CDM's RefreshLayout (ReleaseAll → reacquire → RefreshData),
    -- frames may be parented to CDM's default container OR have stale anchors
    -- pointing at the OLD cdID's slot. The full Reconcile() doesn't run until
    -- DEBOUNCE_NORMAL (0.15s) later, so for that window the icon sits at the
    -- wrong position before snapping into place.
    --
    -- Fix: when SetCooldownID fires for a cdID that has a known savedPosition,
    -- synchronously reparent + reposition the frame to its target slot in the
    -- same tick. The full reconcile still runs at +0.15s and remains the
    -- source of truth (member tracking, partner resolution, validation, etc.)
    -- — this is just a fast initial guess to eliminate the visible delay.
    --
    -- Safety: only acts when savedPositions[cooldownID] points to an existing
    -- group/free placement. Brand-new icons or unrecognised cdIDs fall through
    -- to reconcile as before. Skipped during spec change, talent change,
    -- restoration protection, options panel open, and CDM panel open — those
    -- contexts have their own placement logic.
    local function TryFastPathPlace(itemFrame, cooldownID)
        if not itemFrame or not cooldownID or type(cooldownID) ~= "number" then return end
        if not ns.CDMGroups then return end

        -- Bail in any state where placement is owned by another path
        if state.specChangeDetected then return end
        if state.talentChangeDetected then return end
        if ns.CDMGroups.specChangeInProgress then return end
        if ns.CDMGroups._pendingSpecChange then return end
        if ns.CDMGroups.talentChangeInProgress then return end
        if ns.CDMGroups._restorationProtectionEnd and GetTime() < ns.CDMGroups._restorationProtectionEnd then return end
        if ns.CDMGroups._talentRestorationEnd and GetTime() < ns.CDMGroups._talentRestorationEnd then return end
        if ns._arcUIOptionsOpen then return end
        if ns.CDMGroups.cdmOptionsPanelOpen then return end
        -- Free dragging / group dragging: don't fight the user
        if itemFrame._freeDragging or itemFrame._groupDragging then return end
        -- Hidden by bar tracking — that path manages its own visibility
        if itemFrame._arcHiddenByBar then return end

        -- Need a saved position to know where this cdID belongs
        local savedPositions = ns.CDMGroups.savedPositions
        local saved = savedPositions and savedPositions[cooldownID]
        if not saved then return end

        if saved.type == "group" and saved.target then
            local groups = ns.CDMGroups.groups
            local group = groups and groups[saved.target]
            if not group or not group.container then return end

            -- Prefer current member.row/col when dynamic layout is on (reflow
            -- may have moved this cdID off its saved slot). Mirror the
            -- AssignFrameToCooldown lookup pattern so static and dynamic
            -- layouts converge to the same answer.
            local row, col = saved.row, saved.col
            if group.dynamicLayout and group.members and group.members[cooldownID] then
                local member = group.members[cooldownID]
                if member.row ~= nil and member.col ~= nil then
                    row = member.row
                    col = member.col
                end
            end
            if row == nil or col == nil then return end

            -- Skip if frame is already correctly parented AND already at the
            -- right target slot (cdID didn't actually move groups/positions).
            local currentParent = itemFrame:GetParent()
            local alreadyInGroup = currentParent == group.container
            if alreadyInGroup
              and itemFrame._cdmgTargetCdID == cooldownID
              and itemFrame._cdmgTargetRow == row
              and itemFrame._cdmgTargetCol == col then
                return
            end

            -- Compute slot dimensions and place
            local slotW, slotH = 36, 36
            if ns.CDMGroups.GetSlotDimensions and group.layout then
                slotW, slotH = ns.CDMGroups.GetSlotDimensions(group.layout)
            end

            if ns.CDMGroups.SetupFrameInContainer then
                -- SetupFrameInContainer parents, sizes, anchors and writes
                -- _cdmgTargetPoint/X/Y so FcOnClearAllPoints can self-heal
                -- if CDM re-clears anchors later in the same tick.
                ns.CDMGroups.SetupFrameInContainer(itemFrame, group.container, slotW, slotH, cooldownID)
                -- Stamp target slot for the early-skip check above
                itemFrame._cdmgTargetCdID = cooldownID
                itemFrame._cdmgTargetRow  = row
                itemFrame._cdmgTargetCol  = col
                -- Make sure it's visible (Pool_HideAndClearAnchors hid it)
                if not itemFrame._arcHiddenUnequipped and not IsFrameHiddenByBar(itemFrame) then
                    itemFrame:Show()
                end
                -- Install frame hooks if not yet (cheap idempotent)
                InstallFrameHooks(itemFrame)
                TimelineAdd("ACTION", "FAST_PATH_PLACE", string.format(
                    "cdID=%s → group=%s row=%s col=%s",
                    tostring(cooldownID), tostring(saved.target), tostring(row), tostring(col)))
            end
        elseif saved.type == "free" then
            -- Free icon: parent to UIParent, place at saved x/y
            local x = saved.x or 0
            local y = saved.y or 0
            local size = saved.iconSize or 36

            -- Skip if already correctly positioned as free icon
            if itemFrame._cdmgIsFreeIcon
              and itemFrame._cdmgFreeTargetX == x
              and itemFrame._cdmgFreeTargetY == y then
                return
            end

            itemFrame._cdmgSettingPosition = true
            itemFrame:SetParent(UIParent)
            itemFrame:ClearAllPoints()
            itemFrame:SetPoint("CENTER", UIParent, "CENTER", x, y)
            itemFrame:SetSize(size, size)
            itemFrame:SetScale(1)
            itemFrame:SetAlpha(1)
            itemFrame._cdmgSettingPosition = false

            itemFrame._cdmgIsFreeIcon     = true
            itemFrame._cdmgFreeTargetX    = x
            itemFrame._cdmgFreeTargetY    = y
            itemFrame._cdmgFreeTargetSize = size

            if not itemFrame._arcHiddenUnequipped and not IsFrameHiddenByBar(itemFrame) then
                itemFrame:Show()
            end
            InstallFrameHooks(itemFrame)
            TimelineAdd("ACTION", "FAST_PATH_PLACE", string.format(
                "cdID=%s → free x=%s y=%s",
                tostring(cooldownID), tostring(x), tostring(y)))
        end
    end

    if CooldownViewerItemDataMixin then
        -- Hook SetCooldownID - fires when CDM assigns a (possibly new) cooldownID to a frame
        if CooldownViewerItemDataMixin.SetCooldownID then
            hooksecurefunc(CooldownViewerItemDataMixin, "SetCooldownID", function(itemFrame, cooldownID)
                if not _cdmGroupsEnabled then return end
                
                -- CRITICAL: Check hidden-by-bar BEFORE container gate.
                -- Hidden frames may be in standard CDM viewers, not our containers.
                -- When options panel is OPEN, _arcHiddenByBar is nil (cleared by ShowAllHiddenByBarOverlays)
                -- so we also check ns._arcUIOptionsOpen to catch overlay-bearing frames.
                if itemFrame._arcHiddenByBar or ns._arcUIOptionsOpen then
                    -- CDM's RefreshData re-calls SetCooldownID with each active frame's
                    -- CURRENT cooldownID every refresh cycle (CooldownViewer.lua:
                    -- RefreshData → itemFrame:SetCooldownID(cooldownID)). SetCooldownID's
                    -- body no-ops on an unchanged id, but hooksecurefunc still fires THIS
                    -- post-hook on every refresh (combat enter/leave, aura gain/loss,
                    -- reload). If we simply cleared the bar-hide here, those routine
                    -- refreshes would force-show the Blizzard frame (or drop its options
                    -- overlay) until the next bar update re-hid it.
                    --
                    -- Distinguish via the hidden cooldownID Core tracks (mode-independent;
                    -- works while options are open, where _arcHiddenByBar is nil):
                    --   • SAME id  → no-op refresh of a still-hidden frame: RE-ASSERT the
                    --     hide (Core restores hide vs show+overlay for the current mode).
                    --   • DIFFERENT → genuine reshuffle onto a new cooldownID: release the
                    --     hide and let RefreshHiddenCDMFrames re-find the frame now showing
                    --     the hidden cooldownID. (cooldownIDs are non-secret CDM ids.)
                    local hiddenCdID = ns.API and ns.API.GetCDMHiddenCooldownID
                        and ns.API.GetCDMHiddenCooldownID(itemFrame)
                    if hiddenCdID and cooldownID == hiddenCdID then
                        if ns.API and ns.API.ReassertCDMHideForFrame then
                            ns.API.ReassertCDMHideForFrame(itemFrame, cooldownID)
                        end
                    else
                        -- Clear flags if set
                        itemFrame._arcHiddenByBar = nil
                        itemFrame._arcHiddenByBarCdID = nil
                        -- Immediately hide overlay on this frame so it doesn't linger on wrong icon
                        if ns.API and ns.API.HideOverlayOnFrame then
                            ns.API.HideOverlayOnFrame(itemFrame)
                        end
                        -- Defer refresh: CDM assigns cooldownIDs sequentially during reshuffle,
                        -- the new frame for the hidden cdID may not exist yet.
                        if not state._pendingHiddenRefresh then
                            state._pendingHiddenRefresh = true
                            C_Timer.After(0.2, function()
                                state._pendingHiddenRefresh = nil
                                if ns.API and ns.API.RefreshHiddenCDMFrames then
                                    ns.API.RefreshHiddenCDMFrames()
                                end
                            end)
                        end
                    end
                elseif cooldownID and ns.API and ns.API.HideCDMFrameIfRequested then
                    -- Fresh / never-hidden frame (e.g. CDM building buff icons at login or
                    -- a buff reappearing on a new pool frame). If a bar has requested this
                    -- cooldownID hidden, hide it in this same tick instead of waiting for
                    -- the next bar update (combat/target) — the "not hidden until I
                    -- right-clicked a mob" case. O(1) registry lookup, no-op otherwise.
                    ns.API.HideCDMFrameIfRequested(itemFrame, cooldownID)
                end
                
                -- ─── FAST-PATH PLACEMENT ─────────────────────────────────
                -- Run BEFORE the in-container gate. After CDM's ReleaseAll the
                -- frame may have lost its anchors / been demoted from our
                -- container — fast-path reparents + repositions in the same
                -- tick so there's no visible delay until reconcile fires.
                -- No-ops if savedPositions[cooldownID] doesn't exist or any
                -- protection window is active.
                TryFastPathPlace(itemFrame, cooldownID)

                -- Only care about frames we're managing (in our containers or free icons)
                -- Re-read parent: TryFastPathPlace may have just reparented us in.
                local parent = itemFrame:GetParent()
                local isInContainer = parent and parent._isCDMGContainer
                local isFreeIcon = itemFrame._cdmgIsFreeIcon
                if not isInContainer and not isFreeIcon then return end
                
                -- Check if cooldownID actually changed from what we last enhanced
                local prevCdID = itemFrame._arcLastEnhancedCdID
                if prevCdID and prevCdID == cooldownID then return end  -- Same cdID, no reshuffle
                
                -- Frame got a NEW cooldownID - clear ALL stale caches immediately
                itemFrame._arcCfg = nil
                itemFrame._arcCfgVersion = nil
                itemFrame._arcCfgCdID = nil
                itemFrame._arcTargetAlpha = nil
                itemFrame._arcTargetDesat = nil
                itemFrame._arcTargetTint = nil
                itemFrame._arcTargetGlow = nil
                itemFrame._arcCooldownEventDriven = nil
                itemFrame._arcCurrentGlowSig = nil  -- Force glow re-evaluation
                
                if ns.devMode then
                    print(string.format("|cffFFAA00[ArcUI]|r SetCooldownID: frame %s reassigned %s → %s",
                        tostring(itemFrame:GetName() or tostring(itemFrame)),
                        tostring(prevCdID), tostring(cooldownID)))
                end
                
                -- Notify all module subscribers BEFORE the deferred reconcile
                -- so they can invalidate their per-frame caches in the same
                -- tick CDM made the rebind. Same-tick invalidation prevents
                -- visual / data desync during the 0.15s reconcile window.
                DispatchFrameRebind(itemFrame, prevCdID, cooldownID)
                
                -- Schedule a debounced reconcile to update group membership tracking
                -- DEBOUNCE_NORMAL (0.15s) batches multiple SetCooldownID calls from a single RefreshData cycle
                if not state.pendingReconcile then
                    ScheduleReconcile(CONFIG.DEBOUNCE_NORMAL)
                end
            end)
            Debug("Hooked CooldownViewerItemDataMixin.SetCooldownID (instant reshuffle detection)")
        end
        
        -- Hook ClearCooldownID - fires when CDM releases/clears a frame (during ReleaseAll before reshuffle)
        if CooldownViewerItemDataMixin.ClearCooldownID then
            hooksecurefunc(CooldownViewerItemDataMixin, "ClearCooldownID", function(itemFrame)
                if not _cdmGroupsEnabled then return end
                
                -- CRITICAL: Check hidden-by-bar BEFORE container gate (same as SetCooldownID).
                -- When options open, _arcHiddenByBar is nil, so also check options flag.
                if itemFrame._arcHiddenByBar or ns._arcUIOptionsOpen then
                    itemFrame._arcHiddenByBar = nil
                    itemFrame._arcHiddenByBarCdID = nil
                    if ns.API and ns.API.HideOverlayOnFrame then
                        ns.API.HideOverlayOnFrame(itemFrame)
                    end
                    if not state._pendingHiddenRefresh then
                        state._pendingHiddenRefresh = true
                        C_Timer.After(0.2, function()
                            state._pendingHiddenRefresh = nil
                            if ns.API and ns.API.RefreshHiddenCDMFrames then
                                ns.API.RefreshHiddenCDMFrames()
                            end
                        end)
                    end
                end
                
                local parent = itemFrame:GetParent()
                local isInContainer = parent and parent._isCDMGContainer
                local isFreeIcon = itemFrame._cdmgIsFreeIcon
                if not isInContainer and not isFreeIcon then return end
                
                -- Frame's cooldownID was cleared - purge stale caches
                local oldCdID = itemFrame._arcLastEnhancedCdID
                itemFrame._arcCfg = nil
                itemFrame._arcCfgVersion = nil
                itemFrame._arcCfgCdID = nil
                itemFrame._arcTargetAlpha = nil
                itemFrame._arcTargetDesat = nil
                itemFrame._arcTargetTint = nil
                itemFrame._arcTargetGlow = nil
                itemFrame._arcCooldownEventDriven = nil
                
                -- Notify subscribers of release (newCdID=nil signals "frame
                -- returned to pool"). Modules that don't care about releases
                -- early-return on `if not newCdID then return end`.
                DispatchFrameRebind(itemFrame, oldCdID, nil)
            end)
            Debug("Hooked CooldownViewerItemDataMixin.ClearCooldownID")
        end
    end
    
    -- Register for CooldownViewerSettings.OnDataChanged EventRegistry callback
    -- This fires when user adds/removes/reorders cooldowns in CDM settings
    -- Acts as an early heads-up that a reshuffle is coming
    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
            if not _cdmGroupsEnabled then return end
            TimelineAdd("CDM", "OnDataChanged", "CDM settings data changed - reshuffle incoming")
            Debug("CooldownViewerSettings.OnDataChanged fired - scheduling reconcile")
            -- Schedule reconcile with normal debounce - the SetCooldownID hooks will fire shortly
            -- after this as each viewer calls RefreshLayout → RefreshData
            ScheduleReconcile(CONFIG.DEBOUNCE_NORMAL)
        end, "ArcUI_FrameController")
        Debug("Registered CooldownViewerSettings.OnDataChanged callback")
    end
    
    state.hooksInstalled = true
    Debug("CDM hooks installed")
end

local function Initialize()
    Debug("Initializing FrameController...")
    
    -- Initialize cached enabled state
    RefreshCachedEnabledState()
    
    -- Create event frame
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    eventFrame:RegisterEvent("SPELLS_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
    eventFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
    eventFrame:RegisterEvent("PLAYER_PVP_TALENT_UPDATE")

    eventFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "PLAYER_SPECIALIZATION_CHANGED" then
            OnSpecializationChanged(...)
        elseif event == "TRAIT_CONFIG_UPDATED" then
            OnTalentUpdate(...)
        elseif event == "SPELLS_CHANGED" then
            OnSpellsChanged()
        elseif event == "PLAYER_PVP_TALENT_UPDATE" then
            OnPvPTalentUpdate()
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- Install CDM hooks after entering world
            C_Timer.After(0.5, InstallCDMHooks)
            C_Timer.After(2.0, InstallCDMHooks)  -- Retry in case CDM loads late
            -- Arc Auras spell frames: ready-state alpha does not apply on reload
            -- until the options panel is opened. RefreshAllSpellVisuals clears the
            -- stale _lastAppliedAlpha/_arcLastSpellState guards and re-applies visuals.
            -- Deferred past ArcAuras.Initialize (2s) + CDMEnhance settings load.
            C_Timer.After(3.0, function()
                if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshAllSpellVisuals then
                    ns.ArcAurasCooldown.RefreshAllSpellVisuals()
                end
            end)
        elseif event == "COOLDOWN_VIEWER_DATA_LOADED" then
            TimelineAdd("CDM", "DATA_LOADED", "CDM finished loading/reassigning cooldown data")
            -- Also schedule a reconcile to catch any changes
            if _cdmGroupsEnabled and not state.isProcessing then
                ScheduleReconcile(CONFIG.DEBOUNCE_NORMAL)
            end
        elseif event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
            TimelineAdd("CDM", "SPELL_OVERRIDE", "CDM spell override updated")
        end
    end)
    
    Debug("FrameController initialized")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- API EXPORTS
-- ═══════════════════════════════════════════════════════════════════════════

-- Refresh drag handlers on all icons (like toggling Edit Mode off/on)
-- Call this after CDM changes if drag handlers stop working
local function RefreshDragHandlers()
    if not (ns.CDMGroups.ShouldAllowDrag and ns.CDMGroups.ShouldAllowDrag()) then return end
    
    Debug("RefreshDragHandlers: Re-applying drag handlers to all icons")
    
    -- Refresh group members
    for groupName, group in pairs(ns.CDMGroups.groups or {}) do
        if group.members then
            for cdID, member in pairs(group.members) do
                if member.frame and group.SetupMemberDrag then
                    group:SetupMemberDrag(cdID)
                end
            end
        end
    end
    
    -- Refresh free icons
    for cdID, data in pairs(ns.CDMGroups.freeIcons or {}) do
        if data.frame and ns.CDMGroups.SetupFreeIconDrag then
            ns.CDMGroups.SetupFreeIconDrag(cdID)
        end
    end
    
    Debug("RefreshDragHandlers: Complete")
end

Controller.Initialize = Initialize
Controller.Reconcile = Reconcile
Controller.ScheduleReconcile = ScheduleReconcile
Controller.OnLayoutChange = OnLayoutChange  -- Call when loading profiles/layouts
Controller.ScanCDMViewers = ScanCDMViewers
Controller.InstallFrameHooks = InstallFrameHooks
Controller.IsProcessing = Controller.IsProcessing
Controller.IsInProtection = Controller.IsInProtection
Controller.RefreshDragHandlers = RefreshDragHandlers

-- Assignment functions (for Integration.lua and other modules)
Controller.AssignFrameToGroup = AssignFrameToGroup
Controller.AssignFrameToFree = AssignFrameToFree
Controller.AssignFrameToOwner = AssignFrameToOwner

-- Stats access
Controller.GetStats = function()
    return state.stats
end

Controller.ResetStats = function()
    state.stats = {
        reconcileCount = 0,
        framesAssigned = 0,
        framesRecovered = 0,
        hookFights = { position = 0, scale = 0, size = 0, strata = 0 },
    }
end

-- Allow external modules (like debugger) to hook into timeline events
Controller.SetTimelineCallback = SetTimelineCallback

-- Debug commands
SLASH_ARCUIFC1 = "/arcuifc"
SlashCmdList["ARCUIFC"] = function(msg)
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or msg):lower():trim()
    arg = arg and arg:trim() or ""
    
    if cmd == "debug" then
        _G.ARCUI_FC_DEBUG = not _G.ARCUI_FC_DEBUG
        print("|cff00FFFF[FrameController]|r Debug:", _G.ARCUI_FC_DEBUG and "ON" or "OFF")
    elseif cmd == "reconcile" or cmd == "r" then
        print("|cff00FFFF[FrameController]|r Forcing reconcile...")
        Reconcile()
    elseif cmd == "stats" then
        local s = state.stats
        print("|cff00FFFF[FrameController]|r Stats:")
        print("  Reconciles:", s.reconcileCount)
        print("  Frames assigned:", s.framesAssigned)
        print("  Hook fights - position:", s.hookFights.position, "scale:", s.hookFights.scale, "size:", s.hookFights.size, "strata:", s.hookFights.strata)
    elseif cmd == "state" then
        print("|cff00FFFF[FrameController]|r State:")
        print("  isProcessing:", state.isProcessing)
        print("  pendingReconcile:", state.pendingReconcile)
        print("  specChangeDetected:", state.specChangeDetected)
        print("  talentChangeDetected:", state.talentChangeDetected)
        print("  layoutChangeDetected:", state.layoutChangeDetected)
        print("  hooksInstalled:", state.hooksInstalled)
        print("  lastReconcileTime:", state.lastReconcileTime)
    elseif cmd == "timeline" then
        if arg == "on" then
            _G.ARCUI_FC_TIMELINE = true
            TimelineClear()
            print("|cff00FFFF[FrameController]|r Timeline recording: ON")
            print("  Now change talents/spec and use '/arcuifc timeline' to see what happened")
        elseif arg == "off" then
            _G.ARCUI_FC_TIMELINE = false
            print("|cff00FFFF[FrameController]|r Timeline recording: OFF")
        elseif arg == "clear" then
            TimelineClear()
            print("|cff00FFFF[FrameController]|r Timeline cleared")
        else
            -- Show timeline (optional filter in arg)
            local filter = arg ~= "" and arg or nil
            TimelinePrint(filter, 50)
        end
    elseif cmd == "tl" then
        -- Shorthand for timeline
        TimelinePrint(arg ~= "" and arg or nil, 30)
    else
        print("|cff00FFFF[FrameController]|r Commands:")
        print("  /arcuifc debug - Toggle debug output")
        print("  /arcuifc reconcile - Force reconcile now")
        print("  /arcuifc stats - Show statistics")
        print("  /arcuifc state - Show current state")
        print("  |cffFFFF00Timeline:|r")
        print("  /arcuifc timeline on - Start recording events")
        print("  /arcuifc timeline off - Stop recording")
        print("  /arcuifc timeline [filter] - Show timeline (optional filter)")
        print("  /arcuifc timeline clear - Clear timeline")
        print("  /arcuifc tl [filter] - Shorthand for timeline")
    end
end

-- Auto-initialize
Initialize()

print("|cff00FFFF[ArcUI FrameController]|r Loaded. Use /arcuifc for commands.")