-- ===================================================================
-- ArcUI_CooldownState.lua
-- Consolidated cooldown state visual system
-- v3.3.0: ArcAuras-pattern refactor — single feed+apply, no cascade
--
-- ARCHITECTURE: Owns two invisible shadow Cooldown frames per icon:
--
-- _arcCDMShadowCooldown (main CD):
--   Fed with GetSpellCooldownDuration. GCD filtered.
--   IsShown()=true  → ALL charges depleted / full cooldown active
--   IsShown()=false → ready or has charges available
--
-- _arcCDMChargeShadow (charge recharge):
--   SetCooldown(0,0) then SetCooldownFromDurationObject(GetSpellChargeDuration).
--   Clear-first ensures proc resets and CDR clear immediately.
--   IsShown()=true  → recharge timer active
--   IsShown()=false → all charges full
--
-- EVENT-DRIVEN ARCHITECTURE (matches ArcAuras):
--   Per-icon event handler catches SPELL_UPDATE_COOLDOWN/CHARGES.
--   Feeds shadows, then calls ApplyCooldownStateVisuals ONCE.
--   OnCooldownDone on each shadow catches natural timer expiry.
--   NO hooks on SetCooldown/SetCooldownFromDurationObject —
--   we call those ourselves, so hooking them was reacting to our
--   own writes = 5-13x cascade per event. ArcAuras never does this.
--
-- ENFORCEMENT HOOKS (on CDM parent frame):
--   SetAlpha, SetDesaturated, SetVertexColor hooks BLOCK CDM's
--   native writes and enforce our values. These never re-feed
--   or re-dispatch — they just guard the values we already set.
-- ===================================================================

local ADDON, ns = ...

ns.CooldownState = ns.CooldownState or {}

-- ═══════════════════════════════════════════════════════════════════
-- SECRET-SAFE AURAINSTANCEID HELPER
-- ═══════════════════════════════════════════════════════════════════
-- Live-frame aura presence. HasAuraInstanceID rejects 0 because 0 is the saved-
-- variable "no aura" default, but a LIVE CDM frame reports auraInstanceID == 0 for
-- a self-aura (e.g. Voidfall) = the aura EXISTS. Here only nil means no aura.
-- (A secret value is non-nil = present.) Use this for live frame.auraInstanceID
-- presence checks; keep HasAuraInstanceID for stored / saved-variable ids.
local function HasFrameAura(value)
  return value ~= nil
end

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
local InitCooldownCurves
local GetEffectiveStateVisuals
local GetEffectiveReadyAlpha
local GetGlowThresholdCurve
local ShowReadyGlow
local HideReadyGlow
local SetGlowAlpha
local ShouldShowReadyGlow
local ApplyBorderDesaturation
local EvaluateAuraActiveGlow

local resolved = false

local function ResolveDependencies()
  CDM = ns.CDMEnhance
  if not CDM then return false end

  InitCooldownCurves          = CDM.InitCooldownCurves
  GetEffectiveStateVisuals    = CDM.GetEffectiveStateVisuals
  GetEffectiveReadyAlpha      = CDM.GetEffectiveReadyAlpha
  GetGlowThresholdCurve       = CDM.GetGlowThresholdCurve
  ShowReadyGlow               = CDM.ShowReadyGlow
  HideReadyGlow               = CDM.HideReadyGlow       or function() end
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

local function SetVertexColorSafe(frame, iconTex, r, g, b, a)
  if not iconTex then return end
  -- Store desired color so RefreshIconColor hook can re-apply after CDM writes
  frame._arcDesiredVertexColor = { r = r, g = g, b = b }
  iconTex:SetVertexColor(r, g, b, a or 1)
end

local function ResetDurationText(frame)
  -- Force Hide owns text IgnoreParentAlpha while active (text floats above the
  -- hidden frame). Don't let the normal reset path un-float it.
  if frame._arcForceHideActive then return end
  local skip = frame._arcSwipeWaitForNoCharges
  if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
    if not skip then frame._arcCooldownText:SetIgnoreParentAlpha(false) end
  end
  if frame._arcChargeText and frame._arcChargeText.SetIgnoreParentAlpha then
    if not skip then frame._arcChargeText:SetIgnoreParentAlpha(false) end
  end
  -- Restore chargeFrame container
  if not skip then
    local chargeFrame = frame.ChargeCount or frame.Applications
    if chargeFrame and chargeFrame.SetIgnoreParentAlpha then
      chargeFrame:SetIgnoreParentAlpha(false)
    end
  end
  if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
    if not skip then frame.Cooldown.Text:SetIgnoreParentAlpha(false) end
  end
  if frame.Cooldown and frame.Cooldown.SetIgnoreParentAlpha then
    frame.Cooldown:SetIgnoreParentAlpha(false)
  end
  -- Walk native Cooldown regions
  if frame.Cooldown and not skip then
    local countdownFS = frame.Cooldown.GetCountdownFontString and frame.Cooldown:GetCountdownFontString()
    if countdownFS and countdownFS.SetIgnoreParentAlpha then
      countdownFS:SetIgnoreParentAlpha(false)
    end
    for _, region in ipairs({frame.Cooldown:GetRegions()}) do
      if region:IsObjectType("FontString") and region.SetIgnoreParentAlpha
         and not region._arcIsChargeText then
        region:SetIgnoreParentAlpha(false)
      end
    end
  end
end

local function PreserveDurationText(frame)
  -- Don't enable IgnoreParentAlpha if the group container is hidden
  -- Check both frame and parent: icons added after SafeShowContainer don't have the flag
  if frame._arcGroupHidden then return end
  local parent = frame:GetParent()
  if parent and parent._arcGroupHidden then return end
  
  -- Skip cooldown text if charge-conditional hide is active
  if not frame._arcHideCDTextForCharges then
    if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
      frame._arcCooldownText:SetIgnoreParentAlpha(true)
      frame._arcCooldownText:SetAlpha(1)
    end
    if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
      frame.Cooldown.Text:SetIgnoreParentAlpha(true)
      frame.Cooldown.Text:SetAlpha(1)
    end
  end
  -- Skip charge text if hideAtZero is active
  if not frame._arcHideChargeAtZero then
    if frame._arcChargeText and frame._arcChargeText.SetIgnoreParentAlpha then
      frame._arcChargeText:SetIgnoreParentAlpha(true)
      frame._arcChargeText:SetAlpha(1)
    end
    -- Also protect the chargeFrame container (ChargeCount/Applications).
    -- SetIgnoreParentAlpha on the FontString only ignores inherited alpha —
    -- CDM calls chargeFrame:SetAlpha(0) directly which still affects the text.
    -- SetIgnoreParentAlpha on the container makes it ignore the icon frame's alpha.
    local chargeFrame = frame.ChargeCount or frame.Applications
    if chargeFrame and chargeFrame.SetIgnoreParentAlpha then
      chargeFrame:SetIgnoreParentAlpha(true)
      chargeFrame:SetAlpha(1)
    end
  end
  -- Native Cooldown FontStrings: The Cooldown widget can recreate/reset
  -- its internal text when CDM pushes new DurationObjects. Walk regions
  -- every call to catch any new or reset FontStrings.
  if frame.Cooldown then
    local countdownFS = frame.Cooldown.GetCountdownFontString and frame.Cooldown:GetCountdownFontString()
    if countdownFS and countdownFS.SetIgnoreParentAlpha then
      countdownFS:SetIgnoreParentAlpha(true)
      countdownFS:SetAlpha(1)
    end
    for _, region in ipairs({frame.Cooldown:GetRegions()}) do
      if region:IsObjectType("FontString") and region.SetIgnoreParentAlpha
         and not region._arcIsChargeText then
        region:SetIgnoreParentAlpha(true)
        region:SetAlpha(1)
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- CHARGE-CONDITIONAL TEXT VISIBILITY
--
-- Uses shadow state (non-secret) to conditionally show/hide text:
--   chargeText.hideAtZero: hide charge count when charges = 0
--   cooldownText.hideWhenHasCharges: hide CD text when charges > 0
-- ═══════════════════════════════════════════════════════════════════
local function ApplyChargeConditionalText(frame, cfg, isChargeSpell, isRecharging, isOnCooldown)
  if not isChargeSpell then
    -- Not a charge spell — clear any override flags
    frame._arcHideChargeAtZero = nil
    frame._arcHideCDTextForCharges = nil
    return
  end

  -- Derive charge state from shadows (non-secret):
  --   isRecharging = charges > 0 (charge shadow shown)
  --   isOnCooldown && !isRecharging = charges = 0 (all spent)
  --   !isOnCooldown && !isRecharging = all charges ready
  -- With both shadows read independently (matches shadow tester):
  -- DEPLETED   = isOnCooldown and isRecharging     (0 charges, one recharging)
  -- RECHARGING = not isOnCooldown and isRecharging (1+ charges, one recharging)
  -- FULL       = not isOnCooldown and not isRecharging
  -- DEPLETED   (isOnCooldown=true,  isRecharging=true):  0 charges
  -- RECHARGING (isOnCooldown=false, isRecharging=true):  1+ charges, recharging
  -- FULL       (isOnCooldown=false, isRecharging=false): all charges ready
  local chargesSpent = isOnCooldown and isRecharging   -- DEPLETED only: 0 charges
  local hasCharges   = not isOnCooldown                -- RECHARGING + FULL: 1+ charges

  -- ── CHARGE TEXT: hideAtZero ──
  local chargeCfg = cfg.chargeText
  local wantHideAtZero = chargeCfg and chargeCfg.hideAtZero and chargeCfg.enabled ~= false
  if wantHideAtZero and chargesSpent then
    frame._arcHideChargeAtZero = true
    if frame._arcChargeText then
      -- SetIgnoreParentAlpha: decouple from chargeFrame container so CDM
      -- showing/alpha-ing the container can't drag the fontstring back visible.
      if frame._arcChargeText.SetIgnoreParentAlpha then
        frame._arcChargeText:SetIgnoreParentAlpha(true)
      end
      frame._arcChargeText:SetAlpha(0)
    end
  else
    frame._arcHideChargeAtZero = nil
    -- Restore charge text unconditionally — RECHARGING means 1+ charges available,
    -- text must show regardless of frame alpha (cdAlpha dim does not mean text hidden).
    -- SetIgnoreParentAlpha(false) lets CDM's container alpha manage it naturally.
    -- FORCE HIDE exception: while Show Icon is off the frame renders at alpha 0 and
    -- the text lives on its float — un-floating it here (every dispatch for charge
    -- spells) would keep erasing the charge count Force Hide promises to keep.
    if chargeCfg and chargeCfg.enabled ~= false and frame._arcChargeText then
      if frame._arcChargeText.SetIgnoreParentAlpha and not frame._arcForceHideActive then
        frame._arcChargeText:SetIgnoreParentAlpha(false)
      end
      frame._arcChargeText:SetAlpha(1)
    end
  end

  -- ── COOLDOWN TEXT: hideWhenHasCharges ──
  local cdTextCfg = cfg.cooldownText
  local wantHideCDWithCharges = cdTextCfg and cdTextCfg.hideWhenHasCharges and cdTextCfg.enabled ~= false
  if wantHideCDWithCharges and hasCharges then
    frame._arcHideCDTextForCharges = true
    -- Use SetHideCountdownNumbers to properly suppress the Cooldown widget's
    -- built-in countdown — SetAlpha alone gets overwritten by CDM updates.
    if frame.Cooldown then
      frame.Cooldown:SetHideCountdownNumbers(true)
    end
    if frame._arcCooldownText then
      frame._arcCooldownText:SetAlpha(0)
    end
  else
    local wasHidden = frame._arcHideCDTextForCharges
    frame._arcHideCDTextForCharges = nil
    -- Only restore if cooldown text is enabled and was previously hidden by us
    if wasHidden and cdTextCfg and cdTextCfg.enabled ~= false then
      if frame.Cooldown then
        frame.Cooldown:SetHideCountdownNumbers(false)
      end
      if (frame._lastAppliedAlpha or 1) > 0.01 then
        if frame._arcCooldownText then
          frame._arcCooldownText:SetAlpha(1)
        end
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- DUAL SHADOW COOLDOWN FRAMES — Creation + Feeding + CDM Write Hook
--
-- Shadow frames are our independent cooldown detection system.
-- CDM never sees them. We feed them, we read them.
--
-- Hooks:
--   1. OnCooldownDone on each shadow — natural timer expiry
--   2. SetCooldownFromDurationObject on CDM's VISIBLE Cooldown —
--      CDM writes to its cooldown → we react by feeding our shadows
--      and applying visuals. Independent of CDM's event dispatch.
--
-- NO hooks on shadow SetCooldown / SetCooldownFromDurationObject —
-- we call those during feeding. Hooking them = cascade.
-- ═══════════════════════════════════════════════════════════════════

local function CreateInvisibleCooldown(frame)
  local cd = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
  cd:SetAllPoints(frame)
  cd:SetDrawSwipe(false)
  cd:SetDrawEdge(false)
  cd:SetDrawBling(false)
  cd:SetHideCountdownNumbers(true)
  cd:SetAlpha(0)
  return cd
end

local FeedShadowCooldown
local EnforceCooldownReadyGlow

