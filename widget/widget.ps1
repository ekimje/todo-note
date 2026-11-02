# 할 일 달력 — 바탕화면 달력 위젯 (월간 / 일일 보기, 라이트 / 다크 테마)
# 데이터: 할 일 노트 API (기본 http://localhost:8080/api) — 웹·휴대폰과 같은 DB
#         서버에 닿지 않으면 마지막으로 받은 목록(todos-cache.json)을 읽기 전용으로 보여줌
# 설정:   settings.json  { api, theme: light|dark, mode: month|day, left/top/width/height }
#         API 주소는 환경변수 TODO_API_URL 이 우선
# ⚠ 이 파일은 UTF-8 BOM 으로 저장해야 함 (Windows PowerShell 5.1)

param(
    [string]$Snapshot,          # 확인용: 창 모습을 PNG로 저장하고 종료
    [switch]$SnapshotEditor,
    [ValidateSet('', 'light', 'dark')][string]$Theme = '',
    [ValidateSet('', 'month', 'day')][string]$Mode = '',
    [string]$Date = ''          # 확인용: 처음 보여줄 날짜 (yyyy-MM-dd)
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\TodoCalendarWidget', [ref]$created)
if (-not $created -and -not $Snapshot) { exit }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class TodoCalW32 {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
"@

$cachePath = Join-Path $PSScriptRoot 'todos-cache.json'
$setPath   = Join-Path $PSScriptRoot 'settings.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)

# ---------- 설정 ----------
$script:settings = @{ api = 'http://localhost:8080/api'; theme = 'light'; mode = 'month' }
if (Test-Path -LiteralPath $setPath) {
    try {
        $s0 = ConvertFrom-Json ([IO.File]::ReadAllText($setPath, [Text.Encoding]::UTF8))
        foreach ($p in $s0.PSObject.Properties) { $script:settings[$p.Name] = $p.Value }
    } catch {}
}
if ($script:settings.theme -notin 'light', 'dark') { $script:settings.theme = 'light' }
if ($script:settings.mode -notin 'month', 'day') { $script:settings.mode = 'month' }
if ($Theme) { $script:settings.theme = $Theme }
if ($Mode)  { $script:settings.mode = $Mode }

$script:apiBase = if ($env:TODO_API_URL) { $env:TODO_API_URL } else { [string]$script:settings.api }
$script:apiBase = $script:apiBase.TrimEnd('/')
$script:online = $false

function Save-Settings {
    if ($Snapshot) { return }
    $o = [ordered]@{}
    foreach ($k in $script:settings.Keys) { $o[$k] = $script:settings[$k] }
    try { [IO.File]::WriteAllText($setPath, (ConvertTo-Json $o), $utf8) } catch {}
}

# ---------- 테마 ----------
$SIZE = 378   # 10cm (96 DPI 기준)
$THEMES = @{
    light = @{
        Surface = '#EBFAFAF6'; Edge = '#80FFFFFF'; EditorBg = '#FAFAFAF6'
        Ink = '#1F2533'; Muted = '#7A8193'; Accent = '#2B4BB8'; AccentFg = '#FFFFFF'
        Sun = '#D04A3A'; Sat = '#3A64C8'; Line = '#1A1F2533'; OutMonth = '#661F2533'
        TodayCell = '#142B4BB8'; Chip = '#0F1F2533'; ChipOn = '#262B4BB8'; FieldLine = '#331F2533'
        Placeholder = '#991F2533'; Hover = '#0D1F2533'; DoneBg = '#263FA34D'; DoneFg = '#2E7D3B'
        Highlights = @('#99FFE34A', '#8094E86A', '#80FF9DC6', '#808CCBFF', '#80FFB25C')
        Marks      = @('#E0B800', '#3FA34D', '#E0508E', '#3D8BE0', '#E07B1F')
    }
    dark = @{
        Surface = '#EB161B26'; Edge = '#26FFFFFF'; EditorBg = '#FA161B26'
        Ink = '#E4E8F2'; Muted = '#8D95AB'; Accent = '#8AA4FF'; AccentFg = '#11151F'
        Sun = '#F08A76'; Sat = '#8AB0FF'; Line = '#1FFFFFFF'; OutMonth = '#55E4E8F2'
        TodayCell = '#268AA4FF'; Chip = '#1AFFFFFF'; ChipOn = '#408AA4FF'; FieldLine = '#40E4E8F2'
        Placeholder = '#80E4E8F2'; Hover = '#14FFFFFF'; DoneBg = '#337CC79A'; DoneFg = '#7CC79A'
        Highlights = @('#8CA88A00', '#8C2F8A4A', '#8CB03A72', '#8C2F6FC0', '#8CB8651A')
        Marks      = @('#F2CC3D', '#62C27A', '#F07AAE', '#6AA8F0', '#F29A4A')
    }
}
$BRUSH_KEYS = 'Surface', 'Edge', 'EditorBg', 'Ink', 'Muted', 'Accent', 'AccentFg', 'Chip', 'FieldLine', 'Placeholder', 'Sun'

$brushConv = New-Object System.Windows.Media.BrushConverter
function Brush($hex) { $b = $brushConv.ConvertFromString($hex); $b.Freeze(); return $b }

# ---------- 데이터 (API) ----------
function ToDate($s) {
    if ($s -is [DateTime]) { return $s.Date }
    [DateTime]::ParseExact(([string]$s).Substring(0, 10), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}
function ToStr($d)  { $d.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }

# 우선순위만 있는 할 일(웹에서 추가, 색 미지정)의 기본 형광펜 색
$PRI_COLOR = @{ high = 2; mid = 3; low = 1 }

# Windows PowerShell 5.1 의 Invoke-RestMethod 는 charset 없는 JSON 을 Latin-1 로 읽어 한글이 깨지므로
# 요청/응답 모두 UTF-8 로 직접 처리한다.
function Invoke-Api([string]$method, [string]$path, $body) {
    $req = [Net.HttpWebRequest]::Create($script:apiBase + $path)
    $req.Method = $method; $req.Timeout = 4000; $req.ReadWriteTimeout = 4000; $req.Accept = 'application/json'
    if ($null -ne $body) {
        $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $body -Depth 5 -Compress))
        $req.ContentType = 'application/json; charset=utf-8'; $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
    }
    try { $res = $req.GetResponse() }
    catch [Net.WebException] {
        $msg = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream(), [Text.Encoding]::UTF8)
                $d = (ConvertFrom-Json $sr.ReadToEnd()).detail; if ($d -is [string]) { $msg = $d }
            } catch {}
        }
        throw $msg
    }
    $sr = New-Object IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd(); $res.Close()
    if ($text.Trim()) { return ConvertFrom-Json $text } else { return $null }
}

