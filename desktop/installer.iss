; 할 일 노트 PC 설치 파일 (Inno Setup 6)
; build.ps1 이 PyInstaller 결과(desktop\dist\TodoNote) 를 만든 뒤 이 스크립트로 setup.exe 를 만든다.
; 관리자 권한 없이 사용자 폴더(%LOCALAPPDATA%\Programs\TodoNote)에 설치 — 위젯이 설정 파일을 옆에 쓸 수 있어야 함
; 데이터(%APPDATA%\TodoNote\todos.db)는 제거해도 남는다.

#define AppVersion "1.1.0"

[Setup]
AppId={{6F1C2E5A-4B7D-4E0B-9C3A-7A2D9E1F4B21}
AppName=할 일 노트
AppVersion={#AppVersion}
AppPublisher=할 일 노트
DefaultDirName={localappdata}\Programs\TodoNote
DefaultGroupName=할 일 노트
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=TodoNote-Setup-{#AppVersion}
SetupIconFile=build\icon.ico
UninstallDisplayIcon={app}\TodoNote.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[Tasks]
Name: "desktopicon"; Description: "바탕화면에 바로가기 만들기"; GroupDescription: "바로가기:"
Name: "startup"; Description: "Windows 로그인할 때 자동 실행 (트레이 + 달력 위젯)"; GroupDescription: "자동 실행:"

[Files]
Source: "dist\TodoNote\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\할 일 노트"; Filename: "{app}\TodoNote.exe"
Name: "{autodesktop}\할 일 노트"; Filename: "{app}\TodoNote.exe"; Tasks: desktopicon
Name: "{userstartup}\할 일 노트"; Filename: "{app}\TodoNote.exe"; Parameters: "--background"; Tasks: startup

[Run]
Filename: "{app}\TodoNote.exe"; Description: "할 일 노트 실행"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im TodoNote.exe"; Flags: runhidden; RunOnceId: "KillTodoNote"

[UninstallDelete]
; 위젯이 설치 폴더에 만든 창 위치·캐시 파일
Type: files; Name: "{app}\_internal\widget\settings.json"
Type: files; Name: "{app}\_internal\widget\todos-cache.json"
