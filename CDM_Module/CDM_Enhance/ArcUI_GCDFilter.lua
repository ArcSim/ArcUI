-- ===================================================================
-- ArcUI_GCDFilter.lua
-- GCD filtering on CDM visual Cooldown frames via duration object push.
-- NOT for shadow frames — ArcUI_CooldownState owns those.
--
-- METHOD (12.0.5 PTR 4+):
--   CDM writes SetCooldown on every cycle using a GCD-bundled durObj.
--   We hook SetCooldown and immediately re-push using
--   GetSpellCooldownDuration(sid, true) (or GetSpellChargeDuration for
--   charge spells). The ignoreGCD=true flag makes the durObj GCD-free:
--
--     - GCD-only moment (no real CD)   → durObj is zero-span → engine
--                                         auto-hides the swipe. NO need
--                                         for SetDrawSwipe(false).
--     - Real CD running (GCD layered)  → durObj shows real remaining time
--                                         of the actual cooldown, not GCD.
--     - Charge spell recharging        → pushes recharge timer (also
--                                         GCD-stripped).
--
--   This replaces the entire old SetDrawSwipe/SetDrawEdge suppression
--   system: zero-span durObj makes the engine hide the frame naturally,
--   so there's nothing to suppress.
--
-- AURA OVERRIDE INTERACTION (IAO):
--   wasSetFromAura=true, IAO off:   CDM owns the duration (aura display).
--                                    Skip the push entirely.
--   wasSetFromAura=true, IAO on:    IAOFight (in CooldownState) handles
--                                    the push — it decides whether frame
--                                    is truly on CD and pushes accordingly.
--                                    Skip here to avoid double-push/cascade.
--   wasSetFromAura=false:           Push the GCD-stripped durObj here.
--                                    Applies to both normal and charge spells
--                                    uniformly (Q2: uniform treatment).
--
-- Install: ns.GCDFilter.Install(frame, cdID)
--   Called from ArcUI_CDMEnhance.ApplyIconStyle after _arcNoGCDSwipeEnabled
--   is stored on the frame. Safe to call multiple times — guarded by
--   frame.Cooldown._arcGCDFilterHooked.
-- ===================================================================

local ADDON, ns = ...

ns.GCDFilter = ns.GCDFilter or {}
local GCDFilter = ns.GCDFilter

-- 12.1: item cooldown APIs (GetInventoryItemCooldown) return the RAW cooldown — no
-- ignoreGCD — so during a GCD they report the ~1.5s GCD as the item's cooldown. Any
-- reported duration <= this is GCD/windup noise; real item CDs are >>1.5s (trinkets
-- >=20s). Filter it, matching Arc Auras' ITEM_GCD_THRESHOLD.
local ITEM_GCD_THRESHOLD = 1.5

-- ═══════════════════════════════════════════════════════════════════
-- ShouldSuppressGCD (compat shim)
-- Old callers may still reference this. Always returns false now —
-- suppression is handled by the durObj feed (zero-span auto-hides).
-- Kept for backwards compatibility; remove once no callers remain.
-- ═══════════════════════════════════════════════════════════════════
local function ShouldSuppressGCD(frame)
  return false
end

GCDFilter.ShouldSuppressGCD = ShouldSuppressGCD

