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

-- Bypass keepBright hook when CooldownState writes vertex color.
-- Stores desired color on frame so enforcement hooks (keepBright,
-- SpellUsability.OnRefreshIconColor) can restore it when CDM or
-- SPELL_UPDATE_USABLE overwrites. Same pattern as _arcTargetAlpha.
local function SetVertexColorSafe(frame, iconTex, r, g, b, a)
  if not iconTex then return end
  frame._arcDesiredVertexColor = { r = r, g = g, b = b }
  frame._arcBypassVertexHook = true
  iconTex:SetVertexColor(r, g, b, a or 1)
  frame._arcBypassVertexHook = false
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

-- Forward declaration (defined below EnsureShadowCooldown, but referenced in event handler)
local FeedShadowCooldown

local function EnsureShadowCooldown(frame)
  if not frame._arcCDMShadowCooldown then
    frame._arcCDMShadowCooldown = CreateInvisibleCooldown(frame)

    -- ── Shadow dispatch: reads IsShown() → runs full visual update ──
    -- Matches ArcAuras desatCooldown hooks (ArcUI_ArcAuras.lua:751-790).
    -- Shadows PUSH visual updates — hooksecurefunc only feeds + enforces.
    local function ShadowDispatch()
      if frame._arcFeedingShadow then return end
      local cachedCfg = frame._arcCfg
      if not cachedCfg then return end
      -- Mark dispatched so OnCooldownEvent lightweight path runs (glow, labels)
      ns.CDMEnhance.ApplyCooldownStateVisuals(frame, cachedCfg)
      -- Glow + labels (relay wrapper handles these but be explicit)
      if ns.CDMSpellUsability and ns.CDMSpellUsability.UpdateGlow then
        ns.CDMSpellUsability.UpdateGlow(frame, cachedCfg)
      end
      if frame._arcCLHasText and ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
        ns.CustomLabel.UpdateVisibility(frame)
      end
    end

    -- Hook SetCooldown: fires when shadow set to (0,0) = spell ready
    -- Matches ArcAuras hooksecurefunc(desatCooldown, "SetCooldown", ...)
    hooksecurefunc(frame._arcCDMShadowCooldown, "SetCooldown", ShadowDispatch)

    -- Hook SetCooldownFromDurationObject: fires when real CD fed
    -- Matches ArcAuras hooksecurefunc(desatCooldown, "SetCooldownFromDurationObject", ...)
    hooksecurefunc(frame._arcCDMShadowCooldown, "SetCooldownFromDurationObject", ShadowDispatch)

    -- Hook OnCooldownDone: natural timer expiry (between pulls, out of combat)
    -- HookScript preserves CooldownFrameTemplate's internal handler.
    frame._arcCDMShadowCooldown:HookScript("OnCooldownDone", ShadowDispatch)
  end

  if not frame._arcCDMChargeShadow then
    frame._arcCDMChargeShadow = CreateInvisibleCooldown(frame)

    local function ChargeShadowDispatch()
      if frame._arcFeedingShadow then return end
      local cachedCfg = frame._arcCfg
      if not cachedCfg then return end
      ns.CDMEnhance.ApplyCooldownStateVisuals(frame, cachedCfg)
      if ns.CDMSpellUsability and ns.CDMSpellUsability.UpdateGlow then
        ns.CDMSpellUsability.UpdateGlow(frame, cachedCfg)
      end
      if frame._arcCLHasText and ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
        ns.CustomLabel.UpdateVisibility(frame)
      end
    end

    hooksecurefunc(frame._arcCDMChargeShadow, "SetCooldown", ChargeShadowDispatch)
    hooksecurefunc(frame._arcCDMChargeShadow, "SetCooldownFromDurationObject", ChargeShadowDispatch)
    frame._arcCDMChargeShadow:HookScript("OnCooldownDone", ChargeShadowDispatch)
  end

  -- ═══════════════════════════════════════════════════════════════════
  -- CHARGE EVENT HANDLER
  --
  -- SPELL_UPDATE_CHARGES: CDM may not always fire OnSpellUpdateCooldownEvent
  -- for charge changes. This handler caches isOnGCD + feeds shadows.
  -- Shadow hooks handle the dispatch automatically.
  -- ═══════════════════════════════════════════════════════════════════
  if not frame._arcShadowEventFrame then
    local ef = CreateFrame("Frame")
    ef._arcParent = frame
    ef:RegisterEvent("SPELL_UPDATE_CHARGES")
    ef:SetScript("OnEvent", function(self)
      local pf = self._arcParent
      if not pf then return end
      if pf._arcConfig or pf._arcAuraID then return end
      local ci = pf.cooldownInfo
      local spellID = ci and (ci.overrideSpellID or ci.spellID)
      if spellID then
        -- Cache isOnGCD with transition guard
        local newIsOnGCD = nil
        pcall(function()
          local cdInfo = C_Spell.GetSpellCooldown(spellID)
          if cdInfo then newIsOnGCD = cdInfo.isOnGCD end
        end)
        local isGCDTransition = pf._arcCachedIsOnGCD and not newIsOnGCD
        if not isGCDTransition then
          pf._arcCachedIsOnGCD = newIsOnGCD
        end
        -- Feed shadows → hooks fire → dispatch happens automatically
        FeedShadowCooldown(pf, spellID)
        -- Clear GCD cache after transition guard
        if isGCDTransition then
          pf._arcCachedIsOnGCD = nil
        end
        -- ACTIVE ENFORCEMENT: correct CDM's stale swipe/edge
        local cd = pf.Cooldown
        if cd then
          local desiredSwipe = pf._arcDesiredSwipe
          local desiredEdge  = pf._arcDesiredEdge
          if desiredSwipe ~= nil then cd:SetDrawSwipe(desiredSwipe) end
          if desiredEdge ~= nil then cd:SetDrawEdge(desiredEdge) end
        end
      end
    end)
    frame._arcShadowEventFrame = ef
  end

  return frame._arcCDMShadowCooldown, frame._arcCDMChargeShadow