-- Shared dispatch: apply visuals + glow + label after shadow state changes.
-- Called from OnCooldownDone hooks AND CDM Cooldown write hook.
local function DispatchAfterShadowUpdate(frame)
  local cachedCfg = frame._arcCfg
  if not cachedCfg then return end
  local shadowCD     = frame._arcCDMShadowCooldown
  local chargeShadow = frame._arcCDMChargeShadow
  -- When isOnGCD=true we already set _arcLastShadowShown=false explicitly.
  -- Don't overwrite with IsShown() — shadow is still physically showing until
  -- OnCooldownDone fires, but we want ReadCooldownState to see ready state now.
  if not frame._arcLastIsOnGCD then
    frame._arcLastShadowShown = shadowCD    and shadowCD:IsShown()    or false
    frame._arcLastChargeShown = chargeShadow and chargeShadow:IsShown() or false
  end
  ns.CDMEnhance.ApplyCooldownStateVisuals(frame, cachedCfg)
  if ns.CDMSpellUsability and ns.CDMSpellUsability.UpdateGlow then
    ns.CDMSpellUsability.UpdateGlow(frame, cachedCfg)
  end
  if frame._arcCLHasText and ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
    ns.CustomLabel.UpdateVisibility(frame)
  end
  -- Dynamic Cooldowns: a charge spell changes its collapse alpha at the depleted
  -- boundary (last charge spent / first charge restored) WITHOUT frame.Cooldown:
  -- IsShown() flipping — the recharge swipe stays up across it — so ns.FrameActive
  -- never fires the layout reflow there. Notify the layout directly (it dedupes on
  -- the rendered-alpha bucket and only acts for frames in a Dynamic Cooldowns group).
  if frame._arcIsChargeSpellCached then
    local DL = ns.CDMGroups and ns.CDMGroups.DynamicLayout
    if DL and DL.NotifyCooldownCollapseChanged then
      DL.NotifyCooldownCollapseChanged(frame)
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- POSTGCD RE-PUSH (Arc's experiment, CDM twin of the arc-icon version): when
-- a shadow feed runs while a GCD is up, the filtered (ignoreGCD) reads can be
-- transiently wrong — the client may have re-bucketed a real remaining
-- cooldown under the GCD. Accept the filtered result now and schedule ONE
-- settled re-feed for the moment the GCD ends: it refreshes the state shadow
-- (+ visuals dispatch) AND re-pushes the visible widget the way the GCDFilter
-- hook would (No-GCD frames only; aura/item/override-owned frames excluded).
-- Chained GCDs re-arm until a clean window. One timer per frame per GCD
-- window, zero idle cost.
-- ═══════════════════════════════════════════════════════════════════════════
local function PostGCDRefresh(frame)
  frame._arcPostGCDQueued = nil
  if not frame._arcEnhanced then return end
  local cfg = frame._arcCfg
  if not cfg then return end
  -- Settled state re-feed + visuals
  if ns.CooldownState.FeedShadow then
    ns.CooldownState.FeedShadow(frame, cfg)
  end
  -- STATE FLAGS FROM LIVE IsShown(): the dispatch below deliberately skips
  -- refreshing _arcLastShadowShown while _arcLastIsOnGCD is set — and at high
  -- APM the NEXT cast's GCD is already running at this re-feed moment, so the
  -- cached flags stayed stale and the CDM desat lagged the arc icon's (which
  -- reads IsShown live). This re-feed IS the settled read: write the flags
  -- from the freshly-fed shadows directly, then dispatch.
  local shadowCD     = frame._arcCDMShadowCooldown
  local chargeShadow = frame._arcCDMChargeShadow
  frame._arcLastShadowShown = shadowCD    and shadowCD:IsShown()    or false
  frame._arcLastChargeShown = chargeShadow and chargeShadow:IsShown() or false
  DispatchAfterShadowUpdate(frame)
  -- Visible widget: re-push the stripped read (mirrors the GCDFilter hook's
  -- own-push body and its skip conditions).
  if frame._arcNoGCDSwipeEnabled and frame.Cooldown
     and not frame._arcDurOvActive and frame.wasSetFromAura ~= true
     and frame._arcViewerType ~= "aura" then
    local ci = frame.cooldownInfo
    if ci and not ci.equipSlot then
      local spellID = ci.overrideSpellID or ci.spellID
      if spellID then
        local durObj
        if frame._arcIsChargeSpellCached and C_Spell.GetSpellChargeDuration then
          durObj = C_Spell.GetSpellChargeDuration(spellID, true)
        end
        if not durObj and C_Spell.GetSpellCooldownDuration then
          durObj = C_Spell.GetSpellCooldownDuration(spellID, true)
        end
        if durObj then
          frame._arcBypassCDHook = true
          frame.Cooldown:SetCooldownFromDurationObject(durObj)
          frame._arcBypassCDHook = false
          if frame._arcPreserveDurationText and ns.CooldownState.PreserveDurationText then
            ns.CooldownState.PreserveDurationText(frame)
          end
        end
      end
    end
  end
end

local function SchedulePostGCDRepush(frame)
  if frame._arcPostGCDQueued then return end
  frame._arcPostGCDQueued = true
  -- Delay = the GCD's actual remaining time (61304's record carries plain
  -- numbers in normal play), with a fixed fallback when unreadable.
  local delay = 0.3
  local cd = C_Spell.GetSpellCooldown(61304)
  if cd then
    local s, d = cd.startTime, cd.duration
    if not (issecretvalue and (issecretvalue(s) or issecretvalue(d)))
       and type(s) == "number" and type(d) == "number" and d > 0 then
      local rem = (s + d) - GetTime()
      if rem > 0 and rem < 2 then delay = rem + 0.05 end
    end
  end
  C_Timer.After(delay, function() PostGCDRefresh(frame) end)
end

local function EnsureShadowCooldown(frame)
  if not frame._arcCDMShadowCooldown then
    frame._arcCDMShadowCooldown = CreateInvisibleCooldown(frame)
    -- Initialize as idle so GlobalCooldownSweep auto-stop works on first pass.
    -- nil means "never evaluated" which the sweep treats as active (keeps ticker running).
    frame._arcLastShadowShown  = false
    frame._arcLastChargeShown  = false
    frame._arcLastIsOnGCD      = false

    -- OnShow/OnHide: skip during feed — _arcFeedingShadow guard prevents cascade.
    -- GCD gate on OnShow only: shadow cleared by GCD, not a real state change.
    -- OnHide: NO GCD gate — natural expiry (DEPLETED→RECHARGING) fires OnHide at
    -- same instant as SPELL_UPDATE_CD [nil] which sets isOnGCD=true. Gating blocks it.
    -- OnCooldownDone: always dispatch, deferred 0.1s (IsShown() not updated yet at fire time).
    local _Track = _G.ArcUIProfiler_Track
    local function shadowOnShow()
      if frame._arcFeedingShadow and frame._arcFeedingShadow > 0 then return end
      if frame._arcLastIsOnGCD then return end
      DispatchAfterShadowUpdate(frame)
    end
    local function shadowOnHide()
      if frame._arcFeedingShadow and frame._arcFeedingShadow > 0 then return end
      DispatchAfterShadowUpdate(frame)
    end
    local function shadowOnDone()
      C_Timer.After(0.1, function() DispatchAfterShadowUpdate(frame) end)
    end
    frame._arcCDMShadowCooldown:HookScript("OnShow",        _Track and _Track("CooldownState.ShadowOnShow",        shadowOnShow)        or shadowOnShow)
    frame._arcCDMShadowCooldown:HookScript("OnHide",        _Track and _Track("CooldownState.ShadowOnHide",        shadowOnHide)        or shadowOnHide)
    frame._arcCDMShadowCooldown:HookScript("OnCooldownDone",_Track and _Track("CooldownState.ShadowOnCooldownDone",shadowOnDone)        or shadowOnDone)

    -- Hook CDM's visible Cooldown:Clear — fires at exact CD expiry moment, very low frequency.
    -- From the log: Cooldown:Clear fires ~16x vs 693 SPELL_UPDATE_COOLDOWN events.
    -- When CDM clears its frame the real CD is done — clear our shadow immediately
    -- and dispatch. This gives us the same timing as CDM without any polling or
    -- event spam. Guard with _arcFeedingShadow to avoid cascade from our own feeds.
    -- Pure events: SPELL_UPDATE_COOLDOWN + UNIT_SPELLCAST_SUCCEEDED.
    -- cat=133 (GCD event) with isOnGCD=true + isOnActualCooldown=false:
    --   real CD is done, clear shadow directly so it expires immediately.
    -- ═══════════════════════════════════════════════════════════════════
    local ef = CreateFrame("Frame")
    frame._arcPerFrameEvFrame = ef
    ef:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    ef:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    -- bag items (potions / healthstones) need the stock count re-read when the
    -- bags change; batched by the client, so this is a rare event
    ef:RegisterEvent("BAG_UPDATE_DELAYED")
    local _TrackEv = _G.ArcUIProfiler_Track
    local function perFrameEventHandler(_, ev, a1, a2, a3, a4, a5)
      if not frame._arcEnhanced then
        ef:UnregisterAllEvents()
        frame._arcPerFrameEvFrame = nil
        return
      end

      -- ITEM ENTRIES (12.1) have no spellID to match on -- a potion entry has
      -- none at all until CDM fills one in on first use -- so they never
      -- reached the feed below and their state never moved. Route them here on
      -- their own signals: SPELL_UPDATE_COOLDOWN carries
      -- (spellID, baseSpellID, spellCategory, startRecoveryCategory, itemID),
      -- so a3 == our spellCategoryID is exactly "this potion family just
      -- changed". Trinkets take any cooldown event (their slot read is cheap).
      local ciEv = frame.cooldownInfo
      local evEquip = ciEv and ciEv.equipSlot
      local evCat   = ciEv and ciEv.spellCategoryID
      -- bag traffic only concerns item entries; never re-dispatch spell frames
      if ev == "BAG_UPDATE_DELAYED" and not (evEquip or evCat) then return end
      if evEquip or evCat then
        if ev == "SPELL_UPDATE_COOLDOWN" or ev == "BAG_UPDATE_DELAYED" then
          -- BAG_UPDATE_DELAYED always matters here: it is how an out-of-stock
          -- potion/healthstone flips back to in-stock (and vice versa)
          local relevant = ev == "BAG_UPDATE_DELAYED" or evEquip ~= nil
            or a1 == nil or a3 == evCat
          if not relevant then return end
          local cfgI = frame._arcCfg
          if cfgI then
            ns.CooldownState.FeedShadow(frame, cfgI)
            DispatchAfterShadowUpdate(frame)
          end
        end
        return
      end
      -- Build the full set of spellIDs this frame can respond to:
      --   _arcCachedSpellID   — set at enhancement time and updated by override handler
      --   overrideSpellID     — live from CDM (changes during override windows)
      --   spellID (base)      — always the base spell
      -- Matching any of these means an event for this frame should trigger a feed.
      -- This covers short-lived override spells whose SPELL_UPDATE_COOLDOWN fires
      -- before _arcCachedSpellID has been updated by the override event handler.
      local ci = frame.cooldownInfo
      local baseSpell     = ci and ci.spellID
      local overrideSpell = ci and ci.overrideSpellID
      local cachedSpell   = frame._arcCachedSpellID
      -- Primary spellID for FeedShadow (prefer live override, then cached, then base)
      local spellID = overrideSpell or cachedSpell or baseSpell
      if not spellID then return end

      if ev == "SPELL_UPDATE_COOLDOWN" then
        -- CDM DIET (DesatLab-proven 2026-08-11): the blanket a3==133 match fed
        -- this frame on EVERY cast's GCD notify, and each feed could consume a
        -- transiently-collapsed ignoreGCD read that cleared a running shadow
        -- ~30ms after every correct desat write (the log showed desat 1 ->
        -- ready 0 flips on every cast). Same rule as the arc-icon zip patch:
        -- GCD notifies only reach frames that RENDER the GCD (charge spells,
        -- or No-GCD filtering off). Own-spell + bulk updates still cover
        -- every real cooldown change; POSTGCD corrects the rest.
        local gcdEventRelevant = (a3 == 133)
          and (frame._arcIsChargeSpellCached == true or frame._arcNoGCDSwipeEnabled ~= true)
        local matches = (a1 == nil)
                     or (a1 == cachedSpell)
                     or (a1 == overrideSpell)
                     or (a1 == baseSpell)
                     or (a2 == cachedSpell)
                     or (a2 == overrideSpell)
                     or (a2 == baseSpell)
                     or gcdEventRelevant
        if not matches then return end
        -- cat=133: GCD event. If CDM already resolved real CD as done, clear
        -- shadow directly so it expires now rather than waiting for OnCooldownDone.
        -- SECRECY: isOnGCD/isOnActualCooldown can be SECRET booleans in
        -- restricted contexts (proven by a live error on the GCDFilter's read
        -- of the same fields) - comparing a secret throws. Read through an
        -- issecretvalue gate; when secret, this fast-path simply doesn't run.
        local fOnGCD, fOnActual = frame.isOnGCD, frame.isOnActualCooldown
        if issecretvalue and (issecretvalue(fOnGCD) or issecretvalue(fOnActual)) then
          fOnGCD, fOnActual = nil, nil
        end
        if a3 == 133 and fOnGCD == true and fOnActual == false then
          local shadow = frame._arcCDMShadowCooldown
          if shadow and shadow:IsShown() then
            -- Non-charge frames (DesatLab-proven): this claim fires during
            -- the tail re-bucketing transient too — instant clears here
            -- reverted every desat write within ~30ms. Schedule the settled
            -- POSTGCD re-feed instead: a genuine CDR-completion resolves at
            -- the GCD boundary; a transient never blips. Charge frames keep
            -- the instant clear (their recharge model has no GCD race).
            if not frame._arcIsChargeSpellCached then
              SchedulePostGCDRepush(frame)
              return
            end
            frame._arcFeedingShadow = (frame._arcFeedingShadow or 0) + 1
            CooldownFrame_Clear(shadow)
            frame._arcFeedingShadow = frame._arcFeedingShadow - 1
            frame._arcLastShadowShown = false
            frame._arcLastIsOnGCD     = true
            local cfg = frame._arcCfg
            if cfg then DispatchAfterShadowUpdate(frame) end
          end
          return
        end
      elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
        if a3 ~= cachedSpell and a3 ~= overrideSpell and a3 ~= baseSpell then return end
        -- IGNORE HARD ICD discriminator: sample the PRE-cast shadow state before
        -- the feed below refreshes it. For a 2-charge spell the inference is exact
        -- (player casts are non-secret everywhere):
        --   cast from FULL (neither shadow shown)      -> 1 charge left -> ICD, not zero
        --   cast from RECHARGING (charge shadow only)  -> 0 charges     -> true depletion
        -- The flag makes ReadCooldownState keep DEPLETED (desat, no charge glow) for
        -- a genuine zero instead of remapping it to RECHARGING. Cleared there when
        -- the both-shown window ends. 3+ charge spells stay ambiguous mid-band, so
        -- the flag is only ever set for maxCharges == 2 (all known hard-ICD spells).
        if frame._arcIgnoreHardICD and frame._arcIsChargeSpellCached
           and frame._arcMaxChargesCached == 2 then
          local sCD = frame._arcCDMShadowCooldown
          local sCh = frame._arcCDMChargeShadow
          local wasOnCD      = sCD and sCD:IsShown() or false
          local wasRecharging = sCh and sCh:IsShown() or false
          if not wasOnCD then
            frame._arcICDCastToZero = wasRecharging or nil
          end
          -- cast observed while both already shown (latency edge): keep prior flag
        end
      end

      local cfg = frame._arcCfg
      if cfg then
        ns.CooldownState.FeedShadow(frame, cfg)
        DispatchAfterShadowUpdate(frame)
      end
    end
    ef:SetScript("OnEvent", _TrackEv and _TrackEv("CooldownState.PerFrameEvent", perFrameEventHandler) or perFrameEventHandler)

    -- Hook OnSpellUpdateCooldownEvent: CDM calls this AFTER it processes
    -- SPELL_UPDATE_COOLDOWN and updates frame.isOnGCD. Frame fields are current here.
    -- If isOnGCD=true and shadow is shown, real CD is done and only GCD remains.
    -- Clear the shadow immediately — fixes CDR-induced delay where DurationObject
    -- expires after the spell actually came off CD.
    if frame.OnSpellUpdateCooldownEvent and not frame._arcOnCDEventHooked then
      frame._arcOnCDEventHooked = true
      hooksecurefunc(frame, "OnSpellUpdateCooldownEvent", function(self)
        -- SECRECY: isOnGCD can be a SECRET boolean in restricted contexts -
        -- comparing a secret throws. Gate the read; secret = skip fast-path.
        local sOnGCD = self.isOnGCD
        if issecretvalue and issecretvalue(sOnGCD) then return end
        if sOnGCD ~= true then return end
        local shadow = self._arcCDMShadowCooldown
        if not shadow or not shadow:IsShown() then return end
        -- Non-charge frames (DesatLab-proven): CDM's GCD claim also fires
        -- during the tail transient — clearing on it was the second desat-
        -- revert vector. Boundary-correct via POSTGCD instead of trusting it.
        if not self._arcIsChargeSpellCached then
          SchedulePostGCDRepush(self)
          return
        end
        self._arcFeedingShadow = (self._arcFeedingShadow or 0) + 1
        CooldownFrame_Clear(shadow)
        self._arcFeedingShadow = self._arcFeedingShadow - 1
        self._arcLastShadowShown = false
        self._arcLastIsOnGCD = true
        local cfg = self._arcCfg
        if cfg then DispatchAfterShadowUpdate(self) end
      end)
    end
  end

  -- IAO: fight CDM's continuous aura duration pushes.
  -- CDM calls SetCooldown on every refresh cycle with the aura duration.
  -- HandleIgnoreAuraOverride only fires from events — between events CDM
  -- wins → flicker. Hook SetCooldown and re-push the spell CD when IAO is
  -- active and aura is present.
  if frame.Cooldown and not frame._arcIAOCDHooked then
    frame._arcIAOCDHooked = true

    local function IAOFight(self)
      local pf = self._arcParentFrame
      if not pf then return end
      if pf._arcBypassCDHook then return end
      if not pf._arcIgnoreAuraOverride then return end

      -- ITEM ENTRIES: the spell durObj below is zero-span for a trinket and
      -- absent for a potion, so re-push the item's own window instead. Same
      -- fight, different source.
      local ciF = pf.cooldownInfo
      if ciF and (ciF.equipSlot or ciF.spellCategoryID) then
        if ns.CooldownState.PushItemIAO then ns.CooldownState.PushItemIAO(pf) end
        return
      end
      -- wasSetFromAura=true: CDM is actively displaying aura duration on the swipe.
      -- _arcAuraActive just means an aura instance exists — CDM may not be showing it.
      local isAuraNow = (pf.wasSetFromAura == true) or (pf.totemData ~= nil)
      if not isAuraNow then return end
      local ci = pf.cooldownInfo
      local spellID = ci and (ci.overrideSpellID or ci.spellID)
      if not spellID then return end

      -- Just push the durObj. ignoreGCD follows user setting:
      --   noGCDSwipe=false: durObj includes GCD → GCD swipe shows normally
      --   noGCDSwipe=true:  durObj excludes GCD → zero-span during GCD-only,
      --                     engine auto-hides; real CD animates when present
      -- Either way, zero-span when truly ready → engine hides. No trulyOnCD
      -- fallback chain needed — the durObj encodes the correct state.
      local ignoreGCD = pf._arcNoGCDSwipeEnabled and true or false
      local pushObj
      if pf._arcIsChargeSpellCached and C_Spell.GetSpellChargeDuration then
        pushObj = C_Spell.GetSpellChargeDuration(spellID, ignoreGCD)
      end
      if not pushObj and C_Spell.GetSpellCooldownDuration then
        pushObj = C_Spell.GetSpellCooldownDuration(spellID, ignoreGCD)
      end
      if not pushObj then return end

      pf._arcBypassCDHook = true
      self:SetUseAuraDisplayTime(false)
      self:SetCooldownFromDurationObject(pushObj, true)
      pf._arcBypassCDHook = false
      -- The push above rebuilt CDM's countdown FontString, and the global
      -- preserve re-apply hook SKIPPED it (it ignores bypassed pushes). Without
      -- an explicit re-float here, preserved duration text binds to the dimmed
      -- frame alpha until the next dispatch — the intermittent "Preserve
      -- Duration Text flicker" on IAO icons. Worst on totem-linked CDs
      -- (Fire/Storm Elemental): totemData keeps this fight firing on every
      -- CDM refresh even when CDM isn't actually overriding the cooldown.
      if pf._arcPreserveDurationText then
        PreserveDurationText(pf)
      end
    end

    hooksecurefunc(frame.Cooldown, "SetCooldown", IAOFight)
  end

  -- Only create charge shadow for charge spells (saves frame creation + feed cost)
  if frame._arcIsChargeSpellCached and not frame._arcCDMChargeShadow then
    frame._arcCDMChargeShadow = CreateInvisibleCooldown(frame)

    -- Same pattern as main shadow: skip during feed to avoid clear-first cascade.
    -- No GCD gate — charge state changes are always real.
    local _Track2 = _G.ArcUIProfiler_Track
    local function chargeOnShow()
      if frame._arcFeedingShadow and frame._arcFeedingShadow > 0 then return end
      DispatchAfterShadowUpdate(frame)
    end
    local function chargeOnHide()
      if frame._arcFeedingShadow and frame._arcFeedingShadow > 0 then return end
      DispatchAfterShadowUpdate(frame)
    end
    local function chargeOnDone()
      C_Timer.After(0.1, function() DispatchAfterShadowUpdate(frame) end)
    end
    frame._arcCDMChargeShadow:HookScript("OnShow",        _Track2 and _Track2("CooldownState.ChargeOnShow",        chargeOnShow) or chargeOnShow)
    frame._arcCDMChargeShadow:HookScript("OnHide",        _Track2 and _Track2("CooldownState.ChargeOnHide",        chargeOnHide) or chargeOnHide)
    frame._arcCDMChargeShadow:HookScript("OnCooldownDone",_Track2 and _Track2("CooldownState.ChargeOnCooldownDone",chargeOnDone) or chargeOnDone)

    -- SPELL_UPDATE_CHARGES removed — simple 2-event approach (SPELL_UPDATE_COOLDOWN
    -- + UNIT_SPELLCAST_SUCCEEDED) with SetCooldown(0,0) before DurationObject feed
    -- handles all cases including proc CDR and charge resets cleanly.
  end

  return frame._arcCDMShadowCooldown, frame._arcCDMChargeShadow
