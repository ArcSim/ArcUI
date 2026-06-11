-- ===================================================================
-- ArcUI_Display.lua
-- Display system supporting multiple independent bars
-- v2.9.12: Fixed stale bar cache causing tick marks issues on update
--   - Expanded appearance hash to include maxStacks, tick settings, bar dimensions
--   - Bars now properly rebuild when tick-related settings change
--   - Forces full refresh on addon update (hash format change)
-- v2.9.11: Fixed stack text draggability for bar mode
--   - Stack text now only draggable when Text Anchor set to "Free (Drag)"
--   - Added textLocked setting to lock FREE mode position
--   - Fixed EnableMouse to use textAnchor == "FREE" pattern
-- v2.9.10: Fixed tick marks and reverseFill for stack bars
--   - Tick marks now positioned correctly for vertical bars (fill bottom-to-top)
--   - Fixed reverseFill not working for granular/perStack/threshold display modes
--   - Added reverseFill support to all bar positioning logic
-- v2.9.9: Fixed stack text always draggable on aura stack bars
--   - Stack text now always draggable unless explicitly locked
--   - Added iconStackLocked setting to lock position
-- v2.9.8: Fixed ColorCurve alpha flickering (base color alpha 0 issue)
--   - Use SetStatusBarColor(colorResult:GetRGBA()) for ColorCurve (handles alpha)
--   - Apply color BEFORE SetAlpha(1) to prevent any flash
--   - Reset VertexColor to white when switching modes
--   - Base color alpha 0 now correctly makes bar invisible at 100%
-- v2.9.7: ColorCurve + Gradient API Limitation
--   - SetGradient() does NOT accept secret values (AllowedWhenUntainted)
--   - SetStatusBarColor() DOES accept secrets (InsecureSecretArguments)
--   - Therefore: Conditional Color and Gradient are mutually exclusive
--   - When Conditional Color enabled: threshold colors work, gradient skipped
-- v2.9.6: Fixed white bar flash timing
--   - Check aura existence EVERY FRAME (no throttle) for instant response
--   - Only throttle color/value updates, not expiry detection
--   - Use bar:SetAlpha(0) not texture alpha (animation overrides texture)
--   - Restore bar:SetAlpha(1) when new aura starts
-- v2.9.2: Fixed ColorCurve alpha handling for duration bars
--   - GetRGB() → GetRGBA() so color picker opacity applies to bar texture
--   - Threshold settings hash now includes alpha for proper cache invalidation
-- v2.9.1: Fixed ColorCurve threshold for duration bars
--   - Removed SetType() call (ColorCurves don't support it)
--   - Fixed curve point setup for step-like transitions
--   - Added OnUpdate handler for continuous color updates as aura depletes
--   - Properly clears OnUpdate when bar inactive or threshold disabled
-- ===================================================================

local ADDON, ns = ...
ns.Display = ns.Display or {}

-- Performance: local aliases for hot-path globals
local string_format = string.format
local math_floor = math.floor
-- Round to nearest integer for pixel-perfect SetSize/SetPoint calls.
-- Prevents float drift (e.g. 166 * 1.0 stored via AceDB returning 165.9999...)
-- from causing WoW to round the wrong direction at different UI scales.
local function PixelSize(n) return math_floor(n + 0.5) end

-- Physical-pixel-aware snap: matches the rounding used by CDMGroups icon sizing
-- (GetSlotDimensions) so bar widths align exactly with icon grid widths.
-- Formula: floor(n / pmult + 0.5) * pmult  where pmult = (768/screenH) / UIScale
local function PixelSnap(n, effectiveScale)
    local _, h = GetPhysicalScreenSize()
    local s = effectiveScale or UIParent:GetScale()
    if h and h > 0 and s and s > 0 then
        local pmult = (768 / h) / s
        return math_floor(n / pmult + 0.5) * pmult
    end
    return math_floor(n + 0.5)
end

local math_ceil = math.ceil
local math_max = math.max
local math_min = math.min

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- ===================================================================
-- INITIALIZATION FLAG: Prevent bar flash during reload
-- Bars stay hidden until initialization completes (after PLAYER_ENTERING_WORLD + delay)
-- ===================================================================
local initializationComplete = false

-- Mark initialization as complete (called from Core.lua after setup)
function ns.Display.MarkInitializationComplete()
  initializationComplete = true
end

-- Check if initialization is complete
function ns.Display.IsInitialized()
  return initializationComplete
end

-- ===================================================================
-- LIBPLEEBUG PROFILING SETUP
-- ===================================================================
local MemDebug = LibStub and LibStub("LibPleebug-1", true)
local P, TrackThis
if MemDebug then
  P, TrackThis = MemDebug:DropIn(ns.Display)
end
ns.Display._TrackThis = TrackThis

-- ═══════════════════════════════════════════════════════════════════════════
-- PERFORMANCE: Safe Show/Hide that skip redundant calls
-- Calling Hide() on already-hidden frame still has C++ overhead
-- ═══════════════════════════════════════════════════════════════════════════
local function SafeHide(frame)
    if frame and frame:IsShown() then
        frame:Hide()
    end
end

local function SafeShow(frame)
    if frame and not frame:IsShown() then
        frame:Show()
    end
end

-- Track if delete buttons should be visible (set when options panel opens)
local deleteButtonsVisible = false

-- Forward declaration for delete confirmation (defined later in file)
local ShowDeleteConfirmation

-- ===================================================================
-- COLORCURVE CACHE FOR DURATION BARS (v2.8.2 - Fixed config key mismatch)
-- Curves are created once per bar and rebuilt when settings change
-- ===================================================================
local durationColorCurves = {}  -- [barNumber] = { curve = ColorCurve, settingsHash = string }

-- Default colors matching AppearanceOptions display defaults
local DURATION_THRESHOLD_DEFAULT_COLORS = {
  [2] = {r=0.8, g=0.8, b=0, a=1},   -- Yellow
  [3] = {r=1, g=0.5, b=0, a=1},     -- Orange
  [4] = {r=1, g=0.3, b=0, a=1},     -- Red-Orange
  [5] = {r=1, g=0, b=0, a=1},       -- Red
}
local DURATION_THRESHOLD_DEFAULT_VALUES = {
  [2] = 75,
  [3] = 50,
  [4] = 25,
  [5] = 10,
}

-- Helper to create a simple hash of threshold settings for cache invalidation
local function GetThresholdSettingsHash(cfg, baseColor)
  local parts = {}
  local bc = baseColor or {r=0, g=0.8, b=1, a=1}
  table.insert(parts, string.format("bc:%.2f,%.2f,%.2f,%.2f", bc.r, bc.g, bc.b, bc.a or 1))
  for i = 2, 5 do
    local enabled = cfg["durationThreshold" .. i .. "Enabled"]
    local value = cfg["durationThreshold" .. i .. "Value"] or DURATION_THRESHOLD_DEFAULT_VALUES[i]
    local color = cfg["durationThreshold" .. i .. "Color"] or DURATION_THRESHOLD_DEFAULT_COLORS[i]
    if enabled then
      table.insert(parts, string.format("t%d:%d,%.2f,%.2f,%.2f,%.2f", i, value, color.r, color.g, color.b, color.a or 1))
    end
  end
  table.insert(parts, cfg.durationThresholdAsSeconds and "sec" or "pct")
  table.insert(parts, tostring(cfg.durationThresholdMaxDuration or 0))
  return table.concat(parts, "|")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PERFORMANCE: Bar appearance caching
-- Expensive operations (SetTexture, SetOrientation, etc) only need to run
-- when appearance settings change, not every frame. This hash tracks changes.
-- ═══════════════════════════════════════════════════════════════════════════
local function GetBarAppearanceHash(barConfig)
  if not barConfig or not barConfig.display then return nil end
  local d = barConfig.display
  local t = barConfig.tracking or {}
  local bc = d.barColor or {r=0, g=0, b=0}
  local tc = d.tickColor or {r=0, g=0, b=0}
  -- Include all settings that affect bar setup (not dynamic values like fill %)
  -- Added: maxStacks, tick settings, width/height for tick positioning
  return string.format("%s|%s|%s|%s|%.2f|%.2f|%.2f|%s|%s|%d|%s|%s|%.2f|%.2f|%.2f|%d|%d",
    d.texture or "default",
    d.barOrientation or "horizontal",
    tostring(d.barReverseFill),
    tostring(d.showBackground),
    bc.r, bc.g, bc.b,
    tostring(d.useGradient),
    tostring(d.durationColorCurveEnabled),
    t.maxStacks or 0,
    tostring(d.showTickMarks),
    d.tickMode or "percent",
    tc.r, tc.g, tc.b,
    d.width or 200,
    d.height or 20
  )
end

-- Create or get cached ColorCurve for a duration bar
-- ColorCurves use linear interpolation by default - we create step transitions
-- by placing pairs of points very close together (epsilon apart)
local function GetDurationColorCurve(barNumber, barConfig)
  if not barConfig or not barConfig.display then return nil end
  
  local cfg = barConfig.display
  if not cfg.durationColorCurveEnabled then return nil end
  
  -- Check if ColorCurve API exists (WoW 12.0+)
  if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then
    return nil
  end
  
  -- Get base bar color (used at 100% remaining)
  local baseColor = cfg.barColor or {r=0, g=0.8, b=1, a=1}
  
  -- Check if we need to rebuild the curve (settings changed)
  local currentHash = GetThresholdSettingsHash(cfg, baseColor)
  local cached = durationColorCurves[barNumber]
  
  if cached and cached.settingsHash == currentHash then
    return cached.curve
  end
  
  -- Build threshold points from UI settings
  local thresholds = {}
  
  for i = 2, 5 do
    local enabled = cfg["durationThreshold" .. i .. "Enabled"]
    local value = cfg["durationThreshold" .. i .. "Value"] or DURATION_THRESHOLD_DEFAULT_VALUES[i]
    local color = cfg["durationThreshold" .. i .. "Color"] or DURATION_THRESHOLD_DEFAULT_COLORS[i]
    
    if enabled then
      table.insert(thresholds, { value = value, color = color })
    end
  end
  
  -- If no thresholds enabled, return nil (use base color only)
  if #thresholds == 0 then
    durationColorCurves[barNumber] = nil
    return nil
  end
  
  -- Sort thresholds by value ascending (lowest % first)
  -- e.g., [{value=10%, Red}, {value=25%, Orange}, {value=50%, Yellow}]
  table.sort(thresholds, function(a, b) return a.value < b.value end)
  
  -- Create the ColorCurve (NOTE: ColorCurves don't have SetType - they use linear interpolation)
  -- We simulate step behavior by using pairs of points with tiny epsilon gaps
  local curve = C_CurveUtil.CreateColorCurve()
  
  -- Mode settings
  local asSeconds = cfg.durationThresholdAsSeconds
  local maxDuration = cfg.durationThresholdMaxDuration or 30
  
  -- Epsilon for creating instant color transitions
  local EPSILON = 0.0001
  
  -- Build curve points for step-like transitions
  -- For threshold at 50%, we want:
  --   0% to 49.99% = threshold color
  --   50% to 100% = next higher color (or base)
  --
  -- Example: thresholds = [{10%=Red}, {50%=Yellow}], base=Blue
  -- Points:
  --   0.0 = Red (lowest threshold's color for 0-10%)
  --   0.10 = Red (just before transition)
  --   0.10+ε = Yellow (transition to next threshold)
  --   0.50 = Yellow (just before transition)
  --   0.50+ε = Blue (transition to base)
  --   1.0 = Blue (at full duration)
  
  -- Start with lowest threshold's color at 0%
  local lowestColor = thresholds[1].color
  curve:AddPoint(0.0, CreateColor(lowestColor.r, lowestColor.g, lowestColor.b, lowestColor.a or 1))
  
  -- Add transition points for each threshold
  for i = 1, #thresholds do
    local t = thresholds[i]
    local pct
    if asSeconds then
      pct = t.value / maxDuration
    else
      pct = t.value / 100
    end
    pct = math_max(0, math_min(1, pct))
    
    -- Determine next color (above this threshold)
    local nextColor
    if i == #thresholds then
      -- Last threshold - above this use base color
      nextColor = baseColor
    else
      -- Use next threshold's color
      nextColor = thresholds[i + 1].color
    end
    
    -- Add point just before threshold (current threshold's color)
    local currentColor = t.color
    if pct > EPSILON then
      curve:AddPoint(pct - EPSILON, CreateColor(currentColor.r, currentColor.g, currentColor.b, currentColor.a or 1))
    end
    
    -- Add point at threshold (next color begins)
    curve:AddPoint(pct, CreateColor(nextColor.r, nextColor.g, nextColor.b, nextColor.a or 1))
  end
  
  -- End with base color at 100%
  curve:AddPoint(1.0, CreateColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1))
  
  -- Cache
  durationColorCurves[barNumber] = { curve = curve, settingsHash = currentHash }
  return curve
end

-- Clear cached curve for a bar (called when settings change)
function ns.Display.ClearDurationColorCurve(barNumber)
  durationColorCurves[barNumber] = nil
  -- Also clear live OnUpdate data so the alreadyActive check doesn't skip re-setup
  -- Without this, changing conditional color settings has no effect on running bars
  -- because the old curve reference persists in the OnUpdate closure
  local frames = ns.Display._barFrames
  if frames and frames[barNumber] and frames[barNumber].barFrame then
    local bar = frames[barNumber].barFrame.bar
    if bar then
      bar.colorCurveData = nil
      bar.auraMonitorData = nil
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPER: Rotate StatusBar Texture for Vertical Bars
-- ===================================================================
-- HELPER: APPLY FILL TEXTURE SCALE
-- ===================================================================
local function ApplyFillTextureScale(statusBar, scale, isVertical)
  if not statusBar then return end
  scale = scale or 1.0
  
  -- Get the StatusBar texture and apply scaling
  local texture = statusBar:GetStatusBarTexture()
  if texture then
    -- Reset to defaults first
    texture:SetTexCoord(0, 1, 0, 1)
    texture:SetHorizTile(false)
    texture:SetVertTile(false)
    
    -- For StatusBars, we control tiling through HorizTile/VertTile
    -- Scale < 1 = more repetitions (tiled), Scale > 1 = stretched
    if scale < 1 then
      -- Tiled mode - texture repeats
      if isVertical then
        texture:SetVertTile(true)
      else
        texture:SetHorizTile(true)
      end
    else
      -- Stretched mode - texture stretches
      -- Adjust tex coords to stretch - smaller value = more stretch visible
      local stretchAmount = 1.0 / scale
      if isVertical then
        -- For vertical bars, stretch along the Y axis
        texture:SetTexCoord(0, 1, 0, stretchAmount)
      else
        -- For horizontal bars, stretch along the X axis
        texture:SetTexCoord(0, stretchAmount, 0, 1)
      end
    end
  end
end

-- ===================================================================
-- FILE-LEVEL PERFORMANCE HELPERS (hoisted from UpdateBar inner closures)
-- ===================================================================

-- Pre-built format strings to avoid string concatenation in hot paths
-- Used by FormatDuration AND SetFormattedText for secret-safe duration display
local DURATION_FMT = { [0] = "%.0f", [1] = "%.1f", [2] = "%.2f", [3] = "%.3f" }

-- Convert threshold value; if thresholdAsPercent, convert percentage to actual value
local function GetThresholdValue(thresholdMinValue, defaultValue, thresholdAsPercent, maxStacks)
  local value = thresholdMinValue or defaultValue
  if thresholdAsPercent then
    return math_floor(maxStacks * value / 100)
  end
  return value
end

-- Get color for a granular bar value based on threshold ranges
local WHITE_COLOR = {r=1, g=1, b=1, a=1}

-- Sort comparator for color ranges (avoids closure alloc in table.sort)
local function ColorRangeSort(a, b) return a.startValue < b.startValue end

local function GetColorForValue(val, enableMaxColor, maxStacks, maxColor, colorRanges)
  if enableMaxColor and val == maxStacks then
    return maxColor
  end
  local color = colorRanges[1] and colorRanges[1].color or WHITE_COLOR
  for _, range in ipairs(colorRanges) do
    if val >= range.startValue then
      color = range.color
    else
      break
    end
  end
  return color
end

-- Check if a multi-icon index should show duration text
-- showDurationOn: 0=none, 1=first, 2-10=first N, -1=last
local function ShouldShowIconDuration(iconIndex, showDurationOn, maxStacks, detectedMultipleStacks)
  if showDurationOn == 0 then
    return false
  elseif showDurationOn == -1 then
    return iconIndex == maxStacks
  elseif showDurationOn == 1 then
    return iconIndex == 1
  elseif showDurationOn >= 2 then
    if iconIndex == 1 then
      return true
    elseif iconIndex <= showDurationOn then
      return detectedMultipleStacks
    end
    return false
  end
  return false
end

-- ===================================================================
-- HELPER: SAFE NUMBER COMPARISON (protects against secret values)
-- Returns true if value is a regular number and > 0
-- ===================================================================
local function IsNumericAndPositive(value)
  if value == nil then return false end
  -- Secret values can't be compared — treat as non-numeric (use issecretvalue, not pcall)
  if issecretvalue and issecretvalue(value) then return false end
  return type(value) == "number" and value > 0
end

-- ===================================================================
-- HELPER: FORMAT DURATION WITH DECIMALS (for NON-SECRET values only)
-- For secret values from DurationObject, use SetFormattedText instead:
--   fontString:SetFormattedText(DURATION_FMT[decimals], secretValue)
-- This function handles preview mode values and other regular numbers.
-- ===================================================================
local function FormatDuration(value, decimals)
  if value == nil then return "" end
  local fmt = DURATION_FMT[decimals or 1] or "%.1f"
  local num = tonumber(value)
  if num then
    return string_format(fmt, num)
  end
  -- Non-number: pass through (shouldn't happen for non-secret path)
  return value
end

-- ===================================================================
-- HELPER: APPLY SMOOTHING TO STATUSBAR
-- ===================================================================
-- WoW 12.0+: Use Enum.StatusBarInterpolation.ExponentialEaseOut on SetValue/SetMinMaxValues
-- instead of the legacy SetSmoothing API for much smoother ease-out animation curves
-- ===================================================================
local SMOOTH_INTERPOLATION = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut or nil

local function GetBarInterpolation(enableSmooth)
  return enableSmooth and SMOOTH_INTERPOLATION or nil
end

local function ApplyBarSmoothing(bar, enableSmooth)
  if not bar then return end
  -- Disable legacy smoothing - we use interpolation enum on SetValue/SetMinMaxValues instead
  if bar.SetSmoothing then
    bar:SetSmoothing(false)
  end
end

-- ===================================================================
-- HELPER: APPLY GRADIENT TO STATUSBAR
-- Creates a visual gradient effect by blending the bar color with a second color
-- currentColor: Optional {r,g,b,a} table - pass the color you just set to avoid
--               GetStatusBarColor() which returns secret values in combat
-- ===================================================================
local function ApplyBarGradient(bar, barConfig, currentColor)
  if not bar then return end
  
  local cfg = barConfig and barConfig.display
  if not cfg then return end
  
  local texture = bar:GetStatusBarTexture()
  if not texture or not texture.SetGradient then return end
  
  local useGradient = cfg.useGradient
  local direction = cfg.gradientDirection or "VERTICAL"
  local intensity = cfg.gradientIntensity or 0.5
  local secondColor = cfg.gradientSecondColor or {r=0, g=0, b=0, a=0.5}
  
  -- Use provided currentColor, or fall back to cfg.barColor (never use GetStatusBarColor - returns secrets)
  local baseColor = currentColor or cfg.barColor
  if not baseColor or type(baseColor.r) ~= "number" or type(baseColor.g) ~= "number" or type(baseColor.b) ~= "number" then
    baseColor = {r=0, g=0.8, b=1, a=1}  -- Default cyan fallback
  end
  
  local r, g, b = baseColor.r, baseColor.g, baseColor.b
  local a = (type(baseColor.a) == "number") and baseColor.a or 1
  
  if not useGradient then
    -- Reset gradient (solid color) - still need to call SetGradient to clear any previous gradient
    local solidColor = CreateColor(r, g, b, a)
    texture:SetGradient(direction, solidColor, solidColor)
    return
  end
  
  -- Validate secondColor
  local sc = secondColor
  if not sc or type(sc.r) ~= "number" or type(sc.g) ~= "number" or type(sc.b) ~= "number" then
    sc = {r=0, g=0, b=0, a=0.5}
  end
  
  -- Blend the base color with the second color based on intensity
  local r2 = r + (sc.r - r) * intensity
  local g2 = g + (sc.g - g) * intensity
  local b2 = b + (sc.b - b) * intensity
  local a2 = a  -- Keep alpha from main color for consistency
  
  -- Apply gradient
  local startColor = CreateColor(r, g, b, a)
  local endColor = CreateColor(r2, g2, b2, a2)
  texture:SetGradient(direction, startColor, endColor)
end

-- ===================================================================
-- HELPER: GET FONT OUTLINE FLAG STRING
-- ===================================================================
local function GetOutlineFlag(outlineSetting)
  -- Convert setting to font flag
  if outlineSetting == "NONE" or outlineSetting == "" or not outlineSetting then
    return ""
  elseif outlineSetting == "THICKOUTLINE" then
    return "THICKOUTLINE"
  else
    return "OUTLINE"  -- Default
  end
end

-- ===================================================================
-- HELPER: APPLY TEXT SHADOW
-- ===================================================================
local function ApplyTextShadow(fontString, enableShadow, shadowColor)
  if not fontString then return end
  if enableShadow then
    local sc = shadowColor or {r=0, g=0, b=0, a=1}
    fontString:SetShadowColor(sc.r, sc.g, sc.b, sc.a or 1)
    fontString:SetShadowOffset(1, -1)
  else
    fontString:SetShadowOffset(0, 0)
  end
end

-- ===================================================================
-- FRAME STORAGE (per bar)
-- ===================================================================
local barFrames = {}  -- [barNumber] = {barFrame, textFrame}
ns.Display._barFrames = barFrames  -- Expose for debugger

-- ===================================================================
-- EVENT-DRIVEN AURA POLLING OPTIMIZATION
-- Tracks which bars are actively polling auras, stops polling on expiry
-- ===================================================================
local activeAuraPolling = {}  -- [barNumber] = { unit = string, auraID = number, barFrame = frame }

-- Helper to register a bar for aura polling tracking
local function RegisterAuraPolling(barNumber, unit, auraID, barFrame, iconFrame, durationFrame)
  if not unit or not auraID then return end
  activeAuraPolling[barNumber] = {
    unit = unit,
    auraID = auraID,
    barFrame = barFrame,
    iconFrame = iconFrame,
    durationFrame = durationFrame,
  }
end

-- Helper to unregister a bar from aura polling
local function UnregisterAuraPolling(barNumber)
  activeAuraPolling[barNumber] = nil
end

-- ===================================================================
-- LIVE PREVIEW MODE (uses actual bars, not separate preview)
-- ===================================================================
local previewMode = false
local previewStacks = 0.5  -- Decimal 0-1 (0.5 = 50%)

function ns.Display.SetPreviewMode(enabled)
  previewMode = enabled
  if enabled then
    -- Update all bars to show preview value (convert decimal to stacks)
    local activeBars = ns.API.GetActiveBars and ns.API.GetActiveBars() or {}
    for _, barNum in ipairs(activeBars) do
      local barConfig = ns.API.GetBarConfig and ns.API.GetBarConfig(barNum)
      if barConfig then
        local maxStacks = barConfig.tracking.maxStacks or 10
        local useDurationBar = barConfig.tracking.useDurationBar
        -- Convert decimal (0-1) to actual stack count
        local stackCount = math_floor(previewStacks * maxStacks + 0.5)
        
        if useDurationBar then
          ns.Display.UpdateDurationBar(barNum, stackCount, maxStacks, true, nil, nil, nil)
        else
          ns.Display.UpdateBar(barNum, stackCount, maxStacks, true)
        end
      end
    end
  else
    -- Refresh all bars to show real values
    if ns.API.RefreshAll then
      ns.API.RefreshAll()
    end
  end
end

function ns.Display.SetPreviewStacks(decimal)
  previewStacks = decimal
  if previewMode then
    -- Update all bars with new preview decimal (convert to stacks per bar)
    local activeBars = ns.API.GetActiveBars and ns.API.GetActiveBars() or {}
    for _, barNum in ipairs(activeBars) do
      local barConfig = ns.API.GetBarConfig and ns.API.GetBarConfig(barNum)
      if barConfig then
        local maxStacks = barConfig.tracking.maxStacks or 10
        local useDurationBar = barConfig.tracking.useDurationBar
        -- Convert decimal (0-1) to actual stack count
        local stackCount = math_floor(decimal * maxStacks + 0.5)
        
        if useDurationBar then
          ns.Display.UpdateDurationBar(barNum, stackCount, maxStacks, true, nil, nil, nil)
        else
          ns.Display.UpdateBar(barNum, stackCount, maxStacks, true)
        end
      end
    end
  end
end

function ns.Display.IsPreviewMode()
  return previewMode
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PERFORMANCE OPTIMIZATION: Cached lookups and state tracking
-- Avoids expensive repeated calls in the ticker loop
-- ═══════════════════════════════════════════════════════════════════════════

-- Cache AceConfigDialog reference (only lookup once per session)
local cachedAceConfigDialog = nil
local function GetAceConfigDialog()
  if not cachedAceConfigDialog then
    cachedAceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
  end
  return cachedAceConfigDialog
end

-- Helper to check if options panel is open (uses cached reference)
local function IsOptionsOpen()
  local AceConfigDialog = GetAceConfigDialog()
  if AceConfigDialog and AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["ArcUI"] then
    return true
  end
  return false
end

-- Cache current spec (updated via event, not API call every frame)
local cachedCurrentSpec = nil
local function GetCachedSpec()
  if cachedCurrentSpec == nil then
    cachedCurrentSpec = GetSpecialization() or 0
  end
  return cachedCurrentSpec
end

-- Invalidate spec cache (call on PLAYER_SPECIALIZATION_CHANGED)
function ns.Display.InvalidateSpecCache()
  cachedCurrentSpec = nil
  -- Force full bar re-layout on next UpdateBar — container sizes change after spec reflow
  for barNumber, frames in pairs(barFrames) do
    if frames.barFrame then
      frames.barFrame._lastConfigVersion = -1
      frames.barFrame._lastActive = nil
      frames.barFrame._lastOptionsOpen = nil
    end
  end
end

-- Export for Core.lua and other modules
function ns.Display.GetCachedSpec()
  return GetCachedSpec()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BAR VISIBILITY CACHE
-- Track computed visibility per bar to skip recalculation every frame
-- ═══════════════════════════════════════════════════════════════════════════
local barVisibilityCache = {}  -- [barNumber] = { visible = bool, version = number }
local visibilityCacheVersion = 0

-- Invalidate visibility cache (call on combat change, spec change, settings change)
function ns.Display.InvalidateVisibilityCache(barNumber)
  if barNumber then
    barVisibilityCache[barNumber] = nil
  else
    -- Invalidate all
    wipe(barVisibilityCache)
    visibilityCacheVersion = visibilityCacheVersion + 1
  end
end

-- Get cached visibility for a bar (returns nil if not cached)
local function GetCachedVisibility(barNumber)
  local cached = barVisibilityCache[barNumber]
  if cached and cached.version == visibilityCacheVersion then
    return cached.visible
  end
  return nil
end

-- Set cached visibility
local function SetCachedVisibility(barNumber, visible)
  barVisibilityCache[barNumber] = {
    visible = visible,
    version = visibilityCacheVersion
  }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BAR APPEARANCE TRACKING
-- Track when appearance was last applied to skip redundant work
-- Appearance = textures, colors, fonts, positions (changes on settings)
-- Values = bar fill, text content (changes every frame)
-- ═══════════════════════════════════════════════════════════════════════════
local barAppearanceApplied = {}  -- [barNumber] = configVersion

-- Get config version for appearance tracking
local function GetBarConfigVersion(barNumber)
  local db = ns.db and ns.db.char
  local barConfig = db and db.bars and db.bars[barNumber]
  return barConfig and barConfig._configVersion or 0
end

-- Check if appearance needs refresh
local function NeedsAppearanceRefresh(barNumber)
  local currentVersion = GetBarConfigVersion(barNumber)
  local appliedVersion = barAppearanceApplied[barNumber] or -1
  return currentVersion ~= appliedVersion
end

-- Mark appearance as applied
local function MarkAppearanceApplied(barNumber)
  barAppearanceApplied[barNumber] = GetBarConfigVersion(barNumber)
end

-- Force appearance refresh for a bar
function ns.Display.InvalidateBarAppearance(barNumber)
  if barNumber then
    barAppearanceApplied[barNumber] = -1
  else
    -- Invalidate all
    wipe(barAppearanceApplied)
  end
end

-- Increment config version (call when ANY setting changes)
function ns.Display.BumpConfigVersion(barNumber)
  local db = ns.db and ns.db.char
  local barConfig = db and db.bars and db.bars[barNumber]
  if barConfig then
    barConfig._configVersion = (barConfig._configVersion or 0) + 1
    barAppearanceApplied[barNumber] = -1  -- Force refresh
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPER: Get CENTER-based position for scale-safe anchoring
-- When scaling a frame, it scales from its anchor point. Using CENTER ensures
-- the frame scales uniformly in all directions, preventing position drift.
-- ═══════════════════════════════════════════════════════════════════════════
local function GetCenterBasedPosition(frame)
  if not frame then return nil end
  
  -- Get the frame's center in screen coordinates
  local centerX, centerY = frame:GetCenter()
  if not centerX or not centerY then return nil end
  
  -- Get UIParent center
  local uiCenterX, uiCenterY = UIParent:GetCenter()
  if not uiCenterX or not uiCenterY then return nil end
  
  -- Calculate offset from UIParent center (accounting for effective scale)
  local effectiveScale = frame:GetEffectiveScale()
  local uiScale = UIParent:GetEffectiveScale()
  
  local x = (centerX - uiCenterX) * (effectiveScale / uiScale)
  local y = (centerY - uiCenterY) * (effectiveScale / uiScale)
  
  -- Round to integer UI units first (same as CDMGroups SetPosition),
  -- then snap to physical pixel boundary using the frame's own effective scale.
  x = math.floor(x + 0.5)
  y = math.floor(y + 0.5)
  x = PixelSnap(x, effectiveScale)
  y = PixelSnap(y, effectiveScale)
  
  return {
    point = "CENTER",
    relPoint = "CENTER",
    x = x,
    y = y
  }
end

-- ===================================================================
-- CREATE BAR FRAME FOR SPECIFIC BAR NUMBER
-- ===================================================================
local function CreateBarFrame(barNumber)
  local frame = CreateFrame("Frame", "ArcUIBarFrame" .. barNumber, UIParent)
  frame:SetSize(200, 20)
  frame:SetPoint("CENTER", 0, 200 - ((barNumber - 1) * 30))
  frame:SetMovable(true)
  frame:EnableMouse(false)
  frame:SetClampedToScreen(true)
  frame:Hide()  -- Start hidden, UpdateBar will show if appropriate
  frame.barNumber = barNumber  -- Store for debugging
  
  -- Background
  frame.bg = frame:CreateTexture(nil, "BACKGROUND")
  frame.bg:SetAllPoints()
  frame.bg:SetColorTexture(0.2, 0.2, 0.2, 0.8)
  frame.bg:SetSnapToPixelGrid(false)
  frame.bg:SetTexelSnappingBias(0)
  
  -- Status bar (fills frame - padding applied by ApplyAppearance if configured)
  frame.bar = CreateFrame("StatusBar", nil, frame)
  frame.bar:SetAllPoints(frame)  -- No padding by default
  frame.bar:SetMinMaxValues(0, 10)
  frame.bar:SetValue(0)
  frame.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  frame.bar:SetStatusBarColor(0, 0.5, 1, 1)
  -- Note: SetRotatesTexture is set in ApplyAppearance when orientation is known
  
  -- Prevent pixel snapping on StatusBar texture for crisp rendering
  local barTexture = frame.bar:GetStatusBarTexture()
  if barTexture then
    barTexture:SetSnapToPixelGrid(false)
    barTexture:SetTexelSnappingBias(0)
  end
  
  -- Background (child of statusbar, layer BACKGROUND)
  -- This is hidden because we use frame.bg instead for consistent background across all modes
  frame.bar.bg = frame.bar:CreateTexture(nil, "BACKGROUND")
  frame.bar.bg:SetAllPoints(frame.bar)
  frame.bar.bg:SetColorTexture(0, 0, 0, 0)  -- Transparent
  frame.bar.bg:SetSnapToPixelGrid(false)
  frame.bar.bg:SetTexelSnappingBias(0)
  frame.bar.bg:Hide()
  
  -- TICK OVERLAY FRAME - sits above fill bars (level updated by ApplyAppearance)
  frame.tickOverlay = CreateFrame("Frame", nil, frame)
  frame.tickOverlay:SetAllPoints(frame)
  frame.tickOverlay:SetFrameLevel(frame:GetFrameLevel() + 22)
  
  -- TRACKING FAIL OVERLAY - red background with "Tracking Failed" text
  -- Uses HIGH strata to appear above all bar elements including text frames
  frame.trackingFailOverlay = CreateFrame("Frame", nil, frame)
  frame.trackingFailOverlay:SetAllPoints(frame)
  frame.trackingFailOverlay:SetFrameStrata("HIGH")
  frame.trackingFailOverlay:SetFrameLevel(100)
  frame.trackingFailOverlay:Hide()
  
  frame.trackingFailOverlay.bg = frame.trackingFailOverlay:CreateTexture(nil, "BACKGROUND")
  frame.trackingFailOverlay.bg:SetAllPoints()
  frame.trackingFailOverlay.bg:SetColorTexture(0.6, 0, 0, 0.5)  -- Dark red, semi-transparent
  
  frame.trackingFailOverlay.text = frame.trackingFailOverlay:CreateFontString(nil, "OVERLAY")
  frame.trackingFailOverlay.text:SetPoint("CENTER")
  frame.trackingFailOverlay.text:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
  frame.trackingFailOverlay.text:SetText("Tracking Failed")
  frame.trackingFailOverlay.text:SetTextColor(1, 1, 1, 1)
  
  -- MISSING SETUP OVERLAY - yellow background with "Missing Setup" text
  -- Shows when bar is enabled but no tracking configured
  frame.missingSetupOverlay = CreateFrame("Frame", nil, frame)
  frame.missingSetupOverlay:SetAllPoints(frame)
  frame.missingSetupOverlay:SetFrameStrata("HIGH")
  frame.missingSetupOverlay:SetFrameLevel(100)
  frame.missingSetupOverlay:Hide()
  
  frame.missingSetupOverlay.bg = frame.missingSetupOverlay:CreateTexture(nil, "BACKGROUND")
  frame.missingSetupOverlay.bg:SetAllPoints()
  frame.missingSetupOverlay.bg:SetColorTexture(0.6, 0.5, 0, 0.5)  -- Dark yellow, semi-transparent
  
  frame.missingSetupOverlay.text = frame.missingSetupOverlay:CreateFontString(nil, "OVERLAY")
  frame.missingSetupOverlay.text:SetPoint("CENTER")
  frame.missingSetupOverlay.text:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
  frame.missingSetupOverlay.text:SetText("Missing Setup")
  frame.missingSetupOverlay.text:SetTextColor(1, 1, 0.2, 1)  -- Yellow text
  
  -- Border textures (4 separate textures for pixel-perfect borders - no centered edge issues)
  -- This approach gives precise control unlike BackdropTemplate which centers edges
  frame.barBorderFrame = CreateFrame("Frame", nil, frame.tickOverlay)
  frame.barBorderFrame:SetAllPoints(frame)
  frame.barBorderFrame:SetFrameLevel(frame:GetFrameLevel() + 23)
  
  frame.barBorderFrame.top = frame.barBorderFrame:CreateTexture(nil, "OVERLAY")
  frame.barBorderFrame.top:SetSnapToPixelGrid(false)
  frame.barBorderFrame.top:SetTexelSnappingBias(0)
  
  frame.barBorderFrame.bottom = frame.barBorderFrame:CreateTexture(nil, "OVERLAY")
  frame.barBorderFrame.bottom:SetSnapToPixelGrid(false)
  frame.barBorderFrame.bottom:SetTexelSnappingBias(0)
  
  frame.barBorderFrame.left = frame.barBorderFrame:CreateTexture(nil, "OVERLAY")
  frame.barBorderFrame.left:SetSnapToPixelGrid(false)
  frame.barBorderFrame.left:SetTexelSnappingBias(0)
  
  frame.barBorderFrame.right = frame.barBorderFrame:CreateTexture(nil, "OVERLAY")
  frame.barBorderFrame.right:SetSnapToPixelGrid(false)
  frame.barBorderFrame.right:SetTexelSnappingBias(0)
  
  frame.barBorderFrame:Hide()  -- Hidden by default
  
  -- Tick marks (on tick overlay frame with OVERLAY layer)
  -- Uses Textures instead of Lines for reliable rendering at all UI scales
  -- (Lines have known thickness/visibility quirks; WA uses the same texture approach)
  frame.tickMarks = {}
  for i = 1, 100 do
    local tick = frame.tickOverlay:CreateTexture(nil, "OVERLAY")
    tick:SetDrawLayer("OVERLAY", 7)  -- High sublevel
    tick:SetSnapToPixelGrid(false)
    tick:SetTexelSnappingBias(0)
    tick:SetColorTexture(0, 0, 0, 1)
    tick:Hide()
    frame.tickMarks[i] = tick
  end
  
  -- Drag functionality + bar selection + right-click to edit
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and not IsShiftKeyDown() then
      local barConfig = ns.API.GetBarConfig(barNumber)
      if barConfig and barConfig.display.barMovable then
        -- Bar is movable - allow dragging
        self:StartMoving()
      else
        -- Bar not movable - select this bar for configuration
        ns.API.SetSelectedBar(barNumber)
      end
    end
  end)
  
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and not IsShiftKeyDown() then
      self:StopMovingOrSizing()
      local barConfig = ns.API.GetBarConfig(barNumber)
      if barConfig then
        -- Always save CENTER-based position for scale-safe anchoring
        -- This ensures scaling doesn't cause position drift
        local centerPos = GetCenterBasedPosition(self)
        if centerPos then
          barConfig.display.barPosition = centerPos
          -- Immediately re-anchor to snapped position so frame doesn't stay at drag-drop location
          self:ClearAllPoints()
          PixelUtil.SetPoint(self, centerPos.point, UIParent, centerPos.relPoint, centerPos.x, centerPos.y)
        else
          -- Fallback if center calculation fails
          local point, _, relPoint, x, y = self:GetPoint()
          barConfig.display.barPosition = {
            point = point,
            relPoint = relPoint,
            x = x,
            y = y
          }
        end
      end
    elseif button == "RightButton" or (button == "LeftButton" and IsShiftKeyDown()) then
      -- Debug: verify barNumber in closure matches frame's stored barNumber
      if ns.devMode then
        print(string.format("|cff00FFFF[ArcUI Debug]|r Bar right-clicked: closure barNumber=%d, frame.barNumber=%s, frame name=%s", 
          barNumber, tostring(self.barNumber), self:GetName() or "unnamed"))
      end
      -- Open options and select this bar
      if ns.Display.OpenOptionsForBar then
        ns.Display.OpenOptionsForBar("buff", barNumber)
      end
    end
  end)
  
  -- Delete button (small red X in corner, only visible when options panel is open)
  frame.deleteButton = CreateFrame("Button", nil, frame)
  frame.deleteButton:SetSize(12, 12)
  frame.deleteButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  -- Must be above tickOverlay (which is at +100) to be visible
  frame.deleteButton:SetFrameLevel(frame:GetFrameLevel() + 150)
  
  frame.deleteButton.text = frame.deleteButton:CreateFontString(nil, "OVERLAY")
  frame.deleteButton.text:SetPoint("CENTER", 0, 0)
  frame.deleteButton.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
  frame.deleteButton.text:SetText("x")
  frame.deleteButton.text:SetTextColor(0.8, 0.2, 0.2, 1)
  
  frame.deleteButton:SetScript("OnEnter", function(self)
    self.text:SetTextColor(1, 0.3, 0.3, 1)
  end)
  
  frame.deleteButton:SetScript("OnLeave", function(self)
    self.text:SetTextColor(0.8, 0.2, 0.2, 1)
  end)
  
  frame.deleteButton:SetScript("OnClick", function(self)
    if ShowDeleteConfirmation then
      ShowDeleteConfirmation(barNumber)
    end
  end)
  
  frame.deleteButton:Hide()  -- Hidden by default, shown when options panel opens
  
  -- When frame is shown, check if delete buttons should be visible
  frame:SetScript("OnShow", function(self)
    if deleteButtonsVisible and self.deleteButton then
      self.deleteButton:Show()
    end
  end)
  
  -- Reposition tick marks AND segment bars when bar resizes (e.g. dynamic container width matching)
  -- UpdateTickMarks alone is not enough — granularBars positions also depend on barFrame width.
  -- Both must recalculate together so ticks and segment edges stay in sync.
  frame:SetScript("OnSizeChanged", function(self, w, h)
    if not w or w <= 0 then return end
    local barNum = self._barNumber or self.barNumber
    if barNum and ns.Display.UpdateBar then
      -- Defer one frame: SetSize fires OnSizeChanged before layout commits,
      -- so GetWidth() inside UpdateBar would still return the old value.
      C_Timer.After(0, function()
        if self and self:IsShown() then
          ns.Display.UpdateBar(barNum)
        end
      end)
    elseif self._tickBarConfig and self._tickMaxValue and ns.Display._UpdateTickMarks then
      C_Timer.After(0, function()
        if self and self:IsShown() then
          ns.Display._UpdateTickMarks(self, self._tickBarConfig, self._tickMaxValue, self._tickDisplayMode)
        end
      end)
    end
  end)
  
  frame:Hide()
  return frame
end

-- ===================================================================
-- CREATE TEXT FRAME FOR SPECIFIC BAR NUMBER
-- ===================================================================
local function CreateTextFrame(barNumber)
  local frame = CreateFrame("Frame", "ArcUITextFrame" .. barNumber, UIParent)
  frame:SetSize(200, 60)
  frame:SetPoint("CENTER", 0, 230 - ((barNumber - 1) * 30))
  frame:SetMovable(true)
  frame:EnableMouse(false)
  frame:SetClampedToScreen(true)
  frame:Hide()  -- Start hidden, UpdateBar will show if appropriate
  
  -- Use MEDIUM strata so we don't overlap Blizzard UI panels (talents, settings, etc.)
  -- Frame level 150 to be above tick overlay (~101) but still in MEDIUM strata
  frame:SetFrameStrata("MEDIUM")
  frame:SetFrameLevel(250)
  
  frame.text = frame:CreateFontString(nil, "OVERLAY")
  frame.text:SetPoint("CENTER")
  frame.text:SetFont("Fonts\\FRIZQT__.TTF", 24, "OUTLINE")
  frame.text:SetText("")
  frame.text:SetTextColor(1, 1, 1, 1)
  frame.text:SetShadowOffset(2, -2)  -- Add shadow like old addon
  frame.text:SetShadowColor(0, 0, 0, 1)
  
  -- Drag functionality
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      self:StartMoving()
    end
  end)
  
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
      self:StopMovingOrSizing()
      local barConfig = ns.API.GetBarConfig(barNumber)
      if barConfig then
        local point, _, relPoint, x, y = self:GetPoint()
        barConfig.display.textPosition = {
          point = point,
          relPoint = relPoint,
          x = x,
          y = y
        }
      end
    elseif button == "RightButton" then
      if ns.Display.OpenOptionsForBar then
        ns.Display.OpenOptionsForBar("buff", barNumber)
      end
    end
  end)
  
  frame:Hide()
  return frame
