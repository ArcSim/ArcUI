-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI-CatalogGridBuilder.lua
-- Reusable icon grid builder for AceConfig options panels
-- Place in: Libs/AceGUI-3.0-ArcUI-Widgets/ArcUI-CatalogGridBuilder.lua
--
-- Generates dynamic AceConfig "execute" button args for icon grids
-- with selection state, multi-select, edit-all, caching, and callbacks.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- USAGE EXAMPLE:
--
--   local CatalogGridBuilder = LibStub("ArcUI-CatalogGridBuilder-1.0")
--
--   local myGrid = CatalogGridBuilder:New({
--       id            = "auraCatalog",
--       maxIcons      = 50,
--       iconWidth     = 36,
--       iconHeight    = 36,
--       cellWidth     = 0.25,
--       orderBase     = 7,
--
--       -- DATA: Return array of entry tables
--       dataProvider  = function(grid)
--           return ns.Catalog.GetFilteredCatalog("tracked", "")
--       end,
--
--       -- IDENTITY / DISPLAY: Mandatory accessors
--       getEntryID    = function(entry) return entry.cooldownID end,
--       getEntryIcon  = function(entry) return entry.icon end,
--
--       -- OPTIONAL: Custom button label
--       -- state = { selected, multiSelected, editAll, hasCustom }
--       getEntryName  = function(entry, state)
--           if state.editAll then return "|cff00ffffAll|r" end
--           if state.multiSelected then return "|cff00ff00Multi|r" end
--           if state.selected then return "|cff00ff00Edit|r" end
--           return ""
--       end,
--
--       -- OPTIONAL: Tooltip text
--       getEntryDesc  = function(entry, state)
--           return entry.name .. "\nSpell ID: " .. (entry.spellID or "?")
--       end,
--
--       -- OPTIONAL: Per-entry hide filter (true = hidden)
--       isEntryHidden = function(entry) return false end,
--
--       -- OPTIONAL: Custom-data indicator per entry
--       hasCustomData = function(entry) return false end,
--
--       -- SELECTION: "single" | "toggle" | "multi"
--       selectionMode   = "toggle",
--       multiSelectKey  = "shift",  -- "shift" | "ctrl" | "alt" | nil
--
--       -- CALLBACKS
--       onSelect           = function(grid, id, entry) end,
--       onDeselect         = function(grid, id, entry) end,
--       onSelectionChanged = function(grid) end,
--   })
--
--   -- Merge icon args into AceConfig:
--   local iconArgs = myGrid:GetArgs()
--   for k, v in pairs(iconArgs) do myOptionsTable.args[k] = v end
--
--   -- Query:
--   myGrid:GetSelectedEntry()       -- Single entry or nil
--   myGrid:GetSelectedEntries()     -- Array of all selected
--   myGrid:GetSelectedIDs()         -- Array of selected IDs
--   myGrid:HasSelection()           -- Boolean
--   myGrid:GetSelectionCount()      -- Number
--
--   -- Manipulate:
--   myGrid:ClearSelection()
--   myGrid:SelectByID(id)
--   myGrid:ToggleByID(id)
--   myGrid:MultiSelectByID(id)
--   myGrid:SetEditAll(true)
--   myGrid:InvalidateCache()
-- ═══════════════════════════════════════════════════════════════════════════

local MAJOR, MINOR = "ArcUI-CatalogGridBuilder-1.0", 1
local lib = LibStub and LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- ═══════════════════════════════════════════════════════════════════════════
-- CATALOGGRIDBUILDER
-- ═══════════════════════════════════════════════════════════════════════════
local CatalogGridBuilder = {}
CatalogGridBuilder.__index = CatalogGridBuilder

