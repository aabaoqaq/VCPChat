[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [switch]$ValidateOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$script:Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:StartedAt = Get-Date
$script:ReportRoot = Join-Path $script:RepoRoot "AppData\update-report"
$script:HistoryRoot = Join-Path $script:ReportRoot "history"
$script:RunRoot = Join-Path $script:HistoryRoot $script:Timestamp
$script:UpstreamCopyRoot = Join-Path $script:RunRoot "upstream"
$script:SnapshotRoot = Join-Path ([System.IO.Path]::GetTempPath()) "VCPChatUpdate-$($script:Timestamp)"
$script:SnapshotDataRoot = Join-Path $script:SnapshotRoot "protected"
$script:ExcludeFile = Join-Path $script:RepoRoot ".update-exclude.txt"
$script:BatchEntry = Join-Path $script:RepoRoot "自动更新.bat"
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:SnapshotItems = @()

$script:Report = [ordered]@{
    Status = $(if ($ValidateOnly) { "ValidateOnly" } else { "Pending" })
    BeforeHead = $null
    AfterHead = $null
    UpstreamHead = $null
    CurrentBranch = $null
    UpstreamCommits = @()
    DiffStat = @()
    ProtectedPaths = @()
    RestoredPaths = @()
    ImportedExampleKeys = @()
    UpstreamCopies = @()
    DependencyChanges = @()
    Notes = @()
    Conflicts = @()
    StashRef = $null
    FinalAction = "仅本地保留"
}

$script:DefaultCoreEntries = @(
    ".update-exclude.txt",
    ".gitignore.local",
    "自动更新.bat",
    "tools/update/VCPChatUpdate.ps1",
    "Forummodules/config.env",
    "RAGmodules/config.env",
    "VCPDistributedServer/Plugin/DeepMemo/config.env",
    "VCPDistributedServer/Plugin/DeepMemo/config.env.local",
    "VCPDistributedServer/Plugin/DistImageServer/config.env"
)

$script:DefaultUserEntries = @(
    "assets/wallpaper/"
)

$script:DefaultRuntimeEntries = @(
    "AppData/",
    "VCPDistributedServer/Plugin/PTYShellExecutor/reports/",
    "VCPDistributedServer/Plugin/BladeGame/game_state.json",
    "VCPDistributedServer/Plugin/BladeGame/备份/"
)

function Write-Stage {
    param([string]$Title)

    Write-Host ""
    Write-Host ("=" * 60)
    Write-Host $Title
    Write-Host ("=" * 60)
}

function Add-ReportNote {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $script:Report.Notes += $Message
    }
}

function Normalize-RelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $value = $Path.Trim().Replace("\", "/")
    if ($value.StartsWith("./")) {
        $value = $value.Substring(2)
    }
    while ($value.StartsWith("/")) {
        $value = $value.Substring(1)
    }
    return $value
}

function Get-RepoRelativePath {
    param([string]$LiteralPath)

    $relative = [System.IO.Path]::GetRelativePath($script:RepoRoot, $LiteralPath)
    return Normalize-RelativePath -Path $relative
}

function Convert-ToLiteralPath {
    param([string]$RelativePath)

    $normalized = Normalize-RelativePath -Path $RelativePath
    $segments = $normalized -split "/"
    return Join-Path -Path $script:RepoRoot -ChildPath ([System.IO.Path]::Combine($segments))
}

function Convert-ToSnapshotPath {
    param([string]$RelativePath)

    $normalized = Normalize-RelativePath -Path $RelativePath
    $trimmed = $normalized.TrimEnd("/")
    $segments = $trimmed -split "/"
    return Join-Path -Path $script:SnapshotDataRoot -ChildPath ([System.IO.Path]::Combine($segments))
}

function Convert-ToRunUpstreamPath {
    param([string]$RelativePath)

    $normalized = Normalize-RelativePath -Path $RelativePath
    $segments = $normalized -split "/"
    return Join-Path -Path $script:UpstreamCopyRoot -ChildPath ([System.IO.Path]::Combine($segments))
}

