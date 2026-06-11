# ArcUI — Claude Code Instructions

ArcUI is a comprehensive World of Warcraft addon suite for WoW 12.0 (Midnight), currently v3.7.x.
It covers cooldown management, buff/debuff tracking bars, resource bars, CDM (CooldownViewer)
integration, custom icons/timers, and proc tracking. Related addon: ArcUI_ProcTracker (v1.0.5+).

Target client: WoW 12.0 Midnight Beta — Interface 120001.

---

## ABSOLUTE RULES — never violate these

- **NEVER use pcall anywhere in ArcUI.** No exceptions. It has all been removed; do not reintroduce it.
- **ALL new features and options MUST default to false/disabled.** Users opt-in, never opt-out.
- **Surgical fixes only.** Fix exactly what was asked. No "while I'm here" restructuring, no broad
  migrations, no refactors without explicit approval.
- **Run `luac -p` on every modified Lua file before declaring a task done.** Run it yourself; do not
  ask the user to.
- **Zero-idle-CPU philosophy:** event-driven > polling, throttled > per-frame, single watcher >
  per-icon hooks. Avoid OnUpdate when events exist. ALWAYS ask before adding any constant polling.
- **Never re-copy files from old uploads or backups over the working tree** unless explicitly told
  "use these new files." Always work from the live project files.

---

## WoW 12.0 SECRET VALUES (critical — most bugs trace back to violating these)

Secret values are tainted runtime values addons cannot inspect.

**Cannot do with secrets:**
- Compare them (`<`, `>`, `==` against numbers), do arithmetic, `tonumber()`, or store in
  SavedVariables (they get replaced with nil on save).
- Passing a secret into an API call marks the receiving object secret.

**Can do:**
- `if x then` works as a nil check on secrets.
- `issecretvalue(x)` to test. `HasSecretAspect()` on objects; `SetToDefaults()` clears all secret
  state on a frame. `IsAnchoringSecret()` to test anchor taint (secret anchors propagate DOWN the
  anchor chain, not up).
- Comparing different types yields non-secret false; comparing nil secrets yields non-secret true.
- `/dump` prints secret contents (debugging only).

**Duration objects ARE secret:**
- `IsZero()`, `GetSpan()`, `GetCooldownDuration()` ALL return secrets. Never extract numbers.
- Pass the durObj directly to `Cooldown:SetCooldownFromDurationObject(durObj)`.
- APIs always return a durObj (zero-span when inactive), never nil.
- Use `C_UnitAuras.GetAuraDurationRemaining(unit, auraInstanceID)` and `SetTimerDuration`.

**BANNED with secrets (12.0.1):** `SetCooldown`, `SetCooldownFromExpirationTime`,
`SetCooldownDuration`, `SetCooldownUNIX`, `ActionButton_ApplyCooldown`.

**Secret-accepting APIs (safe sinks):** `SetText`, `SetValue`, `SetAlpha`, `SetVertexColor`,
`SetTexture` (secret numbers only, not strings), `C_StringUtil.*`, `AbbreviateNumbers`,
`Cooldown:SetCooldownFromDurationObject`.

**Known NON-secret values:**
- `GetUnitAuras`/`UNIT_AURA` vectors themselves (contents are secret); `auraInstanceID` is non-secret.
- Player spellcasts (including pets), even in combat — `UNIT_SPELLCAST_SUCCEEDED` on "player" is safe.
- `UnitHealthMax`/`UnitPowerMax` for player units; `UnitStagger` for player. `UnitPowerMax` returns
  non-secret 0 if the unit doesn't use that power type.
- `UnitIsUnit` for target/focus/mouseover/softenemy/softinteract/softfriend tokens (compound tokens
  like boss1target remain secret).
- `maxCharges` (non-secret as of 12.0.1); `isEnabled` and `isActive` from spell/action cooldown APIs.
- `isOnGCD` (true/false/nil) from `GetSpellState()` is NON-secret. NEVER compare
  `GetSpellCooldown.duration` — it is SECRET.
- NEVER compare `currentCharges` — SECRET.
- Unit names/GUIDs/IDs are secret in instances (instance-based, not combat-based).

