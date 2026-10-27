$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$testRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'validation'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$testExe = Join-Path $testRoot 'UiRegression.exe'
& $compiler /nologo /target:exe /main:UiRegression "/out:$testExe" "/win32icon:$PSScriptRoot\NetworkSwitch.ico" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll "$PSScriptRoot\NetworkSwitch.cs" "$PSScriptRoot\Test-Ui.cs"
if ($LASTEXITCODE -ne 0) { throw 'UI test compilation failed.' }
& $testExe
if ($LASTEXITCODE -ne 0) { throw 'UI regression failed.' }
