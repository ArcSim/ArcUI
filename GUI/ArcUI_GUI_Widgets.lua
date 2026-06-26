---@diagnostic disable: undefined-global
local _, ns = ...
local GUI = ns.GUI
local T   = GUI.Theme

-- ── Toggle ─────────────────────────────────────────────────────

function GUI:CreateToggle(parent, label, onChange)
    local BOX = 16
    local H   = 24

    local frame = CreateFrame("Button", nil, parent)
    frame:SetHeight(H)

    -- Box background
    local boxBg = frame:CreateTexture(nil, "BACKGROUND")
    boxBg:SetSize(BOX, BOX)
    boxBg:SetPoint("LEFT", frame, "LEFT", 0, 0)
    boxBg:SetColorTexture(T.bgDark[1], T.bgDark[2], T.bgDark[3], 1)

    -- Box border frame
    local boxBorder = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    boxBorder:SetSize(BOX, BOX)
    boxBorder:SetPoint("LEFT", frame, "LEFT", 0, 0)
    boxBorder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = T.borderSize })
    boxBorder:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], 1)

    -- Check mark
    local check = frame:CreateTexture(nil, "ARTWORK")
    check:SetSize(BOX - 4, BOX - 4)
    check:SetPoint("CENTER", boxBg, "CENTER", 0, 0)
    check:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
    check:Hide()

    -- Label
    local fs = frame:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("LEFT",  boxBg, "RIGHT",  T.paddingSmall + 2, 0)
    fs:SetPoint("RIGHT", frame, "RIGHT",  0, 0)
    fs:SetJustifyH("LEFT")
    GUI.Font(fs)
    fs:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 1)
    fs:SetText(label or "")

    local checked    = false
    local onChangeFn = onChange

    function frame:SetChecked(val)
        checked = val and true or false
        if checked then
            check:Show()
            boxBorder:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 1)
        else
            check:Hide()
            boxBorder:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], 1)
        end
    end

    function frame:IsChecked() return checked end
    function frame:SetLabel(text) fs:SetText(text or "") end
    function frame:SetOnChange(fn) onChangeFn = fn end

    frame:SetScript("OnClick", function()
        frame:SetChecked(not checked)
        if onChangeFn then onChangeFn(checked) end
    end)

    frame:SetScript("OnEnter", function()
        boxBg:SetColorTexture(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], 1)
        fs:SetTextColor(T.textPrimary[1], T.textPrimary[2], T.textPrimary[3], 1)
    end)
    frame:SetScript("OnLeave", function()
        boxBg:SetColorTexture(T.bgDark[1], T.bgDark[2], T.bgDark[3], 1)
        fs:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 1)
    end)

    return frame
end

-- ── Slider ─────────────────────────────────────────────────────

