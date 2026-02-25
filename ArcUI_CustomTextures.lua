-- ===================================================================
-- ArcUI_CustomTextures.lua (AUTO-GENERATED — do not edit manually)
-- Run generate_textures.bat to rebuild after adding/removing files.
-- Share your textures in the ArcUI Discord to get them added
-- ===================================================================

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
if not LSM then return end

local TEXTURE_PATH = [[Interface\AddOns\ArcUI\CustomTextures\]]

local COMMUNITY_TEXTURES = {
  { name = "ArcUI: ArcaneCharge Full", file = "ArcaneCharge_Full.tga" },
  { name = "ArcUI: BRune Full", file = "BRune_Full.tga" },
  { name = "ArcUI: ChiRPG Empty", file = "ChiRPG_Empty.tga" },
  { name = "ArcUI: ChiRPG Full", file = "ChiRPG_Full.tga" },
  { name = "ArcUI: Chi Empty", file = "Chi_Empty.tga" },
  { name = "ArcUI: Chi Full", file = "Chi_Full.tga" },
  { name = "ArcUI: Circular bar", file = "Circular_bar.tga" },
  { name = "ArcUI: Circular bar backer", file = "Circular_bar_backer.tga" },
  { name = "ArcUI: Circular bar backer gold", file = "Circular_bar_backer_gold.tga" },
  { name = "ArcUI: Circular bar backer silver", file = "Circular_bar_backer_silver.tga" },
  { name = "ArcUI: CLEAN HUDCIRCLE", file = "CLEAN_HUDCIRCLE.tga" },
  { name = "ArcUI: Combo Border ACharge", file = "Combo_Border_ACharge.tga" },
  { name = "ArcUI: Combo Border ACharge Full", file = "Combo_Border_ACharge_Full.tga" },
  { name = "ArcUI: Combo Empty", file = "Combo_Empty.tga" },
  { name = "ArcUI: Combo Full", file = "Combo_Full.tga" },
  { name = "ArcUI: Combo Full Inner", file = "Combo_Full_Inner.tga" },
  { name = "ArcUI: DR Full", file = "DR_Full.tga" },
  { name = "ArcUI: DSSGRPG Full", file = "DSSGRPG_Full.tga" },
  { name = "ArcUI: DSSORPG Full", file = "DSSORPG_Full.tga" },
  { name = "ArcUI: emptybar", file = "emptybar.tga" },
  { name = "ArcUI: EssenceRPG Empty", file = "EssenceRPG_Empty.tga" },
  { name = "ArcUI: EssenceRPG Full", file = "EssenceRPG_Full.tga" },
  { name = "ArcUI: Essence Empty", file = "Essence_Empty.tga" },
  { name = "ArcUI: Essence Full", file = "Essence_Full.tga" },
  { name = "ArcUI: FRune Full", file = "FRune_Full.tga" },
  { name = "ArcUI: FRune Full1", file = "FRune_Full1.tga" },
  { name = "ArcUI: FRune Full2", file = "FRune_Full2.tga" },
  { name = "ArcUI: FRune Full3", file = "FRune_Full3.tga" },
  { name = "ArcUI: FRune Full4", file = "FRune_Full4.tga" },
  { name = "ArcUI: FRune Full5", file = "FRune_Full5.tga" },
  { name = "ArcUI: FRune Full6", file = "FRune_Full6.tga" },
  { name = "ArcUI: HexBar", file = "HexBar.tga" },
  { name = "ArcUI: HexBarRPG", file = "HexBarRPG.tga" },
  { name = "ArcUI: HexBarRPG Mini", file = "HexBarRPG_Mini.tga" },
  { name = "ArcUI: HexBarRPG Thin", file = "HexBarRPG_Thin.tga" },
  { name = "ArcUI: HexBar BottomBar", file = "HexBar_BottomBar.tga" },
  { name = "ArcUI: HexBar BottomBar Fill", file = "HexBar_BottomBar_Fill.tga" },
  { name = "ArcUI: HexBar FiveBar", file = "HexBar_FiveBar.tga" },
  { name = "ArcUI: HexBar Highlight", file = "HexBar_Highlight.tga" },
  { name = "ArcUI: HexBar Icon Thin", file = "HexBar_Icon_Thin.tga" },
  { name = "ArcUI: HexBar Loading Empty", file = "HexBar_Loading_Empty.tga" },
  { name = "ArcUI: HexBar Loading Fill", file = "HexBar_Loading_Fill.tga" },
  { name = "ArcUI: HexBar LongThin", file = "HexBar_LongThin.tga" },
  { name = "ArcUI: HexBar Mini", file = "HexBar_Mini.tga" },
  { name = "ArcUI: HexBar Thin", file = "HexBar_Thin.tga" },
  { name = "ArcUI: HexBar Thin Generic", file = "HexBar_Thin_Generic.tga" },
  { name = "ArcUI: HexBar Thin Generic Empty", file = "HexBar_Thin_Generic_Empty.tga" },
  { name = "ArcUI: HexBar Tick", file = "HexBar_Tick.tga" },
  { name = "ArcUI: HolyPower Empty", file = "HolyPower_Empty.tga" },
  { name = "ArcUI: HolyPower Full", file = "HolyPower_Full.tga" },
  { name = "ArcUI: Indicator Combat", file = "Indicator_Combat.tga" },
  { name = "ArcUI: Indicator Curse", file = "Indicator_Curse.tga" },
  { name = "ArcUI: Indicator Disease", file = "Indicator_Disease.tga" },
  { name = "ArcUI: Indicator Elite", file = "Indicator_Elite.tga" },
  { name = "ArcUI: Indicator Magic", file = "Indicator_Magic.tga" },
  { name = "ArcUI: Indicator PartyLead", file = "Indicator_PartyLead.tga" },
  { name = "ArcUI: Indicator Poison", file = "Indicator_Poison.tga" },
  { name = "ArcUI: Indicator Rare", file = "Indicator_Rare.tga" },
  { name = "ArcUI: Indicator Resting", file = "Indicator_Resting.tga" },
  { name = "ArcUI: Indicator Resting Billboard", file = "Indicator_Resting_Billboard.tga" },
  { name = "ArcUI: Indicator StatusEffect", file = "Indicator_StatusEffect.tga" },
  { name = "ArcUI: Indicator SummPending", file = "Indicator_SummPending.tga" },
  { name = "ArcUI: Nugs UIHelper Murloc", file = "Nugs_UIHelper_Murloc.tga" },
  { name = "ArcUI: Nugs Warlock Felstalker", file = "Nugs_Warlock_Felstalker.tga" },
  { name = "ArcUI: Nugs Warlock Tyrant", file = "Nugs_Warlock_Tyrant.tga" },
  { name = "ArcUI: Nugs Warlock WildImp", file = "Nugs_Warlock_WildImp.tga" },
  { name = "ArcUI: Nugs Warlock WildImp Horde", file = "Nugs_Warlock_WildImp_Horde.tga" },
  { name = "ArcUI: Nugs Warrior Offensive", file = "Nugs_Warrior_Offensive.tga" },
  { name = "ArcUI: Nugs Warrior Shield", file = "Nugs_Warrior_Shield.tga" },
  { name = "ArcUI: OyanaUI Cancel", file = "OyanaUI_Cancel.tga" },
  { name = "ArcUI: OyanaUI Combat Indicator Large", file = "OyanaUI_Combat_Indicator_Large.tga" },
  { name = "ArcUI: OyanaUI Confirm", file = "OyanaUI_Confirm.tga" },
  { name = "ArcUI: OyanaUI Error", file = "OyanaUI_Error.tga" },
  { name = "ArcUI: OyanaUI ico empty", file = "OyanaUI_ico_empty.tga" },
  { name = "ArcUI: OyanaUI ico full", file = "OyanaUI_ico_full.tga" },
  { name = "ArcUI: OyanaUI Info", file = "OyanaUI_Info.tga" },
  { name = "ArcUI: OyanaUI LFG", file = "OyanaUI_LFG.tga" },
  { name = "ArcUI: OyanaUI Party Indicator Large", file = "OyanaUI_Party_Indicator_Large.tga" },
  { name = "ArcUI: OyanaUI StatusFX Indicator Large", file = "OyanaUI_StatusFX_Indicator_Large.tga" },
  { name = "ArcUI: OyanaUI Warning", file = "OyanaUI_Warning.tga" },
  { name = "ArcUI: RPGCombo Border ACharge", file = "RPGCombo_Border_ACharge.tga" },
  { name = "ArcUI: RPGCombo Border ACharge Full", file = "RPGCombo_Border_ACharge_Full.tga" },
  { name = "ArcUI: RPGCombo Empty", file = "RPGCombo_Empty.tga" },
  { name = "ArcUI: RPGCombo Full", file = "RPGCombo_Full.tga" },
  { name = "ArcUI: RPG HUDCIRCLE", file = "RPG_HUDCIRCLE.tga" },
  { name = "ArcUI: RPG HUDCIRCLE AGONY", file = "RPG_HUDCIRCLE_AGONY.tga" },
  { name = "ArcUI: RPG HUDCIRCLE BUTTON", file = "RPG_HUDCIRCLE_BUTTON.tga" },
  { name = "ArcUI: RPG HUDCIRCLE CHARPANEL", file = "RPG_HUDCIRCLE_CHARPANEL.tga" },
  { name = "ArcUI: RPG HUDCIRCLE SKULL", file = "RPG_HUDCIRCLE_SKULL.tga" },
  { name = "ArcUI: RPG HUDCIRCLE SPELLBOOK", file = "RPG_HUDCIRCLE_SPELLBOOK.tga" },
  { name = "ArcUI: SoulFragment Full", file = "SoulFragment_Full.tga" },
  { name = "ArcUI: SpellHUD Agony", file = "SpellHUD_Agony.tga" },
  { name = "ArcUI: SpellHUD Axe", file = "SpellHUD_Axe.tga" },
  { name = "ArcUI: SpellHUD Bag", file = "SpellHUD_Bag.tga" },
  { name = "ArcUI: SpellHUD Blasphemy", file = "SpellHUD_Blasphemy.tga" },
  { name = "ArcUI: SpellHUD Chaos", file = "SpellHUD_Chaos.tga" },
  { name = "ArcUI: SpellHUD Corruption", file = "SpellHUD_Corruption.tga" },
  { name = "ArcUI: SpellHUD Demon", file = "SpellHUD_Demon.tga" },
  { name = "ArcUI: SpellHUD Demonbolt", file = "SpellHUD_Demonbolt.tga" },
  { name = "ArcUI: SpellHUD Demon Clean", file = "SpellHUD_Demon_Clean.tga" },
  { name = "ArcUI: SpellHUD Dreadstalker", file = "SpellHUD_Dreadstalker.tga" },
  { name = "ArcUI: SpellHUD Empty", file = "SpellHUD_Empty.tga" },
  { name = "ArcUI: SpellHUD Essence", file = "SpellHUD_Essence.tga" },
  { name = "ArcUI: SpellHUD Felguard", file = "SpellHUD_Felguard.tga" },
  { name = "ArcUI: SpellHUD FelguardAxe", file = "SpellHUD_FelguardAxe.tga" },
  { name = "ArcUI: SpellHUD Fire", file = "SpellHUD_Fire.tga" },
  { name = "ArcUI: SpellHUD Holy", file = "SpellHUD_Holy.tga" },
  { name = "ArcUI: SpellHUD Infernal", file = "SpellHUD_Infernal.tga" },
  { name = "ArcUI: SpellHUD Murloc", file = "SpellHUD_Murloc.tga" },
  { name = "ArcUI: SpellHUD Nature", file = "SpellHUD_Nature.tga" },
  { name = "ArcUI: SpellHUD Observer", file = "SpellHUD_Observer.tga" },
  { name = "ArcUI: SpellHUD Physical", file = "SpellHUD_Physical.tga" },
  { name = "ArcUI: SpellHUD Shadow", file = "SpellHUD_Shadow.tga" },
  { name = "ArcUI: SpellHUD Shadowfiend", file = "SpellHUD_Shadowfiend.tga" },
  { name = "ArcUI: SpellHUD SWPAIN", file = "SpellHUD_SWPAIN.tga" },
  { name = "ArcUI: SpellHUD Tyrant", file = "SpellHUD_Tyrant.tga" },
  { name = "ArcUI: SpellHUD UnstableAffliction", file = "SpellHUD_UnstableAffliction.tga" },
  { name = "ArcUI: SpellHUD VAMPTOUCH", file = "SpellHUD_VAMPTOUCH.tga" },
  { name = "ArcUI: SpellHUD VileTaint", file = "SpellHUD_VileTaint.tga" },
  { name = "ArcUI: SpellHUD Water", file = "SpellHUD_Water.tga" },
  { name = "ArcUI: SpellHUD Wind", file = "SpellHUD_Wind.tga" },
  { name = "ArcUI: SSRPG Empty", file = "SSRPG_Empty.tga" },
  { name = "ArcUI: SSRPG Full", file = "SSRPG_Full.tga" },
  { name = "ArcUI: SS Empty", file = "SS_Empty.tga" },
  { name = "ArcUI: SS Empty Bar", file = "SS_Empty_Bar.tga" },
  { name = "ArcUI: SS Full", file = "SS_Full.tga" },
  { name = "ArcUI: SS Full Bar", file = "SS_Full_Bar.tga" },
  { name = "ArcUI: URune Full", file = "URune_Full.tga" },
}

local COMMUNITY_FONTS = {
}

local function RegisterMedia()
  for _, entry in ipairs(COMMUNITY_TEXTURES) do
    LSM:Register(LSM.MediaType.STATUSBAR, entry.name, TEXTURE_PATH .. entry.file)
  end
  for _, entry in ipairs(COMMUNITY_FONTS) do
    LSM:Register(LSM.MediaType.FONT, entry.name, TEXTURE_PATH .. entry.file)
  end
end

RegisterMedia()

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addonName)
  if addonName == "ArcUI" then
    RegisterMedia()
    self:UnregisterAllEvents()
  end
end)
