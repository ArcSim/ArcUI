-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Talent Picker Widget
-- v6: WA-style SetScale positioning - uniform scale applied per-button
--     like Blizzard/WA coordinate systems actually work
-- ═══════════════════════════════════════════════════════════════════════════

local addonName, ns = ...
ns.TalentPicker = ns.TalentPicker or {}

local AceGUI = LibStub("AceGUI-3.0")

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local BASE_ICON_SIZE = 32             -- Logical button size (before scale)
local ICON_VISUAL_FACTOR = 0.85       -- Visual icon size = BASE * this (bigger = bigger icons)
local TREE_PADDING = 8
local FRAME_WIDTH = 1200
local FRAME_HEIGHT = 750

local CLASS_TREE_WIDTH = 370
local HERO_TREE_WIDTH = 280
local SPEC_TREE_WIDTH = 460
local TREE_GAP = 10

-- Visual constants
local BORDER_NORMAL = "Interface\\Buttons\\UI-Quickslot2"
local EDGE_SECTION  = "Interface\\Tooltips\\UI-Tooltip-Border"

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local talentCache = {}
local nodePositions = {}

local function SelectionKey(nodeID, entryID)
  if entryID then return nodeID .. ":" .. entryID end
  return nodeID
end

local function ParseSelectionKey(selKey)
  if type(selKey) == "string" then
    local n, e = selKey:match("^(%d+):(%d+)$")
    if n and e then return tonumber(n), tonumber(e) end
  end
  return selKey, nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TALENT DATA
-- ═══════════════════════════════════════════════════════════════════════════

local function ResolveEntryInfo(configID, entryID)
  local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
  if not entryInfo or not entryInfo.definitionID then return nil end
  local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
  if not defInfo then return nil end
  -- Use definition-level overrides first (immune to runtime spell replacement)
  -- Fall back to spell API only if definition doesn't provide overrides
  return {
    spellID = defInfo.spellID,
    name = defInfo.overrideName
        or (defInfo.spellID and C_Spell.GetSpellName(defInfo.spellID))
        or "Unknown",
    icon = defInfo.overrideIcon
        or (defInfo.spellID and C_Spell.GetSpellTexture(defInfo.spellID))
        or 134400,
  }
end

local function GetTalentTreeData()
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return nil end
  local configInfo = C_Traits.GetConfigInfo(configID)
  if not configInfo or not configInfo.treeIDs or #configInfo.treeIDs == 0 then return nil end
  local treeID = configInfo.treeIDs[1]
  local nodes = C_Traits.GetTreeNodes(treeID)

  local td = { configID = configID, treeID = treeID, nodes = {},
    classNodes = {}, specNodes = {}, heroNodes = {}, _pendingNodes = {} }

  for _, nodeID in ipairs(nodes) do
    local ni = C_Traits.GetNodeInfo(configID, nodeID)
    if ni and ni.ID and ni.ID ~= 0 then
      local node = {
        nodeID = nodeID,
        posX = ni.posX or 0, posY = ni.posY or 0,
        type = ni.type,
        activeRank = ni.activeRank or 0,
        isVisible = ni.isVisible ~= false,
        isAvailable = ni.isAvailable,
        isTalented = (ni.activeRank or 0) > 0 and (not ni.subTreeID or ni.subTreeActive == true),
        entryIDs = ni.entryIDs or {},
        activeEntry = ni.activeEntry,
        subTreeID = ni.subTreeID,
        subTreeActive = ni.subTreeActive,
        isChoiceNode = false,
        entries = {},
      }

      if #node.entryIDs > 1 then
        node.isChoiceNode = true
        for idx, eid in ipairs(node.entryIDs) do
          local resolved = ResolveEntryInfo(configID, eid)
          if resolved then
            local isActive = node.activeEntry and node.activeEntry.entryID == eid
            -- Hero tree entries: only active if in the player's chosen subtree
            if isActive and node.subTreeID then
              isActive = node.subTreeActive == true
            end
            table.insert(node.entries, {
              entryID = eid, entryIndex = idx,
              spellID = resolved.spellID, name = resolved.name, icon = resolved.icon,
              isActive = isActive,
            })
            if isActive then
              node.spellID = resolved.spellID; node.name = resolved.name; node.icon = resolved.icon
            end
          end
        end
        if not node.spellID and #node.entries > 0 then
          local e = node.entries[1]
          node.spellID = e.spellID; node.name = e.name; node.icon = e.icon
        end
      else
        local eid = (node.activeEntry and node.activeEntry.entryID) or node.entryIDs[1]
        if eid then
          local resolved = ResolveEntryInfo(configID, eid)
          if resolved then
            node.spellID = resolved.spellID; node.name = resolved.name; node.icon = resolved.icon
          end
        end
      end

      -- Skip nodes with no resolved spell (ghost nodes like 90912, bad entries like 108704)
      if not node.icon or not node.spellID then
        td.nodes[nodeID] = node  -- still track for condition checking
      elseif node.subTreeID then
        table.insert(td.heroNodes, node)
      else
        -- Temporarily hold non-hero nodes; we'll separate class/spec by currency after
        table.insert(td._pendingNodes, node)
      end
      td.nodes[nodeID] = node
    end
  end

  -- Determine class vs spec using node costs (currency-based categorization)
  -- Step 1: Find the spec currency by sampling a clearly-spec node (posX >= 11000)
  local specCurrencyID = nil
  for _, node in ipairs(td._pendingNodes) do
    if node.posX >= 11000 then
      local costs = C_Traits.GetNodeCost(configID, node.nodeID)
      if costs and #costs > 0 then
        specCurrencyID = costs[1].ID
        break
      end
    end
  end

  -- Step 2: Categorize each pending node by its currency
  for _, node in ipairs(td._pendingNodes) do
    local isSpec = false
    if specCurrencyID then
      local costs = C_Traits.GetNodeCost(configID, node.nodeID)
      if costs then
        for _, cost in ipairs(costs) do
          if cost.ID == specCurrencyID then isSpec = true; break end
        end
      end
    else
      -- Fallback if we couldn't identify spec currency: use posX heuristic
      isSpec = node.posX >= 10000
    end

    if isSpec then
      table.insert(td.specNodes, node)
    else
      table.insert(td.classNodes, node)
    end
  end
  td._pendingNodes = nil

  return td
