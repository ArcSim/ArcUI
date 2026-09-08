-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Duration Override  (EXPERIMENTAL — COOLDOWN ICONS ONLY)
--
-- Attaches a mini custom-timer onto a CDM COOLDOWN icon: on a trigger, the
-- icon's Cooldown shows OUR duration (a totem's remaining time, or a fixed
-- manual duration) AS AN AURA-ACTIVE OVERRIDE — the inverse of
-- ignoreAuraOverride. While active the icon is treated like an aura is up
-- (its OWN appearance config: no-desaturate, swipe/edge visibility, glow), and
-- when it ends the real spell cooldown shows through again.
--
-- Start trigger : UNIT_SPELLCAST_SUCCEEDED on "player" (this icon's spell).
--   - manual mode: push a fixed-duration durObj immediately.
--   - totem  mode: arm a window; the next PLAYER_TOTEM_UPDATE whose slot becomes
--     OCCUPIED is ESTIMATED to be this spell's totem → push GetTotemDuration(slot).
-- End trigger   : natural expiry (duration/totem runs out) OR a configured END
--   spell's cast "consumes" it early.
--
-- SECRET-SAFE: spellID, slot, and "slot occupied?" (probe Cooldown:IsShown) are
-- all NON-secret. The durObj reference is non-secret; only handed to
-- SetCooldownFromDurationObject (safe sink), never read/compared/arithmetic.
-- Pushing onto the Blizzard Cooldown reuses the ignoreAuraOverride pattern
-- (hooksecurefunc, only _arc* fields). Appearance reuses the SAME _arc levers
-- (_arcForceDesatValue / _arcDesiredSwipe / _arcDesiredEdge) the CDMEnhance hooks
-- already enforce — CooldownState delegates here while we're active so nothing
-- fights.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local DO = {}
ns.DurationOverride = DO

local CORRELATE_WINDOW = 0.5  -- cast-success → totem-slot-fill window

-- spellID -> { [frame] = true }      (rebuilt by RefreshAll)
local spellToFrames = {}
-- frame   -> { cdID, mode, manual, spellID, endSpells={[id]=true}, visuals={...} }
local enabled = {}

local pendingFrame, pendingTime = nil, nil  -- totem-mode cast awaiting a slot

-- ArcUI-owned host + probe Cooldown (non-secret "is slot occupied?" via IsShown).
local host = CreateFrame("Frame")
host:Hide()
local probeCD = CreateFrame("Cooldown", nil, host, "CooldownFrameTemplate")
probeCD:Hide()

local EndOverride  -- fwd

-- ── helpers ────────────────────────────────────────────────────────────────

local function GetFrameSpellID(frame)
    local ci = frame and frame.cooldownInfo
    if not ci then return nil end
    return ci.overrideSpellID or ci.spellID
end

-- Resolve the spellID whose cast should trigger an Arc Aura frame's override:
-- the spell itself, or an item/trinket's on-use spell (NON-secret spellID from
-- GetItemSpell). Returns nil for timer/totem frames — those ARE durations, not
-- override targets.
local function ArcTriggerSpellID(arcID)
    if not (ns.ArcAuras and ns.ArcAuras.ParseArcID) then return nil end
    local t, id = ns.ArcAuras.ParseArcID(arcID)
    if t == "spell" then
        return id
    elseif t == "item" and id then
        local _, sid = C_Item.GetItemSpell(id)
        return tonumber(sid)
    elseif t == "trinket" and id then
        local itemID = GetInventoryItemID("player", id)
        if itemID then
            local _, sid = C_Item.GetItemSpell(itemID)
            return tonumber(sid)
        end
    end
    return nil
end

-- Parse a comma/space separated spell-ID string into a set.
local function ParseSpellIDs(str)
    local set = nil
    if type(str) == "string" then
        for token in str:gmatch("[^%s,]+") do
            local id = tonumber(token)
            if id then set = set or {}; set[id] = true end
        end
    end
    return set
end

local function ResolveIcon(frame)
    local t = frame and frame.Icon
    if t and not t.SetDesaturated and t.Icon then t = t.Icon end
    return t
end

-- Returns the slot's live durObj if a totem currently occupies it, else nil.
-- Non-secret: feed into the probe Cooldown (clearIfZero) then read IsShown().
local function SlotActiveDurObj(slot)
    if not GetTotemDuration then return nil end
    local durObj = GetTotemDuration(slot)
    if not durObj then return nil end
    probeCD:SetCooldownFromDurationObject(durObj, true)
    if probeCD:IsShown() then return durObj end
    return nil
end

-- ── cooldown push + re-assert hooks (mirror ignoreAuraOverride) ─────────────

local function Reassert(frame, why)
    local cd = frame.Cooldown
    -- For an AURA-source override, re-read the source aura's CURRENT durObj on every push so
    -- the displayed duration always tracks the live aura (so refreshes are reflected),
    -- instead of re-pushing the stale snapshot captured at start. Re-pushing an unchanged
    -- end-time is a visual no-op, so this is flicker-free. Cast/totem/manual overrides have
    -- no provider and keep their fixed durObj.
    local provider = frame._arcDurOvGetDurObj
    if provider then
        local fresh = provider()
        if fresh then frame._arcDurOvDurObj = fresh end
    end
    local durObj = frame._arcDurOvDurObj
    if not cd or not durObj then return end
    frame._arcDurOvWhy = why    -- debug breadcrumb for ArcUI_CDMAuraProbe (non-secret _arc field)
    frame._arcDurOvBypass = true
    cd:SetCooldownFromDurationObject(durObj)
    frame._arcDurOvBypass = false
end

