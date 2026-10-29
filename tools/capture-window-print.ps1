# Captures a window's own pixels, even when another window is on top of it.
#
# CopyFromScreen grabs whatever is physically on top, which "captured" a browser window instead of the
# game the first time. PrintWindow asks the window to draw itself into a bitmap, so overlap, focus and
# z-order do not matter and the desktop is not disturbed.
#
#   .\capture-window-print.ps1 -ProcessId 1234 -Path shot.png
#
# PW_RENDERFULLCONTENT (2) is what makes this work for windows that render with a 3D/DirectX surface.

param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$ClientOnly
)

Add-Type -AssemblyName System.Drawing

if (-not ("PrintCapture" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PrintCapture {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
}

[void][PrintCapture]::SetProcessDPIAware()

$proc = Get-Process -Id $ProcessId -ErrorAction Stop
$handle = $proc.MainWindowHandle
if ($handle -eq 0) {
    Write-Host "no window handle for pid $ProcessId"
    exit 1
}

$rect = New-Object PrintCapture+RECT
if ($ClientOnly) {
    [void][PrintCapture]::GetClientRect($handle, [ref]$rect)
} else {
    [void][PrintCapture]::GetWindowRect($handle, [ref]$rect)
}

$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -le 0 -or $height -le 0) {
    Write-Host "window has no area ($width x $height)"
    exit 1
}

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$hdc = $graphics.GetHdc()
$ok = [PrintCapture]::PrintWindow($handle, $hdc, 2)
$graphics.ReleaseHdc($hdc)
$graphics.Dispose()

Write-Host "printwindow=$ok ${width}x${height} -> $Path"
$bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()
exit 0