end

-- ===================================================================
-- CREATE DURATION TEXT FRAME FOR SPECIFIC BAR NUMBER
-- ===================================================================
local function CreateDurationFrame(barNumber)
  local frame = CreateFrame("Frame", "ArcUIDurationFrame" .. barNumber, UIParent)
  frame:SetSize(80, 30)
  frame:SetPoint("CENTER", 0, 200 - ((barNumber - 1) * 30))
  frame:SetMovable(true)
  frame:EnableMouse(false)
  frame:SetClampedToScreen(true)
  frame:Hide()  -- Start hidden, UpdateBar will show if appropriate
  
  -- Use MEDIUM strata so we don't overlap Blizzard UI panels
  -- Frame level 150 to be above tick overlay but still in MEDIUM strata
  frame:SetFrameStrata("MEDIUM")
  frame:SetFrameLevel(250)
  
  frame.text = frame:CreateFontString(nil, "OVERLAY")
  frame.text:SetPoint("CENTER")
  frame.text:SetFont("Fonts\\FRIZQT__.TTF", 18, "OUTLINE")
  frame.text:SetText("")  -- Start empty
  frame.text:SetTextColor(1, 1, 1, 1)
  frame.text:SetShadowOffset(2, -2)
  frame.text:SetShadowColor(0, 0, 0, 1)
  
  -- Drag functionality
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      self:StartMoving()
    end
  end)
  
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
      self:StopMovingOrSizing()
      local barConfig = ns.API.GetBarConfig(barNumber)
      if barConfig then
        local point, _, relPoint, x, y = self:GetPoint()
        barConfig.display.durationPosition = {
          point = point,
          relPoint = relPoint,
          x = x,
          y = y
        }
      end
    elseif button == "RightButton" then
      if ns.Display.OpenOptionsForBar then
        ns.Display.OpenOptionsForBar("buff", barNumber)
      end
    end
  end)
  
  frame:Hide()
  return frame
end

-- ===================================================================
-- CREATE NAME TEXT FRAME FOR SPECIFIC BAR NUMBER (for duration bars)
-- ===================================================================
local function CreateNameFrame(barNumber)
  local frame = CreateFrame("Frame", "ArcUINameFrame" .. barNumber, UIParent)
  frame:SetSize(150, 24)
  frame:SetPoint("CENTER", 0, 220 - ((barNumber - 1) * 30))
  frame:SetMovable(true)
  frame:EnableMouse(false)
  frame:SetClampedToScreen(true)
  frame:Hide()  -- Start hidden, UpdateBar will show if appropriate
  
  -- Use MEDIUM strata so we don't overlap Blizzard UI panels
  -- Frame level 150 to be above tick overlay but still in MEDIUM strata
  frame:SetFrameStrata("MEDIUM")
  frame:SetFrameLevel(250)
  
  frame.text = frame:CreateFontString(nil, "OVERLAY")
  frame.text:SetPoint("CENTER")
  frame.text:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
  frame.text:SetText("")
  frame.text:SetTextColor(1, 1, 1, 1)
  frame.text:SetShadowOffset(1, -1)
  frame.text:SetShadowColor(0, 0, 0, 1)
  
  -- Drag functionality
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      self:StartMoving()
    end
  end)
  
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
      self:StopMovingOrSizing()
      local barConfig = ns.API.GetBarConfig(barNumber)
      if barConfig then
        local point, _, relPoint, x, y = self:GetPoint()
        barConfig.display.namePosition = {
          point = point,
          relPoint = relPoint,
          x = x,
          y = y
        }
      end
    elseif button == "RightButton" then
      if ns.Display.OpenOptionsForBar then
        ns.Display.OpenOptionsForBar("buff", barNumber)
      end
    end
  end)
  
  frame:Hide()
  return frame
end

-- ===================================================================
-- CREATE BAR ICON FRAME FOR SPECIFIC BAR NUMBER (icon alongside bar)
-- ===================================================================
local function CreateBarIconFrame(barNumber)
  local frame = CreateFrame("Frame", "ArcUIBarIconFrame" .. barNumber, UIParent)
  frame:SetSize(32, 32)
  frame:SetPoint("CENTER", 0, 200 - ((barNumber - 1) * 30))
  frame:SetMovable(true)
  frame:EnableMouse(false)
  frame:SetClampedToScreen(true)
  frame:Hide()  -- Start hidden, UpdateBar will show if appropriate
  
  frame:SetFrameStrata("MEDIUM")
  frame:SetFrameLevel(250)
  
  -- Background for border
  frame.background = frame:CreateTexture(nil, "BACKGROUND")
  frame.background:SetPoint("TOPLEFT", frame, "TOPLEFT", -1, 1)
  frame.background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1, -1)
  frame.background:SetColorTexture(0, 0, 0, 1)
  frame.background:SetSnapToPixelGrid(false)
  frame.background:SetTexelSnappingBias(0)
  
  -- Icon texture
  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetAllPoints(frame)
  frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  frame.icon:SetSnapToPixelGrid(false)
  frame.icon:SetTexelSnappingBias(0)
  
  -- Drag functionality
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      self:StartMoving()
    end
  end)
  
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
      self:StopMovingOrSizing()
      local barConfig = ns.API.GetBarConfig(barNumber)
      if barConfig then
        local point, _, relPoint, x, y = self:GetPoint()
        barConfig.display.barIconPosition = {
          point = point,
          relPoint = relPoint,
          x = x,
          y = y
        }
      end
    elseif button == "RightButton" then
      if ns.Display.OpenOptionsForBar then
        ns.Display.OpenOptionsForBar("buff", barNumber)
      end
    end
  end)
  
  frame:Hide()
  return frame
end

-- ===================================================================
-- CREATE ICON FRAME FOR SPECIFIC BAR NUMBER
-- v2.7.0: Added cooldown swipe frame, fixed frame levels, added text caching
-- ===================================================================
local function CreateIconFrame(barNumber)
  local frame = CreateFrame("Frame", "ArcUIIconFrame" .. barNumber, UIParent)
  frame:SetSize(48, 48)
  frame:SetPoint("CENTER", 0, 260 - ((barNumber - 1) * 60))
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:Hide()  -- Start hidden, UpdateBar will show if appropriate
  
  frame:SetFrameStrata("MEDIUM")
  frame:SetFrameLevel(250)
  
  -- Background (behind icon for border effect) - sublevel -8 (lowest in BACKGROUND)
  frame.background = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  frame.background:SetPoint("TOPLEFT", frame, "TOPLEFT", -2, 2)
  frame.background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -2)
  frame.background:SetColorTexture(0, 0, 0, 1)
  frame.background:SetSnapToPixelGrid(false)
  frame.background:SetTexelSnappingBias(0)
  
  -- Icon texture (on top of background) - sublevel -1 in ARTWORK
  frame.icon = frame:CreateTexture(nil, "ARTWORK", nil, -1)
  frame.icon:SetAllPoints(frame)
  frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- Trim default icon borders
  frame.icon:SetSnapToPixelGrid(false)
  frame.icon:SetTexelSnappingBias(0)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- COOLDOWN SWIPE FRAME
  -- Frame level = icon level + 1 (above icon, below text overlays)
  -- ═══════════════════════════════════════════════════════════════════
  frame.cooldown = CreateFrame("Cooldown", "ArcUIIconCooldown" .. barNumber, frame, "CooldownFrameTemplate")
  frame.cooldown:SetAllPoints(frame)
  frame.cooldown:SetFrameLevel(frame:GetFrameLevel() + 1)
  frame.cooldown:SetDrawEdge(true)
  frame.cooldown:SetDrawBling(true)
  frame.cooldown:SetDrawSwipe(true)
  frame.cooldown:SetHideCountdownNumbers(true)  -- We handle our own duration text
  frame.cooldown:SetSwipeColor(0, 0, 0, 0.7)
  frame.cooldown:Hide()  -- Hidden by default
  
  -- TRACKING FAIL OVERLAY - red background with "Tracking Failed" text
  -- Frame level +10 to appear above cooldown swipe
  frame.trackingFailOverlay = CreateFrame("Frame", nil, frame)
  frame.trackingFailOverlay:SetAllPoints(frame)
  frame.trackingFailOverlay:SetFrameStrata("HIGH")
  frame.trackingFailOverlay:SetFrameLevel(frame:GetFrameLevel() + 10)
  frame.trackingFailOverlay:Hide()
  
  frame.trackingFailOverlay.bg = frame.trackingFailOverlay:CreateTexture(nil, "BACKGROUND")
  frame.trackingFailOverlay.bg:SetAllPoints()
  frame.trackingFailOverlay.bg:SetColorTexture(0.6, 0, 0, 0.5)  -- Dark red, semi-transparent
  
  frame.trackingFailOverlay.text = frame.trackingFailOverlay:CreateFontString(nil, "OVERLAY")
  frame.trackingFailOverlay.text:SetPoint("CENTER")
  frame.trackingFailOverlay.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
  frame.trackingFailOverlay.text:SetText("Tracking\nFailed")
  frame.trackingFailOverlay.text:SetTextColor(1, 1, 1, 1)
  frame.trackingFailOverlay.text:SetJustifyH("CENTER")
  
  -- MISSING SETUP OVERLAY - yellow background with "Missing Setup" text
  -- Shows when bar is enabled but no tracking configured
  frame.missingSetupOverlay = CreateFrame("Frame", nil, frame)
  frame.missingSetupOverlay:SetAllPoints(frame)
  frame.missingSetupOverlay:SetFrameStrata("HIGH")
  frame.missingSetupOverlay:SetFrameLevel(frame:GetFrameLevel() + 10)
  frame.missingSetupOverlay:Hide()
  
  frame.missingSetupOverlay.bg = frame.missingSetupOverlay:CreateTexture(nil, "BACKGROUND")
  frame.missingSetupOverlay.bg:SetAllPoints()
  frame.missingSetupOverlay.bg:SetColorTexture(0.6, 0.5, 0, 0.5)  -- Dark yellow, semi-transparent
  
  frame.missingSetupOverlay.text = frame.missingSetupOverlay:CreateFontString(nil, "OVERLAY")
  frame.missingSetupOverlay.text:SetPoint("CENTER")
  frame.missingSetupOverlay.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
  frame.missingSetupOverlay.text:SetText("Missing\nSetup")
  frame.missingSetupOverlay.text:SetTextColor(1, 1, 0.2, 1)  -- Yellow text
  frame.missingSetupOverlay.text:SetJustifyH("CENTER")
  
  -- Stacks text (top right by default) - sublevel 7 (highest in OVERLAY, above cooldown swipe)
  frame.stacks = frame:CreateFontString(nil, "OVERLAY", nil, 7)
  frame.stacks:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
  frame.stacks:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
  frame.stacks:SetText("")
  frame.stacks:SetTextColor(1, 1, 1, 1)
  frame.stacks:SetShadowOffset(1, -1)
  frame.stacks:SetShadowColor(0, 0, 0, 1)
  
  -- Text caching to prevent flickering
  frame.lastStacksText = ""
  frame.lastDurationText = ""
  
  -- Separate movable stacks frame for FREE mode
  -- Frame level +20 to be above everything
  frame.stacksFrame = CreateFrame("Frame", "ArcUIIconStacksFrame" .. barNumber, UIParent)
  frame.stacksFrame:SetSize(40, 24)
  frame.stacksFrame:SetPoint("CENTER", frame, "CENTER", 0, 0)  -- Default: center of icon
  frame.stacksFrame:SetMovable(true)
  frame.stacksFrame:EnableMouse(false)  -- Disabled by default, enabled in icon mode when not locked
  frame.stacksFrame:SetClampedToScreen(true)
  frame.stacksFrame:SetFrameStrata("MEDIUM")
  frame.stacksFrame:SetFrameLevel(frame:GetFrameLevel() + 20)
  
  -- Free stacks text on the movable frame
  frame.stacksFrame.text = frame.stacksFrame:CreateFontString(nil, "OVERLAY", nil, 7)
  frame.stacksFrame.text:SetPoint("CENTER")
  frame.stacksFrame.text:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
  frame.stacksFrame.text:SetText("")
  frame.stacksFrame.text:SetTextColor(1, 1, 1, 1)
  frame.stacksFrame.text:SetShadowOffset(1, -1)
  frame.stacksFrame.text:SetShadowColor(0, 0, 0, 1)
  
  -- Text caching for free stacks frame
  frame.stacksFrame.lastText = ""
  
  -- Drag functionality + right-click to edit (same pattern as bar frames)
  frame.stacksFrame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      self:StartMoving()
    end
  end)
  
  frame.stacksFrame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
      self:StopMovingOrSizing()
      local barConfig = ns.API.GetBarConfig(barNumber)
      if barConfig then
        -- Always save CENTER-based position for scale-safe anchoring
        local centerPos = GetCenterBasedPosition(self)
        if centerPos then
          barConfig.display.iconStackPosition = centerPos
          self:ClearAllPoints()
          PixelUtil.SetPoint(self, centerPos.point, UIParent, centerPos.relPoint, centerPos.x, centerPos.y)
        else
          local point, _, relPoint, x, y = self:GetPoint()
          barConfig.display.iconStackPosition = {
            point = point,
            relPoint = relPoint,
            x = x,
            y = y
          }
        end
      end
    elseif button == "RightButton" then
      -- Open options and select this bar
      if ns.Display.OpenOptionsForBar then
        ns.Display.OpenOptionsForBar("buff", barNumber)
      end
    end
  end)
  
  frame.stacksFrame:Hide()
  
  -- Duration text (center) - sublevel 7 (highest in OVERLAY)
  frame.duration = frame:CreateFontString(nil, "OVERLAY", nil, 7)
  frame.duration:SetPoint("CENTER", frame, "CENTER", 0, 0)
  frame.duration:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
  frame.duration:SetText("")
  frame.duration:SetTextColor(1, 1, 1, 1)
  frame.duration:SetShadowOffset(1, -1)
  frame.duration:SetShadowColor(0, 0, 0, 1)
  
  -- Delete button (small red X in corner, only visible when options panel is open)
  -- Frame level +50 to be above everything
  frame.deleteButton = CreateFrame("Button", nil, frame)
  frame.deleteButton:SetSize(12, 12)
  frame.deleteButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  frame.deleteButton:SetFrameLevel(frame:GetFrameLevel() + 50)
  
  frame.deleteButton.text = frame.deleteButton:CreateFontString(nil, "OVERLAY")
  frame.deleteButton.text:SetPoint("CENTER", 0, 0)
  frame.deleteButton.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
  frame.deleteButton.text:SetText("x")
  frame.deleteButton.text:SetTextColor(0.8, 0.2, 0.2, 1)
  
  frame.deleteButton:SetScript("OnEnter", function(self)
    self.text:SetTextColor(1, 0.3, 0.3, 1)
  end)
  
  frame.deleteButton:SetScript("OnLeave", function(self)
    self.text:SetTextColor(0.8, 0.2, 0.2, 1)
  end)
  
  frame.deleteButton:SetScript("OnClick", function(self)
    if ShowDeleteConfirmation then
      ShowDeleteConfirmation(barNumber)
    end
  end)
  
  frame.deleteButton:Hide()  -- Hidden by default, shown when options panel opens
  
  -- When frame is shown, check if delete buttons should be visible
  frame:SetScript("OnShow", function(self)
    if deleteButtonsVisible and self.deleteButton then
      self.deleteButton:Show()
    end
  end)
  
  -- Drag functionality and click-to-edit
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and not IsShiftKeyDown() then
      self:StartMoving()
    end
  end)
  
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and not IsShiftKeyDown() then
      self:StopMovingOrSizing()
      local barConfig = ns.API.GetBarConfig(barNumber)
      if barConfig then
        -- Always save CENTER-based position for scale-safe anchoring
        local centerPos = GetCenterBasedPosition(self)
        if centerPos then
          barConfig.display.iconPosition = centerPos
          self:ClearAllPoints()
          PixelUtil.SetPoint(self, centerPos.point, UIParent, centerPos.relPoint, centerPos.x, centerPos.y)
        else
          local point, _, relPoint, x, y = self:GetPoint()
          barConfig.display.iconPosition = {
            point = point,
            relPoint = relPoint,
            x = x,
            y = y
          }
        end
      end
    elseif button == "RightButton" or (button == "LeftButton" and IsShiftKeyDown()) then
      -- Debug: verify barNumber in closure
      if ns.devMode then
        print(string.format("|cff00FFFF[ArcUI Debug]|r Icon right-clicked: closure barNumber=%d, frame name=%s", 
          barNumber, self:GetName() or "unnamed"))
      end
      -- Open options and select this bar
      if ns.Display.OpenOptionsForBar then
        ns.Display.OpenOptionsForBar("buff", barNumber)
      end
    end
  end)
  
  frame:Hide()
  return frame
end

-- ===================================================================
-- CREATE MULTI-ICON FRAME (StatusBar-based icon for each stack)
-- Each "icon" is a StatusBar where fill texture = buff icon
-- SetMinMaxValues(stackNum-1, stackNum) so it fills when stacks >= stackNum
-- ===================================================================
local function CreateMultiIconFrame(barNumber, stackNum)
  local frameName = "ArcUIMultiIcon" .. barNumber .. "_" .. stackNum
  local frame = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
  frame:SetSize(48, 48)
  frame:SetPoint("CENTER", UIParent, "CENTER", (stackNum - 1) * 52, 0)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:SetFrameStrata("MEDIUM")
  frame:SetFrameLevel(100 + stackNum)
  frame:Hide()  -- Start hidden, UpdateBar will show if appropriate
  
  -- Solid color background (behind desaturated icon)
  frame.solidBg = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
  frame.solidBg:SetAllPoints()
  frame.solidBg:SetColorTexture(0.05, 0.05, 0.05, 0.9)
  frame.solidBg:SetSnapToPixelGrid(false)
  frame.solidBg:SetTexelSnappingBias(0)
  
  -- Desaturated icon background (shows when stack not filled)
  frame.desatBg = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
  frame.desatBg:SetAllPoints()
  frame.desatBg:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
  frame.desatBg:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  frame.desatBg:SetDesaturated(true)
  frame.desatBg:SetVertexColor(0.4, 0.4, 0.4, 1)  -- Darken the desaturated icon
  frame.desatBg:SetSnapToPixelGrid(false)
  frame.desatBg:SetTexelSnappingBias(0)
  
  -- StatusBar that acts as the icon fill
  -- When stacks >= stackNum, this bar will be full (showing the icon)
  -- When stacks < stackNum, this bar will be empty (showing desaturated background)
  frame.iconBar = CreateFrame("StatusBar", frameName .. "Bar", frame)
  frame.iconBar:SetAllPoints()
  frame.iconBar:SetMinMaxValues(stackNum - 1, stackNum)
  frame.iconBar:SetValue(0)
  frame.iconBar:SetOrientation("HORIZONTAL")  -- Changed from VERTICAL - HORIZONTAL works!
  -- Note: SetRotatesTexture not needed for icon bars
  
  -- The icon texture as the fill - DON'T use SetTexCoord on StatusBar texture
  frame.iconBar:SetStatusBarTexture("Interface\\Icons\\INV_Misc_QuestionMark")
  frame.iconBar:SetStatusBarColor(1, 1, 1, 1)  -- Ensure white color
  
  -- Prevent pixel snapping on StatusBar texture
  local iconBarTex = frame.iconBar:GetStatusBarTexture()
  if iconBarTex then
    iconBarTex:SetSnapToPixelGrid(false)
    iconBarTex:SetTexelSnappingBias(0)
  end
  
  -- Track what texture is currently set (to avoid re-setting during combat)
  frame.currentTextureID = nil
  
  -- Border frame (separate so it's on top)
  frame.borderFrame = CreateFrame("Frame", nil, frame)
  frame.borderFrame:SetAllPoints()
  frame.borderFrame:SetFrameLevel(frame:GetFrameLevel() + 5)
  
  frame.border = frame.borderFrame:CreateTexture(nil, "OVERLAY")
  frame.border:SetPoint("TOPLEFT", frame, "TOPLEFT", -1, 1)
  frame.border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1, -1)
  frame.border:SetSnapToPixelGrid(false)
  frame.border:SetTexelSnappingBias(0)
  frame.border:SetColorTexture(0, 0, 0, 1)
  frame.border:SetDrawLayer("OVERLAY", -1)
  
  -- Duration text (only shown on one of the icons based on config)
  frame.duration = frame.borderFrame:CreateFontString(nil, "OVERLAY")
  frame.duration:SetPoint("BOTTOM", frame, "BOTTOM", 0, 2)
  frame.duration:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
  frame.duration:SetText("")
  frame.duration:SetTextColor(1, 1, 1, 1)
  frame.duration:Hide()
  
  -- Drag handlers + right-click to edit (same pattern as bar frames)
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      -- Always allow drag for multi-icon frames (same as aura bars)
      self:StartMoving()
    end
  end)
  
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
      self:StopMovingOrSizing()
      -- Save position
      local barConfig = ns.API.GetBarConfig(barNumber)
      if barConfig then
        -- Always save CENTER-based position for scale-safe anchoring
        local centerPos = GetCenterBasedPosition(self)
        if not barConfig.display.iconMultiPositions then
          barConfig.display.iconMultiPositions = {}
        end
        if centerPos then
          barConfig.display.iconMultiPositions[stackNum] = centerPos
          self:ClearAllPoints()
          PixelUtil.SetPoint(self, centerPos.point, UIParent, centerPos.relPoint, centerPos.x, centerPos.y)
        else
          local point, _, relPoint, x, y = self:GetPoint()
          barConfig.display.iconMultiPositions[stackNum] = {
            point = point,
            relPoint = relPoint,
            x = x,
            y = y
          }
        end
      end
    elseif button == "RightButton" then
      -- Open options and select this bar
      if ns.Display.OpenOptionsForBar then
        ns.Display.OpenOptionsForBar("buff", barNumber)
      end
    end
  end)
  
  frame.stackNum = stackNum
  frame.barNumber = barNumber
  frame:Hide()
  return frame
end

-- Storage for multi-icon frames: multiIconFrames[barNumber][stackNum] = frame
local multiIconFrames = {}

