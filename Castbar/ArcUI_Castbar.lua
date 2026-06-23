-- ===================================================================
-- ArcUI_Castbar.lua
-- Player castbar - single bar showing cast progress
-- Similar in structure to resource bars (movable, configurable appearance)
-- OnUpdate only runs during an active cast (zero idle CPU)
-- ===================================================================

local ADDON, ns = ...
ns.Castbar = ns.Castbar or {}

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local function PixelSize(n) return math.floor(n + 0.5) end

-- Format the cast timer text per cfg.timerFormat: "remaining" (1.2), "elapsed" (0.8),
-- or "both" (0.8/2.0 — elapsed over total).
local function FormatTimer(cfg, remaining, total)
  remaining = math.max(0, remaining or 0)
  total     = total or 0
  local fmt = (cfg and cfg.timerFormat) or "remaining"
  if fmt == "elapsed" then
    return string.format("%.1f", math.max(0, total - remaining))
  elseif fmt == "both" then
    return string.format("%.1f/%.1f", math.max(0, total - remaining), total)
  end
  return string.format("%.1f", remaining)
end

-- ===================================================================
-- DB ACCESSOR
-- ===================================================================
local function GetCastbarDB()
  -- Resolve via the shared-aware store so shared-castbar mode (account-wide) is honored.
  local store = ns.API and ns.API.GetCastbarStore and ns.API.GetCastbarStore()
  -- Phase 1: operate on instance 1 (today's single bar). Multi-instance routing lands in Phase 2.
  return store and store.castbars and store.castbars[1]
end

-- Bar LOCATION resolver. In shared mode the on-screen position stays PER-CHARACTER unless the user
-- opts to share location too (castbarShareLocation). Only barPosition routes through this; the look
-- (and the icon's offset relative to the bar) stays on the normal shared store.
local function GetCastbarPositionCfg()
  local g = ns.db and ns.db.global
  if g and g.castbarShared and not g.castbarShareLocation then
    local c = ns.db.char
    return c and c.castbars and c.castbars[1]
  end
  return GetCastbarDB()
end
ns.Castbar.GetPositionCfg = GetCastbarPositionCfg  -- exposed so the options X/Y sliders edit the same store

-- ===================================================================
-- CAST STATE
-- ===================================================================
local castFrameObj = nil
local castTextFrame = nil
local castActive = false
local castIsChannel = false
local castIsEmpowered = false
local castEmpowerNumStages = 0
local castEmpowerStageProps = {}  -- [i] = 0-1 proportion of bar width for stage-i boundary
local castStartTime = 0
local castEndTime = 0
local castPreviewActive = false
local castTimingRefined = false
local castActiveSpellID    = 0     -- spellID of current cast (for override re-apply on appearance change)
local castNotInterruptible = false -- true when the current cast cannot be interrupted
local castColorLocked = false      -- true when a fixed color (override/uninterruptible) overrides thresholds
local castFading = false           -- true while an interrupt/cancel feedback bar is fading out
local fadeStart = 0                -- GetTime() when the fade-out started
local activeTicks = 0              -- number of tick dividers currently shown (0 = none)
local castCurrentGUID  = nil   -- GUID from the CHANNEL/EMPOWER_START that opened the current bar
local castChannelEnded = false -- true between CHANNEL_STOP and the next CHANNEL_START (hold window)
local channelStopTime  = 0     -- GetTime() when CHANNEL_STOP fired
-- ===================================================================
-- DEBUG
-- Toggle with /arccastdebug
-- ===================================================================
local arcCastDebug = false
local function CastDebug(...)
  if arcCastDebug then print("|cff00ff00[ArcCast]|r", ...) end
end

-- ===================================================================
-- CAST-TYPE PROFILES + AUTO SHARE (resource-bar style, keyed by cast type)
-- One bar, one location; appearance can differ per cast type. Each Auto Share
-- category is either shared across all types (lives in base cfg) or customised
-- per type (lives in cfg.profiles[hardcast|channel|empower]).
-- ===================================================================
-- Which Auto Share category a per-type key belongs to. Keys not listed are always
-- shared (size, position, icon, empower segments, uninterruptible, behavior, etc.).
local CASTBAR_CATEGORY = {
  -- colors
  barColor = "colors", conditionalColorEnabled = "colors", colorThresholds = "colors",
  conditionalColorAsSec = "colors",
  -- fill
  texture = "fill", opacity = "fill", reverseFill = "fill",
  -- text
  showText = "text", showTimer = "text", font = "text", fontSize = "text",
  textColor = "text", textOutline = "text",
  -- background
  showBackground = "background", backgroundColor = "background",
  -- border
  showBorder = "border", borderColor = "border", drawnBorderThickness = "border",
  -- tick marks
  tickMarksEnabled   = "tickMarks", tickShowOn          = "tickMarks",
  tickMode           = "tickMarks", tickPercent         = "tickMarks",
  tickCustom         = "tickMarks", tickMarksColor      = "tickMarks",
  tickMarksThickness = "tickMarks", tickMarksHeightFraction = "tickMarks",
  tickHeightAnchor   = "tickMarks", tickThicknessAnchor = "tickMarks",
}
ns.Castbar.CATEGORY = CASTBAR_CATEGORY

-- True when a key is customised per cast type. Per-type unless its category is explicitly
-- shared (checkbox ticked). Default (unchecked / nil) = per-type.
local function IsKeyProfiled(cfg, key)
  local cat = CASTBAR_CATEGORY[key]
  if not cat then return false end
  local share = cfg.autoShareCategories
  return not (share and share[cat])
end
ns.Castbar.IsKeyProfiled = IsKeyProfiled

-- Read-only view of cfg for a cast type: per-type keys come from cfg.profiles[type];
-- everything else falls through to the base config via the metatable.
local function EffectiveCfg(cfg, castType)
  if not cfg or not castType then return cfg end
  local prof = cfg.profiles and cfg.profiles[castType]
  if not prof then return cfg end
  local e = setmetatable({}, { __index = cfg })
  for k, v in pairs(prof) do
    if IsKeyProfiled(cfg, k) then e[k] = v end
  end
  return e
end
ns.Castbar.EffectiveCfg = EffectiveCfg

-- Cast type currently displayed: the live cast's type, else the options-edited profile.
local function ResolveDisplayType()
  if castActive then
    return castIsEmpowered and "empower" or (castIsChannel and "channel") or "hardcast"
  end
  return (ns.CastbarOptions and ns.CastbarOptions._editProfile) or "hardcast"
end
ns.Castbar.ResolveDisplayType = ResolveDisplayType

-- cfg resolved for the current display type — use for all per-type appearance reads.
local function GetEffectiveCfg()
  local c = GetCastbarDB()
  if not c then return nil end
  return EffectiveCfg(c, ResolveDisplayType())
end

local function TruncateSpellName(name, cfg)
  if type(name) ~= "string" or not cfg.spellShortenEnabled then return name end
  local limit = cfg.spellShortenLength or 20
  if string.len(name) > limit then
    return string.sub(name, 1, limit) .. ".."
  end
  return name
end

-- ===================================================================
-- FRAME CREATION
-- ===================================================================
local function CreateCastbarFrames()
  -- Main bar frame
  local frame = CreateFrame("Frame", "ArcUICastbarMain", UIParent)
  frame:SetSize(250, 20)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(false)

  -- Background
  frame.bg = frame:CreateTexture(nil, "BACKGROUND")
  frame.bg:SetAllPoints()
  frame.bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)
  frame.bg:SetSnapToPixelGrid(false)
  frame.bg:SetTexelSnappingBias(0)

  -- Cast fill bar
  frame.fillBar = CreateFrame("StatusBar", nil, frame)
  frame.fillBar:SetAllPoints(frame)
  frame.fillBar:SetMinMaxValues(0, 1)
  frame.fillBar:SetValue(0)
  frame.fillBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  frame.fillBar:SetStatusBarColor(0.2, 0.8, 1, 1)
  frame.fillBar:SetFrameLevel(frame:GetFrameLevel() + 2)

  -- Border overlay (4 separate textures for pixel-perfect edges)
  frame.borderOverlay = CreateFrame("Frame", nil, frame)
  frame.borderOverlay:SetAllPoints()
  frame.borderOverlay:SetFrameLevel(frame:GetFrameLevel() + 10)
  frame.borderOverlay.top    = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.bottom = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.left   = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.right  = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.top:SetSnapToPixelGrid(false);    frame.borderOverlay.top:SetTexelSnappingBias(0)
  frame.borderOverlay.bottom:SetSnapToPixelGrid(false); frame.borderOverlay.bottom:SetTexelSnappingBias(0)
  frame.borderOverlay.left:SetSnapToPixelGrid(false);   frame.borderOverlay.left:SetTexelSnappingBias(0)
  frame.borderOverlay.right:SetSnapToPixelGrid(false);  frame.borderOverlay.right:SetTexelSnappingBias(0)

  -- Icon frame (to the left of the bar by default; can be repositioned when iconMovable=true)
  frame.iconFrame = CreateFrame("Frame", nil, frame)
  frame.iconFrame:SetSize(20, 20)
  frame.iconFrame:SetPoint("RIGHT", frame, "LEFT", -2, 0)
  frame.iconFrame:SetFrameLevel(frame:GetFrameLevel() + 5)
  frame.iconFrame:SetMovable(true)
  frame.iconFrame:SetClampedToScreen(true)
  frame.iconTex = frame.iconFrame:CreateTexture(nil, "ARTWORK")
  frame.iconTex:SetAllPoints()
  frame.iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  frame.iconFrame:RegisterForDrag("LeftButton")
  frame.iconFrame:SetScript("OnDragStart", function(self)
    if ns._arcUIOptionsOpen then self:StartMoving() end
  end)
  frame.iconFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local cfg = GetCastbarDB()
    local mainFrame = castFrameObj
    if cfg and mainFrame then
      local mainLeft   = mainFrame:GetLeft()       or 0
      local mainBottom = mainFrame:GetBottom()     or 0
      local iconLeft   = self:GetLeft()            or 0
      local iconBottom = self:GetBottom()          or 0
      local offsetX = math.floor(iconLeft - mainLeft + 0.5)
      local offsetY = math.floor(iconBottom - mainBottom + 0.5)
      cfg.iconPosition = { point="BOTTOMLEFT", relPoint="BOTTOMLEFT", x=offsetX, y=offsetY }
      self:ClearAllPoints()
      self:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", offsetX, offsetY)
    end
  end)

  -- Segment bars for empowered casts — one StatusBar per stage, fills with its own color
  -- Pool of 8 supports up to empowerMaxStages = 8; unused bars stay hidden.
  frame.stageSegBars = {}
  for i = 1, 8 do
    local sb = CreateFrame("StatusBar", nil, frame)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    sb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    sb:SetStatusBarColor(1, 1, 1, 1)
    sb:SetFrameLevel(frame:GetFrameLevel() + 3)
    sb:EnableMouse(false)
    sb:Hide()
    frame.stageSegBars[i] = sb
  end

  -- Tick mark overlay for channeled spells (16-divider pool covers any realistic tick count).
  -- High frame level + OVERLAY sublevel 7 so ticks render ABOVE the fill bar — same method as
  -- the aura bars. (The old +5 overlay sat below the configured fill level → ticks were invisible.)
  frame.tickOverlay = CreateFrame("Frame", nil, frame)
  frame.tickOverlay:SetAllPoints()
  frame.tickOverlay:SetFrameLevel(frame:GetFrameLevel() + 22)
  frame.tickPool = {}
  for i = 1, 16 do
    local t = frame.tickOverlay:CreateTexture(nil, "OVERLAY")
    t:SetDrawLayer("OVERLAY", 7)
    t:SetSnapToPixelGrid(false)
    t:SetTexelSnappingBias(0)
    t:Hide()
    frame.tickPool[i] = t
  end

  -- Latency "safe zone" overlay at the finishing edge of the bar (above fill, below ticks).
  frame.latencyZone = frame.tickOverlay:CreateTexture(nil, "ARTWORK")
  frame.latencyZone:SetSnapToPixelGrid(false)
  frame.latencyZone:SetTexelSnappingBias(0)
  frame.latencyZone:Hide()

  -- Direct-drag repositioning, same model as the aura/resource bars: the bar frame itself is
  -- the handle. Mouse is only enabled while the options panel is open (see ShowPreview /
  -- HidePreview), so the bar never captures clicks during normal play.
  local function SaveCastbarPosition()
    local cfg = GetCastbarPositionCfg()
    if cfg then
      local point, _, relPoint, x, y = frame:GetPoint()
      if point then
        cfg.barPosition = { point = point, relPoint = relPoint, x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
      end
    end
  end

  frame:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    local cfg = GetCastbarDB()
    if cfg and cfg.barMovable ~= false and not cfg.anchorToGroup then
      self._moving = true
      self:StartMoving()
    end
  end)
  frame:SetScript("OnMouseUp", function(self, button)
    if self._moving then
      self:StopMovingOrSizing()
      self._moving = false
      SaveCastbarPosition()
    elseif button == "RightButton" then
      if ns.Castbar.OpenOptions then ns.Castbar.OpenOptions() end
    end
  end)

  frame:Hide()

  -- Separate text frame: name + timer (anchored to mainFrame, not movable independently)
  local textFrame = CreateFrame("Frame", "ArcUICastbarText", UIParent)
  textFrame:SetSize(250, 20)
  textFrame:SetPoint("CENTER", frame, "CENTER", 0, 0)
  textFrame:SetFrameStrata("HIGH")
  textFrame:SetFrameLevel(200)

  textFrame.nameText = textFrame:CreateFontString(nil, "OVERLAY")
  textFrame.nameText:SetPoint("LEFT", textFrame, "LEFT", 4, 0)
  textFrame.nameText:SetPoint("RIGHT", textFrame, "RIGHT", -38, 0)
  textFrame.nameText:SetJustifyH("LEFT")
  textFrame.nameText:SetJustifyV("MIDDLE")

  textFrame.timerText = textFrame:CreateFontString(nil, "OVERLAY")
  textFrame.timerText:SetPoint("RIGHT", textFrame, "RIGHT", -4, 0)
  textFrame.timerText:SetJustifyH("RIGHT")
  textFrame.timerText:SetJustifyV("MIDDLE")

  textFrame:Hide()

  return frame, textFrame
