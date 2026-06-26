-- ===================================================================
-- ArcUI_Options.lua  
-- Main Options registration for Arc UI
-- v3.4.2: Fixed OpenOptions nil error and added AceDB error handling
-- ===================================================================

local ADDON, ns = ...
ns.Options = ns.Options or {}

local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceDB = LibStub("AceDB-3.0")

-- Profile browser collapsed state (defaults closed)
local profileBrowserCollapsed = true
-- Settings tab section collapsed state (defaults open)
local settingsCollapsed = {}

-- ===================================================================
-- RELIABLE PANEL OPEN/CLOSE DETECTION
-- Hook AceConfigDialog:Open and :Close directly - much more reliable
-- than trying to hook frame OnShow/OnHide
-- ===================================================================
if not AceConfigDialog._arcUIHooked then
    AceConfigDialog._arcUIHooked = true
    
    -- Hook Close
    hooksecurefunc(AceConfigDialog, "Close", function(self, appName)
        if appName == "ArcUI" then
            ns._arcUIOptionsOpen = false
            -- Re-evaluate aura textures (hide previews, disable movers)
            if ns.Textures and ns.Textures.OnOptionsClosed then
                ns.Textures.OnOptionsClosed()
            end
            -- Make cooldown bars click-through again
            if ns.CooldownBars and ns.CooldownBars.RefreshMouseInteractivity then
                ns.CooldownBars.RefreshMouseInteractivity()
            end
            -- Fire registered panel callbacks (ArcAurasCooldown, SpellUsability, etc.)
            if ns.CDMShared and ns.CDMShared.FirePanelCallbacks then
                ns.CDMShared.FirePanelCallbacks(false)
            end
            if ns.CDMGroups and ns.CDMGroups.DynamicLayout and ns.CDMGroups.DynamicLayout.OnOptionsPanelClosed then
                ns.CDMGroups.DynamicLayout.OnOptionsPanelClosed()
            end
            -- IMMEDIATE: All panel-close logic (reflow, click-through, visuals)
            if ns.CDMGroups and ns.CDMGroups.OnArcUIPanelChanged then
                ns.CDMGroups.OnArcUIPanelChanged(false)
            end
        end
    end)
    
    -- Hook Open (backup - we also call directly in OpenOptions)
    hooksecurefunc(AceConfigDialog, "Open", function(self, appName)
        if appName == "ArcUI" then
            local wasOpen = ns._arcUIOptionsOpen
            ns._arcUIOptionsOpen = true
            -- Only fire layout/restore callbacks on actual open (closed → open).
            -- NotifyChange causes AceConfig to call Open again while already open,
            -- which would re-run Layout+RestoreIconsToSavedPositions on every UI rebuild.
            if not wasOpen then
                -- Fire registered panel callbacks (ArcAurasCooldown, SpellUsability, etc.)
                if ns.CDMShared and ns.CDMShared.FirePanelCallbacks then
                    ns.CDMShared.FirePanelCallbacks(true)
                end
                if ns.CDMGroups and ns.CDMGroups.DynamicLayout and ns.CDMGroups.DynamicLayout.OnOptionsPanelOpened then
                    ns.CDMGroups.DynamicLayout.OnOptionsPanelOpened()
                end
                -- IMMEDIATE: All panel-open logic (borders, scan, drag, visuals)
                if ns.CDMGroups and ns.CDMGroups.OnArcUIPanelChanged then
                    ns.CDMGroups.OnArcUIPanelChanged(true)
                end
            end
        end
    end)
end

-- ===================================================================
-- ADDON INFO
-- ===================================================================
-- Get version from TOC file (auto-updates when TOC changes)
local function GetAddonVersion()
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    return C_AddOns.GetAddOnMetadata(ADDON, "Version") or "Unknown"
  elseif GetAddOnMetadata then
    return GetAddOnMetadata(ADDON, "Version") or "Unknown"
  end
  return "Unknown"
end

ns.AddonInfo = {
  Version = GetAddonVersion(),
  Discord = "https://discord.gg/yMZmnFjUTd",
  Author = "Arc",
}

-- ===================================================================
-- DISCORD LINK BUTTON (must be defined before OpenOptions)
-- ===================================================================
local function CreateDiscordLink(parentFrame)
  if parentFrame._arcUIDiscordLink then return end
  
  local container = CreateFrame("Frame", nil, parentFrame)
  container:SetSize(200, 20)
  container:SetPoint("TOPRIGHT", parentFrame, "TOPRIGHT", -10, -8)
  
  local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  label:SetPoint("RIGHT", container, "RIGHT", 0, 0)
  label:SetText("|cff5865F2Discord:|r |cff7289DA" .. ns.AddonInfo.Discord .. "|r")
  
  local link = CreateFrame("EditBox", nil, container)
  link:SetSize(200, 20)
  link:SetPoint("RIGHT", container, "RIGHT", 0, 0)
  link:SetFontObject(GameFontNormal)
  link:SetAutoFocus(false)
  link:EnableMouse(true)
  link:SetText(ns.AddonInfo.Discord)
  link:SetCursorPosition(0)
  link:Hide()
  
  container:EnableMouse(true)
  container:SetScript("OnEnter", function(self)
    label:SetText("|cff5865F2Discord:|r |cffffffffClick to copy|r")
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Click to copy Discord link", 1, 1, 1)
    GameTooltip:Show()
  end)
  container:SetScript("OnLeave", function(self)
    label:SetText("|cff5865F2Discord:|r |cff7289DA" .. ns.AddonInfo.Discord .. "|r")
    GameTooltip:Hide()
  end)
  container:SetScript("OnMouseDown", function(self)
    link:Show()
    link:SetFocus()
    link:HighlightText()
    label:Hide()
  end)
  
  link:SetScript("OnEditFocusLost", function(self)
    self:Hide()
    label:Show()
  end)
  link:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  link:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
  end)
  
  parentFrame._arcUIDiscordLink = container
end

