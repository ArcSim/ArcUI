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
        local _, sid = GetItemSpell(id)
        return tonumber(sid)
    elseif t == "trinket" and id then
        local itemID = GetInventoryItemID("player", id)
        if itemID then
            local _, sid = GetItemSpell(itemID)
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

local function Reassert(frame)
    local cd = frame.Cooldown
    local durObj = frame._arcDurOvDurObj
    if not cd or not durObj then return end
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
        if pf._arcDurOvActive then Reassert(pf) end
    end)
    hooksecurefunc(cd, "SetCooldown", function(self)
        local pf = self._arcDurOvParent
        if not pf or pf._arcDurOvBypass then return end
        if pf._arcDurOvActive then Reassert(pf) end          -- numeric push → re-assert
    end)
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
    if ns.Glows then ns.Glows.Stop(frame, "durov") end
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
    Reassert(frame)
    DO.ApplyVisuals(frame)
end

EndOverride = function(frame, restore)
    if not frame._arcDurOvActive then return end
    frame._arcDurOvActive = false
    frame._arcDurOvDurObj = nil
    frame._arcDurOvSlot   = nil
    ClearVisuals(frame)
    if restore and frame._arcDurOvRealDurObj and frame.Cooldown then
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

-- ── registry ───────────────────────────────────────────────────────────────

-- cdID here is the cooldownID for native CDM frames, or the arcID for Arc Auras
-- (both index GetIconSettings). isArc routes the end-repaint to the right engine.
local function BuildEntry(cdID, spellID, isArc, cfg)
    return {
        cdID = cdID, spellID = spellID, isArc = isArc,
        mode = cfg.mode or "totem",
        manual = cfg.manual or 0,
        endSpells = ParseSpellIDs(cfg.endSpells),
        visuals = BuildVisuals(cfg),
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
        nowEnabled[frame] = BuildEntry(cdID, spellID, isArc, cfg)
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

    -- Keep any active glow previews in sync with edited settings.
    RefreshGlowPreviews()
end

-- ── events ─────────────────────────────────────────────────────────────────

local ev = CreateFrame("Frame")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
ev:RegisterEvent("PLAYER_TOTEM_UPDATE")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg3 then OnCastSuccess(arg3) end          -- (unit, castGUID, spellID)
    elseif event == "PLAYER_TOTEM_UPDATE" then
        local slot = tonumber(arg1)
        if slot then OnTotemUpdate(slot) end
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(2.0, DO.RefreshAll)
    end
end)

if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
    ns.CDMShared.RegisterPanelCallback("DurationOverride", {
        onOpen  = function() DO.RefreshAll() end,
        onClose = function() DO.ClearGlowPreview(); DO.RefreshAll() end,
    })
end