end

local function GetOrCreateFrames()
  if not castFrameObj then
    castFrameObj, castTextFrame = CreateCastbarFrames()
  end
  return castFrameObj, castTextFrame
end

-- ===================================================================
-- SPELL OVERRIDE & DISPLAY HELPERS
-- ===================================================================
local function GetSpellOverride(spellID, cfg)
  if not cfg or not cfg.spellOverrides or not spellID or spellID == 0 then return nil end
  for _, ov in ipairs(cfg.spellOverrides) do
    if ov.spellID == spellID then return ov end
  end
  return nil
end

-- Returns: fillColor {r,g,b,a}, overrideTexPath (or nil), borderColorOverride (or nil),
--          colorLocked (true when a fixed color should win over threshold/curve coloring)
-- Priority: base type → spell override → uninterruptible
local function ResolveActiveDisplay(cfg, spellID, isChannel, isEmpowered, notInterruptible)
  -- cfg is the per-type effective config, so cfg.barColor is already this cast type's color.
  local color = cfg.barColor or {r=0.2, g=0.8, b=1, a=1}

  local overrideTex = nil
  local borderOvr   = nil
  local locked      = false
  local override = GetSpellOverride(spellID, cfg)
  if override then
    if override.barColorEnabled and override.barColor then
      color = override.barColor
      locked = true
    end
    if override.textureOverrideEnabled and override.texture and override.texture ~= "" then
      overrideTex = (LSM and LSM:Fetch("statusbar", override.texture)) or nil
    end
  end

  if notInterruptible and cfg.uninterruptibleEnabled then
    if not (override and override.barColorEnabled) then
      color = cfg.uninterruptibleColor or color
    end
    locked = true
    if cfg.showBorder and cfg.uninterruptibleBorderColor then
      borderOvr = cfg.uninterruptibleBorderColor
    end
  end

  return color, overrideTex, borderOvr, locked
end

-- Threshold color based on what's REMAINING in the cast. As the cast nears completion it
-- passes each "X remaining" threshold; the LOWEST passed threshold wins (so a later/smaller
-- threshold overrides an earlier one). asSec → threshold value is seconds remaining, else
-- percent remaining. Returns nil to keep the base color.
local function ResolveProgressColor(cfg, remainingPct, remainingSec)
  if not (cfg and cfg.conditionalColorEnabled and cfg.colorThresholds) then return nil end
  local val = cfg.conditionalColorAsSec and (remainingSec or 0) or (remainingPct or 0)
  local best, bestAt = nil, math.huge
  for _, th in ipairs(cfg.colorThresholds) do
    if th.enabled and th.color and th.percent and val <= th.percent and th.percent < bestAt then
      best, bestAt = th.color, th.percent
    end
  end
  return best
