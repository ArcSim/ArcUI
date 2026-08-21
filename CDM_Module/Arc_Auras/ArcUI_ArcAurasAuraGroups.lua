-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_ArcAurasAuraGroups.lua
-- SPELL-ID AURA GROUPS (12.1): the engine-display side of CDMGroups groups
-- created with groupType = "aura". The GROUP is a completely normal ArcUI
-- group — container, border, title, drag toggle, Edit Mode wrapper,
-- visibility conditions, rename/delete, per-spec profiles, and the standard
-- icon drag/drop all come from ns.CDMGroups. This module only attaches the
-- ENGINE rows (AuraContainer + AddAuraGroup flow layout) that render the
-- members while the group is "live".
--
-- THE FLIP (lab-proven UX, ArcUI_AuraLab_Slots UpdateMemberVisibility):
--   * options panel open / drag mode ON  -> the group behaves EXACTLY like a
--     normal group: member holders materialize in their grid slots (ghosts,
--     live auras, drag in/out between groups), engine rows are hidden.
--   * panel closed & drag off            -> member holders tear down (the
--     spec-hide path: savedPositions preserved), engine rows show. The
--     engine creates a button whenever a member's aura goes active and its
--     flow layout compacts the row — true dynamic placement under secrecy.
--
-- MEMBERSHIP is the standard record: ns.CDMGroups.savedPositions[arcID] =
-- { type = "group", target = <groupName> } — written by the normal drop
-- machinery, preserved by TeardownIcon, rewritten by RenameGroup. The
-- engine union filter is derived from it.
--
-- PER-MEMBER SLOTS (v2 — kills the old shared-look limit): each member gets
-- its OWN engine group ("arcSlot<k>") inside the shared containers. Multiple
-- groups in one container share ONE flow layout (lab/p3lim-confirmed:
-- RebuildLayoutGroups), so the row still compacts as one — but every button
-- now has a KNOWN owner (its slot index -> member arcID), so TRUE per-icon
-- styling works in the live view, and ordering = the grid order (slot k =
-- k-th member, sorted by grid position).
--
-- HARD LIMITS (engine physics — disclosed in the Groups tab):
--   * no ghost/missing visuals in live mode (absent aura = no icon)
--   * max MEMBER_SLOTS live members per group (slots pre-provisioned at
--     build; RC 69189 forbids mid-secrecy group creation)
--
-- RC 69189: engine container/group creation is BLOCKED from addon stacks
-- while auras are secret. maxFrameCount pre-creates every button ON OUR
-- STACK at AddAuraGroup time -> the lifetime after a build is pool reuse
-- (always legal). Saved aura groups PREBUILD at ADDON_LOADED (load window,
-- covers /reload inside instances) from a raw SavedVariables scan; anything
-- else defers until auras are accessible.
--
-- Engine containers are parented to UIParent and ANCHORED to the group
-- container (lab-proven; anchoring TO our frames is legal, and a
-- group-container parent is impossible at prebuild time — the CDMGroups
-- containers don't exist until login). Visibility/alpha/strata are MIRRORED
-- from the container (hooks + sync).
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...
ns.AuraIconGroups = ns.AuraIconGroups or {}
local AG = ns.AuraIconGroups

local IS_121 = (select(4, GetBuildInfo()) or 0) >= 120100

local MEMBER_SLOTS = 10  -- engine groups per container (RC: pre-provisioned)

local runtimes = {}      -- groupName -> { engines={player=,target=}, cfg={iconW,iconH}, anchoredTo }
local loadWindowOver = false
local pendingBuild = false
local pendingSync = false
local targetSwapArmed = false

local function AurasSecretNow()
    return (C_Secrets and C_Secrets.ShouldAurasBeSecret
        and C_Secrets.ShouldAurasBeSecret()) and true or false
end

-- Engine mode = the group is "live": holders parked, engine rows render.
-- Mirrors UpdateGroupVisibility's forceShow inputs.
local function EngineModeActive()
    if ns.optionsPanelOpen then return false end
    if ns.CDMGroups and ns.CDMGroups.dragModeEnabled then return false end
    return true
end
AG.EngineModeActive = EngineModeActive

-- ═══════════════════════════════════════════════════════════════════════════
-- MEMBERSHIP (from the standard savedPositions records)
-- ═══════════════════════════════════════════════════════════════════════════

local function IsAuraArcID(id)
    return type(id) == "string" and id:match("^arc_aura_") and true or false
end

local function GroupOf(arcID)
    local sp = ns.CDMGroups and ns.CDMGroups.savedPositions
    local rec = sp and sp[arcID]
    if rec and rec.type == "group" and rec.target then
        local g = ns.CDMGroups.groups and ns.CDMGroups.groups[rec.target]
        if g and g.isAuraGroup then return rec.target, g end
    end
    return nil, nil
end
AG.GetGroupOf = GroupOf

function AG.MembersOf(groupName)
    -- DETERMINISTIC ORDER (audit finding: pairs() hash order made "first
    -- member" a coin flip, which silently picked the style donor): sort by
    -- the saved grid slot (sortIndex when present, else row-major row/col),
    -- arcID as the stable tiebreak.
    local rows = {}
    local sp = ns.CDMGroups and ns.CDMGroups.savedPositions
    if sp then
        for arcID, rec in pairs(sp) do
            if IsAuraArcID(arcID) and rec.type == "group" and rec.target == groupName then
                rows[#rows + 1] = {
                    id = arcID,
                    key = rec.sortIndex or ((rec.row or 0) * 1000 + (rec.col or 0)),
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return a.id < b.id
    end)
    local out = {}
    for i, r in ipairs(rows) do out[i] = r.id end
    return out
end

-- one member's include map for one engine row ({} when the member does not
-- track that unit — an empty filter is the engine's "off" state)
local function MemberMapFor(arcID, unit)
    local def = ns.AuraIcons and ns.AuraIcons.Get and ns.AuraIcons.Get(arcID)
    if not def then return {} end
    local mode = def.unitMode or "buff"
    local wants = (unit == "player" and (mode == "buff" or mode == "both"))
        or (unit == "target" and (mode == "debuff" or mode == "both"))
    if not wants then return {} end
    if def.spellIDs and next(def.spellIDs) then
        local ids = {}
        for id in pairs(def.spellIDs) do ids[id] = true end
        return ids
    end
    if def.spellID then return { [def.spellID] = true } end
    return {}
end

-- Consumed by AuraIcons.RefreshVisibility: a member has no standalone
-- presentation ONLY while its group's engine rows actually render it.
-- The group's Dynamic Layout toggle (autoReflow) IS the live-view switch:
-- off = the group stays a normal static grid full-time.
function AG.IsEngineOwned(arcID)
    if not IS_121 then return false end
    if not EngineModeActive() then return false end
    local gname, g = GroupOf(arcID)
    if not (gname and g and g.autoReflow) then return false end
    return runtimes[gname] ~= nil
end


-- ═══════════════════════════════════════════════════════════════════════════
-- ENGINE RUNTIME BUILD (RC-gated; prebuild covers saved groups at load)
-- ═══════════════════════════════════════════════════════════════════════════

local function ArmTargetSwapRefresh()
    if targetSwapArmed then return end
    targetSwapArmed = true
    local w = CreateFrame("Frame")
    w:RegisterEvent("PLAYER_TARGET_CHANGED")
    w:SetScript("OnEvent", function()
        -- containers only self-refresh on UNIT_AURA of their unit — the
        -- target row goes stale on target swap without this (lab-confirmed)
        for _, rt in pairs(runtimes) do
            local c = rt.engines.target
            if c and c:IsShown() and c.UpdateAllAuras then c:UpdateAllAuras() end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ENGINE BUTTON STYLING — TRUE PER-ICON: every button belongs to a member
-- slot (b._arcSlotIndex), and rt.slotStyles[k] holds THAT member's effective
-- settings. Full parity with the slot presentation via the ONE shared
-- styling path (StyleActiveButton). Runs at initializeFrame (create-time
-- legal, incl. the load window) and again from SyncAll for live edits,
-- gated on button accessibility.
-- ═══════════════════════════════════════════════════════════════════════════

local function StyleGroupButton(b, rt)
    local style = rt and rt.slotStyles and rt.slotStyles[b._arcSlotIndex or 0]
    if not style then return end
    if ns.AuraIcons and ns.AuraIcons.StyleActiveButton then
        ns.AuraIcons.StyleActiveButton(b, style, rt.sizeRef)
    end
end

local function StyleRuntimeButtons(name)
    local rt = runtimes[name]
    if not rt then return end
    local resized = false
    for _, b in ipairs(rt.buttons or {}) do
        local ok
        if b.CanBeAccessedInContext then
            ok = b:CanBeAccessedInContext()
        else
            ok = not (b.IsForbidden and b:IsForbidden())
        end
        if ok then
            -- initializeFrame only runs at CREATION (pool reuse never
            -- re-inits — audit finding), so the configured icon size and any
            -- later size edits must land here. NEVER GetSize() the button
            -- (rect reads are the secret trap) — track what WE last applied.
            if b._arcAppliedW ~= rt.cfg.iconW or b._arcAppliedH ~= rt.cfg.iconH then
                b:SetSize(rt.cfg.iconW, rt.cfg.iconH)
                b._arcAppliedW, b._arcAppliedH = rt.cfg.iconW, rt.cfg.iconH
                resized = true
            end
            StyleGroupButton(b, rt)
        else
            pendingSync = true   -- retry at regen/PEW
        end
    end
    if resized and not InCombatLockdown() then
        -- nudge the engine flow layout so it re-packs at the new sizes now
        for _, c in pairs(rt.engines) do
            if c.UpdateAllAuras then c:UpdateAllAuras() end
        end
    end
end

-- seed (prebuild only): { iconW, iconH, slotStyles = { [k] = sparse per-icon
-- settings } } resolved raw from SavedVariables so the pre-created buttons
-- are styled INSIDE the load window (the only legal styling context for a
-- reload-into-instance session)
local function BuildRuntime(name, seed)
    if runtimes[name] then return runtimes[name] end
    if not IS_121 then return nil end
    -- ADOPT an orphaned runtime (rename / spec swap): engine frames are
    -- group-agnostic — re-keying avoids a fresh build (which the RC gate can
    -- refuse mid-session). NEVER during prebuild (the groups table is empty
    -- then, so EVERY runtime looks orphaned and N saved groups would collapse
    -- into one — audit finding), and never while the group merely hasn't been
    -- recreated YET (profile still lists it as an aura group).
    if not seed and ns.CDMGroups.groups and next(ns.CDMGroups.groups) ~= nil then
        for oldName, rt in pairs(runtimes) do
            local g = ns.CDMGroups.groups[oldName]
            if not (g and g.isAuraGroup) then
                local saved = ns.CDMGroups.GetGroupLayoutFromProfile
                    and ns.CDMGroups.GetGroupLayoutFromProfile(oldName)
                if not (saved and saved.groupType == "aura") then
                    runtimes[oldName] = nil
                    runtimes[name] = rt
                    return rt
                end
            end
        end
    end
    if loadWindowOver and AurasSecretNow() then
        pendingBuild = true
        return nil
    end

    if C_AddOns and C_AddOns.IsAddOnLoaded and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
        C_AddOns.LoadAddOn("Blizzard_AuraContainer")
    end

    -- button config read by initializeFrame at CREATION only — pool reuse
    -- never re-inits (audit-corrected). Post-create size/style changes land
    -- via StyleRuntimeButtons.
    local cfg = { iconW = seed and seed.iconW or 36, iconH = seed and seed.iconH or 36 }
    local rt = { engines = {}, cfg = cfg, buttons = {} }
    -- glow packs read W/H through here (engine button sizes are secret)
    rt.sizeRef = { GetSize = function() return cfg.iconW, cfg.iconH end }
    -- per-member styles, slot k = k-th member in grid order; prebuild seeds
    -- them RAW so create-time styling works even when the whole session is
    -- spent inside an instance
    rt.slotStyles = seed and seed.slotStyles or {}

    local WireAuraButton = ns.AuraIcons and ns.AuraIcons.WireAuraButton

    local function makeEngine(unit, filter)
        local c = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
        if not c or type(c.AddAuraGroup) ~= "function" then
            if c then c:Hide() end
            return nil
        end
        c:SetSize(1, 1)
        c:SetUnit(unit)
        c:SetEnabled(true)
        c:EnableMouse(false)
        c:Hide()   -- shown only in engine mode, mirrored to the group container
        -- ONE ENGINE GROUP PER MEMBER SLOT: all slots share this container's
        -- single flow layout (groups flow together — RebuildLayoutGroups),
        -- so the row compacts as one, but each slot's buttons have a KNOWN
        -- member -> true per-icon styling. Add order = slot order = the
        -- member's grid order. All slots pre-provisioned here (RC 69189:
        -- group creation is illegal mid-secrecy; filters + styles are
        -- live-settable per slot, so membership changes never create).
        for k = 1, MEMBER_SLOTS do
            c:AddAuraGroup("arcSlot" .. k, filter, {
                -- player buffs match once; target debuffs can match twice
                -- (two casters) — small caps keep the pre-created frame
                -- count sane (all frames build on our stack right here)
                maxFrameCount = (unit == "target") and 2 or 1,
                initializeFrame = function(b)
                    if WireAuraButton then WireAuraButton(b) end
                    b:SetSize(cfg.iconW, cfg.iconH)
                    b._arcAppliedW, b._arcAppliedH = cfg.iconW, cfg.iconH
                    b._arcSlotIndex = k
                    b:EnableMouse(false)
                    if not b._arcGroupCollected then
                        b._arcGroupCollected = true
                        rt.buttons[#rt.buttons + 1] = b
                    end
                    StyleGroupButton(b, rt)
                end,
                candidateFilters = { includeSpellIDs = {} },  -- SyncAll assigns
                layout = {
                    elementSpacingX = 2, elementSpacingY = 2, -- pre-PTR7 keys
                    elementSpacing = 2, lineSpacing = 2,      -- PTR7 keys
                    groupSpacing = 2, groupLineSpacing = 2,   -- between slots
                },
            })
        end
        rt.engines[unit] = c
        return c
    end

    makeEngine("player", "HELPFUL")
    makeEngine("target", "HARMFUL")
    ArmTargetSwapRefresh()
    runtimes[name] = rt
    return rt
end

-- ═══════════════════════════════════════════════════════════════════════════
-- LAYOUT + ANCHORING (from the group's OWN settings — Grid Settings applies)
-- ═══════════════════════════════════════════════════════════════════════════

local function ApplyEngineLayout(name, group)
    local rt = runtimes[name]
    if not rt then return end
    local layout = group.layout or {}
    local al = group.auraLayout or {}
    local spacing = layout.spacingX or layout.spacing or 2
    local spacingY = layout.spacingY or layout.spacing or 2
    local perRow = layout.gridCols or 4
    local iconW = layout.iconWidth or layout.iconSize or 36
    local iconH = layout.iconHeight or layout.iconSize or 36
    -- PIN RESOLUTION from the group's Alignment (the SAME shape-aware control
    -- normal groups use) + Row Growth. Alignment values pin their own axis:
    --   left/right/center (horizontal shapes)  -> horizontal pin
    --   top/bottom/center (vertical shapes)    -> vertical pin
    --   center_h/center_v (multi grids)        -> that axis centered
    -- Row Growth (DOWN/UP/CENTER) fills whichever axis Alignment didn't set;
    -- back-compat horizontal default derives from Col Growth.
    local align = layout.alignment
    local vGrow = layout.verticalGrowth or "DOWN"       -- Row Growth: DOWN|UP|CENTER
    local shape = "horizontal"
    if ns.CDMGroups.DetectGridShape then
        shape = ns.CDMGroups.DetectGridShape(layout.gridRows or 1, layout.gridCols or 4)
    end

    -- hMode/vMode: LEFT|RIGHT|CENTER and TOP|BOTTOM|CENTER (= pinned side)
    local hMode
    if align == "left" or align == "right" then
        hMode = align:upper()
    elseif align == "center_h" or (align == "center" and shape ~= "vertical") then
        hMode = "CENTER"
    end
    if not hMode then
        local hg = layout.horizontalGrowth
        hMode = (hg == "LEFT") and "RIGHT" or (hg == "CENTER") and "CENTER" or "LEFT"
    end
    local vMode = (vGrow == "UP") and "BOTTOM" or (vGrow == "CENTER") and "CENTER" or "TOP"
    if align == "top" then vMode = "TOP"
    elseif align == "bottom" then vMode = "BOTTOM"
    elseif align == "center_v" or (align == "center" and shape == "vertical") then
        vMode = "CENTER"
    end
    rt.cfg.iconW, rt.cfg.iconH = iconW, iconH

    -- FLOW inside the box is always CORNER-anchored — pinning the flow to an
    -- edge midpoint shifts each ELEMENT half-out (the lab's centered-mode
    -- bug). Centered growth comes from the PIN below, not the flow.
    local flowCorner = ((vMode == "BOTTOM") and "BOTTOM" or "TOP")
        .. ((hMode == "RIGHT") and "RIGHT" or "LEFT")

    local FD = AnchorUtil and AnchorUtil.FlowDirection
    for _, c in pairs(rt.engines) do
        -- spacing per SLOT group; groupSpacing = the gap BETWEEN slots, set
        -- equal to element spacing so members space like one row.
        -- (No engine sort: slot order IS the member grid order.)
        if c.SetAuraGroupLayout then
            for k = 1, MEMBER_SLOTS do
                c:SetAuraGroupLayout("arcSlot" .. k, {
                    elementSpacingX = spacing, elementSpacingY = spacingY,
                    elementSpacing = spacing, lineSpacing = spacingY,
                    groupSpacing = spacing, groupLineSpacing = spacingY,
                })
            end
        end
        local lineSize = perRow * (iconW + spacing)
        if c.SetFlowLayoutMaximumLineSize then
            c:SetFlowLayoutMaximumLineSize(lineSize)
        elseif c.SetAuraLayoutRowWidth then
            c:SetAuraLayoutRowWidth(lineSize)
        end
        if c.SetFlowLayoutPadding then
            c:SetFlowLayoutPadding(0, 0, 0, 0)
        elseif c.SetAuraLayoutPadding then
            c:SetAuraLayoutPadding(0, 0, 0, 0)
        end
        if FD then
            local dirH = (hMode == "RIGHT") and FD.Left or FD.Right
            local dirV = (vMode == "BOTTOM") and FD.Up or FD.Down
            if c.SetFlowLayoutGrowthDirection then
                c:SetFlowLayoutGrowthDirection(dirH, dirV)
            elseif c.SetAuraLayoutGrowthDirection then
                c:SetAuraLayoutGrowthDirection(dirH, dirV)
            end
        end
        if c.SetAuraLayoutAnchorPoint then
            c:SetAuraLayoutAnchorPoint(flowCorner)
        end
    end

    -- THE PIN: the fixed point the auto-sizing box grows away from, on the
    -- container's padded rect. CENTER on an axis pins that axis's midpoint
    -- so the box expands symmetrically (lab centered-growth pattern).
    local container = group.container
    if not container then return end
    local inset = 6 + (group.containerPadding or 0)
    local vPart = (vMode == "TOP") and "TOP" or (vMode == "BOTTOM") and "BOTTOM" or ""
    local hPart = (hMode == "LEFT") and "LEFT" or (hMode == "RIGHT") and "RIGHT" or ""
    local pin = vPart .. hPart
    if pin == "" then pin = "CENTER" end
    local xOff = (hMode == "LEFT") and inset or (hMode == "RIGHT") and -inset or 0
    local yOff = (vMode == "TOP") and -inset or (vMode == "BOTTOM") and inset or 0

    local A, B = rt.engines.player, rt.engines.target
    local first = A or B
    if first then
        first:ClearAllPoints()
        first:SetPoint(pin, container, pin, xOff, yOff)
    end
    if A and B then
        B:ClearAllPoints()
        -- TARGET (debuff) row placement:
        --   "newline" (or centered growth, where an edge-chain would sit
        --   off-center) -> its own line past the player row, h-aligned
        --   like the pin; default -> continue the player row edge-to-edge.
        -- Chaining uses TOP/BOTTOM edges only: an EMPTY engine container has
        -- ~zero height, side MIDPOINTS drift to the row top (lab finding).
        local newline = (al.debuffRow == "newline") or hMode == "CENTER"
        if newline then
            if vMode == "BOTTOM" then
                B:SetPoint("BOTTOM" .. hPart, A, "TOP" .. hPart, 0, spacingY)
            else
                B:SetPoint("TOP" .. hPart, A, "BOTTOM" .. hPart, 0, -spacingY)
            end
        else
            local chainV = (vMode == "BOTTOM") and "BOTTOM" or "TOP"
            local hSelf = (hMode == "RIGHT") and "RIGHT" or "LEFT"
            local hFar = (hMode == "RIGHT") and "LEFT" or "RIGHT"
            B:SetPoint(chainV .. hSelf, A, chainV .. hFar,
                (hMode == "RIGHT") and -spacing or spacing, 0)
        end
    end
end

-- mirror the container's shown/alpha onto the engines (they are NOT
-- children — visibility conditions and edit hides must carry over)
local function UpdateEngineShown(name, group)
    local rt = runtimes[name]
    if not rt then return end
    -- pooled containers get reused by NORMAL groups on spec swaps — a stale
    -- mirror hook must never re-show engines for a non-aura group. Dynamic
    -- Layout off = static grid full-time, engines stay hidden.
    local container = group and group.isAuraGroup and group.autoReflow
        and group.container or nil
    local on = EngineModeActive() and container ~= nil and container:IsShown()
    local alpha = container and container:GetAlpha() or 1
    for _, c in pairs(rt.engines) do
        c:SetShown(on)
        c:SetAlpha(alpha)
        if container then
            c:SetFrameStrata(container:GetFrameStrata())
            c:SetFrameLevel(container:GetFrameLevel() + 2)
        end
    end
end

local function HookContainerMirror(name, group)
    local container = group.container
    if not container or container._arcAuraGroupMirror == name then return end
    container._arcAuraGroupMirror = name   -- stamp: pooled containers re-target
    if not container._arcAuraGroupHooked then
        container._arcAuraGroupHooked = true
        container:HookScript("OnShow", function(self)
            local n = self._arcAuraGroupMirror
            if n then UpdateEngineShown(n, ns.CDMGroups.groups[n]) end
        end)
        container:HookScript("OnHide", function(self)
            local n = self._arcAuraGroupMirror
            if n then UpdateEngineShown(n, ns.CDMGroups.groups[n]) end
        end)
        hooksecurefunc(container, "SetAlpha", function(self)
            local n = self._arcAuraGroupMirror
            if n then
                local rt = runtimes[n]
                if rt then
                    local a = self:GetAlpha()
                    for _, c in pairs(rt.engines) do c:SetAlpha(a) end
                end
            end
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SYNC (the single reconciler — membership, layout, anchoring, the flip)
-- ═══════════════════════════════════════════════════════════════════════════

-- assign members to engine slots: slot k carries the k-th (grid-order)
-- member's filter on each row it wants, and that member's effective
-- settings as the slot's style. Both are live-settable — membership and
-- styling changes never create engine objects.
local function AssignSlots(name)
    local rt = runtimes[name]
    if not rt then return end
    local members = AG.MembersOf(name)
    -- per-member styles (post-login settings cascade; prebuild already
    -- seeded the sparse entries for the in-instance case)
    if ns.ArcAuras and ns.ArcAuras.GetCachedSettings then
        for k = 1, MEMBER_SLOTS do
            local arcID = members[k]
            rt.slotStyles[k] = arcID and ns.ArcAuras.GetCachedSettings(arcID) or nil
        end
    end
    if InCombatLockdown() then
        pendingSync = true   -- filter edits queue to regen (slots convention)
        return
    end
    for unit, c in pairs(rt.engines) do
        if c.SetAuraGroupCandidateFilters then
            for k = 1, MEMBER_SLOTS do
                local arcID = members[k]
                c:SetAuraGroupCandidateFilters("arcSlot" .. k,
                    { includeSpellIDs = arcID and MemberMapFor(arcID, unit) or {} })
            end
        end
    end
end

function AG.SyncAll()
    if not IS_121 then return end
    local groups = ns.CDMGroups and ns.CDMGroups.groups or {}
    local live = {}
    for name, group in pairs(groups) do
        if group.isAuraGroup then
            live[name] = true
            local rt = runtimes[name] or BuildRuntime(name)
            if rt then
                HookContainerMirror(name, group)
                ApplyEngineLayout(name, group)
                AssignSlots(name)
                StyleRuntimeButtons(name)
                UpdateEngineShown(name, group)
            end
        end
    end
    -- runtimes whose group is gone (deleted / renamed / spec without it):
    -- park — hide + empty filters. The frames are reused if the name returns.
    for name, rt in pairs(runtimes) do
        if not live[name] then
            for _, c in pairs(rt.engines) do
                if not InCombatLockdown() and c.SetAuraGroupCandidateFilters then
                    for k = 1, MEMBER_SLOTS do
                        c:SetAuraGroupCandidateFilters("arcSlot" .. k, { includeSpellIDs = {} })
                    end
                end
                c:Hide()
            end
        end
    end
    -- the flip: park/revive member holders (standalone presentation)
    if ns.AuraIcons and ns.AuraIcons.RefreshVisibility then
        ns.AuraIcons.RefreshVisibility()
    end
end

local syncQueued = false
local function QueueSync()
    if syncQueued then return end
    syncQueued = true
    C_Timer.After(0.2, function()
        syncQueued = false
        AG.SyncAll()
    end)
end
AG.QueueSync = QueueSync

-- ═══════════════════════════════════════════════════════════════════════════
-- PREBUILD (ADDON_LOADED raw scan — RC load window; covers /reload inside
-- instances where creation is blocked for the rest of the session)
-- ═══════════════════════════════════════════════════════════════════════════

local function PrebuildSavedGroups()
    if not IS_121 then return end
    local pn = UnitName and UnitName("player")
    if not pn or pn == "Unknown" then return end   -- spec-key fabrication lesson
    -- RAW read only — no helpers, no spec queries, nothing fabricates spec
    -- keys this early (ns.db doesn't even exist yet). Besides the group
    -- NAMES, also resolve each group's SEED: icon size + the sorted-first
    -- CUSTOMIZED member's sparse per-icon settings — the create-time style.
    -- Without it, a reload inside an instance leaves every pre-created
    -- button bare for the whole session (buttons are forbidden 24/7 there;
    -- the load window is the ONLY legal styling context — audit finding).
    local charKey = pn .. " - " .. (GetRealmName() or "")
    local charDB = ArcUIDB and ArcUIDB.char and ArcUIDB.char[charKey]
    local cg = charDB and charDB.cdmGroups
    local seeds = {}   -- gname -> { iconW, iconH, style, preferred }

    local function considerProfile(prof, preferred)
        if type(prof) ~= "table" or type(prof.groupLayouts) ~= "table" then return end
        for gname, ld in pairs(prof.groupLayouts) do
            if type(ld) == "table" and ld.groupType == "aura" then
                local s = seeds[gname]
                if not s or (preferred and not s.preferred) then
                    s = { preferred = preferred or nil }
                    s.iconW = ld.iconWidth or ld.iconSize or 36
                    s.iconH = ld.iconHeight or ld.iconSize or 36
                    -- ALL members in grid order -> per-SLOT styles (sparse
                    -- entries share the merged-settings key shape;
                    -- StyleActiveButton defaults everything absent; the full
                    -- cascade replaces these at the first accessible SyncAll)
                    local sp = prof.savedPositions
                    local iset = prof.iconSettings
                    if type(sp) == "table" then
                        local rows = {}
                        for arcID, rec in pairs(sp) do
                            if type(arcID) == "string" and arcID:match("^arc_aura_")
                               and type(rec) == "table" and rec.type == "group"
                               and rec.target == gname then
                                rows[#rows + 1] = {
                                    id = arcID,
                                    key = rec.sortIndex
                                        or ((rec.row or 0) * 1000 + (rec.col or 0)),
                                }
                            end
                        end
                        table.sort(rows, function(a, b)
                            if a.key ~= b.key then return a.key < b.key end
                            return a.id < b.id
                        end)
                        local slotStyles = {}
                        for k, r in ipairs(rows) do
                            if k > MEMBER_SLOTS then break end
                            local raw = type(iset) == "table" and iset[r.id]
                            if type(raw) == "table" and next(raw) ~= nil then
                                slotStyles[k] = CopyTable(raw)
                            end
                        end
                        if next(slotStyles) ~= nil then s.slotStyles = slotStyles end
                    end
                    seeds[gname] = s
                end
            end
        end
    end

    if cg and cg.specData then
        local lastSpec = cg.lastActiveSpec
        for specKey, sd in pairs(cg.specData) do
            if type(sd) == "table" and sd.layoutProfiles then
                local activeName = sd.activeProfile or "Default"
                for profName, prof in pairs(sd.layoutProfiles) do
                    considerProfile(prof, specKey == lastSpec and profName == activeName)
                end
            end
        end
    end
    -- global (shared) group layouts: names + size only (membership and
    -- per-icon settings are per-profile and were handled above)
    local gl = ArcUIDB and ArcUIDB.global and ArcUIDB.global.groupLayouts
    if gl then
        for _, layoutSet in pairs(gl) do
            if type(layoutSet) == "table" then
                for gname, ld in pairs(layoutSet) do
                    if type(ld) == "table" and ld.groupType == "aura" and not seeds[gname] then
                        seeds[gname] = {
                            iconW = ld.iconWidth or ld.iconSize or 36,
                            iconH = ld.iconHeight or ld.iconSize or 36,
                        }
                    end
                end
            end
        end
    end
    for gname, seed in pairs(seeds) do
        BuildRuntime(gname, seed)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WIRING
-- ═══════════════════════════════════════════════════════════════════════════

if IS_121 then
    -- attach when an aura group materializes (login, spec swap, "+ Aura Group")
    if ns.CDMGroups and ns.CDMGroups.CreateGroup then
        hooksecurefunc(ns.CDMGroups, "CreateGroup", function(name)
            local g = ns.CDMGroups.groups and ns.CDMGroups.groups[name]
            if g and g.isAuraGroup then QueueSync() end
        end)
    end
    -- drag mode is half of the flip condition
    if ns.CDMGroups and ns.CDMGroups.SetDragMode then
        hooksecurefunc(ns.CDMGroups, "SetDragMode", QueueSync)
    end
    -- the options panel is the other half
    if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
        ns.CDMShared.RegisterPanelCallback("ArcAuraIconGroups", {
            onOpen = QueueSync,
            onClose = QueueSync,
        })
    end

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("ADDON_LOADED")
    ev:RegisterEvent("PLAYER_LOGIN")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:SetScript("OnEvent", function(_, event, arg1)
        if event == "ADDON_LOADED" then
            if arg1 == ADDON then
                ev:UnregisterEvent("ADDON_LOADED")
                PrebuildSavedGroups()
            end
            return
        end
        if event == "PLAYER_LOGIN" then
            loadWindowOver = true
            return
        end
        if event == "PLAYER_ENTERING_WORLD" then
            -- staggered settle passes: CDMGroups restore + arc position
            -- restore land within the first seconds after PEW
            C_Timer.After(2, AG.SyncAll)
            C_Timer.After(6, AG.SyncAll)
        end
        -- PEW + regen: drain deferred builds / combat-queued filter pushes
        if (pendingBuild or pendingSync) and not AurasSecretNow() then
            pendingBuild = false
            pendingSync = false
            AG.SyncAll()
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF ArcUI_ArcAurasAuraGroups.lua
-- ═══════════════════════════════════════════════════════════════════════════

-- CONTAINER REPAIR (12.1 engine bug -- full write-up in ns.CDMShared).
-- Aura GROUPS use AddAuraGroup rather than AddAuraSlot, so there are no
-- per-slot candidate filters to re-push here: the group carries its own filter
-- from creation. Cycling the container is therefore the ONLY repair available,
-- and it is the one that matters, since the reported symptom is the container
-- being bricked outright by a vehicle or cinematic.
function ns.AuraIconGroups.RepairContainers()
    local Sh = ns.CDMShared
    if not (Sh and Sh.RepairAuraContainer) then return end
    for _, rt in pairs(runtimes) do
        if rt and rt.engines then
            for _, c in pairs(rt.engines) do
                Sh.RepairAuraContainer(c)
            end
        end
    end
end

if ns.CDMShared and ns.CDMShared.RegisterAuraContainerRepair then
    ns.CDMShared.RegisterAuraContainerRepair(ns.AuraIconGroups.RepairContainers)
end