end

local function IsTalentNodeSelected(nodeID)
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return false end
  local ni = C_Traits.GetNodeInfo(configID, nodeID)
  if not ni or (ni.activeRank or 0) == 0 then return false end
  -- Hero tree nodes: must also be in the active subtree
  if ni.subTreeID then return ni.subTreeActive == true end
  return true
end

local function GetTalentNodeInfo(nodeID, entryID)
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return nil end
  local ni = C_Traits.GetNodeInfo(configID, nodeID)
  if not ni or ni.ID == 0 then return nil end
  local info = { nodeID = nodeID, currentRank = ni.activeRank or 0,
    isSelected = (ni.activeRank or 0) > 0 }
  -- Hero tree nodes: must also be in the active subtree
  if ni.subTreeID and info.isSelected then
    info.isSelected = ni.subTreeActive == true
  end
  local resolveID = entryID or (ni.activeEntry and ni.activeEntry.entryID) or (ni.entryIDs and ni.entryIDs[1])
  if entryID then
    info.entryID = entryID
    info.isSelected = info.isSelected and (ni.activeEntry and ni.activeEntry.entryID == entryID)
  end
  if resolveID then
    local resolved = ResolveEntryInfo(configID, resolveID)
    if resolved then info.spellID = resolved.spellID; info.name = resolved.name; info.icon = resolved.icon end
  end
  return info
end

ns.TalentPicker.GetTalentTreeData = GetTalentTreeData
ns.TalentPicker.IsTalentNodeSelected = IsTalentNodeSelected
ns.TalentPicker.GetTalentNodeInfo = GetTalentNodeInfo

-- ═══════════════════════════════════════════════════════════════════════════
-- CHECK TALENT CONDITIONS
-- ═══════════════════════════════════════════════════════════════════════════

function ns.TalentPicker.CheckTalentConditions(talentConditions, matchMode)
  if not talentConditions or #talentConditions == 0 then return true end
  matchMode = matchMode or "all"
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return false end
  for _, cond in ipairs(talentConditions) do
    local nodeID, required, entryID
    if type(cond) == "number" then nodeID = cond; required = true
    else nodeID = cond.nodeID; required = cond.required ~= false; entryID = cond.entryID end
    local ni = C_Traits.GetNodeInfo(configID, nodeID)
    local isSel = false
    if ni then
      local hasRank = (ni.activeRank or 0) > 0
      if ni.subTreeID then
        -- Hero tree node: must have rank AND be in the player's active subtree
        isSel = hasRank and ni.subTreeActive == true
      else
        isSel = hasRank
      end
      if isSel and entryID then
        isSel = ni.activeEntry and ni.activeEntry.entryID == entryID
      end
    end
    if required then
      if matchMode == "all" and not isSel then return false end
      if matchMode == "any" and isSel then return true end
    else
      if matchMode == "all" and isSel then return false end
      if matchMode == "any" and not isSel then return true end
    end
  end
  return matchMode == "all"
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UI: Talent Button
-- ═══════════════════════════════════════════════════════════════════════════

local TalentPickerFrame = nil
local selectedTalents = {}
local onSelectCallback = nil

