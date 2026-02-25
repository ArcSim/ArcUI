-- ===================================================================
-- ArcUI_Resources.lua
-- Primary AND Secondary Resource tracking with threshold color layers
-- Uses multi-bar overlay technique for secret-value-safe color changes
-- v2.6.0: Added secondary resource support (Combo Points, Runes, etc.)
-- ===================================================================

local ADDON, ns = ...
ns.Resources = ns.Resources or {}

-- Track if delete buttons should be visible (set when options panel opens)
local deleteButtonsVisible = false

-- Forward declaration for delete confirmation (defined later in file)
local ShowResourceDeleteConfirmation

-- ===================================================================
-- SPELL PREDICTION SYSTEM
-- Tracks pending spell costs/gains for resource bar overlays
-- Non-secret: C_Spell.GetSpellPowerCost + UNIT_SPELLCAST events
-- ===================================================================
local Prediction = {
  active = false,
  spellID = nil,
  cost = 0,        -- Normalized cost (e.g. 2.0 shards)
  gain = 0,        -- Predicted gain amount
  powerType = nil,  -- Which power type this prediction is for
}
ns.Resources._prediction = Prediction

-- Warlock generative spells: spells that CREATE soul shards
-- GetSpellPowerCost only reports costs, not gains — these must be hardcoded
-- Format: [spellID] = { gain = N } or [spellID] = { gain = N, talent = spellID }
-- talent = required talent spellID (checked via IsPlayerSpell)
local WARLOCK_SHARD_GENERATORS = {
  -- Destruction generators
  [434506] = { gain = 2, gainNoChaosBolt = 3 },  -- Incinerate: 2 shards (3 if no Chaos Bolt known)
  [6353]   = { gain = 1 },                        -- Soul Fire: 1 shard
  -- Demonology generators
  [264178] = { gain = 2 },                        -- Demonbolt: 2 shards
  [686]    = { gain = 1, talent = 426115 },        -- Shadow Bolt: 1 shard (requires Fel Invocation)
  -- Cross-spec generators (talent-gated)
  [386997] = { gain = 3, talent = 449638 },        -- Soul Rot: 3 shards (requires Shared Suffering hero talent)
  [265187] = { gain = 3, talent = 449638 },        -- Summon Demonic Tyrant: 3 shards (requires Shared Suffering)
}

-- Cache: rebuild on spec/talent change
local cachedGenerators = nil

local function RebuildGeneratorCache()
  cachedGenerators = {}
  local _, playerClass = UnitClass("player")
  if playerClass ~= "WARLOCK" then return end
  
  local hasChaos = IsSpellKnown(116858)  -- Chaos Bolt (Destruction)
  
  for spellID, info in pairs(WARLOCK_SHARD_GENERATORS) do
    -- Check talent requirement
    if info.talent then
      if not IsPlayerSpell(info.talent) then
        -- Talent not learned, skip this generator
      else
        cachedGenerators[spellID] = info.gain
      end
    else
      -- No talent requirement
      if info.gainNoChaosBolt and not hasChaos then
        cachedGenerators[spellID] = info.gainNoChaosBolt
      else
        cachedGenerators[spellID] = info.gain
      end
    end
  end
end

function Prediction:StartCast(spellID)
  if not spellID then return end
  
  -- Rebuild generator cache if needed
  if not cachedGenerators then
    RebuildGeneratorCache()
  end
  
  local SOUL_SHARD_TYPE = Enum and Enum.PowerType and Enum.PowerType.SoulShards or 7
  
  -- Check for shard GENERATION first (not in cost API)
  local generatedShards = cachedGenerators[spellID]
  if generatedShards and generatedShards > 0 then
    self.active = true
    self.spellID = spellID
    self.cost = 0
    self.gain = generatedShards
    self.powerType = SOUL_SHARD_TYPE
    return
  end
  
  -- Check soul shard cost via API
  local costInfo = C_Spell.GetSpellPowerCost(spellID)
  if not costInfo then
    self:Clear()
    return
  end
  
  local shardCost = 0
  for _, entry in ipairs(costInfo) do
    if entry.type == SOUL_SHARD_TYPE then
      shardCost = entry.cost or 0
      break
    end
  end
  
  if shardCost <= 0 then
    self:Clear()
    return
  end
  
  -- Safety: if cost > 5 (soul shards max), API might return tenths — normalize
  if shardCost > 5 then
    shardCost = shardCost / 10
  end
  
  self.active = true
  self.spellID = spellID
  self.cost = shardCost
  self.gain = 0
  self.powerType = SOUL_SHARD_TYPE
end

function Prediction:Clear()
  self.active = false
  self.spellID = nil
  self.cost = 0
  self.gain = 0
  self.powerType = nil
end

-- Invalidate generator cache on spec/talent change
function Prediction:InvalidateCache()
  cachedGenerators = nil
end

-- Get prediction info for a specific segment index given current value
-- Returns: "cost", "gain", or nil (no prediction for this segment)
function Prediction:GetSegmentState(segIndex, currentValue)
  if not self.active then return nil end
  
  if self.cost > 0 then
    -- Cost prediction: segments that will be consumed
    local afterCost = currentValue - self.cost
    -- Segment is currently filled but will be empty/partial after cast
    if currentValue >= segIndex and afterCost < segIndex then
      return "cost"
    end
    -- Partially filled segment that will be further consumed
    if currentValue > (segIndex - 1) and currentValue < segIndex and afterCost < (segIndex - 1) then
      return "cost"
    end
  end
  
  if self.gain > 0 then
    -- Gain prediction: segments that will be filled
    local afterGain = math.min(currentValue + self.gain, 5)  -- Cap at 5 shards
    -- Currently empty segment that will have value after gain
    if currentValue < segIndex and afterGain >= segIndex then
      return "gain"
    end
    -- Partial fill: segment currently empty but will get partial fill
    if currentValue < segIndex and afterGain > (segIndex - 1) and afterGain < segIndex then
      return "gain"
    end
  end
  
  return nil
end

-- ===================================================================
-- HELPER: CHECK IF OPTIONS PANEL IS OPEN
-- Used to show bars hidden by talent conditions when editing
-- ===================================================================
local function IsOptionsOpen()
  -- Check namespace flag first (set explicitly by Options.lua)
  if ns._arcUIOptionsOpen then
    return true
  end
  -- Fallback: Check AceConfigDialog directly
  local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
  if AceConfigDialog and AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["ArcUI"] then
    return true
  end
  return false
end

-- ===================================================================
-- HELPER: CHECK TALENT CONDITIONS
-- Returns true if conditions are met (or no conditions set)
-- ===================================================================
local function AreTalentConditionsMet(cfg)
  if not cfg or not cfg.behavior then return true end
  if not cfg.behavior.talentConditions or #cfg.behavior.talentConditions == 0 then return true end
  
  if ns.TalentPicker and ns.TalentPicker.CheckTalentConditions then
    local matchMode = cfg.behavior.talentMatchMode or "all"
    return ns.TalentPicker.CheckTalentConditions(cfg.behavior.talentConditions, matchMode)
  end
  
  return true
end

-- ===================================================================
-- HELPER: APPLY SMOOTHING TO STATUSBAR
-- WoW 12.0 native StatusBar:SetValue(value, interpolation) provides
-- engine-level C++ interpolation — much smoother than Lua-based mixins.
-- Store the interpolation enum on the bar for use in SetValue calls.
-- ===================================================================
local INTERP_SMOOTH = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut
local INTERP_NONE = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.None

local function ApplyBarSmoothing(bar, enableSmooth)
  if not bar then return end
  -- Disable old Lua-based mixin smoothing if present (conflicts with native)
  if bar.SetSmoothing then
    bar:SetSmoothing(false)
  end
  -- Store interpolation enum for SetValue calls
  if enableSmooth and INTERP_SMOOTH then
    bar._arcInterpolation = INTERP_SMOOTH
  else
    bar._arcInterpolation = INTERP_NONE
  end
end

-- ===================================================================
-- HELPER: GET ORIENTATION FROM CONFIG
-- Config uses lowercase "horizontal"/"vertical", WoW API uses uppercase
-- ===================================================================
local function GetBarOrientation(cfg)
  local orient = cfg and cfg.display and cfg.display.barOrientation or "horizontal"
  if orient == "vertical" then
    return "VERTICAL"
  end
  return "HORIZONTAL"
end

local function GetBarReverseFill(cfg)
  return cfg and cfg.display and cfg.display.barReverseFill or false
end

-- ===================================================================
-- HELPER: CONFIGURE STATUSBAR FOR CRISP RENDERING
-- Prevents pixel snapping artifacts
-- ===================================================================
local function ConfigureStatusBar(bar)
  if not bar then return end
  -- Note: SetRotatesTexture is set later when orientation is known
  local tex = bar:GetStatusBarTexture()
  if tex then
    tex:SetSnapToPixelGrid(false)
    tex:SetTexelSnappingBias(0)
  end
end

-- ===================================================================
-- POWER TYPE DEFINITIONS (Primary Resources)
-- ===================================================================
ns.Resources.PowerTypes = {
  { id = 0,  name = "Mana",         token = "MANA",         color = {r=0, g=0.5, b=1} },
  { id = 1,  name = "Rage",         token = "RAGE",         color = {r=1, g=0, b=0} },
  { id = 2,  name = "Focus",        token = "FOCUS",        color = {r=1, g=0.5, b=0.25} },
  { id = 3,  name = "Energy",       token = "ENERGY",       color = {r=1, g=1, b=0} },
  { id = 6,  name = "Runic Power",  token = "RUNIC_POWER",  color = {r=0, g=0.82, b=1} },
  { id = 8,  name = "Astral Power", token = "LUNAR_POWER",  color = {r=0.3, g=0.52, b=0.9} },
  { id = 11, name = "Maelstrom",    token = "MAELSTROM",    color = {r=0, g=0.5, b=1} },
  { id = 13, name = "Insanity",     token = "INSANITY",     color = {r=0.4, g=0, b=0.8} },
  { id = 17, name = "Fury",         token = "FURY",         color = {r=0.78, g=0.26, b=0.99} },
  { id = 18, name = "Pain",         token = "PAIN",         color = {r=1, g=0.61, b=0} },
}

-- ===================================================================
-- SECONDARY RESOURCE TYPE DEFINITIONS
-- These are discrete/segmented resources separate from primary power
-- ===================================================================
ns.Resources.SecondaryTypes = {
  { id = "comboPoints",   name = "Combo Points",   powerType = Enum.PowerType.ComboPoints,   color = {r=1, g=0.96, b=0.41}, maxDefault = 5 },
  { id = "holyPower",     name = "Holy Power",     powerType = Enum.PowerType.HolyPower,     color = {r=0.95, g=0.9, b=0.6}, maxDefault = 5 },
  { id = "chi",           name = "Chi",            powerType = Enum.PowerType.Chi,           color = {r=0.71, g=1, b=0.92}, maxDefault = 5 },
  { id = "runes",         name = "Runes",          powerType = Enum.PowerType.Runes,         color = {r=0.5, g=0.5, b=0.5}, maxDefault = 6 },
  { id = "soulShards",    name = "Soul Shards",    powerType = Enum.PowerType.SoulShards,    color = {r=0.58, g=0.51, b=0.79}, maxDefault = 5 },
  { id = "essence",       name = "Essence",        powerType = Enum.PowerType.Essence,       color = {r=0, g=0.8, b=0.8}, maxDefault = 5 },
  { id = "arcaneCharges", name = "Arcane Charges", powerType = Enum.PowerType.ArcaneCharges, color = {r=0.1, g=0.1, b=0.98}, maxDefault = 4 },
  { id = "stagger",       name = "Stagger",        powerType = nil,                          color = {r=0.52, g=1, b=0.52}, maxDefault = 100 },  -- Special: uses UnitStagger
  { id = "soulFragments", name = "Soul Fragments", powerType = nil,                          color = {r=0.34, g=0.06, b=0.46}, maxDefault = 6 },   -- Special: DH Vengeance (C_Spell.GetSpellCastCount)
  { id = "soulFragmentsDevourer", name = "Soul Fragments (Devourer)", powerType = nil,     color = {r=0.28, g=0.13, b=0.80}, maxDefault = 50 },  -- Special: DH Devourer hero spec (aura-based)
  { id = "maelstromWeapon", name = "Maelstrom Weapon", powerType = nil,                     color = {r=0.0, g=0.5, b=1.0}, maxDefault = 10 },  -- Special: Enhancement Shaman (aura 344179)
}

-- Lookup table for quick access
ns.Resources.SecondaryTypesLookup = {}
for _, st in ipairs(ns.Resources.SecondaryTypes) do
  ns.Resources.SecondaryTypesLookup[st.id] = st
end

-- Secondary resources that show discrete ticks (1 per point)
ns.Resources.TickedSecondaryTypes = {
  comboPoints = true,
  holyPower = true,
  chi = true,
  runes = true,
  soulShards = true,
  essence = true,
  arcaneCharges = true,
  soulFragments = true,
  soulFragmentsDevourer = true,
  maelstromWeapon = true,
}

-- Secondary resources that have independent segments (like runes)
ns.Resources.FragmentedSecondaryTypes = {
  runes = true,
  essence = true,
}

-- ===================================================================
-- FRAME STORAGE (per resource bar)
-- ===================================================================
local resourceFrames = {}  -- [barNumber] = {mainFrame, textFrame, layers = {}}

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPER: Rotate StatusBar Texture for Vertical Bars
-- ===================================================================
-- HELPER: APPLY FILL TEXTURE SCALE
-- ===================================================================
local function ApplyFillTextureScale(statusBar, scale)
  if not statusBar then return end
  scale = scale or 1.0
  
  -- Get the StatusBar texture and apply scaling
  local texture = statusBar:GetStatusBarTexture()
  if texture then
    -- Reset to defaults first
    texture:SetTexCoord(0, 1, 0, 1)
    
    -- For StatusBars, we control tiling through HorizTile
    -- Scale < 1 = more repetitions (tiled), Scale > 1 = stretched
    if scale < 1 then
      -- Tiled mode - texture repeats
      texture:SetHorizTile(true)
      texture:SetVertTile(false)
    else
      -- Stretched mode - texture stretches
      texture:SetHorizTile(false)
      texture:SetVertTile(false)
      -- Adjust tex coords to stretch - smaller right value = more stretch visible
      local right = 1.0 / scale
      texture:SetTexCoord(0, right, 0, 1)
    end
  end
end

-- ===================================================================
-- GET SECONDARY RESOURCE MAX VALUE
-- ===================================================================
function ns.Resources.GetSecondaryMaxValue(secondaryType)
  if not secondaryType then return 5 end
  
  local typeInfo = ns.Resources.SecondaryTypesLookup[secondaryType]
  if not typeInfo then return 5 end
  
  local maxDefault = typeInfo.maxDefault or 5
  
  -- Special cases with known fixed max values
  if secondaryType == "stagger" then
    return UnitHealthMax("player") or 100
  elseif secondaryType == "soulFragments" then
    return 6
  elseif secondaryType == "soulFragmentsDevourer" then
    local hasSoulGlutton = C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(1247534)
    return hasSoulGlutton and 35 or 50
  elseif secondaryType == "maelstromWeapon" then
    return 10
  elseif secondaryType == "soulShards" then
    -- All Warlock specs: 5 shards visually
    -- Destruction uses fractional fill per shard, but segment count is still 5
    return 5
  elseif typeInfo.powerType then
    -- Use maxDefault as floor: UnitPowerMax can return partial values at login
    local max = UnitPowerMax("player", typeInfo.powerType) or maxDefault
    return math.max(max, maxDefault)
  end
  
  return maxDefault
end

-- ===================================================================
-- GET SECONDARY RESOURCE VALUE
-- Returns: maxValue, currentValue, displayValue, displayFormat
-- displayFormat: "number" (integer), "decimal" (fractional), "custom"
-- ===================================================================
function ns.Resources.GetSecondaryResourceValue(secondaryType)
  if not secondaryType then return nil, nil, nil, nil end
  
  local typeInfo = ns.Resources.SecondaryTypesLookup[secondaryType]
  if not typeInfo then return nil, nil, nil, nil end
  
  -- ═══════════════════════════════════════════════════════════════
  -- STAGGER (Brewmaster Monk)
  -- Uses UnitStagger, max is player's max health
  -- ═══════════════════════════════════════════════════════════════
  if secondaryType == "stagger" then
    local stagger = UnitStagger("player") or 0
    local maxHealth = UnitHealthMax("player") or 1
    return maxHealth, stagger, stagger, "number"
  end
  
  -- ═══════════════════════════════════════════════════════════════
  -- SOUL FRAGMENTS (Vengeance Demon Hunter)
  -- Uses C_Spell.GetSpellCastCount on Soul Cleave (228477)
  -- ═══════════════════════════════════════════════════════════════
  if secondaryType == "soulFragments" then
    local current = C_Spell and C_Spell.GetSpellCastCount and C_Spell.GetSpellCastCount(228477) or 0
    local max = 6
    return max, current, current, "number"
  end
  
  -- ═══════════════════════════════════════════════════════════════
  -- SOUL FRAGMENTS - DEVOURER (DH Devourer Hero Spec)
  -- Tracks aura stacks: Soul Fragments (1225789) or Collapsing Star (1227702)
  -- Max depends on Soul Glutton talent (1247534): 35 with, 50 without
  -- ═══════════════════════════════════════════════════════════════
  if secondaryType == "soulFragmentsDevourer" then
    local auraData = C_UnitAuras and (C_UnitAuras.GetPlayerAuraBySpellID(1225789) or C_UnitAuras.GetPlayerAuraBySpellID(1227702))
    local current = auraData and auraData.applications or 0
    local hasSoulGlutton = C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(1247534)
    local max = hasSoulGlutton and 35 or 50
    return max, current, current, "number"
  end
  
  -- ═══════════════════════════════════════════════════════════════
  -- MAELSTROM WEAPON (Enhancement Shaman)
  -- Tracks aura stacks via C_UnitAuras (spellID 344179)
  -- ═══════════════════════════════════════════════════════════════
  if secondaryType == "maelstromWeapon" then
    local auraData = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID(344179)
    local current = auraData and auraData.applications or 0
    local max = 10
    return max, current, current, "number"
  end
  
  -- ═══════════════════════════════════════════════════════════════
  -- RUNES (Death Knight)
  -- Count ready runes via GetRuneCooldown
  -- ═══════════════════════════════════════════════════════════════
  if secondaryType == "runes" then
    local max = UnitPowerMax("player", Enum.PowerType.Runes) or 6
    if max < 6 then max = 6 end  -- Floor: always at least 6 runes
    
    local readyRunes = 0
    for i = 1, max do
      local _, _, runeReady = GetRuneCooldown(i)
      if runeReady then
        readyRunes = readyRunes + 1
      end
    end
    
    return max, readyRunes, readyRunes, "number"
  end
  
  -- ═══════════════════════════════════════════════════════════════
  -- SOUL SHARDS (Warlock)
  -- All specs: max=5, segments=5
  -- Destruction: fractional current (e.g. 3.5 shards), decimal display
  -- Affliction/Demonology: whole shards only
  -- ═══════════════════════════════════════════════════════════════
  if secondaryType == "soulShards" then
    local spec = GetSpecialization()
    local specID = spec and GetSpecializationInfo(spec)
    
    if specID == 267 then  -- Destruction
      local currentFractional = UnitPower("player", Enum.PowerType.SoulShards, true)  -- e.g. 35 for 3.5 shards
      local shardValue = (currentFractional or 0) / 10  -- Normalize: 35 → 3.5
      return 5, shardValue, shardValue, "decimal"
    end
    
    -- Affliction/Demonology: whole shards
    local current = UnitPower("player", Enum.PowerType.SoulShards)
    return 5, current, current, "number"
  end
  
  -- ═══════════════════════════════════════════════════════════════
  -- REGULAR SECONDARY RESOURCES
  -- ComboPoints, HolyPower, Chi, Essence, ArcaneCharges
  -- ═══════════════════════════════════════════════════════════════
  if typeInfo.powerType then
    local current = UnitPower("player", typeInfo.powerType)
    local max = UnitPowerMax("player", typeInfo.powerType)
    local maxDefault = typeInfo.maxDefault or 5
    
    -- Floor: UnitPowerMax can return partial values at login
    if not max or max < maxDefault then max = maxDefault end
    
    return max, current, current, "number"
  end
  
  return nil, nil, nil, nil
end

-- ===================================================================
-- GET SECONDARY RESOURCE COLOR
-- ===================================================================
function ns.Resources.GetSecondaryResourceColor(secondaryType)
  if not secondaryType then return {r=1, g=1, b=1} end
  
  local typeInfo = ns.Resources.SecondaryTypesLookup[secondaryType]
  if typeInfo and typeInfo.color then
    return typeInfo.color
  end
  
  return {r=1, g=1, b=1}
end

-- Default color for Animacharged (Echoing Reprimand) combo points
ns.Resources.ChargedComboPointColor = {r=0.169, g=0.733, b=0.992, a=1}

-- Helper: Build a lookup table of charged (Animacharged) combo point indices
-- Returns: table where chargedLookup[index] = true for charged points, or empty table
function ns.Resources.GetChargedComboPointLookup()
  local lookup = {}
  local charged = GetUnitChargedPowerPoints and GetUnitChargedPowerPoints("player")
  if charged then
    for _, index in ipairs(charged) do
      lookup[index] = true
    end
  end
  return lookup
end

-- ===================================================================
-- GET RUNE COOLDOWN DETAILS (Per-rune cooldown data)
-- Returns: table of { start, duration, ready, fillPercent } for each rune
-- ===================================================================
function ns.Resources.GetRuneCooldownDetails()
  local max = UnitPowerMax("player", Enum.PowerType.Runes) or 6
  if max <= 0 then return nil end
  
  local runeData = {}
  local now = GetTime()
  
  for i = 1, max do
    local start, duration, runeReady = GetRuneCooldown(i)
    
    local fillPercent = 1  -- Default to full
    if not runeReady and start and duration and duration > 0 then
      -- Calculate progress
      local elapsed = now - start
      fillPercent = math.min(1, math.max(0, elapsed / duration))
    end
    
    runeData[i] = {
      runeIndex = i,       -- Preserve original game rune index
      start = start or 0,
      duration = duration or 0,
      ready = runeReady,
      fillPercent = fillPercent
    }
  end
  
  -- Sort: ready runes first (leftmost), then charging runes by progress
  -- descending (most progressed / closest to ready displayed next)
  table.sort(runeData, function(a, b)
    if a.ready ~= b.ready then
      return a.ready  -- ready (true) sorts before charging (false)
    end
    if not a.ready then
      -- Both charging: higher fillPercent (closer to ready) comes first
      return a.fillPercent > b.fillPercent
    end
    -- Both ready: maintain stable order by original rune index
    return a.runeIndex < b.runeIndex
  end)
  
  return runeData, max
end

-- ===================================================================
-- GET ESSENCE COOLDOWN DETAILS (Per-essence charge data for Evoker)
-- Returns: table of { ready, fillPercent, start, duration } for each essence
-- Uses GetPowerRegenForPowerType to predict next essence tick
-- Tracks _essenceNextTick / _essenceLastCount across frames for smooth fill
-- Reuses cached tables to avoid per-frame allocations
-- ===================================================================
local _essenceNextTick = nil
local _essenceLastCount = nil
local _essenceDataCache = {}
local _essenceCacheMax = 0

function ns.Resources.GetEssenceCooldownDetails()
  local max = UnitPowerMax("player", Enum.PowerType.Essence) or 5
  if max <= 0 then return nil end
  
  local current = UnitPower("player", Enum.PowerType.Essence)
  local now = GetTime()
  
  -- Calculate tick duration from regen rate
  local regenRate = GetPowerRegenForPowerType(Enum.PowerType.Essence) or 0.2
  local tickDuration = (regenRate > 0) and (1 / regenRate) or 5
  
  -- Initialize tracking state
  if _essenceLastCount == nil then _essenceLastCount = current end
  
  -- If we gained an essence, reset timer for next one
  if current > _essenceLastCount then
    _essenceNextTick = (current < max) and (now + tickDuration) or nil
  end
  
  -- If missing essence and no timer running, start one
  if current < max and not _essenceNextTick then
    _essenceNextTick = now + tickDuration
  end
  
  -- If full, clear timer
  if current >= max then
    _essenceNextTick = nil
  end
  
  _essenceLastCount = current
  
  -- Ensure cache has enough entries (only allocate on max change)
  if max ~= _essenceCacheMax then
    for i = 1, max do
      if not _essenceDataCache[i] then
        _essenceDataCache[i] = { ready = false, fillPercent = 0, start = 0, duration = 0 }
      end
    end
    _essenceCacheMax = max
  end
  
  -- Update cached entries in-place (zero allocations per frame)
  for i = 1, max do
    local entry = _essenceDataCache[i]
    if i <= current then
      entry.ready = true
      entry.fillPercent = 1
      entry.start = 0
      entry.duration = 0
    elseif i == current + 1 and _essenceNextTick then
      local remaining = _essenceNextTick - now
      if remaining < 0 then remaining = 0 end
      entry.ready = false
      entry.fillPercent = 1 - (remaining / tickDuration)
      if entry.fillPercent < 0 then entry.fillPercent = 0 end
      if entry.fillPercent > 1 then entry.fillPercent = 1 end
      entry.start = _essenceNextTick - tickDuration
      entry.duration = tickDuration
    else
      entry.ready = false
      entry.fillPercent = 0
      entry.start = 0
      entry.duration = 0
    end
  end
  
  return _essenceDataCache, max
end

-- ===================================================================
-- DETECT AVAILABLE SECONDARY RESOURCE FOR CURRENT CLASS/SPEC
-- Returns: secondaryType string or nil
-- ===================================================================
function ns.Resources.DetectSecondaryResource()
  local _, playerClass = UnitClass("player")
  local spec = GetSpecialization()
  local specID = spec and GetSpecializationInfo(spec)
  
  local classResources = {
    ["DEATHKNIGHT"] = "runes",
    ["DRUID"] = "comboPoints",
    ["EVOKER"] = "essence",
    ["PALADIN"] = "holyPower",
    ["ROGUE"] = "comboPoints",
    ["WARLOCK"] = "soulShards",
  }
  
  -- Spec-specific resources
  local specResources = {
    -- Demon Hunter
    [577] = nil,           -- Havoc - no secondary shown here
    [581] = "soulFragments", -- Vengeance (Soul Cleave cast count)
    [1480] = "soulFragmentsDevourer", -- Devourer hero spec (aura-based)
    
    -- Druid
    [102] = nil,           -- Balance
    [103] = "comboPoints", -- Feral
    [104] = nil,           -- Guardian
    [105] = nil,           -- Restoration
    
    -- Mage
    [62] = "arcaneCharges", -- Arcane
    [63] = nil,            -- Fire
    [64] = nil,            -- Frost
    
    -- Monk
    [268] = "stagger",     -- Brewmaster
    [270] = nil,           -- Mistweaver
    [269] = "chi",         -- Windwalker
    
    -- Shaman
    [262] = nil,           -- Elemental
    [263] = "maelstromWeapon", -- Enhancement
    [264] = nil,           -- Restoration
  }
  
  -- Check spec-specific first
  if specID and specResources[specID] then
    return specResources[specID]
  end
  
  -- Fall back to class-wide
  return classResources[playerClass]
end

-- ===================================================================
-- GET SPEC-APPROPRIATE DEFAULT COLOR for Secondary Resources
-- Returns a color table based on current class/spec, or a generic fallback
-- ===================================================================
function ns.Resources.GetSecondaryResourceDefaultColor()
  local _, playerClass = UnitClass("player")
  local spec = GetSpecialization()
  local specID = spec and GetSpecializationInfo(spec)
  
  -- DK spec colors for Runes
  if playerClass == "DEATHKNIGHT" then
    if specID == 250 then      -- Blood
      return {r=0.77, g=0.12, b=0.23, a=1}  -- Red
    elseif specID == 251 then  -- Frost
      return {r=0.25, g=0.58, b=0.90, a=1}  -- Blue
    elseif specID == 252 then  -- Unholy
      return {r=0.33, g=0.80, b=0.25, a=1}  -- Green
    end
    -- Spec not loaded yet: neutral rune gray (will update on next render when spec loads)
    return {r=0.5, g=0.5, b=0.5, a=1}
  end
  
  -- Evoker: light emerald for Essence
  if playerClass == "EVOKER" then
    return {r=0.40, g=0.85, b=0.55, a=1}  -- Light emerald
  end
  
  -- Generic fallback
  return {r=0.5, g=0.5, b=0.5, a=1}