local function InstallHooks(frame)
    local cd = frame.Cooldown
    if not cd or cd._arcDurOvHooked then return end
    cd._arcDurOvHooked = true
    cd._arcDurOvParent = frame

    hooksecurefunc(cd, "SetCooldownFromDurationObject", function(self, durObj)
        local pf = self._arcDurOvParent
        if not pf or pf._arcDurOvBypass then return end
        pf._arcDurOvRealDurObj = durObj                     -- remember CDM's value
        if pf._arcDurOvActive then Reassert(pf, "reassert-cdm-durobj") end
    end)
    hooksecurefunc(cd, "SetCooldown", function(self)
        local pf = self._arcDurOvParent
        if not pf or pf._arcDurOvBypass then return end
        if pf._arcDurOvActive then Reassert(pf, "reassert-cdm-setcd") end          -- numeric push → re-assert
    end)
    -- Clear: when the REAL spell cooldown ENDS, CDM calls Cooldown:Clear() (not SetCooldown),
    -- which the two hooks above miss -- so without this the override vanishes and the icon
    -- shows "ready" while the aura is still up. Re-assert so the aura duration keeps showing
    -- (aura duration outranks the real cooldown).
    if type(cd.Clear) == "function" then
        hooksecurefunc(cd, "Clear", function(self)
            local pf = self._arcDurOvParent
            if not pf or pf._arcDurOvBypass then return end
            if pf._arcDurOvActive then Reassert(pf, "reassert-cdm-clear") end
        end)
    end
end