-- Re-float preserved duration text after one of OUR bypassed re-pushes below.
-- Each re-push rebuilds CDM's countdown FontString, and the global preserve
-- re-apply hook (CDMEnhance) deliberately ignores bypassed pushes — so without
-- this the preserved text binds to the dimmed frame alpha until the next
-- dispatch, showing as intermittent text flicker on dimmed icons.
local function RefloatPreservedText(pf)
  if pf._arcPreserveDurationText and ns.CooldownState and ns.CooldownState.PreserveDurationText then
    ns.CooldownState.PreserveDurationText(pf)
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- INSTALL
-- Hooks frame.Cooldown (the CDM visual Cooldown widget) once per icon.
-- Single responsibility: on every CDM SetCooldown write, re-push using
-- ignoreGCD=true durObj so the visible swipe is GCD-free.
-- ═══════════════════════════════════════════════════════════════════
function GCDFilter.Install(frame, cdID)
  if not frame or not frame.Cooldown then return end
  if frame.Cooldown._arcGCDFilterHooked then return end
  frame.Cooldown._arcGCDFilterHooked = true

  -- Stash parent reference — hook reads it via self._arcParentFrame.
  -- Don't overwrite if already set by another hook installer.
  if not frame.Cooldown._arcParentFrame then
    frame.Cooldown._arcParentFrame = frame
  end
  if not frame.Cooldown._arcCdID then
    frame.Cooldown._arcCdID = cdID
  end

  local cd = frame.Cooldown

  -- ── SetCooldown: re-push GCD-stripped durObj ─────────────────────
  -- CDM writes a GCD-bundled durObj every cycle. Replace it immediately
  -- with the ignoreGCD=true version so:
  --   - GCD-only moments → zero-span durObj → engine auto-hides
  --   - Real CD moments  → real remaining time of the actual CD
  --   - Charges          → recharge timer, GCD stripped
  hooksecurefunc(cd, "SetCooldown", function(self)
    local pf = self._arcParentFrame
    if not pf then return end
    -- Ignore Hard ICD (charge spells only): even without No-GCD, re-push so the
    -- visible swipe shows the charge RECHARGE instead of the hard ICD CDM drew
    -- (the charge branch below already prefers GetSpellChargeDuration).
    local icdOverride = pf._arcIgnoreHardICD and pf._arcIsChargeSpellCached
    if not pf._arcNoGCDSwipeEnabled and not icdOverride then return end
    if pf._arcBypassCDHook then return end

    -- Aura display frames:
    --   IAO off: CDM owns the duration (aura display). Skip.
    --   IAO on:  IAOFight in CooldownState handles the push. Skip here.
    if pf.wasSetFromAura == true then return end

    -- Duration Override active: the override owns the cooldown display (a custom
    -- aura/totem/manual duration, NOT the real spell cooldown) and DurationOverride
    -- re-asserts its durObj on every push. Skip the GCD re-push so we don't fight it --
    -- otherwise, while the spell is on cooldown, the real cooldown races/clobbers the
    -- override (and its refreshes never make it onto the widget).
    if pf._arcDurOvActive then return end

    -- Skip non-cooldown viewers (aura trackers etc).
    if pf._arcViewerType == "aura" then return end

    -- 12.1: item (trinket) cooldowns — CDM bundles the GCD into the item frame's swipe,
    -- and the spell API returns zero-span (the CD is on the item, not the spell). This
    -- hook only runs when No-GCD swipe is on (_arcNoGCDSwipeEnabled gate above), so for
    -- item frames re-push the RAW item cooldown (GetInventoryItemCooldown is inherently
    -- GCD-free) to strip the GCD and show the real item cooldown. Effectively a fix for
    -- Blizzard's CDM showing the GCD on item frames.
    local eqSlot = pf.cooldownInfo and pf.cooldownInfo.equipSlot
    if eqSlot then
      local istart, idur = GetInventoryItemCooldown("player", eqSlot)
      pf._arcBypassCDHook = true
      if istart and idur and istart > 0 and idur > ITEM_GCD_THRESHOLD then
        self:SetCooldown(istart, idur)
      else
        self:Clear()
      end
      pf._arcBypassCDHook = false
      RefloatPreservedText(pf)
      return
    end

    local ci = pf.cooldownInfo
    local spellID = ci and (ci.overrideSpellID or ci.spellID)
    if not spellID then return end

    -- Pick the right API: charge spells use recharge timer, normal spells
    -- use cooldown duration. Both called with ignoreGCD=true.
    -- For charge spells, GetSpellChargeDuration returns zero-span when no
    -- recharge is running (all charges full), which auto-hides the swipe
    -- — the exact behaviour we want for "ready" state.
    local durObj
    if pf._arcIsChargeSpellCached and C_Spell.GetSpellChargeDuration then
      durObj = C_Spell.GetSpellChargeDuration(spellID, true)
    end
    if not durObj and C_Spell.GetSpellCooldownDuration then
      durObj = C_Spell.GetSpellCooldownDuration(spellID, true)
    end
    if not durObj then return end

    pf._arcBypassCDHook = true
    self:SetCooldownFromDurationObject(durObj)
    pf._arcBypassCDHook = false
    RefloatPreservedText(pf)
  end)

  -- 12.1: item (trinket) cooldowns may be pushed via SetCooldownFromDurationObject
  -- (the durObj model), which the SetCooldown hook above does NOT catch — so a GCD
  -- durObj CDM pushes onto a READY trinket slips through and draws the GCD swipe/edge.
  -- Mirror the item branch here: strip it (Clear) when ready, show the real item CD
  -- via the numeric API when on cooldown. Only acts on item frames; spells are no-ops.
  if cd.SetCooldownFromDurationObject then
    hooksecurefunc(cd, "SetCooldownFromDurationObject", function(self)
      local pf = self._arcParentFrame
      if not pf then return end
      if not pf._arcNoGCDSwipeEnabled then return end
      if pf._arcBypassCDHook then return end
      if pf.wasSetFromAura == true then return end
      if pf._arcDurOvActive then return end   -- override owns the display; don't fight it
      if pf._arcViewerType == "aura" then return end
      local eqSlot = pf.cooldownInfo and pf.cooldownInfo.equipSlot
      if not eqSlot then return end
      local istart, idur = GetInventoryItemCooldown("player", eqSlot)
      pf._arcBypassCDHook = true
      if istart and idur and istart > 0 and idur > ITEM_GCD_THRESHOLD then
        self:SetCooldown(istart, idur)
      else
        self:Clear()
      end
      pf._arcBypassCDHook = false
      RefloatPreservedText(pf)
    end)
  end

  -- SetDrawSwipe / SetDrawEdge hooks REMOVED (Q1):
  --   The ignoreGCD=true durObj is zero-span during pure GCD, so the
  --   engine auto-hides the swipe. No suppression needed.
  --   Any code that still calls SetDrawSwipe(true) during a GCD-only
  --   window will have no visible effect because the underlying cooldown
  --   has nothing to animate.
end