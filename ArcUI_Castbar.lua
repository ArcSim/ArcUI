-- ===================================================================
-- ArcUI_Castbar.lua
-- Player castbar - single bar showing cast progress
-- Similar in structure to resource bars (movable, configurable appearance)
-- OnUpdate only runs during an active cast (zero idle CPU)
-- ===================================================================

local ADDON, ns = ...
ns.Castbar = ns.Castbar or {}

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local function PixelSize(n) return math.floor(n + 0.5) end

-- ===================================================================
-- DB ACCESSOR
-- ===================================================================
local function GetCastbarDB()
  local db = ns.API and ns.API.GetDB and ns.API.GetDB()
  return db and db.castbar
end

-- ===================================================================
-- CAST STATE
-- ===================================================================
local castFrameObj = nil
local castTextFrame = nil
local castActive = false
local castIsChannel = false
local castStartTime = 0
local castEndTime = 0

-- ===================================================================
-- FRAME CREATION
-- ===================================================================
local function CreateCastbarFrames()
  -- Main bar frame
  local frame = CreateFrame("Frame", "ArcUICastbarMain", UIParent)
  frame:SetSize(250, 20)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(false)

  -- Background
  frame.bg = frame:CreateTexture(nil, "BACKGROUND")
  frame.bg:SetAllPoints()
  frame.bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)
  frame.bg:SetSnapToPixelGrid(false)
  frame.bg:SetTexelSnappingBias(0)

  -- Cast fill bar
  frame.fillBar = CreateFrame("StatusBar", nil, frame)
  frame.fillBar:SetAllPoints(frame)
  frame.fillBar:SetMinMaxValues(0, 1)
  frame.fillBar:SetValue(0)
  frame.fillBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  frame.fillBar:SetStatusBarColor(0.2, 0.8, 1, 1)
  frame.fillBar:SetFrameLevel(frame:GetFrameLevel() + 2)

  -- Border overlay (4 separate textures for pixel-perfect edges)
  frame.borderOverlay = CreateFrame("Frame", nil, frame)
  frame.borderOverlay:SetAllPoints()
  frame.borderOverlay:SetFrameLevel(frame:GetFrameLevel() + 10)
  frame.borderOverlay.top    = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.bottom = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.left   = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.right  = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
  frame.borderOverlay.top:SetSnapToPixelGrid(false);    frame.borderOverlay.top:SetTexelSnappingBias(0)
  frame.borderOverlay.bottom:SetSnapToPixelGrid(false); frame.borderOverlay.bottom:SetTexelSnappingBias(0)
  frame.borderOverlay.left:SetSnapToPixelGrid(false);   frame.borderOverlay.left:SetTexelSnappingBias(0)
  frame.borderOverlay.right:SetSnapToPixelGrid(false);  frame.borderOverlay.right:SetTexelSnappingBias(0)

  -- Icon frame (to the left of the bar)
  frame.iconFrame = CreateFrame("Frame", nil, frame)
  frame.iconFrame:SetSize(20, 20)
  frame.iconFrame:SetPoint("RIGHT", frame, "LEFT", -2, 0)
  frame.iconFrame:SetFrameLevel(frame:GetFrameLevel() + 5)
  frame.iconTex = frame.iconFrame:CreateTexture(nil, "ARTWORK")
  frame.iconTex:SetAllPoints()
  frame.iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  -- Drag to move
  frame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
      local cfg = GetCastbarDB()
      if cfg and cfg.barMovable then
        self:StartMoving()
      end
    end
  end)
  frame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
      self:StopMovingOrSizing()
      local cfg = GetCastbarDB()
      if cfg then
        local point, _, relPoint, x, y = self:GetPoint()
        cfg.barPosition = { point = point, relPoint = relPoint, x = x, y = y }
      end
    end
  end)

  frame:Hide()

  -- Separate text frame: name + timer (anchored to mainFrame, not movable independently)
  local textFrame = CreateFrame("Frame", "ArcUICastbarText", UIParent)
  textFrame:SetSize(250, 20)
  textFrame:SetPoint("CENTER", frame, "CENTER", 0, 0)
  textFrame:SetFrameStrata("HIGH")
  textFrame:SetFrameLevel(200)

  textFrame.nameText = textFrame:CreateFontString(nil, "OVERLAY")
  textFrame.nameText:SetPoint("LEFT", textFrame, "LEFT", 4, 0)
  textFrame.nameText:SetPoint("RIGHT", textFrame, "RIGHT", -38, 0)
  textFrame.nameText:SetJustifyH("LEFT")
  textFrame.nameText:SetJustifyV("MIDDLE")

  textFrame.timerText = textFrame:CreateFontString(nil, "OVERLAY")
  textFrame.timerText:SetPoint("RIGHT", textFrame, "RIGHT", -4, 0)
  textFrame.timerText:SetJustifyH("RIGHT")
  textFrame.timerText:SetJustifyV("MIDDLE")

  textFrame:Hide()

  return frame, textFrame
