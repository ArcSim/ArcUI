-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Custom Label Options
-- External options module for the Custom Label section.
-- Uses ns.OptionsHelpers (exported by ArcUI_CDMEnhanceOptions) so all
-- entries work with edit-all, multi-select, and per-icon customization.
--
-- IMPORTANT: All closures resolve helpers via H() at CALL TIME, not at
-- table-build time, to avoid nil upvalue issues with load ordering.
--
-- STATE VISIBILITY is now PER-LABEL: each label has its own show/hide
-- toggles so different labels can appear in different states.
-- ═══════════════════════════════════════════════════════════════════════════

local addonName, ns = ...

ns.CustomLabelOptions = ns.CustomLabelOptions or {}

-- ═══════════════════════════════════════════════════════════════════════════
-- SHARED CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local ANCHOR_VALUES = {
  TOPLEFT = "Top Left", TOP = "Top", TOPRIGHT = "Top Right",
  LEFT = "Left", CENTER = "Center", RIGHT = "Right",
  BOTTOMLEFT = "Bottom Left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right",
}

local STRATA_VALUES = {
  [""] = "Inherit", ["BACKGROUND"] = "Background", ["LOW"] = "Low",
  ["MEDIUM"] = "Medium", ["HIGH"] = "High", ["DIALOG"] = "Dialog", ["TOOLTIP"] = "Tooltip",
}
local STRATA_SORTING = { "", "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "TOOLTIP" }

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

local function HideAuraCustomLabel()
  local h = H()
  return h.HideIfNoAuraSelection() or h.collapsedSections.customLabel
end

local function HideAuraCustomLabel2()
  if HideAuraCustomLabel() then return true end
  local c = H().GetAuraCfg()
  return not c or not c.customLabel or (c.customLabel.labelCount or 1) < 2
end

local function HideAuraCustomLabel3()
  if HideAuraCustomLabel() then return true end
  local c = H().GetAuraCfg()
  return not c or not c.customLabel or (c.customLabel.labelCount or 1) < 3
end

local function HideCooldownCustomLabel()
  local h = H()
  if h.HideIfNoCooldownSelection() then return true end
  if h.IsEditingMixedTypes() then return true end
  return h.collapsedSections.customLabel
end

local function HideCooldownCustomLabel2()
  if HideCooldownCustomLabel() then return true end
  local c = H().GetCooldownCfg()
  return not c or not c.customLabel or (c.customLabel.labelCount or 1) < 2
end

local function HideCooldownCustomLabel3()
  if HideCooldownCustomLabel() then return true end
  local c = H().GetCooldownCfg()
  return not c or not c.customLabel or (c.customLabel.labelCount or 1) < 3
end

local function Refresh()
  if ns.CustomLabel and ns.CustomLabel.QueueRefresh then ns.CustomLabel.QueueRefresh() end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GENERIC LABEL ENTRY BUILDERS
-- mode = "aura" | "cooldown" — resolved lazily inside every closure
-- Now includes PER-LABEL state visibility toggles.
-- ═══════════════════════════════════════════════════════════════════════════

local function BuildLabelEntries(suffix, orderBase, mode, hideLabel)
  local sKey = suffix  -- "" for label 1, "2" for label 2, "3" for label 3
  local labelNum = suffix == "" and "" or (" " .. suffix)
  local entries = {}

  -- Description header for labels 2/3
  if suffix ~= "" then
    entries["customLabel" .. suffix .. "Desc"] = {
      type = "description", name = "|cff88ccffLabel " .. suffix .. "|r", fontSize = "medium",
      order = orderBase, width = "full",
      hidden = hideLabel,
    }
    orderBase = orderBase + 0.01
  end

  entries["customLabelText" .. suffix] = {
    type = "input", name = "Label Text" .. labelNum,
    desc = suffix == "" and "Custom text to display on the icon. Leave empty to disable." or nil,
    get = function() local c = GetCfg(mode); return c and c.customLabel and c.customLabel["text" .. sKey] or "" end,
    set = function(_, v)
      ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["text" .. sKey] = (v ~= "") and v or nil end)
      Refresh()
    end,
    order = orderBase + 0.01, width = 1.0,
    hidden = hideLabel,
  }

  entries["customLabelSize" .. suffix] = {
    type = "range", name = "Size", min = 1, max = 35, step = 1,
    get = function() local c = GetCfg(mode); return c and c.customLabel and c.customLabel["size" .. sKey] or 12 end,
    set = function(_, v)
      ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["size" .. sKey] = v end)
      Refresh()
    end,
    order = orderBase + 0.02, width = 0.7,
    hidden = hideLabel,
  }

  entries["customLabelColor" .. suffix] = {
    type = "color", name = "Color", hasAlpha = true,
    get = function()
      local c = GetCfg(mode)
      local col = c and c.customLabel and c.customLabel["color" .. sKey] or { r = 1, g = 1, b = 1, a = 1 }
      return col.r or 1, col.g or 1, col.b or 1, col.a or 1
    end,
    set = function(_, r, g, b, a)
      ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["color" .. sKey] = { r = r, g = g, b = b, a = a } end)
      Refresh()
    end,
    order = orderBase + 0.03, width = 0.5,
    hidden = hideLabel,
  }

  entries["customLabelAnchor" .. suffix] = {
    type = "select", name = "Anchor", values = ANCHOR_VALUES,
    get = function() local c = GetCfg(mode); return c and c.customLabel and c.customLabel["anchor" .. sKey] or "CENTER" end,
    set = function(_, v)
      ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["anchor" .. sKey] = v end)
      Refresh()
    end,
    order = orderBase + 0.04, width = 0.7,
    hidden = hideLabel,
  }

  entries["customLabelXOffset" .. suffix] = {
    type = "range", name = "X Offset", min = -50, max = 50, step = 1,
    get = function() local c = GetCfg(mode); return c and c.customLabel and c.customLabel["xOffset" .. sKey] or 0 end,
    set = function(_, v)
      ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["xOffset" .. sKey] = v end)
      Refresh()
    end,
    order = orderBase + 0.05, width = 0.7,
    hidden = hideLabel,
  }

  entries["customLabelYOffset" .. suffix] = {
    type = "range", name = "Y Offset", min = -50, max = 50, step = 1,
    get = function() local c = GetCfg(mode); return c and c.customLabel and c.customLabel["yOffset" .. sKey] or 0 end,
    set = function(_, v)
      ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["yOffset" .. sKey] = v end)
      Refresh()
    end,
    order = orderBase + 0.06, width = 0.7,
    hidden = hideLabel,
  }

  -- ── PER-LABEL STATE VISIBILITY TOGGLES ──
  if mode == "aura" then
    entries["customLabelShowActive" .. suffix] = {
      type = "toggle", name = "When Active",
      desc = "Show this label when the aura is active (buff/debuff present)",
      get = function() local c = GetCfg(mode); return not c or not c.customLabel or c.customLabel["showWhenActive" .. sKey] ~= false end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["showWhenActive" .. sKey] = v end)
        Refresh()
      end,
      order = orderBase + 0.07, width = 0.85,
      hidden = hideLabel,
    }
    entries["customLabelShowInactive" .. suffix] = {
      type = "toggle", name = "When Inactive",
      desc = "Show this label when the aura is inactive (buff/debuff missing)",
      get = function() local c = GetCfg(mode); return not c or not c.customLabel or c.customLabel["showWhenInactive" .. sKey] ~= false end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["showWhenInactive" .. sKey] = v end)
        Refresh()
      end,
      order = orderBase + 0.08, width = 0.95,
      hidden = hideLabel,
    }
  else
    -- Cooldown state toggles
    entries["customLabelShowReady" .. suffix] = {
      type = "toggle", name = "When Ready",
      desc = "Show this label when all charges are full (or cooldown is ready for non-charge spells)",
      get = function() local c = GetCfg(mode); return not c or not c.customLabel or c.customLabel["showInReadyState" .. sKey] ~= false end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["showInReadyState" .. sKey] = v end)
        Refresh()
      end,
      order = orderBase + 0.07, width = 0.7,
      hidden = hideLabel,
    }
    entries["customLabelShowRecharging" .. suffix] = {
      type = "toggle", name = "While Recharging",
      desc = "Show this label while a charge is recharging (charges still available). Only affects charge spells like Fire Blast, Lava Burst, etc.",
      get = function() local c = GetCfg(mode); return not c or not c.customLabel or c.customLabel["showWhileRecharging" .. sKey] ~= false end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["showWhileRecharging" .. sKey] = v end)
        Refresh()
      end,
      order = orderBase + 0.075, width = 0.85,
      hidden = hideLabel,
    }
    entries["customLabelShowCooldown" .. suffix] = {
      type = "toggle", name = "On Cooldown",
      desc = "Show this label when all charges are spent (or ability is on cooldown for non-charge spells)",
      get = function() local c = GetCfg(mode); return not c or not c.customLabel or c.customLabel["showInCooldownState" .. sKey] ~= false end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["showInCooldownState" .. sKey] = v end)
        Refresh()
      end,
      order = orderBase + 0.08, width = 0.7,
      hidden = hideLabel,
    }

    -- Aura filter toggles (some cooldown frames also track auras)
    entries["customLabelShowAuraActive" .. suffix] = {
      type = "toggle", name = "When Aura Active",
      desc = "Show this label when an aura is active on this cooldown frame. Some cooldown icons also display buff/debuff state — this filters based on that aura presence.",
      get = function() local c = GetCfg(mode); return not c or not c.customLabel or c.customLabel["showWhenAuraActive" .. sKey] ~= false end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["showWhenAuraActive" .. sKey] = v end)
        Refresh()
      end,
      order = orderBase + 0.085, width = 0.85,
      hidden = hideLabel,
    }
    entries["customLabelShowAuraInactive" .. suffix] = {
      type = "toggle", name = "When Aura Inactive",
      desc = "Show this label when no aura is active on this cooldown frame. Some cooldown icons also display buff/debuff state — this filters based on that aura absence.",
      get = function() local c = GetCfg(mode); return not c or not c.customLabel or c.customLabel["showWhenAuraInactive" .. sKey] ~= false end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel["showWhenAuraInactive" .. sKey] = v end)
        Refresh()
      end,
      order = orderBase + 0.09, width = 0.95,
      hidden = hideLabel,
    }
  end

  return entries
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ADD/REMOVE BUTTONS BUILDER
-- ═══════════════════════════════════════════════════════════════════════════

