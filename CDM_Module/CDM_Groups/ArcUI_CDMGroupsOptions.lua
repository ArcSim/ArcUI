-- ===================================================================
-- ArcUI_CDMGroupsOptions.lua
-- Options panel for CDM Icon Groups
-- Integrated from CDMGroups addon
-- ===================================================================

local ADDON_NAME, ns = ...

-- Reference to shared module (for CDM styling toggle)
local Shared = ns.CDMShared

-- Forward declarations
local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = DeepCopy(v)
    end
    return copy
end

-- Remap alignment when grid shape changes so user's intent is preserved
local function RemapAlignmentForShape(oldShape, newShape, currentAlignment)
    if oldShape == newShape then return nil end
    
    local mapped
    if oldShape == "horizontal" and newShape == "multi" then
        local map = { center = "center_h", left = "left", right = "right" }
        mapped = map[currentAlignment]
    elseif oldShape == "vertical" and newShape == "multi" then
        local map = { center = "center_v", top = "top", bottom = "bottom" }
        mapped = map[currentAlignment]
    elseif newShape == "horizontal" then
        local map = { center_h = "center", center_v = "center", left = "left", right = "right", top = "left", bottom = "right", center = "center" }
        mapped = map[currentAlignment]
    elseif newShape == "vertical" then
        local map = { center_h = "center", center_v = "center", top = "top", bottom = "bottom", left = "top", right = "bottom", center = "center" }
        mapped = map[currentAlignment]
    end
    
    return mapped
end

-- Remap and save alignment BEFORE SetGridSize so Layout() uses the correct value
-- Does NOT call Layout - SetGridSize already does that internally
local function RemapAlignmentBeforeResize(g, oldRows, oldCols, newRows, newCols)
    local DetectGridShape = ns.CDMGroups.DetectGridShape
    local GetDefaultAlignment = ns.CDMGroups.GetDefaultAlignment
    if not DetectGridShape or not GetDefaultAlignment then return end
    
    local oldShape = DetectGridShape(oldRows, oldCols)
    local newShape = DetectGridShape(newRows, newCols)
    if oldShape == newShape then return end
    
    local old = g.layout.alignment or GetDefaultAlignment(oldShape)
    local mapped = RemapAlignmentForShape(oldShape, newShape, old)
    local newAlignment = mapped or GetDefaultAlignment(newShape)
    
    g.layout.alignment = newAlignment
    local db = g.getDB and g.getDB()
    if db then db.alignment = newAlignment end
end

-- CRITICAL: Use the exported GetSpecData from main module (reads from char storage)
-- DO NOT use ns.db.profile.cdmGroups - that's the OLD account-wide storage!
local function GetSpecData(specIndex)
    -- Use the canonical GetSpecData from CDMGroups module which reads from ns.db.char
    if ns.CDMGroups and ns.CDMGroups.GetSpecData then
        return ns.CDMGroups.GetSpecData(specIndex)
    end
    return nil
end

local function ClearPositionFromSpec(cdID)
    -- Use the canonical ClearPositionFromSpec from CDMGroups module
    if ns.CDMGroups and ns.CDMGroups.ClearPositionFromSpec then
        ns.CDMGroups.ClearPositionFromSpec(cdID)
    end
end

local function PrintMsg(msg)
    print("|cff00ccffArcUI|r: " .. msg)
end

-- Default group template
local DEFAULT_GROUPS = {
    Buffs = {
        enabled = true,
        position = { x = -200, y = 150 },
        showBorder = false,
        showBackground = false,
        autoReflow = true,  -- Default true for new groups
        lockGridSize = false,
        containerPadding = 0,
        borderColor = { r = 0.3, g = 0.8, b = 0.3, a = 1 },
        bgColor = { r = 0, g = 0, b = 0, a = 0.6 },
        layout = {
            direction = "HORIZONTAL",
            spacing = 2,
            iconSize = 36,
            perRow = 4,
            gridRows = 2,
            gridCols = 4,
            horizontalGrowth = "RIGHT",  -- RIGHT or LEFT
            verticalGrowth = "DOWN",     -- DOWN or UP
        },
    },
}

-- UI STATE FOR OPTIONS (ns.CDMGroups.selectedGroup stored globally)

local collapsedSections = {
    groupLayouts = true,   -- Load Group Layout - start collapsed
    placeholders = true,   -- Placeholders section - start collapsed
    globalOptions = true,
    grid = false,
    layout = false,
    frameStrata = true,    -- Frame Strata section - start collapsed
    anchoring = true,      -- Anchoring section - start collapsed
    position = true,
    appearance = true,
    tools = true,
}

-- OPTIONS TABLE