**Display helpers:** Curve objects for secret-compatible color transitions;
`C_StringUtil.TruncateWhenZero` suppresses secret zeros in display text.

**Charge bars:** hook `SetCachedChargeValues(count, shown)` on `CooldownViewerCooldownItemMixin` —
count is non-secret for CDM spells. `SPELL_UPDATE_COOLDOWN` + `isOnGCD` misses casts within the
charge GCD; catch final-charge spends with `UNIT_SPELLCAST_SUCCEEDED` on "player".

**Scheduling that needs real numbers:** only use NON-secret sources — `GetTime()` plus
locally-tracked cast times, isActive/isEnabled flags.

---

## Architecture

- **Namespace:** `local ADDON, ns = ...`. `ns.API` (Core.lua), `ns.Display` / `ns.Resources` /
  `ns.Catalog` / `ns.CDMEnhance` (modules), `ns.db` (AceDB).
- **CDM scanning:** `ScanAllCDMIcons()` scans the 4 viewers → `cdmIconCache` →
  `OnCDMScanComplete()`.
- **Settings flow:** DEFAULT → global → perIcon. `GetIconSettings()` returns the merged result;
  `GetOrCreateIconSettings()` returns the sparse entry. `InvalidateCache()` is REQUIRED after
  changes.
- **CooldownState module is ONLY for cooldowns.** Auras are handled by
  `OptimizedApplyIconVisuals` (event-driven). `ApplyCooldownStateVisuals` skips auras.
- **Event-driven hooks** (SetIsActive, aura gained/lost): frame state is already correct at hook
  time — check frame properties directly, no redundant API queries.
- **Mouse/tooltips:** `SetScript("OnEnter", fn)` and `RegisterForDrag("LeftButton")` re-enable the
  mouse; set tooltips BEFORE click-through; force tooltips off when click-through is on.
- **Libraries:** AceDB, AceConfig, AceConfigDialog, LibSharedMedia, LibCustomGlow (Arc's fork:
  ArcGlow-1.0), LibDeflate, AceSerializer. CDM = Blizzard's native CooldownViewer; read CDM source
  in docs/ directly when diagnosing CDM interactions.

---

## Bug analysis methodology (mandatory)

- ALWAYS read every relevant file line by line, from line 1 to the end, before touching code —
  regardless of file length. Bugs hide in unrelated-seeming lines.
- Grep-only diagnosis consistently misses root causes. Grep may supplement full reads, never
  replace them.
- When a fix is proposed, trace its interaction with every code path that touches the same frames,
  settings keys, or events before shipping.
- When a regression is reported, diff against the last known-good git commit first.

---

## Changelogs & output conventions

- **Changelog format (CurseForge):** `## Section` header, then `- **Title** — Description` all on
  one line. NO blank lines between entries within a section; contiguous bullets under the header.
  No newline between the bold title and the description. Matches the 3.6.4 format exactly.
- **Changelog content:** plain English, user-facing only. No technical jargon, no implementation
  details.
- **Changelog files:** named `CHANGELOG_vX_X_X_V1.md`; increment the `_VN` suffix on every update
  within the same version.
- **Deliverables:** only Lua/TOC code changes plus a brief summary. No extra documentation files,
  no change-summary documents, unless explicitly requested.

---

## Workflow

- One bug or feature per session. Commit after each fix is confirmed working in-game.
- Before any risky change, ensure the current state is committed so it can be rolled back.
- After edits: `luac -p` every touched file, then summarize briefly what changed and why.
- Communication style: be direct and concise. No lengthy preambles or restated requirements.

---

## Architecture / File Map

Load order is defined by `ArcUI.toc` (libs → core → options → CDM module → Arc Auras → CDM
options). Everything shares one private namespace: `local ADDON, ns = ...`.

### How the modules connect (big picture)

- **Bars side (root folder):** `ArcUI_DB` defines schema/defaults and config accessors on
  `ns.API`. `ArcUI_Options` creates the AceDB (`ns.db`), registers the master options tree, and
  calls each module's `Init()` at PLAYER_LOGIN. `ArcUI_Core` hooks CDM frames for aura events and
  drives bar updates through `ns.Display` (aura/stack bars), `ns.Resources` (resource bars), and
  `ns.CooldownBars` (cooldown/charge/timer bars + the player spell catalog). `ns.CustomTracking`
  is the deterministic cast-event tracking engine feeding the same bars. `ns.Catalog` discovers
  CDM auras and creates/removes bars. `ns.BarGroupAlign` (BGA) does pixel-snap math for bars
  anchored to CDM group containers.
