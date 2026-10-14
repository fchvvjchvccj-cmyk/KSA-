function New-SupportForm([string]$ImagePath) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $width = [Math]::Min(680, [Math]::Max(280, $area.Width - 80))
    $height = [Math]::Min($width + 90, [Math]::Max(300, $area.Height - 100))
    $form = New-Object Windows.Forms.Form
    try {
        $form.Text = '汉化不易，感谢支持'
        $form.StartPosition = 'CenterScreen'
        $form.ClientSize = New-Object Drawing.Size($width, $height)
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.AutoScaleMode = 'None'
        $form.BackColor = [Drawing.Color]::White
        $form.Font = New-Object Drawing.Font('Microsoft YaHei', 10)
        $form.Tag = [Drawing.Image]::FromFile($ImagePath)
        # 图片按比例完整显示，不裁剪赞赏码；关闭窗口就能继续安装。
        $picture = New-Object Windows.Forms.PictureBox
        $picture.Dock = 'Fill'
        $picture.SizeMode = 'Zoom'
        $picture.Image = $form.Tag
        $footer = New-Object Windows.Forms.Panel
        $footer.Dock = 'Bottom'
        $footer.Height = 78
        $label = New-Object Windows.Forms.Label
        $label.Dock = 'Top'
        $label.Height = 32
        $label.TextAlign = 'MiddleCenter'
        $label.Text = '赞赏完全自愿，感谢支持。汉化免费使用。'
        $button = New-Object Windows.Forms.Button
        $button.Dock = 'Bottom'
        $button.Height = 44
        $button.Text = '继续安装（无需赞赏）'
        $button.Add_Click({ param($sender, $eventArgs) $sender.FindForm().Close() })
        $footer.Controls.Add($label)
        $footer.Controls.Add($button)
        $form.Controls.Add($picture)
        $form.Controls.Add($footer)
        $form.AcceptButton = $button
        $form.Add_Disposed({ param($sender, $eventArgs) if ($sender.Tag -is [Drawing.Image]) { $sender.Tag.Dispose() } })
        return $form
    } catch {
        if ($form.Tag -is [Drawing.Image]) { $form.Tag.Dispose() }
        $form.Dispose()
        throw
    }
}

function Show-SupportNotice {
    param(
        [string]$Root,
        [scriptblock]$Presenter = { param($form) [void]$form.ShowDialog() }
    )
    $imagePath = Join-Path $Root '给我打赏一点吧，汉化不易.jpg'
    $marker = Join-Path $Root '.support-viewed'
    $hash = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash
    if ((Test-Path -LiteralPath $marker) -and [IO.File]::ReadAllText($marker).Trim() -eq $hash) { return }
    $form = New-SupportForm $imagePath
    try {
        & $Presenter $form
        # 只有完成展示后才记录；记录仅在补丁解压目录中，不写入游戏或存档。
        [IO.File]::WriteAllText($marker, $hash, [Text.Encoding]::UTF8)
    } finally { $form.Dispose() }
}