local function BuildAddRemoveEntries(orderBase, mode, hideMain)
  return {
    customLabelAdd = {
      type = "execute", name = "+ Add Label",
      desc = "Add another text label to this icon (up to 3)",
      order = orderBase, width = 0.55,
      hidden = function()
        if hideMain() then return true end
        local c = GetCfg(mode)
        return c and c.customLabel and (c.customLabel.labelCount or 1) >= 3
      end,
      func = function()
        ApplySetting(mode, function(c)
          if not c.customLabel then c.customLabel = {} end
          c.customLabel.labelCount = math.min(3, (c.customLabel.labelCount or 1) + 1)
        end)
        Refresh()
      end,
    },
    customLabelRemove = {
      type = "execute", name = "- Remove Label",
      desc = "Remove the last extra label",
      order = orderBase + 0.01, width = 0.6,
      hidden = function()
        if hideMain() then return true end
        local c = GetCfg(mode)
        return not c or not c.customLabel or (c.customLabel.labelCount or 1) <= 1
      end,
      func = function()
        ApplySetting(mode, function(c)
          if not c.customLabel then return end
          local count = c.customLabel.labelCount or 1
          if count == 3 then
            c.customLabel.text3 = nil; c.customLabel.size3 = nil; c.customLabel.color3 = nil
            c.customLabel.anchor3 = nil; c.customLabel.xOffset3 = nil; c.customLabel.yOffset3 = nil
            c.customLabel.showWhenActive3 = nil; c.customLabel.showWhenInactive3 = nil
            c.customLabel.showInReadyState3 = nil; c.customLabel.showInCooldownState3 = nil
            c.customLabel.showWhileRecharging3 = nil
            c.customLabel.showWhenAuraActive3 = nil; c.customLabel.showWhenAuraInactive3 = nil
          elseif count == 2 then
            c.customLabel.text2 = nil; c.customLabel.size2 = nil; c.customLabel.color2 = nil
            c.customLabel.anchor2 = nil; c.customLabel.xOffset2 = nil; c.customLabel.yOffset2 = nil
            c.customLabel.showWhenActive2 = nil; c.customLabel.showWhenInactive2 = nil
            c.customLabel.showInReadyState2 = nil; c.customLabel.showInCooldownState2 = nil
            c.customLabel.showWhileRecharging2 = nil
            c.customLabel.showWhenAuraActive2 = nil; c.customLabel.showWhenAuraInactive2 = nil
          end
          c.customLabel.labelCount = math.max(1, count - 1)
        end)
        Refresh()
      end,
    },
  }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SHARED SETTINGS BUILDER (font, outline, strata, level)