function GUI:CreateSlider(parent, label, minVal, maxVal, step, onChange)
    local TRACK = 6
    local THUMB = 12
    local H     = label and 42 or 26

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(H)

    local lblFS
    if label then
        lblFS = frame:CreateFontString(nil, "OVERLAY")
        lblFS:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
        lblFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -60, 0)
        lblFS:SetHeight(T.fontSizeNormal + 4)
        lblFS:SetJustifyH("LEFT")
        GUI.Font(lblFS)
        lblFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 1)
        lblFS:SetText(label)
    end

    local valFS = frame:CreateFontString(nil, "OVERLAY")
    valFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    valFS:SetHeight(T.fontSizeNormal + 4)
    valFS:SetWidth(56)
    valFS:SetJustifyH("RIGHT")
    GUI.Font(valFS)
    valFS:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 1)

    -- Track
    local trackBg = frame:CreateTexture(nil, "BACKGROUND")
    trackBg:SetHeight(TRACK)
    trackBg:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  THUMB / 2,  THUMB / 2)
    trackBg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -THUMB / 2, THUMB / 2)
    trackBg:SetColorTexture(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], 1)

    local trackFill = frame:CreateTexture(nil, "ARTWORK")
    trackFill:SetHeight(TRACK)
    trackFill:SetPoint("LEFT", trackBg, "LEFT", 0, 0)
    trackFill:SetWidth(1)
    trackFill:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.7)

    -- Thumb
    local thumb = CreateFrame("Button", nil, frame)
    thumb:SetSize(THUMB, THUMB)
    thumb:SetPoint("LEFT", trackBg, "LEFT", 0, 0)
    local thumbTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbTex:SetAllPoints(thumb)
    thumbTex:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
    thumb:SetNormalTexture(thumbTex)

    local curMin  = minVal or 0
    local curMax  = maxVal or 1
    local curStep = step   or 0
    local curVal  = curMin
    local onChangeFn = onChange

    local function UpdateVisuals()
        local pct = (curMax > curMin) and ((curVal - curMin) / (curMax - curMin)) or 0
        pct = math.max(0, math.min(1, pct))
        local tw = trackBg:GetWidth()
        if tw and tw > 0 then
            thumb:ClearAllPoints()
            thumb:SetPoint("CENTER", trackBg, "LEFT", pct * tw, 0)
            trackFill:SetWidth(math.max(1, pct * tw))
        end
        valFS:SetText(string.format(curStep >= 1 and "%d" or "%.2f", curVal))
    end

    function frame:SetValue(v)
        if curStep > 0 then
            v = math.floor(v / curStep + 0.5) * curStep
        end
        curVal = math.max(curMin, math.min(curMax, v))
        UpdateVisuals()
    end

    function frame:GetValue()     return curVal end
    function frame:SetStep(s)     curStep = s end
    function frame:SetLabel(text) if lblFS then lblFS:SetText(text or "") end end
    function frame:SetOnChange(fn) onChangeFn = fn end

    function frame:SetMinMaxValues(mn, mx)
        curMin = mn; curMax = mx
        UpdateVisuals()
    end

    local function SetFromCursor()
        local mx = GetCursorPosition() / UIParent:GetEffectiveScale()
        local tl = trackBg:GetLeft()
        local tw = trackBg:GetWidth()
        if tl and tw and tw > 0 then
            local pct = math.max(0, math.min(1, (mx - tl) / tw))
            frame:SetValue(curMin + pct * (curMax - curMin))
            if onChangeFn then onChangeFn(curVal) end
        end
    end

    thumb:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" then return end
        thumb:SetScript("OnUpdate", function() SetFromCursor() end)
    end)
    thumb:SetScript("OnMouseUp", function()
        thumb:SetScript("OnUpdate", nil)
    end)

    frame:EnableMouse(true)
    frame:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then SetFromCursor() end
    end)
    frame:SetScript("OnSizeChanged", function() UpdateVisuals() end)
    frame:SetScript("OnShow",        function() UpdateVisuals() end)

    UpdateVisuals()
    return frame
end

-- ── Dropdown ───────────────────────────────────────────────────

local _openDropdown = nil

