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
    if not pf._arcNoGCDSwipeEnabled then return end
    if pf._arcBypassCDHook then return end

    -- Aura display frames:
    --   IAO off: CDM owns the duration (aura display). Skip.
    --   IAO on:  IAOFight in CooldownState handles the push. Skip here.
    if pf.wasSetFromAura == true then return end

    -- Skip non-cooldown viewers (aura trackers etc).
    if pf._arcViewerType == "aura" then return end

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
  end)

  -- SetDrawSwipe / SetDrawEdge hooks REMOVED (Q1):
  --   The ignoreGCD=true durObj is zero-span during pure GCD, so the
  --   engine auto-hides the swipe. No suppression needed.
  --   Any code that still calls SetDrawSwipe(true) during a GCD-only
  --   window will have no visible effect because the underlying cooldown
  --   has nothing to animate.
end