local function CreateTalentNodeButton(parent, node, entry, choiceOffset)
  local button = CreateFrame("Button", nil, parent)
  button:SetSize(BASE_ICON_SIZE, BASE_ICON_SIZE)

  local dIcon = (entry and entry.icon) or node.icon or 134400
  local dSpellID = (entry and entry.spellID) or node.spellID
  local dName = (entry and entry.name) or node.name or "Unknown"
  local dEntryID = entry and entry.entryID or nil
  local isTalented = (node.activeRank or 0) > 0
  -- Hero tree nodes: only count as talented if in the player's active subtree
  if node.subTreeID and isTalented then
    isTalented = node.subTreeActive == true
  end
  -- Choice entries: only the active entry is talented, not both
  if entry and isTalented then
    isTalented = entry.isActive == true
  end

  -- Background - slightly visible behind icon
  button.bg = button:CreateTexture(nil, "BACKGROUND")
  button.bg:SetAllPoints(); button.bg:SetColorTexture(0, 0, 0, 0.8)

  -- Icon
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetPoint("TOPLEFT", 2, -2); button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  button.icon:SetTexture(dIcon); button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  -- Border frame (separate for nicer look)
  button.border = button:CreateTexture(nil, "OVERLAY")
  button.border:SetPoint("TOPLEFT", -1, 1); button.border:SetPoint("BOTTOMRIGHT", 1, -1)
  button.border:SetTexture(BORDER_NORMAL)
  button.border:SetTexCoord(0.15, 0.85, 0.15, 0.85)

  -- Talented glow ring (subtle bright edge for nodes with points)
  button.talentGlow = button:CreateTexture(nil, "OVERLAY", nil, 2)
  button.talentGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
  button.talentGlow:SetPoint("TOPLEFT", -6, 6)
  button.talentGlow:SetPoint("BOTTOMRIGHT", 6, -6)
  button.talentGlow:SetBlendMode("ADD")
  button.talentGlow:SetAlpha(0.35)
  button.talentGlow:Hide()

  -- Cover glow (condition selection feedback)
  button.cover = button:CreateTexture(nil, "OVERLAY", nil, 3)
  button.cover:SetTexture("interface/buttons/checkbuttonglow")
  button.cover:SetIgnoreParentScale(true)
  button.cover:SetPoint("TOPLEFT", button, "TOPLEFT", -8, 8)
  button.cover:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 8, -8)
  button.cover:SetBlendMode("ADD")
  button.cover:Hide()

  -- X mark lines for excluded state
  button.line1 = nil
  button.line2 = nil

  button.node = node
  button.nodeID = node.nodeID
  button.entryID = dEntryID
  button.displayName = dName
  button.displaySpellID = dSpellID
  button.isChoiceEntry = (entry ~= nil)
  button.entryIsActive = entry and entry.isActive or false
  button.choiceOffset = choiceOffset
  button.selKey = SelectionKey(node.nodeID, dEntryID)
  button.isTalented = isTalented

  -- Set base talented/untalented visual state
  if isTalented then
    button.icon:SetDesaturated(false)
    button.icon:SetAlpha(1)
    button.border:SetVertexColor(0.7, 0.7, 0.7, 1)
    button.talentGlow:Show()
    button.talentGlow:SetVertexColor(0.9, 0.8, 0.5, 1)
  else
    button.icon:SetDesaturated(true)
    button.icon:SetAlpha(0.45)
    button.border:SetVertexColor(0.3, 0.3, 0.3, 1)
    button.talentGlow:Hide()
  end

  -- WA-style visual states: nil=unselected, true=required(green), false=excluded(red)
  function button:UpdateSelection()
    local sel = selectedTalents[self.selKey]
    if sel == true then
      -- Required: green glow
      self.cover:Show()
      self.cover:SetVertexColor(0, 1, 0, 1)
      self.icon:SetDesaturated(false)
      self.icon:SetAlpha(1)
      self.border:SetVertexColor(0, 0.8, 0, 1)
      self.talentGlow:Show()
      self.talentGlow:SetVertexColor(0, 1, 0, 1)
      if self.line1 then self.line1:Hide(); self.line2:Hide() end
    elseif sel == false then
      -- Excluded: red glow + X lines
      self.cover:Show()
      self.cover:SetVertexColor(1, 0, 0, 1)
      self.icon:SetDesaturated(false)
      self.icon:SetAlpha(1)
      self.border:SetVertexColor(0.8, 0, 0, 1)
      self.talentGlow:Show()
      self.talentGlow:SetVertexColor(1, 0, 0, 1)
      if not self.line1 then
        self.line1 = self:CreateLine()
        self.line1:SetColorTexture(1, 0, 0, 1)
        self.line1:SetStartPoint("TOPLEFT", 3, -3)
        self.line1:SetEndPoint("BOTTOMRIGHT", -3, 3)
        self.line1:SetBlendMode("ADD"); self.line1:SetThickness(2)
        self.line2 = self:CreateLine()
        self.line2:SetColorTexture(1, 0, 0, 1)
        self.line2:SetStartPoint("TOPRIGHT", -3, -3)
        self.line2:SetEndPoint("BOTTOMLEFT", 3, 3)
        self.line2:SetBlendMode("ADD"); self.line2:SetThickness(2)
      end
      self.line1:Show(); self.line2:Show()
    else
      -- No condition set: revert to base talented/untalented state
      self.cover:Hide()
      if self.isTalented then
        self.icon:SetDesaturated(false)
        self.icon:SetAlpha(1)
        self.border:SetVertexColor(0.7, 0.7, 0.7, 1)
        self.talentGlow:Show()
        self.talentGlow:SetVertexColor(0.9, 0.8, 0.5, 1)
      else
        self.icon:SetDesaturated(true)
        self.icon:SetAlpha(0.45)
        self.border:SetVertexColor(0.3, 0.3, 0.3, 1)
        self.talentGlow:Hide()
      end
      if self.line1 then self.line1:Hide(); self.line2:Hide() end
    end
  end

  -- WA-style anchor point for choice nodes
  function button:GetAnchorPoint()
    if self.choiceOffset == "left" then return "RIGHT" end
    if self.choiceOffset == "right" then return "LEFT" end
    return "CENTER"
  end

  button:SetScript("OnClick", function(self, mb)
    local cur = selectedTalents[self.selKey]
    if mb == "RightButton" then selectedTalents[self.selKey] = nil
    elseif cur == nil then selectedTalents[self.selKey] = true
    elseif cur == true then selectedTalents[self.selKey] = false
    else selectedTalents[self.selKey] = nil end
    self:UpdateSelection()
    if TalentPickerFrame and TalentPickerFrame.UpdateSummary then TalentPickerFrame:UpdateSummary() end
  end)

  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    -- Always use stored name from definition to avoid spell override issues
    -- (e.g. Soul Immolation being replaced by Spontaneous Immolation at runtime)
    GameTooltip:AddLine(self.displayName or "Unknown", 1, 1, 1)
    if self.displaySpellID then
      local desc = C_Spell.GetSpellDescription(self.displaySpellID)
      if desc and desc ~= "" then
        GameTooltip:AddLine(desc, nil, nil, nil, true)  -- wrap text
      end
    end
    GameTooltip:AddLine(" ")
    local sel = selectedTalents[self.selKey]
    if sel == true then GameTooltip:AddLine("Condition: REQUIRED", 0, 1, 0)
    elseif sel == false then GameTooltip:AddLine("Condition: EXCLUDED", 1, 0, 0)
    else GameTooltip:AddLine("Condition: None", 0.5, 0.5, 0.5) end
    if self.isChoiceEntry then
      GameTooltip:AddLine("|cffffd700Choice Node|r", 1, 0.82, 0)
      GameTooltip:AddLine(self.entryIsActive and "This choice is ACTIVE" or "This choice is NOT active",
        self.entryIsActive and 0 or 0.5, self.entryIsActive and 1 or 0.5, self.entryIsActive and 0 or 0.5)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-Click: Cycle | Right-Click: Clear", 1, 0.82, 0)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  button:SetMotionScriptsWhileDisabled(true)

  return button
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UI: Frame Construction
-- ═══════════════════════════════════════════════════════════════════════════