function GUI:CreateDropdown(parent, label, items, onChange)
    local H = label and 42 or 24

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(H)

    local lblFS
    if label then
        lblFS = frame:CreateFontString(nil, "OVERLAY")
        lblFS:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
        lblFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        lblFS:SetHeight(T.fontSizeNormal + 4)
        lblFS:SetJustifyH("LEFT")
        GUI.Font(lblFS)
        lblFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 1)
        lblFS:SetText(label)
    end

    local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btn:SetHeight(24)
    if label then
        btn:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  0, 0)
        btn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    else
        btn:SetAllPoints(frame)
    end
    btn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = T.borderSize,
    })
    btn:SetBackdropColor(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], 1)
    btn:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], 1)

    local selFS = btn:CreateFontString(nil, "OVERLAY")
    selFS:SetPoint("LEFT",  btn, "LEFT",  T.paddingSmall, 0)
    selFS:SetPoint("RIGHT", btn, "RIGHT", -T.paddingMedium * 2, 0)
    selFS:SetJustifyH("LEFT")
    GUI.Font(selFS)
    selFS:SetTextColor(T.textPrimary[1], T.textPrimary[2], T.textPrimary[3], 1)

    local arrow = btn:CreateFontString(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", btn, "RIGHT", -T.paddingSmall, 0)
    GUI.Font(arrow, T.fontSizeSmall)
    arrow:SetText("▼")
    arrow:SetTextColor(T.accent[1], T.accent[2], T.accent[3], 1)

    -- Popup list
    local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetFrameStrata("TOOLTIP")
    popup:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = T.borderSize,
    })
    popup:SetBackdropColor(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], 1)
    popup:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], 1)
    popup:Hide()

    local curItems   = items or {}
    local curVal     = nil
    local itemBtns   = {}
    local onChangeFn = onChange

    local function RebuildPopup()
        for _, ib in ipairs(itemBtns) do ib:SetParent(nil) end
        itemBtns = {}
        local totalH = T.borderSize * 2
        for i, item in ipairs(curItems) do
            local ib = CreateFrame("Button", nil, popup, "BackdropTemplate")
            ib:SetHeight(T.itemHeight)
            ib:SetPoint("TOPLEFT",  popup, "TOPLEFT",  T.borderSize,  -(T.borderSize + (i - 1) * T.itemHeight))
            ib:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -T.borderSize, -(T.borderSize + (i - 1) * T.itemHeight))

            local iFS = ib:CreateFontString(nil, "OVERLAY")
            iFS:SetPoint("LEFT",  ib, "LEFT",  T.paddingMedium, 0)
            iFS:SetPoint("RIGHT", ib, "RIGHT", -T.paddingSmall, 0)
            iFS:SetJustifyH("LEFT")
            GUI.Font(iFS)
            iFS:SetText(item.text or tostring(item.value))

            local isActive = (item.value == curVal)
            iFS:SetTextColor(
                isActive and T.accent[1] or T.textSecondary[1],
                isActive and T.accent[2] or T.textSecondary[2],
                isActive and T.accent[3] or T.textSecondary[3], 1)

            ib:SetScript("OnEnter", function()
                ib:SetBackdropColor(T.accentHover[1], T.accentHover[2], T.accentHover[3], T.accentHover[4])
                iFS:SetTextColor(T.textPrimary[1], T.textPrimary[2], T.textPrimary[3], 1)
            end)
            ib:SetScript("OnLeave", function()
                ib:SetBackdropColor(0, 0, 0, 0)
                local active = (item.value == curVal)
                iFS:SetTextColor(
                    active and T.accent[1] or T.textSecondary[1],
                    active and T.accent[2] or T.textSecondary[2],
                    active and T.accent[3] or T.textSecondary[3], 1)
            end)
            ib:SetScript("OnClick", function()
                curVal = item.value
                selFS:SetText(item.text or tostring(item.value))
                popup:Hide()
                _openDropdown = nil
                if onChangeFn then onChangeFn(curVal) end
            end)

            table.insert(itemBtns, ib)
            totalH = totalH + T.itemHeight
        end
        popup:SetHeight(totalH)
    end

    local function TogglePopup()
        if popup:IsShown() then
            popup:Hide()
            _openDropdown = nil
            return
        end
        if _openDropdown and _openDropdown ~= popup then
            _openDropdown:Hide()
        end
        RebuildPopup()
        popup:ClearAllPoints()
        popup:SetWidth(btn:GetWidth())
        local bL = btn:GetLeft()
        local bB = btn:GetBottom()
        if bL and bB then
            popup:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", bL, bB)
        end
        popup:Show()
        _openDropdown = popup
    end

    -- Dismiss on outside click
    local closer = CreateFrame("Frame", nil, UIParent)
    closer:SetAllPoints()
    closer:SetFrameStrata("TOOLTIP")
    closer:SetFrameLevel(math.max(1, (popup:GetFrameLevel() or 2) - 1))
    closer:EnableMouse(false)
    popup:SetScript("OnShow", function()
        closer:EnableMouse(true)
        closer:SetScript("OnMouseDown", function()
            popup:Hide()
            _openDropdown = nil
            closer:EnableMouse(false)
        end)
    end)
    popup:SetScript("OnHide", function()
        closer:EnableMouse(false)
    end)

    function frame:SetItems(newItems)
        curItems = newItems or {}
        if popup:IsShown() then RebuildPopup() end
    end

    function frame:SetValue(val)
        curVal = val
        for _, item in ipairs(curItems) do
            if item.value == val then
                selFS:SetText(item.text or tostring(val))
                return
            end
        end
        selFS:SetText(tostring(val or ""))
    end

    function frame:GetValue()     return curVal end
    function frame:SetLabel(text) if lblFS then lblFS:SetText(text or "") end end
    function frame:SetOnChange(fn) onChangeFn = fn end

    btn:SetScript("OnClick", TogglePopup)
    btn:SetScript("OnEnter", function()
        btn:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 1)
    end)
    btn:SetScript("OnLeave", function()
        btn:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], 1)
    end)

    return frame
