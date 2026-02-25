-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_AssistedCombatHighlight.lua
-- Standalone module: Brings Blizzard's Assisted Combat "next cast" highlight
-- to CDM frames AND Arc Auras Cooldown frames.
-- Supports two styles:
--   "ants"  = ActionBarButtonAssistedCombatHighlightTemplate (blue marching ants)
--   "proc"  = ActionButtonSpellAlertTemplate (golden proc burst + loop glow)
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...
ns.AssistedCombatHighlight = ns.AssistedCombatHighlight or {}
local ACH = ns.AssistedCombatHighlight

-- ═══════════════════════════════════════════════════════════════════════════
-- GUARD: Bail if Assisted Combat system doesn't exist (not on this build)
-- ═══════════════════════════════════════════════════════════════════════════
if not AssistedCombatManager or not C_AssistedCombat then
  ACH.available = false
  return
end
ACH.available = true

-- ═══════════════════════════════════════════════════════════════════════════
-- LOCALS
-- ═══════════════════════════════════════════════════════════════════════════
local enhancedFrames       -- resolved lazily from CDMEnhance
local highlightFrames = {} -- [key] = highlight frame (key = cdID or "aa_"..arcID)
local lastNextCastSpellID  = nil
local updateElapsed        = 0
local isActive             = false
local affectingCombat      = false
local lastArcAurasCount    = 0  -- Track spellData entry count for auto-detect

-- Default update interval (synced with AssistedCombatManager rate)
local DEFAULT_RATE = 0.1

-- Sizing ratios from Blizzard templates:
-- Ants: Container = 45x45, Flipbook texture = 66x66
local ANTS_FLIPBOOK_RATIO = 66 / 45
-- Proc: ProcStartFlipbook = 150x150 for a 45x45 icon
local PROC_START_RATIO = 150 / 45

-- ═══════════════════════════════════════════════════════════════════════════
-- MASQUE SHAPE INTEGRATION
-- When Masque skins a CDM frame with a custom shape (Circle, Hexagon, etc.),
-- our highlights must use matching shape textures. Without this, highlights
-- always render as default square/modern regardless of Masque skin.
-- ═══════════════════════════════════════════════════════════════════════════

-- Get Masque shape from a frame's _MSQ_CFG (set by Masque:AddButton)
local function GetMasqueShape(frame)
  if not frame then return nil end
  local mcfg = frame._MSQ_CFG
  if not mcfg or not mcfg.Enabled or mcfg.BaseSkin then return nil end
  return mcfg.Shape
end

-- Cached Masque API reference
local cachedMasqueAPI
local function GetMasqueAPI()
  if cachedMasqueAPI == nil then
    cachedMasqueAPI = LibStub and LibStub("Masque", true) or false
  end
  return cachedMasqueAPI or nil
end

-- Apply Masque shape to "ants" style highlight
-- Uses Masque:GetAssistedCombatHighlightStyle(shape) which returns:
--   { Texture, TexCoords, Width, Height, FrameWidth, FrameHeight }
local function ApplyMasqueAntsShape(highlight, shape)
  if not highlight or not shape or not highlight.Flipbook then return false end
  local api = GetMasqueAPI()
  if not api or not api.GetAssistedCombatHighlightStyle then return false end

  local ok, styleData = pcall(api.GetAssistedCombatHighlightStyle, api, shape)
  if not ok or not styleData then return false end

  -- Apply shape-matched texture
  if styleData.Texture then
    highlight.Flipbook:SetTexture(styleData.Texture)
  end
  if styleData.TexCoords then
    local tc = styleData.TexCoords
    highlight.Flipbook:SetTexCoord(tc[1] or 0, tc[2] or 1, tc[3] or 0, tc[4] or 1)
  end

  -- Apply flipbook animation frame dimensions
  -- highlight.Flipbook.Anim is an AnimationGroup; the FlipBook anim is a child
  if highlight.Flipbook.Anim then
    local animGroup = highlight.Flipbook.Anim
    -- Try named key first, then iterate to find FlipBook animation
    local flipAnim = animGroup.FlipAnim
    if not flipAnim then
      for _, child in pairs({animGroup:GetAnimations()}) do
        if child and child.SetFlipBookFrameWidth then
          flipAnim = child
          break
        end
      end
    end
    if flipAnim and flipAnim.SetFlipBookFrameWidth then
      flipAnim:SetFlipBookFrameWidth(styleData.FrameWidth or 0)
      flipAnim:SetFlipBookFrameHeight(styleData.FrameHeight or 0)
    end
  end

  -- Fix glitch: play then stop to reinitialize (Masque pattern)
  if highlight.Flipbook.Anim then
    highlight.Flipbook.Anim:Play()
    highlight.Flipbook.Anim:Stop()
  end

  highlight._achMasqueShape = shape
  return true