end
ns.Castbar.ResolveProgressColor = ResolveProgressColor

-- ===================================================================
-- TICK MARKS
-- ===================================================================
-- Core placement: draw dividers at the given list of 0-1 fractions along the bar.
-- Optional `colors` overrides the per-divider color (colors[i] for divider i).
local function PlaceTickFractions(fractions, colors)
  if not castFrameObj or not castFrameObj.tickPool then return end
  local pool = castFrameObj.tickPool
  local barW = castFrameObj:GetWidth()
  local barH = castFrameObj:GetHeight()
  if not barW or barW <= 0 or not fractions or #fractions == 0 then
    for _, t in ipairs(pool) do t:Hide() end
    activeTicks = 0
    return
  end
  activeTicks = #fractions
  local cfg   = GetEffectiveCfg()
  local color = (cfg and cfg.tickMarksColor) or {r=1, g=1, b=1, a=0.6}
  local thick = (cfg and cfg.tickMarksThickness) or 2
  local hFrac = (cfg and cfg.tickMarksHeightFraction) or 1.0
  local hAnch = (cfg and cfg.tickHeightAnchor) or "center"
  local tAnch = (cfg and cfg.tickThicknessAnchor) or "center"

  -- Pixel-exact thickness, same formula the aura bars use, so thin ticks aren't snapped away.
  local scale  = castFrameObj:GetEffectiveScale()
  local _, ph  = GetPhysicalScreenSize()
  local onePx  = (ph and ph > 0 and scale and scale > 0) and (768 / ph) / scale or 1
  local pxThick  = math.max(onePx, onePx * thick)
  local tickSpan = math.max(onePx, barH * hFrac)

  -- Dividers anchored to the high tickOverlay so they render above the fill bar.
  local overlay = castFrameObj.tickOverlay
  for i = 1, #pool do
    local t = pool[i]
    local f = fractions[i]
    if f and f > 0 and f < 1 then
      -- Thickness anchor: how the tick straddles its exact position.
      local rawPos   = f * barW
      local posAlong = rawPos - pxThick / 2            -- center (default)
      if tAnch == "start" then posAlong = rawPos
      elseif tAnch == "end" then posAlong = rawPos - pxThick end

      t:ClearAllPoints()
      t:SetSize(pxThick, tickSpan)
      -- Height anchor: vertical placement of the tick within the bar.
      if hAnch == "top" then
        t:SetPoint("TOPLEFT", overlay, "TOPLEFT", posAlong, 0)
      elseif hAnch == "bottom" then
        t:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", posAlong, 0)
      else
        t:SetPoint("LEFT", overlay, "LEFT", posAlong, 0)
      end
      local col = (colors and colors[i]) or color
      t:SetColorTexture(col.r, col.g, col.b, col.a or 0.6)
      t:Show()
    else
      t:Hide()
    end
  end
end
ns.Castbar.PlaceTickFractions = PlaceTickFractions

-- Even spacing: N ticks → N-1 dividers at i/N (each segment = 100/N %).
local function PlaceTickMarks(count)
  count = count or 0
  if count < 2 then PlaceTickFractions(nil); return end
  local fr = {}
  for i = 1, count - 1 do fr[i] = i / count end
  PlaceTickFractions(fr)
end
ns.Castbar.PlaceTickMarks = PlaceTickMarks

-- Custom placement: parse a "20, 40, 55" percentage list into 0-1 fractions.
local function ParseCustomTicks(str)
  if type(str) ~= "string" or str == "" then return nil end
  local fr = {}
  for tok in string.gmatch(str, "[^,%s]+") do
    local n = tonumber(tok)
    if n and n > 0 and n < 100 then fr[#fr + 1] = n / 100 end
  end
  return (#fr > 0) and fr or nil
end
ns.Castbar.ParseCustomTicks = ParseCustomTicks

-- Resolve the GLOBAL tick layout into fractions: "percent" → a divider every N%,
-- "custom" → the explicit percentage list.
local function GlobalTickFractions(cfg)
  if not cfg then return nil end
  if cfg.tickMode == "custom" then
    return ParseCustomTicks(cfg.tickCustom)
  end
  local p = cfg.tickPercent or 10
  if p <= 0 then return nil end
  local fr, i = {}, 1
  while i * p < 100 do
    fr[#fr + 1] = (i * p) / 100
    i = i + 1
  end
  return (#fr > 0) and fr or nil
end
ns.Castbar.GlobalTickFractions = GlobalTickFractions

local function HideTickMarks()
  activeTicks = 0
  if not castFrameObj or not castFrameObj.tickPool then return end
  for _, t in ipairs(castFrameObj.tickPool) do t:Hide() end
end
ns.Castbar.HideTickMarks = HideTickMarks

-- Resolve which tick layout to draw for the active channel and place it. Single source of
-- truth shared by ShowCast (cast start) and ApplyAppearance (mid-cast option change):
-- per-spell custom %s → per-spell even count → global (Per % / Custom). Hardcasts have no ticks.
local function ApplyChannelTicks(spellID)
  local cfg = GetEffectiveCfg()
  -- Empowered casts: draw a divider at each stage boundary (on by default) so the stages are
  -- visible even without segment colors. Uses the live stage proportions.
  if castIsEmpowered then
    if cfg and cfg.empowerStageDividers ~= false and castEmpowerStageProps and #castEmpowerStageProps > 0 then
      -- Optional per-divider colors (divider i uses stage i's segment color).
      local divColors = (cfg.empowerDividerPerColor and cfg.empowerSegmentColors) or nil
      PlaceTickFractions(castEmpowerStageProps, divColors)
    else
      HideTickMarks()
    end
    return
  end
  -- "channels" = channels only; "all" also shows them on hardcasts.
  local showOn   = (cfg and cfg.tickShowOn) or "channels"
  local eligible = castIsChannel or (showOn == "all")
  if not (cfg and cfg.tickMarksEnabled and eligible) then
    HideTickMarks()
    return
  end
  local ov = GetSpellOverride(spellID, cfg)
  if ov and ov.tickMode == "custom" and ov.customTicks and ov.customTicks ~= "" then
    local fr = ParseCustomTicks(ov.customTicks)
    if fr then PlaceTickFractions(fr) else HideTickMarks() end
  elseif ov and ov.tickCount and ov.tickCount > 0 then
    PlaceTickMarks(ov.tickCount)
  else
    PlaceTickFractions(GlobalTickFractions(cfg))
  end
end

-- ===================================================================
-- BORDER DRAWING
-- ===================================================================
local function ApplyBorder(mainFrame, cfg, borderColorOverride)
  local bo = mainFrame.borderOverlay
  if cfg.showBorder then
    local bt = PixelUtil.GetNearestPixelSize(cfg.drawnBorderThickness or 2, mainFrame:GetEffectiveScale(), 1)
    local bc = borderColorOverride or cfg.borderColor or {r=0, g=0, b=0, a=1}

    for _, t in pairs({bo.top, bo.bottom, bo.left, bo.right}) do
      t:SetSnapToPixelGrid(true)
      t:SetTexelSnappingBias(1)
    end

    bo.top:ClearAllPoints()
    bo.top:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, 0)
    bo.top:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, 0)
    bo.top:SetHeight(bt)
    bo.top:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
    bo.top:Show()

    bo.bottom:ClearAllPoints()
    bo.bottom:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, 0)
    bo.bottom:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
    bo.bottom:SetHeight(bt)
    bo.bottom:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
    bo.bottom:Show()

    bo.left:ClearAllPoints()
    bo.left:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -bt)
    bo.left:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, bt)
    bo.left:SetWidth(bt)
    bo.left:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
    bo.left:Show()

    bo.right:ClearAllPoints()
    bo.right:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -bt)
    bo.right:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, bt)
    bo.right:SetWidth(bt)
    bo.right:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
    bo.right:Show()

    bo:Show()
  else
    bo.top:Hide(); bo.bottom:Hide(); bo.left:Hide(); bo.right:Hide()
    bo:Hide()
  end
end