-- ═══════════════════════════════════════════════════════════════════════════

local function BuildSharedEntries(orderBase, mode, hideMain)
  return {
    customLabelSharedDesc = {
      type = "description", name = "|cffaaaaaaShared across all labels:|r", fontSize = "small",
      order = orderBase, width = "full",
      hidden = hideMain,
    },
    customLabelFont = {
      type = "select", name = "Font",
      dialogControl = "LSM30_Font",
      values = AceGUIWidgetLSMlists and AceGUIWidgetLSMlists.font or {},
      get = function() local c = GetCfg(mode); return c and c.customLabel and c.customLabel.font or "Friz Quadrata TT" end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel.font = v end)
        Refresh()
      end,
      order = orderBase + 0.01, width = 1.0,
      hidden = hideMain,
    },
    customLabelOutline = {
      type = "select", name = "Outline",
      values = { [""] = "None", ["OUTLINE"] = "Thin", ["THICKOUTLINE"] = "Thick" },
      get = function() local c = GetCfg(mode); return c and c.customLabel and c.customLabel.outline or "OUTLINE" end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel.outline = v end)
        Refresh()
      end,
      order = orderBase + 0.02, width = 0.6,
      hidden = hideMain,
    },
    customLabelFrameStrata = {
      type = "select", name = "Frame Strata",
      desc = "Controls the draw layer of the label. Higher strata draws on top of other elements.",
      values = STRATA_VALUES,
      sorting = STRATA_SORTING,
      get = function() local c = GetCfg(mode); return c and c.customLabel and c.customLabel.frameStrata or "" end,
      set = function(_, v)
        ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel.frameStrata = (v ~= "") and v or nil end)
        Refresh()
      end,
      order = orderBase + 0.03, width = 0.7,
      hidden = hideMain,
    },
    customLabelFrameLevel = {
      type = "input", name = "Level",
      desc = "Frame level for the label (higher = on top). 0 = inherit from icon + 2.",
      dialogControl = "ArcUI_EditBox",
      get = function() local c = GetCfg(mode); return tostring(c and c.customLabel and c.customLabel.frameLevel or 0) end,
      set = function(_, v)
        local num = tonumber(v)
        if num then
          num = math.max(0, math.floor(num))
          ApplySetting(mode, function(c) if not c.customLabel then c.customLabel = {} end; c.customLabel.frameLevel = (num > 0) and num or nil end)
          Refresh()
        end
      end,
      order = orderBase + 0.04, width = 0.4,
      hidden = hideMain,
    },
  }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AURA OPTIONS  → called by CDMEnhanceOptions.GetCDMAuraIconsOptionsTable()
