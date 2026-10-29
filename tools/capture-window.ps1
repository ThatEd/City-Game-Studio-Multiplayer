# Captures a game window to a PNG, so UI state can be checked instead of inferred from logs.
#
#   .\capture-window.ps1 -ProcessId 1234 -Path out.png -Place 0,0 -Size 1000,700
#
# Two things make a capture trustworthy, and both were got wrong the first time:
#
#   * DPI. Without SetProcessDPIAware this script sees *virtualised* coordinates, so the rect it reads is
#     smaller than the real window and the copied region lands somewhere else entirely - the first
#     attempt "captured" a snipping-tool window instead of the game.
#   * Overlap. Two game windows can overlap, and CopyFromScreen grabs whatever is on top. -Place moves
#     the window out of the way first, and the window is brought to the front before copying.
#
# It prints the rect it used, so a wrong capture is visible in the output rather than only in the image.

param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Place = "",
    [string]$Size = "1000,700",
    [switch]$BringToFront
)

Add-Type -AssemblyName System.Drawing

if (-not ("CaptureNative" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CaptureNative {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int w, int h, bool repaint);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
}

[void][CaptureNative]::SetProcessDPIAware()

$proc = Get-Process -Id $ProcessId -ErrorAction Stop
$handle = $proc.MainWindowHandle
if ($handle -eq 0) {
    Write-Host "no window handle for pid $ProcessId (still starting?)"
    exit 1
}

if ($Place -ne "") {
    $xy = $Place.Split(",")
    $wh = $Size.Split(",")
    [void][CaptureNative]::MoveWindow($handle, [int]$xy[0], [int]$xy[1], [int]$wh[0], [int]$wh[1], $true)
    Start-Sleep -Milliseconds 900
}

if ($BringToFront) {
    [void][CaptureNative]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 600
}

if (-not [CaptureNative]::IsWindowVisible($handle)) {
    Write-Host "window not visible"
    exit 1
}

$rect = New-Object CaptureNative+RECT
if (-not [CaptureNative]::GetWindowRect($handle, [ref]$rect)) {
    Write-Host "could not read the window rect"
    exit 1
}

$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
Write-Host "rect $($rect.Left),$($rect.Top) ${width}x${height} -> $Path"
if ($width -le 0 -or $height -le 0) {
    Write-Host "window has no area"
    exit 1
}

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
$bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
Write-Host "saved $Path"
exit 0
