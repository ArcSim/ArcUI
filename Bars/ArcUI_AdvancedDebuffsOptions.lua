-- ===================================================================
-- ArcUI_AdvancedDebuffsOptions.lua
-- Options panel for the Advanced Debuffs feature (ns.AdvancedDebuffs).
-- Registered as a top-level tab in ArcUI_Options.lua.
-- ===================================================================

local ADDON, ns = ...
ns.AdvancedDebuffs = ns.AdvancedDebuffs or {}
local AD = ns.AdvancedDebuffs

local function GetDB()
    local db = ns.API.GetDB and ns.API.GetDB()
    return db and db.advancedDebuffs
end

local function GetExtDB()
    local db = ns.API.GetDB and ns.API.GetDB()
    return db and db.advancedExternals
end

function AD.GetOptionsTable()
    return {
        type        = "group",
        name        = "Advanced Debuffs",
        childGroups = "tab",
        args = {
            main = {
                type  = "group",
                name  = "Setup",
                order = 1,
                args  = {
                    -- ── Enable ─────────────────────────────────────────────
                    enabled = {
                        type  = "toggle",
                        name  = "Enable Advanced Debuffs",
                        desc  = "Show a draggable icon grid with harmful auras currently affecting you.",
                        order = 1,
                        width = 2.0,
                        get   = function() local db = GetDB(); return db and db.enabled end,
                        set   = function(_, val)
                            local db = GetDB()
                            if not db then return end
                            db.enabled = val
                            if val then
                                if AD.Enable then AD.Enable() end
                            else
                                if AD.Disable then AD.Disable() end
                            end
                        end,
                    },

                    -- ── Layout ─────────────────────────────────────────────
                    layoutHeader = { type = "header", name = "Layout", order = 10 },

                    iconSize = {
                        type  = "range",
                        name  = "Icon Size",
                        order = 11,
                        min   = 20, max = 80, step = 2,
                        width = 1.5,
                        get   = function() local db = GetDB(); return db and db.iconSize or 40 end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then db.iconSize = val; if AD.ApplySettings then AD.ApplySettings() end end
                        end,
                    },

                    iconSpacing = {
                        type  = "range",
                        name  = "Icon Spacing",
                        order = 12,
                        min   = 0, max = 20, step = 1,
                        width = 1.5,
                        get   = function() local db = GetDB(); return db and db.iconSpacing or 4 end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then db.iconSpacing = val; if AD.ApplySettings then AD.ApplySettings() end end
                        end,
                    },

                    iconsPerRow = {
                        type  = "range",
                        name  = "Icons Per Row",
                        order = 13,
                        min   = 1, max = 20, step = 1,
                        width = 1.5,
                        get   = function() local db = GetDB(); return db and db.iconsPerRow or 8 end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then db.iconsPerRow = val; if AD.ApplySettings then AD.ApplySettings() end end
                        end,
                    },

                    maxRows = {
                        type  = "range",
                        name  = "Max Rows",
                        order = 14,
                        min   = 1, max = 10, step = 1,
                        width = 1.5,
                        get   = function() local db = GetDB(); return db and db.maxRows or 2 end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then db.maxRows = val; if AD.ApplySettings then AD.ApplySettings() end end
                        end,
                    },

                    growHorizontal = {
                        type   = "select",
                        name   = "Grow Horizontal",
                        desc   = "Direction icons flow horizontally from the frame anchor.",
                        order  = 15,
                        width  = 1.4,
                        values = { ["RIGHT"] = "Right", ["LEFT"] = "Left" },
                        get    = function() local db = GetDB(); return db and db.growHorizontal or "RIGHT" end,
                        set    = function(_, val)
                            local db = GetDB()
                            if db then db.growHorizontal = val; if AD.ApplySettings then AD.ApplySettings() end end
                        end,
                    },

                    growVertical = {
                        type   = "select",
                        name   = "Grow Vertical",
                        desc   = "Direction icons flow when wrapping to the next row.",
                        order  = 16,
                        width  = 1.4,
                        values = { ["DOWN"] = "Down", ["UP"] = "Up" },
                        get    = function() local db = GetDB(); return db and db.growVertical or "DOWN" end,
                        set    = function(_, val)
                            local db = GetDB()
                            if db then db.growVertical = val; if AD.ApplySettings then AD.ApplySettings() end end
                        end,
                    },

                    -- ── Border ─────────────────────────────────────────────
                    borderHeader = { type = "header", name = "Border", order = 20 },

                    borderColorMode = {
                        type   = "select",
                        name   = "Border Color Mode",
                        desc   = "Dispel Type: colors the border based on Magic/Curse/Disease/Poison/Bleed dispel category. Custom: uses a single fixed color.",
                        order  = 21,
                        width  = 1.6,
                        values = { ["dispel"] = "Dispel Type", ["custom"] = "Custom Color" },
                        get    = function() local db = GetDB(); return db and db.borderColorMode or "dispel" end,
                        set    = function(_, val)
                            local db = GetDB()
                            if db then db.borderColorMode = val; if AD.RefreshAllAuras then AD.RefreshAllAuras() end end
                        end,
                    },

                    borderColor = {
                        type     = "color",
                        name     = "Custom Border Color",
                        order    = 22,
                        width    = 1.4,
                        hasAlpha = true,
                        hidden   = function()
                            local db = GetDB()
                            return not db or db.borderColorMode ~= "custom"
                        end,
                        get = function()
                            local db = GetDB()
                            local bc = db and db.borderColor or { r=0.8, g=0.8, b=0.8, a=1 }
                            return bc.r, bc.g, bc.b, bc.a
                        end,
                        set = function(_, r, g, b, a)
                            local db = GetDB()
                            if db then
                                db.borderColor = { r=r, g=g, b=b, a=a }
                                if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                            end
                        end,
                    },

                    -- ── Cooldown Swipe ─────────────────────────────────────
                    swipeHeader = { type = "header", name = "Cooldown Swipe", order = 30 },

                    showSwipe = {
                        type  = "toggle",
                        name  = "Show Cooldown Swipe",
                        order = 31,
                        width = 1.6,
                        get   = function() local db = GetDB(); return not db or db.showSwipe ~= false end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then db.showSwipe = val; if AD.ApplySettings then AD.ApplySettings() end end
                        end,
                    },

                    reverseSwipe = {
                        type  = "toggle",
                        name  = "Reverse Swipe Direction",
                        desc  = "When enabled the swipe drains clockwise as the debuff fades (standard timer style).",
                        order = 32,
                        width = 1.9,
                        get   = function() local db = GetDB(); return not db or db.reverseSwipe ~= false end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then db.reverseSwipe = val; if AD.ApplySettings then AD.ApplySettings() end end
                        end,
                    },

                    -- ── Misc ───────────────────────────────────────────────
                    miscHeader = { type = "header", name = "Miscellaneous", order = 40 },

                    showTooltips = {
                        type  = "toggle",
                        name  = "Show Tooltips on Hover",
                        order = 41,
                        width = 1.7,
                        get   = function() local db = GetDB(); return db and db.showTooltips end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then db.showTooltips = val; if AD.ApplySettings then AD.ApplySettings() end end
                        end,
                    },

                    strata = {
                        type   = "select",
                        name   = "Frame Strata",
                        order  = 42,
                        width  = 1.4,
                        values = {
                            ["BACKGROUND"] = "Background",
                            ["LOW"]        = "Low",
                            ["MEDIUM"]     = "Medium",
                            ["HIGH"]       = "High",
                            ["DIALOG"]     = "Dialog",
                        },
                        get = function() local db = GetDB(); return db and db.strata or "MEDIUM" end,
                        set = function(_, val)
                            local db = GetDB()
                            if db then
                                db.strata = val
                                if AD.ApplyPosition then AD.ApplyPosition() end
                            end
                        end,
                    },
                },
            },

            filters = {
                type  = "group",
                name  = "Filters",
                order = 2,
                args  = {
                    filtersDesc = {
                        type     = "description",
                        name     = "Restrict which harmful auras are shown. If multiple filters are enabled, an aura must pass ALL of them (AND logic). Leave all filters disabled to show every harmful aura.",
                        order    = 1,
                        fontSize = "medium",
                    },

                    filterBreak1 = { type = "header", name = "Source Filters", order = 10 },

                    filterPlayer = {
                        type  = "toggle",
                        name  = "Player-Applied Only",
                        desc  = "Show only harmful auras applied by you.",
                        order = 11,
                        width = 1.6,
                        get   = function()
                            local db = GetDB()
                            return db and db.filters and db.filters.PLAYER
                        end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then
                                db.filters = db.filters or {}
                                db.filters.PLAYER = val
                                if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                            end
                        end,
                    },

                    filterRaid = {
                        type  = "toggle",
                        name  = "Raid/Party-Applied Only",
                        desc  = "Show only harmful auras applied by raid or party members.",
                        order = 12,
                        width = 1.9,
                        get   = function()
                            local db = GetDB()
                            return db and db.filters and db.filters.RAID
                        end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then
                                db.filters = db.filters or {}
                                db.filters.RAID = val
                                if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                            end
                        end,
                    },

                    filterBreak2 = { type = "header", name = "Type Filters", order = 20 },

                    filterCrowdControl = {
                        type  = "toggle",
                        name  = "Crowd Control Only",
                        desc  = "Show only crowd control debuffs.",
                        order = 21,
                        width = 1.6,
                        get   = function()
                            local db = GetDB()
                            return db and db.filters and db.filters.CROWD_CONTROL
                        end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then
                                db.filters = db.filters or {}
                                db.filters.CROWD_CONTROL = val
                                if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                            end
                        end,
                    },

                    filterRaidPlayerDispellable = {
                        type  = "toggle",
                        name  = "Dispellable by You Only",
                        desc  = "Show only harmful auras that your character can dispel.",
                        order = 22,
                        width = 1.9,
                        get   = function()
                            local db = GetDB()
                            return db and db.filters and db.filters.RAID_PLAYER_DISPELLABLE
                        end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then
                                db.filters = db.filters or {}
                                db.filters.RAID_PLAYER_DISPELLABLE = val
                                if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                            end
                        end,
                    },

                    filterImportant = {
                        type  = "toggle",
                        name  = "Important Auras Only",
                        desc  = "Show only auras flagged as important by Blizzard.",
                        order = 23,
                        width = 1.7,
                        get   = function()
                            local db = GetDB()
                            return db and db.filters and db.filters.IMPORTANT
                        end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then
                                db.filters = db.filters or {}
                                db.filters.IMPORTANT = val
                                if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                            end
                        end,
                    },

                    filterRaidInCombat = {
                        type  = "toggle",
                        name  = "Raid-Visible In Combat Only",
                        desc  = "Show only auras that are visible in raid frames during combat.",
                        order = 24,
                        width = 2.2,
                        get   = function()
                            local db = GetDB()
                            return db and db.filters and db.filters.RAID_IN_COMBAT
                        end,
                        set   = function(_, val)
                            local db = GetDB()
                            if db then
                                db.filters = db.filters or {}
                                db.filters.RAID_IN_COMBAT = val
                                if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                            end
                        end,
                    },
                },
            },

            position = {
                type  = "group",
                name  = "Position",
                order = 3,
                args  = {
                    posDesc = {
                        type     = "description",
                        name     = "Drag the icon grid in-game to reposition it. The frame is moveable at all times; left-click an empty area and drag. Position is saved automatically on release.",
                        order    = 1,
                        fontSize = "medium",
                    },

                    posBreak = { type = "header", name = "", order = 5 },

                    resetPosition = {
                        type  = "execute",
                        name  = "Reset to Center",
                        desc  = "Move the icon grid back to the center of the screen.",
                        order = 6,
                        width = 1.4,
                        func  = function()
                            local db = GetDB()
                            if db then
                                db.position = { point="CENTER", relativePoint="CENTER", x=0, y=-200 }
                                if AD.ApplyPosition then AD.ApplyPosition() end
                            end
                        end,
                    },
                },
            },

            -- ── Externals tracker ──────────────────────────────────────────
            externals = {
                type  = "group",
                name  = "Externals",
                order = 4,
                args  = {
                    extEnabled = {
                        type  = "toggle",
                        name  = "Enable External Defensives",
                        desc  = "Show a draggable icon grid tracking defensive cooldowns cast on you by others (Pain Suppression, Guardian Spirit, Ironbark, and similar).",
                        order = 1,
                        width = 2.2,
                        get   = function() local db = GetExtDB(); return db and db.enabled end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if not db then return end
                            db.enabled = val
                            if val then
                                if AD.EnableExternals then AD.EnableExternals() end
                            else
                                if AD.DisableExternals then AD.DisableExternals() end
                            end
                        end,
                    },

                    showBigDefensives = {
                        type  = "toggle",
                        name  = "Include Big Defensives",
                        desc  = "Also show major defensive cooldowns you cast on yourself (Divine Shield, Ice Block, and similar).",
                        order = 2,
                        width = 2.0,
                        get   = function() local db = GetExtDB(); return db and db.showBigDefensives end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if db then
                                db.showBigDefensives = val
                                if AD.RefreshExternals then AD.RefreshExternals() end
                            end
                        end,
                    },

                    -- ── Layout ──────────────────────────────────────────────
                    extLayoutHeader = { type = "header", name = "Layout", order = 10 },

                    extIconSize = {
                        type  = "range",
                        name  = "Icon Size",
                        order = 11,
                        min   = 20, max = 80, step = 2,
                        width = 1.5,
                        get   = function() local db = GetExtDB(); return db and db.iconSize or 40 end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if db then db.iconSize = val; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                        end,
                    },

                    extIconSpacing = {
                        type  = "range",
                        name  = "Icon Spacing",
                        order = 12,
                        min   = 0, max = 20, step = 1,
                        width = 1.5,
                        get   = function() local db = GetExtDB(); return db and db.iconSpacing or 4 end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if db then db.iconSpacing = val; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                        end,
                    },

                    extIconsPerRow = {
                        type  = "range",
                        name  = "Icons Per Row",
                        order = 13,
                        min   = 1, max = 20, step = 1,
                        width = 1.5,
                        get   = function() local db = GetExtDB(); return db and db.iconsPerRow or 8 end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if db then db.iconsPerRow = val; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                        end,
                    },

                    extMaxRows = {
                        type  = "range",
                        name  = "Max Rows",
                        order = 14,
                        min   = 1, max = 5, step = 1,
                        width = 1.5,
                        get   = function() local db = GetExtDB(); return db and db.maxRows or 1 end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if db then db.maxRows = val; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                        end,
                    },

                    extGrowHorizontal = {
                        type   = "select",
                        name   = "Grow Horizontal",
                        desc   = "Direction icons flow horizontally from the frame anchor.",
                        order  = 15,
                        width  = 1.4,
                        values = { ["RIGHT"] = "Right", ["LEFT"] = "Left" },
                        get    = function() local db = GetExtDB(); return db and db.growHorizontal or "RIGHT" end,
                        set    = function(_, val)
                            local db = GetExtDB()
                            if db then db.growHorizontal = val; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                        end,
                    },

                    extGrowVertical = {
                        type   = "select",
                        name   = "Grow Vertical",
                        desc   = "Direction icons flow when wrapping to the next row.",
                        order  = 16,
                        width  = 1.4,
                        values = { ["DOWN"] = "Down", ["UP"] = "Up" },
                        get    = function() local db = GetExtDB(); return db and db.growVertical or "DOWN" end,
                        set    = function(_, val)
                            local db = GetExtDB()
                            if db then db.growVertical = val; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                        end,
                    },

                    -- ── Border ──────────────────────────────────────────────
                    extBorderHeader = { type = "header", name = "Border", order = 20 },

                    extBorderColor = {
                        type     = "color",
                        name     = "Border Color",
                        order    = 21,
                        width    = 1.2,
                        hasAlpha = true,
                        get = function()
                            local db = GetExtDB()
                            local bc = db and db.borderColor or { r=0.2, g=0.8, b=0.2, a=1 }
                            return bc.r, bc.g, bc.b, bc.a
                        end,
                        set = function(_, r, g, b, a)
                            local db = GetExtDB()
                            if db then
                                db.borderColor = { r=r, g=g, b=b, a=a }
                                if AD.RefreshExternals then AD.RefreshExternals() end
                            end
                        end,
                    },

                    -- ── Cooldown Swipe ──────────────────────────────────────
                    extSwipeHeader = { type = "header", name = "Cooldown Swipe", order = 30 },

                    extShowSwipe = {
                        type  = "toggle",
                        name  = "Show Cooldown Swipe",
                        order = 31,
                        width = 1.6,
                        get   = function() local db = GetExtDB(); return not db or db.showSwipe ~= false end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if db then db.showSwipe = val; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                        end,
                    },

                    extReverseSwipe = {
                        type  = "toggle",
                        name  = "Reverse Swipe Direction",
                        desc  = "When enabled the swipe drains clockwise as the buff fades (standard timer style).",
                        order = 32,
                        width = 1.9,
                        get   = function() local db = GetExtDB(); return not db or db.reverseSwipe ~= false end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if db then db.reverseSwipe = val; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                        end,
                    },

                    -- ── Misc ────────────────────────────────────────────────
                    extMiscHeader = { type = "header", name = "Miscellaneous", order = 40 },

                    extShowTooltips = {
                        type  = "toggle",
                        name  = "Show Tooltips on Hover",
                        order = 41,
                        width = 1.7,
                        get   = function() local db = GetExtDB(); return db and db.showTooltips end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if db then db.showTooltips = val; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                        end,
                    },

                    extStrata = {
                        type   = "select",
                        name   = "Frame Strata",
                        order  = 42,
                        width  = 1.4,
                        values = {
                            ["BACKGROUND"] = "Background",
                            ["LOW"]        = "Low",
                            ["MEDIUM"]     = "Medium",
                            ["HIGH"]       = "High",
                            ["DIALOG"]     = "Dialog",
                        },
                        get = function() local db = GetExtDB(); return db and db.strata or "MEDIUM" end,
                        set = function(_, val)
                            local db = GetExtDB()
                            if db then
                                db.strata = val
                                if AD.ApplyExtPosition then AD.ApplyExtPosition() end
                            end
                        end,
                    },

                    -- ── Position ────────────────────────────────────────────
                    extPosHeader = { type = "header", name = "Position", order = 50 },

                    extPosDesc = {
                        type     = "description",
                        name     = "Drag the icon grid in-game to reposition it. Position is saved automatically on release.",
                        order    = 51,
                        fontSize = "medium",
                    },

                    extResetPosition = {
                        type  = "execute",
                        name  = "Reset to Center",
                        desc  = "Move the icon grid back to the center of the screen.",
                        order = 52,
                        width = 1.4,
                        func  = function()
                            local db = GetExtDB()
                            if db then
                                db.position = { point="CENTER", relativePoint="CENTER", x=0, y=-260 }
                                if AD.ApplyExtPosition then AD.ApplyExtPosition() end
                            end
                        end,
                    },
                },
            },
        },
    }
end