# API 의 할 일 → 달력 항목 (start ~ end). 마감일 없는 할 일은 달력에 놓을 자리가 없어 제외
function Convert-Todo($t) {
    if (-not $t.due) { return $null }
    $end = ToStr (ToDate $t.due)
    $start = if ($t.start) { ToStr (ToDate $t.start) } else { $end }
    $color = if ($null -ne $t.color) { [int]$t.color } elseif ($PRI_COLOR.ContainsKey([string]$t.priority)) { $PRI_COLOR[[string]$t.priority] } else { 3 }
    [pscustomobject]@{ id = [string]$t.id; text = [string]$t.text; start = $start; end = $end; done = [bool]$t.done; color = $color }
}

function Load-Data {
    $list = New-Object System.Collections.ArrayList
    try {
        $todos = Invoke-Api 'GET' '/todos' $null
        foreach ($t in @($todos)) { $c = Convert-Todo $t; if ($c) { [void]$list.Add($c) } }
        $script:online = $true
        $json = if ($list.Count) { ConvertTo-Json -InputObject @($list.ToArray()) -Depth 5 } else { '[]' }
        try { [IO.File]::WriteAllText($cachePath, $json, $utf8) } catch {}
    } catch {
        $script:online = $false
        if (Test-Path -LiteralPath $cachePath) {
            try {
                $raw = [IO.File]::ReadAllText($cachePath, [Text.Encoding]::UTF8)
                if ($raw.Trim()) { (ConvertFrom-Json $raw) | ForEach-Object { [void]$list.Add($_) } }
            } catch {}
        }
    }
    $script:items = $list
}

# 편집기 내용을 서버에 저장. 실패하면 오류 문구를 돌려줌
function Save-Item($id, $text, $start, $end, $done, $color) {
    $s = if ($start -eq $end) { $null } else { ToStr $start }
    $body = @{ text = $text; start = $s; due = (ToStr $end); color = $color }
    try {
        if ($id) { $body.done = [bool]$done; [void](Invoke-Api 'PATCH' "/todos/$id" $body) }
        else { [void](Invoke-Api 'POST' '/todos' $body) }
        return $null
    } catch { return "저장하지 못했어요: $_" }
}

# 완료 표시만 바꾸기 (일일 보기의 체크 상자)
function Set-Done($id, [bool]$done) {
    try { [void](Invoke-Api 'PATCH' "/todos/$id" @{ done = $done }); return $null }
    catch { return "저장하지 못했어요: $_" }
}

