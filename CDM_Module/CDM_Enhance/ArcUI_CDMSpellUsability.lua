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
-- DEFAULT COLORS (match CDM constants and ArcAurasCooldown defaults)
-- ═══════════════════════════════════════════════════════════════════════════

local NOT_ENOUGH_MANA  = { r = 0.5, g = 0.5, b = 1.0, a = 1.0 }
local NOT_USABLE_COLOR = { r = 0.4, g = 0.4, b = 0.4, a = 1.0 }
local ON_CD_COLOR      = { r = 0.4, g = 0.4, b = 0.4, a = 1.0 }

-- ═══════════════════════════════════════════════════════════════════════════
-- DESATURATION HELPER
-- Uses the bypass flag so CDMEnhance's desat hooks don't intercept.
-- Also stores the request so CooldownState can respect it on next pass.
-- ═══════════════════════════════════════════════════════════════════════════

local function ApplyUsabilityDesat(frame, iconTex, desaturate)
    local wasRequested = frame._arcUsabilityDesatRequest
    -- Store request for CooldownState + CDMEnhance hooks to read
    frame._arcUsabilityDesatRequest = desaturate and true or nil

    -- ONLY touch desaturation when explicitly configured (true/false).
    -- When nil (not configured / releasing ownership), actively clear any
    -- desaturation WE previously applied so icons snap instantly to colored
    -- when resources become available (e.g. Elemental Blast at 80 Maelstrom).
    -- Without this, the icon stays desaturated until CDM's next RefreshData cycle (~1s).
    if desaturate == nil then
        if wasRequested and iconTex then
            frame._arcBypassDesatHook = true
            if iconTex.SetDesaturation then
                iconTex:SetDesaturation(0)
            elseif iconTex.SetDesaturated then
                iconTex:SetDesaturated(false)
            end
            frame._arcBypassDesatHook = false
        end
        return
    end

    if not iconTex then return end
    frame._arcBypassDesatHook = true
    if iconTex.SetDesaturation then
        iconTex:SetDesaturation(desaturate and 1 or 0)
    elseif iconTex.SetDesaturated then
        iconTex:SetDesaturated(desaturate and true or false)
    end
    frame._arcBypassDesatHook = false
end

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
        local id = frame:GetSpellID()
        if id and not issecretvalue(id) then return id end
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

-- Bypass keepBright hook when SpellUsability writes vertex color.
-- SpellUsability is the authority for ready-state tinting (OOM, not-usable,
-- normal) so keepBright must not override its writes.
local function SetVertexColorBypassed(frame, iconTex, r, g, b, a)
    frame._arcBypassVertexHook = true
    iconTex:SetVertexColor(r, g, b, a or 1)
    frame._arcBypassVertexHook = false
end