-- Get or create multi-icon frames for a bar
local function GetMultiIconFrames(barNumber, maxStacks)
  if not multiIconFrames[barNumber] then
    multiIconFrames[barNumber] = {}
  end
  
  -- Create frames for each stack position
  for i = 1, maxStacks do
    if not multiIconFrames[barNumber][i] then
      multiIconFrames[barNumber][i] = CreateMultiIconFrame(barNumber, i)
    end
  end
  
  return multiIconFrames[barNumber]
end

-- Hide all multi-icon frames for a bar
local function HideMultiIconFrames(barNumber)
  if multiIconFrames[barNumber] then
    for i, frame in pairs(multiIconFrames[barNumber]) do
      SafeHide(frame)
    end
  end
end

-- ===================================================================
-- GET OR CREATE FRAMES FOR BAR
-- ===================================================================
local function GetBarFrames(barNumber)
  if not barFrames[barNumber] then
    barFrames[barNumber] = {
      barFrame = CreateBarFrame(barNumber),
      textFrame = CreateTextFrame(barNumber),
      durationFrame = CreateDurationFrame(barNumber),
      iconFrame = CreateIconFrame(barNumber),
      nameFrame = CreateNameFrame(barNumber),
      barIconFrame = CreateBarIconFrame(barNumber)
    }
  end
  -- Create missing frames for existing bars
  if not barFrames[barNumber].durationFrame then
    barFrames[barNumber].durationFrame = CreateDurationFrame(barNumber)
  end
  if not barFrames[barNumber].iconFrame then
    barFrames[barNumber].iconFrame = CreateIconFrame(barNumber)
  end
  if not barFrames[barNumber].nameFrame then
    barFrames[barNumber].nameFrame = CreateNameFrame(barNumber)
  end
  if not barFrames[barNumber].barIconFrame then
    barFrames[barNumber].barIconFrame = CreateBarIconFrame(barNumber)
  end
  return barFrames[barNumber].barFrame, barFrames[barNumber].textFrame, barFrames[barNumber].durationFrame, barFrames[barNumber].iconFrame, barFrames[barNumber].nameFrame, barFrames[barNumber].barIconFrame
end

-- ===================================================================
-- CUSTOM TRACKING SMOOTH UPDATE SYSTEM
-- Smooth animation support:
-- full control over the duration values (not secret values from CDM)
-- ===================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- DEACTIVATION: Zero-CPU bars hidden by spec/talent conditions
-- When deactivated, the smooth OnUpdate loop skips the bar entirely
-- and all per-frame OnUpdate scripts are cleared.
-- ═══════════════════════════════════════════════════════════════════════════
local function DeactivateBar(barNumber)
  local frames = barFrames[barNumber]
  if frames then
    if frames.barFrame and frames.barFrame.bar then
      frames.barFrame.bar:SetScript("OnUpdate", nil)
    end
    if frames.iconFrame then
      frames.iconFrame:SetScript("OnUpdate", nil)
    end
    if frames.durationFrame then
      frames.durationFrame:SetScript("OnUpdate", nil)
    end
    SafeHide(frames.barFrame)
    SafeHide(frames.textFrame)
    SafeHide(frames.durationFrame)
    SafeHide(frames.iconFrame)
    SafeHide(frames.nameFrame)
    SafeHide(frames.barIconFrame)
    HideMultiIconFrames(barNumber)
  end
end

local function ReactivateBar(barNumber)
  -- No-op: deactivation is handled by frame visibility
end


local smoothUpdateFrame = CreateFrame("Frame")
local SMOOTH_UPDATE_INTERVAL = 0.03  -- ~30fps for smooth animation
local smoothUpdateElapsed = 0

smoothUpdateFrame:SetScript("OnUpdate", function(self, elapsed)
  smoothUpdateElapsed = smoothUpdateElapsed + elapsed
  if smoothUpdateElapsed < SMOOTH_UPDATE_INTERVAL then return end
  smoothUpdateElapsed = 0
  
  -- Skip updates when preview mode is active (prevents flickering)
  if previewMode and IsOptionsOpen() then return end
  
  local currentTime = GetTime()
  

end)

-- ===================================================================
-- SHARED: UPDATE TICK MARKS FOR A BAR
-- Called by UpdateBar and UpdateDurationBar to update tick marks
-- ===================================================================
local function UpdateTickMarks(barFrame, barConfig, maxValue, displayMode)
  if not barFrame or not barConfig then return end

  -- Cache parameters on the frame so OnSizeChanged can re-call us
  barFrame._tickBarConfig = barConfig
  barFrame._tickMaxValue = maxValue
  barFrame._tickDisplayMode = displayMode

  local isVertical   = (barConfig.display.barOrientation == "vertical")
  local isReverseFill = barConfig.display.barReverseFill or false

  -- Hide legacy _arcGranularTicks (superseded by unified tickMarks)
  if barFrame._arcGranularTicks then
    for i = 1, 100 do
      if barFrame._arcGranularTicks[i] then barFrame._arcGranularTicks[i]:Hide()
      else break end
    end
  end

  if barConfig.display.showTickMarks and maxValue > 1 then
    local tickMode        = barConfig.display.tickMode or "percent"
    local abilityThresholds = barConfig.abilityThresholds
    local tc              = barConfig.display.tickColor or {r=0, g=0, b=0, a=1}
    local thickness       = barConfig.display.tickThickness or 2

    -- Duration mode: only force "all" → "percent" when maxValue exceeds the tick
    -- pool (100 slots). For short bars (≤ 100s) "all" gives one tick per second
    -- which aligns with integer values — forcing to percent causes misalignment.
    if displayMode == "duration" and tickMode == "all" and maxValue > 100 then
      tickMode = "percent"
    end

    -- Folded mode: ticks span only the first half (midpoint = max)
    local tickMaxValue = maxValue
    if displayMode == "folded" then tickMaxValue = math_ceil(maxValue / 2) end

    -- ── Build tick position list ─────────────────────────────────
    local tickPositions = {}
    if tickMode == "all" then
      for i = 1, tickMaxValue - 1 do table.insert(tickPositions, i) end
    elseif tickMode == "percent" then
      local tickPercent = barConfig.display.tickPercent or 10
      local numTicks = math_floor(100 / tickPercent)
      for i = 1, numTicks - 1 do
        local tickVal = tickMaxValue * (i * tickPercent / 100)
        if tickVal > 0 and tickVal < tickMaxValue then table.insert(tickPositions, tickVal) end
      end
    elseif tickMode == "custom" and abilityThresholds and #abilityThresholds > 0 then
      local usePercent = barConfig.display.customTicksAsPercent
      for _, tick in ipairs(abilityThresholds) do
        if tick.enabled and tick.cost and tick.cost > 0 then
          local tickVal = tick.cost
          if usePercent then tickVal = tickMaxValue * tick.cost / 100 end
          if tickVal > 0 and tickVal < tickMaxValue then table.insert(tickPositions, tickVal) end
        end
      end
    end

    -- ── Shared sizing ────────────────────────────────────────────
    local segInset = 0
    if barConfig.display.showBorder and (displayMode == "granular" or displayMode == "perStack") then
      local btRaw = barConfig.display.drawnBorderThickness or 2
      local _s1 = barFrame:GetEffectiveScale()
      local _, _h1 = GetPhysicalScreenSize()
      local _onePx1 = (_h1 and _h1 > 0 and _s1 and _s1 > 0) and (768 / _h1) / _s1 or 1
      segInset = _onePx1 * btRaw
    end
    local tickTotalSize = isVertical and barFrame:GetHeight() or barFrame:GetWidth()
    local tickInsetSize = tickTotalSize - 2 * segInset
    local scale         = barFrame:GetEffectiveScale()

    local tickHeightPct  = barConfig.display.tickHeightPercent or 100
    local heightAnchor   = barConfig.display.tickHeightAnchor  or "center"
    local thicknessAnchor = barConfig.display.tickThicknessAnchor or "center"
    local barCrossSize   = isVertical and barFrame:GetWidth() or barFrame:GetHeight()
    local borderInset    = 0
    if barConfig.display.showBorder and (displayMode == "granular" or displayMode == "perStack") then
      local btRawCross = barConfig.display.drawnBorderThickness or 0
      -- Use same exact-pixel formula as segInset so tick span matches fill area exactly
      local _sc = barFrame:GetEffectiveScale()
      local _, _hc = GetPhysicalScreenSize()
      local _onePxC = (_hc and _hc > 0 and _sc and _sc > 0) and (768 / _hc) / _sc or 1
      borderInset = _onePxC * btRawCross
    end
    local availCross     = math.max(1, barCrossSize - 2 * borderInset)

    -- ── Draw ticks ───────────────────────────────────────────────
    local tickIndex = 1
    for _, tickValue in ipairs(tickPositions) do
      if barFrame.tickMarks and barFrame.tickMarks[tickIndex] then
        local tick = barFrame.tickMarks[tickIndex]
        local _, _ht = GetPhysicalScreenSize()
        local _onePxT = (_ht and _ht > 0 and scale and scale > 0) and (768 / _ht) / scale or 1
        local pixelThickness = _onePxT * thickness
        local halfThick  = pixelThickness / 2
        local tickSpan   = availCross * (tickHeightPct / 100)

        tick:ClearAllPoints()
        tick:SetColorTexture(tc.r, tc.g, tc.b, tc.a or 1)

        -- ── Position along bar axis ──────────────────────────────
        -- GRANULAR: bar[i] is stretched from 0 to i/max*total — its width IS the
        -- cumulative right-edge position. Read it back to get the exact committed pixel.
        -- PERSTACK: bar[i] is a fixed-width segment at offset (i-1)/max*total — its
        -- width is just one segment. Use math instead (PixelSnap matches how segments
        -- are positioned in the perStack loop).
        -- SIMPLE/FOLDED/DURATION: raw float fill, match with raw float math.
        local intVal     = math.floor(tickValue)
        local granularBar = displayMode == "granular"
          and barFrame.granularBars and barFrame.granularBars[intVal]

        local rawPos
        if granularBar then
          rawPos = (isVertical and granularBar:GetHeight() or granularBar:GetWidth())
        elseif displayMode == "perStack" then
          -- Match the exact formula used in the perStack segment loop:
          -- integer pixel boundaries via math_floor (not nearest-round) so ticks
          -- land on the same physical pixel as the segment edge they mark.
          local _, _h = GetPhysicalScreenSize()
          local _pmult = (_h and _h > 0 and scale and scale > 0) and (768 / _h) / scale or 1
          local _totalPx = math_floor(tickInsetSize / _pmult + 0.5)
          rawPos = segInset + math_floor(tickValue / tickMaxValue * _totalPx) * _pmult
        else
          rawPos = segInset + tickValue / tickMaxValue * tickInsetSize
        end

        -- Thickness anchor: nudge tick so its centre/end aligns with rawPos
        local posAlong = rawPos
        if thicknessAnchor == "center" then
          posAlong = rawPos - halfThick
        elseif thicknessAnchor == "end" then
          posAlong = rawPos - pixelThickness
        end

        if isVertical then
          tick:SetSize(tickSpan, pixelThickness)
          if heightAnchor == "top" then
            tick:SetPoint(isReverseFill and "TOPLEFT"    or "BOTTOMLEFT",  barFrame.tickOverlay, isReverseFill and "TOPLEFT"    or "BOTTOMLEFT",  0, isReverseFill and -posAlong or posAlong)
          elseif heightAnchor == "bottom" then
            tick:SetPoint(isReverseFill and "TOPRIGHT"   or "BOTTOMRIGHT", barFrame.tickOverlay, isReverseFill and "TOPRIGHT"   or "BOTTOMRIGHT", 0, isReverseFill and -posAlong or posAlong)
          else
            tick:SetPoint(isReverseFill and "TOP"        or "BOTTOM",      barFrame.tickOverlay, isReverseFill and "TOP"        or "BOTTOM",      0, isReverseFill and -posAlong or posAlong)
          end
        else
          tick:SetSize(pixelThickness, tickSpan)
          if heightAnchor == "top" then
            tick:SetPoint(isReverseFill and "TOPRIGHT"    or "TOPLEFT",    barFrame.tickOverlay, isReverseFill and "TOPRIGHT"    or "TOPLEFT",    isReverseFill and -posAlong or posAlong, 0)
          elseif heightAnchor == "bottom" then
            tick:SetPoint(isReverseFill and "BOTTOMRIGHT" or "BOTTOMLEFT", barFrame.tickOverlay, isReverseFill and "BOTTOMRIGHT" or "BOTTOMLEFT", isReverseFill and -posAlong or posAlong, 0)
          else
            tick:SetPoint(isReverseFill and "RIGHT"       or "LEFT",       barFrame.tickOverlay, isReverseFill and "RIGHT"       or "LEFT",       isReverseFill and -posAlong or posAlong, 0)
          end
        end

        tick:Show()
        tickIndex = tickIndex + 1
      end
    end

    -- Hide unused tick slots
    if barFrame.tickMarks then
      for i = tickIndex, 100 do
        if barFrame.tickMarks[i] then barFrame.tickMarks[i]:Hide() end
      end
    end
  else
    -- Ticks disabled or maxValue <= 1 — hide everything
    if barFrame.tickMarks then
      for i = 1, 100 do
        if barFrame.tickMarks[i] then barFrame.tickMarks[i]:Hide() end
      end
    end
  end
end

-- Expose for barFrame OnSizeChanged hook (defined in CreateBarFrame above)
ns.Display._UpdateTickMarks = UpdateTickMarks