end

-- ===================================================================
-- COLORCURVE SYSTEM FOR RESOURCE BARS
-- Uses WoW 12.0's ColorCurve API for secret-value-safe color thresholds
-- Much simpler than the multi-stacked bar approach!
-- ===================================================================

-- Cache for max power values (needed for numeric threshold mode)
local cachedMaxPower = {}  -- [powerType] = maxValue

-- Cache for ColorCurves
local resourceColorCurves = {}  -- [barNumber] = { curve, settingsHash }
local resourceMaxColorCurves = {}  -- [barNumber] = { curve, hash }

-- Default threshold colors
local RESOURCE_THRESHOLD_DEFAULT_COLORS = {
  [2] = {r = 1, g = 1, b = 0, a = 1},     -- Yellow
  [3] = {r = 1, g = 0.5, b = 0, a = 1},   -- Orange
  [4] = {r = 1, g = 0, b = 0, a = 1},     -- Red
  [5] = {r = 0.5, g = 0, b = 0.5, a = 1}, -- Purple
}

local RESOURCE_THRESHOLD_DEFAULT_VALUES = {
  [2] = 75,  -- 75%
  [3] = 50,  -- 50%
  [4] = 25,  -- 25%
  [5] = 10,  -- 10%
}

-- Cache max power when non-secret (out of combat)
local function CacheMaxPowerValue(powerType)
  if not powerType or powerType < 0 then return end
  
  local max = UnitPowerMax("player", powerType)
  if not max then return end
  
  -- Check if it's secret
  if issecretvalue and issecretvalue(max) then
    return  -- Can't cache secret value
  end
  
  if max and max > 0 then
    cachedMaxPower[powerType] = max
  end
end

-- Get cached max power (for numeric threshold conversion)
local function GetCachedMaxPower(powerType)
  return cachedMaxPower[powerType]
end

-- Safe color extraction: handles both {r=, g=, b=} tables and indexed {[1]=r, [2]=g, [3]=b} arrays
local function SafeColorRGBA(color, defaultR, defaultG, defaultB, defaultA)
  if not color then return defaultR or 1, defaultG or 1, defaultB or 1, defaultA or 1 end
  local r = color.r or color[1] or defaultR or 1
  local g = color.g or color[2] or defaultG or 1
  local b = color.b or color[3] or defaultB or 1
  local a = color.a or color[4] or defaultA or 1
  return r, g, b, a
end

-- Hash function for cache invalidation
local function GetResourceThresholdHash(cfg, baseColor, powerType)
  local parts = {}
  local bcR, bcG, bcB, bcA = SafeColorRGBA(baseColor, 0, 0.8, 1, 1)
  table.insert(parts, string.format("bc:%.2f,%.2f,%.2f,%.2f", bcR, bcG, bcB, bcA))
  
  for i = 2, 5 do
    local enabled = cfg["colorCurveThreshold" .. i .. "Enabled"]
    local value = cfg["colorCurveThreshold" .. i .. "Value"] or RESOURCE_THRESHOLD_DEFAULT_VALUES[i]
    local color = cfg["colorCurveThreshold" .. i .. "Color"] or RESOURCE_THRESHOLD_DEFAULT_COLORS[i]
    if enabled then
      local cR, cG, cB, cA = SafeColorRGBA(color, 1, 1, 1, 1)
      table.insert(parts, string.format("t%d:%d,%.2f,%.2f,%.2f,%.2f", i, value, cR, cG, cB, cA))
    end
  end
  
  table.insert(parts, cfg.colorCurveThresholdAsPercent and "pct" or "num")
  table.insert(parts, (cfg.colorCurveDirection == "fill" or cfg.colorCurveDirectionFilling) and "fill" or "drain")
  -- Include actual max power for numeric mode so curve rebuilds when talents change max
  local effectiveMax = cfg.colorCurveMaxValue or 100
  if not cfg.colorCurveThresholdAsPercent and powerType then
    local cachedMax = GetCachedMaxPower(powerType)
    if cachedMax and cachedMax > 0 then
      effectiveMax = cachedMax
    end
  end
  table.insert(parts, tostring(effectiveMax))
  -- Include maxColor so curve rebuilds when max color settings change
  if cfg.enableMaxColor then
    local mc = cfg.maxColor or {r=0, g=1, b=0, a=1}
    table.insert(parts, string.format("mc:%.2f,%.2f,%.2f,%.2f", mc.r or 0, mc.g or 1, mc.b or 0, mc.a or 1))
  end
  return table.concat(parts, "|")
end

-- Create or get cached ColorCurve for resource bar
-- NOTE: For resources, thresholds work OPPOSITE to cooldowns:
-- - Cooldowns: low % = urgent (about to be ready)
-- - Resources: low % = urgent (almost empty/out of resource)
local function GetResourceColorCurve(barNumber, barConfig, powerType)
  if not barConfig or not barConfig.display then return nil end
  
  local cfg = barConfig.display
  if not cfg.colorCurveEnabled then return nil end
  
  -- Check if ColorCurve API exists (WoW 12.0+)
  if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then
    return nil
  end
  
  -- Max color integration: when enabled, inject a step at 100% into the curve
  local enableMaxColor = cfg.enableMaxColor
  local maxColor = cfg.maxColor or {r=0, g=1, b=0, a=1}
  
  -- Get base bar color (used above all thresholds - "healthy" color)
  -- Check display.barColor first, then fall back to thresholds[1].color for older configs
  local baseColor = cfg.barColor
  if not baseColor and barConfig.thresholds and barConfig.thresholds[1] then
    baseColor = barConfig.thresholds[1].color
  end
  baseColor = baseColor or {r = 0, g = 0.8, b = 1, a = 1}
  
  -- Check if we need to rebuild the curve
  local currentHash = GetResourceThresholdHash(cfg, baseColor, powerType)
  local cached = resourceColorCurves[barNumber]
  
  if cached and cached.settingsHash == currentHash then
    return cached.curve
  end
  
  -- Build threshold points from UI settings
  local thresholds = {}
  
  for i = 2, 5 do
    local enabled = cfg["colorCurveThreshold" .. i .. "Enabled"]
    local value = cfg["colorCurveThreshold" .. i .. "Value"] or RESOURCE_THRESHOLD_DEFAULT_VALUES[i]
    local color = cfg["colorCurveThreshold" .. i .. "Color"] or RESOURCE_THRESHOLD_DEFAULT_COLORS[i]
    
    if enabled then
      table.insert(thresholds, { value = value, color = color })
    end
  end
  
  -- If no thresholds enabled, return nil (use base color only)
  if #thresholds == 0 then
    resourceColorCurves[barNumber] = nil
    return nil
  end
  
  -- Sort thresholds by value ASCENDING (lowest % first)
  table.sort(thresholds, function(a, b) return a.value < b.value end)
  
  -- Create the ColorCurve
  local curve = C_CurveUtil.CreateColorCurve()
  
  -- Mode settings
  local asPercent = cfg.colorCurveThresholdAsPercent ~= false  -- Default true for resources
  local isFilling = (cfg.colorCurveDirection == "fill") or cfg.colorCurveDirectionFilling
  local maxValue = cfg.colorCurveMaxValue or 100
  
  -- For numeric mode, try to get actual max power
  if not asPercent and powerType then
    local cachedMax = GetCachedMaxPower(powerType)
    if cachedMax and cachedMax > 0 then
      maxValue = cachedMax
    end
  end
  
  local EPSILON = 0.0001
  
  if isFilling then
    -- FILLING MODE: base color at 0%, threshold colors as resource builds up
    -- Example: thresholds = [{50%, Yellow}, {75%, Orange}], base = Blue
    -- 0% to 50%: Blue (base)
    -- 50% to 75%: Yellow
    -- 75% to 100%: Orange
    
    -- Start at 0% with base color
    local bR, bG, bB, bA = SafeColorRGBA(baseColor)
    curve:AddPoint(0.0, CreateColor(bR, bG, bB, bA))
    
    for i = 1, #thresholds do
      local t = thresholds[i]
      local pct
      if asPercent then
        pct = t.value / 100
      else
        pct = t.value / maxValue
      end
      pct = math.max(0, math.min(1, pct))
      
      -- Color before this threshold (base or previous threshold)
      local prevColor
      if i == 1 then
        prevColor = baseColor
      else
        prevColor = thresholds[i - 1].color
      end
      
      -- Add point just before threshold (previous color)
      if pct > EPSILON then
        local pR, pG, pB, pA = SafeColorRGBA(prevColor)
        curve:AddPoint(pct - EPSILON, CreateColor(pR, pG, pB, pA))
      end
      
      -- At threshold: switch to this threshold's color
      local tR, tG, tB, tA = SafeColorRGBA(t.color)
      curve:AddPoint(pct, CreateColor(tR, tG, tB, tA))
    end
    
    -- End at 100% with highest threshold color (or max color if enabled)
    local highestColor = thresholds[#thresholds].color
    if enableMaxColor then
      -- Step: highest threshold color just below max, then max color at exactly 100%
      local hR, hG, hB, hA = SafeColorRGBA(highestColor)
      curve:AddPoint(1.0 - EPSILON, CreateColor(hR, hG, hB, hA))
      local mcR, mcG, mcB, mcA = SafeColorRGBA(maxColor)
      curve:AddPoint(1.0, CreateColor(mcR, mcG, mcB, mcA))
    else
      local hR, hG, hB, hA = SafeColorRGBA(highestColor)
      curve:AddPoint(1.0, CreateColor(hR, hG, hB, hA))
    end
    
  else
    -- DRAINING MODE (default): threshold colors at low %, base color at full
    -- Example: thresholds = [{10%, Red}, {25%, Orange}, {50%, Yellow}], base = Green
    -- 0% to 10%: Red
    -- 10% to 25%: Orange
    -- 25% to 50%: Yellow
    -- 50% to 100%: Green (base)
    
    -- Start at 0% with the lowest (most urgent) threshold color
    local lowestThreshold = thresholds[1]
    local lR, lG, lB, lA = SafeColorRGBA(lowestThreshold.color)
    curve:AddPoint(0.0, CreateColor(lR, lG, lB, lA))
    
    for i = 1, #thresholds do
      local t = thresholds[i]
      local pct
      if asPercent then
        pct = t.value / 100
      else
        pct = t.value / maxValue
      end
      pct = math.max(0, math.min(1, pct))
      
      -- Determine next color (above this threshold)
      local nextColor
      if i == #thresholds then
        nextColor = baseColor
      else
        nextColor = thresholds[i + 1].color
      end
      
      local currentColor = t.color
      
      -- Add point just before threshold (current color)
      if pct > EPSILON then
        local cR, cG, cB, cA = SafeColorRGBA(currentColor)
        curve:AddPoint(pct - EPSILON, CreateColor(cR, cG, cB, cA))
      end
      
      -- Add point at threshold (next color begins)
      local nR, nG, nB, nA = SafeColorRGBA(nextColor)
      curve:AddPoint(pct, CreateColor(nR, nG, nB, nA))
    end
    
    -- End with base color at 100% (or max color step if enabled)
    if enableMaxColor then
      -- Step: base color just below max, then max color at exactly 100%
      local bR, bG, bB, bA = SafeColorRGBA(baseColor)
      curve:AddPoint(1.0 - EPSILON, CreateColor(bR, bG, bB, bA))
      local mcR, mcG, mcB, mcA = SafeColorRGBA(maxColor)
      curve:AddPoint(1.0, CreateColor(mcR, mcG, mcB, mcA))
    else
      local bR, bG, bB, bA = SafeColorRGBA(baseColor)
      curve:AddPoint(1.0, CreateColor(bR, bG, bB, bA))
    end
  end
  
  -- Cache
  resourceColorCurves[barNumber] = { curve = curve, settingsHash = currentHash }
  return curve
end

-- Clear cached curve (called when settings change)
function ns.Resources.ClearResourceColorCurve(barNumber)
  resourceColorCurves[barNumber] = nil
  resourceMaxColorCurves[barNumber] = nil
end

function ns.Resources.ClearAllResourceColorCurves()
  wipe(resourceColorCurves)
  wipe(resourceMaxColorCurves)
end

-- ═══════════════════════════════════════════════════════════════
-- DIRECT THRESHOLD EVALUATOR (for secondary resources)
-- Evaluates colorCurve threshold settings via direct numeric comparison
-- instead of UnitPowerPercent. Works for all secondary resources since
-- Beta 3 made them non-secret values.
-- Returns: resolved color table {r,g,b,a} or nil if no threshold matched
-- ═══════════════════════════════════════════════════════════════
local function EvaluateThresholdsDirectly(barConfig, currentValue, maxValue)
  if not barConfig or not barConfig.display then return nil end
  local cfg = barConfig.display
  if not cfg.colorCurveEnabled then return nil end
  if type(currentValue) ~= "number" then return nil end
  if issecretvalue and issecretvalue(currentValue) then return nil end  -- Can't compare secrets
  if not maxValue or maxValue <= 0 then return nil end
  
  local enableMaxColor = cfg.enableMaxColor
  local maxColor = cfg.maxColor or {r=0, g=1, b=0, a=1}
  
  -- Get base bar color
  local baseColor = cfg.barColor
  if not baseColor and barConfig.thresholds and barConfig.thresholds[1] then
    baseColor = barConfig.thresholds[1].color
  end
  baseColor = baseColor or {r=0, g=0.8, b=1, a=1}
  
  -- Build sorted thresholds from UI settings
  local thresholds = {}
  -- Default: percent mode ON for primary resources (mana/energy have large max values)
  -- but OFF for secondary resources (combo points etc. have small max values like 5-7)
  local asPercent
  if cfg.colorCurveThresholdAsPercent ~= nil then
    asPercent = cfg.colorCurveThresholdAsPercent
  else
    -- Auto-detect: if maxValue is small (<=30), default to raw values
    asPercent = (maxValue > 30)
  end
  
  for i = 2, 5 do
    local enabled = cfg["colorCurveThreshold" .. i .. "Enabled"]
    local value = cfg["colorCurveThreshold" .. i .. "Value"] or RESOURCE_THRESHOLD_DEFAULT_VALUES[i]
    local color = cfg["colorCurveThreshold" .. i .. "Color"] or RESOURCE_THRESHOLD_DEFAULT_COLORS[i]
    
    if enabled then
      -- Convert threshold value to absolute if in percent mode
      local absValue
      if asPercent then
        absValue = (value / 100) * maxValue
      else
        absValue = value
      end
      table.insert(thresholds, { value = absValue, color = color })
    end
  end
  
  -- No thresholds enabled → just handle at-max
  if #thresholds == 0 then
    if enableMaxColor and currentValue >= maxValue then
      return maxColor
    end
    return nil
  end
  
  -- Sort ascending
  table.sort(thresholds, function(a, b) return a.value < b.value end)
  
  local isFilling = (cfg.colorCurveDirection == "fill") or cfg.colorCurveDirectionFilling
  -- Auto-default: secondary resources fill (building up combo points etc.)
  if not cfg.colorCurveDirection and not cfg.colorCurveDirectionFilling then
    local isSecondary = barConfig.tracking and barConfig.tracking.resourceCategory == "secondary"
    if isSecondary then isFilling = true end
  end
  
  -- At-max override
  if enableMaxColor and currentValue >= maxValue then
    return maxColor
  end
  
  if isFilling then
    -- FILLING: base below first threshold, threshold color when value >= threshold
    -- Walk from highest to lowest: first threshold where currentValue >= threshold wins
    for i = #thresholds, 1, -1 do
      if currentValue >= thresholds[i].value then
        return thresholds[i].color
      end
    end
    return baseColor
  else
    -- DRAINING: base at full, threshold colors at low values
    -- Walk from lowest to highest: first threshold where currentValue < threshold wins
    for i = 1, #thresholds do
      if currentValue < thresholds[i].value then
        return thresholds[i].color
      end
    end
    return baseColor
  end
end

-- ═══════════════════════════════════════════════════════════════
-- MAX-COLOR-ONLY CURVE
-- For simple/folded modes that don't use full colorCurve thresholds
-- but still want the max-value color change via secret-safe tinting.
-- Creates a 2-step curve: topColor below max, maxColor at 100%.
-- ═══════════════════════════════════════════════════════════════

local function GetMaxColorOnlyCurve(barNumber, barConfig, topColor, powerType)
  if not barConfig or not barConfig.display then return nil end
  local cfg = barConfig.display
  if not cfg.enableMaxColor then return nil end
  if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end

  local maxColor = cfg.maxColor or {r=0, g=1, b=0, a=1}

  -- Build hash for cache (topColor + maxColor)
  local tR, tG, tB, tA = SafeColorRGBA(topColor)
  local mR, mG, mB, mA = SafeColorRGBA(maxColor)
  local hash = string.format("%.2f,%.2f,%.2f,%.2f|%.2f,%.2f,%.2f,%.2f", tR, tG, tB, tA, mR, mG, mB, mA)

  local cached = resourceMaxColorCurves[barNumber]
  if cached and cached.hash == hash then
    return cached.curve
  end

  local EPSILON = 0.0001
  local curve = C_CurveUtil.CreateColorCurve()
  curve:AddPoint(0.0, CreateColor(tR, tG, tB, tA))
  curve:AddPoint(1.0 - EPSILON, CreateColor(tR, tG, tB, tA))
  curve:AddPoint(1.0, CreateColor(mR, mG, mB, mA))

  resourceMaxColorCurves[barNumber] = { curve = curve, hash = hash }
  return curve
end

-- Cache max power for all common power types (call on PLAYER_ENTERING_WORLD, etc.)
function ns.Resources.CacheAllMaxPowerValues()
  for _, pt in ipairs(ns.Resources.PowerTypes) do
    CacheMaxPowerValue(pt.id)
  end
end

-- ===================================================================
-- CREATE RESOURCE BAR FRAME
-- ===================================================================
local function CreateResourceBarFrame(barNumber)
  local frame = CreateFrame("Frame", "ArcUIResourceFrame" .. barNumber, UIParent)
  frame:SetSize(250, 25)
  frame:SetPoint("CENTER", 0, -100 - ((barNumber - 1) * 35))
  frame:SetMovable(true)
  frame:EnableMouse(false)
  frame:SetClampedToScreen(true)
  
  -- Background
  frame.bg = frame:CreateTexture(nil, "BACKGROUND")
  frame.bg:SetAllPoints()
  frame.bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)
  frame.bg:SetSnapToPixelGrid(false)
  frame.bg:SetTexelSnappingBias(0)
  
  -- Border textures created later on borderOverlay frame
  
  -- Threshold layers container (bars stacked on top of each other)
  -- These create the "color change" illusion with secret values!
  frame.layers = {}
  
  -- Create up to 5 threshold layers (bottom to top)
  for i = 1, 5 do
    local layer = CreateFrame("StatusBar", nil, frame)
    layer:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    layer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    layer:SetMinMaxValues(0, 100)
    layer:SetValue(0)
    layer:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    layer:SetStatusBarColor(1, 1, 1, 1)
    layer:SetFrameLevel(frame:GetFrameLevel() + i)  -- Stack in order
    ConfigureStatusBar(layer)  -- Enable rotation and prevent pixel snapping
    layer:Hide()
    frame.layers[i] = layer
  end
  
  -- Tick marks overlay (must be above all granular bars which go up to +105)
  frame.tickOverlay = CreateFrame("Frame", nil, frame)
  frame.tickOverlay:SetAllPoints(frame)
  frame.tickOverlay:SetFrameLevel(frame:GetFrameLevel() + 150)
  
  -- Prediction overlays for simple/continuous bar mode
  -- Gain bar: sits BEHIND main fill (+5), extends past fill to show incoming shards
  frame.predGainBar = CreateFrame("StatusBar", nil, frame)
  frame.predGainBar:SetAllPoints(frame)
  frame.predGainBar:SetMinMaxValues(0, 5)
  frame.predGainBar:SetValue(0)
  frame.predGainBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  frame.predGainBar:SetFrameLevel(frame:GetFrameLevel() + 5)
  ConfigureStatusBar(frame.predGainBar)
  frame.predGainBar:Hide()
  
  -- Cost overlay: sits ABOVE main fill (+7), covers the "to be consumed" zone
  frame.predCostFrame = CreateFrame("Frame", nil, frame)
  frame.predCostFrame:SetFrameLevel(frame:GetFrameLevel() + 7)
  frame.predCostFrame:Hide()
  frame.predCostTex = frame.predCostFrame:CreateTexture(nil, "OVERLAY")
  frame.predCostTex:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
  frame.predCostTex:SetVertexColor(0, 0, 0, 0.5)
  
  frame.tickMarks = {}
  for i = 1, 100 do
    local tick = frame.tickOverlay:CreateTexture(nil, "OVERLAY")
    tick:SetDrawLayer("OVERLAY", 7)
    tick:SetSnapToPixelGrid(false)
    tick:SetTexelSnappingBias(0)
    tick:SetColorTexture(0, 0, 0, 1)
    tick:Hide()
    frame.tickMarks[i] = tick
  end
  
  -- Border textures (4 separate textures for pixel-perfect borders - no centered edge issues)
  -- This approach gives precise control unlike BackdropTemplate which centers edges
  frame.borderOverlay = CreateFrame("Frame", nil, frame)
  frame.borderOverlay:SetAllPoints(frame)
  frame.borderOverlay:SetFrameLevel(frame:GetFrameLevel() + 151)
  
  frame.borderOverlay.top = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.top:SetSnapToPixelGrid(false)
  frame.borderOverlay.top:SetTexelSnappingBias(0)
  
  frame.borderOverlay.bottom = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.bottom:SetSnapToPixelGrid(false)
  frame.borderOverlay.bottom:SetTexelSnappingBias(0)
  
  frame.borderOverlay.left = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.left:SetSnapToPixelGrid(false)
  frame.borderOverlay.left:SetTexelSnappingBias(0)
  
  frame.borderOverlay.right = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.right:SetSnapToPixelGrid(false)
  frame.borderOverlay.right:SetTexelSnappingBias(0)
  
  -- Drag functionality + right-click to edit
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and not IsShiftKeyDown() then
      local cfg = ns.API.GetResourceBarConfig(barNumber)
      if cfg and cfg.display.barMovable then
        self:StartMoving()
      end
    end
  end)
  
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and not IsShiftKeyDown() then
      self:StopMovingOrSizing()
      local cfg = ns.API.GetResourceBarConfig(barNumber)
      if cfg then
        local point, _, relPoint, x, y = self:GetPoint()
        cfg.display.barPosition = {
          point = point,
          relPoint = relPoint,
          x = x,
          y = y
        }
      end
    elseif button == "RightButton" or (button == "LeftButton" and IsShiftKeyDown()) then
      -- Open options and select this resource bar
      if ns.Resources.OpenOptionsForBar then
        ns.Resources.OpenOptionsForBar(barNumber)
      end
    end
  end)
  
  -- Delete button (small red X in corner, only visible when options panel is open)
  frame.deleteButton = CreateFrame("Button", nil, frame)
  frame.deleteButton:SetSize(12, 12)
  frame.deleteButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  -- Must be above tickOverlay (which is at +150) to be visible
  frame.deleteButton:SetFrameLevel(frame:GetFrameLevel() + 200)
  
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
    if ShowResourceDeleteConfirmation then
      ShowResourceDeleteConfirmation(barNumber)
    end
  end)
  
  frame.deleteButton:Hide()  -- Hidden by default, shown when options panel opens
  
  -- When frame is shown, check if delete buttons should be visible
  frame:SetScript("OnShow", function(self)
    if deleteButtonsVisible and self.deleteButton then
      self.deleteButton:Show()
    end
  end)
  
  frame:Hide()
  return frame
end

-- ===================================================================
-- CREATE TEXT FRAME
-- ===================================================================
local function CreateResourceTextFrame(barNumber)
  local frame = CreateFrame("Frame", "ArcUIResourceText" .. barNumber, UIParent)
  frame:SetSize(100, 40)
  frame:SetPoint("CENTER", 0, -70 - ((barNumber - 1) * 35))
  frame:SetMovable(true)
  frame:EnableMouse(false)
  frame:SetClampedToScreen(true)
  -- Default strata/level - will be overridden by ApplyAppearance with config values
  frame:SetFrameStrata("HIGH")
  frame:SetFrameLevel(110)
  
  frame.text = frame:CreateFontString(nil, "OVERLAY")
  frame.text:SetPoint("CENTER")
  frame.text:SetFont("Fonts\\FRIZQT__.TTF", 20, "THICKOUTLINE")
  frame.text:SetText("0")
  frame.text:SetTextColor(1, 1, 1, 1)
  frame.text:SetShadowOffset(0, 0)  -- Default to no shadow (setting controls this)
  
  -- Drag functionality
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      self:StartMoving()
    end
  end)
  
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
      self:StopMovingOrSizing()
      local cfg = ns.API.GetResourceBarConfig(barNumber)
      if cfg then
        local point, _, relPoint, x, y = self:GetPoint()
        cfg.display.textPosition = {
          point = point,
          relPoint = relPoint,
          x = x,
          y = y
        }
      end
    end
  end)
  
  frame:Hide()
  return frame
end

-- ===================================================================
-- GET OR CREATE RESOURCE FRAMES
-- ===================================================================
local function GetResourceFrames(barNumber)
  if not resourceFrames[barNumber] then
    resourceFrames[barNumber] = {
      mainFrame = CreateResourceBarFrame(barNumber),
      textFrame = CreateResourceTextFrame(barNumber)
    }
  end
  return resourceFrames[barNumber].mainFrame, resourceFrames[barNumber].textFrame
end

-- ===================================================================
-- ACTIVE COUNT COLOR for Fragmented/Icons/Segmented Modes
-- Evaluates conditions based on how many resources are currently active
-- Returns a single color for active segments only, or nil
-- Must be enabled via cfg.display.enableActiveCountColors
-- ===================================================================
local function GetActiveCountColor(cfg, activeCount)
  if not (cfg.display and cfg.display.enableActiveCountColors) then return nil end
  local conditions = cfg.display.activeCountColors
  if not conditions or type(activeCount) ~= "number" then return nil end
  -- Secret values can't be compared — skip active count coloring for primary resources in combat
  if issecretvalue and issecretvalue(activeCount) then return nil end
  
  -- Evaluate conditions in order (highest index = highest priority when overlapping)
  local matchColor = nil
  for i = 1, 3 do
    local cond = conditions[i]
    if cond and (i == 1 or cond.enabled) then
      local from = tonumber(cond.from) or 1
      local to = tonumber(cond.to) or 99
      if activeCount >= from and activeCount <= to and cond.color then
        matchColor = cond.color
      end
    end
  end
  return matchColor
end

-- ===================================================================
-- PER-SPEC READY COLOR for Fragmented/Icons Modes
-- Color priority: fragmentedColors[i] override → per-spec → barColor
-- ===================================================================
local DK_SPEC_DEFAULT_COLORS = {
  [250] = {r=0.77, g=0.12, b=0.23, a=1},  -- Blood: red
  [251] = {r=0.2,  g=0.6,  b=1.0,  a=1},  -- Frost: blue
  [252] = {r=0.0,  g=0.8,  b=0.2,  a=1},  -- Unholy: green
}
ns.Resources = ns.Resources or {}
ns.Resources.DK_SPEC_DEFAULT_COLORS = DK_SPEC_DEFAULT_COLORS

