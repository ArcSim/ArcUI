-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Spell Usability Options
-- External options module for the Spell Usability section.
-- Uses ns.OptionsHelpers (exported by ArcUI_CDMEnhanceOptions) so all
-- entries work with edit-all, multi-select, and per-icon customization.
--
-- IMPORTANT: All closures resolve helpers via H() at CALL TIME, not at
-- table-build time, to avoid nil upvalue issues with load ordering.
--
-- Controls icon tinting/alpha/glow based on C_Spell.IsSpellUsable() state:
--   Usable       → white (or custom)  — spell is castable right now
--   Not Enough   → blue tint          — insufficient resource (mana/energy/etc)
--   Not Usable   → gray tint          — other restriction (wrong stance, etc)
--
-- Range indicator (red tint) is handled by the existing Range Indicator section.
-- ═══════════════════════════════════════════════════════════════════════════

local addonName, ns = ...

ns.SpellUsabilityOptions = ns.SpellUsabilityOptions or {}

-- ═══════════════════════════════════════════════════════════════════════════
-- LAZY ACCESSORS  (always resolve at call time, never cache references)
-- ═══════════════════════════════════════════════════════════════════════════

local function H()  return ns.OptionsHelpers end

-- mode = "aura" or "cooldown"
local function GetCfg(mode)
  local h = H()
  if mode == "aura" then return h.GetAuraCfg() end
  return h.GetCooldownCfg()
end

local function ApplySetting(mode, setter)
  local h = H()
  if mode == "aura" then return h.ApplyAuraSetting(setter) end
  return h.ApplySharedCooldownSetting(setter)
end

-- ── Hide functions (resolve at call time) ──

local function HideAuraUsability()
  local h = H()
  return h.HideIfNoAuraSelection() or h.collapsedSections.spellUsability
end

local function HideCooldownUsability()
  local h = H()
  if h.HideIfNoCooldownSelection() then return true end
  if h.IsEditingMixedTypes() then return true end
  return h.collapsedSections.spellUsability
end

-- ── Refresh helper ──

local function Refresh()
  -- Invalidate settings cache so visuals update immediately
  if ns.CDMEnhance and ns.CDMEnhance.InvalidateCache then
    ns.CDMEnhance.InvalidateCache()
  end
  -- Refresh spell frame visuals only (no frame size rebuild)
  if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshAllSpellVisuals then
    ns.ArcAurasCooldown.RefreshAllSpellVisuals()
  end
  -- Refresh CDM frame usability visuals
  if ns.CDMSpellUsability and ns.CDMSpellUsability.RefreshAll then
    ns.CDMSpellUsability.RefreshAll()
  end
end

-- Heavier refresh for glow param changes: forces glow restart with new settings
local function RefreshGlow()
  if ns.CDMEnhance and ns.CDMEnhance.InvalidateCache then
    ns.CDMEnhance.InvalidateCache()
  end
  -- Force-stop usable glows so they restart with new params
  if ns.ArcAurasCooldown and ns.ArcAurasCooldown.StopAllUsableGlows then
    ns.ArcAurasCooldown.StopAllUsableGlows()
  end
  -- Force-stop CDM frame usable glows
  if ns.CDMSpellUsability and ns.CDMSpellUsability.StopAllGlows then
    ns.CDMSpellUsability.StopAllGlows()
  end
  -- Now re-apply visuals (will restart glow with fresh settings)
  if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshAllSpellVisuals then
    ns.ArcAurasCooldown.RefreshAllSpellVisuals()
  end
  -- Refresh CDM frame usability visuals
  if ns.CDMSpellUsability and ns.CDMSpellUsability.RefreshAll then
    ns.CDMSpellUsability.RefreshAll()
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GENERIC ENTRY BUILDER
-- mode = "aura" | "cooldown" — resolved lazily inside every closure
-- ═══════════════════════════════════════════════════════════════════════════

