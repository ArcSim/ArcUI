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

-- 12.1 secret-safe wrappers. The instance-id aura APIs Lua-ERROR when auras are secret, so never
-- call them with a secret (or nil) auraInstanceID. Returning nil makes the bar fill fall back
-- (holds last state) instead of crashing. Inert on live. All C_UnitAuras.GetAuraDuration /
-- GetAuraDataByAuraInstanceID CALL sites in this file route through these.
local _C_GetAuraDuration = C_UnitAuras and C_UnitAuras.GetAuraDuration
local _C_GetAuraData     = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
local function SafeGetAuraDuration(unit, aiid)
  if aiid == nil or (ns.API and ns.API.AurasSecret and ns.API.AurasSecret(unit)) then return nil end
  return _C_GetAuraDuration and _C_GetAuraDuration(unit, aiid)
end
local function SafeGetAuraData(unit, aiid)
  if aiid == nil or (ns.API and ns.API.AurasSecret and ns.API.AurasSecret(unit)) then return nil end
  return _C_GetAuraData and _C_GetAuraData(unit, aiid)
end

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

-- ===================================================================
-- FILL-SEGMENT FRAME LEVELS
-- The chrome above the fill sits at FIXED offsets from the bar frame:
-- tick overlay +22, border +23, text frames +25. Segment frames used to
-- take `base + i` with no cap, so any bar with more than ~21 stacks put
-- its top segments INTO the chrome band and covered it: on a 25-stack bar
-- the tick marks vanished at stack 23 (segment level 23 >= tick's 22) and
-- the border at 24-25 (>= border's 23). The "At Max" bar (+21) was buried
-- the same way. Compress the index into the reserved 1..20 band instead.
-- Segments are cumulative (each spans 0..i) so a higher index must still
-- draw over a lower one: the mapping is monotonic, and equal levels break
-- ties by creation order, which is ascending by index. Bars with <= 20
-- segments keep their exact previous levels.
-- ===================================================================
local SEGMENT_LEVEL_BAND = 20
local function SegmentLevel(baseLevel, i, count)
    if not count or count <= SEGMENT_LEVEL_BAND then
        return baseLevel + i
    end
    return baseLevel + 1 + math_floor((i - 1) * (SEGMENT_LEVEL_BAND - 1) / (count - 1))
end

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- ===================================================================
-- INITIALIZATION FLAG: Prevent bar flash during reload
-- Bars stay hidden until initialization completes (after PLAYER_ENTERING_WORLD + delay)
-- ===================================================================
local initializationComplete = false
-- true only while ns.Display.EnginePrebuild runs: lets the update path reach
-- the engine attach during the load window, before init is marked complete
local prebuildPass = false

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

  -- USE TEXTURE COLORS: a gradient is another multiply over the art, and even
  -- the "solid" branch below pushes barColor through SetGradient -- both have
  -- to become white for the texture's own colors to survive.
  if ns.API.IsNaturalFill(cfg) then
    local white = CreateColor(1, 1, 1, 1)
    texture:SetGradient(cfg.gradientDirection or "VERTICAL", white, white)
    return
  end

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

-- ═══════════════════════════════════════════════════════════════════════════
-- DEACTIVATION: Zero-CPU bars hidden by spec/talent conditions
-- When deactivated, all per-frame OnUpdate scripts are cleared and frames hidden.
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
    local scale = barFrame:GetEffectiveScale()
    local _, _hpx = GetPhysicalScreenSize()
    local onePx = (_hpx and _hpx > 0 and scale and scale > 0) and (768 / _hpx) / scale or 1

    local segInset = 0
    if barConfig.display.showBorder and (displayMode == "granular" or displayMode == "perStack") then
      local btRaw = barConfig.display.drawnBorderThickness or 2
      segInset = onePx * btRaw
    end

    -- Per-side Fill Inset awareness: mirror the fill's own insets so ticks
    -- track the ACTUAL fill area, not the frame. Only the modes whose fill
    -- honours the padding (granular/perStack segments + duration bars) —
    -- simple-mode fills don't inset, so their ticks don't either.
    local padL, padR, padT, padB = 0, 0, 0, 0
    if displayMode == "granular" or displayMode == "perStack" or displayMode == "duration" then
      padL = (barConfig.display.barPaddingL or 0) * onePx
      padR = (barConfig.display.barPaddingR or 0) * onePx
      padT = (barConfig.display.barPaddingT or 0) * onePx
      padB = (barConfig.display.barPaddingB or 0) * onePx
    end
    -- Along-axis start/far insets, honouring orientation + reverse fill
    -- (same mapping as the fill's segment loop)
    local insetAlongStart, insetAlongFar
    if isVertical then
      if isReverseFill then insetAlongStart, insetAlongFar = segInset + padT, segInset + padB
      else insetAlongStart, insetAlongFar = segInset + padB, segInset + padT end
    else
      if isReverseFill then insetAlongStart, insetAlongFar = segInset + padR, segInset + padL
      else insetAlongStart, insetAlongFar = segInset + padL, segInset + padR end
    end

    local tickTotalSize = isVertical and barFrame:GetHeight() or barFrame:GetWidth()
    local tickInsetSize = tickTotalSize - insetAlongStart - insetAlongFar

    local tickHeightPct  = barConfig.display.tickHeightPercent or 100
    local heightAnchor   = barConfig.display.tickHeightAnchor  or "center"
    local thicknessAnchor = barConfig.display.tickThicknessAnchor or "center"
    local barCrossSize   = isVertical and barFrame:GetWidth() or barFrame:GetHeight()
    local borderInset    = 0
    if barConfig.display.showBorder and (displayMode == "granular" or displayMode == "perStack") then
      local btRawCross = barConfig.display.drawnBorderThickness or 0
      borderInset = onePx * btRawCross
    end
    local crossPads = isVertical and (padL + padR) or (padT + padB)
    local availCross = math.max(1, barCrossSize - 2 * borderInset - crossPads)

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
          local _totalPx = math_floor(tickInsetSize / onePx + 0.5)
          rawPos = insetAlongStart + math_floor(tickValue / tickMaxValue * _totalPx) * onePx
        else
          rawPos = insetAlongStart + tickValue / tickMaxValue * tickInsetSize
        end

        -- Thickness anchor: nudge tick so its centre/end aligns with rawPos
        local posAlong = rawPos
        if thicknessAnchor == "center" then
          posAlong = rawPos - halfThick
        elseif thicknessAnchor == "end" then
          posAlong = rawPos - pixelThickness
        end

        -- PIXEL SNAP (ns.Display.tickPixelSnap, default on): quantize the tick's
        -- DRAWN EDGE to the physical pixel grid. The textures are unsnapped, so
        -- an edge landing mid-pixel rasterizes with partial coverage — at
        -- fractional positions (e.g. 5% spacing) each tick got a different
        -- fraction, rendering some crisp-1px and some soft-2px = "unevenly wide"
        -- ticks. Thickness is already an exact physical-pixel multiple, so with
        -- the edge snapped every tick draws identical. Position error <= half a
        -- pixel. Kill switch for in-game A/B:
        --   /run ArcUI_Display.tickPixelSnap = false  (then /reload)
        if ns.Display.tickPixelSnap ~= false then
          posAlong = math_floor(posAlong / onePx + 0.5) * onePx
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

-- Tick-edge pixel snapping (see PIXEL SNAP inside UpdateTickMarks).
-- Runtime kill switch: /run ArcUI_Display.tickPixelSnap = false  (then /reload)
ns.Display.tickPixelSnap = true

-- ===================================================================
-- BUTTON-OWNED CHROME spec (custom aura bars, Hide When Inactive):
-- resolves the bar's background/border styling into the table
-- BD.SetOwnChrome / the attach opts consume -- the chrome is then built as
-- CHILDREN OF THE ENGINE BUTTON so the whole visible bar shows/hides with
-- the aura natively (presence is a secret boolean and must never be read).
-- ===================================================================
-- Tick marks for the button-owned chrome: replicates UpdateTickMarks'
-- SIMPLE-mode math (value list per tickMode, fraction*size, center-anchored
-- thickness, physical-pixel snap). Positions are px offsets from the FILL
-- ORIGIN; BD places the textures. "custom" tickMode (ability thresholds) is
-- not mirrored here.
local function BuildOwnChromeTicks(d, barFrame, maxValue, durationMode)
  if not d.showTickMarks or not maxValue or maxValue <= 1 then return nil end
  local bar = barFrame.bar
  if not bar then return nil end
  local vertical = d.barOrientation == "vertical"
  local size = vertical and (bar:GetHeight() or 0) or (bar:GetWidth() or 0)
  local cross = vertical and (bar:GetWidth() or 0) or (bar:GetHeight() or 0)
  if size <= 1 then return nil end
  local _s = barFrame:GetEffectiveScale()
  local _, _h = GetPhysicalScreenSize()
  local onePx = (_h and _h > 0 and _s and _s > 0) and (768 / _h) / _s or 1
  local thick = onePx * (d.tickThickness or 2)
  local mode = d.tickMode or "percent"
  if durationMode and mode == "all" and maxValue > 100 then mode = "percent" end
  local values = {}
  if mode == "all" then
    for i = 1, math_floor(maxValue) - 1 do values[#values + 1] = i end
  elseif mode == "percent" then
    local pct = d.tickPercent or 10
    local num = math_floor(100 / pct)
    for i = 1, num - 1 do
      local v = maxValue * (i * pct / 100)
      if v > 0 and v < maxValue then values[#values + 1] = v end
    end
  end
  if #values == 0 then return nil end
  local pos = {}
  for i, v in ipairs(values) do
    local raw = (v / maxValue) * size - thick / 2
    pos[i] = math_floor(raw / onePx + 0.5) * onePx
  end
  return {
    positions = pos,
    color = d.tickColor or { r = 0, g = 0, b = 0, a = 1 },
    thicknessPx = thick,
    spanPx = math.max(1, cross * ((d.tickHeightPercent or 100) / 100)),
    vertical = vertical,
    reverse = d.barReverseFill or false,
  }
end

-- NAME TEXT for engine-owned chrome ("Hide When Inactive" custom aura bars).
-- The native nameFrame is UIParent-parented, so it cannot follow the engine
-- button's secret visibility and gets suppressed with the rest of the native
-- chrome -- which left the bar NAMELESS while shown (Rend report). The recipe
-- carries a copy: same text, font, shadow and the exact on-screen spot,
-- expressed as an offset from the FILL center (the engine button is
-- SetAllPoints over barFrame.bar, so button coordinates ARE fill coordinates).
-- The name on these bars is STATIC -- presence is unreadable so there is no
-- dynamic name source -- so a build-time snapshot is exact, not approximate.
local function BuildOwnChromeName(barConfig, barFrame, nameFrame)
  local d = barConfig.display
  if not (d.showName and nameFrame and nameFrame.text) then return nil end
  local t = barConfig.tracking or {}
  local text = t.buffName or t.spellName
  if (not text or text == "") and t.spellID and C_Spell.GetSpellName then
    text = C_Spell.GetSpellName(t.spellID)
  end
  if not text or text == "" then return nil end
  -- exact rendered position of the native text, relative to the fill center
  -- (covers every nameAnchor mode incl. FREE; nil rects -> centered fallback)
  local bar = barFrame.bar or barFrame
  local bx, by = bar:GetCenter()
  local nx, ny = nameFrame.text:GetCenter()
  local dx, dy = 0, 0
  if bx and by and nx and ny then dx, dy = nx - bx, ny - by end
  local fontPath, fontSize, fontFlags = nameFrame.text:GetFont()
  local shX, shY = nameFrame.text:GetShadowOffset()
  local sr, sg, sb, sa = nameFrame.text:GetShadowColor()
  return {
    text = text,
    fontPath = fontPath or "Fonts\\FRIZQT__.TTF",
    fontSize = fontSize or 14,
    fontFlags = fontFlags or "OUTLINE",
    color = d.nameColor or { r = 1, g = 1, b = 1, a = 1 },
    dx = dx, dy = dy,
    shadowX = shX or 1, shadowY = shY or -1,
    shadowColor = { r = sr or 0, g = sg or 0, b = sb or 0, a = sa or 1 },
  }
end

local function BuildOwnChrome(barConfig, barFrame, tickMaxValue, durationMode, nameFrame)
  local d = barConfig.display
  local _s = barFrame:GetEffectiveScale()
  local _, _h = GetPhysicalScreenSize()
  local onePx = (_h and _h > 0 and _s and _s > 0) and (768 / _h) / _s or 1
  local bgTex
  if LSM and d.backgroundTexture and d.backgroundTexture ~= "Solid" then
    bgTex = LSM:Fetch("background", d.backgroundTexture, true)
  end
  return {
    bgShown = d.showBackground and true or false,
    bgColor = d.backgroundColor or { r = 0.2, g = 0.2, b = 0.2, a = 0.8 },
    bgTexture = bgTex,
    borderShown = d.showBorder and true or false,
    borderColor = d.borderColor or { r = 0, g = 0, b = 0, a = 1 },
    borderPx = onePx * (d.drawnBorderThickness or 2),
    ticks = BuildOwnChromeTicks(d, barFrame, tickMaxValue, durationMode),
    name = BuildOwnChromeName(barConfig, barFrame, nameFrame),
  }
end

-- ===================================================================
-- UPDATE SPECIFIC BAR
-- ===================================================================
-- TOTEM-LIKE BARS (pet / totem / ground) NEVER enter the 12.1 aura-slot engine.
-- Nothing about them changed in 12.1: their duration comes from
-- GetTotemDuration(slot), an ordinary duration object that aura secrecy never
-- touched, so the pre-aura-slot path still works and is the correct one.
--
-- Arming the engine for them did silent damage. The attach handed OUR duration
-- FontString to the AuraButton's own timer (BD.ApplyStyle -> SetDurationText),
-- which then never fires because there is no aura behind a totem, and the region
-- becomes access-constrained the moment initializeFrame returns so our own
-- DurationTextBinding cannot drive it either. The fill kept working (that is our
-- own StatusBar, which the engine never took) while the countdown went blank:
-- exactly the Call Dreadstalkers report, with `Attach: retarget-only (idKey=760)`
-- in the ArcBarDur log as the fingerprint.
-- CUSTOM MAX for totem/pet bars. Maps remaining SECONDS to a 0..1 bar value.
-- Aura bars cannot have a custom max on 12.1 because the engine timer takes no
-- maximum, but these bars are ours end to end, so they can. The explicit plateau
-- point past the max is what makes the bar sit full (drain) or empty (fill) while
-- the totem still has longer left than the user's window, rather than trusting
-- endpoint clamping. Cached per (max, direction) -- these are pure data.
local totemMaxCurves = {}
local function GetTotemMaxCurve(maxValue, fillMode)
  if not (C_CurveUtil and C_CurveUtil.CreateCurve) then return nil end
  if not maxValue or maxValue <= 0 then return nil end
  local key = string_format("%s:%s", tostring(maxValue), tostring(fillMode))
  local curve = totemMaxCurves[key]
  if curve then return curve end
  curve = C_CurveUtil.CreateCurve()
  if fillMode == "fill" then
    curve:AddPoint(0, 1); curve:AddPoint(maxValue, 0); curve:AddPoint(99999, 0)
  else
    curve:AddPoint(0, 0); curve:AddPoint(maxValue, 1); curve:AddPoint(99999, 1)
  end
  totemMaxCurves[key] = curve
  return curve
end

-- CDM TIMER MIRROR "fill" mode.
-- The mirror re-pushes CDM's own SetValue, which is REMAINING (CooldownViewer's
-- RefreshCooldownInfo does SetMinMaxValues(0, duration) + SetValue(currentTime)),
-- so our bar can only ever DRAIN. Producing elapsed would need duration minus
-- remaining, arithmetic on two secrets, and the curve escape is closed as well:
-- LuaCurveObject:Evaluate is AllowedWhenUntainted, so it refuses a secret x.
--
-- So we do not invert the value, we paint the OTHER SIDE of it. A texture
-- anchored from the drain texture's trailing edge to the end of the bar IS the
-- elapsed region, and it resizes itself as the drain texture shrinks. Pure
-- C-side layout, nothing read, nothing compared. The drain texture is alpha'd
-- out so only the elapsed side paints.
--
-- Which END it grows from is the drain bar's reverse-fill, inverted: the gap the
-- drain leaves is always on the opposite side from its anchor.
local function ApplyMirrorFillLayer(barFrame, barConfig, baseColor, isVertical, drainReverse, enabled, staticTex)
  local tex = barFrame._mirrorFillTex
  local sb = barFrame.bar
  local drainTex = sb and sb:GetStatusBarTexture()

  if not enabled then
    -- the texture object is KEPT (pooled) but the mode is off. Everything that
    -- keys off "is fill mode on" must read the FLAG, never the texture's
    -- existence -- the mirror hook did the latter and went on forcing the drain
    -- to alpha 0 after a switch back to drain, leaving a permanently blank bar.
    barFrame._mirrorFillActive = nil
    if tex then
      tex:Hide()
      -- detach any Keep-Texture-Still mask so a later non-static pass (or the
      -- drain look itself) never renders through a stale cut
      if barFrame._mirrorFillMaskAttached then
        tex:RemoveMaskTexture(barFrame._mirrorFillMask)
        barFrame._mirrorFillMaskAttached = nil
        barFrame._mirrorFillMask:Hide()
      end
    end
    if drainTex then
      drainTex:SetAlpha(1)
      drainTex:SetVertexColor(1, 1, 1, 1)
    end
    if sb then
      sb:SetAlpha(1)
      sb:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
    end
    return
  end
  if not drainTex then return end
  barFrame._mirrorFillActive = true

  if not tex then
    tex = barFrame:CreateTexture(nil, "ARTWORK")
    barFrame._mirrorFillTex = tex
  end

  local path = "Interface\\TargetingFrame\\UI-StatusBar"
  if LSM and barConfig.display.texture then
    local fetched = LSM:Fetch("statusbar", barConfig.display.texture)
    if fetched then path = fetched end
  end
  tex:SetTexture(path)
  tex:SetVertexColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)

  tex:ClearAllPoints()
  if isVertical then
    if drainReverse then           -- drain hugs the TOP, elapsed grows from the bottom
      tex:SetPoint("TOPLEFT", drainTex, "BOTTOMLEFT", 0, 0)
      tex:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
    else                           -- drain hugs the BOTTOM, elapsed grows from the top
      tex:SetPoint("BOTTOMLEFT", drainTex, "TOPLEFT", 0, 0)
      tex:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, 0)
    end
  else
    if drainReverse then           -- drain hugs the RIGHT, elapsed grows from the left
      tex:SetPoint("TOPLEFT", sb, "TOPLEFT", 0, 0)
      tex:SetPoint("BOTTOMRIGHT", drainTex, "BOTTOMLEFT", 0, 0)
    else                           -- drain hugs the LEFT, elapsed grows from the right
      tex:SetPoint("TOPLEFT", drainTex, "TOPRIGHT", 0, 0)
      tex:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
    end
  end

  -- ── STATIC-TEXTURE FILL ("Keep Texture Still") ────────────────────────────
  -- The default fill layer above anchors a plain Texture across the GROWING gap,
  -- so the art is STRETCHED to whatever width that gap is. Uniform textures hide
  -- it; patterned ones (Diagonal, Rocks, Outline) visibly distort. Reported by
  -- cheerful_chipmunk_07698 against 3.8.1; the ask is the pre-12.1 WeakAuras
  -- look: texture stays still at FULL SIZE, the colour flows through it, and
  -- the unfilled part stays CLEAR (his Outline sits over a Blizzard HP tracker,
  -- so painting the unfilled part covers his UI -- a first cut did exactly
  -- that with a background-coloured drain and was rejected).
  --
  -- Mechanism: draw the whole texture ONCE at full size, then reveal only the
  -- elapsed region with a MASK anchored across the gap -- the SAME drainTex
  -- edge anchors the stretched path uses, so no value is ever computed
  -- (elapsed = max - remaining would be secret arithmetic in instances; an
  -- anchor to the drain edge needs no numbers at all). The mask is a SOLID
  -- WHITE rect: stretching solid white distorts nothing, which is the whole
  -- trick -- the stretching moved from the ART to the mask.
  -- NEAREST + CLAMPTOBLACKADDITIVE per the proven mask recipe: the default
  -- bilinear filter fades the outer half-texel of an 8x8 stretched over a
  -- bar into a visible soft edge.
  if staticTex then
    tex:ClearAllPoints()
    tex:SetAllPoints(sb)                      -- full size, never resized => never stretched
    tex:SetVertexColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)

    local mask = barFrame._mirrorFillMask
    if not mask then
      mask = barFrame:CreateMaskTexture()
      mask:SetTexture("Interface\\Buttons\\WHITE8X8",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE", "NEAREST")
      barFrame._mirrorFillMask = mask
    end
    mask:ClearAllPoints()
    if isVertical then
      if drainReverse then
        mask:SetPoint("TOPLEFT", drainTex, "BOTTOMLEFT", 0, 0)
        mask:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
      else
        mask:SetPoint("BOTTOMLEFT", drainTex, "TOPLEFT", 0, 0)
        mask:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, 0)
      end
    else
      if drainReverse then
        mask:SetPoint("TOPLEFT", sb, "TOPLEFT", 0, 0)
        mask:SetPoint("BOTTOMRIGHT", drainTex, "BOTTOMLEFT", 0, 0)
      else
        mask:SetPoint("TOPLEFT", drainTex, "TOPRIGHT", 0, 0)
        mask:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
      end
    end
    mask:Show()
    if not barFrame._mirrorFillMaskAttached then
      tex:AddMaskTexture(mask)
      barFrame._mirrorFillMaskAttached = true
    end
    -- HIDDEN at apply time, exactly like the stretched path (same comment at
    -- the end of this function): the mirror's min/max hook shows the fill on
    -- a real timer push and hides it on the inactive (0,0) push. A style-time
    -- Show() here revealed the FULL static texture whenever no timer was
    -- running -- an empty bar read as a full one (Arc's screenshot). Empty
    -- now shows nothing but the bar's own background/border, like every
    -- other fill bar at zero.
    tex:Hide()

    -- drain killed at the frame, exactly like the stretched path: it only
    -- supplies the boundary through its texture's anchors, which still track
    -- on an alpha-0 StatusBar
    sb:SetAlpha(0)
    sb:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, 0)
    drainTex:SetAlpha(0)
    return
  end

  -- leaving static mode: detach the mask or the stretched fill (and any later
  -- static pass against a REPLACED drain texture) renders through a stale cut
  if barFrame._mirrorFillMaskAttached then
    tex:RemoveMaskTexture(barFrame._mirrorFillMask)
    barFrame._mirrorFillMaskAttached = nil
    barFrame._mirrorFillMask:Hide()
  end

  -- KILL THE REMAINING SIDE AT THE FRAME. Per-texture alpha kept losing: the
  -- branch above re-runs SetVertexColor(1,1,1,1) and SetStatusBarColor on the
  -- drain every update, SetStatusBarTexture hands back a FRESH texture region on
  -- any config change, and the Use Texture Colors hook rewrites tints on its own.
  -- Frame alpha is immune to all of it -- an alpha-0 StatusBar renders nothing
  -- whatever its textures say -- and layout is unaffected, so the fill layer's
  -- anchor to the drain texture's edge still tracks. The colour/texture alphas
  -- stay as belt and braces.
  sb:SetAlpha(0)
  sb:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, 0)
  drainTex:SetAlpha(0)
  -- shown/hidden by the mirror's own min/max hook: an inactive CDM entry pushes a
  -- literal (0, 0), which would otherwise leave a zero-width drain texture and a
  -- full-width "elapsed" gap, i.e. a bar that reads FULL after the timer ends
  tex:Hide()
