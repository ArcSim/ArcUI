---@diagnostic disable: undefined-field, undefined-global
-- ArcUI_BarGroupAlign.lua
-- Shared pixel-perfect bar alignment for CDM group anchoring.
-- Used by ArcUI_Resources, ArcUI_CooldownBars, ArcUI_Display, and any future bar type.
-- See ArcUI_BarAlignment.md for the full explanation of every drift source fixed here.

local _, ns = ...
ns.BarGroupAlign = ns.BarGroupAlign or {}
local BGA = ns.BarGroupAlign

-- ===================================================================
-- PIXEL SNAP
-- ===================================================================

-- SnapToGroupPx: identical formula to CDMGroups Layout() snapPx.
-- Uses UIParent:GetScale() — NOT container:GetEffectiveScale() — to match CDMGroups exactly.
-- Always use this when sizing a bar to match _slotAreaW / _slotAreaH.
local function SnapToGroupPx(n)
  local _, h = GetPhysicalScreenSize()
  local s = UIParent:GetScale()
  if h and h > 0 and s and s > 0 then
    local ppu = (h / 768) * s
    return math.floor(n * ppu + 0.5) / ppu
  end
  return math.floor(n + 0.5)
end
BGA.SnapToGroupPx = SnapToGroupPx

-- PixelSnap: for dimensions NOT derived from CDMGroups (bar height, etc.).
-- Accepts explicit effectiveScale for callers that already have it.
function BGA.PixelSnap(n, effectiveScale)
  local _, h = GetPhysicalScreenSize()
  local s = effectiveScale or UIParent:GetScale()
  if h and h > 0 and s and s > 0 then
    local ppu = (h / 768) * s
    return math.floor(n * ppu + 0.5) / ppu
  end
  return math.floor(n + 0.5)
end

-- ===================================================================
-- ACTUAL ICON INSET READERS
-- These read live frame positions instead of computing from rawBase.
-- GetLeft()/GetTop() and SetPoint offsets share the same WoW coordinate
-- space, so the difference is directly usable as a SetPoint offset.
-- ===================================================================

-- X inset: container BOTTOMLEFT → leftmost visible icon left edge.
local function GetIconInsetX(group)
  local rawBase = group and group._slotInsetPx or 0
  if not group or not group.members or not group.container then return rawBase end
  local containerLeft = group.container:GetLeft()
  if not containerLeft then return rawBase end
  local minLeft = math.huge
  for _, member in pairs(group.members) do
    local frame = member.frame
    if frame and frame:IsShown() then
      local fL = frame:GetLeft()
      if fL and fL < minLeft then minLeft = fL end
    end
  end
  if minLeft < math.huge then
    return SnapToGroupPx(minLeft - containerLeft)
  end
  return rawBase
end
BGA.GetIconInsetX = GetIconInsetX

-- Y inset (top): downward inset from container top edge to topmost icon top edge.
-- WoW Y is inverted: containerTop - iconTop = positive downward value.
local function GetIconInsetY(group)
  local rawBase = group and group._slotInsetPx or 0
  if not group or not group.members or not group.container then return rawBase end
  local containerTop = group.container:GetTop()
  if not containerTop then return rawBase end
  local maxTop = -math.huge
  for _, member in pairs(group.members) do
    local frame = member.frame
    if frame and frame:IsShown() then
      local fT = frame:GetTop()
      if fT and fT > maxTop then maxTop = fT end
    end
  end
  if maxTop > -math.huge then
    return SnapToGroupPx(containerTop - maxTop)
  end
  return rawBase
end
BGA.GetIconInsetY = GetIconInsetY

-- Y inset (bottom): distance in WoW units from container bottom edge UP to the
-- bottom edge of the lowest visible icon. Use as positive Y offset in a TOPLEFT
-- anchor so the bar sits flush against the icon area bottom, not the container edge.
local function GetIconInsetBottom(group)
  local rawBase = group and group._slotInsetPx or 0
  if not group or not group.members or not group.container then return rawBase end
  local containerBottom = group.container:GetBottom()
  if not containerBottom then return rawBase end
  local minBottom = math.huge
  for _, member in pairs(group.members) do
    local frame = member.frame
    if frame and frame:IsShown() then
      local fB = frame:GetBottom()
      if fB and fB < minBottom then minBottom = fB end
    end
  end
  if minBottom < math.huge then
    return SnapToGroupPx(minBottom - containerBottom)  -- positive = icon bottom above container bottom
  end
  return rawBase
end
BGA.GetIconInsetBottom = GetIconInsetBottom

-- ===================================================================
-- DIMENSION HELPERS
-- ===================================================================

--- Returns the correct bar width (or height for vertical fragmented) in WoW units.
--- @param group table CDMGroups group object
--- @param isFragVertical boolean true for vertical fragmented layout
--- @param isSideAnchor boolean true for LEFT/RIGHT anchor points
--- @param sizeAdjust number? optional matchWidthAdjust
--- @return number? dimension, or nil if group not ready
function BGA.GetMatchedDimension(group, isFragVertical, isSideAnchor, sizeAdjust)
  if not group then return nil end
  local dim
  if isFragVertical then
    -- Vertical fragmented: long dimension is always H regardless of anchor side
    dim = group._slotAreaHRaw or group._slotAreaH
  else
    -- Horizontal / non-fragmented: side anchors need H, others need W
    dim = isSideAnchor
      and (group._slotAreaHRaw or group._slotAreaH)
      or  (group._slotAreaWRaw or group._slotAreaW)
  end
  if not dim or dim <= 0 then return nil end
  return SnapToGroupPx(dim + (sizeAdjust or 0))
