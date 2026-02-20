-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI CDM Spell Usability
-- Runtime module for spell usability visuals on CDM (Cooldown Manager) frames.
-- Handles:
--   1. Usability vertex color tinting via RefreshIconColor hook
--   2. Usable glow via overlay pattern (Ellesmere method)
--
-- Shadow cooldown frame creation and feeding is owned by CooldownState.
-- This file only READS shadow state (IsShown) for glow decisions.
--
-- ALPHA is NOT managed here. CooldownState.ApplyReadyState merges usability
-- alpha into readyAlpha (single-writer pattern), eliminating flicker from
-- multiple systems fighting over SetAlpha.
--
-- EVENT-DRIVEN: CooldownState dispatch (which calls UpdateGlow) is now
-- triggered from SPELL_UPDATE_COOLDOWN hooks + shadow OnCooldownDone,
-- not 20Hz polling. SPELL_UPDATE_USABLE (line 372) handles resource changes.
--
-- Settings are stored in cfg.spellUsability (managed by SpellUsabilityOptions).
-- Integration: CDMEnhance calls HookFrame() during enhancement.
--              UpdateGlow() is called from the CooldownState relay wrapper.
-- ═══════════════════════════════════════════════════════════════════════════

local addonName, ns = ...

ns.CDMSpellUsability = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- LCG ACCESS
-- ═══════════════════════════════════════════════════════════════════════════

local cachedLCG
local function GetLCG()
    if cachedLCG then return cachedLCG end
    cachedLCG = LibStub and LibStub("LibCustomGlow-1.0", true)
    return cachedLCG
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DEFAULT COLORS (match CDM constants and ArcAurasCooldown defaults)
-- ═══════════════════════════════════════════════════════════════════════════

local NOT_ENOUGH_MANA  = { r = 0.5, g = 0.5, b = 1.0, a = 1.0 }
local NOT_USABLE_COLOR = { r = 0.4, g = 0.4, b = 0.4, a = 1.0 }

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS PANEL STATE
-- ═══════════════════════════════════════════════════════════════════════════

local function IsOptionsPanelOpen()
    return ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen
        and ns.CDMEnhance.IsOptionsPanelOpen() or false
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function GetSpellIDFromFrame(frame)
    if frame.cooldownInfo then
        return frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
    end
    if frame.GetSpellID then
        local ok, id = pcall(frame.GetSpellID, frame)
        if ok then return id end
    end
    return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- USABILITY TINTING (RefreshIconColor hook)
--
-- Runs AFTER CDM sets its native colors. Overrides vertex color based
-- on spell usability state and user's custom tint settings.
-- Skip when out of range (range indicator handles that independently).
-- We do NOT check cooldown state here — cooldownDesaturated is SECRET.
-- CDM's own desaturation makes colors subtle during cooldown anyway.
-- ═══════════════════════════════════════════════════════════════════════════

