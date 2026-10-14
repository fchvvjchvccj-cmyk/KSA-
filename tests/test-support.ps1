param([Parameter(Mandatory=$true)][string]$ReportDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/support.ps1')
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = [IO.Path]::GetFullPath((Join-Path $temporaryRoot ('KsaSupport-Test-' + [Guid]::NewGuid().ToString('N'))))
if (!$fixture.StartsWith($temporaryRoot.TrimEnd('\') + '\KsaSupport-Test-', [StringComparison]::OrdinalIgnoreCase)) { throw '测试目录越界' }
New-Item -ItemType Directory -Path $fixture | Out-Null
New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$imagePath = Join-Path $fixture '给我打赏一点吧，汉化不易.jpg'
Copy-Item -LiteralPath (Join-Path $root '给我打赏一点吧，汉化不易.jpg') -Destination $imagePath
$script:presentations = 0
$script:checks = 0
try {
    # 构建并离屏绘制真正的提示窗，不调用 Show 或 ShowDialog，不影响用户桌面。
    Show-SupportNotice -Root $fixture -Presenter {
        param($form)
        if ($form.Visible) { throw '后台检查不应显示窗口' }
        $form.PerformLayout()
        $picture = $form.Controls | Where-Object { $_ -is [Windows.Forms.PictureBox] }
        $footer = $form.Controls | Where-Object { $_ -is [Windows.Forms.Panel] }
        $button = $footer.Controls | Where-Object { $_ -is [Windows.Forms.Button] }
        if (!$picture.Image -or $picture.SizeMode -ne 'Zoom') { throw '图片没有完整按比例显示' }
        if (!$button.Enabled -or $button.Text -ne '继续安装（无需赞赏）') { throw '免费继续按钮不可用' }
        if ($picture.Bounds.IntersectsWith($footer.Bounds)) { throw '图片与继续安装区域重叠' }
        # 隐藏表单的子控件也处于隐藏状态；转入离屏面板后绘制实际内容。
        $canvas = New-Object Windows.Forms.Panel
        $canvas.Size = $form.ClientSize
        $canvas.BackColor = [Drawing.Color]::White
        $canvas.Controls.Add($picture)
        $canvas.Controls.Add($footer)
        $canvas.PerformLayout()
        $bitmap = New-Object Drawing.Bitmap($canvas.Width, $canvas.Height)
        try {
            $canvas.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
            $bitmap.Save((Join-Path $ReportDirectory 'support-preview.png'), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose(); $canvas.Dispose() }
        $script:presentations++
        $script:checks += 4
    }
    $marker = Join-Path $fixture '.support-viewed'
    if ([IO.File]::ReadAllText($marker).Trim() -ne (Get-FileHash -LiteralPath $imagePath).Hash) { throw '未记录已完成的图片展示' }
    $script:checks++
    Show-SupportNotice -Root $fixture -Presenter { throw '同一图片不应重复展示' }
    $script:checks++
    # 失败的展示不能被记作完成，下一次仍需显示。
    [IO.File]::WriteAllText($marker, 'outdated image hash')
    $failed = $false
    try { Show-SupportNotice -Root $fixture -Presenter { throw '模拟展示失败' } }
    catch { $failed = $_.Exception.Message -eq '模拟展示失败' }
    if (!$failed -or [IO.File]::ReadAllText($marker) -ne 'outdated image hash') { throw '失败展示错误地记录为完成' }
    $script:checks++
    # 表单释放后原图不能继续被锁住，便于移动或删除解压包。
    $stream = [IO.File]::Open($imagePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stream.Dispose()
    $script:checks++
    [pscustomobject]@{
        result = 'passed'
        checks = $script:checks
        fullImagePreserved = $true
        freeContinueAvailable = $true
        noticeRecordedOnlyAfterSuccessfulPresentation = $true
        repeatedNoticeSuppressed = $true
        imageReleasedAfterClose = $true
        userWindowsOpened = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ReportDirectory 'support-tests.json') -Encoding UTF8
    Write-Output "赞赏图片与首次安装提示：$($script:checks) 项离屏检查通过，未打开窗口。"
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith($temporaryRoot.TrimEnd('\') + '\KsaSupport-Test-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
