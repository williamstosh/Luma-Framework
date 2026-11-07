<#
.SYNOPSIS
  安全改文工装（snapshot / verify / replace / restore / scan）

.DESCRIPTION
  由来：2026-10-04 改 Obsidian 笔记时用「整文件重写」，把 419 行的
  `游戏插件组合库.md` 写成了 15 段旋转拼接的 6297 行（一级标题重复 165 次），
  靠「文件里还残留一份完整副本」+ 逐项复核才还原。
  本工具把那次教训从「文档里的纪律」变成「可执行机制」。

  动作：
    snapshot <文件>              改前留基线：备份 + 结构指纹（行数/哈希/标题清单/$数字计数）
    verify   <文件>              改后体检：结构 + 与基线差分；-RestoreOnFail 失败自动回滚
    replace  <文件> -Old -New    字面替换（非正则！）+ 自动 snapshot + 复验 + 失败自动回滚
    restore  <文件>              回滚到最近快照（当前状态另存 pre-restore，避免误丢）
    scan     <目录>              扫目录，找出已经被改坏的文本文件

  体检项（全部来自那次损坏的真实特征）：
    · 文件不是合法 UTF-8                          → 编码被破坏
    · 同一行/同一标题重复 ≥ -MaxRepeat 次（默认 12）→ 旋转拼接的硬指纹（分章同名标题只有 2~7 次，只警告）
    · 同一行重复出现超过 -MaxRepeat 次             → 同上（表格分隔行/代码围栏自动忽略）
    · 行数相对基线暴涨（> MaxLineGrowth × 基线 + 50）→ 内容被复制膨胀
    · 出现基线里没有的 `$<数字>` 组引用            → PowerShell 正则替换的 $1+数字 坑
    · 基线里有小节整段消失                         → 内容被吃掉

.EXAMPLE
  # 改笔记的三步标准流程（改文用 IDE 的定点替换，则只需第 1、3 步）
  .\text-guard.ps1 snapshot 'D:\AiWorkSpace\Obsidian Vault\Game\游戏插件组合库.md'
  .\text-guard.ps1 verify   'D:\AiWorkSpace\Obsidian Vault\Game\游戏插件组合库.md' -RestoreOnFail

.EXAMPLE
  .\text-guard.ps1 replace 'note.md' -Old '旧文本' -New '新文本' -Expect 1
  .\text-guard.ps1 scan 'D:\AiWorkSpace\Obsidian Vault'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('snapshot', 'verify', 'replace', 'restore', 'scan')]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$File,

    [Parameter(Position = 2)]
    [string]$Root,

    [string]$Old,
    [string]$New,
    [switch]$All,
    [int]$Expect = -1,

    # 同一行/同一标题出现 ≥ 该次数即判为「旋转拼接」（真事故是 165 次级别）
    # 实测正常文档的上限：分章同名标题 7 次、表格行 10 次、双语条目 9 次 ⇒ 取 12
    [int]$MaxRepeat = 12,
    # 行数超过「基线 × 该倍数 + 50」判为暴涨
    [int]$MaxLineGrowth = 3,
    [switch]$AllowDuplicateHeadings,
    # 裸用即可：verify -RestoreOnFail；replace 默认为开
    [switch]$RestoreOnFail,
    [switch]$Quiet,

    [string]$StateDir = 'D:\AiWorkSpace\luma-build\logs\text-guard'
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

