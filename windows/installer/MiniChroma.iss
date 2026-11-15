; Inno Setup script for MiniChroma on Windows. Built by GitHub Actions; run ISCC.exe on it locally to test.
#define MyAppVersion "0.1.0"

[Setup]
AppId={{B3E7C1A2-5F4D-4C8E-9A61-7D2E0F3B9C11}
AppName=MiniChroma
AppVersion={#MyAppVersion}
AppPublisher=KMThegamer2022
DefaultDirName={autopf}\MiniChroma
DefaultGroupName=MiniChroma
OutputDir=..\installer-output
OutputBaseFilename=MiniChroma-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern

[Tasks]
Name: "startup"; Description: "Start MiniChroma when I sign in"; GroupDescription: "Options:"

[Files]
Source: "..\src\MiniChroma.Windows\publish\MiniChroma.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\scripts\agent-status.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\claude-hooks.json"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion isreadme

[Icons]
Name: "{group}\MiniChroma"; Filename: "{app}\MiniChroma.exe"
Name: "{group}\Uninstall MiniChroma"; Filename: "{uninstallexe}"
Name: "{userstartup}\MiniChroma"; Filename: "{app}\MiniChroma.exe"; Tasks: startup

[Run]
Filename: "{app}\MiniChroma.exe"; Description: "Start MiniChroma now"; Flags: nowait postinstall skipifsilent

[Code]
// Checks for OpenRGB during setup. MiniChroma needs it, so tell the user what to do if it is missing.
function OpenRgbInstalled(): Boolean;
begin
  Result := FileExists(ExpandConstant('{pf}\OpenRGB\OpenRGB.exe'))
         or FileExists(ExpandConstant('{pf64}\OpenRGB\OpenRGB.exe'))
         or FileExists(ExpandConstant('{localappdata}\Programs\OpenRGB\OpenRGB.exe'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and (not OpenRgbInstalled()) then
    MsgBox('MiniChroma needs OpenRGB to control your keyboard.' + #13#10 + #13#10 +
           '1. Download OpenRGB from https://openrgb.org (free).' + #13#10 +
           '2. Open OpenRGB, go to Settings and turn on the SDK Server.' + #13#10 +
           '3. Start MiniChroma from the Start menu.', mbInformation, MB_OK);
end;
