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
#ifdef SmokeTest
DefaultGroupName=easypub-lvy installer smoke
#else
DefaultGroupName=easypub-lvy
#endif
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
FinishedLabel=安装完成。已有书库、设置和用户安装的插件会继续保留。%n%n如果勾选了书源插件，请进入软件的“插件”页启用并确认权限。已有插件不会被覆盖。
ConfirmUninstall=确定卸载 %1？书库、设置、书源和用户安装的插件数据将保留。

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked
Name: "booksource"; Description: "安装书源下载插件（可选，已有插件保留）"; GroupDescription: "可选插件："; Flags: unchecked

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "install_booksource.ps1"; Flags: dontcopy
Source: "{#BookSourceDir}\*"; DestDir: "{tmp}\booksource-payload"; Flags: ignoreversion recursesubdirs createallsubdirs uninsneveruninstall; Tasks: booksource

[Icons]
Name: "{group}\easypub-lvy"; Filename: "{app}\easypub_desktop.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\easypub-lvy"; Filename: "{app}\easypub_desktop.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\easypub_desktop.exe"; Description: "启动 easypub-lvy"; Flags: nowait postinstall skipifsilent

[Code]
var PluginInstallFailed: Boolean;
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

function InstallBookSource(CheckOnly: Boolean): Boolean;
var
  Args, LocalRoot: String;
  ExitCode: Integer;
  ErrorText: AnsiString;
begin
  ExtractTemporaryFile('install_booksource.ps1');
  LocalRoot := ExpandConstant('{localappdata}');
#ifdef SmokeTest
  LocalRoot := ExpandConstant('{param:TESTLOCAL|{localappdata}}');
#endif
  Args := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\install_booksource.ps1') + '" -LocalRoot "' + LocalRoot +
    '" -PayloadDirectory "' + ExpandConstant('{tmp}\booksource-payload') +
    '" -ErrorFile "' + ExpandConstant('{tmp}\booksource-error.txt') + '"';
  if CheckOnly then Args := Args + ' -CheckOnly';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Args, '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  Result := Result and (ExitCode = 0);
  if not Result then
    if LoadStringFromFile(ExpandConstant('{tmp}\booksource-error.txt'), ErrorText) then
      Log('Booksource: ' + UTF8Decode(ErrorText));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if InstalledRelease(ExpandConstant('{app}')) > {#Release} then
    Result := '该目录已经安装了更新的版本，请下载最新安装包，或选择另一个目录。';
  if (Result = '') and WizardIsTaskSelected('booksource') then
    if not InstallBookSource(True) then
      Result := '无法读取插件数据目录，或有未完成的数据迁移。请先打开软件处理，或取消勾选书源插件。';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('booksource') then
    if not InstallBookSource(False) then begin
      PluginInstallFailed := True;
      RaiseException('主程序已安装，但书源插件安装失败。请检查数据目录权限，或从软件插件页手动安装。');
    end;
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if PluginInstallFailed then Result := 10;
end;
