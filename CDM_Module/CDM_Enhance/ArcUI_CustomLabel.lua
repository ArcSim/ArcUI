-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Custom Label  (up to 3 per icon)
-- Per-icon custom text overlays for CDM icons
-- v2.11.0: Secret-safe auraInstanceID protection
--
-- Each label has its own: text, size, color, anchor, xOffset, yOffset,
--   AND its own state visibility toggles
-- Shared across all labels: font, outline, frameStrata, frameLevel
--
-- STATE VISIBILITY (secret-safe, PER-LABEL):
--   Auras:     Uses HasAuraInstanceID() for secret-safe detection
--     showWhenActive  / showWhenInactive  (+ suffix 2/3)
--
--   Cooldowns (non-charge): Two-state using durationObj curve
--     showInReadyState / showInCooldownState (+ suffix 2/3)
--     isOnGCD filter prevents phantom CD
--
--   Cooldowns (charge): Three-state using chargeDurObj + durationObj
--     showInReadyState    = all charges full
--     showWhileRecharging = has charges but recharging
--     showInCooldownState = all charges spent (uncastable)
--     chargeDurObj is GCD-safe; durationObj needs GCD filter on charge spells
--
--   Cooldown Aura Filter (secret-safe gate):
--     showWhenAuraActive  / showWhenAuraInactive (+ suffix 2/3)
--     Some cooldown frames also track auras (auraInstanceID on the frame).
--     This filter gates the cooldown visibility result: if the aura state
--     doesn't match, alpha is forced to 0 regardless of cooldown state.
--     Uses HasAuraInstanceID() for secret-safe boolean check.
--
-- DATA STORAGE: All settings live inside cfg.customLabel which is part of
-- iconSettings[cooldownID] in the AceDB profile → exported by CDM export.
-- ═══════════════════════════════════════════════════════════════════════════

local addonName, ns = ...

ns.CustomLabel = ns.CustomLabel or {}
local CL = ns.CustomLabel

-- Label index → config key suffixes:  1="", 2="2", 3="3"
local SUFFIXES = { "", "2", "3" }
-- Frame keys for each label's container
local FRAME_KEYS = { "_arcCL1", "_arcCL2", "_arcCL3" }

-- ═══════════════════════════════════════════════════════════════════════════
-- SECRET-SAFE AURAINSTANCEID HELPER
-- Uses ns.API.HasAuraInstanceID from Core.lua (handles secret values)
-- ═══════════════════════════════════════════════════════════════════════════
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
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function GetFontPath(fontName)
  if not fontName or fontName == "" then return "Fonts\\FRIZQT__.TTF" end
  local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
  if LSM then
    local path = LSM:Fetch("font", fontName)
    if path then return path end
  end
  if fontName:find("\\") or fontName:find("/") then return fontName end
  return "Fonts\\FRIZQT__.TTF"
end

-- Secret-safe curve alpha helper: evaluates curve on durationObj, sets widget alpha
local function ApplyCurveAlpha(widget, durObj, curve)
  if not widget or not durObj or not curve then return end
  local ok, result = pcall(function()
    return durObj:EvaluateRemainingPercent(curve)
  end)
  if ok and result ~= nil then
    widget:SetAlpha(result)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- APPLY CUSTOM LABEL(S)
-- Creates/updates up to 3 container+FontString overlays per icon
-- ═══════════════════════════════════════════════════════════════════════════