- **CDM side (CDM_Module):** `ns.CDMShared` is the hub (constants, DB helpers, throttles, panel
  callbacks). `ns.CDMGroups` owns groups/free icons/per-spec profiles; `ns.FrameController` is the
  single authority for frame lifecycle/assignment, using `ns.FrameRegistry` for lookup and
  `ns.FrameActive` for active-state detection. `ns.CDMEnhance` styles every CDM icon and exposes
  the merged-settings flow (`GetIconSettings`/`InvalidateCache`); feature files (CooldownState,
  AuraFrames, Glows, Keybinds, CustomLabel, SpellUsability, TextColor, Masque, ACH, BPH) all hang
  off it. `ns.ArcAuras` (+Cooldown/+Timer) are custom item/spell/timer icons that register into
  CDMGroups via `ns.CDMGroups.Integration`.
- **Visuals dispatch split (critical):** `ns.CooldownState` owns COOLDOWN visuals via hidden
  shadow Cooldown frames (single-pass `Apply()` merges alpha/swipe/glow/text color);
  `ns.AuraFrames.UpdateAuraFrame` (a.k.a. `OptimizedApplyIconVisuals`) owns AURA visuals,
  event-driven off `ns.FrameActive`. All actual glow rendering goes through `ns.Glows`.
- **Positioning:** `ns.CDMGroupsAnchors` (group↔group/external-frame anchoring),
  `ns.CDMContainerSync` (ArcUI containers ↔ Blizzard CDM viewers / Edit Mode),
  `ns.EditModeContainers` (LibEQOL drag wrappers).
- **Import/export:** `ns.UnifiedIE` auto-detects string type and dispatches to
  `ns.BarsImportExport` / `ns.CDMImportExport` / `ns.CDMMasterExport` / `ns.CRImportExport`.
  `ns.CDMSharedProfiles` syncs CDM profiles across same-class characters by reference.

### Root — core (load order)

- **ArcUI_DB.lua** — DB schema (`ns.DB_DEFAULTS`), threshold presets, and `ns.API` config
  accessors: `GetBarConfig/GetResourceBarConfig/GetCooldownBarConfig`, `GetActive*Bars` (cached;
  `InvalidateActiveBarCache`), `InitializeNew*Bar`.
- **ArcUI_BarGroupAlign.lua** — `ns.BarGroupAlign` pixel-snap/measure utilities
  (`GetMatchedDimension`, `GetIconInset*`, `ApplySizeAndAnchor`) for bars anchored to
  `ns.CDMGroups.groups[*].container`. Used by Display/Resources/CooldownBars.
- **ArcUI_Core.lua** — event-driven aura engine: hooks CDM frame methods
  (`OnAuraInstanceInfoSet/Cleared`, `OnUnitAuraUpdatedEvent`, `RefreshData`, totems) to drive bar
  updates; owns `ScanAllCDMIcons()`/`GetAllCDMIcons()` (`ns.API`), alternate-cooldown-ID mapping,
  hide-CDM-icon-when-tracked-by-bar logic, and `ns.Sounds` LSM registration.
- **ArcUI_Display.lua** — `ns.Display`: renders all buff/debuff/stack/duration bars (textures,
  text, ticks, curves, animations). Key: `UpdateBar`, `UpdateDurationBar`, `ApplyAppearance`,
  `ApplyAllBars`, `RefreshAllBars`, `HideBar`, preview mode. Hooks
  `ns.CDMGroups.UpdateGroupVisibility` for visibility sync.
- **ArcUI_Resources.lua** — `ns.Resources`: primary/secondary resource bars (thresholds,
  smoothing, segmented/fragmented modes, spell-cost forecasting, per-spec auto-power profiles).
  Heavy event surface (UNIT_POWER_FREQUENT, RUNE_POWER_UPDATE, shapeshift, etc.). Key:
  `UpdateBar`, `ApplyAppearance`, `UpdateAllBars`, `RefreshVisibility`, `PowerTypes`/
  `SecondaryTypes` metadata.