-- ===================================================================
-- BLIZZARD CASTBAR VISIBILITY
-- ===================================================================
local blizzCastBarHooked = false
local blizzCastBarHideActive = false  -- live gate: the Show->Hide hook only suppresses while this is true
local function ApplyBlizzCastBarVisibility()
  local cfg = GetCastbarDB()
  local frame = PlayerCastingBarFrame
  if not frame then return end
  local shouldHide = (cfg and cfg.hideCastBar) and true or false
  local wasHiding  = blizzCastBarHideActive
  blizzCastBarHideActive = shouldHide
  if shouldHide then
    -- Install the suppress hook once, but gate it on the live flag so hiding is REVERSIBLE
    -- (toggling hideCastBar -- or shared mode -- back off restores the bar without a /reload).
    if not blizzCastBarHooked then
      blizzCastBarHooked = true
      hooksecurefunc(frame, "Show", function(self)
        if blizzCastBarHideActive then self:Hide() end
      end)
    end
    frame:Hide()
  elseif wasHiding then
    -- Only on the hide->show transition: restore the Blizzard castbar (the gated hook is now inert).
    frame:Show()
  end
end

-- ===================================================================
-- APPLY APPEARANCE
-- ===================================================================
function ns.Castbar.ApplyAppearance()
  ApplyBlizzCastBarVisibility()
  local cfg = GetEffectiveCfg()  -- per-type appearance for the current display/cast type
  if not cfg then return end

  local mainFrame, textFrame = GetOrCreateFrames()

  if not cfg.enabled then
    mainFrame:Hide()
    textFrame:Hide()
    return
  end

  -- Size
  local w = PixelSize(cfg.width or 250)
  local h = PixelSize(cfg.height or 20)
  mainFrame:SetSize(w, h)
  textFrame:SetSize(w, h)

  -- Position: anchor to a CDM group if configured, otherwise use the saved free position
  local _anchorDone = false
  local BGA = ns.BarGroupAlign
  if cfg.anchorToGroup and cfg.anchorGroupName and cfg.anchorGroupName ~= "" and BGA then
    local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[cfg.anchorGroupName]
    if group and group.container then
      local barH = h  -- already pixel-snapped above
      local resolvedW = BGA.ApplySizeAndAnchor(
        mainFrame,
        cfg.anchorGroupName,
        cfg.anchorPoint or "BOTTOM",
        barH,
        cfg.anchorOffsetX or 0,
        cfg.anchorOffsetY or -2,
        cfg.matchGroupWidth or false,
        cfg.matchSlotsOnly or false,
        false,                    -- isFragVertical (castbar is always horizontal)
        cfg.matchWidthAdjust or 0,
        false                     -- needsSwap
      )
      if resolvedW then
        textFrame:SetSize(resolvedW, barH)
      end
      _anchorDone = true
    end
  end
  if not _anchorDone then
    local pcfg = GetCastbarPositionCfg()
    local pos = (pcfg and pcfg.barPosition) or {point="CENTER", relPoint="CENTER", x=0, y=-100}
    mainFrame:ClearAllPoints()
    mainFrame:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER", pos.x or 0, pos.y or -100)
  end
  textFrame:ClearAllPoints()
  textFrame:SetPoint("CENTER", mainFrame, "CENTER", 0, 0)

  -- Strata and level
  local strata = cfg.barFrameStrata or "MEDIUM"
  local level  = cfg.barFrameLevel or 10
  mainFrame:SetFrameStrata(strata)
  mainFrame:SetFrameLevel(level)
  mainFrame.fillBar:SetFrameLevel(level + 2)
  if mainFrame.stageSegBars then
    for _, sb in ipairs(mainFrame.stageSegBars) do sb:SetFrameLevel(level + 3) end
  end
  mainFrame.borderOverlay:SetFrameLevel(level + 10)
  mainFrame.iconFrame:SetFrameLevel(level + 5)
  mainFrame.tickOverlay:SetFrameLevel(level + 22)
  textFrame:SetFrameStrata(strata)
  textFrame:SetFrameLevel(level + 100)

  -- Opacity
  mainFrame:SetAlpha(cfg.opacity or 1.0)

  -- Background
  if cfg.showBackground then
    local bg = cfg.backgroundColor or {r=0.1, g=0.1, b=0.1, a=0.9}
    mainFrame.bg:SetColorTexture(bg.r, bg.g, bg.b, bg.a or 0.9)
    mainFrame.bg:Show()
  else
    mainFrame.bg:Hide()
  end

  -- Border (use uninterruptible override colour when a non-interruptible cast is active)
  local _activeBorderOvr = (castActive and castNotInterruptible
    and cfg.uninterruptibleEnabled and cfg.uninterruptibleBorderColor) or nil
  ApplyBorder(mainFrame, cfg, _activeBorderOvr)

  -- Texture for fill bar
  local texPath = "Interface\\TargetingFrame\\UI-StatusBar"
  if LSM and cfg.texture then
    texPath = LSM:Fetch("statusbar", cfg.texture) or texPath
  end
  mainFrame.fillBar:SetStatusBarTexture(texPath)
  if mainFrame.stageSegBars then
    for _, sb in ipairs(mainFrame.stageSegBars) do sb:SetStatusBarTexture(texPath) end
  end

  -- Re-apply active cast overrides so option changes don't clobber live styling
  if castActive then
    local color, overrideTex = ResolveActiveDisplay(cfg, castActiveSpellID, castIsChannel, castIsEmpowered, castNotInterruptible)
    mainFrame.fillBar:SetStatusBarColor(color.r, color.g, color.b, color.a or 1)
    if overrideTex then mainFrame.fillBar:SetStatusBarTexture(overrideTex) end
    ApplyChannelTicks(castActiveSpellID)
  end

  -- Icon
  local iconSize = PixelSize(cfg.iconSize or 20)
  mainFrame.iconFrame:SetSize(iconSize, iconSize)
  mainFrame.iconFrame:ClearAllPoints()
  if cfg.iconMovable and cfg.iconPosition then
    local pos = cfg.iconPosition
    mainFrame.iconFrame:SetPoint(pos.point, mainFrame, pos.relPoint, pos.x, pos.y)
  else
    mainFrame.iconFrame:SetPoint("RIGHT", mainFrame, "LEFT", -2, 0)
  end
  if cfg.showIcon then
    mainFrame.iconFrame:Show()
  else
    mainFrame.iconFrame:Hide()
  end

  -- Font
  local fontPath = "Fonts\\FRIZQT__.TTF"
  if LSM and cfg.font then
    fontPath = LSM:Fetch("font", cfg.font) or fontPath
  end
  local fontSize  = cfg.fontSize or 14
  local outline   = cfg.textOutline
  if outline == "NONE" or outline == "None" or outline == "" then outline = nil end
  local tc = cfg.textColor or {r=1, g=1, b=1, a=1}

  textFrame.nameText:SetFont(fontPath, fontSize, outline)
  textFrame.nameText:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
  textFrame.timerText:SetFont(fontPath, fontSize, outline)
  textFrame.timerText:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)

  -- Mouse is off during live casts so the bar never eats clicks; ShowPreview turns it on for
  -- positioning while the options panel is open.
  if not castActive then mainFrame:EnableMouse(false) end
  if ns._arcUIOptionsOpen and not castActive and ns.Castbar.ShowPreview then
    ns.Castbar.ShowPreview()
  end
end

-- ===================================================================
-- EMPOWERED SEGMENT BARS
-- ===================================================================
local function HideEmpowerVisuals()
  if not castFrameObj then return end
  if castFrameObj.stageSegBars then
    for i = 1, 8 do
      if castFrameObj.stageSegBars[i] then castFrameObj.stageSegBars[i]:Hide() end
    end
  end
  -- Ensure the main fill bar is visible for non-segment mode
  if castFrameObj.fillBar then castFrameObj.fillBar:Show() end
end

-- Real empowered stage layout, matching Blizzard's CastingBarFrame math:
--   • actual stage count = numStages + 1 (the +1 is the hold-at-max stage)
--   • dividers sit at the CUMULATIVE real stage durations (not evenly spaced)
-- Returns stageCount, props (divider fractions, one per numStages), totalDurMs.
-- Returns nil if the stage durations aren't available yet (caller should retry/refine).
local function ComputeEmpowerStages()
  local numStages = select(10, UnitChannelInfo("player"))
  if not numStages or numStages < 1 then return nil end
  local cum, sum = {}, 0
  for i = 1, numStages do
    local d = (GetUnitEmpowerStageDuration and GetUnitEmpowerStageDuration("player", i - 1)) or 0
    sum = sum + d
    cum[i] = sum
  end
  if sum <= 0 then return nil end  -- durations not ready yet
  local ha = (GetUnitEmpowerHoldAtMaxTime and GetUnitEmpowerHoldAtMaxTime("player")) or 0
  local totalDur = sum + ha
  local props = {}
  for i = 1, numStages do props[i] = cum[i] / totalDur end
  return numStages + 1, props, totalDur
end
ns.Castbar.ComputeEmpowerStages = ComputeEmpowerStages

