# GoodbyeDPI Kontrol Paneli - hizmeti açıp kapatır, mod değiştirir.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# --- Yönetici kontrolü ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class DpiPanel : Panel {
    public DpiPanel() { DoubleBuffered = true; ResizeRedraw = true; }
}
public static class DpiW32 {
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, int w, int l);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
}
'@

[System.Windows.Forms.Application]::EnableVisualStyles()

$ServiceName = 'GoodbyeDPI'
$RegPath     = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$Exe         = Join-Path $PSScriptRoot 'x86_64\goodbyedpi.exe'

$Captions = @{
    1 = 'En uyumlu'; 2 = 'Uyumlu'; 3 = 'Hızlı'; 4 = 'En hızlı'; 5 = 'Oto TTL'
    6 = 'Yanlış seq'; 7 = 'Bozuk checksum'; 8 = 'Seq + checksum'; 9 = '+ QUIC engeli'
}
$Descs = @{
    1 = 'HTTP ve HTTPS paketlerini küçük parçalara böler. En uyumlu ama yavaş olabilir.'
    2 = '-1 gibi, ama HTTPS parçaları daha büyük; biraz daha hızlı.'
    3 = 'Sadece HTTPS parçalanır, HTTP başlıklarıyla oynanır. Hızlı.'
    4 = 'Parçalama yok, sadece başlık hileleri. En hızlısı ama Türkiye''de zayıf.'
    5 = 'Parçalama + otomatik TTL''li sahte paket. Türkiye''de genelde en iyi seçenek.'
    6 = 'Sahte paket yanlış sıra numarasıyla gider. -5 işe yaramazsa bunu dene.'
    7 = 'Sahte paket bozuk checksum ile gönderilir.'
    8 = 'Yanlış sıra numarası ve bozuk checksum birlikte. Daha agresif.'
    9 = '-8''e ek olarak QUIC/HTTP3 engeli. YouTube ve Chrome için en kapsamlısı.'
}

# --- Renkler ---
function RGB($r, $g, $b, $a = 255) { [Drawing.Color]::FromArgb($a, $r, $g, $b) }
$C = @{
    Bg        = RGB 15 17 22
    Card      = RGB 26 29 37
    CardHover = RGB 34 38 49
    Border    = RGB 42 46 58
    Text      = RGB 238 240 244
    Muted     = RGB 136 143 158
    Green     = RGB 34 197 94
    GreenDark = RGB 21 128 61
    Accent    = RGB 99 102 241
    Amber     = RGB 245 158 11
    Off       = RGB 62 67 82
}
function Font($size, $style = 'Regular', $name = 'Segoe UI') { New-Object Drawing.Font($name, [single]$size, [Drawing.FontStyle]$style) }

function RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [single]($r * 2)
    $p.AddArc($x, $y, $d, $d, [single]180, [single]90)
    $p.AddArc([single]($x + $w - $d), $y, $d, $d, [single]270, [single]90)
    $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), $d, $d, [single]0, [single]90)
    $p.AddArc($x, [single]($y + $h - $d), $d, $d, [single]90, [single]90)
    $p.CloseFigure()
    $p
}

# --- Hizmet işlemleri ---
function Get-Svc { Get-Service -Name $ServiceName -ErrorAction SilentlyContinue }