-- Blizzard spec background atlases (from ClassTalentUtil.lua SpecializationVisuals)
local SpecBackgrounds = {
  -- DK
  [250] = "talents-background-deathknight-blood",
  [251] = "talents-background-deathknight-frost",
  [252] = "talents-background-deathknight-unholy",
  -- DH
  [577] = "talents-background-demonhunter-havoc",
  [581] = "talents-background-demonhunter-vengeance",
  [1480] = "talents-background-demonhunter-devourer",
  -- Druid
  [102] = "talents-background-druid-balance",
  [103] = "talents-background-druid-feral",
  [104] = "talents-background-druid-guardian",
  [105] = "talents-background-druid-restoration",
  -- Evoker
  [1467] = "talents-background-evoker-devastation",
  [1468] = "talents-background-evoker-preservation",
  [1473] = "talents-background-evoker-augmentation",
  -- Hunter
  [253] = "talents-background-hunter-beastmastery",
  [254] = "talents-background-hunter-marksmanship",
  [255] = "talents-background-hunter-survival",
  -- Mage
  [62] = "talents-background-mage-arcane",
  [63] = "talents-background-mage-fire",
  [64] = "talents-background-mage-frost",
  -- Monk
  [268] = "talents-background-monk-brewmaster",
  [269] = "talents-background-monk-windwalker",
  [270] = "talents-background-monk-mistweaver",
  -- Paladin
  [65] = "talents-background-paladin-holy",
  [66] = "talents-background-paladin-protection",
  [70] = "talents-background-paladin-retribution",
  -- Priest
  [256] = "talents-background-priest-discipline",
  [257] = "talents-background-priest-holy",
  [258] = "talents-background-priest-shadow",
  -- Rogue
  [259] = "talents-background-rogue-assassination",
  [260] = "talents-background-rogue-outlaw",
  [261] = "talents-background-rogue-subtlety",
  -- Shaman
  [262] = "talents-background-shaman-elemental",
  [263] = "talents-background-shaman-enhancement",
  [264] = "talents-background-shaman-restoration",
  -- Warlock
  [265] = "talents-background-warlock-affliction",
  [266] = "talents-background-warlock-demonology",
  [267] = "talents-background-warlock-destruction",
  -- Warrior
  [71] = "talents-background-warrior-arms",
  [72] = "talents-background-warrior-fury",
  [73] = "talents-background-warrior-protection",
}

local function GetSpecBackground()
  local specIndex = GetSpecialization()
  if not specIndex then return nil end
  local specID = GetSpecializationInfo(specIndex)
  return specID and SpecBackgrounds[specID]
end