-- Global registry of all grids
lib.gridRegistry = lib.gridRegistry or {}

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTRUCTOR
-- ═══════════════════════════════════════════════════════════════════════════
function lib:New(config)
    assert(config, "CatalogGridBuilder:New requires a config table")
    assert(config.id, "Config requires 'id' field")
    assert(config.dataProvider, "Config requires 'dataProvider' function")
    assert(config.getEntryID, "Config requires 'getEntryID' function")
    assert(config.getEntryIcon, "Config requires 'getEntryIcon' function")

    local grid = setmetatable({}, CatalogGridBuilder)

    -- Core config
    grid.id            = config.id
    grid.maxIcons      = config.maxIcons or 50
    grid.iconWidth     = config.iconWidth or 36
    grid.iconHeight    = config.iconHeight or 36
    grid.cellWidth     = config.cellWidth or 0.25
    grid.orderBase     = config.orderBase or 7
    grid.orderStep     = config.orderStep or 0.001

    -- Data
    grid.dataProvider  = config.dataProvider

    -- Entry accessors
    grid.getEntryID    = config.getEntryID
    grid.getEntryIcon  = config.getEntryIcon
    grid.getEntryName  = config.getEntryName
    grid.getEntryDesc  = config.getEntryDesc
    grid.isEntryHidden = config.isEntryHidden
    grid.hasCustomData = config.hasCustomData

    -- Selection
    grid.selectionMode   = config.selectionMode or "single"
    grid.multiSelectKey  = config.multiSelectKey or "shift"

    -- Callbacks
    grid.onSelect           = config.onSelect
    grid.onDeselect         = config.onDeselect
    grid.onSelectionChanged = config.onSelectionChanged

    -- State
    grid._selectedID     = nil
    grid._multiSelected  = {}
    grid._editAll        = false
    grid._cache          = {}
    grid._cacheValid     = false

    lib.gridRegistry[config.id] = grid
    return grid
end

--- Retrieve a grid by ID
function lib:GetGrid(id)
    return lib.gridRegistry[id]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CACHE
-- ═══════════════════════════════════════════════════════════════════════════

function CatalogGridBuilder:InvalidateCache()
    self._cacheValid = false
end

function CatalogGridBuilder:_RebuildCache()
    wipe(self._cache)
    local entries = self.dataProvider(self)
    if entries then
        local idx = 0
        for _, entry in ipairs(entries) do
            local hidden = self.isEntryHidden and self.isEntryHidden(entry)
            if not hidden then
                idx = idx + 1
                self._cache[idx] = entry
                if idx >= self.maxIcons then break end
            end
        end
    end
    self._cacheValid = true
end

function CatalogGridBuilder:GetEntryByIndex(index)
    if not self._cacheValid then self:_RebuildCache() end
    return self._cache[index]
end

function CatalogGridBuilder:GetVisibleCount()
    if not self._cacheValid then self:_RebuildCache() end
    return #self._cache
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SELECTION QUERIES
-- ═══════════════════════════════════════════════════════════════════════════

function CatalogGridBuilder:IsSelected(id)
    if self._editAll then return true end
    if self._multiSelected[id] then return true end
    return self._selectedID == id
end

function CatalogGridBuilder:IsMultiSelected(id)
    return self._multiSelected[id] == true
end

function CatalogGridBuilder:IsEditAll()
    return self._editAll
end

function CatalogGridBuilder:HasSelection()
    if self._editAll then return true end
    if self._selectedID then return true end
    return next(self._multiSelected) ~= nil
end

function CatalogGridBuilder:GetSelectionCount()
    if self._editAll then return self:GetVisibleCount() end
    local count = 0
    for _ in pairs(self._multiSelected) do count = count + 1 end
    if count > 0 then return count end
    return self._selectedID and 1 or 0
end

function CatalogGridBuilder:GetSelectedID()
    if self._selectedID then return self._selectedID end
    for id in pairs(self._multiSelected) do return id end
    return nil
end

function CatalogGridBuilder:GetSelectedEntry()
    if not self._selectedID then return nil end
    return self:FindEntryByID(self._selectedID)
end