end

-- Feed BOTH shadow frames with current spell state.
-- GCD is filtered on the main shadow. Charge shadow uses GetSpellChargeDuration
-- which never contains GCD data (Blizzard's charge path skips GCD).
--
-- EVENT-DRIVEN: Called ONLY from the per-frame SPELL_UPDATE_COOLDOWN
-- event handler. Uses cached isOnGCD set by the event handler before
-- this function is called (matches ArcAuras line 1621 → 739 pattern).
-- NO live API query — pure cache, zero polling, zero extra CPU.
FeedShadowCooldown = function(frame, spellID)
  if not spellID then return end
  local shadowCD, chargeShadow = EnsureShadowCooldown(frame)

  -- GCD filter: read cached isOnGCD (set by event frame before calling us)
  local isOnGCD = frame._arcCachedIsOnGCD == true

  -- === MAIN CD SHADOW (all charges depleted detection) ===
  if isOnGCD then
    -- During GCD: clear shadow so IsShown()=false (spell is "ready")
    -- SetCooldown hook fires → dispatch with ready state
    shadowCD:SetCooldown(0, 0)
  else
    -- Not on GCD: feed real cooldown duration
    local durObj = nil
    pcall(function() durObj = C_Spell.GetSpellCooldownDuration(spellID) end)
    if durObj then
      -- Guard ONLY Clear() to prevent intermediate state dispatch
      -- (Clear fires OnCooldownDone + SetCooldown hooks with wrong state)
      frame._arcFeedingShadow = true
      shadowCD:Clear()
      frame._arcFeedingShadow = nil
      -- SetCooldownFromDurationObject hook fires → dispatch with correct state
      pcall(function() shadowCD:SetCooldownFromDurationObject(durObj, true) end)
    else
      shadowCD:SetCooldown(0, 0)
    end
  end

  -- === CHARGE SHADOW (recharge detection) ===
  local chargeDurObj = nil
  pcall(function() chargeDurObj = C_Spell.GetSpellChargeDuration(spellID) end)
  if chargeDurObj then
    frame._arcFeedingShadow = true
    chargeShadow:Clear()
    frame._arcFeedingShadow = nil
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

-- ═══════════════════════════════════════════════════════════════════
-- READ COOLDOWN STATE (read-only, ArcAuras pattern)
--
-- Reads state from already-fed shadow frames. NEVER feeds.
-- Shadows are fed at the event level (PreDispatch / CHARGES handler),
-- and their hooks push the dispatch. This function only reads.
-- Eliminates recursion: hook → dispatch → handler → read (no feed).
-- ═══════════════════════════════════════════════════════════════════
local function ReadCooldownState(frame, spellID)
  -- isChargeSpell: frame cache avoids pcall on repeat calls
  local isChargeSpell = false
  if frame._arcIsChargeSpell == spellID then
    isChargeSpell = true
  else
    pcall(function() isChargeSpell = C_Spell.GetSpellCharges(spellID) ~= nil end)
    if isChargeSpell then frame._arcIsChargeSpell = spellID end
  end

  -- Read state from shadows (already fed by event handler or naturally expired)
  local isOnCooldown, isRecharging = GetBinaryCooldownState(frame, isChargeSpell)

  -- isOnGCD from cache (set by PreDispatch in event context, nil for batch paths)
  local isOnGCD = frame._arcCachedIsOnGCD == true

  return isOnCooldown, isRecharging, isChargeSpell, isOnGCD
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
local ON_CD_COLOR_CS    = { r = 0.4, g = 0.4, b = 0.4, a = 1.0 }

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

  -- Priority 1: On Cooldown (shadow CD depleted) with custom color
  if su.useOnCooldownColor then
    local shadowCD = frame._arcCDMShadowCooldown
    if shadowCD and shadowCD:IsShown() then
      return su.onCooldownColor or ON_CD_COLOR_CS
    end
  end

  -- Priority 2: Resource / usability checks (non-secret)
  local isUsable, notEnoughMana = C_Spell.IsSpellUsable(spellID)

  if isUsable then
    -- Priority 3: Normal state custom color
    if su.useNormalColor and su.normalColor then
      return su.normalColor
    end
    return nil  -- don't override CDM's native vertex color
  end

  if notEnoughMana then
    return su.notEnoughResourceColor or NOT_ENOUGH_MANA
  else
    return su.notUsableColor or NOT_USABLE_COLOR
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- USABILITY DESATURATION (matches vertex color priority chain)
-- Returns true/false/nil. nil = no override.
-- ═══════════════════════════════════════════════════════════════════
local function GetUsabilityDesaturation(frame, spellID, cfg)
  if not spellID then return nil end
  local su = cfg and cfg.spellUsability
  if not su or su.enabled == false then return nil end

  if frame.spellOutOfRange == true then
    local ri = cfg and cfg.rangeIndicator
    local rangeEnabled = not ri or ri.enabled ~= false
    if rangeEnabled then return nil end
  end

  -- On Cooldown desat
  if su.onCooldownDesaturate then
    local shadowCD = frame._arcCDMShadowCooldown
    if shadowCD and shadowCD:IsShown() then return true end
  end

  local isUsable, notEnoughMana = C_Spell.IsSpellUsable(spellID)

  if isUsable then
    return su.normalDesaturate and true or nil
  elseif notEnoughMana then
    return su.notEnoughResourceDesaturate and true or nil
  else
    return su.notUsableDesaturate and true or nil
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

  -- Desaturation: release icon control (CDM clears desat natively when ready).
  -- Sync border to 0 (CDM doesn't handle border desat).
  frame._arcDesatBranch = frame._arcDesatBranch or "READY"
  frame._arcForceDesatValue = nil
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
    -- Aura is showing on this cooldown frame → suppress cooldown desat
    -- CDM doesn't know we want bright during aura display
    frame._arcDesatBranch = "BIN_CD_AURA_ACTIVE"
    frame._arcForceDesatValue = 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 0)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, 0)
  elseif stateVisuals.noDesaturate then
    -- User explicitly wants NO desat → override CDM's native desat
    frame._arcDesatBranch = "BIN_CD_NODESAT"
    frame._arcForceDesatValue = 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 0)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, 0)
  elseif isRecharging then
    -- Recharging with charges available → suppress desat (ArcAuras line 433)
    -- CDM would desat but we want bright when charges exist
    frame._arcDesatBranch = "BIN_RECHARGE_NODESAT"
    frame._arcForceDesatValue = 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 0)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, 0)
  else
    -- CDM handles icon desat natively (cooldown → desat, ready → bright).
    -- Release icon control. Sync border from shadow state (CDM doesn't do border).
    frame._arcDesatBranch = "BIN_CD_NATIVE"
    frame._arcForceDesatValue = nil
    local shadowCD = frame._arcCDMShadowCooldown
    local borderDesat = (shadowCD and shadowCD:IsShown()) and 1 or 0
    ApplyBorderDesaturation(frame, borderDesat)
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
    -- Can't resolve spell — clear our state and let CDM handle natively
    frame._arcReadyForGlow = false
    frame._arcForceDesatValue = nil
    frame._arcEnforceReadyAlpha = false
    frame._arcReadyAlphaValue = nil
    frame._arcTargetAlpha = nil
    frame._arcDesiredSwipe = nil
    frame._arcDesiredEdge = nil
    frame._arcDesiredVertexColor = nil
    HideReadyGlow(frame)
    return
  end

  -- Single operation: feed shadow → read state (ArcAuras pattern)
  local isOnCooldown, isRecharging, isChargeSpell, isOnGCD = ReadCooldownState(frame, spellID)

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
    -- Tint: ONLY custom cooldownTint during cooldown (ABE pattern)
    if stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
      local col = stateVisuals.cooldownTintColor
      SetVertexColorSafe(frame, iconTex, col.r or 0.5, col.g or 0.5, col.b or 0.5)
    else
      frame._arcDesiredVertexColor = nil  -- release enforcement
    end
    if isGlowEligible then
      ApplyReadyGlow(frame, stateVisuals)
    else
      HideReadyGlow(frame)
    end
  else
    -- READY (merge usability alpha)
    frame._arcDesatBranch = "IAO_BIN_READY"
    local usabilityAlpha = GetUsabilityAlpha(frame, spellID, cfg)
    ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha)
    -- IAO: force desat=0 because CDM thinks this is an aura frame
    -- and might desat based on aura state, not cooldown state.
    frame._arcForceDesatValue = 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 0)
    frame._arcBypassDesatHook = false
    -- Release vertex color enforcement — SpellUsability handles it
    frame._arcDesiredVertexColor = nil
    if isGlowEligible then
      ApplyReadyGlow(frame, stateVisuals)
    else
      HideReadyGlow(frame)
    end
  end

  -- ═══════════════════════════════════════════════════════════════
  -- UNIFIED SWIPE/EDGE DECISION (mirrors ArcAuras FeedCooldown pattern)
  -- CooldownState is the SOLE authority for swipe/edge when it runs.
  -- Shadow-driven: isOnCooldown/isRecharging are GCD-filtered.
  -- Stores desired state for enforcing hooks to hold against CDM.
  -- ═══════════════════════════════════════════════════════════════
  if frame.Cooldown then
    local swipeCfg = cfg.cooldownSwipe
    local userWantsSwipe = not swipeCfg or swipeCfg.showSwipe ~= false
    local userWantsEdge  = not swipeCfg or swipeCfg.showEdge  ~= false
    local wantSwipe, wantEdge

    if isChargeSpell then
      -- Read from cfg (stable) instead of frame properties (may be stale/cleared by CDM)
      local swipeWait = swipeCfg and swipeCfg.swipeWaitForNoCharges
      local edgeWait  = swipeCfg and swipeCfg.edgeWaitForNoCharges

      if isOnCooldown then
        -- All charges depleted → show swipe/edge per user pref
        wantSwipe = userWantsSwipe
        wantEdge  = userWantsEdge
      elseif isRecharging then
        -- Recharging with charges available → respect wait flags
        wantSwipe = userWantsSwipe and not swipeWait
        wantEdge  = userWantsEdge and not edgeWait
      else
        -- Fully ready — no cooldown running, nothing to show
        wantSwipe = false
        wantEdge  = false
      end
    else
      -- Normal spell: shadow is GCD-filtered, so isOnCooldown=false during GCD-only.
      -- This naturally implements noGCDSwipe when CooldownState is running.
      if isOnCooldown then
        wantSwipe = userWantsSwipe
        wantEdge  = userWantsEdge
      else
        wantSwipe = false
        wantEdge  = false
      end
    end

    -- Store for enforcing hooks and apply
    frame._arcDesiredSwipe = wantSwipe
    frame._arcDesiredEdge  = wantEdge
    frame._arcBypassSwipeHook = true
    frame.Cooldown:SetDrawSwipe(wantSwipe)
    frame.Cooldown:SetDrawEdge(wantEdge)
    frame._arcBypassSwipeHook = false
  end