end

-- ── ColorPicker ────────────────────────────────────────────────

function GUI:CreateColorPicker(parent, label, hasAlpha, onChange)
    local H      = label and 42 or 24
    local SWATCH = 20

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(H)

    local lblFS
    if label then
        lblFS = frame:CreateFontString(nil, "OVERLAY")
        lblFS:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
        lblFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        lblFS:SetHeight(T.fontSizeNormal + 4)
        lblFS:SetJustifyH("LEFT")
        GUI.Font(lblFS)
        lblFS:SetTextColor(T.textSecondary[1], T.textSecondary[2], T.textSecondary[3], 1)
        lblFS:SetText(label)
    end

    local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btn:SetSize(SWATCH + 40, 24)
    if label then
        btn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    else
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    end
    btn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = T.borderSize,
    })
    btn:SetBackdropColor(T.bgMedium[1], T.bgMedium[2], T.bgMedium[3], 1)
    btn:SetBackdropBorderColor(T.border[1], T.border[2], T.border[3], 1)

    -- Checkerboard for transparency preview
    local checker = btn:CreateTexture(nil, "BACKGROUND")
    checker:SetSize(SWATCH - 4, SWATCH - 4)
    checker:SetPoint("CENTER", btn, "CENTER", 0, 0)
    checker:SetTexture("Interface\\Buttons\\UI-ColorSwatch")

    local swatch = btn:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(SWATCH - 4, SWATCH - 4)
    swatch:SetPoint("CENTER", btn, "CENTER", 0, 0)
    swatch:SetColorTexture(1, 1, 1, 1)

    local curR, curG, curB, curA = 1, 1, 1, 1
    local onChangeFn = onChange

    local function UpdateSwatch()
        swatch:SetColorTexture(curR, curG, curB, 1)
        if hasAlpha then
            swatch:SetAlpha(curA)
        end
        btn:SetBackdropBorderColor(curR * 0.6, curG * 0.6, curB * 0.6, 1)
    end

    function frame:SetColor(r, g, b, a)
        curR = r or 1; curG = g or 1; curB = b or 1; curA = a or 1
        UpdateSwatch()
    end

    function frame:GetColor() return curR, curG, curB, curA end
    function frame:SetLabel(text) if lblFS then lblFS:SetText(text or "") end end
    function frame:SetOnChange(fn) onChangeFn = fn end

    btn:SetScript("OnClick", function()
        local prevR, prevG, prevB, prevA = curR, curG, curB, curA

        local function OnColorChanged()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            local opSlider = ColorPickerFrame.OpacitySlider or _G["OpacitySliderFrame"]
            local a = (hasAlpha and opSlider) and (1 - opSlider:GetValue()) or curA
            curR, curG, curB, curA = r, g, b, a
            UpdateSwatch()
            if onChangeFn then onChangeFn(r, g, b, a) end
        end

        local function OnCancel()
            curR, curG, curB, curA = prevR, prevG, prevB, prevA
            UpdateSwatch()
            if onChangeFn then onChangeFn(prevR, prevG, prevB, prevA) end
        end

        local info = {
            r           = curR,
            g           = curG,
            b           = curB,
            opacity     = hasAlpha and (1 - curA) or nil,
            hasOpacity  = hasAlpha,
            func        = OnColorChanged,
            opacityFunc = hasAlpha and OnColorChanged or nil,
            cancelFunc  = OnCancel,
        }

        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow(info)
        else
            OpenColorPicker(info)
        end
    end)

    btn:SetScript("OnEnter", function()
        btn:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 1)
    end)
    btn:SetScript("OnLeave", UpdateSwatch)

    UpdateSwatch()
    return frame
end
