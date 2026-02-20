-- ===================================================================
-- ArcUI_CooldownState.lua
-- Consolidated cooldown state visual system
-- v3.2.0: Dual shadow architecture (main CD + charge recharge)
--
-- ARCHITECTURE: Owns two invisible shadow Cooldown frames per icon:
--
-- _arcCDMShadowCooldown (main CD):
--   Fed with GetSpellCooldownDuration. GCD filtered out.
--   IsShown()=true  → ALL charges depleted / full cooldown
--   IsShown()=false → ready or has charges available
--
-- _arcCDMChargeShadow (charge recharge):
--   Fed with GetSpellChargeDuration. No GCD contamination.
--   IsShown()=true  → recharge timer active
--   IsShown()=false → all charges full
--
-- WHY DUAL: CDM's native frame.Cooldown shows GCD, so
-- frame.Cooldown:IsShown() is contaminated during GCD transitions.
-- ArcAuras doesn't have this problem because it controls its own
-- Cooldown widget (feeding charge duration, which has no GCD).
-- The charge shadow gives us the same clean signal.
--
-- Feed-before-read: Both shadows fed at TOP of main dispatcher,
-- before any path reads GetBinaryCooldownState.
--
-- Usability alpha is merged INTO readyAlpha (single writer pattern),
-- matching ArcAurasCooldown.lua line 522-524.
-- ===================================================================

local ADDON, ns = ...

ns.CooldownState = ns.CooldownState or {}

-- ═══════════════════════════════════════════════════════════════════
-- SECRET-SAFE AURAINSTANCEID HELPER
-- ═══════════════════════════════════════════════════════════════════
local function HasAuraInstanceID(value)
  if ns.API and ns.API.HasAuraInstanceID then
    return ns.API.HasAuraInstanceID(value)
  end
  if value == nil then return false end
  if issecretvalue and issecretvalue(value) then return true end
  if type(value) == "number" and value == 0 then return false end
  return value ~= nil
end

-- ═══════════════════════════════════════════════════════════════════
-- DEPENDENCY REFERENCES (resolved lazily on first call)
-- ═══════════════════════════════════════════════════════════════════
local CDM
local CooldownCurves
local InitCooldownCurves
local GetSpellCooldownState
local GetEffectiveStateVisuals
local GetEffectiveReadyAlpha
local GetGlowThresholdCurve
local ShowReadyGlow
local HideReadyGlow
local SetGlowAlpha
local ShouldShowReadyGlow
local ApplyBorderDesaturation

local resolved = false

local function ResolveDependencies()
  CDM = ns.CDMEnhance
  if not CDM then return false end

  CooldownCurves              = CDM.CooldownCurves
  InitCooldownCurves          = CDM.InitCooldownCurves
  GetSpellCooldownState       = CDM.GetSpellCooldownState
  GetEffectiveStateVisuals    = CDM.GetEffectiveStateVisuals
  GetEffectiveReadyAlpha      = CDM.GetEffectiveReadyAlpha
  GetGlowThresholdCurve       = CDM.GetGlowThresholdCurve
  ShowReadyGlow               = CDM.ShowReadyGlow
  HideReadyGlow               = CDM.HideReadyGlow or function() end
  SetGlowAlpha                = CDM.SetGlowAlpha
  ShouldShowReadyGlow         = CDM.ShouldShowReadyGlow
  ApplyBorderDesaturation     = CDM.ApplyBorderDesaturation

  resolved = true
  return true
end

-- ═══════════════════════════════════════════════════════════════════
-- SMALL HELPERS
-- ═══════════════════════════════════════════════════════════════════

local function ResolveCurrentSpellID(frame, cfg)
  if frame.cooldownInfo then
    local live = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
    if live then return live end
  end
  return cfg._spellID
end

local function ResolveIconTexture(frame)
  local iconTex = frame.Icon or frame.icon
  if not iconTex then return nil end
  if not iconTex.SetDesaturated and iconTex.Icon then
    iconTex = iconTex.Icon
  end
  return iconTex
end

local function SetDesat(iconTex, value)
  if not iconTex then return end
  if iconTex.SetDesaturation then
    iconTex:SetDesaturation(value or 0)
  end
end

local function ResetDurationText(frame)
  local skip = frame._arcSwipeWaitForNoCharges
  if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
    if not skip then frame._arcCooldownText:SetIgnoreParentAlpha(false) end
  end
  if frame._arcChargeText and frame._arcChargeText.SetIgnoreParentAlpha then
    if not skip then frame._arcChargeText:SetIgnoreParentAlpha(false) end
  end
  if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
    if not skip then frame.Cooldown.Text:SetIgnoreParentAlpha(false) end
  end
  -- Reset Cooldown widget parent-alpha override (set by preserveDurationText)
  if frame.Cooldown and frame.Cooldown.SetIgnoreParentAlpha then
    frame.Cooldown:SetIgnoreParentAlpha(false)
  end
end

local function PreserveDurationText(frame)
  if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
    frame._arcCooldownText:SetIgnoreParentAlpha(true)
    frame._arcCooldownText:SetAlpha(1)
  end
  if frame._arcChargeText and frame._arcChargeText.SetIgnoreParentAlpha then
    frame._arcChargeText:SetIgnoreParentAlpha(true)
    frame._arcChargeText:SetAlpha(1)
  end
  if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
    frame.Cooldown.Text:SetIgnoreParentAlpha(true)
    frame.Cooldown.Text:SetAlpha(1)
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- DUAL SHADOW COOLDOWN FRAMES — Creation + Feeding
--
-- Owns the entire shadow lifecycle. Two invisible Cooldown frames
-- convert secret data into non-secret IsShown() booleans:
--
-- _arcCDMShadowCooldown (main CD shadow):
--   Fed with GetSpellCooldownDuration. GCD filtered.
--   IsShown()=true  → ALL charges depleted / full cooldown active
--   IsShown()=false → spell ready or has charges available
--
-- _arcCDMChargeShadow (charge recharge shadow):
--   Fed with GetSpellChargeDuration. Only for charge spells.
--   IsShown()=true  → recharge timer active (some charges used)
--   IsShown()=false → all charges full (no recharge)
--
-- EVENT-DRIVEN ARCHITECTURE (matches ArcAuras):
--   Shadows are fed from SPELL_UPDATE_COOLDOWN event hooks, not 20Hz
--   polling. OnCooldownDone on each shadow fires when the internal
--   timer expires, triggering a re-dispatch for natural cooldown-to-
--   ready transitions (e.g. between M+ pulls, out of combat).
--   Because events fire after API state has settled, there is no GCD
--   race condition — no grace period hack needed.
-- ═══════════════════════════════════════════════════════════════════

