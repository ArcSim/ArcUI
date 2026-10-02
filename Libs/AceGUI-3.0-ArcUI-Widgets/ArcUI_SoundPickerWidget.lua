-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_LSMSound: ArcUI's OWN sound picker (AceGUI widget, dialogControl =
-- "ArcUI_LSMSound"). Same look and API as LibSharedMedia's LSM30_Sound, but
-- the open list is VIRTUAL: a fixed handful of row frames repainted as you
-- scroll, instead of one frame per sound.
--
-- Why it exists (user report, 2026-09-25): with 3-4 SharedMedia packs the
-- stock LSM30_Sound froze the game ~10s on open - it builds a Button + two
-- speaker textures + a FontString for EVERY sound and chains their anchors
-- one row at a time. Thousands of sounds = thousands of frames.
--
-- Why a separate type instead of patching LSM30_Sound: that widget is SHARED.
-- AceGUI runs the highest registered version for every addon on the client,
-- so a patched copy silently replaces every other addon's sound picker too.
-- Arc's rule: ArcUI fixes must never reach other addons. The bundled
-- AceGUI-3.0-SharedMediaWidgets stays byte-for-byte stock (version 13).
--
-- Keeps ArcUI's old patch behaviour: "None" pinned to the top of the list.
-- The closed box reuses AGSMW:GetBaseFrame (read-only use of the shared lib;
-- nothing in it is modified).
-- ═══════════════════════════════════════════════════════════════════════════

local AceGUI = LibStub("AceGUI-3.0")
local Media = LibStub("LibSharedMedia-3.0")
local AGSMW = LibStub("AceGUISharedMediaWidgets-1.0")

local Type, Version = "ArcUI_LSMSound", 1
if (AceGUI:GetWidgetVersion(Type) or 0) >= Version then return end

local ROW_H = 18