end

-- ===================================================================
-- ANCHOR APPLICATION
-- Single function that handles all four anchor sides with correct
-- icon-aligned offsets. Call this instead of frame:SetPoint directly.
-- ===================================================================

--- Apply group-aligned anchor to a bar frame.
--- @param frame table WoW frame to anchor
--- @param container table CDMGroups container frame
--- @param group table CDMGroups group object
--- @param anchorPoint string "TOP"|"BOTTOM"|"LEFT"|"RIGHT"
--- @param barWidth number computed bar width (used for non-matched fallback)
--- @param offsetX number cfg.display.anchorOffsetX
--- @param offsetY number cfg.display.anchorOffsetY
--- @param matchSlots boolean true = use icon-aligned insets
function BGA.ApplyAnchor(frame, container, group, anchorPoint, barWidth, offsetX, offsetY, matchSlots)
  local insetX = matchSlots and GetIconInsetX(group) or 0
  local insetY = matchSlots and GetIconInsetY(group) or 0

  frame:ClearAllPoints()
  if anchorPoint == "TOP" then
    if matchSlots then
      local insetYTop = GetIconInsetY(group)
      frame:SetPoint("BOTTOMLEFT", container, "TOPLEFT", insetX + offsetX, -insetYTop + offsetY)
    else
      frame:SetPoint("BOTTOMLEFT", container, "TOPLEFT", offsetX, offsetY)
    end
  elseif anchorPoint == "BOTTOM" then
    if matchSlots then
      local insetBottom = GetIconInsetBottom(group)
      frame:SetPoint("TOPLEFT", container, "BOTTOMLEFT", insetX + offsetX, insetBottom + offsetY)
    else
      frame:SetPoint("TOPLEFT", container, "BOTTOMLEFT", offsetX, offsetY)
    end
  elseif anchorPoint == "LEFT" then
    if matchSlots then
      frame:SetPoint("TOPRIGHT", container, "TOPLEFT", offsetX, -(insetY + offsetY))
    else
      frame:SetPoint("RIGHT", container, "LEFT", offsetX, offsetY)
    end
  elseif anchorPoint == "RIGHT" then
    if matchSlots then
      frame:SetPoint("TOPLEFT", container, "TOPRIGHT", offsetX, -(insetY + offsetY))
    else
      frame:SetPoint("LEFT", container, "RIGHT", offsetX, offsetY)
    end
  end
end

-- ===================================================================
-- HIGH-LEVEL HELPERS (convenience wrappers using groupName string)
-- ===================================================================

--- Returns matched bar width in WoW units by group name.
--- @param groupName string
--- @param isFragVertical boolean
--- @param isSideAnchor boolean
--- @param sizeAdjust number?
--- @return number?
function BGA.GetMatchedDimensionByName(groupName, isFragVertical, isSideAnchor, sizeAdjust)
  local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]
  return BGA.GetMatchedDimension(group, isFragVertical, isSideAnchor, sizeAdjust)
end

--- Returns X icon inset by group name.
--- @param groupName string
--- @return number
function BGA.GetIconInsetXByName(groupName)
  local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]
  return GetIconInsetX(group)
end

--- Returns Y icon inset by group name.
--- @param groupName string
--- @return number
function BGA.GetIconInsetYByName(groupName)
  local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]
  return GetIconInsetY(group)
end

--- Returns bottom Y icon inset by group name.
--- Use as positive Y offset when anchoring a bar to BOTTOM of a group so it
--- sits flush with the icon bottom edge rather than the container bottom edge.
--- @param groupName string
--- @return number
function BGA.GetIconInsetBottomByName(groupName)
  local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]
  return GetIconInsetBottom(group)
end

--- Full size + anchor in one call. The main entry point for all bar types.
--- Handles dimension selection, SnapToGroupPx, and correct anchor for all four sides.
---
--- @param frame table bar's root frame
--- @param groupName string cfg.display.anchorGroupName
--- @param anchorPoint string "TOP"|"BOTTOM"|"LEFT"|"RIGHT"
--- @param barHeight number already-computed bar height (from cfg.display.height * scale)
--- @param offsetX number cfg.display.anchorOffsetX
--- @param offsetY number cfg.display.anchorOffsetY
--- @param matchGroupWidth boolean cfg.display.matchGroupWidth
--- @param matchSlotsOnly boolean cfg.display.matchSlotsOnly
--- @param isFragVertical boolean true for vertical fragmented bars
--- @param sizeAdjust number? cfg.display.matchWidthAdjust
--- @param needsSwap boolean? true when width/height should be swapped in SetSize
--- @return number? barWidth the resolved width (or nil if group not found)
function BGA.ApplySizeAndAnchor(frame, groupName, anchorPoint, barHeight, offsetX, offsetY,
    matchGroupWidth, matchSlotsOnly, isFragVertical, sizeAdjust, needsSwap)

  local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[groupName]
  if not group or not group.container then return nil end
  local container = group.container

  local isSideAnchor = (anchorPoint == "LEFT" or anchorPoint == "RIGHT")
  local barWidth

  if matchGroupWidth then
    local dim = BGA.GetMatchedDimension(group, isFragVertical, isSideAnchor, sizeAdjust)
    if dim and dim > 0 then
      barWidth = dim
      if needsSwap then
        frame:SetSize(barHeight, barWidth)
      else
        frame:SetSize(barWidth, barHeight)
      end
    end
  end

  local matchSlots = matchGroupWidth and matchSlotsOnly and barWidth
  BGA.ApplyAnchor(frame, container, group, anchorPoint, barWidth, offsetX, offsetY, matchSlots)

  return barWidth
end