local function CreateInvisibleCooldown(frame)
  local cd = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
  cd:SetAllPoints(frame)
  cd:SetDrawSwipe(false)
  cd:SetDrawEdge(false)
  cd:SetDrawBling(false)
  cd:SetHideCountdownNumbers(true)
  cd:SetAlpha(0)  -- INVISIBLE — but IsShown() still reflects CD state
  return cd
end

local function EnsureShadowCooldown(frame)
  if not frame._arcCDMShadowCooldown then
    frame._arcCDMShadowCooldown = CreateInvisibleCooldown(frame)
    -- OnCooldownDone: shadow timer expired → cooldown finished naturally
    -- Triggers re-dispatch for cooldown-to-ready visual transition
    -- (matches ArcAuras Cooldown frame OnCooldownDone pattern)
    frame._arcCDMShadowCooldown:SetScript("OnCooldownDone", function()
      if ns.CDMEnhance and ns.CDMEnhance.OnCooldownEvent then
        ns.CDMEnhance.OnCooldownEvent(frame)
      end
    end)
  end
  if not frame._arcCDMChargeShadow then
    frame._arcCDMChargeShadow = CreateInvisibleCooldown(frame)
    -- Same pattern: charge recharge timer expired → re-dispatch
    frame._arcCDMChargeShadow:SetScript("OnCooldownDone", function()
      if ns.CDMEnhance and ns.CDMEnhance.OnCooldownEvent then
        ns.CDMEnhance.OnCooldownEvent(frame)
      end
    end)
  end
  return frame._arcCDMShadowCooldown, frame._arcCDMChargeShadow
end

