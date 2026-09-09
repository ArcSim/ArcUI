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
-- while auras are secret. AddAuraGroup batch-creates every button ON OUR
-- STACK at build time (FrameCreationBatchSize, cap-independent) -> the
-- lifetime after a build is pool reuse (always legal). Saved aura groups PREBUILD at ADDON_LOADED (load window,
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

-- PARK CONVENTION (the Bonegrinder / Maitecky duplicate-rows lesson): a slot
-- with nothing to show gets the NEVER-MATCHING id map, NEVER the empty table.
-- {} is the permissive fallback when the engine drops toward creation-time
-- filters (vehicles / cinematics / encounter end fail OPEN) — a filterless
-- slot then displays an ARBITRARY aura, and with 10 pre-provisioned slots
-- that renders as a whole row of identical copies.
local function ParkMap() return { [0] = true } end

-- ...and the id map alone CANNOT park a slot. Identity filters are
-- POLICY-SKIPPED by the engine (CanApplyIdentityCandidateFilters,
-- Blizzard_AuraContainerUtil.lua — the anti-"Move now!" rule; never-secret
-- spells exempt) for HARMFUL auras on assistable units (self/friendly
-- target) and HELPFUL auras on hostile units. On those lanes a parked
-- target row renders the unit's first debuff in EVERY slot — the 2026-09-08
-- self-target report: ten copies of one untracked debuff. The only "off"
-- that survives the policy is a ZERO FRAME CAP: RefreshAuraGroup caps
-- before any filtering runs. SetAuraGroupMaxFrameCount is data-only
-- (number + dirty mark) so it is combat-legal, and raising it back never
-- creates frames (AddAuraGroup batch-creates 10 per slot up front on our
-- stack; acquisition pool-reuses below that).
local SLOT_CAP = { player = 1, target = 2 }  -- target: two casters can apply the same debuff

-- THE HOSTILITY GATE (the self-target residual): even an UNPARKED
-- target-row slot cannot identity-filter while the target is assistable —
-- the engine skips includeSpellIDs there by policy, so the slot would
-- render an ARBITRARY debuff on a friendly/self target instead of its
-- member's. Honest behavior (combat-first rule): the slot shows NOTHING
-- while its filter cannot be honored. This mirrors the engine's own
-- CanApplyIdentityCandidateFilters exactly — same UnitCanAssist flags,
-- same never-secret exemption — so the gate is never wider than the skip.
-- UnitCanAssist returns a plain non-secret bool for literal tokens.
local function TargetFiltersHonored()
    return not UnitCanAssist("player", "target", true, true)
end

-- never-secret members (Sated-class utility debuffs) keep identity
-- filtering everywhere, so they bypass the gate
local function AllNeverSecret(ids)
    if not (C_Secrets and C_Secrets.GetSpellAuraSecrecy
        and Enum.SecrecyLevel) then return false end
    for id in pairs(ids) do
        if C_Secrets.GetSpellAuraSecrecy(id) ~= Enum.SecrecyLevel.NeverSecret then
            return false
        end
    end
    return true
end

-- THE ONE park/unpark writer — every site that pushes a slot's candidate
-- filter goes through here so the cap and filter string can never drift
-- from the filter.
-- Park: cap to 0 FIRST (kills rendering), then the sentinel filter.
-- Unpark: install the real string + filter FIRST, then restore the cap —
-- no window where a permissive cap meets a stale filter. Target-row
-- unparks respect the hostility gate (exempt = never-secret member);
-- the PLAYER_TARGET_CHANGED handler re-caps on every swap.
-- fstr = the member's per-slot FILTER STRING (AuraIcons.FilterForLane —
-- "Only mine" appends |PLAYER: you/your pet/your vehicle). The string is
-- applied OUTSIDE the identity-filter policy gate, so it narrows even the
-- friendly-target debuff lane where includeSpellIDs is skipped, and it is
-- how another player's copy of a member debuff stays off the row.
-- SetAuraGroupFilterString is data-only (guarded-on-change; rebuilds the
-- parse-filter dedupe tables + UpdateAllAuras) — combat-legal like the
-- other two setters.
local BASE_FILTER = { player = "HELPFUL", target = "HARMFUL" }  -- makeEngine parity
local function ApplySlotFilter(c, unit, k, ids, fstr, exempt)
    local key = "arcSlot" .. k
    local parked = ids[0] ~= nil
    local canCap = c.SetAuraGroupMaxFrameCount ~= nil
    if parked and canCap then c:SetAuraGroupMaxFrameCount(key, 0) end
    if c.SetAuraGroupFilterString then
        c:SetAuraGroupFilterString(key, fstr or BASE_FILTER[unit] or "HELPFUL")
    end
    c:SetAuraGroupCandidateFilters(key, { includeSpellIDs = ids })
    if not parked and canCap then
        local cap = SLOT_CAP[unit] or 1
        if unit == "target" and not exempt and not TargetFiltersHonored() then
            cap = 0
        end
        c:SetAuraGroupMaxFrameCount(key, cap)
    end
