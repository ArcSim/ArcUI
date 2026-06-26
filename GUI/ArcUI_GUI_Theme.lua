---@diagnostic disable: undefined-global
local _, ns = ...
ns.GUI = ns.GUI or {}

ns.GUI.Theme = {
    -- Backgrounds
    bgDark    = { 0.07,  0.08,  0.10,  0.97 },
    bgMedium  = { 0.10,  0.11,  0.135, 1.0  },
    bgLight   = { 0.13,  0.14,  0.17,  1.0  },
    -- Borders
    border     = { 0.20, 0.22, 0.26, 1.0 },
    borderSize = 1,
    -- Accent (cyan/blue to match the design reference)
    accent      = { 0.30, 0.75, 1.0,  1.0  },
    accentDim   = { 0.30, 0.75, 1.0,  0.65 },
    accentHover = { 0.30, 0.75, 1.0,  0.12 },
    -- Text
    textPrimary   = { 1.0,  1.0,  1.0,  1.0 },
    textSecondary = { 0.60, 0.65, 0.72, 1.0 },
    error         = { 1.0,  0.35, 0.35, 1.0 },
    -- Layout
    headerHeight  = 42,
    footerHeight  = 30,
    sidebarWidth  = 185,
    itemHeight    = 28,
    sectionHeight = 32,
    paddingSmall  = 4,
    paddingMedium = 8,
    paddingLarge  = 14,
    -- Fonts
    fontPath       = "Fonts\\FRIZQT__.TTF",
    fontSizeSmall  = 10,
    fontSizeNormal = 11,
    fontSizeLarge  = 13,
}

function ns.GUI.Font(fs, size)
    local T = ns.GUI.Theme
    fs:SetFont(T.fontPath, size or T.fontSizeNormal, "")
    fs:SetShadowOffset(0, 0)
    fs:SetShadowColor(0, 0, 0, 0)
end