-- ===================================================================
-- UPDATE SPECIFIC BAR
-- ===================================================================
function ns.Display.UpdateBar(barNumber, stacks, maxStacks, active, durationFontString, iconTexture, auraName, cachedConfig)
  -- PROFILER: Track where time is spent
  local PM = ns.ProfilerMark
  if PM then PM("GetBarConfig") end

  local barConfig = cachedConfig or ns.API.GetBarConfig(barNumber)
  if not barConfig or not barConfig.tracking or not barConfig.tracking.enabled then
    -- Bar not configured - hide it (but don't create frames!)
    if barFrames[barNumber] then
      SafeHide(barFrames[barNumber].barFrame)
      SafeHide(barFrames[barNumber].textFrame)
      SafeHide(barFrames[barNumber].durationFrame)
      SafeHide(barFrames[barNumber].iconFrame)
      SafeHide(barFrames[barNumber].nameFrame)
      SafeHide(barFrames[barNumber].barIconFrame)
      -- Also hide multi-icon frames
      HideMultiIconFrames(barNumber)
    end
    return
  end
  
  -- FLICKERING FIX: Skip real tracking updates when preview mode is active
  -- When previewMode is on, only allow updates from SetPreviewStacks (no durationFontString)
  if previewMode and IsOptionsOpen() and durationFontString then
    return  -- Skip real tracking update, let preview control the display
  end
  
  if PM then PM("VisibilityChecks") end
  
  -- ═══════════════════════════════════════════════════════════════════════════
  -- PERFORMANCE: Cache expensive lookups ONCE at start of function
  -- ═══════════════════════════════════════════════════════════════════════════
  local optionsOpen = IsOptionsOpen()
  local currentSpec = GetCachedSpec()
  
  -- ═══════════════════════════════════════════════════════════════════════════
  -- INITIALIZATION CHECK: Keep bars hidden until init complete (prevents flash on reload)
  -- ═══════════════════════════════════════════════════════════════════════════
  if not initializationComplete and not optionsOpen then
    if barFrames[barNumber] then
      SafeHide(barFrames[barNumber].barFrame)
      SafeHide(barFrames[barNumber].textFrame)
      SafeHide(barFrames[barNumber].durationFrame)
      SafeHide(barFrames[barNumber].iconFrame)
      SafeHide(barFrames[barNumber].nameFrame)
      SafeHide(barFrames[barNumber].barIconFrame)
      HideMultiIconFrames(barNumber)
    end
    return
  end
  
  -- ═══════════════════════════════════════════════════════════════════════════
  -- EARLY VISIBILITY CHECK: Skip all work if bar shouldn't be visible
  -- ═══════════════════════════════════════════════════════════════════════════
  local shouldShow = true
  local deactivate = false  -- Track if hidden by semi-permanent condition (spec/talent)
  
  -- Spec check
  if barConfig.behavior and barConfig.behavior.showOnSpecs and #barConfig.behavior.showOnSpecs > 0 then
    shouldShow = false
    for _, spec in ipairs(barConfig.behavior.showOnSpecs) do
      if spec == currentSpec then
        shouldShow = true
        break
      end
    end
    if not shouldShow then deactivate = true end
  end
  
  -- Talent conditions check
  if shouldShow and ns.TrackingOptions and ns.TrackingOptions.AreTalentConditionsMet then
    if not ns.TrackingOptions.AreTalentConditionsMet(barConfig) then
      shouldShow = false
      deactivate = true
    end
  end
  
  -- Hide When conditions check (uses CDMGroups state via shared evaluator)
  local hideWhenFadeAlpha = 1.0
  if shouldShow and not optionsOpen and ns.CooldownBars and ns.CooldownBars.GetHideWhen then
    local hideWhen = ns.CooldownBars.GetHideWhen(barConfig)
    if hideWhen and ns.CooldownBars.EvaluateHideConditions(hideWhen, barConfig.behavior and barConfig.behavior.hideLogic) then
      local hAlpha = ns.CooldownBars.GetHideWhenAlpha(barConfig)
      if hAlpha <= 0 then
        shouldShow = false
      else
        hideWhenFadeAlpha = hAlpha
      end
    end
  end
  if barFrames[barNumber] then barFrames[barNumber]._arcHideWhenAlpha = hideWhenFadeAlpha end
  
  -- Inactive check — defer hide by 2 frames to prevent flicker on quick buff refresh
  if shouldShow and not optionsOpen and not active and barConfig.behavior and barConfig.behavior.hideWhenInactive then
    local frames = barFrames[barNumber]
    if frames then
      if not frames._arcHideWhenInactivePending then
        frames._arcHideWhenInactivePending = true
        C_Timer.After(0.1, function()  -- ~6 frames at 60fps, covers quick buff refresh window
          if frames._arcHideWhenInactivePending then
            frames._arcHideWhenInactivePending = nil
            -- Only hide if still inactive
            local state = ns.API and ns.API.GetBarState and ns.API.GetBarState(barNumber)
            if state and not state.active then
              SafeHide(frames.barFrame)
              SafeHide(frames.textFrame)
              SafeHide(frames.durationFrame)
              SafeHide(frames.iconFrame)
              SafeHide(frames.nameFrame)
              SafeHide(frames.barIconFrame)
              HideMultiIconFrames(barNumber)
            end
          end
        end)
      end
    end
    shouldShow = false
  else
    -- Cancel any pending hide if bar became active again
    local frames = barFrames[barNumber]
    if frames then frames._arcHideWhenInactivePending = nil end
  end
  
  -- Early exit if bar shouldn't show and options not open
  if not shouldShow and not optionsOpen then
    if deactivate then
      DeactivateBar(barNumber)
    else
      if barFrames[barNumber] then
        SafeHide(barFrames[barNumber].barFrame)
        SafeHide(barFrames[barNumber].textFrame)
        SafeHide(barFrames[barNumber].durationFrame)
        SafeHide(barFrames[barNumber].iconFrame)
        SafeHide(barFrames[barNumber].nameFrame)
        SafeHide(barFrames[barNumber].barIconFrame)
        HideMultiIconFrames(barNumber)
      end
    end
    return
  end
  
  -- Bar is active — ensure it's not flagged as deactivated
  ReactivateBar(barNumber)
  
  -- Get values from config if not provided
  maxStacks = tonumber(maxStacks) or tonumber(barConfig.tracking.maxStacks) or 10
  if maxStacks < 1 then maxStacks = 10 end
  stacks = stacks or 0
  
  local barFrame, textFrame, durationFrame, iconFrame, nameFrame, barIconFrame = GetBarFrames(barNumber)
  local displayType = barConfig.display.displayType or "bar"
  
  if PM then PM("GetBarFrames") end
  
  -- Config validation and overlay logic (only matters when options open)
  if optionsOpen then
    -- Check tracking status
    local trackingOK = ns.API.IsTrackingOK and ns.API.IsTrackingOK(barNumber)
    local showFailOverlay = not trackingOK and barConfig.tracking.cooldownID and barConfig.tracking.cooldownID > 0
    
    if showFailOverlay then
      if displayType == "icon" then
        local cfg = barConfig.display
        if cfg.iconMultiMode then
          barFrame:Hide()
          textFrame:Hide()
          durationFrame:Hide()
          iconFrame:Hide()
          if iconFrame.trackingFailOverlay then
            iconFrame.trackingFailOverlay:Hide()
          end
          if iconFrame.stacksFrame then iconFrame.stacksFrame:Hide() end
          if nameFrame then nameFrame:Hide() end
          if barIconFrame then barIconFrame:Hide() end
          
          local multiFrames = GetMultiIconFrames(barNumber, maxStacks)
          for i = 1, maxStacks do
            local mFrame = multiFrames[i]
            if mFrame then
              mFrame:Show()
              mFrame.iconBar:SetValue(0)
            end
          end
          return
        else
          barFrame:Hide()
          textFrame:Hide()
          durationFrame:Hide()
          if nameFrame then nameFrame:Hide() end
          if barIconFrame then barIconFrame:Hide() end
          
          iconFrame:Show()
          if iconFrame.trackingFailOverlay then
            iconFrame.trackingFailOverlay:Show()
          end
          if iconFrame.stacksFrame then iconFrame.stacksFrame:Hide() end
          iconFrame.stacks:Hide()
        end
      else
        iconFrame:Hide()
        if iconFrame.stacksFrame then iconFrame.stacksFrame:Hide() end
        HideMultiIconFrames(barNumber)
        textFrame:Hide()
        durationFrame:Hide()
        if nameFrame then nameFrame:Hide() end
        if barIconFrame then barIconFrame:Hide() end
        
        barFrame:Show()
        if barFrame.trackingFailOverlay then
          barFrame.trackingFailOverlay:Show()
        end
      end
      return
    end
    
    -- Check if properly configured
    local tracking = barConfig.tracking
    local hasSpellIdentification = (tracking.spellID and tracking.spellID > 0) or 
                                    (tracking.cooldownID and tracking.cooldownID > 0) or 
                                    (tracking.buffName and tracking.buffName ~= "")
    local hasTrackType = tracking.trackType and tracking.trackType ~= "" and tracking.trackType ~= "none"
    local isProperlyConfigured = hasSpellIdentification and hasTrackType
    
    if not isProperlyConfigured then
      if displayType == "icon" then
        barFrame:Hide()
        textFrame:Hide()
        if durationFrame then durationFrame:Hide() end
        if nameFrame then nameFrame:Hide() end
        if barIconFrame then barIconFrame:Hide() end
        HideMultiIconFrames(barNumber)
        
        iconFrame:Show()
        if iconFrame.missingSetupOverlay then
          iconFrame.missingSetupOverlay:Show()
        end
        if iconFrame.trackingFailOverlay then iconFrame.trackingFailOverlay:Hide() end
        if iconFrame.stacksFrame then iconFrame.stacksFrame:Hide() end
        iconFrame.stacks:Hide()
      else
        iconFrame:Hide()
        if iconFrame.stacksFrame then iconFrame.stacksFrame:Hide() end
        HideMultiIconFrames(barNumber)
        textFrame:Hide()
        if durationFrame then durationFrame:Hide() end
        if nameFrame then nameFrame:Hide() end
        if barIconFrame then barIconFrame:Hide() end
        
        barFrame:Show()
        if barFrame.missingSetupOverlay then
          barFrame.missingSetupOverlay:Show()
        end
        if barFrame.trackingFailOverlay then barFrame.trackingFailOverlay:Hide() end
      end
      return
    end
  end
  
  -- Hide overlays when not needed (use SafeHide to avoid redundant calls)
  SafeHide(barFrame.trackingFailOverlay)
  if iconFrame then SafeHide(iconFrame.trackingFailOverlay) end
  SafeHide(barFrame.missingSetupOverlay)
  if iconFrame then SafeHide(iconFrame.missingSetupOverlay) end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- ICON MODE
  -- ═══════════════════════════════════════════════════════════════════
  if displayType == "icon" then
    local cfg = barConfig.display
    
    -- Always hide single iconFrame when multi-icon mode is enabled
    if cfg.iconMultiMode then
      SafeHide(iconFrame)
      SafeHide(iconFrame.stacksFrame)
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- MULTI-ICON MODE - Show separate icon for each stack
    -- ═══════════════════════════════════════════════════════════════════
    if cfg.iconMultiMode then
      -- Hide regular display elements
      SafeHide(barFrame)
      SafeHide(textFrame)
      SafeHide(durationFrame)
      SafeHide(iconFrame)
      SafeHide(iconFrame.stacksFrame)
      SafeHide(nameFrame)
      SafeHide(barIconFrame)
      
      -- Get the icon texture from CACHED config value only
      -- This was saved out of combat when tracking was set up
      -- Do NOT call GetTexture() or GetSpellTexture() here - they return secret values in combat
      local iconTex = barConfig.tracking.iconTextureID or "Interface\\Icons\\INV_Misc_QuestionMark"
      
      -- Get or create multi-icon frames
      local multiFrames = GetMultiIconFrames(barNumber, maxStacks)
      
      -- Get positioning settings
      local spacing = cfg.iconMultiSpacing or 4
      local direction = cfg.iconMultiDirection or "RIGHT"
      local iconSize = cfg.iconSize or 48
      local showDurationOn = cfg.iconMultiShowDurationOn or 1  -- 0=none, 1=first, 2-10=first N, -1=last
      local durationFontSize = cfg.iconDurationFontSize or 12
      local dc = cfg.iconDurationColor or {r=1, g=1, b=1, a=1}
      local freeMode = cfg.iconMultiFreeMode  -- Free positioning mode
      
      -- ═══════════════════════════════════════════════════════════════════
      -- STACK COUNT DETECTION using CDM FontString secret value trick
      -- If issecretvalue(stackText) returns true, we have 2+ stacks
      -- If it returns false, we have 0-1 stacks
      -- ═══════════════════════════════════════════════════════════════════
      local detectedMultipleStacks = false
      local trackedCooldownID = barConfig.tracking.cooldownID
      
      if trackedCooldownID then
        -- Cache CDM icon lookup on barFrame (cooldownID doesn't change during combat)
        local cdmIcon = barFrame._cachedCdmIcon
        if not cdmIcon or (cdmIcon ~= false and cdmIcon.cooldownID ~= trackedCooldownID) then
          cdmIcon = nil
          -- Try FindFrameByCooldownID if available (avoids GetChildren scan)
          if ns.CDMEnhance and ns.CDMEnhance.FindFrameByCooldownID then
            cdmIcon = ns.CDMEnhance.FindFrameByCooldownID(trackedCooldownID)
          end
          if not cdmIcon then
            local viewer = _G["BuffIconCooldownViewer"]
            if viewer then
              for _, child in pairs({viewer:GetChildren()}) do
                if child.cooldownID == trackedCooldownID then
                  cdmIcon = child
                  break
                end
              end
            end
          end
          barFrame._cachedCdmIcon = cdmIcon or false
        end
        if cdmIcon and cdmIcon ~= false then
          local appFS = cdmIcon.Applications and cdmIcon.Applications.Applications
          if appFS then
            local stackText = appFS:GetText()
            if stackText then
              detectedMultipleStacks = issecretvalue(stackText)
            end
          end
        end
      end
      
      -- Calculate which icons show duration based on showDurationOn setting and detected stacks
      -- showDurationOn values:
      --   0 = none
      --   1 = first icon only
      --   2-10 = first N icons (when filled)
      --   -1 = last icon only
      -- Use cached optionsOpen from function start for preview mode
      local usePreviewValue = optionsOpen and (not active or previewMode)
      local previewStackCount = nil
      if usePreviewValue then
        -- Use global previewStacks (0-1 decimal) to calculate preview
        local pct = previewStacks or 0.5
        previewStackCount = math_floor(maxStacks * pct + 0.5)
        if previewStackCount < 1 then previewStackCount = math_ceil(maxStacks / 2) end
      end
      
      -- Update each multi-icon frame
      for i = 1, maxStacks do
        local mFrame = multiFrames[i]
        if mFrame then
          -- Set size
          mFrame:SetSize(iconSize, iconSize)
          
          -- Set position - use saved position (free mode) or calculate default
          mFrame:ClearAllPoints()
          local savedPos = cfg.iconMultiPositions and cfg.iconMultiPositions[i]
          
          if freeMode and savedPos then
            -- Free mode with saved position
            mFrame:SetPoint(savedPos.point, UIParent, savedPos.relPoint, savedPos.x, savedPos.y)
          elseif not freeMode then
            -- Auto-layout mode - calculate positions based on direction
            local offsetX, offsetY = 0, 0
            if direction == "RIGHT" then
              offsetX = (i - 1) * (iconSize + spacing)
            elseif direction == "LEFT" then
              offsetX = -(i - 1) * (iconSize + spacing)
            elseif direction == "UP" then
              offsetY = (i - 1) * (iconSize + spacing)
            elseif direction == "DOWN" then
              offsetY = -(i - 1) * (iconSize + spacing)
            end
            
            -- Use main icon position as anchor
            local mainPos = cfg.position
            if mainPos then
              mFrame:SetPoint(mainPos.point, UIParent, mainPos.relPoint, mainPos.x + offsetX, mainPos.y + offsetY)
            else
              mFrame:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
            end
          else
            -- Free mode but no saved position yet - use default layout
            local offsetX, offsetY = 0, 0
            if direction == "RIGHT" then
              offsetX = (i - 1) * (iconSize + spacing)
            elseif direction == "LEFT" then
              offsetX = -(i - 1) * (iconSize + spacing)
            elseif direction == "UP" then
              offsetY = (i - 1) * (iconSize + spacing)
            elseif direction == "DOWN" then
              offsetY = -(i - 1) * (iconSize + spacing)
            end
            
            local mainPos = cfg.position
            if mainPos then
              mFrame:SetPoint(mainPos.point, UIParent, mainPos.relPoint, mainPos.x + offsetX, mainPos.y + offsetY)
            else
              mFrame:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
            end
          end
          
          -- Set icon texture ONLY when out of combat (SetStatusBarTexture doesn't accept secret/tainted values)
          -- Track what texture is set so we don't try to set it again during combat
          if not InCombatLockdown() then
            if mFrame.currentTextureID ~= iconTex then
              mFrame.iconBar:SetStatusBarTexture(iconTex)
              mFrame.iconBar:SetStatusBarColor(1, 1, 1, 1)  -- Ensure white color!
              -- DON'T use SetTexCoord on StatusBar texture - it breaks the display
              
              -- Set desaturated background texture (same icon, but gray)
              mFrame.desatBg:SetTexture(iconTex)
              mFrame.desatBg:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- TexCoord OK on regular Texture
              mFrame.desatBg:SetDesaturated(true)
              mFrame.desatBg:SetVertexColor(0.4, 0.4, 0.4, 1)
              
              mFrame.currentTextureID = iconTex
            end
          end
          
          -- Set min/max values for this stack position (i-1, i)
          -- Stack 1: (0,1), Stack 2: (1,2), etc.
          local iconInterp = GetBarInterpolation(cfg.enableSmoothing)
          mFrame.iconBar:SetMinMaxValues(i - 1, i, iconInterp)
          
          -- Pass the stacks value through to SetValue
          -- SetValue accepts secret values - it will show filled when stacks >= i
          if usePreviewValue and previewStackCount then
            -- Preview mode: use calculated preview count
            mFrame.iconBar:SetValue(previewStackCount, iconInterp)
          elseif stacks then
            -- Live mode: pass secret value directly through
            mFrame.iconBar:SetValue(stacks, iconInterp)
          else
            -- No stacks data: show empty
            mFrame.iconBar:SetValue(0, iconInterp)
          end
          
          -- Background visibility (desaturated icon background)
          local showDesatBg = cfg.iconMultiShowDesatBg
          if showDesatBg == nil then showDesatBg = true end  -- Default to showing
          
          if showDesatBg or optionsOpen then
            -- Show desaturated background (always show during editing for visibility)
            SafeShow(mFrame.desatBg)
            SafeShow(mFrame.solidBg)
          else
            -- Hide background - only show filled icons
            SafeHide(mFrame.desatBg)
            SafeHide(mFrame.solidBg)
          end
          
          -- Border
          if cfg.iconShowBorder then
            local bc = cfg.iconBorderColor or {r=0, g=0, b=0, a=1}
            mFrame.border:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
            SafeShow(mFrame.border)
          else
            SafeHide(mFrame.border)
          end
          
          -- Duration text - use new shouldShowDuration logic
          local showDuration = ShouldShowIconDuration(i, showDurationOn, maxStacks, detectedMultipleStacks)
          
          -- In preview mode, use the preview stack count for visibility
          if usePreviewValue and previewStackCount then
            -- Preview: show duration on icons up to previewStackCount, limited by showDurationOn
            if showDurationOn == 0 then
              showDuration = false
            elseif showDurationOn == -1 then
              showDuration = (i == maxStacks)
            elseif showDurationOn == 1 then
              showDuration = (i == 1)
            elseif showDurationOn >= 2 then
              -- In preview, show on first N icons up to the preview stack count
              showDuration = (i <= showDurationOn) and (i <= previewStackCount)
            end
          end
          
          -- Get duration anchor setting
          local durationAnchor = cfg.iconMultiDurationAnchor or "BOTTOM"
          
          -- Update duration position based on anchor
          mFrame.duration:ClearAllPoints()
          if durationAnchor == "CENTER" then
            mFrame.duration:SetPoint("CENTER", mFrame, "CENTER", 0, 0)
          elseif durationAnchor == "TOP" then
            mFrame.duration:SetPoint("TOP", mFrame, "TOP", 0, -2)
          elseif durationAnchor == "BOTTOM" then
            mFrame.duration:SetPoint("BOTTOM", mFrame, "BOTTOM", 0, 2)
          elseif durationAnchor == "LEFT" then
            mFrame.duration:SetPoint("LEFT", mFrame, "LEFT", 2, 0)
          elseif durationAnchor == "RIGHT" then
            mFrame.duration:SetPoint("RIGHT", mFrame, "RIGHT", -2, 0)
          elseif durationAnchor == "TOPLEFT" then
            mFrame.duration:SetPoint("TOPLEFT", mFrame, "TOPLEFT", 2, -2)
          elseif durationAnchor == "TOPRIGHT" then
            mFrame.duration:SetPoint("TOPRIGHT", mFrame, "TOPRIGHT", -2, -2)
          elseif durationAnchor == "BOTTOMLEFT" then
            mFrame.duration:SetPoint("BOTTOMLEFT", mFrame, "BOTTOMLEFT", 2, 2)
          elseif durationAnchor == "BOTTOMRIGHT" then
            mFrame.duration:SetPoint("BOTTOMRIGHT", mFrame, "BOTTOMRIGHT", -2, 2)
          else
            mFrame.duration:SetPoint("BOTTOM", mFrame, "BOTTOM", 0, 2)
          end
          
          if showDuration and cfg.iconShowDuration then
            local durationOutline = GetOutlineFlag(cfg.iconDurationOutline)
            local durationFont = "Fonts\\FRIZQT__.TTF"
            if LSM and cfg.iconDurationFont then
              local font = LSM:Fetch("font", cfg.iconDurationFont)
              if font then
                durationFont = font
              end
            end
            mFrame.duration:SetFont(durationFont, durationFontSize, durationOutline)
            ApplyTextShadow(mFrame.duration, cfg.iconDurationShadow)
            mFrame.duration:SetTextColor(dc.r, dc.g, dc.b, dc.a)
            
            -- Get decimals setting for formatting
            local decimals = cfg.durationDecimals or 1
            
            if active and durationFontString then
              if durationFontString.GetAuraInfo then
                -- Has GetAuraInfo - use C_UnitAuras.GetAuraDurationRemaining for secret-safe text
                local auraID, unit = durationFontString:GetAuraInfo()
                if auraID and unit then
                  -- Validate the aura still exists before GetAuraDurationRemaining
                  -- (calling with a stale auraID is the crash risk, not the call itself).
                  local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraID)
                  if auraData then
                    mFrame.duration:SetFormattedText(DURATION_FMT[decimals] or "%.1f",
                      C_UnitAuras.GetAuraDurationRemaining(unit, auraID))
                  else
                    mFrame.duration:SetFormattedText(DURATION_FMT[decimals] or "%.1f", durationFontString:GetValue())
                  end
                else
                  mFrame.duration:SetFormattedText(DURATION_FMT[decimals] or "%.1f", durationFontString:GetValue())
                end
              elseif durationFontString.GetValue then
                -- StatusBar or wrapper - pass value directly (secret-safe via SetText)
                mFrame.duration:SetFormattedText(DURATION_FMT[decimals] or "%.1f", durationFontString:GetValue())
              elseif durationFontString.GetText then
                -- FontString - use GetText
                mFrame.duration:SetText(durationFontString:GetText())
              end
              mFrame.duration:Show()
            elseif usePreviewValue then
              -- Preview mode - show "0" as placeholder
              mFrame.duration:SetText("0")
              mFrame.duration:Show()
            else
              mFrame.duration:SetText("")
              mFrame.duration:Hide()
            end
          else
            mFrame.duration:Hide()
          end
          
          -- Editing text (show when options open and free mode enabled)
          if not mFrame.editingText then
            mFrame.editingText = mFrame:CreateFontString(nil, "OVERLAY")
            mFrame.editingText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
            mFrame.editingText:SetPoint("TOP", mFrame, "BOTTOM", 0, -2)
            mFrame.editingText:SetTextColor(1, 0.8, 0, 1)
          end
          
          if optionsOpen and freeMode then
            mFrame.editingText:SetText("Stack " .. i)
            mFrame.editingText:Show()
          else
            mFrame.editingText:Hide()
          end
          
          -- Show frame visibility logic
          -- Show when: options open, OR active, OR showDesatBg is enabled (always show inactive icons)
          local showDesatBg = cfg.iconMultiShowDesatBg
          if showDesatBg == nil then showDesatBg = true end
          
          if cfg.enabled and (optionsOpen or active or showDesatBg) then
            SafeShow(mFrame)
          else
            SafeHide(mFrame)
          end
        end
      end
      
      -- Hide any extra frames if maxStacks decreased
      if multiIconFrames[barNumber] then
        for i = maxStacks + 1, #multiIconFrames[barNumber] do
          SafeHide(multiIconFrames[barNumber][i])
        end
      end
      
      return  -- Done with multi-icon mode
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- REGULAR ICON MODE
    -- ═══════════════════════════════════════════════════════════════════
    -- Hide multi-icon frames if switching back to regular mode
    HideMultiIconFrames(barNumber)
    
    -- Hide bar elements
    SafeHide(barFrame)
    SafeHide(textFrame)
    SafeHide(durationFrame)
    SafeHide(nameFrame)
    SafeHide(barIconFrame)
    
    -- Set icon texture with multiple fallbacks
    if iconTexture then
      iconFrame.icon:SetTexture(iconTexture)
    elseif barConfig.tracking.iconTextureID then
      iconFrame.icon:SetTexture(barConfig.tracking.iconTextureID)
    elseif barConfig.tracking.spellID then
      local texture = C_Spell.GetSpellTexture(barConfig.tracking.spellID)
      if texture then
        iconFrame.icon:SetTexture(texture)
      end
    end
    
    -- Apply icon zoom
    local zoom = cfg.iconZoom or 0
    local minCoord = 0.08 + (zoom * 0.42)  -- 0.08 to 0.50
    local maxCoord = 0.92 - (zoom * 0.42)  -- 0.92 to 0.50
    iconFrame.icon:SetTexCoord(minCoord, maxCoord, minCoord, maxCoord)
    
    -- Show/hide icon texture based on iconShowTexture
    -- SAFETY: Also verify bar is enabled (prevents ghost icons from deleted bars)
    if cfg.iconShowTexture == false or not barConfig.tracking.enabled then
      iconFrame.icon:Hide()
      iconFrame.background:Hide()
    else
      iconFrame.icon:Show()
    end
    
    -- Use cached optionsOpen from function start for preview mode
    local showPreview = optionsOpen and (not active or previewMode)
    
    -- Update stacks text (SetText handles secret values)
    if cfg.iconShowStacks then
      local stackAnchor = cfg.iconStackAnchor or "TOPRIGHT"
      local stackText
      local sc = cfg.iconStackColor or {r=1, g=1, b=1, a=1}
      
      -- Determine which text element to use
      if stackAnchor == "FREE" then
        stackText = iconFrame.stacksFrame.text
        iconFrame.stacks:Hide()
        iconFrame.stacksFrame:Show()
      else
        stackText = iconFrame.stacks
        iconFrame.stacksFrame:Hide()
        iconFrame.stacks:Show()
      end
      
      -- Show stacks - preview, active, or inactive
      if showPreview then
        local previewStackCount = math_max(1, math_floor((maxStacks or 3) * (previewStacks or 0.5)))
        stackText:SetText(previewStackCount)
      elseif active and stacks then
        stackText:SetText(stacks)
      else
        stackText:SetText("0")
      end
      stackText:SetTextColor(sc.r, sc.g, sc.b, sc.a)
    else
      iconFrame.stacks:Hide()
      iconFrame.stacksFrame:Hide()
    end
    
    -- Update duration text (pass secret value directly)
    -- durationFontString can be FontString (GetText), StatusBar (GetValue), or wrapper with GetAuraInfo
    if cfg.iconShowDuration then
      local dc = cfg.iconDurationColor or {r=1, g=1, b=1, a=1}
      local decimals = cfg.durationDecimals or 1
      
      -- Store decimals on frame for OnUpdate access
      iconFrame.storedDecimals = decimals
      
      if showPreview then
        -- Preview mode - show sample duration
        local maxDuration = barConfig.tracking.maxDuration or 30
        local pct = previewStacks or 0.5
        local previewValue = maxDuration * pct
        iconFrame.duration:SetText(string_format(DURATION_FMT[decimals] or "%.1f", previewValue))
        iconFrame:SetScript("OnUpdate", nil)
        iconFrame.durationActive = false
        iconFrame.durationSource = nil
      elseif durationFontString and durationFontString.GetAuraInfo then
        -- Has GetAuraInfo - use DurationObject for auto-updating countdown
        local auraID, unit = durationFontString:GetAuraInfo()
        if auraID and unit and active then
          -- Store source for OnUpdate to get fresh aura info
          iconFrame.durationSource = durationFontString
          iconFrame.durationActive = true
          
          -- Set up OnUpdate to poll GetRemainingDuration() with fresh DurationObject
          if not iconFrame.durationOnUpdate then
            iconFrame.durationOnUpdate = function(self, elapsed)
              self.durationElapsed = (self.durationElapsed or 0) + elapsed
              if self.durationElapsed < 0.05 then return end  -- 20fps
              self.durationElapsed = 0

              if not self.durationActive or not self.durationSource then return end

              -- Get current auraID from source (may have changed due to refresh)
              local currentAuraID, currentUnit = self.durationSource:GetAuraInfo()
              if not currentAuraID or not currentUnit then
                self.duration:SetText("")
                return
              end

              -- GetAuraDuration returns nil for gone auras, does not throw — no pcall needed
              local durObj = C_UnitAuras.GetAuraDuration(currentUnit, currentAuraID)
              if durObj then
                -- GetRemainingDuration on valid durObj does not throw — no pcall needed
                self.duration:SetFormattedText(DURATION_FMT[self.storedDecimals] or "%.1f", durObj:GetRemainingDuration())
              else
                self.duration:SetText("")
              end
            end
          end
          iconFrame:SetScript("OnUpdate", iconFrame.durationOnUpdate)

          -- Initial text set — no pcall, GetAuraDuration returns nil safely
          local durObj = C_UnitAuras.GetAuraDuration(unit, auraID)
          if durObj then
            iconFrame.duration:SetFormattedText(DURATION_FMT[decimals] or "%.1f", durObj:GetRemainingDuration())
          end
        else
          iconFrame.duration:SetText("")
          iconFrame:SetScript("OnUpdate", nil)
          iconFrame.durationActive = false
          iconFrame.durationSource = nil
        end
      elseif durationFontString and durationFontString.GetValue then
        -- It's a StatusBar or wrapper - pass value directly (secret-safe via SetText)
        iconFrame:SetScript("OnUpdate", nil)
        iconFrame.durationActive = false
        iconFrame.durationSource = nil
        if active then
          iconFrame.duration:SetFormattedText(DURATION_FMT[decimals] or "%.1f", durationFontString:GetValue())
        else
          iconFrame.duration:SetText("")
        end
      elseif durationFontString and durationFontString.GetText then
        -- It's a FontString - use GetText
        iconFrame:SetScript("OnUpdate", nil)
        iconFrame.durationActive = false
        iconFrame.durationSource = nil
        iconFrame.duration:SetText(durationFontString:GetText())
      else
        iconFrame:SetScript("OnUpdate", nil)
        iconFrame.durationActive = false
        iconFrame.durationSource = nil
        iconFrame.duration:SetText("")
      end
      iconFrame.duration:SetTextColor(dc.r, dc.g, dc.b, dc.a)
      iconFrame.duration:Show()
    else
      iconFrame:SetScript("OnUpdate", nil)
      iconFrame.durationActive = false
      iconFrame.durationSource = nil
      iconFrame.duration:Hide()
    end
    
    -- Border
    if cfg.iconShowBorder then
      local bc = cfg.iconBorderColor or {r=0, g=0, b=0, a=1}
      iconFrame.background:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
      iconFrame.background:Show()
    else
      iconFrame.background:Hide()
    end
    
    -- Visibility logic
    local shouldShow = true
    local hideWhenFadeAlpha = 1.0
    
    -- Hide When conditions (but not if options panel is open)
    if not optionsOpen and ns.CooldownBars and ns.CooldownBars.GetHideWhen then
      local hideWhen = ns.CooldownBars.GetHideWhen(barConfig)
      if hideWhen and ns.CooldownBars.EvaluateHideConditions(hideWhen, barConfig.behavior and barConfig.behavior.hideLogic) then
        local hAlpha = ns.CooldownBars.GetHideWhenAlpha(barConfig)
        if hAlpha <= 0 then
          shouldShow = false
        else
          hideWhenFadeAlpha = hAlpha
        end
      end
    end
    if barFrames[barNumber] then barFrames[barNumber]._arcHideWhenAlpha = hideWhenFadeAlpha end
    
    -- Hide when inactive (but not if options panel is open for preview)
    if not active and barConfig.behavior.hideWhenInactive and not optionsOpen then
      shouldShow = false
    end
    
    -- If not active and not preview, clear duration text
    if not active and not showPreview then
      iconFrame.duration:SetText("")
    end
    
    if shouldShow and cfg.enabled then
      SafeShow(iconFrame)
      if hideWhenFadeAlpha < 1.0 then iconFrame:SetAlpha(hideWhenFadeAlpha) end
    else
      SafeHide(iconFrame)
    end
    
    return  -- Exit early for icon mode
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- BAR MODE (existing code)
  -- ═══════════════════════════════════════════════════════════════════
  -- Hide icon frame if in bar mode
  SafeHide(iconFrame)
  
  -- Use cached optionsOpen from function start for preview mode
  local showPreview = optionsOpen and (not active or previewMode)
  
  -- For preview mode, calculate a sample stack count from the global preview slider
  -- We can't use 'stacks' parameter for math as it may be a secret value
  local effectiveStacks = stacks
  if showPreview then
    -- Use global previewStacks (0-1 decimal) to calculate preview
    local pct = previewStacks or 0.5
    effectiveStacks = math_floor(maxStacks * pct + 0.5)
    if effectiveStacks < 1 then effectiveStacks = math_ceil(maxStacks / 2) end
  end
  
  local displayMode = barConfig.display.thresholdMode or "simple"
  local thresholds = barConfig.thresholds or {}
  
  -- Helper: cache thresholdAsPercent for file-level GetThresholdValue calls
  local thresholdAsPercent = barConfig.display.thresholdAsPercent

  -- ═══════════════════════════════════════════════════════════════════
  -- PERFORMANCE: Use _configVersion instead of building hash string every call
  -- _configVersion is bumped by BumpConfigVersion() when settings change
  -- ═══════════════════════════════════════════════════════════════════
  local currentConfigVersion = barConfig._configVersion or 0
  local needsSetup = barFrame._lastConfigVersion ~= currentConfigVersion
  -- When anchored to a group, always force segment re-layout.
  -- The bar frame may be resized by UpdateBarForGroup in ApplyAppearance,
  -- and segment bars need to recompute their SetPoint positions every time.
  if not needsSetup and barConfig.display and barConfig.display.anchorToGroup then
    local dm = barConfig.display.thresholdMode or "simple"
    if dm == "perStack" or dm == "granular" then
      needsSetup = true
    end
  end
  if needsSetup then
    if barFrame.stackedBars then
      for i = 1, #barFrame.stackedBars do
        SafeHide(barFrame.stackedBars[i])
      end
    end
    if barFrame.granularBars then
      for i = 1, #barFrame.granularBars do
        local gb = barFrame.granularBars[i]
        SafeHide(gb)
        if gb then
          if gb._arcTickBorderEnd then gb._arcTickBorderEnd:Hide() end
          if gb._arcTickBorderStart then gb._arcTickBorderStart:Hide() end
          if gb._arcTickBorder then gb._arcTickBorder:Hide() end
        end
      end
    end
  end
  
  if PM then PM("AppearanceSetup") end
  
  -- Get orientation settings for bar (always needed for logic, cheap)
  local isBarVertical = (barConfig.display.barOrientation == "vertical")
  local barOrientation = isBarVertical and "VERTICAL" or "HORIZONTAL"
  local isBarReverseFill = barConfig.display.barReverseFill or false
  local rotateBarTex = (barConfig.display.rotateTexture == true) or (barConfig.display.rotateTexture ~= false and isBarVertical)
  
  -- Get texture - cache the path on the frame to avoid LSM:Fetch every frame
  local texturePath = barFrame._cachedTexturePath
  if needsSetup or not texturePath then
    texturePath = "Interface\\TargetingFrame\\UI-StatusBar"
    if LSM and barConfig.display.texture then
      local fetchedTexture = LSM:Fetch("statusbar", barConfig.display.texture)
      if fetchedTexture then texturePath = fetchedTexture end
    end
    barFrame._cachedTexturePath = texturePath
    -- Only lock in the config version when options are closed — while options are
    -- open the user may change settings every call, so always re-evaluate needsSetup
    if not optionsOpen then
      barFrame._lastConfigVersion = currentConfigVersion
    end
  end
  
  -- Get fill texture scale
  local fillTextureScale = barConfig.display.fillTextureScale or 1.0
  
  local baseColor = barConfig.display.barColor or {r=0, g=0.8, b=1, a=1}
  if thresholds[1] and thresholds[1].enabled and thresholds[1].color then
    baseColor = thresholds[1].color
  end
  
  if PM then PM("BarRendering") end

  -- ═══════════════════════════════════════════════════════════════════════════
  -- RUNTIME EARLY EXIT: Bar already set up, active state unchanged, options closed.
  -- Bust on options open/close transitions and for 1s after close so dynamic
  -- layout reflow can complete before we lock in the bar state.
  -- ═══════════════════════════════════════════════════════════════════════════
  local optionsTransition = (barFrame._lastOptionsOpen ~= nil) and (barFrame._lastOptionsOpen ~= optionsOpen)
  if not optionsTransition and not optionsOpen then
    -- Check 1s grace period after close
    if barFrame._optionsCloseTime then
      if GetTime() - barFrame._optionsCloseTime < 1.0 then
        optionsTransition = true
      else
        barFrame._optionsCloseTime = nil
      end
    end
  end
  if barFrame._lastOptionsOpen ~= optionsOpen then
    barFrame._lastConfigVersion = -1  -- container width changed, force segment re-layout
    optionsTransition = true
  end
  if barFrame._lastOptionsOpen and not optionsOpen and not barFrame._optionsCloseTime then
    barFrame._optionsCloseTime = GetTime()
    optionsTransition = true
  end
  barFrame._lastOptionsOpen = optionsOpen

  if not optionsOpen and not needsSetup and not optionsTransition and barFrame._lastActive == active and barFrame._lastActive ~= nil then
    if active then
      -- Cancel any pending hideWhenInactive hide
      if barFrames[barNumber] then barFrames[barNumber]._arcHideWhenInactivePending = nil end
      if displayMode == "granular" or displayMode == "perStack" then
        if barFrame.granularBars then
          for _, bar in ipairs(barFrame.granularBars) do
            bar:SetValue(effectiveStacks, interp)
          end
        end
      elseif displayMode == "folded" then
        if barFrame.stackedBars then
          if barFrame.stackedBars[1] then barFrame.stackedBars[1]:SetValue(effectiveStacks, interp) end
          if barFrame.stackedBars[2] then barFrame.stackedBars[2]:SetValue(effectiveStacks, interp) end
        end
        if barFrame.maxColorBar then barFrame.maxColorBar:SetValue(effectiveStacks, interp) end
      else -- simple
        if barFrame.stackedBars then
          if barFrame.stackedBars[1] then barFrame.stackedBars[1]:SetValue(effectiveStacks, interp) end
          if barFrame.stackedBars[2] then barFrame.stackedBars[2]:SetValue(effectiveStacks, interp) end
        end
      end
      if barConfig.display.showText then
        textFrame.text:SetText(stacks)
        if not textFrame:IsShown() then textFrame:Show() end
      end
      -- Restore frames hidden externally (e.g. HideBar from Core trackingOK=false)
      -- If barFrame was hidden, force full path so duration/name/etc get properly re-setup
      if barConfig.display.enabled and not barFrame:IsShown() then
        barFrame._lastActive = nil  -- bust early exit so full path runs next call
        barFrame:Show()
      end
      if nameFrame and barConfig.display.showName and not nameFrame:IsShown() then
        nameFrame:Show()
      end
      if barIconFrame and barConfig.display.showBarIcon and not barIconFrame:IsShown() then
        barIconFrame:Show()
      end
    else
      -- Inactive: ensure correct visibility based on hideWhenInactive setting
      if barConfig.behavior and barConfig.behavior.hideWhenInactive then
        if barFrame:IsShown() then
          SafeHide(barFrame)
          SafeHide(textFrame)
        end
      elseif barConfig.display.enabled and not barFrame:IsShown() then
        barFrame:Show()
        if barConfig.display.showText then textFrame:Show() end
      end
    end
    return
  end
  barFrame._lastActive = active

  if displayMode == "granular" then
    -- ═══════════════════════════════════════════════════════════════
    -- GRANULAR MODE: 1 bar per stack
    -- ═══════════════════════════════════════════════════════════════
    barFrame.bar:SetAlpha(0)
    
    -- Hide other bar types
    if barFrame.stackedBars then
      for _, bar in ipairs(barFrame.stackedBars) do bar:Hide() end
    end
    if barFrame.maxColorBar then
      barFrame.maxColorBar:Hide()
    end
    
    -- Build color ranges from thresholds
    -- Build color ranges from thresholds (cached on barFrame, rebuilt when config changes)
    local colorRanges = barFrame._cachedColorRanges
    if needsSetup or not colorRanges then
      colorRanges = {}
      colorRanges[1] = { startValue = 0, color = baseColor }
      local n = 1
      if thresholds[2] and thresholds[2].enabled then
        n = n + 1; colorRanges[n] = { startValue = GetThresholdValue(thresholds[2].minValue, math_floor(maxStacks/2), thresholdAsPercent, maxStacks), color = thresholds[2].color }
      end
      if thresholds[3] and thresholds[3].enabled then
        n = n + 1; colorRanges[n] = { startValue = GetThresholdValue(thresholds[3].minValue, math_floor(maxStacks*0.8), thresholdAsPercent, maxStacks), color = thresholds[3].color }
      end
      if thresholds[4] and thresholds[4].enabled then
        n = n + 1; colorRanges[n] = { startValue = GetThresholdValue(thresholds[4].minValue, math_floor(maxStacks*0.5), thresholdAsPercent, maxStacks), color = thresholds[4].color }
      end
      if thresholds[5] and thresholds[5].enabled then
        n = n + 1; colorRanges[n] = { startValue = GetThresholdValue(thresholds[5].minValue, math_floor(maxStacks*0.7), thresholdAsPercent, maxStacks), color = thresholds[5].color }
      end
      if thresholds[6] and thresholds[6].enabled then
        n = n + 1; colorRanges[n] = { startValue = GetThresholdValue(thresholds[6].minValue, math_floor(maxStacks*0.9), thresholdAsPercent, maxStacks), color = thresholds[6].color }
      end
      for i = n + 1, #colorRanges do colorRanges[i] = nil end
      table.sort(colorRanges, ColorRangeSort)
      barFrame._cachedColorRanges = colorRanges
    end
    
    -- Get max color settings
    local enableMaxColor = barConfig.display.enableMaxColor
    local maxColor = barConfig.display.maxColor or {r=0, g=1, b=0, a=1}
    
    local numBars = maxStacks
    
    -- Get smoothing setting
    local enableSmooth = barConfig.display.enableSmoothing
    
    -- Build threshold boundary set (cached on barFrame, rebuilt with config changes)
    local thresholdBoundary = barFrame._cachedThresholdBoundary
    if needsSetup or not thresholdBoundary then
      thresholdBoundary = {}
      if enableSmooth then
        local prevColor = nil
        for val = 1, numBars do
          local c = GetColorForValue(val, enableMaxColor, maxStacks, maxColor, colorRanges)
          if prevColor ~= nil and c ~= prevColor then
            thresholdBoundary[val] = true
          end
          prevColor = c
        end
      end
      barFrame._cachedThresholdBoundary = thresholdBoundary
    end
    
    if not barFrame.granularBars then
      barFrame.granularBars = {}
    end

    local granularScale = barFrame:GetEffectiveScale()
    local segGap = PixelSnap(barConfig.display.segmentedSpacing or 1, granularScale)

    while #barFrame.granularBars < numBars do
      local bar = CreateFrame("StatusBar", nil, barFrame)
      bar:SetStatusBarTexture(texturePath)
      bar:SetOrientation(barOrientation)
      bar:SetReverseFill(isBarReverseFill)
      bar:SetRotatesTexture(rotateBarTex)
      local barTex = bar:GetStatusBarTexture()
      if barTex then barTex:SetSnapToPixelGrid(false) barTex:SetTexelSnappingBias(0) end
      table.insert(barFrame.granularBars, bar)
    end
    
    for i = 1, numBars do
      local bar = barFrame.granularBars[i]
      local barValue = i
      local widthPercent = barValue / maxStacks
      local color = GetColorForValue(barValue, enableMaxColor, maxStacks, maxColor, colorRanges)
      
      -- Skip interpolation at threshold boundary bars to prevent old color leaking through
      local interp = thresholdBoundary[barValue] and nil or GetBarInterpolation(enableSmooth)

      -- PERFORMANCE: Only apply expensive setup when appearance changes
      if needsSetup or not bar._setupDone then
        bar:SetOrientation(barOrientation)
        bar:SetReverseFill(isBarReverseFill)
        bar:SetRotatesTexture(rotateBarTex)
        bar:SetStatusBarTexture(texturePath)
        bar:SetFrameLevel(barFrame:GetFrameLevel() + i)
        ApplyBarSmoothing(bar, enableSmooth)
        bar:ClearAllPoints()
        local barScale = barFrame:GetEffectiveScale()
        if isBarVertical then
          local totalHeight = barFrame:GetHeight()
          local barHeight = widthPercent * totalHeight
          if isBarReverseFill then
            bar:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
            bar:SetPoint("RIGHT", barFrame, "RIGHT", 0, 0)
          else
            bar:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 0, 0)
            bar:SetPoint("RIGHT", barFrame, "RIGHT", 0, 0)
          end
          bar:SetHeight(math_max(2, PixelSnap(barHeight, barScale)))
        else
          local totalWidth = barFrame:GetWidth()
          local barWidth = widthPercent * totalWidth
          if isBarReverseFill then
            bar:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, 0)
            bar:SetPoint("BOTTOM", barFrame, "BOTTOM", 0, 0)
          else
            bar:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
            bar:SetPoint("BOTTOM", barFrame, "BOTTOM", 0, 0)
          end
          bar:SetWidth(math_max(2, PixelSnap(barWidth, barScale)))
        end
        bar:SetMinMaxValues(barValue - 1, barValue)
        bar:SetStatusBarColor(color.r, color.g, color.b, color.a or 1)
        ApplyBarGradient(bar, barConfig, color)
        bar._setupDone = true
      end
      bar:SetValue(effectiveStacks, interp)
      bar:Show()

      -- Hide legacy border tick textures — UpdateTickMarks now handles all tick drawing
      if bar._arcTickBorderEnd   then bar._arcTickBorderEnd:Hide() end
      if bar._arcTickBorderStart then bar._arcTickBorderStart:Hide() end
      if bar._arcTickBorder      then bar._arcTickBorder:Hide() end
    end
    
  elseif displayMode == "perStack" then
    -- ═══════════════════════════════════════════════════════════════
    -- SEQUENCE MODE: Separate segments with color ranges
    -- ═══════════════════════════════════════════════════════════════
    barFrame.bar:SetAlpha(0)
    
    local numBars = maxStacks
    local stackColors = barConfig.stackColors or {}

    -- Get max color settings
    local enableMaxColor = barConfig.display.enableMaxColor
    local maxColor = barConfig.display.maxColor or {r=0, g=1, b=0, a=1}
    
    -- Get smoothing setting
    local enableSmooth = barConfig.display.enableSmoothing

    -- Border inset: when a border is drawn, inset segments so fill textures
    -- can't bleed over the border edges at the leading and trailing ends.
    local segInset = 0
    if barConfig.display.showBorder then
      local btRaw = barConfig.display.drawnBorderThickness or 2
      local _s2 = barFrame:GetEffectiveScale()
      local _, _h2 = GetPhysicalScreenSize()
      local _onePx2 = (_h2 and _h2 > 0 and _s2 and _s2 > 0) and (768 / _h2) / _s2 or 1
      segInset = _onePx2 * btRaw
    end

    -- Hide maxColorBar (we use segment color override instead)
    if barFrame.maxColorBar then
      barFrame.maxColorBar:Hide()
    end
    
    -- Ensure we have granularBars for segments
    if not barFrame.granularBars then
      barFrame.granularBars = {}
    end
    
    -- Create segment bars as needed
    while #barFrame.granularBars < numBars do
      local bar = CreateFrame("StatusBar", nil, barFrame)
      bar:SetStatusBarTexture(texturePath)
      bar:SetOrientation(barOrientation)
      bar:SetReverseFill(isBarReverseFill)
      bar:SetRotatesTexture(rotateBarTex)
      local barTex = bar:GetStatusBarTexture()
      if barTex then barTex:SetSnapToPixelGrid(false) barTex:SetTexelSnappingBias(0) end
      table.insert(barFrame.granularBars, bar)
    end
    
    -- Hide any old threshold overlays if they exist
    if barFrame.thresholdOverlay1 then
      for _, bar in ipairs(barFrame.thresholdOverlay1) do bar:Hide() end
    end
    if barFrame.thresholdOverlay2 then
      for _, bar in ipairs(barFrame.thresholdOverlay2) do bar:Hide() end
    end
    
    -- Calculate segment size based on orientation — work in integer screen pixels
    -- throughout so every boundary lands exactly on a physical pixel with zero drift.
    local totalSize = (isBarVertical and barFrame:GetHeight() or barFrame:GetWidth()) - 2 * segInset
    local scale = barFrame:GetEffectiveScale()
    local _, _h = GetPhysicalScreenSize()
    local pmult = (_h and _h > 0 and scale and scale > 0) and (768 / _h) / scale or 1
    -- Convert totalSize and gap to integer screen pixels
    local totalPixels = math_floor(totalSize / pmult + 0.5)
    local segGapPx    = math_floor((barConfig.display.segmentedSpacing or 1) + 0.5)

    for i = 1, numBars do
      local bar = barFrame.granularBars[i]
      local color = stackColors[i] or baseColor

      -- Override last segment with max color if enabled
      if enableMaxColor and i == numBars then
        color = maxColor
      end

      -- Per-segment pixel boundaries (always needed for positioning)
      local startPixel = math_floor((i - 1) * totalPixels / numBars)
      local endPixel   = math_floor(i       * totalPixels / numBars)
      local sizePixels = math_max(2, endPixel - startPixel - segGapPx)
      local offset  = segInset + startPixel * pmult
      local barSize = sizePixels * pmult

      -- PERFORMANCE: Only apply expensive setup when appearance changes
      if needsSetup or not bar._setupDone then
        bar:SetOrientation(barOrientation)
        bar:SetReverseFill(isBarReverseFill)
        bar:SetRotatesTexture(rotateBarTex)
        bar:SetStatusBarTexture(texturePath)
        bar:SetFrameLevel(barFrame:GetFrameLevel() + i)
        ApplyBarSmoothing(bar, enableSmooth)
        bar:ClearAllPoints()
        if isBarVertical then
          if isBarReverseFill then
            bar:SetPoint("TOPLEFT",  barFrame, "TOPLEFT",  0, -offset)
            bar:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, -offset)
            if i == numBars then
              bar:SetPoint("BOTTOMLEFT",  barFrame, "BOTTOMLEFT",  0,  segInset)
              bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0,  segInset)
            else
              bar:SetHeight(barSize)
            end
          else
            bar:SetPoint("BOTTOMLEFT",  barFrame, "BOTTOMLEFT",  0, offset)
            bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, offset)
            if i == numBars then
              bar:SetPoint("TOPLEFT",  barFrame, "TOPLEFT",  0, -segInset)
              bar:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, -segInset)
            else
              bar:SetHeight(barSize)
            end
          end
        else
          if isBarReverseFill then
            bar:SetPoint("TOPRIGHT",    barFrame, "TOPRIGHT",    -offset, 0)
            bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -offset, 0)
            if i == numBars then
              bar:SetPoint("TOPLEFT",    barFrame, "TOPLEFT",     segInset, 0)
              bar:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT",  segInset, 0)
            else
              bar:SetWidth(barSize)
            end
          else
            bar:SetPoint("TOPLEFT",    barFrame, "TOPLEFT",    offset, 0)
            bar:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", offset, 0)
            if i == numBars then
              bar:SetPoint("TOPRIGHT",    barFrame, "TOPRIGHT",    -segInset, 0)
              bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -segInset, 0)
            else
              bar:SetWidth(barSize)
            end
          end
        end
        local interp = GetBarInterpolation(enableSmooth)
        bar:SetMinMaxValues(i - 1, i, interp)
        bar:SetStatusBarColor(color.r, color.g, color.b, color.a or 1)
        ApplyBarGradient(bar, barConfig, color)
        bar._setupDone = true
      end
      local interp = GetBarInterpolation(enableSmooth)
      bar:SetValue(effectiveStacks, interp)
      SafeShow(bar)

      -- Hide legacy border tick textures — UpdateTickMarks now handles all tick drawing
      if bar._arcTickBorderEnd   then bar._arcTickBorderEnd:Hide() end
      if bar._arcTickBorderStart then bar._arcTickBorderStart:Hide() end
      if bar._arcTickBorder      then bar._arcTickBorder:Hide() end
    end  -- end for i = 1, numBars

    -- Hide extra bars
    for i = numBars + 1, #barFrame.granularBars do
      local exBar = barFrame.granularBars[i]
      SafeHide(exBar)
      if exBar then
        if exBar._arcTickBorderEnd   then exBar._arcTickBorderEnd:Hide() end
        if exBar._arcTickBorderStart then exBar._arcTickBorderStart:Hide() end
        if exBar._arcTickBorder      then exBar._arcTickBorder:Hide() end
      end
    end
    
  elseif displayMode == "folded" then
    -- ═══════════════════════════════════════════════════════════════
    -- FOLDED MODE: Bar folds at midpoint, second color overlays first
    -- Visual: 10 stacks shown as 5 segments, 2nd color fills over 1st after midpoint
    -- ═══════════════════════════════════════════════════════════════
    barFrame.bar:SetAlpha(0)
    
    local midpoint = math_ceil(maxStacks / 2)
    local color1 = barConfig.display.foldedColor1 or {r=0, g=0.5, b=1, a=1}
    local color2 = barConfig.display.foldedColor2 or {r=0, g=1, b=0, a=1}
    local maxColor = barConfig.display.maxColor or {r=0, g=1, b=0, a=1}
    
    -- Get smoothing setting
    local enableSmooth = barConfig.display.enableSmoothing
    
    -- Hide other bar types
    if barFrame.granularBars then
      for _, bar in ipairs(barFrame.granularBars) do bar:Hide() end
    end
    
    -- Hide foldedBgFrame if exists from old code
    if barFrame.foldedBgFrame then
      barFrame.foldedBgFrame:Hide()
    end
    
    if not barFrame.stackedBars then
      barFrame.stackedBars = {}
    end
    
    while #barFrame.stackedBars < 2 do
      local bar = CreateFrame("StatusBar", nil, barFrame)
      table.insert(barFrame.stackedBars, bar)
    end
    
    -- Bar 1: First half color (0 to midpoint)
    local bar1 = barFrame.stackedBars[1]
    
    -- PERFORMANCE: Only apply expensive setup when appearance changes
    if needsSetup or not bar1._setupDone then
      bar1:SetParent(barFrame)
      bar1:SetOrientation(barOrientation)
      bar1:SetReverseFill(isBarReverseFill)
      bar1:SetRotatesTexture(rotateBarTex)
      bar1:SetStatusBarTexture(texturePath)
      bar1:SetFrameLevel(barFrame:GetFrameLevel() + 1)
      ApplyBarSmoothing(bar1, enableSmooth)
      bar1:ClearAllPoints()
      bar1:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
      bar1:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
      bar1:SetMinMaxValues(0, midpoint, interp)
      bar1:SetStatusBarColor(color1.r, color1.g, color1.b, color1.a or 1)
      ApplyBarGradient(bar1, barConfig, color1)
      bar1._setupDone = true
    end
    bar1:SetValue(effectiveStacks, interp)
    bar1:Show()
    
    -- Bar 2: Second half color (midpoint to max) - overlays bar1 directly
    local bar2 = barFrame.stackedBars[2]
    
    -- PERFORMANCE: Only apply expensive setup when appearance changes
    if needsSetup or not bar2._setupDone then
      bar2:SetParent(barFrame)
      bar2:SetOrientation(barOrientation)
      bar2:SetReverseFill(isBarReverseFill)
      bar2:SetRotatesTexture(rotateBarTex)
      bar2:SetStatusBarTexture(texturePath)
      bar2:SetFrameLevel(barFrame:GetFrameLevel() + 2)
      ApplyBarSmoothing(bar2, enableSmooth)
      bar2:ClearAllPoints()
      bar2:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
      bar2:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
      bar2:SetMinMaxValues(midpoint, maxStacks, interp)
      bar2:SetStatusBarColor(color2.r, color2.g, color2.b, color2.a or 1)
      ApplyBarGradient(bar2, barConfig, color2)
      bar2._setupDone = true
    end
    bar2:SetValue(effectiveStacks, interp)
    bar2:Show()
    
    -- MAX COLOR OVERLAY for folded mode
    local enableMaxColor = barConfig.display.enableMaxColor
    if enableMaxColor and maxStacks > 1 then
      if not barFrame.maxColorBar then
        barFrame.maxColorBar = CreateFrame("StatusBar", nil, barFrame)
      end
      
      local maxBar = barFrame.maxColorBar
      
      -- PERFORMANCE: Only apply expensive setup when appearance changes
      if needsSetup or not maxBar._setupDone then
        maxBar:SetOrientation(barOrientation)
        maxBar:SetReverseFill(isBarReverseFill)
        maxBar:SetRotatesTexture(rotateBarTex)
        maxBar:SetStatusBarTexture(texturePath)
        maxBar:SetFrameLevel(barFrame:GetFrameLevel() + 21)
        ApplyBarSmoothing(maxBar, enableSmooth)
        maxBar:ClearAllPoints()
        maxBar:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
        maxBar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
        maxBar:SetMinMaxValues(maxStacks - 1, maxStacks, interp)
        maxBar:SetStatusBarColor(maxColor.r, maxColor.g, maxColor.b, maxColor.a or 1)
        ApplyBarGradient(maxBar, barConfig, maxColor)
        maxBar._setupDone = true
      end
      maxBar:SetValue(effectiveStacks, interp)
      maxBar:Show()
    elseif barFrame.maxColorBar then
      barFrame.maxColorBar:Hide()
    end
    
  else
    -- ═══════════════════════════════════════════════════════════════
    -- SIMPLE MODE: 2 bars (base + optional max color overlay)
    -- ═══════════════════════════════════════════════════════════════
    barFrame.bar:SetAlpha(0)
    
    local maxColor = barConfig.display.maxColor or {r=0, g=1, b=0, a=1}
    local enableMaxColor = barConfig.display.enableMaxColor
    
    -- Get smoothing setting
    local enableSmooth = barConfig.display.enableSmoothing
    
    -- Hide maxColorBar from continuous mode (simple mode uses stackedBars[2] instead)
    if barFrame.maxColorBar then
      barFrame.maxColorBar:Hide()
    end
    
    if not barFrame.stackedBars then
      barFrame.stackedBars = {}
    end
    
    while #barFrame.stackedBars < 2 do
      local bar = CreateFrame("StatusBar", nil, barFrame)
      table.insert(barFrame.stackedBars, bar)
    end
    
    if enableMaxColor and maxStacks > 1 then
      local interp = GetBarInterpolation(enableSmooth)
      local bar1 = barFrame.stackedBars[1]
      if needsSetup or not bar1._setupDone then
        bar1:SetOrientation(barOrientation)
        bar1:SetReverseFill(isBarReverseFill)
        bar1:SetRotatesTexture(rotateBarTex)
        bar1:SetStatusBarTexture(texturePath)
        bar1:SetFrameLevel(barFrame:GetFrameLevel() + 1)
        ApplyBarSmoothing(bar1, enableSmooth)
        bar1:ClearAllPoints()
        bar1:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
        bar1:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
        bar1:SetMinMaxValues(0, maxStacks, interp)
        bar1:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
        ApplyBarGradient(bar1, barConfig, baseColor)
        bar1._setupDone = true
      end
      bar1:SetValue(effectiveStacks, interp)
      bar1:Show()

      local bar2 = barFrame.stackedBars[2]
      if needsSetup or not bar2._setupDone then
        bar2:SetOrientation(barOrientation)
        bar2:SetReverseFill(isBarReverseFill)
        bar2:SetRotatesTexture(rotateBarTex)
        bar2:SetStatusBarTexture(texturePath)
        bar2:SetFrameLevel(barFrame:GetFrameLevel() + 2)
        ApplyBarSmoothing(bar2, enableSmooth)
        bar2:ClearAllPoints()
        bar2:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
        bar2:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
        bar2:SetMinMaxValues(maxStacks - 1, maxStacks, interp)
        bar2:SetStatusBarColor(maxColor.r, maxColor.g, maxColor.b, maxColor.a or 1)
        ApplyBarGradient(bar2, barConfig, maxColor)
        bar2._setupDone = true
      end
      bar2:SetValue(effectiveStacks, interp)
      bar2:Show()
    else
      local bar1 = barFrame.stackedBars[1]
      local interp = GetBarInterpolation(enableSmooth)
      if needsSetup or not bar1._setupDone then
        bar1:SetOrientation(barOrientation)
        bar1:SetReverseFill(isBarReverseFill)
        bar1:SetRotatesTexture(rotateBarTex)
        bar1:SetStatusBarTexture(texturePath)
        bar1:SetFrameLevel(barFrame:GetFrameLevel() + 1)
        ApplyBarSmoothing(bar1, enableSmooth)
        bar1:ClearAllPoints()
        bar1:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
        bar1:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
        bar1:SetMinMaxValues(0, maxStacks, interp)
        bar1:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
        ApplyBarGradient(bar1, barConfig, baseColor)
        bar1._setupDone = true
      end
      bar1:SetValue(effectiveStacks, interp)
      bar1:Show()
      barFrame.stackedBars[2]:Hide()
    end
  end
  
  -- Update text (SetText handles secret values!)
  if barConfig.display.showText then
    if showPreview then
      textFrame.text:SetText(effectiveStacks)
    else
      textFrame.text:SetText(stacks)
    end
    local tc = barConfig.display.textColor
    textFrame.text:SetTextColor(tc.r, tc.g, tc.b, tc.a)
  end
  
  -- Update duration text (pass secret value directly from GetText/GetValue to SetText)
  if barConfig.display.showDuration and durationFrame then
    -- durationFontString can be either:
    -- 1. A FontString reference (from icon source) - use GetText()
    -- 2. A StatusBar reference (from bar source) - use GetValue()
    -- 3. A wrapper object with GetAuraInfo() for direct API access
    -- 4. A wrapper object with GetText() for cooldownCharge passthrough
    
    local shouldHide = false
    local durationValue = nil
    local decimals = barConfig.display.durationDecimals or 1
    
    -- Store decimals on frame for OnUpdate access
    durationFrame.storedDecimals = decimals
    
    if showPreview then
      -- Preview mode - show sample duration value, clear OnUpdate
      durationFrame:SetScript("OnUpdate", nil)
      durationFrame.isActive = false
      durationFrame.sourceBar = nil
      
      local maxDuration = barConfig.tracking.maxDuration or 30
      local pct = previewStacks or 0.5
      local previewDurationValue = maxDuration * pct
      durationValue = string_format(DURATION_FMT[decimals] or "%.1f", previewDurationValue)
    elseif durationFontString and durationFontString.GetAuraInfo then
      -- Has GetAuraInfo - use DurationObject for auto-updating countdown text
      local auraID, unit = durationFontString:GetAuraInfo()
      if auraID and unit and active then
        -- Store current aura info for OnUpdate
        durationFrame.sourceBar = durationFontString
        durationFrame.isActive = true

        -- Set up OnUpdate to poll GetRemainingDuration() with fresh DurationObject
        if not durationFrame.durationOnUpdate then
          durationFrame.durationOnUpdate = function(self, elapsed)
            self.elapsed = (self.elapsed or 0) + elapsed
            if self.elapsed < 0.05 then return end  -- 20fps
            self.elapsed = 0

            if not self.isActive or not self.sourceBar then
              self:SetScript("OnUpdate", nil)
              self.text:SetText("")
              self:Hide()
              return
            end

            local currentAuraID, currentUnit = self.sourceBar:GetAuraInfo()
            if not currentAuraID or not currentUnit then
              self:SetScript("OnUpdate", nil)
              self.isActive = false
              self.sourceBar = nil
              self.text:SetText("")
              self:Hide()
              return
            end

            local durObj = C_UnitAuras.GetAuraDuration(currentUnit, currentAuraID)
            if durObj then
              self.text:SetFormattedText(DURATION_FMT[self.storedDecimals] or "%.1f", durObj:GetRemainingDuration())
            else
              self:SetScript("OnUpdate", nil)
              self.isActive = false
              self.sourceBar = nil
              self.text:SetText("")
              self:Hide()
            end
          end
        end
        durationFrame:SetScript("OnUpdate", durationFrame.durationOnUpdate)

        -- Initial text set — no pcall, GetAuraDuration returns nil safely
        local durObj = C_UnitAuras.GetAuraDuration(unit, auraID)
        if durObj then
          durationFrame.text:SetFormattedText(DURATION_FMT[decimals] or "%.1f", durObj:GetRemainingDuration())
        end
        
        local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}
        durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
        durationFrame:Show()
      elseif not active then
        -- Not active - clear OnUpdate, show for options preview or user preference
        durationFrame:SetScript("OnUpdate", nil)
        durationFrame.isActive = false
        durationFrame.sourceBar = nil
        
        if optionsOpen then
          durationValue = string_format(DURATION_FMT[decimals] or "%.1f", 0)
        elseif barConfig.display.durationShowWhenReady then
          durationValue = string_format(DURATION_FMT[decimals] or "%.1f", 0)
        else
          shouldHide = true
        end
      else
        durationFrame:SetScript("OnUpdate", nil)
        durationFrame.isActive = false
        durationFrame.sourceBar = nil
        shouldHide = true
      end
    elseif durationFontString and durationFontString.GetValue then
      -- It's a StatusBar or wrapper - pass value directly to SetText (secret-safe)
      durationFrame:SetScript("OnUpdate", nil)
      durationFrame.isActive = false
      durationFrame.sourceBar = nil
      
      if active then
        durationFrame.text:SetText(durationFontString:GetValue())
        local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}
        durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
        durationFrame:Show()
      else
        -- Not active - show for options preview, otherwise check user preference
        if optionsOpen then
          durationValue = string_format(DURATION_FMT[decimals] or "%.1f", 0)
        elseif barConfig.display.durationShowWhenReady then
          durationValue = string_format(DURATION_FMT[decimals] or "%.1f", 0)
        else
          shouldHide = true
        end
      end
    elseif durationFontString and durationFontString.GetText then
      -- It's a FontString or wrapper - use GetText
      durationFrame:SetScript("OnUpdate", nil)
      durationFrame.isActive = false
      durationFrame.sourceBar = nil
      
      -- GetText can return secret values during combat - can't compare them!
      -- But we CAN check IsShown() which is non-secret
      
      -- Check if the source is visible (non-secret check)
      local sourceShown = false  -- Default to false (hidden)
      if durationFontString.IsShown then
        sourceShown = durationFontString:IsShown()
      end
      
      if sourceShown then
        -- Source is showing duration - pass directly to SetText (whitelisted)
        durationFrame.text:SetText(durationFontString:GetText())
        local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}
        durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
        durationFrame:Show()
      else
        -- Source is hidden (spell ready/not on cooldown)
        if optionsOpen then
          -- Show for options preview
          durationFrame.text:SetText("0")
          local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}
          durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
          durationFrame:Show()
        elseif barConfig.display.durationShowWhenReady then
          -- User wants to show "0" when ready
          durationFrame.text:SetText("0")
          local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}
          durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
          durationFrame:Show()
        else
          -- Default: hide when ready
          durationFrame:Hide()
        end
      end
    else
      -- No duration source - clear OnUpdate
      durationFrame:SetScript("OnUpdate", nil)
      durationFrame.isActive = false
      durationFrame.sourceBar = nil
      
      if optionsOpen then
        durationValue = "0"
      elseif barConfig.display.durationShowWhenReady then
        durationValue = "0"
      else
        shouldHide = true
      end
    end
    
    -- Apply show/hide and text (only for non-FontString sources)
    if shouldHide then
      durationFrame:Hide()
    elseif durationValue then
      durationFrame.text:SetText(durationValue)
      local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}
      durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
      durationFrame:Show()
    end
  end
  
  -- Update tick marks - only needed when config changes
  if needsSetup then
    UpdateTickMarks(barFrame, barConfig, maxStacks, displayMode)
  end

  -- Bar icon - only setup when config changes
  if needsSetup and barConfig.display.showBarIcon and barIconFrame then
    -- Set icon texture
    if iconTexture then
      barIconFrame.icon:SetTexture(iconTexture)
    elseif barConfig.tracking.iconTextureID then
      barIconFrame.icon:SetTexture(barConfig.tracking.iconTextureID)
    elseif barConfig.tracking.spellID then
      local texture = C_Spell.GetSpellTexture(barConfig.tracking.spellID)
      if texture then
        barIconFrame.icon:SetTexture(texture)
      end
    end
    
    -- Border
    if barConfig.display.barIconShowBorder then
      local bc = barConfig.display.barIconBorderColor or {r=0, g=0, b=0, a=1}
      barIconFrame.background:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
      barIconFrame.background:Show()
    else
      barIconFrame.background:Hide()
    end
    
    barIconFrame:Show()
  elseif barIconFrame then
    barIconFrame:Hide()
  end
  
  -- Visibility already determined at function start - just show/hide based on that
  if shouldShow and barConfig.display.enabled then
    barFrame:Show()
    if barConfig.display.showText then
      textFrame:Show()
    else
      textFrame:Hide()
    end
    if barConfig.display.showName and nameFrame then
      nameFrame:Show()
    end
    if barConfig.display.showBarIcon and barIconFrame then
      barIconFrame:Show()
    end
  else
    barFrame:Hide()
    textFrame:Hide()
    if durationFrame then durationFrame:Hide() end
    if nameFrame then nameFrame:Hide() end
    if barIconFrame then barIconFrame:Hide() end
  end