-- ── appearance (aura-active treatment, reusing CDMEnhance's _arc levers) ────

-- Force the icon desaturation. value 0 = colored, 1 = desaturated. Sets
-- _arcForceDesatValue (the SetDesaturated hook's authority) and applies now.
local function ForceDesat(frame, value)
    local iconTex = ResolveIcon(frame)
    frame._arcForceDesatValue = value
    if not iconTex then return end
    frame._arcBypassDesatHook = true
    if iconTex.SetDesaturation then iconTex:SetDesaturation(value)
    else iconTex:SetDesaturated(value == 1) end
    frame._arcBypassDesatHook = false
end

-- Force swipe/edge visibility. Sets _arcDesired* (the SetDrawSwipe/Edge hook
-- authority) and applies now, bypass-guarded.
local function ForceSwipeEdge(frame, showSwipe, showEdge)
    local cd = frame.Cooldown
    frame._arcDesiredSwipe = showSwipe
    frame._arcDesiredEdge  = showEdge
    if not cd then return end
    frame._arcBypassSwipeHook = true
    cd:SetDrawSwipe(showSwipe)
    cd:SetDrawEdge(showEdge)
    frame._arcBypassSwipeHook = false
end

-- Apply the override's appearance while active. Called by StartOverride and by
-- CooldownState's delegate (so it survives CDM repaints).
-- Build the visuals table from a durationOverride config (shared by the live
-- registry and the options glow preview).
local function BuildVisuals(cfg)
    return {
        desaturate = cfg.desaturate == true,
        showSwipe  = cfg.showSwipe,
        showEdge   = cfg.showEdge,
        glow       = cfg.glow == true,
        glowType   = cfg.glowType,
        glowColor  = cfg.glowColor,
        glowScale  = cfg.glowScale,
        glowSpeed  = cfg.glowSpeed,
        glowLines  = cfg.glowLines,
        glowThickness = cfg.glowThickness,
        glowParticles = cfg.glowParticles,
        glowXOffset = cfg.glowXOffset,
        glowYOffset = cfg.glowYOffset,
        glowFrameStrata = cfg.glowFrameStrata,
        glowFrameLevel  = cfg.glowFrameLevel,
    }
end

-- Build the live override's appearance from the SHARED "Aura Active State" look
-- (aa = the auraActiveState config). The custom duration is treated as the icon
-- being aura-active, so it reuses the same glow the spell's own CDM aura uses:
--   - colored (desaturate=false) and swipe/edge shown while active (the inactive
--     "Desaturate When Aura Inactive" is handled by the normal cooldown path).
--   - glow mirrors auraActiveState's "Glow When Aura Active" + its glow suite.
local function BuildVisualsFromAuraActive(s)
    s = s or {}
    local aa = s.auraActiveState or {}
    local sw = s.cooldownSwipe or {}
    return {
        desaturate    = false,
        showSwipe     = true,
        showEdge      = true,
        glow          = aa.glow == true,
        glowType      = aa.glowType,
        glowColor     = aa.glowColor,
        glowScale     = aa.glowScale,
        glowSpeed     = aa.glowSpeed,
        glowLines     = aa.glowLines,
        glowThickness = aa.glowThickness,
        glowParticles = aa.glowParticles,
        glowXOffset   = aa.glowXOffset,
        glowYOffset   = aa.glowYOffset,
        glowFrameStrata = aa.glowFrameStrata,
        glowFrameLevel  = aa.glowFrameLevel,
        -- Swipe reverse + custom color while active. These are the SAME shared
        -- "Aura Active State" swipe options the own-CDM-aura path uses; they live
        -- in cooldownSwipe.* (reverseWhileAura / auraSwipeColor / base reverse).
        reverseSwipe   = sw.reverseWhileAura == true,
        baseReverse    = sw.reverse == true,
        auraSwipeColor = sw.auraSwipeColor,
        -- "Alpha while aura active" -- the override == aura active, so honor it here too.
        activeAlphaEnabled = aa.activeAlphaEnabled == true,
        activeAlpha        = aa.activeAlpha,
    }
end

-- Start/stop the override glow on a frame from a visuals table (shared by the
-- live override and the options preview).
local function StartGlow(frame, v)
    if not ns.Glows then return end
    if v and v.glow then
        local gc = v.glowColor
        ns.Glows.Start(frame, "durov", v.glowType or "button", {
            color      = gc and { gc.r or 1, gc.g or 0.85, gc.b or 0.1, gc.a or 1 } or nil,
            scale      = v.glowScale or 1.0,
            frequency  = v.glowSpeed or 0.25,
            lines      = v.glowLines or 8,
            thickness  = v.glowThickness or 2,
            particles  = v.glowParticles or 4,
            xOffset    = v.glowXOffset or 0,
            yOffset    = v.glowYOffset or 0,
            strata     = v.glowFrameStrata,
            frameLevel = v.glowFrameLevel,
        })
    else
        ns.Glows.Stop(frame, "durov")
    end
end

function DO.ApplyVisuals(frame)
    local v = frame._arcDurOvVisuals
    if not v then return end
    -- Default: don't desaturate (treat as aura-active). Opt-in to desaturate.
    ForceDesat(frame, (v.desaturate == true) and 1 or 0)
    ForceSwipeEdge(frame, v.showSwipe ~= false, v.showEdge ~= false)
    StartGlow(frame, v)
    -- Swipe reverse + custom swipe color while active (shared Aura Active State look).
    -- SetReverse/SetSwipeColor are sticky widget state CDM's SetCooldown doesn't reset,
    -- so a one-time set here survives CDM repaints.
    local cd = frame.Cooldown
    if cd then
        if cd.SetReverse then cd:SetReverse(v.reverseSwipe == true or v.baseReverse == true) end
        if cd.SetSwipeColor and v.auraSwipeColor then
            local c = v.auraSwipeColor
            cd:SetSwipeColor(c.r or 1, c.g or 0.95, c.b or 0.57, c.a or 0.7)
        end
    end
    -- "Alpha while aura active" (opt-in): force the icon's opacity while the override owns it,
    -- overriding the (possibly stale) Ready/On-Cooldown alpha. _arcAuraActiveAlpha is the
    -- high-precedence lever the CDMEnhance frame SetAlpha hook enforces against CDM repaints;
    -- set it + apply now (bypassing that hook). Any value (incl. 1) applies when enabled.
    if v.activeAlphaEnabled then
        local a = v.activeAlpha or 1
        frame._arcAuraActiveAlpha = a
        frame._arcBypassFrameAlphaHook = true
        frame:SetAlpha(a)
        frame._arcBypassFrameAlphaHook = false
        frame._lastAppliedAlpha = a
    elseif frame._arcAuraActiveAlpha ~= nil then
        frame._arcAuraActiveAlpha = nil
    end
end

-- ── glow preview (options panel) ────────────────────────────────────────────
-- cdID is the cooldownID (native CDM) or the arcID (Arc Auras) — both index
-- GetIconSettings. Resolves the live frame so the preview glow shows the current
-- glow settings without the override actually being active.
DO.previewFrames = {}  -- [frame] = cdID

local function ResolveFrameForCdID(cdID)
    if cdID == nil then return nil end
    if ns.ArcAuras and ns.ArcAuras.frames and ns.ArcAuras.frames[cdID] then
        return ns.ArcAuras.frames[cdID]
    end
    if ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrameData then
        local d = ns.CDMEnhance.GetEnhancedFrameData(cdID)
        if d then return d.frame end
    end
    return nil
end

function DO.SetGlowPreview(cdID, on)
    local frame = ResolveFrameForCdID(cdID)
    if not frame then return end
    if on then
        DO.previewFrames[frame] = cdID
        local s = ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(cdID)
        local v = BuildVisuals((s and s.durationOverride) or {})
        v.glow = true                 -- preview always shows the glow
        StartGlow(frame, v)
    else
        DO.previewFrames[frame] = nil
        if frame._arcDurOvActive then
            DO.ApplyVisuals(frame)    -- restore the real override glow
        elseif ns.Glows then
            ns.Glows.Stop(frame, "durov")
        end
    end
end

function DO.IsGlowPreviewActive(cdID)
    local frame = ResolveFrameForCdID(cdID)
    return frame ~= nil and DO.previewFrames[frame] ~= nil
end

function DO.ClearGlowPreview()
    local frames = {}
    for frame in pairs(DO.previewFrames) do frames[#frames + 1] = frame end
    for _, frame in ipairs(frames) do
        DO.previewFrames[frame] = nil
        if frame._arcDurOvActive then
            DO.ApplyVisuals(frame)
        elseif ns.Glows then
            ns.Glows.Stop(frame, "durov")
        end
    end
end

-- Re-apply active previews with current settings (called after a settings change).
local function RefreshGlowPreviews()
    for frame, cdID in pairs(DO.previewFrames) do
        local s = ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(cdID)
        local v = BuildVisuals((s and s.durationOverride) or {})
        v.glow = true
        StartGlow(frame, v)
    end
end

-- Clear the appearance levers + glow so CooldownState reclaims the frame.
local function ClearVisuals(frame)
    frame._arcForceDesatValue = nil
    frame._arcDesiredSwipe = nil
    frame._arcDesiredEdge  = nil
    frame._arcAuraActiveAlpha = nil   -- release the "alpha while aura active" lever (RepaintOnEnd restores)
    if ns.Glows then ns.Glows.Stop(frame, "durov") end
    -- Restore swipe reverse + color to the icon's base (non-aura) state, mirroring
    -- CooldownState's own-aura clear path (override end == aura no longer active).
    local cd = frame.Cooldown
    if cd then
        local cdID = frame._arcDurOvCdID
        local s = cdID and ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(cdID)
        local sw = s and s.cooldownSwipe
        if cd.SetReverse then cd:SetReverse(sw and sw.reverse == true or false) end
        if cd.SetSwipeColor then
            local base = sw and sw.swipeColor
            if base then cd:SetSwipeColor(base.r or 0, base.g or 0, base.b or 0, base.a or 0.8)
            else cd:SetSwipeColor(0, 0, 0, 0.8) end
        end
    end
end

-- Repaint the frame's normal (non-override) visuals after an override ends.
-- Arc Aura frames (spell/item/trinket) repaint through their own engine; native
-- CDM frames through CooldownState.
local function RepaintOnEnd(frame)
    local arcID = frame._arcDurOvArcID
    if arcID then
        -- Arc SPELL frames live in ArcAurasCooldown.spellData and repaint via its
        -- spell-visual pass; item/trinket frames repaint via ArcAuras.
        local spellData = ns.ArcAurasCooldown and ns.ArcAurasCooldown.spellData
        if spellData and spellData[arcID] and ns.ArcAurasCooldown.RefreshSpellVisuals then
            ns.ArcAurasCooldown.RefreshSpellVisuals(arcID)
        elseif ns.ArcAuras and ns.ArcAuras.RefreshFrameSettings then
            ns.ArcAuras.RefreshFrameSettings(arcID)
        end
        return
    end
    local cdID = frame._arcDurOvCdID
    if cdID and ns.CooldownState and ns.CooldownState.Apply and ns.CDMEnhance and ns.CDMEnhance.GetIconSettings then
        local cfg = ns.CDMEnhance.GetIconSettings(cdID)
        if cfg then ns.CooldownState.Apply(frame, cfg) end
    end

    -- FORCE desat re-check. For a normal cooldown icon, CooldownState's standard
    -- on-cooldown desat RELEASES to CDM (`_arcForceDesatValue == nil`) and relies
    -- on CDM firing SetDesaturated — but CDM won't re-fire after our override left
    -- the icon colored, so it stays colored. If CooldownState landed on the
    -- cooldown branch (per `_arcDesatBranch`) with no forced value, actively apply
    -- CDM's default desaturation now. (noDesaturate / aura cases set a forced
    -- value above and are already handled; ready cases keep it colored.)
    if frame._arcForceDesatValue == nil
       and (frame._arcDesatBranch == "C_BIN_CD" or frame._arcDesatBranch == "IAO_BIN_CD") then
        local iconTex = ResolveIcon(frame)
        if iconTex then
            frame._arcBypassDesatHook = true
            if iconTex.SetDesaturation then iconTex:SetDesaturation(1) else iconTex:SetDesaturated(true) end
            frame._arcBypassDesatHook = false
        end
    end
end

-- ── start / end ────────────────────────────────────────────────────────────

local function StartOverride(frame, durObj)
    local entry = enabled[frame]
    InstallHooks(frame)
    frame._arcDurOvActive  = true
    frame._arcDurOvDurObj  = durObj
    frame._arcDurOvVisuals = entry and entry.visuals or nil
    frame._arcDurOvCdID    = entry and entry.cdID or frame.cooldownID
    frame._arcDurOvArcID   = (entry and entry.isArc) and entry.cdID or nil
    Reassert(frame, "cast-start")
    DO.ApplyVisuals(frame)
end

EndOverride = function(frame, restore)
    if not frame._arcDurOvActive then return end
    frame._arcDurOvActive = false
    frame._arcDurOvDurObj = nil
    frame._arcDurOvGetDurObj = nil
    frame._arcDurOvSlot   = nil
    ClearVisuals(frame)
    if restore and frame._arcDurOvRealDurObj and frame.Cooldown then
        frame._arcDurOvWhy = "end-restore-real"   -- probe breadcrumb
        frame._arcDurOvBypass = true
        frame.Cooldown:SetCooldownFromDurationObject(frame._arcDurOvRealDurObj)
        frame._arcDurOvBypass = false
    end
    RepaintOnEnd(frame)
end
DO.EndOverride = EndOverride

-- ── triggers ───────────────────────────────────────────────────────────────

local function StartManual(frame, entry)
    local dur = tonumber(entry.manual) or 0
    if dur <= 0 or not (C_DurationUtil and C_DurationUtil.CreateDuration) then return end
    frame._arcDurOvManualObj = frame._arcDurOvManualObj or C_DurationUtil.CreateDuration()
    frame._arcDurOvManualObj:SetTimeFromStart(GetTime(), dur)
    frame._arcDurOvSlot = nil
    StartOverride(frame, frame._arcDurOvManualObj)
    -- End after the fixed duration. Token guards against a recast restarting it.
    frame._arcDurOvToken = (frame._arcDurOvToken or 0) + 1
    local token = frame._arcDurOvToken
    C_Timer.After(dur, function()
        if frame._arcDurOvActive and frame._arcDurOvToken == token then
            EndOverride(frame, true)
        end
    end)
end

local function OnCastSuccess(spellID)
    -- 1) END trigger: a configured "consume" spell ends an active override early.
    for frame, entry in pairs(enabled) do
        if frame._arcDurOvActive and entry.endSpells and entry.endSpells[spellID] then
            EndOverride(frame, true)
        end
    end

    -- 2) START trigger: this icon's spell was cast.
    local frames = spellToFrames[spellID]
    if frames then
        for frame in pairs(frames) do
            local entry = enabled[frame]
            if entry then
                if entry.mode == "manual" then
                    StartManual(frame, entry)
                else
                    pendingFrame, pendingTime = frame, GetTime()  -- arm totem window
                end
            end
        end
    end