function Ensure-Directory {
    param([string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        [void](New-Item -ItemType Directory -Path $LiteralPath -Force)
    }
}

function Test-StringInList {
    param(
        [string[]]$List,
        [string]$Value
    )

    foreach ($item in $List) {
        if ($item.Equals($Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Add-UniqueItem {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $normalized = Normalize-RelativePath -Path $Value
        if (-not (Test-StringInList -List $List.ToArray() -Value $normalized)) {
            [void]$List.Add($normalized)
        }
    }
}

function Test-EntryMatch {
    param(
        [string]$Entry,
        [string]$RelativePath
    )

    $entryValue = Normalize-RelativePath -Path $Entry
    $pathValue = Normalize-RelativePath -Path $RelativePath
    if ([string]::IsNullOrWhiteSpace($entryValue) -or [string]::IsNullOrWhiteSpace($pathValue)) {
        return $false
    }

    if ($entryValue.EndsWith("/")) {
        return $pathValue.StartsWith($entryValue, [System.StringComparison]::OrdinalIgnoreCase)
    }

    return $pathValue.Equals($entryValue, [System.StringComparison]::OrdinalIgnoreCase)
}

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $gitArgs = @("-c", "core.quotepath=false", "-C", $script:RepoRoot) + $Arguments
    $output = & git @gitArgs 2>&1
    $exitCode = $LASTEXITCODE
    if ((-not $AllowFailure) -and $exitCode -ne 0) {
        $joinedOutput = ($output | Out-String).Trim()
        throw "git $($Arguments -join ' ') 执行失败：`n$joinedOutput"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Ensure-ExcludeFile {
    if (Test-Path -LiteralPath $script:ExcludeFile) {
        return
    }

    $content = @(
        "# VCPChat 更新保护清单",
        "# 说明：",
        "# 1. 核心配置和用户数据会在更新后自动恢复/保留本地版本。",
        "# 2. 运行时产物不会参与恢复，仅用于避免误判为需要保留的个人内容。",
        "",
        "# === 核心配置 ==="
    ) + $script:DefaultCoreEntries + @(
        "",
        "# === 用户数据 ==="
    ) + $script:DefaultUserEntries + @(
        "",
        "# === 运行时产物 ==="
    ) + $script:DefaultRuntimeEntries

    Ensure-Directory -LiteralPath (Split-Path -Parent $script:ExcludeFile)
    [System.IO.File]::WriteAllLines($script:ExcludeFile, $content, $script:Utf8NoBom)
}

function Get-ExcludeSpec {
    Ensure-ExcludeFile

    $core = [System.Collections.Generic.List[string]]::new()
    $user = [System.Collections.Generic.List[string]]::new()
    $runtime = [System.Collections.Generic.List[string]]::new()
    $section = "Core"

    foreach ($line in Get-Content -LiteralPath $script:ExcludeFile -ErrorAction Stop) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($trimmed -like "#*") {
            if ($trimmed -match "运行时") {
                $section = "Runtime"
            } elseif ($trimmed -match "用户数据") {
                $section = "User"
            } elseif ($trimmed -match "核心配置|保护恢复") {
                $section = "Core"
            }
            continue
        }

        if ($trimmed.Equals("ECHO is off.", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        switch ($section) {
            "Runtime" { Add-UniqueItem -List $runtime -Value $trimmed }
            "User" { Add-UniqueItem -List $user -Value $trimmed }
            default { Add-UniqueItem -List $core -Value $trimmed }
        }
    }

    foreach ($entry in $script:DefaultCoreEntries) {
        Add-UniqueItem -List $core -Value $entry
    }
    foreach ($entry in $script:DefaultUserEntries) {
        Add-UniqueItem -List $user -Value $entry
    }
    foreach ($entry in $script:DefaultRuntimeEntries) {
        Add-UniqueItem -List $runtime -Value $entry
    }

    return [pscustomobject]@{
        Core = $core.ToArray()
        User = $user.ToArray()
        Runtime = $runtime.ToArray()
        Protected = @($core.ToArray() + $user.ToArray())
    }
}

function Get-EnvLikeRelativePaths {
    $results = [System.Collections.Generic.List[string]]::new()
    $files = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Force -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if ($file.FullName -match "\\\.git(\\|$)") {
            continue
        }

        $name = $file.Name
        $isEnvLike = (
            $name.Equals(".env", [System.StringComparison]::OrdinalIgnoreCase) -or
            $name.Equals(".env.local", [System.StringComparison]::OrdinalIgnoreCase) -or
            $name.Equals("config.env", [System.StringComparison]::OrdinalIgnoreCase) -or
            $name.Equals("config.env.local", [System.StringComparison]::OrdinalIgnoreCase)
        )

        if ($isEnvLike) {
            Add-UniqueItem -List $results -Value (Get-RepoRelativePath -LiteralPath $file.FullName)
        }
    }

    return $results.ToArray()
}

function Test-IsRuntimePath {
    param(
        [string]$RelativePath,
        [string[]]$RuntimeEntries
    )

    foreach ($entry in $RuntimeEntries) {
        if (Test-EntryMatch -Entry $entry -RelativePath $RelativePath) {
            return $true
        }
    }

    return $false
}

function Get-ProtectedPaths {
    param([pscustomobject]$ExcludeSpec)

    $protected = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $ExcludeSpec.Protected) {
        Add-UniqueItem -List $protected -Value $entry
    }

    foreach ($entry in Get-EnvLikeRelativePaths) {
        if (-not (Test-IsRuntimePath -RelativePath $entry -RuntimeEntries $ExcludeSpec.Runtime)) {
            Add-UniqueItem -List $protected -Value $entry
        }
    }

    return $protected.ToArray() | Sort-Object
}

function Get-WorkingTreeChanges {
    $result = Invoke-Git -Arguments @("status", "--porcelain=v1", "-uall")
    $changes = @()
    foreach ($line in $result.Output) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $text = [string]$line
        if ($text.Length -lt 4) {
            continue
        }

        $status = $text.Substring(0, 2)
        $pathText = $text.Substring(3)
        if ($pathText.Contains(" -> ")) {
            $parts = $pathText.Split(" -> ")
            $pathText = $parts[-1]
        }

        $changes += [pscustomobject]@{
            Status = $status
            Path = Normalize-RelativePath -Path $pathText
            IsUntracked = $status.Equals("??", [System.StringComparison]::Ordinal)
        }
    }

    return $changes
}

function Split-ChangesByProtection {
    param(
        [pscustomobject[]]$Changes,
        [string[]]$ProtectedEntries,
        [string[]]$RuntimeEntries
    )

    $protected = @()
    $runtime = @()
    $other = @()

    foreach ($change in $Changes) {
        $isProtected = $false
        foreach ($entry in $ProtectedEntries) {
            if (Test-EntryMatch -Entry $entry -RelativePath $change.Path) {
                $isProtected = $true
                break
            }
        }

        if ($isProtected) {
            $protected += $change
            continue
        }

        if (Test-IsRuntimePath -RelativePath $change.Path -RuntimeEntries $RuntimeEntries) {
            $runtime += $change
            continue
        }

        $other += $change
    }

    return [pscustomobject]@{
        Protected = $protected
        Runtime = $runtime
        Other = $other
    }
}

function Backup-ProtectedItems {
    param([string[]]$ProtectedEntries)

    Ensure-Directory -LiteralPath $script:SnapshotDataRoot

    $backedUp = @()
    foreach ($entry in $ProtectedEntries) {
        $literalPath = Convert-ToLiteralPath -RelativePath $entry
        if (-not (Test-Path -LiteralPath $literalPath)) {
            continue
        }

        $item = Get-Item -LiteralPath $literalPath -Force
        $snapshotPath = Convert-ToSnapshotPath -RelativePath $entry
        Ensure-Directory -LiteralPath (Split-Path -Parent $snapshotPath)

        if ($item.PSIsContainer) {
            Copy-Item -LiteralPath $literalPath -Destination $snapshotPath -Recurse -Force
            $backedUp += [pscustomobject]@{ Path = Normalize-RelativePath -Path $entry; Kind = "Directory" }
        } else {
            Copy-Item -LiteralPath $literalPath -Destination $snapshotPath -Force
            $backedUp += [pscustomobject]@{ Path = Normalize-RelativePath -Path $entry; Kind = "File" }
        }
    }

    return $backedUp
}

function Remove-TrackedPathChanges {
    param([string[]]$Paths)

    if ($Paths.Count -gt 0) {
        Invoke-Git -Arguments (@("restore", "--source=HEAD", "--staged", "--worktree", "--") + $Paths) | Out-Null
    }
}

function Remove-UntrackedPathChanges {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        $literalPath = Convert-ToLiteralPath -RelativePath $path
        if (Test-Path -LiteralPath $literalPath) {
            Remove-Item -LiteralPath $literalPath -Recurse -Force
        }
    }
}

function Clear-PathsFromWorkingTree {
    param([pscustomobject[]]$Changes)

    $trackedPaths = @($Changes | Where-Object { -not $_.IsUntracked } | ForEach-Object { $_.Path } | Sort-Object -Unique)
    $untrackedPaths = @($Changes | Where-Object { $_.IsUntracked } | ForEach-Object { $_.Path } | Sort-Object -Unique)

    Remove-TrackedPathChanges -Paths $trackedPaths
    Remove-UntrackedPathChanges -Paths $untrackedPaths
}

function Get-HeadHash {
    return ((Invoke-Git -Arguments @("rev-parse", "HEAD")).Output | Select-Object -First 1).Trim()
}

function Get-UpstreamHash {
    return ((Invoke-Git -Arguments @("rev-parse", "upstream/main")).Output | Select-Object -First 1).Trim()
}

function Get-BranchName {
    return ((Invoke-Git -Arguments @("rev-parse", "--abbrev-ref", "HEAD")).Output | Select-Object -First 1).Trim()
}

function Get-CommitLines {
    param(
        [string]$Range,
        [string]$Format = "- %h %s"
    )

    $result = Invoke-Git -Arguments @("log", "--reverse", "--pretty=format:$Format", $Range) -AllowFailure
    return @($result.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-DiffStatLines {
    param([string]$Range)

    $result = Invoke-Git -Arguments @("diff", "--stat", $Range) -AllowFailure
    return @($result.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ConflictDetails {
    $files = @((Invoke-Git -Arguments @("diff", "--name-only", "--diff-filter=U") -AllowFailure).Output |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Normalize-RelativePath -Path ([string]$_) })

    $details = @()
    foreach ($file in $files) {
        $statusLine = @((Invoke-Git -Arguments @("status", "--porcelain=v1", "--", $file) -AllowFailure).Output)[0]
        $snippet = @()
        $literalPath = Convert-ToLiteralPath -RelativePath $file
        if (Test-Path -LiteralPath $literalPath) {
            $lines = Get-Content -LiteralPath $literalPath -ErrorAction SilentlyContinue
            $marker = $lines | Select-String -Pattern "^(<<<<<<<|=======|>>>>>>>)" | Select-Object -First 1
            if ($null -ne $marker) {
                $start = [Math]::Max(1, $marker.LineNumber - 3)
                $end = [Math]::Min($lines.Count, $marker.LineNumber + 8)
                for ($index = $start; $index -le $end; $index++) {
                    $snippet += "{0,4}: {1}" -f $index, $lines[$index - 1]
                }
            }
        }

        $details += [pscustomobject]@{
            Path = $file
            Status = if ($statusLine) { ([string]$statusLine).Trim() } else { "未识别" }
            Snippet = $snippet
        }
    }

    return $details
}

function Show-ConflictSummary {
    param(
        [pscustomobject[]]$Conflicts,
        [string]$Phase
    )

    Write-Stage -Title "检测到真实冲突：$Phase"
    foreach ($conflict in $Conflicts) {
        Write-Host "- $($conflict.Path) [$($conflict.Status)]"
        foreach ($line in $conflict.Snippet) {
            Write-Host "  $line"
        }
    }
}

function Get-FileHashSafe {
    param([string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return $null
    }

    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash
}

function Get-MatchingExampleRelativePath {
    param([string]$RelativePath)

    $normalized = Normalize-RelativePath -Path $RelativePath
    $directory = Split-Path -Path $normalized -Parent
    $name = Split-Path -Path $normalized -Leaf
    $candidates = @()

    switch -Regex ($name) {
        "^config\.env\.local$" { $candidates += "config.env.example" }
        "^\.env\.local$" { $candidates += ".env.example" }
        "^config\.env$" { $candidates += "config.env.example" }
        "^\.env$" { $candidates += ".env.example" }
    }

    foreach ($candidate in $candidates) {
        $relativeCandidate = if ([string]::IsNullOrWhiteSpace($directory)) { $candidate } else { (Normalize-RelativePath -Path "$directory/$candidate") }
        if (Test-Path -LiteralPath (Convert-ToLiteralPath -RelativePath $relativeCandidate)) {
            return $relativeCandidate
        }
    }

    return $null
}

function Get-EnvAssignmentMap {
    param([string]$LiteralPath)

    $map = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $LiteralPath -ErrorAction Stop) {
        if ($line -match "^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=") {
            $key = $Matches[1]
            if (-not $map.Contains($key)) {
                $map[$key] = $line
            }
        }
    }

    return $map
}

function Import-MissingExampleKeys {
    param(
        [string]$TargetRelativePath,
        [string]$ExampleRelativePath
    )

    $targetLiteralPath = Convert-ToLiteralPath -RelativePath $TargetRelativePath
    $exampleLiteralPath = Convert-ToLiteralPath -RelativePath $ExampleRelativePath
    if ((-not (Test-Path -LiteralPath $targetLiteralPath)) -or (-not (Test-Path -LiteralPath $exampleLiteralPath))) {
        return @()
    }

    $targetMap = Get-EnvAssignmentMap -LiteralPath $targetLiteralPath
    $exampleMap = Get-EnvAssignmentMap -LiteralPath $exampleLiteralPath
    $missing = @()

    foreach ($key in $exampleMap.Keys) {
        if (-not $targetMap.Contains($key)) {
            $missing += [pscustomobject]@{ Key = $key; Line = $exampleMap[$key] }
        }
    }

    if ($missing.Count -gt 0) {
        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.AppendLine("")
        [void]$builder.AppendLine("# Added from upstream example on $($script:Timestamp)")
        foreach ($entry in $missing) {
            [void]$builder.AppendLine($entry.Line)
        }

        [System.IO.File]::AppendAllText($targetLiteralPath, $builder.ToString(), $script:Utf8NoBom)
    }

    return $missing
}

function Save-UpstreamVariantIfNeeded {
    param([pscustomobject]$SnapshotItem)

    if ($SnapshotItem.Kind -ne "File") {
        return
    }

    $relativePath = Normalize-RelativePath -Path $SnapshotItem.Path
    $currentLiteralPath = Convert-ToLiteralPath -RelativePath $relativePath
    $snapshotLiteralPath = Convert-ToSnapshotPath -RelativePath $relativePath
    if ((-not (Test-Path -LiteralPath $currentLiteralPath)) -or (-not (Test-Path -LiteralPath $snapshotLiteralPath))) {
        return
    }

    $examplePath = Get-MatchingExampleRelativePath -RelativePath $relativePath
    if ($null -ne $examplePath) {
        return
    }

    $currentHash = Get-FileHashSafe -LiteralPath $currentLiteralPath
    $snapshotHash = Get-FileHashSafe -LiteralPath $snapshotLiteralPath
    if (($null -eq $currentHash) -or ($null -eq $snapshotHash) -or ($currentHash -eq $snapshotHash)) {
        return
    }

    $upstreamLiteralPath = Convert-ToRunUpstreamPath -RelativePath $relativePath
    Ensure-Directory -LiteralPath (Split-Path -Parent $upstreamLiteralPath)
    Copy-Item -LiteralPath $currentLiteralPath -Destination $upstreamLiteralPath -Force
    $script:Report.UpstreamCopies += [pscustomobject]@{
        Target = $relativePath
        SavedTo = (Get-RepoRelativePath -LiteralPath $upstreamLiteralPath)
    }
}

function Restore-ProtectedItems {
    param([pscustomobject[]]$SnapshotItems)

    foreach ($item in $SnapshotItems) {
        $snapshotLiteralPath = Convert-ToSnapshotPath -RelativePath $item.Path
        if (-not (Test-Path -LiteralPath $snapshotLiteralPath)) {
            continue
        }

        $targetLiteralPath = Convert-ToLiteralPath -RelativePath $item.Path
        Ensure-Directory -LiteralPath (Split-Path -Parent $targetLiteralPath)

        if ($item.Kind -eq "Directory") {
            Ensure-Directory -LiteralPath $targetLiteralPath
            $children = Get-ChildItem -LiteralPath $snapshotLiteralPath -Force -ErrorAction SilentlyContinue
            foreach ($child in $children) {
                Copy-Item -LiteralPath $child.FullName -Destination $targetLiteralPath -Recurse -Force
            }
        } else {
            Copy-Item -LiteralPath $snapshotLiteralPath -Destination $targetLiteralPath -Force
        }

        $script:Report.RestoredPaths += $item.Path
    }
}

function Get-DependencyChanges {
    param(
        [string]$BeforeHead,
        [string]$AfterHead
    )

    if ([string]::IsNullOrWhiteSpace($BeforeHead) -or [string]::IsNullOrWhiteSpace($AfterHead)) {
        return @()
    }

    $changedFiles = @((Invoke-Git -Arguments @("diff", "--name-only", "$BeforeHead..$AfterHead") -AllowFailure).Output |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Normalize-RelativePath -Path ([string]$_) })

    return @($changedFiles | Where-Object {
        $_ -match "(^|/)(package\.json|package-lock\.json|requirements\.txt|pyproject\.toml|poetry\.lock)$"
    })
}

function Invoke-DependencyInstallers {
    param([string[]]$DependencyFiles)

    $nodeFiles = @($DependencyFiles | Where-Object { $_ -match "(^|/)(package\.json|package-lock\.json)$" })
    $requirementsFiles = @($DependencyFiles | Where-Object { $_ -match "(^|/)requirements\.txt$" })
    $poetryFiles = @($DependencyFiles | Where-Object { $_ -match "(^|/)(pyproject\.toml|poetry\.lock)$" })

    if ($nodeFiles.Count -gt 0) {
        $choice = Read-Host "检测到 Node 依赖清单变化，是否在仓库根目录执行 npm install？(Y/N，默认 N)"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "N" }
        if ($choice.Trim().ToUpperInvariant() -eq "Y") {
            Push-Location $script:RepoRoot
            try {
                & npm install
                if ($LASTEXITCODE -eq 0) {
                    Add-ReportNote -Message "已在仓库根目录执行 npm install。"
                } else {
                    Add-ReportNote -Message "npm install 执行失败，请手动检查。"
                }
            } finally {
                Pop-Location
            }
        }
    }

    if ($requirementsFiles.Count -gt 0) {
        $choice = Read-Host "检测到 Python requirements 变化，是否按清单执行 pip install -r？(Y/N，默认 N)"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "N" }
        if ($choice.Trim().ToUpperInvariant() -eq "Y") {
            foreach ($requirementsFile in $requirementsFiles) {
                $literalPath = Convert-ToLiteralPath -RelativePath $requirementsFile
                Write-Host "- pip install -r $requirementsFile"
                & pip install -r $literalPath
                if ($LASTEXITCODE -eq 0) {
                    Add-ReportNote -Message "已执行 pip install -r $requirementsFile。"
                } else {
                    Add-ReportNote -Message "pip install -r $requirementsFile 执行失败，请手动检查。"
                }
            }
        }
    }

    if ($poetryFiles.Count -gt 0) {
        Add-ReportNote -Message "检测到 pyproject.toml / poetry.lock 变化，请按你的本地流程决定是否执行 poetry install。"
    }
}

function Write-UpdateReport {
    Ensure-Directory -LiteralPath $script:RunRoot
    Ensure-Directory -LiteralPath $script:ReportRoot
    Ensure-Directory -LiteralPath $script:HistoryRoot

    $reportPath = Join-Path $script:RunRoot "report.md"
    $latestPath = Join-Path $script:ReportRoot "latest.md"
    $finishedAt = Get-Date
    $lines = [System.Collections.Generic.List[string]]::new()

    [void]$lines.Add("# VCPChat 更新报告")
    [void]$lines.Add("")
    [void]$lines.Add("- 状态: $($script:Report.Status)")
    [void]$lines.Add("- 开始时间: $($script:StartedAt.ToString("yyyy-MM-dd HH:mm:ss"))")
    [void]$lines.Add("- 结束时间: $($finishedAt.ToString("yyyy-MM-dd HH:mm:ss"))")
    [void]$lines.Add("- 分支: $($script:Report.CurrentBranch)")
    [void]$lines.Add("- 更新前 HEAD: $($script:Report.BeforeHead)")
    [void]$lines.Add("- 更新后 HEAD: $($script:Report.AfterHead)")
    [void]$lines.Add("- 上游 HEAD: $($script:Report.UpstreamHead)")
    [void]$lines.Add("- 非保护项 stash: $(if ($script:Report.StashRef) { $script:Report.StashRef } else { "无" })")
    [void]$lines.Add("- 结束动作: $($script:Report.FinalAction)")
    [void]$lines.Add("")

    [void]$lines.Add("## 上游提交")
    if ($script:Report.UpstreamCommits.Count -gt 0) {
        foreach ($line in $script:Report.UpstreamCommits) {
            [void]$lines.Add($line)
        }
    } else {
        [void]$lines.Add("- 无需合并，上游没有新提交。")
    }
    [void]$lines.Add("")

    [void]$lines.Add("## 变更统计")
    if ($script:Report.DiffStat.Count -gt 0) {
        foreach ($line in $script:Report.DiffStat) {
            [void]$lines.Add("- $line")
        }
    } else {
        [void]$lines.Add("- 无")
    }
    [void]$lines.Add("")

    [void]$lines.Add("## 保护项恢复")
    if ($script:Report.RestoredPaths.Count -gt 0) {
        foreach ($path in ($script:Report.RestoredPaths | Sort-Object -Unique)) {
            [void]$lines.Add("- $path")
        }
    } else {
        [void]$lines.Add("- 无")
    }
    [void]$lines.Add("")

    [void]$lines.Add("## Example 新键导入")
    if ($script:Report.ImportedExampleKeys.Count -gt 0) {
        foreach ($entry in $script:Report.ImportedExampleKeys) {
            [void]$lines.Add("- $($entry.Path): $($entry.Keys -join ', ')")
        }
    } else {
        [void]$lines.Add("- 无")
    }
    [void]$lines.Add("")

    [void]$lines.Add("## 上游配置副本")
    if ($script:Report.UpstreamCopies.Count -gt 0) {
        foreach ($entry in $script:Report.UpstreamCopies) {
            [void]$lines.Add("- $($entry.Target) -> $($entry.SavedTo)")
        }
    } else {
        [void]$lines.Add("- 无")
    }
    [void]$lines.Add("")

    [void]$lines.Add("## 依赖清单变化")
    if ($script:Report.DependencyChanges.Count -gt 0) {
        foreach ($path in $script:Report.DependencyChanges) {
            [void]$lines.Add("- $path")
        }
    } else {
        [void]$lines.Add("- 无")
    }
    [void]$lines.Add("")

    [void]$lines.Add("## 冲突")
    if ($script:Report.Conflicts.Count -gt 0) {
        foreach ($conflict in $script:Report.Conflicts) {
            [void]$lines.Add("- $($conflict.Path) [$($conflict.Status)]")
            foreach ($line in $conflict.Snippet) {
                [void]$lines.Add("  $line")
            }
        }
    } else {
        [void]$lines.Add("- 无")
    }
    [void]$lines.Add("")

    [void]$lines.Add("## 备注")
    if ($script:Report.Notes.Count -gt 0) {
        foreach ($note in $script:Report.Notes) {
            [void]$lines.Add("- $note")
        }
    } else {
        [void]$lines.Add("- 无")
    }

    [System.IO.File]::WriteAllLines($reportPath, $lines, $script:Utf8NoBom)
    [System.IO.File]::WriteAllLines($latestPath, $lines, $script:Utf8NoBom)
    return $reportPath
}

function Prune-ReportHistory {
    if (-not (Test-Path -LiteralPath $script:HistoryRoot)) {
        return
    }

    $historyDirs = Get-ChildItem -LiteralPath $script:HistoryRoot -Directory | Sort-Object Name -Descending
    $toRemove = $historyDirs | Select-Object -Skip 10
    foreach ($item in $toRemove) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}

function Restore-OriginalStateAfterAbort {
    param([string]$StashRef)

    $mergeAbort = Invoke-Git -Arguments @("merge", "--abort") -AllowFailure
    if ($mergeAbort.ExitCode -ne 0) {
        Add-ReportNote -Message "git merge --abort 未成功完成，请手动检查仓库状态。"
    }

    if (-not [string]::IsNullOrWhiteSpace($StashRef)) {
        $stashResult = Invoke-Git -Arguments @("stash", "pop", "--index", $StashRef) -AllowFailure
        if ($stashResult.ExitCode -eq 0) {
            Add-ReportNote -Message "已恢复更新前的工作区修改。"
        } else {
            Add-ReportNote -Message "自动恢复 stash 失败，请手动执行 git stash list / git stash pop。"
        }
    }
}

try {
    Write-Stage -Title "VCPChat 自动更新脚本"

    if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot ".git"))) {
        throw "当前目录不是 Git 仓库：$($script:RepoRoot)"
    }

    if (-not (Test-Path -LiteralPath $script:BatchEntry)) {
        throw "找不到批处理入口：$($script:BatchEntry)"
    }

    $script:Report.CurrentBranch = Get-BranchName
    if ($script:Report.CurrentBranch -ne "custom") {
        throw "当前分支是 '$($script:Report.CurrentBranch)'，脚本只允许在 custom 分支执行。"
    }

    $upstreamRemote = Invoke-Git -Arguments @("remote", "get-url", "upstream") -AllowFailure
    if ($upstreamRemote.ExitCode -ne 0) {
        throw "未检测到 upstream 远程。请先执行 git remote add upstream <官方仓库地址>。"
    }

    $excludeSpec = Get-ExcludeSpec
    $protectedPaths = Get-ProtectedPaths -ExcludeSpec $excludeSpec
    $script:Report.ProtectedPaths = $protectedPaths

    Write-Host "- 保护项数量: $($protectedPaths.Count)"
    Write-Host "- 运行时跳过项数量: $($excludeSpec.Runtime.Count)"
    Write-Host "- 上游: $(([string]$upstreamRemote.Output[0]).Trim())"

    if ($ValidateOnly) {
        $script:Report.Status = "ValidateOnly"
        $script:Report.BeforeHead = Get-HeadHash
        $script:Report.UpstreamHead = "ValidateOnly"
        Add-ReportNote -Message "仅执行静态校验，未执行 fetch / merge / install / push。"
        Write-Host ""
        Write-Host "校验完成：脚本已成功解析，未改动 Git 工作区。"
        return
    }

    Write-Stage -Title "阶段 1/5：拉取上游并生成更新摘要"
    $script:Report.BeforeHead = Get-HeadHash
    Invoke-Git -Arguments @("fetch", "upstream", "main") | Out-Null
    $script:Report.UpstreamHead = Get-UpstreamHash

    $pendingCommitCount = ((Invoke-Git -Arguments @("rev-list", "--count", "$($script:Report.BeforeHead)..upstream/main")).Output | Select-Object -First 1).Trim()
    $script:Report.UpstreamCommits = @(Get-CommitLines -Range "$($script:Report.BeforeHead)..upstream/main")
    $script:Report.DiffStat = @(Get-DiffStatLines -Range "$($script:Report.BeforeHead)..upstream/main")

    if ($pendingCommitCount -eq "0") {
        $script:Report.Status = "UpToDate"
        $script:Report.AfterHead = $script:Report.BeforeHead
        Add-ReportNote -Message "上游没有新提交，本次未执行 merge。"
        $reportPath = Write-UpdateReport
        Prune-ReportHistory
        Write-Host "当前已经是最新版本。"
        Write-Host "报告位置: $reportPath"
        return
    }

    Write-Host "- 待合并提交数: $pendingCommitCount"
    foreach ($line in $script:Report.UpstreamCommits) {
        Write-Host "  $line"
    }

    $workingChanges = @(Get-WorkingTreeChanges)
    $classifiedChanges = Split-ChangesByProtection -Changes $workingChanges -ProtectedEntries $protectedPaths -RuntimeEntries $excludeSpec.Runtime
    $snapshotItems = @(Backup-ProtectedItems -ProtectedEntries $protectedPaths)
    $script:SnapshotItems = @($snapshotItems)

    if ($snapshotItems.Count -gt 0) {
        Add-ReportNote -Message "已在临时目录创建保护项快照：$($script:SnapshotDataRoot)"
    }

    if ($classifiedChanges.Other.Count -gt 0) {
        Write-Host "- 检测到 $($classifiedChanges.Other.Count) 个非保护项本地修改，先单独 stash。"
        $pathsToStash = @($classifiedChanges.Other | ForEach-Object { $_.Path } | Sort-Object -Unique)
        $stashMessage = "VCPChat auto-update non-protected $($script:Timestamp)"
        Invoke-Git -Arguments (@("stash", "push", "--include-untracked", "-m", $stashMessage, "--") + $pathsToStash) | Out-Null
        $stashList = Invoke-Git -Arguments @("stash", "list", "-1", "--format=%gd")
        $script:Report.StashRef = (([string]$stashList.Output[0]).Trim())
        Add-ReportNote -Message "非保护项修改已暂存到 $($script:Report.StashRef)，本次更新不会自动恢复。"
    }

    $pathsToClear = @($classifiedChanges.Protected + $classifiedChanges.Runtime)
    if ($pathsToClear.Count -gt 0) {
        Write-Host "- 清理受保护/运行时改动，确保 merge 仅处理分支历史。"
        Clear-PathsFromWorkingTree -Changes $pathsToClear
    }

    $postClearChanges = @(Get-WorkingTreeChanges)
    if ($postClearChanges.Count -gt 0) {
        $remaining = $postClearChanges | ForEach-Object { $_.Path } | Sort-Object -Unique
        throw "清理后工作区仍不干净，未继续合并：$($remaining -join ', ')"
    }

    Write-Stage -Title "阶段 2/5：合并 upstream/main -> custom"
    $mergeResult = Invoke-Git -Arguments @("merge", "--no-edit", "upstream/main") -AllowFailure
    if ($mergeResult.ExitCode -ne 0) {
        $conflicts = @(Get-ConflictDetails)
        if ($conflicts.Count -gt 0) {
            $script:Report.Status = "Conflict"
            $script:Report.Conflicts = $conflicts
            Show-ConflictSummary -Conflicts $conflicts -Phase "merge"
            $choice = Read-Host "输入 A 终止本次更新并恢复到合并前，输入 K 保留冲突现场自己处理（默认 K）"
            if ([string]::IsNullOrWhiteSpace($choice)) {
                $choice = "K"
            }

            if ($choice.Trim().ToUpperInvariant() -eq "A") {
                Restore-OriginalStateAfterAbort -StashRef $script:Report.StashRef
                $script:Report.Status = "ConflictAborted"
                $script:Report.AfterHead = Get-HeadHash
                $reportPath = Write-UpdateReport
                Prune-ReportHistory
                Write-Host "已中止合并并恢复到更新前状态。"
                Write-Host "报告位置: $reportPath"
                return
            }

            Add-ReportNote -Message "你选择保留冲突现场。保护项快照仍在：$($script:SnapshotDataRoot)"
            $script:Report.AfterHead = Get-HeadHash
            $reportPath = Write-UpdateReport
            Prune-ReportHistory
            Write-Host "已保留冲突现场，请按报告中的文件列表手动处理。"
            Write-Host "报告位置: $reportPath"
            return
        }

        throw "git merge 返回非零，但未解析到冲突文件，请手动检查。"
    }

    $script:Report.AfterHead = Get-HeadHash
    $script:Report.Status = "Merged"

    Write-Stage -Title "阶段 3/5：恢复保护项并处理配置"
    foreach ($snapshotItem in $snapshotItems) {
        Save-UpstreamVariantIfNeeded -SnapshotItem $snapshotItem
    }

    Restore-ProtectedItems -SnapshotItems $snapshotItems

    foreach ($snapshotItem in $snapshotItems | Where-Object { $_.Kind -eq "File" }) {
        $examplePath = Get-MatchingExampleRelativePath -RelativePath $snapshotItem.Path
        if ($null -eq $examplePath) {
            continue
        }

        $missingKeys = @(Import-MissingExampleKeys -TargetRelativePath $snapshotItem.Path -ExampleRelativePath $examplePath)
        if ($missingKeys.Count -gt 0) {
            $script:Report.ImportedExampleKeys += [pscustomobject]@{
                Path = $snapshotItem.Path
                Keys = @($missingKeys | ForEach-Object { $_.Key })
            }
        }
    }

    Write-Stage -Title "阶段 4/5：依赖清单检查"
    $dependencyChanges = @(Get-DependencyChanges -BeforeHead $script:Report.BeforeHead -AfterHead $script:Report.AfterHead)
    $script:Report.DependencyChanges = @($dependencyChanges)
    if ($dependencyChanges.Count -gt 0) {
        foreach ($path in $dependencyChanges) {
            Write-Host "- $path"
        }
        Invoke-DependencyInstallers -DependencyFiles $dependencyChanges
    } else {
        Write-Host "未检测到依赖清单变化。"
    }

    Write-Stage -Title "阶段 5/5：收尾与可选推送"
    $pushChoice = Read-Host "是否推送到 origin/custom？(Y/N，默认 N)"
    if ([string]::IsNullOrWhiteSpace($pushChoice)) {
        $pushChoice = "N"
    }

    if ($pushChoice.Trim().ToUpperInvariant() -eq "Y") {
        $originRemote = Invoke-Git -Arguments @("remote", "get-url", "origin") -AllowFailure
        if ($originRemote.ExitCode -ne 0) {
            Add-ReportNote -Message "未检测到 origin，已保留本地结果。"
            $script:Report.FinalAction = "仅本地保留（origin 不存在）"
        } else {
            $pushResult = Invoke-Git -Arguments @("push", "origin", "custom") -AllowFailure
            if ($pushResult.ExitCode -eq 0) {
                $script:Report.FinalAction = "已推送 origin/custom"
            } else {
                $script:Report.FinalAction = "推送失败，结果仅保留本地"
                Add-ReportNote -Message "git push origin custom 失败，请检查网络或权限。"
            }
        }
    }

    $script:Report.Status = "Completed"
    $reportPath = Write-UpdateReport
    Prune-ReportHistory

    if (Test-Path -LiteralPath $script:SnapshotRoot) {
        Remove-Item -LiteralPath $script:SnapshotRoot -Recurse -Force
    }

    Write-Host ""
    Write-Host "更新完成。"
    Write-Host "报告位置: $reportPath"
    Write-Host "最新报告: $(Join-Path $script:ReportRoot 'latest.md')"
    if ($script:Report.StashRef) {
        Write-Host "非保护项修改仍在 $($script:Report.StashRef) 中，未自动恢复。"
    }
} catch {
    $script:Report.Status = "Failed"
    Add-ReportNote -Message $_.Exception.Message
    try {
        if ($script:SnapshotItems.Count -gt 0) {
            Restore-ProtectedItems -SnapshotItems $script:SnapshotItems
            Add-ReportNote -Message "失败后已尽力恢复保护项快照。"
        }
    } catch {
        Add-ReportNote -Message "失败后恢复保护项快照时再次出错，请手动检查。"
    }
    try {
        $script:Report.AfterHead = Get-HeadHash
    } catch {
        $script:Report.AfterHead = $script:Report.BeforeHead
    }

    try {
        $reportPath = Write-UpdateReport
        Prune-ReportHistory
        Write-Host ""
        Write-Host "脚本失败：$($_.Exception.Message)"
        Write-Host "报告位置: $reportPath"
    } catch {
        Write-Host ""
        Write-Host "脚本失败，且写报告时再次失败：$($_.Exception.Message)"
    }

    exit 1
}
