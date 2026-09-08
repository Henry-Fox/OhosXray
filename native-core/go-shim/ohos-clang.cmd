@echo off
REM Wrapper so cgo does not need --target in CGO_LDFLAGS (rejected by Go).
set "CLANG=C:\Users\mengshuo\AppData\Local\OpenHarmony\Sdk\26.0.0\native\llvm\bin\clang.exe"
set "SYSROOT=C:\Users\mengshuo\AppData\Local\OpenHarmony\Sdk\26.0.0\native\sysroot"
"%CLANG%" --target=aarch64-linux-ohos --sysroot="%SYSROOT%" %*
