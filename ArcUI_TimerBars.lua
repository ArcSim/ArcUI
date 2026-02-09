-- ===================================================================
-- ArcUI_TimerBars.lua
-- Timer bars with custom durations triggered by spell casts or auras
-- Properly integrates with CooldownBars display infrastructure
-- ===================================================================

local ADDON, ns = ...
ns.TimerBars = ns.TimerBars or {}

-- ===================================================================
-- CONSTANTS
-- ===================================================================
local MAX_TIMER_BARS = 10
local UPDATE_INTERVAL = 0.05  -- 20fps for text updates

-- ===================================================================
-- DATA STORAGE
-- ===================================================================
ns.TimerBars.bars = {}           -- Bar frames (barData indexed by barIndex)
ns.TimerBars.activeTimers = {}   -- Active timer configs: [timerID] = barIndex

-- ===================================================================
-- DEBUG LOGGING
-- ===================================================================
local DEBUG_ENABLED = false

local function Log(msg)
  if DEBUG_ENABLED then
    print("|cffcc66ff[TimerBars]|r " .. tostring(msg))
  end
end

-- ===================================================================
-- DATABASE ACCESS
-- ===================================================================
local function GetDB()
  if ns.db and ns.db.char then
    if not ns.db.char.timerBars then
      ns.db.char.timerBars = {}
    end
    return ns.db.char.timerBars
  end
  return nil
end

-- Get or create timer config
function ns.TimerBars.GetTimerConfig(timerID)
  if not ns.db or not ns.db.char then return nil end
  
  ns.db.char.timerBarConfigs = ns.db.char.timerBarConfigs or {}
  
  if not ns.db.char.timerBarConfigs[timerID] then
    ns.db.char.timerBarConfigs[timerID] = {
      tracking = {
        enabled = true,
        timerID = timerID,
        triggerType = "spellcast",    -- "spellcast", "aura_gained", "aura_lost"
        triggerSpellID = 0,           -- For spellcast triggers
        triggerAuraID = 0,            -- For aura triggers
        triggerUnit = "player",       -- Unit to watch for auras
        customDuration = 10,          -- User-defined duration in seconds
        barName = "Timer",
        iconTextureID = 134400,       -- Default question mark
      },
      display = {
        width = 200,
        height = 20,
        barScale = 1.0,
        opacity = 1.0,
        barColor = {r = 0.8, g = 0.4, b = 1, a = 1},  -- Purple for timers
        backgroundColor = {r = 0.15, g = 0.15, b = 0.15, a = 0.9},
        showBorder = true,
        borderColor = {r = 0, g = 0, b = 0, a = 1},
        drawnBorderThickness = 1,
        showBarIcon = true,
        barIconSize = 20,
        showName = true,
        nameFont = "Friz Quadrata TT",
        nameFontSize = 12,
        nameColor = {r = 1, g = 1, b = 1, a = 1},
        showDuration = true,
        durationFont = "Friz Quadrata TT",
        durationFontSize = 12,
        durationColor = {r = 1, g = 1, b = 0.5, a = 1},
        durationDecimals = 1,
        durationBarFillMode = "drain",
        barPosition = nil,
      },
      behavior = {
        hideWhenInactive = true,
        hideOutOfCombat = false,
        showOnSpecs = {},
      },
    }
  end
  
  return ns.db.char.timerBarConfigs[timerID]
end

-- ===================================================================
-- HELPER: CONFIGURE STATUSBAR
-- ===================================================================
local function ConfigureStatusBar(bar)
  if not bar then return end
  local tex = bar:GetStatusBarTexture()
  if tex then
    tex:SetSnapToPixelGrid(false)
    tex:SetTexelSnappingBias(0)
  end
end