end

-- Apply Masque shape to "proc" style highlight
-- Uses Masque:GetSpellAlertFlipBook(styleName, shape) which returns:
--   { LoopTexture, StartTexture (optional), FrameWidth, FrameHeight, ... }
local function ApplyMasqueProcShape(highlight, shape)
  if not highlight or not shape then return false end
  local api = GetMasqueAPI()
  if not api or not api.GetSpellAlertFlipBook then return false end

  -- Try "Modern" style first (most common), then "Classic"
  local ok, flipData = pcall(api.GetSpellAlertFlipBook, api, "Modern", shape)
  if not ok or not flipData then
    ok, flipData = pcall(api.GetSpellAlertFlipBook, api, "Classic", shape)
  end
  if not ok or not flipData then return false end

  -- Apply loop texture
  if flipData.LoopTexture and highlight.ProcLoopFlipbook then
    highlight.ProcLoopFlipbook:SetTexture(flipData.LoopTexture)
  end

  -- Apply start texture (use loop as fallback — Masque pattern)
  if highlight.ProcStartFlipbook then
    if flipData.StartTexture then
      highlight.ProcStartFlipbook:SetTexture(flipData.StartTexture)
    elseif flipData.LoopTexture then
      highlight.ProcStartFlipbook:SetTexture(flipData.LoopTexture)
      -- When using loop texture as start, snap start to fill container
      highlight.ProcStartFlipbook:ClearAllPoints()
      highlight.ProcStartFlipbook:SetAllPoints()
    end
  end

  -- Apply flipbook animation dimensions to ProcLoop
  -- Blizzard template stores FlipBook anim as named child; LCG uses .flipbookRepeat
  local loopAnimGroup = highlight.ProcLoopAnim or highlight.ProcLoop
  if loopAnimGroup and flipData.FrameWidth then
    local loopFlipAnim = loopAnimGroup.FlipAnim or loopAnimGroup.flipbookRepeat
    if loopFlipAnim and loopFlipAnim.SetFlipBookFrameWidth then
      loopFlipAnim:SetFlipBookFrameWidth(flipData.FrameWidth or 0)
      loopFlipAnim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
    end
  end

  -- Apply to ProcStartAnim as well
  if highlight.ProcStartAnim and flipData.FrameWidth then
    local startFlipAnim = highlight.ProcStartAnim.FlipAnim or highlight.ProcStartAnim.flipbookStart
    if startFlipAnim and startFlipAnim.SetFlipBookFrameWidth then
      startFlipAnim:SetFlipBookFrameWidth(flipData.FrameWidth or 0)
      startFlipAnim:SetFlipBookFrameHeight(flipData.FrameHeight or 0)
    end
  end

  highlight._achMasqueShape = shape
  return true
end

-- Apply Masque shape to a highlight (dispatches by style)
local function ApplyMasqueShape(highlight, parentFrame)
  if not highlight or not parentFrame then return end
  local shape = GetMasqueShape(parentFrame)
  if not shape then
    highlight._achMasqueShape = nil
    return
  end

  if highlight._achStyle == "proc" then
    ApplyMasqueProcShape(highlight, shape)
  else -- ants
    ApplyMasqueAntsShape(highlight, shape)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DB ACCESS
