param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [ValidateSet('aarch64', 'x86_64')][string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }),
    [int]$Jobs = 4
)
$ErrorActionPreference = 'Stop'
$objcRoot = Split-Path $PSScriptRoot -Parent
if (!$env:LLVM_MINGW_ROOT) {
    throw 'Set LLVM_MINGW_ROOT to an extracted LLVM-MinGW UCRT toolchain.'
}
$objcToolchain = (Resolve-Path $env:LLVM_MINGW_ROOT).Path
$env:PATH = "$objcToolchain\bin;$env:PATH"
$objcBuild = Join-Path $objcRoot "build\windows-$Architecture-$Configuration"
cmake -S $objcRoot -B $objcBuild -G Ninja `
    "-DCMAKE_TOOLCHAIN_FILE=$objcRoot/platform/windows/llvm-mingw.cmake" `
    "-DLLVM_MINGW_ROOT=$objcToolchain" "-DOBJC_WINDOWS_ARCH=$Architecture" `
    "-DCMAKE_BUILD_TYPE=$Configuration"
if ($LASTEXITCODE -ne 0) { throw 'Windows CMake configuration failed.' }
cmake --build $objcBuild --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
# Tests and applications need the target's DLLs, even when the host compiler
# uses a different architecture. Keep them beside the generated executables.
foreach ($objcDLL in 'libc++.dll', 'libunwind.dll', 'libwinpthread-1.dll') {
    Copy-Item (Join-Path $objcToolchain "$Architecture-w64-mingw32\bin\$objcDLL") $objcBuild -Force
}