end

-- Feed shadow frames. 4-state method validated by /cdmshadow2:
--   Both durObj APIs called with ignoreGCD=true so the feed itself is
--   GCD-free. No isOnGCD branching, no SetCooldown(0,0) clear dance
--   (which is banned in 12.0.1 with secret values anyway).
--   State classifier (GetBinaryCooldownState): pure IsShown() on both frames.
--     mainShown=false, chargeShown=false → READY
--     mainShown=true,  chargeShown=false → ON COOLDOWN (normal spell)
--     mainShown=false, chargeShown=true  → RECHARGING (charge avail)
--     mainShown=true,  chargeShown=true  → DEPLETED (all charges gone)
--   For normal spells GetSpellChargeDuration returns zero-span, so the
--   charge shadow stays hidden automatically — same code path as charge spells.
-- 12.1: item cooldown APIs report the ~1.5s GCD as the item CD during a GCD; anything
-- <= this is GCD/windup noise (real item CDs are >>1.5s). Mirrors Arc Auras' threshold.
local ITEM_GCD_THRESHOLD = 1.5
FeedShadowCooldown = function(frame, spellID)
  -- 12.1 item branch: item cooldowns are not spell cooldowns, so the spell APIs
  -- return zero-span for them. Two flavours, both keyed off cooldownInfo:
  --
  --   equipSlot        -> TRINKET. GetInventoryItemCooldown on the slot.
  --   spellCategoryID  -> BAG ITEM (combat potion 4, health potion 30,
  --                       healthstone 1711, demonic healthstone 2566). These
  --                       entries ship with NO spellID at all -- CDM fills
  --                       cooldownInfo.spellID / lastItemIDForCategory in
  --                       UpdateFromSpellCategory the first time an item of
  --                       that category is used. So: read the item's cooldown
  --                       when we know the item, else the spell CDM learned,
  --                       else treat as ready. (Blizzard's own item path is
  --                       equip-slot only -- their source carries the "TODO:
  --                       Support potions as well" note -- which is why these
  --                       icons never dimmed or dropped their ready glow.)
  --
  -- Both run even with a nil spellID, which is the normal state for a potion
  -- entry that has not been used yet this session.
  local ci = frame.cooldownInfo
  local eqSlot = ci and ci.equipSlot
  local catID  = ci and ci.spellCategoryID
  if eqSlot or catID then
    if frame._arcFeedingShadow and frame._arcFeedingShadow > 0 then return end
    frame._arcFeedingShadow = (frame._arcFeedingShadow or 0) + 1
    frame._arcLastIsOnGCD = false
    frame._arcIsChargeSpellCached = false
    local shadowCD = EnsureShadowCooldown(frame)
    if shadowCD then
      -- secret-proof identity: live fields when readable (refreshes the
      -- per-frame plain-number cache), the cache when they read SECRET
      -- (restricted contexts: instances + 12.1 restricted open-world
      -- events). The APIs below reject secret ARGUMENTS but return plain
      -- numbers, so the cached identity keeps full cooldown fidelity there.
      local itemID, catSpellID = ns.CooldownState.GetItemIdentity(frame, ci)
      local start, dur
      if eqSlot then
        start, dur = GetInventoryItemCooldown("player", eqSlot)
      else
        if itemID and C_Item and C_Item.GetItemCooldown then
          start, dur = C_Item.GetItemCooldown(itemID)
        end
      end
      -- Keep the live window for the IAO push: these are ABSOLUTE times, so a
      -- pair read a moment ago still describes the same cooldown exactly.
      if start and dur and start > 0 and dur > ITEM_GCD_THRESHOLD then
        frame._arcItemCDStart, frame._arcItemCDDur = start, dur
      else
        frame._arcItemCDStart, frame._arcItemCDDur = nil, nil
      end
      if start and dur and start > 0 and dur > ITEM_GCD_THRESHOLD then
        shadowCD:SetCooldown(start, dur)
      elseif catID and catSpellID and C_Spell.GetSpellCooldownDuration then
        -- category entry with a spell CDM resolved on first use: the durObj is
        -- the secret-safe read (ignoreGCD so a bare GCD never reads as a CD)
        local durObj = C_Spell.GetSpellCooldownDuration(catSpellID, true)
        if durObj then
          shadowCD:SetCooldownFromDurationObject(durObj, true)
        else
          shadowCD:Clear()
        end
      else
        shadowCD:Clear()
      end
    end
    frame._arcFeedingShadow = frame._arcFeedingShadow - 1
    return
  end

  if not spellID then return end
  if frame._arcFeedingShadow and frame._arcFeedingShadow > 0 then return end
  frame._arcFeedingShadow = (frame._arcFeedingShadow or 0) + 1

  -- SPELL CHANGE DETECTION: When CDM reassigns a frame to a different spell
  -- (via layout manager / Pools recycle), the shadow still has the OLD spell's
  -- cooldown timer. Invalidate cache so state-change detection doesn't skip
  -- visuals, and kill any stale ready glow from the previous spell immediately.
  local prevSpellID = frame._arcShadowFedSpellID
  if prevSpellID and prevSpellID ~= spellID then
    frame._arcLastShadowShown = false
    frame._arcLastChargeShown = false
    if frame._arcReadyGlowActive and ns.CDMEnhance and ns.CDMEnhance.HideReadyGlow then
      ns.CDMEnhance.HideReadyGlow(frame)
    end
  end
  frame._arcShadowFedSpellID = spellID

  -- Read isOnGCD and isChargeSpell for downstream consumers (DispatchAfterShadowUpdate,
  -- IAOFight, ReadCooldownState all read _arcLastIsOnGCD; charge shadow creation
  -- gate reads _arcIsChargeSpellCached). Feed itself does NOT branch on either.
  local cdInfo     = C_Spell.GetSpellCooldown(spellID)
  local isOnGCD    = cdInfo and cdInfo.isOnGCD == true
  local chargesInfo = C_Spell.GetSpellCharges(spellID)
  local isChargeSpell = chargesInfo ~= nil and chargesInfo.maxCharges ~= nil and chargesInfo.maxCharges > 1

  -- Cache BEFORE EnsureShadowCooldown — charge shadow is only created when
  -- _arcIsChargeSpellCached is true, so it must be set before EnsureShadow runs.
  frame._arcLastIsOnGCD         = (isOnGCD == true)
  frame._arcIsChargeSpellCached = isChargeSpell
  frame._arcMaxChargesCached    = chargesInfo and chargesInfo.maxCharges or nil

  local shadowCD, chargeShadow = EnsureShadowCooldown(frame)

  -- MAIN shadow: feed GCD-stripped cooldown duration unconditionally.
  -- ignoreGCD=true makes the durObj exclude GCD, so during a pure-GCD
  -- moment (no real CD) the durObj is zero-span and the shadow stays
  -- hidden — exactly the binary signal we want.
  if C_Spell.GetSpellCooldownDuration then
    local durObj = C_Spell.GetSpellCooldownDuration(spellID, true)
    if durObj then
      shadowCD:SetCooldownFromDurationObject(durObj, true)
    else
      shadowCD:Clear()
    end
  end

  -- CHARGE shadow: same treatment. Zero-span for non-charge spells → hidden.
  if chargeShadow and C_Spell.GetSpellChargeDuration then
    local durObj = C_Spell.GetSpellChargeDuration(spellID, true)
    if durObj then
      chargeShadow:SetCooldownFromDurationObject(durObj, true)
    else
      chargeShadow:Clear()
    end
  end

  frame._arcFeedingShadow = frame._arcFeedingShadow - 1

  -- POSTGCD: this feed ran while a GCD was up — the filtered reads may be
  -- transiently wrong (tail re-bucket). Schedule ONE settled re-feed for the
  -- moment the GCD ends (see SchedulePostGCDRepush above). Mirrors the
  -- arc-icon trigger: non-charge frames only.
  if isOnGCD and not isChargeSpell then
    SchedulePostGCDRepush(frame)
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- BINARY STATE DETECTION via dual shadow cooldown frames
-- ═══════════════════════════════════════════════════════════════════
local function GetBinaryCooldownState(frame)
  -- Read both shadows independently — never gate one on the other.
  -- DEPLETED:   mainShown=true,  chargeShown=true  (0 charges, recharging)
  -- RECHARGING: mainShown=false, chargeShown=true  (1+ charges, recharging)
  -- ON_CD:      mainShown=true,  chargeShown=false (non-charge spell on cooldown)
  -- FULL/READY: mainShown=false, chargeShown=false
  local shadowCD    = frame._arcCDMShadowCooldown
  local chargeShadow = frame._arcCDMChargeShadow
  local isOnCooldown = shadowCD    and shadowCD:IsShown()    or false
  local isRecharging = chargeShadow and chargeShadow:IsShown() or false
  return isOnCooldown, isRecharging