local function CreateTreeSection(parent, title, width, height)
  local s = CreateFrame("Frame", nil, parent)
  s:SetSize(width, height)
  s:SetClipsChildren(true)

  -- Dark base behind everything
  s.darkBg = s:CreateTexture(nil, "BACKGROUND", nil, -2)
  s.darkBg:SetAllPoints()
  s.darkBg:SetColorTexture(0.03, 0.03, 0.05, 0.98)

  -- Atlas background (spec art) — positioned and cropped per section
  s.atlasBg = s:CreateTexture(nil, "BACKGROUND", nil, -1)
  s.atlasBg:SetAllPoints()
  s.atlasBg:SetAlpha(0.35)

  -- Subtle inner border via overlay
  s.borderFrame = CreateFrame("Frame", nil, s, "BackdropTemplate")
  s.borderFrame:SetAllPoints()
  s.borderFrame:SetBackdrop({
    edgeFile = EDGE_SECTION,
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 }
  })
  s.borderFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)

  -- Header bar with gradient feel
  s.headerBg = s:CreateTexture(nil, "ARTWORK")
  s.headerBg:SetPoint("TOPLEFT", 2, -2)
  s.headerBg:SetPoint("TOPRIGHT", -2, -2)
  s.headerBg:SetHeight(18)
  s.headerBg:SetColorTexture(0.12, 0.12, 0.15, 0.9)

  -- Header bottom accent line
  s.headerLine = s:CreateTexture(nil, "ARTWORK", nil, 1)
  s.headerLine:SetPoint("TOPLEFT", s.headerBg, "BOTTOMLEFT")
  s.headerLine:SetPoint("TOPRIGHT", s.headerBg, "BOTTOMRIGHT")
  s.headerLine:SetHeight(1)
  s.headerLine:SetColorTexture(0.4, 0.4, 0.4, 0.5)

  s.title = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  s.title:SetPoint("TOP", 0, -4); s.title:SetText(title)

  -- Content frame where buttons live
  s.content = CreateFrame("Frame", nil, s)
  s.content:SetPoint("TOPLEFT", 5, -22)
  s.content:SetPoint("BOTTOMRIGHT", -5, 5)
  s.content:SetClipsChildren(true)

  -- Method to set the atlas background
  function s:SetSectionAtlas(atlas, portion)
    -- portion: "left", "right", or "center"
    -- We position a full-width atlas texture and let ClipsChildren crop to our section
    if atlas and C_Texture.GetAtlasInfo(atlas) then
      self.atlasBg:SetAtlas(atlas, true)  -- useAtlasSize=true for native dimensions
      self.atlasBg:SetAlpha(0.3)
      self.atlasBg:ClearAllPoints()

      -- The atlas is the full talent frame width. We anchor it so our section
      -- shows only the relevant portion, and ClipsChildren handles the crop.
      local atlasInfo = C_Texture.GetAtlasInfo(atlas)
      local atlasW = atlasInfo and atlasInfo.width or 1920
      local atlasH = atlasInfo and atlasInfo.height or 1080
      local sW = self:GetWidth()
      local sH = self:GetHeight()
      -- Scale atlas to fill the section height
      local scale = sH / atlasH
      local scaledW = atlasW * scale

      self.atlasBg:SetSize(scaledW, sH)
      if portion == "left" then
        self.atlasBg:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
      elseif portion == "right" then
        self.atlasBg:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
      else
        self.atlasBg:SetPoint("CENTER", self, "CENTER", 0, 0)
      end
    else
      -- Fallback: dark tinted bg
      self.atlasBg:ClearAllPoints()
      self.atlasBg:SetAllPoints()
      self.atlasBg:SetColorTexture(0.05, 0.05, 0.08, 0.5)
    end
  end

  -- Method to set hero backplate
  function s:SetHeroBackplate()
    local heroAtlas = "talents-heroclass-backplate-full-expanded"
    if C_Texture.GetAtlasInfo(heroAtlas) then
      self.atlasBg:ClearAllPoints()
      self.atlasBg:SetAtlas(heroAtlas, false)
      self.atlasBg:SetAllPoints()
      self.atlasBg:SetAlpha(0.4)
    end
  end

  return s
end

-- Get class color for the local player
local function GetPlayerClassColor()
  local _, className = UnitClass("player")
  local color = RAID_CLASS_COLORS[className]
  if color then return color.r, color.g, color.b end
  return 1, 0.82, 0
end

-- Get active hero tree names
local function GetHeroTreeNames()
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return nil end
  local heroIDs = C_ClassTalents.GetHeroTalentSpecsForClassSpec and C_ClassTalents.GetHeroTalentSpecsForClassSpec()
  if not heroIDs then return nil end
  local names = {}
  for _, stID in ipairs(heroIDs) do
    local info = C_Traits.GetSubTreeInfo(configID, stID)
    if info and info.name then table.insert(names, info.name) end
  end
  return names
end