local function PlaceSegmentBars()
  if not castFrameObj then return end
  local cfg    = GetCastbarDB()
  local barW   = castFrameObj:GetWidth()
  local barH   = castFrameObj:GetHeight()
  local segs   = castFrameObj.stageSegBars
  -- In preview mode (options panel open, no live cast) show a 4-stage demo layout
  local nStage = castEmpowerNumStages
  local props  = castEmpowerStageProps
  if castPreviewActive and nStage == 0 then
    nStage = (cfg and cfg.empowerMaxStages) or 4
    props  = {}
    for i = 1, nStage - 1 do props[i] = i / nStage end
  end
  local useSegs = cfg and cfg.empowerSegmentColorsEnabled and nStage > 0

  -- Switch between single fill bar and per-segment bars
  if useSegs then
    castFrameObj.fillBar:Hide()
  else
    castFrameObj.fillBar:Show()
  end

  for i = 1, 8 do
    local sb = segs and segs[i]
    if sb then
      if useSegs and i <= nStage then
        local segStart = i > 1 and (props[i-1] or 0) or 0
        local segEnd   = props[i] or 1
        local segW     = math.max(1, PixelSize((segEnd - segStart) * barW))
        local segX     = PixelSize(segStart * barW)
        sb:SetSize(segW, barH)
        sb:ClearAllPoints()
        sb:SetPoint("TOPLEFT", castFrameObj, "TOPLEFT", segX, 0)
        local cols = cfg and cfg.empowerSegmentColors
        local c    = cols and cols[i] or {r=1, g=1, b=1, a=1}
        sb:SetStatusBarColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
        sb:SetValue(0)
        sb:Show()
      else
        sb:Hide()
      end
    end
  end
end
ns.Castbar.RefreshSegmentBars = PlaceSegmentBars

-- Latency "safe zone": a strip at the finishing edge sized to your latency — the window where
-- your cast is effectively already done server-side, so you can queue the next one.
-- latMs comes from world latency (GetNetStats) or a manual override; durSecOverride lets the
-- preview size it against a demo cast.
local function UpdateLatencyZone(cfg, durSecOverride)
  if not castFrameObj or not castFrameObj.latencyZone then return end
  local lz = castFrameObj.latencyZone
  if not (cfg and cfg.latencyEnabled) then lz:Hide(); return end
  local latMs
  if cfg.latencyManual then
    latMs = cfg.latencyManualMs or 100
  else
    local _, _, _, world = GetNetStats()
    latMs = world or 0
  end
  local durMs = (durSecOverride or (castEndTime - castStartTime)) * 1000
  if latMs <= 0 or durMs <= 0 then lz:Hide(); return end
  local frac  = math.min(latMs / durMs, 1)
  local zoneW = math.max(1, PixelSize(frac * castFrameObj:GetWidth()))
  local lc    = cfg.latencyColor or {r=1, g=0, b=0, a=0.4}
  lz:ClearAllPoints()
  -- Finishing edge: hardcasts/empower fill toward the RIGHT; channels drain toward the LEFT.
  local fillsRight = not (castIsChannel and not castIsEmpowered)
  if cfg.reverseFill then fillsRight = not fillsRight end
  if fillsRight then
    lz:SetPoint("TOPRIGHT",    castFrameObj, "TOPRIGHT",    0, 0)
    lz:SetPoint("BOTTOMRIGHT", castFrameObj, "BOTTOMRIGHT", 0, 0)
  else
    lz:SetPoint("TOPLEFT",    castFrameObj, "TOPLEFT",    0, 0)
    lz:SetPoint("BOTTOMLEFT", castFrameObj, "BOTTOMLEFT", 0, 0)
  end
  lz:SetWidth(zoneW)
  lz:SetColorTexture(lc.r, lc.g, lc.b, lc.a or 0.4)
  lz:Show()
end
ns.Castbar.UpdateLatencyZone = UpdateLatencyZone

-- Forward declaration: StopCast is defined after CastOnUpdate but called from within it.
local StopCast

-- ===================================================================
-- ONUPDATE (only runs during an active cast)
-- ===================================================================
local function CastOnUpdate(self, elapsed)
  local cfg = GetCastbarDB()
    if not cfg then return end
    -- Channel STOP and empower STOP/release both set castChannelEnded; tear the bar down.
    if castChannelEnded and (castIsChannel or castIsEmpowered) then
      if (GetTime() - channelStopTime) > 0.01 then
        StopCast()
        return
      end
    end
    -- Safety net: if timing shows the channel/empower is well past its end and the STOP event
    -- was somehow missed, stop the bar so it never lingers as a ghost.
    if (castIsChannel or castIsEmpowered) and castTimingRefined and not castChannelEnded then
      if (GetTime() - castEndTime) > 1.5 then
        CastDebug("Safety net: cast past end time, stopping")
        StopCast()
        return
      end
    end
  -- Regular channels: refine timing on each tick until we get valid server timestamps.
  if castIsChannel and not castIsEmpowered and not castTimingRefined then
    local name, _, _, st, et = UnitChannelInfo("player")
    if name and st and st > 0 and et and et > st then
      castStartTime     = st / 1000
      castEndTime       = et / 1000
      castTimingRefined = true
    end
  end

  -- Empowered casts: once the real stage durations are available, lock in accurate
  -- stage count, boundaries and total duration (overrides any temporary even split).
  if castIsEmpowered and not castTimingRefined then
    local n2, _, _, st2 = UnitChannelInfo("player")
    if n2 and st2 and st2 > 0 then
      local realStages, props, totalDur = ComputeEmpowerStages()
      if realStages then
        castStartTime         = st2 / 1000
        castEndTime           = (st2 + totalDur) / 1000
        castEmpowerNumStages  = realStages
        castEmpowerStageProps = props
        PlaceSegmentBars()
        ApplyChannelTicks(castActiveSpellID)  -- redraw stage dividers at the real positions
        castTimingRefined = true
      end
    end
  end

  local now = GetTime()
  local total = castEndTime - castStartTime
  if total <= 0 then return end

  local progress
  if castIsChannel and not castIsEmpowered then
    progress = 1.0 - (now - castStartTime) / total
  else
    progress = (now - castStartTime) / total
  end
  progress = math.max(0, math.min(1, progress))
  if cfg.reverseFill then progress = 1.0 - progress end

  castFrameObj.fillBar:SetValue(progress)

  -- Conditional (threshold) coloring for hardcast/channel fill — recolor as the cast passes
  -- each % threshold. Suppressed for empower (segments) and when a fixed color is locked in.
  if not castIsEmpowered and not castColorLocked then
    local ecfg = GetEffectiveCfg()
    if ecfg and ecfg.conditionalColorEnabled then
      local remainingSec = math.max(0, castEndTime - now)
      local remainingPct = (total > 0) and (remainingSec / total * 100) or 0
      local thColor = ResolveProgressColor(ecfg, remainingPct, remainingSec)
      if thColor then
        castFrameObj.fillBar:SetStatusBarColor(thColor.r, thColor.g, thColor.b, thColor.a or 1)
      end
    end
  end

  -- Per-stage segment fills (empowered only)
  local segs = castFrameObj and castFrameObj.stageSegBars
  if castIsEmpowered and segs and cfg.empowerSegmentColorsEnabled then
    for i = 1, castEmpowerNumStages do
      local sb = segs[i]
      if sb and sb:IsShown() then
        local props    = castEmpowerStageProps or {}
        local segStart = i > 1 and (props[i-1] or 0) or 0
        local segEnd   = props[i] or 1
        local segDur  = segEnd - segStart
        local segFill
        if segDur > 0 then
          segFill = math.max(0, math.min(1, (progress - segStart) / segDur))
        elseif progress >= segEnd then
          segFill = 1
        else
          segFill = 0
        end
        sb:SetValue(segFill)
      end
    end
  end

  -- Live countdown timer
  if cfg.showTimer then
    local remaining = castEndTime - now
    if remaining < 0 then remaining = 0 end
    castTextFrame.timerText:SetText(FormatTimer(cfg, remaining, castEndTime - castStartTime))
  end
end