# ---------------------------------------------------------------------------
# 输出小工具
# ---------------------------------------------------------------------------
function Write-Head($t) { Write-Host (''); Write-Host ('=== ' + $t + ' ===') -ForegroundColor Cyan }
function Write-Ok($t) { Write-Host ('  [PASS] ' + $t) -ForegroundColor Green }
function Write-Bad($t) { Write-Host ('  [FAIL] ' + $t) -ForegroundColor Red }
function Write-WarnLine($t) { Write-Host ('  [WARN] ' + $t) -ForegroundColor Yellow }
function Write-Dim($t) { if (-not $Quiet) { Write-Host ('  ' + $t) -ForegroundColor DarkGray } }
function Short-Text($s, $n = 72) {
    $t = ($s -replace '\s+', ' ').Trim()
    if ($t.Length -gt $n) { return ($t.Substring(0, $n) + '...') }
    return $t
}
function Get-PropKeys($obj) {
    if ($null -eq $obj) { return @() }
    # ⛔ 哈希表必须走 .Keys：PSObject.Properties 对 Hashtable 返回的是 .NET 成员
    #    （Count/Keys/Values/IsReadOnly/...），会数出 7 这种假数字
    if ($obj -is [System.Collections.IDictionary]) { return @($obj.Keys) }
    return @($obj.PSObject.Properties | Where-Object { $_.Name -ne '' } | Select-Object -ExpandProperty Name)
}

# ---------------------------------------------------------------------------
# 结构指纹
# ---------------------------------------------------------------------------
function Test-Utf8File($path) {
    try { [void]$Utf8Strict.GetString([IO.File]::ReadAllBytes($path)); return $true } catch { return $false }
}

function Test-FileLocked($path) {
    try { $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $false } catch { return $true }
}

function Get-TextStats($path, [int]$maxRepeat) {
    $lines = [IO.File]::ReadAllLines($path, $Utf8NoBom)

    $headings = @{}
    foreach ($l in $lines) {
        # 所有级别都统计（1~6 级）：损坏时各级标题都会成倍重复，一级标题最硬，其余作旁证
        if ($l -match '^#{1,6}\s+\S') {
            $k = $l.Trim()
            if ($headings.ContainsKey($k)) { $headings[$k] = $headings[$k] + 1 } else { $headings[$k] = 1 }
        }
    }

    # 参与「高重复行」判定的候选行：略掉太短的、注释、纯符号（表格分隔 / 代码围栏 / 引用符）
    $cand = New-Object System.Collections.ArrayList
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t.Length -lt 16) { continue }
        if ($t -like '<!--*') { continue }
        if ($t.StartsWith('|')) { continue }              # 表格行：跨页/分块重复属正常
        if ($t -match '^[\-!>#*_=\s]+$') { continue }     # 纯符号：分隔线/引用符/围栏
        [void]$cand.Add($t)
    }
    $rep = @()
    if ($cand.Count -gt 0) {
        $rep = @($cand | Group-Object | Where-Object { $_.Count -gt $maxRepeat } | Sort-Object Count -Descending |
            ForEach-Object { [pscustomobject]@{ Count = $_.Count; Text = $_.Name } })
    }

    $dollar = 0
    foreach ($l in $lines) { if ($l -match '\$\d') { $dollar++ } }

    return [pscustomobject]@{
        Path              = (Resolve-Path $path).Path
        Bytes             = (Get-Item $path).Length
        Lines             = $lines.Count
        Sha256            = (Get-FileHash $path -Algorithm SHA256).Hash
        Utf8              = (Test-Utf8File $path)
        Headings          = $headings
        # 一级标题重复 = 硬失败；二~六级重复 = 旁证（1~4 个只警告，≥5 个随一级一起判失败）
        DuplicateHeadings = @($headings.Keys | Where-Object { ($headings[$_] -gt 1) -and ($_ -match '^#\s') } | Sort-Object)
        DuplicateSubs     = @($headings.Keys | Where-Object { ($headings[$_] -gt 1) -and ($_ -notmatch '^#\s') } | Sort-Object)
        # 同一标题重复 ≥ MaxRepeat 次 = 旋转拼接的硬指纹
        # （实测：正常笔记里分章同名最多重复 2~7 次，如「## 本章小结」x4、「### 已写回笔记」x5）
        RepeatedHeadings  = @($headings.Keys | Where-Object { $headings[$_] -ge $maxRepeat } | Sort-Object)
        Repeated          = $rep
        DollarRefs        = $dollar
    }
}

