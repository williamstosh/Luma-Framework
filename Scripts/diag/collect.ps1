<#
.SYNOPSIS
  四海兄弟：最终版 —— 一次诊断跑之后的证据采集与摘要

.DESCRIPTION
  1) 把本次运行的所有日志 + 配置 + 组件状态快照，复制到
     <RepoDir>\logs\diag\<yyyyMMdd-HHmmss>_<Label>\
  2) 抓 Windows 事件日志里这次运行的崩溃签名（故障模块 / 异常码 / 偏移）
  3) 抓 WER 报告（Report.wer 里含崩溃时刻的已加载模块清单 —— 用来确认是哪个 addon 在进程里）
  4) 在控制台打印一份「一眼能读」的摘要

.EXAMPLE
  .\collect.ps1 -Label luma+renodx
  .\collect.ps1 -Label luma+renodx -Minutes 30
#>
[CmdletBinding()]
param(
    [string]$Label = 'run',
    [int]$Minutes = 90,
    [string]$GameDir = 'F:\SteamLibrary\steamapps\common\Mafia Definitive Edition',
    [string]$RepoDir = 'D:\AiWorkSpace\luma-build'
)

$ErrorActionPreference = 'Continue'
$since = (Get-Date).AddMinutes(-$Minutes)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $RepoDir ("logs\diag\{0}_{1}" -f $stamp, $Label)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$werOut = Join-Path $outDir 'wer'
New-Item -ItemType Directory -Path $werOut -Force | Out-Null

Write-Host ("=== 采集到 " + $outDir + " ===") -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1) 日志与配置
# ---------------------------------------------------------------------------
$files = @(
    'ReShade.log', 'LumaMafiaDE-probe.log', 'dlss5-bridge.log', 'OptiScaler.log',
    'RenoDX-DLSS5-crash.log', 'renodx-mafiade.log', 'renodx.log',
    'ReShade.ini', 'OptiScaler.ini', 'dlss5-bridge.cfg'
)
$copied = @()
foreach ($f in $files) {
    $p = Join-Path $GameDir $f
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $outDir $f) -Force
        $it = Get-Item $p
        $copied += ("{0,-28} {1,10:N0} B  {2}" -f $f, $it.Length, $it.LastWriteTime.ToString('HH:mm:ss'))
    }
}
Write-Host '--- 已复制 ---' -ForegroundColor DarkGray
$copied | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor DarkGray }

# 2) 组件状态快照（复刻 combo.ps1 的逻辑，避免依赖它）
$comps = @(
    @{ N = 'Luma mod';   On = 'Luma-Mafia Definitive Edition.addon'; Off = @('Luma-Mafia Definitive Edition.addon.off', 'Luma-Mafia Definitive Edition.addon1') },
    @{ N = 'RenoDX';     On = 'renodx-mafiade.addon64';               Off = @('renodx-mafiade.addon64.off') },
    @{ N = 'OptiScaler'; On = 'dxgi.dll';                            Off = @('dxgi.dll.off', 'dxgi.dll1') }
)
$stateLines = @('组件状态（快照时刻）：')
foreach ($c in $comps) {
    $onP = Join-Path $GameDir $c.On
    $isOn = Test-Path $onP
    $offP = $c.Off | ForEach-Object { Join-Path $GameDir $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    $show = if ($isOn) { "$($c.On)  (ON)" } elseif ($offP) { (Split-Path $offP -Leaf) + '  (off)' } else { '(缺失)' }
    $stateLines += ("  {0,-11} {1}" -f $c.N, $show)
}
$stateLines += ("  {0,-11} {1}" -f 'd3d11.dll', $(if (Test-Path (Join-Path $GameDir 'd3d11.dll')) { 'OK（ReShade 宿主）' } else { '!!! 缺失' }))
$stateLines | Set-Content (Join-Path $outDir 'state.txt') -Encoding utf8
$stateLines | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 3) Windows 事件日志：崩溃签名
# ---------------------------------------------------------------------------
$evText = @()
$sig = @()
try {
    $evs = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -ErrorAction Stop |
        Where-Object { $_.Message -match 'mafiadefinitiveedition' }
    foreach ($e in $evs) {
        $evText += ("[{0}] provider={1} id={2}" -f $e.TimeCreated.ToString('MM-dd HH:mm:ss'), $e.ProviderName, $e.Id)
        $evText += $e.Message
        $evText += '---'
        $m = $e.Message -split "`r?`n" | Where-Object { $_ -match '出错模块名称|异常代码|错误偏移|Faulting module|Exception code|Fault offset' }
        if ($m) { $sig += ("  " + $e.TimeCreated.ToString('HH:mm:ss') + " : " + (($m -join ' | ') -replace '\s+', ' ')) }
    }
}
catch { $evText += "Get-WinEvent 失败：$_" }
$evText | Set-Content (Join-Path $outDir 'events.txt') -Encoding utf8