local function GetFragmentedReadyColor(config, segmentIndex)
  local segColors = config.display.fragmentedColors or {}
  if segColors[segmentIndex] then
    return segColors[segmentIndex]
  end
  local specColors = config.display.fragmentedSpecColors
  if specColors == nil and config.tracking and config.tracking.secondaryType == "runes" then
    specColors = { enabled = true }
  end
  if specColors and specColors.enabled then
    local spec = GetSpecialization and GetSpecialization()
    local specID = spec and GetSpecializationInfo(spec)
    if specID then
      if specColors[specID] then return specColors[specID] end
      if DK_SPEC_DEFAULT_COLORS[specID] then return DK_SPEC_DEFAULT_COLORS[specID] end
    end
  end
  return config.display.barColor
      or (ns.Resources.GetSecondaryResourceDefaultColor and ns.Resources.GetSecondaryResourceDefaultColor())
      or {r=0.5, g=0.5, b=0.5, a=1}
end

-- ===================================================================
-- SMART CHARGING COLOR
-- Auto-derives a dimmed version of the ready color per segment
-- Avoids allocations by reusing a per-segment cache table
-- ===================================================================
local SMART_DIM_FACTOR = 0.35
local _smartChargingCache = {}  -- [segmentIndex] = {r, g, b, a}

local function GetChargingColorForSegment(config, segmentIndex)
  -- If smart mode is off, use the manual charging color
  if not config.display.smartChargingColor then
    return config.display.fragmentedChargingColor or {r=0.4, g=0.4, b=0.4, a=1}
  end
  
  -- Smart mode: derive from the ready color for this segment
  local readyColor = GetFragmentedReadyColor(config, segmentIndex)
  
  -- Reuse cached table entry to avoid allocations
  if not _smartChargingCache[segmentIndex] then
    _smartChargingCache[segmentIndex] = {r=0, g=0, b=0, a=1}
  end
  local c = _smartChargingCache[segmentIndex]
  c.r = readyColor.r * SMART_DIM_FACTOR
  c.g = readyColor.g * SMART_DIM_FACTOR
  c.b = readyColor.b * SMART_DIM_FACTOR
  c.a = readyColor.a or 1
  return c
end

-- ===================================================================
-- ICON SHAPE TEXTURES for Icons Mode
-- Texture-based shapes give crisp, pixel-perfect rendering
-- "square" uses drawn ColorTexture (unchanged). All others use texture files.
-- ===================================================================
local ARCUI_TEXTURE_BASE = "Interface\\AddOns\\ArcUI\\Textures\\"
local ARCUI_NEW_TEX = ARCUI_TEXTURE_BASE .. "New Icon Textures\\"

-- Fill textures for each shape (the main visible shape)
local ICON_SHAPE_FILLS = {
  -- Original MWRB circle
  circle2              = ARCUI_TEXTURE_BASE .. "Points_Fill_2.tga",
  -- Circles
  circleSmooth         = ARCUI_NEW_TEX .. "Circle_Smooth.tga",
  circleSmoothBorder   = ARCUI_NEW_TEX .. "Circle_Smooth_Border.tga",
  circleWhite          = ARCUI_NEW_TEX .. "Circle_White.tga",
  circleWhiteBorder    = ARCUI_NEW_TEX .. "Circle_White_Border.tga",
  circleSquirrel       = ARCUI_NEW_TEX .. "Circle_Squirrel.tga",
  circleSquirrelBorder = ARCUI_NEW_TEX .. "Circle_Squirrel_Border.tga",
  -- Squares (texture-based, different from drawn "square")
  squareSmooth         = ARCUI_NEW_TEX .. "Square_Smooth.tga",
  squareSmoothBorder   = ARCUI_NEW_TEX .. "Square_Smooth_Border.tga",
  squareWhite          = ARCUI_NEW_TEX .. "Square_White.tga",
  squareWhiteBorder    = ARCUI_NEW_TEX .. "Square_White_Border.tga",
  squareSquirrel       = ARCUI_NEW_TEX .. "Square_Squirrel.tga",
  squareSquirrelBorder = ARCUI_NEW_TEX .. "Square_Squirrel_Border.tga",
  -- Triangles
  triangle             = ARCUI_NEW_TEX .. "triangle.tga",
  triangleBorder       = ARCUI_NEW_TEX .. "triangle-border.tga",
}

-- Texture-based artistic border files (Ring overlays for "texture" border style)
-- Square texture shapes: use texture fill but 4-edge pixel borders (like plain "square")
local SQUARE_TEXTURE_SHAPES = {
  squareSmooth = true, squareSmoothBorder = true,
  squareWhite = true, squareWhiteBorder = true,
  squareSquirrel = true, squareSquirrelBorder = true,
}

-- Shapes that use texture-based rendering (vs "square" which uses drawn borders + ColorTexture)
local TEXTURE_SHAPES = {
  circle2 = true,
  circleSmooth = true, circleSmoothBorder = true,
  circleWhite = true, circleWhiteBorder = true,
  circleSquirrel = true, circleSquirrelBorder = true,
  squareSmooth = true, squareSmoothBorder = true,
  squareWhite = true, squareWhiteBorder = true,
  squareSquirrel = true, squareSquirrelBorder = true,
  triangle = true, triangleBorder = true,
}

-- Circle shapes that support ring overlay borders
local CIRCLE_SHAPES = {
  circle2 = true,
  circleSmooth = true, circleSmoothBorder = true,
  circleWhite = true, circleWhiteBorder = true,
  circleSquirrel = true, circleSquirrelBorder = true,
}

-- Ring overlay textures for circle borders, keyed by thickness range
-- Each ring has a known pixel width in its 256x256 texture
-- sizeRatio = 256 / (256 - 2*ringPx) makes the inner edge align with the icon edge
local ARCUI_RING_10 = ARCUI_NEW_TEX .. "Ring_10px.tga"
local ARCUI_RING_20 = ARCUI_NEW_TEX .. "Ring_20px.tga"
local ARCUI_RING_30 = ARCUI_NEW_TEX .. "Ring_30px.tga"
local ARCUI_RING_40 = ARCUI_NEW_TEX .. "Ring_40px.tga"

local CIRCLE_RING_TIERS = {
  { maxThickness = 3,  tex = ARCUI_RING_10, ratio = 256 / 236 },
  { maxThickness = 7,  tex = ARCUI_RING_20, ratio = 256 / 216 },
  { maxThickness = 12, tex = ARCUI_RING_30, ratio = 256 / 196 },
  { maxThickness = 20, tex = ARCUI_RING_40, ratio = 256 / 176 },
}

local function GetCircleRingForThickness(thickness)
  for _, tier in ipairs(CIRCLE_RING_TIERS) do
    if thickness <= tier.maxThickness then
      return tier.tex, tier.ratio
    end
  end
  local last = CIRCLE_RING_TIERS[#CIRCLE_RING_TIERS]
  return last.tex, last.ratio
end

-- Expose for options dropdown (sorted display order)
ns.Resources.ICON_SHAPE_OPTIONS = {
  ["square"]              = "Square (Drawn)",
  ["squareSmooth"]        = "Square Smooth",
  ["squareSmoothBorder"]  = "Square Smooth + Ring",
  ["squareWhite"]         = "Square Flat",
  ["squareWhiteBorder"]   = "Square Flat + Ring",
  ["squareSquirrel"]      = "Square Spiralled",
  ["squareSquirrelBorder"]= "Square Spiralled + Ring",
  ["circle2"]             = "Circle (MWRB)",
  ["circleSmooth"]        = "Circle Smooth",
  ["circleSmoothBorder"]  = "Circle Smooth + Ring",
  ["circleWhite"]         = "Circle Flat",
  ["circleWhiteBorder"]   = "Circle Flat + Ring",
  ["circleSquirrel"]      = "Circle Spiralled",
  ["circleSquirrelBorder"]= "Circle Spiralled + Ring",
  ["triangle"]            = "Triangle",
  ["triangleBorder"]      = "Triangle + Ring",
}

-- Sort order for dropdown display
ns.Resources.ICON_SHAPE_ORDER = {
  "square", "squareSmooth", "squareSmoothBorder", "squareWhite", "squareWhiteBorder",
  "squareSquirrel", "squareSquirrelBorder",
  "circle2", "circleSmooth", "circleSmoothBorder", "circleWhite", "circleWhiteBorder",
  "circleSquirrel", "circleSquirrelBorder",
  "triangle", "triangleBorder",
}

-- ===================================================================
-- ANIMACHARGED OVERLAY for Continuous Modes
-- Creates overlay bars at charged combo point positions on top of base bar
-- Each overlay is sized to exactly 1 segment width, positioned at that segment's slice
-- ===================================================================
local function ApplyChargedOverlays(mainFrame, cfg, maxValue, currentVal, texturePath, orientation, reverseFill, isVertical)
  local secondaryType = cfg.tracking.secondaryType
  if secondaryType ~= "comboPoints" then
    -- Hide overlays if they exist
    if mainFrame.chargedOverlays then
      for _, bar in ipairs(mainFrame.chargedOverlays) do bar:Hide() end
    end
    return
  end
  
  local chargedLookup = ns.Resources.GetChargedComboPointLookup()
  local chargedColor = cfg.display.chargedComboColor or ns.Resources.ChargedComboPointColor
  
  -- Check if any charged points exist
  local hasCharged = false
  for _ in pairs(chargedLookup) do hasCharged = true; break end
  
  if not hasCharged then
    if mainFrame.chargedOverlays then
      for _, bar in ipairs(mainFrame.chargedOverlays) do bar:Hide() end
    end
    return
  end
  
  if not mainFrame.chargedOverlays then
    mainFrame.chargedOverlays = {}
  end
  
  local segmentCount = math.floor(maxValue)
  if segmentCount <= 0 then segmentCount = 1 end
  
  local barWidth = mainFrame:GetWidth()
  local barHeight = mainFrame:GetHeight()
  
  local overlayIdx = 0
  for i = 1, segmentCount do
    if chargedLookup[i] then
      overlayIdx = overlayIdx + 1
      
      -- Create overlay bar if needed
      if not mainFrame.chargedOverlays[overlayIdx] then
        local bar = CreateFrame("StatusBar", nil, mainFrame)
        table.insert(mainFrame.chargedOverlays, bar)
      end
      
      local overlay = mainFrame.chargedOverlays[overlayIdx]
      overlay:ClearAllPoints()
      overlay:SetStatusBarTexture(texturePath)
      overlay:SetOrientation(orientation)
      overlay:SetReverseFill(false)  -- Fill always forward within the segment slice
      overlay:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
      overlay:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
      overlay:SetMinMaxValues(0, 1)
      overlay:SetStatusBarColor(chargedColor.r, chargedColor.g, chargedColor.b, chargedColor.a or 1)
      
      -- Position overlay at exactly this segment's slice
      if isVertical then
        local segH = barHeight / segmentCount
        if reverseFill then
          -- Vertical reversed: segment 1 at top
          overlay:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -((i - 1) * segH))
          overlay:SetSize(barWidth, segH)
        else
          -- Vertical normal: segment 1 at bottom
          overlay:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, (i - 1) * segH)
          overlay:SetSize(barWidth, segH)
        end
      else
        local segW = barWidth / segmentCount
        if reverseFill then
          -- Horizontal reversed: segment 1 at right
          overlay:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -((i - 1) * segW), 0)
          overlay:SetSize(segW, barHeight)
        else
          -- Horizontal normal: segment 1 at left
          overlay:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", (i - 1) * segW, 0)
          overlay:SetSize(segW, barHeight)
        end
      end
      
      -- Show fully filled if this point is earned, hide if not
      -- Combo points are non-secret integers, safe to compare
      if not issecretvalue(currentVal) and currentVal >= i then
        overlay:SetValue(1)
        overlay:Show()
      elseif issecretvalue(currentVal) then
        -- Secret fallback: show overlay, let engine handle via SetValue
        overlay:SetValue(1)
        overlay:Show()
      else
        overlay:Hide()
      end
    end
  end
  
  -- Hide unused overlays
  for j = overlayIdx + 1, #mainFrame.chargedOverlays do
    mainFrame.chargedOverlays[j]:Hide()
  end
end