end

local function OnTotemUpdate(slot)
    -- Correlate a fresh totem-spell cast to this newly-occupied slot.
    if pendingFrame and pendingTime and (GetTime() - pendingTime) <= CORRELATE_WINDOW then
        local durObj = SlotActiveDurObj(slot)
        if durObj and enabled[pendingFrame] then
            pendingFrame._arcDurOvSlot = slot
            StartOverride(pendingFrame, durObj)
            pendingFrame, pendingTime = nil, nil
        end
    end
    -- Refresh / expire any active totem override bound to this slot.
    for frame, entry in pairs(enabled) do
        if entry.mode == "totem" and frame._arcDurOvActive and frame._arcDurOvSlot == slot then
            local durObj = SlotActiveDurObj(slot)
            if durObj then StartOverride(frame, durObj) else EndOverride(frame, true) end
        end
    end
end

-- ── conditions layer (evolve DO → Conditions) ───────────────────────────────
-- A cooldown icon reacts to a CONDITION (Phase 1: a CDM-tracked aura being
-- active) with EFFECTS — push the aura's remaining duration onto the icon and/or
-- glow it. Detection is event-driven + secret-safe: we watch the source aura's
-- CDM frame through ns.FrameActive (no polling, no secret comparisons). The
-- Duration effect uses the aura's own durObj fed into the same push machinery DO
-- already uses. Show/Hide effect + Spell Proc condition come in later phases.