local frameBackdrop = {
    bgFile = [[Interface\DialogFrame\UI-DialogBox-Background-Dark]],
    edgeFile = [[Interface\DialogFrame\UI-DialogBox-Border]],
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 9 },
}
local sliderBackdrop = {
    bgFile = [[Interface\Buttons\UI-SliderBar-Background]],
    edgeFile = [[Interface\Buttons\UI-SliderBar-Border]],
    tile = true, edgeSize = 8, tileSize = 8,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- ── helpers ────────────────────────────────────────────────────────────────
-- The list is name -> path (the picker shows NAMES, the value previews).
local function PlayName(list, name)
    if not name then return end
    local v = list and list[name]
    PlaySoundFile((v and v ~= name) and v or Media:Fetch("sound", name), "Master")
end

-- Sorted names, "None" first, case-insensitive. Upper-cased keys are built
-- once per open (not per comparison) so thousands of names sort quickly.
local function SortedNames(list)
    local names, keys = {}, {}
    for k in pairs(list or {}) do
        if type(k) == "string" then
            names[#names + 1] = k
            keys[k] = k:upper()
        end
    end
    table.sort(names, function(a, b)
        if a == "None" then return b ~= "None" end
        if b == "None" then return false end
        local ka, kb = keys[a], keys[b]
        if ka ~= kb then return ka < kb end
        return a < b
    end)
    return names
end

-- ── the ONE shared popup (only one picker is ever open) ────────────────────
local popup

local function Paint(p)
    local owner = p.owner
    if not owner then return end
    for i = 1, #p.rows do
        local row = p.rows[i]
        local name = (i <= p.visible) and p.names[p.offset + i] or nil
        if name then
            row.name = name
            row.text:SetText(name)
            row.check:SetShown(name == owner.value)
            row:Show()
        else
            row.name = nil
            row:Hide()
        end
    end
end

local function SetOffset(p, off)
    local maxOff = math.max(0, #p.names - p.visible)
    off = math.floor((off or 0) + 0.5)
    if off < 0 then off = 0 elseif off > maxOff then off = maxOff end
    p.offset = off
    if p.slider:IsShown() and math.floor(p.slider:GetValue() + 0.5) ~= off then
        p.slider:SetValue(off)   -- OnValueChanged sees the same offset: no double paint
    end
    Paint(p)
end

local function ClosePopup(owner)
    if not popup then return end
    if owner and popup.owner ~= owner then return end
    popup:Hide()
    popup.owner = nil
    popup.names = {}
end

local function Row_OnClick(row)
    local p = row.popup
    local owner = p.owner
    local name = row.name
    ClosePopup()
    if owner and name then owner:Fire("OnValueChanged", name) end
end

local function RowSpeaker_OnClick(btn)
    local p = btn.row.popup
    PlayName(p.owner and p.owner.list, btn.row.name)
end

local function CreateRow(p, i)
    local row = CreateFrame("Button", nil, p)
    row.popup = p
    row:SetHeight(ROW_H)
    row:SetFrameLevel(p:GetFrameLevel() + 5)
    row:SetHighlightTexture([[Interface\QuestFrame\UI-QuestTitleHighlight]], "ADD")
    row:SetScript("OnClick", Row_OnClick)

    local check = row:CreateTexture(nil, "OVERLAY")
    check:SetSize(16, 16)
    check:SetPoint("LEFT", row, "LEFT", 1, -1)
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:Hide()
    row.check = check

    local sb = CreateFrame("Button", nil, row)
    sb:SetSize(16, 16)
    sb:SetPoint("RIGHT", row, "RIGHT", -1, 0)
    sb.row = row
    sb:SetScript("OnClick", RowSpeaker_OnClick)
    local spk = sb:CreateTexture(nil, "BACKGROUND")
    spk:SetTexture("Interface\\Common\\VoiceChat-Speaker")
    spk:SetAllPoints(sb)
    local spkOn = sb:CreateTexture(nil, "HIGHLIGHT")
    spkOn:SetTexture("Interface\\Common\\VoiceChat-On")
    spkOn:SetAllPoints(sb)

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    text:SetPoint("TOPLEFT", check, "TOPRIGHT", 1, 0)
    text:SetPoint("BOTTOMRIGHT", sb, "BOTTOMLEFT", -2, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text

    p.rows[i] = row
    return row
end

local function GetPopup()
    if popup then return popup end
    local p = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    p:SetClampedToScreen(true)
    p:SetFrameStrata("TOOLTIP")
    p:SetBackdrop(frameBackdrop)
    p:EnableMouse(true)
    p:EnableMouseWheel(true)
    p:Hide()
    p.rows, p.names, p.offset, p.visible = {}, {}, 0, 0

    local slider = CreateFrame("Slider", nil, p, "BackdropTemplate")
    slider:SetOrientation("VERTICAL")
    slider:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, -10)
    slider:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -14, 10)
    slider:SetBackdrop(sliderBackdrop)
    slider:SetThumbTexture([[Interface\Buttons\UI-SliderBar-Button-Vertical]])
    slider:SetWidth(12)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetMinMaxValues(0, 0)
    slider:SetScript("OnValueChanged", function(_, v)
        local off = math.floor((v or 0) + 0.5)
        if off ~= p.offset then
            p.offset = off
            Paint(p)
        end
    end)
    p.slider = slider

    p:SetScript("OnMouseWheel", function(self, delta)
        SetOffset(self, self.offset - delta * 3)
    end)
    popup = p
    return p
end

local function OpenFor(owner)
    local p = GetPopup()
    if p.owner and p.owner ~= owner then ClosePopup() end
    p.owner = owner
    p.names = SortedNames(owner.list)
    local count = #p.names
    local maxRows = math.max(5, math.floor((UIParent:GetHeight() * 2 / 5 - 25) / ROW_H))
    p.visible = math.min(count, maxRows)
    local scroll = count > p.visible

    local w = owner.frame:GetWidth()
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", owner.frame, "BOTTOMLEFT")
    p:SetPoint("TOPRIGHT", owner.frame, "BOTTOMRIGHT", w < 160 and (160 - w) or 0, 0)
    p:SetHeight(math.max(1, p.visible) * ROW_H + 25)

    for i = 1, p.visible do
        local row = p.rows[i] or CreateRow(p, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -13 - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", p, "RIGHT", scroll and -28 or -14, 0)
    end
    for i = p.visible + 1, #p.rows do p.rows[i]:Hide() end

    p.slider:SetShown(scroll)
    p.slider:SetMinMaxValues(0, math.max(0, count - p.visible))

    -- open with the current pick in view (centred when possible)
    local start = 0
    if owner.value then
        for i, n in ipairs(p.names) do
            if n == owner.value then
                start = i - 1 - math.floor(p.visible / 2)
                break
            end
        end
    end
    p:Show()
    p.offset = -1
    SetOffset(p, start)
end

-- ── widget methods ──────────────────────────────────────────────────────────
local methods = {}

function methods:OnAcquire()
    self:SetHeight(44)
    self:SetWidth(200)
end

function methods:OnRelease()
    ClosePopup(self)
    self:SetText("")
    self:SetLabel("")
    self:SetDisabled(false)
    self.value = nil
    self.list = nil
    self.frame:ClearAllPoints()
    self.frame:Hide()
end

function methods:ClearFocus()
    ClosePopup(self)
end

function methods:SetValue(value)
    if self.list then self:SetText(value or "") end
    self.value = value
end

function methods:GetValue() return self.value end

function methods:SetList(list)
    self.list = list or Media:HashTable("sound")
end

function methods:SetText(text) self.frame.text:SetText(text or "") end
function methods:SetLabel(text) self.frame.label:SetText(text or "") end

function methods:AddItem(key, value)
    self.list = self.list or {}
    self.list[key] = value
end
methods.SetItemValue = methods.AddItem

function methods:SetMultiselect() end
function methods:GetMultiselect() return false end
function methods:SetItemDisabled() end

function methods:SetDisabled(disabled)
    self.disabled = disabled
    if disabled then
        self.frame:Disable()
        self.speaker:SetDesaturated(true)
        self.speakeron:SetDesaturated(true)
        ClosePopup(self)
    else
        self.frame:Enable()
        self.speaker:SetDesaturated(false)
        self.speakeron:SetDesaturated(false)
    end
end

function methods:ToggleDrop()
    if popup and popup:IsShown() and popup.owner == self then
        ClosePopup(self)
        AceGUI:ClearFocus()
    else
        AceGUI:SetFocus(self)
        OpenFor(self)
    end
end

-- ── scripts ────────────────────────────────────────────────────────────────
local function DropButton_OnClick(this) this.obj:ToggleDrop() end
local function Frame_OnHide(this) ClosePopup(this.obj) end
local function Drop_OnEnter(this) this.obj:Fire("OnEnter") end
local function Drop_OnLeave(this) this.obj:Fire("OnLeave") end
local function Widget_PlaySound(this)
    local self = this.obj
    PlayName(self.list, self.frame.text:GetText())
end

local function Constructor()
    local frame = AGSMW:GetBaseFrame()
    local self = { type = Type, frame = frame }
    frame.obj = self
    frame.dropButton.obj = self
    frame.dropButton:SetScript("OnEnter", Drop_OnEnter)
    frame.dropButton:SetScript("OnLeave", Drop_OnLeave)
    frame.dropButton:SetScript("OnClick", DropButton_OnClick)
    frame:SetScript("OnHide", Frame_OnHide)

    local sb = CreateFrame("Button", nil, frame)
    sb:SetSize(16, 16)
    sb:SetPoint("LEFT", frame.DLeft, "LEFT", 26, 1)
    sb:SetScript("OnClick", Widget_PlaySound)
    sb.obj = self
    self.soundbutton = sb
    frame.text:SetPoint("LEFT", sb, "RIGHT", 2, 0)

    local speaker = sb:CreateTexture(nil, "BACKGROUND")
    speaker:SetTexture("Interface\\Common\\VoiceChat-Speaker")
    speaker:SetAllPoints(sb)
    self.speaker = speaker
    local speakeron = sb:CreateTexture(nil, "HIGHLIGHT")
    speakeron:SetTexture("Interface\\Common\\VoiceChat-On")
    speakeron:SetAllPoints(sb)
    self.speakeron = speakeron

    self.alignoffset = 31
    for name, fn in pairs(methods) do self[name] = fn end

    AceGUI:RegisterAsWidget(self)
    return self
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
