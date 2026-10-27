$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$IconPath = Join-Path $Root 'windows/runner/resources/app_icon.ico'
$PngPath = Join-Path $Root 'assets/app_icon.png'
$TempPng = Join-Path $env:TEMP 'superracktools-icon-256.png'
Add-Type -AssemblyName System.Drawing
$Image = [System.Drawing.Image]::FromFile($PngPath)
$Bitmap = New-Object System.Drawing.Bitmap 256, 256
$Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
$Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$Graphics.DrawImage($Image, 0, 0, 256, 256)
$Bitmap.Save($TempPng, [System.Drawing.Imaging.ImageFormat]::Png)
$Graphics.Dispose(); $Bitmap.Dispose(); $Image.Dispose()
$env:SUPER_RACK_ICON_PNG = $TempPng
$env:SUPER_RACK_ICON_ICO = $IconPath
@'
import os, pathlib, struct
png=pathlib.Path(os.environ['SUPER_RACK_ICON_PNG']).read_bytes()
entry=struct.pack('<BBBBHHII',0,0,0,0,1,32,len(png),22)
pathlib.Path(os.environ['SUPER_RACK_ICON_ICO']).write_bytes(struct.pack('<HHH',0,1,1)+entry+png)
'@ | python -
if ($LASTEXITCODE -ne 0) { throw 'Windows icon generation failed.' }
Remove-Item $TempPng
$Cmake = Join-Path $Root 'windows/CMakeLists.txt'
$text = [IO.File]::ReadAllText($Cmake).Replace('set(BINARY_NAME "super_rack_tools")', 'set(BINARY_NAME "SuperRackTools")')
[IO.File]::WriteAllText($Cmake, $text)
$Rc = Join-Path $Root 'windows/runner/Runner.rc'
$text = [IO.File]::ReadAllText($Rc).Replace('super_rack_tools', 'SuperRackTools').Replace('com.example', 'tech.rslive')
[IO.File]::WriteAllText($Rc, $text)
$Main = Join-Path $Root 'windows/runner/main.cpp'
$text = [IO.File]::ReadAllText($Main).Replace('super_rack_tools', 'SuperRackTools')
[IO.File]::WriteAllText($Main, $text)
