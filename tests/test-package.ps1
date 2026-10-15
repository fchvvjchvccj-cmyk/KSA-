param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = [IO.Path]::GetFullPath((Join-Path $temporaryRoot ('KsaPackage-Test-' + [Guid]::NewGuid().ToString('N'))))
if (!$fixture.StartsWith($temporaryRoot.TrimEnd('\') + '\KsaPackage-Test-', [StringComparison]::OrdinalIgnoreCase)) { throw '测试目录越界' }
function Copy-FixtureFile([string]$relative) {
    $target = Join-Path $fixture $relative
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
}
function Expect-PackageFailure([string[]]$messages) {
    $caught = $null
    try { & (Join-Path $fixture 'scripts/install.ps1') -CheckPackage }
    catch { $caught = $_.Exception.Message }
    if (!$caught) { throw '损坏或缺失的汉化文件未被拒绝' }
    foreach ($message in $messages) { if (!$caught.Contains($message)) { throw "报错缺少定位信息：$message" } }
}
try {
    # 使用独立副本模拟玩家解压目录，不修改发布包或实际游戏。
    foreach ($relative in @('manifest.json', 'scripts/install.ps1') + @($manifest.files.PSObject.Properties.Value) + @($manifest.deltas.PSObject.Properties.Value.path)) { Copy-FixtureFile $relative }
    & (Join-Path $fixture 'scripts/install.ps1') -CheckPackage
    $dll = Join-Path $fixture 'payload/KsaChinese.dll'
    $bytes = [IO.File]::ReadAllBytes($dll)
    Remove-Item -LiteralPath $dll
    Expect-PackageFailure @('汉化文件缺失', 'payload/KsaChinese.dll', $dll)
    [IO.File]::WriteAllText($dll, 'corrupted or mixed DLL')
    Expect-PackageFailure @('汉化文件校验失败', '预期 SHA256', '实际 SHA256', $dll)
    [IO.File]::WriteAllBytes($dll, $bytes)
    $delta = Join-Path $fixture $manifest.deltas.PSObject.Properties['KSA.dll'].Value.path
    [IO.File]::WriteAllText($delta, 'corrupted delta')
    Expect-PackageFailure @('差分补丁文件校验失败', $delta)
    if (Test-Path -LiteralPath (Join-Path $fixture '.install-path.txt')) { throw '检查模式不应记录游戏安装路径' }
    [pscustomobject]@{
        result = 'passed'; checks = 5; powershellVersion = $PSVersionTable.PSVersion.ToString()
        intactPackageAccepted = $true; missingDllReported = $true; mismatchedDllHashesReported = $true
        corruptedDeltaRejected = $true; gameDirectoryNotRequired = $true; gameStarted = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'reports/package-tests.json') -Encoding UTF8
    Write-Output '汉化包检查入口：5 项检查通过，未安装或启动游戏。'
} finally {
    # 删除前核对绝对路径，仅清理本次创建的临时测试目录。
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith($temporaryRoot.TrimEnd('\') + '\KsaPackage-Test-', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
