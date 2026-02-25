-- ===================================================================
-- ArcUI_TimerBarOptions.lua
-- Custom Bars options panel (Timer Bars + Stack Bars)
-- Timer bars are integrated into CooldownBars system
-- ===================================================================

local ADDON, ns = ...
ns.TimerBarOptions = ns.TimerBarOptions or {}

-- ===================================================================
-- UI STATE
-- ===================================================================
local expandedTimers = {}  -- expandedTimers["timer_timerID"] = true
local expandedSections = {} -- expandedSections["timerID_settings"] = true, etc.

-- Staging state for new generator/spender additions (per timer)
-- [timerID] = { genTrigger, genSpellID, genCooldownID, genStacks, spTrigger, spSpellID, spCooldownID, spStacks }
local stackStagingState = {}
local function GetStaging(timerID)
  if not stackStagingState[timerID] then
    stackStagingState[timerID] = {
      genTrigger = "spellcast", genSpellID = nil, genCooldownID = nil, genStacks = "1",
      spTrigger = "spellcast", spSpellID = nil, spCooldownID = nil, spStacks = "1",
    }
  end
  return stackStagingState[timerID]
end

-- Helper: is this trigger type aura-based?
local function IsAuraTrigger(tt)
  return tt == "auraGained" or tt == "auraLost"
end

-- ===================================================================
-- BAR MODE LABELS
-- ===================================================================
local BAR_MODES = {
  timer = "|cffcc66ffTimer|r",
  toggle = "|cff00ccffToggle|r",
  stack = "|cff66ccffStack|r",
}

local BAR_MODE_ORDER = { "timer", "toggle", "stack" }

-- ===================================================================
-- TRIGGER TYPE LABELS
-- ===================================================================
local TRIGGER_TYPES = {
  spellcast = "Spell Cast",
  ["Aura Gained"] = "Aura Gained",
  ["Aura Lost"] = "Aura Lost",
}

local TRIGGER_TYPE_ORDER = { "spellcast", "Aura Gained", "Aura Lost" }

local CANCEL_METHODS = {
  sameSpell = "Same Spell Cast",
  auraLost = "Aura Lost (Buff Removed)",
  auraGained = "Aura Gained (Buff Applied)",
  overlayHide = "Spell Glow Hide",
  differentSpell = "Different Spell Cast",
}

local CANCEL_METHOD_ORDER = { "sameSpell", "auraLost", "auraGained", "overlayHide", "differentSpell" }

-- ===================================================================
-- STACK TRIGGER TYPES (for generators/spenders)
-- ===================================================================
local STACK_TRIGGER_TYPES = {
  spellcast = "|cffcc66ffSpell Cast|r",
  auraGained = "|cff00ff00Aura Gained|r",
  auraLost = "|cffff4444Aura Lost|r",
  glowShow = "|cffffd700Glow Show|r",
  glowHide = "|cff888888Glow Hide|r",
}
local STACK_TRIGGER_ORDER = { "spellcast", "auraGained", "auraLost", "glowShow", "glowHide" }

local AURA_TYPES = {
  normal = "Buff/Debuff",
  totem = "Totem/Pet/Ground",
}

-- ===================================================================
-- GET SPELL CATALOG DROPDOWN
-- ===================================================================
local function GetSpellCatalogDropdown()
  local values = { [0] = "-- Select Spell --" }
  
  if ns.CooldownBars and ns.CooldownBars.spellCatalog then
    for _, data in ipairs(ns.CooldownBars.spellCatalog) do
      local texture = C_Spell.GetSpellTexture(data.spellID) or 134400
      values[data.spellID] = string.format("|T%d:16:16:0:0|t %s", texture, data.name)
    end
  end
  
  return values
end

-- ===================================================================
-- GET AURA CATALOG DROPDOWN (uses CDM cooldownID)
-- ===================================================================
local function GetAuraCatalogDropdown()
  local values = { [0] = "-- Select Aura --" }
  
  if ns.Catalog and ns.Catalog.GetFilteredCatalog then
    local entries = ns.Catalog.GetFilteredCatalog("tracked", "")
    for _, entry in ipairs(entries) do
      local cooldownID = entry.cooldownID or 0
      if cooldownID > 0 then
        values[cooldownID] = string.format("|T%d:16:16:0:0|t %s", entry.icon, entry.name)
      end
    end
  end
  
  return values
end