-- Feed BOTH shadow frames with current spell state.
-- GCD is filtered on the main shadow. Charge shadow uses GetSpellChargeDuration
-- which never contains GCD data (Blizzard's charge path skips GCD).
--
-- EVENT-DRIVEN: Called from SPELL_UPDATE_COOLDOWN hooks and shadow
-- OnCooldownDone callbacks. API state is settled by event time, so
-- no GCD grace period is needed (that was a polling-era workaround).
local function FeedShadowCooldown(frame, spellID)
  if not spellID then return end
  local shadowCD, chargeShadow = EnsureShadowCooldown(frame)

  -- GCD filter: isOnGCD is NeverSecret per SpellSharedDocumentation
  local isOnGCD = nil
  pcall(function()
    local cdInfo = C_Spell.GetSpellCooldown(spellID)
    if cdInfo and cdInfo.isOnGCD == true then isOnGCD = true end
  end)

  -- === MAIN CD SHADOW (all charges depleted detection) ===
  if isOnGCD then
    -- During GCD: clear shadow so IsShown()=false (spell is "ready")
    shadowCD:SetCooldown(0, 0)
  else
    -- Not on GCD: feed real cooldown duration
    local durObj = nil
    pcall(function() durObj = C_Spell.GetSpellCooldownDuration(spellID) end)
    if durObj then
      shadowCD:Clear()
      pcall(function() shadowCD:SetCooldownFromDurationObject(durObj, true) end)
    else
      shadowCD:SetCooldown(0, 0)
    end
  end

  -- === CHARGE SHADOW (recharge detection) ===
  -- GetSpellChargeDuration returns a DurationObject when recharge is active.
  -- This API has NO GCD contamination — Blizzard's charge path skips GCD.
  local chargeDurObj = nil
  pcall(function() chargeDurObj = C_Spell.GetSpellChargeDuration(spellID) end)
  if chargeDurObj then
    chargeShadow:Clear()
    pcall(function() chargeShadow:SetCooldownFromDurationObject(chargeDurObj, true) end)
  else
    chargeShadow:SetCooldown(0, 0)
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- BINARY STATE DETECTION via dual shadow cooldown frames
--
-- No longer reads frame.Cooldown:IsShown() — that's CDM's native
-- widget which is contaminated by GCD display.
-- ═══════════════════════════════════════════════════════════════════
local function GetBinaryCooldownState(frame, isChargeSpell)
  local shadowCD = frame._arcCDMShadowCooldown
  local isOnCooldown = shadowCD and shadowCD:IsShown() or false

  local isRecharging = false
  if isChargeSpell and not isOnCooldown then
    -- Use charge shadow instead of frame.Cooldown (GCD-free)
    local chargeShadow = frame._arcCDMChargeShadow
    isRecharging = chargeShadow and chargeShadow:IsShown() or false
  end
  return isOnCooldown, isRecharging
end

-- Lightweight flags (no DurationObject creation)
local function GetCooldownFlags(spellID)
  if not spellID then return nil, false end
  local isOnGCD = nil
  pcall(function()
    local cdInfo = C_Spell.GetSpellCooldown(spellID)
    if cdInfo and cdInfo.isOnGCD == true then isOnGCD = true end
  end)
  local isChargeSpell = false
  pcall(function()
    isChargeSpell = C_Spell.GetSpellCharges(spellID) ~= nil
  end)
  return isOnGCD, isChargeSpell
end

-- ═══════════════════════════════════════════════════════════════════
-- USABILITY ALPHA QUERY (matches ArcAuras GetUsabilityState pattern)
-- Returns alpha override or nil. Merged into readyAlpha by caller.
-- ═══════════════════════════════════════════════════════════════════
local function GetUsabilityAlpha(frame, spellID, cfg)
  if not spellID then return nil end
  local su = cfg and cfg.spellUsability
  if not su or su.enabled == false then return nil end
  -- Only skip for range when range indicator is ENABLED (match ArcAuras)
  if frame.spellOutOfRange then
    local ri = cfg and cfg.rangeIndicator
    local rangeEnabled = not ri or ri.enabled ~= false
    if rangeEnabled then return nil end
  end

  local isUsable, notEnoughMana = C_Spell.IsSpellUsable(spellID)
  if isUsable then return nil end

  if notEnoughMana then
    return su.notEnoughResourceAlpha
  else
    return su.notUsableAlpha
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- USABILITY VERTEX COLOR (matches ArcAuras GetUsabilityColor)
-- Returns color table or nil. nil = don't override CDM's native color.
-- Only returns a color when spell is NOT usable and spellUsability is
-- enabled with custom colors. This avoids wiping CDM's native tinting.
-- ═══════════════════════════════════════════════════════════════════
local NOT_ENOUGH_MANA   = { r = 0.5, g = 0.5, b = 1.0, a = 1.0 }
local NOT_USABLE_COLOR  = { r = 0.4, g = 0.4, b = 0.4, a = 1.0 }

local function GetUsabilityVertexColor(frame, spellID, cfg)
  if not spellID then return nil end
  local su = cfg and cfg.spellUsability
  if not su or su.enabled == false then return nil end

  -- Only skip for range when range indicator is ENABLED (match ArcAuras)
  if frame.spellOutOfRange == true then
    local ri = cfg and cfg.rangeIndicator
    local rangeEnabled = not ri or ri.enabled ~= false
    if rangeEnabled then return nil end
  end

  local isUsable, notEnoughMana = C_Spell.IsSpellUsable(spellID)

  -- Usable → nil (don't override CDM's native vertex color)
  if isUsable then return nil end

  if notEnoughMana then
    return su.notEnoughResourceColor or NOT_ENOUGH_MANA
  else
    return su.notUsableColor or NOT_USABLE_COLOR
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- OPTIONS PANEL PREVIEW HELPER
-- ═══════════════════════════════════════════════════════════════════
local function PreviewClampAlpha(alpha)
  if alpha <= 0 then
    if ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
      return 0.35
    end
  end
  return alpha
end

-- ═══════════════════════════════════════════════════════════════════
-- APPLY READY STATE (binary, single writer)
-- Merges usability alpha into readyAlpha BEFORE applying.
-- Uses _lastAppliedAlpha cache to skip redundant SetAlpha calls.
-- ═══════════════════════════════════════════════════════════════════
local function ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlphaOverride)
  local effectiveReadyAlpha = GetEffectiveReadyAlpha(stateVisuals)

  -- Merge usability alpha (match ArcAuras line 522-524)
  if usabilityAlphaOverride then
    effectiveReadyAlpha = usabilityAlphaOverride
  end

  effectiveReadyAlpha = PreviewClampAlpha(effectiveReadyAlpha)

  -- Alpha: set enforcement flags
  frame._arcTargetAlpha = nil
  if effectiveReadyAlpha < 1.0 then
    frame._arcEnforceReadyAlpha = true
    frame._arcReadyAlphaValue = effectiveReadyAlpha
  else
    frame._arcEnforceReadyAlpha = false
    frame._arcReadyAlphaValue = nil
  end

  -- Apply with cache check
  if frame._lastAppliedAlpha ~= effectiveReadyAlpha then
    frame._arcBypassFrameAlphaHook = true
    frame:SetAlpha(effectiveReadyAlpha)
    frame._arcBypassFrameAlphaHook = false
    frame._lastAppliedAlpha = effectiveReadyAlpha
  end

  -- Desaturation: force colored
  frame._arcBypassDesatHook = true
  frame._arcForceDesatValue = nil
  frame._arcDesatBranch = frame._arcDesatBranch or "READY"
  SetDesat(iconTex, 0)
  frame._arcBypassDesatHook = false
  ApplyBorderDesaturation(frame, 0)

  frame:Show()
  frame._arcPreserveDurationText = false  -- Ready state: no preserve needed
  ResetDurationText(frame)
end