-- ===================================================================
-- UPDATE THRESHOLD LAYERS
-- ===================================================================
-- TWO MODES:
--
-- SIMPLE MODE: Single bar with proportional fill (1 color)
-- GRANULAR MODE: TRUE color change at ANY threshold using ~100 bars
--
local function UpdateThresholdLayers(barNumber, secretValue, passedMaxValue)
  local cfg = ns.API.GetResourceBarConfig(barNumber)
  if not cfg or not cfg.tracking.enabled then return end
  
  local mainFrame, _ = GetResourceFrames(barNumber)
  mainFrame._barNumber = barNumber  -- Store for icon drag handlers
  local thresholds = cfg.thresholds or {}
  
  -- Use passed maxValue if provided, otherwise fall back to stored
  local maxValue = passedMaxValue or cfg.tracking.maxValue or 100
  local displayMode = cfg.display.thresholdMode or "simple"
  
  -- SAFETY: Primary resources must never be in fragmented or icons mode.
  -- These modes compare secretValue per-segment which crashes on SECRET primary resources.
  -- If a slot was reused from a previous secondary bar, force back to simple.
  local isSecondaryResource = cfg.tracking.resourceCategory == "secondary"
  if not isSecondaryResource and (displayMode == "fragmented" or displayMode == "icons") then
    cfg.display.thresholdMode = "simple"
    displayMode = "simple"
  end
  
  -- MIGRATION: Convert old granular/threshold modes to colorCurve
  -- Granular mode (1 StatusBar per unit) caused "script ran too long" on high-value resources
  -- and threshold mode (stacked bars) is redundant with colorCurve. Both are now removed.
  if displayMode == "granular" or displayMode == "threshold" then
    -- Migrate old thresholds[2-5] config to colorCurve keys if present
    if cfg.thresholds and not cfg.display.colorCurveEnabled then
      cfg.display.colorCurveEnabled = true
      cfg.display.colorCurveThresholdAsPercent = cfg.display.thresholdAsPercent or false
      for i = 2, 5 do
        if cfg.thresholds[i] then
          cfg.display["colorCurveThreshold" .. i .. "Enabled"] = cfg.thresholds[i].enabled
          cfg.display["colorCurveThreshold" .. i .. "Value"] = cfg.thresholds[i].minValue
          -- Normalize color to {r=, g=, b=, a=} format (old data may use indexed arrays)
          local oldColor = cfg.thresholds[i].color
          if oldColor then
            local r, g, b, a = SafeColorRGBA(oldColor)
            cfg.display["colorCurveThreshold" .. i .. "Color"] = {r=r, g=g, b=b, a=a}
          end
        end
      end
    end
    cfg.display.thresholdMode = "colorCurve"
    displayMode = "colorCurve"
  end
  
  -- Hide all existing layers
  for i = 1, #mainFrame.layers do
    mainFrame.layers[i]:Hide()
  end
  
  -- Hide granular bars if they exist
  if mainFrame.granularBars then
    for i = 1, #mainFrame.granularBars do
      mainFrame.granularBars[i]:Hide()
    end
  end
  
  -- Hide stacked bars if they exist
  if mainFrame.stackedBars then
    for i = 1, #mainFrame.stackedBars do
      mainFrame.stackedBars[i]:Hide()
    end
  end
  
  -- Hide prediction overlays (only shown in simple mode when active)
  if mainFrame.predGainBar then mainFrame.predGainBar:Hide() end
  if mainFrame.predCostFrame then mainFrame.predCostFrame:Hide() end
  
  -- Hide fragmented bars if they exist
  if mainFrame.fragmentedBars then
    for i = 1, #mainFrame.fragmentedBars do
      mainFrame.fragmentedBars[i]:Hide()
    end
  end
  if mainFrame.fragmentedBgs then
    for i = 1, #mainFrame.fragmentedBgs do
      mainFrame.fragmentedBgs[i]:Hide()
    end
  end
  -- Clear fragmented OnUpdate when switching away
  if displayMode ~= "fragmented" and mainFrame.fragmentedOnUpdate then
    mainFrame:SetScript("OnUpdate", nil)
    mainFrame.fragmentedOnUpdate = nil
  end
  -- Clear icons OnUpdate when switching away
  if displayMode ~= "icons" and mainFrame.iconsOnUpdate then
    mainFrame:SetScript("OnUpdate", nil)
    mainFrame.iconsOnUpdate = nil
  end
  
  -- Helper: Check if this bar is tracking a secondary resource (non-secret in Beta 3+)
  local isSecondaryResource = (cfg.tracking.resourceCategory == "secondary")
  
  -- Helper: Resolve the powerType for secondary resources (for ColorCurve paths that need it)
  local function GetSecondaryPowerType()
    if not isSecondaryResource then return nil end
    local secType = cfg.tracking.secondaryType
    local typeInfo = secType and ns.Resources.SecondaryTypesLookup and ns.Resources.SecondaryTypesLookup[secType]
    return typeInfo and typeInfo.powerType
  end
  
  -- Get texture from settings
  local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
  local texturePath = "Interface\\TargetingFrame\\UI-StatusBar"
  if LSM and cfg.display.texture then
    local fetchedTexture = LSM:Fetch("statusbar", cfg.display.texture)
    if fetchedTexture then
      texturePath = fetchedTexture
    end
  end
  
  -- Get fill texture scale
  local fillTextureScale = cfg.display.fillTextureScale or 1.0
  
  if displayMode == "folded" then
    -- ═══════════════════════════════════════════════════════════════
    -- FOLDED MODE: Bar folds at midpoint, second color overlays first
    -- Visual: 2nd color fills over 1st after midpoint
    -- ═══════════════════════════════════════════════════════════════
    local midpoint = math.ceil(maxValue / 2)
    local color1 = cfg.display.foldedColor1 or {r=0, g=0.5, b=1, a=1}
    local color2 = cfg.display.foldedColor2 or {r=0, g=1, b=0, a=1}
    
    -- Get smoothing and orientation settings
    local enableSmooth = cfg.display.enableSmoothing
    local orientation = GetBarOrientation(cfg)
    local reverseFill = GetBarReverseFill(cfg)
    local isVertical = (orientation == "VERTICAL")
    
    -- Hide other bar types
    if mainFrame.granularBars then
      for _, bar in ipairs(mainFrame.granularBars) do bar:Hide() end
    end
    if mainFrame.layers then
      for _, layer in ipairs(mainFrame.layers) do layer:Hide() end
    end
    -- Hide foldedBgFrame if exists from old code
    if mainFrame.foldedBgFrame then
      mainFrame.foldedBgFrame:Hide()
    end
    -- Hide fragment frames if they exist
    if mainFrame.fragmentFrames then
      for _, frame in ipairs(mainFrame.fragmentFrames) do frame:Hide() end
    end
    -- Hide icon frames if they exist
    if mainFrame.iconFrames then
      for _, frame in ipairs(mainFrame.iconFrames) do frame:Hide() end
    end
    -- Hide charged overlays from continuous mode
    if mainFrame.chargedOverlays then
      for _, bar in ipairs(mainFrame.chargedOverlays) do bar:Hide() end
    end
    
    if not mainFrame.stackedBars then
      mainFrame.stackedBars = {}
    end
    
    while #mainFrame.stackedBars < 2 do
      local bar = CreateFrame("StatusBar", nil, mainFrame)
      bar:SetStatusBarTexture(texturePath)
      bar:SetOrientation(orientation)
      bar:SetReverseFill(reverseFill)
      bar:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
      table.insert(mainFrame.stackedBars, bar)
    end
    
    -- Bar 1: First half color (0 to midpoint)
    local bar1 = mainFrame.stackedBars[1]
    bar1:SetParent(mainFrame)
    bar1:ClearAllPoints()
    bar1:SetAllPoints(mainFrame)  -- Fill entire frame like MWRB
    bar1:SetMinMaxValues(0, midpoint)
    bar1:SetStatusBarTexture(texturePath)
    bar1:SetStatusBarColor(color1.r, color1.g, color1.b, color1.a or 1)
    bar1:SetOrientation(orientation)
    bar1:SetReverseFill(reverseFill)
    bar1:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
    bar1:SetFrameLevel(mainFrame:GetFrameLevel() + 6)
    ApplyBarSmoothing(bar1, enableSmooth)
    bar1:SetValue(secretValue, bar1._arcInterpolation)  -- Will cap at midpoint naturally
    bar1:Show()
    
    -- Bar 2: Second half color (midpoint to max) - overlays bar1 directly
    local bar2 = mainFrame.stackedBars[2]
    bar2:SetParent(mainFrame)
    bar2:ClearAllPoints()
    bar2:SetAllPoints(mainFrame)  -- Fill entire frame like MWRB
    bar2:SetMinMaxValues(midpoint, maxValue)
    bar2:SetStatusBarTexture(texturePath)
    bar2:SetStatusBarColor(color2.r, color2.g, color2.b, color2.a or 1)
    bar2:SetOrientation(orientation)
    bar2:SetReverseFill(reverseFill)
    bar2:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
    bar2:SetFrameLevel(mainFrame:GetFrameLevel() + 7)
    ApplyBarSmoothing(bar2, enableSmooth)
    bar2:SetValue(secretValue, bar2._arcInterpolation)  -- Only fills when value > midpoint
    bar2:Show()
    
    -- MAX COLOR via ColorCurve on bar2's texture (replaces old maxColorBar overlay)
    local enableMaxColor = cfg.display.enableMaxColor
    local powerType = cfg.tracking.powerType
    if enableMaxColor and isSecondaryResource and type(secretValue) == "number" then
      -- Secondary resource at-max: direct comparison (non-secret, avoids UnitPowerPercent login bugs)
      if secretValue >= maxValue and maxValue > 0 then
        local maxColor = cfg.display.maxColor or {r=0, g=1, b=0, a=1}
        bar2:SetStatusBarColor(maxColor.r, maxColor.g, maxColor.b, maxColor.a or 1)
      end
    elseif enableMaxColor and powerType and powerType >= 0 then
      -- Primary resource: UnitPowerPercent curve (secret-safe)
      local maxCurve = GetMaxColorOnlyCurve(barNumber, cfg, color2, powerType)
      if maxCurve then
        local barTexture = bar2:GetStatusBarTexture()
        local colorOK = pcall(function()
          local colorResult = UnitPowerPercent("player", powerType, false, maxCurve)
          if colorResult and colorResult.GetRGBA then
            barTexture:SetVertexColor(colorResult:GetRGBA())
          end
        end)
        if not colorOK then
          bar2:SetStatusBarColor(color2.r, color2.g, color2.b, color2.a or 1)
        end
      end
    end
    -- Hide legacy maxColorBar if it exists from previous code
    if mainFrame.maxColorBar then
      mainFrame.maxColorBar:Hide()
    end
    
  elseif displayMode == "fragmented" then
    -- ═══════════════════════════════════════════════════════════════
    -- FRAGMENTED MODE: Completely separate bars for each segment
    -- For Runes (DK) and Essence (Evoker) where each segment charges independently
    -- Each segment is its own independent frame with background, fill, border, text
    -- The gaps between segments are TRUE EMPTY SPACE (no background)
    -- ═══════════════════════════════════════════════════════════════
    
    -- Hide other bar types
    if mainFrame.granularBars then
      for _, bar in ipairs(mainFrame.granularBars) do bar:Hide() end
    end
    if mainFrame.stackedBars then
      for _, bar in ipairs(mainFrame.stackedBars) do bar:Hide() end
    end
    if mainFrame.maxColorBar then
      mainFrame.maxColorBar:Hide()
    end
    -- Hide simple mode layers
    for i = 1, #mainFrame.layers do
      mainFrame.layers[i]:Hide()
    end
    
    -- CRITICAL: Hide main frame's background and borders so gaps show through
    if mainFrame.bg then
      mainFrame.bg:Hide()
    end
    if mainFrame.borderOverlay then
      if mainFrame.borderOverlay.top then mainFrame.borderOverlay.top:Hide() end
      if mainFrame.borderOverlay.bottom then mainFrame.borderOverlay.bottom:Hide() end
      if mainFrame.borderOverlay.left then mainFrame.borderOverlay.left:Hide() end
      if mainFrame.borderOverlay.right then mainFrame.borderOverlay.right:Hide() end
      mainFrame.borderOverlay:Hide()
    end
    -- Hide icon frames if they exist
    if mainFrame.iconFrames then
      for _, frame in ipairs(mainFrame.iconFrames) do frame:Hide() end
    end
    -- Hide charged overlays from continuous mode
    if mainFrame.chargedOverlays then
      for _, bar in ipairs(mainFrame.chargedOverlays) do bar:Hide() end
    end
    
    -- Get resource type from config
    local secondaryType = cfg.tracking.secondaryType
    local numSegments = maxValue
    local segmentData = nil
    
    -- Get per-segment cooldown data (skip during preview — use secretValue for animation)
    local isPreview = IsOptionsOpen()
    if not isPreview then
      if secondaryType == "runes" then
        segmentData, numSegments = ns.Resources.GetRuneCooldownDetails()
      elseif secondaryType == "essence" then
        segmentData, numSegments = ns.Resources.GetEssenceCooldownDetails()
      end
    end
    
    if not segmentData or numSegments <= 0 then
      numSegments = maxValue
    end
    
    -- Get colors
    local perSegmentColors = cfg.display.fragmentedColors or {}
    local barColor = cfg.display.barColor or ns.Resources.GetSecondaryResourceDefaultColor()
    local bgColor = cfg.display.backgroundColor or {r=0.1, g=0.1, b=0.1, a=0.8}
    local borderColor = cfg.display.borderColor or {r=0, g=0, b=0, a=1}
    local showBorder = cfg.display.showBorder
    local borderThickness = cfg.display.drawnBorderThickness or 2
    
    -- Animacharged combo point support
    local chargedLookup = {}
    local chargedColor = nil
    if secondaryType == "comboPoints" then
      chargedLookup = ns.Resources.GetChargedComboPointLookup()
      chargedColor = cfg.display.chargedComboColor or ns.Resources.ChargedComboPointColor
    end
    
    -- Active count color conditioning (all segments same color based on active count)
    -- Floor for fractional resources (Destruction soul shards: 3.5 → 3 whole shards active)
    local activeCount = type(secretValue) == "number" and math.floor(secretValue) or secretValue
    if segmentData then
      -- For runes/essence, count ready segments
      activeCount = 0
      for _, seg in ipairs(segmentData) do
        if seg.ready then activeCount = activeCount + 1 end
      end
    end
    local activeCountColor = GetActiveCountColor(cfg, activeCount)
    
    -- Get smoothing setting
    local enableSmooth = cfg.display.enableSmoothing
    
    -- Text settings (new unified cdText* keys, fallback to old fragmented* keys only if new key is nil)
    local showSegmentText = cfg.display.cdTextShow
    if showSegmentText == nil then showSegmentText = cfg.display.fragmentedShowSegmentText end
    local textSize = cfg.display.cdTextSize or cfg.display.fragmentedTextSize or 10
    local textOffsetX = cfg.display.cdTextOffsetX or cfg.display.fragmentedTextOffsetX or 0
    local textOffsetY = cfg.display.cdTextOffsetY or cfg.display.fragmentedTextOffsetY or 0
    local cdTextOutline = cfg.display.cdTextOutline or "OUTLINE"
    local cdTextPrecision = cfg.display.cdTextDecimalPrecision or 0
    local cdTextColor = cfg.display.cdTextColor or {r=1, g=1, b=1, a=1}
    local cdTextFontPath = STANDARD_TEXT_FONT
    if LSM and cfg.display.cdTextFont then
      cdTextFontPath = LSM:Fetch("font", cfg.display.cdTextFont) or STANDARD_TEXT_FONT
    end
    
    -- Prediction settings
    local showPrediction = cfg.display.showPrediction
    local predCostColor = cfg.display.predCostColor or {r=0, g=0, b=0, a=0.5}
    local predGainColor = cfg.display.predGainColor or {r=1, g=1, b=1, a=0.3}
    local predActive = showPrediction and Prediction.active and secondaryType == "soulShards"
    
    -- Spacing between segments (actual gap between separate frames)
    local spacing = cfg.display.fragmentedSpacing or 2
    
    -- When spacing=0 with borders, use unified border:
    -- ONE outer border + dividers. No per-segment border duplication.
    local useUnifiedBorder = (showBorder and spacing == 0)
    
    -- Snap border thickness to exact physical pixel count.
    -- borderThickness=1 at 0.8 UI scale = 0.8 screen pixels = anti-aliased blur.
    -- PixelUtil snaps it to exactly 1 (or 2) physical pixels.
    local pixelBT = borderThickness
    if showBorder and mainFrame.GetEffectiveScale then
      pixelBT = PixelUtil.GetNearestPixelSize(borderThickness, mainFrame:GetEffectiveScale(), 1)
    end
    
    local totalGaps = spacing * math.max(0, numSegments - 1)
    
    -- Layout direction
    local layoutDir = cfg.display.fragmentedLayoutDirection or "horizontal"
    local isLayoutVertical = (layoutDir == "vertical")
    
    -- Fill orientation
    local fillOrient = cfg.display.fragmentedFillOrientation or "horizontal"
    local isFillVertical = (fillOrient == "vertical")
    local barOrientation = isFillVertical and "VERTICAL" or "HORIZONTAL"
    
    -- Segment size: configured dims = content area, gaps are extra
    local segmentWidth, segmentHeight
    local isMatchingGroup = cfg.display.anchorToGroup and cfg.display.matchGroupWidth
    
    if isMatchingGroup then
      local mfW = mainFrame:GetWidth()
      local mfH = mainFrame:GetHeight()
      if isLayoutVertical then
        segmentWidth = mfW
        segmentHeight = (mfH - totalGaps) / numSegments
      else
        segmentWidth = (mfW - totalGaps) / numSegments
        segmentHeight = mfH
      end
    else
      local scale = cfg.display.barScale or 1.0
      local baseW = cfg.display.width * scale
      local baseH = cfg.display.height * scale
      if isLayoutVertical then
        segmentWidth = baseH
        segmentHeight = baseW / numSegments
        mainFrame:SetSize(baseH, baseW + totalGaps)
      else
        segmentWidth = baseW / numSegments
        segmentHeight = baseH
        mainFrame:SetSize(baseW + totalGaps, baseH)
      end
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- UNIFIED BORDER (spacing=0): outer border + dividers on borderOverlay
    -- Uses pixel-snapped thickness + SetSnapToPixelGrid for positions
    -- ═══════════════════════════════════════════════════════════════════
    if useUnifiedBorder and mainFrame.borderOverlay then
      local bt = pixelBT
      local bc = borderColor
      
      -- Enable GPU pixel snapping on outer border textures
      mainFrame.borderOverlay.top:SetSnapToPixelGrid(true)
      mainFrame.borderOverlay.top:SetTexelSnappingBias(1)
      mainFrame.borderOverlay.bottom:SetSnapToPixelGrid(true)
      mainFrame.borderOverlay.bottom:SetTexelSnappingBias(1)
      mainFrame.borderOverlay.left:SetSnapToPixelGrid(true)
      mainFrame.borderOverlay.left:SetTexelSnappingBias(1)
      mainFrame.borderOverlay.right:SetSnapToPixelGrid(true)
      mainFrame.borderOverlay.right:SetTexelSnappingBias(1)
      
      mainFrame.borderOverlay:Show()
      mainFrame.borderOverlay.top:ClearAllPoints()
      mainFrame.borderOverlay.top:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, 0)
      mainFrame.borderOverlay.top:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, 0)
      mainFrame.borderOverlay.top:SetHeight(bt)
      mainFrame.borderOverlay.top:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
      mainFrame.borderOverlay.top:Show()
      
      mainFrame.borderOverlay.bottom:ClearAllPoints()
      mainFrame.borderOverlay.bottom:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, 0)
      mainFrame.borderOverlay.bottom:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
      mainFrame.borderOverlay.bottom:SetHeight(bt)
      mainFrame.borderOverlay.bottom:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
      mainFrame.borderOverlay.bottom:Show()
      
      mainFrame.borderOverlay.left:ClearAllPoints()
      mainFrame.borderOverlay.left:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -bt)
      mainFrame.borderOverlay.left:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, bt)
      mainFrame.borderOverlay.left:SetWidth(bt)
      mainFrame.borderOverlay.left:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
      mainFrame.borderOverlay.left:Show()
      
      mainFrame.borderOverlay.right:ClearAllPoints()
      mainFrame.borderOverlay.right:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -bt)
      mainFrame.borderOverlay.right:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, bt)
      mainFrame.borderOverlay.right:SetWidth(bt)
      mainFrame.borderOverlay.right:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
      mainFrame.borderOverlay.right:Show()
      
      -- Create/update divider lines between segments
      if not mainFrame.fragmentDividers then
        mainFrame.fragmentDividers = {}
      end
      for d = 1, numSegments - 1 do
        if not mainFrame.fragmentDividers[d] then
          local div = mainFrame.borderOverlay:CreateTexture(nil, "OVERLAY")
          div:SetSnapToPixelGrid(true)
          div:SetTexelSnappingBias(1)
          mainFrame.fragmentDividers[d] = div
        end
        local div = mainFrame.fragmentDividers[d]
        div:SetSnapToPixelGrid(true)
        div:SetTexelSnappingBias(1)
        div:ClearAllPoints()
        div:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
        
        if isLayoutVertical then
          local yPos = d * segmentHeight
          div:SetPoint("LEFT", mainFrame, "BOTTOMLEFT", bt, yPos)
          div:SetPoint("RIGHT", mainFrame, "BOTTOMRIGHT", -bt, yPos)
          div:SetHeight(bt)
        else
          local xPos = d * segmentWidth
          div:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", xPos, -bt)
          div:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", xPos, bt)
          div:SetWidth(bt)
        end
        div:Show()
      end
      -- Hide excess dividers
      for d = numSegments, #(mainFrame.fragmentDividers) do
        if mainFrame.fragmentDividers[d] then
          mainFrame.fragmentDividers[d]:Hide()
        end
      end
    else
      -- Not unified: restore snapping defaults, hide dividers
      if mainFrame.borderOverlay then
        mainFrame.borderOverlay.top:SetSnapToPixelGrid(false)
        mainFrame.borderOverlay.top:SetTexelSnappingBias(0)
        mainFrame.borderOverlay.bottom:SetSnapToPixelGrid(false)
        mainFrame.borderOverlay.bottom:SetTexelSnappingBias(0)
        mainFrame.borderOverlay.left:SetSnapToPixelGrid(false)
        mainFrame.borderOverlay.left:SetTexelSnappingBias(0)
        mainFrame.borderOverlay.right:SetSnapToPixelGrid(false)
        mainFrame.borderOverlay.right:SetTexelSnappingBias(0)
      end
      if mainFrame.fragmentDividers then
        for _, div in ipairs(mainFrame.fragmentDividers) do div:Hide() end
      end
    end
    
    -- Create fragment frames container if it doesn't exist
    if not mainFrame.fragmentFrames then
      mainFrame.fragmentFrames = {}
    end
    
    -- Ensure we have enough fragment frames
    while #mainFrame.fragmentFrames < numSegments do
      local idx = #mainFrame.fragmentFrames + 1
      
      -- Create container frame for this segment
      local segFrame = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
      segFrame:SetFrameLevel(mainFrame:GetFrameLevel() + 1)
      
      -- Background texture
      segFrame.bg = segFrame:CreateTexture(nil, "BACKGROUND")
      segFrame.bg:SetAllPoints()
      segFrame.bg:SetTexture(texturePath)
      segFrame.bg:SetSnapToPixelGrid(false)
      segFrame.bg:SetTexelSnappingBias(0)
      
      -- Fill StatusBar
      segFrame.fill = CreateFrame("StatusBar", nil, segFrame)
      segFrame.fill:SetStatusBarTexture(texturePath)
      segFrame.fill:SetMinMaxValues(0, 1)
      segFrame.fill:SetFrameLevel(segFrame:GetFrameLevel() + 1)
      ConfigureStatusBar(segFrame.fill)  -- Prevent pixel snapping
      
      -- Border (drawn style)
      segFrame.borderTop = segFrame:CreateTexture(nil, "OVERLAY")
      segFrame.borderTop:SetSnapToPixelGrid(false)
      segFrame.borderTop:SetTexelSnappingBias(0)
      segFrame.borderBottom = segFrame:CreateTexture(nil, "OVERLAY")
      segFrame.borderBottom:SetSnapToPixelGrid(false)
      segFrame.borderBottom:SetTexelSnappingBias(0)
      segFrame.borderLeft = segFrame:CreateTexture(nil, "OVERLAY")
      segFrame.borderLeft:SetSnapToPixelGrid(false)
      segFrame.borderLeft:SetTexelSnappingBias(0)
      segFrame.borderRight = segFrame:CreateTexture(nil, "OVERLAY")
      segFrame.borderRight:SetSnapToPixelGrid(false)
      segFrame.borderRight:SetTexelSnappingBias(0)
      
      -- Cooldown text
      segFrame.cdText = segFrame.fill:CreateFontString(nil, "OVERLAY")
      segFrame.cdText:SetPoint("CENTER", segFrame.fill, "CENTER", 0, 0)
      segFrame.cdText:SetTextColor(1, 1, 1, 1)
      
      -- Prediction overlay (cost/gain indicator) - anchored to fill area, not full segment
      segFrame.predictFrame = CreateFrame("Frame", nil, segFrame)
      segFrame.predictFrame:SetFrameLevel(segFrame.fill:GetFrameLevel() + 1)
      segFrame.predictFrame:SetAllPoints(segFrame.fill)
      segFrame.predictOverlay = segFrame.predictFrame:CreateTexture(nil, "OVERLAY")
      segFrame.predictOverlay:SetAllPoints()
      segFrame.predictOverlay:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
      segFrame.predictOverlay:SetVertexColor(0, 0, 0, 0.5)
      segFrame.predictFrame:Hide()
      
      table.insert(mainFrame.fragmentFrames, segFrame)
    end
    
    -- Position and update each segment frame
    for i = 1, numSegments do
      local segFrame = mainFrame.fragmentFrames[i]
      
      -- Position based on layout direction
      segFrame:ClearAllPoints()
      if isLayoutVertical then
        -- Vertical layout: stack bottom-to-top (segment 1 at bottom)
        local yOffset = (i - 1) * (segmentHeight + spacing)
        segFrame:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, yOffset)
        segFrame:SetSize(segmentWidth, segmentHeight)
      else
        -- Horizontal layout: stack left-to-right (segment 1 at left)
        local xOffset = (i - 1) * (segmentWidth + spacing)
        segFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", xOffset, 0)
        segFrame:SetSize(segmentWidth, segmentHeight)
      end
      
      -- Update background
      if cfg.display.showBackground ~= false then
        segFrame.bg:SetTexture(texturePath)
        segFrame.bg:SetVertexColor(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
        segFrame.bg:Show()
      else
        segFrame.bg:Hide()
      end
      
      -- Update fill bar positioning
      segFrame.fill:ClearAllPoints()
      if useUnifiedBorder then
        -- Unified: outer border on borderOverlay, dividers on top.
        -- Inset fill only on edges touching mainFrame outer border.
        local bt = pixelBT
        local inL, inR, inT, inB = 0, 0, 0, 0
        if isLayoutVertical then
          inL = bt; inR = bt
          inT = (i == numSegments) and bt or 0
          inB = (i == 1) and bt or 0
        else
          inT = bt; inB = bt
          inL = (i == 1) and bt or 0
          inR = (i == numSegments) and bt or 0
        end
        segFrame.fill:SetPoint("TOPLEFT", segFrame, "TOPLEFT", inL, -inT)
        segFrame.fill:SetPoint("BOTTOMRIGHT", segFrame, "BOTTOMRIGHT", -inR, inB)
      else
        local inset = showBorder and pixelBT or 0
        segFrame.fill:SetPoint("TOPLEFT", segFrame, "TOPLEFT", inset, -inset)
        segFrame.fill:SetPoint("BOTTOMRIGHT", segFrame, "BOTTOMRIGHT", -inset, inset)
      end
      segFrame.fill:SetStatusBarTexture(texturePath)
      segFrame.fill:SetOrientation(barOrientation)
      segFrame.fill:SetReverseFill(false)
      segFrame.fill:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isFillVertical))
      ApplyBarSmoothing(segFrame.fill, enableSmooth)
      
      -- Per-segment borders (only for spaced mode — unified uses borderOverlay + dividers)
      if showBorder and not useUnifiedBorder then
        local bt = pixelBT
        -- Enable GPU pixel snapping on per-segment borders
        segFrame.borderTop:SetSnapToPixelGrid(true)
        segFrame.borderTop:SetTexelSnappingBias(1)
        segFrame.borderBottom:SetSnapToPixelGrid(true)
        segFrame.borderBottom:SetTexelSnappingBias(1)
        segFrame.borderLeft:SetSnapToPixelGrid(true)
        segFrame.borderLeft:SetTexelSnappingBias(1)
        segFrame.borderRight:SetSnapToPixelGrid(true)
        segFrame.borderRight:SetTexelSnappingBias(1)
        
        segFrame.borderTop:ClearAllPoints()
        segFrame.borderTop:SetPoint("TOPLEFT", segFrame, "TOPLEFT", 0, 0)
        segFrame.borderTop:SetPoint("TOPRIGHT", segFrame, "TOPRIGHT", 0, 0)
        segFrame.borderTop:SetHeight(bt)
        segFrame.borderTop:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        segFrame.borderTop:Show()
        
        segFrame.borderBottom:ClearAllPoints()
        segFrame.borderBottom:SetPoint("BOTTOMLEFT", segFrame, "BOTTOMLEFT", 0, 0)
        segFrame.borderBottom:SetPoint("BOTTOMRIGHT", segFrame, "BOTTOMRIGHT", 0, 0)
        segFrame.borderBottom:SetHeight(bt)
        segFrame.borderBottom:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        segFrame.borderBottom:Show()
        
        segFrame.borderLeft:ClearAllPoints()
        segFrame.borderLeft:SetPoint("TOPLEFT", segFrame, "TOPLEFT", 0, -bt)
        segFrame.borderLeft:SetPoint("BOTTOMLEFT", segFrame, "BOTTOMLEFT", 0, bt)
        segFrame.borderLeft:SetWidth(bt)
        segFrame.borderLeft:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        segFrame.borderLeft:Show()
        
        segFrame.borderRight:ClearAllPoints()
        segFrame.borderRight:SetPoint("TOPRIGHT", segFrame, "TOPRIGHT", 0, -bt)
        segFrame.borderRight:SetPoint("BOTTOMRIGHT", segFrame, "BOTTOMRIGHT", 0, bt)
        segFrame.borderRight:SetWidth(bt)
        segFrame.borderRight:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        segFrame.borderRight:Show()
      else
        segFrame.borderTop:Hide()
        segFrame.borderBottom:Hide()
        segFrame.borderLeft:Hide()
        segFrame.borderRight:Hide()
      end
      
      -- Get fill percentage for this segment
      local fillPercent = 0
      local isReady = false
      local cooldownRemaining = 0
      
      if segmentData and segmentData[i] then
        fillPercent = segmentData[i].fillPercent or 0
        isReady = segmentData[i].ready
        -- Calculate remaining time
        if not isReady and segmentData[i].start and segmentData[i].duration and segmentData[i].duration > 0 then
          local elapsed = GetTime() - segmentData[i].start
          cooldownRemaining = math.max(0, segmentData[i].duration - elapsed)
        end
      elseif secretValue >= i then
        -- Full segment
        fillPercent = 1
        isReady = true
      elseif secretValue > (i - 1) then
        -- Partial segment (Destruction soul shards: e.g. 3.5 → segment 4 = 50%)
        fillPercent = secretValue - (i - 1)
        isReady = false
      else
        fillPercent = 0
        isReady = false
      end
      
      -- Get color for this segment
      local segmentColor
      if chargedLookup[i] and chargedColor then
        -- Animacharged point: always show filled, bright if earned, dim if not
        fillPercent = 1
        if isReady then
          segmentColor = chargedColor
        else
          segmentColor = {r=chargedColor.r*0.5, g=chargedColor.g*0.5, b=chargedColor.b*0.5, a=chargedColor.a or 1}
        end
      elseif isReady then
        segmentColor = activeCountColor or GetFragmentedReadyColor(cfg, i)
      else
        segmentColor = GetChargingColorForSegment(cfg, i)
      end
      
      segFrame.fill:SetStatusBarColor(segmentColor.r, segmentColor.g, segmentColor.b, segmentColor.a or 1)
      segFrame.fill:SetValue(fillPercent, segFrame.fill._arcInterpolation)
      
      -- Prediction overlay
      if segFrame.predictFrame then
        if predActive then
          local predState = Prediction:GetSegmentState(i, secretValue)
          if predState == "cost" then
            segFrame.predictOverlay:SetTexture(texturePath)
            segFrame.predictOverlay:SetVertexColor(predCostColor.r, predCostColor.g, predCostColor.b, predCostColor.a or 0.5)
            segFrame.predictFrame:Show()
          elseif predState == "gain" then
            local gainCol = activeCountColor or GetFragmentedReadyColor(cfg, i)
            segFrame.predictOverlay:SetTexture(texturePath)
            segFrame.predictOverlay:SetVertexColor(gainCol.r, gainCol.g, gainCol.b, predGainColor.a or 0.3)
            segFrame.predictFrame:Show()
          else
            segFrame.predictFrame:Hide()
          end
        else
          segFrame.predictFrame:Hide()
        end
      end
      
      -- Update cooldown text
      segFrame.cdText:SetFont(cdTextFontPath, textSize, cdTextOutline)
      segFrame.cdText:SetTextColor(cdTextColor.r, cdTextColor.g, cdTextColor.b, cdTextColor.a or 1)
      segFrame.cdText:ClearAllPoints()
      segFrame.cdText:SetPoint("CENTER", segFrame, "CENTER", textOffsetX, textOffsetY)
      if showSegmentText and not isReady and cooldownRemaining > 0 then
        local fmt = "%." .. cdTextPrecision .. "f"
        segFrame.cdText:SetText(string.format(fmt, cooldownRemaining))
        segFrame.cdText:Show()
      elseif showSegmentText and IsOptionsOpen() then
        -- Preview: show fake countdown so user can see font/size/color/precision live
        local previewVal = 3.5 + (numSegments - i) * 1.7
        local fmt = "%." .. cdTextPrecision .. "f"
        segFrame.cdText:SetText(string.format(fmt, previewVal))
        segFrame.cdText:Show()
      else
        segFrame.cdText:Hide()
      end
      
      segFrame:Show()
    end
    
    -- Hide unused segment frames
    for i = numSegments + 1, #mainFrame.fragmentFrames do
      if mainFrame.fragmentFrames[i] then
        mainFrame.fragmentFrames[i]:Hide()
      end
    end
    
    -- Hide old fragmented bars if they exist
    if mainFrame.fragmentedBars then
      for _, bar in ipairs(mainFrame.fragmentedBars) do bar:Hide() end
    end
    if mainFrame.fragmentedBgs then
      for _, bg in ipairs(mainFrame.fragmentedBgs) do bg:Hide() end
    end
    
    -- Set up OnUpdate for animation (only for runes/essence which have cooldowns)
    if secondaryType == "runes" or secondaryType == "essence" then
      mainFrame.fragmentedSecondaryType = secondaryType
      mainFrame.fragmentedConfig = cfg
      mainFrame.fragmentedTexturePath = texturePath
      
      if not mainFrame.fragmentedOnUpdate then
        mainFrame.fragmentedOnUpdate = function(self, elapsed)
          if not self.fragmentFrames or not self:IsShown() then return end
          -- Skip during preview — SetPreviewValue drives animation via UpdateThresholdLayers
          if IsOptionsOpen() then return end
          
          local secType = self.fragmentedSecondaryType
          local config = self.fragmentedConfig
          if not secType or not config then return end
          
          local data, num
          if secType == "runes" then
            data, num = ns.Resources.GetRuneCooldownDetails()
          elseif secType == "essence" then
            data, num = ns.Resources.GetEssenceCooldownDetails()
          end
          
          if not data then return end
          
          local showText = config.display.cdTextShow
          if showText == nil then showText = config.display.fragmentedShowSegmentText end
          local precision = config.display.cdTextDecimalPrecision or 0
          local fmt = "%." .. precision .. "f"
          
          local readyCount = 0
          for _, seg in ipairs(data) do
            if seg.ready then readyCount = readyCount + 1 end
          end
          local countColor = GetActiveCountColor(config, readyCount)
          
          for i = 1, num do
            local segFrame = self.fragmentFrames[i]
            
            if segFrame and data[i] then
              local fillPct = data[i].fillPercent or 0
              local ready = data[i].ready
              
              local col
              if ready then
                col = countColor or GetFragmentedReadyColor(config, i)
              else
                col = GetChargingColorForSegment(config, i)
              end
              
              segFrame.fill:SetStatusBarColor(col.r, col.g, col.b, col.a or 1)
              segFrame.fill:SetValue(fillPct, segFrame.fill._arcInterpolation)
              
              -- Update text
              if showText and not ready and data[i].start and data[i].duration and data[i].duration > 0 then
                local remaining = math.max(0, data[i].duration - (GetTime() - data[i].start))
                if remaining > 0 then
                  segFrame.cdText:SetText(string.format(fmt, remaining))
                  segFrame.cdText:Show()
                else
                  segFrame.cdText:Hide()
                end
              elseif showText and IsOptionsOpen() then
                local previewVal = 3.5 + (num - i) * 1.7
                segFrame.cdText:SetText(string.format(fmt, previewVal))
                segFrame.cdText:Show()
              else
                segFrame.cdText:Hide()
              end
            end
          end
        end
        mainFrame:SetScript("OnUpdate", mainFrame.fragmentedOnUpdate)
      end
    else
      -- Clear OnUpdate for non-cooldown resources
      mainFrame:SetScript("OnUpdate", nil)
      mainFrame.fragmentedOnUpdate = nil
    end
    
  elseif displayMode == "icons" then
    -- ═══════════════════════════════════════════════════════════════
    -- ICONS MODE: Individual square/circle icons for each segment
    -- For Runes (DK) and Essence (Evoker) displayed as separate icons
    -- Supports Row (horizontal line) and Freeform (draggable) layouts
    -- ═══════════════════════════════════════════════════════════════
    
    -- Hide other bar types
    if mainFrame.granularBars then
      for _, bar in ipairs(mainFrame.granularBars) do bar:Hide() end
    end
    if mainFrame.stackedBars then
      for _, bar in ipairs(mainFrame.stackedBars) do bar:Hide() end
    end
    if mainFrame.maxColorBar then
      mainFrame.maxColorBar:Hide()
    end
    -- Hide simple mode layers
    for i = 1, #mainFrame.layers do
      mainFrame.layers[i]:Hide()
    end
    -- Hide fragmented frames if they exist
    if mainFrame.fragmentFrames then
      for _, frame in ipairs(mainFrame.fragmentFrames) do frame:Hide() end
    end
    
    -- Hide main frame's background and borders (icons have their own)
    if mainFrame.bg then
      mainFrame.bg:Hide()
    end
    if mainFrame.borderOverlay then
      if mainFrame.borderOverlay.top then mainFrame.borderOverlay.top:Hide() end
      if mainFrame.borderOverlay.bottom then mainFrame.borderOverlay.bottom:Hide() end
      if mainFrame.borderOverlay.left then mainFrame.borderOverlay.left:Hide() end
      if mainFrame.borderOverlay.right then mainFrame.borderOverlay.right:Hide() end
      mainFrame.borderOverlay:Hide()
    end
    -- Hide charged overlays from continuous mode
    if mainFrame.chargedOverlays then
      for _, bar in ipairs(mainFrame.chargedOverlays) do bar:Hide() end
    end
    
    -- Get resource type from config
    local secondaryType = cfg.tracking.secondaryType
    local numIcons = maxValue
    local segmentData = nil
    local isPreview = IsOptionsOpen()
    
    -- Get per-segment cooldown data (skip during preview — use secretValue for animation)
    if not isPreview then
      if secondaryType == "runes" then
        segmentData, numIcons = ns.Resources.GetRuneCooldownDetails()
      elseif secondaryType == "essence" then
        segmentData, numIcons = ns.Resources.GetEssenceCooldownDetails()
      end
    end
    
    if not segmentData or numIcons <= 0 then
      numIcons = maxValue
    end
    
    -- Get colors
    local perSegmentColors = cfg.display.fragmentedColors or {}
    local barColor = cfg.display.barColor or ns.Resources.GetSecondaryResourceDefaultColor()
    local bgColor = cfg.display.backgroundColor or {r=0.1, g=0.1, b=0.1, a=0.8}
    local borderColor = cfg.display.borderColor or {r=0, g=0, b=0, a=1}
    local showBorder = cfg.display.showBorder
    local borderThickness = cfg.display.drawnBorderThickness or 2
    
    -- Icons settings
    local iconsMode = cfg.display.iconsMode or "row"
    local iconSize = cfg.display.iconsSize or 32
    local iconSpacing = cfg.display.iconsSpacing or 4
    local showCDText = cfg.display.cdTextShow
    if showCDText == nil then showCDText = cfg.display.iconsShowCooldownText end
    local iconCDTextSize = cfg.display.cdTextSize or cfg.display.iconsCooldownTextSize or 12
    local iconCDTextOffsetX = cfg.display.cdTextOffsetX or cfg.display.iconsCDTextOffsetX or 0
    local iconCDTextOffsetY = cfg.display.cdTextOffsetY or cfg.display.iconsCDTextOffsetY or 0
    local iconCDTextOutline = cfg.display.cdTextOutline or "OUTLINE"
    local iconCDTextPrecision = cfg.display.cdTextDecimalPrecision or 0
    local iconCDTextColor = cfg.display.cdTextColor or {r=1, g=1, b=1, a=1}
    local iconCDTextFontPath = STANDARD_TEXT_FONT
    if LSM and cfg.display.cdTextFont then
      iconCDTextFontPath = LSM:Fetch("font", cfg.display.cdTextFont) or STANDARD_TEXT_FONT
    end
    local savedPositions = cfg.display.iconsPositions or {}
    local iconShape = cfg.display.iconsShape or "square"
    local isTextureShape = TEXTURE_SHAPES[iconShape]
    local isFreeform = (iconsMode == "freeform")
    
    -- Prediction settings
    local iconShowPrediction = cfg.display.showPrediction
    local iconPredCostColor = cfg.display.predCostColor or {r=0, g=0, b=0, a=0.5}
    local iconPredGainColor = cfg.display.predGainColor or {r=1, g=1, b=1, a=0.3}
    local iconPredActive = iconShowPrediction and Prediction.active and secondaryType == "soulShards"
    
    -- Animacharged combo point support
    local chargedLookup = {}
    local chargedColor = nil
    if secondaryType == "comboPoints" then
      chargedLookup = ns.Resources.GetChargedComboPointLookup()
      chargedColor = cfg.display.chargedComboColor or ns.Resources.ChargedComboPointColor
    end
    
    -- Active count color conditioning (all icons same color based on active count)
    local activeCount = type(secretValue) == "number" and math.floor(secretValue) or secretValue
    if segmentData then
      activeCount = 0
      for _, seg in ipairs(segmentData) do
        if seg.ready then activeCount = activeCount + 1 end
      end
    end
    local activeCountColor = GetActiveCountColor(cfg, activeCount)
    
    -- Create icon frames container
    if not mainFrame.iconFrames then
      mainFrame.iconFrames = {}
    end
    
    -- Ensure we have enough icon frames
    while #mainFrame.iconFrames < numIcons do
      local idx = #mainFrame.iconFrames + 1
      
      -- Create container frame for this icon
      local iconFrame = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
      iconFrame:SetFrameLevel(mainFrame:GetFrameLevel() + 1)
      iconFrame.index = idx
      
      -- Background
      iconFrame.bg = iconFrame:CreateTexture(nil, "BACKGROUND")
      iconFrame.bg:SetAllPoints()
      
      -- Fill overlay (for cooldown progress)
      iconFrame.fill = iconFrame:CreateTexture(nil, "ARTWORK")
      iconFrame.fill:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT", 0, 0)
      iconFrame.fill:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 0, 0)
      
      -- Border textures
      iconFrame.borderTop = iconFrame:CreateTexture(nil, "OVERLAY")
      iconFrame.borderBottom = iconFrame:CreateTexture(nil, "OVERLAY")
      iconFrame.borderLeft = iconFrame:CreateTexture(nil, "OVERLAY")
      iconFrame.borderRight = iconFrame:CreateTexture(nil, "OVERLAY")
      
      -- Cooldown text
      iconFrame.cdText = iconFrame:CreateFontString(nil, "OVERLAY")
      iconFrame.cdText:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
      iconFrame.cdText:SetTextColor(1, 1, 1, 1)
      
      -- Prediction overlay (cost/gain indicator) - inset by border at render time
      iconFrame.predictFrame = CreateFrame("Frame", nil, iconFrame)
      iconFrame.predictFrame:SetFrameLevel(iconFrame:GetFrameLevel() + 3)
      iconFrame.predictFrame:SetAllPoints(iconFrame)
      iconFrame.predictOverlay = iconFrame.predictFrame:CreateTexture(nil, "OVERLAY")
      iconFrame.predictOverlay:SetAllPoints()
      iconFrame.predictOverlay:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
      iconFrame.predictOverlay:SetVertexColor(0, 0, 0, 0.5)
      iconFrame.predictFrame:Hide()
      
      -- Index label (shown only in freeform mode when options panel is open)
      iconFrame.indexLabel = iconFrame:CreateFontString(nil, "OVERLAY", nil, 7)
      iconFrame.indexLabel:SetPoint("TOP", iconFrame, "TOP", 0, -2)
      iconFrame.indexLabel:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
      iconFrame.indexLabel:SetTextColor(1, 0.82, 0, 1)  -- Gold
      iconFrame.indexLabel:SetText(tostring(idx))
      iconFrame.indexLabel:Hide()
      
      -- Make draggable in freeform mode
      iconFrame:SetMovable(true)
      iconFrame:EnableMouse(true)
      iconFrame:RegisterForDrag("LeftButton")
      
      iconFrame:SetScript("OnDragStart", function(self)
        local barNum = self:GetParent()._barNumber
        if not barNum then return end
        local resCfg = ns.API.GetResourceBarConfig(barNum)
        if resCfg and resCfg.display.iconsMode == "freeform" then
          self._isDragging = true
          self:StartMoving()
        end
      end)
      
      iconFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self._isDragging = false
        local barNum = self:GetParent()._barNumber
        if not barNum then return end
        local resCfg = ns.API.GetResourceBarConfig(barNum)
        if resCfg then
          if not resCfg.display.iconsPositions then
            resCfg.display.iconsPositions = {}
          end
          local point, _, relPoint, x, y = self:GetPoint(1)
          resCfg.display.iconsPositions[self.index] = {
            point = point,
            relPoint = relPoint,
            x = x,
            y = y
          }
        end
      end)
      
      table.insert(mainFrame.iconFrames, iconFrame)
    end
    
    -- Position and update each icon
    for i = 1, numIcons do
      local iconFrame = mainFrame.iconFrames[i]
      
      -- Size
      iconFrame:SetSize(iconSize, iconSize)
      
      -- Position based on layout mode
      -- Skip repositioning if this icon is actively being dragged
      if not iconFrame._isDragging then
        iconFrame:ClearAllPoints()
        if iconsMode == "freeform" and savedPositions[i] then
          -- Use saved position
          local pos = savedPositions[i]
          iconFrame:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER", pos.x or 0, pos.y or 0)
        elseif iconsMode == "freeform" then
          -- Default freeform position (spread out horizontally)
          local xOffset = (i - 1) * (iconSize + iconSpacing)
          iconFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", xOffset, 0)
        else
          -- Row mode - horizontal line
          local xOffset = (i - 1) * (iconSize + iconSpacing)
          iconFrame:SetPoint("LEFT", mainFrame, "LEFT", xOffset, 0)
        end
      end
      
      -- Get fill percentage for this icon
      local fillPercent = 0
      local isReady = false
      local cooldownRemaining = 0
      
      if segmentData and segmentData[i] then
        fillPercent = segmentData[i].fillPercent or 0
        isReady = segmentData[i].ready
        if not isReady and segmentData[i].start and segmentData[i].duration and segmentData[i].duration > 0 then
          local elapsed = GetTime() - segmentData[i].start
          cooldownRemaining = math.max(0, segmentData[i].duration - elapsed)
        end
      elseif secretValue >= i then
        fillPercent = 1
        isReady = true
      elseif secretValue > (i - 1) then
        fillPercent = secretValue - (i - 1)
        isReady = false
      else
        fillPercent = 0
        isReady = false
      end
      
      -- Get color for this icon
      local iconColor
      if chargedLookup[i] and chargedColor then
        -- Animacharged point: always show filled, bright if earned, dim if not
        fillPercent = 1
        if isReady then
          iconColor = chargedColor
        else
          iconColor = {r=chargedColor.r*0.5, g=chargedColor.g*0.5, b=chargedColor.b*0.5, a=chargedColor.a or 1}
        end
      elseif isReady then
        -- Priority: activeCountColor → perSegment → barColor
        iconColor = activeCountColor or GetFragmentedReadyColor(cfg, i)
      else
        iconColor = GetChargingColorForSegment(cfg, i)
      end
      
      -- Drag: only intercept mouse in freeform mode; row mode passes through to mainFrame
      iconFrame:EnableMouse(isFreeform)
      
      -- Index label: visible only in freeform mode when options panel is open
      if iconFrame.indexLabel then
        if isFreeform and IsOptionsOpen() then
          local labelSize = math.max(9, math.min(14, iconSize * 0.4))
          iconFrame.indexLabel:SetFont(STANDARD_TEXT_FONT, labelSize, "OUTLINE")
          iconFrame.indexLabel:Show()
        else
          iconFrame.indexLabel:Hide()
        end
      end
      
      -- Shape-aware rendering
      if isTextureShape then
        -- ── TEXTURE SHAPES (circle, lightning) ──
        -- Uses actual .blp/.tga files for crisp pixel-perfect shapes
        local fillTex = ICON_SHAPE_FILLS[iconShape]
        
        -- Background: shape texture in configured bg color (empty state)
        if cfg.display.showBackground ~= false then
          iconFrame.bg:SetTexture(fillTex)
          iconFrame.bg:SetVertexColor(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
          iconFrame.bg:ClearAllPoints()
          iconFrame.bg:SetAllPoints(iconFrame)
          iconFrame.bg:SetTexCoord(0, 1, 0, 1)
          iconFrame.bg:Show()
        else
          iconFrame.bg:Hide()
        end
        
        -- Fill: same shape texture, anchored bottom-to-top with TexCoord cropping
        -- This gives visual progress (filling up) like the square mode
        iconFrame.fill:SetTexture(fillTex)
        iconFrame.fill:SetVertexColor(iconColor.r, iconColor.g, iconColor.b, iconColor.a or 1)
        iconFrame.fill:SetAlpha(1)
        iconFrame.fill:ClearAllPoints()
        iconFrame.fill:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT", 0, 0)
        iconFrame.fill:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 0, 0)
        local fillHeight = math.max(0.1, iconSize * fillPercent)
        iconFrame.fill:SetHeight(fillHeight)
        -- Crop texture to show only the bottom portion matching fill level
        if fillPercent > 0 and fillPercent < 1 then
          iconFrame.fill:SetTexCoord(0, 1, 1 - fillPercent, 1)
        else
          iconFrame.fill:SetTexCoord(0, 1, 0, 1)
        end
        if fillPercent > 0 then
          iconFrame.fill:Show()
        else
          iconFrame.fill:Hide()
        end
        
        -- Border rendering: Square textures use 4-edge pixel borders (same as plain square)
        -- Circle textures use ring overlay textures (transparent centers)
        local isSquareTexture = SQUARE_TEXTURE_SHAPES[iconShape]
        
        -- Ensure ring border textures exist (for circles)
        if not iconFrame.drawnBorder then
          iconFrame.drawnBorder = iconFrame:CreateTexture(nil, "OVERLAY", nil, 5)
          iconFrame.drawnBorder:SetBlendMode("BLEND")
        else
          iconFrame.drawnBorder:SetDrawLayer("OVERLAY", 5)
        end
        if not iconFrame.shapeBorder then
          iconFrame.shapeBorder = iconFrame:CreateTexture(nil, "OVERLAY", nil, 5)
          iconFrame.shapeBorder:SetBlendMode("BLEND")
        end
        
        if isSquareTexture then
          -- Square texture shapes: 4-edge pixel borders (pixel-perfect, transparent-friendly)
          if iconFrame.drawnBorder then iconFrame.drawnBorder:Hide() end
          if iconFrame.shapeBorder then iconFrame.shapeBorder:Hide() end
          if showBorder then
            local bt = PixelUtil.GetNearestPixelSize(borderThickness, iconFrame:GetEffectiveScale(), 1)
            local br, bg2, bb, ba = borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1
            iconFrame.borderTop:SetSnapToPixelGrid(true)
            iconFrame.borderTop:SetTexelSnappingBias(1)
            iconFrame.borderBottom:SetSnapToPixelGrid(true)
            iconFrame.borderBottom:SetTexelSnappingBias(1)
            iconFrame.borderLeft:SetSnapToPixelGrid(true)
            iconFrame.borderLeft:SetTexelSnappingBias(1)
            iconFrame.borderRight:SetSnapToPixelGrid(true)
            iconFrame.borderRight:SetTexelSnappingBias(1)
            iconFrame.borderTop:ClearAllPoints()
            iconFrame.borderTop:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 0, 0)
            iconFrame.borderTop:SetPoint("TOPRIGHT", iconFrame, "TOPRIGHT", 0, 0)
            iconFrame.borderTop:SetHeight(bt)
            iconFrame.borderTop:SetColorTexture(br, bg2, bb, ba)
            iconFrame.borderTop:Show()
            iconFrame.borderBottom:ClearAllPoints()
            iconFrame.borderBottom:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT", 0, 0)
            iconFrame.borderBottom:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 0, 0)
            iconFrame.borderBottom:SetHeight(bt)
            iconFrame.borderBottom:SetColorTexture(br, bg2, bb, ba)
            iconFrame.borderBottom:Show()
            iconFrame.borderLeft:ClearAllPoints()
            iconFrame.borderLeft:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 0, -bt)
            iconFrame.borderLeft:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT", 0, bt)
            iconFrame.borderLeft:SetWidth(bt)
            iconFrame.borderLeft:SetColorTexture(br, bg2, bb, ba)
            iconFrame.borderLeft:Show()
            iconFrame.borderRight:ClearAllPoints()
            iconFrame.borderRight:SetPoint("TOPRIGHT", iconFrame, "TOPRIGHT", 0, -bt)
            iconFrame.borderRight:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 0, bt)
            iconFrame.borderRight:SetWidth(bt)
            iconFrame.borderRight:SetColorTexture(br, bg2, bb, ba)
            iconFrame.borderRight:Show()
          else
            iconFrame.borderTop:Hide()
            iconFrame.borderBottom:Hide()
            iconFrame.borderLeft:Hide()
            iconFrame.borderRight:Hide()
          end
        elseif CIRCLE_SHAPES[iconShape] then
          -- ── CIRCLES: ring texture overlay in OVERLAY layer ──
          -- Ring texture tinted to borderColor, sized so inner edge aligns with icon
          iconFrame.borderTop:Hide()
          iconFrame.borderBottom:Hide()
          iconFrame.borderLeft:Hide()
          iconFrame.borderRight:Hide()
          
          -- Ensure ring border texture exists
          if not iconFrame.drawnBorder then
            iconFrame.drawnBorder = iconFrame:CreateTexture(nil, "OVERLAY", nil, 5)
            iconFrame.drawnBorder:SetBlendMode("BLEND")
          else
            iconFrame.drawnBorder:SetDrawLayer("OVERLAY", 5)
          end
          
          if showBorder then
            local bt = borderThickness
            local br, bg2, bb, ba = borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1
            local ringTex, ringRatio = GetCircleRingForThickness(bt)
            iconFrame.drawnBorder:ClearAllPoints()
            iconFrame.drawnBorder:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
            iconFrame.drawnBorder:SetSize(iconSize * ringRatio, iconSize * ringRatio)
            iconFrame.drawnBorder:SetTexture(ringTex)
            iconFrame.drawnBorder:SetVertexColor(br, bg2, bb, ba)
            iconFrame.drawnBorder:Show()
          else
            iconFrame.drawnBorder:Hide()
          end
          if iconFrame.shapeBorder then iconFrame.shapeBorder:Hide() end
        else
          -- ── TRIANGLES and others: no separate border system ──
          -- Use triangleBorder shape variant for built-in borders
          iconFrame.borderTop:Hide()
          iconFrame.borderBottom:Hide()
          iconFrame.borderLeft:Hide()
          iconFrame.borderRight:Hide()
          if iconFrame.drawnBorder then iconFrame.drawnBorder:Hide() end
          if iconFrame.shapeBorder then iconFrame.shapeBorder:Hide() end
        end
      else
        -- ── SQUARE (drawn borders, fill bar bottom-to-top) ──
        -- Reset vertex color to white (texture shapes set it, which multiplies with SetColorTexture)
        if cfg.display.showBackground ~= false then
          iconFrame.bg:SetVertexColor(1, 1, 1, 1)
          iconFrame.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
          iconFrame.bg:ClearAllPoints()
          iconFrame.bg:SetAllPoints(iconFrame)
          iconFrame.bg:Show()
        else
          iconFrame.bg:Hide()
        end
        iconFrame.fill:SetVertexColor(1, 1, 1, 1)
        
        local fillHeight = iconSize * fillPercent
        iconFrame.fill:ClearAllPoints()
        iconFrame.fill:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT", 0, 0)
        iconFrame.fill:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 0, 0)
        iconFrame.fill:SetHeight(math.max(1, fillHeight))
        iconFrame.fill:SetColorTexture(iconColor.r, iconColor.g, iconColor.b, iconColor.a or 1)
        iconFrame.fill:SetTexCoord(0, 1, 0, 1)
        iconFrame.fill:SetAlpha(1)
        if fillPercent > 0 then
          iconFrame.fill:Show()
        else
          iconFrame.fill:Hide()
        end
        
        -- Hide texture/drawn borders if they exist
        if iconFrame.shapeBorder then iconFrame.shapeBorder:Hide() end
        if iconFrame.drawnBorder then iconFrame.drawnBorder:Hide() end
        
        -- Square drawn borders
        if showBorder then
          local bt = PixelUtil.GetNearestPixelSize(borderThickness, iconFrame:GetEffectiveScale(), 1)
          iconFrame.borderTop:SetSnapToPixelGrid(true)
          iconFrame.borderTop:SetTexelSnappingBias(1)
          iconFrame.borderBottom:SetSnapToPixelGrid(true)
          iconFrame.borderBottom:SetTexelSnappingBias(1)
          iconFrame.borderLeft:SetSnapToPixelGrid(true)
          iconFrame.borderLeft:SetTexelSnappingBias(1)
          iconFrame.borderRight:SetSnapToPixelGrid(true)
          iconFrame.borderRight:SetTexelSnappingBias(1)
          iconFrame.borderTop:ClearAllPoints()
          iconFrame.borderTop:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 0, 0)
          iconFrame.borderTop:SetPoint("TOPRIGHT", iconFrame, "TOPRIGHT", 0, 0)
          iconFrame.borderTop:SetHeight(bt)
          iconFrame.borderTop:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
          iconFrame.borderTop:Show()
          
          iconFrame.borderBottom:ClearAllPoints()
          iconFrame.borderBottom:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT", 0, 0)
          iconFrame.borderBottom:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 0, 0)
          iconFrame.borderBottom:SetHeight(bt)
          iconFrame.borderBottom:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
          iconFrame.borderBottom:Show()
          
          iconFrame.borderLeft:ClearAllPoints()
          iconFrame.borderLeft:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 0, -bt)
          iconFrame.borderLeft:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMLEFT", 0, bt)
          iconFrame.borderLeft:SetWidth(bt)
          iconFrame.borderLeft:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
          iconFrame.borderLeft:Show()
          
          iconFrame.borderRight:ClearAllPoints()
          iconFrame.borderRight:SetPoint("TOPRIGHT", iconFrame, "TOPRIGHT", 0, -bt)
          iconFrame.borderRight:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 0, bt)
          iconFrame.borderRight:SetWidth(bt)
          iconFrame.borderRight:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
          iconFrame.borderRight:Show()
        else
          iconFrame.borderTop:Hide()
          iconFrame.borderBottom:Hide()
          iconFrame.borderLeft:Hide()
          iconFrame.borderRight:Hide()
        end
      end
      
      -- Prediction overlay
      if iconFrame.predictFrame then
        if iconPredActive then
          local predState = Prediction:GetSegmentState(i, secretValue)
          if predState == "cost" or predState == "gain" then
            -- Inset prediction frame to fit inside borders
            local bt = showBorder and PixelUtil.GetNearestPixelSize(borderThickness, iconFrame:GetEffectiveScale(), 1) or 0
            iconFrame.predictFrame:ClearAllPoints()
            iconFrame.predictFrame:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", bt, -bt)
            iconFrame.predictFrame:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -bt, bt)
            iconFrame.predictOverlay:SetTexture(texturePath)
            if predState == "cost" then
              iconFrame.predictOverlay:SetVertexColor(iconPredCostColor.r, iconPredCostColor.g, iconPredCostColor.b, iconPredCostColor.a or 0.5)
            else
              local gainCol = activeCountColor or GetFragmentedReadyColor(cfg, i)
              iconFrame.predictOverlay:SetVertexColor(gainCol.r, gainCol.g, gainCol.b, iconPredGainColor.a or 0.3)
            end
            iconFrame.predictFrame:Show()
          else
            iconFrame.predictFrame:Hide()
          end
        else
          iconFrame.predictFrame:Hide()
        end
      end
      
      -- Update cooldown text
      iconFrame.cdText:SetFont(iconCDTextFontPath, iconCDTextSize, iconCDTextOutline)
      iconFrame.cdText:SetTextColor(iconCDTextColor.r, iconCDTextColor.g, iconCDTextColor.b, iconCDTextColor.a or 1)
      iconFrame.cdText:ClearAllPoints()
      iconFrame.cdText:SetPoint("CENTER", iconFrame, "CENTER", iconCDTextOffsetX, iconCDTextOffsetY)
      if showCDText and not isReady and cooldownRemaining > 0 then
        local fmt = "%." .. iconCDTextPrecision .. "f"
        iconFrame.cdText:SetText(string.format(fmt, cooldownRemaining))
        iconFrame.cdText:Show()
      elseif showCDText and IsOptionsOpen() then
        -- Preview: show fake countdown so user can see font/size/color/precision live
        local previewVal = 3.5 + (numIcons - i) * 1.7
        local fmt = "%." .. iconCDTextPrecision .. "f"
        iconFrame.cdText:SetText(string.format(fmt, previewVal))
        iconFrame.cdText:Show()
      else
        iconFrame.cdText:Hide()
      end
      
      iconFrame:Show()
    end
    
    -- Hide unused icons
    for i = numIcons + 1, #mainFrame.iconFrames do
      if mainFrame.iconFrames[i] then
        mainFrame.iconFrames[i]:Hide()
      end
    end
    
    -- Resize mainFrame to encompass all icons in row mode (enables drag)
    if not isFreeform and numIcons > 0 then
      local totalIconsWidth = (numIcons * iconSize) + ((numIcons - 1) * iconSpacing)
      mainFrame:SetSize(totalIconsWidth, iconSize)
    end
    
    -- Set up OnUpdate for animation
    if secondaryType == "runes" or secondaryType == "essence" then
      mainFrame.iconsSecondaryType = secondaryType
      mainFrame.iconsConfig = cfg
      
      if not mainFrame.iconsOnUpdate then
        mainFrame.iconsOnUpdate = function(self, elapsed)
          if not self.iconFrames or not self:IsShown() then return end
          -- Skip during preview — SetPreviewValue drives animation via UpdateThresholdLayers
          if IsOptionsOpen() then return end
          
          local secType = self.iconsSecondaryType
          local config = self.iconsConfig
          if not secType or not config then return end
          
          local data, num
          if secType == "runes" then
            data, num = ns.Resources.GetRuneCooldownDetails()
          elseif secType == "essence" then
            data, num = ns.Resources.GetEssenceCooldownDetails()
          end
          
          if not data then return end
          
          local showText = config.display.cdTextShow
          if showText == nil then showText = config.display.iconsShowCooldownText end
          local precision = config.display.cdTextDecimalPrecision or 0
          local fmt = "%." .. precision .. "f"
          local iSize = config.display.iconsSize or 32
          local iShape = config.display.iconsShape or "square"
          local isTextureShape = TEXTURE_SHAPES[iShape]
          
          local readyCount = 0
          for _, seg in ipairs(data) do
            if seg.ready then readyCount = readyCount + 1 end
          end
          local countColor = GetActiveCountColor(config, readyCount)
          
          for i = 1, num do
            local iconFrame = self.iconFrames[i]
            
            if iconFrame and data[i] then
              local fillPct = data[i].fillPercent or 0
              local ready = data[i].ready
              
              local col
              if ready then
                col = countColor or GetFragmentedReadyColor(config, i)
              else
                col = GetChargingColorForSegment(config, i)
              end
              
              -- Update fill
              if isTextureShape then
                -- Texture shapes: fill grows bottom-to-top with TexCoord cropping
                local fillH = math.max(0.1, iSize * fillPct)
                iconFrame.fill:SetHeight(fillH)
                iconFrame.fill:SetVertexColor(col.r, col.g, col.b, col.a or 1)
                iconFrame.fill:SetAlpha(1)
                if fillPct > 0 and fillPct < 1 then
                  iconFrame.fill:SetTexCoord(0, 1, 1 - fillPct, 1)
                else
                  iconFrame.fill:SetTexCoord(0, 1, 0, 1)
                end
                -- Background: configured bg color (not darkened icon color)
                local bColor = config.display.backgroundColor or {r=0.1, g=0.1, b=0.1, a=0.8}
                iconFrame.bg:SetVertexColor(bColor.r, bColor.g, bColor.b, bColor.a or 0.8)
              else
                -- Square: fill bar grows bottom-to-top
                -- Reset vertex color (texture shapes set it, multiplies with SetColorTexture)
                iconFrame.fill:SetVertexColor(1, 1, 1, 1)
                local fillH = iSize * fillPct
                iconFrame.fill:SetHeight(math.max(1, fillH))
                iconFrame.fill:SetColorTexture(col.r, col.g, col.b, col.a or 1)
              end
              if fillPct > 0 then
                iconFrame.fill:Show()
              else
                iconFrame.fill:Hide()
              end
              
              -- Update text
              if showText and not ready and data[i].start and data[i].duration and data[i].duration > 0 then
                local remaining = math.max(0, data[i].duration - (GetTime() - data[i].start))
                if remaining > 0 then
                  iconFrame.cdText:SetText(string.format(fmt, remaining))
                  iconFrame.cdText:Show()
                else
                  iconFrame.cdText:Hide()
                end
              elseif showText and IsOptionsOpen() then
                local previewVal = 3.5 + (num - i) * 1.7
                iconFrame.cdText:SetText(string.format(fmt, previewVal))
                iconFrame.cdText:Show()
              else
                iconFrame.cdText:Hide()
              end
            end
          end
        end
        mainFrame:SetScript("OnUpdate", mainFrame.iconsOnUpdate)
      end
    else
      mainFrame:SetScript("OnUpdate", nil)
      mainFrame.iconsOnUpdate = nil
    end
    
  elseif displayMode == "colorCurve" then
    -- ═══════════════════════════════════════════════════════════════
    -- COLORCURVE MODE: Single bar with dynamic color from ColorCurve API
    -- Uses UnitPowerPercent(unit, powerType, unmod, curve) which returns Color directly!
    -- Much simpler than multi-stacked bar approach, and fully secret-value safe.
    -- ═══════════════════════════════════════════════════════════════
    
    -- Hide all other bar types
    if mainFrame.fragmentFrames then
      for _, frame in ipairs(mainFrame.fragmentFrames) do frame:Hide() end
    end
    if mainFrame.iconFrames then
      for _, frame in ipairs(mainFrame.iconFrames) do frame:Hide() end
    end
    if mainFrame.granularBars then
      for _, bar in ipairs(mainFrame.granularBars) do bar:Hide() end
    end
    
    -- Get power type for ColorCurve
    local powerType = cfg.tracking.powerType
    -- For secondary resources, resolve powerType from the type definition
    if not powerType and isSecondaryResource then
      powerType = GetSecondaryPowerType()
    end
    
    -- Cache max power value when available (for numeric threshold conversion)
    if powerType and powerType >= 0 then
      CacheMaxPowerValue(powerType)
    end
    
    -- Get or create the ColorCurve
    local colorCurve = GetResourceColorCurve(barNumber, cfg, powerType)
    local baseColor = cfg.display.barColor or (thresholds[1] and thresholds[1].color) or {r=0, g=0.8, b=1, a=1}
    local bcR, bcG, bcB, bcA = SafeColorRGBA(baseColor, 0, 0.8, 1, 1)
    
    -- Get smoothing and orientation settings
    local enableSmooth = cfg.display.enableSmoothing
    local orientation = GetBarOrientation(cfg)
    local reverseFill = GetBarReverseFill(cfg)
    local isVertical = (orientation == "VERTICAL")
    
    -- Create stacked bars container if it doesn't exist
    if not mainFrame.stackedBars then
      mainFrame.stackedBars = {}
    end
    
    -- Ensure we have at least 1 bar
    if #mainFrame.stackedBars < 1 then
      local bar = CreateFrame("StatusBar", nil, mainFrame)
      bar:SetStatusBarTexture(texturePath)
      bar:SetOrientation(orientation)
      bar:SetReverseFill(reverseFill)
      bar:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
      table.insert(mainFrame.stackedBars, bar)
    end
    
    -- Hide any extra bars from other modes
    for i = 2, #mainFrame.stackedBars do
      mainFrame.stackedBars[i]:Hide()
    end
    
    -- Setup the single bar
    local bar = mainFrame.stackedBars[1]
    bar:ClearAllPoints()
    bar:SetAllPoints(mainFrame)
    bar:SetMinMaxValues(0, maxValue)
    bar:SetStatusBarTexture(texturePath)
    bar:SetOrientation(orientation)
    bar:SetReverseFill(reverseFill)
    bar:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
    bar:SetFrameLevel(mainFrame:GetFrameLevel() + 6)
    ApplyBarSmoothing(bar, enableSmooth)
    bar:SetValue(secretValue, bar._arcInterpolation)
    bar:Show()
    
    -- Get the bar texture for color application
    local barTexture = bar:GetStatusBarTexture()
    
    -- Apply color: secondary resources use direct threshold evaluation (UnitPowerPercent
    -- is designed for primary resources and unreliable for discrete secondary ones)
    if isSecondaryResource and type(secretValue) == "number" then
      -- Direct evaluation: compare secretValue against threshold settings numerically
      local directColor = EvaluateThresholdsDirectly(cfg, secretValue, maxValue)
      if directColor then
        local dR, dG, dB, dA = SafeColorRGBA(directColor)
        barTexture:SetVertexColor(dR, dG, dB, dA)
      else
        barTexture:SetVertexColor(bcR, bcG, bcB, bcA)
      end
    elseif colorCurve and powerType and powerType >= 0 then
      -- Primary resource: use UnitPowerPercent with ColorCurve (secret-safe)
      local colorOK = pcall(function()
        local colorResult = UnitPowerPercent("player", powerType, false, colorCurve)
        if colorResult and colorResult.GetRGBA then
          barTexture:SetVertexColor(colorResult:GetRGBA())
        else
          barTexture:SetVertexColor(bcR, bcG, bcB, bcA)
        end
      end)
      if not colorOK then
        barTexture:SetVertexColor(bcR, bcG, bcB, bcA)
      end
    else
      -- No color curve - use base color
      barTexture:SetVertexColor(bcR, bcG, bcB, bcA)
    end
    
    -- Max color is now part of the ColorCurve (injected as a step at 100%)
    -- Hide legacy maxColorBar if it exists from previous code
    if mainFrame.maxColorBar then
      mainFrame.maxColorBar:Hide()
    end
    
    -- Animacharged combo point overlays (painted on top at charged positions)
    ApplyChargedOverlays(mainFrame, cfg, maxValue, secretValue, texturePath, orientation, reverseFill, isVertical)
    
    -- Clear any OnUpdate handlers from other modes
    mainFrame:SetScript("OnUpdate", nil)
    mainFrame.fragmentedOnUpdate = nil
    mainFrame.iconsOnUpdate = nil
    
  elseif displayMode == "perStack" then
    -- ═══════════════════════════════════════════════════════════════
    -- SEGMENTED MODE: Multiple colored segments within one bar
    -- Each point/unit gets its own segment bar colored by range
    -- Range 1-2 yellow + Range 3-5 green = 2 yellow + 3 green segments
    -- ═══════════════════════════════════════════════════════════════
    
    -- Hide fragment frames if they exist
    if mainFrame.fragmentFrames then
      for _, frame in ipairs(mainFrame.fragmentFrames) do frame:Hide() end
    end
    -- Hide icon frames if they exist
    if mainFrame.iconFrames then
      for _, frame in ipairs(mainFrame.iconFrames) do frame:Hide() end
    end
    -- Clear any OnUpdate handlers from other modes
    mainFrame:SetScript("OnUpdate", nil)
    mainFrame.fragmentedOnUpdate = nil
    mainFrame.iconsOnUpdate = nil
    -- Hide charged overlays from continuous mode
    if mainFrame.chargedOverlays then
      for _, bar in ipairs(mainFrame.chargedOverlays) do bar:Hide() end
    end
    
    local baseColor = cfg.display.barColor or (thresholds[1] and thresholds[1].color) or {r=0, g=0.8, b=1, a=1}
    local enableMaxColor = cfg.display.enableMaxColor
    local maxColor = cfg.display.maxColor or {r=0, g=1, b=0, a=1}
    
    -- Animacharged combo point support
    local chargedLookup = {}
    local chargedColor = nil
    local secondaryType = cfg.tracking.secondaryType
    if secondaryType == "comboPoints" then
      chargedLookup = ns.Resources.GetChargedComboPointLookup()
      chargedColor = cfg.display.chargedComboColor or ns.Resources.ChargedComboPointColor
    end
    
    -- Active count color conditioning
    local activeCountColor = GetActiveCountColor(cfg, type(secretValue) == "number" and math.floor(secretValue) or 0)
    
    -- Get orientation settings
    local orientation = GetBarOrientation(cfg)
    local reverseFill = GetBarReverseFill(cfg)
    local isVertical = (orientation == "VERTICAL")
    
    -- Hide legacy maxColorBar if it exists
    if mainFrame.maxColorBar then
      mainFrame.maxColorBar:Hide()
    end
    
    -- Determine segment count (for secondary resources = discrete points)
    local segmentCount = maxValue
    if isSecondaryResource then
      segmentCount = math.floor(maxValue)
    end
    if segmentCount <= 0 then segmentCount = 1 end
    
    -- For primary resources with large maxValue (mana 100000+), fall back to single-bar mode
    if segmentCount > 30 then
      -- Too many segments, use single bar with stackColors lookup
      if not mainFrame.stackedBars then mainFrame.stackedBars = {} end
      if #mainFrame.stackedBars < 1 then
        local bar = CreateFrame("StatusBar", nil, mainFrame)
        bar:SetStatusBarTexture(texturePath)
        bar:SetOrientation(orientation)
        bar:SetReverseFill(reverseFill)
        bar:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
        table.insert(mainFrame.stackedBars, bar)
      end
      local bar1 = mainFrame.stackedBars[1]
      bar1:ClearAllPoints()
      bar1:SetAllPoints(mainFrame)
      bar1:SetMinMaxValues(0, maxValue)
      bar1:SetStatusBarTexture(texturePath)
      bar1:SetOrientation(orientation)
      bar1:SetReverseFill(reverseFill)
      bar1:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
      bar1:SetFrameLevel(mainFrame:GetFrameLevel() + 6)
      local enableSmooth = cfg.display.enableSmoothing
      ApplyBarSmoothing(bar1, enableSmooth)
      bar1:SetValue(secretValue, bar1._arcInterpolation)
      bar1:Show()
      bar1:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      for i = 2, #mainFrame.stackedBars do mainFrame.stackedBars[i]:Hide() end
    else
      -- MULTI-SEGMENT rendering for discrete resources
      -- Matches Display.lua granular bar pattern: 2-point anchoring + SetMinMaxValues(i-1, i)
      
      -- Build stackColors from colorRanges (lazy-init)
      if not cfg.stackColors then
        cfg.stackColors = {}
        if cfg.colorRanges then
          local ranges = cfg.colorRanges
          if ranges[1] then
            local fromVal = ranges[1].from or 1
            local toVal = ranges[1].to or segmentCount
            local color = ranges[1].color or baseColor
            for i = fromVal, math.min(toVal, segmentCount) do
              cfg.stackColors[i] = {r=color.r, g=color.g, b=color.b, a=color.a or 1}
            end
          end
          for rangeIdx = 2, 3 do
            if ranges[rangeIdx] and ranges[rangeIdx].enabled then
              local fromVal = ranges[rangeIdx].from or 1
              local toVal = ranges[rangeIdx].to or segmentCount
              local color = ranges[rangeIdx].color or {r=1, g=1, b=0, a=1}
              for i = fromVal, math.min(toVal, segmentCount) do
                cfg.stackColors[i] = {r=color.r, g=color.g, b=color.b, a=color.a or 1}
              end
            end
          end
        end
      end
      
      -- Create segment bars
      if not mainFrame.stackedBars then mainFrame.stackedBars = {} end
      
      -- Smoothing
      local enableSmooth = cfg.display.enableSmoothing
      
      -- Segment gap (built into segment size like Display.lua)
      local segGap = cfg.display.segmentedSpacing or 1
      local totalSize = isVertical and mainFrame:GetHeight() or mainFrame:GetWidth()
      local segmentSize = totalSize / segmentCount
      
      -- Current value for comparison
      -- Use raw secretValue for fractional resources (Destruction soul shards: 3.5 fills segment 4 to 50%)
      local currentVal = type(secretValue) == "number" and secretValue or 0
      
      -- At-max check
      local isAtMax = enableMaxColor and isSecondaryResource and type(secretValue) == "number" and secretValue >= maxValue and maxValue > 0
      
      for i = 1, segmentCount do
        -- Create bar if needed
        if not mainFrame.stackedBars[i] then
          local bar = CreateFrame("StatusBar", nil, mainFrame)
          bar:SetStatusBarTexture(texturePath)
          table.insert(mainFrame.stackedBars, bar)
        end
        
        local segBar = mainFrame.stackedBars[i]
        
        -- Setup orientation/texture
        segBar:SetOrientation(orientation)
        segBar:SetReverseFill(reverseFill)
        segBar:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
        segBar:SetStatusBarTexture(texturePath)
        segBar:SetFrameLevel(mainFrame:GetFrameLevel() + i)
        ApplyBarSmoothing(segBar, enableSmooth)
        
        -- 2-point anchoring (matches Display.lua pattern)
        segBar:ClearAllPoints()
        if isVertical then
          if reverseFill then
            -- Reverse: position from TOP (fills top-to-bottom)
            segBar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -(i - 1) * segmentSize)
            segBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -(i - 1) * segmentSize)
          else
            -- Normal: position from BOTTOM (fills bottom-to-top)
            segBar:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, (i - 1) * segmentSize)
            segBar:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, (i - 1) * segmentSize)
          end
          segBar:SetHeight(math.max(2, segmentSize - segGap))
        else
          if reverseFill then
            -- Reverse: position from RIGHT (fills right-to-left)
            segBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -(i - 1) * segmentSize, 0)
            segBar:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -(i - 1) * segmentSize, 0)
          else
            -- Normal: position from LEFT (fills left-to-right)
            segBar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", (i - 1) * segmentSize, 0)
            segBar:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", (i - 1) * segmentSize, 0)
          end
          segBar:SetWidth(math.max(2, segmentSize - segGap))
        end
        
        -- Use SetMinMaxValues(i-1, i) so StatusBar handles fill natively
        segBar:SetMinMaxValues(i - 1, i)
        
        -- Get color for this segment (charged > activeCount > atMax > stackColor > base)
        local segColor
        if chargedLookup[i] and chargedColor then
          segColor = chargedColor
        elseif activeCountColor then
          segColor = activeCountColor
        elseif isAtMax then
          segColor = maxColor
        elseif cfg.stackColors and cfg.stackColors[i] then
          segColor = cfg.stackColors[i]
        else
          segColor = baseColor
        end
        segBar:SetStatusBarColor(segColor.r, segColor.g, segColor.b, segColor.a or 1)
        
        -- Pass actual value - StatusBar fills automatically (0 at i-1, full at i)
        segBar:SetValue(currentVal)
        segBar:Show()
      end
      
      -- Hide extra bars beyond segmentCount
      for i = segmentCount + 1, #mainFrame.stackedBars do
        mainFrame.stackedBars[i]:Hide()
      end
    end
    
  else
    -- ═══════════════════════════════════════════════════════════════
    -- SIMPLE MODE: Single bar with optional max color via ColorCurve
    -- ═══════════════════════════════════════════════════════════════
    -- Bar 1: Full width, 0 to max - base color (tinted to maxColor at 100% via curve)
    
    -- Hide fragment frames if they exist
    if mainFrame.fragmentFrames then
      for _, frame in ipairs(mainFrame.fragmentFrames) do frame:Hide() end
    end
    -- Hide icon frames if they exist
    if mainFrame.iconFrames then
      for _, frame in ipairs(mainFrame.iconFrames) do frame:Hide() end
    end
    -- Clear any OnUpdate handlers from other modes
    mainFrame:SetScript("OnUpdate", nil)
    mainFrame.fragmentedOnUpdate = nil
    mainFrame.iconsOnUpdate = nil
    
    local baseColor = thresholds[1] and thresholds[1].color or {r=0, g=0.8, b=1, a=1}
    local enableMaxColor = cfg.display.enableMaxColor
    
    -- Get smoothing and orientation settings
    local enableSmooth = cfg.display.enableSmoothing
    local orientation = GetBarOrientation(cfg)
    local reverseFill = GetBarReverseFill(cfg)
    local isVertical = (orientation == "VERTICAL")
    
    -- Hide legacy maxColorBar if it exists
    if mainFrame.maxColorBar then
      mainFrame.maxColorBar:Hide()
    end
    
    -- Create stacked bars container if it doesn't exist
    if not mainFrame.stackedBars then
      mainFrame.stackedBars = {}
    end
    
    -- Ensure we have at least 1 bar
    if #mainFrame.stackedBars < 1 then
      local bar = CreateFrame("StatusBar", nil, mainFrame)
      bar:SetStatusBarTexture(texturePath)
      bar:SetOrientation(orientation)
      bar:SetReverseFill(reverseFill)
      bar:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
      table.insert(mainFrame.stackedBars, bar)
    end
    
    -- Single bar: 0 to max
    local bar1 = mainFrame.stackedBars[1]
    bar1:ClearAllPoints()
    bar1:SetAllPoints(mainFrame)
    bar1:SetMinMaxValues(0, maxValue)
    bar1:SetStatusBarTexture(texturePath)
    bar1:SetOrientation(orientation)
    bar1:SetReverseFill(reverseFill)
    bar1:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
    bar1:SetFrameLevel(mainFrame:GetFrameLevel() + 6)
    ApplyBarSmoothing(bar1, enableSmooth)
    bar1:SetValue(secretValue, bar1._arcInterpolation)
    bar1:Show()
    
    -- Apply color: max color curve via UnitPowerPercent, or static base color
    local powerType = cfg.tracking.powerType
    if enableMaxColor and isSecondaryResource and type(secretValue) == "number" then
      -- Secondary resource at-max: direct comparison (non-secret, avoids UnitPowerPercent login bugs)
      if secretValue >= maxValue and maxValue > 0 then
        local maxColor = cfg.display.maxColor or {r=0, g=1, b=0, a=1}
        bar1:SetStatusBarColor(maxColor.r, maxColor.g, maxColor.b, maxColor.a or 1)
      else
        bar1:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      end
    elseif enableMaxColor and powerType and powerType >= 0 then
      -- Primary resource: UnitPowerPercent curve (secret-safe)
      local maxCurve = GetMaxColorOnlyCurve(barNumber, cfg, baseColor, powerType)
      if maxCurve then
        local barTexture = bar1:GetStatusBarTexture()
        local colorOK = pcall(function()
          local colorResult = UnitPowerPercent("player", powerType, false, maxCurve)
          if colorResult and colorResult.GetRGBA then
            barTexture:SetVertexColor(colorResult:GetRGBA())
          else
            barTexture:SetVertexColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
          end
        end)
        if not colorOK then
          bar1:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
        end
      else
        bar1:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
      end
    else
      bar1:SetStatusBarColor(baseColor.r, baseColor.g, baseColor.b, baseColor.a or 1)
    end
    
    -- Hide any extra stacked bars from other modes
    for i = 2, #mainFrame.stackedBars do
      mainFrame.stackedBars[i]:Hide()
    end
    
    -- ═══════════════════════════════════════════════════════════════
    -- PREDICTION OVERLAYS (simple/continuous mode)
    -- Gain: StatusBar behind main bar shows where it'll fill to
    -- Cost: Texture overlay on top shows portion being consumed
    -- ═══════════════════════════════════════════════════════════════
    local showPred = cfg.display.showPrediction
    local predCostCol = cfg.display.predCostColor or {r=0, g=0, b=0, a=0.5}
    local predGainCol = cfg.display.predGainColor or {r=1, g=1, b=1, a=0.3}
    local predActive = showPred and Prediction.active and cfg.tracking.secondaryType == "soulShards"
    local currentVal = type(secretValue) == "number" and secretValue or 0
    
    if predActive and mainFrame.predGainBar and Prediction.gain > 0 then
      -- Gain bar: extends past main fill to show incoming shards
      local gainTarget = math.min(currentVal + Prediction.gain, maxValue)
      local gainColor = baseColor
      mainFrame.predGainBar:ClearAllPoints()
      mainFrame.predGainBar:SetAllPoints(mainFrame)
      mainFrame.predGainBar:SetMinMaxValues(0, maxValue)
      mainFrame.predGainBar:SetStatusBarTexture(texturePath)
      mainFrame.predGainBar:SetOrientation(orientation)
      mainFrame.predGainBar:SetReverseFill(reverseFill)
      mainFrame.predGainBar:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
      mainFrame.predGainBar:SetStatusBarColor(gainColor.r, gainColor.g, gainColor.b, predGainCol.a or 0.3)
      mainFrame.predGainBar:SetValue(gainTarget)
      mainFrame.predGainBar:Show()
    elseif mainFrame.predGainBar then
      mainFrame.predGainBar:Hide()
    end
    
    if predActive and mainFrame.predCostFrame and Prediction.cost > 0 then
      -- Cost overlay: positioned texture covering the "will be consumed" zone
      local afterCost = math.max(0, currentVal - Prediction.cost)
      local barWidth = mainFrame:GetWidth()
      local barHeight = mainFrame:GetHeight()
      
      mainFrame.predCostFrame:ClearAllPoints()
      mainFrame.predCostFrame:SetAllPoints(mainFrame)
      mainFrame.predCostTex:ClearAllPoints()
      mainFrame.predCostTex:SetTexture(texturePath)
      mainFrame.predCostTex:SetVertexColor(predCostCol.r, predCostCol.g, predCostCol.b, predCostCol.a or 0.5)
      
      if isVertical then
        local startPx, endPx
        if reverseFill then
          startPx = (afterCost / maxValue) * barHeight
          endPx = (currentVal / maxValue) * barHeight
          mainFrame.predCostTex:SetPoint("TOPLEFT", mainFrame.predCostFrame, "TOPLEFT", 0, -startPx)
          mainFrame.predCostTex:SetPoint("BOTTOMRIGHT", mainFrame.predCostFrame, "TOPRIGHT", 0, -endPx)
        else
          startPx = (afterCost / maxValue) * barHeight
          endPx = (currentVal / maxValue) * barHeight
          mainFrame.predCostTex:SetPoint("BOTTOMLEFT", mainFrame.predCostFrame, "BOTTOMLEFT", 0, startPx)
          mainFrame.predCostTex:SetPoint("TOPRIGHT", mainFrame.predCostFrame, "BOTTOMRIGHT", 0, endPx)
        end
      else
        local startPx, endPx
        if reverseFill then
          startPx = (1 - currentVal / maxValue) * barWidth
          endPx = (1 - afterCost / maxValue) * barWidth
          mainFrame.predCostTex:SetPoint("TOPLEFT", mainFrame.predCostFrame, "TOPLEFT", startPx, 0)
          mainFrame.predCostTex:SetPoint("BOTTOMRIGHT", mainFrame.predCostFrame, "TOPLEFT", endPx, -barHeight)
        else
          startPx = (afterCost / maxValue) * barWidth
          endPx = (currentVal / maxValue) * barWidth
          mainFrame.predCostTex:SetPoint("TOPLEFT", mainFrame.predCostFrame, "TOPLEFT", startPx, 0)
          mainFrame.predCostTex:SetPoint("BOTTOMRIGHT", mainFrame.predCostFrame, "TOPLEFT", endPx, -barHeight)
        end
      end
      mainFrame.predCostFrame:Show()
    elseif mainFrame.predCostFrame then
      mainFrame.predCostFrame:Hide()
    end
    
    -- Animacharged combo point overlays (painted on top at charged positions)
    ApplyChargedOverlays(mainFrame, cfg, maxValue, secretValue, texturePath, orientation, reverseFill, isVertical)
  end