end

-- ReadCooldownState: reads only cached values — no live API calls.
-- isOnGCD:       written by FeedShadowCooldown (runs first every dispatch cycle).
-- isChargeSpell: written by FeedShadowCooldown (updated every feed, so linked-spell
--                frames that swap spells always reflect the current spell's charge type).
-- GetBinaryCooldownState: reads shadow IsShown() — always non-secret, zero API cost.
local function ReadCooldownState(frame, spellID)
  local isOnGCD       = frame._arcLastIsOnGCD         or false
  local isChargeSpell = frame._arcIsChargeSpellCached or false
  local isOnCooldown, isRecharging = GetBinaryCooldownState(frame)
  -- IGNORE HARD ICD (per-icon opt-in, e.g. Monk Zenith 1249625: 2 charges, 70s
  -- recharge, 16s hard ICD per cast): some charge spells start a REAL spell
  -- cooldown alongside the recharge, making main+charge both shown — which this
  -- model otherwise reads as DEPLETED (full desat) while a charge is in hand.
  -- With the toggle on, that combination reads RECHARGING instead — UNLESS the
  -- cast-history discriminator (see the SUCCEEDED handler) proved the last cast
  -- spent the final charge (_arcICDCastToZero): a genuine zero keeps DEPLETED so
  -- desaturation and charge glows stay truthful. With no history (login/reload
  -- mid-cooldown) the old remap applies until the first observed cast. Pure
  -- IsShown logic + non-secret player cast events — secret-safe everywhere.
  if not (isOnCooldown and isRecharging) then
    frame._arcICDCastToZero = nil  -- ambiguous window over; next cast re-derives
  end
  if frame._arcIgnoreHardICD and isChargeSpell and isOnCooldown and isRecharging
     and not frame._arcICDCastToZero then
    isOnCooldown = false
  end
  return isOnCooldown, isRecharging, isChargeSpell, isOnGCD
end

-- ═══════════════════════════════════════════════════════════════════
-- USABILITY HELPERS
-- ═══════════════════════════════════════════════════════════════════
local function GetUsabilityAlpha(frame, spellID, cfg)
  if not spellID then return nil, false end
  local su = cfg and cfg.spellUsability
  if not su or not su.enabled then return nil, false end
  -- Proc override: if a proc glow is active and the setting is enabled, skip usability dimming
  if frame._arcProcGlowActive and su.procOverride then return nil, false end
  if frame.spellOutOfRange then
    local ri = cfg and cfg.rangeIndicator
    local rangeEnabled = not ri or ri.enabled ~= false
    if rangeEnabled then return nil, false end
  end
  -- Use cached CDM usability state (set by SetVertexColor detector) to avoid
  -- calling IsSpellUsable again — CDM already called it, we just read the result.
  local state = frame._arcCDMUsabilityState
  local isUsable = (state == "USABLE" or state == nil)
  local notEnoughMana = (state == "NOT_MANA")
  if isUsable then return nil, false end
  if notEnoughMana then
    return su.notEnoughResourceAlpha, su.notEnoughResourcePreserveDurationText == true
  else
    return su.notUsableAlpha, su.notUsablePreserveDurationText == true
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
-- DESATURATE WHEN AURA INACTIVE (cooldown icons that track an aura)
-- Force the icon desaturated while the tracked aura is NOT active, superseding
-- whatever the ready/cooldown/usability path just set. Called from EVERY
-- saturating path (the dispatch end AND ApplyReadyState) so usability re-applies
-- on combat entry can't re-saturate it. Routes through the single desat authority
-- (_arcForceDesatValue=1 + SetDesat under bypass) which the icon SetDesaturated/
-- SetDesaturation enforcement hook then pins against CDM (its staleness-clear only
-- touches forceValue==0). Aura presence uses the EXACT SAME signal as the aura-active
-- glow (EvaluateAuraActiveGlow): HasFrameAura(auraInstanceID) reflects the buff
-- dropping immediately (wasSetFromAura LAGS true for a tick after the buff falls,
-- which left the icon coloured), so the desat now triggers the moment the glow does.
-- ═══════════════════════════════════════════════════════════════════
local function ApplyAuraInactiveDesat(frame, iconTex)
  local cfg = frame._arcCfg
  if not (cfg and cfg.auraActiveState and cfg.auraActiveState.desaturateWhenInactive) then return end
  local auraActive = HasFrameAura(frame.auraInstanceID) or (frame.totemData ~= nil)
  if auraActive then return end
  iconTex = iconTex or ResolveIconTexture(frame)
  frame._arcForceDesatValue = 1
  frame._arcBypassDesatHook = true
  SetDesat(iconTex, 1)
  frame._arcBypassDesatHook = false
  if ApplyBorderDesaturation then ApplyBorderDesaturation(frame, 1) end
end

-- "Alpha while aura active" (auraActiveState.activeAlpha): when this spell's OWN CDM aura is
-- active (or a totem occupies the frame), override the ready/cooldown alpha with the user's
-- value so the icon dims/hides while the aura is up. Returns nil when not applicable (normal
-- alpha). The SEPARATE-aura (Duration Override) case is handled in DO.ApplyVisuals -- this
-- frame delegates to it while _arcDurOvActive, so this path never double-applies.
local function AuraActiveAlphaOverride(frame)
  local aa = frame._arcCfg and frame._arcCfg.auraActiveState
  if not (aa and aa.activeAlphaEnabled) then return nil end   -- opt-in; any value (incl. 1) overrides
  -- Use the SAME live signal the aura-active glow uses (HasFrameAura = auraInstanceID ~= nil),
  -- NOT the cached _arcAuraActive flag (often unset/stale -> alpha never applied, ready/cooldown
  -- alpha won). totemData ~= nil is the secret-safe nil-compare for totem frames.
  if HasFrameAura(frame.auraInstanceID) or (frame.totemData ~= nil) then
    return aa.activeAlpha or 1
  end
  return nil
end

-- ═══════════════════════════════════════════════════════════════════
-- APPLY READY STATE
-- ═══════════════════════════════════════════════════════════════════
local function ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlphaOverride, usabilityPreserveText)
  local effectiveReadyAlpha = GetEffectiveReadyAlpha(stateVisuals)
  if usabilityAlphaOverride then
    effectiveReadyAlpha = usabilityAlphaOverride
  end
  -- Proc override: if a proc glow is active and the setting is enabled, show at full alpha
  if frame._arcProcGlowActive and stateVisuals and stateVisuals.readyProcOverride then
    effectiveReadyAlpha = 1.0
  end
  local aaAlpha = AuraActiveAlphaOverride(frame)
  if aaAlpha then effectiveReadyAlpha = aaAlpha end
  effectiveReadyAlpha = PreviewClampAlpha(effectiveReadyAlpha)
  frame._arcTargetAlpha = nil
  if effectiveReadyAlpha < 1.0 then
    frame._arcEnforceReadyAlpha = true
    frame._arcReadyAlphaValue = effectiveReadyAlpha
  else
    frame._arcEnforceReadyAlpha = false
    frame._arcReadyAlphaValue = nil
  end
  if frame._lastAppliedAlpha ~= effectiveReadyAlpha then
    frame._arcBypassFrameAlphaHook = true
    frame:SetAlpha(effectiveReadyAlpha)
    frame._arcBypassFrameAlphaHook = false
    frame._lastAppliedAlpha = effectiveReadyAlpha
  end
  frame._arcDesatBranch = frame._arcDesatBranch or "READY"
  frame._arcForceDesatValue = nil
  -- 3.6.6: Affirmatively restore icon saturation on READY transition.
  -- Some charge spells (e.g. Avenging Wrath 358267) trigger a short post-cast
  -- lockout (~250ms mini-CD on the visible Cooldown widget). CDM calls
  -- Icon:SetDesaturated(true) when its widget gets that timer, but it never
  -- calls SetDesaturated(false) on expiry because cooldownInfo.isActive stays
  -- true while the next charge is still recharging — so our hook can't catch
  -- a call that never fires. Restore here on the genuine READY transition
  -- detected by ReadCooldownState. Idempotent and safe: if the icon is
  -- already colored this is a visual no-op. Bypasses our own desat hook so
  -- we don't loop, and skips when usability has explicitly requested desat.
  if iconTex and iconTex.SetDesaturation and not frame._arcUsabilityDesatRequest then
    frame._arcBypassDesatHook = true
    iconTex:SetDesaturation(0)
    frame._arcBypassDesatHook = false
  end
  ApplyBorderDesaturation(frame, 0)
  frame:Show()
  -- When a usability state (not enough resource / not usable) requests preserve
  -- duration text, honour it the same way cooldown state does: keep countdown
  -- and charge text visible at full alpha even though the icon is dimmed/hidden.
  if usabilityPreserveText and usabilityAlphaOverride and usabilityAlphaOverride < 1.0 then
    frame._arcPreserveDurationText = true
    if frame.Cooldown then
      frame.Cooldown:SetAlpha(1)
    end
    PreserveDurationText(frame)
  else
    frame._arcPreserveDurationText = false
    ResetDurationText(frame)
  end
  -- Aura-inactive desat wins over the ready/usability saturation just applied.
  ApplyAuraInactiveDesat(frame, iconTex)
end

-- ═══════════════════════════════════════════════════════════════════
-- APPLY COOLDOWN STATE ALPHA
-- ═══════════════════════════════════════════════════════════════════
local function ApplyCooldownAlpha(frame, stateVisuals)
  local cdAlpha = stateVisuals.cooldownAlpha or 1.0
  -- Proc override: if a proc glow is active and the setting is enabled, show at full alpha
  if frame._arcProcGlowActive and stateVisuals.cooldownProcOverride then
    cdAlpha = 1.0
  end
  local aaAlpha = AuraActiveAlphaOverride(frame)
  if aaAlpha then cdAlpha = aaAlpha end
  cdAlpha = PreviewClampAlpha(cdAlpha)
  frame._arcEnforceReadyAlpha = false
  frame._arcReadyAlphaValue = nil
  frame._arcTargetAlpha = cdAlpha
  if frame._lastAppliedAlpha ~= cdAlpha then
    frame._arcBypassFrameAlphaHook = true
    frame:SetAlpha(cdAlpha)
    frame._arcBypassFrameAlphaHook = false
    frame._lastAppliedAlpha = cdAlpha
  end

  -- Preserve duration text: keep countdown + charge text visible even when
  -- frame is dimmed/hidden. This is the WHOLE POINT of the feature — text
  -- stays readable at full opacity while the icon fades to cooldownAlpha.
  -- Arc Auras applies preserve unconditionally regardless of alpha.
  frame._arcPreserveDurationText = stateVisuals.preserveDurationText == true
  if stateVisuals.preserveDurationText then
    -- Cooldown widget must be at alpha 1 so its child text can be visible.
    -- The frame itself is at cdAlpha (possibly 0), but IgnoreParentAlpha
    -- on the FontStrings makes them ignore the entire parent alpha chain.
    if frame.Cooldown then
      frame.Cooldown:SetAlpha(1)
    end
    PreserveDurationText(frame)
  else
    if frame.Cooldown then
      if frame.Cooldown.SetIgnoreParentAlpha then
        frame.Cooldown:SetIgnoreParentAlpha(false)
      end
    end
    ResetDurationText(frame)
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- APPLY COOLDOWN DESATURATION
-- ═══════════════════════════════════════════════════════════════════
local function ApplyCooldownDesat(frame, iconTex, stateVisuals, hasActiveAuraDisplay, isRecharging)
  if hasActiveAuraDisplay then
    frame._arcForceDesatValue = 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 0)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, 0)
  elseif stateVisuals.noDesaturate then
    frame._arcForceDesatValue = 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, 0)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, 0)
  else
    -- OWN THE ICON DESAT (was: release to CDM's native desat via
    -- _arcForceDesatValue = nil). DesatLab proof (2026-08-11): CDM's own
    -- cooldownDesaturated state goes SECRET on enhanced frames (a tainted
    -- CDM run stores a secret into its own state), so Blizzard's
    -- SetDesaturated writes become secret-valued and never render — the CDM
    -- icon stayed bright while the arc icon desatted. Drive the icon desat
    -- from OUR non-secret shadow state instead, mirroring the IAO branch:
    -- ON-CD / DEPLETED (main shadow shown) desaturates; RECHARGING with a
    -- charge in hand (main hidden) stays colored. _arcForceDesatValue lets
    -- the enforcement hook re-assert over Blizzard's plain/secret writes.
    local shadowCD = frame._arcCDMShadowCooldown
    local desatVal = (shadowCD and shadowCD:IsShown()) and 1 or 0
    frame._arcForceDesatValue = desatVal
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, desatVal)
    frame._arcBypassDesatHook = false
    ApplyBorderDesaturation(frame, desatVal)
  end
end