-- ===================================================================
-- CREATE TIMER BAR FRAME
-- ===================================================================
local function CreateTimerBar(index)
  local frame = CreateFrame("Frame", "ArcUITimerBar"..index, UIParent, "BackdropTemplate")
  frame:SetSize(200, 20)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, -100 - (index - 1) * 28)
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  frame:SetBackdropColor(0, 0, 0, 0.8)
  frame:SetBackdropBorderColor(0.6, 0.3, 0.8, 1)  -- Purple border
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  
  -- Drag handlers
  frame:SetScript("OnDragStart", function(self)
    if not InCombatLockdown() then
      self:StartMoving()
    end
  end)
  
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local barData = self.barData
    if barData and barData.timerID then
      local cfg = ns.TimerBars.GetTimerConfig(barData.timerID)
      if cfg and cfg.display then
        local centerX, centerY = self:GetCenter()
        if centerX and centerY then
          local uiCenterX, uiCenterY = UIParent:GetCenter()
          cfg.display.barPosition = {
            point = "CENTER",
            relPoint = "CENTER",
            x = centerX - uiCenterX,
            y = centerY - uiCenterY,
          }
        end
      end
    end
  end)
  
  -- Right-click to open options
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" or (button == "LeftButton" and IsShiftKeyDown()) then
      local barData = self.barData
      if barData and barData.timerID then
        ns.TimerBars.OpenOptionsForBar(barData.timerID)
      end
    end
  end)
  
  -- Icon
  local icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetSize(16, 16)
  icon:SetPoint("LEFT", frame, "LEFT", 2, 0)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  icon:SetSnapToPixelGrid(false)
  icon:SetTexelSnappingBias(0)
  
  -- Status bar
  local bar = CreateFrame("StatusBar", nil, frame)
  bar:SetPoint("LEFT", icon, "RIGHT", 4, 0)
  bar:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
  bar:SetPoint("TOP", frame, "TOP", 0, -3)
  bar:SetPoint("BOTTOM", frame, "BOTTOM", 0, 3)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(0.8, 0.4, 1, 1)
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(1)
  ConfigureStatusBar(bar)
  
  -- Bar background
  local barBg = bar:CreateTexture(nil, "BACKGROUND")
  barBg:SetAllPoints()
  barBg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
  barBg:SetVertexColor(0.15, 0.15, 0.15, 0.9)
  barBg:SetSnapToPixelGrid(false)
  barBg:SetTexelSnappingBias(0)
  
  -- Name text container
  local nameTextContainer = CreateFrame("Frame", nil, bar)
  nameTextContainer:SetSize(150, 20)
  nameTextContainer:SetPoint("LEFT", bar, "LEFT", 4, 0)
  local nameText = nameTextContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  nameText:SetAllPoints()
  nameText:SetJustifyH("LEFT")
  nameText:SetTextColor(1, 1, 1, 1)
  nameText:SetShadowOffset(1, -1)
  
  -- Duration text container
  local durationTextContainer = CreateFrame("Frame", nil, bar)
  durationTextContainer:SetSize(60, 20)
  durationTextContainer:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
  local durationText = durationTextContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  durationText:SetAllPoints()
  durationText:SetJustifyH("RIGHT")
  durationText:SetTextColor(1, 1, 0.5, 1)
  durationText:SetShadowOffset(1, -1)
  
  local barData = {
    frame = frame,
    bar = bar,
    barBg = barBg,
    icon = icon,
    nameTextContainer = nameTextContainer,
    nameText = nameText,
    durationTextContainer = durationTextContainer,
    text = durationText,  -- Named 'text' to match CooldownBars pattern
    timerID = nil,
    barIndex = index,
    -- Timer state
    durObj = nil,
    startTime = nil,
    endTime = nil,
    isActive = false,
    -- Display flags (set by ApplyAppearance)
    showDuration = true,
    customColor = nil,
  }
  
  frame.barData = barData
  frame:Hide()
  
  ns.TimerBars.bars[index] = barData
  return barData
end

-- Get or create bar frame
local function GetOrCreateBar(index)
  if not ns.TimerBars.bars[index] then
    CreateTimerBar(index)
  end
  return ns.TimerBars.bars[index]
end