end

-- ===================================================================
-- HIDE SPECIFIC BAR
-- ===================================================================
function ns.Display.HideBar(barNumber)
  -- Early exit if frames don't exist or are already hidden
  -- This prevents redundant work when called repeatedly by the ticker
  if not barFrames[barNumber] then
      return
  end
  
  -- Check if ALL frames are already hidden (icon, bar, text, duration)
  -- FIXED: Must include textFrame and durationFrame in the check to prevent ghost "0" text
  local frames = barFrames[barNumber]
  local iconFrame = frames.iconFrame
  local barFrame = frames.barFrame
  local textFrame = frames.textFrame
  local durationFrame = frames.durationFrame
  
  local iconHidden = not iconFrame or not iconFrame:IsShown()
  local barHidden = not barFrame or not barFrame:IsShown()
  local textHidden = not textFrame or not textFrame:IsShown()
  local durationHidden = not durationFrame or not durationFrame:IsShown()
  local nameHidden = not frames.nameFrame or not frames.nameFrame:IsShown()
  local barIconHidden = not frames.barIconFrame or not frames.barIconFrame:IsShown()
  
  -- Only skip if ALL frames are hidden
  if iconHidden and barHidden and textHidden and durationHidden and nameHidden and barIconHidden then
    return  -- Already hidden, no work needed
  end
  

  
  if barFrames[barNumber] then
    barFrames[barNumber].barFrame:Hide()
    barFrames[barNumber].textFrame:Hide()
    
    -- Clear text values to prevent stale "0" showing
    if barFrames[barNumber].textFrame.text then
      barFrames[barNumber].textFrame.text:SetText("")
    end
    
    if barFrames[barNumber].durationFrame then
      barFrames[barNumber].durationFrame:Hide()
      if barFrames[barNumber].durationFrame.text then
        barFrames[barNumber].durationFrame.text:SetText("")
      end
    end
    if barFrames[barNumber].iconFrame then
      barFrames[barNumber].iconFrame:Hide()
      -- CRITICAL: Also hide child textures explicitly
      -- In some edge cases, child textures can remain visible even when parent is hidden
      if barFrames[barNumber].iconFrame.icon then
        barFrames[barNumber].iconFrame.icon:Hide()
      end
      if barFrames[barNumber].iconFrame.background then
        barFrames[barNumber].iconFrame.background:Hide()
      end
      if barFrames[barNumber].iconFrame.cooldown then
        barFrames[barNumber].iconFrame.cooldown:Hide()
      end
      -- Clear icon frame text elements
      if barFrames[barNumber].iconFrame.stacks then
        barFrames[barNumber].iconFrame.stacks:SetText("")
      end
      if barFrames[barNumber].iconFrame.duration then
        barFrames[barNumber].iconFrame.duration:SetText("")
      end
      if barFrames[barNumber].iconFrame.stacksFrame and barFrames[barNumber].iconFrame.stacksFrame.text then
        barFrames[barNumber].iconFrame.stacksFrame.text:SetText("")
      end
    end
    if barFrames[barNumber].nameFrame then
      barFrames[barNumber].nameFrame:Hide()
      if barFrames[barNumber].nameFrame.text then
        barFrames[barNumber].nameFrame.text:SetText("")
      end
    end
    if barFrames[barNumber].barIconFrame then
      barFrames[barNumber].barIconFrame:Hide()
    end
  end
  -- Also hide multi-icon frames
  HideMultiIconFrames(barNumber)
end

-- ===================================================================
-- DELETE CONFIRMATION DIALOG
-- ===================================================================
local deleteConfirmFrame = nil

ShowDeleteConfirmation = function(barNumber, barType)
  barType = barType or "buff"
  
  if not deleteConfirmFrame then
    deleteConfirmFrame = CreateFrame("Frame", "ArcUIDeleteConfirm", UIParent, "BackdropTemplate")
    deleteConfirmFrame:SetSize(300, 120)
    deleteConfirmFrame:SetFrameStrata("TOOLTIP")
    deleteConfirmFrame:SetToplevel(true)
    deleteConfirmFrame:SetFrameLevel(9999)
    deleteConfirmFrame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
    deleteConfirmFrame:SetBackdropColor(0.1, 0.1, 0.1, 1)
    deleteConfirmFrame:EnableMouse(true)
    deleteConfirmFrame:SetMovable(true)
    deleteConfirmFrame:RegisterForDrag("LeftButton")
    deleteConfirmFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    deleteConfirmFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    deleteConfirmFrame:SetClampedToScreen(true)
    
    deleteConfirmFrame.title = deleteConfirmFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    deleteConfirmFrame.title:SetPoint("TOP", 0, -16)
    deleteConfirmFrame.title:SetText("Delete Bar?")
    
    deleteConfirmFrame.text = deleteConfirmFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    deleteConfirmFrame.text:SetPoint("TOP", 0, -40)
    deleteConfirmFrame.text:SetWidth(260)
    
    deleteConfirmFrame.deleteBtn = CreateFrame("Button", nil, deleteConfirmFrame, "UIPanelButtonTemplate")
    deleteConfirmFrame.deleteBtn:SetSize(100, 24)
    deleteConfirmFrame.deleteBtn:SetPoint("BOTTOMLEFT", 30, 16)
    deleteConfirmFrame.deleteBtn:SetText("Delete")
    
    deleteConfirmFrame.cancelBtn = CreateFrame("Button", nil, deleteConfirmFrame, "UIPanelButtonTemplate")
    deleteConfirmFrame.cancelBtn:SetSize(100, 24)
    deleteConfirmFrame.cancelBtn:SetPoint("BOTTOMRIGHT", -30, 16)
    deleteConfirmFrame.cancelBtn:SetText("Cancel")
    deleteConfirmFrame.cancelBtn:SetScript("OnClick", function() deleteConfirmFrame:Hide() end)
  end
  
  -- Get bar name for display
  local barName = "Bar " .. barNumber
  local cfg = ns.API and ns.API.GetBarConfig and ns.API.GetBarConfig(barNumber)
  if cfg and cfg.tracking then
    if cfg.tracking.buffName and cfg.tracking.buffName ~= "" then
      barName = cfg.tracking.buffName
    elseif cfg.tracking.spellName and cfg.tracking.spellName ~= "" then
      barName = cfg.tracking.spellName
    end
  end
  
  deleteConfirmFrame.text:SetText(string.format("Delete %s?", barName))
  deleteConfirmFrame.deleteBtn:SetScript("OnClick", function()
    ns.Display.DeleteBar(barNumber)
    deleteConfirmFrame:Hide()
  end)
  
  deleteConfirmFrame:ClearAllPoints()
  deleteConfirmFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
  deleteConfirmFrame:Raise()
  deleteConfirmFrame:Show()
end

-- Expose for external use
ns.Display.ShowDeleteConfirmation = ShowDeleteConfirmation

-- ===================================================================
-- DELETE BAR (Clear config and hide)
-- ===================================================================
function ns.Display.DeleteBar(barNumber)
  local cfg = ns.API and ns.API.GetBarConfig and ns.API.GetBarConfig(barNumber)
  if cfg then
    -- Get fresh defaults for a complete reset
    local defaults = ns.DB_DEFAULTS and ns.DB_DEFAULTS.char and ns.DB_DEFAULTS.char.bars and ns.DB_DEFAULTS.char.bars[1]
    
    if defaults then
      -- Fully reset tracking config to defaults
      if defaults.tracking then
        for k, v in pairs(defaults.tracking) do
          if type(v) == "table" then
            cfg.tracking[k] = CopyTable(v)
          else
            cfg.tracking[k] = v
          end
        end
      end
      cfg.tracking.enabled = false  -- Make sure it's disabled
      
      -- Fully reset display config to defaults
      if defaults.display then
        for k, v in pairs(defaults.display) do
          if type(v) == "table" then
            cfg.display[k] = CopyTable(v)
          else
            cfg.display[k] = v
          end
        end
      end
      cfg.display.enabled = false  -- Make sure it's disabled
      
      -- Fully reset behavior config to defaults
      if defaults.behavior then
        for k, v in pairs(defaults.behavior) do
          if type(v) == "table" then
            cfg.behavior[k] = CopyTable(v)
          else
            cfg.behavior[k] = v
          end
        end
      end
      
      -- Reset events if present
      if defaults.events then
        cfg.events = CopyTable(defaults.events)
      else
        cfg.events = {}
      end
      
      -- Clear migration flag so settings are re-migrated if needed
      cfg._migrated = nil
    else
      -- Fallback: just clear tracking config (legacy behavior)
      cfg.tracking.enabled = false
      cfg.tracking.trackType = "buff"
      cfg.tracking.cooldownID = 0
      cfg.tracking.spellID = 0
      cfg.tracking.spellName = ""
      cfg.tracking.buffName = ""
      cfg.tracking.maxStacks = 10
      cfg.tracking.iconTextureID = 0
      cfg.tracking.auraInstanceID = 0
      cfg.tracking.slotNumber = 0
      cfg.display.enabled = false
    end
    
    -- Hide the bar (this will hide ALL frames including icons)
    ns.Display.HideBar(barNumber)
    

      
    -- Refresh options panel
    if LibStub and LibStub("AceConfigRegistry-3.0", true) then
      LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
    end
  end
end

-- ===================================================================
-- SHOW/HIDE DELETE BUTTONS ON ALL BARS
-- Only visible when options panel is open
-- ===================================================================

function ns.Display.ShowDeleteButtons()
  deleteButtonsVisible = true
  for barNumber, frames in pairs(barFrames) do
    if frames then
      -- Show on barFrame if visible and has delete button
      local barFrame = frames.barFrame
      if barFrame and barFrame:IsShown() and barFrame.deleteButton then
        barFrame.deleteButton:Show()
      end
      -- Show on iconFrame if visible and has delete button  
      local iconFrame = frames.iconFrame
      if iconFrame and iconFrame:IsShown() and iconFrame.deleteButton then
        iconFrame.deleteButton:Show()
      end
    end
  end
end

function ns.Display.HideDeleteButtons()
  deleteButtonsVisible = false
  for barNumber, frames in pairs(barFrames) do
    if frames then
      local barFrame = frames.barFrame
      if barFrame and barFrame.deleteButton then
        barFrame.deleteButton:Hide()
      end
      local iconFrame = frames.iconFrame
      if iconFrame and iconFrame.deleteButton then
        iconFrame.deleteButton:Hide()
      end
    end
  end
end

function ns.Display.AreDeleteButtonsVisible()
  return deleteButtonsVisible
end