end

local function GetOrCreateFrames()
  if not castFrameObj then
    castFrameObj, castTextFrame = CreateCastbarFrames()
  end
  return castFrameObj, castTextFrame
end

-- ===================================================================
-- BORDER DRAWING
-- ===================================================================
local function ApplyBorder(mainFrame, cfg)
  local bo = mainFrame.borderOverlay
  if cfg.showBorder then
    local bt = PixelUtil.GetNearestPixelSize(cfg.drawnBorderThickness or 2, mainFrame:GetEffectiveScale(), 1)
    local bc = cfg.borderColor or {r=0, g=0, b=0, a=1}

    for _, t in pairs({bo.top, bo.bottom, bo.left, bo.right}) do
      t:SetSnapToPixelGrid(true)
      t:SetTexelSnappingBias(1)
    end

    bo.top:ClearAllPoints()
    bo.top:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, 0)
    bo.top:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, 0)
    bo.top:SetHeight(bt)
    bo.top:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
    bo.top:Show()

    bo.bottom:ClearAllPoints()
    bo.bottom:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, 0)
    bo.bottom:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
    bo.bottom:SetHeight(bt)
    bo.bottom:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
    bo.bottom:Show()

    bo.left:ClearAllPoints()
    bo.left:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -bt)
    bo.left:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, bt)
    bo.left:SetWidth(bt)
    bo.left:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
    bo.left:Show()

    bo.right:ClearAllPoints()
    bo.right:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -bt)
    bo.right:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, bt)
    bo.right:SetWidth(bt)
    bo.right:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
    bo.right:Show()

    bo:Show()
  else
    bo.top:Hide(); bo.bottom:Hide(); bo.left:Hide(); bo.right:Hide()
    bo:Hide()
  end
end

