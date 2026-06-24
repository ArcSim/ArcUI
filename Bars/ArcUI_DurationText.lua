-- ===================================================================
-- ArcUI_DurationText.lua
-- Thin wrapper over 12.0.7's C_DurationUtil.CreateDurationTextBinding.
--
-- A DurationTextBinding makes Blizzard drive a FontString's countdown text
-- entirely C-side — no Lua OnUpdate. We bind a (secret-safe) duration object
-- once and reapply it whenever it changes; Blizzard formats + updates the text
-- on its own interval. This replaces the per-bar 10fps "GetRemainingDuration()
-- -> SetText" OnUpdate handlers (category A of the bar OnUpdate audit).
--
-- Feature-probed: on a client without these APIs, IsSupported() is false and
-- callers keep their existing OnUpdate path. Verified against live 12.0.7.68235:
--   C_DurationUtil.CreateDurationTextBinding() -> binding
--   binding:SetFontString(fs) / :SetDuration(durObj) / :SetFormatter(numFmt)
--   binding:SetUpdateInterval(s) / :SetZeroDurationText / :SetExpiredText
--   binding:Enable() / :Disable()
--   C_StringUtil.CreateNumericRuleFormatter():AddBreakpoint{threshold,format}
-- ===================================================================

local ADDON, ns = ...
ns = ns or {}
ns.DurationText = ns.DurationText or {}
local DT = ns.DurationText

local supported = (C_DurationUtil and C_DurationUtil.CreateDurationTextBinding
                   and C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) and true or false

function DT.IsSupported()
  return supported
end

-- Shared numeric formatters keyed by decimal count. A single breakpoint at
-- threshold 0 with a "%.Nf" format reproduces ArcUI's existing plain-decimal
-- look exactly (e.g. "12.3"), so there is no visible change.
local formatters = {}
local function GetFormatter(decimals)
  decimals = decimals or 1
  local f = formatters[decimals]
  if not f then
    f = C_StringUtil.CreateNumericRuleFormatter()
    f:AddBreakpoint({ threshold = 0, format = "%." .. decimals .. "f" })
    formatters[decimals] = f
  end
  return f
end