- **ArcUI_Catalog.lua** — `ns.Catalog`: discovers CDM auras (frame scan + DataProvider out of
  combat), bar create/remove from catalog entries (`CreateArcUIDisplay`/`RemoveArcUIDisplay`),
  reload-required tracking. Rescans on spec/talent change.
- **ArcUI_Minimap.lua** — LibDBIcon minimap button; opens options via `ns.API.OpenOptions()`.
- **ArcUI_CooldownBars.lua** — `ns.CooldownBars`: player spellbook catalog (`ScanPlayerSpells`,
  `spellCatalog` — also consumed by Cooldown Reminder and options panels) plus CRUD/runtime for
  cooldown, charge, resource and timer bars. Slash: `/cdbar`, `/stackbar`.
- **ArcUI_CustomTracking.lua** — `ns.CustomTracking`: deterministic custom aura/cooldown engine
  driven by `UNIT_SPELLCAST_SUCCEEDED` (stacks, decay, modifiers, talent/spec conditions);
  definitions edited via ArcUI_CustomOptions.
- **ArcUI_TalentPicker.lua** — `ns.TalentPicker`: talent-tree picker UI and runtime
  `CheckTalentConditions()` used by bars, resources, Arc Auras, and options for conditional
  visibility.
- **ArcUI_DataRepair.lua** — `ns.DataRepair`: SavedVariables compaction (strip defaults on
  logout, restore on login), ghost-bar/corruption cleanup, character purge. Slash: `/arcrepair`.

### Root — options & presets

- **ArcUI_Options.lua** — creates the AceDB, registers the top-level AceConfig tree ("ArcUI"),
  aggregates every panel's `GetOptionsTable()`, calls module `Init()`s at login, fires panel
  open/close callbacks into CDM modules. Exports `ns.API.OpenOptions`. Slash: `/arcui`,
  `/arcbars`, `/ab`, `/aui`.
- **ArcUI_TrackingOptions.lua** — `ns.TrackingOptions`: Aura Bars setup tab
  (`GetBuffDebuffSetupTable`) and Resources setup tab (`GetResourceSetupTable`);
  `AreTalentConditionsMet()`.
- **ArcUI_Presets.lua** — `ns.Presets`: appearance skin/profile system (snapshot/apply/copy/
  paste/save/load, category filtering, bar-type compatibility); library in
  `ns.db.global.skinLibrary`.
- **ArcUI_AppearanceOptions.lua** — `ns.AppearanceOptions`: unified appearance panel for all bar
  types (color/fill/size/text/border/ticks); integrates `ns.Presets`; applies via
  `ns.Display.ApplyAppearance` / `ns.Resources.ApplyAppearance`.
- **ArcUI_CooldownBarOptions.lua** — `ns.CooldownBarOptions`: options tab for cooldown/charge
  bars (reads `ns.CooldownBars` state and presets).
- **ArcUI_TimerBarOptions.lua** — `ns.TimerBarOptions`: "Custom Bars" tab for timer bars
  (triggers, generators/spenders, duration) — backed by `ns.CooldownBars.activeTimers`.
- **ArcUI_CustomOptions.lua** — `ns.CustomOptions`: UI for `ns.CustomTracking` custom aura/
  cooldown definitions.

### Root — Cooldown Reminder

- **ArcUI_CooldownReminder.lua** — `ns.CooldownReminder` + `.Engine`: shadow-Cooldown-widget
  detection of spell/item cooldown-ready transitions; queued/stacked pulse animations, sounds,
  TTS, per-trigger glows. Slash: `/arcuicr`.
- **ArcUI_CooldownReminder_Options.lua** — `ns.GetCooldownReminderOptionsTable()`: catalog
  browser, per-spell trigger editor (type/sound/TTS/animation/glow/priority).
- **ArcUI_CR_ImportExport.lua** — `ns.CRImportExport`: ARCUI_CR string export/import for CR
  settings + whitelist; also bundled into ARCMASTER exports.

### Root — import/export

- **ArcUI_Bars_ImportExport.lua** — `ns.BarsImportExport`: export/import of all bar configs
  (aura/cooldown/resource/timer) with add/replace modes.
