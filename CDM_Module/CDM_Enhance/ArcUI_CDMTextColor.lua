-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_CDMTextColor.lua — Duration-Based Cooldown Text Coloring
--
-- Colors cooldown countdown text based on remaining seconds using
-- DurationObject:EvaluateRemainingDuration(colorCurve) — secret-safe.
--
-- The ColorCurve X-axis is remaining seconds (not percentage):
--   0s = expiring → red
--   5s = soon → yellow
--   60s+ = plenty → white
--
-- Duration providers:
--   Auras:    C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
--   Spells:   C_Spell.GetSpellCooldownDuration(spellID)
--   Charges:  C_Spell.GetSpellChargeDuration(spellID)
-- ═══════════════════════════════════════════════════════════════════════════

local AddonName, ns = ...
ns.CDMTextColor = ns.CDMTextColor or {}

local GetIconSettings  -- forward ref, resolved on first tick

-- ═══════════════════════════════════════════════════════════════════════════
-- PRESET DEFINITIONS
--
-- Each preset is an array of { threshold (seconds), color } entries plus
-- a defaultColor for durations above the highest threshold.
-- Uses Step curves: color snaps instantly at each threshold boundary.
-- ═══════════════════════════════════════════════════════════════════════════

local PRESETS = {
  classic = {
    entries = {
      { threshold = 5,    color = CreateColor(1.00, 0.39, 0.28, 1) },  -- Tomato red:  0-5s
      { threshold = 60,   color = CreateColor(1.00, 1.00, 0.00, 1) },  -- Yellow:      5-60s
      { threshold = 3600, color = CreateColor(1.00, 1.00, 1.00, 1) },  -- White:       60s-1h
    },
    percentEntries = {
      { threshold = 8,   color = CreateColor(1.00, 0.39, 0.28, 1) },  -- Tomato red:  0-8%
      { threshold = 50,  color = CreateColor(1.00, 1.00, 0.00, 1) },  -- Yellow:      8-50%
      { threshold = 100, color = CreateColor(1.00, 1.00, 1.00, 1) },  -- White:       50-100%
    },
    defaultColor = CreateColor(0.67, 0.67, 0.67, 1),  -- Grey: above max
  },
  warm = {
    entries = {
      { threshold = 3,    color = CreateColor(1.00, 0.20, 0.10, 1) },  -- Red:    0-3s
      { threshold = 10,   color = CreateColor(1.00, 0.50, 0.00, 1) },  -- Orange: 3-10s
      { threshold = 30,   color = CreateColor(1.00, 0.85, 0.00, 1) },  -- Gold:   10-30s
      { threshold = 120,  color = CreateColor(1.00, 1.00, 0.60, 1) },  -- Pale:   30s-2m
    },
    percentEntries = {
      { threshold = 5,   color = CreateColor(1.00, 0.20, 0.10, 1) },  -- Red:    0-5%
      { threshold = 15,  color = CreateColor(1.00, 0.50, 0.00, 1) },  -- Orange: 5-15%
      { threshold = 40,  color = CreateColor(1.00, 0.85, 0.00, 1) },  -- Gold:   15-40%
      { threshold = 75,  color = CreateColor(1.00, 1.00, 0.60, 1) },  -- Pale:   40-75%
    },
    defaultColor = CreateColor(1.00, 1.00, 1.00, 1),  -- White: above max
  },
  cool = {
    entries = {
      { threshold = 5,    color = CreateColor(0.40, 0.70, 1.00, 1) },  -- Light blue: 0-5s
      { threshold = 30,   color = CreateColor(0.30, 0.50, 0.90, 1) },  -- Mid blue:   5-30s
      { threshold = 120,  color = CreateColor(0.70, 0.85, 1.00, 1) },  -- Ice blue:   30s-2m
    },
    percentEntries = {
      { threshold = 10,  color = CreateColor(0.40, 0.70, 1.00, 1) },  -- Light blue: 0-10%
      { threshold = 40,  color = CreateColor(0.30, 0.50, 0.90, 1) },  -- Mid blue:   10-40%
      { threshold = 75,  color = CreateColor(0.70, 0.85, 1.00, 1) },  -- Ice blue:   40-75%
    },
    defaultColor = CreateColor(1.00, 1.00, 1.00, 1),  -- White: above max
  },
  nature = {
    entries = {
      { threshold = 5,    color = CreateColor(1.00, 0.30, 0.20, 1) },  -- Red:    0-5s
      { threshold = 30,   color = CreateColor(1.00, 0.80, 0.00, 1) },  -- Yellow: 5-30s
      { threshold = 120,  color = CreateColor(0.30, 1.00, 0.30, 1) },  -- Green:  30s-2m
    },
    percentEntries = {
      { threshold = 10,  color = CreateColor(1.00, 0.30, 0.20, 1) },  -- Red:    0-10%
      { threshold = 40,  color = CreateColor(1.00, 0.80, 0.00, 1) },  -- Yellow: 10-40%
      { threshold = 75,  color = CreateColor(0.30, 1.00, 0.30, 1) },  -- Green:  40-75%
    },
    defaultColor = CreateColor(1.00, 1.00, 1.00, 1),  -- White: above max
  },
  urgent = {
    entries = {
      { threshold = 3,    color = CreateColor(1.00, 0.00, 0.00, 1) },  -- Pure red:  0-3s
      { threshold = 10,   color = CreateColor(1.00, 0.60, 0.00, 1) },  -- Orange:    3-10s
      { threshold = 60,   color = CreateColor(1.00, 1.00, 1.00, 1) },  -- White:     10-60s
    },
    percentEntries = {
      { threshold = 5,   color = CreateColor(1.00, 0.00, 0.00, 1) },  -- Pure red:  0-5%
      { threshold = 20,  color = CreateColor(1.00, 0.60, 0.00, 1) },  -- Orange:    5-20%
      { threshold = 60,  color = CreateColor(1.00, 1.00, 1.00, 1) },  -- White:     20-60%
    },
    defaultColor = CreateColor(0.80, 0.80, 0.80, 1),  -- Light grey: above max
  },
}