local function ApplyReadyGlow(frame, stateVisuals)
  if ShouldShowReadyGlow(stateVisuals, frame) then
    ShowReadyGlow(frame, stateVisuals)
  else
    HideReadyGlow(frame)
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- 12.1 ITEM COOLDOWN STATE
--   trinkets        -> cooldownInfo.equipSlot
--   potions/stones  -> cooldownInfo.spellCategoryID (bag items)
-- Spell cooldown APIs return zero-span for item cooldowns, so we feed the shadow from
-- the item APIs (non-secret, in-combat-safe) and apply ICON-only state
-- visuals (alpha/desat/ready-glow). We deliberately do NOT call DecideAndApplySwipeEdge
-- — CDM owns the visible swipe for item cooldowns.
-- ═══════════════════════════════════════════════════════════════════
-- IGNORE AURA OVERRIDE on an item icon: while the item's BUFF is up, CDM
-- pushes the aura's duration onto the swipe (CheckCacheCooldownValuesFromAura
-- wins over the cooldown source, in ITEM_AURA_COLOR). With the option on the
-- user wants the item's COOLDOWN there instead, so re-push our own window.
-- Item cooldowns are plain non-secret numbers, so SetCooldown is legal here
-- (the 12.0.1 ban is on feeding it SECRET values).
local function PushItemIAO(frame)
  local cd = frame.Cooldown
  if not cd then return end
  if frame._arcBypassCDHook then return end
  -- only fight while CDM is actually showing the aura on the swipe
  if frame.wasSetFromAura ~= true then return end
  local st, du = frame._arcItemCDStart, frame._arcItemCDDur
  frame._arcBypassCDHook = true
  cd:SetUseAuraDisplayTime(false)
  if st and du then
    cd:SetCooldown(st, du)
  else
    -- buff up, item not on cooldown: showing nothing beats showing the
    -- duration the option exists to hide
    cd:Clear()
  end
  frame._arcBypassCDHook = false
end
ns.CooldownState.PushItemIAO = PushItemIAO

-- Blizzard's own fallback item per bag-item category (spellCategoryMetadataLookup).
-- Potions have none -- their identity only exists once one has been used -- so
-- out-of-stock is only knowable for them after that.
local CATEGORY_FALLBACK_ITEM = {
  [1711] = 5512,    -- Healthstone
  [2566] = 224464,  -- Demonic Healthstone
}

-- BAG-ITEM IDENTITY, secret-proof (the _arcSpellID pattern): cooldownInfo's
-- lastItemIDForCategory / spellID go SECRET in restricted contexts (instances
-- AND 12.1 restricted open-world events -- the Prey Hunts crash), and every
-- consumer API rejects secret ARGUMENTS ("AllowedWhenUntainted") while their
-- RETURNS stay plain numbers. So: whenever the live fields are readable,
-- refresh a per-frame PLAIN-NUMBER cache; when they read secret, serve the
-- cache -- identity doesn't change under restriction (and category cooldowns
-- are shared, so even a same-category stale item reads the right cooldown).
-- Full swipe/dim/glow/stock/tooltip fidelity in combat and keys, exactly like
-- the spell icons. Exported: CDMEnhance's tooltip forwarder uses it too.
local function GetItemIdentity(frame, ci)
  if not (frame and ci) then return nil, nil end
  local itemID, spellID = ci.lastItemIDForCategory, ci.spellID
  if itemID then
    if issecretvalue and issecretvalue(itemID) then
      itemID = frame._arcItemIDCache
    else
      frame._arcItemIDCache = itemID
    end
  else
    itemID = frame._arcItemIDCache
  end
  if spellID then
    if issecretvalue and issecretvalue(spellID) then
      spellID = frame._arcItemSpellIDCache
    else
      frame._arcItemSpellIDCache = spellID
    end
  else
    spellID = frame._arcItemSpellIDCache
  end
  return itemID, spellID
end
ns.CooldownState.GetItemIdentity = GetItemIdentity

-- OUT OF STOCK for a CDM bag item, the same question the Arc item icons ask
-- with GetItemCount. Returns nil when we cannot know (no item identity yet),
-- which callers treat as "in stock" rather than dimming on a guess.
-- Identity via the secret-proof cache (GetItemIdentity above): GetItemCount
-- rejects secret arguments but returns plain counts, so the cached plain ID
-- keeps stock detection fully working in restricted contexts.
local function ItemOutOfStock(frame, ci)
  if not ci then return nil end
  local cat = ci.spellCategoryID
  if not cat then return nil end
  local itemID = GetItemIdentity(frame, ci)
  itemID = itemID or CATEGORY_FALLBACK_ITEM[cat]
  if not itemID or not GetItemCount then return nil end
  -- includeCharges=true: a healthstone's stack is charges, not item count
  local count = GetItemCount(itemID, false, true)
  if type(count) ~= "number" then return nil end
  return count <= 0
end

local function HandleItemCooldownState(frame, iconTex, cfg, stateVisuals, ignoreAuraOverride)
  if not stateVisuals then return end
  iconTex = iconTex or frame.Icon
  FeedShadowCooldown(frame, nil)
  local isOnCooldown = GetBinaryCooldownState(frame)
  if ignoreAuraOverride then PushItemIAO(frame) end

  -- AURA ACTIVE, exactly as the cooldown icons read it: HasFrameAura on CDM's
  -- own auraInstanceID (a SECRET id still means the buff EXISTS -- presence is
  -- a nil check, never a compare). Item buffs OVERLAP their cooldown: a potion
  -- runs a 30s buff while a 5 minute cooldown ticks, so this state has to be
  -- evaluated ALONGSIDE the cooldown state, not instead of it. This whole path
  -- previously returned before any aura-active work, which is why "glow when
  -- aura active" never fired on these icons.
  local isAuraActive = HasFrameAura(frame.auraInstanceID) or (frame.totemData ~= nil)

  if isOnCooldown then
    ApplyCooldownAlpha(frame, stateVisuals)   -- already honours activeAlpha
    if isAuraActive then
      -- buff up = icon stays COLOURED, matching the cooldown icons' AURA_READY
      -- rule. We own the value; desat is never released to CDM on an enhanced
      -- frame (its writes are secret-dead and the old value would stick).
      frame._arcDesatBranch = "ITEM_AURA_ACTIVE"
      frame._arcForceDesatValue = 0
      frame._arcBypassDesatHook = true
      SetDesat(iconTex, 0)
      frame._arcBypassDesatHook = false
      frame._arcTargetDesat = 0
      if ApplyBorderDesaturation then ApplyBorderDesaturation(frame, 0) end
    else
      ApplyCooldownDesat(frame, iconTex, stateVisuals, false, false)
    end
  elseif ItemOutOfStock(frame, frame.cooldownInfo) then
    -- ═══════════════════════════════════════════════════════════════
    -- OUT OF STOCK STATE (bag items: potions, healthstones)
    -- A state of its own, with its own alpha / desaturate / tint, because
    -- "none in my bags" is not a cooldown and not an aura. Defaults keep the
    -- long-standing Arc item behaviour: desaturated, normal alpha, no tint --
    -- and the legacy cooldownState.dimWhenEmpty toggle still dims when set.
    -- ═══════════════════════════════════════════════════════════════
    local oos = (cfg and cfg.outOfStockState) or {}
    local cs  = cfg and cfg.cooldownStateVisuals and cfg.cooldownStateVisuals.cooldownState

    if oos.alphaEnabled then
      local a = PreviewClampAlpha(oos.alpha ~= nil and oos.alpha or 1.0)
      frame._arcEnforceReadyAlpha = false
      frame._arcReadyAlphaValue = nil
      frame._arcTargetAlpha = a
      if frame._lastAppliedAlpha ~= a then
        frame._arcBypassFrameAlphaHook = true
        frame:SetAlpha(a)
        frame._arcBypassFrameAlphaHook = false
        frame._lastAppliedAlpha = a
      end
    elseif cs and cs.dimWhenEmpty == true then
      ApplyCooldownAlpha(frame, stateVisuals)
    else
      ApplyReadyState(frame, iconTex, stateVisuals, nil, false)
    end

    local desat = (oos.desaturate ~= false)   -- default ON
    frame._arcDesatBranch = "ITEM_OUT_OF_STOCK"
    frame._arcForceDesatValue = desat and 1 or 0
    frame._arcBypassDesatHook = true
    SetDesat(iconTex, desat and 1 or 0)
    frame._arcBypassDesatHook = false
    frame._arcTargetDesat = desat and 1 or 0
    if ApplyBorderDesaturation then ApplyBorderDesaturation(frame, desat and 1 or 0) end

    if oos.tint and oos.tintColor then
      local c = oos.tintColor
      SetVertexColorSafe(frame, iconTex, c.r or 0.5, c.g or 0.5, c.b or 0.5)
    elseif frame._arcDesiredVertexColor then
      -- SINGLE-WRITER RULE: SetVertexColorSafe does not just paint, it STORES
      -- the colour so the RefreshIconColor hook re-applies it after every CDM
      -- write. Simply not painting leaves that enforcement running, which is
      -- why the tint survived unticking the toggle. Release it AND undo our
      -- last write. Guarded on us having set one, so no other writer's colour
      -- is stomped.
      frame._arcDesiredVertexColor = nil
      if iconTex and iconTex.SetVertexColor then
        iconTex:SetVertexColor(1, 1, 1, 1)
      end
    end
  else
    ApplyReadyState(frame, iconTex, stateVisuals, nil, false)
    -- 12.1: item frames — CDM desaturates the icon when the on-use spell is on the GCD.
    -- ApplyReadyState clears _arcForceDesatValue (passthrough), so CDM's GCD desat leaks
    -- through and the trinket flickers desaturated on every GCD. FORCE saturation here so
    -- the desat hook blocks it — the item cooldown (0/ready right now) is the only thing
    -- that should desaturate a trinket. Cleared again the moment it goes on real CD.
    frame._arcForceDesatValue = 0
  end
  -- READY GLOW IS STATE-GATED, like every other path. ApplyReadyGlow only asks
  -- "is the glow option on?" — it does NOT look at the cooldown, so calling it
  -- unconditionally here left the glow burning through the entire item cooldown
  -- (the alpha/desat branches above were gated, which is why only the glow was
  -- wrong). _arcReadyForGlow is bookkeeping the other paths also write.
  frame._arcReadyForGlow = not isOnCooldown
  if isOnCooldown then
    HideReadyGlow(frame)
  else
    ApplyReadyGlow(frame, stateVisuals)
  end

  -- Aura-active glow (and glow-when-missing) — the same evaluator every
  -- cooldown path calls. Runs last so it owns its own glow key regardless of
  -- what the ready glow above decided.
  EvaluateAuraActiveGlow(frame, cfg)
end

-- ═══════════════════════════════════════════════════════════════════
-- SINGLE SOURCE OF TRUTH: Swipe/Edge decision + apply
--
-- All paths (IAO, CooldownLogic, and the OnCooldownEvent enforcer)
-- call this one function. No decision logic lives anywhere else.
--
-- ownWhenReady = true  → IAO frames: suppress swipe at ready/GCD-show
--                        (prevents aura-duration swipe bleeding through)
-- ownWhenReady = false → Normal CD frames: release to CDM when ready
-- ═══════════════════════════════════════════════════════════════════
local function DecideAndApplySwipeEdge(frame, cfg, isOnCooldown, isRecharging, isChargeSpell, isOnGCD, ownWhenReady)
  if not frame.Cooldown then return end
  local swipeCfg       = cfg.cooldownSwipe
  local userWantsSwipe = not swipeCfg or swipeCfg.showSwipe ~= false
  local userWantsEdge  = not swipeCfg or swipeCfg.showEdge  ~= false
  local noGCDSwipe     = swipeCfg and swipeCfg.noGCDSwipe
  local wantSwipe, wantEdge

  if isChargeSpell then
    local swipeWait    = swipeCfg and swipeCfg.swipeWaitForNoCharges
    local edgeWait     = swipeCfg and swipeCfg.edgeWaitForNoCharges
    local hasWaitFlags = swipeWait or edgeWait
    if isOnCooldown then
      wantSwipe = userWantsSwipe; wantEdge = userWantsEdge
    elseif isRecharging then
      -- Always show swipe when recharging, even if isOnGCD=true.
      -- ArcUI_GCDFilter.lua pushes chargeDurObj to replace GCD duration on visual frame.
      wantSwipe = not swipeWait and userWantsSwipe
      wantEdge  = not edgeWait  and userWantsEdge
    elseif isOnGCD then
      -- Release to nil — ArcUI_GCDFilter.lua owns GCD suppression on the visual frame.
      wantSwipe = nil; wantEdge = nil
    elseif noGCDSwipe or hasWaitFlags or ownWhenReady then
      wantSwipe = false; wantEdge = false
    else
      wantSwipe = nil; wantEdge = nil
    end
  else
    if isOnCooldown then
      wantSwipe = userWantsSwipe; wantEdge = userWantsEdge
    elseif isOnGCD then
      -- Release to nil — ArcUI_GCDFilter.lua owns GCD suppression on the visual frame.
      wantSwipe = nil; wantEdge = nil
    elseif ownWhenReady then
      wantSwipe = false; wantEdge = false
    else
      wantSwipe = nil; wantEdge = nil
    end
  end

  frame._arcDesiredSwipe = wantSwipe
  frame._arcDesiredEdge  = wantEdge
  if wantSwipe ~= nil then
    frame._arcBypassSwipeHook = true
    frame.Cooldown:SetDrawSwipe(wantSwipe)
    frame.Cooldown:SetDrawEdge(wantEdge)
    frame._arcBypassSwipeHook = false
  end
end