end


-- ═══════════════════════════════════════════════════════════════════
-- PATH B: Aura Logic (buffs / debuffs / totems)
-- Uses event-driven caching from OptimizedApplyIconVisuals.
-- ═══════════════════════════════════════════════════════════════════
local function HandleAuraLogic(frame, iconTex, cfg, stateVisuals)
  local isAuraActive = HasAuraInstanceID(frame.auraInstanceID) or (frame.totemData ~= nil)
  local isCooldownFrame = not cfg._isAura and frame.totemData == nil

  -- Pre-compute cooldown state ONCE for cooldown frames (avoids 4x redundant queries)
  local cdSpellID, cdOnCooldown, cdRecharging, cdIsCharge, cdIsOnGCD
  if isCooldownFrame then
    cdSpellID = ResolveCurrentSpellID(frame, cfg)
    if cdSpellID then
      cdOnCooldown, cdRecharging, cdIsCharge, cdIsOnGCD = ReadCooldownState(frame, cdSpellID)
    end
  end

  -- ═════════════════════════════════════════════════════════════════
  -- ALPHA
  -- ═════════════════════════════════════════════════════════════════
  if frame._arcTargetAlpha == nil then
    if isCooldownFrame then
      -- Cooldown frame: use pre-computed state
      if cdSpellID then
        local isOnGCD, isChargeSpell = cdIsOnGCD, cdIsCharge
        local isOnCooldown, isRecharging = cdOnCooldown, cdRecharging
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
  -- When frame is showing an aura (ignoreAuraOverride OFF), release
  -- desat control so CDM handles natively. We only manage desat for
  -- pure aura frames (no underlying cooldown).
  -- ═════════════════════════════════════════════════════════════════
  if frame._arcTargetDesat == nil then
    if isCooldownFrame then
      -- Cooldown frame currently showing aura → release desat control.
      -- CDM handles desat natively based on aura/cooldown state.
      frame._arcDesatBranch = "AURA_CD_NATIVE"
      frame._arcForceDesatValue = nil
      frame._arcTargetDesat = -1  -- mark as processed but not managed
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
  -- When frame is showing an aura, release vertex color control so
  -- CDM/SpellUsability handle natively.
  -- ═════════════════════════════════════════════════════════════════
  if frame._arcTargetTint == nil then
    if isCooldownFrame then
      -- Release vertex color enforcement → CDM handles natively
      frame._arcDesiredVertexColor = nil
      frame._arcTargetTint = true
    else
      local tR, tG, tB = 1, 1, 1
      if not isAuraActive and stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
        local col = stateVisuals.cooldownTintColor
        tR, tG, tB = col.r or 0.5, col.g or 0.5, col.b or 0.5
      end
      frame._arcTargetTint = string.format("%.2f,%.2f,%.2f", tR, tG, tB)
      if iconTex then SetVertexColorSafe(frame, iconTex, tR, tG, tB) end
    end
  end

  -- ═════════════════════════════════════════════════════════════════
  -- SWIPE/EDGE: Release control for cooldown frames showing auras.
  -- CDM manages swipe natively for aura duration display.
  -- Without this, stale _arcDesiredSwipe from HandleCooldownLogic
  -- would persist and enforcement hooks would hide CDM's aura swipe.
  -- ═════════════════════════════════════════════════════════════════
  if isCooldownFrame then
    frame._arcDesiredSwipe = nil
    frame._arcDesiredEdge = nil
  end

  -- ═════════════════════════════════════════════════════════════════
  -- GLOW
  -- ═════════════════════════════════════════════════════════════════
  local auraID = frame.auraInstanceID
  if isCooldownFrame or frame._arcTargetGlow == nil then
    if isCooldownFrame then
      -- Binary glow using pre-computed state
      if cdSpellID then
        local glowOnCD, glowRecharging = cdOnCooldown, cdRecharging
        local glowWhileCharges = stateVisuals.glowWhileChargesAvailable

        local glowEligible = true
        if glowOnCD then
          glowEligible = false
        elseif cdIsCharge and glowRecharging and not glowWhileCharges then
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
    -- Can't resolve spell (frame mid-update, cooldownInfo not populated yet).
    -- DON'T touch desat/alpha — let CDM handle natively. Clear our force values
    -- so hooks don't interfere with CDM's correct state.
    frame._arcDesatBranch = "C1_NO_SPELL"
    frame._arcForceDesatValue = nil
    frame._arcEnforceReadyAlpha = false
    frame._arcReadyAlphaValue = nil
    frame._arcTargetAlpha = nil
    frame._arcDesiredSwipe = nil
    frame._arcDesiredEdge = nil
    frame._arcDesiredVertexColor = nil
    return
  end

  -- Single operation: feed shadow → read state (ArcAuras pattern)
  local isOnCooldown, isRecharging, isChargeSpell, isOnGCD = ReadCooldownState(frame, spellID)

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
    -- Following ABE priority: on-cooldown tint ONLY. Usability tints
    -- (OOM, not-usable, normal) do NOT apply during cooldown.
    -- ═══════════════════════════════════════════════════════════════
    frame._arcDesatBranch = "C_BIN_CD"
    ApplyCooldownAlpha(frame, stateVisuals)
    ApplyCooldownDesat(frame, iconTex, stateVisuals, hasActiveAuraDisplay, isRecharging)
    -- Tint: ONLY custom cooldownTint. Enforce so SPELL_UPDATE_USABLE
    -- doesn't overwrite between CD events. No tint → clear enforcement,
    -- let CDM/SpellUsability handle natively.
    if stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
      local col = stateVisuals.cooldownTintColor
      SetVertexColorSafe(frame, iconTex, col.r or 0.5, col.g or 0.5, col.b or 0.5)
    else
      frame._arcDesiredVertexColor = nil  -- release enforcement
    end
    -- Glow: charge spell recharging with glowWhileChargesAvailable → keep glow
    if isGlowEligible then
      ApplyReadyGlow(frame, stateVisuals)
    else
      HideReadyGlow(frame)
    end
  else
    -- ═══════════════════════════════════════════════════════════════
    -- READY (match ArcAuras lines 498-558)
    -- Merge usability alpha into readyAlpha — single writer.
    -- Vertex color: SpellUsability.OnRefreshIconColor owns all
    -- ready-state tinting (OOM, not-usable, normal/ready color).
    -- CooldownState does NOT touch vertex color in ready state.
    -- ═══════════════════════════════════════════════════════════════
    frame._arcDesatBranch = "C_BIN_READY"
    local usabilityAlpha = GetUsabilityAlpha(frame, spellID, cfg)
    ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha)
    -- Release vertex color enforcement — SpellUsability handles it
    frame._arcDesiredVertexColor = nil

    if isGlowEligible then
      ApplyReadyGlow(frame, stateVisuals)
    else
      HideReadyGlow(frame)
    end
  end

  -- ═══════════════════════════════════════════════════════════════
  -- UNIFIED SWIPE/EDGE DECISION (PATH C)
  -- CooldownState owns swipe/edge with CDM-aware passthrough.
  -- Shadow-driven: isOnCooldown/isRecharging are GCD-filtered.
  --
  -- ACTIVE ENFORCEMENT: hooksecurefunc fires AFTER CDM processes.
  -- PreDispatch sets _arcDesiredSwipe, then the caller ACTIVELY
  -- calls SetDrawSwipe to correct CDM's stale write. Same as
  -- ArcAuras: decide + write in one call stack. No race.
  --
  -- ACTIVE CONTROL (true/false): When we override CDM's behavior.
  --   true  → on cooldown, recharging without wait flags
  --   false → noGCDSwipe ON + READY/GCD, swipeWait + recharging
  -- PASSTHROUGH (nil): When CDM's native behavior is correct.
  --   nil   → READY (no flags), GCD + noGCDSwipe OFF
  -- ═══════════════════════════════════════════════════════════════
  if frame.Cooldown then
    local swipeCfg = cfg.cooldownSwipe
    local userWantsSwipe = not swipeCfg or swipeCfg.showSwipe ~= false
    local userWantsEdge  = not swipeCfg or swipeCfg.showEdge  ~= false
    -- Read from cfg (stable) instead of frame properties (may be stale/cleared by CDM)
    local noGCDSwipe = swipeCfg and swipeCfg.noGCDSwipe
    local wantSwipe, wantEdge

    if isChargeSpell then
      local swipeWait = swipeCfg and swipeCfg.swipeWaitForNoCharges
      local edgeWait  = swipeCfg and swipeCfg.edgeWaitForNoCharges
      local hasWaitFlags = swipeWait or edgeWait

      if isOnCooldown then
        -- All charges depleted → show swipe/edge per user pref
        wantSwipe = userWantsSwipe
        wantEdge  = userWantsEdge
      elseif isRecharging then
        -- Recharging: wait flags actively block, otherwise show
        wantSwipe = not swipeWait and userWantsSwipe
        wantEdge  = not edgeWait and userWantsEdge
      elseif noGCDSwipe or hasWaitFlags then
        -- READY + (noGCDSwipe OR waitFlags) → explicit false to block
        -- waitFlags: prevents race condition during READY→recharge transition
        -- (CooldownState dispatches AFTER CDM hooks, so stale nil would
        -- let CDM's recharge swipe through before we can set false)
        wantSwipe = false
        wantEdge  = false
      else
        -- READY, no blockers → CDM passthrough (GCD swipe shows)
        wantSwipe = nil
        wantEdge  = nil
      end
    else
      -- Normal spell: shadow is GCD-filtered (isOnCooldown=false during GCD)
      if isOnCooldown then
        wantSwipe = userWantsSwipe
        wantEdge  = userWantsEdge
      elseif noGCDSwipe and isOnGCD then
        -- GCD active + noGCDSwipe ON → actively block GCD swipe
        wantSwipe = false
        wantEdge  = false
      else
        -- READY (or GCD + noGCDSwipe OFF): release to CDM
        wantSwipe = nil
        wantEdge  = nil
      end
    end

    -- Store for enforcing hooks
    frame._arcDesiredSwipe = wantSwipe
    frame._arcDesiredEdge  = wantEdge
    -- Only call SetDrawSwipe when we have an explicit decision (not nil passthrough)
    if wantSwipe ~= nil then
      frame._arcBypassSwipeHook = true
      frame.Cooldown:SetDrawSwipe(wantSwipe)
      frame.Cooldown:SetDrawEdge(wantEdge)
      frame._arcBypassSwipeHook = false
    end
  end

  -- ═══════════════════════════════════════════════════════════════
  -- SPELL USABILITY DESATURATION OVERRIDE
  -- Checks both the stored flag from SpellUsability.OnRefreshIconColor
  -- AND computes fresh via GetUsabilityDesaturation so it works
  -- regardless of which system fires first.
  -- Uses bypass so CDMEnhance hooks don't intercept.
  -- ═══════════════════════════════════════════════════════════════
  local usabilityDesat = frame._arcUsabilityDesatRequest
  if usabilityDesat == nil then
    usabilityDesat = GetUsabilityDesaturation(frame, spellID, cfg)
  end
  if usabilityDesat then
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 1)
    frame._arcBypassDesatHook = false
    -- Update _arcForceDesatValue so CDMEnhance hooks also enforce it
    frame._arcForceDesatValue = 1
    -- Store for CDMEnhance hooks to reference
    frame._arcUsabilityDesatRequest = true
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

  -- No safety net needed: HandleCooldownLogic and HandleIgnoreAuraOverride
  -- Handlers read state from already-fed shadows via ReadCooldownState.
  -- This eliminates the dual-feed race that caused GCD transition flashes.

  if not stateVisuals then
    stateVisuals = GetEffectiveStateVisuals(cfg)
  end

  local cdID = frame.cooldownID
  local isGlowPreview = cdID and ns.CDMEnhanceOptions
                        and ns.CDMEnhanceOptions.IsGlowPreviewActive
                        and ns.CDMEnhanceOptions.IsGlowPreviewActive(cdID)

  local ignoreAuraOverride = (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
                          or (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)

  -- Check if spellUsability needs us to proceed (for alpha override)
  local hasSpellUsability = cfg.spellUsability and cfg.spellUsability.enabled ~= false

  -- No state visuals + no preview + no ignoreAuraOverride + no spellUsability + no noGCDSwipe + no waitFlags → let CDM handle
  local hasNoGCDSwipe = cfg.cooldownSwipe and cfg.cooldownSwipe.noGCDSwipe
  local hasWaitFlags = cfg.cooldownSwipe and (cfg.cooldownSwipe.swipeWaitForNoCharges or cfg.cooldownSwipe.edgeWaitForNoCharges)
  if not stateVisuals and not isGlowPreview and not ignoreAuraOverride and not hasSpellUsability and not hasNoGCDSwipe and not hasWaitFlags then
    local prevBranch = frame._arcDesatBranch
    local wasManagedDesat = prevBranch ~= nil and prevBranch ~= "NO_SV_EARLY"

    frame._arcForceDesatValue = nil
    frame._arcReadyForGlow = false
    frame._arcDesatBranch = "NO_SV_EARLY"
    frame._arcDesiredSwipe = nil
    frame._arcDesiredEdge = nil
    frame._arcDesiredVertexColor = nil
    HideReadyGlow(frame)

    if wasManagedDesat then
      SetDesat(iconTex, 0)
      -- Reset vertex color to white (bypass keepBright hook, but don't enforce)
      frame._arcBypassVertexHook = true
      if iconTex then iconTex:SetVertexColor(1, 1, 1, 1) end
      frame._arcBypassVertexHook = false
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
ns.CooldownState.GetUsabilityAlpha  = GetUsabilityAlpha

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
-- PRE-DISPATCH: Cache isOnGCD + dispatch CooldownState.
--
-- Called from CDMEnhance's hooksecurefunc on OnSpellUpdateCooldownEvent.
-- Only caches isOnGCD (reliable only in SPELL_UPDATE_COOLDOWN context).
-- Shadows PUSH visual updates via hooks on SetCooldown /
-- SetCooldownFromDurationObject / OnCooldownDone (ArcAuras pattern).
-- PreDispatch only: caches isOnGCD + feeds shadows.
-- After return, the caller ACTIVELY calls SetDrawSwipe/SetDrawEdge
-- to correct CDM's stale write. No race, no taint.
-- ═══════════════════════════════════════════════════════════════════
function ns.CooldownState.PreDispatch(frame)
  if not frame then return end
  if frame._arcConfig or frame._arcAuraID then return end

  local ci = frame.cooldownInfo
  local spellID = ci and (ci.overrideSpellID or ci.spellID)
  if not spellID then return end

  -- Cache isOnGCD (only reliable in event context)
  local newIsOnGCD = nil
  pcall(function()
    local cdInfo = C_Spell.GetSpellCooldown(spellID)
    if cdInfo then newIsOnGCD = cdInfo.isOnGCD end
  end)

  -- GCD→non-GCD transition guard:
  -- HOLD the old cache (true) so FeedShadowCooldown sees
  -- isOnGCD=true → clears shadow → prevents residual GCD
  -- DurationObject from causing false cooldown flash.
  local isGCDTransition = frame._arcCachedIsOnGCD and not newIsOnGCD
  if not isGCDTransition then
    frame._arcCachedIsOnGCD = newIsOnGCD
  end

  -- Feed shadows → hooks fire → dispatch happens automatically
  -- (shadow hooks call ApplyCooldownStateVisuals directly)
  EnsureShadowCooldown(frame)
  FeedShadowCooldown(frame, spellID)

  -- Clear GCD cache after transition guard (next event feeds normally)
  if isGCDTransition then
    frame._arcCachedIsOnGCD = nil
  end
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
  local desatCurve = GetTwoStateDesatCurve(stateVisuals.cooldownDesaturate)
  if desatCurve and durObj then
    local ok, desatResult = pcall(function()
      return durObj:EvaluateRemainingPercent(desatCurve)
    end)
    if ok and desatResult ~= nil then
      SetDesat(iconTex, desatResult)
      ApplyBorderDesaturation(frame, desatResult)
      return true
    end
  end
  SetDesat(iconTex, 1)
  ApplyBorderDesaturation(frame, 1)
  return false
end
--]]