- **ArcUI_UnifiedImportExport.lua** — `ns.UnifiedIE`: single import window; auto-detects string
  type (bars/CDM/Master/CR) and routes to the right importer; character-migration tools.

### CDM_Module — shared infrastructure

- **ArcUI_CDM_Shared.lua** — `ns.CDMShared` hub: viewer/category constants, DB helpers
  (`GetCDMGroupsDB`, `GetSpecIconSettings`, profile access), styling master toggle, event
  throttling, options-panel open/close callback registry.
- **ArcUI_FrameActive.lua** — `ns.FrameActive`: O(1) active-state tracking for CDM icon frames
  (shown/bound/aura-owned) with `OnChanged`/`OnAuraInstanceChanged` callbacks; adaptive
  UNIT_AURA registration. Standalone (no module deps).
- **ArcUI_CDMSetup.lua** — `ns.CDMSetup`: requirements checker/alerts (WoW version, CDM enabled,
  viewer settings, Edit Mode layout type, ElvUI/MasqueBlizzBars conflicts) + one-click fixes.
- **ArcUI_CDMContainerSync.lua** — `ns.CDMContainerSync`: bidirectional position/size sync
  between ArcUI group containers and Blizzard CDM viewers (push via SetPoint hooks, pull from
  Edit Mode), persisted via LibEditModeOverride.
- **ArcUI_EditModeContainers.lua** — `ns.EditModeContainers`: LibEQOL drag-overlay wrappers for
  all groups; "Drag Groups" toggle; Edit Mode integration.
- **ArcUI_CDM_ImportExport.lua** — `ns.CDMImportExport`: per-spec CDM export/import (group
  layouts, icon positions, iconSettings, global defaults, layout profiles, Arc Auras).
- **ArcUI_CDM_MasterExport.lua** — `ns.CDMMasterExport`: ARCMASTER global export/import across
  all characters/specs (scans raw `ArcUIDB.char`); pending-import queue for alts; cherry-pick
  selector used by UnifiedIE.
- **ArcUI_CDM_SharedProfiles.lua** — `ns.CDMSharedProfiles`: same-class profile sync via
  lightweight references into source characters' SavedVariables (Push/Pull/CheckAndSync,
  detach/purge).

### CDM_Module/CDM_Enhance — icon styling & state visuals

- **ArcUI_CDMEnhance.lua** — `ns.CDMEnhance`, the styling core: `EnhanceFrame`/`ApplyIconStyle`,
  merged settings (`GetIconSettings`, `GetOrCreateIconSettings`, `InvalidateCache`,
  `GetEffectiveIconSettingsForFrame`), ready/proc glow orchestration, cooldown curves,
  `GetEnhancedFrames`, mouse/tooltip state. Hooks CDM mixin methods; delegates to the files below.
- **ArcUI_CooldownFormatter.lua** — `ns.CooldownFormatter` (CF): 12.0.5 Cooldown text threshold
  APIs (milliseconds/abbrev) with feature probing.
- **ArcUI_GCDFilter.lua** — `GCDFilter.Install`: hooks visual Cooldown SetCooldown to strip GCD
  swipe, re-pushing real durObjs; defers to CooldownState when IAO is active.
- **ArcUI_Glows.lua** — `ns.Glows`: THE glow renderer for everything (LCG pixel/autocast/button/
  proc, Blizzard ants/ach_proc, CDM flash). Keyed Start/Stop per frame, Masque shape matching,
  forced alpha, resize handling, CDM VisualAlerts patch.
- **ArcUI_AuraFrames.lua** — `ns.AuraFrames` (AF): aura-frame visuals — aura-active glow,
  alpha/desaturate state visuals, threshold glow tickers, `UpdateAuraFrame` (the
  event-driven aura path), post-RefreshLayout sweep. Driven by `ns.FrameActive` callbacks.
- **ArcUI_CooldownState.lua** — `ns.CooldownState`: cooldown-only state detection via dual
  hidden shadow Cooldown frames; `FeedShadow` → relay → single-pass `Apply()` merging alpha,
  swipe, glow, text color, usability. (See "CooldownState is ONLY for cooldowns" rule above.)