-- ═══════════════════════════════════════════════════════════════════════════
local function GetDB()
  -- Access raw SavedVariables directly, same as Arc Auras
  if not ArcUIDB then return nil end
  if not ArcUIDB.char then ArcUIDB.char = {} end

  local playerName = UnitName("player")
  local realmName = GetRealmName()
  if not playerName or playerName == "" or not realmName or realmName == "" then
    return nil
  end

  local charKey = playerName .. " - " .. realmName
  if not ArcUIDB.char[charKey] then ArcUIDB.char[charKey] = {} end

  local charDB = ArcUIDB.char[charKey]

  -- Initialize achSettings if missing
  if not charDB.achSettings then
    charDB.achSettings = {
      assistedCombatHighlight = false,
      achOnArcAuras = false,
      achCombatOnly = false,
      achStrata = "INHERIT",
      achLevel = 5,
      achScale = 1.0,
      achStyle = "ants",
      achShowBurst = true,
      achAlwaysAnimate = false,
      achColor = { r = 1, g = 1, b = 1, a = 1 },
    }
  end

  -- ONE-TIME MIGRATION: Move settings from old profile location
  if not charDB.achSettings._migrated then
    if ns.db and ns.db.profile and ns.db.profile.cdmEnhance then
      local old = ns.db.profile.cdmEnhance
      if old.assistedCombatHighlight ~= nil then charDB.achSettings.assistedCombatHighlight = old.assistedCombatHighlight end
      if old.achOnArcAuras ~= nil then charDB.achSettings.achOnArcAuras = old.achOnArcAuras end
      if old.achCombatOnly ~= nil then charDB.achSettings.achCombatOnly = old.achCombatOnly end
      if old.achStrata ~= nil then charDB.achSettings.achStrata = old.achStrata end
      if old.achLevel ~= nil then charDB.achSettings.achLevel = old.achLevel end
      if old.achScale ~= nil then charDB.achSettings.achScale = old.achScale end
      if old.achStyle ~= nil then charDB.achSettings.achStyle = old.achStyle end
      if old.achShowBurst ~= nil then charDB.achSettings.achShowBurst = old.achShowBurst end
      if old.achAlwaysAnimate ~= nil then charDB.achSettings.achAlwaysAnimate = old.achAlwaysAnimate end
      if old.achColor ~= nil then charDB.achSettings.achColor = old.achColor end
    end
    charDB.achSettings._migrated = true
  end

  return charDB.achSettings
end

local function IsEnabled()
  local db = GetDB()
  if not db then return false end
  if db.assistedCombatHighlight == nil then return false end
  return db.assistedCombatHighlight
end

local function IsArcAurasEnabled()
  local db = GetDB()
  return db and db.achOnArcAuras or false
end

local function IsCombatOnly()
  local db = GetDB()
  return db and db.achCombatOnly or false
end

local function GetStrata()
  local db = GetDB()
  return db and db.achStrata or "INHERIT"
end

local function GetLevelOffset()
  local db = GetDB()
  return db and db.achLevel or 5
end

local function GetGlowScale()
  local db = GetDB()
  return db and db.achScale or 1.0
end

local function GetStyle()
  local db = GetDB()
  return db and db.achStyle or "ants"
end

local function GetShowBurst()
  local db = GetDB()
  if not db then return true end
  if db.achShowBurst == nil then return true end
  return db.achShowBurst
end

local function GetAlwaysAnimate()
  local db = GetDB()
  return db and db.achAlwaysAnimate or false
end