-- ===================================================================
-- TIMER ACTIVATION
-- ===================================================================
local function StartTimer(timerID)
  local barIndex = ns.TimerBars.activeTimers[timerID]
  if not barIndex then return end
  
  local barData = ns.TimerBars.bars[barIndex]
  if not barData then return end
  
  local cfg = ns.TimerBars.GetTimerConfig(timerID)
  if not cfg then return end
  
  local duration = cfg.tracking.customDuration or 10
  local now = GetTime()
  
  -- Create duration object
  local durObj = C_DurationUtil.CreateDuration()
  durObj:SetTimeFromStart(now, duration, 1)
  
  -- Store timer state on barData
  barData.durObj = durObj
  barData.startTime = now
  barData.endTime = now + duration
  barData.isActive = true
  
  -- Apply to status bar
  local interpolation = Enum.StatusBarInterpolation.ExponentialEaseOut
  local direction = Enum.StatusBarTimerDirection.RemainingTime
  if cfg.display.durationBarFillMode == "fill" then
    direction = Enum.StatusBarTimerDirection.ElapsedTime
  end
  
  barData.bar:SetMinMaxValues(0, 1)
  barData.bar:SetTimerDuration(durObj, interpolation, direction)
  barData.bar:SetToTargetValue()
  
  -- Show the bar
  barData.frame:Show()
  barData.frame:SetAlpha(cfg.display.opacity or 1)
  
  -- Set up OnUpdate for duration text
  barData.bar.timerData = {
    barData = barData,
    cfg = cfg,
    elapsed = 0,
  }
  
  barData.bar:SetScript("OnUpdate", function(self, elapsed)
    local data = self.timerData
    if not data then return end
    
    data.elapsed = data.elapsed + elapsed
    if data.elapsed < UPDATE_INTERVAL then return end
    data.elapsed = 0
    
    local bd = data.barData
    if not bd or not bd.isActive then return end
    
    local remaining = bd.endTime - GetTime()
    
    if remaining <= 0 then
      -- Timer completed
      bd.isActive = false
      bd.text:SetText("0")
      self:SetScript("OnUpdate", nil)
      
      if data.cfg.behavior.hideWhenInactive then
        bd.frame:Hide()
      end
      
      Log("Timer completed: " .. (bd.timerID or "?"))
      return
    end
    
    -- Update duration text
    if bd.showDuration ~= false then
      local decimals = data.cfg.display.durationDecimals or 1
      local fmt
      if decimals == 0 then
        fmt = "%.0f"
      elseif decimals == 2 then
        fmt = "%.2f"
      else
        fmt = "%.1f"
      end
      bd.text:SetText(string.format(fmt, remaining))
    end
  end)
  
  -- Set initial text
  local decimals = cfg.display.durationDecimals or 1
  local fmt = decimals == 0 and "%.0f" or (decimals == 2 and "%.2f" or "%.1f")
  barData.text:SetText(string.format(fmt, duration))
  
  Log("Timer started: " .. timerID .. " for " .. duration .. "s")
end

-- Expose StartTimer for options testing
ns.TimerBars.StartTimer = StartTimer

-- ===================================================================
-- ADD/REMOVE TIMER BARS
-- ===================================================================
function ns.TimerBars.AddTimer(timerID)
  if ns.TimerBars.activeTimers[timerID] then
    Log("Timer already exists: " .. timerID)
    return false
  end
  
  -- Find next available slot
  local barIndex = nil
  for i = 1, MAX_TIMER_BARS do
    local inUse = false
    for _, idx in pairs(ns.TimerBars.activeTimers) do
      if idx == i then
        inUse = true
        break
      end
    end
    if not inUse then
      barIndex = i
      break
    end
  end
  
  if not barIndex then
    Log("No available timer bar slots")
    return false
  end
  
  -- Create config if needed
  ns.TimerBars.GetTimerConfig(timerID)
  
  -- Create bar
  local barData = GetOrCreateBar(barIndex)
  barData.timerID = timerID
  
  ns.TimerBars.activeTimers[timerID] = barIndex
  
  -- Apply appearance immediately
  ns.TimerBars.ApplyAppearance(timerID)
  
  -- Save
  ns.TimerBars.SaveConfig()
  
  Log("Added timer: " .. timerID .. " at slot " .. barIndex)
  return true