-- ===================================================================
-- EARLY OPENOPTIONS DEFINITION (before PLAYER_LOGIN)
-- This ensures /arcui always has a function to call, even if DB fails
-- ===================================================================
local optionsRegistered = false

ns.API = ns.API or {}

-- Define OpenOptions early - will be replaced with full version after registration
ns.API.OpenOptions = function()
  if not optionsRegistered then
    print("|cff00ccffArc UI|r Options not ready yet. Try again in a moment.")
    print("|cff00ccffArc UI|r If this persists, type: /arcui reset-db")
    return
  end
  
  if InCombatLockdown() then
    ns._arcPendingOptionsOpen = true
    print("|cff00ccffArc UI|r Options will open when combat ends.")
    return
  end
  
  ns._arcPendingOptionsOpen = nil
  ns._arcUIOptionsOpen = true  -- Flag for Resources module to detect options are open

  -- Restore saved position/size into AceConfig's own status table BEFORE Open
  -- AceConfig reads status.top/left/width/height inside Open via SetStatusTable
  do
    local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    local pos  = globalDB and globalDB.optionsPanelPos
    local size = globalDB and globalDB.optionsPanelSize
    if pos or size then
      local status = AceConfigDialog:GetStatusTable("ArcUI")
      if status then
        if pos  then status.top  = pos.top;  status.left   = pos.left   end
        if size then status.width = size.width; status.height = size.height end
        -- Clamp to screen so saved positions from different resolutions don't go offscreen
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        local w = status.width  or 900
        local h = status.height or 700
        if status.top  then status.top  = math.max(h,       math.min(status.top,  sh)) end
        if status.left then status.left = math.max(0,       math.min(status.left, sw - w)) end
        -- Also clamp size to screen
        if w > sw     then status.width  = sw      end
        if h > sh - 50 then status.height = sh - 50 end
      end
    end
  end

  AceConfigDialog:Open("ArcUI")
  -- CDM_Shared's ACD:Open posthook sets ns.optionsPanelOpen and fires all callbacks
  
  -- Refresh resource bars immediately so they show despite talent/spec/combat conditions
  if ns.Resources and ns.Resources.RefreshAllBars then
    ns.Resources.RefreshAllBars()
  end

  -- Refresh aura textures so they preview (and become draggable) while open
  if ns.Textures and ns.Textures.RefreshAll then
    ns.Textures.RefreshAll()
  end

  -- Cooldown bars become draggable while open; click-through when closed
  if ns.CooldownBars and ns.CooldownBars.RefreshMouseInteractivity then
    ns.CooldownBars.RefreshMouseInteractivity()
  end

  -- Show "Hidden by Bar" overlays on CDM icons that are being hidden
  C_Timer.After(0.1, function()
    if ns.API.ShowHiddenByBarOverlays then
      ns.API.ShowHiddenByBarOverlays()
    end
  end)
  
  C_Timer.After(0.05, function()
    local widget = AceConfigDialog.OpenFrames["ArcUI"]
    if widget and widget.frame then
      local actualFrame = widget.frame
      local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
      local alpha = globalDB and globalDB.menuBackgroundAlpha or 1.0
      
      -- Create solid background
      if not actualFrame._arcUISolidBgFrame then
        actualFrame._arcUISolidBgFrame = CreateFrame("Frame", nil, actualFrame)
        actualFrame._arcUISolidBgFrame:SetPoint("TOPLEFT", actualFrame, "TOPLEFT", 8, -8)
        actualFrame._arcUISolidBgFrame:SetPoint("BOTTOMRIGHT", actualFrame, "BOTTOMRIGHT", -8, 8)
        actualFrame._arcUISolidBgFrame:SetFrameLevel(math.max(1, actualFrame:GetFrameLevel() - 1))
        
        actualFrame._arcUISolidBgFrame.tex = actualFrame._arcUISolidBgFrame:CreateTexture(nil, "BACKGROUND")
        actualFrame._arcUISolidBgFrame.tex:SetAllPoints()
        actualFrame._arcUISolidBgFrame.tex:SetColorTexture(0.02, 0.02, 0.02, 1)
      end
      
      actualFrame._arcUISolidBgFrame:SetAlpha(alpha)
      actualFrame._arcUISolidBgFrame:Show()

      -- Position/size restored via AceConfig status table before Open — nothing to do here

      -- Stretch the drag area across the full top of the frame.
      -- AceGUIContainer-Frame: titletext is a child of the title Frame (the drag handle).
      -- widget.titletext is exposed, so :GetParent() gives us the title frame directly.
      -- We clear its points and anchor it across the full frame top so the whole
      -- header bar is draggable, not just the narrow title texture.
      if not actualFrame._arcUITitleStretched then
        actualFrame._arcUITitleStretched = true
        local widget = AceConfigDialog.OpenFrames["ArcUI"]
        if widget and widget.titletext then
          local titleFrame = widget.titletext:GetParent()
          if titleFrame and titleFrame ~= actualFrame then
            titleFrame:ClearAllPoints()
            titleFrame:SetPoint("TOPLEFT",  actualFrame, "TOPLEFT",  0,  0)
            titleFrame:SetPoint("TOPRIGHT", actualFrame, "TOPRIGHT", 0,  0)
            titleFrame:SetHeight(28)
          end
        end
      end
      
      -- Create Discord link at top right (or show existing one)
      CreateDiscordLink(actualFrame)
      if actualFrame._arcUIDiscordLink then
        actualFrame._arcUIDiscordLink:Show()
      end
      
      -- Hook OnHide for cleanup (visual elements, drag mode, etc)
      -- NOTE: OnOptionsPanelClosed is called via AceConfigDialog:Close hook, not here
      if not actualFrame._arcUIOnHideHooked then
        actualFrame._arcUIOnHideHooked = true
        local originalOnHide = actualFrame:GetScript("OnHide")
        actualFrame:SetScript("OnHide", function(self, ...)
          if originalOnHide then originalOnHide(self, ...) end
          
          -- Clear options open flag (backup - Close hook also does this)
          ns._arcUIOptionsOpen = false
          -- Backup: re-evaluate textures + cooldown bar click-through
          if ns.Textures and ns.Textures.OnOptionsClosed then
              ns.Textures.OnOptionsClosed()
          end
          if ns.CooldownBars and ns.CooldownBars.RefreshMouseInteractivity then
              ns.CooldownBars.RefreshMouseInteractivity()
          end
          -- Fire registered panel callbacks (backup path)
          if ns.CDMShared and ns.CDMShared.FirePanelCallbacks then
              ns.CDMShared.FirePanelCallbacks(false)
          end
          
          -- BACKUP: Run panel-close logic if Close hook didn't fire
          -- (e.g. Escape key, other addons closing the frame)
          if ns.CDMGroups and ns.CDMGroups.OnArcUIPanelChanged then
              ns.CDMGroups.OnArcUIPanelChanged(false)
          end
          
          -- Hide "Hidden by Bar" overlays
          if ns.API.HideHiddenByBarOverlays then
            ns.API.HideHiddenByBarOverlays()
          end
          
          -- Save panel position and size via AceConfig status table (kept up to date by AceGUI on drag/resize)
          do
            local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
            if globalDB then
              local status = AceConfigDialog:GetStatusTable("ArcUI")
              if status then
                globalDB.optionsPanelPos  = { top = status.top, left = status.left }
                globalDB.optionsPanelSize = { width = status.width, height = status.height }
              end
            end
          end

          -- CRITICAL: Hide Discord link when panel closes
          -- AceConfigDialog reuses frame objects, so our Discord link would
          -- appear on other addons' config panels if we don't hide it
          if self._arcUIDiscordLink then
            self._arcUIDiscordLink:Hide()
          end
          if self._arcUISolidBgFrame then
            self._arcUISolidBgFrame:Hide()
          end
          
          if ns.Display and ns.Display.HideDeleteButtons then
            ns.Display.HideDeleteButtons()
          end
          if ns.Resources and ns.Resources.HideDeleteButtons then
            ns.Resources.HideDeleteButtons()
          end
          if ns.CDMEnhance and ns.CDMEnhance.SetUnlocked then
            ns.CDMEnhance.SetUnlocked(false)
          end
          if ns.CDMGroups and ns.CDMGroups.SetDragMode then
            ns.CDMGroups.SetDragMode(false)
          end
          
          C_Timer.After(0.1, function()
            if ns.API.ValidateAllBarTracking then
              ns.API.ValidateAllBarTracking()
            end
            -- Refresh resource bars to re-apply visibility rules now that options panel is closed
            -- (bars with unmet talent conditions or wrong spec should now be hidden again)
            if ns.Resources and ns.Resources.RefreshAllBars then
              ns.Resources.RefreshAllBars()
            end
          end)
        end)
      end
    end
    
    if ns.API.ValidateAllBarTracking then
      ns.API.ValidateAllBarTracking()
    end
  end)
