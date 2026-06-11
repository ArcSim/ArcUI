-- ===================================================================
-- ArcUI_CDMGroupsAnchors.lua
-- Anchoring system for CDM Groups
-- Supports: Group>Group, Group>External Frame, External Frame>Group
-- Uses safe anchoring (screen-coordinate positioning) to avoid taint.
-- ===================================================================

local ADDON_NAME, ns = ...

ns.CDMGroupsAnchors = ns.CDMGroupsAnchors or {}
local Anchors = ns.CDMGroupsAnchors

-- ═══════════════════════════════════════════════════════════════════════════
-- LOCAL REFERENCES
-- ═══════════════════════════════════════════════════════════════════════════
local _G = _G
local pairs = pairs
local string_find = string.find

-- State: prevents infinite re-entry when we SetPoint during a hook/reapply
local isAnchoring = false

-- Track hooked external frames to avoid double-hooking
local hookedExternalFrames = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- MOUSE PROXY FRAME
-- One shared 1x1 invisible frame that tracks the cursor via a single OnUpdate.
-- Groups with mode="toMouse" anchor directly to this frame — zero taint since
-- it's our own frame. OnUpdate only runs while at least one toMouse group is
-- active; completely idle otherwise.
-- Architecture mirrors WeakAuras' mouseFrame pattern.
-- ═══════════════════════════════════════════════════════════════════════════
local mouseProxyFrame = nil
local mouseProxyConsumers = 0  -- count of active toMouse groups

local function EnsureMouseProxy()
    if mouseProxyFrame then return mouseProxyFrame end
    mouseProxyFrame = CreateFrame("Frame", "ArcUI_CDMGroupMouseProxy", UIParent)
    mouseProxyFrame:SetSize(1, 1)
    mouseProxyFrame:SetPoint("CENTER", UIParent, "CENTER")
    mouseProxyFrame:SetFrameStrata("BACKGROUND")
    return mouseProxyFrame
end

local function MouseProxyOnUpdate()
    local scale = UIParent:GetEffectiveScale()
    if scale and scale > 0 then
        local x, y = GetCursorPosition()
        mouseProxyFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    end
end

local function RegisterMouseConsumer()
    mouseProxyConsumers = mouseProxyConsumers + 1
    if mouseProxyConsumers == 1 then
        EnsureMouseProxy()
        mouseProxyFrame:SetScript("OnUpdate", MouseProxyOnUpdate)
    end
end

local function UnregisterMouseConsumer()
    mouseProxyConsumers = math.max(0, mouseProxyConsumers - 1)
    if mouseProxyConsumers == 0 and mouseProxyFrame then
        mouseProxyFrame:SetScript("OnUpdate", nil)
    end
end

function Anchors.ResetMouseConsumers()
    mouseProxyConsumers = 0
    if mouseProxyFrame then
        mouseProxyFrame:SetScript("OnUpdate", nil)
    end
end

-- Track hooked target frames (toFrame mode) to re-anchor group when target moves
local hookedTargetFrames = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function DebugPrint(msg)
    if ns.lpmsg then ns.lpmsg(msg, "DEBUG") end
end

-- Safely resolve a global frame name to a frame object
local function SafeGetFrame(name)
    if not name or type(name) ~= "string" or name == "" then return nil end
    local frame = _G[name]
    if not frame then return nil end
    if frame.IsForbidden and frame:IsForbidden() then
        DebugPrint("CDMGroupsAnchors: Forbidden frame: " .. name)
        return nil
    end
    return frame
end

-- Get the pixel offset from BOTTOMLEFT of a rect to the given anchor point.
-- Identical to reference Anchors.lua GetAnchorOffset.
local function GetAnchorOffset(width, height, anchorPoint)
    local x, y = 0, 0

    if string_find(anchorPoint, "RIGHT") then
        x = width
    elseif string_find(anchorPoint, "LEFT") then
        x = 0
    else
        x = width / 2
    end

    if string_find(anchorPoint, "TOP") then
        y = height
    elseif string_find(anchorPoint, "BOTTOM") then
        y = 0
    else
        y = height / 2
    end

    return x, y
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SAFE ANCHOR: Position via screen coordinates (breaks taint chain)
--
-- Matches Anchors.lua ns.DoAnchor(force=true) logic exactly:
-- 1. GetRect() on destFrame gives (left, bottom, width, height)
-- 2. Calculate destPoint screen position
-- 3. Subtract source's sourcePoint offset from its BOTTOMLEFT
-- 4. Add user offsets
-- 5. Scale-correct from destFrame's scale space to UIParent's
-- 6. SetPoint BOTTOMLEFT, UIParent, BOTTOMLEFT
-- ═══════════════════════════════════════════════════════════════════════════
local function SafeAnchor(sourceFrame, sourcePoint, destFrame, destPoint, xOffset, yOffset)
    if not sourceFrame or not destFrame then return false end

    local dLeft, dBottom, dWidth, dHeight = destFrame:GetRect()
    if not dLeft or not dWidth or dWidth < 1 then return false end

    -- Guard: if anchoring is secret (instances), GetRect returns secret values
    if issecretvalue(dLeft) or issecretvalue(dWidth) then return false end

    -- Dest anchor point in dest's scale space
    local dAnchorX, dAnchorY = GetAnchorOffset(dWidth, dHeight, destPoint)
    local targetX = dLeft + dAnchorX
    local targetY = dBottom + dAnchorY

    -- Convert target to UIParent scale space
    local dScale = destFrame:GetEffectiveScale()
    local uScale = UIParent:GetEffectiveScale()
    local dRatio = dScale / uScale
    targetX = targetX * dRatio
    targetY = targetY * dRatio

    -- Source dimensions in source's scale space, converted to UIParent space
    local sWidth, sHeight = sourceFrame:GetSize()
    if not sWidth or sWidth < 1 then return false end
    if issecretvalue(sWidth) then return false end

    local sScale = sourceFrame:GetEffectiveScale()
    local sRatio = sScale / uScale
    local sWidthUI = sWidth * sRatio
    local sHeightUI = sHeight * sRatio
    local sAnchorX, sAnchorY = GetAnchorOffset(sWidthUI, sHeightUI, sourcePoint)

    -- Final BOTTOMLEFT position in UIParent scale space
    local finalX = targetX - sAnchorX + (xOffset or 0)
    local finalY = targetY - sAnchorY + (yOffset or 0)

    -- Convert from UIParent coordinate space to source frame's SetPoint space.
    if sRatio ~= 1 then
        finalX = finalX / sRatio
        finalY = finalY / sRatio
    end

    -- Combat guard: ClearAllPoints/SetPoint blocked on protected frames in combat
    if InCombatLockdown() and sourceFrame.IsProtected and sourceFrame:IsProtected() then
        return false
    end

    sourceFrame:ClearAllPoints()
    sourceFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", finalX, finalY)
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SAFE ANCHOR (CENTER): Same taint-free method as SafeAnchor but outputs
-- CENTER anchor point. Required for group-to-group anchoring because the
-- dynamic layout system assumes containers are CENTER-anchored to UIParent.
-- Same principle: only anchors to UIParent, never to the target frame.
-- Uses identical math to SafeAnchor, then converts BOTTOMLEFT → CENTER.
-- ═══════════════════════════════════════════════════════════════════════════
local function SafeAnchorCenter(sourceFrame, sourcePoint, destFrame, destPoint, xOffset, yOffset)
    if not sourceFrame or not destFrame then return false end

    local dLeft, dBottom, dWidth, dHeight = destFrame:GetRect()
    if not dLeft or not dWidth or dWidth < 1 then return false end
    if issecretvalue(dLeft) or issecretvalue(dWidth) then return false end

    -- GetRect() returns screen pixels. Convert to UIParent space.
    local dScale = destFrame:GetEffectiveScale()
    local uScale = UIParent:GetEffectiveScale()
    local dRatio = dScale / uScale
    local dLeftUI   = dLeft   * dRatio
    local dBottomUI = dBottom * dRatio
    local dWidthUI  = dWidth  * dRatio
    local dHeightUI = dHeight * dRatio

    -- Dest anchor point in UIParent space
    local dAnchorX, dAnchorY = GetAnchorOffset(dWidthUI, dHeightUI, destPoint)
    local targetX = dLeftUI + dAnchorX
    local targetY = dBottomUI + dAnchorY

    -- Source dimensions: GetSize() returns local coords. Convert to UIParent space.
    local sWidth, sHeight = sourceFrame:GetSize()
    if not sWidth or sWidth < 1 then return false end
    if issecretvalue(sWidth) then return false end
    local sScale = sourceFrame:GetEffectiveScale()
    local sRatio = sScale / uScale
    local sWidthUI  = sWidth  * sRatio
    local sHeightUI = sHeight * sRatio

    -- Source anchor offset in UIParent space
    local sAnchorX, sAnchorY = GetAnchorOffset(sWidthUI, sHeightUI, sourcePoint)

    -- BOTTOMLEFT position in UIParent space
    local blX = targetX - sAnchorX + (xOffset or 0)
    local blY = targetY - sAnchorY + (yOffset or 0)

    -- Convert BOTTOMLEFT to CENTER offset relative to UIParent CENTER.
    -- All values are now in UIParent space.
    local uWidth, uHeight = UIParent:GetSize()
    local centerX = blX + sWidthUI * 0.5 - uWidth * 0.5
    local centerY = blY + sHeightUI * 0.5 - uHeight * 0.5

    -- Combat guard
    if InCombatLockdown() and sourceFrame.IsProtected and sourceFrame:IsProtected() then
        return false
    end

    sourceFrame:ClearAllPoints()
    sourceFrame:SetPoint("CENTER", UIParent, "CENTER", centerX, centerY)
    return true