-- ═══════════════════════════════════════════════════════════════════
-- APPLY COOLDOWN STATE ALPHA (binary, single writer)
-- ═══════════════════════════════════════════════════════════════════
local function ApplyCooldownAlpha(frame, stateVisuals)
  local cdAlpha = stateVisuals.cooldownAlpha or 1.0
  cdAlpha = PreviewClampAlpha(cdAlpha)

  frame._arcEnforceReadyAlpha = false
  frame._arcReadyAlphaValue = nil
  frame._arcTargetAlpha = cdAlpha
  -- Cache for SetCooldown hook — gates text SetIgnoreParentAlpha
  frame._arcPreserveDurationText = stateVisuals.preserveDurationText == true

  if frame._lastAppliedAlpha ~= cdAlpha then
    frame._arcBypassFrameAlphaHook = true
    frame:SetAlpha(cdAlpha)
    frame._arcBypassFrameAlphaHook = false
    frame._lastAppliedAlpha = cdAlpha
  end

  if frame.Cooldown then
    if not stateVisuals.preserveDurationText then
      -- Normal: ensure Cooldown inherits frame alpha
      if frame.Cooldown.SetIgnoreParentAlpha then
        frame.Cooldown:SetIgnoreParentAlpha(false)
      end
    end
    -- preserveDurationText: Cooldown widget inherits frame alpha naturally
    -- (swipe/edge dim with frame). PreserveDurationText() below makes text
    -- FontStrings ignore parent alpha so they render at full opacity.
  end

  if stateVisuals.preserveDurationText then
    PreserveDurationText(frame)
  else
    ResetDurationText(frame)
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- APPLY COOLDOWN DESATURATION (binary)
-- ═══════════════════════════════════════════════════════════════════
local function ApplyCooldownDesat(frame, iconTex, stateVisuals, hasActiveAuraDisplay, isRecharging)
  if hasActiveAuraDisplay then
    frame._arcDesatBranch = "BIN_CD_AURA_ACTIVE"
    frame._arcForceDesatValue = 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 0)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, 0)
  elseif stateVisuals.noDesaturate then
    frame._arcDesatBranch = "BIN_CD_NODESAT"
    frame._arcForceDesatValue = 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 0)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, 0)
  elseif isRecharging then
    -- Recharging (not fully depleted): suppress desat (match ArcAuras line 433)
    frame._arcDesatBranch = "BIN_RECHARGE_NODESAT"
    frame._arcForceDesatValue = 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 0)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, 0)
  elseif stateVisuals.cooldownDesaturate then
    frame._arcDesatBranch = "BIN_CD_DESAT"
    frame._arcForceDesatValue = 1
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 1)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, 1)
  else
    -- cooldownDesaturate off: let CDM handle
    frame._arcDesatBranch = "BIN_CD_CDM_HANDLES"
    frame._arcForceDesatValue = nil
  end
end

-- Show/hide ready glow (binary)
local function ApplyReadyGlow(frame, stateVisuals)
  if ShouldShowReadyGlow(stateVisuals, frame) then
    ShowReadyGlow(frame, stateVisuals)
  else
    HideReadyGlow(frame)
  end
end


-- ═══════════════════════════════════════════════════════════════════
-- PATH A: Ignore Aura Override (binary)
-- Shows spell cooldown state instead of aura duration.
-- ═══════════════════════════════════════════════════════════════════
local function HandleIgnoreAuraOverride(frame, iconTex, cfg, stateVisuals)
  local spellID = ResolveCurrentSpellID(frame, cfg)
  if not spellID then
    frame._arcReadyForGlow = false
    HideReadyGlow(frame)
    return
  end

  local isOnGCD, isChargeSpell = GetCooldownFlags(spellID)
  local isOnCooldown, isRecharging = GetBinaryCooldownState(frame, isChargeSpell)

  local waitForNoCharges = isChargeSpell and stateVisuals.waitForNoCharges
  local glowWhileCharges = stateVisuals.glowWhileChargesAvailable

  -- Visual branch (match ArcAuras lines 400-407)
  local useCooldownVisuals
  if isOnCooldown then
    useCooldownVisuals = true
  elseif isChargeSpell and isRecharging then
    useCooldownVisuals = not waitForNoCharges
  else
    useCooldownVisuals = false
  end

  -- Glow eligibility (match ArcAuras lines 410-419)
  local isGlowEligible
  if isOnCooldown then
    isGlowEligible = false
  elseif isChargeSpell and isRecharging and not glowWhileCharges then
    isGlowEligible = false
  else
    isGlowEligible = true
  end

  frame:Show()

  if useCooldownVisuals then
    -- ON COOLDOWN
    frame._arcDesatBranch = "IAO_BIN_CD"
    ApplyCooldownAlpha(frame, stateVisuals)
    -- For IAO, we always drive desat ourselves (CDM is in aura mode)
    if stateVisuals.noDesaturate or isRecharging then
      frame._arcForceDesatValue = 0
      frame._arcBypassDesatHook = true
      SetDesat(iconTex, 0)
      frame._arcBypassDesatHook = false
      ApplyBorderDesaturation(frame, 0)
    else
      frame._arcForceDesatValue = 1
      frame._arcBypassDesatHook = true
      SetDesat(iconTex, 1)
      frame._arcBypassDesatHook = false
      ApplyBorderDesaturation(frame, 1)
    end
    -- Tint (custom tint → else → usability color if not usable)
    if stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
      local col = stateVisuals.cooldownTintColor
      iconTex:SetVertexColor(col.r or 0.5, col.g or 0.5, col.b or 0.5)
    else
      local uc = GetUsabilityVertexColor(frame, spellID, cfg)
      if uc then iconTex:SetVertexColor(uc.r, uc.g, uc.b, uc.a or 1) end
    end
    HideReadyGlow(frame)
  else
    -- READY (merge usability alpha)
    frame._arcDesatBranch = "IAO_BIN_READY"
    local usabilityAlpha = GetUsabilityAlpha(frame, spellID, cfg)
    ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha)
    -- Vertex color (usability tint when not usable, else CDM handles)
    local uc = GetUsabilityVertexColor(frame, spellID, cfg)
    if uc then iconTex:SetVertexColor(uc.r, uc.g, uc.b, uc.a or 1) end
    if isGlowEligible then
      ApplyReadyGlow(frame, stateVisuals)
    else
      HideReadyGlow(frame)
    end
  end

  -- noGCDSwipe: Hide swipe during GCD for normal spells only.
  -- Charge spells that are recharging are handled by CDMEnhance's
  -- SetCooldown/SetDrawSwipe hooks which properly distinguish GCD vs recharge.
  if isOnGCD and frame._arcNoGCDSwipeEnabled and frame.Cooldown then
    if not (isChargeSpell and isRecharging) then
      frame._arcBypassSwipeHook = true
      frame.Cooldown:SetDrawSwipe(false)
      frame.Cooldown:SetDrawEdge(false)
      frame._arcBypassSwipeHook = false
    end
  end
end