end

-- one member's include map for one engine row (park map when the member does
-- not track that unit — the engine's only safe "off" state).
-- ROUTE BY LANES (AuraIcons.LanesFor — the ONE lane resolver, same as the
-- single-icon slots): the legacy unitMode field is a stale "buff" default on
-- current-shape defs (auraType + units), so reading it alone sent target
-- DEBUFF members onto the HELPFUL player row — invisible in the live view
-- while the panel view (holders, LanesFor-driven) worked. The group has
-- exactly two rows — player HELPFUL and target HARMFUL; lanes those rows
-- cannot represent (focus / pet / party / self-debuff) stay panel-only.
-- second return: the member's per-slot filter string (nil when parked —
-- the row's base filter stands). Resolved through AuraIcons.FilterForLane
-- so "Only mine" means the same thing here as on the member's single-icon
-- slots (the 2026-09-08 report: another player's copy of a member debuff
-- rendered in the dynamic view because every slot ran the bare row filter).
local LANE_HELPFUL = { harmful = false }
local LANE_HARMFUL = { harmful = true }
local function MemberMapFor(arcID, unit)
    local def = ns.AuraIcons and ns.AuraIcons.Get and ns.AuraIcons.Get(arcID)
    if not def then return ParkMap() end
    local wants = false
    local lanes = ns.AuraIcons.LanesFor and ns.AuraIcons.LanesFor(def)
    if lanes then
        for _, lane in ipairs(lanes) do
            if (unit == "player" and lane.unit == "player" and not lane.harmful)
                or (unit == "target" and lane.unit == "target" and lane.harmful) then
                wants = true
                break
            end
        end
    else
        -- resolver unavailable (should not happen): legacy routing
        local mode = def.unitMode or "buff"
        wants = (unit == "player" and (mode == "buff" or mode == "both"))
            or (unit == "target" and (mode == "debuff" or mode == "both"))
    end
    if not wants then return ParkMap() end
    local fstr
    if ns.AuraIcons.FilterForLane then
        fstr = ns.AuraIcons.FilterForLane(def,
            (unit == "target") and LANE_HARMFUL or LANE_HELPFUL)
    end
    local ids
    if def.spellIDs and next(def.spellIDs) then
        ids = {}
        for id in pairs(def.spellIDs) do ids[id] = true end
    elseif def.spellID then
        ids = { [def.spellID] = true }
    else
        return ParkMap()
    end
    -- third return: hostility-gate exemption (target row only) — a member
    -- whose every id is never-secret identity-filters even on friendlies
    local exempt = (unit == "target") and AllNeverSecret(ids) or false
    return ids, fstr, exempt
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
        -- 1) re-apply the hostility gate: member slots on the target row
        --    cap to 0 while the new target is assistable (identity filters
        --    are policy-skipped there), back to SLOT_CAP on a hostile one.
        --    rt.slotTargetMode mirrors what AssignSlots last pushed to the
        --    engine ("gated"/"exempt" per member slot, nil = parked).
        --    Cap writes are data-only + guarded-on-change: combat-legal,
        --    and hostile-to-hostile swaps are no-ops.
        -- 2) containers only self-refresh on UNIT_AURA of their unit — the
        --    target row goes stale on target swap without the rescan
        --    (lab-confirmed).
        local honored = TargetFiltersHonored()
        for _, rt in pairs(runtimes) do
            local c = rt.engines.target
            if c then
                local tm = rt.slotTargetMode
                if tm and c.SetAuraGroupMaxFrameCount then
                    for k = 1, MEMBER_SLOTS do
                        local mode = tm[k]
                        if mode then
                            c:SetAuraGroupMaxFrameCount("arcSlot" .. k,
                                (mode == "exempt" or honored) and SLOT_CAP.target or 0)
                        end
                    end
                end
                if c:IsShown() and c.UpdateAllAuras then c:UpdateAllAuras() end
            end
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
    -- per-BUTTON sizeRef: glow packs bake their geometry from W/H (button
    -- rects are secret, so packs take size as a parameter), and slots can
    -- carry per-icon size overrides — a shared group-size ref would build
    -- every pack at the wrong dimensions
    if not b._arcSizeRef then
        b._arcSizeRef = { GetSize = function()
            return b._arcAppliedW or (rt.cfg and rt.cfg.iconW) or 36,
                b._arcAppliedH or (rt.cfg and rt.cfg.iconH) or 36
        end }
    end
    if ns.AuraIcons and ns.AuraIcons.StyleActiveButton then
        ns.AuraIcons.StyleActiveButton(b, style, b._arcSizeRef)
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
            local dims = rt.slotDims and rt.slotDims[b._arcSlotIndex]
            local w = dims and dims.w or rt.cfg.iconW
            local h = dims and dims.h or rt.cfg.iconH
            if b._arcAppliedW ~= w or b._arcAppliedH ~= h then
                b:SetSize(w, h)
                b._arcAppliedW, b._arcAppliedH = w, h
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
    -- per-member styles + sizes, slot k = k-th member in grid order; prebuild
    -- seeds them RAW so create-time styling works even when the whole session
    -- is spent inside an instance. Glow packs read W/H through per-BUTTON
    -- refs (see StyleGroupButton) — engine button rects are secret.
    rt.slotStyles = seed and seed.slotStyles or {}
    rt.slotDims = seed and seed.slotDims or {}

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
                -- BORN PARKED (cap 0): the sentinel filter below is
                -- policy-skipped for friendly-target debuffs, so an
                -- uncapped parked slot leaks (see ApplySlotFilter). The
                -- 10-frame batch still pre-creates on our stack regardless
                -- of the cap; ApplySlotFilter restores SLOT_CAP on the
                -- slots that get members.
                maxFrameCount = 0,
                initializeFrame = function(b)
                    if WireAuraButton then WireAuraButton(b) end
                    local dims = rt.slotDims and rt.slotDims[k]
                    local w = dims and dims.w or cfg.iconW
                    local h = dims and dims.h or cfg.iconH
                    b:SetSize(w, h)
                    b._arcAppliedW, b._arcAppliedH = w, h
                    b._arcSlotIndex = k
                    b:EnableMouse(false)
                    if not b._arcGroupCollected then
                        b._arcGroupCollected = true
                        rt.buttons[#rt.buttons + 1] = b
                    end
                    StyleGroupButton(b, rt)
                end,
                candidateFilters = { includeSpellIDs = ParkMap() },  -- parked until SyncAll assigns
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

-- The group's TRUE slot size (holder parity): "Icon Size" is a SCALE
-- (iconSize/36) over the base width/height. ns.CDMGroups.GetSlotDimensions
-- is the one authority; the same math is inlined for safety. Reading the
-- raw keys as pixel sizes was the 2026-09-06 "aura group icons resize when
-- the panel closes" bug — every non-36 group flipped to the wrong size.
local function SlotDims(layout)
    if ns.CDMGroups and ns.CDMGroups.GetSlotDimensions then
        return ns.CDMGroups.GetSlotDimensions(layout)
    end
    local scale = (layout.iconSize or 36) / 36
    return math.floor((layout.iconWidth or 36) * scale + 0.5),
        math.floor((layout.iconHeight or 36) * scale + 0.5)
end

local function ApplyEngineLayout(name, group)
    local rt = runtimes[name]
    if not rt then return end
    local layout = group.layout or {}
    local al = group.auraLayout or {}
    local spacing = layout.spacingX or layout.spacing or 2
    local spacingY = layout.spacingY or layout.spacing or 2
    local perRow = layout.gridCols or 4
    local iconW, iconH = SlotDims(layout)
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
        --   "newline" -> its own line past the player row, h-aligned like
        --   the pin; default -> continue the player row edge-to-edge (the
        --   lab-proven ONE CONTIGUOUS ROW: the buff container self-resizes
        --   as auras come/go and the chain slides the debuff row with it).
        -- SINGLE-ROW groups chain even when CENTERED (Arc's call, 2026-09-06:
        -- buffs and debuffs share the row under dynamic, exactly like the
        -- panel grid) - the pin centers the BUFF container and the row
        -- extends right of it, a drift accepted over splitting the row.
        -- Centered VERTICAL/MULTI grids keep the own-line placement (a
        -- horizontal chain makes no sense on a column).
        -- Chaining uses TOP/BOTTOM edges only: an EMPTY engine container has
        -- ~zero height, side MIDPOINTS drift to the row top (lab finding).
        local newline = (al.debuffRow == "newline")
            or (hMode == "CENTER" and shape ~= "horizontal")
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
    -- per-member SIZES (holder parity — mirrors SetIconSize's member loop):
    -- the group slot size, overridden when the icon opts out of group scale:
    -- (width/height or slot) * scale
    rt.slotDims = rt.slotDims or {}
    for k = 1, MEMBER_SLOTS do
        local arcID = members[k]
        local dims = nil
        if arcID then
            local w, h = rt.cfg.iconW, rt.cfg.iconH
            local icfg = ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettings
                and ns.CDMEnhance.GetEffectiveIconSettings(arcID)
            if icfg and icfg.useGroupScale == false then
                local scale = icfg.scale or 1.0
                w = (icfg.width or w) * scale
                h = (icfg.height or h) * scale
            end
            dims = { w = w, h = h }
        end
        rt.slotDims[k] = dims
    end
    if InCombatLockdown() then
        pendingSync = true   -- filter edits queue to regen (slots convention)
        return
    end
    for unit, c in pairs(rt.engines) do
        if c.SetAuraGroupCandidateFilters then
            -- fresh mode table per push so the target-swap re-cap always
            -- mirrors what the engine actually carries (combat defers above
            -- leave BOTH the engine and this table on their old state)
            local tm = (unit == "target") and {} or nil
            for k = 1, MEMBER_SLOTS do
                local arcID = members[k]
                local ids, fstr, exempt
                if arcID then ids, fstr, exempt = MemberMapFor(arcID, unit) end
                ids = ids or ParkMap()
                ApplySlotFilter(c, unit, k, ids, fstr, exempt)
                if tm and ids[0] == nil then
                    tm[k] = exempt and "exempt" or "gated"
                end
            end
            if tm then rt.slotTargetMode = tm end
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
    -- park — hide + zero caps + sentinel filters. The frames are reused if
    -- the name returns.
    for name, rt in pairs(runtimes) do
        if not live[name] then
            rt.slotTargetMode = nil   -- no member slots left to re-cap
            for unit, c in pairs(rt.engines) do
                if not InCombatLockdown() and c.SetAuraGroupCandidateFilters then
                    for k = 1, MEMBER_SLOTS do
                        ApplySlotFilter(c, unit, k, ParkMap())
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
                    s.iconW, s.iconH = SlotDims(ld)
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
                        local slotStyles, slotDims = {}, {}
                        for k, r in ipairs(rows) do
                            if k > MEMBER_SLOTS then break end
                            local raw = type(iset) == "table" and iset[r.id]
                            if type(raw) == "table" and next(raw) ~= nil then
                                slotStyles[k] = CopyTable(raw)
                                -- per-icon size opt-out, same math as AssignSlots
                                if raw.useGroupScale == false then
                                    local sc = raw.scale or 1.0
                                    slotDims[k] = {
                                        w = (raw.width or s.iconW) * sc,
                                        h = (raw.height or s.iconH) * sc,
                                    }
                                end
                            end
                        end
                        if next(slotStyles) ~= nil then s.slotStyles = slotStyles end
                        if next(slotDims) ~= nil then s.slotDims = slotDims end
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
                        local w, h = SlotDims(ld)
                        seeds[gname] = { iconW = w, iconH = h }
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
-- Since the per-member-slot rework (v2) every container carries TEN engine
-- groups with per-group candidate filters, so the verified two-part repair
-- applies in full: (1) cycle the container (SetEnabled false->true — the
-- vehicle/cinematic/encounter-end filter break fails OPEN, which is how a
-- whole row of identical copies appears: 10 filterless slots each showing
-- the same arbitrary aura, the Maitecky screenshot), then (2) re-push every
-- slot's believed-correct filter. SetAuraGroupCandidateFilters is data-only
-- and legal in ANY context (combat included — the entomb case is mid-pull),
-- so the re-push must NOT ride AssignSlots' combat-deferring path. Since
-- 2026-09-08 the re-push rides ApplySlotFilter, which also re-asserts the
-- frame caps (SetAuraGroupMaxFrameCount is equally data-only/combat-legal)
-- — the caps, not the filters, are what parks a slot against the engine's
-- identity-filter policy skip on friendly-target debuffs.
function ns.AuraIconGroups.RepairContainers()
    local Sh = ns.CDMShared
    if not (Sh and Sh.RepairAuraContainer) then return end
    for name, rt in pairs(runtimes) do
        if rt and rt.engines then
            local members = AG.MembersOf(name)
            for unit, c in pairs(rt.engines) do
                Sh.RepairAuraContainer(c)
                if c.SetAuraGroupCandidateFilters then
                    for k = 1, MEMBER_SLOTS do
                        local arcID = members[k]
                        local ids, fstr, exempt
                        if arcID then ids, fstr, exempt = MemberMapFor(arcID, unit) end
                        ApplySlotFilter(c, unit, k, ids or ParkMap(), fstr, exempt)
                    end
                end
            end
        end
    end
end

if ns.CDMShared and ns.CDMShared.RegisterAuraContainerRepair then
    ns.CDMShared.RegisterAuraContainerRepair(ns.AuraIconGroups.RepairContainers)
end