-- ═══════════════════════════════════════════════════════════════════════════

function ns.CustomLabelOptions.GetAuraArgs()
  local args = {}
  local mode = "aura"

  -- Header
  args.customLabelHeader = {
    type = "toggle",
    name = function() return H().GetAuraHeaderName("customLabel", "Custom Label") end,
    desc = "Click to expand/collapse. Add custom text overlay to icons. Purple dot indicates per-icon customizations.",
    dialogControl = "CollapsibleHeader",
    get = function() return not H().collapsedSections.customLabel end,
    set = function(_, v) H().collapsedSections.customLabel = not v end,
    order = 168, width = "full",
    hidden = function() return H().HideIfNoAuraSelection() end,
  }

  -- Label 1 (text, size, color, anchor, offsets, state toggles)
  for k, v in pairs(BuildLabelEntries("", 168.10, mode, HideAuraCustomLabel)) do args[k] = v end
  -- Add/Remove buttons
  for k, v in pairs(BuildAddRemoveEntries(168.20, mode, HideAuraCustomLabel)) do args[k] = v end
  -- Label 2
  for k, v in pairs(BuildLabelEntries("2", 168.25, mode, HideAuraCustomLabel2)) do args[k] = v end
  -- Label 3
  for k, v in pairs(BuildLabelEntries("3", 168.35, mode, HideAuraCustomLabel3)) do args[k] = v end
  -- Shared settings (font, outline, strata, level)
  for k, v in pairs(BuildSharedEntries(168.50, mode, HideAuraCustomLabel)) do args[k] = v end

  -- Reset
  args.resetCustomLabel = {
    type = "execute", name = "Reset Section",
    desc = "Reset Custom Label settings to defaults for selected icon(s)",
    order = 168.95, width = 0.7,
    hidden = HideAuraCustomLabel,
    func = function()
      H().ResetAuraSectionSettings("customLabel")
      if ns.CustomLabel and ns.CustomLabel.RefreshAll then ns.CustomLabel.RefreshAll() end
    end,
  }

  return args
