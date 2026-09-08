# Cross-compile libxraycore.so for HarmonyOS arm64-v8a.
# Must use GOOS=android (not linux) so Go TLS works under dlopen on musl.
# Must set TUN fd via Go os.Setenv (XraySetTunFd), not C setenv.

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Resolve-Path (Join-Path $Root "..\..")
$OutDir = Join-Path $Repo "entry\src\main\cpp\libs\arm64-v8a"
$PackDir = Join-Path $Repo "entry\libs\arm64-v8a"
$SdkNative = "C:\Users\mengshuo\AppData\Local\OpenHarmony\Sdk\26.0.0\native"
$Clang = Join-Path $SdkNative "llvm\bin\clang.exe"
$Sysroot = Join-Path $SdkNative "sysroot"
$GoTmp = Join-Path $Repo "gotmp\goshim-build"
$CcWrapper = Join-Path $Root "ohos-clang.cmd"

if (-not (Test-Path $Clang)) { throw "OHOS clang not found: $Clang" }
if (-not (Test-Path $CcWrapper)) { throw "clang wrapper not found: $CcWrapper" }

New-Item -ItemType Directory -Force -Path $OutDir, $PackDir, $GoTmp | Out-Null

$StubInc = Join-Path $Root "android-stub\include"
$StubLibDir = Join-Path $Root "android-stub\lib"
$StubSrc = Join-Path $Root "android-stub\log_stub.c"
$StubObj = Join-Path $StubLibDir "log_stub.o"
$StubLib = Join-Path $StubLibDir "liblog.a"
$Ar = Join-Path $SdkNative "llvm\bin\llvm-ar.exe"

New-Item -ItemType Directory -Force -Path $OutDir, $PackDir, $GoTmp, $StubLibDir | Out-Null

# Build stub liblog.a (GOOS=android cgo links -llog)
& $Clang --target=aarch64-linux-ohos --sysroot=$Sysroot -fPIC -D__MUSL__ -O2 "-I$StubInc" -c $StubSrc -o $StubObj
if ($LASTEXITCODE -ne 0) { throw "compile android log stub failed" }
& $Ar rcs $StubLib $StubObj
if ($LASTEXITCODE -ne 0) { throw "archive liblog.a failed" }

$env:GOOS = "android"
$env:GOARCH = "arm64"
$env:CGO_ENABLED = "1"
$env:CC = $CcWrapper
$env:CXX = (Join-Path $Root "ohos-clang++.cmd")
# Keep flags simple: --target/--sysroot live in the clang wrapper (Go rejects them in CGO_LDFLAGS).
$env:CGO_CFLAGS = "-fPIC -D__MUSL__ -O2 -I$StubInc"
$env:CGO_LDFLAGS = "-fPIC -L$StubLibDir"
$env:GOTMPDIR = $GoTmp
$env:GOCACHE = Join-Path $Repo ".gocache"

Set-Location $Root
Write-Host "go mod tidy..."
go mod tidy
if ($LASTEXITCODE -ne 0) { throw "go mod tidy failed" }
Write-Host "building libxraycore.so ..."
go build -buildmode=c-shared -tags "netgo" -trimpath -ldflags="-checklinkname=0" -o (Join-Path $OutDir "libxraycore.so") .
if ($LASTEXITCODE -ne 0) { throw "go build failed" }

Copy-Item -Force (Join-Path $OutDir "libxraycore.so") (Join-Path $PackDir "libxraycore.so")
$hdr = Join-Path $OutDir "libxraycore.h"
if (Test-Path $hdr) {
  Copy-Item -Force $hdr (Join-Path $PackDir "libxraycore.h")
}

Write-Host "OK -> $OutDir\libxraycore.so"
Get-Item (Join-Path $OutDir "libxraycore.so") | Format-List Name, Length, LastWriteTime