-- ===================================================================
-- THRESHOLD TEXT COLOURING (optional, opt-in via DT.Bind's `d` arg)
-- Recolours the countdown text by remaining-time thresholds the same way the
-- duration BAR recolours its fill: a ColorCurve is evaluated against the SECRET
-- duration object (durObj:EvaluateRemainingPercent) and the resulting SECRET
-- colour is fed to FontString:SetTextColor (a secret-safe sink). A single shared
-- 20fps ticker drives every colour-bound FontString and only runs while at least
-- one aura is active (same active-only pattern as the bar fill's OnUpdate).
-- Reads INDEPENDENT fields off the display config: durationTextColorEnabled +
-- durationTextThreshold{2..5}{Enabled,Value,Color} + durationTextThresholdAsSeconds
-- + durationTextThresholdMaxDuration. Base colour (100% remaining) = durationColor.
-- ===================================================================
local TEXT_THRESH_DEFAULT_VALUES = { [2] = 75, [3] = 50, [4] = 25, [5] = 10 }
local TEXT_THRESH_DEFAULT_COLORS = {
  [2] = { r = 0.8, g = 0.8, b = 0, a = 1 },  -- yellow
  [3] = { r = 1,   g = 0.5, b = 0, a = 1 },  -- orange
  [4] = { r = 1,   g = 0.3, b = 0, a = 1 },  -- red-orange
  [5] = { r = 1,   g = 0,   b = 0, a = 1 },  -- red
}

-- Build a ColorCurve from the text-threshold settings on a display config table.
-- Mirrors the duration bar's step-curve construction (pairs of points an epsilon
-- apart = instant transitions). Returns nil when the feature is off, no bands are
-- enabled, or the ColorCurve API is missing.
function DT.BuildTextThresholdCurve(d, baseColor)
  if not d or not d.durationTextColorEnabled then return nil end
  if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end
  baseColor = baseColor or { r = 1, g = 1, b = 1, a = 1 }

  local thresholds = {}
  for i = 2, 5 do
    if d["durationTextThreshold" .. i .. "Enabled"] then
      local value = d["durationTextThreshold" .. i .. "Value"] or TEXT_THRESH_DEFAULT_VALUES[i]
      local color = d["durationTextThreshold" .. i .. "Color"] or TEXT_THRESH_DEFAULT_COLORS[i]
      thresholds[#thresholds + 1] = { value = value, color = color }
    end
  end
  if #thresholds == 0 then return nil end
  table.sort(thresholds, function(a, b) return a.value < b.value end)

  local asSeconds = d.durationTextThresholdAsSeconds
  local maxDuration = tonumber(d.durationTextThresholdMaxDuration) or 30
  if maxDuration <= 0 then maxDuration = 30 end
  local EPSILON = 0.0001

  local curve = C_CurveUtil.CreateColorCurve()
  local lowest = thresholds[1].color
  curve:AddPoint(0.0, CreateColor(lowest.r, lowest.g, lowest.b, lowest.a or 1))
  for i = 1, #thresholds do
    local t = thresholds[i]
    local pct = asSeconds and (t.value / maxDuration) or (t.value / 100)
    if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
    local nextColor = (i == #thresholds) and baseColor or thresholds[i + 1].color
    local cc = t.color
    if pct > EPSILON then
      curve:AddPoint(pct - EPSILON, CreateColor(cc.r, cc.g, cc.b, cc.a or 1))
    end
    curve:AddPoint(pct, CreateColor(nextColor.r, nextColor.g, nextColor.b, nextColor.a or 1))
  end
  curve:AddPoint(1.0, CreateColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1))
  return curve
end

-- ===================================================================
-- SECONDS-MODE THRESHOLD COLOURING WITH NO TICKER (formatter colour escapes)
-- In SECONDS mode the band colours are baked into the duration formatter's
-- breakpoints: each breakpoint's format string carries a |cAARRGGBB..|r colour
-- escape, and Blizzard's DurationTextBinding picks the breakpoint by the SECRET
-- remaining seconds and writes the coloured text on its own C-side interval -- so
-- there is NO Lua OnUpdate. (Percent mode can't use this: the formatter samples
-- remaining SECONDS, not percent, so percent thresholds stay on the ticker below.)
local function ColorEscape(c)
  local a  = math.floor((c.a or 1) * 255 + 0.5)
  local r  = math.floor((c.r or 1) * 255 + 0.5)
  local g  = math.floor((c.g or 1) * 255 + 0.5)
  local bb = math.floor((c.b or 1) * 255 + 0.5)
  return string.format("|c%02x%02x%02x%02x", a, r, g, bb)
end

-- Enabled seconds thresholds, sorted ascending by value.
local function CollectSecondsThresholds(d)
  local t = {}
  for i = 2, 5 do
    if d["durationTextThreshold" .. i .. "Enabled"] then
      local v = tonumber(d["durationTextThreshold" .. i .. "Value"] or TEXT_THRESH_DEFAULT_VALUES[i])
      local c = d["durationTextThreshold" .. i .. "Color"] or TEXT_THRESH_DEFAULT_COLORS[i]
      if v and v > 0 then t[#t + 1] = { value = v, color = c } end
    end
  end
  table.sort(t, function(a, b) return a.value < b.value end)
  return t
end

-- A cache key so the formatter is only rebuilt + re-applied when the bands change.
local function SecondsColorKey(d)
  local t, parts = CollectSecondsThresholds(d), {}
  for _, e in ipairs(t) do
    parts[#parts + 1] = string.format("%g=%.2f,%.2f,%.2f,%.2f", e.value, e.color.r, e.color.g, e.color.b, e.color.a or 1)
  end
  return table.concat(parts, "|")
end

-- Build a NumericRuleFormatter whose breakpoints switch the text colour by the
-- remaining-seconds value. Band [0, t1) uses the lowest threshold's colour; each
-- threshold opens the band ABOVE it; above the highest threshold the format carries
-- no colour escape so the FontString's own colour (durationColor) shows. nil if no
-- bands enabled. (NumericRuleFormatBreakpoint: highest threshold <= value wins.)
function DT.BuildSecondsColorFormatter(d, decimals)
  if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) then return nil end
  local t = CollectSecondsThresholds(d)
  if #t == 0 then return nil end
  local numFmt = "%." .. (decimals or 1) .. "f"
  local f = C_StringUtil.CreateNumericRuleFormatter()
  f:AddBreakpoint({ threshold = 0, format = ColorEscape(t[1].color) .. numFmt .. "|r" })
  for i = 1, #t do
    local nextColor = t[i + 1] and t[i + 1].color
    local fmt = nextColor and (ColorEscape(nextColor) .. numFmt .. "|r") or numFmt
    f:AddBreakpoint({ threshold = t[i].value, format = fmt })
  end
  return f
end

-- Shared 20fps colour ticker. colorBindings maps FontString -> {unit, auraID,
-- curve, baseColor}. Created lazily; only runs while bindings exist.
local colorBindings = {}
local colorTicker
local colorElapsed = 0

local function ApplyBaseColor(fs, baseColor)
  if fs and baseColor and fs.SetTextColor then
    fs:SetTextColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
  end
end

local function StopColorTickerIfIdle()
  if colorTicker and colorTicker._running and not next(colorBindings) then
    colorTicker:SetScript("OnUpdate", nil)
    colorTicker._running = false
  end
end

local function ColorTick(_, elapsed)
  colorElapsed = colorElapsed + elapsed
  if colorElapsed < 0.05 then return end   -- throttle to 20fps
  colorElapsed = 0
  for fs, data in pairs(colorBindings) do
    -- GetAuraDuration returns nil for a gone aura and does not throw -- no pcall.
    local durObj = C_UnitAuras and C_UnitAuras.GetAuraDuration
                   and C_UnitAuras.GetAuraDuration(data.unit, data.auraID)
    if not durObj then
      ApplyBaseColor(fs, data.baseColor)
      colorBindings[fs] = nil
    else
      local cr = durObj:EvaluateRemainingPercent(data.curve)   -- SECRET colour
      if cr then fs:SetTextColor(cr:GetRGBA()) else ApplyBaseColor(fs, data.baseColor) end
    end
  end
  StopColorTickerIfIdle()
end

-- Start (or refresh) threshold colouring on a FontString.
function DT.BindColor(fs, unit, auraID, curve, baseColor)
  if not fs or not unit or not auraID or not curve then return end
  colorBindings[fs] = { unit = unit, auraID = auraID, curve = curve, baseColor = baseColor }
  -- Apply once immediately so the colour is correct before the next tick.
  local durObj = C_UnitAuras and C_UnitAuras.GetAuraDuration
                 and C_UnitAuras.GetAuraDuration(unit, auraID)
  local cr = durObj and durObj:EvaluateRemainingPercent(curve)
  if cr then fs:SetTextColor(cr:GetRGBA()) end
  if not colorTicker then colorTicker = CreateFrame("Frame") end
  if not colorTicker._running then
    colorElapsed = 0
    colorTicker._running = true
    colorTicker:SetScript("OnUpdate", ColorTick)
  end
end

-- Stop threshold colouring on a FontString; optionally reset it to baseColor.
function DT.UnbindColor(fs, baseColor)
  if not fs then return end
  colorBindings[fs] = nil
  if baseColor then ApplyBaseColor(fs, baseColor) end
  StopColorTickerIfIdle()
end

-- Bind (or refresh) a FontString to a duration object so Blizzard drives its
-- countdown text. The binding is created once and cached on the FontString
-- (an ArcUI-created region, so writing a field on it is taint-safe); later
-- calls just reapply the duration / formatter. Returns true on success.
--
-- Optional threshold colouring: a caller opts in by passing its display config
-- `d` (plus the `unit` + `auraID` used to re-read the duration each tick). When
-- `d` is omitted the text colour is left entirely alone (old behaviour).
function DT.Bind(fs, durObj, decimals, unit, auraID, d)
  if not supported or not fs or not durObj then return false end
  local b = fs._arcDurBinding
  if not b then
    b = C_DurationUtil.CreateDurationTextBinding()
    b:SetFontString(fs)
    b:SetZeroDurationText("")
    b:SetExpiredText("")
    b:SetUpdateInterval(0.1)   -- 10fps, matches the cadence of the old OnUpdate
    fs._arcDurBinding = b
    fs._arcDurFmtKey = nil
  end

  -- Pick the formatter. When threshold colouring is on we bake the band colours
  -- into the formatter's breakpoints (SECONDS thresholds), so the colour is driven
  -- entirely C-side -- NO OnUpdate/ticker. Otherwise the plain decimals formatter.
  -- (Percent-based colouring is parked for now; it would need the ticker below.)
  -- Re-applied only when the key changes.
  local fmt, fmtKey
  if d and d.durationTextColorEnabled then
    fmt = DT.BuildSecondsColorFormatter(d, decimals)   -- nil if no bands enabled
    if fmt then fmtKey = "c:" .. tostring(decimals) .. ":" .. SecondsColorKey(d) end
  end
  if not fmt then
    fmt = GetFormatter(decimals)
    fmtKey = "p:" .. tostring(decimals)
  end
  if fs._arcDurFmtKey ~= fmtKey then
    b:SetFormatter(fmt)
    fs._arcDurFmtKey = fmtKey
  end

  -- Re-applying the duration on the existing binding restarts the C-side
  -- countdown (proven: bars on the full UpdateBar path refresh correctly on aura
  -- reapply). Callers must RE-CALL Bind whenever the duration changes; the bug
  -- where the text stuck on the old value was a caller skipping this re-bind, not
  -- the binding itself.
  b:SetDuration(durObj)        -- secret durObj is a safe sink
  b:Enable()

  if d ~= nil then
    -- Seconds threshold colouring is handled entirely by the formatter above, so
    -- there is no ticker. Make sure none is running and the FontString sits at its
    -- base colour (shown for the above-all-thresholds band). The percent/ticker
    -- path (DT.BindColor / DT.BuildTextThresholdCurve) is parked for a future option.
    DT.UnbindColor(fs, d.durationColor)
  end
  return true
end

-- Stop driving a FontString (aura/totem gone). Keeps the binding cached for
-- reuse and blanks the text.
function DT.Unbind(fs)
  if not fs then return end
  local b = fs and fs._arcDurBinding
  if b then b:Disable() end
  if fs.SetText then fs:SetText("") end
  DT.UnbindColor(fs, nil)   -- also stop the colour ticker (text is blanked anyway)
end