end

-- ═══════════════════════════════════════════════════════════════════════════
-- COOLDOWN OPTIONS  → called by CDMEnhanceOptions.GetCDMCooldownIconsOptionsTable()
-- ═══════════════════════════════════════════════════════════════════════════

function ns.CustomLabelOptions.GetCooldownArgs()
  local args = {}
  local mode = "cooldown"

  -- Header
  args.customLabelHeader = {
    type = "toggle",
    name = function() return H().GetCooldownHeaderName("customLabel", "Custom Label") end,
    desc = "Click to expand/collapse. Add custom text overlay to icons. Purple dot indicates per-icon customizations.",
    dialogControl = "CollapsibleHeader",
    get = function() return not H().collapsedSections.customLabel end,
    set = function(_, v) H().collapsedSections.customLabel = not v end,
    order = 186, width = "full",
    hidden = function()
      local h = H()
      if h.HideIfNoCooldownSelection() then return true end
      if h.IsEditingMixedTypes() then return true end
      return false
    end,
  }

  -- Label 1 (text, size, color, anchor, offsets, state toggles)
  for k, v in pairs(BuildLabelEntries("", 186.10, mode, HideCooldownCustomLabel)) do args[k] = v end
  -- Add/Remove buttons
  for k, v in pairs(BuildAddRemoveEntries(186.20, mode, HideCooldownCustomLabel)) do args[k] = v end
  -- Label 2
  for k, v in pairs(BuildLabelEntries("2", 186.25, mode, HideCooldownCustomLabel2)) do args[k] = v end
  -- Label 3
  for k, v in pairs(BuildLabelEntries("3", 186.35, mode, HideCooldownCustomLabel3)) do args[k] = v end
  -- Shared settings (font, outline, strata, level)
  for k, v in pairs(BuildSharedEntries(186.50, mode, HideCooldownCustomLabel)) do args[k] = v end

  -- Reset
  args.resetCustomLabel = {
    type = "execute", name = "Reset Section",
    desc = "Reset Custom Label settings to defaults for selected icon(s)",
    order = 186.95, width = 0.7,
    hidden = HideCooldownCustomLabel,
    func = function()
      H().ResetCooldownSectionSettings("customLabel")
      if ns.CustomLabel and ns.CustomLabel.RefreshAll then ns.CustomLabel.RefreshAll() end
    end,
  }

  return args
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ASSISTED COMBAT HIGHLIGHT OPTIONS
-- Global setting (not per-icon) — shows the Blizzard "next cast" flipbook
-- highlight on CDM frames when Assisted Combat recommends a spell.
-- Includes color tint and Arc Auras Cooldown toggle.
-- ═══════════════════════════════════════════════════════════════════════════