# ---------------------------------------------------------------------------
# 4) WER 报告（含崩溃时刻的模块清单）
# ---------------------------------------------------------------------------
$werRoots = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue'),
    'C:\ProgramData\Microsoft\Windows\WER\ReportArchive',
    'C:\ProgramData\Microsoft\Windows\WER\ReportQueue'
)
$werHits = @()
foreach ($root in $werRoots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $since -and ($_.Name -match 'mafiadefinitiveedition|AppCrash') } |
        ForEach-Object {
            $rep = Join-Path $_.FullName 'Report.wer'
            if (Test-Path $rep) {
                $dst = Join-Path $werOut ($_.Name + '.Report.wer')
                Copy-Item $rep $dst -Force
                $werHits += [pscustomobject]@{ Dir = $_.Name; Time = $_.LastWriteTime; Report = $dst }
            }
        }
}
foreach ($h in $werHits) {
    $txt = Get-Content $h.Report -Encoding utf8 -ErrorAction SilentlyContinue
    $fm = $txt | Where-Object { $_ -match '^(AppName|AppPath|ModName|ModVer|ExceptionCode|Offset|Sig\[)' } | Select-Object -First 12
    if ($fm) { $sig += ("  [WER " + $h.Time.ToString('HH:mm:ss') + "] " + (($fm -join ' | ') -replace '\s+', ' ')) }
}

# 5) 用户态转储（存在才记录，不复制大文件）
$dumps = @()
$dumpDir = Join-Path $env:LOCALAPPDATA 'CrashDumps'
if (Test-Path $dumpDir) {
    $dumps = Get-ChildItem $dumpDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $since -and $_.Name -match 'mafiadefinitiveedition' } |
        Select-Object Name, Length, LastWriteTime
}

# ---------------------------------------------------------------------------
# 6) 摘要
# ---------------------------------------------------------------------------
function Read-TailSafe([string]$path, [int]$n) {
    if (-not (Test-Path $path)) { return @() }
    return (Get-Content $path -Tail $n -ErrorAction SilentlyContinue)
}

Write-Host ''
Write-Host '================ 摘要 ================' -ForegroundColor Cyan

$rs = Join-Path $GameDir 'ReShade.log'
if (Test-Path $rs) {
    $lines = Get-Content $rs -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '[ReShade.log]' -ForegroundColor Yellow
    ($lines | Select-Object -First 1) | ForEach-Object { Write-Host ("  " + $_) }
    $lines | Where-Object { $_ -match 'Registered add-on|Loading add-on|Failed to load add-on' } | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Green }
    $errs = $lines | Where-Object { $_ -match '\| ERROR \||Failed|fatal|assert' -and $_ -notmatch 'SwapchainProxyPass' }
    Write-Host ("  错误/断言行数（排除 SwapchainProxyPass）: " + $errs.Count) -ForegroundColor $(if ($errs.Count) { 'Red' } else { 'DarkGray' })
    $errs | Select-Object -First 8 | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor Red }
    $proxy = ($lines | Where-Object { $_ -match '\[RenoDX\].*SwapchainProxyPass' }).Count
    Write-Host ("  RenoDX SwapchainProxyPass 警告数: " + $proxy) -ForegroundColor DarkYellow
    $clean = ($lines | Where-Object { $_ -match 'Unregistered add-on' }).Count
    Write-Host ("  正常退出标记(Unregistered add-on): " + $clean + $(if ($clean -gt 0) { '  ⇒ 不是崩溃退出' } else { '  ⇒ 没有正常退出，疑似崩溃/强制结束' })) -ForegroundColor $(if ($clean -gt 0) { 'Green' } else { 'Red' })
    Write-Host '  最后 6 行：' -ForegroundColor DarkGray
    Read-TailSafe $rs 6 | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkGray }
}

$pr = Join-Path $GameDir 'LumaMafiaDE-probe.log'
if (Test-Path $pr) {
    $pl = Get-Content $pr -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '[LumaMafiaDE-probe.log]' -ForegroundColor Yellow
    Write-Host ("  step 5/5 CoreMain 完成: " + (($pl | Where-Object { $_ -match 'step 5/5' }).Count))
    Write-Host ("  === SR hook 命中: " + (($pl | Where-Object { $_ -match '=== SR hook' }).Count))
    Write-Host ("  resolve hooked 统计行数: " + (($pl | Where-Object { $_ -match 'resolve hooked' }).Count))
    ($pl | Where-Object { $_ -match 'resolve hooked' } | Select-Object -Last 2) | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Green }
    Write-Host '  最后 8 行：' -ForegroundColor DarkGray
    Read-TailSafe $pr 8 | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ("[崩溃签名 · 最近 " + $Minutes + " 分钟]") -ForegroundColor Yellow
if ($sig.Count -eq 0) { Write-Host '  无（这个时间窗内没有 Application Error / WER 记录）' -ForegroundColor Green }
else { $sig | ForEach-Object { Write-Host $_ -ForegroundColor Red } }

if ($dumps.Count) {
    Write-Host ''
    Write-Host '[用户态转储]' -ForegroundColor Yellow
    $dumps | ForEach-Object { Write-Host ("  " + $_.Name + "  " + [math]::Round($_.Length / 1MB, 1) + " MB  " + $_.LastWriteTime.ToString('HH:mm:ss')) }
}

Write-Host ''
Write-Host ("采集完成：" + $outDir) -ForegroundColor Cyan
