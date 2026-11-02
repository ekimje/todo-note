# 할 일 노트 PC 설치판 빌드
#   powershell -NoProfile -ExecutionPolicy Bypass -File desktop\build.ps1
# 결과
#   desktop\dist\TodoNote\TodoNote.exe        설치 없이 바로 실행되는 폴더
#   desktop\dist\TodoNote-Setup-x.y.z.exe     설치 파일 (Inno Setup 6 이 있을 때)
$ErrorActionPreference = 'Stop'
$env:PYTHONUTF8 = '1'   # 한글 경로·주석을 CP949 로 읽지 않게
$here = $PSScriptRoot
$root = Split-Path $here -Parent
Set-Location $here

# 1) 빌드 전용 가상환경
$venv = Join-Path $here '.venv'
$py = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $py)) {
    Write-Host '== 가상환경 만들기'
    py -3 -m venv $venv
    if ($LASTEXITCODE) { python -m venv $venv }
}
& $py -m pip install --disable-pip-version-check -q -r (Join-Path $here 'requirements.txt')
if ($LASTEXITCODE) { throw 'pip install 실패' }

# 2) 아이콘
& $py (Join-Path $here 'make_icons.py')
if ($LASTEXITCODE) { throw '아이콘 생성 실패' }

# 3) PyInstaller (onedir: 시작이 빠르고 백신 오탐이 적음)
Write-Host '== PyInstaller'
$sep = ';'
& $py -m PyInstaller --noconfirm --clean --windowed `
    --name TodoNote `
    --icon (Join-Path $here 'build\icon.ico') `
    --distpath (Join-Path $here 'dist') `
    --workpath (Join-Path $here 'build\pyinstaller') `
    --specpath (Join-Path $here 'build') `
    --paths (Join-Path $root 'api') `
    --hidden-import app.main `
    --collect-submodules uvicorn `
    --exclude-module psycopg --exclude-module psycopg_pool `
    --add-data "$(Join-Path $root 'web\public')${sep}web" `
    --add-data "$(Join-Path $root 'widget\widget.ps1')${sep}widget" `
    --add-data "$(Join-Path $here 'build\icon.png')${sep}." `
    (Join-Path $here 'todo_desktop.py')
if ($LASTEXITCODE) { throw 'PyInstaller 실패' }
Write-Host "-> $(Join-Path $here 'dist\TodoNote\TodoNote.exe')"

# 4) 설치 파일 (Inno Setup 6)
$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    Write-Warning 'Inno Setup 6 이 없어 설치 파일은 건너뜀.  winget install JRSoftware.InnoSetup  후 다시 실행'
    exit 0
}
Write-Host '== Inno Setup'
& $iscc /Q (Join-Path $here 'installer.iss')
if ($LASTEXITCODE) { throw 'Inno Setup 실패' }
Get-ChildItem (Join-Path $here 'dist\TodoNote-Setup-*.exe') | ForEach-Object { Write-Host "-> $($_.FullName)" }