ns.AssistedCombatHighlightOptions = ns.AssistedCombatHighlightOptions or {}

local function GetACHDB()
  if not ArcUIDB then return nil end
  if not ArcUIDB.char then return nil end
  local playerName = UnitName("player")
  local realmName = GetRealmName()
  if not playerName or playerName == "" or not realmName or realmName == "" then return nil end
  local charKey = playerName .. " - " .. realmName
  local charDB = ArcUIDB.char[charKey]
  if not charDB or not charDB.achSettings then return nil end
  return charDB.achSettings
end

local function IsACHAvailable()
  return ns.AssistedCombatHighlight and ns.AssistedCombatHighlight.available
end

function ns.AssistedCombatHighlightOptions.GetCooldownArgs()
  local args = {}

  -- Header
  args.achHeader = {
    type = "toggle",
    name = "Assisted Combat Highlight",
    desc = "Click to expand/collapse.\nShows the animated \"next cast\" highlight on CDM cooldown icons when Assisted Combat recommends a spell.",
    dialogControl = "CollapsibleHeader",
    get = function() return not H().collapsedSections.assistedCombatHighlight end,
    set = function(_, v) H().collapsedSections.assistedCombatHighlight = not v end,
    order = 169, width = "full",
    hidden = function()
      return not IsACHAvailable()
    end,
  }

  local function HideACH()
    if not IsACHAvailable() then return true end
    return H().collapsedSections.assistedCombatHighlight
  end

  -- Description
  args.achDesc = {
    type = "description",
    name = "|cff888888Uses the same animated flipbook overlay Blizzard shows on action bar buttons."
      .. " The highlight appears on your CDM cooldown and utility icons when Assisted Combat"
      .. " recommends a spell, animated in combat and static out of combat.\n"
      .. "Requires Assisted Combat to be enabled in Game Settings > Combat.|r",
    order = 169.01, width = "full", fontSize = "small",
    hidden = HideACH,
  }

  -- Enable toggle
  args.achEnabled = {
    type = "toggle",
    name = "Enable on CDM Frames",
    desc = "Show the Assisted Combat next-cast highlight on CDM cooldown and utility icons.",
    order = 169.02, width = 1.0,
    hidden = HideACH,
    get = function()
      local db = GetACHDB()
      if not db then return false end
      if db.assistedCombatHighlight == nil then return false end
      return db.assistedCombatHighlight
    end,
    set = function(_, v)
      local db = GetACHDB()
      if db then
        db.assistedCombatHighlight = v
      end
      local ACH = ns.AssistedCombatHighlight
      if not ACH then return end
      if v then
        local avail, reason = C_AssistedCombat.IsAvailable()
        if avail then
          ACH.Enable()
        else
          print("|cffFF6600[ArcUI]|r Assisted Combat is not available: " .. (reason or "unknown reason"))
        end
      else
        ACH.Disable()
      end
    end,
  }

  -- Style dropdown
  args.achStyle = {
    type = "select",
    name = "Style",
    desc = "Choose the highlight animation style.\n\n|cff00ffffAnts|r — Blizzard's marching ants border (same as action bar assisted combat highlight).\n\n|cff00ffffProc Glow|r — Blizzard's spell proc burst + loop animation (same as spell activation overlay).",
    order = 169.025, width = 0.6,
    hidden = HideACH,
    values = {
      ants = "Ants",
      proc = "Proc Glow",
    },
    sorting = { "ants", "proc" },
    get = function()
      local db = GetACHDB()
      return db and db.achStyle or "ants"
    end,
    set = function(_, v)
      local db = GetACHDB()
      if db then
        db.achStyle = v
      end
      if ns.AssistedCombatHighlight then
        ns.AssistedCombatHighlight.DestroyAllHighlights()
        ns.AssistedCombatHighlight.Refresh()
      end
    end,
  }

  -- Arc Auras Cooldown toggle
  args.achArcAuras = {
    type = "toggle",
    name = "Include Arc Auras",
    desc = "Also show the Assisted Combat highlight on Arc Auras Cooldown frames (custom spell tracking icons).",
    order = 169.03, width = 1.0,
    hidden = HideACH,
    get = function()
      local db = GetACHDB()
      return db and db.achOnArcAuras or false
    end,
    set = function(_, v)
      local db = GetACHDB()
      if db then
        db.achOnArcAuras = v
      end
      if ns.AssistedCombatHighlight and ns.AssistedCombatHighlight.Refresh then
        ns.AssistedCombatHighlight.Refresh()
      end
    end,
  }

  -- Combat only toggle
  args.achCombatOnly = {
    type = "toggle",
    name = "Combat Only",
    desc = "Only show the next-cast highlight while in combat. Hides it when out of combat.",
    order = 169.035, width = 0.8,
    hidden = HideACH,
    get = function()
      local db = GetACHDB()
      return db and db.achCombatOnly or false
    end,
    set = function(_, v)
      local db = GetACHDB()
      if db then
        db.achCombatOnly = v
      end
      if ns.AssistedCombatHighlight and ns.AssistedCombatHighlight.Refresh then
        ns.AssistedCombatHighlight.Refresh()
      end
    end,
  }

  -- Frame Strata dropdown
  args.achStrata = {
    type = "select",
    name = "Strata",
    desc = "Set the frame strata for the highlight overlay. 'Inherit' uses the parent icon's strata.",
    order = 169.036, width = 0.7,
    hidden = HideACH,
    values = {
      INHERIT    = "Inherit",
      BACKGROUND = "Background",
      LOW        = "Low",
      MEDIUM     = "Medium",
      HIGH       = "High",
      DIALOG     = "Dialog",
    },
    sorting = { "INHERIT", "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG" },
    get = function()
      local db = GetACHDB()
      return db and db.achStrata or "INHERIT"
    end,
    set = function(_, v)
      local db = GetACHDB()
      if db then
        db.achStrata = v
      end
      if ns.AssistedCombatHighlight and ns.AssistedCombatHighlight.RestrataAll then
        ns.AssistedCombatHighlight.RestrataAll()
      end
    end,
  }

  -- Frame Level offset input
  args.achLevel = {
    type = "input",
    name = "Level",
    desc = "Frame level offset above the parent icon. Higher values render on top of other overlays within the same strata.",
    order = 169.037, width = 0.45,
    hidden = HideACH,
    get = function()
      local db = GetACHDB()
      return tostring(db and db.achLevel or 5)
    end,
    set = function(_, v)
      local num = tonumber(v)
      if not num then return end
      num = math.floor(math.max(0, math.min(50, num)))
      local db = GetACHDB()
      if db then
        db.achLevel = num
      end
      if ns.AssistedCombatHighlight and ns.AssistedCombatHighlight.RestrataAll then
        ns.AssistedCombatHighlight.RestrataAll()
      end
    end,
  }

  -- Glow size scale slider
  args.achScale = {
    type = "range",
    name = "Glow Size",
    desc = "Scale the highlight glow relative to the icon. 1.0 = exact icon size, higher values extend the glow beyond the icon edge.",
    order = 169.038, width = 1.0,
    min = 0.5, max = 2.0, step = 0.05,
    isPercent = true,
    hidden = HideACH,
    get = function()
      local db = GetACHDB()
      return db and db.achScale or 1.0
    end,
    set = function(_, v)
      local db = GetACHDB()
      if db then
        db.achScale = v
      end
      if ns.AssistedCombatHighlight and ns.AssistedCombatHighlight.ResizeAll then
        ns.AssistedCombatHighlight.ResizeAll()
      end
    end,
  }

  -- Always Animate toggle
  args.achAlwaysAnimate = {
    type = "toggle",
    name = "Always Animate",
    desc = "Keep the highlight animation playing even when out of combat. When disabled, the highlight freezes on a static frame outside of combat.",
    order = 169.039, width = 0.9,
    hidden = HideACH,
    get = function()
      local db = GetACHDB()
      return db and db.achAlwaysAnimate or false
    end,
    set = function(_, v)
      local db = GetACHDB()
      if db then
        db.achAlwaysAnimate = v
      end
      if ns.AssistedCombatHighlight and ns.AssistedCombatHighlight.RefreshAnimAll then
        ns.AssistedCombatHighlight.RefreshAnimAll()
      end
    end,
  }

  -- Show Burst toggle (proc style only)
  args.achShowBurst = {
    type = "toggle",
    name = "Show Burst Intro",
    desc = "Play the burst intro animation when the next-cast spell changes. Only applies to the Proc Glow style.",
    order = 169.0395, width = 0.9,
    hidden = function()
      if HideACH() then return true end
      local db = GetACHDB()
      return not db or (db.achStyle or "ants") ~= "proc"
    end,
    get = function()
      local db = GetACHDB()
      if not db then return true end
      if db.achShowBurst == nil then return true end
      return db.achShowBurst
    end,
    set = function(_, v)
      local db = GetACHDB()
      if db then
        db.achShowBurst = v
      end
    end,
  }

  -- Color picker
  args.achColor = {
    type = "color",
    name = "Tint Color",
    desc = "Tint the highlight animation. White = default Blizzard color.",
    hasAlpha = true,
    order = 169.04, width = 0.6,
    hidden = HideACH,
    get = function()
      local db = GetACHDB()
      if not db or not db.achColor then return 1, 1, 1, 1 end
      local c = db.achColor
      return c.r or 1, c.g or 1, c.b or 1, c.a or 1
    end,
    set = function(_, r, g, b, a)
      local db = GetACHDB()
      if db then
        db.achColor = { r = r, g = g, b = b, a = a }
      end
      if ns.AssistedCombatHighlight and ns.AssistedCombatHighlight.RecolorAll then
        ns.AssistedCombatHighlight.RecolorAll()
      end
    end,
  }

  -- Reset color button
  args.achResetColor = {
    type = "execute",
    name = "Reset Color",
    desc = "Reset highlight color to default (white).",
    order = 169.05, width = 0.6,
    hidden = function()
      if HideACH() then return true end
      local db = GetACHDB()
      return not db or not db.achColor
    end,
    func = function()
      local db = GetACHDB()
      if db then
        db.achColor = nil
      end
      if ns.AssistedCombatHighlight and ns.AssistedCombatHighlight.RecolorAll then
        ns.AssistedCombatHighlight.RecolorAll()
      end
    end,
  }

  -- Status line
  args.achStatus = {
    type = "description",
    name = function()
      if not C_AssistedCombat then
        return "|cffff6666Assisted Combat system not found on this build.|r"
      end
      local avail, reason = C_AssistedCombat.IsAvailable()
      if avail then
        local rotationSpells = C_AssistedCombat.GetRotationSpells()
        local count = rotationSpells and #rotationSpells or 0
        return "|cff00ff00Assisted Combat is active|r — " .. count .. " rotation spell" .. (count ~= 1 and "s" or "") .. " tracked"
      else
        return "|cffff6666Assisted Combat unavailable:|r " .. (reason or "unknown")
      end
    end,
    order = 169.06, width = "full", fontSize = "medium",
    hidden = HideACH,
  }

  return args
end