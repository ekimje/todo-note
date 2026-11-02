# 위젯 ↔ API 동기화 테스트 (창을 띄우지 않음)
#   powershell -NoProfile -ExecutionPolicy Bypass -File widget\tests\sync-test.ps1
# widget.ps1 에서 데이터 함수만 꺼내 실행 중인 API 에 대해 검사하고, 만든 항목은 지운다.
param([string]$Api = $(if ($env:TODO_API_URL) { $env:TODO_API_URL } else { 'http://localhost:8080/api' }))
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot '..\widget.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $src), [ref]$null, [ref]$null)
$names = 'ToDate', 'ToStr', 'Invoke-Api', 'Convert-Todo', 'Load-Data', 'Save-Item', 'Set-Done'
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($names -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
$PRI_COLOR = @{ high = 2; mid = 3; low = 1 }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$cachePath = Join-Path ([IO.Path]::GetTempPath()) ("todo-widget-test-" + [guid]::NewGuid() + '.json')
$script:apiBase = $Api.TrimEnd('/')

$script:fail = 0; $script:pass = 0
function Check($name, $cond) {
    if ($cond) { $script:pass++; Write-Host "  ok   $name" }
    else { $script:fail++; Write-Host "  FAIL $name" -ForegroundColor Red }
}
function Find($id) { $script:items | Where-Object { $_.id -eq $id } | Select-Object -First 1 }

$ko = -join [char[]](0xD55C, 0xAE00, 0x0020, 0xC704, 0xC82F)   # '한글 위젯'
$ko2 = $ko + ' 2'
$created = @()
try {
    Write-Host "API: $script:apiBase"

    # 1. 새 기간 일정 저장 → 서버에서 다시 읽기
    $err = Save-Item $null $ko (ToDate '2026-11-20') (ToDate '2026-11-23') $false 2
    Check 'create range event' (-not $err)
    Load-Data
    Check 'online after load' $script:online
    $it = $script:items | Where-Object { $_.text -eq $ko } | Select-Object -First 1
    if ($it) { $created += $it.id }
    Check 'korean text round-trips' ($null -ne $it)
    Check 'range start/end' ($it.start -eq '2026-11-20' -and $it.end -eq '2026-11-23')
    Check 'color kept' ($it.color -eq 2)

    # 2. 수정: 하루 일정으로 + 완료 + 글자 변경
    $err = Save-Item $it.id $ko2 (ToDate '2026-11-21') (ToDate '2026-11-21') $true 4
    Check 'patch ok' (-not $err)
    Load-Data; $it2 = Find $it.id
    Check 'patched text' ($it2.text -eq $ko2)
    Check 'single day: start = end' ($it2.start -eq '2026-11-21' -and $it2.end -eq '2026-11-21')
    Check 'done flag' ($it2.done -eq $true)

    # 3. 서버 규칙 위반은 오류 문구로 돌아옴
    $err = Save-Item $it.id 'x' (ToDate '2026-11-25') (ToDate '2026-11-21') $false 0
    Check 'invalid range returns message' ([bool]$err)

    # 4. 웹에서 만든 할 일(색 없음, 우선순위 high) → 기본 색, 마감 없는 할 일은 달력 제외
    $web = Invoke-Api 'POST' '/todos' @{ text = 'web-high'; priority = 'high'; due = '2026-11-22' }
    $nodue = Invoke-Api 'POST' '/todos' @{ text = 'web-nodue' }
    $created += $web.id, $nodue.id
    Load-Data
    Check 'priority color fallback' ((Find $web.id).color -eq 2)
    Check 'no-due todo hidden from calendar' ($null -eq (Find $nodue.id))

    # 5. 일일 보기 체크 상자: 완료 표시만 바꾸고 나머지는 그대로
    Check 'set-done false' (-not (Set-Done $it.id $false))
    Load-Data; $it3 = Find $it.id
    Check 'done cleared' ($it3.done -eq $false -and $it3.text -eq $ko2 -and $it3.color -eq 4)
    Check 'set-done true' (-not (Set-Done $it.id $true))
    Load-Data
    Check 'done set' ((Find $it.id).done -eq $true)
    Check 'set-done unknown id returns message' ([bool](Set-Done ([guid]::NewGuid()) $true))

    # 6. 삭제
    [void](Invoke-Api 'DELETE' "/todos/$($it.id)" $null)
    Load-Data
    Check 'deleted' ($null -eq (Find $it.id))
    $created = $created | Where-Object { $_ -ne $it.id }

    # 7. 서버가 꺼졌을 때: 캐시로 표시 + 오프라인 표시
    $before = $script:items.Count
    $script:apiBase = 'http://127.0.0.1:9/api'
    Load-Data
    Check 'offline flag' (-not $script:online)
    Check 'offline shows cached items' ($script:items.Count -eq $before -and $before -gt 0)
    $err = Save-Item $null 'offline' (ToDate '2026-11-01') (ToDate '2026-11-01') $false 0
    Check 'offline save returns message' ([bool]$err)
}
finally {
    $script:apiBase = $Api.TrimEnd('/')
    foreach ($id in $created) { try { [void](Invoke-Api 'DELETE' "/todos/$id" $null) } catch {} }
    Remove-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
}

Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail) { exit 1 }