-- Display names for options dropdowns
ns.CDMTextColor.PRESET_NAMES = {
  custom  = "Custom (Your Settings)",
  classic = "Classic (Red / Yellow / White)",
  warm    = "Warm (Red / Orange / Gold)",
  cool    = "Cool (Blue Tones)",
  nature  = "Nature (Red / Yellow / Green)",
  urgent  = "Urgent (Bold Red / Orange)",
}

--- Convert a preset to custom entry format for the T1-T5 editor.
--- When usePercent is true, returns percent-based thresholds.
--- Returns entries table + defaultColor table, ready to write into settings.
function ns.CDMTextColor.GetPresetEntries(presetName, usePercent)
  local preset = PRESETS[presetName]
  if not preset then return nil end

  local source = usePercent and preset.percentEntries or preset.entries
  if not source then return nil end

  local entries = {}
  for i, e in ipairs(source) do
    local r, g, b = e.color:GetRGB()
    entries[i] = {
      enabled = true,
      threshold = e.threshold,
      color = { r = r, g = g, b = b, a = 1 },
    }
  end
  -- Fill remaining T slots as disabled
  for i = #entries + 1, 5 do
    entries[i] = { enabled = false, threshold = 0, color = { r = 1, g = 1, b = 1, a = 1 } }
  end

  local dr, dg, db = preset.defaultColor:GetRGB()
  local defaultColor = { r = dr, g = dg, b = db, a = 1 }

  return entries, defaultColor
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CURVE BUILDER
--
-- Builds a Step ColorCurve from threshold entries.
-- X-axis = remaining seconds. Uses 0.5s offset between zones so the
-- transition happens cleanly past integer boundaries.
-- ═══════════════════════════════════════════════════════════════════════════

local curveCache = {}  -- [presetName] = colorCurve