-- ═══════════════════════════════════════════════════════════════════
-- PATH A: Ignore Aura Override (binary)
-- ═══════════════════════════════════════════════════════════════════
local function HandleIgnoreAuraOverride(frame, iconTex, cfg, stateVisuals)
  local spellID = ResolveCurrentSpellID(frame, cfg)
  if not spellID then
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

  local isOnCooldown, isRecharging, isChargeSpell, isOnGCD = ReadCooldownState(frame, spellID)

  local waitForNoCharges = isChargeSpell and stateVisuals.waitForNoCharges
  local glowWhileCharges = stateVisuals.glowWhileChargesAvailable

  -- Match HandleCooldownLogic exactly — isOnGCD is not a cooldown state.
  local useCooldownVisuals
  if isOnCooldown then useCooldownVisuals = true
  elseif isChargeSpell and isRecharging then useCooldownVisuals = not waitForNoCharges
  else useCooldownVisuals = false end

  local isGlowEligible
  if isOnCooldown then isGlowEligible = false
  elseif isChargeSpell and isRecharging and not glowWhileCharges then isGlowEligible = false
  else isGlowEligible = true end

  -- Aura presence via CDM's native auraInstanceID — non-secret, always current.
  -- Only fight CDM desat when aura is actually showing on this frame.
  local isAuraActive = HasFrameAura(frame.auraInstanceID) or (frame.totemData ~= nil)

  -- IAO initial push: when wasSetFromAura first becomes true, CDM may not call
  -- SetCooldown again for several seconds. IAOFight waits for SetCooldown — so we
  -- do a one-shot push here to set the timer immediately.
  -- _arcBypassCDHook prevents IAOFight from re-firing on the triggered SetCooldown.
  -- The cascade guard: if we're already inside a bypass (prior push), skip.
  --
  -- ONE-SHOT GUARD (_arcIAOPushKey): this block runs on EVERY dispatch, and each
  -- SetCooldownFromDurationObject rebuilds CDM's countdown FontString — losing the
  -- Preserve Duration Text IgnoreParentAlpha state (with _arcBypassCDHook set, the
  -- re-apply hook skips too). Re-pushing per dispatch made the preserved text
  -- flicker/vanish while the aura was up (Bestial Wrath). Key the push to the real
  -- binary cooldown state: push once per aura window, and again only when the
  -- underlying cooldown genuinely transitions (recast / CD reset mid-aura). The key
  -- is cleared by the dispatcher when the aura window ends. IAOFight still handles
  -- any CDM-initiated re-push of the aura duration.
  --
  -- Just push the durObj. ignoreGCD=true means the durObj encodes zero-span
  -- when spell isn't really on CD → engine auto-hides. No trulyOnCD check.
  if frame._arcIgnoreAuraOverride and frame.wasSetFromAura == true
     and frame.Cooldown and not frame._arcBypassCDHook then
    local pushKey = (isOnCooldown and "C" or "c") .. (isRecharging and "R" or "r")
    if frame._arcIAOPushKey ~= pushKey then
      local ignoreGCD = frame._arcNoGCDSwipeEnabled and true or false
      local pushObj
      if frame._arcIsChargeSpellCached and C_Spell.GetSpellChargeDuration then
        pushObj = C_Spell.GetSpellChargeDuration(spellID, ignoreGCD)
      end
      if not pushObj and C_Spell.GetSpellCooldownDuration then
        pushObj = C_Spell.GetSpellCooldownDuration(spellID, ignoreGCD)
      end
      if pushObj then
        frame._arcBypassCDHook = true
        frame.Cooldown:SetUseAuraDisplayTime(false)
        frame.Cooldown:SetCooldownFromDurationObject(pushObj, true)
        frame._arcBypassCDHook = false
        frame._arcIAOPushKey = pushKey  -- only latch on success; retry next dispatch otherwise
      end
    end
  end

  frame:Show()

  if useCooldownVisuals then
    frame._arcDesatBranch = "IAO_BIN_CD"
    ApplyCooldownAlpha(frame, stateVisuals)
    if not isAuraActive then
      -- No aura — CDM runs normal cooldown, release desat to it
      frame._arcForceDesatValue = nil
    elseif stateVisuals.noDesaturate or (isRecharging and not isOnCooldown) then
      -- RECHARGING (has charges) or noDesaturate: force colored
      frame._arcForceDesatValue = 0
      frame._arcBypassDesatHook = true
      SetDesat(iconTex, 0)
      frame._arcBypassDesatHook = false
      ApplyBorderDesaturation(frame, 0)
    else
      -- ON_CD / DEPLETED with aura: force desaturated
      frame._arcForceDesatValue = 1
      frame._arcBypassDesatHook = true
      SetDesat(iconTex, 1)
      frame._arcBypassDesatHook = false
      ApplyBorderDesaturation(frame, 1)
    end
    if stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
      local col = stateVisuals.cooldownTintColor
      SetVertexColorSafe(frame, iconTex, col.r or 0.5, col.g or 0.5, col.b or 0.5)
    else
      frame._arcDesiredVertexColor = nil
    end
    if isGlowEligible then ApplyReadyGlow(frame, stateVisuals) else HideReadyGlow(frame) end
  else
    frame._arcDesatBranch = "IAO_BIN_READY"
    local usabilityAlpha, usabilityPreserveText = GetUsabilityAlpha(frame, spellID, cfg)
    ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha, usabilityPreserveText)
    if isAuraActive then
      frame._arcForceDesatValue = 0
      frame._arcBypassDesatHook = true
      SetDesat(iconTex, 0)
      frame._arcBypassDesatHook = false
    else
      frame._arcForceDesatValue = nil
    end
    frame._arcDesiredVertexColor = nil
    if isGlowEligible then ApplyReadyGlow(frame, stateVisuals) else HideReadyGlow(frame) end
  end

  -- CHARGE-CONDITIONAL TEXT (hideAtZero / hideWhenHasCharges)
  ApplyChargeConditionalText(frame, cfg, isChargeSpell, isRecharging, isOnCooldown)

  -- SWIPE/EDGE — single source of truth
  DecideAndApplySwipeEdge(frame, cfg, isOnCooldown, isRecharging, isChargeSpell, isOnGCD, true)

  -- AURA ACTIVE GLOW
  EvaluateAuraActiveGlow(frame, cfg)
end


-- ═══════════════════════════════════════════════════════════════════
-- PATH B: Aura Logic (buffs / debuffs / totems)
-- ═══════════════════════════════════════════════════════════════════
local function HandleAuraLogic(frame, iconTex, cfg, stateVisuals)
  frame._arcTargetAlpha = nil
  frame._arcTargetDesat = nil
  frame._arcTargetTint = nil

  local isAuraActive = HasFrameAura(frame.auraInstanceID) or (frame.totemData ~= nil)
  local isCooldownFrame = not cfg._isAura and frame.totemData == nil

  local cdSpellID, cdOnCooldown, cdRecharging, cdIsCharge, cdIsOnGCD
  if isCooldownFrame then
    cdSpellID = ResolveCurrentSpellID(frame, cfg)
    if cdSpellID then
      cdOnCooldown, cdRecharging, cdIsCharge, cdIsOnGCD = ReadCooldownState(frame, cdSpellID)
    end
  end

  -- ALPHA
  if frame._arcTargetAlpha == nil then
    if isCooldownFrame then
      if cdSpellID then
        local isOnGCD, isChargeSpell = cdIsOnGCD, cdIsCharge
        local isOnCooldown, isRecharging = cdOnCooldown, cdRecharging
        local waitForNoCharges = isChargeSpell and stateVisuals.waitForNoCharges
        local useCooldownVisuals
        if isOnCooldown then useCooldownVisuals = true
        elseif isChargeSpell and isRecharging then useCooldownVisuals = not waitForNoCharges
        else useCooldownVisuals = false end
        if not isChargeSpell and isOnGCD then
          local usabilityAlpha, usabilityPreserveText = GetUsabilityAlpha(frame, cdSpellID, cfg)
          ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha, usabilityPreserveText)
        elseif useCooldownVisuals then
          frame:Show()
          ApplyCooldownAlpha(frame, stateVisuals)
        else
          local usabilityAlpha, usabilityPreserveText = GetUsabilityAlpha(frame, cdSpellID, cfg)
          ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha, usabilityPreserveText)
        end
      else
        ApplyReadyState(frame, iconTex, stateVisuals)
      end
    else
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

  -- DESATURATION
  if frame._arcTargetDesat == nil then
    if isCooldownFrame then
      -- Cooldown-viewer frame in its AURA-ACTIVE phase: the aura takes
      -- priority over the shadow — the icon stays COLORED while the buff
      -- runs (IAO is routed upstream and never reaches this branch). The old
      -- "release to CDM native" (_arcForceDesatValue = nil) is DEAD on
      -- enhanced frames (DesatLab: CDM's desat state goes secret, its writes
      -- never render), so the desat our shadow path forced during the earlier
      -- cooldown phase STUCK through the whole aura phase. Own it instead:
      -- actively saturate + enforce, the same ownership rule as the shadow
      -- branch — never hand desat back to CDM.
      frame._arcDesatBranch = "AURA_CD_SATURATE"
      frame._arcForceDesatValue = 0
      frame._arcBypassDesatHook = true
      SetDesat(iconTex, 0)
      frame._arcBypassDesatHook = false
      frame._arcTargetDesat = 0
      ApplyBorderDesaturation(frame, 0)
    else
      if isAuraActive then
        -- Aura active = ready state — no desat needed. CDM agrees so no fight.
        frame._arcDesatBranch = "AURA_READY"
        frame._arcForceDesatValue = nil
        frame._arcTargetDesat = 0
        ApplyBorderDesaturation(frame, 0)
      elseif stateVisuals.cooldownDesaturate then
        -- User explicitly wants desat on cooldown — force it.
        frame._arcDesatBranch = "AURA_CD"
        frame._arcForceDesatValue = 1
        frame._arcBypassDesatHook = true
        SetDesat(iconTex, 1)
        frame._arcBypassDesatHook = false
        frame._arcTargetDesat = 1
        ApplyBorderDesaturation(frame, 1)
      else
        -- No user desat option — release to CDM entirely.
        frame._arcDesatBranch = "AURA_CD_NATIVE"
        frame._arcForceDesatValue = nil
        frame._arcTargetDesat = -1
      end
    end
  end

  -- TINT
  if frame._arcTargetTint == nil then
    if isCooldownFrame then
      frame._arcDesiredVertexColor = nil
      frame._arcTargetTint = true
    else
      local tR, tG, tB = 1, 1, 1
      if not isAuraActive and stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
        local col = stateVisuals.cooldownTintColor
        tR, tG, tB = col.r or 0.5, col.g or 0.5, col.b or 0.5
      end
      frame._arcTargetTint = string.format("%.2f,%.2f,%.2f", tR, tG, tB)
      -- RAW write: do NOT use SetVertexColorSafe for aura frames.
      -- SetVertexColorSafe sets _arcDesiredVertexColor, which the hook enforces
      -- against ALL future writes — blocking CDM from clearing tint when aura activates.
      -- Old working version used raw SetVertexColor; match that behavior.
      frame._arcDesiredVertexColor = nil
      if iconTex then
        iconTex:SetVertexColor(tR, tG, tB, 1)
      end
    end
  end

  -- SWIPE/EDGE: cooldown frames need proper swipe control even inside HandleAuraLogic.
  -- Previously just nulled desired values and let CDM control swipe — but that breaks
  -- swipeWaitForNoCharges on charge spells that also track an aura (e.g. Shadow Dance,
  -- Feint, Hover). When the aura activates after consuming a charge, the frame routes
  -- here and CDM draws the full swipe, ignoring our waitForNoCharges setting.
  if isCooldownFrame then
    if cdSpellID then
      DecideAndApplySwipeEdge(frame, cfg, cdOnCooldown, cdRecharging, cdIsCharge, cdIsOnGCD, false)
    else
      frame._arcDesiredSwipe = nil
      frame._arcDesiredEdge = nil
    end
  end

  -- GLOW
  local auraID = frame.auraInstanceID
  if isCooldownFrame or frame._arcTargetGlow == nil or not isAuraActive then
    if isCooldownFrame then
      if cdSpellID then
        local glowOnCD, glowRecharging = cdOnCooldown, cdRecharging
        local glowWhileCharges = stateVisuals.glowWhileChargesAvailable
        local glowEligible = true
        if glowOnCD then glowEligible = false
        elseif cdIsCharge and glowRecharging and not glowWhileCharges then glowEligible = false end
        if glowEligible and ShouldShowReadyGlow(stateVisuals, frame) then
          ShowReadyGlow(frame, stateVisuals)
        elseif not frame._arcPandemicGlowActive then
          -- glowFollowPandemic: TriggerAlertEvent owns the glow — don't kill it here
          HideReadyGlow(frame)
        end
      else
        ApplyReadyGlow(frame, stateVisuals)
      end
    elseif ShouldShowReadyGlow(stateVisuals, frame) and isAuraActive then
      local threshold = stateVisuals.glowThreshold or 1.0
      if threshold < 1.0 and auraID then
        local auraType = stateVisuals.glowAuraType or "auto"
        local unit = "player"
        if auraType == "debuff" then unit = "target"
        elseif auraType == "auto" then
          local cat = frame.category
          if cat == 3 then unit = "target" end
        end
        InitCooldownCurves()
        -- 12.1: instance-id aura APIs THROW while the unit's auras are secret (the auraID stays
        -- NON-secret), so gate on the ns.API.AurasSecret probe. Skip -> plain ready glow. Inert on live.
        local auraDurObj = C_UnitAuras and C_UnitAuras.GetAuraDuration
                           and not (ns.API and ns.API.AurasSecret and ns.API.AurasSecret(unit))
                           and C_UnitAuras.GetAuraDuration(unit, auraID)
        if auraDurObj then
          local thresholdCurve = GetGlowThresholdCurve(threshold)
          if thresholdCurve then
            local glowAlpha = auraDurObj:EvaluateRemainingPercent(thresholdCurve)
            if glowAlpha ~= nil then
              SetGlowAlpha(frame, glowAlpha, stateVisuals)
            else ShowReadyGlow(frame, stateVisuals) end
          else ShowReadyGlow(frame, stateVisuals) end
        else ShowReadyGlow(frame, stateVisuals) end
      else ShowReadyGlow(frame, stateVisuals) end
      frame._arcTargetGlow = true
    else
      -- glowFollowPandemic: TriggerAlertEvent owns the glow — don't kill it here
      if not frame._arcPandemicGlowActive then
        HideReadyGlow(frame)
      end
      frame._arcTargetGlow = true
    end
  end

  -- AURA ACTIVE GLOW — evaluate for all paths through HandleAuraLogic.
  -- HandleCooldownLogic and HandleIgnoreAuraOverride both call this at their end.
  -- HandleAuraLogic was missing it, so totem/wasSetFromAura cooldown frames
  -- (which route here when wasSetFromAura=true) never got aura active glow evaluated.
  EvaluateAuraActiveGlow(frame, cfg)
end


-- ═══════════════════════════════════════════════════════════════════
-- AURA ACTIVE GLOW — cooldown frames only
-- ArcUI_AuraFrames.lua has its own copies for true aura/buff frames.
-- No cross-file dependency: each file owns its glow logic entirely.
-- ═══════════════════════════════════════════════════════════════════

local function ShouldShowAuraActiveGlow(auraActiveCfg, frame, isReady)
  if frame and frame.cooldownID then
    if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsAuraGlowPreviewActive then
      if ns.CDMEnhanceOptions.IsAuraGlowPreviewActive(frame.cooldownID) then
        return true
      end
    end
  end
  if not auraActiveCfg then return false end
  if auraActiveCfg.glowFollowPandemic then return false end
  local glowOnActive  = auraActiveCfg.glow == true
  local glowOnMissing = auraActiveCfg.glowWhenMissing == true
  if not glowOnActive and not glowOnMissing then return false end
  if auraActiveCfg.glowCombatOnly then
    local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
    if not inCombat then return false end
  end
  if isReady ~= nil then
    if isReady     and glowOnActive  then return true end
    if not isReady and glowOnMissing then return true end
    return false
  end
  return true