-- ═══════════════════════════════════════════════════════════════════
-- PATH B: Aura Logic (buffs / debuffs / totems)
-- Uses event-driven caching from OptimizedApplyIconVisuals.
-- ═══════════════════════════════════════════════════════════════════
local function HandleAuraLogic(frame, iconTex, cfg, stateVisuals)
  local isAuraActive = HasAuraInstanceID(frame.auraInstanceID) or (frame.totemData ~= nil)
  local isCooldownFrame = not cfg._isAura and frame.totemData == nil

  -- ═════════════════════════════════════════════════════════════════
  -- ALPHA
  -- ═════════════════════════════════════════════════════════════════
  if frame._arcTargetAlpha == nil then
    if isCooldownFrame then
      -- Cooldown frame: binary detection
      local cdSpellID = ResolveCurrentSpellID(frame, cfg)
      if cdSpellID then
        local isOnGCD, isChargeSpell = GetCooldownFlags(cdSpellID)
        local isOnCooldown, isRecharging = GetBinaryCooldownState(frame, isChargeSpell)
        local waitForNoCharges = isChargeSpell and stateVisuals.waitForNoCharges

        local useCooldownVisuals
        if isOnCooldown then
          useCooldownVisuals = true
        elseif isChargeSpell and isRecharging then
          useCooldownVisuals = not waitForNoCharges
        else
          useCooldownVisuals = false
        end

        if not isChargeSpell and isOnGCD then
          local usabilityAlpha = GetUsabilityAlpha(frame, cdSpellID, cfg)
          ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha)
        elseif useCooldownVisuals then
          frame:Show()
          ApplyCooldownAlpha(frame, stateVisuals)
        else
          local usabilityAlpha = GetUsabilityAlpha(frame, cdSpellID, cfg)
          ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha)
        end
      else
        ApplyReadyState(frame, iconTex, stateVisuals)
      end
    else
      -- Pure aura frame: use aura presence for alpha
      local targetAlpha
      if isAuraActive then
        local effectiveReadyAlpha = GetEffectiveReadyAlpha(stateVisuals)
        targetAlpha = effectiveReadyAlpha
        if effectiveReadyAlpha < 1.0 then
          frame._arcEnforceReadyAlpha = true
          frame._arcReadyAlphaValue = effectiveReadyAlpha
        else
          frame._arcEnforceReadyAlpha = false
        end
      else
        frame._arcEnforceReadyAlpha = false
        local cdAlpha = stateVisuals.cooldownAlpha
        targetAlpha = PreviewClampAlpha(cdAlpha)
      end

      frame._arcTargetAlpha = targetAlpha
      if frame._lastAppliedAlpha ~= targetAlpha then
        frame._arcBypassFrameAlphaHook = true
        frame:SetAlpha(targetAlpha)
        if frame.Cooldown then frame.Cooldown:SetAlpha(targetAlpha) end
        frame._arcBypassFrameAlphaHook = false
        frame._lastAppliedAlpha = targetAlpha
      end
      if not frame:IsShown() then frame:Show() end
    end
  end

  -- ═════════════════════════════════════════════════════════════════
  -- DESATURATION
  -- ═════════════════════════════════════════════════════════════════
  if frame._arcTargetDesat == nil then
    if isCooldownFrame then
      local cdSpellID = ResolveCurrentSpellID(frame, cfg)
      if cdSpellID then
        local isOnGCD, isChargeSpell = GetCooldownFlags(cdSpellID)
        local isOnCooldown, isRecharging = GetBinaryCooldownState(frame, isChargeSpell)

        if not isChargeSpell and isOnGCD then
          frame._arcDesatBranch = "AURA_CD_GCD"
          frame._arcBypassDesatHook = true
          SetDesat(iconTex, 0)
          frame._arcBypassDesatHook = false
          frame._arcTargetDesat = 0
          ApplyBorderDesaturation(frame, 0)
        elseif isOnCooldown then
          ApplyCooldownDesat(frame, iconTex, stateVisuals, false, false)
          frame._arcTargetDesat = stateVisuals.cooldownDesaturate and 1 or 0
        elseif isRecharging then
          frame._arcDesatBranch = "AURA_CD_RECHARGE"
          frame._arcBypassDesatHook = true
          SetDesat(iconTex, 0)
          frame._arcBypassDesatHook = false
          frame._arcTargetDesat = 0
          ApplyBorderDesaturation(frame, 0)
        else
          frame._arcDesatBranch = "AURA_CD_READY"
          frame._arcBypassDesatHook = true
          SetDesat(iconTex, 0)
          frame._arcBypassDesatHook = false
          frame._arcTargetDesat = 0
          ApplyBorderDesaturation(frame, 0)
        end
      else
        frame._arcDesatBranch = "AURA_CD_NO_SPELL"
        frame._arcBypassDesatHook = true
        SetDesat(iconTex, 0)
        frame._arcBypassDesatHook = false
        frame._arcTargetDesat = 0
        ApplyBorderDesaturation(frame, 0)
      end
    else
      -- Pure aura frame: aura presence
      local targetDesat
      if isAuraActive then
        frame._arcDesatBranch = "AURA_READY"
        targetDesat = 0
      else
        frame._arcDesatBranch = "AURA_CD"
        targetDesat = stateVisuals.cooldownDesaturate and 1 or 0
      end
      frame._arcBypassDesatHook = true
      SetDesat(iconTex, targetDesat)
      frame._arcBypassDesatHook = false
      frame._arcTargetDesat = targetDesat
      ApplyBorderDesaturation(frame, targetDesat)
    end
  end

  -- ═════════════════════════════════════════════════════════════════
  -- TINT
  -- ═════════════════════════════════════════════════════════════════
  if frame._arcTargetTint == nil then
    if isCooldownFrame then
      local cdSpellID = ResolveCurrentSpellID(frame, cfg)
      if cdSpellID then
        local _, isChargeSpell = GetCooldownFlags(cdSpellID)
        local isOnCooldown = GetBinaryCooldownState(frame, isChargeSpell)
        if isOnCooldown and stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
          local col = stateVisuals.cooldownTintColor
          iconTex:SetVertexColor(col.r or 0.5, col.g or 0.5, col.b or 0.5)
        else
          -- No custom tint → usability color if not usable, else CDM handles
          local uc = GetUsabilityVertexColor(frame, cdSpellID, cfg)
          if uc then iconTex:SetVertexColor(uc.r, uc.g, uc.b, uc.a or 1) end
        end
      end
      frame._arcTargetTint = true
    else
      local tR, tG, tB = 1, 1, 1
      if not isAuraActive and stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
        local col = stateVisuals.cooldownTintColor
        tR, tG, tB = col.r or 0.5, col.g or 0.5, col.b or 0.5
      end
      frame._arcTargetTint = string.format("%.2f,%.2f,%.2f", tR, tG, tB)
      if iconTex then iconTex:SetVertexColor(tR, tG, tB) end
    end
  end

  -- ═════════════════════════════════════════════════════════════════
  -- GLOW
  -- ═════════════════════════════════════════════════════════════════
  local auraID = frame.auraInstanceID
  if isCooldownFrame or frame._arcTargetGlow == nil then
    if isCooldownFrame then
      -- Binary glow
      local glowSpellID = ResolveCurrentSpellID(frame, cfg)
      if glowSpellID then
        local _, glowIsCharge = GetCooldownFlags(glowSpellID)
        local glowOnCD, glowRecharging = GetBinaryCooldownState(frame, glowIsCharge)
        local glowWhileCharges = stateVisuals.glowWhileChargesAvailable

        local glowEligible = true
        if glowOnCD then
          glowEligible = false
        elseif glowIsCharge and glowRecharging and not glowWhileCharges then
          glowEligible = false
        end

        if glowEligible and ShouldShowReadyGlow(stateVisuals, frame) then
          ShowReadyGlow(frame, stateVisuals)
        else
          HideReadyGlow(frame)
        end
      else
        ApplyReadyGlow(frame, stateVisuals)
      end
      -- Do NOT cache _arcTargetGlow for cooldown frames
    elseif ShouldShowReadyGlow(stateVisuals, frame) and isAuraActive then
      local threshold = stateVisuals.glowThreshold or 1.0

      if threshold < 1.0 and auraID then
        -- Threshold glow uses aura DurationObject (NOT cooldown — this is fine)
        local auraType = stateVisuals.glowAuraType or "auto"
        local unit = "player"
        if auraType == "debuff" then
          unit = "target"
        elseif auraType == "auto" then
          local cat = frame.category
          if cat == 3 then unit = "target" end
        end

        InitCooldownCurves()
        local auraDurObj = C_UnitAuras and C_UnitAuras.GetAuraDuration
                           and C_UnitAuras.GetAuraDuration(unit, auraID)
        if auraDurObj then
          local thresholdCurve = GetGlowThresholdCurve(threshold)
          if thresholdCurve then
            local ok, glowAlpha = pcall(function()
              return auraDurObj:EvaluateRemainingPercent(thresholdCurve)
            end)
            if ok and glowAlpha ~= nil then
              SetGlowAlpha(frame, glowAlpha, stateVisuals)
            else
              ShowReadyGlow(frame, stateVisuals)
            end
          else
            ShowReadyGlow(frame, stateVisuals)
          end
        else
          ShowReadyGlow(frame, stateVisuals)
        end
      else
        ShowReadyGlow(frame, stateVisuals)
      end
      frame._arcTargetGlow = true
    else
      HideReadyGlow(frame)
      frame._arcTargetGlow = true
    end
  end