local function BuildUsabilityEntries(orderBase, mode, hideSection)

  local entries = {}

  -- ───────────────────────────────────────────────────────────────────
  -- MASTER TOGGLE
  -- ───────────────────────────────────────────────────────────────────
  entries["spellUsabilityEnabled"] = {
    type = "toggle", name = "Enable Usability Tinting",
    desc = "Tint spell icons based on whether they can be cast.\n\n"
        .. "|cff8080ffBlue|r = Not enough resource (mana, energy, etc.)\n"
        .. "|cff999999Gray|r = Not usable (wrong stance, missing buff, etc.)\n\n"
        .. "When disabled, icons use default white when no custom tint is set.",
    get = function()
      local c = GetCfg(mode)
      return not c or not c.spellUsability or c.spellUsability.enabled ~= false
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.enabled = v
      end)
      Refresh()
    end,
    order = orderBase + 0.001, width = 1.2,
    hidden = hideSection,
  }

  -- ───────────────────────────────────────────────────────────────────
  -- NOT ENOUGH RESOURCE  (mana, energy, maelstrom, etc.)
  -- Layout: [Description full] → [Tint Color] [Opacity Slider] on same row
  -- ───────────────────────────────────────────────────────────────────
  entries["spellUsabilityResourceDesc"] = {
    type = "description", name = "|cff8080ffNot Enough Resource|r  |cff666666(mana, energy, maelstrom, etc.)|r",
    fontSize = "medium",
    order = orderBase + 0.010, width = "full",
    hidden = hideSection,
  }

  entries["spellUsabilityResourceColor"] = {
    type = "color", name = "Tint Color", hasAlpha = false,
    desc = "Icon tint color when you don't have enough resource.\n\nDefault: |cff8080ffBlue|r (matching CDM behavior)",
    get = function()
      local c = GetCfg(mode)
      local col = c and c.spellUsability and c.spellUsability.notEnoughResourceColor
      if col then return col.r, col.g, col.b end
      return 0.5, 0.5, 1.0  -- default blue
    end,
    set = function(_, r, g, b)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.notEnoughResourceColor = { r = r, g = g, b = b }
      end)
      Refresh()
    end,
    order = orderBase + 0.011, width = 0.5,
    hidden = hideSection,
  }

  entries["spellUsabilityResourceAlpha"] = {
    type = "range", name = "Icon Opacity", min = 0, max = 1.0, step = 0.05,
    desc = "Icon opacity when you don't have enough resource to cast.\n\nSet to 0 to hide the icon until you have enough resource.",
    get = function()
      local c = GetCfg(mode)
      return c and c.spellUsability and c.spellUsability.notEnoughResourceAlpha or 1.0
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.notEnoughResourceAlpha = v
      end)
      Refresh()
    end,
    order = orderBase + 0.012, width = 0.8,
    hidden = hideSection,
  }

  -- ───────────────────────────────────────────────────────────────────
  -- NOT USABLE  (wrong stance, missing buff, etc.)
  -- Layout: [Description full] → [Tint Color] [Opacity Slider] on same row
  -- ───────────────────────────────────────────────────────────────────
  entries["spellUsabilityNotUsableDesc"] = {
    type = "description", name = "|cff999999Not Usable|r  |cff666666(wrong stance, missing buff, etc.)|r",
    fontSize = "medium",
    order = orderBase + 0.020, width = "full",
    hidden = hideSection,
  }

  entries["spellUsabilityNotUsableColor"] = {
    type = "color", name = "Tint Color", hasAlpha = false,
    desc = "Icon tint color when the spell can't be cast.\n\nDefault: |cff999999Gray|r (matching CDM behavior)",
    get = function()
      local c = GetCfg(mode)
      local col = c and c.spellUsability and c.spellUsability.notUsableColor
      if col then return col.r, col.g, col.b end
      return 0.4, 0.4, 0.4  -- default gray
    end,
    set = function(_, r, g, b)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.notUsableColor = { r = r, g = g, b = b }
      end)
      Refresh()
    end,
    order = orderBase + 0.021, width = 0.5,
    hidden = hideSection,
  }

  entries["spellUsabilityNotUsableAlpha"] = {
    type = "range", name = "Icon Opacity", min = 0, max = 1.0, step = 0.05,
    desc = "Icon opacity when the spell can't be cast for other reasons (wrong stance, missing buff, etc.).\n\nSet to 0 to hide the icon until castable.",
    get = function()
      local c = GetCfg(mode)
      return c and c.spellUsability and c.spellUsability.notUsableAlpha or 1.0
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.notUsableAlpha = v
      end)
      Refresh()
    end,
    order = orderBase + 0.022, width = 0.8,
    hidden = hideSection,
  }

  -- ───────────────────────────────────────────────────────────────────
  -- USABLE GLOW
  -- ───────────────────────────────────────────────────────────────────
  entries["spellUsabilityGlow"] = {
    type = "toggle", name = "Show Glow When Usable",
    desc = "Show a glow effect while the spell has enough resources to cast.\n\nUseful for resource-gated spells with no cooldown — the glow tells you at a glance that you can cast it.",
    get = function()
      local c = GetCfg(mode)
      return c and c.spellUsability and c.spellUsability.usableGlow or false
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.usableGlow = v
      end)
      RefreshGlow()
    end,
    order = orderBase + 0.031, width = 1.2,
    hidden = hideSection,
  }

  entries["spellUsabilityGlowPreview"] = {
    type = "toggle", name = "Preview",
    desc = "Toggle usable glow preview for selected icon(s). Preview will automatically stop when you close the options panel.",
    get = function()
      return ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.GetUsableGlowPreviewState
          and ns.CDMEnhanceOptions.GetUsableGlowPreviewState(mode == "aura")
    end,
    set = function(_, v)
      if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.ToggleUsableGlowPreviewForSelection then
        ns.CDMEnhanceOptions.ToggleUsableGlowPreviewForSelection(mode == "aura")
      end
    end,
    order = orderBase + 0.0315, width = 0.5,
    hidden = function()
      if hideSection() then return true end
      local c = GetCfg(mode)
      return not (c and c.spellUsability and c.spellUsability.usableGlow)
    end,
  }

  entries["spellUsabilityGlowCombatOnly"] = {
    type = "toggle", name = "Combat Only",
    desc = "Only show the usable glow while in combat.\n\nOut of combat, most spells are always usable so the glow would be redundant.",
    get = function()
      local c = GetCfg(mode)
      return c and c.spellUsability and c.spellUsability.usableGlowCombatOnly or false
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.usableGlowCombatOnly = v
      end)
      Refresh()
    end,
    order = orderBase + 0.032, width = 0.7,
    hidden = function()
      if hideSection() then return true end
      local c = GetCfg(mode)
      return not (c and c.spellUsability and c.spellUsability.usableGlow)
    end,
  }

  entries["spellUsabilityGlowType"] = {
    type = "select", name = "Glow Type",
    desc = "Glow animation style for the usable indicator",
    values = {
      button   = "Button Glow",
      pixel    = "Pixel Glow",
      autocast = "Autocast Shine",
      glow     = "Blizzard Default",
    },
    get = function()
      local c = GetCfg(mode)
      local t = c and c.spellUsability and c.spellUsability.usableGlowType or "button"
      if t == "blizzard" then t = "glow" end  -- migrate removed option
      return t
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.usableGlowType = v
      end)
      RefreshGlow()
    end,
    order = orderBase + 0.033, width = 0.7,
    hidden = function()
      if hideSection() then return true end
      local c = GetCfg(mode)
      return not (c and c.spellUsability and c.spellUsability.usableGlow)
    end,
  }

  entries["spellUsabilityGlowColor"] = {
    type = "color", name = "Glow Color", hasAlpha = true,
    desc = "Color of the usable glow effect",
    get = function()
      local c = GetCfg(mode)
      local col = c and c.spellUsability and c.spellUsability.usableGlowColor
      if col then return col.r or 1, col.g or 1, col.b or 1, col.a or 1 end
      return 1, 1, 1, 1
    end,
    set = function(_, r, g, b, a)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.usableGlowColor = { r = r, g = g, b = b, a = a }
      end)
      RefreshGlow()
    end,
    order = orderBase + 0.034, width = 0.5,
    hidden = function()
      if hideSection() then return true end
      local c = GetCfg(mode)
      return not (c and c.spellUsability and c.spellUsability.usableGlow)
    end,
  }

  entries["spellUsabilityGlowScale"] = {
    type = "range", name = "Scale", min = 0.25, max = 4.0, step = 0.05,
    get = function()
      local c = GetCfg(mode)
      return c and c.spellUsability and c.spellUsability.usableGlowScale or 1.0
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.usableGlowScale = v
      end)
      RefreshGlow()
    end,
    order = orderBase + 0.035, width = 0.55,
    hidden = function()
      if hideSection() then return true end
      local c = GetCfg(mode)
      return not (c and c.spellUsability and c.spellUsability.usableGlow)
    end,
  }

  entries["spellUsabilityGlowSpeed"] = {
    type = "range", name = "Speed", min = 0.05, max = 1.0, step = 0.05,
    get = function()
      local c = GetCfg(mode)
      return c and c.spellUsability and c.spellUsability.usableGlowSpeed or 0.25
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.usableGlowSpeed = v
      end)
      RefreshGlow()
    end,
    order = orderBase + 0.036, width = 0.55,
    hidden = function()
      if hideSection() then return true end
      local c = GetCfg(mode)
      return not (c and c.spellUsability and c.spellUsability.usableGlow)
    end,
  }

  entries["spellUsabilityGlowLines"] = {
    type = "range", name = "Lines", min = 1, max = 16, step = 1,
    get = function()
      local c = GetCfg(mode)
      return c and c.spellUsability and c.spellUsability.usableGlowLines or 8
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.usableGlowLines = v
      end)
      RefreshGlow()
    end,
    order = orderBase + 0.037, width = 0.55,
    hidden = function()
      if hideSection() then return true end
      local c = GetCfg(mode)
      return not (c and c.spellUsability and c.spellUsability.usableGlow)
          or (c.spellUsability.usableGlowType ~= "pixel")
    end,
  }

  entries["spellUsabilityGlowThickness"] = {
    type = "range", name = "Thickness", min = 1, max = 10, step = 0.5,
    get = function()
      local c = GetCfg(mode)
      return c and c.spellUsability and c.spellUsability.usableGlowThickness or 2
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.usableGlowThickness = v
      end)
      RefreshGlow()
    end,
    order = orderBase + 0.038, width = 0.55,
    hidden = function()
      if hideSection() then return true end
      local c = GetCfg(mode)
      return not (c and c.spellUsability and c.spellUsability.usableGlow)
          or (c.spellUsability.usableGlowType ~= "pixel")
    end,
  }

  entries["spellUsabilityGlowParticles"] = {
    type = "range", name = "Particles", min = 1, max = 16, step = 1,
    get = function()
      local c = GetCfg(mode)
      return c and c.spellUsability and c.spellUsability.usableGlowParticles or 4
    end,
    set = function(_, v)
      ApplySetting(mode, function(c)
        if not c.spellUsability then c.spellUsability = {} end
        c.spellUsability.usableGlowParticles = v
      end)
      RefreshGlow()
    end,
    order = orderBase + 0.039, width = 0.55,
    hidden = function()
      if hideSection() then return true end
      local c = GetCfg(mode)
      return not (c and c.spellUsability and c.spellUsability.usableGlow)
          or (c.spellUsability.usableGlowType ~= "autocast")
    end,
  }

  return entries
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AURA OPTIONS  → called by CDMEnhanceOptions.GetCDMAuraIconsOptionsTable()
-- ═══════════════════════════════════════════════════════════════════════════