-- ===================================================================
-- UPDATE CUSTOM BAR (Cast-based tracking with duration countdown)
-- ===================================================================
function ns.Display.UpdateDurationBar(barNumber, stacks, maxStacks, active, sourceBar, stacksFontString, iconTexture, auraName, cachedConfig)
  -- PROFILER: Track where time is spent
  local PM = ns.ProfilerMark
  if PM then PM("GetBarConfig") end

  local barConfig = cachedConfig or ns.API.GetBarConfig(barNumber)
  if not barConfig or not barConfig.tracking.enabled then
    if barFrames[barNumber] then
      barFrames[barNumber].barFrame:Hide()
      barFrames[barNumber].textFrame:Hide()
      if barFrames[barNumber].durationFrame then
        barFrames[barNumber].durationFrame:Hide()
      end
      if barFrames[barNumber].iconFrame then
        barFrames[barNumber].iconFrame:Hide()
      end
      if barFrames[barNumber].nameFrame then
        barFrames[barNumber].nameFrame:Hide()
      end
      if barFrames[barNumber].barIconFrame then
        barFrames[barNumber].barIconFrame:Hide()
      end
    end
    return
  end
  
  -- FLICKERING FIX: Skip real tracking updates when preview mode is active
  -- When previewMode is on, only allow updates from SetPreviewStacks (no sourceBar)
  if previewMode and IsOptionsOpen() and sourceBar then
    return  -- Skip real tracking update, let preview control the display
  end
  
  if PM then PM("VisibilityChecks") end
  
  -- ═══════════════════════════════════════════════════════════════════════════
  -- PERFORMANCE: Cache expensive lookups ONCE at start of function
  -- ═══════════════════════════════════════════════════════════════════════════
  local optionsOpen = IsOptionsOpen()
  local currentSpec = GetCachedSpec()
  
  -- ═══════════════════════════════════════════════════════════════════════════
  -- EARLY VISIBILITY CHECK: Skip all work if bar shouldn't be visible
  -- This uses cached spec and avoids redundant calculations later
  -- ═══════════════════════════════════════════════════════════════════════════
  local shouldShow = true
  
  -- Spec check (most common reason to hide)
  local deactivate = false
  if barConfig.behavior and barConfig.behavior.showOnSpecs and #barConfig.behavior.showOnSpecs > 0 then
    shouldShow = false
    for _, spec in ipairs(barConfig.behavior.showOnSpecs) do
      if spec == currentSpec then
        shouldShow = true
        break
      end
    end
    if not shouldShow then deactivate = true end
  end
  
  -- Talent conditions check
  if shouldShow and ns.TrackingOptions and ns.TrackingOptions.AreTalentConditionsMet then
    if not ns.TrackingOptions.AreTalentConditionsMet(barConfig) then
      shouldShow = false
      deactivate = true
    end
  end
  
  -- Hide When conditions (only if not in options - we want to show bars for editing)
  local hideWhenFadeAlpha = 1.0
  if shouldShow and not optionsOpen and ns.CooldownBars and ns.CooldownBars.GetHideWhen then
    local hideWhen = ns.CooldownBars.GetHideWhen(barConfig)
    if hideWhen and ns.CooldownBars.EvaluateHideConditions(hideWhen, barConfig.behavior and barConfig.behavior.hideLogic) then
      local hAlpha = ns.CooldownBars.GetHideWhenAlpha(barConfig)
      if hAlpha <= 0 then
        shouldShow = false
      else
        hideWhenFadeAlpha = hAlpha
      end
    end
  end
  if barFrames[barNumber] then barFrames[barNumber]._arcHideWhenAlpha = hideWhenFadeAlpha end
  
  -- Inactive check (if hideWhenInactive and not active, but show in options for editing)
  if shouldShow and not optionsOpen and not active and barConfig.behavior and barConfig.behavior.hideWhenInactive then
    shouldShow = false
  end
  
  -- Early exit if bar shouldn't show and options not open
  if not shouldShow and not optionsOpen then
    if deactivate then
      DeactivateBar(barNumber)
    else
      if barFrames[barNumber] then
        barFrames[barNumber].barFrame:Hide()
        barFrames[barNumber].textFrame:Hide()
        if barFrames[barNumber].durationFrame then
          barFrames[barNumber].durationFrame:Hide()
        end
        if barFrames[barNumber].iconFrame then
          barFrames[barNumber].iconFrame:Hide()
        end
        if barFrames[barNumber].nameFrame then
          barFrames[barNumber].nameFrame:Hide()
        end
        if barFrames[barNumber].barIconFrame then
          barFrames[barNumber].barIconFrame:Hide()
        end
      end
    end
    return
  end
  
  -- Bar is active — ensure it's not flagged as deactivated
  ReactivateBar(barNumber)
  
  if PM then PM("GetBarFrames") end
  
  local barFrame, textFrame, durationFrame, iconFrame, nameFrame, barIconFrame = GetBarFrames(barNumber)
  local displayType = barConfig.display.displayType or "bar"
  
  if PM then PM("OptionsValidation") end
  
  -- Config validation and overlay logic (only matters when options open)
  if optionsOpen then
    local tracking = barConfig.tracking
    local hasSpellIdentification = (tracking.spellID and tracking.spellID > 0) or 
                                    (tracking.cooldownID and tracking.cooldownID > 0) or 
                                    (tracking.buffName and tracking.buffName ~= "")
    local hasTrackType = tracking.trackType and tracking.trackType ~= "" and tracking.trackType ~= "none"
    local isProperlyConfigured = hasSpellIdentification and hasTrackType
    
    if not isProperlyConfigured then
      if displayType == "icon" then
        barFrame:Hide()
        textFrame:Hide()
        if durationFrame then durationFrame:Hide() end
        if nameFrame then nameFrame:Hide() end
        if barIconFrame then barIconFrame:Hide() end
        
        iconFrame:Show()
        if iconFrame.missingSetupOverlay then
          iconFrame.missingSetupOverlay:Show()
        end
        if iconFrame.trackingFailOverlay then iconFrame.trackingFailOverlay:Hide() end
        if iconFrame.stacksFrame then iconFrame.stacksFrame:Hide() end
        iconFrame.stacks:Hide()
      else
        iconFrame:Hide()
        if iconFrame.stacksFrame then iconFrame.stacksFrame:Hide() end
        textFrame:Hide()
        if durationFrame then durationFrame:Hide() end
        if nameFrame then nameFrame:Hide() end
        if barIconFrame then barIconFrame:Hide() end
        
        barFrame:Show()
        if barFrame.missingSetupOverlay then
          barFrame.missingSetupOverlay:Show()
        end
        if barFrame.trackingFailOverlay then barFrame.trackingFailOverlay:Hide() end
      end
      return
    end
    
    -- Tracking fail overlay (only when options open)
    local trackingOK = ns.API.IsTrackingOK and ns.API.IsTrackingOK(barNumber)
    if not trackingOK and barConfig.tracking.cooldownID and barConfig.tracking.cooldownID > 0 then
      if displayType == "icon" then
        barFrame:Hide()
        textFrame:Hide()
        durationFrame:Hide()
        if nameFrame then nameFrame:Hide() end
        if barIconFrame then barIconFrame:Hide() end
        
        iconFrame:Show()
        if iconFrame.trackingFailOverlay then
          iconFrame.trackingFailOverlay:Show()
        end
        if iconFrame.stacksFrame then iconFrame.stacksFrame:Hide() end
        iconFrame.stacks:Hide()
      else
        iconFrame:Hide()
        if iconFrame.stacksFrame then iconFrame.stacksFrame:Hide() end
        textFrame:Hide()
        durationFrame:Hide()
        if nameFrame then nameFrame:Hide() end
        if barIconFrame then barIconFrame:Hide() end
        
        barFrame:Show()
        if barFrame.trackingFailOverlay then
          barFrame.trackingFailOverlay:Show()
        end
      end
      return
    end
  end
  
  -- Hide overlays (they were only shown when options open + error condition)
  if barFrame.missingSetupOverlay then
    barFrame.missingSetupOverlay:Hide()
  end
  if iconFrame and iconFrame.missingSetupOverlay then
    iconFrame.missingSetupOverlay:Hide()
  end
  if barFrame.trackingFailOverlay then
    barFrame.trackingFailOverlay:Hide()
  end
  if iconFrame and iconFrame.trackingFailOverlay then
    iconFrame.trackingFailOverlay:Hide()
  end
  
  maxStacks = tonumber(maxStacks) or 10
  if maxStacks < 1 then maxStacks = 10 end
  stacks = stacks or 0
  
  -- ═══════════════════════════════════════════════════════════════════
  -- ICON MODE (Duration)
  -- ═══════════════════════════════════════════════════════════════════
  if displayType == "icon" then
    barFrame:Hide()
    textFrame:Hide()
    durationFrame:Hide()
    if nameFrame then nameFrame:Hide() end
    if barIconFrame then barIconFrame:Hide() end
    
    local cfg = barConfig.display
    
    -- Set icon texture
    if iconTexture then
      iconFrame.icon:SetTexture(iconTexture)
    elseif barConfig.tracking.iconTextureID then
      iconFrame.icon:SetTexture(barConfig.tracking.iconTextureID)
    elseif barConfig.tracking.spellID then
      local texture = C_Spell.GetSpellTexture(barConfig.tracking.spellID)
      if texture then
        iconFrame.icon:SetTexture(texture)
      end
    end
    
    -- Apply icon zoom
    local zoom = cfg.iconZoom or 0
    local minCoord = 0.08 + (zoom * 0.42)
    local maxCoord = 0.92 - (zoom * 0.42)
    iconFrame.icon:SetTexCoord(minCoord, maxCoord, minCoord, maxCoord)
    
    -- SAFETY: Also verify bar is enabled (prevents ghost icons from deleted bars)
    if cfg.iconShowTexture == false or not barConfig.tracking.enabled then
      iconFrame.icon:Hide()
      iconFrame.background:Hide()
    else
      iconFrame.icon:Show()
    end
    
    -- Update stacks text (use secret value from stacksFontString if available)
    if cfg.iconShowStacks then
      local stackAnchor = cfg.iconStackAnchor or "TOPRIGHT"
      local stackText
      local sc = cfg.iconStackColor or {r=1, g=1, b=1, a=1}
      
      if stackAnchor == "FREE" then
        stackText = iconFrame.stacksFrame.text
        iconFrame.stacks:Hide()
        iconFrame.stacksFrame:Show()
      else
        stackText = iconFrame.stacks
        iconFrame.stacksFrame:Hide()
        iconFrame.stacks:Show()
      end
      
      -- Use stacks from auraInstanceID (passed as secret value) or stacksFontString
      if active and stacksFontString and stacksFontString.GetText then
        stackText:SetText(stacksFontString:GetText())
      elseif active and stacks then
        stackText:SetText(stacks)
      else
        -- Not active - show empty for duration icons
        stackText:SetText("")
      end
      stackText:SetTextColor(sc.r, sc.g, sc.b, sc.a)
    else
      iconFrame.stacks:Hide()
      iconFrame.stacksFrame:Hide()
    end
    
    -- Update duration (use C_UnitAuras.GetAuraDurationRemaining for secret-safe text)
    -- Use cached optionsOpen from function start
    local showPreview = optionsOpen and (not active or previewMode)
    
    if cfg.iconShowDuration then
      if showPreview then
        -- Preview mode - show sample duration
        local maxDuration = barConfig.tracking.maxDuration or 30
        local pct = previewStacks or 0.5
        local previewValue = maxDuration * pct
        local decimals = cfg.durationDecimals or 1
        iconFrame.duration:SetText(string_format(DURATION_FMT[decimals] or "%.1f", previewValue))
        iconFrame.duration:Show()
      elseif active and sourceBar and sourceBar.GetAuraInfo then
        -- Has GetAuraInfo - use C_UnitAuras.GetAuraDurationRemaining for secret-safe text
        local auraID, unit = sourceBar:GetAuraInfo()
        if auraID and unit then
          -- Validate aura exists before GetAuraDurationRemaining (stale id is the crash risk)
          local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraID)
          if auraData then
            iconFrame.duration:SetText(C_UnitAuras.GetAuraDurationRemaining(unit, auraID))  -- Secret passes directly to SetText
          elseif sourceBar.GetValue then
            iconFrame.duration:SetText(sourceBar:GetValue())
          end
        elseif sourceBar.GetValue then
          iconFrame.duration:SetText(sourceBar:GetValue())
        end
        iconFrame.duration:Show()
      elseif active and sourceBar and sourceBar.GetValue then
        -- Fallback: pass raw value through (secret-safe via SetText)
        iconFrame.duration:SetText(sourceBar:GetValue())
        iconFrame.duration:Show()
      else
        -- Not active - hide duration
        iconFrame.duration:SetText("")
        iconFrame.duration:Hide()
      end
      local dc = cfg.iconDurationColor or {r=1, g=1, b=1, a=1}
      iconFrame.duration:SetTextColor(dc.r, dc.g, dc.b, dc.a)
    else
      iconFrame.duration:Hide()
    end
    
    -- Border
    if cfg.iconShowBorder then
      local bc = cfg.iconBorderColor or {r=0, g=0, b=0, a=1}
      iconFrame.background:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
      iconFrame.background:Show()
    else
      iconFrame.background:Hide()
    end
    
    -- Visibility already determined at function start - just show if enabled
    if shouldShow and cfg.enabled then
      iconFrame:Show()
      iconFrame:SetAlpha(1)  -- Always full opacity for duration icons
    else
      iconFrame:Hide()
    end
    
    return
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- BAR MODE (Duration) - SECRET VALUE PASSTHROUGH
  -- Mirrors ArcUI_Resources.lua UpdateThresholdLayers EXACTLY
  -- ═══════════════════════════════════════════════════════════════════
  SafeHide(iconFrame)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- HIDE ALL EXISTING BARS FIRST (like resource bar does)
  -- ═══════════════════════════════════════════════════════════════════
  SafeHide(barFrame.bar)
  
  if barFrame.stackedBars then
    for i = 1, #barFrame.stackedBars do SafeHide(barFrame.stackedBars[i]) end
  end
  if barFrame.granularBars then
    for i = 1, #barFrame.granularBars do SafeHide(barFrame.granularBars[i]) end
  end
  if barFrame.durationGranularBars then
    for i = 1, #barFrame.durationGranularBars do SafeHide(barFrame.durationGranularBars[i]) end
  end
  if barFrame.durationLayers then
    for i = 1, #barFrame.durationLayers do SafeHide(barFrame.durationLayers[i]) end
  end
  if barFrame.durationStackedBars then
    for i = 1, #barFrame.durationStackedBars do SafeHide(barFrame.durationStackedBars[i]) end
  end
  if barFrame.durationLayeredBars then
    for i = 1, #barFrame.durationLayeredBars do SafeHide(barFrame.durationLayeredBars[i]) end
  end
  
  -- Get base color from config
  local baseColor = barConfig.display.barColor or {r=0, g=0.5, b=1, a=1}
  
  -- Get orientation settings for duration bar
  local isDurationVertical = (barConfig.display.barOrientation == "vertical")
  local durationOrientation = isDurationVertical and "VERTICAL" or "HORIZONTAL"
  local rotateDurTex = (barConfig.display.rotateTexture == true) or (barConfig.display.rotateTexture ~= false and isDurationVertical)
  -- Timer direction handles drain/fill behavior:
  -- - Drain: RemainingTime (bar shrinks as time passes)
  -- - Fill: ElapsedTime (bar grows as time passes)
  -- ReverseFill controls anchor direction (left-to-right vs right-to-left)
  local fillMode = barConfig.display.durationBarFillMode or "drain"
  local isDurationReverseFill = barConfig.display.barReverseFill or false
  
  -- Get max duration from user config (always use this for consistency)
  -- Ensure maxValue is at least 1 for preview mode calculations
  local maxValue = barConfig.tracking.maxDuration or 30
  if maxValue <= 0 then maxValue = 30 end  -- Fallback for "auto" or invalid values
  
  -- Use cached optionsOpen from function start
  local showPreview = optionsOpen and (not active or previewMode)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- COLORCURVE SUPPORT (v2.9.0 - Simplified)
  -- When enabled: bar fill color changes based on remaining duration %
  -- No trick needed - just evaluate curve and apply color to bar
  -- ═══════════════════════════════════════════════════════════════════
  local colorCurve = GetDurationColorCurve(barNumber, barConfig)
  local useColorCurve = colorCurve ~= nil and barConfig.display.durationColorCurveEnabled
  
  if PM then PM("AppearanceSetup") end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- PERFORMANCE: Only run expensive bar setup when appearance changes
  -- Uses _configVersion (bumped by BumpConfigVersion) instead of hashing
  -- ═══════════════════════════════════════════════════════════════════
  local currentConfigVersion = barConfig._configVersion or 0
  local needsSetup = barFrame._lastConfigVersion ~= currentConfigVersion
  
  if needsSetup then
    -- Get texture (use global LSM from top of file) - only when needed
    local texturePath = "Interface\\TargetingFrame\\UI-StatusBar"
    if LSM and barConfig.display.texture then
      local fetchedTexture = LSM:Fetch("statusbar", barConfig.display.texture)
      if fetchedTexture then
        texturePath = fetchedTexture
      end
    end
    
    -- Apply expensive bar setup (padding always 0 - no UI option exposed)
    barFrame.bar:ClearAllPoints()
    barFrame.bar:SetAllPoints(barFrame)
    barFrame.bar:SetStatusBarTexture(texturePath)
    -- Note: Frame level is set by the strata block later, but set baseline here
    -- Fill bar should be 1 level above parent (background is at parent level)
    barFrame.bar:SetFrameLevel(barFrame:GetFrameLevel() + 1)
    
    -- Apply user's fill direction settings
    barFrame.bar:SetOrientation(durationOrientation)
    barFrame.bar:SetReverseFill(isDurationReverseFill)
    -- Rotate texture only when vertical (keeps texture pattern correct for horizontal)
    barFrame.bar:SetRotatesTexture(rotateDurTex)
    
    -- Background visibility - respects showBackground setting
    if barFrame.bg then
      barFrame.bg:SetShown(barConfig.display.showBackground)
    end
    
    -- Cache the version — only when options closed so live config changes keep triggering needsSetup
    if not optionsOpen then
      barFrame._lastConfigVersion = currentConfigVersion
    end
  end
  
  -- NOTE: We don't set bar:SetAlpha(1) here - each code path sets alpha
  -- AFTER applying color to prevent flicker when base color has alpha 0
  
  -- Hide legacy colorCurveBg if it exists (no longer used)
  if barFrame.colorCurveBg then
    barFrame.colorCurveBg:Hide()
  end
  
  if PM then PM("BarValueHandling") end
  
  -- Get duration bar interpolation (used by multiple branches below)
  local durationInterp = GetBarInterpolation(barConfig.display.enableSmoothing)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- BAR VALUE AND COLOR HANDLING
  -- SetStatusBarColor accepts secret values - pass colorResult:GetRGBA() directly
  -- Gradient is skipped when using ColorCurve (requires non-secret arithmetic)
  -- ═══════════════════════════════════════════════════════════════════
  if showPreview then
    -- Preview mode - manual value, clear OnUpdate
    barFrame.bar.colorCurveData = nil
    barFrame.bar:SetScript("OnUpdate", nil)
    UnregisterAuraPolling(barNumber)
    
    barFrame.bar:SetMinMaxValues(0, maxValue)
    local pct = previewStacks or 0.5
    local previewValue = maxValue * pct
    barFrame.bar:SetValue(previewValue)
    
    -- Apply bar color - SetStatusBarColor handles alpha directly for ColorCurve
    if useColorCurve and pct then
      -- Reset VertexColor in case it was tinted before
      local barTexture = barFrame.bar:GetStatusBarTexture()
      if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
      
      -- Preview mode: SetStatusBarColor with curve result (handles alpha correctly).
      -- pct is a non-secret preview number, so curve evaluation can't error here.
      local colorResult = colorCurve and colorCurve:Evaluate(pct)
      if colorResult then
        barFrame.bar:SetStatusBarColor(colorResult:GetRGBA())
      else
        barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      end
      -- Note: Gradient skipped when using ColorCurve (SetGradient doesn't accept secrets)
    else
      -- No ColorCurve - reset VertexColor and use SetStatusBarColor with gradient
      local barTexture = barFrame.bar:GetStatusBarTexture()
      if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
      barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      ApplyBarGradient(barFrame.bar, barConfig, baseColor)
    end
    -- Restore visibility after color is applied (prevents flicker)
    barFrame.bar:SetAlpha(1)
    barFrame.bar:Show()
    
  elseif active and sourceBar and sourceBar.GetTotemInfo then
    -- TOTEM DURATION BAR
    -- 12.0.5+: GetDurationObject() → GetTotemDuration(slot).
    -- GetTotemDuration returns nil when slot inactive, valid durObj when active.
    -- Use SetTimerDuration for bar animation (no polling needed) and
    -- GetRemainingDuration() in a text OnUpdate — same pattern as aura bars.
    if barFrame.bar.SetSmoothing then
      barFrame.bar:SetSmoothing(false)
    end

    -- Clear any legacy polling state
    barFrame.bar.totemPollingData = nil
    barFrame.bar:SetScript("OnUpdate", nil)

    local durObj = sourceBar:GetDurationObject()

    if durObj then
      local barTextureTotem = barFrame.bar:GetStatusBarTexture()
      if barTextureTotem then barTextureTotem:SetVertexColor(1, 1, 1, 1) end

      local fillMode = barConfig.display.durationBarFillMode or "drain"
      local timerDirection = (fillMode == "fill")
        and Enum.StatusBarTimerDirection.ElapsedTime
        or  Enum.StatusBarTimerDirection.RemainingTime

      barFrame.bar:SetMinMaxValues(0, 1)
      barFrame.bar:SetTimerDuration(durObj, Enum.StatusBarInterpolation.Linear, timerDirection)

      -- Duration text: poll GetRemainingDuration() on the fresh durObj each frame.
      -- GetTotemDuration returns nil (not a zero-span object) when slot gone,
      -- so `if durObj then` correctly gates the text update.
      local showDuration = barConfig.display.showDuration
      local decimals = barConfig.display.durationDecimals or 1
      local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}

      if durationFrame and showDuration then
        durationFrame.storedDecimals = decimals
        durationFrame.sourceBar = sourceBar
        durationFrame.isActive = true

        if not durationFrame.totemDurationOnUpdate then
          durationFrame.totemDurationOnUpdate = function(self, elapsed)
            self.elapsed = (self.elapsed or 0) + elapsed
            if self.elapsed < 0.1 then return end  -- 10 fps
            self.elapsed = 0
            if not self.isActive or not self.sourceBar then
              self:SetScript("OnUpdate", nil)
              self.text:SetText("")
              self:Hide()
              return
            end
            -- GetDurationObject returns nil when slot inactive (API returns nil, not zero-span)
            local currentDurObj = self.sourceBar:GetDurationObject()
            if currentDurObj then
              self.text:SetFormattedText(DURATION_FMT[self.storedDecimals] or "%.1f",
                currentDurObj:GetRemainingDuration())
            else
              self:SetScript("OnUpdate", nil)
              self.isActive = false
              self.sourceBar = nil
              self.text:SetText("")
              self:Hide()
            end
          end
        end

        durationFrame:SetScript("OnUpdate", durationFrame.totemDurationOnUpdate)
        durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
        durationFrame:Show()
      end

      barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      barFrame.bar:SetAlpha(1)
    else
      -- No duration object — slot inactive, clear everything
      UnregisterAuraPolling(barNumber)
      barFrame.bar:SetMinMaxValues(0, maxValue)
      barFrame.bar:SetValue(0)
      local barTexture = barFrame.bar:GetStatusBarTexture()
      if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
      barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      if durationFrame then
        durationFrame.isActive = false
        durationFrame.sourceBar = nil
        durationFrame:SetScript("OnUpdate", nil)
        durationFrame:Hide()
      end
      barFrame.bar:SetAlpha(1)
    end

    ApplyBarGradient(barFrame.bar, barConfig, baseColor)
    barFrame.bar:Show()
    
  elseif active and sourceBar and sourceBar.GetAuraInfo then
    -- AURA DURATION BAR
    local auraID, unit = sourceBar:GetAuraInfo()
    
    -- Disable legacy SetSmoothing - we use interpolation enum on SetValue instead
    -- AUTO mode: SetTimerDuration has its own interpolation param (inherently smooth)
    -- MANUAL MAX mode: SetValue gets durationInterp from enableSmoothing toggle
    if barFrame.bar.SetSmoothing then
      barFrame.bar:SetSmoothing(false)
    end
    
    if auraID and unit then
      -- Determine timer direction based on fillMode setting
      local fillMode = barConfig.display.durationBarFillMode or "drain"
      local timerDirection = (fillMode == "fill") 
        and Enum.StatusBarTimerDirection.ElapsedTime 
        or Enum.StatusBarTimerDirection.RemainingTime
      
      -- Check if user wants dynamic max (Auto) or manual max
      local useDynamicMax = barConfig.tracking.dynamicMaxDuration
      
      if useDynamicMax then
        -- AUTO MODE: Use SetTimerDuration for auto-animation (normalized 0-1).
        -- GetAuraDuration returns nil for gone auras and does not throw; validate the
        -- instance first so a stale id (the real crash risk) falls back cleanly.
        local durObj = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraID)
          and C_UnitAuras.GetAuraDuration(unit, auraID)
        if durObj then
          barFrame.bar:SetMinMaxValues(0, 1)
          barFrame.bar:SetTimerDuration(durObj, Enum.StatusBarInterpolation.ExponentialEaseOut, timerDirection)
        else
          barFrame.bar:SetMinMaxValues(0, maxValue)
          barFrame.bar:SetValue(sourceBar:GetValue(), durationInterp)
        end
        
        -- Apply color (with curve if enabled)
        if useColorCurve then
          -- Check if colorCurve OnUpdate is already set up for this exact aura
          -- Skip re-setup to prevent fighting between ticker calls and OnUpdate
          local existingData = barFrame.bar.colorCurveData
          local alreadyActive = existingData and existingData.auraID == auraID and existingData.unit == unit
          
          if not alreadyActive then
            -- Store data for OnUpdate handler
            barFrame.bar.colorCurveData = {
              unit = unit,
              auraID = auraID,
              colorCurve = colorCurve,
              baseColor = baseColor,
              elapsed = 0,
            }
            
            -- Apply initial color FIRST (before SetAlpha) using SetStatusBarColor
            -- SetStatusBarColor accepts secrets AND handles alpha correctly - no flicker!
            local barTexture = barFrame.bar:GetStatusBarTexture()
            if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end  -- Reset any previous VertexColor
            
            -- GetAuraDuration returns nil for gone auras and does not throw; validate
            -- the instance first, then evaluate the curve directly (no pcall).
            local durObj = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraID)
              and C_UnitAuras.GetAuraDuration(unit, auraID)
            local colorResult = durObj and durObj:EvaluateRemainingPercent(colorCurve)
            if colorResult then
              -- SetStatusBarColor handles alpha directly - base color alpha 0 = invisible
              barFrame.bar:SetStatusBarColor(colorResult:GetRGBA())
            else
              barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
            end
            
            -- NOW make bar visible (color already applied, no flicker)
            barFrame.bar:SetAlpha(1)

            -- Set up OnUpdate handler for continuous color updates (throttled to 20fps).
            -- Expiry cleanup is handled event-driven by activeAuraPolling UNIT_AURA handler
            -- which nils colorCurveData — the `if not data then return end` fast-exit covers it.
            barFrame.bar:SetScript("OnUpdate", function(self, elapsed)
              local data = self.colorCurveData
              if not data then return end  -- event-driven cleanup already ran → free exit

              -- Throttle gate FIRST — GetAuraDuration only called at 20fps, not every frame
              data.elapsed = data.elapsed + elapsed
              if data.elapsed < 0.05 then return end
              data.elapsed = 0

              -- GetAuraDuration returns nil for gone auras, does not throw — no pcall needed
              local durObj = C_UnitAuras.GetAuraDuration(data.unit, data.auraID)
              if not durObj then
                self:SetAlpha(0)
                self:SetScript("OnUpdate", nil)
                self.colorCurveData = nil
                return
              end

              -- Evaluate color from curve — SetStatusBarColor accepts secrets
              local colorResult = durObj:EvaluateRemainingPercent(data.colorCurve)
              if colorResult then
                self:SetStatusBarColor(colorResult:GetRGBA())
              else
                self:SetStatusBarColor(data.baseColor.r, data.baseColor.g, data.baseColor.b, data.baseColor.a or 1)
              end
            end)

            -- Register for event-driven cleanup when aura expires
            RegisterAuraPolling(barNumber, unit, auraID, barFrame, nil, nil)
          end  -- end if not alreadyActive
        else
          -- No color curve - but still need OnUpdate to detect aura expiry
          -- SetTimerDuration animates automatically but doesn't know when aura is gone
          
          -- Store data for aura monitoring
          barFrame.bar.auraMonitorData = {
            unit = unit,
            auraID = auraID,
            baseColor = baseColor,
            elapsed = 0,
          }
          
          -- Get bar texture reference for color
          local barTexture = barFrame.bar:GetStatusBarTexture()

          -- Reset VertexColor to white (in case ColorCurve was previously active)
          if barTexture then
            barTexture:SetVertexColor(1, 1, 1, 1)
          end

          -- No OnUpdate needed — activeAuraPolling UNIT_AURA handler handles expiry
          -- event-driven by niling auraMonitorData and calling SetScript("OnUpdate", nil).
          barFrame.bar:SetScript("OnUpdate", nil)

          -- Apply base color via SetStatusBarColor
          barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)

          -- NOW restore bar visibility (color is already applied, no flicker)
          barFrame.bar:SetAlpha(1)

          -- Register for event-driven cleanup
          RegisterAuraPolling(barNumber, unit, auraID, barFrame, nil, nil)
        end
      else
        -- MANUAL MAX MODE: Poll remaining duration, StatusBar auto-clamps to maxValue
        -- e.g., max=4, remaining=8.9 → shows full; remaining=2.3 → shows 2.3
        barFrame.bar:SetMinMaxValues(0, maxValue)
        
        -- Store data for OnUpdate
        barFrame.bar.manualMaxData = {
          unit = unit,
          auraID = auraID,
          baseColor = baseColor,
          elapsed = 0,
          interp = durationInterp,
        }
        
        -- OnUpdate polls GetRemainingDuration (secret) → SetValue (accepts secrets, auto-clamps).
        -- Throttle gate first — expiry handled event-driven by activeAuraPolling.
        local barTexture = barFrame.bar:GetStatusBarTexture()
        barFrame.bar:SetScript("OnUpdate", function(self, elapsed)
          local data = self.manualMaxData
          if not data then return end  -- event-driven cleanup already ran → free exit

          -- Throttle gate FIRST — GetAuraDuration only called at 20fps, not every frame
          data.elapsed = data.elapsed + elapsed
          if data.elapsed < 0.05 then return end
          data.elapsed = 0

          -- GetAuraDuration returns nil for gone auras, does not throw — no pcall needed
          local durObj = C_UnitAuras.GetAuraDuration(data.unit, data.auraID)
          if not durObj then
            self:SetAlpha(0)
            self:SetScript("OnUpdate", nil)
            self.manualMaxData = nil
            return
          end

          -- GetRemainingDuration on a valid durObj does not throw — no pcall needed
          local remaining = durObj:GetRemainingDuration()  -- secret value
          self:SetValue(remaining, data.interp)            -- SetValue accepts secrets
        end)
        
        -- Register for event-driven cleanup when aura expires
        RegisterAuraPolling(barNumber, unit, auraID, barFrame, nil, nil)

        -- Apply initial value — no pcall, GetAuraDuration returns nil safely
        local durObj = C_UnitAuras.GetAuraDuration(unit, auraID)
        if durObj then
          barFrame.bar:SetValue(durObj:GetRemainingDuration(), durationInterp)
        end
        
        -- Reset VertexColor and apply base color
        if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
        barFrame.bar.colorCurveData = nil
        barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
        
        -- NOW restore bar visibility (color is already applied, no flicker)
        barFrame.bar:SetAlpha(1)
      end
    else
      -- No valid aura - clear OnUpdate
      barFrame.bar.colorCurveData = nil
      barFrame.bar:SetScript("OnUpdate", nil)
      UnregisterAuraPolling(barNumber)
      barFrame.bar:SetMinMaxValues(0, maxValue)
      barFrame.bar:SetValue(sourceBar:GetValue())
      local barTexture = barFrame.bar:GetStatusBarTexture()
      if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
      barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
    end
    
    -- Only apply gradient if colorCurve is NOT active (gradient requires non-secret arithmetic)
    if not useColorCurve then
      ApplyBarGradient(barFrame.bar, barConfig, baseColor)  -- Pass baseColor to avoid secrets
    end
    -- Restore visibility after color is applied (prevents flicker)
    barFrame.bar:SetAlpha(1)
    barFrame.bar:Show()
    
  elseif active and sourceBar and sourceBar.GetValue then
    -- Generic fallback (no GetAuraInfo) - clear OnUpdate
    barFrame.bar.colorCurveData = nil
    barFrame.bar:SetScript("OnUpdate", nil)
    UnregisterAuraPolling(barNumber)
    
    -- Reset VertexColor for non-ColorCurve path
    local barTexture = barFrame.bar:GetStatusBarTexture()
    if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
    
    local useDynamicMax = barConfig.tracking.dynamicMaxDuration and sourceBar.GetMinMaxValues
    
    if useDynamicMax then
      local _, dynamicMax = sourceBar:GetMinMaxValues()
      barFrame.bar:SetMinMaxValues(0, dynamicMax or maxValue)
    else
      barFrame.bar:SetMinMaxValues(0, maxValue)
    end
    
    barFrame.bar:SetValue(sourceBar:GetValue(), durationInterp)
    barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
    ApplyBarGradient(barFrame.bar, barConfig, baseColor)  -- Pass baseColor to avoid secrets
    -- Restore visibility after color is applied (prevents flicker)
    barFrame.bar:SetAlpha(1)
    barFrame.bar:Show()
    
  elseif active and not sourceBar and IsNumericAndPositive(stacks) then
    -- Preview mode from ApplyPreviewValue - clear OnUpdate
    barFrame.bar.colorCurveData = nil
    barFrame.bar:SetScript("OnUpdate", nil)
    UnregisterAuraPolling(barNumber)
    
    barFrame.bar:SetMinMaxValues(0, maxValue)
    local effectiveMax = (maxStacks and maxStacks > 0) and maxStacks or 10
    local pct = stacks / effectiveMax
    local previewValue = maxValue * pct
    barFrame.bar:SetValue(previewValue)
    
    -- Apply bar color - SetStatusBarColor handles alpha directly for ColorCurve
    if useColorCurve and pct then
      -- Reset VertexColor in case it was tinted before
      local barTexture = barFrame.bar:GetStatusBarTexture()
      if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
      
      -- Preview mode: SetStatusBarColor with curve result (handles alpha correctly).
      -- pct is a non-secret preview number, so curve evaluation can't error here.
      local colorResult = colorCurve and colorCurve:Evaluate(pct)
      if colorResult then
        barFrame.bar:SetStatusBarColor(colorResult:GetRGBA())
      else
        barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      end
      -- Note: Gradient skipped when using ColorCurve (SetGradient doesn't accept secrets)
    else
      -- No ColorCurve - reset VertexColor and use SetStatusBarColor with gradient
      local barTexture = barFrame.bar:GetStatusBarTexture()
      if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
      barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      ApplyBarGradient(barFrame.bar, barConfig, baseColor)
    end
    -- Restore visibility after color is applied (prevents flicker)
    barFrame.bar:SetAlpha(1)
    barFrame.bar:Show()
    
  else
    -- Not active - clear OnUpdate and show dimmed empty bar
    barFrame.bar.colorCurveData = nil
    barFrame.bar:SetScript("OnUpdate", nil)
    UnregisterAuraPolling(barNumber)
    
    -- Reset VertexColor for non-active state
    local barTexture = barFrame.bar:GetStatusBarTexture()
    if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
    
    barFrame.bar:SetMinMaxValues(0, maxValue)
    barFrame.bar:SetValue(0)
    local dimmedColor = {r=baseColor.r * 0.5, g=baseColor.g * 0.5, b=baseColor.b * 0.5, a=baseColor.a or 0.8}
    barFrame.bar:SetStatusBarColor(dimmedColor.r, dimmedColor.g, dimmedColor.b, dimmedColor.a)
    ApplyBarGradient(barFrame.bar, barConfig, dimmedColor)
    -- Restore visibility after color is applied (prevents flicker)
    barFrame.bar:SetAlpha(1)
    barFrame.bar:Show()
  end
  
  -- Update stacks text (use secret value passthrough)
  if barConfig.display.showText then
    if showPreview then
      -- Preview mode - show sample stacks value
      local previewStackCount = math_max(1, math_floor((maxStacks or 3) * (previewStacks or 0.5)))
      textFrame.text:SetText(previewStackCount)
    elseif active and not sourceBar and IsNumericAndPositive(stacks) then
      -- Preview from ApplyPreviewValue - use passed stacks value
      textFrame.text:SetText(stacks)
    elseif active and stacksFontString and stacksFontString.GetText then
      -- Pass secret stacks value directly
      textFrame.text:SetText(stacksFontString:GetText())
    elseif active and stacks then
      textFrame.text:SetText(stacks)
    else
      -- Not active - show empty for duration bars
      textFrame.text:SetText("")
    end
    local tc = barConfig.display.textColor
    textFrame.text:SetTextColor(tc.r, tc.g, tc.b, tc.a)
  end
  
  -- Duration text - use C_UnitAuras.GetAuraDurationRemaining for secret-safe text
  if barConfig.display.showDuration and durationFrame then
    local decimals = barConfig.display.durationDecimals or 1
    local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}
    
    -- Store decimals on frame for OnUpdate access
    durationFrame.storedDecimals = decimals
    
    if showPreview then
      -- Preview mode - show sample duration value
      local pct = previewStacks or 0.5
      local previewValue = maxValue * pct
      durationFrame.text:SetText(string_format(DURATION_FMT[decimals] or "%.1f", previewValue))
      durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
      durationFrame:Show()
    elseif active and not sourceBar and IsNumericAndPositive(stacks) then
      -- Preview from ApplyPreviewValue - calculate duration from stacks percentage
      local effectiveMax = (maxStacks and maxStacks > 0) and maxStacks or 10
      local pct = stacks / effectiveMax
      local previewDurationValue = maxValue * pct
      durationFrame.text:SetText(string_format(DURATION_FMT[decimals] or "%.1f", previewDurationValue))
      durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
      durationFrame:Show()
    elseif active and sourceBar and sourceBar.GetTotemInfo then
      -- TOTEM/PET: Duration text is handled by totem bar's OnUpdate polling
      -- Skip here to avoid conflicts - durationFrame is already set up above
      -- (do nothing - totem polling handles duration text updates)
    elseif active and sourceBar and sourceBar.GetAuraInfo then
      -- Use DurationObject for auto-updating countdown text
      -- Pattern: Get fresh auraID from sourceBar each frame to detect refreshes
      local auraID, unit = sourceBar:GetAuraInfo()
      if auraID and unit then
        -- Store current aura info for OnUpdate
        durationFrame.sourceBar = sourceBar
        durationFrame.isActive = true

        -- Set up OnUpdate to poll GetRemainingDuration() with fresh DurationObject
        if not durationFrame.durationOnUpdate then
          durationFrame.durationOnUpdate = function(self, elapsed)
            self.elapsed = (self.elapsed or 0) + elapsed
            if self.elapsed < 0.05 then return end  -- 20fps
            self.elapsed = 0

            if not self.isActive or not self.sourceBar then
              self:SetScript("OnUpdate", nil)
              self.text:SetText("")
              self:Hide()
              return
            end

            local currentAuraID, currentUnit = self.sourceBar:GetAuraInfo()
            if not currentAuraID or not currentUnit then
              self:SetScript("OnUpdate", nil)
              self.isActive = false
              self.sourceBar = nil
              self.text:SetText("")
              self:Hide()
              return
            end

            local durObj = C_UnitAuras.GetAuraDuration(currentUnit, currentAuraID)
            if durObj then
              self.text:SetFormattedText(DURATION_FMT[self.storedDecimals] or "%.1f", durObj:GetRemainingDuration())
            else
              self:SetScript("OnUpdate", nil)
              self.isActive = false
              self.sourceBar = nil
              self.text:SetText("")
              self:Hide()
            end
          end
        end
        durationFrame:SetScript("OnUpdate", durationFrame.durationOnUpdate)

        -- Initial text set — no pcall, GetAuraDuration returns nil safely
        local durObj = C_UnitAuras.GetAuraDuration(unit, auraID)
        if durObj then
          durationFrame.text:SetFormattedText(DURATION_FMT[decimals] or "%.1f", durObj:GetRemainingDuration())
        end
      else
        durationFrame.text:SetFormattedText(DURATION_FMT[decimals] or "%.1f", sourceBar:GetValue())
        durationFrame:SetScript("OnUpdate", nil)
        durationFrame.isActive = false
        durationFrame.sourceBar = nil
      end
      durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
      durationFrame:Show()
    elseif active and sourceBar and sourceBar.GetValue then
      -- Fallback: pass raw value through (secret-safe via SetText)
      -- Clear OnUpdate since we don't have aura info
      durationFrame:SetScript("OnUpdate", nil)
      durationFrame.isActive = false
      durationFrame.sourceBar = nil
      durationFrame.text:SetFormattedText(DURATION_FMT[decimals] or "%.1f", sourceBar:GetValue())
      durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
      durationFrame:Show()
    else
      -- Not active (cooldown ready / all charges available)
      -- Clear OnUpdate
      durationFrame:SetScript("OnUpdate", nil)
      durationFrame.isActive = false
      durationFrame.sourceBar = nil
      -- Check if we should show "0" or hide
      if optionsOpen or barConfig.display.durationShowWhenReady then
        -- Show "0" for editing or if user wants to see ready state
        durationFrame.text:SetText(string_format(DURATION_FMT[decimals] or "%.1f", 0))
        durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
        durationFrame:Show()
      else
        -- Default: hide when ready
        durationFrame:Hide()
      end
    end
  elseif durationFrame then
    -- Clear OnUpdate when duration display is disabled
    durationFrame:SetScript("OnUpdate", nil)
    durationFrame.isActive = false
    durationFrame.sourceBar = nil
    durationFrame:Hide()
  end
  
  -- Name text - show buff name for duration bars
  -- Dynamic aura name is stored on bar state by Core.lua (bypasses profiler wrapper)
  -- When active: state.dynamicAuraName has the secret-safe name from CDM frame auraSpellID
  -- When inactive: state.dynamicAuraName is nil, so we use static config name
  if barConfig.display.showName and nameFrame then
    local barState = ns.API.GetBarState and ns.API.GetBarState(barNumber)
    local dynamicName = barState and barState.dynamicAuraName
    if dynamicName then
      -- Dynamic aura name - updates as different buffs cycle through the CDM slot
      -- secret-safe: C_Spell.GetSpellName(secret) → SetText(secret string) passthrough
      nameFrame.text:SetText(dynamicName)
    else
      -- Static fallback: get base ability name from cooldownID (e.g. "Roll the Bones")
      -- tracking.buffName may store a linked/proc spell name from discovery
      local baseName = nil
      local cooldownID = barConfig.tracking.cooldownID
      if cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
        if info then
          local baseID = info.overrideSpellID or info.spellID
          if baseID and baseID > 0 then
            baseName = C_Spell.GetSpellName(baseID)
          end
        end
      end
      if not baseName or baseName == "" then
        baseName = barConfig.tracking.buffName or barConfig.tracking.spellName or ""
        if baseName == "" and barConfig.tracking.spellID then
          baseName = C_Spell.GetSpellName(barConfig.tracking.spellID) or ""
        end
      end
      nameFrame.text:SetText(baseName)
    end
    local nc = barConfig.display.nameColor or {r=1, g=1, b=1, a=1}
    nameFrame.text:SetTextColor(nc.r, nc.g, nc.b, nc.a)
    nameFrame:Show()
  elseif nameFrame then
    nameFrame:Hide()
  end
  
  -- Bar icon - show tracking icon alongside bar
  if barConfig.display.showBarIcon and barIconFrame then
    -- Set icon texture
    if iconTexture then
      barIconFrame.icon:SetTexture(iconTexture)
    elseif barConfig.tracking.iconTextureID then
      barIconFrame.icon:SetTexture(barConfig.tracking.iconTextureID)
    elseif barConfig.tracking.spellID then
      local texture = C_Spell.GetSpellTexture(barConfig.tracking.spellID)
      if texture then
        barIconFrame.icon:SetTexture(texture)
      end
    end
    
    -- Border
    if barConfig.display.barIconShowBorder then
      local bc = barConfig.display.barIconBorderColor or {r=0, g=0, b=0, a=1}
      barIconFrame.background:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
      barIconFrame.background:Show()
    else
      barIconFrame.background:Hide()
    end
    
    barIconFrame:Show()
  elseif barIconFrame then
    barIconFrame:Hide()
  end
  
  -- Update tick marks for duration bar (uses maxDuration as maxValue)
  -- Pass "duration" mode so tick marks know to handle seconds appropriately
  local maxDuration = barConfig.tracking.maxDuration or 30
  UpdateTickMarks(barFrame, barConfig, maxDuration, "duration")
  
  -- Visibility already determined at function start - just show/hide based on that
  if shouldShow and barConfig.display.enabled then
    barFrame:Show()
    barFrame:SetAlpha(1)  -- Always full opacity for duration bars
    if barConfig.display.showText then
      textFrame:Show()
    else
      textFrame:Hide()
    end
    -- Note: durationFrame visibility is already handled earlier in the function
    -- based on whether the cooldown is active and durationShowWhenReady setting
    if barConfig.display.showName and nameFrame then
      nameFrame:Show()
    end
    if barConfig.display.showBarIcon and barIconFrame then
      barIconFrame:Show()
    end
  else
    barFrame:Hide()
    textFrame:Hide()
    if durationFrame then durationFrame:Hide() end
    if nameFrame then nameFrame:Hide() end
    if barIconFrame then barIconFrame:Hide() end
  end
