# Run beside gaze.exe. Registers gaze:// only for the current Windows user.
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot 'gaze.exe'
if (-not (Test-Path $exe)) { throw 'Keep this script beside gaze.exe in the extracted release.' }
$key = 'HKCU:\Software\Classes\gaze'
New-Item -Path $key -Force | Out-Null
Set-Item -Path $key -Value 'URL:gaze Party Session'
New-ItemProperty -Path $key -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
New-Item -Path "$key\shell\open\command" -Force | Out-Null
Set-Item -Path "$key\shell\open\command" -Value ('"' + $exe + '" "%1"')
Write-Host 'gaze Party Session links are registered for this account.'