function ns.SpellUsabilityOptions.GetAuraArgs()
  local args = {}
  local mode = "aura"

  -- Header
  args.spellUsabilityHeader = {
    type = "toggle",
    name = function() return H().GetAuraHeaderName("spellUsability", "Spell Usability") end,
    desc = "Click to expand/collapse. Controls icon tinting, opacity, and glow based on whether the spell can be cast. Purple dot indicates per-icon customizations.",
    dialogControl = "CollapsibleHeader",
    get = function() return not H().collapsedSections.spellUsability end,
    set = function(_, v) H().collapsedSections.spellUsability = not v end,
    order = 109.65, width = "full",
    hidden = function() return H().HideIfNoAuraSelection() end,
  }

  -- All entries
  for k, v in pairs(BuildUsabilityEntries(109.65, mode, HideAuraUsability)) do
    args[k] = v
  end

  -- Reset (after all entries)
  args.resetSpellUsability = {
    type = "execute", name = "Reset Section",
    desc = "Reset Spell Usability settings to defaults for selected icon(s)",
    order = 109.699, width = 0.7,
    hidden = HideAuraUsability,
    func = function()
      H().ResetAuraSectionSettings("spellUsability")
      Refresh()
    end,
  }

  return args
end

-- ═══════════════════════════════════════════════════════════════════════════
-- COOLDOWN OPTIONS  → called by CDMEnhanceOptions.GetCDMCooldownIconsOptionsTable()
-- ═══════════════════════════════════════════════════════════════════════════