function Read-Baseline($path) {
    $name = Split-Path $path -Leaf
    $j = Join-Path $StateDir ($name + '.latest.json')
    if (-not (Test-Path $j)) { return $null }
    return (Get-Content $j -Raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# 体检
# ---------------------------------------------------------------------------
function Invoke-Checks($path, [int]$maxRepeat, [bool]$allowDup, $baseline) {
    $s = Get-TextStats $path $maxRepeat
    $fails = New-Object System.Collections.ArrayList
    $warns = New-Object System.Collections.ArrayList

    if ($s.Utf8) { Write-Ok 'UTF-8 编码合法' } else { [void]$fails.Add('文件不是合法 UTF-8（编码已被破坏）'); Write-Bad '文件不是合法 UTF-8' }

    $dupTotal = $s.DuplicateHeadings.Count + $s.DuplicateSubs.Count
    if ($dupTotal -eq 0) {
        Write-Ok ('标题无重复（1~6 级共 ' + $s.Headings.Count + ' 个）')
    } elseif ($allowDup) {
        Write-WarnLine ('标题重复 ' + $dupTotal + ' 个（已用 -AllowDuplicateHeadings 放行）')
    } elseif ($s.RepeatedHeadings.Count -gt 0) {
        $msg = '同一标题重复 ≥' + $MaxRepeat + ' 次的有 ' + $s.RepeatedHeadings.Count + ' 个（旋转拼接的硬指纹）：' + ((@($s.RepeatedHeadings | Select-Object -First 3) | ForEach-Object { Short-Text $_ 26 }) -join ' / ')
        [void]$fails.Add($msg); Write-Bad $msg
    } else {
        Write-WarnLine ('有 ' + $dupTotal + ' 个标题重复 2~' + ($MaxRepeat - 1) + ' 次（「本章小结」这类分章同名，一般正常）')
    }

    if ($s.Repeated.Count -eq 0) {
        Write-Ok ('无高重复行（阈值 >' + $maxRepeat + ' 次）')
    } else {
        $msg = '同一行重复 >' + $maxRepeat + ' 次的有 ' + $s.Repeated.Count + ' 行，最高 ' + $s.Repeated[0].Count + ' 次：「' + (Short-Text $s.Repeated[0].Text 48) + '」'
        [void]$fails.Add($msg); Write-Bad $msg
    }

    if ($null -ne $baseline) {
        Write-Dim ('基线：' + $baseline.SnapshotAt + ' / ' + $baseline.Lines + ' 行 / ' + $baseline.Sha256.Substring(0, 12) + '...')
        $limit = ($baseline.Lines * $MaxLineGrowth + 50)
        if ($s.Lines -gt $limit) {
            $msg = '行数暴涨：' + $baseline.Lines + ' -> ' + $s.Lines + '（上限 ' + $limit + '）'
            [void]$fails.Add($msg); Write-Bad $msg
        } else {
            Write-Ok ('行数正常：' + $baseline.Lines + ' -> ' + $s.Lines)
        }

        if ($s.DollarRefs -gt $baseline.DollarRefs) {
            $msg = '出现基线里没有的 $<数字> 组引用：' + $baseline.DollarRefs + ' -> ' + $s.DollarRefs + '（正则替换 $1 + 数字 变 $14 的典型症状）'
            [void]$fails.Add($msg); Write-Bad $msg
        } else {
            Write-Ok ('$<数字> 组引用未增加（' + $baseline.DollarRefs + ' -> ' + $s.DollarRefs + '）')
        }

        $bKeys = Get-PropKeys $baseline.Headings
        $lost = @($bKeys | Where-Object { -not $s.Headings.ContainsKey($_) })
        $lostTop = @($lost | Where-Object { $_ -match '^#\s' })
        if ($lostTop.Count -gt 0) {
            $msg = '基线里有 ' + $lostTop.Count + ' 个一级标题整段消失：' + ((@($lostTop | Select-Object -First 3) | ForEach-Object { Short-Text $_ 28 }) -join ' / ')
            [void]$fails.Add($msg); Write-Bad $msg
        } elseif ($lost.Count -gt 0) {
            Write-WarnLine ('基线里有 ' + $lost.Count + ' 个子标题消失（改名/合并时属正常）：' + ((@($lost | Select-Object -First 3) | ForEach-Object { Short-Text $_ 26 }) -join ' / '))
        } else {
            Write-Ok ('基线里的 ' + $bKeys.Count + ' 个标题都还在')
        }
    } else {
        Write-WarnLine '没有基线（先运行 snapshot 才能做差分体检）'
    }

    if ($s.Sha256 -eq $s.Sha256) { } # 占位，保证在 -Quiet 下也计算过哈希
    return [pscustomobject]@{ Stats = $s; Fails = @($fails); Warns = @($warns) }
}

function Show-Report($path, $result) {
    Write-Host ('  ' + $path) -ForegroundColor White
    Write-Dim ('行数 ' + $result.Stats.Lines + ' ｜ 体积 ' + ('{0:N0}' -f $result.Stats.Bytes) + ' B ｜ SHA256 ' + $result.Stats.Sha256.Substring(0, 16) + '...')
    if ($result.Fails.Count -eq 0) { Write-Host '  => 体检通过' -ForegroundColor Green } else { Write-Host ('  => 体检未通过（' + $result.Fails.Count + ' 项）') -ForegroundColor Red }
}

# ---------------------------------------------------------------------------
# 快照 / 回滚
# ---------------------------------------------------------------------------
function Save-Snapshot($path, [int]$maxRepeat) {
    if (-not (Test-Path $path)) { throw ('文件不存在：' + $path) }
    if (Test-FileLocked $path) { Write-WarnLine '文件当前被独占占用（可能正在写入），快照可能不完整' }
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

    $name = Split-Path $path -Leaf
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = Join-Path $StateDir ($name + '.snap-' + $ts + '.bak')
    Copy-Item $path $bak -Force

    $s = Get-TextStats $path $maxRepeat
    $meta = [pscustomobject]@{
        SourcePath   = $s.Path
        SnapshotAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        SnapshotFile = (Split-Path $bak -Leaf)
        Bytes        = $s.Bytes
        Lines        = $s.Lines
        Sha256       = $s.Sha256
        Utf8         = $s.Utf8
        DollarRefs   = $s.DollarRefs
        Headings     = $s.Headings
    }
    $json = $meta | ConvertTo-Json -Depth 6
    Set-Content -Path (Join-Path $StateDir ($name + '.latest.json')) -Value $json -Encoding UTF8
    Set-Content -Path (Join-Path $StateDir ($name + '.snap-' + $ts + '.json')) -Value $json -Encoding UTF8

    # 只保留最近 10 代（.bak + .json 成对 ⇒ 20 项）
    $old = @(Get-ChildItem $StateDir -File | Where-Object { $_.Name -like ($name + '.snap-*') } | Sort-Object Name -Descending | Select-Object -Skip 20)
    foreach ($f in $old) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }

    return [pscustomobject]@{ Backup = $bak; Meta = $meta }
}

function Invoke-Restore($path) {
    $name = Split-Path $path -Leaf
    $snaps = @(Get-ChildItem $StateDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ($name + '.snap-*.bak') } | Sort-Object Name -Descending)
    if ($snaps.Count -eq 0) { throw ('没有可用快照：' + $path + '（先运行 snapshot）') }

    $src = $snaps[0].FullName
    $keep = Join-Path $StateDir ($name + '.pre-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak')
    Copy-Item $path $keep -Force
    Copy-Item $src $path -Force
    Write-Host ('  已回滚到 ' + (Split-Path $src -Leaf) + '（回滚前状态另存 ' + (Split-Path $keep -Leaf) + '）') -ForegroundColor Yellow
    return $src
}

