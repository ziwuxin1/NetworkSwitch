$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$destination = Join-Path (Split-Path $PSScriptRoot -Parent) 'NetworkSwitch-Cyber-v2.1.1.exe'
& $compiler /nologo /target:winexe /platform:anycpu "/win32icon:$PSScriptRoot\NetworkSwitch.ico" /optimize+ "/out:$destination" "/win32manifest:$PSScriptRoot\app.manifest" "/resource:$PSScriptRoot\NetworkWorker.ps1,NetworkWorker.ps1" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll "$PSScriptRoot\NetworkSwitch.cs"
if ($LASTEXITCODE -ne 0) { throw 'Compilation failed.' }
Write-Output "Built: $destination"