end

-- ===================================================================
-- MAIN OPTIONS TABLE
-- ===================================================================
local function GetOptionsTable()
  local optionsTable = {
    type = "group",
    name = "Arc UI",
    childGroups = "tab",
    args = {
      icons = {
        type = "group",
        name = "Icons",
        order = 1,
        childGroups = "tab",
        args = {
          groups = (function()
            local tbl = ns.GetCDMGroupsOptionsTable and ns.GetCDMGroupsOptionsTable() or {
              type = "group",
              name = "Groups",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Groups"
            tbl.order = 1
            return tbl
          end)(),
          
          cdmIcons = (function()
            local tbl = ns.GetCDMIconsOptionsTable and ns.GetCDMIconsOptionsTable() or {
              type = "group",
              name = "Icon Catalog",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Icon Catalog"
            tbl.order = 2
            return tbl
          end)(),
          
          defaults = {
            type = "group",
            name = "Globals",
            order = 5,
            childGroups = "tab",
            args = {
              auraDefaults = (function()
                local tbl = ns.GetCDMGlobalAuraDefaultsOptionsTable and ns.GetCDMGlobalAuraDefaultsOptionsTable() or {
                  type = "group",
                  name = "Aura Globals",
                  args = { loading = { type = "description", name = "Loading...", order = 1 } }
                }
                tbl.name = "Aura Globals"
                tbl.order = 1
                return tbl
              end)(),
              
              cooldownDefaults = (function()
                local tbl = ns.GetCDMGlobalCooldownDefaultsOptionsTable and ns.GetCDMGlobalCooldownDefaultsOptionsTable() or {
                  type = "group",
                  name = "Cooldown Globals",
                  args = { loading = { type = "description", name = "Loading...", order = 1 } }
                }
                tbl.name = "Cooldown Globals"
                tbl.order = 2
                return tbl
              end)(),
            },
          },
          
          -- Extras tab (Keybind Display, Assisted Combat Highlight, Button Press Highlight)
          extras = (function()
            local tbl = ns.GetCDMUtilitiesOptionsTable and ns.GetCDMUtilitiesOptionsTable() or {
              type = "group",
              name = "Extras",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Extras"
            tbl.order = 6
            return tbl
          end)(),
          
          -- Arc Icons tab (tracked trinkets / items / spells)
          arcAuras = (function()
            local tbl = ns.GetArcAurasOptionsTable and ns.GetArcAurasOptionsTable() or {
              type = "group",
              name = "Arc Icons",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            -- Custom Icons is now its OWN top-level tab (below). Strip the nested
            -- copy, and flatten the lone "Main" child so Arc Icons shows its
            -- catalog directly instead of behind a redundant sub-tab.
            if tbl.args then
              tbl.args.customIcons = nil
              if tbl.args.main and tbl.args.main.args then
                tbl.args = tbl.args.main.args
                tbl.childGroups = nil
              end
            end
            tbl.name = "Arc Icons"
            tbl.order = 3
            return tbl
          end)(),

          -- Custom Icons tab (timers) — pulled up out of Arc Icons for visibility
          customIcons = (function()
            local tbl = ns.GetCustomIconsOptionsTable and ns.GetCustomIconsOptionsTable() or {
              type = "group",
              name = "Custom Icons",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Custom Icons"
            tbl.order = 4
            return tbl
          end)(),
          
          -- Profiles tab: Arc Manager profile selector + Profile Browser combined
          profiles = (function()
            local profileMgr = ns.GetCDMProfileManagerOnlyOptionsTable and ns.GetCDMProfileManagerOnlyOptionsTable() or { args = {} }
            local profileBrowser = ns.GetCDMProfileBrowserOptionsTable and ns.GetCDMProfileBrowserOptionsTable() or { args = {} }

            -- Merge browser args under a collapsible header, re-keyed to avoid conflicts
            local mergedArgs = {}
            for k, v in pairs(profileMgr.args or {}) do
              mergedArgs[k] = v
            end

            -- Browser section header with collapsible toggle
            mergedArgs["browserSectionHeader"] = {
              type = "toggle",
              name = "|cffffd100Profile Browser|r",
              desc = "Browse, rename, or delete profiles across all characters and specs",
              dialogControl = "CollapsibleHeader",
              order = 50,
              width = "full",
              get = function() return not profileBrowserCollapsed end,
              set = function(_, v) profileBrowserCollapsed = not v end,
            }
            mergedArgs["browserSectionDesc"] = {
              type = "description",
              name = "|cffaaaaaaBrowse, rename, or delete profiles across all characters and specs on this account.|r",
              order = 51,
              fontSize = "small",
              hidden = function() return profileBrowserCollapsed end,
            }
            -- Inline the browser args at order 52+ sorted by original order
            local browserOrder = 52
            local sortedBrowser = {}
            for k, v in pairs(profileBrowser.args or {}) do
              table.insert(sortedBrowser, { key = k, val = v, ord = v.order or 999 })
            end
            table.sort(sortedBrowser, function(a, b) return a.ord < b.ord end)
            for _, item in ipairs(sortedBrowser) do
              local entry = {}
              for ek, ev in pairs(item.val) do entry[ek] = ev end
              entry.order = browserOrder
              browserOrder = browserOrder + 1
              local origHidden = entry.hidden
              entry.hidden = function()
                if profileBrowserCollapsed then return true end
                if origHidden then return origHidden() end
                return false
              end
              mergedArgs["browser_" .. item.key] = entry
            end

            return {
              type = "group",
              name = "Profiles",
              order = 7,
              args = mergedArgs,
            }
          end)(),

          sharing = (function()
            if ns.CDMSharedProfiles and ns.CDMSharedProfiles.GetOptionsTable then
              local tbl = ns.CDMSharedProfiles.GetOptionsTable()
              tbl.name = "Account Sharing"
              tbl.order = 8
              return tbl
            end
            return {
              type = "group",
              name = "Account Sharing",
              order = 8,
              args = { loading = { type = "description", name = "Loading...", order = 1 } },
            }
          end)(),
        },
      },
      
      -- ═══════════════════════════════════════════════════════════════
      -- AURAS: buff/debuff tracking. One catalog (Bars) where you pick an
      -- aura and create a bar or a texture, plus the shared Appearance.
      -- ═══════════════════════════════════════════════════════════════
      auras = {
        type = "group",
        name = "Buffs/Debuffs",
        order = 2,
        childGroups = "tab",
        args = {
          auraBars = (function()
            local tbl = ns.TrackingOptions and ns.TrackingOptions.GetBuffDebuffSetupTable() or {
              type = "group",
              name = "Catalog",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Catalog"
            tbl.order = 1
            return tbl
          end)(),

          textures = (function()
            local tbl = ns.GetTexturesOptionsTable and ns.GetTexturesOptionsTable() or {
              type = "group",
              name = "Textures",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Textures"
            tbl.order = 2
            return tbl
          end)(),

          appearance = (function()
            local tbl = ns.AppearanceOptions and ns.AppearanceOptions.GetOptionsTable() or {
              type = "group",
              name = "Appearance",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Appearance"
            tbl.order = 3
            return tbl
          end)(),
        },
      },

      -- ═══════════════════════════════════════════════════════════════
      -- COOLDOWNS: spell cooldown / charge / custom-timer bars + castbar.
      -- ═══════════════════════════════════════════════════════════════
      cooldowns = {
        type = "group",
        name = "Cooldowns",
        order = 3,
        childGroups = "tab",
        args = {
          cooldownBars = (function()
            local tbl = ns.CooldownBarOptions and ns.CooldownBarOptions.GetOptionsTable() or {
              type = "group",
              name = "Cooldown Bars",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Cooldown Bars"
            tbl.order = 1
            return tbl
          end)(),

          timerBars = (function()
            local tbl = ns.TimerBarOptions and ns.TimerBarOptions.GetOptionsTable() or {
              type = "group",
              name = "Custom Bars",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Custom Bars"
            tbl.order = 2
            return tbl
          end)(),

          cooldownReminder = (function()
            local tbl = ns.GetCooldownReminderOptionsTable and ns.GetCooldownReminderOptionsTable() or {
              type = "group",
              name = "Cooldown Reminder",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Cooldown Reminder"
            tbl.order = 3
            return tbl
          end)(),

          appearance = (function()
            local tbl = ns.AppearanceOptions and ns.AppearanceOptions.GetOptionsTable() or {
              type = "group",
              name = "Appearance",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Appearance"
            tbl.order = 4
            return tbl
          end)(),
        },
      },

      resources = {
        type = "group",
        name = "Resources",
        order = 4,
        childGroups = "tab",
        args = {
          setup = (function()
            local tbl = ns.TrackingOptions and ns.TrackingOptions.GetResourceSetupTable() or {
              type = "group",
              name = "Setup",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Setup"
            tbl.order = 1
            return tbl
          end)(),
          
          appearance = (function()
            local tbl = ns.AppearanceOptions and ns.AppearanceOptions.GetOptionsTable() or {
              type = "group",
              name = "Appearance",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Appearance"
            tbl.order = 2
            return tbl
          end)(),
        },
      },
      
      -- ═══════════════════════════════════════════════════════════════
      -- IMPORT / EXPORT
      -- Tabs: CDM Export | Bars Export | Master Export | Import (unified)
      -- ═══════════════════════════════════════════════════════════════
      importExport = {
        type = "group",
        name = "Import/Export",
        order = 7,
        childGroups = "tab",
        args = {
          cdmExport = (function()
            local tbl = ns.GetCDMExportOnlyOptionsTable and ns.GetCDMExportOnlyOptionsTable() or {
              type = "group",
              name = "Icon Manager Export",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Icon Manager Export"
            tbl.order = 1
            return tbl
          end)(),

          barsExport = (function()
            local tbl = ns.GetBarsExportOnlyOptionsTable and ns.GetBarsExportOnlyOptionsTable() or {
              type = "group",
              name = "Bars Export",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Bars Export"
            tbl.order = 2
            return tbl
          end)(),

          masterExport = (function()
            local tbl = ns.GetCDMMasterExportOptionsTable and ns.GetCDMMasterExportOptionsTable() or {
              type = "group",
              name = "Master Export",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Master Export"
            tbl.order = 3
            return tbl
          end)(),

          crExport = (function()
            local tbl = ns.GetCRExportOnlyOptionsTable and ns.GetCRExportOnlyOptionsTable() or {
              type = "group",
              name = "Cooldown Reminder Export",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Cooldown Reminder Export"
            tbl.order = 3.5
            return tbl
          end)(),

          castbarExport = (function()
            local tbl = ns.GetCastbarExportOnlyOptionsTable and ns.GetCastbarExportOnlyOptionsTable() or {
              type = "group",
              name = "Castbar Export",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Castbar Export"
            tbl.order = 3.7
            return tbl
          end)(),

          unifiedImport = (function()
            local tbl = ns.GetUnifiedImportExportOptionsTable and ns.GetUnifiedImportExportOptionsTable() or {
              type = "group",
              name = "Import",
              args = { loading = { type = "description", name = "Loading...", order = 1 } }
            }
            tbl.name = "Import"
            tbl.order = 4
            return tbl
          end)(),
        },
      },

      migration = (function()
        local tbl = ns.GetMigrationOptionsTable and ns.GetMigrationOptionsTable() or {
          type = "group",
          name = "Migration",
          args = { loading = { type = "description", name = "Loading...", order = 1 } }
        }
        tbl.name  = "Migration"
        tbl.order = 8
        return tbl
      end)(),

      castbar = (function()
        local tbl = ns.CastbarOptions and ns.CastbarOptions.GetOptionsTable() or {
          type = "group",
          name = "Castbar",
          args = { loading = { type = "description", name = "Loading...", order = 1 } }
        }
        tbl.name  = "Castbar"
        tbl.order = 5
        return tbl
      end)(),

      setMyKick = (function()
        local tbl = ns.GetSetMyKickOptionsTable and ns.GetSetMyKickOptionsTable() or {
          type = "group",
          name = "Kick Assist",
          args = { loading = { type = "description", name = "Loading...", order = 1 } }
        }
        tbl.name  = "Kick Assist"
        tbl.order = 6
        return tbl
      end)(),

      advancedDebuffs = (function()
        local tbl = ns.AdvancedDebuffs and ns.AdvancedDebuffs.GetOptionsTable and ns.AdvancedDebuffs.GetOptionsTable() or {
          type = "group",
          name = "Advanced Debuffs",
          args = { loading = { type = "description", name = "Loading...", order = 1 } }
        }
        tbl.name  = "Advanced Debuffs"
        tbl.order = 3.8
        return tbl
      end)(),

      settings = {
        type = "group",
        name = "Settings",
        order = 9,
        args = {
          menuHeader = {
            type = "toggle",
            name = "|cffffd100Background|r",
            dialogControl = "CollapsibleHeader",
            order = 1,
            width = "full",
            get = function() return not settingsCollapsed.background end,
            set = function(_, v) settingsCollapsed.background = not v end,
          },
          menuBackgroundAlpha = {
            type = "range",
            name = "Menu Background Solidity",
            desc = "Control how solid/opaque the options panel background is (0 = see-through, 1 = fully solid dark background)",
            order = 2,
            min = 0,
            max = 1,
            step = 0.05,
            isPercent = true,
            width = 1.5,
            hidden = function() return settingsCollapsed.background end,
            get = function()
              local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
              return globalDB and globalDB.menuBackgroundAlpha or 1.0
            end,
            set = function(_, val)
              local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
              if globalDB then
                globalDB.menuBackgroundAlpha = val
                local widget = AceConfigDialog.OpenFrames["ArcUI"]
                if widget and widget.frame and widget.frame._arcUISolidBgFrame then
                  widget.frame._arcUISolidBgFrame:SetAlpha(val)
                end
              end
            end,
          },

          minimapHeader = {
            type = "toggle",
            name = "|cffffd100Minimap|r",
            dialogControl = "CollapsibleHeader",
            order = 10,
            width = "full",
            get = function() return not settingsCollapsed.minimap end,
            set = function(_, v) settingsCollapsed.minimap = not v end,
          },
          minimapButton = {
            type = "toggle",
            name = "Show Minimap Button",
            desc = "Toggle the minimap button visibility",
            order = 11,
            width = 1.5,
            hidden = function() return settingsCollapsed.minimap end,
            get = function()
              local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
              return globalDB and not globalDB.minimap.hide
            end,
            set = function(_, val)
              local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
              if globalDB then
                globalDB.minimap.hide = not val
                if val then
                  ns.API.ShowMinimapButton()
                else
                  ns.API.HideMinimapButton()
                end
              end
            end,
          },

          changelogHeader = {
            type = "toggle",
            name = "|cffffd100Changelog|r",
            dialogControl = "CollapsibleHeader",
            order = 20,
            width = "full",
            get = function() return not settingsCollapsed.changelog end,
            set = function(_, v) settingsCollapsed.changelog = not v end,
          },
          changelogShow = {
            type = "toggle",
            name = "Show Changelog on Update",
            desc = "Automatically pop up the 'What's New' window once after each ArcUI update.",
            order = 21,
            width = 1.8,
            hidden = function() return settingsCollapsed.changelog end,
            get = function()
              local g = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
              return not (g and g.changelog and g.changelog.disabled)
            end,
            set = function(_, val)
              local g = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
              if g then
                g.changelog = g.changelog or {}
                g.changelog.disabled = not val
              end
            end,
          },
          changelogView = {
            type = "execute",
            name = "View Changelog",
            desc = "Open the 'What's New' window now.",
            order = 22,
            width = 1.2,
            hidden = function() return settingsCollapsed.changelog end,
            func = function()
              if ns.Changelog and ns.Changelog.Show then ns.Changelog.Show() end
            end,
          },

          aboutHeader = {
            type = "toggle",
            name = "|cffffd100About|r",
            dialogControl = "CollapsibleHeader",
            order = 90,
            width = "full",
            get = function() return not settingsCollapsed.about end,
            set = function(_, v) settingsCollapsed.about = not v end,
          },
          version = {
            type = "input",
            name = "Version",
            order = 91,
            width = 1.0,
            dialogControl = "SFX-Info",
            hidden = function() return settingsCollapsed.about end,
            get = function() return ns.AddonInfo.Version end,
            set = function() end,
          },
          author = {
            type = "input",
            name = "Author",
            order = 92,
            width = 1.0,
            dialogControl = "SFX-Info",
            hidden = function() return settingsCollapsed.about end,
            get = function() return ns.AddonInfo.Author end,
            set = function() end,
          },
        },
      },
    },
  }
  
  return optionsTable
end

-- ===================================================================
-- OPTIONS REGISTRATION
-- ===================================================================
local function RegisterOptions()
  -- skipValidation=true (3rd arg, AceConfigRegistry direct): every edit in an
  -- open panel triggers NotifyChange → re-fetch → full recursive VALIDATION of
  -- the entire tree on top of the rebuild. The lib documents skipValidation as
  -- "primarily useful for extremely huge options, with a noticeable slowdown"
  -- — which is exactly this tree. (AceConfig:RegisterOptionsTable's 3rd arg is
  -- a slash command, not skipValidation, hence the direct registry call.)
  LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable("ArcUI", GetOptionsTable, true)
  AceConfigDialog:SetDefaultSize("ArcUI", 900, 700)
  optionsRegistered = true
end

-- ===================================================================
-- DATABASE RESET FUNCTION
-- ===================================================================
local function ResetDatabase()
  -- Clear the corrupted SavedVariables
  ArcUIDB = nil
  ArcUI_CDMEnhance_Debug = nil
  
  print("|cff00ccffArc UI|r Database has been reset. Please |cffff0000/reload|r to complete the reset.")
  print("|cff00ccffArc UI|r Your settings will be restored to defaults.")
end

-- ===================================================================
-- SLASH COMMANDS (defined early so they always work)
-- ===================================================================
SLASH_ARCBARS1 = "/arcbars"
SLASH_ARCBARS2 = "/ab"
SLASH_ARCBARS3 = "/arcui"
SLASH_ARCBARS4 = "/aui"

SLASH_ARCCDM1 = "/cdm"
SlashCmdList["ARCCDM"] = function()
  local frame = _G["CooldownViewerSettings"]
  if frame and frame.Show then
    frame:Show()
    frame:Raise()
  end
end
SlashCmdList["ARCBARS"] = function(msg)
  msg = msg:lower():trim()
  
  -- Database reset command (always available, even if options fail)
  if msg == "reset-db" or msg == "resetdb" then
    StaticPopupDialogs["ARCUI_RESET_DB"] = {
      text = "This will reset ALL Arc UI settings to defaults.\n\nAre you sure?",
      button1 = "Yes, Reset",
      button2 = "Cancel",
      OnAccept = function()
        ResetDatabase()
      end,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
      preferredIndex = 3,
    }
    StaticPopup_Show("ARCUI_RESET_DB")
    return
  end
  
  if msg == "" or msg == "options" or msg == "config" then
    ns.API.OpenOptions()
  elseif msg == "scan" then
    local buffs, err = ns.API.ScanAvailableBuffs()
    if buffs then
      print("|cff00ccffArc UI|r Found " .. #buffs .. " buff(s)/debuff(s). Open options to configure.")
    else
      print("|cff00ccffArc UI|r Error: " .. (err or "Unknown"))
    end
  elseif msg == "unlock" or msg == "drag" then
    if ns.CDMGroups and ns.CDMGroups.ToggleDragMode then
      ns.CDMGroups.ToggleDragMode()
      if ns.CDMGroups.dragModeEnabled then
        print("|cff00ccffArc UI|r Edit mode |cff00ff00ENABLED|r - drag icons to reposition")
      else
        print("|cff00ccffArc UI|r Edit mode |cffff0000DISABLED|r")
      end
    elseif ns.CDMEnhance and ns.CDMEnhance.ToggleUnlock then
      ns.CDMEnhance.ToggleUnlock()
    else
      print("|cff00ccffArc UI|r CDM module not loaded yet")
    end
  elseif msg == "layout" then
    if ns.LayoutEditor and ns.LayoutEditor.Toggle then
      ns.LayoutEditor.Toggle()
    end
  elseif msg == "recenter" then
    -- Clear saved position so panel opens at default center next time
    local globalDB = ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if globalDB then
      globalDB.optionsPanelPos  = nil
      globalDB.optionsPanelSize = nil
    end
    local status = AceConfigDialog:GetStatusTable("ArcUI")
    if status then
      local sw, sh = GetScreenWidth(), GetScreenHeight()
      local w, h = 900, 700
      status.top  = sh / 2 + h / 2
      status.left = sw / 2 - w / 2
      status.width  = w
      status.height = h
    end
    -- Reopen at new position if already open
    local widget = AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames["ArcUI"]
    if widget and widget.frame and widget.frame:IsShown() then
      AceConfigDialog:Close("ArcUI")
      ns.API.OpenOptions()
    end
    print("|cff00ccffArc UI|r Options panel recentered")
  elseif msg == "reset" then
    local db = ns.API.GetDB()
    if db then
      for i = 1, 30 do
        if db.bars and db.bars[i] then
          db.bars[i].display.barPosition = {point="CENTER", relPoint="CENTER", x=0, y=200-(i-1)*30}
          db.bars[i].display.textPosition = {point="CENTER", relPoint="CENTER", x=0, y=230-(i-1)*30}
        end
        if db.resourceBars and db.resourceBars[i] then
          db.resourceBars[i].display.barPosition = {point="CENTER", relPoint="CENTER", x=0, y=-100-(i-1)*35}
          db.resourceBars[i].display.textPosition = {point="CENTER", relPoint="CENTER", x=0, y=-70-(i-1)*35}
        end
      end
      for i = 1, 30 do
        if ns.Display and ns.Display.ApplyAppearance then
          ns.Display.ApplyAppearance(i)
        end
        if ns.Resources and ns.Resources.ApplyAppearance then
          ns.Resources.ApplyAppearance(i)
        end
      end
      print("|cff00ccffArc UI|r Positions reset")
    end
  elseif msg == "minimap" then
    local globalDB = ns.API.GetGlobalDB()
    if globalDB then
      globalDB.minimap.hide = not globalDB.minimap.hide
      if globalDB.minimap.hide then
        ns.API.HideMinimapButton()
        print("|cff00ccffArc UI|r Minimap button hidden")
      else
        ns.API.ShowMinimapButton()
        print("|cff00ccffArc UI|r Minimap button shown")
      end
    end
  elseif msg == "export" then
    -- Quick export shortcut
    if optionsRegistered then
      ns.API.OpenOptions()
      C_Timer.After(0.1, function()
        AceConfigDialog:SelectGroup("ArcUI", "icons", "profiles")
      end)
    else
      print("|cff00ccffArc UI|r Options not ready yet.")
    end
  elseif msg == "import" then
    -- Quick import shortcut
    if optionsRegistered then
      ns.API.OpenOptions()
      C_Timer.After(0.1, function()
        AceConfigDialog:SelectGroup("ArcUI", "icons", "profiles")
      end)
    else
      print("|cff00ccffArc UI|r Options not ready yet.")
    end
  elseif msg == "help" then
    print("|cff00ccffArc UI|r Commands:")
    print("  /arcui - Open options")
    print("  /arcui scan - Scan for buffs/debuffs")
    print("  /arcui drag - Toggle icon group editing")
    print("  /arcui recenter - Move options panel back to center of screen")
    print("  /arcui reset - Reset bar positions")
    print("  /arcui minimap - Toggle minimap button")
    print("  /arcui export - Open import/export panel")
    print("  /arcui import - Open import/export panel")
    print("  /arcui reset-db - |cffff0000Reset ALL settings to defaults|r")
  else
    print("|cff00ccffArc UI|r Unknown command. Use /arcui help")
  end
end

-- ===================================================================
-- /arcdebug  — full system overview
-- ===================================================================
SLASH_ARCDEBUG1 = "/arcdebug"
SlashCmdList["ARCDEBUG"] = function()
  local ver = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
  local db  = ns.db and ns.db.char

  local sep = "|cff444444" .. string.rep("-", 44) .. "|r"
  local function yn(v)  return v and "|cff00ff00yes|r" or "|cffff5555no|r" end
  local function hi(s)  return "|cffffd100" .. tostring(s) .. "|r" end
  local function dim(s) return "|cff888888" .. tostring(s) .. "|r" end

  print(sep)
  print("|cff00ccffArcUI|r v" .. hi(ver) .. "   " .. dim(date("%H:%M:%S")) .. "   combat=" .. yn(InCombatLockdown()))
  print(sep)

  -- Castbar
  if ns.Castbar and ns.Castbar.GetStatus then
    local s = ns.Castbar.GetStatus()
    local detail = ""
    if s.enabled and s.castActive then
      local stages = s.castEmpowerStages > 0 and (" x" .. s.castEmpowerStages) or ""
      detail = "  " .. dim("[" .. s.castKind .. stages .. "]")
    end
    print("  Castbar       " .. yn(s.enabled) .. detail)
    if s.enabled then
      local flags = {}
      if s.hideChannels    then flags[#flags+1] = "hide-channels" end
      if s.hideOutOfCombat then flags[#flags+1] = "hide-ooc"      end
      if #flags > 0 then print("    " .. dim(table.concat(flags, "  "))) end
    end
  else
    print("  Castbar       " .. dim("module not loaded"))
  end

  -- Aura bars — tracking.enabled is the active flag (same logic as GetActiveBars)
  do
    local activeCount = ns.API.GetActiveBars and #ns.API.GetActiveBars() or 0
    local total = 0
    if db and db.bars then
      for i = 1, 500 do if db.bars[i] then total = total + 1 end end
    end
    print("  Aura Bars     " .. hi(activeCount) .. " enabled / " .. dim(total .. " configured"))
  end

  -- Resource bars — tracking.enabled (same logic as GetActiveResourceBars)
  do
    local activeCount = ns.API.GetActiveResourceBars and #ns.API.GetActiveResourceBars() or 0
    local total = 0
    if db and db.resourceBars then
      for i = 1, 50 do if db.resourceBars[i] then total = total + 1 end end
    end
    print("  Resource Bars " .. hi(activeCount) .. " enabled / " .. dim(total .. " configured"))
  end

  -- Cooldown bars (nested: cooldownBarConfigs[spellID][barType])
  do
    local cdTotal = 0
    if db and db.cooldownBarConfigs then
      for _, configs in pairs(db.cooldownBarConfigs) do
        for _, cfg in pairs(configs) do
          if type(cfg) == "table" then cdTotal = cdTotal + 1 end
        end
      end
    end
    print("  Cooldown Bars " .. hi(cdTotal) .. " configured")
  end

  -- Timer bars
  do
    local total = 0
    if db and db.timerBarConfigs then
      for _, cfg in pairs(db.timerBarConfigs) do
        if type(cfg) == "table" then total = total + 1 end
      end
    end
    print("  Timer Bars    " .. hi(total) .. " configured")
  end

  -- Cooldown Reminder
  do
    local crDB = db and db.cooldownReminder
    print("  CD Reminder   " .. yn(crDB and crDB.enabled))
  end

  print(sep)

  -- CDM Enhancement
  if ns.CDMShared then
    print("  CDM Enhance   " .. yn(ns.CDMShared.IsCDMStylingEnabled()))
  else
    print("  CDM Enhance   " .. dim("module not loaded"))
  end

  -- CDM Groups
  if ns.CDMGroups then
    local groupCount, freeCount = 0, 0
    if ns.CDMGroups.groups then
      for _ in pairs(ns.CDMGroups.groups) do groupCount = groupCount + 1 end
    end
    if ns.CDMGroups.freeIcons then
      for _ in pairs(ns.CDMGroups.freeIcons) do freeCount = freeCount + 1 end
    end
    print("  CDM Groups    " .. hi(groupCount) .. " groups / " .. hi(freeCount) .. " free icons")
  else
    print("  CDM Groups    " .. dim("module not loaded"))
  end

  -- Arc Auras
  if ns.ArcAuras then
    local arcCount = 0
    local frames = ns.ArcAuras.frames or {}
    for _ in pairs(frames) do arcCount = arcCount + 1 end
    print("  Arc Auras     " .. hi(arcCount) .. " tracked")
  else
    print("  Arc Auras     " .. dim("module not loaded"))
  end

  print(sep)
  print(dim("  /arcui  /arccastdebug  /arcmasque  /arcrepair"))
  print(sep)
end

-- ===================================================================
-- MAIN INITIALIZATION
-- ===================================================================
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
initFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

initFrame:SetScript("OnEvent", function(self, event)
  if event == "PLAYER_REGEN_DISABLED" then
    -- Close options panel when entering combat
    local widget = AceConfigDialog.OpenFrames["ArcUI"]
    if widget then
      AceConfigDialog:Close("ArcUI")
      print("|cff00ccffArc UI|r Options closed - entering combat.")
    end
    return
  end
  
  if event == "PLAYER_REGEN_ENABLED" then
    -- Open options panel if user tried to open during combat
    if ns._arcPendingOptionsOpen then
      ns._arcPendingOptionsOpen = nil
      C_Timer.After(0.1, function()
        if not InCombatLockdown() then
          ns.API.OpenOptions()
        end
      end)
    end
    return
  end
  
  if event == "PLAYER_LOGIN" then
    -- ═══════════════════════════════════════════════════════════════════
    -- ACEDB INITIALIZATION WITH ERROR HANDLING
    -- ═══════════════════════════════════════════════════════════════════
    local dbSuccess, dbError = pcall(function()
      ns.db = AceDB:New("ArcUIDB", ns.DB_DEFAULTS, true)
    end)
    
    if not dbSuccess then
      -- Database failed to load - likely corrupted
      print("|cff00ccffArc UI|r |cffff0000ERROR:|r Database failed to load!")
      print("|cff00ccffArc UI|r Error: " .. tostring(dbError))
      print("|cff00ccffArc UI|r Type |cffff0000/arcui reset-db|r to reset settings and fix this.")
      
      -- Create a minimal database so the addon doesn't completely break
      ns.db = {
        char = {},
        profile = {},
        global = ns.DB_DEFAULTS.global,
      }
      
      -- Still register options so the UI can open (even if limited)
      C_Timer.After(0.1, function()
        RegisterOptions()
        print("|cff00ccffArc UI|r v" .. ns.AddonInfo.Version .. " loaded with LIMITED functionality.")
      end)
      return
    end
    
    -- ═══════════════════════════════════════════════════════════════════
    -- CLEANUP: Remove empty/unconfigured bar configs to reduce memory
    -- Replaces old sparse array hole-filling which was adding bloat
    -- ═══════════════════════════════════════════════════════════════════
    if ns.DataRepair and ns.DataRepair.RunAutoCleanup then
      ns.DataRepair.RunAutoCleanup()
    end
    
    C_Timer.After(0.1, function()
      RegisterOptions()
      
      if ns.Options.InitMinimapButton then
        ns.Options.InitMinimapButton()
      end
      if ns.Display and ns.Display.Init then
        ns.Display.Init()
      end
      if ns.Resources and ns.Resources.Init then
        ns.Resources.Init()
      end
      if ns.CooldownBars and ns.CooldownBars.Init then
        ns.CooldownBars.Init()
      end
      if ns.CustomTracking and ns.CustomTracking.Init then
        ns.CustomTracking.Init()
      end
      if ns.Castbar and ns.Castbar.Init then
        ns.Castbar.Init()
      end
      if ns.AdvancedDebuffs and ns.AdvancedDebuffs.Init then
        ns.AdvancedDebuffs.Init()
      end
      if ns.SetMyKick and ns.SetMyKick.Init then
        ns.SetMyKick.Init()
      end
      if ns.Textures and ns.Textures.Init then
        ns.Textures.Init()
      end

      print("|cff00ccffArc UI|r v" .. ns.AddonInfo.Version .. " loaded. Type /arcui for options, /cdm for CDM settings, /arcui recenter to move panel back to screen.")
    end)
  end
end)