# ---------- 창 ----------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="할 일 달력" Width="$SIZE" Height="$SIZE" MinWidth="300" MinHeight="340" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="Manual" FontFamily="Malgun Gothic" Foreground="{DynamicResource Ink}">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="Padding" Value="8,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Chip" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{DynamicResource Chip}"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="2,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Step" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Padding" Value="6,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Head" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="6,2"/>
      <Setter Property="Margin" Value="1,0"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="line" BorderThickness="0,0,0,1.5" BorderBrush="{DynamicResource FieldLine}" Padding="0,2,0,6">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="line" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border CornerRadius="14" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" Padding="10">
    <Grid>
      <Grid x:Name="Main">
        <Grid.RowDefinitions>
          <RowDefinition Height="26"/>
          <RowDefinition Height="16"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid x:Name="Header" Background="Transparent">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="PrevBtn" Content="‹" FontSize="16"/>
          <TextBlock x:Name="MonthLabel" Grid.Column="1" FontSize="14" FontWeight="Bold" HorizontalAlignment="Center"
                     VerticalAlignment="Center" Cursor="Hand"/>
          <Button x:Name="NextBtn" Grid.Column="2" Content="›" FontSize="16"/>
          <Button x:Name="ModeBtn" Grid.Column="3" Style="{StaticResource Head}"/>
          <Button x:Name="ThemeBtn" Grid.Column="4" Style="{StaticResource Head}"/>
          <Button x:Name="AddBtn" Grid.Column="5" Content="+" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource Accent}" ToolTip="일정 추가"/>
        </Grid>
        <UniformGrid x:Name="WeekdayRow" Grid.Row="1" Columns="7"/>
        <Grid x:Name="Weeks" Grid.Row="2"/>
        <Grid x:Name="DayView" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed" Margin="0,4,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="DaySummary" FontSize="11" Foreground="{DynamicResource Muted}" Margin="4,0,0,6"/>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="DayList"/>
          </ScrollViewer>
        </Grid>
      </Grid>

      <Thumb x:Name="ResizeGrip" Width="16" Height="16" HorizontalAlignment="Right" VerticalAlignment="Bottom"
             Margin="0,0,-8,-8" Cursor="SizeNWSE" ToolTip="끌어서 크기 조절">
        <Thumb.Template>
          <ControlTemplate TargetType="Thumb">
            <Grid Background="Transparent">
              <Path Data="M 13,5 L 5,13 M 13,9 L 9,13" Stroke="{DynamicResource Muted}" StrokeThickness="1.3"/>
            </Grid>
          </ControlTemplate>
        </Thumb.Template>
      </Thumb>

      <Border x:Name="Editor" Visibility="Collapsed" Margin="-10" CornerRadius="14" Background="{DynamicResource EditorBg}" Padding="18,14,18,16">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <Grid>
            <TextBlock x:Name="EditorTitle" FontSize="11" FontWeight="Bold" Foreground="{DynamicResource Muted}" VerticalAlignment="Center"/>
            <Button x:Name="CloseBtn" Content="✕" FontSize="11" Foreground="{DynamicResource Muted}" HorizontalAlignment="Right" Padding="6,2" ToolTip="닫기"/>
          </Grid>

          <Grid Grid.Row="1" Margin="0,6,0,0">
            <TextBox x:Name="TextInput" Style="{StaticResource Field}" MaxLength="200"/>
            <TextBlock x:Name="Placeholder" Text="무엇을 할까요?" FontSize="17" Foreground="{DynamicResource Placeholder}"
                       Margin="2,4,0,0" IsHitTestVisible="False"/>
          </Grid>

          <Grid Grid.Row="2" Margin="0,16,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="34"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="30"/>
              <RowDefinition Height="30"/>
              <RowDefinition Height="32"/>
              <RowDefinition Height="30"/>
            </Grid.RowDefinitions>

            <TextBlock Text="시작" Style="{StaticResource Label}"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
              <Button x:Name="StartPrev" Content="‹" Style="{StaticResource Step}"/>
              <Button x:Name="StartChip" Style="{StaticResource Chip}" MinWidth="104" ToolTip="달력에서 고르기"/>
              <Button x:Name="StartNext" Content="›" Style="{StaticResource Step}"/>
            </StackPanel>

            <TextBlock Grid.Row="1" Text="종료" Style="{StaticResource Label}"/>
            <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal">
              <Button x:Name="EndPrev" Content="‹" Style="{StaticResource Step}"/>
              <Button x:Name="EndChip" Style="{StaticResource Chip}" MinWidth="104" ToolTip="달력에서 고르기"/>
              <Button x:Name="EndNext" Content="›" Style="{StaticResource Step}"/>
              <Border x:Name="DurBox" CornerRadius="3" Padding="7,1" Margin="8,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="DurText" FontSize="11" FontWeight="Bold"/>
              </Border>
            </StackPanel>

            <StackPanel x:Name="QuickRow" Grid.Row="2" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0"/>

            <TextBlock Grid.Row="3" Text="색" Style="{StaticResource Label}"/>
            <StackPanel x:Name="Swatches" Grid.Row="3" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0"/>
          </Grid>

          <TextBlock x:Name="ErrorText" Grid.Row="3" FontSize="11" Foreground="{DynamicResource Sun}" VerticalAlignment="Bottom"
                     TextWrapping="Wrap" Visibility="Collapsed"/>

          <Grid Grid.Row="4" Margin="0,10,0,0">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
              <Button x:Name="DoneBtn" Style="{StaticResource Chip}" Margin="0,0,6,0"/>
              <Button x:Name="DeleteBtn" Content="삭제" Foreground="{DynamicResource Sun}" FontSize="12"/>
            </StackPanel>
            <Button x:Name="SaveBtn" Content="저장" Background="{DynamicResource Accent}" Foreground="{DynamicResource AccentFg}" Padding="22,6"
                    FontSize="13" FontWeight="Bold" HorizontalAlignment="Right"/>
          </Grid>

          <Popup x:Name="DatePopup" StaysOpen="False" Placement="Bottom" AllowsTransparency="True">
            <Border Background="#FFFFFF" CornerRadius="10" BorderBrush="#1F1F2533" BorderThickness="1" Padding="4">
              <Calendar x:Name="PopupCal" BorderThickness="0" Background="Transparent"/>
            </Border>
          </Popup>
        </Grid>
      </Border>
    </Grid>
  </Border>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'Header','PrevBtn','NextBtn','ModeBtn','ThemeBtn','AddBtn','MonthLabel','WeekdayRow','Weeks','DayView','DaySummary','DayList',
               'Editor','EditorTitle','TextInput','Placeholder','CloseBtn','StartPrev','StartChip','StartNext','EndPrev','EndChip','EndNext',
               'DurBox','DurText','QuickRow','Swatches','DoneBtn','ErrorText','DeleteBtn','SaveBtn','DatePopup','PopupCal','ResizeGrip') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

# 테마 적용: XAML 의 DynamicResource 는 리소스를 바꾸면 바로 반영되고, 코드로 만든 칸은 Render 에서 다시 그림
function Apply-Theme {
    $script:C = $THEMES[$script:settings.theme]
    foreach ($k in $BRUSH_KEYS) { $window.Resources[$k] = Brush $script:C[$k] }
    $ThemeBtn.Content = if ($script:settings.theme -eq 'dark') { '라이트' } else { '다크' }
    $ThemeBtn.ToolTip = if ($script:settings.theme -eq 'dark') { '라이트 모드로' } else { '다크 모드로' }
    Build-WeekdayRow
}

function Build-WeekdayRow {
    $WeekdayRow.Children.Clear()
    $names = '일','월','화','수','목','금','토'
    for ($i = 0; $i -lt 7; $i++) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $names[$i]; $t.FontSize = 9; $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
        $t.Foreground = Brush $(if ($i -eq 0) { $script:C.Sun } elseif ($i -eq 6) { $script:C.Sat } else { $script:C.Muted })
        [void]$WeekdayRow.Children.Add($t)
    }
}

