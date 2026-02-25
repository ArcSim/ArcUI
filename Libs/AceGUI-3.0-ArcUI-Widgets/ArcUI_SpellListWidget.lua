-- ===================================================================
-- ArcUI_SpellListWidget.lua
-- Custom AceGUI widget: Interactive spell list for generators/spenders
-- Displays spell entries as icon rows with inline stacks editing and
-- remove buttons. Used in Stack Bar options via dialogControl.
-- ===================================================================

local ADDON, ns = ...

local AceGUI = LibStub and LibStub("AceGUI-3.0")
if not AceGUI then return end

local Type = "ArcUI_SpellList"
local Version = 1

-- Layout constants
local ROW_HEIGHT = 26
local ICON_SIZE = 20
local MAX_ROWS = 10
local BORDER_INSET = 4
local EMPTY_HEIGHT = 30

-- ===================================================================
-- ROW CREATION
-- ===================================================================
local function CreateRow(parent, widget, index)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW_HEIGHT)
  row.entryIdx = index

  -- Hover highlight
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.05)

  -- Spell icon (trimmed)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(ICON_SIZE, ICON_SIZE)
  row.icon:SetPoint("LEFT", 4, 0)
  row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  -- Spell name
  row.nameText = row:CreateFontString(nil, "OVERLAY")
  row.nameText:SetFontObject(GameFontNormal)
  row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.nameText:SetPoint("RIGHT", row, "RIGHT", -80, 0)
  row.nameText:SetJustifyH("LEFT")
  row.nameText:SetWordWrap(false)

  -- Stacks display text (click to edit)
  row.stacksText = row:CreateFontString(nil, "OVERLAY")
  row.stacksText:SetFontObject(GameFontHighlightSmall)
  row.stacksText:SetPoint("RIGHT", row, "RIGHT", -30, 0)
  row.stacksText:SetJustifyH("RIGHT")

  -- Stacks inline edit box (hidden, shown on click)
  row.stacksEdit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
  row.stacksEdit:SetSize(34, 18)
  row.stacksEdit:SetPoint("RIGHT", row, "RIGHT", -28, 0)
  row.stacksEdit:SetAutoFocus(false)
  row.stacksEdit:SetNumeric(true)
  row.stacksEdit:SetMaxLetters(3)
  row.stacksEdit:SetJustifyH("CENTER")
  row.stacksEdit:Hide()

  -- Save stacks on Enter
  row.stacksEdit:SetScript("OnEnterPressed", function(self)
    local newVal = math.max(1, tonumber(self:GetText()) or 1)
    local cfg = ns.CooldownBars and ns.CooldownBars.GetTimerConfig(widget.timerID)
    if cfg then
      local list = (widget.listType == "gen") and cfg.tracking.generators or cfg.tracking.spenders
      local entry = list and list[row.entryIdx]
      if entry then entry.stacks = newVal end
    end
    self:ClearFocus()
    self:Hide()
    row.stacksText:Show()
    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
  end)

  -- Cancel on Escape
  row.stacksEdit:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    self:Hide()
    row.stacksText:Show()
  end)

  -- Also save on focus lost
  row.stacksEdit:SetScript("OnEditFocusLost", function(self)
    if self:IsShown() then
      local newVal = math.max(1, tonumber(self:GetText()) or 1)
      local cfg = ns.CooldownBars and ns.CooldownBars.GetTimerConfig(widget.timerID)
      if cfg then
        local list = (widget.listType == "gen") and cfg.tracking.generators or cfg.tracking.spenders
        local entry = list and list[row.entryIdx]
        if entry then entry.stacks = newVal end
      end
      self:Hide()
      row.stacksText:Show()
      LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
    end
  end)

  -- Remove button (small X icon)
  row.removeBtn = CreateFrame("Button", nil, row)
  row.removeBtn:SetSize(16, 16)
  row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
  row.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
  row.removeBtn:SetScript("OnClick", function()
    local idx = row.entryIdx
    if not idx or not widget.timerID then return end
    if widget.listType == "gen" then
      ns.CooldownBars.RemoveStackGenerator(widget.timerID, idx)
    else
      ns.CooldownBars.RemoveStackSpender(widget.timerID, idx)
    end
    ns.CooldownBars.ForceUpdate(widget.timerID, "timer")
    ns.CooldownBars.ApplyAppearance(widget.timerID, "timer")
    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
  end)
  row.removeBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Remove", 1, 0.3, 0.3)
    GameTooltip:Show()
  end)
  row.removeBtn:SetScript("OnLeave", GameTooltip_Hide)

  -- Click row → toggle inline stacks editor
  row:EnableMouse(true)
  row:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    -- Close any other open editors first
    for i = 1, MAX_ROWS do
      local other = widget.rows[i]
      if other ~= row and other.stacksEdit:IsShown() then
        other.stacksEdit:GetScript("OnEnterPressed")(other.stacksEdit)
      end
    end
    -- Toggle this row's editor
    if row.stacksEdit:IsShown() then
      row.stacksEdit:GetScript("OnEnterPressed")(row.stacksEdit)
    else
      row.stacksText:Hide()
      local cfg = ns.CooldownBars and ns.CooldownBars.GetTimerConfig(widget.timerID)
      if cfg then
        local list = (widget.listType == "gen") and cfg.tracking.generators or cfg.tracking.spenders
        local entry = list and list[row.entryIdx]
        row.stacksEdit:SetText(tostring(entry and entry.stacks or 1))
      end
      row.stacksEdit:Show()
      row.stacksEdit:SetFocus()
      row.stacksEdit:HighlightText()
    end
  end)

  -- Tooltip on name hover
  row:SetScript("OnEnter", function(self)
    local cfg = ns.CooldownBars and ns.CooldownBars.GetTimerConfig(widget.timerID)
    if not cfg then return end
    local list = (widget.listType == "gen") and cfg.tracking.generators or cfg.tracking.spenders
    local entry = list and list[self.entryIdx]
    if entry then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      local name = C_Spell.GetSpellName(entry.spellID) or "Unknown"
      GameTooltip:SetText(name, 1, 1, 1)
      GameTooltip:AddLine("Spell ID: " .. entry.spellID, 0.7, 0.7, 0.7)
      GameTooltip:AddLine("Click to edit stacks", 0.5, 0.8, 1)
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnLeave", GameTooltip_Hide)

  row:Hide()
  return row
end

-- ===================================================================
-- WIDGET METHODS
-- ===================================================================
local methods = {}

function methods:OnAcquire()
  self.timerID = nil
  self.listType = nil
  self:SetHeight(EMPTY_HEIGHT)
end

function methods:OnRelease()
  self.timerID = nil
  self.listType = nil
  for i = 1, MAX_ROWS do
    local row = self.rows[i]
    row.stacksEdit:Hide()
    row.stacksText:Show()
    row:Hide()
  end
end

function methods:SetLabel(text)
  -- Widget draws its own header via the title FontString
  if text and text ~= "" then
    self.titleText:SetText(text)
    self.titleText:Show()
  else
    self.titleText:Hide()
  end
end

function methods:SetText(value)
  -- value = "timerID:gen" or "timerID:sp"
  if not value or value == "" then return end
  local id, lt = value:match("^(%d+):(%a+)$")
  if not id then return end
  self.timerID = tonumber(id)
  self.listType = lt
  self:UpdateDisplay()
end

function methods:SetDisabled(disabled)
  self.disabled = disabled
end

function methods:SetMaxLetters()
  -- no-op (required by AceConfigDialog for input type)
end

function methods:UpdateDisplay()
  local cfg = ns.CooldownBars and ns.CooldownBars.GetTimerConfig(self.timerID)
  if not cfg then return end

  local isGen = (self.listType == "gen")
  local entries = isGen and (cfg.tracking.generators or {}) or (cfg.tracking.spenders or {})
  local numEntries = #entries

  -- Set border color based on type
  if isGen then
    self.border:SetBackdropBorderColor(0.2, 0.7, 0.2, 0.6)
  else
    self.border:SetBackdropBorderColor(0.8, 0.5, 0.1, 0.6)
  end

  -- Update rows
  for i = 1, MAX_ROWS do
    local row = self.rows[i]
    if i <= numEntries then
      local entry = entries[i]
      local spellName = C_Spell.GetSpellName(entry.spellID) or ("|cff888888ID:" .. entry.spellID .. "|r")
      local tex = C_Spell.GetSpellTexture(entry.spellID) or 134400
      local stacks = entry.stacks or 1

      row.icon:SetTexture(tex)
      row.nameText:SetText(spellName)

      local prefix = isGen and "+" or "-"
      local clr = isGen and "|cff88ff88" or "|cffffcc88"
      row.stacksText:SetText(clr .. prefix .. stacks .. "|r")

      row.entryIdx = i
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
      row:SetPoint("RIGHT", self.content, "RIGHT", 0, 0)
      -- Only reset edit state if not currently editing this row
      if not row.stacksEdit:HasFocus() then
        row.stacksEdit:Hide()
        row.stacksText:Show()
      end
      row:Show()
    else
      row.stacksEdit:Hide()
      row.stacksText:Show()
      row:Hide()
    end
  end

  -- Empty state
  if numEntries == 0 then
    self.emptyText:SetText(isGen and "|cff666666No generators added yet|r" or "|cff666666No spenders added yet|r")
    self.emptyText:Show()
  else
    self.emptyText:Hide()
  end

  -- Calculate and set height
  local contentH = math.max(1, numEntries) * ROW_HEIGHT
  local titleH = self.titleText:IsShown() and 20 or 0
  local totalH = contentH + titleH + (BORDER_INSET * 2) + 2
  self:SetHeight(totalH)
end

-- ===================================================================
-- CONSTRUCTOR
-- ===================================================================
local function Constructor()
  local frame = CreateFrame("Frame", nil, UIParent)
  frame:SetHeight(EMPTY_HEIGHT)

  -- Dark bordered container
  local border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  border:SetAllPoints()
  border:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  border:SetBackdropColor(0.06, 0.06, 0.06, 0.75)
  border:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

  -- Optional title (set via SetLabel)
  local titleText = frame:CreateFontString(nil, "OVERLAY")
  titleText:SetFontObject(GameFontNormal)
  titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", BORDER_INSET + 2, -BORDER_INSET)
  titleText:SetJustifyH("LEFT")
  titleText:Hide()

  -- Content area for rows
  local content = CreateFrame("Frame", nil, frame)
  content:SetPoint("TOPLEFT", frame, "TOPLEFT", BORDER_INSET, -BORDER_INSET)
  content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -BORDER_INSET, BORDER_INSET)

  -- Empty state text
  local emptyText = content:CreateFontString(nil, "OVERLAY")
  emptyText:SetFontObject(GameFontDisable)
  emptyText:SetPoint("LEFT", content, "LEFT", 6, 0)
  emptyText:SetJustifyH("LEFT")

  -- Build widget table
  local widget = {
    frame = frame,
    border = border,
    content = content,
    titleText = titleText,
    emptyText = emptyText,
    type = Type,
    rows = {},
  }

  -- Pre-create row frames
  for i = 1, MAX_ROWS do
    widget.rows[i] = CreateRow(content, widget, i)
  end

  -- Apply methods
  for name, func in pairs(methods) do
    widget[name] = func
  end

  return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)