end


-- ═══════════════════════════════════════════════════════════════════
-- PATH C: Cooldown Logic — BINARY (matches ArcAuras pattern)
-- ═══════════════════════════════════════════════════════════════════
local function HandleCooldownLogic(frame, iconTex, cfg, stateVisuals)
  local spellID = ResolveCurrentSpellID(frame, cfg)

  if not spellID then
    frame._arcDesatBranch = "C1_NO_SPELL"
    ApplyReadyState(frame, iconTex, stateVisuals)
    ApplyReadyGlow(frame, stateVisuals)
    return
  end

  local isOnGCD, isChargeSpell = GetCooldownFlags(spellID)
  local isOnCooldown, isRecharging = GetBinaryCooldownState(frame, isChargeSpell)

  local waitForNoCharges = isChargeSpell and stateVisuals.waitForNoCharges
  local glowWhileCharges = stateVisuals.glowWhileChargesAvailable

  -- Visual branch (match ArcAuras lines 400-407)
  local useCooldownVisuals
  if isOnCooldown then
    useCooldownVisuals = true
  elseif isChargeSpell and isRecharging then
    useCooldownVisuals = not waitForNoCharges
  else
    useCooldownVisuals = false
  end

  -- Glow eligibility (match ArcAuras lines 410-419)
  local isGlowEligible
  if isOnCooldown then
    isGlowEligible = false
  elseif isChargeSpell and isRecharging and not glowWhileCharges then
    isGlowEligible = false
  else
    isGlowEligible = true
  end

  -- Check active aura display for desat skip
  local cfgHasIgnoreAura = (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
                        or (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)
  local hasActiveAuraDisplay = not cfgHasIgnoreAura
                               and ((frame.wasSetFromAura == true)
                                    or (frame.totemData ~= nil))

  frame:Show()

  if useCooldownVisuals then
    -- ═══════════════════════════════════════════════════════════════
    -- ON COOLDOWN (match ArcAuras lines 423-496)
    -- ═══════════════════════════════════════════════════════════════
    frame._arcDesatBranch = "C_BIN_CD"
    ApplyCooldownAlpha(frame, stateVisuals)
    ApplyCooldownDesat(frame, iconTex, stateVisuals, hasActiveAuraDisplay, isRecharging)
    -- Tint (custom tint → else → usability color if not usable)
    if stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
      local col = stateVisuals.cooldownTintColor
      iconTex:SetVertexColor(col.r or 0.5, col.g or 0.5, col.b or 0.5)
    else
      local uc = GetUsabilityVertexColor(frame, spellID, cfg)
      if uc then iconTex:SetVertexColor(uc.r, uc.g, uc.b, uc.a or 1) end
    end
    HideReadyGlow(frame)
  else
    -- ═══════════════════════════════════════════════════════════════
    -- READY (match ArcAuras lines 498-558)
    -- Merge usability alpha into readyAlpha — single writer
    -- ═══════════════════════════════════════════════════════════════
    frame._arcDesatBranch = "C_BIN_READY"
    local usabilityAlpha = GetUsabilityAlpha(frame, spellID, cfg)
    ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha)
    -- Vertex color (usability tint when not usable, else CDM handles)
    local uc = GetUsabilityVertexColor(frame, spellID, cfg)
    if uc then iconTex:SetVertexColor(uc.r, uc.g, uc.b, uc.a or 1) end

    if isGlowEligible then
      ApplyReadyGlow(frame, stateVisuals)
    else
      HideReadyGlow(frame)
    end
  end

  -- noGCDSwipe: Hide swipe during GCD for normal spells only.
  -- Charge spells that are recharging are handled by CDMEnhance's
  -- SetCooldown/SetDrawSwipe hooks which properly distinguish GCD vs recharge.
  if isOnGCD and frame._arcNoGCDSwipeEnabled and frame.Cooldown then
    if not (isChargeSpell and isRecharging) then
      frame._arcBypassSwipeHook = true
      frame.Cooldown:SetDrawSwipe(false)
      frame.Cooldown:SetDrawEdge(false)
      frame._arcBypassSwipeHook = false
    end
  end