-- ===================================================================
-- SHOW / STOP CAST
-- ===================================================================
local function ShowCast(spellID, startTimeMS, endTimeMS, isChannel, notInterruptible, isEmpowered, numStages, stageProps)
    local cfg = GetCastbarDB()
  if not cfg or not cfg.enabled then
    CastDebug("ShowCast blocked: castbar disabled (spellID=" .. tostring(spellID) .. ")")
    return
  end
  if cfg.hideOutOfCombat and not InCombatLockdown() then
    CastDebug("ShowCast blocked: hideOutOfCombat is on and not in combat (spellID=" .. tostring(spellID) .. ")")
    return
  end
  if isChannel and not isEmpowered and cfg.hideChannels then
    CastDebug("ShowCast blocked: hideChannels is on (spellID=" .. tostring(spellID) .. ")")
    return
  end
  CastDebug("ShowCast: spellID=" .. tostring(spellID)
    .. " isChannel=" .. tostring(isChannel)
    .. " isEmpowered=" .. tostring(isEmpowered)
    .. " start=" .. tostring(startTimeMS)
    .. " end=" .. tostring(endTimeMS))

  local mainFrame, textFrame = GetOrCreateFrames()

  castActive            = true
  castPreviewActive     = false
  castTimingRefined     = false
  castChannelEnded      = false
  castIsChannel         = isChannel or false
  castIsEmpowered       = isEmpowered or false
  castActiveSpellID     = spellID or 0
  castNotInterruptible  = notInterruptible or false
  castEmpowerNumStages  = numStages or 0
  castEmpowerStageProps = stageProps or {}
  castStartTime         = (startTimeMS or 0) / 1000
  castEndTime           = (endTimeMS   or 0) / 1000

  -- Now that the cast type is known, resolve per-type appearance for the visuals below.
  cfg = GetEffectiveCfg() or cfg

  -- A new cast cancels any in-progress interrupt/cancel fade and restores full opacity.
  castFading = false
  mainFrame:SetAlpha(cfg.opacity or 1.0)
  textFrame:SetAlpha(1)

  -- Spell info (WoW 12.0: C_Spell.GetSpellInfo returns a table)
  local spellName, spellIconID
  if spellID and spellID > 0 then
    local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    if info then
      spellName  = info.name
      spellIconID = info.iconID or info.originalIconID
    end
  end

  -- Icon
  if cfg.showIcon and spellIconID then
    mainFrame.iconTex:SetTexture(spellIconID)
    mainFrame.iconFrame:Show()
  else
    mainFrame.iconFrame:Hide()
  end

  -- Spell name
  if cfg.showText then
    textFrame.nameText:SetText(TruncateSpellName(spellName or "", cfg))
  else
    textFrame.nameText:SetText("")
  end

  -- Bar color: base type → spell override → uninterruptible
  local color, overrideTex, borderOvr, locked = ResolveActiveDisplay(cfg, spellID, isChannel, isEmpowered, notInterruptible)
  castColorLocked = locked or false  -- threshold coloring is suppressed when a fixed color wins
  mainFrame.fillBar:SetStatusBarColor(color.r, color.g, color.b, color.a or 1)
  if overrideTex then mainFrame.fillBar:SetStatusBarTexture(overrideTex) end
  ApplyBorder(mainFrame, cfg, borderOvr)

  -- Initial fill value respects reverseFill: channels normally start full, casts start empty.
  local startsAtFull = (isChannel and not castIsEmpowered)
  if cfg.reverseFill then startsAtFull = not startsAtFull end
  mainFrame.fillBar:SetValue(startsAtFull and 1 or 0)

  -- Initial timer text
  if cfg.showTimer then
    local duration = castEndTime - castStartTime
    if duration < 0 then duration = 0 end
    textFrame.timerText:SetText(FormatTimer(cfg, duration, duration))
  else
    textFrame.timerText:SetText("")
  end

  mainFrame:EnableMouse(false)  -- never interactive during a live cast
  mainFrame.iconFrame:EnableMouse(false)
  mainFrame:Show()
  textFrame:Show()
  if castIsEmpowered then
    PlaceSegmentBars()
  else
    HideEmpowerVisuals()
  end
  -- Tick marks (channels only; hardcasts have none).
  ApplyChannelTicks(spellID)
  UpdateLatencyZone(cfg)
  mainFrame:SetScript("OnUpdate", CastOnUpdate)
end

StopCast = function()
  castActive           = false
  castChannelEnded     = false
  castActiveSpellID    = 0
  castNotInterruptible = false
  castCurrentGUID      = nil
  HideTickMarks()
  HideEmpowerVisuals()
  castIsEmpowered      = false
  castEmpowerNumStages  = 0
  castEmpowerStageProps = {}
  if castFrameObj then
    if castFrameObj.latencyZone then castFrameObj.latencyZone:Hide() end
    castFrameObj:SetScript("OnUpdate", nil)
    castFrameObj:Hide()
  end
  if castTextFrame then
    castTextFrame:Hide()
  end
  -- Restore preview if options panel is still open
  if ns._arcUIOptionsOpen and ns.Castbar.ShowPreview then
    ns.Castbar.ShowPreview()
  end
end

-- Interrupt/cancel feedback: freeze the bar, recolor it, label it, then fade out and hide.
local function FadeOnUpdate(self)
  local cfg = GetCastbarDB()
  local dur = (cfg and cfg.interruptFadeDuration) or 1.0
  local baseAlpha = (cfg and cfg.opacity) or 1.0
  local t = GetTime() - fadeStart
  if t >= dur or dur <= 0 then
    self:SetScript("OnUpdate", nil)
    castFading = false
    self:SetAlpha(baseAlpha)
    if castTextFrame then castTextFrame:SetAlpha(1) end
    StopCast()
    return
  end
  -- Fade the bar AND the separate text frame together.
  local a = 1 - t / dur
  self:SetAlpha(baseAlpha * a)
  if castTextFrame then castTextFrame:SetAlpha(a) end
end

local function ShowFailFeedback(interrupted)
  local cfg = GetCastbarDB()
  if not castFrameObj or not (cfg and cfg.interruptFeedbackEnabled) then StopCast(); return end
  castActive       = false
  castChannelEnded = false
  castFading       = true
  castFrameObj:SetScript("OnUpdate", nil)
  HideTickMarks()
  HideEmpowerVisuals()
  if castFrameObj.latencyZone then castFrameObj.latencyZone:Hide() end
  local ic = cfg.interruptColor or {r=1, g=0.15, b=0.15, a=1}
  castFrameObj.fillBar:SetStatusBarColor(ic.r, ic.g, ic.b, ic.a or 1)
  castFrameObj.fillBar:SetValue(1)
  if castTextFrame then
    castTextFrame.nameText:SetText(interrupted and "Interrupted" or "Cancelled")
    castTextFrame.timerText:SetText("")
  end
  fadeStart = GetTime()
  castFrameObj:SetScript("OnUpdate", FadeOnUpdate)
end

-- End a cast that didn't succeed: show feedback (if enabled) else just hide.
local function EndCast(interrupted)
  local cfg = GetCastbarDB()
  if cfg and cfg.interruptFeedbackEnabled then
    ShowFailFeedback(interrupted)
  else
    StopCast()
  end
end

-- ===================================================================
-- PREVIEW (shown while options panel is open for positioning)
-- ===================================================================
local function ShowPreview()
  local cfg = GetEffectiveCfg()  -- preview the cast-type profile currently being edited
  if not cfg or not cfg.enabled then return end
  if castActive or castFading then return end  -- don't override a live cast or fade-out

  local mainFrame, textFrame = GetOrCreateFrames()
  castPreviewActive = true

  -- Empower segment preview ONLY when editing the Empower profile; otherwise a plain fill bar.
  local editType = ns.CastbarOptions and ns.CastbarOptions._editProfile
  if editType == "empower" and cfg.empowerSegmentColorsEnabled then
    PlaceSegmentBars()
    -- Partially fill each visible segment so the color is obvious in the preview
    if mainFrame.stageSegBars then
      for i, sb in ipairs(mainFrame.stageSegBars) do
        if sb:IsShown() then sb:SetValue(i == 1 and 1 or i == 2 and 0.6 or 0) end
      end
    end
  else
    HideEmpowerVisuals()
    local color = cfg.barColor or {r=0.2, g=0.8, b=1, a=1}
    if cfg.conditionalColorEnabled then
      local th = ResolveProgressColor(cfg, 25, 0.5)  -- preview at 25% / 0.5s remaining
      if th then color = th end
    end
    mainFrame.fillBar:SetStatusBarColor(color.r, color.g, color.b, color.a or 1)
    mainFrame.fillBar:SetValue(0.6)
  end
  if cfg.iconMovable and cfg.showIcon then
    mainFrame.iconTex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    mainFrame.iconFrame:EnableMouse(true)
    mainFrame.iconFrame:Show()
  else
    mainFrame.iconFrame:EnableMouse(false)
    mainFrame.iconFrame:Hide()
  end

  textFrame.nameText:SetText(cfg.showText and "Castbar Preview" or "")
  textFrame.timerText:SetText(cfg.showTimer and "1.2" or "")

  -- Preview tick layout: the Empowered profile shows demo stage dividers; others the channel layout.
  if editType == "empower" then
    if cfg.empowerStageDividers ~= false then
      local n  = cfg.empowerMaxStages or 4
      local fr = {}
      for i = 1, n - 1 do fr[i] = i / n end
      local divColors = (cfg.empowerDividerPerColor and cfg.empowerSegmentColors) or nil
      PlaceTickFractions(fr, divColors)
    else
      HideTickMarks()
    end
  elseif cfg.tickMarksEnabled then
    PlaceTickFractions(GlobalTickFractions(cfg))
  else
    HideTickMarks()
  end

  -- Preview the latency zone against a demo 2s cast so it's visible while configuring.
  UpdateLatencyZone(cfg, 2)

  -- While positioning (panel open) the bar is mouse-interactive so right-click opens the
  -- Castbar tab; dragging itself is still gated by Allow Dragging in OnMouseDown.
  mainFrame:EnableMouse(true)
  mainFrame:Show()
  textFrame:Show()