- **ArcUI_Keybinds.lua** — `ns.Keybinds`: keybind text overlays on CDM + Arc Auras icons; caches
  bindings from standard/addon action bars; debounced refresh on binding events.
- **ArcUI_CustomLabel.lua** — `ns.CustomLabel`: up to 3 custom text overlays per icon with
  state-based visibility and curve alpha; `UpdateVisibility` called from CooldownState relay.
- **ArcUI_Masque.lua** — `ns.Masque`: Masque group registration for CDM/free/custom-group
  icons; conflict handling. Slash: `/arcmasque`.
- **ArcUI_CDMSpellUsability.lua + ArcUI_SpellUsabilityOptions.lua** — `ns.CDMSpellUsability`:
  usability vertex-color tinting + usable glow; caches CDM's RefreshIconColor/SetVertexColor
  state instead of polling; merges usability alpha into CooldownState's readyAlpha (single-writer
  alpha). NOTE: despite the name, SpellUsabilityOptions.lua contains the RUNTIME module; the
  per-icon options UI lives in CDMEnhanceOptions.
- **ArcUI_AssistedCombatHighlight.lua** — `ns.AssistedCombatHighlight`: Blizzard Assisted Combat
  "next cast" highlight on CDM/Arc Auras frames (ants or proc style); settings in
  `ArcUIDB.char[*].achSettings`.
- **ArcUI_ButtonPressHighlight.lua** — `ns.ButtonPressHighlight`: press-feedback overlay (hold/
  flash modes) via UseAction/CastSpellByID/CastSpellByName hooks; settings in `bphSettings`.
- **ArcUI_CDMTextColor.lua** — `ns.CDMTextColor`: cooldown countdown text coloring via
  ColorCurves; captures durObjs from SetCooldownFromDurationObject hook; 0.5s ticker only while
  frames are active.
- **ArcUI_CDMEnhanceOptions.lua** — the master per-icon/global-defaults options builder
  (`ns.GetCDMAuraIconsOptionsTable`, `ns.GetCDMCooldownIconsOptionsTable`,
  `ns.GetCDMGlobalAura/CooldownDefaultsOptionsTable`, `ns.GetCDMUtilitiesOptionsTable`);
  owns selection/edit-all/multi-select state (`ns.CDMEnhanceOptions`) and `ns.OptionsHelpers`
  (settings setters with edit-all expansion) used by other options modules.
- **ArcUI_CustomLabelOptions.lua** — `ns.CustomLabelOptions.GetAura/CooldownArgs()` injected
  into CDMEnhanceOptions; also exports `ns.AssistedCombatHighlightOptions`.

### CDM_Module/CDM_Groups — group/frame management

- **ArcUI_CDMGroups_Registry.lua** — `ns.FrameRegistry`: unified frame registry/lookup by
  cooldownID across viewers, groups, free icons, Arc Auras (`FindByCooldownID`, `Register`,
  `GetValidFrameForCooldownID`).
- **ArcUI_FrameController.lua** — `ns.FrameController`: SINGLE AUTHORITY for frame lifecycle —
  detects CDM rebuilds, scans viewers, assigns frames to groups/free (`Reconcile`,
  `AssignFrameToOwner`), installs anti-reclamation hooks, 2Hz visual maintainer, `OnFrameRebind`
  callback registry.
- **ArcUI_CDMGroups_Maintain.lua** — hook callbacks/installers (`HookFrame*`) that re-assert
  frame properties when CDM fights back; `SetupFreeIconFrame`, `FindFrameInViewers`.
- **ArcUI_CDMGroups_Layout.lua** — icon sizing/slot math, grid alignment, tooltip/click-through
  application (`SetupFrameInContainer`, `RefreshAllGroupLayouts`, `CalculateSlotPosition`).
- **ArcUI_CDMGroups_Placeholders.lua** — `ns.CDMGroups.Placeholders`: draggable placeholder
  frames for inactive cooldownIDs while options panel is open; slot badges and cooldown picker.
- **ArcUI_CDMGroups_StateManager.lua** — `ns.CDMGroups.StateManager`: protection windows during
  spec/talent change and profile load (`IsRestoring`, `IsInAnyProtection`) that block
  save/reflow.
