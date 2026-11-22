; Aran — Inno Setup 6 script
;
; Built by scripts/package-windows.ps1, which passes:
;   /DMyAppVersion=<ver>  /DSourceDir=<staged portable dir>  /DOutputDir=<dist>
;
; Produces: aran-<ver>-windows-x64-setup.exe
; Per-user install into %LOCALAPPDATA%\Programs\Aran (no admin needed), which is
; what makes "install and it just works" possible without UAC on first run.

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\app\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

#define MyAppName "Aran"
#define MyAppPublisher "Aran"
#define MyAppExeName "aran_app.exe"

[Setup]
AppId={{6F1C0B4E-9C1A-4C1E-9B3B-1B5F0C7A2D31}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=aran-{#MyAppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-user install: no UAC prompt, no admin rights needed for the GUI itself.
; The optional system service and TUN still ask for elevation at runtime.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\{#MyAppExeName}
LicenseFile=..\..\LICENSE

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式:"
Name: "autostart"; Description: "登录时自动启动 Aran"; GroupDescription: "启动选项:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Licences (GPL-3.0 compliance for bundled mihomo / smartdns)
Source: "..\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}\licenses"; DestName: "ARAN-LICENSE"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop the kernel service if the user installed it, so no orphan process survives.
Filename: "{cmd}"; Parameters: "/c sc stop AranKernel >nul 2>&1 & sc delete AranKernel >nul 2>&1"; Flags: runhidden

[Code]
function InitializeSetup(): Boolean;
begin
  Result := True;
end;