$script:today = (Get-Date).Date
$script:day   = if ($Date) { ToDate $Date } else { $script:today }   # 일일 보기에서 보는 날짜
$script:year  = $script:day.Year
$script:month = $script:day.Month
$ko = [Globalization.CultureInfo]::GetCultureInfo('ko-KR')
$inv = [Globalization.CultureInfo]::InvariantCulture

# ---------- 그리기 ----------
function New-Text($text, $size, $color) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.Foreground = Brush $color
    $t.TextTrimming = 'CharacterEllipsis'; $t.VerticalAlignment = 'Center'
    return $t
}

function Range-Text($es, $ee) {
    if ($ee -gt $es) { '{0} ~ {1}' -f $es.ToString('M/d', $inv), $ee.ToString('M/d', $inv) } else { $es.ToString('M/d', $inv) }
}

function Render {
    $script:today = (Get-Date).Date
    $isDay = $script:settings.mode -eq 'day'
    $ModeBtn.Content = if ($isDay) { '월간' } else { '일일' }
    $ModeBtn.ToolTip = if ($isDay) { '월간 달력으로 보기' } else { '하루 일정 목록으로 보기' }
    $PrevBtn.ToolTip = if ($isDay) { '전날' } else { '이전 달' }
    $NextBtn.ToolTip = if ($isDay) { '다음날' } else { '다음 달' }
    $WeekdayRow.Visibility = if ($isDay) { 'Collapsed' } else { 'Visible' }
    $Weeks.Visibility = if ($isDay) { 'Collapsed' } else { 'Visible' }
    $DayView.Visibility = if ($isDay) { 'Visible' } else { 'Collapsed' }
    if ($isDay) { Render-Day } else { Render-Month }
    if (-not $script:online) { $MonthLabel.Text += ' · 오프라인' }
    $MonthLabel.ToolTip = if ($script:online) { "동기화됨: $($script:apiBase)`n누르면 오늘로" } else { "서버에 연결할 수 없어 마지막으로 받은 일정을 보여줘요.`n$($script:apiBase)" }
}

function Render-Day {
    $d = $script:day
    $MonthLabel.Text = $d.ToString('M월 d일 (ddd)', $ko)
    if ($d -eq $script:today) { $MonthLabel.Text = '오늘 · ' + $MonthLabel.Text }
    $DayList.Children.Clear()

    $evs = @($script:items | Where-Object { (ToDate $_.start) -le $d -and (ToDate $_.end) -ge $d } |
        Sort-Object @{ Expression = { [bool]$_.done } }, @{ Expression = { $_.end } }, @{ Expression = { $_.start } })
    $doneN = @($evs | Where-Object { $_.done }).Count
    $DaySummary.Text = if ($evs.Count) { "할 일 $($evs.Count)개 · 완료 ${doneN}개" } else { '' }

    if (-not $evs.Count) {
        $empty = New-Text '이 날은 일정이 없어요.  + 로 추가하세요.' 12 $script:C.Muted
        $empty.Margin = '4,24,0,0'; $empty.HorizontalAlignment = 'Center'
        [void]$DayList.Children.Add($empty)
        return
    }

    foreach ($ev in $evs) {
        $es = ToDate $ev.start; $ee = ToDate $ev.end
        $ci = [int]$ev.color % $script:C.Marks.Count

        $row = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto', '*') {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') } else { [Windows.GridLength]::Auto }
            $row.ColumnDefinitions.Add($cd)
        }

        # 완료 체크 상자
        $box = New-Object Windows.Controls.Border
        $box.Width = 18; $box.Height = 18; $box.CornerRadius = 5; $box.Margin = '2,0,10,0'; $box.Cursor = 'Hand'
        $box.BorderThickness = 1.5; $box.VerticalAlignment = 'Center'; $box.Tag = $ev.id
        $box.ToolTip = if ($ev.done) { '완료 취소' } else { '완료' }
        if ($ev.done) {
            $box.Background = Brush $script:C.Accent; $box.BorderBrush = Brush $script:C.Accent
            $tick = New-Text '✓' 11 $script:C.AccentFg; $tick.HorizontalAlignment = 'Center'; $tick.FontWeight = 'Bold'
            $box.Child = $tick
        } else {
            $box.Background = Brush '#00FFFFFF'; $box.BorderBrush = Brush $script:C.Muted
        }
        $box.Add_MouseLeftButtonUp({ param($s, $e)
            $e.Handled = $true
            $it = $script:items | Where-Object { $_.id -eq $s.Tag } | Select-Object -First 1
            if (-not $it -or -not $script:online) { return }
            $err = Set-Done $s.Tag (-not $it.done)
            if ($err) { $DaySummary.Text = $err } else { Load-Data; Render }
        })
        [void]$row.Children.Add($box)

        # 내용: 색 막대 + 제목 + 기간
        $body = New-Object Windows.Controls.Border
        $body.BorderThickness = '3,0,0,0'; $body.BorderBrush = Brush $script:C.Marks[$ci]; $body.Padding = '8,3,4,3'
        $body.CornerRadius = 3; $body.Cursor = 'Hand'; $body.Tag = $ev.id
        $body.Background = Brush $(if ($ee -gt $es) { $script:C.Highlights[$ci] } else { '#00FFFFFF' })
        if ($ev.done) { $body.Opacity = 0.55 }
        [Windows.Controls.Grid]::SetColumn($body, 1)
        $sp = New-Object Windows.Controls.StackPanel
        $title = New-Text $ev.text 13 $script:C.Ink
        if ($ev.done) { $title.TextDecorations = [Windows.TextDecorations]::Strikethrough; $title.Foreground = Brush $script:C.Muted }
        [void]$sp.Children.Add($title)
        if ($ee -gt $es) {
            $left = ($ee - $script:day).Days
            $sub = (Range-Text $es $ee) + $(if ($left -eq 0) { ' · 오늘 마감' } elseif ($left -gt 0) { " · ${left}일 남음" } else { '' })
            [void]$sp.Children.Add((New-Text $sub 10 $script:C.Muted))
        }
        $body.Child = $sp
        $body.Add_MouseLeftButtonUp({ param($s, $e) Open-Editor $s.Tag $null })
        [void]$row.Children.Add($body)

        $row.Margin = '0,0,0,6'
        [void]$DayList.Children.Add($row)
    }
}