function ns.CDMSpellUsability.OnRefreshIconColor(frame, cfg, spellID, isUsable, notEnoughMana, allDepleted)
    if frame._arcBypassUsabilityHook then return end

    -- Skip Arc Auras frames (they handle their own usability)
    if frame._arcConfig or frame._arcAuraID then return end
    
    -- COOLDOWN FRAMES ONLY: Aura frames don't have spell usability state
    if frame._arcViewerType == "aura" then return end

    -- Get settings (use pre-computed if provided)
    if not cfg then
        if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettingsForFrame then
            cfg = ns.CDMEnhance.GetEffectiveIconSettingsForFrame(frame)
        end
    end
    if not cfg then return end

    -- KEEP BRIGHT: When enabled, SpellUsability must not tint or desaturate.
    -- SetVertexColorBypassed skips the keepBright vertex hook (by design),
    -- so we must respect keepBright HERE before applying any usability visuals.
    if cfg.keepBright then
        local iconTex = frame.Icon or frame.icon
        if iconTex and not iconTex.SetVertexColor and iconTex.Icon then
            iconTex = iconTex.Icon
        end
        if iconTex and iconTex.SetVertexColor then
            -- Force white (undo any CDM native tinting)
            SetVertexColorBypassed(frame, iconTex, 1, 1, 1, 1)
            -- Clear usability desat unless user explicitly allows desaturation with keepBright
            if not cfg.keepBrightAllowDesat then
                ApplyUsabilityDesat(frame, iconTex, false)
            end
        end
        return
    end

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
    if not su or not su.enabled then
        -- Don't override if spell is out of range AND range indicator is enabled
        -- (let CDM/range handle the vertex color in that case)
        if frame.spellOutOfRange then
            local ri = cfg.rangeIndicator
            local rangeEnabled = not ri or ri.enabled ~= false
            if rangeEnabled then return end
        end
        -- Reset to full brightness (ITEM_USABLE_COLOR equivalent)
        iconTex:SetVertexColor(1, 1, 1, 1)
        -- Pass nil (not false!) so ApplyUsabilityDesat returns early and
        -- does NOT clear desaturation.  CDM / CooldownState own desat when
        -- usability tinting is disabled.
        ApplyUsabilityDesat(frame, iconTex, nil)
        return
    end

    -- Skip if spell is out of range AND range indicator is enabled (match ArcAuras)
    if frame.spellOutOfRange then
        local ri = cfg.rangeIndicator
        local rangeEnabled = not ri or ri.enabled ~= false
        if rangeEnabled then
            -- Clear our desat request — range indicator owns visuals now
            frame._arcUsabilityDesatRequest = nil
            return
        end
    end

    local spellID = spellID or GetSpellIDFromFrame(frame)
    if not spellID then return end

    -- ── Priority 1: On Cooldown (all charges depleted) ──────────────
    -- Shadow CD converts secret duration into non-secret boolean.
    -- IsShown()=true → all charges depleted / full CD active.
    -- When called from hook, allDepleted is pre-computed (with GCD guard applied).
    if allDepleted == nil then
        local shadowCD = frame._arcCDMShadowCooldown
        allDepleted = shadowCD and shadowCD:IsShown() or false
    end

    -- RECHARGING: charge shadow shown but main shadow hidden (1+ charges, one recharging).
    -- CooldownState owns desat in this state too — bail out same as depleted.
    local isRecharging = false
    if not allDepleted then
        local chargeShadow = frame._arcCDMChargeShadow
        isRecharging = chargeShadow and chargeShadow:IsShown() or false
    end

    if allDepleted and su.useOnCooldownColor then
        -- CooldownState's cooldownTint takes priority (enforced via _arcDesiredVertexColor).
        -- Only set usability's on-CD color when CooldownState isn't enforcing.
        if not frame._arcDesiredVertexColor then
            local c = su.onCooldownColor or ON_CD_COLOR
            SetVertexColorBypassed(frame, iconTex, c.r or 0.4, c.g or 0.4, c.b or 0.4, c.a or 1.0)
        end
        ApplyUsabilityDesat(frame, iconTex, nil)  -- CooldownState owns desat during cooldown
        return
    elseif allDepleted then
        -- Spell is fully depleted but user hasn't enabled custom on-cooldown color.
        -- Bail out: CDM / CooldownState own desat + visuals during cooldown.
        -- Without this, C_Spell.IsSpellUsable (resource check, not CD check)
        -- returns true and the "normal/usable" path below would force desat=0,
        -- wiping CDM's native cooldown desaturation.
        ApplyUsabilityDesat(frame, iconTex, nil)  -- clear request, don't touch desat
        return
    elseif isRecharging then
        -- Charge spell has 1+ charges available but is recharging.
        -- CooldownState owns desat here too — same bail-out as depleted.
        -- Without this, isUsable=true triggers normalDesaturate path every
        -- RefreshIconColor (~3x/s), writing SetDesaturation(0) with bypass
        -- and fighting CDM's charge timer desaturation continuously.
        ApplyUsabilityDesat(frame, iconTex, nil)
        return
    end

    -- ── Priority 2: Resource / Usability checks (non-secret bools) ──
    -- These ONLY apply in READY state (not on cooldown). Follows ABE pattern:
    -- on-CD → CD tint only. Ready → usability tints.
    -- When called from hook, isUsable/notEnoughMana are pre-computed.
    if isUsable == nil then
        isUsable, notEnoughMana = C_Spell.IsSpellUsable(spellID)
    end

    if isUsable then
        -- ── Priority 3: Normal / Usable state ──────────────────────
        if su.useNormalColor then
            local c = su.normalColor or { r = 1, g = 1, b = 1 }
            SetVertexColorBypassed(frame, iconTex, c.r or 1, c.g or 1, c.b or 1, 1)
        end
        ApplyUsabilityDesat(frame, iconTex, su.normalDesaturate)
        return
    elseif notEnoughMana then
        local c = su.notEnoughResourceColor or NOT_ENOUGH_MANA
        SetVertexColorBypassed(frame, iconTex, c.r or 0.5, c.g or 0.5, c.b or 1.0, c.a or 1.0)
        ApplyUsabilityDesat(frame, iconTex, su.notEnoughResourceDesaturate)
        -- NOTE: Alpha is handled by CooldownState.ApplyReadyState which merges
        -- usability alpha into readyAlpha (single-writer pattern, no fighting).
    else
        local c = su.notUsableColor or NOT_USABLE_COLOR
        SetVertexColorBypassed(frame, iconTex, c.r or 0.4, c.g or 0.4, c.b or 0.4, c.a or 1.0)
        ApplyUsabilityDesat(frame, iconTex, su.notUsableDesaturate)
        -- NOTE: Alpha is handled by CooldownState.ApplyReadyState (single-writer).
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HOOK INSTALLER
-- Called from CDMEnhance during frame enhancement.
-- Installs RefreshIconColor hook for usability tinting.
-- ═══════════════════════════════════════════════════════════════════════════

