-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_CooldownFormatter.lua
-- Shared helper that applies user-configurable duration-text options to
-- Blizzard's native Cooldown widget. All rendering happens in Blizzard's
-- engine — zero OnUpdate polling, zero per-frame CPU cost in ArcUI.
--
-- Used from CDMEnhance's StyleCooldownText for every CDM frame.
--
-- New in ArcUI 3.6.6 — built on 12.0.5 Cooldown APIs:
--   SetCountdownMillisecondsThreshold  (one-decimal rendering below threshold)
--   SetCountdownAbbrevThreshold        (M:SS / abbreviated form below threshold)
--
-- Both APIs are feature-detected at call time. On pre-12.0.5 clients the
-- helper becomes a no-op and leaves the widget in its default state.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...
ns.CooldownFormatter = ns.CooldownFormatter or {}
local CF = ns.CooldownFormatter

-- ───────────────────────────────────────────────────────────────────────────
-- Feature detect once per load
-- ───────────────────────────────────────────────────────────────────────────
local _probed = false
local _hasMsThreshold = false
local _hasAbbrevThreshold = false
local _hasRuleFormatter = false

local function ProbeOnce()
  if _probed then return end
  _probed = true
  local probe = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
  _hasMsThreshold     = type(probe.SetCountdownMillisecondsThreshold) == "function"
  _hasAbbrevThreshold = type(probe.SetCountdownAbbrevThreshold) == "function"
  -- Show Below needs the widget hook AND the breakpoint formatter API AND
  -- the rounding enum. Missing any of the three leaves the feature inert
  -- (no formatter attached, the widget keeps its default rendering) — this
  -- presence probe is what stands in for the pcall we are not allowed to use,
  -- so every field written into a breakpoint below must be one we control.
  _hasRuleFormatter = type(probe.SetCountdownFormatter) == "function"
    and C_StringUtil ~= nil
    and type(C_StringUtil.CreateNumericRuleFormatter) == "function"
    and Enum ~= nil and Enum.NumericRuleFormatRounding ~= nil
    and Enum.NumericRuleFormatRounding.Up ~= nil
    and Enum.NumericRuleFormatRounding.Nearest ~= nil
  probe:Hide()
  probe:SetParent(nil)
end

-- True if the core millisecond-threshold API is available.
function CF.IsSupported()
  ProbeOnce()
  return _hasMsThreshold
end

-- ───────────────────────────────────────────────────────────────────────────
-- abbrevThreshold semantics (3.6.6):
--   0 / nil / negative : off — leave Blizzard's default behavior alone
--                        (we cache and restore the engine default per widget)
--   positive number    : seconds below which the engine renders M:SS form
-- ───────────────────────────────────────────────────────────────────────────

local function GetDecimalThreshold(cfg)
  local decimals = cfg and cfg.decimals or 0
  if decimals ~= 1 then return 0 end                      -- 0 decimals or off → no ms rendering
  local v = cfg and cfg.decimalThreshold
  -- 0 / nil / negative → user wants the decimal everywhere → use a very high
  -- threshold so the engine renders the decimal across the entire countdown.
  if type(v) ~= "number" or v <= 0 then return 99999 end
  return v
end

local function GetAbbrevThreshold(cfg)
  local v = cfg and cfg.abbrevThreshold
  -- Migration from pre-final 3.6.6 string values ("default" / "1m" / "5m" / "1h").
  -- Translates legacy DB entries on the fly without needing a DB schema bump.
  if type(v) == "string" then
    if v == "1m" then return 60
    elseif v == "5m" then return 300
    elseif v == "1h" then return 3600
    else return nil end                                   -- "default" or anything unrecognized → off
  end
  if type(v) ~= "number" or v <= 0 then return nil end    -- off — caller restores engine default
  return v
end

-- ───────────────────────────────────────────────────────────────────────────
-- SHOW BELOW (3.8.11) — keep the countdown hidden until the cooldown drops
-- under N seconds, then show the ordinary number ("the ability is 5s away").
--
-- Rendered by a NumericRuleFormatter attached with SetCountdownFormatter, so
-- the ENGINE picks the breakpoint and formats the number: no OnUpdate, no
-- ticker, no per-tick Lua, and remaining time never reaches us — which is why
-- this works in M+ where the duration is SECRET. Breakpoint semantics: the
-- highest threshold <= the remaining value wins (same rule DurationText's
-- colour bands rely on).
--
-- A set formatter owns ALL countdown rendering, so it re-states the icon's
-- own Decimals option inside the visible band. Above the threshold it renders
-- a single space (an empty format is the one thing the presence probe could
-- not vouch for), so no M:SS ladder is needed: the cap sits below the minute
-- band. While it owns the widget, CF.Apply neutralises the two threshold APIs
-- below rather than letting two owners format one widget. Formatters are
-- immutable per config and shared: one instance per distinct
-- (seconds, decimals) tuple.
-- ───────────────────────────────────────────────────────────────────────────

-- The M:SS band starts just above 59, so the visible band can't reach it.
local MAX_THRESHOLD = 59

local _fmtCache = {}
local _fmtCount = 0