end
ns.Castbar.ShowPreview = ShowPreview

local function HidePreview()
  if not castPreviewActive then return end
  castPreviewActive = false
  if not castActive then
    HideEmpowerVisuals()
    if castFrameObj then
      castFrameObj:EnableMouse(false)
      HideTickMarks()
      castFrameObj:Hide()
    end
    if castTextFrame then castTextFrame:Hide() end
  end
end
ns.Castbar.HidePreview = HidePreview

-- ===================================================================
-- EVENT HANDLER
-- ===================================================================
local castEventFrame = CreateFrame("Frame")
castEventFrame:RegisterEvent("PLAYER_LOGIN")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_START",         "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED",        "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_STOP",           "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED",         "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED",    "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED",      "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START",  "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP",   "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START",  "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP",   "player")
castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_UPDATE", "player")
castEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
castEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
castEventFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
castEventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")

castEventFrame:SetScript("OnEvent", function(self, event, unit, castGUID, spellID)
  if event == "PLAYER_LOGIN" then
    ns.Castbar.Init()
    return
  end

  -- Spec/talent change — re-run auto-switch presets for the castbar
  if event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
    C_Timer.After(0.1, function()
      local cfg = GetCastbarDB()
      if cfg and ns.Presets and ns.Presets.RunAutoSwitch then
        if ns.Presets.RunAutoSwitch(cfg, "castbar") then
          ns.Castbar.ApplyAppearance()
        end
      end
    end)
    return
  end

  -- Re-evaluate hideOutOfCombat visibility on combat state changes (no unit arg)
  if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
    if not castActive then
      local cfg = GetCastbarDB()
      if cfg and cfg.enabled and cfg.hideOutOfCombat then
        if event == "PLAYER_REGEN_ENABLED" then
          if castFrameObj then
            castFrameObj:Hide()
            if castTextFrame then castTextFrame:Hide() end
          end
        end
      end
    end
    return
  end

  -- All UNIT_SPELLCAST_* events pass unit as the first argument
  if unit ~= "player" then return end

  if event == "UNIT_SPELLCAST_START" then
    local name, _, _, startTimeMS, endTimeMS, _, _, notInterruptible = UnitCastingInfo("player")
    CastDebug("SPELLCAST_START: spellID=" .. tostring(spellID) .. " name=" .. tostring(name))
    if name then
      castCurrentGUID = castGUID
      ShowCast(spellID, startTimeMS, endTimeMS, false, notInterruptible)
    end

elseif event == "UNIT_SPELLCAST_CHANNEL_START"
    or event == "UNIT_SPELLCAST_EMPOWER_START" then

    local isEmpowerEvent = (event == "UNIT_SPELLCAST_EMPOWER_START")

    -- hard reset stale stop
    castChannelEnded = false
    channelStopTime = 0

    local savedGUID = castGUID
    castCurrentGUID = castGUID or spellID

    -- FAST PATH: same spell spam — keep bar live with no visual reset.
    -- Unconditional: UnitChannelInfo may be nil here (Blizzard race); CastOnUpdate's
    -- timing-refinement loop will pick up the new timestamps on the next frame.
    if castActive
        and castIsChannel
        and not castIsEmpowered
        and not isEmpowerEvent
        and castActiveSpellID == spellID then
        castTimingRefined = false
        CastDebug("CHANNEL_CONTINUE same spell")
        return
    end

    local function TryStart()
        local name, _, _, st, et, _, _, chanSpellID, _, stages = UnitChannelInfo("player")
        if not name then return false end

        local useSpellID = chanSpellID or spellID
        local isEmp = isEmpowerEvent or (stages and stages > 0)

        if isEmp then
            local start = (st and st > 0) and st or (GetTime() * 1000)
            local realStages, props, totalDur = ComputeEmpowerStages()
            if not realStages then
                -- Stage durations not ready yet — temporary even split over numStages+1 stages;
                -- the CastOnUpdate refinement replaces this with the real layout next frame.
                local nst = (stages and stages > 0) and stages or 3
                realStages = nst + 1
                local ha = (GetUnitEmpowerHoldAtMaxTime and GetUnitEmpowerHoldAtMaxTime("player")) or 0
                totalDur = ((et and et > start) and (et - start) or 0) + ha
                props = {}
                for i = 1, nst do props[i] = i / realStages end
            end
            if not totalDur or totalDur <= 0 then return false end
            ShowCast(useSpellID, start, start + totalDur, false, false, true, realStages, props)
        else
            ShowCast(useSpellID, st, et, true, false)
        end

        return true
    end

    -- immediate try
    if TryStart() then return end

    -- retry (fixes Blizzard nil race)
    local function retry(n)
        C_Timer.After(0.05, function()
            if castCurrentGUID ~= savedGUID then return end
            if TryStart() then return end
            if n > 1 then retry(n - 1) end
        end)
    end

    retry(3)

  elseif event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
    -- Catch-all: if EMPOWER_START was missed entirely (nil race resolved too late),
    -- initialize the bar now using current UnitChannelInfo data.
    if not castActive then
      local name, _, _, startTimeMS, endTimeMS, _, _, chanSpellID, _, numStages = UnitChannelInfo("player")
      if name then
        local useSpellID = chanSpellID or spellID
        local start = (startTimeMS and startTimeMS > 0) and startTimeMS or (GetTime() * 1000)
        local realStages, props, totalDur = ComputeEmpowerStages()
        if not realStages then
          local nst = (numStages and numStages > 0) and numStages or 3
          realStages = nst + 1
          local ha = (GetUnitEmpowerHoldAtMaxTime and GetUnitEmpowerHoldAtMaxTime("player")) or 0
          totalDur = ((endTimeMS and endTimeMS > start) and (endTimeMS - start) or 0) + ha
          props = {}
          for i = 1, nst do props[i] = i / realStages end
        end
        if totalDur and totalDur > 0 then
          ShowCast(useSpellID, start, start + totalDur, false, false, true, realStages, props)
        end
      end
    end

  elseif event == "UNIT_SPELLCAST_DELAYED" then
    -- Cast was pushed back (hit while casting); update end time
    if castActive and not castIsChannel then
      local name, _, _, startTimeMS, endTimeMS = UnitCastingInfo("player")
      if name then
        castStartTime = (startTimeMS or 0) / 1000
        castEndTime   = (endTimeMS   or 0) / 1000
      end
    end

  elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
    -- Channel speed changed (e.g. Sped Up buff); skip empowered — their end time includes holdAtMax
    if castActive and castIsChannel and not castIsEmpowered then
      local name, _, _, startTimeMS, endTimeMS = UnitChannelInfo("player")
      if name then
        castStartTime = (startTimeMS or 0) / 1000
        castEndTime   = (endTimeMS   or 0) / 1000
      end
    -- Catch-all: CHANNEL_START nil-raced and all retries resolved before UnitChannelInfo populated
    elseif not castActive then
      local name, _, _, startTimeMS, endTimeMS, _, _, chanSpellID = UnitChannelInfo("player")
      if name then
        CastDebug("CHANNEL_UPDATE catch-all: spellID=" .. tostring(chanSpellID or spellID))
        ShowCast(chanSpellID or spellID, startTimeMS, endTimeMS, true, false)
      end
    end

  elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
    -- Kicked / interrupted (any cast type). Show feedback then fade.
    if castActive then EndCast(true) end

  elseif event == "UNIT_SPELLCAST_STOP"
      or event == "UNIT_SPELLCAST_FAILED" then
    -- For channel/empower these fire for GCD rejections / queued spells, not the cast itself —
    -- CHANNEL_STOP / EMPOWER_STOP own their end. A hardcast that's still active here was cancelled.
    if castIsChannel or castIsEmpowered then return end
    -- GUID guard: rejected/queued spell attempts fire STOP/FAILED with their own GUID, not the
    -- active cast's. Only end the cast when the GUID matches what we started with.
    if castGUID ~= castCurrentGUID then return end
    if castActive then EndCast(false) end

  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    -- Channels and empowered casts fire SUCCEEDED while still running (spell commits to server).
    -- Let CHANNEL_STOP / EMPOWER_STOP handle the actual end.
    if not castIsChannel and not castIsEmpowered then StopCast() end

  elseif event == "UNIT_SPELLCAST_CHANNEL_STOP"
      or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
    castChannelEnded = true
    channelStopTime  = GetTime()
    CastDebug("CHANNEL_STOPPED FOR" .. tostring(castGUID))
  end
end)