end


-- ═══════════════════════════════════════════════════════════════════
-- MAIN DISPATCHER
-- ═══════════════════════════════════════════════════════════════════
local function NewApplyCooldownStateVisuals(frame, cfg, normalAlpha, stateVisuals)
  if not frame then return end

  if not resolved then
    if not ResolveDependencies() then return end
  end

  if frame._arcConfig or frame._arcAuraID then return end

  local iconTex = ResolveIconTexture(frame)
  if not iconTex then return end

  -- ═════════════════════════════════════════════════════════════════
  -- FEED SHADOW BEFORE ANY STATE READS (fixes feed-before-read bug)
  -- Shadow must reflect current spell state before GetBinaryCooldownState
  -- is called by ANY path below (IAO, Aura, Cooldown, or early-out).
  -- ═════════════════════════════════════════════════════════════════
  local frameSpellID = ResolveCurrentSpellID(frame, cfg)
  if frameSpellID and not cfg._isAura then
    FeedShadowCooldown(frame, frameSpellID)
  end

  if not stateVisuals then
    stateVisuals = GetEffectiveStateVisuals(cfg)
  end

  local cdID = frame.cooldownID
  local isGlowPreview = cdID and ns.CDMEnhanceOptions
                        and ns.CDMEnhanceOptions.IsGlowPreviewActive
                        and ns.CDMEnhanceOptions.IsGlowPreviewActive(cdID)

  local ignoreAuraOverride = (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
                          or (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)

  -- No state visuals + no preview + no ignoreAuraOverride → let CDM handle
  if not stateVisuals and not isGlowPreview and not ignoreAuraOverride then
    local prevBranch = frame._arcDesatBranch
    local wasManagedDesat = prevBranch ~= nil and prevBranch ~= "NO_SV_EARLY"

    frame._arcForceDesatValue = nil
    frame._arcReadyForGlow = false
    frame._arcDesatBranch = "NO_SV_EARLY"
    HideReadyGlow(frame)

    if wasManagedDesat then
      SetDesat(iconTex, 0)
      iconTex:SetVertexColor(1, 1, 1)
      ApplyBorderDesaturation(frame, 0)
    end
    return
  end

  -- Build default stateVisuals if needed
  if not stateVisuals then
    local rs = cfg.cooldownStateVisuals and cfg.cooldownStateVisuals.readyState or {}
    stateVisuals = {
      readyAlpha          = 1.0,
      readyGlow           = isGlowPreview and true or (rs.glow == true),
      readyGlowType       = rs.glowType or "button",
      readyGlowColor      = rs.glowColor,
      readyGlowIntensity  = rs.glowIntensity or 1.0,
      readyGlowScale      = rs.glowScale or 1.0,
      readyGlowSpeed      = rs.glowSpeed or 0.25,
      readyGlowLines      = rs.glowLines or 8,
      readyGlowThickness  = rs.glowThickness or 2,
      readyGlowParticles  = rs.glowParticles or 4,
      readyGlowXOffset    = rs.glowXOffset or 0,
      readyGlowYOffset    = rs.glowYOffset or 0,
      cooldownAlpha       = 1.0,
    }
  end

  if isGlowPreview then
    ShowReadyGlow(frame, stateVisuals)
    return
  end

  -- Detect icon type
  local useAuraLogic = cfg._isAura or false
  if not useAuraLogic then
    if frame.totemData ~= nil then
      useAuraLogic = true
    elseif frame.wasSetFromAura == true then
      useAuraLogic = true
    end
  end

  -- ═════════════════════════════════════════════════════════════════
  -- DISPATCH
  -- ═════════════════════════════════════════════════════════════════
  if ignoreAuraOverride then
    local cooldownInfo = frame.cooldownInfo
    local cdmExplicitlyTrackingCooldown = (frame.wasSetFromCooldown == true and frame.wasSetFromAura ~= true)
    local cdmWouldShowAura = cfg._isAura
                             or (frame.totemData ~= nil)
                             or (frame.wasSetFromAura == true)
                             or (not cdmExplicitlyTrackingCooldown
                                 and cooldownInfo
                                 and (cooldownInfo.hasAura == true or cooldownInfo.selfAura == true))
    if cdmWouldShowAura then
      frame._arcDesatBranch = "DISPATCH_IAO"
      frame._arcIgnoreAuraOverride = true
      HandleIgnoreAuraOverride(frame, iconTex, cfg, stateVisuals)
    elseif useAuraLogic then
      frame._arcDesatBranch = "DISPATCH_AURA"
      frame._arcIgnoreAuraOverride = false
      HandleAuraLogic(frame, iconTex, cfg, stateVisuals)
    else
      frame._arcDesatBranch = "DISPATCH_CD"
      frame._arcIgnoreAuraOverride = false
      HandleCooldownLogic(frame, iconTex, cfg, stateVisuals)
    end
  elseif useAuraLogic then
    frame._arcDesatBranch = "DISPATCH_AURA"
    frame._arcIgnoreAuraOverride = false
    HandleAuraLogic(frame, iconTex, cfg, stateVisuals)
  else
    frame._arcDesatBranch = "DISPATCH_CD"
    frame._arcIgnoreAuraOverride = false
    HandleCooldownLogic(frame, iconTex, cfg, stateVisuals)
  end
end


-- ═══════════════════════════════════════════════════════════════════
-- INSTALL
-- ═══════════════════════════════════════════════════════════════════
ns.CDMEnhance.ApplyCooldownStateVisuals = NewApplyCooldownStateVisuals

ns.CooldownState.Apply              = NewApplyCooldownStateVisuals
ns.CooldownState.ApplyReadyState    = ApplyReadyState
ns.CooldownState.ApplyReadyGlow     = ApplyReadyGlow
ns.CooldownState.ResolveIconTexture = ResolveIconTexture

-- Exported for CDMEnhance early-out path (no stateVisuals configured)
-- and SpellUsability.HookFrame (creates shadow during frame enhancement)
function ns.CooldownState.FeedShadow(frame, cfg)
  if not frame then return end
  if frame._arcConfig or frame._arcAuraID then return end
  local spellID
  if frame.cooldownInfo then
    spellID = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
  end
  if not spellID and cfg then spellID = cfg._spellID end
  if spellID then
    FeedShadowCooldown(frame, spellID)
  end
end

function ns.CooldownState.EnsureShadow(frame)
  if not frame then return end
  EnsureShadowCooldown(frame)
end


-- ═══════════════════════════════════════════════════════════════════
-- LEGACY: DurationObject curve functions (commented out)
-- Kept for reference. Re-enable if Blizzard patches shadow frame.
-- Could also be used for future cooldown glow threshold % feature.
-- ═══════════════════════════════════════════════════════════════════

--[[ CURVE-BASED ALPHA
local function ApplyCurveAlpha(frame, durObj, stateVisuals, isChargeSpell)
  frame._arcEnforceReadyAlpha = false
  frame._arcReadyAlphaValue = nil
  local effectiveReadyAlpha = GetEffectiveReadyAlpha(stateVisuals)
  local alphaCurve = GetTwoStateAlphaCurve(effectiveReadyAlpha, stateVisuals.cooldownAlpha)
  if alphaCurve and durObj then
    local ok, alphaResult = pcall(function()
      return durObj:EvaluateRemainingPercent(alphaCurve)
    end)
    if ok and alphaResult ~= nil then
      frame._arcTargetAlpha = alphaResult
      frame._arcBypassFrameAlphaHook = true
      frame:SetAlpha(alphaResult)
      frame._arcBypassFrameAlphaHook = false
      if frame.Cooldown then
        if stateVisuals.preserveDurationText then
          frame.Cooldown:SetAlpha(1)
        else
          frame.Cooldown:SetAlpha(alphaResult)
        end
      end
      if stateVisuals.preserveDurationText then PreserveDurationText(frame)
      else ResetDurationText(frame) end
      return true
    end
  end
  local fallbackAlpha = stateVisuals.cooldownAlpha
  frame._arcTargetAlpha = fallbackAlpha
  frame._arcBypassFrameAlphaHook = true
  frame:SetAlpha(fallbackAlpha)
  frame._arcBypassFrameAlphaHook = false
  return false
end
--]]

--[[ CURVE-BASED DESAT
local function ApplyCurveDesat(frame, iconTex, durObj, stateVisuals)
  if stateVisuals.noDesaturate then
    SetDesat(iconTex, 0); return true
  end
  if not stateVisuals.cooldownDesaturate then return true end
  if durObj and CooldownCurves and CooldownCurves.Binary then
    local ok, desatResult = pcall(function()
      return durObj:EvaluateRemainingPercent(CooldownCurves.Binary)
    end)
    if ok and desatResult ~= nil then
      SetDesat(iconTex, desatResult); return true
    end
  end
  SetDesat(iconTex, 1); return false
end
--]]

--[[ CURVE-BASED GLOW (for future cooldown glow threshold %)
local function ApplyGlow(frame, stateVisuals, effectiveDurObj, isChargeSpell, durationObj, chargeDurObj, isOnGCD)
  if not ShouldShowReadyGlow(stateVisuals, frame) then HideReadyGlow(frame); return end
  if not CooldownCurves or not CooldownCurves.BinaryInv then HideReadyGlow(frame); return end
  local glowDurObj = effectiveDurObj
  if isChargeSpell and stateVisuals.glowWhileChargesAvailable then
    glowDurObj = durationObj
    if isOnGCD then SetGlowAlpha(frame, 1.0, stateVisuals); return end
  end
  if glowDurObj then
    local ok, glowAlpha = pcall(function()
      return glowDurObj:EvaluateRemainingPercent(CooldownCurves.BinaryInv)
    end)
    if ok and glowAlpha ~= nil then SetGlowAlpha(frame, glowAlpha, stateVisuals); return end
  end
  HideReadyGlow(frame)
end
--]]