-- Resolve the Show Below config, or nil when the feature is off for this icon.
-- Returns seconds, decTo (0 = no decimals, else decimals below decTo seconds).
local function GetShowBelowConfig(cfg)
  if not cfg then return nil end
  local seconds = tonumber(cfg.showBelowSeconds) or 0
  if seconds <= 0 then return nil end
  if seconds > MAX_THRESHOLD then seconds = MAX_THRESHOLD end
  -- Honour the icon's own Decimals option wherever it actually covers a
  -- segment (0 = off, 99999 = the user asked for decimals everywhere).
  local decTo = 0
  if (cfg.decimals or 0) == 1 then
    local v = cfg.decimalThreshold
    decTo = (type(v) == "number" and v > 0) and v or 99999
  end
  return seconds, decTo
end

-- One breakpoint rendering the plain number.
local function AddNumberBreakpoint(bps, threshold, useDecimal)
  local bp = { threshold = threshold }
  if useDecimal then
    bp.format   = "%.1f"
    bp.rounding = Enum.NumericRuleFormatRounding.Nearest
  else
    bp.format   = "%d"
    bp.rounding = Enum.NumericRuleFormatRounding.Up
    bp.step     = 1
  end
  bps[#bps + 1] = bp
end

local function BuildShowBelowFormatter(seconds, decTo)
  local bps = {}

  -- [0, seconds) — the visible countdown, decimals where the icon asks for them.
  if decTo >= seconds then
    AddNumberBreakpoint(bps, 0, true)
  elseif decTo > 0 then
    AddNumberBreakpoint(bps, 0, true)
    AddNumberBreakpoint(bps, decTo, false)
  else
    AddNumberBreakpoint(bps, 0, false)
  end

  -- [seconds, ∞) — hidden. A space keeps the FontString honest and empty.
  bps[#bps + 1] = { threshold = seconds, format = " ",
                    rounding = Enum.NumericRuleFormatRounding.Up, step = 1 }

  local f = C_StringUtil.CreateNumericRuleFormatter()
  if not f then return nil end
  f:SetBreakpoints(bps)
  return f
end

-- Attach or clear the resolved formatter. Returns true while it OWNS the
-- widget's formatting. Only ever touches a widget whose state it changed.
local function ApplyShowBelowFormatter(cooldown, cfg)
  if not _hasRuleFormatter then return false end
  local seconds, decTo = GetShowBelowConfig(cfg)
  if not seconds then
    if cooldown._arcThresholdSig then
      cooldown._arcThresholdSig = nil
      cooldown:SetCountdownFormatter(nil)
    end
    return false
  end
  local sig = string.format("%g|%g", seconds, decTo)
  local f = _fmtCache[sig]
  if not f then
    -- Typing in the input mints a config per keystroke, so bound the cache.
    -- Attached widgets keep their own instance alive; evicted configs rebuild.
    if _fmtCount > 32 then _fmtCache = {}; _fmtCount = 0 end
    f = BuildShowBelowFormatter(seconds, decTo)
    if not f then return false end
    _fmtCache[sig] = f
    _fmtCount = _fmtCount + 1
  end
  if cooldown._arcThresholdSig ~= sig then
    cooldown._arcThresholdSig = sig
    cooldown:SetCountdownFormatter(f)
  end
  return true
end

-- ───────────────────────────────────────────────────────────────────────────
-- Apply — main entry point
-- Applies configured options to a Cooldown widget. Safe to call on any frame —
-- missing APIs are silently skipped. Safe to call repeatedly.
--   cooldown : the Blizzard Cooldown widget (eg. frame.Cooldown)
--   cfg      : the cooldownText config table (may be nil → defaults applied)
-- ───────────────────────────────────────────────────────────────────────────
function CF.Apply(cooldown, cfg)
  if not cooldown then return end
  ProbeOnce()
  cfg = cfg or {}

  -- 0. Show Below. When this owns the widget it has already baked the
  -- decimals into its breakpoints (and hides everything past the cap), so
  -- the two threshold APIs below are driven back to neutral: one owner,
  -- never two. Switching the option off restores them on the next pass.
  local thresholdOwns = ApplyShowBelowFormatter(cooldown, cfg)

  -- 1. Decimal rendering below threshold (0 = off / no-decimal mode)
  if _hasMsThreshold then
    local threshold = thresholdOwns and 0 or GetDecimalThreshold(cfg)
    cooldown:SetCountdownMillisecondsThreshold(threshold)
  end
  
  -- 2. Abbreviation threshold.
  -- nil → user wants engine default. Cache the original value once per widget so
  -- toggling the option off can revert to vanilla behavior, instead of leaving
  -- the last-set value stuck on the widget forever (the original 3.6.6 bug).
  if _hasAbbrevThreshold then
    if cooldown._arcDefaultAbbrev == nil and cooldown.GetCountdownAbbrevThreshold then
      cooldown._arcDefaultAbbrev = cooldown:GetCountdownAbbrevThreshold() or 0
    end
    local abbrev = (not thresholdOwns) and GetAbbrevThreshold(cfg) or nil
    if abbrev ~= nil then
      cooldown:SetCountdownAbbrevThreshold(abbrev)
    elseif cooldown._arcDefaultAbbrev ~= nil then
      cooldown:SetCountdownAbbrevThreshold(cooldown._arcDefaultAbbrev)
    end
  end
end

-- Restore Cooldown widget formatter options to their engine defaults.
function CF.Reset(cooldown)
  if not cooldown then return end
  ProbeOnce()
  if _hasMsThreshold then cooldown:SetCountdownMillisecondsThreshold(0) end
  if _hasRuleFormatter and cooldown._arcThresholdSig then
    cooldown._arcThresholdSig = nil
    cooldown:SetCountdownFormatter(nil)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF ArcUI_CooldownFormatter.lua
-- ═══════════════════════════════════════════════════════════════════════════