end

-- ===================================================================
-- DRUID FORM VISIBILITY CHECK
-- Maps showInForms keys to GetShapeshiftFormID() results
-- Returns true if form is allowed (or no form restrictions set)
-- ===================================================================
local function IsDruidFormAllowed(cfg)
  if not cfg or not cfg.behavior then return true end
  local forms = cfg.behavior.showInForms
  if type(forms) ~= "table" then return true end
  
  -- If no forms selected, show in all forms
  local anySelected = false
  for _, v in pairs(forms) do
    if v then anySelected = true; break end
  end
  if not anySelected then return true end
  
  -- Check current form
  local formID = GetShapeshiftFormID()
  
  if not formID or formID == 0 then
    -- No form / caster form
    return forms.caster or false
  elseif formID == DRUID_CAT_FORM then
    return forms.cat or false
  elseif formID == DRUID_BEAR_FORM then
    return forms.bear or false
  elseif formID == DRUID_MOONKIN_FORM_1 or formID == DRUID_MOONKIN_FORM_2 then
    return forms.moonkin or false
  elseif formID == DRUID_TRAVEL_FORM or formID == DRUID_ACQUATIC_FORM or formID == DRUID_FLIGHT_FORM then
    return forms.travel or false
  elseif formID == DRUID_TREE_FORM or formID == 36 then
    -- Tree of Life (Treant Form uses formID 36)
    return forms.tree or false
  end
  
  -- Unknown form: show by default
  return true
