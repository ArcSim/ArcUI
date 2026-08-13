-- ===================================================================
-- ArcUI_Changelog.lua
-- "What's New" window. On the first login after an ArcUI update it pops a
-- styled changelog so players see what changed (the same notes we post on
-- CurseForge). Shown once per version; can be turned off in Settings, or
-- reopened any time via the "View Changelog" button / /arcchangelog.
--
-- TO UPDATE EACH RELEASE: add a new entry at the TOP of ns.Changelog.versions
-- (newest first) mirroring the CurseForge changelog. That's the only edit.
-- ===================================================================

local ADDON, ns = ...
ns = ns or {}
ns.Changelog = ns.Changelog or {}
local CL = ns.Changelog

-- Section colours (header tint).
local C_NEW   = "ff4ade80"  -- green  — New Features
local C_IMP   = "ff60a5fa"  -- blue   — Improvements
local C_FIX   = "fffbbf24"  -- amber  — Bug Fixes
local C_BRAND = "ff00ccff"  -- ArcUI cyan
local C_TITLE = "ffffffff"  -- entry title
local C_DESC  = "ffb0b0b0"  -- entry description

-- ===================================================================
-- CHANGELOG CONTENT  (newest version first)
-- Each version: { version = "x.y.z", sections = { { header, color, items = {
--   { title = "...", desc = "..." }, ... } } } }
-- ===================================================================
CL.versions = {
  {
    version = "3.7.11",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Use Texture Colors", desc = "A new toggle on aura, stack, duration, cooldown, charge, and resource bars plus both castbars: show your fill texture's own colors (gradients, rainbows, artwork) instead of tinting it with the bar color. Color controls that no longer apply gray out and say why." },
          { title = "One voice for the whole addon", desc = "Everything that speaks (Cooldown Reminder, CDM aura alerts, Arc icon alerts) now shares one Voice and Speech Rate setting and respects your Text-to-Speech volume. New speech controls include a Test Voice button, the \"sound between messages\" tick toggle, and a shortcut to WoW's own speech options." },
          { title = "Ignore Spell Overrides for Arc spell icons", desc = "A new per-icon toggle that keeps an Arc spell icon on its base spell's cooldown, artwork, and glows even while the spell is temporarily overridden." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Auto-Track Trinket Slots got their own section", desc = "The trinket auto-track controls moved out of the filter dropdown into a collapsible section right under Global Options, and an auto-tracked icon's Enabled toggle now drives the slot setting itself, so turning one off finally sticks across reloads." },
          { title = "Proper alert sound pickers", desc = "CDM aura alert dropdowns now show sound names with a preview button instead of raw file paths, and sound and speech can be set independently for every alert." },
          { title = "Icons stay honest through spec changes", desc = "An icon could keep an \"aura active\" look or a stuck ready glow after changing specs; ArcUI now re-checks every icon once the Cooldown Manager finishes shuffling and clears anything stale automatically." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "CDM aura alerts fire again", desc = "The alert feature was silently broken, and it now also covers icons the Cooldown Manager creates mid-session in dungeons." },
          { title = "Potions and healthstones get cooldown visuals", desc = "Bag-item icons in the Cooldown Manager never dimmed or dropped their ready glow. Item icons' ready glow also no longer stays on through the whole cooldown, and Ignore Aura Override now works on them." },
          { title = "Custom Icon field works again", desc = "Entering a spell, item, or icon ID in the Custom Icon box threw an error on every keystroke." },
          { title = "Custom icons stop flickering in combat", desc = "A custom icon could snap back to the original artwork and flip between the two mid-fight, especially in dungeons." },
          { title = "Stack bars show their countdown in combat", desc = "A stack bar's duration text went blank the moment combat started." },
          { title = "Settings apply without a reload", desc = "Changing countdown color thresholds, visiting the options panel, or flipping a bar between Stacks and Duration mode could silently kill a bar or texture countdown until a reload, especially after a fight." },
          { title = "Textures added by spell ID count down", desc = "Their duration text and drain never attached at all." },
          { title = "Hiding an icon keeps its texts", desc = "With Show Icon off, the stack count and countdown vanished along with the icon art instead of floating on their own." },
        },
      },
    },
  },
  {
    version = "3.7.10",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Aura Icons: Track Any Buff or Debuff by Spell ID", desc = "Give it a spell ID and you get an icon for that aura, whether or not the Cooldown Manager knows about it. They keep working in raids and Mythic+, where addons are no longer allowed to read your auras: a dimmed ghost while the aura is missing, the real icon while it is on you." },
          { title = "Spell-ID Aura Groups", desc = "Aura icons get their own group type that flows and compacts like any other Arc group, with its own border, title, drag mode, visibility conditions and per-spec profiles." },
          { title = "Aura Alert Sounds", desc = "Play a sound the moment an aura lands, refreshes or drops. The game plays these itself, so they still fire in content where aura tracking is hidden from addons." },
          { title = "Cooldown Manager Aura Alerts", desc = "Sounds and spoken callouts for buffs and debuffs tracked by the Cooldown Manager, with separate triggers for gaining it, losing it, and stacks going up." },
          { title = "Refresh-Window Glows", desc = "Aura icons can glow during the pandemic window, so you know exactly when reapplying is worth it." },
          { title = "Aura Bars and Textures by Spell ID", desc = "The Aura Catalog has a new green Add tile: enter a spell ID and it joins the catalog, so the same buttons build a duration bar, a stack bar or a texture for auras the Cooldown Manager never sees." },
          { title = "Ping Keys and the Ping Feed", desc = "Call your cooldowns out to your group with one key and no macros, and read everyone's pings in a window you can lay out yourself." },
          { title = "New Add Window for Arc Icons", desc = "One place to add items, trinkets, spell cooldowns, aura icons and custom timers, with a drag-and-drop zone." },
          { title = "One Icon Catalog", desc = "The Arc Icons and Custom Icons tabs are gone: every icon, its settings, load conditions, the timer editor, auto-tracking and bulk management now live together in the Icon Catalog." },
          { title = "Guided Tours", desc = "The What's New window can now walk you to exactly where the new features live." },
          { title = "Stack Priority for Free Icons", desc = "Free-positioned icons get a Stack Strata and Stack Level control in Icon Positioning, so you decide exactly which icon draws on top when icons overlap. The whole icon moves together: glows, text and keybinds follow." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Aura Textures Work Again on 12.1", desc = "Progress and Drain textures are driven by the game engine now, so the art still drains during combat and inside instances." },
          { title = "Bulk Management for Arc Icons", desc = "Clear all spells, all aura icons or everything at once, and force a refresh of Arc frames." },
          { title = "Layout Safety Warning", desc = "Loading a profile while layouts are linked can overwrite the shared layout on every character. The first time you do something risky, ArcUI explains it once." },
          { title = "Smoother Resource Bars", desc = "Energy and other fast-regenerating bars moved in visible chunks out of combat. They now update ten times a second while regenerating, and still cost nothing at rest." },
          { title = "One Line at Login", desc = "ArcUI now prints a single load message instead of a stream of module chatter." },
          { title = "Fewer Cooldown Updates per Keypress", desc = "Icons only react to cooldown events that actually concern them, cutting the work done on every cast of any ability." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Replacement Spells Show Their Real Cooldown", desc = "Spells that get swapped out by a talent or a proc (Stormstrike becoming Windstrike under Ascendance, Flame Shock becoming Voltaic Blaze) were read from the original spell, so those icons looked like they were never on cooldown. They now follow whichever form is live, and the icon art follows it too." },
          { title = "High-Haste Cooldown Flicker Fixed", desc = "Cooldown icons no longer blink ready for a split second mid-cooldown when you press other abilities, which got worse the more haste and cooldown reduction you had. Any cooldown read taken while a global cooldown is running now re-checks itself the moment that global ends, on both Arc icons and Cooldown Manager icons." },
          { title = "Cooldown Manager Icons Gray Out on Cooldown Again", desc = "Managed icons could stay full-color while on cooldown even though Arc icons of the same spell grayed out correctly. ArcUI now drives the gray-out itself instead of relying on the game's, which silently stops working on styled icons." },
          { title = "Totem Icons No Longer Stick as Active", desc = "A totem icon could keep showing as active after the totem was gone, most visibly on Earthbind." },
          { title = "Charge Numbers No Longer Vanish on Faded Groups", desc = "A group at partial opacity hid its charge text completely until you opened the CD Manager panel." },
          { title = "On-Use Trinkets No Longer Go Missing at Login", desc = "A trinket whose data had not loaded yet was treated as passive and hidden by the On-Use filter until you toggled auto-track off and on." },
          { title = "Layouts No Longer Look Like They Reset on Every Relog", desc = "A phantom spec entry created early at login made ArcUI read and write the wrong spec's layout depending on timing." },
          { title = "Cooldown Reminder Fires for Buff-Consumption Cooldowns", desc = "Spells whose cooldown only starts when the buff is spent never armed their ready reminder." },
          { title = "Bars and Textures Survive a Combat Reload", desc = "Reloading mid-fight or inside a dungeon could leave a duration bar's fill frozen and an aura texture's art static for the rest of the session, because they only set themselves up if the aura happened to be active at the right moment. They now set up as soon as they know which aura they track." },
          { title = "Aura Texture Art Shows Its Real Colour", desc = "Progress and Drain art could come up with the dimmed \"missing\" colour baked in instead of the active one." },
          { title = "Duration Text Settings Apply on 12.1 Bars", desc = "Decimals, abbreviation and colour-by-time were being ignored on engine-driven bars." },
          { title = "Bar Fill and Tick Marks", desc = "Bar fill no longer bleeds over the border, and tick marks come back on bars that hide when inactive." },
          { title = "Unit Frames Stay Put", desc = "Addons anchored to Arc icon groups no longer drift when the group is rebuilt." },
          { title = "Charge Bars Hide for Spells Your Build Doesn't Know", desc = "A charge bar for an untalented spell (like Healing Stream Totem on Elemental) stayed on screen as an empty black frame instead of hiding." },
          { title = "The Utility Group Keeps Its Column Count", desc = "Column settings could creep back to their default after a reload or relog." },
          { title = "Trinkets Keep Their Slot", desc = "A trinket icon could get bumped out of its saved position by another icon claiming the same cell during login or a spec change." },
          { title = "Cooldown Reminder Panel Grays Out While the Module Is Off", desc = "So it is clear those settings will not do anything until you enable it." },
        },
      },
    },
  },
  {
    version = "3.7.9",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Apply Look: Copy a Bar's Style Onto Other Bars", desc = "Style one bar, then apply its look to all bars of that type, all bars of every type, or a hand-picked list. The Include toggles choose what gets copied, and Text is now split into Stack, Duration, Name and Ready text so you can copy exactly the part you want." },
          { title = "Skins Panel Cleanup + Castbar Skin Picker", desc = "The Load Skin dropdown now lives inside the Skins section for every bar type, and the Castbar finally has its own, so loading a saved skin is where you'd expect it." },
          { title = "Castbar Skins Remember Position", desc = "Per-spec castbar skins now restore where the bar sits on screen, so switching specs puts each castbar back in its own spot. Re-save each skin once to pick this up." },
          { title = "Ignore Hard ICD for Charge Spells", desc = "New per-icon option for charge spells that lock briefly after each use (like Monk's Zenith): the icon no longer looks fully spent while you still hold a charge, and the swipe shows the real recharge instead of the lockout." },
          { title = "Gained-on-Cooldown Spells Just Work", desc = "Arc icons for spells you only have while a cooldown is active (Void Volley, Zenith Stomp) now appear when you gain them and disappear after, instead of being marked \"not part of this spec\" and needing Show Always." },
          { title = "Per-Side Fill Inset for Aura Bars", desc = "Independent Left/Right/Top/Bottom insets so custom bar textures with built-in borders sit perfectly inside the background. Contributed by Linawow." },
          { title = "Addon Integration API", desc = "Other addons can now anchor their frames to ArcUI's icon groups reliably (fixes unit frames shifting on druid form changes with MSUF, and opens the door for more integrations)." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Hide Stacks at Zero on Arc Icons", desc = "The \"Hide at 0\" option now works on Arc cooldown icon stack text, everywhere including dungeons." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Castbar No Longer Disappears Mid-Cast", desc = "Casting an instant spell (like Shimmer) or pressing your next cast early no longer hides the bar or flashes a false \"Cancelled\", and reloading mid-cast brings the bar right back." },
          { title = "Castbar Match Size Sticks After Reload", desc = "Castbars matched to a group's size no longer come back wrong after a reload." },
          { title = "Timer Text No Longer Flickers on Dimmed Icons", desc = "Cooldown text kept visible with Preserve Duration Text no longer flickers or vanishes while Ignore Aura Override is on (was worst on Fire and Storm Elemental)." },
          { title = "Custom Timer Icons No Longer Blink", desc = "Timer icons watching a spell no longer randomly flip between their Active and Not Active looks." },
          { title = "Thin Borders Sit Flush", desc = "1px icon borders no longer drift a pixel off the icon at some UI scales." },
        },
      },
    },
  },
  {
    version = "3.7.8",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Focus Castbar: Hide Non-Important Casts", desc = "Show the focus castbar only for casts Blizzard marks as important (the dangerous ones), so it stays out of the way during trash. Off by default." },
          { title = "Global Font & Texture", desc = "Set your font and bar texture once and apply them everywhere at once (all bars, both castbars, and cooldown text) instead of changing each one by hand." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Match Icon Edges Now Works on Aura Bars", desc = "Lines your aura bars up neatly with your icon group, the same way it already does for the other bar types. If you already had it on, the bar will snap into place." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Stacks and Timers Show Again", desc = "Fixed aura stack numbers and duration timers that had stopped showing for some players." },
          { title = "Midnight (12.1) Fixes", desc = "On the upcoming Midnight patch, duration bars and aura textures now keep working properly in combat." },
        },
      },
    },
  },
  {
    version = "3.7.7",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Patch 12.1 (Midnight) Support", desc = "ArcUI now runs on the 12.1 Midnight PTR. The new patch changes how buffs and debuffs can be read, which used to break large parts of the addon. ArcUI now detects the new restrictions and adapts, so your bars, cooldown icons, and aura tracking keep working. The few options the new rules make impossible are disabled on 12.1 and clearly marked in the panel (they still work normally on live). This is a work in progress and may have rough edges, but the addon is now usable on 12.1 instead of breaking." },
          { title = "Focus Castbar", desc = "A castbar showing what your focus target is casting, with spell name, timer, and icon. Color it differently for spells you can't interrupt or hide those entirely, show a marker the moment your interrupt comes off cooldown, keep the bar on screen briefly after a cast (colored for success, fail, or interrupt), and add a glow for important casts. Off by default, under Castbar > Focus Castbar. Contributed by Seraidi." },
          { title = "Dim or Hide a Cooldown Icon While Its Aura Is Active", desc = "A per-icon option to fade or fully hide a cooldown icon while the buff it tracks is up, so an icon that is already in use gets out of the way. Off by default." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Collapsible Option Sections", desc = "The Cooldown Reminder appearance and audio panel and the Custom Auras and Cooldowns lists now use collapsible headers so long panels are easier to scan." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Cooldown Reminder: No False Alert on Windup Items", desc = "Items with a short effect window before their real cooldown (like the Algari Puzzle Box) no longer announce \"ready\" the instant the effect ends." },
          { title = "Cooldown Reminder: Reminders Work Immediately When Set Mid-Cooldown", desc = "A reminder created or edited while the spell or item is already on cooldown now starts tracking right away." },
          { title = "Instance and Mythic+ Stability", desc = "Totem cooldown bars and secondary-resource bars (such as Soul Fragments and Maelstrom Weapon) no longer risk errors inside dungeons and raids." },
        },
      },
    },
  },
  {
    version = "3.7.6",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Kick Assist Interrupt Alert", desc = "Get a sound or spoken (text-to-speech) alert the moment your focus starts casting and your interrupt is off cooldown, so you know to look and kick. Pick from built-in alert sounds or any shared-media sound, choose the channel, set your own spoken word, and preview it. Off by default." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Single-Charge Spells as Cooldown Bars", desc = "Spells with a single charge, like Evoker's Fire Breath, now show up in the cooldown bar picker and track as a normal cooldown, instead of being mistaken for a charge spell and showing a 0/1 count." },
          { title = "Aura Threshold Glows on Self-Buffs", desc = "Fixed threshold glows on tracked buff and debuff icons that could fail to fire for personal buffs, so they now light up reliably as the aura nears your set threshold." },
        },
      },
    },
  },
  {
    version = "3.7.5.a",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Aura Textures", desc = "A new Buffs/Debuffs display type. Place any image on screen that turns on when a buff or debuff is active and off when it's gone. Pick from a built-in art gallery or your own file, drag and resize it in place, and optionally make it drain like a bar as the aura runs down, pulse, fade as it expires, or show a built-in countdown, with per-spec/talent and Hide When conditions." },
          { title = "Duration Text Threshold Colors", desc = "Aura bars and Aura Textures can recolor their remaining-time countdown through seconds-based thresholds, so the number changes color as the aura nears expiry." },
          { title = "Stack Threshold Colors", desc = "Color a tracked buff's stack number by how many stacks are up, with up to six adjustable count-and-color bands, working even in Mythic+ and instances." },
          { title = "Show Icon Toggle", desc = "A new per-icon switch hides the icon art, swipe and flash while keeping just the stack and duration text, for clean text-only trackers." },
          { title = "Desaturate When Aura Inactive", desc = "A new per-cooldown-icon option grays out the icon whenever its tracked buff drops, for an at-a-glance signal that the buff is down." },
          { title = "Kick Assist Smart Open", desc = "An opt-in mode that, after a ready check, briefly watches party chat and only opens the marker picker if someone else calls out your marker, so you only re-pick when there's an actual clash." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Reorganized Options Menu", desc = "Settings are regrouped for clarity, with a Buffs/Debuffs section gathering the aura Catalog, Textures and Appearance, and a dedicated Cooldowns section gathering Cooldown Bars, Custom Bars and Cooldown Reminder." },
          { title = "Bars Stay Out of the Way", desc = "Cooldown, charge, resource, custom and timer bars are now click-through during normal play and only become draggable while the options panel is open, so they no longer intercept clicks in combat." },
          { title = "Bar Name Text Fine-Tuning", desc = "Buff and debuff bars now expose X and Y offset on their name text, so you can nudge it after choosing a left, center or right position." },
          { title = "Cooldown Display Stability", desc = "Further back-end hardening of the cooldown icon display to reduce the chance of it breaking partway through Mythic+ or other instanced content." },
          { title = "Kick Marker Stays on Your Focus", desc = "Your interrupt marker is always placed on your focus and stays there, so re-pressing your kick key never moves it onto your current target." },
          { title = "Account-Wide Kick Assist Toggle", desc = "Turning Kick Assist on or off now applies to all your characters, with your existing setting carried over automatically." },
          { title = "Clearer Marker Macro Wording", desc = "Macro templates and the editor use a clearer marker placeholder and a renamed Add / Sync Marker Line button; older macros keep working." },
          { title = "Clearer Dynamic Cooldowns Help", desc = "The Dynamic Cooldowns option now explains that an icon only collapses out of the row when its alpha is set to 0, and points you to the exact setting." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Cooldown Icons Vanishing in Mythic+ and Arenas", desc = "Tracked down and fixed a core cause of the cooldown display breaking partway through dungeons, raids and PvP, where icons could disappear until a reload." },
          { title = "Dynamic Cooldowns Groups Loading", desc = "Fixed groups using Dynamic Cooldowns whose icons could stay collapsed or fail to appear until a reload, most noticeably right after importing a profile." },
          { title = "Imported Groups No Longer Scatter", desc = "If an imported profile referenced a group that didn't come through, its icons used to fling across the screen. The missing group is now rebuilt and its icons stay together." },
          { title = "Quick Import Keeps Icons in Their Groups", desc = "Importing a layout from another of your characters on the same spec now keeps each icon in its group, instead of emptying custom groups and dumping their icons into the defaults." },
          { title = "Account-Wide Imports Carry Shared Layouts", desc = "Account-wide (master) imports now bring your shared Group Layouts with them, so a profile linked to a shared layout keeps its groups and their positions." },
          { title = "Totem Tracking Transfers on Import", desc = "The Arc Auras totem-slot toggle now exports and imports, so totems turn on for whoever imports the profile." },
          { title = "Linked Layout Group Positions", desc = "A group's position now loads correctly when re-importing a profile that's linked to a shared Group Layout." },
          { title = "Correct Group Count in Preview", desc = "The import and export preview now shows the real number of groups for a profile linked to a shared layout, instead of undercounting." },
          { title = "Bar Text Alignment", desc = "Left- and right-aligned bar name and duration text now pin their first character to the chosen edge instead of centering on it, so long names read correctly and no longer drift." },
          { title = "Resource Text Color in Instances", desc = "Fixed resource bar value text that could break its threshold coloring inside dungeons, raids and PvP." },
          { title = "Self-Buff Icons Display Correctly", desc = "Cooldown icons, custom labels and glows that track a personal self-buff (like Voidfall) now correctly recognize the buff as active instead of treating it as missing." },
        },
      },
    },
  },
  {
    version = "3.7.4",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Kick Assist", desc = "A built-in interrupt helper in its own tab. Claim your kick raid marker, have it automatically called out to your group on a ready check, and drag ready-made one-press interrupt macros straight onto your bars. Pick which instances it triggers in: Mythic+, Mythic, Heroic, Normal, or Raids. Also available as a separate addon if you want just this without ArcUI." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Smoother Bars", desc = "Bar and resource animations no longer do work every frame. Rune fill updates are throttled and go idle when all runes are ready, lowering background CPU use during play." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Duration Text on Refresh", desc = "Buff and debuff bar countdowns now update correctly when a buff is refreshed, for example Bone Shield, instead of freezing on the old time." },
        },
      },
    },
  },
  {
    version = "3.7.3",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Patch 12.1 Support", desc = "ArcUI is now compatible with patch 12.1. That patch is brand new, so some new errors may show up there that did not happen before; please report anything you run into so it can be fixed quickly." },
          { title = "Share Castbar Across Characters", desc = "Optional setting, off by default, that uses one castbar look on every character, starting from the castbar you already have set up, with each character keeping its own on-screen position unless you also share the position." },
          { title = "Castbar Import and Export", desc = "Share your full castbar setup as a string and load it on another character, or bundle it into your bars export so colors, fonts, per-cast-type profiles, thresholds, and position travel together." },
          { title = "Import a Castbar as a Saved Skin", desc = "When a shared string includes a castbar, the import lets you either replace your live castbar or save the incoming one as a named skin you can apply later." },
          { title = "Hide Blizzard Castbar", desc = "Optional toggle, off by default, that hides the default Blizzard castbar, and turning it back on restores the bar without reloading." },
          { title = "Movable Spell Icon", desc = "Optional setting, off by default, that lets you drag the castbar's spell icon to a custom position while the options panel is open, with a reset button to restore it." },
          { title = "Shorten Long Spell Names", desc = "Optional setting, off by default, that trims spell names longer than a chosen length so they fit on the castbar." },
          { title = "Resource Bar Text Color by Value", desc = "Optional, off by default: resource bar value text can change color based on how full the resource is, with up to four color zones plus a base color and a choice of Fill or Drain direction." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Lighter Casting Updates", desc = "The castbar now listens only for your own casting events, reducing background work during play." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Cooldown Display Stability", desc = "Back-end fixes to make the cooldown display less likely to stop working partway through a dungeon or raid." },
          { title = "Cooldown Group Positioning", desc = "Back-end improvements to cooldown group icon placement, to help reduce icons doubling up, overlapping, or leaving stray empty gaps after talent changes, when opening the options panel, or on login." },
          { title = "Castbar No Longer Lingers After a Failed Cast", desc = "The castbar now correctly clears when a cast is rejected, queued, or fails instead of staying on screen." },
        },
      },
    },
  },
  {
    version = "3.7.2",
    sections = {
      {
        header = "New Features", color = C_NEW, items = {
          { title = "Castbar", desc = "A brand-new player cast bar, with per-cast-type profiles, an optional Auto Share toggle so one cast type's look carries across the others, full support for empowered spells (proper stage segments and timing), and threshold-based color changes. Big thanks to Sadraii, who created the original cast bar module this was expanded from." },
          { title = "Dynamic Cooldowns", desc = "A new per-group option that compacts your cooldown icons the same way Dynamic Auras does: icons drop out and the rest slide together based on whether they're ready or on cooldown. Works hand-in-hand with Dynamic Auras." },
          { title = "Smooth Movement", desc = "When a dynamic group rearranges, icons now glide smoothly into their new spot instead of snapping, with an adjustable speed. Opt-in per group." },
          { title = "Icon Order: First Come, First Served", desc = "Choose how a dynamic group orders its icons: classic Priority order, or First Come First Served, where the icon that became active first keeps its spot and new ones line up after it instead of everything reshuffling." },
          { title = "Custom Icon Stacks: Start Full & Recharge", desc = "Custom timer icons can now show full stacks from the start before the first cast, plus a new \"Timer Complete\" generator with \"Recharge until full\" to build charge-style stack behavior." },
          { title = "What's New Window", desc = "ArcUI now shows a changelog after each update so you always know what changed. Toggle it off in Settings." },
        },
      },
      {
        header = "Improvements", color = C_IMP, items = {
          { title = "Bar Performance", desc = "The buff/debuff/stack bar tracking engine was rebuilt from the ground up for smoother updates and noticeably lower CPU use, especially when tracking lots of auras at once." },
          { title = "Lower CPU Spikes", desc = "Big reductions in the CPU hitch when leaving combat and when players join your party or raid." },
          { title = "Cleaner Custom Icon Options", desc = "The Custom Icons (timer) settings panel now only shows options that actually apply to timers, with the Active / Not Active states behaving correctly and \"Hide at 0\" working properly for stacks." },
          { title = "Totem Dynamic Placement", desc = "Empty totem slots now collapse and compact with Dynamic Auras, keeping your totem icons tidy." },
        },
      },
      {
        header = "Bug Fixes", color = C_FIX, items = {
          { title = "Reverse Swipe While Aura Active", desc = "Fixed the swipe reverting to its normal direction when you left combat while the aura was still active; it now stays reversed for the full duration." },
          { title = "Charge Spell Placement", desc = "Fixed dynamic placement sometimes failing on charge spells, where an icon wouldn't collapse or return as a charge was spent or came back." },
          { title = "Hide CDM Icon Staying Hidden", desc = "Fixed the Blizzard cooldown frame reappearing when a bar had \"Hide CDM Icon\" turned on: after logging in or reloading, on entering or leaving combat, and when opening the options panel. It now stays hidden at all times, including free-floating icons." },
        },
      },
    },
  },
}

