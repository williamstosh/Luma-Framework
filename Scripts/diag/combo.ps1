<#
.SYNOPSIS
  四海兄弟：最终版 —— 组件组合开关（诊断 Luma × RenoDX × OptiScaler 共存）

.DESCRIPTION
  只做「改名」，不删任何文件，因此每个状态都是幂等的、可来回切换。
  ReShade 只加载 *.addon / *.addon32 / *.addon64（证据：ReShade.log
  "Searching for add-ons (*.addon, *.addon64)"），且按文件名字母序加载
  （实测顺序：dlss5-bridge → Luma → renodx-dlss5 → renodx-mafiade），
  所以「改名」同时也是调整 addon 加载顺序的把手。

  组件与命名：
    Luma mod       启用 Luma-Mafia Definitive Edition.addon   禁用 ...addon.off   (遗留 ...addon1)
    RenoDX HDR     启用 renodx-mafiade.addon64                 禁用 ...addon64.off
    OptiScaler     启用 dxgi.dll                               禁用 dxgi.dll.off   (遗留 dxgi.dll1)
    NR bridge      启用 dlss5-bridge.addon64                   禁用 ...addon64.off  (遗留 ...addon641)
    NR (RenoDX)    启用 renodx-dlss5.addon64                   禁用 ...addon64.off  (遗留 ...addon641)

  已确证的背景（2026-10-04）：
    · Luma + RenoDX HDR + NR bridge + RenoDX NR 四件同开 = 实机跑通、零崩溃
    · 唯一的副作用是 Luma core.hpp:5290 的一次性 cbuffer 槽位断言（DEV 构建弹窗，
      注释明说「别人只是占着槽位、当前 pass 不用它的话通常没事」）⇒ 点「否」继续即可
    · ⛔ OptiScaler 的 NR 与 RenoDX DLSS5 NR 是两套注入器，文档记录为互冲，不要同开

.EXAMPLE
  .\combo.ps1 status                     # 只看当前状态 + OptiScaler 关键配置
  .\combo.ps1 luma+renodx+nr             # 刚跑通的那套（4 addon）
  .\combo.ps1 luma+renodx+opti           # 加 OptiScaler（XeFG + 它自己的 NR）
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'renodx-only', 'luma-only', 'luma+renodx', 'luma+renodx+nr', 'luma+renodx+opti', 'luma+renodx+opti+nr')]
    [string]$State = 'status',

    [string]$GameDir = 'F:\SteamLibrary\steamapps\common\Mafia Definitive Edition',
    [string]$RepoDir = 'D:\AiWorkSpace\luma-build'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 组件表：Enabled / Disabled / Legacy(=历史遗留的禁用名，仅用于归一化)
# ---------------------------------------------------------------------------
$components = @(
    [pscustomobject]@{ Name = 'Luma mod';     Enabled = 'Luma-Mafia Definitive Edition.addon'; Disabled = 'Luma-Mafia Definitive Edition.addon.off'; Legacy = @('Luma-Mafia Definitive Edition.addon1') }
    [pscustomobject]@{ Name = 'RenoDX HDR';   Enabled = 'renodx-mafiade.addon64';               Disabled = 'renodx-mafiade.addon64.off';               Legacy = @() }
    [pscustomobject]@{ Name = 'OptiScaler';   Enabled = 'dxgi.dll';                            Disabled = 'dxgi.dll.off';                             Legacy = @('dxgi.dll1') }
    [pscustomobject]@{ Name = 'NR bridge';    Enabled = 'dlss5-bridge.addon64';                Disabled = 'dlss5-bridge.addon64.off';                 Legacy = @('dlss5-bridge.addon641') }
    [pscustomobject]@{ Name = 'NR (RenoDX)';  Enabled = 'renodx-dlss5.addon64';                Disabled = 'renodx-dlss5.addon64.off';                 Legacy = @('renodx-dlss5.addon641') }
)

# 必须始终禁用（Graphics Analyzer 会污染采集/影响性能）
$mustBeOff = @(
    'Luma-Graphics Analyzer.addon',
    'Luma-Graphics Analyzer.addon64'
)
# 必须始终在（ReShade 宿主）
$mustBeOn = @('d3d11.dll')

