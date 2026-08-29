-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_ArcAurasAuraSounds.lua
-- ALERT SOUNDS for 12.1 aura icons — engine-native, secrecy-immune.
--
-- C_UnitAuras.AddAuraSound(trigger, info) -> auraSoundID   (TWO positional
-- args; the trigger is NOT a field of info). info = { unitToken, spellID,
-- soundFileName | soundFileID, outputChannel }. One registration per
-- (unitToken, spellID, trigger) — no wildcards. RemoveAuraSound(id) unregisters.
--
-- WHY THIS IS THE RIGHT PATH: the doc entry carries NONE of the aura-secrecy
-- predicates (no RequiresUnitAuraAccess, no RequiresNonSecretAura), so the
-- ENGINE plays these in raids/M+/combat where every addon-side aura signal is
-- dead. Registration is container-independent: no relationship to our slots.
--
-- WHAT IS GATED: only CHANGING registrations. AddAuraSound is HasRestrictions
-- (FailureMode ReturnNothing -> nil, no error). Registration edits are done
-- out of combat with auras non-secret and retried at the next safe edge
-- (same rule EnhanceQoL ships). Already-registered sounds keep playing while
-- we wait, so combat behaviour is never degraded.
--
-- TTS: impossible from this API — playback never re-enters Lua (no event, no
-- callback, no sound handle; verified against the full C_UnitAuras event
-- list). The ONLY non-secret in-combat aura-application signal an addon can
-- see is UNIT_SPELLCAST_SUCCEEDED for the player's OWN casts
-- (SecretWhenUnitSpellCastRestricted = secret only for non-player units), so
-- TTS here fires for auras YOU cast. The options panel only offers TTS on
-- icons whose spell the player can actually cast, so it is never a dead
-- toggle. Everything else (procs, buffs cast on you by others) has no signal.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...
ns.AuraIconSounds = ns.AuraIconSounds or {}
local AIS = ns.AuraIconSounds

local IS_121 = (select(4, GetBuildInfo()) or 0) >= 120100

local registrationIDs = {}   -- auraSoundIDs we own
local currentSig = nil
local pendingSync = false
local ttsBySpell = {}        -- spellID -> { {text=, arcID=}, ... }

local function TrigEnum()
    return Enum and Enum.UnitAuraSoundTrigger
end

-- key in settings.auraAlerts  ->  engine trigger
local SOUND_KEYS = {
    { key = "gainedSound", trig = "Added" },
    { key = "stacksSound",  trig = "ApplicationsIncreased" },
    { key = "removedSound", trig = "Removed" },
}
AIS.SOUND_KEYS = SOUND_KEYS

-- Registration EDITS need a quiet moment; playback does not.
local function CanChangeRegistrations()
    if InCombatLockdown and InCombatLockdown() then return false end
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
        return false
    end
    return true
end

-- the dropdown stores EITHER this sentinel (speak the paired line, handled by
-- the cast watcher below) or an LSM sound name — one action per edge
local ALERT_TTS = "__tts__"
AIS.ALERT_TTS = ALERT_TTS

-- LSM sounds resolve to EITHER a file path (string) or a fileID (number) —
-- the API takes them in different fields.
local function ResolveSound(name)
    if type(name) ~= "string" or name == "" or name == "None" then return nil, nil end
    if name == ALERT_TTS then return nil, nil end   -- speech, not an engine sound
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    local value = LSM and LSM.Fetch and LSM:Fetch("sound", name, true) or nil
    if type(value) == "number" and value > 0 then return nil, value end
    if type(value) == "string" and value ~= "" then return value, nil end
    return nil, nil
end

local function UnitsFor(def)
    local mode = def and def.unitMode or "buff"
    if mode == "debuff" then return { "target" } end
    if mode == "both" then return { "player", "target" } end
    return { "player" }
end