local function near(x, y) return math.abs((x or 0) - (y or 0)) < 0.02 end

function ns.CDMSpellUsability.HookFrame(frame)
    if not frame then return end
    if frame._arcUsabilityTintHooked then return end
    if not frame.RefreshIconColor then return end
    
    -- COOLDOWN FRAMES ONLY: Aura frames don't have spell usability state
    if frame._arcViewerType == "aura" then return end

    frame._arcUsabilityTintHooked = true

    -- ── Per-button RefreshIconColor hook ──────────────────────────────
    -- Stripped down: only handles keepBright and allDepleted/isRecharging
    -- desat bail-outs. Custom tinting moved to Icon:SetVertexColor hook
    -- below which fires only on actual state transitions (~8x vs 78x/s).
    hooksecurefunc(frame, "RefreshIconColor", function(self)
        if self._arcBypassUsabilityHook then return end
        if self._arcConfig or self._arcAuraID then return end
        if self._arcViewerType == "aura" then return end

        local iconTex = self.Icon or self.icon
        if iconTex and not iconTex.SetVertexColor and iconTex.Icon then iconTex = iconTex.Icon end
        if not iconTex or not iconTex.SetVertexColor then return end

        -- ── Priority 1: CooldownState tint (custom tint color during CD) ──
        -- Set by CooldownState.Apply; overrides everything else.
        local dvc = self._arcDesiredVertexColor
        if dvc then
            SetVertexColorBypassed(self, iconTex, dvc.r, dvc.g, dvc.b, 1)
            return
        end

        local cfg = ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettingsForFrame
                    and ns.CDMEnhance.GetEffectiveIconSettingsForFrame(self)
        if not cfg then return end

        -- ── Priority 2: keepBright ──
        if cfg.keepBright then
            SetVertexColorBypassed(self, iconTex, 1, 1, 1, 1)
            if not cfg.keepBrightAllowDesat then
                ApplyUsabilityDesat(self, iconTex, false)
            end
            return
        end

        -- ── Priority 3: Spell usability custom colors ──
        local su = cfg.spellUsability
        if not su or not su.enabled then
            -- No custom colors — clear our desat request but don't touch vertex color.
            -- CDM's native color stands.
            ApplyUsabilityDesat(self, iconTex, nil)
            return
        end

        local shadowCD = self._arcCDMShadowCooldown
        local allDepleted = shadowCD and shadowCD:IsShown() or false
        if allDepleted and self.isOnGCD then allDepleted = false end

        -- On CD or recharging: CooldownState owns desat, don't apply usability color
        if allDepleted then
            -- Still apply on-cooldown custom tint if configured (and CooldownState isn't enforcing its own)
            if su.useOnCooldownColor and not self._arcDesiredVertexColor then
                local c = su.onCooldownColor or ON_CD_COLOR
                SetVertexColorBypassed(self, iconTex, c.r or 0.4, c.g or 0.4, c.b or 0.4, c.a or 1.0)
            end
            ApplyUsabilityDesat(self, iconTex, nil)
            return
        end
        local chargeShadow = self._arcCDMChargeShadow
        if chargeShadow and chargeShadow:IsShown() then
            ApplyUsabilityDesat(self, iconTex, nil)
            return
        end

        -- Read current CDM state from cached value (set by SetVertexColor detector)
        local state = self._arcCDMUsabilityState or "USABLE"
        if state == "USABLE" then
            if su.useNormalColor then
                local c = su.normalColor or { r=1, g=1, b=1 }
                SetVertexColorBypassed(self, iconTex, c.r or 1, c.g or 1, c.b or 1, 1)
            end
            ApplyUsabilityDesat(self, iconTex, su.normalDesaturate)
        elseif state == "NOT_MANA" then
            local c = su.notEnoughResourceColor or NOT_ENOUGH_MANA
            SetVertexColorBypassed(self, iconTex, c.r or 0.5, c.g or 0.5, c.b or 1.0, c.a or 1.0)
            ApplyUsabilityDesat(self, iconTex, su.notEnoughResourceDesaturate)
        elseif state == "NOT_USABLE" then
            local c = su.notUsableColor or NOT_USABLE_COLOR
            SetVertexColorBypassed(self, iconTex, c.r or 0.4, c.g or 0.4, c.b or 0.4, c.a or 1.0)
            ApplyUsabilityDesat(self, iconTex, su.notUsableDesaturate)
        end
        -- NOT_RANGE: range indicator owns the color, we don't override
    end)

    -- ── Per-frame Icon:SetVertexColor hook — state detection only ──
    -- CDM writes a known color to frame.Icon every RefreshIconColor call.
    -- We classify it to drive glow and alpha — we do NOT write colors here.
    -- Color writing moved to the RefreshIconColor hook above (single-pass, no fighting).
    local iconWidget = frame.Icon
    if iconWidget and iconWidget.SetVertexColor and not iconWidget._arcUsabilityColorHooked then
        iconWidget._arcUsabilityColorHooked = true
        local lastState = nil
        hooksecurefunc(iconWidget, "SetVertexColor", function(self, r, g, b)
            -- Skip writes made by us (SetVertexColorBypassed) to prevent re-entry
            if frame._arcBypassVertexHook then return end
            local state
            if near(r,1.0) and near(g,1.0) and near(b,1.0) then
                state = "USABLE"
            elseif near(r,0.5) and near(g,0.5) and near(b,1.0) then
                state = "NOT_MANA"
            elseif near(r,0.4) and near(g,0.4) and near(b,0.4) then
                state = "NOT_USABLE"
            elseif near(r,0.64) and near(g,0.15) and near(b,0.15) then
                state = "NOT_RANGE"
            end
            if not state then return end  -- skip non-CDM writes

            local stateChanged = (state ~= lastState)
            lastState = state
            frame._arcCDMUsabilityState = state

            -- Glow + alpha: only on actual state transitions
            if stateChanged then
                local cfg = frame._arcCfg
                if not cfg and ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettingsForFrame then
                    cfg = ns.CDMEnhance.GetEffectiveIconSettingsForFrame(frame)
                end
                if not cfg then return end
                local spellID = frame._arcCachedSpellID
                             or (frame.cooldownInfo and (frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID))

                if state ~= "NOT_RANGE" then
                    local isUsable = (state == "USABLE")
                    local shadowCD = frame._arcCDMShadowCooldown
                    local allDepleted = shadowCD and shadowCD:IsShown() or false
                    if allDepleted and frame.isOnGCD then allDepleted = false end
                    ns.CDMSpellUsability.UpdateGlow(frame, cfg, spellID, isUsable, allDepleted)
                end

                if state == "NOT_RANGE" then
                    if spellID then
                        local usable = C_Spell.IsSpellUsable(spellID)
                        if usable and ns.CooldownState and ns.CooldownState.ApplyUsabilityAlpha then
                            ns.CooldownState.ApplyUsabilityAlpha(frame, cfg)
                        end
                    end
                else
                    if ns.CooldownState and ns.CooldownState.ApplyUsabilityAlpha then
                        ns.CooldownState.ApplyUsabilityAlpha(frame, cfg)
                    end
                end
            end
        end)
    end

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

-- Usable glow overlay + raw LCG removed — ns.Glows handles everything.
-- ns.Glows uses keyed glows so ButtonGlow conflicts are impossible.

local function StopUsableGlow(frame)
    if ns.Glows then
        ns.Glows.Stop(frame, "ArcUI_UsableGlow")
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

function ns.CDMSpellUsability.UpdateGlow(frame, cfg, spellID, isUsable, allDepleted)
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

    -- Use pre-computed spellID or look it up
    spellID = spellID or GetSpellIDFromFrame(frame)

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
            -- Use pre-computed allDepleted or compute from shadow
            if allDepleted == nil then
                local shadowCD = frame._arcCDMShadowCooldown
                allDepleted = shadowCD and shadowCD:IsShown() or false
                -- GCD guard: use frame.isOnGCD — no API call needed
                if allDepleted and frame.isOnGCD then
                    allDepleted = false
                end
            end

            -- Read CDM's usability decision from cache — zero IsSpellUsable calls
            if isUsable == nil then
                local cdmState = frame._arcCDMUsabilityState
                if cdmState == "USABLE" then
                    isUsable = true
                elseif cdmState == "NOT_MANA" or cdmState == "NOT_USABLE" then
                    isUsable = false
                elseif cdmState == "NOT_RANGE" then
                    -- Out of range doesn't mean not resource-usable — check actual state
                    isUsable = spellID and C_Spell.IsSpellUsable(spellID) or false
                elseif spellID then
                    isUsable = C_Spell.IsSpellUsable(spellID)
                end
            end

            -- Glow when: has resources AND not fully on cooldown
            if isUsable and not allDepleted then
                local combatOnly = su.usableGlowCombatOnly
                shouldGlow = not combatOnly or InCombatLockdown()
            end
    end

    if shouldGlow then
        local glowSu = su or {}
        local originalType = glowSu.usableGlowType or "button"
        local glowType = originalType
        if glowType == "blizzard" then glowType = "proc" end  -- migrate old name
        if glowType == "glow" then glowType = "proc" end      -- migrate alt name
        if glowType == "default" then glowType = "proc" end   -- "default" routes through LCG proc

        -- Skip if glow already active with same type AND same visual signature.
        -- Prevents restart when UpdateGlow fires multiple times with same outcome.
        local gc = glowSu.usableGlowColor
        local sig = glowType
                 .. (gc and (gc.r or 0) .. (gc.g or 0) .. (gc.b or 0) or "")
                 .. (glowSu.usableGlowScale or 1)
                 .. (glowSu.usableGlowSpeed or 0.25)
                 .. "|s=" .. tostring(glowSu.usableGlowFrameStrata or "inherit")
                 .. "|l=" .. tostring(glowSu.usableGlowFrameLevel or "")
        if frame._arcCDMUsableGlowActive
        and frame._arcCDMUsableGlowType == glowType
        and frame._arcCDMUsableGlowSig  == sig then
            return
        end

        -- Color: nil for "default" with no user color = LCG native golden texture
        local color = nil
        if gc then
            color = {gc.r or 1, gc.g or 0.85, gc.b or 0.1, gc.a or 1}
        elseif originalType ~= "default" then
            color = {1, 0.85, 0.1, 1}
        end

        -- Apply padding offset (matches CDMEnhance behavior)
        local padding = cfg.padding or 0
        local glowOffset = -padding

        if ns.Glows then
            local glowStrata = glowSu.usableGlowFrameStrata
            ns.Glows.Start(frame, "ArcUI_UsableGlow", glowType, {
                color = color,
                lines = glowSu.usableGlowLines or 8,
                frequency = glowSu.usableGlowSpeed or 0.25,
                thickness = glowSu.usableGlowThickness or 2,
                particles = glowSu.usableGlowParticles or 4,
                scale = glowSu.usableGlowScale or 1,
                xOffset = glowOffset + (glowSu.usableGlowXOffset or 0),
                yOffset = glowOffset + (glowSu.usableGlowYOffset or 0),
                strata = (glowStrata ~= "inherit") and glowStrata or nil,
                frameLevel = glowSu.usableGlowFrameLevel,
            })
        end
        frame._arcCDMUsableGlowActive = true
        frame._arcCDMUsableGlowType   = glowType
        frame._arcCDMUsableGlowSig    = sig
    elseif frame._arcCDMUsableGlowActive then
        StopUsableGlow(frame)
        frame._arcCDMUsableGlowActive = false
        frame._arcCDMUsableGlowType = nil
        frame._arcCDMUsableGlowSig = nil
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
            frame._arcCDMUsableGlowSig = nil
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
    for cdID, entry in pairs(enhanced) do
        local frame = entry.frame
        if frame then
            ns.CDMSpellUsability.OnRefreshIconColor(frame)
            ns.CDMSpellUsability.UpdateGlow(frame)
            -- Re-run CooldownState so usability alpha gets applied
            if ns.CooldownState and ns.CooldownState.Apply then
                local cfg = ns.CDMEnhance.GetEffectiveIconSettingsForFrame
                    and ns.CDMEnhance.GetEffectiveIconSettingsForFrame(frame)
                if cfg then ns.CooldownState.Apply(frame, cfg) end
            end
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
            frame._arcCDMUsableGlowSig = nil
        end
        -- Re-evaluate
        ns.CDMSpellUsability.UpdateGlow(frame)
        ns.CDMSpellUsability.OnRefreshIconColor(frame)
        -- Re-run CooldownState so usability alpha gets applied
        if ns.CooldownState and ns.CooldownState.Apply then
            local cfg = ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettingsForFrame
                and ns.CDMEnhance.GetEffectiveIconSettingsForFrame(frame)
            if cfg then ns.CooldownState.Apply(frame, cfg) end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS PANEL STATE — CALLBACK (zero polling)
-- ═══════════════════════════════════════════════════════════════════════════

if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
    ns.CDMShared.RegisterPanelCallback("CDMSpellUsability", {
        onOpen = function() ns.CDMSpellUsability.RefreshAll() end,
        onClose = function() ns.CDMSpellUsability.RefreshAll() end,
    })
end

-- SPELL_UPDATE_USABLE: No longer needs its own event handler.
-- Blizzard's CDM calls RefreshIconColor on each affected button when this
-- event fires. Our per-button hooksecurefunc (installed in HookFrame) rides
-- that dispatch and handles tinting, glow, and alpha-on-flip per-button.
-- This eliminates the O(N) RefreshAll() that was the #1 source of stutter
-- on multi-spell-change abilities like DH Metamorphosis.

-- ── CDM usability state cache via Icon:SetVertexColor ────────────────────
-- CDM's RefreshIconColor calls IsSpellUsable then immediately writes one of
-- four known colors to frame.Icon:SetVertexColor. We hook the mixin ONCE
-- globally and classify the color into a usability state, stored on the frame.
-- The diff guard means we only fire when the state actually changes — the log
-- confirmed ~10 real transitions vs 87+ SpellUpdateUsable broadcast fires.
-- Our RefreshIconColor hook reads _arcCDMUsabilityState instead of calling
-- IsSpellUsable itself — drops IsSpellUsable from ~220/s to ~0/s.
--
-- States: "USABLE" | "NOT_MANA" | "NOT_USABLE" | "NOT_RANGE"
--
-- CDM color constants (CooldownViewer.lua):
--   ITEM_USABLE_COLOR        = (1.0, 1.0, 1.0)
--   ITEM_NOT_ENOUGH_MANA_COLOR = (0.5, 0.5, 1.0)
--   ITEM_NOT_USABLE_COLOR    = (0.4, 0.4, 0.4)
--   ITEM_NOT_IN_RANGE_COLOR  = (0.64, 0.15, 0.15)
-- Per-frame hook installed in HookFrame above — fires only on state transitions.