$states = @{
    'renodx-only'         = @{ 'Luma mod' = $false; 'RenoDX HDR' = $true;  'OptiScaler' = $false; 'NR bridge' = $false; 'NR (RenoDX)' = $false }
    'luma-only'           = @{ 'Luma mod' = $true;  'RenoDX HDR' = $false; 'OptiScaler' = $false; 'NR bridge' = $false; 'NR (RenoDX)' = $false }
    'luma+renodx'         = @{ 'Luma mod' = $true;  'RenoDX HDR' = $true;  'OptiScaler' = $false; 'NR bridge' = $false; 'NR (RenoDX)' = $false }
    'luma+renodx+nr'      = @{ 'Luma mod' = $true;  'RenoDX HDR' = $true;  'OptiScaler' = $false; 'NR bridge' = $true;  'NR (RenoDX)' = $true  }
    'luma+renodx+opti'    = @{ 'Luma mod' = $true;  'RenoDX HDR' = $true;  'OptiScaler' = $true;  'NR bridge' = $false; 'NR (RenoDX)' = $false }
    'luma+renodx+opti+nr' = @{ 'Luma mod' = $true;  'RenoDX HDR' = $true;  'OptiScaler' = $true;  'NR bridge' = $true;  'NR (RenoDX)' = $true  }
}

function Get-LoadedState {
    <# 返回：组件 -> 是否已启用（Enabled 文件名存在即视为启用）+ 实际文件信息 #>
    $result = [ordered]@{}
    foreach ($c in $components) {
        $onPath = Join-Path $GameDir $c.Enabled
        $offCandidates = @($c.Disabled) + $c.Legacy | ForEach-Object { Join-Path $GameDir $_ }
        $on = Test-Path $onPath
        $file = if ($on) { Get-Item $onPath } else { $offCandidates | Where-Object { Test-Path $_ } | ForEach-Object { Get-Item $_ } | Select-Object -First 1 }
        $result[$c.Name] = [pscustomobject]@{
            On     = $on
            File   = if ($file) { $file.Name } else { '(缺失)' }
            Size   = if ($file) { $file.Length } else { 0 }
            MTime  = if ($file) { $file.LastWriteTime.ToString('MM-dd HH:mm') } else { '-' }
        }
    }
    return $result
}

function Get-IniKey([string]$Path, [string]$Section, [string]$Key) {
    <# 取 ini 里指定 section 下第一个 Key = value 的值（找不到返回 $null） #>
    if (-not (Test-Path $Path)) { return $null }
    $inSection = $false
    foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*\[') { $inSection = ($line -match ('^\s*\[' + [regex]::Escape($Section) + '\]')); continue }
        if ($inSection -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.+?)\s*$')) { return $Matches[1] }
    }
    return $null
}

function Show-Status {
    $st = Get-LoadedState
    Write-Host ''
    Write-Host '=== 当前组合 ===' -ForegroundColor Cyan
    $st.Keys | ForEach-Object {
        $v = $st[$_]
        $tag = if ($v.On) { 'ON ' } else { 'off' }
        $clr = if ($v.On) { 'Green' } else { 'DarkGray' }
        Write-Host ("  [{0}] {1,-12} {2,-45} {3,10:N0} B  {4}" -f $tag, $_, $v.File, $v.Size, $v.MTime) -ForegroundColor $clr
    }

    $host_ok = Test-Path (Join-Path $GameDir 'd3d11.dll')
    Write-Host ''
    Write-Host ("  [宿主] d3d11.dll (Luma ReShade) : " + $(if ($host_ok) { 'OK' } else { '!!! 缺失，ReShade/addon 都不会加载' })) -ForegroundColor $(if ($host_ok) { 'Green' } else { 'Red' })

    # 只认「后缀恰好是 .addon/.addon64」的名字才真的会被加载
    $bad = @()
    foreach ($n in $mustBeOff) { if (Test-Path (Join-Path $GameDir $n)) { $bad += $n } }
    foreach ($f in Get-ChildItem $GameDir -File -ErrorAction SilentlyContinue) {
        if ($f.Extension -notin @('.addon', '.addon64', '.addon32')) { continue }
        if ($f.Name -match 'Graphics Analyzer') { $bad += ($f.Name + ' (会被加载!)') }
    }
    if ($bad.Count) { Write-Host ("  [警告] 应禁用的文件在加载列表里：" + ($bad -join ', ')) -ForegroundColor Yellow }
    else { Write-Host '  [检查] Graphics Analyzer：未加载 OK' -ForegroundColor Green }

    # OptiScaler 关键配置（每次跑之前值得核一眼）
    $ini = Join-Path $GameDir 'OptiScaler.ini'
    if (Test-Path $ini) {
        $up = Get-IniKey $ini 'Upscalers' 'Dx11Upscaler'
        $fgEn = Get-IniKey $ini 'FrameGen' 'Enabled'
        $fgOut = Get-IniKey $ini 'FrameGen' 'FGOutput'
        $fgCount = Get-IniKey $ini 'FrameGen' 'InterpolationCount'
        $nrEn = Get-IniKey $ini 'DlssNr' 'Enabled'
        $nrPasses = Get-IniKey $ini 'DlssNr' 'Passes'
        $nrRatio = Get-IniKey $ini 'DlssNr' 'MaxRatio'
        Write-Host ("  [OptiScaler.ini] Dx11Upscaler={0}  FG={1}/{2}/x{3}  DlssNr={4} Passes={5} MaxRatio={6}" -f $up, $fgEn, $fgOut, $fgCount, $nrEn, $nrPasses, $nrRatio) -ForegroundColor DarkGray

        # ⛔ 两套 NR 注入器不要同开
        $optiOn = $st['OptiScaler'].On
        $rnrOn = $st['NR (RenoDX)'].On
        if ($optiOn -and $rnrOn -and $nrEn -and ($nrEn -notmatch '^(false|0)$')) {
            Write-Host ("  [冲突] OptiScaler NR (DlssNr.Enabled=" + $nrEn + ") 与 RenoDX DLSS5 NR 同时启用：文档记录为互冲，建议只留一套") -ForegroundColor Red
        }
    }

    $trap = Join-Path $GameDir 'dxgi.dll.original'
    if ((Test-Path $trap) -and ((Get-Item $trap).Length -eq 0)) {
        Write-Host '  [陷阱] dxgi.dll.original 是 0 字节：若有人把它改回 dxgi.dll，游戏会加载空 DLL 直接崩。建议删除。' -ForegroundColor Yellow
    }
}