-- ===================================================================
-- DEBUG SLASH COMMAND  (/arccastdebug)
-- ===================================================================
SLASH_ARCCASTDEBUG1 = "/arccastdebug"
SlashCmdList["ARCCASTDEBUG"] = function()
  arcCastDebug = not arcCastDebug
  local cfg = GetCastbarDB()
  local state = arcCastDebug and "|cff00ff00ON|r" or "|cffff4444OFF|r"
  print("|cff00ff00[ArcCast]|r Debug " .. state)
  if arcCastDebug and cfg then
    print("|cff00ff00[ArcCast]|r Config dump:")
    print("  enabled=" .. tostring(cfg.enabled))
    print("  hideChannels=" .. tostring(cfg.hideChannels))
    print("  hideOutOfCombat=" .. tostring(cfg.hideOutOfCombat))
    print("  castActive=" .. tostring(castActive))
    print("  castIsChannel=" .. tostring(castIsChannel))
    print("  castIsEmpowered=" .. tostring(castIsEmpowered))
    print("  castEmpowerNumStages=" .. tostring(castEmpowerNumStages))
    if castActive and castActiveSpellID > 0 then
      local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(castActiveSpellID)
      print("  |cffffd100Active spell:|r spellID=" .. castActiveSpellID
        .. " name=" .. tostring(info and info.name or "?")
        .. " notInterruptible=" .. tostring(castNotInterruptible))
    end
    print("  InCombat=" .. tostring(InCombatLockdown()))
    local n, _, _, st, et, _, _, sid, _, ns2 = UnitChannelInfo("player")
    if n then
      print("  UnitChannelInfo: name=" .. tostring(n) .. " spellID=" .. tostring(sid)
        .. " numStages=" .. tostring(ns2) .. " startMS=" .. tostring(st) .. " endMS=" .. tostring(et))
    else
      print("  UnitChannelInfo: nil (no active channel/empower)")
    end
    local cn, _, _, _, _, _, _, cni = UnitCastingInfo("player")
    print("  UnitCastingInfo: name=" .. tostring(cn) .. " notInterruptible=" .. tostring(cni))
  end
end

-- Expose castbar state for the global /arcdebug command in ArcUI_Options.lua
function ns.Castbar.GetStatus()
  local cfg = GetCastbarDB()
  local kind = castIsEmpowered and "empowered" or castIsChannel and "channel" or "cast"
  return {
    enabled           = cfg and cfg.enabled         or false,
    hideChannels      = cfg and cfg.hideChannels     or false,
    hideOutOfCombat   = cfg and cfg.hideOutOfCombat  or false,
    showIcon          = cfg and cfg.showIcon         or false,
    showTimer         = cfg and cfg.showTimer        or false,
    showText          = cfg and cfg.showText         or false,
    width             = cfg and cfg.width            or 0,
    height            = cfg and cfg.height           or 0,
    castActive        = castActive,
    castKind          = kind,
    castEmpowerStages = castEmpowerNumStages,
  }
end

-- ===================================================================
-- INSTANCE MANAGEMENT (multi-instance, resource-bar style)
-- ===================================================================
local MAX_CASTBARS = 10
ns.Castbar.MAX_CASTBARS = MAX_CASTBARS

-- Sorted list of enabled instance ids.
function ns.Castbar.GetActiveInstances()
  local db = ns.API and ns.API.GetCastbarStore and ns.API.GetCastbarStore()
  local list = {}
  if db and db.castbars then
    for i = 1, MAX_CASTBARS do
      local cb = db.castbars[i]
      if cb and cb.enabled then list[#list + 1] = i end
    end
  end
  return list
end

-- Enable the first free instance slot with the given cast-type filter; returns its id (or nil).
function ns.Castbar.CreateInstance(castType)
  local db = ns.API and ns.API.GetCastbarStore and ns.API.GetCastbarStore()
  if not (db and db.castbars) then return nil end
  for i = 1, MAX_CASTBARS do
    local cb = db.castbars[i]
    if cb and not cb.enabled then
      cb.enabled  = true
      cb.castType = castType or "all"
      ns.Castbar.ApplyAppearance()
      return i
    end
  end
  return nil
end

-- Disable an instance (instance 1 is the permanent default and is never deleted).
function ns.Castbar.DeleteInstance(id)
  if not id or id == 1 then return end
  local db = ns.API and ns.API.GetCastbarStore and ns.API.GetCastbarStore()
  if db and db.castbars and db.castbars[id] then
    db.castbars[id].enabled = false
    ns.Castbar.ApplyAppearance()
  end
end

-- Open the ArcUI options panel and jump straight to the Castbar tab (right-click handler).
function ns.Castbar.OpenOptions()
  if ns.API and ns.API.OpenOptions then ns.API.OpenOptions() end
  local ACD = LibStub and LibStub("AceConfigDialog-3.0", true)
  if ACD then
    -- Defer one frame so the panel is built before we navigate to the Castbar tab.
    C_Timer.After(0, function() ACD:SelectGroup("ArcUI", "castbar") end)
  end
end

-- ===================================================================
-- SHARED CASTBAR PROMOTE
-- Copy THIS character's castbar config into the account-wide shared store so shared mode
-- starts from the look you're already using (not defaults). Deep copy via CopyTable so the
-- nested tables (profiles, spellOverrides, colorThresholds, empowerSegmentColors, positions)
-- never alias the per-character ones. Reversible: the per-character store is left untouched.
-- ===================================================================
function ns.Castbar.PromoteToShared()
  local src = ns.db and ns.db.char and ns.db.char.castbars
  local dst = ns.db and ns.db.global and ns.db.global.castbars
  if not (src and dst) then return end
  for id in pairs(src) do
    if type(id) == "number" then
      dst[id] = CopyTable(src[id])
    end
  end
end

-- ===================================================================
-- INIT
-- ===================================================================
-- One-time migration: the castbar used to live in a single db.castbar table. It's now
-- multi-instance (db.castbars[1..N]); move any old settings into instance 1 so testers
-- don't lose their configuration. (Castbar is unreleased, so this only matters locally.)
local function MigrateLegacyCastbar()
  local db = ns.API and ns.API.GetDB and ns.API.GetDB()
  if not db or not db.castbar then return end
  db.castbars = db.castbars or {}
  local old, dst = db.castbar, db.castbars[1]
  if dst then
    for k, v in pairs(old) do dst[k] = v end
    -- Fold the old per-cast-type colors into the new cast-type profiles.
    dst.profiles          = dst.profiles or {}
    dst.profiles.hardcast = dst.profiles.hardcast or {}
    dst.profiles.channel  = dst.profiles.channel  or {}
    dst.profiles.empower  = dst.profiles.empower  or {}
    if old.barColor     then dst.profiles.hardcast.barColor = old.barColor end
    if old.channelColor then dst.profiles.channel.barColor  = old.channelColor end
    if old.empowerColor then dst.profiles.empower.barColor  = old.empowerColor end
    dst.channelColor, dst.empowerColor = nil, nil  -- no longer used
  end
  db.castbar = nil
end

function ns.Castbar.Init()
  MigrateLegacyCastbar()
  ApplyBlizzCastBarVisibility()
  ns.Castbar.ApplyAppearance()
  if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
    ns.CDMShared.RegisterPanelCallback("Castbar", {
      onOpen  = ShowPreview,
      onClose = HidePreview,
    })
  end
  if ns._arcUIOptionsOpen then ShowPreview() end
end

-- ===================================================================
-- END OF ArcUI_Castbar.lua
-- ===================================================================
