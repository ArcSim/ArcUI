-- ===================================================================
-- ArcUI_Minimap.lua
-- Simple minimap button - opens options on click
-- ===================================================================

local ADDON, ns = ...
ns.Options = ns.Options or {}

local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

-- ===================================================================
-- CREATE DATA BROKER OBJECT
-- ===================================================================
local minimapButton = LDB:NewDataObject("ArcUI", {
  type = "launcher",
  text = "Arc UI",
  icon = "Interface\\AddOns\\ArcUI\\Textures\\ArcUI_Icon_400x400",
  
  OnClick = function(self, button)
    if button == "RightButton" then
      MenuUtil.CreateContextMenu(self, function(owner, rootDescription)
        rootDescription:CreateTitle("|cff00ccffArc UI|r")
        rootDescription:CreateButton("Open CDM Settings", function()
          local frame = _G["CooldownViewerSettings"]
          if frame and frame.Show then frame:Show(); frame:Raise() end
        end)
        rootDescription:CreateButton("Recenter Options Panel", function()
          local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
          if not AceConfigDialog then return end
          local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
          if globalDB then globalDB.optionsPanelPos = nil; globalDB.optionsPanelSize = nil end
          local status = AceConfigDialog:GetStatusTable("ArcUI")
          if status then
            local sw, sh = GetScreenWidth(), GetScreenHeight()
            local w, h = 900, 700
            status.top = sh / 2 + h / 2; status.left = sw / 2 - w / 2
            status.width = w; status.height = h
          end
          local widget = AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["ArcUI"]
          if widget and widget.frame and widget.frame:IsShown() then
            AceConfigDialog:Close("ArcUI")
            ns.API.OpenOptions()
          end
        end)
      end)
      return
    end
    if button == "MiddleButton" then
      local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
      if AceConfigDialog then
        local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
        if globalDB then globalDB.optionsPanelPos = nil; globalDB.optionsPanelSize = nil end
        local status = AceConfigDialog:GetStatusTable("ArcUI")
        if status then
          local sw, sh = GetScreenWidth(), GetScreenHeight()
          local w, h = 900, 700
          status.top = sh / 2 + h / 2; status.left = sw / 2 - w / 2
          status.width = w; status.height = h
        end
        local widget = AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["ArcUI"]
        if widget and widget.frame and widget.frame:IsShown() then
          AceConfigDialog:Close("ArcUI")
          ns.API.OpenOptions()
        end
      end
      return
    end
    -- Left click: open ArcUI options
    if ns.API and ns.API.OpenOptions then
      ns.API.OpenOptions()
    end
  end,

  OnTooltipShow = function(tooltip)
    if not tooltip or not tooltip.AddLine then return end
    tooltip:SetText("|cff00ccffArc UI|r")
    tooltip:AddLine("Click to open options", 0.7, 0.7, 0.7)
    tooltip:AddLine("Middle-click to recenter options panel", 0.7, 0.7, 0.7)
    tooltip:AddLine("Right-click for more options", 0.7, 0.7, 0.7)
  end
})

-- ===================================================================
-- INITIALIZE MINIMAP BUTTON
-- ===================================================================
function ns.Options.InitMinimapButton()
  local globalDB = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
  if not globalDB then
    return
  end
  
  -- Register with LibDBIcon
  LDBIcon:Register("ArcUI", minimapButton, globalDB.minimap)
  
  -- Show/hide based on settings
  if globalDB.minimap.hide then
    LDBIcon:Hide("ArcUI")
  else
    LDBIcon:Show("ArcUI")
  end
end

-- ===================================================================
-- API FUNCTIONS
-- ===================================================================
function ns.API.ShowMinimapButton()
  LDBIcon:Show("ArcUI")
  local globalDB = ns.API.GetGlobalDB()
  if globalDB then
    globalDB.minimap.hide = false
  end
end

function ns.API.HideMinimapButton()
  LDBIcon:Hide("ArcUI")
  local globalDB = ns.API.GetGlobalDB()
  if globalDB then
    globalDB.minimap.hide = true
  end
end

-- ===================================================================
-- END OF ArcUI_Minimap.lua
-- ===================================================================