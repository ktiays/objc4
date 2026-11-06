param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [ValidateSet('aarch64', 'x86_64')][string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }),
    [int]$Jobs = 4
)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot/build-windows.ps1" -Configuration $Configuration -Architecture $Architecture -Jobs $Jobs
$objcRoot = Split-Path $PSScriptRoot -Parent
ctest --test-dir (Join-Path $objcRoot "build\windows-$Architecture-$Configuration") --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Windows runtime tests failed.' }
