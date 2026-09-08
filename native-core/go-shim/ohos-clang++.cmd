@echo off
set "CLANGXX=C:\Users\mengshuo\AppData\Local\OpenHarmony\Sdk\26.0.0\native\llvm\bin\clang++.exe"
set "SYSROOT=C:\Users\mengshuo\AppData\Local\OpenHarmony\Sdk\26.0.0\native\sysroot"
"%CLANGXX%" --target=aarch64-linux-ohos --sysroot="%SYSROOT%" %*
