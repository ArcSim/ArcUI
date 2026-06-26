-- ===================================================================
-- ArcUI_AdvancedDebuffsOptions.lua
-- Options panel for Advanced Debuffs and Externals trackers.
-- Two tabs (Debuffs / Externals), each with collapsible sections.
-- ===================================================================

local ADDON, ns = ...
ns.AdvancedDebuffs = ns.AdvancedDebuffs or {}
local AD = ns.AdvancedDebuffs

-- Collapsed state for each collapsible section (nil = expanded by default)
local collapsed = {}

local function GetDB()
    local db = ns.API.GetDB and ns.API.GetDB()
    return db and db.advancedDebuffs
end

local function GetExtDB()
    local db = ns.API.GetDB and ns.API.GetDB()
    return db and db.advancedExternals
end

-- ── Anchor point values (shared by both Position groups) ──────────────────────
local ANCHOR_POINTS = {
    CENTER      = "Center",
    TOP         = "Top",
    BOTTOM      = "Bottom",
    LEFT        = "Left",
    RIGHT       = "Right",
    TOPLEFT     = "Top Left",
    TOPRIGHT    = "Top Right",
    BOTTOMLEFT  = "Bottom Left",
    BOTTOMRIGHT = "Bottom Right",
}

-- Frames the icon grid can be anchored to
local ANCHOR_FRAMES = {
    ["UIParent"]              = "Screen (default)",
    ["PlayerFrame"]           = "Player Frame",
    ["TargetFrame"]           = "Target Frame",
    ["PlayerCastingBarFrame"] = "Blizzard Castbar",
    ["ArcUICastbarMain"]      = "ArcUI Castbar",
    ["MinimapCluster"]        = "Minimap",
}

-- ── Collapse helpers ───────────────────────────────────────────────────────
local function CH(key) -- CollapsibleHeader toggle entry
    return {
        type          = "toggle",
        dialogControl = "CollapsibleHeader",
        desc          = "Click to expand / collapse",
        get           = function() return not collapsed[key] end,
        set           = function(_, v) collapsed[key] = not v end,
        width         = "full",
    }
end
local function hide(key) return function() return collapsed[key] end end

-- ───────────────────────────────────────────────────────────────────────────
-- SHARED LAYOUT CONTROLS (factory; avoids code duplication)
-- ───────────────────────────────────────────────────────────────────────────

local function MakeLayoutGroup(colKey, getDb, applyFn, base)
    return {
        type   = "group",
        name   = "Layout",
        inline = true,
        order  = base + 1,
        hidden = hide(colKey),
        args   = {
            iconSize = {
                type  = "range",
                name  = "Icon Size",
                order = 1,
                min   = 20, max = 80, step = 2,
                width = 1.4,
                get   = function() local db = getDb(); return db and db.iconSize or 40 end,
                set   = function(_, v) local db = getDb(); if db then db.iconSize = v; applyFn() end end,
            },
            iconSpacing = {
                type  = "range",
                name  = "Icon Spacing",
                order = 2,
                min   = 0, max = 20, step = 1,
                width = 1.4,
                get   = function() local db = getDb(); return db and db.iconSpacing or 4 end,
                set   = function(_, v) local db = getDb(); if db then db.iconSpacing = v; applyFn() end end,
            },
            iconsPerRow = {
                type  = "range",
                name  = "Icons Per Row",
                order = 3,
                min   = 1, max = 20, step = 1,
                width = 1.4,
                get   = function() local db = getDb(); return db and db.iconsPerRow or 8 end,
                set   = function(_, v) local db = getDb(); if db then db.iconsPerRow = v; applyFn() end end,
            },
            maxRows = {
                type  = "range",
                name  = "Max Rows",
                order = 4,
                min   = 1, max = 10, step = 1,
                width = 1.4,
                get   = function() local db = getDb(); return db and db.maxRows or 2 end,
                set   = function(_, v) local db = getDb(); if db then db.maxRows = v; applyFn() end end,
            },
            growBreak = { type = "description", name = "", order = 5, width = "full" },
            growHorizontal = {
                type   = "select",
                name   = "Grow Direction",
                desc   = "Horizontal direction icons flow from the anchor point.",
                order  = 6,
                width  = 1.2,
                values = { ["RIGHT"] = "→  Right", ["LEFT"] = "←  Left" },
                get    = function() local db = getDb(); return db and db.growHorizontal or "RIGHT" end,
                set    = function(_, v) local db = getDb(); if db then db.growHorizontal = v; applyFn() end end,
            },
            growVertical = {
                type   = "select",
                name   = "Wrap Direction",
                desc   = "Vertical direction icons flow when wrapping to the next row.",
                order  = 7,
                width  = 1.2,
                values = { ["DOWN"] = "↓  Down", ["UP"] = "↑  Up" },
                get    = function() local db = getDb(); return db and db.growVertical or "DOWN" end,
                set    = function(_, v) local db = getDb(); if db then db.growVertical = v; applyFn() end end,
            },
        },
    }
