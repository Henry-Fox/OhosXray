cmake_minimum_required(VERSION 3.5.0)
project(xraybridge)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                     ${NATIVERENDER_ROOT_PATH}/include)

add_library(xraybridge SHARED
    napi_init.cpp
    xray_bridge.cpp
)

target_link_libraries(xraybridge PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
)

# go build -buildmode=c-shared -tags ohos_native 产物：libxraycore.so + libxraycore.h
# 把交叉编译好的产物放到 entry/src/main/cpp/libs/${OHOS_ARCH}/ 下，
# 与下面的路径对应。${OHOS_ARCH} 由 DevEco Studio 在构建时注入（armeabi-v7a/arm64-v8a等）。
#
# 这个 .so 必须用 GOOS=android 编译（不是 GOOS=linux）：Go 的 runtime 只在
# GOOS=android/darwin/windows 下用"普通全局变量存TLS偏移量+运行时探测"的
# dlopen安全方案；GOOS=linux 下会用真正的 ELF TLS（initial-exec 模型），这种
# 重定位只在"程序启动时就加载"的场景下才能被解析，被 dlopen() 加载时
# HarmonyOS 的 musl 动态链接器会报 "initial-exec TLS resolves to dynamic
# definition" 拒绝加载——而 ArkTS native 模块本来就是被 dlopen() 加载的。
# 详见 native-core/go-shim/build_linux_arm64.sh 的 Step 5 注释。
#
# 这个 .so 还需要额外拷贝到 entry/libs/${OHOS_ARCH}/ 才会被 hvigor 真正打进 HAP
# （src/main/cpp/libs 只是给 CMake 链接时用，不在打包范围内）。
target_link_libraries(xraybridge PUBLIC
    ${NATIVERENDER_ROOT_PATH}/libs/${OHOS_ARCH}/libxraycore.so
)