function Render-Month {
    $T = $script:C
    $Weeks.Children.Clear(); $Weeks.RowDefinitions.Clear()
    $first = New-Object DateTime($script:year, $script:month, 1)
    $offset = [int]$first.DayOfWeek
    $gridStart = $first.AddDays(-$offset)
    $weekCount = [int][Math]::Ceiling(($offset + [DateTime]::DaysInMonth($script:year, $script:month)) / 7)
    $MonthLabel.Text = '{0}년 {1}월' -f $script:year, $script:month

    $rowH = ($window.Height - 22 - 26 - 16) / $weekCount
    $maxLanes = [int][Math]::Max(1, [Math]::Floor(($rowH - 17) / 14))

    for ($w = 0; $w -lt $weekCount; $w++) {
        $rd = New-Object Windows.Controls.RowDefinition
        $rd.Height = New-Object Windows.GridLength(1, 'Star')
        $Weeks.RowDefinitions.Add($rd)

        $wg = New-Object Windows.Controls.Grid
        for ($c = 0; $c -lt 7; $c++) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = New-Object Windows.GridLength(1, 'Star')
            $wg.ColumnDefinitions.Add($cd)
        }
        $heights = @(17) + (@(14) * $maxLanes)
        foreach ($h in $heights) {
            $r = New-Object Windows.Controls.RowDefinition; $r.Height = New-Object Windows.GridLength($h); $wg.RowDefinitions.Add($r)
        }
        $r = New-Object Windows.Controls.RowDefinition; $r.Height = New-Object Windows.GridLength(1, 'Star'); $wg.RowDefinitions.Add($r)

        $line = New-Object Windows.Controls.Border
        $line.BorderThickness = '0,1,0,0'; $line.BorderBrush = Brush $T.Line; $line.Child = $wg
        [Windows.Controls.Grid]::SetRow($line, $w)
        [void]$Weeks.Children.Add($line)

        $ws = $gridStart.AddDays(7 * $w)
        $we = $ws.AddDays(6)

        # 날짜 칸: 빈 곳을 누르면 그 날짜로 새 일정, 날짜 숫자를 누르면 그 날의 일일 보기
        for ($d = 0; $d -lt 7; $d++) {
            $date = $ws.AddDays($d)
            $cell = New-Object Windows.Controls.Border
            $cell.Background = Brush $(if ($date -eq $script:today) { $T.TodayCell } else { '#00FFFFFF' })
            $cell.CornerRadius = 4; $cell.Cursor = 'Hand'; $cell.Tag = (ToStr $date)
            [Windows.Controls.Grid]::SetColumn($cell, $d)
            [Windows.Controls.Grid]::SetRowSpan($cell, $heights.Count + 1)
            $cell.Add_MouseLeftButtonUp({ param($s, $e) Open-Editor $null $s.Tag })
            [void]$wg.Children.Add($cell)

            $inMonth = $date.Month -eq $script:month
            $color = if (-not $inMonth) { $T.OutMonth } elseif ($d -eq 0) { $T.Sun } elseif ($d -eq 6) { $T.Sat } else { $T.Ink }
            $num = New-Text ([string]$date.Day) 10 $color
            $holder = New-Object Windows.Controls.Border
            $holder.HorizontalAlignment = 'Left'; $holder.VerticalAlignment = 'Top'; $holder.Margin = '2,1,0,0'
            $holder.Padding = '3,0'; $holder.CornerRadius = 7; $holder.Cursor = 'Hand'; $holder.Tag = (ToStr $date)
            $holder.ToolTip = '이 날 일정 보기'; $holder.Child = $num
            if ($date -eq $script:today) {
                $num.Foreground = Brush $T.AccentFg; $num.FontWeight = 'Bold'; $holder.Background = Brush $T.Accent
            } else { $holder.Background = Brush '#00FFFFFF' }
            $holder.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Show-Day (ToDate $s.Tag) })
            [Windows.Controls.Grid]::SetColumn($holder, $d)
            [void]$wg.Children.Add($holder)
        }

        # 이번 주에 걸친 일정 배치
        $evs = @($script:items | Where-Object { (ToDate $_.start) -le $we -and (ToDate $_.end) -ge $ws } |
            Sort-Object @{ Expression = { $_.start } }, @{ Expression = { ((ToDate $_.end) - (ToDate $_.start)).Days }; Descending = $true })
        $occupied = @(); for ($l = 0; $l -lt $maxLanes; $l++) { $occupied += ,(New-Object bool[] 7) }
        $hidden = New-Object int[] 7
        $hiddenText = @{}

        foreach ($ev in $evs) {
            $es = ToDate $ev.start; $ee = ToDate $ev.end
            $s = if ($es -lt $ws) { $ws } else { $es }
            $e = if ($ee -gt $we) { $we } else { $ee }
            $c0 = ($s - $ws).Days; $c1 = ($e - $ws).Days

            $lane = -1
            for ($l = 0; $l -lt $maxLanes -and $lane -lt 0; $l++) {
                $free = $true
                for ($c = $c0; $c -le $c1; $c++) { if ($occupied[$l][$c]) { $free = $false } }
                if ($free) { $lane = $l }
            }
            if ($lane -lt 0) {
                for ($c = $c0; $c -le $c1; $c++) { $hidden[$c]++; $hiddenText[$c] += @($ev.text) }
                continue
            }
            for ($c = $c0; $c -le $c1; $c++) { $occupied[$lane][$c] = $true }

            $ci = [int]$ev.color % $T.Highlights.Count
            $label = New-Text $ev.text 9 $T.Ink
            $label.Margin = '3,0,2,0'
            if ($ev.done) { $label.TextDecorations = [Windows.TextDecorations]::Strikethrough; $label.Foreground = Brush $T.Muted }

            $box = New-Object Windows.Controls.Border
            $box.Child = $label; $box.Cursor = 'Hand'; $box.Tag = $ev.id
            $box.ToolTip = "$($ev.text)`n$(Range-Text $es $ee)" + $(if ($ev.done) { ' (완료)' } else { '' })
            if ($ee -gt $es) {
                # 여러 날 일정: 형광펜
                $box.Background = Brush $T.Highlights[$ci]
                $lr = if ($s -eq $es) { 3 } else { 0 }; $rr = if ($e -eq $ee) { 3 } else { 0 }
                $box.CornerRadius = New-Object Windows.CornerRadius($lr, $rr, $rr, $lr)
                $box.Margin = New-Object Windows.Thickness($(if ($s -eq $es) { 2 } else { 0 }), 1, $(if ($e -eq $ee) { 2 } else { 0 }), 1)
                if ($ev.done) { $box.Opacity = 0.45 }
            } else {
                # 하루 일정: 날짜 칸에 글씨로
                $box.Background = Brush '#00FFFFFF'
                $box.BorderBrush = Brush $T.Marks[$ci]; $box.BorderThickness = '2,0,0,0'
                $box.Margin = '3,1,1,1'
            }
            [Windows.Controls.Grid]::SetColumn($box, $c0)
            [Windows.Controls.Grid]::SetColumnSpan($box, $c1 - $c0 + 1)
            [Windows.Controls.Grid]::SetRow($box, $lane + 1)
            $box.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Open-Editor $s.Tag $null })
            [void]$wg.Children.Add($box)
        }

        for ($c = 0; $c -lt 7; $c++) {
            if ($hidden[$c] -gt 0) {
                $more = New-Text "+$($hidden[$c])" 9 $T.Muted
                $more.HorizontalAlignment = 'Right'; $more.Margin = '0,1,3,0'
                $more.ToolTip = ($hiddenText[$c] -join "`n")
                [Windows.Controls.Grid]::SetColumn($more, $c)
                [void]$wg.Children.Add($more)
            }
        }
    }
}

