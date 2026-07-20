-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_PublicAPI.lua
-- Public integration surface for third-party addons.
--
-- 1) ANCHOR PROVIDER: a stable, globally-named anchor frame per CDM group that
--    tracks that group's on-screen position and size, plus an EventRegistry
--    event fired when a group's size changes. This mirrors the provider model
--    that unit-frame addons already consume from other cooldown addons
--    (SkironCooldownManager's SCM_GroupAnchorProxy_1 + its SizeChanged event,
--    Coolinator's CoolinatorPrimaryGroupAnchor): the provider owns its layout,
--    the consumer just SetPoints to a stable anchor identity and observes it.
--
--    Globals exposed (created lazily as groups appear):
--      _G.ArcUI_GroupAnchor_<SanitizedGroupName>  -- one per group
--      _G.ArcUI_PrimaryGroupAnchor                -- tracks the primary group
--    EventRegistry event:
--      "ArcUI.AnchorProxy.SizeChanged"  (args: groupName, anchorFrame)
--
--    TAINT-SAFE: each anchor is our own frame that SetAllPoints the group's
--    internal anchorProxy, which SyncAnchorProxy keeps as a UIParent-relative
--    (screen-coordinate) mirror of the container. So our anchors never sit in a
--    secure/secret anchor chain, and we never move any protected frame. We only
--    hooksecurefunc SyncAnchorProxy (reading, never writing Blizzard state) and
--    fire a notification event; consumers handle their own combat deferral.
--
-- 2) _G.ArcUI_Public: a small table for querying groups / anchors and (optionally)
--    letting an addon hand a frame to ArcUI to host inside a group.
--
-- No user-facing options; passive infrastructure, zero idle CPU (the hook only
-- runs on already-existing SyncAnchorProxy calls).
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local ANCHOR_EVENT   = "ArcUI.AnchorProxy.SizeChanged"
local ANCHOR_PREFIX  = "ArcUI_GroupAnchor_"
local PRIMARY_GROUP  = "Essential"   -- primary anchor tracks this group if present

-- groupName -> our public anchor frame
local anchors = {}
local primaryAnchor  -- _G.ArcUI_PrimaryGroupAnchor

local function SanitizeName(name)
  return (tostring(name):gsub("[^%w]", "_"))
end

local function FireAnchorChanged(groupName, anchor)
  if EventRegistry and EventRegistry.TriggerEvent then
    EventRegistry:TriggerEvent(ANCHOR_EVENT, groupName, anchor)
  end
end

-- Ensure a stable, globally-named anchor exists for a group and is pointed at
-- the group's current internal anchorProxy. Returns the anchor frame (or nil).
local function EnsureAnchor(groupName, group)
  if not groupName then return nil end

  local anchor = anchors[groupName]
  if not anchor then
    local globalName = ANCHOR_PREFIX .. SanitizeName(groupName)
    anchor = _G[globalName]
    if not anchor then
      anchor = CreateFrame("Frame", globalName, UIParent)
      anchor:EnableMouse(false)
      anchor:SetAlpha(0)
    end
    anchor._arcGroupName = groupName
    anchor:SetScript("OnSizeChanged", function(self)
      FireAnchorChanged(self._arcGroupName, self)
    end)
    anchors[groupName] = anchor
  end

  -- Point at the group's internal proxy (UIParent-relative mirror of the
  -- container). Re-point only if the proxy object changed (group rebuild).
  local proxy = group and group.anchorProxy
  if proxy and anchor._arcMirror ~= proxy then
    anchor:ClearAllPoints()
    anchor:SetAllPoints(proxy)
    anchor._arcMirror = proxy
    anchor:Show()
  end

  return anchor
end

