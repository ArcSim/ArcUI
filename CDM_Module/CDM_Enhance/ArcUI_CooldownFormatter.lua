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

local function ProbeOnce()
  if _probed then return end
  _probed = true
  local probe = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
  _hasMsThreshold     = type(probe.SetCountdownMillisecondsThreshold) == "function"
  _hasAbbrevThreshold = type(probe.SetCountdownAbbrevThreshold) == "function"
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
  
  -- 1. Decimal rendering below threshold (0 = off / no-decimal mode)
  if _hasMsThreshold then
    local threshold = GetDecimalThreshold(cfg)
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
    local abbrev = GetAbbrevThreshold(cfg)
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
end

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF ArcUI_CooldownFormatter.lua
-- ═══════════════════════════════════════════════════════════════════════════