end

function ns.TimerBars.RemoveTimer(timerID)
  local barIndex = ns.TimerBars.activeTimers[timerID]
  if not barIndex then return false end
  
  local barData = ns.TimerBars.bars[barIndex]
  if barData then
    barData.frame:Hide()
    barData.bar:SetScript("OnUpdate", nil)
    barData.timerID = nil
    barData.isActive = false
    barData.durObj = nil
  end
  
  ns.TimerBars.activeTimers[timerID] = nil
  
  ns.TimerBars.SaveConfig()
  
  Log("Removed timer: " .. timerID)
  return true
end

-- ===================================================================
-- APPLY APPEARANCE (called from AppearanceOptions)
-- ===================================================================
function ns.TimerBars.ApplyAppearance(timerID)
  local barIndex = ns.TimerBars.activeTimers[timerID]
  if not barIndex then return end
  
  local barData = ns.TimerBars.bars[barIndex]
  if not barData then return end
  
  local cfg = ns.TimerBars.GetTimerConfig(timerID)
  if not cfg then return end
  
  local display = cfg.display
  
  -- Size
  local width = display.width or 200
  local height = display.height or 20
  local scale = display.barScale or 1
  
  barData.frame:SetSize(width, height)
  barData.frame:SetScale(scale)
  
  -- Position
  if display.barPosition then
    barData.frame:ClearAllPoints()
    barData.frame:SetPoint(
      display.barPosition.point or "CENTER",
      UIParent,
      display.barPosition.relPoint or "CENTER",
      display.barPosition.x or 0,
      display.barPosition.y or 0
    )
  end
  
  -- Icon
  if display.showBarIcon ~= false then
    local iconSize = display.barIconSize or height - 4
    barData.icon:SetSize(iconSize, iconSize)
    barData.icon:Show()
    barData.bar:SetPoint("LEFT", barData.icon, "RIGHT", 4, 0)
  else
    barData.icon:Hide()
    barData.bar:SetPoint("LEFT", barData.frame, "LEFT", 4, 0)
  end
  
  -- Icon texture
  local iconTexture = cfg.tracking.iconTextureID or 134400
  if cfg.tracking.triggerSpellID and cfg.tracking.triggerSpellID > 0 then
    iconTexture = C_Spell.GetSpellTexture(cfg.tracking.triggerSpellID) or iconTexture
  elseif cfg.tracking.triggerAuraID and cfg.tracking.triggerAuraID > 0 then
    iconTexture = C_Spell.GetSpellTexture(cfg.tracking.triggerAuraID) or iconTexture
  end
  barData.icon:SetTexture(iconTexture)
  
  -- Colors
  local barColor = display.barColor or {r = 0.8, g = 0.4, b = 1, a = 1}
  barData.customColor = barColor
  barData.bar:GetStatusBarTexture():SetVertexColor(barColor.r, barColor.g, barColor.b, barColor.a or 1)
  
  local bgColor = display.backgroundColor or {r = 0.15, g = 0.15, b = 0.15, a = 0.9}
  barData.barBg:SetVertexColor(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.9)
  
  -- Border
  if display.showBorder ~= false then
    local borderColor = display.borderColor or {r = 0, g = 0, b = 0, a = 1}
    barData.frame:SetBackdropBorderColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
  end
  
  -- Name text
  if display.showName ~= false then
    local nameColor = display.nameColor or {r = 1, g = 1, b = 1, a = 1}
    barData.nameText:SetTextColor(nameColor.r, nameColor.g, nameColor.b, nameColor.a or 1)
    barData.nameText:SetText(cfg.tracking.barName or "Timer")
    barData.nameTextContainer:Show()
  else
    barData.nameTextContainer:Hide()
  end
  
  -- Duration text
  barData.showDuration = display.showDuration ~= false
  if barData.showDuration then
    local durColor = display.durationColor or {r = 1, g = 1, b = 0.5, a = 1}
    barData.text:SetTextColor(durColor.r, durColor.g, durColor.b, durColor.a or 1)
    barData.durationTextContainer:Show()
  else
    barData.durationTextContainer:Hide()
  end
  
  -- Opacity
  barData.frame:SetAlpha(display.opacity or 1)
  
  -- Visibility based on behavior
  local shouldShow = true
  if cfg.behavior.hideWhenInactive and not barData.isActive then
    shouldShow = false
  end
  if cfg.behavior.hideOutOfCombat and not UnitAffectingCombat("player") then
    shouldShow = false
  end
  
  -- Check if options panel is open - show bars in preview mode
  local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
  local panelIsOpen = AceConfigDialog and AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["ArcUI"]
  if panelIsOpen and not shouldShow then
    -- Show at reduced opacity for preview
    shouldShow = true
    barData.frame:SetAlpha((display.opacity or 1) * 0.5)
  end
  
  if shouldShow then
    barData.frame:Show()
  else
    barData.frame:Hide()
  end
