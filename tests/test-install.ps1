param([Parameter(Mandatory=$true)][string]$OriginalDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = [IO.Path]::GetFullPath((Join-Path $temporaryRoot ('KsaChinese-Test-' + [Guid]::NewGuid().ToString('N'))))
if (!$fixture.StartsWith($temporaryRoot.TrimEnd('\') + '\KsaChinese-Test-', [StringComparison]::OrdinalIgnoreCase)) { throw '测试目录越界' }
$installer = Join-Path $root 'scripts/install.ps1'
$remembered = Join-Path $root '.install-path.txt'
$hadRemembered = Test-Path -LiteralPath $remembered
$rememberedBytes = $null
if ($hadRemembered) { $rememberedBytes = [IO.File]::ReadAllBytes($remembered) }
$supportMarker = Join-Path $root '.support-viewed'
$hadSupportMarker = Test-Path -LiteralPath $supportMarker
$supportMarkerBytes = $null
if ($hadSupportMarker) { $supportMarkerBytes = [IO.File]::ReadAllBytes($supportMarker) }
function Get-TestHash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-Snapshot {
    $result = @{}
    foreach ($path in Get-ChildItem -LiteralPath $fixture -File -Recurse) {
        $result[$path.FullName.Substring($fixture.Length)] = Get-TestHash $path.FullName
    }
    return $result
}
function Assert-Same($before) {
    $after = Get-Snapshot
    if ($before.Count -ne $after.Count) { throw '拒绝安装后文件数量发生变化' }
    foreach ($path in $before.Keys) { if ($before[$path] -ne $after[$path]) { throw "拒绝安装后文件发生变化：$path" } }
}
function Expect-Rejection([scriptblock]$action, [string]$message) {
    $before = Get-Snapshot
    $rejected = $false
    try { & $action }
    catch { $rejected = $_.Exception.Message -like $message }
    if (!$rejected) { throw "没有拒绝无效安装：$message" }
    Assert-Same $before
}
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    # 后台安装测试模拟已看过提示，避免在用户桌面弹出窗口。
    [IO.File]::WriteAllText($supportMarker, (Get-TestHash (Join-Path $root '给我打赏一点吧，汉化不易.jpg')).ToUpperInvariant())
    foreach ($property in $manifest.originalHashes.PSObject.Properties) {
        $source = Join-Path $OriginalDirectory $property.Name
        if ((Get-TestHash $source) -ne $property.Value) { throw "原始测试文件校验失败：$($property.Name)" }
        $destination = Join-Path $fixture $property.Name
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }
    # 只设置文件存在标记，不启动或复制游戏可执行文件。
    [IO.File]::WriteAllText((Join-Path $fixture 'KSA.exe'), 'test marker; not executable')
    $save = Join-Path $fixture 'user-save-marker.dat'
    [IO.File]::WriteAllText($save, 'user save unchanged')
    $saveHash = Get-TestHash $save
    & $installer -Action Install -GameDirectory $fixture
    foreach ($property in $manifest.patchedHashes.PSObject.Properties) {
        if ((Get-TestHash (Join-Path $fixture $property.Name)) -ne $property.Value) { throw "安装结果不匹配：$($property.Name)" }
    }
    & $installer -Action Install -GameDirectory $fixture
    $unknown = Join-Path $fixture 'KsaChinese.dll'
    $knownBytes = [IO.File]::ReadAllBytes($unknown)
    [IO.File]::WriteAllText($unknown, 'unknown local user file')
    Expect-Rejection { & $installer -Action Install -GameDirectory $fixture } '*未知同名文件*'
    [IO.File]::WriteAllBytes($unknown, $knownBytes)
    & $installer -Action Restore -GameDirectory $fixture
    foreach ($property in $manifest.originalHashes.PSObject.Properties) {
        if ((Get-TestHash (Join-Path $fixture $property.Name)) -ne $property.Value) { throw "原始文件没有完整还原：$($property.Name)" }
    }
    foreach ($relative in @($manifest.files.PSObject.Properties.Name) + @($manifest.localFont)) {
        if (Test-Path -LiteralPath (Join-Path $fixture $relative)) { throw "还原后残留新增文件：$relative" }
    }
    $wrongVersion = Join-Path $fixture 'KSA.dll'
    $originalBytes = [IO.File]::ReadAllBytes($wrongVersion)
    [IO.File]::WriteAllText($wrongVersion, 'wrong game version')
    Expect-Rejection { & $installer -Action Install -GameDirectory $fixture } '*版本或文件不匹配*'
    [IO.File]::WriteAllBytes($wrongVersion, $originalBytes)
    $delta = Join-Path $root $manifest.deltas.PSObject.Properties['KSA.dll'].Value.path
    $deltaBytes = [IO.File]::ReadAllBytes($delta)
    try {
        [IO.File]::WriteAllText($delta, 'corrupted delta')
        Expect-Rejection { & $installer -Action Install -GameDirectory $fixture } '*差分补丁校验失败*'
    } finally { [IO.File]::WriteAllBytes($delta, $deltaBytes) }
    if ((Get-TestHash $save) -ne $saveHash) { throw '存档标记被修改' }
    [pscustomobject]@{
        result = 'passed'
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        installationHashesMatch = $true
        repeatedInstall = $true
        unknownFileProtectedWithoutChanges = $true
        wrongVersionRejectedWithoutChanges = $true
        corruptedDeltaRejectedWithoutChanges = $true
        originalRestore = $true
        addedFilesRemovedOnRestore = $true
        saveUnchanged = $true
        gameExecutableCopiedOrStarted = $false
        manifestSha256 = Get-TestHash (Join-Path $root 'manifest.json')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'reports/distribution-tests.json') -Encoding UTF8
    Write-Output '差分安装、重复安装、文件保护、版本检查、损坏补丁拒绝和完整还原：全部通过。'
} finally {
    if ($hadSupportMarker) { [IO.File]::WriteAllBytes($supportMarker, $supportMarkerBytes) }
    elseif (Test-Path -LiteralPath $supportMarker) { Remove-Item -LiteralPath $supportMarker }
    if ($hadRemembered) { [IO.File]::WriteAllBytes($remembered, $rememberedBytes) }
    elseif (Test-Path -LiteralPath $remembered) { Remove-Item -LiteralPath $remembered }
    # 删除前再次确认测试目录仅位于本机临时目录下。
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith($temporaryRoot.TrimEnd('\') + '\KsaChinese-Test-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
