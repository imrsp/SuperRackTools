$ErrorActionPreference = 'Stop'
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.Tools.ARM64 Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath
if (-not $vs) { throw 'VS 2022 with x64, ARM64 and CMake tools is required.' }
Write-Host "Visual Studio: $vs"
flutter doctor -v
if ($LASTEXITCODE -ne 0) { throw 'Flutter diagnostics failed.' }