-- ===================================================================
-- APPLY APPEARANCE
-- ===================================================================
function ns.Castbar.ApplyAppearance()
  local cfg = GetCastbarDB()
  if not cfg then return end

  local mainFrame, textFrame = GetOrCreateFrames()

  if not cfg.enabled then
    mainFrame:Hide()
    textFrame:Hide()
    return
  end

  -- Size
  local w = PixelSize(cfg.width or 250)
  local h = PixelSize(cfg.height or 20)
  mainFrame:SetSize(w, h)
  textFrame:SetSize(w, h)

  -- Position
  local pos = cfg.barPosition or {point="CENTER", relPoint="CENTER", x=0, y=-100}
  mainFrame:ClearAllPoints()
  mainFrame:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER", pos.x or 0, pos.y or -100)
  textFrame:ClearAllPoints()
  textFrame:SetPoint("CENTER", mainFrame, "CENTER", 0, 0)

  -- Strata and level
  local strata = cfg.barFrameStrata or "MEDIUM"
  local level  = cfg.barFrameLevel or 10
  mainFrame:SetFrameStrata(strata)
  mainFrame:SetFrameLevel(level)
  mainFrame.fillBar:SetFrameLevel(level + 2)
  mainFrame.borderOverlay:SetFrameLevel(level + 10)
  mainFrame.iconFrame:SetFrameLevel(level + 5)
  textFrame:SetFrameStrata(strata)
  textFrame:SetFrameLevel(level + 100)

  -- Opacity
  mainFrame:SetAlpha(cfg.opacity or 1.0)

  -- Background
  if cfg.showBackground then
    local bg = cfg.backgroundColor or {r=0.1, g=0.1, b=0.1, a=0.9}
    mainFrame.bg:SetColorTexture(bg.r, bg.g, bg.b, bg.a or 0.9)
    mainFrame.bg:Show()
  else
    mainFrame.bg:Hide()
  end

  -- Border
  ApplyBorder(mainFrame, cfg)

  -- Texture for fill bar
  local texPath = "Interface\\TargetingFrame\\UI-StatusBar"
  if LSM and cfg.texture then
    texPath = LSM:Fetch("statusbar", cfg.texture) or texPath
  end
  mainFrame.fillBar:SetStatusBarTexture(texPath)

  -- Icon
  local iconSize = PixelSize(cfg.iconSize or 20)
  mainFrame.iconFrame:SetSize(iconSize, iconSize)
  if cfg.showIcon then
    mainFrame.iconFrame:Show()
  else
    mainFrame.iconFrame:Hide()
  end

  -- Font
  local fontPath = "Fonts\\FRIZQT__.TTF"
  if LSM and cfg.font then
    fontPath = LSM:Fetch("font", cfg.font) or fontPath
  end
  local fontSize  = cfg.fontSize or 14
  local outline   = cfg.textOutline
  if outline == "NONE" or outline == "None" or outline == "" then outline = nil end
  local tc = cfg.textColor or {r=1, g=1, b=1, a=1}

  textFrame.nameText:SetFont(fontPath, fontSize, outline)
  textFrame.nameText:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
  textFrame.timerText:SetFont(fontPath, fontSize, outline)
  textFrame.timerText:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)

  -- Movable
  mainFrame:EnableMouse(cfg.barMovable ~= false)
end

-- ===================================================================
-- ONUPDATE (only runs during an active cast)
-- ===================================================================
local function CastOnUpdate(self, elapsed)
  local cfg = GetCastbarDB()
  if not cfg then return end

  local now = GetTime()
  local total = castEndTime - castStartTime
  if total <= 0 then return end

  local progress
  if castIsChannel then
    -- Channels drain from full to empty
    progress = 1.0 - (now - castStartTime) / total
  else
    -- Normal casts fill left to right
    progress = (now - castStartTime) / total
  end
  progress = math.max(0, math.min(1, progress))

  castFrameObj.fillBar:SetValue(progress)

  -- Live countdown timer
  if cfg.showTimer then
    local remaining = castEndTime - now
    if remaining < 0 then remaining = 0 end
    castTextFrame.timerText:SetText(string.format("%.1f", remaining))
  end
end

