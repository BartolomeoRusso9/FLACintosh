; Inno Setup installer for the self-contained MusicPlayerWin publish output.
; Build first with scripts/publish-win-x64.ps1, then run:
;   ISCC.exe installer\MusicPlayerWin.iss

#define AppName "MusicPlayerWin"
#define AppVersion "0.8.0"
#define AppPublisher "MusicPlayerWin"
#define AppExeName "MusicPlayerWin.App.exe"
#define PublishDir "..\\artifacts\\win-x64"

[Setup]
AppId={{A4DE9D77-0B09-4DA7-9D51-1F0A9F5B7E4A}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\MusicPlayerWin
DefaultGroupName=MusicPlayerWin
OutputDir=..\artifacts\installer
OutputBaseFilename=MusicPlayerWin-{#AppVersion}-win-x64-setup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
UninstallDisplayIcon={app}\{#AppExeName}

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\MusicPlayerWin"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\MusicPlayerWin"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch MusicPlayerWin"; Flags: nowait postinstall skipifsilent
