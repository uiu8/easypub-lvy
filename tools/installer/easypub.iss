; 用已验收的便携包制作安装版，不重新构建或修改程序内容。
#ifndef PackageDir
  #error PackageDir is required
#endif
#ifndef Release
  #error Release is required
#endif
#ifndef OutputName
  #error OutputName is required
#endif

[Setup]
#ifdef SmokeTest
AppId=easypub-lvy-installer-smoke
AppName=easypub-lvy installer smoke
#else
AppId={{BEA8F550-7B3A-4CD8-9530-A9904978D26B}
AppName=easypub-lvy
#endif
AppVersion=测试版 {#Release}
AppVerName=easypub-lvy 测试版 {#Release}
VersionInfoVersion=0.0.{#Release}.0
AppPublisher=easypub-lvy
AppPublisherURL=https://github.com/uiu8/easypub-lvy
AppSupportURL=https://github.com/uiu8/easypub-lvy/issues
AppUpdatesURL=https://github.com/uiu8/easypub-lvy/releases/latest
DefaultDirName={localappdata}\Programs\easypub-lvy
DefaultGroupName=easypub-lvy
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
DisableProgramGroupPage=yes
DisableDirPage=no
UsePreviousAppDir=yes
UninstallDisplayIcon={app}\easypub_desktop.exe
OutputBaseFilename={#OutputName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
SetupLogging=yes
LicenseFile=..\..\LICENSE

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Messages]
FinishedLabel=安装完成。已有书库、设置和用户安装的插件会继续保留。%n%n书源下载插件独立提供，新用户可下载插件包，解压后在软件的“插件”页选择“从文件夹安装”，再启用。
ConfirmUninstall=确定卸载 %1？书库、设置、书源和用户安装的插件数据将保留。

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\easypub-lvy"; Filename: "{app}\easypub_desktop.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\easypub-lvy"; Filename: "{app}\easypub_desktop.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\easypub_desktop.exe"; Description: "启动 easypub-lvy"; Flags: nowait postinstall skipifsilent
Filename: "https://github.com/uiu8/easypub-lvy/releases/latest"; Description: "打开下载页，获取可选的书源插件"; Flags: shellexec postinstall skipifsilent unchecked

[Code]
// 自动更新写入 version.json。安装旧安装包时也读取它，避免覆盖较新的程序。
function InstalledRelease(const Directory: String): Integer;
var
  Text: AnsiString;
  Tail: String;
  Index, Count: Integer;
begin
  Result := 0;
  if not LoadStringFromFile(AddBackslash(Directory) + 'version.json', Text) then Exit;
  Tail := String(Text);
  Index := Pos('"release"', Tail);
  if Index = 0 then Exit;
  Delete(Tail, 1, Index + Length('"release"') - 1);
  Index := Pos(':', Tail);
  if Index = 0 then Exit;
  Tail := Trim(Copy(Tail, Index + 1, Length(Tail)));
  Count := 0;
  while Count < Length(Tail) do begin
    if (Tail[Count + 1] < '0') or (Tail[Count + 1] > '9') then Break;
    Count := Count + 1;
  end;
  Result := StrToIntDef(Copy(Tail, 1, Count), 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if InstalledRelease(ExpandConstant('{app}')) > {#Release} then
    Result := '该目录已经安装了更新的版本，请下载最新安装包，或选择另一个目录。';
end;