function ns.CDMSpellUsability.OnRefreshIconColor(frame)
    if frame._arcBypassUsabilityHook then return end

    -- Skip Arc Auras frames (they handle their own usability)
    if frame._arcConfig or frame._arcAuraID then return end

    -- Get settings
    local cfg
    if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettingsForFrame then
        cfg = ns.CDMEnhance.GetEffectiveIconSettingsForFrame(frame)
    end
    if not cfg then return end

    local su = cfg.spellUsability

    -- Resolve icon texture early (shared by both disabled-override and enabled paths)
    local iconTex = frame.Icon or frame.icon
    if not iconTex then return end
    -- Bar-style icons: frame.Icon is a Frame container with .Icon child texture
    if not iconTex.SetVertexColor and iconTex.Icon then
        iconTex = iconTex.Icon
    end
    if not iconTex or not iconTex.SetVertexColor then return end

    -- When usability tinting is DISABLED, undo CDM's native tinting
    -- (same pattern as range indicator disabled: hook fires after CDM
    --  sets its usability colors, so we override back to white)
    if not su or su.enabled == false then
        -- Don't override if spell is out of range AND range indicator is enabled
        -- (let CDM/range handle the vertex color in that case)
        if frame.spellOutOfRange then
            local ri = cfg.rangeIndicator
            local rangeEnabled = not ri or ri.enabled ~= false
            if rangeEnabled then return end
        end
        -- Reset to full brightness (ITEM_USABLE_COLOR equivalent)
        iconTex:SetVertexColor(1, 1, 1, 1)
        return
    end

    -- Skip if spell is out of range AND range indicator is enabled (match ArcAuras)
    if frame.spellOutOfRange then
        local ri = cfg.rangeIndicator
        local rangeEnabled = not ri or ri.enabled ~= false
        if rangeEnabled then return end
    end

    local spellID = GetSpellIDFromFrame(frame)
    if not spellID then return end

    -- C_Spell.IsSpellUsable returns non-secret booleans
    local isUsable, notEnoughMana = C_Spell.IsSpellUsable(spellID)

    if isUsable then
        -- Usable → CDM already set ITEM_USABLE_COLOR, nothing to override
        return
    elseif notEnoughMana then
        local c = su.notEnoughResourceColor or NOT_ENOUGH_MANA
        iconTex:SetVertexColor(c.r or 0.5, c.g or 0.5, c.b or 1.0, c.a or 1.0)
        -- NOTE: Alpha is handled by CooldownState.ApplyReadyState which merges
        -- usability alpha into readyAlpha (single-writer pattern, no fighting).
    else
        local c = su.notUsableColor or NOT_USABLE_COLOR
        iconTex:SetVertexColor(c.r or 0.4, c.g or 0.4, c.b or 0.4, c.a or 1.0)
        -- NOTE: Alpha is handled by CooldownState.ApplyReadyState (single-writer).
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HOOK INSTALLER
-- Called from CDMEnhance during frame enhancement.
-- Installs RefreshIconColor hook for usability tinting.
-- ═══════════════════════════════════════════════════════════════════════════

function ns.CDMSpellUsability.HookFrame(frame)
    if not frame then return end
    if frame._arcUsabilityTintHooked then return end
    if not frame.RefreshIconColor then return end

    frame._arcUsabilityTintHooked = true

    hooksecurefunc(frame, "RefreshIconColor", function(self)
        ns.CDMSpellUsability.OnRefreshIconColor(self)
    end)

    -- Shadow cooldown frame is now created and managed by CooldownState.
    -- Create it eagerly here so it exists before the first event fires.
    if ns.CooldownState and ns.CooldownState.EnsureShadow then
        ns.CooldownState.EnsureShadow(frame)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- USABLE GLOW OVERLAY (dedicated per-icon frame)
--
-- Creates a DEDICATED child frame per icon for usable glow.
-- This gives usable glow its own _ButtonGlow (LCG stores one per frame),
-- eliminating all conflicts with ready/proc/preview glow on _arcGlowOverlay.
-- Same technique used by ArcAurasCooldown and EllesmereBarGlows.
-- ═══════════════════════════════════════════════════════════════════════════

local function GetUsableGlowOverlay(frame)
    if frame._arcUsableGlowOverlay then return frame._arcUsableGlowOverlay end
    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:SetFrameLevel(frame:GetFrameLevel() + 10)
    overlay:Show()
    frame._arcUsableGlowOverlay = overlay
    return overlay
end

local function StartGlowOnOverlay(overlay, glowType, color, opts)
    if not overlay then return end
    local LCG = GetLCG()
    if not LCG then return end
    opts = opts or {}
    local ca = color and { color.r or 1, color.g or 1, color.b or 1, color.a or 1 } or nil
    local key = opts.key or ""

    if glowType == "button" then
        LCG.ButtonGlow_Start(overlay, ca, opts.frequency)
    elseif glowType == "pixel" then
        LCG.PixelGlow_Start(overlay, ca, opts.lines or 8, opts.frequency or 0.25, opts.length, opts.thickness or 2, 0, 0, true, key)
    elseif glowType == "autocast" then
        LCG.AutoCastGlow_Start(overlay, ca, opts.particles or 4, opts.frequency or 0.25, opts.scale or 1, 0, 0, key)
    elseif glowType == "glow" then
        LCG.ProcGlow_Start(overlay, { color = ca, startAnim = false, key = key })
        local gf = overlay["_ProcGlow" .. key]
        if gf then
            if gf.ProcStart then gf.ProcStart:Hide() end
            if gf.ProcLoop then
                gf.ProcLoop:Show()
                gf.ProcLoop:SetAlpha(1.0)
            end
        end
    end
    -- Clamp LCG child frame levels to overlay level (prevents them rendering above duration text)
    if ns.CDMEnhance and ns.CDMEnhance.ClampOverlayChildren then
        ns.CDMEnhance.ClampOverlayChildren(overlay)
    end