-- Keep _G.ArcUI_PrimaryGroupAnchor pointed at the preferred (or first) group.
local function UpdatePrimary()
  local target = anchors[PRIMARY_GROUP]
  if not target then
    for _, a in pairs(anchors) do target = a break end
  end
  if not target then return end

  if not primaryAnchor then
    primaryAnchor = CreateFrame("Frame", "ArcUI_PrimaryGroupAnchor", UIParent)
    primaryAnchor:EnableMouse(false)
    primaryAnchor:SetAlpha(0)
    primaryAnchor:SetScript("OnSizeChanged", function(self)
      FireAnchorChanged("__primary__", self)
    end)
  end
  if primaryAnchor._arcMirror ~= target then
    primaryAnchor:ClearAllPoints()
    primaryAnchor:SetAllPoints(target)
    primaryAnchor._arcMirror = target
    primaryAnchor:Show()
  end
end

-- Ensure anchors for every current group; hide anchors for groups that are gone.
local function RefreshAll()
  local groups = ns.CDMGroups and ns.CDMGroups.groups
  if not groups then return end
  for name, group in pairs(groups) do
    EnsureAnchor(name, group)
  end
  for name, anchor in pairs(anchors) do
    if not groups[name] then
      anchor:ClearAllPoints()
      anchor:Hide()
      anchor._arcMirror = nil
    end
  end
  UpdatePrimary()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HOOK: keep anchors current whenever a group's proxy position/size updates.
-- ═══════════════════════════════════════════════════════════════════════════
if ns.CDMGroups and ns.CDMGroups.SyncAnchorProxy then
  hooksecurefunc(ns.CDMGroups, "SyncAnchorProxy", function(group)
    if not group or not group.name then return end
    EnsureAnchor(group.name, group)
    UpdatePrimary()
  end)
end

-- Backup refreshes: groups may exist before the first SyncAnchorProxy, and the
-- set of groups changes on spec/talent swaps and Edit Mode edits.
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
if C_EditMode then eventFrame:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED") end
eventFrame:SetScript("OnEvent", function()
  -- Defer so CDMGroups has (re)built its groups/containers first.
  C_Timer.After(1.0, RefreshAll)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC TABLE: _G.ArcUI_Public
-- ═══════════════════════════════════════════════════════════════════════════
local Public = {
  -- EventRegistry event name a consumer registers for size-change notifications.
  ANCHOR_CHANGED_EVENT = ANCHOR_EVENT,
}

function Public.GetVersion()
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    return C_AddOns.GetAddOnMetadata(ADDON, "Version")
  end
end

-- Array of current ArcUI CDM group names.
function Public.GetGroupNames()
  local t = {}
  local groups = ns.CDMGroups and ns.CDMGroups.groups
  if groups then
    for name in pairs(groups) do t[#t + 1] = name end
  end
  return t
end

-- Stable anchor frame that tracks a group's position/size. SetPoint your own
-- frame to it and register for ANCHOR_CHANGED_EVENT to react to size changes.
function Public.GetGroupAnchor(name)
  if not name then return nil end
  local a = anchors[name]
  if a then return a end
  local group = ns.CDMGroups and ns.CDMGroups.groups and ns.CDMGroups.groups[name]
  if group then return EnsureAnchor(name, group) end
  return nil
end

-- Convenience anchor for the primary group (the "Essential" group if present).
function Public.GetPrimaryAnchor()
  UpdatePrimary()
  return primaryAnchor
end

-- Optional: hand a frame to ArcUI to host inside a group (ArcUI manages its
-- placement/drag/position-saving). opts = { viewerType = "cooldown"|"aura"|
-- "utility", defaultGroup = "<groupName>" }. Most addons want GetGroupAnchor
-- instead, which keeps YOUR frame under YOUR control.
function Public.RegisterFrame(id, frame, opts)
  opts = opts or {}
  if ns.CDMGroups and ns.CDMGroups.RegisterExternalFrame then
    return ns.CDMGroups.RegisterExternalFrame(id, frame, opts.viewerType, opts.defaultGroup)
  end
  return false
end

function Public.UnregisterFrame(id)
  if ns.CDMGroups and ns.CDMGroups.UnregisterExternalFrame then
    return ns.CDMGroups.UnregisterExternalFrame(id)
  end
  return false
end

_G.ArcUI_Public = Public
ns.PublicAPI = Public