# ---------- 보기 / 테마 전환 ----------
function Set-Mode($m) { $script:settings.mode = $m; Save-Settings; Render }
function Show-Day($d) { $script:day = $d.Date; Set-Mode 'day' }
function Toggle-Mode {
    if ($script:settings.mode -eq 'day') {
        $script:year = $script:day.Year; $script:month = $script:day.Month; Set-Mode 'month'
    } else {
        # 보고 있던 달이 이번 달이면 오늘, 아니면 그 달 1일
        $script:day = if ($script:year -eq $script:today.Year -and $script:month -eq $script:today.Month) { $script:today }
                      else { New-Object DateTime($script:year, $script:month, 1) }
        Set-Mode 'day'
    }
}
function Toggle-Theme {
    $script:settings.theme = if ($script:settings.theme -eq 'dark') { 'light' } else { 'dark' }
    Save-Settings; Apply-Theme; Render; if ($Editor.Visibility -eq 'Visible') { Update-Editor }
}
$ModeBtn.Add_Click({ Toggle-Mode })
$ThemeBtn.Add_Click({ Toggle-Theme })

# ---------- 편집 ----------
$script:editId = $null
$script:delArmed = $false
$script:edStart = $script:today; $script:edEnd = $script:today; $script:edColor = 0; $script:edDone = $false
$script:popupFor = 'start'

# 빠른 기간 버튼
$script:quickBtns = @()
foreach ($q in @(@(1, '하루'), @(3, '3일'), @(7, '1주'), @(14, '2주'))) {
    $b = New-Object Windows.Controls.Button
    $b.Style = $window.FindResource('Chip'); $b.Content = $q[1]; $b.Tag = $q[0]; $b.FontSize = 11; $b.Padding = '9,3'
    $b.Add_Click({ param($s, $e) $script:edEnd = $script:edStart.AddDays([int]$s.Tag - 1); Update-Editor })
    [void]$QuickRow.Children.Add($b); $script:quickBtns += $b
}

# 형광펜 색 고르기
$script:swatchRings = @()
for ($i = 0; $i -lt 5; $i++) {
    $dot = New-Object Windows.Controls.Border
    $dot.Width = 16; $dot.Height = 16; $dot.CornerRadius = 8
    $ring = New-Object Windows.Controls.Border
    $ring.CornerRadius = 12; $ring.Padding = 2; $ring.BorderThickness = 2; $ring.Margin = '0,0,6,0'
    $ring.Child = $dot; $ring.Tag = $i; $ring.Cursor = 'Hand'; $ring.Background = Brush '#00FFFFFF'
    $ring.Add_MouseLeftButtonUp({ param($s, $e) $script:edColor = [int]$s.Tag; Update-Editor })
    [void]$Swatches.Children.Add($ring); $script:swatchRings += $ring
}

