-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_CustomIcons_Options.lua
--
-- Provides the "Custom Icons" sub-tab under Arc Auras in the Options UI.
-- Owns three things:
--   1. Creation form for new custom timer icons (spellID, duration, trigger)
--   2. A timer-only mini-catalog (subset of Arc Auras' tracked list)
--   3. Per-timer editor pane (duration, trigger type, reset behavior, actions)
--
-- Shares selection state with the main Arc Auras catalog via the public
-- accessors on ns.ArcAurasOptions (GetSelectedArcAura / SetSelected /
-- ToggleMultiSelect / InvalidateCache). Selecting a timer here highlights
-- the same entry in the Main tab's catalog and vice versa — editing stays
-- in sync regardless of which tab the user is on.
--
-- Engine interaction: ns.ArcAurasTimer.AddTimer / RemoveTimer /
-- UpdateTimerConfig / StartTimer / StopTimer / ApplyIconOverride.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local CustomIcons = {}
ns.CustomIconsOptions = CustomIcons

-- Local UI state
local pendingTimerSpellID     = ""
local pendingTimerDuration    = ""
local pendingStartTrigger     = "cast"
local pendingEndTrigger       = "none"

-- Collapsible section state for this tab. Keys match the CollapsibleHeader
-- toggles below. Default all expanded.
local collapsed = {
    creation = false,
    catalog  = false,
    presets  = true,   -- closed by default; users opt into the library
    -- Editor subsections — closed by default; user opens each when needed
    editIcon        = true,
    editSpecTalents = true,
    editStart       = true,
    editStacks      = true,
    editEnd         = true,
    editActions     = true,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function IsArcDisabled()
    -- ns.ArcAuras is the module's registered public table. We cannot capture
    -- it at file-load time because this file loads before ns.ArcAuras may be
    -- populated — but the function runs at UI render time, by which point
    -- ns.ArcAuras is reliably available. Original bug: this referenced a
    -- bare `ArcAuras` global which never exists, so IsArcDisabled always
    -- returned true and every input rendered permanently disabled.
    local arc = ns.ArcAuras
    return not (arc and arc.IsEnabled and arc.IsEnabled())
end

-- Fetch the timer-only subset of the Arc Auras tracked list. We reuse the
-- main module's GetTrackedItems so item order / cache / filtering stays
-- consistent with the Main tab catalog.
local function GetTimersList()
    local all = ns.ArcAurasOptions
           and ns.ArcAurasOptions.GetTrackedItems
           and ns.ArcAurasOptions.GetTrackedItems()
           or {}
    local out = {}
    for _, e in ipairs(all) do
        if e.arcType == "timer" then
            out[#out + 1] = e
        end
    end
    return out
end

local function GetSelectedTimer()
    local arcID = ns.ArcAurasOptions and ns.ArcAurasOptions.GetSelectedArcAura
        and ns.ArcAurasOptions.GetSelectedArcAura()
    if not arcID then return nil end
    for _, e in ipairs(GetTimersList()) do
        if e.arcID == arcID then return e end
    end
    return nil
end

local function HasTimerSelected()
    return GetSelectedTimer() ~= nil
end

local function NotifyRefresh()
    if ns.ArcAurasOptions and ns.ArcAurasOptions.InvalidateCache then
        ns.ArcAurasOptions.InvalidateCache()
    end
    if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
        ns.CDMEnhanceOptions.InvalidateCache()
    end
    local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
    if reg then reg:NotifyChange("ArcUI") end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CATALOG BUTTON BUILDER (mirrors Arc Auras main catalog style)
-- ═══════════════════════════════════════════════════════════════════════════

-- Each timer entry renders as an execute button whose image is the icon
-- texture, whose `name` shows a small status tag, and whose click toggles
-- selection via ns.ArcAurasOptions.SetSelected / ToggleMultiSelect.
local function BuildCatalogEntry(index)
    return {
        type = "execute",
        name = function()
            local list = GetTimersList()
            local entry = list[index]
            if not entry then return "" end
            local selectedSingle = ns.ArcAurasOptions and ns.ArcAurasOptions.GetSelectedArcAura
                and ns.ArcAurasOptions.GetSelectedArcAura()
            local multi = ns.ArcAurasOptions and ns.ArcAurasOptions.GetSelectedArcAuras
                and ns.ArcAurasOptions.GetSelectedArcAuras() or {}
            local isSelected = (selectedSingle == entry.arcID) or multi[entry.arcID]
            local isMulti = multi[entry.arcID]
            local hasCustom = ns.CDMEnhance and ns.CDMEnhance.HasPerIconSettings
                and ns.CDMEnhance.HasPerIconSettings(entry.arcID)

            -- Match the Main tab catalog's status string format exactly.
            local status = "|cffffcc00T|r "   -- gold T = custom timer
            if isMulti then
                status = status .. (hasCustom and "|cff00ff00Multi|r |cffaa55ff*|r" or "|cff00ff00Multi|r")
            elseif isSelected then
                status = status .. (hasCustom and "|cff00ff00Edit|r |cffaa55ff*|r" or "|cff00ff00Edit|r")
            elseif hasCustom then
                status = status .. "|cffaa55ff*|r"
            end
            return status
        end,
        desc = function()
            local entry = GetTimersList()[index]
            if not entry then return "" end
            local d = "|cffffd700" .. entry.name .. "|r"
            d = d .. "\nSpell ID: " .. tostring(entry.spellID or "?")
            d = d .. "\nArc ID: "  .. entry.arcID
            d = d .. "\nDuration: " .. tostring(entry.duration or "?") .. "s"

            -- Resolve triggers: prefer new-shape `events` set, fall back to
            -- legacy single `event` field, then to v1 `triggerType`. For the
            -- tooltip, format as a comma-joined list of friendly labels.
            local startLabels = {
                cast = "Cast Success", cooldown = "Cooldown Event",
                proc = "Proc Glow",
            }
            local endLabels = {
                cast = "Cast Success", proc = "Proc Glow Start",
                procEnd = "Proc Glow End", death = "On Death",
            }

            local function labelList(trig, legacyField, labels, emptyStr)
                if type(trig) == "table" and type(trig.events) == "table"
                   and next(trig.events) then
                    -- Keep a deterministic order so tooltips don't shuffle.
                    local ordered = { "cast", "cooldown", "proc", "procEnd", "death" }
                    local parts = {}
                    for _, k in ipairs(ordered) do
                        if trig.events[k] then
                            parts[#parts + 1] = labels[k] or k
                        end
                    end
                    return table.concat(parts, ", ")
                end
                -- Legacy v2 single .event field
                if type(trig) == "table" and type(trig.event) == "string"
                   and trig.event ~= "none" then
                    return labels[trig.event] or trig.event
                end
                -- Legacy v1 triggerType at top-level
                if type(legacyField) == "string" and labels[legacyField] then
                    return labels[legacyField]
                end
                return emptyStr
            end

            local startStr = labelList(entry.config and entry.config.startTrigger,
                entry.config and entry.config.triggerType, startLabels, "(none)")
            local endStr = labelList(entry.config and entry.config.endTrigger,
                nil, endLabels, "(none)")

            d = d .. "\nStart: |cff88ccff" .. startStr .. "|r"
            d = d .. "\nEnd:   |cff88ccff" .. endStr   .. "|r"

            -- Restart-on-refire lives on the startTrigger. Fall back to the
            -- legacy resetOnRecast bool for un-migrated configs.
            local restart = (entry.config and entry.config.startTrigger
                and entry.config.startTrigger.restartOnRefire == true)
                or (entry.config and entry.config.resetOnRecast == true)
            d = d .. "\nRestart on re-fire: " .. (restart and "|cff00ff00Yes|r" or "|cff666666No|r")

            if entry.hasIconOverride then
                d = d .. "\n|cffFFCC00Custom Icon|r (ID: " ..
                    tostring(entry.config.iconID or entry.config.icon or "?") .. ")"
            end
            d = d .. "\n\n|cff888888Click to select  •  Shift+Click multi-select|r"
            return d
        end,
        image = function()
            -- Return nil for empty slots — matches the Main tab catalog
            -- pattern. Entire button is also hidden below, so no image
            -- texture shows for non-existent entries (no "?" placeholders).
            local e = GetTimersList()[index]
            return e and e.icon or nil
        end,
        imageWidth = 32,
        imageHeight = 32,
        order = 100 + index,
        width = 0.25,
        hidden = function()
            if collapsed.catalog then return true end
            return GetTimersList()[index] == nil
        end,
        func = function()
            local entry = GetTimersList()[index]
            if not entry then return end
            if IsShiftKeyDown() then
                if ns.ArcAurasOptions and ns.ArcAurasOptions.ToggleMultiSelect then
                    ns.ArcAurasOptions.ToggleMultiSelect(entry.arcID)
                end
            else
                local cur = ns.ArcAurasOptions and ns.ArcAurasOptions.GetSelectedArcAura
                    and ns.ArcAurasOptions.GetSelectedArcAura()
                if ns.ArcAurasOptions and ns.ArcAurasOptions.SetSelected then
                    ns.ArcAurasOptions.SetSelected(cur == entry.arcID and nil or entry.arcID)
                end
            end
            NotifyRefresh()
        end,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC: options table
-- ═══════════════════════════════════════════════════════════════════════════

function ns.GetCustomIconsOptionsTable()
    local args = {}

    -- ── Intro ──
    args.introDesc = {
        type = "description",
        name = "|cff00CCFFCustom Icons|r\n\n"
            .. "|cff888888Create timer-driven icons for effects whose duration or cooldown isn't exposed "
            .. "through the normal spell API — buff windows, ICDs on passive procs, talent proxies, "
            .. "or any simulated cooldown.|r\n",
        order = 1,
        width = "full",
        fontSize = "medium",
    }

    -- ═══════════════════════════════════════════════════════════════════════
    -- SECTION 0 — PRESETS (ready-made timers for known use cases)
    -- Rendered as a compact icon grid, same style as the Existing Timers
    -- catalog below. Click an icon to install that preset.
    -- ═══════════════════════════════════════════════════════════════════════
    args.presetsHeader = {
        type = "toggle",
        name = "|cffffd700Presets|r  |cff888888(pre-built timers for your class)|r",
        desc = "Click to expand/collapse.",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsed.presets end,
        set = function(_, v) collapsed.presets = not v end,
        order = 5,
        width = "full",
    }
    args.presetsLegend = {
        type = "description",
        name = "|cff888888Click an icon to install. Already-installed presets are dimmed.|r",
        order = 5.1,
        width = "full",
        fontSize = "small",
        hidden = function() return collapsed.presets end,
    }

    -- Build one icon button per class-relevant preset. Iterate on every
    -- render so class-change picks up new entries automatically. Each
    -- button mirrors the Existing Timers catalog style (32x32 icon,
    -- 0.25 width, nil image when there's nothing to show).
    local presets = (ns.GetCustomIconPresetsForPlayer
                     and ns.GetCustomIconPresetsForPlayer()) or {}
    for i, preset in ipairs(presets) do
        local key = "preset_" .. (preset.id or tostring(i))

        args[key .. "_icon"] = {
            type = "execute",
            name = function()
                -- Minimal badge under the icon — just shows install state.
                local installed = ns.IsPresetInstalled and ns.IsPresetInstalled(preset)
                return installed and "|cff888888Installed|r" or "|cff00ff00Add|r"
            end,
            desc = function()
                local d = "|cffffd700" .. (preset.name or "?") .. "|r"
                local installed = ns.IsPresetInstalled and ns.IsPresetInstalled(preset)
                if installed then
                    d = d .. "\n|cff888888Already installed.|r"
                else
                    d = d .. "\n|cff00ff00Click to install.|r"
                end
                return d
            end,
            image = function()
                -- Resolve the preset's spell icon lazily via C_Spell. If
                -- the API isn't ready yet (rare, early-load edge case),
                -- fall back to the question-mark icon; AceConfig handles
                -- nil gracefully by rendering no image.
                local info = preset.spellID and C_Spell.GetSpellInfo(preset.spellID)
                return info and (info.iconID or info.originalIconID) or nil
            end,
            imageWidth = 32,
            imageHeight = 32,
            order = 6 + i * 0.01,
            width = 0.25,
            disabled = function()
                return IsArcDisabled()
                    or (ns.IsPresetInstalled and ns.IsPresetInstalled(preset))
            end,
            hidden = function() return collapsed.presets end,
            func = function()
                if not ns.AddTimerFromPreset then return end
                local ok, result = ns.AddTimerFromPreset(preset)
                if ok then
                    print(string.format(
                        "|cff00CCFF[Arc Auras]|r Installed preset: %s",
                        preset.name or "?"))
                    if result and ns.ArcAurasOptions and ns.ArcAurasOptions.SetSelected then
                        ns.ArcAurasOptions.SetSelected(result)
                    end
                    NotifyRefresh()
                else
                    print("|cff00CCFF[Arc Auras]|r Preset failed: "
                        .. tostring(result))
                end
            end,
        }
    end

    -- Empty-state message when there are no presets for this class.
    args.presetsEmpty = {
        type = "description",
        name = "|cff888888No presets available for your class yet.|r",
        order = 9,
        width = "full",
        fontSize = "small",
        hidden = function()
            return collapsed.presets or #presets > 0
        end,
    }

    -- ═══════════════════════════════════════════════════════════════════════
    -- SECTION 1 — CREATE NEW TIMER
    -- ═══════════════════════════════════════════════════════════════════════
    args.creationHeader = {
        type = "toggle",
        name = "|cffffd700Create New Timer|r",
        desc = "Click to expand/collapse",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsed.creation end,
        set = function(_, v) collapsed.creation = not v end,
        order = 10,
        width = "full",
    }
    args.creationSpellInput = {
        type = "input",
        name = "Spell ID",
        desc = "Spell ID to watch. The timer starts when the selected trigger event fires for this ID.",
        order = 11,
        width = 0.8,
        disabled = IsArcDisabled,
        hidden = function() return collapsed.creation end,
        get = function() return pendingTimerSpellID end,
        set = function(_, val)
            pendingTimerSpellID = (val or ""):gsub("[^%d]", "")
        end,
    }
    args.creationDurationInput = {
        type = "input",
        name = "Duration (seconds)",
        desc = "How long the cooldown swipe runs. Decimals allowed (e.g. 1.5). Maximum: 7200 (2 hours).",
        order = 12,
        width = 0.8,
        disabled = IsArcDisabled,
        hidden = function() return collapsed.creation end,
        get = function() return pendingTimerDuration end,
        set = function(_, val)
            pendingTimerDuration = (val or ""):gsub("[^%d%.]", "")
        end,
    }
    args.creationStartTrigger = {
        type = "select",
        name = "Start Trigger",
        desc = "What event starts the timer.",
        order = 13,
        width = 1.2,
        disabled = IsArcDisabled,
        hidden = function() return collapsed.creation end,
        values = {
            cast     = "Cast Success",
            cooldown = "Cooldown Event",
            proc     = "Proc Glow",
        },
        sorting = { "cast", "cooldown", "proc" },
        get = function() return pendingStartTrigger end,
        set = function(_, v)
            if v ~= "cast" and v ~= "cooldown" and v ~= "proc" then v = "cast" end
            pendingStartTrigger = v
        end,
    }
    args.creationEndTrigger = {
        type = "select",
        name = "End Trigger",
        desc = "What event stops the timer early. 'None' means timer runs to full duration.",
        order = 13.5,
        width = 1.2,
        disabled = IsArcDisabled,
        hidden = function() return collapsed.creation end,
        values = {
            none    = "None",
            cast    = "Cast Success",
            proc    = "Proc Glow Start",
            procEnd = "Proc Glow End",
            death   = "On Death",
        },
        sorting = { "none", "cast", "proc", "procEnd", "death" },
        get = function() return pendingEndTrigger end,
        set = function(_, v)
            if v ~= "none" and v ~= "cast" and v ~= "proc"
               and v ~= "procEnd" and v ~= "death" then
                v = "none"
            end
            pendingEndTrigger = v
        end,
    }
    args.creationAddBtn = {
        type = "execute",
        name = "|cffffd700Add Timer|r",
        desc = "Create the timer with the values above.",
        order = 14,
        width = 0.8,
        disabled = IsArcDisabled,
        hidden = function() return collapsed.creation end,
        func = function()
            local spellID = tonumber(pendingTimerSpellID)
            local dur     = tonumber(pendingTimerDuration)
            if not spellID or spellID <= 0 then
                print("|cff00CCFF[Arc Auras]|r Invalid spell ID.")
                return
            end
            if not dur or dur <= 0 then
                print("|cff00CCFF[Arc Auras]|r Duration must be a positive number.")
                return
            end
            if dur > 7200 then dur = 7200 end

            if ns.ArcAurasTimer and ns.ArcAurasTimer.AddTimer then
                -- Creation form is deliberately single-select. Map the
                -- chosen event to a one-element events set. User can add
                -- more events in the editor after creation.
                local startEvents = { [pendingStartTrigger] = true }
                local endEvents   = (pendingEndTrigger ~= "none")
                    and { [pendingEndTrigger] = true } or {}
                local ok, result = ns.ArcAurasTimer.AddTimer(spellID, dur, {
                    startTrigger = { events = startEvents, spellID = nil,
                                     restartOnRefire = false },
                    endTrigger   = { events = endEvents,   spellID = nil },
                })
                if ok then
                    local info = C_Spell.GetSpellInfo(spellID)
                    local name = info and info.name or ("Spell " .. spellID)
                    local startLabel = ({
                        cast = "Cast Success", cooldown = "Cooldown Event",
                        proc = "Proc Glow",
                    })[pendingStartTrigger] or pendingStartTrigger
                    local endLabel = ({
                        none = "None", cast = "Cast Success",
                        proc = "Proc Glow Start", procEnd = "Proc Glow End",
                        death = "On Death",
                    })[pendingEndTrigger] or pendingEndTrigger
                    print(string.format(
                        "|cff00CCFF[Arc Auras]|r Added timer: %s  |cff888888(%.3gs, start: %s, end: %s)|r",
                        name, dur, startLabel, endLabel))
                    -- Select the newly-created timer so the editor below
                    -- opens on it immediately.
                    if result and ns.ArcAurasOptions and ns.ArcAurasOptions.SetSelected then
                        ns.ArcAurasOptions.SetSelected(result)
                    end
                    pendingTimerSpellID = ""
                    pendingTimerDuration = ""
                    -- Leave trigger choices at the user's last selection so
                    -- batch-creating similar timers is faster.
                    NotifyRefresh()
                else
                    print("|cff00CCFF[Arc Auras]|r Failed: " .. tostring(result))
                end
            end
        end,
    }

    -- ═══════════════════════════════════════════════════════════════════════
    -- SECTION 2 — EXISTING TIMERS CATALOG (timer-only)
    -- ═══════════════════════════════════════════════════════════════════════
    args.catalogHeader = {
        type = "toggle",
        name = function()
            local count = #GetTimersList()
            return string.format("|cffffd700Existing Timers|r (%d)", count)
        end,
        desc = "Click to expand/collapse",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsed.catalog end,
        set = function(_, v) collapsed.catalog = not v end,
        order = 30,
        width = "full",
    }
    args.catalogEmpty = {
        type = "description",
        name = "|cff888888No custom timers yet. Create one above.|r",
        order = 31,
        width = "full",
        fontSize = "small",
        hidden = function()
            return collapsed.catalog or #GetTimersList() > 0
        end,
    }
    args.catalogLegend = {
        type = "description",
        name = "|cff888888Legend: |cffffcc00T|r=Timer  |cff00ff00Edit|r=Selected  |cffaa55ff*|r=Custom CDM Settings|r",
        order = 32,
        width = "full",
        fontSize = "small",
        hidden = function()
            return collapsed.catalog or #GetTimersList() == 0
        end,
    }

    -- Pre-allocate catalog slots. 25 is plenty for practical use; more would
    -- mean the user has heavily specialized builds.
    for i = 1, 25 do
        args["timerCatalog" .. i] = BuildCatalogEntry(i)
    end

    -- ═══════════════════════════════════════════════════════════════════════
    -- SECTION 3 — SELECTED TIMER EDITOR
    -- Hidden entirely when no timer is selected.
    -- ═══════════════════════════════════════════════════════════════════════
    local function EditorHidden()
        return collapsed.editor or not HasTimerSelected()
    end

    -- Editor sub-sections show inline whenever a timer is selected. No
    -- wrapper collapsible — the only "toggle" for the editor is the act
    -- of clicking (or deselecting) a timer in the Existing Timers list.
    local function EditorHidden()
        return not HasTimerSelected()
    end

    -- Small helper-text shown when nothing is selected. Replaces the old
    -- "Edit Timer (select one above)" wrapper header.
    args.editorNoSelection = {
        type = "description",
        name = "\n|cff888888Select a timer from the Existing Timers list above to edit it.|r",
        order = 200,
        width = "full",
        fontSize = "small",
        hidden = function() return HasTimerSelected() end,
    }
    args.editorSelectedHeader = {
        type = "description",
        name = function()
            local e = GetSelectedTimer()
            if not e then return "" end
            return "\n|cffffd700Editing:|r  " .. (e.name or "?")
        end,
        order = 201,
        width = "full",
        fontSize = "medium",
        hidden = EditorHidden,
    }

    -- ── Icon ──
    args.editorIconSubhead = {
        type = "toggle",
        name = "|cff88ccffIcon|r",
        desc = "Click to expand/collapse",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsed.editIcon end,
        set = function(_, v) collapsed.editIcon = not v end,
        order = 210,
        width = "full",
        hidden = EditorHidden,
    }
    args.editorIconOverride = {
        type = "input",
        name = "Icon ID",
        desc = "Enter an IconID (FileDataID) — the number shown as 'IconID' in a spell tooltip. "
            .. "0 resets to the tracked spell's default icon.",
        order = 211,
        width = 0.8,
        hidden = function() return EditorHidden() or collapsed.editIcon end,
        get = function()
            local e = GetSelectedTimer()
            if e and e.config then
                if e.config.iconID then return tostring(e.config.iconID) end
            end
            return ""
        end,
        set = function(_, val)
            local n = tonumber(((val or ""):gsub("[^%d]", "")))
            local e = GetSelectedTimer()
            if not e then return end
            if ns.ArcAurasTimer and ns.ArcAurasTimer.ApplyIconOverride then
                ns.ArcAurasTimer.ApplyIconOverride(e.arcID, n)
            end
            NotifyRefresh()
        end,
    }
    args.editorIconResetBtn = {
        type = "execute",
        name = "Reset Icon",
        desc = "Restore the tracked spell's default icon.",
        order = 212,
        width = 0.6,
        hidden = function() return EditorHidden() or collapsed.editIcon end,
        func = function()
            local e = GetSelectedTimer()
            if not e then return end
            if ns.ArcAurasTimer and ns.ArcAurasTimer.ApplyIconOverride then
                ns.ArcAurasTimer.ApplyIconOverride(e.arcID, nil)
            end
            NotifyRefresh()
        end,
    }

    -- ═══════════════════════════════════════════════════════════════════
    -- ── Spec & Talents ──
    -- Mirrors the spell cooldown panel's gating. Uses the SAME config
    -- fields (showOnSpecs, talentConditions, talentConditionMode) so the
    -- engine can reuse ArcAurasCooldown.ShouldFrameBeVisible directly.
    -- ═══════════════════════════════════════════════════════════════════
    args.editorSpecTalentsSubhead = {
        type = "toggle",
        name = "|cff88ccffSpec & Talents|r  |cff888888(optional)|r",
        desc = "Click to expand/collapse — restrict this timer to specific specs or talents.",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsed.editSpecTalents end,
        set = function(_, v) collapsed.editSpecTalents = not v end,
        order = 215,
        width = "full",
        hidden = EditorHidden,
    }
    args.editorSpecTalentsDesc = {
        type = "description",
        name = "|cff888888By default this timer shows on all specs whenever its trigger fires. "
            .. "Use these controls to restrict it to specific specs or require certain talents be active.|r",
        order = 215.05,
        width = "full",
        fontSize = "small",
        hidden = function() return EditorHidden() or collapsed.editSpecTalents end,
    }

    -- Helpers scoped to the spec picker. Mirror ArcUI_ArcAuras_Options.lua's
    -- pattern: if showOnSpecs is nil / empty, treat as "show on all specs";
    -- when user unchecks the last one we seed the list with every spec id
    -- so toggling again doesn't orphan the entry.
    local function GetTimerCfg()
        local e = GetSelectedTimer()
        return e and e.config or nil
    end

    local function IsSpecEnabled(specNum)
        local cfg = GetTimerCfg()
        if not cfg or not cfg.showOnSpecs or #cfg.showOnSpecs == 0 then return true end
        for _, spec in ipairs(cfg.showOnSpecs) do
            if spec == specNum then return true end
        end
        return false
    end

    local function SetSpecEnabled(specNum, value)
        local cfg = GetTimerCfg()
        if not cfg then return end
        if not cfg.showOnSpecs then cfg.showOnSpecs = {} end
        if value then
            local found = false
            for _, s in ipairs(cfg.showOnSpecs) do
                if s == specNum then found = true break end
            end
            if not found then table.insert(cfg.showOnSpecs, specNum) end
        else
            -- Seed with all specs first so removing one leaves a meaningful
            -- remainder (otherwise the list would be empty, which means
            -- "show on all" — the opposite of what the user clicked).
            if #cfg.showOnSpecs == 0 then
                local numSpecs = GetNumSpecializations() or 4
                for i = 1, numSpecs do
                    table.insert(cfg.showOnSpecs, i)
                end
            end
            for i = #cfg.showOnSpecs, 1, -1 do
                if cfg.showOnSpecs[i] == specNum then
                    table.remove(cfg.showOnSpecs, i)
                end
            end
        end
        -- If all specs are checked, clear to nil (= show on all specs).
        local numSpecs = GetNumSpecializations() or 4
        if #cfg.showOnSpecs >= numSpecs then
            local seen = {}
            for _, s in ipairs(cfg.showOnSpecs) do seen[s] = true end
            local allChecked = true
            for i = 1, numSpecs do
                if not seen[i] then allChecked = false break end
            end
            if allChecked then cfg.showOnSpecs = nil end
        end
        if ns.ArcAurasTimer and ns.ArcAurasTimer.RefreshSpecVisibility then
            ns.ArcAurasTimer.RefreshSpecVisibility()
        end
        NotifyRefresh()
    end

    -- 4 spec toggles. Same width / ordering pattern as the spell panel.
    for specNum = 1, 4 do
        args["editorShowOnSpec" .. specNum] = {
            type = "toggle",
            name = function()
                local _, specName, _, specIcon = GetSpecializationInfo(specNum)
                if specIcon and specName then
                    return string.format("|T%s:14:14:0:0|t %s", specIcon, specName)
                end
                return specName or ("Spec " .. specNum)
            end,
            desc = function()
                local _, specName = GetSpecializationInfo(specNum)
                return specName and ("Show on " .. specName) or ("Show on Spec " .. specNum)
            end,
            order = 215.1 + (specNum * 0.01),
            width = 0.85,
            get = function() return IsSpecEnabled(specNum) end,
            set = function(_, val) SetSpecEnabled(specNum, val) end,
            hidden = function()
                if EditorHidden() or collapsed.editSpecTalents then return true end
                return (GetNumSpecializations() or 4) < specNum
            end,
        }
    end

    -- Talent conditions — delegate entirely to ns.TalentPicker, the same
    -- module the spell panel uses. We just render the summary + buttons.
    args.editorTalentCondHeader = {
        type = "description",
        name = "\n|cffffd700Talent Conditions:|r",
        order = 216,
        width = "full",
        fontSize = "medium",
        hidden = function() return EditorHidden() or collapsed.editSpecTalents end,
    }
    args.editorTalentCondSummary = {
        type = "description",
        name = function()
            local cfg = GetTimerCfg()
            if not cfg then return "" end
            if ns.TalentPicker and ns.TalentPicker.GetConditionSummary then
                return ns.TalentPicker.GetConditionSummary(cfg.talentConditions, cfg.talentConditionMode)
            end
            return "|cff888888No talent conditions|r"
        end,
        order = 216.1,
        width = "full",
        fontSize = "small",
        hidden = function() return EditorHidden() or collapsed.editSpecTalents end,
    }
    args.editorTalentCondEdit = {
        type = "execute",
        name = "Edit Talent Conditions",
        desc = "Open the talent picker to choose which talents must be active (or inactive) for this timer to show.",
        order = 216.2,
        width = 1.0,
        hidden = function() return EditorHidden() or collapsed.editSpecTalents end,
        func = function()
            local cfg = GetTimerCfg()
            if not cfg or not ns.TalentPicker then return end
            ns.TalentPicker.OpenPicker(cfg.talentConditions, cfg.talentConditionMode,
                function(conditions, matchMode)
                    cfg.talentConditions = conditions
                    cfg.talentConditionMode = matchMode
                    if ns.ArcAurasTimer and ns.ArcAurasTimer.RefreshSpecVisibility then
                        ns.ArcAurasTimer.RefreshSpecVisibility()
                    end
                    NotifyRefresh()
                end)
        end,
    }
    args.editorTalentCondClear = {
        type = "execute",
        name = "Clear",
        desc = "Remove all talent conditions. The timer will show whenever it would normally be visible.",
        order = 216.3,
        width = 0.5,
        hidden = function() return EditorHidden() or collapsed.editSpecTalents end,
        disabled = function()
            local cfg = GetTimerCfg()
            return not (cfg and cfg.talentConditions and #cfg.talentConditions > 0)
        end,
        func = function()
            local cfg = GetTimerCfg()
            if not cfg then return end
            cfg.talentConditions = nil
            cfg.talentConditionMode = nil
            if ns.ArcAurasTimer and ns.ArcAurasTimer.RefreshSpecVisibility then
                ns.ArcAurasTimer.RefreshSpecVisibility()
            end
            NotifyRefresh()
        end,
    }

    -- ═══════════════════════════════════════════════════════════════════
    -- ── Start Trigger ──
    -- Owns: editable spellID, duration, start event checkboxes,
    --       restart-on-refire toggle.
    -- ═══════════════════════════════════════════════════════════════════
    args.editorStartSubhead = {
        type = "toggle",
        name = "|cff88ccffStart Trigger|r",
        desc = "Click to expand/collapse — controls what event(s) start this timer.",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsed.editStart end,
        set = function(_, v) collapsed.editStart = not v end,
        order = 220,
        width = "full",
        hidden = EditorHidden,
    }
    args.editorSpellIDInput = {
        type = "input",
        name = "Spell ID",
        desc = "The spell ID this timer watches for. Changing this re-indexes the timer "
            .. "and updates its display icon (unless you have a custom Icon ID set above). "
            .. "Decimals are stripped; must be a positive integer.",
        order = 220.1,
        width = 0.8,
        hidden = function() return EditorHidden() or collapsed.editStart end,
        get = function()
            local e = GetSelectedTimer()
            return tostring((e and e.config and tonumber(e.config.spellID)) or "")
        end,
        set = function(_, val)
            local n = tonumber(((val or ""):gsub("[^%d]", "")))
            if not n or n <= 0 then
                print("|cff00CCFF[Arc Auras]|r Invalid spell ID.")
                return
            end
            local e = GetSelectedTimer()
            if not e or not e.config then return end
            e.config.spellID = n
            if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
            end
            NotifyRefresh()
        end,
    }
    args.editorDuration = {
        type = "input",
        name = "Duration (seconds)",
        desc = "How long the cooldown swipe runs after a Start Trigger fires. If an End Trigger fires before duration expires, the timer stops early. Decimals allowed. Max: 7200 (2 hours).",
        order = 220.2,
        width = 0.8,
        hidden = function() return EditorHidden() or collapsed.editStart end,
        get = function()
            local e = GetSelectedTimer()
            return tostring((e and e.config and tonumber(e.config.duration)) or 10)
        end,
        set = function(_, val)
            local n = tonumber(((val or ""):gsub("[^%d%.]", "")))
            if not n or n <= 0 then
                print("|cff00CCFF[Arc Auras]|r Duration must be a positive number.")
                return
            end
            if n > 7200 then n = 7200 end
            local e = GetSelectedTimer()
            if not e or not e.config then return end
            e.config.duration = n
            if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
            end
            NotifyRefresh()
        end,
    }
    args.editorStartEventsLabel = {
        type = "description",
        name = "\n|cffaaaaaaStart Events|r  |cff666666(any checked event starts the timer)|r",
        order = 220.3,
        width = "full",
        fontSize = "small",
        hidden = function() return EditorHidden() or collapsed.editStart end,
    }

    -- ─────────────────────────────────────────────────────────────────────
    -- Extra Spell IDs — multi-spell match list.
    --
    -- Optional. Adds alternate spellIDs that ALSO trigger this start/end
    -- event. Use case: one icon that tracks "any potion" — different IDs
    -- but same buff duration. The primary Spell ID still drives the icon
    -- and reverse lookup; extras are checked in the trigger matcher.
    --
    -- UX model: existing entries (1..#list) render as filled inputs with
    -- per-row remove buttons. ONE additional empty slot at position #list+1
    -- is always visible, ready to accept input — no "Add" button needed,
    -- typing a valid spellID into it commits the entry and the next empty
    -- slot becomes available. This avoids the engine-normalizes-and-strips
    -- placeholder problem (NormalizeConfigTriggers rejects 0/garbage IDs,
    -- so we can't store empty rows in the list itself).
    --
    -- BuildExtraSpellIDList(triggerKey, baseOrder, hideCheckFn, label)
    --   triggerKey  — "startTrigger" or "endTrigger"
    --   baseOrder   — order anchor; entries occupy +0.01 .. +0.09 above it
    --   hideCheckFn — closure returning true when the section is collapsed
    -- ─────────────────────────────────────────────────────────────────────
    local MAX_EXTRA_IDS = 12

    local function BuildExtraSpellIDList(triggerKey, baseOrder, hideCheckFn, label)
        local headerKey = string.format("editor_%s_extras_header", triggerKey)
        args[headerKey] = {
            type = "description",
            name = "\n|cffffd700" .. label .. ":|r  |cff666666(optional — additional spell IDs that also count as a match)|r",
            order = baseOrder,
            width = "full",
            fontSize = "small",
            hidden = hideCheckFn,
        }

        -- Returns the spellID at idx (or nil), and the timer entry.
        local function getExtra(idx)
            local e = GetSelectedTimer()
            if not e or not e.config or not e.config[triggerKey] then return nil, e end
            local list = e.config[triggerKey].extraSpellIDs
            if not list or idx > #list then return nil, e end
            return list[idx], e
        end

        -- Returns the current length of the extras list (or 0).
        local function listLen()
            local e = GetSelectedTimer()
            if not e or not e.config or not e.config[triggerKey] then return 0 end
            local list = e.config[triggerKey].extraSpellIDs
            return list and #list or 0
        end

        -- A row is shown if:
        --   1. idx <= #list (existing filled entry), OR
        --   2. idx == #list + 1 AND we haven't hit the cap (the editable
        --      "next" slot ready to accept new input).
        local function rowShown(idx)
            if hideCheckFn() then return false end
            local n = listLen()
            if idx <= n then return true end
            if idx == n + 1 and n < MAX_EXTRA_IDS then return true end
            return false
        end

        local function rowHidden(idx)
            return function() return not rowShown(idx) end
        end

        for idx = 1, MAX_EXTRA_IDS do
            local entryOrder = baseOrder + (idx * 0.01)
            local hideEntry = rowHidden(idx)

            args[string.format("editor_%s_extras_%d_input", triggerKey, idx)] = {
                type  = "input",
                name  = function()
                    local sid = getExtra(idx)
                    if sid and C_Spell and C_Spell.GetSpellInfo then
                        local info = C_Spell.GetSpellInfo(sid)
                        if info and info.name then
                            return string.format("Extra #%d  |cff888888(%s)|r", idx, info.name)
                        end
                    end
                    -- Empty "next" slot: prompt the user.
                    if idx == listLen() + 1 then
                        return string.format("Extra #%d  |cff666666(type a spell ID to add)|r", idx)
                    end
                    return string.format("Extra #%d", idx)
                end,
                desc  = "An additional spell ID that also starts/ends this timer. "
                     .. "Type a positive integer and press Enter to commit.",
                order = entryOrder,
                width = 1.4,
                hidden = hideEntry,
                get = function()
                    local sid = getExtra(idx)
                    return tostring(sid or "")
                end,
                set = function(_, val)
                    local n = tonumber(((val or ""):gsub("[^%d]", "")))
                    if not n or n <= 0 then return end
                    local _, e = getExtra(idx)
                    if not e or not e.config then return end
                    e.config[triggerKey] = e.config[triggerKey] or {}
                    local list = e.config[triggerKey].extraSpellIDs or {}
                    -- Idempotent dedupe — if this ID is already in the list,
                    -- don't add it again. Prevents the matcher from doing
                    -- redundant comparisons.
                    for i = 1, #list do
                        if list[i] == n then return end
                    end
                    -- For the "next" slot we APPEND; for an existing index
                    -- we OVERWRITE (the user is editing an existing entry).
                    if idx > #list then
                        table.insert(list, n)
                    else
                        list[idx] = n
                    end
                    e.config[triggerKey].extraSpellIDs = list
                    if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                        ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
                    end
                    NotifyRefresh()
                end,
            }

            args[string.format("editor_%s_extras_%d_remove", triggerKey, idx)] = {
                type = "execute",
                name = "|cffff4444Remove|r",
                desc = "Remove this extra spell ID from the list.",
                order = entryOrder + 0.005,
                width = 0.6,
                -- Remove button only shown for FILLED rows (idx <= #list).
                -- The trailing empty "next" slot has no remove button.
                hidden = function()
                    if hideCheckFn() then return true end
                    return idx > listLen()
                end,
                func = function()
                    local _, e = getExtra(idx)
                    if not e or not e.config or not e.config[triggerKey] then return end
                    local list = e.config[triggerKey].extraSpellIDs
                    if not list or idx > #list then return end
                    table.remove(list, idx)
                    if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                        ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
                    end
                    NotifyRefresh()
                end,
            }
        end
    end

    BuildExtraSpellIDList(
        "startTrigger",
        220.8,
        function() return EditorHidden() or collapsed.editStart end,
        "Extra Start Spell IDs")

    -- Helper to build a Start event checkbox. Reads/writes the events set
    -- inside config.startTrigger.
    local function startEventToggle(key, label, descText, order)
        return {
            type = "toggle",
            name = label,
            desc = descText,
            order = order,
            width = "full",
            hidden = function() return EditorHidden() or collapsed.editStart end,
            get = function()
                local e = GetSelectedTimer()
                return e and e.config and e.config.startTrigger
                   and e.config.startTrigger.events
                   and e.config.startTrigger.events[key] == true or false
            end,
            set = function(_, v)
                local e = GetSelectedTimer()
                if not e or not e.config then return end
                e.config.startTrigger = e.config.startTrigger or {}
                e.config.startTrigger.events = e.config.startTrigger.events or {}
                e.config.startTrigger.events[key] = v and true or nil
                if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                    ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
                end
                NotifyRefresh()
            end,
        }
    end
    args.editorStartCast = startEventToggle("cast",
        "Cast Success",
        "UNIT_SPELLCAST_SUCCEEDED — fires when you successfully cast this spell.",
        220.4)
    args.editorStartCooldown = startEventToggle("cooldown",
        "Cooldown Event",
        "SPELL_UPDATE_COOLDOWN — fires when the spell's cooldown state changes. "
        .. "Suppressed for 2 seconds after zone-in to absorb the load-burst. "
        .. "Useful for tracking passive ICDs that expose a cooldown.",
        220.5)
    args.editorStartProc = startEventToggle("proc",
        "Proc Glow Start",
        "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW — fires when the spell's action-bar "
        .. "proc glow turns on.",
        220.6)

    args.editorStartRestartOnRefire = {
        type = "toggle",
        name = "Restart if triggered again while active",
        desc = "If on, any Start event firing again while the timer is running "
            .. "restarts it from full duration. Off by default — re-fires are ignored "
            .. "until the current timer finishes.",
        order = 220.7,
        width = "full",
        hidden = function() return EditorHidden() or collapsed.editStart end,
        get = function()
            local e = GetSelectedTimer()
            return e and e.config and e.config.startTrigger
               and e.config.startTrigger.restartOnRefire == true or false
        end,
        set = function(_, v)
            local e = GetSelectedTimer()
            if not e or not e.config then return end
            e.config.startTrigger = e.config.startTrigger or {}
            e.config.startTrigger.restartOnRefire = v and true or false
            if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
            end
            NotifyRefresh()
        end,
    }
    -- ═══════════════════════════════════════════════════════════════════
    -- ── Stacks ──
    -- Own collapsible section between Start Trigger and End Trigger. The
    -- Track Stacks toggle gates the rest of the section's interactive
    -- controls; with tracking off the section still expands so the user
    -- can see what's available, but the mode dropdown is grayed out.
    -- ═══════════════════════════════════════════════════════════════════
    args.editorStacksSubhead = {
        type = "toggle",
        name = "|cff88ccffStacks|r  |cff888888(optional)|r",
        desc = "Click to expand/collapse — controls whether this timer counts how "
            .. "many times the Start Trigger fires and how those stacks expire.",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsed.editStacks end,
        set = function(_, v) collapsed.editStacks = not v end,
        order = 222,
        width = "full",
        hidden = EditorHidden,
    }
    args.editorTrackStacks = {
        type = "toggle",
        name = "Track stacks",
        desc = "If on, count how many times the Start Trigger fires while the "
            .. "timer is active and display it on the icon. The stack number uses "
            .. "the same styling as the charge text (color, size, position, etc.) "
            .. "configured under CDM Icons. Off by default.",
        order = 222.1,
        width = "full",
        hidden = function() return EditorHidden() or collapsed.editStacks end,
        get = function()
            local e = GetSelectedTimer()
            return e and e.config and e.config.startTrigger
               and e.config.startTrigger.trackStacks == true or false
        end,
        set = function(_, v)
            local e = GetSelectedTimer()
            if not e or not e.config then return end
            e.config.startTrigger = e.config.startTrigger or {}
            e.config.startTrigger.trackStacks = v and true or false
            if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
            end
            NotifyRefresh()
        end,
    }
    args.editorStackMode = {
        type = "select",
        name = "Stack Mode",
        desc = "How stack expiry works:\n\n"
            .. "|cff88ccffRefresh duration|r — all stacks expire together when the "
            .. "main timer ends. Simple counter. Matches most buff-stack behaviors.\n\n"
            .. "|cff88ccffIndependent durations|r — each stack has its own lifespan "
            .. "equal to the timer's duration. Stacks fall off one at a time as "
            .. "their individual timers expire, even if new procs keep coming. "
            .. "Matches overlap-style trinket effects (e.g. Gaze of the Alnseer).\n\n"
            .. "|cff88ccffConsume (Generator/Spender)|r — start with N stacks; gain "
            .. "stacks from generator events, lose stacks from spender events. "
            .. "Like a resource bar attached to an icon. Configure generators, "
            .. "spenders, max stacks, and on-empty action below.",
        order = 222.2,
        width = "full",
        hidden = function() return EditorHidden() or collapsed.editStacks end,
        disabled = function()
            -- Mode picker only meaningful when tracking is on. Gray out
            -- (rather than hide) so the user discovers the option exists.
            local e = GetSelectedTimer()
            return not (e and e.config and e.config.startTrigger
                        and e.config.startTrigger.trackStacks == true)
        end,
        values = {
            refresh     = "Refresh duration  (all stacks expire together)",
            independent = "Independent durations  (stacks fall off individually)",
            consume     = "Consume  (generator/spender economy)",
        },
        sorting = { "refresh", "independent", "consume" },
        get = function()
            local e = GetSelectedTimer()
            local mode = e and e.config and e.config.startTrigger
                         and e.config.startTrigger.stackMode
            if mode == "independent" then return "independent" end
            if mode == "consume" then return "consume" end
            return "refresh"
        end,
        set = function(_, v)
            if v ~= "refresh" and v ~= "independent" and v ~= "consume" then
                v = "refresh"
            end
            local e = GetSelectedTimer()
            if not e or not e.config then return end
            e.config.startTrigger = e.config.startTrigger or {}
            e.config.startTrigger.stackMode = v
            if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
            end
            NotifyRefresh()
        end,
    }

    -- ── Consume-mode fields: Max Stacks, Initial Stacks, On Empty action ──
    -- All hidden unless trackStacks=true AND stackMode="consume". Each one
    -- writes through UpdateTimerConfig so the engine re-normalizes and the
    -- next dispatcher pass reflects the change.
    local function ConsumeHidden()
        if EditorHidden() or collapsed.editStacks then return true end
        local e = GetSelectedTimer()
        if not (e and e.config and e.config.startTrigger
                and e.config.startTrigger.trackStacks == true) then return true end
        return e.config.startTrigger.stackMode ~= "consume"
    end

    args.editorMaxStacks = {
        type = "input",
        name = "Max Stacks",
        desc = "The cap. Generator events can never push the stack count above "
            .. "this number — extra gains are ignored. Default 5. Disabled when "
            .. "'No max' is on.",
        order = 222.3,
        width = 0.6,
        hidden = ConsumeHidden,
        disabled = function()
            if IsArcDisabled() then return true end
            local e = GetSelectedTimer()
            return e and e.config and e.config.startTrigger
                   and e.config.startTrigger.noMaxStacks == true or false
        end,
        get = function()
            local e = GetSelectedTimer()
            return tostring((e and e.config and e.config.startTrigger
                            and tonumber(e.config.startTrigger.maxStacks)) or 5)
        end,
        set = function(_, val)
            local n = tonumber(((val or ""):gsub("[^%d]", "")))
            if not n or n <= 0 then return end
            if n > 999 then n = 999 end
            local e = GetSelectedTimer()
            if not e or not e.config then return end
            e.config.startTrigger = e.config.startTrigger or {}
            e.config.startTrigger.maxStacks = n
            if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
            end
            NotifyRefresh()
        end,
    }
    args.editorNoMaxStacks = {
        type = "toggle",
        name = "No max (uncapped)",
        desc = "If on, ignore the Max Stacks cap and let generator events keep "
            .. "adding stacks indefinitely. Useful for resource-style counters "
            .. "where you want to track an open-ended pool that only spenders bring down.",
        order = 222.31,
        width = 0.8,
        hidden = ConsumeHidden,
        get = function()
            local e = GetSelectedTimer()
            return e and e.config and e.config.startTrigger
                   and e.config.startTrigger.noMaxStacks == true or false
        end,
        set = function(_, v)
            local e = GetSelectedTimer()
            if not e or not e.config then return end
            e.config.startTrigger = e.config.startTrigger or {}
            e.config.startTrigger.noMaxStacks = v and true or false
            if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
            end
            NotifyRefresh()
        end,
    }
    args.editorInitialStacks = {
        type = "input",
        name = "Initial Stacks",
        desc = "How many stacks the icon starts with when the Start Trigger fires. "
            .. "Set to 0 to start empty and rely entirely on generator events. "
            .. "Clamped to Max Stacks.",
        order = 222.4,
        width = 0.6,
        hidden = ConsumeHidden,
        get = function()
            local e = GetSelectedTimer()
            return tostring((e and e.config and e.config.startTrigger
                            and tonumber(e.config.startTrigger.initialStacks)) or 0)
        end,
        set = function(_, val)
            local n = tonumber(((val or ""):gsub("[^%d]", "")))
            if not n or n < 0 then return end
            local e = GetSelectedTimer()
            if not e or not e.config then return end
            e.config.startTrigger = e.config.startTrigger or {}
            e.config.startTrigger.initialStacks = n
            if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
            end
            NotifyRefresh()
        end,
    }
    args.editorOnEmpty = {
        type = "select",
        name = "On Empty",
        desc = "What happens when stacks are consumed down to 0:\n\n"
            .. "|cff88ccffKeep|r — timer keeps running until its duration expires.\n\n"
            .. "|cff88ccffStop|r — stop the timer immediately (clears the swipe and "
            .. "returns the icon to its ready state).\n\n"
            .. "|cff88ccffHide|r — hide the icon while empty; show again on the next "
            .. "generator gain or when the timer ends.",
        order = 222.5,
        width = 0.8,
        hidden = ConsumeHidden,
        values = {
            keep = "Keep timer running",
            stop = "Stop timer",
            hide = "Hide icon",
        },
        sorting = { "keep", "stop", "hide" },
        get = function()
            local e = GetSelectedTimer()
            local v = e and e.config and e.config.startTrigger
                      and e.config.startTrigger.onEmptyAction
            if v == "stop" or v == "hide" then return v end
            return "keep"
        end,
        set = function(_, v)
            if v ~= "keep" and v ~= "stop" and v ~= "hide" then v = "keep" end
            local e = GetSelectedTimer()
            if not e or not e.config then return end
            e.config.startTrigger = e.config.startTrigger or {}
            e.config.startTrigger.onEmptyAction = v
            if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
            end
            NotifyRefresh()
        end,
    }

    -- ── Generators / Spenders lists ──
    -- Each list is rendered as: header → per-entry block (3 event toggles +
    -- spellID input + amount input + remove button) → "+ Add" button.
    -- The list arrays live at config.startTrigger.generators / .spenders
    -- and each entry has shape { events={cast=true,...}, spellID=N, amount=N }.
    --
    -- We cap the displayed entries at MAX_LIST_ENTRIES because AceConfig
    -- needs a static set of arg keys; if the user has more than that we
    -- still store them (no data loss), they just don't render in the UI.
    local MAX_LIST_ENTRIES = 8

    -- Helper that builds a closure for getting/setting a field on entry[idx]
    -- of either generators or spenders. listKey is "generators" or "spenders".
    local function getEntry(listKey, idx)
        local e = GetSelectedTimer()
        if not e or not e.config or not e.config.startTrigger then return nil end
        local list = e.config.startTrigger[listKey]
        if not list or idx > #list then return nil end
        return list[idx], e
    end

    local function entryHidden(listKey, idx)
        return function()
            if ConsumeHidden() then return true end
            local entry = getEntry(listKey, idx)
            return entry == nil
        end
    end

    -- Build the args block for a single generator-or-spender list. Each
    -- entry takes ~6 widget rows; orders are spaced so generators occupy
    -- 223.x and spenders occupy 224.x.
    local function BuildEconomyList(listKey, baseOrder, headerLabel, headerDesc, addLabel)
        args["editor_" .. listKey .. "_header"] = {
            type = "description",
            name = "\n|cffffd700" .. headerLabel .. ":|r  |cff666666" .. headerDesc .. "|r",
            order = baseOrder,
            width = "full",
            fontSize = "medium",
            hidden = ConsumeHidden,
        }

        for idx = 1, MAX_LIST_ENTRIES do
            local entryOrder = baseOrder + (idx * 0.05)
            local hideEntry = entryHidden(listKey, idx)

            args[string.format("editor_%s_%d_head", listKey, idx)] = {
                type = "description",
                name = function()
                    local entry = getEntry(listKey, idx)
                    if not entry then return "" end
                    local sid = tonumber(entry.spellID) or 0
                    local name = "Spell " .. sid
                    if sid > 0 and C_Spell and C_Spell.GetSpellInfo then
                        local info = C_Spell.GetSpellInfo(sid)
                        if info and info.name then name = info.name end
                    end
                    local amt = entry.amount or 1
                    local sign = (listKey == "generators") and "+" or "-"
                    return string.format("\n|cff88ccff#%d|r  %s%d  %s",
                        idx, sign, amt, name)
                end,
                order = entryOrder + 0.001,
                width = "full",
                fontSize = "small",
                hidden = hideEntry,
            }

            -- Event checkboxes (cast / cooldown / proc) — only one at a time
            -- in practice but stored as a set for consistency with start/end
            -- trigger shape.
            local function eventToggle(eventKey, eventLabel, eventDesc, subOrder)
                args[string.format("editor_%s_%d_ev_%s", listKey, idx, eventKey)] = {
                    type = "toggle",
                    name = eventLabel,
                    desc = eventDesc,
                    order = entryOrder + subOrder,
                    width = 0.6,
                    hidden = hideEntry,
                    get = function()
                        local entry = getEntry(listKey, idx)
                        return entry and entry.events
                               and entry.events[eventKey] == true or false
                    end,
                    set = function(_, v)
                        local entry, e = getEntry(listKey, idx)
                        if not entry then return end
                        entry.events = entry.events or {}
                        entry.events[eventKey] = v and true or nil
                        if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                            ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
                        end
                        NotifyRefresh()
                    end,
                }
            end
            eventToggle("cast",     "Cast",     "Trigger on UNIT_SPELLCAST_SUCCEEDED for this spell.", 0.002)
            eventToggle("cooldown", "Cooldown", "Trigger on SPELL_UPDATE_COOLDOWN for this spell.",     0.003)
            eventToggle("proc",     "Proc",     "Trigger on SPELL_ACTIVATION_OVERLAY_GLOW_SHOW for this spell.", 0.004)

            -- SpellID input
            args[string.format("editor_%s_%d_spellID", listKey, idx)] = {
                type  = "input",
                name  = "Spell ID",
                desc  = "The spell whose event " .. (listKey == "generators" and "GAINS" or "CONSUMES")
                       .. " stacks.",
                order = entryOrder + 0.005,
                width = 0.6,
                hidden = hideEntry,
                get = function()
                    local entry = getEntry(listKey, idx)
                    return tostring((entry and tonumber(entry.spellID)) or "")
                end,
                set = function(_, val)
                    local n = tonumber(((val or ""):gsub("[^%d]", "")))
                    if not n or n <= 0 then return end
                    local entry, e = getEntry(listKey, idx)
                    if not entry then return end
                    entry.spellID = n
                    if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                        ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
                    end
                    NotifyRefresh()
                end,
            }

            -- Amount input
            args[string.format("editor_%s_%d_amount", listKey, idx)] = {
                type  = "input",
                name  = "Amount",
                desc  = "How many stacks each match " .. (listKey == "generators" and "adds" or "consumes") .. ". Default 1.",
                order = entryOrder + 0.006,
                width = 0.5,
                hidden = hideEntry,
                get = function()
                    local entry = getEntry(listKey, idx)
                    return tostring((entry and tonumber(entry.amount)) or 1)
                end,
                set = function(_, val)
                    local n = tonumber(((val or ""):gsub("[^%d]", "")))
                    if not n or n <= 0 then return end
                    local entry, e = getEntry(listKey, idx)
                    if not entry then return end
                    entry.amount = n
                    if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                        ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
                    end
                    NotifyRefresh()
                end,
            }

            -- Remove button
            args[string.format("editor_%s_%d_remove", listKey, idx)] = {
                type = "execute",
                name = "|cffff4444Remove|r",
                desc = "Remove this entry from the list.",
                order = entryOrder + 0.007,
                width = 0.5,
                hidden = hideEntry,
                func = function()
                    local entry, e = getEntry(listKey, idx)
                    if not entry then return end
                    table.remove(e.config.startTrigger[listKey], idx)
                    if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                        ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
                    end
                    NotifyRefresh()
                end,
            }
        end

        -- "+ Add" button
        args["editor_" .. listKey .. "_add"] = {
            type = "execute",
            name = addLabel,
            desc = "Append a new entry to the list. Edit its spell ID, event(s), and amount in the row that appears.",
            order = baseOrder + (MAX_LIST_ENTRIES * 0.05) + 0.05,
            width = 0.9,
            hidden = ConsumeHidden,
            disabled = function()
                local e = GetSelectedTimer()
                if not e or not e.config or not e.config.startTrigger then return true end
                local list = e.config.startTrigger[listKey] or {}
                return #list >= MAX_LIST_ENTRIES
            end,
            func = function()
                local e = GetSelectedTimer()
                if not e or not e.config then return end
                e.config.startTrigger = e.config.startTrigger or {}
                e.config.startTrigger[listKey] = e.config.startTrigger[listKey] or {}
                table.insert(e.config.startTrigger[listKey], {
                    events  = { cast = true },
                    spellID = nil,
                    amount  = 1,
                })
                if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                    ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
                end
                NotifyRefresh()
            end,
        }
    end

    BuildEconomyList("generators", 223,
        "Generators",
        "events that ADD stacks while the timer is active",
        "+ Add Generator")
    BuildEconomyList("spenders", 224,
        "Spenders",
        "events that REMOVE stacks while the timer is active",
        "+ Add Spender")

    -- ═══════════════════════════════════════════════════════════════════
    -- ── End Trigger ──
    -- Each checked event independently stops the timer when it fires.
    -- No checkboxes = timer runs to natural expiration.
    -- ═══════════════════════════════════════════════════════════════════
    args.editorEndSubhead = {
        type = "toggle",
        name = "|cff88ccffEnd Trigger|r  |cff888888(optional — stops timer early)|r",
        desc = "Click to expand/collapse — controls what event(s) stop this timer before its duration expires.",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsed.editEnd end,
        set = function(_, v) collapsed.editEnd = not v end,
        order = 225,
        width = "full",
        hidden = EditorHidden,
    }
    args.editorEndEventsLabel = {
        type = "description",
        name = "\n|cffaaaaaaEnd Events|r  |cff666666(any checked event stops the timer)|r",
        order = 225.1,
        width = "full",
        fontSize = "small",
        hidden = function() return EditorHidden() or collapsed.editEnd end,
    }

    local function endEventToggle(key, label, descText, order)
        return {
            type = "toggle",
            name = label,
            desc = descText,
            order = order,
            width = "full",
            hidden = function() return EditorHidden() or collapsed.editEnd end,
            get = function()
                local e = GetSelectedTimer()
                return e and e.config and e.config.endTrigger
                   and e.config.endTrigger.events
                   and e.config.endTrigger.events[key] == true or false
            end,
            set = function(_, v)
                local e = GetSelectedTimer()
                if not e or not e.config then return end
                e.config.endTrigger = e.config.endTrigger or {}
                e.config.endTrigger.events = e.config.endTrigger.events or {}
                e.config.endTrigger.events[key] = v and true or nil
                if ns.ArcAurasTimer and ns.ArcAurasTimer.UpdateTimerConfig then
                    ns.ArcAurasTimer.UpdateTimerConfig(e.arcID)
                end
                NotifyRefresh()
            end,
        }
    end
    args.editorEndCast = endEventToggle("cast",
        "Cast Success",
        "UNIT_SPELLCAST_SUCCEEDED — stop the timer when this spell is cast again.",
        225.2)
    args.editorEndProc = endEventToggle("proc",
        "Proc Glow Start",
        "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW — stop when the spell's proc glow turns on.",
        225.3)
    args.editorEndProcEnd = endEventToggle("procEnd",
        "Proc Glow End",
        "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE — stop when the proc glow turns off. "
        .. "Pairs well with a Proc Glow Start trigger for 'icon visible while proc is active'.",
        225.4)
    args.editorEndDeath = endEventToggle("death",
        "On Death",
        "PLAYER_DEAD — stop the timer if the player dies, so it doesn't keep running across resurrection.",
        225.5)

    BuildExtraSpellIDList(
        "endTrigger",
        225.8,
        function() return EditorHidden() or collapsed.editEnd end,
        "Extra End Spell IDs")

    -- ── Actions ──
    args.editorActionsSubhead = {
        type = "toggle",
        name = "|cff88ccffActions|r",
        desc = "Click to expand/collapse",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsed.editActions end,
        set = function(_, v) collapsed.editActions = not v end,
        order = 240,
        width = "full",
        hidden = EditorHidden,
    }
    args.editorTestBtn = {
        type = "execute",
        name = "Test Timer",
        desc = "Start the timer now (for testing visuals) without needing to trigger the spell.",
        order = 241,
        width = 0.8,
        hidden = function() return EditorHidden() or collapsed.editActions end,
        func = function()
            local e = GetSelectedTimer()
            if e and ns.ArcAurasTimer and ns.ArcAurasTimer.StartTimer then
                ns.ArcAurasTimer.StartTimer(e.arcID)
            end
        end,
    }
    args.editorStopBtn = {
        type = "execute",
        name = "Stop Timer",
        desc = "Stop the running timer now (resets the icon to ready state).",
        order = 242,
        width = 0.8,
        hidden = function() return EditorHidden() or collapsed.editActions end,
        func = function()
            local e = GetSelectedTimer()
            if e and ns.ArcAurasTimer and ns.ArcAurasTimer.StopTimer then
                ns.ArcAurasTimer.StopTimer(e.arcID)
            end
        end,
    }
    args.editorRemoveBtn = {
        type = "execute",
        name = "|cffff4444Remove Timer|r",
        desc = "|cffff4444Destroy this timer and delete its saved configuration. This cannot be undone.|r",
        order = 243,
        width = 0.8,
        hidden = function() return EditorHidden() or collapsed.editActions end,
        confirm = function()
            local e = GetSelectedTimer()
            return string.format("Remove timer '%s'?", (e and e.name) or "?")
        end,
        func = function()
            local e = GetSelectedTimer()
            if not e then return end
            if ns.ArcAurasTimer and ns.ArcAurasTimer.RemoveTimer then
                ns.ArcAurasTimer.RemoveTimer(e.arcID)
            end
            if ns.ArcAurasOptions and ns.ArcAurasOptions.SetSelected then
                ns.ArcAurasOptions.SetSelected(nil)
            end
            NotifyRefresh()
        end,
    }

    -- Apply the disable gate (gray out interactive widgets when Arc Auras
    -- is off). Mirrors the main Options file's pattern.
    local skipKeys = { introDesc = true }
    for key, entry in pairs(args) do
        if not skipKeys[key]
           and entry.type ~= "description"
           and entry.type ~= "header" then
            if entry.disabled == nil then
                entry.disabled = IsArcDisabled
            end
        end
    end

    return {
        type = "group",
        name = "Custom Icons",
        order = 2,
        args = args,
    }
end