-- sourceFrame -> { [targetFrame] = entry }   (effects this source drives on this target;
--   entry = { cdID, isArc, effDuration, doVisuals, effGlow, glowVisuals, visibility }).
-- A target can appear under MORE THAN ONE source (e.g. duration from buff A, glow from
-- buff B), and a single source's entry can carry several effects.
local condReg = {}
-- targetFrame -> true   (every target driven by any source — for full teardown on refresh)
local condTargets = {}
-- sourceFrame -> true   (detection hooks installed once per source frame)
local condWatched = {}

-- The source aura's live durObj (Duration effect). auraInstanceID is NON-secret;
-- guard nil/0/secret because GetAuraDuration is RequiresValidUnitAuraInstance (it
-- THROWS on an invalid instance, never returns nil).
local function CondSourceDurObj(sourceFrame)
    -- Read the source's CURRENT auraInstanceID live (handles a refresh giving a new id).
    local aiid = sourceFrame and sourceFrame.auraInstanceID
    if not aiid then return nil end
    -- 12.1: the instance-id aura APIs (line ~561/562) THROW while the unit's auras are secret,
    -- and aiid stays NON-secret in that state -> gate on the ns.API.AurasSecret probe. Inert on live.
    if ns.API and ns.API.AurasSecret and ns.API.AurasSecret(sourceFrame.auraDataUnit or "player") then return nil end
    if aiid == 0 then return nil end
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID and C_UnitAuras.GetAuraDuration) then return nil end
    local unit = sourceFrame.auraDataUnit or "player"
    -- CRITICAL: GetAuraDuration is RequiresValidUnitAuraInstance -- it THROWS (can crash the
    -- client) on a stale/invalid (unit, auraInstanceID), which happens during CDM's refresh /
    -- false-clear churn while we re-read live. Validate first with the non-throwing
    -- GetAuraDataByAuraInstanceID -- the exact guard Core's aura bars + AuraFrames use.
    if not C_UnitAuras.GetAuraDataByAuraInstanceID(unit, aiid) then return nil end
    return C_UnitAuras.GetAuraDuration(unit, aiid)
end

-- Condition glow uses its OWN glow key ("cond"), separate from the duration override's
-- "durov" glow, so a duration push (DO-aura source) and a condition glow can coexist on
-- the same icon without one stopping the other.
local function CondStartGlow(target, v)
    if not ns.Glows then return end
    if v and v.glow then
        local gc = v.glowColor
        ns.Glows.Start(target, "cond", v.glowType or "button", {
            color      = gc and { gc.r or 1, gc.g or 0.85, gc.b or 0.1, gc.a or 1 } or nil,
            scale      = v.glowScale or 1.0,
            frequency  = v.glowSpeed or 0.25,
            lines      = v.glowLines or 8,
            thickness  = v.glowThickness or 2,
            particles  = v.glowParticles or 4,
            xOffset    = v.glowXOffset or 0,
            yOffset    = v.glowYOffset or 0,
            strata     = v.glowFrameStrata,
            frameLevel = v.glowFrameLevel,
        })
    else
        ns.Glows.Stop(target, "cond")
    end
end

local function CondStopGlow(target)
    if ns.Glows then ns.Glows.Stop(target, "cond") end
end

-- A SetAlpha enforcement hook installed on the TARGET itself, so Show/Hide works
-- identically on native CDM icons AND Arc spell/item icons (their alpha is driven by
-- different systems, but both call frame:SetAlpha, which this re-asserts over). We
-- only ever FORCE-HIDE (alpha 0) — never force-show — so it never fights Force Hide
-- or the cooldown-state alpha; those set their value, we just override it to 0.
local function InstallCondAlphaHook(target)
    if target._arcCondAlphaHooked then return end
    target._arcCondAlphaHooked = true
    hooksecurefunc(target, "SetAlpha", function(self, alpha)
        if self._arcBypassCondAlpha then return end
        if self._arcCondForceHide and alpha ~= 0 then
            self._arcBypassCondAlpha = true
            self:SetAlpha(0)
            self._arcBypassCondAlpha = false
        end
    end)
end

-- Re-apply the target's normal visuals (restores its real alpha once a Show/Hide
-- force-hide is released). Native CDM via CooldownState, Arc via its own engine.
local function CondRepaintTarget(target)
    if target._arcCondIsArc then
        local arcID = target._arcCondCdID
        local spellData = ns.ArcAurasCooldown and ns.ArcAurasCooldown.spellData
        if arcID and spellData and spellData[arcID] and ns.ArcAurasCooldown.RefreshSpellVisuals then
            ns.ArcAurasCooldown.RefreshSpellVisuals(arcID)
        elseif arcID and ns.ArcAuras and ns.ArcAuras.RefreshFrameSettings then
            ns.ArcAuras.RefreshFrameSettings(arcID)
        end
    else
        local cdID = target._arcCondCdID
        if cdID and ns.CooldownState and ns.CooldownState.Apply
           and ns.CDMEnhance and ns.CDMEnhance.GetIconSettings then
            local cfg = ns.CDMEnhance.GetIconSettings(cdID)
            if cfg then ns.CooldownState.Apply(target, cfg) end
        end
    end
end

-- Show/Hide effect. "hide" → hide the icon while the source is active; "show" → show
-- the icon ONLY while active (hide it when inactive). Both reduce to "force-hide in
-- one state, restore in the other", so we never force-show (no alpha fight).
local function CondApplyVisibility(target, vis, active)
    local shouldHide
    if vis == "hide" then shouldHide = active
    elseif vis == "show" then shouldHide = not active end
    if shouldHide == nil then
        if target._arcCondForceHide then
            target._arcCondForceHide = nil
            CondRepaintTarget(target)
        end
        return
    end
    if shouldHide then
        if not target._arcCondForceHide then
            InstallCondAlphaHook(target)
            target._arcCondForceHide = true
            target._arcBypassCondAlpha = true
            target:SetAlpha(0)
            target._arcBypassCondAlpha = false
        end
    elseif target._arcCondForceHide then
        target._arcCondForceHide = nil
        CondRepaintTarget(target)
    end
end