end

local function MakeDisplayGroup(colKey, getDb, applyFn, applyPosFn, base)
    return {
        type   = "group",
        name   = "Display",
        inline = true,
        order  = base + 1,
        hidden = hide(colKey),
        args   = {
            showSwipe = {
                type  = "toggle",
                name  = "Cooldown Swipe",
                desc  = "Show the timer swipe animation over each icon.",
                order = 1,
                width = 1.3,
                get   = function() local db = getDb(); return not db or db.showSwipe ~= false end,
                set   = function(_, v) local db = getDb(); if db then db.showSwipe = v; applyFn() end end,
            },
            reverseSwipe = {
                type  = "toggle",
                name  = "Clockwise Swipe",
                desc  = "Drain the swipe clockwise as the aura fades — standard countdown style.",
                order = 2,
                width = 1.4,
                get   = function() local db = getDb(); return not db or db.reverseSwipe ~= false end,
                set   = function(_, v) local db = getDb(); if db then db.reverseSwipe = v; applyFn() end end,
            },
            showTooltips = {
                type  = "toggle",
                name  = "Tooltips on Hover",
                desc  = "Show the aura tooltip when hovering over an icon.",
                order = 3,
                width = 1.4,
                get   = function() local db = getDb(); return db and db.showTooltips end,
                set   = function(_, v) local db = getDb(); if db then db.showTooltips = v; applyFn() end end,
            },
            displayBreak = { type = "description", name = "", order = 4, width = "full" },
            strata = {
                type   = "select",
                name   = "Frame Layer",
                desc   = "Render layer for the icon grid. Raise this if icons appear behind other frames.",
                order  = 5,
                width  = 1.3,
                values = {
                    ["BACKGROUND"] = "Background",
                    ["LOW"]        = "Low",
                    ["MEDIUM"]     = "Medium",
                    ["HIGH"]       = "High",
                    ["DIALOG"]     = "Dialog",
                },
                get = function() local db = getDb(); return db and db.strata or "MEDIUM" end,
                set = function(_, v)
                    local db = getDb()
                    if db then db.strata = v; applyPosFn() end
                end,
            },
        },
    }
end

-- ───────────────────────────────────────────────────────────────────────────
-- MAIN OPTIONS TABLE
-- ───────────────────────────────────────────────────────────────────────────