-- ===================================================================
-- HELPERS
-- ===================================================================
local function GetCurrentVersion()
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    return C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
  elseif GetAddOnMetadata then
    return GetAddOnMetadata(ADDON, "Version") or "?"
  end
  return "?"
end

-- Base version with any minor hotfix suffix stripped: "3.7.2.a" -> "3.7.2".
-- The auto-show tracks the BASE version so a minor hotfix (.a/.b) does NOT re-pop
-- the What's New window for players who already saw the base release. Players who
-- never saw the base release still get it (their lastSeen won't match the base),
-- and a hotfix's notes are merged into the base entry so they see those too.
local function GetBaseVersion()
  return (GetCurrentVersion():gsub("%.%a+$", ""))
end

-- Build the coloured body text for ONE version (its sections + items only). The
-- version number lives on the collapsible header row, not in the body.
local function BuildVersionBody(ver)
  local lines = {}
  for _, section in ipairs(ver.sections or {}) do
    lines[#lines + 1] = string.format("|c%s%s|r", section.color or C_TITLE, section.header or "")
    for _, item in ipairs(section.items or {}) do
      if item.desc and item.desc ~= "" then
        lines[#lines + 1] = string.format("  |c%s>|r |c%s%s|r  |c%s%s|r",
          section.color or C_TITLE, C_TITLE, item.title or "", C_DESC, item.desc)
      else
        lines[#lines + 1] = string.format("  |c%s>|r |c%s%s|r",
          section.color or C_TITLE, C_TITLE, item.title or "")
      end
    end
    lines[#lines + 1] = " "
  end
  return table.concat(lines, "\n")
end

-- ===================================================================
-- WINDOW
-- ===================================================================
local frame

local function BuildFrame()
  if frame then return frame end

  local f = CreateFrame("Frame", "ArcUIChangelogFrame", UIParent, "BackdropTemplate")
  f:SetSize(540, 580)
  f:SetPoint("CENTER")
  -- TOOLTIP, not DIALOG: the options window is FULLSCREEN_DIALOG, so a DIALOG
  -- frame opens BEHIND it when the changelog is launched from the Settings tab
  -- (Raise only reorders within a strata). Same choice the Add popup makes.
  f:SetFrameStrata("TOOLTIP")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  f:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
  f:SetBackdropBorderColor(0, 0.8, 1, 0.55)
  f:Hide()

  -- Accent bar along the top
  local accent = f:CreateTexture(nil, "ARTWORK")
  accent:SetColorTexture(0, 0.8, 1, 0.85)
  accent:SetPoint("TOPLEFT", 1, -1)
  accent:SetPoint("TOPRIGHT", -1, -1)
  accent:SetHeight(3)

  -- Title
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 18, -16)
  title:SetText(string.format("|c%sArc UI|r  |cffffffffWhat's New|r", C_BRAND))

  local ver = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ver:SetPoint("TOPRIGHT", -38, -20)
  ver:SetText(string.format("|cff888888v%s|r", GetCurrentVersion()))
  f._versionText = ver

  -- Close (X)
  local x = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  x:SetPoint("TOPRIGHT", 2, 2)
  x:SetScript("OnClick", function() f:Hide() end)

  -- Divider under the title
  local div = f:CreateTexture(nil, "ARTWORK")
  div:SetColorTexture(1, 1, 1, 0.10)
  div:SetPoint("TOPLEFT", 16, -44)
  div:SetPoint("TOPRIGHT", -16, -44)
  div:SetHeight(1)

  -- Scroll body
  local scroll = CreateFrame("ScrollFrame", "ArcUIChangelogScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -52)
  scroll:SetPoint("BOTTOMRIGHT", -34, 50)

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(470, 10)
  scroll:SetScrollChild(content)
  f._content = content
  f._scroll = scroll

  -- One collapsible block per version: a clickable header row plus the version's
  -- body text. The newest version is expanded by default; older versions start
  -- collapsed and expand when the player clicks their header.
  f._blocks = {}
  for i, verData in ipairs(CL.versions) do
    local block = { ver = verData, expanded = (i == 1) }

    local hdr = CreateFrame("Button", nil, content)
    hdr:SetHeight(22)
    local hbg = hdr:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints()
    hbg:SetColorTexture(1, 1, 1, 0.05)
    hdr._bg = hbg
    local htext = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    htext:SetPoint("LEFT", 4, 0)
    htext:SetJustifyH("LEFT")
    hdr._text = htext
    hdr:SetScript("OnEnter", function(self) self._bg:SetColorTexture(0, 0.8, 1, 0.13) end)
    hdr:SetScript("OnLeave", function(self) self._bg:SetColorTexture(1, 1, 1, 0.05) end)
    hdr:SetScript("OnClick", function()
      block.expanded = not block.expanded
      if f._Relayout then f._Relayout() end
    end)
    block.header = hdr

    local b = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b:SetWidth(452)
    b:SetJustifyH("LEFT")
    b:SetJustifyV("TOP")
    b:SetSpacing(4)
    b:SetText(BuildVersionBody(verData))
    block.body = b

    f._blocks[i] = block
  end

  -- Stack the blocks top-to-bottom, showing each body only while its version is
  -- expanded, then size the scroll child to the total height.
  f._Relayout = function()
    local y = 0
    for i, block in ipairs(f._blocks) do
      local arrow = block.expanded and "|cff00ccff-|r" or "|cff888888+|r"
      local tag = (i == 1) and "   |cff4ade80Latest|r" or ""
      block.header._text:SetText(string.format("%s  |cffffd100Version %s|r%s", arrow, block.ver.version, tag))
      block.header:ClearAllPoints()
      block.header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
      block.header:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
      y = y + 24
      if block.expanded then
        block.body:ClearAllPoints()
        block.body:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -y)
        block.body:Show()
        y = y + (block.body:GetStringHeight() or 0) + 10
      else
        block.body:Hide()
      end
    end
    content:SetSize(470, math.max(y, 10))
    if f._scroll then f._scroll:SetVerticalScroll(0) end
  end

  -- Footer divider
  local fdiv = f:CreateTexture(nil, "ARTWORK")
  fdiv:SetColorTexture(1, 1, 1, 0.10)
  fdiv:SetPoint("BOTTOMLEFT", 16, 42)
  fdiv:SetPoint("BOTTOMRIGHT", -16, 42)
  fdiv:SetHeight(1)

  -- "Show on update" checkbox
  local cb = CreateFrame("CheckButton", "ArcUIChangelogCheck", f, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("BOTTOMLEFT", 14, 12)
  local cbText = _G[cb:GetName() .. "Text"]
  if cbText then cbText:SetText("Show automatically on each update") end
  cb:SetScript("OnClick", function(self)
    local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if g then
      g.changelog = g.changelog or {}
      g.changelog.disabled = not self:GetChecked()
    end
  end)
  f._check = cb

  -- Close button
  local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  close:SetSize(100, 24)
  close:SetPoint("BOTTOMRIGHT", -14, 10)
  close:SetText("Close")
  close:SetScript("OnClick", function() f:Hide() end)

  -- Guided tour launcher: the PRIMARY action on this window, not a footnote
  -- beside Close. The changelog says what changed, the tour shows where, and a
  -- tour nobody notices teaches nobody. Centred, oversized and accented.
  -- Hidden when this version has no tour authored.
  local tour = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  tour:SetSize(220, 26)
  tour:SetPoint("TOP", f, "TOP", 0, -50)
  tour:SetText("Click for Guided Tour")
  local tfs = tour:GetFontString()
  if tfs then
    tfs:SetTextColor(0.25, 0.79, 0.95)
    local fp, _, fl = tfs:GetFont()
    if fp then tfs:SetFont(fp, 14, fl) end
  end
  tour:SetScript("OnClick", function()
    f:Hide()
    if ns.Tour and ns.Tour.Start then ns.Tour.Start() end
  end)
  f._tourBtn = tour

  -- Escape closes it
  if not tContains(UISpecialFrames, "ArcUIChangelogFrame") then
    tinsert(UISpecialFrames, "ArcUIChangelogFrame")
  end

  frame = f
  return f
end

-- Populate + show.
function CL.Show()
  local f = BuildFrame()
  if f._versionText then
    f._versionText:SetText(string.format("|cff888888v%s|r", GetCurrentVersion()))
  end
  -- Open with the newest version expanded and older ones collapsed every time,
  -- so players always land on the latest notes.
  for i, block in ipairs(f._blocks) do block.expanded = (i == 1) end
  f._Relayout()
  -- Reflect the current setting on the checkbox.
  local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
  local disabled = g and g.changelog and g.changelog.disabled
  if f._check then f._check:SetChecked(not disabled) end
  -- only offer the tour when this version actually has one authored, and give
  -- the button its own band above the notes: the scroll starts lower when it
  -- is there, and reclaims the space when it is not
  if f._tourBtn then
    local has = (ns.Tour and ns.Tour.HasTour and ns.Tour.HasTour()) and true or false
    f._tourBtn:SetShown(has)
    if f._scroll then
      f._scroll:ClearAllPoints()
      f._scroll:SetPoint("TOPLEFT", 16, has and -84 or -52)
      f._scroll:SetPoint("BOTTOMRIGHT", -34, 50)
    end
  end
  f:Show()
  f:Raise()
end

function CL.Hide()
  if frame then frame:Hide() end
end

function CL.Toggle()
  if frame and frame:IsShown() then frame:Hide() else CL.Show() end
end

-- ===================================================================
-- AUTO-SHOW ON UPDATE
-- ===================================================================
local function CheckOnLogin()
  local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
  if not g then
    -- DB not ready yet (AceDB created at PLAYER_LOGIN) — retry shortly.
    C_Timer.After(2, CheckOnLogin)
    return
  end
  g.changelog = g.changelog or {}
  if g.changelog.disabled then return end

  -- The 3.7.10 notes (and their guided tours) describe 12.1 features. If the
  -- client is still on an older patch, hold the auto-pop and DON'T mark the
  -- version seen — it then pops on the first login after the client is 12.1.
  -- Manual /arccl is unaffected.
  local iface = select(4, GetBuildInfo())
  if type(iface) == "number" and iface < 120100 then return end

  local cur = GetBaseVersion()   -- base version: minor hotfixes (.a/.b) don't re-pop
  if g.changelog.lastSeen ~= cur then
    g.changelog.lastSeen = cur   -- mark seen so it only pops once per base version
    CL.Show()
  end
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loginFrame:SetScript("OnEvent", function(self)
  -- Fire on the FIRST PLAYER_ENTERING_WORLD (initial login, after the loading
  -- screen has finished) and never again this session — unregister so later
  -- zone/instance loading screens don't re-trigger it.
  self:UnregisterEvent("PLAYER_ENTERING_WORLD")
  -- Small cushion so it lands right after the screen clears, not on its tail.
  C_Timer.After(1, CheckOnLogin)
end)

-- ===================================================================
-- SLASH
-- ===================================================================
SLASH_ARCCHANGELOG1 = "/arcchangelog"
SLASH_ARCCHANGELOG2 = "/arccl"
SlashCmdList["ARCCHANGELOG"] = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "reset" or msg == "test" then
    -- Forget the "seen" version so the popup auto-shows again on next login/reload.
    local g = ns.API and ns.API.GetGlobalDB and ns.API.GetGlobalDB()
    if g then
      g.changelog = g.changelog or {}
      g.changelog.lastSeen = nil
      g.changelog.disabled = false
    end
    print("|cff00ccffArcUI|r: changelog reset \226\128\148 it'll pop automatically on your next /reload (or run /arccl to open it now).")
  else
    CL.Show()
  end
end
