@echo off
setlocal enabledelayedexpansion

echo ============================================
echo   ArcUI Custom Texture Generator
echo ============================================
echo.

:: Get the folder this .bat lives in (should be ArcUI addon root)
set "ADDON_DIR=%~dp0"
set "TEX_DIR=%ADDON_DIR%CustomTextures"
set "OUTPUT=%ADDON_DIR%ArcUI_CustomTextures.lua"

:: Create CustomTextures folder if missing
if not exist "%TEX_DIR%" (
    mkdir "%TEX_DIR%"
    echo Created CustomTextures folder.
)

:: Count files
set TEXCOUNT=0
set FONTCOUNT=0
for %%f in ("%TEX_DIR%\*.tga" "%TEX_DIR%\*.blp") do set /a TEXCOUNT+=1
for %%f in ("%TEX_DIR%\*.ttf" "%TEX_DIR%\*.otf") do set /a FONTCOUNT+=1

echo Found %TEXCOUNT% texture(s) and %FONTCOUNT% font(s) in CustomTextures\
echo.

:: Write the Lua file
(
echo -- ===================================================================
echo -- ArcUI_CustomTextures.lua ^(AUTO-GENERATED — do not edit manually^)
echo -- Run generate_textures.bat to rebuild after adding/removing files.
echo -- Share your textures in the ArcUI Discord to get them added!
echo -- ===================================================================
echo.
echo local LSM = LibStub and LibStub^("LibSharedMedia-3.0", true^)
echo if not LSM then return end
echo.
echo local TEXTURE_PATH = [[Interface\AddOns\ArcUI\CustomTextures\]]
echo.
echo local COMMUNITY_TEXTURES = {
) > "%OUTPUT%"

:: Add texture entries
for %%f in ("%TEX_DIR%\*.tga" "%TEX_DIR%\*.blp") do (
    set "FNAME=%%~nf"
    set "FULLNAME=%%~nxf"
    set "DISPLAY=!FNAME:_= !"
    echo   { name = "ArcUI: !DISPLAY!", file = "!FULLNAME!" },>> "%OUTPUT%"
)

echo }>> "%OUTPUT%"
echo.>> "%OUTPUT%"

:: Add font entries
echo local COMMUNITY_FONTS = {>> "%OUTPUT%"
for %%f in ("%TEX_DIR%\*.ttf" "%TEX_DIR%\*.otf") do (
    set "FNAME=%%~nf"
    set "FULLNAME=%%~nxf"
    set "DISPLAY=!FNAME:_= !"
    echo   { name = "ArcUI: !DISPLAY!", file = "!FULLNAME!" },>> "%OUTPUT%"
)
echo }>> "%OUTPUT%"

:: Add registration code
(
echo.
echo local function RegisterMedia^(^)
echo   for _, entry in ipairs^(COMMUNITY_TEXTURES^) do
echo     LSM:Register^(LSM.MediaType.STATUSBAR, entry.name, TEXTURE_PATH .. entry.file^)
echo   end
echo   for _, entry in ipairs^(COMMUNITY_FONTS^) do
echo     LSM:Register^(LSM.MediaType.FONT, entry.name, TEXTURE_PATH .. entry.file^)
echo   end
echo end
echo.
echo RegisterMedia^(^)
echo.
echo local loader = CreateFrame^("Frame"^)
echo loader:RegisterEvent^("ADDON_LOADED"^)
echo loader:SetScript^("OnEvent", function^(self, event, addonName^)
echo   if addonName == "ArcUI" then
echo     RegisterMedia^(^)
echo     self:UnregisterAllEvents^(^)
echo   end
echo end^)
) >> "%OUTPUT%"

echo.
echo Generated: ArcUI_CustomTextures.lua
echo   %TEXCOUNT% texture(s), %FONTCOUNT% font(s)
echo.
echo Done! You can close this window.
pause
