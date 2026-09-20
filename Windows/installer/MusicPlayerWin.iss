; Inno Setup installer for the self-contained FLACintosh publish output.
; Build first with scripts/publish-win-x64.ps1, then run:
;   ISCC.exe installer\MusicPlayerWin.iss

#define AppName "FLACintosh"
#define AppVersion "0.8.0"
#define AppPublisher "FLACintosh"
#define AppExeName "FLACintosh.exe"
#define PublishDir "..\\artifacts\\win-x64"

[Setup]
AppId={{A4DE9D77-0B09-4DA7-9D51-1F0A9F5B7E4A}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\FLACintosh
DefaultGroupName=FLACintosh
OutputDir=..\artifacts\installer
OutputBaseFilename=FLACintosh-{#AppVersion}-win-x64-setup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
UninstallDisplayIcon={app}\{#AppExeName}

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\FLACintosh"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\FLACintosh"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch MusicPlayerWin"; Flags: nowait postinstall skipifsilent