function CL.Apply(frame, cfg)
  if not frame then return end

  local labelCfg = cfg and cfg.customLabel
  local labelCount = (labelCfg and labelCfg.labelCount) or 1
  local anyHasText = false

  -- Shared settings (apply to all labels)
  local sharedFont = labelCfg and labelCfg.font
  local sharedOutline = labelCfg and labelCfg.outline or "OUTLINE"
  local sharedStrata = labelCfg and labelCfg.frameStrata
  local sharedLevel = labelCfg and labelCfg.frameLevel

  for i = 1, 3 do
    local s = SUFFIXES[i]
    local fk = FRAME_KEYS[i]
    local labelText = labelCfg and labelCfg["text" .. s]

    -- Hide labels beyond labelCount or without text
    if i > labelCount or not labelText or labelText == "" then
      if frame[fk] then frame[fk]:Hide() end
    else
      anyHasText = true

      -- ── Create container if needed ──
      if not frame[fk] then
        local container = CreateFrame("Frame", nil, frame)
        container:SetIgnoreParentAlpha(true)
        container._text = container:CreateFontString(nil, "OVERLAY")
        container._text:SetDrawLayer("OVERLAY", 7)
        frame[fk] = container
      end

      local container = frame[fk]
      local label = container._text

      -- ── Per-label settings ──
      local fontSize = labelCfg["size" .. s] or 12
      local anchor   = labelCfg["anchor" .. s] or "CENTER"
      local xOff     = labelCfg["xOffset" .. s] or 0
      local yOff     = labelCfg["yOffset" .. s] or 0
      local c        = labelCfg["color" .. s] or { r = 1, g = 1, b = 1, a = 1 }

      -- ── Font (shared) ──
      local fontFace = GetFontPath(sharedFont)
      local ok = pcall(label.SetFont, label, fontFace, fontSize, sharedOutline)
      if not ok then label:SetFont("Fonts\\FRIZQT__.TTF", fontSize, sharedOutline) end

      -- ── Color ──
      label:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)

      -- ── Anchor (container fills parent, fontstring anchors like cooldown text) ──
      container:ClearAllPoints()
      container:SetAllPoints(frame)
      label:ClearAllPoints()
      label:SetPoint(anchor, container, anchor, xOff, yOff)

      -- ── Strata / Level (shared) ──
      if sharedStrata and sharedStrata ~= "" then
        container:SetFrameStrata(sharedStrata)
      else
        container:SetFrameStrata(frame:GetFrameStrata())
      end
      if sharedLevel and sharedLevel > 0 then
        container:SetFrameLevel(sharedLevel)
      else
        container:SetFrameLevel(frame:GetFrameLevel() + 2)
      end

      -- ── Text ──
      label:SetText(labelText)
      container:Show()
      label:Show()
    end
  end

  frame._arcCLHasText = anyHasText
  -- Backward compat alias (points to label 1's fontstring)
  frame._arcCustomLabel = frame._arcCL1 and frame._arcCL1._text or nil
  frame._arcCustomLabelFrame = frame._arcCL1  -- compat
  frame._arcCLVisCache = nil  -- Force re-evaluation
  CL.UpdateVisibility(frame)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UPDATE VISIBILITY  (state-based, runs from hot paths)
--
-- Each label has its OWN state visibility toggles.
--
-- CHARGE SPELL THREE-STATE MODEL:
--   Ready      = all charges full:     chargeDurObj=0%, durationObj=0%
--   Recharging = charges available:    chargeDurObj>0%, durationObj=0%
--   On Cooldown = all charges spent:   chargeDurObj>0%, durationObj>0%
--
--   chargeDurObj is GCD-safe (ignores GCD phantom CD)
--   durationObj on charge spells shows phantom CD during GCD → filter needed
--
-- CURVE MAPPING (R=Ready, Re=Recharging, CD=OnCooldown):
--   T,T,T → alpha=1
--   F,F,F → alpha=0
--   T,T,F → durationObj BinaryInv      (show when NOT all-spent)
--   F,T,T → chargeDurObj Binary         (show when any recharging)
--   T,F,F → chargeDurObj BinaryInv      (show when all-full)
--   F,F,T → durationObj Binary          (show when all-spent)
--   F,T,F → container=chargeBin × text=durBinInv  (alpha multiply)
--   T,F,T → approximate as always visible (can't OR two secrets)
--
-- COOLDOWN AURA FILTER (applied AFTER cooldown curves):
--   showWhenAuraActive / showWhenAuraInactive per label
--   Non-secret gate: if aura state doesn't match toggles → alpha=0
--   If both toggles are true (default) → no filtering (aura state ignored)
-- ═══════════════════════════════════════════════════════════════════════════

function CL.UpdateVisibility(frame)
  if not frame then return end
  if not frame._arcCLHasText then return end

  local cfg = frame._arcCfg
  local labelCfg = cfg and cfg.customLabel
  -- Use ONLY cfg._isAura to determine path, NOT frame.wasSetFromAura.
  local isAura = (cfg and cfg._isAura == true)

  -- ── AURA PATH: secret-safe via HasAuraInstanceID() ──
  if isAura then
    local isActive = HasAuraInstanceID(frame.auraInstanceID) or (frame.totemData ~= nil)

    for i = 1, 3 do
      local container = frame[FRAME_KEYS[i]]
      if container and container:IsShown() then
        local s = SUFFIXES[i]
        local showActive   = not labelCfg or labelCfg["showWhenActive" .. s] ~= false
        local showInactive = not labelCfg or labelCfg["showWhenInactive" .. s] ~= false
        local shouldShow = (isActive and showActive) or (not isActive and showInactive)
        container:SetAlpha(shouldShow and 1 or 0)
      end
    end
    return
  end

  -- ── COOLDOWN PATH: per-label, duration is SECRET → curve system ──
  local spellID = (cfg and cfg._spellID)
    or (frame.cooldownInfo and (frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID))

  -- Pre-compute cooldown state once for all labels
  local isOnGCD, durationObj, isChargeSpell, chargeDurObj
  local GetSpellCooldownState = ns.CDMEnhance and ns.CDMEnhance.GetSpellCooldownState
  local CooldownCurves

  if spellID and GetSpellCooldownState then
    isOnGCD, durationObj, isChargeSpell, chargeDurObj = GetSpellCooldownState(spellID)

    -- Init curves if we have ANY duration objects
    if durationObj or chargeDurObj then
      local InitCooldownCurves = ns.CDMEnhance and ns.CDMEnhance.InitCooldownCurves
      if InitCooldownCurves then InitCooldownCurves() end
      CooldownCurves = ns.CDMEnhance and ns.CDMEnhance.CooldownCurves
    end
  end

  -- Pre-compute aura state once for all labels (secret-safe)
  local hasFrameAura = HasAuraInstanceID(frame.auraInstanceID) or (frame.totemData ~= nil)

  for i = 1, 3 do
    local container = frame[FRAME_KEYS[i]]
    if container and container:IsShown() then
      local s = SUFFIXES[i]
      local label = container._text
      -- Reset text alpha (may have been set by charge F,T,F multiply case)
      if label then label:SetAlpha(1) end

      -- ════════════════════════════════════════════════════════════════
      -- TWO INDEPENDENT VISIBILITY SYSTEMS:
      --   1. COOLDOWN SYSTEM: showInReadyState / showInCooldownState
      --   2. AURA SYSTEM: showWhenAuraActive / showWhenAuraInactive
      --
      -- Each system is "configured" if at least one toggle is false.
      -- Both true = "show always" = system not filtering.
      --
      -- Final visibility:
      --   - Neither configured → show
      --   - Only cooldown configured → use cooldown result
      --   - Only aura configured → use aura result
      --   - Both configured → both must pass (AND)
      -- ════════════════════════════════════════════════════════════════

      -- COOLDOWN TOGGLES
      local showReady    = not labelCfg or labelCfg["showInReadyState" .. s] ~= false
      local showCooldown = not labelCfg or labelCfg["showInCooldownState" .. s] ~= false

      -- AURA TOGGLES
      local showAuraActive   = not labelCfg or labelCfg["showWhenAuraActive" .. s] ~= false
      local showAuraInactive = not labelCfg or labelCfg["showWhenAuraInactive" .. s] ~= false
      -- "Configured" = user intentionally wants to filter by aura state
      -- Both true = "show always" = not filtering
      -- Both false = "hide always" = likely stale/unintended data, ignore
      -- One true, one false = intentional filtering
      local auraConfigured = (showAuraActive ~= showAuraInactive)

      -- COMPUTE AURA RESULT FIRST (if configured)
      local auraPass = true
      if auraConfigured then
        auraPass = (hasFrameAura and showAuraActive) or (not hasFrameAura and showAuraInactive)
      end

      -- If aura check fails, hide immediately - don't compute cooldown
      if not auraPass then
        container:SetAlpha(0)
        if label then label:SetAlpha(1) end
      else
        -- ════════════════════════════════════════════════════════════════
        -- CHARGE SPELL: Three-state
        -- ════════════════════════════════════════════════════════════════
        if isChargeSpell and chargeDurObj and CooldownCurves then
          local showRecharging = not labelCfg or labelCfg["showWhileRecharging" .. s] ~= false
          local gcdActive = (isOnGCD == true)
          
          -- Check if cooldown filtering is configured (3 toggles)
          -- All ON = not filtering, All OFF = disabled, Mixed = filtering
          local allOn = showReady and showRecharging and showCooldown
          local allOff = not showReady and not showRecharging and not showCooldown
          local chargeConfigured = not allOn and not allOff
          
          if not chargeConfigured then
            -- All toggles same state - not filtering, show the label
            container:SetAlpha(1)
          elseif showReady and showRecharging then
            if gcdActive or not durationObj then
              container:SetAlpha(1)
            else
              ApplyCurveAlpha(container, durationObj, CooldownCurves.BinaryInv)
            end
          elseif showRecharging and showCooldown then
            ApplyCurveAlpha(container, chargeDurObj, CooldownCurves.Binary)
          elseif showReady and not showRecharging and not showCooldown then
            ApplyCurveAlpha(container, chargeDurObj, CooldownCurves.BinaryInv)
          elseif not showReady and not showRecharging and showCooldown then
            if gcdActive or not durationObj then
              container:SetAlpha(0)
            else
              ApplyCurveAlpha(container, durationObj, CooldownCurves.Binary)
            end
          elseif showRecharging then
            ApplyCurveAlpha(container, chargeDurObj, CooldownCurves.Binary)
            if label then
              if gcdActive or not durationObj then
                label:SetAlpha(1)
              else
                ApplyCurveAlpha(label, durationObj, CooldownCurves.BinaryInv)
              end
            end
          else
            container:SetAlpha(1)
          end
        -- ════════════════════════════════════════════════════════════════
        -- NON-CHARGE SPELL: Two-state
        -- ════════════════════════════════════════════════════════════════
        else
          -- Check if cooldown filtering is configured (2 toggles)
          local allOn = showReady and showCooldown
          local allOff = not showReady and not showCooldown
          local cdConfigured = not allOn and not allOff
          
          if not cdConfigured then
            -- All toggles same state - not filtering, show the label
            container:SetAlpha(1)
          elseif not spellID or isOnGCD or not durationObj or not CooldownCurves then
            -- Fallback: use boolean result
            container:SetAlpha(showReady and 1 or 0)
          else
            -- Use curve for smooth transition
            local curve = showReady and CooldownCurves.BinaryInv or CooldownCurves.Binary
            if curve then
              ApplyCurveAlpha(container, durationObj, curve)
            end
          end
        end
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CLEAR CUSTOM LABEL(S)
-- ═══════════════════════════════════════════════════════════════════════════

function CL.Clear(frame)
  if not frame then return end
  for i = 1, 3 do
    local c = frame[FRAME_KEYS[i]]
    if c then
      c:Hide()
      if c._text then c._text:Hide(); c._text:SetText("") end
    end
  end
  frame._arcCLHasText = false
  frame._arcCLVisCache = nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REFRESH ALL
-- ═══════════════════════════════════════════════════════════════════════════

function CL.RefreshAll()
  if not ns.CDMEnhance or not ns.CDMEnhance.GetEnhancedFrames then return end
  local frames = ns.CDMEnhance.GetEnhancedFrames()
  if not frames then return end
  for cdID, data in pairs(frames) do
    if data.frame then
      local cfg = ns.CDMEnhance.GetEffectiveIconSettings and ns.CDMEnhance.GetEffectiveIconSettings(cdID)
      CL.Apply(data.frame, cfg)
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- QUEUE REFRESH  (debounced)
-- ═══════════════════════════════════════════════════════════════════════════

local refreshPending = false
function CL.QueueRefresh()
  if refreshPending then return end
  refreshPending = true
  C_Timer.After(0.05, function()
    refreshPending = false
    CL.RefreshAll()
  end)
end