local function GetColor()
  local db = GetDB()
  if not db or not db.achColor then return 1, 1, 1, 1 end
  local c = db.achColor
  return c.r or 1, c.g or 1, c.b or 1, c.a or 1
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELL MATCHING (CDM frames — uses cooldownInfo spell chain)
-- ═══════════════════════════════════════════════════════════════════════════
local function CDMFrameMatchesSpell(frame, targetSpellID)
  if not frame or not targetSpellID then return false end

  local info = frame.cooldownInfo
  if not info then return false end

  -- Any cooldownInfo field can be secret in combat — wrap everything in pcall
  local ok, matched = pcall(function()
    if info.spellID and info.spellID == targetSpellID then return true end
    if info.overrideSpellID and info.overrideSpellID == targetSpellID then return true end
    if info.overrideTooltipSpellID and info.overrideTooltipSpellID == targetSpellID then return true end
    if info.linkedSpellID and info.linkedSpellID == targetSpellID then return true end

    if info.linkedSpellIDs then
      for _, linkedID in ipairs(info.linkedSpellIDs) do
        if linkedID == targetSpellID then return true end
      end
    end

    if frame.GetAuraSpellID then
      local auraSpellID = frame:GetAuraSpellID()
      if auraSpellID and auraSpellID == targetSpellID then return true end
    end

    return false
  end)

  return ok and matched or false
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RESIZE HIGHLIGHT (style-aware)
-- ═══════════════════════════════════════════════════════════════════════════
local function ResizeHighlight(highlight, iconW, iconH)
  if not highlight then return end
  local scale = GetGlowScale()
  local scaledW, scaledH = iconW * scale, iconH * scale

  if highlight._achStyle == "proc" then
    -- The proc glow is designed to extend beyond the icon edge.
    -- ProcLoopFlipbook uses setAllPoints (fills the container), so
    -- the container itself must be larger than the icon.
    -- Use the same expansion ratio as the ants flipbook (66/45 ≈ 1.467)
    -- so glow spill is proportional across both styles.
    local containerW = scaledW * ANTS_FLIPBOOK_RATIO
    local containerH = scaledH * ANTS_FLIPBOOK_RATIO
    highlight:SetSize(containerW, containerH)
    -- ProcStartFlipbook (burst) is even larger — 150/45 ratio relative to icon
    if highlight.ProcStartFlipbook then
      highlight.ProcStartFlipbook:SetSize(scaledW * PROC_START_RATIO, scaledH * PROC_START_RATIO)
    end
  else -- ants
    highlight:SetSize(scaledW, scaledH)
    if highlight.Flipbook then
      highlight.Flipbook:SetSize(scaledW * ANTS_FLIPBOOK_RATIO, scaledH * ANTS_FLIPBOOK_RATIO)
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- APPLY COLOR (style-aware)
-- ═══════════════════════════════════════════════════════════════════════════
local function ApplyColor(highlight)
  if not highlight then return end
  local r, g, b, a = GetColor()
  -- Both templates have base color baked in. Desaturate strips it so
  -- SetVertexColor gives the actual chosen color instead of multiplying.
  local hasCustomColor = not (r >= 0.99 and g >= 0.99 and b >= 0.99)

  if highlight._achStyle == "proc" then
    if highlight.ProcStartFlipbook then
      highlight.ProcStartFlipbook:SetDesaturated(hasCustomColor)
      highlight.ProcStartFlipbook:SetVertexColor(r, g, b)
      highlight.ProcStartFlipbook:SetAlpha(a)
    end
    if highlight.ProcLoopFlipbook then
      highlight.ProcLoopFlipbook:SetDesaturated(hasCustomColor)
      highlight.ProcLoopFlipbook:SetVertexColor(r, g, b)
    end
    if highlight.ProcAltGlow then
      highlight.ProcAltGlow:SetDesaturated(hasCustomColor)
      highlight.ProcAltGlow:SetVertexColor(r, g, b)
    end
  else -- ants
    if highlight.Flipbook then
      highlight.Flipbook:SetDesaturated(hasCustomColor)
      highlight.Flipbook:SetVertexColor(r, g, b)
      highlight.Flipbook:SetAlpha(a)
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- APPLY STRATA + LEVEL
-- ═══════════════════════════════════════════════════════════════════════════
local function ApplyStrata(highlight)
  if not highlight then return end
  local parent = highlight:GetParent()
  if not parent then return end

  local strata = GetStrata()
  if strata == "INHERIT" then
    highlight:SetFrameStrata(parent:GetFrameStrata())
  else
    highlight:SetFrameStrata(strata)
  end

  local levelOffset = GetLevelOffset()
  highlight:SetFrameLevel(parent:GetFrameLevel() + levelOffset)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GET EFFECTIVE FRAME SIZE