end

-- Direct anchor (standard WoW SetPoint - auto-tracks target movement)
local function DirectAnchor(sourceFrame, sourcePoint, destFrame, destPoint, xOffset, yOffset)
    if not sourceFrame or not destFrame then return false end
    if InCombatLockdown() and sourceFrame.IsProtected and sourceFrame:IsProtected() then
        return false
    end
    sourceFrame:ClearAllPoints()
    sourceFrame:SetPoint(sourcePoint, destFrame, destPoint, xOffset, yOffset)
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ANCHOR DEFAULTS - All disabled per ArcUI convention
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.GetDefaults()
    return {
        enabled       = false,
        mode          = "none",
        targetGroup   = "",
        targetFrame   = "",
        sourcePoint   = "TOP",
        destPoint     = "BOTTOM",
        offsetX       = 0,
        offsetY       = 0,
        useSafeAnchor = true,
        snapBack      = false,
        trackTarget   = false,
        -- list of external frames anchored to this group
        anchoredFrames = {},
    }
end

function Anchors.GetFrameEntryDefaults()
    return {
        frameName     = "",
        sourcePoint   = "BOTTOM",
        destPoint     = "TOP",
        offsetX       = 0,
        offsetY       = 0,
        useSafeAnchor = false, -- anchors to our own anchorProxy, no taint concern
        snapBack      = false,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- APPLY ANCHOR FOR A SINGLE GROUP
-- Two independent steps:
--   1. Position the GROUP itself (mode: toGroup, toFrame, or none)
--   2. Position EXTERNAL FRAMES attached to this group (anchoredFrames[])
-- Both run independently — you can anchor the group to PlayerFrame
-- AND have Sensei bars anchored to this same group.
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.ApplyGroupAnchor(group)
    if not group or not group.anchor or not group.anchor.enabled then return false end
    if InCombatLockdown() then return false end
    if isAnchoring then return false end

    local cfg = group.anchor
    local mode = cfg.mode or "none"
    if not group.container then return false end

    isAnchoring = true
    local applied = false

    -- ─── STEP 1: Position the group itself ───────────────────────────
    if mode == "toGroup" then
        local targetName = cfg.targetGroup
        if targetName and targetName ~= "" and targetName ~= group.name then
            local targetGroup = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[targetName]
            if targetGroup and targetGroup.container then
                if cfg.useSafeAnchor then
                    applied = SafeAnchorCenter(
                        group.container,
                        cfg.sourcePoint or "TOP",
                        targetGroup.container,
                        cfg.destPoint or "BOTTOM",
                        cfg.offsetX or 0,
                        cfg.offsetY or 0
                    )
                    -- Fallback: if safe failed (secret/combat), try direct
                    if not applied then
                        applied = DirectAnchor(
                            group.container,
                            cfg.sourcePoint or "TOP",
                            targetGroup.container,
                            cfg.destPoint or "BOTTOM",
                            cfg.offsetX or 0,
                            cfg.offsetY or 0
                        )
                    end
                else
                    applied = DirectAnchor(
                        group.container,
                        cfg.sourcePoint or "TOP",
                        targetGroup.container,
                        cfg.destPoint or "BOTTOM",
                        cfg.offsetX or 0,
                        cfg.offsetY or 0
                    )
                end
                if applied then
                    -- Update group.position to reflect the new anchor position.
                    -- This prevents stale dragged position from overriding if
                    -- SnapContainerPositionToPixel fires before the next re-anchor.
                    C_Timer.After(0.03, function()
                        if group.container and group.position then
                            local cx = group.container:GetCenter()
                            local uScale = UIParent:GetEffectiveScale()
                            local cScale = group.container:GetEffectiveScale()
                            if cx and uScale and uScale > 0 then
                                local uW, uH = UIParent:GetSize()
                                group.position.x = (group.container:GetLeft() + group.container:GetWidth() * 0.5 - uW * 0.5) * (cScale / uScale)
                                group.position.y = (group.container:GetBottom() + group.container:GetHeight() * 0.5 - uH * 0.5) * (cScale / uScale)
                            end
                        end
                        if ns.CDMGroups.SyncAnchorProxy then
                            ns.CDMGroups.SyncAnchorProxy(group)
                        end
                    end)
                    -- Hook target group's container so we follow during drags
                    Anchors.HookContainerForDragTracking(targetGroup)
                    DebugPrint("CDMGroupsAnchors: " .. group.name .. " > group " .. targetName)
                end
            end
        end

    elseif mode == "toFrame" then
        local targetFrame = SafeGetFrame(cfg.targetFrame)
        if targetFrame then
            if cfg.useSafeAnchor then
                applied = SafeAnchorCenter(
                    group.container,
                    cfg.sourcePoint or "TOP",
                    targetFrame,
                    cfg.destPoint or "BOTTOM",
                    cfg.offsetX or 0,
                    cfg.offsetY or 0
                )
                -- Fallback: if safe failed (secret/combat), try direct
                if not applied then
                    applied = DirectAnchor(
                        group.container,
                        cfg.sourcePoint or "TOP",
                        targetFrame,
                        cfg.destPoint or "BOTTOM",
                        cfg.offsetX or 0,
                        cfg.offsetY or 0
                    )
                end
            else
                applied = DirectAnchor(
                    group.container,
                    cfg.sourcePoint or "TOP",
                    targetFrame,
                    cfg.destPoint or "BOTTOM",
                    cfg.offsetX or 0,
                    cfg.offsetY or 0
                )
            end
            if applied then
                C_Timer.After(0.03, function()
                    if group.container and group.position then
                        local uScale = UIParent:GetEffectiveScale()
                        local cScale = group.container:GetEffectiveScale()
                        if uScale and uScale > 0 then
                            local uW, uH = UIParent:GetSize()
                            group.position.x = (group.container:GetLeft() + group.container:GetWidth() * 0.5 - uW * 0.5) * (cScale / uScale)
                            group.position.y = (group.container:GetBottom() + group.container:GetHeight() * 0.5 - uH * 0.5) * (cScale / uScale)
                        end
                    end
                    if ns.CDMGroups.SyncAnchorProxy then
                        ns.CDMGroups.SyncAnchorProxy(group)
                    end
                end)
                -- Hook target so group tracks it when it moves (only if user enabled)
                if cfg.trackTarget then
                    Anchors.HookTargetFrame(cfg.targetFrame, group)
                end
                DebugPrint("CDMGroupsAnchors: " .. group.name .. " > frame " .. cfg.targetFrame)
            end
        end
    elseif mode == "toMouse" then
        EnsureMouseProxy()
        local sourcePoint = cfg.sourcePoint or "CENTER"
        group.container:ClearAllPoints()
        group.container:SetPoint(sourcePoint, mouseProxyFrame, "BOTTOMLEFT", cfg.offsetX or 0, cfg.offsetY or 0)
        applied = true
        RegisterMouseConsumer()
        C_Timer.After(0.02, function()
            if ns.CDMGroups.SyncAnchorProxy then
                ns.CDMGroups.SyncAnchorProxy(group)
            end
        end)
        DebugPrint("CDMGroupsAnchors: " .. group.name .. " > mouse cursor")
    end
    -- mode == "none": group stays where the user dragged it

    -- ─── STEP 2: Anchored external frames (always runs) ─────────────
    Anchors.ApplyAnchoredFrames(group)

    isAnchoring = false
    return applied
end

-- ═══════════════════════════════════════════════════════════════════════════
-- APPLY ANCHORED FRAMES ONLY (Step 2)
-- Positions external frames relative to the group's anchorProxy.
-- Separated from ApplyGroupAnchor so ReapplyDependents can call it
-- without re-triggering the group's own position anchor (which would loop).
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.ApplyAnchoredFrames(group)
    if not group or not group.anchor then return end
    local cfg = group.anchor
    if not cfg.enabled then return end
    local frames = cfg.anchoredFrames
    if not frames or #frames == 0 or not group.container then return end
    
    -- Lightweight proxy sync: copy container rect to anchorProxy NOW
    -- so SafeAnchor reads current position. Can't call full SyncAnchorProxy
    -- because it triggers ReapplyDependents → ApplyAnchoredFrames → loop.
    local proxyFrame = group.anchorProxy
    if proxyFrame then
        local left, bottom, width, height = group.container:GetRect()
        if left and width and width >= 1 then
            local cScale = group.container:GetEffectiveScale()
            local uScale = UIParent:GetEffectiveScale()
            local ratio = cScale / uScale
            proxyFrame:ClearAllPoints()
            proxyFrame:SetSize(width, height)
            proxyFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * ratio, bottom * ratio)
        end
    end
    proxyFrame = proxyFrame or group.container
    local containerFrame = group.container
    
    local wasAnchoring = isAnchoring
    isAnchoring = true
    
    for i, entry in ipairs(frames) do
        if entry.frameName and entry.frameName ~= "" then
            local extFrame = SafeGetFrame(entry.frameName)
            if extFrame then
                -- ═══════════════════════════════════════════════════════════════
                -- PROFILE-BASED OWNERSHIP: Checked during ALL apply paths.
                -- If the active profile recorded which group owns this frame,
                -- respect it. Runtime tag fallback only during ReapplyAll.
                -- User-driven applies (ClaimFrameOwnership) update the map first.
                -- ═══════════════════════════════════════════════════════════════
                local skipEntry = false
                local ownerMap = ns._activeFrameOwnership
                -- Profile ownership: always respected (inline + ReapplyAll)
                if ownerMap and ownerMap[entry.frameName] and ownerMap[entry.frameName] ~= group.name then
                    DebugPrint("CDMGroupsAnchors: Skipping", entry.frameName, "- profile assigns to", ownerMap[entry.frameName], "not", group.name)
                    skipEntry = true
                -- Runtime tag fallback: only during ReapplyAll (batch), not inline
                elseif Anchors._inReapplyAll and (not ownerMap or not ownerMap[entry.frameName]) then
                    if extFrame._arcAnchoredByGroup and extFrame._arcAnchoredByGroup ~= group.name then
                        DebugPrint("CDMGroupsAnchors: Skipping", entry.frameName, "- runtime owned by", extFrame._arcAnchoredByGroup, "not", group.name)
                        skipEntry = true
                    end
                end
                if not skipEntry then
                -- Save original anchors ONCE before we modify this frame
                -- (only if we haven't saved them yet for this frame)
                if not extFrame._arcOriginalAnchors then
                    local numPoints = extFrame:GetNumPoints()
                    if numPoints and numPoints > 0 then
                        local saved = {}
                        for p = 1, numPoints do
                            local point, relTo, relPoint, xOfs, yOfs = extFrame:GetPoint(p)
                            if point then
                                saved[p] = { point = point, relTo = relTo, relPoint = relPoint, x = xOfs, y = yOfs }
                            end
                        end
                        if #saved > 0 then
                            extFrame._arcOriginalAnchors = saved
                            DebugPrint("CDMGroupsAnchors: Saved", #saved, "original anchors for", entry.frameName)
                        else
                            DebugPrint("CDMGroupsAnchors: WARNING - 0 valid points for", entry.frameName, "numPoints=", numPoints)
                        end
                    else
                        DebugPrint("CDMGroupsAnchors: WARNING - GetNumPoints=", tostring(numPoints), "for", entry.frameName)
                    end
                end
                local entryApplied
                if entry.useSafeAnchor then
                    -- SafeAnchor: use anchorProxy (matches visual icon area, no title/padding offset)
                    entryApplied = SafeAnchor(
                        extFrame,
                        entry.sourcePoint or "BOTTOM",
                        proxyFrame,
                        entry.destPoint or "TOP",
                        entry.offsetX or 0,
                        entry.offsetY or 0
                    )
                    -- Fallback: if safe failed (secret/combat), try direct anchor
                    if not entryApplied then
                        entryApplied = DirectAnchor(
                            extFrame,
                            entry.sourcePoint or "BOTTOM",
                            containerFrame,
                            entry.destPoint or "TOP",
                            entry.offsetX or 0,
                            entry.offsetY or 0
                        )
                    end
                else
                    -- DirectAnchor: use container (real WoW anchor chain for drag following)
                    entryApplied = DirectAnchor(
                        extFrame,
                        entry.sourcePoint or "BOTTOM",
                        containerFrame,
                        entry.destPoint or "TOP",
                        entry.offsetX or 0,
                        entry.offsetY or 0
                    )
                end
                if entryApplied then
                    DebugPrint("CDMGroupsAnchors: frame " .. entry.frameName .. " > " .. group.name .. " [" .. i .. "]")
                    -- Tag frame for runtime tracking
                    extFrame._arcAnchoredByGroup = group.name
                    -- Record in profile ownership map ONLY during ReapplyAll or if no prior claim
                    -- This prevents inline applies (SyncAnchorProxy path) from overwriting
                    -- the profile's saved ownership during LoadProfile
                    if not ns._activeFrameOwnership then ns._activeFrameOwnership = {} end
                    if Anchors._inReapplyAll or not ns._activeFrameOwnership[entry.frameName] then
                        ns._activeFrameOwnership[entry.frameName] = group.name
                    end
                    if entry.snapBack then
                        extFrame._arcAnchorData = {
                            destFrame   = entry.useSafeAnchor and proxyFrame or containerFrame,
                            sourcePoint = entry.sourcePoint or "BOTTOM",
                            destPoint   = entry.destPoint or "TOP",
                            offsetX     = entry.offsetX or 0,
                            offsetY     = entry.offsetY or 0,
                            useSafeAnchor = entry.useSafeAnchor,
                        }
                        Anchors.HookExternalFrame(entry.frameName, group)
                    end
                end
                end -- not skipEntry
            end
        end
    end
    
    -- Hook group's own container for drag tracking
    Anchors.HookContainerForDragTracking(group)
    
    isAnchoring = wasAnchoring
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HOOK CONTAINER FOR DRAG TRACKING
-- Hooks StartMoving/StopMovingOrSizing on a group's container. During drag,
-- runs a temporary OnUpdate every frame to recalc safe-anchored dependents.
-- Zero CPU when idle — OnUpdate only exists while mouse button is held.
-- Covers both: groups anchored TO this group, and external frames on it.
-- ═══════════════════════════════════════════════════════════════════════════
local hookedGroupContainers = {}
function Anchors.HookContainerForDragTracking(group)
    if not group or not group.name or not group.container then return end
    local container = group.container
    
    -- If we hooked this group name before but container changed (profile switch),
    -- clear the stale entry so we can hook the new container
    if hookedGroupContainers[group.name] and container._arcDragGroupHooked then
        return  -- Same container, already hooked
    end
    hookedGroupContainers[group.name] = true
    container._arcDragGroupHooked = true
    
    local groupName = group.name
    
    -- Reapply function: handles both toGroup dependents and anchored frames
    local function ReapplyDuringDrag()
        if isAnchoring then return end
        if InCombatLockdown() then return end
        -- Reapply groups anchored TO this group (toGroup with safe anchor)
        if ns.CDMGroups and ns.CDMGroups.groups then
            for _, otherGroup in pairs(ns.CDMGroups.groups) do
                if otherGroup.anchor and otherGroup.anchor.enabled then
                    local cfg = otherGroup.anchor
                    if cfg.mode == "toGroup" and cfg.targetGroup == groupName and cfg.useSafeAnchor then
                        isAnchoring = true
                        local ok = SafeAnchorCenter(
                            otherGroup.container,
                            cfg.sourcePoint or "TOP",
                            container,
                            cfg.destPoint or "BOTTOM",
                            cfg.offsetX or 0,
                            cfg.offsetY or 0
                        )
                        if not ok then
                            DirectAnchor(
                                otherGroup.container,
                                cfg.sourcePoint or "TOP",
                                container,
                                cfg.destPoint or "BOTTOM",
                                cfg.offsetX or 0,
                                cfg.offsetY or 0
                            )
                        end
                        isAnchoring = false
                        -- Cascade: if otherGroup also has anchored frames, update them too
                        Anchors.ApplyAnchoredFrames(otherGroup)
                    end
                end
            end
        end
        -- Reapply safe-anchored external frames on this group
        Anchors.ApplyAnchoredFrames(group)
    end
    
    -- Hook StartMoving: set drag flag, start self-terminating OnUpdate
    -- NOTE: We do NOT save/restore the existing OnUpdate — that pattern breaks
    -- when StartMoving fires twice (hooksecurefunc can stack), causing the drag
    -- OnUpdate to be saved as _arcDragUpdate and restored permanently on stop.
    -- Instead we use a flag that the OnUpdate checks to self-terminate.
    hooksecurefunc(container, "StartMoving", function()
        container._arcIsDragging = true
        if not container._arcDragOnUpdateActive then
            container._arcDragOnUpdateActive = true
            container:SetScript("OnUpdate", function()
                if not container._arcIsDragging then
                    -- Drag ended — self-terminate
                    container:SetScript("OnUpdate", nil)
                    container._arcDragOnUpdateActive = false
                    return
                end
                ReapplyDuringDrag()
            end)
        end
    end)
    
    -- Hook StopMovingOrSizing: clear drag flag, do final reapply
    -- The OnUpdate will self-terminate on the next frame.
    hooksecurefunc(container, "StopMovingOrSizing", function()
        container._arcIsDragging = nil
        ReapplyDuringDrag()  -- final snap
    end)
    
    -- Also hook SetPoint for programmatic moves (not drags)
    -- ONLY fire if container is actively being dragged — prevents cascade
    -- during LoadProfile/ReapplyAll when containers get repositioned
    hooksecurefunc(container, "SetPoint", function()
        if not container._arcIsDragging then return end
        if isAnchoring then return end
        if InCombatLockdown() then return end
        ReapplyDuringDrag()
    end)

    -- Hook OnSizeChanged: re-anchor dependents after dynamic layout resizes the container.
    -- When dynamic layout compacts icons, it: (1) shrinks the container, (2) shifts its
    -- CENTER by _contentCenterX/Y. SyncAnchorProxy fires between these two steps, so
    -- SafeAnchorCenter reads the wrong rect (old size at new center).
    -- C_Timer.After(0) defers the re-anchor until AFTER the center-sync SetPoint has
    -- also completed in the same tick — GetRect() then returns the final size+position.
    -- _arcSizeChangedPending debounces burst OnSizeChanged events (one deferred call max).
    if container.HookScript then
        container:HookScript("OnSizeChanged", function()
            if container._arcIsDragging then return end  -- drag hook handles drags
            if isAnchoring then return end
            if InCombatLockdown() then return end
            if container._arcSizeChangedPending then return end
            container._arcSizeChangedPending = true
            C_Timer.After(0, function()
                container._arcSizeChangedPending = false
                if InCombatLockdown() then return end
                ReapplyDuringDrag()
            end)
        end)
    end

    DebugPrint("CDMGroupsAnchors: Drag tracking hooked on " .. groupName .. " container")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HOOK EXTERNAL FRAME: Snap back if something else moves it
-- Stores anchor data on the frame itself. Hooks both SetPoint and
-- SetAllPoints. Uses per-frame guard (_arcAnchorMoving) to prevent
-- infinite recursion when our own SetPoint triggers the hook.
-- ═══════════════════════════════════════════════════════════════════════════

local function EnforceFrameAnchor(frame)
    if not frame or not frame._arcAnchorData then return end
    if frame._arcAnchorMoving then return end
    if isAnchoring then return end
    -- Allow non-protected frames to snap back even in combat
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then return end
    
    local data = frame._arcAnchorData
    frame._arcAnchorMoving = true
    
    if data.useSafeAnchor then
        local ok = SafeAnchor(frame, data.sourcePoint, data.destFrame, data.destPoint, data.offsetX, data.offsetY)
        if not ok then
            DirectAnchor(frame, data.sourcePoint, data.destFrame, data.destPoint, data.offsetX, data.offsetY)
        end
    else
        DirectAnchor(frame, data.sourcePoint, data.destFrame, data.destPoint, data.offsetX, data.offsetY)
    end
    
    frame._arcAnchorMoving = false
end

function Anchors.HookExternalFrame(frameName, group)
    if not frameName or frameName == "" then return end
    local frame = SafeGetFrame(frameName)
    if not frame or not frame.SetPoint then return end

    local hookKey = frameName .. "_" .. group.name
    if hookedExternalFrames[hookKey] then return end

    hookedExternalFrames[hookKey] = true
    
    -- Hook SetPoint
    hooksecurefunc(frame, "SetPoint", function(f)
        EnforceFrameAnchor(f)
    end)
    
    -- Hook SetAllPoints (edit mode / layout resets often use this)
    if frame.SetAllPoints then
        hooksecurefunc(frame, "SetAllPoints", function(f)
            EnforceFrameAnchor(f)
        end)
    end
    
    DebugPrint("CDMGroupsAnchors: Hooked SetPoint+SetAllPoints on " .. frameName .. " for snap-back")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HOOK TARGET FRAME: Re-anchor group when its toFrame target moves
-- For safe-anchor mode, the group is anchored to UIParent at calculated
-- coordinates, so it won't track the target automatically. This hook
-- re-runs the anchor calculation when the target frame's position changes.
-- Also useful for direct anchors with ElvUI frames that re-parent/re-anchor.
-- Hooks the target, its ANCHOR CHAIN (the frames it's SetPoint'd to — e.g.
-- ElvUI movers), AND StopMovingOrSizing on each for drag-end detection.
-- When you drag an ElvUI mover, the child frame follows via WoW's anchor
-- system without calling SetPoint, so we must hook the mover directly.
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.HookTargetFrame(frameName, group)
    if not frameName or frameName == "" then return end
    local frame = SafeGetFrame(frameName)
    if not frame or not frame.SetPoint then return end

    local hookKey = frameName .. "_target_" .. group.name
    if hookedTargetFrames[hookKey] then return end

    hookedTargetFrames[hookKey] = true

    local function OnTargetMoved()
        if isAnchoring then return end
        if InCombatLockdown() then return end
        Anchors.ApplyGroupAnchor(group)
    end

    -- Helper: hook SetPoint, SetAllPoints, StopMovingOrSizing on a frame
    local function HookFrame(f, key)
        if hookedTargetFrames[key] then return end
        if f.IsForbidden and f:IsForbidden() then return end
        hookedTargetFrames[key] = true
        if f.SetPoint then
            hooksecurefunc(f, "SetPoint", OnTargetMoved)
        end
        if f.SetAllPoints then
            hooksecurefunc(f, "SetAllPoints", OnTargetMoved)
        end
        if f.StopMovingOrSizing then
            hooksecurefunc(f, "StopMovingOrSizing", OnTargetMoved)
        end
    end

    -- Hook the target frame itself
    HookFrame(frame, hookKey)

    -- Walk ANCHOR chain: find the frame(s) this target is SetPoint'd to
    -- This catches ElvUI movers (ElvUF_Player is anchored to ElvUF_PlayerMover)
    local seen = { [frame] = true }
    local current = frame
    for depth = 1, 4 do
        local numPoints = current.GetNumPoints and current:GetNumPoints() or 0
        if numPoints == 0 then break end
        local _, _, relFrame = current:GetPoint(1)
        if not relFrame then break end
        if relFrame == UIParent or relFrame == WorldFrame then break end
        if seen[relFrame] then break end
        seen[relFrame] = true
        local relName = relFrame.GetName and relFrame:GetName() or tostring(relFrame)
        local relKey = relName .. "_targetanchor_" .. group.name
        HookFrame(relFrame, relKey)
        DebugPrint("CDMGroupsAnchors: Hooked anchor-chain frame " .. relName .. " [depth " .. depth .. "]")
        current = relFrame
    end

    -- Also walk parent chain (some addons parent-anchor, e.g. container > mover)
    local parent = frame:GetParent()
    for depth = 1, 2 do
        if not parent then break end
        if parent == UIParent or parent == WorldFrame then break end
        if seen[parent] then break end
        seen[parent] = true
        local pName = parent.GetName and parent:GetName() or tostring(parent)
        local pKey = pName .. "_targetparent_" .. group.name
        HookFrame(parent, pKey)
        DebugPrint("CDMGroupsAnchors: Hooked parent frame " .. pName .. " [depth " .. depth .. "]")
        parent = parent:GetParent()
    end

    DebugPrint("CDMGroupsAnchors: Tracking target " .. frameName .. " for group " .. group.name)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REAPPLY ALL ANCHORS
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.ReapplyAll()
    if InCombatLockdown() then return end
    if isAnchoring then return end
    if not ns.CDMGroups or not ns.CDMGroups.groups then return end

    -- Flag: ownership check in ApplyAnchoredFrames only fires during ReapplyAll
    -- User-driven applies (drag, UI picker) bypass the check and update ownership
    Anchors._inReapplyAll = true
    for _, group in pairs(ns.CDMGroups.groups) do
        if group.anchor and group.anchor.enabled then
            Anchors.ApplyGroupAnchor(group)
        end
    end
    Anchors._inReapplyAll = false
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REAPPLY DEPENDENTS
-- Called from SyncAnchorProxy when a group's proxy position/size updates.
-- This is how safe-anchored groups track target group movement:
--   1. User drags group "Essential"
--   2. SyncAnchorProxy fires for "Essential"
--   3. ReapplyDependents("Essential") finds all groups anchored TO Essential
--   4. Re-runs their safe anchor calculation with Essential's new position
-- Also re-anchors external frames attached to the moved group.
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.ReapplyDependents(targetGroupName)
    if InCombatLockdown() then return end
    if isAnchoring then return end
    if not targetGroupName or not ns.CDMGroups or not ns.CDMGroups.groups then return end

    for _, group in pairs(ns.CDMGroups.groups) do
        if group.anchor and group.anchor.enabled then
            local cfg = group.anchor
            -- Groups whose container is anchored TO the target group
            if cfg.mode == "toGroup" and cfg.targetGroup == targetGroupName then
                Anchors.ApplyGroupAnchor(group)
            -- This group moved — re-anchor any external frames attached to it
            -- Only Step 2 (ApplyAnchoredFrames), NOT full ApplyGroupAnchor,
            -- to avoid re-triggering SyncAnchorProxy → ReapplyDependents loop
            elseif group.name == targetGroupName and cfg.anchoredFrames and #cfg.anchoredFrames > 0 then
                Anchors.ApplyAnchoredFrames(group)
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CHECK IF GROUP IS ANCHORED (position overridden by anchor target)
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.IsGroupAnchored(group)
    if not group or not group.anchor then return false end
    local cfg = group.anchor
    if not cfg.enabled then return false end
    return cfg.mode == "toGroup" or cfg.mode == "toFrame"
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GET AVAILABLE GROUP NAMES (for target dropdown, excluding self)
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.GetAvailableGroups(excludeName)
    local result = {}
    if not ns.CDMGroups or not ns.CDMGroups.groups then return result end
    for name, _ in pairs(ns.CDMGroups.groups) do
        if name ~= excludeName then
            result[name] = name
        end
    end
    return result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SERIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.Serialize(anchorData)
    if not anchorData then return nil end
    if not anchorData.enabled and (not anchorData.mode or anchorData.mode == "none") then
        -- Still save if anchoredFrames configured (user may enable later)
        if not anchorData.anchoredFrames or #anchorData.anchoredFrames == 0 then
            return nil
        end
    end
    
    local serializedFrames = {}
    if anchorData.anchoredFrames then
        for i, entry in ipairs(anchorData.anchoredFrames) do
            serializedFrames[i] = {
                frameName     = entry.frameName or "",
                sourcePoint   = entry.sourcePoint or "BOTTOM",
                destPoint     = entry.destPoint or "TOP",
                offsetX       = entry.offsetX or 0,
                offsetY       = entry.offsetY or 0,
                useSafeAnchor = entry.useSafeAnchor or false,
                snapBack      = entry.snapBack or false,
            }
        end
    end
    
    return {
        enabled       = anchorData.enabled or false,
        mode          = anchorData.mode or "none",
        targetGroup   = anchorData.targetGroup or "",
        targetFrame   = anchorData.targetFrame or "",
        sourcePoint   = anchorData.sourcePoint or "TOP",
        destPoint     = anchorData.destPoint or "BOTTOM",
        offsetX       = anchorData.offsetX or 0,
        offsetY       = anchorData.offsetY or 0,
        useSafeAnchor = anchorData.useSafeAnchor ~= false,
        snapBack      = anchorData.snapBack or false,
        trackTarget   = anchorData.trackTarget or false,
        anchoredFrames = serializedFrames,
    }
end

function Anchors.Deserialize(savedData)
    if not savedData then return Anchors.GetDefaults() end
    
    local frames = {}
    if savedData.anchoredFrames then
        for i, entry in ipairs(savedData.anchoredFrames) do
            frames[i] = {
                frameName     = entry.frameName or "",
                sourcePoint   = entry.sourcePoint or "BOTTOM",
                destPoint     = entry.destPoint or "TOP",
                offsetX       = entry.offsetX or 0,
                offsetY       = entry.offsetY or 0,
                useSafeAnchor = entry.useSafeAnchor or false,
                snapBack      = entry.snapBack or false,
            }
        end
    end
    
    -- Backward compat: migrate old single-frame frameToGroup to list entry
    if savedData.mode == "frameToGroup" and savedData.targetFrame and savedData.targetFrame ~= "" and #frames == 0 then
        frames[1] = {
            frameName     = savedData.targetFrame,
            sourcePoint   = savedData.sourcePoint or "TOP",
            destPoint     = savedData.destPoint or "BOTTOM",
            offsetX       = savedData.offsetX or 0,
            offsetY       = savedData.offsetY or 0,
            useSafeAnchor = savedData.useSafeAnchor ~= false,
            snapBack      = savedData.snapBack or false,
        }
    end
    
    -- Migrate old frameToGroup mode (anchoredFrames are now independent of mode)
    local mode = savedData.mode or "none"
    local targetFrame = savedData.targetFrame or ""
    local targetGroup = savedData.targetGroup or ""
    if mode == "frameToGroup" then
        mode = "none"
        targetFrame = ""  -- was migrated into anchoredFrames, don't leave stale data
        targetGroup = ""
    end
    
    return {
        enabled       = savedData.enabled or false,
        mode          = mode,
        targetGroup   = targetGroup,
        targetFrame   = targetFrame,
        sourcePoint   = savedData.sourcePoint or "TOP",
        destPoint     = savedData.destPoint or "BOTTOM",
        offsetX       = savedData.offsetX or 0,
        offsetY       = savedData.offsetY or 0,
        useSafeAnchor = savedData.useSafeAnchor ~= false,
        snapBack      = savedData.snapBack or false,
        trackTarget   = savedData.trackTarget or false,
        anchoredFrames = frames,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DETACH ALL EXTERNAL FRAMES FROM A GROUP
-- Called before group destruction during profile/spec switch.
-- Restores original anchor points so frames like PlayerFrame aren't stranded.
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.DetachAllExternalFrames(group)
    if not group or not group.anchor then return end
    local frames = group.anchor.anchoredFrames
    if not frames then return end

    DebugPrint("CDMGroupsAnchors: DetachAllExternalFrames for group:", group.name, "entries:", #frames)

    -- Clear stale hook guard so new container can be hooked after profile switch
    if group.name then
        hookedGroupContainers[group.name] = nil
    end

    -- Clear hookedExternalFrames entries for this group so HookExternalFrame
    -- re-runs on the next ReapplyAll after spec/profile switch.
    -- Without this the guard `if hookedExternalFrames[hookKey] then return end`
    -- permanently blocks re-writing _arcAnchorData, breaking snap-back forever
    -- after the first spec switch even though DetachAllExternalFrames cleared it.
    if group.name then
        local suffix = "_" .. group.name
        for key in pairs(hookedExternalFrames) do
            if key:sub(-#suffix) == suffix then
                hookedExternalFrames[key] = nil
            end
        end
    end

    for _, entry in ipairs(frames) do
        if entry.frameName and entry.frameName ~= "" then
            local extFrame = SafeGetFrame(entry.frameName)
            if extFrame then
                -- CRITICAL: Clear snap-back data FIRST, before any SetPoint calls.
                -- EnforceFrameAnchor is hooked via hooksecurefunc (permanent).
                -- If _arcAnchorData still exists when we call SetPoint to restore,
                -- the hook fires and immediately re-anchors to the old position.
                extFrame._arcAnchorData = nil
                extFrame._arcAnchorMoving = nil
                extFrame._arcAnchoredByGroup = nil

                -- Restore original anchors if we saved them
                if extFrame._arcOriginalAnchors then
                    -- Combat guard: can't modify protected frames in combat
                    if not InCombatLockdown() or not (extFrame.IsProtected and extFrame:IsProtected()) then
                        extFrame:ClearAllPoints()
                        for _, anchor in ipairs(extFrame._arcOriginalAnchors) do
                            local relTo = anchor.relTo
                            -- If relTo was our container/proxy that's being destroyed, anchor to UIParent
                            if relTo and (relTo == group.container or relTo == group.anchorProxy) then
                                relTo = UIParent
                            end
                            extFrame:SetPoint(anchor.point, relTo or UIParent, anchor.relPoint, anchor.x or 0, anchor.y or 0)
                        end
                        DebugPrint("CDMGroupsAnchors: Restored", #extFrame._arcOriginalAnchors, "original anchors for", entry.frameName)
                    else
                        DebugPrint("CDMGroupsAnchors: BLOCKED by combat for", entry.frameName)
                    end
                else
                    DebugPrint("CDMGroupsAnchors: No _arcOriginalAnchors for", entry.frameName, "- nothing to restore")
                end

                -- CRITICAL: Always clear _arcOriginalAnchors after detach.
                -- If the frame now belongs to a DIFFERENT group in the new spec/profile,
                -- the stale saved anchors would restore to the WRONG position.
                -- Clearing here forces the new profile's first ApplyAnchoredFrames
                -- to re-capture the frame's actual current anchors as the new baseline.
                extFrame._arcOriginalAnchors = nil
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RESET ALL HOOK STATE (spec/profile switch)
-- Wipes ALL hook guard tables so every hook re-runs cleanly in the new spec.
-- Called by CDMGroups.OnSpecChange AFTER DetachAllExternalFrames so frames
-- are already restored before we drop the guards.
-- hookedGroupContainers is intentionally kept — containers are reused from the
-- pool and their hooksecurefunc hooks are permanent; re-hooked on new container.
-- hookedTargetFrames is cleared so toFrame/trackTarget groups re-hook their
-- target frame's SetPoint in the new spec (target may be a different frame).
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.ResetAllHookState()
    wipe(hookedExternalFrames)
    wipe(hookedTargetFrames)
    -- hookedGroupContainers: cleared per-group in DetachAllExternalFrames, not here
    DebugPrint("CDMGroupsAnchors: ResetAllHookState — hook guards cleared for spec/profile switch")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API: Claim ownership of an external frame for a group.
-- Call this from the UI picker when the user assigns a frame to a group.
-- Automatically removes the frame from any previous group's claim.
-- ═══════════════════════════════════════════════════════════════════════════
function Anchors.ClaimFrameOwnership(frameName, groupName)
    if not ns._activeFrameOwnership then ns._activeFrameOwnership = {} end
    ns._activeFrameOwnership[frameName] = groupName
    DebugPrint("CDMGroupsAnchors: ClaimFrameOwnership:", frameName, "->", groupName)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENT-DRIVEN REAPPLY: Combat end, vehicles, edit mode, cinematics
-- Catches cases where frames move without calling SetPoint directly.
-- ═══════════════════════════════════════════════════════════════════════════
local anchorEventFrame = CreateFrame("Frame")
anchorEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
anchorEventFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
anchorEventFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
anchorEventFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
anchorEventFrame:RegisterEvent("CINEMATIC_STOP")
anchorEventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
        if arg1 ~= "player" then return end
    end
    C_Timer.After(0.1, Anchors.ReapplyAll)
end)
-- Edit Mode: reapply when user exits edit mode (frames get repositioned)
if C_EditMode then
    anchorEventFrame:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ANCHOR POINT CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════
Anchors.ANCHOR_POINTS = {
    ["TOPLEFT"]     = "Top Left",
    ["TOP"]         = "Top",
    ["TOPRIGHT"]    = "Top Right",
    ["LEFT"]        = "Left",
    ["CENTER"]      = "Center",
    ["RIGHT"]       = "Right",
    ["BOTTOMLEFT"]  = "Bottom Left",
    ["BOTTOM"]      = "Bottom",
    ["BOTTOMRIGHT"] = "Bottom Right",
}

Anchors.ANCHOR_POINTS_SORTED = {
    "TOPLEFT", "TOP", "TOPRIGHT",
    "LEFT", "CENTER", "RIGHT",
    "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

-- ═══════════════════════════════════════════════════════════════════════════
-- COMMON FRAME PRESETS
-- ═══════════════════════════════════════════════════════════════════════════
Anchors.COMMON_FRAMES = {
    [""]              = "— Select preset —",
    ["PlayerFrame"]   = "Player Frame",
    ["TargetFrame"]   = "Target Frame",
    ["FocusFrame"]    = "Focus Frame",
    ["PlayerCastingBarFrame"] = "Player Cast Bar",
    ["TargetFrameSpellBar"]   = "Target Cast Bar",
    ["BuffFrame"]     = "Buff Frame",
    ["DebuffFrame"]   = "Debuff Frame",
    ["MinimapCluster"] = "Minimap",
    ["MicroMenuContainer"] = "Micro Menu",
    ["MainMenuBarVehicleLeaveButton"] = "Leave Vehicle Btn",
    ["ChatFrame1"]    = "Chat Frame 1",
}

Anchors.COMMON_FRAMES_SORTED = {
    "", "PlayerFrame", "TargetFrame", "FocusFrame",
    "PlayerCastingBarFrame", "TargetFrameSpellBar",
    "BuffFrame", "DebuffFrame",
    "MinimapCluster", "MicroMenuContainer",
    "MainMenuBarVehicleLeaveButton", "ChatFrame1",
}

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME PICKER: Mouse-over to find frame names
-- Uses SetPropagateMouseMotion so GetMouseFoci sees frames underneath,
-- while the picker still captures mouse clicks for selection.
-- ═══════════════════════════════════════════════════════════════════════════
local pickerFrame = nil
local pickerCallback = nil
local pickerTooltip = nil
local pickerTicker = nil
local pickerLastName = nil  -- last detected frame name (for click handler)

local function StopPicker()
    if pickerTicker then
        pickerTicker:Cancel()
        pickerTicker = nil
    end
    if pickerFrame then pickerFrame:Hide() end
    if pickerTooltip then pickerTooltip:Hide() end
    pickerCallback = nil
    pickerLastName = nil
end

local function GetTopNamedFrame()
    local frames = GetMouseFoci and GetMouseFoci() or (GetMouseFocus and {GetMouseFocus()} or nil)
    if frames then
        for _, f in ipairs(frames) do
            local check = f
            while check do
                if check.IsForbidden and check:IsForbidden() then break end
                local name = check:GetName()
                if name and name ~= "" and name ~= "WorldFrame" and name ~= "UIParent" and name ~= "ArcUI_FramePicker" then
                    return name, check
                end
                check = check:GetParent()
            end
        end
    end
    
    -- Fallback: scan _G for visible frames under cursor (catches mouse-disabled frames like Sensei bars)
    local cursorX, cursorY = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    cursorX, cursorY = cursorX / scale, cursorY / scale
    
    local bestName, bestFrame, bestArea = nil, nil, math.huge
    local isSecret = issecretvalue
    for gName, obj in pairs(_G) do
        if type(gName) == "string" and type(obj) == "table" then
            if obj.GetObjectType and obj.IsVisible and obj.GetRect then
                local vis = obj:IsVisible()
                if isSecret and isSecret(vis) then
                    if not bestName then
                        bestName = gName .. " |cffff4444(secret)|r"
                        bestFrame = nil
                    end
                elseif vis then
                    local l, b, w, h = obj:GetRect()
                    if l and b and w and h then
                        if isSecret and (isSecret(l) or isSecret(w)) then
                            if not bestName then
                                bestName = gName .. " |cffff4444(secret)|r"
                                bestFrame = nil
                            end
                        elseif w > 0 and h > 0 then
                            if cursorX >= l and cursorX <= (l + w) and cursorY >= b and cursorY <= (b + h) then
                                local area = w * h
                                if area < bestArea and gName ~= "WorldFrame" and gName ~= "UIParent" then
                                    bestName = gName
                                    bestFrame = obj
                                    bestArea = area
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    return bestName, bestFrame
end

function Anchors.StartPicker(callback)
    if not callback then return end
    StopPicker()
    pickerCallback = callback
    
    if not pickerFrame then
        pickerFrame = CreateFrame("Frame", "ArcUI_FramePicker", UIParent)
        pickerFrame:SetFrameStrata("TOOLTIP")
        pickerFrame:SetAllPoints(UIParent)
        pickerFrame:EnableMouse(true)
        -- Let mouse-over pass through so GetMouseFoci returns frames underneath
        if pickerFrame.SetPropagateMouseMotion then
            pickerFrame:SetPropagateMouseMotion(true)
        end
        
        pickerFrame:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                if pickerLastName and pickerCallback then
                    pickerCallback(pickerLastName)
                end
                StopPicker()
            elseif button == "RightButton" then
                StopPicker()
            end
        end)
        
        -- Floating tooltip showing frame name under cursor
        pickerTooltip = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        pickerTooltip:SetFrameStrata("TOOLTIP")
        pickerTooltip:SetFrameLevel(200)
        pickerTooltip:SetSize(320, 28)
        pickerTooltip:EnableMouse(false)
        pickerTooltip:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        pickerTooltip:SetBackdropColor(0, 0, 0, 0.92)
        pickerTooltip:SetBackdropBorderColor(0.4, 0.8, 1, 0.8)
        
        local label = pickerTooltip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", 8, 0)
        label:SetPoint("RIGHT", -8, 0)
        label:SetJustifyH("LEFT")
        pickerTooltip._label = label
        
        local hint = pickerTooltip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT", pickerTooltip, "TOPLEFT", 4, 2)
        hint:SetText("Left-click = select  |  Right-click = cancel")
        pickerTooltip._hint = hint
    end
    
    pickerFrame:Show()
    pickerTooltip:Show()
    
    -- Poll with a fast ticker instead of OnUpdate (avoids frame ownership issues)
    pickerTicker = C_Timer.NewTicker(0.2, function()
        if not pickerFrame or not pickerFrame:IsShown() then
            StopPicker()
            return
        end
        
        local name, frame = GetTopNamedFrame()
        -- Only allow selecting non-secret frames (frame ~= nil)
        pickerLastName = frame and name or nil
        
        if name then
            pickerTooltip._label:SetText("|cff88ccff" .. name .. "|r")
        else
            pickerTooltip._label:SetText("|cff888888(no named frame)|r")
        end
        
        -- Follow cursor
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        pickerTooltip:ClearAllPoints()
        pickerTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 18, y / scale + 10)
    end)
end

function Anchors.IsPickerActive()
    return pickerFrame and pickerFrame:IsShown()
end

-- ===================================================================
-- END OF ArcUI_CDMGroupsAnchors.lua
-- ===================================================================