function Update-Editor {
    $T = $script:C
    $StartChip.Content = $script:edStart.ToString('M월 d일 (ddd)', $ko)
    $EndChip.Content = $script:edEnd.ToString('M월 d일 (ddd)', $ko)
    $days = ($script:edEnd - $script:edStart).Days + 1
    $DurText.Text = if ($days -eq 1) { '하루' } else { "${days}일" }
    $DurText.Foreground = Brush $T.Ink
    $DurBox.Background = Brush $T.Highlights[$script:edColor]
    foreach ($b in $script:quickBtns) {
        $on = [int]$b.Tag -eq $days
        $b.Background = Brush $(if ($on) { $T.ChipOn } else { $T.Chip })
        $b.Foreground = Brush $(if ($on) { $T.Accent } else { $T.Ink })
        $b.FontWeight = if ($on) { 'Bold' } else { 'Normal' }
    }
    foreach ($r in $script:swatchRings) {
        $r.Child.Background = Brush $T.Marks[[int]$r.Tag]
        $r.BorderBrush = Brush $(if ([int]$r.Tag -eq $script:edColor) { $T.Ink } else { '#00FFFFFF' })
    }
    $DoneBtn.Content = if ($script:edDone) { '✓ 완료됨' } else { '완료 표시' }
    $DoneBtn.Background = Brush $(if ($script:edDone) { $T.DoneBg } else { $T.Chip })
    $DoneBtn.Foreground = Brush $(if ($script:edDone) { $T.DoneFg } else { $T.Ink })
}

function Show-EditorError($msg) { $ErrorText.Text = $msg; $ErrorText.Visibility = 'Visible' }

function Open-Editor($id, $dateStr) {
    $script:editId = $id
    $script:delArmed = $false; $DeleteBtn.Content = '삭제'
    $ErrorText.Visibility = 'Collapsed'
    if ($id) {
        $it = $script:items | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $it) { return }
        $EditorTitle.Text = '일정 수정'
        $TextInput.Text = $it.text
        $script:edStart = ToDate $it.start; $script:edEnd = ToDate $it.end
        $script:edColor = [int]$it.color % 5; $script:edDone = [bool]$it.done
        $DoneBtn.Visibility = 'Visible'; $DeleteBtn.Visibility = 'Visible'
    } else {
        $EditorTitle.Text = '새 일정'
        $TextInput.Text = ''
        $script:edStart = if ($dateStr) { ToDate $dateStr } elseif ($script:settings.mode -eq 'day') { $script:day } else { $script:today }
        $script:edEnd = $script:edStart
        $script:edColor = $script:items.Count % 5; $script:edDone = $false
        $DoneBtn.Visibility = 'Collapsed'; $DeleteBtn.Visibility = 'Collapsed'
    }
    Update-Editor
    if (-not $script:online) { Show-EditorError '서버에 연결되지 않아 저장할 수 없어요.' }
    $Editor.Visibility = 'Visible'
    [void]$window.Activate()
    [void]$TextInput.Focus()
    $TextInput.CaretIndex = $TextInput.Text.Length
}

function Close-Editor { $DatePopup.IsOpen = $false; $Editor.Visibility = 'Collapsed'; Render }

function Save-Editor {
    $text = $TextInput.Text.Trim()
    if (-not $text) { Show-EditorError '할 일을 입력하세요.'; [void]$TextInput.Focus(); return }
    $err = Save-Item $script:editId $text $script:edStart $script:edEnd $script:edDone $script:edColor
    if ($err) { Show-EditorError $err; return }
    if (-not $script:editId) {
        $script:year = $script:edStart.Year; $script:month = $script:edStart.Month
        if ($script:settings.mode -eq 'day') { $script:day = $script:edStart }
    }
    Load-Data
    Close-Editor
}

# 시작일을 옮기면 기간은 그대로 따라감
function Move-Start($n) {
    $len = ($script:edEnd - $script:edStart).Days
    $script:edStart = $script:edStart.AddDays($n); $script:edEnd = $script:edStart.AddDays($len); Update-Editor
}
function Move-End($n) {
    $d = $script:edEnd.AddDays($n)
    if ($d -lt $script:edStart) { $d = $script:edStart }
    $script:edEnd = $d; Update-Editor
}
$StartPrev.Add_Click({ Move-Start -1 }); $StartNext.Add_Click({ Move-Start 1 })
$EndPrev.Add_Click({ Move-End -1 });     $EndNext.Add_Click({ Move-End 1 })
$StartChip.Add_MouseWheel({ param($s, $e) Move-Start $(if ($e.Delta -gt 0) { -1 } else { 1 }) })
$EndChip.Add_MouseWheel({ param($s, $e) Move-End $(if ($e.Delta -gt 0) { -1 } else { 1 }) })

function Open-DatePopup($which, $target) {
    $script:popupFor = $which
    $d = if ($which -eq 'start') { $script:edStart } else { $script:edEnd }
    $PopupCal.SelectedDate = $d; $PopupCal.DisplayDate = $d
    $DatePopup.PlacementTarget = $target; $DatePopup.IsOpen = $true
}
$StartChip.Add_Click({ Open-DatePopup 'start' $StartChip })
$EndChip.Add_Click({ Open-DatePopup 'end' $EndChip })
$PopupCal.Add_SelectedDatesChanged({
    if (-not $DatePopup.IsOpen -or -not $PopupCal.SelectedDate) { return }
    $d = $PopupCal.SelectedDate.Value.Date
    if ($script:popupFor -eq 'start') { Move-Start ($d - $script:edStart).Days }
    else { if ($d -lt $script:edStart) { $script:edStart = $d }; $script:edEnd = $d; Update-Editor }
    $DatePopup.IsOpen = $false
    [void][Windows.Input.Mouse]::Capture($null)
})