end

local function ShowAuraActiveGlow(frame, auraActiveCfg)
  if not frame or not auraActiveCfg or not ns.Glows then return end
  local glowType = auraActiveCfg.glowType or "button"
  local r, g, b  = 1, 0.85, 0.1
  if auraActiveCfg.glowColor then
    r = auraActiveCfg.glowColor.r or 1
    g = auraActiveCfg.glowColor.g or 0.85
    b = auraActiveCfg.glowColor.b or 0.1
  end
  local padding = 0
  if frame._arcConfig and frame._arcConfig.padding then
    padding = frame._arcConfig.padding
  elseif frame._arcPadding then
    padding = frame._arcPadding
  end
  local glowOffset = -(padding or 0)
  ns.Glows.Start(frame, "ArcUI_AuraGlow", glowType, {
    color      = {r, g, b, auraActiveCfg.glowIntensity or 1.0},
    intensity  = auraActiveCfg.glowIntensity  or 1.0,
    scale      = auraActiveCfg.glowScale      or 1.0,
    frequency  = auraActiveCfg.glowSpeed      or 0.25,
    lines      = auraActiveCfg.glowLines      or 8,
    thickness  = auraActiveCfg.glowThickness  or 2,
    particles  = auraActiveCfg.glowParticles  or 4,
    xOffset    = glowOffset + (auraActiveCfg.glowXOffset  or 0),
    yOffset    = glowOffset + (auraActiveCfg.glowYOffset  or 0),
    translateX = auraActiveCfg.glowTranslateX or 0,
    translateY = auraActiveCfg.glowTranslateY or 0,
    strata     = (auraActiveCfg.glowFrameStrata ~= "inherit") and auraActiveCfg.glowFrameStrata or nil,
    frameLevel = auraActiveCfg.glowFrameLevel,
  })
  frame._arcAuraActiveGlowActive = true
  frame._arcAuraActiveGlowType   = glowType
end

local function HideAuraActiveGlow(frame)
  if not frame then return end
  if not frame._arcAuraActiveGlowActive then return end
  if ns.Glows then ns.Glows.Stop(frame, "ArcUI_AuraGlow") end
  frame._arcAuraActiveGlowActive = false
  frame._arcAuraActiveGlowType   = nil
  frame._arcAuraActiveGlowSig    = nil
  if frame._arcAuraGlowPreviewAlpha then
    frame._arcBypassAlphaHook = true
    frame:SetAlpha(frame._arcAuraGlowPreviewAlpha)
    frame._arcBypassAlphaHook = false
    frame._arcAuraGlowPreviewAlpha = nil
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- Used by both HandleCooldownLogic and HandleIgnoreAuraOverride.
-- CDM sets frame.auraInstanceID when the aura is active — use that
-- directly rather than any spell-readiness proxy.
-- ═══════════════════════════════════════════════════════════════════
EvaluateAuraActiveGlow = function(frame, cfg)
  local isAuraGlowPreview = ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsAuraGlowPreviewActive
    and ns.CDMEnhanceOptions.IsAuraGlowPreviewActive(frame.cooldownID)
  local aaCfg = cfg.auraActiveState
  if isAuraGlowPreview or (aaCfg and (aaCfg.glow or aaCfg.glowWhenMissing)) then
    local resolvedCfg = aaCfg or {}
    local isActive = HasFrameAura(frame.auraInstanceID) or (frame.totemData ~= nil)
    if ShouldShowAuraActiveGlow(resolvedCfg, frame, isActive) then
      ShowAuraActiveGlow(frame, resolvedCfg)
    else
      -- glowFollowPandemic: TriggerAlertEvent owns this glow while _arcPandemicGlowActive.
      -- Don't let normal Apply calls kill it; TriggerAlertEvent clears on expiry/reapply.
      if not (resolvedCfg.glowFollowPandemic and frame._arcPandemicGlowActive) then
        HideAuraActiveGlow(frame)
      end
    end
  elseif frame._arcAuraActiveGlowActive then
    HideAuraActiveGlow(frame)
  end
end