end

-- ===================================================================
-- UPDATE RESOURCE BAR (Called on power events)
-- ===================================================================
function ns.Resources.UpdateBar(barNumber)
  local cfg = ns.API.GetResourceBarConfig(barNumber)
  if not cfg or not cfg.tracking.enabled then
    if resourceFrames[barNumber] then
      resourceFrames[barNumber].mainFrame:Hide()
      resourceFrames[barNumber].textFrame:Hide()
    end
    return
  end
  
  -- Check if options panel is open - bypass spec/talent checks to allow editing
  local optionsOpen = IsOptionsOpen()
  
  -- ═══════════════════════════════════════════════════════════════════
  -- EARLY SPEC CHECK - Don't create/update frames for wrong spec
  -- This prevents "phantom bars" from appearing on other specs
  -- (Bypassed when options panel is open for editing)
  -- ═══════════════════════════════════════════════════════════════════
  local currentSpec = GetSpecialization() or 0
  local showOnSpecs = cfg.behavior and cfg.behavior.showOnSpecs
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
  elseif cfg.behavior and cfg.behavior.showOnSpec and cfg.behavior.showOnSpec > 0 then
    -- Legacy single spec check
    specAllowed = (currentSpec == cfg.behavior.showOnSpec)
  end
  
  -- If wrong spec, hide existing frames and return early (unless options open)
  if not specAllowed and not optionsOpen then
    if resourceFrames[barNumber] then
      resourceFrames[barNumber].mainFrame:Hide()
      resourceFrames[barNumber].textFrame:Hide()
      -- Clear OnUpdate scripts to save CPU (fragmented/icons timers)
      resourceFrames[barNumber].mainFrame:SetScript("OnUpdate", nil)
      resourceFrames[barNumber].mainFrame.fragmentedOnUpdate = nil
      resourceFrames[barNumber].mainFrame.iconsOnUpdate = nil
    end
    return
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- TALENT CONDITION CHECK
  -- Hide bar if talent conditions not met (unless options panel is open)
  -- ═══════════════════════════════════════════════════════════════════
  local talentsMet = AreTalentConditionsMet(cfg)
  if not talentsMet and not optionsOpen then
    if resourceFrames[barNumber] then
      resourceFrames[barNumber].mainFrame:Hide()
      resourceFrames[barNumber].textFrame:Hide()
      -- Clear OnUpdate scripts to save CPU (fragmented/icons timers)
      resourceFrames[barNumber].mainFrame:SetScript("OnUpdate", nil)
      resourceFrames[barNumber].mainFrame.fragmentedOnUpdate = nil
      resourceFrames[barNumber].mainFrame.iconsOnUpdate = nil
    end
    return
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- DRUID FORM CHECK
  -- Hide bar if not in the selected shapeshift form (unless options open)
  -- ═══════════════════════════════════════════════════════════════════
  local _, playerClass = UnitClass("player")
  if playerClass == "DRUID" and not optionsOpen then
    if not IsDruidFormAllowed(cfg) then
      if resourceFrames[barNumber] then
        resourceFrames[barNumber].mainFrame:Hide()
        resourceFrames[barNumber].textFrame:Hide()
      end
      return
    end
  end
  
  local mainFrame, textFrame = GetResourceFrames(barNumber)
  
  -- ═══════════════════════════════════════════════════════════════════
  -- HIDEWHEN CONDITIONS (early return — skip all work when bar should be hidden)
  -- Bypass when options panel is open for editing.
  -- ═══════════════════════════════════════════════════════════════════
  if not optionsOpen and ns.CooldownBars and ns.CooldownBars.GetHideWhen then
    local hideWhen = ns.CooldownBars.GetHideWhen(cfg)
    if hideWhen and ns.CooldownBars.EvaluateHideConditions(hideWhen) then
      mainFrame:Hide()
      textFrame:Hide()
      return
    end
  end
  
  -- ═══════════════════════════════════════════════════════════════════
  -- DETERMINE RESOURCE TYPE (Primary vs Secondary)
  -- ═══════════════════════════════════════════════════════════════════
  local resourceCategory = cfg.tracking.resourceCategory or "primary"
  local secretValue, maxValue, displayValue, displayFormat
  
  if resourceCategory == "secondary" then
    -- SECONDARY RESOURCE (Combo Points, Runes, etc.)
    local secondaryType = cfg.tracking.secondaryType
    if not secondaryType then
      mainFrame:Hide()
      textFrame:Hide()
      return
    end
    
    local max, current, display, format = ns.Resources.GetSecondaryResourceValue(secondaryType)
    if not max or max <= 0 then
      mainFrame:Hide()
      textFrame:Hide()
      return
    end
    
    secretValue = current
    maxValue = max
    displayValue = display
    displayFormat = format
    
    -- Update stored max value if not overridden
    if not cfg.tracking.overrideMax then
      cfg.tracking.maxValue = maxValue
    else
      maxValue = cfg.tracking.maxValue or max
    end
  else
    -- PRIMARY RESOURCE (Mana, Rage, Energy, etc.)
    local powerType = cfg.tracking.powerType
    
    -- Guard: powerType must be valid (>= 0)
    if not powerType or powerType < 0 then
      mainFrame:Hide()
      textFrame:Hide()
      return
    end
    
    -- PRIMARY: Always use UnitPowerMax directly
    local unitMax = UnitPowerMax("player", powerType)
    maxValue = unitMax
    if not maxValue or maxValue <= 0 then
      maxValue = cfg.tracking.maxValue or 100
    end
    
    secretValue = UnitPower("player", powerType)
    displayValue = secretValue
    displayFormat = "number"
  end
  
  -- Update all threshold layers with the secret value AND maxValue
  UpdateThresholdLayers(barNumber, secretValue, maxValue)
  
  -- Update text (SetText handles secret values!)
  if cfg.display.showText then
    local textFormat = cfg.display.textFormat or "value"
    
    if textFormat == "percent" and cfg.tracking.resourceCategory ~= "secondary" then
      -- Percentage format using CurveConstants.ScaleTo100 for secret-safe 0-100 scaling
      local powerType = cfg.tracking.powerType
      if powerType and powerType >= 0 then
        -- CurveConstants.ScaleTo100 scales 0-1 to 0-100 internally (handles secrets!)
        local pct = UnitPowerPercent("player", powerType, false, CurveConstants.ScaleTo100)
        local pctFmt = (cfg.display.textShowPercentSymbol ~= false) and "%.0f%%" or "%.0f"
        textFrame.text:SetFormattedText(pctFmt, pct)
      else
        textFrame.text:SetText(secretValue)
      end
    elseif textFormat == "percent" and cfg.tracking.secondaryType == "stagger" then
      -- Stagger percentage: stagger / maxHealth * 100
      local pct = (maxValue and maxValue > 0) and (secretValue / maxValue * 100) or 0
      local pctFmt = (cfg.display.textShowPercentSymbol ~= false) and "%.0f%%" or "%.0f"
      textFrame.text:SetFormattedText(pctFmt, pct)
    elseif displayFormat == "decimal" then
      -- Format as decimal (e.g., Soul Shards for Destruction)
      textFrame.text:SetFormattedText("%.1f", displayValue)
    else
      -- Default: raw value
      textFrame.text:SetText(secretValue)
    end
    local tc = cfg.display.textColor
    textFrame.text:SetTextColor(tc.r, tc.g, tc.b, tc.a)
    
    -- Prediction text override (soul shards only, non-secret so we can format freely)
    local predTextFmt = cfg.display.predTextFormat or "none"
    if Prediction.active and predTextFmt ~= "none" and cfg.tracking.secondaryType == "soulShards" then
      local currentVal = type(secretValue) == "number" and math.floor(secretValue) or 0
      local predColor, predText
      
      if Prediction.cost > 0 then
        local afterCost = math.max(0, currentVal - Prediction.cost)
        predColor = cfg.display.predTextCostColor or {r=1, g=0.3, b=0.3}
        if predTextFmt == "arrow" then
          predText = currentVal .. " -> " .. afterCost
        elseif predTextFmt == "delta" then
          predText = currentVal .. " (-" .. Prediction.cost .. ")"
        elseif predTextFmt == "predicted" then
          predText = tostring(afterCost)
        end
      elseif Prediction.gain > 0 then
        local afterGain = math.min(currentVal + Prediction.gain, maxValue)
        predColor = cfg.display.predTextGainColor or {r=0.3, g=1, b=0.3}
        if predTextFmt == "arrow" then
          predText = currentVal .. " -> " .. afterGain
        elseif predTextFmt == "delta" then
          predText = currentVal .. " (+" .. Prediction.gain .. ")"
        elseif predTextFmt == "predicted" then
          predText = tostring(afterGain)
        end
      end
      
      if predText and predColor then
        textFrame.text:SetText(predText)
        textFrame.text:SetTextColor(predColor.r, predColor.g, predColor.b, 1)
      end
    end
    
    textFrame:Show()
  else
    textFrame:Hide()
  end
  
  -- Update tick marks for ability costs / discrete units
  -- Skip tick marks for fragmented/icons modes (each segment is its own frame)
  local displayMode_ticks = cfg.display.thresholdMode or "simple"
  if displayMode_ticks == "fragmented" or displayMode_ticks == "icons" then
    -- Force-hide all ticks for fragmented/icons
    for i = 1, 100 do
      if mainFrame.tickMarks[i] then
        mainFrame.tickMarks[i]:Hide()
      end
    end
  elseif cfg.display.showTickMarks then
    local width = mainFrame:GetWidth()
    local height = mainFrame:GetHeight()
    local isVertical = (GetBarOrientation(cfg) == "VERTICAL")
    local isReverseFill = GetBarReverseFill(cfg)
    local tickIndex = 1
    
    -- Tick positions use full frame dimensions — bar1:SetAllPoints(mainFrame)
    -- means the fill occupies the same space, border is overlaid at higher level
    
    -- For folded mode, ticks are based on midpoint
    local tickMaxValue = maxValue
    local displayMode = cfg.display.thresholdMode or "simple"
    if displayMode == "folded" then
      tickMaxValue = math.ceil(maxValue / 2)
    end
    
    local tickMode = cfg.display.tickMode or "percent"
    local tickPositions = {}
    
    if tickMode == "all" then
      -- All mode: one tick per unit division (for small max values like combo points)
      -- Cap at 50 ticks to avoid performance issues with large resources
      if tickMaxValue <= 50 then
        for i = 1, tickMaxValue - 1 do
          table.insert(tickPositions, i)
        end
      else
        -- For large values, fall back to 10 evenly spaced ticks
        for i = 1, 9 do
          table.insert(tickPositions, math.floor(tickMaxValue * i / 10))
        end
      end
    elseif tickMode == "percent" then
      -- Percent mode: ticks at percentage intervals (exclude 100% = rightmost edge)
      local tickPercent = cfg.display.tickPercent or 10
      local numTicks = math.floor(100 / tickPercent)
      for i = 1, numTicks do
        local tickVal = math.floor(tickMaxValue * (i * tickPercent / 100))
        if tickVal > 0 and tickVal < tickMaxValue then
          table.insert(tickPositions, tickVal)
        end
      end
    elseif tickMode == "custom" and cfg.abilityThresholds and #cfg.abilityThresholds > 0 then
      -- Custom tick positions from abilityThresholds
      local usePercent = cfg.display.customTicksAsPercent
      for _, ability in ipairs(cfg.abilityThresholds) do
        if ability.enabled and ability.cost and ability.cost > 0 then
          local tickVal = ability.cost
          if usePercent then
            -- Interpret cost as percentage
            tickVal = math.floor(tickMaxValue * ability.cost / 100)
          end
          if tickVal > 0 and tickVal < tickMaxValue then
            table.insert(tickPositions, tickVal)
          end
        end
      end
    end
    
    -- Render tick marks anchored to the fill bar (same space as fill, no border offset needed)
    -- Matches Sensei's approach: anchor LEFT/BOTTOM edge at division point, use SetSize for span
    local thickness = cfg.display.tickThickness or 2
    local tc = cfg.display.tickColor or {r=1, g=1, b=1, a=0.8}
    
    for _, tickValue in ipairs(tickPositions) do
      if mainFrame.tickMarks[tickIndex] then
        local tick = mainFrame.tickMarks[tickIndex]
        local pixelThickness = PixelUtil.GetNearestPixelSize(thickness, mainFrame:GetEffectiveScale(), thickness)
        
        tick:ClearAllPoints()
        tick:SetColorTexture(tc.r, tc.g, tc.b, tc.a or 1)
        
        if isVertical then
          local rawY = (tickValue / tickMaxValue) * height
          tick:SetSize(width, pixelThickness)
          if isReverseFill then
            tick:SetPoint("TOP", mainFrame.tickOverlay, "TOP", 0, -rawY)
          else
            tick:SetPoint("BOTTOM", mainFrame.tickOverlay, "BOTTOM", 0, rawY)
          end
        else
          local rawX = (tickValue / tickMaxValue) * width
          tick:SetSize(pixelThickness, height)
          if isReverseFill then
            tick:SetPoint("RIGHT", mainFrame.tickOverlay, "RIGHT", -rawX, 0)
          else
            tick:SetPoint("LEFT", mainFrame.tickOverlay, "LEFT", rawX, 0)
          end
        end
        
        tick:Show()
        tickIndex = tickIndex + 1
      end
    end
    
    -- Hide unused ticks
    for i = tickIndex, 100 do
      if mainFrame.tickMarks[i] then
        mainFrame.tickMarks[i]:Hide()
      end
    end
  else
    -- Hide all ticks
    for i = 1, 100 do
      if mainFrame.tickMarks[i] then
        mainFrame.tickMarks[i]:Hide()
      end
    end
  end
  
  -- Show bar (hideWhen already checked at top of function)
  if cfg.display.enabled then
    mainFrame:Show()
  else
    mainFrame:Hide()
    textFrame:Hide()
  end