local function CreateTalentPickerFrame()
  if TalentPickerFrame then return TalentPickerFrame end

  local f = CreateFrame("Frame", "ArcUITalentPickerFrame", UIParent, "BackdropTemplate")
  f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG"); f:SetFrameLevel(100)
  f:EnableMouse(true); f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  f:SetScript("OnShow", function(self) self:Raise() end)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
  })
  f:SetBackdropColor(0.08, 0.08, 0.1, 1)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOP", 0, -20)
  f.title:SetText("|cff00ccffArcUI|r - Talent Conditions")

  f.closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.closeBtn:SetPoint("TOPRIGHT", -5, -5)
  f.closeBtn:SetScript("OnClick", function() f:Hide() end)

  f.instructions = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.instructions:SetPoint("TOP", 0, -42)
  f.instructions:SetText("|cffffd700Click talents to set conditions. |cff00ff00Green = Required|r, |cffff0000Red = Excluded|r")

  f.treesContainer = CreateFrame("Frame", nil, f)
  f.treesContainer:SetPoint("TOPLEFT", 20, -65)
  f.treesContainer:SetPoint("BOTTOMRIGHT", -20, 100)

  -- Get class/spec info for section titles
  local _, className = UnitClass("player")
  local localClassName = UnitClass("player")  -- localized name
  local specID = GetSpecialization()
  local _, specName = GetSpecializationInfo(specID or 1)
  local cr, cg, cb = GetPlayerClassColor()
  local specAtlas = GetSpecBackground()

  local treeH = FRAME_HEIGHT - 180
  f.classSection = CreateTreeSection(f.treesContainer, localClassName or "CLASS", CLASS_TREE_WIDTH, treeH)
  f.classSection:SetPoint("TOPLEFT", 0, 0)
  f.classSection.title:SetTextColor(cr, cg, cb)
  f.classSection.headerBg:SetColorTexture(cr * 0.15, cg * 0.15, cb * 0.15, 0.9)
  f.classSection.headerLine:SetColorTexture(cr * 0.4, cg * 0.4, cb * 0.4, 0.5)
  f.classSection.borderFrame:SetBackdropBorderColor(cr * 0.5, cg * 0.5, cb * 0.5, 0.6)
  f.classSection:SetSectionAtlas(specAtlas, "left")

  f.heroSection = CreateTreeSection(f.treesContainer, "HERO", HERO_TREE_WIDTH, treeH)
  f.heroSection:SetPoint("LEFT", f.classSection, "RIGHT", TREE_GAP, 0)
  f.heroSection.title:SetTextColor(0.9, 0.8, 0.5)
  f.heroSection.headerBg:SetColorTexture(0.15, 0.12, 0.05, 0.9)
  f.heroSection.headerLine:SetColorTexture(0.5, 0.4, 0.15, 0.5)
  f.heroSection.borderFrame:SetBackdropBorderColor(0.5, 0.4, 0.15, 0.6)
  f.heroSection:SetHeroBackplate()

  f.specSection = CreateTreeSection(f.treesContainer, specName or "SPEC", SPEC_TREE_WIDTH, treeH)
  f.specSection:SetPoint("LEFT", f.heroSection, "RIGHT", TREE_GAP, 0)
  f.specSection.title:SetTextColor(cr, cg, cb)
  f.specSection.headerBg:SetColorTexture(cr * 0.15, cg * 0.15, cb * 0.15, 0.9)
  f.specSection.headerLine:SetColorTexture(cr * 0.4, cg * 0.4, cb * 0.4, 0.5)
  f.specSection.borderFrame:SetBackdropBorderColor(cr * 0.5, cg * 0.5, cb * 0.5, 0.6)
  f.specSection:SetSectionAtlas(specAtlas, "right")

  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.summary:SetPoint("BOTTOMLEFT", 25, 70)
  f.summary:SetWidth(700); f.summary:SetJustifyH("LEFT")
  f.summary:SetText("|cff888888No conditions set - bar will always show|r")

  f.matchModeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.matchModeLabel:SetPoint("BOTTOMLEFT", 25, 42)
  f.matchModeLabel:SetText("|cffffd700Match Mode:|r")

  f.matchModeAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.matchModeAll:SetSize(70, 22); f.matchModeAll:SetPoint("LEFT", f.matchModeLabel, "RIGHT", 10, 0)
  f.matchModeAll:SetText("ALL")
  f.matchModeAll:SetScript("OnClick", function()
    f.matchMode = "all"; f.matchModeAll:SetButtonState("PUSHED", true); f.matchModeAny:SetButtonState("NORMAL")
  end)
  f.matchModeAny = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.matchModeAny:SetSize(70, 22); f.matchModeAny:SetPoint("LEFT", f.matchModeAll, "RIGHT", 5, 0)
  f.matchModeAny:SetText("ANY")
  f.matchModeAny:SetScript("OnClick", function()
    f.matchMode = "any"; f.matchModeAny:SetButtonState("PUSHED", true); f.matchModeAll:SetButtonState("NORMAL")
  end)
  f.matchMode = "all"

  f.clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.clearBtn:SetSize(90, 25); f.clearBtn:SetPoint("BOTTOMRIGHT", -130, 35)
  f.clearBtn:SetText("Clear All")
  f.clearBtn:SetScript("OnClick", function()
    wipe(selectedTalents); f:RefreshNodes(); f:UpdateSummary()
  end)

  f.saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.saveBtn:SetSize(90, 25); f.saveBtn:SetPoint("BOTTOMRIGHT", -25, 35)
  f.saveBtn:SetText("Save")
  f.saveBtn:SetScript("OnClick", function()
    if onSelectCallback then
      local conditions = {}
      for selKey, req in pairs(selectedTalents) do
        local nID, eID = ParseSelectionKey(selKey)
        if nID then
          local c = { nodeID = nID, required = req }
          if eID then c.entryID = eID end
          table.insert(conditions, c)
        end
      end
      onSelectCallback(conditions, f.matchMode)
    end
    f:Hide()
  end)

  f.nodeButtons = {}

  function f:UpdateSummary()
    local req, exc = {}, {}
    for selKey, state in pairs(selectedTalents) do
      local nID, eID = ParseSelectionKey(selKey)
      local info = GetTalentNodeInfo(nID, eID)
      local name = info and info.name or ("Node " .. tostring(nID))
      if state == true then table.insert(req, name)
      elseif state == false then table.insert(exc, name) end
    end
    local text = ""
    if #req > 0 then text = "|cff00ff00Required:|r " .. table.concat(req, ", ") end
    if #exc > 0 then
      if text ~= "" then text = text .. "  " end
      text = text .. "|cffff0000Excluded:|r " .. table.concat(exc, ", ")
    end
    if text == "" then text = "|cff888888No conditions set - bar will always show|r" end
    self.summary:SetText(text)
  end

  function f:RefreshNodes()
    for _, btn in ipairs(self.nodeButtons) do
      if btn.UpdateSelection then btn:UpdateSelection() end
    end
  end

  -- ════════════════════════════════════════════════════════════════════
  -- POPULATE - WA-style SetScale positioning
  -- ════════════════════════════════════════════════════════════════════
  function f:PopulateTalents()
    for _, btn in ipairs(self.nodeButtons) do btn:Hide(); btn:ClearAllPoints() end
    wipe(self.nodeButtons)

    local td = GetTalentTreeData()
    if not td then return end

    -- Refresh section titles with current class/spec/hero names
    local _, className = UnitClass("player")
    local localClassName = UnitClass("player")
    local specID = GetSpecialization()
    local _, specName = GetSpecializationInfo(specID or 1)
    local cr, cg, cb = GetPlayerClassColor()
    local specAtlas = GetSpecBackground()

    self.classSection.title:SetText(localClassName or "CLASS")
    self.classSection.title:SetTextColor(cr, cg, cb)
    self.classSection.headerBg:SetColorTexture(cr * 0.15, cg * 0.15, cb * 0.15, 0.9)
    self.classSection.headerLine:SetColorTexture(cr * 0.4, cg * 0.4, cb * 0.4, 0.5)
    self.classSection.borderFrame:SetBackdropBorderColor(cr * 0.5, cg * 0.5, cb * 0.5, 0.6)
    self.classSection:SetSectionAtlas(specAtlas, "left")

    local heroNames = GetHeroTreeNames()
    if heroNames and #heroNames > 0 then
      self.heroSection.title:SetText(table.concat(heroNames, " / "))
    else
      self.heroSection.title:SetText("HERO")
    end
    self.heroSection:SetHeroBackplate()

    self.specSection.title:SetText(specName or "SPEC")
    self.specSection.title:SetTextColor(cr, cg, cb)
    self.specSection.headerBg:SetColorTexture(cr * 0.15, cg * 0.15, cb * 0.15, 0.9)
    self.specSection.headerLine:SetColorTexture(cr * 0.4, cg * 0.4, cb * 0.4, 0.5)
    self.specSection.borderFrame:SetBackdropBorderColor(cr * 0.5, cg * 0.5, cb * 0.5, 0.6)
    self.specSection:SetSectionAtlas(specAtlas, "right")

    -- ── Position a set of nodes into a container using WA's approach ──
    -- 1. Divide raw positions by 10 → "display units"
    -- 2. Subtract minimums to zero-base
    -- 3. Calculate uniform scale to fit container
    -- 4. Each button: SetScale(scale), SetSize adjusted for scale
    -- 5. SetPoint at display coordinates (scale handles the mapping)
    local function PositionTree(nodes, container, containerWidth, containerHeight, isHeroSection)
      if #nodes == 0 then return end

      -- Filter visible nodes with valid icons
      local visible = {}
      for _, node in ipairs(nodes) do
        if node.isVisible and node.icon and node.spellID then
          table.insert(visible, node)
        end
      end
      if #visible == 0 then return end

      if isHeroSection then
        -- Group hero nodes by subTreeID
        local trees, allSTs = {}, {}
        for _, node in ipairs(visible) do
          local st = node.subTreeID or 0
          if not trees[st] then trees[st] = {}; table.insert(allSTs, st) end
          table.insert(trees[st], node)
        end

        -- C_ClassTalents.GetHeroTalentSpecsForClassSpec() returns exactly which
        -- 2 subtree IDs are available for the current spec. This is THE answer.
        local allowedSTs = {}
        if C_ClassTalents.GetHeroTalentSpecsForClassSpec then
          local specHeroTrees = C_ClassTalents.GetHeroTalentSpecsForClassSpec()
          if specHeroTrees then
            for _, stID in ipairs(specHeroTrees) do
              allowedSTs[stID] = true
            end
          end
        end

        -- Fallback: if API not available, show all
        if next(allowedSTs) == nil then
          for _, stID in ipairs(allSTs) do allowedSTs[stID] = true end
        end

        local order = {}
        for _, stID in ipairs(allSTs) do
          if allowedSTs[stID] then table.insert(order, stID) end
        end
        table.sort(order)

        local nTrees = #order
        local gap = 15
        local halfH = (containerHeight - gap * (nTrees - 1)) / nTrees

        for ti, st in ipairs(order) do
          local tn = trees[st]
          local minX, maxX, minY, maxY = 99999, -99999, 99999, -99999
          for _, n in ipairs(tn) do
            local dx, dy = n.posX / 10, n.posY / 10
            minX = math.min(minX, dx); maxX = math.max(maxX, dx)
            minY = math.min(minY, dy); maxY = math.max(maxY, dy)
          end
          local rX = maxX - minX; local rY = maxY - minY
          if rX == 0 then rX = 1 end; if rY == 0 then rY = 1 end

          -- Scale to fit this sub-section
          local availW = containerWidth - TREE_PADDING * 2
          local availH = halfH - TREE_PADDING * 2
          local treeScale = math.min(availW / (rX + BASE_ICON_SIZE), availH / (rY + BASE_ICON_SIZE))

          -- Scaled dimensions
          local scaledW = rX * treeScale
          local scaledH = rY * treeScale

          -- Center within this half
          local baseY = (ti - 1) * (halfH + gap)
          local offX = TREE_PADDING + (availW - scaledW) / 2
          local offY = baseY + TREE_PADDING + (availH - scaledH) / 2

          -- Compute visual button size
          local visualSize = BASE_ICON_SIZE * ICON_VISUAL_FACTOR

          for _, node in ipairs(tn) do
            local dx = (node.posX / 10 - minX) * treeScale + offX
            local dy = (node.posY / 10 - minY) * treeScale + offY

            if node.isChoiceNode and #node.entries > 1 then
              for idx, entry in ipairs(node.entries) do
                local btn = CreateTalentNodeButton(container, node, entry, idx == 1 and "left" or "right")
                btn:SetSize(visualSize, visualSize)
                btn:SetPoint(btn:GetAnchorPoint(), container, "TOPLEFT", dx, -dy)
                btn:UpdateSelection()
                table.insert(self.nodeButtons, btn)
              end
            else
              local btn = CreateTalentNodeButton(container, node, nil, nil)
              btn:SetSize(visualSize, visualSize)
              btn:SetPoint("CENTER", container, "TOPLEFT", dx, -dy)
              btn:UpdateSelection()
              table.insert(self.nodeButtons, btn)
            end
          end
        end
        return
      end

      -- ── Standard class/spec tree ──
      -- Step 1: Convert to display units (divide by 10), find bounds
      local minX, maxX, minY, maxY = 99999, -99999, 99999, -99999
      for _, node in ipairs(visible) do
        local dx, dy = node.posX / 10, node.posY / 10
        minX = math.min(minX, dx); maxX = math.max(maxX, dx)
        minY = math.min(minY, dy); maxY = math.max(maxY, dy)
      end

      local rangeX = maxX - minX
      local rangeY = maxY - minY
      if rangeX == 0 then rangeX = 1 end
      if rangeY == 0 then rangeY = 1 end

      -- Step 2: Calculate uniform scale
      -- Available space (container minus padding on each side, minus room for half-icon on edges)
      local availW = containerWidth - TREE_PADDING * 2
      local availH = containerHeight - TREE_PADDING * 2
      local treeScale = math.min(availW / (rangeX + BASE_ICON_SIZE), availH / (rangeY + BASE_ICON_SIZE))

      -- Step 3: Scaled tree dimensions, center in container
      local scaledW = rangeX * treeScale
      local scaledH = rangeY * treeScale
      local offX = TREE_PADDING + (availW - scaledW) / 2
      local offY = TREE_PADDING + (availH - scaledH) / 2

      -- Step 4: Visual button size
      local visualSize = BASE_ICON_SIZE * ICON_VISUAL_FACTOR

      -- Step 5: Place each button
      for _, node in ipairs(visible) do
        local dx = (node.posX / 10 - minX) * treeScale + offX
        local dy = (node.posY / 10 - minY) * treeScale + offY

        if node.isChoiceNode and #node.entries > 1 then
          for idx, entry in ipairs(node.entries) do
            local btn = CreateTalentNodeButton(container, node, entry, idx == 1 and "left" or "right")
            btn:SetSize(visualSize, visualSize)
            btn:SetPoint(btn:GetAnchorPoint(), container, "TOPLEFT", dx, -dy)
            btn:UpdateSelection()
            table.insert(self.nodeButtons, btn)
          end
        else
          local btn = CreateTalentNodeButton(container, node, nil, nil)
          btn:SetSize(visualSize, visualSize)
          btn:SetPoint("CENTER", container, "TOPLEFT", dx, -dy)
          btn:UpdateSelection()
          table.insert(self.nodeButtons, btn)
        end
      end
    end

    local cW = self.classSection.content:GetWidth() or (CLASS_TREE_WIDTH - 10)
    local cH = self.classSection.content:GetHeight() or (FRAME_HEIGHT - 200)
    local hW = self.heroSection.content:GetWidth() or (HERO_TREE_WIDTH - 10)
    local hH = self.heroSection.content:GetHeight() or (FRAME_HEIGHT - 200)
    local sW = self.specSection.content:GetWidth() or (SPEC_TREE_WIDTH - 10)
    local sH = self.specSection.content:GetHeight() or (FRAME_HEIGHT - 200)

    PositionTree(td.classNodes, self.classSection.content, cW, cH, false)
    PositionTree(td.heroNodes,  self.heroSection.content,  hW, hH, true)
    PositionTree(td.specNodes,  self.specSection.content,  sW, sH, false)
  end

  f:Hide()
  TalentPickerFrame = f
  return f
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