-- ═══════════════════════════════════════════════════════════════════════════
local function GetEffectiveFrameSize(frame)
  local w, h = frame:GetWidth(), frame:GetHeight()
  if not w or not h or w <= 1 or h <= 1 then
    w = frame._cdmgTargetSize or frame._arcOrigW or 36
    h = frame._cdmgTargetSize or frame._arcOrigH or 36
  end
  return w, h
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SET ANIMATION STATE (style-aware: play in combat, stop out of combat)
-- ═══════════════════════════════════════════════════════════════════════════
local function SetAnimState(hl)
  if not hl or not hl:IsShown() then return end
  local shouldAnimate = affectingCombat or GetAlwaysAnimate()

  if hl._achStyle == "proc" then
    if shouldAnimate then
      if hl.ProcLoop and not hl.ProcLoop:IsPlaying() then
        hl.ProcLoop:Play()
      end
    else
      -- Frozen: stop all animations and hide the start burst completely
      -- so only the static loop first-frame is visible (no overlap)
      if hl.ProcStartAnim and hl.ProcStartAnim:IsPlaying() then
        hl.ProcStartAnim:Stop()
      end
      if hl.ProcStartFlipbook then
        hl.ProcStartFlipbook:SetAlpha(0)
        hl.ProcStartFlipbook:Hide()
      end
      if hl.ProcLoop and hl.ProcLoop:IsPlaying() then
        hl.ProcLoop:Stop()
      end
      -- Ensure loop flipbook is visible as a static glow
      if hl.ProcLoopFlipbook then
        hl.ProcLoopFlipbook:SetAlpha(1)
        hl.ProcLoopFlipbook:Show()
      end
    end
  else -- ants
    if not hl.Flipbook or not hl.Flipbook.Anim then return end
    if shouldAnimate then
      if not hl.Flipbook.Anim:IsPlaying() then
        hl.Flipbook.Anim:Play()
      end
    else
      if hl.Flipbook.Anim:IsPlaying() then
        hl.Flipbook.Anim:Stop()
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SIZE HOOK: Auto-resize highlight when parent icon resizes (zero polling)
-- ═══════════════════════════════════════════════════════════════════════════
local function InstallSizeHook(frame)
  if frame._achSizeHooked then return end
  frame._achSizeHooked = true

  local function OnParentResized()
    -- Find highlight owned by this frame (check all since key may change on recycle)
    for key, hl in pairs(highlightFrames) do
      if hl and hl:GetParent() == frame and hl:IsShown() then
        local w, h = GetEffectiveFrameSize(frame)
        ResizeHighlight(hl, w, h)
        return
      end
    end
  end

  hooksecurefunc(frame, "SetSize", function() OnParentResized() end)
  hooksecurefunc(frame, "SetWidth", function() OnParentResized() end)
  hooksecurefunc(frame, "SetHeight", function() OnParentResized() end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HIGHLIGHT FRAME CREATION (style-aware)
-- ═══════════════════════════════════════════════════════════════════════════
local function GetOrCreateHighlight(frame, key)
  local existing = highlightFrames[key]
  local style = GetStyle()

  -- If parent changed OR style changed, destroy old and recreate
  if existing and (existing:GetParent() ~= frame or existing._achStyle ~= style) then
    existing:Hide()
    existing:ClearAllPoints()
    existing:SetParent(nil)
    highlightFrames[key] = nil
    existing = nil
  end

  local w, h = GetEffectiveFrameSize(frame)

  -- Size check for existing highlight
  if existing then
    local scale = GetGlowScale()
    if existing._achStyle == "proc" then
      local ew, eh = existing:GetSize()
      local tw = w * scale * ANTS_FLIPBOOK_RATIO
      local th = h * scale * ANTS_FLIPBOOK_RATIO
      if math.abs(ew - tw) > 0.5 or math.abs(eh - th) > 0.5 then
        ResizeHighlight(existing, w, h)
      end
    else -- ants
      if existing.Flipbook then
        local fw, fh = existing.Flipbook:GetSize()
        local tw, th = w * scale * ANTS_FLIPBOOK_RATIO, h * scale * ANTS_FLIPBOOK_RATIO
        if math.abs(fw - tw) > 0.5 or math.abs(fh - th) > 0.5 then
          ResizeHighlight(existing, w, h)
        end
      end
    end
    -- Check if Masque shape changed (user switched skin)
    local currentShape = GetMasqueShape(frame)
    if existing._achMasqueShape ~= currentShape then
      ApplyMasqueShape(existing, frame)
      ApplyColor(existing)  -- Re-apply color after shape texture change
    end
    return existing
  end

  -- ── Create new highlight based on style ──
  local highlight

  if style == "proc" then
    highlight = CreateFrame("FRAME", nil, frame, "ActionButtonSpellAlertTemplate")
    highlight:SetPoint("CENTER")
    highlight._achStyle = "proc"

    -- Wire ProcStartAnim → ProcLoop chain
    if highlight.ProcStartAnim then
      highlight.ProcStartAnim:SetScript("OnFinished", function()
        if highlight.ProcLoop then
          highlight.ProcLoop:Play()
        end
      end)
    end

    -- Initialize: show loop flipbook at first frame
    if highlight.ProcLoopFlipbook then
      highlight.ProcLoopFlipbook:SetAlpha(1)
      highlight.ProcLoopFlipbook:Show()
    end
    if highlight.ProcLoop then
      highlight.ProcLoop:Play()
      highlight.ProcLoop:Stop()
    end

  else -- ants (default)
    highlight = CreateFrame("FRAME", nil, frame, "ActionBarButtonAssistedCombatHighlightTemplate")
    highlight:SetPoint("CENTER")
    highlight._achStyle = "ants"

    -- Initialize flipbook to first frame (Blizzard pattern)
    if highlight.Flipbook and highlight.Flipbook.Anim then
      highlight.Flipbook.Anim:Play()
      highlight.Flipbook.Anim:Stop()
    end
  end

  ApplyStrata(highlight)
  ResizeHighlight(highlight, w, h)
  ApplyMasqueShape(highlight, frame)  -- Apply shape BEFORE color (shape changes textures)
  ApplyColor(highlight)
  InstallSizeHook(frame)

  highlight:Hide()
  highlightFrames[key] = highlight
  return highlight
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SHOW / HIDE HELPERS
-- ═══════════════════════════════════════════════════════════════════════════
local function ShowHighlight(frame, key)
  local hl = GetOrCreateHighlight(frame, key)
  hl:Show()

  -- Proc style: optionally play burst intro, then chain to loop
  if hl._achStyle == "proc" then
    if hl.ProcLoopFlipbook then
      hl.ProcLoopFlipbook:SetAlpha(1)
      hl.ProcLoopFlipbook:Show()
    end

    local shouldAnimate = affectingCombat or GetAlwaysAnimate()
    local showBurst = GetShowBurst()

    if shouldAnimate and showBurst and hl.ProcStartAnim and not hl._achBurstPlayed then
      -- Play burst intro (chains to ProcLoop via OnFinished)
      if hl.ProcStartFlipbook then
        hl.ProcStartFlipbook:SetAlpha(1)
        hl.ProcStartFlipbook:Show()
      end
      hl.ProcStartAnim:Play()
      hl._achBurstPlayed = true
    else
      -- No burst: hide start flipbook entirely
      if hl.ProcStartFlipbook then
        hl.ProcStartFlipbook:SetAlpha(0)
        hl.ProcStartFlipbook:Hide()
      end
    end
  end

  SetAnimState(hl)
end

local function HideHighlight(key)
  local hl = highlightFrames[key]
  if hl then
    hl:Hide()
    -- Reset burst flag so it plays again on next show
    hl._achBurstPlayed = nil
    -- Stop animations cleanly
    if hl._achStyle == "proc" then
      if hl.ProcStartAnim and hl.ProcStartAnim:IsPlaying() then
        hl.ProcStartAnim:Stop()
      end
      if hl.ProcLoop and hl.ProcLoop:IsPlaying() then
        hl.ProcLoop:Stop()
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CORE UPDATE: Find matching CDM + Arc Auras frames, show/hide highlights
-- ═══════════════════════════════════════════════════════════════════════════
local function UpdateHighlights(nextSpellID)
  -- Combat-only: hide everything when out of combat
  if IsCombatOnly() and not affectingCombat then
    for key, hl in pairs(highlightFrames) do
      if hl then
        hl:Hide()
        hl._achBurstPlayed = nil
      end
    end
    return
  end

  -- Lazy-resolve CDM enhancedFrames
  if not enhancedFrames then
    if ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrames then
      enhancedFrames = ns.CDMEnhance.GetEnhancedFrames()
    end
  end

  -- ── CDM frames ──
  -- Only match cooldown viewer frames (essential + utility).
  -- Skip aura/buff frames — they can share spellIDs with cooldowns
  -- but should not get the assisted combat highlight.
  local matchedCdID = nil
  if enhancedFrames and nextSpellID then
    for cdID, data in pairs(enhancedFrames) do
      if data and data.frame and data.frame:IsShown() then
        local vt = data.viewerType
        if vt == "cooldown" then
          if CDMFrameMatchesSpell(data.frame, nextSpellID) then
            matchedCdID = cdID
            break
          end
        end
      end
    end
  end

  if enhancedFrames then
    for cdID, data in pairs(enhancedFrames) do
      local vt = data and data.viewerType
      if vt ~= "cooldown" then
        -- Not a cooldown frame — hide any stale highlight and skip
        HideHighlight(cdID)
      elseif not data or not data.frame then
        HideHighlight(cdID)
      elseif cdID == matchedCdID then
        ShowHighlight(data.frame, cdID)
      else
        HideHighlight(cdID)
      end
    end
  end

  -- ── STALE HIGHLIGHT CLEANUP ──
  -- If a cdID was removed from enhancedFrames (frame recycled/spec change),
  -- or its parent frame is gone, hide and remove the orphaned highlight.
  -- Only checks CDM keys (not "aa_" prefixed Arc Auras keys).
  for key, hl in pairs(highlightFrames) do
    if type(key) ~= "string" or not key:find("^aa_") then
      -- CDM-keyed highlight — verify it's still valid
      if not enhancedFrames or not enhancedFrames[key] then
        -- cdID no longer in enhancedFrames — orphaned
        if hl then
          hl:Hide()
          hl:ClearAllPoints()
          hl:SetParent(nil)
        end
        highlightFrames[key] = nil
      elseif hl then
        -- cdID exists but check parent frame is still correct
        local data = enhancedFrames[key]
        local parent = hl:GetParent()
        if parent and data and data.frame and parent ~= data.frame then
          -- Parent changed (frame recycled) — destroy stale highlight
          hl:Hide()
          hl:ClearAllPoints()
          hl:SetParent(nil)
          highlightFrames[key] = nil
        end
      end
    end
  end

  -- ── Arc Auras Cooldown frames ──
  local arcAurasEnabled = IsArcAurasEnabled()
  local AACooldown = ns.ArcAurasCooldown
  local spellData = AACooldown and AACooldown.spellData

  if spellData then
    if arcAurasEnabled and nextSpellID then
      local matchedArcID = AACooldown.spellsByID and AACooldown.spellsByID[nextSpellID]

      for arcID, fd in pairs(spellData) do
        local key = "aa_" .. arcID
        if not fd or not fd.frame then
          HideHighlight(key)
        elseif arcID == matchedArcID and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
          ShowHighlight(fd.frame, key)
        else
          HideHighlight(key)
        end
      end
    else
      for arcID, _ in pairs(spellData) do
        HideHighlight("aa_" .. arcID)
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HIDE ALL HIGHLIGHTS
-- ═══════════════════════════════════════════════════════════════════════════
local function HideAllHighlights()
  for key, hl in pairs(highlightFrames) do
    if hl then
      hl:Hide()
      hl._achBurstPlayed = nil
    end
  end
  lastNextCastSpellID = nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- COMBAT STATE CHANGE
-- ═══════════════════════════════════════════════════════════════════════════
local function OnCombatChanged()
  affectingCombat = UnitAffectingCombat("player")
  -- Force immediate re-evaluation (combat-only toggle needs this)
  lastNextCastSpellID = nil
  updateElapsed = 999
  -- Reset burst flag on combat enter so the intro plays fresh
  if affectingCombat then
    for _, hl in pairs(highlightFrames) do
      if hl then hl._achBurstPlayed = nil end
    end
  end
  for _, hl in pairs(highlightFrames) do
    SetAnimState(hl)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ONUPDATE
-- ═══════════════════════════════════════════════════════════════════════════
local function OnUpdate(self, elapsed)
  updateElapsed = updateElapsed + elapsed

  local rate = AssistedCombatManager:GetUpdateRate()
  if rate <= 0 then rate = DEFAULT_RATE end

  if updateElapsed < rate then return end
  updateElapsed = 0

  -- Auto-detect new/removed Arc Auras frames (cheap count check)
  if IsArcAurasEnabled() then
    local AACooldown = ns.ArcAurasCooldown
    local spellData = AACooldown and AACooldown.spellData
    if spellData then
      local count = 0
      for _ in pairs(spellData) do count = count + 1 end
      if count ~= lastArcAurasCount then
        lastArcAurasCount = count
        lastNextCastSpellID = nil  -- Force re-evaluation
      end
    end
  end

  local spellID = C_AssistedCombat.GetNextCastSpell(false)

  if spellID ~= lastNextCastSpellID then
    lastNextCastSpellID = spellID
    UpdateHighlights(spellID)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API: Bulk updates from options panel
-- ═══════════════════════════════════════════════════════════════════════════
function ACH.RecolorAll()
  for _, hl in pairs(highlightFrames) do
    ApplyColor(hl)
  end
end

function ACH.RestrataAll()
  for _, hl in pairs(highlightFrames) do
    ApplyStrata(hl)
  end
end

function ACH.ResizeAll()
  for _, hl in pairs(highlightFrames) do
    if hl then
      local parent = hl:GetParent()
      if parent then
        local w, h = GetEffectiveFrameSize(parent)
        ResizeHighlight(hl, w, h)
      end
    end
  end
end

function ACH.RefreshAnimAll()
  for _, hl in pairs(highlightFrames) do
    SetAnimState(hl)
  end
end

-- Re-apply Masque shapes on all highlights (called when user changes Masque skin)
function ACH.RefreshMasqueShapes()
  -- Clear cached API in case Masque was enabled/disabled
  cachedMasqueAPI = nil
  -- Clear shape cache on all highlights so they re-detect on next show
  for key, hl in pairs(highlightFrames) do
    if hl then
      hl._achMasqueShape = nil
    end
  end
  -- Force full re-evaluation
  lastNextCastSpellID = nil
  updateElapsed = 999
end

-- Destroy all highlights and force recreation (used when style changes)
function ACH.DestroyAllHighlights()
  for key, hl in pairs(highlightFrames) do
    if hl then
      hl:Hide()
      hl:ClearAllPoints()
      hl:SetParent(nil)
    end
    highlightFrames[key] = nil
  end
  lastNextCastSpellID = nil
  lastArcAurasCount = 0
  updateElapsed = 999
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API: Enable / Disable / Refresh
-- ═══════════════════════════════════════════════════════════════════════════
local updateFrame = nil

function ACH.Enable()
  if isActive then return end
  isActive = true

  if not updateFrame then
    updateFrame = CreateFrame("Frame")
  end

  affectingCombat = UnitAffectingCombat("player")
  updateFrame:SetScript("OnUpdate", OnUpdate)

  EventRegistry:RegisterFrameEventAndCallback("PLAYER_REGEN_ENABLED", OnCombatChanged, ACH)
  EventRegistry:RegisterFrameEventAndCallback("PLAYER_REGEN_DISABLED", OnCombatChanged, ACH)
  EventRegistry:RegisterCallback("AssistedCombatManager.RotationSpellsUpdated", ACH.Refresh, ACH)

  ACH.Refresh()

  if ns.devMode then
    print("|cff00FF00[ArcUI]|r Assisted Combat Highlight enabled")
  end
end

function ACH.Disable()
  if not isActive then return end
  isActive = false

  if updateFrame then
    updateFrame:SetScript("OnUpdate", nil)
  end

  EventRegistry:UnregisterFrameEventAndCallback("PLAYER_REGEN_ENABLED", ACH)
  EventRegistry:UnregisterFrameEventAndCallback("PLAYER_REGEN_DISABLED", ACH)
  EventRegistry:UnregisterCallback("AssistedCombatManager.RotationSpellsUpdated", ACH)

  HideAllHighlights()

  if ns.devMode then
    print("|cffFF6600[ArcUI]|r Assisted Combat Highlight disabled")
  end
end

function ACH.Refresh()
  enhancedFrames = nil
  lastNextCastSpellID = nil
  lastArcAurasCount = 0
  updateElapsed = 999
end

function ACH.IsActive()
  return isActive
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME LIFECYCLE: Called by CDMEnhance when CDM frames are released/recycled
-- ═══════════════════════════════════════════════════════════════════════════
function ACH.OnFrameReleased(cdID)
  if highlightFrames[cdID] then
    highlightFrames[cdID]:Hide()
    highlightFrames[cdID]:ClearAllPoints()
    highlightFrames[cdID]:SetParent(nil)
    highlightFrames[cdID] = nil
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event)
  self:UnregisterAllEvents()

  C_Timer.After(2, function()
    if not IsEnabled() then return end

    local avail = C_AssistedCombat.IsAvailable()
    if avail then
      ACH.Enable()
      -- Second refresh after Arc Auras Cooldown has had time to register spells
      C_Timer.After(3, function()
        if isActive then ACH.Refresh() end
      end)
    else
      EventRegistry:RegisterCallback("AssistedCombatManager.RotationSpellsUpdated", function()
        if not isActive and IsEnabled() then
          local a = C_AssistedCombat.IsAvailable()
          if a then
            ACH.Enable()
          end
        end
      end, ACH)
    end
  end)
end)