end

-- ===================================================================
-- OPEN OPTIONS FOR BAR (right-click to edit)
-- ===================================================================
function ns.TimerBars.OpenOptionsForBar(timerID)
  local AceConfigDialog = LibStub("AceConfigDialog-3.0")
  
  -- Check if options panel is already open
  local panelIsOpen = AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["ArcUI"]
  if not panelIsOpen then
    return  -- Don't open panel, just ignore
  end
  
  -- Set the selected bar in AppearanceOptions
  -- Format: "timer_timerID" e.g. "timer_1"
  if ns.AppearanceOptions and ns.AppearanceOptions.SetSelectedBar then
    ns.AppearanceOptions.SetSelectedBar("timer", timerID)
  end
  
  -- Refresh the options to show updated selection
  local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
  AceConfigRegistry:NotifyChange("ArcUI")
  
  -- Select the appearance tab
  AceConfigDialog:SelectGroup("ArcUI", "bars", "appearance")
  
  Log("OpenOptionsForBar: timer " .. timerID)
end

-- ===================================================================
-- GET BAR FRAME (for AppearanceOptions editing indicator)
-- ===================================================================
function ns.TimerBars.GetBarFrame(timerID)
  local barIndex = ns.TimerBars.activeTimers[timerID]
  if barIndex then
    local barData = ns.TimerBars.bars[barIndex]
    if barData then
      return barData.frame
    end
  end
  return nil
end

-- ===================================================================
-- EVENT HANDLING
-- ===================================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("UNIT_AURA")

eventFrame:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_LOGIN" then
    C_Timer.After(2, function()
      ns.TimerBars.RestoreConfig()
    end)
    
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    if unit ~= "player" then return end
    
    -- Check all timers for spellcast triggers
    for timerID, barIndex in pairs(ns.TimerBars.activeTimers) do
      local cfg = ns.TimerBars.GetTimerConfig(timerID)
      if cfg and cfg.tracking.enabled then
        if cfg.tracking.triggerType == "spellcast" then
          if cfg.tracking.triggerSpellID == spellID then
            StartTimer(timerID)
          end
        end
      end
    end
    
  elseif event == "UNIT_AURA" then
    local unit, updateInfo = ...
    
    -- Check all timers for aura triggers
    for timerID, barIndex in pairs(ns.TimerBars.activeTimers) do
      local cfg = ns.TimerBars.GetTimerConfig(timerID)
      if cfg and cfg.tracking.enabled then
        local triggerType = cfg.tracking.triggerType
        local triggerUnit = cfg.tracking.triggerUnit or "player"
        
        if unit == triggerUnit and (triggerType == "aura_gained" or triggerType == "aura_lost") then
          local auraID = cfg.tracking.triggerAuraID
          if auraID and auraID > 0 then
            -- Check if aura was added
            if updateInfo and updateInfo.addedAuras and triggerType == "aura_gained" then
              for _, aura in ipairs(updateInfo.addedAuras) do
                if aura.spellId == auraID then
                  StartTimer(timerID)
                  break
                end
              end
            end
            
            -- Check if aura was removed
            if updateInfo and updateInfo.removedAuraInstanceIDs and triggerType == "aura_lost" then
              -- Need to track aura instance IDs - simplified: just check if aura no longer exists
              local auraExists = C_UnitAuras.GetPlayerAuraBySpellID(auraID)
              if not auraExists then
                StartTimer(timerID)
              end
            end
          end
        end
      end
    end
  end