$DoneBtn.Add_Click({ $script:edDone = -not $script:edDone; Update-Editor })
$SaveBtn.Add_Click({ Save-Editor })
$CloseBtn.Add_Click({ Close-Editor })
$DeleteBtn.Add_Click({
    if (-not $script:delArmed) { $script:delArmed = $true; $DeleteBtn.Content = '한 번 더 누르면 삭제'; return }
    try { [void](Invoke-Api 'DELETE' "/todos/$($script:editId)" $null) }
    catch { if ("$_" -notmatch '찾을 수 없') { Show-EditorError "삭제하지 못했어요: $_"; return } }
    Load-Data
    Close-Editor
})
$TextInput.Add_TextChanged({
    $Placeholder.Visibility = if ($TextInput.Text) { 'Collapsed' } else { 'Visible' }
    if ($TextInput.Text) { $ErrorText.Visibility = 'Collapsed' }
})
$Editor.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'Return') { $e.Handled = $true; Save-Editor }
    elseif ($e.Key -eq 'Escape') { $e.Handled = $true; Close-Editor }
})

# ---------- 이동/조작 ----------
function Shift-View($n) {
    if ($script:settings.mode -eq 'day') {
        $script:day = $script:day.AddDays($n)
    } else {
        $d = (New-Object DateTime($script:year, $script:month, 1)).AddMonths($n)
        $script:year = $d.Year; $script:month = $d.Month
    }
    Render
}
function Go-Today {
    $script:day = (Get-Date).Date; $script:year = $script:day.Year; $script:month = $script:day.Month; Render
}
$PrevBtn.Add_Click({ Shift-View -1 })
$NextBtn.Add_Click({ Shift-View 1 })
$AddBtn.Add_Click({ Open-Editor $null $null })
$MonthLabel.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Go-Today })

function Save-Position {
    $script:settings.left = $window.Left; $script:settings.top = $window.Top
    $script:settings.width = $window.Width; $script:settings.height = $window.Height
    if (-not $env:TODO_API_URL) { $script:settings.api = $script:apiBase }
    Save-Settings
}
$Header.Add_MouseLeftButtonDown({ param($s, $e) if ($e.OriginalSource -is [Windows.Controls.Grid]) { $window.DragMove(); Save-Position } })

# 오른쪽 아래 모서리를 끌어 크기 조절
$ResizeGrip.Add_DragDelta({ param($s, $e)
    $window.Width = [Math]::Max($window.MinWidth, $window.Width + $e.HorizontalChange)
    $window.Height = [Math]::Max($window.MinHeight, $window.Height + $e.VerticalChange)
})
$ResizeGrip.Add_DragCompleted({ Save-Position })

# 크기가 바뀌면 칸에 들어갈 일정 줄 수를 다시 계산
$resizeTimer = New-Object Windows.Threading.DispatcherTimer
$resizeTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$resizeTimer.Add_Tick({ $resizeTimer.Stop(); if ($Editor.Visibility -ne 'Visible') { Render } })
$window.Add_SizeChanged({ $resizeTimer.Stop(); $resizeTimer.Start() })

$menu = New-Object Windows.Controls.ContextMenu
function Add-MenuItem($header, $action) {
    $mi = New-Object Windows.Controls.MenuItem; $mi.Header = $header; $mi.Add_Click($action); [void]$menu.Items.Add($mi)
}
Add-MenuItem '오늘로' { Go-Today }
Add-MenuItem '월간 / 일일 보기 전환' { Toggle-Mode }
Add-MenuItem '라이트 / 다크 모드 전환' { Toggle-Theme }
Add-MenuItem '지금 동기화' { Load-Data; Render }
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
Add-MenuItem '달력 닫기' { $window.Close() }
$window.ContextMenu = $menu

# 위치 복원 (기본: 화면 오른쪽 위)
$area = [Windows.SystemParameters]::WorkArea
$window.Left = $area.Right - $SIZE - 24; $window.Top = $area.Top + 24
try {
    $p = $script:settings; $vs = [Windows.SystemParameters]
    if ($null -ne $p.left -and $p.left -ge $vs::VirtualScreenLeft -and $p.left -lt ($vs::VirtualScreenLeft + $vs::VirtualScreenWidth - 40) -and
        $p.top -ge $vs::VirtualScreenTop -and $p.top -lt ($vs::VirtualScreenTop + $vs::VirtualScreenHeight - 40)) {
        $window.Left = $p.left; $window.Top = $p.top
    }
    if ($p.width -ge $window.MinWidth -and $p.width -le $vs::VirtualScreenWidth) { $window.Width = $p.width }
    if ($p.height -ge $window.MinHeight -and $p.height -le $vs::VirtualScreenHeight) { $window.Height = $p.height }
} catch {}

# 다른 창 뒤, 바탕화면 쪽에 머물기
function Send-Bottom {
    $h = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
    [void][TodoCalW32]::SetWindowPos($h, [IntPtr]1, 0, 0, 0, 0, 0x0013)
}
$window.Add_Loaded({
    Send-Bottom
    if ($Snapshot) {
        if ($SnapshotEditor) { Open-Editor $null $null }
        $window.UpdateLayout()
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth, [int]$window.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($window.Content)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
        $window.Close()
    }
})
$window.Add_Deactivated({ if ($Editor.Visibility -ne 'Visible') { Send-Bottom } })

# 웹·휴대폰에서 바꾼 내용과 날짜 변경 반영 (편집 중에는 건너뜀)
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(30)
$timer.Add_Tick({
    if ($Editor.Visibility -eq 'Visible') { return }
    $now = (Get-Date).Date
    if ($now -ne $script:today -and $script:day -eq $script:today) { $script:day = $now }   # 자정이 지나면 오늘을 따라감
    Load-Data; Render
})
$timer.Start()

Apply-Theme
Load-Data
Render
[void]$window.ShowDialog()
if ($created) { $mutex.ReleaseMutex() }