function AD.GetOptionsTable()
    return {
        type        = "group",
        name        = "Advanced Debuffs",
        childGroups = "tab",
        args = {

            -- ================================================================
            -- TAB 1: DEBUFFS
            -- ================================================================
            debuffs = {
                type  = "group",
                name  = "Debuffs",
                order = 1,
                args  = {

                    -- ── Enable ────────────────────────────────────────────────
                    enabled = {
                        type  = "toggle",
                        name  = "Enable Debuffs Tracker",
                        desc  = "Show a draggable icon grid with all harmful auras currently affecting you.",
                        order = 1,
                        width = "full",
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

                    enabledDesc = {
                        type     = "description",
                        name     = "Drag the icon grid anywhere on screen — position saves automatically when you release.",
                        order    = 2,
                        fontSize = "small",
                        width    = "full",
                    },

                    sep1 = { type = "description", name = "", order = 3, width = "full" },

                    -- ── Layout ────────────────────────────────────────────────
                    layoutHeader = (function()
                        local h = CH("debuffLayout")
                        h.name  = "Layout"
                        h.order = 10
                        return h
                    end)(),

                    layoutGroup = MakeLayoutGroup(
                        "debuffLayout", GetDB,
                        function() if AD.ApplySettings then AD.ApplySettings() end end,
                        10
                    ),

                    -- ── Border ────────────────────────────────────────────────
                    borderHeader = (function()
                        local h = CH("debuffBorder")
                        h.name  = "Border"
                        h.order = 20
                        return h
                    end)(),

                    borderGroup = {
                        type   = "group",
                        name   = "Border",
                        inline = true,
                        order  = 21,
                        hidden = hide("debuffBorder"),
                        args   = {
                            borderDesc = {
                                type     = "description",
                                name     = "The icon border is colored by each aura's dispel type — Magic (blue), Curse (purple), Disease (brown), Poison (green), Bleed (red), Enrage (orange). A small badge icon also appears at the top-right corner for the four types that have one.",
                                order    = 1,
                                fontSize = "small",
                                width    = "full",
                            },
                            borderColorMode = {
                                type   = "select",
                                name   = "Color Mode",
                                desc   = "Dispel Type: colors the border by debuff category. Custom: uses a single fixed color for all icons.",
                                order  = 2,
                                width  = 1.5,
                                values = { ["dispel"] = "Dispel Type", ["custom"] = "Custom Color" },
                                get    = function() local db = GetDB(); return db and db.borderColorMode or "dispel" end,
                                set    = function(_, val)
                                    local db = GetDB()
                                    if db then db.borderColorMode = val; if AD.RefreshAllAuras then AD.RefreshAllAuras() end end
                                end,
                            },
                            borderColor = {
                                type     = "color",
                                name     = "Custom Color",
                                order    = 3,
                                width    = 1.0,
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
                            borderBreak = { type = "description", name = "", order = 4, width = "full" },
                            borderWidth = {
                                type  = "range",
                                name  = "Border Thickness",
                                desc  = "Width in pixels of the colored border strip around each icon.",
                                order = 5,
                                min   = 0, max = 8, step = 1,
                                width = 1.4,
                                get   = function() local db = GetDB(); return db and db.borderWidth or 2 end,
                                set   = function(_, v)
                                    local db = GetDB()
                                    if db then db.borderWidth = v; if AD.ApplySettings then AD.ApplySettings() end end
                                end,
                            },
                            borderGlow = {
                                type  = "toggle",
                                name  = "Border Glow",
                                desc  = "Add a pixel glow effect around each icon, matching its border color — the same style used on CDM icons.",
                                order = 6,
                                width = 1.2,
                                get   = function() local db = GetDB(); return db and db.borderGlow end,
                                set   = function(_, v)
                                    local db = GetDB()
                                    if db then db.borderGlow = v; if AD.RefreshAllAuras then AD.RefreshAllAuras() end end
                                end,
                            },
                            glowWidth = {
                                type   = "range",
                                name   = "Glow Thickness",
                                desc   = "Line thickness of the pixel glow.",
                                order  = 7,
                                min    = 1, max = 6, step = 1,
                                width  = 1.2,
                                hidden = function() local db = GetDB(); return not db or not db.borderGlow end,
                                get    = function() local db = GetDB(); return db and db.glowWidth or 2 end,
                                set    = function(_, v)
                                    local db = GetDB()
                                    if db then db.glowWidth = v; if AD.RefreshAllAuras then AD.RefreshAllAuras() end end
                                end,
                            },
                        },
                    },

                    -- ── Display ───────────────────────────────────────────────
                    displayHeader = (function()
                        local h = CH("debuffDisplay")
                        h.name  = "Display"
                        h.order = 30
                        return h
                    end)(),

                    displayGroup = MakeDisplayGroup(
                        "debuffDisplay", GetDB,
                        function() if AD.ApplySettings then AD.ApplySettings() end end,
                        function() if AD.ApplyPosition then AD.ApplyPosition() end end,
                        30
                    ),

                    -- ── Filters ───────────────────────────────────────────────
                    filtersHeader = (function()
                        local h = CH("debuffFilters")
                        h.name  = "Filters"
                        h.order = 40
                        return h
                    end)(),

                    filtersGroup = {
                        type   = "group",
                        name   = "Filters",
                        inline = true,
                        order  = 41,
                        hidden = hide("debuffFilters"),
                        args   = {
                            filtersDesc = {
                                type     = "description",
                                name     = "Restrict which harmful auras are shown. All enabled filters must pass (AND). Leave all off to show every harmful aura on you.",
                                order    = 1,
                                fontSize = "small",
                                width    = "full",
                            },
                            filterBreak1 = {
                                type  = "description",
                                name  = "|cffffd700By Source|r",
                                order = 9,
                                width = "full",
                            },
                            filterPlayer = {
                                type  = "toggle",
                                name  = "Player-Applied Only",
                                desc  = "Show only harmful auras applied by you.",
                                order = 10,
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
                                name  = "Raid / Party Only",
                                desc  = "Show only harmful auras applied by raid or party members.",
                                order = 11,
                                width = 1.5,
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
                            filterBreak2 = {
                                type  = "description",
                                name  = "|cffffd700By Type|r",
                                order = 19,
                                width = "full",
                            },
                            filterCrowdControl = {
                                type  = "toggle",
                                name  = "Crowd Control Only",
                                desc  = "Show only crowd control debuffs.",
                                order = 20,
                                width = 1.5,
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
                            filterDispellable = {
                                type  = "toggle",
                                name  = "Dispellable by You Only",
                                desc  = "Show only harmful auras your character can dispel.",
                                order = 21,
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
                                name  = "Important Only",
                                desc  = "Show only auras flagged as important by Blizzard.",
                                order = 22,
                                width = 1.3,
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
                                name  = "Raid-Visible in Combat Only",
                                desc  = "Show only auras that appear in raid frames during combat.",
                                order = 23,
                                width = 2.1,
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

                    -- ── Blocklist ─────────────────────────────────────────────
                    blocklistHeader = (function()
                        local h = CH("debuffBlocklist")
                        h.name  = "Blocklist"
                        h.order = 45
                        return h
                    end)(),

                    blocklistGroup = {
                        type   = "group",
                        name   = "Blocklist",
                        inline = true,
                        order  = 46,
                        hidden = hide("debuffBlocklist"),
                        args   = function()
                            local args = {
                                blocklistDesc = {
                                    type     = "description",
                                    name     = "Spell IDs listed here are suppressed from the debuff display. Only spell IDs that are non-secret outside instances work here — for example the Bloodlust/Exhaustion family (57723, 57724, 80354, 160455, 390435, 95809, 264689, 308312). These IDs are pre-populated by default.\n\n|cffaaaaaa\226\129\185 spellId filtering is skipped inside instances due to WoW 12.0 secret values; debuffs show normally there.|r",
                                    order    = 1,
                                    fontSize = "small",
                                    width    = "full",
                                },
                                blocklistEnabled = {
                                    type  = "toggle",
                                    name  = "Enable Blocklist",
                                    desc  = "When on, auras whose spell ID appears in the list below are hidden from the display.",
                                    order = 2,
                                    width = 1.5,
                                    get   = function()
                                        local db = GetDB()
                                        return db == nil or db.blacklistEnabled ~= false
                                    end,
                                    set   = function(_, v)
                                        local db = GetDB()
                                        if db then
                                            db.blacklistEnabled = v
                                            if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                                        end
                                    end,
                                },
                                addSpellId = {
                                    type  = "input",
                                    name  = "Spell ID",
                                    desc  = "Type a numeric spell ID, then click Add.",
                                    order = 3,
                                    width = 1.1,
                                    get   = function() return AD._debuffPendingID or "" end,
                                    set   = function(_, v) AD._debuffPendingID = v end,
                                },
                                addButton = {
                                    type  = "execute",
                                    name  = "Add",
                                    desc  = "Add the spell ID above to the blocklist.",
                                    order = 4,
                                    width = 0.55,
                                    func  = function()
                                        local id = tonumber(AD._debuffPendingID)
                                        if not id or id < 1 then return end
                                        local db = GetDB()
                                        if db then
                                            db.blacklist = db.blacklist or {}
                                            db.blacklist[id] = true
                                            AD._debuffPendingID = ""
                                            if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                        end
                                    end,
                                },
                                clearAll = {
                                    type  = "execute",
                                    name  = "Clear All",
                                    desc  = "Remove every spell ID from the blocklist.",
                                    order = 5,
                                    width = 0.85,
                                    func  = function()
                                        local db = GetDB()
                                        if db then
                                            db.blacklist = {}
                                            if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                        end
                                    end,
                                },
                                listBreak = { type = "description", name = "", order = 9, width = "full" },
                            }
                            local db = GetDB()
                            if db and db.blacklist then
                                local order = 10
                                for spellId, active in pairs(db.blacklist) do
                                    if active then
                                        local sname = C_Spell.GetSpellName and C_Spell.GetSpellName(spellId)
                                        local label = sname
                                            and (sname .. "  [" .. spellId .. "]")
                                            or  ("Spell " .. spellId)
                                        args["bl_" .. spellId] = {
                                            type  = "execute",
                                            name  = label,
                                            desc  = "Click to remove this spell from the blocklist.",
                                            order = order,
                                            width = 2.0,
                                            func  = function()
                                                local db2 = GetDB()
                                                if db2 and db2.blacklist then
                                                    db2.blacklist[spellId] = nil
                                                    if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                                                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                                end
                                            end,
                                        }
                                        order = order + 1
                                    end
                                end
                            end
                            return args
                        end,
                    },

                    -- ── Tracked Spells ────────────────────────────────────────
                    watchlistHeader = (function()
                        local h = CH("debuffWatchlist")
                        h.name  = "Tracked Spells"
                        h.order = 47
                        return h
                    end)(),

                    watchlistGroup = {
                        type   = "group",
                        name   = "Tracked Spells",
                        inline = true,
                        order  = 48,
                        hidden = hide("debuffWatchlist"),
                        args   = function()
                            local args = {
                                watchlistDesc = {
                                    type     = "description",
                                    name     = "Spell IDs added here are always shown regardless of the filter restrictions above. Useful for tracking a specific debuff while still using filters for everything else. The blocklist still takes priority — a spell that is both tracked and blocked will be hidden.\n\n|cffaaaaaa\226\129\185 spellId matching is skipped inside instances due to WoW 12.0 secret values.|r",
                                    order    = 1,
                                    fontSize = "small",
                                    width    = "full",
                                },
                                watchAddSpellId = {
                                    type  = "input",
                                    name  = "Spell ID",
                                    desc  = "Type a numeric spell ID, then click Add.",
                                    order = 2,
                                    width = 1.1,
                                    get   = function() return AD._debuffWatchPendingID or "" end,
                                    set   = function(_, v) AD._debuffWatchPendingID = v end,
                                },
                                watchAddButton = {
                                    type  = "execute",
                                    name  = "Add",
                                    desc  = "Add the spell ID above to the tracked spells list.",
                                    order = 3,
                                    width = 0.55,
                                    func  = function()
                                        local id = tonumber(AD._debuffWatchPendingID)
                                        if not id or id < 1 then return end
                                        local db = GetDB()
                                        if db then
                                            db.watchlist = db.watchlist or {}
                                            db.watchlist[id] = true
                                            AD._debuffWatchPendingID = ""
                                            if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                        end
                                    end,
                                },
                                watchClearAll = {
                                    type  = "execute",
                                    name  = "Clear All",
                                    desc  = "Remove every spell ID from the tracked list.",
                                    order = 4,
                                    width = 0.85,
                                    func  = function()
                                        local db = GetDB()
                                        if db then
                                            db.watchlist = {}
                                            if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                        end
                                    end,
                                },
                                watchListBreak = { type = "description", name = "", order = 9, width = "full" },
                            }
                            local db = GetDB()
                            if db and db.watchlist then
                                local order = 10
                                for spellId, active in pairs(db.watchlist) do
                                    if active then
                                        local sname = C_Spell.GetSpellName and C_Spell.GetSpellName(spellId)
                                        local label = sname
                                            and (sname .. "  [" .. spellId .. "]")
                                            or  ("Spell " .. spellId)
                                        args["wl_" .. spellId] = {
                                            type  = "execute",
                                            name  = label,
                                            desc  = "Click to remove this spell from the tracked list.",
                                            order = order,
                                            width = 2.0,
                                            func  = function()
                                                local db2 = GetDB()
                                                if db2 and db2.watchlist then
                                                    db2.watchlist[spellId] = nil
                                                    if AD.RefreshAllAuras then AD.RefreshAllAuras() end
                                                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                                end
                                            end,
                                        }
                                        order = order + 1
                                    end
                                end
                            end
                            return args
                        end,
                    },

                    -- ── Position ──────────────────────────────────────────────
                    positionHeader = (function()
                        local h = CH("debuffPosition")
                        h.name  = "Position"
                        h.order = 50
                        return h
                    end)(),

                    positionGroup = {
                        type   = "group",
                        name   = "Position",
                        inline = true,
                        order  = 51,
                        hidden = hide("debuffPosition"),
                        args   = {
                            posDesc = {
                                type     = "description",
                                name     = "Drag the frame or use the controls below to fine-tune placement. Open the ArcUI panel to reveal the drag handle above the icon grid.",
                                order    = 1,
                                fontSize = "small",
                                width    = "full",
                            },
                            posAnchor = {
                                type   = "select",
                                name   = "Anchor Point",
                                desc   = "Which corner/edge of the icon grid is used as the anchor.",
                                order  = 2,
                                width  = 1.35,
                                values = ANCHOR_POINTS,
                                get    = function()
                                    local db = GetDB(); local p = db and db.position
                                    return p and p.point or "CENTER"
                                end,
                                set    = function(_, v)
                                    local db = GetDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.point = v
                                        if AD.ApplyPosition then AD.ApplyPosition() end
                                    end
                                end,
                            },
                            relAnchor = {
                                type   = "select",
                                name   = "Relative To Point",
                                desc   = "Which point on the target frame the anchor attaches to.",
                                order  = 3,
                                width  = 1.35,
                                values = ANCHOR_POINTS,
                                get    = function()
                                    local db = GetDB(); local p = db and db.position
                                    return p and p.relativePoint or "CENTER"
                                end,
                                set    = function(_, v)
                                    local db = GetDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.relativePoint = v
                                        if AD.ApplyPosition then AD.ApplyPosition() end
                                    end
                                end,
                            },
                            relativeFrame = {
                                type   = "select",
                                name   = "Attach to Frame",
                                desc   = "Frame the position anchors to. If the chosen frame doesn't exist, falls back to the screen.",
                                order  = 4,
                                width  = 1.8,
                                values = ANCHOR_FRAMES,
                                get    = function()
                                    local db = GetDB(); local p = db and db.position
                                    return p and p.relativeFrame or "UIParent"
                                end,
                                set    = function(_, v)
                                    local db = GetDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.relativeFrame = v
                                        if AD.ApplyPosition then AD.ApplyPosition() end
                                    end
                                end,
                            },
                            posBreakAnchors = { type = "description", name = "", order = 5, width = "full" },
                            posX = {
                                type  = "range",
                                name  = "X Offset",
                                order = 6,
                                min   = -2000, max = 2000, step = 1,
                                width = 1.4,
                                get   = function()
                                    local db = GetDB(); local p = db and db.position
                                    return p and p.x or 0
                                end,
                                set   = function(_, v)
                                    local db = GetDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.x = v
                                        if AD.ApplyPosition then AD.ApplyPosition() end
                                    end
                                end,
                            },
                            posY = {
                                type  = "range",
                                name  = "Y Offset",
                                order = 7,
                                min   = -1200, max = 1200, step = 1,
                                width = 1.4,
                                get   = function()
                                    local db = GetDB(); local p = db and db.position
                                    return p and p.y or -200
                                end,
                                set   = function(_, v)
                                    local db = GetDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.y = v
                                        if AD.ApplyPosition then AD.ApplyPosition() end
                                    end
                                end,
                            },
                            posBreak = { type = "description", name = "", order = 8, width = "full" },
                            resetPosition = {
                                type  = "execute",
                                name  = "Reset to Center",
                                desc  = "Move the debuffs icon grid back to the center of the screen.",
                                order = 9,
                                width = 1.4,
                                func  = function()
                                    local db = GetDB()
                                    if db then
                                        db.position = { point="CENTER", relativePoint="CENTER", x=0, y=-200, relativeFrame="UIParent" }
                                        if AD.ApplyPosition then AD.ApplyPosition() end
                                    end
                                end,
                            },
                        },
                    },
                },
            },

            -- ================================================================
            -- TAB 2: EXTERNALS
            -- ================================================================
            externals = {
                type  = "group",
                name  = "Externals",
                order = 2,
                args  = {

                    -- ── Enable ────────────────────────────────────────────────
                    extEnabled = {
                        type  = "toggle",
                        name  = "Enable Externals Tracker",
                        desc  = "Show a draggable icon grid tracking healer defensives received from allies — Ironbark, Life Cocoon, Pain Suppression, Guardian Spirit, Blessing of Protection, and similar. Note: instant heals like Lay on Hands leave no persistent aura and cannot be tracked this way.",
                        order = 1,
                        width = "full",
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
                        desc  = "Also show major defensive cooldowns you cast on yourself — Divine Shield, Ice Block, and similar. Displayed alongside externals received from allies.",
                        order = 2,
                        width = "full",
                        get   = function() local db = GetExtDB(); return db and db.showBigDefensives end,
                        set   = function(_, val)
                            local db = GetExtDB()
                            if db then
                                db.showBigDefensives = val
                                if AD.RefreshExternals then AD.RefreshExternals() end
                            end
                        end,
                    },

                    extEnabledDesc = {
                        type     = "description",
                        name     = "Drag the icon grid anywhere on screen — position saves automatically when you release.",
                        order    = 3,
                        fontSize = "small",
                        width    = "full",
                    },

                    extSep1 = { type = "description", name = "", order = 4, width = "full" },

                    -- ── Layout ────────────────────────────────────────────────
                    extLayoutHeader = (function()
                        local h = CH("extLayout")
                        h.name  = "Layout"
                        h.order = 10
                        return h
                    end)(),

                    extLayoutGroup = MakeLayoutGroup(
                        "extLayout", GetExtDB,
                        function() if AD.ApplyExtSettings then AD.ApplyExtSettings() end end,
                        10
                    ),

                    -- ── Border ────────────────────────────────────────────────
                    extBorderHeader = (function()
                        local h = CH("extBorder")
                        h.name  = "Border"
                        h.order = 20
                        return h
                    end)(),

                    extBorderGroup = {
                        type   = "group",
                        name   = "Border",
                        inline = true,
                        order  = 21,
                        hidden = hide("extBorder"),
                        args   = {
                            extBorderColor = {
                                type     = "color",
                                name     = "Border Color",
                                desc     = "Color of the border strip shown around each external defensive icon.",
                                order    = 1,
                                width    = 1.0,
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
                            extBorderBreak = { type = "description", name = "", order = 2, width = "full" },
                            extBorderWidth = {
                                type  = "range",
                                name  = "Border Thickness",
                                desc  = "Width in pixels of the colored border strip around each icon.",
                                order = 3,
                                min   = 0, max = 8, step = 1,
                                width = 1.4,
                                get   = function() local db = GetExtDB(); return db and db.borderWidth or 2 end,
                                set   = function(_, v)
                                    local db = GetExtDB()
                                    if db then db.borderWidth = v; if AD.ApplyExtSettings then AD.ApplyExtSettings() end end
                                end,
                            },
                            extBorderGlow = {
                                type  = "toggle",
                                name  = "Border Glow",
                                desc  = "Add a pixel glow effect around each icon, matching the border color — the same style used on CDM icons.",
                                order = 4,
                                width = 1.2,
                                get   = function() local db = GetExtDB(); return db and db.borderGlow end,
                                set   = function(_, v)
                                    local db = GetExtDB()
                                    if db then db.borderGlow = v; if AD.RefreshExternals then AD.RefreshExternals() end end
                                end,
                            },
                            extGlowWidth = {
                                type   = "range",
                                name   = "Glow Thickness",
                                desc   = "Line thickness of the pixel glow.",
                                order  = 5,
                                min    = 1, max = 6, step = 1,
                                width  = 1.2,
                                hidden = function() local db = GetExtDB(); return not db or not db.borderGlow end,
                                get    = function() local db = GetExtDB(); return db and db.glowWidth or 2 end,
                                set    = function(_, v)
                                    local db = GetExtDB()
                                    if db then db.glowWidth = v; if AD.RefreshExternals then AD.RefreshExternals() end end
                                end,
                            },
                        },
                    },

                    -- ── Display ───────────────────────────────────────────────
                    extDisplayHeader = (function()
                        local h = CH("extDisplay")
                        h.name  = "Display"
                        h.order = 30
                        return h
                    end)(),

                    extDisplayGroup = MakeDisplayGroup(
                        "extDisplay", GetExtDB,
                        function() if AD.ApplyExtSettings then AD.ApplyExtSettings() end end,
                        function() if AD.ApplyExtPosition then AD.ApplyExtPosition() end end,
                        30
                    ),

                    -- ── Blocklist ─────────────────────────────────────────────
                    extBlocklistHeader = (function()
                        local h = CH("extBlocklist")
                        h.name  = "Blocklist"
                        h.order = 35
                        return h
                    end)(),

                    extBlocklistGroup = {
                        type   = "group",
                        name   = "Blocklist",
                        inline = true,
                        order  = 36,
                        hidden = hide("extBlocklist"),
                        args   = function()
                            local args = {
                                extBlocklistDesc = {
                                    type     = "description",
                                    name     = "Spell IDs listed here are suppressed from the externals display.\n\n|cffaaaaaa\226\129\185 spellId filtering is skipped inside instances due to WoW 12.0 secret values.|r",
                                    order    = 1,
                                    fontSize = "small",
                                    width    = "full",
                                },
                                extBlocklistEnabled = {
                                    type  = "toggle",
                                    name  = "Enable Blocklist",
                                    desc  = "When on, externals whose spell ID appears in the list below are hidden from the display.",
                                    order = 2,
                                    width = 1.5,
                                    get   = function()
                                        local db = GetExtDB()
                                        return db == nil or db.blacklistEnabled ~= false
                                    end,
                                    set   = function(_, v)
                                        local db = GetExtDB()
                                        if db then
                                            db.blacklistEnabled = v
                                            if AD.RefreshExternals then AD.RefreshExternals() end
                                        end
                                    end,
                                },
                                extAddSpellId = {
                                    type  = "input",
                                    name  = "Spell ID",
                                    desc  = "Type a numeric spell ID, then click Add.",
                                    order = 3,
                                    width = 1.1,
                                    get   = function() return AD._extPendingID or "" end,
                                    set   = function(_, v) AD._extPendingID = v end,
                                },
                                extAddButton = {
                                    type  = "execute",
                                    name  = "Add",
                                    desc  = "Add the spell ID above to the blocklist.",
                                    order = 4,
                                    width = 0.55,
                                    func  = function()
                                        local id = tonumber(AD._extPendingID)
                                        if not id or id < 1 then return end
                                        local db = GetExtDB()
                                        if db then
                                            db.blacklist = db.blacklist or {}
                                            db.blacklist[id] = true
                                            AD._extPendingID = ""
                                            if AD.RefreshExternals then AD.RefreshExternals() end
                                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                        end
                                    end,
                                },
                                extClearAll = {
                                    type  = "execute",
                                    name  = "Clear All",
                                    desc  = "Remove every spell ID from the blocklist.",
                                    order = 5,
                                    width = 0.85,
                                    func  = function()
                                        local db = GetExtDB()
                                        if db then
                                            db.blacklist = {}
                                            if AD.RefreshExternals then AD.RefreshExternals() end
                                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                        end
                                    end,
                                },
                                extListBreak = { type = "description", name = "", order = 9, width = "full" },
                            }
                            local db = GetExtDB()
                            if db and db.blacklist then
                                local order = 10
                                for spellId, active in pairs(db.blacklist) do
                                    if active then
                                        local sname = C_Spell.GetSpellName and C_Spell.GetSpellName(spellId)
                                        local label = sname
                                            and (sname .. "  [" .. spellId .. "]")
                                            or  ("Spell " .. spellId)
                                        args["extbl_" .. spellId] = {
                                            type  = "execute",
                                            name  = label,
                                            desc  = "Click to remove this spell from the blocklist.",
                                            order = order,
                                            width = 2.0,
                                            func  = function()
                                                local db2 = GetExtDB()
                                                if db2 and db2.blacklist then
                                                    db2.blacklist[spellId] = nil
                                                    if AD.RefreshExternals then AD.RefreshExternals() end
                                                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                                end
                                            end,
                                        }
                                        order = order + 1
                                    end
                                end
                            end
                            return args
                        end,
                    },

                    -- ── Position ──────────────────────────────────────────────
                    extPositionHeader = (function()
                        local h = CH("extPosition")
                        h.name  = "Position"
                        h.order = 40
                        return h
                    end)(),

                    extPositionGroup = {
                        type   = "group",
                        name   = "Position",
                        inline = true,
                        order  = 41,
                        hidden = hide("extPosition"),
                        args   = {
                            extPosDesc = {
                                type     = "description",
                                name     = "Drag the frame or use the controls below to fine-tune placement. Open the ArcUI panel to reveal the drag handle above the icon grid.",
                                order    = 1,
                                fontSize = "small",
                                width    = "full",
                            },
                            extPosAnchor = {
                                type   = "select",
                                name   = "Anchor Point",
                                desc   = "Which corner/edge of the icon grid is used as the anchor.",
                                order  = 2,
                                width  = 1.35,
                                values = ANCHOR_POINTS,
                                get    = function()
                                    local db = GetExtDB(); local p = db and db.position
                                    return p and p.point or "CENTER"
                                end,
                                set    = function(_, v)
                                    local db = GetExtDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.point = v
                                        if AD.ApplyExtPosition then AD.ApplyExtPosition() end
                                    end
                                end,
                            },
                            extRelAnchor = {
                                type   = "select",
                                name   = "Relative To Point",
                                desc   = "Which point on the target frame the anchor attaches to.",
                                order  = 3,
                                width  = 1.35,
                                values = ANCHOR_POINTS,
                                get    = function()
                                    local db = GetExtDB(); local p = db and db.position
                                    return p and p.relativePoint or "CENTER"
                                end,
                                set    = function(_, v)
                                    local db = GetExtDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.relativePoint = v
                                        if AD.ApplyExtPosition then AD.ApplyExtPosition() end
                                    end
                                end,
                            },
                            extRelativeFrame = {
                                type   = "select",
                                name   = "Attach to Frame",
                                desc   = "Frame the position anchors to. If the chosen frame doesn't exist, falls back to the screen.",
                                order  = 4,
                                width  = 1.8,
                                values = ANCHOR_FRAMES,
                                get    = function()
                                    local db = GetExtDB(); local p = db and db.position
                                    return p and p.relativeFrame or "UIParent"
                                end,
                                set    = function(_, v)
                                    local db = GetExtDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.relativeFrame = v
                                        if AD.ApplyExtPosition then AD.ApplyExtPosition() end
                                    end
                                end,
                            },
                            extPosBreakAnchors = { type = "description", name = "", order = 5, width = "full" },
                            extPosX = {
                                type  = "range",
                                name  = "X Offset",
                                order = 6,
                                min   = -2000, max = 2000, step = 1,
                                width = 1.4,
                                get   = function()
                                    local db = GetExtDB(); local p = db and db.position
                                    return p and p.x or 0
                                end,
                                set   = function(_, v)
                                    local db = GetExtDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.x = v
                                        if AD.ApplyExtPosition then AD.ApplyExtPosition() end
                                    end
                                end,
                            },
                            extPosY = {
                                type  = "range",
                                name  = "Y Offset",
                                order = 7,
                                min   = -1200, max = 1200, step = 1,
                                width = 1.4,
                                get   = function()
                                    local db = GetExtDB(); local p = db and db.position
                                    return p and p.y or -260
                                end,
                                set   = function(_, v)
                                    local db = GetExtDB()
                                    if db then
                                        db.position = db.position or {}
                                        db.position.y = v
                                        if AD.ApplyExtPosition then AD.ApplyExtPosition() end
                                    end
                                end,
                            },
                            extPosBreak = { type = "description", name = "", order = 8, width = "full" },
                            extResetPosition = {
                                type  = "execute",
                                name  = "Reset to Center",
                                desc  = "Move the externals icon grid back to the center of the screen.",
                                order = 9,
                                width = 1.4,
                                func  = function()
                                    local db = GetExtDB()
                                    if db then
                                        db.position = { point="CENTER", relativePoint="CENTER", x=0, y=-260, relativeFrame="UIParent" }
                                        if AD.ApplyExtPosition then AD.ApplyExtPosition() end
                                    end
                                end,
                            },
                        },
                    },
                },
            },
        },
    }
end