end

local function StopUsableGlow(frame)
    local overlay = frame._arcUsableGlowOverlay
    if not overlay then return end
    -- Hide overlay FIRST — LCG's ButtonGlow_Stop checks r:IsVisible().
    -- When hidden it skips the fade animation, releases to pool immediately,
    -- and ButtonGlowResetter properly clears all _ButtonGlow references.
    -- This means next ButtonGlow_Start creates a fresh frame from the pool.
    overlay:Hide()
    overlay:SetAlpha(0)
    -- Stop keyed glow types
    local LCG = GetLCG()
    if LCG then
        LCG.PixelGlow_Stop(overlay, "usable")
        LCG.AutoCastGlow_Stop(overlay, "usable")
        if LCG.ProcGlow_Stop then LCG.ProcGlow_Stop(overlay, "usable") end
        -- ButtonGlow is safe to stop directly — dedicated overlay means no conflicts
        LCG.ButtonGlow_Stop(overlay)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GLOW UPDATE (called from CooldownState relay + ApplyIconVisuals)
--
-- Manages usable glow overlay based on spell state:
--   Show glow when: spell has resources (IsSpellUsable)
--                   AND not all charges depleted (shadow CD not shown)
--   Hide glow when: no resources OR all charges consumed
--
-- NOTE: Shadow cooldown is fed by CooldownState BEFORE this runs.
-- The event-driven dispatch order guarantees fresh shadow state.
-- ═══════════════════════════════════════════════════════════════════════════

function ns.CDMSpellUsability.UpdateGlow(frame, cfg)
    if not frame then return end
    -- Skip Arc Auras frames
    if frame._arcConfig or frame._arcAuraID then return end

    if not cfg then
        if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettingsForFrame then
            cfg = ns.CDMEnhance.GetEffectiveIconSettingsForFrame(frame)
        end
    end
    if not cfg then return end

    local su = cfg.spellUsability

    -- Shadow cooldown is fed by CooldownState.FeedShadow before UpdateGlow runs.
    -- We just read the shadow state here for glow decisions.
    local spellID = GetSpellIDFromFrame(frame)

    -- Check preview mode
    local cdID = frame.cooldownID
    local isPreview = cdID
        and ns.CDMEnhanceOptions
        and ns.CDMEnhanceOptions.IsUsableGlowPreviewActive
        and ns.CDMEnhanceOptions.IsUsableGlowPreviewActive(cdID)

    local shouldGlow = false

    if isPreview then
        -- Preview always shows glow
        shouldGlow = true
    elseif su and su.usableGlow and spellID then
            -- Shadow frame converts secret cooldown into non-secret boolean:
            --   IsShown()=true  → all charges depleted / full CD active
            --   IsShown()=false → has charges available / spell ready
            local shadowCD = frame._arcCDMShadowCooldown
            local allDepleted = shadowCD and shadowCD:IsShown() or false

            -- IsSpellUsable checks resources (mana/energy/etc) — non-secret
            local isUsable = C_Spell.IsSpellUsable(spellID)

            -- Glow when: has resources AND not fully on cooldown
            if isUsable and not allDepleted then
                local combatOnly = su.usableGlowCombatOnly
                shouldGlow = not combatOnly or InCombatLockdown()
            end
    end

    if shouldGlow then
        local glowSu = su or {}
        local glowType = glowSu.usableGlowType or "button"
        if glowType == "blizzard" then glowType = "glow" end  -- migrate
        -- Only restart if type changed or not active
        if not frame._arcCDMUsableGlowActive or frame._arcCDMUsableGlowType ~= glowType then
            -- Stop old glow if type changed
            if frame._arcCDMUsableGlowActive then
                StopUsableGlow(frame)
            end
            local gc = glowSu.usableGlowColor
            local overlay = GetUsableGlowOverlay(frame)
            overlay:Show()
            overlay:SetAlpha(1)
            StartGlowOnOverlay(overlay, glowType, gc, {
                key = "usable",
                lines = glowSu.usableGlowLines or 8,
                frequency = glowSu.usableGlowSpeed or 0.25,
                thickness = glowSu.usableGlowThickness or 2,
                particles = glowSu.usableGlowParticles or 4,
                scale = glowSu.usableGlowScale or 1,
            })
            frame._arcCDMUsableGlowActive = true
            frame._arcCDMUsableGlowType = glowType
        end
    elseif frame._arcCDMUsableGlowActive then
        StopUsableGlow(frame)
        frame._arcCDMUsableGlowActive = false
        frame._arcCDMUsableGlowType = nil
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CLEANUP HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