end)

-- ===================================================================
-- SAVE/RESTORE CONFIG
-- ===================================================================
function ns.TimerBars.SaveConfig()
  local db = GetDB()
  if not db then return end
  
  db.activeTimers = {}
  for timerID in pairs(ns.TimerBars.activeTimers) do
    table.insert(db.activeTimers, timerID)
  end
  
  Log("Saved " .. #db.activeTimers .. " timer bars")
end

function ns.TimerBars.RestoreConfig()
  local db = GetDB()
  if not db then return end
  
  if db.activeTimers then
    for _, timerID in ipairs(db.activeTimers) do
      ns.TimerBars.AddTimer(timerID)
    end
    Log("Restored " .. #db.activeTimers .. " timer bars")
  end
end

-- ===================================================================
-- HELPER: Generate unique timer ID
-- ===================================================================
local function GenerateTimerID()
  local db = GetDB()
  local maxID = 0
  
  if db and db.activeTimers then
    for _, id in ipairs(db.activeTimers) do
      if id > maxID then maxID = id end
    end
  end
  
  for id in pairs(ns.TimerBars.activeTimers) do
    if id > maxID then maxID = id end
  end
  
  -- Also check configs
  if ns.db and ns.db.char and ns.db.char.timerBarConfigs then
    for id in pairs(ns.db.char.timerBarConfigs) do
      if id > maxID then maxID = id end
    end
  end
  
  return maxID + 1
end

ns.TimerBars.GenerateTimerID = GenerateTimerID

-- ===================================================================
-- SLASH COMMAND
-- ===================================================================
SLASH_ARCUITIMER1 = "/timer"
SlashCmdList["ARCUITIMER"] = function(msg)
  msg = msg and msg:lower():trim() or ""
  
  if msg == "test" then
    -- Create a test timer if none exists
    local testID = 999
    if not ns.TimerBars.activeTimers[testID] then
      ns.TimerBars.AddTimer(testID)
      local cfg = ns.TimerBars.GetTimerConfig(testID)
      if cfg then
        cfg.tracking.barName = "Test Timer"
        cfg.tracking.customDuration = 10
      end
      ns.TimerBars.ApplyAppearance(testID)
    end
    StartTimer(testID)
    print("|cffcc66ff[TimerBars]|r Started test timer (10s)")
    
  elseif msg == "list" then
    print("|cffcc66ff[TimerBars]|r Active timers:")
    local count = 0
    for timerID, barIndex in pairs(ns.TimerBars.activeTimers) do
      local cfg = ns.TimerBars.GetTimerConfig(timerID)
      local name = cfg and cfg.tracking.barName or "Unknown"
      print(string.format("  #%d: %s (slot %d)", timerID, name, barIndex))
      count = count + 1
    end
    if count == 0 then
      print("  (none)")
    end
    
  elseif msg == "debug" then
    DEBUG_ENABLED = not DEBUG_ENABLED
    print("|cffcc66ff[TimerBars]|r Debug: " .. (DEBUG_ENABLED and "ON" or "OFF"))
    
  else
    print("|cffcc66ff[TimerBars]|r Commands:")
    print("  /timer test - Start a test timer")
    print("  /timer list - List active timers")
    print("  /timer debug - Toggle debug mode")
  end
end

-- ===================================================================
-- INIT
-- ===================================================================
function ns.TimerBars.Init()
  Log("TimerBars initialized")
end