- **ArcUI_CDMGroups_ImportRestore.lua** — `ns.CDMGroups.ImportRestore`: post-import placement —
  known icons restored, unknown placed as free grid; persists across reload, auto-expires.
- **ArcUI_CDMGroupsAnchors.lua** — `ns.CDMGroupsAnchors`: group→group/external-frame anchoring,
  mouse-follow, taint-safe re-anchoring on combat end/vehicle/Edit Mode; frame picker.
- **ArcUI_CDMGroups.lua** — `ns.CDMGroups`, the group core: `groups`/`freeIcons`/
  `savedPositions`, container pool, create/delete groups, drag mode, per-spec profiles
  (`LoadProfile`, `SaveCurrentToProfile`), visibility conditions (combat/mounted/group/etc. via
  `UpdateGroupVisibility` — hooked by bars for visibility sync), spec-change handling.
- **ArcUI_CDMGroups_DynamicLayout.lua** — `ns.CDMGroups.DynamicLayout`: reflow mode (fill gaps
  when auras hide) and dynamic positioning (auras flow around cooldown "walls"); dirty-group
  flagging.
- **ArcUI_CDMGroups_Integration.lua** — `ns.CDMGroups.Integration`: external-frame registration
  API used by Arc Auras (`RegisterExternalFrame`, `AssignToGroup`, `SavePosition`).
- **ArcUI_CDMGroupsOptions.lua** — `ns.GetCDMGroupsOptionsTable()`: group management panel
  (create/rename/delete, layout, appearance, strata, visibility conditions, anchoring UI).

### CDM_Module/Arc_Auras — custom item/spell/timer icons

- **ArcUI_ArcAuras.lua** — `ns.ArcAuras` core: frame creation/lifecycle/registry for tracked
  items/trinkets/spells/timers, CDMGroups positioning integration, settings cache, arcID scheme
  (`MakeTrinketID/MakeItemID/MakeSpellID`). Direct `ArcUIDB` access (bypasses AceDB). Slash:
  `/arc`.
- **ArcUI_ArcAurasCooldown.lua** — `ns.ArcAurasCooldown`: event-driven spell cooldown engine
  (shadow Cooldown frames + SPELL_UPDATE_* events) driving swipes, desaturation, usability tint,
  ready/proc glows; `spellData`/`spellsByID` consumed by ACH/BPH/Keybinds.
- **ArcUI_ArcAurasTimer.lua** — `ns.ArcAurasTimer`: custom timer engine (cast/cooldown/proc
  triggers, stack modes refresh/independent/consume), persists active state across reloads.
- **ArcUI_CustomIcons_Presets.lua** — `ns.CustomIconsPresets`: pure-data preset timer library +
  install helpers (`ns.AddTimerFromPreset`).
- **ArcUI_CustomIcons_Options.lua** — `ns.GetCustomIconsOptionsTable()`: Custom Icons tab
  (timer creation form, preset picker, per-timer editor).
- **ArcUI_ArcAuras_Options.lua** — `ns.ArcAurasOptions`: main Arc Auras panel — unified catalog
  (trinkets/items/spells/timers), selection state shared with Custom Icons tab.

### Files present but NOT loaded (not in ArcUI.toc)

- **ArcUI_TimerBars.lua** — old standalone timer-bar system, superseded by timer bars inside
  ArcUI_CooldownBars.lua. NOTE: `ns.TimerBars` still EXISTS at runtime — CooldownBars.lua
  (~line 9389) installs it as a compat shim aliasing `ns.CooldownBars` timer functions, and
  Bars_ImportExport + AppearanceOptions call through it.
- **ArcUI_ResourceOptions.lua** (`ns.ResourceOptions`) — orphaned resource options panel;
  the live UI is TrackingOptions (setup) + AppearanceOptions (appearance).
- **ArcUI_CustomTextures.lua** — LSM registration for ~140 community bar textures.
- **ArcUI_CRDebugger.lua** — dev tool: `/crdebug` cooldown state-transition tracer for the
  Cooldown Reminder engine.
- **ArcUI_Profiler.lua** — deleted in working tree (was a profiling tool; LibPleebug fills this
  role via `ns.lpmsg`).