end

-- ===================================================================
-- SHARED HELPER: Update a single bar's position AND size for a group.
-- Must be defined before ApplyAppearance which calls it.
-- ===================================================================
local function UpdateBarForGroup(barNumber, cfg, barFrame, groupName)
  local grp = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]
  if not grp or not grp.container then return end
  local container = grp.container

  local scale       = cfg.barScale or 1.0
  local isVertical  = (cfg.barOrientation == "vertical")
  local anchorPoint = cfg.anchorPoint or "BOTTOM"
  local isSideAnchor = (anchorPoint == "LEFT" or anchorPoint == "RIGHT")

  local effScale = container:GetEffectiveScale()
  local offsetX = PixelSnap(cfg.anchorOffsetX or 0, effScale)
  local offsetY = PixelSnap(cfg.anchorOffsetY or 0, effScale)

  -- Compute bar size first so we can use barWidth for centering
  local barWidth, barHeight
  if cfg.matchGroupWidth then
    local sizeAdjust = cfg.matchWidthAdjust or 0
    local matchDimension
    if cfg.matchSlotsOnly and grp._slotAreaW then
      -- Use active slot span (already snapped WoW units)
      matchDimension = isSideAnchor
        and (grp._slotAreaHRaw or grp._slotAreaH)
        or  (grp._slotAreaWRaw or grp._slotAreaW)
    else
      local cW, cH = container:GetWidth(), container:GetHeight()
      matchDimension = isSideAnchor and cH or cW
    end
    if matchDimension and matchDimension > 0 then
      barWidth  = PixelSnap(matchDimension + sizeAdjust, effScale)
      barHeight = PixelSnap((cfg.height or 20) * scale, effScale)
      if isVertical then
        barFrame:SetSize(barHeight, barWidth)
      else
        barFrame:SetSize(barWidth, barHeight)
      end
    end
  end

  barFrame:ClearAllPoints()
  local matchSlots = cfg.matchGroupWidth and cfg.matchSlotsOnly and barWidth
  if anchorPoint == "TOP" then
    if matchSlots then
      local halfWidth = PixelSnap(barWidth / 2, effScale)
      barFrame:SetPoint("BOTTOMLEFT", container, "TOP", -halfWidth + offsetX, offsetY)
    else
      barFrame:SetPoint("BOTTOMLEFT", container, "TOPLEFT", offsetX, offsetY)
    end
  elseif anchorPoint == "BOTTOM" then
    if matchSlots then
      local halfWidth = PixelSnap(barWidth / 2, effScale)
      barFrame:SetPoint("TOPLEFT", container, "BOTTOM", -halfWidth + offsetX, offsetY)
    else
      barFrame:SetPoint("TOPLEFT", container, "BOTTOMLEFT", offsetX, offsetY)
    end
  elseif anchorPoint == "LEFT" then
    barFrame:SetPoint("RIGHT", container, "LEFT", offsetX, offsetY)
  elseif anchorPoint == "RIGHT" then
    barFrame:SetPoint("LEFT", container, "RIGHT", offsetX, offsetY)
  end
end

-- ===================================================================
-- APPLY APPEARANCE TO SPECIFIC BAR
-- ===================================================================
function ns.Display.ApplyAppearance(barNumber)
  barNumber = barNumber or ns.API.GetSelectedBar()
  local barConfig = ns.API.GetBarConfig(barNumber)
  if not barConfig then return end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- INITIALIZATION CHECK: Skip appearance until init complete (prevents flash on reload)
  -- ═══════════════════════════════════════════════════════════════════
  if not initializationComplete and not IsOptionsOpen() then
    return
  end
  
  -- If bar is not enabled, hide all frames and return
  -- CRITICAL: Do NOT call GetBarFrames for disabled bars - it would create ghost frames!
  if not barConfig.tracking or not barConfig.tracking.enabled then
    -- Only try to hide if frames already exist
    if barFrames[barNumber] then
      ns.Display.HideBar(barNumber)
    end
    return
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- SPEC CHECK: Hide and return early if current spec doesn't match
  -- CRITICAL: Must check BEFORE GetBarFrames to avoid creating ghost frames
  -- ═══════════════════════════════════════════════════════════════════
  local currentSpec = GetSpecialization() or 0
  local showOnSpecs = barConfig.behavior and barConfig.behavior.showOnSpecs
  local specAllowed = true
  
  if showOnSpecs and #showOnSpecs > 0 then
    -- Multi-spec check: is current spec in the list?
    specAllowed = false
    for _, spec in ipairs(showOnSpecs) do
      if spec == currentSpec then
        specAllowed = true
        break
      end
    end
  elseif barConfig.behavior and barConfig.behavior.showOnSpec and barConfig.behavior.showOnSpec > 0 then
    -- Legacy single spec check
    specAllowed = (currentSpec == barConfig.behavior.showOnSpec)
  end
  
  if not specAllowed then
    -- Only hide if frames already exist - don't create them just to hide
    if barFrames[barNumber] then
      ns.Display.HideBar(barNumber)
    end
    return
  end
  
  local barFrame, textFrame, durationFrame, iconFrame, nameFrame, barIconFrame = GetBarFrames(barNumber)
  local cfg = barConfig.display
  local displayType = cfg.displayType or "bar"

  -- Always clear _setupDone on segment bars when ApplyAppearance runs.
  -- The frame may be resized by UpdateBarForGroup called later in this function,
  -- but UpdateBar runs immediately after so we can't rely on size-change detection
  -- (WoW layout may not commit the new size before GetWidth() is called).
  if barFrame.granularBars then
    for _, _gb in ipairs(barFrame.granularBars) do _gb._setupDone = false end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- ICON MODE APPEARANCE
  -- ═══════════════════════════════════════════════════════════════════
  if displayType == "icon" then
    -- Hide bar elements
    barFrame:Hide()
    textFrame:Hide()
    durationFrame:Hide()
    if nameFrame then nameFrame:Hide() end
    if barIconFrame then barIconFrame:Hide() end
    
    -- Size
    local iconSize = cfg.iconSize or 48
    iconFrame:SetSize(iconSize, iconSize)
    
    -- Position
    if cfg.iconPosition then
      iconFrame:ClearAllPoints()
      iconFrame:SetPoint(
        cfg.iconPosition.point,
        UIParent,
        cfg.iconPosition.relPoint,
        cfg.iconPosition.x,
        cfg.iconPosition.y
      )
    end
    
    -- Frame strata and level for icon mode
    local iconStrata = cfg.barFrameStrata or "MEDIUM"
    local iconLevel = cfg.barFrameLevel or 10
    iconFrame:SetFrameStrata(iconStrata)
    iconFrame:SetFrameLevel(iconLevel)
    
    -- Set icon texture from tracking config
    if barConfig.tracking.iconTextureID then
      iconFrame.icon:SetTexture(barConfig.tracking.iconTextureID)
    elseif barConfig.tracking.spellID then
      -- Fallback: get texture from spellID
      local texture = C_Spell.GetSpellTexture(barConfig.tracking.spellID)
      if texture then
        iconFrame.icon:SetTexture(texture)
      end
    end
    
    -- Apply icon zoom
    local zoom = cfg.iconZoom or 0
    local minCoord = 0.08 + (zoom * 0.42)
    local maxCoord = 0.92 - (zoom * 0.42)
    iconFrame.icon:SetTexCoord(minCoord, maxCoord, minCoord, maxCoord)
    
    -- Show/hide icon texture based on iconShowTexture
    -- SAFETY: Also verify bar is enabled (prevents ghost icons from deleted bars)
    if cfg.iconShowTexture == false or not barConfig.tracking.enabled then
      iconFrame.icon:Hide()
      iconFrame.background:Hide()
    else
      iconFrame.icon:Show()
    end
    
    -- Stacks font - apply to both regular stacks and free stacks frame
    local stackFontSize = cfg.iconStackFontSize or 16
    local stackFont = "Fonts\\FRIZQT__.TTF"
    if LSM and cfg.iconStackFont then
      local fetchedFont = LSM:Fetch("font", cfg.iconStackFont)
      if fetchedFont and fetchedFont ~= "" then
        stackFont = fetchedFont
      end
    end
    local stackOutline = GetOutlineFlag(cfg.iconStackOutline)
    
    -- Apply fonts (regions are ArcUI-created; stackFont is a resolved path)
    if iconFrame.stacks then
      iconFrame.stacks:SetFont(stackFont, stackFontSize, stackOutline)
    end
    if iconFrame.stacksFrame and iconFrame.stacksFrame.text then
      iconFrame.stacksFrame.text:SetFont(stackFont, stackFontSize, stackOutline)
    end
    ApplyTextShadow(iconFrame.stacks, cfg.iconStackShadow)
    ApplyTextShadow(iconFrame.stacksFrame.text, cfg.iconStackShadow)
    
    -- Stacks anchor position
    local stackAnchor = cfg.iconStackAnchor or "TOPRIGHT"
    iconFrame.stacks:ClearAllPoints()
    
    -- Stack text is always draggable unless explicitly locked
    local stackDraggable = not cfg.iconStackLocked
    iconFrame.stacksFrame:EnableMouse(stackDraggable)
    
    if stackAnchor == "FREE" then
      -- FREE mode - use separate movable frame
      iconFrame.stacks:Hide()
      
      -- Position free stacks frame
      iconFrame.stacksFrame:ClearAllPoints()
      if cfg.iconStackPosition then
        iconFrame.stacksFrame:SetPoint(
          cfg.iconStackPosition.point,
          UIParent,
          cfg.iconStackPosition.relPoint,
          cfg.iconStackPosition.x,
          cfg.iconStackPosition.y
        )
      else
        -- Default position: CENTER of icon
        iconFrame.stacksFrame:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
      end
      
      -- Apply strata and level to stacks frame (use icon strata as default)
      local stackStrata = cfg.iconStackStrata or iconStrata
      local stackLevel = cfg.iconStackLevel or (iconLevel + 20)
      iconFrame.stacksFrame:SetFrameStrata(stackStrata)
      iconFrame.stacksFrame:SetFrameLevel(stackLevel)
      
      -- Show stacks frame if stacks enabled
      if cfg.iconShowStacks then
        iconFrame.stacksFrame:Show()
      else
        iconFrame.stacksFrame:Hide()
      end
    else
      -- Anchored modes - use regular stacks text
      iconFrame.stacksFrame:Hide()
      
      if stackAnchor == "TOPRIGHT" then
        iconFrame.stacks:SetPoint("TOPRIGHT", iconFrame, "TOPRIGHT", -2, -2)
      elseif stackAnchor == "TOPLEFT" then
        iconFrame.stacks:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 2, -2)
      elseif stackAnchor == "BOTTOMRIGHT" then
        iconFrame.stacks:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -2, 2)
      elseif stackAnchor == "BOTTOMLEFT" then
        iconFrame.stacks:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT", 2, 2)
      elseif stackAnchor == "TOPRIGHT_OUTER" then
        iconFrame.stacks:SetPoint("BOTTOMLEFT", iconFrame, "TOPRIGHT", 2, 2)
      elseif stackAnchor == "TOPLEFT_OUTER" then
        iconFrame.stacks:SetPoint("BOTTOMRIGHT", iconFrame, "TOPLEFT", -2, 2)
      elseif stackAnchor == "BOTTOMRIGHT_OUTER" then
        iconFrame.stacks:SetPoint("TOPLEFT", iconFrame, "BOTTOMRIGHT", 2, -2)
      elseif stackAnchor == "BOTTOMLEFT_OUTER" then
        iconFrame.stacks:SetPoint("TOPRIGHT", iconFrame, "BOTTOMLEFT", -2, -2)
      elseif stackAnchor == "CENTER" then
        iconFrame.stacks:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
      end
      
      if cfg.iconShowStacks then
        iconFrame.stacks:Show()
      else
        iconFrame.stacks:Hide()
      end
    end
    
    -- Duration font
    local durationFontSize = cfg.iconDurationFontSize or 14
    local durationOutline = GetOutlineFlag(cfg.iconDurationOutline)
    local durationFont = "Fonts\\FRIZQT__.TTF"
    if LSM and cfg.iconDurationFont then
      local fetchedFont = LSM:Fetch("font", cfg.iconDurationFont)
      if fetchedFont and fetchedFont ~= "" then
        durationFont = fetchedFont
      end
    end
    
    -- Apply font (region is ArcUI-created; durationFont is a resolved path)
    if iconFrame.duration then
      iconFrame.duration:SetFont(durationFont, durationFontSize, durationOutline)
    end
    ApplyTextShadow(iconFrame.duration, cfg.iconDurationShadow)
    
    -- Border
    if cfg.iconShowBorder then
      local bc = cfg.iconBorderColor or {r=0, g=0, b=0, a=1}
      iconFrame.background:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
      iconFrame.background:Show()
    else
      iconFrame.background:Hide()
    end
    
    -- Movability
    iconFrame:EnableMouse(true)
    
    -- Smart delete button positioning
    -- Attach to the most prominent visible element
    if iconFrame.deleteButton then
      iconFrame.deleteButton:ClearAllPoints()
      
      local iconHidden = (cfg.iconShowTexture == false)
      local stacksInFreeMode = (cfg.iconStackAnchor == "FREE")
      local stackFontSize = cfg.iconStackFontSize or 16
      local iconSize = cfg.iconSize or 48
      
      if iconHidden and stacksInFreeMode and cfg.iconShowStacks then
        -- Icon hidden, stacks in free mode - attach x to stacks frame
        iconFrame.deleteButton:SetPoint("TOPRIGHT", iconFrame.stacksFrame, "TOPRIGHT", 6, 6)
      elseif stacksInFreeMode and cfg.iconShowStacks and stackFontSize > iconSize then
        -- Stacks font larger than icon - attach to stacks frame
        iconFrame.deleteButton:SetPoint("TOPRIGHT", iconFrame.stacksFrame, "TOPRIGHT", 6, 6)
      else
        -- Default: attach to icon frame
        iconFrame.deleteButton:SetPoint("TOPRIGHT", iconFrame, "TOPRIGHT", 0, 0)
      end
    end
    
    -- Show icon frame if enabled
    if cfg.enabled then
      iconFrame:Show()
    end
    
    return  -- Exit early for icon mode
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- BAR MODE APPEARANCE (existing code below)
  -- ═══════════════════════════════════════════════════════════════════
  -- Hide icon frame in bar mode
  if iconFrame then
    iconFrame:Hide()
    -- Also hide and disable the separate stacksFrame (it's parented to UIParent, not iconFrame)
    if iconFrame.stacksFrame then
      iconFrame.stacksFrame:Hide()
      iconFrame.stacksFrame:EnableMouse(false)
    end
  end
  
  -- Check if this is a duration bar (uses single fill mode, not stacked)
  local useDurationBar = barConfig.tracking and barConfig.tracking.useDurationBar
  
  -- Check if vertical orientation
  local isVertical = (cfg.barOrientation == "vertical")
  
  -- Apply scale to SIZE instead of using SetScale()
  -- SetScale causes anchor-based drift when scale changes
  -- Multiplying size by scale keeps the bar anchored in place
  local scale = cfg.barScale or 1.0
  local scaledWidth = PixelSnap(cfg.width * scale)
  local scaledHeight = PixelSnap(cfg.height * scale)
  
  -- Size - SWAP width and height for vertical bars
  if isVertical then
    barFrame:SetSize(scaledHeight, scaledWidth)  -- Swap dimensions!
  else
    barFrame:SetSize(scaledWidth, scaledHeight)  -- Normal horizontal
  end
  
  -- NOTE: We do NOT use SetScale anymore - it causes position drift
  -- barFrame:SetScale(cfg.barScale) -- REMOVED - scale is now applied to size
  barFrame:SetAlpha(cfg.opacity * (barFrames[barNumber] and barFrames[barNumber]._arcHideWhenAlpha or 1.0))
  
  -- Bar padding (always 0 - no UI option exposed)
  barFrame.bar:ClearAllPoints()
  barFrame.bar:SetAllPoints(barFrame)
  
  -- ═══════════════════════════════════════════════════════════════
  -- CDM GROUP ANCHOR
  -- ═══════════════════════════════════════════════════════════════
  local anchoredToGroup = false
  if cfg.anchorToGroup and cfg.anchorGroupName then
    local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[cfg.anchorGroupName]
    if group and group.container then
      local container = group.container
      local anchorPoint = cfg.anchorPoint or "BOTTOM"
      local offsetX = PixelSnap(cfg.anchorOffsetX or 0)
      local offsetY = PixelSnap(cfg.anchorOffsetY or 0)

      -- Use shared helper for position + size (same as resize callbacks)
      local _wBefore = barFrame._lastKnownW
      local _hBefore = barFrame._lastKnownH
      UpdateBarForGroup(barNumber, cfg, barFrame, cfg.anchorGroupName)
      local _wAfter, _hAfter = barFrame:GetWidth(), barFrame:GetHeight()
      -- If frame was resized by UpdateBarForGroup, clear _setupDone on all segment bars
      -- so they recompute their SetPoint positions against the new frame dimensions.
      if _wBefore ~= _wAfter or _hBefore ~= _hAfter then
        if barFrame.granularBars then
          for _, _gb in ipairs(barFrame.granularBars) do _gb._setupDone = false end
        end
      end
      barFrame._lastKnownW = _wAfter
      barFrame._lastKnownH = _hAfter

      -- Hook the container's OnSizeChanged event
      barFrame._anchoredGroupName = cfg.anchorGroupName
      barFrame._anchoredBarNumber = barNumber
      if ns.Display.HookContainerForAnchoredBars then
        ns.Display.HookContainerForAnchoredBars(cfg.anchorGroupName)
      end

      anchoredToGroup = true
    end
  end
  
  -- Position (fallback if not anchored to group)
  if not anchoredToGroup and cfg.barPosition then
    barFrame:ClearAllPoints()
    PixelUtil.SetPoint(barFrame, cfg.barPosition.point, UIParent, cfg.barPosition.relPoint, cfg.barPosition.x, cfg.barPosition.y)
  end
  
  -- Frame strata and level
  local barStrata = cfg.barFrameStrata or "MEDIUM"
  local barLevel = cfg.barFrameLevel or 10
  barFrame:SetFrameStrata(barStrata)
  barFrame:SetFrameLevel(barLevel)
  
  -- Apply strata to the fill bar (StatusBar child) - must also have strata set
  -- Fill bar is 1 level above the parent frame (background texture is on parent at barLevel)
  if barFrame.bar then
    barFrame.bar:SetFrameStrata(barStrata)
    barFrame.bar:SetFrameLevel(barLevel + 1)
  end
  
  -- Apply strata/level to stacked bars (perStack/continuous modes)
  -- Levels: +1 to +20 for stack bars, +21 for maxColorBar
  if barFrame.stackedBars then
    for i, bar in ipairs(barFrame.stackedBars) do
      bar:SetFrameStrata(barStrata)
      bar:SetFrameLevel(barLevel + i)
    end
  end
  -- Apply strata/level to granular bars (perThreshold mode)
  if barFrame.granularBars then
    for i, bar in ipairs(barFrame.granularBars) do
      bar:SetFrameStrata(barStrata)
      bar:SetFrameLevel(barLevel + i)
    end
  end
  if barFrame.maxColorBar then
    barFrame.maxColorBar:SetFrameStrata(barStrata)
    barFrame.maxColorBar:SetFrameLevel(barLevel + 21)
  end
  
  -- Apply strata/level to tick overlay and border (above all fill bars)
  -- Tick overlay at +22, border at +23
  if barFrame.tickOverlay then
    barFrame.tickOverlay:SetFrameStrata(barStrata)
    barFrame.tickOverlay:SetFrameLevel(barLevel + 22)
  end
  if barFrame.barBorderFrame then
    barFrame.barBorderFrame:SetFrameStrata(barStrata)
    barFrame.barBorderFrame:SetFrameLevel(barLevel + 23)
  end
  
  -- Apply strata to text frames - use individual settings if specified, fallback to bar strata
  -- Text frames default to +25 (above tick overlay and border)
  if textFrame then
    local stackStrata = cfg.stackTextStrata or barStrata
    local stackLevel = cfg.stackTextLevel or (barLevel + 25)
    textFrame:SetFrameStrata(stackStrata)
    textFrame:SetFrameLevel(stackLevel)
  end
  if durationFrame then
    local durStrata = cfg.durationTextStrata or barStrata
    local durLevel = cfg.durationTextLevel or (barLevel + 25)
    durationFrame:SetFrameStrata(durStrata)
    durationFrame:SetFrameLevel(durLevel)
  end
  if nameFrame then
    local nameStrata = cfg.nameTextStrata or barStrata
    local nameLevel = cfg.nameTextLevel or (barLevel + 25)
    nameFrame:SetFrameStrata(nameStrata)
    nameFrame:SetFrameLevel(nameLevel)
  end
  
  -- Text font and sizing (MUST happen before anchor positioning)
  local fontPath = "Fonts\\FRIZQT__.TTF"
  if LSM and cfg.font then
    local fetchedFont = LSM:Fetch("font", cfg.font)
    if fetchedFont and fetchedFont ~= "" then
      fontPath = fetchedFont
    end
  end
  
  local fontSize = cfg.fontSize or 14
  local outlineFlag = GetOutlineFlag(cfg.textOutline)
  
  -- Apply font (region is ArcUI-created; fontPath is a resolved path)
  if textFrame.text then
    textFrame.text:SetFont(fontPath, fontSize, outlineFlag)
  end
  ApplyTextShadow(textFrame.text, cfg.textShadow)
  
  -- Fixed generous frame size — FontStrings render independently of parent size.
  -- Resizing per-fontSize caused anchor drift (text moved when size slider changed).
  textFrame:SetSize(200, 60)
  
  -- Text positioning - either anchored to bar or free-floating
  local textAnchor = cfg.textAnchor or "OUTERTOP"
  if textAnchor ~= "FREE" then
    -- Anchor text to bar edge points
    textFrame:ClearAllPoints()
    local offsetX = cfg.textAnchorOffsetX or 0
    local offsetY = cfg.textAnchorOffsetY or 0
    local padding = 5  -- Small padding from edge for visual clarity
    
    -- Inner anchors (text inside bar)
    if textAnchor == "CENTER" then
      textFrame:SetPoint("CENTER", barFrame, "CENTER", offsetX, offsetY)
    elseif textAnchor == "RIGHT" or textAnchor == "CENTERRIGHT" then
      textFrame:SetPoint("CENTER", barFrame, "RIGHT", -padding + offsetX, offsetY)
    elseif textAnchor == "LEFT" or textAnchor == "CENTERLEFT" then
      textFrame:SetPoint("CENTER", barFrame, "LEFT", padding + offsetX, offsetY)
    elseif textAnchor == "TOP" then
      textFrame:SetPoint("CENTER", barFrame, "TOP", offsetX, -padding + offsetY)
    elseif textAnchor == "BOTTOM" then
      textFrame:SetPoint("CENTER", barFrame, "BOTTOM", offsetX, padding + offsetY)
    elseif textAnchor == "TOPLEFT" then
      textFrame:SetPoint("CENTER", barFrame, "TOPLEFT", padding + offsetX, -padding + offsetY)
    elseif textAnchor == "TOPRIGHT" then
      textFrame:SetPoint("CENTER", barFrame, "TOPRIGHT", -padding + offsetX, -padding + offsetY)
    elseif textAnchor == "BOTTOMLEFT" then
      textFrame:SetPoint("CENTER", barFrame, "BOTTOMLEFT", padding + offsetX, padding + offsetY)
    elseif textAnchor == "BOTTOMRIGHT" then
      textFrame:SetPoint("CENTER", barFrame, "BOTTOMRIGHT", -padding + offsetX, padding + offsetY)
    -- Outer anchors (text outside bar, touching the border)
    -- Use -20 for right-side outers, +20 for left-side outers to compensate for text centering
    elseif textAnchor == "OUTERRIGHT" or textAnchor == "OUTERCENTERRIGHT" then
      textFrame:SetPoint("LEFT", barFrame, "RIGHT", -20 + offsetX, offsetY)
    elseif textAnchor == "OUTERLEFT" or textAnchor == "OUTERCENTERLEFT" then
      textFrame:SetPoint("RIGHT", barFrame, "LEFT", 20 + offsetX, offsetY)
    elseif textAnchor == "OUTERTOP" then
      textFrame:SetPoint("BOTTOM", barFrame, "TOP", offsetX, offsetY)
    elseif textAnchor == "OUTERBOTTOM" then
      textFrame:SetPoint("TOP", barFrame, "BOTTOM", offsetX, offsetY)
    elseif textAnchor == "OUTERTOPLEFT" then
      textFrame:SetPoint("BOTTOMRIGHT", barFrame, "TOPLEFT", 20 + offsetX, offsetY)
    elseif textAnchor == "OUTERTOPRIGHT" then
      textFrame:SetPoint("BOTTOMLEFT", barFrame, "TOPRIGHT", -20 + offsetX, offsetY)
    elseif textAnchor == "OUTERBOTTOMLEFT" then
      textFrame:SetPoint("TOPRIGHT", barFrame, "BOTTOMLEFT", 20 + offsetX, offsetY)
    elseif textAnchor == "OUTERBOTTOMRIGHT" then
      textFrame:SetPoint("TOPLEFT", barFrame, "BOTTOMRIGHT", -20 + offsetX, offsetY)
    else
      -- Fallback
      textFrame:SetPoint("CENTER", barFrame, "CENTER", offsetX, offsetY)
    end
  elseif cfg.textPosition then
    textFrame:ClearAllPoints()
    textFrame:SetPoint(
      cfg.textPosition.point,
      UIParent,
      cfg.textPosition.relPoint,
      cfg.textPosition.x,
      cfg.textPosition.y
    )
  end
  
  -- Duration text font and sizing
  if durationFrame then
    local durationOutline = GetOutlineFlag(cfg.durationOutline)
    local durationFontSize = cfg.durationFontSize or 18
    local fontPath = "Fonts\\FRIZQT__.TTF"
    
    -- Try to get custom font
    if LSM and cfg.durationFont then
      local fetchedFont = LSM:Fetch("font", cfg.durationFont)
      if fetchedFont and fetchedFont ~= "" then
        fontPath = fetchedFont
      end
    elseif LSM and cfg.font then
      -- Fallback to regular font
      local fetchedFont = LSM:Fetch("font", cfg.font)
      if fetchedFont and fetchedFont ~= "" then
        fontPath = fetchedFont
      end
    end
    
    -- Apply font (region is ArcUI-created; fontPath is a resolved path)
    if durationFrame.text then
      durationFrame.text:SetFont(fontPath, durationFontSize, durationOutline)
    end
    
    ApplyTextShadow(durationFrame.text, cfg.durationShadow)
    
    -- Size duration frame
    durationFrame:SetSize(durationFontSize * 4, durationFontSize + 4)
    
    -- Duration positioning - either anchored to bar or free-floating
    local durationAnchor = cfg.durationAnchor or "CENTER"
    if durationAnchor ~= "FREE" then
      durationFrame:ClearAllPoints()
      local offsetX = cfg.durationAnchorOffsetX or 0
      local offsetY = cfg.durationAnchorOffsetY or 0
      local padding = 5
      
      -- New format (matching textAnchor) + backward compatibility for old format
      if durationAnchor == "CENTER" then
        durationFrame:SetPoint("CENTER", barFrame, "CENTER", offsetX, offsetY)
      elseif durationAnchor == "RIGHT" or durationAnchor == "CENTERRIGHT" or durationAnchor == "RIGHT_INNER" then
        durationFrame:SetPoint("CENTER", barFrame, "RIGHT", -padding + offsetX, offsetY)
      elseif durationAnchor == "LEFT" or durationAnchor == "CENTERLEFT" or durationAnchor == "LEFT_INNER" then
        durationFrame:SetPoint("CENTER", barFrame, "LEFT", padding + offsetX, offsetY)
      elseif durationAnchor == "TOP" or durationAnchor == "TOP_INNER" then
        durationFrame:SetPoint("CENTER", barFrame, "TOP", offsetX, -padding + offsetY)
      elseif durationAnchor == "BOTTOM" or durationAnchor == "BOTTOM_INNER" then
        durationFrame:SetPoint("CENTER", barFrame, "BOTTOM", offsetX, padding + offsetY)
      elseif durationAnchor == "TOPLEFT" then
        durationFrame:SetPoint("BOTTOMRIGHT", barFrame, "TOPLEFT", padding + offsetX, -padding + offsetY)
      elseif durationAnchor == "TOPRIGHT" then
        durationFrame:SetPoint("BOTTOMLEFT", barFrame, "TOPRIGHT", -padding + offsetX, -padding + offsetY)
      elseif durationAnchor == "BOTTOMLEFT" then
        durationFrame:SetPoint("TOPRIGHT", barFrame, "BOTTOMLEFT", padding + offsetX, padding + offsetY)
      elseif durationAnchor == "BOTTOMRIGHT" then
        durationFrame:SetPoint("TOPLEFT", barFrame, "BOTTOMRIGHT", -padding + offsetX, padding + offsetY)
      elseif durationAnchor == "OUTERRIGHT" or durationAnchor == "OUTERCENTERRIGHT" or durationAnchor == "RIGHT_OUTER" then
        durationFrame:SetPoint("LEFT", barFrame, "RIGHT", -20 + offsetX, offsetY)
      elseif durationAnchor == "OUTERLEFT" or durationAnchor == "OUTERCENTERLEFT" or durationAnchor == "LEFT_OUTER" then
        durationFrame:SetPoint("RIGHT", barFrame, "LEFT", 20 + offsetX, offsetY)
      elseif durationAnchor == "OUTERTOP" or durationAnchor == "TOP_OUTER" then
        durationFrame:SetPoint("BOTTOM", barFrame, "TOP", offsetX, offsetY)
      elseif durationAnchor == "OUTERBOTTOM" or durationAnchor == "BOTTOM_OUTER" then
        durationFrame:SetPoint("TOP", barFrame, "BOTTOM", offsetX, offsetY)
      elseif durationAnchor == "OUTERTOPLEFT" then
        durationFrame:SetPoint("BOTTOMRIGHT", barFrame, "TOPLEFT", offsetX, offsetY)
      elseif durationAnchor == "OUTERTOPRIGHT" then
        durationFrame:SetPoint("BOTTOMLEFT", barFrame, "TOPRIGHT", offsetX, offsetY)
      elseif durationAnchor == "OUTERBOTTOMLEFT" then
        durationFrame:SetPoint("TOPRIGHT", barFrame, "BOTTOMLEFT", offsetX, offsetY)
      elseif durationAnchor == "OUTERBOTTOMRIGHT" then
        durationFrame:SetPoint("TOPLEFT", barFrame, "BOTTOMRIGHT", offsetX, offsetY)
      else
        durationFrame:SetPoint("CENTER", barFrame, "CENTER", offsetX, offsetY)
      end
    elseif cfg.durationPosition then
      durationFrame:ClearAllPoints()
      durationFrame:SetPoint(
        cfg.durationPosition.point,
        UIParent,
        cfg.durationPosition.relPoint,
        cfg.durationPosition.x,
        cfg.durationPosition.y
      )
    end
  end
  
  -- Texture
  if LSM then
    local texture = LSM:Fetch("statusbar", cfg.texture)
    if texture then
      barFrame.bar:SetStatusBarTexture(texture)
    end
  end
  
  -- Fill direction and orientation
  barFrame.bar:SetOrientation(isVertical and "VERTICAL" or "HORIZONTAL")
  barFrame.bar:SetReverseFill(cfg.barReverseFill or false)
  -- Rotate texture to match fill direction
  barFrame.bar:SetRotatesTexture((cfg.rotateTexture == true) or (cfg.rotateTexture ~= false and isVertical))
  
  -- Background - ONLY on main frame (barFrame.bg)
  -- barFrame.bar.bg is always hidden since barFrame.bar is hidden in non-simple modes
  barFrame.bar.bg:Hide()
  barFrame.bg:SetShown(cfg.showBackground)
  if cfg.showBackground then
    local bg = cfg.backgroundColor
    local bgTextureName = cfg.backgroundTexture or "Solid"
    
    -- Background fills entire frame like MWRB (SetAllPoints)
    barFrame.bg:ClearAllPoints()
    barFrame.bg:SetAllPoints(barFrame)
    
    -- Reset texture state before applying new one
    barFrame.bg:SetVertexColor(1, 1, 1, 1)  -- Reset vertex color
    barFrame.bg:SetTexCoord(0, 1, 0, 1)     -- Reset tex coords
    
    if bgTextureName == "Solid" then
      barFrame.bg:SetColorTexture(bg.r, bg.g, bg.b, bg.a)
    else
      -- Try to fetch from LSM background type
      local bgTexture = LSM and LSM:Fetch("background", bgTextureName)
      if bgTexture then
        barFrame.bg:SetTexture(bgTexture)
        barFrame.bg:SetVertexColor(bg.r, bg.g, bg.b, bg.a)
      else
        barFrame.bg:SetColorTexture(bg.r, bg.g, bg.b, bg.a)
      end
    end
  end
  
  -- Border - uses 4 manual textures for pixel-perfect borders
  if barFrame.barBorderFrame then
    if cfg.showBorder then
      local btRaw = cfg.drawnBorderThickness or 2
      -- Snap to nearest physical pixel so every edge is uniform and crisp
      local _s3 = barFrame:GetEffectiveScale()
      local _, _h3 = GetPhysicalScreenSize()
      local _onePx3 = (_h3 and _h3 > 0 and _s3 and _s3 > 0) and (768 / _h3) / _s3 or 1
      local bt = _onePx3 * btRaw
      local bc = cfg.borderColor or {r = 0, g = 0, b = 0, a = 1}
      
      -- Top border (spans full width at top)
      barFrame.barBorderFrame.top:ClearAllPoints()
      barFrame.barBorderFrame.top:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
      barFrame.barBorderFrame.top:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, 0)
      barFrame.barBorderFrame.top:SetHeight(bt)
      barFrame.barBorderFrame.top:SetColorTexture(bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1)
      barFrame.barBorderFrame.top:Show()
      
      -- Bottom border (spans full width at bottom)
      barFrame.barBorderFrame.bottom:ClearAllPoints()
      barFrame.barBorderFrame.bottom:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 0, 0)
      barFrame.barBorderFrame.bottom:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
      barFrame.barBorderFrame.bottom:SetHeight(bt)
      barFrame.barBorderFrame.bottom:SetColorTexture(bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1)
      barFrame.barBorderFrame.bottom:Show()
      
      -- Left border (between top and bottom borders)
      barFrame.barBorderFrame.left:ClearAllPoints()
      barFrame.barBorderFrame.left:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, -bt)
      barFrame.barBorderFrame.left:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 0, bt)
      barFrame.barBorderFrame.left:SetWidth(bt)
      barFrame.barBorderFrame.left:SetColorTexture(bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1)
      barFrame.barBorderFrame.left:Show()
      
      -- Right border (between top and bottom borders)
      barFrame.barBorderFrame.right:ClearAllPoints()
      barFrame.barBorderFrame.right:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, -bt)
      barFrame.barBorderFrame.right:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, bt)
      barFrame.barBorderFrame.right:SetWidth(bt)
      barFrame.barBorderFrame.right:SetColorTexture(bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1)
      barFrame.barBorderFrame.right:Show()
      
      barFrame.barBorderFrame:Show()
    else
      if barFrame.barBorderFrame.top then barFrame.barBorderFrame.top:Hide() end
      if barFrame.barBorderFrame.bottom then barFrame.barBorderFrame.bottom:Hide() end
      if barFrame.barBorderFrame.left then barFrame.barBorderFrame.left:Hide() end
      if barFrame.barBorderFrame.right then barFrame.barBorderFrame.right:Hide() end
      barFrame.barBorderFrame:Hide()
    end
  end
  
  -- Movability
  barFrame:EnableMouse(cfg.barMovable)
  -- Text frame: draggable when FREE anchor and not locked
  local textDraggable = (cfg.textAnchor == "FREE") and not cfg.textLocked
  textFrame:EnableMouse(textDraggable)
  if durationFrame then
    durationFrame:EnableMouse(cfg.durationAnchor == "FREE")
  end
  
  -- Show/hide duration frame based on config
  if durationFrame then
    if cfg.showDuration then
      durationFrame:Show()
    else
      durationFrame:Hide()
    end
  end
  
  -- Name frame appearance (for duration bars)
  if nameFrame then
    -- Font
    local nameFont = "Fonts\\FRIZQT__.TTF"
    if LSM and cfg.nameFont then
      local font = LSM:Fetch("font", cfg.nameFont)
      if font then nameFont = font end
    elseif LSM and cfg.font then
      local font = LSM:Fetch("font", cfg.font)
      if font then nameFont = font end
    end
    local nameOutline = GetOutlineFlag(cfg.nameOutline)
    nameFrame.text:SetFont(nameFont, cfg.nameFontSize or 14, nameOutline)
    ApplyTextShadow(nameFrame.text, cfg.nameShadow)
    
    -- Size based on font
    local nameFontSize = cfg.nameFontSize or 14
    nameFrame:SetSize(nameFontSize * 12, nameFontSize + 4)
    
    -- Position
    local nameAnchor = cfg.nameAnchor or "CENTER"
    if nameAnchor ~= "FREE" then
      nameFrame:ClearAllPoints()
      local offsetX = cfg.nameAnchorOffsetX or 0
      local offsetY = cfg.nameAnchorOffsetY or 0
      local padding = 5
      
      -- New format (matching textAnchor) + backward compatibility for old format
      if nameAnchor == "CENTER" then
        nameFrame:SetPoint("CENTER", barFrame, "CENTER", offsetX, offsetY)
      elseif nameAnchor == "RIGHT" or nameAnchor == "CENTERRIGHT" then
        nameFrame:SetPoint("CENTER", barFrame, "RIGHT", -padding + offsetX, offsetY)
      elseif nameAnchor == "LEFT" or nameAnchor == "CENTERLEFT" then
        nameFrame:SetPoint("CENTER", barFrame, "LEFT", padding + offsetX, offsetY)
      elseif nameAnchor == "TOP" then
        nameFrame:SetPoint("CENTER", barFrame, "TOP", offsetX, -padding + offsetY)
      elseif nameAnchor == "BOTTOM" then
        nameFrame:SetPoint("CENTER", barFrame, "BOTTOM", offsetX, padding + offsetY)
      elseif nameAnchor == "TOPLEFT" then
        nameFrame:SetPoint("BOTTOMRIGHT", barFrame, "TOPLEFT", padding + offsetX, -padding + offsetY)
      elseif nameAnchor == "TOPRIGHT" then
        nameFrame:SetPoint("BOTTOMLEFT", barFrame, "TOPRIGHT", -padding + offsetX, -padding + offsetY)
      elseif nameAnchor == "BOTTOMLEFT" then
        nameFrame:SetPoint("TOPRIGHT", barFrame, "BOTTOMLEFT", padding + offsetX, padding + offsetY)
      elseif nameAnchor == "BOTTOMRIGHT" then
        nameFrame:SetPoint("TOPLEFT", barFrame, "BOTTOMRIGHT", -padding + offsetX, padding + offsetY)
      elseif nameAnchor == "OUTERRIGHT" or nameAnchor == "OUTERCENTERRIGHT" or nameAnchor == "RIGHT_OUTER" then
        nameFrame:SetPoint("LEFT", barFrame, "RIGHT", 2 + offsetX, offsetY)
      elseif nameAnchor == "OUTERLEFT" or nameAnchor == "OUTERCENTERLEFT" or nameAnchor == "LEFT_OUTER" then
        nameFrame:SetPoint("RIGHT", barFrame, "LEFT", -2 + offsetX, offsetY)
      elseif nameAnchor == "OUTERTOP" or nameAnchor == "TOP_OUTER" then
        nameFrame:SetPoint("BOTTOM", barFrame, "TOP", offsetX, 2 + offsetY)
      elseif nameAnchor == "OUTERBOTTOM" or nameAnchor == "BOTTOM_OUTER" then
        nameFrame:SetPoint("TOP", barFrame, "BOTTOM", offsetX, -2 + offsetY)
      elseif nameAnchor == "OUTERTOPLEFT" then
        nameFrame:SetPoint("BOTTOMRIGHT", barFrame, "TOPLEFT", offsetX, offsetY)
      elseif nameAnchor == "OUTERTOPRIGHT" then
        nameFrame:SetPoint("BOTTOMLEFT", barFrame, "TOPRIGHT", offsetX, offsetY)
      elseif nameAnchor == "OUTERBOTTOMLEFT" then
        nameFrame:SetPoint("TOPRIGHT", barFrame, "BOTTOMLEFT", offsetX, offsetY)
      elseif nameAnchor == "OUTERBOTTOMRIGHT" then
        nameFrame:SetPoint("TOPLEFT", barFrame, "BOTTOMRIGHT", offsetX, offsetY)
      else
        nameFrame:SetPoint("CENTER", barFrame, "CENTER", offsetX, offsetY)
      end
    elseif cfg.namePosition then
      nameFrame:ClearAllPoints()
      nameFrame:SetPoint(
        cfg.namePosition.point,
        UIParent,
        cfg.namePosition.relPoint,
        cfg.namePosition.x,
        cfg.namePosition.y
      )
    end
    
    -- Movability
    nameFrame:EnableMouse(nameAnchor == "FREE")
    
    if cfg.showName then
      nameFrame:Show()
    else
      nameFrame:Hide()
    end
  end
  
  -- Bar icon frame appearance (icon alongside bar)
  if barIconFrame then
    -- Size
    local iconSize = cfg.barIconSize or 32
    barIconFrame:SetSize(iconSize, iconSize)
    
    -- Position
    local iconAnchor = cfg.barIconAnchor or "LEFT"
    if iconAnchor ~= "FREE" then
      barIconFrame:ClearAllPoints()
      local offsetX = cfg.iconOffsetX or 0
      local offsetY = cfg.iconOffsetY or 0
      local iconBarSpacing = cfg.iconBarSpacing or 4  -- Use the Bar Gap setting
      
      if iconAnchor == "LEFT" then
        barIconFrame:SetPoint("RIGHT", barFrame, "LEFT", -iconBarSpacing + offsetX, offsetY)
      elseif iconAnchor == "RIGHT" then
        barIconFrame:SetPoint("LEFT", barFrame, "RIGHT", iconBarSpacing + offsetX, offsetY)
      elseif iconAnchor == "TOP" then
        barIconFrame:SetPoint("BOTTOM", barFrame, "TOP", offsetX, iconBarSpacing + offsetY)
      elseif iconAnchor == "BOTTOM" then
        barIconFrame:SetPoint("TOP", barFrame, "BOTTOM", offsetX, -iconBarSpacing + offsetY)
      else
        barIconFrame:SetPoint("RIGHT", barFrame, "LEFT", -iconBarSpacing + offsetX, offsetY)
      end
    elseif cfg.barIconPosition then
      barIconFrame:ClearAllPoints()
      barIconFrame:SetPoint(
        cfg.barIconPosition.point,
        UIParent,
        cfg.barIconPosition.relPoint,
        cfg.barIconPosition.x,
        cfg.barIconPosition.y
      )
    end
    
    -- Border
    if cfg.barIconShowBorder then
      local bc = cfg.barIconBorderColor or {r=0, g=0, b=0, a=1}
      barIconFrame.background:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
      barIconFrame.background:Show()
    else
      barIconFrame.background:Hide()
    end
    
    -- Movability
    barIconFrame:EnableMouse(iconAnchor == "FREE")
    
    if cfg.showBarIcon then
      barIconFrame:Show()
    else
      barIconFrame:Hide()
    end
  end
  
  -- CRITICAL FIX: Check preview mode BEFORE refreshing
  if previewMode then
    -- In preview mode - maintain preview value
    local maxStacks = barConfig.tracking.maxStacks or 10
    local stackCount = math_floor(previewStacks * maxStacks + 0.5)
    ns.Display.UpdateBar(barNumber, stackCount, maxStacks, true)
  else
    -- Not in preview - refresh with real values
    if ns.API.RefreshDisplay then
      ns.API.RefreshDisplay(barNumber)
    end
  end