function Save-Snapshot([string]$Tag) {
    $dir = Join-Path $RepoDir 'logs\diag'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $out = Join-Path $dir ("state_{0}_{1}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Tag)
    $st = Get-LoadedState
    $lines = @("state=$Tag", "when=" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), '')
    foreach ($k in $st.Keys) {
        $v = $st[$k]
        $p = Join-Path $GameDir $v.File
        $hash = if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash.Substring(0, 16) } else { '-' }
        $lines += ("{0,-12} {1,-3} {2,-45} {3,10} {4} sha256={5}" -f $k, $(if ($v.On) { 'ON' } else { 'off' }), $v.File, $v.Size, $v.MTime, $hash)
    }
    $lines += ('d3d11.dll present=' + (Test-Path (Join-Path $GameDir 'd3d11.dll')))
    $lines | Set-Content -Path $out -Encoding utf8
    Write-Host ("  [快照] " + $out) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if (-not (Test-Path $GameDir)) { throw "游戏目录不存在：$GameDir" }

$proc = Get-Process -Name 'mafiadefinitiveedition' -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host ("游戏正在运行（PID " + ($proc.Id -join ',') + "）—— 运行中改名会导致加载状态与目录不一致。") -ForegroundColor Red
    Write-Host '请先退出游戏再执行本脚本。' -ForegroundColor Red
    exit 1
}

if ($State -eq 'status') { Show-Status; exit 0 }

$want = $states[$State]
Write-Host ("=== 切换到 [" + $State + "] ===") -ForegroundColor Cyan

foreach ($c in $components) {
    $desired = $want[$c.Name]
    $onPath = Join-Path $GameDir $c.Enabled
    $offPath = Join-Path $GameDir $c.Disabled
    $exists = Test-Path $onPath

    if ($desired -and -not $exists) {
        # 候选必须 >1KB（排除 0 字节的 dxgi.dll.original 之类）
        $cand = @($c.Disabled) + $c.Legacy |
            ForEach-Object { Join-Path $GameDir $_ } |
            Where-Object { (Test-Path $_) -and ((Get-Item $_).Length -gt 1024) } |
            Select-Object -First 1
        if (-not $cand) { throw ("[$($c.Name)] 找不到可启用的文件（期望 $onPath，或候选 " + (@($c.Disabled) + $c.Legacy -join ', ') + "）") }
        Move-Item -Path $cand -Destination $onPath -Force
        Write-Host ("  [{0}] 启用  <- {1}" -f $c.Name, (Split-Path $cand -Leaf)) -ForegroundColor Green
    }
    elseif (-not $desired -and $exists) {
        Move-Item -Path $onPath -Destination $offPath -Force
        Write-Host ("  [{0}] 禁用  -> {1}" -f $c.Name, (Split-Path $offPath -Leaf)) -ForegroundColor DarkYellow
    }
    else {
        Write-Host ("  [{0}] 已是目标状态（{1}）" -f $c.Name, $(if ($desired) { 'ON' } else { 'off' })) -ForegroundColor DarkGray
    }
}

Show-Status
Save-Snapshot $State
Write-Host ''
Write-Host '下一步：' -ForegroundColor Cyan
Write-Host '  1) 启动游戏，进主菜单再进游戏跑 30~60 秒（DEV 构建若弹 cbuffer 断言，点「否」继续）'
Write-Host ('  2) 退出游戏后执行： .\collect.ps1 -Label "{0}"' -f $State)