function ns.SpellUsabilityOptions.GetCooldownArgs()
  local args = {}
  local mode = "cooldown"

  -- Header
  args.spellUsabilityHeader = {
    type = "toggle",
    name = function() return H().GetCooldownHeaderName("spellUsability", "Spell Usability") end,
    desc = "Click to expand/collapse. Controls icon tinting, opacity, and glow based on whether the spell can be cast. Purple dot indicates per-icon customizations.",
    dialogControl = "CollapsibleHeader",
    get = function() return not H().collapsedSections.spellUsability end,
    set = function(_, v) H().collapsedSections.spellUsability = not v end,
    order = 109.65, width = "full",
    hidden = function()
      local h = H()
      if h.HideIfNoCooldownSelection() then return true end
      if h.IsEditingMixedTypes() then return true end
      return false
    end,
  }

  -- All entries
  for k, v in pairs(BuildUsabilityEntries(109.65, mode, HideCooldownUsability)) do
    args[k] = v
  end

  -- Reset (after all entries)
  args.resetSpellUsability = {
    type = "execute", name = "Reset Section",
    desc = "Reset Spell Usability settings to defaults for selected icon(s)",
    order = 109.699, width = 0.7,
    hidden = HideCooldownUsability,
    func = function()
      H().ResetCooldownSectionSettings("spellUsability")
      Refresh()
    end,
  }

  return args
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GLOBAL DEFAULTS  → called by CDMEnhanceOptions global sections
-- ═══════════════════════════════════════════════════════════════════════════

