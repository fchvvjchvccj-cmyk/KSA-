param(
    [ValidateSet('Install', 'Restore')][string]$Action = 'Install',
    [ValidateSet('zh-Hans', 'en-US')][string]$Launch,
    [string]$GameDirectory,
    [switch]$CheckPackage
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$remembered = Join-Path $root '.install-path.txt'
function Assert-PackageFile([string]$relative, [string]$expectedHash, [string]$kind) {
    $base = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (!$path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw '补丁路径越出了指定目录。' }
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "${kind}文件缺失：$relative`n完整路径：$path`n请从 GitHub Releases 重新下载对应游戏版本的完整 ZIP，解压到新的文件夹后运行。若解压后文件消失，请查看安全软件的保护历史，确认原因；不要跳过文件校验。"
    }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "${kind}文件校验失败：$relative`n完整路径：$path`n预期 SHA256：$expectedHash`n实际 SHA256：$actualHash`n文件内容与此包清单不同，可能是混用了不同版本或下载、解压不完整。请重新下载完整 ZIP 并解压到新的文件夹，不要覆盖旧补丁目录。"
    }
}
# 先检查补丁包自身，避免把缺失负载误报为游戏安装问题。
if ($Action -eq 'Install' -or $CheckPackage) {
    foreach ($property in $manifest.files.PSObject.Properties) {
        Assert-PackageFile $property.Value $manifest.patchedHashes.PSObject.Properties[$property.Name].Value '汉化'
    }
    foreach ($property in $manifest.deltas.PSObject.Properties) {
        Assert-PackageFile $property.Value.path $property.Value.sha256 '差分补丁'
    }
}
if ($CheckPackage) {
    if ($Launch -or $GameDirectory -or $Action -ne 'Install') { throw '检查汉化包时请勿指定安装、还原或启动参数。' }
    Write-Output "汉化包完整性检查通过，适用游戏版本：$($manifest.gameBuild)。未安装或启动游戏。"
    return
}
if (!$GameDirectory) {
    if (Test-Path -LiteralPath $remembered) { $GameDirectory = [IO.File]::ReadAllText($remembered).Trim() }
    elseif (Test-Path -LiteralPath (Join-Path $root 'KSA.exe')) { $GameDirectory = $root }
    elseif (Test-Path -LiteralPath (Join-Path $root 'Kitten Space Agency/KSA.exe')) { $GameDirectory = Join-Path $root 'Kitten Space Agency' }
    else { $GameDirectory = (Read-Host '请输入游戏安装目录（包含 KSA.exe 的文件夹，可直接粘贴路径）').Trim().Trim('"') }
}
$game = [IO.Path]::GetFullPath($GameDirectory)
if (!(Test-Path -LiteralPath (Join-Path $game 'KSA.exe') -PathType Leaf)) { throw '所选文件夹中没有 KSA.exe，请选择游戏安装目录。' }
foreach ($process in Get-Process -Name KSA -ErrorAction SilentlyContinue) {
    if (!$process.Path -or $process.Path.StartsWith($game.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '请先保存并正常退出游戏，然后重新运行。安装器不会强制关闭游戏。'
    }
}

function Get-SafePath([string]$base, [string]$relative) {
    $base = [IO.Path]::GetFullPath($base)
    $path = [IO.Path]::GetFullPath((Join-Path $base $relative))
    if (!$path.StartsWith($base.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '补丁路径越出了指定目录。' }
    return $path
}
function Get-Hash([string]$path) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Copy-Safe([string]$source, [string]$destination) {
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

$backup = Join-Path $game '.ksa-zh-backup/original'
$statePath = Join-Path $game '.ksa-zh-backup/install-state.json'
$state = $null
if (Test-Path -LiteralPath $statePath) { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
$expected = @{}
foreach ($property in $manifest.patchedHashes.PSObject.Properties) { $expected[$property.Name] = $property.Value }
$fontSource = Join-Path $env:WINDIR 'Fonts/simhei.ttf'
if ($Action -eq 'Install') {
    if (!(Test-Path -LiteralPath $fontSource)) { throw '本机缺少 Windows 黑体 simhei.ttf。请先通过 Windows 的中文语言或字体设置安装黑体，再重试。' }
    $expected[$manifest.localFont] = Get-Hash $fontSource
} elseif ($state) {
    $fontProperty = $state.installedHashes.PSObject.Properties[$manifest.localFont]
    if ($fontProperty) { $expected[$manifest.localFont] = $fontProperty.Value }
}

# 全部校验通过后才开始备份和安装，陌生版本及同名文件均不覆盖。
foreach ($property in $manifest.originalHashes.PSObject.Properties) {
    $relative = $property.Name
    $current = Get-Hash (Get-SafePath $game $relative)
    if ($current -ne $property.Value -and $current -ne $expected[$relative]) {
        throw "版本或文件不匹配：$relative。本补丁仅支持 $($manifest.gameBuild) 的干净原版，旧补丁请先还原。"
    }
    $saved = Get-Hash (Get-SafePath $backup $relative)
    if ($saved -and $saved -ne $property.Value) { throw "原始备份校验失败：$relative，已停止。" }
    if (($Action -eq 'Restore' -or $current -ne $property.Value) -and $saved -ne $property.Value) {
        throw "缺少有效原始备份：$relative。请先还原旧补丁，或选择干净原版安装。"
    }
}
foreach ($relative in $expected.Keys) {
    if ($manifest.originalHashes.PSObject.Properties[$relative]) { continue }
    $current = Get-Hash (Get-SafePath $game $relative)
    $previous = $null
    if ($state) {
        $property = $state.installedHashes.PSObject.Properties[$relative]
        if ($property) { $previous = $property.Value }
    }
    if ($current -and $current -ne $expected[$relative] -and $current -ne $previous) { throw "发现未知同名文件：$relative，已保留。" }
}
if ($Action -eq 'Restore') {
    if (!$state) { throw '没有本安装器的安装记录，无法确认新增文件，已停止还原。' }
    foreach ($property in $manifest.originalHashes.PSObject.Properties) {
        Copy-Safe (Get-SafePath $backup $property.Name) (Get-SafePath $game $property.Name)
    }
    foreach ($relative in $expected.Keys) {
        if ($manifest.originalHashes.PSObject.Properties[$relative]) { continue }
        $path = Get-SafePath $game $relative
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Write-Output '已恢复原始英文程序文件；存档未改动。原始备份仍保留在游戏目录的 .ksa-zh-backup 中。'
} else {
    if (!('KsaPatch.Delta' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Text;
namespace KsaPatch {
    public static class Delta {
        public static void Apply(string originalPath, string deltaPath, string targetPath) {
            byte[] original = File.ReadAllBytes(originalPath);
            using (var file = File.OpenRead(deltaPath))
            using (var gzip = new GZipStream(file, CompressionMode.Decompress))
            using (var reader = new BinaryReader(gzip)) {
                if (Encoding.ASCII.GetString(reader.ReadBytes(8)) != "KSAZH001") throw new InvalidDataException("差分文件格式错误");
                uint size = reader.ReadUInt32();
                if (size > 100 * 1024 * 1024) throw new InvalidDataException("差分目标文件过大");
                byte[] output = new byte[(int)size];
                int cursor = 0;
                while (true) {
                    byte kind = reader.ReadByte();
                    if (kind == 255) break;
                    if (kind == 0) {
                        uint offset = reader.ReadUInt32();
                        uint length = reader.ReadUInt32();
                        if ((ulong)offset + length > (ulong)original.Length || (ulong)cursor + length > size) throw new InvalidDataException("差分复制范围错误");
                        Buffer.BlockCopy(original, (int)offset, output, cursor, (int)length);
                        cursor += (int)length;
                    } else if (kind == 1) {
                        uint length = reader.ReadUInt32();
                        if ((ulong)cursor + length > size) throw new InvalidDataException("差分写入范围错误");
                        byte[] literal = reader.ReadBytes((int)length);
                        if (literal.Length != (int)length) throw new InvalidDataException("差分内容不完整");
                        Buffer.BlockCopy(literal, 0, output, cursor, (int)length);
                        cursor += (int)length;
                    } else { throw new InvalidDataException("未知差分指令"); }
                }
                if (cursor != output.Length || gzip.ReadByte() != -1) throw new InvalidDataException("差分文件长度错误");
                File.WriteAllBytes(targetPath, output);
            }
        }
    }
}
'@
    }
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $stage = Get-SafePath $temporaryRoot ('KsaChinese-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        foreach ($property in $manifest.deltas.PSObject.Properties) {
            $relative = $property.Name
            $original = Get-SafePath $game $relative
            if ((Get-Hash $original) -ne $manifest.originalHashes.PSObject.Properties[$relative].Value) { $original = Get-SafePath $backup $relative }
            $destination = Get-SafePath $stage $relative
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
            [KsaPatch.Delta]::Apply($original, (Get-SafePath $root $property.Value.path), $destination)
        }
        foreach ($property in $manifest.files.PSObject.Properties) {
            Copy-Safe (Get-SafePath $root $property.Value) (Get-SafePath $stage $property.Name)
        }
        Copy-Safe $fontSource (Get-SafePath $stage $manifest.localFont)
        foreach ($relative in $expected.Keys) {
            if ((Get-Hash (Get-SafePath $stage $relative)) -ne $expected[$relative]) { throw "差分生成校验失败：$relative，游戏文件未改动。" }
        }
        # 首次安装展示完整赞赏图片，关闭即可继续，不要求付款。
        . (Join-Path $PSScriptRoot 'support.ps1')
        Show-SupportNotice -Root $root
        foreach ($property in $manifest.originalHashes.PSObject.Properties) {
            $savedPath = Get-SafePath $backup $property.Name
            if (!(Test-Path -LiteralPath $savedPath)) { Copy-Safe (Get-SafePath $game $property.Name) $savedPath }
        }
        [pscustomobject]@{ gameBuild = $manifest.gameBuild; installedHashes = $expected } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
        foreach ($relative in $expected.Keys) {
            Copy-Safe (Get-SafePath $stage $relative) (Get-SafePath $game $relative)
            if ((Get-Hash (Get-SafePath $game $relative)) -ne $expected[$relative]) { throw "安装后校验失败：$relative。请使用还原入口恢复备份。" }
        }
        Write-Output '简体中文汉化已安装，原始文件已在游戏目录的 .ksa-zh-backup 中备份。'
    } finally {
        # 仅清理本次创建的临时目录，删除前再次核对其绝对路径边界。
        $resolvedStage = [IO.Path]::GetFullPath($stage)
        if ($resolvedStage.StartsWith($temporaryRoot.TrimEnd('\') + '\KsaChinese-', [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        }
    }
}
[IO.File]::WriteAllText($remembered, $game, [Text.Encoding]::UTF8)
if ($Launch) {
    if ($Action -ne 'Install') { throw '还原时不能同时启动汉化游戏。' }
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $game 'KSA.exe'))
    $start.WorkingDirectory = $game
    $start.UseShellExecute = $false
    $start.EnvironmentVariables['KSA_LANGUAGE'] = $Launch
    [Diagnostics.Process]::Start($start) | Out-Null
}