-- ═══════════════════════════════════════════════════════════════════
-- PATH C: Cooldown Logic — BINARY (matches ArcAuras pattern)
-- ═══════════════════════════════════════════════════════════════════
local function HandleCooldownLogic(frame, iconTex, cfg, stateVisuals)
  local spellID = ResolveCurrentSpellID(frame, cfg)
  if not spellID then
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

  local isOnCooldown, isRecharging, isChargeSpell, isOnGCD = ReadCooldownState(frame, spellID)

  local waitForNoCharges = isChargeSpell and stateVisuals.waitForNoCharges
  local glowWhileCharges = stateVisuals.glowWhileChargesAvailable

  local useCooldownVisuals
  if isOnCooldown then useCooldownVisuals = true
  elseif isChargeSpell and isRecharging then useCooldownVisuals = not waitForNoCharges
  else useCooldownVisuals = false end

  local isGlowEligible
  if isOnCooldown then isGlowEligible = false
  elseif isChargeSpell and isRecharging and not glowWhileCharges then isGlowEligible = false
  else isGlowEligible = true end

  local cfgHasIgnoreAura = (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
                        or (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)
  -- BLIZZARD'S VERDICT, NOT OUR GUESS. CheckCacheCooldownValuesFromAura adopts the
  -- totem/aura duration ONLY when CanUseAuraForDisplay() passes -- i.e. the spell's
  -- cooldownInfo.flags does NOT carry Enum.CooldownSetSpellFlags.HideAura (=1) -- and
  -- signals that by setting wasSetFromAura (+ cooldownUseAuraDisplayTime=true,
  -- cooldownDesaturated=false). RefreshTotemData still POPULATES totemData either way,
  -- so bare `totemData ~= nil` is NOT "an aura is being displayed".
  --   Earthgrab Totem 29982: flags=0 -> wasSetFromAura=true  -> CDM shows totem duration
  --   Surging Totem  29970: flags=1 -> wasSetFromAura=false -> CDM shows the COOLDOWN
  --                                                            and sets cooldownDesaturated=true
  -- The old `or (frame.totemData ~= nil)` fired only for that second class (the
  -- dispatcher already sent wasSetFromAura frames to HandleAuraLogic), pinning
  -- force=0 saturation for the whole cooldown and overriding CDM's own decision.
  -- The dispatcher asks this exact question correctly via useAuraLogic; match it.
  -- Also strictly safer in combat: wasSetFromAura is assigned from literals only, so
  -- it is never secret, while totemData is a SECRET TABLE in combat.
  local hasActiveAuraDisplay = not cfgHasIgnoreAura and (frame.wasSetFromAura == true)

  frame:Show()

  if useCooldownVisuals then
    frame._arcDesatBranch = "C_BIN_CD"
    ApplyCooldownAlpha(frame, stateVisuals)
    ApplyCooldownDesat(frame, iconTex, stateVisuals, hasActiveAuraDisplay, isRecharging)
    if stateVisuals.cooldownTint and stateVisuals.cooldownTintColor then
      local col = stateVisuals.cooldownTintColor
      SetVertexColorSafe(frame, iconTex, col.r or 0.5, col.g or 0.5, col.b or 0.5)
    else
      frame._arcDesiredVertexColor = nil
    end
    if isGlowEligible then ApplyReadyGlow(frame, stateVisuals) else HideReadyGlow(frame) end
  else
    frame._arcDesatBranch = "C_BIN_READY"
    frame._arcPreserveCooldownPath = nil  -- Cooldown ended, allow normal dispatch
    local usabilityAlpha, usabilityPreserveText = GetUsabilityAlpha(frame, spellID, cfg)
    ApplyReadyState(frame, iconTex, stateVisuals, usabilityAlpha, usabilityPreserveText)
    frame._arcDesiredVertexColor = nil
    if isGlowEligible then ApplyReadyGlow(frame, stateVisuals) else HideReadyGlow(frame) end
  end

  -- CHARGE-CONDITIONAL TEXT (hideAtZero / hideWhenHasCharges)
  ApplyChargeConditionalText(frame, cfg, isChargeSpell, isRecharging, isOnCooldown)

  -- SWIPE/EDGE — single source of truth
  DecideAndApplySwipeEdge(frame, cfg, isOnCooldown, isRecharging, isChargeSpell, isOnGCD, false)

  -- AURA ACTIVE GLOW
  EvaluateAuraActiveGlow(frame, cfg)
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
  -- Never process CDM aura viewer frames (buff/debuff icons) — they have no cooldown state
  if frame._arcViewerType == "aura" then return end
  -- RELEASED-FRAME GUARD (timeline-proven, 2026-08-12): a frame CDM has
  -- released (ClearCooldownID → cooldownID nil) can still reach this engine
  -- through stale caches/relays — spell resolution rides OUR cached settings,
  -- not the frame's cleared cooldownInfo — and HandleCooldownLogic's
  -- unconditional frame:Show() raised the corpse (the "clone icon" /
  -- floating-square bug: trace showed Show cdID=nil from this file on a pool
  -- spare CDM never assigned). A CDM item frame with no cooldownID must never
  -- be shown or styled. (Arc's own frames exited above via _arcAuraID/_arcConfig;
  -- totem/item CDM frames always carry a cooldownID.)
  if frame.cooldownID == nil and frame.GetCooldownID then return end

  -- DURATION OVERRIDE: while an experimental duration override is active, it owns
  -- the entire visual (treated as an aura-active override) and drives the same
  -- _arc desat/swipe/edge levers. Delegate and stop so we don't paint cooldown
  -- state over it.
  if frame._arcDurOvActive and ns.DurationOverride and ns.DurationOverride.ApplyVisuals then
    ns.DurationOverride.ApplyVisuals(frame)
    return
  end

  local iconTex = ResolveIconTexture(frame)
  if not iconTex then return end

  if not stateVisuals then
    -- Reuse the frame's already-cached state-visuals when cfg is the frame's own
    -- cached cfg (identical table ⇒ the cache was computed from it, see
    -- GetEffectiveIconSettingsForFrame). This is the hot cooldown-event path
    -- (DispatchAfterShadowUpdate passes frame._arcCfg), so it avoids re-allocating
    -- the ~40-field state-visuals table on every cooldown state change. Any other
    -- cfg falls back to a fresh compute. Identity match makes this staleness-proof:
    -- the cached value is, by construction, exactly GetEffectiveStateVisuals(cfg).
    if cfg ~= nil and cfg == frame._arcCfg then
      stateVisuals = frame._arcCachedStateVisuals
    else
      stateVisuals = GetEffectiveStateVisuals(cfg)
    end
  end

  local cdID = frame.cooldownID
  local isGlowPreview = cdID and ns.CDMEnhanceOptions
                        and ns.CDMEnhanceOptions.IsGlowPreviewActive
                        and ns.CDMEnhanceOptions.IsGlowPreviewActive(cdID)
  -- Aura active glow preview (separate system from ready glow preview)
  local isAuraGlowPreview = cdID and ns.CDMEnhanceOptions
                            and ns.CDMEnhanceOptions.IsAuraGlowPreviewActive
                            and ns.CDMEnhanceOptions.IsAuraGlowPreviewActive(cdID)

  local ignoreAuraOverride = (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
                          or (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)

  local hasSpellUsability = cfg.spellUsability and cfg.spellUsability.enabled == true
  local hasNoGCDSwipe = cfg.cooldownSwipe and cfg.cooldownSwipe.noGCDSwipe
  local hasWaitFlags = cfg.cooldownSwipe and (cfg.cooldownSwipe.swipeWaitForNoCharges or cfg.cooldownSwipe.edgeWaitForNoCharges)
  local hasChargeTextFlags = (cfg.chargeText and cfg.chargeText.enabled ~= false and cfg.chargeText.hideAtZero)
                          or (cfg.cooldownText and cfg.cooldownText.enabled ~= false and cfg.cooldownText.hideWhenHasCharges)
  -- desaturateWhenInactive: aura-not-active desat is the only configured visual? still run the dispatch.
  local hasAuraInactiveDesat = cfg.auraActiveState and cfg.auraActiveState.desaturateWhenInactive
  -- GLOW WHEN AURA ACTIVE / MISSING is its own feature: GetEffectiveStateVisuals
  -- only reports ready/cooldown settings, so an icon configured with ONLY this
  -- glow produced stateVisuals = nil and bailed here -- the glow never
  -- evaluated. CDMEnhance's own gate already carries this term; this one was
  -- missing it, which is why ticking the option alone did nothing.
  local hasAuraActiveGlow = cfg.auraActiveState
    and (cfg.auraActiveState.glow == true or cfg.auraActiveState.glowWhenMissing == true)

  if not stateVisuals and not isGlowPreview and not isAuraGlowPreview and not ignoreAuraOverride and not hasSpellUsability and not hasNoGCDSwipe and not hasWaitFlags and not hasChargeTextFlags and not hasAuraInactiveDesat and not hasAuraActiveGlow then
    local prevBranch = frame._arcDesatBranch
    local wasManagedDesat = prevBranch ~= nil and prevBranch ~= "NO_SV_EARLY"
    frame._arcForceDesatValue = nil
    frame._arcReadyForGlow = false
    frame._arcDesatBranch = "NO_SV_EARLY"
    frame._arcDesiredSwipe = nil
    frame._arcDesiredEdge = nil
    frame._arcDesiredVertexColor = nil
    -- glowFollowPandemic: TriggerAlertEvent owns this glow — don't kill it from the early-exit path
    if not frame._arcPandemicGlowActive then
      HideReadyGlow(frame)
    end
    -- Clean up leftover aura active glow (e.g. glowWhenMissing was just disabled)
    -- Same guard: don't wipe pandemic glow mid-window
    if frame._arcAuraActiveGlowActive and not frame._arcPandemicGlowActive then
      HideAuraActiveGlow(frame)
    end
    if wasManagedDesat then
      SetDesat(iconTex, 0)
      if iconTex then iconTex:SetVertexColor(1, 1, 1, 1) end
      ApplyBorderDesaturation(frame, 0)
    end
    return
  end

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

  -- Ensure stateVisuals is at least a minimal table when aura glow preview is active
  -- so HandleCooldownLogic (which indexes it directly) does not error on nil
  if not stateVisuals and isAuraGlowPreview then
    stateVisuals = { readyAlpha = 1.0, cooldownAlpha = 1.0 }
  end

  local useAuraLogic = cfg._isAura or false
  if not useAuraLogic then
    if frame.wasSetFromAura == true then useAuraLogic = true end
  end

  -- OVERRIDE TRANSITION PROTECTION: spell override swaps (e.g. Surging Totem
  -- → Retract → back) can flip wasSetFromAura/totemData, diverting from
  -- cooldown-binary to aura-logic. Aura logic sees totemData as "active aura"
  -- → AURA_READY, hiding the remaining cooldown. If CDMEnhance flagged this
  -- frame during override detection, force cooldown path until CD ends.
  if useAuraLogic and frame._arcPreserveCooldownPath then
    useAuraLogic = false
  end

  -- 12.1: item cooldowns are not spell cooldowns. Trinkets (equipSlot) and bag
  -- items (spellCategoryID -- potions, healthstones) both feed the shadow from
  -- item APIs and get ICON-only state visuals; never touch the visible Cooldown
  -- (CDM owns the item swipe).
  if frame.cooldownInfo and (frame.cooldownInfo.equipSlot or frame.cooldownInfo.spellCategoryID) then
    HandleItemCooldownState(frame, frame.Icon, cfg, stateVisuals, ignoreAuraOverride)
    return
  end

  -- DISPATCH
  if ignoreAuraOverride then
    -- wasSetFromAura: CDM actively displaying aura duration on the swipe (authoritative).
    -- _arcAuraActive: covers timing gap — OnAuraInstanceInfoSet fires and sets this true
    --                 BEFORE CDM sets wasSetFromAura. Without it the first dispatch after
    --                 aura gained routes wrong.
    -- totemData: totem active on this frame.
    -- NOTE: HasAuraInstanceID alone is wrong — Blizzard sets auraInstanceID internally
    -- on some cooldown frames even when not displaying aura duration.
    local isAuraPresent = (frame.wasSetFromAura == true)
                       or (frame._arcAuraActive == true)
                       or (frame.totemData ~= nil)
    if isAuraPresent then
      frame._arcDesatBranch = "DISPATCH_IAO"
      frame._arcIgnoreAuraOverride = true
      HandleIgnoreAuraOverride(frame, iconTex, cfg, stateVisuals)
    else
      frame._arcDesatBranch = "DISPATCH_IAO_NO_AURA"
      frame._arcIgnoreAuraOverride = true
      frame._arcIAOPushKey = nil  -- aura window ended: re-arm the IAO initial push
      HandleCooldownLogic(frame, iconTex, cfg, stateVisuals)
    end
  elseif useAuraLogic then
    -- EVENT-DRIVEN AURA FRAMES: OptimizedApplyIconVisuals is the authority
    -- on alpha/desat/tint for true aura frames (cfg._isAura or totem).
    -- It fires instantly on SetAuraInstanceInfo/ClearAuraInstanceInfo hooks.
    -- CooldownState's HandleAuraLogic duplicates that work and can arrive
    -- late (via rescans/tickers), overwriting the correct values.
    -- Exception: cooldown frames with wasSetFromAura need HandleAuraLogic
    -- because their sub-path uses ReadCooldownState (spell cooldown, not aura).
    if cfg._isAura then
      -- True aura frame — CooldownState never touches these, AuraFrames owns them
      return
    end
    frame._arcDesatBranch = "DISPATCH_AURA"
    frame._arcIgnoreAuraOverride = false
    HandleAuraLogic(frame, iconTex, cfg, stateVisuals)
  else
    frame._arcDesatBranch = "DISPATCH_CD"
    frame._arcIgnoreAuraOverride = false
    frame._arcIAOPushKey = nil  -- IAO not active on this path: re-arm for next aura window
    HandleCooldownLogic(frame, iconTex, cfg, stateVisuals)
  end

  -- DESATURATE WHEN AURA INACTIVE: runs AFTER the dispatch branch so it supersedes
  -- whatever desat the branch decided (covers the cooldown-state path; the
  -- ready/usability path is covered inside ApplyReadyState). Re-evaluated on aura
  -- gained/lost via InstallCooldownAuraHooks (which re-calls this function).
  ApplyAuraInactiveDesat(frame, iconTex)
end


-- ═══════════════════════════════════════════════════════════════════
-- STANDALONE READY GLOW ENFORCEMENT (shadow binary detection)
-- Mirrors ArcAurasCooldown lines 540-548: reads shadows, decides glow.
-- Called from DispatchAfterShadowUpdate and exported for CDMEnhance.
-- ═══════════════════════════════════════════════════════════════════
EnforceCooldownReadyGlow = function(frame, stateVisuals)
  if not frame then return end
  -- 12.1: item (equip-slot) cooldowns — CDM owns the display; don't enforce a ready glow.
  if frame.cooldownInfo and frame.cooldownInfo.equipSlot then return end
  if not resolved then
    if not ResolveDependencies() then return end
  end
  if not stateVisuals then return end

  -- Feed shadow first (match ArcAurasCooldown: always feed before reading)
  local spellID
  if frame.cooldownInfo then
    spellID = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
  end
  if not spellID then spellID = frame._arcCachedSpellID end
  if spellID then
    EnsureShadowCooldown(frame)
    FeedShadowCooldown(frame, spellID)
  end

  local shadowCD = frame._arcCDMShadowCooldown
  local isOnCooldown = shadowCD and shadowCD:IsShown() or false

  local chargeShadow = frame._arcCDMChargeShadow
  local isRecharging = chargeShadow and chargeShadow:IsShown() or false

  local glowWhileCharges = stateVisuals.glowWhileChargesAvailable

  local isGlowEligible
  if isOnCooldown then
    isGlowEligible = false
  elseif isRecharging and not glowWhileCharges then
    isGlowEligible = false
  else
    isGlowEligible = true
  end

  if isGlowEligible and ShouldShowReadyGlow(stateVisuals, frame) then
    ShowReadyGlow(frame, stateVisuals)
  else
    HideReadyGlow(frame)
  end
end


-- ═══════════════════════════════════════════════════════════════════
-- INSTALL
-- ═══════════════════════════════════════════════════════════════════
ns.CDMEnhance.ApplyCooldownStateVisuals = NewApplyCooldownStateVisuals

ns.CooldownState.Apply                  = NewApplyCooldownStateVisuals
ns.CooldownState.ApplyReadyState        = ApplyReadyState
ns.CooldownState.ApplyReadyGlow         = ApplyReadyGlow
ns.CooldownState.ResolveIconTexture     = ResolveIconTexture
ns.CooldownState.GetUsabilityAlpha      = GetUsabilityAlpha
ns.CooldownState.EnforceReadyGlow       = EnforceCooldownReadyGlow
ns.CooldownState.PreserveDurationText   = PreserveDurationText
-- Exported for profiler auto-wrapping (was local-only, showed as ? in caller analysis)
ns.CooldownState.DispatchAfterShadowUpdate = DispatchAfterShadowUpdate

-- ═══════════════════════════════════════════════════════════════════
-- LIGHTWEIGHT USABILITY ALPHA UPDATER
-- Called by CDMSpellUsability's SetVertexColor hook instead of full Apply.
-- Only re-applies alpha — never touches swipe, glow, desat, charge text, etc.
-- On cooldown: shadow state events own alpha, skip entirely.
-- On ready: apply usability dim or restore to readyAlpha.
-- ═══════════════════════════════════════════════════════════════════
function ns.CooldownState.ApplyUsabilityAlpha(frame, cfg)
  if not frame then return end
  if not resolved then
    if not ResolveDependencies() then return end
  end
  -- On cooldown shadow events own alpha — skip, nothing to do here.
  local shadowCD = frame._arcCDMShadowCooldown
  if shadowCD and shadowCD:IsShown() then return end
  -- Charge-recharging shadow also owns alpha. A multi-charge spell that's
  -- recharging (1-of-N charge spent) is still in the "cooldown visual"
  -- branch and is using cooldownAlpha. ApplyReadyState clobbers
  -- _arcTargetAlpha (sets it to nil) which destroys that enforcement,
  -- so range-check / usability events firing this helper would reset the
  -- opacity back to readyAlpha mid-recharge. Bail exactly like shadowCD.
  local chargeShadow = frame._arcCDMChargeShadow
  if chargeShadow and chargeShadow:IsShown() then return end

  local spellID = frame._arcCachedSpellID
               or (frame.cooldownInfo and (frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID))
  if not spellID then return end

  local iconTex = ResolveIconTexture(frame)
  if not iconTex then return end

  local usabilityAlpha, preserveText = GetUsabilityAlpha(frame, spellID, cfg)
  -- Use cached stateVisuals — already computed when cfg was cached, no allocation needed.
  local sv = frame._arcCachedStateVisuals or { readyAlpha = 1.0, cooldownAlpha = 1.0 }
  ApplyReadyState(frame, iconTex, sv, usabilityAlpha, preserveText)
end

function ns.CooldownState.FeedShadow(frame, cfg)
  if not frame then return end
  if frame._arcConfig or frame._arcAuraID then return end
  if frame._arcViewerType == "aura" then return end
  -- 12.1: item (equip-slot) cooldowns — feed the shadow from the item cooldown API.
  if frame.cooldownInfo and frame.cooldownInfo.equipSlot then FeedShadowCooldown(frame, nil); return end
  local spellID
  if frame.cooldownInfo then
    spellID = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
  end
  if not spellID and cfg then spellID = cfg._spellID end
  if spellID then
    FeedShadowCooldown(frame, spellID)
  end
end

-- Exposed for debugger: read current binary state from shadow frames directly.
function ns.CooldownState.ReadBinaryState(frame)
  if not frame then return nil, nil, nil, nil end
  local isChargeSpell = frame._arcIsChargeSpellCached or false
  local isOnGCD       = frame._arcLastIsOnGCD or false
  local isOnCooldown, isRecharging = GetBinaryCooldownState(frame)
  return isOnCooldown, isRecharging, isChargeSpell, isOnGCD
end

function ns.CooldownState.EnsureShadow(frame)
  if not frame then return end
  if frame._arcViewerType == "aura" then return end
  EnsureShadowCooldown(frame)
end

-- ═══════════════════════════════════════════════════════════════════
-- COOLDOWN FRAME AURA INSTANCE HOOKS
-- Owns OnAuraInstanceInfoSet/Cleared for cooldown/utility frames.
-- ArcUI_AuraFrames.lua handles true aura (buff/debuff) frames only.
-- ═══════════════════════════════════════════════════════════════════
function ns.CooldownState.InstallCooldownAuraHooks(frame)
  if not frame then return end
  if frame._arcViewerType == "aura" then return end
  if frame._arcCooldownAuraHooked then return end
  frame._arcCooldownAuraHooked = true

  if frame.OnAuraInstanceInfoSet then
    hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
      self._arcAuraActive = HasFrameAura(self.auraInstanceID)
      local cfg = ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettingsForFrame
        and ns.CDMEnhance.GetEffectiveIconSettingsForFrame(self)
      -- Set reverse immediately when aura becomes active
      local swipeCfg = cfg and cfg.cooldownSwipe
      if swipeCfg and swipeCfg.reverseWhileAura and self.Cooldown then
        self.Cooldown:SetReverse(true)
      end
      if cfg and ns.CooldownState.Apply then
        ns.CooldownState.Apply(self, cfg)
      end
      if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
        ns.CustomLabel.UpdateVisibility(self)
      end
    end)
  end

  if frame.OnAuraInstanceInfoCleared then
    hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
      self._arcAuraActive = HasFrameAura(self.auraInstanceID)
      -- IMMEDIATE glow kill: aura just dropped, CDM will call RefreshData() next
      -- which can re-trigger visual state resets before Apply() re-evaluates glow.
      -- Don't rely on routing through Apply → EvaluateAuraActiveGlow — kill directly.
      if self._arcAuraActiveGlowActive and ns.Glows then
        ns.Glows.Stop(self, "ArcUI_AuraGlow")
        self._arcAuraActiveGlowActive = false
        self._arcAuraActiveGlowType   = nil
        self._arcAuraActiveGlowSig    = nil
      end
      local cfg = ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettingsForFrame
        and ns.CDMEnhance.GetEffectiveIconSettingsForFrame(self)
      local swipeCfg = cfg and cfg.cooldownSwipe
      -- Reset reverse back to base setting when aura ends
      if swipeCfg and swipeCfg.reverseWhileAura and self.Cooldown then
        self.Cooldown:SetReverse(swipeCfg.reverse == true)
      end
      -- Reset swipe color immediately so auraSwipeColor doesn't linger
      if swipeCfg and swipeCfg.auraSwipeColor and self.Cooldown then
        if swipeCfg.swipeColor then
          local sc = swipeCfg.swipeColor
          self.Cooldown:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
        else
          self.Cooldown:SetSwipeColor(0, 0, 0, 0.8)
        end
      end
      if cfg and ns.CooldownState.Apply then
        ns.CooldownState.Apply(self, cfg)
      end
      if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
        ns.CustomLabel.UpdateVisibility(self)
      end
    end)
  end

  -- ── SPELL OVERRIDE HOOK ──────────────────────────────────────────
  -- COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED fires when a proc swaps the
  -- spell tied to a CDM frame (Hot Streak's Pyroblast slot, Tempest on
  -- Maelstrom Weapon, etc.). Blizzard: SetOverrideSpell → RefreshData.
  -- If the override doesn't change auraInstanceID, the OnAuraInstanceInfoSet
  -- hook above doesn't fire, leaving auraActiveState glow / cooldownSwipe
  -- reverse / swipe color stale until the next aura state change.
  -- Defer one frame so RefreshData settles first, then re-apply state.
  if frame.OnCooldownViewerSpellOverrideUpdatedEvent and not frame._arcCooldownOverrideHooked then
    frame._arcCooldownOverrideHooked = true

    hooksecurefunc(frame, "OnCooldownViewerSpellOverrideUpdatedEvent", function(self)
      local capturedSelf = self
      C_Timer.After(0, function()
        capturedSelf._arcAuraActive = HasFrameAura(capturedSelf.auraInstanceID)
        local cfg = ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettingsForFrame
          and ns.CDMEnhance.GetEffectiveIconSettingsForFrame(capturedSelf)
        if cfg and ns.CooldownState.Apply then
          ns.CooldownState.Apply(capturedSelf, cfg)
        end
        if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
          ns.CustomLabel.UpdateVisibility(capturedSelf)
        end
      end)
    end)
  end
end