function CatalogGridBuilder:GetSelectedEntries()
    if not self._cacheValid then self:_RebuildCache() end
    if self._editAll then
        local result = {}
        for i, e in ipairs(self._cache) do result[i] = e end
        return result
    end
    local result = {}
    if next(self._multiSelected) then
        for _, entry in ipairs(self._cache) do
            if self._multiSelected[self.getEntryID(entry)] then
                result[#result + 1] = entry
            end
        end
    elseif self._selectedID then
        for _, entry in ipairs(self._cache) do
            if self.getEntryID(entry) == self._selectedID then
                result[1] = entry
                break
            end
        end
    end
    return result
end

function CatalogGridBuilder:GetSelectedIDs()
    if self._editAll then
        if not self._cacheValid then self:_RebuildCache() end
        local result = {}
        for _, e in ipairs(self._cache) do
            result[#result + 1] = self.getEntryID(e)
        end
        return result
    end
    if next(self._multiSelected) then
        local result = {}
        for id in pairs(self._multiSelected) do
            result[#result + 1] = id
        end
        return result
    end
    return self._selectedID and { self._selectedID } or {}
end

function CatalogGridBuilder:FindEntryByID(id)
    if not self._cacheValid then self:_RebuildCache() end
    for _, entry in ipairs(self._cache) do
        if self.getEntryID(entry) == id then return entry end
    end
    return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SELECTION MANIPULATION
-- ═══════════════════════════════════════════════════════════════════════════

function CatalogGridBuilder:ClearSelection()
    local had = self:HasSelection()
    self._selectedID = nil
    wipe(self._multiSelected)
    self._editAll = false
    if had and self.onSelectionChanged then self.onSelectionChanged(self) end
end

function CatalogGridBuilder:SelectByID(id)
    wipe(self._multiSelected)
    self._editAll = false
    self._selectedID = id
    local entry = self:FindEntryByID(id)
    if self.onSelect then self.onSelect(self, id, entry) end
    if self.onSelectionChanged then self.onSelectionChanged(self) end
end

function CatalogGridBuilder:DeselectByID(id)
    if self._selectedID == id then self._selectedID = nil end
    self._multiSelected[id] = nil
    local entry = self:FindEntryByID(id)
    if self.onDeselect then self.onDeselect(self, id, entry) end
    if self.onSelectionChanged then self.onSelectionChanged(self) end
end

function CatalogGridBuilder:ToggleByID(id)
    wipe(self._multiSelected)
    self._editAll = false
    local entry = self:FindEntryByID(id)
    if self._selectedID == id then
        self._selectedID = nil
        if self.onDeselect then self.onDeselect(self, id, entry) end
    else
        self._selectedID = id
        if self.onSelect then self.onSelect(self, id, entry) end
    end
    if self.onSelectionChanged then self.onSelectionChanged(self) end
end

function CatalogGridBuilder:MultiSelectByID(id)
    -- Promote single -> multi if needed
    if self._selectedID and not next(self._multiSelected) then
        self._multiSelected[self._selectedID] = true
    end
    local entry = self:FindEntryByID(id)
    if self._multiSelected[id] then
        self._multiSelected[id] = nil
        if self.onDeselect then self.onDeselect(self, id, entry) end
    else
        self._multiSelected[id] = true
        if not self._selectedID then self._selectedID = id end
        if self.onSelect then self.onSelect(self, id, entry) end
    end
    self._editAll = false
    if self.onSelectionChanged then self.onSelectionChanged(self) end
end

function CatalogGridBuilder:SetEditAll(enabled)
    self._editAll = enabled
    if self.onSelectionChanged then self.onSelectionChanged(self) end
end

function CatalogGridBuilder:ToggleEditAll()
    self:SetEditAll(not self._editAll)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CLICK HANDLER (internal)
-- ═══════════════════════════════════════════════════════════════════════════
function CatalogGridBuilder:_HandleClick(id, entry)
    if self._editAll then self._editAll = false end

    local isMultiKey = false
    if self.multiSelectKey == "shift" and IsShiftKeyDown then
        isMultiKey = IsShiftKeyDown()
    elseif self.multiSelectKey == "ctrl" and IsControlKeyDown then
        isMultiKey = IsControlKeyDown()
    elseif self.multiSelectKey == "alt" and IsAltKeyDown then
        isMultiKey = IsAltKeyDown()
    end

    if (self.selectionMode == "multi" or self.selectionMode == "toggle") and isMultiKey then
        self:MultiSelectByID(id)
    elseif self.selectionMode == "toggle" then
        self:ToggleByID(id)
    else
        -- Single select: toggle on re-click
        wipe(self._multiSelected)
        if self._selectedID == id then
            self._selectedID = nil
            if self.onDeselect then self.onDeselect(self, id, entry) end
        else
            self._selectedID = id
            if self.onSelect then self.onSelect(self, id, entry) end
        end
        self._editAll = false
        if self.onSelectionChanged then self.onSelectionChanged(self) end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ACECONFIG ARGS GENERATION
-- ═══════════════════════════════════════════════════════════════════════════

--- Generate AceConfig args table for the icon grid.
-- Merge the returned keys into your options group's args table.
function CatalogGridBuilder:GetArgs()
    local args = {}
    local gridRef = self

    for i = 1, self.maxIcons do
        local slotIndex = i
        local argKey = self.id .. "_icon_" .. i

        args[argKey] = {
            type = "execute",

            name = function()
                local entry = gridRef:GetEntryByIndex(slotIndex)
                if not entry then return "" end
                local id = gridRef.getEntryID(entry)
                local hasCustom = gridRef.hasCustomData and gridRef.hasCustomData(entry) or false

                if gridRef.getEntryName then
                    return gridRef.getEntryName(entry, {
                        selected      = gridRef:IsSelected(id),
                        multiSelected = gridRef:IsMultiSelected(id),
                        editAll       = gridRef._editAll,
                        hasCustom     = hasCustom,
                    })
                end

                -- Default labels
                if gridRef._editAll then
                    return hasCustom and "|cff00ffffAll|r |cffaa55ff*|r" or "|cff00ffffAll|r"
                end
                if gridRef:IsMultiSelected(id) then
                    return hasCustom and "|cff00ff00Multi|r |cffaa55ff*|r" or "|cff00ff00Multi|r"
                end
                if gridRef:IsSelected(id) then
                    return hasCustom and "|cff00ff00Edit|r |cffaa55ff*|r" or "|cff00ff00Edit|r"
                end
                return hasCustom and "|cffaa55ff*|r" or ""
            end,

            desc = function()
                local entry = gridRef:GetEntryByIndex(slotIndex)
                if not entry then return "" end
                if gridRef.getEntryDesc then
                    local id = gridRef.getEntryID(entry)
                    return gridRef.getEntryDesc(entry, {
                        selected      = gridRef:IsSelected(id),
                        multiSelected = gridRef:IsMultiSelected(id),
                        editAll       = gridRef._editAll,
                        hasCustom     = gridRef.hasCustomData and gridRef.hasCustomData(entry) or false,
                    })
                end
                return entry.name or "Unknown"
            end,

            func = function()
                local entry = gridRef:GetEntryByIndex(slotIndex)
                if not entry then return end
                gridRef:_HandleClick(gridRef.getEntryID(entry), entry)
            end,

            image = function()
                local entry = gridRef:GetEntryByIndex(slotIndex)
                return entry and gridRef.getEntryIcon(entry) or nil
            end,

            imageWidth  = self.iconWidth,
            imageHeight = self.iconHeight,
            order       = self.orderBase + (i * self.orderStep),
            width       = self.cellWidth,

            hidden = function()
                return gridRef:GetEntryByIndex(slotIndex) == nil
            end,
        }
    end

    return args
end

--- Iterate visible entries (returns iterator function)
function CatalogGridBuilder:IterateEntries()
    if not self._cacheValid then self:_RebuildCache() end
    local i = 0
    return function()
        i = i + 1
        return self._cache[i]
    end
end
