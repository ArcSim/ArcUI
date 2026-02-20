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
  return {
    spellID = defInfo.spellID,
    name = defInfo.overrideName or (defInfo.spellID and C_Spell.GetSpellName(defInfo.spellID)) or "Unknown",
    icon = defInfo.overrideIcon or (defInfo.spellID and C_Spell.GetSpellTexture(defInfo.spellID)) or 134400,
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
    classNodes = {}, specNodes = {}, heroNodes = {} }

  for _, nodeID in ipairs(nodes) do
    local ni = C_Traits.GetNodeInfo(configID, nodeID)
    if ni and ni.ID and ni.ID ~= 0 then
      local node = {
        nodeID = nodeID,
        posX = ni.posX or 0, posY = ni.posY or 0,
        type = ni.type,
        activeRank = ni.activeRank or 0,
        isVisible = ni.isVisible ~= false,
        isTalented = (ni.activeRank or 0) > 0,
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
          node.spellID = node.entries[1].spellID; node.name = node.entries[1].name; node.icon = node.entries[1].icon
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

      if node.subTreeID then
        table.insert(td.heroNodes, node)
      elseif node.posX < 10000 then
        table.insert(td.classNodes, node)
      else
        table.insert(td.specNodes, node)
      end
      td.nodes[nodeID] = node
    end
  end
  return td
end

local function IsTalentNodeSelected(nodeID)
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return false end
  local ni = C_Traits.GetNodeInfo(configID, nodeID)
  return ni and (ni.activeRank or 0) > 0
end

local function GetTalentNodeInfo(nodeID, entryID)
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return nil end
  local ni = C_Traits.GetNodeInfo(configID, nodeID)
  if not ni or ni.ID == 0 then return nil end
  local info = { nodeID = nodeID, currentRank = ni.activeRank or 0,
    isSelected = (ni.activeRank or 0) > 0 }
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
      isSel = ni.subTreeID and (hasRank and ni.subTreeActive == true) or hasRank
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

  button.bg = button:CreateTexture(nil, "BACKGROUND")
  button.bg:SetAllPoints(); button.bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)

  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetPoint("TOPLEFT", 2, -2); button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  button.icon:SetTexture(dIcon); button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  button.border = button:CreateTexture(nil, "OVERLAY")
  button.border:SetPoint("TOPLEFT", -1, 1); button.border:SetPoint("BOTTOMRIGHT", 1, -1)
  button.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  button.border:SetTexCoord(0.15, 0.85, 0.15, 0.85)
  button.border:SetVertexColor(0.4, 0.4, 0.4, 1)

  -- Cover glow (like WA's checkbuttonglow)
  button.cover = button:CreateTexture(nil, "OVERLAY", nil, 1)
  button.cover:SetTexture("interface/buttons/checkbuttonglow")
  button.cover:SetIgnoreParentScale(true)
  button.cover:SetPoint("TOPLEFT", button, "TOPLEFT", -8, 8)
  button.cover:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 8, -8)
  button.cover:SetBlendMode("ADD")
  button.cover:Hide()

  -- X mark lines for excluded state
  button.line1 = nil
  button.line2 = nil

  button.icon:SetDesaturated(true)
  button.icon:SetAlpha(0.6)

  button.node = node
  button.nodeID = node.nodeID
  button.entryID = dEntryID
  button.displayName = dName
  button.displaySpellID = dSpellID
  button.isChoiceEntry = (entry ~= nil)
  button.entryIsActive = entry and entry.isActive or false
  button.choiceOffset = choiceOffset
  button.selKey = SelectionKey(node.nodeID, dEntryID)

  -- WA-style visual states: nil=unselected, true=required(yellow/green), false=excluded(red)
  function button:UpdateSelection()
    local sel = selectedTalents[self.selKey]
    if sel == true then
      -- Required: green/yellow glow
      self.cover:Show()
      self.cover:SetVertexColor(0, 1, 0, 1)
      self.icon:SetDesaturated(false)
      self.icon:SetAlpha(1)
      self.border:SetVertexColor(0, 0.8, 0, 1)
      if self.line1 then self.line1:Hide(); self.line2:Hide() end
    elseif sel == false then
      -- Excluded: red glow + X lines
      self.cover:Show()
      self.cover:SetVertexColor(1, 0, 0, 1)
      self.icon:SetDesaturated(false)
      self.icon:SetAlpha(1)
      self.border:SetVertexColor(0.8, 0, 0, 1)
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
      -- Unselected: desaturated
      self.cover:Hide()
      self.icon:SetDesaturated(true)
      self.icon:SetAlpha(0.6)
      self.border:SetVertexColor(0.4, 0.4, 0.4, 1)
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
    if self.displaySpellID then
      GameTooltip:SetSpellByID(self.displaySpellID)
    else
      GameTooltip:AddLine(self.displayName or "Unknown", 1, 1, 1)
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

local function CreateTreeSection(parent, title, width, height)
  local s = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  s:SetSize(width, height)
  s:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 }
  })
  s:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)
  s.title = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  s.title:SetPoint("TOP", 0, -5); s.title:SetText(title); s.title:SetTextColor(1, 0.82, 0)
  -- Content frame where buttons live - clip children to prevent overflow
  s.content = CreateFrame("Frame", nil, s)
  s.content:SetPoint("TOPLEFT", 5, -20)
  s.content:SetPoint("BOTTOMRIGHT", -5, 5)
  s.content:SetClipsChildren(true)
  return s
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

  local treeH = FRAME_HEIGHT - 180
  f.classSection = CreateTreeSection(f.treesContainer, "CLASS", CLASS_TREE_WIDTH, treeH)
  f.classSection:SetPoint("TOPLEFT", 0, 0)
  f.heroSection = CreateTreeSection(f.treesContainer, "HERO", HERO_TREE_WIDTH, treeH)
  f.heroSection:SetPoint("LEFT", f.classSection, "RIGHT", TREE_GAP, 0)
  f.specSection = CreateTreeSection(f.treesContainer, "SPEC", SPEC_TREE_WIDTH, treeH)
  f.specSection:SetPoint("LEFT", f.heroSection, "RIGHT", TREE_GAP, 0)

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

    -- ── Position a set of nodes into a container using WA's approach ──
    -- 1. Divide raw positions by 10 → "display units"
    -- 2. Subtract minimums to zero-base
    -- 3. Calculate uniform scale to fit container
    -- 4. Each button: SetScale(scale), SetSize adjusted for scale
    -- 5. SetPoint at display coordinates (scale handles the mapping)
    local function PositionTree(nodes, container, containerWidth, containerHeight, isHeroSection)
      if #nodes == 0 then return end

      -- Filter visible nodes and collect display positions
      local visible = {}
      for _, node in ipairs(nodes) do
        if node.isVisible and node.icon then
          table.insert(visible, node)
        end
      end
      if #visible == 0 then return end

      if isHeroSection then
        -- Split hero trees by subTreeID, stack top/bottom
        local trees, order = {}, {}
        for _, node in ipairs(visible) do
          local st = node.subTreeID or 0
          if not trees[st] then trees[st] = {}; table.insert(order, st) end
          table.insert(trees[st], node)
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

    local _, className = UnitClass("player")
    local specID = GetSpecialization()
    local _, specName = GetSpecializationInfo(specID)
    self.classSection.title:SetText(className or "CLASS")
    self.specSection.title:SetText(specName or "SPEC")
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