-- ===================================================================
-- SHOW / STOP CAST
-- ===================================================================
local function ShowCast(spellID, startTimeMS, endTimeMS, isChannel, notInterruptible)
  local cfg = GetCastbarDB()
  if not cfg or not cfg.enabled then return end
  if cfg.hideOutOfCombat and not InCombatLockdown() then return end
  if isChannel and cfg.hideChannels then return end

  local mainFrame, textFrame = GetOrCreateFrames()

  castActive       = true
  castIsChannel    = isChannel or false
  castStartTime    = (startTimeMS or 0) / 1000
  castEndTime      = (endTimeMS   or 0) / 1000

  -- Spell icon
  if cfg.showIcon and spellID and spellID > 0 then
    local tex = C_Spell.GetSpellTexture(spellID)
    if tex then
      mainFrame.iconTex:SetTexture(tex)
      mainFrame.iconFrame:Show()
    else
      mainFrame.iconFrame:Hide()
    end
  else
    mainFrame.iconFrame:Hide()
  end

  -- Spell name
  if cfg.showText then
    local name = (C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or ""
    textFrame.nameText:SetText(name)
  else
    textFrame.nameText:SetText("")
  end

  -- Bar color: cast vs channel
  local color
  if isChannel then
    color = cfg.channelColor or {r=0.2, g=1, b=0.4, a=1}
  else
    color = cfg.barColor or {r=0.2, g=0.8, b=1, a=1}
  end
  mainFrame.fillBar:SetStatusBarColor(color.r, color.g, color.b, color.a or 1)

  -- Initial fill: channels start full and drain, casts start empty and fill
  mainFrame.fillBar:SetValue(isChannel and 1 or 0)

  -- Initial timer text
  if cfg.showTimer then
    local duration = castEndTime - castStartTime
    if duration < 0 then duration = 0 end
    textFrame.timerText:SetText(string.format("%.1f", duration))
  else
    textFrame.timerText:SetText("")
  end

  mainFrame:Show()
  textFrame:Show()
  mainFrame:SetScript("OnUpdate", CastOnUpdate)
end

local function StopCast()
  castActive = false
  if castFrameObj then
    castFrameObj:SetScript("OnUpdate", nil)
    castFrameObj:Hide()
  end
  if castTextFrame then
    castTextFrame:Hide()
  end
end

-- ===================================================================
-- EVENT HANDLER
-- ===================================================================
local castEventFrame = CreateFrame("Frame")
castEventFrame:RegisterEvent("PLAYER_LOGIN")
castEventFrame:RegisterEvent("UNIT_SPELLCAST_START")
castEventFrame:RegisterEvent("UNIT_SPELLCAST_STOP")
castEventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")
castEventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
castEventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
castEventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
castEventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
castEventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
castEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
castEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

castEventFrame:SetScript("OnEvent", function(self, event, unit, castGUID, spellID)
  if event == "PLAYER_LOGIN" then
    ns.Castbar.Init()
    return
  end

  -- Re-evaluate hideOutOfCombat visibility on combat state changes (no unit arg)
  if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
    if not castActive then
      local cfg = GetCastbarDB()
      if cfg and cfg.enabled and cfg.hideOutOfCombat then
        if event == "PLAYER_REGEN_ENABLED" then
          if castFrameObj then
            castFrameObj:Hide()
            if castTextFrame then castTextFrame:Hide() end
          end
        end
      end
    end
    return
  end

  -- All UNIT_SPELLCAST_* events pass unit as the first argument
  if unit ~= "player" then return end

  if event == "UNIT_SPELLCAST_START" then
    local name, _, _, startTimeMS, endTimeMS, _, _, notInterruptible = GetUnitCastingInfo("player")
    if name then
      ShowCast(spellID, startTimeMS, endTimeMS, false, notInterruptible)
    end

  elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
    local name, _, _, startTimeMS, endTimeMS, _, notInterruptible = GetUnitChannelInfo("player")
    if name then
      ShowCast(spellID, startTimeMS, endTimeMS, true, notInterruptible)
    end

  elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
    -- Channel speed changed (e.g. Sped Up buff)
    if castActive and castIsChannel then
      local name, _, _, startTimeMS, endTimeMS = GetUnitChannelInfo("player")
      if name then
        castStartTime = (startTimeMS or 0) / 1000
        castEndTime   = (endTimeMS   or 0) / 1000
      end
    end

  elseif event == "UNIT_SPELLCAST_STOP"
      or event == "UNIT_SPELLCAST_FAILED"
      or event == "UNIT_SPELLCAST_INTERRUPTED"
      or event == "UNIT_SPELLCAST_SUCCEEDED"
      or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
    StopCast()
  end
end)

-- ===================================================================
-- INIT
-- ===================================================================
function ns.Castbar.Init()
  ns.Castbar.ApplyAppearance()
end

-- ===================================================================
-- END OF ArcUI_Castbar.lua
-- ===================================================================