function Get-CurrentMode {
    $p = (Get-ItemProperty -Path $RegPath -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if ($p -and $p -match '^"[^"]+"\s*-([1-9])\b') { return [int]$Matches[1] }
    return 5
}

function Ensure-Service([int]$mode) {
    $bin = "`"$Exe`" -$mode"
    if (-not (Get-Svc)) {
        New-Service -Name $ServiceName -BinaryPathName $bin -StartupType Manual -DisplayName $ServiceName -Description 'Turkiye icin DPI engelini asar.' | Out-Null
    } else {
        Set-ItemProperty -Path $RegPath -Name ImagePath -Value $bin
    }
}

# --- Durum ---
$script:mode        = Get-CurrentMode
$script:running     = $false
$script:auto        = $false
$script:busy        = $false
$script:hoverPower  = $false
$script:hoverTile   = 0
$script:trayHinted  = $false
$script:lastHicon   = [IntPtr]::Zero

# --- Form ---
$W = 380; $H = 668
$form = New-Object Windows.Forms.Form
$form.Text = 'DPI Kontrol'
$form.ClientSize = New-Object Drawing.Size($W, $H)
$form.FormBorderStyle = 'None'
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.ForeColor = $C.Text
$form.Font = Font 9.5
[Windows.Forms.Form].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true)

$form.Add_Load({
    try {
        $v = 2; [void][DpiW32]::DwmSetWindowAttribute($form.Handle, 33, [ref]$v, 4)   # yuvarlak köşeler
        $v = 0x003A2E2A; [void][DpiW32]::DwmSetWindowAttribute($form.Handle, 34, [ref]$v, 4)  # kenar rengi
    } catch {}
})

function Enable-Drag($ctrl) {
    $ctrl.Add_MouseDown({ if ($_.Button -eq 'Left') { [void][DpiW32]::ReleaseCapture(); [void][DpiW32]::SendMessage($form.Handle, 0xA1, 2, 0) } })
}
Enable-Drag $form

# --- Başlık çubuğu ---
$title = New-Object Windows.Forms.Label
$title.Text = 'DPI Kontrol'
$title.Font = Font 10.5 'Bold'
$title.ForeColor = $C.Text
$title.Location = New-Object Drawing.Point(20, 14)
$title.AutoSize = $true
$form.Controls.Add($title)
Enable-Drag $title

function New-TitleButton($text, $x, $hoverColor) {
    $b = New-Object Windows.Forms.Label
    $b.Text = $text
    $b.Font = Font 10
    $b.ForeColor = $C.Muted
    $b.TextAlign = 'MiddleCenter'
    $b.Size = New-Object Drawing.Size(46, 42)
    $b.Location = New-Object Drawing.Point($x, 0)
    $b.Cursor = 'Hand'
    $b.Tag = $hoverColor
    $b.Add_MouseEnter({ $this.BackColor = $this.Tag; $this.ForeColor = $C.Text })
    $b.Add_MouseLeave({ $this.BackColor = $C.Bg; $this.ForeColor = $C.Muted })
    $form.Controls.Add($b)
    $b
}
$btnMin   = New-TitleButton '—' ($W - 92) $C.CardHover
$btnClose = New-TitleButton '✕' ($W - 46) (RGB 196 43 28)

# --- Güç butonu ---
$power = New-Object DpiPanel
$power.Size = New-Object Drawing.Size(200, 190)
$power.Location = New-Object Drawing.Point((($W - 200) / 2), 50)
$power.BackColor = $C.Bg
$power.Cursor = 'Hand'
$power.Add_MouseEnter({ $script:hoverPower = $true; $power.Invalidate() })
$power.Add_MouseLeave({ $script:hoverPower = $false; $power.Invalidate() })
$power.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $cx = [single]($power.Width / 2); $cy = [single]($power.Height / 2)
    $R = [single]64

    if ($script:busy) {
        $ring = $C.Amber; $fill = $C.Card; $icon = $C.Amber
    } elseif ($script:running) {
        # parıltı
        for ($i = 12; $i -ge 1; $i--) {
            $rr = $R + $i * 2.2
            $br = New-Object Drawing.SolidBrush (RGB 34 197 94 ([int](5 + (12 - $i) * 1.6)))
            $g.FillEllipse($br, [single]($cx - $rr), [single]($cy - $rr), [single]($rr * 2), [single]($rr * 2))
            $br.Dispose()
        }
        $ring = $null; $icon = [Drawing.Color]::White
    } else {
        $ring = if ($script:hoverPower) { RGB 92 98 116 } else { $C.Off }
        $fill = if ($script:hoverPower) { $C.CardHover } else { $C.Card }
        $icon = if ($script:hoverPower) { $C.Text } else { $C.Muted }
    }

    $rect = New-Object Drawing.RectangleF(($cx - $R), ($cy - $R), ($R * 2), ($R * 2))
    if ($script:running -and -not $script:busy) {
        $top = if ($script:hoverPower) { RGB 52 211 110 } else { $C.Green }
        $lg = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, $top, $C.GreenDark, [single]90)
        $g.FillEllipse($lg, $rect); $lg.Dispose()
    } else {
        $b = New-Object Drawing.SolidBrush $fill; $g.FillEllipse($b, $rect); $b.Dispose()
        $p = New-Object Drawing.Pen($ring, [single]3); $g.DrawEllipse($p, $rect); $p.Dispose()
    }

    # güç simgesi
    $pen = New-Object Drawing.Pen($icon, [single]5.5)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $s = [single]23
    $g.DrawArc($pen, [single]($cx - $s), [single]($cy - $s + 4), [single]($s * 2), [single]($s * 2), [single]-60, [single]300)
    $g.DrawLine($pen, $cx, [single]($cy - 27), $cx, [single]($cy - 2))
    $pen.Dispose()
})
$form.Controls.Add($power)

# --- Durum yazıları ---
$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Font = Font 20 'Bold'
$lblStatus.TextAlign = 'MiddleCenter'
$lblStatus.Location = New-Object Drawing.Point(0, 242)
$lblStatus.Size = New-Object Drawing.Size($W, 40)
$form.Controls.Add($lblStatus)

$lblSub = New-Object Windows.Forms.Label
$lblSub.Font = Font 9.5
$lblSub.ForeColor = $C.Muted
$lblSub.TextAlign = 'MiddleCenter'
$lblSub.Location = New-Object Drawing.Point(0, 282)
$lblSub.Size = New-Object Drawing.Size($W, 22)
$form.Controls.Add($lblSub)

# --- Mod seçimi ---
$lblSection = New-Object Windows.Forms.Label
$lblSection.Text = 'MOD'
$lblSection.Font = Font 8 'Bold'
$lblSection.ForeColor = $C.Muted
$lblSection.Location = New-Object Drawing.Point(22, 326)
$lblSection.AutoSize = $true
$form.Controls.Add($lblSection)

$tiles = @()
$tileW = 106; $tileH = 54; $gap = 11
for ($n = 1; $n -le 9; $n++) {
    $t = New-Object DpiPanel
    $t.Tag = $n
    $col = ($n - 1) % 3; $row = [math]::Floor(($n - 1) / 3)
    $t.Location = New-Object Drawing.Point((20 + $col * ($tileW + $gap)), (348 + $row * ($tileH + 10)))
    $t.Size = New-Object Drawing.Size($tileW, $tileH)
    $t.BackColor = $C.Bg
    $t.Cursor = 'Hand'
    $t.Add_MouseEnter({ $script:hoverTile = $this.Tag; $this.Invalidate() })
    $t.Add_MouseLeave({ $script:hoverTile = 0; $this.Invalidate() })
    $t.Add_Paint({
        $g = $_.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $n = [int]$this.Tag
        $sel = $n -eq $script:mode
        $hov = $n -eq $script:hoverTile
        $path = RoundRect 1 1 ($this.Width - 3) ($this.Height - 3) 10

        $fill = if ($sel) { RGB 37 39 74 } elseif ($hov) { $C.CardHover } else { $C.Card }
        $b = New-Object Drawing.SolidBrush $fill; $g.FillPath($b, $path); $b.Dispose()
        $pc = if ($sel) { $C.Accent } else { $C.Border }
        $pw = if ($sel) { 2 } else { 1 }
        $p = New-Object Drawing.Pen($pc, [single]$pw); $g.DrawPath($p, $path); $p.Dispose(); $path.Dispose()

        $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'
        $f1 = Font 13 'Bold'; $f2 = Font 7.75
        $c1 = if ($sel) { [Drawing.Color]::White } else { $C.Text }
        $c2 = if ($sel) { RGB 180 182 255 } else { $C.Muted }
        $b1 = New-Object Drawing.SolidBrush $c1; $b2 = New-Object Drawing.SolidBrush $c2
        $g.DrawString("-$n", $f1, $b1, (New-Object Drawing.RectangleF(0, 5, $this.Width, 26)), $sf)
        $g.DrawString($Captions[$n], $f2, $b2, (New-Object Drawing.RectangleF(0, 31, $this.Width, 18)), $sf)
        $b1.Dispose(); $b2.Dispose(); $f1.Dispose(); $f2.Dispose(); $sf.Dispose()
    })
    $t.Add_Click({ Set-Mode ([int]$this.Tag) })
    $form.Controls.Add($t)
    $tiles += $t
}

$lblDesc = New-Object Windows.Forms.Label
$lblDesc.Font = Font 9
$lblDesc.ForeColor = $C.Muted
$lblDesc.Location = New-Object Drawing.Point(22, 540)
$lblDesc.Size = New-Object Drawing.Size(($W - 44), 40)
$form.Controls.Add($lblDesc)

# --- Açılışta başlat kartı ---
$card = New-Object DpiPanel
$card.Location = New-Object Drawing.Point(20, 592)
$card.Size = New-Object Drawing.Size(($W - 40), 56)
$card.BackColor = $C.Bg
$card.Add_Paint({
    $g = $_.Graphics; $g.SmoothingMode = 'AntiAlias'
    $path = RoundRect 0 0 ($card.Width - 1) ($card.Height - 1) 12
    $b = New-Object Drawing.SolidBrush $C.Card; $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
})
$form.Controls.Add($card)

$lblAuto = New-Object Windows.Forms.Label
$lblAuto.Text = 'Windows açılışında başlat'
$lblAuto.Font = Font 10
$lblAuto.ForeColor = $C.Text
$lblAuto.BackColor = $C.Card
$lblAuto.AutoSize = $true
$lblAuto.Location = New-Object Drawing.Point(16, 17)
$card.Controls.Add($lblAuto)

$switch = New-Object DpiPanel
$switch.Size = New-Object Drawing.Size(46, 26)
$switch.Location = New-Object Drawing.Point(($card.Width - 62), 15)
$switch.BackColor = $C.Card
$switch.Cursor = 'Hand'
$switch.Add_Paint({
    $g = $_.Graphics; $g.SmoothingMode = 'AntiAlias'
    $path = RoundRect 0 0 ($switch.Width - 1) ($switch.Height - 1) 12.5
    $tc = if ($script:auto) { $C.Green } else { $C.Off }
    $b = New-Object Drawing.SolidBrush $tc; $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
    $kx = if ($script:auto) { $switch.Width - 23 } else { 3 }
    $g.FillEllipse([Drawing.Brushes]::White, [single]$kx, [single]3, [single]19, [single]19)
})
$switch.Add_Click({ Set-Auto (-not $script:auto) })
$card.Controls.Add($switch)

# --- Sistem tepsisi ---
function New-DotIcon($color) {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $b = New-Object Drawing.SolidBrush $color
    $g.FillEllipse($b, 3, 3, 26, 26)
    $p = New-Object Drawing.Pen([Drawing.Color]::White, [single]3.5); $p.StartCap = 'Round'; $p.EndCap = 'Round'
    $g.DrawArc($p, [single]9, [single]10, [single]14, [single]14, [single]-60, [single]300)
    $g.DrawLine($p, [single]16, [single]8, [single]16, [single]16)
    $g.Dispose(); $b.Dispose(); $p.Dispose()
    $h = $bmp.GetHicon(); $bmp.Dispose()
    if ($script:lastHicon -ne [IntPtr]::Zero) { [void][DpiW32]::DestroyIcon($script:lastHicon) }
    $script:lastHicon = $h
    [Drawing.Icon]::FromHandle($h)
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Text = 'DPI Kontrol'
$menu = New-Object Windows.Forms.ContextMenuStrip
$miToggle = $menu.Items.Add('Aç')
$miShow   = $menu.Items.Add('Göster')
[void]$menu.Items.Add('-')
$miExit   = $menu.Items.Add('Çıkış')
$tray.ContextMenuStrip = $menu
$tray.Visible = $true

function Show-Window { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }
$tray.Add_MouseDoubleClick({ Show-Window })
$miShow.Add_Click({ Show-Window })
$miToggle.Add_Click({ Toggle-Power })
$miExit.Add_Click({ $form.Close() })

$btnMin.Add_Click({
    $form.Hide()
    if (-not $script:trayHinted) {
        $tray.ShowBalloonTip(2500, 'DPI Kontrol', 'Arka planda çalışıyor. Simgeye çift tıklayarak açabilirsin.', 'Info')
        $script:trayHinted = $true
    }
})
$btnClose.Add_Click({ $form.Close() })
$form.Add_FormClosed({
    $timer.Stop(); $tray.Visible = $false; $tray.Dispose()
    if ($script:lastHicon -ne [IntPtr]::Zero) { [void][DpiW32]::DestroyIcon($script:lastHicon) }
})

# --- Mantık ---
function Update-State {
    $svc = Get-Svc
    $script:running = [bool]($svc -and $svc.Status -eq 'Running')
    $script:auto    = [bool]($svc -and $svc.StartType -eq 'Automatic')

    if ($script:busy) {
        $lblStatus.Text = 'Bekleyin…'; $lblStatus.ForeColor = $C.Amber
    } elseif ($script:running) {
        $lblStatus.Text = 'Açık'; $lblStatus.ForeColor = $C.Green
        $lblSub.Text = "Mod -$($script:mode) · $($Captions[$script:mode]) aktif"
    } else {
        $lblStatus.Text = 'Kapalı'; $lblStatus.ForeColor = $C.Text
        $lblSub.Text = 'Açmak için butona tıkla'
    }
    $lblDesc.Text = $Descs[$script:mode]

    $state = if ($script:running) { 'Açık' } else { 'Kapalı' }
    $tray.Text = "DPI Kontrol – $state (Mod -$($script:mode))"
    $tray.Icon = New-DotIcon $(if ($script:running) { $C.Green } else { $C.Off })
    $miToggle.Text = if ($script:running) { 'Kapat' } else { 'Aç' }

    $power.Invalidate(); $switch.Invalidate()
    foreach ($t in $tiles) { $t.Invalidate() }
}

function Do-Action([scriptblock]$action) {
    if ($script:busy) { return }
    $script:busy = $true
    $form.Cursor = 'WaitCursor'
    Update-State
    [Windows.Forms.Application]::DoEvents()
    try { & $action }
    catch { [Windows.Forms.MessageBox]::Show("Hata: $($_.Exception.Message)", 'DPI Kontrol', 'OK', 'Error') | Out-Null }
    finally { $script:busy = $false; $form.Cursor = 'Default'; Update-State }
}

function Toggle-Power {
    Do-Action {
        if ((Get-Svc).Status -eq 'Running') {
            Stop-Service -Name $ServiceName -Force
        } else {
            Ensure-Service $script:mode
            Start-Service -Name $ServiceName
        }
    }
}

function Set-Mode([int]$n) {
    if ($script:busy -or $n -eq $script:mode) { return }
    $script:mode = $n
    Do-Action {
        $was = (Get-Svc).Status -eq 'Running'
        if ($was) { Stop-Service -Name $ServiceName -Force }
        Ensure-Service $script:mode
        if ($was) { Start-Service -Name $ServiceName }
    }
}

function Set-Auto([bool]$on) {
    Do-Action {
        Ensure-Service $script:mode
        Set-Service -Name $ServiceName -StartupType $(if ($on) { 'Automatic' } else { 'Manual' })
    }
}

$power.Add_Click({ Toggle-Power })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ if (-not $script:busy) { Update-State } })
$timer.Start()

Update-State
[Windows.Forms.Application]::Run($form)