local function BuildCurveFromEntries(entries, defaultColor, usePercent)
  if not entries or #entries == 0 then return nil end

  local curve = C_CurveUtil.CreateColorCurve()
  curve:SetType(Enum.LuaCurveType.Step)

  -- Percent mode uses 0-1 scale so offset must be tiny; seconds use 0.5s
  local OFFSET = usePercent and 0.005 or 0.5

  -- Point at 0: color for the lowest zone (expiring)
  curve:AddPoint(0, entries[1].color)

  -- Each subsequent threshold starts a new color zone
  for i = 2, #entries do
    local prevThreshold = entries[i - 1].threshold or 0
    curve:AddPoint(prevThreshold + OFFSET, entries[i].color)
  end

  -- Default color for anything above the highest threshold
  if defaultColor then
    local lastThreshold = entries[#entries].threshold or 0
    curve:AddPoint(lastThreshold + OFFSET, defaultColor)
  end

  return curve
end

local function GetCurveForPreset(presetName)
  if curveCache[presetName] then return curveCache[presetName] end

  local preset = PRESETS[presetName]
  if not preset then return nil end

  local curve = BuildCurveFromEntries(preset.entries, preset.defaultColor)
  if curve then
    curveCache[presetName] = curve
  end
  return curve
end

--- Build a curve from user-defined custom entries
local function GetCurveForCustom(customEntries, baseColorTbl, usePercent)
  if not customEntries or #customEntries == 0 then return nil end

  -- Filter to enabled entries only
  local active = {}
  for _, e in ipairs(customEntries) do
    if e.enabled then
      active[#active + 1] = e
    end
  end
  if #active == 0 then return nil end

  -- Build a signature for caching so we don't rebuild every tick
  local sig = usePercent and "pct" or "sec"
  for _, e in ipairs(active) do
    local c = e.color or {}
    sig = sig .. string.format("_%d_%.2f%.2f%.2f", e.threshold or 0, c.r or 1, c.g or 1, c.b or 1)
  end
  -- Include base color in sig so cache invalidates when base color changes
  if baseColorTbl then
    sig = sig .. string.format("_b%.2f%.2f%.2f", baseColorTbl.r or 1, baseColorTbl.g or 1, baseColorTbl.b or 1)
  end

  if curveCache[sig] then return curveCache[sig] end

  -- Convert {threshold, color={r,g,b}} to {threshold, CreateColor()}
  local entries = {}
  for i, e in ipairs(active) do
    local c = e.color or {}
    local t = e.threshold or 0
    -- EvaluateRemainingPercent uses 0-1 scale; user enters 0-100 scale
    if usePercent then t = t / 100 end
    entries[i] = {
      threshold = t,
      color = CreateColor(c.r or 1, c.g or 1, c.b or 1, 1),  -- alpha not supported on CD fontstrings
    }
  end
  table.sort(entries, function(a, b) return a.threshold < b.threshold end)

  -- Use base text color as above-max fallback so text reverts to normal above all thresholds
  local defaultColor
  if baseColorTbl then
    defaultColor = CreateColor(baseColorTbl.r or 1, baseColorTbl.g or 1, baseColorTbl.b or 1, 1)
  else
    defaultColor = CreateColor(1, 1, 1, 1)  -- white fallback
  end

  local curve = BuildCurveFromEntries(entries, defaultColor, usePercent)
  if curve then
    curveCache[sig] = curve
  end
  return curve
end

--- Get the ColorCurve for a given icon config
--- Always uses custom entries (preset dropdown populates custom entries on selection).
local function GetCurveForConfig(cfg)
  if not cfg or not cfg.cooldownText then return nil end
  local tc = cfg.cooldownText
  if not tc.durationColor then return nil end

  local usePercent = tc.durationColorUsePercent
  local baseColor = tc.color

  -- If custom entries exist, use them
  if tc.durationColorCustom and #tc.durationColorCustom > 0 then
    return GetCurveForCustom(tc.durationColorCustom, baseColor, usePercent)
  end

  -- No custom entries yet (user enabled toggle but hasn't picked a preset) — fall back to classic
  return GetCurveForPreset("classic")
end

-- Public: aura icons (12.1) feed this curve into the engine's DurationText
-- binding (options.textColorCurve) instead of the ticker path.
ns.CDMTextColor.GetCurveForConfig = GetCurveForConfig

--- Wipe curve cache (call when settings change)
local _checkedNoConfig = false  -- true when we scanned all frames and found no durationColor config

function ns.CDMTextColor.InvalidateCurves()
  wipe(curveCache)
  _checkedNoConfig = false  -- settings changed — re-scan on next event in case durationColor was just enabled
  -- Clear every applied banded countdown formatter (12.1 aura icons) so a
  -- settings change or disable never leaves a stale formatter on the widget;
  -- the next tick re-applies the current config. Desk-time only, cheap.
  if ns.CDMTextColor._ClearAllBandedFormatters then
    ns.CDMTextColor._ClearAllBandedFormatters()
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DURATION HOOK
--
-- Hook SetCooldownFromDurationObject on each frame's Cooldown widget to
-- capture the EXACT DurationObject being displayed. This is critical for
-- ignoreAuraOverride mode where CDMEnhance replaces the aura timer with
-- the spell cooldown — independent API queries can return the wrong timer.
-- ═══════════════════════════════════════════════════════════════════════════

local function InstallDurationHook(frame)
  local cd = frame and frame.Cooldown
  if not cd or cd._arcTextColorHooked then return end
  cd._arcTextColorHooked = true

  -- Capture DurationObject when CDMEnhance (or CDM) pushes one
  -- NOTE: Do NOT check _arcBypassCDHook here — CDMEnhance sets that flag
  -- around its override calls, which are exactly what we want to capture
  hooksecurefunc(cd, "SetCooldownFromDurationObject", function(self, durObj)
    local pf = self._arcParentFrame or frame
    -- Skip GCD: CDM pushes the GCD durObj (~1.5s) which would trigger the
    -- lowest threshold color. Keep the stale real-CD durObj through the GCD window.
    if pf.isOnGCD then return end
    pf._arcTextColorDurObj = durObj
  end)

  -- Clear stored DurationObject when cooldown is cleared
  hooksecurefunc(cd, "Clear", function(self)
    local pf = self._arcParentFrame or frame
    pf._arcTextColorDurObj = nil
  end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DURATION PROVIDERS
--
-- Get a DurationObject for a CDM icon frame based on its type.
-- Priority:
--   1. Hooked DurationObject (from SetCooldownFromDurationObject — matches display exactly)
--   2. Aura API (normal mode — CDM shows aura timer)
--   3. Spell API (fallback)
-- ═══════════════════════════════════════════════════════════════════════════

-- Feed the correct DurationObject onto the frame when spell goes on cooldown.
-- Called once when isActive becomes true — same pattern as CooldownState shadow frames.
-- The DurationObject ticks down on its own; no repeated API calls needed.
local function FeedTextColorDurObj(frame)
  local hasAura = frame.auraInstanceID and type(frame.auraInstanceID) == "number"

  -- Aura frame (non-IAO): aura timer fed via auraInstanceID path, not here
  if hasAura and not frame._arcIgnoreAuraOverride then return end

  local ci = frame.cooldownInfo
  local spellID = ci and (ci.overrideSpellID or ci.spellID)
  if not spellID or type(spellID) ~= "number" then return end

  -- Multi-charge (maxCharges>1): use GetSpellChargeDuration (per-charge recharge timer)
  -- Regular / 1-charge: use GetSpellCooldownDuration
  local chargeInfo = C_Spell.GetSpellCharges(spellID)
  if chargeInfo and chargeInfo.maxCharges and chargeInfo.maxCharges > 1 then
    local durObj = C_Spell.GetSpellChargeDuration and C_Spell.GetSpellChargeDuration(spellID)
    if durObj then frame._arcTextColorDurObj = durObj end
  else
    local durObj = C_Spell.GetSpellCooldownDuration(spellID)
    if durObj then frame._arcTextColorDurObj = durObj end
  end
end

local function GetDurationForFrame(frame)
  if not frame then return nil end

  -- Stored DurationObject (fed when cooldown started, or from SetCooldownFromDurationObject hook)
  local stored = frame._arcTextColorDurObj
  if stored then return stored end

  -- Aura fallback (normal aura mode — no stored obj yet)
  local auraID = frame.auraInstanceID
  -- 12.1: GetAuraDuration THROWS while the unit's auras are secret (the auraID stays NON-secret),
  -- so gate on the ns.API.AurasSecret probe. Skip -> text uses static color. Inert on live.
  if auraID and type(auraID) == "number" and not (ns.API and ns.API.AurasSecret and ns.API.AurasSecret(frame.auraDataUnit or frame.unitToken or "player")) then
    local unit = frame.auraDataUnit or frame.unitToken or "player"
    local dur = C_UnitAuras.GetAuraDuration(unit, auraID)
    if dur then return dur end
  end

  return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TEXT COLOR APPLICATION
-- ═══════════════════════════════════════════════════════════════════════════

local function ApplyColor(frame, color)
  if not color then return end
  local r, g, b = color:GetRGB()

  -- Flag so CDMEnhance's StyleCooldownText skips static color
  frame._arcDurationColorActive = true

  -- Our custom cooldown text overlay
  if frame._arcCooldownText then
    frame._arcCooldownText:SetTextColor(r, g, b)
  end

  -- Native Cooldown widget countdown text
  local cd = frame.Cooldown
  if cd then
    local countdownFS = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if countdownFS then
      countdownFS:SetTextColor(r, g, b)
    end
    -- Walk fontstring regions (CDM may create additional text)
    for _, region in ipairs({cd:GetRegions()}) do
      if region:IsObjectType("FontString") and not region._arcIsChargeText then
        region:SetTextColor(r, g, b)
      end
    end
  end
end

local function ResetColor(frame, cfg)
  frame._arcDurationColorActive = nil

  -- Restore to user's configured static color (RGB only — alpha not supported on CD fontstrings)
  local col = cfg and cfg.cooldownText and cfg.cooldownText.color
  local r, g, b = 1, 1, 1
  if col then r, g, b = col.r or 1, col.g or 1, col.b or 1 end

  if frame._arcCooldownText then
    frame._arcCooldownText:SetTextColor(r, g, b)
  end
  local cd = frame.Cooldown
  if cd then
    local countdownFS = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if countdownFS then
      countdownFS:SetTextColor(r, g, b)
    end
    for _, region in ipairs({cd:GetRegions()}) do
      if region:IsObjectType("FontString") and not region._arcIsChargeText then
        region:SetTextColor(r, g, b)
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 12.1 AURA ICONS — BANDED COUNTDOWN FORMATTER
--
-- On 12.1 CDM stopped pushing duration objects entirely (its refresh went
-- back to CooldownFrame_Set with numbers that are SECRET to addons), so for
-- aura icons the ticker has NO color source: the SetCooldownFromDurationObject
-- hook never fires and the aura duration APIs are walled. Instead the color
-- thresholds are BAKED into a NumericRuleFormatter (color escapes per band)
-- pushed once via Cooldown:SetCountdownFormatter — the engine then formats
-- AND colors the countdown C-side from the real remaining time. Secret-proof,
-- event-free, zero ticks. Above the top band no escape is emitted, so the
-- fontstring's own static color shows.
--
-- Because a set formatter takes over ALL countdown rendering, it replicates
-- the icon's Decimals / Abbreviate options (ns.CooldownFormatter semantics)
-- in its breakpoints. Seconds thresholds only: percent-of-duration needs the
-- total duration, which is unreadable for 12.1 auras.
--
-- Cooldown-viewer frames keep the durObj ticker: it works there, and a baked
-- formatter would color the GCD's own countdown on every keypress.
-- ═══════════════════════════════════════════════════════════════════════════

local fmtCache  = {}   -- [sig]   = formatter
local fmtFrames = {}   -- [frame] = sig currently applied to its Cooldown

local function ColorEscape(c)
  return string.format("|c%02x%02x%02x%02x", 255,
    math.floor((c.r or 1) * 255 + 0.5),
    math.floor((c.g or 1) * 255 + 0.5),
    math.floor((c.b or 1) * 255 + 0.5))
end

-- Build (or fetch) the banded formatter for this icon config.
-- Returns formatter, sig — or nil when this path can't serve the config.
local function BandedFormatterForConfig(cfg)
  local tc = cfg and cfg.cooldownText
  if not tc or not tc.durationColor then return nil end
  if tc.durationColorUsePercent then return nil end
  if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) then return nil end

  -- Color bands: enabled custom entries, else the classic preset (mirrors
  -- GetCurveForConfig's fallback so both paths color identically).
  local bands = {}
  if tc.durationColorCustom then
    for _, e in ipairs(tc.durationColorCustom) do
      local t = tonumber(e.threshold)
      if e.enabled and t and t > 0 and e.color then
        bands[#bands + 1] = { t = t, c = e.color }
      end
    end
  end
  if #bands == 0 then
    for _, e in ipairs(PRESETS.classic.entries) do
      local r, g, b = e.color:GetRGB()
      bands[#bands + 1] = { t = e.threshold, c = { r = r, g = g, b = b } }
    end
  end
  table.sort(bands, function(a, b) return a.t < b.t end)

  -- Format regions replicate ns.CooldownFormatter's decimals/abbrev handling.
  local decTo = 0
  if (tc.decimals or 0) == 1 then
    local v = tc.decimalThreshold
    decTo = (type(v) == "number" and v > 0) and v or 99999
  end
  if decTo > 60 then decTo = 60 end   -- minutes formatting takes over past 60
  local abbrev = tc.abbrevThreshold
  if type(abbrev) == "string" then
    abbrev = (abbrev == "1m" and 60) or (abbrev == "5m" and 300)
      or (abbrev == "1h" and 3600) or nil
  end
  if type(abbrev) ~= "number" or abbrev <= 0 then abbrev = nil end

  local parts = { "v1", tostring(decTo), tostring(abbrev) }
  for _, b in ipairs(bands) do
    parts[#parts + 1] = string.format("%g:%.2f,%.2f,%.2f",
      b.t, b.c.r or 1, b.c.g or 1, b.c.b or 1)
  end
  local sig = table.concat(parts, "|")
  if fmtCache[sig] then return fmtCache[sig], sig end

  -- Breakpoint edges: 0, every band edge, and every format-region edge.
  local edgeSet = { [0] = true, [60] = true, [3600] = true }
  for _, b in ipairs(bands) do edgeSet[b.t] = true end
  if decTo > 0 and decTo < 60 then edgeSet[decTo] = true end
  if abbrev and abbrev > 60 and abbrev < 3600 then edgeSet[abbrev] = true end
  local edges = {}
  for v in pairs(edgeSet) do edges[#edges + 1] = v end
  table.sort(edges)

  local Up = Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Up
  local f = C_StringUtil.CreateNumericRuleFormatter()
  for _, lo in ipairs(edges) do
    -- Band color for [lo, nextEdge): the first band whose threshold is above
    -- lo. Above the top band esc stays nil (static text color shows).
    local esc
    for _, b in ipairs(bands) do
      if lo < b.t then esc = ColorEscape(b.c) break end
    end
    local fmt, comps, step
    if lo >= 3600 then
      fmt, comps, step = "%d h", { { div = 3600 } }, 3600
    elseif lo >= 60 then
      if abbrev and lo < abbrev then
        fmt = "%d:%02d"
        comps = {
          { div = 60, step = 1, rounding = Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Down or nil },
          { mod = 60, step = 1, rounding = Enum.NumericRuleFormatRounding and Enum.NumericRuleFormatRounding.Down or nil },
        }
      else
        fmt, comps, step = "%d m", { { div = 60 } }, 60
      end
    elseif lo < decTo then
      fmt = "%.1f"
    else
      fmt = "%.0f"
    end
    local bp = { threshold = lo, format = esc and (esc .. fmt .. "|r") or fmt }
    if comps then bp.components = comps end
    if step then
      -- countdown-style ceiling: "2 m" until the timer crosses into 60s
      bp.step = step
      if Up then bp.rounding = Up end
    end
    f:AddBreakpoint(bp)
  end
  fmtCache[sig] = f
  return f, sig
end

local function ClearBandedFormatter(frame)
  if not fmtFrames[frame] then return end
  fmtFrames[frame] = nil
  local cd = frame.Cooldown
  if cd and cd.SetCountdownFormatter then cd:SetCountdownFormatter(nil) end
end

-- Forward-target for InvalidateCurves (defined above this section).
function ns.CDMTextColor._ClearAllBandedFormatters()
  wipe(fmtCache)
  for frame in pairs(fmtFrames) do
    local cd = frame.Cooldown
    if cd and cd.SetCountdownFormatter then cd:SetCountdownFormatter(nil) end
  end
  wipe(fmtFrames)
end

local function ApplyBandedFormatter(frame, cfg)
  local cd = frame.Cooldown
  if not (cd and cd.SetCountdownFormatter) then return false end
  local f, sig = BandedFormatterForConfig(cfg)
  if not f then
    ClearBandedFormatter(frame)
    return false
  end
  if fmtFrames[frame] ~= sig then
    cd:SetCountdownFormatter(f)
    fmtFrames[frame] = sig
  end
  return false   -- set-and-forget: this frame needs no tick
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TICKER — Runs at 0.1s, iterates group members, applies text color
-- ═══════════════════════════════════════════════════════════════════════════

local ticker = nil
local activeFrames = {}  -- [frame] = true

local function ProcessFrame(frame, cfg, viewerType)
  -- 12.1 aura icons take the baked-formatter path (see block above): the
  -- ticker has no readable duration source for them.
  if viewerType == "aura" and ns.API and ns.API.IS_121 then
    return ApplyBandedFormatter(frame, cfg)
  end
  -- Install duration hook once per frame (captures CDMEnhance's DurationObject)
  InstallDurationHook(frame)

  local curve = GetCurveForConfig(cfg)
  if not curve then
    if activeFrames[frame] then ResetColor(frame, cfg); activeFrames[frame] = nil end
    return false
  end

  if not frame:IsVisible() then
    if activeFrames[frame] then activeFrames[frame] = nil end
    return false
  end

  -- Gate on isActive (non-secret per 12.0.1) — don't color when spell is ready.
  -- For charge spells use GetSpellCharges.isActive (no GCD filter needed).
  -- For regular/1-charge use GetSpellCooldown.isActive + GCD filter.
  -- Aura frames bypass this check — they use auraInstanceID path below.
  local hasAura = frame.auraInstanceID and type(frame.auraInstanceID) == "number"
  if not hasAura then
    local ci = frame.cooldownInfo
    local spellID = ci and (ci.overrideSpellID or ci.spellID)
    if spellID then
      local onCooldown = false
      local chargeInfo = C_Spell.GetSpellCharges(spellID)
      if chargeInfo and chargeInfo.maxCharges and chargeInfo.maxCharges > 1 then
        onCooldown = chargeInfo.isActive == true
      else
        local cdInfo = C_Spell.GetSpellCooldown(spellID)
        onCooldown = cdInfo and cdInfo.isActive == true and cdInfo.isOnGCD ~= true
      end
      if not onCooldown then
        -- Spell came off cooldown — clear stored durObj and reset color
        frame._arcTextColorDurObj = nil
        if activeFrames[frame] then ResetColor(frame, cfg); activeFrames[frame] = nil end
        return false
      else
        -- Spell just went on cooldown or is on cooldown — feed durObj if not set yet
        if not frame._arcTextColorDurObj then
          FeedTextColorDurObj(frame)
        end
      end
    end
  end

  local dur = GetDurationForFrame(frame)
  if dur then
    -- EvaluateRemainingDuration: evaluates curve at remaining seconds
    -- EvaluateRemainingPercent: evaluates curve at remaining percent (0-100)
    local usePercent = cfg and cfg.cooldownText and cfg.cooldownText.durationColorUsePercent
    local color
    if usePercent then
      color = dur:EvaluateRemainingPercent(curve)
    else
      color = dur:EvaluateRemainingDuration(curve)
    end
    if color then
      ApplyColor(frame, color)
      activeFrames[frame] = true
      return true
    end
  end

  return activeFrames[frame] ~= nil
end


local function OnTick()
  if not GetIconSettings then
    if ns.CDMEnhance and ns.CDMEnhance.GetIconSettings then
      GetIconSettings = ns.CDMEnhance.GetIconSettings
    else
      return
    end
  end

  -- GetEnhancedFrames() returns ALL CDM frames: grouped, free-positioned, auras, cooldowns
  -- Same pattern as CustomLabel.RefreshAll()
  local GetEnhancedFrames = ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrames
  if not GetEnhancedFrames then return end

  local frames = GetEnhancedFrames()
  if not frames then return end

  local hasActive = false

  for cdID, data in pairs(frames) do
    if data.frame then
      local cfg = GetIconSettings(cdID)
      -- Fast-skip frames with no durationColor enabled — most frames won't have it
      if cfg and cfg.cooldownText and cfg.cooldownText.durationColor then
        if ProcessFrame(data.frame, cfg, data.viewerType) then
          hasActive = true
        end
      elseif activeFrames[data.frame] or fmtFrames[data.frame] then
        -- Was active but config disabled — reset and remove
        ResetColor(data.frame, cfg)
        activeFrames[data.frame] = nil
        ClearBandedFormatter(data.frame)
      end
    end
  end

  -- Stop ticker when nothing needs coloring
  if not hasActive then
    if ticker then
      ticker:Cancel()
      ticker = nil
    end
    wipe(activeFrames)
  end
end

function ns.CDMTextColor.Start()
  if not ticker then
    ticker = C_Timer.NewTicker(0.5, OnTick)
  end
end

function ns.CDMTextColor.Stop()
  if ticker then
    ticker:Cancel()
    ticker = nil
  end
  -- Reset all frames we were coloring
  for frame in pairs(activeFrames) do
    local cdID = frame.cooldownID
    local cfg = GetIconSettings and cdID and GetIconSettings(cdID) or nil
    ResetColor(frame, cfg)
  end
  wipe(activeFrames)
  if ns.CDMTextColor._ClearAllBandedFormatters then
    ns.CDMTextColor._ClearAllBandedFormatters()
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 12.1 DIAGNOSTIC (/arctcprobe) — the "duration text color dead on PTR" bug.
-- Answers, on a live client, the two questions the fix depends on:
--   1. do AURA frames have a hook-captured durObj (the path that matches the
--      display exactly and needs no aura API read)?
--   2. does durObj:EvaluateRemainingDuration(curve) work on a (possibly
--      secret) aura durObj for tainted callers, or does it throw?
-- USER-TRIGGERED, one pass, prints per-frame findings. If question 2 throws,
-- the error itself is the answer (run once, out of raid, expect at most one
-- error line) — that tells us whether the fix is "ungate the evaluate path"
-- or "migrate to SetCountdownFormatter breakpoints".
-- ═══════════════════════════════════════════════════════════════════════════
SLASH_ARCTCPROBE1 = "/arctcprobe"
SlashCmdList["ARCTCPROBE"] = function()
  local issecret = issecretvalue
  local P = function(fmt, ...) print("|cff33ff99[ArcTC]|r " .. fmt:format(...)) end
  local GetEnhancedFrames = ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrames
  if not GetEnhancedFrames then P("CDMEnhance not ready.") return end
  local frames = GetEnhancedFrames()
  if not frames then P("no enhanced frames.") return end
  local curve = GetCurveForPreset("classic")
  P("build=%s IS_121=%s", tostring((select(2, GetBuildInfo()))), tostring(ns.API and ns.API.IS_121))
  local tested = 0
  for cdID, data in pairs(frames) do
    local f = data.frame
    if f and f:IsVisible() and f.auraInstanceID ~= nil and tested < 3 then
      tested = tested + 1
      local aidSecret = issecret and issecret(f.auraInstanceID) or false
      local stored = f._arcTextColorDurObj
      P("frame cd=%s aidSecret=%s hookedDurObj=%s", tostring(cdID), tostring(aidSecret), tostring(stored ~= nil))
      if stored and curve then
        -- THE probe: if this line errors, Evaluate is walled for aura durObjs
        -- and the fix must go through SetCountdownFormatter instead.
        local col = stored:EvaluateRemainingDuration(curve)
        P("  Evaluate on hooked durObj -> %s (colorSecret=%s) -- EVALUATE WORKS on this frame",
          tostring(col ~= nil), tostring(col and issecret and issecret(col) or false))
      end
    end
  end
  if tested == 0 then P("no visible AURA frames found -- get a tracked buff up and rerun.") end
  P("run once in the open world AND once in a dungeon/forced-CVar env; paste both outputs.")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AUTO-START — Check if any icon has durationColor enabled
-- Uses GetEnhancedFrames() as the single source of truth for ALL frames.
-- ═══════════════════════════════════════════════════════════════════════════

function ns.CDMTextColor.CheckAndStart()
  -- Fast-exit: already scanned and found no durationColor config anywhere.
  -- Flag is cleared by PLAYER_ENTERING_WORLD so spec/profile changes re-check.
  if _checkedNoConfig then return end

  if not GetIconSettings then
    if ns.CDMEnhance and ns.CDMEnhance.GetIconSettings then
      GetIconSettings = ns.CDMEnhance.GetIconSettings
    else
      return
    end
  end

  local GetEnhancedFrames = ns.CDMEnhance and ns.CDMEnhance.GetEnhancedFrames
  if not GetEnhancedFrames then return end

  local frames = GetEnhancedFrames()
  if not frames then return end

  -- If no frames enhanced yet, CDMEnhance hasn't scanned — don't conclude "nothing to do"
  local frameCount = 0
  for _ in pairs(frames) do frameCount = frameCount + 1 break end
  if frameCount == 0 then return end

  for cdID in pairs(frames) do
    local cfg = GetIconSettings(cdID)
    if cfg and cfg.cooldownText and cfg.cooldownText.durationColor then
      ns.CDMTextColor.Start()
      return
    end
  end
  -- Scanned everything — no durationColor config found. Stop scanning until world reload.
  _checkedNoConfig = true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENT REGISTRATION
-- ═══════════════════════════════════════════════════════════════════════════

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:SetScript("OnEvent", function(self, event, unit)
  -- UNIT_AURA fires frequently — only care about player
  if event == "UNIT_AURA" and unit ~= "player" then return end
  -- SPELL_UPDATE_CHARGES: a charge was gained — clear stored durObj on all active frames
  -- so the next tick re-feeds the new charge recharge timer (old obj has remaining=0)
  if event == "SPELL_UPDATE_CHARGES" then
    for frame in pairs(activeFrames) do
      frame._arcTextColorDurObj = nil
    end
    return
  end
  -- If ticker already running, nothing to do
  if ticker then return end
  -- Reset "found no config" flag on zone entry so new specs/profiles re-check
  if event == "PLAYER_ENTERING_WORLD" then _checkedNoConfig = false end
  C_Timer.After(0.3, function()
    if not GetIconSettings and ns.CDMEnhance and ns.CDMEnhance.GetIconSettings then
      GetIconSettings = ns.CDMEnhance.GetIconSettings
    end
    ns.CDMTextColor.CheckAndStart()
  end)
end)