end

-- ===================================================================
-- APPLY ALL BARS
-- ===================================================================
function ns.Display.ApplyAllBars(nudgeLayout)
  -- Safety check: ensure DB functions are loaded
  if not ns.API.GetActiveBars then
    return
  end
  
  local activeBars = ns.API.GetActiveBars()
  for _, barNumber in ipairs(activeBars) do
    -- Nudge frame size to force layout engine recalc (fixes pixel-snapped border alignment)
    if nudgeLayout and barFrames[barNumber] and barFrames[barNumber].barFrame then
      local f = barFrames[barNumber].barFrame
      local w, h = f:GetSize()
      if w and h and w > 0 and h > 0 then
        f:SetSize(w + 0.01, h + 0.01)
        f:SetSize(w, h)
      end
    end
    ns.Display.ApplyAppearance(barNumber)
  end
  
  -- Also refresh visibility for all bars (respects spec settings)
  ns.Display.RefreshAllBars()
end

-- ===================================================================
-- REFRESH ALL BARS (for spec changes, etc.)
-- ===================================================================
-- Clear all deactivated flags so bars get re-evaluated on next update
-- Called on spec change, talent change, or when options panel opens
function ns.Display.ReactivateAllBars()

end

function ns.Display.RefreshAllBars()
  -- Clear deactivated flags so bars get properly re-evaluated
  ns.Display.ReactivateAllBars()
  
  local currentSpec = GetSpecialization() or 0
  local db = ns.API.GetDB and ns.API.GetDB()
  
  -- CRITICAL: Don't iterate if no database or no bars table
  if not db or not db.bars then return end
  
  -- Refresh visibility for all bars (including ones that might need hiding)
  for barNumber, barConfig in pairs(db.bars) do
    
    if barConfig and barConfig.tracking and barConfig.tracking.enabled then
      -- Check spec visibility first
      local showOnSpecs = barConfig.behavior and barConfig.behavior.showOnSpecs
      local specAllowed = true
      
      if showOnSpecs and #showOnSpecs > 0 then
        -- Multi-spec check: is current spec in the list?
        specAllowed = false
        for _, spec in ipairs(showOnSpecs) do
          if spec == currentSpec then
            specAllowed = true
            break
          end
        end
      elseif barConfig.behavior and barConfig.behavior.showOnSpec and barConfig.behavior.showOnSpec > 0 then
        -- Legacy single spec check
        specAllowed = (currentSpec == barConfig.behavior.showOnSpec)
      end
      
      if specAllowed then
        -- CRITICAL: Call ApplyAppearance FIRST to set up frames properly
        -- This handles anchors, borders, textures, fonts, etc.
        ns.Display.ApplyAppearance(barNumber)
        
        -- Then use Core.lua's RefreshDisplay to do proper tracking update
        -- This goes through full tracking logic instead of just UpdateBar
        if ns.API and ns.API.RefreshDisplay then
          ns.API.RefreshDisplay(barNumber)
        else
          -- Fallback if RefreshDisplay not available
          ns.Display.UpdateBar(barNumber)
        end
      else
        -- Hide bar - wrong spec (hide ALL frames)
        ns.Display.HideBar(barNumber)
      end
    elseif barFrames[barNumber] then
      -- Hide bars that aren't enabled (hide ALL frames)
      -- Only if frames already exist - don't create them!
      ns.Display.HideBar(barNumber)
    end
  end
end

-- ===================================================================
-- GET BAR FRAME (for external access)
-- ===================================================================
function ns.Display.GetBarFrame(barNumber)
  if barFrames[barNumber] then
    return barFrames[barNumber].barFrame
  end
  return nil
end

-- ===================================================================
-- GET ICON FRAME (for external access)
-- ===================================================================
function ns.Display.GetIconFrame(barNumber)
  if barFrames[barNumber] then
    return barFrames[barNumber].iconFrame
  end
  return nil
end

-- ===================================================================
-- GET APPROPRIATE FRAME (bar or icon based on displayType)
-- ===================================================================
function ns.Display.GetDisplayFrame(barNumber)
  local barConfig = ns.API.GetBarConfig(barNumber)
  if not barConfig then return nil end
  
  local displayType = barConfig.display.displayType or "bar"
  if displayType == "icon" then
    return ns.Display.GetIconFrame(barNumber)
  else
    return ns.Display.GetBarFrame(barNumber)
  end
end

-- ===================================================================
-- OPEN OPTIONS AND SELECT BAR (for click-to-edit)
-- Opens the options panel if not already open, then selects the Appearance tab
-- ===================================================================
function ns.Display.OpenOptionsForBar(barType, barNumber)
  local AceConfigDialog = LibStub("AceConfigDialog-3.0")
  
  -- Check if options panel is already open - if not, do nothing
  local panelIsOpen = AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["ArcUI"]
  if not panelIsOpen then
    return  -- Don't open panel, just ignore the click
  end
  
  -- Set the selected bar in AppearanceOptions
  if ns.AppearanceOptions and ns.AppearanceOptions.SetSelectedBar then
    ns.AppearanceOptions.SetSelectedBar(barType, barNumber)
  end
  
  -- Refresh the options to show updated selection
  local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
  AceConfigRegistry:NotifyChange("ArcUI")
  
  -- Select the appearance tab (now under bars)
  AceConfigDialog:SelectGroup("ArcUI", "bars", "appearance")
end

-- ===================================================================
-- SET PREVIEW VALUE (for live preview in appearance options)
-- ===================================================================
function ns.Display.SetPreviewValue(barNumber, previewValue)
  local barConfig = ns.API.GetBarConfig(barNumber)
  if not barConfig then return end
  
  local barFrame, textFrame = GetBarFrames(barNumber)
  if not barFrame then return end
  
  local maxStacks = barConfig.tracking.maxStacks or 10
  local displayMode = barConfig.display.thresholdMode or "simple"
  
  if displayMode == "granular" then
    -- Granular mode: each bar represents one stack unit, set 1 if filled, 0 if not
    if barFrame.granularBars then
      for i, bar in ipairs(barFrame.granularBars) do
        if bar:IsShown() then
          bar:SetValue(i <= previewValue and 1 or 0)
        end
      end
    end
  elseif displayMode == "perStack" then
    -- Sequence mode: use SetValue with previewValue (min/max already set per segment)
    if barFrame.granularBars then
      for i, bar in ipairs(barFrame.granularBars) do
        if bar:IsShown() then
          bar:SetValue(previewValue)
        end
      end
    end
  elseif displayMode == "folded" then
    -- Folded mode: use stackedBars
    if barFrame.stackedBars then
      for _, bar in ipairs(barFrame.stackedBars) do
        if bar:IsShown() then
          bar:SetValue(previewValue)
        end
      end
    end
    -- Also update main bar in case folded mode uses it
    if barFrame.bar then
      barFrame.bar:SetValue(previewValue)
    end
  else
    -- Simple mode: use main bar
    if barFrame.bar then
      barFrame.bar:SetValue(previewValue)
    end
  end
  
  -- Update text
  if barConfig.display.showText and textFrame and textFrame.text then
    textFrame.text:SetText(previewValue)
  end
  
  -- Make sure bar is visible for preview
  barFrame:Show()
  if barConfig.display.showText then
    textFrame:Show()
  end
end

-- ===================================================================
-- INITIALIZATION
-- ===================================================================
C_Timer.After(2.0, function()
  ns.Display.ApplyAllBars()
end)

-- ===================================================================
-- ===================================================================
-- SHARED HELPER: Update a single bar's position AND size for a group.
-- Called from initial setup and both resize callbacks so position
-- always stays in sync when container padding/size changes.
-- ===================================================================
-- CDM GROUP CONTAINER SIZE DIRECT CALLBACK FOR AURA BARS
-- Called directly from CDMGroups ReflowIcons when dynamic container resizes.
-- This is more reliable than OnSizeChanged hooks alone because hooks
-- get lost when containers are recreated (spec change, group rebuild).
-- ===================================================================
function ns.Display.OnGroupContainerSizeChanged(groupName, newWidth, newHeight)
  if not ns.API or not ns.API.GetActiveBars or not ns.API.GetBarConfig then return end
  local activeBars = ns.API.GetActiveBars()
  for _, barNumber in ipairs(activeBars) do
    local barConfig = ns.API.GetBarConfig(barNumber)
    if barConfig and barConfig.display then
      local cfg = barConfig.display
      if cfg.anchorToGroup and cfg.anchorGroupName == groupName and cfg.matchGroupWidth then
        local barFrame = ns.Display.GetBarFrame and ns.Display.GetBarFrame(barNumber)
        if barFrame then
          UpdateBarForGroup(barNumber, cfg, barFrame, groupName)
        end
      end
    end
  end
end

-- ===================================================================
-- CDM GROUP CONTAINER SIZE HOOK FOR AURA BARS
-- Hooks container's OnSizeChanged - fires only when size changes
-- Zero CPU overhead when nothing is happening
-- ===================================================================
local hookedContainersForAuraBars = {}  -- [container] = true

local function OnContainerSizeChangedForAuraBars(container, width, height)
  if not width or not height or width <= 0 or height <= 0 then return end
  local groupName
  if ns.CDMGroups and ns.CDMGroups.groups then
    for name, group in pairs(ns.CDMGroups.groups) do
      if group.container == container then groupName = name break end
    end
  end
  if not groupName then return end
  if not ns.API or not ns.API.GetActiveBars or not ns.API.GetBarConfig then return end
  local activeBars = ns.API.GetActiveBars()
  for _, barNumber in ipairs(activeBars) do
    local barConfig = ns.API.GetBarConfig(barNumber)
    if barConfig and barConfig.display then
      local cfg = barConfig.display
      if cfg.anchorToGroup and cfg.anchorGroupName == groupName and cfg.matchGroupWidth then
        local barFrame = ns.Display.GetBarFrame and ns.Display.GetBarFrame(barNumber)
        if barFrame then
          UpdateBarForGroup(barNumber, cfg, barFrame, groupName)
        end
      end
    end
  end
end

-- Hook a container for size change events (Aura Bars)
function ns.Display.HookContainerForAnchoredBars(groupName)
  if not ns.CDMGroups or not ns.CDMGroups.groups then return end
  
  local group = ns.CDMGroups.groups[groupName]
  if not group or not group.container then return end
  
  local container = group.container
  if hookedContainersForAuraBars[container] then return end  -- Already hooked
  
  hookedContainersForAuraBars[container] = true
  container:HookScript("OnSizeChanged", OnContainerSizeChangedForAuraBars)
  
  -- Fire immediately in case the container was already sized before we hooked
  local w, h = container:GetWidth(), container:GetHeight()
  if w and h and w > 0 and h > 0 then
    OnContainerSizeChangedForAuraBars(container, w, h)
  end
end

-- ===================================================================
-- HIDEWHEN VISIBILITY HOOK
-- Hook CDMGroups.UpdateGroupVisibility so buff/debuff bars refresh
-- in sync with group visibility (mount, combat, death, target, etc.)
-- Same pattern as CooldownBars.lua and Resources.lua.
-- ===================================================================
local function InstallDisplayVisibilityHook()
  if not ns.CDMGroups or not ns.CDMGroups.UpdateGroupVisibility then return end
  if ns.Display._visHookInstalled then return end
  ns.Display._visHookInstalled = true
  
  hooksecurefunc(ns.CDMGroups, "UpdateGroupVisibility", function()
    if not ns.Display.RefreshAllBars then return end
    -- Lightweight: just re-evaluate each active bar's hideWhen
    local db = ns.API and ns.API.GetDB and ns.API.GetDB()
    if not db or not db.bars then return end
    for barNumber, barConfig in pairs(db.bars) do
      if barConfig and barConfig.tracking and barConfig.tracking.enabled then
        if ns.API and ns.API.RefreshDisplay then
          ns.API.RefreshDisplay(barNumber)
        end
      end
    end
  end)
end

local dispVisHookFrame = CreateFrame("Frame")
dispVisHookFrame:RegisterEvent("PLAYER_LOGIN")
dispVisHookFrame:SetScript("OnEvent", function(self, event)
  C_Timer.After(4, function()
    InstallDisplayVisibilityHook()
  end)
  self:UnregisterAllEvents()
end)

-- ===================================================================
-- LIBPLEEBUG FUNCTION WRAPPING
-- Wrap heavy functions for CPU profiling
-- ===================================================================
if P then
  -- Main Update Loop (heaviest)
  ns.Display.UpdateBar = P:Def("UpdateBar", ns.Display.UpdateBar, "Updates")
  ns.Display.UpdateDurationBar = P:Def("UpdateDurationBar", ns.Display.UpdateDurationBar, "Updates")
  
  -- Apply Functions
  ns.Display.ApplyAllBars = P:Def("ApplyAllBars", ns.Display.ApplyAllBars, "Apply")
  ns.Display.ApplyBar = P:Def("ApplyBar", ns.Display.ApplyBar, "Apply")
end

-- ===================================================================
-- END OF ArcUI_Display.lua
-- ===================================================================