function ns.SpellUsabilityOptions.GetGlobalAuraArgs(collapsedGlobalSections, GetGlobalCfg, ApplyGlobalSetting, RefreshGlobal)
  return ns.SpellUsabilityOptions._BuildGlobalArgs(
    collapsedGlobalSections, GetGlobalCfg, ApplyGlobalSetting, RefreshGlobal
  )
end

function ns.SpellUsabilityOptions.GetGlobalCooldownArgs(collapsedGlobalSections, GetGlobalCfg, ApplyGlobalSetting, RefreshGlobal)
  return ns.SpellUsabilityOptions._BuildGlobalArgs(
    collapsedGlobalSections, GetGlobalCfg, ApplyGlobalSetting, RefreshGlobal
  )
end

function ns.SpellUsabilityOptions._BuildGlobalArgs(collapsedSections, GetGlobalCfg, ApplyGlobalSetting, RefreshGlobal)
  local args = {}

  args.spellUsabilityHeader = {
    type = "toggle", name = "Spell Usability", dialogControl = "CollapsibleHeader",
    get = function() return not collapsedSections.spellUsability end,
    set = function(_, v) collapsedSections.spellUsability = not v end,
    order = 55, width = "full",
  }

  args.spellUsabilityEnabled = {
    type = "toggle", name = "Enable Usability Tinting",
    desc = "Tint spell icons based on whether they can be cast.\n\n"
        .. "|cff8080ffBlue|r = Not enough resource\n"
        .. "|cff999999Gray|r = Not usable",
    get = function()
      local g = GetGlobalCfg()
      return not g.spellUsability or g.spellUsability.enabled ~= false
    end,
    set = function(_, v) ApplyGlobalSetting("spellUsability.enabled", v); RefreshGlobal() end,
    order = 55.1, width = 1.0,
    hidden = function() return collapsedSections.spellUsability end,
  }

  return args
end