end

-- ===================================================================
-- APPLY APPEARANCE
-- ===================================================================
function ns.Resources.ApplyAppearance(barNumber)
  local cfg = ns.API.GetResourceBarConfig(barNumber)
  if not cfg then return end
  
  -- CRITICAL: Don't create frames or show bars that aren't tracking anything.
  -- This prevents ghost bars from appearing on characters with no resource bars.
  if not cfg.tracking.enabled then
    -- Only hide if frames already exist (don't create them just to hide them)
    if resourceFrames[barNumber] then
      resourceFrames[barNumber].mainFrame:Hide()
      resourceFrames[barNumber].textFrame:Hide()
    end
    return
  end
  
  -- Check if options panel is open - bypass spec/talent checks to allow editing
  local optionsOpen = IsOptionsOpen()
  
  -- Early spec check - don't apply appearance for wrong spec bars (unless options open)
  local currentSpec = GetSpecialization() or 0
  local showOnSpecs = cfg.behavior and cfg.behavior.showOnSpecs
  local specAllowed = true
  
  if showOnSpecs and #showOnSpecs > 0 then
    specAllowed = false
    for _, spec in ipairs(showOnSpecs) do
      if spec == currentSpec then
        specAllowed = true
        break
      end
    end
  elseif cfg.behavior and cfg.behavior.showOnSpec and cfg.behavior.showOnSpec > 0 then
    specAllowed = (currentSpec == cfg.behavior.showOnSpec)
  end
  
  -- If wrong spec, just hide any existing frames and return (unless options open)
  if not specAllowed and not optionsOpen then
    if resourceFrames[barNumber] then
      resourceFrames[barNumber].mainFrame:Hide()
      resourceFrames[barNumber].textFrame:Hide()
    end
    return
  end
  
  -- Druid form check
  local _, playerClass = UnitClass("player")
  if playerClass == "DRUID" and not optionsOpen then
    if not IsDruidFormAllowed(cfg) then
      if resourceFrames[barNumber] then
        resourceFrames[barNumber].mainFrame:Hide()
        resourceFrames[barNumber].textFrame:Hide()
      end
      return
    end
  end
  
  local mainFrame, textFrame = GetResourceFrames(barNumber)
  local display = cfg.display
  
  -- Size - SWAP width and height for vertical orientation
  local isVertical = (display.barOrientation == "vertical")
  local isFragmented = (display.thresholdMode == "fragmented")
  local isFragmentedVertical = (isFragmented and display.fragmentedLayoutDirection == "vertical")
  -- Fragmented mode uses its own layout direction exclusively (ignore barOrientation)
  local needsSwap = isFragmented and isFragmentedVertical or (not isFragmented and isVertical)
  local scale = display.barScale or 1.0
  local scaledWidth = display.width * scale
  local scaledHeight = display.height * scale
  
  if needsSwap then
    mainFrame:SetSize(scaledHeight, scaledWidth)  -- Swap dimensions for vertical!
  else
    mainFrame:SetSize(scaledWidth, scaledHeight)  -- Normal horizontal
  end
  
  -- NOTE: We apply scale to SIZE instead of SetScale() to avoid anchor drift
  -- mainFrame:SetScale(display.barScale or 1.0)  -- REMOVED - scale applied to size above
  mainFrame:SetAlpha(display.opacity or 1.0)
  
  -- Frame strata and level
  local strata = display.barFrameStrata or "HIGH"
  mainFrame:SetFrameStrata(strata)
  textFrame:SetFrameStrata(strata)
  
  local level = display.barFrameLevel or 10
  mainFrame:SetFrameLevel(level)
  textFrame:SetFrameLevel(level + 100)
  
  -- Update layer levels
  if mainFrame.layers then
    for i, layer in ipairs(mainFrame.layers) do
      layer:SetFrameLevel(level + i)
    end
  end
  if mainFrame.fragmentFrames then
    for i, segFrame in ipairs(mainFrame.fragmentFrames) do
      segFrame:SetFrameLevel(level + 1)
      if segFrame.fill then segFrame.fill:SetFrameLevel(level + 2) end
    end
  end
  if mainFrame.iconFrames then
    for i, iconFrame in ipairs(mainFrame.iconFrames) do
      iconFrame:SetFrameLevel(level + 1)
    end
  end
  if mainFrame.tickOverlay then mainFrame.tickOverlay:SetFrameLevel(level + 50) end
  if mainFrame.borderOverlay then mainFrame.borderOverlay:SetFrameLevel(level + 51) end
  if mainFrame.deleteButton then mainFrame.deleteButton:SetFrameLevel(level + 60) end
  
  -- Position - check for CDM Group anchor first
  local anchoredToGroup = false
  if display.anchorToGroup and display.anchorGroupName then
    local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[display.anchorGroupName]
    if group and group.container then
      local container = group.container
      local anchorPoint = display.anchorPoint or "BOTTOM"
      local offsetX = display.anchorOffsetX or 0
      local offsetY = display.anchorOffsetY or 0
      
      mainFrame:ClearAllPoints()
      if anchorPoint == "TOP" then
        mainFrame:SetPoint("BOTTOM", container, "TOP", offsetX, offsetY)
      elseif anchorPoint == "BOTTOM" then
        mainFrame:SetPoint("TOP", container, "BOTTOM", offsetX, offsetY)
      elseif anchorPoint == "LEFT" then
        mainFrame:SetPoint("RIGHT", container, "LEFT", offsetX, offsetY)
      elseif anchorPoint == "RIGHT" then
        mainFrame:SetPoint("LEFT", container, "RIGHT", offsetX, offsetY)
      end
      
      -- Match size to container if enabled
      -- TOP/BOTTOM: bar width = container width
      -- LEFT/RIGHT: bar width = container height
      if display.matchGroupWidth then
        local containerWidth = container:GetWidth()
        local containerHeight = container:GetHeight()
        local isSideAnchor = (anchorPoint == "LEFT" or anchorPoint == "RIGHT")
        
        -- Use container height for side anchors, container width for top/bottom
        local matchDimension = isSideAnchor and containerHeight or containerWidth
        
        if matchDimension and matchDimension > 0 then
          local sizeAdjust = display.matchWidthAdjust or 0
          local barWidth = matchDimension + sizeAdjust
          local barHeight = display.height * scale
          
          -- Swap for vertical orientation or fragmented vertical layout
          if needsSwap then
            mainFrame:SetSize(barHeight, barWidth)
          else
            mainFrame:SetSize(barWidth, barHeight)
          end
        end
        
        -- Hook the container's OnSizeChanged event
        mainFrame._anchoredGroupName = display.anchorGroupName
        mainFrame._anchoredBarNumber = barNumber
        if ns.Resources.HookContainerForAnchoredBars then
          ns.Resources.HookContainerForAnchoredBars(display.anchorGroupName)
        end
      else
        mainFrame._anchoredGroupName = nil
      end
      
      anchoredToGroup = true
    end
  end
  
  -- Fallback to normal position if not anchored
  if not anchoredToGroup and display.barPosition then
    mainFrame:ClearAllPoints()
    mainFrame:SetPoint(
      display.barPosition.point,
      UIParent,
      display.barPosition.relPoint,
      display.barPosition.x,
      display.barPosition.y
    )
    mainFrame._anchoredGroupName = nil
  end
  
  -- Text font and sizing (MUST happen before anchor positioning)
  local fontName = display.font or "2002 Bold"
  local fontSize = display.fontSize or 20
  local outline = display.textOutline or "THICKOUTLINE"
  local font = (LSM and LSM:Fetch("font", fontName)) or "Fonts\\FRIZQT__.TTF"
  textFrame.text:SetFont(font, fontSize, outline)
  
  -- Apply text shadow setting
  if display.textShadow then
    textFrame.text:SetShadowOffset(2, -2)
    textFrame.text:SetShadowColor(0, 0, 0, 1)
  else
    textFrame.text:SetShadowOffset(0, 0)
  end
  
  -- Size frame based on fontSize (avoid secret value issues with GetStringWidth)
  -- Wider estimate if prediction text is enabled (e.g. "3 -> 1" needs more room)
  local predFmt = display.predTextFormat or "none"
  local widthMultiplier = (predFmt ~= "none") and 6 or 3
  local estimatedWidth = fontSize * widthMultiplier
  local estimatedHeight = fontSize + 4
  textFrame:SetSize(estimatedWidth, estimatedHeight)
  
  -- Text positioning - either anchored to bar or free-floating
  local textAnchor = display.textAnchor or "FREE"
  if textAnchor ~= "FREE" then
    -- Anchor text to bar edge points
    textFrame:ClearAllPoints()
    local offsetX = display.textAnchorOffsetX or 0
    local offsetY = display.textAnchorOffsetY or 0
    local padding = 5  -- Small padding from edge for visual clarity
    
    -- Inner anchors (text inside bar)
    if textAnchor == "CENTER" then
      textFrame:SetPoint("CENTER", mainFrame, "CENTER", offsetX, offsetY)
    elseif textAnchor == "RIGHT" or textAnchor == "CENTERRIGHT" then
      textFrame:SetPoint("CENTER", mainFrame, "RIGHT", -padding + offsetX, offsetY)
    elseif textAnchor == "LEFT" or textAnchor == "CENTERLEFT" then
      textFrame:SetPoint("CENTER", mainFrame, "LEFT", padding + offsetX, offsetY)
    elseif textAnchor == "TOP" then
      textFrame:SetPoint("CENTER", mainFrame, "TOP", offsetX, -padding + offsetY)
    elseif textAnchor == "BOTTOM" then
      textFrame:SetPoint("CENTER", mainFrame, "BOTTOM", offsetX, padding + offsetY)
    elseif textAnchor == "TOPLEFT" then
      textFrame:SetPoint("CENTER", mainFrame, "TOPLEFT", padding + offsetX, -padding + offsetY)
    elseif textAnchor == "TOPRIGHT" then
      textFrame:SetPoint("CENTER", mainFrame, "TOPRIGHT", -padding + offsetX, -padding + offsetY)
    elseif textAnchor == "BOTTOMLEFT" then
      textFrame:SetPoint("CENTER", mainFrame, "BOTTOMLEFT", padding + offsetX, padding + offsetY)
    elseif textAnchor == "BOTTOMRIGHT" then
      textFrame:SetPoint("CENTER", mainFrame, "BOTTOMRIGHT", -padding + offsetX, padding + offsetY)
    -- Outer anchors (text outside bar, touching the border)
    -- Use -20 for right-side outers, +20 for left-side outers to compensate for text centering
    elseif textAnchor == "OUTERRIGHT" or textAnchor == "OUTERCENTERRIGHT" then
      textFrame:SetPoint("LEFT", mainFrame, "RIGHT", -20 + offsetX, offsetY)
    elseif textAnchor == "OUTERLEFT" or textAnchor == "OUTERCENTERLEFT" then
      textFrame:SetPoint("RIGHT", mainFrame, "LEFT", 20 + offsetX, offsetY)
    elseif textAnchor == "OUTERTOP" then
      textFrame:SetPoint("BOTTOM", mainFrame, "TOP", offsetX, offsetY)
    elseif textAnchor == "OUTERBOTTOM" then
      textFrame:SetPoint("TOP", mainFrame, "BOTTOM", offsetX, offsetY)
    elseif textAnchor == "OUTERTOPLEFT" then
      textFrame:SetPoint("BOTTOMRIGHT", mainFrame, "TOPLEFT", 20 + offsetX, offsetY)
    elseif textAnchor == "OUTERTOPRIGHT" then
      textFrame:SetPoint("BOTTOMLEFT", mainFrame, "TOPRIGHT", -20 + offsetX, offsetY)
    elseif textAnchor == "OUTERBOTTOMLEFT" then
      textFrame:SetPoint("TOPRIGHT", mainFrame, "BOTTOMLEFT", 20 + offsetX, offsetY)
    elseif textAnchor == "OUTERBOTTOMRIGHT" then
      textFrame:SetPoint("TOPLEFT", mainFrame, "BOTTOMRIGHT", -20 + offsetX, offsetY)
    else
      -- Fallback
      textFrame:SetPoint("CENTER", mainFrame, "CENTER", offsetX, offsetY)
    end
  elseif display.textPosition then
    textFrame:ClearAllPoints()
    textFrame:SetPoint(
      display.textPosition.point,
      UIParent,
      display.textPosition.relPoint,
      display.textPosition.x,
      display.textPosition.y
    )
  end
  
  -- Background - fills entire frame like MWRB
  -- Skip if in fragmented/icons mode (each segment has its own background)
  local isFragmented = display.thresholdMode == "fragmented"
  local isIconsMode = display.thresholdMode == "icons"
  
  if display.showBackground and not isFragmented and not isIconsMode then
    local bg = display.backgroundColor
    local bgTextureName = display.backgroundTexture or "Solid"
    
    -- Background fills entire frame (SetAllPoints) like MWRB
    mainFrame.bg:ClearAllPoints()
    mainFrame.bg:SetAllPoints(mainFrame)
    
    if bgTextureName == "Solid" then
      mainFrame.bg:SetColorTexture(bg.r, bg.g, bg.b, bg.a)
    else
      -- Try to fetch from LSM background type
      local bgTexture = LSM and LSM:Fetch("background", bgTextureName)
      if bgTexture then
        mainFrame.bg:SetTexture(bgTexture)
        mainFrame.bg:SetVertexColor(bg.r, bg.g, bg.b, bg.a)
      else
        mainFrame.bg:SetColorTexture(bg.r, bg.g, bg.b, bg.a)
      end
    end
    mainFrame.bg:Show()
  else
    mainFrame.bg:Hide()
  end
  
  -- Border - draw around entire frame using 4 manual textures for pixel-perfect borders
  -- For fragmented/icons with spacing>0, each segment has its own border (drawn in UpdateThresholdLayers)
  -- For fragmented with spacing=0, unified border is drawn in UpdateThresholdLayers
  if display.showBorder and not isFragmented and not isIconsMode then
    local bt = PixelUtil.GetNearestPixelSize(display.drawnBorderThickness or 2, mainFrame:GetEffectiveScale(), 1)
    local bc = display.borderColor
    
    -- Enable pixel grid snapping on border textures
    mainFrame.borderOverlay.top:SetSnapToPixelGrid(true)
    mainFrame.borderOverlay.top:SetTexelSnappingBias(1)
    mainFrame.borderOverlay.bottom:SetSnapToPixelGrid(true)
    mainFrame.borderOverlay.bottom:SetTexelSnappingBias(1)
    mainFrame.borderOverlay.left:SetSnapToPixelGrid(true)
    mainFrame.borderOverlay.left:SetTexelSnappingBias(1)
    mainFrame.borderOverlay.right:SetSnapToPixelGrid(true)
    mainFrame.borderOverlay.right:SetTexelSnappingBias(1)
    
    -- Top border (spans full width at top)
    mainFrame.borderOverlay.top:ClearAllPoints()
    mainFrame.borderOverlay.top:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, 0)
    mainFrame.borderOverlay.top:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, 0)
    mainFrame.borderOverlay.top:SetHeight(bt)
    mainFrame.borderOverlay.top:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
    mainFrame.borderOverlay.top:Show()
    
    -- Bottom border (spans full width at bottom)
    mainFrame.borderOverlay.bottom:ClearAllPoints()
    mainFrame.borderOverlay.bottom:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, 0)
    mainFrame.borderOverlay.bottom:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
    mainFrame.borderOverlay.bottom:SetHeight(bt)
    mainFrame.borderOverlay.bottom:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
    mainFrame.borderOverlay.bottom:Show()
    
    -- Left border (between top and bottom borders)
    mainFrame.borderOverlay.left:ClearAllPoints()
    mainFrame.borderOverlay.left:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -bt)
    mainFrame.borderOverlay.left:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, bt)
    mainFrame.borderOverlay.left:SetWidth(bt)
    mainFrame.borderOverlay.left:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
    mainFrame.borderOverlay.left:Show()
    
    -- Right border (between top and bottom borders)
    mainFrame.borderOverlay.right:ClearAllPoints()
    mainFrame.borderOverlay.right:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -bt)
    mainFrame.borderOverlay.right:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, bt)
    mainFrame.borderOverlay.right:SetWidth(bt)
    mainFrame.borderOverlay.right:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
    mainFrame.borderOverlay.right:Show()
    
    mainFrame.borderOverlay:Show()
  else
    if mainFrame.borderOverlay.top then mainFrame.borderOverlay.top:Hide() end
    if mainFrame.borderOverlay.bottom then mainFrame.borderOverlay.bottom:Hide() end
    if mainFrame.borderOverlay.left then mainFrame.borderOverlay.left:Hide() end
    if mainFrame.borderOverlay.right then mainFrame.borderOverlay.right:Hide() end
    mainFrame.borderOverlay:Hide()
  end
  
  -- Texture for all layers (positioning is done in UpdateThresholdLayers)
  for i = 1, 5 do
    local layer = mainFrame.layers[i]
    
    -- Position to span full bar like MWRB (SetAllPoints)
    layer:ClearAllPoints()
    layer:SetAllPoints(mainFrame)
    
    if LSM and display.texture then
      local texture = LSM:Fetch("statusbar", display.texture)
      if texture then
        layer:SetStatusBarTexture(texture)
      end
    end
    
    -- Fill direction - use barOrientation and barReverseFill
    local isVertical = (display.barOrientation == "vertical")
    layer:SetOrientation(isVertical and "VERTICAL" or "HORIZONTAL")
    layer:SetReverseFill(display.barReverseFill or false)
    -- Rotate texture to match fill direction
    layer:SetRotatesTexture((cfg.display.rotateTexture == true) or (cfg.display.rotateTexture ~= false and isVertical))
  end
  
  -- Movability
  mainFrame:EnableMouse(display.barMovable)
  -- textLocked: true=locked, false=draggable, nil(existing users)=locked
  textFrame:EnableMouse(display.textLocked == false)
  
  -- Refresh display
  ns.Resources.UpdateBar(barNumber)
end

-- ===================================================================
-- HIDE BAR
-- ===================================================================
function ns.Resources.HideBar(barNumber)
  if resourceFrames[barNumber] then
    resourceFrames[barNumber].mainFrame:Hide()
    resourceFrames[barNumber].textFrame:Hide()
  end
end

-- ===================================================================
-- UPDATE ALL RESOURCE BARS
-- ===================================================================
function ns.Resources.UpdateAllBars()
  local activeBars = ns.API.GetActiveResourceBars()
  for _, barNumber in ipairs(activeBars) do
    ns.Resources.UpdateBar(barNumber)
  end
end

-- ===================================================================
-- REFRESH VISIBILITY (for hideWhen state changes: mount, target, etc.)
-- Called via CDMGroups.UpdateGroupVisibility hook.
-- ===================================================================
function ns.Resources.RefreshVisibility()
  if not ns.API or not ns.API.GetActiveResourceBars then return end
  ns.Resources.UpdateAllBars()
end

-- ===================================================================
-- APPLY ALL BARS
-- ===================================================================
function ns.Resources.ApplyAllBars(nudgeLayout)
  if not ns.API.GetActiveResourceBars then return end
  
  local activeBars = ns.API.GetActiveResourceBars()
  for _, barNumber in ipairs(activeBars) do
    -- Nudge frame size to force layout engine recalc (fixes pixel-snapped border alignment)
    if nudgeLayout and resourceFrames[barNumber] and resourceFrames[barNumber].mainFrame then
      local f = resourceFrames[barNumber].mainFrame
      local w, h = f:GetSize()
      if w and h and w > 0 and h > 0 then
        f:SetSize(w + 0.01, h + 0.01)
        f:SetSize(w, h)
      end
    end
    ns.Resources.ApplyAppearance(barNumber)
  end
end

-- ===================================================================
-- REFRESH ALL BARS (for spec changes, etc.)
-- ===================================================================
function ns.Resources.RefreshAllBars()
  local currentSpec = GetSpecialization() or 0
  local optionsOpen = IsOptionsOpen()
  
  -- Get all active bars from DB (supports bars beyond index 10)
  local activeBars = ns.API.GetActiveResourceBars and ns.API.GetActiveResourceBars() or {}
  local activeSet = {}
  for _, barNum in ipairs(activeBars) do
    activeSet[barNum] = true
  end
  
  -- Also check bars 1-30 in case some are configured but not in activeBars yet
  -- IMPORTANT: Check db.resourceBars directly to avoid creating bars via GetResourceBarConfig
  local db = ns.API.GetDB()
  if db and db.resourceBars then
    for barNumber = 1, 30 do
      local barData = db.resourceBars[barNumber]
      if barData and barData.tracking and barData.tracking.enabled then
        activeSet[barNumber] = true
      end
    end
  end
  
  -- Refresh all bars we found
  for barNumber, _ in pairs(activeSet) do
    local cfg = ns.API.GetResourceBarConfig(barNumber)
    if cfg and cfg.tracking.enabled then
      -- Check spec visibility first (bypassed when options panel open)
      local showOnSpecs = cfg.behavior and cfg.behavior.showOnSpecs
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
      elseif cfg.behavior and cfg.behavior.showOnSpec and cfg.behavior.showOnSpec > 0 then
        -- Legacy single spec check
        specAllowed = (currentSpec == cfg.behavior.showOnSpec)
      end
      
      -- Show bar if spec allowed OR options panel is open for editing
      if specAllowed or optionsOpen then
        -- CRITICAL: Apply appearance FIRST to restore saved position/styling
        -- Then update the bar values
        ns.Resources.ApplyAppearance(barNumber)
        ns.Resources.UpdateBar(barNumber)
      else
        -- Hide bar - wrong spec (only hide if frames exist, don't create them)
        if resourceFrames[barNumber] then
          resourceFrames[barNumber].mainFrame:Hide()
          resourceFrames[barNumber].textFrame:Hide()
        end
      end
    else
      -- Hide bars that aren't enabled (only hide if frames exist, don't create them)
      if resourceFrames[barNumber] then
        resourceFrames[barNumber].mainFrame:Hide()
        resourceFrames[barNumber].textFrame:Hide()
      end
    end
  end
end

-- ===================================================================
-- GET BAR FRAME (for external access)
-- ===================================================================
function ns.Resources.GetBarFrame(barNumber)
  if resourceFrames[barNumber] then
    return resourceFrames[barNumber].mainFrame
  end
  return nil
end

-- ===================================================================
-- OPEN OPTIONS AND SELECT RESOURCE BAR (for click-to-edit)
-- Only works if options panel is already open
-- ===================================================================
function ns.Resources.OpenOptionsForBar(barNumber)
  local AceConfigDialog = LibStub("AceConfigDialog-3.0")
  
  -- Check if options panel is already open
  if not AceConfigDialog.OpenFrames or not AceConfigDialog.OpenFrames["ArcUI"] then
    -- Panel is not open, do nothing
    return
  end
  
  -- Set the selected bar in AppearanceOptions
  if ns.AppearanceOptions and ns.AppearanceOptions.SetSelectedBar then
    ns.AppearanceOptions.SetSelectedBar("resource", barNumber)
  end
  
  -- Refresh and switch to Appearance tab
  local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
  
  -- Refresh the options to show updated selection
  AceConfigRegistry:NotifyChange("ArcUI")
  
  -- Select the appearance tab under resources
  AceConfigDialog:SelectGroup("ArcUI", "resources", "appearance")
end