local function SpellIDsOf(def)
    local ids = {}
    if def.spellIDs and next(def.spellIDs) then
        for id in pairs(def.spellIDs) do ids[#ids + 1] = id end
    elseif def.spellID then
        ids[1] = def.spellID
    end
    table.sort(ids)   -- stable signature
    return ids
end

-- Build the full desired registration list + the TTS lookup, and a signature
-- that changes only when something real changed.
local function BuildDesired()
    local list, sigParts, tts = {}, {}, {}
    local defs = ns.AuraIcons and ns.AuraIcons.All and ns.AuraIcons.All() or {}
    local arcIDs = {}
    for arcID in pairs(defs) do arcIDs[#arcIDs + 1] = arcID end
    table.sort(arcIDs)

    for _, arcID in ipairs(arcIDs) do
        local def = defs[arcID]
        local settings = ns.ArcAuras and ns.ArcAuras.GetCachedSettings
            and ns.ArcAuras.GetCachedSettings(arcID)
        local alerts = settings and settings.auraAlerts
        if def and alerts then
            local ids = SpellIDsOf(def)
            local units = UnitsFor(def)
            for _, entry in ipairs(SOUND_KEYS) do
                local fileName, fileID = ResolveSound(alerts[entry.key])
                if fileName or fileID then
                    for _, unit in ipairs(units) do
                        for _, spellID in ipairs(ids) do
                            list[#list + 1] = {
                                trig = entry.trig, unit = unit, spellID = spellID,
                                fileName = fileName, fileID = fileID,
                                channel = alerts.channel,
                            }
                        end
                    end
                    -- the channel is part of the signature: changing it has to
                    -- re-register, or the engine keeps playing on the old one
                    sigParts[#sigParts + 1] = arcID .. ":" .. entry.key .. ":"
                        .. tostring(fileName or fileID) .. ":" .. #ids
                        .. ":" .. tostring(alerts.channel or "Master")
                end
            end
            -- TTS lookup: keyed by the spell IDs, matched against the
            -- player's own cast events. Speech is its own field now (sound and
            -- speech are independent), so the line being filled in IS the
            -- switch -- it no longer waits for the sound slot to hold the old
            -- "__tts__" sentinel.
            local text = alerts.gainedTTS
            if type(text) == "string" and text ~= "" then
                for _, spellID in ipairs(ids) do
                    tts[spellID] = tts[spellID] or {}
                    table.insert(tts[spellID], { text = text, arcID = arcID })
                end
                sigParts[#sigParts + 1] = arcID .. ":tts"
            end
        end
    end
    return list, table.concat(sigParts, "|"), tts
end

local retryFrame

local function ClearRegistrations()
    if C_UnitAuras and C_UnitAuras.RemoveAuraSound then
        for i = 1, #registrationIDs do
            C_UnitAuras.RemoveAuraSound(registrationIDs[i])
        end
    end
    wipe(registrationIDs)
end

function AIS.Sync()
    if not IS_121 then return end
    if not (C_UnitAuras and C_UnitAuras.AddAuraSound) then return end
    local TRIG = TrigEnum()
    if not TRIG then return end

    local desired, sig, tts = BuildDesired()
    ttsBySpell = tts    -- TTS needs no registration; update it immediately

    if sig == currentSig then
        pendingSync = false
        return
    end
    if not CanChangeRegistrations() then
        pendingSync = true
        if retryFrame then
            retryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
            retryFrame:RegisterEvent("ENCOUNTER_END")
            retryFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        end
        return
    end

    pendingSync = false
    ClearRegistrations()
    currentSig = sig
    for _, r in ipairs(desired) do
        local trigger = TRIG[r.trig]
        if trigger ~= nil then
            local info = {
                unitToken = r.unit,
                spellID = r.spellID,
                outputChannel = r.channel or "Master",
            }
            if r.fileName then info.soundFileName = r.fileName
            else info.soundFileID = r.fileID end
            -- HasRestrictions: nil return = refused, nothing to clean up
            local id = C_UnitAuras.AddAuraSound(trigger, info)
            if id then registrationIDs[#registrationIDs + 1] = id end
        end
    end
end

local syncQueued = false
function AIS.QueueSync()
    if syncQueued then return end
    syncQueued = true
    C_Timer.After(0.2, function()
        syncQueued = false
        AIS.Sync()
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TTS: the player's OWN casts (non-secret for player/pet even in instances)
-- ═══════════════════════════════════════════════════════════════════════════

-- Can the player actually cast this spell? Drives whether the panel offers
-- TTS at all — an aura you never cast has no signal to speak on.
function AIS.CanSelfTrigger(spellID)
    if not spellID then return false end
    if C_SpellBook and C_SpellBook.IsSpellKnownOrOverridesKnown
       and C_SpellBook.IsSpellKnownOrOverridesKnown(spellID) then
        return true
    end
    if IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(spellID) then
        return true
    end
    if IsSpellKnown and IsSpellKnown(spellID) then return true end
    return false
end

function AIS.CanSelfTriggerDef(def)
    if not def then return false end
    if def.spellIDs and next(def.spellIDs) then
        for id in pairs(def.spellIDs) do
            if AIS.CanSelfTrigger(id) then return true end
        end
        return false
    end
    return AIS.CanSelfTrigger(def.spellID)
end

if IS_121 then
    retryFrame = CreateFrame("Frame")
    retryFrame:RegisterEvent("PLAYER_LOGIN")
    retryFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    retryFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    retryFrame:SetScript("OnEvent", function(_, event, arg1, _, arg3)
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            local spellID = arg3
            -- non-secret for player casts, but guard anyway (restricted
            -- contexts are the one thing that could change that)
            if issecretvalue and issecretvalue(spellID) then return end
            local hits = spellID and ttsBySpell[spellID]
            if hits and ns.Sounds and ns.Sounds.SpeakText then
                for _, h in ipairs(hits) do
                    ns.Sounds.SpeakText(h.text)
                end
            end
            return
        end
        -- login / zone / regen / encounter edges: (re)apply anything deferred
        if event == "PLAYER_LOGIN" then
            C_Timer.After(2, AIS.Sync)
            return
        end
        if pendingSync or event == "PLAYER_ENTERING_WORLD" then
            AIS.Sync()
        end
    end)

    -- settings edits land on panel close
    if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
        ns.CDMShared.RegisterPanelCallback("ArcAuraIconSounds", {
            onClose = function() AIS.QueueSync() end,
        })
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF ArcUI_ArcAurasAuraSounds.lua
-- ═══════════════════════════════════════════════════════════════════════════
