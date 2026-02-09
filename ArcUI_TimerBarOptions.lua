-- ===================================================================
-- ArcUI_TimerBarOptions.lua
-- Timer Bars options panel configuration UI
-- Timer bars are integrated into CooldownBars system
-- ===================================================================

local ADDON, ns = ...
ns.TimerBarOptions = ns.TimerBarOptions or {}

-- ===================================================================
-- UI STATE
-- ===================================================================
local expandedTimers = {}  -- expandedTimers["timer_timerID"] = true

-- ===================================================================
-- TRIGGER TYPE LABELS
-- ===================================================================
local TRIGGER_TYPES = {
  spellcast = "Spell Cast",
  ["Aura Gained"] = "Aura Gained",
  ["Aura Lost"] = "Aura Lost",
}

local TRIGGER_TYPE_ORDER = { "spellcast", "Aura Gained", "Aura Lost" }

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
  
  return {
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
          local triggerType = cfg and cfg.tracking.triggerType or "spellcast"
          local triggerLabel = TRIGGER_TYPES[triggerType] or triggerType
          local duration = cfg and cfg.tracking.customDuration or 10
          
          local iconTexture = 134400
          if cfg and cfg.tracking.triggerSpellID and cfg.tracking.triggerSpellID > 0 then
            iconTexture = C_Spell.GetSpellTexture(cfg.tracking.triggerSpellID) or 134400
          elseif cfg and cfg.tracking.triggerCooldownID and cfg.tracking.triggerCooldownID > 0 then
            -- Get icon from catalog entry
            if ns.Catalog and ns.Catalog.GetEntry then
              local entry = ns.Catalog.GetEntry(cfg.tracking.triggerCooldownID)
              if entry then iconTexture = entry.icon or 134400 end
            end
          end
          
          return string.format("|T%d:16:16:0:0|t |cffcc66ff%s|r - %s (%ds)",
            iconTexture, name, triggerLabel, duration)
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
          if cfg then cfg.tracking.enabled = value end
        end,
        order = 1,
        width = 0.5,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      barName = {
        type = "input",
        name = "Name",
        desc = "Display name for this timer bar",
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
        desc = "How long the timer runs when triggered",
        get = function()
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return cfg and tostring(cfg.tracking.customDuration) or "10"
        end,
        set = function(info, value)
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          if cfg then
            cfg.tracking.customDuration = tonumber(value) or 10
          end
        end,
        order = 3,
        width = 0.6,
        hidden = function() return not expandedTimers[timerKey] end,
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
        order = 4,
        width = 0.8,
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      lineBreak1 = {
        type = "description",
        name = "",
        order = 4.5,
        width = "full",
        hidden = function() return not expandedTimers[timerKey] end,
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
        order = 5,
        width = 1.5,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or cfg.tracking.triggerType ~= "spellcast"
        end,
      },
      
      triggerSpellManual = {
        type = "input",
        name = "Spell ID",
        desc = "Or enter spell ID manually",
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
        order = 6,
        width = 0.5,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
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
        order = 5,
        width = 1.5,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or (cfg.tracking.triggerType ~= "Aura Gained" and cfg.tracking.triggerType ~= "Aura Lost")
        end,
      },
      
      triggerAuraManual = {
        type = "input",
        name = "Cooldown ID",
        desc = "Or enter CDM cooldown ID manually",
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
        order = 6,
        width = 0.5,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
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
        order = 7,
        width = 0.8,
        hidden = function()
          if not expandedTimers[timerKey] then return true end
          local cfg = ns.CooldownBars.GetTimerConfig(timerID)
          return not cfg or (cfg.tracking.triggerType ~= "Aura Gained" and cfg.tracking.triggerType ~= "Aura Lost")
        end,
      },
      
      lineBreak2 = {
        type = "description",
        name = "",
        order = 8,
        width = "full",
        hidden = function() return not expandedTimers[timerKey] end,
      },
      
      hideWhenInactive = {
        type = "toggle",
        name = "Hide When Inactive",
        desc = "Hide the bar when the timer is not running",
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
        width = 0.9,
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
      
      lineBreak3 = {
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
        hidden = function() return not expandedTimers[timerKey] end,
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
        width = 0.7,
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
end

-- ===================================================================
-- BUILD OPTIONS TABLE
-- ===================================================================
function ns.TimerBarOptions.GetOptionsTable()
  local args = {
    description = {
      type = "description",
      name = "|cffcc66ffTimer Bars|r create custom duration bars triggered by spell casts or aura events.\n\n" ..
             "1. Click |cff00ff00Create New Timer|r below\n" ..
             "2. Set the trigger (spell cast or aura)\n" ..
             "3. Set the duration\n" ..
             "4. Click |cffffd700Edit Appearance|r to customize the look\n",
      fontSize = "medium",
      order = 1,
    },
    
    createHeader = {
      type = "header",
      name = "Create Timer",
      order = 10,
    },
    
    createBtn = {
      type = "execute",
      name = "|cff00ff00Create New Timer|r",
      desc = "Add a new timer bar",
      func = function()
        local timerID = ns.CooldownBars.GenerateTimerID()
        ns.CooldownBars.AddTimerBar(timerID)
        expandedTimers["timer_" .. timerID] = true
        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
      end,
      order = 11,
      width = 1.0,
    },
    
    activeHeader = {
      type = "header",
      name = "Active Timer Bars",
      order = 100,
    },
    
    activeDesc = {
      type = "description",
      name = function()
        local count = 0
        for _ in pairs(ns.CooldownBars.activeTimers or {}) do
          count = count + 1
        end
        if count == 0 then
          return "|cff888888No timer bars configured. Create one above.|r"
        end
        return string.format("|cff888888%d timer bar(s). Click to expand settings.|r", count)
      end,
      fontSize = "medium",
      order = 101,
    },
  }
  
  -- Add entries for each active timer
  local orderBase = 110
  for timerID in pairs(ns.CooldownBars.activeTimers or {}) do
    args["timer_" .. timerID] = CreateTimerEntry(timerID, orderBase)
    orderBase = orderBase + 1
  end
  
  return {
    type = "group",
    name = "Timer Bars",
    args = args,
  }
end