-- Apply/clear one source's effects on one target for the source's active state. Each
-- effect has its OWN per-target guard so duration / glow / visibility are independent
-- (duration from one source, glow from another, can both ride the same icon).
local function CondApplyEntry(target, entry, sourceFrame, active, refresh)
    target._arcCondCdID  = entry.cdID
    target._arcCondIsArc = entry.isArc

    -- DURATION: push the source aura/totem's durObj onto the icon (guard _arcCondDurOn).
    if entry.effDuration then
        if active then
            if not target._arcCondDurOn then
                local durObj = CondSourceDurObj(sourceFrame)
                if durObj then
                    target._arcCondDurOn    = true
                    InstallHooks(target)
                    target._arcDurOvActive  = true
                    target._arcDurOvDurObj  = durObj
                    -- live re-read on every re-assert so refreshes are always reflected
                    target._arcDurOvGetDurObj = function() return CondSourceDurObj(sourceFrame) end
                    target._arcDurOvVisuals = entry.doVisuals
                    target._arcDurOvCdID    = entry.cdID
                    target._arcDurOvArcID   = entry.isArc and entry.cdID or nil
                    Reassert(target, "cond-start")
                    DO.ApplyVisuals(target)
                end
            elseif refresh and target._arcDurOvActive then
                -- aura refreshed (UNIT_AURA updated): re-read its durObj + re-push, no clear
                local durObj = CondSourceDurObj(sourceFrame)
                if durObj then
                    target._arcDurOvDurObj = durObj
                    Reassert(target, "cond-refresh")
                end
            end
        elseif target._arcCondDurOn then
            target._arcCondDurOn = false
            if target._arcDurOvActive then EndOverride(target, true) end
        end
    end

    -- GLOW (key "cond"; guard _arcCondGlowOn).
    if entry.effGlow then
        if active then
            if not target._arcCondGlowOn then
                target._arcCondGlowOn = true
                CondStartGlow(target, entry.glowVisuals)
            end
        elseif target._arcCondGlowOn then
            target._arcCondGlowOn = false
            CondStopGlow(target)
        end
    end

    -- VISIBILITY (evaluated every time so a "show while active" target is hidden even
    -- before its first activation).
    if entry.visibility then
        CondApplyVisibility(target, entry.visibility, active)
    end
end

-- Clear ALL condition effects on a target (used before a rebuild and on removal).
local function CondFullClear(target)
    if target._arcCondDurOn then
        target._arcCondDurOn = false
        if target._arcDurOvActive then EndOverride(target, true) end
    end
    if target._arcCondGlowOn then
        target._arcCondGlowOn = false
        CondStopGlow(target)
    end
    if target._arcCondForceHide then
        target._arcCondForceHide = nil
        CondRepaintTarget(target)
    end
end

-- Recompute a source's active state and push it to every target it drives. ACTIVE if its
-- buff/debuff aura is present (`_arcCondAuraOn`: SET by CDM's OnAuraInstanceInfoSet,
-- CLEARED by UNIT_AURA's removedAuraInstanceIDs -- NOT by CDM's OnAuraInstanceInfoCleared,
-- which fires a FALSE clear on spell-override refreshes) OR a totem occupies it
-- (`_arcCondTotemOn`). All signals ride the CDM/aura DATA, so they are
-- VISIBILITY-INDEPENDENT. `refresh` (UNIT_AURA updated) re-reads a duration durObj.
local function CondReeval(sourceFrame, refresh)
    local active = (sourceFrame._arcCondAuraOn == true) or (sourceFrame._arcCondTotemOn == true)
    local targets = condReg[sourceFrame]
    if not targets then return end
    for target, entry in pairs(targets) do
        CondApplyEntry(target, entry, sourceFrame, active, refresh)
    end
end