local function GetOptionsTable()
    -- Helper to get selected group object
    local function GetSelectedGroup()
        return ns.CDMGroups.groups[ns.CDMGroups.selectedGroup]
    end
    
    -- Check if selected group exists in DB but NOT at runtime (broken/orphaned)
    local function IsSelectedGroupBroken()
        if not ns.CDMGroups.selectedGroup or ns.CDMGroups.selectedGroup == "" then
            return false
        end
        -- Check profile.groupLayouts for existence
        local specData = GetSpecData()
        local profile = nil
        if specData and specData.layoutProfiles then
            local profileName = specData.activeProfile or "Default"
            profile = specData.layoutProfiles[profileName]
        end
        local _eiLDB = profile and profile.groupLayoutName and ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
        local _eiSrc = (_eiLDB and _eiLDB[profile.groupLayoutName]) or (profile and profile.groupLayouts)
        local existsInProfile = _eiSrc and _eiSrc[ns.CDMGroups.selectedGroup]
        local existsAtRuntime = ns.CDMGroups.groups[ns.CDMGroups.selectedGroup]
        return existsInProfile and not existsAtRuntime
    end
    
    -- Helper to check if section should be hidden
    local function HideIfNoGroup()
        return not GetSelectedGroup()
    end
    
    -- Helper for fine tuning mode
    local function IsFineTuning()
        local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
        return db and db.fineTuningLayout
    end
    
    -- Build group dropdown values (from runtime groups primarily)
    local function GetGroupValues()
        local values = {}
        
        -- Primary: Use runtime groups (authoritative for active session)
        for groupName, _ in pairs(ns.CDMGroups.groups or {}) do
            values[groupName] = groupName
        end
        
        -- Secondary: Check profile.groupLayouts for groups not yet loaded
        local specData = GetSpecData()
        local profile = nil
        if specData and specData.layoutProfiles then
            local profileName = specData.activeProfile or "Default"
            profile = specData.layoutProfiles[profileName]
        end
        
        local _ggvLDB = profile and profile.groupLayoutName and ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
        local _ggvSrc = (_ggvLDB and _ggvLDB[profile.groupLayoutName]) or (profile and profile.groupLayouts)
        if _ggvSrc then
            for groupName, _ in pairs(_ggvSrc) do
                if not values[groupName] then
                    -- Group exists in profile but not at runtime
                    if ns.CDMGroups.initialLoadInProgress then
                        values[groupName] = "|cff888888" .. groupName .. " (loading)|r"
                    else
                        values[groupName] = "|cffff6666" .. groupName .. " (broken)|r"
                    end
                end
            end
        end
        
        return values
    end
    
    -- Create a new group with default settings (in current spec)
    local function CreateNewGroup(groupName)
        if not groupName or groupName == "" then return false end
        
        -- Check if group already exists in runtime
        if ns.CDMGroups.groups and ns.CDMGroups.groups[groupName] then
            return false -- Already exists
        end
        
        -- CreateGroup handles everything:
        -- 1. Reads from profile.groupLayouts (or creates defaults)
        -- 2. Saves new group to profile.groupLayouts
        -- 3. Creates runtime group object
        local group = ns.CDMGroups.CreateGroup(groupName)
        if not group then return false end
        
        -- Select the new group
        ns.CDMGroups.selectedGroup = groupName
        
        -- Trigger auto-save to linked template
        if ns.CDMGroups.TriggerTemplateAutoSave then
            ns.CDMGroups.TriggerTemplateAutoSave()
        end
        
        return true
    end
    
    -- Rename a group (in current spec)
    local function RenameGroup(oldName, newName)
        if not oldName or not newName or oldName == "" or newName == "" then return false end
        if oldName == newName then return false end
        
        -- Check runtime groups first (authoritative for existence check)
        if not ns.CDMGroups.groups[oldName] then return false end -- Old group doesn't exist
        if ns.CDMGroups.groups[newName] then return false end -- New name already exists
        
        -- Get profile for updating groupLayouts
        local specData = GetSpecData()
        local profile = nil
        if specData and specData.layoutProfiles then
            local profileName = specData.activeProfile or "Default"
            profile = specData.layoutProfiles[profileName]
        end
        
        -- Update profile.groupLayouts (single source of truth)
        local _rnLDB = profile and profile.groupLayoutName and ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
        local _rnTarget = (_rnLDB and _rnLDB[profile.groupLayoutName]) or (profile and profile.groupLayouts)
        if _rnTarget and _rnTarget[oldName] then
            _rnTarget[newName] = _rnTarget[oldName]
            _rnTarget[oldName] = nil
        end
        
        -- Update savedPositions references (ns.CDMGroups.savedPositions IS profile.savedPositions)
        for cdID, saved in pairs(ns.CDMGroups.savedPositions) do
            if saved.type == "group" and saved.target == oldName then
                saved.target = newName
            end
        end
        
        -- Update the actual runtime group object
        local group = ns.CDMGroups.groups[oldName]
        group.name = newName
        ns.CDMGroups.groups[newName] = group
        ns.CDMGroups.groups[oldName] = nil
        
        -- Update specGroups reference
        if ns.CDMGroups.currentSpec and ns.CDMGroups.specGroups[ns.CDMGroups.currentSpec] then
            ns.CDMGroups.specGroups[ns.CDMGroups.currentSpec][newName] = group
            ns.CDMGroups.specGroups[ns.CDMGroups.currentSpec][oldName] = nil
        end
        
        -- Also clean up legacy specData.groups if it exists
        if specData and specData.groups then
            if specData.groups[oldName] then
                specData.groups[newName] = specData.groups[oldName]
                specData.groups[oldName] = nil
            end
        end
        
        -- Update title with proper color
        if group.container and group.container.title then
            local color = group.borderColor or { r = 0.5, g = 0.5, b = 0.5 }
            local hex = string.format("|cff%02x%02x%02x", color.r*255, color.g*255, color.b*255)
            group.container.title:SetText(hex .. newName .. "|r")
        end
        
        -- Update dragBar label
        if group.dragBar then
            for i = 1, group.dragBar:GetNumRegions() do
                local region = select(i, group.dragBar:GetRegions())
                if region and region:GetObjectType() == "FontString" then
                    region:SetText("|cffffffffDrag Group|r")
                    break
                end
            end
        end
        
        -- Update member entries
        for cdID, member in pairs(group.members) do
            if member.entry then
                member.entry.group = group
            end
        end
        
        -- Update selection
        ns.CDMGroups.selectedGroup = newName
        
        -- Trigger auto-save to linked template
        if ns.CDMGroups.TriggerTemplateAutoSave then
            ns.CDMGroups.TriggerTemplateAutoSave()
        end
        
        return true
    end
    
    -- Delete a group (from current spec)
    local function DeleteGroup(groupName)
        if not groupName or groupName == "" then return false end
        
        -- Check runtime groups (authoritative)
        if not ns.CDMGroups.groups[groupName] then return false end
        
        local group = ns.CDMGroups.groups[groupName]
        
        -- Collect all member cdIDs and place them as free icons in a row
        local toRelease = {}
        for cdID, member in pairs(group.members or {}) do
            table.insert(toRelease, { cdID = cdID, frame = member.frame })
        end
        
        -- Place icons as free icons in a horizontal row at center of screen
        local startX = -((#toRelease - 1) * 40) / 2  -- Center the row
        for i, info in ipairs(toRelease) do
            local cdID = info.cdID
            local xPos = startX + (i - 1) * 40
            local yPos = 0
            
            -- Clear from group without returning to CDM
            if group.members[cdID] then
                local member = group.members[cdID]
                if member.entry then
                    member.entry.manipulated = false
                    member.entry.group = nil
                end
                group.members[cdID] = nil
            end
            
            -- Clear from grid
            for row, cols in pairs(group.grid or {}) do
                for col, id in pairs(cols) do
                    if id == cdID then
                        cols[col] = nil
                    end
                end
            end
            
            -- Clear saved position
            ns.CDMGroups.savedPositions[cdID] = nil
            ClearPositionFromSpec(cdID)
            
            -- Track as free icon
            ns.CDMGroups.TrackFreeIcon(cdID, xPos, yPos, 36)
        end
        
        -- Hide and clean up the container
        if group.container then
            group.container:Hide()
            group.container:SetParent(nil)
        end
        if group.dragBar then
            group.dragBar:Hide()
            group.dragBar:SetParent(nil)
        end
        if group.selectionHighlight then
            group.selectionHighlight:Hide()
        end
        
        -- Hide edge arrows (the +/- buttons)
        if group.edgeArrows then
            for _, arrow in pairs(group.edgeArrows) do
                if arrow then
                    arrow:Hide()
                    arrow:SetParent(nil)
                end
            end
        end
        
        -- Remove from runtime
        ns.CDMGroups.groups[groupName] = nil
        if ns.CDMGroups.currentSpec and ns.CDMGroups.specGroups[ns.CDMGroups.currentSpec] then
            ns.CDMGroups.specGroups[ns.CDMGroups.currentSpec][groupName] = nil
        end
        
        -- Remove from profile.groupLayouts (single source of truth)
        local specData = GetSpecData()
        if specData and specData.layoutProfiles then
            local profileName = specData.activeProfile or "Default"
            local profile = specData.layoutProfiles[profileName]
            local _delTarget = profile and ns.CDMGroups.GetLayoutTarget and ns.CDMGroups.GetLayoutTarget(profile)
            if _delTarget then
                _delTarget[groupName] = nil
            end
        end
        
        -- Also clean up legacy specData.groups if it exists
        if specData and specData.groups then
            specData.groups[groupName] = nil
        end
        
        -- Clear selection if this was selected
        if ns.CDMGroups.selectedGroup == groupName then
            -- Select another runtime group
            local newSelection = ""
            for name, _ in pairs(ns.CDMGroups.groups) do
                newSelection = name
                break
            end
            ns.CDMGroups.selectedGroup = newSelection
        end
        
        -- Trigger auto-save to linked template
        if ns.CDMGroups.TriggerTemplateAutoSave then
            ns.CDMGroups.TriggerTemplateAutoSave()
        end
        
        return true
    end
    
    local function IsCDMEnabled()
        local S = ns.CDMShared
        if S and S.IsCDMStylingEnabled then return S.IsCDMStylingEnabled() end
        return true
    end

    local options = {
        type = "group",
        name = function()
            local specName = ns.CDMGroups.currentSpec
            if GetSpecializationInfo then
                local _, name = GetSpecializationInfo(ns.CDMGroups.currentSpec)
                if name then specName = name end
            end
            return "CDM Groups |cff888888(" .. specName .. ")|r"
        end,
        args = {
            cdmDisabledMsg = {
                type = "description",
                name = "\n|cffff4444CDM Module is Disabled\n\nUse the 'Enable CDM Module' toggle above to re-enable icon styling and group management.|r\n",
                order = 3,
                width = "full",
                fontSize = "large",
                hidden = function() return IsCDMEnabled() end,
            },
            -- EDIT MODE (enables icon dragging - auto-enables when panel opens)
            editModeToggle = {
                type = "toggle",
                name = "|cff00ff00Edit Mode|r",
                desc = "Enable dragging individual icons within groups.\n\nAuto-enables when options panel opens.",
                order = 0,
                width = 0.65,
                get = function() return ns.CDMGroups.dragModeEnabled end,
                set = function(_, val) 
                    -- Disable auto-enable when manually toggling off
                    if not val then
                        ns.CDMGroups._userDisabledEditMode = true
                    else
                        ns.CDMGroups._userDisabledEditMode = false
                    end
                    ns.CDMGroups.SetDragMode(val) 
                end,
            },
            -- DRAG GROUPS (shows overlays for dragging group containers)
            dragGroupsToggle = {
                type = "toggle",
                name = "|cff00ccffDrag Groups|r",
                desc = "Show drag overlays on groups to reposition them.\n\nDoes NOT auto-enable when panel opens.",
                order = 0.05,
                width = 0.8,
                get = function() 
                    return ns.EditModeContainers and ns.EditModeContainers.IsOverlaysEnabled and ns.EditModeContainers.IsOverlaysEnabled()
                end,
                set = function(_, val) 
                    if ns.EditModeContainers and ns.EditModeContainers.SetOverlaysEnabled then
                        ns.EditModeContainers.SetOverlaysEnabled(val)
                    end
                end,
            },
            -- MASTER ENABLE TOGGLE (uses Shared.IsCDMStylingEnabled)
            masterEnable = {
                type = "toggle",
                name = "|cff00ff00Enable CDM Module|r",
                desc = "Master toggle to enable/disable all ArcUI CDM icon styling and group management.\n\n|cffffaa00Reload recommended after changing.|r\n\nWhen disabled, icons stay under default CDM control.",
                order = 0.1,
                width = 1.3,
                disabled = function() return false end,  -- Always enabled so user can re-enable CDM
                get = function() 
                    -- Use centralized function from CDM_Shared
                    local S = ns.CDMShared
                    if S and S.IsCDMStylingEnabled then
                        return S.IsCDMStylingEnabled()
                    end
                    return true
                end,
                set = function(_, val) 
                    -- Use centralized function from CDM_Shared
                    local S = ns.CDMShared
                    if S and S.SetCDMStylingEnabled then
                        S.SetCDMStylingEnabled(val)
                    end
                end,
            },
            keepCDMStyle = {
                type = "toggle",
                name = "Keep CDM Styling",
                desc = "Preserve CDM's native icon look: rounded mask, shadow overlay, and proportional glow borders.\n\nWhen enabled, ArcUI will reposition the CDM shadow overlay proportionally as icons are resized, keeping it correctly fitted at all sizes.\n\n|cffffaa00Enabled by default for new specs. Existing users can enable this manually.|r",
                order = 0.2,
                width = 1.3,
                get = function()
                    local specData = GetSpecData()
                    if specData then return specData.keepCDMStyle == true end
                    return false
                end,
                set = function(_, val)
                    local specData = GetSpecData()
                    if specData then
                        specData.keepCDMStyle = val or nil
                        if ns.CDMEnhance and ns.CDMEnhance.InvalidateCache then
                            ns.CDMEnhance.InvalidateCache()
                        end
                        if ns.CDMEnhance and ns.CDMEnhance.RefreshAllStyles then
                            ns.CDMEnhance.RefreshAllStyles()
                        end
                    end
                end,
            },
            masterSpacer = {
                type = "description",
                name = "",
                order = 0.5,
                width = "full",
            },
            addDefaultGroupsBtn = {
                type = "execute",
                name = "|cff88ff88+ Default Groups|r",
                desc = "Create the 3 default groups (Buffs, Essential, Utility) if they don't exist.\n\nThis does NOT delete any existing groups or positions.",
                order = 22.5,
                width = 1.1,
                func = function()
                    if InCombatLockdown() then
                        PrintMsg("|cffff0000Cannot create groups in combat|r")
                        return
                    end
                    
                    local created = 0
                    local defaults = { "Buffs", "Essential", "Utility" }
                    
                    for _, name in ipairs(defaults) do
                        if not ns.CDMGroups.groups[name] then
                            if ns.CDMGroups.CreateGroup then
                                ns.CDMGroups.CreateGroup(name)
                                created = created + 1
                            end
                        end
                    end
                    
                    if created > 0 then
                        PrintMsg("Created " .. created .. " default group(s)")
                        ns.CDMGroups.UpdateGroupSelectionVisuals()
                        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                    else
                        PrintMsg("All default groups already exist")
                    end
                end,
            },
            showBorderInEditMode = {
                type = "toggle",
                name = "Show Borders",
                desc = "Show group borders and backgrounds when in edit mode. Disable to see true layout without borders.",
                order = 1.5,
                width = 0.85,
                get = function()
                    -- Use shared DB accessor (reads from char.cdmGroups)
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return true end  -- Default to showing
                    local val = db.showBorderInEditMode
                    if val == nil then return true end
                    return val
                end,
                set = function(_, val)
                    -- Use shared DB accessor (writes to char.cdmGroups)
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return end
                    db.showBorderInEditMode = val
                    -- Update all groups
                    for _, group in pairs(ns.CDMGroups.groups or {}) do
                        if group.UpdateAppearance then
                            group.UpdateAppearance()
                        end
                    end
                    ns.CDMGroups.UpdateGroupSelectionVisuals()
                end,
            },
            showControlButtons = {
                type = "toggle",
                name = "Show Layout Arrows",
                desc = "Show the row/column add/remove arrow buttons on group edges when in edit mode.",
                order = 1.6,
                width = 1.2,
                get = function()
                    -- Use shared DB accessor (reads from char.cdmGroups)
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return true end  -- Default to showing
                    local val = db.showControlButtons
                    if val == nil then return true end
                    return val
                end,
                set = function(_, val)
                    -- Use shared DB accessor (writes to char.cdmGroups)
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return end
                    db.showControlButtons = val
                    ns.CDMGroups.UpdateGroupSelectionVisuals()
                end,
            },
            showDragHandle = {
                type = "toggle",
                name = "Show Drag Handle",
                desc = "Show the drag handle icon on groups when in edit mode. You can still move groups via the Edit Mode overlay even with this hidden.",
                order = 1.65,
                width = 1.1,
                get = function()
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return true end
                    local val = db.showDragHandle
                    if val == nil then return true end
                    return val
                end,
                set = function(_, val)
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return end
                    db.showDragHandle = val
                    -- Immediately show/hide drag handles on all groups
                    for _, group in pairs(ns.CDMGroups.groups or {}) do
                        if group.container and group.container.dragToggleBtn then
                            if val and ns.CDMGroups.dragModeEnabled then
                                group.container.dragToggleBtn:Show()
                            else
                                group.container.dragToggleBtn:Hide()
                            end
                        end
                    end
                end,
            },

            scanBtn = {
                type = "execute",
                name = "Scan & Assign",
                desc = "Clean invalid positions and re-assign icons. Icons pointing to deleted groups get reassigned to defaults.",
                order = 2,
                width = 0.9,
                func = function()
                    -- First ensure default groups exist
                    local defaults = { "Buffs", "Essential", "Utility" }
                    for _, name in ipairs(defaults) do
                        if not ns.CDMGroups.groups[name] then
                            if ns.CDMGroups.CreateGroup then
                                ns.CDMGroups.CreateGroup(name)
                            end
                        end
                    end
                    
                    -- CRITICAL: Clean savedPositions pointing to non-existent groups
                    -- This makes Reconcile treat them as new icons and assign to defaults
                    local cleanedCount = 0
                    local savedPositions = ns.CDMGroups.savedPositions
                    if savedPositions then
                        local toRemove = {}
                        for cdID, saved in pairs(savedPositions) do
                            if saved.type == "group" and saved.target then
                                if not ns.CDMGroups.groups[saved.target] then
                                    table.insert(toRemove, cdID)
                                end
                            end
                        end
                        for _, cdID in ipairs(toRemove) do
                            savedPositions[cdID] = nil
                            cleanedCount = cleanedCount + 1
                        end
                    end
                    
                    if cleanedCount > 0 then
                        PrintMsg("|cffff8800Cleaned|r " .. cleanedCount .. " invalid positions")
                    end
                    
                    -- Run Reconcile
                    if ns.FrameController and ns.FrameController.Reconcile then
                        ns.FrameController.Reconcile()
                        PrintMsg("|cff00ff00Done|r - icons assigned to saved or default positions")
                    else
                        local count = ns.CDMGroups.ScanAllViewers and ns.CDMGroups.ScanAllViewers() or 0
                        local assigned = ns.CDMGroups.AutoAssignNewIcons and ns.CDMGroups.AutoAssignNewIcons() or 0
                        PrintMsg("Found " .. count .. " icons, assigned " .. assigned .. " new")
                    end
                    
                    -- Refresh drag handlers if drag mode is on
                    if ns.CDMGroups.dragModeEnabled and ns.FrameController and ns.FrameController.RefreshDragHandlers then
                        C_Timer.After(0.2, function()
                            ns.FrameController.RefreshDragHandlers()
                        end)
                    end
                    
                    -- Refresh
                    ns.CDMGroups.UpdateGroupSelectionVisuals()
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            emergencyRescueBtn = {
                type = "execute",
                name = "|cffff8800Emergency Rescue|r",
                desc = "EMERGENCY: Find ALL frames with cooldownID that aren't being tracked and create them as FREE ICONS. Use this if icons are stuck/missing. Rescued icons appear on screen and can be dragged.",
                order = 2.1,
                width = 1.1,
                func = function()
                    if ns.CDMGroups.EmergencyRescue then
                        local rescued, tracked, errors = ns.CDMGroups.EmergencyRescue()
                        -- Refresh UI
                        ns.CDMGroups.UpdateGroupSelectionVisuals()
                        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                    else
                        PrintMsg("|cffff0000EmergencyRescue function not available!|r")
                    end
                end,
            },

            openCDM = {
                type = "execute",
                name = "Open CD Manager",
                desc = "Open the Cooldown Manager settings panel",
                order = 2.7,
                width = 1.05,
                func = function()
                    local frame = _G["CooldownViewerSettings"]
                    if frame and frame.Show then
                        frame:Show()
                        frame:Raise()
                    end
                end,
            },

            spacer1 = {
                type = "description",
                name = "",
                order = 3,
                width = "full",
            },
            
            -- ════════════════════════════════════════════════════════════════
            -- PLACEHOLDERS SECTION (collapsible)
            -- ════════════════════════════════════════════════════════════════
            placeholdersToggle = {
                type = "toggle",
                name = "Placeholders",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 4,
                width = "full",
                get = function() return not collapsedSections.placeholders end,
                set = function(_, v) collapsedSections.placeholders = not v end,
            },
            phShowPlaceholders = {
                type = "toggle",
                name = "Show Placeholders",
                desc = "Show placeholder icons for saved positions that don't have an active cooldown.\nPlaceholders are visible in Edit Mode and can be dragged to new positions.",
                order = 4.1,
                width = 1.15,
                hidden = function() return collapsedSections.placeholders end,
                get = function()
                    if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.GetShowPlaceholdersDB then
                        return ns.CDMGroups.Placeholders.GetShowPlaceholdersDB()
                    end
                    return false
                end,
                set = function(_, val)
                    if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.SetEditingMode then
                        ns.CDMGroups.Placeholders.SetEditingMode(val)
                    end
                end,
            },
            phCatalogBtn = {
                type = "execute",
                name = "Placeholder Catalog",
                desc = "Open the cooldown catalog to add a placeholder for an ability you don't currently have.",
                order = 4.2,
                width = 1.25,
                hidden = function() return collapsedSections.placeholders end,
                func = function()
                    if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.ShowCooldownPicker then
                        ns.CDMGroups.Placeholders.ShowCooldownPicker()
                    else
                        PrintMsg("Placeholder picker not available. Use /arcuiph picker")
                    end
                end,
            },
            phRefreshBtn = {
                type = "execute",
                name = "Refresh",
                desc = "Refresh all placeholder positions and visibility.",
                order = 4.3,
                width = 0.5,
                hidden = function() return collapsedSections.placeholders end,
                func = function()
                    if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.RefreshAllPlaceholders then
                        ns.CDMGroups.Placeholders.RefreshAllPlaceholders()
                        PrintMsg("Placeholders refreshed")
                    end
                end,
            },
            phClearAllBtn = {
                type = "execute",
                name = "|cffff6666Clear All|r",
                desc = "Remove ALL placeholders from all groups. This clears saved placeholder positions.\n\n|cffffaa00This cannot be undone.|r",
                order = 4.4,
                width = 0.65,
                hidden = function() return collapsedSections.placeholders end,
                confirm = true,
                confirmText = "Remove ALL placeholders from all groups?\n\nThis clears their saved positions and cannot be undone.",
                func = function()
                    local removed = 0
                    -- Clear placeholder members from all groups
                    for groupName, group in pairs(ns.CDMGroups.groups or {}) do
                        if group.members then
                            local toRemove = {}
                            for cdID, member in pairs(group.members) do
                                if member.isPlaceholder then
                                    table.insert(toRemove, cdID)
                                end
                            end
                            for _, cdID in ipairs(toRemove) do
                                -- Hide visual placeholder
                                if ns.CDMGroups.Placeholders and ns.CDMGroups.Placeholders.HidePlaceholder then
                                    ns.CDMGroups.Placeholders.HidePlaceholder(cdID)
                                end
                                -- Clear from grid
                                if group.grid and group.members[cdID] then
                                    local m = group.members[cdID]
                                    if m.row and m.col and group.grid[m.row] and group.grid[m.row][m.col] == cdID then
                                        group.grid[m.row][m.col] = nil
                                    end
                                end
                                -- Remove member
                                group.members[cdID] = nil
                                -- Clear saved position
                                if ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[cdID] then
                                    if ns.CDMGroups.savedPositions[cdID].isPlaceholder then
                                        ns.CDMGroups.savedPositions[cdID] = nil
                                        ClearPositionFromSpec(cdID)
                                    end
                                end
                                removed = removed + 1
                            end
                        end
                    end
                    -- Also clear any savedPositions marked as placeholder that aren't in groups
                    for cdID, saved in pairs(ns.CDMGroups.savedPositions or {}) do
                        if saved.isPlaceholder then
                            ns.CDMGroups.savedPositions[cdID] = nil
                            ClearPositionFromSpec(cdID)
                            removed = removed + 1
                        end
                    end
                    PrintMsg("Cleared " .. removed .. " placeholder(s)")
                    -- Refresh UI
                    ns.CDMGroups.UpdateGroupSelectionVisuals()
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            phCountInfo = {
                type = "description",
                name = function()
                    local count = 0
                    for _, group in pairs(ns.CDMGroups.groups or {}) do
                        if group.members then
                            for _, member in pairs(group.members) do
                                if member.isPlaceholder then
                                    count = count + 1
                                end
                            end
                        end
                    end
                    -- Also count savedPositions placeholders not in groups
                    for cdID, saved in pairs(ns.CDMGroups.savedPositions or {}) do
                        if saved.isPlaceholder then
                            local found = false
                            for _, group in pairs(ns.CDMGroups.groups or {}) do
                                if group.members and group.members[cdID] then
                                    found = true
                                    break
                                end
                            end
                            if not found then count = count + 1 end
                        end
                    end
                    if count == 0 then
                        return "|cff888888No placeholders active.|r"
                    else
                        return string.format("|cff00ff00%d placeholder(s) active.|r", count)
                    end
                end,
                order = 4.5,
                width = "full",
                fontSize = "small",
                hidden = function() return collapsedSections.placeholders end,
            },
            phSpacer = {
                type = "description",
                name = " ",
                order = 4.9,
                width = "full",
                hidden = function() return collapsedSections.placeholders end,
            },
            
            -- ════════════════════════════════════════════════════════════════
            -- LOAD GROUP LAYOUT SECTION
            -- ════════════════════════════════════════════════════════════════
            groupLayoutsToggle = {
                type = "toggle",
                name = "Group Layout",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 5,
                width = "full",
                get = function() return not collapsedSections.groupLayouts end,
                set = function(_, v) collapsedSections.groupLayouts = not v end,
            },
            glProfilesSelect = {
                type = "select",
                name = "Arc Manager Profile",
                desc = "Select a profile from any character/spec to load as your group layout.",
                order = 5.1,
                width = 1.4,
                hidden = function()
                    if collapsedSections.groupLayouts then return true end
                    local IE = ns.CDMImportExport
                    if not IE or not IE.GetAvailableProfiles then return true end
                    local profiles = IE.GetAvailableProfiles()
                    return #profiles == 0
                end,
                values = function()
                    local vals = { [""] = "|cff666666Select a profile...|r" }
                    local IE = ns.CDMImportExport
                    if IE and IE.GetAvailableProfiles then
                        local profiles = IE.GetAvailableProfiles()
                        for _, p in ipairs(profiles) do
                            vals[p.key] = p.displayName
                        end
                    end
                    return vals
                end,
                sorting = function()
                    local order = { "" }
                    local IE = ns.CDMImportExport
                    if IE and IE.GetAvailableProfiles then
                        local profiles = IE.GetAvailableProfiles()
                        for _, p in ipairs(profiles) do
                            order[#order + 1] = p.key
                        end
                    end
                    return order
                end,
                get = function() return ns.CDMGroupsOptions_selectedProfile or "" end,
                set = function(_, val) ns.CDMGroupsOptions_selectedProfile = val ~= "" and val or nil end,
            },
            glProfilesLoadBtn = {
                type = "execute",
                name = "|cff00ff00Load|r",
                desc = "Load selected profile. This replaces your current group layout and requires a reload.",
                order = 5.2,
                width = 0.4,
                hidden = function()
                    if collapsedSections.groupLayouts then return true end
                    local IE = ns.CDMImportExport
                    if not IE or not IE.GetAvailableProfiles then return true end
                    local profiles = IE.GetAvailableProfiles()
                    return #profiles == 0
                end,
                disabled = function() return not ns.CDMGroupsOptions_selectedProfile or ns.CDMGroupsOptions_selectedProfile == "" end,
                func = function()
                    local sel = ns.CDMGroupsOptions_selectedProfile
                    if not sel or sel == "" then return end
                    
                    local IE = ns.CDMImportExport
                    if not IE or not IE.GetAvailableProfiles then return end
                    
                    -- Find profile info
                    local profiles = IE.GetAvailableProfiles()
                    local info = nil
                    for _, p in ipairs(profiles) do
                        if p.key == sel then
                            info = p
                            break
                        end
                    end
                    if not info then return end
                    
                    local confirmText = info.profileName .. " (" .. info.charName .. " - " .. info.specName .. ")"
                    
                    StaticPopupDialogs["ARCUI_GROUPS_LOAD_PROFILE"] = {
                        text = "Load profile '" .. confirmText .. "'?\n\nThis will REPLACE your current group layout.\n|cffffaa00Requires a UI reload to complete.|r",
                        button1 = "Load",
                        button2 = "Cancel",
                        OnAccept = function()
                            if IE.ImportLayoutFromAccount then
                                IE.ImportLayoutFromAccount(info.key)
                            end
                            ns.CDMGroupsOptions_selectedProfile = nil
                            local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
                            if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
                            
                            -- Show reload prompt after layout import
                            C_Timer.After(0.1, function()
                                StaticPopupDialogs["ARCUI_GROUPS_RELOAD_AFTER_LAYOUT"] = {
                                    text = "Group layout imported successfully!\n\nPlease reload your UI to apply the changes.",
                                    button1 = "Reload Now",
                                    button2 = "Later",
                                    OnAccept = function()
                                        ReloadUI()
                                    end,
                                    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
                                }
                                StaticPopup_Show("ARCUI_GROUPS_RELOAD_AFTER_LAYOUT")
                            end)
                        end,
                        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
                    }
                    StaticPopup_Show("ARCUI_GROUPS_LOAD_PROFILE")
                end,
            },
            glProfilesNoData = {
                type = "description",
                name = "|cff666666No other profiles available. Play other specs or characters to generate layouts.|r",
                order = 5.3,
                width = "full",
                fontSize = "small",
                hidden = function()
                    if collapsedSections.groupLayouts then return true end
                    local IE = ns.CDMImportExport
                    if not IE or not IE.GetAvailableProfiles then return false end
                    local profiles = IE.GetAvailableProfiles()
                    return #profiles > 0
                end,
            },
            
            -- ════════════════════════════════════════════════════════════════
            -- LINK TO GROUP LAYOUT (inside Load Group Layout section)
            -- ════════════════════════════════════════════════════════════════
            glLinkSpacer = {
                type = "description",
                name = " ",
                order = 5.4,
                width = "full",
                hidden = function() return collapsedSections.groupLayouts end,
            },
            glLinkHeader = {
                type = "description",
                name = "|cffd4af37Link to Group Layout|r",
                order = 5.41,
                width = "full",
                fontSize = "medium",
                hidden = function() return collapsedSections.groupLayouts end,
            },
            glLinkDesc = {
                type = "description",
                name = "|cffaaaaaaLive-link this profile to a shared Group Layout. All group positions and sizes are stored account-wide and shared by any linked profile.|r",
                order = 5.42,
                width = "full",
                fontSize = "small",
                hidden = function() return collapsedSections.groupLayouts end,
            },
            glLinkStatus = {
                type = "description",
                name = function()
                    local linked = ns.CDMGroups and ns.CDMGroups.GetActiveProfileGroupLayoutName and ns.CDMGroups.GetActiveProfileGroupLayoutName()
                    if linked then
                        return "|cff00ccffLinked to: " .. linked .. "|r"
                    end
                    return "|cff888888Independent — not linked to any layout.|r"
                end,
                order = 5.43,
                width = "full",
                fontSize = "medium",
                hidden = function() return collapsedSections.groupLayouts end,
            },
            glLinkSelect = {
                type = "select",
                name = "Group Layout",
                desc = "Select a Group Layout to link this profile to.",
                order = 5.5,
                width = 1.4,
                hidden = function()
                    if collapsedSections.groupLayouts then return true end
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return not db or not next(db)
                end,
                values = function()
                    local vals = { [""] = "|cff666666Select a layout...|r" }
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    if db then
                        for name in pairs(db) do
                            vals[name] = name
                        end
                    end
                    return vals
                end,
                sorting = function()
                    local order = { "" }
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    if db then
                        for name in pairs(db) do
                            order[#order + 1] = name
                        end
                    end
                    return order
                end,
                get = function()
                    -- Pre-populate with currently linked layout if nothing explicitly selected
                    if ns._glLinkSelected then return ns._glLinkSelected end
                    local linked = ns.CDMGroups and ns.CDMGroups.GetActiveProfileGroupLayoutName and ns.CDMGroups.GetActiveProfileGroupLayoutName()
                    return linked or ""
                end,
                set = function(_, val) ns._glLinkSelected = val ~= "" and val or nil end,
            },
            glLinkBtn = {
                type = "execute",
                name = "Link",
                desc = "Link this profile to the selected layout.",
                order = 5.51,
                width = 0.4,
                hidden = function()
                    if collapsedSections.groupLayouts then return true end
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return not db or not next(db)
                end,
                disabled = function() return not ns._glLinkSelected or ns._glLinkSelected == "" end,
                func = function()
                    local sel = ns._glLinkSelected
                    if not sel or sel == "" then return end
                    if ns.CDMGroups and ns.CDMGroups.LinkProfileToGroupLayout then
                        ns.CDMGroups.LinkProfileToGroupLayout(sel)
                    end
                    ns._glLinkSelected = nil
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            glUnlinkBtn = {
                type = "execute",
                name = "Unlink",
                desc = "Detach from the layout and take an independent snapshot.",
                order = 5.52,
                width = 0.5,
                hidden = function()
                    if collapsedSections.groupLayouts then return true end
                    local linked = ns.CDMGroups and ns.CDMGroups.GetActiveProfileGroupLayoutName and ns.CDMGroups.GetActiveProfileGroupLayoutName()
                    return not linked
                end,
                func = function()
                    if ns.CDMGroups and ns.CDMGroups.UnlinkProfileFromGroupLayout then
                        ns.CDMGroups.UnlinkProfileFromGroupLayout()
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
                confirm = true,
                confirmText = "Unlink from Group Layout? A snapshot will be taken — your layout won't change, but future changes won't be shared.",
            },
            glNoLayoutsNote = {
                type = "description",
                name = "|cff888888No Group Layouts exist yet.|r",
                order = 5.6,
                width = "full",
                fontSize = "small",
                hidden = function()
                    if collapsedSections.groupLayouts then return true end
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return db and next(db) ~= nil
                end,
            },
            glCreateSpacer = {
                type = "description",
                name = " ",
                order = 5.7,
                width = "full",
                hidden = function() return collapsedSections.groupLayouts end,
            },
            glCreateHeader = {
                type = "description",
                name = "|cffd4af37Create New Layout|r",
                order = 5.71,
                width = "full",
                fontSize = "medium",
                hidden = function() return collapsedSections.groupLayouts end,
            },
            glCreateDesc = {
                type = "description",
                name = "|cff888888Save your current group positions as a new named layout, then link this profile to it.|r",
                order = 5.72,
                width = "full",
                fontSize = "small",
                hidden = function() return collapsedSections.groupLayouts end,
            },
            glCreateName = {
                type = "input",
                name = "Layout Name",
                order = 5.73,
                width = 1.2,
                get = function() return ns._glCreateName or "" end,
                set = function(_, val) ns._glCreateName = val ~= "" and val or nil end,
                hidden = function() return collapsedSections.groupLayouts end,
            },
            glCreateBtn = {
                type = "execute",
                name = "Create & Link",
                desc = "Create a new layout from your current groups and link this profile to it.",
                order = 5.74,
                width = 0.75,
                hidden = function() return collapsedSections.groupLayouts end,
                disabled = function()
                    local name = ns._glCreateName
                    if not name or name == "" then return true end
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return db and db[name] ~= nil
                end,
                func = function()
                    local name = ns._glCreateName
                    if not name or name == "" then return end
                    -- Save current groups first
                    if ns.CDMGroups and ns.CDMGroups.SaveGroupLayoutsToActiveProfile then
                        ns.CDMGroups.SaveGroupLayoutsToActiveProfile()
                    end
                    local specData = ns.CDMGroups and ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData()
                    local activeProfileName = (specData and specData.activeProfile) or "Default"
                    local profile = specData and specData.layoutProfiles and specData.layoutProfiles[activeProfileName]
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    if db then
                        local seedSrc = (profile and profile.groupLayoutName and db[profile.groupLayoutName])
                            or (profile and profile.groupLayouts and next(profile.groupLayouts) and profile.groupLayouts)
                        if seedSrc then
                            local copy = {}
                            for k, v in pairs(seedSrc) do copy[k] = v end
                            db[name] = copy
                        else
                            db[name] = {}
                        end
                    end
                    -- Auto-link this profile to the new layout
                    if ns.CDMGroups and ns.CDMGroups.LinkProfileToGroupLayout then
                        ns.CDMGroups.LinkProfileToGroupLayout(name)
                    end
                    ns._glCreateName = nil
                    ns._glLinkSelected = nil
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                    print("|cff00ccffArcUI|r: Group Layout '" .. name .. "' created and linked.")
                end,
                confirm = function()
                    local name = ns._glCreateName
                    if not name or name == "" then return false end
                    return "Create Group Layout '" .. name .. "' from your current groups and link this profile to it?"
                end,
            },
            glCreateDupeNote = {
                type = "description",
                name = "|cffff8800A layout with that name already exists.|r",
                order = 5.75,
                width = "full",
                fontSize = "small",
                hidden = function()
                    if collapsedSections.groupLayouts then return true end
                    local name = ns._glCreateName
                    if not name or name == "" then return true end
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return not (db and db[name])
                end,
            },

            -- ════════════════════════════════════════════════════════════════
            -- GLOBAL OPTIONS SECTION (collapsible)
            -- ════════════════════════════════════════════════════════════════
            globalOptionsToggle = {
                type = "toggle",
                name = "Global Options",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 16,
                width = "full",
                get = function() return not collapsedSections.globalOptions end,
                set = function(_, v) collapsedSections.globalOptions = not v end,
            },
            globalOptionsDesc = {
                type = "description",
                name = "|cffaaaaaaGlobal settings that apply to all icons managed by ArcUI.|r",
                order = 16.1,
                width = "full",
                fontSize = "small",
                hidden = function() return collapsedSections.globalOptions end,
            },
            showTooltips = {
                type = "toggle",
                name = "Show Tooltips",
                desc = "When enabled, hovering over icons shows spell tooltips.\n\nWhen disabled, tooltips are hidden on all icons managed by ArcUI.\n\n|cffaaaaaaSeparate from Click-Through: you can have tooltips off but still click icons, or vice versa.|r",
                order = 16.15,
                width = 0.9,
                hidden = function() return collapsedSections.globalOptions end,
                get = function()
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return true end  -- Default: show tooltips
                    return db.disableTooltips ~= true
                end,
                set = function(_, val)
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return end
                    db.disableTooltips = not val
                    if ns.CDMGroups and ns.CDMGroups.RefreshIconSettings then
                        ns.CDMGroups.RefreshIconSettings()
                    end
                end,
            },
            clickThrough = {
                type = "toggle",
                name = "Click-Through",
                desc = "When enabled, icons cannot be clicked - mouse clicks pass through to whatever is behind them.\n\n|cffaaaaaaNOTE: This also blocks tooltips since no mouse events reach the icon. Use 'Show Tooltips' above if you only want to hide tooltips while keeping icons clickable.|r",
                order = 16.2,
                width = 0.9,
                hidden = function() return collapsedSections.globalOptions end,
                get = function()
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return false end  -- Default: clickable
                    return db.clickThrough == true
                end,
                set = function(_, val)
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if not db then return end
                    db.clickThrough = val
                    -- Refresh cache and apply to all frames via RefreshIconSettings
                    if ns.CDMGroups and ns.CDMGroups.RefreshIconSettings then
                        ns.CDMGroups.RefreshIconSettings()
                    end
                end,
            },
            containerSyncHeader = {
                type = "description",
                name = "\n|cff88ffffContainer Sync|r - Anchor CDM viewers to ArcUI group positions",
                order = 16.4,
                width = "full",
                fontSize = "medium",
                hidden = function() return collapsedSections.globalOptions end,
            },
            containerSyncDesc = {
                type = "description",
                name = "|cffaaaaaaAnchors the base CDM viewer to the matching ArcUI group proxy. "
                    .. "The viewer auto-tracks position and size. Blizzard's Layout resize is suppressed while synced. "
                    .. "Detaches automatically in Edit Mode so you can still drag viewers.|r",
                order = 16.41,
                width = "full",
                fontSize = "small",
                hidden = function() return collapsedSections.globalOptions end,
            },
            syncBuffs = {
                type = "toggle",
                name = "Sync Buffs",
                desc = "Anchor the BuffIcon CDM viewer to the Buffs group proxy.",
                order = 16.5,
                width = 0.7,
                hidden = function() return collapsedSections.globalOptions end,
                get = function()
                    return ns.CDMContainerSync and ns.CDMContainerSync.IsEnabled("Buffs") or false
                end,
                set = function(_, val)
                    if ns.CDMContainerSync then
                        ns.CDMContainerSync.SetEnabled("Buffs", val)
                    end
                end,
            },
            syncEssential = {
                type = "toggle",
                name = "Sync Essential",
                desc = "Anchor the Essential CDM viewer to the Essential group proxy.",
                order = 16.6,
                width = 0.9,
                hidden = function() return collapsedSections.globalOptions end,
                get = function()
                    return ns.CDMContainerSync and ns.CDMContainerSync.IsEnabled("Essential") or false
                end,
                set = function(_, val)
                    if ns.CDMContainerSync then
                        ns.CDMContainerSync.SetEnabled("Essential", val)
                    end
                end,
            },
            syncUtility = {
                type = "toggle",
                name = "Sync Utility",
                desc = "Anchor the Utility CDM viewer to the Utility group proxy.",
                order = 16.7,
                width = 0.8,
                hidden = function() return collapsedSections.globalOptions end,
                get = function()
                    return ns.CDMContainerSync and ns.CDMContainerSync.IsEnabled("Utility") or false
                end,
                set = function(_, val)
                    if ns.CDMContainerSync then
                        ns.CDMContainerSync.SetEnabled("Utility", val)
                    end
                end,
            },
            globalOptionsSpacer = {
                type = "description",
                name = " ",
                order = 16.9,
                width = "full",
                hidden = function() return collapsedSections.globalOptions end,
            },
            
            -- GROUP MANAGEMENT
            groupManageHeader = {
                type = "header",
                name = function()
                    local g = GetSelectedGroup()
                    if g then
                        local color = g.borderColor or { r = 0.5, g = 0.5, b = 0.5 }
                        local hex = string.format("|cff%02x%02x%02x", color.r*255, color.g*255, color.b*255)
                        local memberCount = 0
                        for _ in pairs(g.members) do memberCount = memberCount + 1 end
                        local slots = g.layout.gridRows * g.layout.gridCols
                        return "Group Editing: " .. hex .. g.name .. "|r |cff888888[" .. memberCount .. "/" .. slots .. "]|r"
                    end
                    return "Group Editing: |cff888888Select a Group|r"
                end,
                order = 20,
            },
            groupSelect = {
                type = "select",
                name = "",
                desc = "Choose group to edit. Or click a group in-game!",
                order = 21,
                width = 1.0,
                values = GetGroupValues,
                get = function() return ns.CDMGroups.selectedGroup end,
                set = function(_, val) 
                    ns.CDMGroups.selectedGroup = val 
                    ns.CDMGroups.UpdateGroupSelectionVisuals()
                end,
            },
            newGroupBtn = {
                type = "execute",
                name = "|cff88ff88+ New Group|r",
                desc = "Create a new group",
                order = 22,
                width = 0.8,
                func = function()
                    -- Generate unique name (check runtime groups, authoritative for existence)
                    local baseName = "Group"
                    local num = 1
                    local groups = ns.CDMGroups.groups or {}
                    while groups[baseName .. num] do
                        num = num + 1
                    end
                    local newName = baseName .. num
                    if CreateNewGroup(newName) then
                        PrintMsg("Created '" .. newName .. "'")
                        ns.CDMGroups.UpdateGroupSelectionVisuals()
                    end
                end,
            },
            renameGroupInput = {
                type = "input",
                name = "Rename",
                desc = "New name for selected group",
                order = 23,
                width = 0.55,
                hidden = HideIfNoGroup,
                get = function() return "" end,
                set = function(_, val)
                    if val and val ~= "" and ns.CDMGroups.selectedGroup then
                        local oldName = ns.CDMGroups.selectedGroup
                        if RenameGroup(oldName, val) then
                            PrintMsg("Renamed to '" .. val .. "'")
                            ns.CDMGroups.UpdateGroupSelectionVisuals()
                            -- Refresh options panel to show new name
                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                        else
                            print("|cffff0000CDMGroups|r: Name exists or invalid")
                        end
                    end
                end,
            },
            deleteGroupBtn = {
                type = "execute",
                name = "|cffff6666X|r",
                desc = "Delete selected group",
                order = 24,
                width = 0.25,
                hidden = function()
                    -- Show delete for both valid AND broken groups
                    return not GetSelectedGroup() and not IsSelectedGroupBroken()
                end,
                confirm = function() 
                    if IsSelectedGroupBroken() then
                        return "Delete broken group '" .. (ns.CDMGroups.selectedGroup or "") .. "'?\n\nThis will remove the corrupted entry."
                    end
                    return "Delete '" .. (ns.CDMGroups.selectedGroup or "") .. "'?\nIcons become free." 
                end,
                func = function()
                    if ns.CDMGroups.selectedGroup then
                        local name = ns.CDMGroups.selectedGroup
                        if DeleteGroup(name) then
                            PrintMsg("Deleted '" .. name .. "'")
                            ns.CDMGroups.UpdateGroupSelectionVisuals()
                        end
                    end
                end,
            },
            repairGroupBtn = {
                type = "execute",
                name = "|cffffaa00Repair|r",
                desc = "Attempt to recreate this broken group",
                order = 24.5,
                width = 0.5,
                hidden = function()
                    -- Only show for broken groups
                    return not IsSelectedGroupBroken()
                end,
                func = function()
                    if ns.CDMGroups.selectedGroup and IsSelectedGroupBroken() then
                        local name = ns.CDMGroups.selectedGroup
                        -- Try to recreate the group
                        local group = ns.CDMGroups.CreateGroup(name)
                        if group then
                            PrintMsg("Repaired group '" .. name .. "'")
                            ns.CDMGroups.UpdateGroupSelectionVisuals()
                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                        else
                            PrintMsg("|cffff0000Failed to repair|r '" .. name .. "' - try deleting and recreating")
                        end
                    end
                end,
            },
            
            -- WARNING: Broken group message
            brokenGroupWarning = {
                type = "description",
                name = "|cffff6666This group is broken!|r\n\n" ..
                       "|cffaaaaaaThe group exists in saved data but failed to load properly.\n" ..
                       "This can happen after a Lua error or addon update.\n\n" ..
                       "Try |cffffaa00Repair|r to recreate it, or |cffff6666X|r to delete it.|r",
                order = 25,
                fontSize = "medium",
                width = "full",
                hidden = function()
                    return not IsSelectedGroupBroken()
                end,
            },
            
            -- GRID SETTINGS SECTION
            gridHeader = {
                type = "toggle",
                name = "Grid Settings",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 30,
                width = "full",
                get = function() return not collapsedSections.grid end,
                set = function(_, v) collapsedSections.grid = not v end,
            },
            gridRows = {
                type = "range",
                name = "Rows",
                desc = "Number of rows in the grid. Grid will auto-expand when icons are added.",
                order = 31,
                min = 1, max = 20, step = 1,
                width = 0.7,
                hidden = function() return HideIfNoGroup() or collapsedSections.grid end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.layout.gridRows or 2
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        local oldRows = g.layout.gridRows or 1
                        local oldCols = g.layout.gridCols or 1
                        -- Remap alignment BEFORE SetGridSize (which calls Layout internally)
                        RemapAlignmentBeforeResize(g, oldRows, oldCols, val, oldCols)
                        g:SetGridSize(val, oldCols)
                    end
                end,
            },
            gridCols = {
                type = "range",
                name = "Columns",
                desc = "Number of columns in the grid",
                order = 32,
                min = 1, max = 20, step = 1,
                width = 0.7,
                hidden = function() return HideIfNoGroup() or collapsedSections.grid end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.layout.gridCols or 4
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        local oldRows = g.layout.gridRows or 1
                        local oldCols = g.layout.gridCols or 1
                        -- Remap alignment BEFORE SetGridSize (which calls Layout internally)
                        RemapAlignmentBeforeResize(g, oldRows, oldCols, oldRows, val)
                        g:SetGridSize(oldRows, val)
                    end
                end,
            },
            horizontalGrowth = {
                type = "select",
                name = "Col Growth",
                desc = "Column growth direction - where new columns are added when grid expands",
                order = 33,
                width = 0.7,
                hidden = function() return HideIfNoGroup() or collapsedSections.grid end,
                values = { RIGHT = "Right", LEFT = "Left" },
                get = function()
                    local g = GetSelectedGroup()
                    if not g then return "RIGHT" end
                    return g.layout.horizontalGrowth or "RIGHT"
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        g.layout.horizontalGrowth = val
                        -- Save to DB (flat structure - db.horizontalGrowth, NOT db.layout.horizontalGrowth)
                        local db = g.getDB and g.getDB()
                        if db then
                            db.horizontalGrowth = val
                        end
                        -- Trigger layout refresh
                        if g.Layout then g:Layout() end
                        -- Trigger auto-save to linked template
                        if ns.CDMGroups.TriggerTemplateAutoSave then
                            ns.CDMGroups.TriggerTemplateAutoSave()
                        end
                    end
                end,
            },
            verticalGrowth = {
                type = "select",
                name = "Row Growth",
                desc = "Row growth direction - where new rows are added when grid expands",
                order = 33.5,
                width = 0.7,
                hidden = function() return HideIfNoGroup() or collapsedSections.grid end,
                values = { DOWN = "Down", UP = "Up" },
                get = function()
                    local g = GetSelectedGroup()
                    if not g then return "DOWN" end
                    return g.layout.verticalGrowth or "DOWN"
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        g.layout.verticalGrowth = val
                        -- Save to DB (flat structure - db.verticalGrowth, NOT db.layout.verticalGrowth)
                        local db = g.getDB and g.getDB()
                        if db then
                            db.verticalGrowth = val
                        end
                        -- Trigger layout refresh
                        if g.Layout then g:Layout() end
                        -- Trigger auto-save to linked template
                        if ns.CDMGroups.TriggerTemplateAutoSave then
                            ns.CDMGroups.TriggerTemplateAutoSave()
                        end
                    end
                end,
            },
            lockGridSize = {
                type = "toggle",
                name = "Lock Grid Size",
                desc = "Prevent grid expansion when dragging icons in this group (prevents accidental row/column creation)",
                order = 34,
                width = 0.95,
                hidden = function() return HideIfNoGroup() or collapsedSections.grid end,
                get = function() 
                    local g = GetSelectedGroup()
                    return g and g.lockGridSize
                end,
                set = function(_, val) 
                    local g = GetSelectedGroup()
                    if g then g:SetLockGridSize(val) end
                end,
            },
            gridRowBreak1 = {
                type = "description",
                name = "",
                order = 34.9,
                width = "full",
                hidden = function() return HideIfNoGroup() or collapsedSections.grid end,
            },
            containerPadding = {
                type = "range",
                name = "Container Padding",
                desc = "Space around icons inside the container.\n\n|cffffd700-6|r = Tight (Masque-friendly)\n|cffffd7000|r = Compact\n|cffffd7004|r = Default\n|cffffd7008+|r = Spacious",
                order = 35,
                width = 1.15,
                min = -6,
                max = 12,
                step = 1,
                hidden = function() return HideIfNoGroup() or collapsedSections.grid end,
                get = function()
                    local g = GetSelectedGroup()
                    -- Internal -4 displays as 0, internal 0 displays as 4, etc.
                    return g and (g.containerPadding or 0) + 4 or 4
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    -- Slider 0 stores as -4, slider 4 stores as 0, etc.
                    if g then g:SetContainerPadding(val - 4) end
                end,
            },
            layoutSpacer = {
                type = "description",
                name = "",
                order = 35.9,
                width = "full",
                hidden = function() return HideIfNoGroup() or collapsedSections.grid end,
            },
            autoReflow = {
                type = "toggle",
                name = "Dynamic Layout",
                desc = "Automatically compacts icons together with no gaps. Uses alignment setting to control positioning direction. When disabled, icons stay at their assigned grid positions.",
                order = 36,
                width = 1.0,
                hidden = function() return HideIfNoGroup() or collapsedSections.grid end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.autoReflow
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then 
                        -- When enabling, ensure alignment is saved
                        if val and not g.layout.alignment then
                            local rows = g.layout.gridRows or 1
                            local cols = g.layout.gridCols or 1
                            local gridShape = ns.CDMGroups.DetectGridShape and ns.CDMGroups.DetectGridShape(rows, cols) or "horizontal"
                            local defaultAlignment = ns.CDMGroups.GetDefaultAlignment and ns.CDMGroups.GetDefaultAlignment(gridShape) or "center"
                            g.layout.alignment = defaultAlignment
                            local db = g.getDB and g.getDB()
                            if db then
                                db.alignment = defaultAlignment
                            end
                        end
                        g:SetAutoReflow(val) 
                    end
                end,
            },
            alignmentAnchor = {
                type = "select",
                name = "Alignment",
                desc = "Where icons align within the group when Dynamic Layout is enabled.",
                order = 36.5,
                width = 0.8,
                hidden = function() 
                    local g = GetSelectedGroup()
                    return HideIfNoGroup() or collapsedSections.grid or not (g and g.autoReflow)
                end,
                values = function()
                    local g = GetSelectedGroup()
                    if not g then return {} end
                    
                    local rows = g.layout.gridRows or 1
                    local cols = g.layout.gridCols or 1
                    local gridShape = ns.CDMGroups.DetectGridShape(rows, cols)
                    
                    if gridShape == "horizontal" then
                        return { left = "Left", center = "Center", right = "Right" }
                    elseif gridShape == "vertical" then
                        return { top = "Top", center = "Center", bottom = "Bottom" }
                    else -- multi
                        return { top = "Top", bottom = "Bottom", left = "Left", right = "Right", center_h = "Center Horizontal", center_v = "Center Vertical" }
                    end
                end,
                get = function()
                    local g = GetSelectedGroup()
                    if not g then return "center" end
                    
                    local rows = g.layout.gridRows or 1
                    local cols = g.layout.gridCols or 1
                    local gridShape = ns.CDMGroups.DetectGridShape(rows, cols)
                    
                    local alignment = g.layout.alignment
                    if not alignment then
                        return ns.CDMGroups.GetDefaultAlignment(gridShape)
                    end
                    
                    -- Validate: check if stored value is valid for current shape
                    local validValues
                    if gridShape == "horizontal" then
                        validValues = { left = true, center = true, right = true }
                    elseif gridShape == "vertical" then
                        validValues = { top = true, center = true, bottom = true }
                    else
                        validValues = { top = true, bottom = true, left = true, right = true, center_h = true, center_v = true }
                    end
                    
                    if validValues[alignment] then
                        return alignment
                    end
                    
                    -- Stale value - infer old shape from the alignment value
                    local horizOnly = { left = true, right = true }
                    local vertOnly  = { top = true, bottom = true }
                    local multiOnly = { center_h = true, center_v = true }
                    local oldShape
                    if multiOnly[alignment] then oldShape = "multi"
                    elseif vertOnly[alignment] then oldShape = "vertical"
                    else oldShape = "horizontal"
                    end
                    
                    local mapped = RemapAlignmentForShape(oldShape, gridShape, alignment)
                    local newAlignment = mapped or ns.CDMGroups.GetDefaultAlignment(gridShape)
                    
                    g.layout.alignment = newAlignment
                    local db = g.getDB and g.getDB()
                    if db then db.alignment = newAlignment end
                    
                    return newAlignment
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        g.layout.alignment = val
                        -- Save to DB (flat structure - db.alignment, NOT db.layout.alignment)
                        local db = g.getDB and g.getDB()
                        if db then
                            db.alignment = val
                        end
                        -- Trigger layout to reposition icons with new alignment
                        if g.autoReflow and g.ReflowIcons then 
                            g:ReflowIcons() 
                        elseif g.Layout then 
                            g:Layout() 
                        end
                        -- Trigger auto-save to linked template
                        if ns.CDMGroups.TriggerTemplateAutoSave then
                            ns.CDMGroups.TriggerTemplateAutoSave()
                        end
                    end
                end,
            },
            dynamicLayout = {
                type = "toggle",
                name = "Dynamic Auras",
                desc = "When enabled, aura icons without an active buff/debuff/totem don't occupy space in the group. The remaining icons (cooldowns + active auras) compact together. Only affects aura icons - cooldowns always take space. Requires Dynamic Layout enabled.",
                order = 36.7,
                width = 1.0,
                hidden = function() 
                    local g = GetSelectedGroup()
                    return HideIfNoGroup() or collapsedSections.grid or not (g and g.autoReflow)
                end,
                get = function()
                    local g = GetSelectedGroup()
                    if not g then return false end
                    return g.dynamicLayout == true
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        -- Helper to actually enable/disable Dynamic Auras
                        local function ApplyDynamicAuras(enabled)
                            -- CRITICAL FIX: When enabling Dynamic Auras, ensure alignment is saved
                            if enabled and not g.layout.alignment then
                                local rows = g.layout.gridRows or 1
                                local cols = g.layout.gridCols or 1
                                local gridShape = ns.CDMGroups.DetectGridShape and ns.CDMGroups.DetectGridShape(rows, cols) or "horizontal"
                                local defaultAlignment = ns.CDMGroups.GetDefaultAlignment and ns.CDMGroups.GetDefaultAlignment(gridShape) or "center"
                                g.layout.alignment = defaultAlignment
                                local db = g.getDB and g.getDB()
                                if db then
                                    db.alignment = defaultAlignment
                                end
                            end
                            
                            -- Use DynamicLayout module to set (handles tracking state)
                            if ns.CDMGroups.DynamicLayout and ns.CDMGroups.DynamicLayout.SetEnabled then
                                ns.CDMGroups.DynamicLayout.SetEnabled(g, enabled)
                            else
                                g.dynamicLayout = enabled
                            end
                            -- Save to DB
                            local db = g.getDB and g.getDB()
                            if db then
                                db.dynamicLayout = enabled
                            end
                            
                            -- Trigger auto-save to linked template
                            if ns.CDMGroups.TriggerTemplateAutoSave then
                                ns.CDMGroups.TriggerTemplateAutoSave()
                            end
                            
                            local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
                            if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
                        end
                        
                        if val then
                            -- Enabling: Check if global aura "missing" alpha is > 0
                            local auraCfg = ns.CDMEnhance and ns.CDMEnhance.GetGlobalSettings and ns.CDMEnhance.GetGlobalSettings("aura")
                            local currentAlpha = 1.0
                            if auraCfg and auraCfg.cooldownStateVisuals and auraCfg.cooldownStateVisuals.cooldownState then
                                currentAlpha = auraCfg.cooldownStateVisuals.cooldownState.alpha or 1.0
                            end
                            
                            if currentAlpha > 0 then
                                -- Show confirmation popup
                                StaticPopupDialogs["ARCUI_DYNAMIC_AURAS_ALPHA"] = {
                                    text = "Dynamic Auras works best when inactive aura icons are fully hidden.\n\nSet global |cff00ff00Aura Missing Alpha|r to |cffff80000|r?\n\n(You can change this later in CDM Enhancement > Aura Defaults > Aura Missing)",
                                    button1 = "Yes, Set to 0",
                                    button2 = "No, Keep Current",
                                    OnAccept = function()
                                        -- Set global aura missing alpha to 0
                                        if auraCfg then
                                            if not auraCfg.cooldownStateVisuals then auraCfg.cooldownStateVisuals = {} end
                                            if not auraCfg.cooldownStateVisuals.cooldownState then auraCfg.cooldownStateVisuals.cooldownState = {} end
                                            auraCfg.cooldownStateVisuals.cooldownState.alpha = 0
                                            -- Refresh all aura icons
                                            if ns.CDMEnhance and ns.CDMEnhance.RefreshIconType then
                                                ns.CDMEnhance.RefreshIconType("aura")
                                            end
                                        end
                                        ApplyDynamicAuras(true)
                                    end,
                                    OnCancel = function()
                                        -- Enable Dynamic Auras without changing alpha
                                        ApplyDynamicAuras(true)
                                    end,
                                    timeout = 0, whileDead = true, hideOnEscape = false, preferredIndex = 3,
                                }
                                StaticPopup_Show("ARCUI_DYNAMIC_AURAS_ALPHA")
                            else
                                -- Alpha already 0, just enable
                                ApplyDynamicAuras(true)
                            end
                        else
                            -- Disabling: just turn it off
                            ApplyDynamicAuras(false)
                        end
                    end
                end,
            },
            dynamicCooldowns = {
                type = "toggle",
                name = "Dynamic Cooldowns",
                desc = "Repositions cooldown icons so hidden ones drop out and the rest compact to fill the gap. |cffffd100An icon only drops out when its alpha is 0|r, so open the icon and set its Alpha to 0 under Cooldown Ready State (hides it while ready) or On Cooldown State (hides it while on cooldown). Works alongside Dynamic Auras.",
                order = 36.75,
                width = 1.15,
                hidden = function()
                    local g = GetSelectedGroup()
                    return HideIfNoGroup() or collapsedSections.grid or not (g and g.autoReflow)
                end,
                get = function()
                    local g = GetSelectedGroup()
                    if not g then return false end
                    return g.dynamicCooldowns == true
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g then return end
                    g.dynamicCooldowns = val and true or false
                    -- Persist to the group's DB record (per-spec profile).
                    local db = g.getDB and g.getDB()
                    if db then db.dynamicCooldowns = g.dynamicCooldowns end
                    -- Give the group an explicit alignment when enabling so the
                    -- compaction has a defined anchor (mirrors Dynamic Auras).
                    if g.dynamicCooldowns and g.layout and not g.layout.alignment then
                        local rows = g.layout.gridRows or 1
                        local cols = g.layout.gridCols or 1
                        local gridShape = ns.CDMGroups.DetectGridShape and ns.CDMGroups.DetectGridShape(rows, cols) or "horizontal"
                        local defaultAlignment = ns.CDMGroups.GetDefaultAlignment and ns.CDMGroups.GetDefaultAlignment(gridShape) or "center"
                        g.layout.alignment = defaultAlignment
                        if db then db.alignment = defaultAlignment end
                    end
                    -- Apply immediately if the panel is closed; otherwise the
                    -- panel-close re-layout applies it.
                    local DL = ns.CDMGroups.DynamicLayout
                    local panelOpen = DL and DL.IsOptionsPanelOpen and DL.IsOptionsPanelOpen()
                    if not panelOpen then
                        if g.autoReflow and g.ReflowIcons then
                            g:ReflowIcons()
                        elseif g.Layout then
                            g:Layout()
                        end
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then
                        ns.CDMGroups.TriggerTemplateAutoSave()
                    end
                    local reg = LibStub("AceConfigRegistry-3.0", true)
                    if reg then reg:NotifyChange("ArcUI") end
                end,
            },
            smoothMovement = {
                type = "toggle",
                name = "Smooth Movement",
                desc = "Icons slide smoothly to their new position when the layout shifts, instead of snapping instantly. Applies to both Dynamic Auras and Dynamic Cooldowns.",
                order = 36.76,
                width = 1.15,
                hidden = function()
                    local g = GetSelectedGroup()
                    return HideIfNoGroup() or collapsedSections.grid or not (g and g.autoReflow and (g.dynamicLayout or g.dynamicCooldowns))
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.smoothMovement == true
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g then return end
                    g.smoothMovement = val and true or false
                    local db = g.getDB and g.getDB()
                    if db then db.smoothMovement = g.smoothMovement end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                    local reg = LibStub("AceConfigRegistry-3.0", true)
                    if reg then reg:NotifyChange("ArcUI") end
                end,
            },
            smoothMoveDuration = {
                type = "range",
                name = "Movement Duration",
                desc = "How long the slide takes, in seconds. Lower = snappier, higher = slower glide.",
                order = 36.77,
                width = 1.5,
                min = 0.05, max = 0.40, step = 0.01,
                hidden = function()
                    local g = GetSelectedGroup()
                    return HideIfNoGroup() or collapsedSections.grid or not (g and g.autoReflow and (g.dynamicLayout or g.dynamicCooldowns) and g.smoothMovement)
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and (g.smoothMoveDuration or 0.18) or 0.18
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g then return end
                    g.smoothMoveDuration = val
                    local db = g.getDB and g.getDB()
                    if db then db.smoothMoveDuration = val end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            dynamicOrderMode = {
                type = "select",
                name = "Icon Order",
                desc = "How active icons are ordered when the layout compacts.\n\n|cffffd100Priority|r — icons keep their configured left-to-right order; a higher-priority icon taking its slot can push others over.\n\n|cffffd100First Come, First Served|r — the icon that became active first stays leftmost; new icons append after it and nothing reshuffles.",
                order = 36.78,
                width = 1.75,
                values = {
                    priority = "Priority",
                    fcfs = "First Come, First Served",
                },
                sorting = { "priority", "fcfs" },
                hidden = function()
                    local g = GetSelectedGroup()
                    return HideIfNoGroup() or collapsedSections.grid or not (g and g.autoReflow and (g.dynamicLayout or g.dynamicCooldowns))
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return (g and g.dynamicOrderMode) or "priority"
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g then return end
                    g.dynamicOrderMode = val
                    local db = g.getDB and g.getDB()
                    if db then db.dynamicOrderMode = val end
                    -- Reset the runtime activation order so the new mode starts clean.
                    g._fcfsOrder = nil
                    local DL = ns.CDMGroups.DynamicLayout
                    local panelOpen = DL and DL.IsOptionsPanelOpen and DL.IsOptionsPanelOpen()
                    if not panelOpen then
                        if g.autoReflow and g.ReflowIcons then
                            g:ReflowIcons()
                        elseif g.Layout then
                            g:Layout()
                        end
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                    local reg = LibStub("AceConfigRegistry-3.0", true)
                    if reg then reg:NotifyChange("ArcUI") end
                end,
            },
            dynamicContainerSize = {
                type = "toggle",
                name = "Dynamic Container",
                desc = "When enabled, the group container shrinks to fit only the visible icons. When disabled, container stays at full grid size. Only applies when Dynamic Layout is enabled and options panel is closed.",
                order = 36.8,
                width = 1.15,
                hidden = function() 
                    local g = GetSelectedGroup()
                    return HideIfNoGroup() or collapsedSections.grid or not (g and g.autoReflow)
                end,
                get = function()
                    local g = GetSelectedGroup()
                    if not g then return false end
                    return g.dynamicContainerSize or false
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        g.dynamicContainerSize = val
                        local db = g.getDB and g.getDB()
                        if db then
                            db.dynamicContainerSize = val
                        end
                        -- Trigger layout refresh
                        g:Layout()
                        -- Trigger auto-save to linked template
                        if ns.CDMGroups.TriggerTemplateAutoSave then
                            ns.CDMGroups.TriggerTemplateAutoSave()
                        end
                    end
                end,
            },
            
            -- LAYOUT SETTINGS SECTION
            layoutHeader = {
                type = "toggle",
                name = "Layout Settings",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 40,
                width = "full",
                get = function() return not collapsedSections.layout end,
                set = function(_, v) collapsedSections.layout = not v end,
            },
            fineTuningLayout = {
                type = "toggle",
                name = "Fine Tuning",
                desc = "Switch to direct input boxes for pixel-precise width, height, and spacing values.",
                order = 40.5,
                width = 0.75,
                hidden = function() return HideIfNoGroup() or collapsedSections.layout end,
                get = function()
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    return db and db.fineTuningLayout
                end,
                set = function(_, val)
                    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
                    if db then db.fineTuningLayout = val end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            iconSize = {
                type = "range",
                name = "Scale",
                desc = "Scale factor for icons (36 = 100%)",
                order = 41,
                min = 16, max = 128, step = 1,
                width = 0.7,
                hidden = function() return HideIfNoGroup() or collapsedSections.layout or IsFineTuning() end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.layout.iconSize or 36
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then g:SetIconSize(val) end
                end,
            },
            iconSizeInput = {
                type = "input",
                dialogControl = "ArcUI_EditBox",
                name = "Scale",
                desc = "Scale factor for icons (type exact value)",
                order = 41,
                width = 0.4,
                hidden = function() return HideIfNoGroup() or collapsedSections.layout or not IsFineTuning() end,
                get = function()
                    local g = GetSelectedGroup()
                    return tostring(g and g.layout.iconSize or 36)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    local num = tonumber(val)
                    if g and num then g:SetIconSize(num) end
                end,
            },
            iconWidth = {
                type = "range",
                name = "Width",
                desc = "Base icon width in pixels (before scaling)",
                order = 41.1,
                min = 8, max = 128, step = 1,
                width = 0.55,
                hidden = function() return HideIfNoGroup() or collapsedSections.layout or IsFineTuning() end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.layout.iconWidth or 36
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then g:SetIconWidth(val) end
                end,
            },
            iconWidthInput = {
                type = "input",
                dialogControl = "ArcUI_EditBox",
                name = "Width",
                desc = "Base icon width in pixels (type exact value)",
                order = 41.1,
                width = 0.4,
                hidden = function() return HideIfNoGroup() or collapsedSections.layout or not IsFineTuning() end,
                get = function()
                    local g = GetSelectedGroup()
                    return tostring(g and g.layout.iconWidth or 36)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    local num = tonumber(val)
                    if g and num then g:SetIconWidth(num) end
                end,
            },
            iconHeight = {
                type = "range",
                name = "Height",
                desc = "Base icon height in pixels (before scaling)",
                order = 41.2,
                min = 8, max = 128, step = 1,
                width = 0.55,
                hidden = function() return HideIfNoGroup() or collapsedSections.layout or IsFineTuning() end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.layout.iconHeight or 36
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then g:SetIconHeight(val) end
                end,
            },
            iconHeightInput = {
                type = "input",
                dialogControl = "ArcUI_EditBox",
                name = "Height",
                desc = "Base icon height in pixels (type exact value)",
                order = 41.2,
                width = 0.4,
                hidden = function() return HideIfNoGroup() or collapsedSections.layout or not IsFineTuning() end,
                get = function()
                    local g = GetSelectedGroup()
                    return tostring(g and g.layout.iconHeight or 36)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    local num = tonumber(val)
                    if g and num then g:SetIconHeight(num) end
                end,
            },
            spacing = {
                type = "range",
                name = "Spacing",
                desc = "Space between icons (both X and Y)",
                order = 42,
                min = -20, max = 50, step = 0.5,
                width = 0.8,
                hidden = function() 
                    if HideIfNoGroup() or collapsedSections.layout or IsFineTuning() then return true end
                    local g = GetSelectedGroup()
                    return g and g.layout.separateSpacing
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.layout.spacing or 2
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then g:SetSpacing(val) end
                end,
            },
            spacingInput = {
                type = "input",
                dialogControl = "ArcUI_EditBox",
                name = "Spacing",
                desc = "Space between icons (type exact value)",
                order = 42,
                width = 0.4,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.layout or not IsFineTuning() then return true end
                    local g = GetSelectedGroup()
                    return g and g.layout.separateSpacing
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return tostring(g and g.layout.spacing or 2)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    local num = tonumber(val)
                    if g and num then g:SetSpacing(num) end
                end,
            },
            separateSpacing = {
                type = "toggle",
                name = "X/Y",
                desc = "Enable separate X and Y spacing controls",
                order = 42.1,
                width = 0.35,
                hidden = function() return HideIfNoGroup() or collapsedSections.layout end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.layout.separateSpacing
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        g.layout.separateSpacing = val
                        -- Save to profile.groupLayouts (single source of truth)
                        if ns.CDMGroups.SaveGroupLayoutToProfile then
                            ns.CDMGroups.SaveGroupLayoutToProfile(g.name, g)
                        end
                        -- If enabling, initialize X/Y from current spacing
                        if val and not g.layout.spacingX then
                            g:SetSpacingX(g.layout.spacing or 2)
                            g:SetSpacingY(g.layout.spacing or 2)
                        end
                    end
                end,
            },
            spacingX = {
                type = "range",
                name = "X Spacing",
                desc = "Horizontal space between columns",
                order = 42.5,
                min = -20, max = 50, step = 0.5,
                width = 0.7,
                hidden = function() 
                    if HideIfNoGroup() or collapsedSections.layout or IsFineTuning() then return true end
                    local g = GetSelectedGroup()
                    return not (g and g.layout.separateSpacing)
                end,
                get = function()
                    local g = GetSelectedGroup()
                    if g and g.layout.spacingX then
                        return g.layout.spacingX
                    end
                    return g and g.layout.spacing or 2
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then g:SetSpacingX(val) end
                end,
            },
            spacingXInput = {
                type = "input",
                dialogControl = "ArcUI_EditBox",
                name = "X Spacing",
                desc = "Horizontal space between columns (type exact value)",
                order = 42.5,
                width = 0.4,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.layout or not IsFineTuning() then return true end
                    local g = GetSelectedGroup()
                    return not (g and g.layout.separateSpacing)
                end,
                get = function()
                    local g = GetSelectedGroup()
                    if g and g.layout.spacingX then
                        return tostring(g.layout.spacingX)
                    end
                    return tostring(g and g.layout.spacing or 2)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    local num = tonumber(val)
                    if g and num then g:SetSpacingX(num) end
                end,
            },
            spacingY = {
                type = "range",
                name = "Y Spacing",
                desc = "Vertical space between rows",
                order = 42.6,
                min = -20, max = 50, step = 0.5,
                width = 0.7,
                hidden = function() 
                    if HideIfNoGroup() or collapsedSections.layout or IsFineTuning() then return true end
                    local g = GetSelectedGroup()
                    return not (g and g.layout.separateSpacing)
                end,
                get = function()
                    local g = GetSelectedGroup()
                    if g and g.layout.spacingY then
                        return g.layout.spacingY
                    end
                    return g and g.layout.spacing or 2
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then g:SetSpacingY(val) end
                end,
            },
            spacingYInput = {
                type = "input",
                dialogControl = "ArcUI_EditBox",
                name = "Y Spacing",
                desc = "Vertical space between rows (type exact value)",
                order = 42.6,
                width = 0.4,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.layout or not IsFineTuning() then return true end
                    local g = GetSelectedGroup()
                    return not (g and g.layout.separateSpacing)
                end,
                get = function()
                    local g = GetSelectedGroup()
                    if g and g.layout.spacingY then
                        return tostring(g.layout.spacingY)
                    end
                    return tostring(g and g.layout.spacing or 2)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    local num = tonumber(val)
                    if g and num then g:SetSpacingY(num) end
                end,
            },
            
            -- FRAME STRATA SECTION
            frameStrataHeader = {
                type = "toggle",
                name = "Frame Strata",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 45,
                width = "full",
                get = function() return not collapsedSections.frameStrata end,
                set = function(_, v) collapsedSections.frameStrata = not v end,
            },
            frameStrata = {
                type = "select",
                name = "Strata",
                desc = "Rendering layer. Higher strata = on top.",
                order = 45.1,
                width = 0.8,
                hidden = function() return HideIfNoGroup() or collapsedSections.frameStrata end,
                values = {
                    BACKGROUND = "Background",
                    LOW = "Low",
                    MEDIUM = "Medium (Default)",
                    HIGH = "High",
                    DIALOG = "Dialog",
                },
                sorting = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG" },
                get = function()
                    local g = GetSelectedGroup()
                    return g and (g.frameStrata or "MEDIUM") or "MEDIUM"
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g and g.SetGroupFrameStrata then
                        g:SetGroupFrameStrata(val)
                    end
                end,
            },
            frameLevel = {
                type = "input",
                name = "Level",
                desc = "Z-order within the same strata. Higher = on top.",
                dialogControl = "ArcUI_EditBox",
                order = 45.2,
                width = 0.5,
                hidden = function() return HideIfNoGroup() or collapsedSections.frameStrata end,
                get = function()
                    local g = GetSelectedGroup()
                    return tostring(g and (g.frameLevel or 1) or 1)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    local num = tonumber(val)
                    if g and num and g.SetGroupFrameLevel then
                        num = math.max(1, math.floor(num))
                        g:SetGroupFrameLevel(num)
                    end
                end,
            },
            
            -- ═══════════════════════════════════════════════════════════════
            -- ANCHORING SETTINGS SECTION
            -- ═══════════════════════════════════════════════════════════════
            anchoringHeader = {
                type = "toggle",
                name = "Anchoring",
                desc = "Click to expand/collapse. Anchor this group to other groups or frames.",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 47,
                width = "full",
                get = function() return not collapsedSections.anchoring end,
                set = function(_, v) collapsedSections.anchoring = not v end,
            },
            anchorEnabled = {
                type = "toggle",
                name = "Enable Anchoring",
                desc = "When enabled, this group's position is controlled by the anchor target instead of manual X/Y.",
                order = 47.1,
                width = 1.0,
                hidden = function() return HideIfNoGroup() or collapsedSections.anchoring end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.anchor and g.anchor.enabled or false
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g then return end
                    if not g.anchor then
                        g.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.GetDefaults() or { enabled = false, mode = "none" }
                    end
                    g.anchor.enabled = val
                    -- Save to profile
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    -- Apply or revert
                    if val and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    else
                        -- Detach any external frames anchored to this group (e.g. PlayerFrame)
                        if ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.DetachAllExternalFrames then
                            ns.CDMGroupsAnchors.DetachAllExternalFrames(g)
                        end
                        -- Revert group to stored position
                        if g.container and g.position then
                            g.container:ClearAllPoints()
                            g.container:SetPoint("CENTER", UIParent, "CENTER", g.position.x, g.position.y)
                            if ns.CDMGroups.SyncAnchorProxy then ns.CDMGroups.SyncAnchorProxy(g) end
                        end
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            anchorMode = {
                type = "select",
                name = "Group Position",
                desc = "Where this group is positioned:\n" ..
                       "|cff88ffffNone|r: Group stays where you drag it.\n" ..
                       "|cff88ffffGroup > Group|r: Attach this group to another ArcUI group.\n" ..
                       "|cff88ffffGroup > Frame|r: Attach this group to any named UI frame.\n\n" ..
                       "External frames can be attached to this group separately below.",
                order = 47.2,
                width = 1.1,
                hidden = function() return HideIfNoGroup() or collapsedSections.anchoring end,
                values = {
                    ["none"]         = "None",
                    ["toGroup"]      = "Group > Group",
                    ["toFrame"]      = "Group > Frame",
                    ["toMouse"]      = "Follow Cursor",
                },
                sorting = { "none", "toGroup", "toFrame", "toMouse" },
                get = function()
                    local g = GetSelectedGroup()
                    local mode = g and g.anchor and g.anchor.mode or "none"
                    -- Backward compat: old frameToGroup is now just "none" (anchoredFrames are independent)
                    if mode == "frameToGroup" then mode = "none" end
                    return mode
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    local oldMode = g.anchor.mode
                    g.anchor.mode = val
                    -- Clear fields from previous mode to avoid cross-contamination
                    if val ~= oldMode then
                        if val == "toGroup" then
                            g.anchor.targetFrame = ""
                        elseif val == "toFrame" then
                            g.anchor.targetGroup = ""
                        elseif val == "none" then
                            g.anchor.targetGroup = ""
                            g.anchor.targetFrame = ""
                        elseif val == "toMouse" then
                            g.anchor.targetGroup = ""
                            g.anchor.targetFrame = ""
                        end
                    end
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if val == "none" then
                        -- Revert group to stored drag position
                        if g.container and g.position then
                            g.container:ClearAllPoints()
                            g.container:SetPoint("CENTER", UIParent, "CENTER", g.position.x, g.position.y)
                            if ns.CDMGroups.SyncAnchorProxy then ns.CDMGroups.SyncAnchorProxy(g) end
                        end
                    end
                    -- Only apply if enabled (ApplyGroupAnchor already checks for valid targets)
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            anchorTargetGroup = {
                type = "select",
                name = "Target Group",
                desc = "Which ArcUI group to anchor to.",
                order = 47.3,
                width = 1.0,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor or g.anchor.mode ~= "toGroup"
                end,
                values = function()
                    local g = GetSelectedGroup()
                    local exclude = g and g.name or ""
                    return ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.GetAvailableGroups(exclude) or {}
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.anchor and g.anchor.targetGroup or ""
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    g.anchor.targetGroup = val
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            anchorTargetFrame = {
                type = "input",
                name = "Target Frame Name",
                desc = "The global name of the UI frame. Type a name or use the preset/picker below.",
                dialogControl = "ArcUI_EditBox",
                order = 47.4,
                width = 1.0,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor or g.anchor.mode ~= "toFrame"
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.anchor and g.anchor.targetFrame or ""
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    g.anchor.targetFrame = val
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            anchorTargetPreset = {
                type = "select",
                name = "Common Frames",
                desc = "Quick-select a well-known UI frame.",
                order = 47.41,
                width = 1.1,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor or g.anchor.mode ~= "toFrame"
                end,
                values = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.COMMON_FRAMES or {},
                sorting = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.COMMON_FRAMES_SORTED or {},
                get = function() return "" end,
                set = function(_, val)
                    if val == "" then return end
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    g.anchor.targetFrame = val
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                    local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
                    if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
                end,
            },
            anchorTargetPick = {
                type = "execute",
                name = "Pick Frame",
                desc = "Mouse over any frame on screen and click to select it.",
                order = 47.42,
                width = 0.6,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor or g.anchor.mode ~= "toFrame"
                end,
                func = function()
                    if not ns.CDMGroupsAnchors or not ns.CDMGroupsAnchors.StartPicker then return end
                    ns.CDMGroupsAnchors.StartPicker(function(name)
                        local g = GetSelectedGroup()
                        if not g or not g.anchor then return end
                        g.anchor.targetFrame = name
                        local db = g.getDB and g.getDB()
                        if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                        if g.anchor.enabled and ns.CDMGroupsAnchors then
                            ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                        end
                        if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                        local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
                        if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
                    end)
                end,
            },
            anchorPosition = {
                type = "select",
                name = "Position",
                desc = "Where to position relative to the target. Pick 'Advanced' for full control over anchor points.",
                order = 47.45,
                width = 0.8,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor or g.anchor.mode == "none"
                end,
                values = {
                    below  = "Below",
                    above  = "Above",
                    left   = "Left",
                    right  = "Right",
                    center = "Center",
                    advanced = "|cffaaaaaa Advanced|r",
                },
                sorting = { "below", "above", "left", "right", "center", "advanced" },
                get = function()
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return "below" end
                    local src = g.anchor.sourcePoint or "TOP"
                    local dst = g.anchor.destPoint or "BOTTOM"
                    if src == "TOP" and dst == "BOTTOM" then return "below"
                    elseif src == "BOTTOM" and dst == "TOP" then return "above"
                    elseif src == "RIGHT" and dst == "LEFT" then return "left"
                    elseif src == "LEFT" and dst == "RIGHT" then return "right"
                    elseif src == "CENTER" and dst == "CENTER" then return "center"
                    else return "advanced" end
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    local presets = {
                        below  = { "TOP", "BOTTOM" },
                        above  = { "BOTTOM", "TOP" },
                        left   = { "RIGHT", "LEFT" },
                        right  = { "LEFT", "RIGHT" },
                        center = { "CENTER", "CENTER" },
                    }
                    if presets[val] then
                        g.anchor.sourcePoint = presets[val][1]
                        g.anchor.destPoint = presets[val][2]
                        local db = g.getDB and g.getDB()
                        if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                        if g.anchor.enabled and ns.CDMGroupsAnchors then
                            ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                        end
                        if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                    end
                    -- "advanced" reveals the raw dropdowns via _advancedMode flag
                    if val == "advanced" then
                        g.anchor._advancedMode = true
                    else
                        g.anchor._advancedMode = nil
                    end
                end,
            },
            anchorSourcePoint = {
                type = "select",
                name = "Source Point",
                desc = "The point on the source (the thing being moved) that attaches.",
                order = 47.5,
                width = 0.7,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    if not g or not g.anchor or g.anchor.mode == "none" then return true end
                    if g.anchor._advancedMode then return false end
                    -- Only show in advanced mode
                    local src = g.anchor.sourcePoint or "TOP"
                    local dst = g.anchor.destPoint or "BOTTOM"
                    if (src == "TOP" and dst == "BOTTOM") or (src == "BOTTOM" and dst == "TOP")
                        or (src == "RIGHT" and dst == "LEFT") or (src == "LEFT" and dst == "RIGHT")
                        or (src == "CENTER" and dst == "CENTER") then return true end
                    return false
                end,
                values = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.ANCHOR_POINTS or {},
                sorting = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.ANCHOR_POINTS_SORTED or {},
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.anchor and g.anchor.sourcePoint or "TOP"
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    g.anchor.sourcePoint = val
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            anchorDestPoint = {
                type = "select",
                name = "Dest Point",
                desc = "The point on the target (the thing being anchored to) that we attach to.",
                order = 47.6,
                width = 0.7,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    if not g or not g.anchor or g.anchor.mode == "none" then return true end
                    if g.anchor._advancedMode then return false end
                    -- Only show in advanced mode
                    local src = g.anchor.sourcePoint or "TOP"
                    local dst = g.anchor.destPoint or "BOTTOM"
                    if (src == "TOP" and dst == "BOTTOM") or (src == "BOTTOM" and dst == "TOP")
                        or (src == "RIGHT" and dst == "LEFT") or (src == "LEFT" and dst == "RIGHT")
                        or (src == "CENTER" and dst == "CENTER") then return true end
                    return false
                end,
                values = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.ANCHOR_POINTS or {},
                sorting = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.ANCHOR_POINTS_SORTED or {},
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.anchor and g.anchor.destPoint or "BOTTOM"
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    g.anchor.destPoint = val
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            anchorOffsetX = {
                type = "input",
                name = "X Offset",
                desc = "Horizontal offset from the anchor point.",
                dialogControl = "ArcUI_EditBox",
                order = 47.7,
                width = 0.5,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor or g.anchor.mode == "none"
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return tostring(g and g.anchor and g.anchor.offsetX or 0)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    local num = tonumber(val) or 0
                    g.anchor.offsetX = num
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            anchorOffsetY = {
                type = "input",
                name = "Y Offset",
                desc = "Vertical offset from the anchor point.",
                dialogControl = "ArcUI_EditBox",
                order = 47.8,
                width = 0.5,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor or g.anchor.mode == "none"
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return tostring(g and g.anchor and g.anchor.offsetY or 0)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    local num = tonumber(val) or 0
                    g.anchor.offsetY = num
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            anchorSafeMode = {
                type = "toggle",
                name = "Safe Anchoring",
                desc = "Use screen-coordinate positioning to break the taint chain. " ..
                       "Required for anchoring to/from Blizzard protected frames. " ..
                       "Disable only if anchoring between addon frames that don't taint.",
                order = 47.85,
                width = 1.0,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return true end
                    return g.anchor.mode ~= "toFrame" and g.anchor.mode ~= "toGroup"
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.anchor and g.anchor.useSafeAnchor ~= false
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    g.anchor.useSafeAnchor = val
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            anchorTrackTarget = {
                type = "toggle",
                name = "Track Target",
                desc = "When the target frame moves (e.g. ElvUI repositions it), " ..
                       "automatically re-anchor this group to follow it. " ..
                       "Without this, the group only anchors once on login/apply.",
                order = 47.86,
                width = 1.0,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor or g.anchor.mode ~= "toFrame"
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.anchor and g.anchor.trackTarget or false
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    g.anchor.trackTarget = val
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if g.anchor.enabled and ns.CDMGroupsAnchors then
                        ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
                    end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                end,
            },
            -- ═══════════════════════════════════════════════════════════════
            -- FRAME > GROUP: Multi-frame anchored list
            -- ═══════════════════════════════════════════════════════════════
            anchoredFramesDesc = {
                type = "description",
                name = "|cffffd100Anchored Frames|r — External frames positioned relative to this group.",
                fontSize = "medium",
                order = 48.0,
                width = "full",
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor
                end,
            },
            anchoredFramesHelp = {
                type = "description",
                name = "|cffaaaaaa" ..
                    "Attach UI frames (like your player frame) to this group so they move together.\n\n" ..
                    "|cffffd100Safe|r — Positions the frame without creating a direct link that can cause UI errors. Recommended.\n" ..
                    "|cffffd100Snap|r — Forces the frame back if something else tries to move it (e.g. Blizzard resets, edit mode).\n\n" ..
                    "|cffff4444Note:|r Snap may fight with other addons that also position the same frame.",
                order = 48.005,
                width = "full",
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor
                end,
            },
            anchoredFramesAdd = {
                type = "execute",
                name = "+ Add Frame",
                desc = "Add a new external frame entry.",
                order = 48.01,
                width = 0.6,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.anchoring then return true end
                    local g = GetSelectedGroup()
                    return not g or not g.anchor
                end,
                func = function()
                    local g = GetSelectedGroup()
                    if not g or not g.anchor then return end
                    if not g.anchor.anchoredFrames then g.anchor.anchoredFrames = {} end
                    local entry = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.GetFrameEntryDefaults() or {
                        frameName = "", sourcePoint = "BOTTOM", destPoint = "TOP",
                        offsetX = 0, offsetY = 0, useSafeAnchor = true, snapBack = false,
                    }
                    table.insert(g.anchor.anchoredFrames, entry)
                    local db = g.getDB and g.getDB()
                    if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
                    if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
                    local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
                    if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
                end,
            },
            
            -- POSITION SETTINGS SECTION
            positionHeader = {
                type = "toggle",
                name = "Position",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 50,
                width = "full",
                get = function() return not collapsedSections.position end,
                set = function(_, v) collapsedSections.position = not v end,
            },
            posX = {
                type = "input",
                name = "X Offset",
                desc = "Horizontal position from screen center",
                dialogControl = "ArcUI_EditBox",
                order = 51,
                width = 0.6,
                hidden = function() return HideIfNoGroup() or collapsedSections.position end,
                get = function()
                    local g = GetSelectedGroup()
                    if not g then return "0" end
                    -- If anchored, show the actual current position (not stale saved pos)
                    if ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.IsGroupAnchored(g) and g.container then
                        local uW = UIParent:GetSize()
                        local l = g.container:GetLeft()
                        local w = g.container:GetWidth()
                        if l then return tostring(math.floor((l + w * 0.5 - uW * 0.5) + 0.5)) end
                    end
                    return tostring(g.position.x)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then 
                        local num = tonumber(val)
                        if num then
                            g:SetPosition(num, g.position.y) 
                        end
                    end
                end,
            },
            posY = {
                type = "input",
                name = "Y Offset",
                desc = "Vertical position from screen center",
                dialogControl = "ArcUI_EditBox",
                order = 52,
                width = 0.6,
                hidden = function() return HideIfNoGroup() or collapsedSections.position end,
                get = function()
                    local g = GetSelectedGroup()
                    if not g then return "0" end
                    if ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.IsGroupAnchored(g) and g.container then
                        local _, uH = UIParent:GetSize()
                        local b = g.container:GetBottom()
                        local h = g.container:GetHeight()
                        if b then return tostring(math.floor((b + h * 0.5 - uH * 0.5) + 0.5)) end
                    end
                    return tostring(g.position.y)
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then 
                        local num = tonumber(val)
                        if num then
                            g:SetPosition(g.position.x, num) 
                        end
                    end
                end,
            },
            dragToggleAnchor = {
                type = "select",
                name = "Drag Handle",
                desc = "Position of the drag handle button relative to the group",
                order = 53,
                width = 0.9,
                hidden = function() return HideIfNoGroup() or collapsedSections.position end,
                values = {
                    ["TOPLEFT"] = "Top Left",
                    ["TOPRIGHT"] = "Top Right",
                    ["BOTTOMLEFT"] = "Bottom Left",
                    ["BOTTOMRIGHT"] = "Bottom Right",
                },
                get = function()
                    local g = GetSelectedGroup()
                    if g then
                        local db = ns.CDMGroups.GetGroupDB and ns.CDMGroups.GetGroupDB(g.name)
                        return db and db.dragToggleAnchor or "TOPLEFT"
                    end
                    return "TOPLEFT"
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        local db = ns.CDMGroups.GetGroupDB and ns.CDMGroups.GetGroupDB(g.name)
                        if db then db.dragToggleAnchor = val end
                        -- Update the drag toggle position
                        if g.UpdateDragToggleAnchor then
                            g:UpdateDragToggleAnchor(val)
                        end
                    end
                end,
            },
            
            -- APPEARANCE SETTINGS SECTION
            appearanceHeader = {
                type = "toggle",
                name = "Appearance",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 60,
                width = "full",
                get = function() return not collapsedSections.appearance end,
                set = function(_, v) collapsedSections.appearance = not v end,
            },
            showBorder = {
                type = "toggle",
                name = "Border",
                desc = "Show container border (always visible in edit mode)",
                order = 61,
                width = 0.5,
                hidden = function() return HideIfNoGroup() or collapsedSections.appearance end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.showBorder
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then g:SetShowBorder(val) end
                end,
            },
            showBackground = {
                type = "toggle",
                name = "Background",
                desc = "Show container background (always visible in edit mode)",
                order = 62,
                width = 0.7,
                hidden = function() return HideIfNoGroup() or collapsedSections.appearance end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.showBackground
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then g:SetShowBackground(val) end
                end,
            },
            borderColor = {
                type = "color",
                name = "Border Color",
                desc = "Color of the container border and title",
                order = 63,
                hasAlpha = true,
                width = 0.85,
                hidden = function() return HideIfNoGroup() or collapsedSections.appearance end,
                get = function()
                    local g = GetSelectedGroup()
                    if g and g.borderColor then
                        return g.borderColor.r, g.borderColor.g, g.borderColor.b, g.borderColor.a or 1
                    end
                    return 0.5, 0.5, 0.5, 1
                end,
                set = function(_, r, g, b, a)
                    local grp = GetSelectedGroup()
                    if grp then grp:SetBorderColor(r, g, b, a) end
                end,
            },
            bgColor = {
                type = "color",
                name = "BG Color",
                desc = "Color of the container background",
                order = 64,
                hasAlpha = true,
                width = 0.6,
                hidden = function() return HideIfNoGroup() or collapsedSections.appearance end,
                get = function()
                    local g = GetSelectedGroup()
                    if g and g.bgColor then
                        return g.bgColor.r, g.bgColor.g, g.bgColor.b, g.bgColor.a or 0.6
                    end
                    return 0, 0, 0, 0.6
                end,
                set = function(_, r, g, b, a)
                    local grp = GetSelectedGroup()
                    if grp then grp:SetBgColor(r, g, b, a) end
                end,
            },
            visibilityLogic = {
                type = "select",
                name = "Condition Match Mode",
                desc = "Controls how multiple hide conditions combine:\n\n"
                    .. "|cff00ff00Match Any|r (default): Group hides if ANY checked condition is true.\n"
                    .. "Example: 'Out of Combat' + 'Not Casting' = show ONLY when in combat AND casting.\n\n"
                    .. "|cff00ff00Match All|r: Group hides only when ALL checked conditions are true simultaneously.\n"
                    .. "Example: 'Out of Combat' + 'Not Casting' = show when in combat OR casting.",
                order = 64,
                width = 1.5,
                hidden = function() return HideIfNoGroup() or collapsedSections.appearance end,
                values = {
                    ["any"] = "Match Any (hide if any condition met)",
                    ["all"] = "Match All (hide only if all conditions met)",
                },
                sorting = { "any", "all" },
                get = function()
                    local g = GetSelectedGroup()
                    if not g then return "any" end
                    return g.visibilityLogic or "any"
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        g.visibilityLogic = val
                        -- Save to profile
                        if ns.CDMGroups.SaveGroupLayoutToProfile then
                            ns.CDMGroups.SaveGroupLayoutToProfile(g.name, g)
                        end
                        -- Invalidate cached state so update re-applies
                        g._arcLastVisState = nil
                        g._arcHasVisConditions = nil
                        -- Update visibility immediately
                        if ns.CDMGroups.UpdateGroupVisibility then
                            ns.CDMGroups.UpdateGroupVisibility()
                        end
                        -- Trigger auto-save to linked template
                        if ns.CDMGroups.TriggerTemplateAutoSave then
                            ns.CDMGroups.TriggerTemplateAutoSave()
                        end
                    end
                end,
            },
            visibility = {
                type = "multiselect",
                name = "Hide When...",
                desc = "Select conditions that will HIDE this group.\nIf none selected, group is always visible.\nBehavior depends on Condition Match Mode above.\nNote: Groups are always shown when editing or options panel is open.",
                order = 65,
                width = 1.5,
                hidden = function() return HideIfNoGroup() or collapsedSections.appearance end,
                values = function()
                    local v = {
                        ["hideOOC"] = "Out of Combat",
                        ["hideInCombat"] = "In Combat",
                        ["hideMounted"] = "Mounted",
                        ["hideInVehicle"] = "In Vehicle / Taxi",
                        ["hideDead"] = "Dead / Ghost",
                        ["hideResting"] = "Resting (City/Inn)",
                        ["hideSolo"] = "Solo (Not in Group)",
                        ["hideInGroup"] = "In Group",
                        ["hideInRaid"] = "In Raid",
                        ["hideInInstance"] = "In Instance",
                        ["hideInEncounter"] = "Boss Encounter",
                        ["hideInPetBattle"] = "In Pet Battle",
                        ["hidePvP"] = "PvP Flagged",
                        ["hideDragonriding"] = "Skyriding",
                        ["hideNoTarget"] = "No Target",
                        ["hideHasTarget"] = "Has Target",
                        ["hideNotCasting"] = "Not Casting",
                        ["hideCasting"] = "While Casting",
                        ["hideStealthed"] = "Stealthed",
                        ["hideFlying"] = "Flying",
                        ["hideSwimming"] = "Swimming",
                        ["hideAlways"] = "Always (Disabled)",
                    }
                    -- Druid form entries (only show for Druid players)
                    local _, playerClass = UnitClass("player")
                    if playerClass == "DRUID" then
                        v["hideInCasterForm"]  = "|cff69CCF0Form:|r Caster / No Form"
                        v["hideInCatForm"]     = "|cff69CCF0Form:|r Cat"
                        v["hideInBearForm"]    = "|cff69CCF0Form:|r Bear"
                        v["hideInMoonkinForm"] = "|cff69CCF0Form:|r Moonkin"
                        v["hideInTravelForm"]  = "|cff69CCF0Form:|r Travel / Flight"
                        v["hideInTreeForm"]    = "|cff69CCF0Form:|r Tree of Life"
                    end
                    -- Warrior stance entries
                    if playerClass == "WARRIOR" then
                        v["hideInBattleStance"]    = "|cffC79C6EStance:|r Battle Stance"
                        v["hideInDefensiveStance"] = "|cffC79C6EStance:|r Defensive Stance"
                        v["hideInNoStance"]        = "|cffC79C6EStance:|r No Stance"
                    end
                    -- Priest form entries
                    if playerClass == "PRIEST" then
                        v["hideInShadowform"] = "|cff69CCF0Form:|r Shadowform"
                        v["hideInNoStance"]   = "|cff69CCF0Form:|r No Shadowform"
                    end
                    return v
                end,
                get = function(_, key)
                    local g = GetSelectedGroup()
                    if not g then return false end
                    
                    -- Handle backwards compatibility with old string format
                    local vis = g.visibility
                    if type(vis) == "string" then
                        -- Convert old format to new for display purposes
                        if vis == "combat" then
                            return key == "hideOOC"  -- "In Combat Only" = hide when OOC
                        elseif vis == "ooc" then
                            return key == "hideInCombat"  -- "Out of Combat Only" = hide when in combat
                        elseif vis == "never" then
                            return key == "hideAlways"
                        else
                            return false  -- "always" = nothing selected
                        end
                    elseif type(vis) == "table" then
                        return vis[key] or false
                    end
                    return false
                end,
                set = function(_, key, val)
                    local g = GetSelectedGroup()
                    if g then
                        -- Convert to table format if still using old string
                        if type(g.visibility) ~= "table" then
                            local oldVis = g.visibility
                            g.visibility = {}
                            -- Migrate old value
                            if oldVis == "combat" then
                                g.visibility.hideOOC = true
                            elseif oldVis == "ooc" then
                                g.visibility.hideInCombat = true
                            elseif oldVis == "never" then
                                g.visibility.hideAlways = true
                            end
                        end
                        
                        -- Set the new value
                        g.visibility[key] = val or nil  -- Use nil instead of false to keep table clean
                        
                        -- If hideAlways is set, clear other options (they're redundant)
                        if key == "hideAlways" and val then
                            g.visibility.hideOOC = nil
                            g.visibility.hideInCombat = nil
                            g.visibility.hideMounted = nil
                            g.visibility.hideInVehicle = nil
                            g.visibility.hideInPetBattle = nil
                            g.visibility.hideDead = nil
                            g.visibility.hideSolo = nil
                            g.visibility.hideInGroup = nil
                            g.visibility.hideInRaid = nil
                            g.visibility.hideInInstance = nil
                            g.visibility.hideResting = nil
                            g.visibility.hideInEncounter = nil
                            g.visibility.hidePvP = nil
                            g.visibility.hideDragonriding = nil
                            g.visibility.hideNoTarget = nil
                            g.visibility.hideHasTarget = nil
                            g.visibility.hideNotCasting = nil
                            g.visibility.hideCasting = nil
                            g.visibility.hideStealthed = nil
                            g.visibility.hideFlying = nil
                            g.visibility.hideSwimming = nil
                            g.visibility.hideInCatForm = nil
                            g.visibility.hideInBearForm = nil
                            g.visibility.hideInMoonkinForm = nil
                            g.visibility.hideInTravelForm = nil
                            g.visibility.hideInTreeForm = nil
                            g.visibility.hideInCasterForm = nil
                            g.visibility.hideInBattleStance = nil
                            g.visibility.hideInDefensiveStance = nil
                            g.visibility.hideInShadowform = nil
                            g.visibility.hideInNoStance = nil
                        elseif val and g.visibility.hideAlways then
                            -- If setting another option, clear hideAlways
                            g.visibility.hideAlways = nil
                        end
                        
                        -- Save to profile.groupLayouts (single source of truth)
                        if ns.CDMGroups.SaveGroupLayoutToProfile then
                            ns.CDMGroups.SaveGroupLayoutToProfile(g.name, g)
                        end
                        -- Invalidate cached state so update re-applies
                        g._arcLastVisState = nil
                        g._arcHasVisConditions = nil
                        -- Update visibility immediately
                        if ns.CDMGroups.UpdateGroupVisibility then
                            ns.CDMGroups.UpdateGroupVisibility()
                        end
                        -- Trigger auto-save to linked template
                        if ns.CDMGroups.TriggerTemplateAutoSave then
                            ns.CDMGroups.TriggerTemplateAutoSave()
                        end
                    end
                end,
            },
            
            hiddenAlpha = {
                type = "range",
                name = "Hidden Opacity",
                desc = "Opacity level when visibility conditions hide this group.\n0 = fully invisible, 1 = fully visible (no hiding effect).\nDefault: 0",
                order = 66,
                width = 1.5,
                min = 0,
                max = 1,
                step = 0.05,
                isPercent = true,
                hidden = function()
                    if HideIfNoGroup() or collapsedSections.appearance then return true end
                    -- Only show when at least one visibility condition is configured
                    local g = GetSelectedGroup()
                    if not g then return true end
                    local vis = g.visibility
                    if type(vis) == "table" then
                        for k, v in pairs(vis) do
                            if v then return false end
                        end
                        return true
                    end
                    -- Old string format: show for combat/ooc/never
                    return vis == "always" or vis == nil
                end,
                get = function()
                    local g = GetSelectedGroup()
                    return g and g.hiddenAlpha or 0
                end,
                set = function(_, val)
                    local g = GetSelectedGroup()
                    if g then
                        g.hiddenAlpha = val
                        -- Save to profile
                        if ns.CDMGroups.SaveGroupLayoutToProfile then
                            ns.CDMGroups.SaveGroupLayoutToProfile(g.name, g)
                        end
                        -- Invalidate cached state so update re-applies
                        g._arcLastVisState = nil
                        -- Update visibility immediately
                        if ns.CDMGroups.UpdateGroupVisibility then
                            ns.CDMGroups.UpdateGroupVisibility()
                        end
                        -- Trigger auto-save to linked template
                        if ns.CDMGroups.TriggerTemplateAutoSave then
                            ns.CDMGroups.TriggerTemplateAutoSave()
                        end
                    end
                end,
            },
            
            -- TOOLS SECTION
            toolsHeader = {
                type = "toggle",
                name = "Tools",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                disabled = function() return not IsCDMEnabled() end,
                order = 70,
                width = "full",
                get = function() return not collapsedSections.tools end,
                set = function(_, v) collapsedSections.tools = not v end,
            },
            reflowBtn = {
                type = "execute",
                name = "Reflow Icons",
                desc = "Redistribute icons to fill grid sequentially (removes gaps)",
                order = 71,
                width = 0.85,
                hidden = function() return HideIfNoGroup() or collapsedSections.tools end,
                func = function()
                    local g = GetSelectedGroup()
                    if g then g:ReflowIcons() end
                end,
            },
            cleanupBtn = {
                type = "execute",
                name = "Cleanup Empty",
                desc = "Remove empty trailing rows and columns",
                order = 72,
                width = 0.9,
                hidden = function() return HideIfNoGroup() or collapsedSections.tools end,
                func = function()
                    local g = GetSelectedGroup()
                    if g then
                        g:CleanupEmptyRowsCols()
                        g:Layout()
                    end
                end,
            },
        },
    }
    
    -- ═══════════════════════════════════════════════════════════════
    -- INJECT DYNAMIC ANCHORED FRAME ENTRIES
    -- ═══════════════════════════════════════════════════════════════
    local MAX_ANCHORED_FRAMES = 8
    local args = options.args
    
    local function GetEntry(idx)
        local g = GetSelectedGroup()
        if not g or not g.anchor or not g.anchor.anchoredFrames then return nil end
        return g.anchor.anchoredFrames[idx]
    end
    
    local function HideEntry(idx)
        if HideIfNoGroup() or collapsedSections.anchoring then return true end
        local g = GetSelectedGroup()
        if not g or not g.anchor then return true end
        return not g.anchor.anchoredFrames or not g.anchor.anchoredFrames[idx]
    end
    
    local function SaveAndApply()
        local g = GetSelectedGroup()
        if not g or not g.anchor then return end
        local db = g.getDB and g.getDB()
        if db then db.anchor = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.Serialize(g.anchor) or g.anchor end
        if g.anchor.enabled and ns.CDMGroupsAnchors then
            ns.CDMGroupsAnchors.ApplyGroupAnchor(g)
        end
        if ns.CDMGroups.TriggerTemplateAutoSave then ns.CDMGroups.TriggerTemplateAutoSave() end
    end
    
    -- Auto-configure when a frame is assigned.
    -- Default Safe=true for all frames (avoids taint chain issues).
    -- User can toggle off if they want direct anchoring.
    local function AutoConfigureEntry(entry)
        if not entry or not entry.frameName or entry.frameName == "" then return end
        entry.useSafeAnchor = true
        entry.snapBack = false
    end
    
    -- Helper: check if source/dest pair matches a simple preset
    local simplePresets = {
        below  = { "TOP", "BOTTOM" },
        above  = { "BOTTOM", "TOP" },
        left   = { "RIGHT", "LEFT" },
        right  = { "LEFT", "RIGHT" },
        center = { "CENTER", "CENTER" },
    }
    local function GetSimplePosition(src, dst)
        for key, pair in pairs(simplePresets) do
            if src == pair[1] and dst == pair[2] then return key end
        end
        return "advanced"
    end
    local simpleValues = {
        below  = "Below",
        above  = "Above",
        left   = "Left",
        right  = "Right",
        center = "Center",
        advanced = "|cffaaaaaa Advanced|r",
    }
    local simpleSorting = { "below", "above", "left", "right", "center", "advanced" }
    
    for i = 1, MAX_ANCHORED_FRAMES do
        local baseOrder = 48.1 + (i - 1) * 0.1
        local prefix = "af" .. i .. "_"
        
        args[prefix .. "header"] = {
            type = "description",
            name = function()
                local entry = GetEntry(i)
                local fname = entry and entry.frameName or ""
                if fname ~= "" then
                    return "|cff88ccff— Frame " .. i .. ": " .. fname .. " —|r"
                end
                return "|cff888888— Frame " .. i .. " (not set) —|r"
            end,
            fontSize = "medium",
            order = baseOrder,
            width = "full",
            hidden = function() return HideEntry(i) end,
        }
        
        args[prefix .. "name"] = {
            type = "input",
            name = "Frame Name",
            desc = "Global frame name. Type a name, use the preset dropdown, or use Pick Frame.",
            dialogControl = "ArcUI_EditBox",
            order = baseOrder + 0.01,
            width = 0.8,
            hidden = function() return HideEntry(i) end,
            get = function()
                local e = GetEntry(i)
                return e and e.frameName or ""
            end,
            set = function(_, val)
                local e = GetEntry(i)
                if e then
                    e.frameName = val
                    AutoConfigureEntry(e)
                end
                SaveAndApply()
            end,
        }
        
        args[prefix .. "preset"] = {
            type = "select",
            name = "Preset",
            desc = "Quick-select a well-known UI frame.",
            order = baseOrder + 0.011,
            width = 0.9,
            hidden = function() return HideEntry(i) end,
            values = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.COMMON_FRAMES or {},
            sorting = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.COMMON_FRAMES_SORTED or {},
            get = function() return "" end,
            set = function(_, val)
                if val == "" then return end
                local e = GetEntry(i)
                if e then
                    e.frameName = val
                    AutoConfigureEntry(e)
                end
                SaveAndApply()
                local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
                if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
            end,
        }
        
        args[prefix .. "pick"] = {
            type = "execute",
            name = "Pick",
            desc = "Mouse over any frame and click to select it.",
            order = baseOrder + 0.012,
            width = 0.4,
            hidden = function() return HideEntry(i) end,
            func = function()
                if not ns.CDMGroupsAnchors or not ns.CDMGroupsAnchors.StartPicker then return end
                ns.CDMGroupsAnchors.StartPicker(function(name)
                    local e = GetEntry(i)
                    if e then
                        e.frameName = name
                        AutoConfigureEntry(e)
                    end
                    SaveAndApply()
                    local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
                    if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
                end)
            end,
        }
        
        args[prefix .. "position"] = {
            type = "select",
            name = "Position",
            desc = "Where to position relative to the group. Pick 'Advanced' for full control.",
            order = baseOrder + 0.015,
            width = 0.55,
            hidden = function() return HideEntry(i) end,
            values = simpleValues,
            sorting = simpleSorting,
            get = function()
                local e = GetEntry(i)
                if not e then return "below" end
                return GetSimplePosition(e.sourcePoint or "BOTTOM", e.destPoint or "TOP")
            end,
            set = function(_, val)
                local e = GetEntry(i)
                if not e then return end
                if simplePresets[val] then
                    e.sourcePoint = simplePresets[val][1]
                    e.destPoint = simplePresets[val][2]
                    e._advancedMode = nil
                    SaveAndApply()
                elseif val == "advanced" then
                    e._advancedMode = true
                end
            end,
        }
        
        args[prefix .. "source"] = {
            type = "select",
            name = "Src",
            desc = "Point on the external frame that attaches.",
            order = baseOrder + 0.02,
            width = 0.45,
            hidden = function()
                if HideEntry(i) then return true end
                local e = GetEntry(i)
                if not e then return true end
                if e._advancedMode then return false end
                return GetSimplePosition(e.sourcePoint or "BOTTOM", e.destPoint or "TOP") ~= "advanced"
            end,
            values = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.ANCHOR_POINTS or {},
            sorting = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.ANCHOR_POINTS_SORTED or {},
            get = function()
                local e = GetEntry(i)
                return e and e.sourcePoint or "BOTTOM"
            end,
            set = function(_, val)
                local e = GetEntry(i)
                if e then e.sourcePoint = val end
                SaveAndApply()
            end,
        }
        
        args[prefix .. "dest"] = {
            type = "select",
            name = "Dst",
            desc = "Point on this group's container that we attach to.",
            order = baseOrder + 0.03,
            width = 0.45,
            hidden = function()
                if HideEntry(i) then return true end
                local e = GetEntry(i)
                if not e then return true end
                if e._advancedMode then return false end
                return GetSimplePosition(e.sourcePoint or "BOTTOM", e.destPoint or "TOP") ~= "advanced"
            end,
            values = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.ANCHOR_POINTS or {},
            sorting = ns.CDMGroupsAnchors and ns.CDMGroupsAnchors.ANCHOR_POINTS_SORTED or {},
            get = function()
                local e = GetEntry(i)
                return e and e.destPoint or "TOP"
            end,
            set = function(_, val)
                local e = GetEntry(i)
                if e then e.destPoint = val end
                SaveAndApply()
            end,
        }
        
        args[prefix .. "offx"] = {
            type = "input",
            name = "X",
            desc = "Horizontal offset",
            dialogControl = "ArcUI_EditBox",
            order = baseOrder + 0.04,
            width = 0.35,
            hidden = function() return HideEntry(i) end,
            get = function()
                local e = GetEntry(i)
                return tostring(e and e.offsetX or 0)
            end,
            set = function(_, val)
                local e = GetEntry(i)
                if e then e.offsetX = tonumber(val) or 0 end
                SaveAndApply()
            end,
        }
        
        args[prefix .. "offy"] = {
            type = "input",
            name = "Y",
            desc = "Vertical offset",
            dialogControl = "ArcUI_EditBox",
            order = baseOrder + 0.05,
            width = 0.35,
            hidden = function() return HideEntry(i) end,
            get = function()
                local e = GetEntry(i)
                return tostring(e and e.offsetY or 0)
            end,
            set = function(_, val)
                local e = GetEntry(i)
                if e then e.offsetY = tonumber(val) or 0 end
                SaveAndApply()
            end,
        }
        
        args[prefix .. "safe"] = {
            type = "toggle",
            name = "Safe",
            desc = "Position without creating a direct link. Avoids UI errors. Recommended.",
            order = baseOrder + 0.06,
            width = 0.4,
            hidden = function() return HideEntry(i) end,
            get = function()
                local e = GetEntry(i)
                return e and e.useSafeAnchor or false
            end,
            set = function(_, val)
                local e = GetEntry(i)
                if e then e.useSafeAnchor = val end
                SaveAndApply()
            end,
        }
        
        args[prefix .. "snap"] = {
            type = "toggle",
            name = "Snap",
            desc = "Force the frame back if something else moves it. May conflict with other addons.",
            order = baseOrder + 0.07,
            width = 0.4,
            hidden = function() return HideEntry(i) end,
            get = function()
                local e = GetEntry(i)
                return e and e.snapBack or false
            end,
            set = function(_, val)
                local e = GetEntry(i)
                if e then e.snapBack = val end
                SaveAndApply()
            end,
        }
        
        args[prefix .. "remove"] = {
            type = "execute",
            name = "|cffff4444X|r",
            desc = "Remove this frame entry.",
            order = baseOrder + 0.08,
            width = 0.3,
            hidden = function() return HideEntry(i) end,
            func = function()
                local g = GetSelectedGroup()
                if not g or not g.anchor or not g.anchor.anchoredFrames then return end
                -- Detach this specific frame before removing from config
                local entry = g.anchor.anchoredFrames[i]
                if entry and entry.frameName and entry.frameName ~= "" then
                    local extFrame = _G[entry.frameName]
                    if extFrame then
                        -- Clear snap-back data FIRST (prevents hook from re-anchoring)
                        extFrame._arcAnchorData = nil
                        extFrame._arcAnchorMoving = nil
                        extFrame._arcAnchoredByGroup = nil
                        -- Restore original position if saved
                        if extFrame._arcOriginalAnchors then
                            if not InCombatLockdown() or not (extFrame.IsProtected and extFrame:IsProtected()) then
                                extFrame:ClearAllPoints()
                                for _, a in ipairs(extFrame._arcOriginalAnchors) do
                                    extFrame:SetPoint(a.point, a.relTo or UIParent, a.relPoint, a.x or 0, a.y or 0)
                                end
                            end
                            extFrame._arcOriginalAnchors = nil
                        end
                        -- Clear ownership
                        if ns._activeFrameOwnership then
                            ns._activeFrameOwnership[entry.frameName] = nil
                        end
                    end
                end
                table.remove(g.anchor.anchoredFrames, i)
                SaveAndApply()
                local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
                if AceConfigRegistry then AceConfigRegistry:NotifyChange("ArcUI") end
            end,
        }
    end
    
    return options
end


-- ===================================================================
-- EXPORT FOR ARCUI OPTIONS
-- ===================================================================
function ns.GetCDMGroupsOptionsTable()
    return GetOptionsTable()
end

-- ===================================================================
-- END OF ArcUI_CDMGroupsOptions.lua
-- ===================================================================