-- Force-stop all usable glows (for settings refresh)
function ns.CDMSpellUsability.StopAllGlows()
    if not ns.CDMEnhance or not ns.CDMEnhance.GetEnhancedFrames then return end
    local enhanced = ns.CDMEnhance.GetEnhancedFrames()
    if not enhanced then return end
    for _, entry in pairs(enhanced) do
        local frame = entry.frame
        if frame and frame._arcCDMUsableGlowActive then
            StopUsableGlow(frame)
            frame._arcCDMUsableGlowActive = false
            frame._arcCDMUsableGlowType = nil
        end
    end
end

-- Refresh all CDM frame usability visuals
-- IMPORTANT: Never call Blizzard's RefreshIconColor from here — it does a
-- boolean test on IsSpellUsable which is SECRET and taint persists even
-- after InCombatLockdown() returns false. Call our hook directly.
function ns.CDMSpellUsability.RefreshAll()
    if not ns.CDMEnhance or not ns.CDMEnhance.GetEnhancedFrames then return end
    local enhanced = ns.CDMEnhance.GetEnhancedFrames()
    if not enhanced then return end
    for _, entry in pairs(enhanced) do
        local frame = entry.frame
        if frame then
            ns.CDMSpellUsability.OnRefreshIconColor(frame)
            ns.CDMSpellUsability.UpdateGlow(frame)
        end
    end
end

-- Refresh a single CDM frame by cooldownID
function ns.CDMSpellUsability.RefreshFrame(cdID)
    if not ns.CDMEnhance or not ns.CDMEnhance.GetEnhancedFrames then return end
    local enhanced = ns.CDMEnhance.GetEnhancedFrames()
    if not enhanced or not enhanced[cdID] then return end
    local frame = enhanced[cdID].frame
    if frame then
        -- Force glow restart
        if frame._arcCDMUsableGlowActive then
            StopUsableGlow(frame)
            frame._arcCDMUsableGlowActive = false
            frame._arcCDMUsableGlowType = nil
        end
        -- Re-evaluate
        ns.CDMSpellUsability.UpdateGlow(frame)
        ns.CDMSpellUsability.OnRefreshIconColor(frame)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS PANEL STATE TICKER + USABILITY RECOVERY POLLING
-- ═══════════════════════════════════════════════════════════════════════════

local lastPanelOpenState = false
C_Timer.NewTicker(0.5, function()
    local isOpen = IsOptionsPanelOpen()
    if isOpen ~= lastPanelOpenState then
        lastPanelOpenState = isOpen
        ns.CDMSpellUsability.RefreshAll()
    end
end)

-- SPELL_UPDATE_USABLE fires on resource change, form/stance swap, etc.
local usabilityEventFrame = CreateFrame("Frame")
usabilityEventFrame:RegisterEvent("SPELL_UPDATE_USABLE")
usabilityEventFrame:SetScript("OnEvent", function()
    ns.CDMSpellUsability.RefreshAll()
end)