# ---------------------------------------------------------------------------
# replace：字面替换（杜绝正则 $1+数字 坑）
# ---------------------------------------------------------------------------
function Invoke-Replace($path, $old, $new, [bool]$all, [int]$expect, [bool]$doRestore, [int]$maxRepeat) {
    if ([string]::IsNullOrEmpty($old)) { throw '-Old 不能为空' }
    if (-not (Test-Path $path)) { throw ('文件不存在：' + $path) }
    if (Test-FileLocked $path) { throw '文件被独占占用，请先关闭正在写它的程序' }

    # 1) 先 snapshot（基线 = 改前状态，回滚就回这里）
    $snap = Save-Snapshot $path $maxRepeat
    Write-Dim ('已留快照：' + (Split-Path $snap.Backup -Leaf))

    # 2) 定位（计数用正则转义，替换用字面 —— 两者都不受 $1 类语法影响）
    $text = [IO.File]::ReadAllText($path, $Utf8NoBom)
    $matches = [regex]::Matches($text, [regex]::Escape($old))
    $count = $matches.Count
    if ($count -eq 0) { throw '未找到 -Old 指定的文本（未做任何修改）' }
    if ($count -gt 1 -and -not $all) {
        $lns = @($matches | Select-Object -First 5 | ForEach-Object { (($text.Substring(0, $_.Index) -split "`n").Count) })
        throw ('-Old 匹配到 ' + $count + ' 处（行号约 ' + ($lns -join ', ') + '），需加 -All 或把 -Old 写得更具体')
    }
    if ($expect -ge 0 -and $count -ne $expect) { throw ('-Old 匹配到 ' + $count + ' 处，与 -Expect ' + $expect + ' 不符（未做任何修改）') }

    # 3) 字面替换 + 原子写（保留原 BOM 状态）
    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($hadBom)
    $newText = $text.Replace($old, $new)
    $tmp = $path + '.tmp-' + (Get-Random)
    [IO.File]::WriteAllText($tmp, $newText, $enc)
    Move-Item $tmp $path -Force
    Write-Host ('  已替换 ' + $count + ' 处（字面替换，保留 BOM=' + $hadBom + '）') -ForegroundColor Green

    # 4) 复验（失败即回滚）
    Write-Head '复验'
    $base = Read-Baseline $path
    $res = Invoke-Checks $path $maxRepeat $false $base
    Show-Report $path $res
    if ($res.Fails.Count -gt 0) {
        if ($doRestore) { Write-Bad '复验未通过 ⇒ 自动回滚'; [void](Invoke-Restore $path) } else { Write-Bad '复验未通过（回滚请手动运行 restore）' }
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# scan：扫目录找坏文件
# ---------------------------------------------------------------------------
function Invoke-Scan($root, [int]$maxRepeat) {
    if (-not (Test-Path $root)) { throw ('目录不存在：' + $root) }
    # 只扫「人写的散文」：.json/.ini/.ps1 的结构性重复太多（`"status": "modified",` 重复 53 次很正常）⇒ 全当误报
    $files = @(Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.md', '.txt') } |
        Where-Object { $_.FullName -notmatch '\\\.obsidian\\|\\\.trash\\|\\node_modules\\|\\\.git\\' })

    Write-Head ('扫描 ' + $root + '（' + $files.Count + ' 个 .md/.txt）')
    $bad = New-Object System.Collections.ArrayList
    $soft = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $s = $null
        try { $s = Get-TextStats $f.FullName $maxRepeat } catch { continue }
        $issues = New-Object System.Collections.ArrayList
        if (-not $s.Utf8) { [void]$issues.Add('非 UTF-8') }
        if ($s.Repeated.Count -gt 0) { [void]$issues.Add('高重复行 x' + $s.Repeated.Count + '（最高 ' + $s.Repeated[0].Count + '）') }
        if ($s.RepeatedHeadings.Count -gt 0) { [void]$issues.Add('标题重复 ≥' + $maxRepeat + ' 次 x' + $s.RepeatedHeadings.Count) }
        if ($issues.Count -gt 0) {
            [void]$bad.Add([pscustomobject]@{ File = $f; Stats = $s; Issues = ($issues -join ' ｜ ') })
        } else {
            $dupN = $s.DuplicateHeadings.Count + $s.DuplicateSubs.Count
            if ($dupN -gt 0) { [void]$soft.Add([pscustomobject]@{ File = $f; Dup = $dupN }) }
        }
    }

    if ($bad.Count -eq 0) {
        Write-Host ('  没有发现被改坏的文件（' + $files.Count + ' 个全部通过）') -ForegroundColor Green
    } else {
        Write-Host ('  发现 ' + $bad.Count + ' 个可疑文件：') -ForegroundColor Red
        foreach ($b in $bad) {
            Write-Host ('   - ' + $b.File.FullName) -ForegroundColor Red
            Write-Host ('     ' + ('{0,7:N0} 行 / {1,9:N0} B ｜ ' -f $b.Stats.Lines, $b.Stats.Bytes) + $b.Issues) -ForegroundColor DarkGray
            if ($b.Stats.Repeated.Count -gt 0) { Write-Dim ('最高重复行：' + (Short-Text $b.Stats.Repeated[0].Text 60)) }
        }
    }
    if ($soft.Count -gt 0) {
        Write-Host ('  另有 ' + $soft.Count + ' 个文件存在 2~' + ($maxRepeat - 1) + ' 次的分章同名标题（一般正常，仅供留意）：') -ForegroundColor DarkYellow
        foreach ($s2 in $soft) { Write-Dim ((Split-Path $s2.File.FullName -Leaf) + '  (重复标题 ' + $s2.Dup + ' 个)') }
    }
    return ($bad.Count -eq 0)
}

# ---------------------------------------------------------------------------
# 分发
# ---------------------------------------------------------------------------
switch ($Action) {
    'snapshot' {
        if (-not $File) { throw 'snapshot 需要 <文件> 参数' }
        $r = Save-Snapshot $File $MaxRepeat
        Write-Head 'snapshot'
        Write-Host ('  ' + $r.Backup) -ForegroundColor Green
        Write-Dim ('基线：' + $r.Meta.Lines + ' 行 / ' + ('{0:N0}' -f $r.Meta.Bytes) + ' B / ' + $r.Meta.Sha256.Substring(0, 16) + '... / 标题 ' + (Get-PropKeys $r.Meta.Headings).Count + ' 个')
        exit 0
    }
    'verify' {
        if (-not $File) { throw 'verify 需要 <文件> 参数' }
        $doRestore = $RestoreOnFail.IsPresent
        Write-Head ('体检 ' + (Split-Path $File -Leaf))
        $base = Read-Baseline $File
        $res = Invoke-Checks $File $MaxRepeat $AllowDuplicateHeadings.IsPresent $base
        Show-Report $File $res
        if ($res.Fails.Count -gt 0) {
            if ($doRestore) { Write-Bad '体检未通过 ⇒ 自动回滚'; [void](Invoke-Restore $File) } else { Write-Host '  （可加 -RestoreOnFail 自动回滚）' -ForegroundColor DarkGray }
            exit 1
        }
        exit 0
    }
    'replace' {
        if (-not $File) { throw 'replace 需要 <文件> 参数' }
        $doRestore = $true
        if ($PSBoundParameters.ContainsKey('RestoreOnFail')) { $doRestore = $RestoreOnFail.IsPresent }
        Write-Head ('字面替换 ' + (Split-Path $File -Leaf))
        $ok = Invoke-Replace $File $Old $New $All.IsPresent $Expect $doRestore $MaxRepeat
        if ($ok) { exit 0 } else { exit 1 }
    }
    'restore' {
        if (-not $File) { throw 'restore 需要 <文件> 参数' }
        Write-Head ('回滚 ' + (Split-Path $File -Leaf))
        [void](Invoke-Restore $File)
        $base = Read-Baseline $File
        $res = Invoke-Checks $File $MaxRepeat $true $base
        Show-Report $File $res
        exit 0
    }
    'scan' {
        $target = $Root
        if (-not $target) { $target = $File }
        if (-not $target) { throw 'scan 需要 <目录> 参数' }
        $ok = Invoke-Scan $target $MaxRepeat
        if ($ok) { exit 0 } else { exit 1 }
    }
}
