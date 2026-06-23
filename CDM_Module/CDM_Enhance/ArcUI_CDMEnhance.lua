-- ===================================================================
-- ArcUI_CDMEnhance.lua
-- Enhanced CDM icon customization with aspect ratio, padding,
-- v2.11.0: Secret-safe auraInstanceID protection

-- ===================================================================

local ADDON, ns = ...

ns.CDMEnhance = ns.CDMEnhance or {}

-- Use shared CDM constants and helpers (from ArcUI_CDM_Shared.lua)
local Shared = ns.CDMShared

-- ArcUI 12.1-forward fix: EquipSlotTracked (trinket buff) and other aura-type CDM
-- frames in 12.1 have a nil cooldownInfo.spellID, so the proc-glow spellID is derived
-- from the (secret) aura. C_SpellActivationOverlay.IsSpellOverlayed rejects a secret
-- argument in 12.1, so route every overlay check through this guard. On 12.0.7 these
-- spellIDs are never secret, so behavior there is identical.
local function SafeIsSpellOverlayed(spellID)
  if not spellID then return false end
  if issecretvalue and issecretvalue(spellID) then return false end
  return C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed(spellID)
end

-- ArcUI 12.1-forward fix: a frame-DERIVED spellID (frame:GetSpellID() / _arcSpellID) is
-- SECRET on equip-slot aura frames (trinket buffs); comparing or passing a secret number
-- throws in 12.1. Neutralize it at the source so every downstream compare/API is a safe
-- non-match. On 12.0.7 these are never secret, so behavior is identical.
local function NonSecretSpellID(spellID)
  if spellID and issecretvalue and issecretvalue(spellID) then return nil end
  return spellID
end

-- Profiler handler tracking (nil-safe if profiler not loaded)
local Track = _G.ArcUIProfiler_Track
local function _T(name, fn) return Track and Track(name, fn) or fn end

-- Forward declarations for proc glow helpers (defined later, used in RefreshProcGlow)
local StartLCGProcGlow
local StopLCGProcGlow

-- ===================================================================
-- SECRET-SAFE AURAINSTANCEID HELPER
-- Uses ns.API.HasAuraInstanceID from Core.lua (handles secret values)
-- ===================================================================
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

-- ===================================================================
-- CACHED ENABLED STATE (avoid repeated DB lookups)
-- Updated on profile change, settings toggle, or explicit refresh
-- ===================================================================
local cachedCDMGroupsEnabled = true  -- Assume enabled until proven otherwise
local cachedStylingEnabled = true    -- Master styling toggle

-- Update cached enabled state (call on profile change or settings toggle)
local function RefreshCachedEnabledState()
  -- Check CDMGroups enabled
  local groupsDB = Shared and Shared.GetCDMGroupsDB and Shared.GetCDMGroupsDB()
  cachedCDMGroupsEnabled = groupsDB and groupsDB.enabled ~= false
  
  -- Check master styling toggle
  cachedStylingEnabled = Shared and Shared.IsCDMStylingEnabled and Shared.IsCDMStylingEnabled() or true
  
  -- Also refresh Shared's cached state (so other modules stay in sync)
  if Shared and Shared.RefreshCachedEnabledState then
    Shared.RefreshCachedEnabledState()
  end
  
  -- Also refresh CDMGroups' module-level boolean
  if ns.CDMGroups and ns.CDMGroups.RefreshCachedEnabledState then
    ns.CDMGroups.RefreshCachedEnabledState()
  end
end

-- Fast check functions (no DB lookup)
local function IsCDMGroupsEnabledCached()
  return cachedCDMGroupsEnabled
end

local function IsCDMStylingEnabledCached()
  return cachedStylingEnabled
end

-- Export for other modules
ns.CDMEnhance.RefreshCachedEnabledState = RefreshCachedEnabledState
ns.CDMEnhance.IsCDMGroupsEnabledCached = IsCDMGroupsEnabledCached

-- ===================================================================
-- CENTRALIZED BORDER WATCHER
-- Replaces per-frame OnUpdate hooks (was 25 frames × 60fps = 1500 calls/sec!)
-- Now: ONE watcher running at 2Hz = ~2 calls/sec
-- ===================================================================
-- ===================================================================
-- COOLDOWN DETECTION CURVES
-- Created once at addon load, reused for all cooldown state checks
-- These transform remaining% into usable values for secret-safe APIs
-- ===================================================================
-- COOLDOWN CURVES — Binary/BinaryInv used by CustomLabel for state visibility
-- ===================================================================
local CooldownCurves = {
  initialized = false,
}

local function InitCooldownCurves()
  if CooldownCurves.initialized then return true end
  if not C_CurveUtil or not C_CurveUtil.CreateCurve then
    return false
  end

  -- Binary: alpha=1 when on cooldown (remaining > 0%), alpha=0 when ready
  local binary = C_CurveUtil.CreateCurve()
  binary:AddPoint(0.0, 0)       -- 0% remaining (ready) = hide
  binary:AddPoint(0.001, 1)     -- any remaining (on CD) = show
  binary:AddPoint(1.0, 1)       -- full duration = show
  CooldownCurves.Binary = binary

  -- BinaryInv: alpha=1 when ready (remaining = 0%), alpha=0 when on cooldown
  local binaryInv = C_CurveUtil.CreateCurve()
  binaryInv:AddPoint(0.0, 1)    -- 0% remaining (ready) = show
  binaryInv:AddPoint(0.001, 0)  -- any remaining (on CD) = hide
  binaryInv:AddPoint(1.0, 0)    -- full duration = hide
  CooldownCurves.BinaryInv = binaryInv

  CooldownCurves.initialized = true
  return true
end

-- Create a dim curve for a specific alpha value (cached)
-- Export for other modules
ns.CDMEnhance.CooldownCurves = CooldownCurves
ns.CDMEnhance.InitCooldownCurves = InitCooldownCurves

-- Threshold glow curve builders and ticker live in AuraFrames (owns all glow threshold logic).
-- CDMEnhance delegates via ns.AuraFrames at call time so load order doesn't matter.
local function GetGlowThresholdCurve(threshold)
  return ns.AuraFrames and ns.AuraFrames.GetGlowThresholdCurve and ns.AuraFrames.GetGlowThresholdCurve(threshold)
end
local function GetGlowThresholdCurveSeconds(seconds)
  return ns.AuraFrames and ns.AuraFrames.GetGlowThresholdCurveSeconds and ns.AuraFrames.GetGlowThresholdCurveSeconds(seconds)
end
local function StartThresholdGlowTracking(cdID)
  if ns.AuraFrames and ns.AuraFrames.StartThresholdGlowTracking then ns.AuraFrames.StartThresholdGlowTracking(cdID) end
end
local function StopThresholdGlowTracking(cdID)
  if ns.AuraFrames and ns.AuraFrames.StopThresholdGlowTracking then ns.AuraFrames.StopThresholdGlowTracking(cdID) end
end

-- Debug output - only outputs when debug mode is enabled
local function DebugLog(msg)
  -- Only log if debug mode is enabled
  if not ArcUI_CDMEnhance_Debug then return end
  
  local line = date("%H:%M:%S") .. " [Enhance] " .. tostring(msg)
  _G.ARCUI_DEBUG = _G.ARCUI_DEBUG or {}
  table.insert(_G.ARCUI_DEBUG, line)
  if #_G.ARCUI_DEBUG > 500 then table.remove(_G.ARCUI_DEBUG, 1) end
  
  -- Also write to CDMGroups buffer
  if ns.CDMGroups and ns.CDMGroups.debugBuffer then
    table.insert(ns.CDMGroups.debugBuffer, line)
    if #ns.CDMGroups.debugBuffer > 500 then table.remove(ns.CDMGroups.debugBuffer, 1) end
  end
  
  print("|cffFF00FF[ArcUI]|r " .. tostring(msg))
end

-- Export for other files
ns.CDMEnhance.DebugLog = DebugLog

-- ===================================================================
-- ICON TEXTURE HELPER
-- Gets the actual icon texture from a CDM frame, with API fallback
-- Priority: frame.Icon:GetTexture() > GetTextureFileID() > API with overrideTooltipSpellID
-- For auras: CDM often uses overrideTooltipSpellID for display
-- For cooldowns: use override/linked chain
-- NOTE: In combat, GetTexture() may return secret values - use issecretvalue() to check
-- ===================================================================
local function GetIconTextureFromFrame(frame, isAura, baseSpellID, overrideSpellID, displaySpellID, overrideTooltipSpellID)
  local icon = nil
  
  -- Try to read from frame first (shows actual CDM texture)
  if frame and frame.Icon then
    local iconTex = frame.Icon
    
    -- Try GetTexture first (most common)
    -- Check for secret value before comparing (combat restriction)
    if not icon and iconTex.GetTexture then
      local tex = iconTex:GetTexture()
      if tex and not issecretvalue(tex) and tex ~= 0 and tex ~= "" then
        icon = tex
      end
    end
    
    -- Try GetTextureFileID (returns numeric ID)
    if not icon and iconTex.GetTextureFileID then
      local texID = iconTex:GetTextureFileID()
      if texID and not issecretvalue(texID) and texID > 0 then
        icon = texID
      end
    end
    
    -- Try GetTextureFilePath (returns string path)
    if not icon and iconTex.GetTextureFilePath then
      local texPath = iconTex:GetTextureFilePath()
      if texPath and not issecretvalue(texPath) and texPath ~= "" then
        icon = texPath
      end
    end
    
    -- Bar viewer structure: frame.Icon.Icon
    if not icon and frame.Icon.Icon then
      local innerIcon = frame.Icon.Icon
      if innerIcon.GetTexture then
        local tex = innerIcon:GetTexture()
        if tex and not issecretvalue(tex) and tex ~= 0 and tex ~= "" then
          icon = tex
        end
      end
      if not icon and innerIcon.GetTextureFileID then
        local texID = innerIcon:GetTextureFileID()
        if texID and not issecretvalue(texID) and texID > 0 then
          icon = texID
        end
      end
    end
  end
  
  -- Fallback to API with type-aware ordering
  if not icon then
    if isAura then
      -- Auras: try overrideTooltipSpellID first (this is what CDM uses for display)
      if overrideTooltipSpellID and overrideTooltipSpellID > 0 then
        icon = C_Spell.GetSpellTexture(overrideTooltipSpellID)
      end
      -- Then try base spellID
      if not icon and baseSpellID and baseSpellID > 0 then
        icon = C_Spell.GetSpellTexture(baseSpellID)
      end
      if not icon and overrideSpellID then
        icon = C_Spell.GetSpellTexture(overrideSpellID)
      end
      if not icon and displaySpellID then
        icon = C_Spell.GetSpellTexture(displaySpellID)
      end
    else
      -- Cooldowns: use override/linked chain (existing behavior)
      if displaySpellID then
        icon = C_Spell.GetSpellTexture(displaySpellID)
      end
      if not icon and overrideSpellID then
        icon = C_Spell.GetSpellTexture(overrideSpellID)
      end
      if not icon and baseSpellID and baseSpellID > 0 then
        icon = C_Spell.GetSpellTexture(baseSpellID)
      end
    end
  end
  
  return icon or 134400  -- Default question mark icon
end

-- Export helper for other modules
ns.CDMEnhance.GetIconTextureFromFrame = GetIconTextureFromFrame

-- ===================================================================
-- LOCALS
-- ===================================================================
local isUnlocked = false
local textDragMode = false  -- Separate unlock for text dragging
local cooldownPreviewMode = false  -- Preview cooldown animation
local enhancedFrames = {}   -- [cooldownID] = { frame, viewerType, viewerName }

-- Forward declarations for functions used before definition
local ApplyIconStyle
local GetEffectiveStateVisuals
local ApplyCooldownStateVisuals
local HideCDMProcGlow  -- Used in Show hook before full definition
local ResizeProcGlowAlert  -- Used in ApplyIconStyle for default glow resize
local IsMasqueSkinned  -- Used in ready glow for Masque shape matching
local TriggerMasqueSpellAlertUpdate  -- Used in ready glow for Masque shape matching
local ApplyMasqueProcShapeToAlert  -- Direct shape application for CDM SpellActivationAlert
local ApplyMasqueProcShapeToLCG  -- Direct shape application for LCG ProcGlow frames
local ShowAuraActiveGlow  -- Show glow when aura is active on cooldown frame
local HideAuraActiveGlow  -- Hide aura active glow

-- Selection tracking for options panel editing
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)


-- Native CDM icon sizes from CooldownViewer.xml (before any ArcUI resizing)
-- Essential(cooldown)=50, Utility=30, Aura(BuffIcon)=40
local CDM_NATIVE_SIZE = {
  cooldown = 50,
  utility  = 30,
  aura     = 40,
}

-- Store the current group scale per viewer type (from CDM Edit Mode)
-- This is captured when CDM calls SetScale on icons
-- Initialized with defaults, then updated from DB and CDM
local groupScales = {
  aura = 1.0,
  cooldown = 1.0,
  utility = 1.0,
}

-- Map our viewerType to CDM viewer frames (from shared module)
local VIEWER_FRAME_MAP = Shared.VIEWER_FRAME_MAP

-- ===================================================================
-- CENTRALIZED COOLDOWN STATE DETECTION
-- Uses WoW 12.0 secret-safe APIs for reliable cooldown detection
-- 
-- Key insight: isOnGCD is NOT secret and can be compared directly
-- For CHARGE SPELLS: Use GetSpellChargeDuration which tracks recharge, not GCD
-- ===================================================================

-- Get comprehensive cooldown state for a spell
-- Returns: isOnGCD (bool), durationObj, isChargeSpell, chargeDurObj
-- 
-- For CHARGE SPELLS:
--   - chargeDurObj is from GetSpellChargeDuration (recharge timer, ignores GCD)
--   - Use this for alpha/desat curves to properly track recharge state
--
-- For NORMAL SPELLS:
--   - isOnGCD indicates if ONLY on GCD (can be compared directly)
--   - durationObj is from GetSpellCooldownDuration
local function GetSpellCooldownState(spellID)
  if not spellID then return nil, nil, false, nil end
  
  -- Check if this is a charge spell
  local chargeInfo = nil
  local isChargeSpell = false
    chargeInfo = C_Spell.GetSpellCharges(spellID)
    isChargeSpell = chargeInfo ~= nil
  
  -- ONLY set isOnGCD when it's explicitly true - treat false same as nil
  local isOnGCD = nil
    local cdInfo = C_Spell.GetSpellCooldown(spellID)
    if cdInfo and cdInfo.isOnGCD == true then
      isOnGCD = true
    end
    -- If cdInfo.isOnGCD is false or nil, leave isOnGCD as nil
    -- This way we only react to "definitely on GCD", not "definitely not on GCD"
  
  -- Get duration objects
  local durationObj = nil
  local chargeDurObj = nil
  
  -- For charge spells, get charge duration (tracks recharge, ignores GCD)
  -- ignoreGCD=true (12.0.5 PTR 4): returns durObj with GCD stripped out, so
  -- consumers get the real recharge timer even during a GCD window.
  if isChargeSpell and C_Spell.GetSpellChargeDuration then
    local obj = C_Spell.GetSpellChargeDuration(spellID, true)
      chargeDurObj = obj
  end
  
  -- Always get regular cooldown duration too
  if C_Spell.GetSpellCooldownDuration then
    local obj = C_Spell.GetSpellCooldownDuration(spellID, true)
      durationObj = obj
  end
  
  return isOnGCD, durationObj, isChargeSpell, chargeDurObj
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CHARGE SPELL ANIMATION HELPER
-- Export the centralized API
ns.CDMEnhance.GetSpellCooldownState = GetSpellCooldownState

-- ═══════════════════════════════════════════════════════════════════════════
-- TOTEM DETECTION HELPER
-- Totems are a special case in CDM - they appear as category 2 but hasAura=false
-- WoW 12.0: totemData ONLY EXISTS when totem is currently active (it's a secret table)
-- When totem expires, totemData becomes nil but preferredTotemUpdateSlot persists!
-- ═══════════════════════════════════════════════════════════════════════════

-- Check if a frame has active totem
-- Returns: hasTotemData, isTotemActive, totemSlot
local function GetTotemState(frame)
  if not frame then return false, false, nil end
  
  -- Only frames with preferredTotemUpdateSlot are totem frames
  local slotVal = frame.preferredTotemUpdateSlot
  if slotVal and type(slotVal) == "number" and slotVal > 0 then
    -- WoW 12.0: totemData ONLY EXISTS when totem is active
    -- When totem expires, totemData becomes nil
    if frame.totemData ~= nil then
      return true, true, slotVal  -- isTotemFrame=true, isActive=true, slot
    else
      return true, false, slotVal  -- isTotemFrame=true, isActive=false, slot
    end
  end
  
  return false, false, nil
end

-- Export for other modules
ns.CDMEnhance.GetTotemState = GetTotemState

-- ===================================================================
-- GLOW STOP HELPER
-- Consolidates the repeated pattern of stopping all glow types
-- ===================================================================

-- ═══════════════════════════════════════════════════════════════════
-- Default frame level offset for glow overlay relative to parent icon.
-- +1 matches frame.Cooldown level — above swipe (texture on Cooldown),
-- below duration text (FontString in OVERLAY draw layer on Cooldown).
local GLOW_OVERLAY_LEVEL_OFFSET = 1

-- ACH template glow sizing ratios (from Blizzard templates)
local ACH_ANTS_FLIPBOOK_RATIO = 66 / 45   -- Ants flipbook texture is 1.467x container
local ACH_PROC_LOOP_RATIO     = 66 / 45   -- Proc loop container uses same ratio
local ACH_PROC_START_RATIO    = 150 / 45   -- Proc burst intro is 3.33x icon size

-- UNIFIED GLOW OVERLAY
-- All ArcUI glows (ready, proc, usable, preview) draw on this single
-- child frame. Default level = parent+1 (same as Cooldown widget).
-- Glows render above swipe but below duration text because text uses
-- the OVERLAY draw layer which always wins at the same frame level.
-- User can override via readyGlowFrameLevel setting.
-- ═══════════════════════════════════════════════════════════════════
local function GetGlowOverlay(frame)
  if frame._arcGlowOverlay then return frame._arcGlowOverlay end
  local overlay = CreateFrame("Frame", nil, frame)
  overlay:SetAllPoints(frame)
  overlay:SetFrameLevel(frame:GetFrameLevel() + GLOW_OVERLAY_LEVEL_OFFSET)
  overlay:Show()
  overlay._arcOwnerFrame = frame  -- back-reference for alpha hooks etc.
  frame._arcGlowOverlay = overlay
  return overlay
end
ns.CDMEnhance.GetGlowOverlay = GetGlowOverlay

-- Clamp all LCG child frame levels on the glow overlay.
-- LCG internally bumps children to parent+3..+8 which puts them above
-- Cooldown/text. This hooks SetFrameLevel on each child to keep them at
-- the overlay's own level (or user-overridden level).
-- Call after every LCG Start operation.
local function ClampOverlayChildren(overlay)
  if not overlay then return end
  local maxLevel = overlay:GetFrameLevel()
  for _, child in pairs({overlay:GetChildren()}) do
    if child.SetFrameLevel then
      if not child._arcLevelClamped then
        child._arcLevelClamped = true
        -- Store the REAL SetFrameLevel before we replace it
        local origSFL = child.SetFrameLevel
        child._arcOrigSetFrameLevel = origSFL
        child.SetFrameLevel = function(self, level)
          -- Only clamp while still parented to the overlay that owns this hook.
          -- LCG uses frame pools — glow frames get released and reacquired for
          -- different targets (proc glow on fd.frame vs ready glow on overlay).
          -- Without this guard, pool-reused frames stay clamped to the old
          -- overlay's level, rendering behind the icon instead of above it.
          if self._arcClampOverlay and self:GetParent() == self._arcClampOverlay then
            origSFL(self, self._arcClampLevel or level)
          else
            origSFL(self, level)
          end
        end
      end
      child._arcClampLevel = maxLevel
      child._arcClampOverlay = overlay
      -- Use stored original to actually set the level now
      if child._arcOrigSetFrameLevel then
        child._arcOrigSetFrameLevel(child, maxLevel)
      end
    end
  end
end
ns.CDMEnhance.ClampOverlayChildren = ClampOverlayChildren

-- Stop all glow effects on a frame's glow overlay
-- @param frame: The icon frame (state flags live here)
-- @param key: Optional glow key (e.g., "ArcUI_Glow", "ArcUI_Preview", "ArcUI_ReadyGlow")
local function StopAllGlows(frame, key)
  if not frame then return end
  if key and ns.Glows then
    ns.Glows.Stop(frame, key)
  elseif ns.Glows then
    ns.Glows.StopAll(frame)
  end
end

-- Export for other modules
ns.CDMEnhance.StopAllGlows = StopAllGlows

-- ===================================================================
-- DATABASE
-- ===================================================================
-- Current settings version - increment when adding new migrations
local SETTINGS_VERSION = 7

-- Migrate a single settings table (icon or global) from legacy to current format
local function MigrateSettingsTable(cfg)
  if not cfg then return end
  
  -- Migration 1: inactiveState → cooldownStateVisuals.cooldownState
  if cfg.inactiveState then
    local legacy = cfg.inactiveState
    local hasLegacyData = legacy.hideWhenInactive or legacy.desaturateWhenInactive or (legacy.dimAlpha and legacy.dimAlpha < 1.0)
    
    if hasLegacyData then
      -- Ensure new structure exists
      if not cfg.cooldownStateVisuals then cfg.cooldownStateVisuals = {} end
      if not cfg.cooldownStateVisuals.cooldownState then cfg.cooldownStateVisuals.cooldownState = {} end
      
      local newState = cfg.cooldownStateVisuals.cooldownState
      
      -- Migrate alpha (hideWhenInactive = 0, dimAlpha = custom value)
      if legacy.hideWhenInactive then
        newState.alpha = 0
      elseif legacy.dimAlpha and legacy.dimAlpha < 1.0 then
        newState.alpha = legacy.dimAlpha
      end
      
      -- Migrate desaturate
      if legacy.desaturateWhenInactive then
        newState.desaturate = true
      end
    end
    
    -- Delete legacy inactiveState entirely
    cfg.inactiveState = nil
  end
  
  -- Migration 2: swipeMode → noGCDSwipe / ignoreAuraOverride
  if cfg.cooldownSwipe and cfg.cooldownSwipe.swipeMode then
    local swipeMode = cfg.cooldownSwipe.swipeMode
    
    if swipeMode == "noGCD" then
      cfg.cooldownSwipe.noGCDSwipe = true
    elseif swipeMode == "cooldownOnly" then
      cfg.cooldownSwipe.ignoreAuraOverride = true
    end
    
    -- Delete legacy swipeMode
    cfg.cooldownSwipe.swipeMode = nil
  end
  
  -- Migration 3: Clean up empty sub-tables
  if cfg.cooldownStateVisuals then
    if cfg.cooldownStateVisuals.readyState and not next(cfg.cooldownStateVisuals.readyState) then
      cfg.cooldownStateVisuals.readyState = nil
    end
    if cfg.cooldownStateVisuals.cooldownState and not next(cfg.cooldownStateVisuals.cooldownState) then
      cfg.cooldownStateVisuals.cooldownState = nil
    end
    if not next(cfg.cooldownStateVisuals) then
      cfg.cooldownStateVisuals = nil
    end
  end
  
  -- Migration 4: Clear zoom=0 so it uses new default (0.075)
  -- Old default was 0, new default is 0.075 for cleaner icon edges
  if cfg.zoom == 0 then
    cfg.zoom = nil  -- nil = use DEFAULT_ICON_SETTINGS.zoom (0.075)
  end
  
  -- Migration 5: Clear edgeScale = 1.0 so CDM's default is used
  -- Our old default (1.0) was too small compared to CDM's actual default (~1.8)
  if cfg.cooldownSwipe and cfg.cooldownSwipe.edgeScale == 1.0 then
    cfg.cooldownSwipe.edgeScale = nil  -- nil = use CDM's default
  end
  
  -- Migration 6: Convert outline "NONE" to "" (WoW expects empty string, not "NONE")
  if cfg.chargeText and cfg.chargeText.outline == "NONE" then
    cfg.chargeText.outline = ""
  end
  if cfg.cooldownText and cfg.cooldownText.outline == "NONE" then
    cfg.cooldownText.outline = ""
  end
  
  -- Migration 7: Sanitize glow boolean values
  -- Convert any non-boolean truthy values to nil (so they fall back to defaults = false)
  -- This fixes a bug where glows could show unexpectedly due to corrupted saved variables
  if cfg.cooldownStateVisuals and cfg.cooldownStateVisuals.readyState then
    local rs = cfg.cooldownStateVisuals.readyState
    -- Glow must be exactly boolean true, anything else should be nil
    if rs.glow ~= nil and rs.glow ~= true and rs.glow ~= false then
      rs.glow = nil
    end
    -- If glow is false, remove it (nil = default = false, saves space)
    if rs.glow == false then
      rs.glow = nil
    end
    -- Sanitize related boolean fields
    if rs.glowCombatOnly ~= nil and rs.glowCombatOnly ~= true and rs.glowCombatOnly ~= false then
      rs.glowCombatOnly = nil
    end
    if rs.glowCombatOnly == false then
      rs.glowCombatOnly = nil
    end
    if rs.glowWhileChargesAvailable ~= nil and rs.glowWhileChargesAvailable ~= true and rs.glowWhileChargesAvailable ~= false then
      rs.glowWhileChargesAvailable = nil
    end
    if rs.glowWhileChargesAvailable == false then
      rs.glowWhileChargesAvailable = nil
    end
  end
  if cfg.cooldownStateVisuals and cfg.cooldownStateVisuals.cooldownState then
    local cs = cfg.cooldownStateVisuals.cooldownState
    -- Sanitize boolean fields
    if cs.desaturate ~= nil and cs.desaturate ~= true and cs.desaturate ~= false then
      cs.desaturate = nil
    end
    if cs.desaturate == false then
      cs.desaturate = nil
    end
    if cs.tint ~= nil and cs.tint ~= true and cs.tint ~= false then
      cs.tint = nil
    end
    if cs.tint == false then
      cs.tint = nil
    end
    if cs.noDesaturate ~= nil and cs.noDesaturate ~= true and cs.noDesaturate ~= false then
      cs.noDesaturate = nil
    end
    if cs.noDesaturate == false then
      cs.noDesaturate = nil
    end
  end
end

-- Clear ignoreAuraOverride from aura settings (auras shouldn't have this option)
local function ClearAuraIgnoreOverride(cfg)
  if cfg and cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride then
    cfg.cooldownSwipe.ignoreAuraOverride = nil
    return true
  end
  return false
end

-- Run all migrations on the entire database
local function RunMigrations(db)
  if not db then return end
  
  local currentVersion = db.settingsVersion or 0
  
  if currentVersion >= SETTINGS_VERSION then
    return -- Already up to date
  end
  
  print("|cff00ff00[ArcUI CDM]|r Running settings migration v" .. currentVersion .. " → v" .. SETTINGS_VERSION)
  
  -- Migrate all per-icon settings
  if db.iconSettings then
    local migratedCount = 0
    for cdID, cfg in pairs(db.iconSettings) do
      MigrateSettingsTable(cfg)
      migratedCount = migratedCount + 1
    end
    if migratedCount > 0 then
      print("|cff00ff00[ArcUI CDM]|r Migrated " .. migratedCount .. " icon settings")
    end
  end
  
  -- Migrate global aura settings
  if db.globalAuraSettings then
    MigrateSettingsTable(db.globalAuraSettings)
    -- Migration v3: Clear ignoreAuraOverride from auras (only valid for cooldowns)
    if ClearAuraIgnoreOverride(db.globalAuraSettings) then
      print("|cff00ff00[ArcUI CDM]|r Cleared ignoreAuraOverride from global aura defaults")
    end
  end
  
  -- Migrate global cooldown settings
  if db.globalCooldownSettings then
    MigrateSettingsTable(db.globalCooldownSettings)
  end
  
  -- (Removed: button glow + threshold migration — button glow now supports threshold alpha)
  
  -- Mark migrations complete
  db.settingsVersion = SETTINGS_VERSION
  print("|cff00ff00[ArcUI CDM]|r Settings migration complete")
  
  -- Schedule a scan after migration to refresh all icons with new settings
  -- Use C_Timer.After to ensure CDM system is ready
  C_Timer.After(1.0, function()
    if not InCombatLockdown() then
      print("|cff00ff00[ArcUI CDM]|r Refreshing icons after migration...")
      if ns.API and ns.API.ScanAllCDMIcons then
        ns.API.ScanAllCDMIcons()
      end
      if ns.CDMGroups and ns.CDMGroups.ScanAllViewers then
        ns.CDMGroups.ScanAllViewers()
      end
      if ns.CDMEnhance and ns.CDMEnhance.RefreshAllStyles then
        ns.CDMEnhance.RefreshAllStyles()
      end
    end
  end)
end

local _dbMigrationDone = false  -- set true after one-time migration checks pass

local function GetDB()
  -- Use profile for settings so they carry across characters
  if not ns.db then return nil end
  
  -- Primary storage in profile (cross-character for GLOBAL DEFAULTS ONLY)
  -- iconSettings and groupSettings are now per-spec in char.cdmGroups.specData
  if not ns.db.profile then ns.db.profile = {} end
  if not ns.db.profile.cdmEnhance then
    ns.db.profile.cdmEnhance = {
      enabled = true,
      settingsVersion = SETTINGS_VERSION,  -- New installs start at current version
      enableAuraCustomization = true,   -- Enable custom styling for aura icons
      enableCooldownCustomization = true, -- Enable custom styling for cooldown icons
      unlocked = false,
      textDragMode = false,
      -- Global "apply to all" toggles
      globalApplyScale = false,
      globalApplyHideShadow = false,
      -- v3.0: New behavior settings
      disableRightClickSelect = false,  -- Disable right-click to open per-icon options
      lockGridSize = false,             -- Prevent grid expansion when dragging icons
      -- NOTE: Migration tracking is now per-character in char.cdmGroups.migratedProfileIconSettings
    }
  end
  
  -- Migration from char to profile (one-time)
  if ns.db.char and ns.db.char.cdmEnhance then
    local charDB = ns.db.char.cdmEnhance
    local profileDB = ns.db.profile.cdmEnhance
    
    -- Migrate globalAuraSettings and globalCooldownSettings if they exist in char but not profile
    if charDB.globalAuraSettings and not profileDB.globalAuraSettings then
      profileDB.globalAuraSettings = CopyTable(charDB.globalAuraSettings)
    end
    if charDB.globalCooldownSettings and not profileDB.globalCooldownSettings then
      profileDB.globalCooldownSettings = CopyTable(charDB.globalCooldownSettings)
    end
    
    -- Clear old char storage
    ns.db.char.cdmEnhance = nil
  end
  
  -- Migration for new fields
  local db = ns.db.profile.cdmEnhance
  if db.enableAuraCustomization == nil then db.enableAuraCustomization = true end
  if db.enableCooldownCustomization == nil then db.enableCooldownCustomization = true end
  if db.globalApplyScale == nil then db.globalApplyScale = false end
  if db.globalApplyHideShadow == nil then db.globalApplyHideShadow = false end
  -- v3.0: New behavior settings migration
  if db.disableRightClickSelect == nil then db.disableRightClickSelect = false end
  if db.lockGridSize == nil then db.lockGridSize = false end
  
  -- Initialize global settings tables (user-configurable defaults - SHARED across all specs)
  if not db.globalAuraSettings then db.globalAuraSettings = {} end
  if not db.globalCooldownSettings then db.globalCooldownSettings = {} end
  
  -- ═══════════════════════════════════════════════════════════════════════════
  -- FIRST-TIME USER DEFAULTS
  -- Set up sensible defaults for brand new installations
  -- Only applies when both global settings are completely empty (no user changes yet)
  -- ═══════════════════════════════════════════════════════════════════════════
  if not db._firstTimeDefaultsApplied then
    local auraEmpty = not next(db.globalAuraSettings)
    local cooldownEmpty = not next(db.globalCooldownSettings)
    
    if auraEmpty and cooldownEmpty then
      -- This is a brand new user - set up recommended defaults
      
      -- Aura Defaults
      db.globalAuraSettings = {
        border = {
          enabled = true,
          color = {0, 0, 0, 1},  -- Black border
          thickness = 1,
          inset = 0,
        },
      }
      
      -- Cooldown Defaults
      db.globalCooldownSettings = {
        border = {
          enabled = true,
          color = {0, 0, 0, 1},  -- Black border
          thickness = 1,
          inset = 0,
        },
        cooldownSwipe = {
          noGCDSwipe = true,  -- Hide GCD swipes (cleaner during combat)
        },
        rangeIndicator = {
          enabled = false,  -- Disable range indicator overlay
        },
      }
      
      print("|cff00ff00[ArcUI CDM]|r Applied recommended defaults for new installation")
    end
    
    -- Mark as processed so we don't overwrite user changes on subsequent loads
    db._firstTimeDefaultsApplied = true
  end

  
  -- ═══════════════════════════════════════════════════════════════════════════
  -- MIGRATION: iconSettings/groupSettings from profile to per-character storage
  -- - Old characters: migrate from profile.cdmEnhance to char.cdmGroups.specData
  -- - New characters: start fresh (no data to migrate)
  -- - Profile data is KEPT so other characters can still migrate from it
  -- ═══════════════════════════════════════════════════════════════════════════
  
  -- One-time migration checks — skip after first successful pass
  if not _dbMigrationDone then
    local cdmGroupsDB = Shared.GetCDMGroupsDB()
    if cdmGroupsDB and not cdmGroupsDB.migratedProfileIconSettings then
      local specData = Shared.GetCurrentSpecData()
    if specData then
      local didMigrate = false
      
      -- Migrate iconSettings if profile has them and active profile doesn't
      -- NOTE: Now writes to profile.iconSettings via Shared.GetSpecIconSettings()
      if db.iconSettings and next(db.iconSettings) then
        local profileIconSettings = Shared.GetSpecIconSettings()
        if profileIconSettings and (not next(profileIconSettings)) then
          for cdID, settings in pairs(db.iconSettings) do
            if not profileIconSettings[cdID] then
              profileIconSettings[cdID] = CopyTable(settings)
            end
          end
          print("|cff00ff00[ArcUI CDM]|r Migrated per-icon settings to profile storage")
          didMigrate = true
        end
      end
      
      -- Migrate groupSettings if profile has them and char spec doesn't
      if db.groupSettings and next(db.groupSettings) then
        if not specData.groupSettings or not next(specData.groupSettings.aura or {}) then
          for vtype, settings in pairs(db.groupSettings) do
            if type(settings) == "table" and next(settings) then
              if not specData.groupSettings[vtype] then
                specData.groupSettings[vtype] = {}
              end
              for k, v in pairs(settings) do
                if specData.groupSettings[vtype][k] == nil then
                  specData.groupSettings[vtype][k] = v
                end
              end
            end
          end
          if didMigrate then
            print("|cff00ff00[ArcUI CDM]|r Migrated group settings to character storage")
          end
          didMigrate = true
        end
      end
      
      -- Mark this character as checked (won't try to migrate again)
        cdmGroupsDB.migratedProfileIconSettings = true
      end
    end
    -- Clean up old flag that was in wrong place
    if db.migratedToSpecBased then db.migratedToSpecBased = nil end
    -- Remove old position system fields
    if db.positions then db.positions = nil end
    if db.cdmDefaultPositions then db.cdmDefaultPositions = nil end
    if db.auraPositionMode then db.auraPositionMode = nil end
    if db.cooldownPositionMode then db.cooldownPositionMode = nil end
    if db.auraSpacing then db.auraSpacing = nil end
    if db.cooldownSpacing then db.cooldownSpacing = nil end
    if db.groupPositions then db.groupPositions = nil end
    -- Run settings migrations (has its own version guard — cheap when up-to-date)
    RunMigrations(db)
    _dbMigrationDone = true
  end
  
  return db
end

-- Function to restore saved Edit Mode scales from DB
local function RestoreSavedEditModeScales()
  local db = GetDB()
  if db and db.editModeScales then
    for vType, scale in pairs(db.editModeScales) do
      if scale and scale > 0 then
        groupScales[vType] = scale
      end
    end
  end
end

-- Deep merge: overlay source onto dest, only overwriting non-nil values
-- Returns a new table (doesn't modify inputs)
local function DeepMergeSettings(dest, source)
  if not source then return dest end
  if not dest then return CopyTable(source) end
  
  local result = CopyTable(dest)
  for k, v in pairs(source) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = DeepMergeSettings(result[k], v)
    elseif v ~= nil then
      result[k] = v
    end
  end
  return result
end

local DEFAULT_ICON_SETTINGS = {
  -- Visual Scaling
  scale = 1.0,
  -- NOTE: width/height are nil by default to preserve CDM's native icon size
  -- They only get set when user explicitly changes them via the sliders
  aspectRatio = 1.0,  -- 1.0 = square, >1 = wider, <1 = taller
  zoom = 0.075,  -- Default slight zoom to crop icon borders
  padding = 0,
  alpha = 1.0,
  keepBright = false,  -- Prevent all dimming/desaturation (icon stays full brightness always)
  keepBrightAllowDesat = false,  -- When keepBright is on, still allow desaturation (grayscale on cooldown)
  forceHideIcon = false,  -- Hide the icon ART (texture) only — keeps stack/duration text + swipe/border. Cooldowns AND auras. Opt-in.
  customIconID = nil,  -- Custom icon override: spell ID or texture file ID (nil = use default CDM icon)
  shadowSize = 1.0,    -- Shadow size multiplier (1.0 = proportional to icon size)
  
  -- Cooldown State Visual Options (two-state system)
  -- Controls how icon appears when Ready vs On Cooldown
  cooldownStateVisuals = {
    -- Ready State (spell is available/buff is active)
    readyState = {
      alpha = 1.0,           -- Alpha when ready (0-1)
      glow = false,          -- Show glow while ready
      glowColor = nil,       -- nil = default gold, or {r, g, b}
      glowWhileChargesAvailable = false,  -- For charge spells: glow while any charge available (vs only when ALL charges ready)
    },
    -- On Cooldown State (spell on CD/buff not active)  
    cooldownState = {
      alpha = 1.0,           -- Alpha when on cooldown (0-1)
      desaturate = false,    -- We apply desaturation (for auras that CDM doesn't desaturate)
      noDesaturate = false,  -- Block CDM's default desaturation (for cooldowns)
    },
  },
  
  -- Range Indicator
  rangeIndicator = {
    enabled = true,           -- Show out-of-range overlay (CDM default behavior)
  },
  
  -- Spell Usability (tinting when spell not usable / not enough resources)
  spellUsability = {
    enabled = true,            -- Enable usability tinting (CDM default behavior)
    procOverride = false,      -- If true, proc active overrides usability alpha dimming
  },
  
  -- Proc Glow (SpellActivationAlert)
  procGlow = {
    enabled = true,           -- Show proc glow animation
    alpha = 1.0,              -- Glow intensity (0 = invisible, 1 = full)
    scale = 1.0,              -- Glow size multiplier (works for all glow types)
    color = nil,              -- nil = default gold, or {r, g, b} to tint
    glowType = "default",     -- "default" (CDM's glow), "pixel", "autocast", "button", "proc" (LCG glows)
    -- Pixel glow options
    lines = 8,                -- Number of lines (pixel glow)
    thickness = 2,            -- Line thickness (pixel glow)
    -- AutoCast glow options
    particles = 4,            -- Number of particle groups (autocast glow)
    -- Speed (all custom glows)
    speed = 0.25,             -- Animation speed/frequency
  },
  
  -- Border (edge overlays)
  border = {
    enabled = false,
    color = {1, 1, 1, 1},
    thickness = 2,
    inset = -3,
    useClassColor = false,
    followDesaturation = false,  -- Desaturate border when icon is desaturated
  },
  
  -- Cooldown Swipe/Animation
  cooldownSwipe = {
    showSwipe = true,       -- The clock/darken animation
    noGCDSwipe = false,     -- Hide GCD swipes (1.5s or less)
    swipeWaitForNoCharges = false, -- For charge spells: only show swipe when ALL charges consumed
    edgeWaitForNoCharges = false,  -- For charge spells: only show edge when ALL charges consumed
    hideTextWithSwipe = false,     -- When swipeWaitForNoCharges hides swipe, also hide duration text
    showEdge = true,        -- The spinning bright line
    showBling = true,       -- Flash when cooldown finishes
    reverse = false,        -- Reverse swipe direction
    reverseWhileAura = false, -- Reverse swipe while the aura is active on this icon
    swipeColor = nil,       -- nil = use CDM default, or {r, g, b, a} to override
    edgeScale = nil,        -- Scale of the spinning edge line (nil = use CDM default, typically ~1.8)
    edgeColor = nil,        -- nil = use default, or {r, g, b, a} to override
    swipeInset = 0,         -- Single inset for swipe (all sides)
    separateInsets = false, -- Enable separate X/Y insets
    swipeInsetX = 0,        -- Horizontal inset (left/right) for swipe
    swipeInsetY = 0,        -- Vertical inset (top/bottom) for swipe
    -- NOTE: ignoreAuraOverride moved to auraActiveState section
  },
  
  -- Aura Active State (when buff/aura is active on icon)
  -- Customizations for how the icon appears when the associated aura is up
  auraActiveState = {
    ignoreAuraOverride = false,  -- Show spell cooldown instead of aura duration
    glow = false,                -- Show glow while aura is active (cooldown frames only)
    glowFollowPandemic = false,  -- Only show glow when CDM enters pandemic window (uses CDM timing, ignores % threshold)
    glowWhenMissing = false,     -- Invert: show glow when aura is NOT active
    glowType = "button",         -- "button", "pixel", "autocast", "proc"
    glowColor = nil,             -- nil = default gold, or {r, g, b}
    glowIntensity = 1.0,         -- Glow brightness (0-1)
    glowScale = 1.0,             -- Glow size multiplier
    glowSpeed = 0.25,            -- Animation speed
    glowLines = 8,               -- Pixel glow lines
    glowThickness = 2,           -- Pixel glow thickness
    glowParticles = 4,           -- AutoCast particles
    glowCombatOnly = false,      -- Only show glow in combat
    glowFrameStrata = nil,       -- nil = inherit parent strata, or "LOW"/"MEDIUM"/"HIGH"/"DIALOG"
    desaturateWhenInactive = false,  -- COOLDOWN icons only: desaturate the icon while its tracked aura is NOT active (supersedes all other desat). Opt-in.
  },

  -- Debuff Border (debuff type color indicator - magic=blue, curse=purple, etc.)
  debuffBorder = {
    enabled = false,  -- Show debuff type border (default hidden)
    -- When enabled, border will be sized to match icon with zoom/padding
  },
  
  -- Pandemic Border (red glow when aura is in pandemic window - 30% remaining)
  pandemicBorder = {
    enabled = false,  -- Show pandemic indicator (default hidden - we have custom alerts)
    -- When enabled, border will be sized to match icon with zoom/padding
  },
  
  -- Alert Events (triggered by CDM's TriggerAlertEvent)
  -- For Auras: Available=applied, PandemicTime=30% left, OnCooldown=expired
  -- For Cooldowns: Available=ready, OnCooldown=used, ChargeGained=charge restored
  alertEvents = {
    onAvailable = {         -- Aura applied / Cooldown ready
      playSound = false,
      soundFile = nil,      -- Custom sound file name (e.g. "TadaFanfare") or nil
      soundID = 8959,       -- Fallback: SOUNDKIT sound ID
      showGlow = false,
      glowColor = nil,      -- {r, g, b} or nil for default
    },
    onPandemic = {          -- Aura at 30% remaining (auras only)
      playSound = false,
      soundFile = nil,
      soundID = 43499,      -- Warning sound
      showGlow = false,
      glowColor = {r = 1, g = 0.5, b = 0},  -- Orange warning
    },
    onUnavailable = {       -- Aura expired / Cooldown used
      playSound = false,
      soundFile = nil,
      soundID = nil,
      stopGlow = true,      -- Stop any active glow
    },
    onChargeGained = {      -- Cooldown charge restored (cooldowns only)
      playSound = false,
      soundFile = nil,
      soundID = 8959,
      showGlow = false,
      glowColor = nil,
    },
  },
  
  -- Charge/Stack Text
  chargeText = {
    enabled = true,
    autoHide = true,        -- Hide when stack count is 0 or 1
    hideAtZero = false,     -- Hide charge count text when all charges are spent (charges = 0)
    showSingleStack = false, -- Show "1" when aura has exactly 1 stack (CDM hides by default)
    size = 16,
    color = {r = 1, g = 1, b = 1, a = 1},
    font = "Friz Quadrata TT",
    outline = "OUTLINE",
    shadow = false,
    shadowOffsetX = 1,
    shadowOffsetY = -1,
    -- Positioning
    mode = "anchor",  -- "anchor" or "free"
    anchor = "BOTTOMRIGHT",
    offsetX = -2,
    offsetY = 2,
    -- Free position (relative to icon center)
    freeX = 0,
    freeY = 0,
    -- Threshold-colored stack count (secret-safe; colors the NUMBER only).
    -- Each enabled band shows the same overlapped number via
    -- GetAuraApplicationDisplayCount(min-only); the highest reached threshold's
    -- color wins. See ArcUI_StackColor.lua. Fixed 6 slots = merge-safe (mirrors
    -- durationColorCustom). Below the lowest enabled threshold the number is
    -- hidden, so the lowest band's threshold also acts as the "show from" count.
    thresholdColorEnabled = false,  -- OFF by default (opt-in)
    thresholdBands = {
      { enabled = true,  threshold = 1, color = {r = 1,   g = 1,   b = 1,   a = 1} },  -- white  1+
      { enabled = true,  threshold = 3, color = {r = 0.3, g = 1,   b = 0.3, a = 1} },  -- green  3+
      { enabled = true,  threshold = 6, color = {r = 1,   g = 0.3, b = 0.3, a = 1} },  -- red    6+
      { enabled = false, threshold = 9, color = {r = 1,   g = 0.6, b = 0,   a = 1} },  -- orange 9+
      { enabled = false, threshold = 12, color = {r = 0.6, g = 0.4, b = 1,   a = 1} }, -- purple 12+
      { enabled = false, threshold = 15, color = {r = 0.3, g = 0.7, b = 1,   a = 1} }, -- blue   15+
    },
  },

  -- Cooldown Text (timer)
  cooldownText = {
    enabled = true,
    hideWhenHasCharges = false, -- Hide cooldown text when charges > 0 (useful for overlaying charge + CD text)
    size = 14,
    color = {r = 1, g = 1, b = 1, a = 1},
    font = "Friz Quadrata TT",
    outline = "OUTLINE",
    shadow = false,
    shadowOffsetX = 1,
    shadowOffsetY = -1,
    -- Duration-based text coloring
    durationColor = false,              -- Enable color-by-remaining-duration
    durationColorPreset = "custom",    -- "custom", "classic", "warm", "cool", "nature", "urgent"
    durationColorCustom = {             -- Custom color stops (used when preset = "custom")
      { enabled = true,  threshold = 5,    color = {r=1, g=0.39, b=0.28, a=1} },  -- Red
      { enabled = true,  threshold = 60,   color = {r=1, g=1, b=0, a=1} },        -- Yellow
      { enabled = true,  threshold = 3600, color = {r=1, g=1, b=1, a=1} },        -- White
      { enabled = false, threshold = 120,  color = {r=0, g=1, b=0, a=1} },        -- Green
      { enabled = false, threshold = 300,  color = {r=0.5, g=0.5, b=1, a=1} },    -- Blue
    },
    durationColorCustomDefault = {r=0.67, g=0.67, b=0.67, a=1},  -- Above highest threshold
    -- Positioning
    mode = "anchor",  -- "anchor" or "free"
    anchor = "CENTER",
    offsetX = 0,
    offsetY = 0,
    -- Free position (relative to icon center)
    freeX = 0,
    freeY = 0,
    -- 3.6.6 Duration-text formatting (12.0.5 native Cooldown APIs — zero polling)
    decimals = 0,                    -- 0 = integer seconds, 1 = one decimal via engine
    decimalThreshold = 0,            -- seconds; show decimal only when remaining < this. 0 = always show (no threshold).
    abbrevThreshold = 0,             -- seconds; 0 = off (engine default), positive = M:SS form below this many seconds remaining
  },
}

-- Get effective icon settings (merges global defaults + per-icon overrides)
-- Used when APPLYING styles and for options UI display
local effectiveSettingsCache = {}  -- Cache to avoid repeated merging
local effectiveSettingsCacheVersion = 0

local function InvalidateEffectiveSettingsCache()
  effectiveSettingsCacheVersion = effectiveSettingsCacheVersion + 1
  wipe(effectiveSettingsCache)
end

-- Get RAW per-icon settings (only what user has actually customized, no auto-creation)
-- Used for merging with global settings
-- NOW USES SPEC-BASED STORAGE (per-character, per-spec)
local function GetRawIconSettings(cooldownID)
  local iconSettings = Shared.GetSpecIconSettings()
  if not iconSettings then return nil end
  
  local key = tostring(cooldownID)
  return iconSettings[key]  -- May be nil if user hasn't customized this icon
end

local function GetEffectiveIconSettings(cooldownID)
  -- FAST PATH: Check cache first with minimal overhead
  -- Use cooldownID directly as key (works for both numbers and strings)
  if cooldownID then
    local cached = effectiveSettingsCache[cooldownID]
    if cached and cached.version == effectiveSettingsCacheVersion then
      return cached.cfg
    end
  end
  
  -- SLOW PATH: Cache miss - do full validation and build
  local db = GetDB()
  if not db then return CopyTable(DEFAULT_ICON_SETTINGS) end
  
  -- Validate cooldownID
  if not cooldownID or cooldownID == 0 then
    return CopyTable(DEFAULT_ICON_SETTINGS)
  end
  
  -- Allow Arc Aura string IDs (they start with "arc_")
  local isArcAura = type(cooldownID) == "string" and cooldownID:match("^arc_")
  
  -- Must be number OR Arc Aura string ID
  if not isArcAura and type(cooldownID) ~= "number" then
    return CopyTable(DEFAULT_ICON_SETTINGS)
  end
  
  -- Determine icon type for global settings selection using CDM category
  -- Category 0 (Essential) / Category 1 (Utility) = cooldown settings
  -- Category 2 (TrackedBuff) = aura settings
  -- IMPORTANT: isAura controls TWO things:
  --   1. globalSettings bucket selection
  --   2. effective._isAura flag -> routes frame through OptimizedApplyIconVisuals
  -- arc_* IDs use globalAuraSettings for cascade (Inactive/Ready Alpha sliders apply)
  -- but _isAura MUST stay false — if true, OptimizedApplyIconVisuals fires, finds no
  -- active aura, and sets alpha 0. ArcAuras polling owns their visual state.
  local isAura = false  -- routing flag: stays false for arc_* so OptimizedApply never fires
  local spellID = nil
  
  -- Use safe wrapper (returns nil for Arc Aura string IDs)
  local cdInfo = Shared.SafeGetCDMInfo and Shared.SafeGetCDMInfo(cooldownID)
  if cdInfo then
    isAura = Shared.IsAuraCategory(cdInfo.category)
    spellID = cdInfo.overrideSpellID or cdInfo.spellID
  end
  
  -- arc_* IDs use cooldown globals (same as Essential/Utility cooldowns)
  local globalSettings = isAura and db.globalAuraSettings or db.globalCooldownSettings
  
  -- Get raw per-icon settings (only user customizations, not auto-created defaults)
  local perIcon = GetRawIconSettings(cooldownID)
  
  -- Build effective settings: defaults -> global -> per-icon
  local effective = CopyTable(DEFAULT_ICON_SETTINGS)
  
  -- Apply global settings if any
  if globalSettings and next(globalSettings) then
    effective = DeepMergeSettings(effective, globalSettings)
  end
  
  -- Apply per-icon overrides if any (these are actual user customizations)
  if perIcon and next(perIcon) then
    effective = DeepMergeSettings(effective, perIcon)
  end
  
  -- Store CDM category info in config (avoids duplicate API calls in ApplyCooldownStateVisuals)
  effective._isAura = isAura
  effective._spellID = spellID
  
  -- MASQUE COMPATIBILITY: When Masque skinning is enabled, force defaults for appearance settings
  -- Masque controls icon borders/textures, so ArcUI shouldn't apply zoom/padding/aspectRatio
  -- Check requires: ns.Masque exists, IsEnabled function exists, AND IsEnabled() returns true
  local masqueEnabled = ns.Masque and ns.Masque.IsEnabled and (ns.Masque.IsEnabled() == true)
  if masqueEnabled then
    effective.aspectRatio = 1.0
    effective.zoom = 0
    effective.padding = 0
  end
  
  -- Cache the result (use cooldownID directly as key)
  effectiveSettingsCache[cooldownID] = { version = effectiveSettingsCacheVersion, cfg = effective }
  
  return effective
end

-- OPTIMIZED: Get effective settings with frame-level caching
-- This bypasses string conversion and table lookup on cache hit
local function GetEffectiveIconSettingsForFrame(frame)
  if not frame then return nil end
  
  -- FAST PATH: Check frame-level cache first (no string conversion, no table lookup)
  -- SAFETY: Also verify the cached settings are for the CURRENT cooldownID
  -- CDM can reassign frames to new spells, which changes frame.cooldownID
  -- without triggering a cache version bump
  if frame._arcCfg and frame._arcCfgVersion == effectiveSettingsCacheVersion then
    if frame._arcCfgCdID == frame.cooldownID then
      return frame._arcCfg
    end
    -- cdID changed underneath — cache is stale, fall through to refresh
  end
  
  -- Cache miss - get from main cache (which may also be a hit)
  local cdID = frame.cooldownID
  if not cdID then return nil end
  
  local cfg = GetEffectiveIconSettings(cdID)
  
  -- Store on frame for next time (including which cdID this is for)
  frame._arcCfg = cfg
  frame._arcCfgVersion = effectiveSettingsCacheVersion
  frame._arcCfgCdID = cdID
  
  -- Cache derived booleans used by hot hooks (SetDesaturated, SetDesaturation,
  -- SetVertexColor, UpdateGlow) so they can fast-exit without calling
  -- GetEffectiveIconSettingsForFrame or GetEffectiveStateVisuals.
  -- These are recomputed only on cache miss (settings change).
  if cfg then
    local sv = GetEffectiveStateVisuals(cfg)
    frame._arcCachedStateVisuals      = sv
    -- Any cfg-level reason to intercept desaturation?
    -- IAO frames always own desat — must never fast-path to PASSTHROUGH.
    frame._arcCachedNeedDesatIntercept = (cfg.keepBright == true) or (sv ~= nil and sv.noDesaturate == true)
        or (((cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
            or (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)) == true)
    -- Any cfg-level reason to intercept vertex color?
    frame._arcCachedNeedVertexIntercept = (cfg.keepBright == true)
    -- Is usable glow enabled for this icon? (opt-in default = false)
    local su = cfg.spellUsability
    frame._arcCachedUsableGlowEnabled  = su ~= nil and su.usableGlow == true
  else
    frame._arcCachedStateVisuals        = nil
    frame._arcCachedNeedDesatIntercept  = false
    frame._arcCachedNeedVertexIntercept = false
    frame._arcCachedUsableGlowEnabled   = false
  end
  
  return cfg
end

-- Export for hooks that reference ns.CDMEnhance.GetEffectiveIconSettingsForFrame
ns.CDMEnhance.GetEffectiveIconSettingsForFrame = GetEffectiveIconSettingsForFrame

-- Get per-icon settings (for options UI display - returns effective merged settings)
-- Does NOT auto-create entries - use GetOrCreateIconSettings when user makes a change
local function GetIconSettings(cooldownID)
  local db = GetDB()
  if not db then return nil end
  
  -- Return effective settings (for display in options UI)
  -- This merges defaults + global + per-icon without creating entries
  return GetEffectiveIconSettings(cooldownID)
end

-- Ensure per-icon settings entry exists (call this when user makes a change)
-- Get or create per-icon settings with full structure (for setters)
-- NOW USES SPEC-BASED STORAGE (per-character, per-spec)
local function GetOrCreateIconSettings(cooldownID)
  local iconSettings = Shared.GetSpecIconSettings()
  if not iconSettings then
    return nil
  end
  local key = tostring(cooldownID)
  if not iconSettings[key] then iconSettings[key] = {} end
  InvalidateEffectiveSettingsCache()
  return iconSettings[key]
end

-- ===================================================================
-- DATABASE CLEANUP UTILITIES
-- Remove empty tables and values matching defaults from per-icon settings
-- This keeps the SavedVariables clean and ensures global settings work
-- ===================================================================

-- Recursively remove empty tables from a settings table
local function RemoveEmptyTables(tbl)
  if type(tbl) ~= "table" then return end
  
  for k, v in pairs(tbl) do
    if type(v) == "table" then
      RemoveEmptyTables(v)
      if not next(v) then
        tbl[k] = nil
      end
    end
  end
end

-- Check if a value matches the default (for cleanup)
local function ValueMatchesDefault(value, default)
  if type(value) ~= type(default) then return false end
  
  if type(value) == "table" then
    -- For color tables, compare contents
    if value.r or value[1] then
      local vr = value.r or value[1] or 0
      local vg = value.g or value[2] or 0
      local vb = value.b or value[3] or 0
      local va = value.a or value[4] or 1
      local dr = default.r or default[1] or 0
      local dg = default.g or default[2] or 0
      local db = default.b or default[3] or 0
      local da = default.a or default[4] or 1
      return math.abs(vr-dr) < 0.01 and math.abs(vg-dg) < 0.01 and 
             math.abs(vb-db) < 0.01 and math.abs(va-da) < 0.01
    end
    return false  -- Other tables don't match
  end
  
  if type(value) == "number" then
    return math.abs(value - default) < 0.001
  end
  
  return value == default
end

-- Clean up ALL icon settings in current profile - ONLY remove empty tables
-- IMPORTANT: We do NOT remove values matching defaults anymore!
-- Reason: Per-icon values that match DEFAULT_ICON_SETTINGS may still be needed
-- to override globalCooldownSettings/globalAuraSettings which have different values.
-- Example: DEFAULT_ICON_SETTINGS.chargeText.enabled = true
--          globalCooldownSettings.chargeText.enabled = false
--          Per-icon chargeText.enabled = true (user wants to show it)
-- If we removed the per-icon value (matches default), it would fall back to
-- globalCooldownSettings and hide the charge text - not what the user wanted!
local function CleanupAllIconSettings()
  local iconSettings = Shared.GetSpecIconSettings()
  if not iconSettings then return 0, 0 end
  
  local cleanedCount = 0
  local removedCount = 0
  
  for key, settings in pairs(iconSettings) do
    local hadSettings = next(settings) ~= nil
    
    -- Only remove empty tables, preserve all actual values
    RemoveEmptyTables(settings)
    
    if not next(settings) then
      iconSettings[key] = nil
      if hadSettings then
        removedCount = removedCount + 1
      end
    elseif hadSettings then
      cleanedCount = cleanedCount + 1
    end
  end
  
  -- Invalidate cache
  InvalidateEffectiveSettingsCache()
  
  return cleanedCount, removedCount
end

-- Expose cleanup function for import/export and internal use
ns.CDMEnhance.CleanupAllIconSettings = CleanupAllIconSettings

-- Auto-cleanup on profile ready (called by CDMShared when profile is loaded)
-- This ensures old bloated databases get cleaned automatically
-- Silent - only prints if DEBUG is enabled
function ns.CDMEnhance.OnProfileReady()
  -- Delay slightly to ensure all data is loaded
  C_Timer.After(0.5, function()
    local cleaned, removed = CleanupAllIconSettings()
    -- Silent cleanup - don't spam user with messages
    if _G.ARCUI_DEBUG and (cleaned > 0 or removed > 0) then
      print("|cff00ccffArcUI|r: [Debug] Auto-cleaned icon database (" .. removed .. " empty entries removed)")
    end
  end)
end

-- ===================================================================
-- HELPERS
-- ===================================================================
local function GetFontPath(fontName)
  -- Default fallback font
  local defaultFont = "Fonts\\FRIZQT__.TTF"
  
  if not fontName then return defaultFont end
  
  if LSM then
    local path = LSM:Fetch("font", fontName)
    if path and path ~= "" then
      return path
    end
  end
  
  -- If fontName looks like a path already, use it directly
  if fontName:find("\\") or fontName:find("/") then
    return fontName
  end
  
  return defaultFont
end

-- Safe SetFont wrapper - forces font refresh by temporarily changing size
-- WoW caches font objects internally and sometimes doesn't refresh when only path changes
local function SafeSetFont(fontString, fontPath, fontSize, outline)
  if not fontString or not fontString.SetFont then return false end
  
  -- Normalize outline - WoW expects "" for no outline, not "NONE" or nil
  if not outline or outline == "" or outline == "NONE" then
    outline = ""
  end
  
  -- Get current font info to check if we need to force refresh
  local currentPath, currentSize, currentOutline = fontString:GetFont()
  
  -- FORCE REFRESH: WoW caches fonts - if only path is changing, it may not update
  -- Set to a different size first to force WoW to recreate the font object
  if currentSize and currentSize == fontSize then
    -- Temporarily set different size to break the cache
    fontString:SetFont(fontPath, fontSize + 0.01, outline)
  end
  
  -- Now set the actual font
  fontString:SetFont(fontPath, fontSize, outline)
  
  -- Force text refresh - some fonts need this to display correctly
  local currentText = fontString:GetText()
  if currentText then
    fontString:SetText(currentText)
  end
  
  -- Verify the font was set correctly
  local actualPath = fontString:GetFont()
  if not actualPath or actualPath == "" then
    -- Font failed to load completely, fallback to default
    fontString:SetFont("Fonts\\FRIZQT__.TTF", fontSize, outline)
    return false
  end
  
  return true
end

local function GetClassColor()
  local _, class = UnitClass("player")
  local color = RAID_CLASS_COLORS[class]
  if color then
    return {color.r, color.g, color.b, 1}
  end
  return {1, 1, 1, 1}
end

-- ===================================================================
-- CUSTOM SOUNDS
-- ===================================================================
-- Available sound files in Interface\AddOns\ArcUI\Sounds\
local CUSTOM_SOUNDS = {
  "AcousticGuitar", "AirHorn", "Applause", "BananaPeelSlip", "BatmanPunch",
  "BikeHorn", "Blast", "Bleat", "BoxingArenaSound", "Brass", "CartoonVoiceBaritone",
  "CartoonWalking", "CatMeow2", "ChickenAlarm", "CowMooing", "DoubleWhoosh",
  "Drums", "ErrorBeep", "Glass", "GoatBleating", "HeartbeatSingle", "KittenMeow",
  "OhNo", "RingingPhone", "RoaringLion", "RobotBlip", "RoosterChickenCalls",
  "SharpPunch", "SheepBleat", "Shotgun", "SqueakyToyShort", "SquishFart",
  "SynthChord", "TadaFanfare", "TempleBellHuge", "Torch", "WarningSiren",
  "WaterDrop", "Xylophone",
}

local function PlayAlertSound(soundFile, soundID)
  if soundFile and soundFile ~= "" then
    -- Play custom sound file
    local path = "Interface\\AddOns\\ArcUI\\Sounds\\" .. soundFile .. ".ogg"
    PlaySoundFile(path, "Master")
  elseif soundID then
    -- Fall back to sound ID
    PlaySound(soundID)
  end
end

-- Export for options
ns.CUSTOM_SOUNDS = CUSTOM_SOUNDS

-- ===================================================================
-- POSITION MANAGEMENT (Per-Icon Positions)
-- v3.2: SetParent(UIParent) approach with scale-aware positioning
-- Key: Always check cooldownID's saved config, not frame flags
-- Uses raw screen pixels for position storage to avoid scale issues
-- ===================================================================

-- NOTE: TriggerCDMRefreshViaEditMode removed - CDMGroups handles layout directly
-- NOTE: Screen pixel functions removed - CDMGroups handles all positioning
-- NOTE: ApplyIconPosition, ApplyAllIconPositions, and SaveIconPosition have been removed
-- CDMGroups now handles ALL icon positioning

local function ResetIconPosition(cdID)
  -- Get the ACTUAL stored per-icon settings (not the merged copy!)
  -- Now using spec-based storage
  local iconSettings = Shared.GetSpecIconSettings()
  
  local key = tostring(cdID)
  if iconSettings and iconSettings[key] then
    -- Reset position in the actual stored settings
    iconSettings[key].position = {
      mode = "group",
      freeX = 0,
      freeY = 0,
    }
  end
  
  -- Return frame to original parent
  local data = enhancedFrames[cdID]
  if data and data.frame then
    local frame = data.frame
    
    -- Return to original parent so CDM can reclaim it
    if frame._arcOriginalParent then
      frame:SetParent(frame._arcOriginalParent)
      frame._arcOriginalParent = nil
    end
  end
  
  -- Invalidate cache since we modified settings
  InvalidateEffectiveSettingsCache()
end

-- Check if icon has custom position (non-group mode)
local function HasCustomPosition(cdID)
  local cfg = GetIconSettings(cdID)
  return cfg and cfg.position and cfg.position.mode ~= "group"
end

-- ===================================================================
-- BORDER (4 edge textures at OVERLAY level)
-- ===================================================================
local function CreateBorderEdges(frame)
  if frame._arcBorderEdges then return frame._arcBorderEdges end
  
  local edges = {}
  
  edges.top = frame:CreateTexture(nil, "OVERLAY", nil, 7)
  edges.top:SetColorTexture(1, 1, 1, 1)
  edges.top:SetSnapToPixelGrid(true)
  edges.top:SetTexelSnappingBias(1)
  
  edges.bottom = frame:CreateTexture(nil, "OVERLAY", nil, 7)
  edges.bottom:SetColorTexture(1, 1, 1, 1)
  edges.bottom:SetSnapToPixelGrid(true)
  edges.bottom:SetTexelSnappingBias(1)
  
  edges.left = frame:CreateTexture(nil, "OVERLAY", nil, 7)
  edges.left:SetColorTexture(1, 1, 1, 1)
  edges.left:SetSnapToPixelGrid(true)
  edges.left:SetTexelSnappingBias(1)
  
  edges.right = frame:CreateTexture(nil, "OVERLAY", nil, 7)
  edges.right:SetColorTexture(1, 1, 1, 1)
  edges.right:SetSnapToPixelGrid(true)
  edges.right:SetTexelSnappingBias(1)
  
  frame._arcBorderEdges = edges
  return edges
end

local function UpdateIconBorder(frame, cdID, iconWidth, iconHeight, padding, zoom)
  if not cdID then return end
  
  local cfg = GetIconSettings(cdID)
  if not cfg or not cfg.border then return end
  
  local edges = frame._arcBorderEdges or CreateBorderEdges(frame)
  
  if cfg.border.enabled then
    local color
    if cfg.border.useClassColor then
      color = GetClassColor()
    else
      color = cfg.border.color or {1, 1, 1, 1}
    end
    
    local r, g, b, a = color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1
    
    -- Note: Border desaturation is handled by ApplyBorderDesaturation/ApplyBorderDesaturationFromDuration
    -- which are called from ApplyCooldownStateVisuals. We just set the base color here.
    
    local thickness = cfg.border.thickness or 2
    -- Snap border thickness to exact physical pixel count
    thickness = PixelUtil.GetNearestPixelSize(thickness, frame:GetEffectiveScale(), 1)
    
    -- Border position is controlled SOLELY by the inset slider
    -- No longer affected by zoom or padding - user has full control
    local userOffset = cfg.border.inset or -3
    
    -- Snap inset to physical pixel boundary — at fractional scales (e.g. 0.53333)
    -- a raw float inset lands on a fractional physical pixel, causing left/right
    -- borders to differ by 1px and padding to flicker between values.
    local insetX = PixelUtil.GetNearestPixelSize(userOffset, frame:GetEffectiveScale(), 0)
    local insetY = insetX
    
    -- Top edge
    edges.top:ClearAllPoints()
    edges.top:SetPoint("TOPLEFT", frame, "TOPLEFT", insetX, -insetY)
    edges.top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -insetX, -insetY)
    edges.top:SetHeight(thickness)
    edges.top:SetVertexColor(r, g, b, a)
    edges.top:Show()
    
    -- Bottom edge
    edges.bottom:ClearAllPoints()
    edges.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", insetX, insetY)
    edges.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -insetX, insetY)
    edges.bottom:SetHeight(thickness)
    edges.bottom:SetVertexColor(r, g, b, a)
    edges.bottom:Show()
    
    -- Left edge
    edges.left:ClearAllPoints()
    edges.left:SetPoint("TOPLEFT", frame, "TOPLEFT", insetX, -insetY)
    edges.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", insetX, insetY)
    edges.left:SetWidth(thickness)
    edges.left:SetVertexColor(r, g, b, a)
    edges.left:Show()
    
    -- Right edge
    edges.right:ClearAllPoints()
    edges.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -insetX, -insetY)
    edges.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -insetX, insetY)
    edges.right:SetWidth(thickness)
    edges.right:SetVertexColor(r, g, b, a)
    edges.right:Show()
  else
    edges.top:Hide()
    edges.bottom:Hide()
    edges.left:Hide()
    edges.right:Hide()
  end
end

-- ===================================================================
-- TEXTURE COORDINATE CALCULATION (Aspect Ratio + Zoom)
-- ===================================================================
local function CalculateTexCoords(aspectRatio, zoom)
  local left, right, top, bottom = 0, 1, 0, 1
  
  -- Apply aspect ratio cropping
  if aspectRatio and aspectRatio ~= 1.0 then
    if aspectRatio > 1.0 then
      -- Wider than tall - crop top/bottom of texture
      local cropAmount = 1.0 - (1.0 / aspectRatio)
      local offset = cropAmount / 2.0
      top = offset
      bottom = 1.0 - offset
    elseif aspectRatio < 1.0 then
      -- Taller than wide - crop left/right of texture
      local cropAmount = 1.0 - aspectRatio
      local offset = cropAmount / 2.0
      left = offset
      right = 1.0 - offset
    end
  end
  
  -- Apply zoom on top of aspect ratio crop
  if zoom and zoom > 0 then
    local currentWidth = right - left
    local currentHeight = bottom - top
    local visibleSize = 1.0 - (zoom * 2)
    
    local zoomedWidth = currentWidth * visibleSize
    local zoomedHeight = currentHeight * visibleSize
    
    local centerX = (left + right) / 2.0
    local centerY = (top + bottom) / 2.0
    
    left = centerX - (zoomedWidth / 2.0)
    right = centerX + (zoomedWidth / 2.0)
    top = centerY - (zoomedHeight / 2.0)
    bottom = centerY + (zoomedHeight / 2.0)
  end
  
  return left, right, top, bottom
end

-- ===================================================================
-- PREVIEW TEXT FOR EDITING
-- Shows placeholder text (0, 0.0) when editing so user can see position
-- Only shows on the currently selected/edited icon
-- ===================================================================
local function UpdatePreviewText(frame, cdID, cfg)
  -- Show preview when options panel is open (helps user see text styling while editing)
  local optionsOpen = ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsOptionsOpen and ns.CDMEnhanceOptions.IsOptionsOpen()
  
  -- Check if THIS icon is the one being edited
  local isSelectedIcon = false
  if optionsOpen and ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.GetSelectedIcon then
    local selectedAura, selectedCooldown = ns.CDMEnhanceOptions.GetSelectedIcon()
    isSelectedIcon = (cdID == selectedAura) or (cdID == selectedCooldown)
  end
  
  -- Charge/Stack text preview (shows "0")
  -- Skip for Arc Aura frames - they manage their own Count fontstring
  if cfg.chargeText and not frame._arcConfig and not frame._arcAuraID then
    local chargeCfg = cfg.chargeText
    -- Use cached flag instead of IsShown()/GetText() which are secret in instances
    local hasRealText = frame._arcCLHasText == true or frame._arcSingleStackShowing == true

    -- Only show preview on the selected icon AND when no real text
    if isSelectedIcon and not hasRealText then
      -- Ensure text overlay exists (created in ApplyIconStyle)
      local overlayParent = frame._arcTextOverlay or frame
      
      -- Create preview text if needed (parented to text overlay so it's above cooldown swipe)
      if not frame._arcChargePreview then
        frame._arcChargePreview = overlayParent:CreateFontString(nil, "OVERLAY")
        frame._arcChargePreview:SetDrawLayer("OVERLAY", 7)
        frame._arcChargePreview._arcIsPreview = true
        frame._arcChargePreview._arcIsChargeText = true  -- Prevent cooldown styling from touching it
      elseif frame._arcChargePreview:GetParent() ~= overlayParent then
        -- Re-parent if overlay was created after preview
        frame._arcChargePreview:SetParent(overlayParent)
      end
      
      local preview = frame._arcChargePreview
      
      -- Copy styling from charge text config (full styling for live preview)
      local fontPath = GetFontPath(chargeCfg.font)
      local fontSize = chargeCfg.size or 16
      local outline = chargeCfg.outline or "THICKOUTLINE"
      SafeSetFont(preview, fontPath, fontSize, outline)
      
      -- Use actual color settings
      local c = chargeCfg.color or {r=1, g=1, b=0, a=1}
      preview:SetTextColor(c.r or 1, c.g or 1, c.b or 0, c.a or 1)
      
      if chargeCfg.shadow then
        preview:SetShadowOffset(chargeCfg.shadowOffsetX or 1, chargeCfg.shadowOffsetY or -1)
        preview:SetShadowColor(0, 0, 0, 0.8)
      else
        preview:SetShadowOffset(0, 0)
      end
      
      -- Position like charge text
      preview:ClearAllPoints()
      if chargeCfg.mode == "free" then
        local freeX = chargeCfg.freeX or 0
        local freeY = chargeCfg.freeY or 0
        preview:SetPoint("CENTER", frame, "CENTER", freeX, freeY)
      else
        local anchor = chargeCfg.anchor or "BOTTOMRIGHT"
        local offX = chargeCfg.offsetX or -2
        local offY = chargeCfg.offsetY or 2
        preview:SetPoint(anchor, frame, anchor, offX, offY)
      end
      
      preview:SetText("0")
      preview:Show()
    else
      -- Not selected or real text showing, hide preview
      if frame._arcChargePreview then
        frame._arcChargePreview:Hide()
      end
    end
  else
    -- No charge config, hide preview
    if frame._arcChargePreview then
      frame._arcChargePreview:Hide()
    end
  end
  
  -- Cooldown/Duration text preview (shows "0.0")
  local cooldownFrame = frame.Cooldown or frame.cooldown
  if cooldownFrame and cfg.cooldownText and cfg.cooldownText.enabled ~= false then
    local cdTextCfg = cfg.cooldownText
    -- Use cached flag instead of IsShown()/GetText() which are secret in instances
    local hasCooldownText = frame._arcPreserveDurationText == true
    
    -- Only show preview on the selected icon AND when no real text
    if isSelectedIcon and not hasCooldownText then
      -- Ensure text overlay exists (created in ApplyIconStyle)
      local overlayParent = frame._arcTextOverlay or frame
      
      -- Create preview text if needed (parented to text overlay so it's above cooldown swipe)
      if not frame._arcCooldownPreview then
        frame._arcCooldownPreview = overlayParent:CreateFontString(nil, "OVERLAY")
        frame._arcCooldownPreview:SetDrawLayer("OVERLAY", 7)
        frame._arcCooldownPreview._arcIsPreview = true
        frame._arcCooldownPreview._arcIsCooldownText = true  -- Prevent charge styling from touching it
      elseif frame._arcCooldownPreview:GetParent() ~= overlayParent then
        -- Re-parent if overlay was created after preview
        frame._arcCooldownPreview:SetParent(overlayParent)
      end
      
      local preview = frame._arcCooldownPreview
      
      -- Copy styling from cooldown text config (full styling for live preview)
      local fontPath = GetFontPath(cdTextCfg.font)
      local fontSize = cdTextCfg.size or 14
      local outline = cdTextCfg.outline or "OUTLINE"
      SafeSetFont(preview, fontPath, fontSize, outline)
      
      -- Use actual color settings
      local c = cdTextCfg.color or {r=1, g=1, b=1, a=1}
      preview:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
      
      if cdTextCfg.shadow then
        preview:SetShadowOffset(cdTextCfg.shadowOffsetX or 1, cdTextCfg.shadowOffsetY or -1)
        preview:SetShadowColor(0, 0, 0, 0.8)
      else
        preview:SetShadowOffset(0, 0)
      end
      
      -- Position like cooldown text
      preview:ClearAllPoints()
      if cdTextCfg.mode == "free" then
        local freeX = cdTextCfg.freeX or 0
        local freeY = cdTextCfg.freeY or 0
        preview:SetPoint("CENTER", frame, "CENTER", freeX, freeY)
      else
        local anchor = cdTextCfg.anchor or "CENTER"
        local offX = cdTextCfg.offsetX or 0
        local offY = cdTextCfg.offsetY or 0
        preview:SetPoint(anchor, frame, anchor, offX, offY)
      end
      
      preview:SetText("0.0")
      preview:Show()
    else
      -- Not selected or real text showing, hide preview
      if frame._arcCooldownPreview then
        frame._arcCooldownPreview:Hide()
      end
    end
  else
    -- No cooldown config or disabled, hide preview
    if frame._arcCooldownPreview then
      frame._arcCooldownPreview:Hide()
    end
  end
end

-- ===================================================================
-- PREVIEW GLOW FOR EDITING
-- Shows glow animation for 3 seconds when user changes a glow setting
-- Only shows on the icon whose setting was changed
-- ===================================================================
local function UpdatePreviewGlow(frame, cdID, cfg)
  if not ns.Glows then return end
  
  -- Check if options panel is open
  local optionsOpen = ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsOptionsOpen and ns.CDMEnhanceOptions.IsOptionsOpen()
  
  -- Check if glow preview is active (triggered by changing a glow setting)
  local glowPreviewActive, previewCdID = false, nil
  if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.GetGlowPreviewState then
    glowPreviewActive, previewCdID = ns.CDMEnhanceOptions.GetGlowPreviewState()
  end
  
  -- Check if THIS icon should show preview (matches the triggered cdID)
  local isPreviewTarget = glowPreviewActive and (cdID == previewCdID)
  
  -- Check if real glow is happening (don't show preview during actual proc)
  local hasRealGlow = frame._arcProcGlowActive == true
  
  -- Get glow config
  local glowCfg = cfg and cfg.procGlow
  
  -- Should we show preview? Only when:
  -- 1. Options panel is open
  -- 2. This icon's glow was just changed (within 3 seconds)
  -- 3. No real glow is happening
  -- 4. Glow is enabled in settings
  local showPreview = optionsOpen and isPreviewTarget and not hasRealGlow and glowCfg and glowCfg.enabled ~= false
  
  -- Apply optional strata + level override to glow overlay
  local function ApplyGlowOverlayOverrides(glowOverlay, settings)
    if not glowOverlay or not settings then return end
    local strata = settings.readyGlowFrameStrata or settings.glowFrameStrata
    if strata and strata ~= "inherit" then
      glowOverlay.SetFrameStrata(glowOverlay, strata)
      glowOverlay._arcGlowStrataOverride = strata
    elseif glowOverlay._arcGlowStrataOverride then
      local parentStrata = glowOverlay._arcOwnerFrame and glowOverlay._arcOwnerFrame:GetFrameStrata() or "MEDIUM"
      glowOverlay.SetFrameStrata(glowOverlay, parentStrata)
      glowOverlay._arcGlowStrataOverride = nil
    end
    local level = settings.readyGlowFrameLevel or settings.glowFrameLevel
    if level then
      glowOverlay:SetFrameLevel(level)
      glowOverlay._arcGlowLevelOverride = level
    elseif glowOverlay._arcGlowLevelOverride then
      local ownerFrame = glowOverlay._arcOwnerFrame
      glowOverlay:SetFrameLevel(ownerFrame and (ownerFrame:GetFrameLevel() + GLOW_OVERLAY_LEVEL_OFFSET) or GLOW_OVERLAY_LEVEL_OFFSET)
      glowOverlay._arcGlowLevelOverride = nil
    end
  end
  
  if showPreview then
    local originalType = glowCfg.glowType or "proc"
    local glowType = originalType
    local glowScale = glowCfg.scale or 1.0
    local padding = cfg.padding or 0
    local glowOffset = -padding
    
    -- nil color for "default" with no user color = LCG native golden texture
    local color = nil
    if glowCfg.color then
      color = {glowCfg.color.r or 1, glowCfg.color.g or 1, glowCfg.color.b or 1, glowCfg.alpha or 1.0}
    elseif originalType ~= "default" then
      color = {0.95, 0.95, 0.32, glowCfg.alpha or 1.0}
    end
    
    if ns.Glows then
      ns.Glows.Start(frame, "ArcUI_Preview", glowType, {
        color = color,
        scale = glowScale,
        frequency = glowCfg.speed or 0.25,
        lines = glowCfg.lines or 8,
        thickness = glowCfg.thickness or 2,
        particles = glowCfg.particles or 4,
        xOffset = glowOffset + (glowCfg.xOffset or 0),
        yOffset = glowOffset + (glowCfg.yOffset or 0),
        translateX = glowCfg.translateX or 0,
        translateY = glowCfg.translateY or 0,
        strata = (not glowCfg.strata or glowCfg.strata == "inherit") and "MEDIUM" or glowCfg.strata,
        frameLevel = glowCfg.frameLevel or ((not glowCfg.strata or glowCfg.strata == "inherit") and 1 or nil),
      })
    end
    frame._arcGlowPreviewActive = true
    frame._arcGlowPreviewType = glowType
  else
    -- Hide preview glow
    if frame._arcGlowPreviewActive then
      if ns.Glows then
        ns.Glows.Stop(frame, "ArcUI_Preview")
      end
      frame._arcGlowPreviewActive = false
      frame._arcGlowPreviewType = nil
    end
  end
end

-- ===================================================================
-- PANDEMIC/DEBUFF BORDER HELPER FUNCTIONS (module-level for watcher access)
-- ===================================================================

-- CDM default offsets from XML:
-- IconOverlay (shadow): 8px horizontal, 7px vertical (BuffIcon template)
-- PandemicIcon: 6px all sides (AnchorPandemicStateFrame)
-- DebuffBorder: SetAllPoints = 0px (texture has internal padding)
-- The pandemic texture (UI-CooldownManager-PandemicBorder) has MORE internal padding
-- than DebuffBorder. We need to increase pandemic expansion so the visible glow aligns.

-- CDM uses 6px offset for 36px icons = 6/36 = 0.167 ratio
-- For larger icons, we scale the offset proportionally
local CDM_BASE_ICON_SIZE = 36
local CDM_BASE_BORDER_OFFSET = 6
local BORDER_OFFSET_RATIO = CDM_BASE_BORDER_OFFSET / CDM_BASE_ICON_SIZE  -- ~0.167

-- (MODULE_BASE_BORDER_OFFSET and MODULE_PANDEMIC_EXTRA_OFFSET removed - using ratio-based scaling)

-- Apply proper sizing to border frames based on padding
-- Note: Zoom only affects texture cropping, not frame size, so it doesn't affect border expansion
-- Aspect ratio is already handled by anchor points (TOPLEFT/BOTTOMRIGHT follow frame dimensions)
local function ModuleApplyBorderSizing(borderFrame, iconFrame, pad, zm, frameType)
  if not borderFrame then return end
  
  -- Ratio-based: scale offset proportionally to icon size (same for pandemic and debuff)
  local iconW, iconH = iconFrame:GetWidth(), iconFrame:GetHeight()
  local iconSize = math.min(iconW or 36, iconH or 36)
  local expand = iconSize * BORDER_OFFSET_RATIO
  -- Adjust for padding (shrinks visible area, so reduce expand)
  expand = expand - (pad or 0)
  -- Adjust for zoom (expands visible area, so increase expand)
  expand = expand + (zm or 0)
  
  borderFrame:ClearAllPoints()
  borderFrame:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", -expand, expand)
  borderFrame:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", expand, -expand)
end

-- Setup hooks on border frame (only once per frame)
local function ModuleSetupBorderHooks(borderFrame, frameType)
  if not borderFrame then return end
  
  local hookKey = "_arcBorderHooked_" .. (frameType or "border")
  if borderFrame[hookKey] then return end
  borderFrame[hookKey] = true
  borderFrame._arcFrameType = frameType  -- Store for Show hook
  
  -- Helper to enforce hidden state
  local function EnforceHidden(self)
    local parent = self:GetParent()
    
    -- First check: does parent even want this shown?
    if parent then
      if (self._arcFrameType == "pandemic" and not parent._arcShowPandemic) or
         (self._arcFrameType == "debuff" and not parent._arcShowDebuffBorder) then
        -- Parent says disabled - hide regardless of _arcShowEnabled state
        self:Hide()
        self:SetAlpha(0)
        return true
      end
    end
    
    -- Check _arcShowEnabled
    if self._arcShowEnabled == false then
      self:Hide()
      self:SetAlpha(0)
      return true
    end
    
    return false
  end
  
  -- Hook the border frame Show
  hooksecurefunc(borderFrame, "Show", function(self)
    if EnforceHidden(self) then return end
    
    local parent = self:GetParent()
    if self._arcShowEnabled == true then
      -- Enabled: restore alpha and apply sizing when CDM shows it
      self:SetAlpha(1)
      if parent then
        ModuleApplyBorderSizing(self, parent, parent._arcPadding or 0, parent._arcZoom or 0, self._arcFrameType)
      end
    end
    -- If nil and parent allows: let CDM show it, watcher will set up properly
  end)
  
  -- CRITICAL: Also hook SetShown - CDM may use this instead of Show()
  if borderFrame.SetShown then
    hooksecurefunc(borderFrame, "SetShown", function(self, shown)
      if issecretvalue and issecretvalue(shown) then return end
      if shown then
        EnforceHidden(self)
      end
    end)
  end
  
  -- Hook .Texture child if exists (CDM shows this separately for DebuffBorder)
  if borderFrame.Texture then
    hooksecurefunc(borderFrame.Texture, "Show", function(self)
      local bf = self:GetParent()
      if bf then
        if bf._arcShowEnabled == true then
          self:SetAlpha(1)
        elseif bf._arcShowEnabled == false then
          self:Hide()
          self:SetAlpha(0)
        end
      end
    end)
    if borderFrame.Texture.SetShown then
      hooksecurefunc(borderFrame.Texture, "SetShown", function(self, shown)
        if issecretvalue and issecretvalue(shown) then return end
        if shown then
          local bf = self:GetParent()
          if bf and bf._arcShowEnabled == false then
            self:Hide()
            self:SetAlpha(0)
          end
        end
      end)
    end
  end
end

-- Enable border (allow CDM to show, apply sizing)
local function ModuleEnableBorderFrame(borderFrame, iconFrame, pad, zm, frameType)
  if not borderFrame then return end
  borderFrame._arcShowEnabled = true
  borderFrame._arcSizedForParent = iconFrame
  borderFrame._arcSizedWithZoom = zm
  borderFrame._arcSizedWithPadding = pad
  ModuleSetupBorderHooks(borderFrame, frameType)
  
  -- Restore alpha on main frame
  borderFrame:SetAlpha(1)
  
  -- Restore .Texture child (for DebuffBorder)
  if borderFrame.Texture then
    borderFrame.Texture:SetAlpha(1)
  end
  
  -- Restore .Border child frame and its texture (for PandemicIcon)
  if borderFrame.Border then
    borderFrame.Border:SetAlpha(1)
    borderFrame.Border:Show()
    -- Ensure Border fills PandemicIcon (in case setAllPoints was reset)
    borderFrame.Border:ClearAllPoints()
    borderFrame.Border:SetAllPoints(borderFrame)
    if borderFrame.Border.Border then
      borderFrame.Border.Border:SetAlpha(1)
      borderFrame.Border.Border:Show()
    end
  end
  
  -- Restore .FX child frame (yellow glow for PandemicIcon)
  -- FX needs to be sized to account for padding - it should stay on the border
  if borderFrame.FX then
    borderFrame.FX:SetAlpha(1)
    -- FX follows parent via SetAllPoints
    borderFrame.FX:ClearAllPoints()
    borderFrame.FX:SetAllPoints(borderFrame)
  end
  
  -- Always apply sizing (this sizes the main PandemicIcon frame)
  ModuleApplyBorderSizing(borderFrame, iconFrame, pad, zm, frameType)
end

-- Disable border (block CDM from showing)
local function ModuleDisableBorderFrame(borderFrame, frameType)
  if not borderFrame then return end
  borderFrame._arcShowEnabled = false
  borderFrame._arcSizedForParent = nil
  ModuleSetupBorderHooks(borderFrame, frameType)
  borderFrame:Hide()
  borderFrame:SetAlpha(0)
  
  -- Hide .Texture child (for DebuffBorder)
  if borderFrame.Texture then
    borderFrame.Texture:Hide()
    borderFrame.Texture:SetAlpha(0)
  end
  
  -- Hide .Border child frame and its .Border texture (for PandemicIcon)
  if borderFrame.Border then
    borderFrame.Border:Hide()
    borderFrame.Border:SetAlpha(0)
    if borderFrame.Border.Border then
      borderFrame.Border.Border:Hide()
      borderFrame.Border.Border:SetAlpha(0)
    end
    -- Hook Border:Show() and SetShown() to handle enable/disable
    if not borderFrame.Border._arcShowHooked then
      borderFrame.Border._arcShowHooked = true
      
      -- Helper function to enforce hidden state
      local function EnforceBorderHidden(self)
        local parent = self:GetParent() -- PandemicIcon
        if parent then
          local grandparent = parent:GetParent() -- Icon frame
          -- First check grandparent's control flag (use "not" to catch nil OR false)
          if grandparent and not grandparent._arcShowPandemic then
            self:Hide()
            self:SetAlpha(0)
            return true
          end
          -- Then check parent's _arcShowEnabled
          if parent._arcShowEnabled == false then
            self:Hide()
            self:SetAlpha(0)
            return true
          end
        end
        return false
      end
      
      hooksecurefunc(borderFrame.Border, "Show", function(self)
        if EnforceBorderHidden(self) then return end
        local parent = self:GetParent()
        if parent and parent._arcShowEnabled == true then
          self:SetAlpha(1)
          if self.Border then self.Border:SetAlpha(1) end
        end
      end)
      
      -- CRITICAL: Also hook SetShown - CDM may use this instead of Show()
      if borderFrame.Border.SetShown then
        hooksecurefunc(borderFrame.Border, "SetShown", function(self, shown)
          if issecretvalue and issecretvalue(shown) then return end
          if shown then EnforceBorderHidden(self) end
        end)
      end
    end
  end
  
  -- Hide .FX child frame (yellow glow for PandemicIcon)
  if borderFrame.FX then
    borderFrame.FX:Hide()
    borderFrame.FX:SetAlpha(0)
    
    -- Hook FX:Show() and SetShown() to handle enable/disable
    if not borderFrame.FX._arcShowHooked then
      borderFrame.FX._arcShowHooked = true
      
      -- Helper function to enforce hidden state when disabled
      local function EnforceFXHidden(self)
        local parent = self:GetParent() -- PandemicIcon
        if parent then
          local grandparent = parent:GetParent() -- Icon frame
          -- First check grandparent's control flag (use "not" to catch nil OR false)
          if grandparent and not grandparent._arcShowPandemic then
            self:Hide()
            self:SetAlpha(0)
            return true
          end
          -- Then check parent's _arcShowEnabled
          if parent._arcShowEnabled == false then
            self:Hide()
            self:SetAlpha(0)
            return true
          end
        end
        return false
      end
      
      hooksecurefunc(borderFrame.FX, "Show", function(self)
        if EnforceFXHidden(self) then return end
        local parent = self:GetParent()
        if parent and parent._arcShowEnabled == true then
          -- Enabled - restore and ensure proper sizing
          self:SetAlpha(1)
          self:ClearAllPoints()
          self:SetAllPoints(parent)
        end
      end)
      
      -- CRITICAL: Also hook SetShown - CDM may use this instead of Show()
      if borderFrame.FX.SetShown then
        hooksecurefunc(borderFrame.FX, "SetShown", function(self, shown)
          if issecretvalue and issecretvalue(shown) then return end
          if shown then EnforceFXHidden(self) end
        end)
      end
    end
  end
end

-- ===================================================================
-- BORDER DESATURATION SYNC
-- Apply desaturation to custom borders when icon is desaturated
-- ColorTexture doesn't respond to SetDesaturation, so we calculate
-- grayscale color and apply via SetVertexColor instead
-- ===================================================================

-- Convert RGB to grayscale (luminance formula)
local function RGBToGrayscale(r, g, b)
  -- Standard luminance formula
  local gray = 0.299 * r + 0.587 * g + 0.114 * b
  return gray, gray, gray
end

-- Cache for border color curves (keyed by color string)
local borderColorCurveCache = {}

-- Create curves for transitioning between original color and grayscale
-- Returns rCurve, gCurve, bCurve that can be evaluated with durationObj:EvaluateRemainingPercent()
local function GetBorderColorCurves(r, g, b)
  if not C_CurveUtil or not C_CurveUtil.CreateCurve then return nil, nil, nil end
  
  local cacheKey = string.format("%.3f_%.3f_%.3f", r, g, b)
  
  if borderColorCurveCache[cacheKey] then
    return unpack(borderColorCurveCache[cacheKey])
  end
  
  -- Calculate grayscale
  local gray = 0.299 * r + 0.587 * g + 0.114 * b
  
  -- Create curves: 0% remaining (ready) = original color, >0% remaining (on CD) = gray
  -- Using Step type for instant transition (like Binary curve)
  local rCurve = C_CurveUtil.CreateCurve()
  rCurve:SetType(Enum.LuaCurveType.Step)
  rCurve:AddPoint(0.0, r)      -- 0% remaining (ready) → original
  rCurve:AddPoint(0.001, gray) -- >0% remaining (on CD) → gray
  rCurve:AddPoint(1.0, gray)
  
  local gCurve = C_CurveUtil.CreateCurve()
  gCurve:SetType(Enum.LuaCurveType.Step)
  gCurve:AddPoint(0.0, g)
  gCurve:AddPoint(0.001, gray)
  gCurve:AddPoint(1.0, gray)
  
  local bCurve = C_CurveUtil.CreateCurve()
  bCurve:SetType(Enum.LuaCurveType.Step)
  bCurve:AddPoint(0.0, b)
  bCurve:AddPoint(0.001, gray)
  bCurve:AddPoint(1.0, gray)
  
  borderColorCurveCache[cacheKey] = {rCurve, gCurve, bCurve}
  return rCurve, gCurve, bCurve
end

-- Apply desaturation to custom border edges by changing vertex color
-- desatValue should be 0 (colored) or 1 (grayscale) - non-secret values only!
-- Used for auras/totems where we have non-secret state
local function ApplyBorderDesaturation(frame, desatValue)
  if not frame then return end
  
  -- Use frame-level cached config
  local cfg = GetEffectiveIconSettingsForFrame(frame)
  if not cfg then return end
  
  -- Check if custom border has followDesaturation enabled
  if cfg.border and cfg.border.enabled and cfg.border.followDesaturation then
    local edges = frame._arcBorderEdges
    if not edges then return end
    
    -- Get the configured border color
    local color
    if cfg.border.useClassColor then
      color = GetClassColor()
    else
      color = cfg.border.color or {1, 1, 1, 1}
    end
    local r, g, b, a = color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1
    
    -- Calculate final color based on desaturation (0 = colored, 1 = grayscale)
    local finalR, finalG, finalB
    local desatAmount = desatValue or 0
    
    if desatAmount > 0.5 then
      -- Desaturated: use grayscale
      finalR, finalG, finalB = RGBToGrayscale(r, g, b)
    else
      -- Colored: use original
      finalR, finalG, finalB = r, g, b
    end
    
    -- Apply to all edges
    if edges.top then edges.top:SetVertexColor(finalR, finalG, finalB, a) end
    if edges.bottom then edges.bottom:SetVertexColor(finalR, finalG, finalB, a) end
    if edges.left then edges.left:SetVertexColor(finalR, finalG, finalB, a) end
    if edges.right then edges.right:SetVertexColor(finalR, finalG, finalB, a) end
  end
end

-- Apply curve-based border color for cooldowns (secret-safe!)
-- Uses duration object + color curves to set border color
-- SetVertexColor accepts secret values so this works during combat
local function ApplyBorderDesaturationFromDuration(frame, durationObj)
  if not frame or not durationObj then return end
  
  -- Use frame-level cached config
  local cfg = GetEffectiveIconSettingsForFrame(frame)
  if not cfg then return end
  
  -- Check if custom border has followDesaturation enabled
  if not (cfg.border and cfg.border.enabled and cfg.border.followDesaturation) then return end
  
  local edges = frame._arcBorderEdges
  if not edges then return end
  
  -- Get the configured border color
  local color
  if cfg.border.useClassColor then
    color = GetClassColor()
  else
    color = cfg.border.color or {1, 1, 1, 1}
  end
  local r, g, b, a = color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1
  
  -- Get or create color curves for this color
  local rCurve, gCurve, bCurve = GetBorderColorCurves(r, g, b)
  if not rCurve or not gCurve or not bCurve then return end

  local finalR = durationObj:EvaluateRemainingPercent(rCurve)
  local finalG = durationObj:EvaluateRemainingPercent(gCurve)
  local finalB = durationObj:EvaluateRemainingPercent(bCurve)

  if finalR and finalG and finalB then
    if edges.top then edges.top:SetVertexColor(finalR, finalG, finalB, a) end
    if edges.bottom then edges.bottom:SetVertexColor(finalR, finalG, finalB, a) end
    if edges.left then edges.left:SetVertexColor(finalR, finalG, finalB, a) end
    if edges.right then edges.right:SetVertexColor(finalR, finalG, finalB, a) end
  end
end

-- Export for use elsewhere
ns.CDMEnhance.ApplyBorderDesaturation = ApplyBorderDesaturation
ns.CDMEnhance.ApplyBorderDesaturationFromDuration = ApplyBorderDesaturationFromDuration

-- ═══════════════════════════════════════════════════════════════════
-- FORCE HIDE: float the duration + stack text above a hidden icon frame.
-- When the icon is force-hidden the FRAME renders at alpha 0 (kills art, swipe,
-- flash, animation, border, shadow in one shot). These text widgets are told to
-- ignore the parent alpha chain so they stay readable. Empty text renders nothing,
-- so floating them unconditionally is safe (only shows when there's content).
-- NOT applied while the whole group is hidden (visibility conditions) — there the
-- text should disappear with the group. We deliberately do NOT float frame.Cooldown
-- itself (only its countdown FontStrings) so the swipe stays hidden.
-- ═══════════════════════════════════════════════════════════════════
local function ApplyForceHideText(frame, hide)
  if not frame then return end
  local groupHidden = frame._arcGroupHidden
  if not groupHidden then
    local parent = frame:GetParent()
    groupHidden = parent and parent._arcGroupHidden or false
  end
  local on = (hide == true) and not groupHidden
  -- Toggle IgnoreParentAlpha ONLY — do NOT force SetAlpha. The widget's own alpha
  -- (1 when its text feature is enabled, 0 when suppressed/disabled, e.g. a native
  -- stack count hidden because threshold bands or single-stack replaced it) then
  -- drives visibility, so we never re-show something that was deliberately hidden.
  local function ipa(obj)
    if obj and obj.SetIgnoreParentAlpha then
      obj:SetIgnoreParentAlpha(on)
    end
  end
  -- Duration countdown (native Cooldown FontStrings only — never the widget itself)
  if frame.Cooldown then
    local cd = frame.Cooldown
    local fs = cd.GetCountdownFontString and cd:GetCountdownFontString()
    ipa(fs)
    for _, region in ipairs({cd:GetRegions()}) do
      if region:IsObjectType("FontString") then ipa(region) end
    end
  end
  ipa(frame._arcCooldownText)
  -- Stack / charge text (native container + all ArcUI variants)
  ipa(frame.ChargeCount or frame.Applications)
  ipa(frame._arcChargeText)
  ipa(frame._arcSingleStackContainer)
  ipa(frame._arcStackBandContainer)
  -- Edit / drag overlay ("DRAG" button) — keep it usable while the icon is
  -- held at preview opacity in the options panel. (UpdateOverlayState still
  -- governs whether it's shown at all, so this is a no-op outside edit mode.)
  ipa(frame._arcOverlay)
end
ns.CDMEnhance.ApplyForceHideText = ApplyForceHideText

-- ===================================================================
-- APPLY ICON STYLING
-- ===================================================================
ApplyIconStyle = function(frame, cdID)
  if not cdID then return end
  
  -- MASTER TOGGLE: Skip if disabled
  local groupsDB = Shared.GetCDMGroupsDB()
  if groupsDB and groupsDB.enabled == false then
    return
  end
  
  local db = GetDB()
  if not db then return end
  
  -- Determine icon type from enhancedFrames
  local data = enhancedFrames[cdID]
  local viewerType = data and data.viewerType or "cooldown"
  
  -- Check if customization is enabled for this icon type
  local customizationEnabled = true
  if viewerType == "aura" then
    customizationEnabled = db.enableAuraCustomization ~= false
  else
    customizationEnabled = db.enableCooldownCustomization ~= false
  end
  
  -- If customization is disabled, don't apply any styling (CDMGroups handles positioning)
  if not customizationEnabled then
    return
  end
  
  -- Use frame-level cached config
  local cfg = GetEffectiveIconSettingsForFrame(frame)
  if not cfg then return end
  
  -- CDMGroups handles ALL position/scale/size for ALL icons
  -- CDMEnhance only does visual styling (borders, glow, textures, inactive state)
  
  -- Clear inactive state tracking to force re-evaluation with new settings
  frame._arcInactiveSettingsSig = nil
  
  local iconTex = frame.Icon or frame.icon
  
  -- Capture IconMask early for Masque integration.
  -- Must happen before any mask stripping so the reference is always available.
  -- Masque's Mask.lua reads Button.IconMask to initialize its mask system.
  if iconTex and not frame.IconMask then
    local mask = iconTex:GetMaskTexture(1)
    if mask then
      frame.IconMask = mask
    end
  end

  -- FORCE HIDE (Show toggle off): hide the WHOLE icon frame (art, swipe, flash,
  -- animation, border, shadow) by forcing frame alpha to 0, and float only the
  -- duration + stack text. Set the flag EARLY so the frame-alpha hook enforces 0
  -- for any SetAlpha during the rest of ApplyIconStyle; the hide + text float
  -- happen after the text overlays are built (post SetupCooldownText below).
  local wasForceHidden = frame._arcForceHideActive == true
  frame._arcForceHideActive = (cfg.forceHideIcon == true)
  frame._arcWasForceHidden = wasForceHidden

  -- NOTE: CDMGroups controls all sizing - CDMEnhance does NOT call SetScale or SetSize
  local data = enhancedFrames[cdID]
  local vType = data and data.viewerType or "cooldown"

  -- Store original (native CDM) dimensions for shadow overlay scaling.
  -- Always use the known CDM XML constant — GetWidth() may be post-resize.
  do
    local nativeSize = CDM_NATIVE_SIZE[vType] or 36
    frame._arcOrigW = nativeSize
    frame._arcOrigH = nativeSize
  end
  
  local aspectRatio = cfg.aspectRatio or 1.0
  local zoom = cfg.zoom or 0.075
  local padding = cfg.padding or 0
  
  -- MASQUE COMPATIBILITY: Check if Masque skinning is enabled for this viewer type
  local masqueActive = ns.Masque and ns.Masque.ShouldMasqueControlIcon and ns.Masque.ShouldMasqueControlIcon(vType)
  
  if masqueActive then
    -- Masque controls icon appearance - use defaults (no zoom/padding from ArcUI)
    aspectRatio = 1.0
    zoom = 0
    padding = 0
  end
  
  -- Calculate texture coords for aspect ratio and zoom
  local left, right, top, bottom = CalculateTexCoords(aspectRatio, zoom)
  
  -- Store texcoords for cooldown swipe matching (always, even if no icon texture)
  frame._arcTexCoords = { left = left, right = right, top = top, bottom = bottom }
  
  -- Apply texture coords to prevent stretching (only if Icon is a Texture, not a Frame)
  if iconTex and iconTex.SetTexCoord then
    if masqueActive then
      -- MASQUE ACTIVE: Do NOT touch icon texture positioning!
      -- Masque manages the icon texture's anchor points and texcoords when skinning.
      -- Masque skins set specific insets on the icon to leave room for border art.
      -- Calling ClearAllPoints/SetAllPoints here would destroy those insets,
      -- causing icons to fill the entire frame and bleed under the Masque border.
      -- We only store _arcTexCoords above for cooldown swipe reference.
      
      -- RESTORE masks that ArcUI may have stripped for SetTexCoord.
      -- Masque needs the original masks present so Skin_Mask can manage them.
      if iconTex._arcMasksRemoved and iconTex._arcOrigMasks then
        for _, mask in ipairs(iconTex._arcOrigMasks) do
          iconTex:AddMaskTexture(mask)
        end
        iconTex._arcMasksRemoved = nil
      end
    else
      -- MASQUE INACTIVE: Apply ArcUI texcoord manipulation
      -- CRITICAL: Remove CDM's original mask textures before applying SetTexCoord.
      -- They cause uneven rendering when texcoords are manipulated.
      if not iconTex._arcMasksRemoved and iconTex.GetMaskTexture and iconTex.RemoveMaskTexture then
        local masksToRemove = {}
        for i = 1, 5 do
          local mask = iconTex:GetMaskTexture(i)
          if mask then table.insert(masksToRemove, mask) end
        end
        if #masksToRemove > 0 then iconTex._arcOrigMasks = masksToRemove end
        for _, mask in ipairs(masksToRemove) do
          iconTex:RemoveMaskTexture(mask)
        end
        iconTex._arcMasksRemoved = true
      end

      -- CDM MASK: only applied to Icon texture. CDM swipe/edge use pre-shaped texture — no mask needed.
      do
        local specData = Shared and Shared.GetCurrentSpecData and Shared.GetCurrentSpecData()
        local keepMask = specData and specData.keepCDMStyle == true
        if keepMask then
          if not iconTex._arcOwnMask then
            local maskTex = frame:CreateMaskTexture(nil, "ARTWORK")
            maskTex:SetAtlas("UI-HUD-CoolDownManager-Mask", false)
            -- Match CDM's native XML: mask is setAllPoints on the FRAME, not iconTex
            -- Using iconTex causes 1-2px misalignment at top corners
            maskTex:SetAllPoints(frame)
            iconTex:AddMaskTexture(maskTex)
            iconTex._arcOwnMask = maskTex
          end
        else
          -- Remove our own mask if present
          if iconTex._arcOwnMask then
            iconTex:RemoveMaskTexture(iconTex._arcOwnMask)
            iconTex._arcOwnMask = nil
          end
          -- CDM may have re-added its native mask since last refresh — strip any that remain
          if iconTex.GetMaskTexture and iconTex.RemoveMaskTexture then
            for i = 1, 5 do
              local mask = iconTex:GetMaskTexture(i)
              if mask then
                iconTex:RemoveMaskTexture(mask)
              end
            end
          end
          iconTex._arcMasksRemoved = true
        end
      end

      iconTex:SetTexCoord(left, right, top, bottom)

      -- Position icon texture with padding
      iconTex:ClearAllPoints()
      iconTex:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, -padding)
      iconTex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
    end
  end
  
  -- Store zoom/padding on frame for other features
  frame._arcZoom = zoom
  frame._arcPadding = padding
  

  -- Store settings for OnUpdate sync FIRST - hooks check these flags
  -- IMPORTANT: Use explicit false (not nil) so hooks can check == false
  local showPandemic = (cfg.pandemicBorder and cfg.pandemicBorder.enabled) == true
  local showDebuffBorder = (cfg.debuffBorder and cfg.debuffBorder.enabled) == true
  frame._arcShowPandemic = showPandemic
  frame._arcShowDebuffBorder = showDebuffBorder
  
  -- Apply settings to PandemicIcon (after flags are set so hooks work correctly)
  if frame.PandemicIcon then
    if showPandemic then
      ModuleEnableBorderFrame(frame.PandemicIcon, frame, padding, zoom, "pandemic")
    else
      ModuleDisableBorderFrame(frame.PandemicIcon, "pandemic")
    end
  end
  
  -- Apply settings to DebuffBorder (after flags are set so hooks work correctly)
  if frame.DebuffBorder then
    if showDebuffBorder then
      ModuleEnableBorderFrame(frame.DebuffBorder, frame, padding, zoom, "debuff")
    else
      ModuleDisableBorderFrame(frame.DebuffBorder, "debuff")
    end
  end
  
  -- Hook ShowPandemicStateFrame to catch CDM replacing PandemicIcon
  -- CDM nils PandemicIcon in HidePandemicStateFrame and creates a fresh one
  -- in ShowPandemicStateFrame. Posthook fires after new instance exists.
  -- Replaces old 2Hz border watcher polling. CooldownFlash and DebuffBorder
  -- are static children already handled by SetAlpha hooks and ApplyIconStyle.
  if not frame._arcPandemicHooked and frame.ShowPandemicStateFrame then
    frame._arcPandemicHooked = true

    -- ShowPandemicStateFrame and HidePandemicStateFrame are mutually exclusive each frame —
    -- CDM calls exactly one of them from CheckPandemicTimeDisplay every OnUpdate tick.
    -- ON:  ShowPandemicStateFrame fires → start glow, stamp _arcPandemicLastFire
    -- OFF: HidePandemicStateFrame fires → if glow active and last fire was >0.1s ago, kill it
    -- Zero timers, zero closures, zero allocations. Just a GetTime() stamp and a compare.
    local PANDEMIC_LINGER = 0.1  -- allow ~6 frames of Hide before killing (handles hitches)

    local function PandemicGlowKill(self)
      self._arcPandemicGlowActive = nil
      self._arcPandemicLastFire   = nil
      local pfCfgW = GetEffectiveIconSettingsForFrame(self)
      local aasFW  = pfCfgW and pfCfgW.auraActiveState
      local svFW   = pfCfgW and GetEffectiveStateVisuals(pfCfgW)
      if aasFW and aasFW.glow == true and aasFW.glowFollowPandemic == true then
        HideAuraActiveGlow(self)
      elseif svFW and svFW.readyGlow and svFW.glowFollowPandemic then
        if ns.CDMEnhance.HideReadyGlow then ns.CDMEnhance.HideReadyGlow(self) end
      end
    end

    hooksecurefunc(frame, "ShowPandemicStateFrame", function(self)
      local pi = self.PandemicIcon
      if not pi then return end
      local pad = self._arcPadding or 0
      local zm = self._arcZoom or 0
      if self._arcShowPandemic then
        ModuleEnableBorderFrame(pi, self, pad, zm, "pandemic")
      else
        ModuleDisableBorderFrame(pi, "pandemic")
      end

      local pfCfg = GetEffectiveIconSettingsForFrame(self)
      local aasF  = pfCfg and pfCfg.auraActiveState
      local svF   = pfCfg and GetEffectiveStateVisuals(pfCfg)
      local hasFollowPandemic = (aasF and aasF.glow == true and aasF.glowFollowPandemic == true)
                             or (svF and svF.readyGlow and svF.glowFollowPandemic)
      if not hasFollowPandemic then return end

      -- Stamp every fire so HidePandemicStateFrame knows the window is still live
      self._arcPandemicLastFire = GetTime()

      if not self._arcPandemicGlowActive then
        if aasF and aasF.glow == true and aasF.glowFollowPandemic == true then
          local ok = not aasF.glowCombatOnly or InCombatLockdown() or UnitAffectingCombat("player")
          if ok then
            self._arcPandemicGlowActive = true
            HideAuraActiveGlow(self)
            ShowAuraActiveGlow(self, aasF)
          end
        elseif svF and svF.readyGlow and svF.glowFollowPandemic then
          local ok = not svF.readyGlowCombatOnly or InCombatLockdown() or UnitAffectingCombat("player")
          if ok then
            self._arcPandemicGlowActive = true
            if ns.CDMEnhance.HideReadyGlow then ns.CDMEnhance.HideReadyGlow(self) end
            if ns.CDMEnhance.ShowReadyGlow then ns.CDMEnhance.ShowReadyGlow(self, svF) end
          end
        end
      end
    end)

    -- HidePandemicStateFrame fires every frame when window is closed.
    -- Kill glow once enough time has passed since last ShowPandemicStateFrame.
    hooksecurefunc(frame, "HidePandemicStateFrame", function(self)
      if not self._arcPandemicGlowActive then return end
      local last = self._arcPandemicLastFire
      if last and (GetTime() - last) < PANDEMIC_LINGER then return end
      PandemicGlowKill(self)
    end)
  end

  -- ═══════════════════════════════════════════════════════════════════════
  -- PROC GLOW RESIZE - Keep alert sized correctly when icon size changes
  -- If a default glow is currently active, resize it to match new icon size
  -- ═══════════════════════════════════════════════════════════════════════
  -- (Proc glow resize for "default" type removed — all types now go through ns.Glows)

  
  -- ═══════════════════════════════════════════════════════════════════════
  -- PROC GLOW HOOKS - Backup for event-based system
  -- Events (SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE) are primary
  -- Hooks provide redundancy for edge cases where events might not fire
  -- Both call ShowProcGlow/HideProcGlow which have guards against double-calls
  -- ═══════════════════════════════════════════════════════════════════════
  if frame.SpellActivationAlert then
    local alert = frame.SpellActivationAlert
    alert._arcParentFrame = frame
    
    -- PRE-SIZE the alert to match current icon size BEFORE it shows
    -- This prevents the visual delay where glow appears small then resizes
    ResizeProcGlowAlert(frame)
    
    if not alert._arcProcHooked then
      alert._arcProcHooked = true
      
      -- OnShow suppressor: instantly kill CDM's native alert when ArcUI owns the glow.
      -- This prevents even a single-frame flicker of CDM's ProcStart burst on login/reload.
      alert:HookScript("OnShow", function(self)
        local parentFrame = self._arcParentFrame
        if parentFrame and parentFrame._arcProcGlowActive then
          HideCDMProcGlow(parentFrame)
        end
      end)
      
      -- OnHide safety net: ensures our glow state is cleaned up
      -- Primary hide path is ActionButtonSpellAlertManager:HideAlert hook
      -- This catches direct Hide() calls and frame recycling edge cases
      alert:HookScript("OnHide", function(self)
        local parentFrame = self._arcParentFrame
        if not parentFrame then return end
        
        if parentFrame._arcProcGlowActive then
          -- For LCG modes, CDM hiding its SpellActivationAlert is irrelevant -
          -- we already suppressed CDM's alert visuals (SetAlpha(0), hid flipbooks).
          -- CDM may hide/show its alert during internal refresh cycles (layout update,
          -- combat exit, icon state refresh). Killing our LCG glow here causes it to
          -- disappear prematurely. The SPELL_ACTIVATION_OVERLAY_GLOW_HIDE event is
          -- the authoritative signal for when the spell genuinely deactivates.
          local glowType = parentFrame._arcProcGlowType or "default"
          if glowType ~= "default" then
            if ns.devMode then
              print("|cffFF9900[ArcUI ProcHook]|r OnHide SKIPPED for LCG mode:", glowType, "frame:", parentFrame.cooldownID)
            end
            return
          end
          
          if ns.devMode then
            print("|cffFF0000[ArcUI ProcHook]|r OnHide triggered on frame:", parentFrame.cooldownID)
          end
          
          if ns.CDMEnhance and ns.CDMEnhance.HideProcGlow then
            ns.CDMEnhance.HideProcGlow(parentFrame)
          end
        end
      end)
    end
  end
  
  -- Apply CooldownFlash sizing to match icon frame using EXPAND ANCHORS
  -- (SetSize/SetScale don't work reliably, but anchor offsets do!)
  -- When zoom crops the texture, the icon visually expands to fill more of the frame
  -- So CooldownFlash must also expand to match the visual icon area
  if frame.CooldownFlash then
    local cf = frame.CooldownFlash
    
    -- Reset scale to 1 to ensure anchors control size
    cf:SetScale(1)
    
    -- Calculate inset: padding shrinks, zoom expands
    -- Zoom crops texture borders, making icon visually fill more of the frame
    local frameW, frameH = frame:GetSize()
    local zoomExpandX = (zoom or 0) * frameW
    local zoomExpandY = (zoom or 0) * frameH
    local insetX = padding - zoomExpandX  -- Subtract zoom to expand outward
    local insetY = padding - zoomExpandY
    
    -- Apply anchors to match the visual icon area
    -- CDM uses +1 Y offset by default, we preserve that
    cf:ClearAllPoints()
    cf:SetPoint("TOPLEFT", frame, "TOPLEFT", insetX, -insetY + 1)
    cf:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -insetX, insetY + 1)
    
    -- Hook frame's SetSize to update CooldownFlash anchors when frame resizes
    -- This catches size changes from CDMGroups scale slider
    if not frame._arcCFSizeHooked then
      frame._arcCFSizeHooked = true
      hooksecurefunc(frame, "SetSize", function(self, newW, newH)
        local pad = self._arcPadding or 0
        local zm = self._arcZoom or 0
        local w = newW or self:GetWidth()
        local h = newH or self:GetHeight()
        -- Recalculate: zoom expands, padding shrinks
        local zExpandX = zm * w
        local zExpandY = zm * h
        
        -- For CooldownFlash: padding shrinks, zoom expands (inset calculation)
        local cfInsetX = pad - zExpandX
        local cfInsetY = pad - zExpandY
        
        -- For borders: base 3px offset + zoom expansion - padding
        local baseBorderOffset = 3
        local borderExpandX = baseBorderOffset + zExpandX - pad
        local borderExpandY = baseBorderOffset + zExpandY - pad
        
        -- Update CooldownFlash
        if self.CooldownFlash then
          self.CooldownFlash:ClearAllPoints()
          self.CooldownFlash:SetPoint("TOPLEFT", self, "TOPLEFT", cfInsetX, -cfInsetY + 1)
          self.CooldownFlash:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -cfInsetX, cfInsetY + 1)
        end
        
        -- Update DebuffBorder if enabled
        if self.DebuffBorder and self._arcShowDebuffBorder then
          self.DebuffBorder:ClearAllPoints()
          self.DebuffBorder:SetPoint("TOPLEFT", self, "TOPLEFT", -borderExpandX, borderExpandY)
          self.DebuffBorder:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", borderExpandX, -borderExpandY)
        end
        
        -- Update PandemicIcon if enabled
        if self.PandemicIcon and self._arcShowPandemic then
          self.PandemicIcon:ClearAllPoints()
          self.PandemicIcon:SetPoint("TOPLEFT", self, "TOPLEFT", -borderExpandX, borderExpandY)
          self.PandemicIcon:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", borderExpandX, -borderExpandY)
        end
        -- Update shadow overlay anchors
        if self._arcIconOverlay then
          local overlayAlpha = self._arcIconOverlay:GetAlpha()
          if overlayAlpha and overlayAlpha > 0 then
            local iconTex = self.Icon or self.icon
            local anchor = iconTex or self
            local shadowSize = (self._arcCfg and self._arcCfg.shadowSize) or 1.0
            local sox = w * 0.18 * shadowSize
            local soy = h * 0.16 * shadowSize
            self._arcIconOverlay:ClearAllPoints()
            self._arcIconOverlay:SetPoint("TOPLEFT",     anchor, "TOPLEFT",     -sox,  soy)
            self._arcIconOverlay:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT",  sox, -soy)
          end
        end
      end)
    end
  end
  -- When Masque controls cooldowns, we skip ALL positioning, insets, hooks, etc.
  -- ═══════════════════════════════════════════════════════════════════
  local masqueControlsCooldowns = ns.Masque and ns.Masque.ShouldMasqueControlCooldowns and ns.Masque.ShouldMasqueControlCooldowns()
  local swipeCfg = cfg.cooldownSwipe

  -- ═══════════════════════════════════════════════════════════════════
  -- PRESERVE DURATION TEXT HOOK — unconditional, installed for all frames.
  -- CDM's SetCooldown recreates internal fontstrings each call, losing any
  -- SetIgnoreParentAlpha state. Re-apply when _arcPreserveDurationText is set.
  -- Must be unconditional: the swipeCfg hook below is gated and misses frames
  -- with no swipe config (e.g. Voidform with no cooldown swipe settings).
  -- ═══════════════════════════════════════════════════════════════════
  if frame.Cooldown and not frame.Cooldown._arcPreserveTextHooked then
    frame.Cooldown._arcPreserveTextHooked = true
    frame.Cooldown._arcParentFrameForPreserve = frame
    local function ReapplyPreserveText(self)
      local pf = self._arcParentFrameForPreserve
      if not pf or not pf._arcPreserveDurationText then return end
      if pf._arcBypassCDHook then return end
      -- Don't re-enable IgnoreParentAlpha when the group container is hidden.
      -- Without this guard, CDM pushing a new DurationObject fires this hook
      -- and restores SetIgnoreParentAlpha(true) on a frame whose group is at
      -- alpha=0, making the text float visible over an invisible group.
      if pf._arcGroupHidden then return end
      local pfParent = pf:GetParent()
      if pfParent and pfParent._arcGroupHidden then return end
      self:SetAlpha(1)
      local countdownFS = self.GetCountdownFontString and self:GetCountdownFontString()
      if countdownFS and countdownFS.SetIgnoreParentAlpha then
        countdownFS:SetIgnoreParentAlpha(true)
        countdownFS:SetAlpha(1)
      end
      for _, region in ipairs({self:GetRegions()}) do
        if region:IsObjectType("FontString") and region.SetIgnoreParentAlpha
           and not region._arcIsChargeText then
          region:SetIgnoreParentAlpha(true)
          region:SetAlpha(1)
        end
      end
    end
    hooksecurefunc(frame.Cooldown, "SetCooldown", ReapplyPreserveText)
    hooksecurefunc(frame.Cooldown, "SetCooldownFromDurationObject", ReapplyPreserveText)
  end

  -- GCD filtering on the visual Cooldown frame — ArcUI_GCDFilter.lua owns this.
  -- Install is called below after _arcNoGCDSwipeEnabled is stored.

    -- Get swipe insets from config (only used when ArcUI controls cooldowns)
  local swipeInsetX, swipeInsetY
  if swipeCfg and swipeCfg.separateInsets then
    -- Use separate X/Y insets
    swipeInsetX = swipeCfg.swipeInsetX or 0
    swipeInsetY = swipeCfg.swipeInsetY or 0
  else
    -- Use single inset for both
    local inset = (swipeCfg and swipeCfg.swipeInset) or 0
    swipeInsetX = inset
    swipeInsetY = inset
  end
  local totalSwipePaddingX = padding + swipeInsetX
  local totalSwipePaddingY = padding + swipeInsetY

  -- When keepCDMStyle=ON: swipe and mask are both SetAllPoints(frame).
  -- The CDM swipe texture has rounded corners baked to the full frame size.
  -- Ignore padding and zoom — swipe must exactly match frame bounds.
  do
    local specData = Shared and Shared.GetCurrentSpecData and Shared.GetCurrentSpecData()
    if specData and specData.keepCDMStyle == true then
      totalSwipePaddingX = 0
      totalSwipePaddingY = 0
    end
  end


  
  -- Cooldown swipe positioning - SKIP ENTIRELY when Masque controls cooldowns
  if frame.Cooldown and not masqueControlsCooldowns then
    -- Always anchor to frame with padding regardless of Masque icon skinning state.
    -- (When masqueActive but not controlling cooldowns, Icon is inset by Masque's skin
    -- so SetAllPoints(Icon) would shrink the cooldown — use frame-relative padding instead.)
    frame.Cooldown._arcMasqueActive = nil
    frame.Cooldown:ClearAllPoints()
    frame.Cooldown:SetPoint("TOPLEFT", frame, "TOPLEFT", totalSwipePaddingX, -totalSwipePaddingY)
    frame.Cooldown:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -totalSwipePaddingX, totalSwipePaddingY)

    -- Apply matching texcoord range to cooldown swipe so it matches icon crop.
    -- SKIP when keepCDMStyle=ON: CDM's rounded swipe texture needs natural (0,0)→(1,1)
    -- coords — applying icon crop distorts the pre-shaped rounded texture.
    if frame.Cooldown.SetTexCoordRange then
      local specData = Shared and Shared.GetCurrentSpecData and Shared.GetCurrentSpecData()
      local keepCDMStyle = specData and specData.keepCDMStyle == true
      if not keepCDMStyle then
        local tc = frame._arcTexCoords
        if tc then
          local lowVec = CreateVector2D(tc.left, tc.top)
          local highVec = CreateVector2D(tc.right, tc.bottom)
          frame.Cooldown:SetTexCoordRange(lowVec, highVec)
        end
      else
        -- Reset to natural full-texture coords
        local lowVec = CreateVector2D(0, 0)
        local highVec = CreateVector2D(1, 1)
        frame.Cooldown:SetTexCoordRange(lowVec, highVec)
      end
    end

    -- Store padding on cooldown for hooks (includes swipe insets)
    frame.Cooldown._arcPaddingX = totalSwipePaddingX
    frame.Cooldown._arcPaddingY = totalSwipePaddingY
    frame.Cooldown._arcParentFrame = frame

    -- Hook SetAllPoints to prevent CDM from resetting our padding
    if not frame.Cooldown._arcPositionHooked then
      frame.Cooldown._arcPositionHooked = true
      hooksecurefunc(frame.Cooldown, "SetAllPoints", function(self)
        if self._arcMasqueActive then return end
        local parent = self._arcParentFrame
        local padX = self._arcPaddingX or 0
        local padY = self._arcPaddingY or 0
        if parent and (padX > 0 or padY > 0) then
          self:ClearAllPoints()
          self:SetPoint("TOPLEFT", parent, "TOPLEFT", padX, -padY)
          self:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -padX, padY)
        end
        -- Reapply texcoord range — but only when keepCDMStyle is OFF
        local sd = Shared and Shared.GetCurrentSpecData and Shared.GetCurrentSpecData()
        local kcs = sd and sd.keepCDMStyle == true
        if not kcs and parent and parent._arcTexCoords and self.SetTexCoordRange then
          local tc = parent._arcTexCoords
          local lowVec = CreateVector2D(tc.left, tc.top)
          local highVec = CreateVector2D(tc.right, tc.bottom)
          self:SetTexCoordRange(lowVec, highVec)
        end
      end)
    end
    
  end -- END: if frame.Cooldown and not masqueControlsCooldowns
  
  -- ═══════════════════════════════════════════════════════════════════
  -- FRAME SETSIZE HOOK (OUTSIDE masqueControlsCooldowns guard)
  -- Borders + pandemic/debuff overlays need updating on resize regardless
  -- of whether Masque controls cooldowns. Cooldown positioning inside the
  -- hook already checks _arcMasqueActive so it self-gates correctly.
  -- ═══════════════════════════════════════════════════════════════════
  if not frame._arcFrameSizeHooked then
    frame._arcFrameSizeHooked = true
    hooksecurefunc(frame, "SetSize", function(self)
      if self._arcSettingFrameSize then return end
      
      -- Update Cooldown positioning (skip if Masque controls layout)
      if self.Cooldown and self.Cooldown._arcParentFrame and not self.Cooldown._arcMasqueActive then
        local padX = self.Cooldown._arcPaddingX or 0
        local padY = self.Cooldown._arcPaddingY or 0
        if padX > 0 or padY > 0 then
          self.Cooldown:ClearAllPoints()
          self.Cooldown:SetPoint("TOPLEFT", self, "TOPLEFT", padX, -padY)
          self.Cooldown:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -padX, padY)
        end
      end
      
      -- Update borders on resize (pandemic/debuff need proper sizing)
      local pad = self._arcPadding or 0
      local zm = self._arcZoom or 0
      
      if self.PandemicIcon and self._arcShowPandemic then
        ModuleEnableBorderFrame(self.PandemicIcon, self, pad, zm, "pandemic")
      end
      
      if self.DebuffBorder and self._arcShowDebuffBorder then
        ModuleEnableBorderFrame(self.DebuffBorder, self, pad, zm, "debuff")
      end
      
      -- Update custom border on resize
      if self._arcBorderEdges then
        local cdID = self.cooldownID
        if cdID then
          UpdateIconBorder(self, cdID, nil, nil, pad, zm)
        end
      end
    end)
  end
    
  -- Check for ignoreAuraOverride from either location (old: cooldownSwipe, new: auraActiveState)
  -- This must be set REGARDLESS of Masque cooldown control
  local ignoreAuraOverride = (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)
    or (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
  frame._arcIgnoreAuraOverride = ignoreAuraOverride or false
  
  -- Custom Icon Override: spell ID or texture file ID
  local customIconID = cfg.customIconID
  frame._arcCustomIconID = customIconID
    
  -- ═══════════════════════════════════════════════════════════════════
  -- MASQUE CONTROLS COOLDOWNS: Skip cooldown styling but keep No GCD Swipe
  -- Only skip: SetSwipeColor, SetReverse, SetDrawBling, SetDrawSwipe (styling), 
  --            SetDrawEdge (styling), SetEdgeScale, SetEdgeColor, positioning, TexCoordRange
  -- Keep working: No GCD Swipe toggle, CooldownFlash (Bling) visibility
  -- NOTE: When ignoreAuraOverride or customIconID is enabled, use ArcUI path so texture hook gets installed
  -- ═══════════════════════════════════════════════════════════════════
  if masqueControlsCooldowns and not ignoreAuraOverride and not customIconID then
    -- Store NoGCD flags (these work with Masque)
    if swipeCfg then
      frame._arcNoGCDSwipeEnabled = swipeCfg.noGCDSwipe
      frame._arcSwipeWaitForNoCharges = swipeCfg.swipeWaitForNoCharges
      frame._arcEdgeWaitForNoCharges = swipeCfg.edgeWaitForNoCharges
    end
    -- GCD filter hooks on visual Cooldown frame — cooldown/utility only, never aura frames
    if ns.GCDFilter and viewerType ~= "aura" then ns.GCDFilter.Install(frame, cdID) end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- APPLY SHOW SWIPE / SHOW EDGE — Masque owns cooldown, don't enforce
    -- User's showSwipe/showEdge prefs only apply in non-Masque path
    -- ═══════════════════════════════════════════════════════════════════
    
    -- CooldownFlash (Bling) visibility can still be controlled
    if swipeCfg and frame.CooldownFlash then
      if swipeCfg.showBling == false then
        frame.CooldownFlash:SetAlpha(0)
        if frame.CooldownFlash.Flipbook then
          frame.CooldownFlash.Flipbook:SetAlpha(0)
          if not frame.CooldownFlash.Flipbook._arcAlphaHooked then
            frame.CooldownFlash.Flipbook._arcAlphaHooked = true
            frame.CooldownFlash.Flipbook._arcIconFrame = frame
            hooksecurefunc(frame.CooldownFlash.Flipbook, "SetAlpha", function(self, alpha)
              local iconFrame = self._arcIconFrame
              if iconFrame and iconFrame._arcHideCooldownFlash and alpha > 0 then
                self:SetAlpha(0)
              end
            end)
          end
        end
        if frame.CooldownFlash.FlashAnim and frame.CooldownFlash.FlashAnim.Stop then
          frame.CooldownFlash.FlashAnim:Stop()
          if not frame.CooldownFlash.FlashAnim._arcHideHooked then
            frame.CooldownFlash.FlashAnim._arcHideHooked = true
            frame.CooldownFlash.FlashAnim._arcIconFrame = frame
            hooksecurefunc(frame.CooldownFlash.FlashAnim, "Play", function(self)
              local iconFrame = self._arcIconFrame
              if iconFrame and iconFrame._arcHideCooldownFlash then
                self:Stop()
              end
            end)
          end
        end
        if not frame.CooldownFlash._arcAlphaHooked then
          frame.CooldownFlash._arcAlphaHooked = true
          frame.CooldownFlash._arcIconFrame = frame
          hooksecurefunc(frame.CooldownFlash, "SetAlpha", function(self, alpha)
            local iconFrame = self._arcIconFrame
            if iconFrame and iconFrame._arcHideCooldownFlash and alpha > 0 then
              self:SetAlpha(0)
            end
          end)
        end
        frame._arcHideCooldownFlash = true
      else
        frame._arcHideCooldownFlash = false
        frame.CooldownFlash:SetAlpha(1)
      end
    end

    -- GCD intercept hook installed above (before Masque branch) — shared path.

    -- Apply swipe color - Masque doesn't override this, we help it
    if swipeCfg and swipeCfg.swipeColor and frame.Cooldown then
      local sc = swipeCfg.swipeColor
      frame.Cooldown:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- SETCOOLDOWN HOOK FOR MASQUE - Help Masque apply its color during combat
    -- Also applies user's reverse setting and handles charge spell GCD hiding
    -- ═══════════════════════════════════════════════════════════════════
    if frame.Cooldown and not frame.Cooldown._arcMasqueCDHooked then
      frame.Cooldown._arcMasqueCDHooked = true
      frame.Cooldown._arcParentFrame = frame
      frame.Cooldown._arcCdID = cdID
      
      -- Store user's reverse settings for the SetCooldown hook to use
      frame._arcUserReverse      = swipeCfg and swipeCfg.reverse == true
      frame._arcReverseWhileAura = swipeCfg and swipeCfg.reverseWhileAura == true
      
      hooksecurefunc(frame.Cooldown, "SetCooldown", function(self)
        local parentFrame = self._arcParentFrame
        if not parentFrame then return end
        
        -- Help Masque apply its skin color during combat
        -- Masque's Hook_SetSwipeColor has issues with secret values
        local masqueColor = self._MSQ_Color
        if masqueColor then
          local r = masqueColor.r or masqueColor[1] or 0
          local g = masqueColor.g or masqueColor[2] or 0
          local b = masqueColor.b or masqueColor[3] or 0
          local a = masqueColor.a or masqueColor[4] or 0.8
          
          -- Set Masque's reentrancy guard to bypass their hook
          self._Swipe_Hook = true
          self:SetSwipeColor(r, g, b, a)
          self._Swipe_Hook = nil
        end
        
        -- Apply user's reverse (animation direction) setting
        -- CDM template has reverse="true" by default, so we need to set it explicitly
        local auraActive = (parentFrame._arcAuraActive == true) or (parentFrame.totemData ~= nil)
        self:SetReverse((parentFrame._arcUserReverse or false) or (auraActive and (parentFrame._arcReverseWhileAura or false)))
      end)
    end
    
    -- Skip other cooldown customization - Masque handles styling
    -- Don't touch: SetReverse, SetDrawBling, SetDrawSwipe (style),
    -- SetDrawEdge (style), SetEdgeScale, SetEdgeColor, positioning, TexCoordRange
    
  else
    -- ARCUI CONTROLS COOLDOWNS: Apply all user settings
    
    -- Apply custom swipe color if set
    if swipeCfg and swipeCfg.swipeColor then
      local sc = swipeCfg.swipeColor
      frame.Cooldown:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- FINISH FLASH (BLING) - Can be controlled even when Masque is active
    -- ═══════════════════════════════════════════════════════════════════
    if swipeCfg and frame.CooldownFlash then
      -- Apply SetDrawBling (only if Masque doesn't control - Masque handles this itself)
      if not masqueControlsCooldowns then
        frame.Cooldown:SetDrawBling(swipeCfg.showBling ~= false)
      end
      
      -- Hide/show CooldownFlash frame (CDM's separate flash animation)
      -- This works regardless of Masque - it's the visual flipbook animation
      -- Structure: CooldownFlash.Flipbook (texture), CooldownFlash.FlashAnim (AnimationGroup)
      if swipeCfg.showBling == false then
        -- Hide via alpha (not Hide()) so CDM's Show() calls still work
        frame.CooldownFlash:SetAlpha(0)
        
        -- Hide Flipbook texture (the actual animation visual)
        if frame.CooldownFlash.Flipbook then
          frame.CooldownFlash.Flipbook:SetAlpha(0)
          
          -- Hook Flipbook:SetAlpha to enforce 0
          if not frame.CooldownFlash.Flipbook._arcAlphaHooked then
            frame.CooldownFlash.Flipbook._arcAlphaHooked = true
            frame.CooldownFlash.Flipbook._arcIconFrame = frame
            hooksecurefunc(frame.CooldownFlash.Flipbook, "SetAlpha", function(self, alpha)
              local iconFrame = self._arcIconFrame
              if iconFrame and iconFrame._arcHideCooldownFlash and alpha > 0 then
                self:SetAlpha(0)
              end
            end)
          end
        end
        
        -- Stop FlashAnim animation group (AnimationGroups use Stop(), not Hide/SetAlpha)
        if frame.CooldownFlash.FlashAnim and frame.CooldownFlash.FlashAnim.Stop then
          frame.CooldownFlash.FlashAnim:Stop()
          
          -- Hook FlashAnim:Play to prevent it from playing
          if not frame.CooldownFlash.FlashAnim._arcHideHooked then
            frame.CooldownFlash.FlashAnim._arcHideHooked = true
            frame.CooldownFlash.FlashAnim._arcIconFrame = frame
            hooksecurefunc(frame.CooldownFlash.FlashAnim, "Play", function(self)
              local iconFrame = self._arcIconFrame
              if iconFrame and iconFrame._arcHideCooldownFlash then
                self:Stop()
              end
            end)
          end
        end
        
        -- Hook CooldownFlash:SetAlpha to enforce 0
        if not frame.CooldownFlash._arcAlphaHooked then
          frame.CooldownFlash._arcAlphaHooked = true
          frame.CooldownFlash._arcIconFrame = frame
          hooksecurefunc(frame.CooldownFlash, "SetAlpha", function(self, alpha)
            local iconFrame = self._arcIconFrame
            if iconFrame and iconFrame._arcHideCooldownFlash and alpha > 0 then
              self:SetAlpha(0)
            end
          end)
        end
        frame._arcHideCooldownFlash = true
      else
        -- Re-enable CooldownFlash - clear flag and restore parent frame visibility
        frame._arcHideCooldownFlash = false
        -- Restore parent frame to visible so child animations can be seen
        -- Don't touch Flipbook alpha - the animation controls it (starts from 0)
        frame.CooldownFlash:SetAlpha(1)
      end
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- NO GCD SWIPE - Can be controlled even when Masque is active
    -- Store the flag on frame so SetCooldown hook can use it
    -- ═══════════════════════════════════════════════════════════════════
    if swipeCfg then
      frame._arcNoGCDSwipeEnabled = swipeCfg.noGCDSwipe
      frame._arcSwipeWaitForNoCharges = swipeCfg.swipeWaitForNoCharges
      frame._arcEdgeWaitForNoCharges = swipeCfg.edgeWaitForNoCharges
      -- Store swipe/edge settings for noGCDSwipe mode to use
    end
    -- GCD filter hooks on visual Cooldown frame — cooldown/utility only, never aura frames
    if ns.GCDFilter and viewerType ~= "aura" then ns.GCDFilter.Install(frame, cdID) end
    
    -- Apply cooldown swipe customization
    -- IAO frames need hooks even when Masque controls cooldowns, because IAO
    -- takes full control of the cooldown display (spell CD instead of aura).
    if swipeCfg and (not masqueControlsCooldowns or ignoreAuraOverride) then
      -- ArcUI controls: Apply all user settings
      frame.Cooldown:SetDrawSwipe(swipeCfg.showSwipe ~= false)
      frame.Cooldown:SetDrawEdge(swipeCfg.showEdge ~= false)
      -- Aura-aware reverse: honor "Reverse While Aura Active" right here in the
      -- style-apply path. This path re-runs on CDM's post-combat refresh; if it
      -- only set the base reverse it would stomp the reversed direction back to
      -- normal while the aura is still up (the out-of-combat revert bug). Mirrors
      -- the Masque SetCooldown hook above, the aura-transition handlers, and CooldownState.
      local auraActive = (frame._arcAuraActive == true) or (frame.totemData ~= nil)
      frame.Cooldown:SetReverse((swipeCfg.reverse == true) or (auraActive and swipeCfg.reverseWhileAura == true))

      -- Apply edge scale (size of spinning edge line)
      if swipeCfg.edgeScale and frame.Cooldown.SetEdgeScale then
        frame.Cooldown:SetEdgeScale(swipeCfg.edgeScale)
      end
      
      -- Apply custom edge color if set
      if swipeCfg.edgeColor and frame.Cooldown.SetEdgeColor then
        local ec = swipeCfg.edgeColor
        frame.Cooldown:SetEdgeColor(ec.r or 1, ec.g or 1, ec.b or 1, ec.a or 1)
      end
      
      -- ═══════════════════════════════════════════════════════════════════
      -- SWIPE MODE HANDLING (Toggle-based)
      -- ═══════════════════════════════════════════════════════════════════
      local noGCDSwipe = swipeCfg.noGCDSwipe
      local swipeWaitForNoCharges = swipeCfg.swipeWaitForNoCharges
      
      -- Build mode signature for change detection
      local modeSignature = (noGCDSwipe and "noGCD_" or "") .. (swipeWaitForNoCharges and "waitNoChg_" or "") .. (ignoreAuraOverride and "ignoreAura" or "normal")
      
      -- Clean up previous mode state if mode changed
      if frame._arcSwipeMode ~= modeSignature then
        local prevMode = frame._arcSwipeMode
        frame._arcSwipeMode = modeSignature
        
        -- Restore original cooldown frame state
        frame.Cooldown:SetAlpha(1)
        frame.Cooldown:Show()

        if not ignoreAuraOverride then
          -- NOT in special mode - clear ALL our forced state and let CDM handle everything
          frame._arcForceDesatValue = nil
          
          -- Reset text alpha handling
          if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
            if not frame._arcSwipeWaitForNoCharges then frame._arcCooldownText:SetIgnoreParentAlpha(false) end
          end
          if frame._arcChargeText and frame._arcChargeText.SetIgnoreParentAlpha then
            if not frame._arcSwipeWaitForNoCharges then frame._arcChargeText:SetIgnoreParentAlpha(false) end
          end
          
          -- Restore CDM's aura-duration display after EXITING Ignore-Aura-Override.
          -- Only when we were actually overriding (prev mode was IAO) — a frame that was
          -- never in IAO has nothing to undo, so this no longer fires for every normal
          -- icon. NEVER call viewerFrame:RefreshData() from this tainted addon path: on
          -- 12.0.7 that runs CDM's RefreshTotemData/RefreshAuraInstance/CacheCooldownValues
          -- tainted and their unguarded secret comparisons throw, bricking the whole UI
          -- mid-instance (the "tainted by ArcUI" cascade).
          if prevMode and prevMode:find("ignoreAura", 1, true) and frame.Cooldown then
            -- IAOFight had set SetUseAuraDisplayTime(false); restore aura display mode.
            if frame.Cooldown.SetUseAuraDisplayTime then
              frame.Cooldown:SetUseAuraDisplayTime(true)
            end
            -- Best-effort immediate re-push of the aura's real remaining duration via the
            -- approved secret-safe sink, so the swipe is correct at once instead of waiting
            -- for CDM's next aura event. Fully guarded: if the API is unavailable, CDM's
            -- next refresh restores it. _arcBypassCDHook mirrors the IAO entry push above.
            if (frame.wasSetFromAura == true) and frame.auraInstanceID
               and C_UnitAuras and C_UnitAuras.GetAuraDuration
               and frame.Cooldown.SetCooldownFromDurationObject then
              local durObj = C_UnitAuras.GetAuraDuration(frame.auraDataUnit or "player", frame.auraInstanceID)
              if durObj then
                frame._arcBypassCDHook = true
                frame.Cooldown:SetCooldownFromDurationObject(durObj)
                frame._arcBypassCDHook = false
              end
            end
          end
        end
      end
      
      -- Cache whether this is a charge spell (needed by CooldownState binary detection).
      -- Required for: noGCDSwipe GCD intercept, ignoreAuraOverride recharge detection,
      -- swipeWaitForNoCharges, and any path reading GetBinaryCooldownState.
      -- Charge type is static per spellID — only re-check when spellID changes.
      do
        local cooldownInfo = frame.cooldownInfo
        local spellID = cooldownInfo and (cooldownInfo.overrideSpellID or cooldownInfo.spellID)
        if spellID then
          if frame._arcChargeCheckSpellID ~= spellID then
            frame._arcChargeCheckSpellID = spellID
            local chargeInfo = C_Spell.GetSpellCharges(spellID)
            -- maxCharges must be explicitly >1. nil or 1 = normal spell, not a charge spell.
            local isMultiCharge = chargeInfo ~= nil and chargeInfo.maxCharges ~= nil and chargeInfo.maxCharges > 1
            local chargeDurObj = isMultiCharge and C_Spell.GetSpellChargeDuration and C_Spell.GetSpellChargeDuration(spellID, true)
            frame._arcIsChargeSpellCached = (isMultiCharge and chargeDurObj ~= nil)
          end
        else
          frame._arcIsChargeSpellCached = false
          frame._arcChargeCheckSpellID = nil
        end
      end
      
      -- ═══════════════════════════════════════════════════════════════════
      -- SWIPE WAIT FOR NO CHARGES (charge spell handling)
      -- Only show cooldown swipe when ALL charges are consumed.
      -- Uses curves to handle secret durationObj values properly.
      -- Duration text stays visible via SetIgnoreParentAlpha (unless hideTextWithSwipe).
      -- ═══════════════════════════════════════════════════════════════════
      if swipeWaitForNoCharges then
        -- _arcIsChargeSpellCached already set above — no second GetSpellCharges call needed
        if frame._arcIsChargeSpellCached and not swipeCfg.hideTextWithSwipe then
          if frame._arcPreserveDurationText and (frame._lastAppliedAlpha or 1) > 0.01 and not frame._arcGroupHidden and not (frame:GetParent() and frame:GetParent()._arcGroupHidden) then
            if frame.Cooldown then
              for _, region in ipairs({frame.Cooldown:GetRegions()}) do
                if region:IsObjectType("FontString") and region.SetIgnoreParentAlpha then
                  region:SetIgnoreParentAlpha(true)
                end
              end
            end
            if not frame._arcHideCDTextForCharges then
              if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                frame._arcCooldownText:SetIgnoreParentAlpha(true)
              end
            end
            if not frame._arcHideChargeAtZero then
              if frame._arcChargeText and frame._arcChargeText.SetIgnoreParentAlpha then
                frame._arcChargeText:SetIgnoreParentAlpha(true)
              end
            end
          end
        end
      end

      -- GCD intercept hook installed above (before Masque branch) — shared path.
      
      -- ═══════════════════════════════════════════════════════════════════
      -- SWIPE HOOK - Install unconditionally so it works for both
      -- noGCDSwipe and ignoreAuraOverride modes
      -- ═══════════════════════════════════════════════════════════════════
      if frame.Cooldown and not frame.Cooldown._arcSwipeHooked then
        frame.Cooldown._arcSwipeHooked = true
        frame.Cooldown._arcParentFrame = frame

        hooksecurefunc(frame.Cooldown, "SetDrawSwipe", _T("CDMHook.SetDrawSwipe", function(self, drawSwipe)
          local pf = self._arcParentFrame
          if not pf then return end
          if pf._arcBypassSwipeHook then return end

          -- PREVIEW MODE: reapply preview settings if CDM tries to change swipe
          if pf._arcSwipePreviewActive then
            local cfg = GetIconSettings(self._arcCdID)
            local swipeCfg = cfg and cfg.cooldownSwipe
            local wantSwipe = not swipeCfg or swipeCfg.showSwipe ~= false
            local wantEdge  = not swipeCfg or swipeCfg.showEdge  ~= false
            if drawSwipe ~= wantSwipe then
              pf._arcBypassSwipeHook = true
              self:SetDrawSwipe(wantSwipe)
              self:SetDrawEdge(wantEdge)
              pf._arcBypassSwipeHook = false
            end
            return
          end

          -- CooldownState is the authority: hold the line against CDM overrides.
          if pf._arcDesiredSwipe ~= nil then
            if drawSwipe ~= pf._arcDesiredSwipe then
              pf._arcBypassSwipeHook = true
              self:SetDrawSwipe(pf._arcDesiredSwipe)
              if pf._arcDesiredEdge ~= nil then self:SetDrawEdge(pf._arcDesiredEdge) end
              pf._arcBypassSwipeHook = false
            end
            return
          end

          -- No CooldownState decision yet — enforce user setting directly
          local currentCdID = self._arcCdID
          if currentCdID then
            local cfg = GetIconSettings(currentCdID)
            if cfg and cfg.cooldownSwipe then
              local userWantsSwipe = cfg.cooldownSwipe.showSwipe ~= false
              local userWantsEdge  = cfg.cooldownSwipe.showEdge  ~= false
              -- swipeWaitForNoCharges: suppress swipe when recharging (charge shadow shown,
              -- main shadow not shown). Covers the race where CDM fires SetDrawSwipe(true)
              -- before CooldownState has set _arcDesiredSwipe for the new charge state.
              if userWantsSwipe and cfg.cooldownSwipe.swipeWaitForNoCharges and pf._arcIsChargeSpellCached then
                local mainShadow = pf._arcCDMShadowCooldown
                local chargeShadow = pf._arcCDMChargeShadow
                local mainShown = mainShadow and mainShadow:IsShown() or false
                local chargeShown = chargeShadow and chargeShadow:IsShown() or false
                if chargeShown and not mainShown then
                  -- Recharging: suppress swipe regardless of CDM's request
                  if drawSwipe then
                    pf._arcBypassSwipeHook = true
                    self:SetDrawSwipe(false)
                    pf._arcBypassSwipeHook = false
                  end
                  return
                end
              end
              if drawSwipe ~= userWantsSwipe then
                pf._arcBypassSwipeHook = true
                self:SetDrawSwipe(userWantsSwipe)
                self:SetDrawEdge(userWantsEdge)
                pf._arcBypassSwipeHook = false
              end
            end
          end
        end))
      end
      
      -- ═══════════════════════════════════════════════════════════════════
      -- EDGE HOOK
      -- ═══════════════════════════════════════════════════════════════════
      if frame.Cooldown and not frame.Cooldown._arcEdgeHooked then
        frame.Cooldown._arcEdgeHooked = true

        hooksecurefunc(frame.Cooldown, "SetDrawEdge", _T("CDMHook.SetDrawEdge", function(self, drawEdge)
          local pf = self._arcParentFrame
          if not pf then return end
          if pf._arcBypassSwipeHook then return end

          if pf._arcDesiredEdge ~= nil then
            if drawEdge ~= pf._arcDesiredEdge then
              pf._arcBypassSwipeHook = true
              self:SetDrawEdge(pf._arcDesiredEdge)
              pf._arcBypassSwipeHook = false
            end
            return
          end

          -- No CooldownState decision yet — enforce user setting directly
          local currentCdID = self._arcCdID
          if currentCdID then
            local cfg = GetIconSettings(currentCdID)
            if cfg and cfg.cooldownSwipe then
              local userWantsEdge = cfg.cooldownSwipe.showEdge ~= false
              if drawEdge ~= userWantsEdge then
                pf._arcBypassSwipeHook = true
                self:SetDrawEdge(userWantsEdge)
                pf._arcBypassSwipeHook = false
              end
            end
          end
        end))
      end

      -- ═══════════════════════════════════════════════════════════════════
      -- SWIPE COLOR HOOK - Enforce auraSwipeColor when aura is active
      -- CDM calls SetSwipeColor with yellow (ITEM_AURA_COLOR) whenever it
      -- renders aura display. We intercept and apply the user's color instead.
      -- ═══════════════════════════════════════════════════════════════════
      if frame.Cooldown and not frame.Cooldown._arcSwipeColorHooked then
        frame.Cooldown._arcSwipeColorHooked = true

        hooksecurefunc(frame.Cooldown, "SetSwipeColor", _T("CDMHook.SetSwipeColor", function(self, r, g, b, a)
          local pf = self._arcParentFrame
          if not pf then return end
          if pf._arcBypassSwipeHook then return end
          local cfg = self._arcCdID and GetIconSettings(self._arcCdID)
          local sc = cfg and cfg.cooldownSwipe and cfg.cooldownSwipe.auraSwipeColor
          if not sc then return end
          local isActive = (pf._arcAuraActive == true) or (pf.totemData ~= nil)
          if not isActive then return end
          -- Only re-apply if CDM set a different color
          if r == sc.r and g == sc.g and b == sc.b then return end
          pf._arcBypassSwipeHook = true
          self:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.7)
          pf._arcBypassSwipeHook = false
        end))
      end

      -- ═══════════════════════════════════════════════════════════════════
      -- COOLDOWN ALPHA HOOK - Prevent CDM from overriding our alpha during preview
      -- ═══════════════════════════════════════════════════════════════════
      if frame.Cooldown and not frame.Cooldown._arcAlphaHooked then
        frame.Cooldown._arcAlphaHooked = true
        
        hooksecurefunc(frame.Cooldown, "SetAlpha", function(self, alpha)
          local pf = self._arcParentFrame
          if not pf then return end
          if pf._arcBypassAlphaHook then return end
          
          -- PREVIEW MODE: CDM tried to set alpha, but we're previewing - force alpha to 1
          if pf._arcSwipePreviewActive then
            if alpha ~= 1 then
              pf._arcBypassAlphaHook = true
              self:SetAlpha(1)
              pf._arcBypassAlphaHook = false
            end
          end
        end)
      end
      
      -- Handle Ignore Aura Override toggle
      if ignoreAuraOverride then
        -- Store ALL user's swipe/animation preferences for ignoreAuraOverride to respect
        frame._arcShowSwipe = swipeCfg.showSwipe ~= false
        frame._arcShowEdge = swipeCfg.showEdge ~= false
        frame._arcShowBling = swipeCfg.showBling ~= false
        frame._arcReverse = swipeCfg.reverse == true
        frame._arcSwipeColor = swipeCfg.swipeColor
        frame._arcEdgeScale = swipeCfg.edgeScale
        frame._arcEdgeColor = swipeCfg.edgeColor
      end
      
      -- If neither toggle is on, let CDM handle everything normally
      if not noGCDSwipe and not ignoreAuraOverride then
        frame.Cooldown:SetAlpha(1)
      end
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- ICON TEXTURE HOOK - Install unconditionally so ignoreAuraOverride
    -- and customIconID work regardless of whether Masque or ArcUI controls cooldowns
    -- ═══════════════════════════════════════════════════════════════════
    if (ignoreAuraOverride or customIconID) and frame.Icon then
      -- Hook Icon:SetTexture to enforce our override texture
      if not frame.Icon._arcTextureHooked then
        frame.Icon._arcTextureHooked = true
        frame.Icon._arcParentFrame = frame
        
        hooksecurefunc(frame.Icon, "SetTexture", function(self, newTexture)
          local pf = self._arcParentFrame
          if not pf then return end
          if pf._arcBypassTextureHook then return end
          
          -- CUSTOM ICON OVERRIDE: Always enforce if set (highest priority)
          local customID = pf._arcCustomIconID
          if customID then
            -- Try as spell ID first, fall back to direct texture file ID
            local texture = C_Spell.GetSpellTexture(customID) or customID
            if texture then
              pf._arcBypassTextureHook = true
              self:SetTexture(texture)
              pf._arcBypassTextureHook = false
            end
            return
          end
          
          -- Only enforce when ignoreAuraOverride is active AND aura is up
          if pf._arcIgnoreAuraOverride then
            local auraActive = pf._arcAuraActive == true
            if auraActive then
              -- Get current override spell from cooldownInfo (updates dynamically based on talents)
              local cooldownInfo = pf.cooldownInfo
              local spellID = cooldownInfo and (cooldownInfo.overrideSpellID or cooldownInfo.spellID)
              if spellID then
                local texture = C_Spell.GetSpellTexture(spellID)
                if texture then
                  pf._arcBypassTextureHook = true
                  self:SetTexture(texture)
                  pf._arcBypassTextureHook = false
                end
              end
            end
          end
        end)
      end
      
      -- Apply initial texture override
      if customIconID then
        -- Custom icon takes priority
        local texture = C_Spell.GetSpellTexture(customIconID) or customIconID
        if texture then
          frame._arcBypassTextureHook = true
          frame.Icon:SetTexture(texture)
          frame._arcBypassTextureHook = false
        end
      elseif ignoreAuraOverride then
        -- Set initial spell texture — ensures we show spell icon immediately, not aura icon
        local cooldownInfo = frame.cooldownInfo
        local spellID = cooldownInfo and (cooldownInfo.overrideSpellID or cooldownInfo.spellID)
        if spellID then
          local texture = C_Spell.GetSpellTexture(spellID)
          if texture then
            frame._arcBypassTextureHook = true
            frame.Icon:SetTexture(texture)
            frame._arcBypassTextureHook = false
          end
        end
      end
    end
    
    -- CUSTOM ICON CLEANUP: If the hook was previously installed but customIconID
    -- is now cleared, restore CDM's original spell icon
    if not customIconID and not ignoreAuraOverride and frame.Icon and frame.Icon._arcTextureHooked then
      local cooldownInfo = frame.cooldownInfo
      local spellID = cooldownInfo and (cooldownInfo.overrideSpellID or cooldownInfo.spellID)
      if spellID then
        local texture = C_Spell.GetSpellTexture(spellID)
        if texture then
          frame._arcBypassTextureHook = true
          frame.Icon:SetTexture(texture)
          frame._arcBypassTextureHook = false
        end
      end
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- DESATURATION HOOKS - Install unconditionally so they work when 
    -- ignoreAuraOverride is enabled/disabled dynamically
    -- ═══════════════════════════════════════════════════════════════════
    if frame.Icon and not frame.Icon._arcDesatHooked then
      frame.Icon._arcDesatHooked = true
      frame.Icon._arcParentFrame = frame
      
      -- Helper function to compute and apply curve-based desaturation
      -- Called by both SetDesaturated and SetDesaturation hooks
      -- Hook SetDesaturated (boolean version) - CDM uses this for auras
      -- NOTE: We can't sync border here because CDM passes secret values
      -- Border sync happens in ApplyCooldownStateVisuals where we control the values
      hooksecurefunc(frame.Icon, "SetDesaturated", _T("CDMHook.SetDesaturated", function(self, desaturated)
        local pf = self._arcParentFrame
        if not pf then return end
        if pf._arcBypassDesatHook then pf._arcLastDesatHookAction = "BYPASS" return end

        -- DURATION OVERRIDE owns desaturation entirely while active — highest
        -- priority, beating CDM's native desat, the forceValue staleness-clear
        -- below, and usability desat. _arcForceDesatValue is 0 (colored, default)
        -- or 1 (user opted into desaturate while active).
        if pf._arcDurOvActive then
          local v = pf._arcForceDesatValue or 0
          pf._arcLastDesatHookAction = "DUROV→" .. tostring(v)
          pf._arcBypassDesatHook = true
          if self.SetDesaturation then self:SetDesaturation(v) else self:SetDesaturated(v == 1) end
          pf._arcBypassDesatHook = false
          return
        end

        -- 12.1 ITEM (trinket) frames: CDM's desat flickers with the GCD — it SATURATES the
        -- icon during a GCD even while the real item cooldown is running (and desaturates a
        -- ready trinket on a GCD). Derive desat from the REAL item cooldown
        -- (GetInventoryItemCooldown, inherently GCD-free): on item CD => desaturated, ready
        -- => saturated. Steady through GCDs. >1.5 filters GCD-length noise (see GCDFilter).
        local eqSlot = pf.cooldownInfo and pf.cooldownInfo.equipSlot
        if eqSlot then
          local _, idur = GetInventoryItemCooldown("player", eqSlot)
          local onItemCD = (idur and idur > 1.5) and true or false
          pf._arcLastDesatHookAction = "ITEM→" .. (onItemCD and "1" or "0")
          pf._arcBypassDesatHook = true
          if self.SetDesaturation then self:SetDesaturation(onItemCD and 1 or 0) else self:SetDesaturated(onItemCD) end
          pf._arcBypassDesatHook = false
          return
        end

        -- FAST PATH: Skip all work when no dynamic overrides are active AND
        -- cfg says no intercept is needed. Avoids GetEffectiveIconSettingsForFrame
        -- and GetEffectiveStateVisuals (which allocates a table) on PASSTHROUGH calls.
        if not pf._arcUsabilityDesatRequest and pf._arcForceDesatValue == nil then
          if pf._arcCfgCdID == pf.cooldownID and pf._arcCfgVersion == effectiveSettingsCacheVersion
             and not pf._arcCachedNeedDesatIntercept then
            pf._arcLastDesatHookAction = "PASSTHROUGH"
            return
          end
        end
        
        -- Keep Bright: Force colored unless desaturation is allowed
        local kbCfg = GetEffectiveIconSettingsForFrame(pf)
        if kbCfg and kbCfg.keepBright and not kbCfg.keepBrightAllowDesat then
          pf._arcLastDesatHookAction = "KEEP_BRIGHT→0"
          pf._arcBypassDesatHook = true
          if self.SetDesaturation then
            self:SetDesaturation(0)
          else
            self:SetDesaturated(false)
          end
          pf._arcBypassDesatHook = false
          return
        end
        
        -- noDesaturate: Block all desaturation unconditionally.
        -- Defensive guard — catches any timing gap where _arcForceDesatValue
        -- was cleared (READY state, no-spell fallback, early-exit paths) but
        -- CDM still fires SetDesaturated before CooldownState re-confirms.
        if kbCfg then
          local sv = pf._arcCachedStateVisuals
          if sv and sv.noDesaturate then
            pf._arcLastDesatHookAction = "NO_DESAT_SV→0"
            pf._arcBypassDesatHook = true
            if self.SetDesaturation then
              self:SetDesaturation(0)
            else
              self:SetDesaturated(false)
            end
            pf._arcBypassDesatHook = false
            return
          end
        end
        
        -- SpellUsability desat override: if usability system requested desat,
        -- enforce it regardless of what CDM is trying to set.
        if pf._arcUsabilityDesatRequest then
          pf._arcLastDesatHookAction = "USAB_DESAT→1"
          pf._arcBypassDesatHook = true
          if self.SetDesaturation then
            self:SetDesaturation(1)
          else
            self:SetDesaturated(true)
          end
          pf._arcBypassDesatHook = false
          return
        end
        
        -- Fallback: If we have a forced desaturation value, enforce it
        local forceValue = pf._arcForceDesatValue
        if forceValue ~= nil and self.SetDesaturation then
          -- Staleness check: if we're forcing colored (0) from recharge phase but
          -- the shadow cooldown now says ALL charges depleted, our force value is
          -- stale (shadow hasn't been re-fed yet). Clear it and let CDM through.
          -- EXCEPTION: IAO frames always own desat entirely — HandleIgnoreAuraOverride
          -- intentionally sets forceDesat=0 for DEPLETED (isRecharging=true in depleted),
          -- so the staleness check incorrectly clears it.
          if forceValue == 0 and not pf._arcIgnoreAuraOverride
             and pf._arcCDMShadowCooldown and pf._arcCDMShadowCooldown:IsShown() then
            pf._arcForceDesatValue = nil
            pf._arcLastDesatHookAction = "FORCE_STALE_CLEAR"
            -- Let CDM's native desat go through unmodified
          else
            pf._arcLastDesatHookAction = "FORCE→" .. tostring(forceValue)
            pf._arcBypassDesatHook = true
            self:SetDesaturation(forceValue)
            pf._arcBypassDesatHook = false
          end
          return
        end
        -- No interception — CDM's call went through unmodified
        pf._arcLastDesatHookAction = "PASSTHROUGH"
        -- Don't sync border here - desaturated param may be secret
      end))
      
      -- Hook SetDesaturation (numeric version) to enforce our state
      -- NOTE: We can't sync border here because CDM may pass secret values
      if frame.Icon.SetDesaturation then
        hooksecurefunc(frame.Icon, "SetDesaturation", _T("CDMHook.SetDesaturation", function(self, value)
          local pf = self._arcParentFrame
          if not pf then return end
          if pf._arcBypassDesatHook then pf._arcLastDesatHookAction = "BYPASS" return end

          -- DURATION OVERRIDE owns desaturation entirely while active (highest
          -- priority — see the SetDesaturated hook above).
          if pf._arcDurOvActive then
            local v = pf._arcForceDesatValue or 0
            pf._arcLastDesatHookAction = "DUROV→" .. tostring(v)
            pf._arcBypassDesatHook = true
            self:SetDesaturation(v)
            pf._arcBypassDesatHook = false
            return
          end

          -- 12.1 ITEM (trinket) frames: enforce desat from the REAL item cooldown, ignoring
          -- CDM's GCD-driven flicker (see the SetDesaturated hook above for the full why).
          local eqSlot = pf.cooldownInfo and pf.cooldownInfo.equipSlot
          if eqSlot then
            local _, idur = GetInventoryItemCooldown("player", eqSlot)
            local onItemCD = (idur and idur > 1.5) and true or false
            pf._arcLastDesatHookAction = "ITEM→" .. (onItemCD and "1" or "0")
            pf._arcBypassDesatHook = true
            self:SetDesaturation(onItemCD and 1 or 0)
            pf._arcBypassDesatHook = false
            return
          end

          -- FAST PATH: same as SetDesaturated hook
          if not pf._arcUsabilityDesatRequest and pf._arcForceDesatValue == nil then
            if pf._arcCfgCdID == pf.cooldownID and pf._arcCfgVersion == effectiveSettingsCacheVersion
               and not pf._arcCachedNeedDesatIntercept then
              pf._arcLastDesatHookAction = "PASSTHROUGH"
              return
            end
          end
          
          -- Keep Bright: Force colored unless desaturation is allowed
          local kbCfg = GetEffectiveIconSettingsForFrame(pf)
          if kbCfg and kbCfg.keepBright and not kbCfg.keepBrightAllowDesat then
            pf._arcLastDesatHookAction = "KEEP_BRIGHT→0"
            pf._arcBypassDesatHook = true
            self:SetDesaturation(0)
            pf._arcBypassDesatHook = false
            return
          end
          
          -- noDesaturate: Block all desaturation unconditionally.
          -- Defensive guard — catches any timing gap where _arcForceDesatValue
          -- was cleared (READY state, no-spell fallback, early-exit paths) but
          -- CDM still fires SetDesaturation before CooldownState re-confirms.
          if kbCfg then
            local sv = pf._arcCachedStateVisuals
            if sv and sv.noDesaturate then
              pf._arcLastDesatHookAction = "NO_DESAT_SV→0"
              pf._arcBypassDesatHook = true
              self:SetDesaturation(0)
              pf._arcBypassDesatHook = false
              return
            end
          end
          
          -- SpellUsability desat override: if usability system requested desat,
          -- enforce it regardless of what CDM is trying to set.
          if pf._arcUsabilityDesatRequest then
            pf._arcLastDesatHookAction = "USAB_DESAT→1"
            pf._arcBypassDesatHook = true
            self:SetDesaturation(1)
            pf._arcBypassDesatHook = false
            return
          end
          
          -- Fallback: If we have a forced desaturation value, enforce it
          local forceValue = pf._arcForceDesatValue
          if forceValue ~= nil then
            -- Staleness check: skip for IAO frames — they own desat entirely.
            if forceValue == 0 and not pf._arcIgnoreAuraOverride
               and pf._arcCDMShadowCooldown and pf._arcCDMShadowCooldown:IsShown() then
              pf._arcForceDesatValue = nil
              pf._arcLastDesatHookAction = "FORCE_STALE_CLEAR"
              -- Let CDM's native desat go through unmodified
            else
              pf._arcLastDesatHookAction = "FORCE→" .. tostring(forceValue)
              pf._arcBypassDesatHook = true
              self:SetDesaturation(forceValue)
              pf._arcBypassDesatHook = false
            end
            return
          end
          -- No interception — CDM's call went through unmodified
          pf._arcLastDesatHookAction = "PASSTHROUGH"
          -- Don't sync border here - value param may be secret
        end))
      end
      
    -- (SetVertexColor hook removed — RefreshIconColor hook in CDMSpellUsability
    --  now handles all color writes in a single pass after CDM runs.
    --  No more hook fighting at 76/s.)
    end
    
    -- Hook SetCooldown to reapply our settings after CDM updates
    if not frame.Cooldown._arcHooked then
      frame.Cooldown._arcHooked = true
      frame.Cooldown._arcParentFrame = frame
      frame.Cooldown._arcCdID = cdID
      
      hooksecurefunc(frame.Cooldown, "SetCooldown", function(self)
        local parentFrame = self._arcParentFrame
        local currentCdID = self._arcCdID
        if not parentFrame or not currentCdID then return end
        local padX = self._arcPaddingX or 0
        local padY = self._arcPaddingY or 0
        if padX > 0 or padY > 0 then
          self:ClearAllPoints()
          self:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", padX, -padY)
          self:SetPoint("BOTTOMRIGHT", parentFrame, "BOTTOMRIGHT", -padX, padY)
        end

        -- CACHED BOOLEANS: keepCDMStyle and masqueControlsCooldowns are stable
        -- between settings changes. Recompute only when effectiveSettingsCacheVersion
        -- changes (spec swap, user changes settings). Cuts ~64/s live API lookups to ~0.
        if self._arcCooldownCacheVersion ~= effectiveSettingsCacheVersion then
          local sd2 = Shared and Shared.GetCurrentSpecData and Shared.GetCurrentSpecData()
          self._arcCachedKeepCDMStyle             = sd2 and sd2.keepCDMStyle == true
          self._arcCachedMasqueControlsCooldowns  = ns.Masque
              and ns.Masque.ShouldMasqueControlCooldowns
              and ns.Masque.ShouldMasqueControlCooldowns() == true
          self._arcCooldownCacheVersion = effectiveSettingsCacheVersion
        end
        local keepCDMStyle_hook        = self._arcCachedKeepCDMStyle
        local masqueControlsCooldowns  = self._arcCachedMasqueControlsCooldowns

        -- Reapply texcoord range to match icon crop — skip when keepCDMStyle on
        if not keepCDMStyle_hook then
          if parentFrame._arcTexCoords and self.SetTexCoordRange then
            local tc = parentFrame._arcTexCoords
            local lowVec = CreateVector2D(tc.left, tc.top)
            local highVec = CreateVector2D(tc.right, tc.bottom)
            self:SetTexCoordRange(lowVec, highVec)
          end
        end
        -- Masque's Hook_SetSwipeColor has issues with secret values in combat,
        -- so we apply Masque's desired color using our method
        -- We set _Swipe_Hook to bypass Masque's hook entirely (prevents visual glitches)
        
        if masqueControlsCooldowns then
          local masqueColor = self._MSQ_Color
          if masqueColor then
            local r = masqueColor.r or masqueColor[1] or 0
            local g = masqueColor.g or masqueColor[2] or 0
            local b = masqueColor.b or masqueColor[3] or 0
            local a = masqueColor.a or masqueColor[4] or 0.8
            
            -- Set Masque's reentrancy guard to bypass their hook
            self._Swipe_Hook = true
            self:SetSwipeColor(r, g, b, a)
            self._Swipe_Hook = nil
          end
          
          -- Reset reverse to false (CDM template has reverse="true" by default)
          -- This ensures normal cooldown animation direction when Masque controls
          self:SetReverse(false)
          
          -- Check if noGCDSwipe or ignoreAuraOverride is enabled - if so, we still need to handle it
          -- even when Masque controls other cooldown visuals
          if not parentFrame._arcNoGCDSwipeEnabled and not parentFrame._arcIgnoreAuraOverride then
            return  -- Let Masque handle everything else
          end
          -- Fall through to handle noGCDSwipe / ignoreAuraOverride below
        end
        
        -- Skip if this is our own override call
        if parentFrame._arcBypassCDHook then return end
        
        -- PREVIEW MODE: CDM tried to update, but we're previewing - REAPPLY preview settings
        -- hooksecurefunc runs AFTER original, so CDM's values are already set - we must override them
        if parentFrame._arcSwipePreviewActive then
          local now = GetTime()
          parentFrame._arcBypassCDHook = true
          self:SetCooldown(now, 30)
          parentFrame._arcBypassCDHook = false
          -- Ensure visibility
          self:SetAlpha(1)
          self:Show()
          return
        end
        
        local currentCfg = GetIconSettings(currentCdID)
        if not currentCfg then return end

        -- Resolve ignoreAuraOverride BEFORE the cooldownSwipe nil-guard so that
        -- frames with ignoreAuraOverride in auraActiveState (and no cooldownSwipe
        -- table at all) still reach the IAO durationObj push block.
        local ignoreAuraOverride = parentFrame._arcIgnoreAuraOverride
          or (currentCfg.cooldownSwipe and currentCfg.cooldownSwipe.ignoreAuraOverride)
          or (currentCfg.auraActiveState and currentCfg.auraActiveState.ignoreAuraOverride)

        -- For non-IAO paths, still need cooldownSwipe table
        local swipe = currentCfg.cooldownSwipe
        if not ignoreAuraOverride and not swipe then return end

        -- Handle Ignore Aura Override - we take FULL control of swipe/edge
        if ignoreAuraOverride then
          -- ═══════════════════════════════════════════════════════════════════
          -- IGNORE AURA OVERRIDE MODE
          -- durationObj push now lives in CooldownState.HandleIgnoreAuraOverride,
          -- fired via OnAuraInstanceInfoSet → CooldownState.Apply. API-agnostic,
          -- works before and after the 12.0.1 hotfix.
          -- This hook handles: texture override, bling, reverse, swipe color.
          -- ═══════════════════════════════════════════════════════════════════

          -- Set texture to spell icon (not aura icon)
          local cooldownInfo = parentFrame.cooldownInfo
          local spellID = cooldownInfo and (cooldownInfo.overrideSpellID or cooldownInfo.spellID)
          if spellID and parentFrame.Icon then
            local texture = C_Spell.GetSpellTexture(spellID)
            if texture then
              parentFrame._arcBypassTextureHook = true
              parentFrame.Icon:SetTexture(texture)
              parentFrame._arcBypassTextureHook = false
            end
          end
          
          -- Apply bling/reverse/color based on who controls cooldowns
          if not masqueControlsCooldowns then
            -- ArcUI controls: Apply all user settings
            self:SetDrawBling(not swipe or swipe.showBling ~= false)
            local isAuraNowActive = (parentFrame._arcAuraActive == true) or (parentFrame.totemData ~= nil)
            self:SetReverse((swipe and swipe.reverse == true or false) or (isAuraNowActive and swipe and swipe.reverseWhileAura == true))

            -- Set swipe color: auraSwipeColor when aura is active, swipeColor otherwise, else black
            local colorToUse = swipe and swipe.swipeColor
            if isAuraNowActive and swipe and swipe.auraSwipeColor then
              colorToUse = swipe.auraSwipeColor
            end
            if colorToUse then
              self:SetSwipeColor(colorToUse.r or 0, colorToUse.g or 0, colorToUse.b or 0, colorToUse.a or 0.7)
            else
              -- Default: black swipe (overrides CDM's yellowish aura default)
              self:SetSwipeColor(0, 0, 0, 0.7)
            end
          else
            -- Masque controls: Only reset reverse to false (CDM template has reverse="true")
            -- Don't touch bling or color - let Masque handle those
            self:SetReverse(false)
          end
        elseif parentFrame._arcNoGCDSwipeEnabled then
          -- ═══════════════════════════════════════════════════════════════════
          -- NO GCD SWIPE MODE (without IAO)
          -- Charge spell duration push and GCD suppression handled by
          -- ArcUI_GCDFilter.lua — do NOT duplicate here.
          -- Only apply swipe color.
          -- ═══════════════════════════════════════════════════════════════════
          if not masqueControlsCooldowns and swipe.swipeColor then
            local sc = swipe.swipeColor
            self:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
          end
        else
          -- ═══════════════════════════════════════════════════════════════════
          -- NORMAL MODE: No IAO or noGCDSwipe
          -- Swipe/edge enforced by enforcing hooks (user settings or CooldownState).
          -- Just apply bling/reverse/color.
          -- ═══════════════════════════════════════════════════════════════════
          self:SetDrawBling(swipe.showBling ~= false)
          local isAuraNowActive = (parentFrame._arcAuraActive == true) or (parentFrame.totemData ~= nil)
          self:SetReverse((swipe.reverse == true) or (isAuraNowActive and swipe.reverseWhileAura == true))

          -- Apply swipe color: auraSwipeColor when aura is active, else swipeColor
          if isAuraNowActive and swipe.auraSwipeColor then
            local sc = swipe.auraSwipeColor
            self:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.7)
          elseif swipe.swipeColor then
            local sc = swipe.swipeColor
            self:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
          end
        end
      end)
    else
      -- Update references in case cdID changed
      frame.Cooldown._arcCdID = cdID
    end
  end
  
  -- Border (pass zoom to properly inset border to match visible icon area)
  UpdateIconBorder(frame, cdID, nil, nil, padding, zoom)
  
  -- Opacity - SKIP for Arc Auras frames (they manage their own alpha via OnArcAurasUpdate)
  -- Also SKIP when CooldownState manages alpha (stateVisuals configured) to prevent
  -- a brief alpha=1.0 flash before CooldownState applies the correct value.
  if not frame._arcAuraID and not frame._arcConfig then
    local stateVisuals = GetEffectiveStateVisuals(cfg)
    if not stateVisuals then
      local targetAlpha = cfg.alpha or 1.0
      if targetAlpha <= 0 and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
        targetAlpha = 0.35
      end
      frame:SetAlpha(targetAlpha)
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- SHADOW / CDM NATIVE STYLE (IconOverlay)
  -- CDM XML hardcodes the overlay at TOPLEFT -9,8 / BOTTOMRIGHT 9,-8.
  -- Just reapply those fixed offsets — no ratio math needed.
  -- Shadow and mask are both controlled exclusively by keepCDMStyle.
  -- ═══════════════════════════════════════════════════════════════════
  local keepCDMStyle = false
  do
    local specData = Shared and Shared.GetCurrentSpecData and Shared.GetCurrentSpecData()
    if specData and specData.keepCDMStyle then keepCDMStyle = true end
  end
  local shouldHideShadow = not keepCDMStyle

  -- Find the IconOverlay texture once per frame lifetime
  if not frame._arcIconOverlayScanned then
    frame._arcIconOverlayScanned = true
    -- First: look for CDM's native atlas texture in child regions
    local regions = {frame:GetRegions()}
    for _, region in ipairs(regions) do
      if region:IsObjectType("Texture") then
        local atlas = region:GetAtlas()
        if atlas and atlas:find("IconOverlay") then
          frame._arcIconOverlay = region
          break
        end
      end
    end
    -- Fallback: ArcAuras custom frames have frame.IconOverlay (plain texture).
    -- Upgrade it to the CDM atlas so it looks identical.
    if not frame._arcIconOverlay and frame.IconOverlay then
      frame._arcIconOverlay = frame.IconOverlay
      frame._arcIconOverlay:SetAtlas("UI-HUD-CoolDownManager-IconOverlay", false)
      frame._arcIconOverlay:SetVertexColor(1, 1, 1, 1)
    end
  end

  if frame._arcIconOverlay then
    -- Also hide shadow if frame is hidden by dynamic layout (alpha=0 but IsShown=true)
    local frameHidden = not frame:IsShown() or frame:GetAlpha() == 0
    if shouldHideShadow or frameHidden then
      frame._arcIconOverlay:SetAlpha(0)
      frame._arcIconOverlay:Hide()
    else
      frame._arcIconOverlay:Show()
      frame._arcIconOverlay:SetAlpha(1)
      local iconTex = frame.Icon or frame.icon
      local anchor = iconTex or frame
      -- Shadow extend = 18% W / 16% H (from CDM XML: 9px on 50px Essential icon)
      -- This ratio applies correctly to all viewer types and all scales.
      local shadowSize = cfg.shadowSize or 1.0
      local curW = frame:GetWidth()
      local curH = frame:GetHeight()
      local ox = curW * 0.18 * shadowSize
      local oy = curH * 0.16 * shadowSize
      frame._arcIconOverlay:ClearAllPoints()
      frame._arcIconOverlay:SetPoint("TOPLEFT",     anchor, "TOPLEFT",     -ox,  oy)
      frame._arcIconOverlay:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT",  ox, -oy)
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- RANGE INDICATOR - Simple enable/disable
  -- COOLDOWN FRAMES ONLY: Aura frames don't have range/usability logic
  -- When disabled: replicate CDM's RefreshIconColor logic minus range.
  -- CDM's priority: outOfRange → usable → notEnoughMana → notUsable.
  -- We skip the range branch and apply the rest, then hide OOR overlay.
  -- When enabled: let CDM handle everything (don't interfere)
  -- ═══════════════════════════════════════════════════════════════════
  if frame.Icon and not cfg._isAura then
    local rangeCfg = cfg.rangeIndicator
    if rangeCfg then
      -- Store config on the FRAME
      frame._arcRangeCfg = rangeCfg
      
      -- Hook RefreshIconColor — fires AFTER CDM sets red tint + shows OOR
      if not frame._arcRefreshIconColorHooked and frame.RefreshIconColor then
        frame._arcRefreshIconColorHooked = true
        
        hooksecurefunc(frame, "RefreshIconColor", function(self)
          local rCfg = self._arcRangeCfg
          if not rCfg or rCfg.enabled ~= false then return end
          
          -- Hide the OOR shadow overlay
          if self.GetOutOfRangeTexture then
            self:GetOutOfRangeTexture():Hide()
          end
          
          -- Replicate CDM's RefreshIconColor color priority, skipping range:
          -- usable → ITEM_USABLE_COLOR
          -- notEnoughMana → ITEM_NOT_ENOUGH_MANA_COLOR
          -- notUsable → ITEM_NOT_USABLE_COLOR
          -- NOTE: GetSpellID() can return TAINTED values in PvP combat,
          -- which taints IsSpellUsable returns. Use cached non-secret sources.
          local spellID = self._arcCachedSpellID
                       or (self.cooldownInfo and (self.cooldownInfo.overrideSpellID or self.cooldownInfo.spellID))
                       or self._arcSpellID
          if spellID and self.GetIconTexture then
            local iconTexture = self:GetIconTexture()
            local isUsable, notEnoughMana = C_Spell.IsSpellUsable(spellID)
            if isUsable then
              iconTexture:SetVertexColor(CooldownViewerConstants.ITEM_USABLE_COLOR:GetRGBA())
            elseif notEnoughMana then
              iconTexture:SetVertexColor(CooldownViewerConstants.ITEM_NOT_ENOUGH_MANA_COLOR:GetRGBA())
            else
              iconTexture:SetVertexColor(CooldownViewerConstants.ITEM_NOT_USABLE_COLOR:GetRGBA())
            end
          end
        end)
      end
      
      -- Hook OutOfRange:Show to immediately hide when disabled
      if frame.OutOfRange and not frame.OutOfRange._arcHooked then
        frame.OutOfRange._arcHooked = true
        frame.OutOfRange._arcParent = frame
        
        hooksecurefunc(frame.OutOfRange, "Show", function(self)
          local parent = self._arcParent
          if not parent then return end
          local rCfg = parent._arcRangeCfg
          if rCfg and rCfg.enabled == false then
            self:SetShown(false)
          end
        end)
      end
      
      -- Range indicator handling complete. Cooldown frames use RefreshIconColor
      -- hook above. Aura frames (buffs/debuffs) don't have range indicators.
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- SPELL USABILITY HOOK - Install RefreshIconColor hook for custom
  -- usability tinting (blue=no mana, gray=not usable) and glow overlay.
  -- COOLDOWN FRAMES ONLY: Aura frames don't have usability state.
  -- Module installs its own hooksecurefunc, separate from range indicator.
  -- ═══════════════════════════════════════════════════════════════════
  if frame.Icon and not cfg._isAura and ns.CDMSpellUsability and ns.CDMSpellUsability.HookFrame then
    ns.CDMSpellUsability.HookFrame(frame)
    -- CRITICAL: CDM already called RefreshIconColor during frame creation
    -- BEFORE our hook existed. Apply initial usability tint now so the
    -- user doesn't have to toggle the option off/on to get correct colors.
    ns.CDMSpellUsability.OnRefreshIconColor(frame)
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- PROC GLOW CUSTOMIZATION (CDM RECOLOR APPROACH)
  -- Instead of fighting CDM's glow with our own, we just recolor it.
  -- We listen to SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE events
  -- and call SetVertexColor on CDM's SpellActivationAlert textures.
  -- NOTE: glowCfg is NOT cached on frame - always get fresh via GetEffectiveIconSettingsForFrame
  -- ═══════════════════════════════════════════════════════════════════
  local glowCfg = cfg.procGlow
  if glowCfg then
    -- Store spellID for reference (this is stable, not a config reference)
    local spellID = nil
    if frame.cooldownInfo then
      spellID = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
    end
    if not spellID and frame.GetSpellID then
      spellID = NonSecretSpellID(frame:GetSpellID())
    end
    frame._arcSpellID = spellID
    
    -- PRE-WARM: Initialize proc glow frame ahead of time to prevent first-show glitch
    -- "default" remaps to "proc" internally, so pre-warm it too
    local pgt = glowCfg.glowType or "proc"
    if glowCfg.enabled ~= false and (pgt == "proc" or pgt == "default") then
      if ns.CDMEnhance.PreWarmProcGlow then
        ns.CDMEnhance.PreWarmProcGlow(frame, glowCfg)
      end
    end
    
    -- ═══════════════════════════════════════════════════════════════
    -- REFRESH: Check if proc is currently active (for reload/spec change)
    -- ═══════════════════════════════════════════════════════════════
    if spellID and glowCfg.enabled ~= false then
      local isOverlayed = false
        isOverlayed = C_SpellActivationOverlay and SafeIsSpellOverlayed(spellID)
      
      if isOverlayed then
        -- Proc is active - apply our color to CDM's glow
        ns.CDMEnhance.ShowProcGlow(frame, glowCfg)
      end
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- TEXT OVERLAY FRAME (sits above cooldown swipe AND glow frames)
  -- Level hierarchy: base(+0) → glowOverlay/Cooldown(+1, glows sit here) → textOverlay(+2) → charges(+3) → drag(+4)
  -- Glows land at iconLevel+1 (GLOW_LEVEL_OFFSET=1), text clears them with +2.
  -- Cross-group same-strata minimum gap: set foreground group level ≥ background+3.
  -- ═══════════════════════════════════════════════════════════════════
  if not frame._arcTextOverlay then
    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:SetFrameLevel(frame:GetFrameLevel() + 2)
    overlay:EnableMouse(false)  -- CRITICAL: Never intercept mouse - just a container
    frame._arcTextOverlay = overlay
  else
    -- Ensure existing overlay stays above glow frames (frame level may have changed)
    frame._arcTextOverlay:SetFrameLevel(frame:GetFrameLevel() + 2)
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- CHARGE TEXT
  -- ═══════════════════════════════════════════════════════════════════
  SetupChargeText(frame, cdID, cfg)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- COOLDOWN TEXT STYLING
  -- ═══════════════════════════════════════════════════════════════════
  SetupCooldownText(frame, cdID, cfg)

  -- ═══════════════════════════════════════════════════════════════════
  -- FORCE HIDE: apply now that all text overlays exist. Hiding drops the frame
  -- to alpha 0 (the alpha hook keeps it there over the state writers) and floats
  -- the duration + stack text. Showing restores the text and lets the state
  -- system re-apply the real alpha.
  -- ═══════════════════════════════════════════════════════════════════
  if frame._arcForceHideActive then
    frame:SetAlpha(0)  -- alpha hook forces/holds 0 while _arcForceHideActive
    ApplyForceHideText(frame, true)
  elseif frame._arcWasForceHidden then
    -- Just turned the icon back on: un-float the text and restore visibility.
    ApplyForceHideText(frame, false)
    frame._arcBypassFrameAlphaHook = true
    frame:SetAlpha(frame._lastAppliedAlpha or 1)
    frame._arcBypassFrameAlphaHook = false
  end
  frame._arcWasForceHidden = nil

  -- ═══════════════════════════════════════════════════════════════════
  -- PREVIEW TEXT (for editing when no active aura/cooldown)
  -- ═══════════════════════════════════════════════════════════════════
  UpdatePreviewText(frame, cdID, cfg)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- PREVIEW GLOW (for editing glow settings)
  -- ═══════════════════════════════════════════════════════════════════
  UpdatePreviewGlow(frame, cdID, cfg)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- ALERT EVENTS HOOK (for custom actions on CDM events)
  -- ═══════════════════════════════════════════════════════════════════
  if not frame._arcAlertHooked and frame.TriggerAlertEvent then
    frame._arcAlertHooked = true
    frame._arcAlertCdID = cdID
    
    hooksecurefunc(frame, "TriggerAlertEvent", function(self, event)
      local currentCdID = self._arcAlertCdID
      if not currentCdID then return end
      
      local currentCfg = GetIconSettings(currentCdID)
      if not currentCfg then return end
      
      local alertCfg = currentCfg.alertEvents
      local iconTex = self.Icon or self.icon
      -- LibCustomGlow: NEGATIVE offset moves glow INWARD
      local glowOffset = -(currentCfg.padding or 0)
      
      -- Enum.CooldownViewerAlertEventType values:
      -- Available = 1, PandemicTime = 2, OnCooldown = 3, ChargeGained = 4
      local eventType = event
      
      if eventType == 1 then -- Available (Aura applied / Cooldown ready)
        local ev = alertCfg and alertCfg.onAvailable
        if ev then
          -- Play sound
          if ev.playSound then
            PlayAlertSound(ev.soundFile, ev.soundID)
          end
          -- Show glow
          if ev.showGlow and ns.Glows then
            local color = ev.glowColor and {ev.glowColor.r, ev.glowColor.g, ev.glowColor.b, 1} or {0.95, 0.95, 0.32, 1}
            ns.Glows.Start(self, "ArcUI_Alert", "pixel", {color = color, lines = 8, frequency = 0.25, thickness = 2, xOffset = glowOffset, yOffset = glowOffset})
          end
        end
        -- glowFollowPandemic: aura reapplied = pandemic window is over, clear glow
        local panCfg1 = GetEffectiveIconSettingsForFrame(self)
        local aas1 = panCfg1 and panCfg1.auraActiveState
        local sv1  = panCfg1 and GetEffectiveStateVisuals(panCfg1)
        if aas1 and aas1.glow == true and aas1.glowFollowPandemic == true then
          self._arcPandemicGlowActive = nil
          HideAuraActiveGlow(self)
        elseif sv1 and sv1.readyGlow and sv1.glowFollowPandemic then
          self._arcPandemicGlowActive = nil
          if ns.CDMEnhance.HideReadyGlow then ns.CDMEnhance.HideReadyGlow(self) end
        end
        -- NOTE: Inactive state (desaturation/hide/dim) is handled by CDMGroups via ApplyIconVisuals
        -- Do NOT duplicate that logic here - it causes conflicts when settings change
        
      elseif eventType == 2 then -- PandemicTime (Aura at 30% remaining)
        local ev = alertCfg and alertCfg.onPandemic
        if ev then
          -- Play sound
          if ev.playSound then
            PlayAlertSound(ev.soundFile, ev.soundID)
          end
          -- Show glow (warning color)
          if ev.showGlow and ns.Glows then
            local color = ev.glowColor and {ev.glowColor.r, ev.glowColor.g, ev.glowColor.b, 1} or {1, 0.5, 0, 1}
            ns.Glows.Start(self, "ArcUI_Alert", "pixel", {color = color, lines = 8, frequency = 0.15, thickness = 2, xOffset = glowOffset, yOffset = glowOffset})
          end
        end
        -- glowFollowPandemic: CDM fires eventType 2 at exact pandemic entry — use it directly
        local panCfg = GetEffectiveIconSettingsForFrame(self)
        local aas = panCfg and panCfg.auraActiveState
        local sv  = panCfg and GetEffectiveStateVisuals(panCfg)
        if aas and aas.glow == true and aas.glowFollowPandemic == true then
          -- Respect glowCombatOnly: only show if not restricted to combat, or currently in combat
          local passedCombat = not aas.glowCombatOnly or InCombatLockdown() or UnitAffectingCombat("player")
          if passedCombat then
            self._arcPandemicGlowActive = true
            HideAuraActiveGlow(self)
            ShowAuraActiveGlow(self, aas)
          end
        elseif sv and sv.readyGlow and sv.glowFollowPandemic then
          -- Respect readyGlowCombatOnly: only show if not restricted to combat, or currently in combat
          local passedCombat = not sv.readyGlowCombatOnly or InCombatLockdown() or UnitAffectingCombat("player")
          if passedCombat then
            self._arcPandemicGlowActive = true
            if ns.CDMEnhance.HideReadyGlow then ns.CDMEnhance.HideReadyGlow(self) end
            if ns.CDMEnhance.ShowReadyGlow then ns.CDMEnhance.ShowReadyGlow(self, sv) end
          end
        end
        
      elseif eventType == 3 then -- OnCooldown (Aura expired / Cooldown used)
        local ev = alertCfg and alertCfg.onUnavailable
        if ev then
          -- Play sound
          if ev.playSound then
            PlayAlertSound(ev.soundFile, ev.soundID)
          end
          -- Stop glow
          if ev.stopGlow and ns.Glows then
            ns.Glows.Stop(self, "ArcUI_Alert")
          end
        end
        -- glowFollowPandemic: aura expired, clear pandemic glow
        local panCfg3 = GetEffectiveIconSettingsForFrame(self)
        local aas3 = panCfg3 and panCfg3.auraActiveState
        local sv3  = panCfg3 and GetEffectiveStateVisuals(panCfg3)
        if aas3 and aas3.glow == true and aas3.glowFollowPandemic == true then
          self._arcPandemicGlowActive = nil
          HideAuraActiveGlow(self)
        elseif sv3 and sv3.readyGlow and sv3.glowFollowPandemic then
          self._arcPandemicGlowActive = nil
          if ns.CDMEnhance.HideReadyGlow then ns.CDMEnhance.HideReadyGlow(self) end
        end
        -- NOTE: Inactive state (desaturation/hide/dim) is handled by CDMGroups via ApplyIconVisuals
        -- Do NOT duplicate that logic here - it causes conflicts when settings change
        
      elseif eventType == 5 then -- OnAuraApplied (aura reapplied — pandemic window reset)
        -- glowFollowPandemic: reapplication means aura is full duration, CDM hides pandemic — we must too
        local panCfg5 = GetEffectiveIconSettingsForFrame(self)
        local aas5 = panCfg5 and panCfg5.auraActiveState
        local sv5  = panCfg5 and GetEffectiveStateVisuals(panCfg5)
        if aas5 and aas5.glow == true and aas5.glowFollowPandemic == true then
          self._arcPandemicGlowActive = nil
          HideAuraActiveGlow(self)
        elseif sv5 and sv5.readyGlow and sv5.glowFollowPandemic then
          self._arcPandemicGlowActive = nil
          if ns.CDMEnhance.HideReadyGlow then ns.CDMEnhance.HideReadyGlow(self) end
        end

      elseif eventType == 4 then -- ChargeGained
        local ev = alertCfg and alertCfg.onChargeGained
        if ev then
          -- Play sound
          if ev.playSound then
            PlayAlertSound(ev.soundFile, ev.soundID)
          end
          -- Show glow
          if ev.showGlow and ns.Glows then
            local color = ev.glowColor and {ev.glowColor.r, ev.glowColor.g, ev.glowColor.b, 1} or {0.95, 0.95, 0.32, 1}
            ns.Glows.Start(self, "ArcUI_Alert", "pixel", {color = color, lines = 8, frequency = 0.25, thickness = 2, xOffset = glowOffset, yOffset = glowOffset})
            -- Auto-stop after 1 second
            C_Timer.After(1, function()
              if ns.Glows then
                ns.Glows.Stop(self, "ArcUI_Alert")
              end
            end)
          end
        end
      end
    end)
  else
    -- Update stored cdID in case it changed
    frame._arcAlertCdID = cdID
  end
  
  -- Apply custom label text overlay (separate module)
  if ns.CustomLabel and ns.CustomLabel.Apply then
    ns.CustomLabel.Apply(frame, cfg)
  end
  
  -- Mark frame as styled (used by glow hooks to know when styling is complete)
  frame._arcStyled = true
  
  -- If glow was waiting for styling, refresh it now
  if frame._arcPendingGlowRefresh then
    frame._arcPendingGlowRefresh = nil
    -- Use cfg.procGlow (already fresh from GetEffectiveIconSettingsForFrame)
    local gCfg = cfg.procGlow
    local spellID = frame._arcSpellID
    
    if gCfg and spellID and gCfg.enabled ~= false then
      -- Check current proc state
      local isOverlayed = false
        isOverlayed = C_SpellActivationOverlay and SafeIsSpellOverlayed(spellID)
      
      if isOverlayed then
        ns.CDMEnhance.ShowProcGlow(frame, gCfg)
        -- Hide Blizzard's glow for LCG types
        if gCfg.glowType and gCfg.glowType ~= "default" and frame.SpellActivationAlert then
          frame.SpellActivationAlert:SetAlpha(0)
        end
      end
    end
  end
end

-- ===================================================================
-- CHARGE TEXT SETUP (Stack count for Auras, Charge count for Cooldowns)
-- ===================================================================
function SetupChargeText(frame, cdID, cfg)
  local chargeCfg = cfg.chargeText

  -- AURA FRAMES:
  -- showSingleStack OFF: reposition native Applications, CDM controls visibility (hides at <=1)
  -- showSingleStack ON:  suppress native Applications, use our mirror (also shows "1")
  if frame.Applications then
    local appFrame = frame.Applications
    -- Threshold-colored stack bands take over the stack display the same way the
    -- single-stack mirror does: suppress native Applications, render our own.
    local bandsOn = chargeCfg and chargeCfg.enabled ~= false and chargeCfg.thresholdColorEnabled
                  and ns.StackColor and ns.StackColor.HasEnabledBands(chargeCfg)
    if (chargeCfg and chargeCfg.showSingleStack) or bandsOn then
      -- Suppress native Applications so only our mirror/bands show
      appFrame:Hide()
      appFrame:SetAlpha(0)
      if not appFrame._arcSingleStackSuppressHooked then
        appFrame._arcSingleStackSuppressHooked = true
        appFrame._arcParentIconFrame = frame
        hooksecurefunc(appFrame, "Show", function(self)
          local pf = self._arcParentIconFrame
          if not pf then return end
          local cdID2 = pf.cooldownID
          local cfg2 = cdID2 and ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(cdID2)
          if cfg2 and cfg2.chargeText and (cfg2.chargeText.showSingleStack or (cfg2.chargeText.enabled ~= false and cfg2.chargeText.thresholdColorEnabled)) then
            self:Hide()
            self:SetAlpha(0)
          end
        end)
      end
      -- Mirror fontstring: show our own count instead
      if not frame._arcSingleStackText then
        local container = CreateFrame("Frame", nil, frame)
        container:SetAllPoints(frame)
        frame._arcSingleStackContainer = container
        local fs = container:CreateFontString(nil, "OVERLAY", nil, 7)
        fs:SetDrawLayer("OVERLAY", 7)
        frame._arcSingleStackText = fs
      end
      frame._arcSingleStackContainer:SetFrameLevel(frame:GetFrameLevel() + 3)
      frame._arcSingleStackContainer:Show()  -- ensure container is visible (may have been hidden by toggle-off)
      local fs = frame._arcSingleStackText
      local fontPath = GetFontPath(chargeCfg.font)
      SafeSetFont(fs, fontPath, chargeCfg.size or 16, chargeCfg.outline or "OUTLINE")
      local c = chargeCfg.color or {r=1, g=1, b=0, a=1}
      fs:SetTextColor(c.r or 1, c.g or 1, c.b or 0, c.a or 1)
      if chargeCfg.shadow then
        fs:SetShadowOffset(chargeCfg.shadowOffsetX or 1, chargeCfg.shadowOffsetY or -1)
        fs:SetShadowColor(0, 0, 0, 0.8)
      else
        fs:SetShadowOffset(0, 0)
      end
      fs:ClearAllPoints()
      if chargeCfg.mode == "free" then
        fs:SetPoint("CENTER", frame, "CENTER", chargeCfg.freeX or 0, chargeCfg.freeY or 0)
      else
        local anchor = chargeCfg.anchor or "BOTTOMRIGHT"
        fs:SetPoint(anchor, frame, anchor, chargeCfg.offsetX or -2, chargeCfg.offsetY or 2)
      end
      local function UpdateSingleStackText(f)
        if not f._arcSingleStackText then return end
        local auraID = f.auraInstanceID
        local HasAuraInstanceID2 = ns.API and ns.API.HasAuraInstanceID
        local present = HasAuraInstanceID2 and HasAuraInstanceID2(auraID)
        -- Re-read live cfg so a mode flip is honored on the next aura event.
        -- (Cached merge -> cheap; this only fires on aura set/refresh events.)
        local liveCfg = ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(f.cooldownID)
        local cc = liveCfg and liveCfg.chargeText
        local bandsActive = cc and cc.enabled ~= false and cc.thresholdColorEnabled
                          and ns.StackColor and ns.StackColor.HasEnabledBands(cc)
        if bandsActive then
          -- Colored bands own the display; keep the single mirror empty.
          f._arcSingleStackShowing = false
          f._arcSingleStackText:SetText("")
          ns.StackColor.UpdateBands(f)
          return
        end
        if not present then
          f._arcSingleStackShowing = false
          f._arcSingleStackText:SetText("")
          if ns.StackColor then ns.StackColor.UpdateBands(f) end
          return
        end
        local unit = f.auraDataUnit or "player"
        local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraID)
        if auraData and auraData.applications then
          f._arcSingleStackText:SetText(auraData.applications)
        else
          f._arcSingleStackText:SetText("1")
        end
        f._arcSingleStackShowing = true
        if ns.StackColor then ns.StackColor.UpdateBands(f) end
      end
      if not frame._arcSingleStackAuraHooked then
        frame._arcSingleStackAuraHooked = true

        local function ShouldUpdateStack(self)
          local cdID2 = self.cooldownID
          local cfg2 = cdID2 and ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(cdID2)
          return cfg2 and cfg2.chargeText and (cfg2.chargeText.showSingleStack or (cfg2.chargeText.enabled ~= false and cfg2.chargeText.thresholdColorEnabled))
        end

        -- OnAuraInstanceInfoSet: canonical CDM hook, fires on aura set (~4x/session)
        if frame.OnAuraInstanceInfoSet then
          hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
            if ShouldUpdateStack(self) then
              UpdateSingleStackText(self)
            end
          end)
        end

        -- OnUnitAuraUpdatedEvent: fires on STACK REFRESH (same instID, applications changes)
        -- This is the critical missing hook — without it stacks go stale on refresh
        if frame.OnUnitAuraUpdatedEvent then
          hooksecurefunc(frame, "OnUnitAuraUpdatedEvent", function(self)
            if ShouldUpdateStack(self) then
              UpdateSingleStackText(self)
            end
          end)
        end

        -- OnUnitAuraAddedEvent: fires when a new aura instance is added
        if frame.OnUnitAuraAddedEvent then
          hooksecurefunc(frame, "OnUnitAuraAddedEvent", function(self)
            if ShouldUpdateStack(self) then
              UpdateSingleStackText(self)
            end
          end)
        end

        -- ClearAuraInstanceInfo: fires when aura falls off
        if frame.ClearAuraInstanceInfo then
          hooksecurefunc(frame, "ClearAuraInstanceInfo", function(self)
            if self._arcSingleStackText then
              self._arcSingleStackShowing = false
              self._arcSingleStackText:SetText("")
            end
            if ns.StackColor then ns.StackColor.UpdateBands(self) end
          end)
        end

        -- OnAuraInstanceInfoCleared: canonical CDM clear hook
        if frame.OnAuraInstanceInfoCleared then
          hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
            if self._arcSingleStackText then
              self._arcSingleStackShowing = false
              self._arcSingleStackText:SetText("")
            end
            if ns.StackColor then ns.StackColor.UpdateBands(self) end
          end)
        end

        -- OnCooldownIDSet: fires after every SetCooldownID (including repool).
        -- CDM calls FindLinkedSpellForCurrentAuras + RefreshData here, so by the
        -- time our hook fires the frame may already have auraInstanceID set from
        -- an existing active aura — update text so it doesn't stay blank after repool.
        if frame.OnCooldownIDSet then
          hooksecurefunc(frame, "OnCooldownIDSet", function(self)
            if ShouldUpdateStack(self) then
              -- Defer one frame so CDM's aura linking in OnCooldownIDSet completes first
              C_Timer.After(0, function()
                if ShouldUpdateStack(self) then
                  UpdateSingleStackText(self)
                end
              end)
            end
          end)
        end
      end
      -- Render colored bands when enabled; otherwise the single mirror.
      if bandsOn then
        ns.StackColor.ApplyBands(frame, chargeCfg)
        fs:SetText("")
        fs:Hide()
      else
        if ns.StackColor then ns.StackColor.ClearBands(frame) end
        fs:Show()
      end
      UpdateSingleStackText(frame)
    else
      -- showSingleStack OFF and bands OFF: hide mirror/bands, restore Applications alpha,
      -- then reposition the native Applications text using chargeText anchor settings
      if ns.StackColor then ns.StackColor.ClearBands(frame) end
      if frame._arcSingleStackContainer then
        frame._arcSingleStackContainer:Hide()
        frame._arcSingleStackText:SetText("")
        frame._arcSingleStackShowing = false
      end
      if chargeCfg and chargeCfg.enabled ~= false then
        appFrame:SetAlpha(1)
        local appText = appFrame.Applications
        if appText then
          local fontPath = GetFontPath(chargeCfg.font)
          SafeSetFont(appText, fontPath, chargeCfg.size or 16, chargeCfg.outline or "OUTLINE")
          local c = chargeCfg.color or {r=1, g=1, b=1, a=1}
          appText:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
          if chargeCfg.shadow then
            appText:SetShadowOffset(chargeCfg.shadowOffsetX or 1, chargeCfg.shadowOffsetY or -1)
            appText:SetShadowColor(0, 0, 0, 0.8)
          else
            appText:SetShadowOffset(0, 0)
          end
          appText:ClearAllPoints()
          if chargeCfg.mode == "free" then
            appText:SetPoint("CENTER", frame, "CENTER", chargeCfg.freeX or 0, chargeCfg.freeY or 0)
          else
            local anchor = chargeCfg.anchor or "BOTTOMRIGHT"
            appText:SetPoint(anchor, frame, anchor, chargeCfg.offsetX or -2, chargeCfg.offsetY or 2)
          end
        end
      else
        -- chargeText disabled: hide Applications frame via alpha (zero CPU).
        -- Hook SetAlpha once so CDM can't restore it.
        appFrame:SetAlpha(0)
        if not appFrame._arcStackHideHooked then
          appFrame._arcStackHideHooked = true
          hooksecurefunc(appFrame, "SetAlpha", function(self, a)
            local pf = self._arcParentIconFrame
            if not pf then return end
            local cdID2 = pf.cooldownID
            local cfg2 = cdID2 and ns.CDMEnhance and ns.CDMEnhance.GetIconSettings and ns.CDMEnhance.GetIconSettings(cdID2)
            local cc2 = cfg2 and cfg2.chargeText
            if not cc2 or cc2.enabled == false then
              if a ~= 0 then self:SetAlpha(0) end
            end
          end)
          appFrame._arcParentIconFrame = frame
        end
      end
    end
    return
  end

  -- Find the native charge/stack text
  -- Cooldowns use ChargeCount.Current, Auras use Applications.Applications
  local chargeFrame = frame.ChargeCount or frame.Applications
  local chargeText = nil
  
  if chargeFrame then
    -- Try to find the text element
    -- CDM Cooldowns: ChargeCount.Current
    -- CDM Auras: Applications.Applications
    if chargeFrame.Current then
      chargeText = chargeFrame.Current
    elseif chargeFrame.Applications then
      chargeText = chargeFrame.Applications
    elseif chargeFrame.Text then
      chargeText = chargeFrame.Text
    else
      -- Search regions for FontString
      for _, region in ipairs({chargeFrame:GetRegions()}) do
        if region:IsObjectType("FontString") then
          chargeText = region
          break
        end
      end
    end
    
    -- Cache the reference
    if chargeText then
      frame._arcChargeText = chargeText
      -- Mark this text so cooldown text doesn't accidentally style it
      chargeText._arcIsChargeText = true
    end
  end
  
  -- Use cached reference if we couldn't find it this time
  if not chargeText and frame._arcChargeText then
    chargeText = frame._arcChargeText
  end
  
  if not chargeCfg or chargeCfg.enabled == false then
    -- Hide charge/stack text entirely by hiding the parent frame AND the text directly
    if chargeFrame then
      chargeFrame:Hide()
      chargeFrame:SetAlpha(0)
      
      -- Also hide the text element directly
      if chargeText then
        chargeText:Hide()
        chargeText:SetAlpha(0)
      end
      
      -- Detect if this is an aura frame (Applications) vs cooldown frame (ChargeCount)
      local isAuraFrame = frame.Applications ~= nil
      
      -- Check if spell has charges using CACHED CDM info (safe during combat)
      -- The CDM API info.charges is a boolean that indicates if this cooldown tracks charges
      -- This is already cached in cdmIconCache by ArcUI_Core.lua during scan
      local spellHasCharges = false
      if not isAuraFrame then
        local cdmData = ns.API and ns.API.GetCDMIcon and ns.API.GetCDMIcon(cdID)
        if cdmData then
          -- CDM API info.charges is a boolean indicating if cooldown has charges
          spellHasCharges = cdmData.charges == true
        end
      end
      
      -- CRITICAL FIX: Hook Show() and SetShown() to enforce hidden state
      -- CDM will try to show this frame when updating stack count - we must fight back
      if not chargeFrame._arcChargeHideHooked then
        chargeFrame._arcChargeHideHooked = true
        chargeFrame._arcParentIconFrame = frame
        chargeFrame._arcCdID = cdID
        chargeFrame._arcIsAuraFrame = isAuraFrame
        chargeFrame._arcSpellHasCharges = spellHasCharges  -- From CDM cached info
        chargeFrame._arcChargeText = chargeText  -- Store reference for hooks
        
        -- Helper to fully hide charge text
        local function EnforceChargeHidden(cFrame)
          cFrame:Hide()
          cFrame:SetAlpha(0)
          local cText = cFrame._arcChargeText
          if cText then
            cText:Hide()
            cText:SetAlpha(0)
          end
        end
        
        -- Hook Show()
        hooksecurefunc(chargeFrame, "Show", _T("CDMHook.ChargeFrame.Show", function(self)
          -- For COOLDOWNS: Skip for non-charge spells - let CDM control
          -- For AURAS: Always enforce hiding (they show application stacks)
          -- Use cached _arcSpellHasCharges (checked once at setup, not during combat)
          if not self._arcIsAuraFrame and not self._arcSpellHasCharges then
            return  -- Non-charge cooldown, let CDM control
          end
          
          -- Re-check settings (user may have re-enabled)
          local currentCdID = self._arcCdID
          if not currentCdID then return end
          
          local currentCfg = GetIconSettings(currentCdID)
          if currentCfg and currentCfg.chargeText and currentCfg.chargeText.enabled == false then
            EnforceChargeHidden(self)
          end
        end))
        
        -- Hook SetShown() if it exists
        if chargeFrame.SetShown then
          hooksecurefunc(chargeFrame, "SetShown", _T("CDMHook.ChargeFrame.SetShown", function(self, shown)
            -- Skip if shown is a secret value (can't do boolean test)
            if issecretvalue and issecretvalue(shown) then return end
            
            -- For COOLDOWNS: Skip for non-charge spells - let CDM control
            -- For AURAS: Always enforce hiding
            -- Use cached _arcSpellHasCharges (checked once at setup, not during combat)
            if not self._arcIsAuraFrame and not self._arcSpellHasCharges then
              return  -- Non-charge cooldown, let CDM control
            end
            
            -- Safe to check shown now
            if not shown then return end
            
            local currentCdID = self._arcCdID
            if not currentCdID then return end
            
            local currentCfg = GetIconSettings(currentCdID)
            if currentCfg and currentCfg.chargeText and currentCfg.chargeText.enabled == false then
              EnforceChargeHidden(self)
            end
          end))
        end
        
        -- Hook SetAlpha() - prevent CDM from making text visible even for one frame
        if chargeFrame.SetAlpha then
          hooksecurefunc(chargeFrame, "SetAlpha", function(self, alpha)
            if issecretvalue and issecretvalue(alpha) then return end
            
            -- For COOLDOWNS: Skip for non-charge spells - let CDM control
            -- For AURAS: Always enforce hiding
            -- Use cached _arcSpellHasCharges (checked once at setup, not during combat)
            if not self._arcIsAuraFrame and not self._arcSpellHasCharges then
              return  -- Non-charge cooldown, let CDM control
            end
            
            local currentCdID = self._arcCdID
            if not currentCdID then return end
            
            local currentCfg = GetIconSettings(currentCdID)
            if currentCfg and currentCfg.chargeText and currentCfg.chargeText.enabled == false then
              -- If CDM tries to set alpha > 0, push it back to 0
              if alpha and alpha > 0 then
                EnforceChargeHidden(self)
              end
            -- hideAtZero: CooldownState set this flag when charges = 0
            elseif self._arcParentIconFrame and self._arcParentIconFrame._arcHideChargeAtZero then
              if alpha and alpha > 0 then
                local cText = self._arcChargeText
                if cText then cText:SetAlpha(0) end
              end
            end
          end)
        end
      else
        -- Update cdID reference for existing hook
        chargeFrame._arcCdID = cdID
        -- CRITICAL: Update _arcIsAuraFrame on frame reuse! Frame may have been reused
        -- from cooldown to aura or vice versa. Check current frame state.
        local currentIsAura = frame.Applications ~= nil
        chargeFrame._arcIsAuraFrame = currentIsAura
        -- Also update hasCharges cache in case frame is reused for different spell
        -- Use CDM cached info which is safe during combat
        if not currentIsAura then
          local cdmData = ns.API and ns.API.GetCDMIcon and ns.API.GetCDMIcon(cdID)
          if cdmData then
            chargeFrame._arcSpellHasCharges = cdmData.charges == true
          end
        else
          chargeFrame._arcSpellHasCharges = false  -- Auras don't have charges
        end
      end
    end
    -- NOTE: showSingleStack mirror for aura frames is handled above via early-return.
    -- Aura frames never reach this point.
    return
  end
  
  -- ENABLED PATH: User wants charge text visible
  -- We need to re-show frames that we previously hid
  if chargeFrame then
    chargeFrame:SetAlpha(1)
    
    -- Update cdID reference if hook exists (for frame reuse scenarios)
    if chargeFrame._arcChargeHideHooked then
      chargeFrame._arcCdID = cdID
      -- CRITICAL: Update _arcIsAuraFrame on frame reuse! Frame may have been reused
      -- from cooldown to aura or vice versa. Check current frame state.
      local currentIsAura = frame.Applications ~= nil
      chargeFrame._arcIsAuraFrame = currentIsAura
      -- Mark that user wants charge text enabled - hooks will respect this
      chargeFrame._arcChargeUserEnabled = true
      
      -- Determine if we should call Show()
      -- For AURAS: Always safe to show - CDM will control visibility based on stacks
      -- For COOLDOWNS: Only show if spell has charges (CDM hides ChargeCount for non-charge spells)
      local shouldShow = false
      if currentIsAura then
        shouldShow = true
        chargeFrame._arcSpellHasCharges = false  -- Auras don't have charges
      else
        -- Use CDM cached info to check if spell has charges
        local cdmData = ns.API and ns.API.GetCDMIcon and ns.API.GetCDMIcon(cdID)
        if cdmData and cdmData.charges then
          shouldShow = true
          chargeFrame._arcSpellHasCharges = true  -- Update cache
        end
      end
      
      if shouldShow then
        chargeFrame:Show()
        if chargeText then
          chargeText:SetAlpha(1)
          chargeText:Show()
        end
      else
        -- Non-charge cooldown - just restore alpha, let CDM keep it hidden
        if chargeText then
          chargeText:SetAlpha(1)
        end
      end
    end
    -- If no hook exists, don't modify anything - let CDM control visibility
  end
  
  if chargeText then
    -- Style the native charge text directly
    local fontPath = GetFontPath(chargeCfg.font)
    local fontSize = chargeCfg.size or 16
    local outline = chargeCfg.outline or "OUTLINE"
    SafeSetFont(chargeText, fontPath, fontSize, outline)
    
    -- CRITICAL: Set draw layer to OVERLAY with highest sublevel to appear above glows
    chargeText:SetDrawLayer("OVERLAY", 7)
    
    -- Also ensure parent frame (ChargeCount/Applications) is above glow frames
    local chargeFrame = frame.ChargeCount or frame.Applications
    if chargeFrame and chargeFrame.SetFrameLevel then
      local baseLevel = frame:GetFrameLevel()
      chargeFrame:SetFrameLevel(baseLevel + 3)
    end
    
    -- Color
    local c = chargeCfg.color or {r=1, g=1, b=0, a=1}
    chargeText:SetTextColor(c.r or 1, c.g or 1, c.b or 0, c.a or 1)
    
    -- Shadow
    if chargeCfg.shadow then
      chargeText:SetShadowOffset(chargeCfg.shadowOffsetX or 1, chargeCfg.shadowOffsetY or -1)
      chargeText:SetShadowColor(0, 0, 0, 0.8)
    else
      chargeText:SetShadowOffset(0, 0)
    end
    
    -- Position - reposition the text relative to our frame
    chargeText:ClearAllPoints()
    
    if chargeCfg.mode == "free" then
      local freeX = chargeCfg.freeX or 0
      local freeY = chargeCfg.freeY or 0
      chargeText:SetPoint("CENTER", frame, "CENTER", freeX, freeY)
    else
      local anchor = chargeCfg.anchor or chargeCfg.position or "BOTTOMRIGHT"
      local offX = chargeCfg.offsetX or -2
      local offY = chargeCfg.offsetY or 2
      chargeText:SetPoint(anchor, frame, anchor, offX, offY)
    end
    
    -- Do NOT call Show() - let CDM control visibility (hides at 0/1 stacks)
  end
end

-- ===================================================================
-- COOLDOWN TEXT SETUP (Duration countdown for Auras, CD countdown for Cooldowns)
-- ===================================================================
function SetupCooldownText(frame, cdID, cfg)
  local cdTextCfg = cfg.cooldownText
  if not cdTextCfg then return end
  
  local cooldownFrame = frame.Cooldown or frame.cooldown
  if not cooldownFrame then return end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- HELPER: Find all cooldown text fontstrings
  -- ═══════════════════════════════════════════════════════════════════
  local function FindCooldownTexts()
    local texts = {}
    
    -- Check cooldown frame regions (most common location)
    for _, region in ipairs({cooldownFrame:GetRegions()}) do
      if region:IsObjectType("FontString") and not region._arcIsChargeText then
        table.insert(texts, region)
      end
    end
    
    -- Check cooldown frame children
    for _, child in ipairs({cooldownFrame:GetChildren()}) do
      for _, region in ipairs({child:GetRegions()}) do
        if region:IsObjectType("FontString") and not region._arcIsChargeText then
          table.insert(texts, region)
        end
      end
    end
    
    return texts
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- HELPER: Setup hide hooks on a fontstring (one-time)
  -- ═══════════════════════════════════════════════════════════════════
  local function SetupHideHooks(cdText)
    if not cdText or cdText._arcCdTextHooked then return end
    
    cdText._arcCdTextHooked = true
    cdText._arcParentIconFrame = frame
    cdText._arcCdID = cdID
    
    -- Helper to fully hide the text
    local function EnforceHidden(self)
      self:Hide()
      self:SetAlpha(0)
    end
    
    -- Hook Show()
    hooksecurefunc(cdText, "Show", _T("CDMHook.cdText.Show", function(self)
      local currentCdID = self._arcCdID
      if not currentCdID then return end
      
      local currentCfg = GetIconSettings(currentCdID)
      if currentCfg and currentCfg.cooldownText and currentCfg.cooldownText.enabled == false then
        EnforceHidden(self)
      end
    end))
    
    -- Hook SetShown()
    if cdText.SetShown then
      hooksecurefunc(cdText, "SetShown", _T("CDMHook.cdText.SetShown", function(self, shown)
        if issecretvalue and issecretvalue(shown) then return end
        if not shown then return end
        
        local currentCdID = self._arcCdID
        if not currentCdID then return end
        
        local currentCfg = GetIconSettings(currentCdID)
        if currentCfg and currentCfg.cooldownText and currentCfg.cooldownText.enabled == false then
          EnforceHidden(self)
        end
      end))
    end
    
    -- Hook SetAlpha() - prevent CDM from making text visible even for one frame
    if cdText.SetAlpha then
      hooksecurefunc(cdText, "SetAlpha", _T("CDMHook.cdText.SetAlpha", function(self, alpha)
        if issecretvalue and issecretvalue(alpha) then return end
        
        local currentCdID = self._arcCdID
        if not currentCdID then return end
        
        local currentCfg = GetIconSettings(currentCdID)
        if currentCfg and currentCfg.cooldownText and currentCfg.cooldownText.enabled == false then
          -- If CDM tries to set alpha > 0, push it back to 0
          if alpha and alpha > 0 then
            self:SetAlpha(0)
          end
        end
      end))
    end
    
    -- Hook SetText() - text updates may trigger visibility changes
    if cdText.SetText then
      hooksecurefunc(cdText, "SetText", _T("CDMHook.cdText.SetText", function(self)
        local currentCdID = self._arcCdID
        if not currentCdID then return end
        
        local currentCfg = GetIconSettings(currentCdID)
        if currentCfg and currentCfg.cooldownText and currentCfg.cooldownText.enabled == false then
          EnforceHidden(self)
        end
      end))
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- HELPER: Style a cooldown text fontstring
  -- ═══════════════════════════════════════════════════════════════════
  local function StyleCooldownText(cdText, textCfg, parentIconFrame)
    if not cdText then return end
    if cdText._arcIsChargeText then return end
    
    -- Skip alpha reset if duration-based coloring is driving alpha via SetAlpha
    local iconFrame = parentIconFrame or cdText._arcParentIconFrame
    if not (iconFrame and iconFrame._arcDurationColorActive) then
      cdText:SetAlpha(1)
    end
    cdText:Show()  -- CRITICAL: Also call Show() since we call Hide() when disabling
    
    local fontPath = GetFontPath(textCfg.font)
    local fontSize = textCfg.size or 14
    local outline = textCfg.outline or "OUTLINE"
    SafeSetFont(cdText, fontPath, fontSize, outline)
    
    cdText:SetDrawLayer("OVERLAY", 7)
    
    -- Skip static color if duration-based coloring is active (CDMTextColor module)
    if not (iconFrame and iconFrame._arcDurationColorActive) then
      local c = textCfg.color or {r=1, g=1, b=1, a=1}
      cdText:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
    end
    
    if textCfg.shadow then
      cdText:SetShadowOffset(textCfg.shadowOffsetX or 1, textCfg.shadowOffsetY or -1)
      cdText:SetShadowColor(0, 0, 0, 0.8)
    else
      cdText:SetShadowOffset(0, 0)
    end
    
    cdText:ClearAllPoints()
    if textCfg.mode == "free" then
      local freeX = textCfg.freeX or 0
      local freeY = textCfg.freeY or 0
      cdText:SetPoint("CENTER", frame, "CENTER", freeX, freeY)
    else
      local anchor = textCfg.anchor or "CENTER"
      local offX = textCfg.offsetX or 0
      local offY = textCfg.offsetY or 0
      cdText:SetPoint(anchor, frame, anchor, offX, offY)
    end
    
    cdText._arcIsCooldownText = true
    frame._arcCooldownText = cdText
    
    -- Update cdID reference
    if cdText._arcCdTextHooked then
      cdText._arcCdID = cdID
    end
    
    -- 3.6.6: Apply user-configured duration-text options via Blizzard's native
    -- Cooldown API. Engine-rendered — zero per-frame CPU cost. Includes decimal
    -- precision below a threshold, abbreviation form (M:SS), minimum-duration
    -- suppression (hide GCD countdowns), and swipe-only mode.
    if ns.CooldownFormatter and ns.CooldownFormatter.Apply and frame.Cooldown then
      ns.CooldownFormatter.Apply(frame.Cooldown, textCfg)
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- APPLY: Handle disabled state
  -- ═══════════════════════════════════════════════════════════════════
  if cdTextCfg.enabled == false then
    -- Belt: Blizzard API
    cooldownFrame:SetHideCountdownNumbers(true)
    
    -- Suspenders: Find, hide, and hook all countdown fontstrings
    local texts = FindCooldownTexts()
    for _, cdText in ipairs(texts) do
      cdText:Hide()
      cdText:SetAlpha(0)
      SetupHideHooks(cdText)
      cdText._arcCdID = cdID
      frame._arcCooldownText = cdText
      cdText._arcIsCooldownText = true
    end
    
    -- Also handle cached reference
    if frame._arcCooldownText then
      frame._arcCooldownText:Hide()
      frame._arcCooldownText:SetAlpha(0)
      SetupHideHooks(frame._arcCooldownText)
      frame._arcCooldownText._arcCdID = cdID
    end
  else
    -- ═══════════════════════════════════════════════════════════════════
    -- APPLY: Handle enabled state
    -- ═══════════════════════════════════════════════════════════════════
    cooldownFrame:SetHideCountdownNumbers(false)
    
    -- Style existing texts
    if frame._arcCooldownText and frame._arcCooldownText:GetParent() then
      StyleCooldownText(frame._arcCooldownText, cdTextCfg, frame)
    end
    
    for _, cdText in ipairs(FindCooldownTexts()) do
      StyleCooldownText(cdText, cdTextCfg, frame)
      SetupHideHooks(cdText)  -- Setup hooks even when enabled (for dynamic toggling)
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- HOOK: SetCooldown to handle dynamically created text (one-time)
  -- ═══════════════════════════════════════════════════════════════════
  if not cooldownFrame._arcCdTextHooked then
    cooldownFrame._arcCdTextHooked = true
    cooldownFrame._arcParentFrame = frame
    cooldownFrame._arcCdID = cdID
    
    hooksecurefunc(cooldownFrame, "SetCooldown", function(self)
      local parentFrame = self._arcParentFrame
      local currentCdID = self._arcCdID
      if not parentFrame or not currentCdID then return end
      
      local currentCfg = GetIconSettings(currentCdID)
      if not currentCfg or not currentCfg.cooldownText then return end
      
      if currentCfg.cooldownText.enabled == false then
        -- DISABLED: Re-enforce hide
        self:SetHideCountdownNumbers(true)
        
        for _, region in ipairs({self:GetRegions()}) do
          if region:IsObjectType("FontString") and not region._arcIsChargeText then
            region:Hide()
            region:SetAlpha(0)
            SetupHideHooks(region)
            region._arcCdID = currentCdID
          end
        end
        for _, child in ipairs({self:GetChildren()}) do
          for _, region in ipairs({child:GetRegions()}) do
            if region:IsObjectType("FontString") and not region._arcIsChargeText then
              region:Hide()
              region:SetAlpha(0)
              SetupHideHooks(region)
              region._arcCdID = currentCdID
            end
          end
        end
      elseif parentFrame._arcHideCDTextForCharges then
        -- CHARGE-CONDITIONAL HIDE: hideWhenHasCharges active, suppress countdown
        self:SetHideCountdownNumbers(true)
        if parentFrame._arcCooldownText then
          parentFrame._arcCooldownText:SetAlpha(0)
        end
      else
        -- ENABLED: Style text
        -- Preemptively mark duration color active to prevent StyleCooldownText
        -- stomping with static white before the 0.1s ticker fires (flicker fix)
        if currentCfg.cooldownText.durationColor then
          parentFrame._arcDurationColorActive = true
        end
        for _, region in ipairs({self:GetRegions()}) do
          if region:IsObjectType("FontString") and not region._arcIsChargeText then
            StyleCooldownText(region, currentCfg.cooldownText, parentFrame)
            SetupHideHooks(region)
          end
        end
        for _, child in ipairs({self:GetChildren()}) do
          for _, region in ipairs({child:GetRegions()}) do
            if region:IsObjectType("FontString") and not region._arcIsChargeText then
              StyleCooldownText(region, currentCfg.cooldownText, parentFrame)
              SetupHideHooks(region)
            end
          end
        end
      end
    end)
  else
    -- Update cdID reference for existing hook
    cooldownFrame._arcCdID = cdID
  end
end

-- Export ApplyIconStyle for FrameController to call on frame swaps
-- This applies per-icon visual settings (borders, textures, zoom, etc.) without protection checks
ns.CDMEnhance.ApplyIconStyle = ApplyIconStyle

-- NOTE: Text updates not needed - we style native CDM elements directly
-- The native ChargeCount and Cooldown countdown handle their own display

-- ===================================================================
-- TEXT DRAG OVERLAYS
-- ===================================================================
local function CreateTextDragOverlay(fontString, frame, cdID, textType)
  if fontString._arcDragOverlay then 
    fontString._arcDragOverlay._cdID = cdID
    return fontString._arcDragOverlay 
  end
  
  -- Parent to a high-level frame that sits ABOVE the icon drag overlay
  local overlay = CreateFrame("Frame", nil, frame._arcTextOverlay)
  overlay:SetSize(50, 24)
  overlay:SetPoint("CENTER", fontString, "CENTER", 0, 0)
  -- Set frame level HIGHER than icon drag overlay (which is +4)
  overlay:SetFrameLevel(frame:GetFrameLevel() + 100)
  overlay:SetFrameStrata("DIALOG")
  overlay:EnableMouse(false)
  overlay:RegisterForDrag("LeftButton")
  overlay._cdID = cdID
  overlay._textType = textType
  overlay._fontString = fontString
  overlay._parentFrame = frame
  
  overlay.highlight = overlay:CreateTexture(nil, "OVERLAY")
  overlay.highlight:SetAllPoints()
  overlay.highlight:SetColorTexture(0.9, 0.7, 0.2, 0.5)
  overlay.highlight:Hide()
  
  overlay:SetScript("OnEnter", function(self)
    -- Propagate to grandparent (CDM icon frame) for tooltips
    local parentFrame = self:GetParent()
    if parentFrame then
      local grandparent = parentFrame:GetParent()
      if grandparent and grandparent:GetScript("OnEnter") then
        grandparent:GetScript("OnEnter")(grandparent)
      end
    end
    
    if not textDragMode then return end
    self.highlight:Show()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(textType == "charge" and "Charge Text" or "Cooldown Text", 1, 1, 1)
    GameTooltip:AddLine("Drag to reposition", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Shift+Click to reset", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  
  overlay:SetScript("OnLeave", function(self)
    self.highlight:Hide()
    GameTooltip:Hide()
    
    -- Propagate to grandparent (CDM icon frame) for tooltips
    local parentFrame = self:GetParent()
    if parentFrame then
      local grandparent = parentFrame:GetParent()
      if grandparent and grandparent:GetScript("OnLeave") then
        grandparent:GetScript("OnLeave")(grandparent)
      end
    end
  end)
  
  overlay:SetScript("OnDragStart", function(self)
    if not textDragMode then return end
    self._dragging = true
    
    -- Calculate offset between cursor and text center (so text doesn't jump)
    local scale = UIParent:GetEffectiveScale()
    local cursorX, cursorY = GetCursorPosition()
    cursorX, cursorY = cursorX / scale, cursorY / scale
    
    local textX, textY = self._fontString:GetCenter()
    if textX and textY then
      self._dragOffsetX = textX - cursorX
      self._dragOffsetY = textY - cursorY
    else
      self._dragOffsetX = 0
      self._dragOffsetY = 0
    end
  end)
  
  overlay:SetScript("OnDragStop", function(self)
    if not self._dragging then return end
    self._dragging = false
    
    local currentCdID = self._cdID
    -- BUG FIX: Use GetOrCreateIconSettings to write to actual DB, not GetIconSettings (returns copy)
    local cfg = GetOrCreateIconSettings(currentCdID)
    if not cfg then return end
    
    local parentFrame = self._parentFrame
    local endX, endY = self._fontString:GetCenter()
    local frameX, frameY = parentFrame:GetCenter()
    
    if not endX or not endY or not frameX or not frameY then return end
    
    -- Calculate offset from frame center
    local offsetX = endX - frameX
    local offsetY = endY - frameY
    
    if self._textType == "charge" then
      cfg.chargeText.mode = "free"
      cfg.chargeText.freeX = offsetX
      cfg.chargeText.freeY = offsetY
    else
      cfg.cooldownText.mode = "free"
      cfg.cooldownText.freeX = offsetX
      cfg.cooldownText.freeY = offsetY
    end
    
    -- Invalidate cache to ensure changes are picked up
    InvalidateEffectiveSettingsCache()
    
    ApplyIconStyle(parentFrame, currentCdID)
    
    -- For Arc Auras frames, also force stack text refresh
    if parentFrame._arcConfig or parentFrame._arcAuraID then
      parentFrame._arcStackStyleApplied = false
      -- Immediately re-apply styling
      if ns.ArcAuras and ns.ArcAuras.ApplyStackTextStyle and parentFrame.Count then
        ns.ArcAuras.ApplyStackTextStyle(parentFrame, parentFrame.Count)
        parentFrame._arcStackStyleApplied = true
      end
    end
  end)
  
  overlay:SetScript("OnUpdate", function(self)
    if not self._dragging then 
      -- Keep overlay positioned on fontstring when not dragging
      if self._fontString then
          -- SetAlphaFromBoolean handles secret boolean from IsShown()
          self:SetAlphaFromBoolean(self._fontString:IsShown(), 1, 0)
          self:ClearAllPoints()
          self:SetPoint("CENTER", self._fontString, "CENTER", 0, 0)
      end
      return 
    end
    
    -- While dragging, position text at cursor + original offset
    local scale = UIParent:GetEffectiveScale()
    local cursorX, cursorY = GetCursorPosition()
    cursorX, cursorY = cursorX / scale, cursorY / scale
    
    -- Add the offset so text stays where you grabbed it
    local targetX = cursorX + (self._dragOffsetX or 0)
    local targetY = cursorY + (self._dragOffsetY or 0)
    
      self._fontString:ClearAllPoints()
      self._fontString:SetPoint("CENTER", UIParent, "BOTTOMLEFT", targetX, targetY)
      self:ClearAllPoints()
      self:SetPoint("CENTER", self._fontString, "CENTER", 0, 0)
  end)
  
  overlay:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and IsShiftKeyDown() and textDragMode then
      local currentCdID = self._cdID
      -- BUG FIX: Use GetOrCreateIconSettings to write to actual DB
      local cfg = GetOrCreateIconSettings(currentCdID)
      local parentFrame = self._parentFrame
      if cfg then
        if self._textType == "charge" then
          cfg.chargeText.mode = "anchor"
          cfg.chargeText.freeX = 0
          cfg.chargeText.freeY = 0
        else
          cfg.cooldownText.mode = "anchor"
          cfg.cooldownText.freeX = 0
          cfg.cooldownText.freeY = 0
        end
        
        -- Invalidate cache to ensure changes are picked up
        InvalidateEffectiveSettingsCache()
        
        ApplyIconStyle(parentFrame, currentCdID)
        
        -- For Arc Auras frames, also force stack text refresh
        if parentFrame._arcConfig or parentFrame._arcAuraID then
          parentFrame._arcStackStyleApplied = false
          -- Immediately re-apply styling
          if ns.ArcAuras and ns.ArcAuras.ApplyStackTextStyle and parentFrame.Count then
            ns.ArcAuras.ApplyStackTextStyle(parentFrame, parentFrame.Count)
            parentFrame._arcStackStyleApplied = true
          end
        end
      end
    end
  end)
  
  fontString._arcDragOverlay = overlay
  -- Start hidden — OnUpdate only fires when shown, saving CPU.
  -- SetTextDragMode → UpdateTextDragOverlays will Show() when needed.
  overlay:Hide()
  if textDragMode then overlay:Show() end
  return overlay
end

local function UpdateTextDragOverlays(frame)
  -- Check if click-through is enabled
  local clickThroughEnabled = ns.CDMGroups and ns.CDMGroups.ShouldMakeClickThrough and ns.CDMGroups.ShouldMakeClickThrough()
  
  -- Check if frame is CDMGroups managed (container or free icon)
  local parent = frame:GetParent()
  local isCDMGroupsManaged = (parent and parent._isCDMGContainer)
  if not isCDMGroupsManaged and ns.CDMGroups and ns.CDMGroups.freeIcons then
    local cdID = frame.cooldownID
    if cdID and ns.CDMGroups.freeIcons[cdID] then
      isCDMGroupsManaged = true
    end
  end
  
  -- CRITICAL: Ensure _arcTextOverlay never blocks mouse
  if frame._arcTextOverlay then
    frame._arcTextOverlay:EnableMouse(false)
  end
  
  if frame._arcChargeText and frame._arcChargeText._arcDragOverlay then
    local overlay = frame._arcChargeText._arcDragOverlay
    -- Disable if click-through is enabled
    if clickThroughEnabled then
      overlay:EnableMouse(false)
      overlay:Hide()
    elseif textDragMode then
      overlay:EnableMouse(true)
      overlay:Show()
    else
      overlay:EnableMouse(false)
      overlay:Hide()
    end
    -- Ensure high frame level when text drag is active
    if textDragMode and not clickThroughEnabled then
      overlay:SetFrameStrata("DIALOG")
      overlay:SetFrameLevel(frame:GetFrameLevel() + 100)
    else
      overlay.highlight:Hide()
    end
  end
  
  -- Arc Auras Count text drag overlay
  if frame.Count and frame.Count._arcDragOverlay and (frame._arcConfig or frame._arcAuraID) then
    local overlay = frame.Count._arcDragOverlay
    -- Disable if click-through is enabled
    if clickThroughEnabled then
      overlay:EnableMouse(false)
      overlay:Hide()
    elseif textDragMode then
      overlay:EnableMouse(true)
      overlay:Show()
    else
      overlay:EnableMouse(false)
      overlay:Hide()
    end
    -- Ensure high frame level when text drag is active
    if textDragMode and not clickThroughEnabled then
      overlay:SetFrameStrata("DIALOG")
      overlay:SetFrameLevel(frame:GetFrameLevel() + 100)
    else
      overlay.highlight:Hide()
    end
  end
  
  if frame._arcCooldownText and frame._arcCooldownText._arcDragOverlay then
    local overlay = frame._arcCooldownText._arcDragOverlay
    -- Disable if click-through is enabled
    if clickThroughEnabled then
      overlay:EnableMouse(false)
      overlay:Hide()
    elseif textDragMode then
      overlay:EnableMouse(true)
      overlay:Show()
    else
      overlay:EnableMouse(false)
      overlay:Hide()
    end
    if textDragMode and not clickThroughEnabled then
      overlay:SetFrameStrata("DIALOG")
      overlay:SetFrameLevel(frame:GetFrameLevel() + 100)
    else
      overlay.highlight:Hide()
    end
  end
end

-- ===================================================================
-- ICON DRAG OVERLAY
-- ===================================================================
local function CreateDragOverlay(frame, cdID)
  if frame._arcOverlay then 
    frame._arcOverlay._cdID = cdID
    return 
  end
  
  local overlay = CreateFrame("Button", nil, frame)
  overlay:SetAllPoints()
  overlay:SetFrameLevel(frame:GetFrameLevel() + 4)
  overlay:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  -- Default to only unlocked state - options check happens via UpdateOverlayState
  overlay:EnableMouse(isUnlocked)
  overlay:SetMovable(true)
  if isUnlocked then
    overlay:RegisterForDrag("LeftButton")
  end
  overlay._cdID = cdID
  
  -- Green highlight on hover
  overlay.highlight = overlay:CreateTexture(nil, "OVERLAY")
  overlay.highlight:SetAllPoints()
  overlay.highlight:SetColorTexture(0.2, 0.9, 0.2, 0.4)
  overlay.highlight:Hide()
  
  -- "DRAG" text indicator when unlocked
  overlay.dragText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  overlay.dragText:SetPoint("CENTER", 0, 0)
  overlay.dragText:SetText("|cff00ff00DRAG|r")
  overlay.dragText:SetTextColor(0, 1, 0, 1)
  overlay.dragText:Hide()
  
  overlay:SetScript("OnEnter", function(self)
    -- Always propagate OnEnter to parent frame for tooltips
    local parentFrame = self:GetParent()
    if parentFrame and parentFrame:GetScript("OnEnter") then
      parentFrame:GetScript("OnEnter")(parentFrame)
    end
    
    if not isUnlocked then return end
    self.highlight:Show()
    
    local currentCdID = self._cdID
    local data = ns.API and ns.API.GetCDMIcon(currentCdID)
    local name = data and data.name or "Unknown"
    local cfg = GetIconSettings(currentCdID)
    local mode = cfg and cfg.position and cfg.position.mode or "group"
    
    local modeLabels = {
      group = "|cff888888Following Group|r",
      anchored = "|cff00ff00Anchored to Group|r",
      free = "|cffffcc00Free Position|r",
    }
    
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(name, 1, 1, 1)
    GameTooltip:AddLine("Position: " .. (modeLabels[mode] or mode), 1, 1, 1)
    if mode == "group" then
      GameTooltip:AddLine("Change position mode to enable dragging", 0.7, 0.7, 0.7)
    else
      GameTooltip:AddLine("Drag to reposition", 0.7, 0.7, 0.7)
      GameTooltip:AddLine("Shift+Click to reset to group", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
  end)
  
  overlay:SetScript("OnLeave", function(self)
    self.highlight:Hide()
    GameTooltip:Hide()
    
    -- Always propagate OnLeave to parent frame for tooltips
    local parentFrame = self:GetParent()
    if parentFrame and parentFrame:GetScript("OnLeave") then
      parentFrame:GetScript("OnLeave")(parentFrame)
    end
  end)
  
  -- OnMouseDown - CDMGroups handles all drag operations
  overlay:SetScript("OnMouseDown", function(self, button)
    -- CDMGroups handles all drag operations
    return
  end)
  
  overlay:SetScript("OnMouseUp", function(self, button)
    local currentCdID = self._cdID
    if not currentCdID then return end
    
    -- Left-click selection when options panel is open
    if button == "LeftButton" then
      local optionsPanelOpen = ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen()
      if optionsPanelOpen then
        local data = ns.API and ns.API.GetCDMIcon(currentCdID)
        if data then
          local isAura = data.isAura
          if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.SelectIcon then
            ns.CDMEnhanceOptions.SelectIcon(currentCdID, isAura)
          end
        end
      end
    end
  end)
  
  -- Keep OnDragStart/OnDragStop as no-ops
  overlay:SetScript("OnDragStart", function() end)
  overlay:SetScript("OnDragStop", function() end)
  overlay:SetScript("OnClick", function() end)
  
  frame._arcOverlay = overlay
end

-- Backwards compatibility stub
ns.CDMEnhance.DisableCDMSubframeMouse = function(frame) end

local function UpdateOverlayState(frame)
  if not frame then return end
  if frame._arcOverlay then
    -- Check if frame is in a CDMGroups container or is a free icon managed by CDMGroups
    local parent = frame:GetParent()
    local isCDMGroupsManaged = (parent and parent._isCDMGContainer)
    
    -- Also check if it's a CDMGroups free icon
    if not isCDMGroupsManaged and ns.CDMGroups and ns.CDMGroups.freeIcons then
      local cdID = frame.cooldownID
      if cdID and ns.CDMGroups.freeIcons[cdID] then
        isCDMGroupsManaged = true
      end
    end
    
    if isCDMGroupsManaged then
      -- CDMGroups manages ALL mouse for this frame - ALWAYS disable overlay
      frame._arcOverlay:EnableMouse(false)
      frame._arcOverlay:SetMovable(false)
      frame._arcOverlay:RegisterForDrag()
      
      if frame._arcOverlay.highlight then
        frame._arcOverlay.highlight:Hide()
      end
      if frame._arcOverlay.dragText then
        frame._arcOverlay.dragText:Hide()
      end
      UpdateTextDragOverlays(frame)
      return
    end
    
    -- Non-CDMGroups managed frames (legacy path)
    frame._arcOverlay:EnableMouse(true)
    frame._arcOverlay:SetMovable(true)
    
    if isUnlocked then
      frame._arcOverlay:RegisterForDrag("LeftButton")
    else
      frame._arcOverlay:RegisterForDrag()
    end
    frame._arcOverlay:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    
    if frame._arcOverlay.dragText then
      if isUnlocked then
        frame._arcOverlay.dragText:Show()
      else
        frame._arcOverlay.dragText:Hide()
      end
    end
    
    if not isUnlocked then
      frame._arcOverlay.highlight:Hide()
    end
  end
  
  UpdateTextDragOverlays(frame)
end

-- Export for FrameController - just updates overlay state
ns.CDMEnhance.ApplyFrameMouseState = function(frame, cdID)
  if frame then
    UpdateOverlayState(frame)
  end
end

-- ===================================================================
-- HELPER - Determine if icon is "active" for inactive state handling
-- ===================================================================

-- Helper to determine if an icon is "active" based on its type
-- For auras (buffs): active = buff is applied (auraInstanceID > 0)
-- For cooldowns: We use secret-safe APIs directly in ApplyCooldownStateVisuals
-- ===================================================================
-- GLOW MANAGEMENT for Ready State
-- 
-- LCG's bgUpdate() sets glow alpha to 0.5 or 1.0 every frame.
-- We hook the glow frame's SetAlpha to intercept and override!
-- ===================================================================

-- Hook the glow frame's SetAlpha to allow our override
-- HookGlowAlpha removed — forced alpha for secret curve driving now handled
-- by ns.Glows.SetForcedAlpha() which hooks the glow frame's SetAlpha internally.

-- ═══════════════════════════════════════════════════════════════════
-- ACH TEMPLATE GLOWS (ants + proc burst from Blizzard templates)
-- Used as glow types "ants" and "ach_proc" in ready/aura glow systems.
-- These are NOT LCG-managed — they use CreateFrame with Blizzard templates
-- and are stored on the glow overlay as _AchAnts<key> / _AchProc<key>.
-- ═══════════════════════════════════════════════════════════════════

-- Apply Masque shape to an ACH ants glow on overlay
local function ApplyMasqueAntsShapeToGlow(parentFrame, glow)
  if not glow or not glow.Flipbook or not IsMasqueSkinned(parentFrame) then return end
  local shape = parentFrame._MSQ_CFG and parentFrame._MSQ_CFG.Shape
  if not shape then return end
  local MasqueLib = LibStub and LibStub("Masque", true)
  if not MasqueLib or not MasqueLib.GetAssistedCombatHighlightStyle then return end
  local styleData = MasqueLib.GetAssistedCombatHighlightStyle(MasqueLib, shape)
  if not ok or not styleData then return end
  if styleData.Texture then
    glow.Flipbook:SetTexture(styleData.Texture)
  end
  if styleData.TexCoords then
    local tc = styleData.TexCoords
    glow.Flipbook:SetTexCoord(tc[1] or 0, tc[2] or 1, tc[3] or 0, tc[4] or 1)
  end
  if glow.Flipbook.Anim and styleData.FrameWidth then
    local flipAnim
    for _, child in pairs({glow.Flipbook.Anim:GetAnimations()}) do
      if child and child.SetFlipBookFrameWidth then flipAnim = child; break end
    end
    if flipAnim then
      flipAnim:SetFlipBookFrameWidth(styleData.FrameWidth or 0)
      flipAnim:SetFlipBookFrameHeight(styleData.FrameHeight or 0)
    end
  end
  -- Re-init after texture change
  if glow.Flipbook.Anim then
    glow.Flipbook.Anim:Play()
    glow.Flipbook.Anim:Stop()
  end
  glow._achMasqueShape = shape
end

-- Apply Masque shape to an ACH proc glow on overlay
local function ApplyMasqueProcShapeToACHGlow(parentFrame, glow)
  if not glow or not IsMasqueSkinned(parentFrame) then return end
  local shape = parentFrame._MSQ_CFG and parentFrame._MSQ_CFG.Shape
  if not shape then return end
  local MasqueLib = LibStub and LibStub("Masque", true)
  if not MasqueLib or not MasqueLib.GetSpellAlertFlipBook then return end
  local flipData = MasqueLib.GetSpellAlertFlipBook(MasqueLib, "Modern", shape)
  if not ok or not flipData then
    flipData = MasqueLib.GetSpellAlertFlipBook(MasqueLib, "Classic", shape)
  end
  if not ok or not flipData then return end
  if flipData.LoopTexture and glow.ProcLoopFlipbook then
    glow.ProcLoopFlipbook:SetTexture(flipData.LoopTexture)
  end
  if glow.ProcStartFlipbook then
    if flipData.StartTexture then
      glow.ProcStartFlipbook:SetTexture(flipData.StartTexture)
    elseif flipData.LoopTexture then
      glow.ProcStartFlipbook:SetTexture(flipData.LoopTexture)
      glow.ProcStartFlipbook:ClearAllPoints()
      glow.ProcStartFlipbook:SetAllPoints()
    end
  end
  if glow.ProcLoop and flipData.FrameWidth then
    local loopFlipAnim = glow.ProcLoop.FlipAnim
    if not loopFlipAnim then
      for _, child in pairs({glow.ProcLoop:GetAnimations()}) do
        if child and child.SetFlipBookFrameWidth then loopFlipAnim = child; break end
      end
    end
    if loopFlipAnim then
      loopFlipAnim:SetFlipBookFrameWidth(flipData.FrameWidth or 0)
      loopFlipAnim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
    end
  end
  if glow.ProcStartAnim and flipData.FrameWidth then
    local startFlipAnim = glow.ProcStartAnim.FlipAnim
    if not startFlipAnim then
      for _, child in pairs({glow.ProcStartAnim:GetAnimations()}) do
        if child and child.SetFlipBookFrameWidth then startFlipAnim = child; break end
      end
    end
    if startFlipAnim then
      startFlipAnim:SetFlipBookFrameWidth(flipData.FrameWidth or 0)
      startFlipAnim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
    end
  end
  glow._achMasqueShape = shape
end

-- Show an ACH template glow (ants or ach_proc) on the glow overlay
-- @param target: The glow overlay frame
-- @param frame: The parent icon frame (for sizing + Masque)
-- @param style: "ants" or "ach_proc"
-- @param key: Glow key (e.g. "ArcUI_ReadyGlow", "ArcUI_AuraGlow")
-- @param color: {r, g, b, a} color table
-- @param scale: Scale multiplier
-- @param intensity: Alpha intensity
-- @return: The glow frame
local function ShowACHTemplateGlow(target, frame, style, key, color, scale, intensity)
  if not target or not frame then return nil end
  local storageKey = (style == "ants") and ("_AchAnts" .. key) or ("_AchProc" .. key)
  local glow = target[storageKey]

  if not glow then
    if style == "ants" then
      glow = CreateFrame("FRAME", nil, target, "ActionBarButtonAssistedCombatHighlightTemplate")
      glow:SetPoint("CENTER")
      glow._achStyle = "ants"
      if glow.Flipbook and glow.Flipbook.Anim then
        glow.Flipbook.Anim:Play()
        glow.Flipbook.Anim:Stop()
      end
    else -- ach_proc
      glow = CreateFrame("FRAME", nil, target, "ActionButtonSpellAlertTemplate")
      glow:SetPoint("CENTER")
      glow._achStyle = "ach_proc"
      if glow.ProcStartAnim then
        glow.ProcStartAnim:SetScript("OnFinished", function()
          if glow.ProcLoop then glow.ProcLoop:Play() end
        end)
      end
      if glow.ProcLoopFlipbook then
        glow.ProcLoopFlipbook:SetAlpha(1)
        glow.ProcLoopFlipbook:Show()
      end
      if glow.ProcLoop then
        glow.ProcLoop:Play()
        glow.ProcLoop:Stop()
      end
    end
    target[storageKey] = glow
  end

  -- Size
  local w = math.max(frame:GetWidth() or 36, 1)
  local h = math.max(frame:GetHeight() or 36, 1)
  local scaledW, scaledH = w * scale, h * scale

  if style == "ants" then
    glow:SetSize(scaledW, scaledH)
    if glow.Flipbook then
      glow.Flipbook:SetSize(scaledW * ACH_ANTS_FLIPBOOK_RATIO, scaledH * ACH_ANTS_FLIPBOOK_RATIO)
    end
  else -- ach_proc
    local containerW = scaledW * ACH_PROC_LOOP_RATIO
    local containerH = scaledH * ACH_PROC_LOOP_RATIO
    glow:SetSize(containerW, containerH)
    if glow.ProcStartFlipbook then
      glow.ProcStartFlipbook:SetSize(scaledW * ACH_PROC_START_RATIO, scaledH * ACH_PROC_START_RATIO)
    end
  end

  -- Color — desaturate first to strip baked-in color so SetVertexColor gives true color
  local r, g, b, a = color[1] or 1, color[2] or 1, color[3] or 1, color[4] or intensity or 1
  local hasCustomColor = not (r >= 0.99 and g >= 0.99 and b >= 0.99)
  if style == "ants" then
    if glow.Flipbook then
      glow.Flipbook:SetDesaturated(hasCustomColor)
      glow.Flipbook:SetVertexColor(r, g, b, a)
    end
  else
    if glow.ProcLoopFlipbook then
      glow.ProcLoopFlipbook:SetDesaturated(hasCustomColor)
      glow.ProcLoopFlipbook:SetVertexColor(r, g, b, a)
    end
    if glow.ProcStartFlipbook then
      glow.ProcStartFlipbook:SetDesaturated(hasCustomColor)
      glow.ProcStartFlipbook:SetVertexColor(r, g, b, a)
    end
  end

  -- Masque shape
  local currentShape = frame._MSQ_CFG and frame._MSQ_CFG.Shape
  if glow._achMasqueShape ~= currentShape then
    if style == "ants" then
      ApplyMasqueAntsShapeToGlow(frame, glow)
    else
      ApplyMasqueProcShapeToACHGlow(frame, glow)
    end
  end

  -- Play animations and show
  if style == "ants" then
    if glow.Flipbook and glow.Flipbook.Anim and not glow.Flipbook.Anim:IsPlaying() then
      glow.Flipbook.Anim:Play()
    end
  else
    -- Hide start burst, show loop only
    if glow.ProcStartFlipbook then
      glow.ProcStartFlipbook:SetAlpha(0)
      glow.ProcStartFlipbook:Hide()
    end
    if glow.ProcLoopFlipbook then
      glow.ProcLoopFlipbook:SetAlpha(a)
      glow.ProcLoopFlipbook:Show()
    end
    if glow.ProcLoop and not glow.ProcLoop:IsPlaying() then
      glow.ProcLoop:Play()
    end
  end

  glow:Show()
  ClampOverlayChildren(target)
  return glow
end

-- Hide an ACH template glow on the glow overlay
local function HideACHTemplateGlow(target, style, key)
  if not target then return end
  local storageKey = (style == "ants") and ("_AchAnts" .. key) or ("_AchProc" .. key)
  local glow = target[storageKey]
  if not glow then return end
  glow:Hide()
  if style == "ants" then
    if glow.Flipbook and glow.Flipbook.Anim and glow.Flipbook.Anim:IsPlaying() then
      glow.Flipbook.Anim:Stop()
    end
  else
    if glow.ProcStartAnim and glow.ProcStartAnim:IsPlaying() then glow.ProcStartAnim:Stop() end
    if glow.ProcLoop and glow.ProcLoop:IsPlaying() then glow.ProcLoop:Stop() end
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- READY GLOW — via ns.Glows unified module
-- ═══════════════════════════════════════════════════════════════════

-- Build ns.Glows opts from stateVisuals (or raw glow settings)
local function BuildReadyGlowOpts(glowSettings, frame)
  local glowType = "button"
  local r, g, b = 1, 0.85, 0.1
  local intensity = 1.0
  local scale = 1.0
  local speed = 0.25
  local lines = 8
  local thickness = 2
  local particles = 4
  local xOffset = 0
  local yOffset = 0
  local translateX = 0
  local translateY = 0
  local strata, frameLevel
  
  if type(glowSettings) == "table" then
    glowType = glowSettings.readyGlowType or glowSettings.glowType or "button"
    
    local colorSrc = glowSettings.readyGlowColor or glowSettings.glowColor
    if colorSrc then
      r = colorSrc.r or colorSrc[1] or 1
      g = colorSrc.g or colorSrc[2] or 0.85
      b = colorSrc.b or colorSrc[3] or 0.1
    elseif glowSettings.r then
      r = glowSettings.r or 1
      g = glowSettings.g or 0.85
      b = glowSettings.b or 0.1
    end
    
    intensity = glowSettings.readyGlowIntensity or glowSettings.glowIntensity or 1.0
    scale = glowSettings.readyGlowScale or glowSettings.glowScale or 1.0
    speed = glowSettings.readyGlowSpeed or glowSettings.glowSpeed or 0.25
    lines = glowSettings.readyGlowLines or glowSettings.glowLines or 8
    thickness = glowSettings.readyGlowThickness or glowSettings.glowThickness or 2
    particles = glowSettings.readyGlowParticles or glowSettings.glowParticles or 4
    xOffset = glowSettings.readyGlowXOffset or glowSettings.glowXOffset or 0
    yOffset = glowSettings.readyGlowYOffset or glowSettings.glowYOffset or 0
    translateX = glowSettings.readyGlowTranslateX or glowSettings.glowTranslateX or 0
    translateY = glowSettings.readyGlowTranslateY or glowSettings.glowTranslateY or 0
    strata = glowSettings.readyGlowFrameStrata or glowSettings.glowFrameStrata
    frameLevel = glowSettings.readyGlowFrameLevel or glowSettings.glowFrameLevel
  end
  -- "inherit" on CDM icons = MEDIUM strata at level 1 (fits glow position correctly)
  if not strata or strata == "inherit" then
    strata = "MEDIUM"
    if not frameLevel then frameLevel = 1 end
  end
  
  -- Calculate offset from padding + user offset
  local padding = 0
  if frame and frame.cooldownID then
    local iconCfg = GetIconSettings(frame.cooldownID)
    if iconCfg then padding = iconCfg.padding or 0 end
  end
  local baseOffset = -padding
  
  return glowType, {
    color = {r, g, b, intensity},
    intensity = intensity,
    scale = scale,
    frequency = speed,
    lines = lines,
    thickness = thickness,
    particles = particles,
    xOffset = baseOffset + xOffset,
    yOffset = baseOffset + yOffset,
    translateX = translateX,
    translateY = translateY,
    strata = strata,
    frameLevel = frameLevel,
  }
end

-- Set glow alpha (secret-safe via ns.Glows.SetForcedAlpha)
-- Called by CooldownState threshold curve to drive glow visibility with secret values.
local function SetGlowAlpha(frame, alpha, glowSettings)
  if not frame or not ns.Glows then return end
  
  -- Ensure glow is started
  if not ns.Glows.IsActive(frame, "ArcUI_ReadyGlow") then
    local glowType, opts = BuildReadyGlowOpts(glowSettings, frame)
    ns.Glows.Start(frame, "ArcUI_ReadyGlow", glowType, opts)
    frame._arcReadyGlowActive = true
    frame._arcCurrentGlowType = glowType
    -- Immediately hide before first render — the curve will drive visibility
    local gf = ns.Glows.GetGlowFrame(frame, "ArcUI_ReadyGlow")
    if gf then
      gf:SetAlpha(0)
    end
  end
  
  -- Drive alpha with (potentially secret) value
  ns.Glows.SetForcedAlpha(frame, "ArcUI_ReadyGlow", alpha)
end

-- Forward declaration for HideReadyGlow (used in ShowReadyGlow)
local HideReadyGlow

-- Helper: Check if glow should be shown (considers combat-only setting and preview mode)
local function ShouldShowReadyGlow(stateVisuals, frame)
  -- Check if glow preview is active for this icon (overrides all other conditions)
  if frame and frame.cooldownID then
    if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsGlowPreviewActive then
      if ns.CDMEnhanceOptions.IsGlowPreviewActive(frame.cooldownID) then
        return true  -- Preview active = always show glow
      end
    end
  end
  
  -- STRICT CHECK: readyGlow must be explicitly boolean true, not just truthy
  -- This prevents old/corrupted saved variables from accidentally enabling glows
  if not stateVisuals or stateVisuals.readyGlow ~= true then
    return false
  end

  -- glowFollowPandemic: only TriggerAlertEvent (eventType 2) owns this glow.
  -- Normal ready/apply paths must not show or hide it via _arcPandemicGlowActive.
  -- Preview already returned true above so this gate is never reached in preview.
  if stateVisuals.glowFollowPandemic then
    return frame and frame._arcPandemicGlowActive == true or false
  end

  -- Check combat-only mode
  if stateVisuals.readyGlowCombatOnly then
    local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
    if not inCombat then
      return false
    end
  end
  
  return true
end

-- Show glow via ns.Glows unified module
local function ShowReadyGlow(frame, glowSettings)
  if not frame or not ns.Glows then return end
  
  -- Clear forced alpha BEFORE Start — the threshold curve may have driven the
  -- glow frame's alpha with a secret value.  If we call Start first, LCG's
  -- re-start path reads texture GetAlpha() which is tainted by the secret,
  -- then tries arithmetic on it and errors.  Clearing first restores normal
  -- alphas so LCG can safely read them.
  if frame._arcForcedGlowAlpha then
    ns.Glows.ClearForcedAlpha(frame, "ArcUI_ReadyGlow")
  end
  
  local glowType, opts = BuildReadyGlowOpts(glowSettings, frame)
  ns.Glows.Start(frame, "ArcUI_ReadyGlow", glowType, opts)
  
  frame._arcReadyGlowActive = true
  frame._arcCurrentGlowType = glowType  -- backward compat for ProcGlow ownership checks
  
  -- CRITICAL: Enforce pandemic hiding after glow changes
  if frame.PandemicIcon and not frame._arcShowPandemic then
    frame.PandemicIcon:Hide()
    frame.PandemicIcon:SetAlpha(0)
    if frame.PandemicIcon.Border then
      frame.PandemicIcon.Border:Hide()
    end
    if frame.PandemicIcon.FX then
      frame.PandemicIcon.FX:Hide()
    end
  end
end

-- Hide ready glow via ns.Glows unified module
HideReadyGlow = function(frame)
  if not frame then return end
  
  -- PERF: Skip if glow is already inactive
  if not frame._arcReadyGlowActive then return end
  
  -- Stop via ns.Glows (handles all LCG types, ACH templates, cleanup)
  if ns.Glows then
    ns.Glows.Stop(frame, "ArcUI_ReadyGlow")
  end
  
  frame._arcReadyGlowActive = false
  frame._arcCurrentGlowType = nil
  frame._arcCurrentGlowSig = nil
  
  -- CRITICAL: Enforce pandemic hiding after glow changes
  if frame.PandemicIcon and not frame._arcShowPandemic then
    frame.PandemicIcon:Hide()
    frame.PandemicIcon:SetAlpha(0)
    if frame.PandemicIcon.Border then
      frame.PandemicIcon.Border:Hide()
      frame.PandemicIcon.Border:SetAlpha(0)
    end
    if frame.PandemicIcon.FX then
      frame.PandemicIcon.FX:Hide()
      frame.PandemicIcon.FX:SetAlpha(0)
    end
  end
end

-- ===================================================================
-- Get effective state visuals
-- ===================================================================
GetEffectiveStateVisuals = function(cfg)
  if not cfg then return nil end
  
  -- Use the two-state system (cooldownStateVisuals)
  local csv = cfg.cooldownStateVisuals
  if csv then
    local rs = csv.readyState or {}
    local cs = csv.cooldownState or {}
    
    -- Check if any setting is non-default
    -- STRICT: glow must be explicitly boolean true
    local hasReadySettings = (rs.alpha ~= nil and rs.alpha ~= 1.0) or rs.glow == true or rs.desaturate == true or rs.tint == true
    -- Note: noDesaturate explicitly blocks CDM's default desaturation
    local hasCooldownSettings = (cs.alpha ~= nil and cs.alpha ~= 1.0) or cs.desaturate == true or cs.tint == true or cs.noDesaturate == true or cs.preserveDurationText == true or cs.waitForNoCharges == true
    
    if hasReadySettings or hasCooldownSettings then
      return {
        readyAlpha = rs.alpha ~= nil and rs.alpha or 1.0,
        readyDesaturate = rs.desaturate == true,  -- STRICT boolean
        readyTint = rs.tint == true,  -- STRICT boolean
        readyTintColor = rs.tintColor,
        readyGlow = rs.glow == true,  -- STRICT: Only true if explicitly boolean true
        readyGlowColor = rs.glowColor,
        readyGlowType = rs.glowType or "button",
        readyGlowIntensity = rs.glowIntensity or 1.0,
        readyGlowScale = rs.glowScale or 1.0,
        readyGlowSpeed = rs.glowSpeed or 0.25,
        readyGlowLines = rs.glowLines or 8,
        readyGlowThickness = rs.glowThickness or 2,
        readyGlowParticles = rs.glowParticles or 4,
        readyGlowXOffset = rs.glowXOffset or 0,
        readyGlowYOffset = rs.glowYOffset or 0,
        readyGlowTranslateX = rs.glowTranslateX or 0,
        readyGlowTranslateY = rs.glowTranslateY or 0,
        readyGlowCombatOnly = rs.glowCombatOnly == true,  -- STRICT boolean
        readyGlowFrameStrata = rs.glowFrameStrata,  -- nil = inherit parent strata
        readyGlowFrameLevel = rs.glowFrameLevel,    -- nil = auto (relative +15)
        glowThreshold = rs.glowThreshold or 1.0,
        glowThresholdSeconds = rs.glowThresholdSeconds,  -- nil = use percent mode, number = time-based (immune to extension bugs)
        glowFollowPandemic = rs.glowFollowPandemic == true,  -- Use CDM pandemic timing instead of threshold
        glowAuraType = rs.glowAuraType or "auto",
        glowWhileChargesAvailable = rs.glowWhileChargesAvailable == true,  -- STRICT boolean
        readyProcOverride = rs.procOverride == true,    -- STRICT boolean
        cooldownAlpha = cs.alpha ~= nil and cs.alpha or 1.0,
        cooldownDesaturate = cs.desaturate == true,  -- STRICT boolean
        cooldownTint = cs.tint == true,  -- STRICT boolean
        cooldownTintColor = cs.tintColor,
        noDesaturate = cs.noDesaturate == true,  -- STRICT boolean
        preserveDurationText = cs.preserveDurationText == true,  -- STRICT boolean
        waitForNoCharges = cs.waitForNoCharges == true,  -- STRICT boolean
        cooldownProcOverride = cs.procOverride == true,  -- STRICT boolean
      }
    end
  end
  
  return nil  -- No state visuals configured
end

-- Helper to get effective ready alpha (handles options panel preview when alpha is 0)
local function GetEffectiveReadyAlpha(stateVisuals)
  if not stateVisuals then return 1 end
  local readyAlpha = stateVisuals.readyAlpha
  if readyAlpha <= 0 then
    if ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
      return 0.35  -- Options panel preview
    end
  end
  return readyAlpha
end

-- Export for CooldownState module
ns.CDMEnhance.GetEffectiveReadyAlpha = GetEffectiveReadyAlpha

-- ===================================================================
-- APPLY COOLDOWN STATE VISUALS — STUB (load-time placeholder)
-- ===================================================================
-- The full implementation lives in ArcUI_CooldownState.lua which overwrites
-- ns.CDMEnhance.ApplyCooldownStateVisuals after this file loads.
-- This stub exists only to satisfy the export at load time.
-- The relay below routes all internal callers through ns.CDMEnhance,
-- so this stub body never executes during normal operation.
ApplyCooldownStateVisuals = function(frame, cfg, normalAlpha, stateVisuals)
  -- Stub: CooldownState.lua replaces this at load time
end


-- Export state visual functions
ns.CDMEnhance.ApplyCooldownStateVisuals = ApplyCooldownStateVisuals
ns.CDMEnhance.GetEffectiveStateVisuals = GetEffectiveStateVisuals
ns.CDMEnhance.ShowReadyGlow = ShowReadyGlow
ns.CDMEnhance.HideReadyGlow = HideReadyGlow
ns.CDMEnhance.SetGlowAlpha = SetGlowAlpha
ns.CDMEnhance.ShouldShowReadyGlow = ShouldShowReadyGlow

-- ═══════════════════════════════════════════════════════════════════════════
-- AURA ACTIVE GLOW (for cooldown frames when their associated aura is up)
-- Uses dedicated key "ArcUI_AuraGlow" to avoid conflicts with ready/proc glows.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════
-- AURA ACTIVE GLOW — owned by ArcUI_CooldownState.lua for cooldown frames
-- CDMEnhance forwards through ns.CooldownState (set when CooldownState loads).
-- Stub here so any early callers before CooldownState loads don't crash.
-- ═══════════════════════════════════════════════════════════════════

ShowAuraActiveGlow = function(frame, cfg)
  if ns.CooldownState and ns.CooldownState.ShowAuraActiveGlow then
    ns.CooldownState.ShowAuraActiveGlow(frame, cfg)
  end
end

HideAuraActiveGlow = function(frame)
  if ns.CooldownState and ns.CooldownState.HideAuraActiveGlow then
    ns.CooldownState.HideAuraActiveGlow(frame)
  end
end

local function ShouldShowAuraActiveGlow(auraActiveCfg, frame, isReady)
  if ns.CooldownState and ns.CooldownState.ShouldShowAuraActiveGlow then
    return ns.CooldownState.ShouldShowAuraActiveGlow(auraActiveCfg, frame, isReady)
  end
  return false
end

-- Exports: point at CooldownState (set when it loads).
-- Stub closures above ensure early callers are safe before CooldownState loads.
ns.CDMEnhance.ShowAuraActiveGlow       = ShowAuraActiveGlow
ns.CDMEnhance.HideAuraActiveGlow       = HideAuraActiveGlow
ns.CDMEnhance.ShouldShowAuraActiveGlow = ShouldShowAuraActiveGlow

-- RELAY: Make the local a dynamic lookup through ns.CDMEnhance
-- When ArcUI_CooldownState.lua loads, it overwrites ns.CDMEnhance.ApplyCooldownStateVisuals
-- with the refactored version. This relay ensures all 8+ internal call sites in this file
-- automatically route to the new implementation without individual changes.
ApplyCooldownStateVisuals = function(frame, cfg, normalAlpha, stateVisuals)
  -- AURA-EVENT-DRIVEN ROUTING: True aura frames (cfg._isAura, totems) with event hooks
  -- are owned by OptimizedApplyIconVisuals which checks HasAuraInstanceID for live state.
  -- CooldownState evaluates spell cooldown state (not aura presence) and would set wrong alpha.
  -- Cooldown frames with wasSetFromAura still need CooldownState (ReadCooldownState sub-path).
  if frame and not frame._arcIgnoreAuraOverride then
    local frameCfg = cfg or GetEffectiveIconSettingsForFrame(frame)
    if frameCfg and (frameCfg._isAura or (frame.totemData ~= nil and not frame._arcCooldownEventDriven)) then
      -- True aura/totem frame — always route to UpdateAuraFrame, never CooldownState.
      -- Gate on cfg._isAura alone (not _arcAuraEventDriven) so alpha/preview always apply
      -- even during the brief window before AuraFrames sets _arcAuraEventDriven.
      frame._arcLastOptimizedCall = nil
      frame._arcLastAuraActive = nil
      if ns.CDMEnhance.OptimizedApplyIconVisuals then
        ns.CDMEnhance.OptimizedApplyIconVisuals(frame)
      end
      if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
        ns.CustomLabel.UpdateVisibility(frame)
      end
      if ns.CDMSpellUsability and ns.CDMSpellUsability.UpdateGlow then
        ns.CDMSpellUsability.UpdateGlow(frame, frameCfg)
      end
      return
    end
  end
  local result = ns.CDMEnhance.ApplyCooldownStateVisuals(frame, cfg, normalAlpha, stateVisuals)
  -- Update custom label visibility on cooldown state change
  if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
    ns.CustomLabel.UpdateVisibility(frame)
  end
  -- Update usable glow overlay for CDM frames
  if ns.CDMSpellUsability and ns.CDMSpellUsability.UpdateGlow then
    ns.CDMSpellUsability.UpdateGlow(frame, cfg)
  end
  return result
end

-- ═══════════════════════════════════════════════════════════════════
-- EVENT-DRIVEN COOLDOWN STATE UPDATE
--
-- Called from:
--   1. SPELL_UPDATE_COOLDOWN → EnforceReadyGlow loop
--   2. Shadow OnCooldownDone → natural timer expiry (via DispatchAfterShadowUpdate)
--   3. Initial enhancement (deferred C_Timer.After(0))
--   4. Internal dispatchers (glow restart, etc.)
--
-- Feeds shadow then explicitly calls ApplyCooldownStateVisuals.
-- ═══════════════════════════════════════════════════════════════════
function ns.CDMEnhance.OnCooldownEvent(frame, fromTicker, skipIdle, forceVisuals)
  if not frame then return end
  if frame._arcConfig or frame._arcAuraID then return end
  if not cachedCDMGroupsEnabled then return end
  if ns.CDMEnhance.IsFrameHiddenByBar and ns.CDMEnhance.IsFrameHiddenByBar(frame) then return end
  if ns.CDMGroups then
    if ns.CDMGroups.specChangeInProgress or ns.CDMGroups._pendingSpecChange then return end
    if ns.CDMGroups._restorationProtectionEnd and GetTime() < ns.CDMGroups._restorationProtectionEnd then return end
  end

  -- SPELL OVERRIDE DETECTION: CDM can swap overrideSpellID on a frame mid-session
  -- (e.g. Surging Totem 444995 → Retract 1221348 → back). The per-frame event listener
  -- uses _arcCachedSpellID which can be stale. Detect the swap here and invalidate
  -- so the next event feed picks up the correct spell.
  if ns.CooldownState then
    local cfg = GetEffectiveIconSettingsForFrame(frame)
    if cfg then
      local currentOverride = frame.cooldownInfo
                              and (frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID)
      local fedSpell = frame._arcShadowFedSpellID
      if currentOverride and fedSpell and currentOverride ~= fedSpell then
        frame._arcLastShadowShown  = nil
        frame._arcLastChargeShown  = nil
        frame._arcShadowFedSpellID = nil
        -- Feed immediately so the new spell's state is applied now, not on next event
        ns.CooldownState.FeedShadow(frame, cfg)
        ApplyCooldownStateVisuals(frame, cfg)
      end
    end
  end

  -- SWIPE ENFORCEMENT: re-apply what DecideAndApplySwipeEdge last decided.
  -- CDM writes SetDrawSwipe/SetDrawEdge on its own update cycle which can
  -- clobber our value. This is the single place that re-enforces it.
  local cd = frame.Cooldown
  if cd then
    if frame._arcDesiredSwipe ~= nil then
      frame._arcBypassSwipeHook = true
      cd:SetDrawSwipe(frame._arcDesiredSwipe)
      cd:SetDrawEdge(frame._arcDesiredEdge)
      frame._arcBypassSwipeHook = false
    end
  end
end

-- Export font helper functions (for Arc Auras stack text styling)
ns.CDMEnhance.GetFontPath = GetFontPath
ns.CDMEnhance.SafeSetFont = SafeSetFont

-- Show proc glow preview for an icon
function ns.CDMEnhance.ShowProcGlowPreview(cdID)
  local data = enhancedFrames[cdID]
  if not data or not data.frame then return end
  
  local frame = data.frame
  local cfg = GetIconSettings(cdID)
  local glowCfg = cfg and cfg.procGlow
  
  local originalType = glowCfg and glowCfg.glowType or "proc"
  local glowType = originalType
  -- "default" now uses "proc" (LCG ProcGlow) instead of CDM's SpellActivationAlert
  if glowType == "default" then glowType = "proc" end
  
  -- nil color for "default" with no user color = LCG native golden texture
  local userColor = glowCfg and glowCfg.color
  local colorOpt = nil
  if userColor then
    colorOpt = {userColor.r or 1, userColor.g or 0.85, userColor.b or 0.1, glowCfg and glowCfg.alpha or 1.0}
  elseif originalType ~= "default" then
    colorOpt = {0.95, 0.95, 0.32, glowCfg and glowCfg.alpha or 1.0}
  end
  local scale = glowCfg and glowCfg.scale or 1.0
  local glowOffset = -(cfg and cfg.padding or 0)

  if ns.Glows then
    ns.Glows.Start(frame, "ArcUI_ProcPreview", glowType, {
      color = colorOpt,
      scale = scale,
      frequency = glowCfg and glowCfg.speed or 0.25,
      lines = glowCfg and glowCfg.lines or 8,
      thickness = glowCfg and glowCfg.thickness or 2,
      particles = glowCfg and glowCfg.particles or 4,
      xOffset = glowOffset + (glowCfg and glowCfg.xOffset or 0),
      yOffset = glowOffset + (glowCfg and glowCfg.yOffset or 0),
      translateX = glowCfg and glowCfg.translateX or 0,
      translateY = glowCfg and glowCfg.translateY or 0,
      strata = (not (glowCfg and glowCfg.strata) or glowCfg.strata == "inherit") and "MEDIUM" or glowCfg.strata,
      frameLevel = (glowCfg and glowCfg.frameLevel) or ((not (glowCfg and glowCfg.strata) or glowCfg.strata == "inherit") and 1 or nil),
      startAnim = true,
    })
  end
  
  frame._arcProcPreviewActive = true
  frame._arcProcPreviewType = glowType
end

-- Hide proc glow preview for an icon
function ns.CDMEnhance.HideProcGlowPreview(cdID)
  local data = enhancedFrames[cdID]
  if not data or not data.frame then return end
  
  local frame = data.frame
  
  if ns.Glows then
    ns.Glows.Stop(frame, "ArcUI_ProcPreview")
  end
  
  frame._arcProcPreviewActive = false
  frame._arcProcPreviewType = nil
end

-- Refresh active proc glow with new settings (for multi-select)
function ns.CDMEnhance.RefreshProcGlow(cdID)
  local data = enhancedFrames[cdID]
  if not data or not data.frame then return end
  
  local frame = data.frame
  
  -- Only refresh if custom glow is currently active
  if not frame._arcProcGlowActive then return end
  
  local cfg = GetIconSettings(cdID)
  local glowCfg = cfg and cfg.procGlow
  if not glowCfg then return end
  
  -- If glow is disabled, just stop and exit
  if glowCfg.enabled == false then
    StopLCGProcGlow(frame)
    frame._arcProcGlowActive = false
    frame._arcProcGlowType = nil
    return
  end
  
  -- Stop and restart with new settings via ns.Glows
  local padding = cfg and cfg.padding or 0
  StopLCGProcGlow(frame)
  StartLCGProcGlow(frame, glowCfg, padding)
  
  local glowType = glowCfg.glowType or "proc"
  if glowType == "default" then glowType = "proc" end
  frame._arcProcGlowActive = true
  frame._arcProcGlowType = glowType
end

-- Get enhanced frame data for a cooldownID
function ns.CDMEnhance.GetEnhancedFrameData(cdID)
  return enhancedFrames[cdID]
end

-- Iterate every enhanced CDM frame: fn(cdID, frame, data). Used by feature
-- modules (e.g. DurationOverride) that need to (re)scan per-icon settings.
function ns.CDMEnhance.ForEachEnhancedFrame(fn)
  for cdID, data in pairs(enhancedFrames) do
    if data and data.frame then fn(cdID, data.frame, data) end
  end
end

-- Hide all combat-only glows for a specific viewer type
function ns.CDMEnhance.HideAllCombatOnlyGlows(viewerType)
  for cdID, data in pairs(enhancedFrames) do
    if data and data.frame then
      -- If viewerType specified, only hide for matching types
      if not viewerType or data.viewerType == viewerType then
        HideReadyGlow(data.frame)
        HideAuraActiveGlow(data.frame)
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HIDDEN-BY-BAR VERIFICATION HELPER
-- Checks _arcHiddenByBar flag AND verifies cooldownID still matches.
-- If frame was recycled by CDM, cleans up stale flag and returns false.
-- ═══════════════════════════════════════════════════════════════════════════
local function IsFrameHiddenByBar(frame)
  if not frame._arcHiddenByBar then return false end
  -- Verify cooldownID still matches what Core.lua intended to hide
  local expectedCdID = frame._arcHiddenByBarCdID
  if expectedCdID and frame.cooldownID and frame.cooldownID ~= expectedCdID then
    -- Frame was recycled for a different cooldown - stale flag, clean up
    frame._arcHiddenByBar = nil
    frame._arcHiddenByBarCdID = nil
    return false
  end
  return true
end
ns.CDMEnhance.IsFrameHiddenByBar = IsFrameHiddenByBar

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIMIZED APPLY ICON VISUALS (Event-driven)
-- Called from aura state change hooks instead of 20Hz polling
-- Handles: alpha, desaturation. Other visuals stay in ApplyIconVisuals for now.
-- ═══════════════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════
-- OPTIMIZED APPLY ICON VISUALS — shim, owned by ArcUI_AuraFrames.lua
-- AuraFrames.UpdateAuraFrame is wired here by the compat shim at load.
-- This stub ensures callers before AuraFrames loads don't crash.
-- ═══════════════════════════════════════════════════════════════════
function ns.CDMEnhance.OptimizedApplyIconVisuals(frame)
  if ns.AuraFrames and ns.AuraFrames.UpdateAuraFrame then
    ns.AuraFrames.UpdateAuraFrame(frame)
  end
end

-- UNIFIED FUNCTION: Apply all visual state to an icon
-- CDMGroups should call this instead of having its own inline logic
-- Handles auras, cooldowns, ignoreAuraOverride, all inactive state options
function ns.CDMEnhance.ApplyIconVisuals(frame)
  if not frame then return end
  
  -- Arc Aura spell frames own their visuals via ApplySpellStateVisuals
  if frame._arcIsSpellCooldown then return end
  
  -- MASTER TOGGLE: Skip if disabled (fast cached check)
  if not cachedCDMGroupsEnabled then
    return  -- Silent - this is called frequently
  end
  
  -- HIDDEN BY BAR: Core.lua is hiding this icon - skip all visual updates
  if IsFrameHiddenByBar(frame) then return end
  
  -- EVENT-DRIVEN: Cooldown frames and hooked aura frames handle their
  -- own state via event hooks (SPELL_UPDATE_COOLDOWN, SetAuraInstanceInfo,
  -- ClearAuraInstanceInfo). Skip the 20Hz polling path entirely.
  -- Exception: glow preview must work from the options panel.
  -- Exception: ignoreAuraOverride aura frames need the ticker (they track
  -- spell cooldown state, not aura presence, and don't have SPELL_UPDATE hooks).
  -- Exception: cooldown frames with auraActiveState.glow need aura hooks to
  -- trigger glow show/hide (aura hooks call this function).
  if frame._arcCooldownEventDriven or (frame._arcAuraEventDriven and not frame._arcIgnoreAuraOverride) then
    local cdID = frame.cooldownID
    local isGlowPreview = cdID and ns.CDMEnhanceOptions
      and ns.CDMEnhanceOptions.IsGlowPreviewActive
      and ns.CDMEnhanceOptions.IsGlowPreviewActive(cdID)
    local isUsablePreview = cdID and ns.CDMEnhanceOptions
      and ns.CDMEnhanceOptions.IsUsableGlowPreviewActive
      and ns.CDMEnhanceOptions.IsUsableGlowPreviewActive(cdID)
    local isAuraGlowPrev = cdID and ns.CDMEnhanceOptions
      and ns.CDMEnhanceOptions.IsAuraGlowPreviewActive
      and ns.CDMEnhanceOptions.IsAuraGlowPreviewActive(cdID)
    -- Cooldown frames with aura active glow need to fall through to show/hide glow
    local hasAuraActiveGlowCfg = frame._arcHasAuraActiveGlow
    if not isGlowPreview and not isUsablePreview and not isAuraGlowPrev and not hasAuraActiveGlowCfg then
      return  -- Event hooks handle state, skip 20Hz dispatch
    end
    -- Fall through for preview mode or aura active glow
  end

  -- CRITICAL: Skip during spec change to prevent visual glitches
  if ns.CDMGroups then
    if ns.CDMGroups.specChangeInProgress or ns.CDMGroups._pendingSpecChange then return end
    if ns.CDMGroups._restorationProtectionEnd and GetTime() < ns.CDMGroups._restorationProtectionEnd then return end
  end

  -- FAST PATH: Get config from frame-level cache
  local cfg = GetEffectiveIconSettingsForFrame(frame)
  if not cfg then return end
  
  local cdID = frame.cooldownID
  
  -- CRITICAL: Ensure _arcIgnoreAuraOverride is set
  -- This is normally set in UpdateIconAppearance, but ApplyIconVisuals can be called independently
  local ignoreAuraOverride = (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)
    or (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
  frame._arcIgnoreAuraOverride = ignoreAuraOverride or false
  frame._arcCustomIconID = cfg.customIconID
  
  -- Check if glow preview is active for this icon
  local isGlowPreview = ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsGlowPreviewActive and
                        ns.CDMEnhanceOptions.IsGlowPreviewActive(cdID)
  
  -- Check if there are any state visuals configured
  -- If not, let CDM handle everything - don't call ApplyCooldownStateVisuals at all
  -- EXCEPT if glow preview is active - we need ApplyCooldownStateVisuals to handle that
  -- EXCEPT if auraActiveState.glow is enabled - cooldown frames need the aura path for glow
  local stateVisuals = GetEffectiveStateVisuals(cfg)
  local hasAuraActiveGlow = cfg.auraActiveState and (cfg.auraActiveState.glow == true or cfg.auraActiveState.glowWhenMissing == true)
  local isAuraGlowPreview = ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsAuraGlowPreviewActive
    and frame.cooldownID and ns.CDMEnhanceOptions.IsAuraGlowPreviewActive(frame.cooldownID)
  if not stateVisuals and not ignoreAuraOverride and not isGlowPreview and not hasAuraActiveGlow and not isAuraGlowPreview then
    -- No custom settings and not in ignoreAuraOverride mode and not in preview
    -- Let CDM handle alpha, desaturation, everything
    frame._arcForceDesatValue = nil
    -- IMPORTANT: Hide any leftover glow from preview mode
    HideReadyGlow(frame)
    HideAuraActiveGlow(frame)
    -- Feed shadow for usable glow (CooldownState dispatcher not running in this path)
    if ns.CooldownState and ns.CooldownState.FeedShadow then
      ns.CooldownState.FeedShadow(frame, cfg)
    end
    -- Still update usability tinting + glow (work independently of state visuals)
    if ns.CDMSpellUsability then
      if ns.CDMSpellUsability.OnRefreshIconColor then
        ns.CDMSpellUsability.OnRefreshIconColor(frame, cfg)
      end
      if ns.CDMSpellUsability.UpdateGlow then
        ns.CDMSpellUsability.UpdateGlow(frame, cfg)
      end
    end
    -- CRITICAL: Still update custom label visibility — labels have their own
    -- aura active/inactive and cooldown state toggles independent of stateVisuals.
    if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
      ns.CustomLabel.UpdateVisibility(frame)
    end
    return
  end
  
  -- AURA ACTIVE GLOW: Handle directly here for both preview and runtime.
  -- OptimizedApplyIconVisuals handles the runtime case via aura hooks,
  -- but preview needs to work even when no aura is active.
  if isAuraGlowPreview then
    local auraActiveCfg = cfg.auraActiveState or {}
    -- Force-show glow regardless of aura state (preview mode)
    ShowAuraActiveGlow(frame, auraActiveCfg)
  end

  -- Pass stateVisuals to avoid duplicate GetEffectiveStateVisuals call (perf optimization)
  ApplyCooldownStateVisuals(frame, cfg, cfg.alpha or 1.0, stateVisuals)
end

-- Forward declaration for EnhanceFrame (exported below after definition)
local EnhanceFrame

-- ===================================================================
-- FRAME ENHANCEMENT
-- ===================================================================
EnhanceFrame = function(frame, cdID, viewerType, viewerName)
  if not frame then return end
  
  -- MASTER TOGGLE: Skip if disabled (fast cached check)
  if not cachedCDMGroupsEnabled then
    return
  end
  
  -- CRITICAL: Skip during spec change to prevent enhancing orphaned frames
  if ns.CDMGroups then
    if ns.CDMGroups.specChangeInProgress or ns.CDMGroups._pendingSpecChange then return end
    if ns.CDMGroups._restorationProtectionEnd and GetTime() < ns.CDMGroups._restorationProtectionEnd then return end
  end
  
  -- Skip if this type's styling is disabled
  local db = GetDB()
  if db then
    if viewerType == "aura" and db.enableAuraCustomization == false then
      -- Don't spam - this is called constantly
      return
    end
    if (viewerType == "cooldown" or viewerType == "utility") and db.enableCooldownCustomization == false then
      -- Don't spam - this is called constantly
      return
    end
  end
  
  -- Skip BuffBarCooldownViewer frames - they have a different structure (bars, not icons)
  -- and our icon customization settings don't work properly with them
  if viewerName == "BuffBarCooldownViewer" then return end
  local parent = frame:GetParent()
  if parent and parent:GetName() == "BuffBarCooldownViewer" then return end
  
  -- Skip frames that are actual status bars (have Bar element) - these aren't icon-based
  if frame.Bar and frame.Bar:IsObjectType("StatusBar") then return end
  
  -- CRITICAL: Clean up stale references when frame is reassigned to a new cdID
  -- If this frame was previously tracked for a DIFFERENT cdID, remove those old entries
  if frame._arcLastEnhancedCdID and frame._arcLastEnhancedCdID ~= cdID then
    local oldCdID = frame._arcLastEnhancedCdID
    
    -- Clean up enhancedFrames
    local oldEntry = enhancedFrames[oldCdID]
    if oldEntry and oldEntry.frame == frame then
      enhancedFrames[oldCdID] = nil
      if ns.devMode then
        print(string.format("|cffFF6600[ArcUI]|r Frame reassigned: removed enhancedFrames[%d] (now cdID %d)", oldCdID, cdID))
      end
    end
    
    -- CRITICAL: Clear frame-level settings cache — it holds the OLD cdID's settings
    -- Without this, GetEffectiveIconSettingsForFrame returns stale config
    -- (version check passes but cdID has changed underneath)
    frame._arcCfg = nil
    frame._arcCfgVersion = nil
    
    -- CRITICAL: Kill any active proc glow from the OLD cooldownID
    -- When CDM repools frames (spec change, icon added/removed), the proc glow
    -- would persist on the frame even though it now represents a different spell.
    if frame._arcProcGlowActive then
      ns.CDMEnhance.HideProcGlow(frame)
      if ns.devMode then
        print(string.format("|cffFF6600[ArcUI]|r Cleaned up proc glow from old cdID %d (frame now cdID %d)", oldCdID, cdID))
      end
      -- Deferred: re-apply proc glow to whichever frame now holds the proc spell
      C_Timer.After(0.2, function()
        if ns.CDMEnhance.RefreshActiveProcGlows then
          ns.CDMEnhance.RefreshActiveProcGlows()
        end
      end)
    end
    -- Also clear ready glow state from the old spell
    if frame._arcReadyGlowActive then
      HideReadyGlow(frame)
    end
    if frame._arcAuraActiveGlowActive then
      HideAuraActiveGlow(frame)
    end
    -- Clear prewarm flag so new spell gets its own prewarm
    frame._arcProcGlowPreWarmed = nil
  end
  
  -- Track which cdID this frame is currently enhanced for
  frame._arcLastEnhancedCdID = cdID
  frame._arcEnhanced = true
  
  -- Update tracking table
  enhancedFrames[cdID] = {
    frame = frame,
    viewerType = viewerType,
    viewerName = viewerName,
  }
  
  -- Register with Masque (if available and MasqueBlizzBars isn't handling it)
  -- CRITICAL: Skip if spec change was recent - CDM frames may still be settling
  -- The scheduled Masque refresh in CDMGroups will handle these frames later
  local skipMasque = false
  if ns.CDMGroups and ns.CDMGroups.lastSpecChangeTime then
    local timeSinceSpecChange = GetTime() - ns.CDMGroups.lastSpecChangeTime
    if timeSinceSpecChange < 5 then
      skipMasque = true  -- Let the delayed Masque refresh handle it
    end
  end
  if not skipMasque and ns.Masque and ns.Masque.AddFrame then
    ns.Masque.AddFrame(frame, viewerName, cdID)
  end
  
  -- Only do initial setup if not already done
  if not frame._arcInitialized then
    frame._arcInitialized = true
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    
    -- Initial capture of CDM position
    local origX, origY = frame:GetLeft(), frame:GetBottom()
    if origX and origY then
      frame._arcOriginalX = origX
      frame._arcOriginalY = origY
    end
    
    CreateDragOverlay(frame, cdID)
    
    -- Store original (native CDM) dimensions for shadow overlay scaling.
    -- Always use known XML constant — GetWidth() may be post-resize.
    do
      local vt = viewerType or "cooldown"
      local nativeSize = CDM_NATIVE_SIZE[vt] or 36
      frame._arcOrigW = nativeSize
      frame._arcOrigH = nativeSize
    end
    
    -- NOTE: SetSize and SetScale hooks removed - CDMGroups handles all size/scale enforcement
    -- CDMEnhance only communicates settings via GetEffectiveIconSettings which CDMGroups reads
    
    -- ═══════════════════════════════════════════════════════════════════
    -- FRAME ALPHA HOOK - Blocks CDM from overriding our alpha
    -- Binary system: CooldownState sets alpha ONCE per state change,
    -- this hook just prevents CDM's internal SetAlpha(1.0) from clobbering.
    -- Updates _lastAppliedAlpha to keep cache in sync.
    -- ═══════════════════════════════════════════════════════════════════
    if not frame._arcFrameAlphaHooked then
      frame._arcFrameAlphaHooked = true
      
      hooksecurefunc(frame, "SetAlpha", function(self, alpha)
        -- FORCE HIDE: overrides EVERY alpha writer (including our own bypassed
        -- state writes) so the whole icon frame stays hidden. Runs BEFORE the
        -- bypass check on purpose. Text floats separately via IgnoreParentAlpha.
        -- While the options panel is open, hold the icon at PREVIEW opacity (not
        -- 0) so it can be seen, selected and dragged (its edit overlay too).
        if self._arcForceHideActive then
          if self._arcBypassForceHideAlpha then return end
          local target = 0
          if ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
            target = 0.35
          end
          if alpha ~= target then
            self._arcBypassForceHideAlpha = true
            self:SetAlpha(target)
            self._arcBypassForceHideAlpha = false
          end
          return
        end

        if self._arcBypassFrameAlphaHook then return end

        -- HIDDEN BY BAR: Core.lua is hiding this icon for a tracking bar
        if IsFrameHiddenByBar(self) then return end
        
        -- READY STATE ALPHA ENFORCEMENT (includes merged usability alpha)
        if self._arcEnforceReadyAlpha and self._arcReadyAlphaValue then
          self._arcBypassFrameAlphaHook = true
          self:SetAlpha(self._arcReadyAlphaValue)
          self._arcBypassFrameAlphaHook = false
          self._lastAppliedAlpha = self._arcReadyAlphaValue
          return
        end
        
        -- COOLDOWN STATE ALPHA ENFORCEMENT
        if self._arcTargetAlpha ~= nil then
          self._arcBypassFrameAlphaHook = true
          self:SetAlpha(self._arcTargetAlpha)
          self._arcBypassFrameAlphaHook = false
          self._lastAppliedAlpha = self._arcTargetAlpha
          return
        end
        
        -- READY STATE FALLBACK: When CooldownState sets full alpha (1.0),
        -- both _arcTargetAlpha and _arcEnforceReadyAlpha are cleared.
        -- This leaves the frame unprotected against CDM overriding alpha to 0
        -- during re-scans (e.g., options panel open triggers ScanCDM which calls
        -- EnhanceFrame → ApplyIconStyle → CDM widget updates → CDM sets alpha 0).
        -- Preserve last applied alpha to prevent CDM from clobbering our state.
        if self._arcEnhanced and self._lastAppliedAlpha then
          self._arcBypassFrameAlphaHook = true
          self:SetAlpha(self._lastAppliedAlpha)
          self._arcBypassFrameAlphaHook = false
        end
      end)
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- SHOW HOOK - Enforce Hide() when frame is hidden by bar tracking
    -- CDM and layout systems call Show() which would override our Hide()
    -- Verifies cooldownID still matches to handle frame recycling
    -- ═══════════════════════════════════════════════════════════════════
    if not frame._arcHideByBarShowHooked then
      frame._arcHideByBarShowHooked = true
      
      hooksecurefunc(frame, "Show", function(self)
        if IsFrameHiddenByBar(self) then
          self:Hide()
        end
      end)
      
      if frame.SetShown then
        hooksecurefunc(frame, "SetShown", function(self, shown)
          if shown and IsFrameHiddenByBar(self) then
            self:Hide()
          end
        end)
      end
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- AURA STATE HOOKS + INITIAL EVAL
    -- True aura (buff/debuff) frames: delegated to ArcUI_AuraFrames.
    -- Cooldown/utility frames: hooks owned by CooldownState so that all
    -- cooldown-frame logic stays in CooldownState, not AuraFrames.
    -- ═══════════════════════════════════════════════════════════════════
    if viewerType == "aura" then
      if ns.AuraFrames and ns.AuraFrames.EnhanceAuraFrame then
        ns.AuraFrames.EnhanceAuraFrame(frame, cdID)
      end
    else
      if ns.CooldownState and ns.CooldownState.InstallCooldownAuraHooks then
        ns.CooldownState.InstallCooldownAuraHooks(frame)
      end
    end

  end

  -- NOTE: Shadow frames have their own OnCooldownDone (installed by
  -- CooldownState.EnsureShadowCooldown). SPELL_UPDATE_COOLDOWN event
  -- handles all other cooldown state evaluation. No CDM Cooldown hooks needed.
  -- Mark cooldown/utility frames as event-driven (SPELL_UPDATE_COOLDOWN + shadow OnCooldownDone).
  -- MUST run every EnhanceFrame call (not just _arcInitialized) so frames reassigned
  -- to a new spell after first enhancement get the flag restored after it was cleared.
  if viewerType == "cooldown" or viewerType == "utility" then
    frame._arcCooldownEventDriven = true
    -- Cache aura active glow flag so event-driven early return can check cheaply
    local iconCfg = GetIconSettings(cdID)
    frame._arcHasAuraActiveGlow = iconCfg and iconCfg.auraActiveState and (iconCfg.auraActiveState.glow == true or iconCfg.auraActiveState.glowWhenMissing == true) or false

    -- Per-frame event listener installed by CooldownState.EnsureShadow
  end

  -- Store viewerType on frame (updated every enhance call in case of spec switch)
  -- Used by OnCooldownDone hook to filter cooldown/utility frames
  frame._arcViewerType = viewerType
  
  -- ═══════════════════════════════════════════════════════════════════
  -- COOLDOWN SPELL ID CACHE - Cache spellID out of combat for event-driven updates
  -- We read cooldownInfo here (non-secret out of combat) and store for later use
  -- ═══════════════════════════════════════════════════════════════════
  if (viewerType == "cooldown" or viewerType == "utility") and not InCombatLockdown() then
    local cooldownInfo = frame.cooldownInfo
    if cooldownInfo then
      local spellID = cooldownInfo.overrideSpellID or cooldownInfo.spellID
      if spellID then
        frame._arcCachedSpellID = spellID
        -- Also cache initial duration objects (ignoreGCD=true for GCD-free readings)
        if C_Spell.GetSpellCooldownDuration then
          local durObj = C_Spell.GetSpellCooldownDuration(spellID, true)
            frame._arcCachedCooldownDuration = durObj
        end
        if C_Spell.GetSpellChargeDuration then
          local chargeObj = C_Spell.GetSpellChargeDuration(spellID, true)
            frame._arcCachedChargeDuration = chargeObj
        end
      end
    end
  end
  
  -- Update overlay cdID reference
  if frame._arcOverlay then
    frame._arcOverlay._cdID = cdID
  end
  
  -- NOTE: Scale/size enforcement removed - CDMGroups handles all of that
  -- CDMEnhance only provides settings via GetEffectiveIconSettings
  
  -- Always apply icon style (borders, glow, textures - NOT position/scale/size)
  ApplyIconStyle(frame, cdID)
  
  -- ALPHA PROTECTION: CDM widget updates in ApplyIconStyle (SetDrawSwipe, SetReverse, etc.)
  -- can trigger CDM internal code that overrides frame alpha (e.g., new icons like cdID 164597
  -- where CDM initializes at alpha 0). Re-apply CooldownState's last known good alpha
  -- to prevent CDM override. Only applies on re-enhancement (first run has no _lastAppliedAlpha).
  if frame._lastAppliedAlpha and frame._lastAppliedAlpha > 0 then
    frame._arcBypassFrameAlphaHook = true
    frame:SetAlpha(frame._lastAppliedAlpha)
    frame._arcBypassFrameAlphaHook = false
  end
  
  -- Create/update text drag overlays
  local cfg = GetEffectiveIconSettingsForFrame(frame)
  if cfg then
    if frame._arcChargeText then
      CreateTextDragOverlay(frame._arcChargeText, frame, cdID, "charge")
    end
    -- Also create drag overlay for Arc Auras Count text (item stack counts)
    if frame.Count and (frame._arcConfig or frame._arcAuraID) then
      CreateTextDragOverlay(frame.Count, frame, cdID, "charge")
    end
    if frame._arcCooldownText then
      CreateTextDragOverlay(frame._arcCooldownText, frame, cdID, "cooldown")
    end
  end
  UpdateOverlayState(frame)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- INITIAL STATE BOOTSTRAP - Fire an initial cooldown event dispatch
  -- to feed shadow CDs, apply CooldownState visuals, and start usable
  -- glow on first enhancement. Without this, frames sit in default
  -- state until the next SPELL_UPDATE_COOLDOWN event fires.
  -- Deferred by one frame so all hooks/overlays are fully set up.
  -- ═══════════════════════════════════════════════════════════════════
  if (viewerType == "cooldown" or viewerType == "utility") and not InCombatLockdown() then
    C_Timer.After(0, function()
      if frame and frame._arcEnhanced then
        -- Apply initial visuals. CooldownState's per-frame event listener owns feeding.
        local cfg = GetEffectiveIconSettingsForFrame(frame)
        if cfg and ns.CooldownState and ns.CooldownState.Apply then
          ns.CooldownState.Apply(frame, cfg)
        end
      end
    end)
    -- Second pass deferred longer: CDM may not have called SetAuraInstanceInfo/
    -- SetTotemData yet on the first frame after login. Re-evaluate aura active
    -- glow once CDM has had time to push initial aura/totem state to frames.
    local hasAuraGlowCfg = GetIconSettings(cdID)
    hasAuraGlowCfg = hasAuraGlowCfg and hasAuraGlowCfg.auraActiveState
      and (hasAuraGlowCfg.auraActiveState.glow == true or hasAuraGlowCfg.auraActiveState.glowWhenMissing == true)
    if hasAuraGlowCfg then
      C_Timer.After(1.5, function()
        if frame and frame._arcEnhanced then
          local cfg = GetEffectiveIconSettingsForFrame(frame)
          if cfg and ns.CooldownState and ns.CooldownState.Apply then
            ns.CooldownState.Apply(frame, cfg)
          end
        end
      end)
    end
  end
end

-- Export EnhanceFrame for CDMGroups to call when frames change
ns.CDMEnhance.EnhanceFrame = EnhanceFrame

-- ===================================================================
-- SCANNING - Now uses centralized Core.lua scanner
-- CDMEnhance handles frame enhancement after central scan
-- Also tracks detached frames (frames reparented to UIParent for free positioning)
-- ===================================================================

-- Check if a frame reference is still valid (not destroyed/recycled)
local function IsFrameValid(frame)
  if not frame then return false end
  local parent = frame:GetParent()
  return parent ~= nil
end

-- Get all detached frames (for central scanner to include)
function ns.CDMEnhance.GetDetachedFrames()
  -- Delegate to CDMGroups - it tracks all free positioned icons
  if ns.CDMGroups and ns.CDMGroups.GetFreeIcons then
    local freeIcons = ns.CDMGroups.GetFreeIcons()
    local detached = {}
    for cdID, data in pairs(freeIcons) do
      detached[cdID] = {
        cooldownID = cdID,
        frame = data.frame,
        viewerType = data.viewerType,
        viewerName = data.originalViewerName,
      }
    end
    return detached
  end
  return {}  -- CDMGroups not loaded
end

-- Return the enhancedFrames table (used by Core.lua for frame lookup)
function ns.CDMEnhance.GetEnhancedFrames()
  return enhancedFrames
end

-- Return free position frames (delegates to CDMGroups)
function ns.CDMEnhance.GetFreePositionFrames()
  -- Delegate to CDMGroups - it tracks all free positioned icons
  if ns.CDMGroups and ns.CDMGroups.freeIcons then
    local result = {}
    for cdID, data in pairs(ns.CDMGroups.freeIcons) do
      if data.frame then
        result[cdID] = data.frame
      end
    end
    return result
  end
  return {}  -- CDMGroups not loaded
end

-- Return the DB for debug purposes
function ns.CDMEnhance.GetDB()
  return GetDB()
end

-- Find a frame by cooldownID across all CDM viewers (used by Core.lua when tracking fails)
-- SIMPLE: Just scan viewers for a frame where frame.cooldownID matches
function ns.CDMEnhance.FindFrameByCooldownID(cooldownID, viewerType)
  if not cooldownID or cooldownID == 0 then return nil end
  
  -- 1. Check enhancedFrames (fast path)
  local data = enhancedFrames[cooldownID]
  if data and data.frame and IsFrameValid(data.frame) then
    if data.frame.cooldownID == cooldownID then
      return data.frame, data.viewerType, data.viewerName
    end
  end
  
  -- 2. Direct scan of CDM viewers
  local viewerNames
  if viewerType == "aura" then
    viewerNames = {"BuffIconCooldownViewer"}
  elseif viewerType == "cooldown" then
    viewerNames = {"EssentialCooldownViewer"}
  elseif viewerType == "utility" then
    viewerNames = {"UtilityCooldownViewer"}
  else
    -- Search all viewers
    viewerNames = {"BuffIconCooldownViewer", "BuffBarCooldownViewer", "EssentialCooldownViewer", "UtilityCooldownViewer"}
  end
  
  for _, viewerName in ipairs(viewerNames) do
    local viewer = _G[viewerName]
    if viewer then
      local children = {viewer:GetChildren()}
      for _, child in ipairs(children) do
        local frameCdID = child.cooldownID
        if not frameCdID and child.cooldownInfo then
          frameCdID = child.cooldownInfo.cooldownID
        end
        if not frameCdID and child.Icon and child.Icon.cooldownID then
          frameCdID = child.Icon.cooldownID
        end
        if frameCdID == cooldownID then
          local vType = viewerName == "BuffIconCooldownViewer" and "aura" or
                       (viewerName == "BuffBarCooldownViewer" and "aura" or
                       (viewerName == "EssentialCooldownViewer" and "cooldown" or "utility"))
          return child, vType, viewerName
        end
      end
    end
  end
  
  -- 3. Also scan UIParent for free position frames
  -- (They're parented to UIParent but still have valid cooldownID)
  for cdID, eData in pairs(enhancedFrames) do
    if eData.frame and IsFrameValid(eData.frame) then
      if eData.frame.cooldownID == cooldownID then
        return eData.frame, eData.viewerType, eData.viewerName
      end
    end
  end
  
  return nil, nil, nil
end

-- Recovery function: Called when a bar's tracking fails to find its frame
-- Attempts to locate and set up the frame for tracking
function ns.CDMEnhance.RecoverFrameForCooldownID(cooldownID)
  if not cooldownID or cooldownID == 0 then return nil end
  
  local frame, vType, viewerName = ns.CDMEnhance.FindFrameByCooldownID(cooldownID)
  if not frame then return nil end
  
  -- Update our tracking
  enhancedFrames[cooldownID] = {
    frame = frame,
    viewerType = vType,
    viewerName = viewerName,
  }
  
  -- Enhance the frame for styling
  EnhanceFrame(frame, cooldownID, vType, viewerName)
  
  return frame
end

-- Called by Core.lua after central scan completes

function ns.CDMEnhance.OnCDMScanComplete()
  -- MASTER TOGGLE: Skip if disabled
  local groupsDB = Shared.GetCDMGroupsDB()
  if groupsDB and groupsDB.enabled == false then
    return
  end
  
  -- Restore saved Edit Mode scales from DB before sampling
  -- This ensures we have correct scales even if CDM hasn't applied them yet
  RestoreSavedEditModeScales()
  
  -- Get all icons from central scanner and enhance their frames
  local allIcons = ns.API and ns.API.GetAllCDMIcons() or {}
  
  -- Track which cdIDs we've seen in this scan
  local seenCdIDs = {}
  
  -- Sample group scales from CDM frames (overrides restored values if CDM has applied scales)
  -- Only sample from non-free icons (they have CDM's natural scale)
  local scalesSampled = { aura = false, cooldown = false, utility = false }
  
  for cdID, data in pairs(allIcons) do
    seenCdIDs[cdID] = true
    if data.frame then
      -- Sample scale from first suitable icon per viewer type
      local vType = data.viewerType
      if vType and not scalesSampled[vType] then
        local cfg = GetIconSettings(cdID)
        -- Only sample from non-free icons (they have CDM's natural scale)
        if not cfg or not cfg.position or cfg.position.mode ~= "free" then
          local currentScale = data.frame:GetScale()
          if currentScale and currentScale > 0 then
            groupScales[vType] = currentScale
            scalesSampled[vType] = true
          end
        end
      end
      
      EnhanceFrame(data.frame, cdID, data.viewerType, data.viewerName)
      
      -- CDMGroups handles ALL positioning (groups AND free icons)
      -- CDMEnhance only applies styling via EnhanceFrame above
    end
  end
  
  -- Clean up enhancedFrames entries for cdIDs no longer in CDM
  -- CDMGroups handles ALL positioning - we just preserve entries for styling
  for cdID, data in pairs(enhancedFrames) do
    if not seenCdIDs[cdID] then
      -- CDMGroups handles all positioning and tracking
      -- Just preserve enhancedFrames entry for styling purposes
      -- Don't do any position manipulation or cleanup
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- CRITICAL: Also enhance frames in CDMGroups containers
  -- These frames are reparented away from CDM viewers, so the central
  -- API scanner doesn't find them. We need to ensure they're enhanced
  -- so ApplyIconStyle runs (sets up hooks, overlays, borders, etc.)
  -- CDMGroups calls ApplyIconVisuals for visual state handling.
  -- ═══════════════════════════════════════════════════════════════════
  if ns.CDMGroups then
    local cdmGroupsEnhanced = 0
    
    -- Scan group containers
    if ns.CDMGroups.groups then
      for groupName, group in pairs(ns.CDMGroups.groups) do
        if group.members then
          for cdID, member in pairs(group.members) do
            if member.frame and member.frame.cooldownID == cdID then
              -- Check if already enhanced
              local existing = enhancedFrames[cdID]
              if not existing or existing.frame ~= member.frame then
                -- Not enhanced or stale reference - enhance it now
                local viewerType = member.viewerType or "aura"
                local viewerName = member.originalViewerName or "BuffIconCooldownViewer"
                EnhanceFrame(member.frame, cdID, viewerType, viewerName)
                cdmGroupsEnhanced = cdmGroupsEnhanced + 1
              end
            end
          end
        end
      end
    end
    
    -- Scan free icons
    if ns.CDMGroups.freeIcons then
      for cdID, data in pairs(ns.CDMGroups.freeIcons) do
        if data.frame and data.frame.cooldownID == cdID then
          local existing = enhancedFrames[cdID]
          if not existing or existing.frame ~= data.frame then
            local viewerType = data.viewerType or "aura"
            local viewerName = data.originalViewerName or "BuffIconCooldownViewer"
            EnhanceFrame(data.frame, cdID, viewerType, viewerName)
            cdmGroupsEnhanced = cdmGroupsEnhanced + 1
          end
        end
      end
    end
    
    if cdmGroupsEnhanced > 0 and ns.devMode then
      print(string.format("|cff00FF00[ArcUI CDMEnhance]|r Enhanced %d frames from CDMGroups containers", cdmGroupsEnhanced))
    end
  end
  
  if ns.devMode then
    local count = 0
    for cdID, data in pairs(enhancedFrames) do
      count = count + 1
    end
    print(string.format("|cff00FF00[ArcUI CDMEnhance]|r Enhanced %d frames", count))
    print(string.format("|cff00FF00[ArcUI CDMEnhance]|r Group scales (sampled): aura=%.2f, cooldown=%.2f, utility=%.2f", 
      groupScales.aura, groupScales.cooldown, groupScales.utility))
    
    -- Also show override status (now from spec-based storage)
    local specGroupSettings = Shared.GetSpecGroupSettings()
    if specGroupSettings then
      for vType, gs in pairs(specGroupSettings) do
        if gs.scale then
          print(string.format("|cff00FF00[ArcUI CDMEnhance]|r Override ENABLED for %s: scale=%.2f", vType, gs.scale))
        end
      end
    end
  end
  
  -- MASQUE SAFETY: Queue a Masque refresh after scan completes.
  -- Paths like ScanCDM (options panel open) don't go through RefreshAllStyles,
  -- so EnhanceFrame → ApplyIconStyle may run without a subsequent Masque reskin.
  -- This ensures Masque re-applies its icon positioning after any scan.
  if ns.Masque and ns.Masque.QueueRefresh then
    ns.Masque.QueueRefresh()
  end
  
  -- Schedule a delayed rescan to catch late-arriving frames (CDM sometimes creates frames after initial scan)
  C_Timer.After(0.5, function()
    if not InCombatLockdown() then
      -- Force CDM to create any frames that don't exist yet
      ns.CDMEnhance.ForceCDMFrameCreation()
      
      -- Quick scan of CDM viewers for any frames we might have missed
      local viewerConfigs = {
        { name = "BuffIconCooldownViewer", vType = "aura" },
        { name = "EssentialCooldownViewer", vType = "cooldown" },
        { name = "UtilityCooldownViewer", vType = "utility" },
      }
      
      local foundNew = 0
      for _, config in ipairs(viewerConfigs) do
        local viewer = _G[config.name]
        if viewer then
          local children = {viewer:GetChildren()}
          for _, child in ipairs(children) do
            local cdID = child.cooldownID
            if cdID and cdID ~= 0 then
              -- Skip StatusBar frames
              if not (child.Bar and child.Bar.IsObjectType and child.Bar:IsObjectType("StatusBar")) then
                local existing = enhancedFrames[cdID]
                if not existing or existing.frame ~= child then
                  EnhanceFrame(child, cdID, config.vType, config.name)
                  foundNew = foundNew + 1
                end
              end
            end
          end
        end
      end
      
      -- Also trigger CDMGroups to pick up any new frames
      if ns.CDMGroups and ns.CDMGroups.AutoAssignNewIcons then
        ns.CDMGroups.AutoAssignNewIcons()
      end
      
      -- Refresh bar tracking systems
      if ns.API then
        if ns.API.RefreshAll then ns.API.RefreshAll() end
        if ns.API.ScanAvailableBuffs then ns.API.ScanAvailableBuffs() end
        if ns.API.ScanAvailableBarsWithDuration then ns.API.ScanAvailableBarsWithDuration() end
      end
      
      if foundNew > 0 and ns.devMode then
        print(string.format("|cff00FF00[ArcUI CDMEnhance]|r Delayed rescan (0.5s) found %d new frames", foundNew))
      end
    end
  end)
  
  -- Second delayed rescan at 1 second for really late frames
  C_Timer.After(1.0, function()
    if not InCombatLockdown() then
      -- Force CDM to create any remaining frames
      ns.CDMEnhance.ForceCDMFrameCreation()
      
      local viewerConfigs = {
        { name = "BuffIconCooldownViewer", vType = "aura" },
        { name = "EssentialCooldownViewer", vType = "cooldown" },
        { name = "UtilityCooldownViewer", vType = "utility" },
      }
      
      local foundNew = 0
      for _, config in ipairs(viewerConfigs) do
        local viewer = _G[config.name]
        if viewer then
          local children = {viewer:GetChildren()}
          for _, child in ipairs(children) do
            local cdID = child.cooldownID
            if cdID and cdID ~= 0 then
              if not (child.Bar and child.Bar.IsObjectType and child.Bar:IsObjectType("StatusBar")) then
                local existing = enhancedFrames[cdID]
                if not existing or existing.frame ~= child then
                  EnhanceFrame(child, cdID, config.vType, config.name)
                  foundNew = foundNew + 1
                end
              end
            end
          end
        end
      end
      
      if ns.CDMGroups and ns.CDMGroups.AutoAssignNewIcons then
        ns.CDMGroups.AutoAssignNewIcons()
      end
      
      -- Refresh bar tracking systems
      if ns.API then
        if ns.API.RefreshAll then ns.API.RefreshAll() end
        if ns.API.ScanAvailableBuffs then ns.API.ScanAvailableBuffs() end
        if ns.API.ScanAvailableBarsWithDuration then ns.API.ScanAvailableBarsWithDuration() end
      end
      
      if foundNew > 0 and ns.devMode then
        print(string.format("|cff00FF00[ArcUI CDMEnhance]|r Delayed rescan (1.0s) found %d new frames", foundNew))
      end
    end
  end)
end

function ns.CDMEnhance.ScanCDM()
  if InCombatLockdown() then
    return 0, 0
  end
  
  -- MASTER TOGGLE: If disabled, don't scan - leaves addon "blind" to CDM frames
  local groupsDB = Shared.GetCDMGroupsDB()
  if groupsDB and groupsDB.enabled == false then
    return 0, 0
  end
  
  -- Clean up stale enhancedFrames entries BEFORE scan
  -- If a frame was reassigned to a different cooldownID, remove the stale reference
  for cdID, data in pairs(enhancedFrames) do
    if data.frame then
      local frameCdID = data.frame.cooldownID
      -- Only remove if frame has a DIFFERENT valid cooldownID (was definitively reassigned)
      -- nil/0 means CDM hasn't set it yet, so don't remove
      if frameCdID and frameCdID ~= 0 and frameCdID ~= cdID then
        if ns.devMode then
          print(string.format("|cffFF6600[ArcUI]|r Pre-scan cleanup: frame for cdID %d was reassigned to %d", cdID, frameCdID))
        end
        enhancedFrames[cdID] = nil
      elseif not IsFrameValid(data.frame) then
        -- Frame is invalid (destroyed) - clear frame reference
        if ns.devMode then
          print(string.format("|cffFF6600[ArcUI]|r Pre-scan cleanup: frame for cdID %d is invalid", cdID))
        end
        data.frame = nil
      end
    end
  end
  
  -- Call central scanner (which will call OnCDMScanComplete when done)
  local total = ns.API and ns.API.ScanAllCDMIcons() or 0
  
  -- Return counts
  local auraCount, cdCount = ns.API and ns.API.GetCDMIconCount() or 0, 0
  return auraCount, cdCount
end

-- ===================================================================
-- PUBLIC API
-- ===================================================================

-- Force CDM to create all frames for enabled cooldowns
-- CDM lazily creates frames, so we need to call GetItemContainerFrame to ensure they exist
function ns.CDMEnhance.ForceCDMFrameCreation()
  local viewerNames = {"BuffIconCooldownViewer", "EssentialCooldownViewer", "UtilityCooldownViewer"}
  local totalCreated = 0
  
  for _, viewerName in ipairs(viewerNames) do
    local viewer = _G[viewerName]
    if viewer and viewer.GetCooldownIDs and viewer.GetItemContainerFrame then
      local cooldownIDs = viewer:GetCooldownIDs()
      if cooldownIDs then
        for _, cdID in ipairs(cooldownIDs) do
          -- This call creates the frame if it doesn't exist
          local frame = viewer:GetItemContainerFrame(cdID)
          if frame then
            totalCreated = totalCreated + 1
          end
        end
      end
    end
  end
  
  if ns.devMode then
    print(string.format("|cff00FFFF[ArcUI]|r ForceCDMFrameCreation: triggered %d frames", totalCreated))
  end
  
  return totalCreated
end

-- Force show all CDM icons (called by CDMGroups after spec change)
function ns.CDMEnhance.ForceShowAllCDMIcons()
  local viewerNames = {"BuffIconCooldownViewer", "EssentialCooldownViewer", "UtilityCooldownViewer"}
  local shownCount = 0
  
  for _, viewerName in ipairs(viewerNames) do
    local viewer = _G[viewerName]
    if viewer then
      local children = {viewer:GetChildren()}
      for _, child in ipairs(children) do
        if child.cooldownID and child.cooldownID ~= 0 then
          child:SetAlpha(1)
          child:Show()
          shownCount = shownCount + 1
        end
      end
    end
  end
  
  -- Also show frames that might be parented to UIParent (free position icons)
  -- BUT only if they're ACTUALLY tracked as free icons in CDMGroups!
  for cdID, data in pairs(enhancedFrames) do
    if data.frame and IsFrameValid(data.frame) then
      -- Arc Aura spell frames not in current spec are destroyed, not hidden.
      -- No need to check _arcHiddenNotInSpec — they won't be in enhancedFrames.
      local parent = data.frame:GetParent()
      if parent == UIParent then
        -- Only show UIParent frames if CDMGroups is tracking them as free icons
        if ns.CDMGroups and ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[cdID] then
          data.frame:SetAlpha(1)
          data.frame:Show()
        end
        -- Otherwise skip - it's an orphaned frame from spec change
      else
        -- Frame is in a CDM viewer or group container, safe to show
        data.frame:SetAlpha(1)
        data.frame:Show()
      end
    end
  end
  
  if ns.devMode then
    print(string.format("|cff00FF00[ArcUI]|r ForceShowAllCDMIcons: showed %d viewer frames + enhanced frames", shownCount))
  end
end

-- Export UpdateOverlayState for CDMGroups to call when drag mode changes
function ns.CDMEnhance.UpdateOverlayStateForFrame(frame)
  if frame then
    UpdateOverlayState(frame)
  end
end

function ns.CDMEnhance.SetUnlocked(val)
  isUnlocked = val
  local db = GetDB()
  if db then db.unlocked = val end
  
  -- Sync dragModeEnabled with CDMGroups
  if ns.CDMGroups then
    ns.CDMGroups.dragModeEnabled = val
  end
  
  -- Update all enhanced frames overlay states
  for cdID, data in pairs(enhancedFrames) do
    if data.frame then
      UpdateOverlayState(data.frame)
    end
  end
  
  -- Also update CDMGroups managed icons and setup drag handlers
  if ns.CDMGroups and ns.CDMGroups.groups then
    for groupName, group in pairs(ns.CDMGroups.groups) do
      if group.members then
        for cdID, member in pairs(group.members) do
          if member and member.frame then
            UpdateOverlayState(member.frame)
            if val and group.SetupMemberDrag then
              group:SetupMemberDrag(cdID)
            end
          end
        end
      end
    end
  end
  
  -- Update free icons
  if ns.CDMGroups and ns.CDMGroups.freeIcons then
    for cdID, data in pairs(ns.CDMGroups.freeIcons) do
      if data.frame then
        UpdateOverlayState(data.frame)
        if val and ns.CDMGroups.SetupFreeIconDrag then
          ns.CDMGroups.SetupFreeIconDrag(cdID)
        end
      end
    end
  end
  
  -- Refresh click-through state (ShouldMakeClickThrough now checks dragModeEnabled)
  if ns.CDMGroups and ns.CDMGroups.RefreshIconSettings then
    ns.CDMGroups.RefreshIconSettings()
  end
end


function ns.CDMEnhance.ToggleUnlock()
  ns.CDMEnhance.SetUnlocked(not isUnlocked)
end

function ns.CDMEnhance.SetTextDragMode(val)
  textDragMode = val
  local db = GetDB()
  if db then db.textDragMode = val end
  
  for cdID, data in pairs(enhancedFrames) do
    UpdateTextDragOverlays(data.frame)
    -- Also update preview text since it depends on text drag mode
    local cfg = GetIconSettings(cdID)
    if cfg then
      UpdatePreviewText(data.frame, cdID, cfg)
      UpdatePreviewGlow(data.frame, cdID, cfg)
    end
  end
  
end

function ns.CDMEnhance.IsTextDragMode()
  return textDragMode
end


-- ===================================================================
-- COOLDOWN PREVIEW MODE
-- Shows a fake cooldown animation for previewing swipe settings
-- ===================================================================
local function ApplyCooldownPreview(frame, cdID, enable)
  if not frame or not frame.Cooldown then return end
  
  -- Don't preview if Masque controls cooldowns (the options should be hidden anyway)
  if ns.Masque and ns.Masque.ShouldMasqueControlCooldowns and ns.Masque.ShouldMasqueControlCooldowns() then
    return
  end
  
  if enable then
    -- Store that this is a preview so we don't interfere with real cooldowns
    frame._arcSwipePreviewActive = true
    
    -- Get icon settings to apply proper swipe styling
    local cfg = GetIconSettings(cdID)
    local swipeCfg = cfg and cfg.cooldownSwipe
    
    -- Apply swipe settings
    if swipeCfg then
      frame.Cooldown:SetDrawSwipe(swipeCfg.showSwipe ~= false)
      frame.Cooldown:SetDrawEdge(swipeCfg.showEdge ~= false)
      frame.Cooldown:SetDrawBling(swipeCfg.showBling ~= false)
      frame.Cooldown:SetReverse(swipeCfg.reverse == true)
      
      -- Hide/show CooldownFlash frame based on bling setting (alpha-only approach)
      if frame.CooldownFlash then
        if swipeCfg.showBling == false then
          frame.CooldownFlash:SetAlpha(0)
          if frame.CooldownFlash.Flipbook then
            frame.CooldownFlash.Flipbook:SetAlpha(0)
          end
          if frame.CooldownFlash.FlashAnim and frame.CooldownFlash.FlashAnim.Stop then
            frame.CooldownFlash.FlashAnim:Stop()
          end
          frame._arcHideCooldownFlash = true
        else
          -- Re-enable CooldownFlash - clear flag and restore parent frame visibility
          frame._arcHideCooldownFlash = false
          -- Restore parent frame to visible so child animations can be seen
          frame.CooldownFlash:SetAlpha(1)
        end
      end
      
      -- Apply swipe color - use custom if set, otherwise default black
      -- Note: Preview only runs when ArcUI controls cooldowns (Masque check at top of function)
      if swipeCfg.swipeColor then
        local sc = swipeCfg.swipeColor
        frame.Cooldown:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
      else
        -- Default black swipe overlay
        frame.Cooldown:SetSwipeColor(0, 0, 0, 0.7)
      end
      
      if swipeCfg.edgeScale and frame.Cooldown.SetEdgeScale then
        frame.Cooldown:SetEdgeScale(swipeCfg.edgeScale)
      end
      
      if swipeCfg.edgeColor and frame.Cooldown.SetEdgeColor then
        local ec = swipeCfg.edgeColor
        frame.Cooldown:SetEdgeColor(ec.r or 1, ec.g or 1, ec.b or 1, ec.a or 1)
      end
    else
      -- No swipe config at all - use defaults
      frame.Cooldown:SetDrawSwipe(true)
      frame.Cooldown:SetDrawEdge(true)
      frame.Cooldown:SetSwipeColor(0, 0, 0, 0.7)
    end
    
    -- Apply swipe inset for preview
    local swipeInsetX, swipeInsetY = 0, 0
    if swipeCfg then
      if swipeCfg.separateInsets then
        swipeInsetX = swipeCfg.swipeInsetX or 0
        swipeInsetY = swipeCfg.swipeInsetY or 0
      else
        local inset = swipeCfg.swipeInset or 0
        swipeInsetX = inset
        swipeInsetY = inset
      end
    end
    
    -- Calculate total padding for cooldown swipe
    -- When Masque is active, skip icon padding (Masque controls icon)
    -- but still apply our swipe inset
    local basePadding = cfg and cfg.padding or 0
    local masqueActive = ns.Masque and ns.Masque.IsMasqueActiveForType and 
      ns.Masque.IsMasqueActiveForType(enhancedFrames[cdID] and enhancedFrames[cdID].viewerType or "cooldown")
    if masqueActive then
      basePadding = 0  -- Don't add icon padding when Masque controls icon
    end
    local totalPadX = basePadding + swipeInsetX
    local totalPadY = basePadding + swipeInsetY
    
    -- Apply our cooldown positioning with inset
    frame.Cooldown:ClearAllPoints()
    frame.Cooldown:SetPoint("TOPLEFT", frame, "TOPLEFT", totalPadX, -totalPadY)
    frame.Cooldown:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -totalPadX, totalPadY)
    
    -- Set a 30 second cooldown starting now for preview
    local now = GetTime()
    frame.Cooldown:SetCooldown(now, 30)
    frame.Cooldown:Show()
    frame.Cooldown:SetAlpha(1)
    
    -- MASQUE OVERRIDE: Re-apply our cooldown positioning after SetCooldown/Show
    -- Masque hooks these methods and may reposition the cooldown frame
    frame.Cooldown:ClearAllPoints()
    frame.Cooldown:SetPoint("TOPLEFT", frame, "TOPLEFT", totalPadX, -totalPadY)
    frame.Cooldown:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -totalPadX, totalPadY)
    
    -- Also re-apply after a short delay to catch any deferred Masque updates
    C_Timer.After(0.05, function()
      if frame and frame.Cooldown and frame._arcSwipePreviewActive then
        frame.Cooldown:ClearAllPoints()
        frame.Cooldown:SetPoint("TOPLEFT", frame, "TOPLEFT", totalPadX, -totalPadY)
        frame.Cooldown:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -totalPadX, totalPadY)
      end
    end)
  else
    -- Clear the preview
    frame._arcSwipePreviewActive = nil
    frame.Cooldown:Clear()
    
    -- CRITICAL: Reset cached cooldown values so the next OnArcAurasUpdate
    -- will re-apply the real cooldown (the optimization check compares these)
    frame._lastStartTime = nil
    frame._lastDuration = nil
    
    -- Arc Aura spell cooldown frames need an explicit re-feed since their
    -- cooldown engine is event-driven (no CDM to re-push the cooldown)
    if frame._arcIsSpellCooldown and frame._arcAuraID then
      local arcID = frame._arcAuraID
      if ns.ArcAurasCooldown and ns.ArcAurasCooldown.spellData then
        local fd = ns.ArcAurasCooldown.spellData[arcID]
        if fd and ns.ArcAurasCooldown.FeedCooldown then
          C_Timer.After(0.05, function()
            if fd and fd.frame and fd.frame:IsShown() then
              ns.ArcAurasCooldown.FeedCooldown(fd)
            end
          end)
        end
      end
    else
      -- CDM cooldown frame: re-push real cooldown directly so active timers
      -- don't flash empty after preview cleared. One-shot, no polling.
      -- 12.0.1: startTime/duration are secret — use DurationObject instead.
      -- 12.0.5 PTR 4: ignoreGCD=true so the visible swipe matches shadow
      -- semantics (GCD-free duration).
      local spellID = frame.cooldownInfo
        and (frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID)
      if spellID and frame.Cooldown then
        local cdInfo = C_Spell.GetSpellCooldown(spellID)
        if cdInfo and cdInfo.startTime and cdInfo.startTime > 0 then
          local durObj = C_Spell.GetSpellCooldownDuration(spellID, true)
          if durObj then
            frame._arcBypassCDHook = true
            frame.Cooldown:Clear()
            frame.Cooldown:SetCooldownFromDurationObject(durObj)
            frame._arcBypassCDHook = false
          end
        end
      end
    end
  end
end

function ns.CDMEnhance.SetCooldownPreviewMode(val)
  cooldownPreviewMode = val
  
  -- Get all icons being edited (supports edit-all, multi-select, single select)
  local iconsToPreview = {}
  if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.GetAllIconsToUpdate then
    iconsToPreview = ns.CDMEnhanceOptions.GetAllIconsToUpdate()
  else
    -- Fallback to single selection
    local selectedAura, selectedCooldown
    if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.GetSelectedIcon then
      selectedAura, selectedCooldown = ns.CDMEnhanceOptions.GetSelectedIcon()
    end
    if selectedAura then table.insert(iconsToPreview, selectedAura) end
    if selectedCooldown then table.insert(iconsToPreview, selectedCooldown) end
  end
  
  -- Build lookup table for quick checking
  local previewLookup = {}
  for _, cdID in ipairs(iconsToPreview) do
    previewLookup[cdID] = true
  end
  
  -- Apply preview to selected icons in enhancedFrames
  for cdID, data in pairs(enhancedFrames) do
    if previewLookup[cdID] and data.frame then
      ApplyCooldownPreview(data.frame, cdID, val)
    elseif data.frame and data.frame._arcSwipePreviewActive then
      -- Clear preview from non-selected icons
      ApplyCooldownPreview(data.frame, cdID, false)
    end
  end
  
  -- Also apply preview to Arc Auras frames
  if ns.ArcAuras and ns.ArcAuras.frames then
    for arcID, frame in pairs(ns.ArcAuras.frames) do
      if frame then
        if previewLookup[arcID] then
          ApplyCooldownPreview(frame, arcID, val)
        elseif frame._arcSwipePreviewActive then
          ApplyCooldownPreview(frame, arcID, false)
        end
      end
    end
  end
end

function ns.CDMEnhance.IsCooldownPreviewMode()
  return cooldownPreviewMode
end


-- Refresh preview on selected icons (called when selection changes or settings change)
function ns.CDMEnhance.RefreshCooldownPreview()
  if not cooldownPreviewMode then return end
  
  -- Get all icons being edited
  local iconsToPreview = {}
  if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.GetAllIconsToUpdate then
    iconsToPreview = ns.CDMEnhanceOptions.GetAllIconsToUpdate()
  else
    local selectedAura, selectedCooldown
    if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.GetSelectedIcon then
      selectedAura, selectedCooldown = ns.CDMEnhanceOptions.GetSelectedIcon()
    end
    if selectedAura then table.insert(iconsToPreview, selectedAura) end
    if selectedCooldown then table.insert(iconsToPreview, selectedCooldown) end
  end
  
  -- Build lookup table
  local previewLookup = {}
  for _, cdID in ipairs(iconsToPreview) do
    previewLookup[cdID] = true
  end
  
  -- Refresh enhancedFrames
  for cdID, data in pairs(enhancedFrames) do
    if data.frame then
      if previewLookup[cdID] then
        ApplyCooldownPreview(data.frame, cdID, true)
      elseif data.frame._arcSwipePreviewActive then
        ApplyCooldownPreview(data.frame, cdID, false)
      end
    end
  end
  
  -- Also refresh Arc Auras frames
  if ns.ArcAuras and ns.ArcAuras.frames then
    for arcID, frame in pairs(ns.ArcAuras.frames) do
      if frame then
        if previewLookup[arcID] then
          ApplyCooldownPreview(frame, arcID, true)
        elseif frame._arcSwipePreviewActive then
          ApplyCooldownPreview(frame, arcID, false)
        end
      end
    end
  end
end

-- These now just check/set the master toggle in cdmGroups.enabled
function ns.CDMEnhance.SetAuraCustomizationEnabled(val)
  -- Now handled by master toggle
  local db = Shared.GetCDMGroupsDB()
  if db then
    db.enabled = val
    if not val and ns.CDMGroups and ns.CDMGroups.ReleaseAllIcons then
      ns.CDMGroups.ReleaseAllIcons()
    end
  end
end

function ns.CDMEnhance.IsAuraCustomizationEnabled()
  -- Check master toggle
  local db = Shared.GetCDMGroupsDB()
  return db and db.enabled ~= false
end

function ns.CDMEnhance.SetCooldownCustomizationEnabled(val)
  -- Now handled by master toggle
  local db = Shared.GetCDMGroupsDB()
  if db then
    db.enabled = val
    if not val and ns.CDMGroups and ns.CDMGroups.ReleaseAllIcons then
      ns.CDMGroups.ReleaseAllIcons()
    end
  end
end

function ns.CDMEnhance.IsCooldownCustomizationEnabled()
  -- Check master toggle
  local db = Shared.GetCDMGroupsDB()
  return db and db.enabled ~= false
end

function ns.CDMEnhance.GetIconSettings(cdID)
  return GetIconSettings(cdID)
end

-- Get effective icon settings (merged: defaults -> global -> per-icon)
function ns.CDMEnhance.GetEffectiveIconSettings(cdID)
  return GetEffectiveIconSettings(cdID)
end

-- Get or create per-icon settings (for setters - creates sparse entry when needed)
function ns.CDMEnhance.GetOrCreateIconSettings(cdID)
  return GetOrCreateIconSettings(cdID)
end

-- Get global settings for a type (aura or cooldown)
function ns.CDMEnhance.GetGlobalSettings(iconType)
  local db = GetDB()
  if not db then return nil end
  
  if iconType == "aura" then
    return db.globalAuraSettings or {}
  else
    return db.globalCooldownSettings or {}
  end
end

-- Set a global setting value
function ns.CDMEnhance.SetGlobalSetting(iconType, path, value)
  local db = GetDB()
  if not db then return end
  
  local globalSettings
  if iconType == "aura" then
    if not db.globalAuraSettings then db.globalAuraSettings = {} end
    globalSettings = db.globalAuraSettings
  else
    if not db.globalCooldownSettings then db.globalCooldownSettings = {} end
    globalSettings = db.globalCooldownSettings
  end
  
  -- Handle nested paths like "procGlow.enabled"
  local parts = {strsplit(".", path)}
  local target = globalSettings
  for i = 1, #parts - 1 do
    if not target[parts[i]] then target[parts[i]] = {} end
    target = target[parts[i]]
  end
  target[parts[#parts]] = value
  
  -- Invalidate the effective settings cache so icons get new merged values
  InvalidateEffectiveSettingsCache()
end

-- Refresh all icons of a type after global setting change
function ns.CDMEnhance.RefreshIconType(iconType)
  -- Rescan to ensure all frames are captured (utility frames might appear later)
  if not InCombatLockdown() then
    ns.CDMEnhance.ScanCDM()
  end

  InvalidateEffectiveSettingsCache()

  -- Totem-slot frames self-drive (not in the standard cooldown refresh sweep),
  -- so refresh them here too. This is what makes the per-icon glow PREVIEW toggle
  -- — and any other cooldown settings change — actually re-apply to totem icons.
  if (iconType == "cooldown" or iconType == "all") and ns.ArcAurasTotems and ns.ArcAurasTotems.ForceRefreshAll then
    ns.ArcAurasTotems.ForceRefreshAll()
  end

  -- Duration Override re-syncs its enabled-frame registry on cooldown/all refreshes.
  if (iconType == "cooldown" or iconType == "all") and ns.DurationOverride and ns.DurationOverride.RefreshAll then
    ns.DurationOverride.RefreshAll()
  end

  -- Helper to clear all cached visual state flags so ApplyCooldownStateVisuals recalculates
  local function ClearFrameVisualFlags(frame)
    if frame then
      frame._arcTargetAlpha = nil
      frame._arcTargetDesat = nil
      frame._arcTargetTint = nil
      frame._arcTargetGlow = nil
      frame._arcCurrentGlowSig = nil
      frame._arcCDMUsableGlowSig = nil   -- Force usable glow restart with new settings
      frame._arcDesiredVertexColor = nil  -- Release CooldownState vertex color enforcement
      frame._arcDesiredSwipe = nil        -- Release swipe enforcement (let CDM handle)
      frame._arcDesiredEdge = nil         -- Release edge enforcement (let CDM handle)
      frame._arcForceDesatValue = nil     -- Release desat enforcement (let CDM handle)
      frame._arcCooldownEventDriven = nil
      frame._arcHasAuraActiveGlow = nil
      frame._arcAuraEventDriven = nil
      -- CRITICAL: Clear _lastAppliedAlpha so CooldownState doesn't skip SetAlpha
      -- due to stale cache matching the new target value. Without this,
      -- ApplyIconStyle sets alpha=1.0, then CooldownState sees _lastAppliedAlpha=0
      -- matching targetAlpha=0 and skips — leaving the frame stuck at 1.0.
      frame._lastAppliedAlpha = nil
      -- Clear state-change detection cache so next OnCooldownEvent always proceeds
      frame._arcLastShadowShown = nil
      frame._arcLastChargeShown = nil
    end
  end
  
  -- Also refresh CDMGroups frames that might not be in enhancedFrames yet
  if ns.CDMGroups then
    -- Refresh group members
    for groupName, group in pairs(ns.CDMGroups.groups or {}) do
      if group.members then
        for cdID, member in pairs(group.members) do
          if member.frame then
            local vType = member.viewerType or "aura"
            local isAura = vType == "aura"
            local isCooldown = vType == "cooldown" or vType == "utility"
            local shouldRefresh = (iconType == "aura" and isAura) or (iconType == "cooldown" and isCooldown) or iconType == "all"
            
            if shouldRefresh then
              -- CRITICAL: Clear visual flags so ApplyCooldownStateVisuals recalculates
              ClearFrameVisualFlags(member.frame)
              ApplyIconStyle(member.frame, cdID)
              -- ALWAYS apply state visuals to ensure desaturation is cleared/applied
              local cfg = GetEffectiveIconSettingsForFrame(member.frame)
              if cfg then
                ApplyCooldownStateVisuals(member.frame, cfg, cfg.alpha or 1.0)
              end
            end
          end
        end
      end
    end
    
    -- Refresh free icons
    for cdID, data in pairs(ns.CDMGroups.freeIcons or {}) do
      if data.frame then
        local vType = data.viewerType or "aura"
        local isAura = vType == "aura"
        local isCooldown = vType == "cooldown" or vType == "utility"
        local shouldRefresh = (iconType == "aura" and isAura) or (iconType == "cooldown" and isCooldown) or iconType == "all"
        
        if shouldRefresh then
          -- CRITICAL: Clear visual flags so ApplyCooldownStateVisuals recalculates
          ClearFrameVisualFlags(data.frame)
          ApplyIconStyle(data.frame, cdID)
          local cfg = GetEffectiveIconSettingsForFrame(data.frame)
          if cfg then
            ApplyCooldownStateVisuals(data.frame, cfg, cfg.alpha or 1.0)
          end
        end
      end
    end
  end
  
  -- Refresh enhancedFrames
  for cdID, data in pairs(enhancedFrames) do
    -- "cooldown" type refreshes both essential AND utility cooldowns
    local isAura = data.viewerType == "aura"
    local isCooldown = data.viewerType == "cooldown" or data.viewerType == "utility"
    local shouldRefresh = (iconType == "aura" and isAura) or (iconType == "cooldown" and isCooldown) or iconType == "all"
    
    if shouldRefresh and data.frame then
      -- CRITICAL: Clear visual flags so ApplyCooldownStateVisuals recalculates
      ClearFrameVisualFlags(data.frame)
      ApplyIconStyle(data.frame, cdID)
      -- ALWAYS apply state visuals to ensure desaturation is cleared/applied
      local cfg = GetEffectiveIconSettingsForFrame(data.frame)
      if cfg then
        ApplyCooldownStateVisuals(data.frame, cfg, cfg.alpha or 1.0)
      end
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════════════
  -- CRITICAL: Also refresh Arc Auras frames
  -- Arc Auras has its own frame system separate from CDMGroups/enhancedFrames
  -- When aura settings change (aspect ratio, zoom, etc.), we must notify ArcAuras
  -- 
  -- NOTE: Use RefreshAllSettings() NOT RefreshAllFrames()!
  -- RefreshAllFrames() is DESTRUCTIVE - it destroys and recreates frames
  -- RefreshAllSettings() just updates visual settings without losing positions
  -- ═══════════════════════════════════════════════════════════════════════════
  if (iconType == "aura" or iconType == "all") and ns.ArcAuras then
    if ns.ArcAuras.RefreshAllSettings then
      ns.ArcAuras.RefreshAllSettings()
    end
  end
end

-- Reset icon settings to defaults (removes all custom styling)
function ns.CDMEnhance.ResetIconToDefaults(cdID)
  Shared.ClearIconSettings(cdID)
  -- Invalidate cache so icon picks up global settings
  InvalidateEffectiveSettingsCache()
  -- Refresh the icon
  ns.CDMEnhance.UpdateIcon(cdID)
end

-- Check if an icon has per-icon customizations
function ns.CDMEnhance.HasPerIconSettings(cdID)
  local settings = Shared.GetIconSettings(cdID)
  
  -- Check if there are any actual settings stored
  if not settings then return false end
  if not next(settings) then return false end
  
  -- Check if there's anything meaningful (not just empty sub-tables)
  for k, v in pairs(settings) do
    if type(v) ~= "table" then
      -- Found a non-table value (like scale, alpha, etc.)
      return true
    elseif next(v) then
      -- Found a non-empty sub-table
      return true
    end
  end
  
  return false
end

-- Get raw per-icon settings (not merged with defaults) for checking customizations
function ns.CDMEnhance.GetRawPerIconSettings(cdID)
  return Shared.GetIconSettings(cdID)
end

-- Check if any of the specified fields are customized for an icon
-- fields can be top-level keys or deep dot notation like "a.b.c"
function ns.CDMEnhance.HasSectionCustomizations(cdID, fields)
  local raw = ns.CDMEnhance.GetRawPerIconSettings(cdID)
  if not raw then return false end
  
  -- Helper to traverse nested tables using dot notation
  local function getNestedValue(tbl, path)
    local current = tbl
    for key in path:gmatch("[^.]+") do
      if type(current) ~= "table" then return nil end
      current = current[key]
      if current == nil then return nil end
    end
    return current
  end
  
  for _, field in ipairs(fields) do
    local value = getNestedValue(raw, field)
    if value ~= nil then
      -- For tables, check if they have any content
      if type(value) == "table" then
        if next(value) then
          return true
        end
      else
        return true
      end
    end
  end
  
  return false
end

-- Reset all icons of a type to defaults
function ns.CDMEnhance.ResetAllIconsToDefaults(iconType)
  local iconSettings = Shared.GetSpecIconSettings()
  if not iconSettings then return end
  
  local allIcons = ns.API and ns.API.GetAllCDMIcons() or {}
  local count = 0
  for cdID, data in pairs(allIcons) do
    -- "cooldown" type should reset both essential AND utility
    local shouldReset = false
    if not iconType or iconType == "all" then
      shouldReset = true
    elseif iconType == "cooldown" and not data.isAura then
      shouldReset = true
    elseif iconType == "aura" and data.isAura then
      shouldReset = true
    end
    
    if shouldReset then
      iconSettings[tostring(cdID)] = nil
      count = count + 1
    end
  end
  
  -- Invalidate cache so icons pick up global settings
  InvalidateEffectiveSettingsCache()
  ns.CDMEnhance.Refresh()
  return count
end

-- Reset global defaults for a type (aura or cooldown)
function ns.CDMEnhance.ResetGlobalDefaults(iconType)
  local db = GetDB()
  if not db then return end
  
  if iconType == "aura" then
    db.globalAuraSettings = {}
  elseif iconType == "cooldown" then
    db.globalCooldownSettings = {}
  else
    -- Reset both
    db.globalAuraSettings = {}
    db.globalCooldownSettings = {}
  end
  
  -- Invalidate cache and refresh icons
  InvalidateEffectiveSettingsCache()
  ns.CDMEnhance.RefreshIconType(iconType or "all")
end

-- Invalidate settings cache (call after changing settings)
function ns.CDMEnhance.InvalidateCache()
  InvalidateEffectiveSettingsCache()
  
  -- Refresh cached enabled state in case toggle changed
  RefreshCachedEnabledState()
  
  -- Clear cached alpha/desat/tint/glow and cfg on all CDM frames so they recalculate with new settings
  for cdID, data in pairs(enhancedFrames) do
    if data and data.frame then
      data.frame._arcTargetAlpha = nil
      data.frame._arcTargetDesat = nil
      data.frame._arcTargetTint = nil
      data.frame._arcTargetGlow = nil
      data.frame._arcCooldownEventDriven = nil  -- Force re-evaluation
      data.frame._arcHasAuraActiveGlow = nil
      -- NOTE: _arcAuraEventDriven intentionally NOT cleared here.
      -- It is set by AuraFrames.EnhanceAuraFrame and must survive settings changes.
      -- Clearing it here caused aura active glow to never fire after any settings toggle.
      data.frame._arcLastShadowShown = nil       -- Clear state-change cache
      data.frame._arcLastChargeShown = nil
      data.frame._arcCfg = nil                   -- Clear frame-level cfg cache
      data.frame._arcCfgVersion = nil
      data.frame._arcCfgCdID = nil
      data.frame._arcCurrentGlowSig = nil        -- Force glow restart with new settings
      data.frame._arcCDMUsableGlowSig = nil      -- Force usable glow restart too
    end
  end
  
  -- Invalidate ArcAuras settings cache so it fetches fresh settings
  if ns.ArcAuras and ns.ArcAuras.InvalidateSettingsCache then
    ns.ArcAuras.InvalidateSettingsCache()  -- nil = clear all
  end
  
  -- Also clear cache on ArcAuras frames so they pick up new glow/visual settings
  if ns.ArcAuras and ns.ArcAuras.frames then
    for arcID, frame in pairs(ns.ArcAuras.frames) do
      if frame then
        frame._cachedStateVisuals = nil         -- Force stateVisuals refresh
        frame._arcTargetAlpha = nil
        frame._arcTargetDesat = nil
        frame._arcTargetTint = nil
        frame._arcTargetGlow = nil
        frame._arcCurrentGlowSig = nil          -- Force glow restart with new settings
        frame._arcCDMUsableGlowSig = nil        -- Force usable glow restart too
        frame._arcReadyGlowActive = false       -- Reset glow state so it restarts
        frame._arcLastSpellState = nil           -- Bypass state-change early return in ApplySpellStateVisuals
      end
    end
  end
end

-- Get current cache version (used by CDMGroups to validate cached dimensions)
-- Returns a number that increments each time the cache is invalidated
function ns.CDMEnhance.GetCacheVersion()
  return effectiveSettingsCacheVersion
end

-- Invalidate cache for a single icon (call when changing one icon's settings)

-- Check if ArcUI options panel is currently open
function ns.CDMEnhance.IsOptionsPanelOpen()
  -- Use cached value from Shared (updated every 0.25s, avoids expensive LibStub lookups)
  return Shared.IsOptionsPanelOpen()
end

-- Get the addon's group scale setting for a viewer type (1.0 if not set)
function ns.CDMEnhance.GetAddonGroupScale(viewerType)
  local groupSettings = Shared.GetGroupSettingsForType(viewerType)
  if not groupSettings then return 1.0 end
  return groupSettings.scale or 1.0
end

-- Get the current group scale for a viewer type
-- For grouped icons: returns addon scale only (CDM's SetScale multiplies on top)
-- For legacy compatibility

-- Get combined scale (Edit Mode * Addon) - used for free position icons
-- Free position icons are parented to UIParent so they don't get CDM's SetScale
-- We need to apply both scales via SetSize

-- Apply group scale to a specific icon (used when toggling useGroupScale on)
function ns.CDMEnhance.ApplyGroupScaleToIcon(cdID)
  local data = enhancedFrames[cdID]
  if not data or not data.frame then return end
  
  -- Invalidate cache so settings are re-read
  InvalidateEffectiveSettingsCache()
  
  -- Tell CDMGroups to update this icon's size and position
  -- OnIconSizeChanged handles both useGroupScale ON and OFF cases
  if ns.CDMGroups and ns.CDMGroups.OnIconSizeChanged then
    ns.CDMGroups.OnIconSizeChanged(cdID)
  end
  
  -- Re-apply icon style (texcoords, padding, etc.)
  ApplyIconStyle(data.frame, cdID)
end

function ns.CDMEnhance.UpdateIcon(cdID)
  local data = enhancedFrames[cdID]
  
  -- Verify the frame reference is still valid and pointing to the right cooldown
  if data and data.frame then
    -- Check if frame still exists and has the right cooldownID
    if not data.frame.cooldownID or data.frame.cooldownID ~= cdID then
      -- Frame reference is stale, clear it
      data = nil
      enhancedFrames[cdID] = nil
    end
  end
  
  -- If not in enhancedFrames or stale, find the frame directly
  if not data or not data.frame then
    -- FIRST: Check CDMGroups containers (frames may have been reparented)
    if ns.CDMGroups then
      -- Check group containers
      if ns.CDMGroups.groups then
        for groupName, group in pairs(ns.CDMGroups.groups) do
          if group.members and group.members[cdID] then
            local member = group.members[cdID]
            if member.frame and member.frame.cooldownID == cdID then
              local viewerType = member.viewerType or "aura"
              local viewerName = member.originalViewerName or "BuffIconCooldownViewer"
              EnhanceFrame(member.frame, cdID, viewerType, viewerName)
              data = enhancedFrames[cdID]
              break
            end
          end
        end
      end
      
      -- Check free icons
      if (not data or not data.frame) and ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[cdID] then
        local freeData = ns.CDMGroups.freeIcons[cdID]
        if freeData.frame and freeData.frame.cooldownID == cdID then
          local viewerType = freeData.viewerType or "aura"
          local viewerName = freeData.originalViewerName or "BuffIconCooldownViewer"
          EnhanceFrame(freeData.frame, cdID, viewerType, viewerName)
          data = enhancedFrames[cdID]
        end
      end
    end
    
    -- SECOND: Try to find in BuffIconCooldownViewer
    if not data or not data.frame then
      local viewer = _G["BuffIconCooldownViewer"]
      if viewer then
        for _, frame in ipairs({viewer:GetChildren()}) do
          if frame.cooldownID == cdID then
            -- Enhance it now if we found it
            EnhanceFrame(frame, cdID, "aura", "BuffIconCooldownViewer")
            data = enhancedFrames[cdID]
            break
          end
        end
      end
    end
    
    -- THIRD: Try cooldown viewers if still not found
    if not data or not data.frame then
      local cdViewers = {
        {name = "EssentialCooldownViewer", viewerType = "cooldown"},
        {name = "UtilityCooldownViewer", viewerType = "utility"},
      }
      for _, viewerInfo in ipairs(cdViewers) do
        local cdViewer = _G[viewerInfo.name]
        if cdViewer then
          for _, frame in ipairs({cdViewer:GetChildren()}) do
            if frame.cooldownID == cdID then
              EnhanceFrame(frame, cdID, viewerInfo.viewerType, viewerInfo.name)
              data = enhancedFrames[cdID]
              break
            end
          end
        end
        if data and data.frame then break end
      end
    end
  end
  
  if data and data.frame then
    -- Clear glow signature to force restart with new settings
    data.frame._arcCurrentGlowSig = nil
    data.frame._arcCDMUsableGlowSig = nil
    
    ApplyIconStyle(data.frame, cdID)
    
    -- Arc Aura spell frames: trigger FeedCooldown to re-evaluate visuals
    -- ApplyIconVisuals returns early for these, so we drive it through their engine
    if data.frame._arcIsSpellCooldown and data.frame._arcAuraID then
      local arcID = data.frame._arcAuraID
      -- Invalidate ArcAuras settings cache so new values propagate
      if ns.ArcAuras and ns.ArcAuras.InvalidateSettingsCache then
        ns.ArcAuras.InvalidateSettingsCache(arcID)
      end
      -- Clear state-change detection so visuals re-apply even if spell state unchanged
      data.frame._arcLastSpellState = nil
      if ns.ArcAurasCooldown and ns.ArcAurasCooldown.spellData then
        local fd = ns.ArcAurasCooldown.spellData[arcID]
        if fd and ns.ArcAurasCooldown.FeedCooldown then
          ns.ArcAurasCooldown.FeedCooldown(fd)
        end
      end
    else
      -- Re-evaluate glow state (for preview toggle, etc.)
      ns.CDMEnhance.ApplyIconVisuals(data.frame)
    end
    
    -- Trigger immediate CDMGroups layout refresh if icon is in a group
    if ns.CDMGroups and ns.CDMGroups.RefreshIconLayout then
      ns.CDMGroups.RefreshIconLayout(cdID)
    end
    
    -- Recreate text drag overlays if needed
    local cfg = GetIconSettings(cdID)
    if cfg then
      if data.frame._arcChargeText then
        CreateTextDragOverlay(data.frame._arcChargeText, data.frame, cdID, "charge")
      end
      -- Arc Auras Count text
      if data.frame.Count and (data.frame._arcConfig or data.frame._arcAuraID) then
        CreateTextDragOverlay(data.frame.Count, data.frame, cdID, "charge")
      end
      if data.frame._arcCooldownText then
        CreateTextDragOverlay(data.frame._arcCooldownText, data.frame, cdID, "cooldown")
      end
    end
    
    UpdateTextDragOverlays(data.frame)
  end
end

function ns.CDMEnhance.GetAuraIcons()
  -- MASTER TOGGLE: Return empty if CDM styling is disabled
  local groupsDB = Shared.GetCDMGroupsDB()
  if groupsDB and groupsDB.enabled == false then
    return {}
  end
  
  local result = {}
  
  -- First try the API if available
  local allIcons = ns.API and ns.API.GetCDMAuraIcons and ns.API.GetCDMAuraIcons() or {}
  
  for cdID, data in pairs(allIcons) do
    -- Skip BuffBarCooldownViewer frames - we only want icons, not bars
    local viewerName = data.viewerName or ""
    if viewerName ~= "BuffBarCooldownViewer" then
      -- Get frame for icon texture retrieval
      local frame = nil
      local displaySpellID = data.spellID
      local overrideTooltipSpellID = nil
      local frameData = enhancedFrames[cdID]
      -- VERIFY: Only use enhancedFrames data if frame.cooldownID matches cdID
      if frameData and frameData.frame and frameData.frame.cooldownID == cdID then
        frame = frameData.frame
        local cooldownInfo = frame.cooldownInfo
        if cooldownInfo then
          if cooldownInfo.overrideSpellID then
            displaySpellID = cooldownInfo.overrideSpellID
          end
          -- Get overrideTooltipSpellID - this is what CDM uses for display
          overrideTooltipSpellID = cooldownInfo.overrideTooltipSpellID
        end
      end
      
      -- Use helper to get icon texture (reads from frame first, then API)
      local icon = GetIconTextureFromFrame(frame, true, data.spellID, displaySpellID, displaySpellID, overrideTooltipSpellID)
      
      -- Check if this is a totem-based icon
      local isTotem, isTotemActive, totemSlot = false, false, nil
      if frame then
        isTotem, isTotemActive, totemSlot = GetTotemState(frame)
      end
      
      result[cdID] = {
        cooldownID = cdID,
        spellID = data.spellID,
        overrideSpellID = displaySpellID ~= data.spellID and displaySpellID or nil,
        name = displaySpellID and C_Spell.GetSpellName(displaySpellID) or data.name or "Unknown",
        icon = icon,
        hasCustomPos = HasCustomPosition(cdID),
        viewerName = viewerName,
        isTotem = isTotem,
        totemSlot = totemSlot,
      }
    end
  end
  
  -- Also check enhancedFrames for aura icons (fallback/additional)
  -- CRITICAL: Verify frame.cooldownID matches cdID to avoid stale references
  for cdID, frameData in pairs(enhancedFrames) do
    if frameData.viewerType == "aura" and not result[cdID] then
      -- Skip BuffBarCooldownViewer
      local viewerName = frameData.viewerName or ""
      if viewerName ~= "BuffBarCooldownViewer" then
        local frame = frameData.frame
        -- VERIFY: frame.cooldownID must match cdID (skip stale entries)
        if frame and frame.cooldownID == cdID then
          local spellID = frame.spellID
          -- Check for overrideSpellID and overrideTooltipSpellID
          local displaySpellID = spellID
          local overrideTooltipSpellID = nil
          if frame.cooldownInfo then
            if frame.cooldownInfo.overrideSpellID then
              displaySpellID = frame.cooldownInfo.overrideSpellID
            end
            overrideTooltipSpellID = frame.cooldownInfo.overrideTooltipSpellID
          end
          local name = displaySpellID and C_Spell.GetSpellName(displaySpellID) or "Unknown"
          -- Use helper to get icon texture (reads from frame first)
          local icon = GetIconTextureFromFrame(frame, true, spellID, displaySpellID, displaySpellID, overrideTooltipSpellID)
          
          -- Check if this is a totem-based icon
          local isTotem, isTotemActive, totemSlot = GetTotemState(frame)
          
          result[cdID] = {
            cooldownID = cdID,
            spellID = spellID,
            overrideSpellID = displaySpellID ~= spellID and displaySpellID or nil,
            name = name,
            icon = icon,
            hasCustomPos = HasCustomPosition(cdID),
            viewerName = viewerName,
            isTotem = isTotem,
            totemSlot = totemSlot,
          }
        end
      end
    end
  end
  
  -- ALSO check CDMGroups containers - icons parented there won't be in CDM viewers
  if ns.CDMGroups and ns.CDMGroups.groups then
    for groupName, group in pairs(ns.CDMGroups.groups) do
      if group.members then
        for cdID, member in pairs(group.members) do
          if not result[cdID] and member.frame and member.frame.cooldownID == cdID then
            -- Only include aura icons (BuffIcon), not cooldowns
            local viewerType = member.viewerType
            local viewerName = member.originalViewerName
            
            -- Skip BuffBarCooldownViewer
            if viewerName == "BuffBarCooldownViewer" then
              -- Skip bars
            else
              -- Determine if this is an aura icon by checking CDM category or viewerType
              local isAuraIcon = false
              if viewerType == "aura" then
                isAuraIcon = true
              elseif viewerName == "BuffIconCooldownViewer" then
                isAuraIcon = true
              else
                -- Check CDM category as fallback (safe for Arc Aura string IDs)
                if cdID and cdID ~= 0 then
                  local cdInfo = Shared.SafeGetCDMInfo and Shared.SafeGetCDMInfo(cdID)
                  if cdInfo and Shared.IsAuraCategory(cdInfo.category) then
                    isAuraIcon = true
                    viewerName = "BuffIconCooldownViewer"
                  end
                end
              end
              
              if isAuraIcon then
                local frame = member.frame
                local spellID = frame.spellID
                local displaySpellID = spellID
                local overrideTooltipSpellID = nil
                if frame.cooldownInfo then
                  if frame.cooldownInfo.overrideSpellID then
                    displaySpellID = frame.cooldownInfo.overrideSpellID
                  end
                  overrideTooltipSpellID = frame.cooldownInfo.overrideTooltipSpellID
                end
                local name = displaySpellID and C_Spell.GetSpellName(displaySpellID) or "Unknown"
                -- Use helper to get icon texture (reads from frame first)
                local icon = GetIconTextureFromFrame(frame, true, spellID, displaySpellID, displaySpellID, overrideTooltipSpellID)
                
                -- Check if this is a totem-based icon
                local isTotem, isTotemActive, totemSlot = GetTotemState(frame)
                
                result[cdID] = {
                  cooldownID = cdID,
                  spellID = spellID,
                  overrideSpellID = displaySpellID ~= spellID and displaySpellID or nil,
                  name = name,
                  icon = icon,
                  hasCustomPos = true,
                  viewerName = viewerName or "BuffIconCooldownViewer",
                  isTotem = isTotem,
                  totemSlot = totemSlot,
                }
              end
            end
          end
        end
      end
    end
  end
  
  -- ALSO check CDMGroups.freeIcons - these are managed by CDMGroups but free-positioned
  if ns.CDMGroups and ns.CDMGroups.freeIcons then
    for cdID, data in pairs(ns.CDMGroups.freeIcons) do
      if not result[cdID] and data.frame and data.frame.cooldownID == cdID then
        local viewerType = data.viewerType
        local viewerName = data.originalViewerName
        
        -- Skip BuffBarCooldownViewer
        if viewerName ~= "BuffBarCooldownViewer" then
          -- Determine if this is an aura icon
          local isAuraIcon = false
          if viewerType == "aura" then
            isAuraIcon = true
          elseif viewerName == "BuffIconCooldownViewer" then
            isAuraIcon = true
          else
            -- Check CDM category as fallback (safe for Arc Aura string IDs)
            if cdID and cdID ~= 0 then
              local cdInfo = Shared.SafeGetCDMInfo and Shared.SafeGetCDMInfo(cdID)
              if cdInfo and Shared.IsAuraCategory(cdInfo.category) then
                isAuraIcon = true
                viewerName = "BuffIconCooldownViewer"
              end
            end
          end
          
          if isAuraIcon then
            local frame = data.frame
            local spellID = frame.spellID
            local displaySpellID = spellID
            local overrideTooltipSpellID = nil
            if frame.cooldownInfo then
              if frame.cooldownInfo.overrideSpellID then
                displaySpellID = frame.cooldownInfo.overrideSpellID
              end
              overrideTooltipSpellID = frame.cooldownInfo.overrideTooltipSpellID
            end
            local name = displaySpellID and C_Spell.GetSpellName(displaySpellID) or "Unknown"
            -- Use helper to get icon texture (reads from frame first)
            local icon = GetIconTextureFromFrame(frame, true, spellID, displaySpellID, displaySpellID, overrideTooltipSpellID)
            
            -- Check if this is a totem-based icon
            local isTotem, isTotemActive, totemSlot = GetTotemState(frame)
            
            result[cdID] = {
              cooldownID = cdID,
              spellID = spellID,
              overrideSpellID = displaySpellID ~= spellID and displaySpellID or nil,
              name = name,
              icon = icon,
              hasCustomPos = true,
              viewerName = viewerName or "BuffIconCooldownViewer",
              isTotem = isTotem,
              totemSlot = totemSlot,
            }
          end
        end
      end
    end
  end
  
  return result
end

-- Helper for Arc Aura catalog entries - delegates to ArcAuras module
local function CreateArcAuraEntry(cdID, frame)
    if ns.ArcAuras and ns.ArcAuras.CreateCatalogEntry then
        return ns.ArcAuras.CreateCatalogEntry(cdID, frame)
    end
    return nil
end

function ns.CDMEnhance.GetCooldownIcons()
  -- MASTER TOGGLE: Return empty if CDM styling is disabled
  local groupsDB = Shared.GetCDMGroupsDB()
  if groupsDB and groupsDB.enabled == false then
    return {}
  end
  
  local result = {}
  local allIcons = ns.API and ns.API.GetCDMCooldownIcons() or {}
  
  for cdID, data in pairs(allIcons) do
    -- Check for overrideSpellID in the frame's cooldownInfo
    local displaySpellID = data.spellID
    local frame = nil
    local frameData = enhancedFrames[cdID]
    -- VERIFY: Only use enhancedFrames data if frame.cooldownID matches cdID
    if frameData and frameData.frame and frameData.frame.cooldownID == cdID then
      frame = frameData.frame
      if frame.cooldownInfo then
        local overrideID = frame.cooldownInfo.overrideSpellID
        if overrideID and overrideID > 0 then
          displaySpellID = overrideID
        end
      end
    end
    
    -- Use helper to get icon texture (reads from frame first, isAura=false for cooldowns)
    local icon = GetIconTextureFromFrame(frame, false, data.spellID, displaySpellID, displaySpellID)
    
    result[cdID] = {
      cooldownID = cdID,
      spellID = data.spellID,
      overrideSpellID = displaySpellID ~= data.spellID and displaySpellID or nil,
      name = displaySpellID and C_Spell.GetSpellName(displaySpellID) or data.name or "Unknown",
      icon = icon,
      hasCustomPos = HasCustomPosition(cdID),
      viewerName = data.viewerName,
    }
  end
  
  -- ALSO check CDMGroups containers - icons parented there won't be in CDM viewers
  if ns.CDMGroups and ns.CDMGroups.groups then
    for groupName, group in pairs(ns.CDMGroups.groups) do
      if group.members then
        for cdID, member in pairs(group.members) do
          if not result[cdID] and member.frame and member.frame.cooldownID == cdID then
            -- Handle Arc Auras (string IDs) - item-based cooldowns
            if Shared.IsArcAuraID and Shared.IsArcAuraID(cdID) then
              local arcEntry = CreateArcAuraEntry(cdID, member.frame)
              if arcEntry then
                result[cdID] = arcEntry
              end
            else
              -- Only include cooldown icons (Essential/Utility), not auras
              local viewerType = member.viewerType
              local viewerName = member.originalViewerName
              
              -- Determine if this is a cooldown icon by checking CDM category or viewerType
              local isCooldownIcon = false
              if viewerType == "cooldown" or viewerType == "utility" then
                isCooldownIcon = true
              elseif viewerName == "EssentialCooldownViewer" or viewerName == "UtilityCooldownViewer" then
                isCooldownIcon = true
              else
                -- Check CDM category as fallback (safe for Arc Aura string IDs)
                if cdID and cdID ~= 0 then
                  local cdInfo = Shared.SafeGetCDMInfo and Shared.SafeGetCDMInfo(cdID)
                  if cdInfo and (cdInfo.category == 0 or cdInfo.category == 1) then
                    isCooldownIcon = true
                    -- Set viewerName based on category
                    viewerName = cdInfo.category == 0 and "EssentialCooldownViewer" or "UtilityCooldownViewer"
                  end
                end
              end
              
              if isCooldownIcon then
                local frame = member.frame
                local spellID = frame.spellID
                local displaySpellID = spellID
                if frame.cooldownInfo and frame.cooldownInfo.overrideSpellID then
                  displaySpellID = frame.cooldownInfo.overrideSpellID
                end
                local name = displaySpellID and C_Spell.GetSpellName(displaySpellID) or "Unknown"
                -- Use helper to get icon texture (reads from frame first, isAura=false for cooldowns)
                local icon = GetIconTextureFromFrame(frame, false, spellID, displaySpellID, displaySpellID)
                
                result[cdID] = {
                  cooldownID = cdID,
                  spellID = spellID,
                  overrideSpellID = displaySpellID ~= spellID and displaySpellID or nil,
                  name = name,
                  icon = icon,
                  hasCustomPos = true,
                  viewerName = viewerName or "EssentialCooldownViewer",
                }
              end
            end
          end
        end
      end
    end
  end
  
  -- ALSO check CDMGroups.freeIcons - these are managed by CDMGroups but free-positioned
  if ns.CDMGroups and ns.CDMGroups.freeIcons then
    for cdID, data in pairs(ns.CDMGroups.freeIcons) do
      if not result[cdID] and data.frame and data.frame.cooldownID == cdID then
        -- Handle Arc Auras (string IDs) - item-based cooldowns
        if Shared.IsArcAuraID and Shared.IsArcAuraID(cdID) then
          local arcEntry = CreateArcAuraEntry(cdID, data.frame)
          if arcEntry then
            result[cdID] = arcEntry
          end
        else
          local viewerType = data.viewerType
          local viewerName = data.originalViewerName
          
          -- Determine if this is a cooldown icon
          local isCooldownIcon = false
          if viewerType == "cooldown" or viewerType == "utility" then
            isCooldownIcon = true
          elseif viewerName == "EssentialCooldownViewer" or viewerName == "UtilityCooldownViewer" then
            isCooldownIcon = true
          else
            -- Check CDM category as fallback (safe for Arc Aura string IDs)
            if cdID and cdID ~= 0 then
              local cdInfo = Shared.SafeGetCDMInfo and Shared.SafeGetCDMInfo(cdID)
              if cdInfo and (cdInfo.category == 0 or cdInfo.category == 1) then
                isCooldownIcon = true
                viewerName = cdInfo.category == 0 and "EssentialCooldownViewer" or "UtilityCooldownViewer"
              end
            end
          end
          
          if isCooldownIcon then
            local frame = data.frame
            local spellID = frame.spellID
            local displaySpellID = spellID
            if frame.cooldownInfo and frame.cooldownInfo.overrideSpellID then
              displaySpellID = frame.cooldownInfo.overrideSpellID
            end
            local name = displaySpellID and C_Spell.GetSpellName(displaySpellID) or "Unknown"
            -- Use helper to get icon texture (reads from frame first, isAura=false for cooldowns)
            local icon = GetIconTextureFromFrame(frame, false, spellID, displaySpellID, displaySpellID)
            
            result[cdID] = {
              cooldownID = cdID,
              spellID = spellID,
              overrideSpellID = displaySpellID ~= spellID and displaySpellID or nil,
              name = name,
              icon = icon,
              hasCustomPos = true,
              viewerName = viewerName or "EssentialCooldownViewer",
            }
          end
        end
      end
    end
  end
  
  return result
end

function ns.CDMEnhance.Refresh()
  -- Rescan to ensure all frames are captured (utility frames might appear later)
  if not InCombatLockdown() then
    ns.CDMEnhance.ScanCDM()
  end
  
  for cdID, data in pairs(enhancedFrames) do
    ApplyIconStyle(data.frame, cdID)
    UpdateOverlayState(data.frame)
  end
end

-- Refresh overlay mouse states (called when options panel opens/closes)
function ns.CDMEnhance.RefreshOverlayMouseState()
  for cdID, data in pairs(enhancedFrames) do
    local frame = data.frame
    if frame then
      UpdateOverlayState(frame)
      local cfg = GetIconSettings(cdID)
      if cfg then
        UpdatePreviewText(frame, cdID, cfg)
        UpdatePreviewGlow(frame, cdID, cfg)
        local sv = GetEffectiveStateVisuals(cfg)
        local ignAura = (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
                     or (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)
        if sv or ignAura then
          frame._arcTargetAlpha = nil
          frame._arcEnforceReadyAlpha = nil
          ApplyCooldownStateVisuals(frame, cfg, cfg.alpha or 1.0)
        end
      end
      local effectiveCfg = GetEffectiveIconSettings(cdID)
      if (effectiveCfg and effectiveCfg._isAura)
          or (data.viewerType == "aura")
          or (frame._arcAuraStateHooked == true)
          or (frame.totemData ~= nil)
          or (frame.wasSetFromAura == true) then
        frame._arcTargetAlpha       = nil
        frame._arcEnforceReadyAlpha = nil
        frame._arcLastOptimizedCall = nil
        frame._arcLastAuraActive    = nil
        if ns.AuraFrames and ns.AuraFrames.UpdateAuraFrame then
          ns.AuraFrames.UpdateAuraFrame(frame)
        end
      end
    end
  end
end

function ns.CDMEnhance.ResetAllCooldownPositions()
  -- Reset all cooldown icons to group mode
  for cdID, data in pairs(enhancedFrames) do
    if (data.viewerType == "cooldown" or data.viewerType == "utility") and data.frame then
      ResetIconPosition(cdID)
    end
  end
end

function ns.CDMEnhance.ResetAllAuraPositions()
  -- Reset all aura icons to group mode
  for cdID, data in pairs(enhancedFrames) do
    if data.viewerType == "aura" and data.frame then
      ResetIconPosition(cdID)
    end
  end
end

-- Reset ALL icon positions (both auras and cooldowns)

-- Get first icon of a given type (for default X/Y display)
function ns.CDMEnhance.GetFirstIconOfType(viewerType)
  for cdID, data in pairs(enhancedFrames) do
    if data.viewerType == viewerType then
      return cdID
    end
  end
  return nil
end


-- ===================================================================
-- GROUP POSITION API - Delegates to CDMGroupSettings module
-- ===================================================================

-- Disable all drag options (called when options panel closes)
function ns.CDMEnhance.DisableAllDrags()
  -- Disable individual icon unlock (use SetUnlocked to save and refresh)
  if isUnlocked then
    ns.CDMEnhance.SetUnlocked(false)
  end
  
  -- Disable text drag mode too
  if textDragMode then
    ns.CDMEnhance.SetTextDragMode(false)
  end
  
  -- Hide group mover overlay
  if ns.CDMGroupSettings then
    ns.CDMGroupSettings.HideMoverOverlay()
    ns.CDMGroupSettings.HideSettingsDialog()
  end
  
  -- Refresh options panel to update toggle states
  if LibStub and LibStub("AceConfigRegistry-3.0", true) then
    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
  end
end

-- Clear slot base positions (called when group moves so they get recaptured)
-- Refresh all icon styles (called after Edit Mode/mover closes)
function ns.CDMEnhance.RefreshAllStyles()
  -- MASTER TOGGLE: Skip if disabled
  local groupsDB = Shared.GetCDMGroupsDB()
  if groupsDB and groupsDB.enabled == false then
    return
  end
  
  -- Invalidate cache first to ensure fresh settings from DB
  InvalidateEffectiveSettingsCache()
  
  for cdID, data in pairs(enhancedFrames) do
    if data.frame then
      -- NOTE: Scale/size/position handled by CDMGroups
      -- We only refresh visual styles (borders, glow, textures)
      ApplyIconStyle(data.frame, cdID)
      
      -- CRITICAL FIX: Also apply cooldown state visuals (ready state alpha, etc.)
      -- Without this, ready state alpha=0 is not applied until options panel is opened
      -- Clear cached alpha flags so they get recalculated from fresh settings
      data.frame._arcTargetAlpha = nil
      data.frame._arcEnforceReadyAlpha = nil
      local cfg = GetEffectiveIconSettingsForFrame(data.frame)
      if cfg then
        ApplyCooldownStateVisuals(data.frame, cfg, cfg.alpha or 1.0)
      end
    end
  end
  
  -- Refresh Masque skins after style changes
  -- Masque.RefreshAllGroups will re-apply our cooldown positioning after Masque finishes
  if ns.Masque and ns.Masque.QueueRefresh then
    ns.Masque.QueueRefresh()
  end
end

-- ═══════════════════════════════════════════════════════════════════════
-- FORCE REFRESH ALL VISUAL STATES
-- Clears ALL cached visual flags (alpha, desat, tint, throttle timestamps)
-- and reapplies cooldown/aura state visuals from scratch.
-- Call when: options panel closes, reload completes, frame reassignment.
-- ═══════════════════════════════════════════════════════════════════════
function ns.CDMEnhance.ForceRefreshAllVisualStates()
  -- MASTER TOGGLE: Skip if disabled
  local groupsDB = Shared.GetCDMGroupsDB()
  if groupsDB and groupsDB.enabled == false then return end
  
  -- Invalidate settings cache to get fresh values
  InvalidateEffectiveSettingsCache()
  
  for cdID, data in pairs(enhancedFrames) do
    if data.frame then
      local frame = data.frame
      
      -- Clear ALL cached visual state flags so they get recalculated
      frame._arcTargetAlpha = nil
      frame._arcTargetDesat = nil
      frame._arcTargetTint = nil
      frame._arcEnforceReadyAlpha = nil
      frame._arcLastAuraActive = nil
      frame._lastAppliedAlpha = nil

      -- Clear throttle timestamps so the next call isn't skipped
      frame._arcLastOptimizedCall = nil

      -- Clear frame-level config cache to force fresh lookup
      frame._arcCfg = nil
      frame._arcCfgVersion = nil
      
      -- Reapply state visuals from fresh config
      local cfg = GetEffectiveIconSettingsForFrame(frame)
      if cfg then
        if cfg._isAura or (frame.totemData ~= nil) or (frame.wasSetFromAura == true) then
          -- Aura/totem/wasSetFromAura: UpdateAuraFrame owns alpha including preview opacity.
          if ns.AuraFrames and ns.AuraFrames.UpdateAuraFrame then
            ns.AuraFrames.UpdateAuraFrame(frame)
          end
        else
          ApplyCooldownStateVisuals(frame, cfg, cfg.alpha or 1.0)
        end
      end
    end
  end
end

-- ===================================================================
-- ENHANCED FRAMES ACCESS (for Masque integration)
-- ===================================================================

--- Get the enhanced frames table (read-only access for external modules)
function ns.CDMEnhance.GetEnhancedFrames()
  return enhancedFrames
end

-- PER-ICON POSITION API (New system)
-- ===================================================================

-- Get position mode for a specific icon
function ns.CDMEnhance.GetIconPositionMode(cdID)
  -- Delegate to CDMGroups - it controls where icons are positioned
  if ns.CDMGroups and ns.CDMGroups.IsManaged then
    local isManaged, trackingType = ns.CDMGroups.IsManaged(cdID)
    if isManaged then
      return trackingType == "free" and "free" or "group"
    end
  end
  return "group"  -- Default to group if CDMGroups not loaded or icon not managed
end

-- Get icon position
function ns.CDMEnhance.GetIconPosition(cdID)
  -- Read position from CDMGroups for free positioned icons
  if ns.CDMGroups and ns.CDMGroups.freeIcons then
    local freeData = ns.CDMGroups.freeIcons[cdID]
    if freeData then
      return freeData.x or 0, freeData.y or 0
    end
  end
  return nil, nil  -- Not a free icon or CDMGroups not loaded
end

-- Set icon position (writes to CDMGroups free icon data)
function ns.CDMEnhance.SetIconPosition(cdID, x, y)
  -- Write position to CDMGroups for free positioned icons
  if ns.CDMGroups and ns.CDMGroups.freeIcons then
    local freeData = ns.CDMGroups.freeIcons[cdID]
    if freeData then
      -- Update the runtime position
      freeData.x = x or 0
      freeData.y = y or 0
      
      -- CRITICAL: Save to BOTH storage locations (like drag does)
      -- 1. profile.savedPositions (what LoadProfile reads from)
      local posData = {
        type = "free",
        x = x or 0,
        y = y or 0,
        iconSize = freeData.iconSize or 36,
        viewerType = freeData.viewerType,
      }
      if ns.CDMGroups.SavePositionToSpec then
        ns.CDMGroups.SavePositionToSpec(cdID, posData)
      end
      
      -- 2. profile.freeIcons (secondary storage)
      if ns.CDMGroups.SaveFreeIconToSpec then
        ns.CDMGroups.SaveFreeIconToSpec(cdID, { 
          x = x or 0, 
          y = y or 0, 
          iconSize = freeData.iconSize or 36 
        })
      end
      
      -- Apply position to frame if it exists
      if freeData.frame then
        freeData.frame:ClearAllPoints()
        freeData.frame:SetPoint("CENTER", UIParent, "CENTER", x or 0, y or 0)
      end
    end
  end
end

-- Reset a single icon's position to group mode
function ns.CDMEnhance.ResetIconPosition(cdID)
  ResetIconPosition(cdID)
end

-- ===================================================================
-- DEBUG SLASH COMMANDS
-- ===================================================================

-- Global debug flag
ArcUI_CDMEnhance_Debug = false
ArcUI_CDMEnhance_TintDebug = false

-- ===================================================================
-- INITIALIZATION
-- ===================================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Leaving combat
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Entering combat
-- Proc glow events (spellID in event is non-secret)
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
-- Spell override changes (e.g. Hero Talent swaps, Surging Totem <-> Retract)
-- baseSpellID and overrideSpellID are non-secret in this event
eventFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")


-- ═══════════════════════════════════════════════════════════════════════════
-- PROC GLOW FUNCTIONS (Event-driven like ArcAuras)
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- PROC GLOW CUSTOMIZATION
-- Two approaches based on glowType:
--   "default" = Use CDM's native glow with FlipBook frame dimension override
--   "pixel"/"autocast"/"button" = Hide CDM's glow, show LibCustomGlow instead
-- ═══════════════════════════════════════════════════════════════════════════

-- CDM PROC GLOW SIZING
-- From ActionButtonSpellAlertTemplate XML:
--   ProcLoopFlipbook: setAllPoints="true" (auto-fills container)
--   ProcStartFlipbook: 150x150 for a 45x45 button = 3.33x ratio
-- Strategy: Size the container larger than the icon so the loop glow extends
-- beyond the edges. Let ProcLoopFlipbook fill via setAllPoints.
-- Size ProcStartFlipbook (burst) at 3.33x ratio.
--
-- MASQUE INTEGRATION: When Masque is managing a frame (_MSQ_CFG), it replaces
-- flipbook textures with shape-matched versions (Circle, Hexagon, etc.) via its
-- own ShowAlert hook. However, Masque's sizing is designed for standard 36x36
-- action buttons and breaks ArcUI's custom-sized CDM icons. ArcUI applies Masque
-- shape textures (from _MSQ_CFG.Shape) but ALWAYS controls its own glow sizing.
-- A post-hook in ArcUI_Masque.lua re-applies ArcUI sizing after Masque's hook.

local PROC_LOOP_CONTAINER_RATIO = 66 / 45  -- Same expansion as ants glow (~1.467x)
local PROC_START_BURST_RATIO = 150 / 45    -- Burst intro is 3.33x icon size

-- Helper: Check if frame is Masque-managed with custom skin active
IsMasqueSkinned = function(frame)
  local mcfg = frame._MSQ_CFG
  if not mcfg then return false end
  -- Enabled = Masque is actively skinning this button (not using Blizzard skin)
  return mcfg.Enabled and not mcfg.BaseSkin
end

-- Helper: Call Masque's UpdateSpellAlert API to re-apply shape textures
-- Pass Region explicitly for LCG glows (ButtonGlow, ProcGlow) since they're
-- on an overlay frame, not directly on the CDM icon that has _MSQ_CFG.
TriggerMasqueSpellAlertUpdate = function(frame, region)
  local MasqueLib = LibStub and LibStub("Masque", true)
  if not MasqueLib then return end
  -- Masque exposes UpdateSpellAlert on its API object
  if MasqueLib.UpdateSpellAlert then
    MasqueLib.UpdateSpellAlert(MasqueLib, frame, region)
  end
end

-- ─────────────────────────────────────────────────────────────────────────
-- DIRECT MASQUE SHAPE APPLICATION
-- Masque's UpdateSpellAlert → Skin_FlipBooks has a NeedsUpdate guard that
-- can prevent re-application if Masque already ran its hook. This helper
-- applies shape textures DIRECTLY using Masque's public API, bypassing
-- the caching layer. Works for both Blizzard-template (.ProcStartFlipbook/
-- .ProcLoopFlipbook) and LCG-template (.ProcStart/.ProcLoop) frames.
-- ─────────────────────────────────────────────────────────────────────────

-- Apply Masque shape to a Blizzard SpellActivationAlert (ProcStartFlipbook/ProcLoopFlipbook)
ApplyMasqueProcShapeToAlert = function(frame)
  if not frame or not IsMasqueSkinned(frame) then return end
  local alert = frame.SpellActivationAlert
  if not alert then return end

  local shape = frame._MSQ_CFG and frame._MSQ_CFG.Shape
  if not shape then return end

  local MasqueLib = LibStub and LibStub("Masque", true)
  if not MasqueLib or not MasqueLib.GetSpellAlertFlipBook then return end

  local flipData = MasqueLib.GetSpellAlertFlipBook(MasqueLib, "Modern", shape)
  if not ok or not flipData then
    flipData = MasqueLib.GetSpellAlertFlipBook(MasqueLib, "Classic", shape)
  end
  if not ok or not flipData then return end

  -- Apply loop texture
  if flipData.LoopTexture and alert.ProcLoopFlipbook then
    alert.ProcLoopFlipbook:SetTexture(flipData.LoopTexture)
  end

  -- Apply start texture (use loop as fallback if no dedicated start — Masque pattern)
  if alert.ProcStartFlipbook then
    if flipData.StartTexture then
      alert.ProcStartFlipbook:SetTexture(flipData.StartTexture)
    elseif flipData.LoopTexture then
      alert.ProcStartFlipbook:SetTexture(flipData.LoopTexture)
      alert.ProcStartFlipbook:ClearAllPoints()
      alert.ProcStartFlipbook:SetAllPoints()
    end
  end

  -- Apply flipbook animation dimensions to ProcLoop
  if alert.ProcLoop then
    local loopFlipAnim = alert.ProcLoop.FlipAnim
    if not loopFlipAnim then
      for _, child in pairs({alert.ProcLoop:GetAnimations()}) do
        if child and child.SetFlipBookFrameWidth then loopFlipAnim = child; break end
      end
    end
    if loopFlipAnim and loopFlipAnim.SetFlipBookFrameWidth then
      loopFlipAnim:SetFlipBookFrameWidth(flipData.FrameWidth or 0)
      loopFlipAnim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
    end
  end

  -- Apply to ProcStartAnim
  if alert.ProcStartAnim then
    local startFlipAnim = alert.ProcStartAnim.FlipAnim
    if not startFlipAnim then
      for _, child in pairs({alert.ProcStartAnim:GetAnimations()}) do
        if child and child.SetFlipBookFrameWidth then startFlipAnim = child; break end
      end
    end
    if startFlipAnim and startFlipAnim.SetFlipBookFrameWidth then
      startFlipAnim:SetFlipBookFrameWidth(flipData.FrameWidth or 0)
      startFlipAnim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
    end
  end

  -- AltGlow shape (Masque provides per-shape alt glow textures)
  if alert.ProcAltGlow then
    local altData = MasqueLib.GetSpellAlert(MasqueLib, shape)
    -- GetSpellAlert returns Glow, Ants (not useful for alt glow specifically)
    -- The alt glow texture path follows Masque's naming: Shape\SpellAlert-AltGlow
    local altPath = [[Interface\AddOns\Masque\Textures\]] .. shape .. [[\SpellAlert-AltGlow]]
    alert.ProcAltGlow:SetTexture(altPath)
  end

  if ns.devMode then
    print("|cff00FF00[ArcUI ProcGlow]|r Applied Masque shape '" .. shape .. "' to SpellActivationAlert")
  end
end

-- Apply Masque shape to an LCG ProcGlow frame (.ProcStart/.ProcLoop/.ProcLoopAnim)
ApplyMasqueProcShapeToLCG = function(frame, glowFrame)
  if not frame or not glowFrame or not IsMasqueSkinned(frame) then return end

  local shape = frame._MSQ_CFG and frame._MSQ_CFG.Shape
  if not shape then return end

  local MasqueLib = LibStub and LibStub("Masque", true)
  if not MasqueLib or not MasqueLib.GetSpellAlertFlipBook then return end

  local flipData = MasqueLib.GetSpellAlertFlipBook(MasqueLib, "Modern", shape)
  if not ok or not flipData then
    flipData = MasqueLib.GetSpellAlertFlipBook(MasqueLib, "Classic", shape)
  end
  if not ok or not flipData then return end

  -- LCG uses .ProcStart / .ProcLoop (not .ProcStartFlipbook / .ProcLoopFlipbook)
  if flipData.LoopTexture and glowFrame.ProcLoop then
    glowFrame.ProcLoop:SetTexture(flipData.LoopTexture)
  end
  if glowFrame.ProcStart then
    glowFrame.ProcStart:SetTexture(flipData.StartTexture or flipData.LoopTexture or "")
  end

  -- Animation dimensions
  if glowFrame.ProcLoopAnim and flipData.FrameWidth then
    local loopFlipAnim = glowFrame.ProcLoopAnim.FlipAnim or glowFrame.ProcLoopAnim.flipbookRepeat
    if loopFlipAnim and loopFlipAnim.SetFlipBookFrameWidth then
      loopFlipAnim:SetFlipBookFrameWidth(flipData.FrameWidth or 0)
      loopFlipAnim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
    end
  end
  if glowFrame.ProcStartAnim and flipData.FrameWidth then
    local startFlipAnim = glowFrame.ProcStartAnim.FlipAnim or glowFrame.ProcStartAnim.flipbookStart
    if startFlipAnim and startFlipAnim.SetFlipBookFrameWidth then
      startFlipAnim:SetFlipBookFrameWidth(flipData.FrameWidth or 0)
      startFlipAnim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
    end
  end

  if ns.devMode then
    print("|cff00FF00[ArcUI ProcGlow]|r Applied Masque shape '" .. shape .. "' to LCG ProcGlow")
  end
end

-- Export Masque shape helpers for ArcAurasCooldown and other modules
ns.CDMEnhance.IsMasqueSkinned = IsMasqueSkinned
ns.CDMEnhance.TriggerMasqueSpellAlertUpdate = TriggerMasqueSpellAlertUpdate
ns.CDMEnhance.ApplyMasqueProcShapeToAlert = ApplyMasqueProcShapeToAlert
ns.CDMEnhance.ApplyMasqueProcShapeToLCG = ApplyMasqueProcShapeToLCG

ResizeProcGlowAlert = function(frame)
  if not frame then return end
  local alert = frame.SpellActivationAlert
  if not alert then return end
  
  -- ALWAYS set frame level above Cooldown swipe so glow isn't hidden behind it
  local baseLevel = frame:GetFrameLevel()
  alert:SetFrameLevel(baseLevel + 15)
  
  -- ArcUI sizing: ALWAYS applied regardless of Masque (we own glow sizing)
  local frameW, frameH = frame:GetWidth(), frame:GetHeight()
  if frameW <= 0 or frameH <= 0 then return end
  
  -- Container = icon * expansion ratio (loop glow fills this via setAllPoints)
  local containerW = frameW * PROC_LOOP_CONTAINER_RATIO
  local containerH = frameH * PROC_LOOP_CONTAINER_RATIO
  alert:ClearAllPoints()
  alert:SetPoint("CENTER", frame, "CENTER")
  alert:SetSize(containerW, containerH)
  
  -- ProcStartFlipbook (burst) at 3.33x ratio relative to icon
  if alert.ProcStartFlipbook then
    alert.ProcStartFlipbook:ClearAllPoints()
    alert.ProcStartFlipbook:SetPoint("CENTER", alert, "CENTER")
    alert.ProcStartFlipbook:SetSize(frameW * PROC_START_BURST_RATIO, frameH * PROC_START_BURST_RATIO)
  end
  
  -- ProcLoopFlipbook: setAllPoints from template handles this automatically
  if alert.ProcLoopFlipbook then
    alert.ProcLoopFlipbook:SetAllPoints(alert)
  end
  
  -- ProcAltGlow: centered, slightly smaller than container
  if alert.ProcAltGlow then
    alert.ProcAltGlow:ClearAllPoints()
    alert.ProcAltGlow:SetPoint("CENTER", alert, "CENTER")
    local altSize = math.min(containerW, containerH) * 0.6
    alert.ProcAltGlow:SetSize(altSize, altSize)
  end
  
  if ns.devMode then
    print("|cff00FF00[ArcUI ProcGlow]|r Resize: icon=" .. 
      string.format("%.0fx%.0f", frameW, frameH) .. 
      " container=" .. string.format("%.0fx%.0f", containerW, containerH) ..
      " burst=" .. string.format("%.0fx%.0f", frameW * PROC_START_BURST_RATIO, frameH * PROC_START_BURST_RATIO))
  end
end

-- Export for ArcUI_Masque.lua post-hook (must be after function definition)
ns.CDMEnhance.ResizeProcGlowAlert = ResizeProcGlowAlert

-- Apply custom color to CDM's SpellActivationAlert (for "proc" glowType)
local function ApplyProcGlowColor(frame, glowCfg)
  if not frame then return end
  local alert = frame.SpellActivationAlert
  if not alert then return end
  
  -- Resize alert to match icon size
  ResizeProcGlowAlert(frame)
  
  -- Get color from config (default gold like vanilla WoW)
  local r, g, b, a = 1, 0.82, 0, 1  -- Default gold
  if glowCfg and glowCfg.color then
    r = glowCfg.color.r or 1
    g = glowCfg.color.g or 0.82
    b = glowCfg.color.b or 0
  end
  if glowCfg and glowCfg.alpha then
    a = glowCfg.alpha
  end
  
  -- Desaturate strips the baked-in gold color so SetVertexColor gives
  -- the actual chosen color instead of multiplying over gold.
  -- Skip desaturation for white (1,1,1) to keep the default look.
  local hasCustomColor = not (r >= 0.99 and g >= 0.99 and b >= 0.99)
  
  if alert.ProcStartFlipbook then
    alert.ProcStartFlipbook:SetDesaturated(hasCustomColor)
    alert.ProcStartFlipbook:SetVertexColor(r, g, b, a)
  end
  if alert.ProcLoopFlipbook then
    alert.ProcLoopFlipbook:SetDesaturated(hasCustomColor)
    alert.ProcLoopFlipbook:SetVertexColor(r, g, b, a)
  end
  if alert.ProcAltGlow then
    alert.ProcAltGlow:SetDesaturated(hasCustomColor)
    alert.ProcAltGlow:SetVertexColor(r, g, b, a)
  end
  
  if ns.devMode then
    print("|cff00FF00[ArcUI ProcGlow]|r Applied color r=" .. string.format("%.2f", r) .. " g=" .. string.format("%.2f", g) .. " b=" .. string.format("%.2f", b) .. " desat=" .. tostring(hasCustomColor))
  end
end

-- Reset CDM's glow to default colors
local function ResetProcGlowColor(frame)
  if not frame then return end
  local alert = frame.SpellActivationAlert
  if not alert then return end
  
  if alert.ProcStartFlipbook then
    alert.ProcStartFlipbook:SetDesaturated(false)
    alert.ProcStartFlipbook:SetVertexColor(1, 1, 1, 1)
  end
  if alert.ProcLoopFlipbook then
    alert.ProcLoopFlipbook:SetDesaturated(false)
    alert.ProcLoopFlipbook:SetVertexColor(1, 1, 1, 1)
  end
  if alert.ProcAltGlow then
    alert.ProcAltGlow:SetDesaturated(false)
    alert.ProcAltGlow:SetVertexColor(1, 1, 1, 1)
  end
end

-- Suppress a child texture's Show() so CDM can't re-show it while ArcUI owns the glow
local function SuppressTexture(tex, frame)
  if not tex or tex._arcSuppressed then return end
  tex._arcSuppressed = true
  tex._arcSuppressOwner = frame
  local origShow = tex.Show
  tex._arcOrigShow = origShow
  tex.Show = function(self)
    if self._arcSuppressOwner and self._arcSuppressOwner._arcProcGlowActive then
      return  -- block Show entirely
    end
    origShow(self)
  end
end

-- Unsuppress a child texture, restoring original Show()
local function UnsuppressTexture(tex)
  if not tex or not tex._arcSuppressed then return end
  tex._arcSuppressed = nil
  tex._arcSuppressOwner = nil
  if tex._arcOrigShow then
    tex.Show = tex._arcOrigShow
    tex._arcOrigShow = nil
  end
end

-- Hide CDM's glow completely (for LCG replacement)
HideCDMProcGlow = function(frame)
  if not frame then return end
  local alert = frame.SpellActivationAlert
  if not alert then return end
  
  -- IMPORTANT: Stop animations FIRST - this prevents them from resetting alpha/visibility
  if alert.ProcStartAnim and alert.ProcStartAnim:IsPlaying() then
    alert.ProcStartAnim:Stop()
  end
  if alert.ProcLoop and alert.ProcLoop:IsPlaying() then
    alert.ProcLoop:Stop()
  end
  
  -- Hide the textures
  if alert.ProcStartFlipbook then alert.ProcStartFlipbook:Hide() end
  if alert.ProcLoopFlipbook then alert.ProcLoopFlipbook:Hide() end
  if alert.ProcAltGlow then alert.ProcAltGlow:Hide() end
  
  -- Suppress child Show() so CDM animations/events can never re-show them
  SuppressTexture(alert.ProcStartFlipbook, frame)
  SuppressTexture(alert.ProcLoopFlipbook, frame)
  SuppressTexture(alert.ProcAltGlow, frame)
  
  -- Also set alpha 0 on the parent as backup
  alert:SetAlpha(0)
  
  if ns.devMode then
    print("|cff00FF00[ArcUI ProcGlow]|r Hidden CDM glow (suppressed textures)")
  end
end

-- Restore CDM's glow visibility (when LCG glow ends)
-- Start LCG glow on frame (for ALL glow types including proc)
-- This matches the preview code EXACTLY for consistent look
StartLCGProcGlow = function(frame, glowCfg, padding)
  if not frame or not ns.Glows then return end
  
  local originalType = glowCfg.glowType or "proc"
  local glowType = originalType
  -- "default" now uses "proc" (LCG ProcGlow) instead of CDM's SpellActivationAlert
  if glowType == "default" then glowType = "proc" end
  
  local glowOffset = -(padding or 0)
  
  -- nil color for "default" with no user color = LCG uses native golden texture (matches CDM)
  local color = nil
  if glowCfg.color then
    color = {glowCfg.color.r or 1, glowCfg.color.g or 1, glowCfg.color.b or 1, glowCfg.alpha or 1.0}
  elseif originalType ~= "default" then
    color = {0.95, 0.95, 0.32, glowCfg.alpha or 1.0}
  end
  
  ns.Glows.Start(frame, "ArcUI_ProcGlow", glowType, {
    color = color,
    scale = glowCfg.scale or 1.0,
    frequency = glowCfg.speed or 0.25,
    lines = glowCfg.lines or 8,
    thickness = glowCfg.thickness or 2,
    particles = glowCfg.particles or 4,
    xOffset = glowOffset + (glowCfg.xOffset or 0),
    yOffset = glowOffset + (glowCfg.yOffset or 0),
    translateX = glowCfg.translateX or 0,
    translateY = glowCfg.translateY or 0,
    frameLevel = glowCfg.frameLevel,
  })
end

-- Stop LCG glow on frame
StopLCGProcGlow = function(frame)
  if not frame or not ns.Glows then return end
  ns.Glows.Stop(frame, "ArcUI_ProcGlow")
  frame._arcProcGlowPreWarmed = nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PRE-WARM PROC GLOW FRAME
-- Creates and initializes the glow frame ahead of time so it's ready when needed
-- This prevents the "first show glitch" where ProcLoop starts at alpha 0
-- Call this during icon enhancement for any icon that might get proc glows
-- ═══════════════════════════════════════════════════════════════════════════
local function PreWarmProcGlow(frame, glowCfg)
  if not frame or not ns.Glows then return end
  if not glowCfg then return end
  
  local originalType = glowCfg.glowType or "proc"
  local glowType = originalType
  if glowType == "default" then glowType = "proc" end
  
  -- Only pre-warm for "proc" type (others don't have the first-show glitch)
  if glowType ~= "proc" then return end
  
  -- Already pre-warmed or glow is actively showing?
  if frame._arcProcGlowPreWarmed then return end
  if frame._arcProcGlowActive then return end
  
  local padding = 0
  if frame._arcConfig and frame._arcConfig.padding then
    padding = frame._arcConfig.padding
  elseif frame._arcPadding then
    padding = frame._arcPadding
  end
  local glowOffset = -(padding or 0)
  
  -- nil color for "default" with no user color = native golden texture
  local color = nil
  if glowCfg.color then
    color = {glowCfg.color.r or 1, glowCfg.color.g or 1, glowCfg.color.b or 1, 1.0}
  elseif originalType ~= "default" then
    color = {0.95, 0.95, 0.32, 1.0}
  end
  
  -- Start then immediately force-hide to pre-create the glow frame
  ns.Glows.Start(frame, "ArcUI_ProcGlow", "proc", {
    color = color,
    xOffset = glowOffset,
    yOffset = glowOffset,
  })
  ns.Glows.ForceHide(frame, "ArcUI_ProcGlow")
  
  frame._arcProcGlowPreWarmed = true
end

-- Export for use in ApplyIconStyle
ns.CDMEnhance.PreWarmProcGlow = PreWarmProcGlow

-- Called by event (SPELL_ACTIVATION_OVERLAY_GLOW_SHOW) or hook (SpellActivationAlert:Show)
-- Has guard against double-calls - safe to trigger from both
function ns.CDMEnhance.ShowProcGlow(frame, glowCfg)
  if not frame then return end
  if not glowCfg or glowCfg.enabled == false then
    -- Glow DISABLED - hide ALL glows (both ours and CDM's)
    if frame._arcProcGlowActive then
      ns.CDMEnhance.HideProcGlow(frame)
    end
    HideCDMProcGlow(frame)
    return
  end
  
  -- Already showing? Verify animation is actually alive
  if frame._arcProcGlowActive then
    local existingType = frame._arcProcGlowType or "proc"
    if existingType == "proc" or existingType == "default" then
      local gf = ns.Glows and ns.Glows.GetGlowFrame(frame, "ArcUI_ProcGlow")
      if gf then
        if gf:IsShown() and gf:IsVisible() then
          -- Check if animation died
          if gf.ProcLoopAnim and not gf.ProcLoopAnim:IsPlaying() then
            if gf.ProcStart then gf.ProcStart:Hide() end
            if gf.ProcLoop then
              gf.ProcLoop:Show()
              gf.ProcLoop:SetAlpha(glowCfg.alpha or 1.0)
            end
            gf.ProcLoopAnim:Play()
          end
          -- CDM may have re-shown its native alert after our initial hide (login race)
          HideCDMProcGlow(frame)
          return  -- Still playing or just recovered
        elseif not gf:IsShown() then
          -- Glow frame was hidden/released - need full restart
          frame._arcProcGlowActive = false
          frame._arcProcGlowPreWarmed = nil
        else
          HideCDMProcGlow(frame)
          return  -- Parent hidden - OnShow will handle
        end
      else
        -- Glow frame doesn't exist anymore
        frame._arcProcGlowActive = false
        frame._arcProcGlowPreWarmed = nil
      end
    else
      -- pixel / button / autocast: verify the LCG glow frame is still alive.
      -- If it's gone or hidden we must clear the active flag so the restart
      -- below proceeds. Without this check ShowProcGlow returns here forever
      -- and the glow never shows after a frame recycle / spec change / re-open.
      local gf = ns.Glows and ns.Glows.GetGlowFrame(frame, "ArcUI_ProcGlow")
      if gf and gf:IsShown() and gf:IsVisible() then
        HideCDMProcGlow(frame)
        return  -- Genuinely still active — nothing to do
      else
        -- Frame gone or hidden — allow full restart below
        frame._arcProcGlowActive = false
        frame._arcProcGlowPreWarmed = nil
      end
    end
  end
  
  local glowType = glowCfg.glowType or "proc"
  -- "default" now routes through ns.Glows as "proc" type
  if glowType == "default" then glowType = "proc" end
  
  -- Get padding
  local padding = 0
  if frame._arcConfig and frame._arcConfig.padding then
    padding = frame._arcConfig.padding
  elseif frame._arcPadding then
    padding = frame._arcPadding
  end
  
  -- Track which spell started this glow
  local startingSpellID = nil
  if frame.cooldownInfo then
    startingSpellID = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
  end
  
  -- Set state
  frame._arcProcGlowActive = true
  frame._arcProcGlowType = glowType
  frame._arcProcGlowSpellID = startingSpellID
  frame._arcProcGlowPreWarmed = true
  
  -- All types now go through ns.Glows via StartLCGProcGlow
  StartLCGProcGlow(frame, glowCfg, padding)
  
  -- Always hide CDM's native alert when we're showing our own
  if frame.SpellActivationAlert then
    HideCDMProcGlow(frame)
  end

  -- Proc is now active — feed shadow first so binary state is current,
  -- then dispatch visuals so readyProcOverride / cooldownProcOverride applies correctly.
  local cfg = GetEffectiveIconSettingsForFrame(frame)
  if cfg then
    if ns.CooldownState and ns.CooldownState.FeedShadow then
      ns.CooldownState.FeedShadow(frame, cfg)
    end
    ApplyCooldownStateVisuals(frame, cfg, cfg.alpha or 1.0)
  end
end

-- Called when SPELL_ACTIVATION_OVERLAY_GLOW_HIDE fires
function ns.CDMEnhance.HideProcGlow(frame)
  if not frame then return end
  
  -- Capture spellID BEFORE clearing (needed for deferred recovery below)
  local savedSpellID = frame._arcProcGlowSpellID
  
  -- Stop our glow via ns.Glows
  StopLCGProcGlow(frame)
  
  frame._arcProcGlowActive = false
  frame._arcProcGlowType = nil
  frame._arcProcGlowSpellID = nil

  -- Proc ended — feed shadow first so binary state is current,
  -- then dispatch visuals so readyState alpha (e.g. 0) is restored correctly.
  local cfg = GetEffectiveIconSettingsForFrame(frame)
  if cfg then
    if ns.CooldownState and ns.CooldownState.FeedShadow then
      ns.CooldownState.FeedShadow(frame, cfg)
    end
    ApplyCooldownStateVisuals(frame, cfg, cfg.alpha or 1.0)
  end
  
  if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
    -- Also capture the base spellID NOW before state clears further.
    -- When FFE is right-clicked off, GLOW_HIDE 199786 fires but GLOW_SHOW 431044
    -- (plain GS) never follows — CDM doesn't re-fire ShowAlert. We need to check
    -- the base spell at 0.1s and restart if it's still overlayed.
    local baseSpellID = (frame.cooldownInfo and (frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID))
                        or frame._arcSpellID
    C_Timer.After(0.1, function()
      if not frame or frame._arcProcGlowActive then return end
      local cfg = GetEffectiveIconSettingsForFrame(frame)
      local glowCfg = cfg and cfg.procGlow
      if not glowCfg or glowCfg.enabled == false then return end
      -- Check saved spellID first (pure race — briefly de-registered)
      if savedSpellID and SafeIsSpellOverlayed(savedSpellID) then
        HideCDMProcGlow(frame)
        ns.CDMEnhance.ShowProcGlow(frame, glowCfg)
        if ns.devMode then
          print(string.format("|cffFFAA00[ArcUI HideProcGlow]|r Race recovery: savedSpell=%d still overlayed", savedSpellID))
        end
        return
      end
      -- Check base spellID (FFE-style removal — overlay switched to base spell but
      -- CDM didn't fire ShowAlert for it)
      if baseSpellID and baseSpellID ~= savedSpellID
         and SafeIsSpellOverlayed(baseSpellID) then
        HideCDMProcGlow(frame)
        ns.CDMEnhance.ShowProcGlow(frame, glowCfg)
        if ns.devMode then
          print(string.format("|cffFFAA00[ArcUI HideProcGlow]|r Base spell recovery: baseSpell=%d still overlayed (was %s)", baseSpellID, tostring(savedSpellID)))
        end
      end
    end)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CLEANUP STALE PROC GLOWS
-- When CDM repools frames (spec change, icon added/removed), proc glows
-- can persist on frames whose cooldownID has changed. This function iterates
-- ALL enhanced frames and verifies each active proc glow still matches
-- the frame's current spell. Called during spec change and periodic refresh.
-- ═══════════════════════════════════════════════════════════════════════════
function ns.CDMEnhance.CleanupStaleProcGlows()
  local cleaned = false
  for cdID, data in pairs(enhancedFrames) do
    if data.frame and data.frame._arcProcGlowActive then
      local frame = data.frame
      local glowSpellID = frame._arcProcGlowSpellID
      
      -- Get the frame's CURRENT spellID
      local currentSpellID = nil
      if frame.cooldownInfo then
        currentSpellID = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
      end
      if not currentSpellID and frame.GetSpellID then
        currentSpellID = NonSecretSpellID(frame:GetSpellID())
      end
      if not currentSpellID then
        currentSpellID = frame._arcSpellID
      end
      
      -- If the spell changed, the glow is stale — kill it
      if glowSpellID and currentSpellID and glowSpellID ~= currentSpellID then
        if ns.devMode then
          print(string.format("|cffFF6600[ArcUI]|r Stale proc glow: cdID=%d glowSpell=%d currentSpell=%d — cleaning up", cdID, glowSpellID, currentSpellID))
        end
        ns.CDMEnhance.HideProcGlow(frame)
        cleaned = true
      elseif not currentSpellID then
        -- Frame has no spell anymore (empty slot after repool) — kill glow
        if ns.devMode then
          print(string.format("|cffFF6600[ArcUI]|r Orphaned proc glow: cdID=%d glowSpell=%s — cleaning up", cdID, tostring(glowSpellID)))
        end
        ns.CDMEnhance.HideProcGlow(frame)
        cleaned = true
      end
    end
  end
  
  -- If we cleaned any stale glows, callers should follow up with
  -- RefreshActiveProcGlows() to re-apply glows to correct frames
  return cleaned
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REFRESH ACTIVE PROC GLOWS ON RELOAD
-- On reload, CDM calls ShowAlert before our enhancedFrames/sizes are ready.
-- Our ShowAlert hook either bails (no config yet) or sizes against stale
-- frame dimensions. This function runs AFTER RefreshAllStyles sets correct
-- icon sizes and restarts any active proc glows at proper dimensions.
-- ═══════════════════════════════════════════════════════════════════════════
function ns.CDMEnhance.RefreshActiveProcGlows()
  if not C_SpellActivationOverlay or not C_SpellActivationOverlay.IsSpellOverlayed then return end
  
  for cdID, data in pairs(enhancedFrames) do
    if data.frame and data.frame._arcStyled then
      local frame = data.frame
      
      -- Determine the frame's spellID (all non-secret properties)
      local spellID = nil
      if frame.cooldownInfo then
        spellID = frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID
      end
      if not spellID then
        spellID = frame._arcSpellID
      end
      
      -- Check if this spell should have an active proc glow right now
      local isOverlayed = spellID and SafeIsSpellOverlayed(spellID)
      
      if isOverlayed then
        local cfg = GetEffectiveIconSettingsForFrame(frame)
        local glowCfg = cfg and cfg.procGlow
        
        if glowCfg and glowCfg.enabled ~= false then
          -- ALL glow types go through our system (including "default" → "proc")
          if frame._arcProcGlowActive then
            -- Clean up any partial state
            ns.CDMEnhance.HideProcGlow(frame)
          end
          -- Suppress CDM's native glow in case it restarted during refresh
          HideCDMProcGlow(frame)
          ns.CDMEnhance.ShowProcGlow(frame, glowCfg)
          
          if ns.devMode then
            local glowType = glowCfg.glowType or "default"
            print("|cff00FF00[ArcUI ProcRefresh]|r Started", glowType, "glow for cdID:", cdID, "spellID:", spellID)
          end
        elseif glowCfg and glowCfg.enabled == false then
          -- Glow DISABLED: suppress CDM's glow that started before config was ready
          HideCDMProcGlow(frame)
          if frame._arcProcGlowActive then
            ns.CDMEnhance.HideProcGlow(frame)
          end
        end
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ACTIONBUTTONSPELLALERTMANAGER HOOK
-- This intercepts ALL proc glow ShowAlert calls AFTER they start.
-- For LCG replacement mode, we immediately stop/hide CDM's glow.
-- For CDM recolor mode, we apply custom colors.
-- Using hooksecurefunc to avoid taint issues.
-- ═══════════════════════════════════════════════════════════════════════════
local function SetupShowAlertHook()
  -- Wait until ActionButtonSpellAlertManager exists
  if not ActionButtonSpellAlertManager then
    -- Try again later
    C_Timer.After(0.5, SetupShowAlertHook)
    return
  end
  
  if ns.CDMEnhance._showAlertHooked then return end
  ns.CDMEnhance._showAlertHooked = true
  
  -- Hook ShowAlert - runs AFTER CDM shows glow
  -- This is the entry point for starting LCG glows
  hooksecurefunc(ActionButtonSpellAlertManager, "ShowAlert", function(self, frame)
    if not frame then return end
    
    -- Get FRESH config - never use cached references
    local cfg = GetEffectiveIconSettingsForFrame(frame)
    local glowCfg = cfg and cfg.procGlow
    
    if not glowCfg then return end
    
    -- DISABLED: Hide CDM's glow completely
    if glowCfg.enabled == false then
      if frame.SpellActivationAlert then
        HideCDMProcGlow(frame)
      end
      return
    end
    
    local glowType = glowCfg.glowType or "default"
    
    -- ALL glow types (including "default") go through our system.
    -- "default" maps to "proc" (LCG ProcGlow with native golden texture) inside
    -- StartLCGProcGlow, giving the same look without poking CDM's animation internals.
    
    -- 1. Hide CDM's glow with full suppression (blocks CDM from re-showing
    --    ProcStartFlipbook during internal refresh cycles)
    HideCDMProcGlow(frame)
    
    -- 2. Start our glow (ShowProcGlow has guards against double-start)
    ns.CDMEnhance.ShowProcGlow(frame, glowCfg)
    
    if ns.devMode then
      print("|cff00FF00[ArcUI ShowAlertHook]|r Started", glowType, "glow (CDM suppressed)")
    end
  end)
  
  -- Hook HideAlert - runs AFTER CDM hides glow
  -- This is the entry point for stopping LCG glows
  hooksecurefunc(ActionButtonSpellAlertManager, "HideAlert", function(self, frame)
    if not frame then return end
    
    -- Hide our LCG glow if active
    if frame._arcProcGlowActive then
      local glowType = frame._arcProcGlowType or "default"
      
      if glowType ~= "default" then
        -- LCG MODE: CDM may call HideAlert during internal refresh cycles
        -- (layout update, combat exit, icon state refresh) even though the
        -- spell is still procced. Check IsSpellOverlayed before killing the glow.
        -- The SPELL_ACTIVATION_OVERLAY_GLOW_HIDE event is the authoritative
        -- signal and will clean up if we skip here.
        if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
          local glowSpellID = frame._arcProcGlowSpellID
          
          -- PRIMARY CHECK: is the spell that started this glow still overlayed?
          if glowSpellID and SafeIsSpellOverlayed(glowSpellID) then
            if ns.devMode then
              print("|cffFF9900[ArcUI HideAlertHook]|r SKIPPED - spell still overlayed:", glowSpellID, "type:", glowType)
            end
            if frame.SpellActivationAlert then HideCDMProcGlow(frame) end
            return
          end
          
          -- FALLBACK CHECK: FFE-style spell swap — the saved spellID's overlay ended
          -- (e.g. 199786 FFE-empowered GS) but the frame's BASE spellID (e.g. 431044
          -- plain GS) is still overlayed. CDM won't fire a new ShowAlert, so just
          -- update the tracked spellID and keep the glow running — no stop/restart.
          local baseSpellID = (frame.cooldownInfo and (frame.cooldownInfo.overrideSpellID or frame.cooldownInfo.spellID))
                              or frame._arcSpellID
          if baseSpellID and baseSpellID ~= glowSpellID
             and SafeIsSpellOverlayed(baseSpellID) then
            if ns.devMode then
              print("|cffFFAA00[ArcUI HideAlertHook]|r REDIRECT - base spell still overlayed:",
                baseSpellID, "was:", glowSpellID)
            end
            -- Just update tracked spellID — glow keeps playing uninterrupted
            frame._arcProcGlowSpellID = baseSpellID
            if frame.SpellActivationAlert then HideCDMProcGlow(frame) end
            return
          end
        end
      end
      
      ns.CDMEnhance.HideProcGlow(frame)
      
      if ns.devMode then
        print("|cffFF0000[ArcUI HideAlertHook]|r Hid LCG glow for frame:", frame.cooldownID)
      end
    end
  end)
  
  if ns.devMode then
    print("|cff00FF00[ArcUI]|r ActionButtonSpellAlertManager ShowAlert/HideAlert hooked (secure)")
  end
end

-- Set up the hook immediately (will retry if manager doesn't exist yet)
SetupShowAlertHook()

-- Refresh all combat-only glows when combat state changes
local function RefreshCombatOnlyGlows()
  local inCombat = InCombatLockdown() or UnitAffectingCombat("player")
  
  -- Iterate through all enhanced frames
  for cdID, data in pairs(enhancedFrames) do
    if data and data.frame then
      local frame = data.frame
      -- Frame fast-path (== GetIconSettings, but cache-hit) + reuse the cached
      -- state-visuals table instead of re-allocating ~40 fields per frame just to
      -- find the handful with combat-only glows.
      local cfg = GetEffectiveIconSettingsForFrame(frame)
      if cfg then
        local stateVisuals = frame._arcCachedStateVisuals
        if stateVisuals and stateVisuals.readyGlow and stateVisuals.readyGlowCombatOnly then
          -- This icon has combat-only glow enabled
          if inCombat then
            -- Entering combat - evaluate glow state directly
            -- ApplyCooldownStateVisuals handles ready/cooldown detection and glow
            ApplyCooldownStateVisuals(frame, cfg, nil, stateVisuals)
          else
            -- Leaving combat - hide the glow
            HideReadyGlow(frame)
          end
        end
        -- Also handle aura active glow combat-only
        local auraActiveCfg = cfg.auraActiveState
        if auraActiveCfg and (auraActiveCfg.glow or auraActiveCfg.glowWhenMissing) and auraActiveCfg.glowCombatOnly then
          if inCombat then
            -- Entering combat - directly evaluate aura glow state
            local hasAura = HasAuraInstanceID(frame.auraInstanceID)
            if ShouldShowAuraActiveGlow(auraActiveCfg, frame, hasAura) then
              ShowAuraActiveGlow(frame, auraActiveCfg)
            else
              HideAuraActiveGlow(frame)
            end
          else
            HideAuraActiveGlow(frame)
          end
        end
      end
    end
  end
end

eventFrame:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == "Blizzard_CooldownViewer" then
    C_Timer.After(1.0, function()
      if not InCombatLockdown() then
        ns.CDMEnhance.ScanCDM()
        -- Also apply group settings after CDM loads
        C_Timer.After(0.5, function()
          if not InCombatLockdown() then
            ns.CDMEnhance.RefreshAllStyles()
            if ns.CDMGroupSettings then
              ns.CDMGroupSettings.ForceLayoutRefresh("aura")
              ns.CDMGroupSettings.ForceLayoutRefresh("cooldown")
              ns.CDMGroupSettings.ForceLayoutRefresh("utility")
            end
            -- Fix proc glows that started before config/sizes were ready
            C_Timer.After(0.3, function()
              if ns.CDMEnhance.RefreshActiveProcGlows then
                ns.CDMEnhance.RefreshActiveProcGlows()
              end
              -- Force-refresh aura/cooldown state visuals (alpha, desat, glow)
              -- Without this, frames can get stuck at default alpha after CDM loads
              if ns.CDMEnhance.ForceRefreshAllVisualStates then
                ns.CDMEnhance.ForceRefreshAllVisualStates()
              end
            end)
          end
        end)
      end
    end)
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Zone change - CDMGroups handles positioning
    -- CDMEnhance just refreshes styling
    
    C_Timer.After(1.0, function()
      local db = GetDB()
      if db then
        if db.unlocked then isUnlocked = true end
        if db.textDragMode then textDragMode = true end
      end
      -- Refresh cached enabled state
      RefreshCachedEnabledState()
      -- Invalidate cache to ensure fresh settings on load
      InvalidateEffectiveSettingsCache()
      if not InCombatLockdown() then
        -- Force CDM to create all frames before we scan
        ns.CDMEnhance.ForceCDMFrameCreation()
        ns.CDMEnhance.ScanCDM()
        
        -- Second pass to ensure all global settings are applied
        C_Timer.After(0.5, function()
          if not InCombatLockdown() then
            ns.CDMEnhance.RefreshAllStyles()
            if ns.CDMGroupSettings then
              ns.CDMGroupSettings.ForceLayoutRefresh("aura")
              ns.CDMGroupSettings.ForceLayoutRefresh("cooldown")
              ns.CDMGroupSettings.ForceLayoutRefresh("utility")
            end
            -- Fix proc glows that started before config/sizes were ready
            C_Timer.After(0.3, function()
              if ns.CDMEnhance.RefreshActiveProcGlows then
                ns.CDMEnhance.RefreshActiveProcGlows()
              end
              -- Force-refresh aura/cooldown state visuals (alpha, desat, glow)
              -- Without this, frames can get stuck at wrong alpha after reload/zone change
              if ns.CDMEnhance.ForceRefreshAllVisualStates then
                ns.CDMEnhance.ForceRefreshAllVisualStates()
              end
            end)
          end
        end)
      end
    end)
  elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
    -- Spec changed - CDM will show new icons
    -- CDMGroups handles all spec change logic including positioning
    -- CDMEnhance just refreshes styling AFTER CDMGroups completes
    
    -- IMMEDIATE: Kill all active proc glows — frames are about to be repooled
    -- and their cooldownIDs will change. Without this, glows persist on wrong frames.
    for cdID, data in pairs(enhancedFrames) do
      if data.frame and data.frame._arcProcGlowActive then
        ns.CDMEnhance.HideProcGlow(data.frame)
      end
    end
    
    C_Timer.After(1.0, function()
      -- Wait for CDMGroups to finish spec change
      if ns.CDMGroups and ns.CDMGroups.specChangeInProgress then
        -- Still changing, wait more
        C_Timer.After(0.5, function()
          if ns.API and ns.API.ScanAllCDMIcons then
            ns.API.ScanAllCDMIcons()
          end
          -- Final cleanup pass after frames settle with new cooldownIDs
          ns.CDMEnhance.CleanupStaleProcGlows()
          -- Re-apply proc glows to frames that now hold proc-active spells
          ns.CDMEnhance.RefreshActiveProcGlows()
          -- Force-refresh visual states for new spec's frames
          if ns.CDMEnhance.ForceRefreshAllVisualStates then
            ns.CDMEnhance.ForceRefreshAllVisualStates()
          end
        end)
      else
        if ns.API and ns.API.ScanAllCDMIcons then
          ns.API.ScanAllCDMIcons()
        end
        -- Final cleanup pass after frames settle with new cooldownIDs
        ns.CDMEnhance.CleanupStaleProcGlows()
        -- Re-apply proc glows to frames that now hold proc-active spells
        ns.CDMEnhance.RefreshActiveProcGlows()
        -- Force-refresh visual states for new spec's frames
        if ns.CDMEnhance.ForceRefreshAllVisualStates then
          ns.CDMEnhance.ForceRefreshAllVisualStates()
        end
      end
    end)
  elseif event == "PLAYER_REGEN_DISABLED" then
    -- Entering combat - refresh combat-only glows
    RefreshCombatOnlyGlows()
  elseif event == "PLAYER_REGEN_ENABLED" then
    -- Leaving combat - hide combat-only glows
    RefreshCombatOnlyGlows()
    
    -- CRITICAL: Refresh all icon alpha after combat ends
    -- CDM refreshes icons when combat ends and may override our alpha
    -- We need to re-apply our alpha settings after CDM's refresh completes
    -- OPTIMIZATION: Only refresh frames that have custom state visuals or
    -- ignoreAuraOverride. Frames without these are fully managed by CDM
    -- natively and calling ApplyCooldownStateVisuals on them is wasteful
    -- (and was previously destructive — it nuked CDM's native desaturation).
    C_Timer.After(0.1, function()
      for cdID, data in pairs(enhancedFrames) do
        if data.frame then
          local cfg = GetEffectiveIconSettingsForFrame(data.frame)
          if cfg then
            -- Reuse the cached state-visuals (GetEffectiveIconSettingsForFrame just
            -- refreshed it) instead of re-allocating a ~40-field table per frame
            -- that we only nil-check and discard — that alloc was a GC burst at
            -- exactly the combat-drop moment.
            local sv = data.frame._arcCachedStateVisuals
            local ignAura = (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
                         or (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)
            if sv or ignAura then
              -- Clear cached state so it recalculates
              data.frame._arcTargetAlpha = nil
              data.frame._arcEnforceReadyAlpha = nil
              ApplyCooldownStateVisuals(data.frame, cfg, cfg.alpha or 1.0)
            end
          end
        end
      end
    end)
    -- Second pass for stragglers (CDM may have multiple refresh waves)
    C_Timer.After(0.3, function()
      for cdID, data in pairs(enhancedFrames) do
        if data.frame then
          local cfg = GetEffectiveIconSettingsForFrame(data.frame)
          if cfg then
            -- Reuse cached state-visuals (no per-frame table re-allocation).
            local sv = data.frame._arcCachedStateVisuals
            local ignAura = (cfg.auraActiveState and cfg.auraActiveState.ignoreAuraOverride)
                         or (cfg.cooldownSwipe and cfg.cooldownSwipe.ignoreAuraOverride)
            if sv or ignAura then
              data.frame._arcTargetAlpha = nil
              data.frame._arcEnforceReadyAlpha = nil
              ApplyCooldownStateVisuals(data.frame, cfg, cfg.alpha or 1.0)
            end
          end
        end
      end
    end)
    
  elseif event == "SPELL_UPDATE_COOLDOWN" then
    -- Per-frame event listeners in CooldownState handle all CD feeding.

  elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
    -- arg1 = spellID (non-secret event data)
    local spellID = arg1
    if not spellID then return end
    
    if ns.devMode then
      print("|cff00FF00[ArcUI Proc]|r SHOW event for spellID:", spellID)
    end
    
    -- Find frame with this spellID
    -- NOTE: ShowAlert hook is the primary path for LCG glows
    -- This event acts as a backup and handles cases where frame needs glow but ShowAlert didn't fire
    for cdID, data in pairs(enhancedFrames) do
      if data.frame and data.frame._arcStyled then
        local frameSpellID = nil
        if data.frame.cooldownInfo then
          frameSpellID = data.frame.cooldownInfo.overrideSpellID or data.frame.cooldownInfo.spellID
        end
        if not frameSpellID and data.frame.GetSpellID then
          frameSpellID = NonSecretSpellID(data.frame:GetSpellID())
        end
        if not frameSpellID then
          frameSpellID = data.frame._arcSpellID
        end
        
        if frameSpellID == spellID then
          -- Get FRESH config
          local cfg = GetEffectiveIconSettingsForFrame(data.frame)
          local glowCfg = cfg and cfg.procGlow
          
          if glowCfg and glowCfg.enabled ~= false then
            -- ShowProcGlow has guards against double-start, so safe to call even if ShowAlert already ran
            ns.CDMEnhance.ShowProcGlow(data.frame, glowCfg)
            
            if ns.devMode then
              print("|cff00FF00[ArcUI Proc]|r Found frame for spellID:", spellID, "glowType:", glowCfg.glowType)
            end
          end
          break
        end
      end
    end
    
  elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
    -- arg1 = spellID (non-secret event data)
    local spellID = arg1
    if not spellID then return end
    
    if ns.devMode then
      print("|cffFF0000[ArcUI Proc]|r HIDE event for spellID:", spellID)
    end
    
    local foundFrame = false
    
    -- Helper to check if a frame's glow was started by this spellID
    -- IMPORTANT: Match against _arcProcGlowSpellID, NOT current overrideSpellID!
    -- The spell on the frame may have changed since the glow started.
    local function CheckAndHideFrame(frame, cdID)
      if not frame or not frame._arcStyled then return false end
      if not frame._arcProcGlowActive then return false end  -- No active glow to hide
      
      -- Match against the spellID that STARTED the glow
      if frame._arcProcGlowSpellID == spellID then
        if ns.devMode then
          print("|cffFF0000[ArcUI Proc]|r Found frame for spellID:", spellID, "cdID:", cdID)
        end
        
        -- Hide our glow
        ns.CDMEnhance.HideProcGlow(frame)
        
        if ns.devMode then
          print("|cffFF0000[ArcUI Proc]|r Called HideProcGlow")
        end
        
        return true
      end
      return false
    end
    
    -- Search enhancedFrames
    for cdID, data in pairs(enhancedFrames) do
      if CheckAndHideFrame(data.frame, cdID) then
        foundFrame = true
        break
      end
    end
    
    -- Also search CDMGroups if not found
    if not foundFrame and ns.CDMGroups then
      -- Search free icons
      if ns.CDMGroups.freeIcons then
        for cdID, iconData in pairs(ns.CDMGroups.freeIcons) do
          if iconData.frame and CheckAndHideFrame(iconData.frame, cdID) then
            foundFrame = true
            break
          end
        end
      end
      
      -- Search grouped icons
      if not foundFrame and ns.CDMGroups.groups then
        for groupName, groupData in pairs(ns.CDMGroups.groups) do
          if groupData.icons then
            for cdID, iconData in pairs(groupData.icons) do
              if iconData.frame and CheckAndHideFrame(iconData.frame, cdID) then
                foundFrame = true
                break
              end
            end
          end
          if foundFrame then break end
        end
      end
    end
    
    if ns.devMode and not foundFrame then
      print("|cffFF0000[ArcUI Proc]|r Could not find frame for spellID:", spellID)
    end

  elseif event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
    -- baseSpellID / overrideSpellID are non-secret in this event.
    -- CDM has already updated frame.cooldownInfo.overrideSpellID before this fires,
    -- but ArcUI's per-frame caches (_arcCachedSpellID, _arcShadowFedSpellID) still
    -- hold the old spell — causing the ready glow to track the wrong spellID.
    -- Fix: find every enhanced frame whose base spell matches, invalidate caches,
    -- kill any stale ready glow, and re-evaluate state immediately.
    local baseSpellID    = arg1
    local overrideSpellID = arg2  -- nil means override was removed
    if not baseSpellID then return end

    if ns.devMode then
      print(string.format("|cffFFAA00[ArcUI]|r SPELL_OVERRIDE_UPDATED base=%d override=%s",
            baseSpellID, tostring(overrideSpellID)))
    end

    for cdID, data in pairs(enhancedFrames) do
      local frame = data.frame
      if frame and frame._arcStyled then
        local ci = frame.cooldownInfo
        if ci and ci.spellID == baseSpellID then
          local newSpellID = overrideSpellID or baseSpellID
          -- Update cache immediately — per-frame listener uses this for event matching
          frame._arcCachedSpellID    = newSpellID
          frame._arcShadowFedSpellID = nil
          -- Kill ready glow keyed to old spell
          if frame._arcReadyGlowActive then
            HideReadyGlow(frame)
            frame._arcReadyGlowActive = false
          end
          frame._arcLastShadowShown  = nil
          frame._arcLastChargeShown  = nil
          -- Feed shadow SYNCHRONOUSLY with the new spell while cooldownInfo still
          -- reflects the override. The override window can be as short as ~110ms —
          -- a deferred C_Timer.After(0) fires after CDM has already cleared the
          -- override, causing FeedShadow to see the base spell (not on CD) and
          -- produce a ready state instead of the correct cooldown state.
          if ns.CooldownState and ns.CooldownState.FeedShadow then
            local cfg = GetEffectiveIconSettingsForFrame(frame)
            if cfg then
              ns.CooldownState.FeedShadow(frame, cfg)
              -- Apply visuals synchronously so the swipe/alpha update within this frame
              ApplyCooldownStateVisuals(frame, cfg)
            end
          end
          if ns.devMode then
            print(string.format("|cffFFAA00[ArcUI]|r  -> fed shadow cdID=%d spellID=%s",
                  cdID, tostring(newSpellID)))
          end
        end
      end
    end
  end
end)

-- Profiler: wrap the event handler after creation (non-invasive)
if Track then
  local origEvtHandler = eventFrame:GetScript("OnEvent")
  if origEvtHandler then
    eventFrame:SetScript("OnEvent", Track("CDMEnhance.EventHandler", origEvtHandler))
  end
end

-- Hook Edit Mode to reapply our styles when it opens/closes
-- (Edit Mode can temporarily override icon sizes/positions)
local function HookEditMode()
  if not EditModeManagerFrame then return end
  
  if ns.CDMEnhance._editModeHooked then return end
  ns.CDMEnhance._editModeHooked = true
  
  -- Track when Edit Mode is active
  local editModeActive = false
  
  -- Hook ExitEditMode method - this is more reliable than OnHide
  hooksecurefunc(EditModeManagerFrame, "ExitEditMode", function()
    editModeActive = false
    -- Reapply all styles after Edit Mode exits
    C_Timer.After(0.1, function()
      if not InCombatLockdown() then
        ns.CDMEnhance.RefreshAllStyles()
      end
    end)
    -- Second pass for any stragglers
    C_Timer.After(0.3, function()
      if not InCombatLockdown() then
        ns.CDMEnhance.RefreshAllStyles()
      end
      -- Update options panel
      if LibStub and LibStub("AceConfigRegistry-3.0", true) then
        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
      end
    end)
  end)
  
  -- Hook OnShow to know when Edit Mode is active and handle free position icons
  EditModeManagerFrame:HookScript("OnShow", function()
    editModeActive = true
    -- CDMGroups handles positioning - just refresh styles
    C_Timer.After(0.15, function()
      if not InCombatLockdown() then
        for cdID, data in pairs(enhancedFrames) do
          if data.frame then
            ApplyIconStyle(data.frame, cdID)
          end
        end
      end
    end)
  end)
  
  -- Hook OnHide as backup
  EditModeManagerFrame:HookScript("OnHide", function()
    if editModeActive then
      editModeActive = false
      C_Timer.After(0.2, function()
        if not InCombatLockdown() then
          ns.CDMEnhance.RefreshAllStyles()
        end
      end)
    end
  end)
end

-- Try to hook immediately or wait for Edit Mode to load
if EditModeManagerFrame then
  HookEditMode()
else
  -- Hook when Blizzard_EditMode loads
  local editModeLoader = CreateFrame("Frame")
  editModeLoader:RegisterEvent("ADDON_LOADED")
  editModeLoader:SetScript("OnEvent", function(self, event, addon)
    if addon == "Blizzard_EditMode" then
      C_Timer.After(0.1, HookEditMode)
      self:UnregisterAllEvents()
    end
  end)
end

-- ===================================================================
-- COOLDOWN EVENT-DRIVEN UPDATES
-- Instead of polling at 10Hz, we update cooldown visuals on events
-- Duration objects auto-update internally, we just refresh on CD changes
-- ===================================================================

-- ===================================================================
-- OPTIONS PANEL STATE TRACKING
-- Uses Shared's cached state and callback (avoids expensive OnUpdate checks)
-- ===================================================================

-- Register callback for when options panel state changes
Shared.OnOptionsPanelStateChanged = function(isOpen)
  -- Panel state changed - refresh all icon visuals
  ns.CDMEnhance.RefreshOverlayMouseState()

  -- Force item/trinket frames to re-evaluate immediately on panel open/close.
  -- They are event-driven (BAG_UPDATE_COOLDOWN) so they won't self-correct
  -- until the next bag event — causing visible delay on preview alpha.
  if ns.ArcAuras and ns.ArcAuras.frames and ns.ArcAuras.UpdateArcItemFrame then
    for arcID, frame in pairs(ns.ArcAuras.frames) do
      if not frame._arcIsSpellCooldown then
        frame._lastAppliedAlpha = nil
        frame._lastDesatState = nil
        ns.ArcAuras.UpdateArcItemFrame(frame, arcID)
      end
    end
  end
end


-- ═══════════════════════════════════════════════════════════════════════════
-- COOLDOWN STATE: EVENT-DRIVEN ARCHITECTURE
--
-- In-combat cooldown state updates are handled by per-frame hooks:
--   - hooksecurefunc(frame, "OnSpellUpdateCooldownEvent") → SPELL_UPDATE_COOLDOWN
--   - Shadow OnCooldownDone → natural timer expiry
--   - CDM Cooldown OnCooldownDone → GCD/CD widget expiry
--
-- This replaces the old global SPELL_UPDATE_COOLDOWN handler that iterated
-- ALL frames on every event with 20Hz throttle.
--
-- The sweep function below is called by the 0.5s out-of-combat ticker
-- for safety: handles edge cases like options panel preview, cooldowns
-- ===================================================================
-- GROUP SCALE API
-- Per-group scale override (separate from global defaults)
-- Now using spec-based storage
-- ===================================================================

-- Get group scale for a viewer type (nil = use Edit Mode scale)
local function GetGroupScaleValue(viewerType)
  local groupSettings = Shared.GetGroupSettingsForType(viewerType)
  if not groupSettings then return nil end
  return groupSettings.scale
end

-- Check if custom scale is enabled for a viewer type
local function IsGroupScaleOverrideEnabled(viewerType)
  return GetGroupScaleValue(viewerType) ~= nil
end

-- Public API for group scale
function ns.CDMEnhance.GetGroupScaleValue(viewerType)
  return GetGroupScaleValue(viewerType)
end

function ns.CDMEnhance.IsGroupScaleOverrideEnabled(viewerType)
  return IsGroupScaleOverrideEnabled(viewerType)
end

local scaleSetThrottle = {}
function ns.CDMEnhance.SetGroupScale(viewerType, scale)
  -- Now using spec-based storage
  local groupSettings = Shared.GetSpecGroupSettings()
  if not groupSettings then return end
  
  if not groupSettings[viewerType] then
    groupSettings[viewerType] = {}
  end
  
  groupSettings[viewerType].scale = scale
  
  -- Invalidate cache so CDMGroups picks up new settings
  InvalidateEffectiveSettingsCache()
  
  -- Throttle the refresh to avoid lag while dragging slider
  local now = GetTime()
  if not scaleSetThrottle[viewerType] or (now - scaleSetThrottle[viewerType]) > 0.05 then
    scaleSetThrottle[viewerType] = now
    
    -- Refresh icon styles (CDMGroups handles size, we just update visuals)
    local refreshType = (viewerType == "aura") and "aura" or "cooldown"
    ns.CDMEnhance.RefreshIconType(refreshType)
    
    -- Tell CDMGroups to refresh layout
    if ns.CDMGroups and ns.CDMGroups.RefreshAllLayouts then
      ns.CDMGroups.RefreshAllLayouts()
    elseif ns.CDMGroupSettings and ns.CDMGroupSettings.ForceLayoutRefresh then
      ns.CDMGroupSettings.ForceLayoutRefresh(viewerType)
    end
  end
end

-- Alias for backwards compatibility - CDMGroups calls this
ns.CDMEnhance.RefreshAllStyles = ns.CDMEnhance.RefreshAllStyles or function() end
ns.CDMEnhance.RefreshAllIcons = ns.CDMEnhance.RefreshAllStyles

-- ===================================================================
-- ARC AURAS INTEGRATION
-- Arc Auras handles its own visual state (desaturation, glow)
-- This callback handles border sync
-- ===================================================================

--- Called by Arc Auras when an item's cooldown state changes
function ns.CDMEnhance.OnArcAuraStateChanged(arcID, isOnCooldown, remaining, duration)
    local frame = ns.ArcAuras and ns.ArcAuras.GetFrame and ns.ArcAuras.GetFrame(arcID)
    if not frame then return end
    
    -- Apply border desaturation sync if enabled
    if ns.CDMEnhance.ApplyBorderDesaturation then
        -- Arc Auras always desaturates unless noDesaturate is explicitly true
        local shouldDesaturate = isOnCooldown
        
        local cfg = ns.CDMEnhance.GetEffectiveIconSettings(arcID)
        if cfg and cfg.cooldownStateVisuals and cfg.cooldownStateVisuals.cooldownState then
            if cfg.cooldownStateVisuals.cooldownState.noDesaturate == true then
                shouldDesaturate = false
            end
        end
        
        ns.CDMEnhance.ApplyBorderDesaturation(frame, shouldDesaturate and 1 or 0)
    end
end


-- Expose namespace globally for external tools (like CDMAnimExplorer)
ArcUI_NS = ns