-- ===================================================================
-- CREATE TIMER ENTRY (collapsible)
-- ===================================================================
local function CreateTimerEntry(timerID, orderBase)
  local timerKey = "timer_" .. timerID
  
  -- Shared visibility function for stack-mode elements
  local stackHiddenFn = function()
    if not expandedTimers[timerKey] then return true end
    local cfg = ns.CooldownBars.GetTimerConfig(timerID)
    return not cfg or cfg.tracking.barMode ~= "stack"
  end
  
  -- UI mode helper: maps internal state to 3-mode UI
  local function getUIMode()
    local cfg = ns.CooldownBars.GetTimerConfig(timerID)
    if not cfg then return "timer" end
    if cfg.tracking.barMode == "stack" then return "stack" end
    if cfg.tracking.unlimitedDuration then return "toggle" end
    return "timer"
  end
  
  -- Hidden when stack mode (shows for timer AND toggle)
  local timerOrToggleHiddenFn = function()
    if not expandedTimers[timerKey] then return true end
    return getUIMode() == "stack"
  end
  
  -- Sub-section collapsed helpers
  local settingsKey = timerID .. "_settings"
  local genKey = timerID .. "_gen"
  local spKey = timerID .. "_sp"
  local triggerKey = timerID .. "_trigger"
  local cancelKey = timerID .. "_cancel"
  
  local settingsHidden = function()
    if stackHiddenFn() then return true end
    return not expandedSections[settingsKey]
  end
  local genSectionHidden = function()
    if stackHiddenFn() then return true end
    return not expandedSections[genKey]
  end
  local spSectionHidden = function()
    if stackHiddenFn() then return true end
    return not expandedSections[spKey]
  end
  local triggerSectionHidden = function()
    if timerOrToggleHiddenFn() then return true end
    return not expandedSections[triggerKey]
  end
  local cancelSectionHidden = function()
    if not expandedTimers[timerKey] then return true end
    if getUIMode() ~= "toggle" then return true end
    return not expandedSections[cancelKey]
  end
  
  local result = {
    type = "group",
    name = "",
    inline = true,
    order = orderBase,
    args = {
      header = {
        type = "toggle",
        name = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local name = cfg and cfg.tracking.barName or "Timer"
          local barMode = cfg and cfg.tracking.barMode or "timer"
          local triggerType = cfg and cfg.tracking.triggerType or "spellcast"
          local triggerLabel = TRIGGER_TYPES[triggerType] or triggerType
          local duration = cfg and cfg.tracking.customDuration or 10
          
          local iconTexture = 134400
          if cfg and cfg.tracking.iconOverride and cfg.tracking.iconOverride > 0 then
            iconTexture = C_Spell.GetSpellTexture(cfg.tracking.iconOverride) or cfg.tracking.iconOverride
          elseif cfg and cfg.tracking.triggerSpellID and cfg.tracking.triggerSpellID > 0 then
            iconTexture = C_Spell.GetSpellTexture(cfg.tracking.triggerSpellID) or 134400
          elseif cfg and cfg.tracking.triggerCooldownID and cfg.tracking.triggerCooldownID > 0 then
            if ns.Catalog and ns.Catalog.GetEntry then
              local entry = ns.Catalog.GetEntry(cfg.tracking.triggerCooldownID)
              if entry then iconTexture = entry.icon or 134400 end
            end
          elseif cfg and cfg.tracking.generators and cfg.tracking.generators[1] then
            local genID = cfg.tracking.generators[1].spellID
            if genID then iconTexture = C_Spell.GetSpellTexture(genID) or 134400 end
          end
          
          if barMode == "stack" then
            local maxStacks = cfg and cfg.tracking.maxStacks or 4
            local numGens = cfg and cfg.tracking.generators and #cfg.tracking.generators or 0
            local numSpenders = cfg and cfg.tracking.spenders and #cfg.tracking.spenders or 0
            return string.format("|T%d:16:16:0:0|t |cff66ccff%s|r [Stack %d] %dG/%dS",
              iconTexture, name, maxStacks, numGens, numSpenders)
          elseif cfg and cfg.tracking.unlimitedDuration then
            return string.format("|T%d:16:16:0:0|t |cff00ccff%s|r - %s (\226\136\158)",
              iconTexture, name, triggerLabel)
          else
            return string.format("|T%d:16:16:0:0|t |cffcc66ff%s|r - %s (%ss)",
              iconTexture, name, triggerLabel, duration)
          end
        end,
        desc = "Click to expand/collapse settings",
        dialogControl = "CollapsibleHeader",
        get = function() return expandedTimers[timerKey] end,
        set = function(info, value) expandedTimers[timerKey] = value end,
        order = 0,
        width = "full",
      },
      
      enabled = {
        type = "toggle",
        name = "Enabled",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.enabled
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.tracking.enabled = value
            -- Force immediate update: hides bar + kills scripts when disabled
            local barIndex = ns.CooldownBars.activeTimers[timerID]
            local barData = barIndex and ns.CooldownBars.timerBars[barIndex]
            if barData then
              if not value then
                barData.currentStacks = 0
                barData.stackExpiresAt = nil
                barData.isActive = false
              end
              ns.CooldownBars.ForceUpdate(timerID, "timer")
            end
          end
        end,
        order = 1,
        width = 0.5,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      barMode = {
        type = "select",
        name = "Mode",
        desc = "|cffcc66ffTimer|r: Countdown bar triggered by spells/auras.\n\n|cff00ccffToggle|r: Permanent bar that stays active until cancelled (re-cast, aura lost, etc).\n\n|cff66ccffStack|r: Tracks stacks gained by generators and consumed by spenders.",
        values = BAR_MODES,
        sorting = BAR_MODE_ORDER,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if not cfg then return "timer" end
          if cfg.tracking.barMode == "stack" then return "stack" end
          if cfg.tracking.unlimitedDuration then return "toggle" end
          return "timer"
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            if value == "stack" then
              cfg.tracking.barMode = "stack"
              cfg.tracking.unlimitedDuration = nil
              cfg.display.showTickMarks = true
              cfg.display.autoStackTicks = true
            elseif value == "toggle" then
              cfg.tracking.barMode = "timer"
              cfg.tracking.unlimitedDuration = true
            else
              cfg.tracking.barMode = "timer"
              cfg.tracking.unlimitedDuration = nil
            end
            -- Reset state
            local barIndex = ns.CooldownBars.activeTimers[timerID]
            local barData = barIndex and ns.CooldownBars.timerBars[barIndex]
            if barData then
              barData.currentStacks = 0
              barData.stackExpiresAt = nil
              barData.isActive = false
              barData.isStackMode = (value == "stack")
              barData.bar:SetScript("OnUpdate", nil)
            end
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
            ns.CooldownBars.ForceUpdate(timerID, "timer")
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 1.5,
        width = 0.5,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      barName = {
        type = "input",
        name = "Name",
        desc = "Display name for this timer bar",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.barName or ""
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.tracking.barName = value
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
        end,
        order = 2,
        width = 1.0,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      duration = {
        type = "input",
        name = "Duration (sec)",
        desc = "How long the timer runs when triggered (max 86400 = 24h)",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and tostring(cfg.tracking.customDuration) or "10"
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            local num = tonumber(value) or 10
            cfg.tracking.customDuration = math.min(math.max(num, 0.1), 86400)
          end
        end,
        order = 6,
        width = 0.6,
        hidden = function()
          if triggerSectionHidden() then return true end
          return getUIMode() ~= "timer"
        end,
      },
      
      -- ===== CANCEL SETTINGS (collapsible, toggle only) =====
      cancelHeader = {
        type = "toggle",
        name = "|cff00ccffCancel Settings|r",
        desc = "Click to expand/collapse cancel settings",
        dialogControl = "CollapsibleHeader",
        get = function() return expandedSections[cancelKey] end,
        set = function(info, value) expandedSections[cancelKey] = value end,
        order = 6.9,
        width = "full",
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          return getUIMode() ~= "toggle"
        end,
      },
      
      cancelMethod = {
        type = "select",
        name = "Cancel When",
        desc = "How this toggle bar gets cancelled/hidden.\n\n" ..
               "|cffffd700Same Spell Cast|r: Re-casting the trigger spell toggles the bar off (default).\n\n" ..
               "|cffffd700Aura Lost|r: Bar cancels when a specific buff/debuff is removed from you. Best for toggle spells like Burning Rush where re-casting doesn't fire a spell event.\n\n" ..
               "|cffffd700Aura Gained|r: Bar cancels when a specific buff/debuff is applied to you.\n\n" ..
               "|cffffd700Spell Glow Hide|r: Bar cancels when the spell's action bar glow overlay disappears.\n\n" ..
               "|cffffd700Different Spell Cast|r: Bar cancels when you cast a different specified spell.",
        values = CANCEL_METHODS,
        sorting = CANCEL_METHOD_ORDER,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.cancelMethod or "sameSpell"
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then cfg.tracking.cancelMethod = value end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 7,
        width = 1.2,
        hidden = cancelSectionHidden,
      },
      
      cancelAura = {
        type = "select",
        name = "Cancel Aura",
        desc = "Which aura to watch for cancel (from your tracked auras)",
        values = GetAuraCatalogDropdown,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.cancelCooldownID or 0
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.tracking.cancelCooldownID = value
          end
        end,
        order = 7.5,
        width = 1.0,
        hidden = function()
          if cancelSectionHidden() then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local method = cfg and cfg.tracking.cancelMethod or "sameSpell"
          return method ~= "auraLost" and method ~= "auraGained"
        end,
      },
      
      cancelAuraManual = {
        type = "input",
        name = "Cooldown ID",
        desc = "Or enter CDM cooldown ID manually. Leave empty to use the trigger aura.",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local id = cfg and cfg.tracking.cancelCooldownID
          return id and id > 0 and tostring(id) or ""
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            local num = tonumber(value)
            if num and num > 0 then
              cfg.tracking.cancelCooldownID = num
            else
              cfg.tracking.cancelCooldownID = nil
            end
          end
        end,
        order = 7.6,
        width = 0.5,
        hidden = function()
          if cancelSectionHidden() then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local method = cfg and cfg.tracking.cancelMethod or "sameSpell"
          return method ~= "auraLost" and method ~= "auraGained"
        end,
      },
      
      cancelSpellID = {
        type = "input",
        name = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local method = cfg and cfg.tracking.cancelMethod or "sameSpell"
          if method == "overlayHide" then
            return "Glow Spell ID"
          else
            return "Cancel Spell ID"
          end
        end,
        desc = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local method = cfg and cfg.tracking.cancelMethod or "sameSpell"
          if method == "overlayHide" then
            return "Spell ID whose glow overlay to watch. Leave empty to use the trigger spell ID."
          else
            return "Spell ID that cancels this timer. Required for Different Spell Cast."
          end
        end,
        dialogControl = "ArcUI_EditBox",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local id = cfg and cfg.tracking.cancelSpellID
          return id and id > 0 and tostring(id) or ""
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            local num = tonumber(value)
            if num and num > 0 then
              cfg.tracking.cancelSpellID = num
            else
              cfg.tracking.cancelSpellID = nil
            end
          end
        end,
        order = 7.7,
        width = 0.6,
        hidden = function()
          if cancelSectionHidden() then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local method = cfg and cfg.tracking.cancelMethod or "sameSpell"
          return method ~= "differentSpell" and method ~= "overlayHide"
        end,
      },
      
      iconOverride = {
        type = "input",
        name = "Icon ID",
        desc = "Override the bar icon with a spell ID or texture ID. Leave empty to use the trigger spell icon.",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local id = cfg and cfg.tracking.iconOverride
          return id and id > 0 and tostring(id) or ""
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            local num = tonumber(value)
            if num and num > 0 then
              cfg.tracking.iconOverride = num
            else
              cfg.tracking.iconOverride = nil
            end
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 2.5,
        width = 0.5,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      -- ===== TRIGGER (collapsible, timer+toggle only) =====
      triggerHeader = {
        type = "toggle",
        name = function()
          local mode = getUIMode()
          if mode == "timer" then
            return "|cffcc66ffTrigger & Duration|r"
          end
          return "|cff00ccffTrigger|r"
        end,
        desc = "Click to expand/collapse trigger settings",
        dialogControl = "CollapsibleHeader",
        get = function() return expandedSections[triggerKey] end,
        set = function(info, value) expandedSections[triggerKey] = value end,
        order = 2.9,
        width = "full",
        hidden = timerOrToggleHiddenFn,
      },
      
      triggerType = {
        type = "select",
        name = "Trigger",
        desc = "What triggers this timer to start",
        values = TRIGGER_TYPES,
        sorting = TRIGGER_TYPE_ORDER,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.triggerType or "spellcast"
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then cfg.tracking.triggerType = value end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 3,
        width = 0.8,
        hidden = triggerSectionHidden,
      },
      
      lineBreak1 = {
        type = "description",
        name = "",
        order = 3.5,
        width = "full",
        hidden = triggerSectionHidden,
      },
      
      -- SPELLCAST TRIGGER OPTIONS
      triggerSpell = {
        type = "select",
        name = "Trigger Spell",
        desc = "Which spell cast triggers this timer",
        values = GetSpellCatalogDropdown,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.triggerSpellID or 0
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.tracking.triggerSpellID = value
            if value and value > 0 then
              cfg.tracking.iconTextureID = C_Spell.GetSpellTexture(value)
            end
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
        end,
        order = 4,
        width = 1.5,
        hidden = function()
          if triggerSectionHidden() then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or cfg.tracking.triggerType ~= "spellcast"
        end,
      },
      
      triggerSpellManual = {
        type = "input",
        name = "Spell ID",
        desc = "Or enter spell ID manually",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local id = cfg and cfg.tracking.triggerSpellID
          return id and id > 0 and tostring(id) or ""
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            local numVal = tonumber(value)
            cfg.tracking.triggerSpellID = numVal or 0
            if numVal and numVal > 0 then
              cfg.tracking.iconTextureID = C_Spell.GetSpellTexture(numVal)
            end
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
        end,
        order = 4.5,
        width = 0.5,
        hidden = function()
          if triggerSectionHidden() then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or cfg.tracking.triggerType ~= "spellcast"
        end,
      },
      
      -- AURA TRIGGER OPTIONS
      triggerAura = {
        type = "select",
        name = "Trigger Aura",
        desc = "Which aura triggers this timer (from your tracked auras)",
        values = GetAuraCatalogDropdown,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.triggerCooldownID or 0
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.tracking.triggerCooldownID = value
            -- Get icon from catalog entry
            if value and value > 0 and ns.Catalog and ns.Catalog.GetEntry then
              local entry = ns.Catalog.GetEntry(value)
              if entry then
                cfg.tracking.iconTextureID = entry.icon
              end
            end
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
        end,
        order = 4,
        width = 1.5,
        hidden = function()
          if triggerSectionHidden() then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or (cfg.tracking.triggerType ~= "Aura Gained" and cfg.tracking.triggerType ~= "Aura Lost")
        end,
      },
      
      triggerAuraManual = {
        type = "input",
        name = "Cooldown ID",
        desc = "Or enter CDM cooldown ID manually",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local id = cfg and cfg.tracking.triggerCooldownID
          return id and id > 0 and tostring(id) or ""
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            local numVal = tonumber(value)
            cfg.tracking.triggerCooldownID = numVal or 0
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
        end,
        order = 4.5,
        width = 0.5,
        hidden = function()
          if triggerSectionHidden() then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or (cfg.tracking.triggerType ~= "Aura Gained" and cfg.tracking.triggerType ~= "Aura Lost")
        end,
      },
      
      auraType = {
        type = "select",
        name = "Aura Type",
        desc = "Type of aura being tracked",
        values = AURA_TYPES,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.auraType or "normal"
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then cfg.tracking.auraType = value end
        end,
        order = 5,
        width = 0.8,
        hidden = function()
          if triggerSectionHidden() then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or (cfg.tracking.triggerType ~= "Aura Gained" and cfg.tracking.triggerType ~= "Aura Lost")
        end,
      },
      
      lineBreak2 = {
        type = "description",
        name = "",
        order = 5.5,
        width = "full",
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      -- ===== STACK BAR SETTINGS (collapsible) =====
      stackHeader = {
        type = "toggle",
        name = "|cff00ccffStack Settings & Expiry|r",
        desc = "Click to expand/collapse stack settings",
        dialogControl = "CollapsibleHeader",
        get = function() return expandedSections[settingsKey] end,
        set = function(info, value) expandedSections[settingsKey] = value end,
        order = 5.6,
        width = "full",
        hidden = stackHiddenFn,
      },
      
      maxStacks = {
        type = "input",
        name = "Max Stacks",
        desc = "Maximum number of stacks this bar can hold",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and tostring(cfg.tracking.maxStacks) or "4"
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.tracking.maxStacks = math.max(1, math.min(tonumber(value) or 4, 99))
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
          ns.CooldownBars.ForceUpdate(timerID, "timer")
        end,
        order = 5.61,
        width = 0.4,
        hidden = settingsHidden,
      },
      

      
      stackExpireByDuration = {
        type = "toggle",
        name = "Expire by Duration",
        desc = "Stacks expire after a set number of seconds from the last generation.\nDisable if stacks should never time out on their own.",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.stackExpireByDuration ~= false
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then cfg.tracking.stackExpireByDuration = value end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.62,
        width = 0.85,
        hidden = settingsHidden,
      },
      
      stackDuration = {
        type = "input",
        name = "Seconds",
        desc = "Stacks expire after this many seconds from last generation.",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and tostring(cfg.tracking.stackDuration) or "20"
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then cfg.tracking.stackDuration = math.max(0.1, tonumber(value) or 20) end
        end,
        order = 5.621,
        width = 0.3,
        hidden = function()
          if settingsHidden() then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.stackExpireByDuration == false
        end,
      },
      
      stackResetOnDeath = {
        type = "toggle",
        name = "Reset on Death",
        desc = "All stacks are cleared when you die.\nDisable if stacks should persist through death.",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.stackResetOnDeath ~= false
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then cfg.tracking.stackResetOnDeath = value end
        end,
        order = 5.625,
        width = 0.75,
        hidden = settingsHidden,
      },
      
      autoStackTicks = {
        type = "toggle",
        name = "Auto Tick Marks",
        desc = "Show tick marks at each stack boundary.\nDisable to use manual ticks from Appearance.",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.display and cfg.display.autoStackTicks ~= false
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.display.autoStackTicks = value
            if value then cfg.display.showTickMarks = true end
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.63,
        width = 0.8,
        hidden = settingsHidden,
      },
      
      -- ===== GENERATORS (collapsible) =====
      genHeader = {
        type = "toggle",
        name = "|cff00ff00Generators|r",
        desc = "Click to expand/collapse generators",
        dialogControl = "CollapsibleHeader",
        get = function() return expandedSections[genKey] end,
        set = function(info, value) expandedSections[genKey] = value end,
        order = 5.640,
        width = "full",
        hidden = stackHiddenFn,
      },
      
      -- Add controls (on top)
      genAddTrigger = {
        type = "select",
        name = "Trigger",
        desc = "|cffcc66ffSpell Cast|r: Generates stacks when you cast the spell.\n\n|cff00ff00Aura Gained|r: Generates stacks when a buff/debuff appears (CDM frame).\n\n|cffff4444Aura Lost|r: Generates stacks when a buff/debuff disappears.\n\n|cffffd700Glow Show|r: Generates stacks when a spell's proc glow lights up.\n\n|cff888888Glow Hide|r: Generates stacks when a spell's proc glow disappears.",
        values = STACK_TRIGGER_TYPES,
        sorting = STACK_TRIGGER_ORDER,
        get = function() return GetStaging(timerID).genTrigger or "spellcast" end,
        set = function(info, value)
          local staging = GetStaging(timerID)
          staging.genTrigger = value
          staging.genSpellID = nil
          staging.genCooldownID = nil
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.6405,
        width = 0.8,
        hidden = genSectionHidden,
      },
      
      genAddSpell = {
        type = "select",
        name = function()
          local tt = GetStaging(timerID).genTrigger or "spellcast"
          if IsAuraTrigger(tt) then return "Aura" end
          return "Spell"
        end,
        desc = function()
          local tt = GetStaging(timerID).genTrigger or "spellcast"
          if IsAuraTrigger(tt) then return "Pick an aura from your tracked auras" end
          return "Pick a spell from your spellbook"
        end,
        values = function()
          local tt = GetStaging(timerID).genTrigger or "spellcast"
          if IsAuraTrigger(tt) then return GetAuraCatalogDropdown() end
          return GetSpellCatalogDropdown()
        end,
        get = function()
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.genTrigger) then
            return staging.genCooldownID or 0
          end
          return staging.genSpellID or 0
        end,
        set = function(info, value)
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.genTrigger) then
            staging.genCooldownID = (value and value > 0) and value or nil
          else
            staging.genSpellID = (value and value > 0) and value or nil
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.641,
        width = 1.2,
        hidden = genSectionHidden,
      },
      
      genAddID = {
        type = "input",
        name = function()
          local tt = GetStaging(timerID).genTrigger or "spellcast"
          if IsAuraTrigger(tt) then return "CDM ID" end
          return "Spell ID"
        end,
        desc = function()
          local tt = GetStaging(timerID).genTrigger or "spellcast"
          if IsAuraTrigger(tt) then return "Or enter CDM cooldown ID manually" end
          return "Or enter spell ID manually"
        end,
        dialogControl = "ArcUI_EditBox",
        get = function()
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.genTrigger) then
            local id = staging.genCooldownID
            return id and tostring(id) or ""
          end
          local id = staging.genSpellID
          return id and tostring(id) or ""
        end,
        set = function(info, value)
          local id = tonumber(value)
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.genTrigger) then
            staging.genCooldownID = (id and id > 0) and id or nil
          else
            staging.genSpellID = (id and id > 0) and id or nil
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.642,
        width = 0.4,
        hidden = genSectionHidden,
      },
      
      genAddStacks = {
        type = "input",
        name = "Stacks",
        desc = "Stacks generated per trigger",
        dialogControl = "ArcUI_EditBox",
        get = function() return GetStaging(timerID).genStacks or "1" end,
        set = function(info, value) GetStaging(timerID).genStacks = value or "1" end,
        order = 5.643,
        width = 0.3,
        hidden = genSectionHidden,
      },
      
      genAddBtn = {
        type = "execute",
        name = "Add",
        desc = "Add the selected spell/aura as a generator",
        func = function()
          local staging = GetStaging(timerID)
          local tt = staging.genTrigger or "spellcast"
          local stacks = math.max(1, tonumber(staging.genStacks) or 1)
          
          if IsAuraTrigger(tt) then
            local cdID = tonumber(staging.genCooldownID)
            if not cdID or cdID <= 0 then
              print("|cff00ccff[ArcUI]|r Select an aura or enter a cooldown ID first.")
              return
            end
            ns.CooldownBars.AddStackGenerator(timerID, nil, stacks, tt, cdID)
          else
            local spellID = tonumber(staging.genSpellID)
            if not spellID or spellID <= 0 then
              print("|cff00ccff[ArcUI]|r Select a spell or enter a spell ID first.")
              return
            end
            ns.CooldownBars.AddStackGenerator(timerID, spellID, stacks, tt, nil)
          end
          
          ns.CooldownBars.ForceUpdate(timerID, "timer")
          ns.CooldownBars.ApplyAppearance(timerID, "timer")
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("genGrid_" .. timerID)
          if grid then grid:InvalidateCache() end
          staging.genSpellID = nil
          staging.genCooldownID = nil
          staging.genStacks = "1"
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.644,
        width = 0.55,
        disabled = function()
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.genTrigger) then
            return (tonumber(staging.genCooldownID) or 0) <= 0
          end
          return (tonumber(staging.genSpellID) or 0) <= 0
        end,
        hidden = genSectionHidden,
      },
      
      -- Grid icons at orders 5.650..5.660 (merged after result table)
      genGridLabel = {
        type = "description",
        name = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local gens = cfg and cfg.tracking.generators
          if not gens or #gens == 0 then
            return "|cff666666No generators added yet.|r"
          end
          return "|cff888888Click an icon to edit or remove:|r"
        end,
        order = 5.649,
        width = "full",
        hidden = genSectionHidden,
      },
      
      -- Selection panel (appears when grid icon clicked)
      genSelectedLabel = {
        type = "description",
        name = function()
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("genGrid_" .. timerID)
          if not grid or not grid:HasSelection() then return "" end
          local entry = grid:GetSelectedEntry()
          if not entry then return "" end
          local tt = entry.triggerType or "spellcast"
          local ttLabel = STACK_TRIGGER_TYPES[tt] or tt
          local name, tex
          if IsAuraTrigger(tt) then
            local cdEntry = ns.Catalog and ns.Catalog.GetEntry and ns.Catalog.GetEntry(entry.cooldownID)
            name = cdEntry and cdEntry.name or ("CD:" .. (entry.cooldownID or "?"))
            tex = cdEntry and cdEntry.icon or 134400
          else
            name = C_Spell.GetSpellName(entry.spellID) or ("ID:" .. (entry.spellID or "?"))
            tex = C_Spell.GetSpellTexture(entry.spellID) or 134400
          end
          return string.format("|cff00ff00Selected:|r |T%d:14:14:0:0|t %s  %s |cff88ff88(+%d)|r", tex, name, ttLabel, entry.stacks or 1)
        end,
        fontSize = "medium",
        order = 5.665,
        width = "full",
        hidden = function()
          if genSectionHidden() then return true end
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("genGrid_" .. timerID)
          return not grid or not grid:HasSelection()
        end,
      },
      
      genEditStacks = {
        type = "input",
        name = "Stacks Per Trigger",
        desc = "How many stacks this entry generates per trigger",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("genGrid_" .. timerID)
          local entry = grid and grid:GetSelectedEntry()
          return entry and tostring(entry.stacks or 1) or "1"
        end,
        set = function(info, value)
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("genGrid_" .. timerID)
          local entry = grid and grid:GetSelectedEntry()
          if entry then
            entry.stacks = math.max(1, tonumber(value) or 1)
            grid:InvalidateCache()
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.666,
        width = 0.5,
        hidden = function()
          if genSectionHidden() then return true end
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("genGrid_" .. timerID)
          return not grid or not grid:HasSelection()
        end,
      },
      
      genRemoveBtn = {
        type = "execute",
        name = "|cffff4444Remove|r",
        desc = "Remove the selected generator",
        func = function()
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("genGrid_" .. timerID)
          if not grid then return end
          local entry = grid:GetSelectedEntry()
          if not entry then return end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg and cfg.tracking.generators then
            -- Match by index using same composite key
            local tt = entry.triggerType or "spellcast"
            local entryID = IsAuraTrigger(tt) and entry.cooldownID or entry.spellID
            for i, gen in ipairs(cfg.tracking.generators) do
              local genTT = gen.triggerType or "spellcast"
              local genID = IsAuraTrigger(genTT) and gen.cooldownID or gen.spellID
              if genTT == tt and tonumber(genID) == tonumber(entryID) then
                ns.CooldownBars.RemoveStackGenerator(timerID, i)
                break
              end
            end
          end
          grid:ClearSelection()
          grid:InvalidateCache()
          ns.CooldownBars.ForceUpdate(timerID, "timer")
          ns.CooldownBars.ApplyAppearance(timerID, "timer")
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.667,
        width = 0.4,
        hidden = function()
          if genSectionHidden() then return true end
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("genGrid_" .. timerID)
          return not grid or not grid:HasSelection()
        end,
        confirm = function()
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("genGrid_" .. timerID)
          local entry = grid and grid:GetSelectedEntry()
          if entry then
            local tt = entry.triggerType or "spellcast"
            local name
            if IsAuraTrigger(tt) then
              local cdEntry = ns.Catalog and ns.Catalog.GetEntry and ns.Catalog.GetEntry(entry.cooldownID)
              name = cdEntry and cdEntry.name or ("CD:" .. (entry.cooldownID or "?"))
            else
              name = C_Spell.GetSpellName(entry.spellID) or ("ID:" .. (entry.spellID or "?"))
            end
            return "Remove generator: " .. name .. "?"
          end
          return false
        end,
      },
      
      stackBreak2 = {
        type = "description",
        name = " ",
        order = 5.70,
        width = "full",
        hidden = spSectionHidden,
      },
      
      -- ===== SPENDERS (collapsible) =====
      spHeader = {
        type = "toggle",
        name = "|cffff8800Spenders|r",
        desc = "Click to expand/collapse spenders",
        dialogControl = "CollapsibleHeader",
        get = function() return expandedSections[spKey] end,
        set = function(info, value) expandedSections[spKey] = value end,
        order = 5.710,
        width = "full",
        hidden = stackHiddenFn,
      },
      
      -- Add controls (on top)
      spAddTrigger = {
        type = "select",
        name = "Trigger",
        desc = "|cffcc66ffSpell Cast|r: Consumes stacks when you cast the spell.\n\n|cff00ff00Aura Gained|r: Consumes stacks when a buff/debuff appears.\n\n|cffff4444Aura Lost|r: Consumes stacks when a buff/debuff disappears.\n\n|cffffd700Glow Show|r: Consumes stacks when a spell's proc glow lights up.\n\n|cff888888Glow Hide|r: Consumes stacks when a spell's proc glow disappears.",
        values = STACK_TRIGGER_TYPES,
        sorting = STACK_TRIGGER_ORDER,
        get = function() return GetStaging(timerID).spTrigger or "spellcast" end,
        set = function(info, value)
          local staging = GetStaging(timerID)
          staging.spTrigger = value
          staging.spSpellID = nil
          staging.spCooldownID = nil
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.7105,
        width = 0.8,
        hidden = spSectionHidden,
      },
      
      spAddSpell = {
        type = "select",
        name = function()
          local tt = GetStaging(timerID).spTrigger or "spellcast"
          if IsAuraTrigger(tt) then return "Aura" end
          return "Spell"
        end,
        desc = function()
          local tt = GetStaging(timerID).spTrigger or "spellcast"
          if IsAuraTrigger(tt) then return "Pick an aura from your tracked auras" end
          return "Pick a spell from your spellbook"
        end,
        values = function()
          local tt = GetStaging(timerID).spTrigger or "spellcast"
          if IsAuraTrigger(tt) then return GetAuraCatalogDropdown() end
          return GetSpellCatalogDropdown()
        end,
        get = function()
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.spTrigger) then
            return staging.spCooldownID or 0
          end
          return staging.spSpellID or 0
        end,
        set = function(info, value)
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.spTrigger) then
            staging.spCooldownID = (value and value > 0) and value or nil
          else
            staging.spSpellID = (value and value > 0) and value or nil
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.711,
        width = 1.2,
        hidden = spSectionHidden,
      },
      
      spAddID = {
        type = "input",
        name = function()
          local tt = GetStaging(timerID).spTrigger or "spellcast"
          if IsAuraTrigger(tt) then return "CDM ID" end
          return "Spell ID"
        end,
        desc = function()
          local tt = GetStaging(timerID).spTrigger or "spellcast"
          if IsAuraTrigger(tt) then return "Or enter CDM cooldown ID manually" end
          return "Or enter spell ID manually"
        end,
        dialogControl = "ArcUI_EditBox",
        get = function()
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.spTrigger) then
            local id = staging.spCooldownID
            return id and tostring(id) or ""
          end
          local id = staging.spSpellID
          return id and tostring(id) or ""
        end,
        set = function(info, value)
          local id = tonumber(value)
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.spTrigger) then
            staging.spCooldownID = (id and id > 0) and id or nil
          else
            staging.spSpellID = (id and id > 0) and id or nil
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.712,
        width = 0.4,
        hidden = spSectionHidden,
      },
      
      spAddStacks = {
        type = "input",
        name = "Stacks",
        desc = "Stacks consumed per trigger",
        dialogControl = "ArcUI_EditBox",
        get = function() return GetStaging(timerID).spStacks or "1" end,
        set = function(info, value) GetStaging(timerID).spStacks = value or "1" end,
        order = 5.713,
        width = 0.3,
        hidden = spSectionHidden,
      },
      
      spAddBtn = {
        type = "execute",
        name = "Add",
        desc = "Add the selected spell/aura as a spender",
        func = function()
          local staging = GetStaging(timerID)
          local tt = staging.spTrigger or "spellcast"
          local stacks = math.max(1, tonumber(staging.spStacks) or 1)
          
          if IsAuraTrigger(tt) then
            local cdID = tonumber(staging.spCooldownID)
            if not cdID or cdID <= 0 then
              print("|cff00ccff[ArcUI]|r Select an aura or enter a cooldown ID first.")
              return
            end
            ns.CooldownBars.AddStackSpender(timerID, nil, stacks, tt, cdID)
          else
            local spellID = tonumber(staging.spSpellID)
            if not spellID or spellID <= 0 then
              print("|cff00ccff[ArcUI]|r Select a spell or enter a spell ID first.")
              return
            end
            ns.CooldownBars.AddStackSpender(timerID, spellID, stacks, tt, nil)
          end
          
          ns.CooldownBars.ForceUpdate(timerID, "timer")
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("spGrid_" .. timerID)
          if grid then grid:InvalidateCache() end
          staging.spSpellID = nil
          staging.spCooldownID = nil
          staging.spStacks = "1"
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.714,
        width = 0.55,
        disabled = function()
          local staging = GetStaging(timerID)
          if IsAuraTrigger(staging.spTrigger) then
            return (tonumber(staging.spCooldownID) or 0) <= 0
          end
          return (tonumber(staging.spSpellID) or 0) <= 0
        end,
        hidden = spSectionHidden,
      },
      
      -- Grid icons at orders 5.720..5.730 (merged after result table)
      spGridLabel = {
        type = "description",
        name = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local sps = cfg and cfg.tracking.spenders
          if not sps or #sps == 0 then
            return "|cff666666No spenders added yet.|r"
          end
          return "|cff888888Click an icon to edit or remove:|r"
        end,
        order = 5.719,
        width = "full",
        hidden = spSectionHidden,
      },
      
      -- Selection panel (appears when grid icon clicked)
      spSelectedLabel = {
        type = "description",
        name = function()
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("spGrid_" .. timerID)
          if not grid or not grid:HasSelection() then return "" end
          local entry = grid:GetSelectedEntry()
          if not entry then return "" end
          local tt = entry.triggerType or "spellcast"
          local ttLabel = STACK_TRIGGER_TYPES[tt] or tt
          local name, tex
          if IsAuraTrigger(tt) then
            local cdEntry = ns.Catalog and ns.Catalog.GetEntry and ns.Catalog.GetEntry(entry.cooldownID)
            name = cdEntry and cdEntry.name or ("CD:" .. (entry.cooldownID or "?"))
            tex = cdEntry and cdEntry.icon or 134400
          else
            name = C_Spell.GetSpellName(entry.spellID) or ("ID:" .. (entry.spellID or "?"))
            tex = C_Spell.GetSpellTexture(entry.spellID) or 134400
          end
          return string.format("|cffff8800Selected:|r |T%d:14:14:0:0|t %s  %s |cffffcc88(-%d)|r", tex, name, ttLabel, entry.stacks or 1)
        end,
        fontSize = "medium",
        order = 5.735,
        width = "full",
        hidden = function()
          if spSectionHidden() then return true end
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("spGrid_" .. timerID)
          return not grid or not grid:HasSelection()
        end,
      },
      
      spEditStacks = {
        type = "input",
        name = "Stacks Per Trigger",
        desc = "How many stacks this entry consumes per trigger",
        dialogControl = "ArcUI_EditBox",
        get = function()
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("spGrid_" .. timerID)
          local entry = grid and grid:GetSelectedEntry()
          return entry and tostring(entry.stacks or 1) or "1"
        end,
        set = function(info, value)
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("spGrid_" .. timerID)
          local entry = grid and grid:GetSelectedEntry()
          if entry then
            entry.stacks = math.max(1, tonumber(value) or 1)
            grid:InvalidateCache()
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.736,
        width = 0.5,
        hidden = function()
          if spSectionHidden() then return true end
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("spGrid_" .. timerID)
          return not grid or not grid:HasSelection()
        end,
      },
      
      spRemoveBtn = {
        type = "execute",
        name = "|cffff4444Remove|r",
        desc = "Remove the selected spender",
        func = function()
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("spGrid_" .. timerID)
          if not grid then return end
          local entry = grid:GetSelectedEntry()
          if not entry then return end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg and cfg.tracking.spenders then
            local tt = entry.triggerType or "spellcast"
            local entryID = IsAuraTrigger(tt) and entry.cooldownID or entry.spellID
            for i, sp in ipairs(cfg.tracking.spenders) do
              local spTT = sp.triggerType or "spellcast"
              local spID = IsAuraTrigger(spTT) and sp.cooldownID or sp.spellID
              if spTT == tt and tonumber(spID) == tonumber(entryID) then
                ns.CooldownBars.RemoveStackSpender(timerID, i)
                break
              end
            end
          end
          grid:ClearSelection()
          grid:InvalidateCache()
          ns.CooldownBars.ForceUpdate(timerID, "timer")
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 5.737,
        width = 0.4,
        hidden = function()
          if spSectionHidden() then return true end
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("spGrid_" .. timerID)
          return not grid or not grid:HasSelection()
        end,
        confirm = function()
          local grid = LibStub("ArcUI-CatalogGridBuilder-1.0"):GetGrid("spGrid_" .. timerID)
          local entry = grid and grid:GetSelectedEntry()
          if entry then
            local tt = entry.triggerType or "spellcast"
            local name
            if IsAuraTrigger(tt) then
              local cdEntry = ns.Catalog and ns.Catalog.GetEntry and ns.Catalog.GetEntry(entry.cooldownID)
              name = cdEntry and cdEntry.name or ("CD:" .. (entry.cooldownID or "?"))
            else
              name = C_Spell.GetSpellName(entry.spellID) or ("ID:" .. (entry.spellID or "?"))
            end
            return "Remove spender: " .. name .. "?"
          end
          return false
        end,
      },
      
      stackBreak3 = {
        type = "description",
        name = "",
        order = 5.77,
        width = "full",
        hidden = stackHiddenFn,
      },
      
      stackTestBtn = {
        type = "execute",
        name = "Test (+Max)",
        desc = "Set stacks to max for testing",
        func = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local maxS = cfg and cfg.tracking.maxStacks or 4
          ns.CooldownBars.SetStacks(timerID, maxS)
          print(string.format("|cff00ccff[ArcUI]|r Stack bar %d set to %d/%d", timerID, maxS, maxS))
        end,
        order = 5.79,
        width = 0.65,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or cfg.tracking.barMode ~= "stack"
        end,
      },
      
      stackResetBtn = {
        type = "execute",
        name = "Reset (0)",
        desc = "Reset stacks to 0",
        func = function()
          ns.CooldownBars.SetStacks(timerID, 0)
          print(string.format("|cff00ccff[ArcUI]|r Stack bar %d reset to 0", timerID))
        end,
        order = 5.80,
        width = 0.5,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or cfg.tracking.barMode ~= "stack"
        end,
      },
      
      lineBreak3 = {
        type = "description",
        name = "",
        order = 8,
        width = "full",
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      hideWhenInactive = {
        type = "toggle",
        name = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg and cfg.tracking.barMode == "stack" then
            return "Hide When Empty"
          end
          return "Hide When Inactive"
        end,
        desc = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg and cfg.tracking.barMode == "stack" then
            return "Hide the bar when stacks are at 0"
          end
          return "Hide the bar when the timer is not running"
        end,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.behavior and cfg.behavior.hideWhenInactive
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.behavior = cfg.behavior or {}
            cfg.behavior.hideWhenInactive = value
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
        end,
        order = 9,
        width = 0.75,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      hideOutOfCombat = {
        type = "toggle",
        name = "Hide Out of Combat",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.behavior and cfg.behavior.hideOutOfCombat
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.behavior = cfg.behavior or {}
            cfg.behavior.hideOutOfCombat = value
            ns.CooldownBars.ApplyAppearance(timerID, "timer")
          end
        end,
        order = 10,
        width = 0.9,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      -- Spec 1 toggle
      spec1 = {
        type = "toggle",
        name = function()
          local _, specName, _, specIcon = GetSpecializationInfo(1)
          if specIcon and specName then
            return string.format("|T%s:14:14:0:0|t %s", specIcon, specName)
          end
          return specName or "Spec 1"
        end,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if not cfg or not cfg.behavior or not cfg.behavior.showOnSpecs then return true end
          if #cfg.behavior.showOnSpecs == 0 then return true end
          for _, spec in ipairs(cfg.behavior.showOnSpecs) do
            if spec == 1 then return true end
          end
          return false
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            if not cfg.behavior then cfg.behavior = {} end
            if not cfg.behavior.showOnSpecs then cfg.behavior.showOnSpecs = {} end
            if not value and #cfg.behavior.showOnSpecs == 0 then
              local numSpecs = GetNumSpecializations() or 4
              for i = 1, numSpecs do
                if i ~= 1 then table.insert(cfg.behavior.showOnSpecs, i) end
              end
            elseif value then
              local found = false
              for _, spec in ipairs(cfg.behavior.showOnSpecs) do
                if spec == 1 then found = true break end
              end
              if not found then table.insert(cfg.behavior.showOnSpecs, 1) end
            else
              for i = #cfg.behavior.showOnSpecs, 1, -1 do
                if cfg.behavior.showOnSpecs[i] == 1 then table.remove(cfg.behavior.showOnSpecs, i) end
              end
            end
            if ns.CooldownBars.UpdateBarVisibilityForSpec then
              ns.CooldownBars.UpdateBarVisibilityForSpec()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
          end
        end,
        order = 10.1,
        width = 0.75,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      -- Spec 2 toggle
      spec2 = {
        type = "toggle",
        name = function()
          local _, specName, _, specIcon = GetSpecializationInfo(2)
          if specIcon and specName then
            return string.format("|T%s:14:14:0:0|t %s", specIcon, specName)
          end
          return specName or "Spec 2"
        end,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if not cfg or not cfg.behavior or not cfg.behavior.showOnSpecs then return true end
          if #cfg.behavior.showOnSpecs == 0 then return true end
          for _, spec in ipairs(cfg.behavior.showOnSpecs) do
            if spec == 2 then return true end
          end
          return false
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            if not cfg.behavior then cfg.behavior = {} end
            if not cfg.behavior.showOnSpecs then cfg.behavior.showOnSpecs = {} end
            if not value and #cfg.behavior.showOnSpecs == 0 then
              local numSpecs = GetNumSpecializations() or 4
              for i = 1, numSpecs do
                if i ~= 2 then table.insert(cfg.behavior.showOnSpecs, i) end
              end
            elseif value then
              local found = false
              for _, spec in ipairs(cfg.behavior.showOnSpecs) do
                if spec == 2 then found = true break end
              end
              if not found then table.insert(cfg.behavior.showOnSpecs, 2) end
            else
              for i = #cfg.behavior.showOnSpecs, 1, -1 do
                if cfg.behavior.showOnSpecs[i] == 2 then table.remove(cfg.behavior.showOnSpecs, i) end
              end
            end
            if ns.CooldownBars.UpdateBarVisibilityForSpec then
              ns.CooldownBars.UpdateBarVisibilityForSpec()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
          end
        end,
        order = 10.2,
        width = 0.75,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      -- Spec 3 toggle
      spec3 = {
        type = "toggle",
        name = function()
          local _, specName, _, specIcon = GetSpecializationInfo(3)
          if specIcon and specName then
            return string.format("|T%s:14:14:0:0|t %s", specIcon, specName)
          end
          return specName or "Spec 3"
        end,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if not cfg or not cfg.behavior or not cfg.behavior.showOnSpecs then return true end
          if #cfg.behavior.showOnSpecs == 0 then return true end
          for _, spec in ipairs(cfg.behavior.showOnSpecs) do
            if spec == 3 then return true end
          end
          return false
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            if not cfg.behavior then cfg.behavior = {} end
            if not cfg.behavior.showOnSpecs then cfg.behavior.showOnSpecs = {} end
            if not value and #cfg.behavior.showOnSpecs == 0 then
              local numSpecs = GetNumSpecializations() or 4
              for i = 1, numSpecs do
                if i ~= 3 then table.insert(cfg.behavior.showOnSpecs, i) end
              end
            elseif value then
              local found = false
              for _, spec in ipairs(cfg.behavior.showOnSpecs) do
                if spec == 3 then found = true break end
              end
              if not found then table.insert(cfg.behavior.showOnSpecs, 3) end
            else
              for i = #cfg.behavior.showOnSpecs, 1, -1 do
                if cfg.behavior.showOnSpecs[i] == 3 then table.remove(cfg.behavior.showOnSpecs, i) end
              end
            end
            if ns.CooldownBars.UpdateBarVisibilityForSpec then
              ns.CooldownBars.UpdateBarVisibilityForSpec()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
          end
        end,
        order = 10.3,
        width = 0.75,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local numSpecs = GetNumSpecializations()
          return numSpecs < 3
        end,
      },
      
      -- Spec 4 toggle
      spec4 = {
        type = "toggle",
        name = function()
          local _, specName, _, specIcon = GetSpecializationInfo(4)
          if specIcon and specName then
            return string.format("|T%s:14:14:0:0|t %s", specIcon, specName)
          end
          return specName or "Spec 4"
        end,
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if not cfg or not cfg.behavior or not cfg.behavior.showOnSpecs then return true end
          if #cfg.behavior.showOnSpecs == 0 then return true end
          for _, spec in ipairs(cfg.behavior.showOnSpecs) do
            if spec == 4 then return true end
          end
          return false
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            if not cfg.behavior then cfg.behavior = {} end
            if not cfg.behavior.showOnSpecs then cfg.behavior.showOnSpecs = {} end
            if not value and #cfg.behavior.showOnSpecs == 0 then
              local numSpecs = GetNumSpecializations() or 4
              for i = 1, numSpecs do
                if i ~= 4 then table.insert(cfg.behavior.showOnSpecs, i) end
              end
            elseif value then
              local found = false
              for _, spec in ipairs(cfg.behavior.showOnSpecs) do
                if spec == 4 then found = true break end
              end
              if not found then table.insert(cfg.behavior.showOnSpecs, 4) end
            else
              for i = #cfg.behavior.showOnSpecs, 1, -1 do
                if cfg.behavior.showOnSpecs[i] == 4 then table.remove(cfg.behavior.showOnSpecs, i) end
              end
            end
            if ns.CooldownBars.UpdateBarVisibilityForSpec then
              ns.CooldownBars.UpdateBarVisibilityForSpec()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
          end
        end,
        order = 10.4,
        width = 0.75,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local numSpecs = GetNumSpecializations()
          return numSpecs < 4
        end,
      },
      
      -- Talent conditions (Arc Auras style - full row layout)
      talentCondHeader = {
        type = "description",
        name = "\n|cffffd700Talent Conditions:|r",
        order = 10.5,
        width = "full",
        fontSize = "medium",
        hidden = function() return not expandedTimers[timerKey] end,
      },
      talentCondDesc = {
        type = "description",
        name = "|cff888888Only show this timer bar when specific talents are active. If no conditions are set, the bar shows whenever the spell is known.|r",
        order = 10.51,
        width = "full",
        fontSize = "small",
        hidden = function() return not expandedTimers[timerKey] end,
      },
      talentCondSummary = {
        type = "description",
        name = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if not cfg or not cfg.behavior then return "" end
          if cfg.behavior.talentConditions and #cfg.behavior.talentConditions > 0 then
            if ns.TalentPicker and ns.TalentPicker.GetConditionSummary then
              return ns.TalentPicker.GetConditionSummary(cfg.behavior.talentConditions, cfg.behavior.talentMatchMode)
            end
          end
          return ""
        end,
        order = 10.52,
        width = "full",
        fontSize = "small",
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or not cfg.behavior or not cfg.behavior.talentConditions or #cfg.behavior.talentConditions == 0
        end,
      },
      talentCondEdit = {
        type = "execute",
        name = "Edit Talent Conditions",
        desc = "Open the talent picker to choose which talents must be active (or inactive) for this timer bar to show.",
        order = 10.6,
        width = 1.0,
        func = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          local existingConditions = cfg and cfg.behavior and cfg.behavior.talentConditions
          local matchMode = cfg and cfg.behavior and cfg.behavior.talentMatchMode or "all"
          
          if ns.TalentPicker and ns.TalentPicker.OpenPicker then
            ns.TalentPicker.OpenPicker(existingConditions, matchMode, function(conditions, newMatchMode)
              local timerCfg = ns.CooldownBars.GetTimerConfig(timerID)
              if timerCfg then
                if not timerCfg.behavior then timerCfg.behavior = {} end
                timerCfg.behavior.talentConditions = conditions
                timerCfg.behavior.talentMatchMode = newMatchMode
                if ns.CooldownBars and ns.CooldownBars.UpdateBarVisibilityForSpec then
                  ns.CooldownBars.UpdateBarVisibilityForSpec()
                end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
              end
            end)
          else
            print("|cff00ccffArc UI|r: Talent picker not available")
          end
        end,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      talentCondClear = {
        type = "execute",
        name = "Clear",
        desc = "Remove all talent conditions. The bar will show whenever the spell is known.",
        order = 10.7,
        width = 0.5,
        func = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg and cfg.behavior then
            cfg.behavior.talentConditions = nil
            cfg.behavior.talentMatchMode = nil
            if ns.CooldownBars and ns.CooldownBars.UpdateBarVisibilityForSpec then
              ns.CooldownBars.UpdateBarVisibilityForSpec()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
          end
        end,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or not cfg.behavior or not cfg.behavior.talentConditions or #cfg.behavior.talentConditions == 0
        end,
      },
      
      lineBreak4 = {
        type = "description",
        name = "",
        order = 11,
        width = "full",
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      testBtn = {
        type = "execute",
        name = "Test Timer",
        desc = "Start this timer now to test it",
        func = function()
          ns.CooldownBars.StartTimer(timerID)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          print("|cffcc66ff[TimerBars]|r Testing: " .. (cfg and cfg.tracking.barName or "Timer"))
        end,
        order = 12,
        width = 0.6,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and cfg.tracking.barMode == "stack"
        end,
      },
      
      appearanceBtn = {
        type = "execute",
        name = "Edit Appearance",
        desc = "Open Appearance options for this timer bar",
        func = function()
          if ns.AppearanceOptions and ns.AppearanceOptions.SetSelectedBar then
            ns.AppearanceOptions.SetSelectedBar("timer", timerID)
          end
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
          LibStub("AceConfigDialog-3.0"):SelectGroup("ArcUI", "bars", "appearance")
        end,
        order = 12.5,
        width = 0.85,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      deleteBtn = {
        type = "execute",
        name = "|cffff4444Delete|r",
        desc = "Remove this timer bar",
        func = function()
          ns.CooldownBars.RemoveTimerBar(timerID)
          LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        order = 13,
        width = 0.5,
        confirm = true,
        confirmText = "Delete this timer bar?",
        hidden = function() return not expandedTimers[timerKey] end,
      },
    },
  }
  
  
  -- ===== BUILD GENERATOR GRID =====
  local CGB = LibStub("ArcUI-CatalogGridBuilder-1.0")
  
  local genGridID = "genGrid_" .. timerID
  local genGrid = CGB:GetGrid(genGridID)
  if not genGrid then
    genGrid = CGB:New({
    id            = "genGrid_" .. timerID,
    maxIcons      = 10,
    iconWidth     = 28,
    iconHeight    = 28,
    cellWidth     = 0.20,
    orderBase     = 5.650,
    orderStep     = 0.001,
    selectionMode = "toggle",
    
    dataProvider = function(grid)
      local cfg = ns.CooldownBars.GetTimerConfig(timerID)
      return cfg and cfg.tracking.generators or {}
    end,
    
    getEntryID = function(entry)
      local tt = entry.triggerType or "spellcast"
      local id = IsAuraTrigger(tt) and entry.cooldownID or entry.spellID
      return tt .. ":" .. tostring(id or 0)
    end,
    
    getEntryIcon = function(entry)
      local tt = entry.triggerType or "spellcast"
      if IsAuraTrigger(tt) then
        if ns.Catalog and ns.Catalog.GetEntry then
          local cdEntry = ns.Catalog.GetEntry(entry.cooldownID)
          if cdEntry then return cdEntry.icon or 134400 end
        end
        return 134400
      end
      return C_Spell.GetSpellTexture(entry.spellID) or 134400
    end,
    
    getEntryName = function(entry, state)
      local stacks = entry.stacks or 1
      local tt = entry.triggerType or "spellcast"
      -- Color-code by trigger type
      local prefix = ""
      if tt == "auraGained" then prefix = "|cff00ff00A+|r"
      elseif tt == "auraLost" then prefix = "|cffff4444A-|r"
      elseif tt == "glowShow" then prefix = "|cffffd700G+|r"
      elseif tt == "glowHide" then prefix = "|cff888888G-|r"
      end
      if state.selected then
        return prefix .. "|cff00ff00+" .. stacks .. "|r"
      end
      return prefix .. "|cff88ff88+" .. stacks .. "|r"
    end,
    
    getEntryDesc = function(entry, state)
      local tt = entry.triggerType or "spellcast"
      local ttLabel = STACK_TRIGGER_TYPES[tt] or "Spell Cast"
      local name, idLabel
      if IsAuraTrigger(tt) then
        if ns.Catalog and ns.Catalog.GetEntry then
          local cdEntry = ns.Catalog.GetEntry(entry.cooldownID)
          name = cdEntry and cdEntry.name or "Unknown Aura"
        else
          name = "Unknown Aura"
        end
        idLabel = "Cooldown ID: " .. (entry.cooldownID or "?")
      else
        name = C_Spell.GetSpellName(entry.spellID) or "Unknown"
        idLabel = "Spell ID: " .. (entry.spellID or "?")
      end
      local desc = name .. "\n" .. idLabel .. "\nTrigger: " .. ttLabel .. "\nStacks: +" .. (entry.stacks or 1)
      if state.selected then
        desc = desc .. "\n|cff00ff00Selected - edit below|r"
      else
        desc = desc .. "\n|cff888888Click to select|r"
      end
      return desc
    end,
    
    onSelectionChanged = function(grid)
      LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
    end,
  })
  end -- if not genGrid
  
  -- Merge generator grid icons into result.args
  local genArgs = genGrid:GetArgs()
  for k, v in pairs(genArgs) do
    -- Inject genSectionHidden into each grid icon's hidden
    local origHidden = v.hidden
    v.hidden = function()
      if genSectionHidden() then return true end
      return origHidden and origHidden()
    end
    result.args[k] = v
  end
  
  -- ===== BUILD SPENDER GRID =====
  local spGridID = "spGrid_" .. timerID
  local spGrid = CGB:GetGrid(spGridID)
  if not spGrid then
    spGrid = CGB:New({
    id            = "spGrid_" .. timerID,
    maxIcons      = 10,
    iconWidth     = 28,
    iconHeight    = 28,
    cellWidth     = 0.20,
    orderBase     = 5.720,
    orderStep     = 0.001,
    selectionMode = "toggle",
    
    dataProvider = function(grid)
      local cfg = ns.CooldownBars.GetTimerConfig(timerID)
      return cfg and cfg.tracking.spenders or {}
    end,
    
    getEntryID = function(entry)
      local tt = entry.triggerType or "spellcast"
      local id = IsAuraTrigger(tt) and entry.cooldownID or entry.spellID
      return tt .. ":" .. tostring(id or 0)
    end,
    
    getEntryIcon = function(entry)
      local tt = entry.triggerType or "spellcast"
      if IsAuraTrigger(tt) then
        if ns.Catalog and ns.Catalog.GetEntry then
          local cdEntry = ns.Catalog.GetEntry(entry.cooldownID)
          if cdEntry then return cdEntry.icon or 134400 end
        end
        return 134400
      end
      return C_Spell.GetSpellTexture(entry.spellID) or 134400
    end,
    
    getEntryName = function(entry, state)
      local stacks = entry.stacks or 1
      local tt = entry.triggerType or "spellcast"
      local prefix = ""
      if tt == "auraGained" then prefix = "|cff00ff00A+|r"
      elseif tt == "auraLost" then prefix = "|cffff4444A-|r"
      elseif tt == "glowShow" then prefix = "|cffffd700G+|r"
      elseif tt == "glowHide" then prefix = "|cff888888G-|r"
      end
      if state.selected then
        return prefix .. "|cffff8800-" .. stacks .. "|r"
      end
      return prefix .. "|cffffcc88-" .. stacks .. "|r"
    end,
    
    getEntryDesc = function(entry, state)
      local tt = entry.triggerType or "spellcast"
      local ttLabel = STACK_TRIGGER_TYPES[tt] or "Spell Cast"
      local name, idLabel
      if IsAuraTrigger(tt) then
        if ns.Catalog and ns.Catalog.GetEntry then
          local cdEntry = ns.Catalog.GetEntry(entry.cooldownID)
          name = cdEntry and cdEntry.name or "Unknown Aura"
        else
          name = "Unknown Aura"
        end
        idLabel = "Cooldown ID: " .. (entry.cooldownID or "?")
      else
        name = C_Spell.GetSpellName(entry.spellID) or "Unknown"
        idLabel = "Spell ID: " .. (entry.spellID or "?")
      end
      local desc = name .. "\n" .. idLabel .. "\nTrigger: " .. ttLabel .. "\nStacks: -" .. (entry.stacks or 1)
      if state.selected then
        desc = desc .. "\n|cffff8800Selected - edit below|r"
      else
        desc = desc .. "\n|cff888888Click to select|r"
      end
      return desc
    end,
    
    onSelectionChanged = function(grid)
      LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
    end,
  })
  end -- if not spGrid
  
  -- Merge spender grid icons into result.args
  local spArgs = spGrid:GetArgs()
  for k, v in pairs(spArgs) do
    local origHidden = v.hidden
    v.hidden = function()
      if spSectionHidden() then return true end
      return origHidden and origHidden()
    end
    result.args[k] = v
  end
  
  return result
end

-- ===================================================================
-- BUILD OPTIONS TABLE
-- ===================================================================
function ns.TimerBarOptions.GetOptionsTable()
  local args = {
    description = {
      type = "description",
      name = "|cffcc66ffCustom Bars|r let you create |cffcc66ffTimer|r bars (countdown), |cff00ccffToggle|r bars (on/off), or |cff66ccffStack|r bars (generators/spenders).\n\n" ..
             "1. Click a create button below\n" ..
             "2. Configure trigger/stack settings\n" ..
             "3. Click |cffffd700Edit Appearance|r to customize the look\n",
      fontSize = "medium",
      order = 1,
    },
    
    createHeader = {
      type = "header",
      name = "Create New Bar",
      order = 10,
    },
    
    createTimerBtn = {
      type = "execute",
      name = "|cffcc66ffNew Timer|r",
      desc = "Add a new countdown timer bar triggered by spells or auras",
      func = function()
        local timerID = ns.CooldownBars.GenerateTimerID()
        ns.CooldownBars.AddTimerBar(timerID)
        local cfg = ns.CooldownBars.GetTimerConfig(timerID)
        if cfg then
          cfg.tracking.barMode = "timer"
          cfg.tracking.unlimitedDuration = nil
          cfg.tracking.barName = "Timer"
        end
        expandedTimers["timer_" .. timerID] = true
        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
      end,
      order = 11,
      width = 0.6,
    },
    
    createToggleBtn = {
      type = "execute",
      name = "|cff00ccffNew Toggle|r",
      desc = "Add a new toggle bar (stays active until cancelled by re-cast, aura, etc)",
      func = function()
        local timerID = ns.CooldownBars.GenerateTimerID()
        ns.CooldownBars.AddTimerBar(timerID)
        local cfg = ns.CooldownBars.GetTimerConfig(timerID)
        if cfg then
          cfg.tracking.barMode = "timer"
          cfg.tracking.unlimitedDuration = true
          cfg.tracking.barName = "Toggle"
          cfg.display.barColor = {r = 0, g = 0.8, b = 0.8, a = 1}
        end
        ns.CooldownBars.ApplyAppearance(timerID, "timer")
        expandedTimers["timer_" .. timerID] = true
        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
      end,
      order = 11.5,
      width = 0.6,
    },
    
    createStackBtn = {
      type = "execute",
      name = "|cff66ccffNew Stack|r",
      desc = "Add a new stack bar (tracks stacks from spell generators/spenders)",
      func = function()
        local timerID = ns.CooldownBars.GenerateTimerID()
        ns.CooldownBars.AddTimerBar(timerID)
        local cfg = ns.CooldownBars.GetTimerConfig(timerID)
        if cfg then
          cfg.tracking.barMode = "stack"
          cfg.tracking.barName = "Stack Bar"
          cfg.display.barColor = {r = 0, g = 0.8, b = 1, a = 1}  -- Cyan for stack bars
          -- Auto-enable tick marks at stack boundaries
          cfg.display.showTickMarks = true
          cfg.display.autoStackTicks = true
          cfg.display.tickColor = {r = 0, g = 0, b = 0, a = 0.8}
          cfg.display.tickThickness = 2
        end
        ns.CooldownBars.ApplyAppearance(timerID, "timer")
        expandedTimers["timer_" .. timerID] = true
        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
      end,
      order = 12,
      width = 0.6,
    },
    
    activeHeader = {
      type = "header",
      name = "Active Custom Bars",
      order = 100,
    },
    
    activeDesc = {
      type = "description",
      name = function()
        local timerCount = 0
        local toggleCount = 0
        local stackCount = 0
        local checkConfigs = (ns.db and ns.db.char and ns.db.char.timerBarConfigs) or {}
        for tid, cfg in pairs(checkConfigs) do
          if cfg.tracking.barMode == "stack" then
            stackCount = stackCount + 1
          elseif cfg.tracking.unlimitedDuration then
            toggleCount = toggleCount + 1
          else
            timerCount = timerCount + 1
          end
        end
        if timerCount == 0 and toggleCount == 0 and stackCount == 0 then
          return "|cff888888No custom bars configured. Create one above.|r"
        end
        return string.format("|cff888888%d timer(s), %d toggle(s), %d stack(s). Click to expand settings.|r", timerCount, toggleCount, stackCount)
      end,
      fontSize = "medium",
      order = 101,
    },
  }
  
  -- Add entries for each configured timer (from DB, not just runtime activeTimers)
  local orderBase = 110
  local seenTimers = {}
  
  -- First: all timers from saved configs (always available)
  if ns.db and ns.db.char and ns.db.char.timerBarConfigs then
    for timerID in pairs(ns.db.char.timerBarConfigs) do
      args["timer_" .. timerID] = CreateTimerEntry(timerID, orderBase)
      orderBase = orderBase + 1
      seenTimers[timerID] = true
    end
  end
  
  -- Second: any runtime-active timers not yet in saved configs (freshly created)
  for timerID in pairs(ns.CooldownBars.activeTimers or {}) do
    if not seenTimers[timerID] then
      args["timer_" .. timerID] = CreateTimerEntry(timerID, orderBase)
      orderBase = orderBase + 1
    end
  end
  
  return {
    type = "group",
    name = "Custom Bars",
    args = args,
  }
end