end

local TOTEM_LIKE_TRACKTYPES = { pet = true, totem = true, ground = true }
local function IsTotemLikeBar(barConfig)
  local tt = barConfig and barConfig.tracking and barConfig.tracking.trackType
  return tt ~= nil and TOTEM_LIKE_TRACKTYPES[tt] == true
end

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

  -- CUSTOM AURA STACK BAR (12.1, no CDM entry): presence/stacks are
  -- unreadable (secret); the engine ApplicationBar binding drives the fill
  -- and the ArcStacks/ArcTimer overlays drive the texts. The bar frame is
  -- treated as permanently active (chrome always renders).
  local isCustomAura = barConfig.tracking.customAura
    and ns.BarDuration and ns.BarDuration.IsAvailable and ns.BarDuration.IsAvailable()
  if isCustomAura then
    active = true
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
  if not initializationComplete and not optionsOpen and not prebuildPass then
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
  if barFrames[barNumber] then
    local bfSet = barFrames[barNumber]
    if bfSet._arcHideWhenAlpha ~= hideWhenFadeAlpha then
      bfSet._arcHideWhenAlpha = hideWhenFadeAlpha
      -- APPLY ON THE SPOT (Rule 0): the appearance styler is the only other
      -- writer of this alpha and it never runs on combat/condition edges —
      -- a >0 Hidden Opacity painted out of combat stayed painted IN combat
      -- (the Freezing-stacks 15% report; 0% worked because that path hides
      -- instead of fading). Repaint the moment the multiplier changes.
      if bfSet.barFrame then
        bfSet.barFrame:SetAlpha((bfSet._arcBaseOpacity or 1) * hideWhenFadeAlpha)
      end
    end
  end
  
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
  
  -- Early exit if bar shouldn't show and options not open.
  -- NOT during the prebuild: this return sits BEFORE the engine attach, and
  -- with Hide When Inactive on (aura down at login) it would swallow the
  -- bar's only chance to create its engine slot — the same trap the
  -- duration-bar path already guards. The prebuild hides all frames after.
  -- MID-SESSION ARM PASS (the texture fix's twin): re-enabling Show Duration
  -- on a hidden-inactive stack bar hit this return before the countdown-host
  -- attach ever ran — nothing armed, the first in-combat activation DEFERRED
  -- slot creation (secret), and the countdown only appeared a fight later.
  -- When the host is enabled but unarmed, fall through ONCE to arm at the
  -- desk, then restore the hidden state (below, after the attach block).
  local armPassStack = false
  if not shouldShow and not optionsOpen and not prebuildPass then
    if not deactivate and ns.API and ns.API.IS_121
       and barConfig.display.showDuration
       and not (barConfig.tracking and barConfig.tracking.customAura)
       and not IsTotemLikeBar(barConfig)
       and ns.BarDuration and ns.BarDuration.IsAvailable and ns.BarDuration.IsAvailable() then
      local cdA = barConfig.tracking.cooldownID
      local tsA = barConfig.tracking.trackedSpellID or barConfig.tracking.spellID
      if ((cdA or 0) > 0) or ((tsA or 0) > 0) then
        local fr = barFrames[barNumber]
        local bf = fr and fr.barFrame
        if not (bf and bf._arcStackDurArmed) then armPassStack = true end
      end
    end
    if not armPassStack then
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
  -- BAR MODE (existing code)
  -- ═══════════════════════════════════════════════════════════════════
  -- Hide icon frame if in bar mode
  SafeHide(iconFrame)
  
  -- Use cached optionsOpen from function start for preview mode.
  -- Custom aura bars force active=true (presence unreadable) -- treat them
  -- as previewable whenever the panel is open, like the duration bars.
  local showPreview = optionsOpen and (not active or previewMode or isCustomAura)

  -- HIDE WHEN INACTIVE (ownership model): move the bar chrome onto the
  -- engine button so the whole visible bar appears/vanishes with the aura
  -- natively; our barFrame stays SHOWN as the invisible container host and
  -- its native chrome is suppressed. The options panel restores the native
  -- chrome so the bar is always editable like every other bar.
  local engineOwnsChrome = isCustomAura and barConfig.behavior
    and barConfig.behavior.hideWhenInactive and not optionsOpen
  if isCustomAura and barConfig.behavior and barConfig.behavior.hideWhenInactive then
    if barFrame.bg then
      barFrame.bg:SetShown((not engineOwnsChrome) and (barConfig.display.showBackground and true or false))
    end
    if barFrame.tickOverlay then barFrame.tickOverlay:SetShown(not engineOwnsChrome) end
    if ns.BarDuration and ns.BarDuration.SetOwnChrome then
      ns.BarDuration.SetOwnChrome(barFrame, engineOwnsChrome and BuildOwnChrome(barConfig, barFrame, maxStacks, nil, nameFrame) or nil)
    end
  end

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

  if not isCustomAura and not optionsOpen and not needsSetup and not optionsTransition and barFrame._lastActive == active and barFrame._lastActive ~= nil then
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
      -- Duration text refresh on the fast-path. The C-side DurationTextBinding
      -- only re-reads its duration when Bind is re-called; the full path below
      -- does that, but this fast-path returns before reaching it. So a buff
      -- REFRESH (duration changed while active stayed true — e.g. Marrowrend
      -- re-applying Bone Shield) would leave the countdown stuck on the old
      -- value. Re-bind here so refreshes are caught on the fast-path too. Only
      -- the GetAuraInfo binding source needs this: the pre-12.0.7 OnUpdate
      -- fallback re-reads every tick and totems poll on their own.
      if barConfig.display.showDuration and durationFrame and durationFontString
         and durationFontString.GetAuraInfo and ns.DurationText and ns.DurationText.IsSupported() then
        local auraID, unit = durationFontString:GetAuraInfo()
        if auraID and unit then
          local durObj = SafeGetAuraDuration(unit, auraID)
          if durObj then
            ns.DurationText.Bind(durationFrame.text, durObj, barConfig.display.durationDecimals or 1, unit, auraID, barConfig.display)
          end
        end
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
        bar:SetFrameLevel(SegmentLevel(barFrame:GetFrameLevel(), i, numBars))
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
    local _s2 = barFrame:GetEffectiveScale()
    local _, _h2 = GetPhysicalScreenSize()
    local _onePx2 = (_h2 and _h2 > 0 and _s2 and _s2 > 0) and (768 / _h2) / _s2 or 1
    if barConfig.display.showBorder then
      local btRaw = barConfig.display.drawnBorderThickness or 2
      segInset = _onePx2 * btRaw
    end

    -- Per-side fill padding (aura bars, in physical px -> WoW units). Along the fill
    -- axis the padding stacks on top of the border inset; perpendicular to the fill
    -- it is padding-only so that zero padding keeps the current look exactly.
    local padLw = (barConfig.display.barPaddingL or 0) * _onePx2
    local padRw = (barConfig.display.barPaddingR or 0) * _onePx2
    local padTw = (barConfig.display.barPaddingT or 0) * _onePx2
    local padBw = (barConfig.display.barPaddingB or 0) * _onePx2
    local insetLw, insetRw, insetTw, insetBw
    if isBarVertical then
      insetTw, insetBw = segInset + padTw, segInset + padBw  -- fill axis
      insetLw, insetRw = padLw, padRw                        -- perpendicular
    else
      insetLw, insetRw = segInset + padLw, segInset + padRw  -- fill axis
      insetTw, insetBw = padTw, padBw                        -- perpendicular
    end
    -- Fill-axis start/far insets, honouring orientation + reverse fill.
    local startInset, farInset
    if isBarVertical then
      if isBarReverseFill then startInset, farInset = insetTw, insetBw
      else startInset, farInset = insetBw, insetTw end
    else
      if isBarReverseFill then startInset, farInset = insetRw, insetLw
      else startInset, farInset = insetLw, insetRw end
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
    local totalSize = (isBarVertical and barFrame:GetHeight() or barFrame:GetWidth()) - startInset - farInset
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
      local offset  = startInset + startPixel * pmult
      local barSize = sizePixels * pmult

      -- PERFORMANCE: Only apply expensive setup when appearance changes
      if needsSetup or not bar._setupDone then
        bar:SetOrientation(barOrientation)
        bar:SetReverseFill(isBarReverseFill)
        bar:SetRotatesTexture(rotateBarTex)
        bar:SetStatusBarTexture(texturePath)
        bar:SetFrameLevel(SegmentLevel(barFrame:GetFrameLevel(), i, numBars))
        ApplyBarSmoothing(bar, enableSmooth)
        bar:ClearAllPoints()
        if isBarVertical then
          if isBarReverseFill then
            bar:SetPoint("TOPLEFT",  barFrame, "TOPLEFT",  insetLw, -offset)
            bar:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", -insetRw, -offset)
            if i == numBars then
              bar:SetPoint("BOTTOMLEFT",  barFrame, "BOTTOMLEFT",  insetLw,  farInset)
              bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -insetRw, farInset)
            else
              bar:SetHeight(barSize)
            end
          else
            bar:SetPoint("BOTTOMLEFT",  barFrame, "BOTTOMLEFT",  insetLw, offset)
            bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -insetRw, offset)
            if i == numBars then
              bar:SetPoint("TOPLEFT",  barFrame, "TOPLEFT",  insetLw, -farInset)
              bar:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", -insetRw, -farInset)
            else
              bar:SetHeight(barSize)
            end
          end
        else
          if isBarReverseFill then
            bar:SetPoint("TOPRIGHT",    barFrame, "TOPRIGHT",    -offset, -insetTw)
            bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -offset,  insetBw)
            if i == numBars then
              bar:SetPoint("TOPLEFT",    barFrame, "TOPLEFT",     farInset, -insetTw)
              bar:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT",  farInset,  insetBw)
            else
              bar:SetWidth(barSize)
            end
          else
            bar:SetPoint("TOPLEFT",    barFrame, "TOPLEFT",    offset, -insetTw)
            bar:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", offset,  insetBw)
            if i == numBars then
              bar:SetPoint("TOPRIGHT",    barFrame, "TOPRIGHT",    -farInset, -insetTw)
              bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -farInset,  insetBw)
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
    elseif isCustomAura then
      -- engine ArcStacks overlays the live count; blank ours (customs pass 0)
      textFrame.text:SetText("")
    else
      textFrame.text:SetText(stacks)
    end
    local tc = barConfig.display.textColor
    textFrame.text:SetTextColor(tc.r, tc.g, tc.b, tc.a)
  end
  
  -- Update duration text (pass secret value directly from GetText/GetValue to SetText)
  -- 12.1 CDM-SOURCED STACK BARS: the live duration reads below are
  -- unreadable under aura secrecy (combat/instances) -- the countdown went
  -- blank in combat while the stack fill (secret-sink SetValue) kept
  -- working. The duration BARS already solved this with the engine's
  -- text-only ArcTimer binding; route these bars' countdown through the
  -- same one (attached after this block) and skip the live machinery.
  local engineDurText = false
  if not isCustomAura and not IsTotemLikeBar(barConfig) and ns.API and ns.API.IS_121
     and barConfig.display.showDuration and durationFrame then
    local cd0 = barConfig.tracking.cooldownID
    local ts0 = barConfig.tracking.trackedSpellID or barConfig.tracking.spellID
    engineDurText = ((cd0 and cd0 > 0) or (ts0 and ts0 > 0)) and true or false
  end
  -- CUSTOM (engine lane): the button's ArcTimer overlays the countdown -- keep
  -- the frame shown for anchoring, text clear, and skip the source machinery.
  if (isCustomAura or engineDurText) and not showPreview and barConfig.display.showDuration and durationFrame then
    if ns.DurationText and ns.DurationText.Unbind then ns.DurationText.Unbind(durationFrame.text) end
    durationFrame:SetScript("OnUpdate", nil)
    durationFrame.isActive = false
    durationFrame.sourceBar = nil
    durationFrame.text:SetText("")
    durationFrame:Show()
  elseif barConfig.display.showDuration and durationFrame then
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

    -- v3.7.2: a DurationTextBinding may be driving this fontstring for a live
    -- aura countdown. Only the GetAuraInfo-active path (below) binds it; every
    -- other source/branch sets text manually, so release it unless we are on
    -- that path (or it overwrites the manual / preview value).
    local bindingPath = active and durationFontString and durationFontString.GetAuraInfo
    if not bindingPath and ns.DurationText then
      ns.DurationText.Unbind(durationFrame.text)
    end

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
        local durObj = SafeGetAuraDuration(unit, auraID)
        if ns.DurationText and ns.DurationText.IsSupported() then
          -- 12.0.7: Blizzard drives the countdown text C-side — no Lua OnUpdate.
          durationFrame:SetScript("OnUpdate", nil)
          durationFrame.isActive = false
          durationFrame.sourceBar = nil
          if durObj then
            ns.DurationText.Bind(durationFrame.text, durObj, decimals, unit, auraID, barConfig.display)
          else
            ns.DurationText.Unbind(durationFrame.text)
          end
        else
          -- Fallback (pre-12.0.7): poll GetRemainingDuration() each tick.
          durationFrame.sourceBar = durationFontString
          durationFrame.isActive = true

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

              local d = SafeGetAuraDuration(currentUnit, currentAuraID)
              if d then
                self.text:SetFormattedText(DURATION_FMT[self.storedDecimals] or "%.1f", d:GetRemainingDuration())
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

          if durObj then
            durationFrame.text:SetFormattedText(DURATION_FMT[decimals] or "%.1f", durObj:GetRemainingDuration())
          end
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
        if ns.DurationText then ns.DurationText.Unbind(durationFrame.text) end
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

  -- 12.1 CDM-SOURCED STACK BAR countdown: text-only engine binding on a
  -- dedicated HOST frame (no .bar field, so BD creates no fill overlays --
  -- the stack fill stays Core-driven). Same ArcTimer mechanism as the aura
  -- duration bars and aura textures; the engine shows the countdown exactly
  -- while the aura is up, in any context including combat and keys.
  if engineDurText and not showPreview and ns.BarDuration and ns.BarDuration.Attach then
    -- MODE-SWITCH hygiene: a bar flipped from DURATION mode still carries its
    -- bar-keyed engine attach (fill overlay + countdown) — release it so the
    -- old lane can't keep driving this bar's fill/text alongside the host
    if ns.BarDuration.Detach then ns.BarDuration.Detach(barFrame) end
    local host = barFrame._arcStackDurHost
    if not host then
      host = CreateFrame("Frame", nil, barFrame)
      host:SetAllPoints(barFrame)
      barFrame._arcStackDurHost = host
    end
    host:Show()
    local sdUnit = "player"
    if barConfig.tracking.trackType == "debuff" then
      sdUnit = "target"
    elseif barConfig.tracking.trackType == "petbuff" then
      sdUnit = "pet"
    end
    local sdCd = barConfig.tracking.cooldownID
    local sdTs = barConfig.tracking.trackedSpellID or barConfig.tracking.spellID
    local sdFmt, sdColorKey
    if barConfig.display.durationTextColorEnabled and ns.DurationText and ns.DurationText.GetLiveSecondsColorFormatter then
      -- persistent per-fs formatter (live band-edit application, see DT)
      sdFmt = ns.DurationText.GetLiveSecondsColorFormatter(durationFrame and durationFrame.text,
        barConfig.display, barConfig.display.durationDecimals or 1)
      sdColorKey = ns.DurationText.SecondsColorKey and ns.DurationText.SecondsColorKey(barConfig.display)
    end
    local sdFontPath = "Fonts\\FRIZQT__.TTF"
    if LSM and barConfig.display.durationFont then
      local ff = LSM:Fetch("font", barConfig.display.durationFont)
      if ff and ff ~= "" then sdFontPath = ff end
    end
    if ns.TraceTap then ns.TraceTap("BAR", string.format(
      "bar %s stack-durText host attach: cd=%s ts=%s unit=%s colorKey=%s tce=%s",
      tostring(barNumber), tostring(sdCd), tostring(sdTs), sdUnit,
      tostring(sdColorKey), tostring(barConfig.display.durationTextColorEnabled))) end
    ns.BarDuration.Attach(host, durationFrame and durationFrame.text, sdCd, sdTs, sdUnit, {
      showDuration = true,
      durFontPath = sdFontPath,
      durFontSize = barConfig.display.durationFontSize or 18,
      durOutline = GetOutlineFlag(barConfig.display.durationOutline),
      durDecimals = barConfig.display.durationDecimals or 1,
      durationColor = barConfig.display.durationColor or {r=1, g=1, b=1, a=1},
      durFormatter = sdFmt,
      textColorEnabled = barConfig.display.durationTextColorEnabled and true or false,
      colorKey = sdColorKey,
    })
    -- LIVE style re-push (the Textures pattern): the retarget path
    -- deliberately never re-applies opts, and ApplyAppearance only styles
    -- bar-keyed attaches — this is what makes font/decimals edits and the
    -- seconds-color band toggle take effect without a reload (BD detects a
    -- formatter/colorKey change and recreates the slot with the new rules).
    if ns.BarDuration.ApplyStyle then
      ns.BarDuration.ApplyStyle(host, durationFrame, true,
        barConfig.display.durationDecimals or 1,
        barConfig.display.durationColor or {r=1, g=1, b=1, a=1},
        nil, nil, sdFmt,
        barConfig.display.durationTextColorEnabled and true or false,
        sdColorKey)
    end
    barFrame._arcStackDurArmed = true
  elseif barFrame._arcStackDurHost and not engineDurText then
    -- Show Duration toggled off (or bar re-identified): release the binding
    if ns.BarDuration and ns.BarDuration.Detach then
      ns.BarDuration.Detach(barFrame._arcStackDurHost)
    end
    barFrame._arcStackDurHost:Hide()
    barFrame._arcStackDurArmed = nil
  end

  -- ARM PASS exit: the countdown host is armed — restore the hidden-inactive
  -- state and stop (everything below is visual work for a bar that must stay
  -- hidden; the binding survives the hide and drives on the next activation).
  if armPassStack then
    SafeHide(barFrame)
    SafeHide(textFrame)
    SafeHide(durationFrame)
    SafeHide(iconFrame)
    SafeHide(nameFrame)
    SafeHide(barIconFrame)
    HideMultiIconFrames(barNumber)
    return
  end

  -- Update tick marks - only needed when config changes
  if needsSetup then
    UpdateTickMarks(barFrame, barConfig, maxStacks, displayMode)
  end

  -- ═══════════════════════════════════════════════════════════════════
  -- 12.1 ENGINE LANE (custom stack bar): the invisible AuraButton drives the
  -- continuous fill via the ApplicationBar binding (min/max 0..maxStacks,
  -- value = the secret application count, C-side) plus the stack count and
  -- countdown overlays. Native fills above stay at 0 underneath. Requires
  -- Max Stacks > 0 (the engine binding REQUIRES maxApplications).
  -- ═══════════════════════════════════════════════════════════════════
  if isCustomAura and not showPreview and ns.BarDuration and ns.BarDuration.Attach
     and maxStacks and maxStacks > 0 then
    -- keep barFrame.bar styled to this bar's config: it is the style SOURCE
    -- the engine fill copies from (WireSub/ApplyStyle), even though the
    -- native fill itself stays empty under the overlay
    barFrame.bar:SetStatusBarTexture(texturePath)
    barFrame.bar:SetOrientation(barOrientation)
    barFrame.bar:SetReverseFill(isBarReverseFill)
    barFrame.bar:SetRotatesTexture(rotateBarTex)
    local bdUnit = (barConfig.tracking.trackType == "debuff") and "target" or "player"
    local bdDurFmt, bdColorKey
    if barConfig.display.durationTextColorEnabled and ns.DurationText and ns.DurationText.GetLiveSecondsColorFormatter then
      -- persistent per-fs formatter (live band-edit application, see DT)
      bdDurFmt = ns.DurationText.GetLiveSecondsColorFormatter(durationFrame and durationFrame.text,
        barConfig.display, barConfig.display.durationDecimals or 1)
      bdColorKey = ns.DurationText.SecondsColorKey and ns.DurationText.SecondsColorKey(barConfig.display)
    end
    local bdDurFontPath = "Fonts\\FRIZQT__.TTF"
    if LSM and barConfig.display.durationFont then
      local ff = LSM:Fetch("font", barConfig.display.durationFont)
      if ff and ff ~= "" then bdDurFontPath = ff end
    end
    -- THRESHOLD BAND COLORING (zero reads): one saturating-max overlay per
    -- enabled threshold. Overlay for boundary T (maxApplications = T, width =
    -- T/maxStacks of the bar) tracks the base fill edge exactly and stops
    -- growing at T, so it paints the fill region below T in the band-below
    -- color; the base slot renders the TOP band's color. bandsKey rewires the
    -- slots when any band value/color (or the base color) changes.
    local engineBaseColor = baseColor
    local applicationBands, applicationSteps, bandsKey
    -- USE TEXTURE COLORS: the engine overlay carries a COPY of our texture, so
    -- it needs the same white (identity) tint -- and threshold recoloring is
    -- skipped outright, since recoloring the fill is exactly what the toggle
    -- turns off (the panel disables those controls to match).
    local naturalFill = ns.API.IsNaturalFill(barConfig.display)
    if naturalFill then engineBaseColor = { r = 1, g = 1, b = 1, a = 1 } end
    do
      local list = {}
      for i = 2, 6 do
        local th = thresholds[i]
        if th and th.enabled and th.color and not naturalFill then
          local v = GetThresholdValue(th.minValue, nil, thresholdAsPercent, maxStacks)
          v = v and math_floor(v + 0.5)
          if v and v > 1 and v <= maxStacks then list[#list + 1] = { v = v, color = th.color } end
        end
      end
      table.sort(list, function(x, y) return x.v < y.v end)
      if #list > 0 then
        local parts = {}
        -- The Style dropdown maps Segmented = thresholdMode "perStack" ONLY;
        -- the Continuous family is simple/folded/GRANULAR (the "Thresholds"
        -- checkbox writes "granular"!) -- so steps for everything but perStack.
        if displayMode ~= "perStack" then
          -- CONTINUOUS: whole-fill color switch at each threshold (step
          -- overlays; higher thresholds drawn on top). Key is STRUCTURE ONLY
          -- -- colours are pushed live by BD, so recolouring never recreates.
          applicationSteps = {}
          for i, e in ipairs(list) do
            applicationSteps[#applicationSteps + 1] = { threshold = e.v, color = e.color, boost = i }
            parts[#parts + 1] = "s" .. e.v
          end
        else
          -- SEGMENTED: region band coloring (width-stretch overlays; smaller
          -- thresholds drawn on top; base slot renders the top band's color)
          applicationBands = {}
          local below = baseColor
          for i, e in ipairs(list) do
            applicationBands[#applicationBands + 1] = {
              max = e.v, widthFrac = e.v / maxStacks,
              color = below, boost = #list - i + 1,
            }
            parts[#parts + 1] = "b" .. e.v
            below = e.color
          end
          engineBaseColor = below
        end
        bandsKey = table.concat(parts, "|")
      end
    end
    ns.BarDuration.Attach(barFrame, durationFrame and durationFrame.text,
      nil, barConfig.tracking.trackedSpellID, bdUnit, {
      applicationMax = maxStacks,
      applicationBands = applicationBands,
      applicationSteps = applicationSteps,
      bandsKey = bandsKey,
      lockColor = applicationBands ~= nil,
      -- unused by the ApplicationBar binding, but stored for ApplyStyle's
      -- direction-change detection -- must mirror its bdDir formula or every
      -- appearance apply would look like a direction change and churn the slot
      direction = (barConfig.display.durationBarFillMode == "fill")
        and Enum.StatusBarTimerDirection.ElapsedTime or Enum.StatusBarTimerDirection.RemainingTime,
      interpolation = barConfig.display.enableSmoothing and Enum.StatusBarInterpolation.ExponentialEaseOut or Enum.StatusBarInterpolation.Immediate,
      showDuration = barConfig.display.showDuration,
      baseColor = engineBaseColor,
      durationColor = barConfig.display.durationColor or {r=1, g=1, b=1, a=1},
      durFontPath = bdDurFontPath,
      durFontSize = barConfig.display.durationFontSize or 18,
      durOutline = GetOutlineFlag(barConfig.display.durationOutline),
      durDecimals = barConfig.display.durationDecimals or 1,
      durFormatter = bdDurFmt,
      textColorEnabled = barConfig.display.durationTextColorEnabled and true or false,
      colorKey = bdColorKey,
      stacksText = (barConfig.display.showText and textFrame and textFrame.text) or nil,
      stackColor = barConfig.display.textColor,
      ownChrome = engineOwnsChrome and BuildOwnChrome(barConfig, barFrame, maxStacks) or nil,
    })
    barFrame._arcBDActive = true
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
  
  -- Visibility already determined at function start - just show/hide based on that.
  -- engineOwnsChrome: the button carries the visible bar; our aux frames stay
  -- hidden so nothing lingers while the aura is down (barFrame itself must
  -- stay SHOWN -- it hosts the aura container).
  if shouldShow and barConfig.display.enabled then
    barFrame:Show()
    if barConfig.display.showText and not engineOwnsChrome then
      textFrame:Show()
    else
      textFrame:Hide()
    end
    if nameFrame then
      if barConfig.display.showName and not engineOwnsChrome then
        nameFrame:Show()
      elseif engineOwnsChrome then
        nameFrame:Hide()
      end
    end
    if barIconFrame then
      if barConfig.display.showBarIcon and not engineOwnsChrome then
        barIconFrame:Show()
      elseif engineOwnsChrome then
        barIconFrame:Hide()
      end
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
  
  -- THE FLOATING-NUMBERS BUG (reported by Dendar 2026-07-18 and Paeddy 2026-08-21:
  -- "random numbers floating on my screen"). Two frames outlive this early-out:
  --   * iconFrame.stacksFrame -- an ArcUIIconStacksFrame parented to UIPARENT, not
  --     to iconFrame, so hiding the icon does NOT hide it (every other hide site
  --     in this file calls stacksFrame:Hide() explicitly for exactly that reason).
  --   * the multi-icon frames, hidden by HideMultiIconFrames at the very end.
  -- Neither was part of the "already hidden" test, so once the six frames below
  -- were hidden this returned BEFORE reaching their cleanup -- and a stray stack
  -- number could then never be cleared, on any later call, until a reload.
  local stacksHidden = not (iconFrame and iconFrame.stacksFrame)
                       or not iconFrame.stacksFrame:IsShown()
  local multiHidden = true
  if multiIconFrames[barNumber] then
    for _, f in pairs(multiIconFrames[barNumber]) do
      if f and f.IsShown and f:IsShown() then multiHidden = false break end
    end
  end

  -- Only skip if ALL frames are hidden
  if iconHidden and barHidden and textHidden and durationHidden and nameHidden
     and barIconHidden and stacksHidden and multiHidden then
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
      if barFrames[barNumber].iconFrame.stacksFrame then
        -- HIDE the frame, not just its text. It is parented to UIParent, so the
        -- iconFrame:Hide() above does nothing to it, and blanking the fontstring
        -- only lasts until something writes a count back into it -- at which
        -- point the number reappears with no bar under it. Every other hide site
        -- in this file already calls Hide() here; this one only cleared text.
        barFrames[barNumber].iconFrame.stacksFrame:Hide()
        if barFrames[barNumber].iconFrame.stacksFrame.text then
          barFrames[barNumber].iconFrame.stacksFrame.text:SetText("")
        end
        barFrames[barNumber].iconFrame.stacksFrame.lastText = ""
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

  -- 12.1 duration-bar diagnostics: record what we see per bar so /arcbardur can show WHERE the
  -- AuraButton driver path breaks (no trackedSpellID / wrong source branch / not active / not secret).
  -- gated on debug: this builds a fresh table on EVERY duration-bar refresh,
  -- which is pure garbage in normal play (the flag persists across reloads, so
  -- a bug report still captures it from login onward)
  if ns.BarDuration and ns.BarDuration.debug and ns.BarDuration.Trace then
    ns.BarDuration.Trace(barNumber, {
      active = active,
      hasAuraInfo = (sourceBar and sourceBar.GetAuraInfo) and true or false,
      hasTotemInfo = (sourceBar and sourceBar.GetTotemInfo) and true or false,
      hasGetValue = (sourceBar and sourceBar.GetValue) and true or false,
      cooldownID = barConfig.tracking and barConfig.tracking.cooldownID,
      trackedSpellID = barConfig.tracking and barConfig.tracking.trackedSpellID,
      showDuration = barConfig.display and barConfig.display.showDuration and true or false,
      secret = (ns.API and ns.API.AurasSecret and ns.API.AurasSecret("player")) and true or false,
    })
  end

  -- CUSTOM AURA BARS (12.1): no CDM source exists and aura presence cannot
  -- be read (secret) — the bar is treated as permanently "active"; the
  -- engine lane below drives the actual fill/countdown, which appear only
  -- while the aura is up (the invisible AuraButton hides with it).
  local isCustomAura = barConfig.tracking.customAura
    and ns.BarDuration and ns.BarDuration.IsAvailable and ns.BarDuration.IsAvailable()
  if isCustomAura then
    active = true
    sourceBar = nil
  end

  -- PREBUILD (load window): a CDM bar has no resolved CDM frame this early, so
  -- Core reports it inactive with no sourceBar and the engine branch never
  -- runs -- yet the engine only needs the SAVED cooldownID/trackedSpellID to
  -- create its slot. Force the branch here so the slot exists before secrecy
  -- locks creation for the rest of the session. (Stack bars never needed this:
  -- their fill takes the secret count straight through SetValue, which is why
  -- they survived a combat reload and duration bars did not.)
  -- ARM THE ENGINE EVEN WHILE THE AURA IS ABSENT (12.1). The slot does not
  -- need the aura to be up -- it WATCHES for it -- but the attach used to sit
  -- behind `active`, so a CDM bar only tried to create its slot the first time
  -- the buff landed. Reload, then first gain the buff IN COMBAT, and that one
  -- attempt is refused (auras are secret, creation blocked) and the fill never
  -- moves again that session. Gaining it once out of combat "fixed" it, which
  -- is exactly the report. Custom bars never hit this: they force active.
  -- NOTE: `active` itself is NOT forced here -- that would break Hide When
  -- Inactive and the dimmed look for CDM bars, which CAN read their state.
  local engineArm = not isCustomAura
    and not IsTotemLikeBar(barConfig)   -- totems drive themselves, see IsTotemLikeBar
    and barConfig.tracking
    and (((barConfig.tracking.cooldownID or 0) > 0) or ((barConfig.tracking.trackedSpellID or 0) > 0))
    and ns.BarDuration and ns.BarDuration.IsAvailable and ns.BarDuration.IsAvailable()

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
  if barFrames[barNumber] then
    local bfSet = barFrames[barNumber]
    if bfSet._arcHideWhenAlpha ~= hideWhenFadeAlpha then
      bfSet._arcHideWhenAlpha = hideWhenFadeAlpha
      -- APPLY ON THE SPOT (Rule 0): the appearance styler is the only other
      -- writer of this alpha and it never runs on combat/condition edges —
      -- a >0 Hidden Opacity painted out of combat stayed painted IN combat
      -- (the Freezing-stacks 15% report; 0% worked because that path hides
      -- instead of fading). Repaint the moment the multiplier changes.
      if bfSet.barFrame then
        bfSet.barFrame:SetAlpha((bfSet._arcBaseOpacity or 1) * hideWhenFadeAlpha)
      end
    end
  end
  
  -- Inactive check (if hideWhenInactive and not active, but show in options for editing)
  if shouldShow and not optionsOpen and not active and barConfig.behavior and barConfig.behavior.hideWhenInactive then
    shouldShow = false
  end

  -- Early exit if bar shouldn't show and options not open.
  -- NOT during the prebuild: this return sits BEFORE the engine attach, and
  -- with Hide When Inactive on (aura down at login) it swallowed the bar's
  -- only chance to create its slot -- the exact "fill never moves if the buff
  -- first lands in combat" bug. The prebuild hides all frames afterwards.
  if not shouldShow and not optionsOpen and not prebuildPass then
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
  -- USE TEXTURE COLORS: white is the identity tint, so every downstream write
  -- (our own fill AND the engine overlay's copy of the texture) leaves the
  -- art untouched. One substitution here covers the whole function.
  if ns.API.IsNaturalFill(barConfig.display) then
    baseColor = { r = 1, g = 1, b = 1, a = baseColor.a or 1 }
  end
  
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
  
  -- Use cached optionsOpen from function start. Custom aura bars force
  -- active=true (presence is unreadable), which would suppress the preview
  -- forever -- treat them as previewable whenever the panel is open.
  local showPreview = optionsOpen and (not active or previewMode or isCustomAura)

  -- HIDE WHEN INACTIVE (ownership model): chrome moves onto the engine
  -- button (shows/hides with the aura natively); native chrome suppressed
  -- outside the options panel. See UpdateBar's twin block.
  local engineOwnsChrome = isCustomAura and barConfig.behavior
    and barConfig.behavior.hideWhenInactive and not optionsOpen
  if isCustomAura and barConfig.behavior and barConfig.behavior.hideWhenInactive then
    if barFrame.bg then
      barFrame.bg:SetShown((not engineOwnsChrome) and (barConfig.display.showBackground and true or false))
    end
    if barFrame.tickOverlay then barFrame.tickOverlay:SetShown(not engineOwnsChrome) end
    if ns.BarDuration and ns.BarDuration.SetOwnChrome then
      ns.BarDuration.SetOwnChrome(barFrame, engineOwnsChrome and BuildOwnChrome(barConfig, barFrame, maxValue, true, nameFrame) or nil)
    end
  end
  
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
    
    -- Apply expensive bar setup. Inset the fill from each edge by the per-side
    -- padding (in physical px) so custom fill textures don't need baked-in
    -- transparent margins. Background stays full-size; zero padding = current look.
    barFrame.bar:ClearAllPoints()
    local padL = barConfig.display.barPaddingL or 0
    local padR = barConfig.display.barPaddingR or 0
    local padT = barConfig.display.barPaddingT or 0
    local padB = barConfig.display.barPaddingB or 0
    if padL == 0 and padR == 0 and padT == 0 and padB == 0 then
      barFrame.bar:SetAllPoints(barFrame)
    else
      local _s = barFrame:GetEffectiveScale()
      local _, _h = GetPhysicalScreenSize()
      local _onePx = (_h and _h > 0 and _s and _s > 0) and (768 / _h) / _s or 1
      barFrame.bar:SetPoint("TOPLEFT", barFrame, "TOPLEFT", _onePx * padL, -_onePx * padT)
      barFrame.bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -_onePx * padR, _onePx * padB)
    end
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
    -- release the engine-lane claim so the preview duration/stack text render
    -- (the engine attachment itself stays; it re-flags on the next live pass)
    barFrame._arcBDActive = nil

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
    -- Auto max animates C-side via SetTimerDuration with no polling at all; a
    -- custom max or threshold bands add one shared 20fps handler (see below).
    -- Countdown text is a DurationTextBinding, also C-side.
    if barFrame.bar.SetSmoothing then
      barFrame.bar:SetSmoothing(false)
    end

    -- Clear any legacy polling state
    barFrame.bar.totemPollingData = nil
    barFrame.bar.totemTickData = nil
    barFrame.bar:SetScript("OnUpdate", nil)

    -- set when threshold bands are driving the fill colour, so the gradient
    -- (which cannot take secret colours) stays off, same rule as aura bars
    local totemCurveActive = false

    local durObj = sourceBar:GetDurationObject()

    if durObj then
      local barTextureTotem = barFrame.bar:GetStatusBarTexture()
      if barTextureTotem then barTextureTotem:SetVertexColor(1, 1, 1, 1) end

      local fillMode = barConfig.display.durationBarFillMode or "drain"
      local timerDirection = (fillMode == "fill")
        and Enum.StatusBarTimerDirection.ElapsedTime
        or  Enum.StatusBarTimerDirection.RemainingTime

      -- MAX DURATION. Auto = SetTimerDuration, which normalises the totem's own
      -- full span C-side for free. Manual = map remaining SECONDS through our own
      -- plain curve: EvaluateRemainingDuration is SecretWhenCurveSecret and the
      -- curve is ours, so the result is a NON-secret 0..1 that SetValue can take,
      -- and the curve's shape carries fill-vs-drain. No arithmetic on a duration
      -- anywhere, which is why this is legal where the aura lane's max was not.
      local autoMax = barConfig.tracking.dynamicMaxDuration
      if autoMax == nil then autoMax = true end
      local maxCurve = (not autoMax) and GetTotemMaxCurve(maxValue, fillMode) or nil

      barFrame.bar:SetMinMaxValues(0, 1)
      if maxCurve then
        barFrame.bar:SetValue(durObj:EvaluateRemainingDuration(maxCurve), durationInterp)
      else
        -- StatusBarInterpolation has exactly two members, Immediate and
        -- ExponentialEaseOut. "Linear" never existed, so this was passing nil for
        -- a non-nilable argument and silently falling back to Immediate.
        barFrame.bar:SetTimerDuration(durObj,
          GetBarInterpolation(barConfig.display.enableSmoothing) or Enum.StatusBarInterpolation.Immediate,
          timerDirection)
      end

      -- Duration text: poll GetRemainingDuration() on the fresh durObj each frame.
      -- GetTotemDuration returns nil (not a zero-span object) when slot gone,
      -- so `if durObj then` correctly gates the text update.
      local showDuration = barConfig.display.showDuration
      local decimals = barConfig.display.durationDecimals or 1
      local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}

      if durationFrame and showDuration then
        durationFrame.text:SetTextColor(dc.r, dc.g, dc.b, dc.a)
        durationFrame:Show()

        if ns.DurationText and ns.DurationText.IsSupported() then
          -- 12.0.7: Blizzard drives the countdown text C-side — no Lua OnUpdate.
          durationFrame.isActive = false
          durationFrame.sourceBar = nil
          durationFrame:SetScript("OnUpdate", nil)
          -- pass the display config like the aura branch does, so totem bars get
          -- the same duration-text threshold colouring instead of silently
          -- ignoring those options
          ns.DurationText.Bind(durationFrame.text, durObj, decimals, nil, nil, barConfig.display)
        else
          -- Fallback (pre-12.0.7): poll GetRemainingDuration on the totem durObj.
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
        end
      elseif durationFrame then
        -- showDuration off: release the binding and hide, otherwise a frame shown
        -- by an earlier config lingers with a frozen countdown
        if ns.DurationText then ns.DurationText.Unbind(durationFrame.text) end
        durationFrame.isActive = false
        durationFrame.sourceBar = nil
        durationFrame:SetScript("OnUpdate", nil)
        durationFrame:Hide()
      end

      -- FILL COLOUR THRESHOLD BANDS. A totem durObj is an ordinary duration
      -- object, so EvaluateRemainingPercent drives the curve exactly like an aura
      -- bar, and SetStatusBarColor is a secret-safe sink for the result. Re-read
      -- the durObj each tick rather than closing over this one: GetTotemDuration
      -- returns nil the moment the slot empties, which is our stop signal.
      if useColorCurve then
        totemCurveActive = true
        local initialColor = durObj:EvaluateRemainingPercent(colorCurve)
        if initialColor then
          barFrame.bar:SetStatusBarColor(initialColor:GetRGBA())
        else
          barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
        end
      else
        barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      end

      -- ONE handler for both jobs -- a frame has a single OnUpdate script. Manual
      -- max has to repush the value (SetValue does not animate itself the way
      -- SetTimerDuration does); threshold bands have to re-evaluate the colour.
      -- Both re-fetch the durObj, which doubles as the stop signal: GetTotemDuration
      -- returns nil the instant the slot empties. Nothing is installed when neither
      -- job is on, so the default Auto + flat colour bar stays at zero idle cost.
      if maxCurve or useColorCurve then
        barFrame.bar.totemTickData = {
          sourceBar  = sourceBar,
          maxCurve   = maxCurve,
          colorCurve = useColorCurve and colorCurve or nil,
          baseColor  = baseColor,
          interp     = durationInterp,
          elapsed    = 0,
        }

        if not barFrame.bar.totemTickOnUpdate then
          barFrame.bar.totemTickOnUpdate = function(self, elapsed)
            local data = self.totemTickData
            if not data then self:SetScript("OnUpdate", nil); return end

            -- throttle gate FIRST, so GetTotemDuration runs at 20fps not 200
            data.elapsed = data.elapsed + elapsed
            if data.elapsed < 0.05 then return end
            data.elapsed = 0

            local cur = data.sourceBar:GetDurationObject()
            if not cur then
              self:SetScript("OnUpdate", nil)
              self.totemTickData = nil
              if data.colorCurve then
                self:SetStatusBarColor(data.baseColor.r, data.baseColor.g, data.baseColor.b, data.baseColor.a or 1)
              end
              return
            end

            if data.maxCurve then
              self:SetValue(cur:EvaluateRemainingDuration(data.maxCurve), data.interp)
            end

            if data.colorCurve then
              local c = cur:EvaluateRemainingPercent(data.colorCurve)
              if c then
                self:SetStatusBarColor(c:GetRGBA())
              else
                self:SetStatusBarColor(data.baseColor.r, data.baseColor.g, data.baseColor.b, data.baseColor.a or 1)
              end
            end
          end
        end
        barFrame.bar:SetScript("OnUpdate", barFrame.bar.totemTickOnUpdate)
      end
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
        if ns.DurationText then ns.DurationText.Unbind(durationFrame.text) end
        durationFrame:Hide()
      end
      barFrame.bar:SetAlpha(1)
    end

    if not totemCurveActive then
      ApplyBarGradient(barFrame.bar, barConfig, baseColor)
    end
    barFrame.bar:Show()

  elseif (active and ((sourceBar and sourceBar.GetAuraInfo) or isCustomAura)) or engineArm then
    -- AURA DURATION BAR (CDM-sourced, or a CUSTOM spell-ID bar with no
    -- sourceBar — the engine lane below handles the custom case; engineArm
    -- runs it while the aura is ABSENT so the slot exists before secrecy
    -- blocks creation)
    -- MODE-SWITCH hygiene: a bar flipped from STACK mode leaves its
    -- text-only countdown host behind — two ArcTimers would overlay the
    -- same fontstring. Release the host; this lane owns the countdown now.
    if barFrame._arcStackDurHost then
      if ns.BarDuration and ns.BarDuration.Detach then
        ns.BarDuration.Detach(barFrame._arcStackDurHost)
      end
      barFrame._arcStackDurHost:Hide()
    end
    local auraID, unit
    if sourceBar and sourceBar.GetAuraInfo then
      auraID, unit = sourceBar:GetAuraInfo()
    end
    
    -- Disable legacy SetSmoothing - we use interpolation enum on SetValue instead
    -- AUTO mode: SetTimerDuration has its own interpolation param (inherently smooth)
    -- MANUAL MAX mode: SetValue gets durationInterp from enableSmoothing toggle
    if barFrame.bar.SetSmoothing then
      barFrame.bar:SetSmoothing(false)
    end
    
    -- 12.1 (auras secret): the durObj/colorCurve/polling machinery in the normal branch below is
    -- BOTH secret-unsafe (`existingData.auraID == auraID` compares two secret auraInstanceIDs;
    -- RegisterAuraPolling is fed the secret id) AND non-functional (SafeGetAuraDuration returns nil
    -- -> no durObj to drain). Two 12.1 outcomes: if the bar's tracked spell ID is known, an
    -- invisible AuraButton (ns.BarDuration) drives THIS bar's fill + countdown secret-safely; else
    -- the bar stays inert (the "no valid aura" else-branch). AurasSecret is false on live/pre-12.1,
    -- so neither 12.1 path can run there -- the normal branch is unchanged.
    -- Route the engine by the user's buff/debuff PICKER (trackType), NOT the frame's auraDataUnit,
    -- which lies for selfAura debuffs like Flame Shock (it reports "player" though the debuff is on
    -- the target). A debuff tracks the target/HARMFUL; a buff the player/HELPFUL.
    -- PET-BUFF lane (trackType "petbuff", 12.1-only picker choice): buffs the
    -- PET carries (Dark Transformation). Lab-proven: pet slots populate, and
    -- the pet's visible copy uses the entry's BASE spell ID (1233448 for DT) —
    -- already in the candidate set — while the player-side copy CDM reads is a
    -- hidden nameplate-only mirror containers can never match.
    local bdUnit = "player"
    if barConfig.tracking then
      if barConfig.tracking.trackType == "debuff" then
        bdUnit = "target"
      elseif barConfig.tracking.trackType == "petbuff" then
        bdUnit = "pet"
      end
    end
    local aurasSecret121 = ns.API and ns.API.AurasSecret and ns.API.AurasSecret(bdUnit)
    local bdCooldownID   = barConfig.tracking and barConfig.tracking.cooldownID
    -- Fall back to the bar's own saved spell ID. A CDM bar usually has no
    -- trackedSpellID and lets ResolveCandidateSpellIDs read the candidates off
    -- C_CooldownViewer -- but that data is NOT loaded during the load window,
    -- so the set came back EMPTY, Attach bailed before creating anything, and
    -- the slot could never be made once combat locked creation: the bar showed
    -- (Core knew the aura was active) with a fill nothing was driving. The
    -- saved ID is the same one the CDM info reports, so this only ever adds a
    -- candidate the engine would have had anyway.
    local bdTrackedSpell = barConfig.tracking
      and (barConfig.tracking.trackedSpellID or barConfig.tracking.spellID)
    -- CDM IS ONLY THE LOOKUP. The moment it tells us which aura this bar is,
    -- SAVE that spell ID: from then on the bar sets itself up exactly like one
    -- added by spell ID, arming at login from its own config with no CDM
    -- dependency at all. (Waiting on CDM every session is what left these bars
    -- unable to create their slot before secrecy locked creation.) idKey still
    -- prefers the cooldownID, and the ID was already in the candidate set, so
    -- storing it never triggers a rewire.
    if bdCooldownID and bdCooldownID > 0
       and not (bdTrackedSpell and bdTrackedSpell > 0)
       and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
      local cdInfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(bdCooldownID)
      local sid = cdInfo and cdInfo.spellID
      if sid and sid > 0 then
        barConfig.tracking.trackedSpellID = sid
        bdTrackedSpell = sid
      end
    end
    -- CUSTOM bars always ride the engine lane on 12.1 (it works whether or
    -- not auras are currently secret; there is no live-data fallback for
    -- auras with no CDM entry)
    if (aurasSecret121 or isCustomAura) and ns.BarDuration and ns.BarDuration.IsAvailable()
       and ((bdCooldownID and bdCooldownID > 0) or (bdTrackedSpell and bdTrackedSpell > 0)) then
      if barConfig.tracking.cdmMirror and bdCooldownID and bdCooldownID > 0
         and ns.BarDuration.AttachMirror then
      -- CDM TIMER MIRROR: hidden/internal auras (e.g. Crusading Strikes'
      -- swing aura) never match AuraContainer filters, so the engine lane
      -- below can't drive them. The mirror re-pushes the CDM bar item's OWN
      -- SetValue/SetMinMaxValues/SetText (secret-accepting sinks) into OUR
      -- bar + countdown text. Our bar IS the fill here (no engine overlay).
      ns.BarDuration.Detach(barFrame)
      barFrame.bar:SetScript("OnUpdate", nil)
      barFrame.bar.colorCurveData = nil
      UnregisterAuraPolling(barNumber)
      ns.BarDuration.AttachMirror(barFrame,
        (barConfig.display.showDuration and durationFrame and durationFrame.text) or nil,
        bdCooldownID,
        GetBarInterpolation(barConfig.display.enableSmoothing))
      local bdTex = barFrame.bar:GetStatusBarTexture()
      if bdTex then bdTex:SetVertexColor(1, 1, 1, 1) end
      barFrame.bar:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      barFrame.bar:SetValue(0)
      barFrame.bar:SetAlpha(1)
      barFrame.bar:Show()
      barFrame._arcBDActive = true
      -- FILL MODE: the option was inert here before (it only ever picked a
      -- StatusBarTimerDirection for SetTimerDuration, which this lane never
      -- calls). Fill is now the painted-gap layer; drain is unchanged.
      local mirrorFill = (barConfig.display.durationBarFillMode == "fill")
      -- "Keep Texture Still": the drain masks the NOT-YET-ELAPSED part, which
      -- sits at the same end as the stretched path's gap -- so static mode
      -- needs the SAME reverse-fill flip. Worked through explicitly because a
      -- first version skipped the flip and filled the wrong way: with
      -- ReverseFill unflipped the bg-painted drain covers [left, v] and the
      -- visible art grows from the RIGHT, i.e. an inverted fill. Flipped, the
      -- drain covers [v, right] and the art grows left-to-right exactly like
      -- the normal fill (mirror-image for user-reversed bars).
      local mirrorStatic = mirrorFill and (barConfig.display.mirrorStaticTexture == true)
      local mirrorDrainReverse = isDurationReverseFill
      if mirrorFill then mirrorDrainReverse = not isDurationReverseFill end
      barFrame.bar:SetReverseFill(mirrorDrainReverse)
      ApplyMirrorFillLayer(barFrame, barConfig, baseColor,
        isDurationVertical, mirrorDrainReverse, mirrorFill, mirrorStatic)
      if durationFrame then
        if barConfig.display.showDuration then
          -- reclaim the fontstring from other lanes: the engine lane HIDES it
          -- (ArcTimer overlays it) and the live lane may have a DurationText
          -- binding / OnUpdate driver on it -- the mirror owns it now
          if ns.DurationText and ns.DurationText.Unbind then ns.DurationText.Unbind(durationFrame.text) end
          durationFrame:SetScript("OnUpdate", nil)
          durationFrame.isActive = false
          durationFrame.sourceBar = nil
          local mdc = barConfig.display.durationColor or { r = 1, g = 1, b = 1, a = 1 }
          durationFrame.text:SetTextColor(mdc.r, mdc.g, mdc.b, mdc.a or 1)
          durationFrame.text:SetText("")   -- mirror SetTexts the live countdown into it
          durationFrame.text:Show()
          durationFrame:Show()
        else
          durationFrame:Hide()
        end
      end
      else
      -- mirror turned off (or switched to drain) while its fill layer existed:
      -- release the layer and un-hide the real fill texture
      if barFrame._mirrorFillTex then
        ApplyMirrorFillLayer(barFrame, barConfig, baseColor, isDurationVertical, false, false)
      end
      -- 12.1 AuraButton-driven duration bar: the invisible button drives the FILL (and the
      -- countdown text via SetDurationText); we own only color + visibility here. No OnUpdate,
      -- no polling, no durObj, no secret compare.
      local fillMode = barConfig.display.durationBarFillMode or "drain"
      local bdDirection = (fillMode == "fill")
        and Enum.StatusBarTimerDirection.ElapsedTime
        or Enum.StatusBarTimerDirection.RemainingTime
      barFrame.bar:SetScript("OnUpdate", nil)
      barFrame.bar.colorCurveData = nil
      UnregisterAuraPolling(barNumber)
      local ddc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}
      -- Resolve the duration-text style the SAME way ApplyAppearance styles durationFrame.text,
      -- so the engine countdown matches the user's Font/Size/Outline/Decimals exactly.
      local bdDurOutline = GetOutlineFlag(barConfig.display.durationOutline)
      local bdDurFontPath = "Fonts\\FRIZQT__.TTF"
      if LSM and barConfig.display.durationFont then
        local ff = LSM:Fetch("font", barConfig.display.durationFont)
        if ff and ff ~= "" then bdDurFontPath = ff end
      end
      -- Colour-by-time text: reuse the LIVE approach -- seconds bands baked into the formatter,
      -- applied C-side with no durObj read -- so it survives 12.1. nil when the toggle/bands are off.
      -- Persistent per-fs formatter: band edits rewrite its rules in place (see DT).
      local bdDurFmt, bdColorKey
      if barConfig.display.durationTextColorEnabled and ns.DurationText and ns.DurationText.GetLiveSecondsColorFormatter then
        bdDurFmt = ns.DurationText.GetLiveSecondsColorFormatter(durationFrame and durationFrame.text,
          barConfig.display, barConfig.display.durationDecimals or 1)
        bdColorKey = ns.DurationText.SecondsColorKey and ns.DurationText.SecondsColorKey(barConfig.display)
      end
      -- CONDITIONAL COLOUR BY REMAINING TIME (12.1 engine lane). The fill
      -- value is secret, so colour comes from stacked engine layers instead
      -- of a curve: per threshold fraction f, a TRACK layer (follows the
      -- fill, masked to its side of f) and a STEP layer (gated at f). See
      -- the engine-bar-threshold-coloring skill.
      --   DRAIN (value = remaining): base c0, then TRACK(low, f_i, c_i) for
      --     i = n..1, then STEP(low, f_i, colour ABOVE f_i) for i = 1..n.
      --   FILL (value = elapsed, f_i mirrored to 1-f_i): pairs from the
      --     least urgent up -- TRACK(high, q_i, c_i) then STEP(low, q_i, c_i).
      local bdDurSteps, bdDurKey
      -- natural fill owns the color: no threshold recolor overlays
      if barConfig.display.durationColorCurveEnabled and not ns.API.IsNaturalFill(barConfig.display) then
        local d, list = barConfig.display, {}
        local asSeconds = d.durationThresholdAsSeconds
        local thrMax = d.durationThresholdMaxDuration or 30
        for i = 2, 5 do
          if d["durationThreshold" .. i .. "Enabled"] then
            local v = tonumber(d["durationThreshold" .. i .. "Value"])
            local col = d["durationThreshold" .. i .. "Color"]
            local f = v and (asSeconds and (thrMax > 0 and v / thrMax or nil) or v / 100)
            if f and col and f > 0.001 and f < 0.999 then
              list[#list + 1] = { f = f, color = col }
            end
          end
        end
        table.sort(list, function(a, b) return a.f < b.f end)
        if #list > 0 then
          bdDurSteps = {}
          local parts, n = {}, #list
          local function add(side, frac, color, step)
            bdDurSteps[#bdDurSteps + 1] = {
              side = side, frac = frac, color = color, step = step,
              boost = #bdDurSteps + 1,
            }
          end
          if fillMode == "fill" then
            for i = n, 1, -1 do
              local e = list[i]
              add("high", 1 - e.f, e.color, false)
              add("low",  1 - e.f, e.color, true)
            end
          else
            for i = n, 1, -1 do add("low", list[i].f, list[i].color, false) end
            for i = 1, n do
              add("low", list[i].f, (i < n) and list[i + 1].color or baseColor, true)
            end
          end
          -- STRUCTURE ONLY (no colours): colours are pushed live by BD's
          -- retarget path, so recolouring never recreates slots
          for _, e in ipairs(list) do
            parts[#parts + 1] = string.format("d%.4f", e.f)
          end
          parts[#parts + 1] = fillMode
          bdDurKey = table.concat(parts, "|")
        end
      end
      ns.BarDuration.Attach(barFrame, durationFrame and durationFrame.text, bdCooldownID, bdTrackedSpell, bdUnit, {
        direction = bdDirection,
        interpolation = barConfig.display.enableSmoothing and Enum.StatusBarInterpolation.ExponentialEaseOut or Enum.StatusBarInterpolation.Immediate,
        showDuration = barConfig.display.showDuration,
        durationSteps = bdDurSteps,
        bandsKey = bdDurKey,
        baseColor = baseColor,
        durationColor = ddc,
        durFontPath = bdDurFontPath,
        durFontSize = barConfig.display.durationFontSize or 18,
        durOutline = bdDurOutline,
        durDecimals = barConfig.display.durationDecimals or 1,
        durFormatter = bdDurFmt,
        textColorEnabled = barConfig.display.durationTextColorEnabled and true or false,
        colorKey = bdColorKey,
        stacksText = (barConfig.display.showText and textFrame and textFrame.text) or nil,
        stackColor = barConfig.display.textColor,
        ownChrome = engineOwnsChrome and BuildOwnChrome(barConfig, barFrame, maxValue, true) or nil,
      })
      -- Our own fill sits empty UNDER the engine's ArcBar overlay (which shows the real drain);
      -- the bar frame's border/background/ticks still render normally around it.
      local bdTex = barFrame.bar:GetStatusBarTexture()
      if bdTex then bdTex:SetVertexColor(1, 1, 1, 1) end
      barFrame.bar:SetMinMaxValues(0, maxValue)
      barFrame.bar:SetValue(0)
      -- armed-but-inactive keeps the dimmed look the inactive branch would
      -- have painted; the engine overlay stays empty until the aura lands
      local bc = baseColor
      if not active then
        bc = { r = baseColor.r * 0.5, g = baseColor.g * 0.5, b = baseColor.b * 0.5, a = baseColor.a or 0.8 }
      end
      barFrame.bar:SetStatusBarColor(bc.r, bc.g, bc.b, bc.a or 1)
      barFrame.bar:SetAlpha(1)
      barFrame.bar:Show()
      barFrame._arcBDActive = true
      -- Duration text: when shown, the engine ArcTimer overlays it (our fs is hidden in
      -- initializeFrame); when NOT shown, hide the whole durationFrame so no stale value lingers
      -- (this branch skips ArcUI's own duration-text section).
      if durationFrame then
        if barConfig.display.showDuration then
          durationFrame.text:SetText("")   -- clear any stale value; the engine ArcTimer overlays the live countdown
          durationFrame:Show()
        else
          durationFrame:Hide()
        end
      end
      end -- cdmMirror / engine-lane split
    elseif auraID and unit and not aurasSecret121 then
      barFrame._arcBDActive = nil
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
        local durObj = SafeGetAuraData(unit, auraID)
          and SafeGetAuraDuration(unit, auraID)
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
            local durObj = SafeGetAuraData(unit, auraID)
              and SafeGetAuraDuration(unit, auraID)
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
              local durObj = SafeGetAuraDuration(data.unit, data.auraID)
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
          local durObj = SafeGetAuraDuration(data.unit, data.auraID)
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
        local durObj = SafeGetAuraDuration(unit, auraID)
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
      barFrame._arcBDActive = nil
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
    barFrame._arcBDActive = nil
    barFrame.bar.colorCurveData = nil
    barFrame.bar:SetScript("OnUpdate", nil)
    UnregisterAuraPolling(barNumber)
    
    -- Reset VertexColor for non-ColorCurve path
    local barTexture = barFrame.bar:GetStatusBarTexture()
    if barTexture then barTexture:SetVertexColor(1, 1, 1, 1) end
    
    -- 12.1: a manual max cannot be honoured (no max parameter exists anywhere in
    -- the aura timer API) and taking it here was the visible bug -- the source
    -- bar's value is on the SOURCE bar's scale, so pairing it with the user's max
    -- made every bar read full. Always inherit the source's own min/max on 12.1;
    -- the option is locked to Auto to match (see TrackingOptions dynamicMax).
    local useDynamicMax = (barConfig.tracking.dynamicMaxDuration
        or ((ns.API and ns.API.IS_121) and not IsTotemLikeBar(barConfig)))
      and sourceBar.GetMinMaxValues

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
    barFrame._arcBDActive = nil   -- preview has no engine overlay -> let the duration-text section run
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
    barFrame._arcBDActive = nil
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
    elseif barFrame._arcBDActive then
      -- 12.1 engine lane: the AuraButton's ApplicationCount binding overlays the
      -- live stack count (ArcStacks) -- blank ours so no stale/placeholder value
      -- (customs pass stacks=0) shows underneath.
      textFrame.text:SetText("")
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
  
  -- Duration text - DurationTextBinding drives it C-side when supported.
  -- 12.1 BarDuration: when the invisible AuraButton is driving this bar's countdown
  -- (SetDurationText), skip ArcUI's own durObj text logic so the two don't fight over
  -- the same fontstring -- the BarDuration branch already showed + colored durationFrame.
  if barConfig.display.showDuration and durationFrame and not barFrame._arcBDActive then
    local decimals = barConfig.display.durationDecimals or 1
    local dc = barConfig.display.durationColor or {r=1, g=1, b=1, a=1}

    -- Store decimals on frame for OnUpdate access
    durationFrame.storedDecimals = decimals

    -- v3.7.2: a DurationTextBinding may be driving this fontstring (Blizzard
    -- writes its text C-side) for a live totem OR aura countdown. Every other
    -- branch below sets the text manually (preview, fallback, inactive) — so
    -- release the binding unless this update IS a live durObj countdown, or it
    -- overwrites them (e.g. blanking the options preview value).
    local bindingPath = active and sourceBar and (sourceBar.GetTotemInfo or sourceBar.GetAuraInfo)
    if not bindingPath and ns.DurationText then
      ns.DurationText.Unbind(durationFrame.text)
    end

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
      local auraID, unit = sourceBar:GetAuraInfo()
      if auraID and unit then
        local durObj = SafeGetAuraDuration(unit, auraID)
        if ns.DurationText and ns.DurationText.IsSupported() then
          -- 12.0.7: Blizzard drives the countdown text C-side — no Lua OnUpdate.
          -- Re-binds with a fresh durObj whenever this runs (aura refresh/extend).
          durationFrame:SetScript("OnUpdate", nil)
          durationFrame.isActive = false
          durationFrame.sourceBar = nil
          if durObj then
            ns.DurationText.Bind(durationFrame.text, durObj, decimals, unit, auraID, barConfig.display)
          else
            ns.DurationText.Unbind(durationFrame.text)
          end
        else
          -- Fallback (pre-12.0.7): poll GetRemainingDuration() each tick.
          -- Get fresh auraID from sourceBar each frame to detect refreshes.
          durationFrame.sourceBar = sourceBar
          durationFrame.isActive = true

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

              local d = SafeGetAuraDuration(currentUnit, currentAuraID)
              if d then
                self.text:SetFormattedText(DURATION_FMT[self.storedDecimals] or "%.1f", d:GetRemainingDuration())
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

          if durObj then
            durationFrame.text:SetFormattedText(DURATION_FMT[decimals] or "%.1f", durObj:GetRemainingDuration())
          end
        end
      else
        -- No aura info: manual fallback value; release any binding first.
        if ns.DurationText then ns.DurationText.Unbind(durationFrame.text) end
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
  
  -- Visibility already determined at function start - just show/hide based on that.
  -- engineOwnsChrome: the button carries the visible bar; our aux frames stay
  -- hidden (barFrame itself stays SHOWN -- it hosts the aura container).
  if shouldShow and barConfig.display.enabled then
    barFrame:Show()
    barFrame:SetAlpha(1)  -- Always full opacity for duration bars
    if barConfig.display.showText and not engineOwnsChrome then
      textFrame:Show()
    else
      textFrame:Hide()
    end
    -- Note: durationFrame visibility is already handled earlier in the function
    -- based on whether the cooldown is active and durationShowWhenReady setting
    if nameFrame then
      if barConfig.display.showName and not engineOwnsChrome then
        nameFrame:Show()
      elseif engineOwnsChrome then
        nameFrame:Hide()
      end
    end
    if barIconFrame then
      if barConfig.display.showBarIcon and not engineOwnsChrome then
        barIconFrame:Show()
      elseif engineOwnsChrome then
        barIconFrame:Hide()
      end
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
  -- "Match Icon Edges" (cfg.matchIconEdges): same option Resources/CooldownBars already
  -- honor. Anchors flush to the GROUP'S ACTUAL ICON BOUNDING BOX (via the shared
  -- BarGroupAlign insets) instead of the centered/container-edge fallback below.
  -- Gated behind matchSlots + the toggle so default behavior (toggle off) is
  -- byte-for-byte unchanged for every existing bar.
  local iconEdges = matchSlots and cfg.matchIconEdges and ns.BarGroupAlign
  if anchorPoint == "TOP" then
    if iconEdges then
      local insetX = ns.BarGroupAlign.GetIconInsetX(grp)
      local insetY = ns.BarGroupAlign.GetIconInsetY(grp)
      barFrame:SetPoint("BOTTOMLEFT", container, "TOPLEFT", insetX + offsetX, -insetY + offsetY)
    elseif matchSlots then
      local halfWidth = PixelSnap(barWidth / 2, effScale)
      barFrame:SetPoint("BOTTOMLEFT", container, "TOP", -halfWidth + offsetX, offsetY)
    else
      barFrame:SetPoint("BOTTOMLEFT", container, "TOPLEFT", offsetX, offsetY)
    end
  elseif anchorPoint == "BOTTOM" then
    if iconEdges then
      local insetX = ns.BarGroupAlign.GetIconInsetX(grp)
      local insetBottom = ns.BarGroupAlign.GetIconInsetBottom(grp)
      barFrame:SetPoint("TOPLEFT", container, "BOTTOMLEFT", insetX + offsetX, insetBottom + offsetY)
    elseif matchSlots then
      local halfWidth = PixelSnap(barWidth / 2, effScale)
      barFrame:SetPoint("TOPLEFT", container, "BOTTOM", -halfWidth + offsetX, offsetY)
    else
      barFrame:SetPoint("TOPLEFT", container, "BOTTOMLEFT", offsetX, offsetY)
    end
  elseif anchorPoint == "LEFT" then
    if iconEdges then
      local insetY = ns.BarGroupAlign.GetIconInsetY(grp)
      barFrame:SetPoint("TOPRIGHT", container, "TOPLEFT", offsetX, -(insetY + offsetY))
    else
      barFrame:SetPoint("RIGHT", container, "LEFT", offsetX, offsetY)
    end
  elseif anchorPoint == "RIGHT" then
    if iconEdges then
      local insetY = ns.BarGroupAlign.GetIconInsetY(grp)
      barFrame:SetPoint("TOPLEFT", container, "TOPRIGHT", offsetX, -(insetY + offsetY))
    else
      barFrame:SetPoint("LEFT", container, "RIGHT", offsetX, offsetY)
    end
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
  if not initializationComplete and not IsOptionsOpen() and not prebuildPass then
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
  -- Remember the base opacity: the hide-condition evaluators repaint alpha
  -- on the spot when the fade multiplier changes (combat edges fire no aura
  -- event, so waiting for this styler left a >0 Hidden Opacity stuck).
  if barFrames[barNumber] then barFrames[barNumber]._arcBaseOpacity = cfg.opacity end
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
    local nSeg = #barFrame.stackedBars
    for i, bar in ipairs(barFrame.stackedBars) do
      bar:SetFrameStrata(barStrata)
      bar:SetFrameLevel(SegmentLevel(barLevel, i, nSeg))
    end
  end
  -- Apply strata/level to granular bars (perThreshold mode)
  if barFrame.granularBars then
    local nSeg = #barFrame.granularBars
    for i, bar in ipairs(barFrame.granularBars) do
      bar:SetFrameStrata(barStrata)
      bar:SetFrameLevel(SegmentLevel(barLevel, i, nSeg))
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
    
    -- Justify the inner text by the chosen side so the FIRST character (not the
    -- text's centre) pins to the anchor edge. Single-point anchored, so the text
    -- still overflows freely (no width clamp / truncation).
    local justify = "CENTER"
    if textAnchor == "LEFT" or textAnchor == "CENTERLEFT" then justify = "LEFT"
    elseif textAnchor == "RIGHT" or textAnchor == "CENTERRIGHT" then justify = "RIGHT" end
    textFrame.text:ClearAllPoints()
    textFrame.text:SetJustifyH(justify)
    if justify == "LEFT" then textFrame.text:SetPoint("LEFT", textFrame, "LEFT", 0, 0)
    elseif justify == "RIGHT" then textFrame.text:SetPoint("RIGHT", textFrame, "RIGHT", 0, 0)
    else textFrame.text:SetPoint("CENTER", textFrame, "CENTER", 0, 0) end

    -- Inner anchors (text inside bar)
    if textAnchor == "CENTER" then
      textFrame:SetPoint("CENTER", barFrame, "CENTER", offsetX, offsetY)
    elseif textAnchor == "RIGHT" or textAnchor == "CENTERRIGHT" then
      textFrame:SetPoint("RIGHT", barFrame, "RIGHT", -padding + offsetX, offsetY)
    elseif textAnchor == "LEFT" or textAnchor == "CENTERLEFT" then
      textFrame:SetPoint("LEFT", barFrame, "LEFT", padding + offsetX, offsetY)
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
      
      -- Justify the inner text by the chosen side so the FIRST character (not the
      -- text's centre) pins to the anchor edge. Single-point anchored = no truncation.
      local justify = "CENTER"
      if durationAnchor == "LEFT" or durationAnchor == "CENTERLEFT" or durationAnchor == "LEFT_INNER" then justify = "LEFT"
      elseif durationAnchor == "RIGHT" or durationAnchor == "CENTERRIGHT" or durationAnchor == "RIGHT_INNER" then justify = "RIGHT" end
      durationFrame.text:ClearAllPoints()
      durationFrame.text:SetJustifyH(justify)
      if justify == "LEFT" then durationFrame.text:SetPoint("LEFT", durationFrame, "LEFT", 0, 0)
      elseif justify == "RIGHT" then durationFrame.text:SetPoint("RIGHT", durationFrame, "RIGHT", 0, 0)
      else durationFrame.text:SetPoint("CENTER", durationFrame, "CENTER", 0, 0) end

      -- New format (matching textAnchor) + backward compatibility for old format
      if durationAnchor == "CENTER" then
        durationFrame:SetPoint("CENTER", barFrame, "CENTER", offsetX, offsetY)
      elseif durationAnchor == "RIGHT" or durationAnchor == "CENTERRIGHT" or durationAnchor == "RIGHT_INNER" then
        durationFrame:SetPoint("RIGHT", barFrame, "RIGHT", -padding + offsetX, offsetY)
      elseif durationAnchor == "LEFT" or durationAnchor == "CENTERLEFT" or durationAnchor == "LEFT_INNER" then
        durationFrame:SetPoint("LEFT", barFrame, "LEFT", padding + offsetX, offsetY)
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

  -- USE TEXTURE COLORS: claim (or release) the fill tint. Set AFTER the
  -- texture so the guard binds the current texture object.
  ns.API.SetNaturalFill(barFrame.bar, ns.API.IsNaturalFill(cfg))

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
      local offsetX = cfg.nameOffsetX or 0
      local offsetY = cfg.nameOffsetY or 0
      local padding = 5
      
      -- Justify the inner text by the chosen side so the FIRST character (not the
      -- text's centre) pins to the anchor edge. Single-point anchored = no truncation.
      local justify = "CENTER"
      if nameAnchor == "LEFT" or nameAnchor == "CENTERLEFT" then justify = "LEFT"
      elseif nameAnchor == "RIGHT" or nameAnchor == "CENTERRIGHT" then justify = "RIGHT" end
      nameFrame.text:ClearAllPoints()
      nameFrame.text:SetJustifyH(justify)
      if justify == "LEFT" then nameFrame.text:SetPoint("LEFT", nameFrame, "LEFT", 0, 0)
      elseif justify == "RIGHT" then nameFrame.text:SetPoint("RIGHT", nameFrame, "RIGHT", 0, 0)
      else nameFrame.text:SetPoint("CENTER", nameFrame, "CENTER", 0, 0) end

      -- New format (matching textAnchor) + backward compatibility for old format
      if nameAnchor == "CENTER" then
        nameFrame:SetPoint("CENTER", barFrame, "CENTER", offsetX, offsetY)
      elseif nameAnchor == "RIGHT" or nameAnchor == "CENTERRIGHT" then
        nameFrame:SetPoint("RIGHT", barFrame, "RIGHT", -padding + offsetX, offsetY)
      elseif nameAnchor == "LEFT" or nameAnchor == "CENTERLEFT" then
        nameFrame:SetPoint("LEFT", barFrame, "LEFT", padding + offsetX, offsetY)
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
  
  -- 12.1: re-push the freshly-applied fill/text style onto the engine duration overlay so
  -- option changes (bar texture, duration font/colour/decimals) take effect LIVE instead of
  -- only after a reload. No-op on live and on non-BD bars.
  if ns.BarDuration and IsTotemLikeBar(barConfig) then
    -- a bar switched TO pet/totem/ground mid-session may still be attached from
    -- its previous type; release our duration FontString back to us
    if ns.BarDuration.Detach then ns.BarDuration.Detach(barFrame) end
  elseif ns.BarDuration and ns.BarDuration.ApplyStyle then
    local bdDir = (cfg.durationBarFillMode == "fill")
      and Enum.StatusBarTimerDirection.ElapsedTime or Enum.StatusBarTimerDirection.RemainingTime
    local bdDurFmt
    local bdColorKey
    if cfg.durationTextColorEnabled and ns.DurationText and ns.DurationText.GetLiveSecondsColorFormatter then
      -- live variant: this is the option-change path, so the rules rewrite
      -- lands on the very object the engine binding is holding
      bdDurFmt = ns.DurationText.GetLiveSecondsColorFormatter(durationFrame and durationFrame.text,
        cfg, cfg.durationDecimals or 1)
      bdColorKey = ns.DurationText.SecondsColorKey and ns.DurationText.SecondsColorKey(cfg)
    end
    ns.BarDuration.ApplyStyle(barFrame, durationFrame, cfg.showDuration, cfg.durationDecimals or 1, cfg.durationColor, cfg.barColor, bdDir, bdDurFmt, cfg.durationTextColorEnabled and true or false, bdColorKey)
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
  AceConfigDialog:SelectGroup("ArcUI", "auras", "appearance")
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
-- ═══════════════════════════════════════════════════════════════════
-- ENGINE PREBUILD (reload/login mid-combat or mid-instance)
-- Slot CREATION is blocked from addon stacks while auras are secret
-- (RC 69189), and the normal bar init runs from a C_Timer well AFTER the
-- load window, so reloading during a pull left every engine bar empty
-- until combat ended. Fix (same shape as the aura-icons prebuild): run the
-- REAL update path once inside the load window, at PLAYER_LOGIN. Slots get
-- created there -- always legal -- and every later pass only retargets
-- filters, which is legal under secrecy.
--
-- Deliberately reuses the live path instead of a parallel opts builder: the
-- composition (bindings, thresholds, text) must match EXACTLY or the later
-- pass detects a change and tries to recreate, which is the very thing that
-- cannot happen in combat.
-- ═══════════════════════════════════════════════════════════════════
local enginePrebuildDone = false

function ns.Display.EnginePrebuild()
  if enginePrebuildDone then return end
  if not (ns.API and ns.API.IS_121) then return end
  local db = ns.API.GetDB and ns.API.GetDB()
  if not db or not db.bars then return end
  -- guard the early-login "Unknown" character key (spec-key fabrication lesson)
  local pn = UnitName and UnitName("player")
  if not pn or pn == "Unknown" then return end
  enginePrebuildDone = true

  -- CDM-sourced bars resolve their engine identity from the CDM frame, so the
  -- catalogue has to be scanned BEFORE the pass or those bars simply skip the
  -- attach and get nothing for the session (they were the ones "sometimes not
  -- animating"). Custom spell-ID bars never needed this.
  if ns.API.ScanAllCDMIcons then ns.API.ScanAllCDMIcons() end

  -- tell BarDuration this is the load window: slot creation is legal here even
  -- when auras are already secret (reloading straight into an instance)
  if ns.BarDuration then
    ns.BarDuration.loadWindow = true
    -- restore the saved debug flag FIRST: everything worth diagnosing about a
    -- combat reload happens in the next few lines, before any slash command
    -- could turn logging on
    local g = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if g and g.barDurDebug then ns.BarDuration.debug = true end
  end
  prebuildPass = true
  for barNumber, cfg in pairs(db.bars) do
    if type(cfg) == "table" and cfg.tracking and cfg.tracking.enabled
       and cfg.display and cfg.display.displayType ~= "icon" then
      ns.Display.ApplyAppearance(barNumber)      -- sizes/positions the frame the slots anchor to
      if ns.API.RefreshDisplay then ns.API.RefreshDisplay(barNumber) end
      -- ...and then call the update DIRECTLY. RefreshDisplay goes through
      -- Core, which resolves the bar's CDM frame first and simply returns for
      -- any bar whose frame is not in the CDM cache yet -- at login that is
      -- most of them, so those bars never reached the engine attach and lost
      -- their only chance to create a slot (log: cd=82624 attached at 04:02:06
      -- instead of at login, then deferred forever in between). Calling the
      -- update straight lets engineArm arm the slot from the saved config,
      -- which is all the engine needs; the aura does not have to be present.
      local cfgT = cfg.tracking
      if cfgT.useDurationBar then
        ns.Display.UpdateDurationBar(barNumber, 0, 0, false, nil, nil,
          cfgT.iconTextureID, cfgT.buffName)
      else
        -- STACK BARS arm here too: the custom-lane fill binding and the
        -- CDM-sourced countdown (text-only ArcTimer host) are both
        -- create-time engine work with the same one-chance-per-session
        -- constraint as the duration bars above.
        ns.Display.UpdateBar(barNumber, 0, cfgT.maxStacks or 10, false, nil,
          cfgT.iconTextureID, cfgT.buffName)
      end
    end
  end
  -- TEXTURES arm here too: their drain/countdown engines have the same
  -- one-chance-per-session constraint, and their own update bails on
  -- inactive before the attach (Textures._prebuild lifts that gate).
  if ns.Textures and ns.Textures.UpdateTexture and db.textures then
    ns.Textures._prebuild = true
    for num, tcfg in pairs(db.textures) do
      if type(tcfg) == "table" and tcfg.tracking and tcfg.tracking.enabled then
        ns.Textures.UpdateTexture(num)
      end
    end
    ns.Textures._prebuild = nil
    if ns.Textures.RefreshAll then ns.Textures.RefreshAll() end
  end

  prebuildPass = false
  if ns.BarDuration then ns.BarDuration.loadWindow = false end

  -- the real init pass (MarkInitializationComplete + RefreshAllBars) shows
  -- these properly a moment later; keep them hidden until then so nothing
  -- flashes unpositioned
  for barNumber in pairs(db.bars) do
    local f = barFrames[barNumber]
    if f then
      SafeHide(f.barFrame); SafeHide(f.textFrame); SafeHide(f.durationFrame)
      SafeHide(f.nameFrame); SafeHide(f.barIconFrame)
    end
  end
end

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