-- Install the source-frame detection once. CDM's own aura gain/loss events (the SAME
-- signal the aura bars + AuraFrames use) fire exactly once per aura gained/lost and count
-- self-auras (id 0) via Set; the totem event fires on PLAYER_TOTEM_UPDATE. Do NOT hook
-- OnShow/OnHide — the bar system hides the source icon while its aura is still active,
-- which would falsely clear the effect; these events ride the DATA, not visibility.
local function InstallCondDetection(sourceFrame)
    if condWatched[sourceFrame] then return end
    condWatched[sourceFrame] = true
    if type(sourceFrame.OnAuraInstanceInfoSet) == "function" then
        hooksecurefunc(sourceFrame, "OnAuraInstanceInfoSet", function(self, _auraSpellID, aid)
            self._arcCondAuraID     = aid
            self._arcCondClearToken = (self._arcCondClearToken or 0) + 1  -- cancel a pending self-aura debounce
            self._arcCondAuraOn     = true
            CondReeval(self)
        end)
    end
    if type(sourceFrame.OnAuraInstanceInfoCleared) == "function" then
        hooksecurefunc(sourceFrame, "OnAuraInstanceInfoCleared", function(self)
            -- CDM fires a FALSE Cleared on spell-override full refreshes (it re-Sets the aura
            -- the same frame -- proven via ArcUI_CDMAuraProbe). So don't trust this Cleared
            -- directly: debounce, then trust the frame's LIVE auraInstanceID -- a real clear
            -- leaves it nil; a false clear / override swap restores it (and the re-Set bumps
            -- the token, cancelling this). This ALSO catches a "gone" that UNIT_AURA MISSES:
            -- a target debuff vanishing when the target is dropped fires no UNIT_AURA removal,
            -- only this Cleared (the reported stuck-effect bug).
            self._arcCondClearToken = (self._arcCondClearToken or 0) + 1
            local token = self._arcCondClearToken
            C_Timer.After(0.05, function()
                if self._arcCondClearToken ~= token then return end   -- a re-Set re-armed the aura
                if self.auraInstanceID ~= nil then return end          -- still present (false clear / override swap)
                if self._arcCondAuraOn then
                    self._arcCondAuraOn = false
                    self._arcCondAuraID = nil
                    CondReeval(self)
                end
            end)
        end)
    end
    -- PLAYER_TOTEM_UPDATE writes totemData AFTER this hook, so defer one frame (same as
    -- FrameActive). `totemData ~= nil` is a safe nil-compare on a secret table.
    if type(sourceFrame.OnPlayerTotemUpdateEvent) == "function" then
        hooksecurefunc(sourceFrame, "OnPlayerTotemUpdateEvent", function(self)
            C_Timer.After(0, function()
                self._arcCondTotemOn = (self.totemData ~= nil)
                CondReeval(self)
            end)
        end)
    end
    -- Aura DURATION refresh: CDM pushes the source's OWN remaining time onto its Cooldown
    -- widget on every (re)application. Mirror that as a refresh so the duration pushed onto
    -- the target re-reads the new durObj. More reliable than matching UNIT_AURA
    -- updatedAuraInstanceIDs (CDM's spell-override RefreshData churn can mask it). Only the
    -- source's CDM aura push reaches here (GCDFilter/DO never push to a watched aura frame).
    if sourceFrame.Cooldown and sourceFrame.Cooldown.SetCooldownFromDurationObject then
        hooksecurefunc(sourceFrame.Cooldown, "SetCooldownFromDurationObject", function()
            if condWatched[sourceFrame] and sourceFrame._arcCondAuraOn then
                CondReeval(sourceFrame, true)   -- refresh: re-read + re-push the durObj onto the target
            end
        end)
    end
end

-- The authoritative "aura gone / refreshed" signal. CDM's OnAuraInstanceInfoCleared lies
-- on spell-override full refreshes; UNIT_AURA is the truth. One listener for all watched
-- sources (player + target). auraInstanceID is NON-secret, so these compares are safe.
-- condWatched is a small set (distinct condition sources); iterating it per event is cheap.
local condUnitAura = CreateFrame("Frame")
condUnitAura:RegisterUnitEvent("UNIT_AURA", "player", "target")
condUnitAura:RegisterEvent("PLAYER_TARGET_CHANGED")
condUnitAura:SetScript("OnEvent", function(_, event, _unit, info)
    if not next(condWatched) then return end
    -- A source TARGET debuff can vanish with NO UNIT_AURA removal (the "target" token just
    -- goes invalid on a target change), so the listener below never sees it. Re-seed every
    -- watched source from its LIVE auraInstanceID/totemData, deferred a tick so CDM has
    -- refreshed its frames first. (Player/self sources read the same value = harmless.)
    if event == "PLAYER_TARGET_CHANGED" then
        C_Timer.After(0.05, function()
            for sf in pairs(condWatched) do
                local aid = sf.auraInstanceID
                sf._arcCondAuraID     = aid
                sf._arcCondAuraOn     = (aid ~= nil)
                sf._arcCondTotemOn    = (sf.totemData ~= nil)
                sf._arcCondClearToken = (sf._arcCondClearToken or 0) + 1
                CondReeval(sf)
            end
        end)
        return
    end
    if not info then return end
    -- 12.1: UNIT_AURA payload is secret in restricted content -- #rem/#upd throw and the
    -- id compares would be secret-boolean tests. Bail; Conditions won't react under secrecy.
    -- Inert on live. (Real removal detection falls back to the CDM OnAuraInstanceInfoCleared
    -- hooks elsewhere in this module.)
    if issecretvalue and issecretvalue(info.isFullUpdate) then return end
    local rem = info.removedAuraInstanceIDs
    if rem then
        for sf in pairs(condWatched) do
            local aid = sf._arcCondAuraID
            if aid then
                for i = 1, #rem do
                    if rem[i] == aid then
                        sf._arcCondAuraOn     = false
                        sf._arcCondAuraID     = nil
                        sf._arcCondClearToken = (sf._arcCondClearToken or 0) + 1
                        CondReeval(sf)
                        break
                    end
                end
            end
        end
    end
    local upd = info.updatedAuraInstanceIDs
    if upd then
        for sf in pairs(condWatched) do
            local aid = sf._arcCondAuraID
            if aid then
                for i = 1, #upd do
                    if upd[i] == aid then
                        CondReeval(sf, true)   -- refresh: re-read the duration durObj
                        break
                    end
                end
            end
        end
    end
end)

-- Register an effect a source drives on a target. Merges into the (source,target) entry
-- so several effects (and several sources) can stack on one icon.
local function CondAddEffect(sourceCdID, target, cdID, isArc, setter)
    if sourceCdID == nil then return end
    local sourceFrame = ResolveFrameForCdID(sourceCdID)
    if not sourceFrame or sourceFrame == target then return end
    local map = condReg[sourceFrame]
    if not map then map = {}; condReg[sourceFrame] = map end
    local e = map[target]
    if not e then e = { cdID = cdID, isArc = isArc }; map[target] = e end
    setter(e)
    condTargets[target] = true
    InstallCondDetection(sourceFrame)
end

local function CondRefresh()
    -- Refresh is rare (panel open/close, PEW). Fully clear what's applied, then rebuild
    -- from scratch so REMOVED effects are cleared cleanly.
    for target in pairs(condTargets) do CondFullClear(target) end
    -- 12.1 container overlays (aura-by-spellID source) live outside condReg -- detach them all
    -- before the rebuild so removed/edited ones are cleared, then re-attach below.
    if ns.DurationOverrideContainer and ns.DurationOverrideContainer.DetachAll then
        ns.DurationOverrideContainer.DetachAll()
    end
    wipe(condReg)
    wipe(condTargets)
    if not (ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.FrameActive) then return end

    local function tryReg(cdID, target, isArc)
        local s = ns.CDMEnhance.GetIconSettings(cdID)
        if not s then return end

        -- "Add a separate aura" (Aura Active State) -> source = "Aura": push a chosen CDM
        -- buff/debuff/totem's remaining duration onto this icon (alongside Totem and Manual).
        -- This is the only consumer of the conditions layer now -- the old standalone
        -- "Condition" (glow / show-hide from another aura) was removed; the Aura Active State
        -- shared look + "Alpha while aura active" supersede it.
        local doCfg = s.durationOverride
        if doCfg and doCfg.enabled and doCfg.mode == "aura" then
            -- 12.1: overlay a spell-ID-filtered AuraButton so the aura's remaining duration shows
            -- on the icon secret-safe (no C_UnitAuras). Replaces the old CDM-aura-source (cooldownID)
            -- path -- the container reads the aura by SPELL ID directly. Live has no container -> no-op.
            if ns.DurationOverrideContainer and ns.DurationOverrideContainer.IsAvailable
               and ns.DurationOverrideContainer.IsAvailable() and doCfg.auraSpellID then
                ns.DurationOverrideContainer.Attach(target, doCfg.auraSpellID, "player")
            end
        end
    end

    -- Native CDM cooldown icons (never bind an aura viewer frame as a target).
    if ns.CDMEnhance.ForEachEnhancedFrame then
        ns.CDMEnhance.ForEachEnhancedFrame(function(cdID, frame, data)
            if data and data.viewerType == "aura" then return end
            if frame._arcViewerType == "aura" then return end
            tryReg(cdID, frame, false)
        end)
    end
    -- Arc Aura cooldown / item / trinket icons.
    if ns.ArcAuras and ns.ArcAuras.frames then
        for arcID, frame in pairs(ns.ArcAuras.frames) do
            tryReg(arcID, frame, true)
        end
    end

    -- Seed current state (the hooks only fire on later transitions). Read both aura
    -- presence (auraInstanceID: non-secret; 0 = a live self-aura, nil = gone) and totem
    -- presence (totemData ~= nil).
    for sourceFrame in pairs(condReg) do
        local aid = sourceFrame.auraInstanceID
        sourceFrame._arcCondAuraID  = aid   -- so UNIT_AURA removal can match (nil = none)
        sourceFrame._arcCondAuraOn  = (aid ~= nil)
        sourceFrame._arcCondTotemOn = (sourceFrame.totemData ~= nil)
        CondReeval(sourceFrame)
    end
end

-- ── registry ───────────────────────────────────────────────────────────────

-- cdID here is the cooldownID for native CDM frames, or the arcID for Arc Auras
-- (both index GetIconSettings). isArc routes the end-repaint to the right engine.
local function BuildEntry(cdID, spellID, isArc, cfg, s)
    return {
        cdID = cdID, spellID = spellID, isArc = isArc,
        mode = cfg.mode or "totem",
        manual = cfg.manual or 0,
        endSpells = ParseSpellIDs(cfg.endSpells),
        endOnDeath = cfg.endOnDeath == true,   -- manual mode: end the fixed timer early on death
        -- Appearance comes from the SHARED Aura Active State look (glow from
        -- auraActiveState, swipe reverse/color from cooldownSwipe), not the
        -- (retired) per-override appearance config.
        visuals = BuildVisualsFromAuraActive(s),
    }
end

function DO.RefreshAll()
    local nowEnabled = {}
    wipe(spellToFrames)
    if not (ns.CDMEnhance and ns.CDMEnhance.GetIconSettings) then enabled = nowEnabled; return end

    local function tryRegister(cdID, frame, spellID, isArc)
        if not (frame and spellID) then return end
        local s = ns.CDMEnhance.GetIconSettings(cdID)
        local cfg = s and s.durationOverride
        if not (cfg and cfg.enabled) then return end
        if cfg.mode == "aura" then return end   -- aura source is source-watched by the conditions layer, not cast-triggered
        nowEnabled[frame] = BuildEntry(cdID, spellID, isArc, cfg, s)
        spellToFrames[spellID] = spellToFrames[spellID] or {}
        spellToFrames[spellID][frame] = true
    end

    -- Native CDM cooldown icons (cooldown-only — never bind an aura viewer frame).
    if ns.CDMEnhance.ForEachEnhancedFrame then
        ns.CDMEnhance.ForEachEnhancedFrame(function(cdID, frame, data)
            if data and data.viewerType == "aura" then return end
            if frame._arcViewerType == "aura" then return end
            tryRegister(cdID, frame, GetFrameSpellID(frame), false)
        end)
    end

    -- Arc Aura spell / item / trinket icons (their own visual paths). Timer/totem
    -- arcIDs resolve to nil spellID and are skipped.
    if ns.ArcAuras and ns.ArcAuras.frames then
        for arcID, frame in pairs(ns.ArcAuras.frames) do
            tryRegister(arcID, frame, ArcTriggerSpellID(arcID), true)
        end
    end

    -- Tear down overrides on frames no longer enabled; refresh live visuals on
    -- frames whose appearance config changed while active.
    for frame in pairs(enabled) do
        if not nowEnabled[frame] then
            EndOverride(frame, true)
        elseif frame._arcDurOvActive then
            frame._arcDurOvVisuals = nowEnabled[frame].visuals
            DO.ApplyVisuals(frame)
        end
    end
    enabled = nowEnabled

    -- Conditions: aura-active triggers driving the same effect engine.
    CondRefresh()

    -- Keep any active glow previews in sync with edited settings.
    RefreshGlowPreviews()
end

-- ── events ─────────────────────────────────────────────────────────────────

local ev = CreateFrame("Frame")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
ev:RegisterEvent("PLAYER_TOTEM_UPDATE")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_DEAD")
ev:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg3 then OnCastSuccess(arg3) end          -- (unit, castGUID, spellID)
    elseif event == "PLAYER_TOTEM_UPDATE" then
        local slot = tonumber(arg1)
        if slot then OnTotemUpdate(slot) end
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(2.0, DO.RefreshAll)
    elseif event == "PLAYER_DEAD" then
        -- Manual "End on death": a fixed manual timer doesn't track an aura, so dying (which
        -- clears your buffs) would leave it running. End it early when the user opted in.
        for frame, entry in pairs(enabled) do
            if frame._arcDurOvActive and entry.mode == "manual" and entry.endOnDeath then
                EndOverride(frame, true)
            end
        end
    end
end)

if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
    ns.CDMShared.RegisterPanelCallback("DurationOverride", {
        onOpen  = function() DO.RefreshAll() end,
        onClose = function() DO.ClearGlowPreview(); DO.RefreshAll() end,
    })
end