function ns.TalentPicker.OpenPicker(existingConditions, matchMode, callback)
  local frame = CreateTalentPickerFrame()
  wipe(selectedTalents)
  if existingConditions then
    for _, cond in ipairs(existingConditions) do
      if cond.nodeID then
        selectedTalents[SelectionKey(cond.nodeID, cond.entryID)] = cond.required
      end
    end
  end
  frame.matchMode = matchMode or "all"
  if frame.matchMode == "all" then
    frame.matchModeAll:SetButtonState("PUSHED", true); frame.matchModeAny:SetButtonState("NORMAL")
  else
    frame.matchModeAny:SetButtonState("PUSHED", true); frame.matchModeAll:SetButtonState("NORMAL")
  end
  onSelectCallback = callback
  frame:PopulateTalents()
  frame:UpdateSummary()
  frame:Show()
end

function ns.TalentPicker.ClosePicker()
  if TalentPickerFrame then TalentPickerFrame:Hide() end
end

function ns.TalentPicker.GetConditionSummary(conditions, matchMode)
  if not conditions or #conditions == 0 then return "|cff888888No talent conditions|r" end
  local req, exc = {}, {}
  for _, c in ipairs(conditions) do
    local info = GetTalentNodeInfo(c.nodeID, c.entryID)
    local name = info and info.name or ("Node " .. c.nodeID)
    if c.required ~= false then table.insert(req, name) else table.insert(exc, name) end
  end
  local parts = {}
  if #req > 0 then table.insert(parts, "|cff00ff00Req:|r " .. table.concat(req, ", ")) end
  if #exc > 0 then table.insert(parts, "|cffff0000Not:|r " .. table.concat(exc, ", ")) end
  return table.concat(parts, " ") .. (matchMode == "any" and " |cffffd700(ANY)|r" or "")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENTS
-- ═══════════════════════════════════════════════════════════════════════════

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
eventFrame:SetScript("OnEvent", function()
  wipe(talentCache); wipe(nodePositions)
  if TalentPickerFrame and TalentPickerFrame:IsShown() then
    TalentPickerFrame:PopulateTalents(); TalentPickerFrame:RefreshNodes()
  end
  C_Timer.After(0.2, function()
    local r = LibStub and LibStub("AceConfigRegistry-3.0", true)
    if r then r:NotifyChange("ArcUI") end
  end)
end)