-- ===================================================================
-- SET PREVIEW VALUE (for live preview in appearance options)
-- ===================================================================
function ns.Resources.SetPreviewValue(barNumber, previewValue)
  local cfg = ns.API.GetResourceBarConfig(barNumber)
  if not cfg then return end
  
  local mainFrame, textFrame = GetResourceFrames(barNumber)
  if not mainFrame then return end
  
  -- Calculate correct maxValue for preview
  local maxValue
  local resourceCategory = cfg.tracking.resourceCategory or "primary"
  if resourceCategory == "secondary" then
    maxValue = cfg.tracking.maxValue or 100
  else
    -- PRIMARY: Use UnitPowerMax
    local powerType = cfg.tracking.powerType or 0
    maxValue = UnitPowerMax("player", powerType)
    if not maxValue or maxValue <= 0 then
      maxValue = cfg.tracking.maxValue or 100
    end
  end
  
  -- Call UpdateThresholdLayers with the preview value AND maxValue
  UpdateThresholdLayers(barNumber, previewValue, maxValue)
  
  -- Update text
  if cfg.display.showText and textFrame and textFrame.text then
    textFrame.text:SetText(previewValue)
  end
  
  -- Make sure bar is visible for preview
  mainFrame:Show()
  if cfg.display.showText then
    textFrame:Show()
  end
end

-- ===================================================================
-- EVENT HANDLING
-- ===================================================================
local eventFrame = CreateFrame("Frame")
local isInitialized = false

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("UNIT_POWER_FREQUENT")
eventFrame:RegisterEvent("UNIT_MAXPOWER")
eventFrame:RegisterEvent("UNIT_DISPLAYPOWER")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")  -- For spec-based visibility
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")  -- Talent changes can affect max resource

-- Secondary resource specific events
eventFrame:RegisterEvent("RUNE_POWER_UPDATE")           -- Death Knight runes
eventFrame:RegisterEvent("UNIT_POWER_POINT_CHARGE")     -- Evoker essence charging + Animacharged combo points
eventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")      -- Druid form changes
eventFrame:RegisterEvent("UNIT_HEALTH")                 -- For Stagger (based on health)
eventFrame:RegisterEvent("UNIT_MAXHEALTH")              -- For Stagger max
eventFrame:RegisterEvent("UNIT_AURA")                   -- For Maelstrom Weapon (Enhancement Shaman)

-- Spell prediction events (non-secret: player spellcast info)
eventFrame:RegisterEvent("UNIT_SPELLCAST_START")        -- Spell begins casting
eventFrame:RegisterEvent("UNIT_SPELLCAST_STOP")         -- Cast cancelled/interrupted
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")    -- Cast completed

-- Safe initialization - waits for DB to be ready
local function TryInitialize()
  -- Check if DB functions exist and DB is loaded
  if not ns.API or not ns.API.GetDB then
    return false
  end
  
  local db = ns.API.GetDB()
  if not db then
    return false
  end
  
  -- DB is ready - initialize!
  isInitialized = true
  ns.Resources.ApplyAllBars()
  
  return true
end

-- Retry initialization until successful
local function InitWithRetry(attempts)
  attempts = attempts or 0
  
  if TryInitialize() then
    return  -- Success!
  end
  
  -- Retry up to 10 times (5 seconds total)
  if attempts < 10 then
    C_Timer.After(0.5, function()
      InitWithRetry(attempts + 1)
    end)
  end
end

-- Check if a bar tracks a specific secondary type
local function BarTracksSecondaryType(barNumber, secondaryType)
  local cfg = ns.API.GetResourceBarConfig(barNumber)
  if not cfg or not cfg.tracking.enabled then return false end
  if cfg.tracking.resourceCategory ~= "secondary" then return false end
  return cfg.tracking.secondaryType == secondaryType
end

-- Update all bars that track a specific secondary type
local function UpdateBarsForSecondaryType(secondaryType)
  if not isInitialized then return end
  if not ns.API.GetActiveResourceBars then return end
  
  local activeBars = ns.API.GetActiveResourceBars()
  for _, barNumber in ipairs(activeBars) do
    if BarTracksSecondaryType(barNumber, secondaryType) then
      ns.Resources.UpdateBar(barNumber)
    end
  end
end

-- Refresh soul shard bars with full re-render (ApplyAppearance + UpdateBar)
-- ApplyAppearance: segment/icon overlays. UpdateBar: text prediction.
local function RefreshSoulShardBars()
  if not isInitialized then return end
  if not ns.API.GetActiveResourceBars then return end
  if not ns.Resources.ApplyAppearance then return end
  
  local activeBars = ns.API.GetActiveResourceBars()
  for _, barNumber in ipairs(activeBars) do
    if BarTracksSecondaryType(barNumber, "soulShards") then
      ns.Resources.ApplyAppearance(barNumber)
      ns.Resources.UpdateBar(barNumber)
    end
  end
end

eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2, ...)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    -- Addon loaded, but DB might not be ready yet
    -- Start retry loop
    C_Timer.After(0.5, function()
      InitWithRetry()
    end)
    
  elseif event == "PLAYER_LOGIN" then
    -- Player is logged in, UnitPower() should work now
    -- Try to initialize if not already done
    C_Timer.After(1.0, function()
      if not isInitialized then
        InitWithRetry()
      else
        -- Already initialized, update max values and refresh
        ns.Resources.UpdateMaxValues()
        ns.Resources.UpdateAllBars()
      end
    end)
    
  elseif event == "UNIT_POWER_FREQUENT" and arg1 == "player" then
    if not isInitialized then return end
    
    -- Update all resource bars that track this power type
    if not ns.API.GetActiveResourceBars then return end
    
    local powerToken = arg2
    local activeBars = ns.API.GetActiveResourceBars()
    for _, barNumber in ipairs(activeBars) do
      local cfg = ns.API.GetResourceBarConfig(barNumber)
      if cfg and cfg.tracking.enabled then
        local resourceCategory = cfg.tracking.resourceCategory or "primary"
        
        if resourceCategory == "primary" then
          -- Primary resource: check power type token
          local powerType = cfg.tracking.powerType
          local expectedToken = nil
          for _, pt in ipairs(ns.Resources.PowerTypes) do
            if pt.id == powerType then
              expectedToken = pt.token
              break
            end
          end
          
          if powerToken == expectedToken then
            ns.Resources.UpdateBar(barNumber)
          end
        else
          -- Secondary resource: check if token matches
          local secondaryType = cfg.tracking.secondaryType
          local typeInfo = ns.Resources.SecondaryTypesLookup[secondaryType]
          if typeInfo and typeInfo.powerType then
            local powerTypeEnum = typeInfo.powerType
            -- Match token to Enum
            local tokenMatches = false
            if powerToken == "COMBO_POINTS" and secondaryType == "comboPoints" then tokenMatches = true
            elseif powerToken == "HOLY_POWER" and secondaryType == "holyPower" then tokenMatches = true
            elseif powerToken == "CHI" and secondaryType == "chi" then tokenMatches = true
            elseif powerToken == "SOUL_SHARDS" and secondaryType == "soulShards" then tokenMatches = true
            elseif powerToken == "ESSENCE" and secondaryType == "essence" then tokenMatches = true
            elseif powerToken == "ARCANE_CHARGES" and secondaryType == "arcaneCharges" then tokenMatches = true
            elseif powerToken == "RUNES" and secondaryType == "runes" then tokenMatches = true
            end
            
            if tokenMatches then
              ns.Resources.UpdateBar(barNumber)
            end
          end
        end
      end
    end
    
  elseif event == "RUNE_POWER_UPDATE" then
    -- Death Knight rune update
    UpdateBarsForSecondaryType("runes")
    
  elseif event == "UNIT_POWER_POINT_CHARGE" and arg1 == "player" then
    -- Evoker essence charging + Rogue/Druid Animacharged combo points
    UpdateBarsForSecondaryType("essence")
    UpdateBarsForSecondaryType("comboPoints")
    
  elseif event == "UPDATE_SHAPESHIFT_FORM" then
    -- Druid form change - affects resource type AND form-based visibility
    if not isInitialized then return end
    C_Timer.After(0.1, function()
      -- Full refresh: ApplyAppearance for layout + UpdateBar for values
      -- Both have Druid form checks to show/hide based on showInForms
      local activeBars = ns.API.GetActiveResourceBars and ns.API.GetActiveResourceBars() or {}
      for _, barNum in ipairs(activeBars) do
        ns.Resources.ApplyAppearance(barNum)
        ns.Resources.UpdateBar(barNum)
      end
    end)
    
  elseif event == "UNIT_HEALTH" and arg1 == "player" then
    -- Stagger is based on health percentage
    UpdateBarsForSecondaryType("stagger")
    
  elseif event == "UNIT_MAXHEALTH" and arg1 == "player" then
    -- Stagger max changes with max health
    UpdateBarsForSecondaryType("stagger")
    
  elseif event == "UNIT_AURA" and arg1 == "player" then
    -- Maelstrom Weapon stacks (Enhancement Shaman)
    UpdateBarsForSecondaryType("maelstromWeapon")
    -- Soul Fragments - Devourer (aura-based)
    UpdateBarsForSecondaryType("soulFragmentsDevourer")
    -- Vengeance Soul Fragments (C_Spell.GetSpellCastCount updates on aura changes too)
    UpdateBarsForSecondaryType("soulFragments")
    
  elseif event == "UNIT_MAXPOWER" and arg1 == "player" then
    if not isInitialized then return end
    -- Cache new max power values (talents like Swelling Maelstrom change max)
    ns.Resources.CacheAllMaxPowerValues()
    ns.Resources.UpdateAllBars()
    
  elseif event == "UNIT_DISPLAYPOWER" and arg1 == "player" then
    if not isInitialized then return end
    ns.Resources.UpdateAllBars()
    
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Entering world (login, reload, zone change)
    C_Timer.After(1.5, function()
      if isInitialized then
        ns.Resources.UpdateMaxValues()
        ns.Resources.ApplyAllBars()
        ns.Resources.UpdateAllBars()  -- Also update values (max may have changed)
      else
        InitWithRetry()
      end
    end)
    
  elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
    if not isInitialized then return end
    ns.Resources.UpdateAllBars()
    
  elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
    -- Spec changed - refresh all bar visibility and update max values
    Prediction:InvalidateCache()
    if not isInitialized then return end
    C_Timer.After(0.1, function()
      ns.Resources.UpdateMaxValues()
      ns.Resources.RefreshAllBars()
    end)
    
  elseif event == "TRAIT_CONFIG_UPDATED" then
    -- Talent changed - may affect max resource values and prediction generators
    Prediction:InvalidateCache()
    if not isInitialized then return end
    C_Timer.After(0.2, function()
      ns.Resources.UpdateMaxValues()
      ns.Resources.UpdateAllBars()
    end)
    
  elseif event == "UNIT_SPELLCAST_START" and arg1 == "player" then
    -- Spell started casting — check for soul shard cost
    -- UNIT_SPELLCAST_START payload: unit, castGUID, spellID
    if not isInitialized then return end
    local _, playerClass = UnitClass("player")
    if playerClass ~= "WARLOCK" then return end
    -- spellID is 3rd payload arg; arg2=castGUID, ...=spellID
    local spellID = ...
    -- Safety: if spellID didn't come via varargs, try arg2 (some API versions)
    if not spellID and type(arg2) == "number" then
      spellID = arg2
    end
    Prediction:StartCast(spellID)
    if Prediction.active then
      -- Must use ApplyAppearance (not UpdateBar) — fragmented segments are only
      -- rendered during ApplyAppearance; UpdateBar doesn't touch individual segments
      RefreshSoulShardBars()
    end
    
  elseif event == "UNIT_SPELLCAST_STOP" and arg1 == "player" then
    -- Cast cancelled/interrupted
    if Prediction.active then
      Prediction:Clear()
      if isInitialized then
        RefreshSoulShardBars()
      end
    end
    
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" and arg1 == "player" then
    -- Cast completed — clear prediction (actual power change follows via UNIT_POWER_FREQUENT)
    if Prediction.active then
      Prediction:Clear()
      if isInitialized then
        RefreshSoulShardBars()
      end
    end
  end
end)

-- ===================================================================
-- UPDATE MAX VALUES
-- ===================================================================
function ns.Resources.UpdateMaxValues()
  local db = ns.API.GetDB()
  if not db or not db.resourceBars then return end
  
  -- Cache max power values for ColorCurve numeric threshold conversion
  ns.Resources.CacheAllMaxPowerValues()
  
  -- Get active bars and also check bars 1-30 for any enabled
  -- IMPORTANT: Only check bars that actually exist to avoid creating empty bars
  local activeBars = ns.API.GetActiveResourceBars and ns.API.GetActiveResourceBars() or {}
  local checkedBars = {}
  for _, barNum in ipairs(activeBars) do
    checkedBars[barNum] = true
  end
  -- Only add bars that exist in db.resourceBars (don't create new ones)
  for i = 1, 30 do
    if db.resourceBars[i] and db.resourceBars[i].tracking and db.resourceBars[i].tracking.enabled then
      checkedBars[i] = true
    end
  end
  
  for barNumber, _ in pairs(checkedBars) do
    -- Bar is known to exist, safe to get config
    local cfg = db.resourceBars[barNumber]
    if cfg and cfg.tracking.enabled then
      local resourceCategory = cfg.tracking.resourceCategory or "primary"
      
      if cfg.tracking.overrideMax then
        -- User wants manual control, don't auto-update
      elseif resourceCategory == "secondary" then
        -- Secondary resource max
        local secondaryType = cfg.tracking.secondaryType
        if secondaryType then
          local newMax = ns.Resources.GetSecondaryMaxValue(secondaryType)
          if newMax and newMax > 0 and newMax ~= cfg.tracking.maxValue then
            local oldMax = cfg.tracking.maxValue or 5
            cfg.tracking.maxValue = newMax
            
            -- Only rescale thresholds if thresholdAsPercent is enabled
            if cfg.display.thresholdAsPercent and cfg.thresholds and oldMax > 0 then
              for _, threshold in ipairs(cfg.thresholds) do
                threshold.minValue = math.floor((threshold.minValue / oldMax) * newMax)
                threshold.maxValue = math.floor((threshold.maxValue / oldMax) * newMax)
              end
            end
          end
        end
      else
        -- Primary resource max
        local powerType = cfg.tracking.powerType
        
        -- Guard: powerType must be valid (>= 0)
        if not powerType or powerType < 0 then
          -- Skip this bar, invalid powerType
        else
          local newMax = UnitPowerMax("player", powerType)
          if newMax and newMax > 0 and newMax ~= cfg.tracking.maxValue then
            local oldMax = cfg.tracking.maxValue or 100
            cfg.tracking.maxValue = newMax
            
            -- Only rescale thresholds if thresholdAsPercent is enabled
            if cfg.display.thresholdAsPercent and cfg.thresholds and oldMax > 0 then
              for _, threshold in ipairs(cfg.thresholds) do
                threshold.minValue = math.floor((threshold.minValue / oldMax) * newMax)
                threshold.maxValue = math.floor((threshold.maxValue / oldMax) * newMax)
              end
            end
          end
        end
      end
    end
  end
end

-- ===================================================================
-- DELETE CONFIRMATION DIALOG
-- ===================================================================
local resourceDeleteConfirmFrame = nil

ShowResourceDeleteConfirmation = function(barNumber)
  if not resourceDeleteConfirmFrame then
    resourceDeleteConfirmFrame = CreateFrame("Frame", "ArcUIResourceDeleteConfirm", UIParent, "BackdropTemplate")
    resourceDeleteConfirmFrame:SetSize(300, 120)
    resourceDeleteConfirmFrame:SetFrameStrata("TOOLTIP")
    resourceDeleteConfirmFrame:SetToplevel(true)
    resourceDeleteConfirmFrame:SetFrameLevel(9999)
    resourceDeleteConfirmFrame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
    resourceDeleteConfirmFrame:SetBackdropColor(0.1, 0.1, 0.1, 1)
    resourceDeleteConfirmFrame:EnableMouse(true)
    resourceDeleteConfirmFrame:SetMovable(true)
    resourceDeleteConfirmFrame:RegisterForDrag("LeftButton")
    resourceDeleteConfirmFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    resourceDeleteConfirmFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    resourceDeleteConfirmFrame:SetClampedToScreen(true)
    
    resourceDeleteConfirmFrame.title = resourceDeleteConfirmFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    resourceDeleteConfirmFrame.title:SetPoint("TOP", 0, -16)
    resourceDeleteConfirmFrame.title:SetText("Delete Resource Bar?")
    
    resourceDeleteConfirmFrame.text = resourceDeleteConfirmFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    resourceDeleteConfirmFrame.text:SetPoint("TOP", 0, -40)
    resourceDeleteConfirmFrame.text:SetWidth(260)
    
    resourceDeleteConfirmFrame.deleteBtn = CreateFrame("Button", nil, resourceDeleteConfirmFrame, "UIPanelButtonTemplate")
    resourceDeleteConfirmFrame.deleteBtn:SetSize(100, 24)
    resourceDeleteConfirmFrame.deleteBtn:SetPoint("BOTTOMLEFT", 30, 16)
    resourceDeleteConfirmFrame.deleteBtn:SetText("Delete")
    
    resourceDeleteConfirmFrame.cancelBtn = CreateFrame("Button", nil, resourceDeleteConfirmFrame, "UIPanelButtonTemplate")
    resourceDeleteConfirmFrame.cancelBtn:SetSize(100, 24)
    resourceDeleteConfirmFrame.cancelBtn:SetPoint("BOTTOMRIGHT", -30, 16)
    resourceDeleteConfirmFrame.cancelBtn:SetText("Cancel")
    resourceDeleteConfirmFrame.cancelBtn:SetScript("OnClick", function() resourceDeleteConfirmFrame:Hide() end)
  end
  
  -- Get bar name for display
  local barName = "Resource Bar " .. barNumber
  local cfg = ns.API and ns.API.GetResourceBarConfig and ns.API.GetResourceBarConfig(barNumber)
  if cfg and cfg.tracking and cfg.tracking.powerName and cfg.tracking.powerName ~= "" then
    barName = cfg.tracking.powerName
  end
  
  resourceDeleteConfirmFrame.text:SetText(string.format("Delete %s?", barName))
  resourceDeleteConfirmFrame.deleteBtn:SetScript("OnClick", function()
    ns.Resources.DeleteBar(barNumber)
    resourceDeleteConfirmFrame:Hide()
  end)
  
  resourceDeleteConfirmFrame:ClearAllPoints()
  resourceDeleteConfirmFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
  resourceDeleteConfirmFrame:Raise()
  resourceDeleteConfirmFrame:Show()
end

-- Expose for external use
ns.Resources.ShowDeleteConfirmation = ShowResourceDeleteConfirmation

-- ===================================================================
-- DELETE RESOURCE BAR (Clear config and hide)
-- ===================================================================
function ns.Resources.DeleteBar(barNumber)
  local cfg = ns.API and ns.API.GetResourceBarConfig and ns.API.GetResourceBarConfig(barNumber)
  if cfg then
    -- ═══════════════════════════════════════════════════════════
    -- FULLY RESET tracking config
    -- ═══════════════════════════════════════════════════════════
    cfg.tracking.enabled = false
    cfg.tracking.resourceCategory = "primary"
    cfg.tracking.powerType = 0
    cfg.tracking.secondaryType = nil
    cfg.tracking.powerName = ""
    cfg.tracking.maxValue = 100
    cfg.tracking.overrideMax = false
    cfg.tracking.showRuneTimer = false
    
    -- ═══════════════════════════════════════════════════════════
    -- FULLY RESET display state — prevents slot contamination
    -- when a new bar reuses this slot
    -- ═══════════════════════════════════════════════════════════
    cfg.display.enabled = false
    cfg.display.thresholdMode = "simple"
    cfg.display.showTickMarks = false
    cfg.display.enableActiveCountColors = nil
    cfg.display.activeCountColors = nil
    cfg.display.fragmentedColors = nil
    cfg.display.fragmentedChargingColor = nil
    cfg.display.fragmentedSpecColors = nil
    cfg.display.smartChargingColor = nil
    cfg.display.colorCurveEnabled = false
    cfg.display.enableMaxColor = false
    cfg.display.chargedComboColor = nil
    cfg.display.fragmentedShowSegmentText = nil
    cfg.display.fragmentedTextSize = nil
    cfg.display.fragmentedTextOffsetX = nil
    cfg.display.fragmentedTextOffsetY = nil
    cfg.display.fragmentedLayoutDirection = nil
    cfg.display.iconsShowCooldownText = nil
    cfg.display.iconsCDTextSize = nil
    cfg.display.iconsCDTextOffsetX = nil
    cfg.display.iconsCDTextOffsetY = nil
    cfg.display.iconsLayout = nil
    cfg.display.iconSize = nil
    cfg.display.iconSpacing = nil
    cfg.display.iconShape = nil
    cfg.display.iconsBorderStyle = nil
    cfg.display.showInForms = nil
    
    -- Clear color ranges and stack colors
    cfg.stackColors = nil
    cfg.colorRanges = nil
    
    -- Clear behavior
    if cfg.behavior then
      cfg.behavior.showOnSpecs = nil
      cfg.behavior.showOnSpec = nil
      cfg.behavior.talentConditions = nil
      cfg.behavior.talentMatchMode = nil
      cfg.behavior.hideBlizzardFrame = nil
    end
    
    -- Hide the bar (only if frames exist — don't create them)
    if resourceFrames[barNumber] then
      resourceFrames[barNumber].mainFrame:Hide()
      resourceFrames[barNumber].textFrame:Hide()
    end
    
    -- Refresh options panel
    if LibStub and LibStub("AceConfigRegistry-3.0", true) then
      LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
    end
  end
end

-- ===================================================================
-- SHOW/HIDE DELETE BUTTONS ON ALL RESOURCE BARS
-- Only visible when options panel is open
-- ===================================================================

function ns.Resources.ShowDeleteButtons()
  deleteButtonsVisible = true
  for barNumber = 1, 10 do
    local mainFrame, textFrame = GetResourceFrames(barNumber)
    if mainFrame and mainFrame:IsShown() and mainFrame.deleteButton then
      mainFrame.deleteButton:Show()
    end
  end
end

function ns.Resources.HideDeleteButtons()
  deleteButtonsVisible = false
  for barNumber = 1, 10 do
    local mainFrame, textFrame = GetResourceFrames(barNumber)
    if mainFrame and mainFrame.deleteButton then
      mainFrame.deleteButton:Hide()
    end
  end
end

function ns.Resources.AreDeleteButtonsVisible()
  return deleteButtonsVisible
end

-- ===================================================================
-- CDM GROUP CONTAINER SIZE CHANGE CALLBACK
-- Called by CDMGroups when a container's size changes (dynamic sizing)
-- ===================================================================
function ns.Resources.OnGroupContainerSizeChanged(groupName, newWidth, newHeight)
  -- Find all resource bars anchored to this group with matchGroupWidth enabled
  local activeBars = ns.API and ns.API.GetActiveResourceBars and ns.API.GetActiveResourceBars() or {}
  
  for _, barNumber in ipairs(activeBars) do
    local cfg = ns.API.GetResourceBarConfig(barNumber)
    if cfg and cfg.display and cfg.display.anchorToGroup and cfg.display.matchGroupWidth then
      if cfg.display.anchorGroupName == groupName and resourceFrames[barNumber] then
        local mainFrame = resourceFrames[barNumber].mainFrame
        if mainFrame then
          local scale = cfg.display.barScale or 1.0
          local isVertical = (cfg.display.barOrientation == "vertical")
          local anchorPoint = cfg.display.anchorPoint or "BOTTOM"
          local isSideAnchor = (anchorPoint == "LEFT" or anchorPoint == "RIGHT")
          
          -- Use container height for side anchors, container width for top/bottom
          local matchDimension = isSideAnchor and newHeight or newWidth
          local sizeAdjust = cfg.display.matchWidthAdjust or 0
          local barWidth = matchDimension + sizeAdjust
          local barHeight = cfg.display.height * scale
          
          -- Swap for vertical orientation (rotates the bar)
          if isVertical then
            mainFrame:SetSize(barHeight, barWidth)
          else
            mainFrame:SetSize(barWidth, barHeight)
          end
        end
      end
    end
  end
end

-- ===================================================================
-- CONTAINER SIZE HOOK FOR ANCHORED RESOURCE BARS
-- Hooks container's OnSizeChanged - fires only when size actually changes
-- Zero CPU overhead when nothing is happening
-- ===================================================================
local hookedContainers = {}  -- [container] = true

local function OnContainerSizeChanged(container, width, height)
  if not width or not height or width <= 0 or height <= 0 then return end
  if not ns.API or not ns.API.GetActiveResourceBars then return end
  
  -- Find which group this container belongs to
  local groupName
  if ns.CDMGroups and ns.CDMGroups.groups then
    for name, group in pairs(ns.CDMGroups.groups) do
      if group.container == container then
        groupName = name
        break
      end
    end
  end
  
  if not groupName then return end
  
  -- Update all resource bars anchored to this group
  local activeBars = ns.API.GetActiveResourceBars()
  for _, barNumber in ipairs(activeBars) do
    local cfg = ns.API.GetResourceBarConfig(barNumber)
    if cfg and cfg.display and cfg.display.anchorToGroup and cfg.display.anchorGroupName == groupName then
      if cfg.display.matchGroupWidth and resourceFrames[barNumber] then
        local mainFrame = resourceFrames[barNumber].mainFrame
        if mainFrame then
          local scale = cfg.display.barScale or 1.0
          local isVertical = (cfg.display.barOrientation == "vertical")
          local anchorPoint = cfg.display.anchorPoint or "BOTTOM"
          local isSideAnchor = (anchorPoint == "LEFT" or anchorPoint == "RIGHT")
          
          -- Use container height for side anchors, container width for top/bottom
          local matchDimension = isSideAnchor and height or width
          local sizeAdjust = cfg.display.matchWidthAdjust or 0
          local barWidth = matchDimension + sizeAdjust
          local barHeight = cfg.display.height * scale
          
          -- Swap for vertical orientation (rotates the bar)
          if isVertical then
            mainFrame:SetSize(barHeight, barWidth)
          else
            mainFrame:SetSize(barWidth, barHeight)
          end
        end
      end
    end
  end
end

-- Hook a container for size change events
function ns.Resources.HookContainerForAnchoredBars(groupName)
  if not ns.CDMGroups or not ns.CDMGroups.groups then return end
  
  local group = ns.CDMGroups.groups[groupName]
  if not group or not group.container then return end
  
  local container = group.container
  if hookedContainers[container] then return end  -- Already hooked
  
  hookedContainers[container] = true
  container:HookScript("OnSizeChanged", OnContainerSizeChanged)
  
  -- Fire immediately in case the container was already sized before we hooked
  -- (common at login — container gets laid out before resource bars initialize)
  local w, h = container:GetWidth(), container:GetHeight()
  if w and h and w > 0 and h > 0 then
    OnContainerSizeChanged(container, w, h)
  end
end

-- ===================================================================
-- INITIALIZATION (Backup)
-- ===================================================================
-- This is a backup in case events don't fire properly
C_Timer.After(3.0, function()
  if not isInitialized then
    InitWithRetry()
  end
end)

-- ===================================================================
-- HIDEWHEN VISIBILITY HOOK
-- Hook CDMGroups.UpdateGroupVisibility so resource bars refresh
-- in sync with group visibility (mount, combat, death, target, etc.)
-- Same pattern as CooldownBars.lua — one hook instead of 16+ events.
-- ===================================================================
local function InstallResourceVisibilityHook()
  if not ns.CDMGroups or not ns.CDMGroups.UpdateGroupVisibility then return end
  if ns.Resources._visHookInstalled then return end
  ns.Resources._visHookInstalled = true
  
  hooksecurefunc(ns.CDMGroups, "UpdateGroupVisibility", function()
    ns.Resources.RefreshVisibility()
  end)
end

local resVisHookFrame = CreateFrame("Frame")
resVisHookFrame:RegisterEvent("PLAYER_LOGIN")
resVisHookFrame:SetScript("OnEvent", function(self, event)
  InstallResourceVisibilityHook()
  self:UnregisterAllEvents()
end)

-- ===================================================================
-- END OF ArcUI_Resources.lua
-- ===================================================================